#!/usr/bin/env bash
# OVS arm: A-4e (strict modify, read the REAL table back) and A-2 (bounded topology poll).
# Recipe sources: doc/audit/2026-08-30_known-issues-wave/11_behavior-evidence.md sections
# 3.3, 5.2 and 5.3. Both need Ryu on :8080, which only the OVS arm provides.
# ndt up/down kill the calling shell (exit 144) -- this whole script runs under setsid and
# every verdict is taken from state, never from a return code.
# [Co-developed with claude code -- Adam]
set -u
cd /home/adam/Desktop/NDTwin-Kernel
export NDT_OWNER=live-recipes
K=http://localhost:8000
RYU=http://localhost:8080
KLOG=.test_run/logs/kernel.log
PROBE=10.0.0.254          # spec.py's convention: never aim a flow write at a real host

echo "##### 0. bring up the OVS arm #####"
tools/test_workflow/ndt down 2>&1 | tail -5 || echo "(down rc=$? ignored)"
tools/test_workflow/ndt up ovs 2>&1 | tail -25 || echo "(up rc=$? ignored)"
echo "--- ready marker check (verdict is this, not rc) ---"
tools/test_workflow/ndt status 2>&1 | sed -n '/^running/,/^network health/p'

echo
echo "##### 1. A-4e BLOCKING PRE-MERGE CHECK (section 3.3): does ofctl_rest serve modify_strict? #####"
echo -n "  POST $RYU/stats/flowentry/modify_strict -> HTTP "
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 -X POST \
  $RYU/stats/flowentry/modify_strict \
  -H 'Content-Type: application/json' \
  -d "{\"dpid\":1,\"priority\":100,\"match\":{\"eth_type\":2048,\"ipv4_dst\":\"$PROBE\"},\"actions\":[{\"type\":\"OUTPUT\",\"port\":1}]}"
echo "  200/any-non-404 => route exists, A-4e fix stands. 404 => DO NOT MERGE A-4e."

echo
echo "##### 2. A-4e section 5.2: two priorities, modify the high one, READ THE REAL TABLE BACK #####"
KMARK=$(wc -l < $KLOG)
echo "  kernel.log mark: $KMARK"
echo "  --- install priority 100 -> OUTPUT port 1 ---"
curl -s --max-time 20 -X POST "$K/ndt/install_flow_entry" -H 'Content-Type: application/json' \
  -d "{\"dpid\":1,\"priority\":100,\"match\":{\"eth_type\":2048,\"ipv4_dst\":\"$PROBE\"},\"actions\":[{\"type\":\"OUTPUT\",\"port\":1}]}"; echo
echo "  --- install priority 10 -> OUTPUT port 2 (same destination, different priority) ---"
curl -s --max-time 20 -X POST "$K/ndt/install_flow_entry" -H 'Content-Type: application/json' \
  -d "{\"dpid\":1,\"priority\":10,\"match\":{\"eth_type\":2048,\"ipv4_dst\":\"$PROBE\"},\"actions\":[{\"type\":\"OUTPUT\",\"port\":2}]}"; echo
echo "  (flow writes are async: 200 queued says nothing. sleeping 8s for the dispatcher)"
sleep 8

dump() {
    curl -s --max-time 15 "$RYU/stats/flow/1" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception as e: print('  (could not parse flow dump:',e,')'); sys.exit()
for dp,rows in d.items():
    for r in rows:
        m=r.get('match',{})
        if str(m.get('ipv4_dst',''))=='$PROBE' or str(m.get('nw_dst',''))=='$PROBE':
            print('    prio=%-5s actions=%-28s pkts=%-6s dur=%.1fs match=%s' % (
                r.get('priority'), r.get('actions'), r.get('packet_count'),
                r.get('duration_sec',0), m))
"
}
echo "  --- table BEFORE modify ---"; dump

echo "  --- modify priority 100 -> OUTPUT port 3 (must hit ONLY the prio-100 entry) ---"
curl -s --max-time 20 -X POST "$K/ndt/modify_flow_entry" -H 'Content-Type: application/json' \
  -d "{\"dpid\":1,\"priority\":100,\"match\":{\"eth_type\":2048,\"ipv4_dst\":\"$PROBE\"},\"actions\":[{\"type\":\"OUTPUT\",\"port\":3}]}"; echo
sleep 8
echo "  --- table AFTER modify ---"; dump
echo "  PASS = prio-100 actions now port 3, prio-10 STILL port 2 (untouched)."
echo "  --- kernel.log since mark $KMARK: any modify failure? (a 404 surfaces nowhere else) ---"
tail -n +"$((KMARK+1))" $KLOG | grep -iE "modify|flowentry|Controller.cpp" | head -20
echo "  (no modify-failure line = the strict route was served)"

echo
echo "##### 3. A-2 section 5.3: wedge the control plane, watch the clock and the log #####"
if ! sudo -n iptables -L INPUT -n >/dev/null 2>&1; then
    echo "  SKIPPED-NO-IPTABLES-SUDO: cannot add the DROP rule without a password."
else
    A2MARK=$(wc -l < $KLOG)
    echo "  kernel.log mark before wedge: $A2MARK"
    echo "  --- inserting DROP on :8080 ---"
    sudo -n iptables -I INPUT -p tcp --dport 8080 -j DROP && echo "  rule inserted"
    sudo -n iptables -L INPUT -n --line-numbers | grep -E "8080|DROP" | head -5
    echo "  --- waiting 80s (through two poll intervals; a wedged pass costs ~15s) ---"
    sleep 80
    echo "  --- 'no answer' lines since mark (must be EXACTLY 1, edge-triggered) ---"
    tail -n +"$((A2MARK+1))" $KLOG | grep -n "topology poll got no answer" || echo "  (none)"
    echo -n "  count: "; tail -n +"$((A2MARK+1))" $KLOG | grep -c "topology poll got no answer"
    echo "  --- removing the DROP rule (symmetric -D) ---"
    sudo -n iptables -D INPUT -p tcp --dport 8080 -j DROP && echo "  rule deleted"
    echo "  --- verifying the rule is gone ---"
    if sudo -n iptables -L INPUT -n | grep -qE "dpt:8080.*DROP|DROP.*dpt:8080"; then
        echo "  FAIL: a DROP rule on 8080 is STILL present"
        sudo -n iptables -L INPUT -n | grep 8080
    else
        echo "  OK: no DROP rule on 8080 remains"
    fi
    echo "  --- waiting 40s for recovery ---"; sleep 40
    echo "  --- 'answered again' lines since mark (must be EXACTLY 1) ---"
    tail -n +"$((A2MARK+1))" $KLOG | grep -n "topology poll answered again" || echo "  (none)"
    echo -n "  count: "; tail -n +"$((A2MARK+1))" $KLOG | grep -c "topology poll answered again"
    echo "  --- the elapsed time the WARN reports (must be ~15s = 3 requests x 5s, not 733s) ---"
    tail -n +"$((A2MARK+1))" $KLOG | grep "topology poll got no answer" | head -2
fi
echo "##### DONE #####"
