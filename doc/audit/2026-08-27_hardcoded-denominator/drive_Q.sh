#!/usr/bin/env bash
# Ticket Q: alternate baseline and Q-fixed kernels on ONE fabric, B Q B Q B Q.
#
# WHY ALTERNATE. Both binaries run against the same bmv2/proxy/mininet, swapping only the kernel
# process, so "which binary" is the treatment rather than being confounded with having rebuilt.
# The order is B Q B Q B Q and not B B B Q Q Q because whatever is drifting -- and something is:
# two quiet arms of one generation came out 42 ms apart earlier today with no mechanism named --
# is then orthogonal to the treatment instead of aliased onto it.
#
# WHY THREE OF EACH. The replication unit is the ARM, not the rep inside it. Three reps in one
# arm are three reads of one arm; they share its fabric state and cannot go into a standard
# error for a between-arm comparison. That error cost this project a "10.9 SE" that was really
# 0.31 once the arm became the unit.
#
# THE ACCEPTANCE runs on EVERY arm, not once: the kernel logs measured_interval_s and
# divisor_used_s from the same loop iteration, and they must agree to 1% on the Q-fixed arms.
# On baseline arms the line is absent entirely -- that binary has no such instrument -- and its
# absence is recorded as ABSENT rather than as a pass.
#
# Usage: NDT_OWNER=... drive_Q.sh
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
L="$HERE/../2026-08-25_large-scale-concurrent"
# git, not a relative walk: a copy of this script placed anywhere else silently resolved REPO to
# the copy's parent and then reported "no binary" -- a real failure, but attributed to the wrong
# thing. [Co-developed with claude code -- Adam]
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
OUT="$HERE/raw"; mkdir -p "$OUT"
BIN="$REPO/.test_run/binaries"
KLOG="$REPO/.test_run/logs/kernel.log"

# `cp` onto build/bin/ndtwin_kernel fails with ETXTBSY while a kernel is executing from that
# inode -- the smoke run hit it and every arm after the first would have died the same way. A
# copy-then-rename replaces the directory entry instead of writing through it: the running
# process keeps its old inode until restart_kernel.sh kills it, and the new file is in place.
# (cmake's linker got away with `cp`-like behaviour only because ld creates a new file too.)
# [Co-developed with claude code -- Adam]
swap_binary_in() {   # $1 = sha prefix
    cp -p "$BIN/ndtwin_kernel.$1" "$REPO/build/bin/.ndtwin_kernel.staged" || return 1
    mv -f "$REPO/build/bin/.ndtwin_kernel.staged" "$REPO/build/bin/ndtwin_kernel" || return 1
}

BASE_SHA=3367d0e9
QFIX_SHA=ab2d7ed1
FLOW_S="${FLOW_S:-180}"; export FLOW_S
export WARM_S="${WARM_S:-20}" FLOW_LIMIT="${FLOW_LIMIT:-16}" RATE_SCALE=1 T_REPS="${T_REPS:-1}"
SETTLE="${SETTLE:-20}"

# B Q B Q B Q. Six arms, three per cell, alternating.
if [[ -n "${ARMS_OVERRIDE:-}" ]]; then
    read -ra ARMS <<< "$ARMS_OVERRIDE"     # smoke without copying the script elsewhere
else
    ARMS=(Q_B1:$BASE_SHA Q_Q1:$QFIX_SHA Q_B2:$BASE_SHA Q_Q2:$QFIX_SHA Q_B3:$BASE_SHA Q_Q3:$QFIX_SHA)
fi

echo "### ticket Q: ${#ARMS[@]} arms, flow_s=$FLOW_S, start $(date '+%H:%M:%S')"
echo "round_start=$(date +%s)" > "$OUT/round.meta"

for spec in "${ARMS[@]}"; do
    label="${spec%%:*}"; sha="${spec##*:}"
    echo; echo "############ $label  binary=$sha  $(date '+%H:%M:%S') ############"

    # Swap the kernel. Copying the wanted binary into place first means restart_kernel.sh's
    # sha256 assertion is checking that the swap took, not merely that a kernel is running.
    swap_binary_in "$sha" || { echo "🔴 could not put binary $sha in place"; exit 1; }
    if ! "$L/restart_kernel.sh" "$sha"; then
        echo "🔴 arm $label: kernel swap failed -- stopping. Later arms not run, so nothing" \
             "downstream is contaminated by a half-swapped machine." >&2
        exit 1
    fi

    # Mark where this arm starts in the kernel log, so the divisor lines can be attributed to
    # this arm rather than to whatever was in the file already.
    mark=$(wc -l < "$KLOG")

    if ! "$L/run_arm_L.sh" "$label" 0; then
        echo "🔴 arm $label FAILED at $(date '+%H:%M:%S') -- stopping." >&2
        exit 1
    fi

    # --- the acceptance gate, on THIS arm -------------------------------------------------
    tail -n +$((mark + 1)) "$KLOG" | grep -F "rate divisor check" > "$OUT/$label.divisor" || true
    n=$(wc -l < "$OUT/$label.divisor")
    if [[ "$sha" == "$QFIX_SHA" ]]; then
        if (( n == 0 )); then
            echo "  🔴 GATE: no divisor line in $label -- the instrument did not run. NOT a pass."
        else
            python3 - "$OUT/$label.divisor" <<'PY'
import re, sys
rows = []
for line in open(sys.argv[1]):
    m = re.search(r"measured_interval_s=([\d.]+) divisor_used_s=(-?[\d.]+)", line)
    if m:
        rows.append((float(m.group(1)), float(m.group(2))))
if not rows:
    print("  🔴 GATE: lines present but unparseable -- NOT a pass"); raise SystemExit
neg = [r for r in rows if r[1] < 0]
live = [r for r in rows if r[1] >= 0]
# A negative divisor means no rate was published in that window. It is not a failure of the
# fix and it is not a pass either; counted and reported rather than folded into either.
worst = max((abs(m - d) / m for m, d in live), default=None)
if not live:
    print(f"  ⚠️  GATE: {len(rows)} lines, all sentinel (no rate published) -- INCONCLUSIVE")
elif worst <= 0.01:
    print(f"  ✅ GATE: {len(live)}/{len(rows)} live, worst |measured-divisor|/measured = {worst:.4%} (<= 1%)")
else:
    print(f"  🔴 GATE: worst deviation {worst:.4%} EXCEEDS 1% over {len(live)} live samples")
PY
        fi
    else
        (( n == 0 )) && echo "  ok  baseline: no divisor instrument, as expected (ABSENT, not a pass)" \
                     || echo "  🔴 baseline emitted $n divisor lines -- wrong binary ran"
    fi

    echo "  settling ${SETTLE}s"; sleep "$SETTLE"
done

echo "round_end=$(date +%s)" >> "$OUT/round.meta"
# Leave the Q-fixed binary in place: the next thing to run is ticket M, whose baseline is this.
swap_binary_in "$QFIX_SHA" || echo "⚠️  could not leave the Q-fixed binary in place"
echo; echo "### all ${#ARMS[@]} arms done at $(date '+%H:%M:%S')"
