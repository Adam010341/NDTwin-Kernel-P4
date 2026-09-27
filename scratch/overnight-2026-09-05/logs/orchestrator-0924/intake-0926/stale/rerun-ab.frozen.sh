#!/usr/bin/env bash
# Orchestrator rerun on the stacked test merge 81df00cf (c34a643a + probe stubs 356d4e4e + stale suites
# d2a9d641), in a worktree that has NO 08-20 raw: the six stubbed suites and their gate, the three
# stale suites and their gates, trunk's versions of the three as the red arm, and the anchor checker.
# Through the guard, sudo/curl tripwire outermost on PATH. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-hbw-intake-0926
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/stale; GUARD=$W/tools/build_guard/guarded_build.sh
M=81df00cff2ef12e8089309c00011c33f44caf87f
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
[[ ! -e "$W/doc/audit/2026-08-20_sampling-rate-and-cpu/raw/t008_poll_twin.jsonl" ]] || { echo "REFUSE: raw present -- not hermetic"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-ab; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.81df00cf.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '(Ran [0-9]+|[0-9]+ passed|mutation|survivor|killed|cells ok|SKIP)' $log | tail -1)"; }
# red arm: trunk's three stale suites, as copies beside the real ones (same tree otherwise)
for s in test_start_bg_log_rotation test_gate_exit_code_not_tee test_l1_shell_scoring; do
  git -C "$W" show c34a643a:tests/shell/$s.sh > "$W/tests/shell/.redfirst-ab-$s.sh"
  run TRUNK_$s bash tests/shell/.redfirst-ab-$s.sh
  rm -f "$W/tests/shell/.redfirst-ab-$s.sh"
done
for s in test_apps_stop_kills_the_group test_cell_gate_suspect_wiring test_lab_handoff test_ndt_app_orphans test_ndt_honesty test_ndt_sample_rate_reads_both_bounds \
         test_start_bg_log_rotation test_stack_log_rotation test_gate_exit_code_not_tee test_l1_shell_scoring; do
  run $s bash tests/shell/$s.sh
done
run mutate_probe_stubs bash tests/shell/mutate_probe_stubs.sh
run mutate_stack_log_rotation bash tests/shell/mutate_stack_log_rotation.sh
run mutate_l1_shell_scoring bash tests/shell/mutate_l1_shell_scoring.sh
run check_gate_anchors python3 tests/shell/check_gate_anchors.py $M
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=all -- tests/ tools/ doc/audit/2026-08-20_sampling-rate-and-cpu/)" ]] && echo "tests/ tools/ 08-20 clean after the gates" || git -C "$W" status --porcelain --untracked-files=all -- tests/ tools/ doc/audit/2026-08-20_sampling-rate-and-cpu/
echo RERUN-AB-DONE
