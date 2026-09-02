#!/bin/bash
echo "=== full reset: ndt down, mn -c, drop my stale by-hand tmux sessions ==="
~/.local/bin/ndt down 2>&1 | tail -8
for s in MN RYU KERNEL NSR UP; do tmux kill-session -t $s 2>/dev/null; done
sudo mn -c > /dev/null 2>&1
sudo ovs-vsctl list-br | tr '\n' ' '; echo " <- bridges (expect empty)"
ss -lntp 2>/dev/null | grep -E ':6633|:8080|:8000' || echo "(all ports closed)"
echo
echo "=== clean retry of ndt up ovs (attempt 3) ==="
echo "UP3_START $(date +%H:%M:%S)"
tmux new-session -d -s UP -x 210 -y 60
tmux send-keys -t UP 'ndt up ovs; echo "NDT_UP_EXIT=$?"' Enter
