#!/usr/bin/env bash
#
# FINDINGS #61/#62 -- what the real ndtwin_kernel binary does with a wrong topology file.
#
# One argument: the topology file. Runs the kernel, records how it exited, whether it ever
# opened :8000, and what it said. No lab, no sudo, no Mininet: the load happens in main()
# before anything binds (src/main.cpp:376), so a kernel that refuses one never reaches a socket.
#
# [Co-developed with claude code -- Adam]
set -u
BIN="$1"
TOPO="$2"
OUT="$3"
mkdir -p "$(dirname "$OUT")"

{
  echo "== binary:      $BIN"
  echo "== binary sha:  $(sha256sum "$BIN" | cut -d' ' -f1)"
  echo "== topology:    $TOPO"
  echo "== topo sha:    $(sha256sum "$TOPO" | cut -d' ' -f1)"
  echo "== started:     $(date -Is)"
  echo "== :8000 before: $(ss -ltnH 'sport = :8000' | wc -l) listener(s)"
} > "$OUT"

RUNDIR="$(mktemp -d)"
cd "$(dirname "$BIN")/.." || exit 9
setsid "$BIN" --mode mininet --topology "$TOPO" --no-ai \
    > "$RUNDIR/stdout.txt" 2> "$RUNDIR/stderr.txt" &
PID=$!
echo "== pid:         $PID" >> "$OUT"

OPEN_AT=""; DIED_AT=""
for i in $(seq 1 40); do
    if [[ -z "$OPEN_AT" ]] && ss -ltnH "sport = :8000" 2>/dev/null | grep -q .; then
        OPEN_AT=$(awk "BEGIN{printf \"%.2f\", $i*0.25}")
    fi
    if [[ -z "$DIED_AT" ]] && ! kill -0 "$PID" 2>/dev/null; then
        DIED_AT=$(awk "BEGIN{printf \"%.2f\", $i*0.25}")
        break
    fi
    [[ -n "$OPEN_AT" && $i -ge 12 ]] && break
    sleep 0.25
done

{
  echo "== :8000 opened at (s): ${OPEN_AT:-NEVER}"
  echo "== process died at (s): ${DIED_AT:-still alive at end of watch}"
} >> "$OUT"

if kill -0 "$PID" 2>/dev/null; then
    echo "== still running -- the topology was ACCEPTED. Probing get_graph_data." >> "$OUT"
    code=$(curl -s -o "$RUNDIR/graph.json" -w '%{http_code}' --max-time 8 \
           "http://127.0.0.1:8000/ndt/get_graph_data")
    echo "== GET /ndt/get_graph_data -> HTTP $code" >> "$OUT"
    python3 - "$RUNDIR/graph.json" "$TOPO" >> "$OUT" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
t = json.load(open(sys.argv[2]))
print(f"== served: nodes={len(g['nodes'])} edges={len(g['edges'])}")
print(f"== file:   nodes={len(t['nodes'])} edges={len(t['edges'])}")
print(f"== DROPPED: {len(t['edges']) - len(g['edges'])} edge(s)")
ports = sorted({e[k] for e in g["edges"] for k in ("src_interface", "dst_interface")})
print(f"== interface values republished by get_graph_data: {ports}")
PY
    kill -TERM "$PID" 2>/dev/null
    for i in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$PID" 2>/dev/null
fi

wait "$PID" 2>/dev/null; RC=$?
{
  echo "== EXIT CODE: $RC   (0=clean, 1=EXIT_FAILURE, 134=abort, 143=SIGTERM)"
  echo "--- stderr ---"
  cat "$RUNDIR/stderr.txt"
  echo "--- topology load lines from stdout ---"
  grep -iE 'critical|Skipping edge|Load Static Topology|topology file' "$RUNDIR/stdout.txt" | head -12
  echo "--- Server Listening line present? ---"
  grep -c 'Server Listening' "$RUNDIR/stdout.txt"
  echo "== :8000 after: $(ss -ltnH 'sport = :8000' | wc -l) listener(s)"
  echo "== finished: $(date -Is)"
} >> "$OUT"

rm -rf "$RUNDIR"
