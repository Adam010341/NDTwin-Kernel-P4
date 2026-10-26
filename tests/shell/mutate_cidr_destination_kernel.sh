#!/usr/bin/env bash
#
# Mutation gate for tests/test_FlowTableCacheCidr.cpp: CIDR destinations on the kernel's
# flow-batch path (the table cache's row lookup and the pre-queue address check).
#
# [Co-developed with claude code -- Adam]
#
# Each mutation names the ONE test that must go red; "something went red" would be satisfied by
# an unrelated break. The widening changes the code without changing its behaviour and must stay
# green, so the suite is not pinned to a spelling.
#
# Every test in tests/test_FlowTableCacheCidr.cpp must also go red under at least one mutation: a
# test no mutant can redden is not shown to check anything, and the gate fails (exit 1) listing
# it. The list of tests is read from the test binary, so a test added later is held to the same
# rule without this script being told about it.
#
# Guards its own baseline the way mutate_phantom_filter_covers_ovs.sh does: snapshot of the
# working tree before the first mutation, EXIT trap restores, `cp -p` then `touch` so ninja
# rebuilds, byte-identity asserted at the end. Anything that stops the tests running (anchor not
# unique, mutation not applied, mutant does not compile) counts as SURVIVED.
#
# Usage:  LOCK_WAIT=10800 JOBS=1 tools/build_guard/guarded_build.sh \
#             ./tests/shell/mutate_cidr_destination_kernel.sh
# Assumes: cwd is the repo root, ${BUILD_DIR:-build} is already configured (ninja).
#          FlowJob.hpp mutations rebuild HttpSession.cpp -- run under the build guard.
# Exit:    0 all caught, the widening green and no test never reddened / 1 a survivor or a test
#          that never went red / 2 refused
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='*CidrDestination*:FlowTableCacheOptionalFields.*:FlowEntryShapeTest.*:FlowBatchPartitionTest.*'

FLOWJOB=include/ndt_core/routing_management/FlowJob.hpp
DCPM=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
FILES=("$FLOWJOB" "$DCPM")

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
WIDENINGS=0
WIDENINGS_RED=0

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
    if [[ -z "$failed" ]]; then
        echo "  NOTHING WENT RED -- SURVIVOR."
        SURVIVORS=$((SURVIVORS + 1))
    elif grep -qF -- "$expected" <<<"$failed"; then
        printf '  caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  WRONG TEST WENT RED: got [%s], expected [%s] -- SURVIVOR\n' "$failed" "$expected"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

widen() {
    local label="$1" file="$2" old="$3" new="$4" why="$5"
    local n; n=$(anchor_count "$file" "$old")
    printf '\n=== WIDENING: %s ===\n  %s\n  anchor occurrences: %s in %s\n' "$label" "$why" "$n" "$file"
    WIDENINGS=$((WIDENINGS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  ANCHOR IS NOT UNIQUE -- counted red."
        WIDENINGS_RED=$((WIDENINGS_RED + 1)); restore; return
    fi
    apply_anchor "$file" "$old" "$new"
    if ! build; then
        echo "  WIDENING DOES NOT COMPILE -- counted red."
        WIDENINGS_RED=$((WIDENINGS_RED + 1)); restore; return
    fi
    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  stayed green, as it must"
    else
        printf '  WENT RED: %s\n' "$failed"
        WIDENINGS_RED=$((WIDENINGS_RED + 1))
    fi
    restore
}

echo "CIDR destination mutation gate -- kernel table cache and pre-queue check"
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

# --- the cache key (DeviceConfigurationAndPowerManager.cpp) ----------------------------------

mutate "1. the key drops the destination (back to: a /24 is anyone)" \
    "$DCPM" \
    'tableId, priority, fk, dst, src};' \
    'tableId, priority, fk, CachedIpv4Field{}, src};' \
    'BothSpellings/CidrDestinationCache.DeletingA24RemovesThatPrefixOnly/ipv4_dst'

mutate "2. nw_dst unread again (the OpenFlow 1.0 spelling becomes 0.0.0.0)" \
    "$DCPM" \
    '    if (it == match.end())
    {
        it = match.find(alias);
    }' \
    '' \
    'BothSpellings/CidrDestinationCache.DeletingA24RemovesThatPrefixOnly/nw_dst'

mutate "3. the mask leaves the key (a /24 is its own /32)" \
    "$DCPM" \
    'return {v->address & v->mask, v->mask, {}};' \
    'return {v->address & v->mask, 0xFFFFFFFFu, {}};' \
    'BothSpellings/CidrDestinationCache.DeletingA24RemovesThatPrefixOnly/ipv4_dst'

mutate "4. host bits below the mask stay in the key" \
    "$DCPM" \
    'return {v->address & v->mask, v->mask, {}};' \
    'return {v->address, v->mask, {}};' \
    'BothSpellings/CidrDestinationCache.HostBitsBelowTheMaskDoNotMakeADifferentPrefix/ipv4_dst'

mutate "5. an unreadable cached value throws again" \
    "$DCPM" \
    'return {0, 0, it->dump()};' \
    'throw std::runtime_error("invalid ipv4 string: " + it->dump());' \
    'BothSpellings/CidrDestinationCache.AnUnreadableCachedValueNeitherThrowsNorMatchesAnythingElse/ipv4_dst'

mutate "6. an unreadable cached value loses its text (it becomes 'absent')" \
    "$DCPM" \
    'return {0, 0, it->dump()};' \
    'return {};' \
    'BothSpellings/CidrDestinationCache.AnUnreadableCachedValueNeitherThrowsNorMatchesAnythingElse/ipv4_dst'

mutate "7. the key drops the source" \
    "$DCPM" \
    'tableId, priority, fk, dst, src};' \
    'tableId, priority, fk, dst, CachedIpv4Field{}};' \
    'CidrDestinationCache32.ASourceStillTellsTwoRulesApart'

# --- the parser and the pre-queue check (FlowJob.hpp) ----------------------------------------

mutate "8. the pre-queue address check is skipped" \
    "$FLOWJOB" \
    'if (v != match->end() && !parseIpv4MatchValue(*v))' \
    'if (false && v != match->end() && !parseIpv4MatchValue(*v))' \
    'AllFourAddressFields/CidrDestinationAdmission.AMalformedAddressIsRefusedBeforeQueueing/ipv4_dst'

mutate "9. the check forgets nw_dst" \
    "$FLOWJOB" \
    '{"ipv4_dst", "nw_dst", "ipv4_src", "nw_src"}' \
    '{"ipv4_dst", "ipv4_src", "nw_src"}' \
    'AllFourAddressFields/CidrDestinationAdmission.AMalformedAddressIsRefusedBeforeQueueing/nw_dst'

mutate "10. a prefix length of 33 is accepted" \
    "$FLOWJOB" \
    'if (len > 32)' \
    'if (len > 33)' \
    'AllFourAddressFields/CidrDestinationAdmission.AMalformedAddressIsRefusedBeforeQueueing/ipv4_dst'

mutate "11. the a.b.c.d/m.m.m.m spelling is refused" \
    "$FLOWJOB" \
    'if (inet_pton(AF_INET, suffix.c_str(), &m) != 1)' \
    'if (true)' \
    'AllFourAddressFields/CidrDestinationAdmission.AWellFormedAddressIsNotRefused/ipv4_dst'

mutate "12. the prefix mask is built from the wrong end" \
    "$FLOWJOB" \
    'out.mask = (len == 0) ? 0u : (0xFFFFFFFFu << (32 - len));' \
    'out.mask = (len == 0) ? 0u : (0xFFFFFFFFu >> (32 - len));' \
    'BothSpellings/CidrDestinationCache.TheMaskSpellingOfAPrefixIsTheSamePrefix/ipv4_dst'

mutate "13. a number above 2^32-1 is accepted" \
    "$FLOWJOB" \
    'if (n > 0xFFFFFFFFull)' \
    'if (n > 0x1FFFFFFFFull)' \
    'AllFourAddressFields/CidrDestinationAdmission.AMalformedAddressIsRefusedBeforeQueueing/ipv4_dst'

mutate "14. a negative number is accepted" \
    "$FLOWJOB" \
    'if (n < 0 || n > 0xFFFFFFFFll)' \
    'if (n > 0xFFFFFFFFll)' \
    'AllFourAddressFields/CidrDestinationAdmission.AMalformedAddressIsRefusedBeforeQueueing/ipv4_dst'

mutate "15. an empty suffix (a.b.c.d/) is read as a /32" \
    "$FLOWJOB" \
    'const bool digits = !suffix.empty() && suffix.size() <= 2 &&' \
    'if (suffix.empty()) { return out; }
    const bool digits = suffix.size() <= 2 &&' \
    'AllFourAddressFields/CidrDestinationAdmission.AMalformedAddressIsRefusedBeforeQueueing/ipv4_dst'

# --- the cache: reads, serves and removes rows ----------------------------------------------

mutate "16. a prefix on the nw_dst spelling throws again" \
    "$DCPM" \
    '    if (const auto v = parseIpv4MatchValue(*it))' \
    '    if (it.key() == alias && it->is_string() &&
        it->get<std::string>().find('"'"'/'"'"') != std::string::npos)
    {
        throw std::runtime_error("invalid ipv4 string: " + it->dump());
    }
    if (const auto v = parseIpv4MatchValue(*it))' \
    'BothSpellings/CidrDestinationCache.ModifyingA24DoesNotThrow/nw_dst'

mutate "17. a prefix on the ipv4_dst spelling throws again" \
    "$DCPM" \
    '    if (const auto v = parseIpv4MatchValue(*it))' \
    '    if (it.key() == field && it->is_string() &&
        it->get<std::string>().find('"'"'/'"'"') != std::string::npos)
    {
        throw std::runtime_error("invalid ipv4 string: " + it->dump());
    }
    if (const auto v = parseIpv4MatchValue(*it))' \
    'BothSpellings/CidrDestinationCache.ModifyingA24DoesNotThrow/ipv4_dst'

mutate "18. an installed row is served without its match" \
    "$DCPM" \
    '        newFlow["match"] = e.value("match", json::object());' \
    '        newFlow["match"] = json::object();' \
    'CidrDestinationCache32.AnInstalled32IsServedAsSent'

mutate "19. a delete removes nothing" \
    "$DCPM" \
    '            return extractKey(f) == key;' \
    '            return extractKey(f) == key && false;' \
    'CidrDestinationCache32.AnNwDst32DeleteRemovesItsRow'

# --- the two spellings of one field (FlowJob.hpp) ----------------------------------------------

mutate "20. two different addresses in the two spellings are let through" \
    "$FLOWJOB" \
    '            if (va->mask != vb->mask || (va->address & va->mask) != (vb->address & vb->mask))' \
    '            if (false && va && vb)' \
    'CidrDestinationSpellings.DifferentAddressesInBothSpellingsAreRefused'

mutate "21. the spellings are compared as written, not as normalised" \
    "$FLOWJOB" \
    '            if (va->mask != vb->mask || (va->address & va->mask) != (vb->address & vb->mask))' \
    '            if (va && vb && a->dump() != b->dump())' \
    'CidrDestinationSpellings.TheSameAddressInBothSpellingsIsNotRefused'

mutate "22. the source spellings are not compared" \
    "$FLOWJOB" \
    '{"ipv4_src", "nw_src"}};' \
    '{"ipv4_dst", "nw_dst"}};' \
    'CidrDestinationSpellings.DifferentAddressesInBothSpellingsAreRefused'

mutate "23. a destination and a source are compared with each other" \
    "$FLOWJOB" \
    '{{"ipv4_dst", "nw_dst"},
                                                         {"ipv4_src", "nw_src"}};' \
    '{{"ipv4_dst", "nw_dst"},
                                                         {"ipv4_src", "nw_src"},
                                                         {"ipv4_dst", "nw_src"}};' \
    'CidrDestinationSpellings.ADestinationAndASourceMayDiffer'

mutate "24. an embedded NUL is read through (10.0.0.4\\0x is 10.0.0.4)" \
    "$FLOWJOB" \
    "    if (s.find('\\0') != std::string::npos)" \
    "    if (false && s.find('\\0') != std::string::npos)" \
    'AllFourAddressFields/CidrDestinationAdmission.AMalformedAddressIsRefusedBeforeQueueing/ipv4_dst'

widen "stoi -> digit arithmetic on a one- or two-digit suffix" \
    "$FLOWJOB" \
    'const int len = std::stoi(suffix);' \
    'const int len = suffix.size() == 1 ? suffix[0] - '"'"'0'"'"'
                                         : (suffix[0] - '"'"'0'"'"') * 10 + (suffix[1] - '"'"'0'"'"');' \
    "the suffix is already 1-2 ASCII digits, where the two agree"

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

# Every test of tests/test_FlowTableCacheCidr.cpp must have gone red under some mutation above.
# Same check as tests/shell/mutate_cidr_destination.sh, except that here it decides the exit code.
echo
echo "=== tests never reddened by this gate ==="
NEVER=0
while read -r t; do
    [[ -n "$t" ]] || continue
    if [[ "$REDDENED" != *" $t "* ]]; then echo "  - $t"; NEVER=$((NEVER + 1)); fi
done < <("$BIN" --gtest_list_tests --gtest_filter='*CidrDestination*' 2>/dev/null | awk '
    /^[^ ]/ { suite = $1; next }
    /^  /   { print suite $1 }')
TOTAL_TESTS=$("$BIN" --gtest_list_tests --gtest_filter='*CidrDestination*' 2>/dev/null |
    awk '/^  /' | wc -l)
[[ $NEVER -eq 0 ]] && echo "  (none of $TOTAL_TESTS)"
[[ $TOTAL_TESTS -gt 0 ]] || { echo "  the test list is empty -- the check proves nothing"; NEVER=1; }

echo
echo "================================================================"
printf 'mutations : %d\n' "$MUTATIONS"
printf 'survivors : %d\n' "$SURVIVORS"
printf 'widenings : %d green of %d\n' "$((WIDENINGS - WIDENINGS_RED))" "$WIDENINGS"
printf 'never red : %d of %d tests\n' "$NEVER" "$TOTAL_TESTS"
echo "================================================================"

[[ $DIRTY -ne 0 ]] && exit 2
[[ $SURVIVORS -eq 0 && $WIDENINGS_RED -eq 0 && $NEVER -eq 0 ]] || exit 1
echo "all mutations caught, the widening green, every test seen red"
exit 0
