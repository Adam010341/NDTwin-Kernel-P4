#!/usr/bin/env bash
# The twin's own view: per-edge bandwidth usage and the detected-flow list, once per interval.
#
# Written as JSONL (one whole response per line, prefixed with the wall clock we asked at) so a
# later parser never has to guess which sample a field came from. curl gets a hard timeout
# because this repo has had a `popen(curl)` sit for 131 seconds against an IPv6 black hole, and
# a poller that blocks silently produces a gap that looks like idleness.
#
# Usage: poll_twin.sh <outdir> <seconds> [interval]
# [Co-developed with claude code -- Adam]
set -euo pipefail
DIR="${1:?outdir}"; DUR="${2:?seconds}"; IVL="${3:-2}"
mkdir -p "$DIR"
G="$DIR/graph.jsonl"; F="$DIR/flows.jsonl"
: > "$G"; : > "$F"

# 127.0.0.1, never `localhost`: the difference has been measured at 131 seconds.
API=http://127.0.0.1:8000
ok_g=0; ok_f=0; n=0
end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ]; do
    ts=$(date +%s.%N)
    if body=$(curl -sS --max-time 5 "$API/ndt/get_graph_data" 2>/dev/null) && [ -n "$body" ]; then
        printf '{"ts":%s,"body":%s}\n' "$ts" "$body" >> "$G"; ok_g=$((ok_g+1))
    else
        printf '{"ts":%s,"body":null}\n' "$ts" >> "$G"
    fi
    if body=$(curl -sS --max-time 5 "$API/ndt/get_detected_flow_data" 2>/dev/null) && [ -n "$body" ]; then
        printf '{"ts":%s,"body":%s}\n' "$ts" "$body" >> "$F"; ok_f=$((ok_f+1))
    else
        printf '{"ts":%s,"body":null}\n' "$ts" >> "$F"
    fi
    n=$((n+1))
    sleep "$IVL"
done
echo "twin: $n attempts, graph ok=$ok_g, flows ok=$ok_f" >&2
[ "$ok_g" -gt 0 ] || { echo "twin: 🔴 every graph poll failed -- this run has no twin side" >&2; exit 1; }
