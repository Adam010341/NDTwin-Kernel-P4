#!/bin/bash
# A-8 step 5: the manual's OVS "Safe Shutdown Procedure", followed as written, then assert clean.
# Manual, verbatim:
#   1. In Terminal 2 (Mininet), type `exit` to quit the CLI.
#   2. The script will automatically remove the IP alias.
#   3. Run a final cleanup command in Terminal 2:  sudo mn -c
#   4. Close all other terminal windows.
#   (with the manual's own warning that step 3 already killed Ryu)
# NOTE FOR THE REPORT: the OVS section says "in reverse order" but then lists Terminal 2 first;
# true reverse order would be T3 -> T2 -> T1. The P4 section on the same page *does* start with
# Ctrl+C on the kernel. We follow the OVS text as written and Ctrl-C the kernel at step 4,
# which is what "close all other terminal windows" amounts to for a foreground process.
# [Co-developed with claude code -- Adam]
L=$HOME/a8-logs
echo "=== A-8 SAFE SHUTDOWN  $(date -u +%FT%TZ) ==="
echo "--- state before shutdown ---"
ss -tlnH 'sport = :8000' | sed 's/^/  :8000 /'
ss -tlnH 'sport = :8080' | sed 's/^/  :8080 /'
ss -tlnH 'sport = :6633' | sed 's/^/  :6633 /'
echo "  bridges: $(sudo -n ovs-vsctl list-br 2>/dev/null | wc -l)"
tmux ls
echo

echo "########## STEP 1: Terminal 2 -- 'exit' ##########"
echo "STEP1_UTC=$(date -u +%FT%TZ)"
tmux send-keys -t T2 'exit' Enter
sleep 30
echo "--- Terminal 2 pane after exit (step 2: the IP alias removal should appear here) ---"
tmux capture-pane -p -t T2 -S -30 | tee "$L/shutdown_step1_exit.log"
echo
echo "--- step 2 check: was the IP alias actually removed? ---"
grep -i 'removing ip alias\|cleaning up' "$L/T2_mininet_pane.log" | tail -3
ip -o addr show lo | sed 's/^/  lo: /'
ip -o addr show lo | grep -q '192.168.123.1' && echo "ALIAS_STILL_PRESENT=yes" || echo "ALIAS_REMOVED=yes"
echo

echo "########## STEP 3: Terminal 2 -- 'sudo mn -c' ##########"
echo "STEP3_UTC=$(date -u +%FT%TZ)"
tmux send-keys -t T2 'sudo mn -c' Enter
sleep 35
tmux capture-pane -p -t T2 -S -30 | tee "$L/shutdown_step3_mnc.log"
echo
echo "--- the manual says step 3 already killed Ryu. Did it? ---"
ss -tlnH 'sport = :6633' | grep -q . && echo "RYU_6633_STILL_LISTENING=yes" || echo "RYU_6633_GONE=yes"
ss -tlnH 'sport = :8080' | grep -q . && echo "RYU_8080_STILL_LISTENING=yes" || echo "RYU_8080_GONE=yes"
echo "--- T1 pane, last 12 lines ---"
tmux capture-pane -p -t T1 -S -12 2>&1 | tee "$L/shutdown_T1_after_mnc.log"
echo

echo "########## STEP 4: the remaining terminal -- Ctrl-C the kernel in T3 ##########"
echo "STEP4_UTC=$(date -u +%FT%TZ)"
tmux send-keys -t T3 C-c
sleep 20
echo "--- T3 pane, last 30 lines (expect 'All subsystems stopped. Exiting.') ---"
tmux capture-pane -p -t T3 -S -30 | tee "$L/shutdown_step4_kernel.log"
echo
echo "--- the manual's documented last line ---"
grep -c 'terminate called without an active exception' "$L/T3_kernel_pane.log" | sed 's/^/  occurrences of the documented abort line: /'
grep -c 'All subsystems stopped. Exiting.' "$L/T3_kernel_pane.log" | sed 's/^/  occurrences of "All subsystems stopped": /'
echo

echo "########## ASSERT THE MACHINE IS CLEAN ##########"
sleep 10
echo "--- ports ---"
for p in 8000 8080 6633 6653 8081; do
  if ss -tlnH "sport = :$p" | grep -q .; then echo "PORT_$p=OCCUPIED"; ss -tlnpH "sport = :$p"; else echo "PORT_$p=released"; fi
done
echo -n "UDP_6343: "; ss -ulnH 'sport = :6343' | grep -q . && { echo OCCUPIED; ss -ulnpH 'sport = :6343'; } || echo released
echo
echo "--- ovs bridges (expect 0) ---"
sudo -n ovs-vsctl list-br 2>/dev/null | sed 's/^/  /'
echo "BRIDGES_REMAINING=$(sudo -n ovs-vsctl list-br 2>/dev/null | wc -l)"
echo
echo "--- surviving processes, by comm (project rule: no pgrep -f) ---"
for n in ndtwin_kernel ryu-manager iperf3 mn ovs-testcontroller; do
  c=0
  for p in /proc/[0-9]*; do cm=$(cat "$p/comm" 2>/dev/null)||continue; [ "$cm" = "$n" ] && { c=$((c+1)); echo "  SURVIVOR $n PID=${p#/proc/} $(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)"; }; done
  echo "$n survivors: $c"
done
echo "--- anything with 'ndtwin' or 'mininet' in comm ---"
ps -eo pid=,comm= | grep -Ei 'ndtwin|mininet|ryu' || echo "  (none)"
echo
echo "--- tmux sessions remaining ---"
tmux ls 2>&1
echo
echo "--- section 6 is still absent after the whole run (nothing was installed) ---"
for b in simple_switch simple_switch_grpc p4c p4c-bm2-ss; do command -v $b >/dev/null 2>&1 && echo "  PRESENT $b (UNEXPECTED)" || echo "  ABSENT $b"; done
ls -d ~/p4-guide ~/behavioral-model ~/p4c 2>&1 | sed 's/^/  /'
echo
echo "SHUTDOWN_SCRIPT_EXIT=0"
