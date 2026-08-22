#!/usr/bin/env bash
# settle_bisect.sh -- how short can the settle wait be? (the boot-time question)
#
# [Co-developed with claude code -- Adam]
#
# What burst_timing.txt established, one boot, sampled every 4s:
#   * all 128 "Pinging from" lines are printed within 32s of boot start
#   * Ryu still knows 0 host IPv4s for the next 65 seconds
#   * at t+97s -- the single sample where the settle wait releases -- it goes 0 -> 128
#
# So the wait is not protecting the burst; the burst is long over. Learning is triggered by
# whatever happens at release, and the only time-dependence that matters is whether release
# lands after the fabric has finished building. settle=10 releases at ~t+18, before the burst
# completes, and is known to leave 0/128 permanently. settle=90 releases at ~t+97 and works.
#
# If the rule is simply "release after the burst finishes (~t+32)", then a settle in the 25-40
# range should work and OVS boot comes back from 101s to roughly 45s. That is the whole point of
# this run: the deck's OVS number is currently blocked on it.
#
# Method per cell: boot at the given settle, then read BOTH sides twice -- at t+0 and again
# after 20s. The second read exists because the kernel re-polls every 5s and reading once at
# t+0 is how the n=3 acceptance produced a "256 down" that was never re-sampled and cannot now
# be explained. One read is not a measurement of a system with a poll loop in it.
#
# Assert each boot is real: `ndt up` must not have refused at preflight, and ryu.log must be
# newer than the cell's start. A previous experiment probed a dead system for 90 seconds because
# it trusted a gate line that belonged to the previous run.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-22_settle-gate-acceptance"
OUT="$DIR/settle_bisect.txt"
RAW="$DIR/raw"
LOG="$REPO/.test_run/logs/ryu.log"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
CELLS="${CELLS:-55 40 30 20}"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
: > "$OUT"

say "# how short can NDTWIN_RYU_SETTLE_S be before the twin goes blind?"
say "# date:   $(date -Is)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# known:  10 -> 0/128 (broken).  90 -> 128/128, boot 101s.  burst done by t+32s."
say ""
say "  settle   boot    ryu@t+0   graph@t+0      ryu@t+20   graph@t+20    verdict"

read_pair() {
    local r k
    r=$(curl -sf --max-time 5 "$RYU/v1.0/topology/hosts" 2>/dev/null | python3 -c "
import json,sys
try: hs=json.load(sys.stdin)
except Exception: print('?'); raise SystemExit
print(sum(1 for h in hs if h.get('ipv4')))" 2>/dev/null || echo "?")
    k=$(curl -sf --max-time 5 "$KERNEL/ndt/get_graph_data" 2>/dev/null | python3 -c "
import json,sys
try: g=json.load(sys.stdin)
except Exception: print('?,?'); raise SystemExit
e=g.get('edges',[])
print(f\"{len(e)}e/{sum(1 for x in e if not x.get('is_up',True))}d\")" 2>/dev/null || echo "?,?")
    printf '%s %s' "$r" "$k"
}

for s in $CELLS; do
    ndt down > /dev/null 2>&1
    sleep 3
    t0=$(date +%s)
    if ! env NDTWIN_RYU_SETTLE_S="$s" timeout 600 ndt up ovs > "$RAW/bisect_${s}_up.out" 2>&1; then
        say "  $(printf '%-7s' "$s")  UP FAILED -- see raw/bisect_${s}_up.out"
        continue
    fi
    boot=$(( $(date +%s) - t0 ))

    if grep -qE '^\s+XX' "$RAW/bisect_${s}_up.out" 2>/dev/null; then
        say "  $(printf '%-7s' "$s")  ndt REFUSED -- cell invalid, not a data point"
        continue
    fi
    if [[ ! -f "$LOG" ]] || [[ "$(stat -c %Y "$LOG")" -lt "$t0" ]]; then
        say "  $(printf '%-7s' "$s")  ryu.log stale -- cell invalid, not a data point"
        continue
    fi

    read a0 b0 <<< "$(read_pair)"
    sleep 20
    read a1 b1 <<< "$(read_pair)"

    if [[ "$a1" == "128" && "$b1" == "288e/0d" ]]; then v="OK"
    elif [[ "$a1" == "128" ]]; then v="ryu ok, twin stale"
    else v="BLIND"; fi

    say "  $(printf '%-7s' "$s")  $(printf '%-6s' "${boot}s")  $(printf '%-9s' "$a0")  $(printf '%-13s' "$b0")  $(printf '%-9s' "$a1")  $(printf '%-13s' "$b1")  $v"
    cp -f "$LOG" "$RAW/bisect_${s}_ryu.log" 2>/dev/null || true
done

ndt down > /dev/null 2>&1
say ""
say "## reading it"
say "  The lowest settle with verdict OK is the boot-time floor for a correct twin."
say "  A cell that is OK at t+20 but not t+0 is the kernel's 5s poll catching up, not a failure."
say ""
say "done -> $OUT"
