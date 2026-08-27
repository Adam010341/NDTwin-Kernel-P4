#!/usr/bin/env bash
# Drive ticket P's four arms with all four instruments running across the whole round.
#
# The arm runner is ticket 1's run_arm_L.sh, unchanged and unforked. It ran five arms correctly
# already, and every new harness this project has written found its first defect on its first live
# run -- three of them today. Reusing the proven one is worth the slightly odd provenance: P's raw
# lands under the L round's raw/ directory, which the report states explicitly rather than hiding.
#
# The samplers span the entire round rather than one arm each. They record absolute timestamps and
# cumulative counters, so the analysis slices by each arm's window from meta.json; starting and
# stopping them per arm would add four restart seams for no gain.
#
# Usage: NDT_OWNER=... drive_P.sh
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
L="$HERE/../2026-08-25_large-scale-concurrent"
OUT="$HERE/raw"; mkdir -p "$OUT"
SETTLE="${SETTLE:-30}"
export FLOW_S="${FLOW_S:-340}" WARM_S="${WARM_S:-20}" FLOW_LIMIT="${FLOW_LIMIT:-16}" \
       RATE_SCALE="${RATE_SCALE:-1}" T_REPS="${T_REPS:-3}"

ARMS=("P_Q 0" "P_B14 14" "P_B28 28" "P_Qp 0")

# --- instruments, all four, spanning the round ----------------------------------------------
declare -a SAMP
start_sampler() {   # $1=script $2=outfile $3=interval
    python3 "$1" "$OUT/$2" "$3" & SAMP+=("$!")
    echo "  sampler $(basename "$1") pid ${SAMP[-1]} -> raw/$2"
}
cleanup() {
    for p in "${SAMP[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    sleep 1
    alive=0
    for p in "${SAMP[@]:-}"; do [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done
    # A sampler that outlives the round keeps writing into the next session's fabric and its rows
    # would look like this round's data. Assert, do not hope.
    (( alive > 0 )) && echo "🔴 $alive sampler(s) SURVIVED -- kill them before the next round" >&2
    echo "samplers_survived=$alive" >> "$OUT/round.meta"
}
trap cleanup EXIT

echo "### ticket P: ${#ARMS[@]} arms, flow_s=$FLOW_S, settle=${SETTLE}s, start $(date '+%H:%M:%S')"
echo "round_start=$(date +%s)" > "$OUT/round.meta"
start_sampler "$HERE/sample_sflow_stats.py"  sflow_stats.jsonl 2
start_sampler "$L/sample_bmv2_cpu.py"        bmv2_cpu.jsonl    5
start_sampler "$L/sample_proxy_cpu.py"       proxy_cpu.jsonl   5
# udp 6343 drops: inline is fine, it has no pattern that could match itself
python3 -c '
import json,time,sys
out=open(sys.argv[1],"a",buffering=1)
while True:
    t0=time.time()
    try:
        for r in [l.split() for l in open("/proc/net/udp").read().splitlines()[1:]]:
            if r[1].split(":")[1].upper()=="18C7":
                tx,rx=r[4].split(":")
                out.write(json.dumps({"t":t0,"tx_queue":int(tx,16),"rx_queue":int(rx,16),"drops":int(r[-1])})+"\n")
    except Exception as e:
        out.write(json.dumps({"t":t0,"err":str(e)})+"\n")
    time.sleep(max(0.0, 5-(time.time()-t0)))
' "$OUT/udp6343.jsonl" & SAMP+=("$!")
echo "  sampler udp6343 pid ${SAMP[-1]}"
sleep 3

for spec in "${ARMS[@]}"; do
    set -- $spec; label="$1"; burners="$2"
    echo; echo "############ $label (burners=$burners) $(date '+%H:%M:%S') ############"
    if ! "$L/run_arm_L.sh" "$label" "$burners"; then
        echo "🔴 arm $label FAILED at $(date '+%H:%M:%S') -- stopping. Later arms were not run," \
             "so nothing downstream is contaminated by a half-measured machine." >&2
        exit 1
    fi
    echo "  settling ${SETTLE}s"; sleep "$SETTLE"
done
echo "round_end=$(date +%s)" >> "$OUT/round.meta"
echo; echo "### all ${#ARMS[@]} arms done at $(date '+%H:%M:%S')"
