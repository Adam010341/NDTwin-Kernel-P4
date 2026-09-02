#!/bin/bash
B=http://localhost:8000
echo "=== current damage: s1 rules for 10.0.0.99 (there was a priority=10 routing rule before) ==="
sudo ovs-ofctl dump-flows s1 | grep -c 'nw_dst=10.0.0.99'
echo "=== compare with an untouched neighbour, 10.0.0.98 ==="
sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.98'
echo
echo "=== can h1 still reach h99 through s1? (h99 = 10.0.0.99) ==="
tmux send-keys -t MN 'h1 ping -c 2 -W 2 10.0.0.99' Enter
sleep 8
tmux capture-pane -t MN -p | tail -8
echo "=== control: h1 -> h98, whose rule I never touched ==="
tmux send-keys -t MN 'h1 ping -c 2 -W 2 10.0.0.98' Enter
sleep 8
tmux capture-pane -t MN -p | tail -8
echo
echo "######## REPRODUCE on 10.0.0.98: install priority=99, then modify, watch priority=10 ########"
echo "-- before --"
sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.98'
curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d '{"dpid":1,"priority":99,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.98"},"actions":[{"type":"OUTPUT","port":2}]}' $B/ndt/install_flow_entry
sleep 3
echo "-- after install (expect two rules: priority 10 -> its original port, priority 99 -> port 2) --"
sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.98'
curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d '{"dpid":1,"priority":99,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.98"},"actions":[{"type":"OUTPUT","port":7}]}' $B/ndt/modify_flow_entry
sleep 3
echo "-- after modify to port 7 (did priority=10 change too?) --"
sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.98'
echo
echo "=== ping h98 now ==="
tmux send-keys -t MN 'h1 ping -c 2 -W 2 10.0.0.98' Enter
sleep 8
tmux capture-pane -t MN -p | tail -7
date +%H:%M:%S
