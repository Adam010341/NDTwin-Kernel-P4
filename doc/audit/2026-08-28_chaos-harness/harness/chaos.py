#!/usr/bin/env python3
"""Chaos harness runner: gates, null round, injection rounds, report.

    python3 chaos.py --gates     # G1/G2/G3 pre-flight only, no injection
    python3 chaos.py --dry-run   # exercise every destructive action's allow-path dry run
    python3 chaos.py --null      # the null round: no fault injected at all
    python3 chaos.py --full      # gates, null round, then the injection rounds

DEFAULT IS --dry-run. Making the safe mode the default is not politeness: this file will be
run by someone who has not read it.

§5 of the spec, which shapes everything below: **the harness is the first thing under test.**
A new tool's first live run mostly finds defects in the tool. So:

  1. The NULL ROUND runs first and injects nothing. Every violation it reports is a defect in
     this harness, not in the system, and its count is the harness's FALSE-POSITIVE FLOOR --
     which goes in the report, because a floor nobody wrote down gets read as zero.
  2. Destructive actions have a dry run, and it is EXERCISED, because the refuse path is cheap
     to test and the allow path is not. A guard tested only by watching it refuse has never
     had its dangerous branch executed -- and the moment a guard fails is exactly the moment
     the thing it guards happens.
  3. Verdicts come from state, never from an HTTP status.

[Co-developed with claude code -- Adam]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import asdict, dataclass

import actions as A
import invariants as I
import probes
from antioracle import FAIL, INCONCLUSIVE_CPU, NOT_MEASURED, PASS, SKIPPED, CpuGate


# ============================================================================================
# G3 -- the lab claim
# ============================================================================================
def gate_g3_claim(require_ours: str | None) -> tuple[bool, str]:
    """Refuse to inject unless the lab is ours.

    Reads `ndt status` rather than `cat .test_run/lab.claim`: status also prints the
    `measuring` field, which answers "is an experiment actually running" directly, and the
    declared-vs-actual reconciliation for exclusive_cpu. The claim file alone says who OWNS the
    lab, which is a different question -- confusing the two produced a false collision report
    on 2026-08-28.
    """
    # 🔴 Run `ndt status` under the identity we are claiming to be, instead of inheriting
    # whatever NDT_OWNER the caller's shell happens to hold. Found 2026-08-29, second defect in
    # this same gate.
    #
    # `ndt status` renders the claim line RELATIVE TO NDT_OWNER: "claim yours -- 171m left" when
    # it matches, the owner's name when it does not. The substring test below was therefore
    # passing only because this session never exported NDT_OWNER -- and `ndt`'s own help tells
    # every user to do exactly that ("export NDT_OWNER='my-session-name'"). Anyone following the
    # documented protocol would have been refused access to their own lab, with a message
    # naming themselves as the blocker.
    #
    # Pinning the variable makes the answer mean one thing: "yours" now says the claim belongs
    # to the identity passed in --owner, which is precisely the question G3 asks. It is also
    # stronger than string-matching a name, because it is the tool doing the comparison rather
    # than us re-implementing it.
    env = {"NDT_OWNER": require_ours} if require_ours else None
    try:
        rc, out, _ = probes.run(["ndt", "status"], timeout=120, env=env)
    except probes.Timeout:
        return False, "`ndt status` timed out; refusing to inject blind"
    if rc != 0:
        return False, f"`ndt status` exited {rc}"

    claim = measuring = excl = "?"
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("claim "):
            claim = s[6:].strip()
        elif s.startswith("measuring "):
            measuring = s[10:].strip()
        elif s.startswith("exclusive cpu "):
            excl = s[14:].strip()

    if "EXPIRED" in claim or claim.lower().startswith("none"):
        return False, (f"no live claim (claim: {claim}). Chaos injection must hold the lab with "
                       f"exclusive_cpu=yes -- see §2, this harness manufactures CPU load")
    # 🔴 Fail closed when no owner was supplied. Found by running the dry run against a live
    # claim held by ANOTHER session: without this branch the gate saw "a claim exists and it
    # declares exclusive_cpu=yes" and passed -- which is true of every claim, including
    # someone else's. The gate would have authorised injection straight into a neighbour's
    # measurement window. "A claim exists" and "the claim is mine" are different questions, and
    # this is the same confusion that produced a false collision report on 2026-08-28.
    if not require_ours:
        return False, (f"--owner not given, so 'is this claim MINE?' was never asked. The lab is "
                       f"currently held by: {claim}. Refusing rather than assuming.")
    # "yours" is the authoritative answer, because `ndt` computed it against the NDT_OWNER we
    # pinned above. The name match is kept as a fallback for a future `ndt` that phrases it
    # differently -- but it is the weaker test and must not be the only one.
    if not (claim.startswith("yours") or require_ours in claim):
        return False, (f"the lab is claimed by someone else: {claim!r}; expected {require_ours!r}. "
                       f"measuring={measuring!r}")
    if not excl.lower().startswith("yes"):
        return False, (f"claim does not declare exclusive_cpu=yes (exclusive cpu: {excl}). "
                       f"Injection would perturb whoever else is measuring, invisibly to them")
    return True, f"claim={claim} | measuring={measuring} | exclusive cpu={excl}"


# ============================================================================================
# G1 -- positive controls
# ============================================================================================
def probe_one_invariant(inv_id: str, iface: str | None,
                        expect_free: bool = False) -> I.Finding:
    """Run a single named invariant. Exists only so G1 can ask the question G1 is about.

    `expect_free` is context the invariant cannot get for itself: G1 sets it on the AFTER
    reading, because its BEFORE reading proved the lock free seconds earlier. Without it,
    INV-06 must treat "cannot acquire" as a possible innocent neighbour and skip -- which
    silently swallows the very defect G1-06 injects.
    """
    ctx = build_context()
    if inv_id == "INV-01":
        return I.inv01_power_state_agreement(ctx)
    if inv_id == "INV-04":
        return (I.inv04_rate_conservation(ctx, iface) if iface else
                I.Finding("INV-04", SKIPPED, "no --iface, so there is no wire truth"))
    if inv_id == "INV-06":
        return I.inv06_lock_mutual_exclusion(ctx, expect_free=expect_free)
    if inv_id == "INV-07":
        return I.inv07_telemetry_freshness(ctx, iface=iface)
    return I.Finding(inv_id, SKIPPED, "no single-invariant probe wired up for this id")


def gate_g1_controls(dry_run: bool, iface: str | None = None,
                     opt_ins: dict[str, bool] | None = None) -> tuple[bool, list[dict]]:
    """Every invariant needs a real, catalogued defect that makes it go red, and somebody has
    to have watched it happen. An all-green harness and a harness that checks nothing produce
    the same output.

    🔴 REWRITTEN 2026-08-29, first live run. The old version applied each control, called
    `ctl.verify()`, and printed **"FIRED"** -- but `ctl.verify()` asks "did the DEFECT
    reproduce?", which is G2. Whether the INVARIANT NOTICED was never asked; no invariant
    function was called anywhere in this gate. So G1 could report all-green while every
    invariant was blind, which is the exact condition G1 exists to rule out, and the word
    "FIRED" named the thing that had not been measured.

    Same shape as `verify-the-purpose-not-the-mechanism`: the mechanism (the defect landed)
    was checked, the purpose (the check catches it) was not. The distinguishing question --
    "if the invariant were deleted entirely, would this gate go red?" -- answered NO.

    Now both are recorded, separately, and G1 passes only when the invariant itself goes red:

        reproduced : the control really re-created the catalogued defect  (G2)
        detected   : the target invariant returned FAIL because of it     (G1)
    """
    rows = []
    all_ok = True
    opt_ins = opt_ins or {}
    for ctl in A.POSITIVE_CONTROLS:
        if dry_run:
            rows.append({"control": ctl.id, "targets": ctl.targets, "verdict": "DRY-RUN",
                         "detail": ctl.apply(True).detail})
            continue
        if ctl.needs_opt_in and not opt_ins.get(ctl.needs_opt_in):
            rows.append({"control": ctl.id, "targets": ctl.targets, "verdict": "NOT-RUN",
                         "detail": f"needs --{ctl.needs_opt_in}; {ctl.note}"})
            all_ok = False
            continue

        # 🔴 Baseline BEFORE the fault. This was wrong in the first cut of this rewrite -- the
        # baseline was taken after `apply` -- and the very first live run caught it: G1-06's
        # "before" reading was already FAIL because `_c06_apply` had run and left a lock behind.
        # A control credited with a failure it inherited proves nothing, and a control blamed
        # for one is just as wrong. `controls-decide-what-you-learn`, at one line's distance.
        before = probe_one_invariant(ctl.targets, iface)

        applied = ctl.apply(False)
        if not applied.ok:
            rows.append({"control": ctl.id, "targets": ctl.targets, "verdict": "NOT-APPLIED",
                         "detail": applied.detail,
                         "invariant_before": {"verdict": before.verdict, "detail": before.detail}})
            all_ok = False
            continue

        reproduced = ctl.verify()
        # expect_free only holds when the baseline actually came back clean -- otherwise we
        # would be asserting a precondition we never established.
        after = probe_one_invariant(ctl.targets, iface,
                                    expect_free=(before.verdict == PASS))
        if ctl.undo:
            ctl.undo()

        detected = after.verdict == FAIL and before.verdict != FAIL
        if before.verdict == FAIL:
            verdict, note = "INVALID-BASELINE", "the invariant was ALREADY red before the fault"
        elif detected:
            verdict, note = "FIRED", "invariant went red on the injected defect"
        elif reproduced.ok:
            verdict, note = "BLIND", ("the defect reproduced and the invariant did NOT notice -- "
                                      "this invariant's PASS is worthless until fixed")
        else:
            verdict, note = "DID-NOT-REPRODUCE", "the control failed to re-create the defect"

        rows.append({"control": ctl.id, "targets": ctl.targets, "verdict": verdict,
                     "note": note,
                     "reproduced_g2": {"ok": reproduced.ok, "detail": reproduced.detail},
                     "invariant_before": {"verdict": before.verdict, "detail": before.detail},
                     "invariant_after": {"verdict": after.verdict, "detail": after.detail}})
        if verdict != "FIRED":
            all_ok = False

    for inv in A.UNCONTROLLED_INVARIANTS:
        rows.append({"control": "(none)", "targets": inv, "verdict": "NO-CONTROL",
                     "detail": "no executable positive control yet; this invariant is NOT "
                               "delivered under G1 and its PASS means nothing"})
        all_ok = False
    return all_ok, rows


# ============================================================================================
# Rounds
# ============================================================================================
def build_context() -> I.Context:
    try:
        n = probes.bmv2_process_count()
    except Exception:
        n = 0
    return I.Context(expected_switches=n, plane="p4")


@dataclass
class PowerOnChance:
    """Does this round have a power-on worth timing, and why (in both directions)?

    `ip` is the switch to power on, or None when there is nothing to time. `why` is printed
    either way: "not measured" without a reason is the same silence as an omitted row.
    """

    ip: str | None
    why: str


def power_on_chance(agreement: I.Finding, power_ip: str | None) -> PowerOnChance:
    """🔴 FINDINGS-ALL #17's second half, which is why #75 is not simply "call the function".

    `P4PowerStrategy::powerOn` returns success immediately when the vertex is already up. That
    early return is CORRECT for a healthy, running switch -- and INV-01's latency check reads a
    fast 2xx as the A-1 lie. So calling it unconditionally would manufacture a FAIL on a
    perfectly healthy fabric, which is `instrument-must-not-mimic-its-own-finding` for the
    third time in this harness (`switch_flags` collided 128 hosts into a +1; #17 timed a 404).

    The precondition is therefore: a power-on that OUGHT to do work. Two states qualify, and
    both are read from the agreement check's OWN snapshot rather than from a second graph
    fetch, so the two halves of INV-01 cannot end up reasoning about different fabrics:

      1. the target is a switch the graph itself calls DOWN -- powering it on must start it;
      2. the graph certifies more switches up than there are BMv2 processes -- the A-1 state,
         where at least one "up" switch is not running and a power-on has work to do.

    Everything else is NOT MEASURED, and nothing is sent. Refusing to send is half the point:
    a request costs a real round trip whose duration is the very number the caller is about to
    weigh, and on this route it also changes the fabric.
    """
    ev = agreement.evidence or {}
    if not power_ip:
        return PowerOnChance(None, "no --power-ip was given, so this round had no switch to "
                                   "power on and nothing timed a power-on")
    if agreement.verdict == SKIPPED or "graph_up" not in ev:
        return PowerOnChance(None, f"the power-state check reached no conclusion "
                                   f"({agreement.detail}), so whether a power-on would have "
                                   f"work to do is unknown -- and unknown is not permission "
                                   f"to time one")
    down = ev.get("down_by_ip") or {}
    if power_ip in down:
        return PowerOnChance(power_ip,
                             f"the graph says {down[power_ip]} at {power_ip} is down, so "
                             f"powering it on has to start a switch rather than return early")
    if ev.get("graph_up", 0) > ev.get("bmv2_processes", 0):
        return PowerOnChance(power_ip,
                             f"the graph certifies {ev['graph_up']} switch(es) up with only "
                             f"{ev['bmv2_processes']} BMv2 process(es) alive -- the A-1 state, "
                             f"in which at least one power-on has real work to do")
    return PowerOnChance(None,
                         f"{power_ip} is not among the switches the graph calls down, and "
                         f"every switch it calls up has a live process ({ev.get('graph_up')} "
                         f"up, {ev.get('bmv2_processes')} alive), so a power-on would "
                         f"legitimately return at once and its duration would mean nothing")


def inv01_latency_check(agreement: I.Finding, power_ip: str | None) -> I.Finding:
    """INV-01's second half, run or honestly declined -- FINDINGS-ALL #75.

    #17 rewrote `inv01_powercycle_latency` to send the request the kernel actually registers.
    It fixed a function with ZERO call sites: this round called `inv01_power_state_agreement`
    and stopped, so the latency half has never run. `existence != wiring`, the same family as
    #71.

    The result is reported under its OWN name beside the agreement check, never merged into
    it. Two verdicts about different questions in one row means one of them is invisible, and
    the invisible one is whichever a reader is not looking for.
    """
    chance = power_on_chance(agreement, power_ip)
    if chance.ip is None:
        return I.Finding(I.INV01_LATENCY, NOT_MEASURED, f"not measured -- {chance.why}",
                         # 🔴 elapsed_s is None, never 0.0. 0.0 is precisely the fast-return
                         # signature this check reads as the A-1 lie, so writing it as the
                         # default for a measurement that never happened would hand the next
                         # reader the accusation with nothing behind it.
                         {"elapsed_s": None, "threshold_s": I.A1_FAST_S,
                          "honest_reference_s": I.A1_HONEST_S,
                          "why_not_measured": chance.why})
    f = I.inv01_powercycle_latency(chance.ip)
    f.inv = I.INV01_LATENCY
    f.evidence.setdefault("elapsed_s", None)     # a refusal has no duration to report (#17)
    f.evidence.update({"threshold_s": I.A1_FAST_S, "honest_reference_s": I.A1_HONEST_S,
                       "measurable_because": chance.why})
    return f


def round_verdict(findings: list[I.Finding]) -> dict:
    """One verdict for the round, and it fails if ANY check failed -- including either half of
    INV-01.

    The counterpart rule is on the other side: a check that reached no conclusion is listed,
    by name, and is explicitly not a pass. This harness has already been bitten by "omitted is
    indistinguishable from passed" (`run_invariants`' own docstring), and a summary line is
    exactly where that happens next.
    """
    failed = [f.inv for f in findings if f.verdict == FAIL]
    unresolved = [f.inv for f in findings
                  if f.verdict in (NOT_MEASURED, SKIPPED, INCONCLUSIVE_CPU)]
    if failed:
        return {"verdict": FAIL,
                "verdict_detail": f"{len(failed)} check(s) failed: {failed}"}
    return {"verdict": PASS,
            "verdict_detail": (f"no check failed; {len(unresolved)} reached no conclusion and "
                               f"are NOT passes: {unresolved}")}


def run_invariants(ctx: I.Context, gate: CpuGate, iface: str | None,
                   pair: tuple[str, str] | None, dpid: str | None = None,
                   slow: bool = False, power_ip: str | None = None) -> list[I.Finding]:
    """All eight invariants appear in every report, including the ones that did not run.

    An invariant omitted from the output is indistinguishable from one that passed, and this
    project has already been bitten by a `| head -N` read as a total. So the ones that are
    skipped say so, and say why, in the same list as the ones that ran.
    """
    out: list[I.Finding] = []
    for inv_id, fn in I.ALWAYS_ON:                  # INV-01, INV-02, INV-08
        f = fn(ctx)
        out.append(f)
        # 🔴 FINDINGS-ALL #75. INV-01 is two checks; until now the round ran one of them and
        # the other had no call site anywhere in the repo. Appended HERE, next to the check it
        # shares an id with, so removing INV-01 from ALWAYS_ON cannot silently take the
        # latency half with it -- and so the two rows arrive together in the report.
        if inv_id == I.INV01:
            out.append(inv01_latency_check(f, power_ip))

    if dpid:
        out.append(I.inv03_flow_table_identity(ctx, dpid))
    else:
        out.append(I.Finding("INV-03", SKIPPED,
                             "no --dpid given, so the twin's cache was never compared against a "
                             "real switch table"))

    if iface:
        out.append(I.inv04_rate_conservation(ctx, iface))
    else:
        out.append(I.Finding("INV-04", SKIPPED,
                             "no --iface given, so there is no wire truth to compare against"))

    if pair:
        out.append(I.inv05_path_consistency(ctx, pair[0], pair[1]))
    else:
        out.append(I.Finding("INV-05", SKIPPED, "no --pair given"))

    out.append(I.inv06_lock_mutual_exclusion(ctx))

    if slow:
        out.append(I.inv07_telemetry_freshness(ctx, iface=iface))
    else:
        out.append(I.Finding("INV-07", SKIPPED,
                             "needs a 20 s quiet window; enable with --slow"))

    # Apply the CPU anti-oracle. Only downgrades FAIL, and only for the rate/path invariants.
    adjusted = []
    for f in out:
        v, why = gate.verdict_for(f.inv, f.verdict)
        if why:
            f.detail = f"{f.detail}  [VOIDED: {why}]"
        f.verdict = v
        adjusted.append(f)
    return adjusted


def null_round(iface: str | None, pair: tuple[str, str] | None,
               dpid: str | None = None, slow: bool = False,
               power_ip: str | None = None) -> dict:
    """Inject NOTHING. Any violation here is this harness's own defect."""
    ctx = build_context()
    ctx.round_name = "null"
    gate = CpuGate()
    gate.take_baseline()
    findings = run_invariants(ctx, gate, iface, pair, dpid, slow, power_ip)
    gate.sample()
    fails = [f for f in findings if f.verdict == FAIL]
    return {
        "round": "null",
        **round_verdict(findings),
        "cpu_baseline": round(gate.baseline, 4),
        "cpu_peak": round(gate.peak, 4),
        "findings": [asdict(f) for f in findings],
        "false_positive_floor": len(fails),
        "interpretation": (
            "Nothing was injected. Every FAIL above is a defect in the harness, not in NDTwin. "
            f"The harness's false-positive floor for this configuration is {len(fails)}. "
            "Any later round reporting fewer than this many violations has found nothing."
        ),
    }


def injection_round(action: A.Action, dry_run: bool, iface: str | None,
                    pair: tuple[str, str] | None, dpid: str | None = None,
                    slow: bool = False, power_ip: str | None = None) -> dict:
    ctx = build_context()
    ctx.round_name = action.id
    gate = CpuGate()
    gate.take_baseline()

    applied = action.apply(dry_run)
    gate.sample()

    if dry_run:
        return {"round": action.id, "dry_run": True, "applied": applied.detail,
                "verdict": "DRY-RUN", "verdict_detail": "no invariant was evaluated",
                "findings": [], "note": "allow-path dry run exercised; nothing was touched"}

    if not applied.ok:
        return {"round": action.id, "aborted": True, "applied": applied.detail,
                "verdict": "ABORTED", "verdict_detail": "no invariant was evaluated",
                "why": "the injection did not apply, so no conclusion about the system is "
                       "available; scoring this round would report the absence of a fault as "
                       "the absence of a defect"}

    # G2: the injection must prove itself, through a path independent of what it was told.
    v = action.verify()
    if not v.ok:
        if action.undo:
            action.undo()
        return {"round": action.id, "aborted": True, "applied": applied.detail,
                "verdict": "ABORTED", "verdict_detail": "no invariant was evaluated",
                "verify": v.detail,
                "why": "G2 failed: the fault could not be confirmed to have landed. A clean "
                       "round here would mean 'the fault never happened', not 'the system "
                       "coped'."}

    findings = run_invariants(ctx, gate, iface, pair, dpid, slow, power_ip)
    gate.sample()
    if action.undo:
        action.undo()

    return {
        "round": action.id,
        **round_verdict(findings),
        "targets": action.targets,
        "applied": applied.detail,
        "verified": v.detail,
        "cpu_baseline": round(gate.baseline, 4),
        "cpu_peak": round(gate.peak, 4),
        "cpu_delta": round(gate.delta, 4),
        "findings": [asdict(f) for f in findings],
    }


# ============================================================================================
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--gates", action="store_true", help="G1/G2/G3 pre-flight only")
    mode.add_argument("--dry-run", action="store_true", help="exercise allow-path dry runs (default)")
    mode.add_argument("--null", action="store_true", help="null round: inject nothing")
    mode.add_argument("--controls", action="store_true",
                      help="run the G1 positive controls LIVE and check each target invariant "
                           "goes red. Applies real faults, so it is gated exactly like --full")
    mode.add_argument("--full", action="store_true", help="gates, null round, then injections")
    ap.add_argument("--iface", help="veth to use as wire truth for INV-04, e.g. s1-eth3")
    ap.add_argument("--pair", help="src,dst for INV-05, e.g. 10.0.0.2,10.0.0.1")
    ap.add_argument("--dpid", help="dpid to compare twin cache against the real table for INV-03")
    ap.add_argument("--slow", action="store_true", help="include INV-07, which needs a 20 s quiet window")
    ap.add_argument("--power-ip",
                    help="management IP of the switch INV-01's latency half may power on, e.g. "
                         "192.168.123.11. Without it that check reports NOT-MEASURED in every "
                         "round: it POSTs a real power-on, so it needs a target named on "
                         "purpose rather than a default, and it still only sends one when the "
                         "graph proves that power-on would have work to do")
    ap.add_argument("--owner", help="expected claim owner substring for G3")
    ap.add_argument("--allow-poweroff", action="store_true",
                    help="permit G1-01, which really powers a switch down and whose restore "
                         "path has never been exercised against a switch that was actually off")
    ap.add_argument("--out", help="write the JSON report here")
    args = ap.parse_args()
    if not any([args.gates, args.dry_run, args.null, args.controls, args.full]):
        args.dry_run = True

    pair = tuple(args.pair.split(",", 1)) if args.pair else None
    report: dict = {"started": time.strftime("%FT%T%z"), "mode": (
        "gates" if args.gates else "dry-run" if args.dry_run else "null" if args.null
        else "controls" if args.controls else "full")}
    # In EVERY report, including --dry-run. A benchmark that does not name the binary it
    # measured cannot be checked later, and "later" arrives as soon as the fabric is rebuilt.
    report["bmv2_provenance"] = probes.bmv2_provenance()

    # --controls applies real faults (it powers a switch down), so it needs the claim just as
    # much as --full does. Gating only --full would have left the destructive mode ungated.
    injecting = args.full or args.controls
    ok, why = gate_g3_claim(args.owner)
    report["G3_claim"] = {"ok": ok, "detail": why}
    if injecting and not ok:
        report["result"] = "REFUSED before injecting: " + why
        print(json.dumps(report, indent=2))
        return 1
    if not ok:
        print(f"# G3 not satisfied ({why}) -- continuing, because this mode injects nothing.",
              file=sys.stderr)

    g1_ok, g1_rows = gate_g1_controls(dry_run=not injecting, iface=args.iface,
                                      opt_ins={"allow-poweroff": args.allow_poweroff})
    report["G1_positive_controls"] = {"all_fired": g1_ok, "rows": g1_rows}
    # Only --full refuses on G1. --controls is the run that ESTABLISHES G1, so refusing on it
    # would make the gate unsatisfiable: the only way to earn it is to perform it.
    if args.full and not g1_ok:
        report["result"] = ("REFUSED before injecting: at least one invariant has no positive "
                            "control, or its control did not fire. An invariant nobody has "
                            "watched fail cannot be evidence.")
        print(json.dumps(report, indent=2))
        return 1

    if args.gates:
        report["result"] = "gates only"
    elif args.dry_run:
        report["rounds"] = [injection_round(a, True, args.iface, pair, args.dpid, args.slow,
                                            args.power_ip)
                            for a in A.CHAOS_ACTIONS + [A.link_blackhole(args.iface or "s1-eth3")]]
        report["result"] = "dry run complete; every destructive allow path printed its intent and touched nothing"
    elif args.null:
        report["rounds"] = [null_round(args.iface, pair, args.dpid, args.slow, args.power_ip)]
        report["result"] = "null round complete"
    elif args.controls:
        report["result"] = (
            "G1 positive controls run live. FIRED means the target invariant went red BECAUSE "
            "of the injected defect; BLIND means the defect landed and the invariant did not "
            "notice, which is strictly worse than a missing control because it looks like "
            "coverage. G1 is met only when every row reads FIRED.")
    else:
        rounds = [null_round(args.iface, pair, args.dpid, args.slow, args.power_ip)]
        floor = rounds[0]["false_positive_floor"]
        for a in A.CHAOS_ACTIONS:
            rounds.append(injection_round(a, False, args.iface, pair, args.dpid, args.slow,
                                          args.power_ip))
        report["rounds"] = rounds
        report["false_positive_floor"] = floor
        n_incon = sum(1 for r in rounds for f in r.get("findings", [])
                      if f.get("verdict") == INCONCLUSIVE_CPU)
        n_tot = sum(1 for r in rounds for f in r.get("findings", []))
        report["inconclusive_cpu_rate"] = f"{n_incon}/{n_tot}"
        report["inconclusive_cpu_note"] = (
            "This ratio is a RESULT, not an error rate. A high value means these invariants "
            "are structurally unmeasurable on bmv2 under CPU-consuming chaos -- which is a "
            "finding about the plane, and must be reported rather than hidden by scoring the "
            "voided rounds as passes.")
        report["result"] = "full run complete"

    text = json.dumps(report, indent=2)
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
