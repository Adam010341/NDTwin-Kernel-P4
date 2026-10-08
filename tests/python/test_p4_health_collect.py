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
from p4_health import attribution as AT  # noqa: E402
from p4_health import lab as LAB  # noqa: E402
from p4_health import observe_a as OA  # noqa: E402
from p4_health import round_a as RA  # noqa: E402
from p4_health import round_b as RB  # noqa: E402
from p4_health.collect import hosts as HO  # noqa: E402
from p4_health import frames as F  # noqa: E402
from p4_health import hostside as HS  # noqa: E402


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

    def test_veth_peers_reads_both_iproute2_forms(self):
        """MAJOR-1: a peer in the same namespace is printed by NAME, one in another namespace by
        its INDEX there (r2/veth_format.log, iproute2-6.1.0). A switch-to-switch link of a Mininet
        fabric is the first kind, a host-facing port the second."""
        text = ("1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN\\    link/loopback 00:00:00:00:00:00\n"
                "2: s2-eth2@s1-eth4: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop\\    link/ether 8a:5d\n"
                "3: s1-eth4@s2-eth2: <BROADCAST,MULTICAST,M-DOWN> mtu 1500 qdisc noop\\    link/ether b6:74\n"
                "5: s1-eth1@if2: <BROADCAST,MULTICAST> mtu 1500 qdisc noop link-netnsid 0\n"
                "6: eth9: <BROADCAST> mtu 1500\n")
        self.assertEqual(FB.veth_peers(text), {"s2-eth2": "s1-eth4", "s1-eth4": "s2-eth2", "s1-eth1": 2})
        self.assertEqual(FB.ifindex(text)["s1-eth4"], 3)
        self.assertTrue(FB.checksum_offload_off("Features for eth0:\ntx-checksumming: off\n"))
        self.assertEqual(FB.host_addr("2: eth0    inet 10.0.1.1/24 brd x\n link/ether 08:00:00:00:01:11 brd"),
                         ("10.0.1.1", "08:00:00:00:01:11"))


class TestHostside(Sealed):
    """MAJOR-2 / m3: hostside.py is the one module of the probe that runs as root."""

    TOK = "abcd1234"

    def marker(self, **kw):
        args = dict(run_id=self.TOK, cell="SCfwd", seq=0, sport=40001)
        args.update(kw)
        return F.udp_marker("08:00:00:00:01:11", "08:00:00:00:01:00", "10.0.1.1", "10.0.2.2", 40001, **args)

    def rec(self, frame, cells=("SCfwd",), dport=40001, ip="10.0.2.2", run=None):
        return HS.record(frame, run or self.TOK, set(cells), dport, ip)

    def test_an_icmp_error_quoting_a_marker_is_not_a_received_marker(self):
        icmp = icmp_unreachable(self.marker())
        self.assertIsNotNone(F.parse(icmp).get("marker"))           # the quote does carry it
        self.assertIsNone(self.rec(icmp, ip="10.0.1.1"))            # ...even at the sender it quotes
        self.assertIsNone(self.rec(icmp))
        got = self.rec(self.marker())
        self.assertEqual((got["cell"], got["seq"], got["dport"], got["ip_dst"]), ("SCfwd", 0, 40001, "10.0.2.2"))

    def test_record_filters_on_every_field(self):
        m = self.marker()
        self.assertIsNotNone(self.rec(m))
        self.assertIsNone(self.rec(m, run="otherrun"))
        self.assertIsNone(self.rec(m, cells=("K1",)))
        self.assertIsNone(self.rec(m, dport=40011))
        self.assertIsNone(self.rec(m, ip="10.0.3.3"))
        self.assertIsNone(self.rec(m[:30]))                          # truncated: no marker
        tcp = bytearray(m)
        tcp[23] = F.PROTO_TCP                                        # IPv4 protocol byte
        self.assertIsNone(self.rec(bytes(tcp)))

    def test_the_sniff_loop_skips_outgoing_frames_and_stops_at_until(self):
        frames = [(self.marker(seq=0), ("eth0", 0x0800, HS.PACKET_OUTGOING, 1, b"")),
                  None,
                  (self.marker(seq=1), ("eth0", 0x0800, 0, 1, b"")),
                  (icmp_unreachable(self.marker(seq=9)), ("eth0", 0x0800, 0, 1, b"")),
                  (self.marker(seq=2), ("eth0", 0x0800, 0, 1, b"")),
                  (self.marker(seq=3), ("eth0", 0x0800, 0, 1, b""))]
        it, lines, t = iter(frames), [], [0.0]

        def clock():
            t[0] += 0.01
            return t[0]
        n = HS.sniff_loop(lambda: next(it), self.TOK, {"SCfwd"}, 40001, "10.0.2.2", 100.0, 2,
                          clock=clock, emit=lines.append)
        self.assertEqual(n, 2)
        self.assertEqual([S.received(l, "SCfwd")[0]["seq"] for l in lines], [1, 2])
        lines2 = []
        n = HS.sniff_loop(lambda: None, self.TOK, {"SCfwd"}, 40001, "10.0.2.2", 0.05, 0,
                          clock=clock, emit=lines2.append)
        self.assertEqual((n, lines2), (0, []))

    def test_its_lines_are_the_ones_collect_sniff_reads(self):
        out = "\n".join([HS.ready_line("eth0"), HS.sent_line("K1", 7, 0, 9),
                         HS.rx_line(self.rec(self.marker())), HS.done_line(1)])
        self.assertEqual(S.sent(out, "K1"), 7)
        self.assertEqual(S.sent_idents(out, "K1"), {0})
        self.assertEqual(len(S.received(out, "SCfwd", self.TOK)), 1)
        self.assertTrue(HS.ready_line("eth0").startswith("READY"))

    def test_pick_iface(self):
        self.assertEqual(HS.pick_iface("eth3"), "eth3")
        self.assertEqual(HS.pick_iface("auto", listdir=lambda d: ["lo", "eth0"]), "eth0")
        for names in (["lo"], ["lo", "eth0", "eth1"]):
            with self.assertRaises(SystemExit):
                HS.pick_iface("auto", listdir=lambda d, n=names: n)

    def test_the_root_python_writes_nothing_beside_the_sources(self):
        h = HO.Hosts(self.cfg, RecordingRunner(), "run-x", self.tmp, GEN)
        py = h.root_python()
        self.assertEqual(py[0], self.cfg.p4dev_python)
        self.assertIn("-B", py)
        self.assertIn("-I", py)
        self.assertIn("pycache_prefix=%s" % os.path.join(self.tmp, "pycache"), py)


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
            test.write_claim(note=UP_NOTE)         # ... and the claim's note (ndt:3486)
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
        # one round per call: a state file an earlier call of the same test left is not this one's
        if os.path.exists(self.cfg.lab_state_path):
            os.remove(self.cfg.lab_state_path)
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

    def test_a_stop_during_the_teardown_finishes_the_cleanup_and_is_recorded(self):
        """(Cut 2 review, round 4 F1) A stop that arrives while `ndt down` runs must not abort the
        cleanup (the release still follows) and must not vanish: the record says the round was
        stopped, because lab.py ends the run on exactly that sentence. Real handlers
        (install_signals), a `ndt down` that sends SIGTERM to the probe -- this process -- as
        `kill -TERM <pid>` from outside does while subprocess.run waits for it (the handler runs,
        the wait resumes: PEP 475)."""
        seen = []
        safety = signal.signal(signal.SIGTERM, lambda n, f: seen.append(n))
        r = self.runner()

        def down(argv, env, inp):
            os.kill(os.getpid(), signal.SIGTERM)
            os.kill(os.getpid(), signal.SIGINT)             # a second stop: the first is the one kept
            return (0, "")
        r.replies.insert(0, (("ndt", "down"), down))
        try:
            _lr, rec = self.round(r, signals=True)
        finally:
            signal.signal(signal.SIGTERM, safety)
        self.assertEqual(seen, [])                          # LabRound's handler took it
        self.assertEqual(self.names(r)[-2:], ["ndt down", "ndt release"])
        self.assertEqual([p_ for p_ in rec["problems"] if "aborted by signal" in p_],
                         ["aborted by signal %d (during the teardown)" % signal.SIGTERM])
        self.assertFalse(rec["complete"])

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


class TestASignalIsNeverSwallowed(Sealed):
    """N1: the stop signal lab_round raises must get through every `except Exception`."""

    def test_an_http_call_lets_a_signal_through(self):
        from p4_health.collect import config as CF
        with mock.patch.object(CF._urlreq, "urlopen", side_effect=LR.SignalAbort(15)):
            with self.assertRaises(LR.SignalAbort):
                CF.HttpClient("http://p4h.invalid").get("/p4/switch_state")
        with mock.patch.object(CF._urlreq, "urlopen", side_effect=OSError("down")):
            self.assertIsNone(CF.HttpClient("http://p4h.invalid").get("/x").status)

    def test_it_is_not_an_exception(self):
        self.assertFalse(issubclass(LR.SignalAbort, Exception))
        self.assertTrue(issubclass(LR.SignalAbort, BaseException))


class TestTheStateFileIsNotOverwritten(Sealed):
    """MAJOR-3: a round never overwrites a LAB_STATE.json recover.sh still needs."""

    def make(self):
        return LR.LabRound(self.cfg, RecordingRunner(), "B", os.path.join(self.cfg.run_dir, "packages", "B"),
                           "run-x", pid=4242, install_signals=False)

    def put(self, **st):
        os.makedirs(self.cfg.run_dir, exist_ok=True)
        doc = {"phase": "released", "bring_up": "A", "sniffers": [], "controllers": [], "netem": []}
        doc.update(st)
        with open(self.cfg.lab_state_path, "w") as fh:
            json.dump(doc, fh)

    def test_an_unfinished_round_refuses_the_next(self):
        for st in ({"phase": "down-failed"}, {"phase": "claim-lost"}, {"phase": "teardown"},
                   {"phase": "cells"}, {"phase": "down-done"}, {"phase": "claim-unverified"},
                   {"sniffers": [{"pid": 5, "start": 1, "marker": "x"}]},
                   {"controllers": [{"pid": 6, "start": 1, "marker": "x"}]}, {"netem": ["s2-eth3"]}):
            with self.subTest(st=st):
                self.put(**st)
                with self.assertRaises(LR.StateInUse):
                    self.make()
        with open(self.cfg.lab_state_path, "w") as fh:
            fh.write("{not json")
        with self.assertRaises(LR.StateInUse):
            self.make()

    def test_a_finished_or_absent_state_is_fine(self):
        self.make()
        for phase in ("released", "claim-refused", "lab-busy"):
            self.put(phase=phase)
            self.make()


class TestConfig(Sealed):

    def test_ndt_needs_an_owner(self):
        cfg = Config(run_dir=self.tmp, proxy=self.proxy, kernel=self.kernel, ndt="ndt", knob_dir=self.tmp,
                     test_run_dir=self.tmp, thrift_cli=["x"], qdisc_snapshot="q", expected_tsv="e")
        with self.assertRaises(ValueError):
            cfg.ndt_env()

    def test_the_knobs_are_the_two_and_not_the_override(self):
        self.assertEqual(sorted(self.cfg.knobs), ["host_count_override", "telemetry_override"])
        self.assertEqual(self.cfg.thrift_port(3), 9093)


# --- Cut 2: a fake fabric behind the one Runner and the two HTTP clients ---------------------------
#
# Everything bring-up A and B read or poke, answered in the formats the real tools print (the
# thrift fixtures above are captures of them): simple_switch_CLI per Thrift port, `ps`, `ip`,
# `sudo -n mnexec -a <pid> ...` (the sender, the sniffer, ethtool, ip inside a host), the proxy's
# routes, the kernel's two. Nothing is spawned: a "sniffer" or the "controller" is a fake process
# whose output appears when it is waited for. The fabric is the healthy NDTwin of today's trunk
# (what expected_today.tsv predicts); each red test breaks one thing.

GEN_PATH = os.path.join(os.environ.get("P4_HEALTH_UNDER_TEST") or os.path.join(REPO, "tools"),
                        "p4_health", "exercise", "gen_runtime.py")


def load_gen():
    import importlib.util
    spec = importlib.util.spec_from_file_location("hc_gen_test", GEN_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


GEN = load_gen()
#: p4info key and parameter orders for the tables gen_runtime fills (hc_main.p4's declarations)
KEYS = {"HcIngress.ipv4_lpm": ["hdr.ipv4.dstAddr"], "HcIngress.tunnel_exact": ["meta.dst_id"],
        "HcIngress.v6_host": ["meta.v6_lo"], "HcIngress.t_dcount": ["hdr.udp.dstPort"],
        "HcIngress.t_dmeter": ["hdr.udp.dstPort"],
        "HcIngress.t_multipath": ["hdr.ipv4.dstAddr", "meta.mp_choice"],
        "HcIngress.t_default_only": [], "HcIngress.port_exact": ["standard_metadata.ingress_port"],
        "HcIngress.t_ternary": ["hdr.ipv4.srcAddr"], "HcIngress.t_range": ["hdr.udp.dstPort"],
        "HcIngress.t_optional": ["hdr.ipv4.protocol"]}
PARAMS = {"HcIngress.ipv4_forward": ["dstAddr", "port"], "HcIngress.tunnel_forward": ["port"],
          "HcIngress.v6_forward": ["dstAddr", "port"], "HcIngress.stamp": ["v"],
          "HcIngress.set_mark": ["v"], "HcIngress.set_port_tag": ["tag"], "HcIngress.drop": [],
          "HcIngress.dc_hit": [], "HcIngress.dm_read": [], "NoAction": []}
ORDERS = {d: (KEYS, PARAMS) for d in (1, 2, 3, 4)}
RUNTIMES = {d: GEN.runtime(d) for d in (1, 2, 3, 4)}
PIPES4 = {"1": "alt0000000000001", "2": "main000000000002", "3": "main000000000002",
          "4": "main000000000002"}
HOST_PIDS = {"h%d" % h: 3100 + h for h in range(1, 7)}
TOP = 2 ** 31 - 1


def ival(v):
    if isinstance(v, int):
        return v
    if v.count(".") == 3:
        return int.from_bytes(bytes(int(x) for x in v.split(".")), "big")
    if v.count(":") == 5:
        return int(v.replace(":", ""), 16)
    return int(v, 0)


def p4info_text(keys=KEYS, params=PARAMS):
    out = []
    for t, ks in keys.items():
        out.append('tables {\n  preamble {\n    id: 1\n    name: "%s"\n  }' % t)
        for k in ks:
            out.append('  match_fields {\n    id: 1\n    name: "%s"\n  }' % k)
        out.append("}")
    for a, ps in params.items():
        out.append('actions {\n  preamble {\n    id: 2\n    name: "%s"\n  }' % a)
        for p_ in ps:
            out.append('  params {\n    id: 1\n    name: "%s"\n  }' % p_)
        out.append("}")
    return "\n".join(out) + "\n"


class Switch(object):
    def __init__(self, dpid):
        self.dpid = dpid
        self.tables, self.defaults = {}, {}
        self.counters = {("HcIngress.c_in", 0): 0}
        self.registers = {("HcIngress.r_mark", i): 0 for i in range(16)}
        self.meters = {}
        self.mirroring, self.mc = {}, {}
        self.next_handle = 0

    def add(self, table, keys, action, params, priority=None):
        e = {"handle": self.next_handle, "keys": list(keys), "action": action, "params": list(params),
             "priority": priority}
        self.next_handle += 1
        self.tables.setdefault(table, []).append(e)
        if table == "HcIngress.t_dcount":
            self.counters[("HcIngress.dc_k2", e["handle"])] = 0
        return e


class FakeFabric(object):
    """Switches, hosts, the proxy and the kernel of a bring-up, all in memory."""

    def __init__(self, test, cfg, proxy, kernel, proc_root):
        self.test, self.cfg, self.proxy, self.kernel, self.proc = test, cfg, proxy, kernel, proc_root
        self.sw = {d: Switch(d) for d in (1, 2, 3, 4)}
        self.delivered = {h: [] for h in HOST_PIDS}
        self.digests, self.packet_ins = [], []
        # knobs a red test turns
        self.ttl_decrements = True
        self.count_k1 = True
        self.proxy_k1_extra = 0
        self.thrift_down = set()          # dpids whose CLI cannot connect
        self.ndtwin_writes_ternary = False
        self.ndtwin_priority = None       # what the proxy's future writer would store, or None
        self.tx_checksum = "off"
        self.graph_drop_edge = False
        self.graph_drop_switch_edges = False
        self.mode = "ndtwin"              # control_plane.mode in switch_state (B's fabric: external)
        self.sniffer_hangs = None         # a cell: its sniffer never ends (its process stays)
        self.signal_in_sniffer = None     # a cell: a SIGTERM arrives while its sniffer is waited for
        self.force_mode = None            # control_plane.mode whatever package came up
        self.ctrl_never_ready = False     # B's controller never writes its ready file
        self.ctrl_spawn_fails = False     # the adapter cannot be started (Runner.spawn: OSError -> None, runner.py:62-65)
        self.ctrl_garbage_result = False  # B's controller writes a result file that is not JSON
        self.extra_ports = {}             # {dpid: [ports show_ports lists that no link uses]}
        self.cpu_port_listed = False
        self.switch_peer_form = "name"    # "name": iproute2's real form; "none": a parser's blind spot
        self.pipelines = dict(PIPES4)
        self.ctrl_register_ok = False      # bmv2's P4Runtime refuses register writes today
        self.ctrl_connect_error = False    # (round 5, #4) no switch answers the controller's arbitration
        self.ctrl_s2_not_primary = False   # (round 5, #4) s2 grants the pipeline but not primary
        self.ctrl_fail = set()
        self.ctrl_no_result = False
        self.fail_entry = None
        self.foreign_sentinel = False
        self.next_pid = 50000
        for d in (1, 2, 3, 4):
            self.boot(d)
        self.routes()

    # --- the package, applied at boot ------------------------------------------------------
    def boot(self, d):
        s = self.sw[d]
        for e in RUNTIMES[d]["table_entries"]:
            if e.get("default_action"):
                s.defaults[e["table"]] = (e["action_name"], [ival(v) for v in
                                                             [e["action_params"][p_] for p_ in PARAMS[e["action_name"]]]])
                continue
            keys = []
            for k in KEYS[e["table"]]:
                v = e["match"][k]
                keys.append(("LPM", ival(v[0]), v[1]) if isinstance(v, list) else ("EXACT", ival(v)))
            s.add(e["table"], keys, e["action_name"],
                  [ival(e["action_params"][p_]) for p_ in PARAMS[e["action_name"]]])
        s.defaults.setdefault("HcIngress.t_default_only", ("HcIngress.stamp", [0]))
        for g in RUNTIMES[d].get("multicast_group_entries") or []:
            s.mc[g["multicast_group_id"]] = frozenset(r["egress_port"] for r in g["replicas"])
        for c in RUNTIMES[d].get("clone_session_entries") or []:
            s.mirroring[c["clone_session_id"]] = 0x8000 + c["clone_session_id"]
            s.mc[0x8000 + c["clone_session_id"]] = frozenset(r["egress_port"] for r in c["replicas"])
        if self.foreign_sentinel and d == 1:
            s.add("HcIngress.ipv4_lpm", [("LPM", ival("10.0.99.2"), 32)], "HcIngress.drop", [])

    # --- the proxy and the kernel -------------------------------------------------------------
    def routes(self):
        pr, kr = self.proxy.routes, self.kernel.routes

        def state(_b):
            sw = {}
            for d in (1, 2, 3, 4):
                n = len(RUNTIMES[d]["table_entries"])
                failed = 1 if self.fail_entry == d else 0
                sw[str(d)] = {"pipeline": {"p4info_sha256": self.pipelines[str(d)]},
                              "table_entries": {"recorded": n, "applied": n - failed, "failed": failed,
                                                "api_writes": 0, "journaled": False},
                              "pre_entries": {"multicast": {"recorded": len(RUNTIMES[d].get("multicast_group_entries") or []),
                                                            "applied": len(RUNTIMES[d].get("multicast_group_entries") or []), "failed": 0},
                                              "clone": {"recorded": len(RUNTIMES[d].get("clone_session_entries") or []),
                                                        "applied": len(RUNTIMES[d].get("clone_session_entries") or []), "failed": 0}}}
            return (200, {"switches": sw, "heartbeat": {"state": "usable", "frames_reached_hosts": False},
                          "control_plane": {"mode": self.mode, "package": None, "skipped": []}})
        pr[("GET", "/p4/switch_state")] = state
        pr[("GET", "/openapi.json")] = (200, {"paths": {p_: {"get": {}} for p_ in (
            "/p4/switch_state", "/p4/counter/{name}", "/p4/table_entry", "/p4/multicast_group",
            "/p4/readopt/{dpid}", "/stats/flowentry/add")}})
        def c_in(_b):
            self.k1_reads += 1
            return (200, {"packets": self.sw[2].counters[("HcIngress.c_in", 0)]
                          + self.proxy_k1_extra * self.k1_reads, "bytes": 0})
        self.k1_reads = 0
        pr[("GET", "/p4/counter/HcIngress.c_in?dpid=2&index=0")] = c_in
        for name in ("HcIngress.dc_k2", "HcIngress.no_such_counter"):
            pr[("GET", "/p4/counter/%s?dpid=2&index=0" % name)] = (
                404, {"detail": {"error": "not in this pipeline", "counter": name}})
        pr[("POST", "/p4/table_entry")] = self.post_table_entry
        pr[("POST", "/p4/multicast_group")] = self.post_mc
        kr[("GET", "/ndt/get_graph_data")] = lambda b: (200, self.graph())
        kr[("POST", "/ndt/install_meter_entry")] = (501, {"status": "error", "error": "unsupported_on_p4"})

    def post_table_entry(self, body):
        table = body["table"]
        if table not in KEYS:
            return (404, {"detail": {"error": "not in this pipeline", "message": "table not found"}})
        s = self.sw[body["dpid"]]
        prm = [ival(body["action_params"][p_]) for p_ in PARAMS[body["action_name"]]]
        if table in ("HcIngress.t_ternary", "HcIngress.t_range", "HcIngress.t_optional"):
            if not self.ndtwin_writes_ternary:
                return (501, {"detail": {"error": "match type not supported"}})
            (field, v), = body["match"].items()
            prio = self.ndtwin_priority(body["priority"]) if self.ndtwin_priority else TOP - body["priority"]
            if table == "HcIngress.t_ternary":
                key = ("TERNARY", ival(v[0]) & ival(v[1]), ival(v[1]))
            elif table == "HcIngress.t_range":
                key = ("RANGE", v[0], v[1])
            else:
                key = ("TERNARY", v, 0xFF)
            s.add(table, [key], body["action_name"], prm, priority=prio)
            return (200, {"status": "success", "journaled": False})
        (field, v), = body["match"].items()
        s.add(table, [("EXACT", ival(v))], body["action_name"], prm)
        return (200, {"status": "success", "journaled": False})

    def post_mc(self, body):
        self.sw[body["dpid"]].mc[body["multicast_group_id"]] = frozenset(r["egress_port"] for r in body["replicas"])
        return (200, {"status": "success"})

    def graph(self):
        nodes = [{"vertex_type": 0, "dpid": d, "mac": 0, "ip": []} for d in (1, 2, 3, 4)]
        for h in range(1, 7):
            ip = GEN.host_ip(h)
            nodes.append({"vertex_type": 1, "dpid": 0, "ip": [int.from_bytes(bytes(int(x) for x in ip.split(".")), "little")],
                          "mac": int(GEN.host_mac(h).replace(":", ""), 16)})
        edges = []
        for h in range(1, 7):
            ipn = int.from_bytes(bytes(int(x) for x in GEN.host_ip(h).split(".")), "little")
            # the shape a live P4 graph has (e6-graph-p4.json of an earlier run): both
            # directions, the host's side on interface 1, the switch's side carrying its agent ip
            sw_ip = [192653504 + GEN.HOSTS[h]]
            edges.append({"src_dpid": 0, "src_ip": [ipn], "src_interface": 1, "dst_dpid": GEN.HOSTS[h],
                          "dst_interface": GEN.HOST_PORT[h], "dst_ip": sw_ip})
            edges.append({"src_dpid": GEN.HOSTS[h], "src_ip": sw_ip, "src_interface": GEN.HOST_PORT[h],
                          "dst_dpid": 0, "dst_interface": 1, "dst_ip": [ipn]})
        links = GEN.SWITCH_LINKS[1:] if self.graph_drop_edge else GEN.SWITCH_LINKS
        if self.graph_drop_switch_edges:
            links = []
        for a, ap, b, bp, _bw in links:
            edges.append({"src_dpid": a, "src_interface": ap, "dst_dpid": b, "dst_interface": bp, "src_ip": [], "dst_ip": []})
            edges.append({"src_dpid": b, "src_interface": bp, "dst_dpid": a, "dst_interface": ap, "src_ip": [], "dst_ip": []})
        return {"nodes": nodes, "edges": edges}

    # --- the Runner ----------------------------------------------------------------------------
    def runner(self, ndt=None):
        r = ndt or RecordingRunner()
        r.add(("simple_switch_CLI",), self.cli)
        r.add(("ps",), lambda a, e, i: (0, self.ps()))
        r.add(("ip", "-o", "link", "show"), lambda a, e, i: (0, self.root_links()))
        r.add(lambda a: a[:4] == ["sudo", "-n", "mnexec", "-a"] and a[4] != "1", self.in_host)

        def spawn(argv, out_path, env=None, cwd=None):
            r.calls.append({"argv": list(argv), "env": dict(env or {}), "input": None, "spawn": out_path})
            return self.spawn(list(argv), out_path, env or {})
        r.spawn = spawn
        return r

    def ps(self):
        lines = ["%d bash --norc --noediting -is mininet:%s" % (pid, h) for h, pid in sorted(HOST_PIDS.items())]
        for d in (1, 2, 3, 4):
            lines.append("%d simple_switch_grpc -i 1@s%d-eth1 --thrift-port %d --cpu-port 510 x.json"
                         % (4000 + d, d, 9090 + d))
        return "\n".join(lines) + "\n"

    def ifindex(self, d, port):
        return 100 + d * 10 + port

    def iface_list(self):
        out = {}
        for h in range(1, 7):
            out[(GEN.HOSTS[h], GEN.HOST_PORT[h])] = ("h", h)
        for a, ap, b, bp, _bw in GEN.SWITCH_LINKS:
            out[(a, ap)] = ("s", b, bp)
            out[(b, bp)] = ("s", a, ap)
        return out

    def root_links(self):
        """`ip -o link show` in the root namespace, as iproute2 prints it (r2/veth_format.log):
        a peer in the SAME namespace by its name (`s1-eth4@s2-eth2:`, every switch-to-switch
        link, since Mininet's switches live in the root netns), a peer in another namespace by
        its index there (`s1-eth1@if2:`, every host-facing port; the host's eth0 is index 2)."""
        lines = ["1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT\\"
                 "    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00"]
        for (d, port), far in sorted(self.iface_list().items()):
            if far[0] == "h":
                peer = "if2"
            elif self.switch_peer_form == "name":
                peer = "s%d-eth%d" % (far[1], far[2])
            elif self.switch_peer_form == "none":
                lines.append("%d: s%d-eth%d: <BROADCAST,MULTICAST,UP> mtu 1500" % (self.ifindex(d, port), d, port))
                continue
            else:
                peer = "if%d" % self.ifindex(far[1], far[2])
            lines.append("%d: s%d-eth%d@%s: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc htb state UP "
                         "mode DEFAULT\\    link/ether 4e:4e:38:93:49:%02x brd ff:ff:ff:ff:ff:ff"
                         % (self.ifindex(d, port), d, port, peer, port))
        return "\n".join(lines) + "\n"

    def cli(self, argv, env, inp):
        d = int(argv[argv.index("--thrift-port") + 1]) - 9090
        if d in self.thrift_down:
            return (0, "Could not connect to any of [('127.0.0.1', %d)]\n" % (9090 + d))
        cmd = inp.strip().split()
        body = self.cli_body(self.sw[d], cmd)
        return (0, "Obtaining JSON from switch...\nDone\nControl utility for runtime P4 table manipulation\n"
                   "RuntimeCmd: %s\nRuntimeCmd: " % body)

    @staticmethod
    def fmt_key(k):
        if k[0] == "LPM":
            return "* f : LPM       %08x/%d" % (k[1], k[2])
        if k[0] == "TERNARY":
            return "* f : TERNARY   %x &&& %x" % (k[1], k[2])
        if k[0] == "RANGE":
            return "* f : RANGE     %x -> %x" % (k[1], k[2])
        return "* f : EXACT     %x" % k[1]

    def cli_body(self, s, cmd):
        word = cmd[0]
        if word == "table_dump":
            t = cmd[1]
            if t not in KEYS:
                return "Error: Invalid table name (%s)" % t
            lines = ["==========", "TABLE ENTRIES"]
            for e in s.tables.get(t, []):
                lines += ["**********", "Dumping entry 0x%x" % e["handle"], "Match key:"]
                lines += [self.fmt_key(k) for k in e["keys"]]
                if e["priority"] is not None:
                    lines.append("Priority: %d" % e["priority"])
                lines.append("Action entry: %s - %s" % (e["action"], ", ".join("%x" % p_ for p_ in e["params"])))
            lines += ["==========", "Dumping default entry"]
            dflt = s.defaults.get(t, ("NoAction", []))
            lines += ["Action entry: %s - %s" % (dflt[0], ", ".join("%x" % p_ for p_ in dflt[1])), "=========="]
            return "\n".join(lines)
        if word == "pvs_get":
            return ""                                   # an empty value set (pvs_empty.txt's shape)
        if word == "show_tables":
            names = sorted(KEYS) + (["HcIngress.alt_port_stamp"] if s.dpid == 1 else [])
            return "\n".join("%s [implementation=None, mk=]" % n for n in names)
        if word == "show_ports":
            ports = sorted(p_ for (d, p_) in self.iface_list() if d == s.dpid)
            ports += self.extra_ports.get(s.dpid, [])
            rows = ["    %d   s%d-eth%d   UP   " % (p_, s.dpid, p_) for p_ in ports]
            if self.cpu_port_listed:                    # not what bmv2 does (r3/show_ports_cpu510.log)
                rows.append("    510   s%d-cpu   UP   " % s.dpid)
            return "  port #  iface name  status  extra info\n" + "\n".join(rows)
        if word == "counter_read":
            key = (cmd[1], int(cmd[2]))
            if key not in s.counters:
                return "Error: Invalid counter operation (INVALID_INDEX)"
            return "%s[%s]= (0 bytes, %d packets)" % (cmd[1], cmd[2], s.counters[key])
        if word == "register_read":
            return "%s[%s]= %d" % (cmd[1], cmd[2], s.registers[(cmd[1], int(cmd[2]))])
        if word == "meter_get_rates":
            rates = s.meters.get((cmd[1], int(cmd[2])))
            if not rates:
                return "WARNING: expected 2 rates but only received 0"
            return "\n".join("%d: info rate = %s, burst size = %d" % (i, r, b) for i, (r, b) in enumerate(rates))
        if word == "mirroring_get":
            sid = int(cmd[1])
            if sid not in s.mirroring:
                return "Invalid mirroring operation (SESSION_NOT_FOUND)"
            return "MirroringSessionConfig(port=None, mgid=%d)" % s.mirroring[sid]
        if word == "mc_dump":
            lines = ["==========", "MC ENTRIES"]
            for g, ports in sorted(s.mc.items()):
                lines += ["**********", "mgrp(%d)" % g,
                          "  -> (L1h=0, rid=1) -> (ports=[%s], lags=[])" % ", ".join(str(p_) for p_ in sorted(ports))]
            lines += ["==========", "LAGS", "=========="]
            return "\n".join(lines)
        return "Error: unknown command"

    # --- inside a host ----------------------------------------------------------------------------
    def host_of(self, argv):
        pid = int(argv[4])
        return [h for h, p_ in HOST_PIDS.items() if p_ == pid][0]

    @staticmethod
    def opts(argv):
        out = {}
        for i, tok in enumerate(argv):
            if tok.startswith("--") and i + 1 < len(argv):
                out[tok[2:]] = argv[i + 1]
        return out

    def in_host(self, argv, env, inp):
        h = self.host_of(argv)
        rest = argv[5:]
        if rest[:2] == ["ethtool", "-k"]:
            return (0, "Features for eth0:\nrx-checksumming: on\ntx-checksumming: %s\n" % self.tx_checksum)
        if rest[:4] == ["ip", "-o", "link", "show"]:
            n = int(h[1:])
            return (0, "2: eth0@if%d: <BROADCAST,MULTICAST,UP> mtu 1500\\    link/ether %s brd ff:ff:ff:ff:ff:ff\n"
                    % (self.ifindex(GEN.HOSTS[n], GEN.HOST_PORT[n]), GEN.host_mac(n)))
        if rest[:4] == ["ip", "-o", "addr", "show"]:
            return (0, "2: eth0    inet %s/24 brd 10.0.%s.255 scope global eth0\n" % (GEN.host_ip(int(h[1:])), h[1:]))
        if "send" in rest and rest[rest.index("send") - 1].endswith("hostside.py"):
            return (0, self.send(h, self.opts(rest)))
        return (127, "")

    def hops(self, src, dst_ip):
        dst = [h for h in range(1, 7) if GEN.host_ip(h) == dst_ip][0]
        d, n = GEN.HOSTS[int(src[1:])], 0
        while True:
            n += 1
            port = GEN.ROUTES[d][dst]
            kind, far = GEN.neighbour(d, port)
            if kind == "host":
                return n, "h%d" % far
            d = far

    def send(self, src, o):
        n, dport, sport = int(o["count"]), int(o["dport"]), int(o["sport"])
        cell = o["cell"]
        s_first = self.sw[GEN.HOSTS[int(src[1:])]]
        hops, dst = self.hops(src, o["dst-ip"])
        if dport == 40011 and self.count_k1:
            s_first.counters[("HcIngress.c_in", 0)] += n
        if dport == 40012:
            for e in s_first.tables.get("HcIngress.t_dcount", []):
                if e["keys"] == [("EXACT", 40012)]:
                    s_first.counters[("HcIngress.dc_k2", e["handle"])] += n
        if dport == 40031:
            s_first.registers[("HcIngress.r_mark", 0)] = sport
        for seq in range(n):
            if dport == 40050:
                self.packet_ins.append({"ingress_port": GEN.HOST_PORT[int(src[1:])],
                                        "marker": [o["run"], cell, seq], "dport": dport})
                continue
            if dport == 40041:
                self.digests.append({"digest_id": 1, "members": [ival(o["src-ip"]), sport, dport]})
            frame = F.udp_marker(transit_mac(dst), GEN.host_mac(int(dst[1:])), o["src-ip"], o["dst-ip"],
                                 dport, run_id=o["run"], cell=cell, seq=seq, sport=sport,
                                 ttl=int(o["ttl"]) - (hops if self.ttl_decrements else 0),
                                 ident=int(o["ident"]))
            self.delivered[dst].append(frame)
            # (Cut 2 review MAJOR-2) the receiver has no socket on that port: Linux answers with an
            # ICMP port unreachable that quotes the whole datagram, marker included, back to the
            # sender -- which is also sniffing for its cell in the pingall
            self.delivered[src].append(icmp_unreachable(frame))
        return HS.sent_line(cell, n, int(o["ident"]), n) + "\n"

    # --- spawned children ---------------------------------------------------------------------------
    def fake_proc(self, pid, argv):
        d = os.path.join(self.proc, str(pid))
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "stat"), "w") as fh:
            fh.write("%d (python3) S %s %d 0 0\n" % (pid, " ".join(str(i) for i in range(1, 19)), 900000 + pid))
        with open(os.path.join(d, "cmdline"), "w") as fh:
            fh.write("\0".join(argv) + "\0")

    def spawn(self, argv, out_path, env):
        if self.ctrl_spawn_fails and is_adapter_argv(argv):
            return None                                  # what Runner.spawn answers when Popen raises OSError
        self.next_pid += 1
        pid = self.next_pid
        self.fake_proc(pid, argv)
        if "sniff" in argv:
            return FakeSniffer(self, pid, argv, out_path)
        if is_adapter_argv(argv):
            return FakeController(self, pid, argv, out_path, env)
        return None


def is_adapter_argv(argv):
    """B's controller is started through tools/p4_exercise/run_external_controller.py, whichever copy of it."""
    return any(os.path.basename(a) == "run_external_controller.py" for a in argv)


def transit_mac(host):
    return "08:00:00:00:ff:%02x" % GEN.HOSTS[int(host[1:])]


def icmp_unreachable(frame):
    """What a Linux host sends back for a UDP datagram to a closed port: ICMP type 3 code 3 from
    the receiver to the sender, quoting the original IP datagram (RFC 1812 4.3.2.3; Linux quotes
    as much as fits in 576 bytes, so all of a marker)."""
    total = int.from_bytes(frame[16:18], "big")
    quoted = frame[14:14 + total]
    body = bytes([3, 3, 0, 0, 0, 0, 0, 0]) + quoted
    csum = F.checksum16(body)
    body = body[:2] + csum.to_bytes(2, "big") + body[4:]
    src_ip, dst_ip = F.ip_str(frame[26:30]), F.ip_str(frame[30:34])
    ip = F.ipv4_header(dst_ip, src_ip, 1, len(body))
    return F.ethernet(F.mac_str(frame[6:12]), F.mac_str(frame[0:6]), F.ETH_IPV4, ip + body)


class FakeSniffer(object):
    def __init__(self, fab, pid, argv, path):
        self.fab, self.pid, self.path = fab, pid, path
        self.host = fab.host_of(argv)
        o = fab.opts(argv)
        self.cells, self.run = o["cells"].split(","), o["run"]
        self.until = int(o.get("until") or 0)
        self.dport, self.ip = int(o["dport"]), o["ip"]
        fab.test.assertEqual(self.ip, GEN.host_ip(int(self.host[1:])))     # the receiver's own
        self.mark = len(fab.delivered[self.host])
        self.returncode = None
        with open(path, "w") as fh:
            fh.write(HS.ready_line("eth0") + "\n")

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        if self.returncode is None and self.fab.signal_in_sniffer in self.cells:
            self.fab.signal_in_sniffer = None
            raise LR.SignalAbort(15)                        # what lab_round's handler raises
        if self.returncode is None and self.fab.sniffer_hangs in self.cells:
            self.fab.sniffer_hangs = None
            raise RuntimeError("fake: this sniffer does not end")          # its /proc entry stays
        if self.returncode is None:
            got = []
            for frame in self.fab.delivered[self.host][self.mark:]:
                rec = HS.record(frame, self.run, set(self.cells), self.dport, self.ip)   # hostside's own filter
                if rec is not None:
                    got.append(rec)
                    if self.until and len(got) >= self.until:
                        break
            with open(self.path, "a") as fh:
                for r in got:
                    fh.write(HS.rx_line(r) + "\n")
                fh.write(HS.done_line(len(got)) + "\n")
            shutil.rmtree(os.path.join(self.fab.proc, str(self.pid)), ignore_errors=True)
            self.returncode = 0
        return self.returncode


class FakeController(object):
    """controller_ext.py as the fabric sees it: writes its attributions on s2 at once (ready),
    and on `go` reads the direct counter, sends the packet-out and writes its result."""

    def __init__(self, fab, pid, argv, path, env):
        self.fab, self.pid = fab, pid
        with open(env["P4H_CTRL_CONFIG"]) as fh:
            self.conf = json.load(fh)
        self.returncode = None
        s = fab.sw[2]
        from p4_health import controller_ext as CX
        self.CX = CX
        calls = {}
        self.switches = self.switches_record()

        def ok(name, fn):
            if fab.ctrl_connect_error:
                calls[name] = {"ok": False, "error": self.UNREACHABLE}
                return
            if name in fab.ctrl_fail:
                calls[name] = {"ok": False, "error": "UNKNOWN: refused"}
                return
            fn()
            calls[name] = {"ok": True, "detail": None}
        t, rg, op = CX.TERNARY, CX.RANGE, CX.OPTIONAL
        ok("ternary", lambda: s.add(t["table"], [("TERNARY", ival(t["value"]), ival(t["mask"]))],
                                    "HcIngress.set_mark", [t["mark"]], TOP - t["priority"]))
        ok("range", lambda: s.add(rg["table"], [("RANGE", rg["low"], rg["high"])], "HcIngress.set_mark",
                                  [rg["mark"]], TOP - rg["priority"]))
        ok("optional", lambda: s.add(op["table"], [("TERNARY", op["value"], 0xFF)], "HcIngress.set_mark",
                                     [op["mark"]], TOP - op["priority"]))
        ok("priority", lambda: [s.add(t["table"], [("TERNARY", ival(p_["value"]), ival(p_["mask"]))],
                                      "HcIngress.set_mark", [p_["mark"]], TOP - p_["priority"]) for p_ in CX.PRIORITY])
        rates = [(0.125, 12500), (0.125, 12500)]
        ok("meter", lambda: s.meters.__setitem__(("HcIngress.m_in", 0), rates))
        dm = [e["handle"] for e in s.tables["HcIngress.t_dmeter"]][0]
        ok("direct_meter", lambda: s.meters.__setitem__(("HcIngress.dm_mt3", dm), rates))
        ok("digest", lambda: None)

        def clone():
            s.mirroring[9] = 0x8009
            s.mc[0x8009] = frozenset([1])
        ok("clone", clone)
        if fab.ctrl_connect_error:
            calls["register"] = {"ok": False, "error": self.UNREACHABLE}
        elif fab.ctrl_register_ok:
            ok("register", lambda: s.registers.__setitem__(("HcIngress.r_mark", 1), CX.REGISTER["value"]))
        else:
            calls["register"] = {"ok": False, "error": "UNKNOWN:  [canonical_code 12: Register writes are not supported yet]"}
        self.calls = calls
        if not fab.ctrl_never_ready:
            with open(self.conf["ready"], "w") as fh:
                json.dump({"attributions": calls}, fh)

    #: what a step records when the switch never answers (controller_ext.py:121-127, `step`, with the
    #: gRPC error `_rpc_error` formats, :384-392)
    UNREACHABLE = "UNAVAILABLE: failed to connect to all addresses"

    def switches_record(self):
        """The `switches` document of controller.result.json, shaped as controller_ext.py writes it.
        A switch that answered: `connect()` (:130-157) -- address, device_id, program, primary,
        arbitration_status, set_pipeline_ok -- and `write_routes` (:205) -- routes_written,
        routes_failed. One that did not answer the arbitration: `run()` (:336-339) -- only
        connect_error, formatted by `_rpc_error` (here queue.Empty from `arbitration_queue.get`,
        :147, which has no message)."""
        out = {}
        for d in (1, 2, 3, 4):
            if self.fab.ctrl_connect_error:
                out[str(d)] = {"connect_error": "Empty: "}
                continue
            rec = {"address": "localhost:%d" % (30050 + d), "device_id": d,
                   "program": self.conf["programs"][str(d)], "primary": True, "arbitration_status": 0,
                   "set_pipeline_ok": True, "routes_written": len(RUNTIMES[d]["table_entries"]),
                   "routes_failed": 0}
            if d == 2 and self.fab.ctrl_s2_not_primary:
                rec.update({"primary": False, "arbitration_status": 6})      # ALREADY_EXISTS: another election id holds it
            out[str(d)] = rec
        return out

    def poll(self):
        if self.returncode is None and os.path.exists(self.conf["go"]):
            s = self.fab.sw[2]
            if self.fab.ctrl_connect_error:
                self.calls["direct_counter"] = {"ok": False, "error": self.UNREACHABLE}
                self.calls["packet_out"] = {"ok": False, "error": self.UNREACHABLE}
            else:
                h = [e["handle"] for e in s.tables["HcIngress.t_dcount"]][0]
                self.calls["direct_counter"] = {"ok": True, "detail": {"packets": s.counters[("HcIngress.dc_k2", h)]}}
                po = self.conf["packet_out"]
                for seq in range(po["count"]):
                    self.fab.delivered["h4"].append(F.udp_marker(
                        po["src_mac"], po["dst_mac"], po["src_ip"], po["dst_ip"], 40051,
                        run_id=self.conf["token"], cell="P3", seq=seq))
                self.calls["packet_out"] = {"ok": True, "detail": {"frames": po["count"]}}
            if self.fab.ctrl_garbage_result:
                with open(self.conf["out"], "w") as fh:
                    fh.write("{\"attributions\": ")             # cut off mid-write
            elif not self.fab.ctrl_no_result:
                with open(self.conf["out"], "w") as fh:
                    json.dump({"attributions": self.calls, "digests": self.fab.digests,
                               "packet_ins": self.fab.packet_ins, "switches": self.switches}, fh)
            shutil.rmtree(os.path.join(self.fab.proc, str(self.pid)), ignore_errors=True)
            self.returncode = 0
        return self.returncode

    def wait(self, timeout=None):
        return self.poll()


class FakeTime(object):
    """A clock that moves only when something sleeps: a wait loop ends at its deadline at once."""

    def __init__(self):
        self.now = 0.0

    def sleep(self, s):
        self.now += s

    def clock(self):
        return self.now


class Cut2(Sealed):
    """Bring-ups A and B against the fake fabric, through the real observers and cells."""

    def setUp(self):
        Sealed.setUp(self)
        self.proc = os.path.join(self.tmp, "proc")
        os.makedirs(self.proc)
        self.fab = FakeFabric(self, self.cfg, self.proxy, self.kernel, self.proc)
        os.makedirs(self.cfg.run_dir, exist_ok=True)

    def hosts(self, r, register=None):
        out = os.path.join(self.cfg.run_dir, "A")
        os.makedirs(out, exist_ok=True)
        return HO.Hosts(self.cfg, r, "run-x", out, GEN, register=register, sleep=lambda s: None)

    def fresh_state(self):
        """These helpers build a LabRound and drive its body without running the round, so the
        state file a previous helper left is not a round's: start each from none."""
        if os.path.exists(self.cfg.lab_state_path):
            os.remove(self.cfg.lab_state_path)

    def a_round(self, only=None, register=True):
        self.fresh_state()
        r = self.fab.runner()
        lr = LR.LabRound(self.cfg, r, "A", os.path.join(self.cfg.run_dir, "packages", "A"), "run-x",
                         pid=4242, proc_root=self.proc, install_signals=False)
        a = RA.ARound(self.cfg, r, "run-x", GEN, dict(PIPES4), RUNTIMES, ORDERS, only=only,
                      hosts=self.hosts(r, lr.register if register else None))
        a.body(lr)
        return a, r

    def judge(self, a, confirmed=None):
        obs = LAB.merge(a.observations, confirmed)
        return V.judge_all(T.TABLE, obs, a.sc_observations)

    def all_confirmed(self):
        return {i: {"ok": True, "why": "fixture"} for i in AT.ITEMS}


def expected_rows():
    path = os.path.join(REPO, "doc", "audit", "2026-10-03_p4-health-check", "expected_today.tsv")
    rows = {}
    with open(path) as fh:
        for line in fh:
            if line.startswith("#") or line.startswith("cell\t"):
                continue
            f = line.rstrip("\n").split("\t")
            rows[f[0]] = f
    return rows


class TestBringUpAOnTodaysFabric(Cut2):

    def test_bring_up_a_reads_as_predicted(self):
        """Every Cut 2 cell of bring-up A, through the real observers on a fabric that behaves as
        today's trunk does, gives the verdict expected_today.tsv predicts -- with B's
        attributions confirmed (R3's register write is the one bmv2 refuses: UNATTRIBUTED)."""
        a, _r = self.a_round()
        confirmed = self.all_confirmed()
        confirmed["register"] = {"ok": False, "why": "Register writes are not supported yet"}
        ctx = self.judge(a, confirmed)
        rows = expected_rows()
        got = {c: ctx.cells[c].label for c in set(RA.CUT2_CELLS) | {"CP1", "VS1"}}
        want = {c: rows[c][5] for c in got}
        self.assertEqual(want["R3"], V.UNATTRIBUTED)            # m7: the tsv itself says so now
        self.assertEqual(want["VS1"], V.UNATTRIBUTED)
        self.assertEqual(got, want, {c: ctx.cells[c].reason for c in got if got[c] != want[c]})
        self.assertIs(a.observations["VS1"]["negative"]["absent"], True)
        self.assertEqual({k: v.verdict for k, v in ctx.self_checks.items() if k in a.sc_observations},
                         {"SC-fwd": V.GREEN, "SC-count": V.GREEN, "SC-reg": V.GREEN, "SC-ttl": V.GREEN})
        for cid in ("PL1", "T1", "T2", "M1", "M2", "C1", "T3"):
            self.assertEqual(a.observations[cid]["negative"]["absent"], True, cid)

    def test_without_b_every_bmv2_red_is_unattributed(self):
        a, _r = self.a_round()
        ctx = self.judge(a, None)
        for cid in ("T4", "T5", "T6", "MT1", "MT2", "MT3", "D1", "C2", "R3", "K2", "P2", "P3"):
            self.assertEqual(ctx.cells[cid].verdict, V.UNATTRIBUTED, cid)
        for cid in ("T8", "R2"):
            self.assertEqual(ctx.cells[cid].verdict, V.RED, cid)
        cell = T.TABLE.cell("T4")
        self.assertNotIn("attribution", a.observations["T4"])
        self.assertTrue(V.attribution_holds(cell.red_attribution, {"structural"},
                                            LAB.merge(a.observations, self.all_confirmed())["T4"]))

    def test_every_reading_goes_through_the_one_runner(self):
        a, r = self.a_round()
        heads = {tuple(c["argv"][:3]) for c in r.calls}
        self.assertTrue(all(c["argv"][0] in ("simple_switch_CLI", "ps", "ip", "sudo") for c in r.calls), heads)
        for c in r.calls:
            if c["argv"][0] == "sudo":
                self.assertEqual(c["argv"][:4], ["sudo", "-n", "mnexec", "-a"])
                self.assertIn(c["argv"][4], [str(p_) for p_ in HOST_PIDS.values()])
        thrift = [c for c in r.calls if c["argv"][0] == "simple_switch_CLI"]
        for c in thrift:
            self.assertIn(c["input"].split()[0], TH.READ_COMMANDS)
        spawns = [c for c in r.calls if c.get("spawn")]
        self.assertTrue(spawns and all("sniff" in c["argv"] for c in spawns))
        # every sniffer was recorded in LAB_STATE (pid + start + the run's marker token), and
        # every one has ended, so the teardown finds it "gone" and signals nothing
        with open(self.cfg.lab_state_path) as fh:
            recorded = json.load(fh)["sniffers"]
        self.assertEqual(len(recorded), len(spawns))
        for e in recorded:
            self.assertEqual(e["marker"], HO.marker_token("run-x"))
            self.assertIsNone(LR.proc_identity(e["pid"], self.proc))

    def test_sent_is_the_senders_own_count(self):
        a, _r = self.a_round(only=["K1"])
        self.assertEqual(a.observations["K1"]["sent"], RA.K1_FRAMES)
        self.assertEqual(a.sc_observations["SC-count"]["received"], RA.K1_FRAMES)

    def test_only_k1_ttl1_runs_their_gates_and_controls_and_nothing_else(self):
        a, _r = self.a_round(only=["K1", "TTL1"])
        self.assertEqual(set(a.observations), {"PL1", "T1", "TP1", "K1-neg", "K1", "TTL1"})
        ctx = self.judge(a, None)
        self.assertEqual(ctx.cells["K1"].verdict, V.GREEN)
        self.assertEqual(ctx.cells["T4"].phase, "unobserved")


class TestOneObserverFailing(Cut2):
    """m2: an observer that raises on a live shape it did not expect costs its own cell only."""

    def test_the_rest_of_the_round_is_still_observed(self):
        def boom(*a, **kw):
            raise TypeError("an unexpected live shape")
        with mock.patch.object(OA, "observe_tp1", boom):
            a, _r = self.a_round()
        self.assertEqual(a.observations["TP1"]["answer"], None)
        self.assertIn("TypeError", a.observations["TP1"]["error"])
        self.assertTrue(any("TP1" in p_ and "TypeError" in p_ for p_ in a.problems), a.problems)
        self.assertIn("MT1", a.observations)                     # the last step still ran
        ctx = self.judge(a, self.all_confirmed())
        self.assertEqual(ctx.cells["TP1"].verdict, V.NOT_RUN)
        self.assertEqual(ctx.cells["T8"].verdict, V.RED)

    def test_a_signal_still_ends_the_round(self):
        def sig(*a, **kw):
            raise LR.SignalAbort(15)
        with mock.patch.object(OA, "observe_t2", sig):
            with self.assertRaises(LR.SignalAbort):
                self.a_round()


class TestBringUpARedPaths(Cut2):
    """One fault at a time; the cell that owns it must change, for the stated reason."""

    def verdict(self, cid, only=None, confirmed="all"):
        a, _r = self.a_round(only=only or [cid])
        ctx = self.judge(a, self.all_confirmed() if confirmed == "all" else confirmed)
        return ctx.cells.get(cid) or ctx.self_checks.get(cid), ctx, a

    def test_k1_reads_one_more_than_thrift(self):
        self.fab.proxy_k1_extra = 1
        v, _c, _a = self.verdict("K1")
        self.assertEqual(v.verdict, V.RED, v)
        self.assertIn("NDTwin read %d, thrift %d" % (RA.K1_FRAMES + 1, RA.K1_FRAMES), v.reason)

    def test_the_mutant_counter_is_probe_broken_by_sc_count(self):
        self.fab.count_k1 = False
        v, ctx, _a = self.verdict("K1")
        self.assertEqual((v.verdict, ctx.self_checks["SC-count"].verdict), (V.PROBE_BROKEN, V.PROBE_BROKEN))
        self.assertIn("SC-count", v.reason)

    def test_the_mutant_ttl_is_probe_broken_by_sc_ttl(self):
        self.fab.ttl_decrements = False
        v, ctx, a = self.verdict("TTL1")
        self.assertEqual(v.verdict, V.PROBE_BROKEN, v)
        self.assertIn("SC-ttl", v.reason)
        self.assertEqual(a.sc_observations["SC-ttl"]["hops_lpm"], 2)

    def test_a_wrong_program_is_pl1_red_and_rule_d_keeps_the_round_publishable(self):
        self.fab.pipelines["3"] = "alt0000000000001"
        v, ctx, _a = self.verdict("PL1", only=["K1"])
        self.assertEqual(v.verdict, V.RED)
        self.assertEqual(ctx.self_checks["SC-fwd"].verdict, V.NOT_RUN)
        self.assertEqual(ctx.cells["K1"].verdict, V.NOT_RUN)
        self.assertEqual(V.run_verdict(ctx)[0], "COMPLETE")

    def test_a_failed_package_entry_is_t1_red(self):
        self.fab.fail_entry = 3
        v, _c, _a = self.verdict("T1")
        self.assertEqual(v.verdict, V.RED)
        self.assertIn("s3", v.reason)

    def test_a_missing_dump_entry_is_t1_red_and_sc_fwd_fails(self):
        self.fab.sw[4].tables["HcIngress.v6_host"].pop()
        v, ctx, _a = self.verdict("T1")
        self.assertEqual(v.verdict, V.RED)
        self.assertEqual(ctx.self_checks["SC-fwd"].verdict, V.NOT_RUN)   # gate T1 RED

    def test_a_foreign_sentinel_fails_t1s_negative_read(self):
        self.fab.sw[1].add("HcIngress.ipv4_lpm", [("LPM", ival("10.0.99.2"), 32)], "HcIngress.drop", [])
        RUNTIMES_COPY = copy_runtimes()
        RUNTIMES_COPY[1]["table_entries"].append({"table": "HcIngress.ipv4_lpm",
                                                  "match": {"hdr.ipv4.dstAddr": ["10.0.99.2", 32]},
                                                  "action_name": "HcIngress.drop", "action_params": {}})
        obs = OA.observe_t1(self.cfg, self.fab.runner(), RUNTIMES_COPY, ORDERS, 30)
        self.assertEqual(obs["negative"]["absent"], False)
        v = V.decide(T.TABLE.cell("T1"), obs, V.Context())
        self.assertEqual(v.verdict, V.PROBE_BROKEN, v)

    def test_s2_with_the_compiled_default_is_t2_red(self):
        self.fab.sw[2].defaults["HcIngress.t_default_only"] = ("HcIngress.stamp", [0])
        v, _c, _a = self.verdict("T2")
        self.assertEqual(v.verdict, V.RED)

    def test_s3_not_on_the_compiled_default_fails_t2s_negative_read(self):
        self.fab.sw[3].defaults["HcIngress.t_default_only"] = ("HcIngress.stamp", [0x2A])
        v, _c, _a = self.verdict("T2")
        self.assertEqual(v.verdict, V.PROBE_BROKEN)

    def test_an_unreachable_switch_is_not_run_never_green_or_red(self):
        self.fab.thrift_down = {1, 2}
        for cid in ("T2", "C1", "M2", "T3"):
            v, _c, _a = self.verdict(cid)
            self.assertEqual(v.verdict, V.NOT_RUN, (cid, v))

    def test_an_unreachable_switch_leaves_t1_not_run(self):
        self.fab.thrift_down = {3}
        v, _c, _a = self.verdict("T1")
        self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "oracle"), v)

    def test_k1_markers_lost_on_the_path_leave_sc_count_undecided(self):
        orig = self.fab.send

        def lossy(src, o):
            out = orig(src, o)
            if o["cell"] == "K1":
                self.fab.delivered["h6"] = self.fab.delivered["h6"][:-3]
            return out
        self.fab.send = lossy
        v, ctx, a = self.verdict("K1")
        self.assertEqual(a.sc_observations["SC-count"]["received"], RA.K1_FRAMES - 3)
        self.assertEqual((ctx.self_checks["SC-count"].verdict, v.verdict), (V.NOT_RUN, V.NOT_RUN))

    def test_a_failed_entry_on_s2_is_t2_red(self):
        self.fab.fail_entry = 2
        v, _c, _a = self.verdict("T2")
        self.assertEqual(v.verdict, V.RED)
        self.assertIn("applied", v.reason)

    def test_group_2_there_before_the_write_fails_m2s_negative_read(self):
        self.fab.sw[1].mc[2] = frozenset([2, 3])
        v, _c, _a = self.verdict("M2")
        self.assertEqual(v.verdict, V.PROBE_BROKEN, v)

    def test_a_proxy_that_reads_direct_counters_turns_k2_green(self):
        s2 = self.fab.sw[2]
        handle = [e["handle"] for e in s2.tables["HcIngress.t_dcount"]][0]
        s2.counters[("HcIngress.dc_k2", handle)] = 5           # neither counter starts at zero
        s2.counters[("HcIngress.c_in", 0)] = 7
        self.proxy.routes[("GET", "/p4/counter/HcIngress.dc_k2?dpid=2&index=0")] = lambda b: (
            200, {"packets": s2.counters[("HcIngress.dc_k2", handle)], "bytes": 0})
        v, _c, a = self.verdict("K2")
        self.assertEqual(v.verdict, V.GREEN, v)
        self.assertEqual(a.observations["K2"]["oracle"]["delta"], RA.K2_FRAMES)

    def test_a_kernel_that_installs_meters_turns_mt1_green_and_needs_the_before_read(self):
        s2 = self.fab.sw[2]

        def install(_b):
            s2.meters[("HcIngress.m_in", 0)] = list(OA.METER_TARGET)
            return (200, {"status": "Meter entry installed"})
        self.kernel.routes[("POST", "/ndt/install_meter_entry")] = install
        v, _c, _a = self.verdict("MT1")
        self.assertEqual(v.verdict, V.GREEN, v)
        s2.meters[("HcIngress.m_in", 0)] = list(OA.METER_TARGET)       # already there before
        v, _c, _a = self.verdict("MT1")
        self.assertEqual(v.verdict, V.PROBE_BROKEN, v)

    def test_switch_links_lost_on_both_sides_are_not_a_green(self):
        """MAJOR-1's mirror image: a fabric oracle that cannot read the switch-to-switch peers,
        against a graph that has no switch links either, must not agree its way to GREEN."""
        self.fab.switch_peer_form = "none"
        self.fab.graph_drop_switch_edges = True
        v, _c, a = self.verdict("TP1")
        self.assertIsNone(a.observations["TP1"]["oracle"])
        self.assertEqual(v.verdict, V.NOT_RUN, v)

    def test_an_unplaced_port_is_not_run_and_tp1_keeps_what_it_read(self):
        """N4: TP1's NOT RUN must be diagnosable after `ndt down` has removed the fabric."""
        self.fab.extra_ports = {2: [9]}
        v, _c, a = self.verdict("TP1")
        self.assertEqual(v.verdict, V.NOT_RUN, v)
        d = a.observations["TP1"]["diagnostics"]
        self.assertEqual(d["unplaced"], ["s2-eth9"])
        self.assertIn("s1-eth4@s2-eth2", d["ip_link"])
        self.assertEqual(sorted(d["show_ports"]), ["1", "2", "3", "4"])
        self.assertIn("s2-eth9", d["show_ports"]["2"])
        self.assertEqual(sorted(d["hosts"]), ["h%d" % i for i in range(1, 7)])
        self.assertIn("inet 10.0.1.1/24", d["hosts"]["h1"]["addr"])
        self.assertIn("unplaced", d["failed"])

    def test_a_read_that_failed_is_named(self):
        self.fab.thrift_down = {3}
        _v, _c, a = self.verdict("TP1")
        self.assertIsNone(a.observations["TP1"]["oracle"])
        self.assertIn("show_ports on s3", a.observations["TP1"]["diagnostics"]["failed"])

    def test_a_listed_cpu_port_is_not_a_fabric_port(self):
        self.fab.cpu_port_listed = True
        v, _c, a = self.verdict("TP1")
        self.assertEqual(v.verdict, V.GREEN, v)
        self.assertEqual(a.observations["TP1"]["diagnostics"]["cpu_port_listed"], [1, 2, 3, 4])

    def test_a_missing_edge_is_tp1_red(self):
        self.fab.graph_drop_edge = True
        v, _c, _a = self.verdict("TP1")
        self.assertEqual(v.verdict, V.RED)
        self.assertIn("edges", v.reason)

    def test_checksum_offload_on_is_cs1_red(self):
        self.fab.tx_checksum = "on"
        v, _c, _a = self.verdict("CS1")
        self.assertEqual(v.verdict, V.RED)

    def test_a_proxy_that_writes_ternary_turns_t4_to_t7_green(self):
        self.fab.ndtwin_writes_ternary = True
        a, _r = self.a_round(only=["T4", "T5", "T6", "T7"])
        ctx = self.judge(a, self.all_confirmed())
        self.assertEqual({c: ctx.cells[c].verdict for c in ("T4", "T5", "T6", "T7")},
                         {c: V.GREEN for c in ("T4", "T5", "T6", "T7")})

    def test_a_ternary_writer_that_keeps_p4runtimes_numbers_is_red(self):
        """bmv2's thrift prints INT32_MAX - priority (observed on throwaway switches); a writer that
        stored the P4Runtime number as is would invert the order of every overlapping pair."""
        self.fab.ndtwin_writes_ternary = True
        self.fab.ndtwin_priority = lambda p_: p_
        a, _r = self.a_round(only=["T4", "T7"])
        ctx = self.judge(a, self.all_confirmed())
        self.assertEqual(ctx.cells["T4"].verdict, V.RED)
        self.assertIn("priority_ok", ctx.cells["T4"].reason)
        self.assertEqual(ctx.cells["T7"].verdict, V.NOT_RUN)          # gate T4 RED
        obs = a.observations["T7"]
        self.assertIs(obs["oracle"]["order_ok"], False)

    def test_an_entry_there_before_the_write_fails_t3s_negative_read(self):
        self.fab.sw[2].add("HcIngress.port_exact", [("EXACT", 7)], "HcIngress.set_port_tag", [0x33])
        v, _c, _a = self.verdict("T3")
        self.assertNotEqual(v.verdict, V.GREEN)

    def test_a_multicast_200_that_wrote_nothing_is_m2_red(self):
        self.proxy.routes[("POST", "/p4/multicast_group")] = (200, {"status": "success"})
        v, _c, _a = self.verdict("M2")
        self.assertEqual(v.verdict, V.RED)

    def test_a_missing_clone_session_is_c1_red_and_a_stray_one_fails_the_negative(self):
        del self.fab.sw[2].mirroring[7]
        v, _c, _a = self.verdict("C1")
        self.assertEqual(v.verdict, V.RED)
        self.fab.sw[2].mirroring[7] = 0x8007
        self.fab.sw[3].mirroring[7] = 0x8007
        v, _c, _a = self.verdict("C1")
        self.assertEqual(v.verdict, V.PROBE_BROKEN)

    def test_a_host_the_pingall_cannot_reach_is_sc_fwd_probe_broken(self):
        orig = self.fab.send

        def lossy(src, o):
            out = orig(src, o)
            self.fab.delivered["h5"] = []
            return out
        self.fab.send = lossy
        _v, ctx, a = self.verdict("K1")
        self.assertEqual(ctx.self_checks["SC-fwd"].verdict, V.PROBE_BROKEN)
        self.assertEqual(a.sc_observations["SC-fwd"]["pingall"], (25, 30))

    def test_a_sniffer_that_never_listens_sends_nothing(self):
        orig = self.fab.spawn

        def deaf(argv, out_path, env):
            proc = orig(argv, out_path, env)
            if "sniff" in argv:
                with open(out_path, "w") as fh:
                    fh.write("")
                proc.returncode = 1
            return proc
        self.fab.spawn = deaf
        v, _c, a = self.verdict("K1", only=["K1"])
        self.assertIsNone(a.observations["K1"]["sent"])
        self.assertEqual(ctx_cell(self.judge(a), "K1").verdict, V.NOT_RUN)

    def test_an_unreadable_openapi_is_not_a_missing_route(self):
        del self.proxy.routes[("GET", "/openapi.json")]
        for cid in ("C2", "MT2", "MT3", "R2", "R3", "P3", "D1", "P2"):
            v, _c, _a = self.verdict(cid)
            self.assertEqual(v.verdict, V.NOT_RUN, (cid, v))

    def test_an_exit_the_probe_has_no_client_for_is_not_run(self):
        self.proxy.routes[("GET", "/openapi.json")][1]["paths"]["/p4/digest"] = {"get": {}}
        v, _c, _a = self.verdict("D1")
        self.assertEqual(v.verdict, V.NOT_RUN, v)
        self.assertIn("answer.fields", v.reason)

    def test_checksum_unreadable_on_one_host_is_not_run(self):
        orig = self.fab.in_host

        def broken(argv, env, inp):
            if "ethtool" in argv and argv[4] == str(HOST_PIDS["h3"]):
                return (1, "")
            return orig(argv, env, inp)
        self.fab.in_host = broken
        v, _c, a = self.verdict("CS1")
        self.assertIsNone(a.observations["CS1"]["oracle"])
        self.assertEqual(v.verdict, V.NOT_RUN)


def copy_runtimes():
    import copy
    return copy.deepcopy(RUNTIMES)


def ctx_cell(ctx, cid):
    return ctx.cells[cid]


class TestBringUpB(Cut2):

    def b_round(self, mode="external"):
        self.fresh_state()
        self.fab.mode = mode
        r = self.fab.runner()
        pkg = os.path.join(self.cfg.run_dir, "packages", "B")
        lr = LR.LabRound(self.cfg, r, "B", pkg, "run-x", pid=4242, proc_root=self.proc, install_signals=False)
        out = os.path.join(self.cfg.run_dir, "B")
        os.makedirs(out, exist_ok=True)
        hosts = HO.Hosts(self.cfg, r, "run-x", out, GEN, register=lr.register, sleep=lambda s: None)
        t = FakeTime()
        b = RB.BRound(self.cfg, r, "run-x", GEN, os.path.join(self.tmp, "build"), RUNTIMES, "/tutorials/utils",
                      hosts=hosts, sleep=t.sleep, clock=t.clock)
        b.body(lr)
        return b, r, pkg

    def test_the_eleven_attributions_confirmed_from_thrift_and_the_receiver(self):
        b, r, pkg = self.b_round()
        self.assertEqual({k: v["ok"] for k, v in b.confirmed.items()},
                         dict({i: True for i in AT.ITEMS}, register=False), b.confirmed)
        spawn = [c for c in r.calls if c.get("spawn") and is_adapter_argv(c["argv"])][0]
        self.assertEqual(spawn["argv"], [self.cfg.p4dev_python, RB.ADAPTER, pkg, RB.CONTROLLER,
                                         "--tutorials-utils", "/tutorials/utils"])
        self.assertIn("P4H_CTRL_CONFIG", spawn["env"])
        with open(self.cfg.lab_state_path) as fh:
            recorded = json.load(fh)["controllers"]
        # recorded by pid + start + the run directory its argv carries, and gone by now, so the
        # teardown finds it ended and signals nothing
        self.assertEqual([e["marker"] for e in recorded], [self.cfg.run_dir])
        self.assertIsNone(LR.proc_identity(recorded[0]["pid"], self.proc))
        self.assertEqual(b.problems, [])
        with open(spawn["env"]["P4H_CTRL_CONFIG"]) as fh:
            conf = json.load(fh)
        self.assertEqual(conf["token"], HO.marker_token("run-x"))
        self.assertEqual(sorted(conf["programs"].values()), ["hc_alt", "hc_main", "hc_main", "hc_main"])

    def test_a_call_the_controller_lost_is_unattributed_in_a(self):
        self.fab.ctrl_fail = {"ternary", "meter"}
        b, _r, _p = self.b_round()
        a, _r2 = self.a_round(only=["T4", "MT1", "MT2", "T5"])
        ctx = self.judge(a, b.confirmed)
        self.assertEqual({c: ctx.cells[c].verdict for c in ("T4", "MT1", "MT2", "T5")},
                         {"T4": V.UNATTRIBUTED, "MT1": V.UNATTRIBUTED, "MT2": V.UNATTRIBUTED, "T5": V.RED})

    def test_b_spawns_no_controller_on_a_fabric_that_is_not_external(self):
        """MAJOR-3: the adapter checks only the package file; what is UP must say external."""
        b, r, _p = self.b_round(mode="ndtwin")
        self.assertEqual([c for c in r.calls if c.get("spawn") and is_adapter_argv(c["argv"])], [])
        self.assertFalse(any(v["ok"] for v in b.confirmed.values()))
        self.assertTrue(any("external" in p_ for p_ in b.problems), b.problems)

    def test_no_result_file_confirms_nothing(self):
        self.fab.ctrl_no_result = True
        b, _r, _p = self.b_round()
        self.assertFalse(any(v["ok"] for v in b.confirmed.values()), b.confirmed)
        self.assertTrue(any("no result" in p_ or "no controller result" in p_ for p_ in b.problems), b.problems)


class TestTheLabRun(Cut2):
    """lab.run_lab: S0 must be COMPLETE; A then B, each on its own package in the run dir; the
    verdicts come only after both."""

    def setUp(self):
        Cut2.setUp(self)
        run = self.cfg.run_dir
        os.makedirs(os.path.join(run, "exercise", "build"))
        shutil.copy(GEN_PATH, os.path.join(run, "exercise", "gen_runtime.py"))
        for stem in ("hc_main", "hc_alt"):
            with open(os.path.join(run, "exercise", "build", stem + ".p4.p4info.txtpb"), "w") as fh:
                fh.write(p4info_text())
        self.s0 = {"verdict": "COMPLETE", "builds": {"build/hc_alt": {"p4info_sha16": PIPES4["1"]},
                                                      "build/hc_main": {"p4info_sha16": PIPES4["2"]}},
                   "preflight": {"PF-T": {"rc": 1, "g5_rows": 1, "other_fail_rows": 0}},
                   "self_checks": {"main": {"ternary_held": True}}}
        self.claim = self.cfg.claim_file
        self.expected = os.path.join(REPO, "doc", "audit", "2026-10-03_p4-health-check", "expected_today.tsv")

    def ndt_runner(self, down_rc=0, expire_on_up=False, kill_rc=0):
        test = self

        def claim(argv, env, inp):
            with open(test.claim, "w") as fh:
                fh.write("owner=p4h-test\nexpires=%d\nnote=%s\n" % (int(__import__("time").time()) + 900, argv[3]))
            return (0, "")

        def up(argv, env, inp):
            test.fab.mode = test.fab.force_mode or (
                "external" if argv[-1].rstrip("/").endswith("/B") else "ndtwin")
            if expire_on_up:      # our own claim, expired under the round: the teardown stops early
                with open(test.claim, "w") as fh:
                    fh.write("owner=p4h-test\nexpires=%d\nnote=x\n" % (int(__import__("time").time()) - 5))
            return (0, "up")

        def release(argv, env, inp):
            os.remove(test.claim)
            return (0, "")
        r = RecordingRunner()
        r.add(("ndt", "status", "--measuring"), (0, "  measuring      nothing\n"))
        r.add(("ndt", "claim"), claim)
        r.add(("ndt", "up"), up)
        r.add(("ndt", "down"), (down_rc, ""))
        r.add(("ndt", "release"), release)
        r.add(("qdisc_snapshot.sh",), (0, ""))
        r.add(("sudo", "-n", "mnexec", "-a", "1", "kill"), (kill_rc, ""))

        def kill(argv, env, inp):                       # B's controller, stopped by its pid
            shutil.rmtree(os.path.join(test.proc, argv[-1]), ignore_errors=True)
            return (0, "")
        r.add(("kill",), kill)
        return self.fab.runner(r)

    def fake_time(self):
        t = FakeTime()
        return {"sleep": t.sleep, "clock": t.clock}

    def rounds(self, real_signals=False):
        proc = self.proc

        def make(cfg, runner, bringup, pkg, run_id):
            return LR.LabRound(cfg, runner, bringup, pkg, run_id, pid=4242, proc_root=proc,
                               install_signals=real_signals)
        return make

    def run_lab(self, runner=None, real_signals=False, **kw):
        """`real_signals`: every round installs its own SIGTERM / SIGINT / SIGHUP handlers, as in
        production. The default leaves them off (a test that signals itself from inside a body
        has run_lab's own handler and the reading layer's, and nothing else)."""
        r = runner or self.ndt_runner()
        rc, doc = LAB.run_lab(self.cfg, r, self.s0, self.cfg.run_dir, "run-x",
                              round_cls=self.rounds(real_signals),
                              tutorials_utils="/tutorials/utils", expected_tsv=self.expected,
                              a_kwargs={"hosts": None}, b_kwargs=self.fake_time(),
                              log=lambda *a: None, **kw)
        return rc, doc, r

    def test_the_identity_goes_into_health_json(self):
        r = self.ndt_runner()
        ident = {"gate_fingerprint": {"sha256": "f" * 64, "parts": {}}, "system_under_test": "/r/code_identity.json"}
        _rc, doc = LAB.run_lab(self.cfg, r, self.s0, self.cfg.run_dir, "run-x", round_cls=self.rounds(),
                               tutorials_utils="/tutorials/utils", expected_tsv=self.expected,
                               b_kwargs=self.fake_time(), log=lambda *a: None, identity=ident)
        with open(os.path.join(self.cfg.run_dir, "health.json")) as fh:
            h = json.load(fh)
        self.assertEqual((h["gate_fingerprint"]["sha256"], h["system_under_test"]), ("f" * 64, "/r/code_identity.json"))

    def test_a_then_b_then_the_verdicts(self):
        rc, doc, r = self.run_lab()
        ndt = [(c["argv"][1], c["argv"][-1] if c["argv"][1] == "up" else "") for c in r.calls if c["argv"][0] == "ndt"]
        ups = [os.path.relpath(p_, self.cfg.run_dir) for v, p_ in ndt if v == "up"]
        self.assertEqual(ups, ["packages/A", "packages/B"])
        self.assertEqual([v for v, _ in ndt], ["status", "claim", "up", "down", "release"] * 2)
        cells = {c["id"]: c for c in doc["cells"]}
        self.assertEqual((cells["T4"]["verdict"], cells["T4"]["attribution"]["ok"]), (V.RED, True),
                         cells["T4"])
        self.assertEqual(cells["R3"]["verdict"], V.UNATTRIBUTED)
        self.assertEqual(cells["PF-T"]["verdict"], V.RED)
        self.assertEqual(cells["CH1"]["phase"], "unobserved")
        # m1: nothing this run did not observe reads as a flip -- an alias of such a cell neither
        deltas = {c["id"]: c["delta"] for c in doc["cells"]}
        self.assertEqual(deltas["VB1"], "not observed")
        self.assertEqual(sorted(c for c, d in deltas.items() if d == "flipped"), [])
        self.assertEqual((doc["verdict"], rc), ("COMPLETE", 0))
        self.assertTrue(os.path.isfile(os.path.join(self.cfg.run_dir, "health.json")))
        self.assertIn("gate_fingerprint", doc)
        self.assertIn("system_under_test", doc)
        self.assertTrue(os.path.isfile(os.path.join(self.cfg.run_dir, "A", "K1.json")))

    # --- MAJOR-3: B only after A ended clean, and A's record survives -------------------------
    def assert_b_kept_out(self, r, rc, doc, a_phase):
        ndt = [c["argv"][1] for c in r.calls if c["argv"][0] == "ndt"]
        self.assertEqual((ndt.count("claim"), ndt.count("up")), (1, 1), ndt)
        self.assertEqual([c for c in r.calls if c.get("spawn") and is_adapter_argv(c["argv"])], [])
        with open(self.cfg.lab_state_path) as fh:
            st = json.load(fh)
        self.assertEqual((st["bring_up"], st["phase"]), ("A", a_phase))
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        self.assertTrue(any("B not brought up" in p_ for p_ in doc["problems"]), doc["problems"])
        self.assertEqual([b["id"] for b in doc["bringups"]], ["A"])
        return st

    def test_a_failed_down_in_a_keeps_b_out(self):
        rc, doc, r = self.run_lab(runner=self.ndt_runner(down_rc=1))
        self.assert_b_kept_out(r, rc, doc, "down-failed")

    def test_a_claim_lost_in_a_keeps_b_out(self):
        rc, doc, r = self.run_lab(runner=self.ndt_runner(expire_on_up=True))
        self.assert_b_kept_out(r, rc, doc, "claim-lost")

    def test_a_failed_kill_in_a_keeps_b_out(self):
        self.fab.sniffer_hangs = "K1"
        rc, doc, r = self.run_lab(runner=self.ndt_runner(kill_rc=1))
        st = self.assert_b_kept_out(r, rc, doc, "released")
        self.assertEqual(len(st["sniffers"]), 1)              # left for recover.sh

    def test_each_bring_ups_last_state_is_kept(self):
        _rc, _doc, _r = self.run_lab()
        for x in ("A", "B"):
            with open(os.path.join(self.cfg.run_dir, "LAB_STATE.%s.json" % x)) as fh:
                st = json.load(fh)
            self.assertEqual((st["bring_up"], st["phase"]), (x, "released"))

    # --- N1: a stop signal ends the run; N2: a B that did nothing is not COMPLETE -----------
    def assert_signal_ended_the_run(self, r, rc, doc):
        ndt = [c["argv"][1] for c in r.calls if c["argv"][0] == "ndt"]
        self.assertEqual((ndt.count("claim"), ndt.count("up")), (1, 1), ndt)
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        self.assertTrue(any("aborted by signal" in p_ for p_ in doc["bringups"][0]["problems"]), doc["bringups"])
        self.assertTrue(any("stop signal" in p_ for p_ in doc["problems"]), doc["problems"])
        self.assertTrue(os.path.isfile(os.path.join(self.cfg.run_dir, "health.json")))

    def test_a_signal_in_an_observer_ends_the_run(self):
        def sig(*a, **kw):
            raise LR.SignalAbort(15)
        with mock.patch.object(OA, "observe_t2", sig):
            rc, doc, r = self.run_lab()
        self.assert_signal_ended_the_run(r, rc, doc)

    def test_a_signal_while_a_sniffer_is_waited_for_ends_the_round_there(self):
        self.fab.signal_in_sniffer = "K1"
        rc, doc, r = self.run_lab()
        self.assert_signal_ended_the_run(r, rc, doc)
        with open(os.path.join(self.cfg.run_dir, "observations.json")) as fh:
            seen = set(json.load(fh)["cells"])
        later = set(RA.ACTIVE[RA.ACTIVE.index("K1") + 1:])
        self.assertEqual(seen & later, set(), "steps after the signal were still observed")
        self.assertNotIn("K1", seen)

    def test_a_signal_between_the_rounds_ends_the_run(self):
        """N1's window: from A's teardown to B's claim no round's handler is in place. run_lab's
        own handler turns a SIGTERM there into a stop too (a safety handler stands in for the
        default action, so the test process survives on code without it)."""
        seen = []
        safety = signal.signal(signal.SIGTERM, lambda n, f: seen.append(n))
        real_keep = LAB.keep_state

        def keep_then_kill(cfg, bringup):
            real_keep(cfg, bringup)
            if bringup == "A":
                os.kill(os.getpid(), signal.SIGTERM)
        try:
            with mock.patch.object(LAB, "keep_state", keep_then_kill):
                rc, doc, r = self.run_lab()
        finally:
            restored = signal.signal(signal.SIGTERM, safety)
        ndt = [c["argv"][1] for c in r.calls if c["argv"][0] == "ndt"]
        self.assertEqual((ndt.count("claim"), ndt.count("up")), (1, 1), ndt)
        self.assertEqual(seen, [])                       # run_lab's handler took it, not the safety one
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        self.assertTrue(any("stop signal 15" in p_ for p_ in doc["problems"]), doc["problems"])
        self.assertNotEqual(getattr(restored, "__name__", ""), "raiser")   # the caller's handler is back

    # --- round 4, F1: a stop during a teardown ends the run too -------------------------------
    def stop_in_down(self, nth):
        """A runner whose `nth` `ndt down` sends SIGTERM to the probe (this process), as a
        `kill -TERM <pid>` from outside does while subprocess.run waits for ndt: the handler
        runs and the wait resumes (PEP 475). Returns (runner, what the safety handler got)."""
        r = self.ndt_runner()
        downs, seen = [], []

        def down(argv, env, inp):
            downs.append(argv)
            if len(downs) == nth:
                os.kill(os.getpid(), signal.SIGTERM)
            return (0, "")
        r.replies = [(m, down if m == ("ndt", "down") else rep) for m, rep in r.replies]
        return r, seen

    def run_with_a_stop_in_down(self, nth):
        r, seen = self.stop_in_down(nth)
        safety = signal.signal(signal.SIGTERM, lambda n, f: seen.append(n))
        try:
            rc, doc, r = self.run_lab(runner=r, real_signals=True)
        finally:
            signal.signal(signal.SIGTERM, safety)
        self.assertEqual(seen, [], "the signal reached the safety handler: no handler of the probe took it")
        return rc, doc, r

    def test_a_stop_during_a_teardown_ends_the_run_before_b_claims(self):
        """The review's F1: with the teardown handler only noting the signal, B was claimed and
        brought up after a stop. REAL LabRound handlers: the factory of the other run_lab tests
        turns them off, which is why nothing saw this."""
        rc, doc, r = self.run_with_a_stop_in_down(1)
        ndt = [c["argv"][1] for c in r.calls if c["argv"][0] == "ndt"]
        self.assertEqual((ndt.count("claim"), ndt.count("up")), (1, 1), ndt)
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        self.assertTrue(any("aborted by signal 15 (during the teardown)" in p_
                            for p_ in doc["bringups"][0]["problems"]), doc["bringups"])
        self.assertTrue(any("stop signal" in p_ for p_ in doc["problems"]), doc["problems"])
        self.assertEqual(ndt[-2:], ["down", "release"])         # A's cleanup was finished, not cut short

    def test_a_stop_during_b_teardown_is_not_complete(self):
        rc, doc, r = self.run_with_a_stop_in_down(2)
        ndt = [c["argv"][1] for c in r.calls if c["argv"][0] == "ndt"]
        self.assertEqual((ndt.count("claim"), ndt.count("up"), ndt.count("release")), (2, 2, 2), ndt)
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        self.assertTrue(any("aborted by signal 15 (during the teardown)" in p_
                            for p_ in doc["bringups"][1]["problems"]), doc["bringups"])
        self.assertTrue(any("stop signal" in p_ for p_ in doc["problems"]), doc["problems"])

    def test_root_runs_a_frozen_copy_of_its_code_from_the_run_dir(self):
        """N8: root executes hostside.py, frames.py and __init__.py; it runs copies taken into the
        run dir before S0, so the shared tree can change under a 15-minute run and root still
        runs what was recorded. (Round 4, F9) The record is of the COPY's bytes."""
        rc, doc, r = self.run_lab()
        base = os.path.join(os.path.realpath(self.cfg.run_dir), "frozen", "p4_health")
        root_argvs = [c["argv"] for c in r.calls if c["argv"][:4] == ["sudo", "-n", "mnexec", "-a"]
                      and any(a.endswith("hostside.py") for a in c["argv"])]
        self.assertTrue(root_argvs)
        for argv in root_argvs:
            self.assertIn(os.path.join(base, "hostside.py"), argv)
        import hashlib
        for name in ("hostside.py", "frames.py", "__init__.py"):
            with open(os.path.join(base, name), "rb") as fh:
                want = hashlib.sha256(fh.read()).hexdigest()
            self.assertEqual(doc["root_code"][name], want, name)

    def test_b_runs_its_controller_and_the_adapter_from_the_frozen_copy(self):
        """(Round 4, F4b) B's controller and the adapter run as the caller, but they write P4Runtime
        state on the fabric: they too run the run dir's copies, not the shared tree, and the
        record carries their hashes (of the copies' bytes)."""
        rc, doc, r = self.run_lab()
        base = os.path.join(os.path.realpath(self.cfg.run_dir), "frozen")
        spawn = [c for c in r.calls if c.get("spawn") and is_adapter_argv(c["argv"])]
        self.assertEqual(len(spawn), 1)
        self.assertEqual(spawn[0]["argv"], [
            self.cfg.p4dev_python, os.path.join(base, "p4_exercise", "run_external_controller.py"),
            os.path.join(os.path.realpath(self.cfg.run_dir), "packages", "B"),
            os.path.join(base, "p4_health", "controller_ext.py"),
            "--tutorials-utils", "/tutorials/utils"])
        import hashlib
        for rel in ("p4_health/controller_ext.py", "p4_exercise/run_external_controller.py",
                    "p4_exercise/common.py", "p4_exercise/__init__.py", "p4_health/frames.py"):
            with open(os.path.join(base, rel), "rb") as fh:
                self.assertEqual(doc["frozen_code"][rel], hashlib.sha256(fh.read()).hexdigest(), rel)

    def test_run_lab_runs_the_frozen_code_it_is_given(self):
        """(Round 4, F4a) probe.py freezes and checks the code before S0 and hands it to run_lab;
        run_lab must run exactly that, not freeze a second set unchecked."""
        from p4_health import frozen as FZ
        other = os.path.join(self.tmp, "elsewhere")
        fz = FZ.freeze(other)
        rc, doc, r = self.run_lab(frozen=fz)
        root = [c["argv"] for c in r.calls if c["argv"][:4] == ["sudo", "-n", "mnexec", "-a"]
                and any(a.endswith("hostside.py") for a in c["argv"])]
        self.assertTrue(root)
        for argv in root:
            self.assertIn(fz.hostside, argv)
        spawn = [c["argv"] for c in r.calls if c.get("spawn") and is_adapter_argv(c["argv"])][0]
        self.assertEqual((spawn[1], spawn[3]), (fz.adapter, fz.controller))
        self.assertEqual(doc["frozen_code"], fz.sums)
        self.assertFalse(os.path.exists(os.path.join(self.cfg.run_dir, "frozen")))

    def test_b_controller_is_recorded_when_the_run_dir_path_has_a_link(self):
        """(Round 4, F6) LabRound hands out the RESOLVED package path, so the controller's argv
        carries the resolved run dir. The marker it is registered by must be that path too, or
        `register` refuses it: neither the teardown nor recover.sh could then stop it. The kill
        fails here, so the entry stays in B's state file to be seen."""
        real = self.cfg.run_dir
        link = os.path.join(self.tmp, "runlink")
        os.symlink(real, link)
        self.cfg.run_dir = link
        self.fab.ctrl_never_ready = True            # the controller is still running when B ends
        r = self.ndt_runner()
        r.replies.insert(0, (("kill",), (1, "")))      # ... and cannot be stopped
        rc, doc, _r = self.run_lab(runner=r)
        with open(os.path.join(link, "LAB_STATE.B.json")) as fh:
            ctrls = json.load(fh)["controllers"]
        self.assertEqual([c["marker"] for c in ctrls], [os.path.realpath(real)])
        self.assertFalse(any("not recorded" in p_ for b in doc["bringups"] for p_ in b["problems"]), doc["bringups"])

    def test_b_on_a_fabric_that_is_not_external_is_incomplete(self):
        self.fab.force_mode = "ndtwin"
        rc, doc, r = self.run_lab()
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        self.assertTrue(any("B's controller" in p_ for p_ in doc["problems"]), doc["problems"])

    def test_a_controller_that_never_gets_ready_is_incomplete(self):
        self.fab.ctrl_never_ready = True
        rc, doc, r = self.run_lab()
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        self.assertTrue(any("B's controller" in p_ for p_ in doc["problems"]), doc["problems"])

    # --- round 4, F2: every exit of B without a controller result is a failed B --------------
    def assert_b_failed(self, rc, doc, why):
        """INCOMPLETE rc 2, and the run's problems say B's controller did not do its part, and why."""
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        self.assertTrue(any(p_.startswith("B's controller did not do its part") and why in p_
                            for p_ in doc["problems"]), doc["problems"])
        self.assertFalse(any(v["ok"] for v in doc["attributions"].values()), doc["attributions"])

    def test_b_whose_fabric_is_not_external_is_a_failed_b(self):                    # exit 1 of 6
        self.fab.force_mode = "ndtwin"
        rc, doc, _r = self.run_lab()
        self.assert_b_failed(rc, doc, "not external")

    def test_b_whose_controller_never_gets_ready_is_a_failed_b(self):               # exit 2 of 6
        self.fab.ctrl_never_ready = True
        rc, doc, _r = self.run_lab()
        self.assert_b_failed(rc, doc, "never wrote its ready file")

    def test_b_whose_controller_cannot_be_started_is_a_failed_b(self):              # exit 3 of 6
        self.fab.ctrl_spawn_fails = True
        rc, doc, _r = self.run_lab()
        self.assert_b_failed(rc, doc, "could not be started")

    def test_b_whose_sniffer_is_not_ready_is_a_failed_b(self):                      # exit 4 of 6
        """h4's P3 sniffer never prints READY: hosts.window runs no stimulate(), so no marker is
        sent and controller.go is never written. The controller waits for `go` and the probe
        gives up; the run used to read COMPLETE with every bmv2 attribution unconfirmed."""
        orig = self.fab.spawn

        def deaf(argv, out_path, env):
            proc = orig(argv, out_path, env)
            if "sniff" in argv and self.fab.opts(argv)["cells"] == "P3":
                with open(out_path, "w") as fh:
                    fh.write("")
                proc.returncode = 1
            return proc
        self.fab.spawn = deaf
        rc, doc, _r = self.run_lab()
        self.assert_b_failed(rc, doc, "sniffer")
        self.assertFalse(os.path.exists(os.path.join(self.cfg.run_dir, "B", "controller.go")))

    def test_b_whose_controller_writes_no_result_is_a_failed_b(self):               # exit 5 of 6
        self.fab.ctrl_no_result = True
        rc, doc, _r = self.run_lab()
        self.assert_b_failed(rc, doc, "wrote no result")

    def test_b_whose_result_file_is_unreadable_is_a_failed_b(self):                 # exit 6 of 6
        self.fab.ctrl_garbage_result = True
        rc, doc, _r = self.run_lab()
        self.assert_b_failed(rc, doc, "no controller result")

    # --- round 5, #2: on the lab path rc 1 means PROBE-BROKEN and nothing else ---------------
    def assert_incomplete_with_reason(self, rc, doc, *why):
        """INCOMPLETE rc 2, and the health.json on disk carries the reason(s)."""
        self.assertEqual(rc, 2)
        with open(os.path.join(self.cfg.run_dir, "health.json")) as fh:
            h = json.load(fh)
        self.assertEqual(h["verdict"], "INCOMPLETE")
        self.assertEqual(doc["verdict"], "INCOMPLETE")
        for w in why:
            self.assertTrue(any(w in p_ for p_ in h["problems"]), (w, h["problems"]))
        return h

    # --- round 5, #4: a B that ran, wrote a result and confirmed nothing is a failed B ---------------
    def test_b_whose_controller_reached_no_switch_is_a_failed_b(self):
        """The result file is there and well-formed, every switch carries a connect_error and every step
        failed (controller_ext.py:121-127, 336-339): used to read COMPLETE rc 0 with no problems."""
        self.fab.ctrl_connect_error = True
        rc, doc, _r = self.run_lab()
        self.assert_b_failed(rc, doc, "confirmed nothing")
        self.assertTrue(any("connect_error" in p_ for p_ in doc["problems"]), doc["problems"])
        self.assertEqual(doc["attributions"]["ternary"]["ok"], False)

    def test_b_whose_controller_is_not_primary_on_s2_is_a_failed_b(self):
        """s2 granted the pipeline (set_pipeline_ok) but not primary (controller_ext.py:148-157), and the
        attributions that followed all confirmed: B still did not do its part."""
        self.fab.ctrl_s2_not_primary = True
        rc, doc, _r = self.run_lab()
        self.assertTrue(sum(1 for k, v in doc["attributions"].items() if v["ok"]) > 1, doc["attributions"])
        self.assert_b_failed_only_by(rc, doc, "not primary")

    def assert_b_failed_only_by(self, rc, doc, why):
        """As assert_b_failed, for a B some of whose attributions DID confirm."""
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        self.assertTrue(any(p_.startswith("B's controller did not do its part") and why in p_
                            for p_ in doc["problems"]), doc["problems"])

    def test_a_b_that_confirmed_most_of_its_attributions_is_not_a_failed_b(self):
        """The control of the two above: the usual B -- everything but register confirmed, all four
        switches primary -- reads COMPLETE with no problems."""
        rc, doc, _r = self.run_lab()
        self.assertEqual((doc["verdict"], rc, doc["problems"]), ("COMPLETE", 0, []))

    def test_a_b_that_lost_two_calls_is_not_a_failed_b(self):
        """... and so does one whose controller lost two calls: those cells read UNATTRIBUTED, which is
        the answer, not a failure of B."""
        self.fab.ctrl_fail = {"ternary", "meter"}
        rc, doc, _r = self.run_lab()
        self.assertEqual((doc["verdict"], rc, doc["problems"]), ("COMPLETE", 0, []))

    def test_an_incomplete_s0_touches_nothing(self):
        """(Round 5, #2) S0 with one failing check: INCOMPLETE rc 2 (not rc 1, which is the see-red
        run's pass), no lab action, and a health.json that names the check."""
        self.s0["verdict"] = "PROBE-BROKEN"
        self.s0["checks"] = [{"name": "compile build/hc_main", "ok": True, "detail": ""},
                             {"name": "preflight A", "ok": False, "detail": "FAIL x"}]
        rc, doc, r = self.run_lab()
        self.assert_incomplete_with_reason(rc, doc, "S0 is PROBE-BROKEN", "preflight A")
        self.assertEqual(r.calls, [])

    def test_a_leftover_lab_state_is_incomplete_rc_2_and_stays_for_recover(self):
        """(Round 5, #2) --mutant --only K1,TTL1 --bringups A in a run dir whose LAB_STATE.json
        belongs to a round that did not finish: StateInUse used to leave run_lab as an exception
        (Python's exit status 1, no health.json). The file is recover.sh's: it is not touched."""
        left = {"bring_up": "A", "phase": "up", "sniffers": [], "controllers": [], "netem": []}
        os.makedirs(os.path.dirname(self.cfg.lab_state_path), exist_ok=True)
        with open(self.cfg.lab_state_path, "w") as fh:
            json.dump(left, fh)
        rc, doc, r = self.run_lab(bringups=("A",), only=["K1", "TTL1"], mutant=True)
        self.assert_incomplete_with_reason(rc, doc, "StateInUse", "LAB_STATE.json")
        self.assertEqual(r.calls, [])
        with open(self.cfg.lab_state_path) as fh:
            self.assertEqual(json.load(fh), left)

    def test_a_load_model_failure_is_incomplete_rc_2(self):
        with mock.patch.object(LAB, "load_model", side_effect=OSError("gen_runtime.py: no such file")):
            rc, doc, r = self.run_lab()
        self.assert_incomplete_with_reason(rc, doc, "gen_runtime.py: no such file")
        self.assertEqual(r.calls, [])

    def test_an_expectations_failure_is_incomplete_rc_2(self):
        with mock.patch.object(LAB, "expectations", side_effect=KeyError("build/hc_alt")):
            rc, doc, r = self.run_lab()
        self.assert_incomplete_with_reason(rc, doc, "KeyError", "build/hc_alt")
        self.assertEqual(r.calls, [])

    def test_a_round_that_cannot_be_built_ends_the_run_incomplete_with_the_earlier_rounds_kept(self):
        """An exception out of B's LabRound constructor, after A went through, with a PROBE-BROKEN
        cell in A: the headline is INCOMPLETE rc 2 (the run ended early), A's record is in
        health.json, and the reason is a problem of the run."""
        self.fab.count_k1 = False
        proc = self.proc

        def make(cfg, runner, bringup, pkg, run_id):
            if bringup == "B":
                raise LR.StateInUse("planted")
            return LR.LabRound(cfg, runner, bringup, pkg, run_id, pid=4242, proc_root=proc,
                               install_signals=False)
        rc, doc = LAB.run_lab(self.cfg, self.ndt_runner(), self.s0, self.cfg.run_dir, "run-x", round_cls=make,
                              tutorials_utils="/tutorials/utils", expected_tsv=self.expected,
                              b_kwargs=self.fake_time(), log=lambda *a: None)
        h = self.assert_incomplete_with_reason(rc, doc, "StateInUse", "planted")
        self.assertEqual([b["id"] for b in h["bringups"]], ["A"])
        cells = {c["id"]: c for c in h["cells"]}
        self.assertEqual(cells["K1"]["verdict"], V.PROBE_BROKEN)

    def test_a_refused_claim_makes_the_run_incomplete(self):
        r = self.ndt_runner()
        claims = []

        def claim(argv, env, inp):
            claims.append(argv)
            if len(claims) == 2:                    # bring-up B's claim is refused
                return (1, "")
            with open(self.claim, "w") as fh:
                fh.write("owner=p4h-test\nexpires=%d\nnote=x\n" % (int(__import__("time").time()) + 900))
            return (0, "")
        r.replies = [(m, claim if m == ("ndt", "claim") else rep) for m, rep in r.replies]
        rc, doc = LAB.run_lab(self.cfg, r, self.s0, self.cfg.run_dir, "run-x", round_cls=self.rounds(),
                              tutorials_utils="/tutorials/utils", expected_tsv=self.expected,
                              b_kwargs=self.fake_time(), log=lambda *a: None)
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))
        cells = {c["id"]: c for c in doc["cells"]}
        self.assertEqual(cells["T4"]["verdict"], V.UNATTRIBUTED)     # B never ran

    def test_the_see_red_run_uses_the_mutant_package_and_only_its_cells(self):
        self.fab.count_k1 = False
        self.fab.ttl_decrements = False
        rc, doc, r = self.run_lab(bringups=("A",), only=["K1", "TTL1"], mutant=True)
        ups = [c["argv"][-1] for c in r.calls if c["argv"][:2] == ["ndt", "up"]]
        self.assertEqual([os.path.relpath(u, self.cfg.run_dir) for u in ups], ["packages/A-MUT"])
        cells = {c["id"]: c for c in doc["cells"]}
        self.assertEqual({c: cells[c]["verdict"] for c in ("K1", "TTL1", "PL1", "T1", "TP1")},
                         {"K1": V.PROBE_BROKEN, "TTL1": V.PROBE_BROKEN, "PL1": V.GREEN, "T1": V.GREEN,
                          "TP1": V.GREEN})
        self.assertIn("SC-count", cells["K1"]["reason"])
        self.assertIn("SC-ttl", cells["TTL1"]["reason"])
        # the one run whose PROBE-BROKEN is the success: A came up, was read, went down clean
        self.assertEqual(([b["complete"] for b in doc["bringups"]], doc["problems"]), ([True], []))
        self.assertEqual((doc["verdict"], rc), ("PROBE-BROKEN", 1))

    # --- round 4, F3: PROBE-BROKEN does not hide a stop or an unclean round ------------------
    def test_a_see_red_run_stopped_after_k1_is_incomplete_not_a_pass(self):
        """The review's scenario: --mutant --only K1,TTL1 --bringups A, stopped while TTL1 is
        read. K1 is PROBE-BROKEN by SC-count and TTL1 was never observed; the headline used to
        read PROBE-BROKEN rc 1, which is what a see-red PASS reads."""
        self.fab.count_k1 = False
        self.fab.signal_in_sniffer = "TTL1"
        rc, doc, _r = self.run_lab(bringups=("A",), only=["K1", "TTL1"], mutant=True)
        cells = {c["id"]: c for c in doc["cells"]}
        self.assertEqual(cells["K1"]["verdict"], V.PROBE_BROKEN)
        self.assertEqual(cells["TTL1"]["verdict"], V.NOT_RUN)
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))

    def test_a_see_red_run_whose_mutant_is_not_caught_is_not_a_pass(self):
        """(Round 5, #3) The mutant package is up but K1 and TTL1 read as on the plain one (the fake
        fabric counts and decrements as it should): no cell is PROBE-BROKEN, the probe cannot see
        red. The run was complete and clean, and still must not read COMPLETE rc 0."""
        rc, doc, _r = self.run_lab(bringups=("A",), only=["K1", "TTL1"], mutant=True)
        cells = {c["id"]: c for c in doc["cells"]}
        self.assertEqual({c: cells[c]["verdict"] for c in ("K1", "TTL1")}, {"K1": V.GREEN, "TTL1": V.GREEN})
        self.assertEqual(([b["complete"] for b in doc["bringups"]], doc["problems"]), ([True], []))
        self.assertEqual((doc["verdict"], rc), ("SEE-RED-NOT-SEEN", 2))
        with open(os.path.join(self.cfg.run_dir, "health.json")) as fh:
            self.assertEqual(json.load(fh)["verdict"], "SEE-RED-NOT-SEEN")

    def test_a_recorded_stop_overrides_a_probe_broken_cell(self):
        """F3(a): any run whose record carries 'aborted by signal' is INCOMPLETE rc 2, whatever
        the cell verdicts say (a full run here, so the see-red rule has no part in it)."""
        self.fab.count_k1 = False
        self.fab.signal_in_sniffer = "TTL1"
        rc, doc, _r = self.run_lab()
        cells = {c["id"]: c for c in doc["cells"]}
        self.assertEqual(cells["K1"]["verdict"], V.PROBE_BROKEN)
        self.assertTrue(any("aborted by signal" in p_ for p_ in doc["bringups"][0]["problems"]))
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))

    def test_a_stop_between_the_rounds_overrides_a_probe_broken_cell(self):
        """The same for the run-level stop, which no round's record carries."""
        self.fab.count_k1 = False
        seen = []
        safety = signal.signal(signal.SIGTERM, lambda n, f: seen.append(n))
        real_keep = LAB.keep_state

        def keep_then_kill(cfg, bringup):
            real_keep(cfg, bringup)
            if bringup == "A":
                os.kill(os.getpid(), signal.SIGTERM)
        try:
            with mock.patch.object(LAB, "keep_state", keep_then_kill):
                rc, doc, _r = self.run_lab()
        finally:
            signal.signal(signal.SIGTERM, safety)
        self.assertEqual(seen, [])
        cells = {c["id"]: c for c in doc["cells"]}
        self.assertEqual(cells["K1"]["verdict"], V.PROBE_BROKEN)
        self.assertTrue(any("stop signal 15" in p_ for p_ in doc["problems"]), doc["problems"])
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))

    def test_a_see_red_run_whose_round_did_not_end_clean_is_incomplete(self):
        """F3(b): the see-red pass needs a complete, clean run. A's `ndt down` failed here (the
        lab was left up), and the headline used to be the same PROBE-BROKEN rc 1."""
        self.fab.count_k1 = False
        self.fab.ttl_decrements = False
        rc, doc, _r = self.run_lab(runner=self.ndt_runner(down_rc=1), bringups=("A",), only=["K1", "TTL1"],
                                   mutant=True)
        cells = {c["id"]: c for c in doc["cells"]}
        self.assertEqual((cells["K1"]["verdict"], cells["TTL1"]["verdict"]), (V.PROBE_BROKEN, V.PROBE_BROKEN))
        self.assertFalse(doc["bringups"][0]["complete"])
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))

    def test_a_see_red_run_with_a_problem_of_the_run_is_incomplete(self):
        """F3(b), the other half: bringups[0] is complete, but the run has a problem of its own
        (here B kept out because A left something behind)."""
        self.fab.count_k1 = False
        self.fab.ttl_decrements = False
        with mock.patch.object(LAB, "ended_clean", lambda lr, rec: ["a leftover"]):
            rc, doc, _r = self.run_lab(bringups=("A", "B"), only=["K1", "TTL1"], mutant=True)
        self.assertTrue(doc["bringups"][0]["complete"])
        self.assertTrue(any("B not brought up" in p_ for p_ in doc["problems"]), doc["problems"])
        self.assertEqual((doc["verdict"], rc), ("INCOMPLETE", 2))


if __name__ == "__main__":
    unittest.main()
