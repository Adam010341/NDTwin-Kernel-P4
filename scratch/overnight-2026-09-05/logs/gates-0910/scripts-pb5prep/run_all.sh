#!/usr/bin/env bash
# Worker pb5prep: every phase, in order, at the worktree's current HEAD. Serial on purpose (the
# suites and lanes queue on the shared build lock anyway, and phase 5 moves the venv phases 3-4 use).
# [Co-developed with claude code -- Adam]
source /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep/common.sh
N313="$WT/scratch/pb5prep/rehearsal-$SHA/p4_proxy/venv/bin/python"
N312="$W/venv312-$SHA/bin/python"
touch "$W/mainvenv.marker-$SHA"
step() { echo "=== $(date -u +%T) $*"; }
step fp-before;   bash "$S/mainvenv_fp.sh" before-all "$W/mainvenv.marker-$SHA" | tail -3
step phase1;      bash "$S/phase1_py312.sh" > "$W/phase1-$SHA.console" 2>&1; echo "phase1 rc=$?"
step phase2;      bash "$S/phase2_rehearsal_forward.sh" > "$W/phase2-$SHA.console" 2>&1; echo "phase2 rc=$?"
step suites-new313; bash "$S/phase3_suites.sh" new313 "$N313"
step suites-new312; bash "$S/phase3_suites.sh" new312 "$N312"
step suites-main;   bash "$S/phase3_suites.sh" main "$MAINPY"
step lanes-new313;  bash "$S/phase3_lanes.sh" new313 "$N313" --with-3b > "$W/lanes-new313-$SHA.console" 2>&1; echo "rc=$?"
step lanes-main;    bash "$S/phase3_lanes.sh" main "$MAINPY" --with-3b > "$W/lanes-main-$SHA.console" 2>&1; echo "rc=$?"
step lanes-new312;  bash "$S/phase3_lanes.sh" new312 "$N312" > "$W/lanes-new312-$SHA.console" 2>&1; echo "rc=$?"
step phase4;      bash "$S/phase4_misc.sh" "$N313" > "$W/phase4-$SHA.console" 2>&1; echo "phase4 rc=$?"
step phase5;      bash "$S/phase5_rehearsal_rollback.sh" > "$W/phase5-$SHA.console" 2>&1; echo "phase5 rc=$?"
step diffs;       bash "$S/phase6_verdictdiff.sh" new313 main; bash "$S/phase6_verdictdiff.sh" new312 main
step fp-after;    bash "$S/mainvenv_fp.sh" after-all "$W/mainvenv.marker-$SHA" | tail -4
step done
