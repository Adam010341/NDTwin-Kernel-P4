#!/usr/bin/env bash
# Orchestrator rerun on the test merge 79ec2261 (trunk b2eeb71d + c03130fe): the worker's red-first
# (frozen copy), the suite, and its mutation gate -- through the guard, with the orchestrator's own
# sudo/curl tripwire outermost on PATH. [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-hbw-intake-0926
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/lp1c; GUARD=$W/tools/build_guard/guarded_build.sh
[[ "$(git -C "$W" rev-parse HEAD)" == 79ec22617bf6ced7c605c29e58b8e01110a7554d ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-lp1c; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
WS=$TMPDIR/workershims; bash "$O/frozen/make_shims.sh" "$WS" >/dev/null
run() { local n=$1; shift; local log=$O/rerun-$n.79ec2261.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(Ran |LP1C-RED-FIRST|.*mutations|.*survived)' $log | tail -2 | tr '\n' ' ')"; }
run redfirst bash "$O/frozen/redfirst_lp1c.sh" "$W" "$WS"
run test_live_p1_common bash tests/shell/test_live_p1_common.sh
run mutate_live_p1_common bash tests/shell/mutate_live_p1_common.sh
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
ls "$W"/tests/shell/.redfirst-* 2>/dev/null && echo "LEFTOVER redfirst copies" || echo "no redfirst copies left"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || git -C "$W" status --porcelain --untracked-files=no
echo RERUN-LP1C-DONE
