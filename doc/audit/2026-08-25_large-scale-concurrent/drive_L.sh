#!/usr/bin/env bash
# Drive the five arms of PREREG amendment L in the pre-registered order.
#
# The order is not an implementation detail. Q' goes LAST, after the loaded arms, because
# ticket E's third arm was moved after its second by review rather than before it: both
# placements gave the same verdict, and only the later one could see the fabric degrading --
# which was the whole alternative explanation for the effect. Putting it here is the only way
# this round can tell "load did it" from "time did it".
#
# Stops at the first failed arm. A driver that carries on gives the later arms a contaminated
# machine and no way to tell afterwards, which is worse than a short round.
#
# Usage: NDT_OWNER=... drive_L.sh
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SETTLE="${SETTLE:-30}"
export FLOW_S="${FLOW_S:-340}" WARM_S="${WARM_S:-20}" FLOW_LIMIT="${FLOW_LIMIT:-16}" \
       RATE_SCALE="${RATE_SCALE:-1}" T_REPS="${T_REPS:-3}"

ARMS=("L_Q 0" "L_B7 7" "L_B14 14" "L_B28 28" "L_Qp 0")

echo "### amendment L: ${#ARMS[@]} arms, flow_s=$FLOW_S, settle=${SETTLE}s, start $(date '+%H:%M:%S')"
for spec in "${ARMS[@]}"; do
    set -- $spec
    label="$1"; burners="$2"
    echo
    echo "############ $label (burners=$burners) $(date '+%H:%M:%S') ############"
    if ! "$HERE/run_arm_L.sh" "$label" "$burners"; then
        echo "🔴 arm $label FAILED at $(date '+%H:%M:%S') -- stopping. Arms after this one were" \
             "not run, so nothing downstream is contaminated by a half-measured machine." >&2
        exit 1
    fi
    # Settle so one arm's burners cannot bleed into the next arm's opening samples. The load
    # sampler records straight through this gap, so the settle is visible rather than assumed.
    echo "  settling ${SETTLE}s"
    sleep "$SETTLE"
done
echo
echo "### all ${#ARMS[@]} arms done at $(date '+%H:%M:%S')"
