#!/usr/bin/env bash
# PREREG-B v1.0 §3 — sender-gate calibration. Produces exactly one constant, G.
#
# G = the generator ceiling of THIS VM on a sender->sink path that does NOT
# traverse any build under test. The arms run iperf3 inside network
# namespaces over veth, so the calibration path uses a veth pair and a
# namespace too: measuring over `lo` would be faster than the arms' path and
# would overstate G, and overstating G is the direction that lets a
# sender-limited reading pass as a switch reading.
#
# Decision rule (frozen in PREREG-B before this ran): for any rung X,
# G < 5*X  =>  readings at X and above are marked sender-limited and do not
# enter the clean judgement. This script does not evaluate that rule; it only
# supplies G.
# [Co-developed with claude code -- Adam]
set -uo pipefail

OUT="${1:-$HOME/b-round/gate}"
NS=bgate
PAYLOAD=1400          # bytes; frame = payload + 42 = 1442, the arms' working point
DUR=10
REPS=3

mkdir -p "$OUT"
{
  echo "=== sender-gate calibration ==="
  echo "date_utc: $(date -u +%FT%TZ)"
  echo "host_uname: $(uname -r)"
  echo "iperf3: $(iperf3 --version 2>&1 | head -1)"
  echo "payload_bytes: $PAYLOAD  duration_s: $DUR  reps: $REPS"
} > "$OUT/gate_meta.txt"

# --- build the calibration path: veth pair, one end in a namespace ---
sudo ip netns del $NS 2>/dev/null
sudo ip link del vgate0 2>/dev/null
sudo ip netns add $NS
sudo ip link add vgate0 type veth peer name vgate1
sudo ip link set vgate1 netns $NS
sudo ip addr add 10.99.0.1/24 dev vgate0
sudo ip link set vgate0 up
sudo ip netns exec $NS ip addr add 10.99.0.2/24 dev vgate1
sudo ip netns exec $NS ip link set vgate1 up
sudo ip netns exec $NS ip link set lo up

# assert the path exists before measuring anything through it
if ! ping -c2 -W2 10.99.0.2 >"$OUT/gate_path_ping.txt" 2>&1; then
  echo "ABORT: calibration path not reachable" | tee -a "$OUT/gate_meta.txt"
  exit 2
fi
echo "path_assert: ok" >> "$OUT/gate_meta.txt"

sudo ip netns exec $NS iperf3 -s -1 -D --logfile "$OUT/gate_server_warm.log" 2>/dev/null
sleep 1

for r in $(seq 1 $REPS); do
  sudo ip netns exec $NS iperf3 -s -D -1 --logfile "$OUT/gate_server_$r.log" 2>/dev/null
  sleep 1
  iperf3 -c 10.99.0.2 -u -b 0 -l $PAYLOAD -t $DUR -J > "$OUT/gate_rep$r.json" 2>&1
  sleep 1
done

# --- extract G: the receiver-side bits/s, the conservative end ---
python3 - "$OUT" <<'PY' | tee -a "$OUT/gate_meta.txt"
import json,sys,glob,os
d=sys.argv[1]; vals=[]
for f in sorted(glob.glob(os.path.join(d,'gate_rep*.json'))):
    try:
        j=json.load(open(f))
        e=j['end']
        rx=e.get('sum_received') or e.get('sum')
        tx=e.get('sum_sent') or e.get('sum')
        vals.append((os.path.basename(f), tx['bits_per_second']/1e6, rx['bits_per_second']/1e6,
                     rx.get('lost_percent')))
    except Exception as ex:
        vals.append((os.path.basename(f), None, None, 'PARSE-FAIL: %s' % ex))
print("rep  sender_Mbit  receiver_Mbit  loss%")
for v in vals: print(v)
good=[v[2] for v in vals if isinstance(v[2],(int,float))]
if len(good)==len(vals) and good:
    good.sort()
    print("G_median_Mbit_receiver: %.1f" % good[len(good)//2])
    print("G_min_Mbit_receiver:    %.1f   <- use this one (conservative)" % good[0])
else:
    print("G: NOT ESTABLISHED -- parse failures present, do not proceed")
PY

sudo ip netns del $NS 2>/dev/null
sudo ip link del vgate0 2>/dev/null
echo "cleanup: done" >> "$OUT/gate_meta.txt"
