#!/usr/bin/env python3
"""
Tests for tools/p4_power_helper.py -- the root helper behind P4PowerStrategy (Phase 7).

[Co-developed with claude code -- Adam]

The helper is run as a real subprocess and judged only on its observable contract: exit code,
stdout (JSON on success, nothing else), stderr (the reason, on any refusal or failure), which
processes lived and died, and what the manifest file says afterwards.

Expected behaviour is taken from doc/2026-08-11_phase7_power_mechanism_design.md (decision 1: the hard
rules -- PID-only addressing re-verified against /proc comm AND cmdline, SIGTERM with no
SIGKILL escalation, no shell in launches, exit 0 only on observed outcomes, atomic manifest
replacement) and from Phase 7 of doc/2026-07-27_p4_bmv2_support_plan.md -- not from reading the helper.

Fixture trick, from the design doc's own truncation note: /proc/<pid>/comm is capped at 15
characters, so a *copy* of /bin/sleep named `simple_switch_grpc` runs with comm
`simple_switch_g` and an untruncated cmdline -- the same evidence a real bmv2 process leaves.
Every process here is spawned by this test and killed by exact PID; nothing name-matches,
because pkill-shaped cleanup is the precise defect this helper exists to bury.

Zombie note: the fakes are children of this test process, so a SIGTERM from the helper would
leave a zombie that still counts as alive in /proc until reaped -- which would make a
successful kill look like a hung one. Every fake gets a reaper thread so death is observable
to the helper the way it is for a real orphaned bmv2.

Run directly (no pytest):  python3 tests/python/test_p4_power_helper.py -v
"""

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "..", "tools", "p4_power_helper.py")
HELPER = os.path.abspath(HELPER)

def _free_port():
    """
    A port the OS says is free, asked for at the moment of use.

    [Co-developed with claude code -- Adam]
    This replaces `PORTS = iter(range(53101, 53199))`, a fixed band handed out from the same
    starting number in every process. A review caught
    test_a_switch_that_never_opens_its_port_can_still_be_stopped_by_off failing once in four runs:
    the helper reported success for a fixture whose whole purpose is never to bind, which can only
    happen if `port_listening` found something answering there.

    Three explanations were tested and none survived: another process squatting the port
    (`port_listening` *connects*, and a connection to someone else's client port is refused);
    TCP self-connect on loopback inside the ephemeral range (0 hits in 5880 attempts); and this
    suite leaking a listener (a full run leaves nothing behind).

    What is left is a long-lived listener that simply owns a number in whatever band the test
    picked. That is not hypothetical: on this machine Cursor listens on 127.0.0.1:23893, which
    sits inside the first band tried as a fix. A collision there is worse than a plain flake,
    because the helper *refuses* to launch behind an occupied port and exits 1 -- which is what
    this particular test asserts, so it would pass for entirely the wrong reason.

    Asking the OS removes the guessing: bind port 0, read what was assigned, release it. The
    residual race -- the kernel reassigning it between the release and the fixture's bind -- is a
    window of microseconds rather than a number some GUI application holds all day.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class _Ports:
    """Keeps `next(PORTS)` at the call sites; each next() is a fresh ask."""

    def __iter__(self):
        return self

    def __next__(self):
        return _free_port()


PORTS = _Ports()

_MODULE_DIR = None      # holds the fake binaries for the whole run
FAKE_SLEEP_SWITCH = None    # /bin/sleep copy named simple_switch_grpc
FAKE_SLEEP_GUI = None       # /bin/sleep copy named simple_switch_gui (comm collision)
FAKE_PY_SWITCH = None       # python3 copy named simple_switch_grpc (scriptable switch)


def setUpModule():
    global _MODULE_DIR, FAKE_SLEEP_SWITCH, FAKE_SLEEP_GUI, FAKE_PY_SWITCH
    _MODULE_DIR = tempfile.mkdtemp(prefix="ndtwin_p4helper_bin.")
    FAKE_SLEEP_SWITCH = os.path.join(_MODULE_DIR, "sleepy", "simple_switch_grpc")
    FAKE_SLEEP_GUI = os.path.join(_MODULE_DIR, "sleepy", "simple_switch_gui")
    FAKE_PY_SWITCH = os.path.join(_MODULE_DIR, "pysw", "simple_switch_grpc")
    os.makedirs(os.path.dirname(FAKE_SLEEP_SWITCH))
    os.makedirs(os.path.dirname(FAKE_PY_SWITCH))
    shutil.copy2("/bin/sleep", FAKE_SLEEP_SWITCH)
    shutil.copy2("/bin/sleep", FAKE_SLEEP_GUI)
    shutil.copy2(os.path.realpath(sys.executable), FAKE_PY_SWITCH)


def tearDownModule():
    if _MODULE_DIR:
        shutil.rmtree(_MODULE_DIR, ignore_errors=True)


def run_helper(args, manifest, timeout=45):
    """Run the helper as a subprocess against a fixture manifest; (rc, stdout, stderr)."""
    env = dict(os.environ, NDTWIN_P4_MANIFEST=manifest)
    proc = subprocess.run([sys.executable, HELPER] + list(args),
                          capture_output=True, text=True, env=env, timeout=timeout)
    return proc.returncode, proc.stdout, proc.stderr


class HelperTestBase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="ndtwin_p4helper_case.")
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.manifest = os.path.join(self.dir, "manifest.json")
        self._spawned = []

    def tearDown(self):
        # Exact PIDs only, and only PIDs this test created. Never a name match.
        for proc in self._spawned:
            if proc.poll() is None:
                try:
                    os.kill(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        for proc in self._spawned:
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
        # A helper "on" spawns a grandchild the Popen handles do not know about; its pidfile
        # (written by our own listener script) is the cleanup route.
        for name in os.listdir(self.dir):
            if name.endswith(".pid"):
                self._kill_pidfile(os.path.join(self.dir, name))

    def _kill_pidfile(self, pidfile):
        try:
            with open(pidfile) as fh:
                pid = int(fh.read().strip())
        except (OSError, ValueError):
            return
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    def spawn(self, argv):
        """Start a fake switch process with a reaper thread, so its death is visible in /proc."""
        proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        threading.Thread(target=proc.wait, daemon=True).start()
        self._spawned.append(proc)
        time.sleep(0.2)  # let /proc/<pid>/comm and cmdline settle
        self.assertIsNone(proc.poll(), f"fixture process {argv} died at startup")
        return proc

    def write_manifest(self, entries):
        with open(self.manifest, "w") as fh:
            json.dump(entries, fh)
        return os.stat(self.manifest).st_ino

    def read_manifest(self):
        with open(self.manifest) as fh:
            return json.load(fh)

    def entry(self, pid, port, argv="simple_switch_grpc --later"):
        return {"pid": pid, "device_id": 1, "grpc_port": port,
                "thrift_port": port + 500, "log_file": os.path.join(self.dir, "sw.log"),
                "argv": argv}

    def assert_dead(self, proc, msg):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return
            time.sleep(0.05)
        self.fail(msg)

    def assert_alive(self, proc, msg):
        time.sleep(0.2)  # give the reaper thread time to have reaped a just-killed process
        self.assertIsNone(proc.poll(), msg)


class UsageTest(HelperTestBase):
    def test_no_arguments_is_a_usage_error_exit_2(self):
        rc, out, err = run_helper([], self.manifest)
        self.assertEqual(rc, 2)
        self.assertEqual(out, "", "usage errors must not emit anything the kernel could "
                                  "mistake for a success JSON")
        self.assertIn("usage", err.lower())

    def test_an_unknown_verb_is_a_usage_error_exit_2(self):
        rc, out, err = run_helper(["restart", "s1"], self.manifest)
        self.assertEqual(rc, 2)
        self.assertEqual(out, "")


class OffRefusalTest(HelperTestBase):
    def test_a_switch_the_manifest_does_not_know_is_a_failure_not_a_success(self):
        self.write_manifest({})
        rc, out, err = run_helper(["off", "s1"], self.manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "", "a refusal must not print JSON the kernel would act on")
        self.assertNotEqual(err.strip(), "", "the reason belongs on stderr")

    def test_a_missing_manifest_is_a_failure(self):
        rc, out, err = run_helper(["off", "s1"], os.path.join(self.dir, "nope.json"))
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")

    def test_a_corrupt_manifest_is_a_controlled_failure_not_a_crash(self):
        with open(self.manifest, "w") as fh:
            fh.write("{ this is not json")
        rc, out, err = run_helper(["off", "s1"], self.manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertIn("ndtwin-p4-power:", err,
                      "a bad manifest must produce the helper's own diagnostic, not a "
                      "traceback -- the kernel logs stderr verbatim")

    def test_a_manifest_that_is_not_an_object_is_refused(self):
        with open(self.manifest, "w") as fh:
            json.dump(["s1", "s2"], fh)
        rc, out, err = run_helper(["off", "s1"], self.manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertIn("ndtwin-p4-power:", err)

    def test_a_symlinked_manifest_is_refused(self):
        # The design doc's trust boundary: the helper executes/kills based on this file, so a
        # path that is not the real manifest inode must not be believed. A symlink is the
        # cheapest way for another user to redirect the read.
        real = os.path.join(self.dir, "real.json")
        with open(real, "w") as fh:
            json.dump({"s1": self.entry(None, next(PORTS))}, fh)
        link = os.path.join(self.dir, "link.json")
        os.symlink(real, link)
        rc, out, err = run_helper(["off", "s1"], link)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")


class OffTest(HelperTestBase):
    def test_off_with_a_null_pid_reports_already_stopped_and_exits_0(self):
        # Idempotence is part of the contract: the twin's is_up and the manifest can disagree
        # after a crash, and "already stopped" is a true answer, not an error.
        self.write_manifest({"s1": self.entry(None, next(PORTS))})
        rc, out, err = run_helper(["off", "s1"], self.manifest)
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["status"], "already-stopped")

    def test_off_with_a_dead_pid_reports_already_stopped_and_nulls_the_manifest_pid(self):
        probe = subprocess.Popen(["/bin/sleep", "0.05"])
        probe.wait()
        dead_pid = probe.pid
        with self.assertRaises(ProcessLookupError):
            os.kill(dead_pid, 0)  # confirm the PID is actually free before handing it over
        self.write_manifest({"s1": self.entry(dead_pid, next(PORTS))})
        rc, out, err = run_helper(["off", "s1"], self.manifest)
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["status"], "already-stopped")
        self.assertIsNone(self.read_manifest()["s1"]["pid"],
                          "a pid known to be gone must not survive in the manifest, or the "
                          "next 'on' will refuse to start the switch")

    def test_off_kills_exactly_the_named_switch_and_nothing_else(self):
        # Three identically-named processes: the target, a second manifest entry, and one the
        # manifest has never heard of. The named PID dies; both bystanders live. This is the
        # defect the helper exists to bury -- `pkill -f simple_switch_grpc` scored 10/10.
        port_a, port_b, port_c = next(PORTS), next(PORTS), next(PORTS)
        target = self.spawn([FAKE_SLEEP_SWITCH, "600", str(port_a)])
        decoy_listed = self.spawn([FAKE_SLEEP_SWITCH, "600", str(port_b)])
        decoy_unlisted = self.spawn([FAKE_SLEEP_SWITCH, "600", str(port_c)])
        # s2 first: a helper that grabs "some entry" instead of the named one must be caught.
        ino_before = self.write_manifest({"s2": self.entry(decoy_listed.pid, port_b),
                                          "s1": self.entry(target.pid, port_a)})

        rc, out, err = run_helper(["off", "s1"], self.manifest)

        self.assertEqual(rc, 0, f"stderr was: {err}")
        report = json.loads(out)
        self.assertEqual(report["status"], "stopped")
        self.assertEqual(report.get("name"), "s1")
        self.assert_dead(target, "exit 0 with the named switch still running is exactly the "
                                 "dishonest success the design forbids")
        self.assert_alive(decoy_listed, "a different manifest entry was killed")
        self.assert_alive(decoy_unlisted, "a process outside the manifest was killed -- "
                                          "that is name-matching, the forbidden mechanism")
        after = self.read_manifest()
        self.assertIsNone(after["s1"]["pid"], "the stopped switch's pid must become null")
        self.assertEqual(after["s2"]["pid"], decoy_listed.pid,
                         "the other entry must be untouched")
        self.assertNotEqual(os.stat(self.manifest).st_ino, ino_before,
                            "the manifest must be atomically replaced (new inode), never "
                            "truncated in place")

    def test_off_refuses_a_reused_pid_whose_comm_is_not_bmv2(self):
        # PID reuse where the impostor *claims* to be bmv2 in argv[0] but the kernel's comm
        # says otherwise. Both checks are required by the design; this one can only be caught
        # by comm.
        port = next(PORTS)
        impostor = self.spawn(["bash", "-c",
                               f"exec -a simple_switch_grpc sleep 600 {port}"])
        self.write_manifest({"s1": self.entry(impostor.pid, port)})
        rc, out, err = run_helper(["off", "s1"], self.manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assert_alive(impostor, "a process whose comm is not bmv2 was signalled")
        self.assertEqual(self.read_manifest()["s1"]["pid"], impostor.pid,
                         "a refusal must not edit the manifest")

    def test_off_refuses_a_comm_collision_from_a_different_binary(self):
        # comm truncates to 15 chars, so `simple_switch_gui` also shows `simple_switch_g`.
        # The untruncated cmdline is what settles it, and the design requires both checks.
        port = next(PORTS)
        collider = self.spawn([FAKE_SLEEP_GUI, "600", str(port)])
        self.write_manifest({"s1": self.entry(collider.pid, port)})
        rc, out, err = run_helper(["off", "s1"], self.manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assert_alive(collider, "a same-comm process from a different binary was killed")

    def test_off_refuses_a_bmv2_that_is_some_other_switch(self):
        # Right binary, wrong instance: the manifest's grpc port is the thing that ties a PID
        # to *this* switch, and this process's cmdline does not carry it.
        port = next(PORTS)
        other = self.spawn([FAKE_SLEEP_SWITCH, "600"])
        self.write_manifest({"s1": self.entry(other.pid, port)})
        rc, out, err = run_helper(["off", "s1"], self.manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assert_alive(other, "a bmv2 whose cmdline does not carry this switch's gRPC "
                                 "port was signalled")

    def test_off_never_escalates_past_sigterm(self):
        # A switch that ignores SIGTERM is evidence of a different problem; the design says
        # report it, do not silence it with SIGKILL. Runs the helper's full TERM-wait
        # (about 10s) -- that wait is the behaviour under test.
        port = next(PORTS)
        ready = os.path.join(self.dir, "ready")
        code = ("import signal, sys, time\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "open(sys.argv[1], 'w').write('r')\n"
                "time.sleep(90)  # bounded: a run killed before tearDown must not outlive it for long\n")
        stubborn = self.spawn([FAKE_PY_SWITCH, "-c", code, ready, str(port)])
        deadline = time.monotonic() + 5
        while not os.path.exists(ready) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(os.path.exists(ready), "fixture never armed its SIGTERM handler")
        self.write_manifest({"s1": self.entry(stubborn.pid, port)})

        rc, out, err = run_helper(["off", "s1"], self.manifest)

        self.assertEqual(rc, 1, "a switch that survives SIGTERM is a reported failure, "
                                "never a success")
        self.assertEqual(out, "")
        self.assertNotEqual(err.strip(), "")
        self.assert_alive(stubborn, "the process died anyway: something escalated beyond "
                                    "SIGTERM, which the design forbids in every code path")


class OnTest(HelperTestBase):
    def listener_argv(self, port, pidfile, extra=""):
        script = os.path.join(self.dir, "listen.py")
        if not os.path.exists(script):
            with open(script, "w") as fh:
                fh.write("import os, socket, sys, time\n"
                         "port, pidfile = int(sys.argv[1]), sys.argv[2]\n"
                         "open(pidfile, 'w').write(str(os.getpid()))\n"
                         "s = socket.socket()\n"
                         "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
                         "s.bind(('127.0.0.1', port)); s.listen(5)\n"
                         "time.sleep(90)  # bounded: a run killed before tearDown must not outlive it for long\n")
        return f"{FAKE_PY_SWITCH} {script} {port} {pidfile}{extra}"

    def on_entry(self, port, argv):
        e = self.entry(None, port, argv=argv)
        e["log_file"] = os.path.join(self.dir, "on.log")
        return e

    def test_on_starts_the_switch_and_exits_0_only_once_the_port_listens(self):
        port = next(PORTS)
        pidfile = os.path.join(self.dir, "sw.pid")
        ino_before = self.write_manifest(
            {"s1": self.on_entry(port, self.listener_argv(port, pidfile))})

        rc, out, err = run_helper(["on", "s1"], self.manifest)

        self.assertEqual(rc, 0, f"stderr was: {err}")
        report = json.loads(out)
        self.assertEqual(report["status"], "started")
        # Exit 0 means the observed outcome, so the port must be accepting *now*.
        import socket
        with socket.create_connection(("127.0.0.1", port), timeout=2):
            pass
        after = self.read_manifest()
        self.assertEqual(after["s1"]["pid"], report.get("pid"),
                         "the manifest must record the pid the helper reported, or the next "
                         "'off' will kill the wrong thing or nothing")
        self.assertIsInstance(after["s1"]["pid"], int)
        self.assertNotEqual(os.stat(self.manifest).st_ino, ino_before,
                            "the new pid must land via atomic replacement (new inode)")

    def test_on_does_not_pass_the_argv_through_a_shell(self):
        # Shell metacharacters in the manifest argv must be inert argument bytes. If a shell
        # ever interprets them, the marker appears -- and so does root command injection.
        port = next(PORTS)
        pidfile = os.path.join(self.dir, "sw.pid")
        marker = os.path.join(self.dir, "injected")
        # '&' rather than ';' so that under a shell the injected command runs immediately
        # instead of queueing behind the long-lived switch process -- a shell would otherwise
        # only reveal itself 10 minutes after the test ended.
        argv = self.listener_argv(port, pidfile, extra=f" & /bin/touch {marker} ;")
        self.write_manifest({"s1": self.on_entry(port, argv)})

        rc, out, err = run_helper(["on", "s1"], self.manifest)

        self.assertEqual(rc, 0, f"stderr was: {err}")
        self.assertEqual(json.loads(out)["status"], "started")
        self.assertFalse(os.path.exists(marker),
                         "the metacharacters were interpreted: the launch went through a "
                         "shell, which the design forbids because the manifest argv runs "
                         "as root")

    def test_on_refuses_an_argv_that_is_not_bmv2_without_executing_it(self):
        marker = os.path.join(self.dir, "ran")
        port = next(PORTS)
        self.write_manifest({"s1": self.on_entry(port, f"/bin/touch {marker}")})
        rc, out, err = run_helper(["on", "s1"], self.manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertFalse(os.path.exists(marker),
                         "the foreign argv was executed -- as root in real use; it must be "
                         "refused before launch, not judged by its exit")

    def test_on_refuses_while_the_recorded_pid_is_still_alive(self):
        port = next(PORTS)
        pidfile = os.path.join(self.dir, "sw.pid")
        live = self.spawn([FAKE_SLEEP_SWITCH, "600", str(port)])
        self.write_manifest(
            {"s1": dict(self.on_entry(port, self.listener_argv(port, pidfile)),
                        pid=live.pid)})
        rc, out, err = run_helper(["on", "s1"], self.manifest)
        self.assertEqual(rc, 1, "starting a second instance behind a live one leaves two "
                                "processes fighting over one port")
        self.assertEqual(out, "")
        self.assertFalse(os.path.exists(pidfile), "a second instance was launched anyway")

    def test_on_with_no_recorded_argv_is_a_failure_naming_the_gap(self):
        port = next(PORTS)
        e = self.on_entry(port, "unused")
        del e["argv"]
        self.write_manifest({"s1": e})
        rc, out, err = run_helper(["on", "s1"], self.manifest)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertIn("ndtwin-p4-power:", err,
                      "the gap must be reported as the helper's own diagnostic, not as a "
                      "traceback from tripping over it later")
        self.assertIn("argv", err, "the reason must name what the manifest is missing")

    def test_on_that_never_opens_the_port_fails_rather_than_claiming_success(self):
        # A process that runs but never binds is exactly the "twin says Up, dataplane dead"
        # lie; exit 0 here would feed it to the kernel. Runs the helper's full port-wait
        # (about 15s) -- the wait is the behaviour under test.
        port = next(PORTS)
        pidfile = os.path.join(self.dir, "sw.pid")
        script = os.path.join(self.dir, "noport.py")
        with open(script, "w") as fh:
            fh.write("import os, sys, time\n"
                     "open(sys.argv[2], 'w').write(str(os.getpid()))\n"
                     "time.sleep(90)  # bounded: a run killed before tearDown must not outlive it for long\n")
        argv = f"{FAKE_PY_SWITCH} {script} {port} {pidfile}"
        self.write_manifest({"s1": self.on_entry(port, argv)})

        rc, out, err = run_helper(["on", "s1"], self.manifest)

        self.assertEqual(rc, 1)
        self.assertEqual(out, "", "no port, no 'started' -- exit 0 is reserved for the "
                                  "observed outcome")
        self.assertNotEqual(err.strip(), "")



def pid_is_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class OnTimeoutLeavesAnAddressableProcessTest(HelperTestBase):
    """
    What happens to a bmv2 that starts but does not open its port in time.

    [Co-developed with claude code -- Adam]
    The helper deliberately does not kill it: doing so would race a switch that is merely slow.
    It says so, and tells the caller to run "off" once they have decided. That advice is only
    honest if "off" can still reach the process -- which means the pid has to be in the manifest
    by the time "on" gives up, not only on the path where the port opened.
    """

    def slow_listener_argv(self, port, pidfile, delay_s):
        script = os.path.join(self.dir, "slow.py")
        if not os.path.exists(script):
            with open(script, "w") as fh:
                fh.write("import os, socket, sys, time\n"
                         "port, pidfile, delay = int(sys.argv[1]), sys.argv[2], float(sys.argv[3])\n"
                         "open(pidfile, 'w').write(str(os.getpid()))\n"
                         "time.sleep(delay)\n"
                         "s = socket.socket()\n"
                         "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
                         "s.bind(('127.0.0.1', port)); s.listen(5)\n"
                         "time.sleep(90)  # bounded: a run killed before tearDown must not outlive it for long\n")
        return f"{FAKE_PY_SWITCH} {script} {port} {pidfile} {delay_s}"

    def silent_argv(self, port, pidfile):
        """A switch that runs forever and never binds -- the timeout path."""
        script = os.path.join(self.dir, "silent.py")
        if not os.path.exists(script):
            with open(script, "w") as fh:
                fh.write("import os, sys, time\n"
                         "port, pidfile = int(sys.argv[1]), sys.argv[2]\n"
                         "open(pidfile, 'w').write(str(os.getpid()))\n"
                         "time.sleep(90)  # bounded: a run killed before tearDown must not outlive it for long\n")
        return f"{FAKE_PY_SWITCH} {script} {port} {pidfile}"

    def on_entry(self, port, argv):
        e = self.entry(None, port, argv=argv)
        e["log_file"] = os.path.join(self.dir, "on.log")
        return e

    def test_the_pid_is_recorded_before_on_finishes_waiting_for_the_port(self):
        port = next(PORTS)
        pidfile = os.path.join(self.dir, "sw.pid")
        self.write_manifest({"s1": self.on_entry(port, self.slow_listener_argv(port, pidfile, 6))})

        result = {}

        def go():
            result["rc"], result["out"], result["err"] = run_helper(["on", "s1"], self.manifest)

        thread = threading.Thread(target=go)
        thread.start()
        self.addCleanup(thread.join)

        recorded = None
        deadline = time.monotonic() + 4  # comfortably inside the switch's 6 s bind delay
        while time.monotonic() < deadline:
            try:
                recorded = self.read_manifest()["s1"]["pid"]
            except (OSError, ValueError, KeyError):
                recorded = None
            if isinstance(recorded, int):
                break
            time.sleep(0.1)

        still_waiting = thread.is_alive()
        thread.join()

        self.assertIsInstance(
            recorded, int,
            "the manifest still had no pid while 'on' was waiting for the port. Every exit "
            "from that wait other than success leaves a process the helper can no longer name")
        self.assertTrue(
            still_waiting,
            "'on' had already returned, so this proves nothing about the waiting window")
        self.assertEqual(result["rc"], 0, f"stderr was: {result['err']}")

    def test_a_switch_that_never_opens_its_port_can_still_be_stopped_by_off(self):
        # Costs the full PORT_WAIT_S. Worth it: this is the whole failure -- a root helper that
        # creates a process it can never address again, and then reports success for every
        # subsequent request to stop it.
        port = next(PORTS)
        pidfile = os.path.join(self.dir, "sw.pid")
        self.write_manifest({"s1": self.on_entry(port, self.silent_argv(port, pidfile))})

        rc, out, err = run_helper(["on", "s1"], self.manifest, timeout=60)
        self.assertEqual(rc, 1, "a switch that never opened its port must not report success")
        self.assertIn("left running", err)

        recorded = self.read_manifest()["s1"]["pid"]
        self.assertIsInstance(
            recorded, int,
            "'on' gave up without recording the pid, so the running bmv2 it created is "
            "unreachable: the advised 'off' reads pid=None and reports already-stopped")
        self.assertTrue(pid_is_alive(recorded), "fixture process died; the test proves nothing")

        rc2, out2, err2 = run_helper(["off", "s1"], self.manifest)

        self.assertEqual(rc2, 0, f"stderr was: {err2}")
        self.assertEqual(
            json.loads(out2)["status"], "stopped",
            "'off' answered already-stopped for a process that was running -- exit 0 while "
            "the switch keeps forwarding and keeps its gRPC port")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and pid_is_alive(recorded):
            time.sleep(0.05)
        self.assertFalse(pid_is_alive(recorded),
                         "'off' exited 0 before the process was gone")

    def test_a_switch_that_exits_before_binding_leaves_no_pid_behind(self):
        # The other exit from the wait: recording the pid early must not leave the manifest
        # naming a corpse, or the next "on" has to reason about a dead pid.
        port = next(PORTS)
        script = os.path.join(self.dir, "diesfast.py")
        with open(script, "w") as fh:
            fh.write("import sys\nsys.exit(3)\n")
        self.write_manifest(
            {"s1": self.on_entry(port, f"{FAKE_PY_SWITCH} {script} {port}")})

        rc, out, err = run_helper(["on", "s1"], self.manifest, timeout=60)

        self.assertEqual(rc, 1)
        self.assertIn("status 3", err)
        self.assertIsNone(self.read_manifest()["s1"]["pid"],
                          "the manifest names a pid that has already exited")

if __name__ == "__main__":
    unittest.main()


class OverridePrefixTest(HelperTestBase):
    """
    Power-ON under a bmv2 binary override.

    [Co-developed with claude code -- Adam]
    A topology running an override records its argv with a shell env prefix:
    "LD_LIBRARY_PATH=<prefix>/lib <prefix>/bin/simple_switch_grpc -i 1@s5-eth1 ...". This launch
    has no shell, so that prefix used to fail the basename check and power-ON simply did not
    work while an override was in place -- deliberately, on the reasoning that a loud refusal
    beats launching the fast binary against stock libraries via the ldconfig cache.

    The cost of that refusal was larger than it looked: the Energy-Saving App exists to power
    switches off *and back on*, so under an override it could only ever shut the fabric down.
    Found live 2026-08-18 by powering s5 off and being unable to bring it back.

    The prefix is now stripped and the library path derived from the binary instead -- the same
    dirname(binary)/../lib rule the topology's resolve_bmv2_launcher applies, so the two cannot
    drift. Derived rather than read from the manifest because that adds nothing to what is
    already trusted: load_manifest has established root ownership, and the basename check admits
    any .../simple_switch_grpc, so the manifest already names the binary this runs as root.
    """

    # Borrowed rather than inherited: subclassing OnTest would re-run its five tests under a
    # second name, which inflates the suite count for nothing.
    listener_argv = OnTest.listener_argv
    on_entry = OnTest.on_entry

    def _prefixed(self, port, pidfile, lib_dir):
        plain = self.listener_argv(port, pidfile)
        return f"LD_LIBRARY_PATH={lib_dir} {plain}"

    def test_an_env_prefixed_argv_still_starts_the_switch(self):
        # The whole point: this is what an override's manifest looks like, and it used to be
        # refused outright.
        port = next(PORTS)
        pidfile = os.path.join(self.dir, "sw.pid")
        lib_dir = os.path.join(os.path.dirname(os.path.dirname(FAKE_PY_SWITCH)), "lib")
        self.write_manifest({"s1": self.on_entry(port, self._prefixed(port, pidfile, lib_dir))})

        rc, out, err = run_helper(["on", "s1"], self.manifest)

        self.assertEqual(rc, 0, f"stderr was: {err}")
        self.assertEqual(json.loads(out)["status"], "started")

    def test_the_library_path_is_derived_from_the_binary_not_taken_from_the_manifest(self):
        # A sibling <prefix>/lib exists -> the child must see LD_LIBRARY_PATH pointing at it,
        # whatever the manifest's own prefix said. Without this the fast binary would resolve
        # its libraries through the ldconfig cache and silently run against the stock build.
        port = next(PORTS)
        envfile = os.path.join(self.dir, "child_env")
        script = os.path.join(self.dir, "dumpenv.py")
        with open(script, "w") as fh:
            fh.write("import os, socket, sys, time\n"
                     "port, envfile = int(sys.argv[1]), sys.argv[2]\n"
                     "open(envfile, 'w').write(os.environ.get('LD_LIBRARY_PATH', '<unset>'))\n"
                     "s = socket.socket()\n"
                     "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
                     "s.bind(('127.0.0.1', port)); s.listen(5)\n"
                     "time.sleep(90)\n")
        expected_lib = os.path.join(os.path.dirname(os.path.dirname(FAKE_PY_SWITCH)), "lib")
        os.makedirs(expected_lib, exist_ok=True)
        argv = f"LD_LIBRARY_PATH=/wrong/place {FAKE_PY_SWITCH} {script} {port} {envfile}"
        self.write_manifest({"s1": self.on_entry(port, argv)})

        rc, _, err = run_helper(["on", "s1"], self.manifest)
        self.assertEqual(rc, 0, f"stderr was: {err}")

        with open(envfile) as fh:
            seen = fh.read()
        self.assertEqual(seen, expected_lib,
                         "the child must get the path derived from its own binary, not the "
                         "manifest's value -- /wrong/place proves the manifest was consulted")

    def test_no_sibling_lib_directory_means_no_library_path_is_invented(self):
        # The stock build is on the default loader path and has no <prefix>/lib beside it.
        # Setting LD_LIBRARY_PATH to a directory that does not exist is not harmless: it
        # changes resolution order for every library the process loads.
        port = next(PORTS)
        envfile = os.path.join(self.dir, "child_env2")
        script = os.path.join(self.dir, "dumpenv2.py")
        with open(script, "w") as fh:
            fh.write("import os, socket, sys, time\n"
                     "port, envfile = int(sys.argv[1]), sys.argv[2]\n"
                     "open(envfile, 'w').write(os.environ.get('LD_LIBRARY_PATH', '<unset>'))\n"
                     "s = socket.socket()\n"
                     "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
                     "s.bind(('127.0.0.1', port)); s.listen(5)\n"
                     "time.sleep(90)\n")
        bare = os.path.join(self.dir, "nolibs", "simple_switch_grpc")
        os.makedirs(os.path.dirname(bare), exist_ok=True)
        shutil.copy2(os.path.realpath(sys.executable), bare)
        self.write_manifest(
            {"s1": self.on_entry(port, f"{bare} {script} {port} {envfile}")})

        rc, _, err = run_helper(["on", "s1"], self.manifest)
        self.assertEqual(rc, 0, f"stderr was: {err}")

        with open(envfile) as fh:
            self.assertEqual(fh.read(), "<unset>",
                             "no sibling lib/ means the loader's own search order stands")

    def test_an_argv_that_is_only_assignments_is_still_refused(self):
        # Stripping must not turn a nonsense entry into an empty argv that gets launched as
        # something else. The basename check still has to run on what survives.
        port = next(PORTS)
        self.write_manifest({"s1": self.on_entry(port, "LD_LIBRARY_PATH=/x FOO=bar")})

        rc, _, err = run_helper(["on", "s1"], self.manifest)

        self.assertNotEqual(rc, 0)
        self.assertIn("simple_switch_grpc", err)

    def test_an_absolute_path_containing_an_equals_sign_is_not_mistaken_for_an_assignment(self):
        # The strip is anchored on "not absolute", so a binary under a directory with '=' in
        # its name stays the command rather than being eaten as an assignment.
        port = next(PORTS)
        pidfile = os.path.join(self.dir, "sw.pid")
        odd = os.path.join(self.dir, "a=b", "simple_switch_grpc")
        os.makedirs(os.path.dirname(odd), exist_ok=True)
        shutil.copy2(os.path.realpath(sys.executable), odd)
        script = os.path.join(self.dir, "listen.py")
        self.listener_argv(port, pidfile)  # writes listen.py
        self.write_manifest({"s1": self.on_entry(port, f"{odd} {script} {port} {pidfile}")})

        rc, out, err = run_helper(["on", "s1"], self.manifest)

        self.assertEqual(rc, 0, f"stderr was: {err}")
        self.assertEqual(json.loads(out)["status"], "started")
