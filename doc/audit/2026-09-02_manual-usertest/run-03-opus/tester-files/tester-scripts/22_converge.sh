#!/bin/bash
echo "=== the manual's convergence check, sampled until two identical rounds ==="
prev=""
for r in $(seq 1 40); do
  line=""
  for i in $(seq 1 10); do
    c=$(sudo ovs-ofctl dump-flows s$i 2>/dev/null | grep -c actions=)
    line="$line $c"
  done
  echo "$(date +%H:%M:%S) round$r:$line"
  if [ "$line" = "$prev" ] && [ "$line" != " 0 0 0 0 0 0 0 0 0 0" ]; then
     echo "STABLE (two identical rounds in a row)"
     break
  fi
  prev="$line"
  sleep 10
done
echo "=== did Ryu print the message the manual names? ==="
tmux capture-pane -t RYU -p -S -4000 | grep -n "all-destination paths installed" | tail -3
echo "=== last few Ryu lines ==="
tmux capture-pane -t RYU -p | tail -6
date +%H:%M:%S
