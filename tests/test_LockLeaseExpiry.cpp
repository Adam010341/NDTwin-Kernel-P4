/**
 * Tests for A-9: a lock lease that runs out must END, visibly, and a release that arrives after
 * it must be told so rather than answered "released".
 *
 * [Co-developed with claude code -- Adam]
 *
 * Sibling of tests/test_LockManager.cpp, which pins the TTL boundary itself (a lock becomes
 * re-acquirable when its lease runs out, and not before). That property was already true and is
 * not re-tested here. What was NOT true is everything downstream of it:
 *
 *   - expiry never cleared `isLocked`, so it was invisible. No log line, no counter, nothing to
 *     read. LockManager.hpp said so in as many words and left the decision to a later change:
 *     "An expired entry is deliberately left `isLocked == true` on the refusal path ... That is
 *     its own decision and it is not smuggled in here." This is that change;
 *   - `unlock()` therefore answered **true** for a lease that had been dead for hours, and
 *     /ndt/release_lock answered `200 {"status":"released"}` -- the same bytes as a real
 *     release. A caller could not tell "I released it" from "it was taken off me";
 *   - and if somebody else had legitimately acquired in the meantime, that late release cleared
 *     the NEW holder's lock, silently.
 *
 * Why it matters here rather than in the abstract: KNOWN-ISSUES A-9. The Energy-Saving-App takes
 * `routing_lock` with `ttl=300` (Energy-Saving-App/src/app/http.cpp:425) and reaches its two
 * `release_lock()` calls only on paths that need a Simulation-Platform-Manager round trip, so on
 * the TR-5 arms it never released at all -- 0 switches powered off, three arms
 * (doc/audit/2026-08-30_live-traffic-round/FINDING-08_energy-app-locks-itself-out.md).
 *
 * 🔴 WHAT THESE TESTS DO NOT CLAIM. They do not claim ownership is fixed. Two requests --
 * a late one from a dead lease's holder, and a legitimate one from the current holder -- are
 * byte-identical on the wire (`{"type":"routing_lock"}`), and no kernel-local change can separate
 * them. `leaseId` is offered as an OPT-IN: a caller that echoes back the id its acquire returned
 * is refused instead of releasing a stranger's lock. No deployed caller sends it yet, so
 * KNOWN-ISSUES B-2② is still open, and there is a test below that pins the hole open rather than
 * leaving a reader to assume it was closed.
 *
 * Timing: no sleeps. `acquireLock(name, 0)` sets `expiryTime = now`, and every held test is the
 * strict `now < expiryTime`, so a zero TTL is already expired to the next call. Same device
 * test_LockManager.cpp uses, and reachable from the wire (`{"ttl": 0}`).
 */

#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "ndt_core/lock_management/LockManager.hpp"

namespace
{

using Release = LockManager::ReleaseOutcome;
using Renew = LockManager::RenewOutcome;

/// Same list, same reason, as tests/test_LockManager.cpp: it pins the wire vocabulary rather
/// than deriving it from the thing under test.
const std::vector<std::string> kLeaseTestLockNames = {"routing_lock", "graph_lock", "power_lock"};

}  // namespace

// --- a release that arrives after its own lease ran out -------------------------------------

TEST(LockLeaseExpiryTest, ReleasingAnExpiredLeaseIsReportedAsExpiredNotAsReleased)
{
    // The headline. Before A-9 this returned true, and the endpoint turned it into
    // 200 {"status":"released"}.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0)) << "held, and already run out";

    EXPECT_EQ(mgr.release("routing_lock"), Release::Expired)
        << "a lease that ran out was reported as though this caller had released it";
    EXPECT_FALSE(mgr.unlock("routing_lock"))
        << "the two-valued view must agree: nothing was released by this call";
}

TEST(LockLeaseExpiryTest, ALiveLeaseIsStillReleasedNormally)
{
    // The control. Every assertion above is satisfied by "answer Expired to everything", and this
    // is the case that stops it. Deliberately paired with the test above -- a change that made
    // every lock look expired would pass that one and fail this one.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600)) << "held, and in force";

    EXPECT_EQ(mgr.release("routing_lock"), Release::Released);
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 60)) << "and the lock is free afterwards";
}

TEST(LockLeaseExpiryTest, ExpiredAndNeverHeldAreDifferentAnswers)
{
    // These were the same answer before -- `unlock` returned false for one and true for the
    // other, but the endpoint mapped both onto the same sentence once the release path was
    // reached at all. They send a caller to two different places: "your lease ran out" means the
    // work you did afterwards was unprotected; "you never held this" means your acquire is buggy.
    LockManager mgr;
    EXPECT_EQ(mgr.release("routing_lock"), Release::NotHeld) << "nothing was ever acquired";

    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0));
    EXPECT_EQ(mgr.release("routing_lock"), Release::Expired);

    // And the SECOND release of the same lock is NotHeld, not Expired: the lease was reaped by
    // the first call and there is nothing left to have expired. A reap that fired every time
    // would report Expired forever and this case is what catches it.
    EXPECT_EQ(mgr.release("routing_lock"), Release::NotHeld)
        << "the lease was reaped once already; there is nothing here to expire again";
}

TEST(LockLeaseExpiryTest, AnUnknownLockNameIsNotHeldRatherThanExpired)
{
    // A typo must not acquire the vocabulary of a real state. Also pins that the unknown-name
    // early return still fires before anything is reaped.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0)) << "a real, expired lease sits next to it";

    EXPECT_EQ(mgr.release("routing"), Release::NotHeld);
    EXPECT_EQ(mgr.release(""), Release::NotHeld);

    // and the typo must not have reaped or released the real lock's lease
    EXPECT_EQ(mgr.snapshot("routing_lock").expiredLeaseCount, 0u)
        << "an unknown lock name reaped a real lock's lease";
}

// --- the lease id, and what it does and does not close ---------------------------------------

TEST(LockLeaseExpiryTest, ALateReleaseNamingItsOwnLeaseCannotFreeTheLeaseThatReplacedIt)
{
    // The sequence from KNOWN-ISSUES A-9 / B-2②, written out rather than as a property:
    //
    //   A acquires, ttl runs out, B acquires legitimately, A finally releases.
    //
    // Before A-9 the last step cleared B's lock and answered 200. B was never told, and both
    // apps then believed they held the lock that serialises writes to real switches.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0, &a)) << "A's lease, already run out";
    ASSERT_NE(a.leaseId, 0u) << "a successful acquire must name the lease it granted";

    LockManager::AcquireReport b;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &b)) << "B takes the free lock";
    EXPECT_NE(a.leaseId, b.leaseId) << "B was handed A's lease id back";
    EXPECT_TRUE(b.reclaimedExpiredLease)
        << "B took over a lease that had run out, and was not told";

    EXPECT_EQ(mgr.release("routing_lock", a.leaseId), Release::LeaseMismatch)
        << "A's late release was allowed to act on B's lease";
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 60))
        << "A's late release freed B's lock; a third client can now take it";
}

TEST(LockLeaseExpiryTest, ALateReleaseThatNamesNoLeaseStillFreesTheNewHoldersLock)
{
    // 🔴 THIS TEST PINS AN OPEN DEFECT, ON PURPOSE. It is the same sequence as the test above
    // with the lease id left out -- which is what every deployed caller sends today
    // (Energy-Saving-App/src/app/http.cpp:461 and the two others enumerated in
    // LockManager::parseRequest's comment). The kernel cannot tell this request from the real
    // holder's: they are the same bytes. So the hole is still there, and it is KNOWN-ISSUES B-2②.
    //
    // Written as a test rather than as a comment because the alternative -- shipping the
    // lease-id path and letting a reader conclude "release is safe now" -- is exactly the failure
    // test_LockManager.cpp's header describes: an assertion taken for a decision. When an app
    // starts sending `lease`, this test's expectation flips and the flip is the evidence.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0, &a));
    LockManager::AcquireReport b;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &b));

    EXPECT_EQ(mgr.release("routing_lock"), Release::Released)
        << "if this is no longer Released, an owner check has landed -- update KNOWN-ISSUES B-2②";
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 60))
        << "B's lock is free to a third party, which is the defect this test records";
}

TEST(LockLeaseExpiryTest, LeaseIdZeroMeansUnnamedAndKeepsTheOldBehaviourExactly)
{
    // Backward compatibility, asserted rather than assumed: every caller today passes nothing,
    // and the default must not have quietly become "refuse".
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("power_lock", 3600, &a));

    EXPECT_EQ(mgr.release("power_lock", 0), Release::Released);
    ASSERT_TRUE(mgr.acquireLock("power_lock", 3600, &a));
    EXPECT_EQ(mgr.release("power_lock"), Release::Released) << "the defaulted overload agrees";
}

TEST(LockLeaseExpiryTest, TheCurrentLeaseIdIsAcceptedAndAnyOtherIsRefused)
{
    // Discrimination for the check itself: "refuse every lease id" would satisfy the mismatch
    // test above and break the holder.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("graph_lock", 3600, &a));

    EXPECT_EQ(mgr.release("graph_lock", a.leaseId + 1), Release::LeaseMismatch);
    EXPECT_EQ(mgr.release("graph_lock", a.leaseId), Release::Released)
        << "the holder was refused its own lease";
}

TEST(LockLeaseExpiryTest, LeaseIdsAreNeverReusedAcrossAcquiresOrAcrossLocks)
{
    // If ids were per-lock counters, A's stale id would match B's fresh one after one cycle and
    // the mismatch check would silently stop working.
    LockManager mgr;
    LockManager::AcquireReport first, second, other;

    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &first));
    ASSERT_EQ(mgr.release("routing_lock"), Release::Released);
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &second));
    ASSERT_TRUE(mgr.acquireLock("power_lock", 3600, &other));

    EXPECT_NE(first.leaseId, second.leaseId) << "a lease id was reused on the same lock";
    EXPECT_NE(second.leaseId, other.leaseId) << "two locks handed out the same lease id";
    EXPECT_NE(first.leaseId, other.leaseId);
}

// --- expiry has to be visible after the fact --------------------------------------------------

TEST(LockLeaseExpiryTest, AReclaimedLeaseIsCountedAndNamedSoItCanBeSeenAfterwards)
{
    // The observability half. Before A-9 there was no counter, no log line and no read path: the
    // TR-5 write-up had to reconstruct "the lock is held and nobody is releasing it" from the
    // application's own tmux buffer, because nothing on the kernel side could be asked.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0, &a));

    EXPECT_EQ(mgr.snapshot("routing_lock").expiredLeaseCount, 0u)
        << "nothing has looked at the lock yet, so nothing has been reaped yet";

    ASSERT_EQ(mgr.release("routing_lock"), Release::Expired);

    const auto snap = mgr.snapshot("routing_lock");
    EXPECT_EQ(snap.expiredLeaseCount, 1u) << "the reclaimed lease was not counted";
    EXPECT_EQ(snap.lastExpiredLeaseId, a.leaseId)
        << "the counter fired but did not name which lease it was";
    EXPECT_FALSE(snap.held);
}

TEST(LockLeaseExpiryTest, SnapshotAnswersWhoHoldsItAndForHowLongWithoutTakingIt)
{
    // "Is routing_lock held, and for how long" had exactly one way to be asked before: try to
    // take it. That either fails, telling you nothing about how long, or succeeds, which is not
    // a read. An operator following KNOWN-ISSUES A-9's workaround is in that position.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 300, &a));

    const auto snap = mgr.snapshot("routing_lock");
    EXPECT_TRUE(snap.held);
    EXPECT_EQ(snap.leaseId, a.leaseId);
    EXPECT_GT(snap.remainingSeconds, 250) << "remaining=" << snap.remainingSeconds;
    EXPECT_LE(snap.remainingSeconds, 300) << "remaining=" << snap.remainingSeconds;

    // and reading it did not take it, extend it, or free it
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 60)) << "the read released the lock";
    EXPECT_EQ(mgr.snapshot("routing_lock").leaseId, a.leaseId) << "the read moved the lease on";
}

TEST(LockLeaseExpiryTest, SnapshotDoesNotReapTheLeaseItIsReporting)
{
    // A read must not change what it is reading. If snapshot() reaped, an operator looking at the
    // lock would end the holder's lease by looking -- and the reap would be attributed to
    // whichever request happened to arrive next.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0));

    const auto snap = mgr.snapshot("routing_lock");
    EXPECT_FALSE(snap.held) << "an expired lease must read back as not held";
    EXPECT_EQ(snap.expiredLeaseCount, 0u) << "the read reaped the lease it was reporting";

    // the reap is still pending, and the next writer is the one that performs and reports it
    EXPECT_EQ(mgr.release("routing_lock"), Release::Expired);
    EXPECT_EQ(mgr.snapshot("routing_lock").expiredLeaseCount, 1u);
}

TEST(LockLeaseExpiryTest, AnAcquireThatTakesOverADeadLeaseSaysSo)
{
    // The successor's side of the same event. `reclaimedExpiredLease` is how a well-behaved app
    // can notice "the previous holder never released" without waiting for anybody to read a log.
    LockManager mgr;
    LockManager::AcquireReport clean;
    ASSERT_TRUE(mgr.acquireLock("power_lock", 3600, &clean));
    EXPECT_FALSE(clean.reclaimedExpiredLease) << "a first acquire reclaimed something";

    ASSERT_EQ(mgr.release("power_lock"), Release::Released);
    LockManager::AcquireReport afterRelease;
    ASSERT_TRUE(mgr.acquireLock("power_lock", 0, &afterRelease));
    EXPECT_FALSE(afterRelease.reclaimedExpiredLease)
        << "an acquire after a clean release reported a reclaim that did not happen";

    LockManager::AcquireReport afterExpiry;
    ASSERT_TRUE(mgr.acquireLock("power_lock", 3600, &afterExpiry));
    EXPECT_TRUE(afterExpiry.reclaimedExpiredLease)
        << "an acquire took over a lease that had run out and did not say so";
}

TEST(LockLeaseExpiryTest, ARefusedAcquireIsToldWhichLeaseBlocksItAndForHowLong)
{
    // The 423 body used to say "retry after its TTL" -- whose TTL? The caller does not know what
    // ttl the holder asked for. The Energy-Saving-App retries this at 1 Hz for the whole 300 s of
    // somebody else's lease, 183 times in a 242 s window on TR-5, learning nothing each time.
    LockManager mgr;
    LockManager::AcquireReport holder;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 300, &holder));

    LockManager::AcquireReport refused;
    ASSERT_FALSE(mgr.acquireLock("routing_lock", 300, &refused));
    EXPECT_EQ(refused.leaseId, 0u) << "a refused acquire reported a lease it did not get";
    EXPECT_EQ(refused.blockingLeaseId, holder.leaseId);
    EXPECT_GT(refused.remainingSeconds, 250) << "remaining=" << refused.remainingSeconds;
    EXPECT_LE(refused.remainingSeconds, 300) << "remaining=" << refused.remainingSeconds;
}

// --- renew tells the two refusals apart too ----------------------------------------------------

TEST(LockLeaseExpiryTest, RenewingAnExpiredLeaseSaysExpiredAndRenewingNothingSaysNotHeld)
{
    // `bool renew()` already refused both (KNOWN-ISSUES B-2①, 2026-09-01) and the endpoint said
    // "Lock 'X' is expired or not held" -- one sentence for two states. The refusal is unchanged;
    // only the reason is now separable.
    LockManager mgr;
    EXPECT_EQ(mgr.renewLease("routing_lock", 60), Renew::NotHeld) << "never acquired";

    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0));
    EXPECT_EQ(mgr.renewLease("routing_lock", 3600), Renew::Expired);

    // and the refusal must not have taken the lock as a side effect -- renew is not a second door
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 60))
        << "the refused renew left the lock unavailable to a legitimate acquire";
}

TEST(LockLeaseExpiryTest, RenewingALiveLeaseStillSucceedsAndAWrongLeaseIdIsRefused)
{
    // The renew control, plus its lease check. Without the first assertion, "refuse every renew"
    // passes everything above.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("graph_lock", 3600, &a));

    EXPECT_EQ(mgr.renewLease("graph_lock", 7200), Renew::Renewed) << "unnamed lease, as today";
    EXPECT_EQ(mgr.renewLease("graph_lock", 7200, a.leaseId), Renew::Renewed) << "its own lease";
    EXPECT_EQ(mgr.renewLease("graph_lock", 7200, a.leaseId + 1), Renew::LeaseMismatch);

    // the refused renew must not have shortened, extended or freed anything
    EXPECT_FALSE(mgr.acquireLock("graph_lock", 60));
    EXPECT_EQ(mgr.snapshot("graph_lock").leaseId, a.leaseId);
}

TEST(LockLeaseExpiryTest, RenewingOneLockDoesNotReapAnother)
{
    // The reap is a write, and a write reached through the wrong map entry is the shape B-2d took
    // on all three endpoints. graph_lock is left expired; renewing routing_lock must not touch it.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600)) << "live: the one being renewed";
    ASSERT_TRUE(mgr.acquireLock("graph_lock", 0)) << "expired: the one that must stay untouched";

    ASSERT_EQ(mgr.renewLease("routing_lock", 7200), Renew::Renewed);

    EXPECT_EQ(mgr.snapshot("graph_lock").expiredLeaseCount, 0u)
        << "renewing routing_lock reaped graph_lock's lease";
    EXPECT_EQ(mgr.release("graph_lock"), Release::Expired)
        << "graph_lock's pending reap was consumed by an unrelated renew";
}

TEST(LockLeaseExpiryTest, TheThreeLocksExpireIndependently)
{
    // Not generality for its own sake: routing_lock is the one every app takes and the one every
    // reported defect has been about, so a fix written only where the symptom was would leave the
    // other two answering the old way.
    for (const auto& name : kLeaseTestLockNames)
    {
        LockManager mgr;
        ASSERT_TRUE(mgr.acquireLock(name, 0)) << name;
        EXPECT_EQ(mgr.release(name), Release::Expired) << name << ": an expired lease was released";
        EXPECT_EQ(mgr.snapshot(name).expiredLeaseCount, 1u) << name << ": reclaim not counted";
        EXPECT_TRUE(mgr.acquireLock(name, 60)) << name << ": the lock did not come free";
    }
}
