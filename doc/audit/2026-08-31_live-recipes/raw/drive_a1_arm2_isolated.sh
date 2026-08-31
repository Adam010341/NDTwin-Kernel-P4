#!/usr/bin/env bash
# A-1 ARM 2 (the sleep-20 control) re-run in ISOLATION with a settling window long enough
# for setPowerStateMininet, which the v2 run showed is asynchronous: it logs "switch s1 -> on"
# in ~1ms and the process appears later. v2's 3s sample was too early, so its "control FAILED"
# verdict was an instrument artifact, not a product failure. Settle = 25s, sampled every 5s.
# [Co-developed with claude code -- Adam]
set -u
cd /home/adam/Desktop/NDTwin-Kernel
IP=192.168.123.11; K=http://localhost:8000
count() { local c=0 f; for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$f" 2>/dev/null | grep -q "simple_switch_grpc" && c=$((c+1)); done; echo "$c"; }
echo "baseline: $(count)"
BASE=$(count)
echo -n "power-off: "; curl -s --max-time 30 -X POST "$K/ndt/set_switches_power_state?action=off&ip=$IP"; echo
for i in 1 2 3; do sleep 2; echo "  t+$((i*2))s after off: $(count)"; done
echo "sleeping 20s (past the 15s distrust window)"; sleep 20
S=$(date +%s.%N)
B=$(curl -s --max-time 60 -X POST "$K/ndt/set_switches_power_state?action=on&ip=$IP")
E=$(date +%s.%N)
echo "power-on answer: $B  elapsed=$(python3 -c "print(f'{$E-$S:.3f}')")s"
echo "--- settle, sampling every 5s up to 25s ---"
for i in 1 2 3 4 5; do sleep 5; echo "  t+$((i*5))s after on: $(count)  (target $BASE)"; done
echo "FINAL: $(count) vs baseline $BASE"
echo "##### DONE #####"
