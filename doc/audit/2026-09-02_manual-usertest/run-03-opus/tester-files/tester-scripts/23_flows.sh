#!/bin/bash
echo "=== s1 flow table composition (manual: 'one forwarding rule per destination host, plus its table-miss entry') ==="
sudo ovs-ofctl dump-flows s1 > /tmp/s1flows.txt 2>&1
echo "total lines with actions=: $(grep -c actions= /tmp/s1flows.txt)"
echo "--- by priority ---"
grep -o 'priority=[0-9]*' /tmp/s1flows.txt | sort | uniq -c | sort -rn
echo "--- the non-priority-1 (non-host) entries, verbatim ---"
grep -v 'priority=1,' /tmp/s1flows.txt | head -10
echo "--- how many nw_dst rules (one per destination host)? ---"
grep -c 'nw_dst=' /tmp/s1flows.txt
echo "--- table-miss / CONTROLLER entries ---"
grep -c 'CONTROLLER' /tmp/s1flows.txt
echo
echo "=== confirm all ten switches agree ==="
for i in $(seq 1 10); do printf 's%-3s %s\n' "$i" "$(sudo ovs-ofctl dump-flows s$i 2>/dev/null | grep -c actions=)"; done
echo
echo "=== Ryu install summary line ==="
tmux capture-pane -t RYU -p -S -4000 | grep -E "install_all_pair_paths done" | tail -2
date +%H:%M:%S
