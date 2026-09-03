#!/usr/bin/env bash
#
# FINDINGS #27 / #76 live measurement, WITHOUT the lab.
#
# [Co-developed with claude code -- Adam]
#
# Two scenarios, one binary argument, N repetitions. Everything runs on loopback: a python fake
# control plane, the real ndtwin_kernel, and nothing else. No `ndt up`, no lab claim, no Mininet,
# no bmv2, no OVS, no sudo. Only PIDs this script started are ever signalled, by number.
#
#   s76  the #76 condition -- :6343/udp is already taken so the sFlow bind fails, and the control
#        plane is wedged. The kernel decides to exit on its own; measured is the time from the line
#        that announces it to the process actually being gone.
#   s27  the #27 condition -- the control plane ANSWERS /v1.0/topology/switches (so the ten
#        switches reach isUp, which is what isPollableForFlowTable requires) and WEDGES
#        /stats/flow/*. Once the flow-table worker is inside a round, SIGINT, and measure to exit.
#
# Usage: measure_stop.sh <s27|s76> <path-to-ndtwin_kernel> <arm-label> <reps> <outdir>
set -uo pipefail

SCENARIO="${1:?s27 or s76}"
KERNEL="${2:?path to ndtwin_kernel}"
ARM="${3:?before|after}"
REPS="${4:-5}"
OUTDIR="${5:?output directory}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The binary is copied out of build/bin so both arms survive a rebuild, so the repo cannot be
# derived from its path. NDT_REPO names it explicitly.
REPO="${NDT_REPO:?set NDT_REPO to the worktree root}"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json"

mkdir -p "$OUTDIR"
[[ -x "$KERNEL" ]] || { echo "no such kernel binary: $KERNEL" >&2; exit 2; }
[[ -f "$TOPO"   ]] || { echo "no such topology: $TOPO" >&2; exit 2; }

SHA=$(sha256sum "$KERNEL" | cut -d' ' -f1)
echo "kernel   $KERNEL"
echo "sha256   $SHA"
echo "topology $TOPO"
echo "scenario $SCENARIO   arm=$ARM   reps=$REPS"
echo "$SHA  $KERNEL" > "$OUTDIR/kernel.sha256"

# --- helpers ------------------------------------------------------------------------------------
# Only ever kills a PID this script recorded. Never pkill, never pgrep.
kill_pid() {
    local pid="$1" sig="${2:-TERM}"
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill "-$sig" "$pid" 2>/dev/null || true
}

wait_gone() {                       # wait_gone <pid> <seconds> -> echoes elapsed seconds
    local pid="$1" limit="$2" t0 now
    t0=$(date +%s.%N)
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s.%N)
        if (( $(echo "$now - $t0 > $limit" | bc -l) )); then
            echo "TIMEOUT"; return 1
        fi
        sleep 0.02
    done
    now=$(date +%s.%N)
    echo "$now - $t0" | bc -l
}

occupy_sflow() {                    # binds :6343/udp so the collector's bind fails
    python3 -c '
import socket, time, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 6343))
sys.stderr.write("sflow-squatter: holding :6343/udp\n"); sys.stderr.flush()
while True: time.sleep(3600)
' >>"$OUTDIR/squatter.log" 2>&1 &
    # 🔴 stdout MUST be redirected, not inherited. This is called as $(occupy_sflow), and a
    # backgrounded child that keeps the command substitution's pipe open makes $( ) block until
    # that child exits -- which is never. The first run of this harness hung here for exactly
    # that reason and recorded no kernel log at all.
    echo $!
}

RESULTS="$OUTDIR/${SCENARIO}_${ARM}.tsv"
printf 'rep\tscenario\tarm\tannounce_to_exit_s\tsignal_to_exit_s\texit_code\tflow_reqs\tnote\n' > "$RESULTS"

for rep in $(seq 1 "$REPS"); do
    RUNDIR="$OUTDIR/${SCENARIO}_${ARM}_rep${rep}"
    mkdir -p "$RUNDIR"

    # 1. the fake control plane
    if [[ "$SCENARIO" == "s76" ]]; then
        CP_ARGS=(--port 8081 --port 8080 --wedge-all)
    else
        CP_ARGS=(--port 8081 --port 8080 --answer-topology 10)
    fi
    python3 "$HERE/fake_control_plane.py" "${CP_ARGS[@]}" > "$RUNDIR/cp.out" 2> "$RUNDIR/cp.err" &
    CP_PID=$!
    sleep 0.6

    SQ_PID=""
    if [[ "$SCENARIO" == "s76" ]]; then
        SQ_PID=$(occupy_sflow)
        sleep 0.4
    fi

    # 2. the kernel. cwd is the build dir so any relative path it still resolves lands in the repo.
    # stdbuf -oL: spdlog's default sink is stdout, and stdout redirected to a FILE is block
    # buffered. The first run of this harness recorded two empty logs for exactly that reason --
    # the kernel had printed the line the measurement keys on, and it was still sitting in a 4 KB
    # buffer when the rep ended. Line buffering is the difference between measuring and guessing.
    ( cd "$REPO/build" && exec stdbuf -oL -eL "$KERNEL" --mode mininet --no-ai --topology "$TOPO" ) \
        > "$RUNDIR/kernel.out" 2> "$RUNDIR/kernel.err" &
    K_PID=$!

    ANNOUNCE_TO_EXIT="-"
    SIGNAL_TO_EXIT="-"
    NOTE=""

    if [[ "$SCENARIO" == "s76" ]]; then
        # The kernel exits by itself. Measure from the moment it says so to the moment it is gone.
        # Both wordings are accepted: trunk prints "Exiting", the fixed branch "Shutting down".
        t_announce=""
        for _ in $(seq 1 400); do        # up to 20 s
            if grep -qE 'cannot start telemetry collection' "$RUNDIR/kernel.out" "$RUNDIR/kernel.err" 2>/dev/null; then
                # The kernel stamps its own lines; keep that too, so the measurement does not
                # depend only on how fast this shell noticed.
                grep -hE 'cannot start telemetry collection' "$RUNDIR/kernel.out" "$RUNDIR/kernel.err" \
                    2>/dev/null | head -1 > "$RUNDIR/announce.line"
                t_announce=$(date +%s.%N); break
            fi
            kill -0 "$K_PID" 2>/dev/null || { NOTE="exited before announcing"; break; }
            sleep 0.05
        done
        if [[ -n "$t_announce" ]]; then
            ELAPSED=$(wait_gone "$K_PID" 60)
            if [[ "$ELAPSED" == "TIMEOUT" ]]; then
                NOTE="still alive 60 s after announcing"; ANNOUNCE_TO_EXIT="60+"
            else
                t_gone=$(date +%s.%N)
                ANNOUNCE_TO_EXIT=$(echo "$t_gone - $t_announce" | bc -l)
            fi
        else
            [[ -z "$NOTE" ]] && NOTE="never announced"
        fi
    else
        # s27: wait until the flow-table worker is demonstrably inside a round -- the fake has been
        # asked for at least one /stats/flow/. Without that the SIGINT could land in the 10 s sleep,
        # where trunk is already fast and the measurement would have no power.
        READY=0
        for _ in $(seq 1 1200); do       # up to 60 s: switches must go up first, then a round starts
            if grep -qc 'WEDGED    /stats/flow/' "$RUNDIR/cp.err" 2>/dev/null; then
                n=$(grep -c 'WEDGED    /stats/flow/' "$RUNDIR/cp.err" 2>/dev/null || echo 0)
                if (( n >= 1 )); then READY=1; break; fi
            fi
            kill -0 "$K_PID" 2>/dev/null || { NOTE="kernel died before polling flow tables"; break; }
            sleep 0.05
        done
        if (( READY == 1 )); then
            sleep 0.3                     # be unambiguously inside the round, not at its edge
            t_sig=$(date +%s.%N)
            kill_pid "$K_PID" INT
            ELAPSED=$(wait_gone "$K_PID" 180)
            if [[ "$ELAPSED" == "TIMEOUT" ]]; then
                NOTE="still alive 180 s after SIGINT"; SIGNAL_TO_EXIT="180+"
            else
                t_gone=$(date +%s.%N)
                SIGNAL_TO_EXIT=$(echo "$t_gone - $t_sig" | bc -l)
            fi
        else
            [[ -z "$NOTE" ]] && NOTE="flow-table poll never reached the fake control plane"
        fi
    fi

    # 3. reap
    kill_pid "$K_PID" KILL
    wait "$K_PID" 2>/dev/null; K_RC=$?
    kill_pid "$CP_PID" KILL; wait "$CP_PID" 2>/dev/null
    [[ -n "$SQ_PID" ]] && { kill_pid "$SQ_PID" KILL; wait "$SQ_PID" 2>/dev/null; }

    FLOW_REQS=$(grep -c 'WEDGED    /stats/flow/' "$RUNDIR/cp.err" 2>/dev/null || echo 0)

    printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rep" "$SCENARIO" "$ARM" "$ANNOUNCE_TO_EXIT" "$SIGNAL_TO_EXIT" "$K_RC" "$FLOW_REQS" "$NOTE" \
        | tee -a "$RESULTS"
    sleep 1
done

echo
echo "=== $SCENARIO / $ARM ==="
cat "$RESULTS"
