#!/usr/bin/env bash
# A-1 live recipe: power-off then power-on inside the distrust window must really run the helper.
# Recipe source: doc/audit/2026-08-30_known-issues-wave/11_behavior-evidence.md section 5.1.
#
# Two deviations from the literal recipe text, both forced by the recipe's own wording:
#   * port -- the recipe writes :8081, but /ndt/set_switches_power_state is served by the KERNEL
#     (HttpSession.cpp:182) on :8000; :8081 is the proxy. The verbatim :8081 form is run FIRST
#     and its answer recorded, then the corrected :8000 form.
#   * IP -- the recipe says "whichever switch/IP the topology gives"; s1 is 192.168.123.11.
#
# Verdict is the switch's real state and the bmv2 process count, NOT the return code.
# No pkill/pgrep is used to kill anything (read-only counting only).
# [Co-developed with claude code -- Adam]
set -u
cd /home/adam/Desktop/NDTwin-Kernel
SW=s1
IP=192.168.123.11
K=http://localhost:8000
KLOG=.test_run/logs/kernel.log

count() { pgrep -c simple_switch_grpc 2>/dev/null || echo 0; }

echo "##### A-1 PRE-FLIGHT #####"
echo "switch under test: $SW ($IP)"
echo "baseline simple_switch_grpc count: $(count)"
echo "kernel.log line mark before: $(wc -l < $KLOG)"
KMARK=$(wc -l < $KLOG)

echo
echo "##### A-1 STEP 0: the recipe's VERBATIM port (:8081) -- recorded, expected to be wrong #####"
echo -n "  verbatim :8081 answer: "
curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 \
  -X POST "http://localhost:8081/ndt/set_switches_power_state?action=off&switch_ip=$IP" \
  || echo "(curl failed)"
echo "  (:8081 is the proxy; a 404/000 here is a defect in the RECIPE, not in the fix)"

echo
echo "##### A-1 ARM 1: sleep 3 -- INSIDE the 15s distrust window #####"
BASE=$(count); echo "  count before power-off: $BASE"
echo -n "  power-off answer: "
curl -s --max-time 30 -X POST "$K/ndt/set_switches_power_state?action=off&switch_ip=$IP"; echo
sleep 1
AFTER_OFF=$(count); echo "  count after power-off: $AFTER_OFF  (must be $((BASE-1)))"
echo "  sleeping 3s (inside the old ~10s window)"
sleep 3
echo "  --- power-on, timed ---"
START=$(date +%s.%N)
ON_BODY=$(curl -s --max-time 60 -X POST "$K/ndt/set_switches_power_state?action=on&switch_ip=$IP")
END=$(date +%s.%N)
ELAPSED=$(python3 -c "print(f'{$END-$START:.3f}')")
echo "  power-on answer: $ON_BODY"
echo "  power-on elapsed: ${ELAPSED}s   (PASS ~>=1s = helper really ran; FAIL ~0.01s = early return)"
sleep 2
AFTER_ON=$(count)
echo "  count after power-on: $AFTER_ON  (must be back to baseline $BASE)"
echo
echo "  ARM 1 VERDICT INPUTS: baseline=$BASE after_off=$AFTER_OFF after_on=$AFTER_ON elapsed=${ELAPSED}s"

echo
echo "##### A-1 ARM 2 (the control): sleep 20 -- OUTSIDE the window, must still work #####"
BASE2=$(count); echo "  count before power-off: $BASE2"
echo -n "  power-off answer: "
curl -s --max-time 30 -X POST "$K/ndt/set_switches_power_state?action=off&switch_ip=$IP"; echo
sleep 1
AFTER_OFF2=$(count); echo "  count after power-off: $AFTER_OFF2"
echo "  sleeping 20s (past the 15s window -- graph is trusted again)"
sleep 20
START2=$(date +%s.%N)
ON_BODY2=$(curl -s --max-time 60 -X POST "$K/ndt/set_switches_power_state?action=on&switch_ip=$IP")
END2=$(date +%s.%N)
ELAPSED2=$(python3 -c "print(f'{$END2-$START2:.3f}')")
echo "  power-on answer: $ON_BODY2"
echo "  power-on elapsed: ${ELAPSED2}s"
sleep 2
AFTER_ON2=$(count)
echo "  count after power-on: $AFTER_ON2  (must be back to $BASE2)"
echo "  ARM 2 VERDICT INPUTS: baseline=$BASE2 after_off=$AFTER_OFF2 after_on=$AFTER_ON2 elapsed=${ELAPSED2}s"

echo
echo "##### A-1 ARM 3 (I1+I5): two power-ons inside 15s -- both 200, helper runs ONCE #####"
BASE3=$(count)
K3MARK=$(wc -l < $KLOG)
echo "  count: $BASE3 ; kernel.log mark: $K3MARK"
echo -n "  repeat power-on #1: "
curl -s -o /dev/null -w '%{http_code} ' --max-time 60 -X POST "$K/ndt/set_switches_power_state?action=on&switch_ip=$IP"; echo
echo -n "  repeat power-on #2: "
curl -s -o /dev/null -w '%{http_code} ' --max-time 60 -X POST "$K/ndt/set_switches_power_state?action=on&switch_ip=$IP"; echo
sleep 2
echo "  count after two repeats: $(count)  (must still be $BASE3 -- no second instance)"
echo "  --- kernel.log lines since mark $K3MARK mentioning power/helper ---"
tail -n +"$((K3MARK+1))" $KLOG | grep -iE "power|helper|ndtwin-p4-power" | head -20

echo
echo "##### A-1 kernel.log since pre-flight mark $KMARK (power lines) #####"
tail -n +"$((KMARK+1))" $KLOG | grep -iE "power" | head -40
echo "##### DONE #####"
