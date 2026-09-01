#!/bin/bash
# ============================================================================================
# A-3 step 1c: confirmation run on a stack that is provably FRESH.
#
# 🔴 WHY 1b HAD TO BE REDONE. `sudo kill $KERN` in 1a killed the SUBSHELL, not the kernel:
#    $! is the `( cd build && sudo ./bin/ndtwin_kernel ... )` wrapper, and the real process is
#    its child. So 1a's kernel (pid 3052) and 1a's proxy survived, kept :8000 and :8081, and
#    1b's own kernel died after 21 log lines while 1b's measurements were quietly answered by
#    1a's orphan. This is the wrapper-vs-child pid defect already recorded in
#    install-manual-clean-room-test §11.2 -- the same defect that produced H-26's "run 3 FAILED".
#
#    Nothing in 1b said so. The tell was indirect: "destination paths settled at: 0" and a
#    21-line kernel log, next to a Traffic-Engineering-App that was getting real JSON back.
#
# 🔴 AND MY LIVENESS SCAN WAS BLIND TO IT. Walking /proc/*/exe as `tester` cannot see a
#    root-owned process: readlink gets EACCES and the entry is silently skipped, so the scan
#    reported no ndtwin_kernel while one was listening. Ports are the honest witness here, so
#    this script asserts on `ss`, and uses sudo when it needs the owning pid.
#
# ACCEPTANCE IS ON STATE: the ports must be free BEFORE the stack starts and free AFTER it
# stops. An exit code from `kill` proves neither.
# [Co-developed with claude code -- Adam]
# ============================================================================================
set -u
LOG=~/a3_step1c.log
exec > >(tee "$LOG") 2>&1
cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
echo "=== A-3 step 1c started $(date -Is) ==="

port_holder() { sudo ss -tlnpH "( sport = :$1 )" 2>/dev/null; }
port_free()   { [ -z "$(sudo ss -tlnH "( sport = :$1 )" 2>/dev/null)" ]; }

echo
echo "############ 0. CLEAR THE ORPHANS FROM 1a, AND PROVE THEY ARE GONE ############"
for p in 8000 8081; do echo "  before :$p -> $(port_holder $p | sed 's/^/    /')"; done
for p in 8000 8081; do
    pid=$(sudo ss -tlnpH "( sport = :$p )" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    if [ -n "$pid" ]; then echo "  killing holder of :$p -- pid $pid"; sudo kill -TERM "$pid" 2>/dev/null; fi
done
sleep 8
for p in 8000 8081; do
    if port_free $p; then echo "  ✅ :$p is free (checked by state, not by kill's rc)"
    else echo "  🔴 :$p STILL HELD: $(port_holder $p)"; sudo kill -KILL $(sudo ss -tlnpH "( sport = :$p )" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2) 2>/dev/null; sleep 5; fi
done
sudo mn -c >/dev/null 2>&1
for p in 8000 8081; do port_free $p && echo "  confirmed free: :$p" || echo "  🔴 :$p STILL HELD"; done

echo
echo "############ 1. FRESH STACK ############"
rm -f /tmp/ndtwin_p4_switches.json
FIFO=/tmp/mn_stdin_a3c; rm -f "$FIFO"; mkfifo "$FIFO"
sudo python3 p4_proxy/mininet/p4_testbed_topo.py < "$FIFO" > ~/a3c_topo.log 2>&1 &
TOPO=$!; exec 3> "$FIFO"
for i in $(seq 1 120); do grep -q "switches verified listening" ~/a3c_topo.log && break
    [ -d "/proc/$TOPO" ] || break; sleep 2; done
for i in $(seq 1 30); do [ -s /tmp/ndtwin_p4_switches.json ] && break; sleep 2; done
echo "  switches in manifest: $(python3 -c "import json;print(len(json.load(open('/tmp/ndtwin_p4_switches.json'))))" 2>/dev/null)"

( cd p4_proxy && PYTHONPATH="$PWD" venv/bin/python proxy_agent/main.py > ~/a3c_proxy.log 2>&1 ) &
sleep 15
prev=-1
for i in $(seq 1 40); do
    c=$(curl -s http://localhost:8081/ryu_server/all_destination_paths \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["all_destination_paths"]))' 2>/dev/null)
    [ -z "$c" ] && c=ERR
    if [ "$c" = "$prev" ] && [ "$c" != "ERR" ] && [ "$c" != "0" ]; then break; fi
    prev=$c; sleep 3
done
echo "  destination paths settled at: $prev   (0 or ERR here means the proxy did NOT come up)"

( cd build && sudo ./bin/ndtwin_kernel --mode mininet \
    --topology ../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json \
    --no-ai --loglevel info > ~/a3c_kernel.log 2>&1 ) &
sleep 30
KPID=$(sudo ss -tlnpH "( sport = :8000 )" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
echo "  kernel REALLY listening as pid: ${KPID:-NONE}   (the child, not the wrapper)"
echo "  its kernel log is $(wc -l < ~/a3c_kernel.log) lines -- a 21-line log means it died early"
PPID_PROXY=$(sudo ss -tlnpH "( sport = :8081 )" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
echo "  proxy REALLY listening as pid: ${PPID_PROXY:-NONE}"

probe() {
    local ep="$1" g p v
    g=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "http://localhost:8000$ep")
    p=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -X POST \
        -H 'Content-Type: application/json' -d '{}' "http://localhost:8000$ep")
    if   [ "$g" = "000" ] && [ "$p" = "000" ]; then v="NO-ANSWER"
    elif [ "$g" = "404" ] && [ "$p" = "404" ]; then v="🔴 ABSENT"
    else v="PRESENT"; fi
    printf 'GET=%-4s POST=%-4s %s' "$g" "$p" "$v"
}

echo
echo "############ 2. CONTROLS ############"
printf '  (a) POSITIVE GET-routed   %-40s %s\n' "/ndt/get_graph_data"   "$(probe /ndt/get_graph_data)"
printf '  (b) POSITIVE POST-routed  %-40s %s\n' "/ndt/app_register"     "$(probe /ndt/app_register)"
printf '  (c) NEGATIVE invented     %-40s %s\n' "/ndt/definitely_not_a_real_endpoint_a3" "$(probe /ndt/definitely_not_a_real_endpoint_a3)"
printf '  (d) NEGATIVE laptop-only  %-40s %s\n' "/ndt/get_flow_dispatch_status" "$(probe /ndt/get_flow_dispatch_status)"

echo
echo "############ 3. PER-APP MATRIX (confirmation) ############"
cd ~/Desktop || exit 1
for app in Energy-Saving-App Traffic-Engineering-App Network-Traffic-Visualizer Simulation-Platform-Manager; do
    echo; echo "===== $app ====="
    if [ "$app" = "Traffic-Engineering-App" ]; then
        eps=$(grep -ohE 'ndt_url *\+ *"[A-Za-z0-9_/-]+"' "$app"/*.py 2>/dev/null | sed -E 's/.*"(.*)"/\/ndt\/\1/' | sort -u)
    else
        eps=$(grep -rhoE '/ndt/[A-Za-z0-9_/-]+' "$app" 2>/dev/null | sort -u)
    fi
    absent=0; present=0
    for ep in $eps; do
        r=$(probe "$ep"); printf '  %-70s %s\n' "$ep" "$r"
        case "$r" in *ABSENT*) absent=$((absent+1));; *) present=$((present+1));; esac
    done
    [ "$absent" = 0 ] && echo "  ==> $app: $present/$((present+absent)) PRESENT -- compatible" \
                      || echo "  ==> $app: $present present, 🔴 $absent ABSENT -- NOT fully compatible"
done

echo
echo "############ 4. SHUTDOWN -- kill the CHILD pids, then assert the ports ############"
cd ~/Desktop/NDTwin-Kernel || exit 1
[ -n "${KPID:-}" ] && sudo kill -TERM "$KPID" 2>/dev/null
[ -n "${PPID_PROXY:-}" ] && sudo kill -TERM "$PPID_PROXY" 2>/dev/null
sleep 6
echo "exit" >&3; sleep 8; exec 3>&-
sudo kill -TERM $TOPO 2>/dev/null; sleep 4
sudo mn -c >/dev/null 2>&1
sleep 2
for p in 8000 8081; do
    port_free $p && echo "  ✅ :$p free after shutdown" || echo "  🔴 :$p STILL HELD: $(port_holder $p)"
done
echo "A3_STEP1C_DONE $(date -Is)"
