#!/usr/bin/env bash
# One arm of PREREG amendment L: ratio and loop period T measured together, under a named load.
#
# The whole point of amendment L is that ratio and T must come from THE SAME run and the same
# window. The previous round's most expensive mistake was comparing two quantities that could
# only be measured at different times of day and calling the difference a result, so this script
# refuses to produce one without the other.
#
# Usage: run_arm_L.sh <label> <burners>      e.g. run_arm_L.sh L_Q 0 ; run_arm_L.sh L_B14 14
#        FLOW_S / WARM_S / FLOW_LIMIT / RATE_SCALE pass through to run_plane.sh.
#        Smoke-test and real arm run THIS SAME PATH -- a harness the tests bypass is untested.
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
LABEL="${1:?label, e.g. L_Q}"
BURNERS="${2:?number of CPU burners, e.g. 0 or 14}"
OUT="$HERE/raw/$LABEL"
FLOW_S="${FLOW_S:-340}"; WARM_S="${WARM_S:-20}"
WIN_S=$((FLOW_S - 2 * WARM_S))
mkdir -p "$OUT"

# The lab claim is the only source of truth for who may touch this fabric, and `ndt` enforces it
# for `ndt` commands only -- this script is a bare command and would sail straight past it. A
# previous session bypassed its own claim exactly this way, 40 minutes after being warned.
owner="$(sed -n 's/^owner=//p' "$REPO_ROOT/.test_run/lab.claim" 2>/dev/null)"
exp="$(sed -n 's/^expires=//p' "$REPO_ROOT/.test_run/lab.claim" 2>/dev/null)"
if [[ "$owner" != "${NDT_OWNER:-}" ]] || [[ -z "$exp" ]] || (( exp < $(date +%s) )); then
    echo "🔴 REFUSING: lab.claim owner='$owner' expires='$exp', NDT_OWNER='${NDT_OWNER:-}'" >&2
    exit 1
fi
echo "=== arm $LABEL: burners=$BURNERS flow_s=$FLOW_S win_s=$WIN_S (claim ok: $owner) ==="

# --- load, started before anything is measured so the arm is uniform end to end --------------
BURN_PIDS=()
for _ in $(seq 1 "$BURNERS"); do
    bash -c 'while :; do :; done' & BURN_PIDS+=("$!")
done
[[ ${#BURN_PIDS[@]} -gt 0 ]] && echo "  burners: ${BURN_PIDS[*]}"

# Kill by exact pid, never by pattern. `pkill -f` has matched this project's own command lines
# more than once, and this script's argv contains every pattern one would reach for.
cleanup() {
    for p in "${BURN_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    for p in "${BURN_PIDS[@]:-}"; do
        [[ -z "$p" ]] && continue
        for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.2; done
        kill -0 "$p" 2>/dev/null && { echo "  escalating on burner $p"; kill -9 "$p" 2>/dev/null; }
    done
    # An arm that leaves burners alive poisons every arm after it, and the next arm's own load
    # reading would absorb them silently. Assert, do not hope.
    alive=0
    for p in "${BURN_PIDS[@]:-}"; do [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done
    if (( alive > 0 )); then
        echo "🔴 $alive burner(s) SURVIVED -- every later arm is contaminated. Fix before continuing." >&2
        echo "burners_survived=$alive" >> "$OUT/load.meta"
    else
        echo "  burners: all $BURNERS dead"
        echo "burners_survived=0" >> "$OUT/load.meta"
    fi
    [[ -n "${SAMP_PID:-}" ]] && kill "$SAMP_PID" 2>/dev/null
}
trap cleanup EXIT

# --- load sampler. PREREG L-5: BOTH arms need their own readings; the quiet one is not ---------
# assumed quiet. Raw counters are recorded rather than percentages so the arithmetic can be
# redone later against a different definition without re-running the fabric.
# Invoked through python3 rather than relying on the exec bit: measure_loop_period.py is
# committed without one, and the first live run of this script died on exactly that -- after
# the fabric had already been loaded and the flows started, i.e. at the most expensive moment.
python3 "$HERE/sample_load.py" "$OUT/load.jsonl" 5 & SAMP_PID=$!
echo "burners_requested=$BURNERS" > "$OUT/load.meta"
echo "burner_pids=${BURN_PIDS[*]:-}" >> "$OUT/load.meta"

# --- the ratio run, backgrounded so T can be measured inside its own window -------------------
rm -f "$OUT/flows.log"
( FLOW_S="$FLOW_S" WARM_S="$WARM_S" \
  FLOW_LIMIT="${FLOW_LIMIT:-16}" RATE_SCALE="${RATE_SCALE:-1}" \
  bash "$HERE/run_plane.sh" "$LABEL" > "$OUT/plane.log" 2>&1 ) & PLANE_PID=$!

# Detect the real flow start instead of assuming a fixed delay: run_plane.sh does a converge
# precheck of unpredictable duration first, and a fixed sleep would drift T's window off the
# ratio's window -- which is the one thing this arm exists to keep aligned.
echo "  waiting for flows to start..."
for i in $(seq 1 120); do
    [[ -s "$OUT/flows.log" ]] && break
    kill -0 "$PLANE_PID" 2>/dev/null || { echo "🔴 run_plane.sh exited before flows started"; \
        tail -20 "$OUT/plane.log"; exit 1; }
    sleep 1
done
[[ -s "$OUT/flows.log" ]] || { echo "🔴 flows never started"; tail -20 "$OUT/plane.log"; exit 1; }
T_FLOW_SEEN=$(date +%s)
echo "  flows up at $(date '+%H:%M:%S'); T window = +${WARM_S}s for ${WIN_S}s"

sleep "$WARM_S"
# T is measured T_REPS times INSIDE the one traffic window, because traffic is the expensive
# half and T is the cheap half. One estimate per arm would leave every between-arm comparison at
# n=1 -- and n=1 against n=1 is precisely how 1.18 and 0.92 came to be believed on the same
# fabric. Three sub-windows give a within-arm spread to judge the between-arm difference against.
T_REPS="${T_REPS:-3}"
SUB_S=$((WIN_S / T_REPS))
for rep in $(seq 1 "$T_REPS"); do
    echo "  T rep $rep/$T_REPS (${SUB_S}s)"
    python3 "$HERE/measure_loop_period.py" "$OUT/period_$rep.json" "$SUB_S" 2>&1 | sed 's/^/  T| /'
    [[ -s "$OUT/period_$rep.json" ]] || { echo "🔴 no period_$rep.json -- T was not measured," \
        "so this arm cannot be compared against any other. Not a measurement."; exit 1; }
done
echo "t_flow_seen=$T_FLOW_SEEN" >> "$OUT/load.meta"

wait "$PLANE_PID"
echo "=== arm $LABEL done ==="
