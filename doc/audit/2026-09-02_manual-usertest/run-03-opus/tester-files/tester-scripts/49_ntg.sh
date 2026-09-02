#!/bin/bash
cd ~/Network-Traffic-Generator
echo "=== HOST_NUM in NTG's testbed_topo.py ==="
grep -nE "^HOST_NUM|HOST_NUM *=" testbed_topo.py | head -3
echo "=== controller port it dials ==="
grep -nE "RemoteController|6633|6653|port=" testbed_topo.py | head -6
echo
echo "=== F03: manual says change NTG.yaml host_file to ./setting/Mininet.yaml ==="
cp NTG.yaml ~/logs/NTG.yaml.orig
sed -i 's#host_file: "./setting/Hardware.yaml"#host_file: "./setting/Mininet.yaml"#' NTG.yaml
grep host_file NTG.yaml
echo
echo "=== tear down the NDTwin topology (keep Ryu + kernel) so NTG can build its own ==="
tmux send-keys -t MN 'exit' Enter
sleep 25
sudo mn -c > /dev/null 2>&1
sudo ovs-vsctl list-br | tr '\n' ' '; echo " <- bridges after cleanup"
echo "-- note: mn -c kills Ryu (documented). restart Ryu for NTG. --"
tmux kill-session -t RYU 2>/dev/null
tmux new-session -d -s RYU -x 200 -y 50
tmux send-keys -t RYU 'cd ~/Desktop/NDTwin-Kernel && source ~/miniconda3/etc/profile.d/conda.sh && conda activate ryu-env && ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link' Enter
sleep 15
ss -lntp 2>/dev/null | grep -c ':6633'
echo
echo "=== F05: start NTG's topology with the venv interpreter (manual: substitute your own path) ==="
echo "NTG_START $(date +%H:%M:%S)"
tmux kill-session -t NTG 2>/dev/null
tmux new-session -d -s NTG -x 200 -y 50
tmux send-keys -t NTG 'cd ~/Network-Traffic-Generator && sudo ~/ntg-env/bin/python testbed_topo.py' Enter
sleep 60
echo "--- pane ---"
tmux capture-pane -t NTG -p | tail -25
date +%H:%M:%S
