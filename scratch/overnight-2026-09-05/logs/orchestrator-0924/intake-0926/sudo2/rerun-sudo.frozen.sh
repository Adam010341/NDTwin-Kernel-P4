#!/usr/bin/env bash
# Orchestrator rerun of sudo-probe d57f90f1 on the test merge 5d81369c (trunk fed37cff + d57f90f1). Through the guard,
# one guard call per gate (the lock is taken per cell), sudo/curl tripwire first on PATH. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-queued-intake-0927; O=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/sudo2; GUARD=$W/tools/build_guard/guarded_build.sh; M=5d81369c0b7a02c23a265dbf1c2c9e8a6573bc25
P=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1; SNAP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp/hbsnap
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_OWNER
export TMPDIR=/home/adam/.cache/sudoi; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.${M:0:8}.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E 'Ran [0-9]+|cells ok|survivor|mutation\(s\)|PROXY-UNIT|^OK|FAILED|checks, [0-9]+ failed|passed|PASS|FAIL' $log | tail -2 | tr '\n' ' ' | cut -c1-220)"; }
run test_ndt_sudo_surface bash tests/shell/test_ndt_sudo_surface.sh
run test_ndt_honesty bash tests/shell/test_ndt_honesty.sh
run test_l1_shell_scoring bash tests/shell/test_l1_shell_scoring.sh
run check_test_tmpdirs python3 tests/shell/check_test_tmpdirs.py
run mutate_ndt_sudo_surface bash tests/shell/mutate_ndt_sudo_surface.sh
run mutate_probe_stubs bash tests/shell/mutate_probe_stubs.sh
run check_gate_anchors python3 tests/shell/check_gate_anchors.py $M
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean" || git -C "$W" status --porcelain --untracked-files=no
rm -rf "$TMPDIR"; echo RERUN-DONE
