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
        # `[[ -s "$log" ]]` in stack.sh. A run that wrote nothing must not push a real
        # generation off the end of the keep window.
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

    def _cleanup(self):
        import shutil
        self.tee.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def contents(self):
        self.tee.stop()
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

    def test_stop_gives_the_real_descriptors_back(self):
        # The one property NTG's prompt depends on: prompt_toolkit's create_output returns a
        # PlainTextOutput the moment sys.stdout.isatty() is false (output/defaults.py, "Stdout
        # is not a TTY? Render as plain text."), and a plain-text prompt is not one
        # `ndtwin-lab topo-cmd` can drive. What that needs is the ORIGINAL descriptor back,
        # which is what this asserts -- fd 1 is the same open file it was before start().
        before = os.fstat(1)
        self.tee.start()
        during = os.fstat(1)
        self.tee.stop()
        after = os.fstat(1)
        self.assertNotEqual((during.st_dev, during.st_ino), (before.st_dev, before.st_ino),
                            "start() did not redirect fd 1 at all")
        self.assertEqual((after.st_dev, after.st_ino), (before.st_dev, before.st_ino),
                         "stop() left fd 1 pointing at the pipe, so the NTG prompt would "
                         "render as plain text into it")

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
