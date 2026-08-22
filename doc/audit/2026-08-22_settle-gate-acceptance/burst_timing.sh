#!/usr/bin/env bash
# burst_timing.sh -- does the ping burst happen before or after the settle wait releases?
#
# [Co-developed with claude code -- Adam]
#
# This is the mechanism question left open by the acceptance runs. Hosts acquire their IPv4 just
# after the wait releases, at 90s and again at 180s, so the learning tracks the deadline rather
# than happening at a fixed point in bring-up. Two shapes explain that and they need opposite
# fixes:
#
#   A  The burst fires early and its packets are lost (no table-miss entry yet, or the ICMP is
#      dropped) -- then waiting longer is pointless and the fix is in the punt path.
#   B  The burst itself is being held up until the wait releases -- then the wait is not
#      protecting the burst, it is delaying it, and boot time can come back.
#
# The discriminator is the burst's own log. testbed_topo.py prints one "Pinging from hN to ..."
# per host, 128 of them, and `ndtwin-lab topo-out` serves that session's output. Counting those
# lines every few seconds dates the burst directly, with no inference:
#
#   count goes 0 -> 128 WHILE the gate is still logging progress   -> shape A
#   count stays 0 until the gate's verdict line, then jumps        -> shape B
#
# NOTE ON THE FILE THAT ACTUALLY RUNS: `ndtwin-lab ovs-topo-start` launches
# /home/adam/Network-Traffic-Generator/testbed_topo.py, NOT the copy in this repo. They differ
# (the NTG one ends in command_line(net, "NTG.yaml") instead of CLI(net)). The ARP and ping
# section is the same in both, but reason about the NTG copy.
#
# ASSERT THE BOOT HAPPENED. The previous attempt at this experiment (gate_coupling.sh) keyed off
# a "gate is open" line in ryu.log while `ndt up` had actually refused at preflight and never
# booted -- the line was the PREVIOUS run's, because ryu.log only rotates when a new Ryu starts.
# It probed a dead system and produced output that looked like a result. Here the boot's own
# output is checked for ndt's refusal marker, and ryu.log must be newer than the boot start.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-22_settle-gate-acceptance"
OUT="$DIR/burst_timing.txt"
UPOUT="$DIR/raw/burst_timing_up.out"
LOG="$REPO/.test_run/logs/ryu.log"
RYU=http://localhost:8080
LAB=/usr/local/sbin/ndtwin-lab

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
: > "$OUT"

if [[ -n "${NDTWIN_RYU_SETTLE_S:-}" ]]; then
    say "ABORT: NDTWIN_RYU_SETTLE_S='${NDTWIN_RYU_SETTLE_S}' -- must run at the default."
    exit 2
fi

say "# burst timing vs the settle wait"
say "# date:   $(date -Is)   commit: $(git -C "$REPO" rev-parse --short HEAD) + uncommitted"
say ""

ndt down > /dev/null 2>&1
sleep 3
BOOT_T0=$(date +%s)

( timeout 900 ndt up ovs > "$UPOUT" 2>&1 ) &
BOOTPID=$!

# --- the assertion the last attempt was missing ------------------------------------------
sleep 20
if grep -qE '^\s+XX' "$UPOUT" 2>/dev/null; then
    say "ABORT: ndt refused to boot -- this would have probed a dead system."
    grep -E '^\s+XX' "$UPOUT" | sed 's/^/  /' | tee -a "$OUT"
    kill $BOOTPID 2>/dev/null; exit 1
fi
if [[ ! -f "$LOG" ]] || [[ "$(stat -c %Y "$LOG")" -lt "$BOOT_T0" ]]; then
    say "ABORT: ryu.log is older than this boot -- no fresh Ryu, so any gate line would be stale."
    kill $BOOTPID 2>/dev/null; ndt down >/dev/null 2>&1; exit 1
fi
say "boot is real: ndt did not refuse, ryu.log is fresh (mtime $(( $(stat -c %Y "$LOG") - BOOT_T0 ))s after start)"
say ""
say "   t_boot   pings_printed   ryu_with_ipv4   gate_progress_lines   gate_released"

for i in $(seq 1 55); do
    t=$(( $(date +%s) - BOOT_T0 ))
    pings=$(sudo -n "$LAB" topo-out 5000 2>/dev/null | grep -c "Pinging from" || echo "?")
    ryu_n=$(curl -sf --max-time 3 "$RYU/v1.0/topology/hosts" 2>/dev/null | python3 -c "
import json,sys
try: hs=json.load(sys.stdin)
except Exception: print('?'); raise SystemExit
print(sum(1 for h in hs if h.get('ipv4')))" 2>/dev/null || echo "?")
    prog=$(grep -c "host discovery: " "$LOG" 2>/dev/null || echo 0)
    rel=$(grep -cE "host discovery (complete|incomplete)" "$LOG" 2>/dev/null || echo 0)
    [[ "$rel" -gt 0 ]] && rel=YES || rel=no
    printf '   %5ss   %13s   %13s   %19s   %s\n' "$t" "$pings" "$ryu_n" "$prog" "$rel" | tee -a "$OUT"
    kill -0 $BOOTPID 2>/dev/null || { say "   (boot process exited)"; }
    sleep 4
done

wait $BOOTPID 2>/dev/null
say ""
say "## verdict"
say "  If pings_printed reached 128 while gate_released was still 'no', the burst fires during"
say "  the wait and its packets are being lost -- waiting longer cannot help (shape A)."
say "  If pings_printed stayed 0 until gate_released flipped to YES, the wait is delaying the"
say "  burst rather than protecting it, and the boot time is recoverable (shape B)."

ndt down > /dev/null 2>&1
say ""
say "done -> $OUT"
