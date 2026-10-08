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
import signal

from . import attribution as AT
from . import expected as E
from . import report as R
from . import runtime_cli as RC
from .cells import table as T
from .cells import verdict as V
from . import frozen as FZ
from .lab_round import LabRound, SignalAbort
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


def take_unrecorded(cfg, holder, recs):
    """(Cut 2 round 5, NIT 10) A stop (or any exception) that leaves a round's `run()` after the record is
    final but before `recs.append` has run leaves that round out of health.json. Every round that was
    started keeps its record in `.rec`: add the ones missing, and the state file as that round left it."""
    for lr in holder.get("rounds") or []:
        rec = getattr(lr, "rec", None)
        if rec is not None and not any(rec is r for r in recs):
            recs.append(rec)
            keep_state(cfg, lr.bringup)


def signalled(rec):
    """The round was stopped by SIGTERM / SIGINT / SIGHUP (lab_round records it so)."""
    return any(str(p).startswith("aborted by signal") for p in (rec or {}).get("problems") or [])


def _stop_on_signals():
    """(Cut 2 review N1) For the whole run, not only inside a round: a stop signal between A's
    teardown and B's claim raises SignalAbort here too, instead of killing the probe with its
    default action. Returns the handlers it replaced."""
    def raiser(signum, _frame):
        raise SignalAbort(signum)
    return {s: signal.signal(s, raiser) for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}


def _rounds(cfg, runner, run_id, model, pipelines, runtimes, orders, only, mutant, bringups,
            packages, round_cls, a_kwargs, b_kwargs, tutorials_utils, run_dir, recs, problems,
            log, holder):
    """Bring-up A, then -- only if A ended clean and was not stopped -- bring-up B."""
    if "A" in bringups:
        a = holder["A"] = ARound(cfg, runner, run_id, model, pipelines, runtimes, orders, only=only,
                                 **(a_kwargs or {}))
        pkg = os.path.join(packages, "A-MUT" if mutant else "A")
        log("bring-up A (%s): %d cell(s)" % (os.path.basename(pkg), len(a.selected)))
        lr_a = round_cls(cfg, runner, "A", pkg, run_id)
        holder.setdefault("rounds", []).append(lr_a)
        recs.append(lr_a.run(a.body))
        keep_state(cfg, "A")
        log("  A: complete=%s problems=%s" % (recs[-1]["complete"], recs[-1]["problems"]))
        if signalled(recs[-1]):
            # (Cut 2 review N1) a stop is a stop: no further claim, whatever A's teardown did
            problems.append("stop signal during bring-up A: the run ends here, B not brought up")
            log("  " + problems[-1])
            return
        why = ended_clean(lr_a, recs[-1])
        if why and "B" in bringups:
            problems.append("B not brought up: A did not end clean (%s); finish with recover.sh %s"
                            % ("; ".join(why), run_dir))
            log("  " + problems[-1])
            return
    if "B" in bringups:
        b = holder["B"] = BRound(cfg, runner, run_id, model, os.path.join(run_dir, "exercise", "build"),
                                 runtimes, tutorials_utils or os.path.join(os.path.expanduser("~"),
                                                                           "tutorials", "utils"),
                                 **(b_kwargs or {}))
        log("bring-up B (external): the eleven attributions")
        lr_b = round_cls(cfg, runner, "B", os.path.join(packages, "B"), run_id)
        holder.setdefault("rounds", []).append(lr_b)
        recs.append(lr_b.run(b.body))
        keep_state(cfg, "B")
        log("  B: complete=%s problems=%s" % (recs[-1]["complete"], recs[-1]["problems"]))
        if signalled(recs[-1]):
            problems.append("stop signal during bring-up B")
        elif b.failed:
            # (Cut 2 review N2) a B that claimed the lab but whose controller did nothing
            problems.append("B's controller did not do its part: %s" % b.failed)
            log("  " + problems[-1])


def run_lab(cfg, runner, s0_out, run_dir, run_id, bringups=("A", "B"), only=None, mutant=False,
            tutorials_utils=None, round_cls=LabRound, a_kwargs=None, b_kwargs=None,
            expected_tsv=None, log=print, identity=None, signals=True, frozen=None):
    """Returns (rc, health document). rc: 0 COMPLETE, 1 PROBE-BROKEN, 2 INCOMPLETE or SEE-RED-NOT-SEEN.

    (Cut 2 round 5, #2) Whatever ends the run early -- S0 not COMPLETE, a set-up that fails
    (load_model, expectations), a round that cannot start (LAB_STATE.json left by an unfinished
    round, a package outside the run dir) -- is INCOMPLETE rc 2 with a health.json that says why:
    rc 1 is PROBE-BROKEN only, which on the see-red run is the pass.

    `frozen`: the code copies `probe.py lab` froze before S0 and checked against HEAD
    (frozen.freeze). Without it -- the offline tests -- the files are copied here, unchecked."""
    recs, problems, holder, run_stopped = [], [], {}, []
    frozen = frozen or FZ.freeze(run_dir)
    ended_early = False                 # an exception ended the rounds (a signal is `run_stopped`)
    prepared = None
    if s0_out.get("verdict") != "COMPLETE":
        bad = [c.get("name") for c in s0_out.get("checks") or [] if not c.get("ok")]
        problems.append("S0 is %s: the lab is not touched%s" % (
            s0_out.get("verdict"), (" (failed: %s)" % "; ".join(str(n) for n in bad)) if bad else ""))
        log(problems[-1])
    else:
        try:
            model = load_model(os.path.join(run_dir, "exercise"))
            pipelines, runtimes, orders = expectations(s0_out, run_dir, model)
            prepared = (model, pipelines, runtimes, orders)
        except Exception as exc:  # noqa: BLE001 -- a run that cannot be set up is INCOMPLETE, with the reason
            problems.append("the run could not be set up: %s: %s" % (type(exc).__name__, exc))
            log("  " + problems[-1])
    if prepared is not None:
        model, pipelines, runtimes, orders = prepared
        packages = os.path.join(run_dir, "packages")
        a_kwargs = dict({"hostside": frozen.hostside}, **(a_kwargs or {}))
        b_kwargs = dict({"hostside": frozen.hostside, "controller": frozen.controller,
                         "adapter": frozen.adapter}, **(b_kwargs or {}))
        old_handlers = _stop_on_signals() if signals else None
        try:
            _rounds(cfg, runner, run_id, model, pipelines, runtimes, orders, only, mutant, bringups,
                    packages, round_cls, a_kwargs, b_kwargs, tutorials_utils, run_dir, recs, problems,
                    log, holder)
        except SignalAbort as exc:
            take_unrecorded(cfg, holder, recs)
            # (Cut 2 review N1) between rounds, or before a round's own handlers are in place
            problems.append("stop signal %d outside a bring-up's body: the run ends here; finish with "
                            "recover.sh %s if a round was under way" % (exc.signum, run_dir))
            run_stopped.append(exc.signum)
            log("  " + problems[-1])
        except Exception as exc:  # noqa: BLE001 -- (round 5, #2) StateInUse, a package outside the run dir, ...
            take_unrecorded(cfg, holder, recs)
            problems.append("the run ended on %s: %s; finish with recover.sh %s if a round was under way"
                            % (type(exc).__name__, exc, run_dir))
            ended_early = True
            log("  " + problems[-1])
        finally:
            if old_handlers is not None:
                for sig, h in old_handlers.items():
                    signal.signal(sig, h)
    a, b = holder.get("A"), holder.get("B")
    observations = merge(a.observations if a else {}, b.confirmed if b else None)
    if s0_out.get("verdict") == "COMPLETE":
        observations["PF-T"] = pft_observation(s0_out)       # S0's answer, when S0 is whole
    ctx = V.judge_all(T.TABLE, observations, a.sc_observations if a else {})
    expected = E.load(expected_tsv or cfg.expected_tsv)
    ann = E.annotate(ctx, expected)
    rollups = {s: V.rollup(T.TABLE, ctx, s) for s in V.SCOPES}
    complete = bool(recs) and all(r.get("complete") is True for r in recs) and not problems
    # (round 4, F3) a recorded stop overrides the headline; a see-red pass needs a complete, clean run.
    # (round 5, #2) So does a run that ended early on an exception, or never started: it is
    # INCOMPLETE whatever the cells that did get read say.
    stopped = any(signalled(r) for r in recs) or bool(run_stopped) or ended_early
    verdict, rc = V.run_verdict(ctx, bringups_complete=complete, stopped=stopped, see_red=bool(mutant))
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
    doc["root_code"] = frozen.root_code            # what root ran: sha256 of the copies
    doc["frozen_head"] = frozen.head                # the commit every copy was checked against (None: unchecked)
    doc["frozen_code"] = frozen.sums               # every file any round ran, as relative path -> sha256
    # (Cut 2 review m4) design 4.3's system_under_test and the Q6(a) gate fingerprint
    doc["system_under_test"] = (identity or {}).get("system_under_test")
    doc["gate_fingerprint"] = (identity or {}).get("gate_fingerprint")
    R.dump(os.path.join(run_dir, "health.json"), doc)
    with open(os.path.join(run_dir, "observations.json"), "w", encoding="utf-8") as fh:
        json.dump({"cells": observations, "self_checks": a.sc_observations if a else {}}, fh,
                  indent=2, sort_keys=True, default=_jsonable)
    log(R.render(rows, rollups))
    log("verdict %s%s" % (verdict, {"PROBE-BROKEN": "  -- NOT PUBLISHABLE",
                                    "SEE-RED-NOT-SEEN": "  -- the mutant was not noticed: the probe cannot see red"
                                    }.get(verdict, "")))
    return rc, doc


def _jsonable(x):
    if isinstance(x, (set, frozenset)):
        return sorted(x, key=repr)
    return repr(x)
