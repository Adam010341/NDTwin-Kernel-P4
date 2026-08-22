#!/usr/bin/env bash
# graph_settle.sh -- did run 1 really fail, or did my acceptance script read too early?
#
# [Co-developed with claude code -- Adam]
#
# Acceptance at the 90s default, n=3, read immediately after `ndt up` returned:
#     run1  ryu 128/128 with ipv4   kernel graph 288 edges, 256 DOWN
#     run2  ryu 128/128 with ipv4   kernel graph 288 edges,   0 down
#     run3  ryu 128/128 with ipv4   kernel graph 288 edges,   0 down
#
# Ryu was right in all three. Only the kernel's copy differed, which points at the kernel's
# refresh rather than at the fabric. TopologyAndFlowMonitor's poll loop
# (TopologyAndFlowMonitor.cpp:2032-2034) runs every 5s for its first 90s, then every 30s -- and
# the kernel is only started at ndt's [4/4], AFTER the settle wait releases. So its first poll
# can easily land in the second or two before Ryu learns the addresses, and `updateHosts` skips
# every host whose ipv4 list is empty. Read the graph right then and you get 256 down from a
# fabric that is fine and about to be re-polled.
#
# If that is what happened, run 1 is a defect in MY MEASUREMENT, not in the fix, and the
# acceptance criterion is wrong: it should be "the twin reaches 288/0 within the kernel's poll
# cadence", not "the twin is 288/0 the instant ndt up returns".
#
# This boots once and then samples both sides every 5s for 120s. Two outcomes, opposite meanings:
#   * down-count starts high and drops to 0 within a poll or two  -> read-too-early, run 1 healed
#   * down-count stays at 256 for the whole two minutes           -> a real second failure mode,
#                                                                    and the kernel never heals
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-22_settle-gate-acceptance"
OUT="$DIR/graph_settle.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
: > "$OUT"

if [[ -n "${NDTWIN_RYU_SETTLE_S:-}" ]]; then
    say "ABORT: NDTWIN_RYU_SETTLE_S='${NDTWIN_RYU_SETTLE_S}' -- must run at the default."
    exit 2
fi

say "# does the kernel graph heal after boot? (the run-1 question)"
say "# date:   $(date -Is)   commit: $(git -C "$REPO" rev-parse --short HEAD) + uncommitted"
say "# kernel poll cadence, from source: 5s for the first 90s, then 30s"
say ""

ndt down > /dev/null 2>&1
sleep 3

t0=$(date +%s)
if ! timeout 900 ndt up ovs > "$DIR/raw/graph_settle_up.out" 2>&1; then
    say "UP FAILED -- see raw/graph_settle_up.out"
    tail -6 "$DIR/raw/graph_settle_up.out" | sed 's/^/  /' | tee -a "$OUT"
    exit 1
fi
boot=$(( $(date +%s) - t0 ))
say "boot returned after ${boot}s. Sampling both sides every 5s for 120s."
say ""
say "   t_after_boot   ryu(with_ipv4/known)   kernel(edges,down)"

for i in $(seq 0 24); do
    t=$(( i * 5 ))
    ryu_n=$(curl -sf --max-time 4 "$RYU/v1.0/topology/hosts" 2>/dev/null | python3 -c "
import json,sys
try: hs=json.load(sys.stdin)
except Exception: print('?/?'); raise SystemExit
print(f\"{sum(1 for h in hs if h.get('ipv4'))}/{len(hs)}\")" 2>/dev/null || echo "?/?")
    k=$(curl -sf --max-time 4 "$KERNEL/ndt/get_graph_data" 2>/dev/null | python3 -c "
import json,sys
try: g=json.load(sys.stdin)
except Exception: print('?,?'); raise SystemExit
e=g.get('edges',[])
print(f\"{len(e)},{sum(1 for x in e if not x.get('is_up',True))}\")" 2>/dev/null || echo "?,?")
    printf '   %6ss         %-18s     %s\n' "+$t" "$ryu_n" "$k" | tee -a "$OUT"
    sleep 5
done

say ""
say "## verdict"
say "  Read the down column. Dropping to 0 within a poll or two means run 1 was read too early"
say "  and the acceptance criterion needs the settle window, not that the fix failed."

ndt down > /dev/null 2>&1
say ""
say "done -> $OUT"
