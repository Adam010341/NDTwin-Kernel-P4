#!/usr/bin/env bash
# 2 driver: six arms, mirrored, per PREREG section 5.
#
# Order `64 256 1024 | 1024 256 64`. Mirrored so a linear drift in machine state cannot align with
# a frame size -- each size is measured once early and once late.
#
# No commits from inside this script: each commit spawns a background review measured at over two
# cores, and recording the experiment would contaminate it.
#
# Usage: NDT_OWNER="..." ./drive_p2.sh
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SETTLE_S="${SETTLE_S:-20}"
PASS_A="${PASS_A-64 256 1024}"
PASS_B="${PASS_B-1024 256 64}"
TOTAL=$(( $(wc -w <<<"$PASS_A") + $(wc -w <<<"$PASS_B") ))

echo "############ 2 packet-size sweep begins $(date '+%F %H:%M:%S') ############"
echo "pre-run context (disclosed, not hidden):"
echo "  agy=$(ps -eo comm= | grep -c '^agy$')  bmv2=$(ps -eo comm= | grep -c simple_switch)"
echo "  load1=$(cut -d' ' -f1 /proc/loadavg)"
echo "  top non-bmv2 CPU: $(ps -eo pcpu,comm --sort=-pcpu --no-headers | grep -v simple_switch | head -1)"

i=0
for f in $PASS_A; do
    i=$((i+1)); echo; echo "===== arm $i/$TOTAL : ${f}B pass A ====="
    NDT_OWNER="$NDT_OWNER" "$HERE/run_size_arm.sh" "$f" "f${f}_a" || echo "🔴 arm f${f}_a returned non-zero"
    sleep "$SETTLE_S"
done
for f in $PASS_B; do
    i=$((i+1)); echo; echo "===== arm $i/$TOTAL : ${f}B pass B ====="
    NDT_OWNER="$NDT_OWNER" "$HERE/run_size_arm.sh" "$f" "f${f}_b" || echo "🔴 arm f${f}_b returned non-zero"
    sleep "$SETTLE_S"
done

echo; echo "############ 2 arms complete $(date '+%F %H:%M:%S') ############"
printf '%-10s %-6s %-14s %-12s %-12s %s\n' frame arm clean_kpps external total_busy bmv2_share
for f in 64 256 1024; do
  for p in a b; do
    m="$HERE/raw/f${f}_${p}/arm.meta"
    [[ -f "$m" ]] || { printf '%-10s %-6s %s\n' "${f}B" "$p" "MISSING"; continue; }
    printf '%-10s %-6s %-14s %-12s %-12s %s\n' "${f}B" "$p" \
      "$(sed -n 's/^highest_clean_kpps=//p' "$m")" \
      "$(sed -n 's/^external=//p' "$m")" \
      "$(sed -n 's/^total_busy=//p' "$m")" \
      "$(sed -n 's/^bmv2_share=//p' "$m")"
  done
done
