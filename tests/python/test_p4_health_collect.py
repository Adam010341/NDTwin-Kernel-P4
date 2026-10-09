#!/usr/bin/env python3
"""The P4 health check's reading layer and lab lifecycle, sealed off from the lab (design 5.2-②).

[Co-developed with claude code -- Adam]

HERMETIC BY CONSTRUCTION -- a breach is REFUSED when it happens, recorded, and every test ends by
asserting nothing was attempted (hardened in the Cut 1 review, MAJ-7):

  * PATH starts with a directory whose `sudo`, `tc`, `ndt`, `mnexec` and `simple_switch_CLI`
    exit 99 and append to a TRIPWIRE file; every test asserts that file does not exist.
  * `subprocess.Popen` refuses (PermissionError) anything whose executable is not one of those
    stubs, and `os.system`, `os.popen`, `os.exec*`, `os.spawn*`, `os.posix_spawn*`, `os.fork*`
    refuse everything.
  * Every AF_INET / AF_INET6 `connect`, `connect_ex`, `sendto`, `sendmsg` and
    `socket.create_connection` is refused -- whatever the address: 127.0.0.1, the rest of
    127/8, ::1, IPv4-mapped loopback, the host's own addresses and the lab's ports all included.
  * `grpc` is replaced in sys.modules by a stub that raises on any use.
  * The real knob files and claim file -- this checkout's and its main checkout's -- are
    fingerprinted at import and after every test; any change is a red test.
  * P4H_HERMETIC=1: a Config that would default anything to the real machine is refused.

The code under test is handed ONE RecordingRunner and ONE Config whose HTTP clients are
in-process fakes. The package is tools/p4_health, or $P4_HEALTH_UNDER_TEST's copy.
"""
import base64
import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.environ.get("P4_HEALTH_UNDER_TEST") or os.path.join(REPO, "tools"))
FIXTURES = os.path.join(REPO, "tests", "python", "fixtures", "p4_health", "thrift")
os.environ["P4H_HERMETIC"] = "1"


def _checkouts():
    """This checkout, and -- when it is a git worktree -- the main checkout its .git file names
    (read from the file, not from `git`: nothing is spawned)."""
    out = [REPO]
    try:
        with open(os.path.join(REPO, ".git")) as fh:
            line = fh.read().strip()
        if line.startswith("gitdir:"):
            gitdir = line.split(":", 1)[1].strip()
            common = os.path.dirname(os.path.dirname(gitdir))       # <main>/.git/worktrees/x
            out.append(os.path.dirname(common))
    except OSError:
        pass
    return out


REAL_FILES = sorted({os.path.join(c, rel) for c in _checkouts() for rel in (
    "p4_proxy/mininet/host_count_override", "p4_proxy/mininet/telemetry_override",
    "p4_proxy/mininet/app_package_override", ".test_run/lab.claim")})


def _fingerprint():
    out = {}
    for path in REAL_FILES:
        try:
            with open(path, "rb") as fh:
                out[path] = hashlib.sha256(fh.read()).hexdigest()
        except OSError:
            out[path] = None
    return out


REAL_BEFORE = _fingerprint()

# --- the seal ---------------------------------------------------------------------------------------
SEAL = tempfile.mkdtemp(prefix="p4h-collect-seal-%d-" % os.getpid())
STUBS = os.path.join(SEAL, "bin")
TRIPWIRE = os.path.join(SEAL, "TRIPWIRE")
os.makedirs(STUBS)
for _name in ("sudo", "tc", "ndt", "mnexec", "simple_switch_CLI"):
    _path = os.path.join(STUBS, _name)
    with open(_path, "w") as _fh:
        _fh.write('#!/bin/sh\necho "%s $*" >> "%s"\nexit 99\n' % (_name, TRIPWIRE))
    os.chmod(_path, 0o755)
os.environ["PATH"] = STUBS + os.pathsep + os.environ.get("PATH", "")

ATTEMPTS = []          # network: every inet connect / send, refused
SPAWNS = []            # processes: every spawn, refused unless it is a stub (which then trips)
_orig_connect = socket.socket.connect
_orig_connect_ex = socket.socket.connect_ex
_orig_sendto = socket.socket.sendto
_orig_sendmsg = socket.socket.sendmsg
_orig_create = socket.create_connection
_orig_popen_init = subprocess.Popen.__init__
INET = (socket.AF_INET, socket.AF_INET6)


def _refuse_net(what, address):
    ATTEMPTS.append((what, tuple(address[:2]) if isinstance(address, tuple) else address))
    raise ConnectionRefusedError("hermetic test: %s to %r refused" % (what, address))


def _connect(self, address):
    if self.family in INET:
        _refuse_net("connect", address)
    return _orig_connect(self, address)


def _connect_ex(self, address):
    if self.family in INET:
        ATTEMPTS.append(("connect_ex", tuple(address[:2]) if isinstance(address, tuple) else address))
        return 111
    return _orig_connect_ex(self, address)


def _sendto(self, data, *args):
    if self.family in INET:
        _refuse_net("sendto", args[-1])
    return _orig_sendto(self, data, *args)


def _sendmsg(self, buffers, *args):
    if self.family in INET:
        _refuse_net("sendmsg", args[-1] if args else None)
    return _orig_sendmsg(self, buffers, *args)


def _create(address, *a, **kw):
    _refuse_net("create_connection", address)


def _popen_init(self, *a, **kw):
    args = a[0] if a else kw.get("args")
    SPAWNS.append(args)
    argv0 = (args if isinstance(args, str) else (list(args) or [""])[0]).split()[0] if args else ""
    exe = kw.get("executable") or argv0
    resolved = exe if os.sep in str(exe) else shutil.which(str(exe))
    if not resolved or not os.path.realpath(resolved).startswith(os.path.realpath(STUBS) + os.sep):
        raise PermissionError("hermetic test: spawning %r refused (only the fail-loud stubs run)" % (args,))
    return _orig_popen_init(self, *a, **kw)


def _os_refuser(name):
    def refuse(*a, **kw):
        SPAWNS.append((name,) + tuple(str(x) for x in a[:2]))
        raise PermissionError("hermetic test: os.%s refused" % name)
    return refuse


socket.socket.connect = _connect
socket.socket.connect_ex = _connect_ex
socket.socket.sendto = _sendto
socket.socket.sendmsg = _sendmsg
socket.create_connection = _create
subprocess.Popen.__init__ = _popen_init
OS_REFUSED = [n for n in ("system", "popen", "execv", "execve", "execvp", "execvpe", "execl", "execle",
                          "execlp", "execlpe", "spawnv", "spawnve", "spawnvp", "spawnvpe", "spawnl",
                          "spawnle", "spawnlp", "spawnlpe", "posix_spawn", "posix_spawnp", "fork",
                          "forkpty") if hasattr(os, n)]
for _n in OS_REFUSED:
    setattr(os, _n, _os_refuser(_n))


class _GrpcStub(types.ModuleType):
    def __getattr__(self, name):
        raise RuntimeError("hermetic test: grpc.%s used" % name)


sys.modules["grpc"] = _GrpcStub("grpc")

from p4_health import lab_round as LR  # noqa: E402
from p4_health import observe as OB  # noqa: E402
from p4_health import throwaway as TW  # noqa: E402
from p4_health.cells import table as T  # noqa: E402
from p4_health.cells import verdict as V  # noqa: E402
from p4_health.collect import fabric as FB  # noqa: E402
from p4_health.collect import proxy as P  # noqa: E402
from p4_health.collect import ps as PS  # noqa: E402
from p4_health.collect import sniff as S  # noqa: E402
from p4_health.collect import tc as TC  # noqa: E402
from p4_health.collect import thrift as TH  # noqa: E402
from p4_health.collect.config import Config, HermeticViolation, HttpReply  # noqa: E402
from p4_health.collect.runner import RecordingRunner  # noqa: E402


#: What every test's tearDown checked, for $P4H_SEAL_REPORT (an audit of the seal itself).
SEAL_LOG = {"tests_checked": 0, "tripwire_hits": [], "network_attempts": [], "spawns": [],
            "real_files_changed": [], "path_head": STUBS, "stubs": sorted(os.listdir(STUBS)),
            "os_refused": OS_REFUSED, "real_files": REAL_FILES}


def tearDownModule():
    report = os.environ.get("P4H_SEAL_REPORT")
    if report:
        with open(report, "w") as fh:
            json.dump(SEAL_LOG, fh, indent=2, default=str)
    shutil.rmtree(SEAL, ignore_errors=True)


def fixture(name):
    with open(os.path.join(FIXTURES, name + ".txt")) as fh:
        return fh.read()


class FakeHttp(object):
    """An in-process HTTP client: {(METHOD, path): (status, body) or callable(body)}."""

    def __init__(self, routes=None):
        self.routes = dict(routes or {})
        self.calls = []

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        hit = self.routes.get((method, path))
        if hit is None:
            return HttpReply(404, {"detail": "Not Found"}, "")
        if callable(hit):
            hit = hit(body)
        return HttpReply(hit[0], hit[1], json.dumps(hit[1]))

    def get(self, path):
        return self.request("GET", path)

    def post(self, path, body):
        return self.request("POST", path, body)


class Sealed(unittest.TestCase):
    """Every test: no tripwire, no network, no spawn, no real file changed."""

    def setUp(self):
        del ATTEMPTS[:]
        del SPAWNS[:]
        self.tmp = tempfile.mkdtemp(prefix="p4h-collect-%d-" % os.getpid())
        self.knobs = os.path.join(self.tmp, "knobs")
        os.makedirs(self.knobs)
        os.makedirs(os.path.join(self.tmp, "test_run"))
        self.proxy = FakeHttp()
        self.kernel = FakeHttp()
        self.cfg = Config(run_dir=os.path.join(self.tmp, "run"), proxy=self.proxy, kernel=self.kernel,
                          ndt="ndt", owner="p4h-test", knob_dir=self.knobs,
                          test_run_dir=os.path.join(self.tmp, "test_run"),
                          thrift_cli=["simple_switch_CLI"], qdisc_snapshot="qdisc_snapshot.sh",
                          expected_tsv=os.path.join(self.tmp, "none.tsv"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)
        tripped = os.path.exists(TRIPWIRE)
        detail = ""
        if tripped:
            with open(TRIPWIRE) as fh:
                detail = fh.read()
            os.remove(TRIPWIRE)
        changed = sorted(p for p, h in _fingerprint().items() if h != REAL_BEFORE[p])
        SEAL_LOG["tests_checked"] += 1
        if tripped:
            SEAL_LOG["tripwire_hits"].append([self.id(), detail])
        SEAL_LOG["network_attempts"] += [[self.id(), a] for a in ATTEMPTS]
        SEAL_LOG["spawns"] += [[self.id(), sp] for sp in SPAWNS]
        SEAL_LOG["real_files_changed"] += [[self.id(), c] for c in changed]
        self.assertFalse(tripped, "a fail-loud stub was run: %s" % detail)
        self.assertEqual(ATTEMPTS, [], "a lab port was dialled (or any network)")
        self.assertEqual(SPAWNS, [], "a process was spawned")
        self.assertEqual(changed, [], "a real knob or claim file changed")


# --- the seal checks itself ----------------------------------------------------------------------------

class TestTheSealHolds(Sealed):

    def test_every_loopback_and_lab_address_is_refused(self):
        for family, addr in ((socket.AF_INET, ("127.0.0.1", 8081)), (socket.AF_INET, ("127.0.1.1", 8081)),
                             (socket.AF_INET, ("127.255.0.9", 9091)), (socket.AF_INET, ("0.0.0.0", 8000)),
                             (socket.AF_INET6, ("::1", 30051)), (socket.AF_INET6, ("::ffff:127.0.0.1", 8081)),
                             (socket.AF_INET, ("10.0.0.1", 80))):
            with self.subTest(addr=addr):
                s = socket.socket(family, socket.SOCK_STREAM)
                try:
                    with self.assertRaises(ConnectionRefusedError):
                        s.connect(addr)
                finally:
                    s.close()
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            with self.assertRaises(ConnectionRefusedError):
                u.sendto(b"x", ("127.0.1.1", 6343))
        finally:
            u.close()
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(("localhost", 8081))
        self.assertEqual(len(ATTEMPTS), 9)
        self.assertIn(("connect", ("127.0.1.1", 8081)), ATTEMPTS)
        del ATTEMPTS[:]

    def test_the_stubs_are_first_on_path_and_trip(self):
        self.assertEqual(shutil.which("ndt"), os.path.join(STUBS, "ndt"))
        self.assertEqual(shutil.which("simple_switch_CLI"), os.path.join(STUBS, "simple_switch_CLI"))
        rc = subprocess.call(["ndt", "status"])
        self.assertEqual(rc, 99)
        self.assertTrue(os.path.exists(TRIPWIRE))
        os.remove(TRIPWIRE)
        del SPAWNS[:]

    def test_anything_but_a_stub_is_refused_before_it_runs(self):
        for argv in (["true"], ["/usr/bin/env", "true"], [sys.executable, "-c", "pass"]):
            with self.subTest(argv=argv):
                with self.assertRaises(PermissionError):
                    subprocess.run(argv)
        with self.assertRaises(PermissionError):
            subprocess.Popen(["ndt"], executable="/bin/true")
        for name in ("system", "popen", "execv", "spawnv", "posix_spawn"):
            with self.subTest(os_call=name):
                with self.assertRaises(PermissionError):
                    getattr(os, name)("/bin/true", ["/bin/true"]) if name != "system" and name != "popen" \
                        else getattr(os, name)("true")
        self.assertTrue(len(SPAWNS) >= 9)
        self.assertFalse(os.path.exists(TRIPWIRE))
        del SPAWNS[:]

    def test_grpc_is_a_stub(self):
        import grpc
        with self.assertRaises(RuntimeError):
            grpc.insecure_channel("localhost:30051")

    def test_a_config_that_would_default_to_the_machine_is_refused(self):
        with self.assertRaises(HermeticViolation):
            Config(run_dir=self.tmp)
        with self.assertRaises(HermeticViolation):
            Config(run_dir=self.tmp, proxy=self.proxy, kernel=self.kernel, ndt="ndt",
                   test_run_dir=self.tmp, thrift_cli=["x"], qdisc_snapshot="q", expected_tsv="e")

    def test_the_real_files_are_watched(self):
        self.assertTrue(any(p.endswith("p4_proxy/mininet/host_count_override") for p in REAL_FILES))
        self.assertTrue(any(p.endswith(".test_run/lab.claim") for p in REAL_FILES))


# --- thrift: the real formats ---------------------------------------------------------------------------

class TestThriftParsers(Sealed):

    def test_table_dumps(self):
        d = TH.parse_table_dump(TH.body(fixture("table_dump_lpm")))
        self.assertEqual(len(d["entries"]), 7)
        e = d["entries"][3]
        self.assertEqual(e["keys"], [("ipv4.dstAddr", "LPM", "0a000404/32")])
        self.assertEqual((e["action"], e["params"]), ("HcIngress.ipv4_forward", [0x080000000444, 1]))
        self.assertEqual(d["default"]["action"], "HcIngress.drop")
        tern = TH.parse_table_dump(TH.body(fixture("table_dump_ternary")))
        self.assertEqual([(TH.key_value(k, v), x["priority"]) for x in tern["entries"] for (_f, k, v) in x["keys"]],
                         [((0x0A000100, 0xFFFFFF00), 10), ((0x0A000000, 0xFFFF0000), 20)])
        rng = TH.parse_table_dump(TH.body(fixture("table_dump_range")))
        self.assertEqual(TH.key_value(*rng["entries"][0]["keys"][0][1:]), (40000, 40010))
        self.assertEqual(TH.parse_table_dump(TH.body(fixture("table_dump_ap")))["entries"][0]["member"], 0)
        self.assertEqual(TH.parse_table_dump(TH.body(fixture("table_dump_as")))["entries"][0]["group"], 0)
        self.assertEqual(TH.parse_table_dump(TH.body(fixture("table_dump_idle")))["entries"][0]["life"][1], 5000)

    def test_the_two_defaults_of_t2(self):
        rt = TH.parse_table_dump(TH.body(fixture("table_dump_default_runtime")))["default"]
        ct = TH.parse_table_dump(TH.body(fixture("table_dump_default_compiled")))["default"]
        self.assertEqual((rt["action"], rt["params"]), ("HcIngress.stamp", [0x2A]))
        self.assertEqual((ct["action"], ct["params"]), ("HcIngress.stamp", [0]))

    def test_counters_registers_meters(self):
        self.assertEqual(TH.parse_counter(TH.body(fixture("counter_c_in"))), (0, 0))
        self.assertEqual(TH.parse_register(TH.body(fixture("register_r_mark"))), 0)
        self.assertEqual(TH.parse_meter_rates(TH.body(fixture("meter_unset"))), [])
        self.assertEqual(TH.parse_meter_rates(TH.body(fixture("meter_set"))), [(0.001, 1000), (0.002, 2000)])

    def test_pre_objects(self):
        self.assertEqual(TH.parse_mc_dump(TH.body(fixture("mc_dump_empty"))), {})
        self.assertEqual(TH.parse_mc_dump(TH.body(fixture("mc_dump_group"))), {2: frozenset({1, 3})})
        self.assertEqual(TH.parse_mirroring(TH.body(fixture("mirroring_port"))),
                         {"present": True, "port": 1, "mgid": None})
        self.assertEqual(TH.parse_mirroring(TH.body(fixture("mirroring_mgid"))),
                         {"present": True, "port": None, "mgid": 32777})

    def test_absent_is_a_recognised_reply_and_unreadable_is_none(self):
        self.assertEqual(TH.parse_mirroring(TH.body(fixture("mirroring_absent"))), {"present": False})
        for name in ("no_switch", "counter_unknown", "table_unknown"):
            with self.subTest(fixture=name):
                self.assertIsNone(TH.body(fixture(name)))
        self.assertIsNone(TH.parse_mc_dump(TH.body(fixture("no_switch"))))
        self.assertIsNone(TH.parse_table_dump(None))
        self.assertIsNone(TH.parse_counter(TH.body("")))

    def test_profiles_value_sets_tables_ports(self):
        ap = TH.parse_act_prof(TH.body(fixture("act_prof_group")))
        self.assertEqual(ap["groups"], {0: [0]})
        self.assertEqual(ap["members"][0], ("HcIngress.set_mark", (3,)))
        self.assertEqual(TH.parse_act_prof(TH.body(fixture("act_prof_empty"))), {"members": {}, "groups": {}})
        self.assertEqual(TH.parse_pvs(TH.body(fixture("pvs_empty"))), set())
        tables = TH.parse_show_tables(TH.body(fixture("show_tables")))
        self.assertEqual(tables["HcIngress.t_ap"][0], "HcIngress.ap_prof")
        self.assertNotIn("HcIngress.alt_port_stamp", tables)
        self.assertEqual(TH.parse_show_ports(TH.body(fixture("show_ports"))), {1: "p1", 2: "p2", 3: "p3", 510: "p510"})

    def test_the_reader_runs_read_only_commands_on_the_switchs_port_through_the_runner(self):
        r = RecordingRunner().add(("simple_switch_CLI",), (0, fixture("counter_c_in")))
        reader = TH.ThriftReader(self.cfg, r)
        self.assertEqual(reader.read(2, "counter_read HcIngress.c_in 0"), (0, 0))
        self.assertEqual(r.calls[0]["argv"], ["simple_switch_CLI", "--thrift-port", "9092"])
        self.assertEqual(r.calls[0]["input"], "counter_read HcIngress.c_in 0\n")
        for cmd in ("table_add HcIngress.port_exact x 1 => 2", "register_write HcIngress.r_mark 0 1",
                    "mirroring_add 9 1", "pvs_add HcParser.vs_ports 1", "table_clear HcIngress.t_ap",
                    "counter_read HcIngress.c_in 0\nregister_write HcIngress.r_mark 0 1",
                    "show_tables; table_clear HcIngress.t_ap", "table_num_entries HcIngress.t_ap"):
            with self.subTest(cmd=cmd):
                with self.assertRaises(TH.WriteRefused):
                    reader.read(1, cmd)
        self.assertEqual(len(r.calls), 1)


# --- where each number comes from (M3, M4) -----------------------------------------------------------

class TestWhereTheNumbersComeFrom(Sealed):

    def test_sent_is_what_the_sender_says_it_sent(self):
        out = "warming up\nSENT cell=K1 n=3 ident=0 requested=5000\nSENT cell=Q1 n=9 ident=0 requested=9\n"
        self.assertEqual(S.sent(out, "K1"), 3)
        self.assertEqual(S.sent(out, "K2"), None)
        self.assertEqual(S.sent_idents(out, "Q1"), {0})
        rx = S.received('RX {"cell": "K1", "seq": 1, "run": "r1"}\nRX {"cell": "K2"}\nRX not-json\n', "K1", "r1")
        self.assertEqual(len(rx), 1)

    def test_the_oracle_is_thrifts_and_never_the_proxys(self):
        reads = iter([fixture("counter_c_in"),
                      fixture("counter_c_in").replace("(0 bytes, 0 packets)", "(335 bytes, 5 packets)")])
        r = RecordingRunner().add(("simple_switch_CLI",), lambda a, e, i: (0, next(reads)))
        answers = iter([(200, {"packets": 100}), (200, {"packets": 107})])
        self.proxy.routes[("GET", "/p4/counter/HcIngress.c_in?dpid=2&index=0")] = lambda b: next(answers)
        obs = OB.observe_counter(self.cfg, r, 2, "c_in", 0,
                                 lambda: "SENT cell=K1 n=5 ident=1 requested=5000\n", "K1")
        self.assertEqual(obs["oracle"], {"delta": 5})
        self.assertEqual(obs["answer"], {"http": 200, "delta": 7})
        self.assertEqual(obs["sent"], 5)
        ctx = V.Context()
        ctx.self_checks["SC-count"] = V.Verdict(V.GREEN, "fixture")
        ctx.cells["K1-neg"] = V.Verdict(V.GREEN, "fixture")
        v = V.decide(T.TABLE.cell("K1"), obs, ctx)
        self.assertEqual(v.verdict, V.RED)
        self.assertIn("NDTwin read 7, thrift 5", v.reason)

    def test_an_unreadable_negative_read_is_not_absent(self):
        ok = fixture("mc_dump_group").replace("mgrp(2)", "mgrp(1)").replace("[1, 3]", "[1, 2]")
        replies = {"9091": ok, "9092": fixture("no_switch"), "9093": fixture("mc_dump_empty"),
                   "9094": fixture("mc_dump_empty")}
        r = RecordingRunner().add(("simple_switch_CLI",), lambda a, e, i: (0, replies[a[2]]))
        self.proxy.routes[("GET", "/p4/switch_state")] = (200, {"switches": {"1": {"pre_entries": {
            "multicast": {"recorded": 1, "applied": 1}}}}})
        obs = OB.observe_m1(self.cfg, r)
        self.assertEqual(obs["oracle"], {"s1_group1": frozenset({1, 2})})
        self.assertIsNone(obs["negative"])
        self.assertEqual(V.decide(T.TABLE.cell("M1"), obs, V.Context()).verdict, V.NOT_RUN)
        replies["9092"] = fixture("mc_dump_empty")
        obs = OB.observe_m1(self.cfg, r)
        self.assertEqual(V.decide(T.TABLE.cell("M1"), obs, V.Context()).verdict, V.GREEN)

    def test_pl1_reads_show_tables_on_every_switch(self):
        alt = fixture("show_tables").replace("HcIngress.t_ap ", "HcIngress.alt_port_stamp [implementation=None, mk=]\nHcIngress.t_ap ")
        replies = {"9091": alt, "9092": fixture("show_tables"), "9093": fixture("show_tables"),
                   "9094": alt}
        r = RecordingRunner().add(("simple_switch_CLI",), lambda a, e, i: (0, replies[a[2]]))
        self.proxy.routes[("GET", "/p4/switch_state")] = (200, {"switches": {
            str(d): {"pipeline": {"p4info_sha256": "alt" if d == 1 else "main"}} for d in (1, 2, 3, 4)}})
        expect = {"1": "alt", "2": "main", "3": "main", "4": "main"}
        obs = OB.observe_pl1(self.cfg, r, expect)
        self.assertEqual(obs["negative"], {"absent": False})
        self.assertEqual(V.decide(T.TABLE.cell("PL1"), obs, V.Context()).verdict, V.PROBE_BROKEN)

    def test_openapi_routes(self):
        self.proxy.routes[("GET", "/openapi.json")] = (200, {"paths": {"/p4/counter/{name}": {"get": {}},
                                                                     "/p4/table_entry": {"post": {}}}})
        paths = P.openapi_paths(self.cfg)
        self.assertEqual(paths["/p4/table_entry"], {"POST"})
        self.assertIs(OB.route_answer(paths, "R2"), False)
        self.assertIsNone(OB.route_answer(None, "R2"))
        self.proxy.routes[("GET", "/openapi.json")] = (500, None)
        self.assertIsNone(P.openapi_paths(self.cfg))

    def test_the_counter_endpoints_three_answers(self):
        path = ("GET", "/p4/counter/HcIngress.c_in?dpid=1&index=0")
        self.proxy.routes[path] = (503, {"detail": {"error": "counter not read"}})
        self.assertEqual(P.counter(self.cfg, "HcIngress.c_in", 1), (503, None, "counter not read"))
        self.proxy.routes[path] = (200, {"packets": 0, "bytes": 0})
        self.assertEqual(P.counter(self.cfg, "HcIngress.c_in", 1), (200, 0, None))

    def test_post_table_entry_goes_through_the_config_client(self):
        self.proxy.routes[("POST", "/p4/table_entry")] = (501, {"detail": {"error": "unsupported match"}})
        self.assertEqual(P.post_table_entry(self.cfg, {"table": "t"})[0], 501)
        self.assertEqual(self.proxy.calls[-1], ("POST", "/p4/table_entry", {"table": "t"}))

    # review MAJ-2: an unreadable switch_state is no answer, never a RED and never a GREEN
    def test_unreadable_switch_state_is_no_answer(self):
        self.proxy.routes[("GET", "/p4/switch_state")] = (500, None)
        good = fixture("mc_dump_group").replace("mgrp(2)", "mgrp(1)").replace("[1, 3]", "[1, 2]")
        r = RecordingRunner().add(("simple_switch_CLI",), lambda a, e, i: (
            0, good if a[2] == "9091" else fixture("mc_dump_empty")))
        obs = OB.observe_m1(self.cfg, r)
        self.assertIsNone(obs["answer"])
        v = V.decide(T.TABLE.cell("M1"), obs, V.Context())
        self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "answer"))
        alt = fixture("show_tables").replace("HcIngress.t_ap ", "HcIngress.alt_port_stamp [implementation=None, mk=]\nHcIngress.t_ap ")
        r = RecordingRunner().add(("simple_switch_CLI",), lambda a, e, i: (
            0, alt if a[2] == "9091" else fixture("show_tables")))
        obs = OB.observe_pl1(self.cfg, r, {"1": "alt", "2": "main", "3": "main", "4": "main"})
        self.assertIsNone(obs["answer"])
        v = V.decide(T.TABLE.cell("PL1"), obs, V.Context())
        self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "answer"))

    # review MAJ-3 / MINOR 21: the control keeps the endpoint's own error word
    def test_the_counter_control_needs_the_endpoints_own_refusal(self):
        path = ("GET", "/p4/counter/HcIngress.no_such_counter?dpid=2&index=0")
        ctl = T.TABLE.controls[0]
        self.proxy.routes[path] = (404, {"detail": {"error": "not in this pipeline", "counter": "x"}})
        self.assertEqual(ctl.judge(OB.observe_counter_control(self.cfg, 2)).verdict, V.GREEN)
        del self.proxy.routes[path]            # FakeHttp answers FastAPI's own {"detail": "Not Found"}
        self.assertEqual(ctl.judge(OB.observe_counter_control(self.cfg, 2)).verdict, V.PROBE_BROKEN)


    def test_a_missing_counter_route_is_red_no_route_through_the_observers(self):
        """Cut 1 follow-up 4: FastAPI's own 404 for /p4/counter, pushed through K1's two observers
        and the real cells, must give K1 RED "no route" -- not a PROBE-BROKEN control."""
        r = RecordingRunner().add(("simple_switch_CLI",), lambda a, e, i: (0, fixture("counter_c_in")))

        def run_k1():
            obs = OB.observe_counter(self.cfg, r, 2, "c_in", 0,
                                     lambda: "SENT cell=K1 n=5 ident=0 requested=5000\n", "K1")
            ctl = OB.observe_counter_control(self.cfg, 2)
            ctx = V.Context()
            ctx.self_checks["SC-count"] = V.Verdict(V.GREEN, "fixture")
            ctx.cells["K1-neg"] = T.TABLE.controls[0].judge(ctl)
            return obs, ctl, ctx, V.decide(T.TABLE.cell("K1"), obs, ctx)
        # openapi readable, with no /p4/counter; every counter read is FastAPI's {"detail": "Not Found"}
        self.proxy.routes[("GET", "/openapi.json")] = (200, {"paths": {"/p4/table_entry": {"post": {}}}})
        obs, ctl, ctx, v = run_k1()
        self.assertEqual((v.verdict, v.phase), (V.RED, "cannot"), v)
        self.assertIn("no route", v.reason)
        self.assertEqual(ctx.cells["K1-neg"].verdict, V.NOT_RUN)
        self.assertIs(obs["answer"]["route"], False)
        self.assertIs(ctl["answer"]["route"], False)
        # openapi unreadable: that is not a missing route -- the control stays the probe's problem
        del self.proxy.routes[("GET", "/openapi.json")]
        obs, ctl, ctx, v = run_k1()
        self.assertEqual((v.verdict, v.phase), (V.PROBE_BROKEN, "control"), v)
        self.assertNotIn("route", obs["answer"])
        self.assertNotIn("route", ctl["answer"])
        # the route is there and the control gets the endpoint's own refusal: no route claim at all
        self.proxy.routes[("GET", "/openapi.json")] = (200, {"paths": {"/p4/counter/{name}": {"get": {}}}})
        self.proxy.routes[("GET", "/p4/counter/HcIngress.no_such_counter?dpid=2&index=0")] = (
            404, {"detail": {"error": "not in this pipeline"}})
        self.proxy.routes[("GET", "/p4/counter/HcIngress.c_in?dpid=2&index=0")] = (200, {"packets": 10})
        obs, ctl, ctx, v = run_k1()
        self.assertEqual((v.verdict, v.phase), (V.GREEN, "compare"), v)
        self.assertEqual(ctx.cells["K1-neg"].verdict, V.GREEN)
        self.assertIs(ctl["answer"]["route"], True)


class TestSmallOracles(Sealed):

    def test_ps_finds_the_switch_by_its_exact_thrift_port(self):
        lines = ["101 /usr/local/bmv2-fast/bin/simple_switch_grpc --thrift-port 9091 --cpu-port 510 x.json",
                 "102 /usr/local/bmv2-fast/bin/simple_switch_grpc --thrift-port 90910 x.json",
                 "103 ndt-hc-selfcheck-bmv2 --thrift-port 29500 y.json"]
        argv = PS.bmv2_argv(lines, 9091)
        self.assertTrue(PS.has_flag(argv, "--cpu-port", 510))
        self.assertFalse(PS.has_flag(argv, "--priority-queues"))
        self.assertIsNone(PS.bmv2_argv(lines, 9092))
        self.assertIsNone(PS.has_flag(None, "--cpu-port", 510))

    def test_tc_fabric_and_ethtool(self):
        self.assertEqual(TC.rate_kbit("qdisc htb 5: root refcnt 2 r2q 10 default 0x1\nclass htb rate 500Kbit"), 500.0)
        self.assertEqual(TC.rate_kbit("qdisc tbf 1: rate 2Mbit burst"), 2000.0)
        self.assertIsNone(TC.rate_kbit("qdisc noqueue 0: root"))
        self.assertEqual(TC.netem_del_argv("s2-eth3"), ["sudo", "-n", "tc", "qdisc", "del", "dev", "s2-eth3", "root"])
        self.assertEqual(FB.host_pid(["77 bash --norc -is mininet:h1", "78 grep mininet:h1 x"], "h1"), "77")
        self.assertIsNone(FB.host_pid(["77 bash mininet:h1", "79 bash mininet:h1"], "h1"))
        self.assertEqual(FB.veth_peers("7: s1-eth1@if8: <BROADCAST> mtu 1500\n"), {"s1-eth1": 8})
        self.assertTrue(FB.checksum_offload_off("Features for eth0:\ntx-checksumming: off\n"))
        self.assertEqual(FB.host_addr("2: eth0    inet 10.0.1.1/24 brd x\n link/ether 08:00:00:00:01:11 brd"),
                         ("10.0.1.1", "08:00:00:00:01:11"))


class TestUnreadableIsNotEmpty(Sealed):
    """Review MINOR 10: an unreadable document or file is None, never "no rows" / "no frames"."""

    def test_side_rows_and_pcaps(self):
        from p4_health import frames as F
        from p4_health.collect import kernel as K
        self.assertIsNone(K.side_rows(None))
        self.assertIsNone(K.side_rows({"flows": []}))
        self.assertEqual(K.side_rows({"non_ipv4_flows": []}), [])
        self.assertIsNone(F.read_pcap(os.path.join(self.tmp, "missing.pcap")))
        junk = os.path.join(self.tmp, "junk.pcap")
        with open(junk, "wb") as fh:
            fh.write(b"not a pcap at all, not even close....")
        self.assertIsNone(F.read_pcap(junk))
        empty = os.path.join(self.tmp, "empty.pcap")
        F.write_pcap(empty, [])
        self.assertEqual(F.read_pcap(empty), [])


class TestThrowawayGuard(Sealed):

    def test_the_throwaway_cli_only_ever_dials_its_own_port(self):
        """The only thrift writes in tools/p4_health go to a switch the probe started; a lab port,
        or no port, is refused before the runner is called (review MAJ-4)."""
        r = RecordingRunner().add(("simple_switch_CLI",), (0, "RuntimeCmd: "))
        sw = TW.Throwaway(os.path.join(self.tmp, "x.json"), {1: []}, 510, ["simple_switch_CLI"],
                          workdir=self.tmp, runner=r)
        for port in (None, 9090, 9092, 9100, 30051, 8081):
            with self.subTest(port=port):
                sw.thrift_port = port
                with self.assertRaises(TW.ThrowawayError):
                    sw.cli(["table_add HcIngress.t_ternary x 1 => 2"])
        self.assertEqual(r.calls, [])
        sw.thrift_port = 29501
        sw.cli(["show_tables"])
        self.assertEqual(r.calls[0]["argv"], ["simple_switch_CLI", "--thrift-port", "29501"])
        with self.assertRaises(TW.ThrowawayError):
            TW.Throwaway("x.json", {}, 510, ["c"], workdir=self.tmp, argv0="simple_switch")

    def test_the_lab_ports_come_from_grpc_ports(self):
        self.assertIn((9090, 9090 + 512), TW.LAB_PORT_RANGES)
        self.assertIn((30050, 30050 + 512), TW.LAB_PORT_RANGES)
        self.assertFalse(any(lo <= 29500 < hi for lo, hi in TW.LAB_PORT_RANGES))


# --- the lifecycle (M14, M17; section 12 items 10 and 12; review MAJ-6) ---------------------------------

UP_NOTE = "in use: ndt up p4 6 at 2026-10-03 18:00:00 by p4h-test"


class TestLabRound(Sealed):

    def setUp(self):
        Sealed.setUp(self)
        self.host_knob = os.path.join(self.knobs, "host_count_override")
        with open(self.host_knob, "wb") as fh:
            fh.write(b"4  # uncommitted value, kept as bytes\n")
        self.override = os.path.join(self.knobs, "app_package_override")
        with open(self.override, "wb") as fh:
            fh.write(b"/some/other/package\n")
        self.proxy.routes[("GET", "/p4/switch_state")] = (200, {"heartbeat": {"state": "usable",
                                                                            "frames_reached_hosts": False}})
        self.pkg = os.path.join(self.cfg.run_dir, "pkgA")       # (r6) each round's package is inside its run dir
        self.claim_exp = int(__import__("time").time()) + 600  # the one claim the round makes
        self.proc = os.path.join(self.tmp, "proc")
        self.fake_proc(555, 777001, "python3\0sniff.py\0--run-id\0run-x\0")
        self.fake_proc(666, 777002, "python3\0controller_ext.py\0run-x\0")

    def fake_proc(self, pid, start, cmdline, comm="python3"):
        d = os.path.join(self.proc, str(pid))
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "stat"), "w") as fh:
            fh.write("%d (%s) S %s %d 0 0\n" % (pid, comm, " ".join(str(i) for i in range(1, 19)), start))
        with open(os.path.join(d, "cmdline"), "w") as fh:
            fh.write(cmdline)

    def write_claim(self, owner="p4h-test", expires=None, note=""):
        expires = expires if expires is not None else self.claim_exp
        with open(self.cfg.claim_file, "w") as fh:
            fh.write("owner=%s\nexpires=%d\nnote=%s\nexclusive_cpu=no\nmeasuring=\n" % (owner, expires, note))

    def write_claim_text(self, text):
        with open(self.cfg.claim_file, "w") as fh:
            fh.write(text)

    def runner(self, down_rc=0, release_rc=0, claim_rc=0, diff_rc=0, tc_add_rc=0,
               status="  measuring      nothing\n"):
        knob, test = self.host_knob, self

        def claim(argv, env, inp):
            if claim_rc == 0:
                test.write_claim(note=argv[3])
            return (claim_rc, "")

        def up(argv, env, inp):
            with open(knob, "wb") as fh:          # `ndt up p4 --app` rewrites the host knob ...
                fh.write(b"6\n")
            test.write_claim(note=UP_NOTE)         # ... and the claim's note (ndt:3504)
            return (0, "up")

        def down(argv, env, inp):
            test.write_claim(note="down at 2026-10-03 18:20:00; verified clean; claim kept")
            return (down_rc, "")

        def release(argv, env, inp):
            if release_rc == 0 and os.path.exists(test.cfg.claim_file):
                os.remove(test.cfg.claim_file)
            return (release_rc, "")
        r = RecordingRunner()
        r.add(("ndt", "status", "--measuring"), (0, status))
        r.add(("ndt", "claim"), claim)
        r.add(("ndt", "up"), up)
        r.add(("ndt", "down"), down)
        r.add(("ndt", "release"), release)
        r.add(("qdisc_snapshot.sh", "save"), (0, "saved"))
        r.add(("qdisc_snapshot.sh", "diff"), (diff_rc, "" if diff_rc == 0 else "-qdisc htb\n"))
        r.add(("sudo", "-n", "tc", "qdisc", "add"), (tc_add_rc, ""))
        r.add(("sudo", "-n", "tc"), (0, ""))
        r.add(("sudo", "-n", "mnexec", "-a", "1", "kill"), (0, ""))
        r.add(("kill",), (0, ""))
        return r

    def lab(self, r, **kw):
        return LR.LabRound(self.cfg, r, "A", self.pkg, "run-x", pid=4242, proc_root=self.proc,
                           install_signals=kw.pop("signals", False))

    def round(self, r, body=None, **kw):
        lr = self.lab(r, **kw)

        def default_body(lab):
            lab.register("sniffer", 555)
            lab.register("controller", 666)
            lab.add_netem("s2-eth3")
        return lr, lr.run(body or default_body)

    def names(self, r):
        out = []
        for a in r.argvs():
            if a[0] == "ndt":
                out.append("ndt " + a[1])
            elif a[:2] == ["sudo", "-n"] and a[2] == "tc":
                out.append("tc " + a[4])
            elif a[:2] == ["sudo", "-n"] and a[2] == "mnexec":
                out.append("kill-sniffer %s" % a[-1])
            elif a[0] == "kill":
                out.append("kill-controller %s" % a[-1])
            else:
                out.append(os.path.basename(a[0]) + " " + a[1])
        return out

    def state(self):
        with open(self.cfg.lab_state_path) as fh:
            return json.load(fh)

    def test_the_round_in_order(self):
        r = self.runner()
        lr, rec = self.round(r)
        self.assertEqual(self.names(r), [
            "ndt status", "ndt claim", "ndt up", "qdisc_snapshot.sh save", "tc add",
            "kill-sniffer 555", "kill-controller 666", "tc del", "qdisc_snapshot.sh diff",
            "ndt down", "ndt release"])
        self.assertTrue(rec["complete"], rec)
        self.assertEqual((rec["up_rc"], rec["down_rc"], rec["release_rc"]), (0, 0, 0))

    def test_every_ndt_call_carries_the_owner(self):
        r = self.runner()
        self.round(r)
        for call in r.calls:
            if call["argv"][0] == "ndt":
                self.assertEqual(call["env"].get("NDT_OWNER"), "p4h-test", call["argv"])

    def test_a_package_outside_the_run_dir_is_refused_and_nothing_is_touched(self):
        """(r6) Each round's package is its own copy inside its run dir, so app_package_override names
        that round and no other. A package anywhere else is refused before any file or command."""
        outside = os.path.join(self.tmp, "shared", "pkg")
        os.makedirs(outside)
        link = os.path.join(self.cfg.run_dir, "pkgL")
        os.makedirs(self.cfg.run_dir)
        os.symlink(outside, link)
        for what, pkg in (("a sibling directory", outside),
                          ("a name that starts like the run dir", self.cfg.run_dir + "2/pkg"),
                          ("a path that climbs out with ..", os.path.join(self.cfg.run_dir, "..", "pkgB")),
                          ("a link out of the run dir", link),
                          ("the run dir itself", self.cfg.run_dir)):
            with self.subTest(package=what):
                r = self.runner()
                with self.assertRaises(ValueError) as cm:
                    LR.LabRound(self.cfg, r, "A", pkg, "run-x", pid=4242, proc_root=self.proc,
                                install_signals=False)
                self.assertIn("not inside the run dir", str(cm.exception))
                self.assertEqual(r.calls, [])                              # no command
                self.assertFalse(os.path.exists(self.cfg.lab_state_path))   # no state file
        self.assertEqual(os.listdir(self.cfg.run_dir), ["pkgL"])            # and nothing else in the run dir
        lr = self.lab(self.runner())                                        # a package inside it is accepted
        self.assertEqual(lr.state["package"], self.pkg)

    def test_the_package_path_is_resolved_once_and_that_path_is_used_everywhere(self):
        """(r7) check, LAB_STATE and `ndt up --app` all take the resolved path. A path with a link followed
        by .. names one directory to abspath and another to the file system."""
        real = os.path.join(self.cfg.run_dir, "real")
        os.makedirs(os.path.join(real, "sub"))
        os.symlink(os.path.join(real, "sub"), os.path.join(self.cfg.run_dir, "ln"))
        raw = os.path.join(self.cfg.run_dir, "ln", "..", "pkgA")       # abspath: run/pkgA; the file system: run/real/pkgA
        want = os.path.join(os.path.realpath(self.cfg.run_dir), "real", "pkgA")
        r = self.runner()
        lr = LR.LabRound(self.cfg, r, "A", raw, "run-x", pid=4242, proc_root=self.proc, install_signals=False)
        lr.run(lambda lab: None)
        self.assertEqual(self.state()["package"], want)
        up = [a for a in r.argvs() if a[:2] == ["ndt", "up"]][0]
        self.assertEqual(up, ["ndt", "up", "p4", "--app", want])

    def test_the_claims_expires_is_recorded_right_after_the_claim_and_before_the_up(self):
        """(r6) recover.sh tells this claim from any later one by its expires."""
        seen = {}
        r = self.runner()
        up = [rep for rep in r.replies if rep[0] == ("ndt", "up")][0][1]

        def watching_up(argv, env, inp):
            seen["at_up"] = self.state().get("claim_expires")
            return up(argv, env, inp)
        r.replies.insert(0, (("ndt", "up"), watching_up))
        self.round(r)
        self.assertEqual(seen["at_up"], self.claim_exp)
        self.assertEqual(self.state()["claim_expires"], self.claim_exp)

    def test_a_claim_the_file_does_not_show_as_ours_is_not_brought_up_on(self):
        """(r6) `ndt claim` exited 0 but the file has no claim of ours: nothing can be recorded for
        recover.sh to rest on, so nothing is brought up, and nothing is released either."""
        for what, writer in (("no claim file", lambda: None),
                             ("somebody else's claim", lambda: self.write_claim(owner="somebody-else")),
                             ("no expires", lambda: self.write_claim_text("owner=p4h-test\n")),
                             ("expires 0", lambda: self.write_claim_text("owner=p4h-test\nexpires=0\n")),
                             ("a superscript digit, which str.isdigit takes and int() refuses",
                              lambda: self.write_claim_text("owner=p4h-test\nexpires=\u00b2\n")),
                             ("a leading zero", lambda: self.write_claim_text("owner=p4h-test\nexpires=0123\n"))):
            with self.subTest(claim=what):
                if os.path.exists(self.cfg.claim_file):
                    os.remove(self.cfg.claim_file)
                r = self.runner()
                r.replies.insert(0, (("ndt", "claim"), lambda a, e, i, w=writer: (w(), (0, ""))[1]))
                _lr, rec = self.round(r)
                self.assertEqual(self.names(r), ["ndt status", "ndt claim"])
                self.assertFalse(rec["complete"])
                self.assertTrue([p for p in rec["problems"] if "does not show our claim" in p], rec["problems"])
                self.assertEqual(self.state()["phase"], "claim-unverified")
                self.assertIsNone(self.state()["claim_expires"])

    def test_the_claim_note_names_the_state_file(self):
        r = self.runner()
        self.round(r)
        claim = [a for a in r.argvs() if a[:2] == ["ndt", "claim"]][0]
        self.assertEqual(claim[2], "45")
        self.assertIn("state=%s" % self.cfg.lab_state_path, claim[3])
        self.assertTrue(claim[3].startswith("p4-health run-x A "))

    def test_the_knobs_go_back_as_bytes_and_the_override_is_not_touched(self):
        r = self.runner()
        _lr, rec = self.round(r)
        with open(self.host_knob, "rb") as fh:
            self.assertEqual(fh.read(), b"4  # uncommitted value, kept as bytes\n")
        with open(self.override, "rb") as fh:
            self.assertEqual(fh.read(), b"/some/other/package\n")
        self.assertTrue(rec["knobs_restored"])
        self.assertFalse(os.path.exists(os.path.join(self.knobs, "telemetry_override")))

    def test_the_state_file_is_written_before_each_machine_change(self):
        r = self.runner()
        lr, _rec = self.round(r)
        ev = lr.events
        self.assertLess(ev.index(("state", "claiming")), ev.index(("ndt", "claim")))
        self.assertLess(ev.index(("state", "up")), ev.index(("ndt", "up")))
        self.assertLess(ev.index(("state", "teardown")), ev.index(("ndt", "down")))
        st = self.state()
        self.assertEqual((st["pid"], st["owner"], st["bring_up"], st["phase"]), (4242, "p4h-test", "A", "released"))
        self.assertEqual(base64.b64decode(st["knob_snapshot"]["host_count_override"]),
                         b"4  # uncommitted value, kept as bytes\n")
        self.assertIsNone(st["knob_snapshot"]["telemetry_override"])
        self.assertTrue(st["qdisc_before"].endswith("qdisc.A.before"))

    def test_processes_are_recorded_by_pid_start_and_marker_and_leave_once_stopped(self):
        seen = {}
        r = self.runner()

        def body(lab):
            lab.register("sniffer", 555)
            lab.register("controller", 666)
            seen.update(self.state())
        lr, _rec = self.round(r, body)
        self.assertEqual(seen["sniffers"], [{"pid": 555, "start": 777001, "marker": "run-x"}])
        self.assertEqual(seen["controllers"], [{"pid": 666, "start": 777002, "marker": "run-x"}])
        self.assertEqual((self.state()["sniffers"], self.state()["controllers"]), ([], []))

    def test_a_pid_without_the_marker_is_not_registered(self):
        self.fake_proc(777, 5, "bash\0-c\0something else\0")
        lr = self.lab(self.runner())
        with self.assertRaises(ValueError):
            lr.register("sniffer", 777)
        with self.assertRaises(ValueError):
            lr.register("sniffer", 778)            # no such pid

    def test_a_recycled_or_vanished_pid_is_never_signalled(self):
        r = self.runner()

        def body(lab):
            lab.register("sniffer", 555)
            lab.register("controller", 666)
            self.fake_proc(555, 999999, "python3\0sniff.py\0--run-id\0run-x\0")   # same pid, new process
            shutil.rmtree(os.path.join(self.proc, "666"))                        # gone
        lr, _rec = self.round(r, body)
        self.assertFalse([n for n in self.names(r) if n.startswith("kill")])
        outcomes = {e[1]: e[2] for e in lr.events if e[0] in ("stop-sniffer", "stop-controller")}
        self.assertEqual(outcomes, {555: "not ours any more", 666: "gone"})
        self.assertEqual(self.names(r)[-2:], ["ndt down", "ndt release"])

    def test_netem_is_recorded_before_it_is_applied(self):
        seen = {}
        r = self.runner()
        path = self.cfg.lab_state_path

        def tc_add(argv, env, inp):
            with open(path) as fh:
                seen["netem"] = json.load(fh)["netem"]
            return (0, "")
        r.replies.insert(0, (("sudo", "-n", "tc", "qdisc", "add"), tc_add))
        self.round(r)
        self.assertEqual(seen["netem"], ["s2-eth3"])

    def test_a_netem_whose_add_failed_is_not_deleted(self):
        r = self.runner(tc_add_rc=2)
        self.round(r)
        self.assertIn("tc add", self.names(r))
        self.assertNotIn("tc del", self.names(r))

    def test_the_qdisc_snapshot_is_taken_after_up(self):
        r = self.runner()
        self.round(r)
        names = self.names(r)
        self.assertLess(names.index("ndt up"), names.index("qdisc_snapshot.sh save"))
        self.assertLess(names.index("qdisc_snapshot.sh save"), names.index("tc add"))

    def test_a_lost_claim_stops_the_teardown_before_anything_shared_changes(self):
        for case in ("foreign", "expired"):
            with self.subTest(case=case):
                if os.path.exists(self.cfg.claim_file):
                    os.remove(self.cfg.claim_file)
                r = self.runner()
                knob = self.host_knob

                def body(lab, case=case):
                    lab.register("sniffer", 555)
                    lab.add_netem("s2-eth3")
                    if case == "foreign":
                        self.write_claim(owner="somebody-else")
                    else:
                        self.write_claim(expires=1)
                lr, rec = self.round(r, body)
                names = self.names(r)
                self.assertIn("kill-sniffer 555", names)          # our own verified process: stopped
                for step in ("tc del", "ndt down", "ndt release"):
                    self.assertNotIn(step, names)
                with open(knob, "rb") as fh:
                    self.assertEqual(fh.read(), b"6\n")           # not written over a lost claim
                self.assertEqual(self.state()["phase"], "claim-lost")
                self.assertTrue(any("no longer ours" in p for p in rec["problems"]))
                self.assertFalse(rec["complete"])
                with open(knob, "wb") as fh:
                    fh.write(b"4  # uncommitted value, kept as bytes\n")

    def test_a_claim_lost_during_the_down_stops_the_restore_and_the_release(self):
        r = self.runner()
        r.replies.insert(0, (("ndt", "down"), lambda a, e, i: (self.write_claim(owner="x"), (0, ""))[1]))
        _lr, rec = self.round(r)
        self.assertEqual(self.names(r)[-1], "ndt down")
        self.assertIsNone(rec["knobs_restored"])
        st = self.state()
        self.assertEqual((st["phase"], st["claim_lost"]), ("down-done", True))   # recover.sh's cue

    def test_a_successful_down_is_recorded_before_the_knobs_and_the_release(self):
        """Review NEW-C: a crash after the down leaves phase down-done for recover.sh."""
        seen = {}
        r = self.runner()

        def release(argv, env, inp):
            seen["phase"] = self.state()["phase"]
            if os.path.exists(self.cfg.claim_file):
                os.remove(self.cfg.claim_file)
            return (0, "")
        r.replies.insert(0, (("ndt", "release"), release))
        lr, _rec = self.round(r)
        self.assertEqual(seen["phase"], "down-done")
        ev = lr.events
        self.assertLess(ev.index(("ndt", "down")), ev.index(("state", "down-done")))
        self.assertLess(ev.index(("state", "down-done")), ev.index(("knobs", "restored")))
        r = self.runner(down_rc=3)
        lr, _rec = self.round(r)
        self.assertNotIn(("state", "down-done"), lr.events)

    def test_a_failed_kill_keeps_the_process_for_recover(self):
        """Review MINOR 6: only a stopped (or gone, or recycled) process leaves LAB_STATE."""
        r = self.runner()
        r.replies.insert(0, (("sudo", "-n", "mnexec", "-a", "1", "kill"), (1, "")))

        def body(lab):
            lab.register("sniffer", 555)
        self.round(r, body)
        self.assertEqual([e["pid"] for e in self.state()["sniffers"]], [555])

    def test_a_failed_kill_is_a_problem_and_the_round_is_not_complete(self):
        """Cut 1 follow-up 2: the teardown used to ignore how a kill ended, so a sniffer that kept
        running left a round that read complete with no problem on it."""
        for what, argv in (("sniffer", ("sudo", "-n", "mnexec", "-a", "1", "kill")), ("controller", ("kill",))):
            with self.subTest(process=what):
                r = self.runner()
                r.replies.insert(0, (argv, (1, "")))

                def body(lab):
                    lab.register("sniffer", 555)
                    lab.register("controller", 666)
                _lr, rec = self.round(r, body)
                self.assertFalse(rec["complete"])
                self.assertTrue([p for p in rec["problems"] if "could not stop %s pid" % what in p and "kill rc 1" in p],
                                rec["problems"])
        r = self.runner()
        _lr, rec = self.round(r)                    # the same round with every kill working
        self.assertEqual((rec["complete"], rec["problems"]), (True, []))

    def test_the_probe_records_its_own_start_time(self):
        self.fake_proc(4242, 31337, "python3\0probe.py\0")
        lr = self.lab(self.runner())
        self.assertEqual(lr.state["pid_start"], 31337)

    def test_a_failed_down_is_not_released(self):
        r = self.runner(down_rc=3)
        _lr, rec = self.round(r)
        self.assertNotIn("ndt release", self.names(r))
        self.assertFalse(rec["complete"])
        self.assertTrue(any("NOT releasing" in p for p in rec["problems"]))
        with open(self.host_knob, "rb") as fh:
            self.assertEqual(fh.read(), b"4  # uncommitted value, kept as bytes\n")

    def test_a_qdisc_mismatch_does_not_stop_down_restore_or_release(self):
        r = self.runner(diff_rc=1)
        _lr, rec = self.round(r)
        self.assertEqual(self.names(r)[-2:], ["ndt down", "ndt release"])
        self.assertFalse(rec["qdisc_same"])
        self.assertTrue(rec["knobs_restored"])

    def test_a_step_that_raises_still_gets_the_whole_teardown(self):
        r = self.runner()

        def body(lab):
            lab.register("sniffer", 555)
            lab.add_netem("s2-eth3")
            raise RuntimeError("a cell crashed")
        _lr, rec = self.round(r, body)
        self.assertEqual(self.names(r)[-5:], ["kill-sniffer 555", "tc del", "qdisc_snapshot.sh diff",
                                              "ndt down", "ndt release"])
        self.assertFalse(rec["complete"])

    def test_sigterm_takes_the_finally(self):
        r = self.runner()

        def body(lab):
            lab.add_netem("s2-eth3")
            os.kill(os.getpid(), signal.SIGTERM)
        old = signal.getsignal(signal.SIGTERM)
        _lr, rec = self.round(r, body, signals=True)
        self.assertIs(signal.getsignal(signal.SIGTERM), old)
        self.assertIn("aborted by signal %d" % signal.SIGTERM, rec["problems"])
        self.assertEqual(self.names(r)[-4:], ["tc del", "qdisc_snapshot.sh diff", "ndt down", "ndt release"])

    def test_a_busy_lab_is_not_claimed(self):
        r = self.runner(status="  measuring      iperf3 -c 10.0.0.3 -t 200\n")
        _lr, rec = self.round(r)
        self.assertEqual(self.names(r), ["ndt status"])
        self.assertFalse(rec["complete"])

    def test_a_foreign_live_claim_is_busy_and_an_expired_one_is_not(self):
        now = 1000000
        self.assertIsNotNone(LR.lab_busy("  measuring      nothing\n", "owner=other\nexpires=%d\n" % (now + 60), "me", now))
        self.assertIsNone(LR.lab_busy("  measuring      nothing\n", "owner=other\nexpires=%d\n" % (now - 60), "me", now))
        self.assertIsNotNone(LR.lab_busy("  declared       a run\n  measuring      nothing\n", "", "me", now))

    def test_a_refused_claim_is_incomplete_and_brings_nothing_up(self):
        # An earlier claim of our own owner is still in the file: it is not what stops the round,
        # the refusal is (r6: the claim-file check after `ndt claim` would otherwise hide that).
        self.write_claim()
        r = self.runner(claim_rc=1)
        _lr, rec = self.round(r)
        self.assertEqual(self.names(r), ["ndt status", "ndt claim"])
        self.assertFalse(rec["complete"])
        self.assertNotIn("--force", " ".join(sum(r.argvs(), [])))

    def test_frames_that_reached_a_host_make_the_round_incomplete(self):
        self.proxy.routes[("GET", "/p4/switch_state")] = (200, {"heartbeat": {"state": "usable",
                                                                            "frames_reached_hosts": True}})
        _lr, rec = self.round(self.runner())
        self.assertFalse(rec["complete"])

    def test_root_is_refused(self):
        with mock.patch("os.geteuid", return_value=0):
            with self.assertRaises(LR.RootRefused):
                self.lab(self.runner()).run(lambda lab: None)

    def test_the_real_proc_reader(self):
        """proc_identity reads field 22 after the LAST ')' of comm (which may hold spaces)."""
        self.fake_proc(888, 4242, "x\0run-x\0", comm="a b) c")
        self.assertEqual(LR.proc_identity(888, self.proc), (4242, "x run-x"))
        self.assertIsNone(LR.proc_identity(889, self.proc))


class TestConfig(Sealed):

    def test_ndt_needs_an_owner(self):
        cfg = Config(run_dir=self.tmp, proxy=self.proxy, kernel=self.kernel, ndt="ndt", knob_dir=self.tmp,
                     test_run_dir=self.tmp, thrift_cli=["x"], qdisc_snapshot="q", expected_tsv="e")
        with self.assertRaises(ValueError):
            cfg.ndt_env()

    def test_the_knobs_are_the_two_and_not_the_override(self):
        self.assertEqual(sorted(self.cfg.knobs), ["host_count_override", "telemetry_override"])
        self.assertEqual(self.cfg.thrift_port(3), 9093)


if __name__ == "__main__":
    unittest.main()
