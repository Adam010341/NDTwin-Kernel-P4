#!/usr/bin/env python3
"""ndt serve: every red line of TICKET-ndt-serve section 3, against a stub ndt.

[Co-developed with claude code -- Adam]

The server under test is started as a real process on a free port of 127.0.0.1, with its state
directory, token file and app root in a temp directory, and `--ndt` pointing at a STUB: a bash
file that carries an APP_NAMES= line (the server reads ndt's app list from the script) and
execs stub.py, which records its argv, its NDT_* environment and its session id to calls.jsonl
and answers with whatever behavior.json says for that verb. No real `ndt` runs and no lab is
touched.

    python3 tests/python/test_ndt_serve.py
    NDT_SERVE_UNDER_TEST=/tmp/x/ndt_serve python3 tests/python/test_ndt_serve.py   # a mutant
    NDT_UNDER_TEST=/tmp/x/ndt python3 tests/python/test_ndt_serve.py               # a mutant ndt

tests/shell/mutate_ndt_serve.sh is this file's mutation gate: each named mutation must turn the
case it names red.
"""
import glob
import http.client
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SERVE_DIR = os.environ.get("NDT_SERVE_UNDER_TEST") or os.path.join(REPO, "tools", "ndt_serve")
NDT = os.environ.get("NDT_UNDER_TEST") or os.path.join(REPO, "tools", "test_workflow", "ndt")
OWNER = "serve-test"

STUB_NDT = textwrap.dedent('''\
    #!/usr/bin/env bash
    APP_NAMES="%(apps)s"
    exec python3 "$(dirname "$(readlink -f "$0")")/stub.py" "$@"
    ''')

STUB_PY = textwrap.dedent('''\
    import json, os, sys, time
    here = os.path.dirname(os.path.realpath(__file__))
    argv = sys.argv[1:]
    rec = {"argv": argv, "owner": os.environ.get("NDT_OWNER"),
           "ndt_env": sorted(k for k in os.environ if k.startswith("NDT_")),
           "sid": os.getsid(0), "pid": os.getpid(), "cwd": os.getcwd(), "t": time.time()}
    def log(r):
        fd = os.open(os.path.join(here, "calls.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        os.write(fd, (json.dumps(r) + "\\n").encode()); os.close(fd)
    log(rec)
    try:
        beh = json.load(open(os.path.join(here, "behavior.json")))
    except OSError:
        beh = {}
    key = " ".join(argv)
    b = {}
    for k in sorted(beh, key=len):
        if key == k or key.startswith(k + " "):
            b = beh[k]
    if b.get("hold_pipe"):
        import subprocess
        gp = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(%d)" % b["hold_pipe"]],
                              start_new_session=True)
        log({"grandchild": gp.pid, "argv": argv})
    time.sleep(b.get("sleep", 0))
    sys.stdout.buffer.write(bytes.fromhex(b["stdout_hex"]) if "stdout_hex" in b else
                            b.get("stdout", "stub stdout: %s\\n" % key).encode())
    sys.stderr.buffer.write(b.get("stderr", "stub stderr: %s\\n" % key).encode())
    sys.stdout.flush(); sys.stderr.flush()
    time.sleep(b.get("sleep_after", 0))   # printed, then hung: a timeout with output already read
    log({"done": os.getpid(), "argv": argv, "t": time.time()})
    sys.exit(b.get("rc", 0))
    ''')


STARTED = []   # every server process a case started, by its Popen -- see tearDownModule


def tearDownModule():
    """A server a failing case forgot is still this suite's process. Found 09-24: every gate run
    left the M40 mutant's second server running (the case closed only the first). Each is
    stopped here by the Popen that started it -- never looked up by name -- and named on stderr."""
    for p in STARTED:
        if p.poll() is None:
            sys.stderr.write("tearDownModule: a case left server pid %d running; stopping it\n" % p.pid)
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait(10)


class Serve:
    """One server process, its temp tree and its stub."""

    def __init__(self, apps="energy sim nsr viz te", env=None, extra=(), tmp=None):
        self.tmp = tmp or tempfile.mkdtemp(prefix="ndt-serve-test-")
        self.stubdir = os.path.join(self.tmp, "repo", "tools", "test_workflow")
        os.makedirs(self.stubdir, exist_ok=True)
        self.ndt = os.path.join(self.stubdir, "ndt")
        with open(self.ndt, "w") as f:
            f.write(STUB_NDT % {"apps": apps})
        os.chmod(self.ndt, 0o755)
        with open(os.path.join(self.stubdir, "stub.py"), "w") as f:
            f.write(STUB_PY)
        self.state = os.path.join(self.tmp, "state")
        self.token_file = os.path.join(self.tmp, "config", "ndt-serve", "token")
        self.app_root = os.path.join(self.tmp, "packages")
        os.makedirs(self.app_root, exist_ok=True)
        # hermetic: no NDT_* of the shell running the tests (this gate's own NDT_*_UNDER_TEST
        # included) reaches the server, only what a case sets
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("NDT_")}
        self.env.update(env or {})
        self.extra = list(extra)
        self.proc = None
        self.port = None

    def argv(self):
        return [sys.executable, os.path.join(SERVE_DIR, "serve.py"), "--owner", OWNER, "--port", "0",
                "--ndt", self.ndt, "--state-dir", self.state, "--token-file", self.token_file,
                "--app-root", self.app_root] + self.extra

    def start(self, argv=None, expect_ok=True, umask=None):
        out = os.path.join(self.tmp, "serve.%d.out" % time.monotonic_ns())
        self.out = out
        with open(out, "wb") as o, open(out + ".err", "wb") as e:
            self.proc = subprocess.Popen(argv or self.argv(), stdout=o, stderr=e, stdin=subprocess.DEVNULL,
                                         env=self.env, start_new_session=True,
                                         preexec_fn=(lambda: os.umask(umask)) if umask is not None else None)
        STARTED.append(self.proc)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            text = _read(out)
            m = re.search(r"listening on http://127\.0\.0\.1:(\d+)/", text)
            if m:
                self.port = int(m.group(1))
                return self
            if self.proc.poll() is not None:
                if expect_ok:
                    raise AssertionError("server exited %s: %s" % (self.proc.returncode, _read(out + ".err")))
                return self
            time.sleep(0.05)
        raise AssertionError("server did not start")

    def stop(self, sig=signal.SIGTERM, group=False):
        if self.proc and self.proc.poll() is None:
            if group:
                os.killpg(self.proc.pid, sig)   # the group this test created for it
            else:
                self.proc.send_signal(sig)
            self.proc.wait(10)

    def close(self):
        self.stop(signal.SIGKILL)
        # let any runner the test left behind end before its directory goes
        for _ in range(100):
            if not any(self.job_running_on_disk()):
                break
            time.sleep(0.1)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def job_running_on_disk(self):
        for d in glob.glob(os.path.join(self.state, "jobs", "*")):
            yield not os.path.exists(os.path.join(d, "exit.json")) and os.path.exists(os.path.join(d, "spawn.json")) \
                and _pid_alive(json.loads(_read(os.path.join(d, "spawn.json")))["runner_pid"])

    def token(self):
        return _read(self.token_file).strip()

    def behave(self, **verbs):
        with open(os.path.join(self.stubdir, "behavior.json"), "w") as f:
            json.dump({k.replace("_", " "): v for k, v in verbs.items()}, f)

    def calls(self, done=False):
        p = os.path.join(self.stubdir, "calls.jsonl")
        if not os.path.exists(p):
            return []
        rows = [json.loads(l) for l in _read(p).splitlines() if l.strip()]
        return [r for r in rows if ("done" in r) == done and "grandchild" not in r]

    def grandchildren(self):
        p = os.path.join(self.stubdir, "calls.jsonl")
        rows = [json.loads(l) for l in _read(p).splitlines() if l.strip()] if os.path.exists(p) else []
        return [r["grandchild"] for r in rows if "grandchild" in r]

    def request(self, method, path, body=None, token=True, host="default", ctype="application/json",
                headers=None, raw=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        if host == "default":
            host = "127.0.0.1:%d" % self.port
        if host is not None:
            conn.putheader("Host", host)
        if token is True:
            token = self.token()
        if token:
            conn.putheader("X-NDT-Token", token)
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else b"")
        if method == "POST" and ctype:
            conn.putheader("Content-Type", ctype)
        for k, v in (headers or {}).items():
            conn.putheader(k, v)
        conn.putheader("Content-Length", str(len(data)))
        conn.endheaders(data)
        r = conn.getresponse()
        payload = r.read()
        hdrs = {k.lower(): v for k, v in r.getheaders()}
        conn.close()
        try:
            j = json.loads(payload)
        except ValueError:
            j = None
        return r.status, j, hdrs, payload

    def post(self, path, body=None, **kw):
        return self.request("POST", "/api/v1" + path, body if body is not None else {}, **kw)

    def get(self, path, **kw):
        return self.request("GET", "/api/v1" + path, **kw)

    def wait(self, job_id, s=20):
        st, j, _, _ = self.get("/jobs/%s?wait=%d" % (job_id, s))
        assert st == 200, (st, j)
        return j["job"]

    def run_job(self, path, body=None):
        st, j, _, _ = self.post(path, body)
        assert st == 202, (st, j)
        return self.wait(j["job"]["id"])


def _read(path):
    with open(path) as f:
        return f.read()


def code_facts(path):
    """What a static rule may look at in a service file: every call's dotted name, every keyword
    argument, every identifier, and every string literal that is not a docstring -- with line
    numbers. Docstrings and comments are prose ABOUT the rules (\"no pkill -f\") and would make
    the scan fire on the sentence that states it."""
    import ast
    tree = ast.parse(_read(path))
    docs = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.body and isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant):
                docs.add(id(node.body[0].value))
    facts = []
    for node in ast.walk(tree):
        line = getattr(node, "lineno", 0)
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docs:
            facts.append(("str", node.value, line))
        elif isinstance(node, ast.Call):
            f, parts = node.func, []
            while isinstance(f, ast.Attribute):
                parts.insert(0, f.attr)
                f = f.value
            if isinstance(f, ast.Name):
                parts.insert(0, f.id)
            facts.append(("call", ".".join(parts), line))
            for kw in node.keywords:
                v = kw.value.value if isinstance(kw.value, ast.Constant) else "<expr>"
                facts.append(("kw", "%s=%s" % (kw.arg, v), line))
        elif isinstance(node, ast.Name):
            facts.append(("name", node.id, line))
    return facts


def _pid_alive(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[0] not in ("Z", "X")
    except OSError:
        return False


class ServeCase(unittest.TestCase):
    def setUp(self):
        self.s = Serve().start()

    def tearDown(self):
        self.s.close()


# --- red line 1: loopback only, Host header, no CORS -------------------------------------------

class LoopbackOnly(ServeCase):
    def test_listens_on_127_0_0_1_only(self):
        rows = []
        for table in ("/proc/net/tcp", "/proc/net/tcp6"):
            for line in _read(table).splitlines()[1:]:
                f = line.split()
                addr, port = f[1].rsplit(":", 1)
                if int(port, 16) == self.s.port and f[3] == "0A":
                    rows.append((table, addr))
        self.assertEqual(rows, [("/proc/net/tcp", "0100007F")], "listening sockets on the port: %r" % rows)

    def test_foreign_host_header_is_refused(self):
        st, j, _, _ = self.s.get("/health", host="evil.example:%d" % self.s.port)
        self.assertEqual((st, j["error"]), (403, "host"))
        st, j, _, _ = self.s.post("/down", host="evil.example:%d" % self.s.port)
        self.assertEqual(st, 403)
        st, j, _, _ = self.s.get("/status", host="rebind.attacker.test")
        self.assertEqual(st, 403)
        self.assertEqual(self.s.calls(), [], "a refused Host must run nothing")

    def test_missing_host_header_is_refused(self):
        st, j, _, _ = self.s.get("/health", host=None)
        self.assertEqual((st, j["error"]), (403, "host"))

    def test_host_with_another_port_is_refused(self):
        for h in ("localhost:1", "127.0.0.1", "localhost", "127.0.0.1:%d0" % self.s.port):
            st, j, _, _ = self.s.get("/health", host=h)
            self.assertEqual(st, 403, h)

    def test_localhost_and_ip_hosts_are_served(self):
        for h in ("127.0.0.1:%d" % self.s.port, "localhost:%d" % self.s.port, "LOCALHOST:%d" % self.s.port):
            st, j, _, _ = self.s.get("/health", host=h)
            self.assertEqual((st, j["service"]), (200, "ndt-serve"), h)

    def test_no_cors_header_anywhere(self):
        seen = []
        for method, path, hdr in [
                ("GET", "/api/v1/health", {"Origin": "http://evil.example"}),
                ("OPTIONS", "/api/v1/up", {"Origin": "http://evil.example",
                                           "Access-Control-Request-Method": "POST",
                                           "Access-Control-Request-Headers": "x-ndt-token, content-type"}),
                ("POST", "/api/v1/down", {"Origin": "http://evil.example"})]:
            st, j, h, _ = self.s.request(method, path, body={} if method == "POST" else None, headers=hdr)
            seen += [(method, k) for k in h if k.startswith("access-control-")]
            if method == "OPTIONS":
                self.assertGreaterEqual(st, 400, "a preflight must not succeed")
        self.assertEqual(seen, [])
        self.assertEqual(self.s.calls(), [])


# --- red line 2: CSRF -------------------------------------------------------------------------

WRITES = ["/up", "/down", "/claim", "/release", "/apps/nsr/start", "/apps/nsr/stop"]


class Csrf(ServeCase):
    def test_token_file_is_private(self):
        st = os.stat(self.s.token_file)
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.s.token_file)).st_mode), 0o700)
        self.assertGreaterEqual(len(self.s.token()), 40)

    def test_open_directories_left_by_someone_else_are_tightened(self):
        """Judge finding 8: a state or token directory that already exists 0777, an old 0644
        token, and a umask of 000 -- the server still leaves 0700 / 0600 behind."""
        s = Serve()
        try:
            for d in (os.path.dirname(s.token_file), s.state):
                os.makedirs(d)
                os.chmod(d, 0o777)
            with open(s.token_file, "w") as f:
                f.write("old\n")
            os.chmod(s.token_file, 0o644)
            s.start(umask=0)
            self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(s.token_file)).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(s.state).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(s.token_file).st_mode), 0o600)
            self.assertNotEqual(s.token(), "old")
        finally:
            s.close()

    def test_token_is_new_on_every_start(self):
        old = self.s.token()
        self.s.stop()
        self.s.start()
        self.assertNotEqual(self.s.token(), old)
        st, j, _, _ = self.s.post("/down", token=old)
        self.assertEqual((st, j["error"]), (403, "token"))
        self.assertEqual(self.s.calls(), [])

    def test_write_without_token_runs_nothing(self):
        for p in WRITES:
            st, j, _, _ = self.s.post(p, {"plane": "ovs"} if p == "/up" else {}, token=None)
            self.assertEqual((st, j["error"]), (403, "token"), p)
        self.assertEqual(self.s.calls(), [])

    def test_write_with_wrong_token_runs_nothing(self):
        for p in WRITES:
            st, j, _, _ = self.s.post(p, {}, token=self.s.token()[:-1] + "x")
            self.assertEqual(st, 403, p)
        self.assertEqual(self.s.calls(), [])

    def test_token_in_query_is_not_accepted(self):
        st, j, _, _ = self.s.request("POST", "/api/v1/down?token=" + self.s.token(), body={}, token=None)
        self.assertEqual(st, 403)
        self.assertEqual(self.s.calls(), [])

    def test_cross_origin_write_is_refused_with_token(self):
        for origin in ("http://evil.example", "null", "http://localhost:1", "https://localhost:%d" % self.s.port):
            st, j, _, _ = self.s.post("/down", headers={"Origin": origin})
            self.assertEqual((st, j["error"]), (403, "origin"), origin)
        self.assertEqual(self.s.calls(), [])

    def test_same_origin_write_is_accepted(self):
        st, j, _, _ = self.s.post("/release", headers={"Origin": "http://localhost:%d" % self.s.port})
        self.assertEqual(st, 202, j)

    def test_form_shaped_write_is_refused(self):
        for ctype in ("application/x-www-form-urlencoded", "text/plain", "multipart/form-data; boundary=x", None):
            st, j, _, _ = self.s.request("POST", "/api/v1/down", raw=b"{}", ctype=ctype)
            self.assertEqual(st, 415, ctype)
        self.assertEqual(self.s.calls(), [])

    def test_reads_need_the_token_except_health(self):
        """Judge 09-24 finding 1: GET /status?check=1 runs `ndt status --check`, whose lock probes
        POST /ndt/acquire_lock to the kernel (ndt:9416-9431). A read is not side-effect free, so
        every GET but /health is gated the way a write is."""
        paths = ["/status", "/status?check=1", "/apps", "/jobs", "/jobs/20260101T000000Z-abcdef",
                 "/jobs/20260101T000000Z-abcdef/log/stdout", "/cells", "/cells/x", "/cells/x/old",
                 "/guided", "/guided/g20260101T000000Z-abcdef", "/reads/r20260101T000000Z-abcdef/log/stdout"]
        for p in paths:
            st, j, _, _ = self.s.get(p, token=None)
            self.assertEqual((st, (j or {}).get("error")), (403, "token"), p)
        st, j, _, _ = self.s.get("/health", token=None)
        self.assertEqual(st, 200)
        self.assertEqual(self.s.calls(), [])

    def test_status_check_without_token_runs_nothing(self):
        """The <img src=".../status?check=1"> of finding 1: no token, no Origin -- refused, and
        ndt is never started."""
        st, j, _, _ = self.s.get("/status?check=1", token=None)
        self.assertEqual((st, j["error"]), (403, "token"))
        self.assertEqual(self.s.calls(), [])

    def test_cross_origin_read_is_refused(self):
        for origin in ("http://evil.example", "null"):
            st, j, _, _ = self.s.get("/status", headers={"Origin": origin})
            self.assertEqual((st, j["error"]), (403, "origin"), origin)
        st, _, _, _ = self.s.get("/status", headers={"Origin": "http://127.0.0.1:%d" % self.s.port})
        self.assertEqual(st, 200)
        self.assertEqual([c["argv"] for c in self.s.calls()], [["status"]])

    def test_wait_is_capped(self):
        st, j, _, _ = self.s.get("/jobs/20260101T000000Z-abcdef?wait=301")
        self.assertEqual(st, 400)
        st, j, _, _ = self.s.get("/jobs/20260101T000000Z-abcdef?wait=300")
        self.assertEqual(st, 404, "300 is inside the cap; the job simply does not exist")

    def test_get_runs_only_read_verbs(self):
        for p in ("/health", "/status", "/status?check=1", "/apps", "/jobs"):
            st, _, _, _ = self.s.get(p)
            self.assertEqual(st, 200, p)
        for p in WRITES:
            st, _, _, _ = self.s.get(p)
            self.assertEqual(st, 405, "GET %s must not be a write" % p)
        self.assertEqual(sorted({tuple(c["argv"]) for c in self.s.calls()}),
                         [("apps", "status"), ("status",), ("status", "--check")])


class Bounded(unittest.TestCase):
    """Judge finding 1, second half: a blind GET flood must not pin an unbounded number of threads."""

    def test_waiters_are_bounded(self):
        s = Serve(extra=["--max-waiters", "2"]).start()
        try:
            s.behave(up={"sleep": 4})
            job = s.post("/up", {"plane": "ovs", "hosts": 4})[1]["job"]["id"]
            import threading
            res = []
            ts = [threading.Thread(target=lambda: res.append(s.get("/jobs/%s?wait=10" % job)[0])) for _ in range(3)]
            for t in ts:
                t.start()
                time.sleep(0.2)
            for t in ts:
                t.join(30)
            self.assertEqual(sorted(res), [200, 200, 503])
        finally:
            s.close()

    def test_listen_backlog_holds_a_burst(self):
        """Found by the final run of 09-24 23:3x: 20 concurrent POSTs, one reset by the kernel
        (1/10 reproduced). socketserver's listen backlog is 5; a burst past it is dropped or reset
        before the server ever sees it. The backlog is read off the listening socket (ss Send-Q)."""
        s = Serve().start()
        try:
            out = subprocess.run(["ss", "-ltnH", "sport = :%d" % s.port], capture_output=True, text=True).stdout
            backlog = int(out.split()[2])
            self.assertGreaterEqual(backlog, 64, out)
        finally:
            s.close()

    def test_connections_are_bounded(self):
        import socket
        s = Serve(extra=["--max-connections", "4"]).start()
        idle = []
        try:
            for _ in range(4):
                c = socket.create_connection(("127.0.0.1", s.port))
                idle.append(c)
            time.sleep(0.3)
            t0 = time.monotonic()
            st, _, _, _ = s.get("/health", token=None)
            self.assertEqual(st, 503)
            self.assertLess(time.monotonic() - t0, 3, "a refused connection is answered at once")
            for c in idle:
                c.close()
            idle = []
            time.sleep(0.5)
            self.assertEqual(s.get("/health", token=None)[0], 200)
        finally:
            for c in idle:
                c.close()
            s.close()


# --- red line 3: whitelist, argv only ---------------------------------------------------------

class Whitelist(ServeCase):
    def test_up_argv_is_one_of_the_fixed_forms(self):
        table = [({"plane": "ovs"}, ["up", "ovs"]), ({"plane": "ovs", "hosts": 128}, ["up", "ovs"]),
                 ({"plane": "ovs", "hosts": 4}, ["up", "4"]), ({"plane": "p4"}, ["up", "p4"]),
                 ({"plane": "p4", "hosts": 4}, ["up", "p4", "4"]), ({"plane": "p4", "hosts": 128}, ["up", "p4", "128"])]
        for body, want in table:
            job = self.s.run_job("/up", body)
            self.assertEqual(job["argv"][1:], want, body)
        self.assertEqual([c["argv"] for c in self.s.calls()], [w for _, w in table])

    def test_up_refuses_values_outside_the_enums(self):
        for body in ({"plane": "ovs; id"}, {"plane": "OVS"}, {"plane": "ovs4"}, {}, {"plane": "p4", "hosts": 5},
                     {"plane": "p4", "hosts": "4"}, {"plane": "p4", "hosts": 256}, {"plane": "ovs", "hosts": True},
                     {"plane": "ovs", "hosts": 8}, {"plane": ["ovs"]}):
            st, j, _, _ = self.s.post("/up", body)
            self.assertEqual((st, j["error"]), (400, "refused"), body)
        self.assertEqual(self.s.calls(), [])

    def test_up_refuses_unknown_fields(self):
        for body in ({"plane": "ovs", "deep": True}, {"plane": "ovs", "force": True}, {"plane": "p4", "telemetry": "x"}):
            st, j, _, _ = self.s.post("/up", body)
            self.assertEqual(st, 400, body)
        for p in ("/down", "/release", "/apps/nsr/start"):
            st, _, _, _ = self.s.post(p, {"force": True})
            self.assertEqual(st, 400, p)
        st, _, _, _ = self.s.post("/down", {"deep": True})
        self.assertEqual(st, 400)
        self.assertEqual(self.s.calls(), [])

    def test_app_dir_outside_the_root_is_refused(self):
        outside = tempfile.mkdtemp(prefix="ndt-serve-outside-")
        try:
            for app in (outside, "/etc", os.path.join(self.s.app_root, "..", "state"), "relative/pkg",
                        self.s.app_root, "-x"):
                st, j, _, _ = self.s.post("/up", {"plane": "p4", "app": app})
                self.assertEqual((st, j["error"]), (400, "refused"), app)
        finally:
            shutil.rmtree(outside)
        self.assertEqual(self.s.calls(), [])

    def test_app_dir_symlink_out_of_the_root_is_refused(self):
        outside = tempfile.mkdtemp(prefix="ndt-serve-outside-")
        try:
            link = os.path.join(self.s.app_root, "escape")
            os.symlink(outside, link)
            st, j, _, _ = self.s.post("/up", {"plane": "p4", "app": link})
            self.assertEqual((st, j["error"]), (400, "refused"))
        finally:
            shutil.rmtree(outside)
        self.assertEqual(self.s.calls(), [])

    def test_app_root_is_a_directory_not_a_prefix(self):
        """Judge finding 8: commonpath, not startswith -- <root>2/x shares the root's prefix."""
        sibling = self.s.app_root + "2"
        os.makedirs(os.path.join(sibling, "x"))
        st, j, _, _ = self.s.post("/up", {"plane": "p4", "app": os.path.join(sibling, "x")})
        self.assertEqual((st, j["error"]), (400, "refused"))
        self.assertEqual(self.s.calls(), [])

    def test_app_dir_inside_the_root_is_passed_resolved(self):
        real = os.path.join(self.s.app_root, "basic")
        os.makedirs(real)
        os.symlink(real, os.path.join(self.s.app_root, "alias"))
        job = self.s.run_job("/up", {"plane": "p4", "app": os.path.join(self.s.app_root, "alias")})
        self.assertEqual(job["argv"][1:], ["up", "p4", "--app", os.path.realpath(real)])
        st, _, _, _ = self.s.post("/up", {"plane": "ovs", "app": real})
        self.assertEqual(st, 400, "--app is a P4 flag")
        st, _, _, _ = self.s.post("/up", {"plane": "p4", "hosts": 4, "app": real})
        self.assertEqual(st, 400, "an app package sizes the fabric")

    def test_app_name_must_be_one_of_ndts(self):
        for name in ("foo", "nsr;id", "NSR", "..", "nsr%20te", "-h"):
            st, j, _, _ = self.s.post("/apps/%s/start" % name)
            self.assertIn(st, (400, 404), name)
        self.assertEqual(self.s.calls(), [])
        self.assertEqual(self.s.run_job("/apps/nsr/start")["argv"][1:], ["apps", "nsr"])
        self.assertEqual(self.s.run_job("/apps/te/stop")["argv"][1:], ["apps", "stop", "te"])

    def test_app_names_come_from_ndt_itself(self):
        other = Serve(apps="alpha beta").start()
        try:
            st, j, _, _ = other.get("/health")
            self.assertEqual(j["apps"], ["alpha", "beta"])
            st, _, _, _ = other.post("/apps/nsr/start")
            self.assertEqual(st, 400)
            self.assertEqual(other.run_job("/apps/beta/start")["argv"][1:], ["apps", "beta"])
        finally:
            other.close()

    def test_claim_note_reaches_ndt_as_one_argv_element(self):
        m1, m2 = os.path.join(self.s.tmp, "m1"), os.path.join(self.s.tmp, "m2")
        note = '$(touch %s); `touch %s` && echo "q" | cat; *' % (m1, m2)
        job = self.s.run_job("/claim", {"minutes": 25, "note": note})
        self.assertEqual(job["argv"][1:], ["claim", "25", note])
        self.assertEqual(self.s.calls()[0]["argv"], ["claim", "25", note])
        self.assertFalse(os.path.exists(m1) or os.path.exists(m2), "the note was run by a shell")

    def test_claim_note_with_a_newline_is_refused(self):
        for note in ("x\nowner=evil", "tab\there", "nul\x00"):
            st, j, _, _ = self.s.post("/claim", {"note": note})
            self.assertEqual((st, j["error"]), (400, "refused"), repr(note))
        self.assertEqual(self.s.calls(), [])

    def test_claim_minutes_are_bounded(self):
        for m in (0, 241, "30", 1.5, -1, True):
            st, _, _, _ = self.s.post("/claim", {"minutes": m})
            self.assertEqual(st, 400, m)
        self.assertEqual(self.s.run_job("/claim", {})["argv"][1:], ["claim", "30"])

    def test_no_shell_anywhere_in_the_service(self):
        files = glob.glob(os.path.join(SERVE_DIR, "*.py"))
        self.assertGreaterEqual(len(files), 4)
        bad = []
        for p in files:
            for kind, text, line in code_facts(p):
                if (kind == "kw" and text.startswith("shell=") and text != "shell=False") or \
                   (kind == "call" and text in ("os.system", "os.popen", "os.execl", "os.execlp", "os.spawnl",
                                                "subprocess.getoutput", "subprocess.getstatusoutput")) or \
                   (kind == "str" and text in ("bash", "sh", "-c", "/bin/sh", "/bin/bash")):
                    bad.append("%s:%d %s %s" % (os.path.basename(p), line, kind, text))
        self.assertEqual(bad, [])


# --- red line 4: thin shell -------------------------------------------------------------------

class ThinShell(ServeCase):
    def test_rc5_is_refused_and_not_dirty(self):
        self.s.behave(up={"rc": 5})
        refused = self.s.run_job("/up", {"plane": "ovs", "hosts": 4})
        self.s.behave(up={"rc": 1})
        dirty = self.s.run_job("/up", {"plane": "ovs", "hosts": 4})
        self.assertEqual((refused["rc"], refused["rc_class"]), (5, "refused"))
        self.assertIn("GUARD REFUSED", refused["meaning"])
        self.assertEqual((dirty["rc"], dirty["rc_class"]), (1, "dirty"))

    def test_each_verb_reads_its_own_rc_table(self):
        self.s.behave(apps_stop={"rc": 2}, down={"rc": 3}, up={"rc": 2})
        self.assertEqual(self.s.run_job("/apps/nsr/stop")["rc_class"], "nothing")
        self.assertEqual(self.s.run_job("/down")["rc_class"], "nothing")
        self.assertEqual(self.s.run_job("/up", {"plane": "ovs"})["rc_class"], "usage")

    def test_unknown_rc_is_not_folded(self):
        self.s.behave(up={"rc": 7})
        job = self.s.run_job("/up", {"plane": "ovs"})
        self.assertEqual((job["rc"], job["rc_class"]), (7, "unknown"))

    def test_output_is_kept_byte_for_byte(self):
        blob = bytes(range(256)) * 1200 + "中文 🔴\n".encode()
        self.s.behave(down={"stdout_hex": blob.hex(), "stderr": "only stderr\n"})
        job = self.s.run_job("/down")
        self.assertEqual(job["stdout_bytes"], len(blob))
        st, _, h, out = self.s.get("/jobs/%s/log/stdout" % job["id"])
        self.assertEqual(out, blob)
        _, _, _, err = self.s.get("/jobs/%s/log/stderr" % job["id"])
        self.assertEqual(err, b"only stderr\n")
        _, _, h, part = self.s.get("/jobs/%s/log/stdout?offset=1000&limit=5000" % job["id"])
        self.assertEqual(part, blob[1000:6000])
        self.assertEqual(h["x-ndt-log-next-offset"], "6000")

    def test_read_output_is_kept_byte_for_byte(self):
        """Judge finding 4: ndt cuts claim notes with `cut -c1-72`, which counts bytes, so a
        multi-byte character can be cut in half. The JSON answer shows it with U+FFFD; the bytes
        are kept and can be fetched back by the read's id."""
        cut = "claim note 中文".encode()[:-1] + b"\n"
        self.s.behave(status={"stdout_hex": cut.hex(), "stderr": "e\n"})
        st, j, _, _ = self.s.get("/status")
        self.assertIn("\ufffd", j["stdout"])
        rid = j["read"]["id"]
        st, _, _, raw = self.s.get("/reads/%s/log/stdout" % rid)
        self.assertEqual((st, raw), (200, cut))
        st, _, _, raw = self.s.get("/reads/%s/log/stderr" % rid)
        self.assertEqual(raw, b"e\n")

    def test_status_answers_with_rc_and_full_output(self):
        self.s.behave(status={"rc": 3, "stdout": "claim none\nno baseline\n", "stderr": "e\n"})
        st, j, _, _ = self.s.get("/status?check=1")
        self.assertEqual((j["rc"], j["rc_class"], j["stdout"], j["stderr"]), (3, "nothing", "claim none\nno baseline\n", "e\n"))
        self.assertEqual(j["argv"][1:], ["status", "--check"])

    def test_plain_status_is_not_a_verdict(self):
        """Plain `ndt status` answers 0 whatever it found (ndt: `return 0` after the report); only
        --check judges. The live run of 09-24 22:01 printed "all compared fields match" beside a
        plain status of a lab with no baseline -- nothing had been compared."""
        self.s.behave(status={"rc": 0})
        st, j, _, _ = self.s.get("/status")
        self.assertEqual((j["rc"], j["rc_class"]), (0, "report"))
        self.assertNotIn("match", j["meaning"])
        st, j, _, _ = self.s.get("/status?check=1")
        self.assertEqual((j["rc"], j["rc_class"]), (0, "ok"))


class ReadTimeout(unittest.TestCase):
    """Judge finding 7: the read-timeout path had never run."""

    def test_a_read_past_its_timeout_is_stopped_and_frees_its_slot(self):
        s = Serve(extra=["--read-timeout", "1"]).start()
        try:
            s.behave(status={"sleep": 20})
            t0 = time.monotonic()
            st, j, _, _ = s.get("/status")
            self.assertLess(time.monotonic() - t0, 8)
            self.assertEqual((st, j["rc_class"]), (200, "timeout"))
            pid = s.calls()[0]["pid"]
            time.sleep(0.3)
            self.assertFalse(_pid_alive(pid), "the timed-out ndt's group is still running")
            s.behave(status={"rc": 0})
            import threading
            res = []
            ts = [threading.Thread(target=lambda: res.append(s.get("/status")[0])) for _ in range(2)]
            [t.start() for t in ts]
            [t.join(20) for t in ts]
            self.assertEqual(res, [200, 200], "the timed-out read did not give its slot back")
        finally:
            s.close()

    def test_a_pipe_held_outside_the_group_does_not_hang_the_read(self):
        s = Serve(extra=["--read-timeout", "1"]).start()
        try:
            s.behave(status={"sleep": 20, "hold_pipe": 25})
            t0 = time.monotonic()
            st, j, _, _ = s.get("/status")
            self.assertLess(time.monotonic() - t0, 12, "the handler waited on a pipe it cannot close")
            self.assertEqual((st, j["rc_class"]), (200, "timeout"))
        finally:
            for gp in s.grandchildren():   # the test's own stub's child, by the pid it recorded
                try:
                    os.kill(gp, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            s.close()

    def test_reads_beyond_the_slots_wait_then_503(self):
        s = Serve(extra=["--read-timeout", "10", "--read-queue-wait", "1"]).start()
        try:
            s.behave(status={"sleep": 3})
            import threading
            res = []
            ts = [threading.Thread(target=lambda: res.append(s.get("/status")[0])) for _ in range(3)]
            for t in ts:
                t.start()
                time.sleep(0.1)
            [t.join(30) for t in ts]
            self.assertEqual(sorted(res), [200, 200, 503])
        finally:
            s.close()


# --- red line 5: long jobs --------------------------------------------------------------------

class Jobs(ServeCase):
    def test_write_returns_before_the_job_ends(self):
        self.s.behave(up={"sleep": 3})
        t0 = time.monotonic()
        st, j, _, _ = self.s.post("/up", {"plane": "ovs", "hosts": 4})
        self.assertEqual(st, 202)
        self.assertLess(time.monotonic() - t0, 1.5)
        self.assertEqual(j["job"]["state"], "running")
        self.assertEqual(self.s.wait(j["job"]["id"])["state"], "finished")

    def test_second_write_is_refused_while_one_runs(self):
        self.s.behave(up={"sleep": 3})
        st, j, _, _ = self.s.post("/up", {"plane": "ovs", "hosts": 4})
        first = j["job"]["id"]
        for p, b in (("/down", {}), ("/claim", {}), ("/up", {"plane": "p4"}), ("/apps/nsr/start", {})):
            st, j, _, _ = self.s.post(p, b)
            self.assertEqual((st, j["error"], j["job"]["id"]), (409, "busy", first), p)
        self.s.wait(first)
        self.assertEqual([c["argv"] for c in self.s.calls()], [["up", "4"]])

    def test_concurrent_writes_get_exactly_one_slot(self):
        """Judge finding 8: without `with SLOT:` two requests can both see a free slot."""
        import threading
        self.s.behave(up={"sleep": 3})
        barrier = threading.Barrier(20)
        res = []

        def one():
            barrier.wait()
            res.append(self.s.post("/up", {"plane": "ovs", "hosts": 4})[0])
        ts = [threading.Thread(target=one) for _ in range(20)]
        [t.start() for t in ts]
        [t.join(30) for t in ts]
        self.assertEqual((res.count(202), res.count(409)), (1, 19))
        time.sleep(0.5)
        self.assertEqual(len(self.s.calls()), 1)

    def test_a_zombie_is_not_alive(self):
        """Judge finding 8: a runner that has exited but not been reaped is still in /proc."""
        sys.path.insert(0, SERVE_DIR)
        try:
            import importlib
            jobs = importlib.import_module("jobs")
            importlib.reload(jobs)
        finally:
            sys.path.remove(SERVE_DIR)
        p = subprocess.Popen([sys.executable, "-c", "pass"])
        st = jobs.proc_starttime(p.pid)
        deadline = time.monotonic() + 5
        while jobs.proc_starttime(p.pid)[0] != "Z" and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(jobs.proc_starttime(p.pid)[0], "Z", "the child did not become a zombie")
        self.assertFalse(jobs.alive(p.pid, st[1]))
        p.wait()

    def test_slot_is_free_again_after_the_job(self):
        self.s.run_job("/up", {"plane": "ovs", "hosts": 4})
        self.assertEqual(self.s.run_job("/down")["state"], "finished")

    def test_job_outlives_the_server(self):
        self.s.behave(up={"sleep": 2, "rc": 1})
        st, j, _, _ = self.s.post("/up", {"plane": "ovs", "hosts": 4})
        job_id = j["job"]["id"]
        self.s.stop(signal.SIGKILL, group=True)     # what a closed terminal does to the server
        deadline = time.monotonic() + 15
        while not self.s.calls(done=True) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertEqual(len(self.s.calls(done=True)), 1, "ndt died with the server")
        self.s.start()
        job = self.s.wait(job_id)
        self.assertEqual((job["state"], job["rc"], job["rc_class"]), ("finished", 1, "dirty"))

    def test_restarted_server_still_honours_a_running_job(self):
        self.s.behave(up={"sleep": 4})
        st, j, _, _ = self.s.post("/up", {"plane": "ovs", "hosts": 4})
        job_id = j["job"]["id"]
        self.s.stop(signal.SIGKILL, group=True)
        self.s.start()
        st, j, _, _ = self.s.post("/down")
        self.assertEqual((st, j["job"]["id"]), (409, job_id))
        self.assertEqual(self.s.wait(job_id)["state"], "finished")
        self.assertEqual([c["argv"] for c in self.s.calls()], [["up", "4"]])

    def test_ndt_runs_in_a_session_of_its_own(self):
        job = self.s.run_job("/down")
        call = self.s.calls()[0]
        runner = json.loads(_read(os.path.join(self.s.state, "jobs", job["id"], "runner.json")))
        server_sid = os.getsid(self.s.proc.pid)
        self.assertNotEqual(runner["runner_sid"], server_sid, "the runner shares the server's session")
        self.assertNotEqual(call["sid"], runner["runner_sid"], "ndt shares the runner's session")
        self.assertNotEqual(call["sid"], server_sid)

    def test_an_orphaned_ndt_still_holds_the_slot(self):
        """The runner is gone and ndt is still building: that is not a free slot."""
        self.s.behave(up={"sleep": 3})
        st, j, _, _ = self.s.post("/up", {"plane": "ovs", "hosts": 4})
        job_id = j["job"]["id"]
        rj = os.path.join(self.s.state, "jobs", job_id, "runner.json")
        deadline = time.monotonic() + 5
        while not os.path.exists(rj) and time.monotonic() < deadline:
            time.sleep(0.05)
        runner = json.loads(_read(rj))
        # the runner this test's server started, by the pid it recorded -- checked before the signal
        with open("/proc/%d/cmdline" % runner["runner_pid"], "rb") as f:
            self.assertIn(b"runner.py", f.read())
        os.kill(runner["runner_pid"], signal.SIGKILL)
        deadline = time.monotonic() + 5
        while self.s.get("/jobs/" + job_id)[1]["job"]["state"] == "running" and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertEqual(self.s.get("/jobs/" + job_id)[1]["job"]["state"], "orphaned")
        st, j, _, _ = self.s.post("/down")
        self.assertEqual((st, j["error"], j["job"]["id"]), (409, "busy", job_id))
        deadline = time.monotonic() + 10
        while not self.s.calls(done=True) and time.monotonic() < deadline:
            time.sleep(0.1)
        time.sleep(0.3)
        job = self.s.get("/jobs/" + job_id)[1]["job"]
        self.assertEqual((job["state"], job["rc"]), ("lost", None), "its rc was never recorded, so none is claimed")
        self.assertEqual(self.s.run_job("/down")["state"], "finished")

    def test_jobs_are_listed_newest_first_within_one_second(self):
        for job_id, created in (("20260101T000000Z-ffffff", 100.1), ("20260101T000000Z-000000", 100.9)):
            d = os.path.join(self.s.state, "jobs", job_id)
            os.makedirs(d)
            with open(os.path.join(d, "request.json"), "w") as f:
                json.dump({"id": job_id, "kind": "down", "argv": ["ndt", "down"], "cwd": "/", "created_at": created}, f)
            with open(os.path.join(d, "exit.json"), "w") as f:
                json.dump({"rc": 0}, f)
        st, j, _, _ = self.s.get("/jobs")
        self.assertEqual([v["id"] for v in j["jobs"]], ["20260101T000000Z-000000", "20260101T000000Z-ffffff"])

    def test_a_job_nobody_recorded_is_lost_not_finished(self):
        d = os.path.join(self.s.state, "jobs", "20260101T000000Z-abcdef")
        os.makedirs(d)
        for name, obj in (("request.json", {"id": "20260101T000000Z-abcdef", "kind": "up", "argv": ["ndt", "up"], "cwd": "/"}),
                          ("spawn.json", {"runner_pid": 2 ** 22 + 7, "runner_starttime": 1})):
            with open(os.path.join(d, name), "w") as f:
                json.dump(obj, f)
        st, j, _, _ = self.s.get("/jobs/20260101T000000Z-abcdef")
        self.assertEqual((j["job"]["state"], j["job"]["rc"], j["job"]["rc_class"]), ("lost", None, "unknown"))
        self.assertEqual(self.s.run_job("/down")["state"], "finished", "a lost job must not hold the slot")


# --- red line 6: no pattern kills -------------------------------------------------------------

class NoPatternKill(unittest.TestCase):
    def test_no_process_is_found_or_signalled_by_name(self):
        """Through the tree's own instrument, not a word list of this file's: a word list here
        would itself be a site that tool reports (it did, 09-24)."""
        checker = os.path.join(REPO, "tests", "shell", "check_process_by_name.py")
        files = sorted(glob.glob(os.path.join(SERVE_DIR, "*.py")))
        self.assertGreaterEqual(len(files), 4)
        r = subprocess.run([sys.executable, checker] + files, capture_output=True, text=True, timeout=60)
        # named files: silent and rc 0 when clean; a site is a `<file>:<line>: RUNS|TEACHES` row, rc 1
        self.assertEqual((r.returncode, r.stdout.strip()), (0, ""), r.stdout + r.stderr)
        calls = [(os.path.basename(p), text, line) for p in files for kind, text, line in code_facts(p)
                 if kind == "call" and text in ("os.kill", "signal.pthread_kill")]
        names = [(os.path.basename(p), line) for p in files for kind, text, line in code_facts(p)
                 if kind == "name" and text == "psutil"]
        self.assertEqual((calls, names), ([], []))

    def test_the_only_signal_sent_is_to_a_group_this_service_created(self):
        """The timeout paths of run_read (serve.py) and Grid._run (cells.py) are the two places a
        signal is sent; each must name the pid of the Popen it started with start_new_session,
        never a looked-up process."""
        sends = [(os.path.basename(p), text, line) for p in glob.glob(os.path.join(SERVE_DIR, "*.py"))
                 for kind, text, line in code_facts(p)
                 if kind == "call" and (text.startswith("os.kill") or text.endswith(".send_signal")
                                        or text.endswith(".terminate") or text.endswith(".kill"))]
        self.assertEqual({t for _, t, _ in sends}, {"os.killpg"}, sends)
        for name in {f for f, _, _ in sends}:
            src = _read(os.path.join(SERVE_DIR, name))
            self.assertIn("os.killpg(p.pid, signal.SIGKILL)", src, name)
            self.assertIn("start_new_session=True", src, name)
        # 🔴 judge r2 finding 4: subprocess.run(timeout=...) kills its child implicitly -- a signal
        # this scan cannot see, sent to the child and not to its group. None may remain.
        implicit = [(os.path.basename(p), line) for p in glob.glob(os.path.join(SERVE_DIR, "*.py"))
                    for kind, text, line in code_facts(p)
                    if kind == "kw" and text.startswith("timeout=") and "subprocess.run" in
                    _read(p).splitlines()[line - 1]]
        self.assertEqual(implicit, [])


# --- red line 7: identity ---------------------------------------------------------------------

class Identity(unittest.TestCase):
    def test_every_ndt_call_carries_the_owner(self):
        s = Serve().start()
        try:
            s.get("/status")
            s.get("/apps")
            s.run_job("/claim", {"minutes": 5})
            s.run_job("/up", {"plane": "ovs", "hosts": 4})
            s.run_job("/apps/nsr/start")
            s.run_job("/release")
            calls = s.calls()
            self.assertEqual(len(calls), 6)
            self.assertEqual({c["owner"] for c in calls}, {OWNER})
        finally:
            s.close()

    def test_inherited_ndt_variables_are_not_passed(self):
        s = Serve(env={"NDT_TOPO": "/elsewhere.json", "NDT_MEASURING": "x", "NDT_OWNER": "somebody-else"}).start()
        try:
            s.run_job("/down")
            c = s.calls()[0]
            self.assertEqual((c["owner"], c["ndt_env"]), (OWNER, ["NDT_OWNER"]))
            st, j, _, _ = s.get("/health")
            self.assertEqual(j["stripped_env"], ["NDT_MEASURING", "NDT_OWNER", "NDT_TOPO"])
        finally:
            s.close()

    def test_jobs_run_the_ndt_resolved_at_start(self):
        """Judge finding 6: the record names the sha of the file that ran. Re-pointing the symlink
        after start neither changes what runs nor goes unreported."""
        s = Serve()
        try:
            other = os.path.join(s.tmp, "other", "tools", "test_workflow")
            os.makedirs(other)
            for f in ("ndt", "stub.py"):
                shutil.copy2(os.path.join(s.stubdir, f), os.path.join(other, f))
            link = os.path.join(s.tmp, "bin", "ndt")
            os.makedirs(os.path.dirname(link))
            os.symlink(s.ndt, link)
            real = s.ndt
            s.ndt = link
            s.start()
            os.remove(link)
            os.symlink(os.path.join(other, "ndt"), link)
            job = s.run_job("/down")
            self.assertEqual(job["argv"][0], real)
            self.assertEqual(len(s.calls()), 1, "the call did not reach the ndt resolved at start")
            self.assertFalse(os.path.exists(os.path.join(other, "calls.jsonl")), "the re-pointed ndt ran")
            st, j, _, _ = s.get("/health")
            self.assertTrue(j["ndt_drift"])
            self.assertEqual(j["ndt_realpath_now"], os.path.join(other, "ndt"))
        finally:
            s.close()

    def test_server_refuses_to_start_without_an_owner(self):
        s = Serve()
        try:
            for owner in (None, "a b", "", "x" * 65):
                argv = s.argv()
                i = argv.index("--owner")
                argv = argv[:i] + argv[i + 2:] if owner is None else argv[:i + 1] + [owner] + argv[i + 2:]
                s.start(argv, expect_ok=False)
                self.assertEqual(s.proc.wait(10), 2, owner)
                self.assertFalse(os.path.exists(s.token_file))
        finally:
            s.close()


class RcProvenance(unittest.TestCase):
    """Judge finding 5: say where each rc table comes from, and hold it to that source -- the real
    ndt of this tree, not a stub."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, SERVE_DIR)
        try:
            import importlib
            cls.verbs = importlib.reload(importlib.import_module("verbs"))
        finally:
            sys.path.remove(SERVE_DIR)
        with open(NDT) as f:
            cls.lines = f.read().splitlines()
        r = subprocess.run([NDT, "help"], capture_output=True, text=True, timeout=60)
        cls.help = " ".join((r.stdout + r.stderr).split())

    def test_every_table_names_its_source(self):
        v = self.verbs
        self.assertEqual(sorted(v.RC_SOURCE), sorted(k for k in v.RC_TABLE if k != "cells.run"))

    def test_help_sourced_tables_are_in_ndt_help(self):
        for kind, src in self.verbs.RC_SOURCE.items():
            if "help" not in src:
                continue
            self.assertEqual(sorted(src["help"]), sorted(self.verbs.RC_TABLE[kind]), kind)
            for rc, phrase in src["help"].items():
                self.assertIn(" ".join(phrase.split()), self.help, "%s rc %d" % (kind, rc))

    FUNC_DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_:-]*)\s*\(\)\s*\{")

    def enclosing_function(self, n):
        """The function ndt line n lies in: the nearest `name() {` at column 0 above it, with no
        column-0 `}` (a function's end) in between and not a one-line definition. None when the
        line is at top level."""
        for i in range(n - 2, -1, -1):
            text = self.lines[i]
            m = self.FUNC_DEF.match(text)
            if m:
                return None if text.rstrip().endswith("}") else m.group(1)
            if text.startswith("}"):
                return None
        return None

    def test_code_sourced_tables_are_in_ndt(self):
        """Each anchor is its line, the text on it AND the function it lies in (intake judge 09-26,
        finding 3): `return 1` is on a great many lines, and a line number pointed back at 09-24's
        8315 -- proc_checkout's `return 1` today -- passed a check of the text alone. Every
        anchor is checked and every broken one named, not only the first."""
        bad = []
        for kind, src in self.verbs.RC_SOURCE.items():
            if "code" not in src:
                continue
            self.assertEqual(sorted({a[1] for a in src["code"]}), sorted(self.verbs.RC_TABLE[kind]), kind)
            for line, rc, needle, func in src["code"]:
                text = self.lines[line - 1] if 0 < line <= len(self.lines) else "<past the end of ndt>"
                where = self.enclosing_function(line) if 0 < line <= len(self.lines) else None
                if needle not in text or where != func:
                    bad.append("%s rc %d: ndt:%d is %r in %s, cited as %r in %s" % (
                        kind, rc, line, text.strip(), where, needle, func))
        self.assertEqual(bad, [])

    def test_the_function_finder_reads_ndt(self):
        """The finder above, on the real ndt's claim_line: a finder that answered the cited name
        whatever the line, or None whatever the line, would make the check above decoration."""
        starts = [i + 1 for i, t in enumerate(self.lines) if t.startswith("claim_line() {")]
        self.assertEqual(len(starts), 1, "claim_line() is defined once")
        start = starts[0]
        end = next(i + 1 for i in range(start, len(self.lines)) if self.lines[i].startswith("}"))
        self.assertEqual([self.enclosing_function(n) for n in (start, start + 1, end - 1, end + 1)],
                         [None, "claim_line", "claim_line", None])

    def test_status_check_rc1_names_any_problem(self):
        c, m = self.verbs.meaning("status.check", 1)
        self.assertEqual(c, "dirty")
        for word in ("problem", "claim", "measurement", "output"):
            self.assertIn(word, m)


class DemoProbes(unittest.TestCase):
    def test_demo_probes_cannot_touch_the_lab(self):
        """Judge finding 3: a probe that carries the token and names a writer IS a writer the
        moment the slot is free. Every call whose step is a probe must be a GET or carry no token."""
        import ast
        tree = ast.parse(_read(os.path.join(SERVE_DIR, "demo_sequence.py")))
        probes = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and getattr(node.func, "attr", None) == "call" and node.args \
                    and isinstance(node.args[0], ast.Constant) and "probe" in str(node.args[0].value):
                method = node.args[1].value if len(node.args) > 1 and isinstance(node.args[1], ast.Constant) else "?"
                tok = [k.value.value for k in node.keywords if k.arg == "token" and isinstance(k.value, ast.Constant)]
                probes.append((node.args[0].value, method, tok))
        self.assertGreaterEqual(len(probes), 3)
        for name, method, tok in probes:
            self.assertTrue(method == "GET" or tok == [False], "%s: %s with the token" % (name, method))
        self.assertNotIn("none of which can change anything", _read(os.path.join(SERVE_DIR, "demo_sequence.py")))


# --- red line 8 and the routes: the entry point -----------------------------------------------

class Entry(unittest.TestCase):
    def test_ndt_help_lists_serve(self):
        r = subprocess.run([NDT, "help"], capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, NDT_OWNER=OWNER))
        self.assertRegex(r.stdout + r.stderr, r"\n  serve \[--owner")

    def test_ndt_serve_execs_this_server(self):
        r = subprocess.run([NDT, "serve", "--help"], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("usage: ndt serve", r.stdout)
        self.assertIn("127.0.0.1", r.stdout)

    def test_root_is_reserved_for_the_gui(self):
        s = Serve().start()
        try:
            for p in ("/", "/index.html", "/app.js", "/apiv1/health"):
                st, j, _, _ = s.request("GET", p)
                self.assertEqual(st, 404, p)
                self.assertIn("reserved for the Web-GUI", j["note"])
        finally:
            s.close()

    def test_second_server_on_the_same_state_refuses(self):
        s = Serve().start()
        other = None
        try:
            tok = s.token()
            other = Serve(tmp=s.tmp)
            other.start(expect_ok=False)
            self.assertNotEqual(other.proc.wait(10), 0)
            self.assertIn("another ndt serve", _read(other.out + ".err"))
            self.assertEqual(s.token(), tok, "a server that could not start replaced the running one's token")
            st, _, _, _ = s.get("/health")
            self.assertEqual(st, 200)
        finally:
            if other is not None:   # when it wrongly started (M40), it is still running
                other.stop(signal.SIGKILL)
            s.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
