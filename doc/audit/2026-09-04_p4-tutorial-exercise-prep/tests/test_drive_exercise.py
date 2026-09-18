"""drive_exercise.py, driven offline: both fabrics, neither of them real.

[Co-developed with claude code -- Adam]

WHY THIS FILE EXISTS AND WHAT IT CAN SAY.  The driver's whole job is to start a
fabric and read what comes back, which is exactly what a test on this machine
must not do: TICKET-P2 section 0-2 forbids sudo, `ndt up`, Mininet and bmv2 here,
and live is the orchestrator's to run.  So every fabric is replaced -- the
process table, the host namespaces, `ndt`, convert.py and pre-flight are all
stubs -- and what is left is the part that is a decision rather than a reading:

  * the `--fabric tutorials` plan block and sudo line are what they printed on
    2026-09-08, byte for byte (fixtures/dryrun_*.txt, captured from trunk
    b392f111 BEFORE --fabric existed -- so they are the truth of "before", not a
    copy of what this file now prints);
  * a ping with no summary line is UNTESTED and never 0%;
  * a host with no namespace is a named failure and never a lost packet;
  * the ndtwin round takes the claim AFTER the pre-flight and gives it back in a
    `finally`, both halves, in _common.sh finish()'s order;
  * the two new exercises' red arms are red for the reason the exercise says,
    and are distinguishable from their green arms.

🔴 WHAT IT CANNOT SAY: nothing here has run a switch.  Every expectation about
what bmv2 does with firewall.p4 or link_monitor.p4 is 【源碼推導，未執行】 until
the orchestrator's live round, and these tests assert only that the driver ASKS
the question that way.

Run:  p4_proxy/venv/bin/python -m unittest discover \
          -s doc/audit/2026-09-04_p4-tutorial-exercise-prep/tests \
          -t doc/audit/2026-09-04_p4-tutorial-exercise-prep/tests
Env:  DRIVE_EXERCISE_UNDER_TEST=<path>   (the mutation gate points it at a copy)
"""
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
DEFAULT_DRIVER = os.path.join(os.path.dirname(HERE), "drive_exercise.py")
DRIVER_PATH = os.path.abspath(os.environ.get("DRIVE_EXERCISE_UNDER_TEST", DEFAULT_DRIVER))


def load_driver():
    """A fresh module object, so one test's monkeypatching cannot reach another."""
    spec = importlib.util.spec_from_file_location("drive_exercise_under_test", DRIVER_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def make_exercise_tree(root, exercise, topo_rel, prog, hosts, switches, links, extra=()):
    """A tutorials-shaped exercise directory: topology.json, the program, solution/."""
    exdir = os.path.join(root, "exercises", exercise)
    os.makedirs(os.path.join(exdir, "solution"), exist_ok=True)
    tp = os.path.join(exdir, topo_rel)
    os.makedirs(os.path.dirname(tp), exist_ok=True)
    with open(tp, "w") as f:
        json.dump({"hosts": {h: {"ip": "10.0.%d.%d/24" % (i + 1, i + 1)}
                             for i, h in enumerate(hosts)},
                   "switches": {s: {"runtime_json": "%s-runtime.json" % s} for s in switches},
                   "links": links}, f, indent=2)
    for name in (prog,) + tuple(extra):
        with open(os.path.join(exdir, name), "w") as f:
            f.write("// skeleton\n")
    with open(os.path.join(exdir, "solution", prog), "w") as f:
        f.write("// solution\n")
    return exdir


POD_LINKS = [["h1", "s1-p1"], ["h2", "s1-p2"], ["s1-p3", "s3-p1"], ["s1-p4", "s4-p2"],
             ["h3", "s2-p1"], ["h4", "s2-p2"], ["s2-p3", "s4-p1"], ["s2-p4", "s3-p2"]]
SR_LINKS = [["h1", "s1-p1"], ["h2", "s2-p1"], ["h3", "s3-p1"],
            ["s1-p2", "s2-p2"], ["s2-p3", "s3-p2"], ["s3-p3", "s1-p3"]]


def build_tut_root(root):
    make_exercise_tree(root, "basic", "pod-topo/topology.json", "basic.p4",
                       ["h1", "h2", "h3", "h4"], ["s1", "s2", "s3", "s4"], POD_LINKS)
    make_exercise_tree(root, "source_routing", "topology.json", "source_routing.p4",
                       ["h1", "h2", "h3"], ["s1", "s2", "s3"], SR_LINKS)
    make_exercise_tree(root, "firewall", "pod-topo/topology.json", "firewall.p4",
                       ["h1", "h2", "h3", "h4"], ["s1", "s2", "s3", "s4"], POD_LINKS,
                       extra=("basic.p4",))
    make_exercise_tree(root, "link_monitor", "pod-topo/topology.json", "link_monitor.p4",
                       ["h1", "h2", "h3", "h4"], ["s1", "s2", "s3", "s4"], POD_LINKS)
    return root


def stub_compile(mod):
    """p4c replaced: the compiler's identity is a live question, not this one."""
    def fake(exdir, src, base):
        info = {"cmd": "p4c (stubbed)", "rc": 0, "out": "", "warnings": 0,
                "json": os.path.join(exdir, "build", base + ".json"), "bytes": 1,
                "sha": "j" * 16,
                "p4info": os.path.join(exdir, "build", base + ".p4.p4info.txtpb"),
                "src": src}
        return 0, info["json"], info
    mod.compile_prog = fake
    return fake


def stub_preflight(mod, ok=True):
    mod.preflight = lambda *_a, **_k: (ok, [], {"switch_sha": "s" * 16, "switch_ver": "stub",
                                                "p4c_sha": "p" * 16, "p4c_ver": "stub"})


def render_main(mod, argv, tut_root):
    """main() with stdout captured and the Tee put back.  -> (rc, text)."""
    buf = io.StringIO()
    old_argv, old_out, old_err = sys.argv, sys.stdout, sys.stderr
    sys.argv = ["drive_exercise.py"] + list(argv)
    sys.stdout, sys.stderr = buf, buf
    try:
        rc = mod.main()
    finally:
        sys.argv, sys.stdout, sys.stderr = old_argv, old_out, old_err
    text = buf.getvalue()
    text = text.replace(os.path.join(tut_root, "exercises", "basic"), "<EXDIR>")
    text = text.replace(os.path.join(tut_root, "exercises", "source_routing"), "<EXDIR>")
    text = text.replace(os.path.join(tut_root, "exercises", "firewall"), "<EXDIR>")
    text = text.replace(os.path.join(tut_root, "exercises", "link_monitor"), "<EXDIR>")
    text = text.replace(tut_root, "<TUT>").replace(DRIVER_PATH, "<DRIVER>")
    return rc, text


# --------------------------------------------------------------- fake fabric --


class FakeProc(object):
    """A process handle the steps can hold: it never forks anything."""

    def __init__(self, out=b"", fh=None):
        self.out, self.fh = out, fh
        self.terminated = self.killed = False
        if fh is not None:
            fh.write(out)
            fh.flush()

    def communicate(self, input=None, timeout=None):
        return (self.out if self.fh is None else b""), None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        return 0


class StubHosts(object):
    """A HostRunner the steps cannot tell from a fabric, and that moves no packet.

    `pingall` is answered from a table rather than by the real parser, because
    what the step tests want to say is "this arm asserts X about the loss", and
    the parser itself has its own cells above.
    """

    def __init__(self, ips, popen_texts=None, cmd_texts=None, pa=None):
        self.ips = dict(ips)
        self.popen_texts = popen_texts or {}
        self.cmd_texts = cmd_texts or {}
        self.pa = pa
        self.popened = []
        self.cmds = []

    def names(self):
        return sorted(self.ips)

    def describe(self):
        return "stub hosts"

    def popen(self, host, argv, **kw):
        self.popened.append((host, list(argv)))
        text = b""
        for key, val in self.popen_texts.items():
            if key in " ".join(argv):
                text = val if isinstance(val, bytes) else val.encode()
        return FakeProc(text, kw.get("stdout") if hasattr(kw.get("stdout"), "write") else None)

    def cmd(self, host, line):
        self.cmds.append((host, line))
        for key, val in self.cmd_texts.items():
            if key in line:
                return val
        return ""

    def pingall(self, count=5):
        return self.pa


def zero_loss(mod, pairs=12):
    pa = mod.PingAll()
    pa.pairs = pa.zero = pairs
    pa.sent = pa.received = 5 * pairs
    return pa


def total_loss(mod, pairs=12):
    pa = mod.PingAll()
    pa.pairs = pa.lossy = pairs
    pa.sent = 5 * pairs
    pa.received = 0
    return pa


class Args(object):
    recv_warmup = 0.0
    drain_wait = 0.0
    fabric = "ndtwin"
    which = "solution"
    dry_run = False


def quiet(mod):
    """The driver narrates to stdout; a gate's output is easier to read without it.

    Only the printer is silenced -- every assertion below is on the objects the
    steps build, not on what they narrated, and the cells that ARE about printed
    text (the plan block) capture stdout instead.
    """
    mod.say = lambda *_a, **_k: None


def steps_for(mod, exercise, which, hosts, tmp):
    mod.IPERF_WARMUP = 0.0
    mod.PROBE_SECONDS = 0.0
    args = Args()
    args.which = which
    return mod.Steps(hosts, exercise, which, tmp, tmp, args, ips=hosts.ips)


def verdict(session):
    return {e.name: e for e in session.expects}


# ================================================================= the cells ==


class PlanBlockIsFrozen(unittest.TestCase):
    """🔴 The 09-08 control: same command, same plan, same sudo line."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="drv-plan-")
        self.mod = load_driver()
        self.mod.TUT = build_tut_root(self.tmp)
        self.mod.UTILS = os.path.join(self.tmp, "utils")
        stub_preflight(self.mod)
        stub_compile(self.mod)

    def test_the_tutorials_plan_and_sudo_line_are_what_they_printed_on_09_08(self):
        for ex, which in (("basic", "solution"), ("basic", "skeleton"),
                          ("source_routing", "solution"), ("source_routing", "skeleton")):
            with self.subTest(exercise=ex, which=which):
                rc, text = render_main(self.mod, [ex, "--which", which, "--dry-run"], self.mod.TUT)
                want = open(os.path.join(FIXTURES, "dryrun_%s_%s.txt" % (ex, which))).read()
                self.assertEqual(0, rc)
                self.assertEqual(want, text)

    def test_the_default_fabric_is_tutorials(self):
        rc, text = render_main(self.mod, ["basic", "--dry-run"], self.mod.TUT)
        self.assertEqual(0, rc)
        self.assertIn("sudo /home/adam/p4dev-python-venv/bin/python", text)
        self.assertNotIn("--fabric ndtwin", text)

    def test_the_ndtwin_plan_names_the_ndt_commands_and_asks_for_no_sudo(self):
        rc, text = render_main(self.mod,
                               ["basic", "--which", "solution", "--fabric", "ndtwin",
                                "--dry-run"], self.mod.TUT)
        self.assertEqual(0, rc)
        self.assertIn("convert.py", text)
        self.assertIn("up p4 --app", text)
        self.assertIn("--fabric ndtwin", text)
        run_line = [l for l in text.splitlines() if l.strip().endswith("--fabric ndtwin")]
        self.assertTrue(run_line, text)
        self.assertNotIn("sudo", run_line[0])


class TheLossNumber(unittest.TestCase):
    """A rate, parsed out of ping's own summary line, or nothing."""

    def setUp(self):
        self.mod = load_driver()

    def runner(self, replies):
        mod = self.mod

        class R(mod.HostRunner):
            def __init__(self):
                mod.HostRunner.__init__(self, {"h1": "10.0.1.1", "h2": "10.0.2.2"})
                self.lines = []

            def cmd(self, host, line):
                self.lines.append((host, line))
                return replies

        return R()

    def test_a_ping_with_no_summary_line_is_untested_and_not_zero_loss(self):
        r = self.runner("ping: connect: Network is unreachable\n")
        res = r.ping("h1", "10.0.2.2")
        self.assertIsNone(res.loss)
        self.assertFalse(res.tested)
        self.assertIn("no '% packet loss' summary", res.label())

    def test_the_loss_comes_from_the_summary_line(self):
        r = self.runner("5 packets transmitted, 4 received, 20% packet loss, time 4005ms\n")
        res = r.ping("h1", "10.0.2.2")
        self.assertEqual(20.0, res.loss)
        self.assertEqual(4, res.received)
        self.assertEqual(5, res.transmitted)

    def test_pingall_sends_five_packets_on_every_ordered_pair(self):
        r = self.runner("5 packets transmitted, 5 received, 0% packet loss, time 4005ms\n")
        pa = r.pingall(count=5)
        self.assertEqual(2, pa.pairs)                     # h1->h2 and h2->h1
        self.assertEqual(0, pa.loss)
        self.assertTrue(all("ping -c 5 -W 2" in line for _, line in r.lines), r.lines)

    def test_an_untested_pair_makes_the_pingall_number_none_rather_than_zero(self):
        r = self.runner("ping: socket: Operation not permitted\n")
        pa = r.pingall(count=5)
        self.assertEqual(2, pa.untested)
        self.assertIsNone(pa.loss)
        self.assertIn("UNTESTED", pa.label())

    def test_one_untested_pair_voids_the_number_even_when_the_others_were_clean(self):
        """🔴 The mixed case, and the only one that can see the difference.

        With every pair untested nothing was sent, so "no packets lost" is
        vacuously true whichever way the total is computed.  A fabric where ONE
        direction could not be tested and the rest were clean is the reading that
        would otherwise be published as 0% -- an untested pair is not a passed one
        (live-p1/_common.sh's pingall_loss carries the same rule).
        """
        mod = self.mod
        replies = {"10.0.2.2": "5 packets transmitted, 5 received, 0% packet loss\n",
                   "10.0.1.1": "ping: socket: Operation not permitted\n"}

        class R(mod.HostRunner):
            def cmd(self, host, line):
                return next(v for k, v in replies.items() if k in line)

        pa = R({"h1": "10.0.1.1", "h2": "10.0.2.2"}).pingall(count=5)
        self.assertEqual(1, pa.untested)
        self.assertEqual(1, pa.zero)
        self.assertIsNone(pa.loss)


class TheNdtwinNamespace(unittest.TestCase):
    """`sudo -n mnexec -a <pid>`, and the pid is `ndt`'s own rule."""

    def setUp(self):
        self.mod = load_driver()
        self.ps = ("  101 /usr/bin/python3 /home/adam/tutorials/utils/run_exercise.py mininet:h9\n"
                   "  222 bash -c echo mininet:h1 is not a host\n"
                   "  333 mnexec bash --norc -is mininet:h1\n"
                   "  444 mnexec bash --norc -is mininet:h2\n")
        self.calls = []

        def runner(cmd, cwd=None, timeout=None, env=None):
            self.calls.append(list(cmd))
            if cmd[:2] == ["ps", "-eo"]:
                return 0, self.ps
            return 0, "5 packets transmitted, 5 received, 0% packet loss\n"

        self.hosts = self.mod.NdtwinHosts({"h1": "10.0.1.1", "h2": "10.0.2.2"},
                                          cwd="/tmp", runner=runner)

    def test_the_pid_is_the_tail_field_of_the_process_table(self):
        self.assertEqual("333", self.hosts.host_pid("h1"))
        self.assertEqual("444", self.hosts.host_pid("h2"))

    def test_a_host_with_no_namespace_is_a_named_failure_and_not_zero_loss(self):
        with self.assertRaises(self.mod.HostNotFound) as cm:
            self.hosts.host_pid("h3")
        self.assertIn("h3", str(cm.exception))
        res = self.hosts.ping("h3", "10.0.3.3")
        self.assertIsNone(res.loss)
        self.assertIn("no namespace", res.label())

    def test_a_command_enters_the_namespace_through_sudo_mnexec(self):
        self.hosts.cmd("h1", "LANG=C ping -c 5 -W 2 10.0.2.2")
        self.assertIn(["sudo", "-n", "mnexec", "-a", "333", "sh", "-c",
                       "LANG=C ping -c 5 -W 2 10.0.2.2"], self.calls)


class TheNdtwinRound(unittest.TestCase):
    """convert -> pre-flight -> claim -> up -> steps -> down -> release."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="drv-ndtwin-")
        self.mod = load_driver()
        quiet(self.mod)
        self.mod.PKG_ROOT = os.path.join(self.tmp, "packages")
        self.mod.NDT = "/fake/ndt"
        self.mod.PROXY_PY = "/fake/python"
        self.mod.CONVERT = "/fake/convert.py"
        self.mod.PREFLIGHT = "/fake/preflight.py"
        self.mod.switch_state = lambda *_a, **_k: {"switches": {}}
        self.calls = []
        self.envs = []
        self.rcs = {}
        mod = self.mod

        def runner(cmd, cwd=None, timeout=None, env=None):
            self.calls.append(list(cmd))
            self.envs.append(env)
            for key, rc in self.rcs.items():
                if key in " ".join(cmd):
                    return rc, "stub rc=%d" % rc
            return 0, "stub ok"
        mod.run = runner

        class NoSteps(object):
            raises = None

            def __init__(self, *a, **kw):
                self.expects, self.steps = [], []

            def run(self):
                if NoSteps.raises:
                    raise NoSteps.raises
        self.NoSteps = NoSteps
        mod.Steps = NoSteps
        mod.NdtwinHosts = lambda *a, **kw: StubHosts({"h1": "10.0.1.1"})
        self.spec = mod.EXERCISES["basic"]
        self.args = Args()

    def go(self, ex="basic", which="solution"):
        steps = []
        return self.mod.run_on_ndtwin(ex, which, "/ex", self.mod.EXERCISES[ex], self.args,
                                      {"h1": "10.0.1.1"}, self.tmp, steps)

    def verbs(self):
        return [c for c in self.calls if c and c[0] == self.mod.NDT]

    def test_the_round_runs_convert_preflight_claim_up_down_release_in_order(self):
        self.go()
        order = []
        for c in self.calls:
            joined = " ".join(c)
            if self.mod.CONVERT in joined:
                order.append("convert")
            elif self.mod.PREFLIGHT in joined:
                order.append("preflight")
            elif c and c[0] == self.mod.NDT:
                order.append(c[1])
        self.assertEqual(["convert", "preflight", "claim", "up", "down", "release"], order)

    def test_convert_is_given_the_default_prog_and_not_the_variant(self):
        self.go(ex="firewall")
        conv = [c for c in self.calls if "/fake/convert.py" in c][0]
        self.assertIn("--p4", conv)
        self.assertEqual("basic.p4", conv[conv.index("--p4") + 1])
        self.assertIn("pod-topo/topology.json", conv)

    def test_the_teardown_runs_both_halves_even_when_the_steps_raise(self):
        self.NoSteps.raises = RuntimeError("the step blew up")
        try:
            with self.assertRaises(RuntimeError):
                self.go()
        finally:
            self.NoSteps.raises = None
        tail = [" ".join(c[1:2]) for c in self.verbs()]
        self.assertEqual(["claim", "up", "down", "release"], tail)

    def test_a_refused_preflight_never_takes_the_claim(self):
        self.rcs["preflight.py"] = 1
        rc, pkg, state = self.go()
        self.assertEqual(2, rc)
        self.assertEqual([], self.verbs())

    def test_every_ndt_call_carries_the_owner(self):
        self.go()
        for cmd, env in zip(self.calls, self.envs):
            if cmd and cmd[0] == self.mod.NDT:
                self.assertEqual(self.mod.NDT_OWNER, (env or {}).get("NDT_OWNER"), cmd)


class TheCompanionProgram(unittest.TestCase):
    """exercises/firewall's s2-s4 run DEFAULT_PROG, and it has to be built."""

    def setUp(self):
        self.mod = load_driver()
        self.tmp = tempfile.mkdtemp(prefix="drv-compile-")
        build_tut_root(self.tmp)

    def test_firewall_builds_its_own_program_and_the_default_one(self):
        exdir = os.path.join(self.tmp, "exercises", "firewall")
        got = self.mod.companion_programs(exdir, self.mod.EXERCISES["firewall"], "solution")
        self.assertEqual([(os.path.join(exdir, "basic.p4"), "basic")], got)

    def test_an_exercise_whose_default_is_its_own_program_has_no_companion(self):
        for ex in ("basic", "source_routing", "link_monitor"):
            with self.subTest(exercise=ex):
                exdir = os.path.join(self.tmp, "exercises", ex)
                self.assertEqual([], self.mod.companion_programs(
                    exdir, self.mod.EXERCISES[ex], "solution"))

    def test_the_tutorials_harness_is_handed_the_default_programs_json(self):
        """-j is DEFAULT_PROG's json; the variant reaches s1 through `program`."""
        stub_preflight(self.mod)
        stub_compile(self.mod)
        self.mod.TUT = self.tmp
        rc, text = render_main(self.mod, ["firewall", "--which", "solution", "--dry-run"],
                               self.tmp)
        self.assertEqual(0, rc)
        self.assertIn("-j build/basic.json", text)
        self.assertIn("program  : <EXDIR>/solution/firewall.p4 -> build/firewall.json", text)


class TheFirewallArms(unittest.TestCase):
    """README step 1.2 and solution:211-218, as two arms of one script."""

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-fw-")
        self.ips = {"h1": "10.0.1.1", "h2": "10.0.2.2", "h3": "10.0.3.3", "h4": "10.0.4.4"}

    def session(self, which, transfers):
        hosts = StubHosts(self.ips, popen_texts={"iperf -c": transfers},
                          pa=zero_loss(self.mod))
        s = steps_for(self.mod, "firewall", which, hosts, self.tmp)
        s.run()
        return s

    OK = "[  3]  0.0- 3.0 sec  1.50 GBytes  4.29 Gbits/sec\n"

    def test_the_skeleton_arm_is_red_when_the_external_flow_is_blocked(self):
        s = self.session("skeleton", "connect failed: No route to host\n")
        e = verdict(s)["RED ARM: iperf h3 -> h1 must connect"]
        self.assertFalse(e.ok)
        self.assertIn("the red arm is not red", e.note)

    def test_the_skeleton_arm_passes_when_the_external_flow_gets_through(self):
        s = self.session("skeleton", self.OK)
        self.assertTrue(verdict(s)["RED ARM: iperf h3 -> h1 must connect"].ok)

    def test_the_solution_arm_wants_the_external_flow_blocked(self):
        blocked = self.session("solution", "connect failed: No route to host\n")
        self.assertTrue(verdict(blocked)["iperf h3 -> h1 is blocked"].ok)
        through = self.session("solution", self.OK)
        self.assertFalse(verdict(through)["iperf h3 -> h1 is blocked"].ok)

    def test_both_arms_require_the_internal_to_external_flow(self):
        for which in ("skeleton", "solution"):
            with self.subTest(which=which):
                s = self.session(which, self.OK)
                self.assertTrue(verdict(s)["iperf h1 -> h3 (internal -> external)"].ok)


class TheLinkMonitorArms(unittest.TestCase):
    """The discriminator is the PORT field, not the switch id."""

    SOLUTION = "\n".join("Switch %d - Port %d: 1.5 Mbps" % (s, p)
                         for s, p in ((1, 4), (4, 1), (2, 4), (3, 1))) + "\n"
    SKELETON = "\n".join("Switch %d - Port 0: 0 Mbps" % s for s in (1, 4, 2, 3)) + "\n"

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-lm-")
        self.ips = {"h1": "10.0.1.1", "h2": "10.0.2.2", "h3": "10.0.3.3", "h4": "10.0.4.4"}

    def session(self, which, received):
        hosts = StubHosts(self.ips, popen_texts={"receive.py": received})
        s = steps_for(self.mod, "link_monitor", which, hosts, self.tmp)
        s.run()
        return s

    def test_the_skeleton_arm_expects_every_reported_port_to_be_zero(self):
        s = self.session("skeleton", self.SKELETON)
        v = verdict(s)
        self.assertTrue(v["every reported port is 0"].ok)
        self.assertTrue(v["switch ids seen"].ok)
        self.assertTrue(v["injection: probes reached h1"].ok)

    def test_the_two_arms_are_distinguishable(self):
        """The solution's output must FAIL the skeleton's port check, and vice versa."""
        self.assertFalse(verdict(self.session("skeleton", self.SOLUTION))
                         ["every reported port is 0"].ok)
        self.assertFalse(verdict(self.session("solution", self.SKELETON))
                         ["every reported port is non-zero"].ok)

    def test_the_solution_arm_wants_all_four_switch_ids_and_no_zero_port(self):
        v = verdict(self.session("solution", self.SOLUTION))
        self.assertTrue(v["switch ids seen"].ok)
        self.assertTrue(v["every reported port is non-zero"].ok)

    def test_no_probe_rows_fails_the_injection_check_rather_than_passing_vacuously(self):
        for which in ("skeleton", "solution"):
            with self.subTest(which=which):
                v = verdict(self.session(which, "sniffing on eth0\n"))
                self.assertFalse(v["injection: probes reached h1"].ok)
                self.assertFalse(v["switch ids seen"].ok)


class TheLabRefusal(unittest.TestCase):
    """The ndtwin pre-flight asks `require_free_lab`'s two questions."""

    def setUp(self):
        self.mod = load_driver()

    def test_a_live_claim_of_somebody_elses_refuses(self):
        ok, why = self.mod.lab_is_free({"owner": "someone-else",
                                        "expires": str(2 ** 31), "measuring": ""})
        self.assertFalse(ok)
        self.assertIn("someone-else", why)

    def test_our_own_claim_that_declares_a_measurement_refuses_too(self):
        ok, why = self.mod.lab_is_free({"owner": self.mod.NDT_OWNER,
                                        "expires": str(2 ** 31), "measuring": "F5 round 3"})
        self.assertFalse(ok)
        self.assertIn("F5 round 3", why)

    def test_an_expired_claim_is_not_a_claim(self):
        ok, why = self.mod.lab_is_free({"owner": "someone-else", "expires": "1",
                                        "measuring": "old"})
        self.assertTrue(ok)


class TheReport(unittest.TestCase):
    """What the raw has to carry (TICKET-P2 section 5.6)."""

    def setUp(self):
        self.mod = load_driver()
        self.tmp = tempfile.mkdtemp(prefix="drv-report-")

    def state(self):
        return {"control_plane": {"mode": "ndtwin", "package": "/pkg",
                                  "skipped": ["lldp_discovery"]},
                "switches": {"1": {"pipeline": {"ndtwin": False, "p4info_sha256": "abc123"},
                                   "table_entries": {"recorded": 5, "applied": 5, "failed": 0,
                                                     "api_writes": 0},
                                   "entries_recorded": 5}}}

    def test_the_summary_names_the_pipeline_sha_and_the_entry_counts(self):
        lines = "\n".join(self.mod.switch_state_summary(self.state()))
        self.assertIn("p4info_sha256=abc123", lines)
        self.assertIn("applied=5", lines)
        self.assertIn("ndtwin=False", lines)

    def test_an_unreadable_switch_state_says_so_instead_of_printing_zeros(self):
        lines = "\n".join(self.mod.switch_state_summary({"error": "URLError"}))
        self.assertIn("UNREADABLE", lines)
        self.assertNotIn("applied=", lines)

    def test_the_report_header_carries_the_fabric_and_the_package(self):
        path = os.path.join(self.tmp, "r.md")
        self.mod.write_report(path, {
            "utc": "now", "exercise": "basic", "which": "solution", "exdir": "/ex",
            "fabric": "ndtwin", "package": "/pkg", "switch_state": self.state(),
            "env": {"switch_sha": "-", "switch_ver": "-", "p4c_sha": "-", "p4c_ver": "-"},
            "compile": {"cmd": "p4c", "rc": 0, "out": "", "warnings": 0},
            "compile_extra": [], "topo_summary": "topology : x", "steps": [],
            "expects": [], "artifacts": [], "notes": [], "verdict": "PASS", "exit": 0,
            "stdout": "", "stderr": ""})
        with open(path) as f:
            text = f.read()
        self.assertIn("| fabric | `ndtwin` |", text)
        self.assertIn("| package | `/pkg` |", text)
        self.assertIn("p4info_sha256=abc123", text)


if __name__ == "__main__":                      # pragma: no cover
    unittest.main()
