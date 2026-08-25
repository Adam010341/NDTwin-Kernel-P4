#!/usr/bin/env bash
# One measurement run on whichever plane is currently up.
#
# Order matters and is pre-registered: pollers first so the window has margin on both sides,
# flows second, and the reconciliation window is the flat middle -- not the ramp, where 64
# clients are still starting, and not the tail, where they are finishing at slightly different
# times. The window bounds are written to meta.json so the analysis cannot quietly choose them
# after seeing the data.
#
# Usage: run_plane.sh <label>            e.g. run_plane.sh p4
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:?label, e.g. p4 or ovs}"
OUT="$HERE/raw/$LABEL"
mkdir -p "$OUT"

# Overridable so the plumbing can be smoke-tested at 30 s before a 6-minute run commits to it.
# New harnesses are the first thing under test: every previous one's first live run found a
# defect in the harness, not in the system.
FLOW_S="${FLOW_S:-340}"   # how long each iperf3 client runs
WARM_S="${WARM_S:-20}"    # discarded ramp at each end
POLL_S=$((FLOW_S + 40))
WIN_S=$((FLOW_S - 2 * WARM_S))

echo "=== $LABEL: flows ${FLOW_S}s, window ${WIN_S}s, pollers ${POLL_S}s ==="

# --- pre-conditions. PREREG section 5: none of these may be assumed. ------------------------
python3 - "$OUT" <<'PY'
import json, subprocess, sys, os
out = sys.argv[1]
g = json.loads(subprocess.run(
    ["curl", "-sS", "--max-time", "8", "http://127.0.0.1:8000/ndt/get_graph_data"],
    capture_output=True, text=True).stdout)
down = [e for e in g["edges"] if not e.get("is_up", True)]
hosts = [n for n in g.get("nodes", []) if n.get("vertex_type") == 1]
ipv4 = [h for h in hosts if h.get("ip") and h["ip"][0]]
print(f"  pre: edges={len(g['edges'])} down={len(down)} hosts={len(hosts)} ipv4={len(ipv4)}")
json.dump({"edges": len(g["edges"]), "edges_down": len(down),
           "hosts": len(hosts), "hosts_ipv4": len(ipv4)},
          open(os.path.join(out, "precheck.json"), "w"), indent=1)
if down or len(ipv4) != 128:
    print("  🔴 PREREG 5.0 not met: the twin has not converged. Not a measurement -- reboot.")
    sys.exit(1)
print("  pre: converged (edges_down=0, hosts_ipv4=128)")
PY
[ $? -eq 0 ] || exit 1

# Name the binary that is actually running, per benchmark-must-name-the-binary-it-measured.
{
  echo "label=$LABEL"
  echo "flow_s=$FLOW_S warm_s=$WARM_S win_s=$WIN_S"
  echo "bmv2: $(pgrep -a simple_switch_grpc | head -1)"
  echo "kernel: $(pgrep -a ndtwin_kernel | head -1)"
  echo "proxy: $(pgrep -af 'proxy_agent|p4_proxy' | head -1)"
} > "$OUT/binaries.txt"
cat "$OUT/binaries.txt" | sed 's/^/  /'

# --- pollers --------------------------------------------------------------------------------
bash "$HERE/poll_veth.sh" "$OUT/veth.tsv" "$POLL_S" 2 2> "$OUT/veth.stderr" &
VP=$!
bash "$HERE/poll_twin.sh" "$OUT" "$POLL_S" 2 2> "$OUT/twin.stderr" &
TP=$!
sleep 4

# --- flows ----------------------------------------------------------------------------------
T_FLOW_START=$(date +%s.%N)
bash "$HERE/run_flows.sh" "$OUT" "$FLOW_S" 2>&1 | tee "$OUT/flows.log"
T_FLOW_END=$(date +%s.%N)

wait "$VP" "$TP" 2>/dev/null

WIN_LO=$(python3 -c "print($T_FLOW_START + $WARM_S)")
WIN_HI=$(python3 -c "print($T_FLOW_START + $WARM_S + $WIN_S)")
python3 - "$OUT" "$LABEL" "$T_FLOW_START" "$T_FLOW_END" "$WIN_LO" "$WIN_HI" <<'PY'
import json, sys
d, label, t0, t1, lo, hi = sys.argv[1:]
json.dump({"label": label, "flow_start": float(t0), "flow_end": float(t1),
           "window_lo": float(lo), "window_hi": float(hi)},
          open(f"{d}/meta.json", "w"), indent=1)
print(f"\n  window: {lo} .. {hi}  ({float(hi)-float(lo):.0f}s)")
PY

echo "  veth: $(cat "$OUT/veth.stderr")"
echo "  twin: $(cat "$OUT/twin.stderr")"
echo "=== $LABEL done; raw in $OUT ==="
