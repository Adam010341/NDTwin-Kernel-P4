#!/usr/bin/env bash
# Orchestrator rerun on the test merge 7b600ab0 (trunk 9c2e59e4 + ebdf365e), p4_src/build linked to the main checkout's. [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hbw-intake-0926; O=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/hbw; PY=$W/p4_proxy/venv/bin/python; GUARD=$W/tools/build_guard/guarded_build.sh; P=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-hbw; mkdir -p "$TMPDIR"; export PYTHONDONTWRITEBYTECODE=1
[[ "$(git -C "$W" rev-parse HEAD)" == 7b600ab0* ]] || { echo "REFUSE: HEAD is not 7b600ab0"; exit 2; }
MODS=$(ls "$W"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
run() { local n=$1 cwd=$2; shift 2; local log=$O/rerun-$n.7b600ab0.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cwd $cwd cmd $*"; ls -l "$W/p4_proxy/p4_src/build" | head -1; } > "$log"
  ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(Ran |OK|FAILED|SELF-TEST|mutation gate|every new test)' $log | tail -2 | tr '\n' ' ')"; }
run p4_proxy_suite "$W/p4_proxy" env PYTHONPATH="$W/p4_proxy" "$PY" -m unittest $MODS
run test_ndt_heartbeat "$W" bash tests/shell/test_ndt_heartbeat.sh
run live08_selftest "$W" bash $P/08_heartbeat.sh --self-test
run live07_selftest "$W" bash $P/07_roles_basic.sh --self-test
run mutate_roles_binding "$W" bash tests/shell/mutate_roles_binding.sh
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || { echo "TRACKED CHANGES LEFT:"; git -C "$W" status --porcelain --untracked-files=no; }
echo RERUN3-DONE
