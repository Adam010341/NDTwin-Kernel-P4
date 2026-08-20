#!/usr/bin/env bash
# One measurement condition: fixed-rate UDP across the fabric while sampling the twin, the
# interface counters and per-process CPU together.
#
# Usage:  measure.sh <label> <seconds> <rate-mbit>
#
# [Co-developed with claude code -- Adam]
#
# The three probes run concurrently and on independent cadences, which is deliberate: the twin
# poll and the CPU poll each have their own cost, and interleaving them into one loop would make
# every twin sample wait on a /proc scan of ~140 processes. Their timestamps are what line them
# up afterwards, not their ordering.
#
# Traffic is UDP, not TCP: a TCP flow's rate is decided by congestion control reacting to the
# fabric, so "offered 200 Mbit/s" would stop being a fixed input the moment anything else
# changed. Ground truth still comes from the interface counters either way -- the offered rate
# is never trusted as the answer -- but a fixed input keeps the three conditions comparable.
set -u

LABEL="$1"
DUR="${2:-300}"
RATE="${3:-200}"

REPO=/home/adam/Desktop/NDTwin-Kernel
OUT="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu/raw"
mkdir -p "$OUT"

host_pid() {
    # mininet host processes are named "mininet:<host>"; $NF avoids matching a host whose name
    # is a prefix of another ("h1" vs "h12"), which a substring grep would do.
    ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'
}

H1=$(host_pid h1)
H33=$(host_pid h33)
if [ -z "$H1" ] || [ -z "$H33" ]; then
    echo "FATAL: could not find host pids (h1='$H1' h33='$H33'). Is the fabric up?" >&2
    exit 1
fi
echo "[$LABEL] h1=$H1 h33=$H33  ${RATE}Mbit/s for ${DUR}s"

# A stale server from a previous condition would accept the flow and silently make this run
# measure the wrong thing, so clear first. Hosts share the root PID namespace, which is why a
# plain pkill reaches them at all.
sudo -n mnexec -a "$H33" pkill -f iperf3 2>/dev/null || true
sudo -n mnexec -a "$H1" pkill -f iperf3 2>/dev/null || true
sleep 1

sudo -n mnexec -a "$H33" iperf3 -s -1 --daemon --logfile "$OUT/${LABEL}_server.log" 2>/dev/null
sleep 1

python3 "$REPO/tools/test_workflow/cpu_probe.py" "$DUR" 2 "$OUT/${LABEL}_cpu.jsonl" &
CPU_PID=$!
# POLL=off drops the 4 Hz /ndt/get_graph_data poll. That HTTP work is served BY the kernel
# process whose CPU is being measured, and on a 128-host / 288-edge graph it is not small --
# so with it on, "cost of ingesting sFlow" is really "that plus serving my own instrument".
# Ground truth comes from /proc/net/dev either way and needs nothing from the kernel.
if [ "${POLL:-on}" = "off" ]; then
    python3 "$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu/netdev_only.py" \
        "$DUR" 4 "$OUT/${LABEL}_twin.jsonl" &
else
    python3 "$REPO/doc/audit/2026-08-18_live-full-stack-round/run.py" \
        "$DUR" 4 "$OUT/${LABEL}_twin.jsonl" &
fi
TWIN_PID=$!

sleep 2
# --json emits a per-second intervals[] array -- 300 entries, ~6,700 lines -- that nothing in
# this directory reads; every analysis takes end.sum and stops. Piping it through jq to keep
# just that block turns a 6.7k-line file into ~15 lines. Without jq the full output is kept, so
# a machine missing it degrades to verbose rather than to no data.
if command -v jq >/dev/null 2>&1; then
    sudo -n mnexec -a "$H1" iperf3 -c 10.0.0.33 -u -b "${RATE}M" -t "$DUR" -l 1400 --json 2>&1 \
        | jq '{end: {sum: .end.sum}, start: {test_start: .start.test_start}}' \
        > "$OUT/${LABEL}_client.json" &
else
    sudo -n mnexec -a "$H1" iperf3 -c 10.0.0.33 -u -b "${RATE}M" -t "$DUR" -l 1400 \
        --json > "$OUT/${LABEL}_client.json" 2>&1 &
fi
IPERF_PID=$!

wait $CPU_PID $TWIN_PID 2>/dev/null
wait $IPERF_PID 2>/dev/null || true
sudo -n mnexec -a "$H33" pkill -f iperf3 2>/dev/null || true

echo "[$LABEL] done -> $OUT/${LABEL}_{cpu,twin}.jsonl, ${LABEL}_client.json"
