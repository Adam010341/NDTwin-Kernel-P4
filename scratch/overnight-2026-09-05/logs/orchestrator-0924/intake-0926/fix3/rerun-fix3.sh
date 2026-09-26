#!/usr/bin/env bash
# Orchestrator rerun on the octopus test merge 5475445a (cafd518a + 60194b09 + f4f43a32 + e012a5a7). [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hbw-intake-0926; O=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/fix3; GUARD=$W/tools/build_guard/guarded_build.sh; P=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
[[ "$(git -C "$W" rev-parse HEAD)" == 5475445a* ]] || { echo "REFUSE: HEAD is not 5475445a"; exit 2; }
export PYTHONDONTWRITEBYTECODE=1
run() { local n=$1 cwd=$2; shift 2; local log=$O/rerun-$n.5475445a.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cwd $cwd TMPDIR ${TMPDIR:-} cmd $*"; } > "$log"
  ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(Ran |OK|FAILED|SELF-TEST|mutation gate|PASS|FAIL)' $log | tail -2 | tr '\n' ' ')"; }
export TMPDIR=/tmp/claude-1000/nd-orch; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run test_ndt_serve "$W" python3 tests/python/test_ndt_serve.py
run test_ndt_serve_cells "$W" python3 tests/python/test_ndt_serve_cells.py
rm -rf "$TMPDIR"; export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-fix3; mkdir -p "$TMPDIR"
run live08_selftest "$W" bash $P/08_heartbeat.sh --self-test
run live07_selftest "$W" bash $P/07_roles_basic.sh --self-test
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || git -C "$W" status --porcelain --untracked-files=no
echo RERUN-FIX3-DONE
