#!/usr/bin/env bash
#
# Mutation gate for the flow-entry shape check's refusal of OpenFlow keys the kernel does not send
# to the controller (kUnsentFlowKeys and its loop in describeFlowEntryShapeProblem, FlowJob.hpp).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation names the tests that must go red; "something went red" would be satisfied by an
# unrelated break. A test name matches only as a whole name, so the `cookie` case is not satisfied
# by `cookie_mask`.
#
# Every test of this check (the TESTS filter below) must also go red under at least one mutation:
# a test no mutant can redden is not shown to check anything, and the gate fails (exit 1) listing
# it. The list is read from the test binary, so a case added later is held to the same rule.
#
# Guards its own baseline the way mutate_cidr_destination_kernel.sh does: snapshot of the working
# tree before the first mutation, EXIT trap restores, `cp -p` then `touch` so ninja rebuilds,
# byte-identity asserted at the end. Anything that stops the tests running (anchor not unique,
# mutation not applied, mutant does not compile) counts as SURVIVED.
#
# Usage:  LOCK_WAIT=10800 JOBS=1 tools/build_guard/guarded_build.sh \
#             ./tests/shell/mutate_flow_unsent_keys.sh
# Assumes: cwd is the repo root, ${BUILD_DIR:-build} is already configured (ninja).
#          FlowJob.hpp is included by HttpSession.cpp, so every mutant rebuilds it -- run under
#          the build guard.
# Exit:    0 all caught and every test seen red / 1 a survivor or a test that never went red /
#          2 refused
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
# What a mutant is run against: this check's tests, and the shape and C-7 tests around them, so a
# mutant that breaks those shows in the "all red" line.
FILTER='FlowEntryShapeTest.*:*FlowEntryUnsentKeyTest.*:UnsentFlowKeyEndpointTest.*:P4PriorityDeleteEndpointTest.*'
# This check's tests: each must be reddened by some mutant below.
TESTS='*FlowEntryUnsentKeyTest.*:UnsentFlowKeyEndpointTest.*'
TESTS+=':FlowEntryShapeTest.TheControllersOwnDefaultIsAcceptedBecauseNothingIsLost'
TESTS+=':FlowEntryShapeTest.ADefaultSpelledAsSomethingElseIsStillRefused'
TESTS+=':FlowEntryShapeTest.IdleTimeoutIsNotRefusedOnAnInstall'
TESTS+=':FlowEntryShapeTest.EveryRefusalSaysWhatTheControllerUsesInstead'
TESTS+=':FlowEntryShapeTest.TheIdleTimeoutRefusalSaysItIsSentOnAnInstallOnly'
TESTS+=':FlowEntryShapeTest.AFullReadBackRowIsTakenOnEveryOp'

FLOWJOB=include/ndt_core/routing_management/FlowJob.hpp
FILES=("$FLOWJOB")

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -d "$BUILD_DIR" ]] || { echo "REFUSE: $BUILD_DIR is not configured." >&2; exit 2; }

BK=$(mktemp -d)
snap() { echo "$BK/$(echo "$1" | tr '/' '_')"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done
restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "$(snap "$f")" "$f"
        touch "$f"
    done
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
REDDENED=" "

anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

apply_anchor() {
    ANCHOR="$2" REPL="$3" python3 - "$1" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
}

build() { cmake --build "$BUILD_DIR" --target "$TARGET" >/dev/null 2>&1; }

# Failed test names, full gtest names (parameterised ones carry '/'), rc taken from the binary.
red_tests() {
    local out rc
    out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    local names
    names=$(sed -n 's/^\[  FAILED  \] \([^ ,]*\).*/\1/p' <<<"$out" | grep -v '^[0-9]' | sort -u |
        tr '\n' ' ')
    # A nonzero rc with no FAILED line (a crash, a death) is still red; say so rather than "".
    [[ -n "$names" ]] && echo "$names" || echo "<rc=$rc, no FAILED line>"
}

# mutate <label> <file> <old> <new> <expected test names, space-separated, all must go red>
mutate() {
    local label="$1" file="$2" old="$3" new="$4" expected="$5"
    local n; n=$(anchor_count "$file" "$old")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  ANCHOR IS NOT UNIQUE ($n matches) -- SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! apply_anchor "$file" "$old" "$new"; then
        echo "  mutation could not be applied -- SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! build; then
        echo "  MUTANT DOES NOT COMPILE -- the test never ran, SURVIVOR."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | grep -E 'error' | head -5 |
            sed 's/^/       /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    local failed; failed=$(red_tests)
    REDDENED+="$failed "
    local missing="" t
    for t in $expected; do
        [[ " $failed " == *" $t "* ]] || missing+="$t "
    done
    if [[ -z "$failed" ]]; then
        echo "  NOTHING WENT RED -- SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1))
    elif [[ -z "$missing" ]]; then
        printf '  caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  EXPECTED RED BUT GREEN: [%s]; red was [%s] -- SURVIVOR\n' "$missing" "$failed"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

P='EveryUnsentKey/FlowEntryUnsentKeyTest.AKeyTheKernelDoesNotSendIsRefusedOnEveryOp'
E='UnsentFlowKeyEndpointTest'
S='FlowEntryShapeTest'

echo "Unsent OpenFlow keys mutation gate -- the flow-entry shape check"
echo "  build dir : $BUILD_DIR"
echo "  filter    : $FILTER"
echo "  commit    : $(git rev-parse HEAD 2>/dev/null) dirty=$(git status --porcelain --untracked-files=no 2>/dev/null | wc -l)"
for f in "${FILES[@]}"; do printf '  baseline  : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"; done
echo
echo "baseline (unmutated) must build and be green:"
if ! build; then
    echo "  REFUSE: the unmutated tree does not build."
    cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -20 | sed 's/^/    /'
    exit 2
fi
BASE_RED=$(red_tests)
if [[ -n "$BASE_RED" ]]; then
    echo "  REFUSE: baseline is RED: $BASE_RED"
    exit 2
fi
"$BIN" --gtest_filter="$FILTER" 2>&1 | tail -3 | sed 's/^/    /'
echo "  ok       baseline green"

mutate "M1. the check is skipped" \
    "$FLOWJOB" \
    '        if (!nothingIsLost)' \
    '        if (false && !nothingIsLost)' \
    "$P/cookie $P/table_id $P/out_port $P/idle_timeout $S.ADefaultSpelledAsSomethingElseIsStillRefused $E.ACookieIsA400AndNothingIsQueued $E.OneBadEntryRefusesTheWholeBatchAndLeavesTheView $E.ATableIdThatIsNotAnIntegerIsRefusedBeforeQueueingNotAfter"

mutate "M2. table_id leaves the table" \
    "$FLOWJOB" \
    '    {"table_id", 0, false, "the controller uses table_id 0"},
' \
    '' \
    "$P/table_id $E.OneBadEntryRefusesTheWholeBatchAndLeavesTheView $E.ATableIdThatIsNotAnIntegerIsRefusedBeforeQueueingNotAfter"

mutate "M3. out_port, a delete filter, leaves the table" \
    "$FLOWJOB" \
    '    {"out_port", 4294967295u, false,
     "the controller uses out_port 4294967295, OFPP_ANY, which filters on no port"},
' \
    '' \
    "$P/out_port $P/out_port_minus_1 $P/out_port_8589934591"

mutate "M4. a present key is refused whatever its value" \
    "$FLOWJOB" \
    '            value.is_number_integer() && value == nlohmann::json(unsent.controllerDefault);' \
    '            false;' \
    "$S.TheControllersOwnDefaultIsAcceptedBecauseNothingIsLost $E.ZeroValuedKeysStillQueue $S.AFullReadBackRowIsTakenOnEveryOp"

mutate "M5. any integer is accepted (the default is not compared)" \
    "$FLOWJOB" \
    '            value.is_number_integer() && value == nlohmann::json(unsent.controllerDefault);' \
    '            value.is_number_integer();' \
    "$P/cookie $P/cookie_mask $P/table_id $P/hard_timeout $P/flags $P/buffer_id $P/out_port $P/out_group $P/idle_timeout $P/out_port_minus_1 $P/out_port_8589934591 $E.ACookieIsA400AndNothingIsQueued $E.OneBadEntryRefusesTheWholeBatchAndLeavesTheView"

mutate "M6. idle_timeout is refused on an install too" \
    "$FLOWJOB" \
    '    {"idle_timeout", 0, true, "the controller uses idle_timeout 0"},' \
    '    {"idle_timeout", 0, false, "the controller uses idle_timeout 0"},' \
    "$S.IdleTimeoutIsNotRefusedOnAnInstall $E.IdleTimeoutStillTravelsOnAnInstall"

mutate "M7. idle_timeout is no longer refused on a modify or a delete" \
    "$FLOWJOB" \
    '    {"idle_timeout", 0, true, "the controller uses idle_timeout 0"},
' \
    '' \
    "$P/idle_timeout"

mutate "M8. a non-integer equal to the default is accepted (the type test dropped)" \
    "$FLOWJOB" \
    '            value.is_number_integer() && value == nlohmann::json(unsent.controllerDefault);' \
    '            value == nlohmann::json(unsent.controllerDefault);' \
    "$S.ADefaultSpelledAsSomethingElseIsStillRefused"

mutate "M9. out_port's default is taken as 0, not OFPP_ANY" \
    "$FLOWJOB" \
    '    {"out_port", 4294967295u, false,' \
    '    {"out_port", 0u, false,' \
    "$S.TheControllersOwnDefaultIsAcceptedBecauseNothingIsLost $E.ZeroValuedKeysStillQueue $S.AFullReadBackRowIsTakenOnEveryOp"

mutate "M10. a key the controller does not read joins the table" \
    "$FLOWJOB" \
    '    {"cookie", 0, false, "the controller uses cookie 0"},' \
    '    {"cookie", 0, false, "the controller uses cookie 0"},
    {"byte_count", 0, false, "the controller uses byte_count 0"},' \
    "$S.AFullReadBackRowIsTakenOnEveryOp"

mutate "M11. the refusal no longer says what the controller uses" \
    "$FLOWJOB" \
    '" (" + unsent.instead + "); omit it, or send the integer " +' \
    '" (" + std::string(unsent.key) + "); omit it, or send the integer " +' \
    "$S.EveryRefusalSaysWhatTheControllerUsesInstead $S.TheIdleTimeoutRefusalSaysItIsSentOnAnInstallOnly $E.TheProblemIsTheTextTheApiReferenceQuotes"

mutate "M12. the idle_timeout refusal no longer says it is about a modify or a delete" \
    "$FLOWJOB" \
    '(unsent.sentOnInstall ? " on a modify or a delete" : "")' \
    'std::string()' \
    "$S.TheIdleTimeoutRefusalSaysItIsSentOnAnInstallOnly"

# --- restore and verify ------------------------------------------------------------------------

restore
echo
echo "restoring and rebuilding the pristine tree:"
if ! build; then
    echo "  REFUSE: the restored tree does not build."
    exit 2
fi
DIRTY=0
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$(snap "$f")"; then
        echo "  NOT RESTORED: $f differs from its pre-run snapshot."
        DIRTY=1
    fi
done
[[ $DIRTY -eq 0 ]] && echo "  ok       all ${#FILES[@]} sources byte-identical to the pre-run snapshot"
FINAL_RED=$(red_tests)
if [[ -n "$FINAL_RED" ]]; then
    echo "  the restored tree is RED: $FINAL_RED"
    DIRTY=1
fi

echo
echo "=== tests never reddened by this gate ==="
NEVER=0
while read -r t; do
    [[ -n "$t" ]] || continue
    if [[ "$REDDENED" != *" $t "* ]]; then echo "  - $t"; NEVER=$((NEVER + 1)); fi
done < <("$BIN" --gtest_list_tests --gtest_filter="$TESTS" 2>/dev/null | awk '
    /^[^ ]/ { suite = $1; next }
    /^  /   { print suite $1 }')
TOTAL_TESTS=$("$BIN" --gtest_list_tests --gtest_filter="$TESTS" 2>/dev/null | awk '/^  /' | wc -l)
[[ $NEVER -eq 0 ]] && echo "  (none of $TOTAL_TESTS)"
[[ $TOTAL_TESTS -gt 0 ]] || { echo "  the test list is empty -- the check proves nothing"; NEVER=1; }

echo
echo "================================================================"
printf 'mutations : %d\n' "$MUTATIONS"
printf 'survivors : %d\n' "$SURVIVORS"
printf 'never red : %d of %d tests\n' "$NEVER" "$TOTAL_TESTS"
echo "================================================================"

[[ $DIRTY -ne 0 ]] && exit 2
[[ $SURVIVORS -eq 0 && $NEVER -eq 0 ]] || exit 1
echo "all mutations caught and every test seen red"
exit 0
