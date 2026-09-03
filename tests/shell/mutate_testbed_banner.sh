#!/usr/bin/env bash
#
# Mutation gate for finding #42 -- testbed_topo.py runs a 128-ping self-test across the fabric
# and then prints three "OK" health claims with NO data flow from the pings to the banner.
# Measured 2026-09-03 on a fabric where all 128 pings were at 100% loss: the banner printed
#
#     Host internet: OK | sFlow reachability: OK | Switch identification: OK
#
# [Co-developed with claude code -- Adam]
#
# It drives one suite:
#
#   tests/python/test_testbed_banner.py    the parser, the summary, the banner, and -- the half
#                                          that would otherwise be decoration -- the AST check
#                                          that the `__main__` block actually calls them.
#
# Each mutation puts back one piece of the defect, or one plausible weakening, and must turn its
# NAMED case red. A mutation nobody catches means that case proves nothing.
#
# 🔴 Three directions, not one:
#
#   (defect)     the thing that happened: a banner printed from a constant, a ping whose result
#                goes nowhere, a self-test the bring-up never runs.
#   (loosening)  the shapes a check written as "did we get some numbers?" signs off on: 0 of 0
#                pings, results recorded twice, ping output nobody could parse read as zero
#                loss, a shortfall counted as a smaller sample instead of as loss.
#   (control)    the opposite failure: an implementation that calls every fabric broken. It
#                satisfies every case in the first two groups and produces a banner an operator
#                learns to ignore -- which is where the original one came from. Each must turn
#                a case labelled "control" red.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the suite is
# pointed at them with TESTBED_TOPO_UNDER_TEST. testbed_topo.py itself is never written -- it is
# a shared worktree and another session may be reading it right now. The baseline sha256 is
# re-checked at the end.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# 🔴 The `./` is load-bearing -- do not tidy it away. testbed_topo.py sits at the repo ROOT, and
# this is the first mutation gate in the repo whose target does. tests/shell/check_gate_anchors.py
# decides which argument names a file with `"/" in v` (path_at, and default_file_of the same way),
# so a bare `testbed_topo.py` is not path-shaped to it: it falls through to the only slash-bearing
# string this gate declares and counts all 23 anchors in tests/python/test_testbed_banner.py, where
# none of them are. Measured 2026-09-03 -- `--gates mutate_testbed_banner.sh` reported MISSING:23
# against a gate whose anchors are all present and all unique. With the `./` it reads ok(23).
# git resolves `<rev>:./testbed_topo.py` from the repo root, which is where the tool's `git -C`
# puts it, and bash treats the path the same either way. The tool's own limitation is worth
# fixing there rather than here, but a gate nobody can read is a gate nobody is checking.
TOPO="$REPO/./testbed_topo.py"
PY_TEST="$REPO/tests/python/test_testbed_banner.py"

# The suite imports nothing outside the standard library (mininet is stubbed), so a bare python3
# is the right interpreter here and not a second environment to keep in step. A venv can still be
# forced for a matrix run.
PY="${TESTBED_BANNER_TEST_PY:-python3}"
command -v "$PY" >/dev/null || { echo "no python3 -- set TESTBED_BANNER_TEST_PY"; exit 2; }

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-banner-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_TOPO=$(sha256sum "$TOPO" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_py() { TESTBED_TOPO_UNDER_TEST="$1/testbed_topo.py" \
           timeout 300 "$PY" "$PY_TEST" 2>&1; }

report_py() {   # $1 = mutation name, $2 = mutant dir, $3 = the test method that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_py "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-62s (py %s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-62s (py %s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR|OK|Ran)' <<<"$out" | sed 's/^/             /'
    fi
}

# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the file and which is the anchor from this
# function's own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is
# not checking (finding #28 -- two gates written the same night extracted zero anchors and
# nobody would have known).
#
# The anchor must be unique. A mutation that lands in two places, or in none, describes itself
# wrongly and the row above it becomes a lie about what was proved.
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$TOPO" "$d/testbed_topo.py"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp "$TOPO" "$base/testbed_topo.py"
run_py "$base" | tail -1
run_py "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the defect itself: the banner is not printed from the measurement -------------------------

m=$(mutant m1 "$TOPO" \
    '        for line in banner_lines(ping_summary):
            print(line)' \
    '        print("")
        print(BANNER_HEADER)
        print("Host internet: OK | sFlow reachability: OK | Switch identification: OK")')
report_py "M1: the constant three-OK banner is back (the defect, verbatim)" "$m" \
          "test_no_health_claim_is_spelled_as_a_constant_in_the_bring_up"

m=$(mutant m2 "$TOPO" \
    '        ping_summary = run_ping_self_test(net, HOST_NUM)' \
    '        pass  # ping_summary = run_ping_self_test(net, HOST_NUM)')
report_py "M2: the bring-up stops running the self-test at all" "$m" \
          "test_the_bring_up_runs_the_self_test"

m=$(mutant m3 "$TOPO" \
    '        for line in banner_lines(ping_summary):' \
    '        for line in banner_lines(summarize_pings([], expected=0)):')
# 🔴 The shape that passes "is banner_lines called?" and measures nothing. Named at the case that
# reads which VALUE reaches it, not at the one that reads which names are called.
report_py "M3: banner_lines is called, but not with what was measured" "$m" \
          "test_the_banner_is_printed_from_the_self_tests_result"

m=$(mutant m4 "$TOPO" \
    '    if sink is not None:
        sink.add(result)
    return result' \
    '    return result')
report_py "M4: a ping's result never reaches the sink (returned into a thread)" "$m" \
          "test_the_result_reaches_the_sink"

m=$(mutant m5 "$TOPO" \
    '    if ping_summary is None or not ping_summary.ok:
        raise SystemExit(1)' \
    '    pass')
report_py "M5: the run exits 0 whatever the self-test measured" "$m" \
          "test_the_run_exits_non_zero_when_the_self_test_failed"

# --- loosening: the ways a count reads fine while the fabric does not --------------------------

m=$(mutant m6 "$TOPO" \
    '        return (self.expected > 0' \
    '        return (self.expected >= 0')
report_py "M6 (loosening): 0 of 0 pings counts as a pass" "$m" \
          "test_measuring_nothing_is_not_passing"

m=$(mutant m7 "$TOPO" \
    '                and self.attempted == self.expected
                and self.distinct == self.expected' \
    '                and self.distinct == self.expected')
# 🔴 Named at the case that DISCRIMINATES, not at the duplicate case. With the attempted clause
# gone, 128 results covering 64 pairs is still caught by `distinct` -- that mutation survives at
# the obvious case and says nothing. It takes 129 results covering 128 pairs (one reply recorded
# twice, one host that never answered) for this clause to be the only thing left standing.
report_py "M7 (loosening): more results than pings launched is fine" "$m" \
          "test_more_results_than_pings_launched_is_not_ok"

m=$(mutant m8 "$TOPO" \
    '                and self.distinct == self.expected
                and self.replied == self.expected)' \
    '                and self.replied == self.expected)')
report_py "M8 (loosening): a copied result counts as a second measurement" "$m" \
          "test_a_result_recorded_twice_does_not_fill_in_for_a_missing_one"

m=$(mutant m9 "$TOPO" \
    '                and self.replied == self.expected)' \
    '                and self.replied >= 0)')
report_py "M9 (loosening): loss stops being looked at" "$m" \
          "test_total_loss_is_not_ok"

m=$(mutant m10 "$TOPO" \
    '        lost=expected - replied,' \
    '        lost=len(results) - replied,')
# The shortfall re-read as a smaller sample: 64 results, 64 replies, "0 lost". This is the exact
# arithmetic that makes a dead half of the fabric invisible.
report_py "M10 (loosening): pings that never reported are dropped from the denominator" "$m" \
          "test_results_that_never_arrived_are_lost_not_absent"

m=$(mutant m11 "$TOPO" \
    '        loss_pct=100.0 if expected <= 0 else 100.0 * (expected - replied) / expected,' \
    '        loss_pct=0.0 if expected <= 0 else 100.0 * (expected - replied) / expected,')
# Written pointing at test_no_result_at_all_from_a_fabric_that_was_pinged and it SURVIVED there:
# that case launches 128 pings, so it never reaches the expected<=0 branch this mutation edits.
# The run was red -- at a different case -- which is exactly the difference between "the suite
# noticed" and "this case proves anything". Re-named at the case that actually divides by zero.
report_py "M11 (loosening): no pings at all reads as zero loss" "$m" \
          "test_measuring_nothing_does_not_report_zero_loss"

m=$(mutant m12 "$TOPO" \
    '        return self.parsed and self.received > 0' \
    '        return self.received >= 0')
report_py "M12 (loosening): output nobody could parse counts as a reply" "$m" \
          "test_unreadable_output_is_not_reached"

m=$(mutant m13 "$TOPO" \
    '    match = _PING_STATS_RE.search(text or "")
    if match is None:
        return None' \
    '    match = _PING_STATS_RE.search(text or "")
    if match is None:
        return (1, 1, 0.0)')
report_py "M13: unreadable ping output is guessed at instead of refused" "$m" \
          "test_output_with_no_statistics_line_is_unreadable_not_perfect"

m=$(mutant m14 "$TOPO" \
    '    r"[^\n]*?(?P<loss>\d+(?:\.\d+)?)%\s+packet\s+loss"' \
    '    r"[^\n]*?(?P<loss>\d+(?:\.\d+)?)%?\s*.*packet\s+loss"')
# "+1 errors, 100% packet loss" read as 1% loss. Not a crash, not a refusal -- a number, wrong.
# Every other canned output still parses identically, which is what makes it worth a case.
report_py "M14: the loss percentage is read off the errors field" "$m" \
          "test_the_errors_field_does_not_confuse_the_loss_percentage"

m=$(mutant m15 "$TOPO" \
    '    except Exception as exc:' \
    '    except ValueError as exc:')
# A host whose cmd() raises kills its thread, records nothing, and the summary is folded over
# what came back. Needs the summary to notice the shortfall AND ping_test to record the failure;
# named at the end-to-end case, which is the only one that sees both.
report_py "M15: a ping that cannot run vanishes instead of failing" "$m" \
          "test_hosts_that_cannot_be_reached_at_all_still_report"

m=$(mutant m16 "$TOPO" \
    '    expected = 2 * pairs' \
    '    expected = 0')
report_py "M16 (loosening): the self-test expects nothing, so nothing is missing" "$m" \
          "test_a_healthy_fabric_passes"

m=$(mutant m17 "$TOPO" \
    '    return summarize_pings(sink.all(), expected=expected)' \
    '    return summarize_pings(sink.all(), expected=len(sink.all()))')
# The self-referential denominator: however many results came back is however many we wanted.
# Only a sink that DROPS results tells this apart from the real thing -- with ping_test's own
# guard in place every launched ping records something, so no fake host can produce the gap.
report_py "M17 (loosening): the denominator is read off the results" "$m" \
          "test_results_lost_on_the_way_back_are_still_counted_as_pings"

# --- the banner's own wording ------------------------------------------------------------------

m=$(mutant m18 "$TOPO" \
    '            f"host reachability: FAIL -- {summary.replied}/{summary.expected} pings replied, "' \
    '            f"host reachability: OK -- {summary.replied}/{summary.expected} pings replied, "')
report_py "M18: the failing branch says OK too" "$m" \
          "test_total_loss_does_not_say_ok_anywhere"

m=$(mutant m19 "$TOPO" \
    '    lines.append("sFlow reachability: NOT MEASURED (configured above, never read back here)")' \
    '    lines.append("sFlow reachability: OK")')
report_py "M19: an unmeasured claim is claimed again" "$m" \
          "test_the_unmeasured_claims_are_not_claimed"

m=$(mutant m20 "$TOPO" \
    '            f"{summary.lost} lost ({summary.loss_pct:.1f}% loss)"' \
    '            f"(see above)"')
report_py "M20: the failure stops carrying the numbers it was computed from" "$m" \
          "test_total_loss_carries_the_counts_it_was_computed_from"

m=$(mutant m21 "$TOPO" \
    '        if summary.attempted != summary.expected:' \
    '        if summary.distinct < summary.attempted:')
# Both diagnostics fire on the same condition: results that never arrived are then reported as
# results recorded twice. Still red, still FAIL -- and the operator is sent to the wrong place.
report_py "M21: a shortfall is diagnosed as a duplicate" "$m" \
          "test_missing_results_are_named_as_missing"

# --- 🔴 the other direction: an instrument that fails everything ---------------------------------
# Each of these passes every mutation above. Without the controls this gate would sign off on a
# banner that says FAIL to every operator on every fabric -- which is how a banner stops being
# read at all, and is where the constant OK it replaces came from.

m=$(mutant n1 "$TOPO" \
    '        return (self.expected > 0' \
    '        return (self.expected < 0')
report_py "N1 (control): no fabric ever passes" "$m" \
          "test_a_healthy_fabric_says_ok_with_its_numbers"

m=$(mutant n2 "$TOPO" \
    '    if summary.ok:' \
    '    if False:')
report_py "N2 (control): the banner only has a failing branch" "$m" \
          "test_a_healthy_fabric_says_ok_with_its_numbers"

m=$(mutant n3 "$TOPO" \
    '    match = _PING_STATS_RE.search(text or "")' \
    '    match = None if text else _PING_STATS_RE.search(text)')
report_py "N3 (control): every ping is unreadable, so every fabric is broken" "$m" \
          "test_a_reply_is_read_as_a_reply"

m=$(mutant n4 "$TOPO" \
    '    if ping_summary is None or not ping_summary.ok:
        raise SystemExit(1)' \
    '    raise SystemExit(1)')
# Passes "does it exit non-zero on failure?" and exits non-zero on a healthy fabric too. The
# case that catches it is the one that reads whether the raise is GUARDED by the measurement.
report_py "N4 (control): the run always exits non-zero" "$m" \
          "test_the_exit_status_is_conditional_on_the_measurement"

echo
[[ "$(sha256sum "$TOPO" | cut -d' ' -f1)" == "$BASE_TOPO" ]] || { echo "🔴 baseline CHANGED -- testbed_topo.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (testbed_topo.py $BASE_TOPO)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
