#!/usr/bin/env bash
# Orchestrator rerun on the test merge fc4c1688 (trunk 3f8c2abf + 4f661e31); sudo/curl nolab shims on PATH. [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hbw-intake-0926; O=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/r2b; GUARD=$W/tools/build_guard/guarded_build.sh; P=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
[[ "$(git -C "$W" rev-parse HEAD)" == fc4c168860a7a1da410cd1a8b762daf92a53f8b2 ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
run() { local n=$1 cwd=$2; shift 2; local log=$O/rerun-$n.fc4c1688.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cwd $cwd TMPDIR ${TMPDIR:-} cmd $*"; } > "$log"
  ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(Ran |OK|FAILED|SELF-TEST)' $log | tail -2 | tr '\n' ' ')"; }
export TMPDIR=/tmp/claude-1000/nd-orch; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run test_ndt_serve "$W" python3 tests/python/test_ndt_serve.py
rm -rf "$TMPDIR"; export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-r2b; mkdir -p "$TMPDIR"
run live08_selftest "$W" bash $P/08_heartbeat.sh --self-test
run live07_selftest "$W" bash $P/07_roles_basic.sh --self-test
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || git -C "$W" status --porcelain --untracked-files=no
echo RERUN-R2B-DONE
