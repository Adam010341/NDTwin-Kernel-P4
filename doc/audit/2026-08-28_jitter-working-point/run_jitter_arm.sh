#!/usr/bin/env bash
# One jitter arm: UDP below capacity, machine saturated by NON-network load.
#
# WHY BURNERS. The PREREG wants the link below capacity AND the machine saturated. On bmv2 those
# fight each other -- both are governed by per-packet CPU, so raising traffic to saturate the
# machine is exactly what pushes the link over capacity. CPU burners break the coupling: they
# saturate the host without adding a single packet.
#
# Burner cleanup is in a trap and asserts, because a burner surviving this script poisons every
# later measurement and the next round's load reading would absorb it silently.
# Usage: NDT_OWNER=... run_jitter_arm.sh <per_flow_mbit> <dur_s> <burners> <outdir>
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RATE="${1:?}"; DUR="${2:?}"; NB="${3:?}"; OUT="${4:?}"; mkdir -p "$OUT"
BP=()
cleanup() {
    for p in "${BP[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    sleep 1
    alive=0
    for p in "${BP[@]:-}"; do [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && { alive=$((alive+1)); kill -9 "$p" 2>/dev/null; }; done
    sleep 1
    still=0
    for p in "${BP[@]:-}"; do [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && still=$((still+1)); done
    echo "burners_survived=$still" >> "$OUT/meta"
    (( still > 0 )) && echo "🔴 $still burner(s) SURVIVED -- later measurements contaminated" >&2
}
trap cleanup EXIT
host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }

CL=(); SV=()
for i in $(seq 0 15); do CL+=("h$((1+i*4))"); SV+=("h$((65+i*4))"); done
for i in $(seq 1 "$NB"); do bash -c 'while :; do :; done' & BP+=("$!"); done
echo "burners=${BP[*]}" > "$OUT/meta"
sleep 20
echo "load1_before=$(cut -d' ' -f1 /proc/loadavg)" >> "$OUT/meta"
for i in $(seq 0 15); do
    sp=$(host_pid "${SV[$i]}"); [[ -z "$sp" ]] && { echo "🔴 no ns ${SV[$i]}"; exit 1; }
    sudo -n mnexec -a "$sp" iperf3 -s -1 --daemon -p $((5700 + i)) >/dev/null 2>&1
done
sleep 2
for i in $(seq 0 15); do
    cp=$(host_pid "${CL[$i]}")
    sudo -n mnexec -a "$cp" iperf3 -c "10.0.0.${SV[$i]#h}" -p $((5700 + i)) -u -b "${RATE}M" \
        -t "$DUR" -l 1400 --json > "$OUT/f_${CL[$i]}.json" 2>&1 &
done
sleep $((DUR / 2)); echo "load1_mid=$(cut -d' ' -f1 /proc/loadavg)" >> "$OUT/meta"
wait
echo "load1_after=$(cut -d' ' -f1 /proc/loadavg)" >> "$OUT/meta"
echo "### arm done $(date '+%H:%M:%S')"
