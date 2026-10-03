"""The verdict vocabulary, the decision order, rule D, and the rollup. Pure functions.

[Co-developed with claude code -- Adam]

DESIGN 2.1. Each cell walks five steps and the first that decides, decides:

  1. NDTwin's "cannot" answer (no route in openapi, 404 "not in this pipeline", 501, a
     constant field). A RED candidate straight away -- the oracle is not needed and not read.
     EXPECTED refusals are not this: CP2's 409 and the K1-neg / T3-neg 404s are pass
     conditions, judged at step 5.
  2. Rule D: a gate cell this one depends on that is not GREEN -> NOT RUN, naming the gate;
     every gate GREEN but a self-check it depends on failed -> PROBE-BROKEN.
  3. The stimulus, as the SENDER reports it (active cells): 0 or unknown -> NOT RUN.
  4. The oracle unreadable -> NOT RUN.
  5. The comparison -> GREEN / PARTIAL / RED. A GREEN that rests on a thrift match also needs
     its same-window negative read: not taken -> NOT RUN, failed -> PROBE-BROKEN.

A RED from step 1 or 5 stands only if the cell's attribution holds; otherwise UNATTRIBUTED, which
the rollup does not count. A self-check failing is PROBE-BROKEN, never RED.
"""
from __future__ import annotations

GREEN = "GREEN"
PARTIAL = "PARTIAL"
RED = "RED"
UNATTRIBUTED = "UNATTRIBUTED"
NOT_RUN = "NOT RUN"
READ_ONLY = "READ-ONLY"
PROBE_BROKEN = "PROBE-BROKEN"
VERDICTS = (GREEN, PARTIAL, RED, UNATTRIBUTED, NOT_RUN, READ_ONLY, PROBE_BROKEN)

#: self-check states
SC_OK, SC_FAIL = "ok", "fail"

CAN, PART, CANNOT, UNDECIDED = "can", "partial", "cannot", "undecided"


class Verdict(object):
    def __init__(self, verdict, reason="", partial=None, attribution=None, phase=None,
                 evidence=None):
        assert verdict in VERDICTS, verdict
        self.verdict = verdict
        self.reason = reason
        self.partial = partial              # "a" | "b" | "c" | "d" for PARTIAL
        self.attribution = attribution      # {"kind": [...], "ok": bool}
        self.phase = phase                  # which step decided
        self.evidence = sorted(evidence or [])

    @property
    def label(self):
        return "PARTIAL(%s)" % self.partial if self.verdict == PARTIAL and self.partial else self.verdict

    def as_dict(self):
        return {"verdict": self.verdict, "label": self.label, "reason": self.reason,
                "partial": self.partial, "attribution": self.attribution, "phase": self.phase}

    def __repr__(self):
        return "Verdict(%s, %r)" % (self.label, self.reason)


class Outcome(object):
    """What a cell's `cannot` or `compare` function found."""

    def __init__(self, verdict, reason="", partial=None, evidence=()):
        self.verdict = verdict
        self.reason = reason
        self.partial = partial
        self.evidence = set(evidence)


def green(reason=""):
    return Outcome(GREEN, reason)


def partial(tag, reason=""):
    return Outcome(PARTIAL, reason, partial=tag)


def red(reason, *evidence):
    return Outcome(RED, reason, evidence=evidence)


def not_run(reason):
    return Outcome(NOT_RUN, reason)


def unattributed(reason):
    return Outcome(UNATTRIBUTED, reason)


def broken(reason):
    return Outcome(PROBE_BROKEN, reason)


def attribution_holds(required, evidence, obs):
    """Every required kind is established: by the deciding function's own evidence (structural:
    NDTwin's own declaration; thrift: the oracle reading itself) or by the observation's
    attribution block (bmv2: B's controller did the same thing and thrift saw it; wire: the
    receiver proved what was on the wire; static: offline evidence such as binary strings or a
    throwaway switch). A requirement written "bmv2|static" is met by either."""
    have = set(evidence)
    for kind, ok in ((obs.get("attribution") or {}).items()):
        if ok is True:
            have.add(kind)
    for req in required:
        if not any(alt in have for alt in req.split("|")):
            return False
    return True


def _red_or_unattributed(spec, out, obs, phase):
    ok = attribution_holds(spec.red_attribution, out.evidence, obs)
    attr = {"kind": list(spec.red_attribution), "ok": ok}
    if ok:
        return Verdict(RED, out.reason, attribution=attr, phase=phase, evidence=out.evidence)
    return Verdict(UNATTRIBUTED, "%s -- attribution %s not established"
                   % (out.reason, "+".join(spec.red_attribution)), attribution=attr, phase=phase,
                   evidence=out.evidence)


def _finish(spec, out, obs, phase):
    if out.verdict == RED:
        return _red_or_unattributed(spec, out, obs, phase)
    return Verdict(out.verdict, out.reason, partial=out.partial, phase=phase,
                   evidence=out.evidence)


def gate_problem(spec, ctx):
    """Rule D for a cell or a self-check: (verdict, reason) or None when every dependency holds."""
    for gate in spec.gates:
        v = ctx.cell(gate)
        if v is None or v.verdict != GREEN:
            return NOT_RUN, "gate %s %s" % (gate, v.label if v is not None else "not judged")
    for sc in spec.self_checks:
        state = ctx.self_check(sc)
        if state is None:
            return NOT_RUN, "self-check %s not run" % sc
        if state.verdict == NOT_RUN:
            return NOT_RUN, state.reason
        if state.verdict == PROBE_BROKEN:
            return PROBE_BROKEN, "self-check %s failed: %s" % (sc, state.reason)
    return None


def decide(spec, obs, ctx):
    """The five steps of DESIGN 2.1 for one cell. `obs` is the observation dict:

        answer       NDTwin's side (route presence, http status, values, ...)
        sent         frames the sender reported sending (active cells)
        oracle       the independent reading; None = unreadable
        negative     {"absent": bool} -- the same-window negative read; None = not taken
        attribution  {"bmv2": bool, "wire": bool, "static": bool}
        pre          {"ok": bool, "why": str} -- the cell's stated precondition
    """
    if spec.by_design is not None:
        return Verdict(NOT_RUN, "by design: %s" % spec.by_design, phase="design")
    obs = obs or {}
    # 1. NDTwin's own "cannot"
    if spec.cannot is not None:
        out = spec.cannot(obs)
        if out is not None:
            return _red_or_unattributed(spec, out, obs, "cannot")
    # 2. rule D
    problem = gate_problem(spec, ctx)
    if problem is not None:
        return Verdict(problem[0], problem[1], phase="gate")
    # 3. stimulus
    if spec.kind == "active":
        sent = obs.get("sent")
        if not sent:
            return Verdict(NOT_RUN, "stimulus: the sender reported %s sent" % (sent,), phase="stimulus")
    # 4. oracle
    if spec.needs_oracle and obs.get("oracle") is None:
        return Verdict(NOT_RUN, "oracle unreadable", phase="oracle")
    # precondition (the cell's own, stated in its row)
    if spec.precondition is not None:
        ok, why = spec.precondition(obs)
        if ok is not True:
            return Verdict(NOT_RUN, "precondition: %s" % (why or "not established"),
                           phase="precondition")
    # 5. compare
    out = spec.compare(obs)
    if out.verdict == GREEN and spec.negative_read:
        neg = obs.get("negative")
        if neg is None:
            return Verdict(NOT_RUN, "same-window negative read not taken", phase="negative")
        if neg.get("absent") is not True:
            return Verdict(PROBE_BROKEN, "same-window negative read failed: %s"
                           % (neg.get("why") or "the object that must be absent read as present"),
                           phase="negative")
    return _finish(spec, out, obs, "compare")


def decide_self_check(sc, obs, ctx):
    """A self-check: NOT RUN by rule D, else ok or PROBE-BROKEN. Never RED (DESIGN 2.1)."""
    problem = gate_problem(sc, ctx)
    if problem is not None:
        return Verdict(problem[0], problem[1], phase="gate")
    if obs is None:
        return Verdict(NOT_RUN, "not observed", phase="oracle")
    ok, why = sc.check(obs)
    if ok:
        return Verdict(GREEN, why or "ok", phase="compare")
    return Verdict(PROBE_BROKEN, why, phase="compare")


class Context(object):
    """The verdicts so far, so rule D can look gates and self-checks up."""

    def __init__(self):
        self.cells = {}
        self.self_checks = {}

    def cell(self, cid):
        return self.cells.get(cid)

    def self_check(self, sid):
        return self.self_checks.get(sid)


def judge_all(table, observations, sc_observations):
    """Every self-check and cell, in dependency order. Returns the Context."""
    ctx = Context()
    pending_cells = [c for c in table.cells if c.alias_of is None]
    pending_sc = list(table.self_checks)
    for _ in range(len(pending_cells) + len(pending_sc) + 1):
        progressed = False
        for sc in list(pending_sc):
            if all(g in ctx.cells for g in sc.gates) and all(s in ctx.self_checks for s in sc.self_checks):
                ctx.self_checks[sc.id] = decide_self_check(sc, sc_observations.get(sc.id), ctx)
                pending_sc.remove(sc)
                progressed = True
        for spec in list(pending_cells):
            if all(g in ctx.cells for g in spec.gates) and all(s in ctx.self_checks for s in spec.self_checks):
                ctx.cells[spec.id] = decide(spec, observations.get(spec.id), ctx)
                pending_cells.remove(spec)
                progressed = True
        if not progressed:
            break
    if pending_cells or pending_sc:
        raise ValueError("dependency cycle: %s" % [s.id for s in pending_cells + pending_sc])
    for spec in table.cells:
        if spec.alias_of is not None:
            ctx.cells[spec.id] = ctx.cells[spec.alias_of]
    for ctl in table.controls:
        ctx.cells[ctl.id] = ctl.judge(observations.get(ctl.id))
    return ctx


# --- rollup -----------------------------------------------------------------------------------

COUNTED = (GREEN, PARTIAL, RED)


def dimension_answer(verdicts):
    """One dimension's answer from its cells' verdicts. DESIGN 5.1: only GREEN, PARTIAL and an
    attributed RED count; none counted -> undecided; all GREEN -> can; all RED -> cannot; else
    partial. NOT RUN never counts as green, and the answer is not the best cell's."""
    counted = [v for v in verdicts if v in COUNTED]
    if not counted:
        return UNDECIDED
    if all(v == GREEN for v in counted):
        return CAN
    if all(v == RED for v in counted):
        return CANNOT
    return PART


def rollup(table, ctx, scope):
    """{dimension: answer} and the four totals, for scope 'core' (core cells, the 16 keys) or
    'full' (every cell, every key)."""
    dims = table.core_dimensions if scope == "core" else table.dimensions
    per = {}
    for dim in dims:
        vs = [ctx.cells[c.id].verdict for c in table.cells
              if c.dimension == dim and c.id in ctx.cells and (scope == "full" or c.scope == "core")]
        per[dim] = dimension_answer(vs)
    totals = {k: sum(1 for a in per.values() if a == k) for k in (CAN, PART, CANNOT, UNDECIDED)}
    return {"dimensions": per, "totals": totals}


def run_verdict(ctx, bringups_complete=True):
    """COMPLETE | PROBE-BROKEN | INCOMPLETE, and the rc (0, 1, 2)."""
    if any(v.verdict == PROBE_BROKEN for v in ctx.cells.values()) or \
            any(v.verdict == PROBE_BROKEN for v in ctx.self_checks.values()):
        return "PROBE-BROKEN", 1
    if not bringups_complete:
        return "INCOMPLETE", 2
    return "COMPLETE", 0


def telemetry_none_check(verdicts, link_usage_absent):
    """The telemetry `none` bring-up (DESIGN 2.3): V1, CH1 and CH7 must be RED and
    assert_link_usage_absent must hold. Anything else -> PROBE-BROKEN. Returns (ok, why)."""
    if link_usage_absent is not True:
        return False, "assert_link_usage_absent did not hold"
    wrong = sorted(c for c in ("V1", "CH1", "CH7") if (verdicts.get(c) or NOT_RUN) != RED)
    if wrong:
        return False, "with telemetry none these must be RED and are not: %s" % ", ".join(wrong)
    return True, "V1, CH1, CH7 RED and no link usage, as a fabric with no telemetry must read"
