#!/usr/bin/env python3
"""ndt serve -- a local HTTP API over `ndt`'s lab verbs. First cut: backend only.

[Co-developed with claude code -- Adam]

    ndt serve --owner adam                     # through the ndt verb (same tree's ndt)
    python3 tools/ndt_serve/serve.py --owner adam [--port 8765] [--ndt ~/.local/bin/ndt]

It listens on 127.0.0.1 only, for one user, with no login (Adam's ruling, 09-24). The API is
under /api/v1/; every other path is reserved for the Web-GUI's static files (next cut).

The design red lines (TICKET section 3), and where each one lives:

  1. loopback only     BIND below; the Host header must be 127.0.0.1:<port> or localhost:<port>
                       (DNS rebinding); no CORS header is ever sent.
  2. CSRF              every request but GET /health carries the token from
                       ~/.config/ndt-serve/token (0600) in the X-NDT-Token header -- a custom header,
                       so no browser sends it cross-origin without a preflight this server never
                       answers -- and an Origin header, when present, must be this server's; a POST
                       also needs a JSON body. 🔴 GETs are gated too (judge 09-24, finding 1): a
                       "read" is not side-effect free -- `ndt status --check` POSTs three lock
                       probes to the kernel (ndt:8832-8847) -- so an <img> in any page must not be
                       able to start one.
  3. whitelist         verbs.py builds every argv; there is no shell on any path.
  4. thin shell        ndt's rc is passed through untouched, with a sentence from ndt help beside
                       it; stdout and stderr are kept byte for byte.
  5. long jobs         jobs.py / runner.py: async, one state-changing job at a time, detached with
                       setsid, recorded on disk.
  6. no pkill -f       nothing here signals anything but the process group this process itself
                       created for a read-only `ndt status` that ran past its timeout.
  7. identity          --owner (or $NDT_OWNER) is set once, and every ndt call carries it.
"""
import argparse
import fcntl
import hmac
import http.server
import json
import os
import re
import secrets
import signal
import socketserver
import stat
import subprocess
import sys
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cells  # noqa: E402
import jobs   # noqa: E402
import verbs  # noqa: E402

API = "/api/v1"
BIND = "127.0.0.1"
TOKEN_HEADER = "X-NDT-Token"
MAX_BODY = 16 * 1024
READ_TIMEOUT_S = 30        # an idle connection holds a handler thread this long at most
MAX_WAIT_S = 300           # ?wait= on a job, per request
PIPE_GRACE_S = 5           # after killpg, how long a read waits for its pipes to close
MAX_LOG_CHUNK = 16 * 1024 * 1024
OWNER_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
APP_NAMES_LINE = re.compile(r'^APP_NAMES="([a-z0-9 _-]*)"\s*$', re.M)
GUI_NOTE = "paths outside /api/ are reserved for the Web-GUI's static files (next cut)"


class Config:
    pass


# --- startup -----------------------------------------------------------------------------------

def default_state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "ndt-serve")


def default_token_file():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "ndt-serve", "token")


def app_names_of(ndt_real):
    """ndt's own app list, READ from the script (APP_NAMES="..."), not executed and not guessed."""
    with open(ndt_real, errors="replace") as f:
        hits = APP_NAMES_LINE.findall(f.read())
    if len(hits) != 1:
        raise SystemExit("ndt serve: cannot read ndt's app list from %s (%d APP_NAMES= lines)" % (ndt_real, len(hits)))
    return hits[0].split()


def child_env(owner):
    """The environment every ndt call gets: this process's, minus every inherited NDT_* variable,
    plus NDT_OWNER. An NDT_TOPO or NDT_MEASURING left in the shell that started the server would
    otherwise change what every later request does, and no request would say so."""
    stripped = sorted(k for k in os.environ if k.startswith("NDT_"))
    env = {k: v for k, v in os.environ.items() if not k.startswith("NDT_")}
    env["NDT_OWNER"] = owner
    return env, stripped


def private_dir(d):
    os.makedirs(d, mode=0o700, exist_ok=True)
    st = os.lstat(d)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        raise SystemExit("ndt serve: %s is not a directory owned by this user" % d)
    os.chmod(d, 0o700)


def hold_lock(path):
    """An exclusive flock held for the life of the process. A second server on the same state
    directory or token file refuses to start -- before it binds, and before it writes a token."""
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise SystemExit("ndt serve: another ndt serve holds %s" % path)
    return fd


def write_token(path):
    """A fresh token on every start, mode 0600, written atomically. rename() replaces a symlink
    at the path instead of writing through it."""
    token = secrets.token_urlsafe(32)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, (token + "\n").encode())
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    return token


# --- running a read-only verb in the request ---------------------------------------------------

READ_SLOTS = threading.BoundedSemaphore(2)


def run_read(cfg, kind, argv_tail, timeout):
    """Run a READ-ONLY ndt verb and answer with all of its output. Never used for a verb that
    changes anything -- those are jobs.

    Two of these at a time; a third waits up to cfg.read_queue_wait seconds for a slot and then
    gets None (the caller answers 503). The output is kept BYTE FOR BYTE in the read log and
    fetched back by id: the JSON answer can only carry it decoded, and `ndt` cuts claim notes
    with `cut -c1-72`, which counts bytes (judge 09-24, finding 4)."""
    if not READ_SLOTS.acquire(timeout=cfg.read_queue_wait):
        return None
    note = None
    try:
        t0 = time.monotonic()
        p = subprocess.Popen([cfg.ndt_real] + argv_tail, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=cfg.env, cwd=cfg.repo, close_fds=True,
                             start_new_session=True)
        timed_out = False
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # The group this call created (start_new_session: pgid == p.pid), by the pid it
            # recorded -- never a name or a pattern (TICKET 3.6).
            timed_out = True
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                out, err = p.communicate(timeout=PIPE_GRACE_S)
            except subprocess.TimeoutExpired:
                # 🔴 Something OUTSIDE the group still holds the pipe (a child that made its own
                # session -- a sudo'd helper can). Waiting for EOF would pin this handler and its
                # read slot for as long as that process lives (judge 09-24, finding 7). What was
                # read before now is kept; the rest is given up, and the answer says so.
                note = "a process outside ndt's group kept its output pipe open; output after the timeout is lost"
                partial = getattr(p, "_fileobj2output", None) or {}
                out = b"".join(partial.get(p.stdout, []))
                err = b"".join(partial.get(p.stderr, []))
                for f in (p.stdout, p.stderr):
                    try:
                        f.close()
                    except OSError:
                        pass
                p.wait(timeout=PIPE_GRACE_S)
        rc = p.returncode
    finally:
        READ_SLOTS.release()
    rc_class, meaning = verbs.meaning(kind, rc)
    if timed_out:
        rc_class, meaning = "timeout", "ndt did not answer within %d s and was stopped" % timeout
    argv = [cfg.ndt_real] + argv_tail
    rid = cfg.reads.save(kind, argv, rc, out, err, {"owner": cfg.owner, "timed_out": timed_out, "note": note})
    res = {"argv": argv, "rc": rc, "rc_class": rc_class, "meaning": meaning,
           "stdout": out.decode("utf-8", "replace"), "stderr": err.decode("utf-8", "replace"),
           "duration_s": round(time.monotonic() - t0, 3), "owner": cfg.owner,
           "read": {"id": rid, "stdout": "%s/reads/%s/log/stdout" % (API, rid),
                    "stderr": "%s/reads/%s/log/stderr" % (API, rid)}}
    if note:
        res["note"] = note
    return res


# --- HTTP --------------------------------------------------------------------------------------

class HttpError(Exception):
    def __init__(self, code, error, **extra):
        super().__init__(error)
        self.code, self.body = code, dict(error=error, **extra)


SLOT = threading.Lock()   # serialises "is the slot free?" with "take it"


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "ndt-serve/1"
    sys_version = ""
    timeout = READ_TIMEOUT_S
    cfg = None

    # One entry point for every method, so the Host check cannot be skipped by a method nobody
    # thought of. Methods with no route get 405, and nothing here ever answers a preflight with
    # an Access-Control-* header.
    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_OPTIONS(self):
        self._handle("OPTIONS")

    def do_PUT(self):
        self._handle("PUT")

    def do_DELETE(self):
        self._handle("DELETE")

    def do_PATCH(self):
        self._handle("PATCH")

    def do_HEAD(self):
        self._handle("HEAD")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # --- answering ---
    def _send(self, code, obj=None, raw=None, ctype="application/json; charset=utf-8", headers=None):
        body = raw if raw is not None else (json.dumps(obj, indent=1) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _handle(self, method):
        try:
            self._check_host()
            url = urllib.parse.urlsplit(self.path)
            path, query = url.path, urllib.parse.parse_qs(url.query)
            if path != API and not path.startswith(API + "/"):
                raise HttpError(404, "not found", note=GUI_NOTE)
            route, args = self._route(method, path[len(API):] or "/")
            if method == "GET" and route is not Handler.r_health:
                self._check_read()
            route(self, query, *args)
        except HttpError as e:
            self._send(e.code, e.body, headers={"Allow": "GET, POST"} if e.code == 405 else None)
        except BrokenPipeError:
            pass
        except Exception as e:   # an answer, not a dropped connection the client cannot read
            self.log_message("internal error on %s %s: %r", method, self.path, e)
            self._send(500, {"error": "internal", "note": repr(e)})

    def _check_host(self):
        hosts = self.headers.get_all("Host") or []
        port = self.server.server_address[1]
        allowed = ("127.0.0.1:%d" % port, "localhost:%d" % port)
        if len(hosts) != 1 or hosts[0].strip().lower() not in allowed:
            raise HttpError(403, "host", note="the Host header must be one of: %s" % ", ".join(allowed))

    def _check_token(self):
        sent = self.headers.get(TOKEN_HEADER, "")
        if not hmac.compare_digest(sent.encode(), self.cfg.token.encode()):
            raise HttpError(403, "token", note="send the token from %s in the %s header" % (
                self.cfg.token_file, TOKEN_HEADER))

    def _check_origin(self):
        origin = self.headers.get("Origin")
        port = self.server.server_address[1]
        if origin is not None and origin.lower() not in ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port):
            raise HttpError(403, "origin", note="a cross-origin request is refused")

    def _check_read(self):
        """Every GET but /health: the token and the Origin, exactly as a write."""
        self._check_token()
        self._check_origin()

    def _check_write(self):
        """A state-changing request: the token, then the Origin, then a JSON body."""
        self._check_token()
        self._check_origin()
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            raise HttpError(415, "content-type", note="a write must be Content-Type: application/json")
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise HttpError(400, "content-length")
        if n < 0 or n > MAX_BODY:
            raise HttpError(413, "body too large")
        raw = self.rfile.read(n) if n else b""
        try:
            body = json.loads(raw.decode("utf-8")) if raw.strip() else {}
        except (UnicodeDecodeError, ValueError):
            raise HttpError(400, "body is not JSON")
        if not isinstance(body, dict):
            raise HttpError(400, "body must be a JSON object")
        return body

    # --- routes: (method, pattern, function). The ONLY place a path becomes an action. ---
    def _route(self, method, sub):
        allowed_methods = set()
        for m, pattern, fn in ROUTES:
            hit = pattern.fullmatch(sub)
            if hit:
                allowed_methods.add(m)
                if m == method:
                    return fn, hit.groups()
        if allowed_methods:
            raise HttpError(405, "method not allowed", allowed=sorted(allowed_methods))
        raise HttpError(404, "not found")

    # --- read-only ---
    def r_health(self, query):
        """No token: it runs nothing and says nothing a local page could use against the lab."""
        busy = self.cfg.store.holding_the_slot()
        now = os.path.realpath(self.cfg.ndt)
        try:
            sha_now = jobs.file_sha256(self.cfg.ndt_real)
        except OSError:
            sha_now = None
        self._send(200, {
            "service": "ndt-serve", "api": "v1", "owner": self.cfg.owner, "bind": BIND,
            "port": self.server.server_address[1], "ndt": self.cfg.ndt, "ndt_realpath": self.cfg.ndt_real,
            "ndt_sha256": sha_now, "ndt_sha256_at_start": self.cfg.ndt_sha_at_start,
            # every ndt call runs ndt_realpath -- what the path resolved to at start. If the
            # symlink has been re-pointed since, or the file edited, it is said here.
            "ndt_realpath_now": now,
            "ndt_drift": now != self.cfg.ndt_real or sha_now != self.cfg.ndt_sha_at_start,
            "repo": self.cfg.repo,
            "apps": self.cfg.apps, "app_roots": self.cfg.app_roots, "token_file": self.cfg.token_file,
            "state_dir": self.cfg.state_dir, "stripped_env": self.cfg.stripped,
            "busy": busy["id"] if busy else None, "pid": os.getpid()})

    def r_status(self, query):
        check = query.get("check", ["0"])[-1] in ("1", "true", "yes")
        self._read_verb("status.check" if check else "status", verbs.argv_status(check))

    def r_apps(self, query):
        self._read_verb("apps.status", verbs.ARGV_APPS_STATUS, extra={"apps": self.cfg.apps})

    def _read_verb(self, kind, argv_tail, extra=None):
        res = run_read(self.cfg, kind, argv_tail, self.cfg.read_timeout)
        if res is None:
            raise HttpError(503, "busy", note="two read-only ndt calls were running for %d s" % self.cfg.read_queue_wait)
        if extra:
            res.update(extra)
        self._send(200, res)

    def r_jobs(self, query):
        limit = _int_param(query, "limit", 20, 1, 500)
        self._send(200, {"jobs": self.cfg.store.list(limit)})

    def r_job(self, query, job_id):
        wait = _int_param(query, "wait", 0, 0, MAX_WAIT_S)
        try:
            if wait:
                # a long-poll holds a thread for up to MAX_WAIT_S; only so many at once
                if not self.server.waiters.acquire(blocking=False):
                    raise HttpError(503, "busy", note="too many ?wait= requests are already waiting")
                try:
                    v = self.cfg.store.wait(job_id, wait)
                finally:
                    self.server.waiters.release()
            else:
                v = self.cfg.store.view(job_id)
        except KeyError:
            raise HttpError(404, "no such job")
        self._send(200, {"job": self._job(job_id) if v["kind"] == "cells.run" else v, "links": _links(job_id)})

    def r_read_log(self, query, rid, stream):
        try:
            data = self.cfg.reads.read(rid, stream)
        except KeyError:
            raise HttpError(404, "no such read")
        self._send(200, raw=data, ctype="text/plain; charset=utf-8")

    def r_log(self, query, job_id, stream):
        offset = _int_param(query, "offset", 0, 0, 1 << 40)
        limit = _int_param(query, "limit", MAX_LOG_CHUNK, 1, MAX_LOG_CHUNK)
        try:
            data, size = self.cfg.store.read_log(job_id, stream, offset, limit)
            state = self.cfg.store.view(job_id)["state"]
        except KeyError:
            raise HttpError(404, "no such job")
        self._send(200, raw=data, ctype="text/plain; charset=utf-8", headers={
            "X-NDT-Log-Offset": str(min(offset, size)), "X-NDT-Log-Size": str(size),
            "X-NDT-Log-Next-Offset": str(min(offset, size) + len(data)), "X-NDT-Job-State": state})

    # --- state-changing: each is ONE job, and only one runs at a time ---
    def w_up(self, query):
        body = self._check_write()
        self._start("up", _whitelisted(verbs.argv_up, body, self.cfg.app_roots), body)

    def w_down(self, query):
        body = self._check_write()
        self._start("down", _whitelisted(verbs.argv_down, body), body)

    def w_claim(self, query):
        body = self._check_write()
        self._start("claim", _whitelisted(verbs.argv_claim, body), body)

    def w_release(self, query):
        body = self._check_write()
        self._start("release", _whitelisted(verbs.argv_release, body), body)

    def w_app(self, query, name, action):
        body = self._check_write()
        self._start("apps." + action, _whitelisted(verbs.argv_app, name, action, body, self.cfg.apps), body)

    def _start(self, kind, argv_tail, body):
        job_id = self._spawn(kind, [self.cfg.ndt_real] + argv_tail, body)
        cfg = self.cfg
        self._send(202, {"job": cfg.store.view(job_id), "links": _links(job_id)})

    def _spawn(self, kind, argv, body, env=None, extra=None):
        """Take the one slot and start a job, or 409. Every state-changing path comes here."""
        cfg = self.cfg
        with SLOT:
            busy = cfg.store.holding_the_slot()
            if busy is not None:
                raise HttpError(409, "busy", note="one state-changing job at a time", job=busy)
            meta = {"owner": cfg.owner, "ndt": cfg.ndt, "ndt_realpath": cfg.ndt_real,
                    "ndt_sha256": jobs.file_sha256(cfg.ndt_real), "request": body,
                    "requested_by": "%s:%s" % self.client_address[:2], "stripped_env": cfg.stripped}
            meta.update(extra or {})
            job_id = cfg.store.start(kind, argv, cfg.repo, env or cfg.env, meta)
        return job_id

    # --- live_cells (cells.py): the grid's own list, its red, its green, a run, a guided walk ---
    def _cell(self, name):
        try:
            return self.cfg.grid.get(name)
        except KeyError:
            raise HttpError(404, "no such cell", note="the cells are what run_cells.sh --list prints")
        except cells.CellError as e:
            raise HttpError(503, "grid", note=str(e))

    def r_cells(self, query):
        try:
            self._send(200, {"cells": self.cfg.grid.list(), "grid": self.cfg.grid.dir})
        except cells.CellError as e:
            raise HttpError(503, "grid", note=str(e))

    def r_cell(self, query, name):
        self._send(200, {"cell": self._cell(name)})

    def r_cell_fixture(self, query, name, which):
        self._cell(name)
        try:
            self._send(200, self.cfg.grid.judge_fixture(name, which))
        except KeyError:
            raise HttpError(404, "no %s/ fixture for this cell" % which)

    def r_cell_fixture_raw(self, query, name, which, rel):
        self._cell(name)
        try:
            p = cells.safe_file(self.cfg.grid.fixture_dir(name, which), rel)
        except KeyError:
            raise HttpError(404, "no such raw file")
        with open(p, "rb") as f:
            self._send(200, raw=f.read(), ctype="text/plain; charset=utf-8")

    def w_cell_run(self, query, name):
        body = self._check_write()
        _whitelisted(verbs.no_fields, body)
        job_id = self._spawn_cell_run(self._cell(name), body)
        self._send(202, {"job": self._job(job_id), "links": _links(job_id)})

    def _spawn_cell_run(self, cell, body):
        cfg = self.cfg
        raw_root = os.path.join(cfg.state_dir, "cells-raw", cell["name"] + "-" + secrets.token_hex(4))
        os.makedirs(raw_root, mode=0o700)
        return self._spawn("cells.run", cfg.grid.run_argv(cell["name"], raw_root), body,
                           env=cfg.grid.env, extra={"cell": cell["name"], "raw_root": raw_root})

    def _job(self, job_id):
        """A job's view; a cell run also carries the CELL: line its own judge printed, and a
        class read from it -- rc 0 from run_cells.sh is PASS *or SKIP*, and SKIP is not a pass."""
        v = self.cfg.store.view(job_id)
        if v["kind"] == "cells.run" and v.get("raw_root"):
            res = self.cfg.grid.run_result(v["cell"], v["raw_root"])
            v["cell_verdict"] = res["verdict"] if res else None
            if v["state"] == "finished" and v["rc"] == 0 and res and res["verdict"]:
                v["rc_class"] = {"PASS": "pass", "SKIP": "skip"}.get(res["verdict"]["state"], "unknown")
        return v

    def r_cell_run(self, query, name, job_id):
        cell = self._cell(name)
        try:
            v = self._job(job_id)
        except KeyError:
            raise HttpError(404, "no such job")
        if v["kind"] != "cells.run" or v.get("cell") != cell["name"]:
            raise HttpError(404, "that job is not a run of this cell")
        res = self.cfg.grid.run_result(cell["name"], v["raw_root"])
        old = None
        if cell.get("old"):
            old = self.cfg.grid.judge_fixture(cell["name"], "old")
        self._send(200, {"job": v, "result": res,
                         "compare": cells.compare(old, res) if res else None,
                         "expected": cell.get("expected")})

    def r_job_raw(self, query, job_id, rel):
        try:
            v = self.cfg.store.view(job_id)
        except KeyError:
            raise HttpError(404, "no such job")
        if not v.get("raw_root"):
            raise HttpError(404, "this job keeps no raw directory")
        try:
            p = cells.safe_file(v["raw_root"], rel)
        except KeyError:
            raise HttpError(404, "no such raw file")
        with open(p, "rb") as f:
            self._send(200, raw=f.read(), ctype="text/plain; charset=utf-8")

    # --- the guided walk: GET derives, POST acts ---
    def _walk_view(self, walk):
        """The walk with each step's state DERIVED from what it recorded and from its job --
        nothing is written here, so a GET cannot move a walk."""
        cur, blocked = None, None
        for i, st in enumerate(walk["steps"]):
            if st["step"] == "verdict":
                st["state"] = "done" if walk.get("verdict") else "pending"
            elif st["job"]:
                try:
                    v = self._job(st["job"])
                except KeyError:
                    v = {"state": "lost", "rc": None, "rc_class": "unknown", "meaning": "job record missing"}
                st["result"] = {k: v.get(k) for k in ("id", "state", "rc", "rc_class", "meaning", "cell_verdict")}
                if v["state"] in ("running", "orphaned"):
                    st["state"] = "running"
                else:
                    st["state"] = "done" if _step_ok(st["step"], v) else "blocked"
            elif st["result"] is not None:
                st["state"] = "done" if st["result"].get("ok") else "blocked"
            else:
                st["state"] = "pending"
            if cur is None and st["state"] != "done":
                cur = i
                if st["state"] == "blocked":
                    blocked = _block_reason(st)
        walk["current"] = cur
        walk["blocked"] = blocked
        walk["done"] = cur is None
        return walk

    def r_guided_list(self, query):
        out = []
        for name in sorted(os.listdir(self.cfg.guided.root), reverse=True)[:50]:
            if name.endswith(".json"):
                try:
                    w = self._walk_view(self.cfg.guided.load(name[:-5]))
                except KeyError:
                    continue
                out.append({k: w[k] for k in ("id", "cell", "current", "blocked", "done", "verdict")})
        self._send(200, {"walks": out})

    def r_guided(self, query, gid):
        try:
            self._send(200, {"walk": self._walk_view(self.cfg.guided.load(gid))})
        except KeyError:
            raise HttpError(404, "no such walk")

    def w_guided_create(self, query, name):
        body = self._check_write()
        _whitelisted(verbs.no_fields, body)
        cell = self._cell(name)
        self._send(201, {"walk": self._walk_view(self.cfg.guided.create(cell))})

    def w_guided_next(self, query, gid):
        body = self._check_write()
        _whitelisted(verbs.no_fields, body)
        g = self.cfg.guided
        with g.lock:
            try:
                walk = self._walk_view(g.load(gid))
            except KeyError:
                raise HttpError(404, "no such walk")
            if walk.get("aborted"):
                raise HttpError(409, "aborted", walk=walk)
            if walk["done"]:
                raise HttpError(409, "finished", walk=walk)
            st = walk["steps"][walk["current"]]
            if st["state"] == "running":
                raise HttpError(409, "running", note="this step's job is still running", walk=walk)
            if st["step"] == "verdict":
                raise HttpError(409, "yours", note="this step is Adam's: POST %s/guided/%s/verdict" % (API, gid), walk=walk)
            self._do_step(walk, st)
            g.save(walk)
            self._send(200, {"walk": self._walk_view(walk)})

    def _do_step(self, walk, st):
        """Do one step (again, if it is blocked). Read-only steps run here; the rest are jobs."""
        cfg, name = self.cfg, walk["cell"]
        cell = self._cell(name)
        st["job"], st["result"] = None, None
        if st["step"] in ("old", "new"):
            r = cfg.grid.judge_fixture(name, st["step"])
            state = (r["verdict"] or {}).get("state")
            ok = state == ("FAIL" if st["step"] == "old" else "PASS")
            st["result"] = {"ok": ok, "judge": r, "why": None if ok else (
                "old/ no longer judges FAIL -- the red this cell was built on cannot be shown"
                if st["step"] == "old" else "new/ does not judge PASS")}
        elif st["step"] == "status":
            r = run_read(cfg, "status", verbs.argv_status(False), cfg.read_timeout)
            if r is None:
                raise HttpError(503, "busy", note="two read-only ndt calls are already running")
            st["result"] = dict(r, ok=r["rc"] == 0)
        elif st["step"] == "claim":
            st["job"] = self._spawn("claim", [cfg.ndt_real] + verbs.argv_claim(
                {"minutes": 30, "note": "guided walk %s (%s)" % (walk["id"], name)}), {"guided": walk["id"]})
        elif st["step"] == "run":
            st["job"] = self._spawn_cell_run(cell, {"guided": walk["id"]})
        elif st["step"] == "compare":
            run = next(s for s in walk["steps"] if s["step"] == "run")
            v = self._job(run["job"])
            res = cfg.grid.run_result(name, v["raw_root"])
            old = next((s for s in walk["steps"] if s["step"] == "old"), None)
            rows = cells.compare(old["result"]["judge"] if old and old["result"] else None, res)
            st["result"] = {"ok": True, "rows": rows,
                            "red_to_green": [r["id"] for r in rows if r["red_to_green"]],
                            "still_red": [r["id"] for r in rows if r["still_red"]],
                            "verdict_line": (res or {}).get("verdict")}
        elif st["step"] == "release":
            st["job"] = self._spawn("release", [cfg.ndt_real] + verbs.argv_release({}), {"guided": walk["id"]})

    def w_guided_verdict(self, query, gid):
        body = self._check_write()
        verdict, note = body.get("verdict"), body.get("note", "")
        if set(body) - {"verdict", "note"} or verdict not in ("green", "red") or not isinstance(note, str) \
                or len(note) > 2000 or re.search(r"[\x00-\x08\x0b-\x1f\x7f]", note):
            raise HttpError(400, "refused", note='body is {"verdict": "green"|"red", "note": "<text>"}')
        g = self.cfg.guided
        with g.lock:
            try:
                walk = self._walk_view(g.load(gid))
            except KeyError:
                raise HttpError(404, "no such walk")
            if walk["done"] or walk.get("aborted") or walk["steps"][walk["current"]]["step"] != "verdict":
                raise HttpError(409, "not now", note="the verdict is asked for after the compare step", walk=walk)
            walk["verdict"] = {"verdict": verdict, "note": note, "at": time.time(),
                               "requested_by": "%s:%s" % self.client_address[:2]}
            g.save(walk)
            self._send(200, {"walk": self._walk_view(walk)})

    def w_guided_abort(self, query, gid):
        body = self._check_write()
        _whitelisted(verbs.no_fields, body)
        g = self.cfg.guided
        with g.lock:
            try:
                walk = self._walk_view(g.load(gid))
            except KeyError:
                raise HttpError(404, "no such walk")
            walk["aborted"] = time.time()
            g.save(walk)
            claimed = any(s["step"] == "claim" and s["state"] == "done" for s in walk["steps"])
            released = any(s["step"] == "release" and s["state"] == "done" for s in walk["steps"])
            self._send(200, {"walk": self._walk_view(walk), "note": (
                "the claim this walk took is still held -- POST %s/release when the lab is as you want it" % API)
                if claimed and not released else "nothing of the lab is held by this walk"})


def _step_ok(step, v):
    """Did a job step come out so that the walk may go on?"""
    if v.get("state") != "finished":
        return False
    if step == "run":
        # a red cell is a RESULT Adam should see -- the walk goes on to compare it. Only a
        # harness that could not run it, or a restore that failed, stops the walk.
        return v.get("rc") in (0, 1) and bool(v.get("cell_verdict"))
    return v.get("rc") == 0


def _block_reason(st):
    r = st.get("result") or {}
    if r.get("why"):
        return r["why"]
    return "%s: rc %s (%s) -- %s. POST next to retry this step, or abort." % (
        st["step"], r.get("rc"), r.get("rc_class"), r.get("meaning"))


def _whitelisted(fn, *args):
    try:
        return fn(*args)
    except verbs.Refused as e:
        raise HttpError(400, "refused", note=str(e))


def _int_param(query, name, default, lo, hi):
    raw = query.get(name, [None])[-1]
    if raw is None:
        return default
    if not re.fullmatch(r"[0-9]{1,15}", raw) or not lo <= int(raw) <= hi:
        raise HttpError(400, "bad parameter", note="%s must be an integer from %d to %d" % (name, lo, hi))
    return int(raw)


def _links(job_id):
    j = "%s/jobs/%s" % (API, job_id)
    return {"self": j, "wait": j + "?wait=60", "stdout": j + "/log/stdout", "stderr": j + "/log/stderr"}


ROUTES = [
    ("GET", re.compile(r"/health"), Handler.r_health),
    ("GET", re.compile(r"/status"), Handler.r_status),
    ("GET", re.compile(r"/apps"), Handler.r_apps),
    ("GET", re.compile(r"/jobs"), Handler.r_jobs),
    ("GET", re.compile(r"/jobs/([^/]+)"), Handler.r_job),
    ("GET", re.compile(r"/jobs/([^/]+)/log/(stdout|stderr)"), Handler.r_log),
    ("GET", re.compile(r"/reads/([^/]+)/log/(stdout|stderr)"), Handler.r_read_log),
    ("POST", re.compile(r"/up"), Handler.w_up),
    ("POST", re.compile(r"/down"), Handler.w_down),
    ("POST", re.compile(r"/claim"), Handler.w_claim),
    ("POST", re.compile(r"/release"), Handler.w_release),
    ("POST", re.compile(r"/apps/([^/]+)/(start|stop)"), Handler.w_app),
    ("GET", re.compile(r"/cells"), Handler.r_cells),
    ("GET", re.compile(r"/cells/([^/]+)"), Handler.r_cell),
    ("GET", re.compile(r"/cells/([^/]+)/(old|new)"), Handler.r_cell_fixture),
    ("GET", re.compile(r"/cells/([^/]+)/(old|new)/raw/([^/]+)"), Handler.r_cell_fixture_raw),
    ("POST", re.compile(r"/cells/([^/]+)/run"), Handler.w_cell_run),
    ("GET", re.compile(r"/cells/([^/]+)/runs/([^/]+)"), Handler.r_cell_run),
    ("GET", re.compile(r"/jobs/([^/]+)/raw/(.+)"), Handler.r_job_raw),
    ("POST", re.compile(r"/cells/([^/]+)/guided"), Handler.w_guided_create),
    ("GET", re.compile(r"/guided"), Handler.r_guided_list),
    ("GET", re.compile(r"/guided/([^/]+)"), Handler.r_guided),
    ("POST", re.compile(r"/guided/([^/]+)/next"), Handler.w_guided_next),
    ("POST", re.compile(r"/guided/([^/]+)/verdict"), Handler.w_guided_verdict),
    ("POST", re.compile(r"/guided/([^/]+)/abort"), Handler.w_guided_abort),
]


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """One thread per connection, and only so many of them (judge 09-24, finding 1): a blind
    flood of connections from a local page gets an immediate 503, not a thread each."""
    daemon_threads = True
    allow_reuse_address = True
    conn_slots = None
    waiters = None
    _BUSY_BODY = b'{"error": "busy", "note": "too many connections"}\n'
    BUSY = (b"HTTP/1.0 503 Service Unavailable\r\nContent-Type: application/json\r\n"
            b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(_BUSY_BODY)) + _BUSY_BODY

    def process_request(self, request, client_address):
        if not self.conn_slots.acquire(blocking=False):
            try:
                request.sendall(self.BUSY)
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.conn_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.conn_slots.release()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="ndt serve", description=(
        "A local HTTP API over ndt's lab verbs, on %s only. API under %s/." % (BIND, API)))
    ap.add_argument("--owner", default=os.environ.get("NDT_OWNER"),
                    help="the NDT_OWNER every ndt call carries (default: $NDT_OWNER; required)")
    ap.add_argument("--port", type=int, default=8765, help="default 8765; 0 picks a free one")
    ap.add_argument("--ndt", default=os.path.expanduser("~/.local/bin/ndt"),
                    help="the ndt to run (default ~/.local/bin/ndt -- the main checkout's)")
    ap.add_argument("--state-dir", default=default_state_dir(), help="jobs are kept here")
    ap.add_argument("--token-file", default=default_token_file())
    ap.add_argument("--app-root", action="append", default=None,
                    help="a directory 'up --app' packages must lie under (repeatable; "
                         "default <repo>/.test_run/packages)")
    ap.add_argument("--read-timeout", type=int, default=60, help="seconds a read-only ndt call may take")
    ap.add_argument("--read-queue-wait", type=int, default=30,
                    help="seconds a third read-only call waits for one of the two slots before 503")
    ap.add_argument("--max-connections", type=int, default=32, help="connections served at once")
    ap.add_argument("--max-waiters", type=int, default=4, help="?wait= long-polls at once")
    a = ap.parse_args(argv)

    if not a.owner or not OWNER_RE.match(a.owner):
        ap.error("--owner (or $NDT_OWNER) is required: 1-64 of [A-Za-z0-9._-]")
    ndt_real = os.path.realpath(a.ndt)
    if not os.path.isfile(ndt_real) or not os.access(ndt_real, os.X_OK):
        ap.error("not an executable: %s" % a.ndt)

    cfg = Config()
    cfg.owner, cfg.ndt, cfg.ndt_real = a.owner, os.path.abspath(a.ndt), ndt_real
    cfg.repo = os.path.dirname(os.path.dirname(os.path.dirname(ndt_real)))
    cfg.apps = app_names_of(ndt_real)
    cfg.app_roots = [os.path.abspath(r) for r in (a.app_root or [os.path.join(cfg.repo, ".test_run", "packages")])]
    cfg.env, cfg.stripped = child_env(a.owner)
    cfg.read_timeout = a.read_timeout
    cfg.read_queue_wait = a.read_queue_wait
    cfg.ndt_sha_at_start = jobs.file_sha256(ndt_real)
    cfg.state_dir = os.path.abspath(a.state_dir)
    cfg.token_file = os.path.abspath(a.token_file)

    private_dir(cfg.state_dir)
    private_dir(os.path.dirname(cfg.token_file))
    locks = [hold_lock(os.path.join(cfg.state_dir, "serve.lock")), hold_lock(cfg.token_file + ".lock")]
    cfg.store = jobs.JobStore(cfg.state_dir, verbs.meaning)
    cfg.reads = jobs.ReadLog(cfg.state_dir)
    cfg.grid = cells.Grid(cfg.repo, cfg.env)
    cfg.guided = cells.Guided(cfg.state_dir)
    Handler.cfg = cfg
    try:
        httpd = Server((BIND, a.port), Handler)
    except OSError as e:
        raise SystemExit("ndt serve: cannot listen on %s:%d: %s" % (BIND, a.port, e))
    httpd.conn_slots = threading.BoundedSemaphore(a.max_connections)
    httpd.waiters = threading.BoundedSemaphore(a.max_waiters)
    cfg.token = write_token(cfg.token_file)   # only after the bind: a server that could not
    #                                           start must not replace a running one's token

    def reaper():
        while True:
            time.sleep(1)
            cfg.store.reap()
    threading.Thread(target=reaper, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=httpd.shutdown, daemon=True).start())

    port = httpd.server_address[1]
    print("ndt serve: listening on http://%s:%d%s/  owner=%s" % (BIND, port, API, cfg.owner))
    print("  ndt      %s -> %s (sha256 %s)" % (cfg.ndt, ndt_real, jobs.file_sha256(ndt_real)[:16]))
    print("  token    %s (header %s)" % (cfg.token_file, TOKEN_HEADER))
    print("  jobs     %s" % cfg.store.root)
    if cfg.stripped:
        print("  dropped  %s -- not passed to ndt" % " ".join(cfg.stripped))
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        for fd in locks:
            os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
