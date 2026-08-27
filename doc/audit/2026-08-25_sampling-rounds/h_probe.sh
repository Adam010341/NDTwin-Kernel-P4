#!/usr/bin/env bash
# Ticket H steps 0-2: what are the emit(363) sleepers actually waiting on?
# Pre-registration: PREREG.md, section "工單 H". [Co-developed with claude code -- Adam]
#
# Ticket G found three hot _stream_receiver threads asleep at sflow_emitter.py:363 in ~14% of
# dumps and I wrote down the wrong reason for it. The Python frame says where the interpreter
# stopped; it cannot say what the OS is waiting for. This reads the two things that can:
# /proc/<tid>/wchan, the kernel function each thread is parked in, and the collector socket's
# own queue and drop counter.
#
# EVERY /proc READ IS DONE TWICE, BEFORE AND AFTER THE DUMP, AND NEVER DURING. py-spy stops the
# process while it samples, so a state read taken during a dump says 't' for every thread and
# would make the step-2 comparison agree with nothing. Reading on both sides also bounds the
# race against py-spy's own view: a thread whose wchan or state moved between the two reads is
# discarded by h_parse.py rather than joined to whichever read suits.
#
# NOTHING HERE PERTURBS THE FABRIC. Steps 0-2 only read /proc. The load arm needs traffic, which
# is why this waits for the lab rather than running alongside someone else's measurement.
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
RAW="$ROUND/raw_h"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
PYSPY=/home/adam/miniconda3/bin/py-spy
LOG="$ROUND/h_probe.log"
OUT="$ROUND/h_probe.out"
ITERS="${ITERS:-90}"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG" >>"$OUT"; echo "[$(date +%H:%M:%S)] $*"; }

# --- reused verbatim from gil_g.sh / wall_f.sh; the hand-rolled variants are where ticket E's
# --- only failure happened, so they are not rewritten.
free_8081() {
    local pid
    pid=$(ss -ltnp 2>/dev/null | grep ":8081" | grep -oE "pid=[0-9]+" | cut -d= -f2 | head -1)
    [ -n "${pid:-}" ] || return 0
    say "    clearing :8081 held by pid $pid"; kill "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do ss -ltnp 2>/dev/null | grep -q ":8081" || return 0; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true; sleep 2
    ss -ltnp 2>/dev/null | grep -q ":8081" && { say "    FATAL: :8081 still held"; return 1; }
    return 0
}
teardown() { "$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
             free_8081 || exit 1
             $LAB topo-stop >>"$LOG" 2>&1 || true
             setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true; sleep 3; }
compile_at() {
    sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $1;/" "$P4SRC"
    sed -i -E "s/^const bit<32> SAMPLE_TRUNC_BYTES = [0-9]+;/const bit<32> SAMPLE_TRUNC_BYTES = $2;/" "$P4SRC"
    grep -q "SAMPLE_RATE = $1;" "$P4SRC" || { say "FATAL: rate sed missed"; return 1; }
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1 || return 1
    grep -q "\"op\" *: *\"truncate\"" "$P4BUILD/ndtwin_switch.json" \
        || { say "FATAL: truncate op absent from compiled JSON"; return 1; }
}
bringup() {
    $LAB topo-start >>"$LOG" 2>&1
    for i in $(seq 1 40); do sleep 5; $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break; done
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "ABORT: fabric short of 10"; return 1; }
    env NDTWIN_SFLOW_BATCH="$1" TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0; done
    say "ABORT: kernel API never came up"; return 1
}
proxy_pid() { ss -ltnp 2>/dev/null | grep ":8081" | grep -oE "pid=[0-9]+" | cut -d= -f2 | head -1; }

snap_wchan() { local p=$1; for t in /proc/"$p"/task/*/wchan; do
                   local tid=${t%/wchan}; tid=${tid##*/}
                   echo "$tid $(cat "$t" 2>/dev/null || echo -)"; done > "$2"; }
# comm can contain spaces, so the state is NOT field 3 by whitespace: a thread named
# "AnyIO worker th" would yield "worker" as its state and h_parse would silently read that as
# "not running". Everything after the LAST ')' is positional, so the state is the first field
# there. This proxy happens to use single-word comms (python / event_engine / lifeguard), which
# is exactly why the bug would have gone unseen until a build that names threads differently.
snap_state() { local p=$1; for t in /proc/"$p"/task/*/stat; do
                   sed -n 's/^\([0-9]*\) .*) \([^ ]*\) .*/\1 \2/p' "$t" 2>/dev/null; done > "$2"; }
# mawk has no strtonum, so the hex port is matched as a string and the queues parsed in python.
snap_udp()   { python3 - "$1" <<'PY'
import sys
out=[]
for l in open("/proc/net/udp").read().splitlines()[1:]:
    r=l.split()
    if r[1].split(':')[1].upper()=="18C7":
        tx,rx=r[4].split(':')
        out.append("6343 %d %s" % (int(rx,16), r[-1]))
open(sys.argv[1],"w").write("\n".join(out)+("\n" if out else ""))
PY
}

arm() {   # $1 = arm name, $2 = pid, $3 = iterations
    local a="$1" pid="$2" n="$3" d="$RAW/$1" i fails=0
    mkdir -p "$d"; rm -f "$d"/it_*
    for i in $(seq 1 "$n"); do
        local s; s=$(printf '%s/it_%04d' "$d" "$i")
        snap_state "$pid" "${s}_state_a.txt"; snap_wchan "$pid" "${s}_wchan_a.txt"
        snap_udp "${s}_udp.txt"
        sudo -n mnexec -a "$pid" "$PYSPY" dump -p "$pid" --json > "${s}_dump.json" 2>>"$LOG" \
            || fails=$((fails+1))
        snap_wchan "$pid" "${s}_wchan_b.txt"; snap_state "$pid" "${s}_state_b.txt"
        sleep 1
    done
    say "    arm $a: $n iterations, $fails dump failures"
}

say "=== h_probe start: ticket H steps 0-2, 1/8 ==="
say "SELFTEST $(PYTHONDONTWRITEBYTECODE=1 python3 "$ROUND/h_parse.py" --selftest 2>&1 | tail -1)"
mkdir -p "$RAW"
compile_at 8 128 || exit 1
say "compiled at SAMPLE_RATE=8 SAMPLE_TRUNC_BYTES=128"
teardown; bringup 1 || exit 1
PID=$(proxy_pid); [ -n "$PID" ] || { say "FATAL: no pid on :8081"; exit 1; }
say "proxy pid $PID  os-threads $(ls /proc/$PID/task | wc -l)"
say "kernel sha256 $(sha256sum "$REPO/build/bin/ndtwin_kernel" | cut -d' ' -f1)"
say "p4 constants $(grep -E '^const bit<(16|32)> SAMPLE_(RATE|TRUNC_BYTES)' "$P4SRC" | tr '\n' ' ')"
# The key is `edges`, not `links`: ticket G asserted d.get("links", []) and a missing field
# turned into a plausible 0. No default here -- a wrong key must raise, not report zero.
say "edges $(curl -s -m 5 http://localhost:8000/ndt/get_graph_data | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["edges"]))' 2>&1 | tail -1)"

say "--- ARM idle-before (control: no traffic, sleepers should be absent) ---"
arm i1 "$PID" 25
say "--- ARM load: 200 Mbit/s UDP ---"
POLL=on "$PRIOR/measure.sh" h8_poll 150 200 >>"$LOG" 2>&1 &
MEAS=$!
sleep 20
arm l "$PID" "$ITERS"
wait $MEAS 2>/dev/null || true
say "--- ARM idle-after (drift baseline) ---"
sleep 10
arm i2 "$PID" 25

say "--- ANALYSIS ---"
for a in i1 l i2; do
    PYTHONDONTWRITEBYTECODE=1 python3 "$ROUND/h_parse.py" "$RAW/$a" 2>&1 | tee -a "$LOG" >>"$OUT"
    PYTHONDONTWRITEBYTECODE=1 python3 "$ROUND/h_parse.py" "$RAW/$a" 2>&1 | tail -40
done

say "--- restoring production: 1/256, truncate 128 ---"
teardown
compile_at 256 128 && bringup 1 && say "=== h_probe complete, production restored ===" \
    || say "=== h_probe complete, RESTORE FAILED -- check before releasing lab ==="
