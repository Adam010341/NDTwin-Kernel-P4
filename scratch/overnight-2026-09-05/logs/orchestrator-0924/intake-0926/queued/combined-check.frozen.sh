#!/usr/bin/env bash
# Orchestrator check on the local merge 4ff4eee8 (f186ce98 GUI + bbb9fd41 queued), before the push: the two
# cross-branch checkers -- anchors (every gate's anchor resolves in the combined tree) and group C's corpus
# scorer (test_l1_shell_scoring). Through the guard, sudo/curl tripwire first. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-queued-intake-0927
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/queued; GUARD=$W/tools/build_guard/guarded_build.sh
M=4ff4eee8059c483f5152df9f32f7406faf95406b
[[ "$(git -C "$W" rev-parse HEAD)" == $M ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab-combined; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP NDT_OWNER
export TMPDIR=/home/adam/.cache/qc; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/combined-$n.4ff4eee8.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E 'Ran [0-9]+|cells ok' $log | tail -1)"; }
run check_gate_anchors python3 tests/shell/check_gate_anchors.py $M
run test_l1_shell_scoring bash tests/shell/test_l1_shell_scoring.sh
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean" || git -C "$W" status --porcelain --untracked-files=no
rm -rf "$TMPDIR"; echo COMBINED-DONE
