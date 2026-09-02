#!/usr/bin/env bash
# Sweep A: ONE flow, payload HELD at 1400 B, only the OFFERED BIT RATE moves.
# [Co-developed with claude code -- Adam]
set -u
R="$(cd "$(dirname "$0")" && pwd)"
OUT="$R/raw/sweepA"; mkdir -p "$OUT"
for cell in "green20M:20M" "r5M:5M" "r2M:2M" "r1M:1M" "r500k:500K" "r250k:250K" "r125k:125K" "r60k:60K"; do
  tag="${cell%%:*}"; rate="${cell##*:}"
  echo "=== $(date -Is) cell $tag rate $rate ==="
  "$R/sweep.sh" "$OUT" "$tag" "$rate" 1400 50 30
  echo "--- drain 20 s so the 15 s table empties before the next cell ---"
  sleep 20
done
echo "=== $(date -Is) sweep A done ==="
