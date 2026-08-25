#!/usr/bin/env bash
# PREREG §D-2 gate: prove truncate() actually truncates, and prove it did not kill telemetry.
#
# [Co-developed with claude code -- Adam]
#
# WHY AN A/B AND NOT A SINGLE CELL. "It compiled in" is exactly what the 08-20 runtime knob also
# did before it silently zeroed every edge. The gate therefore runs the SAME cell twice at 1/256,
# changing only SAMPLE_TRUNC_BYTES -- 16384 (larger than any frame, so truncate() is a no-op) vs
# 128 -- and compares bytes carried on the bmv2 -> proxy gRPC stream. Same code path, one number
# different, so a difference cannot be anything else.
#
# WHY THE gRPC SOCKET AND NOT A veth. CPU_PORT 255 on simple_switch_grpc is not attached to an
# interface; sampled copies travel inside the P4Runtime StreamChannel. So the bytes are counted
# where they actually flow, on the loopback socket bmv2 serves.
#
# The emitter's own max_header_bytes is already 128, so the sFlow datagram on the wire looks the
# same either way -- measuring THERE would prove nothing. This measures upstream of it.
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
LOG="$ROUND/gate_d.log"
PY=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/656b223c-2026-43d1-8b7b-d441a8cd116a/scratchpad/plotvenv/bin/python
DUR="${DUR:-120}"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# Bytes the PROXY has read off the ten P4Runtime streams.
#
# The first version of this filter used sport 9559-9600 and bytes_sent, guessing bmv2's default
# gRPC port. It returned 0 against a live ten-switch fabric -- and 0 is indistinguishable from
# "telemetry is dead", which is the exact reading this gate exists to make. Checking the reader
# against a known-non-empty input BEFORE the run is what caught it: the ports are 50053-50062,
# and the proxy dials them over IPv6 loopback, so a sport filter never matches.
# Verified: 6 s delta of 56,805 B on an idle fabric.
grpc_bytes() {
    ss -tin state established "( dport >= :50053 and dport <= :50062 )" 2>/dev/null \
      | tr '\n' ' ' | grep -oE "bytes_received:[0-9]+" | cut -d: -f2 \
      | awk '{s+=$1} END {print s+0}'
}

teardown() {
    "$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
    $LAB topo-stop >>"$LOG" 2>&1 || true
    setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true
    sleep 3
}

bringup() {
    $LAB topo-start >>"$LOG" 2>&1
    for i in $(seq 1 40); do
        sleep 5
        $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break
    done
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "ABORT: fabric short of 10"; return 1; }
    env TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do
        sleep 5
        curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0
    done
    say "ABORT: kernel API never came up"; return 1
}

compile_at() {   # $1 = SAMPLE_RATE, $2 = SAMPLE_TRUNC_BYTES
    sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $1;/" "$P4SRC"
    sed -i -E "s/^const bit<32> SAMPLE_TRUNC_BYTES = [0-9]+;/const bit<32> SAMPLE_TRUNC_BYTES = $2;/" "$P4SRC"
    grep -q "SAMPLE_RATE = $1;" "$P4SRC"        || { say "FATAL: rate sed missed"; return 1; }
    grep -q "SAMPLE_TRUNC_BYTES = $2;" "$P4SRC" || { say "FATAL: trunc sed missed"; return 1; }
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1 || return 1
    # Assert the injection landed in the artefact that will actually run, not just in the source.
    grep -q "\"op\" *: *\"truncate\"" "$P4BUILD/ndtwin_switch.json" \
        || { say "FATAL: truncate op absent from compiled JSON"; return 1; }
}

arm() {   # $1 = label, $2 = trunc bytes
    say "--- arm $1: SAMPLE_TRUNC_BYTES=$2, rate 1/256 ---"
    teardown
    compile_at 256 "$2" || exit 1
    bringup || exit 1
    B0=$(grpc_bytes)
    # Known-non-empty check: a counter that reads 0 while ten switches are streaming is a broken
    # reader, not a quiet fabric, and must not be reported as "no bytes".
    [ "${B0:-0}" -gt 0 ] || say "    WARNING: grpc_bytes reads 0 at start -- reader may be broken"
    POLL=on "$PRIOR/measure.sh" "$1" "$DUR" 200 >>"$LOG" 2>&1
    B1=$(grpc_bytes)
    V=$(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" "$1" 2>&1 | tail -1)
    say "    VERDICT $V"
    say "    GRPCBYTES $1 delta=$((B1 - B0)) start=$B0 end=$B1"
}

say "=== gate_d start, DUR=${DUR}s per arm, PREREG f64897b §D-2 ==="
arm d256full_poll 16384
arm d256trunc_poll 128

say "--- restoring production config (1/256, truncate 128) ---"
teardown
compile_at 256 128 && bringup && say "=== gate_d complete, production restored ===" \
    || say "=== gate_d complete, RESTORE FAILED -- check before releasing lab ==="
