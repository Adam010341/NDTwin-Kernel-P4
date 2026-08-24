#!/usr/bin/env bash
# boot_rate.sh -- phase 1 of the 2026-08-24 full-stack round: ten OVS boots at plain
# defaults, measuring the convergence rate that 2026-08-24_path-switch-count-404/REPORT.md
# estimated at 3-of-5. Every iteration's raw is numbered, never overwritten (the C-1 lesson
# from scratch/review-2026-08-24/corrections.md: rerun-clobbered raws inverted a citation).
#
# [Co-developed with claude code -- Adam]
#
# Per boot: ndt up ovs (no env overrides) -> twin health read at t+0 and t+20 (the kernel
# re-polls every 5s, so a t+0 read races it; acceptance criterion is "healthy within poll
# cadence") -> on failure keep ryu.log for the failing-vs-succeeding diff the 404 report
# asked for -> ndt down.
set -uo pipefail
export NDT_OWNER=review-0824

DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/boot_rate.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
RYULOG="/home/adam/Desktop/NDTwin-Kernel/.test_run/logs/ryu.log"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

# Append, never truncate. A prior partial run's rows stay.
say ""
say "# ten OVS boots at plain defaults -- convergence rate (phase 1, full-stack round)"
say "# date:   $(date +%Y-%m-%dT%H:%M:%S%z)   commit: $(git -C /home/adam/Desktop/NDTwin-Kernel rev-parse --short HEAD)"
say "# env check: NDTWIN_RYU_SETTLE_S=${NDTWIN_RYU_SETTLE_S:-unset}  NDTWIN_RYU_LLDP_GUARD=${NDTWIN_RYU_LLDP_GUARD:-unset}  NDTWIN_RYU_LLDP_BACKOFF=${NDTWIN_RYU_LLDP_BACKOFF:-unset}"

twin_read() {  # -> "hosts graphEdges graphDown" or "? ? ?"
    local h g
    h=$(curl -sf --max-time 5 "$RYU/v1.0/topology/hosts" | python3 -c "
import json,sys
hs=json.load(sys.stdin)
print(sum(1 for x in hs if x.get('ipv4')))" 2>/dev/null || echo "?")
    g=$(curl -sf --max-time 5 "$KERNEL/ndt/get_graph_data" | python3 -c "
import json,sys
e=json.load(sys.stdin)['edges']
print(len(e), sum(1 for x in e if not x.get('is_up',True)))" 2>/dev/null || echo "? ?")
    echo "$h $g"
}

fails=0; oks=0
for i in $(seq 1 10); do
    ndt down >/dev/null 2>&1
    sleep 3
    t0=$(date +%s)
    if ! timeout 600 ndt up ovs > "$RAW/rate_boot${i}_up.out" 2>&1; then
        say "## boot $i: ndt up EXITED NONZERO (wall $(( $(date +%s)-t0 ))s) -- see rate_boot${i}_up.out"
    fi
    wall=$(( $(date +%s) - t0 ))
    xx=$(grep -cE '^\s+XX' "$RAW/rate_boot${i}_up.out" || true)
    read -r hosts edges down <<< "$(twin_read)"
    verdict=""
    if [ "$xx" -eq 0 ] && [ "$hosts" = "128" ] && [ "$down" = "0" ]; then
        verdict="CONVERGED"
    else
        sleep 20   # give the kernel poll a chance before calling it
        read -r hosts edges down <<< "$(twin_read)"
        if [ "$xx" -eq 0 ] && [ "$hosts" = "128" ] && [ "$down" = "0" ]; then
            verdict="CONVERGED (at t+20; t+0 read raced the poll)"
        else
            verdict="FAILED"
            cp -f "$RYULOG" "$RAW/rate_boot${i}_ryu.log" 2>/dev/null || true
            fails=$((fails+1))
        fi
    fi
    [ "${verdict%% *}" = "CONVERGED" ] && oks=$((oks+1))
    say "## boot $i: $verdict  wall=${wall}s  XX=$xx  ryu_hosts=${hosts}/128  graph=${edges}e/${down}d"
done

# Keep one healthy fabric up for phase 2 if the last boot converged; otherwise tear down.
if [ "${verdict%% *}" = "CONVERGED" ]; then
    say "# leaving the last fabric up for phase 2 (claim review-0824 held)"
else
    ndt down >/dev/null 2>&1
    say "# last boot failed -- fabric torn down"
fi

say "# rate: $fails of $((fails+oks)) failed to converge"
say "done -> $OUT"
