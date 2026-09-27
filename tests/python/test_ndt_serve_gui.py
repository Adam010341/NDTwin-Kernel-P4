#!/usr/bin/env python3
"""ndt serve, the GUI cut: what the server does for the page, and what the page's script may do.

[Co-developed with claude code -- Adam]

Adam's rulings (09-27 13:2x): the page is served by ndt serve itself at / (Q2), and the token
reaches it through a one-time URL #fragment, kept in memory only (Q3). The orchestrator's review
of doc/audit/2026-09-27_ndt-serve-gui/SCOPE.md made the fragment a ONE-TIME KEY traded for the
token. These cases pin the server's side of that, against the stub ndt of test_ndt_serve.Serve:

  * the page's three files need no token, run nothing, obey the Host check and carry a CSP that
    allows no inline script, no other origin and no frame;
  * the start-up URL carries a key, never the token, and goes to a terminal or to a 0600 file --
    never into a log; a key trades once, within its time, from this very origin, in a JSON body;
  * `serve.py url` sends the token only to the process serve.json names, and only if that
    process holds the port;
  * GET /lab is plain `ndt status` with its rows verbatim and two readings: the own-claim form,
    whole, and measuring exactly `nothing`; GET /meta is the server's own tables;
  * {"dry_run": true} answers the argv the write would run and runs, spawns and makes nothing --
    and only where it is offered;

and PageLint holds static/app.js and static/index.html to what the page may do (SCOPE section 6):
one door out, every write through the confirm dialog, nothing in storage, no HTML from strings.
What only a browser can show is tests/browser/test_ndt_serve_page.py (headless Chrome, under the
build guard) -- kept out of this directory because CI has no Chrome and the L1 lane fails a skip.

Every server here gets its own HOME, so no default path reaches the real ~/.config/ndt-serve.

    python3 tests/python/test_ndt_serve_gui.py
    NDT_SERVE_UNDER_TEST=/tmp/x/ndt_serve python3 tests/python/test_ndt_serve_gui.py   # a mutant

tests/shell/mutate_ndt_serve.sh (the G series) is this file's mutation gate.
"""
import glob
import importlib.util
import json
import os
import pty
import re
import select
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_ndt_serve as base  # noqa: E402
import test_ndt_serve_cells as grid  # noqa: E402
from test_ndt_serve import tearDownModule  # noqa: E402,F401 -- the same leftover-server sweep

SERVE_PY = os.path.join(base.SERVE_DIR, "serve.py")
STATIC = os.path.join(base.SERVE_DIR, "static")
KEY = r"[A-Za-z0-9_-]{43}"

_spec = importlib.util.spec_from_file_location("verbs_under_test", os.path.join(base.SERVE_DIR, "verbs.py"))
verbs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verbs)

STATUS_FULL = ("lab\n"
               "  claim          yours -- 30m left (until 23:59:00)\n"
               "  prev claim     orch-0924 (until 20:00:00)\n"
               "  declared       iperf3 matrix   (claim measuring=; 'ndt check' refuses while set)\n"
               "  measuring      nothing\n")


def private_home(s):
    """The server's HOME inside its own temp tree; no XDG_* of the shell running the tests."""
    s.home = os.path.join(s.tmp, "home")
    os.makedirs(s.home, exist_ok=True)
    s.env["HOME"] = s.home
    for k in ("XDG_CONFIG_HOME", "XDG_STATE_HOME"):
        s.env.pop(k, None)


class Gui:
    """What a GUI case needs on top of a Serve: the one-time URL, and trading its key."""

    def conf(self):
        return os.path.dirname(self.token_file)

    def url_file(self):
        return os.path.join(self.conf(), "url")

    def key(self):
        m = re.fullmatch(r"http://127\.0\.0\.1:%d/#k=(%s)\n" % (self.port, KEY), base._read(self.url_file()))
        assert m, base._read(self.url_file())
        return m.group(1)

    def trade(self, key, origin="default", host="default", ctype="application/json", query="", body=None):
        if origin == "default":
            origin = "http://127.0.0.1:%d" % self.port
        headers = {"Origin": origin} if origin is not None else {}
        st, j, h, _ = self.request("POST", "/api/v1/session" + query, body if body is not None else {"nonce": key},
                                   token=None, host=host, ctype=ctype, headers=headers)
        return st, j

    def jobs(self):
        st, j, _, _ = self.get("/jobs")
        assert st == 200, (st, j)
        return j["jobs"]


class GuiServe(Gui, base.Serve):
    def __init__(self, **kw):
        super().__init__(**kw)
        private_home(self)


class GuiGridServe(Gui, grid.GridServe):
    def __init__(self, **kw):
        super().__init__(**kw)
        private_home(self)


def page_file(name):
    with open(os.path.join(STATIC, name), "rb") as f:
        return f.read()


def csp_of(headers):
    out = {}
    for d in headers.get("content-security-policy", "").split(";"):
        parts = d.split()
        if parts:
            out[parts[0]] = parts[1:]
    return out


# --- the page's three files --------------------------------------------------------------------

class Page(unittest.TestCase):
    def setUp(self):
        self.s = GuiServe().start()

    def tearDown(self):
        self.s.close()

    def test_page_files_need_no_token_and_run_nothing(self):
        for path, name, ctype in (("/", "index.html", "text/html"), ("/app.js", "app.js", "text/javascript"),
                                  ("/app.css", "app.css", "text/css"), ("/?x=1", "index.html", "text/html")):
            st, _, h, payload = self.s.request("GET", path, token=None)
            self.assertEqual(st, 200, path)
            self.assertTrue(h["content-type"].startswith(ctype), (path, h["content-type"]))
            self.assertEqual(payload, page_file(name), path)
        self.assertEqual(self.s.calls(), [], "a page file ran ndt")
        self.assertEqual(self.s.jobs(), [])

    def test_every_answer_carries_a_csp_with_no_inline_script_and_no_other_origin(self):
        for path in ("/", "/app.js", "/app.css", "/api/v1/health"):
            st, _, h, _ = self.s.request("GET", path, token=None)
            self.assertEqual(st, 200, path)
            csp = csp_of(h)
            for directive, want in (("default-src", ["'none'"]), ("script-src", ["'self'"]),
                                    ("style-src", ["'self'"]), ("connect-src", ["'self'"]),
                                    ("img-src", ["'self'"]), ("base-uri", ["'none'"]), ("form-action", ["'none'"])):
                self.assertEqual(csp.get(directive), want, (path, directive, h.get("content-security-policy")))
            self.assertNotIn("unsafe", h["content-security-policy"], path)
            self.assertEqual(h.get("referrer-policy"), "no-referrer", path)
            self.assertEqual(h.get("cache-control"), "no-store", path)
            self.assertEqual(h.get("x-content-type-options"), "nosniff", path)

    def test_the_page_cannot_be_framed(self):
        for path in ("/", "/app.js"):
            _, _, h, _ = self.s.request("GET", path, token=None)
            self.assertEqual(csp_of(h).get("frame-ancestors"), ["'none'"], path)
            self.assertEqual(h.get("x-frame-options"), "DENY", path)

    def test_the_page_obeys_the_host_check(self):
        for host in ("evil.example:%d" % self.s.port, "127.0.0.1:%d" % (self.s.port + 1), None):
            st, j, _, payload = self.s.request("GET", "/", token=None, host=host)
            self.assertEqual(st, 403, host)
            self.assertEqual(j["error"], "host", host)
            self.assertNotIn(b"<html", payload)

    def test_the_page_is_get_only(self):
        for method in ("POST", "PUT", "DELETE", "HEAD"):
            st, _, h, payload = self.s.request(method, "/", body={}, token=None)
            self.assertEqual(st, 405, method)
            self.assertEqual(h.get("allow"), "GET", method)
            self.assertNotIn(b"<html", payload)


# --- the start-up URL --------------------------------------------------------------------------

def read_until(fd, pattern, timeout=15):
    buf = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if re.search(pattern, buf.decode("utf-8", "replace")):
                break
    return buf.decode("utf-8", "replace")


class StartupUrl(unittest.TestCase):
    def test_the_url_goes_to_a_0600_file_when_stdout_is_not_a_terminal(self):
        s = GuiServe().start()
        try:
            out = base._read(s.out)
            self.assertIn("the one-time URL is in %s (0600)" % s.url_file(), out)
            self.assertNotIn("#k=", out)
            self.assertNotIn(s.token(), out)
            self.assertNotIn(s.token(), base._read(s.out + ".err"))
            for p in (s.url_file(), os.path.join(s.conf(), "serve.json")):
                self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600, p)
            key = s.key()
            self.assertNotIn(s.token(), base._read(s.url_file()), "the URL carries the token")
            st, j = s.trade(key)
            self.assertEqual(st, 200, j)
            self.assertEqual(j["token"], s.token())
        finally:
            s.close()

    def test_the_url_is_printed_to_a_terminal_and_written_nowhere(self):
        s = GuiServe()
        master, slave = pty.openpty()
        try:
            with open(os.path.join(s.tmp, "tty.err"), "wb") as e:
                s.proc = subprocess.Popen(s.argv(), stdout=slave, stderr=e, stdin=subprocess.DEVNULL, env=s.env,
                                          start_new_session=True)
            base.STARTED.append(s.proc)
            os.close(slave)
            slave = None
            out = read_until(master, r"one use, good for")
            m = re.search(r"listening on http://127\.0\.0\.1:(\d+)/", out)
            self.assertTrue(m, out)
            s.port = int(m.group(1))
            m = re.search(r"page     http://127\.0\.0\.1:%d/#k=(%s)\r?\n" % (s.port, KEY), out)
            self.assertTrue(m, out)
            self.assertFalse(os.path.exists(s.url_file()), "a terminal got the URL, and a file too")
            self.assertNotIn(s.token(), out)
            st, j = s.trade(m.group(1))
            self.assertEqual(st, 200, j)
        finally:
            if slave is not None:
                os.close(slave)
            s.close()
            os.close(master)


# --- trading the key ---------------------------------------------------------------------------

class Session(unittest.TestCase):
    def setUp(self):
        self.s = GuiServe().start()

    def tearDown(self):
        self.s.close()

    def test_a_key_is_good_once(self):
        key = self.s.key()
        st, j = self.s.trade(key)
        self.assertEqual(st, 200, j)
        self.assertEqual(j["token"], self.s.token())
        st, j = self.s.trade(key)
        self.assertEqual((st, j["error"]), (403, "nonce"), j)
        self.assertNotIn("token", j)

    def test_a_key_expires(self):
        s = GuiServe(extra=["--nonce-ttl", "1"]).start()
        try:
            key = s.key()
            time.sleep(1.5)
            st, j = s.trade(key)
            self.assertEqual((st, j["error"]), (403, "nonce"), j)
        finally:
            s.close()

    def test_the_key_is_traded_only_from_this_very_origin(self):
        s, key = self.s, self.s.key()
        p = s.port
        for origin in (None, "null", "http://evil.example", "http://localhost:%d" % p,
                       "http://127.0.0.1:%d" % (p + 1), "https://127.0.0.1:%d" % p):
            st, j = s.trade(key, origin=origin)
            self.assertEqual((st, j["error"]), (403, "origin"), origin)
        st, j = s.trade(key, query="?nonce=" + key)
        self.assertEqual((st, j["error"]), (400, "refused"), j)
        for ctype in ("text/plain", "application/x-www-form-urlencoded"):
            st, j = s.trade(key, ctype=ctype)
            self.assertEqual(st, 415, (ctype, j))
        for body in ({"nonce": key, "x": 1}, {"nonce": [key]}, {"key": key}):
            st, j = s.trade(key, body=body)
            self.assertEqual((st, j["error"]), (400, "refused"), body)
        # none of those spent it -- and the same origin under its other name trades it
        st, j = s.trade(key, origin="http://localhost:%d" % p, host="localhost:%d" % p)
        self.assertEqual(st, 200, j)
        self.assertEqual(j["token"], s.token())

    def test_a_new_key_needs_the_token(self):
        st, j, _, _ = self.s.post("/session/new", token=None)
        self.assertEqual((st, j["error"]), (403, "token"), j)
        st, j, _, _ = self.s.post("/session/new", {"dry_run": True})
        self.assertEqual((st, j["error"]), (400, "refused"), j)
        st, j, _, _ = self.s.post("/session/new")
        self.assertEqual(st, 201, j)
        m = re.fullmatch(r"http://127\.0\.0\.1:%d/#k=(%s)" % (self.s.port, KEY), j["url"])
        self.assertTrue(m, j)
        self.assertEqual(j["expires_in_s"], 600)
        self.assertEqual(self.s.trade(m.group(1))[0], 200)
        self.assertEqual(self.s.trade(m.group(1))[0], 403)

    def test_only_the_newest_keys_are_kept(self):
        first = self.s.key()
        new = []
        for _ in range(8):
            st, j, _, _ = self.s.post("/session/new")
            self.assertEqual(st, 201, j)
            new.append(j["url"].split("#k=")[1])
        st, j = self.s.trade(first)
        self.assertEqual((st, j["error"]), (403, "nonce"), "a ninth key did not push out the oldest")
        self.assertEqual(self.s.trade(new[0])[0], 200)
        self.assertEqual(self.s.trade(new[-1])[0], 200)


# --- `serve.py url` / `ndt serve url` ----------------------------------------------------------

class UrlCommand(unittest.TestCase):
    def start_with_default_paths(self):
        """A server started WITHOUT --token-file: its files land under the temp HOME's
        ~/.config/ndt-serve, which is where `url` looks by default."""
        s = GuiServe()
        argv = s.argv()
        i = argv.index("--token-file")
        del argv[i:i + 2]
        s.token_file = os.path.join(s.home, ".config", "ndt-serve", "token")
        return s.start(argv=argv)

    def check_url_answer(self, s, r):
        self.assertEqual(r.returncode, 0, r.stderr)
        m = re.fullmatch(r"http://127\.0\.0\.1:%d/#k=(%s)\n" % (s.port, KEY), r.stdout)
        self.assertTrue(m, r.stdout)
        self.assertIn("one use", r.stderr)
        self.assertEqual(s.trade(m.group(1))[0], 200)
        self.assertEqual(s.trade(m.group(1))[0], 403)

    def test_url_prints_a_new_key_of_the_running_server(self):
        s = self.start_with_default_paths()
        try:
            self.assertTrue(os.path.isfile(s.token_file))
            r = subprocess.run([sys.executable, SERVE_PY, "url"], capture_output=True, text=True, env=s.env,
                               timeout=60)
            self.check_url_answer(s, r)
        finally:
            s.close()

    def test_ndt_serve_url_is_the_same_command(self):
        s = self.start_with_default_paths()
        try:
            r = subprocess.run([base.NDT, "serve", "url"], capture_output=True, text=True, env=s.env, timeout=60)
            self.check_url_answer(s, r)
        finally:
            s.close()

    def stranger(self):
        """A listener on 127.0.0.1 that records what it is sent: whoever bound a port after the
        server serve.json names. -> (port, what it got, stop)."""
        lsock = socket.socket()
        lsock.bind(("127.0.0.1", 0))
        lsock.listen(4)
        lsock.settimeout(0.2)
        got = []
        done = threading.Event()

        def serve():
            while not done.is_set():
                try:
                    c, _ = lsock.accept()
                except socket.timeout:
                    continue
                c.settimeout(2)
                try:
                    got.append(c.recv(65536))
                except OSError:
                    got.append(b"")
                c.close()
        t = threading.Thread(target=serve, daemon=True)
        t.start()

        def stop():
            done.set()
            t.join(5)
            lsock.close()
        return lsock.getsockname()[1], got, stop

    def url_against(self, s, port, pid):
        with open(os.path.join(s.conf(), "serve.json"), "w") as f:
            json.dump({"port": port, "pid": pid, "owner": base.OWNER}, f)
        return subprocess.run([sys.executable, SERVE_PY, "url", "--token-file", s.token_file],
                              capture_output=True, text=True, env=s.env, timeout=60)

    def test_url_sends_the_token_only_to_the_pid_that_holds_the_port(self):
        s = GuiServe().start()
        port, got, stop = self.stranger()
        try:
            r = self.url_against(s, port, s.proc.pid)   # the server's pid, alive -- not the port's holder
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertIn("is not the process listening", r.stderr)
            time.sleep(0.3)
            self.assertEqual(got, [], "the token went to a process serve.json does not name")
        finally:
            stop()
            s.close()

    def test_url_refuses_a_serve_json_whose_pid_is_gone(self):
        # judge G-N7 (fcd4f69a): the server died, serve.json stayed, somebody else holds its port
        s = GuiServe().start()
        port, got, stop = self.stranger()
        gone = subprocess.Popen([sys.executable, "-c", "pass"])
        gone.wait()
        try:
            self.assertFalse(os.path.exists("/proc/%d" % gone.pid), "the pid came back already")
            r = self.url_against(s, port, gone.pid)
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertIn("is not the process listening", r.stderr)
            time.sleep(0.3)
            self.assertEqual(got, [], "the token went to whoever holds a dead server's port")
        finally:
            stop()
            s.close()

    def test_url_with_no_server_says_so(self):
        s = GuiServe()
        try:
            os.makedirs(s.conf(), exist_ok=True)
            with open(s.token_file, "w") as f:
                f.write("x" * 43 + "\n")
            r = subprocess.run([sys.executable, SERVE_PY, "url", "--token-file", s.token_file],
                               capture_output=True, text=True, env=s.env, timeout=60)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("no running server's files", r.stderr)
            self.assertEqual(r.stdout, "")
        finally:
            s.close()

    def test_ndt_help_lists_serve_url(self):
        r = subprocess.run([base.NDT, "help"], capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, NDT_OWNER=base.OWNER))
        self.assertRegex(r.stdout + r.stderr, r"\n  serve url  +\S")


# --- GET /lab and GET /meta --------------------------------------------------------------------

class Lab(unittest.TestCase):
    def setUp(self):
        self.s = GuiServe().start()

    def tearDown(self):
        self.s.close()

    def lab(self, stdout, **kw):
        self.s.behave(status=dict({"stdout": stdout}, **kw))
        st, j, _, _ = self.s.get("/lab")
        self.assertEqual(st, 200, j)
        return j

    def test_lab_is_plain_status_with_its_rows_verbatim(self):
        j = self.lab(STATUS_FULL)
        self.assertEqual(j["claim"], "yours -- 30m left (until 23:59:00)")
        self.assertEqual(j["measuring"], "nothing")
        self.assertEqual(j["declared"], "iperf3 matrix   (claim measuring=; 'ndt check' refuses while set)")
        self.assertIs(j["claim_is_yours"], True)
        self.assertIs(j["measuring_is_nothing"], True)
        self.assertIsNone(j["busy"])
        self.assertEqual(j["stdout"], STATUS_FULL)
        self.assertEqual([c["argv"] for c in self.s.calls()], [["status"]])
        st, _, _, raw = self.s.request("GET", j["read"]["stdout"])
        self.assertEqual((st, raw), (200, STATUS_FULL.encode()))

    def test_lab_claim_is_yours_only_in_ndts_own_form_whole(self):
        for claim, yours in (("yours -- 30m left (until 23:59:00)", True),
                             ("yours-x -- 12m left (until 23:40:00)", False),
                             ("yours -- 30m left (until 23:59:00) and more", False),
                             ("orch-0924 -- 12m left (until 23:40:00)", False),
                             ("none", False),
                             ("EXPIRED 3m ago (was serve-test) -- treated as free", False)):
            j = self.lab("lab\n  claim          %s\n  measuring      nothing\n" % claim)
            self.assertEqual(j["claim"], claim)
            self.assertIs(j["claim_is_yours"], yours, claim)
        j = self.lab("lab\n  prev claim     yours -- 30m left (until 23:59:00)\n")
        self.assertIsNone(j["claim"])
        self.assertIs(j["claim_is_yours"], False)

    def test_measuring_is_nothing_only_when_ndt_says_nothing(self):
        for rows, value, nothing in (("  measuring      nothing\n", "nothing", True),
                                     ("  measuring      iperf3 -c 10.0.0.2 -t 30\n", "iperf3 -c 10.0.0.2 -t 30", False),
                                     ("  orphaned       iperf3 -c 10.0.0.2\n", None, False),
                                     ("", None, False)):
            j = self.lab("lab\n  claim          none\n" + rows)
            self.assertEqual(j["measuring"], value, rows)
            self.assertIs(j["measuring_is_nothing"], nothing, rows)

    def test_a_stopped_read_is_not_a_reading(self):
        s = GuiServe(extra=["--read-timeout", "1"]).start()
        try:
            s.behave(status={"stdout": STATUS_FULL, "sleep_after": 5})
            st, j, _, _ = s.get("/lab")
            self.assertEqual(st, 200, j)
            self.assertEqual(j["rc_class"], "timeout")
            self.assertIs(j["claim_is_yours"], False)
            self.assertIs(j["measuring_is_nothing"], False)
        finally:
            s.close()

    def test_lab_names_the_job_holding_the_slot(self):
        self.s.behave(down={"sleep": 3}, status={"stdout": STATUS_FULL})
        st, j, _, _ = self.s.post("/down")
        self.assertEqual(st, 202, j)
        st, lab, _, _ = self.s.get("/lab")
        self.assertEqual(st, 200, lab)
        self.assertEqual((lab["busy"] or {}).get("id"), j["job"]["id"])
        self.s.wait(j["job"]["id"])

    def test_lab_and_meta_need_the_token(self):
        for path in ("/lab", "/meta"):
            st, j, _, _ = self.s.get(path, token=None)
            self.assertEqual((st, j["error"]), (403, "token"), path)
        self.assertEqual(self.s.calls(), [])

    def test_meta_is_the_servers_own_tables(self):
        st, j, _, _ = self.s.get("/meta")
        self.assertEqual(st, 200, j)
        self.assertEqual(j["up_hosts"], {k: list(v) for k, v in verbs.UP_HOSTS.items()})
        self.assertIn(None, j["up_hosts"]["ovs"], "ndt's default size is an option too")
        self.assertEqual(j["max_claim_minutes"], verbs.MAX_CLAIM_MINUTES)
        self.assertEqual(j["max_note_chars"], verbs.MAX_NOTE_CHARS)
        self.assertEqual(j["default_claim_minutes"], 30)
        self.assertEqual(j["apps"], ["energy", "sim", "nsr", "viz", "te"])
        self.assertEqual(j["owner"], base.OWNER)
        self.assertEqual(self.s.calls(), [])
        # the default the page offers is the default a claim without minutes gets
        st, c, _, _ = self.s.post("/claim", {})
        self.assertEqual(st, 202, c)
        self.assertEqual(self.s.wait(c["job"]["id"])["argv"][1:], ["claim", str(j["default_claim_minutes"])])


# --- apps start / stop: the own-claim rule is this server's (judge B1, fcd4f69a) ------------------

class AppsNeedYourClaim(unittest.TestCase):
    """ndt's apps verbs check no claim -- cmd_apps and app_start ask neither foreign_claim nor
    in_flight, and ndtwin-lab's energy-start / sim-start ask nothing -- so the "claim first" the page
    shows for them was the only guard there was (opus judge on fcd4f69a, B1). The orchestrator's
    ruling (a): the server reads the claim inside the slot, as for a lab cell. [Co-developed with
    claude code -- Adam]"""

    def setUp(self):
        self.s = GuiServe().start()

    def tearDown(self):
        self.s.close()

    def test_apps_start_and_stop_run_only_under_your_claim(self):
        for claim in ("orch-0924 -- 12m left (until 23:40:00)", "none", "yours-x -- 12m left (until 23:40:00)",
                      "EXPIRED 3m ago (was serve-test) -- treated as free"):
            self.s.behave(status={"stdout": "lab\n  claim          %s\n  measuring      nothing\n" % claim})
            for path in ("/apps/sim/start", "/apps/sim/stop"):
                st, j, _, _ = self.s.post(path)
                self.assertEqual((st, j.get("error"), j.get("claim")), (409, "claim", claim), (path, j))
            # the preview needs no claim: it runs nothing, and the dialog is where "claim first" is shown
            st, j, _, _ = self.s.post("/apps/sim/start", {"dry_run": True})
            self.assertEqual((st, j.get("needs_own_claim")), (200, True), j)
        self.assertEqual({tuple(c["argv"]) for c in self.s.calls()}, {("status",)},
                         "an app verb reached ndt without your claim")
        self.assertEqual(self.s.jobs(), [])
        self.s.behave(status={"stdout": STATUS_FULL})
        for path, tail in (("/apps/sim/start", ["apps", "sim"]), ("/apps/sim/stop", ["apps", "stop", "sim"])):
            st, j, _, _ = self.s.post(path)
            self.assertEqual(st, 202, j)
            self.assertEqual(self.s.wait(j["job"]["id"])["argv"][1:], tail)


# --- dry_run -----------------------------------------------------------------------------------

WRITES = [  # path, body, argv tail, kind, confirm, needs_own_claim
    ("/up", {"plane": "ovs", "hosts": 4}, ["up", "4"], "up", "typed", True),
    ("/up", {"plane": "p4", "hosts": 128}, ["up", "p4", "128"], "up", "typed", True),
    ("/down", {}, ["down"], "down", "typed", True),
    ("/claim", {"minutes": 20, "note": "gui test"}, ["claim", "20", "gui test"], "claim", "plain", False),
    ("/release", {}, ["release"], "release", "plain", False),
    ("/apps/sim/start", {}, ["apps", "sim"], "apps.start", "plain", True),
    ("/apps/sim/stop", {}, ["apps", "stop", "sim"], "apps.stop", "plain", True),
]


class DryRun(unittest.TestCase):
    def setUp(self):
        self.s = GuiServe().start()
        self.s.behave(status={"stdout": STATUS_FULL})   # your claim: the real app runs below need it

    def tearDown(self):
        self.s.close()

    def test_a_dry_run_runs_nothing_and_answers_the_argv_that_would_run(self):
        ndt = os.path.realpath(self.s.ndt)
        dry = []
        for path, body, tail, kind, _, _ in WRITES:
            st, j, _, _ = self.s.post(path, dict(body, dry_run=True))
            self.assertEqual(st, 200, (path, j))
            self.assertIs(j["dry_run"], True)
            self.assertEqual((j["kind"], j["argv"]), (kind, [ndt] + tail), path)
            dry.append(j["argv"])
        self.assertEqual(self.s.calls(), [], "a dry run ran ndt")
        self.assertEqual(self.s.jobs(), [], "a dry run started a job")
        for (path, body, _, _, _, _), argv in zip(WRITES, dry):   # the same argv, when it runs
            st, j, _, _ = self.s.post(path, body)
            self.assertEqual(st, 202, (path, j))
            self.assertEqual(self.s.wait(j["job"]["id"])["argv"], argv, path)

    def test_the_dialogs_strength_is_the_servers(self):
        for path, body, _, kind, confirm, own in WRITES:
            st, j, _, _ = self.s.post(path, dict(body, dry_run=True))
            self.assertEqual(st, 200, (path, j))
            self.assertEqual((j["confirm"], j["needs_own_claim"]), (confirm, own), kind)

    def test_dry_run_is_true_or_false(self):
        for bad in ("yes", 1, None, "true"):
            st, j, _, _ = self.s.post("/down", {"dry_run": bad})
            self.assertEqual((st, j["error"]), (400, "refused"), bad)
        self.assertEqual(self.s.calls(), [])
        self.assertEqual(self.s.jobs(), [])
        st, j, _, _ = self.s.post("/release", {"dry_run": False})
        self.assertEqual(st, 202, j)
        self.s.wait(j["job"]["id"])


class DryRunCells(grid.GridCase):
    def setUp(self):
        self.s = GuiGridServe().start()

    def cells_raw(self):
        return sorted(glob.glob(os.path.join(self.s.state, "cells-raw", "*")))

    def test_a_cell_dry_run_makes_nothing_and_asks_nothing(self):
        st, j, _, _ = self.s.post("/cells/lab_cell/run", {"dry_run": True})
        self.assertEqual(st, 200, j)
        runner = os.path.join(self.s.grid_dir, "run_cells.sh")
        self.assertEqual(j["argv"][:4], [runner, "--cell", "lab_cell", "--raw-root"])
        self.assertTrue(j["argv"][4].startswith(os.path.join(self.s.state, "cells-raw", "lab_cell-")), j["argv"])
        self.assertFalse(os.path.exists(j["argv"][4]), "a dry run made the raw directory")
        self.assertEqual((j["kind"], j["requires"], j["confirm"], j["needs_own_claim"]),
                         ("cells.run", "ovs4", "typed", True))
        self.assertIsNone(j["writes_shared_state"])
        st, off, _, _ = self.s.post("/cells/offline_cell/run", {"dry_run": True})
        self.assertEqual((st, off["confirm"], off["needs_own_claim"]), (200, "plain", False), off)
        # a cell that writes shared state: the preview shows what it writes and asks for nothing --
        # the confirmation is given in the dialog, and a run without it is still refused
        st, h4, _, _ = self.s.post("/cells/%s/run" % grid.H4, {"dry_run": True})
        self.assertEqual(st, 200, h4)
        self.assertIn("host_count_override", h4["writes_shared_state"])
        st, r, _, _ = self.s.post("/cells/%s/run" % grid.H4)
        self.assertEqual((st, r["error"]), (400, "confirm"), r)
        self.assertEqual(self.cells_raw(), [])
        self.assertEqual(self.s.runs(), [])
        self.assertEqual(self.s.jobs(), [])
        st, run, _, _ = self.s.post("/cells/lab_cell/run")
        self.assertEqual(st, 202, run)
        self.assertEqual(self.s.wait(run["job"]["id"])["argv"][:4], j["argv"][:4])

    def test_the_dry_run_is_refused_where_it_is_not_offered(self):
        gid = self.walk()
        before = sorted(os.listdir(os.path.join(self.s.state, "guided")))
        st, j, _, _ = self.s.post("/cells/lab_cell/guided", {"dry_run": True})
        self.assertEqual((st, j["error"]), (400, "refused"), j)
        self.assertEqual(sorted(os.listdir(os.path.join(self.s.state, "guided"))), before, "a walk was created")
        st, j, _, _ = self.s.post("/guided/%s/abort" % gid, {"dry_run": True})
        self.assertEqual((st, j["error"]), (400, "refused"), j)
        st, j, _, _ = self.s.post("/guided/%s/verdict" % gid, {"verdict": "green", "note": "", "dry_run": True})
        self.assertEqual((st, j["error"]), (400, "refused"), j)
        st, w, _, _ = self.s.get("/guided/" + gid)
        self.assertFalse(w["walk"].get("aborted"), "a dry run aborted the walk")
        self.assertIsNone(w["walk"]["verdict"])

    def test_a_walks_dry_run_moves_nothing(self):
        gid = self.walk("lab_cell")
        ndt = os.path.realpath(self.s.ndt)
        seen = len(self.s.grid_calls())
        st, j, _, _ = self.s.post("/guided/%s/next" % gid, {"dry_run": True})
        self.assertEqual(st, 200, j)
        self.assertEqual((j.get("dry_run"), j["kind"], j["argv"]), (True, "guided.old", None), j)
        self.assertIn("read-only", j["note"])
        self.assertEqual(len(self.s.grid_calls()), seen, "a dry run ran the judge")
        st, w, _, _ = self.s.get("/guided/" + gid)
        self.assertEqual(w["walk"]["steps"][0]["state"], "pending")
        for _ in ("old", "new", "status"):
            self.next(gid)
        st, j, _, _ = self.s.post("/guided/%s/next" % gid, {"dry_run": True})
        self.assertEqual(st, 200, j)
        self.assertEqual((j["kind"], j["argv"], j["confirm"]),
                         ("claim", [ndt, "claim", "30", "guided walk %s (lab_cell)" % gid], "plain"), j)
        self.assertNotIn(["claim"], [c["argv"][:1] for c in self.s.calls()])
        self.assertEqual([x for x in self.s.jobs() if x["kind"] == "claim"], [])
        self.next(gid)
        self.settle(gid)
        st, j, _, _ = self.s.post("/guided/%s/next" % gid, {"dry_run": True})
        self.assertEqual(st, 200, j)
        self.assertEqual((j["kind"], j["argv"][1:3], j["confirm"], j["needs_own_claim"]),
                         ("cells.run", ["--cell", "lab_cell"], "typed", True), j)
        self.assertEqual(self.s.runs(), [])


# --- the page's script and markup (SCOPE section 6, "頁面端的靜態檢查") ---------------------------

def js_code():
    """static/app.js without comments: whole-line `//` comments, and trailing ones after two spaces."""
    out = []
    for line in page_file("app.js").decode().splitlines():
        out.append("" if line.lstrip().startswith("//") else re.sub(r"\s{2,}//.*$", "", line))
    return "\n".join(out)


def function_spans(code):
    """name -> (start, end) of every `function name(...) {...}`, by brace matching."""
    spans = {}
    for m in re.finditer(r"\bfunction\s+(\w+)\s*\(", code):
        i = code.index("{", m.end())
        depth = 0
        for j in range(i, len(code)):
            depth += {"{": 1, "}": -1}.get(code[j], 0)
            if depth == 0:
                break
        spans[m.group(1)] = (m.start(), j + 1)
    return spans


def owner(spans, pos):
    """The innermost named function around pos, or None (top level)."""
    best = None
    for name, (a, b) in spans.items():
        if a <= pos < b and (best is None or a > spans[best][0]):
            best = name
    return best


def sites(code, pattern, definition=None):
    """Every match of pattern, minus the definition itself, as (owner, pos)."""
    spans = function_spans(code)
    out = []
    for m in re.finditer(pattern, code):
        if definition and code.startswith("function " + definition, m.start() - len("function ")):
            continue
        out.append((owner(spans, m.start()), m.start()))
    return out


class PageLint(unittest.TestCase):
    def setUp(self):
        self.code = js_code()

    def test_the_script_keeps_nothing_outside_memory(self):
        found = sites(self.code, r"\b(localStorage|sessionStorage|indexedDB|caches)\b|document\.cookie")
        self.assertTrue(found, "storageHook must read the stores for the browser case")
        self.assertEqual({o for o, _ in found}, {"storageHook"}, found)
        a, b = function_spans(self.code)["storageHook"]
        self.assertNotRegex(self.code[a:b], r"token|setItem|=(?!=)[^=]*cookie|cookie\s*=(?!=)")
        self.assertNotRegex(self.code, r"\.setItem\s*\(|document\.cookie\s*=(?!=)")

    def test_the_script_makes_no_html_from_strings(self):
        for pat in (r"innerHTML", r"outerHTML", r"insertAdjacentHTML", r"document\.write", r"\beval\s*\(",
                    r"\bnew\s+Function\b", r"\bsetTimeout\s*\(\s*[\"'`]", r"\bDOMParser\b",
                    r"createContextualFragment", r"\.setAttribute\s*\(\s*[\"']on", r"\bsrcdoc\b"):
            self.assertNotRegex(self.code, pat)

    def test_there_is_one_door_out_and_the_token_is_set_at_it(self):
        self.assertEqual(sites(self.code, r"\bfetch\s*\("), [("call", self.code.index("fetch("))])
        self.assertEqual([o for o, _ in sites(self.code, r"X-NDT-Token")], ["call"])
        for pat in (r"XMLHttpRequest", r"sendBeacon", r"\bWebSocket\b", r"\bEventSource\b", r"window\.open\s*\(",
                    r"\bimport\s*\(", r"\.src\s*="):
            self.assertNotRegex(self.code, pat)
        callers = {o for o, _ in sites(self.code, r"(?<![\w.])call\(", definition="call(")}
        self.assertLessEqual(callers, {"get", "post", "openSession"}, callers)

    def test_every_write_is_confirmed_in_the_dialog(self):
        posts = sites(self.code, r"(?<![\w.])post\(", definition="post(")
        self.assertTrue(posts)
        self.assertEqual({o for o, _ in posts}, {"confirmThen"}, posts)
        self.assertLessEqual({o for o, _ in sites(self.code, r"[\"']POST[\"']")}, {"post", "openSession"})

    # [Co-developed with claude code -- Adam] the orchestrator's condition on the log re-read (09-27
    # 15:4x): a job's log is re-read every 2 s only while its view is open and the page is shown
    def test_the_job_view_can_be_closed_and_its_log_stops(self):
        html = page_file("index.html").decode()
        self.assertEqual(len(re.findall(r'<button id="job-close" type="button">', html)), 1,
                         "the job view has no Close button")
        spans = function_spans(self.code)
        self.assertIn("closeJob", spans, "no closeJob()")
        a, b = spans["closeJob"]
        body = self.code[a:b]
        self.assertRegex(body, r"\bwatching = null;", "closing the view does not stop the log loop")
        self.assertRegex(body, r'\$\("job"\)\.hidden = true;', "closing the view does not hide it")
        self.assertRegex(self.code, r'\$\("job-close"\)\.addEventListener\("click", closeJob\)',
                         "the Close button is not wired to closeJob")

    def test_the_log_loop_stops_when_the_job_ends(self):
        # judge G-N1 (fcd4f69a): this condition was held by nothing -- `if (false)` there survived
        a, b = function_spans(self.code)["openJob"]
        loop = self.code[a:b]
        m = re.search(r'if \(r\.json\.job\.state !== "running"\) \{([^}]*)\}', loop)
        self.assertTrue(m, "the log loop does not stop when the job ends")
        self.assertRegex(m.group(1), r"\breturn;\s*$", "the job-ended branch does not leave the loop")
        self.assertLess(m.start(), loop.index("await sleep(2000);"), "the loop sleeps before it looks")

    def test_a_hidden_page_does_not_poll_a_jobs_log(self):
        spans = function_spans(self.code)
        self.assertIn("whileHidden", spans, "no whileHidden()")
        a, b = spans["whileHidden"]
        wait = self.code[a:b]
        # it waits: the one early return is for a page that is shown, and a hidden one resolves only
        # from the visibilitychange listener
        self.assertIn('if (document.visibilityState !== "hidden") return Promise.resolve();', wait)
        self.assertEqual(wait.count("Promise.resolve()"), 1, wait)
        self.assertIn('document.visibilityState === "hidden"', wait)
        self.assertIn('"visibilitychange"', wait)
        a, b = spans["openJob"]
        loop = self.code[a:b]
        # the wait sits after the sleep and before the next read, and the loop asks again after it
        # whether this is still the job being watched
        self.assertRegex(loop, r"await sleep\(2000\);\s*await whileHidden\(\);\s*if \(watching !== mine\) return;",
                         "the log loop reads on while the page is hidden")
        # watching holds this OPENING, not the job id: a view closed and opened again on the same
        # job within one sleep would otherwise leave the old loop running beside the new one
        self.assertRegex(loop, r"const mine = \{\};[^\n]*\n\s*watching = mine;")
        self.assertNotIn("watching !== id", loop)

    def test_the_markup_has_no_inline_script_style_or_handler(self):
        html = page_file("index.html").decode()
        scripts = re.findall(r"<script\b[^>]*>(.*?)</script>", html, re.S)
        self.assertEqual(re.findall(r"<script\b([^>]*)>", html), [' src="/app.js" defer'])
        self.assertEqual(scripts, [""])
        self.assertNotRegex(html, r"\son[a-z]+\s*=")
        self.assertNotRegex(html, r"\sstyle\s*=|<style\b|javascript:")
        self.assertEqual(re.findall(r"\b(?:href|src)=\"([^\"]*)\"", html), ["/app.css", "/app.js"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
