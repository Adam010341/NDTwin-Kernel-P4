#!/usr/bin/env bash
# gate_coupling.sh -- does the host-discovery gate block the event it is waiting for?
#
# [Co-developed with claude code -- Adam]
#
# Two acceptance runs, same fabric, only the deadline changed:
#
#   deadline  90s -> gate read 0/128 for  90s, boot 101s, hosts learned right after it released
#   deadline 180s -> gate read 0/128 for 180s, boot 191s, hosts learned right after it released
#
# If the ping burst happened at a fixed time (~t+96, as the 90s run alone suggested), the 180s
# gate would have SEEN it at t+96 and exited early. It did not. The learning time tracks the
# deadline, which means the gate is not waiting for the burst -- it is holding it up. A gate
# that blocks the event it waits for can only ever run its deadline out, and the healthy
# outcomes so far were the walk landing just after the burst by a second or two.
#
# What this run tests, inside a deliberately long window (deadline 300s):
#   1. Does s1 have a table-miss entry pointing at the controller? If not, nothing can punt and
#      no packet can teach Ryu until the walk installs rules -- the gate would be deadlocked by
#      construction, waiting for a packet-in that its own blocking prevents.
#   2. Do the Mininet hosts exist yet? (If they do not, the burst simply has not happened and
#      the gate is innocent -- the fabric build is what is slow.)
#   3. INTERVENTION: ping one host pair by hand, mid-window, and ask Ryu again. A ping that
#      teaches Ryu proves the learning path is open and the gate is merely waiting for traffic
#      that has not come. A ping that teaches it nothing proves the path is shut.
#
# Assert the injection: the ping must be shown to have run (host pid found, ping output kept),
# and the probe must be shown to be INSIDE the window (a progress line present, no verdict line
# yet). A probe that lands after the gate released would answer a different question and look
# exactly like an answer to this one.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0822}"
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$REPO/doc/audit/2026-08-22_settle-gate-acceptance"
OUT="$DIR/coupling.txt"
RYU=http://localhost:8080
LOG="$REPO/.test_run/logs/ryu.log"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
: > "$OUT"

hosts_now() {
    curl -sf --max-time 5 "$RYU/v1.0/topology/hosts" 2>/dev/null | python3 -c "
import json,sys
try: hs=json.load(sys.stdin)
except Exception: print('unreadable'); raise SystemExit
w=[h for h in hs if h.get('ipv4')]
print(f'{len(w)}/{len(hs)} with ipv4', end='')
if w: print('  ->', ','.join(sorted(ip for h in w for ip in h['ipv4'])[:5]), end='')
print()"
}

say "# gate coupling: is the gate blocking the packet-ins it waits for?"
say "# date:   $(date -Is)   commit: $(git -C "$REPO" rev-parse --short HEAD) + uncommitted"
say "# deadline for this run: NDTWIN_RYU_SETTLE_S=300 (long, so the probe lands mid-window)"
say ""

ndt down > /dev/null 2>&1
sleep 3

( NDTWIN_RYU_SETTLE_S=300 timeout 700 ndt up ovs > "$DIR/raw/coupling_up.out" 2>&1 ) &
BOOTPID=$!

# Wait for the gate to actually be running -- not a fixed sleep, the same mistake this whole
# investigation is about.
say "## waiting for the gate to open (first progress line in ryu.log)"
for _ in $(seq 1 120); do
    grep -q "host discovery: " "$LOG" 2>/dev/null && break
    sleep 2
done
if ! grep -q "host discovery: " "$LOG" 2>/dev/null; then
    say "  gate never logged a progress line in 240s -- aborting, nothing to probe"
    kill $BOOTPID 2>/dev/null; ndt down >/dev/null 2>&1; exit 1
fi
say "  gate is open: $(grep 'host discovery: ' "$LOG" | tail -1)"
say ""

say "## 1. s1's table-miss entry (can anything punt at all?)"
curl -sf --max-time 5 "$RYU/stats/flow/1" 2>/dev/null | python3 -c "
import json,sys
try: fl=json.load(sys.stdin).get('1',[])
except Exception: print('  (flow stats unreadable)'); raise SystemExit
miss=[f for f in fl if f.get('priority')==0]
ctrl=[f for f in miss if any('CONTROLLER' in str(a) for a in f.get('actions',[]))]
print(f'  s1: {len(fl)} flows total, {len(miss)} at priority 0, {len(ctrl)} of those to CONTROLLER')
for f in ctrl[:1]: print('    miss entry actions:', f.get('actions'))
if not ctrl:
    print('    NO table-miss to controller -- nothing can punt, so no packet can teach Ryu')
    print('    until the walk installs rules. The gate would be waiting on an event it blocks.')" | tee -a "$OUT"
say ""

say "## 2. do the Mininet hosts exist yet?"
H1PID=$(pgrep -f 'mininet:h1$' | head -1)
say "  h1 pid: ${H1PID:-NOT FOUND}"
say "  mininet host processes: $(pgrep -cf 'mininet:h' 2>/dev/null || echo 0)"
say "  ryu currently knows: $(hosts_now)"
say ""

if [[ -z "$H1PID" ]]; then
    say "## 3. SKIPPED -- no h1 to ping from. The fabric is not built yet, which is itself the"
    say "   answer to (2): the gate is waiting before the hosts exist."
else
    say "## 3. INTERVENTION: ping h1 -> 10.0.0.33 by hand, mid-window"
    sudo -n mnexec -a "$H1PID" ping -c 3 -i 0.3 -W 1 10.0.0.33 > "$DIR/raw/coupling_ping.out" 2>&1
    say "  ping ran: $(grep -E 'transmitted' "$DIR/raw/coupling_ping.out" || echo 'NO PING OUTPUT -- injection failed')"
    sleep 8
    say "  ryu after the ping: $(hosts_now)"
fi
say ""

say "## still inside the window? (the probe is only valid if the gate had not released)"
if grep -q "host discovery incomplete\|host discovery complete" "$LOG" 2>/dev/null; then
    say "  !! the gate RELEASED before the probe finished -- this run answers a different"
    say "     question than the one asked. Discard and re-run with a longer deadline."
else
    say "  yes: no verdict line yet, gate still waiting ($(grep -c 'host discovery: ' "$LOG") progress lines)"
fi

say ""
say "## letting the boot finish, then the final state for comparison"
wait $BOOTPID 2>/dev/null
say "  gate verdict: $(grep -E 'host discovery (complete|incomplete)' "$LOG" | tail -1 | sed 's/.*] //')"
say "  ryu final:    $(hosts_now)"

ndt down > /dev/null 2>&1
say ""
say "done -> $OUT"
