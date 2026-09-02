#!/usr/bin/env bash
#
# Mutation gate for tests/test_PowerManagerShutdown.cpp (KNOWN-ISSUES B-5).
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration -- and a death test that has never been
# seen to fail is worse than one, because it passes when the statement never runs at all. This
# applies each mutation, rebuilds, and records WHICH test went red.
#
# The three mutations are three different claims, and the third is the one that makes this gate
# worth writing:
#
#   1. the join is removed          -- the defect exactly as it shipped
#   2. the destructor is emptied    -- the guarantee for an owner that never calls stop()
#   3. a NEW unjoined worker        -- the SHAPE. This is what separates a test that asserts
#                                      "m_openflowTablesUpdateThread is joined" (the fix
#                                      restated, and no protection at all against the next
#                                      thread someone adds) from one that asserts "nothing this
#                                      object owns is still joinable when it is destroyed". The
#                                      class fell into B-5 precisely because adding a fourth
#                                      thread compiles, runs and reopens the hole without
#                                      touching stop(); mutation 3 does that on purpose and
#                                      requires the suite to notice.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. The baseline is the WORKING TREE, not HEAD, so it
# runs against an uncommitted fix.
#
# 🔴 Anything that stops the tests from RUNNING counts as SURVIVED, never as a warning: an anchor
# that no longer matches, a mutation that cannot be applied, and a mutant that does not compile.
# In all three the targeted behaviour is exactly as unproven as if the suite had stayed green.
#
# ⚠️ Shared worktree: this edits two tracked source files in place and puts them back. If another
# session is editing DeviceConfigurationAndPowerManager.{hpp,cpp} at the same time, do not run
# this -- the restore writes back THIS script's snapshot.
#
# Usage:  tests/shell/mutate_b5_power_manager_shutdown.sh
#         BUILD_DIR=build-asan tests/shell/mutate_b5_power_manager_shutdown.sh
# Assumes: cwd is the repo root, ${BUILD_DIR:-build} is already configured (ninja).
# Exit:    0 all mutations caught
#          1 a mutation survived -- including one that failed to build or whose anchor moved
#          2 refused (baseline red, tree unbuildable, or a source not restored byte-identically)
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='PowerManagerShutdownDeathTest.*'

HDR=include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp
SRC=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
FILES=("$HDR" "$SRC")

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -d "$BUILD_DIR" ]] || { echo "REFUSE: $BUILD_DIR is not configured. cmake -B $BUILD_DIR -G Ninja" >&2; exit 2; }

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done
restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "$(snap "$f")" "$f"
        # cp -p puts the ORIGINAL mtime back, which is older than the object built from the
        # mutant -- ninja would then see nothing to do and the next run would test the mutant
        # while the source on disk is pristine. touch is what actually restores the build.
        touch "$f"
    done
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal>. python, not `grep -c -F`: grep would split a multi-line pattern
# into several patterns and count matching LINES, and every anchor here spans lines.
anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# edit <file> <anchor> <replacement> -- one substitution, refused unless the anchor is unique.
edit() {
    local file="$1" anchor="$2" repl="$3" n
    n=$(anchor_count "$file" "$anchor")
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    [[ "$n" -eq 1 ]] || { echo "  🔴 ANCHOR IS NOT UNIQUE ($n) -- this mutation proves nothing."; return 1; }
    ANCHOR="$anchor" REPL="$repl" python3 - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
}

build() { cmake --build "$BUILD_DIR" --target "$TARGET" >/dev/null 2>&1; }

# red_tests -- the names of the tests that failed. rc is taken from the binary, never through a
# pipe. --gtest_death_test_style is left at what the suite sets for itself (threadsafe).
red_tests() {
    local out rc
    out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\[  FAILED  \] \([A-Za-z]*\.[A-Za-z]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' '
}

# run_mutation <label> <expected-test> <apply-fn>
run_mutation() {
    local label="$1" expected="$2" apply="$3"
    printf '\n=== %s ===\n' "$label"
    MUTATIONS=$((MUTATIONS + 1))

    if ! "$apply"; then
        echo "  🔴 mutation could not be applied. NOT a pass."
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

# --- the mutations ----------------------------------------------------------------------------

# 1. THE DEFECT AS IT SHIPPED: stop() joins two of the three workers.
m1() {
    edit "$SRC" \
'    if (m_openflowTablesUpdateThread.joinable())
    {
        m_openflowTablesUpdateThread.join();
    }' \
'    // MUTANT: the third worker is not joined -- B-5 exactly as it shipped'
}

# 2. The destructor stops guaranteeing anything, so only an owner that remembers stop() is safe.
#    The stopped case must stay GREEN here: this mutation is about the other one.
m2() {
    edit "$SRC" \
'DeviceConfigurationAndPowerManager::~DeviceConfigurationAndPowerManager()
{
    stop();
}' \
'DeviceConfigurationAndPowerManager::~DeviceConfigurationAndPowerManager()
{
    // MUTANT: no stop() -- an object dropped without one destroys joinable threads
}'
}

# 3. THE SHAPE. A fourth worker, started and never joined -- the next instance of B-5, written by
#    someone who never had to look at stop(). Two files, because that is what it takes in real
#    life: a member and a line in start().
m3() {
    edit "$HDR" \
'    std::thread m_openflowTablesUpdateThread;' \
'    std::thread m_openflowTablesUpdateThread;
    std::thread m_mutantFourthWorker; // MUTANT' || return 1
    edit "$SRC" \
'    m_openflowTablesUpdateThread =
        thread(&DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker, this);' \
'    m_openflowTablesUpdateThread =
        thread(&DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker, this);
    // MUTANT: a fourth worker nobody joins
    m_mutantFourthWorker = thread(&DeviceConfigurationAndPowerManager::statusUpdateWorker, this);'
}

# --- baseline ---------------------------------------------------------------------------------

echo "B-5 mutation gate (kernel shutdown abort)"
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

run_mutation "1. stop() forgets the third worker (B-5 as it shipped)" \
    'PowerManagerShutdownDeathTest.AStoppedManagerIsDestroyedWithoutAborting' m1

run_mutation "2. the destructor no longer stops anything" \
    'PowerManagerShutdownDeathTest.AManagerNeverStoppedIsDestroyedWithoutAborting' m2

run_mutation "3. a FOURTH worker is added and never joined (the shape)" \
    'PowerManagerShutdownDeathTest.AStoppedManagerIsDestroyedWithoutAborting' m3

# --- the tree must be exactly as it was --------------------------------------------------------

echo
echo "restoring and re-checking the baseline:"
restore
if ! build; then
    echo "  REFUSE: the RESTORED tree does not build. The working tree may be damaged."
    exit 2
fi
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$(snap "$f")"; then
        echo "  REFUSE: $f was not restored byte-identically."
        exit 2
    fi
done
echo "  ok       sources restored byte-identically and the tree builds"

echo
echo "mutations: $MUTATIONS   survivors: $SURVIVORS"
if (( SURVIVORS > 0 )); then
    echo "🔴 GATE FAILED -- a mutation survived. The suite does not prove what it claims."
    exit 1
fi
echo "✅ every mutation was caught."
