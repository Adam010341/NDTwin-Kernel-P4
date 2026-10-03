"""One lab run of the health check: S0's packages -> bring-up A -> bring-up B -> verdicts. (Cut 2)

[Co-developed with claude code -- Adam]

design 4.2's order. S0 must be COMPLETE before anything touches the lab. Then each bring-up is
one LabRound (claim -> up -> body -> teardown, crash-safe), on its OWN package directory inside
the run directory (S0 wrote them to <run>/packages/<name>), and nothing is judged until both are
done: A's cells whose RED needs a `bmv2` attribution get it from B's confirmed attributions, so
judging A alone would make every one of them UNATTRIBUTED.

`--only` narrows bring-up A (round_a.expand) and keeps B's attributions (design 4.4); the
see-red run of design 5.2-④ is `--mutant --only K1,TTL1 --bringups A`.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil

from . import attribution as AT
from . import expected as E
from . import report as R
from . import runtime_cli as RC
from .cells import table as T
from .cells import verdict as V
from .lab_round import LabRound
from .round_a import ARound
from .round_b import BRound


def load_model(exercise_dir):
    spec = importlib.util.spec_from_file_location("hc_gen_lab", os.path.join(exercise_dir, "gen_runtime.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def expectations(s0_out, run_dir, model):
    """PL1's pipelines (S0's p4info sha16, which is what switch_state reports, main.py:511-523),
    and every switch's runtime document and p4info key/param orders (T1)."""
    builds = s0_out["builds"]
    alt, main = builds["build/hc_alt"]["p4info_sha16"], builds["build/hc_main"]["p4info_sha16"]
    pipelines = {"1": alt, "2": main, "3": main, "4": main}
    runtimes, orders = {}, {}
    for d in (1, 2, 3, 4):
        runtimes[d] = model.runtime(d)
        with open(os.path.join(run_dir, "exercise", "build", "%s.p4.p4info.txtpb" % model.program(d)),
                  encoding="utf-8") as fh:
            orders[d] = RC.p4info_orders(fh.read())
    return pipelines, runtimes, orders


def pft_observation(s0_out):
    pf = (s0_out.get("preflight") or {}).get("PF-T") or {}
    main = (s0_out.get("self_checks") or {}).get("main") or {}
    return {"answer": {"rc": pf.get("rc"), "g5_rows": pf.get("g5_rows", 0),
                       "other_fail_rows": pf.get("other_fail_rows", 0)},
            "attribution": {"static": bool(main.get("ternary_held"))}}


def merge(observations, confirmed):
    """A's observations with B's attributions attached; with no B run, none is attached."""
    out = dict(observations)
    if confirmed is None:
        return out
    for cell, attr in AT.for_cells(confirmed).items():
        if cell in out and out[cell] is not None:
            out[cell] = dict(out[cell], attribution=dict(out[cell].get("attribution") or {}, **attr))
    return out


def ended_clean(lab_round, rec):
    """Why a round did NOT end clean, or [] (Cut 2 review MAJOR-3): released, `ndt down` and
    `ndt release` rc 0, no process it failed to stop, nothing left in its state file. Only then
    may the next bring-up claim the lab -- anything else is recover.sh's to finish first."""
    st, why = lab_round.state, []
    if st.get("phase") != "released":
        why.append("phase %s" % st.get("phase"))
    if rec.get("down_rc") != 0:
        why.append("ndt down rc %s" % rec.get("down_rc"))
    if rec.get("release_rc") != 0:
        why.append("ndt release rc %s" % rec.get("release_rc"))
    if any("could not stop" in p for p in rec.get("problems") or []):
        why.append("a process it could not stop")
    left = [k for k in ("sniffers", "controllers", "netem") if st.get(k)]
    if left:
        why.append("%s left in LAB_STATE.json" % ", ".join(left))
    return why


def keep_state(cfg, bringup):
    """A copy of the state file as this bring-up left it (the next round rewrites the file)."""
    if os.path.exists(cfg.lab_state_path):
        shutil.copyfile(cfg.lab_state_path, os.path.join(os.path.dirname(cfg.lab_state_path),
                                                         "LAB_STATE.%s.json" % bringup))


def run_lab(cfg, runner, s0_out, run_dir, run_id, bringups=("A", "B"), only=None, mutant=False,
            tutorials_utils=None, round_cls=LabRound, a_kwargs=None, b_kwargs=None,
            expected_tsv=None, log=print):
    """Returns (rc, health document). rc: 0 COMPLETE, 1 PROBE-BROKEN, 2 INCOMPLETE."""
    if s0_out.get("verdict") != "COMPLETE":
        log("S0 is %s: the lab is not touched" % s0_out.get("verdict"))
        return 1, None
    model = load_model(os.path.join(run_dir, "exercise"))
    pipelines, runtimes, orders = expectations(s0_out, run_dir, model)
    packages = os.path.join(run_dir, "packages")
    recs, a, b, problems = [], None, None, []
    if "A" in bringups:
        a = ARound(cfg, runner, run_id, model, pipelines, runtimes, orders, only=only, **(a_kwargs or {}))
        pkg = os.path.join(packages, "A-MUT" if mutant else "A")
        log("bring-up A (%s): %d cell(s)" % (os.path.basename(pkg), len(a.selected)))
        lr_a = round_cls(cfg, runner, "A", pkg, run_id)
        recs.append(lr_a.run(a.body))
        keep_state(cfg, "A")
        log("  A: complete=%s problems=%s" % (recs[-1]["complete"], recs[-1]["problems"]))
        why = ended_clean(lr_a, recs[-1])
        if why and "B" in bringups:
            problems.append("B not brought up: A did not end clean (%s); finish with recover.sh %s"
                            % ("; ".join(why), run_dir))
            log("  " + problems[-1])
            bringups = tuple(x for x in bringups if x != "B")
    if "B" in bringups:
        b = BRound(cfg, runner, run_id, model, os.path.join(run_dir, "exercise", "build"), runtimes,
                   tutorials_utils or os.path.join(os.path.expanduser("~"), "tutorials", "utils"),
                   **(b_kwargs or {}))
        log("bring-up B (external): the eleven attributions")
        recs.append(round_cls(cfg, runner, "B", os.path.join(packages, "B"), run_id).run(b.body))
        keep_state(cfg, "B")
        log("  B: complete=%s problems=%s" % (recs[-1]["complete"], recs[-1]["problems"]))
    observations = merge(a.observations if a else {}, b.confirmed if b else None)
    observations["PF-T"] = pft_observation(s0_out)
    ctx = V.judge_all(T.TABLE, observations, a.sc_observations if a else {})
    expected = E.load(expected_tsv or cfg.expected_tsv)
    ann = E.annotate(ctx, expected)
    rollups = {s: V.rollup(T.TABLE, ctx, s) for s in V.SCOPES}
    complete = bool(recs) and all(r.get("complete") is True for r in recs) and not problems
    verdict, rc = V.run_verdict(ctx, bringups_complete=complete)
    rows = R.table_rows(T.TABLE, ctx, ann)
    with open(os.path.join(run_dir, "00_table.tsv"), "w", encoding="utf-8") as fh:
        fh.write(R.tsv(rows))
    doc = R.health(run_id, s0_out.get("repo", {}).get("probe_tree"), s0_out.get("identity") or {},
                   {"verdict": s0_out.get("verdict")}, recs, T.TABLE, ctx, ann, rollups, verdict)
    doc["self_checks_observed"] = sorted((a.sc_observations if a else {}))
    doc["attributions"] = b.confirmed if b else None
    doc["only"] = sorted(a.selected) if a else []
    doc["mutant"] = bool(mutant)
    doc["problems"] = problems
    R.dump(os.path.join(run_dir, "health.json"), doc)
    with open(os.path.join(run_dir, "observations.json"), "w", encoding="utf-8") as fh:
        json.dump({"cells": observations, "self_checks": a.sc_observations if a else {}}, fh,
                  indent=2, sort_keys=True, default=_jsonable)
    log(R.render(rows, rollups))
    log("verdict %s%s" % (verdict, "  -- NOT PUBLISHABLE" if verdict == "PROBE-BROKEN" else ""))
    return rc, doc


def _jsonable(x):
    if isinstance(x, (set, frozenset)):
        return sorted(x, key=repr)
    return repr(x)
