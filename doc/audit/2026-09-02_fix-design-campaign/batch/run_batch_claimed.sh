#!/usr/bin/env bash
# Claim the lab for the batch (heavy CPU, no lab traffic), run it, release. Sequential; one ninja.
# [Co-developed with claude code -- Adam]
set -uo pipefail
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/4e0e8cb4-1c72-4731-b5fe-2989d7af1d65/scratchpad
REPO=/home/adam/Desktop/NDTwin-Kernel; NDT="$REPO/tools/test_workflow/ndt"
export NDT_OWNER=auditor
cl=$(timeout 30 "$NDT" status 2>/dev/null | awk '$1=="claim"{$1="";print}' | sed 's/^ //')
if [[ -n "$cl" && "$cl" != none* && "$cl" != EXPIRED* && "$cl" != *auditor* ]]; then echo "lab still claimed: '$cl' -- not starting"; exit 3; fi
"$NDT" claim "${MIN:-150}" "auditor: batch compile + mutation gates of 10 fix branches (HEAVY CPU, no lab traffic, no switches touched)" || { echo "claim failed"; exit 4; }
trap '"$NDT" release >/dev/null 2>&1; echo "lab released at $(date +%H:%M:%S)"' EXIT
echo "batch start $(date +%H:%M:%S)"; bash "$SP/batch_compile.sh"; rc=$?; echo "batch end $(date +%H:%M:%S) rc=$rc"; exit $rc
