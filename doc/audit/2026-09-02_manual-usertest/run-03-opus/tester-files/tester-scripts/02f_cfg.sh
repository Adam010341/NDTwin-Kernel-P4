#!/bin/bash
cd ~/Desktop/NDTwin-Kernel
cp intelligent_router.py ~/logs/intelligent_router.py.orig
echo "=== edit (1) static_topology_file_path : /home/adam -> /home/$(whoami) ==="
sed -i 's#"/home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json"#"/home/ndt/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json"#' intelligent_router.py
sed -n '36,39p' intelligent_router.py
echo "=== (2) is_mininet already True (line 56); manual wants True ==="
sed -n '56p' intelligent_router.py
echo "=== (3) switch_num : no literal knob; derived. What does it resolve to? ==="
source ~/miniconda3/etc/profile.d/conda.sh; conda activate ryu-env
python - <<'PY'
import json,pathlib
p=pathlib.Path("/home/ndt/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json")
topo=json.load(open(p))
dpids=sorted(int(n["dpid"]) for n in topo.get("nodes",[]) if n and n.get("vertex_type")==0 and n.get("dpid"))
print("switches declared in JSON:",len(dpids),"dpids:",dpids)
print("hosts declared:",sum(1 for n in topo.get("nodes",[]) if n and n.get("vertex_type")!=0))
PY
echo "=== does the file parse after my edit? ==="
python -c "import ast,sys; ast.parse(open('intelligent_router.py').read()); print('parses OK')"
echo "=== Step 2.7: extra python libs in ryu-env ==="
pip install -U networkx 2>&1 | tail -2
pip install -U "requests<2.29" "urllib3<2" 2>&1 | tail -2
pip list 2>/dev/null | grep -Ei "^(networkx|requests|urllib3) "
date +%H:%M
