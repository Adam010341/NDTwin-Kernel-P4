#!/usr/bin/env bash
# Ticket W: do finished flows OUTRANK live ones in the top-k the energy app consumes?
#
# Two arms on one fabric generation, baseline then this branch, each: churn traffic while polling
# top-k at 1 Hz with RANK recorded, then keep polling 40 s after the traffic stops. The tail is
# the point -- that is when every flow is dead and the list should be empty of live ones.
#
# The original question ("do both arms return ~50 records of which ~45 read zero") measured the
# PROPORTION of corpses. The severity claim is about ORDER, because the consumer reads the top of
# the list, so this records each record's rank.
#
# Usage: NDT_OWNER=... drive_topk.sh
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
L="$REPO/doc/audit/2026-08-25_large-scale-concurrent"
M="$REPO/doc/audit/2026-08-27_1khz-path-recompute"
OUT="$HERE/raw_topk"; mkdir -p "$OUT"
BIN="$REPO/.test_run/binaries"
CHURN_S=120; TAIL_S=40

owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
[[ "$owner" == "${NDT_OWNER:-}" ]] || { echo "🔴 lab.claim owner='$owner' != '${NDT_OWNER:-}'"; exit 1; }

swap_binary_in() {   # copy-then-rename: cp onto a running kernel is ETXTBSY
    cp -p "$BIN/ndtwin_kernel.$1" "$REPO/build/bin/.ndtwin_kernel.staged" || return 1
    mv -f "$REPO/build/bin/.ndtwin_kernel.staged" "$REPO/build/bin/ndtwin_kernel" || return 1
}

for spec in W_base:3367d0e9 W_branch:a40e04ce; do
    label="${spec%%:*}"; sha="${spec##*:}"
    echo; echo "############ $label  binary=$sha  $(date '+%H:%M:%S') ############"
    mkdir -p "$OUT/$label"
    swap_binary_in "$sha" || { echo "🔴 could not stage $sha"; exit 1; }
    "$L/restart_kernel.sh" "$sha" || { echo "🔴 $label: swap/converge failed"; exit 1; }

    # Poller first and running through the whole churn AND the tail: the tail is where the
    # question lives, so it must not depend on the churn script exiting cleanly.
    python3 "$HERE/sample_topk_rank.py" "$OUT/$label" 1 $((CHURN_S + TAIL_S + 10)) 50 \
        > "$OUT/$label/topk.log" 2>&1 & TP=$!
    sleep 3
    SEED=20260828 "$M/run_churn.sh" "$OUT/$label/churn" "$CHURN_S" 5 4 \
        > "$OUT/$label/churn.log" 2>&1
    rc=$?
    echo "  churn rc=$rc: $(grep -F 'flows that MOVED DATA' "$OUT/$label/churn.log" | tail -1 | sed 's/^ *//')"
    (( rc != 0 )) && { echo "🔴 $label: no traffic -- not an arm"; kill "$TP" 2>/dev/null; exit 1; }
    echo "  traffic stopped $(date '+%H:%M:%S'); polling the tail for ${TAIL_S}s"
    echo "t_traffic_stop=$(date +%s)" > "$OUT/$label/arm.meta"
    echo "binary=$sha" >> "$OUT/$label/arm.meta"
    wait "$TP" 2>/dev/null
    echo "  $(tail -1 "$OUT/$label/topk.log")"
done
echo; echo "### top-k arms done $(date '+%H:%M:%S')"
