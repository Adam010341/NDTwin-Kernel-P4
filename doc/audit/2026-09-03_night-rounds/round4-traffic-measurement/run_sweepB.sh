#!/usr/bin/env bash
# Sweep B, the MECHANISM test: ONE flow, OFFERED BIT RATE HELD at 1 Mbit/s, only the payload
# size moves. Bit rate constant, packet rate 14x. If the window is driven by sample arrival the
# flow must walk back INTO the default answer; if it is driven by bandwidth, nothing moves.
# [Co-developed with claude code -- Adam]
set -u
R="$(cd "$(dirname "$0")" && pwd)"
OUT="$R/raw/sweepB"; mkdir -p "$OUT"
for cell in "p1400:1400" "p600:600" "p250:250" "p100:100"; do
  tag="${cell%%:*}"; len="${cell##*:}"
  echo "=== $(date -Is) cell $tag payload $len bytes, rate HELD at 1M ==="
  "$R/sweep.sh" "$OUT" "$tag" 1M "$len" 50 30
  echo "--- drain 20 s ---"
  sleep 20
done
echo "=== $(date -Is) sweep B done ==="
