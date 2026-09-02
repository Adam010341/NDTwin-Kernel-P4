#!/usr/bin/env bash
#
# Mutation gate for the KNOWN-ISSUES B-2① fix: LockManager::renew() must refuse a lease that has
# already run out.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation below reintroduces one part of the defect, or breaks one half of the property the
# fix rests on, and names the case that must go red. A mutation that SURVIVES means that case is
# decorative.
#
# 🔴 THIS GATE MATTERS MORE THAN USUAL HERE, because the test suite it is gating used to assert
# the DEFECT. tests/test_LockManager.cpp had `RenewingAnExpiredLockPutsItBackInForce`, green,
# with a written rationale -- so "the tests pass" was true before the fix and is true after it,
# and only a mutation run can tell you which of the two the suite is actually pinning.
#
# 🔴 The harness guards its own baseline. Originals are snapshotted before the first mutation, an
# EXIT trap restores them on any exit including interrupt, and the run ends by asserting the files
# are byte-identical to the snapshot. These files live in a worktree other sessions write to.
#
# The baseline is the WORKING TREE, not HEAD: this is meant to be runnable against an uncommitted
# fix, and "restore to HEAD" would silently discard it.
#
# Usage:  bash tests/shell/mutate_lock_renew_expiry.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

LOCK=include/ndt_core/lock_management/LockManager.hpp
HTTP=src/ndt_core/http/HttpSession.cpp
# [Co-developed with claude code -- Adam]
# BUILD_DIR is honoured so tests/shell/mutate_lock_lease_all.sh can point all three gates at one
# build tree. Only TARGET is ever built -- never the whole tree, and never a configure step.
BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
GATE_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='LockManager*:LockRequestParsing*:LockEndpoint*'
BK=$(mktemp -d)

cp "$LOCK" "$BK/lock" && cp "$HTTP" "$BK/http"
restore() { cp "$BK/lock" "$LOCK"; cp "$BK/http" "$HTTP"; }
trap 'restore; rm -rf "$BK"' EXIT

build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$(nproc)" 2>&1; }
run() { "$BIN" --gtest_filter="$FILTER" 2>&1; }

SURVIVORS=0
BROKEN=0
MUTATIONS=0

# $1 = mutation name, $2 = gtest case that must fail, $3 = the perl edit's target file
report() {
    local name="$1" want="$2" out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "${MUTATE_DRY_RUN:-0}" == "1" ]]; then
        printf '  anchor-ok %-46s (would redden %s)\n' "$name" "$want"
        return
    fi
    if ! build > "$BK/build.log" 2>&1; then
        # A mutation that does not compile proves nothing about the tests: it never reached them.
        printf '  BUILD-FAIL %-44s (the mutation did not compile -- it tested nothing)\n' "$name"
        tail -5 "$BK/build.log" | sed 's/^/             /'
        BROKEN=$((BROKEN + 1))
        restore
        return
    fi
    out=$(run); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $want" <<<"$out"; then
        printf '  caught   %-46s (%s went red)\n' "$name" "$want"
    else
        printf '  SURVIVED %-46s (%s stayed green -- that case proves nothing)\n' "$name" "$want"
        grep -E '^\[  FAILED  \]' <<<"$out" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# Every mutation is a literal string replacement asserted to have fired exactly once. A perl
# substitution that matches nothing edits nothing, and the run then reports the UNMUTATED tree as
# "caught"/"survived" -- four green ticks that mean nothing. memory/injections-must-assert-their-
# own-success.
mutate() {   # $1 = file, $2 = literal to find, $3 = literal replacement
    local file="$1" from="$2" to="$3" n
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 REFUSE: the mutation target appears $n times in $file, expected exactly 1"
        echo "     target: $from"
        exit 2
    fi
    # Anchor-only pass. The target was found exactly once, which is the whole of what a dry run
    # checks -- and it is the check that goes stale silently when somebody refactors the code
    # under this gate. Running it costs a second; finding out after a 20-minute build does not.
    [[ "${MUTATE_DRY_RUN:-0}" == "1" ]] && return 0
    FROM="$from" TO="$to" perl -0777 -pi -e 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' "$file"
}

# [Co-developed with claude code -- Adam]
# Rewritten 2026-09-02: this ran the suite up to three times and judged it on `run | grep -q`,
# so the verdict came from the PIPE's exit code and the binary's own rc was discarded. One run,
# rc captured unpiped, and the failing case names printed.
baseline_check() {
    local out rc
    out=$(run); rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "  REFUSE: baseline is not green (rc=$rc); mutation results would be meaningless"
        grep -E '^\[  FAILED  \]' <<<"$out" | sed 's/^/    /'
        exit 2
    fi
    grep -E '^\[==========\]|^\[  PASSED  \]' <<<"$out" | sed 's/^/  /'
}

if [[ "${MUTATE_DRY_RUN:-0}" == "1" ]]; then
    echo "dry run: mutation anchors only -- nothing is built, mutated or executed"
elif ! build > "$BK/build.log" 2>&1; then
    echo "  REFUSE: the baseline does not build"
    tail -20 "$BK/build.log" | sed 's/^/    /'
    exit 2
elif [[ "${MUTATE_SKIP_BASELINE:-0}" == "1" ]]; then
    echo "baseline: already checked by the batch runner (MUTATE_SKIP_BASELINE=1)"
else
    echo "baseline (unmutated) must be green:"
    baseline_check
fi
echo
echo "mutations:"

# 🔴 ALL SIX TARGETS BELOW WERE REWRITTEN ON 2026-09-02, and the reason is worth reading before
#    the mutations themselves.
#
#    The A-9 change (commit "End a lock lease that runs out...") replaced renew()'s inline
#    `|| now >= it->second.expiryTime` with a call to the shared reapIfExpired(), and turned
#    `bool renew()` into a wrapper over `RenewOutcome renewLease()`. B-2①'s GUARANTEE is intact --
#    an expired lease still cannot be renewed, and the same LockManagerTest cases still pin it --
#    but every one of this file's six literal targets stopped existing. `mutate()` REFUSES on a
#    target it cannot find exactly once, so the gate would have exited 2 rather than passing
#    silently; it was still a gate that could no longer be run.
#
#    🔑 A mutation gate is source-coupled by construction: it names lines. So a refactor of the
#    code under it is also a change to the gate, and "the tests are still green" does not tell you
#    the gate survived. This one was found by re-counting the targets after the refactor, not by
#    running anything -- see the A-9 findings.

# 1. The fix itself, removed: renew stops asking whether the lease has run out. This is the
#    shipped defect, verbatim -- an expired lease is still flagged isLocked, so it falls through.
mutate "$LOCK" \
    'if (reapIfExpired(type, it->second, now)) {
            return RenewOutcome::Expired;
        }
' \
    ''
report "renew drops the expiry check (the defect)" \
       "LockManagerTest.RenewingAnExpiredLeaseIsRefusedRatherThanResurrectingIt"

# 2. The comparison is present but backwards -- reaps live leases, spares dead ones. The direction
#    has to be pinned separately from the presence, or "it compares something" passes.
mutate "$LOCK" '!state.isLocked || now < state.expiryTime' \
               '!state.isLocked || now >= state.expiryTime'
report "the expiry comparison is inverted" \
       "LockManagerTest.RenewingALockThatIsStillInForceRewritesItsDeadline"

# 3. renew answers Renewed without writing the new deadline. Every refusal test still passes; only
#    the ttl-0 shrink probe can see this.
mutate "$LOCK" \
    'it->second.expiryTime = now + std::chrono::seconds(ttlSeconds);
        return RenewOutcome::Renewed;' \
    'return RenewOutcome::Renewed;'
report "renew reports success without extending" \
       "LockManagerTest.RenewingALockThatIsStillInForceRewritesItsDeadline"

# 4. The held check goes. A released lock keeps its old expiryTime and its cleared isLocked, so
#    without this check a lock that was explicitly unlocked becomes renewable again.
mutate "$LOCK" \
    'if (!it->second.isLocked) {
            return RenewOutcome::NotHeld;
        }' \
    ''
report "renew stops checking isLocked" "LockManagerTest.RenewingALockNobodyHoldsIsRefused"

# 5. An absent entry is created instead of being refused, so renew becomes a second way to take a
#    lock that was never acquired -- bypassing the held check entirely.
mutate "$LOCK" \
    'if (it == m_locks.end()) {
            return RenewOutcome::NotHeld;
        }' \
    'if (it == m_locks.end()) {
            m_locks[type].isLocked = true;
            m_locks[type].expiryTime = now + std::chrono::seconds(ttlSeconds);
            return RenewOutcome::Renewed;
        }'
report "renew creates a lock nobody acquired" "LockManagerTest.RenewingALockNobodyHoldsIsRefused"

# 6. The handler side: the refusal loses its own status code and answers 200 like a success. The
#    LockManager tests cannot see this at all -- it is why the endpoint has its own cases.
mutate "$HTTP" \
    'const bool expired = (renewOutcome == LockManager::RenewOutcome::Expired);
            res.result(http::status::precondition_failed); // 412 Precondition Failed' \
    'const bool expired = (renewOutcome == LockManager::RenewOutcome::Expired);
            res.result(http::status::ok);'
report "handleRenewLock answers 200 on a refused renew" \
       "LockEndpointTest.RenewingAnExpiredLeaseIs412AndLeavesTheLockAcquirable"

restore
[[ "${MUTATE_DRY_RUN:-0}" == "1" ]] || build > /dev/null 2>&1
echo
if cmp -s "$BK/lock" "$LOCK" && cmp -s "$BK/http" "$HTTP"; then
    echo "baseline restored: both files byte-identical to the pre-run snapshot"
else
    echo "🔴 BASELINE NOT RESTORED -- a mutant is still on disk:"
    diff -u "$BK/lock" "$LOCK" | head -20
    diff -u "$BK/http" "$HTTP" | head -20
    exit 1
fi
# One machine-readable line per gate, for tests/shell/mutate_lock_lease_all.sh to aggregate.
#
# 🔑 A DRY RUN GETS ITS OWN LINE AND REPORTS NO KILLS. The first version of this printed
# `killed=9 survived=0` after a run that had built nothing and executed nothing -- an instrument
# reporting its own finding, which is the exact shape this repo keeps getting caught by. A reader
# skimming for "survived=0" would have taken an anchor check for a passing mutation gate.
if [[ "${MUTATE_DRY_RUN:-0}" == "1" ]]; then
    printf 'GATE-SUMMARY name=%s mode=dry-run anchors=%d mutations=0 killed=0 survived=0 build_failures=0\n' \
           "$GATE_NAME" "$MUTATIONS"
    echo "dry run: $MUTATIONS anchors each matched exactly once."
    echo "NOTHING was mutated, built or executed -- this is not a mutation result."
    exit 0
fi

printf 'GATE-SUMMARY name=%s mode=run mutations=%d killed=%d survived=%d build_failures=%d\n' \
       "$GATE_NAME" "$MUTATIONS" "$((MUTATIONS - SURVIVORS - BROKEN))" "$SURVIVORS" "$BROKEN"
echo "survivors=$SURVIVORS build-failures=$BROKEN"
[[ "$SURVIVORS" -eq 0 && "$BROKEN" -eq 0 ]]
