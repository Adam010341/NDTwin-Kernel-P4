#!/usr/bin/env python3
"""The P4 health check's reading layer and lab lifecycle, sealed off from the lab (DESIGN 5.2-②).

[Co-developed with claude code -- Adam]

HERMETIC BY CONSTRUCTION, and checked after every test:

  * PATH starts with a directory whose `sudo`, `tc`, `ndt`, `mnexec` and `simple_switch_CLI` exit
    99 and append a line to a TRIPWIRE file. Every test ends by asserting that file does not
    exist -- anything that reached one of them, by any route, is a red test.
  * `socket.socket.connect`, `connect_ex` and `socket.create_connection` are wrapped: a connect to
    127.0.0.1, ::1, localhost or 0.0.0.0 on 8000, 8081, 30051-30060 or 9091-9100 is refused and
    recorded, and every test asserts none was attempted (section 12 item 9).
  * `grpc` is replaced in sys.modules by a stub that raises on any use.
  * `subprocess.Popen` is wrapped to record every spawn (it still spawns, so the PATH stubs can
    fire); every test asserts nothing was spawned at all.

The code under test is handed ONE RecordingRunner and ONE Config whose HTTP clients are
in-process fakes. The package is tools/p4_health, or $P4_HEALTH_UNDER_TEST's copy.
"""
import base64
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

LAB_PORTS = {8000, 8081} | set(range(30051, 30061)) | set(range(9091, 9101))
LAB_HOSTS = {"127.0.0.1", "::1", "localhost", "0.0.0.0", "::"}
ATTEMPTS = []
SPAWNS = []
_orig_connect = socket.socket.connect
_orig_connect_ex = socket.socket.connect_ex
_orig_create = socket.create_connection
_orig_popen_init = subprocess.Popen.__init__


def _lab(address):
    return (isinstance(address, tuple) and len(address) >= 2 and str(address[0]) in LAB_HOSTS
            and address[1] in LAB_PORTS)


def _connect(self, address):
    if _lab(address):
        ATTEMPTS.append(tuple(address[:2]))
        raise ConnectionRefusedError("hermetic test: lab port %r refused" % (address,))
    return _orig_connect(self, address)


def _connect_ex(self, address):
    if _lab(address):
        ATTEMPTS.append(tuple(address[:2]))
        return 111
    return _orig_connect_ex(self, address)


def _create(address, *a, **kw):
    if _lab(address):
        ATTEMPTS.append(tuple(address[:2]))
        raise ConnectionRefusedError("hermetic test: lab port %r refused" % (address,))
    return _orig_create(address, *a, **kw)


def _popen_init(self, *a, **kw):
    SPAWNS.append(a[0] if a else kw.get("args"))
    return _orig_popen_init(self, *a, **kw)


socket.socket.connect = _connect
socket.socket.connect_ex = _connect_ex
socket.create_connection = _create
subprocess.Popen.__init__ = _popen_init


class _GrpcStub(types.ModuleType):
    def __getattr__(self, name):
        raise RuntimeError("hermetic test: grpc.%s used" % name)


sys.modules["grpc"] = _GrpcStub("grpc")

from p4_health import lab_round as LR  # noqa: E402
from p4_health import observe as OB  # noqa: E402
from p4_health.cells import table as T  # noqa: E402
from p4_health.cells import verdict as V  # noqa: E402
from p4_health.collect import fabric as FB  # noqa: E402
from p4_health.collect import proxy as P  # noqa: E402
from p4_health.collect import ps as PS  # noqa: E402
from p4_health.collect import sniff as S  # noqa: E402
from p4_health.collect import tc as TC  # noqa: E402
from p4_health.collect import thrift as TH  # noqa: E402
from p4_health.collect.config import Config, HttpReply  # noqa: E402
from p4_health.collect.runner import RecordingRunner  # noqa: E402


def tearDownModule():
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
    """Every test: no tripwire, no lab port, no spawn."""

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
        detail = open(TRIPWIRE).read() if tripped else ""
        if tripped:
            os.remove(TRIPWIRE)
        self.assertFalse(tripped, "a fail-loud stub was run: %s" % detail)
        self.assertEqual(ATTEMPTS, [], "a lab port was dialled")
        self.assertEqual(SPAWNS, [], "a process was spawned")


# --- the seal checks itself ----------------------------------------------------------------------------

class TestTheSealHolds(Sealed):

    def test_a_lab_port_is_refused_and_recorded(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            with self.assertRaises(ConnectionRefusedError):
                s.connect(("127.0.0.1", 8081))
        finally:
            s.close()
        self.assertEqual(ATTEMPTS, [("127.0.0.1", 8081)])
        del ATTEMPTS[:]

    def test_the_stubs_are_first_on_path_and_trip(self):
        self.assertEqual(shutil.which("ndt"), os.path.join(STUBS, "ndt"))
        self.assertEqual(shutil.which("simple_switch_CLI"), os.path.join(STUBS, "simple_switch_CLI"))
        rc = subprocess.call(["ndt", "status"])
        self.assertEqual(rc, 99)
        self.assertTrue(os.path.exists(TRIPWIRE))
        os.remove(TRIPWIRE)
        del SPAWNS[:]

    def test_grpc_is_a_stub(self):
        import grpc
        with self.assertRaises(RuntimeError):
            grpc.insecure_channel("localhost:30051")


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
                    "mirroring_add 9 1", "pvs_add HcParser.vs_ports 1", "table_clear HcIngress.t_ap"):
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
        self.proxy.routes[("GET", "/p4/counter/HcIngress.c_in?dpid=1&index=0")] = (503, {"detail": "x"})
        self.assertEqual(P.counter(self.cfg, "HcIngress.c_in", 1), (503, None))
        self.proxy.routes[("GET", "/p4/counter/HcIngress.c_in?dpid=1&index=0")] = (200, {"packets": 0, "bytes": 0})
        self.assertEqual(P.counter(self.cfg, "HcIngress.c_in", 1), (200, 0))


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


# --- the lifecycle (M14, M17; section 12 items 10 and 12) ----------------------------------------------

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
        self.pkg = os.path.join(self.tmp, "pkgA")

    def runner(self, down_rc=0, release_rc=0, claim_rc=0, diff_rc=0,
               status="  measuring      nothing\n"):
        knob = self.host_knob

        def up(argv, env, inp):
            with open(knob, "wb") as fh:          # `ndt up p4 --app` rewrites the host knob
                fh.write(b"6\n")
            return (0, "up")
        r = RecordingRunner()
        r.add(("ndt", "status", "--measuring"), (0, status))
        r.add(("ndt", "claim"), (claim_rc, ""))
        r.add(("ndt", "up"), up)
        r.add(("ndt", "down"), (down_rc, ""))
        r.add(("ndt", "release"), (release_rc, ""))
        r.add(("qdisc_snapshot.sh", "save"), (0, "saved"))
        r.add(("qdisc_snapshot.sh", "diff"), (diff_rc, "" if diff_rc == 0 else "-qdisc htb\n"))
        r.add(("sudo", "-n", "tc"), (0, ""))
        r.add(("sudo", "-n", "mnexec", "-a", "1", "kill"), (0, ""))
        r.add(("kill",), (0, ""))
        return r

    def round(self, r, body=None, **kw):
        lr = LR.LabRound(self.cfg, r, "A", self.pkg, "run-x", pid=4242, install_signals=kw.pop("signals", False))

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
        with open(self.cfg.lab_state_path) as fh:
            st = json.load(fh)
        self.assertEqual((st["pid"], st["owner"], st["bring_up"], st["phase"]), (4242, "p4h-test", "A", "released"))
        self.assertEqual(st["netem"], ["s2-eth3"])
        self.assertEqual((st["sniffers"], st["controllers"]), ([555], [666]))
        self.assertEqual(base64.b64decode(st["knob_snapshot"]["host_count_override"]),
                         b"4  # uncommitted value, kept as bytes\n")
        self.assertIsNone(st["knob_snapshot"]["telemetry_override"])
        self.assertTrue(st["qdisc_before"].endswith("qdisc.A.before"))

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

    def test_the_qdisc_snapshot_is_taken_after_up(self):
        r = self.runner()
        self.round(r)
        names = self.names(r)
        self.assertLess(names.index("ndt up"), names.index("qdisc_snapshot.sh save"))
        self.assertLess(names.index("qdisc_snapshot.sh save"), names.index("tc add"))

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
                LR.LabRound(self.cfg, self.runner(), "A", self.pkg, "r").run(lambda lab: None)


class TestConfig(Sealed):

    def test_ndt_needs_an_owner(self):
        cfg = Config(run_dir=self.tmp, proxy=self.proxy, kernel=self.kernel)
        with self.assertRaises(ValueError):
            cfg.ndt_env()

    def test_the_knobs_are_the_two_and_not_the_override(self):
        self.assertEqual(sorted(self.cfg.knobs), ["host_count_override", "telemetry_override"])
        self.assertEqual(self.cfg.thrift_port(3), 9093)


if __name__ == "__main__":
    unittest.main()
