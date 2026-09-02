#!/bin/bash
echo "=== workaround: install the helper the ndt script expects ==="
sudo install -m 0755 ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
ls -l /usr/local/sbin/ndtwin-lab
echo
echo "=== retry: ndt up ovs (this is also my SECOND bring-up of the OVS stack) ==="
echo "UP2_START $(date +%H:%M:%S)"
tmux kill-session -t UP 2>/dev/null
tmux new-session -d -s UP -x 210 -y 60
tmux send-keys -t UP 'ndt up ovs; echo "NDT_UP_EXIT=$?"' Enter
