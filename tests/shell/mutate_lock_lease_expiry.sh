#!/usr/bin/env bash
#
# Mutation gate for the KNOWN-ISSUES A-9 fix: a lock lease that runs out must END, visibly, and a
# release that arrives after it must be told so rather than answered "released".
#
# [Co-developed with claude code -- Adam]
#
# Each mutation below reintroduces one part of the defect, or breaks one half of a property the
# fix rests on, and names the case that must go red. A mutation that SURVIVES means that case is
# decorative.
#
# 🔴 THIS GATE HAS NEVER BEEN RUN. The change it gates was written under a no-build constraint
# (a CPU-sensitive measurement was in progress), so tests/test_LockLeaseExpiry.cpp and the three
# new LockEndpointTest cases have NOT been seen red, and have not been seen green either. Per the
# project's mutation-gate rule that is NOT a delivery. Running this script is the first thing a
# human should do with this branch, and its output is the evidence the fix currently lacks.
#
# Same shape as tests/shell/mutate_lock_renew_expiry.sh, which gates B-2① in the same two files.
# Read that one first if this is unfamiliar; the harness notes below are identical by design.
#
# 🔴 The harness guards its own baseline. Originals are snapshotted before the first mutation, an
# EXIT trap restores them on any exit including interrupt, and the run ends by asserting the files
# are byte-identical to the snapshot. These files live in a worktree other sessions write to.
#
# The baseline is the WORKING TREE, not HEAD: this is meant to be runnable against an uncommitted
# fix, and "restore to HEAD" would silently discard it.
#
# Usage:  bash tests/shell/mutate_lock_lease_expiry.sh
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
FILTER='LockManager*:LockRequestParsing*:LockEndpoint*:LockLeaseExpiry*'
BK=$(mktemp -d)

cp "$LOCK" "$BK/lock" && cp "$HTTP" "$BK/http"
# 🔴 mtime, not content, is what the build system compares. Plain `cp` already stamps the
# restored file with the current time -- but `cp -p` / `cp -a` would put the ORIGINAL mtime back,
# ninja would decide nothing had changed, and the NEXT mutant would be tested against the PREVIOUS
# mutant's object file. Every result after that point would be attributed to the wrong edit, and
# the gate would look like it was working. The touch makes that explicit instead of leaving it
# resting on a flag nobody wrote down. [Co-developed with claude code -- Adam]
restore() {
    cp "$BK/lock" "$LOCK"
    cp "$BK/http" "$HTTP"
    touch "$LOCK" "$HTTP"
}
trap 'restore; rm -rf "$BK"' EXIT

build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$(nproc)" 2>&1; }
run() { "$BIN" --gtest_filter="$FILTER" 2>&1; }

SURVIVORS=0
MUTATIONS=0
# BROKEN and ANCHORS_MISSED are SUBSETS of SURVIVORS, reported separately only so a reader can
# tell "no test noticed the change" from "the change never ran". They are never added on top.
BROKEN=0
ANCHORS_MISSED=0
ANCHOR_MISS=""

# $1 = mutation name, $2 = gtest case that must fail
report() {
    local name="$1" want="$2" out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ -n "${ANCHOR_MISS:-}" ]]; then
        printf '  SURVIVED %-46s (no anchor: %s)\n' "$name" "$ANCHOR_MISS"
        echo "             the mutation never happened, so $want proves nothing about it"
        SURVIVORS=$((SURVIVORS + 1))
        ANCHORS_MISSED=$((ANCHORS_MISSED + 1))
        ANCHOR_MISS=""
        return
    fi
    if [[ "${MUTATE_DRY_RUN:-0}" == "1" ]]; then
        printf '  anchor-ok %-46s (would redden %s)\n' "$name" "$want"
        return
    fi
    if ! build > "$BK/build.log" 2>&1; then
        # A mutation that does not compile proves nothing about the tests: it never reached them.
        # 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, NOT A WARNING. The test never ran,
        # so nothing was proved about it. Giving it its own column let a gate print
        # "survivors=0" with a case sitting unmeasured beside it.
        printf '  SURVIVED %-46s (did not compile -- the test never ran)\n' "$name"
        tail -5 "$BK/build.log" | sed 's/^/             /'
        BROKEN=$((BROKEN + 1))
        SURVIVORS=$((SURVIVORS + 1))
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
# "caught"/"survived" -- ticks that mean nothing. memory/injections-must-assert-their-own-success.
mutate() {   # $1 = file, $2 = literal to find, $3 = literal replacement
    local file="$1" from="$2" to="$3" n
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        # 🔴 NOT `exit 2` ANY MORE. A missing anchor means this mutation never happened, and a
        # mutation that never happened is exactly a survivor: the case it was meant to redden was
        # never put to the test. Aborting the whole gate here also threw away every result after
        # it, which is the wrong trade when one compile window runs every branch's gate in a
        # batch. Recorded here, turned into a survivor by report().
        echo "  🔴 ANCHOR GONE: the mutation target appears $n times in $file, expected exactly 1"
        echo "     target: $from"
        ANCHOR_MISS="found $n times in $file, expected exactly 1"
        return 1
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

# 1. The reap never fires. This is the pre-A-9 tree, verbatim: expiry is asked about but never
#    recorded, `isLocked` stays true forever, and a late release finds the flag set.
mutate "$LOCK" \
    'if (!state.isLocked || now < state.expiryTime) {
            return false;
        }' \
    'if (true) {
            return false;
        }'
report "the lease reap never fires (the defect)" \
       "LockLeaseExpiryTest.ReleasingAnExpiredLeaseIsReportedAsExpiredNotAsReleased"

# 2. The reap fires on the wrong side of the comparison: live leases are reaped, dead ones are
#    not. Presence and direction have to be pinned separately, or "it compares something" passes.
mutate "$LOCK" '!state.isLocked || now < state.expiryTime' \
               '!state.isLocked || now >= state.expiryTime'
report "the reap's expiry comparison is inverted" \
       "LockLeaseExpiryTest.ALiveLeaseIsStillReleasedNormally"

# 3. The reap ends the lease but records nothing. Every outcome test still passes; only the
#    observability half can see this, and observability is half of what A-9 is about.
mutate "$LOCK" \
    'state.expiredLeaseId = state.leaseId;
        state.expiredLeaseCount += 1;' \
    ''
report "an expired lease is reclaimed but not recorded" \
       "LockLeaseExpiryTest.AReclaimedLeaseIsCountedAndNamedSoItCanBeSeenAfterwards"

# 4. The outcome itself: release calls an expired lease a release. The state change is correct,
#    only the answer lies -- which is precisely the pre-A-9 endpoint behaviour.
mutate "$LOCK" 'return ReleaseOutcome::Expired;' 'return ReleaseOutcome::Released;'
report "release reports an expired lease as released" \
       "LockLeaseExpiryTest.ReleasingAnExpiredLeaseIsReportedAsExpiredNotAsReleased"

# 5. Lease ids stop being unique. Every outcome test still passes -- until a stale id from one
#    cycle matches a fresh one from the next and the mismatch check silently stops working.
mutate "$LOCK" 'state.leaseId = m_nextLeaseId++;' 'state.leaseId = 1;'
report "lease ids are reused" \
       "LockLeaseExpiryTest.LeaseIdsAreNeverReusedAcrossAcquiresOrAcrossLocks"

# 6. The opt-in ownership check goes. A caller naming a superseded lease releases the current
#    holder's lock again -- the sequence KNOWN-ISSUES A-9 and B-2② are both about.
mutate "$LOCK" \
    'if (leaseId != 0 && leaseId != it->second.leaseId) {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "refused a release of {} naming lease {}; the current lease is {}. "
                               "The lock was NOT released",
                               lockTypeToString(type), leaseId, it->second.leaseId);
            return ReleaseOutcome::LeaseMismatch;
        }

' \
    ''
report "release stops checking the lease it was given" \
       "LockLeaseExpiryTest.ALateReleaseNamingItsOwnLeaseCannotFreeTheLeaseThatReplacedIt"

# 7. The read reaps. An operator looking at the lock would end the holder's lease by looking, and
#    the reclaim would be attributed to whichever request happened to arrive next.
mutate "$LOCK" \
    'const auto now = std::chrono::steady_clock::now();
        out.expiredLeaseCount' \
    'const auto now = std::chrono::steady_clock::now();
        reapIfExpired(type, it->second, now);
        out.expiredLeaseCount'
report "snapshot() reaps the lease it reports" \
       "LockLeaseExpiryTest.SnapshotDoesNotReapTheLeaseItIsReporting"

# 8. The handler side: the expired refusal loses its status code and answers 200 like a success.
#    The LockManager tests cannot see this at all -- it is why the endpoint has its own cases.
mutate "$HTTP" \
    'const bool expired = (releaseOutcome == LockManager::ReleaseOutcome::Expired);
            res.result(http::status::precondition_failed);' \
    'const bool expired = (releaseOutcome == LockManager::ReleaseOutcome::Expired);
            res.result(http::status::ok);'
report "handleReleaseLock answers 200 on an expired lease" \
       "LockEndpointTest.ReleasingAnExpiredLeaseIs412AndSaysExpiredRatherThan200Released"

# 9. The lease never reaches the wire, so the opt-in check of mutation 6 has no way to be used by
#    anybody. A LockManager-only test suite cannot see this either.
mutate "$HTTP" '{"lease", report.leaseId},
                              ' ''
report "the acquire reply drops the lease id" \
       "LockEndpointTest.AnAcquireHandsBackALeaseIdAndSaysWhenItTookOverADeadOne"

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
    printf 'GATE-SUMMARY name=%s mode=dry-run anchors=%d mutations=0 killed=0 survived=%d build_failures=0 anchors_missed=%d\n' \
           "$GATE_NAME" "$MUTATIONS" "$ANCHORS_MISSED" "$ANCHORS_MISSED"
    if [[ "$ANCHORS_MISSED" -gt 0 ]]; then
        echo "dry run: $ANCHORS_MISSED of $MUTATIONS anchors NO LONGER MATCH the source."
        echo "Those mutations cannot run at all, which makes them survivors, not warnings."
        exit 1
    fi
    echo "dry run: $MUTATIONS anchors each matched exactly once."
    echo "NOTHING was mutated, built or executed -- this is not a mutation result."
    exit 0
fi

# killed = mutations - survivors. build_failures and anchors_missed are SUBSETS of survived --
# printed so a reader can tell "no test noticed" from "the test never ran" -- never added on top.
printf 'GATE-SUMMARY name=%s mode=run mutations=%d killed=%d survived=%d build_failures=%d anchors_missed=%d\n' \
       "$GATE_NAME" "$MUTATIONS" "$((MUTATIONS - SURVIVORS))" "$SURVIVORS" "$BROKEN" "$ANCHORS_MISSED"
echo "survivors=$SURVIVORS (of which $BROKEN did not compile, $ANCHORS_MISSED had no anchor)"
# BROKEN and ANCHORS_MISSED are already inside SURVIVORS; testing them again would be double
# counting, and testing only BROKEN was how a never-compiled mutant used to pass this line.
[[ "$SURVIVORS" -eq 0 ]]
