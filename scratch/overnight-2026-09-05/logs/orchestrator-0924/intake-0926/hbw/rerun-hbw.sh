#!/usr/bin/env bash
# Orchestrator rerun of segment W's own gates on a test merge (trunk 9c2e59e4 + 1a3ebd7f = a4be233b). [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hbw-intake-0926; O=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/hbw; PY=$W/p4_proxy/venv/bin/python; GUARD=$W/tools/build_guard/guarded_build.sh
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-hbw; mkdir -p "$TMPDIR"; export PYTHONDONTWRITEBYTECODE=1
MODS=$(ls "$W"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
run() { local n=$1 cwd=$2; shift 2; local log=$O/rerun-$n.a4be233b.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cwd $cwd cmd $*"; } > "$log"
  ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -vE '^# rc=|^guarded_build: |ResourceWarning' $log | tail -1)"; }
run p4_proxy_suite "$W/p4_proxy" env PYTHONPATH="$W/p4_proxy" "$PY" -m unittest $MODS
run test_ndt_heartbeat "$W" bash tests/shell/test_ndt_heartbeat.sh
run live08_selftest "$W" bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/08_heartbeat.sh --self-test
run test_ndtwin_lab_heartbeat "$W" bash tests/shell/test_ndtwin_lab_heartbeat.sh
run spike_selfcheck "$W" bash doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh --self-test
echo RERUN-DONE
