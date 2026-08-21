#!/bin/bash
# Does OVS's "256 links down" resolve itself, or is it permanent?
#
# Reconciling two prior results that disagree:
#   (a) TopologyAndFlowMonitor.cpp:2007-2014 says the empty-ipv4 state is TRANSIENT -- Ryu learns
#       host IPs from the ping burst testbed_topo.py fires, and the old single-snapshot ingest
#       just sampled too early. The monitor now re-polls every 5s for 90s, so the edges should
#       come up on their own.
#   (b) Today's measurement said 256 down at ~24s, and mainDev's longer-lived fabric showed 256
#       down too. My manual now claims OVS "never" marks host edges up.
#
# Both cannot be right. This samples the kernel's own graph every 15s for 4 minutes -- past the
# 90s converging window and well past the ping burst.
# [Co-developed with claude code -- Adam]
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
NDT="$REPO/tools/test_workflow/ndt"
export NDT_OWNER=manual-verify-0821
export TERM="${TERM:-dumb}"

"$NDT" claim 25 "measuring whether OVS host edges ever come up" >/dev/null || exit 1
echo "== bringing OVS up =="
"$NDT" up ovs 2>&1 | tail -5
T0=$(date +%s)

echo
echo "elapsed  edges_up  edges_down  hosts_up  ryu_hosts  ryu_hosts_with_ipv4"
for i in $(seq 0 16); do
    now=$(date +%s)
    graph="$(curl -sf --max-time 5 http://localhost:8000/ndt/get_graph_data 2>/dev/null)"
    ryu="$(curl -sf --max-time 5 http://localhost:8080/v1.0/topology/hosts 2>/dev/null)"
    printf '%5ss   ' "$(( now - T0 ))"
    printf '%s\n' "$graph" | "$REPO/p4_proxy/venv/bin/python" -c '
import json,sys
try: g=json.load(sys.stdin)
except Exception: print("  (kernel not answering)"); raise SystemExit
up   = sum(1 for e in g["edges"] if e["is_up"])
down = sum(1 for e in g["edges"] if not e["is_up"])
hu   = sum(1 for n in g["nodes"] if n.get("vertex_type")==1 and n.get("is_up"))
print(f"{up:8d}  {down:10d}  {hu:8d}", end="  ")
'
    printf '%s' "$ryu" | "$REPO/p4_proxy/venv/bin/python" -c '
import json,sys
try: h=json.load(sys.stdin)
except Exception: print("(ryu n/a)"); raise SystemExit
print(f"{len(h):9d}  {sum(1 for x in h if x.get(\"ipv4\")):19d}")
'
    sleep 15
done

echo
echo "== tearing down =="
"$NDT" down 2>&1 | tail -3
"$NDT" release
