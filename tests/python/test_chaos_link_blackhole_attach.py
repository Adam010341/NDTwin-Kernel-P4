#!/usr/bin/env python3
"""W8-8: the chaos harness's `link_blackhole` must attach netem UNDER the shaper, not over it.

[Co-developed with claude code -- Adam]

The defect, found while fixing B-6 (scratch/overnight-2026-09-05/fix/W8-SUMMARY.md §6, §7.8),
in `doc/audit/2026-08-28_chaos-harness/harness/actions.py`:

    apply : `sudo tc qdisc add dev <iface> root netem loss 100%`  -- unconditional `root`
    verify: `"netem" in out and "loss 100%" in out`
    undo  : `sudo tc qdisc del dev <iface> root`
    note  : "reversible; undo removes the qdisc"

On a Mininet TCLink interface `add ... root netem` does not stack a layer -- it REPLACES htb,
and `del ... root` then leaves the kernel default rather than htb. Captured verbatim on
2026-08-13 in doc/audit/2026-08-12_overnight-review/C-live-ovs-runbook.md (P1), and the
NOPASSWD grants on this machine cannot put htb back. `tools/test_workflow/faults.sh` and
`include/utils/NetemLinkFault.hpp` both carry the rule that came out of that round; the harness
did not.

🔴 THE POINT OF THIS FILE IS THE SECOND HALF, NOT THE FIRST. Fixing only the attach point would
leave the shape that made it invisible: a G2 check whose criterion is true of both outcomes.
`netem ... loss 100%` is present when the netem hangs off the htb class AND when it has just
replaced htb, so the old verify would have said "the fault landed" on the interface it had
destroyed. So the cases below pin both directions:

  * the command that goes out on a shaped interface never says `root`   (the fault)
  * a root qdisc that was htb and is now netem FAILS verification       (the damage)
  * the undo deletes at the parent the netem is actually on             (the restore)
  * an interface with no shaper still gets `root`, because that is correct there, and a
    refusal everywhere would be a check with no resolving power         (the control)

The trees fed in are real captures where a real capture exists -- the 2026-08-13 runbook for
the shaped/destroyed/restored triple -- and otherwise the fixtures `tests/shell/test_faults.sh`
already drives the shell original with, so the port and the original are answering the same
questions. One case goes further and asks `faults.sh` itself, in a subshell, for its answer on
the same tree: this rule has three implementations in the repo now, and a port that has drifted
from the file it was ported from is the failure mode that matters.

Stdlib only. No kernel, no fabric, no build, no lab, and no `tc`: `probes.run` is replaced.
Run:  python3 tests/python/test_chaos_link_blackhole_attach.py -v
"""
from __future__ import annotations

import io
import contextlib
import os
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# Same seam as tests/python/test_chaos_runner_wiring.py: NDT_CHAOS_HARNESS points the import at
# a MUTATED COPY so tests/shell/mutate_chaos_blackhole_attach.sh can score this file without
# writing a byte into a worktree other sessions are reading. Unset in a normal run.
HARNESS = os.environ.get("NDT_CHAOS_HARNESS") or os.path.join(
    REPO, "doc", "audit", "2026-08-28_chaos-harness", "harness")
sys.path.insert(0, HARNESS)
# probes.py walks up from its own __file__ to find the repo; under the gate that copy lives in
# /tmp, where the walk finds nothing. Pinned so a mutation to the harness never also mutates
# the repo the harness is read against.
os.environ.setdefault("NDT_KERNEL_REPO", REPO)

import actions  # noqa: E402
import probes  # noqa: E402

FAULTS_SH = os.path.join(REPO, "tools", "test_workflow", "faults.sh")

# --- the trees -------------------------------------------------------------------------------
# 🔴 Verbatim from doc/audit/2026-08-12_overnight-review/C-live-ovs-runbook.md, P1 (2026-08-13,
# `tc qdisc show dev s1-eth2` on a live OVS fabric). Note `default 0x1`: the class id is printed
# in hex by this kernel, which is why the attach point is built by concatenating the token
# rather than reformatting it.
SHAPED = ("qdisc htb 5: root refcnt 15 r2q 10 default 0x1 direct_packets_stat 0 "
          "direct_qlen 1000")
#: what the interface looked like after `add ... root netem loss 100%` -- htb 5: and class 5:1
#: gone. Same source, same session.
SHAPER_REPLACED = "qdisc netem 8005: root refcnt 15 limit 1000 loss 100%"
#: and after the documented undo, `del ... root`: neither netem nor htb. Same source.
AFTER_DEL_ROOT = "qdisc noqueue 0: root refcnt 2"

# The device-named spelling of the same lines, which is what tests/shell/test_faults.sh drives
# the shell original with. Both spellings occur in this repo's evidence, so both are exercised.
SHAPED_DEV = ("qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10 default 1 direct_packets_stat 0\n"
              "qdisc pfifo_fast 0: dev s1-eth1 parent 5:1 bands 3")
#: the SAFE outcome: netem as a leaf of htb's default class, htb still standing. Built from the
#: recovery recipe the same runbook adopted for every later round
#: (`tc qdisc add dev <if> parent 5:1 handle 10: netem loss 100%`).
SHAPED_DEV_WITH_NETEM = (
    "qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10 default 1 direct_packets_stat 0\n"
    "qdisc netem 10: dev s1-eth1 parent 5:1 limit 1000 loss 100%")
#: an interface with no shaper at all -- the P4 testbed case, where `root` is the right answer.
UNSHAPED = "qdisc noqueue 0: root refcnt 2"
UNSHAPED_WITH_NETEM = "qdisc netem 10: root refcnt 2 limit 1000 loss 100%"


class FakeTc:
    """Stands in for probes.run: answers `tc qdisc show` from a script and records every argv.

    Recording the argv is the point. Half the claims here are about the COMMAND that goes out,
    not about the answer that comes back -- `add ... root netem` on a shaped interface succeeds,
    which is exactly why it went unnoticed for a month.
    """

    def __init__(self, trees, show_rc=0, add_rc=0, del_rc=0, show_err=""):
        self.trees = list(trees)          # successive answers to `tc qdisc show`
        self.show_rc = show_rc
        self.show_err = show_err
        self.add_rc = add_rc
        self.del_rc = del_rc
        self.calls: list[list[str]] = []

    def __call__(self, argv, timeout=5.0, env=None):
        self.calls.append(list(argv))
        words = [w for w in argv if w not in ("sudo", "-n")]
        if words[:2] == ["tc", "qdisc"] and words[2] == "show":
            tree = self.trees.pop(0) if len(self.trees) > 1 else self.trees[0]
            return self.show_rc, tree, self.show_err
        if words[:3] == ["tc", "qdisc", "add"]:
            return self.add_rc, "", "" if self.add_rc == 0 else "RTNETLINK answers: File exists"
        if words[:3] == ["tc", "qdisc", "del"]:
            return self.del_rc, "", "" if self.del_rc == 0 else "sudo: a password is required"
        raise AssertionError(f"the harness ran a command this test did not expect: {argv}")

    # -- what a test wants to ask about the recorded calls ------------------------------------
    def adds(self):
        return [c for c in self.calls if "add" in c]

    def dels(self):
        return [c for c in self.calls if "del" in c]

    def writes(self):
        """Every call that changes the machine, i.e. everything that is not a `show`."""
        return [c for c in self.calls if "show" not in c]


class TcSeam(unittest.TestCase):
    """Installs the fake in place of probes.run and takes it out again."""

    def setUp(self):
        self._real_run = probes.run

    def tearDown(self):
        probes.run = self._real_run

    def seam(self, *args, **kwargs) -> FakeTc:
        fake = FakeTc(*args, **kwargs)
        probes.run = fake
        return fake


# =============================================================================================
class AttachPointTest(unittest.TestCase):
    """Where the netem may go. The plan, before anything runs."""

    def test_a_shaped_interface_attaches_under_htb_and_never_at_root(self):
        where, why = actions.netem_attach_point(SHAPED)
        self.assertEqual(where, ["parent", "5:0x1"], why)
        self.assertNotIn("root", where,
                         "attaching at root on an htb interface replaces TCLink's shaping")

    def test_the_handle_and_the_default_class_are_read_not_hardcoded(self):
        tree = "qdisc htb 7: dev s2-eth3 root refcnt 2 default 20"
        self.assertEqual(actions.netem_attach_point(tree)[0], ["parent", "7:20"])

    def test_an_unshaped_interface_is_the_one_place_root_is_right(self):
        # The control. A rule that answered "refuse" everywhere would pass every case above and
        # detect nothing; the P4 runbook's root-netem recipe is valid precisely here.
        self.assertEqual(actions.netem_attach_point(UNSHAPED)[0], ["root"])

    def test_a_netem_already_present_is_refused_rather_than_stacked(self):
        where, why = actions.netem_attach_point(SHAPED_DEV_WITH_NETEM)
        self.assertIsNone(where)
        self.assertIn("already", why)

    def test_a_netem_that_has_already_replaced_the_shaper_is_refused_too(self):
        self.assertIsNone(actions.netem_attach_point(SHAPER_REPLACED)[0])

    def test_an_htb_root_with_no_default_class_is_refused_rather_than_guessed(self):
        where, why = actions.netem_attach_point("qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10")
        self.assertIsNone(where)
        self.assertIn("default", why)

    def test_an_unreadable_tree_is_refused(self):
        self.assertIsNone(actions.netem_attach_point("")[0])

    def test_the_port_gives_the_same_answers_as_faults_sh(self):
        """The rule has three implementations in this repo. This one is a PORT, and a port that
        has drifted from its original is the failure this asks about -- so the original is
        asked, in a subshell, on the same trees."""
        if not os.path.exists(FAULTS_SH):
            self.skipTest(f"{FAULTS_SH} is not in this tree")
        for tree, expected in ((SHAPED, "parent 5:0x1"),
                               (SHAPED_DEV, "parent 5:1"),
                               (UNSHAPED, "root"),
                               (SHAPED_DEV_WITH_NETEM, "unsafe"),
                               ("", "unsafe")):
            # TREE is copied out of $2 FIRST: inside a shell function $2 is the function's own
            # second argument, not the script's, so reading it in the stub would hand faults.sh
            # an empty tree and every answer would be "unsafe" -- a green that proves nothing.
            script = ('set -uo pipefail; source "$1" ; TREE="$2"; '
                      'show_qdisc() { printf "%s\\n" "$TREE"; } ; netem_attach_point dev0')
            out = subprocess.run(["bash", "-c", script, "bash", FAULTS_SH, tree],
                                 capture_output=True, text=True, timeout=30)
            shell_says = out.stdout.strip()
            self.assertEqual(shell_says, expected,
                             f"faults.sh itself answered {shell_says!r} for this tree")
            where, _ = actions.netem_attach_point(tree)
            ported = " ".join(where) if where else "unsafe"
            self.assertEqual(ported, shell_says,
                             f"the port and faults.sh disagree on:\n{tree}")


class DeletePointTest(unittest.TestCase):
    """Where the netem actually is, for the delete that removes it."""

    def test_a_netem_under_a_class_is_deleted_by_parent(self):
        self.assertEqual(actions.netem_delete_point(SHAPED_DEV_WITH_NETEM)[0], ["parent", "5:1"])

    def test_a_netem_at_root_is_deleted_at_root(self):
        self.assertEqual(actions.netem_delete_point(UNSHAPED_WITH_NETEM)[0], ["root"])

    def test_the_delete_carries_no_trailing_token_after_the_attach_point(self):
        # The NOPASSWD grant is matched literally: `qdisc del dev s*-eth* root` and
        # `... parent *`. One extra token and the revert dies with "a password is required",
        # leaving the fault in place. Measured 2026-08-13.
        for tree in (UNSHAPED_WITH_NETEM, SHAPED_DEV_WITH_NETEM):
            where, _ = actions.netem_delete_point(tree)
            self.assertNotIn("netem", where)

    def test_no_netem_means_do_not_touch_the_root_qdisc(self):
        where, why = actions.netem_delete_point(SHAPED_DEV)
        self.assertIsNone(where)
        self.assertIn("no netem", why)


# =============================================================================================
class ApplyTest(TcSeam):
    """The command that actually goes out."""

    def test_on_a_shaped_interface_the_command_never_says_root(self):
        """W8-8 itself."""
        tc = self.seam([SHAPED])
        out = actions.link_blackhole("s1-eth2").apply(False)
        self.assertTrue(out.ok, out.detail)
        self.assertEqual(len(tc.adds()), 1, tc.calls)
        sent = tc.adds()[0]
        self.assertNotIn("root", sent,
                         "this is the command that replaces TCLink's htb: " + " ".join(sent))
        self.assertEqual(sent[sent.index("dev") + 2: sent.index("netem")], ["parent", "5:0x1"])
        self.assertEqual(sent[-3:], ["netem", "loss", "100%"])

    def test_on_an_unshaped_interface_the_command_does_say_root(self):
        tc = self.seam([UNSHAPED])
        out = actions.link_blackhole("s1-eth3").apply(False)
        self.assertTrue(out.ok, out.detail)
        self.assertIn("root", tc.adds()[0])

    def test_a_netem_already_there_is_refused_and_nothing_is_run(self):
        tc = self.seam([SHAPED_DEV_WITH_NETEM])
        out = actions.link_blackhole("s1-eth1").apply(False)
        self.assertFalse(out.ok)
        self.assertEqual(tc.writes(), [], "a refusal that still ran tc is not a refusal")

    def test_an_unreadable_interface_is_a_failed_injection_not_a_silent_one(self):
        tc = self.seam([""], show_rc=1, show_err="Cannot find device \"s9-eth9\"")
        out = actions.link_blackhole("s9-eth9").apply(False)
        self.assertFalse(out.ok)
        self.assertEqual(tc.writes(), [])

    def test_the_dry_run_reports_the_attach_point_it_read_and_touches_nothing(self):
        tc = self.seam([SHAPED])
        out = actions.link_blackhole("s1-eth2").apply(True)
        self.assertTrue(out.dry_run)
        self.assertEqual(tc.writes(), [])
        self.assertIn("parent 5:0x1", out.detail)
        self.assertNotIn("root netem", out.detail,
                         "the dry run printed a command that would destroy the shaper")

    def test_a_dry_run_with_no_fabric_plans_nothing_rather_than_printing_a_false_command(self):
        # §5.2: a dry run makes no claim about the system, so an unreadable tree is not a
        # failure -- but it is not a plan either, and the old version printed
        # "would run: tc qdisc add dev X root netem loss 100%" whether or not that was true.
        tc = self.seam([""], show_rc=1, show_err="Cannot find device")
        out = actions.link_blackhole("s1-eth2").apply(True)
        self.assertTrue(out.dry_run)
        self.assertEqual(tc.writes(), [])
        self.assertIsNone(out.evidence.get("planned"))
        self.assertNotIn("qdisc add", out.detail,
                         "a dry run that never read the tree still quoted a command; that "
                         "printed line was the harness's only description of what it would do")


class VerifyTest(TcSeam):
    """G2, both halves: the fault landed, and the shaping survived."""

    def _applied(self, before, after, iface="s1-eth2"):
        """Run a real apply against `before`, then let verify see `after`."""
        tc = self.seam([before])
        action = actions.link_blackhole(iface)
        applied = action.apply(False)
        tc.trees = [after]
        return action, applied, tc

    def test_a_netem_under_the_shaper_verifies_and_says_the_shaper_survived(self):
        action, applied, _ = self._applied(SHAPED_DEV, SHAPED_DEV_WITH_NETEM, "s1-eth1")
        self.assertTrue(applied.ok, applied.detail)
        v = action.verify()
        self.assertTrue(v.ok, v.detail)
        self.assertEqual(v.evidence["root_qdisc_before"], "htb")
        self.assertEqual(v.evidence["root_qdisc_after"], "htb")

    def test_a_netem_that_replaced_the_shaper_is_not_a_successful_injection(self):
        """The half the old check could not see: `netem ... loss 100%` is true here too."""
        action, _, _ = self._applied(SHAPED, SHAPER_REPLACED)
        v = action.verify()
        self.assertIn("netem", SHAPER_REPLACED)
        self.assertIn("loss 100%", SHAPER_REPLACED)
        self.assertFalse(v.ok, "the interface was destroyed and this reported success")
        self.assertEqual(v.evidence["root_qdisc_before"], "htb")
        self.assertEqual(v.evidence["root_qdisc_after"], "netem")

    def test_root_netem_on_an_interface_that_had_no_shaper_still_verifies(self):
        # The control for the case above, and it is a real one: on an unshaped interface the
        # root qdisc IS replaced (noqueue -> netem) and that is fine, because `del ... root`
        # gives noqueue straight back -- the 2026-08-13 capture says so in as many words. A
        # check that read every root replacement as damage would refuse the whole P4 fabric.
        action, applied, _ = self._applied(UNSHAPED, UNSHAPED_WITH_NETEM, "s1-eth3")
        self.assertTrue(applied.ok, applied.detail)
        v = action.verify()
        self.assertTrue(v.ok, v.detail)
        self.assertEqual((v.evidence["root_qdisc_before"], v.evidence["root_qdisc_after"]),
                         ("noqueue", "netem"))

    def test_an_unfamiliar_root_qdisc_is_protected_rather_than_sacrificed(self):
        # Fail-closed. `tbf` is not on the list of qdiscs the kernel restores by itself, so
        # losing it reads as damage even though this harness has never met it. The alternative
        # -- treat anything unrecognised as disposable -- is how the htb case was missed.
        action, _, _ = self._applied("qdisc tbf 8: root refcnt 2 rate 10Mbit",
                                     "qdisc netem 8005: root refcnt 2 limit 1000 loss 100%")
        self.assertFalse(action.verify().ok)

    def test_a_fault_that_never_landed_fails(self):
        action, _, _ = self._applied(SHAPED_DEV, SHAPED_DEV, "s1-eth1")
        v = action.verify()
        self.assertFalse(v.ok)
        self.assertIn("no netem", v.detail)

    def test_verify_refuses_when_no_pre_injection_tree_was_recorded(self):
        # Without a before-tree the shaper half cannot be evaluated at all, and answering "ok"
        # then is the old behaviour wearing a new name.
        self.seam([SHAPED_DEV_WITH_NETEM])
        v = actions.link_blackhole("s1-eth1").verify()
        self.assertFalse(v.ok)
        self.assertIn("cannot tell", v.detail)


class UndoTest(TcSeam):
    """The restore, read off the tree rather than remembered."""

    def test_the_netem_is_removed_at_the_parent_it_is_on_never_at_root(self):
        tc = self.seam([SHAPED_DEV_WITH_NETEM])
        actions.link_blackhole("s1-eth1").undo()
        self.assertEqual(len(tc.dels()), 1, tc.calls)
        sent = tc.dels()[0]
        self.assertEqual(sent[-2:], ["parent", "5:1"])
        self.assertNotIn("root", sent,
                         "`del ... root` on a shaped interface takes htb with the netem")

    def test_a_netem_at_root_is_removed_at_root(self):
        tc = self.seam([UNSHAPED_WITH_NETEM])
        actions.link_blackhole("s1-eth3").undo()
        self.assertEqual(tc.dels()[0][-1], "root")

    def test_nothing_to_remove_means_no_tc_at_all(self):
        tc = self.seam([SHAPED_DEV])
        actions.link_blackhole("s1-eth1").undo()
        self.assertEqual(tc.writes(), [],
                         "an undo with nothing to undo must not delete the root qdisc")

    def test_a_refused_delete_is_said_out_loud(self):
        # The old undo swallowed every failure, so a fault left in place looked like a clean
        # round. `sudo: a password is required` is the measured way this fails (2026-08-13).
        tc = self.seam([SHAPED_DEV_WITH_NETEM], del_rc=1)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            actions.link_blackhole("s1-eth1").undo()
        self.assertEqual(len(tc.dels()), 1)
        self.assertIn("s1-eth1", err.getvalue())


class WiringTest(unittest.TestCase):
    """existence != wiring: the safe rule has to be what the Action actually calls."""

    def test_apply_verify_and_undo_are_the_same_shaper_aware_object(self):
        action = actions.link_blackhole("s1-eth1")
        for f in (action.apply, action.verify, action.undo):
            self.assertTrue(hasattr(f, "__self__"),
                            "apply/verify/undo must share one object, or verify has no "
                            "pre-injection tree to compare against")
        self.assertIs(action.apply.__self__, action.verify.__self__)
        self.assertIs(action.apply.__self__, action.undo.__self__)

    def test_the_action_is_still_marked_destructive_and_still_carries_an_undo(self):
        action = actions.link_blackhole("s1-eth1")
        self.assertTrue(action.destructive)
        self.assertIsNotNone(action.undo)


if __name__ == "__main__":
    unittest.main(verbosity=2)
