#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_check_gate_anchors.py (KNOWN-ISSUES L-3).
#
# [Co-developed with claude code -- Adam]
#
# The tool under test is the one that decides whether every OTHER mutation gate can still find
# the text it mutates. If it goes blind, twenty-nine gates go unwatched and the report still
# reads clean -- so its own tests have to be shown red before they mean anything.
#
# Thirteen mutations, in three families:
#   1-4, 9, 13  the four table shapes it learned to read (packed argument, command substitution,
#               parallel arrays, callback dispatch, delegation). Each blinds one shape.
#   5-8, 10     the loudness contract: a driver inheriting "ok" it did not earn, an unchecked
#               delegate read as a checked one, exit 2 downgraded to 0, the stderr line dropped,
#               and a delegating gate mis-filed as NO-ANCHORS on a healthy tree.
#   11, 12      the measurement itself: an anchor count pinned to the expected value, and the
#               comparison that turns a count into MISSING.
#
# A mutation that makes the wrong test go red is a SURVIVOR, not a kill: the case it targets was
# never put to the test. So is one that makes the tool crash before the named case runs.
#
# 🔴 Guards its own baseline: every mutation is applied to a COPY in a temp dir and the tests are
# pointed at the copy with CHECKER_UNDER_TEST. tests/shell/check_gate_anchors.py itself is never
# written -- this worktree is shared and another session may be running it right now. Byte
# identity is asserted at the end regardless.
#
# Nothing is built, nothing is killed, no lab is touched: the tool is read-only and every gate it
# reads here is a synthetic one in a temp git repo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CHECKER="$HERE/check_gate_anchors.py"
TEST="$REPO/tests/python/test_check_gate_anchors.py"
PY="${PY:-/usr/bin/python3}"
BK=$(mktemp -d /tmp/check-anchors-mutate-XXXXXX)
trap 'rm -rf "$BK"' EXIT
BASE_SHA=$(sha256sum "$CHECKER" | cut -d' ' -f1)

MUTATIONS=0
SURVIVORS=0
run_against() { CHECKER_UNDER_TEST="$1" "$PY" "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = mutated copy, $3 = test that must fail
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "^FAIL: $3 " <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR): |^Ran |^OK|^FAILED' <<<"$out" | sed 's/^/             /'
    fi
}

mutant() {   # $1 = name, $2 = anchor \x1f replacement; prints the path to the mutated copy
    local out="$BK/check.$1.py"; cp "$CHECKER" "$out"
    "$PY" - "$out" "$2" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
old, new = spec.split("\x1f")
s = open(p).read()
assert s.count(old) == 1, "anchor is not unique (%d matches): %r" % (s.count(old), old[:70])
open(p, "w").write(s.replace(old, new))
PY
    echo "$out"
}

echo "baseline (must be green before any mutation):"
run_against "$CHECKER" | tail -1
if ! run_against "$CHECKER" >/dev/null 2>&1; then
    echo "  baseline is RED -- fix that first; mutations prove nothing on a red baseline"
    run_against "$CHECKER" | grep -E '^(FAIL|ERROR): ' | sed 's/^/    /'
    exit 2
fi
echo

m1=$(mutant m1 '            word.append(_unescape_ansi_c(text[i + 2:j]))'$'\x1f''            word.append(text[i + 2:j])')
report "M1: \$'\\x1f' is read as literal characters" "$m1" "test_packed_argument_ok"

m2=$(mutant m2 '            substitutions.append(text[i + 2:j - 1] if j > i + 2 else "")'$'\x1f''            substitutions.append("")')
report "M2: \$( ) contents are never parsed" "$m2" "test_packed_argument_drift_is_caught"

m3=$(mutant m3 '    m = re.fullmatch(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\[[^\]]*\]\}", word.strip())
    return m.group(1) if m else None'$'\x1f''    return None')
report "M3: an array reference is not recognised" "$m3" "test_array_table_ok"

# 2026-09-04: re-anchored. is_whole_param_ref's regex grew a `|[0-9]+` alternative (it must
# also recognise a bare numbered positional parameter, $1/$2/..., as a whole reference -- see
# the function's own docstring, which already listed "$1" as an example the old regex did not
# actually match) and wrapped onto a second line for its length; same return statement, same
# mutation (drop it to `return False`, an unconditional "never a reference").
m4=$(mutant m4 '    return re.fullmatch(r"\$\{?(?:[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?|[0-9]+)\}?",
                        word.strip()) is not None'$'\x1f''    return False')
report "M4: an unexpanded parameter counts as a literal anchor" "$m4" \
       "test_an_array_reference_is_never_reported_as_a_literal_anchor"

m5=$(mutant m5 '        elif all(s.startswith("ok") for s in states):'$'\x1f''        elif True:')
report "M5: a driver inherits ok from a broken delegate" "$m5" \
       "test_driver_is_not_ok_when_a_delegate_anchor_has_drifted"

m6=$(mutant m6 '        if absent or not states:'$'\x1f''        if False:')
report "M6: a delegate nobody checked is inherited as ok" "$m6" \
       "test_a_delegate_that_was_not_checked_is_not_inherited_as_ok"

m7=$(mutant m7 '              "%d other cell(s) not ok" % (len(blind), len(bad) - len(blind)), file=sys.stderr)
        return 2'$'\x1f''              "%d other cell(s) not ok" % (len(blind), len(bad) - len(blind)), file=sys.stderr)
        return 0')
report "M7: unreadable gates downgrade exit 2 to exit 0" "$m7" \
       "test_an_unreadable_gate_exits_2_and_says_so"

m8=$(mutant m8 '        print("check_gate_anchors: %d gate-cell(s) COULD NOT BE CHECKED (exit 2); "'$'\x1f''        print("check_gate_anchors: %d gate-cell(s) were fine (exit 2); "')
report "M8: the stderr line stops naming the unchecked cells" "$m8" \
       "test_the_count_of_unchecked_cells_is_printed_and_repeated_on_stderr"

m9=$(mutant m9 '        roles.setdefault(int(m.group(2)), m.group(1).lower())'$'\x1f''        pass')
# The callback shape survives this one: with no roles, the generic "declared path then a
# quoted literal" rule still reaches its anchor. The table shape does not -- its call site names
# no file at all, so the roles are the only route to it. Naming the case the mutation actually
# kills is the point; naming the other one would be a gate that passes on the wrong evidence.
report "M9: a function's own parameter roles are ignored" "$m9" "test_array_table_ok"

m10=$(mutant m10 '            if delegates and not anchors and not problems:'$'\x1f''            if False:')
report "M10: a driver gate is filed as NO-ANCHORS on a clean tree" "$m10" \
       "test_a_clean_run_does_not_claim_anything_was_unchecked"

m11=$(mutant m11 '        return body.count(anchor)'$'\x1f''        return 1')
report "M11: every literal anchor counts as present" "$m11" "test_array_table_drift_is_caught"

m12=$(mutant m12 '                if c == want:
                    continue'$'\x1f''                if True:
                    continue')
report "M12: the count is never compared with what the gate expects" "$m12" \
       "test_callback_dispatch_drift_is_caught"

m13=$(mutant m13 '    return fixed, problems, sorted(dict.fromkeys(delegates))'$'\x1f''    return fixed, problems, []')
report "M13: a driver gate names none of the gates it runs" "$m13" \
       "test_driver_is_ok_when_every_delegate_is"

echo
if [[ "$(sha256sum "$CHECKER" | cut -d' ' -f1)" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes (check_gate_anchors.py was never written)"
else
    echo "🔴 baseline CHANGED -- check_gate_anchors.py was written during the gate"
    exit 3
fi
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
exit 1
