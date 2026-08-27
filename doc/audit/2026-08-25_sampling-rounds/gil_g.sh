#!/usr/bin/env bash
# Ticket G (= Adam's item 2): is the proxy's CPU plateau a GIL ceiling?
# Pre-registration: PREREG.md, section "工單 G". Read it before reading these numbers.
# [Co-developed with claude code -- Adam]
#
# WHY 1/8 AND NOT F's 1/16.  Ticket F deliberately moved OFF 1/8 because the cliff made LOSS
# unmeasurable there.  This measures something else: the proxy's internal thread state, which the
# cliff does not perturb -- a queued thread is queued whether or not the data plane is dropping.
# The auditor asked for 1/8 specifically because that is where the proxy is closest to its
# plateau, and the plateau is the thing under test.
#
# WHY THREE ARMS WITH IDLE ON BOTH SIDES.  I1 is not filler: with no traffic every thread must
# classify as blocked, so it is the known-good input that says whether gil_parse.py's hand-written
# classifier works at all.  I2 is the drift baseline -- ticket E only saw the fabric degrading
# because the control ran AFTER the treatment, and that one placement decided the round.
#
# WHY THE INSTRUMENT MEASURES ITSELF.  py-spy dump pauses the process.  Pausing the suspected
# bottleneck 105 times could produce the queue it is looking for, so proxy CPU is snapshotted at
# four points and the dumped stretch is compared against the two undumped ones on either side.
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
RAW="$ROUND/raw_gil"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
PYSPY=/home/adam/miniconda3/bin/py-spy
LOG="$ROUND/gil_g.log"
OUT="$ROUND/gil_g.out"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG" >>"$OUT"; echo "[$(date +%H:%M:%S)] $*"; }

# --- helpers lifted verbatim from wall_f.sh: the hand-rolled variants are where ticket E's only
# --- failure happened (missing PYTHONPATH, wrong interpreter), so they are not rewritten here.
free_8081() {
    local pid
    pid=$(ss -ltnp 2>/dev/null | grep ":8081" | grep -oE "pid=[0-9]+" | cut -d= -f2 | head -1)
    [ -n "${pid:-}" ] || return 0
    say "    clearing :8081 held by pid $pid"
    kill "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do
        ss -ltnp 2>/dev/null | grep -q ":8081" || return 0
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true; sleep 2
    ss -ltnp 2>/dev/null | grep -q ":8081" && { say "    FATAL: :8081 still held"; return 1; }
    return 0
}

teardown() { "$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
             free_8081 || exit 1
             $LAB topo-stop >>"$LOG" 2>&1 || true
             setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true; sleep 3; }

compile_at() {   # $1 = SAMPLE_RATE, $2 = SAMPLE_TRUNC_BYTES
    sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $1;/" "$P4SRC"
    sed -i -E "s/^const bit<32> SAMPLE_TRUNC_BYTES = [0-9]+;/const bit<32> SAMPLE_TRUNC_BYTES = $2;/" "$P4SRC"
    grep -q "SAMPLE_RATE = $1;" "$P4SRC"        || { say "FATAL: rate sed missed"; return 1; }
    grep -q "SAMPLE_TRUNC_BYTES = $2;" "$P4SRC" || { say "FATAL: trunc sed missed"; return 1; }
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1 || return 1
    grep -q "\"op\" *: *\"truncate\"" "$P4BUILD/ndtwin_switch.json" \
        || { say "FATAL: truncate op absent from compiled JSON"; return 1; }
}

bringup() {   # $1 = batch size
    $LAB topo-start >>"$LOG" 2>&1
    for i in $(seq 1 40); do sleep 5; $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break; done
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "ABORT: fabric short of 10"; return 1; }
    env NDTWIN_SFLOW_BATCH="$1" TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0; done
    say "ABORT: kernel API never came up"; return 1
}

# The proxy pid is read from the socket that defines it, not from a pattern: this file's own
# command line contains "proxy", and `pgrep -f | head -1` returned a stale pid twice in the
# 08-25 round -- head sorts, it does not identify.
proxy_pid() { ss -ltnp 2>/dev/null | grep ":8081" | grep -oE "pid=[0-9]+" | cut -d= -f2 | head -1; }

snap_tasks() {   # $1 = pid, $2 = destination file
    for t in /proc/"$1"/task/*/stat; do cat "$t" 2>/dev/null; done > "$2"
}

# One arm: N dumps at 1 Hz into raw_gil/<arm>/, bracketed by /proc task snapshots.
dump_arm() {   # $1 = arm name, $2 = pid, $3 = number of dumps
    local arm="$1" pid="$2" n="$3" d="$RAW/$1" t0 t1 i fails=0
    mkdir -p "$d"; rm -f "$d"/dump_*.json
    t0=$(date +%s.%N)
    snap_tasks "$pid" "$d/task_start.txt"
    for i in $(seq 1 "$n"); do
        sudo -n mnexec -a "$pid" "$PYSPY" dump -p "$pid" --json \
            > "$d/$(printf 'dump_%04d.json' "$i")" 2>>"$LOG" || fails=$((fails+1))
        sleep 1
    done
    snap_tasks "$pid" "$d/task_end.txt"
    t1=$(date +%s.%N)
    echo "$(echo "$t1 - $t0" | bc) $t0 $t1" > "$d/window.txt"
    say "    arm $arm: $n dumps, $fails failed, window $(cut -d' ' -f1 "$d/window.txt")s"
}

# Proxy CPU% between two task snapshots, using nothing from py-spy.
cpu_between() {   # $1 = start file, $2 = end file, $3 = elapsed seconds
    python3 - "$1" "$2" "$3" <<'PY'
import os,sys
def rd(p):
    o={}
    for l in open(p):
        l=l.strip()
        if not l: continue
        try:
            tid=int(l.split(None,1)[0]); r=l[l.rindex(")")+1:].split()
            o[tid]=int(r[11])+int(r[12])
        except Exception: pass
    return o
a,b=rd(sys.argv[1]),rd(sys.argv[2]); e=float(sys.argv[3])
tck=os.sysconf("SC_CLK_TCK")
print("%.1f" % (sum(b[t]-a[t] for t in b if t in a)/tck/e*100.0))
PY
}

say "=== gil_g start: 1/8, three arms, one fabric generation ==="
say "SELFTEST $(PYTHONDONTWRITEBYTECODE=1 python3 "$ROUND/gil_parse.py" --selftest 2>&1 | tail -1)"
mkdir -p "$RAW"

compile_at 8 128 || exit 1
say "compiled at SAMPLE_RATE=8 SAMPLE_TRUNC_BYTES=128"
teardown
bringup 1 || exit 1

PID=$(proxy_pid)
[ -n "$PID" ] || { say "FATAL: no pid on :8081"; exit 1; }
say "proxy pid $PID  exe $(readlink /proc/$PID/exe)  os-threads $(ls /proc/$PID/task | wc -l)"
say "kernel sha256 $(sha256sum "$REPO/build/bin/ndtwin_kernel" | cut -d' ' -f1)"
say "bmv2   sha256 $(sha256sum /usr/local/bmv2-fast/bin/simple_switch_grpc | cut -d' ' -f1)"
say "emitter sha256 5bdf97ebe32e0a57a2ced00f926447f2986ff9252f2832b2b9ae99bcf0ef582e (mainDev uncommitted, +84/-3, mtime 08-25 14:48 = pre-F)"
say "p4 constants $(grep -E '^const bit<(16|32)> SAMPLE_(RATE|TRUNC_BYTES)' "$P4SRC" | tr '\n' ' ')"
say "edges $(curl -s -m 5 http://localhost:8000/ndt/get_graph_data | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("links",[])))' 2>/dev/null)"

# ---- arm I1: idle, same generation. Known-good input for the classifier. ----
say "--- ARM I1: idle, no traffic ---"
dump_arm i1 "$PID" 40

# ---- arm L: 200 Mbit/s UDP for 150 s; dumps cover the middle 105 s ----
say "--- ARM L: 200 Mbit/s UDP, dumps over the middle ---"
POLL=on "$PRIOR/measure.sh" g8gil_poll 150 200 >>"$LOG" 2>&1 &
MEAS=$!
sleep 10
snap_tasks "$PID" "$RAW/p0.txt"; T0=$(date +%s.%N)
sleep 15
snap_tasks "$PID" "$RAW/p1.txt"; T1=$(date +%s.%N)
dump_arm l "$PID" 105
snap_tasks "$PID" "$RAW/p2.txt"; T2=$(date +%s.%N)
sleep 15
snap_tasks "$PID" "$RAW/p3.txt"; T3=$(date +%s.%N)
wait $MEAS 2>/dev/null || true

say "    PERTURBATION pre-dump  $(cpu_between "$RAW/p0.txt" "$RAW/p1.txt" "$(echo "$T1-$T0"|bc)")%"
say "    PERTURBATION dumped    $(cpu_between "$RAW/p1.txt" "$RAW/p2.txt" "$(echo "$T2-$T1"|bc)")%"
say "    PERTURBATION post-dump $(cpu_between "$RAW/p2.txt" "$RAW/p3.txt" "$(echo "$T3-$T2"|bc)")%"

# ---- arm I2: idle again, same generation, same pid. Drift baseline. ----
say "--- ARM I2: idle again (drift baseline) ---"
sleep 10
NOW=$(proxy_pid)
[ "$NOW" = "$PID" ] || say "    !! proxy pid changed $PID -> $NOW: the three arms are NOT one process"
dump_arm i2 "$PID" 40

say "--- ANALYSIS ---"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROUND/gil_parse.py" "$RAW" i1 l i2 2>&1 | tee -a "$LOG" >>"$OUT"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROUND/gil_parse.py" "$RAW" i1 l i2 2>&1 | tail -80

say "--- restoring production: 1/256, truncate 128, batch unset ---"
teardown
compile_at 256 128 && bringup 1 && say "=== gil_g complete, production restored ===" \
    || say "=== gil_g complete, RESTORE FAILED -- check before releasing lab ==="
