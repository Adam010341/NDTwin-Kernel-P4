#!/usr/bin/env bash
# Ticket C control: how much of the six-cell disagreement is a fabric rebuild?
#
# [Co-developed with claude code -- Adam]
#
# The review ruled the main criterion INCONCLUSIVE, and it was right for a sharper reason than
# the one I gave: "every pair exceeds 0.1" rests on ONE pair that clears it by 0.040 (level A,
# 1.005 vs 1.145 = 0.140). Estimation noise is known (+-0.44 in spread's own units, within one
# trace); BETWEEN-CELL condition noise has no number at all.
#
# 🔴 THE REBUILD IS THE VARIABLE, NOT THE REPEAT. Running the same cell twice on the SAME fabric
# measures estimation noise -- already in hand, and nothing is learned. The six cells were each
# preceded by a full teardown and rebuild, so that is what has to sit between the two runs here.
# Same parameters, same sampling rate, same offered load, same truncate constant; one rebuild.
#
# Pre-registered reading (fixed before the run):
#   |delta| <  0.1   -> between-cell variation is below the criterion  -> main criterion CONFIRMED
#   |delta| >= 0.1   -> the criterion cannot separate cells            -> conclusion WITHDRAWN
#   |delta| >= 0.140 -> it alone accounts for level A's marginal pair  -> worse than withdrawn
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
LOG="$ROUND/ctl_c.log"
PY=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/656b223c-2026-43d1-8b7b-d441a8cd116a/scratchpad/plotvenv/bin/python
DUR="${DUR:-300}"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

teardown() {
    "$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
    $LAB topo-stop >>"$LOG" 2>&1 || true
    setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true
    sleep 3
}
bringup() {
    $LAB topo-start >>"$LOG" 2>&1
    for i in $(seq 1 40); do sleep 5; $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break; done
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "ABORT: fabric short of 10"; return 1; }
    env TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0; done
    say "ABORT: kernel API never came up"; return 1
}
compile_at() {
    sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $1;/" "$P4SRC"
    grep -q "SAMPLE_RATE = $1;" "$P4SRC" || { say "FATAL: rate sed missed"; return 1; }
    grep -q "SAMPLE_TRUNC_BYTES = 128;" "$P4SRC" || { say "FATAL: truncate is not 128"; return 1; }
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1
}
arm() {   # $1 = cell label
    teardown
    compile_at 32 || exit 1
    bringup || exit 1
    # The kernel PID identifies the boot, which is how mainDev proved two of their conditions
    # never crossed a rebuild. Recorded here so this control can be audited the same way.
    say "    $1 kernel pid=$(pgrep -f 'ndtwin_kernel' | head -1)"
    POLL=on "$PRIOR/measure.sh" "$1" "$DUR" 90 >>"$LOG" 2>&1
    say "    VERDICT $(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" "$1" 2>&1 | tail -1)"
}

say "=== ctl_c start: qa090 params (1/32 @ 90 Mbit/s), twice, one rebuild between ==="
arm zc090a_poll
say "--- REBUILD between the two runs (this is the variable under test) ---"
arm zc090b_poll
say "--- restoring production config (1/256) ---"
teardown
compile_at 256 && bringup && say "=== ctl_c complete, production restored ===" \
    || say "=== ctl_c complete, RESTORE FAILED ==="
