#!/usr/bin/env bash
# Ticket E main measurement: does merge move the wall? 1/8, two arms, ONE fabric generation.
# [Co-developed with claude code -- Adam]
#
# WHY NOT gate_d.sh's SHAPE. That script tears down and rebuilds between arms, so its two arms
# land on different fabric generations -- and mainDev measured a generation to be worth 14.8%,
# which is the same size as the effect this run is looking for. Truncation had no choice (the
# constant is compiled into the P4 program). merge is an env var on the proxy, so it does.
#
# SAMPLE_RATE is a P4 constant, so 1/8 needs one recompile and one rebuild -- but BEFORE both
# arms, once. Between the arms only NDTWIN_SFLOW_BATCH changes, and only the proxy restarts.
#
# 🔴 Restarting the proxy on a warm fabric has a recorded trap: clone replicas stack up and
# telemetry multiplies (trigger is the pipeline commit). It was fixed by the settle pair
# 79e4f69 and demoted to defence in depth -- but it is asserted here anyway, because a silent
# doubling would disguise "merge did nothing" as "merge helped" or the reverse.
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND="$REPO/doc/audit/2026-08-25_sampling-rounds"
PRIOR="$REPO/doc/audit/2026-08-20_sampling-rate-and-cpu"
LAB="sudo -n /usr/local/sbin/ndtwin-lab"
TOPO="$REPO/setting/StaticNetworkTopologyP4_10Switches_128Hosts.json"
P4SRC="$REPO/p4_proxy/p4_src/ndtwin_switch.p4"
P4BUILD="$REPO/p4_proxy/p4_src/build"
LOG="$ROUND/run_e8.log"
PY=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/656b223c-2026-43d1-8b7b-d441a8cd116a/scratchpad/plotvenv/bin/python
DUR="${DUR:-120}"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
edges() { curl -s -m 5 http://localhost:8000/ndt/get_graph_data | "$PY" -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("links",d.get("edges",[]))))' 2>/dev/null || echo -1; }

say "=== run_e8 start: 1/8, two arms, one fabric generation ==="
grep -q "SAMPLE_TRUNC_BYTES = 128;" "$P4SRC" || { say "FATAL: truncate is not 128"; exit 1; }
say "kernel sha256 $(sha256sum "$REPO/build/bin/ndtwin_kernel" | cut -d' ' -f1)"
say "bmv2   sha256 $(sha256sum /usr/local/bmv2-fast/bin/simple_switch_grpc | cut -d' ' -f1)"

sed -i -E "s/^const bit<16> SAMPLE_RATE = [0-9]+;/const bit<16> SAMPLE_RATE = 8;/" "$P4SRC"
grep -q "SAMPLE_RATE = 8;" "$P4SRC" || { say "FATAL: sed missed"; exit 1; }
p4c-bm2-ss --arch v1model -o "$P4BUILD/ndtwin_switch.json" --p4runtime-files "$P4BUILD/ndtwin_switch.p4info.txt" "$P4SRC" >>"$LOG" 2>&1 || exit 1

"$REPO/tools/test_workflow/stack.sh" down >>"$LOG" 2>&1 || true
$LAB topo-stop >>"$LOG" 2>&1 || true
setsid $LAB cleanup </dev/null >>"$LOG" 2>&1 || true
sleep 3
$LAB topo-start >>"$LOG" 2>&1
for i in $(seq 1 40); do sleep 5; $LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" && break; done
$LAB status 2>&1 | tail -1 | grep -q "bmv2: 10" || { say "ABORT: fabric short of 10"; exit 1; }
env NDTWIN_SFLOW_BATCH=1 TOPO_P4="$TOPO" nohup "$REPO/tools/test_workflow/stack.sh" up p4 >>"$LOG" 2>&1 </dev/null &
for i in $(seq 1 40); do sleep 5; curl -s -o /dev/null -m 3 http://localhost:8000/ndt/get_graph_data && break; done
E0=$(edges); say "fabric up, edges=$E0  (this generation serves BOTH arms)"

POLL=on "$PRIOR/measure.sh" e8b1_poll "$DUR" 200 >>"$LOG" 2>&1
say "ARM1 $(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" e8b1_poll 2>&1 | tail -1)"

# --- proxy only, same fabric ---
say "--- restarting PROXY ONLY with NDTWIN_SFLOW_BATCH=8 (fabric untouched) ---"
PPID_=$(cat "$REPO/.test_run/pids/p4_proxy.pid" 2>/dev/null || echo 0)
[ "$PPID_" -gt 0 ] && kill "$PPID_" 2>/dev/null
for i in $(seq 1 20); do sleep 1; ss -tln 2>/dev/null | grep -q ":8081 " || break; done
P4_PROXY_PY=$(grep -oE '/[^ "]*ryu-env[^ "]*/python|/[^ "]*/bin/python[0-9.]*' "$REPO/.test_run/pids/p4_proxy.cmd" 2>/dev/null | head -1)
[ -z "$P4_PROXY_PY" ] && P4_PROXY_PY=/home/adam/miniconda3/envs/ryu-env/bin/python
setsid env NDTWIN_SFLOW_BATCH=8 nohup bash -c "cd '$REPO/p4_proxy' && '$P4_PROXY_PY' proxy_agent/main.py" >>"$LOG" 2>&1 </dev/null &
for i in $(seq 1 30); do sleep 2; ss -tln 2>/dev/null | grep -q ":8081 " && break; done
ss -tln 2>/dev/null | grep -q ":8081 " || { say "ABORT: proxy did not reopen :8081"; exit 1; }
sleep 20
E1=$(edges)
say "proxy restarted, edges=$E1 (was $E0)"
[ "$E1" = "$E0" ] || say "🔴 WARNING: edge count changed $E0 -> $E1 -- telemetry multiplication trap may have fired"

POLL=on "$PRIOR/measure.sh" e8b8_poll "$DUR" 200 >>"$LOG" 2>&1
say "ARM2 $(PYTHONDONTWRITEBYTECODE=1 "$PY" "$ROUND/cell_verdict.py" e8b8_poll 2>&1 | tail -1)"
say "=== run_e8 complete (production restore left to operator) ==="
