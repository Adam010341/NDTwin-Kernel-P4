#!/usr/bin/env bash
# fail_probe.sh -- boot until link discovery fails, then probe the failing fabric LIVE
# (during ndt's own 300s waiter, before anything is torn down).
#
# [Co-developed with claude code -- Adam]
#
# The ×10 (boot_rate.txt) put the failure at 6/10 with this signature: all switches connect,
# /v1.0/topology/links stays empty, walk installs nothing. The discriminator this script
# exists for, per switch, on the LIVE failing fabric:
#   A. LLDP punt rule ABSENT            -> Ryu-side per-switch setup never ran
#   B. rule present, n_packets = 0      -> LLDP not arriving (not sent, or dropped in fabric)
#   C. rule present, n_packets rising   -> LLDP arrives but Switches app discards it
# Healthy baseline (boot 10's fabric, captured 15:2x): rule present, 38 pkts in 150 s.
set -uo pipefail
export NDT_OWNER=review-0824
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; OUT="$DIR/fail_probe.txt"
RYU=http://localhost:8080
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

links_now() { curl -sf --max-time 4 "$RYU/v1.0/topology/links" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "?"; }

say ""
say "# fail probe -- $(date +%H:%M:%S)  commit $(git -C /home/adam/Desktop/NDTwin-Kernel rev-parse --short HEAD)"

for attempt in 1 2 3; do
    ndt down >/dev/null 2>&1; sleep 3
    say "## attempt $attempt: booting"
    setsid ndt up ovs > "$RAW/diag${attempt}_up.out" 2>&1 &
    fail=1
    for t in $(seq 10 5 150); do
        sleep 5
        n=$(links_now)
        if [ "$n" != "?" ] && [ "$n" -ge 30 ] 2>/dev/null; then
            say "   t+${t}s links=$n -> this boot is HEALTHY, not probing"
            fail=0; break
        fi
    done
    if [ "$fail" = 0 ]; then
        sleep 60; ndt down >/dev/null 2>&1   # let it finish quietly, then clear
        continue
    fi

    say "   links still $(links_now) at t+150 -- FAILING BOOT CAUGHT, probing live"
    say "   PROBE is_connected: $(sudo -n ovs-vsctl show 2>/dev/null | grep -c 'is_connected: true')/10"
    lldp_map=""
    for i in $(seq 1 10); do
        line=$(sudo -n mnexec -a 1 ovs-ofctl -O OpenFlow13 dump-flows "s$i" 2>/dev/null | grep -F '0x88cc')
        sudo -n mnexec -a 1 ovs-ofctl -O OpenFlow13 dump-flows "s$i" > "$RAW/diag${attempt}_flows_s${i}.txt" 2>&1
        if [ -z "$line" ]; then lldp_map="$lldp_map s$i:ABSENT"
        else pkts=$(printf '%s' "$line" | grep -oE 'n_packets=[0-9]+' | head -1); lldp_map="$lldp_map s$i:${pkts}"; fi
    done
    say "   PROBE lldp rule map:$lldp_map"
    say "   PROBE ryu switches/ports: $(curl -sf --max-time 4 $RYU/v1.0/topology/switches | python3 -c 'import json,sys; sw=json.load(sys.stdin); print(len(sw), [len(s.get("ports",[])) for s in sw])' 2>/dev/null)"
    sleep 20
    lldp_map2=""
    for i in 1 5 9; do
        line=$(sudo -n mnexec -a 1 ovs-ofctl -O OpenFlow13 dump-flows "s$i" 2>/dev/null | grep -F '0x88cc')
        pkts=$(printf '%s' "$line" | grep -oE 'n_packets=[0-9]+' | head -1)
        lldp_map2="$lldp_map2 s$i:${pkts:-ABSENT}"
    done
    say "   PROBE +20s delta check:$lldp_map2"
    sudo -n ovs-vsctl show > "$RAW/diag${attempt}_ovs_show.txt" 2>&1
    cp -f /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/ryu.log "$RAW/diag${attempt}_ryu.log" 2>/dev/null || true
    say "   probe complete -> raw/diag${attempt}_*"
    break
done
ndt down >/dev/null 2>&1
say "done -> $OUT"
