#!/usr/bin/env python3
"""ndt serve -- a local HTTP API over `ndt`'s lab verbs, and the one page that drives it.

[Co-developed with claude code -- Adam]

    ndt serve --owner adam                     # through the ndt verb (same tree's ndt)
    python3 tools/ndt_serve/serve.py --owner adam [--port 8765] [--ndt ~/.local/bin/ndt]

It listens on 127.0.0.1 only, for one user, with no login (Adam's ruling, 09-24). The API is
under /api/v1/. The page (the GUI cut, Adam's Q2 ruling 09-27) is three fixed files -- /,
/app.js, /app.css from static/ -- read once at start, served with no token and running nothing;
every other path is 404.

The design red lines (TICKET section 3), and where each one lives:

  1. loopback only     BIND below; the Host header must be 127.0.0.1:<port> or localhost:<port>
                       (DNS rebinding); no CORS header is ever sent.
  2. CSRF              every request but GET /health carries the token from
                       ~/.config/ndt-serve/token (0600) in the X-NDT-Token header -- a custom header,
                       so no browser sends it cross-origin without a preflight this server never
                       answers -- and an Origin header, when present, must be this server's; a POST
                       also needs a JSON body. 🔴 GETs are gated too (judge 09-24, finding 1): a
                       "read" is not side-effect free -- `ndt status --check` POSTs three lock
                       probes to the kernel (ndt:9416-9431) -- so an <img> in any page must not be
                       able to start one.
  3. whitelist         verbs.py builds every argv; there is no shell on any path.
  4. thin shell        ndt's rc is passed through untouched, with a sentence from ndt help beside
                       it; stdout and stderr are kept byte for byte.
  5. long jobs         jobs.py / runner.py: async, one state-changing job at a time, detached with
                       setsid, recorded on disk.
  6. no pkill -f       nothing here signals anything but a process group this process itself
                       created, for a call that ran past its timeout: a read-only `ndt status` or
                       `ndt apps` (run_read, below), or a grid call -- `run_cells.sh --list` or
                       a cell's `judge` (cells.Grid._run). Two places, one shape.
  7. identity          --owner (or $NDT_OWNER) is set once, and every ndt call carries it.

The page gets the token the way Adam ruled (Q3, 09-27): a ONE-TIME key in the URL's #fragment,
which the page trades for the token (POST /session) and then wipes from the address bar. The
token itself is never in a URL -- a browser may keep a URL in its history before the page can
wipe it, and a used key is worth nothing there. The start-up URL goes to a terminal only; when
stdout is a file (a log keeps what it is sent) it goes to a 0600 file beside the token instead.
`serve.py url` asks the running server for another.
"""
import argparse
import fcntl
import hmac
import http.client
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
GUI_NOTE = "outside /api/v1/ there is only the page: /, /app.js and /app.css"
# The page's three files, and nothing else: a path is looked up, never joined onto a directory.
STATIC_DIR = os.path.join(HERE, "static")
STATIC = {"/": ("index.html", "text/html; charset=utf-8"),
          "/app.js": ("app.js", "text/javascript; charset=utf-8"),
          "/app.css": ("app.css", "text/css; charset=utf-8")}
# On every answer, the page's first: no inline script, no other origin, no frame around it.
SECURITY_HEADERS = (
    ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
                                "img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
    ("X-Frame-Options", "DENY"),
    ("Referrer-Policy", "no-referrer"),
)
NONCE_TTL_S = 600          # a one-time page URL is good for this long, and for one use
MAX_NONCES = 8             # outstanding at once; minting another forgets the oldest
NONCE_RE = re.compile(r"[A-Za-z0-9_-]{16,64}")


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
    """A fresh token on every start, mode 0600, written atomically."""
    token = secrets.token_urlsafe(32)
    write_private(path, token + "\n")
    return token


def write_private(path, text):
    """Mode 0600, written atomically: the token, the one-time page URL, serve.json. rename()
    replaces a symlink at the path instead of writing through it."""
    tmp = "%s.tmp.%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, text.encode())
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def load_static():
    """The page's three files, read once: the page served is the page that was there at start,
    as every ndt call runs the ndt that was there at start."""
    out = {}
    for path, (name, ctype) in STATIC.items():
        try:
            with open(os.path.join(STATIC_DIR, name), "rb") as f:
                out[path] = (f.read(), ctype)
        except OSError as e:
            raise SystemExit("ndt serve: cannot read the page's %s: %s" % (name, e))
    return out


def page_url(port, nonce):
    return "http://%s:%d/#k=%s" % (BIND, port, nonce)


class Nonces:
    """One-time keys for the page URL (SCOPE section 3). A key is good once, for `ttl` seconds,
    and only while it is one of the MAX_NONCES newest -- a used, expired or forgotten key and a
    key never minted are the same answer: 403."""

    def __init__(self, ttl):
        self.ttl = ttl
        self.lock = threading.Lock()
        self.book = []   # [(key, deadline)], oldest first

    def mint(self):
        key = secrets.token_urlsafe(32)
        with self.lock:
            now = time.monotonic()
            self.book = [(k, t) for k, t in self.book if t > now][-(MAX_NONCES - 1):]
            self.book.append((key, now + self.ttl))
        return key

    def take(self, key):
        """True once for a live key; the key is gone after it, whatever the answer."""
        with self.lock:
            now = time.monotonic()
            for i, (k, t) in enumerate(self.book):
                if hmac.compare_digest(k.encode(), key.encode()):
                    del self.book[i]
                    return t > now
        return False


def listener_owned_by(pid, port):
    """Is `pid` the process listening on 127.0.0.1:<port>? Read from /proc: the listening
    socket's inode in /proc/net/tcp, found among pid's own fds -- by the pid serve.json names,
    never by a process name. A server that died leaves serve.json behind, and whoever binds its
    port next must not be handed the token."""
    want = "0100007F:%04X" % port   # /proc/net/tcp: address and port in hex, the address as stored
    inodes = set()
    try:
        with open("/proc/net/tcp") as f:
            for line in list(f)[1:]:
                cols = line.split()
                if len(cols) > 9 and cols[1] == want and cols[3] == "0A":   # 0A = LISTEN
                    inodes.add("socket:[%s]" % cols[9])
        fds = os.listdir("/proc/%d/fd" % pid)
    except OSError:
        return False
    for fd in fds:
        try:
            if os.readlink("/proc/%d/fd/%s" % (pid, fd)) in inodes:
                return True
        except OSError:
            continue
    return False


def url_command(token_file):
    """`ndt serve url`: a new one-time page URL from the RUNNING server, which alone can mint
    one. It reads the token file and serve.json beside it, checks that serve.json's pid really
    is the process listening on its port, and only then sends the token there."""
    conf = os.path.dirname(token_file)
    try:
        with open(os.path.join(conf, "serve.json")) as f:
            info = json.load(f)
        with open(token_file) as f:
            token = f.read().strip()
    except (OSError, ValueError) as e:
        raise SystemExit("ndt serve url: no running server's files in %s (%s)" % (conf, e))
    port, pid = info.get("port"), info.get("pid")
    if not (isinstance(port, int) and isinstance(pid, int)):
        raise SystemExit("ndt serve url: %s names no port and pid" % os.path.join(conf, "serve.json"))
    if not listener_owned_by(pid, port):
        raise SystemExit("ndt serve url: pid %d (serve.json) is not the process listening on %s:%d -- "
                         "is ndt serve running? The token was not sent." % (pid, BIND, port))
    conn = http.client.HTTPConnection(BIND, port, timeout=10)
    try:
        conn.request("POST", API + "/session/new", body=b"{}", headers={
            "Host": "%s:%d" % (BIND, port), TOKEN_HEADER: token, "Content-Type": "application/json"})
        r = conn.getresponse()
        raw = r.read()
    except OSError as e:
        raise SystemExit("ndt serve url: %s:%d did not answer: %s" % (BIND, port, e))
    finally:
        conn.close()
    try:
        j = json.loads(raw)
    except ValueError:
        j = {}
    if r.status != 201 or not isinstance(j.get("url"), str):
        raise SystemExit("ndt serve url: the server answered %d: %s" % (r.status, raw[:300].decode("utf-8", "replace")))
    print(j["url"])
    sys.stderr.write("one use, good for %d min\n" % (j.get("expires_in_s", 0) // 60))
    return 0


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


class DryRun(Exception):
    """`{"dry_run": true}` on a write that allows it (DRY_RUN_OK): raised where the job would
    be spawned -- after the whitelist built the argv, before anything is made or run -- and
    answered with that argv. The page shows it in its confirm dialog and builds no argv itself."""

    def __init__(self, kind, argv, cell=None, note=None):
        super().__init__(kind)
        confirm, own_claim = confirm_policy(kind, cell)
        self.body = {"dry_run": True, "kind": kind, "argv": argv, "confirm": confirm,
                     "needs_own_claim": own_claim,
                     "note": note or "nothing was run; whether the slot is free and the claim is yours "
                                     "is decided when it runs, by this server and by ndt"}
        if cell is not None:
            self.body.update(cell=cell["name"], requires=cell["requires"],
                             writes_shared_state=cell.get("writes_shared_state"))


def confirm_policy(kind, cell=None):
    """How hard the page makes Adam confirm a write (SCOPE section 2): "typed" or "plain", and
    whether it waits for his own claim first (section 2.4). The page keeps no table of its own;
    it adds only the measuring rule (typed whenever measuring is not `nothing`). A UI guard --
    ndt and this server still decide."""
    if kind in ("up", "down"):
        return "typed", True
    if kind in ("apps.start", "apps.stop"):
        return "plain", True
    if kind == "cells.run":
        lab = cell is None or cell["requires"] != "none"
        return ("typed" if lab else "plain"), lab
    return "plain", False   # claim, release, a walk's read-only step


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
        for k, v in SECURITY_HEADERS:
            self.send_header(k, v)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _handle(self, method):
        self.route, self.dry_run = None, False
        try:
            self._check_host()
            url = urllib.parse.urlsplit(self.path)
            path, query = url.path, urllib.parse.parse_qs(url.query)
            if path in STATIC:
                # the page: after the Host check, before any token -- it runs nothing
                if method != "GET":
                    raise HttpError(405, "method not allowed", allowed=["GET"])
                self._send(200, raw=self.cfg.static[path][0], ctype=self.cfg.static[path][1])
                return
            if path != API and not path.startswith(API + "/"):
                raise HttpError(404, "not found", note=GUI_NOTE)
            route, args = self._route(method, path[len(API):] or "/")
            self.route = route
            if method == "GET" and route is not Handler.r_health:
                self._check_read()
            route(self, query, *args)
        except DryRun as d:
            self._send(200, d.body)
        except HttpError as e:
            self._send(e.code, e.body, headers={"Allow": ", ".join(e.body.get("allowed") or ("GET", "POST"))}
                       if e.code == 405 else None)
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
        """A state-changing request: the token, then the Origin, then a JSON body. A route in
        DRY_RUN_OK takes `dry_run` out of the body here; on any other route it stays in, and the
        route's whitelist refuses it as an unknown field -- a preview is never a write's default."""
        self._check_token()
        self._check_origin()
        body = self._json_body()
        if self.route in DRY_RUN_OK and "dry_run" in body:
            self.dry_run = body.pop("dry_run")
            if not isinstance(self.dry_run, bool):
                raise HttpError(400, "refused", note="dry_run must be true or false")
        return body

    def _json_body(self):
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

    def r_lab(self, query):
        """What the page confirms a write against, read afresh before every one (SCOPE 2.1):
        plain `ndt status` -- never --check, which POSTs lock probes -- with its claim, measuring
        and declared rows VERBATIM, and the only two readings the page may act on: is the claim
        ndt's own-claim form, whole (OWN_CLAIM, as a cell run's precheck), and is measuring
        exactly `nothing`. A read stopped at its timeout is not a reading: both are false."""
        r = run_read(self.cfg, "status", verbs.argv_status(False), self.cfg.read_timeout)
        if r is None:
            raise HttpError(503, "busy", note="two read-only ndt calls were running for %d s" % self.cfg.read_queue_wait)
        read = r["rc_class"] != "timeout"
        claim, measuring = claim_of(r["stdout"]), row_of(MEASURING_LINE, r["stdout"])
        r.update(claim=claim, measuring=measuring, declared=row_of(DECLARED_LINE, r["stdout"]),
                 claim_is_yours=read and bool(OWN_CLAIM.fullmatch(claim or "")),
                 measuring_is_nothing=read and measuring == "nothing",
                 busy=self.cfg.store.holding_the_slot())
        self._send(200, r)

    def r_meta(self, query):
        """What the page's forms offer, from the tables that decide it -- the page has none."""
        self._send(200, {"owner": self.cfg.owner, "apps": self.cfg.apps,
                         "up_hosts": {k: list(v) for k, v in verbs.UP_HOSTS.items()},
                         "max_claim_minutes": verbs.MAX_CLAIM_MINUTES,
                         "default_claim_minutes": verbs.DEFAULT_CLAIM_MINUTES,
                         "max_note_chars": verbs.MAX_NOTE_CHARS})

    # --- the page's way in (SCOPE section 3) ---
    def w_session(self, query):
        """A one-time key from the page's URL, for the token. There is no token to check yet, so
        the Origin is REQUIRED here and must be this very origin: a browser sends it on every
        POST and no page can forge it, and the key comes only in a JSON body."""
        if query:
            raise HttpError(400, "refused", note="the key goes in the JSON body, never in the URL")
        origin = (self.headers.get("Origin") or "").lower()
        if origin != "http://" + self.headers["Host"].strip().lower():
            raise HttpError(403, "origin", note="the key is traded only from this server's own page")
        body = self._json_body()
        key = body.get("nonce")
        if set(body) != {"nonce"} or not isinstance(key, str) or not NONCE_RE.fullmatch(key):
            raise HttpError(400, "refused", note='the body is {"nonce": "<the key from the URL>"}')
        if not self.cfg.nonces.take(key):
            raise HttpError(403, "nonce", note="this link was used already or has expired -- "
                                               "'ndt serve url' prints a new one")
        self._send(200, {"token": self.cfg.token, "owner": self.cfg.owner})

    def w_session_new(self, query):
        """A new one-time page URL, for the token holder (`ndt serve url`)."""
        _whitelisted(verbs.no_fields, self._check_write())
        self._send(201, {"url": page_url(self.server.server_address[1], self.cfg.nonces.mint()),
                         "expires_in_s": self.cfg.nonces.ttl})

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

    def _spawn(self, kind, argv, body, env=None, extra=None, precheck=None):
        """Take the one slot and start a job, or 409. Every state-changing path comes here.
        `precheck` runs INSIDE the slot, after the busy check and before the spawn, so what it
        read is still true when the job starts -- no other job of this server can move it."""
        cfg = self.cfg
        if self.dry_run:
            raise DryRun(kind, argv)
        with SLOT:
            busy = cfg.store.holding_the_slot()
            if busy is not None:
                raise HttpError(409, "busy", note="one state-changing job at a time", job=busy)
            if precheck is not None:
                precheck()
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
        confirmed = _whitelisted(verbs.cell_run_body, body)
        job_id = self._spawn_cell_run(self._cell(name), body, confirmed)
        self._send(202, {"job": self._job(job_id), "links": _links(job_id)})

    def _need_confirmation(self, cell, confirmed):
        if cell.get("writes_shared_state") and confirmed is not True:
            raise HttpError(400, "confirm", note="this cell writes shared state -- " + cell["writes_shared_state"] +
                            ' Send {"confirm_shared_state_write": true} to run it anyway.')

    def _spawn_cell_run(self, cell, body, confirmed):
        """A cell run. 🔴 A cell that needs the lab runs only under THIS owner's claim (judge r2
        finding 1). Written 09-24, when ndt's OVS `up` did not refuse under a foreign claim; since
        trunk 68ace017 it does, on both planes (up_ovs calls guard_up_lab_free, ndt:4362). The check
        stays because a cell is more than its `up`: some set netem, send kill -TERM or write the
        host-count knob, and none of that asks ndt's guard -- and under a foreign claim the
        restore's `down` is refused (rc 5), so what the cell left stays."""
        cfg = self.cfg
        raw_root = os.path.join(cfg.state_dir, "cells-raw", cell["name"] + "-" + secrets.token_hex(4))
        if self.dry_run:
            # before the raw directory (a preview makes nothing) and before the confirmation it
            # shows: the dialog is where Adam gives it
            raise DryRun("cells.run", cfg.grid.run_argv(cell["name"], raw_root), cell)
        self._need_confirmation(cell, confirmed)
        os.makedirs(raw_root, mode=0o700)
        return self._spawn("cells.run", cfg.grid.run_argv(cell["name"], raw_root), body,
                           env=cfg.grid.env, extra={"cell": cell["name"], "raw_root": raw_root},
                           precheck=self._require_own_claim if cell["requires"] != "none" else None)

    def _require_own_claim(self):
        """Read `ndt status`'s claim line (ndt:5786 claim_line) and go on only if it is ndt's
        own-claim form, exactly. This reads ndt's answer; it does not decide anything ndt decides.

        🔴 Exact, not a prefix (intake judge 09-26, finding 2): claim_line prints somebody else's
        claim as `<owner> -- ...`, and an owner is any string -- `yours-x`, or one that spells the
        whole own form. What it cannot tell apart is an owner named exactly `yours`: ndt prints
        that claim as it prints your own (and its own `--check` reads `yours*` the same way)."""
        r = run_read(self.cfg, "status", verbs.argv_status(False), self.cfg.read_timeout)
        # [Co-developed with claude code -- Adam] two reasons the claim was not read, each named
        # (intake judge 09-26, finding 5) -- neither is a claim, and neither runs the cell
        if r is None:
            raise HttpError(409, "claim", note="the claim was not read: no read slot came free within %d s "
                            "(two read-only ndt calls held both), so ndt status never ran; a cell that needs "
                            "the lab is not run on a guess -- try again" % self.cfg.read_queue_wait)
        if r["rc_class"] == "timeout":
            raise HttpError(409, "claim", note="the claim was not read: ndt status did not answer within %d s "
                            "and was stopped, and a stopped read is not a reading; a cell that needs the lab "
                            "is not run on a guess" % self.cfg.read_timeout, read=r["read"]["id"])
        line = claim_of(r["stdout"])
        if not OWN_CLAIM.fullmatch(line or ""):
            raise HttpError(409, "claim", note="a cell that needs the lab runs only under your own claim -- "
                            "POST %s/claim first" % API, claim=line, read=r["read"]["id"])

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
        confirmed = _whitelisted(verbs.cell_run_body, body)
        cell = self._cell(name)
        self._need_confirmation(cell, confirmed)
        self._send(201, {"walk": self._walk_view(self.cfg.guided.create(cell, confirmed))})

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
            if self.dry_run and st["step"] in READ_STEPS:
                raise DryRun("guided." + st["step"], None, note=READ_STEPS[st["step"]])
            self._do_step(walk, st)   # a dry run of a claim, run or release step stops at its spawn
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
            why = None
            if r.get("timed_out"):
                why = "the judge did not answer within %d s and was stopped" % cfg.grid.timeout
            elif not ok:
                why = ("old/ no longer judges FAIL -- the red this cell was built on cannot be shown"
                       if st["step"] == "old" else "new/ does not judge PASS")
            st["result"] = {"ok": ok and not r.get("timed_out"), "judge": r, "why": why}
        elif st["step"] == "status":
            r = run_read(cfg, "status", verbs.argv_status(False), cfg.read_timeout)
            if r is None:
                raise HttpError(503, "busy", note="two read-only ndt calls are already running")
            st["result"] = dict(r, ok=r["rc"] == 0)
        elif st["step"] == "claim":
            st["job"] = self._spawn("claim", [cfg.ndt_real] + verbs.argv_claim(
                {"minutes": 30, "note": "guided walk %s (%s)" % (walk["id"], name)}), {"guided": walk["id"]})
        elif st["step"] == "run":
            # the claim is read again here, inside the slot: another tab's walk may have
            # released it since this walk's claim step (judge r2 finding 3)
            try:
                st["job"] = self._spawn_cell_run(cell, {"guided": walk["id"]},
                                                 walk.get("confirmed_shared_state_write") is True)
            except HttpError as e:
                if e.body.get("error") != "claim":
                    raise
                st["result"] = {"ok": False, "why": "claim: the run was not started -- %s (claim line: %s)" % (
                    e.body.get("note"), e.body.get("claim"))}
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


# A walk's steps that spawn no job, and what the page's dialog says each one does.
READ_STEPS = {"old": "a read-only step: the cell's own judge reads its old/ fixture (the red it was built on)",
              "new": "a read-only step: the cell's own judge reads its new/ fixture",
              "status": "a read-only step: plain ndt status",
              "compare": "a read-only step: the run's result beside old/'s, row by row"}

CLAIM_LINE = re.compile(r"^  claim\s+(.*?)\s*$", re.M)
# ndt status's measuring and declared rows (cmd_status, ndt:6760-6787): `measuring  nothing`, or
# the first process in flight; `declared` only when a claim says measuring=.
MEASURING_LINE = re.compile(r"^  measuring\s+(.*?)\s*$", re.M)
DECLARED_LINE = re.compile(r"^  declared\s+(.*?)\s*$", re.M)
# ndt's own-claim value, whole: `printf 'yours -- %dm left (until %s)\n'` (ndt:5799, claim_line),
# the time from `date +%H:%M:%S`. [Co-developed with claude code -- Adam]
OWN_CLAIM = re.compile(r"yours -- [0-9]+m left \(until [0-9]{2}:[0-9]{2}:[0-9]{2}\)")


def claim_of(status_stdout):
    """The value of the `claim` row of `ndt status` (`  claim          yours -- 30m left ...`),
    or None when there is no such row. `prev claim` is a different row and does not match."""
    m = CLAIM_LINE.search(status_stdout or "")
    return m.group(1) if m else None


def row_of(pattern, status_stdout):
    m = pattern.search(status_stdout or "")
    return m.group(1) if m else None


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
    ("GET", re.compile(r"/lab"), Handler.r_lab),
    ("GET", re.compile(r"/meta"), Handler.r_meta),
    ("POST", re.compile(r"/session"), Handler.w_session),
    ("POST", re.compile(r"/session/new"), Handler.w_session_new),
]
# The writes that answer {"dry_run": true} with their argv. Every other POST refuses the field.
DRY_RUN_OK = {Handler.w_up, Handler.w_down, Handler.w_claim, Handler.w_release, Handler.w_app,
              Handler.w_cell_run, Handler.w_guided_next}


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """One thread per connection, and only so many of them (judge 09-24, finding 1): a blind
    flood of connections from a local page gets an immediate 503, not a thread each."""
    daemon_threads = True
    allow_reuse_address = True
    # socketserver's default listen backlog is 5: a burst of 20 connections (a page that fetches
    # in parallel does that) had one reset by the kernel before accept() ever saw it -- 1 in 10
    # runs of the concurrency case, 09-24 23:3x. The cap on connections SERVED is conn_slots.
    request_queue_size = 64
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
    ap.add_argument("--nonce-ttl", type=int, default=NONCE_TTL_S,
                    help="seconds a one-time page URL stays good (default %d)" % NONCE_TTL_S)
    ap.add_argument("command", nargs="?", choices=["url"],
                    help="url: print a new one-time URL of the running server's page (it reads "
                         "--token-file and serve.json beside it)")
    a = ap.parse_args(argv)

    if a.command == "url":
        return url_command(os.path.abspath(a.token_file))
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
    cfg.static = load_static()
    cfg.nonces = Nonces(a.nonce_ttl)

    private_dir(cfg.state_dir)
    private_dir(os.path.dirname(cfg.token_file))
    locks = [hold_lock(os.path.join(cfg.state_dir, "serve.lock")), hold_lock(cfg.token_file + ".lock")]
    cfg.store = jobs.JobStore(cfg.state_dir, verbs.meaning)
    cfg.reads = jobs.ReadLog(cfg.state_dir)
    cfg.grid = cells.Grid(cfg.repo, cfg.env, timeout=cfg.read_timeout)
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
    port = httpd.server_address[1]
    conf = os.path.dirname(cfg.token_file)
    write_private(os.path.join(conf, "serve.json"),
                  json.dumps({"port": port, "pid": os.getpid(), "owner": cfg.owner}) + "\n")

    def reaper():
        while True:
            time.sleep(1)
            cfg.store.reap()
    threading.Thread(target=reaper, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=httpd.shutdown, daemon=True).start())

    print("ndt serve: listening on http://%s:%d%s/  owner=%s" % (BIND, port, API, cfg.owner))
    print("  ndt      %s -> %s (sha256 %s)" % (cfg.ndt, ndt_real, jobs.file_sha256(ndt_real)[:16]))
    print("  token    %s (header %s)" % (cfg.token_file, TOKEN_HEADER))
    print("  jobs     %s" % cfg.store.root)
    # The page's URL carries a one-time key: to a terminal it is printed; to anything else (a log
    # keeps what it is sent, and ours do) it goes to a 0600 file and only the file's name is printed.
    url = page_url(port, cfg.nonces.mint())
    if sys.stdout.isatty():
        print("  page     %s" % url)
        print("           one use, good for %d min; 'ndt serve url' prints another" % (a.nonce_ttl // 60))
    else:
        url_file = os.path.join(conf, "url")
        write_private(url_file, url + "\n")
        print("  page     the one-time URL is in %s (0600): stdout is not a terminal" % url_file)
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
