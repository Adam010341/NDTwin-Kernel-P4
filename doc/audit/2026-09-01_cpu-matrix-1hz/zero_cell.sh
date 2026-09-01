#!/usr/bin/env bash
# The zero-sampling cell, at 1 Hz path recompute -- the one cell the main round failed to get.
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS EXISTS
# matrix_1hz.sh's mzero cells are void. They were brought up with NDTWIN_CLONE_DISABLE=1, and
# that flag has no reader anywhere in the repo (p4_proxy/proxy_agent/main.py:77 names it as this
# repo's most-repeated bug shape), so all six sampled at 1/64 like every other cell. The 08-20
# round had already retracted its own zero for the same reason.
#
# THE MECHANISM, AND WHY THIS ONE INSTEAD
# The clone fires on a random draw hitting zero:
#     random(meta.sample_rand, (bit<16>)0, SAMPLE_RATE - 1);
#     if (meta.sample_rand == 0) { ... clone_preserving_field_list(...) }
# No value of SAMPLE_RATE makes that probability zero -- SAMPLE_RATE=0 underflows the upper
# bound to 65535 and still samples 1 in 65536. So this moves the draw's LOWER BOUND to 1: the
# draw can no longer be 0, the predicate is never true, and the clone never fires. One token,
# no dead code for p4c to warn about, no change to the proxy, and the rest of the pipeline --
# forwarding, counters, packet-in for discovery -- is untouched. That is what "sampling rate
# zero" has to mean here: traffic still flows, nothing is sampled.
#
# Rejected alternatives: deleting the mirror session (the 08-20 retraction shows a DELETE
# against empty P4Runtime bookkeeping is a no-op that leaves the target's PRE group orphaned
# and still cloning), and adding the missing NDTWIN_CLONE_DISABLE reader (a production-code
# change to get a measurement -- wrong order).
#
# 🔴 THE CONTROL IS VERIFIED BEFORE MEASURING, NOT AFTER
# That is the whole lesson of the failed cells. The main round measured 300 s and checked
# afterwards, which can only void data. Here a probe runs first: traffic on, twin polled, and
# the cell is measured ONLY if every edge reads zero while the interface counters say bytes
# really moved. Both halves matter -- "twin reads zero" with no traffic proves nothing.
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
HERE="$REPO/doc/audit/2026-09-01_cpu-matrix-1hz"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
LOG="$HERE/zero_cell.log"
DUR="${DUR:-300}"
REPS="${REPS:-3}"

SAMPLING_ON='random(meta.sample_rand, (bit<16>)0, SAMPLE_RATE - 1);'
SAMPLING_OFF='random(meta.sample_rand, (bit<16>)1, SAMPLE_RATE - 1);'

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

restore_p4() {
    if grep -qF "$SAMPLING_OFF" "$P4SRC"; then
        python3 - "$P4SRC" "$SAMPLING_OFF" "$SAMPLING_ON" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(old) == 1, f"expected exactly one occurrence, found {s.count(old)}"
open(p, "w").write(s.replace(old, new))
PY
        say "  p4 sampling predicate restored"
    fi
}
# Leaving the fabric compiled with sampling disabled would silently zero the telemetry of every
# later round on this machine. This must run whatever happens, including Ctrl-C.
trap 'restore_p4' EXIT INT TERM

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
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "FATAL: fabric short of 10 switches"; return 1; }
    env TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do
        sleep 5
        curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0
    done
    say "FATAL: kernel API never came up"; return 1
}

# --- disable sampling in the pipeline ----------------------------------------------------
say "=== zero-sampling cell, DUR=${DUR}s, REPS=${REPS} ==="
grep -qF "$SAMPLING_ON" "$P4SRC" || { say "FATAL: sampling predicate not in its expected form"; exit 1; }
python3 - "$P4SRC" "$SAMPLING_ON" "$SAMPLING_OFF" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(old) == 1, f"expected exactly one occurrence, found {s.count(old)}"
open(p, "w").write(s.replace(old, new))
PY
grep -qF "$SAMPLING_OFF" "$P4SRC" || { say "FATAL: edit did not take"; exit 1; }
say "  sampling predicate: $(grep -oF "$SAMPLING_OFF" "$P4SRC")"
p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
    --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1 \
    || { say "FATAL: p4c failed"; exit 1; }

KBIN="$REPO/build/bin/ndtwin_kernel"
say "  kernel sha256: $(sha256sum "$KBIN" | cut -d' ' -f1)"
KSYM=$(nm "$KBIN" | awk '/calFlowPathByQueried/ {print $NF}' | head -1)
KR=$(objdump -d --disassemble="$KSYM" "$KBIN" 2>/dev/null | grep -oE 'sleep_forIlSt5ratioILl1ELl[0-9]+EE' | sort -u)
say "  recompute    : $KR"
[[ "$KR" == *"ratioILl1ELl1EE"* ]] || { say "FATAL: not the 1 Hz binary"; exit 1; }

for R in $(seq 1 "$REPS"); do
    SUF=""; [ "$R" -gt 1 ] && SUF="_r$R"
    say "--- replicate $R of $REPS ---"
    teardown
    bringup || exit 1

    # ---- VERIFY THE CONTROL, THEN MEASURE -----------------------------------------------
    say "    verifying: traffic on, telemetry must be zero on every edge"
    if ! python3 "$HERE/verify_zero.py" 30 >>"$LOG" 2>&1; then
        say "    ✗ control did NOT hold -- refusing to measure this replicate"
        say "      (see zero_cell.log; a cell measured now would be another mislabelled zero)"
        exit 1
    fi
    say "    ✓ control holds"

    POLL=on  "$HERE/measure.sh" "mzs_poll${SUF}"   "$DUR" 200 >>"$LOG" 2>&1
    say "    mzs_poll${SUF} done"
    POLL=off "$HERE/measure.sh" "mzs_nopoll${SUF}" "$DUR" 200 >>"$LOG" 2>&1
    say "    mzs_nopoll${SUF} done"
done

say "--- restoring production pipeline ---"
restore_p4
teardown
p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
    --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1
bringup || exit 1
say "  predicate now: $(grep -oF "$SAMPLING_ON" "$P4SRC")"
say "  SAMPLE_RATE  : $(grep -oE 'SAMPLE_RATE = [0-9]+;' "$P4SRC" | head -1)"
say "=== done ==="
