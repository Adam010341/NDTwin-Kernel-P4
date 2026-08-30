#!/bin/bash
# ============================================================================================
# T2-1 investigation: is the fabric actually broken, or was the previous run's instrumentation?
#
# The first two T-2 runs disagreed with their own logs. The proxy log recorded 15
# "Discovered link" lines and zero link failures, while my API sampling reported links=0 for
# four minutes. Both cannot be right, and neither is trustworthy until the instrument is.
#
# THREE THINGS THE PREVIOUS RUNS GOT WRONG, FIXED HERE
#   1. The proxy ran with block-buffered stdout, so its log was incomplete at the moment I read
#      it -- the committed log has 706 lines and not one HTTP access line, though the server
#      demonstrably served requests. PYTHONUNBUFFERED=1 now, so the log is a record of what had
#      happened by the time it is read, not of what happened to be flushed.
#   2. Convergence was judged on `all_destination_paths` alone. That is downstream of link
#      discovery, so a fabric mid-discovery and a fabric that will never converge look
#      identical. This waits on the count of discovered links and only then looks at paths.
#   3. pingall ran on a fixed sleep rather than after convergence, so a slow fabric and a
#      broken one were indistinguishable. Here it runs only once discovery has stopped moving,
#      and its full matrix is captured.
#
# The question this run answers is narrow and is the one Adam asked: does a reader who follows
# the manual end up with a fabric that forwards? Everything else is secondary to that.
# [Co-developed with claude code -- Adam]
# ============================================================================================
LOG=~/t2i.log
exec > >(tee -a "$LOG") 2>&1
cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
ts() { date -Is; }
alive() { [ -d "/proc/$1" ]; }
banner(){ echo; echo "############ $* ############"; }

echo "=== T2-1 investigation, started $(ts) ==="
echo "override: $(grep -vE '^[[:space:]]*(#|$)' p4_proxy/mininet/bmv2_binary_override | head -1)"
echo "hosts:    $(cat p4_proxy/mininet/host_count_override)"

sudo mn -c >/dev/null 2>&1
sudo rm -f /tmp/ndtwin_p4_switches.json      # sudo: it is root-owned, and a stale one would pass
rm -f ~/topo2.log ~/proxy2.log

banner "1. FABRIC"
FIFO=/tmp/mn2; rm -f "$FIFO"; mkfifo "$FIFO"
sudo python3 p4_proxy/mininet/p4_testbed_topo.py < "$FIFO" > ~/topo2.log 2>&1 &
TOPO=$!; exec 3> "$FIFO"
for i in $(seq 1 120); do
    grep -q "switches verified listening" ~/topo2.log && break
    alive $TOPO || { echo "topology gone"; break; }
    sleep 2
done
for i in $(seq 1 30); do [ -s /tmp/ndtwin_p4_switches.json ] && break; sleep 2; done
echo "$(ts)  manifest switches: $(python3 -c "import json;print(len(json.load(open('/tmp/ndtwin_p4_switches.json'))))" 2>/dev/null)"

banner "2. PROXY  (unbuffered, so its log can be read while it runs)"
( cd p4_proxy && PYTHONUNBUFFERED=1 PYTHONPATH="$PWD" venv/bin/python proxy_agent/main.py > ~/proxy2.log 2>&1 ) &
PROXY=$!
sleep 15

banner "3. WAIT FOR LINK DISCOVERY -- the thing paths depend on"
echo "Sampling the proxy's own discovery log AND the API together, so a disagreement between"
echo "them is visible rather than being attributed to whichever one I happened to read."
printf "    %-10s %8s %8s %8s %8s %8s\n" time disc_log api_sw api_link api_host api_path
prev=-1; same=0
for i in $(seq 1 40); do
    d=$(grep -c "Discovered link" ~/proxy2.log 2>/dev/null)
    s=$(curl -s -m 5 http://localhost:8081/v1.0/topology/switches | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null)
    l=$(curl -s -m 5 http://localhost:8081/v1.0/topology/links    | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null)
    h=$(curl -s -m 5 http://localhost:8081/v1.0/topology/hosts    | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null)
    p=$(curl -s -m 5 http://localhost:8081/ryu_server/all_destination_paths | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["all_destination_paths"]))' 2>/dev/null)
    printf "    %-10s %8s %8s %8s %8s %8s\n" "+$((i*5))s" "${d:--}" "${s:--}" "${l:--}" "${h:--}" "${p:--}"
    if [ -n "$d" ] && [ "$d" = "$prev" ]; then same=$((same+1)); else same=0; fi
    [ "$same" -ge 3 ] && { echo "    -> discovery stopped moving at $d links"; break; }
    prev=$d; sleep 5
done

banner "4. DATAPATH -- pingall, only now that discovery has settled"
echo "pingall" >&3
for i in $(seq 1 60); do grep -q "Results:" ~/topo2.log && break; sleep 5; done
echo "$(ts)  pingall matrix:"
sed -n '/pingall/,/Results:/p' ~/topo2.log | tail -12 | sed 's/^/      /'
grep -E "\*\*\* Results:" ~/topo2.log | tail -1 | sed 's/^/    /'

banner "5. IS THIS AN LLDP PROBLEM OR A FORWARDING PROBLEM?"
echo "If links are discovered and paths exist but ping still fails, the twin is fine and the"
echo "data plane is not -- a different defect from the one the previous write-up alleged."
echo "    discovered links (log):  $(grep -c 'Discovered link' ~/proxy2.log)"
echo "    link failures (log):     $(grep -c 'link failure' ~/proxy2.log)"
echo "    api links:               $(curl -s -m 5 http://localhost:8081/v1.0/topology/links | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null)"
echo "    api paths:               $(curl -s -m 5 http://localhost:8081/ryu_server/all_destination_paths | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["all_destination_paths"]))' 2>/dev/null)"
echo "    table entries installed on s1 (does the switch have rules at all?):"
sudo timeout 20 simple_switch_CLI --thrift-port 9091 <<< "table_dump ipv4_lpm" 2>/dev/null \
    | grep -cE "^Dumping|entry" | sed 's/^/      entries-ish: /'

banner "SHUTDOWN"
kill $PROXY 2>/dev/null; sleep 2
echo "exit" >&3; sleep 8; exec 3>&-
sudo kill $TOPO 2>/dev/null; sleep 3
sudo mn -c >/dev/null 2>&1
echo "finished $(ts)"
