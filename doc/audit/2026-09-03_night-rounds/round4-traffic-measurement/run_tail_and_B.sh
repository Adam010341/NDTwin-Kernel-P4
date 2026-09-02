#!/usr/bin/env bash
set -u
R="$(cd "$(dirname "$0")" && pwd)"
# close the BOTTOM of the disagreement band: where does the 15 s table lose the flow too?
for cell in "r30k:30K" "r15k:15K"; do
  tag="${cell%%:*}"; rate="${cell##*:}"
  echo "=== $(date -Is) sweepA extra cell $tag rate $rate ==="
  "$R/sweep.sh" "$R/raw/sweepA" "$tag" "$rate" 1400 50 30
  sleep 20
done
"$R/run_sweepB.sh"
