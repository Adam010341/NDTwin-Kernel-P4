#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_chaos_runner_wiring.py (FINDINGS-ALL #75).
#
# [Co-developed with claude code -- Adam]
#
# #17 fixed INV-01's latency check. #75 is that nothing called it: `chaos.py` ran
# `inv01_power_state_agreement` and stopped, so the latency half had zero call sites in the
# repo and no round has ever evaluated it. The fix wires it into the round -- which can go
# wrong in two opposite directions, so the mutations run in both:
#
#   W1-W7  take a piece of the wiring back out       -> a named case must go red
#   X1-X3  WIDEN it without breaking the contract    -> every case must stay GREEN
#   U1     an inert edit that cannot change behaviour -> must SURVIVE
#
# The X block is the half that is easy to skip. A test suite pinned to prose, to an exact
# evidence dict, or to the spelling of a verdict constant would kill X1-X3 -- and a gate that
# scores those as catches is rewarding a suite that will go red on the next reword, which is
# how a gate stops being run. The contract is: both INV-01 checks are evaluated, reported
# separately with a duration and the threshold it was judged against, a round with no power-on
# to time says NOT MEASURED and sends nothing, and the round fails if either check fails.
# Everything else is free to change.
#
# U1 is the scorer's own control. A gate that has never printed SURVIVED cannot be trusted to
# print it: if the baseline were red, or `report` matched the wrong thing, every line would
# read "caught" and the tally would be a decoration. U1 changes a comment, so the tests MUST
# stay green, and the gate fails if it is reported as a catch.
#
# 🔴 An UNAPPLICABLE mutation is scored a SURVIVOR, never a catch. If an anchor has been
# reworded away, this gate has proved nothing about that mutation and says so on the tally
# line -- the failure mode `tests/shell/check_gate_anchors.py` exists for is a gate whose
# anchors have drifted while its output still looks orderly.
#
# 🔴 Guards its own baseline. Mutations are applied to a COPY of the harness in a temp dir and
# the test is pointed at the copy with NDT_CHAOS_HARNESS; the files under
# doc/audit/2026-08-28_chaos-harness/harness/ are never written -- other sessions are reading
# this worktree right now. Anchor counts are taken from the REAL files, so a reworded source
# reports a missing anchor here and in tests/shell/check_gate_anchors.py.
#
# NDT_KERNEL_REPO pins the route table to the real src/ndt_core/http/HttpSession.cpp, so a
# mutation to the harness never also mutates the authority the harness is checked against.
#
# Usage:  bash tests/shell/mutate_chaos_runner_wiring.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

HARNESS_DIR=doc/audit/2026-08-28_chaos-harness/harness
CHAOS="$HARNESS_DIR/chaos.py"
INVARIANTS="$HARNESS_DIR/invariants.py"
ANTIORACLE="$HARNESS_DIR/antioracle.py"
TEST=tests/python/test_chaos_runner_wiring.py
PY="${PY:-python3}"

BK="$(mktemp -d /tmp/chaos-wiring-mutate-XXXXXX)"
trap 'rm -rf "$BK"' EXIT
BASE_CHAOS="$(sha256sum "$CHAOS" | cut -d' ' -f1)"
BASE_INV="$(sha256sum "$INVARIANTS" | cut -d' ' -f1)"
BASE_AO="$(sha256sum "$ANTIORACLE" | cut -d' ' -f1)"

SURVIVORS=0
MUTATIONS=0
WIDENINGS=0
BROKEN_WIDENINGS=0
UNAPPLICABLE=0

# fresh_copy -- an unmutated copy of the harness in $BK/<tag>, and echo its path.
fresh_copy() {
    local tag dst
    tag="$1"
    dst="$BK/$tag"
    rm -rf "$dst"; mkdir -p "$dst"
    cp "$REPO/$HARNESS_DIR"/*.py "$dst"/
    echo "$dst"
}

# apply_exact <repo-relative file> <old> <new> <copy dir> -- assert the anchor is unique in the
# REAL file, then write the replacement into the copy. Never writes the real file. A
# substitution that matched nothing would leave the copy unmutated and score a green as
# "caught", which is the one result a gate must never produce by accident -- so a missing or
# duplicated anchor is reported UNAPPLICABLE and counted as a survivor.
apply_exact() {
    local file="$1" from="$2" to="$3" dst="$4" n base
    base="$(basename "$file")"
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 UNAPPLICABLE: anchor appears $n time(s) in $file, expected 1 -- counted as a"
        echo "     SURVIVOR, because this gate has proved nothing about that mutation."
        echo "     anchor: $from"
        UNAPPLICABLE=$((UNAPPLICABLE + 1))
        return 1
    fi
    FROM="$from" TO="$to" perl -0777 -pe 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' \
        "$file" > "$dst/$base"
}

# report <label> <copy dir> <test case that must go red>
report() {
    local label="$1" dir="$2" want="$3" out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ ! -d "$dir" ]]; then
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (never applied)\n' "$label"
        return
    fi
    out="$(NDT_CHAOS_HARNESS="$dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $want\b" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$label" "$want"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$label" "$want"
        grep -E "^(FAIL|ERROR|OK|Ran )" <<<"$out" | sed 's/^/             /'
    fi
}

# must_survive <label> <copy dir> -- the other direction. A widening, or an edit that cannot
# change behaviour, must leave the whole suite GREEN. Red here means the suite is pinned to
# something that is not the contract.
must_survive() {
    local label="$1" dir="$2" out rc
    WIDENINGS=$((WIDENINGS + 1))
    out="$(NDT_CHAOS_HARNESS="$dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" -v 2>&1)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  survived %-58s (all green, as required)\n' "$label"
    else
        BROKEN_WIDENINGS=$((BROKEN_WIDENINGS + 1))
        printf '  🔴 KILLED %-57s (the suite went red on a change the contract permits)\n' "$label"
        grep -E "^(FAIL|ERROR)" <<<"$out" | sed 's/^/             /'
    fi
}

echo "baseline (must be green before any mutation):"
base_dir="$(fresh_copy base)"
NDT_CHAOS_HARNESS="$base_dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" 2>&1 | tail -2 | sed 's/^/  /'
if ! NDT_CHAOS_HARNESS="$base_dir" NDT_KERNEL_REPO="$REPO" "$PY" "$TEST" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    exit 2
fi
echo

# --- W: the wiring, taken back out one piece at a time ------------------------------------------

d="$(fresh_copy w1)"
apply_exact "$CHAOS" \
  '        if inv_id == I.INV01:' \
  '        if False:' "$d" || d=""
report "W1: the call is removed again (finding #75 itself)" "$d" \
       "test_the_latency_check_reaches_the_round_report"

d="$(fresh_copy w2)"
apply_exact "$INVARIANTS" \
  'A1_FAST_S = 0.1' \
  'A1_FAST_S = 0.0' "$d" || d=""
report "W2: the threshold is widened so every latency passes" "$d" \
       "test_a_duration_on_the_failing_side_of_the_threshold_fails_the_round"

d="$(fresh_copy w3)"
apply_exact "$CHAOS" \
  '        return I.Finding(I.INV01_LATENCY, NOT_MEASURED, f"not measured -- {chance.why}",' \
  '        return I.Finding(I.INV01_LATENCY, PASS, f"not measured -- {chance.why}",' "$d" || d=""
report "W3: 'not measured' is scored as a pass" "$d" \
       "test_a_healthy_fabric_reports_not_measured_and_sends_nothing"

d="$(fresh_copy w4)"
apply_exact "$CHAOS" \
  '    failed = [f.inv for f in findings if f.verdict == FAIL]' \
  '    failed = [f.inv for f in findings if f.verdict == FAIL and f.inv != I.INV01_LATENCY]' "$d" || d=""
report "W4: the round verdict stops counting the latency check" "$d" \
       "test_a_duration_on_the_failing_side_of_the_threshold_fails_the_round"

d="$(fresh_copy w5)"
apply_exact "$CHAOS" \
  '    f.evidence.update({"threshold_s": I.A1_FAST_S, "honest_reference_s": I.A1_HONEST_S,' \
  '    f.evidence.update({"honest_reference_s": I.A1_HONEST_S,' "$d" || d=""
report "W5: the report drops the threshold it judged by" "$d" \
       "test_the_latency_row_carries_its_measurement_and_its_threshold"

d="$(fresh_copy w6)"
apply_exact "$CHAOS" \
  '                         {"elapsed_s": None, "threshold_s": I.A1_FAST_S,' \
  '                         {"elapsed_s": 0.0, "threshold_s": I.A1_FAST_S,' "$d" || d=""
report "W6: an unmeasured duration is written as 0.0, not null" "$d" \
       "test_a_healthy_fabric_reports_not_measured_and_sends_nothing"

d="$(fresh_copy w7)"
apply_exact "$CHAOS" \
  '    return PowerOnChance(None,
                         f"{power_ip} is not among the switches the graph calls down, and "' \
  '    return PowerOnChance(power_ip,
                         f"{power_ip} is not among the switches the graph calls down, and "' "$d" || d=""
report "W7: a healthy fabric is timed anyway, so a power-on is sent" "$d" \
       "test_a_healthy_fabric_reports_not_measured_and_sends_nothing"

echo

# --- 🔴 X: widenings the contract permits. Every one of these must stay GREEN --------------------

d="$(fresh_copy x1)"
apply_exact "$CHAOS" \
  '    f.evidence.update({"threshold_s": I.A1_FAST_S,' \
  '    f.evidence.update({"harness_note": "extra evidence", "threshold_s": I.A1_FAST_S,' "$d"
must_survive "X1 (widening): an extra evidence key is added" "$d"

d="$(fresh_copy x2)"
apply_exact "$ANTIORACLE" \
  'NOT_MEASURED = "NOT-MEASURED"' \
  'NOT_MEASURED = "NOT MEASURED (no power-on to time)"' "$d"
must_survive "X2 (widening): the verdict string itself is reworded" "$d"

d="$(fresh_copy x3)"
apply_exact "$INVARIANTS" \
  'A1_HONEST_S = 1.27' \
  'A1_HONEST_S = 1.35' "$d"
must_survive "X3 (widening): the honest-path reference is re-measured" "$d"

d="$(fresh_copy u1)"
apply_exact "$CHAOS" \
  '        # 🔴 FINDINGS-ALL #75. INV-01 is two checks; until now the round ran one of them and' \
  '        # Reworded comment, no behaviour change at all (the scorer control).' "$d"
must_survive "U1 (control): an inert edit -- a survivor must be reportable" "$d"

echo
ok=1
[[ "$(sha256sum "$CHAOS"      | cut -d' ' -f1)" == "$BASE_CHAOS" ]] || { echo "🔴 baseline CHANGED -- $CHAOS was written during the gate"; ok=0; }
[[ "$(sha256sum "$INVARIANTS" | cut -d' ' -f1)" == "$BASE_INV"   ]] || { echo "🔴 baseline CHANGED -- $INVARIANTS was written during the gate"; ok=0; }
[[ "$(sha256sum "$ANTIORACLE" | cut -d' ' -f1)" == "$BASE_AO"    ]] || { echo "🔴 baseline CHANGED -- $ANTIORACLE was written during the gate"; ok=0; }
[[ "$ok" == 1 ]] || exit 3
echo "baseline byte-identical: yes (chaos.py, invariants.py, antioracle.py)"
echo "widening controls: $WIDENINGS, $BROKEN_WIDENINGS killed (a kill here means the suite is pinned to prose, not behaviour)"
[[ "$UNAPPLICABLE" -eq 0 ]] || echo "unapplicable mutations: $UNAPPLICABLE (each counted as a survivor)"
if [[ "$SURVIVORS" -eq 0 && "$BROKEN_WIDENINGS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
