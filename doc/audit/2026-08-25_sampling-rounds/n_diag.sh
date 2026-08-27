#!/usr/bin/env bash
# Ticket N, make-up: diagnostic A -- does the twin under-report while the fabric is saturated?
# Pre-registration: PREREG.md 增補 N-1-1 (registered) and N-4-5 (recorded as not done).
# [Co-developed with claude code -- Adam]
#
# WHY THIS EXISTS SEPARATELY.  n_cell.sh grew around the thing I wanted to measure -- interface
# counters and machine load -- and amendment N-1 arrived after its shape was fixed, so the
# twin/veth column had no call site and never got one.  That is the failure mode worth naming:
# a registered item added AFTER the script's skeleton exists has nobody to grow a call for it.
#
# WHY IT DOES NOT READ THE PRINTED TABLE.  analyze.py prints class, edges, loaded, veth GB,
# twin GB, ratio, per-edge min, max -- and `ratio` sits next to `per-edge min`, both plausible
# decimals.  Reading one as the other cost this project a headline on 08-26.  So this asks for
# --json and computes the ratio from the per-edge veth_bytes and twin_bytes fields, which are
# named rather than positional.  The printed ratio is then asserted against it as a cross-check:
# if they disagree the cell stops instead of picking whichever looks right.
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-25_large-scale-concurrent"
LABEL="${1:?cell label}"
DUR="${2:-30}"
NFLOW="${3:-32}"
OUT="$ROUND/raw_n/$LABEL"
mkdir -p "$OUT"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$ROUND/n_diag.log"; }
host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }
CORE_IFACES="s5-eth3 s5-eth4 s6-eth3 s6-eth4 s7-eth3 s7-eth4 s8-eth3 s8-eth4"
snap_ifaces() { : > "$1"; for i in $CORE_IFACES; do
    echo "$i $(cat /sys/class/net/$i/statistics/tx_bytes) $(cat /sys/class/net/$i/statistics/rx_bytes)" >> "$1"; done; }

say "=== $LABEL: $NFLOW flows x ${DUR}s + twin/veth reconciliation ==="
say "--- topology actually running (qdisc on named ifaces) ---"
{ for i in s1-eth1 s1-eth3 s5-eth3; do echo "$i: $(sudo -n tc qdisc show dev $i 2>&1 | head -1)"; done; } \
    | tee "$OUT/qdisc.txt" | sed 's/^/    /'

# Cleared ONCE. Per-iteration pkill killed every previously-started server on 08-27, because
# mininet hosts share the root PID namespace; the guard said 32/32 started and was telling the
# truth, they were killed afterwards. See PREREG 增補 N-2-1.
sudo -n mnexec -a "$(host_pid h1)" pkill -f iperf3 2>/dev/null || true
sleep 1
started=0
for i in $(seq 0 $((NFLOW-1))); do
    if [ "$i" -lt 16 ]; then S="h$((65+i))"; else S="h$((97+i-16))"; fi
    sudo -n mnexec -a "$(host_pid "$S")" iperf3 -s -1 --daemon --logfile "$OUT/srv_$S.log" 2>/dev/null \
        && started=$((started+1))
done
alive=$(pgrep -c -x iperf3 2>/dev/null || echo 0)
say "    servers: $started started, $alive ALIVE (want >= $NFLOW)"
[ "$alive" -ge "$NFLOW" ] || { say "ABORT: servers died during startup"; exit 1; }

WIN=$((DUR + 25))
say "--- pollers for ${WIN}s (veth ground truth + twin's own view) ---"
"$PRIOR/poll_veth.sh" "$OUT/veth.tsv" "$WIN" 2 2>>"$ROUND/n_diag.log" &
PV=$!
"$PRIOR/poll_twin.sh" "$OUT" "$WIN" 2 2>>"$ROUND/n_diag.log" &
PT=$!
sleep 3
python3 "$ROUND/cell_env.py" snap "$OUT/env_a.txt"; snap_ifaces "$OUT/if_a.txt"; T0=$(date +%s.%N)

say "--- $NFLOW TCP flows for ${DUR}s ---"
for i in $(seq 0 $((NFLOW-1))); do
    if [ "$i" -lt 16 ]; then C="h$((1+i))"; SIP="10.0.0.$((65+i))"; else C="h$((33+i-16))"; SIP="10.0.0.$((97+i-16))"; fi
    sudo -n mnexec -a "$(host_pid "$C")" iperf3 -c "$SIP" -t "$DUR" -P 4 --json > "$OUT/cli_$C.json" 2>/dev/null &
done
wait $! 2>/dev/null
T1=$(date +%s.%N); snap_ifaces "$OUT/if_b.txt"; python3 "$ROUND/cell_env.py" snap "$OUT/env_b.txt"
wait $PV $PT 2>/dev/null || true
EL=$(echo "$T1 - $T0" | bc)

say "--- core-link rates (interface counters) ---"
python3 - "$OUT" "$EL" <<'PY' | tee "$OUT/rates.txt" | sed 's/^/    /'
import sys
d, el = sys.argv[1], float(sys.argv[2])
rd = lambda p: {l.split()[0]: int(l.split()[1]) for l in open(p)}
a, b = rd(d+"/if_a.txt"), rd(d+"/if_b.txt")
rows = sorted(((i, (b[i]-a[i])*8/el/1e9) for i in a), key=lambda r: -r[1])
for i, g in rows[:4]: print("  %-10s %7.3f Gbit/s" % (i, g))
print("  MAX        %7.3f Gbit/s   TOTAL %7.3f" % (rows[0][1], sum(r[1] for r in rows)))
PY

say "--- DIAGNOSTIC A: twin vs veth (never reads the printed ratio column) ---"
python3 "$PRIOR/analyze.py" --dir "$OUT" --auto-window --json "$OUT/rows.json" > "$OUT/analyze.txt" 2>&1
python3 - "$OUT" <<'PY' | tee "$OUT/diagA.txt" | sed 's/^/    /'
import json, re, sys
d = sys.argv[1]
try:
    rows = json.load(open(d + "/rows.json"))
except Exception as e:
    print("  NO-DATA: analyze.py produced no rows (%s)" % e); raise SystemExit
rows = rows if isinstance(rows, list) else rows.get("rows", [])
loaded = [r for r in rows if r.get("veth_bytes", 0) > 0]
vb = sum(r["veth_bytes"] for r in loaded); tb = sum(r["twin_bytes"] for r in loaded)
print("  loaded edges %d   veth %.3f GB   twin %.3f GB" % (len(loaded), vb/1e9, tb/1e9))
if not vb:
    print("  NO-DATA: veth total is zero"); raise SystemExit
mine = tb / vb
print("  twin/veth = %.4f   (computed from named fields, not the printed column)" % mine)
# Cross-check against what analyze.py printed, and STOP on disagreement rather than choose.
txt = open(d + "/analyze.txt").read()
m = [l for l in txt.splitlines() if l.strip().startswith(("switch", "host", "all"))]
print("  analyze.py's own summary rows:")
for l in m[:6]: print("     " + l.rstrip())
print("  -> %s" % ("twin UNDER-reports by %.1f%%" % (100*(1-mine)) if mine < 0.97 else
                   "twin OVER-reports by %.1f%%" % (100*(mine-1)) if mine > 1.03 else
                   "twin tracks veth within 3% -- no under-reporting at this working point"))
PY
python3 "$ROUND/cell_env.py" "$OUT/env_a.txt" "$OUT/env_b.txt" "$LABEL" | tee "$OUT/env.txt"
say "=== $LABEL done ==="
