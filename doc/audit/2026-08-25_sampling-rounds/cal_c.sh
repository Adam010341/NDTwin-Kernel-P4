#!/usr/bin/env bash
# PREREG §C-1-6: which offered rates does a single UDP flow actually reach on this fabric?
#
# [Co-developed with claude code -- Adam]
#
# Ticket C pairs cells by lambda, and lambda = sampling_rate x packet_rate. If an offered rate is
# not actually delivered, the cell's lambda is not what the design says and the pairing is broken
# -- so the rates get checked BEFORE the six cells are fixed, not after. 200 Mbit/s is the only
# one known to work (gt ~205 on every cell this round); everything else here is untested.
#
# One fabric, one sampling rate (1/256, production, truncate 128). Only the offered load varies,
# so no recompile between steps and no teardown -- which also means every step sees the same
# fabric, the way a calibration should.
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
LOG="$ROUND/cal_c.log"
PY=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/656b223c-2026-43d1-8b7b-d441a8cd116a/scratchpad/plotvenv/bin/python
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

say "=== cal_c start (PREREG 70f2e64 C-1-6) ==="
say "truncate constant in source: $(grep -oE 'SAMPLE_TRUNC_BYTES = [0-9]+' "$REPO/p4_proxy/p4_src/ndtwin_switch.p4")"
"$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
$LAB topo-stop >>"$LOG" 2>&1 || true
setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true
sleep 3
$LAB topo-start >>"$LOG" 2>&1
for i in $(seq 1 40); do sleep 5; $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break; done
$LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "ABORT: fabric short of 10"; exit 1; }
env TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 "http://localhost:8000/ndt/get_graph_data" && break; done

for M in 63 90 126 180 251 360 502; do
    CELL=$(printf "cal%03d_poll" "$M")
    POLL=on "$PRIOR/measure.sh" "$CELL" 20 "$M" >>"$LOG" 2>&1
    V=$(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" "$CELL" 2>&1 | tail -1)
    say "    CAL offered=${M} $V"
done
say "=== cal_c complete ==="
