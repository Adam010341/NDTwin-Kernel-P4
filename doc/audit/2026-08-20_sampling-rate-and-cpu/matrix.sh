#!/usr/bin/env bash
# The 2-factor CPU matrix: sampling rate x twin-polling.
#
# [Co-developed with claude code -- Adam]
#
# Why two factors and not one. The first sweep reported the kernel's CPU as "the cost of
# ingesting sFlow", but that figure also contained the kernel serving this harness's own 4 Hz
# poll of a 128-host / 288-edge graph. With one factor the two are inseparable, and the
# resulting numbers looked strongly sub-linear in sample count -- 0 -> 203 samples/s cost 47
# points of a core while 203 -> 813 cost only 10 more. That is either a real saturation effect
# or an artefact of taking the zero point from a differently-configured run. Adding the
# poll-off arm and two lower sampling rates is what tells those apart.
#
# The sample rate for a poll-off cell is not measurable from its own data -- with no twin
# readings there are no per-window counts to divide by the quantum. It is taken from the
# poll-on cell at the same sampling rate, which is legitimate because the sample rate is a
# property of the traffic and the pipeline, not of whether anyone is watching. cpu_probe also
# records /proc/net/snmp UDP InDatagrams as an independent corroboration.
#
# IMPORTANT: `ndtwin-lab cleanup` runs `mn -c`, which kills broadly enough to take out the
# shell that called it. Every invocation here goes through setsid so it cannot signal this
# script's process group. That is not paranoia -- it has killed a driver mid-run before.
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
LOG="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu/matrix.log"
DUR="${DUR:-300}"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

teardown() {
    "$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
    $LAB topo-stop >>"$LOG" 2>&1 || true
    setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true
    sleep 3
}

bringup() {   # $1 = extra env for stack.sh, may be empty
    $LAB topo-start >>"$LOG" 2>&1
    for i in $(seq 1 40); do
        sleep 5
        if $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10"; then break; fi
    done
    if ! $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10"; then
        say "FATAL: fabric did not reach 10 switches"; return 1
    fi
    env $1 TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 \
        >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do
        sleep 5
        curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0
    done
    say "FATAL: kernel API never came up"; return 1
}

compile_at() {
    sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $1;/" "$P4SRC"
    grep -q "SAMPLE_RATE = $1;" "$P4SRC" || { say "FATAL: sed did not take for rate $1"; return 1; }
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1
}

say "=== matrix start, DUR=${DUR}s per cell ==="

for RATE in 1024 512 256 128 64; do
    say "--- SAMPLE_RATE = 1/$RATE ---"
    teardown
    compile_at "$RATE" || exit 1
    bringup "" || exit 1
    # poll-on first: its twin readings are the only way to recover the true sample rate, and
    # the poll-off cell at the same rate inherits that number.
    POLL=on  "$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh" "m${RATE}_poll"   "$DUR" 200 >>"$LOG" 2>&1
    say "    poll-on done"
    POLL=off "$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh" "m${RATE}_nopoll" "$DUR" 200 >>"$LOG" 2>&1
    say "    poll-off done"
done

# The zero-sampling intercept, on the pipeline already running (1/64). Only the proxy and
# kernel restart; the fabric stays, which keeps this cell's fabric identical to the 1/64 cells
# rather than a fresh one -- the whole point of an intercept is that nothing else moved.
say "--- no clone session (intercept) ---"
"$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
sleep 2
env NDTWIN_CLONE_DISABLE=1 TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 \
    >>"$LOG" 2>&1 </dev/null &
for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && break; done
POLL=on  "$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh" "mnone_poll"   "$DUR" 200 >>"$LOG" 2>&1
say "    poll-on done"
POLL=off "$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh" "mnone_nopoll" "$DUR" 200 >>"$LOG" 2>&1
say "    poll-off done"

say "--- restoring production config (1/256, clone on) ---"
teardown
compile_at 256 || exit 1
bringup "" || exit 1
say "=== matrix complete, production config restored ==="
