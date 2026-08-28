#!/usr/bin/env bash
# P1-3 driver: ten arms, mirrored, per PREREG section 7.
#
# Cell order `1 2 4 8 16 | 16 8 4 2 1`. Mirrored so that a linear drift in machine state cannot
# align with a single cell -- each cell is measured once early and once late, at opposite ends of
# the session. The replication unit is the ARM, not the rep: two arms per cell, separated in time
# and interleaved across cells, never back to back.
#
# No commits from inside this script. Each commit spawns a background review that was measured at
# over two cores today; recording the experiment would contaminate it. Results land on disk and
# are committed after the last arm.
#
# Usage: NDT_OWNER="..." ./drive_p1_3.sh
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

SETTLE_S="${SETTLE_S:-20}"
# Overridable so that a pass interrupted mid-flight can be resumed on its own without re-running
# the pass that already completed. `-` not `:-`, so PASS_A="" really means "run no A arms".
# 2026-08-29: pass A completed 20:15-20:35; pass B was killed at 20:38 by a /compact that reset
# the owning shell. Resumed with PASS_A="".
PASS_A="${PASS_A-1 2 4 8 16}"
PASS_B="${PASS_B-16 8 4 2 1}"
TOTAL=$(( $(wc -w <<<"$PASS_A") + $(wc -w <<<"$PASS_B") ))

echo "############ P1-3 begins $(date '+%F %H:%M:%S') ############"
echo "pre-run context (disclosed, not hidden):"
printf '  agy_instances=%s  ' "$(pgrep -c agy 2>/dev/null)"
ps -o pcpu --no-headers -C agy 2>/dev/null | awk '{s+=$1} END{printf "agy_cpu_total=%.1f%%\n", s+0}'
echo "  load1=$(cut -d' ' -f1 /proc/loadavg)"
echo "  bmv2=$(pgrep -cf 'simple_switch_g[r]pc')  kernel=$(pgrep -c ndtwin_kernel)"

i=0
for n in $PASS_A; do
    i=$((i+1))
    echo; echo "===== arm $i/$TOTAL : n=$n pass A ====="
    NDT_OWNER="$NDT_OWNER" "$HERE/run_flowcount_arm.sh" "$n" "n${n}_a" || echo "🔴 arm n${n}_a returned non-zero"
    sleep "$SETTLE_S"
done
for n in $PASS_B; do
    i=$((i+1))
    echo; echo "===== arm $i/$TOTAL : n=$n pass B ====="
    NDT_OWNER="$NDT_OWNER" "$HERE/run_flowcount_arm.sh" "$n" "n${n}_b" || echo "🔴 arm n${n}_b returned non-zero"
    sleep "$SETTLE_S"
done

echo; echo "############ P1-3 arms complete $(date '+%F %H:%M:%S') ############"
printf '%-8s %-10s %-12s %-14s %s\n' cell arm clean_perflow aggregate busy_fraction
for n in 1 2 4 8 16; do
  for p in a b; do
    m="$HERE/raw/n${n}_${p}/arm.meta"
    [[ -f "$m" ]] || { printf '%-8s %-10s %s\n' "n=$n" "$p" "MISSING"; continue; }
    printf '%-8s %-10s %-12s %-14s %s\n' "n=$n" "$p" \
      "$(sed -n 's/^highest_clean_per_flow_mbit=//p' "$m")" \
      "$(sed -n 's/^aggregate_clean_mbit=//p' "$m")" \
      "$(sed -n 's/^busy_fraction=//p' "$m")"
  done
done
