#!/usr/bin/env bash
#
# One entry point for every mutation gate on the lock code: A-9, KNOWN-ISSUES B-2① and B-2②.
#
# [Co-developed with claude code -- Adam]
#
#   bash tests/shell/mutate_lock_lease_all.sh              # build, baseline, all three gates
#   bash tests/shell/mutate_lock_lease_all.sh --dry-run    # anchors only: no build, no mutation
#   BUILD_DIR=build-rel bash tests/shell/mutate_lock_lease_all.sh
#
# 🔴 THE THREE GATES HAVE NEVER BEEN RUN FOR REAL. They were written under a no-build constraint
# (a CPU-sensitive measurement was in progress), so tests/test_LockLeaseExpiry.cpp,
# tests/test_LockOwnership.cpp and the five new LockEndpointTest cases have been seen neither red
# nor green. `--dry-run` HAS been run, and it proves exactly one thing: that all 23 mutation
# anchors still match the source exactly once. That is not a mutation result and this script says
# so in as many words when it runs in that mode.
#
# WHAT IT DOES
#   1. builds ONLY the test target -- never the whole tree, never a configure step;
#   2. runs the lock tests as a baseline. Red => exit 2, naming the cases. A mutation run against
#      a red baseline measures nothing, so it refuses rather than reporting;
#   3. runs the full suite too, because this branch edits HttpSession.cpp, which most of the
#      suite links. A red NON-lock test is reported loudly but does not refuse -- the gates below
#      do not measure those, and blocking a lock gate on unrelated breakage helps nobody;
#   4. runs each gate with MUTATE_SKIP_BASELINE=1 (step 2 already did it) and the same BUILD_DIR;
#   5. aggregates each gate's GATE-SUMMARY line into one verdict;
#   6. asserts both mutated sources are byte-identical to their pre-run snapshots.
#
# EXIT: 0 clean, 1 survivors or build-failed mutants, 2 refused (no build / red baseline / a gate
# refused, which happens when a mutation anchor no longer matches the source).
#
# No process is ever killed -- no pkill, no pgrep, nothing signals anything. Every exit code that
# decides something is captured unpiped, because `cmd | grep -q` reports on the grep.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $arg (try --dry-run)"; exit 2 ;;
    esac
done

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"

# 🔴 The target is test_routing_strategy, NOT test_LockManager. tests/CMakeLists.txt declares one
# test executable (plus fuzz_sflow); test_LockManager.cpp, test_LockLeaseExpiry.cpp,
# test_LockOwnership.cpp and test_HttpSessionStatusCodes.cpp are all translation units inside it.
# There is no per-file test binary to build.
LOCK_FILTER='LockManager*:LockRequestParsing*:LockEndpoint*:LockLeaseExpiry*:LockOwnership*'

SOURCES=(
    include/ndt_core/lock_management/LockManager.hpp
    src/ndt_core/http/HttpSession.cpp
)

GATES=(
    "$HERE/mutate_lock_lease_expiry.sh"    # A-9        -- lease expiry is an event, not a condition
    "$HERE/mutate_lock_renew_expiry.sh"    # B-2 case 1 -- an expired lease cannot be renewed
    "$HERE/mutate_lock_ownership.sh"       # B-2 case 2 -- the lease id, and the unwired switch
)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for src in "${SOURCES[@]}"; do
    cp "$src" "$WORK/$(tr '/' '_' <<<"$src")"
done

hr() { printf '%s\n' "======================================================================"; }

# ---------------------------------------------------------------- 1 + 2 + 3: build and baseline

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY RUN -- anchors only. Nothing is built, mutated or executed."
    echo
else
    hr
    echo "building $TARGET in $BUILD_DIR (this target only)"
    if ! cmake --build "$BUILD_DIR" --target "$TARGET" -j"$(nproc)" > "$WORK/build.log" 2>&1; then
        echo "REFUSE: the baseline does not build"
        tail -30 "$WORK/build.log" | sed 's/^/    /'
        exit 2
    fi
    if [[ ! -x "$BIN" ]]; then
        echo "REFUSE: $BIN is missing or not executable after a successful build"
        exit 2
    fi
    echo "  built: $BIN"

    hr
    echo "baseline, lock tests ($LOCK_FILTER)"
    lock_out=$("$BIN" --gtest_filter="$LOCK_FILTER" 2>&1); lock_rc=$?
    if [[ "$lock_rc" -ne 0 ]]; then
        echo "REFUSE: the lock baseline is red (rc=$lock_rc). Mutation results would be"
        echo "        meaningless -- every mutant would 'go red' for a reason nobody chose."
        grep -E '^\[  FAILED  \]' <<<"$lock_out" | sed 's/^/    /'
        exit 2
    fi
    grep -E '^\[==========\]|^\[  PASSED  \]' <<<"$lock_out" | sed 's/^/  /'

    hr
    echo "baseline, full suite (this branch edits HttpSession.cpp, which most of it links)"
    all_out=$("$BIN" 2>&1); all_rc=$?
    grep -E '^\[==========\]|^\[  PASSED  \]|^\[  FAILED  \] [0-9]+ test' <<<"$all_out" | sed 's/^/  /'
    NONLOCK_RED=0
    if [[ "$all_rc" -ne 0 ]]; then
        NONLOCK_RED=1
        echo
        echo "  ⚠️  the full suite is red while the lock tests are green. These are NOT measured"
        echo "      by the gates below, and this script does not refuse on them -- but somebody"
        echo "      has to look, because this branch touches a file most of the suite links:"
        grep -E '^\[  FAILED  \]' <<<"$all_out" | grep -vE 'Lock(Manager|Request|Endpoint|LeaseExpiry|Ownership)' \
            | sed 's/^/        /'
    fi
    echo
fi

# ------------------------------------------------------------------------------- 4 + 5: the gates

TOTAL_MUT=0
TOTAL_KILLED=0
TOTAL_SURV=0
TOTAL_BROKEN=0
TOTAL_ANCHORS=0
REFUSED=0

for gate in "${GATES[@]}"; do
    name="$(basename "$gate" .sh)"
    log="$WORK/$name.log"
    hr
    echo "gate: $name"

    MUTATE_SKIP_BASELINE=1 MUTATE_DRY_RUN="$DRY_RUN" BUILD_DIR="$BUILD_DIR" bash "$gate" > "$log" 2>&1
    rc=$?

    sed 's/^/  /' "$log"

    summary=$(grep -m1 '^GATE-SUMMARY ' "$log")
    if [[ -z "$summary" ]]; then
        echo "  🔴 $name printed no GATE-SUMMARY line (rc=$rc). Treating as refused."
        REFUSED=$((REFUSED + 1))
        continue
    fi

    field() { sed -n "s/.* $1=\([0-9][0-9]*\).*/\1/p" <<<"$summary"; }
    g_anchors=$(field anchors); g_anchors=${g_anchors:-0}
    g_mut=$(field mutations);   g_mut=${g_mut:-0}
    g_kill=$(field killed);     g_kill=${g_kill:-0}
    g_surv=$(field survived);   g_surv=${g_surv:-0}
    g_brok=$(field build_failures); g_brok=${g_brok:-0}

    TOTAL_ANCHORS=$((TOTAL_ANCHORS + g_anchors))
    TOTAL_MUT=$((TOTAL_MUT + g_mut))
    TOTAL_KILLED=$((TOTAL_KILLED + g_kill))
    TOTAL_SURV=$((TOTAL_SURV + g_surv))
    TOTAL_BROKEN=$((TOTAL_BROKEN + g_brok))

    # rc 2 is a REFUSE: a mutation anchor no longer matches the source. That is not a survivor and
    # must not be aggregated as one -- it means the gate could not run at all. It is exactly what
    # happened to mutate_lock_renew_expiry.sh when A-9 refactored the code under it.
    if [[ "$rc" -eq 2 ]]; then
        echo "  🔴 $name REFUSED (rc=2) -- an anchor no longer matches the source."
        REFUSED=$((REFUSED + 1))
    fi
done

# ------------------------------------------------------------------- 6: the sources came back

hr
DRIFTED=0
for src in "${SOURCES[@]}"; do
    snap="$WORK/$(tr '/' '_' <<<"$src")"
    if cmp -s "$snap" "$src"; then
        echo "  unchanged: $src"
    else
        echo "  🔴 MUTANT LEFT ON DISK: $src"
        diff -u "$snap" "$src" | head -30 | sed 's/^/      /'
        DRIFTED=$((DRIFTED + 1))
    fi
done

# ---------------------------------------------------------------------------------- the verdict

hr
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY RUN: $TOTAL_ANCHORS mutation anchors, each matching the source exactly once."
    echo "This is NOT a mutation result. Nothing was built, mutated or executed."
else
    echo "$TOTAL_MUT mutations, $TOTAL_SURV survived (killed $TOTAL_KILLED, build-failed $TOTAL_BROKEN)"
fi
[[ "$REFUSED" -gt 0 ]] && echo "$REFUSED gate(s) REFUSED and measured nothing"
[[ "$DRIFTED" -gt 0 ]] && echo "$DRIFTED source(s) NOT restored"
echo

# --------------------------------------------------- tests that are green on purpose, not by luck

cat <<'PINNED'
EXPECTED-GREEN-ON-BASELINE (these pin defects that are still OPEN -- they are not survivors):

  LockLeaseExpiryTest.ALateReleaseThatNamesNoLeaseStillFreesTheNewHoldersLock
  LockOwnershipTest.AnyCallerCanStillReleaseAnyCallersLiveLockWhenNoLeaseIsNamed
  LockOwnershipTest.AnyCallerCanStillRenewAnyCallersLiveLease

  Three, not two. Each ASSERTS THAT A DEFECT IS STILL PRESENT: a release or renew that names no
  lease still acts on somebody else's live lock, because two such requests are the same bytes on
  the wire and no kernel-local change can separate them (KNOWN-ISSUES B-2②, still OPEN).

  They exist so that the presence of the `lease` field and of LockManager::setRequireLeaseId()
  cannot be mistaken for the hole being closed -- the failure test_LockManager.cpp's own header
  describes, where a green test gets taken for a decision. When an app starts sending `lease` and
  the switch is turned on, these expectations FLIP, and the flip is the evidence.

  A SURVIVOR is a different thing entirely: a mutation that no test noticed. These three are
  killed by mutations of their own -- the first by "release stops checking the lease it was
  given", the second and third by "enforcement is on by default" -- so they are load-bearing in
  both directions and neither is decorative.
PINNED
echo

if [[ "$REFUSED" -gt 0 || "$DRIFTED" -gt 0 ]]; then
    exit 2
fi
if [[ "$DRY_RUN" -eq 0 && ( "$TOTAL_SURV" -gt 0 || "$TOTAL_BROKEN" -gt 0 ) ]]; then
    exit 1
fi
exit 0
