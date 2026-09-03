#!/usr/bin/env bash
#
# Mutation gate for tests/test_PhantomFilterCoversOvs.cpp (KNOWN-ISSUES C-4).
#
# [Co-developed with claude code -- Adam]
#
# C-4 is B-1 fixed on one plane. The filter, the token and the read path were all correct and all
# shared; what was not shared was a truthful confirmation signal. `DispatchOutcomeLog::record`
# stamped a token whenever `OpResult::ok`, and on OVS `ok` comes from Ryu's fire-and-forget 200 --
# emitted as soon as the OFPFlowMod is built, and OpenFlow does not acknowledge a FLOW_MOD.
#
# So the mutations here are aimed at a specific hazard: this fix is one boolean wide. A single
# `return true;` in the wrong subclass, or a dropped `&&`, restores the phantom on OVS or removes
# a real entry on P4, and both are silent. Each mutation below names the ONE test that must go
# red, because "something went red" would be satisfied by the suite noticing an unrelated break.
#
# Three shapes are covered, deliberately:
#   * the plane's claim        -- which control plane says its acceptance is an observation
#   * the conversion           -- whether that claim reaches the token, and only then
#   * the report               -- whether kernel.log says a row is being withheld, and why
#
# The widenings matter as much as the kills. A gate whose every mutation is a deletion only ever
# proves the tests notice absence; the four below change the code without changing its behaviour
# and must stay GREEN, which is what stops the assertions from being pinned to a spelling.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# byte-identity asserted at the end. The baseline is the WORKING TREE, not HEAD, so this runs
# against an uncommitted fix. Restore is `cp -p` then `touch`: cp -p puts the ORIGINAL mtime back,
# which is older than the object built from the mutant, so ninja would decide there was nothing to
# do and the next mutation would be scored against the previous mutant's binary.
#
# 🔴 Anything that stops the tests RUNNING counts as SURVIVED, never as a warning: an anchor that
# no longer matches, a mutation that cannot be applied, a mutant that does not compile. In all
# three the targeted behaviour is exactly as unproven as if the suite had stayed green, and
# scoring them softly lets the gate shrink silently as the code moves under it.
#
# Usage:  LOCK_WAIT=10800 JOBS=1 tools/build_guard/guarded_build.sh \
#             ./tests/shell/mutate_phantom_filter_covers_ovs.sh
#         BUILD_DIR=build-asan ./tests/shell/mutate_phantom_filter_covers_ovs.sh
# Assumes: cwd is the repo root, ${BUILD_DIR:-build} is already configured (ninja).
#          Run it under the build guard -- fourteen rebuilds unguarded is how this laptop's
#          systemd-oomd came to kill the user's application on 2026-09-02.
# Exit:    0 all mutations caught and all widenings green
#          1 a mutation survived -- including one that failed to build or whose anchor moved
#          2 refused (baseline red, tree unbuildable, or a source not restored byte-identically)
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
# The existing B-1 suites are in the filter on purpose: half of what this fix must prove is that
# the P4 plane did NOT change, and those are the tests that own that guarantee.
FILTER='PhantomOvsFixture.*:PendingEntryFilterTest.*:ProgrammedTokenTest.*'

OPRESULT=include/ndt_core/routing_management/OpResult.hpp
OVSSTRAT=include/ndt_core/routing_management/OpenFlowRoutingStrategy.hpp
P4STRAT=include/ndt_core/routing_management/P4RoutingStrategy.hpp
HTTPBASE=src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp
OUTCOMES=include/ndt_core/routing_management/DispatchOutcomeLog.hpp
FILTERHPP=include/ndt_core/routing_management/PendingEntryFilter.hpp
CONTROLLER=src/ndt_core/routing_management/Controller.cpp
DEVMGR=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
FILES=("$OPRESULT" "$OVSSTRAT" "$P4STRAT" "$HTTPBASE" "$OUTCOMES" "$FILTERHPP" "$CONTROLLER" "$DEVMGR")

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -d "$BUILD_DIR" ]] || { echo "REFUSE: $BUILD_DIR is not configured. cmake -B $BUILD_DIR -G Ninja" >&2; exit 2; }

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
WIDENINGS=0
WIDENINGS_RED=0

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal> -- how many times the literal occurs. Shown for every mutation:
# an anchor matching twice silently mutates the wrong site, one matching zero times makes the
# mutation a no-op that then "passes".
#
# python, not `grep -c -F`: grep splits a multi-line -F pattern into several patterns and counts
# matching LINES, so a multi-line anchor would report >1 and be rejected as "not unique".
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

# red_tests -- the space-separated names of the tests that failed. rc captured from the binary
# directly, never through a pipe.
red_tests() {
    local out rc
    out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\[  FAILED  \] \([A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <file> <old> <new> <expected-test>
# A killing mutation: it changes behaviour, and the named test must be the one that reports it.
mutate() {
    local label="$1" file="$2" old="$3" new="$4" expected="$5"
    local n; n=$(anchor_count "$file" "$old")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    if ! apply_anchor "$file" "$old" "$new"; then
        echo "  🔴 mutation could not be applied. NOT a pass. SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    if ! build; then
        echo "  🔴 MUTANT DOES NOT COMPILE -- the test never ran, so this counts as SURVIVED."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | grep -E 'error|Error' | head -5 |
            sed 's/^/       /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        SURVIVORS=$((SURVIVORS + 1))
    elif grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# widen <label> <file> <old> <new> <why-behaviour-is-preserved>
# A behaviour-preserving rewrite. It must stay GREEN. A red here means the suite is pinned to a
# spelling rather than to a behaviour, which is its own defect: it makes the next honest refactor
# look like a regression, and it is how a test stops being able to judge anything but itself.
widen() {
    local label="$1" file="$2" old="$3" new="$4" why="$5"
    local n; n=$(anchor_count "$file" "$old")
    printf '\n=== WIDENING: %s ===\n' "$label"
    printf '  %s\n' "$why"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    WIDENINGS=$((WIDENINGS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this widening proves nothing. Counted red."
        WIDENINGS_RED=$((WIDENINGS_RED + 1)); restore; return
    fi

    apply_anchor "$file" "$old" "$new"
    if ! build; then
        echo "  🔴 WIDENING DOES NOT COMPILE -- counted red; a rewrite this suite forbids at"
        echo "     compile time is as pinned as one it forbids at run time."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | grep -E 'error|Error' | head -5 |
            sed 's/^/       /'
        WIDENINGS_RED=$((WIDENINGS_RED + 1)); restore; return
    fi

    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  ✅ stayed green, as it must"
    else
        printf '  🔴 WENT RED: %s\n' "$failed"
        echo "     The suite is pinned to the spelling, not to the behaviour."
        WIDENINGS_RED=$((WIDENINGS_RED + 1))
    fi
    restore
}

# --- baseline --------------------------------------------------------------------------------

echo "C-4 mutation gate -- the phantom filter covers the OVS write path"
echo "  build dir : $BUILD_DIR"
echo "  target    : $TARGET"
echo "  filter    : $FILTER"
for f in "${FILES[@]}"; do printf '  baseline  : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"; done
echo
echo "baseline (unmutated) must build and be green:"
if ! build; then
    echo "  REFUSE: the unmutated tree does not build. Nothing below would mean anything."
    cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -20 | sed 's/^/    /'
    exit 2
fi
BASE_RED=$(red_tests)
if [[ -n "$BASE_RED" ]]; then
    echo "  REFUSE: baseline is RED before any mutation."
    printf '    red: %s\n' "$BASE_RED"
    exit 2
fi
"$BIN" --gtest_filter="$FILTER" 2>&1 | tail -3 | sed 's/^/    /'
echo "  ok       baseline green"

# --- killing mutations -----------------------------------------------------------------------

# 1. THE DEFECT ITSELF, in its narrowest form: the OVS plane claims its acceptance is an
#    observation. This is what trunk did, expressed as one word, and it is the whole of C-4.
mutate "1. Ryu claims its fire-and-forget 200 confirms programming" \
    "$OVSSTRAT" \
    'bool successConfirmsProgramming() const override { return false; }' \
    'bool successConfirmsProgramming() const override { return true; }' \
    'PhantomOvsFixture.AnOvsInstallIsNotServedBeforeAPollObservesIt'

# 2. The opposite error, and the one a nervous fix makes: withhold on P4 too. It looks safe --
#    nothing phantom is ever served -- and it removes a real, confirmed entry from the view for a
#    whole poll interval on the plane that had no defect.
mutate "2. the P4 proxy stops confirming, so a real entry disappears" \
    "$P4STRAT" \
    'bool successConfirmsProgramming() const override { return true; }' \
    'bool successConfirmsProgramming() const override { return false; }' \
    'PhantomOvsFixture.AConfirmedP4InstallIsStillServedImmediately'

# 3. The conversion, deleted: record() goes back to stamping every success, whatever the plane
#    said. The strategies still answer correctly and nothing reads the answer -- "decided
#    correctly, wired to nothing", which is the shape this repo has paid for repeatedly.
mutate "3. record() stamps a token for any success again" \
    "$OUTCOMES" \
    'if (result.confirmsProgramming)
            {
                noteProgrammed_(job.token);
            }' \
    'noteProgrammed_(job.token);' \
    'PhantomOvsFixture.AnOvsInstallIsNotServedBeforeAPollObservesIt'

# 4. The carrier, dropped: post() stops attaching the plane's claim, so every success defaults to
#    unconfirmed. OVS stays correct by accident and P4 loses its confirmed entries -- a mutation
#    that is invisible to any test that only checks the OVS half.
mutate "4. post() drops the plane's claim on the way out" \
    "$HTTPBASE" \
    'return OpResult::success(status).withProgrammingConfirmed(successConfirmsProgramming());' \
    'return OpResult::success(status);' \
    'PhantomOvsFixture.AProxySuccessStillConfirmsTheEntry'

# 5. The confirmation is inverted at the carrier rather than at the plane. Same end state as 1 and
#    2 together, reached by a different edit, so it also proves the two planes are not being told
#    apart by something downstream that happens to agree.
mutate "5. post() inverts the plane's claim" \
    "$HTTPBASE" \
    '.withProgrammingConfirmed(successConfirmsProgramming());' \
    '.withProgrammingConfirmed(!successConfirmsProgramming());' \
    'PhantomOvsFixture.AProxySuccessStillConfirmsTheEntry'

# 6. `ok` stops being required, so a REFUSED entry confirms itself. B-1's original guarantee,
#    which this change must not spend.
mutate "6. a refusal confirms its own token" \
    "$OUTCOMES" \
    'if (result.ok)
        {
            succeeded_' \
    'if (result.ok || result.confirmsProgramming || true)
        {
            succeeded_' \
    'PhantomOvsFixture.AProxyRefusalConfirmsNothingEither'

# 7. Withholding reported as failing. The tempting simplification -- "if we are not confirming it,
#    call it a failure" -- and it would make A-7's dispatch-status endpoint report a healthy OVS
#    fabric as a fabric full of rejected rules, swapping one false alarm for another.
mutate "7. an accepted-but-unconfirmed entry is counted as a failure" \
    "$OUTCOMES" \
    'succeeded_.fetch_add(1, std::memory_order_relaxed);' \
    'if (result.confirmsProgramming) { succeeded_.fetch_add(1, std::memory_order_relaxed); } else { failed_.fetch_add(1, std::memory_order_relaxed); }' \
    'PhantomOvsFixture.TheCountersStillMeanWhatA7SaysTheyMean'

# 8. The view stops saying it is withholding. Silence here is the exact defect KNOWN-ISSUES B-1's
#    2026-09-02 review recorded as clause 3: the count was computed and dropped.
mutate "8. the view withholds silently again" \
    "$DEVMGR" \
    '    reportWithheldRows(withheld);' \
    '    (void)withheld;' \
    'PhantomOvsFixture.TheViewSaysItIsWithholdingRows'

# 9. The view cries wolf: it reports withholding on every read, whether or not anything was
#    withheld. A line that is always there is a line nobody reads, so this is not cosmetic.
mutate "9. the view reports withholding unconditionally" \
    "$DEVMGR" \
    'if (withheld == previous)' \
    'if (false)' \
    'PhantomOvsFixture.TheViewDoesNotClaimToWithholdWhatItServed'

# 10. The dispatch stops saying WHY. The view can then only report a count, and "this plane
#     cannot confirm" becomes indistinguishable from "the switch refused it" -- which are the two
#     things an operator has to tell apart before deciding whether to re-send.
mutate "10. the dispatch stops explaining an unconfirmed acceptance" \
    "$CONTROLLER" \
    'if (unconfirmed > 0)' \
    'if (false)' \
    'PhantomOvsFixture.TheDispatchSaysWhyAnAcceptedEntryIsStillWithheld'

# 11. The filter itself widened to hide untokened rows. Not new in this change, but this suite has
#     to notice it: everything a real switch reports arrives untokened, so this empties the table
#     view of the whole fabric -- the catastrophic direction of the same fix.
mutate "11. the filter hides rows polled off a real switch" \
    "$FILTERHPP" \
    'if (token != 0 && !(isProgrammed && isProgrammed(token)))' \
    'if (!(isProgrammed && isProgrammed(token)))' \
    'PhantomOvsFixture.PolledRowsAreNeverWithheldOnEitherPlane'

# --- widenings: behaviour-preserving, must stay green -----------------------------------------

# W1. The plane's answer via a named constant instead of a literal. If this reddens, something is
#     reading the source text rather than the behaviour.
widen "W1. Ryu's answer through a named local" \
    "$OVSSTRAT" \
    'bool successConfirmsProgramming() const override { return false; }' \
    'bool successConfirmsProgramming() const override { const bool openFlowAcknowledgesFlowMods = false; return openFlowAcknowledgesFlowMods; }' \
    "same value, one indirection out -- nothing about the behaviour changes"

# W2. The two conditions in the other order. Both are plain reads of a struct with no side
#     effects, so the order is arbitrary and no test may depend on it.
widen "W2. the confirmation test written the other way round" \
    "$OUTCOMES" \
    'if (result.confirmsProgramming)
            {
                noteProgrammed_(job.token);
            }' \
    'if (result.confirmsProgramming && result.ok)
            {
                noteProgrammed_(job.token);
            }' \
    "inside the ok branch already, so && result.ok is a redundant true"

# W3. The view's message reworded and extended. The assertions name the two fragments that carry
#     the meaning -- that it is withholding, and that the reason is 'not observed' -- and must
#     tolerate everything else moving.
widen "W3. the view's line reworded around its two load-bearing fragments" \
    "$DEVMGR" \
    '"flow-table view is withholding {} row(s) from ' \
    '"KNOWN-ISSUES C-4: flow-table view is withholding {} row(s) from ' \
    "same two fragments, extra prose -- a message may be improved without breaking a test"

# W4. post() computes the claim before the return instead of inside it. Identical call, identical
#     value, one statement earlier.
widen "W4. post() names the plane's claim before returning it" \
    "$HTTPBASE" \
    '    return OpResult::success(status).withProgrammingConfirmed(successConfirmsProgramming());' \
    '    const bool confirmed = successConfirmsProgramming();
    return OpResult::success(status).withProgrammingConfirmed(confirmed);' \
    "same expression, hoisted -- a refactor the suite must not forbid"

# --- restore and verify ------------------------------------------------------------------------

restore
echo
echo "restoring and rebuilding the pristine tree:"
if ! build; then
    echo "  REFUSE: the restored tree does not build. The working tree may be damaged."
    exit 2
fi
DIRTY=0
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$(snap "$f")"; then
        echo "  🔴 NOT RESTORED: $f differs from its pre-run snapshot."
        DIRTY=1
    fi
done
[[ $DIRTY -eq 0 ]] && echo "  ok       all ${#FILES[@]} sources byte-identical to the pre-run snapshot"
FINAL_RED=$(red_tests)
if [[ -n "$FINAL_RED" ]]; then
    echo "  🔴 the restored tree is RED: $FINAL_RED"
    DIRTY=1
fi

echo
echo "================================================================"
printf 'mutations : %d\n' "$MUTATIONS"
printf 'survivors : %d\n' "$SURVIVORS"
printf 'widenings : %d green of %d\n' "$((WIDENINGS - WIDENINGS_RED))" "$WIDENINGS"
echo "================================================================"

[[ $DIRTY -ne 0 ]] && exit 2
[[ $SURVIVORS -eq 0 && $WIDENINGS_RED -eq 0 ]] || exit 1
echo "all mutations caught, all widenings green"
exit 0
