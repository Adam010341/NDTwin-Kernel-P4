# run-03 harvest pass 3: ONE read-only GET to settle the NTG-loop hypothesis before the VM stops.
# GET only - no writes, no restarts. [Co-developed with claude code -- Adam]
set -u
{
  echo "captured: $(date -u +%FT%TZ)"
  echo "=== is NTG still looping? last 2 lines of the NTG pane ==="
  tmux capture-pane -t NTG -p -S -3 2>&1 | tail -3
  echo
  echo "=== GET /ndt/get_graph_data : every node device_name (READ ONLY) ==="
  curl -s --max-time 20 http://127.0.0.1:8000/ndt/get_graph_data \
    | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception as e: print("parse failed:",e); sys.exit()
nodes=d.get("nodes") or d.get("data",{}).get("nodes") or []
print("node count:",len(nodes))
bad=[]
for n in nodes:
    nm=n.get("device_name")
    if nm is None: continue
    tail=str(nm)[1:]
    if not tail.isdigit(): bad.append(nm)
print("device_name values whose [1:] is NOT all digits:",bad)
print("first 12 device_name:",[n.get("device_name") for n in nodes[:12]])
'
  echo
  echo "=== the exact expression NTG runs (distance_seperate.py:37) ==="
  echo 'device_name = f"h{ (int(node[device_name][1:])-1)*(len(node[ip])) + (i+1) }"'
  echo "=== does int() throw on the observed values? ==="
  curl -s --max-time 20 http://127.0.0.1:8000/ndt/get_graph_data \
    | python3 -c '
import json,sys
d=json.load(sys.stdin); nodes=d.get("nodes") or d.get("data",{}).get("nodes") or []
for n in nodes:
    nm=n.get("device_name")
    if nm is None: continue
    try: int(str(nm)[1:])
    except ValueError as e: print("ValueError on device_name=%r -> %s" % (nm,e))
'
} > ~/NTG-HYPOTHESIS.txt 2>&1
cat ~/NTG-HYPOTHESIS.txt
