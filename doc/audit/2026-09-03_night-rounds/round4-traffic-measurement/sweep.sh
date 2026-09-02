#!/usr/bin/env bash
# Round 4 sweep driver. [Co-developed with claude code -- Adam]
# usage: sweep.sh <outdir> <cell-tag> <bitrate|quiet> <payload-bytes> <load-seconds> <probe-seconds>
# Holds FLOW COUNT at exactly 1 throughout. Only ONE of {bitrate, payload} moves per sweep.
set -u
R="$(cd "$(dirname "$0")" && pwd)"
source "$R/lib_r4.sh"
OUT="$1"; TAG="$2"; RATE="$3"; LEN="$4"; TLOAD="$5"; TPROBE="$6"
mkdir -p "$OUT"
{
  echo "## cell $TAG  rate=$RATE payload=$LEN load=${TLOAD}s probe=${TPROBE}s"
  date -Is
  echo "-- machine noise record (COMMON-BRIEF 1: a busy machine fakes symptoms) --"
  uptime
  free -m | sed -n '1,2p'
  echo "suspect: $(ps -eo comm=,pcpu= --sort=-pcpu | head -5 | tr '\n' ';')"
  echo "-- proxy sflow send-side counters BEFORE --"
  curl -s --max-time 4 http://127.0.0.1:8081/sflow/stats
  echo
} >> "$OUT/cells.log"

# Guard: a cell is only interpretable if NOTHING else is offering traffic. `comm` is the
# kernel's name for the executable, so this matches an iperf3 and not a shell that mentions one.
# (ndt:353 makes the same argument.) Never pgrep -f.
STRAY=$(ps -eo pid=,comm=,args= | awk '$2=="iperf3" && $0 !~ / -s / {print $1}' | tr '\n' ' ')
if [[ -n "${STRAY// }" ]]; then
  echo "ABORT: iperf3 client(s) already running: $STRAY -- cell $TAG would be uninterpretable" \
       | tee -a "$OUT/cells.log"
  exit 3
fi
NROWS=$(curl -s --max-time 4 "http://127.0.0.1:8000/ndt/get_detected_flow_data?liveness=all" \
        | python3 -c "import json,sys;print(len(json.load(sys.stdin)))" 2>/dev/null || echo -1)
echo "pre-cell flow table rows (want 0): $NROWS" >> "$OUT/cells.log"

# The quiet cell for THIS cell: same command, no load, taken immediately before it.
python3 "$R/probe.py" 10.0.0.1 10.0.0.2 5 8 "${TAG}_quiet" > "$OUT/probe_${TAG}_quiet.csv" 2>&1

if [[ "$RATE" != "quiet" ]]; then
  ( r4_in h1 iperf3 -c 10.0.0.2 -u -b "$RATE" -l "$LEN" -t "$TLOAD" --forceflush \
      > "$OUT/iperf_$TAG.log" 2>&1 ) &
  IPID=$!
  sleep 12   # warm-up: let the 1 Hz rate loop and the path computation see the flow
else
  IPID=""
fi

python3 "$R/probe.py" 10.0.0.1 10.0.0.2 5 "$TPROBE" "$TAG" > "$OUT/probe_$TAG.csv" 2>"$OUT/probe_$TAG.err"

if [[ -n "$IPID" ]]; then wait $IPID 2>/dev/null; fi
{
  echo "-- proxy sflow send-side counters AFTER --"
  curl -s --max-time 4 http://127.0.0.1:8081/sflow/stats
  echo
  echo "-- iperf3 ground truth --"
  tail -4 "$OUT/iperf_$TAG.log" 2>/dev/null || echo "(quiet cell, no iperf3)"
  echo
} >> "$OUT/cells.log"
