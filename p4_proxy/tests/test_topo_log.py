#!/usr/bin/env python3
"""The bridge's log: the rotation, the tee, and the traceback that has to outlive the pane.

[Co-developed with claude code -- Adam]

What is on trial. `ndtwin-lab topo-start` runs ntg_bmv2_topo.py inside a root-owned tmux pane,
and on 2026-09-18 that script died of a KeyError before writing the switch manifest. tmux reaped
the session when the process went; `ndtwin-lab topo-out` then answered "no topo session"; `ndt
up` could only say `fabric did not come up: 0/4 switches, manifest missing` and "look at the
pane". The traceback naming the line existed nowhere on the machine. So the subject here is not
"logging" -- it is whether a crash leaves a readable artefact behind, and whether the
interactive prompt that shares that terminal still gets a terminal.

Three things a test can actually settle, and each has its own class:
  * the rotation is stack.sh's, including the two rules that are easy to drop -- an EMPTY log is
    not rotated (it would push a real generation off the end) and only the stamped generations
    this scheme writes are pruned;
  * bytes written to FILE DESCRIPTOR 1 -- not to `sys.stdout` -- reach both the terminal and the
    file. That distinction is the whole design: Mininet's logger binds `sys.stderr` at import
    and keeps that object, and `os.system` writes to the descriptor, so a `sys.stdout` wrapper
    would have captured this file's own prints and nothing else;
  * `stop()` gives the real descriptors back, and `record_traceback` writes to the file in
    EITHER state -- because the crash this module exists for can happen while NTG owns the
    terminal.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each of these
files directly and parses "Ran N tests".
"""

import os
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(PROXY_DIR, "mininet"))

import topo_log  # noqa: E402


class WhereTheLogGoesTest(unittest.TestCase):
    """The path, derived from this file's own location rather than from the environment."""

    def test_the_default_is_beside_the_proxy_and_kernel_logs(self):
        # stack.sh writes $LOG_DIR/p4_proxy.log, kernel.log and ryu.log under
        # $RUN_DIR/logs == <kernel dir>/.test_run/logs. The bridge's belongs with them.
        got = topo_log.default_path(kernel_dir="/somewhere/NDTwin-Kernel", env={})
        self.assertEqual(got, "/somewhere/NDTwin-Kernel/.test_run/logs/topo.log")

    def test_with_no_kernel_dir_it_names_this_checkout(self):
        # 🔴 Derived from __file__, because the bridge is launched by `sudo tmux` under a fixed
        # root environment that carries nothing an operator set -- the same reason
        # host_count_override and app_package_override are files. A tree named by anything else
        # is FINDING-01: a whole round run against the wrong checkout with nothing saying so.
        got = topo_log.default_path(env={})
        expected = os.path.join(os.path.dirname(PROXY_DIR), ".test_run", "logs", "topo.log")
        self.assertEqual(got, expected)

    def test_the_tests_override_wins(self):
        self.assertEqual(topo_log.default_path(env={"NDT_TOPO_LOG": "/tmp/x/topo.log"}),
                         "/tmp/x/topo.log")

    def test_the_keep_depth_is_stack_shs_five_and_cannot_be_driven_to_zero(self):
        # stack.sh rotate_log: `keep="${NDT_LOG_KEEP:-5}"`, and `(( keep >= 1 ))` or it goes
        # back to 5. Zero is the state O-4 is about -- one generation was never enough.
        self.assertEqual(topo_log.keep_depth(env={}), 5)
        self.assertEqual(topo_log.keep_depth(env={"NDT_LOG_KEEP": "2"}), 2)
        self.assertEqual(topo_log.keep_depth(env={"NDT_LOG_KEEP": "0"}), 5)
        self.assertEqual(topo_log.keep_depth(env={"NDT_LOG_KEEP": "nonsense"}), 5)


class RotationTest(unittest.TestCase):
    """stack.sh's rotate_log, in Python. The rules that are easy to lose are each a cell."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="topo_log_rotate.")
        self.log = os.path.join(self.tmp, "topo.log")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, text):
        with open(os.path.join(self.tmp, name), "w") as fh:
            fh.write(text)

    def test_a_log_with_content_is_moved_aside_under_a_stamp(self):
        self.write("topo.log", "the era that is ending\n")
        moved = topo_log.rotate(self.log, keep=5, env={})
        self.assertIsNotNone(moved)
        self.assertFalse(os.path.exists(self.log), "the old log is still in place")
        with open(moved) as fh:
            self.assertEqual(fh.read(), "the era that is ending\n")
        # 🔴 STAMPED, not numbered: `.prev`/`.prev2` mean something different an hour later, so
        # a path written down in a report stops being true. stack.sh's reasoning, kept.
        self.assertNotIn(".prev", moved)
        self.assertRegex(os.path.basename(moved), r"^topo\.log\.\d{8}-\d{6}(-\d+)?$")

    def test_an_empty_log_is_not_rotated(self):
        # A run that wrote nothing must not push a real generation off the end of the keep
        # window. In stack.sh the guard is at the CALL SITE (`if [[ -s "$log" ]]; then
        # rotate_log "$log"; fi`, stack.sh:509-510); here it is inside rotate(), which is the
        # one difference between the two and is why this cell asserts it of the function.
        self.write("topo.log", "")
        self.assertIsNone(topo_log.rotate(self.log, keep=5, env={}))
        self.assertTrue(os.path.exists(self.log))

    def test_a_log_that_does_not_exist_is_not_an_error(self):
        self.assertIsNone(topo_log.rotate(self.log, keep=5, env={}))

    def test_two_rotations_in_one_second_do_not_overwrite_each_other(self):
        self.write("topo.log", "first\n")
        first = topo_log.rotate(self.log, keep=5, env={})
        self.write("topo.log", "second\n")
        second = topo_log.rotate(self.log, keep=5, env={})
        self.assertNotEqual(first, second)
        with open(first) as fh:
            self.assertEqual(fh.read(), "first\n")

    def test_only_the_newest_keep_generations_survive(self):
        for stamp in ("20260101-000001", "20260102-000002", "20260103-000003",
                      "20260104-000004"):
            self.write("topo.log." + stamp, stamp)
        self.write("topo.log", "the newest\n")
        topo_log.rotate(self.log, keep=2, env={})
        left = sorted(n for n in os.listdir(self.tmp) if n.startswith("topo.log."))
        self.assertEqual(len(left), 2, f"kept {left}")
        self.assertIn("topo.log.20260104-000004", left,
                      "the newest pre-existing generation was pruned before the older ones")

    def test_a_generation_this_scheme_did_not_write_is_left_alone(self):
        # stack.sh: "Any pre-existing .prev/.prev2 is left alone rather than swept up, because
        # deleting a file this scheme did not create is not this function's decision to make."
        self.write("topo.log.prev", "somebody else's")
        self.write("topo.log", "the newest\n")
        topo_log.rotate(self.log, keep=1, env={})
        self.assertTrue(os.path.exists(os.path.join(self.tmp, "topo.log.prev")))


class TheTeeTest(unittest.TestCase):
    """The descriptor swap itself, exercised against real fds and a real file."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="topo_log_tee.")
        self.log = os.path.join(self.tmp, "logs", "topo.log")
        self.tee = topo_log.Tee(self.log, keep=5, env={})
        self.addCleanup(self._cleanup)
        self._suite_fds = {1: os.dup(1), 2: os.dup(2)}
        self.addCleanup(self._restore_the_suites_own_descriptors)

    def _cleanup(self):
        import shutil
        self.tee.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _restore_the_suites_own_descriptors(self):
        """Put fds 1 and 2 back whatever the code under test did with them.

        🔴 THIS IS NOT TIDINESS, IT IS WHAT MAKES THE MUTATION GATE ABLE TO SEE. Measured
        2026-09-18: with the `stop()` restore mutated away, every cell below leaves fd 1 and
        fd 2 pointing at a tee pipe for the REST OF THE SUITE. unittest's own report then goes
        through that pipe and is interleaved by the pump thread, so `FAIL: <name>` no longer
        starts a line and the gate -- which greps for exactly that -- scored M33 as a SURVIVOR
        (`34 mutations, 1 survived`, gate run with pipes on stdout/stderr and /dev/null on
        stdin). The mutation was being caught and the evidence was being shredded on the way
        out. A test that redirects this process's descriptors puts them back itself.

        Registered AFTER _cleanup so it runs BEFORE it: cleanups are LIFO, and the tee's own
        close() joins its pump, which only ends when the pipe's last write end is gone -- which
        is what restoring these descriptors does.
        """
        for fd, saved in sorted(self._suite_fds.items()):
            try:
                os.dup2(saved, fd)
                os.close(saved)
            except OSError:
                pass
        self._suite_fds = {}

    def contents(self):
        # join_timeout is short because this is a TEST calling stop(), not the teardown path.
        # The production value is five seconds and stays five seconds; under a mutant that
        # never restores fd 1 the pump never sees EOF, and ten cells each waiting the real
        # budget turned a 0.006 s suite into a 70 s one -- slow enough to start competing with
        # the mutation gate's own `timeout 300`.
        self.tee.stop(join_timeout=0.5)
        with open(self.log, "rb") as fh:
            return fh.read().decode("utf-8", "replace")

    def test_the_log_directory_is_created(self):
        self.assertTrue(self.tee.start())
        self.tee.stop()
        self.assertTrue(os.path.isfile(self.log))

    def test_bytes_written_to_descriptor_one_reach_the_file(self):
        # 🔴 THE DESCRIPTOR, NOT sys.stdout. `os.system('sudo mn -c')`, Mininet's logger (which
        # binds sys.stderr at import and keeps that object) and every child write here. A
        # sys.stdout wrapper would have caught this process's own prints and missed all of it,
        # which is why the tee is os.dup2 and not a wrapper.
        self.tee.start()
        os.write(1, b"MARKER-fd1-not-sys-stdout\n")
        self.assertIn("MARKER-fd1-not-sys-stdout", self.contents())

    def test_bytes_written_to_descriptor_two_reach_the_file(self):
        self.tee.start()
        os.write(2, b"MARKER-fd2\n")
        self.assertIn("MARKER-fd2", self.contents())

    def test_an_ordinary_print_reaches_the_file(self):
        self.tee.start()
        print("MARKER-print")
        sys.stdout.flush()
        self.assertIn("MARKER-print", self.contents())

    @staticmethod
    def ident(fd):
        st = os.fstat(fd)
        return (st.st_dev, st.st_ino)

    def assert_the_terminal_comes_back(self, terminal_fd, read_back, label):
        """Put `terminal_fd` on fds 1 and 2, tee over it, stop, and check they came back.

        🔴 THE TERMINAL IS ONE THIS TEST MADE. The first version compared fd 1 against
        whatever the harness happened to hand this process, which made the cell's
        discriminating power a property of how the suite was launched rather than of the code:
        it reddened under a tty and could not be relied on otherwise. A descriptor created
        here is the same descriptor under `python x.py`, under `-m unittest`, inside a command
        substitution and inside the mutation gate.

        Two independent assertions, because they fail for different reasons: fd 1 is the same
        open file it was (identity), and a byte written to it after the hand-over arrives on
        this test's own terminal and NOT in the log (behaviour -- an unrestored fd 1 is still
        the tee's pipe, so the byte would go through the pump into the file).
        """
        log = os.path.join(self.tmp, "restore-%s.log" % label)
        tee = topo_log.Tee(log, keep=5, env={})
        saved = {1: os.dup(1), 2: os.dup(2)}
        # No newline in the marker itself: a pty applies ONLCR, so the "\n" this test writes
        # comes back as "\r\n" and an equality on the whole line would be asserting termios
        # rather than anything about the tee.
        marker = b"MARKER-after-the-handover-" + label.encode()
        try:
            os.dup2(terminal_fd, 1)
            os.dup2(terminal_fd, 2)
            before = self.ident(1)
            started = tee.start()
            during = self.ident(1)
            tee.stop()
            after = self.ident(1)
            os.write(1, marker + b"\n")
        finally:
            # Back to the suite's own descriptors FIRST -- the tee's pump only ends when the
            # last write end of its pipe is gone, and fds 1 and 2 are those write ends.
            for fd, fd_saved in sorted(saved.items()):
                os.dup2(fd_saved, fd)
                os.close(fd_saved)
            tee.close()
        self.assertTrue(started, "the tee refused to start over a %s" % label)
        self.assertNotEqual(during, before, "start() did not redirect fd 1 at all")
        self.assertEqual(after, before,
                         "stop() left fd 1 pointing at the tee's pipe, so NTG's prompt would "
                         "render as plain text into it (prompt_toolkit create_output: "
                         "\"Stdout is not a TTY? Render as plain text.\")")
        with open(log, "rb") as fh:
            self.assertNotIn(marker, fh.read(),
                             "a byte written after the hand-over still went through the tee")
        self.assertIn(marker, read_back(),
                      "the byte written after the hand-over never reached the terminal")

    @staticmethod
    def drain(fd, timeout=2.0):
        """Whatever is readable on `fd` within `timeout`. Never blocks forever.

        A bare os.read() here would hang the whole suite on exactly the failure this cell is
        about -- nothing arriving -- and a gate cannot tell a hang from a catch.
        """
        import select
        deadline = time.monotonic() + timeout
        out = b""
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            out += chunk
            if out.rstrip():
                break
        return out

    def test_stop_gives_the_real_descriptors_back(self):
        # The pane shape: `ndtwin-lab topo-start` runs the bridge inside tmux, so fd 1 is a
        # pty, and that is the case NTG's prompt depends on.
        master, slave = os.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        self.assert_the_terminal_comes_back(
            slave, lambda: self.drain(master), "pty")

    def test_stop_gives_the_real_descriptors_back_with_no_tty_at_all(self):
        # 🔴 THE SHAPE THE GATE ITSELF RUNS IN, and the reason this cell exists: the mutation
        # gate captures its mutants with `out=$(...)`, so stdout is a pipe and there is no tty
        # anywhere. The restore has to be observable there too.
        read_fd, write_fd = os.pipe()
        self.addCleanup(os.close, read_fd)
        self.addCleanup(os.close, write_fd)
        self.assert_the_terminal_comes_back(
            write_fd, lambda: self.drain(read_fd), "pipe")

    def test_the_pump_does_not_share_a_descriptor_stop_will_close(self):
        # 🔴 THE GUARD FOR A DEFECT FOUND BY MEASUREMENT, 2026-09-18. Under a real pty the line
        # printed immediately before the hand-over to NTG's prompt reached the log and NOT the
        # terminal: the pump is a thread still draining when stop() runs, and the descriptor it
        # was writing to had already been closed in the same loop that restored fd 1. The lost
        # line is the visible half; the dangerous half is that a CLOSED descriptor number is
        # one the next open() in this process gets, so the pump would then be writing the
        # topology log into an unrelated file.
        #
        # 🔴 AND THIS IS THE ASSERTABLE HALF OF IT. The ordering itself (join before close)
        # could not be made to fail from inside one process -- both arms were measured three
        # times each through a file-backed fd 1 and both kept the line, because the writer
        # blocks on a full pipe and the pump has already drained it. What IS assertable, and is
        # what makes the ordering safe rather than lucky, is that the pump owns its descriptor.
        self.tee.start()
        self.assertIsNotNone(self.tee._terminal_fd)
        self.assertNotIn(self.tee._terminal_fd, list(self.tee._saved.values()),
                         "the pump writes to a descriptor stop() closes, so a late chunk goes "
                         "either nowhere or into whatever opened that number next")
        self.tee.stop()

    def test_the_last_line_before_stop_reaches_the_terminal(self):
        # The user-visible half of the cell above. Not a guard for the ordering -- see there --
        # but it is the property an operator cares about, so it is asserted rather than assumed.
        pane = os.path.join(self.tmp, "pane.txt")
        fd = os.open(pane, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
        saved = os.dup(1)
        try:
            os.dup2(fd, 1)
            os.close(fd)
            self.tee.start()
            print("MARKER-last-line-before-stop")
            sys.stdout.flush()
            self.tee.stop()
        finally:
            os.dup2(saved, 1)
            os.close(saved)
        with open(pane) as fh:
            self.assertIn("MARKER-last-line-before-stop", fh.read(),
                          "the pane lost the last thing printed before the hand-over")

    def test_nothing_written_after_stop_reaches_the_file(self):
        self.tee.start()
        print("MARKER-before-stop")
        sys.stdout.flush()
        self.tee.stop()
        print("MARKER-after-stop")
        sys.stdout.flush()
        with open(self.log, "rb") as fh:
            text = fh.read().decode("utf-8", "replace")
        self.assertIn("MARKER-before-stop", text)
        self.assertNotIn("MARKER-after-stop", text)

    def test_start_after_stop_resumes_without_rotating_the_file_away(self):
        # The teardown path: the tee comes back on after NTG's prompt returns, and what the
        # bring-up wrote must still be in the same file underneath it.
        self.tee.start()
        print("MARKER-bring-up")
        sys.stdout.flush()
        self.tee.stop()
        self.tee.start()
        print("MARKER-teardown")
        sys.stdout.flush()
        text = self.contents()
        self.assertIn("MARKER-bring-up", text)
        self.assertIn("MARKER-teardown", text)

    def test_a_traceback_is_written_while_the_tee_is_up(self):
        self.tee.start()
        try:
            raise KeyError("s5")
        except KeyError:
            self.tee.record_traceback()
        text = self.contents()
        self.assertIn("KeyError", text)
        self.assertIn("'s5'", text)

    def test_a_traceback_is_written_while_the_tee_is_down(self):
        # 🔴 The state NTG's prompt runs in. A crash there is exactly as invisible as the one
        # this whole module is about, so `record_traceback` has to reach the file with the
        # descriptors handed back.
        self.tee.start()
        self.tee.stop()
        try:
            raise KeyError("s5")
        except KeyError:
            self.tee.record_traceback()
        with open(self.log, "rb") as fh:
            text = fh.read().decode("utf-8", "replace")
        self.assertIn("KeyError", text)

    def test_a_traceback_is_written_exactly_once(self):
        # Written through stderr while the tee is up, and by hand while it is down -- doing
        # both in both states would double it, and a doubled traceback reads as two failures.
        # The text is supplied rather than raised: a real traceback carries its marker twice
        # (the source line AND the exception line), so counting one would be counting Python's
        # formatting rather than this function's writes -- which is how the first version of
        # this cell went red at 2 != 1.
        self.tee.start()
        self.tee.record_traceback(text="TRACEBACK-WRITTEN-ONCE\n")
        self.assertEqual(self.contents().count("TRACEBACK-WRITTEN-ONCE"), 1)

    def test_a_log_that_cannot_be_opened_does_not_stop_the_run(self):
        # A bring-up that refused to start because its LOG could not be opened would cost more
        # than the defect it reports. Reported once, on the terminal, and the caller goes on.
        said = []
        tee = topo_log.Tee(os.path.join(self.tmp, "not-a-dir-file", "x", "topo.log"),
                           keep=5, env={}, report=said.append)
        with open(os.path.join(self.tmp, "not-a-dir-file"), "w") as fh:
            fh.write("I am a file, not a directory\n")
        self.assertFalse(tee.start())
        self.assertFalse(tee.active)
        self.assertTrue(any("could not open the topology log" in s for s in said), said)
        # And the crash path still says something rather than swallowing the exception.
        tee.record_traceback(text="a traceback with nowhere to go\n")


if __name__ == "__main__":
    unittest.main()

# [Co-developed with claude code -- Adam]
