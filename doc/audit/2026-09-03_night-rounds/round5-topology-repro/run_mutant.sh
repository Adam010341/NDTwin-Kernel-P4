#!/usr/bin/env bash
# Start the kernel fabric-free against one topology file, probe it, stop it, verify it is gone.
# One argument: the topology file (absolute path). Everything goes to stdout.
# No sudo is used, so $! really is the kernel (the COMMON-BRIEF sudo-forks hazard does not apply).
# [Co-developed with claude code -- Adam]
set -u
KDIR=/home/adam/Desktop/NDTwin-Kernel
TOPO="$1"
TAG="$(basename "$TOPO" .json)"
RUN=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/mut/$TAG
rm -rf "$RUN"; mkdir -p "$RUN"
KLOG="$RUN/kernel.log"   # --logfile is ignored by this build; the real log is stdout.txt (see friction log)

echo "== topology: $TOPO"
echo "== bytes:    $(wc -c < "$TOPO")"
echo "== started:  $(date -Is)"

cd "$KDIR/build" || exit 9
setsid ./bin/ndtwin_kernel --mode mininet --topology "$TOPO" --no-ai --logfile "$KLOG" \
  > "$RUN/stdout.txt" 2> "$RUN/stderr.txt" &
PID=$!
echo "== kernel pid: $PID"

OPEN_AT=""; DIED_AT=""
for i in $(seq 1 40); do
    if [[ -z "$OPEN_AT" ]] && ss -ltnH "sport = :8000" 2>/dev/null | grep -q .; then
        OPEN_AT=$(awk "BEGIN{printf \"%.2f\", $i*0.25}")
    fi
    if [[ -z "$DIED_AT" ]] && ! kill -0 "$PID" 2>/dev/null; then
        DIED_AT=$(awk "BEGIN{printf \"%.2f\", $i*0.25}")
        break
    fi
    [[ -n "$OPEN_AT" && $i -ge 24 ]] && break
    sleep 0.25
done

echo "== :8000 opened at (s): ${OPEN_AT:-NEVER}"
echo "== process died at (s): ${DIED_AT:-still alive at end of watch}"

if kill -0 "$PID" 2>/dev/null; then
  echo "== ps on exact pid: $(ps -o pid=,stat=,etime=,comm= -p "$PID" 2>&1)"
  echo "--- probes ---"
  for u in \
    "http://127.0.0.1:8000/ndt/get_graph_data" \
    "http://127.0.0.1:8000/ndt/get_path_switch_count?ip1=10.0.0.1&ip2=10.0.0.2" \
    "http://127.0.0.1:8000/ndt/get_path_switch_count?ip1=10.0.0.1&ip2=10.0.0.4" \
    "http://127.0.0.1:8000/ndt/get_average_link_usage" \
    "http://127.0.0.1:8000/ndt/get_switches_power_state" ; do
      code=$(curl -s -o "$RUN/body.tmp" -w '%{http_code}' --max-time 8 "$u")
      echo "PROBE $code  $u"
      if [[ "$u" == *get_graph_data* ]]; then cp "$RUN/body.tmp" "$RUN/graph.json"; fi
      head -c 300 "$RUN/body.tmp"; echo
  done
  python3 - "$RUN/graph.json" <<'PY'
import json,sys
try:
    g=json.load(open(sys.argv[1]))
except Exception as e:
    print("GRAPH-PARSE-FAIL", e); raise SystemExit
def grab(o,key,acc):
    if isinstance(o,dict):
        for k,v in o.items():
            if k==key and isinstance(v,list): acc.append(v)
            grab(v,key,acc)
    elif isinstance(o,list):
        for v in o: grab(v,key,acc)
ns=[];es=[]
grab(g,"nodes",ns); grab(g,"edges",es)
n = ns[0] if ns else []; e = es[0] if es else []
sw=[x for x in n if x.get("vertex_type")==0]
ho=[x for x in n if x.get("vertex_type")==1]
print(f"GRAPH nodes={len(n)} (vertex_type0={len(sw)} vertex_type1={len(ho)}) edges={len(e)}")
print("GRAPH status:", g.get("status"), "top keys:", sorted(g.keys())[:10])
names=sorted(x.get("device_name","?") for x in n)
print("GRAPH device_names:", names)
# per-host degree: how many edges touch each host address
from collections import Counter
c=Counter()
for x in e:
    for side in ("src_ip","dst_ip"):
        v=x.get(side)
        if isinstance(v,list) and v: c[str(v[0])]+=1
        elif v is not None: c[str(v)]+=1
print("GRAPH edge-endpoint histogram (top 8):", c.most_common(8))
PY
else
  echo "== process is NOT alive; no probes possible"
fi

echo "--- exit ---"
if kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null
    for i in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$PID" 2>/dev/null
fi
wait "$PID" 2>/dev/null; RC=$?
echo "== wait rc (143=SIGTERM, 134=abort, 1=exit1, 0=clean): $RC"
echo "== ps rows on exact pid after stop: $(ps -o pid= -p "$PID" 2>/dev/null | wc -l)"

echo "--- stderr (all, max 25 lines) ---"; head -25 "$RUN/stderr.txt"
echo "--- stdout (last 12 lines) ---"; tail -12 "$RUN/stdout.txt"
echo "--- kernel.log lines: $(wc -l < "$RUN/stdout.txt" 2>/dev/null || echo 0) ---"
echo "  Skipping-edge count: $(grep -c 'Skipping edge' "$RUN/stdout.txt" 2>/dev/null || echo 0)"
grep 'Skipping edge' "$RUN/stdout.txt" 2>/dev/null | head -4
echo "--- kernel.log warning/error lines ---"
grep -iE 'warning|error|critical' "$RUN/stdout.txt" 2>/dev/null | head -15
echo "--- kernel.log topology/load lines ---"
grep -iE 'Load Static Topology|bmv2 topology|mixed|homogene|Invalid IP' "$RUN/stdout.txt" 2>/dev/null | head -8
echo "== finished: $(date -Is)"
sleep 3.2
echo "== after 3.2 s settle: tcp:8000=$(ss -ltnH 'sport = :8000' | wc -l) udp:6343=$(ss -lunH 'sport = :6343' | wc -l)"
