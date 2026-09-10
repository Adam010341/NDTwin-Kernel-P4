#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #87 in tests/test_GroupMeterExistence.cpp:
# an install or a modify is claimed only after the switch has been asked.
#
# [Co-developed with claude code -- Adam]
#
# Finding #1 gave guardedMod a read-back and wired it to Delete alone. Add and Modify went from
# Ryu's 200 straight to "installed"/"modified" with nothing having asked the switch anything --
# and Ryu neither barriers a group/meter mod nor waits for a reply, so a switch that refuses one
# refuses it asynchronously, correlated to nothing. That is the delete story of 2026-09-03
# (five 200 {"outcome":"deleted"} over five groups that were still there), on the other two verbs.
#
# 🔴 REACHABILITY, and it is weaker here than for the delete half: the delete instance was
# measured on ovs4. A refused INSTALL has not been observed -- FINDINGS-ALL.md:136 says so. Every
# assertion these mutations exercise is against a scripted fake switch, not a live one.
#
# 🔴 The last mutation, M7, is the important one and it is not a defect that breaks anything: it
# makes modify report "modified_verified". The code still works, the claim is just stronger than
# the evidence -- entryExists matches an id in /stats/groupdesc and never looks at buckets, so a
# Present after a modify proves the entry exists, not that the switch took the new definition. It
# is the same role M9 plays in mutate_cpu_report_no_ip.sh. If M7 survives, this suite pins "there
# is a read-back" and not "the claim matches the read-back", which is the difference between the
# fix and a decoration.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit
# including Ctrl-C, byte-identity asserted at the end, and the tree rebuilt from the restored
# source so the next ctest does not run the last mutant. Baseline is the WORKING TREE, not HEAD.
#
# ⚠️ Only src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp is mutated. The header
#    carries VERIFY_ATTEMPTS and mutating it would rebuild every translation unit that includes
#    it -- including the ~1.6 GB HttpSession.cpp -- which on this laptop is what systemd-oomd
#    kills the user's application over. The loop bound is reached through the .cpp instead.
#    Every build here goes through tools/build_guard/guarded_build.sh with JOBS=1, so DO NOT
#    wrap this script in guarded_build.sh: it would deadlock against its own inner lock (that is
#    what held /tmp/ndtwin-build.lock for three hours on 2026-09-04).
#
# ⚠️ SIBLING GATES ON THIS FILE. mutate_f13_group_meter_existence.sh mutates the pre-check and
#    mutate_delete_group_entry.sh mutates the read-back. The #87 change rewrote the read-back
#    block, so several of the latter's anchors had to be re-pointed at the new text -- same
#    mutations, same verdicts, new coordinates. Run
#      python3 tests/shell/check_gate_anchors.py HEAD --gates \
#          mutate_delete_group_entry.sh mutate_f13_group_meter_existence.sh \
#          mutate_group_install_modify_readback.sh
#    after touching any of them.
#
# Usage:
#   bash tests/shell/mutate_group_install_modify_readback.sh
#   BUILD_DIR=build-debug bash tests/shell/mutate_group_install_modify_readback.sh
#
# Exit codes:
#   0  every mutation caught by the test named for it, every control green
#   1  at least one mutation survived, or a control went red
#   2  the baseline is not green, or an anchor moved -- neither is a mutation result
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

SRC=src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp
FILES=("$SRC")

BUILD_DIR="${BUILD_DIR:-build}"
TARGET="${TARGET:-test_routing_strategy}"
BIN="${BIN:-$BUILD_DIR/bin/$TARGET}"
FILTER="${FILTER:-GroupMeterFixture.*:GroupMeterEndpointTest.*}"
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1").$(echo "$1" | md5sum | cut -c1-6)"; }
for f in "${FILES[@]}"; do cp "$f" "$(snap "$f")"; done
restore() { local f; for f in "${FILES[@]}"; do cp "$(snap "$f")" "$f"; touch "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
INVALID=0

# --- mechanics ---------------------------------------------------------------------------------

apply() {   # $1 = file, $2 = exact anchor, $3 = replacement
    ANCHOR="$2" REPL="$3" perl -0777 -i -pe 's/\Q$ENV{ANCHOR}\E/$ENV{REPL}/' "$1"
}

assert_unique() {   # $1 = file, $2 = single-line anchor
    local n
    n=$(grep -c -F -- "$2" "$1")
    if [[ "$n" -ne 1 ]]; then
        printf '  INVALID  anchor matches %s times in %s (want 1): %s\n' "$n" "$1" "$2"
        return 1
    fi
    return 0
}

build() {
    if [[ "${NO_GUARD:-0}" == "1" || ! -x "$GUARD" ]]; then
        cmake --build "$BUILD_DIR" --target "$TARGET" >"$BK/build.log" 2>&1
    else
        LOCK_WAIT="${LOCK_WAIT:-10800}" JOBS=1 "$GUARD" \
            cmake --build "$BUILD_DIR" --target "$TARGET" -j1 >"$BK/build.log" 2>&1
    fi
}

run_suite() {
    "$BIN" --gtest_filter="$FILTER" >"$BK/run.log" 2>&1
}

# --- baseline ----------------------------------------------------------------------------------

echo "#87 mutation gate -- install and modify are claimed only after the switch is asked"
echo "  build dir : $BUILD_DIR"
echo "  target    : $TARGET   (tests/test_GroupMeterExistence.cpp compiles into this binary)"
echo "  filter    : $FILTER"
printf '  baseline  : %s  sha256 %s\n' "$SRC" "$(sha256sum "$SRC" | cut -c1-16)"
echo
echo "baseline (unmutated) must build and be green:"
build; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline build failed (rc=$rc) -- the fix or the new tests do not compile."
    tail -40 "$BK/build.log" | sed 's/^/    /'
    exit 2
fi
if [[ ! -x "$BIN" ]]; then
    echo "  REFUSE: $BIN is missing after a successful build. Check BUILD_DIR ('$BUILD_DIR')."
    exit 2
fi
run_suite; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  REFUSE: baseline is not green (rc=$rc). Failing tests:"
    grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'
    exit 2
fi
if ! grep -qE '^\[  PASSED  \] [1-9]' "$BK/run.log"; then
    echo "  REFUSE: the filter '$FILTER' ran no tests. A gate over zero tests proves nothing."
    exit 2
fi
printf '  ok       baseline green (%s)\n' "$(grep -E '^\[  PASSED  \]' "$BK/run.log" | tail -1)"
echo

# --- reporting ---------------------------------------------------------------------------------

mutate_must_die() {   # name, must-fail test, file, anchor, replacement, [uniqueness line]
    local name="$1" must_fail="$2" file="$3" anchor="$4" repl="$5" uniq="${6:-$4}"
    local rc
    MUTATIONS=$((MUTATIONS + 1))
    if ! assert_unique "$file" "$uniq"; then
        INVALID=$((INVALID + 1)); restore; return
    fi
    apply "$file" "$anchor" "$repl"
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-46s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi
    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-46s (mutant does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi
    run_suite; rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $must_fail" "$BK/run.log"; then
        printf '  caught   %-46s (%s went red)\n' "$name" "$must_fail"
    else
        printf '  SURVIVED %-46s (%s stayed green -- that test proves nothing)\n' "$name" "$must_fail"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             also red: /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

mutate_must_live() {   # name, file, anchor, replacement, [uniqueness line]
    local name="$1" file="$2" anchor="$3" repl="$4" uniq="${5:-$3}"
    local rc
    MUTATIONS=$((MUTATIONS + 1))
    if ! assert_unique "$file" "$uniq"; then
        INVALID=$((INVALID + 1)); restore; return
    fi
    apply "$file" "$anchor" "$repl"
    if cmp -s "$(snap "$file")" "$file"; then
        printf '  INVALID  %-46s (anchor did not apply; file unchanged)\n' "$name"
        INVALID=$((INVALID + 1)); restore; return
    fi
    build; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        printf '  INVALID  %-46s (control does not compile, rc=%s)\n' "$name" "$rc"
        tail -12 "$BK/build.log" | sed 's/^/             /'
        INVALID=$((INVALID + 1)); restore; return
    fi
    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ok       %-46s (control stayed green, as it must)\n' "$name"
    else
        printf '  SURVIVED %-46s (control went RED -- the harness reports red for any edit,\n' "$name"
        printf '           %-46s  so every "caught" above is worthless)\n' ""
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

echo "mutations:"

# --- M1: #87 itself -- add and modify go straight from Ryu's 200 to the outcome -----------------
mutate_must_die \
    "M1 install/modify claimed without reading back" \
    "GroupMeterFixture.AGroupTheSwitchNeverTookIsNotReportedAsInstalled" \
    "$SRC" \
    '    const Existence expected = (op == EntryOp::Delete) ? Existence::Absent : Existence::Present;' \
    '    if (op == EntryOp::Add)
    {
        return result.withOutcome("installed");
    }
    if (op == EntryOp::Modify)
    {
        return result.withOutcome("modified");
    }
    const Existence expected = Existence::Absent;'

# --- M2: the expectation is inverted -- a switch that DID take it is reported as a failure ------
mutate_must_die \
    "M2 add expects the entry to be absent afterwards" \
    "GroupMeterFixture.AGroupTheSwitchDidTakeIsReportedAsInstalled" \
    "$SRC" \
    '    const Existence expected = (op == EntryOp::Delete) ? Existence::Absent : Existence::Present;' \
    '    const Existence expected = Existence::Absent;'

# --- M3: 🔴 Unknown becomes failure -- the kernel publishing its own reach as a finding ---------
mutate_must_die \
    "M3 an unreadable read-back becomes a 502" \
    "GroupMeterFixture.AModifyThatCannotBeReadBackIsUnverifiedRatherThanFailed" \
    "$SRC" \
    '    if (after == Existence::Unknown)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} was forwarded but {} could not be read back, so whether it took "' \
    '    if (false)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} was forwarded but {} could not be read back, so whether it took "' \
    '                           "{} was forwarded but {} could not be read back, so whether it took "'

# --- M4: the read-back happens once, so an install still in flight is a failure -----------------
mutate_must_die \
    "M4 the read-back is not retried" \
    "GroupMeterFixture.TheInstallReadBackIsRetriedAndBounded" \
    "$SRC" \
    '    for (int attempt = 0; attempt < VERIFY_ATTEMPTS; ++attempt)' \
    '    for (int attempt = 0; attempt < 1; ++attempt)'

# --- M5: the loop spins on success, so every install pays the full delay ------------------------
mutate_must_die \
    "M5 the loop breaks on the wrong condition" \
    "GroupMeterFixture.TheInstallReadBackIsRetriedAndBounded" \
    "$SRC" \
    '        if (after == expected || after == Existence::Unknown)' \
    '        if (after != expected)'

# --- M6: 🔴 the verdict is taken from the PRE-post read -----------------------------------------
# "Read back after writing" written as "reuse what we saw before writing". One line, and it is
# exactly the defect the ordering test exists for: no second query is issued at all.
mutate_must_die \
    "M6 the verdict comes from the read before the post" \
    "GroupMeterFixture.AnInstallReadBackHappensAfterThePostNotBeforeIt" \
    "$SRC" \
    '        after = entryExists(kind, dpid, id);' \
    '        after = before;'

# --- M7: 🔴 the claim outgrows the evidence -----------------------------------------------------
# Nothing breaks. modify simply reports that it was verified, which an existence check cannot
# support. This is the mutation this gate exists for.
mutate_must_die \
    "M7 modify claims it was verified" \
    "GroupMeterFixture.AModifyIsNotClaimedVerifiedWhenOnlyExistenceWasChecked" \
    "$SRC" \
    '        return result.withOutcome("modified");' \
    '        return result.withOutcome("modified_verified");'

echo
echo "controls (behaviour-preserving; these must stay GREEN):"

# --- C1: the same ternary, the other way round --------------------------------------------------
mutate_must_live \
    "C1 the outcome ternary is inverted in spelling" \
    "$SRC" \
    '        const char* outcome = (op == EntryOp::Delete) ? "still_present" : "absent";' \
    '        const char* outcome = (op != EntryOp::Delete) ? "absent" : "still_present";'

# --- C2: the same predicate ---------------------------------------------------------------------
mutate_must_live \
    "C2 attempt > 0 written as attempt >= 1" \
    "$SRC" \
    '        if (attempt > 0)' \
    '        if (attempt >= 1)'

# --- C3: the same failure, reworded -------------------------------------------------------------
# The phrase the tests DO assert on ("did NOT take it") is kept; everything around it moves. A
# suite that goes red here is pinned to prose rather than to behaviour.
mutate_must_live \
    "C3 the absent-after-install sentence is reworded" \
    "$SRC" \
    '                : named + " is not on the switch after the " +' \
    '                : named + " could not be found on the switch after the " +'

# --- restore ------------------------------------------------------------------------------------

echo
ok=1
for f in "${FILES[@]}"; do
    cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }
done
if [[ "$ok" == 1 ]]; then
    echo "baseline restored: $SRC byte-identical to the pre-run snapshot"
else
    echo "🔴 the working tree was left mutated -- do not commit until this is sorted out"
fi

echo "rebuilding from the restored source:"
build; rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "  🔴 rebuild after restore failed (rc=$rc) -- the tree may not be what it was"
    tail -20 "$BK/build.log" | sed 's/^/    /'
    ok=0
else
    run_suite; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        echo "  ok       green again from the restored source"
    else
        echo "  🔴 NOT green after restore (rc=$rc):"
        grep -F '[  FAILED  ]' "$BK/run.log" | sed 's/^/    /'
        ok=0
    fi
fi

echo
printf '%d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
if [[ "$INVALID" -gt 0 ]]; then
    printf '%d could not be applied or built -- neither caught nor survived; a human must look\n' \
        "$INVALID"
fi

[[ "$SURVIVORS" -eq 0 && "$INVALID" -eq 0 && "$ok" == 1 ]]
