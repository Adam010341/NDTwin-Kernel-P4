#!/bin/bash
echo "RUN2_START $(date +%H:%M:%S)"
~/.local/bin/ndt down >/dev/null 2>&1
sudo mn -c >/dev/null 2>&1
for s in MN RYU KERNEL UP; do tmux kill-session -t $s 2>/dev/null; done
echo "=== Terminal 1 ==="
tmux new-session -d -s RYU -x 200 -y 50
tmux send-keys -t RYU 'cd ~/Desktop/NDTwin-Kernel && source ~/miniconda3/etc/profile.d/conda.sh && conda activate ryu-env && ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link' Enter
sleep 15
ss -lntp 2>/dev/null | grep -c ':6633' 
echo "=== Terminal 2 ==="
T2=$(date +%s)
tmux new-session -d -s MN -x 200 -y 50
tmux send-keys -t MN 'cd ~/Desktop/NDTwin-Kernel && sudo python3 testbed_topo.py' Enter
sleep 50
echo "--- convergence poll (run 2) ---"
prev=""
for r in $(seq 1 25); do
  line=""; for i in $(seq 1 10); do line="$line $(sudo ovs-ofctl dump-flows s$i 2>/dev/null | grep -c actions=)"; done
  now=$(date +%s); echo "  t+$((now-T2))s :$line"
  if [ "$line" = "$prev" ] && [ "$line" != " 0 0 0 0 0 0 0 0 0 0" ]; then echo "  STABLE at t+$((now-T2))s after topology start"; break; fi
  prev="$line"; sleep 10
done
echo "=== Terminal 3 ==="
tmux new-session -d -s KERNEL -x 200 -y 50
tmux send-keys -t KERNEL 'cd ~/Desktop/NDTwin-Kernel/build && sudo bin/ndtwin_kernel --mode mininet --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --no-ai --loglevel info' Enter
sleep 25
tmux capture-pane -t KERNEL -p -S -300 | grep -E "topology from the control plane|Pulled|Data plane|Server Listening" | tail -5
echo "--- did the renamed host from run 1 persist into run 2? ---"
curl -sS http://localhost:8000/ndt/get_graph_data | grep -o '"device_name":"HstA"' | head -1
echo "RUN2_UP $(date +%H:%M:%S)"
