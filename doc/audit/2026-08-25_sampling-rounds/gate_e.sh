#!/usr/bin/env bash
# Ticket E gate: does merge actually merge, and does it break telemetry?
# [Co-developed with claude code -- Adam]
#
# Same cell at 1/256 twice, differing only in NDTWIN_SFLOW_BATCH (1 vs 8). Three checks, all
# three implemented HERE -- ticket D listed three in the pre-registration and gate_d.sh called
# two, which the review found by grep. The rule earned that day: as many checks as the
# pre-registration names, that many calls in the script.
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
LOG="$ROUND/gate_e.log"
PY=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/656b223c-2026-43d1-8b7b-d441a8cd116a/scratchpad/plotvenv/bin/python
DUR="${DUR:-120}"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# Datagrams proxy -> kernel. Already collected by cpu_probe as udp_in (/proc/net/snmp), and
# already validated against cells on disk BEFORE this ran: 208.0/s at 1/256 and 1668.5/s at
# 1/32, a ratio of 8.02 for an 8x sampling change. D's first byte counter returned 0 against a
# live fabric and 0 was the reading the gate existed to make; this one was checked first.
udp_delta() {   # $1 = cell
    "$PY" - "$1" <<'PY'
import gzip,json,os,sys
c=sys.argv[1]; p=f"/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-08-20_sampling-rate-and-cpu/raw/{c}_cpu.jsonl"
p=p if os.path.exists(p) else p+".gz"
op=gzip.open if p.endswith(".gz") else open
r=[json.loads(l) for l in op(p,"rt") if "udp_in" in l]
print(f"{r[-1]['udp_in']-r[0]['udp_in']} over {r[-1]['t']-r[0]['t']:.1f}s = {(r[-1]['udp_in']-r[0]['udp_in'])/(r[-1]['t']-r[0]['t']):.1f}/s")
PY
}
teardown() { "$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true; $LAB topo-stop >>"$LOG" 2>&1 || true; setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true; sleep 3; }
bringup() {   # $1 = batch size
    $LAB topo-start >>"$LOG" 2>&1
    for i in $(seq 1 40); do sleep 5; $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break; done
    $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "ABORT: fabric short of 10"; return 1; }
    env NDTWIN_SFLOW_BATCH="$1" TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
    for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && return 0; done
    say "ABORT: kernel API never came up"; return 1
}
arm() {   # $1 = cell, $2 = batch
    say "--- arm $1: NDTWIN_SFLOW_BATCH=$2 ---"
    teardown; bringup "$2" || exit 1
    say "    kernel sha256(on disk) $(sha256sum "$REPO/build/bin/ndtwin_kernel" | cut -d' ' -f1)"
    POLL=on "$PRIOR/measure.sh" "$1" "$DUR" 200 >>"$LOG" 2>&1
    say "    VERDICT $(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" "$1" 2>&1 | tail -1)"
    say "    UDPDGRAM $1 $(udp_delta "$1")"
}
say "=== gate_e start (BRIEF-E E-2) ==="
# Check 3 of 3, called rather than merely registered.
say "SELFTEST $(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" --selftest 2>&1 | tail -1)"
arm e256b1_poll 1
arm e256b8_poll 8
say "--- restoring production (batch unset) ---"
teardown; bringup 1 && say "=== gate_e complete ===" || say "=== gate_e complete, RESTORE FAILED ==="
