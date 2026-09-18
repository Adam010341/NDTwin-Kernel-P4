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
    # TICKET-P3 §2.7's other nine, at the shapes their own Makefiles and topologies declare.
    # Only what the driver READS out of a tree is reproduced: the topology the Makefile names,
    # the program the wildcard finds, and solution/.
    make_exercise_tree(root, "basic_tunnel", "topology.json", "basic_tunnel.p4",
                       ["h1", "h2", "h3"], ["s1", "s2", "s3"], SR_LINKS)
    make_exercise_tree(root, "calc", "topology.json", "calc.p4",
                       ["h1", "h2"], ["s1"], [["h1", "s1-p1"], ["h2", "s1-p2"]])
    for ex in ("ecn", "mri", "qos"):
        make_exercise_tree(root, ex, "topology.json", "%s.p4" % ex,
                           ["h1", "h11", "h2", "h22", "h3"], ["s1", "s2", "s3"], SR_LINKS)
    make_exercise_tree(root, "flowcache", "topology.json", "flowcache.p4",
                       ["h1", "h2", "h3"], ["s1", "s2", "s3"], SR_LINKS)
    make_exercise_tree(root, "load_balance", "topology.json", "load_balance.p4",
                       ["h1", "h2", "h3"], ["s1", "s2", "s3"], SR_LINKS)
    # 🔴 multicast is the one whose Makefile moves TOPO (Makefile:5 -> sig-topo/topology.json).
    make_exercise_tree(root, "multicast", "sig-topo/topology.json", "multicast.p4",
                       ["h1", "h2", "h3", "h4"], ["s1"],
                       [["h1", "s1-p1"], ["h2", "s1-p2"], ["h3", "s1-p3"], ["h4", "s1-p4"]])
    make_exercise_tree(root, "p4runtime", "topology.json", "advanced_tunnel.p4",
                       ["h1", "h2", "h3"], ["s1", "s2", "s3"], SR_LINKS)
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
    """A process handle the steps can hold: it never forks anything.

    `timeout_first` reproduces the one case that has no other way in: a client that never
    connected sits in SYN retries, the first communicate(timeout=...) raises, the caller kills
    it, and the SECOND communicate returns whatever it had printed by then.
    """

    def __init__(self, out=b"", fh=None, timeout_first=False):
        self.out, self.fh = out, fh
        self.fed = None
        self.terminated = self.killed = False
        self.timeout_first, self._timed_out = timeout_first, False
        if fh is not None:
            fh.write(out)
            fh.flush()

    def communicate(self, input=None, timeout=None):
        self.fed = input
        if self.timeout_first and not self._timed_out:
            self._timed_out = True
            raise subprocess.TimeoutExpired("stub", timeout or 0)
        return (self.out if self.fh is None else b""), None

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        return 0

    def poll(self):
        """Alive until somebody stops it -- the controller arm's `alive` reading."""
        return None if not (self.terminated or self.killed) else 0


class StubHosts(object):
    """A HostRunner the steps cannot tell from a fabric, and that moves no packet.

    `pingall` is answered from a table rather than by the real parser, because
    what the step tests want to say is "this arm asserts X about the loss", and
    the parser itself has its own cells above.
    """

    def __init__(self, ips, popen_texts=None, cmd_texts=None, pa=None, popen_timeouts=(),
                 pings=None):
        self.ips = dict(ips)
        self.popen_texts = popen_texts or {}
        self.cmd_texts = cmd_texts or {}
        self.pa = pa
        self.popen_timeouts = tuple(popen_timeouts)
        #: (host, dst) -> PingResult, for the two exercises whose acceptance is a single ping
        #: with the exercise's own controller running rather than a pingall.
        self.pings = dict(pings or {})
        self.popened = []
        self.cmds = []
        self.procs = []

    def names(self):
        return sorted(self.ips)

    def ping(self, host, dst, count=5):
        return self.pings[(host, dst)]

    def describe(self):
        return "stub hosts"

    def popen(self, host, argv, **kw):
        self.popened.append((host, list(argv)))
        text = b""
        for key, val in self.popen_texts.items():
            if key in " ".join(argv):
                text = val if isinstance(val, bytes) else val.encode()
        p = FakeProc(text, kw.get("stdout") if hasattr(kw.get("stdout"), "write") else None,
                     timeout_first=any(k in " ".join(argv) for k in self.popen_timeouts))
        self.procs.append((host, list(argv), p))
        return p

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


def steps_for(mod, exercise, which, hosts, tmp, fabric="tutorials", package=None):
    mod.IPERF_WARMUP = 0.0
    mod.PROBE_SECONDS = 0.0
    # The nine new exercises' own waits. Zeroed for the same reason PROBE_SECONDS is: what
    # these cells are about is the decision, and a suite that slept through every sender's
    # duration would take minutes to say it.
    mod.SEND_SECONDS = 0
    mod.BG_SECONDS = 0
    mod.CTRL_SETTLE = 0
    args = Args()
    args.which = which
    return mod.Steps(hosts, exercise, which, tmp, tmp, args, ips=hosts.ips,
                     fabric=fabric, package=package)


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


class TheRootRefusal(unittest.TestCase):
    """🔴 The NDTwin fabric is refused to root, and refused BEFORE anything is written."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="drv-root-")
        self.mod = load_driver()
        self.mod.TUT = build_tut_root(self.tmp)
        self.mod.UTILS = os.path.join(self.tmp, "utils")
        stub_preflight(self.mod)
        self.compiled = []
        real = stub_compile(self.mod)

        def counting(exdir, src, base):
            self.compiled.append(src)
            return real(exdir, src, base)
        self.mod.compile_prog = counting

    def test_ndtwin_mode_refuses_to_run_as_root_and_says_why(self):
        self.mod.euid = lambda: 0
        rc, text = render_main(self.mod, ["basic", "--fabric", "ndtwin"], self.mod.TUT)
        self.assertEqual(2, rc)
        self.assertIn("must NOT be run as root", text)
        self.assertIn("root-owned files", text)
        self.assertEqual([], self.compiled, "the refusal comes before anything is written")

    def test_the_tutorials_fabric_still_requires_root(self):
        """The opposite refusal, unchanged: Mininet needs namespaces and veth pairs."""
        self.mod.euid = lambda: 1000
        rc, text = render_main(self.mod, ["basic"], self.mod.TUT)
        self.assertEqual(2, rc)
        self.assertIn("needs root", text)


class TheRecordedSource(unittest.TestCase):
    """`--p4` decides the pipeline by its STEM and the package's `source.p4` by its PATH."""

    def setUp(self):
        self.mod = load_driver()
        self.tmp = tempfile.mkdtemp(prefix="drv-src-")
        build_tut_root(self.tmp)

    def exdir(self, ex):
        return os.path.join(self.tmp, "exercises", ex)

    def test_a_solution_run_names_the_solution_file_it_compiled(self):
        self.assertEqual("solution/basic.p4", self.mod.convert_p4_arg(
            self.exdir("basic"), self.mod.EXERCISES["basic"], "solution"))

    def test_a_skeleton_run_names_the_skeleton(self):
        self.assertEqual("basic.p4", self.mod.convert_p4_arg(
            self.exdir("basic"), self.mod.EXERCISES["basic"], "skeleton"))

    def test_firewall_keeps_the_default_prog_because_that_is_the_file_that_was_built(self):
        """solution/ holds firewall.p4 and nothing else; DEFAULT_PROG is basic.p4, and the
        skeleton copy is the only basic.p4 there is."""
        for which in ("solution", "skeleton"):
            with self.subTest(which=which):
                self.assertEqual("basic.p4", self.mod.convert_p4_arg(
                    self.exdir("firewall"), self.mod.EXERCISES["firewall"], which))


class TheBmv2Identity(unittest.TestCase):
    """Which binary the fabric ran, by sha -- `--version` cannot tell the two builds apart."""

    def setUp(self):
        self.mod = load_driver()
        self.tmp = tempfile.mkdtemp(prefix="drv-bmv2-")

    def test_a_path_in_the_status_row_is_hashed(self):
        binary = os.path.join(self.tmp, "simple_switch_grpc")
        with open(binary, "wb") as f:
            f.write(b"bytes\n")
        sha, label = self.mod.bmv2_identity("  bmv2           %s\n" % binary)
        self.assertEqual(self.mod.sha16(binary), sha)
        self.assertIn(binary, label)

    def test_a_status_with_no_bmv2_row_is_UNREADABLE_and_says_so(self):
        sha, label = self.mod.bmv2_identity("  sample rate    1/256\n")
        self.assertIn("UNREADABLE", label)
        self.assertIn("no bmv2 row", label)

    def test_a_row_naming_a_binary_that_is_not_there_is_UNREADABLE(self):
        sha, label = self.mod.bmv2_identity("  bmv2           /nowhere/simple_switch_grpc\n")
        self.assertIn("UNREADABLE", label)
        self.assertIn("/nowhere/simple_switch_grpc", label)


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
        # 🔴 AND THE DECIMAL FORM, which is what ping prints for most of the fractions that
        # matter: 3 of 6 lost is `33.3333%`. A parser that reads only the integer part finds
        # nothing here and reports UNTESTED for a ping that ran -- or, one mutation away,
        # reports the fabric as clean.
        r = self.runner("6 packets transmitted, 4 received, 33.3333% packet loss, time 5007ms\n")
        res = r.ping("h1", "10.0.2.2")
        self.assertAlmostEqual(33.3333, res.loss, places=4)
        self.assertEqual(4, res.received)

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
        # 🔴 THE KNOB IS A FIXTURE FILE. `ndt up p4 --app` writes the model's host count into
        # p4_proxy/mininet/host_count_override for real, and a test that let the driver touch
        # this checkout's copy would be a test that breaks the next `ndt up p4` in this tree.
        self.knob = os.path.join(self.tmp, "host_count_override")
        self.mod.HOST_KNOB = self.knob
        self.status_text = "  bmv2           simple_switch_grpc (stub)\n"
        self.calls = []
        self.envs = []
        self.knob_at = []          # (verb, what the knob held when that verb ran)
        self.rcs = {}
        mod = self.mod

        def runner(cmd, cwd=None, timeout=None, env=None):
            self.calls.append(list(cmd))
            self.envs.append(env)
            joined = " ".join(cmd)
            if cmd and cmd[0] == mod.NDT:
                self.knob_at.append((cmd[1], self.knob_bytes()))
            # what `ndt up p4 --app` really does to the knob: the MODEL's host count.
            if "up p4 --app" in joined:
                with open(self.knob, "wb") as f:
                    f.write(b"3\n")
            for key, rc in self.rcs.items():
                if key in joined:
                    return rc, "stub rc=%d" % rc
            if "status" in joined:
                return 0, self.status_text
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

    def knob_bytes(self):
        try:
            with open(self.knob, "rb") as f:
                return f.read()
        except OSError:
            return None

    def go(self, ex="basic", which="solution", env=None):
        steps = []
        self.steps_out = steps
        return self.mod.run_on_ndtwin(ex, which, "/ex", self.mod.EXERCISES[ex], self.args,
                                      {"h1": "10.0.1.1"}, self.tmp, steps, env)

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
        self.assertEqual(["convert", "preflight", "claim", "up", "status", "down", "release"],
                         order)

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
        self.assertEqual(["claim", "up", "status", "down", "release"], tail)

    def test_a_refused_preflight_never_takes_the_claim(self):
        self.rcs["preflight.py"] = 1
        rc, pkg, state = self.go()
        self.assertEqual(2, rc)
        self.assertEqual([], self.verbs())

    # --- the knob, and the lab coming back -----------------------------------------------

    def test_the_host_knob_is_put_back_between_the_down_and_the_release(self):
        """🔴 The order is what makes the release take, so the order is the assertion.

        `ndt release` refuses while the P4 host knob differs from what the round started at
        (ndt:885-898). A restore after the release is a restore that happened too late, and a
        restore before the teardown would put it back under a fabric that is still running --
        so the knob is read at every `ndt` verb and the two readings are compared.
        """
        with open(self.knob, "wb") as f:
            f.write(b"4\n")
        rc, pkg, state = self.go()
        self.assertEqual(0, rc)
        at = dict(self.knob_at)
        self.assertEqual(b"3\n", at["down"], "the fabric's own value must still be there")
        self.assertEqual(b"4\n", at["release"], "the release must see what the round started at")
        self.assertEqual(b"4\n", self.knob_bytes())

    def test_the_knob_is_put_back_as_bytes_and_not_as_the_number(self):
        """host_count_in skips comments, so `4` and `# mine\n4\n` are the same READING and
        not the same FILE. Writing the number back would rewrite somebody's annotated file and
        call it a restore (live-p1/_common.sh:119-131)."""
        original = b"# 4 hosts: the round I was in the middle of\n4\n"
        with open(self.knob, "wb") as f:
            f.write(original)
        self.go()
        self.assertEqual(original, self.knob_bytes())

    def test_a_knob_this_round_created_is_removed_again(self):
        self.assertIsNone(self.knob_bytes())
        self.go()
        self.assertIsNone(self.knob_bytes(), "the round created it; it must not outlive it")

    def test_a_release_that_would_not_take_fails_the_run_and_says_the_lab_is_claimed(self):
        self.rcs["release"] = 1
        rc, pkg, state = self.go()
        self.assertNotEqual(0, rc, "a round that did not give the lab back did not pass")
        self.assertIn("release", self.mod.run_on_ndtwin.teardown_problem)
        self.assertIn("STILL CLAIMED", self.mod.run_on_ndtwin.teardown_problem)

    def test_a_knob_that_could_not_be_put_back_is_reported_rather_than_passed_over(self):
        with open(self.knob, "wb") as f:
            f.write(b"4\n")
        self.mod.knob_restore = lambda *_a, **_k: (False, "could NOT put the knob back: stub")
        rc, pkg, state = self.go()
        self.assertNotEqual(0, rc)
        self.assertIn("could NOT put the knob back", self.mod.run_on_ndtwin.teardown_problem)

    def test_the_verdict_says_the_lab_was_not_returned(self):
        v, rc = self.mod.final_verdict("PASS (4/4)", 0, "`ndt release` exited 1 -- THE LAB IS STILL CLAIMED")
        self.assertIn("LAB NOT RETURNED", v)
        self.assertEqual(1, rc)
        v, rc = self.mod.final_verdict("PASS (4/4)", 0, "")
        self.assertEqual(("PASS (4/4)", 0), (v, rc))

    # --- which bmv2 ------------------------------------------------------------------------

    def test_the_round_captures_ndt_status_and_hashes_the_binary_it_names(self):
        binary = os.path.join(self.tmp, "simple_switch_grpc")
        with open(binary, "wb") as f:
            f.write(b"not really a switch, but it hashes\n")
        self.status_text = "  bmv2           %s\n  sample rate    1/256\n" % binary
        env = {"switch_sha": "-", "switch_ver": "-", "p4c_sha": "p", "p4c_ver": "v"}
        self.go(env=env)
        self.assertIn(["status"], [c[1:] for c in self.verbs()])
        self.assertEqual(self.mod.sha16(binary), env["switch_sha"])
        self.assertNotEqual("-", env["switch_sha"])
        labels = [lbl for lbl, _cmd, _out in self.steps_out]
        self.assertTrue(any("ndt status" in l for l in labels), labels)

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

    def test_a_client_killed_by_the_timeout_is_not_a_transfer(self):
        """🔴 The one case the exit code and the report line disagree about.

        The solution DROPS h3 -> h1, so iperf's client does not fail fast -- it sits in SYN
        retries until this driver's own wall clock kills it, and iperf v2 prints its (zero)
        interval line on the way out. A reading that looked only for `bits/sec` would call
        that a transfer, and the firewall's whole point would be reported as broken.
        """
        hosts = StubHosts(self.ips, popen_texts={"iperf -c": self.OK},
                          popen_timeouts=("iperf -c",), pa=zero_loss(self.mod))
        s = steps_for(self.mod, "firewall", "solution", hosts, self.tmp)
        s.run()
        v = verdict(s)
        self.assertTrue(v["iperf h3 -> h1 is blocked"].ok,
                        "a client the timeout killed did not connect")
        self.assertFalse(v["iperf h1 -> h3 (internal -> external)"].ok,
                         "and the same is true in the direction that should have worked")

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


class TheReceiverIsUnbuffered(unittest.TestCase):
    """🔴 The receiver's stdout is a FILE, so the interpreter block-buffers it.

    2026-09-18 19:11, tutorials harness, link_monitor/solution: both arms failed on
    the FIRST assertion -- `injection: probes reached h1  want=>=1 report row  got=0
    rows` -- with `logs/driver-h1-receive.log` at 0 B, not even receive.py:26's
    `sniffing on eth0`.  The dataplane was fine: the same run's s1.log has 8
    `Egress port is 1`, one per probe.  link_monitor/receive.py:16-28 only prints;
    basic/receive.py:51,58 and source_routing/receive.py:41,56 flush themselves,
    which is the whole reason those two arms passed on the same driver.

    `_start_receiver` redirects stdout to a file and `_stop_receiver` ends the child
    with SIGTERM, which runs no atexit handler -- so a buffer that was never flushed
    is simply discarded.  `-u` is the fix, and it belongs in the ARGV of every
    receiver this driver starts, not only link_monitor's: it is the exercise's own
    file that decides whether it flushes, and the driver does not get to assume.
    """

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-unbuf-")
        self.ips = {"h1": "10.0.1.1", "h2": "10.0.2.2", "h3": "10.0.3.3", "h4": "10.0.4.4"}

    def receivers(self, exercise):
        """Every argv this exercise's steps started a receive.py with."""
        hosts = StubHosts(self.ips, popen_texts={"receive.py": ""},
                          pa=zero_loss(self.mod))
        steps_for(self.mod, exercise, "solution", hosts, self.tmp).run()
        return [argv for _host, argv in hosts.popened
                if any(a.endswith("receive.py") for a in argv)]

    def test_every_receive_py_is_started_unbuffered_with_u_before_the_script(self):
        for ex in ("link_monitor", "basic", "source_routing"):
            with self.subTest(exercise=ex):
                started = self.receivers(ex)
                self.assertEqual(1, len(started),
                                 "%s starts exactly one receiver: %r" % (ex, started))
                argv = started[0]
                script = [i for i, a in enumerate(argv) if a.endswith("receive.py")][0]
                self.assertIn("-u", argv,
                              "%s: receive.py's stdout is a file, so without -u its "
                              "output dies in the buffer SIGTERM never flushes (%r)"
                              % (ex, argv))
                self.assertLess(argv.index("-u"), script,
                                "%s: -u after the script is an argument to receive.py, "
                                "not an interpreter flag (%r)" % (ex, argv))


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

    def test_the_report_names_the_bmv2_binary_by_its_sha(self):
        """CLAUDE.md: benchmark 必指認 binary（sha＋哪種識別碼）."""
        path = os.path.join(self.tmp, "r2.md")
        self.mod.write_report(path, {
            "utc": "now", "exercise": "basic", "which": "solution", "exdir": "/ex",
            "fabric": "ndtwin", "package": "/pkg", "switch_state": {},
            "env": {"switch_sha": "abcdef0123456789", "switch_ver": "bmv2 1.15 (ndt status)",
                    "switch_path": "the bmv2 `ndt status` names",
                    "p4c_sha": "0f0f0f0f0f0f0f0f", "p4c_ver": "p4c"},
            "compile": {"cmd": "p4c", "rc": 0, "out": "", "warnings": 0},
            "compile_extra": [], "topo_summary": "topology : x", "steps": [],
            "expects": [], "artifacts": [], "notes": [], "verdict": "PASS", "exit": 0,
            "stdout": "", "stderr": ""})
        with open(path) as f:
            text = f.read()
        self.assertIn("abcdef0123456789", text)
        self.assertIn("the bmv2 `ndt status` names", text)

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


# ======================================================= TICKET-P3 §2.7: the other nine ==
#
# 🔴 WHAT THESE CELLS CAN AND CANNOT SAY. Not one of the nine has ever been run on either
# fabric by the session that wrote them. Every expectation in the driver is
# 【源碼推導，未執行】 or 【README 宣稱】 (DRIVER.md §6 grades each one), and what is asserted
# here is only that the driver ASKS the question that way, and that the two arms of each
# exercise are DISTINGUISHABLE -- the solution's own output must fail the skeleton's check and
# the skeleton's must fail the solution's. Without that second half a pair of arms can both be
# green over a fabric that is doing neither thing.


def show2(*layers):
    """A scapy show2() block the way receive.py prints one, per delivered packet."""
    out = ["got a packet", "###[ Ethernet ]###", "  type      = IPv4"]
    for name, fields in layers:
        out.append("###[ %s ]###" % name)
        for k, v in fields:
            out.append("     %-9s = %s" % (k, v))
    return "\n".join(out) + "\n"


def sniffed(*blocks):
    return "sniffing on eth0\n" + "".join(blocks)


def mk_pingall(mod, ips, loss_of):
    """A PingAll over every ordered pair, built from real PingResults.

    `loss_of(src, dst)` returns the loss percentage, or None for UNTESTED. Real objects and
    not a table of numbers, because `multicast` is asserted PER PAIR and a stub that answered
    the aggregate would be the test supplying the answer it is checking.
    """
    pa = mod.PingAll()
    names = sorted(ips, key=mod.host_key)
    for s in names:
        for d in names:
            if s == d:
                continue
            loss = loss_of(s, d)
            if loss is None:
                r = mod.PingResult(None, 0, 0, why="stub: untested")
            else:
                recv = int(round(5 * (100 - loss) / 100.0))
                r = mod.PingResult(float(loss), recv, 5)
            pa.add(s, d, ips[d], r)
    return pa


def fake_controller(text, alive=True):
    """A stand-in for the exercise's own controller: it writes its log and stays up."""
    def go(argv, **kw):
        fh = kw.get("stdout")
        if hasattr(fh, "write"):
            fh.write(text.encode() if isinstance(text, str) else text)
            fh.flush()
        p = FakeProc(b"")
        if not alive:
            p.terminated = True          # poll() -> 0, i.e. it exited
        return p
    return go


IPS3 = {"h1": "10.0.1.1", "h2": "10.0.2.2", "h3": "10.0.3.3"}
IPS5 = {"h1": "10.0.1.1", "h11": "10.0.1.11", "h2": "10.0.2.2",
        "h22": "10.0.2.22", "h3": "10.0.3.3"}


class TheThirteen(unittest.TestCase):
    """The table itself: thirteen exercises, each with steps and each fully described."""

    def setUp(self):
        self.mod = load_driver()

    def test_all_thirteen_exercises_are_in_the_table(self):
        self.assertEqual(
            sorted(["basic", "basic_tunnel", "calc", "ecn", "firewall", "flowcache",
                    "link_monitor", "load_balance", "mri", "multicast", "p4runtime",
                    "qos", "source_routing"]),
            sorted(self.mod.EXERCISES))

    def test_every_exercise_has_scripted_steps(self):
        """A spec with no steps_ method is `main()`'s 'not scripted yet' path wearing a
        table entry, and the operator only finds out after the compile."""
        for ex in self.mod.EXERCISES:
            with self.subTest(exercise=ex):
                self.assertTrue(hasattr(self.mod.Steps, "steps_" + ex),
                                "%s is in EXERCISES with no steps_%s" % (ex, ex))

    def test_every_exercise_declares_what_the_driver_reads(self):
        for ex, spec in self.mod.EXERCISES.items():
            with self.subTest(exercise=ex):
                for key in ("topo", "prog", "default_prog", "hosts", "switches", "plan_steps"):
                    self.assertIn(key, spec)
                self.assertTrue(spec["prog"].endswith(".p4"))
                self.assertTrue(spec["default_prog"].endswith(".p4"))

    def test_multicast_is_the_one_exercise_whose_makefile_moves_the_topology(self):
        """exercises/multicast/Makefile:5 sets TOPO=sig-topo/topology.json; every other one
        of the nine falls through to utils/Makefile:13-15's topology.json. Reading the wrong
        file would build a four-host star as a three-host triangle and call it multicast."""
        moved = sorted(ex for ex, s in self.mod.EXERCISES.items()
                       if s["topo"] not in ("topology.json",))
        self.assertEqual(["basic", "firewall", "link_monitor", "multicast"], moved)
        self.assertEqual("sig-topo/topology.json", self.mod.EXERCISES["multicast"]["topo"])

    def test_none_of_the_nine_has_a_companion_program_to_build(self):
        """utils/Makefile:20-22's DEFAULT_PROG is the wildcard *.p4 and none of the nine
        overrides it, so each is its own default -- unlike firewall, whose Makefile:6 names
        basic.p4 and whose s2-s4 would start on a json nobody built."""
        tmp = tempfile.mkdtemp(prefix="drv-13-")
        build_tut_root(tmp)
        for ex in ("basic_tunnel", "calc", "ecn", "mri", "flowcache", "load_balance",
                   "multicast", "p4runtime", "qos"):
            with self.subTest(exercise=ex):
                self.assertEqual([], self.mod.companion_programs(
                    os.path.join(tmp, "exercises", ex), self.mod.EXERCISES[ex], "solution"))

    def test_only_two_exercises_declare_a_red_arm_that_is_not_the_data_plane(self):
        red = {ex: s["red_arm"] for ex, s in self.mod.EXERCISES.items() if s.get("red_arm")}
        self.assertEqual({"flowcache": "compile", "basic_tunnel": "entries"}, red)

    def test_p4runtime_compiles_the_same_program_on_both_arms(self):
        """🔴 exercises/p4runtime ships solution/mycontroller.py and NO solution/*.p4.

        advanced_tunnel.p4 has no TODO in it -- the exercise IS the controller -- so both arms
        run the same pipeline. Without `variant: controller` pick_source returns None for the
        solution arm and the round stops with "no .p4 source for p4runtime/solution" before it
        starts anything. Measured by reading the real tree on 2026-09-19.
        """
        tmp = tempfile.mkdtemp(prefix="drv-p4rt-")
        build_tut_root(tmp)
        exdir = os.path.join(tmp, "exercises", "p4runtime")
        os.remove(os.path.join(exdir, "solution", "advanced_tunnel.p4"))
        for which in ("skeleton", "solution"):
            with self.subTest(which=which):
                src, base = self.mod.pick_source(exdir, self.mod.EXERCISES["p4runtime"], which)
                self.assertEqual(os.path.join(exdir, "advanced_tunnel.p4"), src)
                self.assertEqual("advanced_tunnel", base)

    def test_an_exercise_with_no_solution_program_is_still_an_error_everywhere_else(self):
        """🔴 THE CONTROL for the flag above. `variant: controller` is explicit rather than
        "fall back to the skeleton whenever solution/ has no .p4", because for every other
        exercise a missing solution/*.p4 IS the error -- and a silent fallback would compile
        the SKELETON and report it as the solution arm.
        """
        tmp = tempfile.mkdtemp(prefix="drv-nosol-")
        build_tut_root(tmp)
        exdir = os.path.join(tmp, "exercises", "flowcache")
        os.remove(os.path.join(exdir, "solution", "flowcache.p4"))
        src, base = self.mod.pick_source(exdir, self.mod.EXERCISES["flowcache"], "solution")
        self.assertIsNone(src)

    def test_only_the_two_external_controller_exercises_name_a_controller(self):
        ctrl = {ex: s["controller"] for ex, s in self.mod.EXERCISES.items()
                if s.get("controller")}
        self.assertEqual({"flowcache": "mycontroller.py", "p4runtime": "mycontroller.py"}, ctrl)


class TheBasicTunnelArms(unittest.TestCase):
    """The tunnel routes by dst_id, not by IP -- so only dst_id may move between rounds."""

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-bt-")

    def session(self, which, h2_text, h3_text):
        """h2 and h3 both sniff both rounds; the stub answers per receiver TAG."""
        hosts = StubHosts(IPS3, popen_texts={
            "driver-h2": "", "driver-h3": "",
            "send.py": ("sending on interface eth0 to dst_id 2\n"
                        if which else ""),
        })
        s = steps_for(self.mod, "basic_tunnel", which, hosts, self.tmp)
        # The receivers' output is whatever the tag's log file holds; write it as the step
        # runs by patching _stop_receiver's reader through the log files themselves.
        texts = {"h2-1": h2_text[0], "h3-1": h3_text[0],
                 "h2-2": h2_text[1], "h3-2": h3_text[1]}
        real_stop = s._stop_receiver

        def stop(proc, fh, path, drain=None):
            real_stop(proc, fh, path, drain)
            for tag, txt in texts.items():
                if path.endswith("driver-%s-receive.log" % tag):
                    return txt
            return ""
        s._stop_receiver = stop
        sends = []
        real_send = s._send_once

        def send(host, argv, feed=None, label=""):
            sends.append(list(argv))
            dst = argv[argv.index("--dst_id") + 1]
            real_send(host, argv, feed, label)
            return "sending on interface eth0 to dst_id %s\n" % dst
        s._send_once = send
        s.run()
        self.sends = sends
        return s

    ONE = show2(("IP", [("ttl", "63")]))

    def test_the_solution_wants_dst_id_2_at_h2_and_dst_id_3_at_h3(self):
        s = self.session("solution", (self.ONE, ""), ("", self.ONE))
        v = verdict(s)
        self.assertTrue(v["--dst_id 2 lands on h2"].ok)
        self.assertTrue(v["--dst_id 3 lands on h3, same IP"].ok)
        self.assertTrue(v["injection: send.py built 2 tunnel frames"].ok)

    def test_both_rounds_send_to_the_same_ip_and_only_dst_id_moves(self):
        """🔴 README:138-140 is the whole exercise: 'received at h2, even though that IP
        address is the address of h3'. A driver that changed the IP too would pass over a
        fabric with no tunnel table at all."""
        self.session("solution", (self.ONE, ""), ("", self.ONE))
        dests = {a[2] for a in self.sends}
        ids = [a[a.index("--dst_id") + 1] for a in self.sends]
        self.assertEqual({IPS3["h2"]}, dests, self.sends)
        self.assertEqual(["2", "3"], ids)

    def test_the_basic_tunnel_arms_are_distinguishable(self):
        """The skeleton's own (empty) result must fail the solution's checks, and the
        solution's must fail the skeleton's."""
        v = verdict(self.session("solution", ("", ""), ("", "")))
        self.assertFalse(v["--dst_id 2 lands on h2"].ok)
        v = verdict(self.session("skeleton", (self.ONE, ""), ("", self.ONE)))
        self.assertFalse(v["nothing is delivered by the skeleton"].ok)

    def test_a_tunnel_that_delivered_to_the_wrong_host_is_red(self):
        """🔴 dst_id 3 arriving at h3 AND at h2 is not the tunnel working.

        The IP in both rounds is h2's, so a copy reaching h2 with `--dst_id 3` means the
        switch also forwarded on the IP header -- flooding, a leftover ipv4_lpm entry, a
        tunnel that did not replace the route. "h3 got one" alone is satisfied by all of
        those, which is why both halves are asserted.
        """
        v = verdict(self.session("solution", (self.ONE, self.ONE), ("", self.ONE)))
        self.assertTrue(v["--dst_id 2 lands on h2"].ok)
        self.assertFalse(v["--dst_id 3 lands on h3, same IP"].ok)


class TheCalcArms(unittest.TestCase):
    """calc.py is the client, the REPL is the interface, and the two arms are two lines."""

    SOLUTION = "> 1+1\n2\n> "
    SKELETON = "> 1+1\nDidn't receive response\n> "

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-calc-")

    def session(self, which, out):
        hosts = StubHosts({"h1": "10.0.1.1", "h2": "10.0.1.2"},
                          popen_texts={"calc.py": out})
        s = steps_for(self.mod, "calc", which, hosts, self.tmp)
        s.run()
        self.hosts = hosts
        return s

    def test_the_repl_is_fed_the_expression_and_the_quit(self):
        """calc.py:80-83 loops on input() until the line is exactly `quit`; a run that never
        quit would sit on the driver's SEND_TIMEOUT and report a timeout as no answer."""
        self.session("solution", self.SOLUTION)
        argv = [a for _h, a in self.hosts.popened if any("calc.py" in x for x in a)][0]
        self.assertIn("-u", argv)
        self.assertLess(argv.index("-u"), [i for i, a in enumerate(argv)
                                           if a.endswith("calc.py")][0])
        proc = [p for _h, a, p in self.hosts.procs if any("calc.py" in x for x in a)][0]
        self.assertEqual(b"1+1\nquit\n", proc.fed)

    def test_the_solution_wants_the_answer_line(self):
        v = verdict(self.session("solution", self.SOLUTION))
        self.assertTrue(v["the switch answered 1+1"].ok)
        self.assertTrue(v["and it did not time out"].ok)

    def test_the_skeleton_wants_the_timeout_line(self):
        v = verdict(self.session("skeleton", self.SKELETON))
        self.assertTrue(v["RED ARM: the skeleton must not answer"].ok)

    def test_the_calc_arms_are_distinguishable(self):
        self.assertFalse(verdict(self.session("solution", self.SKELETON))
                         ["the switch answered 1+1"].ok)
        self.assertFalse(verdict(self.session("skeleton", self.SOLUTION))
                         ["RED ARM: the skeleton must not answer"].ok)

    def test_a_client_that_never_read_the_expression_fails_the_injection_check(self):
        """No `> 1+1` echo means calc.py never got that far, and then 'no answer' is a
        statement about the client rather than about the switch."""
        v = verdict(self.session("skeleton", "Traceback (most recent call last):\n"))
        self.assertFalse(v["injection: calc.py read the expression"].ok)

    def test_the_answer_is_a_line_and_not_a_substring(self):
        """`2` inside a longer line is not the answer: calc.py:97 prints it alone."""
        v = verdict(self.session("solution", "> 1+1\ncannot find P4calc header in 2 packets\n"))
        self.assertFalse(v["the switch answered 1+1"].ok)


class TheEcnAndQosArms(unittest.TestCase):
    """Both arms are read off one field -- ipv4.tos -- and both need the whole SET of it."""

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-tos-")

    def ecn(self, which, tos_values):
        rx = sniffed(*[show2(("IP", [("tos", t)])) for t in tos_values])
        hosts = StubHosts(IPS5, popen_texts={
            "receive.py": rx,
            "send.py": "###[ IP ]###\n     tos       = 0x1\n"})
        s = steps_for(self.mod, "ecn", which, hosts, self.tmp)
        s.run()
        self.hosts = hosts
        return s

    def qos(self, which, udp_tos, tcp_tos):
        seq = {"1": udp_tos, "2": tcp_tos}
        hosts = StubHosts(IPS5, popen_texts={
            "receive.py": "", "send.py": "###[ IP ]###\n     tos       = 0x1\n"})
        s = steps_for(self.mod, "qos", which, hosts, self.tmp)
        real_stop = s._stop_receiver

        def stop(proc, fh, path, drain=None):
            real_stop(proc, fh, path, drain)
            for tag, values in seq.items():
                if path.endswith("driver-h2-%s-receive.log" % tag):
                    return sniffed(*[show2(("IP", [("tos", t)])) for t in values])
            return ""
        s._stop_receiver = stop
        s.run()
        self.hosts = hosts
        return s

    # -- ecn ------------------------------------------------------------------------------

    def test_ecn_runs_a_background_flow_between_h11_and_h22(self):
        """ecn.p4:9's ECN_THRESHOLD is 10 enqueued packets and nothing else in this exercise
        builds a queue. A run without the background flow would report the solution as red
        for a reason that is not about ecn.p4."""
        self.ecn("solution", ["0x1", "0x3"])
        iperfs = [(h, a) for h, a in self.hosts.popened if a and a[0] == "iperf"]
        self.assertEqual([("h22", ["iperf", "-s", "-u"])], [(h, a) for h, a in iperfs if "-s" in a])
        cli = [(h, a) for h, a in iperfs if "-c" in a]
        self.assertEqual(1, len(cli), cli)
        self.assertEqual("h11", cli[0][0])
        self.assertIn("-u", cli[0][1])
        self.assertIn(IPS5["h22"], cli[0][1])

    def test_the_ecn_solution_wants_a_marked_packet(self):
        v = verdict(self.ecn("solution", ["0x1", "0x1", "0x3"]))
        self.assertTrue(v["h2 saw a congestion-marked packet"].ok)

    def test_the_ecn_skeleton_wants_every_packet_unmarked(self):
        v = verdict(self.ecn("skeleton", ["0x1", "0x1"]))
        self.assertTrue(v["RED ARM: every tos stays 0x1"].ok)

    def test_the_ecn_arms_are_distinguishable(self):
        self.assertFalse(verdict(self.ecn("solution", ["0x1", "0x1"]))
                         ["h2 saw a congestion-marked packet"].ok)
        self.assertFalse(verdict(self.ecn("skeleton", ["0x1", "0x3"]))
                         ["RED ARM: every tos stays 0x1"].ok)

    def test_no_packet_at_all_fails_the_injection_check_rather_than_passing_vacuously(self):
        """'every tos is 0x1' is true of an empty list, which is what a dead fabric, a dead
        sender and a sniffer that never started all produce."""
        for which in ("solution", "skeleton"):
            with self.subTest(which=which):
                v = verdict(self.ecn(which, []))
                self.assertFalse(v["injection: packets reached h2"].ok)
                key = ("h2 saw a congestion-marked packet" if which == "solution"
                       else "RED ARM: every tos stays 0x1")
                self.assertFalse(v[key].ok)

    # -- qos ------------------------------------------------------------------------------

    def test_qos_sends_both_protocols_with_the_flags_its_send_py_parses(self):
        """qos/send.py:27-32 is argparse with --p/--des/--m/--dur and its body runs only when
        all four are given (:34): a positional argv would be accepted silently and do nothing."""
        self.qos("solution", ["0xb9"], ["0xb1"])
        sends = [a for _h, a in self.hosts.popened if any("send.py" in x for x in a)]
        protos = sorted(x.split("=")[1] for a in sends for x in a if x.startswith("--p="))
        self.assertEqual(["TCP", "UDP"], protos)
        for a in sends:
            self.assertTrue(any(x.startswith("--des=") for x in a), a)
            self.assertTrue(any(x.startswith("--m=") for x in a), a)
            self.assertTrue(any(x.startswith("--dur=") for x in a), a)

    def test_the_qos_solution_wants_a_different_class_per_protocol(self):
        v = verdict(self.qos("solution", ["0x1", "0xb9"], ["0x1", "0xb1"]))
        self.assertTrue(v["UDP is expedited forwarding"].ok)
        self.assertTrue(v["TCP is voice admit"].ok)

    def test_a_fabric_that_stamped_one_class_on_both_protocols_is_red(self):
        """🔴 The reason both protocols are sent. With only UDP asserted, a switch that put
        0xb9 on everything would pass -- and the exercise IS the classification."""
        v = verdict(self.qos("solution", ["0xb9"], ["0xb9"]))
        self.assertTrue(v["UDP is expedited forwarding"].ok)
        self.assertFalse(v["TCP is voice admit"].ok)

    def test_the_qos_skeleton_wants_0x1_on_both(self):
        v = verdict(self.qos("skeleton", ["0x1"], ["0x1"]))
        self.assertTrue(v["RED ARM: UDP tos stays 0x1"].ok)
        self.assertTrue(v["RED ARM: TCP tos stays 0x1"].ok)

    def test_the_qos_arms_are_distinguishable(self):
        self.assertFalse(verdict(self.qos("skeleton", ["0xb9"], ["0xb1"]))
                         ["RED ARM: UDP tos stays 0x1"].ok)
        self.assertFalse(verdict(self.qos("solution", ["0x1"], ["0x1"]))
                         ["UDP is expedited forwarding"].ok)


class TheMriArms(unittest.TestCase):
    """The hop count and the swids, which are what the MRI option is for."""

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-mri-")

    SOLUTION = sniffed(show2(("IPOption_MRI", [("count", "2")]),
                             ("SwitchTrace", [("swid", "2"), ("qdepth", "0")]),
                             ("SwitchTrace", [("swid", "1"), ("qdepth", "17")])))
    SKELETON = sniffed(show2(("IPOption_MRI", [("count", "0")])))

    def session(self, which, rx):
        hosts = StubHosts(IPS5, popen_texts={"receive.py": rx, "send.py": ""})
        s = steps_for(self.mod, "mri", which, hosts, self.tmp)
        s.run()
        return s

    def test_the_solution_wants_two_hops_and_both_swids(self):
        v = verdict(self.session("solution", self.SOLUTION))
        self.assertTrue(v["hop count at h2"].ok)
        self.assertTrue(v["switch ids in the trace"].ok)

    def test_the_skeleton_wants_an_empty_trace(self):
        v = verdict(self.session("skeleton", self.SKELETON))
        self.assertTrue(v["RED ARM: the hop count stays 0"].ok)
        self.assertTrue(v["and no swid is ever stamped"].ok)

    def test_the_mri_arms_are_distinguishable(self):
        self.assertFalse(verdict(self.session("solution", self.SKELETON))["hop count at h2"].ok)
        self.assertFalse(verdict(self.session("skeleton", self.SOLUTION))
                         ["RED ARM: the hop count stays 0"].ok)

    def test_a_packet_with_no_mri_option_fails_its_own_check(self):
        """A UDP datagram that arrived without the option is not 'count = 0': the option was
        stripped or never built, and mri.p4 is not the subject of that."""
        v = verdict(self.session("skeleton", sniffed(show2(("IP", [("ttl", "62")])))))
        self.assertTrue(v["injection: packets reached h2"].ok)
        self.assertFalse(v["injection: the MRI option survived to h2"].ok)
        self.assertFalse(v["RED ARM: the hop count stays 0"].ok)

    def test_qdepth_is_not_asserted_in_either_arm(self):
        """🔴 It is 0 without the 0.5 Mbit/s link of topology.json:65-69 (G2-C), and this
        exercise's claim is the count and the swids. A cell on qdepth would make mri red for
        a property of the fabric rather than of mri.p4."""
        for which in ("solution", "skeleton"):
            with self.subTest(which=which):
                s = self.session(which, self.SOLUTION if which == "solution" else self.SKELETON)
                self.assertEqual([], [e for e in s.expects if "qdepth" in e.name])


class TheLoadBalanceArms(unittest.TestCase):
    """Ten sends, because one packet is consistent with both arms."""

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-lb-")

    def session(self, which, n2, n3):
        hosts = StubHosts(IPS3, popen_texts={
            "receive.py": "", "send.py": "sending on interface eth0 to 10.0.0.1\n"})
        s = steps_for(self.mod, "load_balance", which, hosts, self.tmp)
        texts = {"h2": sniffed(*[show2(("IP", [("ttl", "62")]))] * n2),
                 "h3": sniffed(*[show2(("IP", [("ttl", "62")]))] * n3)}
        real_stop = s._stop_receiver

        def stop(proc, fh, path, drain=None):
            real_stop(proc, fh, path, drain)
            for tag, txt in texts.items():
                if path.endswith("driver-%s-receive.log" % tag):
                    return txt
            return ""
        s._stop_receiver = stop
        s.run()
        self.hosts = hosts
        return s

    def test_ten_packets_are_sent_to_the_load_balanced_address(self):
        """🔴 10.0.0.1 is nobody's host address -- it is what s1's ecmp_group matches on --
        so the hosts that answer are decided by the fabric, which is the whole exercise."""
        self.session("solution", 5, 5)
        sends = [a for _h, a in self.hosts.popened if any("send.py" in x for x in a)]
        self.assertEqual(10, len(sends), sends)
        self.assertEqual({"10.0.0.1"}, {a[2] for a in sends})

    def test_the_solution_wants_both_servers_used(self):
        self.assertTrue(verdict(self.session("solution", 6, 4))["both servers were used"].ok)

    def test_the_skeleton_wants_only_h2(self):
        self.assertTrue(verdict(self.session("skeleton", 10, 0))["RED ARM: only h2 is used"].ok)

    def test_the_load_balance_arms_are_distinguishable(self):
        self.assertFalse(verdict(self.session("solution", 10, 0))["both servers were used"].ok)
        self.assertFalse(verdict(self.session("skeleton", 6, 4))["RED ARM: only h2 is used"].ok)

    def test_a_fabric_that_delivered_nothing_fails_both_arms(self):
        for which, key in (("solution", "both servers were used"),
                           ("skeleton", "RED ARM: only h2 is used")):
            with self.subTest(which=which):
                self.assertFalse(verdict(self.session(which, 0, 0))[key].ok)


class TheMulticastArms(unittest.TestCase):
    """🔴 The solution's correct result is a fabric that is PARTLY unreachable."""

    IPS = {"h1": "10.0.0.1", "h2": "10.0.0.2", "h3": "10.0.0.3", "h4": "10.0.0.4"}

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-mc-")

    def session(self, which, loss_of):
        hosts = StubHosts(self.IPS, pa=mk_pingall(self.mod, self.IPS, loss_of))
        s = steps_for(self.mod, "multicast", which, hosts, self.tmp)
        s.run()
        self.hosts = hosts
        return s

    @staticmethod
    def GROUP_ONLY(s, d):
        return 100 if "h4" in (s, d) else 0

    def test_ipv6_is_disabled_inside_every_host_and_not_on_the_box(self):
        """exercises/multicast/disable_ipv6.sh as shipped is `sudo sysctl` on the machine.
        Run as the exercise ships it this driver would turn IPv6 off for everything on the
        laptop, which is not its to do; what it is FOR is the noise inside the fabric."""
        self.session("solution", self.GROUP_ONLY)
        hosts = sorted(h for h, line in self.hosts.cmds if "disable_ipv6" in line)
        self.assertEqual(["h1", "h2", "h3", "h4"], hosts)
        for _h, line in self.hosts.cmds:
            if "disable_ipv6" in line:
                self.assertIn("net.ipv6.conf.all.disable_ipv6=1", line)
                self.assertNotIn("sudo", line)

    def test_the_solution_wants_the_group_reachable_and_h4_not(self):
        v = verdict(self.session("solution", self.GROUP_ONLY))
        self.assertTrue(v["h1/h2/h3 reach each other"].ok)
        self.assertTrue(v["nobody reaches h4"].ok)

    def test_a_solution_that_also_reached_h4_is_red(self):
        """🔴 sig-topo/s1-runtime.json:47-65 replicates ports 1,2,3; the fourth is README:122's
        own TODO and this driver does not edit the exercise. A fabric that reached h4 is
        running something other than what the package carries."""
        v = verdict(self.session("solution", lambda s, d: 0))
        self.assertTrue(v["h1/h2/h3 reach each other"].ok)
        self.assertFalse(v["nobody reaches h4"].ok)

    def test_the_skeleton_wants_nothing_to_ping_at_all(self):
        v = verdict(self.session("skeleton", lambda s, d: 100))
        self.assertTrue(v["RED ARM: nothing pings at all"].ok)

    def test_the_multicast_arms_are_distinguishable(self):
        self.assertFalse(verdict(self.session("skeleton", self.GROUP_ONLY))
                         ["RED ARM: nothing pings at all"].ok)
        self.assertFalse(verdict(self.session("solution", lambda s, d: 100))
                         ["h1/h2/h3 reach each other"].ok)

    def test_an_untested_pair_is_not_a_blocked_one(self):
        """A host whose namespace could not be entered looks exactly like a host the group
        does not replicate to, and only this cell tells them apart."""
        v = verdict(self.session("solution",
                                 lambda s, d: None if "h4" in (s, d) else 0))
        self.assertFalse(v["injection: every ordered pair was tested"].ok)
        self.assertFalse(v["nobody reaches h4"].ok)


class TheControllerArms(unittest.TestCase):
    """exercises/p4runtime and exercises/flowcache: the controller IS the exercise."""

    P4RT_SOLUTION = ("Installed P4 Program using SetForwardingPipelineConfig on s1\n"
                     "Installed P4 Program using SetForwardingPipelineConfig on s2\n"
                     "Installed ingress tunnel rule on s1\n"
                     "Installed transit tunnel rule on s2\n"
                     "Installed egress tunnel rule on s2\n")
    P4RT_SKELETON = ("Installed P4 Program using SetForwardingPipelineConfig on s1\n"
                     "Installed P4 Program using SetForwardingPipelineConfig on s2\n"
                     "Installed ingress tunnel rule on s1\n"
                     "TODO Install transit tunnel rule\n")
    FC_SOLUTION = ("Installed P4 Program using SetForwardingPipelineConfig on s1\n"
                   "Installed P4 Program using SetForwardingPipelineConfig on s2\n"
                   "Installed P4 Program using SetForwardingPipelineConfig on s3\n"
                   "Received PacketIn message of length 64 bytes from switch s1\n"
                   "For switch s1 flow (SA=10.0.1.1, DA=10.0.2.2, proto=1) added table entry "
                   "to send packets to port 2 with new DSCP 5\n")

    def setUp(self):
        self.mod = load_driver()
        quiet(self.mod)
        self.tmp = tempfile.mkdtemp(prefix="drv-ctrl-")

    def session(self, exercise, which, log, loss, fabric="tutorials", package=None, alive=True):
        self.mod.local_popen = fake_controller(log, alive=alive)
        hosts = StubHosts(IPS3, pings={("h1", IPS3["h2"]):
                                       self.mod.PingResult(float(loss),
                                                           int(5 * (100 - loss) / 100), 5)})
        s = steps_for(self.mod, exercise, which, hosts, self.tmp,
                      fabric=fabric, package=package)
        s.run()
        return s

    def controller_argv(self):
        return self.started

    # -- which command starts the controller -------------------------------------------

    def test_the_tutorials_arm_runs_the_controller_as_itself(self):
        """Its 127.0.0.1:5005N and device_id N-1 are the truth of the harness it was written
        for, so nothing has to rewrite them there."""
        started = []
        self.mod.local_popen = lambda argv, **kw: (started.append(list(argv)),
                                                   fake_controller(self.P4RT_SOLUTION)(argv, **kw))[1]
        hosts = StubHosts(IPS3, pings={("h1", IPS3["h2"]): self.mod.PingResult(0.0, 5, 5)})
        steps_for(self.mod, "p4runtime", "solution", hosts, self.tmp).run()
        self.assertEqual(1, len(started))
        self.assertTrue(started[0][-1].endswith("solution/mycontroller.py"), started[0])
        self.assertNotIn("run_external_controller.py", " ".join(started[0]))

    def test_the_ndtwin_arm_goes_through_the_adapter_live_p1_03_uses(self):
        """🔴 On NDTwin the hard-coded ports and device ids are NOT the truth, and
        tools/p4_exercise/run_external_controller.py is what rewrites them (TICKET-P1D).
        Two launchers for one controller would make 'the exercise's controller ran' mean two
        different things on the two fabrics."""
        started = []
        self.mod.local_popen = lambda argv, **kw: (started.append(list(argv)),
                                                   fake_controller(self.P4RT_SKELETON)(argv, **kw))[1]
        hosts = StubHosts(IPS3, pings={("h1", IPS3["h2"]): self.mod.PingResult(100.0, 0, 5)})
        steps_for(self.mod, "p4runtime", "skeleton", hosts, self.tmp,
                  fabric="ndtwin", package="/pkg").run()
        self.assertIn("run_external_controller.py", " ".join(started[0]))
        self.assertIn("/pkg", started[0])
        self.assertIn("mycontroller.py", started[0])

    # -- p4runtime ---------------------------------------------------------------------

    def test_the_p4runtime_solution_wants_the_transit_rule_and_the_ping(self):
        v = verdict(self.session("p4runtime", "solution", self.P4RT_SOLUTION, 0))
        self.assertTrue(v["the transit rule went in"].ok)
        self.assertTrue(v["h1 -> h2 forwards through the tunnel"].ok)
        self.assertTrue(v["switches the controller programmed"].ok)

    def test_the_p4runtime_skeleton_wants_the_todo_and_no_forwarding(self):
        v = verdict(self.session("p4runtime", "skeleton", self.P4RT_SKELETON, 100))
        self.assertTrue(v["RED ARM: the transit rule is still the student's TODO"].ok)
        self.assertTrue(v["RED ARM: h1 -> h2 does not forward"].ok)

    def test_the_p4runtime_arms_are_distinguishable(self):
        self.assertFalse(verdict(self.session("p4runtime", "solution",
                                              self.P4RT_SKELETON, 100))
                         ["the transit rule went in"].ok)
        self.assertFalse(verdict(self.session("p4runtime", "skeleton",
                                              self.P4RT_SOLUTION, 0))
                         ["RED ARM: the transit rule is still the student's TODO"].ok)

    def test_a_controller_that_died_fails_the_injection_check(self):
        """🔴 'h1 cannot ping h2' is true of a controller that never started, of a fabric that
        never came up and of the skeleton alike. Only the controller's own log tells them
        apart, which is why it is asserted first."""
        v = verdict(self.session("p4runtime", "skeleton", "", 100, alive=False))
        self.assertFalse(v["injection: the controller stayed up"].ok)
        self.assertFalse(v["switches the controller programmed"].ok)

    def test_a_controller_that_programmed_the_wrong_switches_is_red(self):
        """mycontroller.py:142-152 connects to s1 and s2 and never touches s3; live-p1/03
        asserts the same set on the twin's side."""
        log = self.P4RT_SOLUTION + \
            "Installed P4 Program using SetForwardingPipelineConfig on s3\n"
        v = verdict(self.session("p4runtime", "solution", log, 0))
        self.assertFalse(v["switches the controller programmed"].ok)

    # -- flowcache ---------------------------------------------------------------------

    def test_the_flowcache_solution_wants_three_switches_a_cached_flow_and_the_ping(self):
        v = verdict(self.session("flowcache", "solution", self.FC_SOLUTION, 0))
        self.assertTrue(v["switches the controller programmed"].ok)
        self.assertTrue(v["the controller cached the flow it was punted"].ok)
        self.assertTrue(v["h1 -> h2 forwards once the cache is warm"].ok)

    def test_reaching_the_flowcache_steps_with_the_skeleton_is_itself_the_finding(self):
        """🔴 spec['red_arm'] == 'compile': the skeleton is supposed to stop at p4c
        (flowcache.p4:83-91 vs :232/:269-271, README:29). A run that got here compiled it."""
        v = verdict(self.session("flowcache", "skeleton", self.FC_SOLUTION, 0))
        self.assertIn("RED ARM: the skeleton must not compile", v)
        self.assertFalse(v["RED ARM: the skeleton must not compile"].ok)

    def test_a_flowcache_round_with_no_cached_flow_is_red(self):
        log = "\n".join(self.FC_SOLUTION.splitlines()[:3]) + "\n"
        v = verdict(self.session("flowcache", "solution", log, 0))
        self.assertTrue(v["switches the controller programmed"].ok)
        self.assertFalse(v["the controller cached the flow it was punted"].ok)


class TheRedArmsThatAreNotTheDataPlane(unittest.TestCase):
    """flowcache stops at the compiler and basic_tunnel stops at the control plane."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="drv-red-")
        self.mod = load_driver()
        self.mod.TUT = build_tut_root(self.tmp)
        self.mod.UTILS = os.path.join(self.tmp, "utils")
        self.mod.RUNS = os.path.join(self.tmp, "runs")
        stub_preflight(self.mod)

    def compiler(self, rc):
        def fake(exdir, src, base):
            info = {"cmd": "p4c (stubbed)", "rc": rc, "out": "", "warnings": 0, "src": src}
            if rc == 0:
                # The real compile_prog only returns these when both files exist, and
                # write_report stats the p4info -- so the stand-in has to produce them too.
                build = os.path.join(exdir, "build")
                os.makedirs(build, exist_ok=True)
                for name in (base + ".json", base + ".p4.p4info.txtpb"):
                    with open(os.path.join(build, name), "w") as f:
                        f.write("{}\n")
                info.update({"json": os.path.join(build, base + ".json"), "bytes": 1,
                             "sha": "j" * 16,
                             "p4info": os.path.join(build, base + ".p4.p4info.txtpb")})
            return rc, (info.get("json")), info
        self.mod.compile_prog = fake

    def test_a_flowcache_skeleton_that_does_not_compile_is_exit_1_and_says_by_design(self):
        """🔴 NOT exit 2. Two means 'nothing was started, there is nothing to look at', and
        filing the designed refusal under it would put it with the broken cases."""
        self.compiler(1)
        rc, text = render_main(self.mod, ["flowcache", "--which", "skeleton"], self.mod.TUT)
        self.assertEqual(1, rc)
        self.assertIn("skeleton does not compile, by design", text)
        self.assertIn("RED ARM: the skeleton must NOT compile", text)

    def test_a_flowcache_skeleton_that_DOES_compile_is_the_finding(self):
        self.compiler(0)
        rc, text = render_main(self.mod, ["flowcache", "--which", "skeleton"], self.mod.TUT)
        self.assertEqual(1, rc)
        self.assertIn("the red arm is not red", text)

    def test_the_flowcache_solution_is_not_treated_as_a_red_arm(self):
        self.compiler(0)
        rc, text = render_main(self.mod, ["flowcache", "--dry-run"], self.mod.TUT)
        self.assertEqual(0, rc)
        self.assertNotIn("RED ARM", text)

    def test_a_compile_failure_anywhere_else_is_still_exit_2(self):
        """Every other exercise's compile failure is a broken tool chain, not an arm."""
        self.compiler(1)
        rc, text = render_main(self.mod, ["basic", "--which", "skeleton"], self.mod.TUT)
        self.assertEqual(2, rc)
        self.assertIn("compile failed -- stopping", text)


class TheTelemetryFlag(unittest.TestCase):
    """`--telemetry` is an ndtwin flag, and omitting it is not the same as saying `auto`."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="drv-tel-")
        self.mod = load_driver()
        quiet(self.mod)
        self.mod.TUT = build_tut_root(self.tmp)
        self.mod.PKG_ROOT = os.path.join(self.tmp, "packages")
        self.mod.NDT = "/fake/ndt"
        self.mod.PROXY_PY = "/fake/python"
        self.mod.CONVERT = "/fake/convert.py"
        self.mod.PREFLIGHT = "/fake/preflight.py"
        self.mod.HOST_KNOB = os.path.join(self.tmp, "host_count_override")
        self.mod.TELEMETRY_KNOB = os.path.join(self.tmp, "telemetry_override")
        self.mod.switch_state = lambda *_a, **_k: {"switches": {}}
        self.mod.link_usage_cell = lambda *_a, **_k: (True, "LINK_USAGE stub rc=0")
        self.calls = []
        mod = self.mod

        def runner(cmd, cwd=None, timeout=None, env=None):
            self.calls.append(list(cmd))
            return 0, "stub ok"
        mod.run = runner

        class NoSteps(object):
            def __init__(self, *a, **kw):
                self.expects, self.steps = [], []

            def run(self):
                pass
        mod.Steps = NoSteps
        mod.NdtwinHosts = lambda *a, **kw: StubHosts({"h1": "10.0.1.1"})
        self.args = Args()
        self.args.telemetry = None

    def go(self):
        steps = []
        return self.mod.run_on_ndtwin("basic", "solution", "/ex",
                                      self.mod.EXERCISES["basic"], self.args,
                                      {"h1": "10.0.1.1"}, self.tmp, steps, None)

    def up_argv(self):
        return [c for c in self.calls if c and c[0] == self.mod.NDT and c[1] == "up"][0]

    def test_no_flag_means_the_package_decides(self):
        """🔴 Not `auto`. Without --telemetry `ndt` writes the package's own telemetry.source;
        spelling a word out here would overrule every package that declared one and then
        report the result as the package's."""
        self.go()
        self.assertNotIn("--telemetry", self.up_argv())

    def test_the_word_is_passed_through_when_it_is_given(self):
        for word in ("none", "cooperative", "link", "auto"):
            with self.subTest(word=word):
                self.calls = []
                self.args.telemetry = word
                self.go()
                argv = self.up_argv()
                self.assertIn("--telemetry", argv)
                self.assertEqual(word, argv[argv.index("--telemetry") + 1])

    def test_the_telemetry_knob_is_put_back_by_the_teardown(self):
        """🔴 `ndt down` does not touch it and `ndt release` does not check it (TICKET-P3
        §2.1), so nothing refuses over a knob this round moved -- which is exactly why the
        round has to put it back itself. It decides the NEXT bring-up's telemetry."""
        with open(self.mod.TELEMETRY_KNOB, "wb") as f:
            f.write(b"# mine\nauto\n")
        self.args.telemetry = "link"
        mod = self.mod

        def runner(cmd, cwd=None, timeout=None, env=None):
            self.calls.append(list(cmd))
            if "--telemetry" in cmd:
                with open(mod.TELEMETRY_KNOB, "wb") as f:
                    f.write(b"link\n")
            return 0, "stub ok"
        mod.run = runner
        self.go()
        with open(self.mod.TELEMETRY_KNOB, "rb") as f:
            self.assertEqual(b"# mine\nauto\n", f.read())

    def test_a_telemetry_knob_this_round_created_is_removed_again(self):
        self.args.telemetry = "none"
        mod = self.mod

        def runner(cmd, cwd=None, timeout=None, env=None):
            self.calls.append(list(cmd))
            if "--telemetry" in cmd:
                with open(mod.TELEMETRY_KNOB, "wb") as f:
                    f.write(b"none\n")
            return 0, "stub ok"
        mod.run = runner
        self.go()
        self.assertFalse(os.path.exists(self.mod.TELEMETRY_KNOB))

    def test_the_flag_is_refused_on_the_tutorials_fabric(self):
        """There is no proxy, no kernel and no telemetry_override in the exercise's own
        Mininet: an accepted-and-ignored flag is a word nobody read."""
        mod = load_driver()                 # a module whose `say` still prints
        mod.TUT = self.mod.TUT
        stub_preflight(mod)
        stub_compile(mod)
        rc, text = render_main(mod, ["basic", "--telemetry", "link", "--dry-run"], mod.TUT)
        self.assertEqual(2, rc)
        self.assertIn("--telemetry is an ndtwin-fabric flag", text)
        self.assertNotIn("compile", text, "refused before anything was built")


class TheGenericLinkUsageCell(unittest.TestCase):
    """🔴 The one cell that is about NDTwin rather than about an exercise's program."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="drv-usage-")
        self.mod = load_driver()
        quiet(self.mod)

    def test_the_cell_does_not_run_on_a_skeleton_arm(self):
        """🔴 A SKELETON IS A FABRIC THE EXERCISE SAYS SHOULD NOT FORWARD. Running the cell
        there produces an empty on-path set, which the assertion refuses -- correctly, and
        about the wrong thing. NOT RUN, with the reason, and NO expectation either way."""
        run, dst, why = self.mod.link_usage_applies(self.mod.EXERCISES["basic"], "skeleton")
        self.assertFalse(run)
        self.assertIn("should not forward", why)

    def test_two_solutions_forward_nothing_and_are_named(self):
        """source_routing's solution drops every frame without a 0x1234 stack and calc's
        drops everything that is not the calculator protocol. Both are properties of the
        EXERCISE; a cell that went red on them would be reporting the twin for it."""
        for ex, fragment in (("source_routing", "0x1234 source-route stack"),
                             ("calc", "calculator protocol")):
            with self.subTest(exercise=ex):
                run, dst, why = self.mod.link_usage_applies(self.mod.EXERCISES[ex], "solution")
                self.assertFalse(run)
                self.assertIn(fragment, why)

    def test_every_other_solution_arm_runs_the_cell(self):
        runs = sorted(ex for ex in self.mod.EXERCISES
                      if self.mod.link_usage_applies(self.mod.EXERCISES[ex], "solution")[0])
        self.assertEqual(
            sorted(["basic", "basic_tunnel", "ecn", "firewall", "flowcache", "link_monitor",
                    "load_balance", "mri", "multicast", "p4runtime", "qos"]), runs)

    def test_the_two_unreachable_last_hosts_are_overridden(self):
        """🔴 "The model's last host" is a property of the MODEL, and for two packages it is a
        host the exercise deliberately cannot reach: multicast's sig-topo group replicates
        ports 1,2,3 (README:122 is the TODO to add the fourth) and p4runtime's controller
        wires h1<->h2 and never contacts s3. Measuring to those is an empty on-path set."""
        self.assertEqual("h3", self.mod.link_usage_applies(
            self.mod.EXERCISES["multicast"], "solution")[1])
        self.assertEqual("h2", self.mod.link_usage_applies(
            self.mod.EXERCISES["p4runtime"], "solution")[1])
        # everybody else takes the model's own last host, which is what None means here
        self.assertIsNone(self.mod.link_usage_applies(
            self.mod.EXERCISES["basic"], "solution")[1])

    def test_the_destination_reaches_the_shell_helper(self):
        seen = []
        self.mod.link_usage_cell("/pkg", "x", self.tmp, dst="h3",
                                 runner=lambda cmd, **kw: (seen.append(cmd), (0, ""))[1])
        self.assertIn("'h3'", seen[0][2])

    def test_the_cell_is_live_p1_commons_own_function_and_not_a_second_copy(self):
        """🔴 live-p1/05 runs link_usage_round three times and the driver runs it once per
        exercise. A Python re-implementation here would make 'the same program-independent
        cell over thirteen exercises' a comparison between two instruments."""
        seen = []

        def runner(cmd, cwd=None, timeout=None, env=None):
            seen.append(list(cmd))
            return 0, "LINK_USAGE basic/solution expect=follows onpath=3 rc=0\n"
        ok, out = self.mod.link_usage_cell("/pkg", "basic/solution", self.tmp, runner=runner)
        self.assertTrue(ok)
        self.assertEqual(1, len(seen))
        self.assertEqual("bash", seen[0][0])
        script = seen[0][2]
        self.assertIn("live-p1/_common.sh", script)
        self.assertIn("link_usage_round", script)
        self.assertIn("'/pkg'", script)
        self.assertIn("'follows'", script)

    def test_a_non_zero_rc_is_a_failed_cell_and_not_a_skip(self):
        """rc 2 from link_usage_round is 'no namespace / no sudo' -- a permission answer.
        Rendered as a skip it would read as a fabric whose link usage was fine."""
        ok, out = self.mod.link_usage_cell(
            "/pkg", "x", self.tmp,
            runner=lambda *_a, **_k: (2, "no namespace for h1"))
        self.assertFalse(ok)

    def test_the_control_asks_for_the_absent_variant(self):
        seen = []
        self.mod.link_usage_cell("/pkg", "x", self.tmp, expect="absent",
                                 runner=lambda cmd, **kw: (seen.append(cmd), (0, ""))[1])
        self.assertIn("'absent'", seen[0][2])

    def test_the_round_runs_it_after_the_steps_and_records_the_expectation(self):
        """Last, so a failure here cannot be confused with one of the exercise's own, and
        before the teardown because it needs the fabric."""
        mod = self.mod
        mod.PKG_ROOT = os.path.join(self.tmp, "packages")
        mod.NDT = "/fake/ndt"
        mod.PROXY_PY = "/fake/python"
        mod.CONVERT = "/fake/convert.py"
        mod.PREFLIGHT = "/fake/preflight.py"
        mod.HOST_KNOB = os.path.join(self.tmp, "host_count_override")
        mod.TELEMETRY_KNOB = os.path.join(self.tmp, "telemetry_override")
        mod.switch_state = lambda *_a, **_k: {"switches": {}}
        order = []
        mod.run = lambda cmd, cwd=None, timeout=None, env=None: (
            order.append(cmd[1] if cmd and cmd[0] == mod.NDT else "other"), (0, "ok"))[1]
        mod.link_usage_cell = lambda *a, **kw: (order.append("link_usage"), (False, "nope"))[1]

        class NoSteps(object):
            def __init__(self, *a, **kw):
                self.expects, self.steps = [], []

            def run(self):
                order.append("steps")
        mod.Steps = NoSteps
        mod.NdtwinHosts = lambda *a, **kw: StubHosts({"h1": "10.0.1.1"})
        args = Args()
        args.telemetry = None
        rc, pkg, state = mod.run_on_ndtwin("basic", "solution", "/ex",
                                           mod.EXERCISES["basic"], args,
                                           {"h1": "10.0.1.1"}, self.tmp, [], None)
        self.assertLess(order.index("steps"), order.index("link_usage"))
        self.assertLess(order.index("link_usage"), order.index("down"))
        names = [e.name for e in mod.run_on_ndtwin.expects]
        self.assertIn("G1  link usage follows the iperf path", names)
        self.assertNotIn("link_usage", order[:order.index("steps")])
        self.assertEqual("G1  link usage follows the iperf path", names[-1],
                         "the generic cell is the LAST expectation, after the exercise's own")
        self.assertFalse([e for e in mod.run_on_ndtwin.expects
                          if e.name.startswith("G1")][0].ok)
        # rc is the ROUND's rc (did the fabric come up, did the lab come back); a failed
        # expectation becomes exit 1 in main()'s verdict block, which is where every other
        # expectation is judged too.
        self.assertEqual(0, rc)


if __name__ == "__main__":                      # pragma: no cover
    unittest.main()
