#!/usr/bin/env bash
#
# Mutation gate for KNOWN-ISSUES B-2②: "any caller can release or renew any caller's lock".
#
# [Co-developed with claude code -- Adam]
#
# 🔴 READ THIS FIRST, OR THE GATE WILL BE MISREAD. B-2② IS NOT CLOSED. The mechanism it needs --
# a per-lease token -- exists (LockState::leaseId, from A-9), and the policy that would make it
# mandatory exists (LockManager::setRequireLeaseId), but the policy is OFF BY DEFAULT and nothing
# turns it on, because turning it on refuses every release and renew sent by the four callers in
# this workspace. So this gate proves two different things and they must not be confused:
#
#   - that the STILL-OPEN default behaviour is pinned, so nobody reads the presence of the switch
#     as the switch being on (mutations 1-2);
#   - that the switch, WHEN ON, actually refuses and actually does not act (mutations 3-7).
#
# 🔴 IT HAS NEVER BEEN RUN. Written under a no-build constraint, so tests/test_LockOwnership.cpp
# has been seen neither red nor green. Per the project's mutation-gate rule that is not a
# delivery; running this is the first thing to do with the branch.
#
# Same harness as tests/shell/mutate_lock_renew_expiry.sh (B-2①) and
# tests/shell/mutate_lock_lease_expiry.sh (A-9). Originals are snapshotted before the first
# mutation, an EXIT trap restores them on any exit including interrupt, and the run ends by
# asserting the files are byte-identical to the snapshot -- these files live in a worktree other
# sessions write to. The baseline is the WORKING TREE, not HEAD, so an uncommitted fix is gated
# rather than silently discarded.
#
# Usage:  bash tests/shell/mutate_lock_ownership.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

LOCK=include/ndt_core/lock_management/LockManager.hpp
HTTP=src/ndt_core/http/HttpSession.cpp
BIN=build/bin/test_routing_strategy
FILTER='LockOwnership*:LockManager*:LockLeaseExpiry*:LockEndpoint*'
BK=$(mktemp -d)

cp "$LOCK" "$BK/lock" && cp "$HTTP" "$BK/http"
restore() { cp "$BK/lock" "$LOCK"; cp "$BK/http" "$HTTP"; }
trap 'restore; rm -rf "$BK"' EXIT

build() { cmake --build build --target test_routing_strategy -j"$(nproc)" 2>&1; }
run() { "$BIN" --gtest_filter="$FILTER" 2>&1; }

SURVIVORS=0
BROKEN=0

report() {
    local name="$1" want="$2" out rc
    if ! build > "$BK/build.log" 2>&1; then
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

# Every mutation is a literal replacement asserted to have fired exactly once. A substitution that
# matches nothing edits nothing, and the run then reports the UNMUTATED tree as caught/survived.
# memory/injections-must-assert-their-own-success.
mutate() {   # $1 = file, $2 = literal to find, $3 = literal replacement
    local file="$1" from="$2" to="$3" n
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 REFUSE: the mutation target appears $n times in $file, expected exactly 1"
        echo "     target: $from"
        exit 2
    fi
    FROM="$from" TO="$to" perl -0777 -pi -e 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' "$file"
}

echo "baseline (unmutated) must be green:"
if ! build > "$BK/build.log" 2>&1; then
    echo "  REFUSE: the baseline does not build"
    tail -20 "$BK/build.log" | sed 's/^/    /'
    exit 2
fi
if run | grep -q '^\[  PASSED  \]'; then
    run | grep -E '^\[==========\]|^\[  PASSED  \]|^\[  FAILED  \]' | sed 's/^/  /'
else
    echo "  REFUSE: baseline is not green; mutation results would be meaningless"
    run | tail -20 | sed 's/^/    /'
    exit 2
fi
if run | grep -q '^\[  FAILED  \]'; then
    echo "  REFUSE: baseline has failures"
    exit 2
fi
echo
echo "mutations:"

# --- the still-open default -------------------------------------------------------------------

# 1. Enforcement defaults to ON. This is the mutation that would "fix" B-2② and break four repos
#    on the next deploy, and the only thing standing between the two is one initialiser. The test
#    it must redden is the one that PINS THE DEFECT as still present.
mutate "$LOCK" 'bool m_requireLeaseId = false;' 'bool m_requireLeaseId = true;'
report "enforcement is on by default" \
       "LockOwnershipTest.AnyCallerCanStillReleaseAnyCallersLiveLockWhenNoLeaseIsNamed"

# 2. The unattributable-action counter never increments, so B-2②'s only measurement silently
#    reads zero -- and a zero here would be read as "no unattributed traffic, safe to enforce",
#    which is the exact opposite of the truth.
mutate "$LOCK" \
    'if (m_requireLeaseId) {
                return ReleaseOutcome::LeaseRequired;
            }
            it->second.unattributedActions += 1;' \
    'if (m_requireLeaseId) {
                return ReleaseOutcome::LeaseRequired;
            }'
report "an unattributable release is not counted" \
       "LockOwnershipTest.AnUnattributableReleaseIsCountedEvenThoughItIsAllowed"

# --- what the switch does when it is on --------------------------------------------------------

# 3. Enforcement is checked but does not stop the release: the caller is refused AND the lock is
#    freed anyway. memory/rejected-requests-can-still-act -- the worst shape a refusal can take,
#    and invisible to any test that stops at the return value.
mutate "$LOCK" \
    'if (m_requireLeaseId) {
                return ReleaseOutcome::LeaseRequired;
            }
            it->second.unattributedActions += 1;
        }

        // Reported from inside the mutex' \
    'if (m_requireLeaseId) {
                it->second.isLocked = false;
                return ReleaseOutcome::LeaseRequired;
            }
            it->second.unattributedActions += 1;
        }

        // Reported from inside the mutex'
report "a refused release frees the lock anyway" \
       "LockOwnershipTest.WithEnforcementOnAReleaseNamingNoLeaseIsRefusedAndTheLockStaysHeld"

# 4. The renew half of the switch goes missing. Release is the half everybody talks about, so a
#    fix applied only where the symptom was reported would leave a stranger able to extend
#    somebody else's lease indefinitely -- which is the example KNOWN-ISSUES B-2 actually writes.
mutate "$LOCK" \
    'if (m_requireLeaseId) {
                return RenewOutcome::LeaseRequired;
            }
' \
    ''
report "renew stops enforcing the lease requirement" \
       "LockOwnershipTest.WithEnforcementOnARenewNamingNoLeaseIsRefusedAndNothingIsExtended"

# 5. Enforcement leaks onto locks nobody holds, so a caller whose real problem is 412 gets a 400
#    telling it not to retry. There is nothing to protect on an unheld lock.
mutate "$LOCK" \
    'if (it == m_locks.end()) {
            return ReleaseOutcome::NotHeld;
        }' \
    'if (it == m_locks.end()) {
            return m_requireLeaseId ? ReleaseOutcome::LeaseRequired : ReleaseOutcome::NotHeld;
        }'
report "enforcement leaks onto a lock nobody holds" \
       "LockOwnershipTest.EnforcementDoesNotTurnNotHeldOrExpiredIntoALeaseRequirement"

# 6. The lease check stops discriminating: any non-zero id is accepted. Enforcement would then be
#    satisfied by a caller sending `"lease": 1` forever, which is worse than no enforcement --
#    it looks closed and is not.
mutate "$LOCK" 'if (leaseId != 0 && leaseId != it->second.leaseId) {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "refused a release of {}' \
               'if (false) {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "refused a release of {}'
report "any non-zero lease id is accepted on release" \
       "LockOwnershipTest.WithEnforcementOnAWrongLeaseIsStillAMismatchNotALeaseRequirement"

# --- the wire ---------------------------------------------------------------------------------

# 7. The handler turns the 400 into a 200 with no body change. The LockManager tests cannot see
#    this: the manager refused correctly and the endpoint lied about it afterwards.
#    The target is anchored on the enum name rather than on the message, because the message
#    contains both a backslash-escaped quote and an apostrophe, and a mutation target that needs
#    three levels of shell quoting is a mutation target that will be wrong.
mutate "$HTTP" \
    'if (releaseOutcome == LockManager::ReleaseOutcome::LeaseRequired)
        {
            // 400, not 412: a missing required field, not a state. Only reachable when
            // LockManager::setRequireLeaseId(true) has been called, which nothing does yet.
            res.result(http::status::bad_request);' \
    'if (releaseOutcome == LockManager::ReleaseOutcome::LeaseRequired)
        {
            // 400, not 412: a missing required field, not a state. Only reachable when
            // LockManager::setRequireLeaseId(true) has been called, which nothing does yet.
            res.result(http::status::ok);'
report "handleReleaseLock answers 200 on a lease_required refusal" \
       "LockEndpointTest.WithEnforcementOnAReleaseNamingNoLeaseIs400AndReleasesNothing"

# 8. The lease id stops reaching the release reply, so a caller has no way to notice after the
#    fact that it released a lease that was not its own -- the only detection path that exists
#    while enforcement is off, i.e. today.
mutate "$HTTP" ', {"lease", releasedLease}}.dump();' '}.dump();'
report "the release reply drops the lease it acted on" \
       "LockEndpointTest.ReleasingAHeldLockSucceeds"

restore
build > /dev/null 2>&1
echo
if cmp -s "$BK/lock" "$LOCK" && cmp -s "$BK/http" "$HTTP"; then
    echo "baseline restored: both files byte-identical to the pre-run snapshot"
else
    echo "🔴 BASELINE NOT RESTORED -- a mutant is still on disk:"
    diff -u "$BK/lock" "$LOCK" | head -20
    diff -u "$BK/http" "$HTTP" | head -20
    exit 1
fi
echo "survivors=$SURVIVORS build-failures=$BROKEN"
[[ "$SURVIVORS" -eq 0 && "$BROKEN" -eq 0 ]]
