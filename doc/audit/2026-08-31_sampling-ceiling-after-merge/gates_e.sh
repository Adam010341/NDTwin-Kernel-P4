#!/usr/bin/env bash
# =================================================================================================
# gates_e.sh -- PREREG-E §2's pre-conditions, one call per registered check.
#
# [Co-developed with claude code -- Adam]
#
# 🔴 THE RULE THIS FILE EXISTS TO OBEY.  PREREG §2.3: "as many checks as the pre-registration
# names, that many calls in the script".  The D round listed three checks and gate_d.sh called
# two; the review found it by grep.  So every check below is numbered with the §2 item it
# implements, and the run ends by printing the map, so the two greps can be laid side by side
# without reading either file.
#
#   G1  §2.1  the counters read something at batch_size=1
#   G2  §2.2  no silent wipeout: ratio >= 0.95, samples non-zero, lambda same order, distinct > 0
#   G3  §2.3  cell_verdict.py --selftest, CALLED not merely registered
#   G4  §2.4  CPU gate forced RED   (a burner known to eat one core)
#   G5a §2.4  CPU gate forced GREEN (i)  idle fabric        -- proves it CAN be green
#   G5b §2.4  CPU gate forced GREEN (ii) a normal arm's own load -- proves it does not
#             misreport the experiment itself as contamination      [reviewer-review E3b]
#   G6  §2.4  ratio gate forced RED   (tail 20% of samples zeroed)
#   G7  §2.4  ratio gate forced GREEN (an archived 08-25 D-round cell)
#
# 🔑 §2 line 44 says "four forces"; E3b then splits the CPU force-green into two segments, which
# makes five.  This script runs five and labels them; see TBD-DRAFT.md D11.
#
# ANY gate not coming out as forced STOPS THE ROUND.  There is no branch here that lowers a
# threshold, and `abort` exits.
#
# Usage:
#     . doc/audit/2026-08-31_sampling-ceiling-after-merge/round.env
#     ./gates_e.sh                 # real; refuses without a claimed, exclusive, live fabric
#     DRY_RUN=1 ./gates_e.sh       # whole control flow, no side effects, full transcript
#     DRY_RUN=1 DRY_FAIL=fabric ./gates_e.sh    # and the refusal branch
# =================================================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${ROUND:-}" ]] || . "$HERE/round.env"
LOG="$ROUND/gates_e.log"
# shellcheck source=lib_e.sh
. "$HERE/lib_e.sh"

GATE_LOG="$OUT/gates.jsonl"
PASSED=(); FAILED=()

record() { if [[ "$2" == PASS ]]; then PASSED+=("$1"); else FAILED+=("$1"); fi
           say "  [$2] $1  ${3:-}"; }

# The interpreter check is first because every ratio-side gate depends on it and because a
# python3 that cannot import the round's modules would otherwise fail four gates in a row with
# four different-looking errors.
check_interpreter() {
    if [[ "$DRY_RUN" == 1 ]]; then dry_note "would verify PY_PLOT can import plot_figures/plot_ladder_rates"; return 0; fi
    "$PY_PLOT" -c "
import sys; sys.path.insert(0, '$PRIOR'); import plot_figures, plot_ladder_rates" 2>/dev/null && return 0
    printf 'REFUSE: PY_PLOT=%s cannot import the round modules.\n' "$PY_PLOT" >&2
    printf '        cell_verdict.py imports plot_figures and plot_ladder_rates; the system and\n' >&2
    printf '        conda pythons share a binary with the venv but not its site-packages.\n' >&2
    printf '        Set PY_PLOT to an interpreter that has them and re-run.\n' >&2
    return 1
}

# -- the burner, for G4 -----------------------------------------------------------------------
# awk, not python: the gate exempts the proxy by the socket it holds and everything else by
# `comm`, and a python burner would be indistinguishable from the proxy for anybody reading the
# attribution table later.  awk is on nobody's allow list, which is the point.
#
# Started plainly and its PID captured immediately -- never `$!` from inside a subshell or a
# pipeline, where it names something else (memory/process-liveness-checks-lie-in-two-ways) -- and
# the capture is then CHECKED against /proc/<pid>/comm before anything is concluded from it.
# Stopped by that PID.  Never `pkill -f`.
BURNER_PID=""
burner_start() {
    if [[ "$DRY_RUN" == 1 ]]; then dry_note "would start: awk 'BEGIN{while(1){}}' and record its PID"; BURNER_PID=DRYRUN; return 0; fi
    awk 'BEGIN{while(1){}}' >/dev/null 2>&1 &
    BURNER_PID=$!
    sleep 1
    local comm; comm=$(cat "/proc/$BURNER_PID/comm" 2>/dev/null || echo MISSING)
    if [[ "$comm" != awk ]]; then
        say "    burner did not start (pid=$BURNER_PID comm=$comm)"
        return 1
    fi
    say "    burner pid=$BURNER_PID comm=$comm"
}
burner_stop() {
    [[ -n "$BURNER_PID" && "$BURNER_PID" != DRYRUN ]] || { dry_note "would stop the burner by recorded PID"; return 0; }
    kill "$BURNER_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 10); do [[ -d "/proc/$BURNER_PID" ]] || { say "    burner stopped"; BURNER_PID=""; return 0; }; sleep 1; done
    kill -9 "$BURNER_PID" 2>/dev/null || true; sleep 1
    [[ -d "/proc/$BURNER_PID" ]] && say "    🔴 burner $BURNER_PID would not die -- do NOT measure on this machine"
    BURNER_PID=""
}
trap 'burner_stop' EXIT

cpu_gate() {   # $1 = label, $2 = expect (green|red), $3.. = extra args
    local label="$1" expect="$2"; shift 2
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run: $PY_PROXY $HERE/cpu_gate.py --label $label --expect $expect --threshold $CPU_GATE_FOREIGN_CORES --baseline-file $CPU_BASELINE_FILE --out $GATE_LOG $*"
        return 0
    fi
    "$PY_PROXY" "$HERE/cpu_gate.py" --label "$label" --expect "$expect" \
        --threshold "$CPU_GATE_FOREIGN_CORES" --baseline-file "$CPU_BASELINE_FILE" \
        --out "$GATE_LOG" "$@" 2>&1 | tee -a "$LOG"
    return "${PIPESTATUS[0]}"
}

# The idle baseline the CPU gate judges against.  It MUST be taken with the fabric DOWN, which is
# why it is its own mode rather than a step of main: an "idle" reading taken while ten bmv2
# switches are running would fold the experiment's own load into the baseline and the gate could
# then never see a fabric-sized contamination at all.
baseline_mode() {
    say "=== gates_e baseline (fabric must be DOWN) ==="
    preflight plan || exit 2
    # DRY_FAIL=fabricup makes this refusal reachable in a dry run too: a branch that can
    # only ever be exercised live is a branch nobody has tested.
    if { [[ "$DRY_FAIL" == fabricup ]]; } || { fabric_is_up && [[ "$DRY_RUN" != 1 ]]; }; then
        printf 'REFUSE: the fabric is UP.  A baseline taken now would include the fabric, and the\n' >&2
        printf '        gate would then be blind to exactly the magnitude of load it exists to see.\n' >&2
        printf '        Take the baseline before bringing anything up.\n' >&2
        exit 1
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run: $PY_PROXY $HERE/cpu_gate.py --record-baseline --baseline-file $CPU_BASELINE_FILE --window 60"
        return 0
    fi
    RUN mkdir -p "$(dirname "$CPU_BASELINE_FILE")"
    "$PY_PROXY" "$HERE/cpu_gate.py" --record-baseline --baseline-file "$CPU_BASELINE_FILE" \
        --window "${BASELINE_WINDOW:-60}" 2>&1 | tee -a "$LOG"
}

# =================================================================================================
main() {
    say "=== gates_e start (PREREG-E §2), DRY_RUN=$DRY_RUN ==="
    preflight gates || { say "preflight refused -- nothing below ran"; exit 2; }
    if [[ ! -s "$CPU_BASELINE_FILE" && "$DRY_RUN" != 1 ]]; then
        printf 'REFUSE: no CPU baseline at %s.\n' "$CPU_BASELINE_FILE" >&2
        printf '        Run `./gates_e.sh baseline` with the fabric down first.  Without it the\n' >&2
        printf '        CPU gate has no green: this machine idles near 0.84 foreign cores.\n' >&2
        exit 1
    fi
    check_interpreter || exit 2
    record_identity "gates" "$(git -C "$KERNEL_DIR" rev-parse HEAD)"

    # -- G3 first: everything numeric below is read through cell_verdict, so if its selftest does
    #    not pass, no other reading in this file means anything.  §2.3.
    local st
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run: $PY_PLOT $ROUND25/cell_verdict.py --selftest"
        st="SELFTEST PASS (synthetic)"
    else
        st=$(PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" "$ROUND25/cell_verdict.py" --selftest 2>&1 | tail -1)
    fi
    case "$st" in
        *PASS*) record "G3 §2.3 cell_verdict --selftest" PASS "$st" ;;
        *)      record "G3 §2.3 cell_verdict --selftest" FAIL "$st"
                abort "§2.3" "cell_verdict selftest did not pass: $st" ;;
    esac

    # -- G1 §2.1: the counters read something at batch_size=1.  The same trap twice is what this
    #    guards: gate_d's first byte counter returned 0 against a live fabric, and 0 is exactly
    #    the reading the gate exists to make.  Two independent counters, both must be non-zero.
    say "--- G1 §2.1: counters readable at batch_size=$BATCH_OFF ---"
    teardown; bringup "$BATCH_OFF" || abort "§2.1" "fabric would not come up for the batch_size=1 check"
    assert_batch_took "$BATCH_OFF"
    local dg0 dg1 udp0 udp1
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would read :8081/sflow/stats datagrams_sent twice 6 s apart, and /proc/net/snmp Udp InDatagrams"
        record "G1 §2.1 counters non-zero at batch_size=1" PASS "synthetic"
    else
        dg0=$(curl -sf --max-time 10 http://localhost:8081/sflow/stats | "$PY_PROXY" -c 'import json,sys;print(json.load(sys.stdin)["datagrams_sent"])')
        udp0=$(awk '/^Udp:/{u=$0} END{}' /proc/net/snmp; grep -A1 '^Udp:' /proc/net/snmp | tail -1 | awk '{print $2}')
        sleep 6
        dg1=$(curl -sf --max-time 10 http://localhost:8081/sflow/stats | "$PY_PROXY" -c 'import json,sys;print(json.load(sys.stdin)["datagrams_sent"])')
        udp1=$(grep -A1 '^Udp:' /proc/net/snmp | tail -1 | awk '{print $2}')
        say "    sflow datagrams_sent delta=$(( dg1 - dg0 ))   udp InDatagrams delta=$(( udp1 - udp0 ))"
        if (( dg1 - dg0 > 0 && udp1 - udp0 > 0 )); then
            record "G1 §2.1 counters non-zero at batch_size=1" PASS "sflow=+$((dg1-dg0)) udp=+$((udp1-udp0))"
        else
            record "G1 §2.1 counters non-zero at batch_size=1" FAIL "sflow=+$((dg1-dg0)) udp=+$((udp1-udp0))"
            abort "§2.1" "a counter reads zero against a live ten-switch fabric.  That is a broken
        reader, not a quiet fabric, and every ceiling reading in this round would inherit it."
        fi
    fi

    # -- G5a §2.4 force-green (i): idle fabric.  Taken HERE, while the fabric is up and nothing is
    #    offering load, because that is what "idle" means and it cannot be staged later.
    say "--- G5a §2.4 force-green (i): idle fabric must be GREEN ---"
    if cpu_gate forcegreen_idle green --window 20; then
        record "G5a §2.4 CPU gate force-green (idle)" PASS
    else
        record "G5a §2.4 CPU gate force-green (idle)" FAIL
        abort "§2.4" "the CPU gate is not green on an idle, exclusively-claimed fabric.  Either
        something foreign is running (find it in the attribution table above) or the allow list
        is too narrow.  Fix the gate; do not raise the threshold."
    fi

    # -- G4 §2.4 force-red: a burner known to eat one core.
    say "--- G4 §2.4 force-red: burner must turn the CPU gate RED ---"
    burner_start || abort "§2.4" "the burner would not start, so the force-red never happened"
    if cpu_gate forcered_burner red --window 20; then
        record "G4 §2.4 CPU gate force-red (burner)" PASS
    else
        record "G4 §2.4 CPU gate force-red (burner)" FAIL
        burner_stop
        abort "§2.4" "a process burning a whole core did NOT turn the gate red.  The allow list is
        too wide, or the threshold is too high.  Every green reading in this round would be
        uninformative.  Fix the gate."
    fi
    burner_stop

    # -- G5b §2.4 force-green (ii): the fabric under a NORMAL arm's own load.
    #    🔴 This is the segment that matters.  (i) alone is the 08-30 second bad-gate shape --
    #    "it passed because there was nothing there".  If a normal arm's own load reads as
    #    contamination, the gate would demand re-running exactly the arms that carry the result,
    #    which is how the ③ round's gate died.  Not green => the THRESHOLD is wrong; stop and fix
    #    the gate.  Do not shrink the arm to fit it.
    say "--- G5b §2.4 force-green (ii): a normal arm's own load must ALSO be GREEN ---"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would start the round's own offered load (measure.sh cell g_gate_load) and run the gate during it"
        record "G5b §2.4 CPU gate force-green (own load)" PASS "synthetic"
    else
        foreign_iperf3_guard || abort "§2.4" "cannot start the round's own load safely"
        POLL=on "$PRIOR/measure.sh" g_gate_load 90 "$RATE_MBIT" >>"$LOG" 2>&1 &
        local load_pid=$!
        sleep 20
        if cpu_gate forcegreen_ownload green --window 40 --exempt-pid "$load_pid"; then
            record "G5b §2.4 CPU gate force-green (own load)" PASS
        else
            record "G5b §2.4 CPU gate force-green (own load)" FAIL
            wait "$load_pid" 2>/dev/null || true
            abort "§2.4" "the CPU gate reports the experiment's OWN load as contamination.  PREREG
        §2.4(ii): the gate's threshold is wrong.  Stop the round and fix the gate; it is
        explicitly forbidden to adjust the arms to suit it."
        fi
        wait "$load_pid" 2>/dev/null || true
        archive_cell g_gate_load
    fi

    # -- G2 §2.2: no silent wipeout on the cell just measured.  ratio, samples, lambda, distinct.
    #    Four conditions, four assertions -- "healthy" is not one word here.
    say "--- G2 §2.2: no silent wipeout ---"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run cell_verdict on g_gate_load and assert ratio>=0.95, lam>0, distinct>0, mark has no NO-DATA"
        record "G2 §2.2 no silent wipeout" PASS "synthetic"
    else
        local v; v=$(PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" "$ROUND25/cell_verdict.py" g_gate_load 2>&1 | tail -1)
        say "    $v"
        local lam distinct
        lam=$(sed -n 's/.*[[:space:]]lam=\([0-9.e+-]*\).*/\1/p' <<<"$v")
        distinct=$(sed -n 's/.*[[:space:]]distinct=\([0-9]*\).*/\1/p' <<<"$v")
        if [[ "$v" == *NO-DATA* ]] || [[ -z "${lam:-}" ]] || [[ "${distinct:-0}" == 0 ]] \
           || ! awk -v l="${lam:-0}" 'BEGIN{exit !(l>0)}'; then
            record "G2 §2.2 no silent wipeout" FAIL "$v"
            abort "§2.2" "the gate cell shows a silent wipeout (lam=${lam:-?} distinct=${distinct:-?}).
        A ladder run on top of this would read a dead telemetry path as a discovered ceiling."
        fi
        record "G2 §2.2 no silent wipeout" PASS "lam=$lam distinct=$distinct"
    fi

    # -- G7 §2.4 ratio force-green, then G6 force-red.  Green first, deliberately: it establishes
    #    that the reader can reach and score an archived cell at all, so a red below is a verdict
    #    about the injected data rather than about a path that reads nothing.
    say "--- G7 §2.4 ratio gate force-green: archived 08-25 D-round cell ---"
    local goodcell="${RATIO_GOOD_CELL:-t008_poll}"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run: $PY_PLOT $HERE/ratio_gate.py --check $goodcell --expect green"
        record "G7 §2.4 ratio gate force-green ($goodcell)" PASS "synthetic"
    elif PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" "$HERE/ratio_gate.py" --check "$goodcell" --expect green 2>&1 | tee -a "$LOG"; then
        record "G7 §2.4 ratio gate force-green ($goodcell)" PASS
    else
        record "G7 §2.4 ratio gate force-green ($goodcell)" FAIL
        abort "§2.4" "the ratio gate is not green on a known-good archived cell.  The reader, not
        the fabric, is what is broken."
    fi

    say "--- G6 §2.4 ratio gate force-red: tail 20% of samples zeroed ---"
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would run: $PY_PLOT $HERE/ratio_gate.py --make-forcered $goodcell e_gate_forcered_trunc20"
        dry_note "  (which itself asserts the source is green BEFORE and the product is red AFTER)"
        record "G6 §2.4 ratio gate force-red (tail 20% zeroed)" PASS "synthetic"
    elif PYTHONDONTWRITEBYTECODE=1 "$PY_PLOT" "$HERE/ratio_gate.py" \
            --make-forcered "$goodcell" e_gate_forcered_trunc20 --tail-frac 0.20 2>&1 | tee -a "$LOG"; then
        record "G6 §2.4 ratio gate force-red (tail 20% zeroed)" PASS
    else
        record "G6 §2.4 ratio gate force-red (tail 20% zeroed)" FAIL
        abort "§2.4" "the ratio gate did not go red on data with a fifth of its samples removed.
        It cannot detect the failure it is deployed to detect -- and PREREG §3b names that exact
        shape ('_pending not flushed at the end') as the most likely batching bug."
    fi

    say ""
    say "=== gates_e summary (PREREG §2 item -> call, for the grep-against-grep check) ==="
    local g; for g in "${PASSED[@]+"${PASSED[@]}"}"; do say "  PASS  $g"; done
    for g in "${FAILED[@]+"${FAILED[@]}"}"; do say "  FAIL  $g"; done
    if (( ${#FAILED[@]} )); then
        say "🔴 ${#FAILED[@]} gate(s) failed -- the ladder must not run."
        restore_production || true
        exit 1
    fi
    say "=== all §2 gates green.  run_e.sh may proceed. ==="
    restore_production || say "🔴 production restore FAILED -- check before releasing the lab"
}

case "${1:-gates}" in
    baseline) baseline_mode ;;
    gates)    main "$@" ;;
    *) printf 'usage: %s {gates|baseline}\n' "$0" >&2; exit 2 ;;
esac
