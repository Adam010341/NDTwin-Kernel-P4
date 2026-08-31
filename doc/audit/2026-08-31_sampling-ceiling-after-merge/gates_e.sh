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

# -- the UDP counter reader, for G1 -------------------------------------------------------------
#
# 🔴 Sets UDP_INDATAGRAMS.  It is deliberately NOT a command substitution: `abort` ends in
# `exit 9`, and inside $( ) that exits the SUBSHELL only -- the caller would carry on with an
# empty value and the gate would compare two blanks.  That is the exact failure shape the rest
# of this file exists to prevent, so the value comes back through a global instead.
#
# THE BUG THIS REPLACES (found live, 2026-08-31, not by the dry run):
#     grep -A1 '^Udp:' /proc/net/snmp | tail -1 | awk '{print $2}'
# /proc/net/snmp has TWO lines starting `Udp:` (header, values) and the line after the values is
# `UdpLite:`.  `UdpLite:` does not match `^Udp:` -- it is dragged in as the -A1 CONTEXT of the
# values line -- so `tail -1` selects it and $2 is the literal string "InDatagrams".
#
# 🔑 `set -u` made that a crash, which was the lucky direction.  Without it both reads coerce to
# 0, the gate FAILs, and G1 prints its own line: "a counter reads zero against a live ten-switch
# fabric.  That is a broken reader, not a quiet fabric."  The CATEGORY is right and the TARGET is
# wrong -- both counters were fine; the pipeline reading them was not.  A gate that fails while
# pointing at the wrong component costs more than one that stays silent.
#
# The numeric assertion is not an extra guard bolted on: reading a non-number IS the failure
# mode, and without the assertion there is no way to demonstrate that this parse was repaired.
# Forced in both directions -- see FORCE_UDP_NONNUMERIC and the G-UDP rows in the summary.
#
# One expression, one quantity: the old code read the same counter two different ways at the two
# call sites, and only one of them carried the (dead, output-less) `awk '/^Udp:/{u=$0} END{}'`
# fragment.  Two spellings of one reading is how the two ends of a bracket stop being comparable.
# [Co-developed with claude code -- Adam]
udp_indatagrams() {
    local v
    if [[ -n "${FORCE_UDP_NONNUMERIC:-}" ]]; then
        v="$FORCE_UDP_NONNUMERIC"
    else
        v=$(awk '/^Udp:/{getline; print $2; exit}' /proc/net/snmp)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || abort "§2.1" "Udp InDatagrams parsed as '$v', which is not a number.
        /proc/net/snmp was readable, so this is a PARSER fault, not a fabric fault.  Do not go
        looking at the switches or the counters: look at the expression that read them."
    UDP_INDATAGRAMS="$v"
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
    # 🔴 >=3 readings, appended, and the RANGE checked.  The baseline's source is operator
    # behaviour, so one reading is a point sample of a moving quantity: the real detection floor
    # is 0.5 cores PLUS that movement, not 0.5 cores.
    : >"$CPU_BASELINE_FILE"
    local i
    for i in $(seq 1 "${BASELINE_REPEATS:-3}"); do
        "$PY_PROXY" "$HERE/cpu_gate.py" --record-baseline --baseline-file "$CPU_BASELINE_FILE.one" \
            --window "${BASELINE_WINDOW:-60}" 2>&1 | tee -a "$LOG"
        cat "$CPU_BASELINE_FILE.one" >>"$CPU_BASELINE_FILE"
    done
    rm -f "$CPU_BASELINE_FILE.one"
    baseline_range_check "$CPU_BASELINE_FILE" 2>&1 | tee -a "$LOG"
    case "${PIPESTATUS[0]}" in
        0) : ;;
        1) say "🔴 the baseline's own range meets the threshold -- see §0-ter; DISCLOSE this" ;;
        *) abort "§0-ter" "fewer than ${BASELINE_REPEATS:-3} baseline readings; the range is unknown" ;;
    esac
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
    teardown; swap_kernel 1hz; bringup "$BATCH_OFF" || abort "§2.1" "fabric would not come up for the batch_size=1 check"
    assert_batch_took "$BATCH_OFF"
    local dg0 dg1 udp0 udp1
    if [[ "$DRY_RUN" == 1 ]]; then
        dry_note "would read :8081/sflow/stats datagrams_sent twice 6 s apart, and /proc/net/snmp Udp InDatagrams"
        record "G1 §2.1 counters non-zero at batch_size=1" PASS "synthetic"
    else
        dg0=$(curl -sf --max-time 10 http://localhost:8081/sflow/stats | "$PY_PROXY" -c 'import json,sys;print(json.load(sys.stdin)["datagrams_sent"])')
        udp_indatagrams; udp0="$UDP_INDATAGRAMS"
        sleep 6
        dg1=$(curl -sf --max-time 10 http://localhost:8081/sflow/stats | "$PY_PROXY" -c 'import json,sys;print(json.load(sys.stdin)["datagrams_sent"])')
        udp_indatagrams; udp1="$UDP_INDATAGRAMS"
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
    # -- G0 §2 (v0.5): the calibration objects are the SOURCE OF THE THRESHOLDS.  If they change,
    #    the thresholds changed and nobody would notice.  raw*/ is git-ignored on working
    #    branches, so the local copy is unprotected -- the authority is the audit-raw orphan
    #    branch, and both are checked against the values pinned in PREREG §0-bis.
    #
    # 🔴 THE CELLS BELONG TO THE 08-20 ROUND, NOT THE 08-25 ONE.  The 08-25 round owns the READER
    # (cell_verdict.py); it has no t008/t004 files at all, and its raw directories are named
    # raw_n / raw_h / raw_gil -- there is no `raw/` there.  A reader who infers the directory from
    # the round name finds nothing and concludes the dependency is broken; that happened on
    # 2026-08-31.  Copy the paths, never the round name.
    say "--- G0 §2: calibration objects match the values pinned in the registration ---"
    calib_check() {   # $1 = path, $2 = expected sha256
        local ar wt
        if [[ "$DRY_RUN" == 1 ]]; then
            dry_note "would verify $1 against $2 in BOTH audit-raw and the worktree"; return 0
        fi
        ar=$(git -C "$KERNEL_DIR" cat-file blob "audit-raw:$1" 2>/dev/null | sha256sum | cut -d' ' -f1)
        wt=$(sha256sum "$KERNEL_DIR/$1" 2>/dev/null | cut -d' ' -f1)
        [[ "$ar" == "$2" ]] || { say "    🔴 audit-raw copy of $1 is $ar, registered $2"; return 1; }
        [[ "$wt" == "$2" ]] || { say "    🔴 WORKTREE copy of $1 is ${wt:-ABSENT}, registered $2"; return 1; }
        say "    ok  ${1##*/raw/}  $2"
    }
    local cf=0
    calib_check doc/audit/2026-08-20_sampling-rate-and-cpu/raw/t008_poll_twin.jsonl \
        295ab0d46ea830bcf039eb4fab02461b2268527e0a92b8138347d05edcae1d07 || cf=1
    calib_check doc/audit/2026-08-20_sampling-rate-and-cpu/raw/t008_poll_client.json \
        18dbe3884cfcdbff853665c511af7e8765833a5a6a287d5153d3bf6d6b0dc342 || cf=1
    calib_check doc/audit/2026-08-20_sampling-rate-and-cpu/raw/m256_poll_twin.jsonl.gz \
        5bed4f7e3e6097800cc985a1e95eb92464dd3849ff044b59be24ba171390dc79 || cf=1
    calib_check doc/audit/2026-08-20_sampling-rate-and-cpu/raw/m256_poll_client.json \
        69b8842d21d95e1e48438107a3b853200847a638d228c3dc2cc811bc3304a84d || cf=1
    calib_check doc/audit/2026-08-20_sampling-rate-and-cpu/raw/t008_poll_cpu.jsonl \
        fb4d791a23afa03dffc50dd85bc437a06038c3d47e35b5746230ec0b3d72c73d || cf=1
    # 🔴 The selftest's NEGATIVE dependency (PREREG §0-bis-a): its known-bad arm asserts that
    # `r999_poll_does_not_exist` returns NO-DATA.  If somebody ever creates a file by that name,
    # that arm stops testing anything and the selftest still prints PASS.  Absence is a
    # precondition, so it is asserted like one.
    if [[ "$DRY_RUN" != 1 ]]; then
        local ghosts; ghosts=$(ls "$PRIOR_RAW"/r999_poll_does_not_exist_* 2>/dev/null | wc -l)
        (( ghosts == 0 )) || { say "    🔴 $ghosts file(s) named r999_poll_does_not_exist_* exist"; cf=1; }
    else
        dry_note "would assert NO file named r999_poll_does_not_exist_* exists (selftest's known-bad arm)"
    fi
    if (( cf )); then
        record "G0 §2 calibration objects match the registration" FAIL
        abort "§2 calibration" "a calibration object is not the one PREREG §2 pins.
        These four files ARE the thresholds: the ratio gate's green and the selftest's known-good
        both come from them.  A different file is a different threshold, silently."
    fi
    record "G0 §2 calibration objects match the registration" PASS "4 objects, audit-raw and worktree"

    say "--- G7 §2.4 ratio gate force-green: archived 08-20-round cell (PREREG §0-bis) ---"
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

    # -- G8 §4 (v0.3): the running-arm identity check, forced in BOTH directions.
    #    A clause added to a registration is a clause nobody has seen fail.  The failure mode it
    #    guards is "eight arms, one binary, every provenance record still correct", so the check
    #    has to be shown to fire -- and its green has to be shown to come from a COMPARISON rather
    #    than from the check quietly not running.  That is why the pass condition greps for
    #    `verdict=MATCH` and not for exit status 0.
    say "--- G8 §4: running-arm identity, forced both ways ---"
    if [[ "$DRY_RUN" == 1 ]]; then
        local fg fr
        fg=$(DRY_FAIL= check_running_arm "$KBIN_1HZ" || true)
        fr=$(DRY_FAIL=exedrift_absorbed check_running_arm "$KBIN_1HZ" || true)
        local fu; fu=$(DRY_FAIL=exeunreadable_absorbed check_running_arm "$KBIN_1HZ" || true)
        say "    force-green: $fg"
        say "    force-red  : $fr"
        say "    unreadable : $fu"
        if [[ "$fg" == *verdict=MATCH* && "$fr" == *verdict=MISMATCH* && "$fu" == *verdict=UNREADABLE* ]]; then
            record "G8 §4 running-arm identity forced 3 ways" PASS "MATCH/MISMATCH/UNREADABLE all reachable"
        else
            record "G8 §4 running-arm identity forced 3 ways" FAIL "$fg | $fr | $fu"
            abort "§4" "the running-arm check cannot be made to produce all three verdicts."
        fi
    else
        local other_arm this_arm
        this_arm=$(check_running_arm "$KBIN_1HZ" || true)
        # force-red: point the check at the OTHER arm's provenance while the 1 Hz arm runs.
        # This is the live analogue of "the fabric is running a different binary than the record
        # says", which is the whole failure mode.
        other_arm=$(check_running_arm "$KBIN_1KHZ" || true)
        say "    force-green (this arm) : $this_arm"
        say "    force-red   (other arm): $other_arm"
        if [[ "$this_arm" == *verdict=MATCH* && "$other_arm" == *verdict=MISMATCH* ]]; then
            record "G8 §4 running-arm identity forced both ways" PASS
        else
            record "G8 §4 running-arm identity forced both ways" FAIL "$this_arm | $other_arm"
            abort "§4" "the running-arm check did not come out both ways.  If it cannot say
        MISMATCH when pointed at the other arm, it cannot detect the failure it was added for --
        and its greens would mean nothing."
        fi
        record_bmv2_identity gate
    fi

    # -- G9/G10/G11 (v0.4): the three clauses inherited from the D round, each forced RED.
    #    🔴 G9 exists because "restore failure must be loud" is itself a claim that can be
    #    vacuously true.  If nobody has ever seen it shout, it is the second empty pass.
    say "--- G9 #11: restore-failure must actually SHOUT (forced) ---"
    local out9 rc9
    out9=$(DRY_FAIL=restore assert_restore_landed 2>&1); rc9=$?
    say "$out9"
    if (( rc9 != 0 )) && [[ "$out9" == *"DO NOT RELEASE THE LAB"* ]]; then
        # and the clean direction must ALSO come out, or the check is simply always red
        local out9g rc9g; out9g=$(DRY_FAIL= assert_restore_landed 2>&1); rc9g=$?
        if (( rc9g == 0 )); then
            record "G9 #11 restore failure is loud (forced red AND green)" PASS "rc=$rc9 then rc=$rc9g"
        else
            record "G9 #11 restore failure is loud" FAIL "the clean direction did not come out green"
            abort "#11" "assert_restore_landed is red even when nothing is wrong."
        fi
    else
        record "G9 #11 restore failure is loud" FAIL "rc=$rc9"
        abort "#11" "a forced restore failure did not return non-zero AND shout.
        A silent restore failure contaminates the NEXT round in the queue, which cannot see it."
    fi

    say "--- G10 #14: topology invariant must go red on a changed edge count (forced) ---"
    local out10; out10=$( ( EDGE_BASELINE=288; DRY_FAIL=edgecount assert_topology_invariant forced ) 2>&1 || true)
    if [[ "$out10" == *"edge count changed"* ]]; then
        record "G10 #14 topology invariant forced red" PASS
    else
        record "G10 #14 topology invariant forced red" FAIL "$out10"
        abort "#14" "a changed edge count did not trip the invariant."
    fi

    say "--- G11 #3: boot_id change must go red (forced) ---"
    local out11; out11=$( ( BOOT_BASELINE=dry-run-synthetic-boot-id; DRY_FAIL=bootid assert_same_boot forced ) 2>&1 || true)
    if [[ "$out11" == *"REBOOTED mid-round"* ]]; then
        record "G11 #3 boot_id change forced red" PASS
    else
        record "G11 #3 boot_id change forced red" FAIL "$out11"
        abort "#3" "a changed boot_id did not trip the check."
    fi

    # -- G8b §4: the identity BRACKET itself.  G8 above exercises check_running_arm's three
    #    verdicts; it does NOT touch the open/close bracket, and `exedrift` cannot -- it forces
    #    BOTH ends to the same value.  So until now the bracket had zero force coverage while
    #    G8 printed "all reachable", which reads as if it were covered.
    #
    # 🔴 This is §2's own gate-3 rule turning up a second time in the same script family: as many
    # calls as the registration names checks.  `exedriftmid` existed and had NO CALLER here --
    # a fix that exists is not a fix that runs.
    #
    # Two-part pass condition, and the SECOND half is the point:
    #   (i)  the output carries the bracket's own mismatch abort;
    #   (ii) the abort did NOT come from ABORT(§4 running-arm) -- otherwise the earlier check
    #        absorbed it again, which is the third failure mode, not a pass.
    say "--- G8b §4: the identity bracket must be REACHED and must fire on its own terms ---"
    local bout
    bout=$(cd "$HERE" && DRY_RUN=1 DRY_FAIL=exedriftmid LADDER=16 REPS=1 ./run_e.sh ladder 2>&1 || true)
    local hit_bracket=0 absorbed=0
    [[ "$bout" == *"changed mid-cell"* && "$bout" == *"ABORT(identity)"* ]] && hit_bracket=1
    [[ "$bout" == *"ABORT(§4 running-arm)"* ]] && absorbed=1
    say "    bracket abort present: $hit_bracket   absorbed by the earlier check: $absorbed"
    if (( hit_bracket == 1 && absorbed == 0 )); then
        say "    $(grep -m1 'changed mid-cell' <<<"$bout" | sed 's/^ *//')"
        record "G8b §4 identity bracket reached and fired" PASS "not absorbed by assert_running_arm"
    else
        record "G8b §4 identity bracket reached and fired" FAIL "hit=$hit_bracket absorbed=$absorbed"
        abort "§4" "the identity bracket is still not covered by any force.
        hit_bracket=$hit_bracket absorbed=$absorbed
        A bracket that no force reaches cannot be said to detect a mid-cell binary swap, which is
        the only reason it exists."
    fi

    # =============================================================================================
    # G-MATRIX -- every force this round defines, run from ONE table.
    #
    # 🔑 The point is not brevity, it is turning step 0 of the force audit ("does this force have a
    # caller?") from an AUDIT into an INVARIANT.  Before: somebody had to periodically grep for
    # forces with no caller -- and today proved nobody does; `exedriftmid` was written, verified by
    # hand in a report, and never called by a gate.  After: adding a force means adding a ROW, and
    # a row runs.  There is no "exists but is never invoked" state left to hide in.
    #
    # 🔑 It also makes the count self-maintaining.  The last hand-written list said "six" and named
    # seven.  A table has as many rows as it has; nobody counts.
    #
    # Columns:  label | env prefix | driver args | must contain | must NOT contain
    # "must NOT contain" is how a force proves it reached ITS OWN check rather than being absorbed
    # by an earlier one -- the failure mode that wore a green badge twice today.
    # =============================================================================================
    local EV_BAD EV_GOOD
    EV_BAD="$(mktemp)"; EV_GOOD="$(mktemp)"
    # 🔴 The evidence force reads a FIXTURE, never the master registration.  Reading the master
    # during its own force is the circularity (the gate reads a field the gate's own result
    # updates); a fixture removes it while keeping the coverage, because what is under test is the
    # READER, not the file.  And it gets a positive control: the same reader must PASS on
    # COMPLETE.  Testing only the refusal would leave the accept path unobserved -- exactly the
    # thing this round has recorded about guards that can only be watched refusing.
    printf 'EVIDENCE-BASIS: INCOMPLETE\n' >"$EV_BAD"
    printf 'EVIDENCE-BASIS: COMPLETE\n'   >"$EV_GOOD"

    local FORCE_MATRIX=(
      "claim||ladder|REFUSE: lab.claim owner=|"
      "staged||ladder|REFUSE: staged kernel binary missing|"
      "iperf3||ladder|REFUSE: iperf3 already running|"
      "fabric||ladder|REFUSE: no live P4 fabric|"
      # The reader for a neighbouring round's not-restored marker.  Before this the
      # marker had three writers and zero readers repo-wide.
      "labmarker||ladder|REFUSE: a neighbouring round left the lab un-restored|"
      "restore||ladder|PRODUCTION RESTORE FAILED|"
      "edgecount|REPS=2|ladder|ABORT(#14 invariant)|"
      "bootid|REPS=2|ladder|ABORT(#3 boot_id)|"
      "recompute||ladder|ABORT(§4-bis)|"
      "exedriftmid||ladder|ABORT(identity)|ABORT(§4 running-arm)"
      "exeunreadablemid||ladder|could not be READ|ABORT(§4 running-arm)"
      "exeunreadable_absorbed||ladder|ABORT(§4 running-arm)|"
      "exedrift_absorbed||ladder|ABORT(§4 running-arm)|"
      "@none@|PREREG_FILE=$EV_BAD|ladder|EVIDENCE-BASIS: INCOMPLETE|"
      "@none@|PREREG_FILE=$EV_GOOD|ladder|@COMPLETES@|REFUSE"
    )

    say "--- G-MATRIX: ${#FORCE_MATRIX[@]} forces, one row each ---"
    local row lbl envp args want deny out ok fails=0
    for row in "${FORCE_MATRIX[@]}"; do
        IFS='|' read -r lbl envp args want deny <<<"$row"
        out=$(cd "$HERE" && env $envp DRY_RUN=1 \
              $( [[ "$lbl" != "@none@" ]] && printf 'DRY_FAIL=%s' "$lbl" ) \
              LADDER=16 REPS="${REPS:-1}" ./run_e.sh $args 2>&1 || true)
        ok=1
        if [[ "$want" == "@COMPLETES@" ]]; then
            [[ "$out" == *"ladder complete"* ]] || ok=0
        else
            [[ "$out" == *"$want"* ]] || ok=0
        fi
        [[ -n "$deny" && "$out" == *"$deny"* ]] && ok=0
        if (( ok )); then
            say "    [ok]   ${lbl}${envp:+ ($envp)} -> ${want}"
        else
            say "    [FAIL] ${lbl}${envp:+ ($envp)} -> wanted '${want}'${deny:+, not '${deny}'}"
            fails=$((fails+1))
        fi
    done
    rm -f "$EV_BAD" "$EV_GOOD"
    if (( fails )); then
        record "G-MATRIX all ${#FORCE_MATRIX[@]} forces reach their own check" FAIL "$fails failing"
        abort "§2" "$fails force(s) did not reach the check they name.
        A force that never reaches its own assertion is documentation, not a test."
    fi
    record "G-MATRIX all ${#FORCE_MATRIX[@]} forces reach their own check" PASS

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
