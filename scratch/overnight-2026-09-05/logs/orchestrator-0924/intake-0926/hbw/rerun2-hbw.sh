#!/usr/bin/env bash
# F2: proxy suite on the test merge a4be233b with p4_proxy/p4_src/build linked to the main checkout's (as red_first_w.sh:13 does); plus every ndt shell suite, naming any red check. [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hbw-intake-0926; O=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/hbw; PY=$W/p4_proxy/venv/bin/python; GUARD=$W/tools/build_guard/guarded_build.sh
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-hbw; mkdir -p "$TMPDIR"; export PYTHONDONTWRITEBYTECODE=1
MODS=$(ls "$W"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
run() { local n=$1 cwd=$2; shift 2; local log=$O/rerun-$n.a4be233b.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cwd $cwd cmd $*"; ls -l "$W/p4_proxy/p4_src/build" | head -1; } > "$log"
  ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(Ran |OK|FAILED|suites red)' $log | tail -2 | tr '\n' ' ')"; }
run p4_proxy_suite_withbuild "$W/p4_proxy" env PYTHONPATH="$W/p4_proxy" "$PY" -m unittest $MODS
run ndt_suites2 "$W" bash $O/ndt_suites2.sh "$W"
echo RERUN2-DONE
