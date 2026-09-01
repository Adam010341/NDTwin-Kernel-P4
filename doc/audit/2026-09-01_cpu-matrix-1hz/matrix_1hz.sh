#!/usr/bin/env bash
# The 2-factor CPU matrix, re-run with calFlowPathByQueried at 1 Hz.
#
# [Co-developed with claude code -- Adam]
#
# Adapted from doc/audit/2026-08-20_sampling-rate-and-cpu/matrix.sh. That round measured the
# same cells while the path-recompute thread slept 1 ms per iteration; ticket M (2f57ba56,
# 2026-08-27) changed it to 1 s. Same cells, same durations, same driver, so the two
# decompositions can be put side by side.
#
# 🔴 WHAT THE COMPARISON CAN AND CANNOT SAY (Adam's ruling, 2026-09-01)
# The 08-20 numbers came from a kernel twelve days older -- ticket Q's in-loop divisor
# instrument and today's B-2(1)/E-2 fixes are all in between. Adam chose the side-by-side
# anyway, over building a one-constant-apart binary for a paired A/B. So the difference
# between the two rounds is "the difference between the two rounds", NOT "the effect of the
# recompute change". Any figure or sentence that says otherwise is wrong.
#
# WHAT IS NEW HERE relative to matrix.sh
# The cold-fabric zero (mzero, n=3) was run by hand in the 08-20 round -- matrix.log has no
# trace of it and no script produced it. It is scripted here, because it is the cell where a
# change to a fixed per-iteration cost should show most cleanly: at idle there is no ingest
# work for it to hide behind.
#
# IMPORTANT: `ndtwin-lab cleanup` runs `mn -c`, which kills broadly enough to take out the
# shell that called it. Every invocation goes through setsid so it cannot signal this script's
# process group. That is not paranoia -- it has killed a driver mid-run before.
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
HERE="$REPO/doc/audit/2026-09-01_cpu-matrix-1hz"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
LOG="$HERE/matrix_1hz.log"
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

cell() {  # $1 = label, $2 = poll on|off
    POLL="$2" "$HERE/measure.sh" "$1" "$DUR" 200 >>"$LOG" 2>&1
    say "    $1 done"
}

# ---------------------------------------------------------------------------------------
# Identify the binary before measuring anything. stack.sh:760 only checks that the kernel
# binary EXISTS -- it never rebuilds -- so "the tree says 1 Hz" says nothing about what is
# about to run. The discriminator is the sleep_for template instantiation: seconds is
# ratio<1,1>, microseconds is ratio<1,1000000>. Verified against archived binaries to print
# BOTH answers before being trusted (3367d0e9 and ab2d7ed1 read 1 kHz, a40e04ce reads 1 Hz).
# ---------------------------------------------------------------------------------------
say "=== binary identification ==="
KBIN="$REPO/build/bin/ndtwin_kernel"
KSHA=$(sha256sum "$KBIN" | cut -d' ' -f1)
KSYM=$(nm "$KBIN" | awk '/calFlowPathByQueried/ {print $NF}' | head -1)
KRATIO=$(objdump -d --disassemble="$KSYM" "$KBIN" 2>/dev/null \
         | grep -oE 'sleep_forIlSt5ratioILl1ELl[0-9]+EE' | sort -u | tr '\n' ' ')
say "  kernel   : $KBIN"
say "  sha256   : $KSHA"
say "  recompute: $KRATIO"
case "$KRATIO" in
    *ratioILl1ELl1EE*) say "  => 1 Hz confirmed" ;;
    *) say "FATAL: this binary is not the 1 Hz build -- refusing to label the round 1 Hz"; exit 1 ;;
esac
say "  p4 SAMPLE_RATE at start: $(grep -oE 'SAMPLE_RATE = [0-9]+' "$P4SRC")"

say "=== matrix start, DUR=${DUR}s per cell ==="

for RATE in 1024 512 256 128 64; do
    say "--- SAMPLE_RATE = 1/$RATE ---"
    teardown
    compile_at "$RATE" || exit 1
    bringup "" || exit 1
    # poll-on first: its twin readings are the only way to recover the true sample rate, and
    # the poll-off cell at the same rate inherits that number.
    cell "m${RATE}_poll"   on
    cell "m${RATE}_nopoll" off
done

# The zero-sampling intercept on the pipeline already running (1/64). Only the proxy and
# kernel restart; the fabric stays, which keeps this cell's fabric identical to the 1/64 cells
# rather than a fresh one -- the whole point of an intercept is that nothing else moved.
say "--- no clone session, warm fabric (mnone) ---"
"$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
sleep 2
env NDTWIN_CLONE_DISABLE=1 TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 \
    >>"$LOG" 2>&1 </dev/null &
for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && break; done
cell "mnone_poll"   on
cell "mnone_nopoll" off

# The cold-fabric zero, n=3. Distinct from mnone: the fabric is torn down and rebuilt each
# time, so this is the intercept with nothing warm left over. The 08-20 round took its
# headline zero (2.89%, sd 0.03) from these three, and it is the number the whole
# decomposition subtracts, so it is replicated rather than measured once.
#
# 🔴 This MUST go through bringup(), not through a bare `stack.sh up`. The first draft of this
# script inlined only the stack.sh half, which drops `$LAB topo-start` -- that would have
# measured a kernel with NO FABRIC AT ALL and called it the cold-fabric zero. Those are
# different numbers: the kernel holds a 288-edge graph and runs its periodic work against it
# either way. Caught 2 minutes into the first launch by re-reading the block against
# bringup(); the round was restarted rather than patched around.
for R in 1 2 3; do
    say "--- cold-fabric zero, replicate $R of 3 ---"
    teardown
    bringup "NDTWIN_CLONE_DISABLE=1" || exit 1
    SUF=""; [ "$R" -gt 1 ] && SUF="_r$R"
    cell "mzero_poll${SUF}"   on
    cell "mzero_nopoll${SUF}" off
done

# Leaving the fabric compiled at 1/64 would silently change what every later round measures.
# The 08-20 round restored 1/256 for the same reason; this is not tidy-up, it is the
# instrument being put back.
say "--- restoring production config (1/256, clone on) ---"
teardown
compile_at 256 || exit 1
bringup "" || exit 1
say "  p4 SAMPLE_RATE at end: $(grep -oE 'SAMPLE_RATE = [0-9]+' "$P4SRC")"
say "=== matrix complete, production config restored ==="
