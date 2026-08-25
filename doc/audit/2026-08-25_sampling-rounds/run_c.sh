#!/usr/bin/env bash
# Ticket C: the lambda-collapse test. Six cells, two levels, each level reached from opposite
# directions -- low sampling x low load against high sampling x high load.
#
# [Co-developed with claude code -- Adam]
#
# The question is whether precision depends ONLY on lambda, or also on how that lambda was
# obtained. If the three cells of a level agree, one curve replaces the whole 66-cell matrix the
# handoff originally proposed. If they do not, there is a second variable and the matrix earns
# its cost. Both outcomes are decided by the criterion fixed in PREREG 70f2e64 C-1-5, not after
# looking at the numbers.
#
# Truncate stays at 128 (production) throughout -- PREREG C-1-1. Cells are prefixed `q`, which
# no other generation in this raw/ shares.
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
LOG="$ROUND/run_c.log"
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
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "ABORT(7.1): fabric short of 10"; return 1; }
    env TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0; done
    say "ABORT(7.2): kernel API never came up"; return 1
}
compile_at() {
    sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $1;/" "$P4SRC"
    grep -q "SAMPLE_RATE = $1;" "$P4SRC" || { say "FATAL: rate sed missed"; return 1; }
    # C-1-1: truncate must stay at production 128 in EVERY cell. Assert, do not assume -- an
    # earlier arm of gate_d.sh set it to 16384 and only its own restore put it back.
    grep -q "SAMPLE_TRUNC_BYTES = 128;" "$P4SRC" || { say "FATAL: truncate is not 128"; return 1; }
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1 || return 1
    grep -q "\"op\" *: *\"truncate\"" "$P4BUILD/ndtwin_switch.json" \
        || { say "FATAL: truncate op absent from compiled JSON"; return 1; }
}

say "=== run_c start, DUR=${DUR}s/cell, PREREG 760775f ==="
# cell : sampling divisor : offered Mbit/s : level
for SPEC in qa090:32:90:A qa180:64:180:A qa360:128:360:A qb063:8:63:B qb126:16:126:B qb251:32:251:B; do
    IFS=: read -r CELL R M LVL <<<"$SPEC"
    say "--- level $LVL  cell=$CELL  1/$R @ ${M} Mbit/s ---"
    teardown
    compile_at "$R" || exit 1
    bringup || { say "STOPPED before $CELL"; break; }
    POLL=on "$PRIOR/measure.sh" "${CELL}_poll" "$DUR" "$M" >>"$LOG" 2>&1
    V=$(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" "${CELL}_poll" 2>&1 | tail -1)
    say "    VERDICT $LVL $V"
done
say "--- restoring production config (1/256, truncate 128) ---"
teardown
compile_at 256 && bringup && say "=== run_c complete, production restored ===" \
    || say "=== run_c complete, RESTORE FAILED ==="
