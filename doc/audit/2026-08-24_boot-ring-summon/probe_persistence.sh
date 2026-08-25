#!/usr/bin/env bash
# probe_persistence.sh -- is the loaded-boot host failure PERMANENT or just LATE?
#
# [Co-developed with claude code -- Adam]
#
# The summoning run scores a boot from twin reads at t+0 and t+20 only. Every loaded boot so
# far lands at hosts=0/128 with 256 edges down. That is scored SETTLE-HOSTS, but the scoring
# cannot tell these apart:
#
#   permanent  -- the learning window closed with nothing learned, and no amount of waiting
#                 helps. This is what the settle-VALUE regression does (memory: "窗外是永久的").
#   late       -- learning happens, just after t+20. Then the boot is slow, not broken, and
#                 calling it a failure overstates the defect.
#
# That distinction was established for the settle-value regression, NOT for this load-induced
# one, so inheriting it would be assuming the answer.
#
# There is also a mechanism problem the run cannot resolve: the learning window is
# [switch connect, all-pairs install]. Load makes the walk SLOWER, which should make that
# window LONGER and learning MORE likely -- the opposite of what we observe. So "load shortens
# the window" does not fit, and the real mechanism is unidentified. Do not write one down
# without opening the code that does it.
#
# Method: one loaded boot, then sample the twin every 15s for 10 minutes with the load still
# running, then drop the load and keep sampling. If hosts climb while loaded -> late. If they
# climb only after the load is dropped -> load is suppressing learning, not the window. If they
# never climb -> permanent, matching the settle-value regression.
set -uo pipefail

export NDT_OWNER=maindev-v3
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/probe_persistence.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
WORKERS=$(nproc)
LOADMARK="ndtwin_probe_busyloop_$$"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
load_count() { local n; n=$(pgrep -c -f "$LOADMARK" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; echo "$n"; }
load_start() { local i; for i in $(seq "$WORKERS"); do setsid bash -c "while :; do :; done # $LOADMARK" >/dev/null 2>&1 & done; sleep 2; }
load_stop() { local p t=0; while [ "$(load_count)" -gt 0 ] && [ "$t" -lt 5 ]; do for p in $(pgrep -f "$LOADMARK" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done; sleep 1; t=$((t+1)); done; }
trap 'load_stop >/dev/null 2>&1' EXIT INT TERM

twin() {
    local h g
    h=$(curl -sf --max-time 5 "$RYU/v1.0/topology/hosts" | python3 -c "
import json,sys
print(sum(1 for x in json.load(sys.stdin) if x.get('ipv4')))" 2>/dev/null || echo "?")
    g=$(curl -sf --max-time 5 "$KERNEL/ndt/get_graph_data" | python3 -c "
import json,sys
e=json.load(sys.stdin)['edges']
print(len(e), sum(1 for x in e if not x.get('is_up',True)))" 2>/dev/null || echo "? ?")
    echo "$h $g"
}

say ""
say "# persistence probe: is the loaded-boot host failure permanent or merely late?"
say "# date: $(date +%Y-%m-%dT%H:%M:%S%z)  commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# uptime_h=$(awk '{printf "%.2f", $1/3600}' /proc/uptime)  boot_id=$(cat /proc/sys/kernel/random/boot_id)"

ndt down >/dev/null 2>&1; sleep 3
load_start
alive=$(load_count)
[[ "$alive" -ne "$WORKERS" ]] && { say "ABORT: only $alive/$WORKERS workers"; exit 3; }
say "# load up: $alive/$WORKERS workers"

setsid bash -c "cd '$REPO' && exec ndt up ovs" > "$RAW/probe_up.out" 2>&1 &
pg=$!
while kill -0 "$pg" 2>/dev/null; do
    (( $(date +%s) - ${t0:=$(date +%s)} >= 600 )) && { kill -TERM -"$pg" 2>/dev/null; break; }
    sleep 2
done
wait "$pg" 2>/dev/null
cp -f "$REPO/.test_run/logs/ryu.log" "$RAW/probe_ryu.log" 2>/dev/null || true
say "# boot done; sampling every 15s. load stays UP for the first 10 minutes."

start=$(date +%s)
dropped=0
for i in $(seq 1 80); do          # 80 * 15s = 20 min
    el=$(( $(date +%s) - start ))
    if (( el >= 600 )) && (( dropped == 0 )); then
        load_stop; dropped=1
        say "--- load dropped at t+${el}s (workers now $(load_count)) ---"
    fi
    read -r h e d <<< "$(twin)"
    say "t+${el}s  hosts=${h}/128  edges=${e}  down=${d}  loaded=$(( dropped == 0 ? 1 : 0 ))"
    [[ "$h" == "128" && "$d" == "0" ]] && { say "# converged at t+${el}s -- this was LATE, not permanent"; break; }
    sleep 15
done

load_stop
say "# final: $(twin)"

# Tear the fabric down. The first run of this script did NOT, and the failed fabric -- 139
# host/switch processes, the kernel, and Ryu -- stayed up for ~12 hours until someone noticed.
# A probe that leaves its subject running is a leak, and the next person to measure anything
# inherits a machine with a dead OVS fabric on it.
#
# The accident was informative, which does not make it acceptable: the 11.8h reading it produced
# (hosts=0/128, 256 down, byte-identical to t+0 on an idle machine) is recorded above and is now
# the strongest persistence evidence we have. Reproduce that DELIBERATELY with PROBE_HOLD=1
# rather than by forgetting to clean up.
if [[ -n "${PROBE_HOLD:-}" ]]; then
    say "# PROBE_HOLD set -- leaving the fabric up ON PURPOSE. Run 'ndt down' when finished."
else
    ndt down >/dev/null 2>&1
    say "# fabric torn down"
fi
say "done -> $OUT"
