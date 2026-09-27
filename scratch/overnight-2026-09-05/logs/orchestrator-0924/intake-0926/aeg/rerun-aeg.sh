#!/usr/bin/env bash
# Orchestrator rerun of aeg on the test merge 9a831336 (trunk 3d740be0 + the delivered head). Through the guard,
# one guard call per gate (the lock is taken per cell), sudo/curl tripwire first on PATH. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-intake-0927; O=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/aeg; GUARD=$W/tools/build_guard/guarded_build.sh; M=9a83133685bb6d4373d772e472a817ca1d801b00
P=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1; SNAP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp/hbsnap
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_OWNER
export TMPDIR=/home/adam/.cache/aegi; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.${M:0:8}.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E 'Ran [0-9]+|cells ok|survivor|mutation\(s\)|PROXY-UNIT|^OK|FAILED|checks, [0-9]+ failed|passed|PASS|FAIL' $log | tail -2 | tr '\n' ' ' | cut -c1-220)"; }
run test_live_p1_common bash tests/shell/test_live_p1_common.sh
run test_live_p1_thirteen bash tests/shell/test_live_p1_thirteen.sh
run live07_selftest env SELFTEST_HB_RUN="$SNAP/run" SELFTEST_HB_PKGS="$SNAP/pkgs" bash $P/07_roles_basic.sh --self-test
run live08_selftest bash $P/08_heartbeat.sh --self-test
run proxy_unit bash -c 'cd p4_proxy; bad=0; n=0; for f in tests/test_*.py; do out=$(timeout 900 venv/bin/python "$f" 2>&1); rc=$?; k=$(sed -n -E "s/^Ran ([0-9]+) tests?.*/\1/p" <<<"$out" | tail -1); n=$((n+${k:-0})); l=$(grep -E "^(OK|FAILED)" <<<"$out" | tail -1); if [[ $rc != 0 || $l != OK* || ${k:-0} == 0 ]]; then bad=1; echo "FAILED $f rc=$rc ran=${k:-0} $l"; fi; done; echo "PROXY-UNIT ran $n bad=$bad"; exit $bad'
run mutate_live_p1_common bash tests/shell/mutate_live_p1_common.sh
run mutate_live_p1_thirteen bash tests/shell/mutate_live_p1_thirteen.sh
run mutate_roles_binding bash tests/shell/mutate_roles_binding.sh
run mutate_p4_heartbeat_w bash tests/shell/mutate_p4_heartbeat_w.sh
run check_gate_anchors python3 tests/shell/check_gate_anchors.py $M
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean" || git -C "$W" status --porcelain --untracked-files=no
rm -rf "$TMPDIR"; echo RERUN-DONE
