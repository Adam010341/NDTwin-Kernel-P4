#!/usr/bin/env python3
"""E-4: the chaos harness's `needs_opt_in` must gate EVERY action, not only the controls.

[Co-developed with claude code -- Adam]

The defect, in `doc/audit/2026-08-28_chaos-harness/harness/`:

    actions.py  declares `Action.needs_opt_in` and documents it as the per-action safety gate
    chaos.py    consulted it in ONE branch of ONE loop -- `gate_g1_controls`, live path only

So an action that is not a positive control could carry the field and run ungated, and one
did: `link_blackhole` is `destructive=True`, puts `tc netem loss 100%` on a live link, and its
undo depends on a sudo grant whose `parent` form has never been observed to be accepted on this
machine. It had no opt-in at all, and the path that reaches it -- `--dry-run` -- asked no
question before running it. Same family as #71 and #75: `existence != wiring`. A field declared
in one file and enforced in one branch of another is a safety label, not a gate.

🔴 The fix is not "add a flag to the blackhole". A flag added to an action nobody asks about
would be exactly the defect again, one action later. So the decision moved into
`actions.opt_in_refusal` -- ONE predicate, ONE sentence -- and both entry points ask it:
`gate_g1_controls` for the controls, `injection_round` for everything else. This file pins both
halves, and the second is the one that would rot silently:

  * the decision itself: default-deny, the flag name is in the sentence
  * `injection_round` refuses BEFORE apply, dry run included, and runs no command at all
  * `gate_g1_controls` refuses with the IDENTICAL sentence (one decision, not two that agree)
  * the flag reaches the action through `main()`'s argv -- the wiring, end to end
  * `link_blackhole` is gated AND still absent from `CHAOS_ACTIONS`, which is Adam's ruling of
    2026-09-07 (DECISIONS.md, grill §4E, E-4): gating it and adding it to `--full` are two
    questions and they got two answers.

Why the dry run is inside the gate, since it looks like the opposite of `04` §5.2 ("the allow
path needs a dry run, and the runner exercises it"): the blackhole is in no list, so the dry
run is the ONLY path that reaches it. An opt-in that exempted dry runs would gate nothing at
all while the report said "gated". `--dry-run --allow-link-blackhole` gets §5.2's exercise back,
on purpose and by name.

Stdlib only. No kernel, no fabric, no build, no lab, and no `tc`: `probes.run` is replaced and
every argv it is handed is recorded, because half of what is claimed here is about commands
that must NOT go out.

Run:  python3 tests/python/test_chaos_opt_in_all_actions.py -v
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# Same seam as tests/python/test_chaos_link_blackhole_attach.py: NDT_CHAOS_HARNESS points the
# import at a MUTATED COPY so tests/shell/mutate_chaos_opt_in_all_actions.sh can score this file
# without writing a byte into a worktree other sessions are reading. Unset in a normal run.
HARNESS = os.environ.get("NDT_CHAOS_HARNESS") or os.path.join(
    REPO, "doc", "audit", "2026-08-28_chaos-harness", "harness")
sys.path.insert(0, HARNESS)
# probes.py walks up from its own __file__ to find the repo; under the gate that copy lives in
# /tmp, where the walk finds nothing. Pinned so a mutation to the harness never also mutates the
# authority it is checked against.
os.environ.setdefault("NDT_KERNEL_REPO", REPO)

import actions  # noqa: E402
import antioracle  # noqa: E402
import chaos  # noqa: E402
import invariants  # noqa: E402
import probes  # noqa: E402
from antioracle import PASS  # noqa: E402

FLAG = "allow-link-blackhole"

# 🔴 Verbatim from doc/audit/2026-08-12_overnight-review/C-live-ovs-runbook.md, P1 (2026-08-13):
# a live TCLink interface. Used here only so the ALLOWED dry run has a real tree to plan
# against -- the attach rule itself is tested in test_chaos_link_blackhole_attach.py.
SHAPED = ("qdisc htb 5: root refcnt 15 r2q 10 default 0x1 direct_packets_stat 0 "
          "direct_qlen 1000")


def gated_action(flag: str = "x-flag", note: str = "why this one is gated") -> actions.Action:
    """An action that records whether it was ever applied. `applied` is the whole point: a
    refusal that still ran the action is not a refusal, and only the spy can tell the two
    apart -- the returned record looks the same either way."""
    seen: list[bool] = []

    def apply(dry: bool) -> actions.ActionResult:
        seen.append(dry)
        return actions.ActionResult(True, "applied")

    act = actions.Action("T-gated", "INV-02", "an action behind a flag", destructive=True,
                         apply=apply, verify=lambda: actions.ActionResult(True, "verified"),
                         needs_opt_in=flag, note=note)
    act.applied = seen                      # type: ignore[attr-defined]
    return act


def ungated_action() -> actions.Action:
    """The control. A gate that refused everything would satisfy every case below and have no
    resolving power at all, so an action with no flag has to come through untouched."""
    seen: list[bool] = []

    def apply(dry: bool) -> actions.ActionResult:
        seen.append(dry)
        return actions.ActionResult(True, "applied")

    act = actions.Action("T-open", "INV-02", "an action behind nothing", destructive=False,
                         apply=apply, verify=lambda: actions.ActionResult(True, "verified"))
    act.applied = seen                      # type: ignore[attr-defined]
    return act


class FakeShell:
    """Stands in for probes.run and records every argv it is handed.

    Answers only the reads this harness makes on the way through a dry run: no bmv2 processes,
    no lab claim, and one qdisc tree. Anything else is an assertion failure rather than a
    default, because a command this test did not predict is exactly what it is looking for.
    """

    def __init__(self, tree: str = SHAPED):
        self.tree = tree
        self.calls: list[list[str]] = []

    def __call__(self, argv, timeout=5.0, env=None):
        self.calls.append(list(argv))
        words = [w for w in argv if w not in ("sudo", "-n")]
        if words[0] == "pgrep":
            return 1, "", ""                       # no BMv2 running; pgrep exits 1 on no match
        if words[:2] == ["ndt", "status"]:
            return 1, "", "no claim"               # G3 fails; a mode that injects nothing goes on
        if words[:3] == ["tc", "qdisc", "show"]:
            return 0, self.tree, ""
        raise AssertionError(f"the harness ran a command this test did not expect: {argv}")

    def tc(self) -> list[list[str]]:
        return [c for c in self.calls if "tc" in c]

    def writes(self) -> list[list[str]]:
        """Every tc call that is not a read."""
        return [c for c in self.tc() if "show" not in c]


class Seam(unittest.TestCase):
    """Installs the fake shell and takes it out again.

    `cpu_busy_fraction` goes with it, on the same seam tests/python/test_chaos_runner_wiring.py
    uses: every round a CpuGate touches sleeps two real seconds in /proc/stat, and the CPU
    anti-oracle is not what this file is about. Nothing here reads its verdict.
    """

    def setUp(self):
        self._run = probes.run
        self._cpu = antioracle.cpu_busy_fraction
        antioracle.cpu_busy_fraction = lambda window_s=1.0: 0.0

    def tearDown(self):
        probes.run = self._run
        antioracle.cpu_busy_fraction = self._cpu

    def shell(self, *a, **kw) -> FakeShell:
        fake = FakeShell(*a, **kw)
        probes.run = fake
        return fake


# =============================================================================================
class TheDecisionItself(unittest.TestCase):
    """`actions.opt_in_refusal` -- one predicate, and it lives beside the field it reads."""

    def test_an_action_with_no_flag_is_not_gated(self):
        # The control for this whole file. A predicate that refused everything would pass every
        # case below it and stop the harness from doing anything at all.
        self.assertIsNone(actions.opt_in_refusal(ungated_action(), {}))
        self.assertIsNone(actions.opt_in_refusal(ungated_action(), None))

    def test_a_gated_action_with_its_flag_may_run(self):
        self.assertIsNone(actions.opt_in_refusal(gated_action(), {"x-flag": True}))

    def test_a_gated_action_without_its_flag_is_refused(self):
        self.assertIsNotNone(actions.opt_in_refusal(gated_action(), {"other-flag": True}))

    def test_the_refusal_names_the_flag_that_would_allow_it(self):
        # Without the flag name a refusal cannot be told from a failure, and the reader has no
        # way to get the action to run. It is the only actionable word in the sentence.
        why = actions.opt_in_refusal(gated_action("allow-thing", "the reason"), {})
        self.assertIn("--allow-thing", why)
        self.assertIn("the reason", why)

    def test_a_caller_that_passes_no_flags_at_all_is_refused(self):
        # Default-deny. A caller that forgot the argument must get a refusal, not an injection.
        self.assertIsNotNone(actions.opt_in_refusal(gated_action(), None))

    def test_a_flag_present_but_false_is_not_a_yes(self):
        self.assertIsNotNone(actions.opt_in_refusal(gated_action(), {"x-flag": False}))


# =============================================================================================
class TheInjectionRoundAsksIt(Seam):
    """The entry point the controls loop is NOT: every chaos action goes through here."""

    def round(self, act, dry, opt_ins="omit"):
        kw = {} if opt_ins == "omit" else {"opt_ins": opt_ins}
        return chaos.injection_round(act, dry, None, None, None, False, None, **kw)

    def test_a_gated_action_is_refused_before_anything_is_applied(self):
        """E-4 itself: this loop never asked the question, so a destructive action with a flag
        ran anyway."""
        self.shell()
        act = gated_action()
        r = self.round(act, False, {})
        self.assertEqual(r["verdict"], "REFUSED", r)
        self.assertEqual(act.applied, [], "the action was applied by a round that refused it")

    def test_a_dry_run_of_a_gated_action_is_refused_and_reads_nothing(self):
        """The blackhole is in no list, so `--dry-run` is the only path that reaches it. A gate
        that exempted dry runs would gate nothing -- and would still print 'gated'."""
        fake = self.shell()
        act = actions.link_blackhole("s1-eth2")
        r = self.round(act, True, {})
        self.assertEqual(r["verdict"], "REFUSED", r)
        self.assertTrue(r["dry_run"])
        self.assertEqual(fake.tc(), [],
                         "a refused dry run still read the interface's qdisc tree")

    def test_the_refused_round_is_reported_rather_than_dropped(self):
        # An action missing from the report reads exactly like one that ran and found nothing;
        # this harness has been bitten by "omitted is indistinguishable from passed" before.
        self.shell()
        r = self.round(gated_action("allow-thing"), False, {})
        self.assertEqual(r["round"], "T-gated")
        self.assertIn("--allow-thing", r["detail"])
        self.assertNotEqual(r["verdict"], PASS)
        self.assertEqual(r.get("findings", []), [],
                         "a refused round must not carry invariant results it never evaluated")

    def test_the_flag_lets_the_round_run(self):
        # The other direction. Without it the gate could be a constant refusal and every case
        # above would still pass.
        self.shell()
        act = gated_action()
        r = self.round(act, True, {"x-flag": True})
        self.assertNotEqual(r["verdict"], "REFUSED", r)
        self.assertEqual(act.applied, [True], "the allowed action never ran")

    def test_an_ungated_action_is_untouched(self):
        self.shell()
        act = ungated_action()
        r = self.round(act, True, {})
        self.assertNotEqual(r["verdict"], "REFUSED", r)
        self.assertEqual(act.applied, [True])

    def test_a_caller_that_omits_the_flags_argument_gets_a_refusal(self):
        """Fail-closed at the signature: a call site added later that forgets to pass the flags
        refuses the action instead of injecting it."""
        self.shell()
        act = gated_action()
        r = self.round(act, False)
        self.assertEqual(r["verdict"], "REFUSED", r)
        self.assertEqual(act.applied, [])


# =============================================================================================
class BothEntryPointsAskTheSameQuestion(unittest.TestCase):
    """One decision. Two loops that happen to agree today are two decisions tomorrow."""

    def setUp(self):
        self._controls = actions.POSITIVE_CONTROLS
        self._uncontrolled = actions.UNCONTROLLED_INVARIANTS
        self._probe = chaos.probe_one_invariant
        # Nothing in this class may reach the network: the controls loop probes an invariant
        # for every control it actually runs.
        chaos.probe_one_invariant = lambda inv, iface, expect_free=False: invariants.Finding(
            inv, PASS, "stubbed")
        actions.UNCONTROLLED_INVARIANTS = []

    def tearDown(self):
        actions.POSITIVE_CONTROLS = self._controls
        actions.UNCONTROLLED_INVARIANTS = self._uncontrolled
        chaos.probe_one_invariant = self._probe

    def test_a_gated_control_is_not_run_and_is_not_applied(self):
        act = gated_action()
        actions.POSITIVE_CONTROLS = [act]
        ok, rows = chaos.gate_g1_controls(dry_run=False, opt_ins={})
        self.assertEqual(rows[0]["verdict"], "NOT-RUN", rows)
        self.assertEqual(act.applied, [])
        self.assertFalse(ok, "a control that could not run must not leave G1 satisfied")

    def test_both_paths_refuse_with_the_identical_sentence(self):
        """The pin. A reader comparing a refused control with a refused injection round must
        not have to work out whether two wordings mean the same thing."""
        act = gated_action("allow-thing", "the reason it is gated")
        actions.POSITIVE_CONTROLS = [act]
        _, rows = chaos.gate_g1_controls(dry_run=False, opt_ins={})
        rnd = chaos.injection_round(act, False, None, None, None, False, None, opt_ins={})
        self.assertEqual(rows[0]["detail"], rnd["detail"])
        self.assertIn("--allow-thing", rows[0]["detail"])

    def test_a_dry_run_no_longer_previews_a_gated_control_without_its_flag(self):
        act = gated_action()
        actions.POSITIVE_CONTROLS = [act]
        _, rows = chaos.gate_g1_controls(dry_run=True, opt_ins={})
        self.assertEqual(rows[0]["verdict"], "NOT-RUN", rows)
        self.assertEqual(act.applied, [],
                         "the dry branch ran the action before anyone asked for the flag")

    def test_the_flag_lets_the_control_through_in_both_modes(self):
        for dry in (True, False):
            act = gated_action()
            actions.POSITIVE_CONTROLS = [act]
            _, rows = chaos.gate_g1_controls(dry_run=dry, opt_ins={"x-flag": True})
            self.assertNotEqual(rows[0]["verdict"], "NOT-RUN", rows)
            self.assertEqual(act.applied, [dry])

    def test_an_ungated_control_is_untouched_in_both_modes(self):
        for dry in (True, False):
            act = ungated_action()
            actions.POSITIVE_CONTROLS = [act]
            _, rows = chaos.gate_g1_controls(dry_run=dry, opt_ins={})
            self.assertNotEqual(rows[0]["verdict"], "NOT-RUN", rows)
            self.assertEqual(act.applied, [dry])


# =============================================================================================
class TheBlackholeIsGatedAndStaysOutOfFull(unittest.TestCase):
    """Adam's ruling, 2026-09-07 (E-4). Two questions, two answers, and both are pinned."""

    def test_the_blackhole_carries_an_opt_in_flag(self):
        self.assertEqual(actions.link_blackhole("s1-eth1").needs_opt_in, FLAG)

    def test_the_blackhole_is_not_in_the_list_full_runs(self):
        """`--full` walks CHAOS_ACTIONS. Putting the blackhole there would send `tc` at a live
        link on every full run -- which is the decision Adam took, and took the other way."""
        blackholes = [a.id for a in actions.CHAOS_ACTIONS if a.id.startswith("T-netem")]
        self.assertEqual(blackholes, [],
                         "link_blackhole is in CHAOS_ACTIONS; E-4 ruled it stays out")

    def test_every_destructive_action_the_runner_can_build_is_behind_a_flag(self):
        """The general statement of E-4, asked of the whole surface rather than of the one
        action that prompted it. `all_actions` includes the blackhole, which belongs to no list
        -- and belonging to no list is how it escaped the question for a fortnight."""
        ungated = [a.id for a in actions.all_actions() if a.destructive and not a.needs_opt_in]
        self.assertEqual(ungated, [], f"destructive and ungated: {ungated}")

    def test_the_surface_still_holds_actions_that_are_not_gated(self):
        # Zero-discrimination control for the case above: if `all_actions` returned nothing, or
        # everything were destructive, that assertion would be vacuous.
        surface = actions.all_actions()
        self.assertTrue([a for a in surface if a.destructive])
        self.assertTrue([a for a in surface if not a.needs_opt_in])


# =============================================================================================
class TheFlagReachesTheActionThroughMain(Seam):
    """existence != wiring, end to end: `--allow-link-blackhole` on the command line has to
    arrive at the action's gate. A dict built in one place and read in another is exactly the
    join that was broken before this fix."""

    def run_main(self, argv: list[str]) -> tuple[dict, FakeShell]:
        fake = self.shell()
        out, err = io.StringIO(), io.StringIO()
        old = sys.argv
        sys.argv = ["chaos.py"] + argv
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = chaos.main()
        finally:
            sys.argv = old
        self.assertEqual(rc, 0, err.getvalue())
        return json.loads(out.getvalue()), fake

    def one_round(self, report: dict, prefix: str) -> dict:
        rounds = [r for r in report["rounds"] if r["round"].startswith(prefix)]
        self.assertEqual(len(rounds), 1, report["rounds"])
        return rounds[0]

    def test_the_default_dry_run_refuses_the_blackhole_and_runs_no_tc(self):
        report, fake = self.run_main(["--dry-run", "--iface", "s1-eth2"])
        r = self.one_round(report, "T-netem")
        self.assertEqual(r["verdict"], "REFUSED", r)
        self.assertIn(f"--{FLAG}", r["detail"])
        self.assertEqual(fake.tc(), [], "a refused dry run still ran tc")

    def test_the_flag_lets_the_dry_run_plan_its_attach_point(self):
        """The direction that proves the wiring rather than the refusal: with the flag the
        action runs, reads the tree, and plans under the shaper."""
        report, fake = self.run_main(["--dry-run", "--iface", "s1-eth2", f"--{FLAG}"])
        r = self.one_round(report, "T-netem")
        self.assertNotEqual(r["verdict"], "REFUSED", r)
        self.assertIn("parent 5:0x1", r["applied"])
        self.assertTrue(fake.tc(), "the allowed dry run never read the qdisc tree")
        self.assertEqual(fake.writes(), [], "a dry run changed the machine")

    def test_the_poweroff_control_is_still_gated_by_its_own_flag(self):
        """Per-action, not a blanket yes: the blackhole's flag must not unlock G1-01."""
        report, _ = self.run_main(["--gates", f"--{FLAG}"])
        rows = [r for r in report["G1_positive_controls"]["rows"] if r["control"] == "G1-01"]
        self.assertEqual(rows[0]["verdict"], "NOT-RUN", rows)
        self.assertIn("--allow-poweroff", rows[0]["detail"])

    def test_the_ungated_chaos_actions_still_run_in_the_dry_run(self):
        # The control: the refusals above must not be a mode that refuses everything.
        report, _ = self.run_main(["--dry-run", "--iface", "s1-eth2"])
        for h in ("H5", "H23"):
            self.assertNotEqual(self.one_round(report, h)["verdict"], "REFUSED", report)

    def test_the_result_line_says_which_rounds_were_refused(self):
        # A refusal nobody can find in the summary is a silent skip with extra steps.
        report, _ = self.run_main(["--dry-run", "--iface", "s1-eth2"])
        self.assertIn("T-netem", report["result"])

    def test_every_declared_flag_is_a_real_command_line_flag(self):
        """Asked of the CLI itself, not of this test's reading of the source. An action naming a
        flag that argparse does not accept is refused forever, with no way to allow it."""
        declared = sorted({a.needs_opt_in for a in actions.all_actions() if a.needs_opt_in})
        self.assertTrue(declared)
        helptext = subprocess.run(
            [sys.executable, os.path.join(HARNESS, "chaos.py"), "--help"],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "NDT_KERNEL_REPO": REPO}).stdout
        for flag in declared:
            self.assertIn(f"--{flag}", helptext, f"no CLI flag can ever set {flag}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
