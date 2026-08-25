#!/usr/bin/env bash
# Ticket B: extend the sampling ladder above 1/64, up to 1/1. Ticket A rides along.
#
# [Co-developed with claude code -- Adam]
#
# Structure is matrix.sh's, deliberately: same teardown/bringup/compile_at, same measure.sh,
# same 200 Mbit/s single UDP flow, same 300 s cells, so the six new cells are comparable to the
# five already in raw/ without an argument about method. What is new is only:
#
#   * poll-ON only. matrix.sh's poll-off arm exists to separate the harness's own 4 Hz poll from
#     ingest cost. That question is answered; this ladder needs twin readings in every cell, and
#     a poll-off cell has none.
#
#   * cells are r001..r032, NOT m1..m32. `m1*` matches m1024, m128, m16 and m1 -- the handoff
#     warned about exactly this collision and then proposed names that trip it. Zero-padded and
#     mutually exclusive with the m* generation sharing this directory. PREREG §1-bis(4).
#
#   * a verdict after every cell, from cell_verdict.py, which is the pre-registered stop
#     condition and not a judgement made later while looking at the numbers.
#
#   * kernel.log is copied into raw/ per cell. Ticket A cannot be closed without it: the 08-20
#     round archived no kernel.log, so its tid offsets can never be resolved to thread names,
#     and offsets are not stable across builds (trace +13 vs today +11). The log and the cpu
#     trace have to come out of the SAME run or the identification is a guess.
#
# Runs low rate -> high rate (1/32 first). Sampling gets heavier as it goes, so when it breaks,
# every cell already finished is still valid. The reverse order would risk losing the lot.
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
RAW="$PRIOR/raw"
KLOG="$REPO/.test_run/logs/kernel.log"
LOG="$ROUND/ladder_ext.log"
PY=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/656b223c-2026-43d1-8b7b-d441a8cd116a/scratchpad/plotvenv/bin/python
DUR="${DUR:-300}"
OWNER="8/25 sampling"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

teardown() {
    "$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
    $LAB topo-stop >>"$LOG" 2>&1 || true
    # setsid: `ndtwin-lab cleanup` runs `mn -c`, which kills broadly enough to take out the shell
    # that called it. It has killed a driver mid-run before (matrix.sh:20-22).
    setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true
    sleep 3
}

bringup() {
    $LAB topo-start >>"$LOG" 2>&1
    for i in $(seq 1 40); do
        sleep 5
        if $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10"; then break; fi
    done
    if ! $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10"; then
        say "ABORT(§7.1): fabric did not reach 10 switches"; return 1
    fi
    env TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 \
        >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do
        sleep 5
        curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0
    done
    say "ABORT(§7.2): kernel API never came up"; return 1
}

compile_at() {
    sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $1;/" "$P4SRC"
    grep -q "SAMPLE_RATE = $1;" "$P4SRC" || { say "FATAL: sed did not take for rate $1"; return 1; }
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1
}

say "=== ladder_ext start, DUR=${DUR}s/cell, PREREG a7c2bd7 ==="
say "kernel binary sha256: $(sha256sum "$REPO/build/bin/ndtwin_kernel" | cut -d' ' -f1)"
say "bmv2 binary  sha256: $(sha256sum /usr/local/bmv2-fast/bin/simple_switch_grpc | cut -d' ' -f1)"
say "boot_id: $(cat /proc/sys/kernel/random/boot_id)  uptime: $(cut -d' ' -f1 /proc/uptime)s"

# Ticket D re-runs the top of this ladder with truncate(128) on, and needs its own cell names so
# the two generations can sit in one raw/ without a prefix eating the other -- `r0*` would match
# both. Defaults reproduce the original ticket-B run exactly.
RATES="${RATES:-32 16 8 4 2 1}"
PREFIX="${PREFIX:-r}"

CONSEC_SAT=0
for RATE in $RATES; do
    CELL=$(printf "%s%03d_poll" "$PREFIX" "$RATE")
    say "--- SAMPLE_RATE = 1/$RATE  cell=$CELL ---"
    teardown
    compile_at "$RATE" || exit 1
    bringup || { say "STOPPED before $CELL"; break; }

    # Ticket A: the thread-id table and the cpu trace must come from the same boot.
    cp -f "$KLOG" "$RAW/${CELL}_kernel.log" 2>/dev/null \
        && say "    kept kernel.log ($(grep -c 'pid=.* tid=' "$RAW/${CELL}_kernel.log") thread-id lines)" \
        || say "    WARNING: no kernel.log to keep -- ticket A cannot use this cell"

    POLL=on "$PRIOR/measure.sh" "$CELL" "$DUR" 200 >>"$LOG" 2>&1
    V=$(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" "$CELL" 2>&1 | tail -1)
    say "    VERDICT $V"

    case "$V" in
        *SATURATED*) CONSEC_SAT=$((CONSEC_SAT + 1)) ;;
        *NO-DATA*)   say "ABORT(§7.2): cell produced no twin data"; break ;;
        *)           CONSEC_SAT=0 ;;
    esac
    if [ "$CONSEC_SAT" -ge 2 ]; then
        say "STOP(§7.3): two consecutive SATURATED cells -- climbing further only re-measures the same wall"
        break
    fi
done

say "--- restoring production config (1/256) ---"
teardown
compile_at 256 && bringup && say "=== ladder_ext complete, production config restored ===" \
    || say "=== ladder_ext complete, BUT production restore failed -- check before releasing lab ==="
