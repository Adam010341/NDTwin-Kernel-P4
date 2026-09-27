#!/usr/bin/env bash
# Orchestrator rerun on the test merge ac0c3b64 (trunk d9308f61 + fix/p4proxy-protobuf5-0927 ab026ef0,
# tree b0cd6731), BEFORE the venv migration (so on the protobuf 3.20.3 venv): the suites that read what
# the branch changed -- ndt's lines (test_ndt_serve), _common.sh (test_live_p1_common), the install
# hints (test_ndtwin_lab_heartbeat), the shell-summary corpus (test_l1_shell_scoring), the gate anchors.
# Through the guard, sudo/curl tripwire outermost on PATH. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-hbw-intake-0926
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/pb5-merge; GUARD=$W/tools/build_guard/guarded_build.sh
M=ac0c3b64bb242a1dee4606958c260de4bf1cf853
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset L1_POLL_S SELFTEST_L1_POLL_S SELFTEST_PROBE_SUDO JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-pb5; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.ac0c3b64.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(Ran [0-9]+|OK|FAILED|.*[0-9]+ passed|.*cells ok)' $log | tail -2 | tr '\n' ' ')"; }
run test_ndt_serve python3 tests/python/test_ndt_serve.py
run check_gate_anchors python3 tests/shell/check_gate_anchors.py $M
run test_live_p1_common bash tests/shell/test_live_p1_common.sh
run test_ndtwin_lab_heartbeat bash tests/shell/test_ndtwin_lab_heartbeat.sh
run test_l1_shell_scoring bash tests/shell/test_l1_shell_scoring.sh
run syntax bash -c 'for f in tools/test_workflow/ndt tools/test_workflow/stack.sh tools/test_workflow/l1_unit_tests.sh doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh; do bash -n "$f" && echo "syntax ok $f"; done; python3 -m py_compile p4_proxy/regen_p4runtime_pb2.py && echo "py_compile ok regen"'
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || git -C "$W" status --porcelain --untracked-files=no
echo RERUN-PB5-DONE
