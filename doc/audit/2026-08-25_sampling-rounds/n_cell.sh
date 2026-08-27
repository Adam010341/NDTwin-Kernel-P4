#!/usr/bin/env bash
# Ticket N, one cell: how fast does a single CORE link actually carry?
# Pre-registration: PREREG.md "預註冊：工單 N" + "增補 N-1". [Co-developed with claude code -- Adam]
#
# WHY TCP HERE AND UDP IN THE 08-25 ROUND.  That round asked about telemetry accuracy, so a
# fixed offered rate was needed to keep the denominator of every ratio known, and TCP's
# rate-adaptation would have made the offered load an unknown.  This round asks the opposite
# question -- what will the fabric carry -- and rate-adaptation is the measurement, not a
# contaminant.  A fixed UDP rate here would only tell me whether I guessed the ceiling.
#
# WHY THE PAIRING.  Hosts 1-32 hang off s1, 33-64 off s2, 65-96 off s3, 97-128 off s4.  s1 and
# s2 both reach s5 and s6 directly, so h1->h33 never touches the core.  Only edge-pairs on
# opposite sides cross it: s1->s3 goes s1 -> {s5|s6} -> {s9|s10} -> {s7|s8} -> s3.  Every flow
# here is such a pair, so all offered load is forced through the eight core links.
#
# WHY INTERFACE COUNTERS AND NOT iperf3.  iperf3 reports what its own socket saw.  The question
# is what a link carried, and ECMP splits a flow set across s5-eth3 and s5-eth4 by hash, so the
# per-link rate is not the total divided by anything I get to choose.  /sys counters are read
# per interface, underneath OVS, and the split falls out of the measurement rather than being
# assumed.
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
LABEL="${1:?cell label}"
DUR="${2:-30}"
NFLOW="${3:-16}"
OUT="$ROUND/raw_n/$LABEL"
mkdir -p "$OUT"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$ROUND/n_cell.log"; }

host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }

# The eight core-side interfaces: s5..s8 toward s9 (eth3) and s10 (eth4).
CORE_IFACES="s5-eth3 s5-eth4 s6-eth3 s6-eth4 s7-eth3 s7-eth4 s8-eth3 s8-eth4"

snap_ifaces() {   # $1 = destination file
    : > "$1"
    for i in $CORE_IFACES; do
        [ -d "/sys/class/net/$i" ] || continue
        echo "$i $(cat /sys/class/net/$i/statistics/tx_bytes) $(cat /sys/class/net/$i/statistics/rx_bytes)" >> "$1"
    done
}

say "=== cell $LABEL: $NFLOW flows x ${DUR}s, all crossing the core ==="

# The registered injection self-proof. NAMED interfaces only: a bare `tc qdisc show` is refused
# by sudoers with "a password is required", and that refusal reads exactly like "no shaping".
say "--- qdisc state (access s1-eth1 / core s5-eth3) ---"
{
  echo "s1-eth1: $(sudo -n tc qdisc show dev s1-eth1 2>&1 | head -1)"
  echo "s1-eth2: $(sudo -n tc qdisc show dev s1-eth2 2>&1 | head -1)"
  echo "s5-eth3: $(sudo -n tc qdisc show dev s5-eth3 2>&1 | head -1)"
  echo "h1-eth0-peer(s1-eth3): $(sudo -n tc qdisc show dev s1-eth3 2>&1 | head -1)"
} | tee "$OUT/qdisc.txt" | sed 's/^/    /'
say "--- 'Bandwidth limit ... ignoring' lines in the topo session ---"
sudo -n /usr/local/sbin/ndtwin-lab topo-out 3000 2>&1 | grep -c "Bandwidth limit" > "$OUT/bwlimit_count.txt"
say "    count = $(cat "$OUT/bwlimit_count.txt")"

# Servers first: a client that connects before its server is up fails silently into the log.
# Cleared ONCE, before any server exists. Not per-iteration: see the note below the loop.
say "--- clearing stale iperf3 (once, root PID namespace is shared) ---"
sudo -n mnexec -a "$(host_pid h1)" pkill -f iperf3 2>/dev/null || true
sleep 1
say "--- starting $NFLOW servers ---"
started=0
for i in $(seq 0 $((NFLOW-1))); do
    if [ "$i" -lt 16 ]; then S="h$((65+i))"; else S="h$((97+i-16))"; fi
    SP=$(host_pid "$S"); [ -n "$SP" ] || { say "    FATAL: no pid for $S"; exit 1; }
    sudo -n mnexec -a "$SP" iperf3 -s -1 --daemon --logfile "$OUT/srv_$S.log" 2>/dev/null && started=$((started+1))
done
# ASSERT THE SERVERS ARE STILL ALIVE, not merely that they started. The first version ran
# `pkill -f iperf3` inside this loop to clear stale servers, and mininet hosts share the root PID
# namespace -- so each iteration killed every server the previous iterations had started. Exactly
# one survived, the last, and "32/32 servers started" still printed because each one did start.
# 31 of 32 flows then failed to connect and the cell reported 0.902 Gbit/s off the interface
# counters, which is a correct reading of a single flow and would have been published as a
# 32-flow ceiling. Verified by prediction: the surviving flow was cli_h48 -> h112, the last pair.
alive=$(pgrep -c -x iperf3 2>/dev/null || echo 0)
say "    $alive iperf3 servers alive after the loop (want >= $NFLOW)"
[ "$alive" -ge "$NFLOW" ] || { say "ABORT: servers died during startup -- see the pkill note above"; exit 1; }
say "    $started/$NFLOW servers started"
[ "$started" -eq "$NFLOW" ] || { say "ABORT: server count short"; exit 1; }
sleep 2

python3 "$ROUND/cell_env.py" snap "$OUT/env_a.txt"
snap_ifaces "$OUT/if_a.txt"
T0=$(date +%s.%N)

say "--- $NFLOW TCP flows for ${DUR}s ---"
for i in $(seq 0 $((NFLOW-1))); do
    if [ "$i" -lt 16 ]; then C="h$((1+i))"; SIP="10.0.0.$((65+i))"; else C="h$((33+i-16))"; SIP="10.0.0.$((97+i-16))"; fi
    CP=$(host_pid "$C")
    sudo -n mnexec -a "$CP" iperf3 -c "$SIP" -t "$DUR" -P 4 --json > "$OUT/cli_$C.json" 2>"$OUT/cli_$C.err" &
done
wait

T1=$(date +%s.%N)
snap_ifaces "$OUT/if_b.txt"
python3 "$ROUND/cell_env.py" snap "$OUT/env_b.txt"
ELAPSED=$(echo "$T1 - $T0" | bc)
echo "$ELAPSED" > "$OUT/elapsed.txt"

say "--- per-core-link rate over ${ELAPSED}s (interface counters, not iperf3) ---"
python3 - "$OUT" "$ELAPSED" <<'PY' | tee "$OUT/rates.txt" | sed 's/^/    /'
import sys
d, el = sys.argv[1], float(sys.argv[2])
def rd(p):
    o = {}
    for l in open(p):
        f = l.split()
        o[f[0]] = (int(f[1]), int(f[2]))
    return o
a, b = rd(d + "/if_a.txt"), rd(d + "/if_b.txt")
rows = []
for i in sorted(a):
    dtx = b[i][0] - a[i][0]
    rows.append((i, dtx * 8 / el / 1e9))
rows.sort(key=lambda r: -r[1])
tot = sum(r[1] for r in rows)
for i, g in rows:
    print("  %-10s %7.3f Gbit/s" % (i, g))
print("  %-10s %7.3f Gbit/s   <- SINGLE CORE LINK MAX (the ticket's question)" % ("MAX", rows[0][1]))
print("  %-10s %7.3f Gbit/s   (all eight core links together)" % ("TOTAL", tot))
if rows[0][1] > 0:
    print("  ECMP split across the top four: %s" % ", ".join("%.2f" % r[1] for r in rows[:4]))
PY

python3 "$ROUND/cell_env.py" "$OUT/env_a.txt" "$OUT/env_b.txt" "$LABEL" | tee "$OUT/env.txt"
say "=== cell $LABEL done ==="
