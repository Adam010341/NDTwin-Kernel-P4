#!/usr/bin/env bash
# Ticket F: does merge reduce the proxy's work, measured where the measurement is stable?
# [Co-developed with claude code -- Adam]
#
# WHY 1/16 AND NOT 1/8. Ticket E tried this at 1/8 and could not answer it: the control ran
# 22.01% and 29.49% on the same setting, 7.5 points apart, against a 4.4-point effect. 1/8 sits
# on the cliff, where small differences in headroom become large differences in loss. The same
# fabric at 1/256 gave 0.098% and 0.159% -- two full rebuilds apart, and proxy CPU 11.9 vs 11.6.
# So the instrument is not noisy; the WORKING POINT was. 1/16 is the stable cell with real sample
# volume: lambda 1112, loss 0.025%, proxy 70% against a plateau at ~145%.
#
# WHY FULL REBUILDS RATHER THAN RESTARTING THE PROXY. A proxy-only restart keeps one generation,
# which is what 1/8 needed. Here it buys little -- at a stable working point a full teardown and
# rebuild moved proxy CPU by 0.3 points -- and it costs the one thing that matters when nobody is
# watching: the hand-rolled restart is where ticket E's only failure happened (missing PYTHONPATH,
# wrong interpreter). This reuses gate_e.sh's arm() verbatim instead.
#
# WHAT IS MEASURED. Proxy CPU is the primary readout: merge removes one sendto and one datagram
# per N samples, so if the fixed cost is on the send side this is where it shows, and CPU is far
# steadier than loss. Datagrams/s is the assertion that merge was actually on. Loss should stay
# near zero throughout -- if it does not, the cell is not stable and the run says so.
#
# NOT CLAIMED: any ceiling. The 08-20 round already established that this CPU-vs-rate line must
# not be extrapolated to a saturation point -- its fit overshoots the measured zero by 45 points.
# This measures a difference at one working point, nothing further.
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
LOG="$ROUND/wall_f.log"
OUT="$ROUND/wall_f.out"
PY=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/656b223c-2026-43d1-8b7b-d441a8cd116a/scratchpad/plotvenv/bin/python
DUR="${DUR:-120}"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG" >>"$OUT"; echo "[$(date +%H:%M:%S)] $*"; }

udp_delta() {
    "$PY" - "$1" <<'PY'
import gzip,json,os,sys
c=sys.argv[1]; p=f"/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu/raw/{c}_cpu.jsonl"
p=p if os.path.exists(p) else p+".gz"
op=gzip.open if p.endswith(".gz") else open
r=[json.loads(l) for l in op(p,"rt") if "udp_in" in l]
d=r[-1]['udp_in']-r[0]['udp_in']; s=r[-1]['t']-r[0]['t']
print(f"{d} over {s:.1f}s = {d/s:.1f}/s")
PY
}

proxy_cpu() {
    PYTHONDONTWRITEBYTECODE=1 "$PY" - "$1" <<'PY'
import sys
sys.path.insert(0,"/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu")
from plot_figures import cpu_stats
g=cpu_stats(sys.argv[1])["groups"]
print("proxy=%.1f kernel=%.1f bmv2=%.1f" % (
    sum(v for k,v in g.items() if "proxy" in k),
    sum(v for k,v in g.items() if "kernel" in k),
    sum(v for k,v in g.items() if k.startswith("bmv2"))))
PY
}

compile_at() {   # $1 = SAMPLE_RATE, $2 = SAMPLE_TRUNC_BYTES
    sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = $1;/" "$P4SRC"
    sed -i -E "s/^const bit<32> SAMPLE_TRUNC_BYTES = [0-9]+;/const bit<32> SAMPLE_TRUNC_BYTES = $2;/" "$P4SRC"
    grep -q "SAMPLE_RATE = $1;" "$P4SRC"        || { say "FATAL: rate sed missed"; return 1; }
    grep -q "SAMPLE_TRUNC_BYTES = $2;" "$P4SRC" || { say "FATAL: trunc sed missed"; return 1; }
    p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" \
        --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1 || return 1
    # Assert the injection reached the artefact that will run, not just the source.
    grep -q "\"op\" *: *\"truncate\"" "$P4BUILD/ndtwin_switch.json" \
        || { say "FATAL: truncate op absent from compiled JSON"; return 1; }
}

# stack.sh down deliberately will NOT kill a proxy it did not start -- "the next 'up' would find
# the port open and measure the wrong process, so this is reported rather than ignored". That
# guard is right, and it is what aborted the first attempt at 02:57: the proxy left behind by the
# previous session still held :8081, so `up` refused and the kernel API never appeared. Clearing
# the port is this script's job, not the guard's.
#
# By PID from ss, never `pkill -f`: this file's own command line contains the pattern, and killing
# your own shell that way has happened repeatedly on this machine.
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

bringup() {   # $1 = batch size
    $LAB topo-start >>"$LOG" 2>&1
    for i in $(seq 1 40); do sleep 5; $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break; done
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "ABORT: fabric short of 10"; return 1; }
    env NDTWIN_SFLOW_BATCH="$1" TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0; done
    say "ABORT: kernel API never came up"; return 1
}

arm() {   # $1 = cell, $2 = batch
    say "--- arm $1: NDTWIN_SFLOW_BATCH=$2, rate 1/16 ---"
    teardown; bringup "$2" || exit 1
    say "    kernel sha256 $(sha256sum "$REPO/build/bin/ndtwin_kernel" | cut -d' ' -f1)"
    say "    p4 constants $(grep -E '^const bit<(16|32)> SAMPLE_(RATE|TRUNC_BYTES)' "$P4SRC" | tr '\n' ' ')"
    POLL=on "$PRIOR/measure.sh" "$1" "$DUR" 200 >>"$LOG" 2>&1
    say "    VERDICT $(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" "$1" 2>&1 | tail -1)"
    say "    UDPDGRAM $1 $(udp_delta "$1")"
    say "    CPU $1 $(proxy_cpu "$1")"
}

say "=== wall_f start: 1/16, alternating batch, DUR=${DUR}s ==="
say "SELFTEST $(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" --selftest 2>&1 | tail -1)"
compile_at 16 128 || exit 1
say "compiled at SAMPLE_RATE=16 SAMPLE_TRUNC_BYTES=128"

# Strict alternation. b8 is always second within a pair, so the three b1 cells also give the
# drift baseline directly -- the same trick that decided ticket E.
arm f16b1a_poll 1
arm f16b8a_poll 8
arm f16b1b_poll 1
arm f16b8b_poll 8
arm f16b1c_poll 1
arm f16b8c_poll 8

say "--- restoring production: 1/256, truncate 128, batch unset ---"
teardown
compile_at 256 128 && bringup 1 && say "=== wall_f complete, production restored ===" \
    || say "=== wall_f complete, RESTORE FAILED -- check before releasing lab ==="
