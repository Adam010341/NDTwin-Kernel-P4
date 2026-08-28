#!/usr/bin/env bash
# Read htb's OWN drop counters around the burner arm. Directly names the layer that drops,
# instead of inferring it by removing the shaper -- which would also remove a CPU consumer,
# and this round's whole conclusion is that CPU contention is what matters.
# tc -s qdisc is CUMULATIVE, so both a baseline and a final read are required.
set -uo pipefail
O="$(cd "$(dirname "$0")" && pwd)"
host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }
CP=$(host_pid h1); SP=$(host_pid h65)
snap() { sudo -n mnexec -a "$1" tc -s qdisc show dev "$2" 2>/dev/null; }
snap "$CP" h1-eth1  > "$O/h1_before.txt"
snap "$SP" h65-eth1 > "$O/h65_before.txt"
for i in $(seq 1 10); do timeout 110 bash -c 'while :; do :; done' & done
sleep 12
sudo -n mnexec -a "$SP" iperf3 -s -1 --daemon -p 5860 >/dev/null 2>&1
sleep 1
timeout 90 sudo -n mnexec -a "$CP" iperf3 -c 10.0.0.65 -p 5860 -u -b 800M -t 60 -l 1400 --json \
    > "$O/arm.json" 2>&1
snap "$CP" h1-eth1  > "$O/h1_after.txt"
snap "$SP" h65-eth1 > "$O/h65_after.txt"
echo done
