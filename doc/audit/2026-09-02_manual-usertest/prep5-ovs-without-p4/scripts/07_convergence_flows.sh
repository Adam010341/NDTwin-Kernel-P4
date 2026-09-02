#!/bin/bash
# A-8 step 3: the manual's own convergence check -- ask the switches, not the controller.
# Manual, verbatim:
#   for i in $(seq 1 10); do
#     printf 's%-3s %s\n' "$i" "$(sudo ovs-ofctl dump-flows s$i 2>/dev/null | grep -c actions=)"
#   done
# Manual's expected value: 130 per switch (128 destination rules + 1 LLDP + 1 table-miss).
# [Co-developed with claude code -- Adam]
echo "=== A-8 CONVERGENCE / FLOW COUNTS  $(date -u +%FT%TZ) ==="
echo "--- did the manual's convergence message appear? ---"
grep -ih 'all-destination paths installed' "$HOME/a8-logs/T2_mininet_pane.log" "$HOME/a8-logs/T1_ryu_pane.log" 2>/dev/null | tail -3 || echo "(message not found in either pane log)"
echo "--- ryu's own rules= line ---"
grep -ih 'install_all_pair_paths done' "$HOME/a8-logs/T1_ryu_pane.log" 2>/dev/null | tail -3 || echo "(no install_all_pair_paths line)"
echo
for round in 1 2 3; do
  echo "########## SAMPLE $round  $(date -u +%FT%TZ) ##########"
  for i in $(seq 1 10); do
    printf 's%-3s %s\n' "$i" "$(sudo ovs-ofctl dump-flows s$i 2>/dev/null | grep -c actions=)"
  done
  [ $round -lt 3 ] && sleep 10
done
echo
echo "--- total across all ten ---"
T=0; for i in $(seq 1 10); do n=$(sudo ovs-ofctl dump-flows s$i 2>/dev/null | grep -c actions=); T=$((T+n)); done
echo "TOTAL_FLOWS_ALL_TEN=$T"
echo
echo "--- proof these are real forwarding rules, not noise: a sample from s1 ---"
sudo ovs-ofctl dump-flows s1 2>/dev/null | head -5
echo "..."
sudo ovs-ofctl dump-flows s1 2>/dev/null | grep -c 'nw_dst=10\.0\.0\.' | sed 's/^/s1 nw_dst=10.0.0.x rules: /'
echo
echo "--- switch-to-controller connections (all ten should be connected to :6633) ---"
sudo -n ovs-vsctl --columns=name,controller list bridge 2>/dev/null | head -30
for i in $(seq 1 10); do printf 's%-3s ' "$i"; sudo -n ovs-vsctl get-controller s$i 2>/dev/null | tr '\n' ' '; sudo -n ovs-ofctl show s$i >/dev/null 2>&1 && echo "OF_OK" || echo "OF_FAIL"; done
echo "CONVERGENCE_SCRIPT_EXIT=0"
