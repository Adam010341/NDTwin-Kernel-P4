#!/usr/bin/env bash
# Tickets Q and M, six arms, ONE fabric generation, mirrored: base Q M M Q base.
#
# WHY MIRRORED (PREREG section 1). All three conditions have mean position 3.5 -- base at 1,6;
# Q at 2,5; M at 3,4 -- so any drift that is approximately LINEAR over the block cancels exactly
# in every pairwise difference, without anyone having to know its size or its mechanism. The
# rotation `A B C A B C` this replaces has mean positions 2.5/3.5/4.5, leaving every comparison
# contaminated by exactly 1xd.
#
# WHY ALL SIX ARMS RUN THE IDENTICAL WORKLOAD. Q's metric wants steady flows and M's wants churn.
# Running each ticket's own workload on its own arms would put the workload back into the
# comparison as a confounder of position. So every arm runs BOTH: 16 steady iperf3 flows for the
# ratio and the loop period, and 144 short churn flows for the path-fill latency. Q's binaries do
# not change churn behaviour and M's do not change the ratio, so each metric is read off all six
# arms with the other four as controls.
#
# WHY THE ARM IS THE UNIT. Reps inside one arm are reads of one arm. Using their spread as the
# error term for a between-arm difference understates it about fivefold -- this project reported a
# "10.9 SE" that was 0.31 once the arm became the unit, and an independent recomputation agreed
# with the wrong number because it started from the same reps.
#
# Usage: NDT_OWNER="..." drive_block.sh            (SMOKE=1 for a short plumbing run)
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
L="$REPO/doc/audit/2026-08-25_large-scale-concurrent"
M="$REPO/doc/audit/2026-08-27_1khz-path-recompute"
OUT="$HERE/raw"; mkdir -p "$OUT"
KLOG="$REPO/.test_run/logs/kernel.log"
BIN="$REPO/.test_run/binaries"

BASE_SHA=3367d0e9      # baseline
QFIX_SHA=ab2d7ed1      # + ticket Q (rate denominator divided by the measured interval)
MFIX_SHA=a40e04ce      # + ticket M (path recompute 1 kHz -> 1 Hz)

if [[ -n "${SMOKE:-}" ]]; then
    FLOW_S=70; CHURN_S=40; CHURN_EVERY=5; CHURN_BATCH=2; SETTLE=5
    ARMS=(S_B1:$BASE_SHA S_M2:$MFIX_SHA)
else
    FLOW_S=240; CHURN_S=180; CHURN_EVERY=5; CHURN_BATCH=4; SETTLE=20
    ARMS=(B1:$BASE_SHA Q2:$QFIX_SHA M3:$MFIX_SHA M4:$MFIX_SHA Q5:$QFIX_SHA B6:$BASE_SHA)
fi
WARM_S=20
WIN_S=$((FLOW_S - 2 * WARM_S))
POLL_HZ="${POLL_HZ:-10}"
SAMP_S=$((CHURN_S + 30))         # starts 5 s before churn, ends 25 s after its last flow starts
CHURN_SEED="${CHURN_SEED:-20260828}"

# `cp` onto build/bin/ndtwin_kernel fails ETXTBSY while a kernel executes from that inode.
# Copy-then-rename replaces the directory entry instead of writing through it.
swap_binary_in() {
    cp -p "$BIN/ndtwin_kernel.$1" "$REPO/build/bin/.ndtwin_kernel.staged" || return 1
    mv -f "$REPO/build/bin/.ndtwin_kernel.staged" "$REPO/build/bin/ndtwin_kernel" || return 1
}

say() { echo "$@" | tee -a "$OUT/progress.txt"; }

# --- the lab claim, checked here as well as inside run_arm_L.sh ------------------------------
owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
exp="$(sed -n 's/^expires=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
if [[ "$owner" != "${NDT_OWNER:-}" ]] || [[ -z "$exp" ]] || (( exp < $(date +%s) )); then
    echo "🔴 REFUSING: lab.claim owner='$owner' expires='$exp' NDT_OWNER='${NDT_OWNER:-}'" >&2
    exit 1
fi

say "### block ${#ARMS[@]} arms  flow_s=$FLOW_S churn_s=$CHURN_S poll=${POLL_HZ}Hz  start $(date '+%F %H:%M:%S')"
{ echo "round_start=$(date +%s)"; echo "arms=${ARMS[*]}"; echo "flow_s=$FLOW_S churn_s=$CHURN_S"
  echo "churn_seed=$CHURN_SEED poll_hz=$POLL_HZ warm_s=$WARM_S win_s=$WIN_S"; } > "$OUT/round.meta"

# --- PREREG section 6: the poll-perturbation baseline ----------------------------------------
# The northbound API serves one request at a time, so a 10 Hz poller may be perturbing the very
# thing it measures. This runs the sampler against an IDLE fabric first. Without it the whole
# block's M numbers are uninterpretable -- M-quater says so in as many words.
if [[ ! -s "$OUT/pollbase/flows.json" ]]; then
    say "--- poll-only baseline (no traffic, 60 s) ---"
    if pgrep -f 'ndtwin_kerne[l]' >/dev/null; then
        python3 "$HERE/sample_flow_path_latency.py" "$OUT/pollbase" "$POLL_HZ" 60 2>&1 \
            | tee -a "$OUT/progress.txt"
    else
        say "  ⚠️  no kernel running yet; baseline deferred to after the first arm's swap"
    fi
fi

for spec in "${ARMS[@]}"; do
    label="${spec%%:*}"; sha="${spec##*:}"
    ADIR="$OUT/$label"; mkdir -p "$ADIR"
    say ""; say "############ $label  binary=$sha  $(date '+%H:%M:%S') ############"
    echo "arm_start=$(date +%s)" > "$ADIR/arm.meta"; echo "binary=$sha" >> "$ADIR/arm.meta"

    swap_binary_in "$sha" || { say "🔴 $label: could not stage binary $sha"; exit 1; }
    if ! "$L/restart_kernel.sh" "$sha" 2>&1 | tee -a "$OUT/progress.txt"; then
        say "🔴 $label: kernel swap/converge FAILED -- stopping. Later arms not run, so nothing"
        say "   downstream is contaminated by a half-swapped machine."
        exit 1
    fi

    # Deferred baseline: the first arm's kernel is the first one available.
    if [[ ! -s "$OUT/pollbase/flows.json" ]]; then
        say "--- poll-only baseline (no traffic, 60 s) ---"
        python3 "$HERE/sample_flow_path_latency.py" "$OUT/pollbase" "$POLL_HZ" 60 2>&1 \
            | tee -a "$OUT/progress.txt"
    fi

    mark=$(wc -l < "$KLOG")          # attribute divisor lines to THIS arm, not to the file

    # --- steady half: ratio + veth + loop period T, via the amendment-L harness --------------
    rm -f "$L/raw/$label/flows.log"
    ( FLOW_S="$FLOW_S" WARM_S="$WARM_S" FLOW_LIMIT=16 RATE_SCALE=1 T_REPS=1 \
      "$L/run_arm_L.sh" "$label" 0 > "$ADIR/arm_L.log" 2>&1 ) & ARM_PID=$!

    # Wait for the real flow start rather than sleeping a fixed amount: run_plane.sh does a
    # converge precheck of unpredictable length first, and a fixed sleep would drift the churn
    # window off the steady window -- which is the one thing keeping all six arms comparable.
    say "  waiting for steady flows..."
    for _ in $(seq 1 180); do
        [[ -s "$L/raw/$label/flows.log" ]] && break
        kill -0 "$ARM_PID" 2>/dev/null || break
        sleep 1
    done
    if [[ ! -s "$L/raw/$label/flows.log" ]]; then
        say "🔴 $label: steady flows never started"; tail -20 "$ADIR/arm_L.log" | tee -a "$OUT/progress.txt"
        kill "$ARM_PID" 2>/dev/null; exit 1
    fi
    T_FLOWS_UP=$(date +%s)
    echo "t_flows_up=$T_FLOWS_UP" >> "$ADIR/arm.meta"
    say "  steady flows up at $(date '+%H:%M:%S')"

    # --- churn half + the per-flow path sampler ----------------------------------------------
    # Sampler first, five seconds ahead of churn, so no churn flow is left-censored by the
    # sampler starting late. A flow already present on the first poll cannot have its detection
    # latency measured, only bounded.
    sleep 15
    python3 "$HERE/sample_flow_path_latency.py" "$ADIR/pathlat" "$POLL_HZ" "$SAMP_S" \
        > "$ADIR/pathlat.log" 2>&1 & SAMP_PID=$!
    sleep 5
    say "  churn: $CHURN_S s, batch $CHURN_BATCH every $CHURN_EVERY s, seed $CHURN_SEED"
    SEED="$CHURN_SEED" "$M/run_churn.sh" "$ADIR/churn" "$CHURN_S" "$CHURN_EVERY" "$CHURN_BATCH" \
        > "$ADIR/churn.log" 2>&1
    churn_rc=$?
    # run_churn.sh exits non-zero when NO flow moved bytes. That is the failure mode that once
    # produced a whole round of beautiful telemetry over an idle fabric, so it stops the block.
    if (( churn_rc != 0 )); then
        say "🔴 $label: churn FAILED (rc=$churn_rc) -- an arm with no traffic is not an arm."
        tail -6 "$ADIR/churn.log" | tee -a "$OUT/progress.txt"
        kill "$SAMP_PID" 2>/dev/null; kill "$ARM_PID" 2>/dev/null; exit 1
    fi
    say "  churn: $(grep -F 'flows that MOVED DATA' "$ADIR/churn.log" | tail -1 | sed 's/^ *//')"

    wait "$SAMP_PID" 2>/dev/null
    say "  $(tail -1 "$ADIR/pathlat.log")"
    wait "$ARM_PID" 2>/dev/null

    # --- Q's acceptance gate, on THIS arm ----------------------------------------------------
    tail -n +$((mark + 1)) "$KLOG" | grep -F "rate divisor check" > "$ADIR/divisor" || true
    n=$(wc -l < "$ADIR/divisor")
    if [[ "$sha" == "$BASE_SHA" ]]; then
        (( n == 0 )) && say "  ok  baseline: no divisor instrument (ABSENT, not a pass)" \
                     || say "  🔴 baseline emitted $n divisor lines -- the wrong binary ran"
    elif (( n == 0 )); then
        say "  🔴 GATE: no divisor line in $label -- the instrument did not run. NOT a pass."
    else
        python3 - "$ADIR/divisor" 2>&1 <<'PY' | tee -a "$OUT/progress.txt"
import re, sys
rows = []
for line in open(sys.argv[1]):
    m = re.search(r"measured_interval_s=([\d.]+) divisor_used_s=(-?[\d.]+)", line)
    if m:
        rows.append((float(m.group(1)), float(m.group(2))))
if not rows:
    print("  🔴 GATE: lines present but unparseable -- NOT a pass"); raise SystemExit
# A negative divisor means no rate was published in that window: a sentinel, deliberately not 0,
# because 0 is a legal measurement here. Counted separately -- neither a pass nor a failure.
live = [r for r in rows if r[1] >= 0]
worst = max((abs(m - d) / m for m, d in live), default=None)
if not live:
    print(f"  ⚠️  GATE: {len(rows)} lines, all sentinel (no rate published) -- INCONCLUSIVE")
elif worst <= 0.01:
    print(f"  ✅ GATE: {len(live)}/{len(rows)} live, worst {worst:.4%} (<= 1%)")
else:
    print(f"  🔴 GATE: worst deviation {worst:.4%} EXCEEDS 1% over {len(live)} live samples")
PY
    fi

    # Findings land on disk per arm, not at the end of the round: a usage cutoff, a dead session
    # and a context compaction all evaporate whatever is unwritten, and none of them warns you.
    say "  T: $(grep -Eo 'period: [0-9.]+ s over [0-9]+ gaps' "$ADIR/arm_L.log" | tail -1)"
    echo "arm_end=$(date +%s)" >> "$ADIR/arm.meta"
    "$HERE/summarise.py" "$OUT" > "$OUT/READOUT.txt" 2>/dev/null || true

    say "  settling ${SETTLE}s"; sleep "$SETTLE"
done

echo "round_end=$(date +%s)" >> "$OUT/round.meta"
say ""; say "### all ${#ARMS[@]} arms done at $(date '+%F %H:%M:%S')"
"$HERE/summarise.py" "$OUT" 2>&1 | tee "$OUT/READOUT.txt" | tee -a "$OUT/progress.txt"
