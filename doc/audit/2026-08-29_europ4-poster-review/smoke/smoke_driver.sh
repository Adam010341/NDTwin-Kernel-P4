#!/usr/bin/env bash
# Smoke driver: stock then fast, one arm each, short ladders. Design + deviations = SMOKE-PLAN.md.
# Instrument = ①'s drive_p1.sh/run_build_arm.sh, byte-identical copies (sha256 in REVIEW.md §11-bis area).
# [Co-developed with claude code -- Adam]
set -uo pipefail
cd "$(dirname "$0")"
export NDT_OWNER="8/29 poster-reviewer"

cp /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/bmv2_binary_override raw/override.before

echo "=== SMOKE stock arm start $(date '+%F %T') ==="
RATES_MBIT="30 45 70" ./drive_p1.sh stock:smoke_stock
echo "=== SMOKE fast arm start $(date '+%F %T') ==="
RATES_MBIT="240 360 540" ./drive_p1.sh fast:smoke_fast

echo "=== override drift check ==="
diff raw/override.before /home/adam/Desktop/NDTwin-Kernel/p4_proxy/mininet/bmv2_binary_override \
  && echo "override unchanged vs entry state" || echo "override DIFFERS from entry state (see diff above)"

echo "=== SMOKE DRIVER DONE $(date '+%F %T') ==="
