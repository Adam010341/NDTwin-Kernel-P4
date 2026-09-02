#!/bin/bash
# A-8 steps 3-4: a real ping, then the manual's iperf3 validation, then read the flows back
# out of the kernel's REST API while the transfer is still running.
# Manual, verbatim (Generating Traffic (Validation)):
#   mininet> h1 iperf3 -s &
#   mininet> h2 iperf3 -c h1 -t 300 &
#   curl -X GET http://localhost:8000/ndt/get_detected_flow_data
# [Co-developed with claude code -- Adam]
L=$HOME/a8-logs
echo "=== A-8 TRAFFIC + API  $(date -u +%FT%TZ) ==="

echo "########## 1. A REAL PING BETWEEN TWO HOSTS (h1 -> h2) ##########"
: > "$L/ping_marker.txt"
tmux send-keys -t T2 'h1 ping -c 4 h2' Enter
sleep 12
echo "--- pane, last 20 lines ---"
tmux capture-pane -p -t T2 -S -20 | tee "$L/ping_h1_h2.log"
echo
echo "########## 1b. A SECOND PING ACROSS THE FABRIC (h1 -> h100, different switch) ##########"
tmux send-keys -t T2 'h1 ping -c 4 h100' Enter
sleep 12
tmux capture-pane -p -t T2 -S -20 | tee "$L/ping_h1_h100.log"
echo

echo "########## 2. iperf3, exactly as the manual writes it ##########"
echo "IPERF_START_UTC=$(date -u +%FT%TZ)"
tmux send-keys -t T2 'h1 iperf3 -s &' Enter
sleep 4
tmux send-keys -t T2 'h2 iperf3 -c h1 -t 300 &' Enter
echo "--- waiting 25 s for the transfer to establish and the kernel to see it ---"
sleep 25
echo "--- pane after starting iperf3 ---"
tmux capture-pane -p -t T2 -S -25 | tee "$L/iperf3_start.log"
echo

echo "########## 3. curl :8000/ndt/get_detected_flow_data (WHILE the transfer runs) ##########"
for s in 1 2 3; do
  echo "----- sample $s at $(date -u +%FT%TZ) -----"
  curl -sS -X GET http://localhost:8000/ndt/get_detected_flow_data \
    | tee "$L/get_detected_flow_data_$s.json" | head -c 4000
  echo
  echo "  bytes: $(wc -c < "$L/get_detected_flow_data_$s.json")"
  [ $s -lt 3 ] && sleep 12
done
echo
echo "--- decode the addresses in the newest sample, and check they name h1/h2 ---"
python3 - "$L/get_detected_flow_data_3.json" <<'PY' 2>&1 | tee "$L/flow_decode.log"
import json,struct,sys
d=json.load(open(sys.argv[1]))
def ip(v):
    try: return '.'.join(str(b) for b in struct.pack('<I', int(v)))
    except Exception: return str(v)
recs = d if isinstance(d,list) else d.get('data', d.get('flows', d))
print("record count:", len(recs) if hasattr(recs,'__len__') else '?')
for i,r in enumerate(recs if isinstance(recs,list) else []):
    print(f"--- record {i} ---")
    for k in ('src_ip','dst_ip'):
        if k in r: print(f"  {k}: {r[k]}  ->  {ip(r[k])}")
    for k in ('src_port','dst_port','protocol','flow_rate','path','switch_path'):
        if k in r: print(f"  {k}: {r[k]}")
print()
ips=set()
for r in (recs if isinstance(recs,list) else []):
    for k in ('src_ip','dst_ip'):
        if k in r: ips.add(ip(r[k]))
print("DISTINCT DECODED ADDRESSES:", sorted(ips))
print("NAMES_h1_10.0.0.1:", "YES" if "10.0.0.1" in ips else "NO")
print("NAMES_h2_10.0.0.2:", "YES" if "10.0.0.2" in ips else "NO")
ports=set()
for r in (recs if isinstance(recs,list) else []):
    for k in ('src_port','dst_port'):
        if k in r: ports.add(r[k])
print("PORTS SEEN:", sorted(ports))
print("IPERF3_PORT_5201_PRESENT:", "YES" if 5201 in ports else "NO")
PY
echo

echo "########## 4. curl :8000/ndt/get_graph_data ##########"
curl -sS -X GET http://localhost:8000/ndt/get_graph_data > "$L/get_graph_data.json"
echo "bytes: $(wc -c < "$L/get_graph_data.json")"
head -c 1500 "$L/get_graph_data.json"; echo
python3 - "$L/get_graph_data.json" <<'PY' 2>&1 | tee "$L/graph_decode.log"
import json,sys
d=json.load(open(sys.argv[1]))
print("top-level type:", type(d).__name__, "keys:", list(d)[:10] if isinstance(d,dict) else '')
def cnt(o,*names):
    for n in names:
        if isinstance(o,dict) and n in o and hasattr(o[n],'__len__'): return n,len(o[n])
    return None,None
for names in (('nodes','node','vertices'),('edges','links','edge')):
    n,c = cnt(d,*names)
    if n: print(f"{n}: {c}")
if isinstance(d,dict) and 'nodes' in d:
    ns=d['nodes']
    kinds={}
    for x in ns:
        k = x.get('type') or x.get('kind') or ('switch' if str(x.get('id','')).startswith('s') else 'other')
        kinds[k]=kinds.get(k,0)+1
    print("node kinds:", kinds)
    print("first 3 nodes:", ns[:3])
PY
echo

echo "########## 5. iperf3 still running? (no pgrep -f) ##########"
for p in /proc/[0-9]*; do c=$(cat "$p/comm" 2>/dev/null)||continue; [ "$c" = "iperf3" ] && echo "PID=${p#/proc/} $(tr '\0' ' ' < "$p/cmdline")"; done
echo
echo "--- sFlow datagrams actually reaching the kernel? (kernel log) ---"
grep -icE 'sflow|flow sample' "$L/T3_kernel_pane.log" | sed 's/^/kernel log lines mentioning sflow: /'
echo "--- kernel errors so far ---"
grep -icE '\[error\]|\[critical\]' "$L/T3_kernel_pane.log" | sed 's/^/error+critical: /'
grep -ihE '\[error\]|\[critical\]' "$L/T3_kernel_pane.log" | head -10
echo "TRAFFIC_SCRIPT_EXIT=0"
