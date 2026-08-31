#!/usr/bin/env bash
# A-1 live recipe, CORRECTED HARNESS (v2). Recipe source:
# doc/audit/2026-08-30_known-issues-wave/11_behavior-evidence.md section 5.1.
#
# v1 was INVALID and is kept alongside as evidence. Three recipe/harness defects found by it:
#   D1 port      recipe says :8081; /ndt/set_switches_power_state is served by the KERNEL on
#                :8000 (HttpSession.cpp:182). Verbatim :8081 answers 404.
#   D2 parameter recipe says switch_ip=; the kernel wants ip= (tools/contract_test/spec.py:773
#                sends {"ip": ..., "action": ...}). switch_ip= answers
#                {"error":"Missing or invalid ip/action"} -- so the verbatim recipe never
#                powers anything off, and every later assertion is vacuous.
#   D3 counter   recipe's pass criterion is `pgrep -c simple_switch_grpc`. That name is 19
#                chars; pgrep matches comm, truncated to 15, so it returns 0 ALWAYS -- on a
#                fabric with ten live switches. baseline 0 -> after_off 0 -> after_on 0 reads
#                as "count returned to baseline" = PASS for any behaviour whatsoever. The
#                instrument has zero discriminating power. Replaced with a /proc scan.
#
# Verdict is the switch's real state and the bmv2 process count, NOT the return code.
# No pkill/pgrep is used to KILL anything; the /proc scan is read-only.
# [Co-developed with claude code -- Adam]
set -u
cd /home/adam/Desktop/NDTwin-Kernel
IP=192.168.123.11        # s1, from setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
K=http://localhost:8000
KLOG=.test_run/logs/kernel.log

# D3 replacement: count real command lines, not a 15-char-truncated comm.
count() {
    local c=0 f
    for f in /proc/[0-9]*/cmdline; do
        tr '\0' ' ' < "$f" 2>/dev/null | grep -q "simple_switch_grpc" && c=$((c+1))
    done
    echo "$c"
}

echo "##### A-1 PRE-FLIGHT (corrected harness) #####"
echo "switch under test: s1 ($IP)"
echo "instrument cross-check -- recipe's counter vs a working one:"
echo "  pgrep -c simple_switch_grpc : $(pgrep -c simple_switch_grpc 2>/dev/null; true)  <-- recipe's, blind"
echo "  /proc scan                  : $(count)  <-- used below"
KMARK=$(wc -l < $KLOG)
echo "kernel.log mark: $KMARK"

echo
echo "##### A-1 ARM 1: sleep 3 -- INSIDE the 15s distrust window (the defect's window) #####"
BASE=$(count); echo "  count before power-off: $BASE"
echo -n "  power-off answer: "
curl -s --max-time 30 -X POST "$K/ndt/set_switches_power_state?action=off&ip=$IP"; echo
sleep 1
AFTER_OFF=$(count); echo "  count after power-off: $AFTER_OFF  (expect $((BASE-1)))"
echo "  sleeping 3s -- inside the window"
sleep 3
START=$(date +%s.%N)
ON_BODY=$(curl -s --max-time 60 -X POST "$K/ndt/set_switches_power_state?action=on&ip=$IP")
END=$(date +%s.%N)
ELAPSED=$(python3 -c "print(f'{$END-$START:.3f}')")
echo "  power-on answer: $ON_BODY"
echo "  power-on elapsed: ${ELAPSED}s  (PASS: ~>=1s, helper ran; FAIL: ~0.01s, early return)"
sleep 3
AFTER_ON=$(count); echo "  count after power-on: $AFTER_ON  (must be back to $BASE)"
echo "  ARM1: baseline=$BASE after_off=$AFTER_OFF after_on=$AFTER_ON elapsed=${ELAPSED}s"

echo
echo "##### A-1 ARM 2 (control): sleep 20 -- OUTSIDE the window, must still work #####"
BASE2=$(count); echo "  count before power-off: $BASE2"
echo -n "  power-off answer: "
curl -s --max-time 30 -X POST "$K/ndt/set_switches_power_state?action=off&ip=$IP"; echo
sleep 1
AFTER_OFF2=$(count); echo "  count after power-off: $AFTER_OFF2  (expect $((BASE2-1)))"
echo "  sleeping 20s -- past the window, graph is trusted again"
sleep 20
START2=$(date +%s.%N)
ON_BODY2=$(curl -s --max-time 60 -X POST "$K/ndt/set_switches_power_state?action=on&ip=$IP")
END2=$(date +%s.%N)
ELAPSED2=$(python3 -c "print(f'{$END2-$START2:.3f}')")
echo "  power-on answer: $ON_BODY2"
echo "  power-on elapsed: ${ELAPSED2}s"
sleep 3
AFTER_ON2=$(count); echo "  count after power-on: $AFTER_ON2  (must be back to $BASE2)"
echo "  ARM2: baseline=$BASE2 after_off=$AFTER_OFF2 after_on=$AFTER_ON2 elapsed=${ELAPSED2}s"

echo
echo "##### A-1 ARM 3 (I1 + I5): repeat power-on on an ALREADY-UP switch #####"
echo "  I1 = an already-up power-on runs zero commands; I5 = repeat inside window is a no-op"
BASE3=$(count); M3=$(wc -l < $KLOG)
echo "  count: $BASE3 ; kernel.log mark: $M3"
for i in 1 2; do
    S=$(date +%s.%N)
    C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST "$K/ndt/set_switches_power_state?action=on&ip=$IP")
    E=$(date +%s.%N)
    echo "  repeat power-on #$i: HTTP $C in $(python3 -c "print(f'{$E-$S:.3f}')")s"
done
sleep 2
echo "  count after two repeats: $(count)  (must still be $BASE3 -- no second instance started)"

echo
echo "##### kernel.log power/helper lines since mark $KMARK #####"
tail -n +"$((KMARK+1))" $KLOG | grep -iE "power|helper|ndtwin-p4-power|distrust" | head -40
echo "##### DONE #####"
