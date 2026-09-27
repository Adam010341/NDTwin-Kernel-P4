#!/usr/bin/env bash
# Orchestrator rerun on the test merge ebc6808c (trunk 3db3b9a8 + fix/hb-followups-r3-0927 c22d1300):
# 07/08 self-tests, the gate-anchor checker, and both mutation gates the round changed -- through the
# guard, sudo/curl tripwire outermost on PATH; the main checkout's lab-state knobs hashed before and
# after (R-N1: no mutant may write them). [Co-developed with claude code -- Adam]
set -u
R=/home/adam/Desktop/NDTwin-Kernel; W=$R/scratch/overnight-2026-09-05/wt-hbw-intake-0926
O=$R/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/r3; GUARD=$W/tools/build_guard/guarded_build.sh
P=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
[[ "$(git -C "$W" rev-parse HEAD)" == ebc6808ca9f0b0cee57e51ffdf41e1cc57d7f7a0 ]] || { echo "REFUSE: HEAD moved"; exit 2; }
SH=$O/nolab; mkdir -p "$SH"; : > "$SH/tripwire.log"
printf '#!/bin/sh\necho "sudo $*" >> %s/tripwire.log\nexit 1\n' "$SH" > "$SH/sudo"
printf '#!/bin/sh\ncase "$*" in *:8000*|*:8081*|*:8080*) echo "curl $*" >> %s/tripwire.log; exit 7;; esac\nexec /usr/bin/curl "$@"\n' "$SH" > "$SH/curl"
chmod +x "$SH/sudo" "$SH/curl"; export PATH="$SH:$PATH"; export PYTHONDONTWRITEBYTECODE=1
unset L1_POLL_S SELFTEST_L1_POLL_S SELFTEST_PROBE_SUDO
knobs() { for k in host_count_override app_package_override telemetry_override; do
    f=$R/p4_proxy/mininet/$k; [[ -e $f ]] && echo "$k $(sha256sum < $f | cut -c1-16) $(stat -c %Y $f)" || echo "$k absent"; done; }
knobs > "$O/knobs-before.txt"
export TMPDIR=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp-r3; rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
run() { local n=$1; shift; local log=$O/rerun-$n.ebc6808c.log
  { git -C "$W" rev-parse HEAD; echo "# $(date -u +%FT%TZ) cmd $*"; } > "$log"
  ( cd "$W" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; echo "# rc=$?" >> "$log"
  echo "$n $(tail -1 $log) | $(grep -E '^(SELF-TEST|mutation gate|.*/[0-9]+ *$|08.s mutant tree)' $log | tail -2 | tr '\n' ' ')"; }
run live07_selftest bash $P/07_roles_basic.sh --self-test
run live08_selftest bash $P/08_heartbeat.sh --self-test
run check_gate_anchors python3 tests/shell/check_gate_anchors.py ebc6808ca9f0b0cee57e51ffdf41e1cc57d7f7a0
run mutate_roles_binding bash tests/shell/mutate_roles_binding.sh
run mutate_p4_heartbeat_w bash tests/shell/mutate_p4_heartbeat_w.sh
knobs > "$O/knobs-after.txt"
cmp -s "$O/knobs-before.txt" "$O/knobs-after.txt" && echo "main checkout's lab-state knobs unchanged" || { echo "🔴 KNOBS CHANGED"; diff "$O/knobs-before.txt" "$O/knobs-after.txt"; }
echo "tripwire lines: $(wc -l < "$SH/tripwire.log")"
[[ -z "$(git -C "$W" status --porcelain --untracked-files=no)" ]] && echo "tracked tree clean after the gates" || git -C "$W" status --porcelain --untracked-files=no
ls "$W"/tests/shell/.redfirst-* "$W"/tests/shell/.mutant-* 2>/dev/null && echo "LEFTOVER copies" || echo "no leftover copies"
echo RERUN-R3-DONE
