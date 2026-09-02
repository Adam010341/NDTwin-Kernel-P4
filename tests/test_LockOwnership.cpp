/**
 * Tests for KNOWN-ISSUES B-2②: "any caller can release or renew any caller's lock".
 *
 * [Co-developed with claude code -- Adam]
 *
 * B-2 has two halves and the entry is explicit that they must not be closed together. ① --
 * renewing a lease that had already run out -- was fixed on 2026-09-01 (commit 554cae2f) and is
 * covered by tests/test_LockManager.cpp plus tests/shell/mutate_lock_renew_expiry.sh. ② is this
 * file: while the lease is still ALIVE, a caller that has never held it can release it or extend
 * it, because LockState carried no token and release/renew took a lock NAME and nothing else.
 *
 * 🔑 B-2② DOES NOT NEED A MECHANISM OF ITS OWN. `LockState::leaseId` -- added for A-9 so that an
 * expired lease could be told apart from a live one -- is already the token this needs, in the
 * only form a kernel with no credential on the wire can have one. Building a second notion of
 * ownership beside it would give one question two answers, which is precisely how B-2① came
 * about (renew and acquireLock disagreeing about "held", forty lines apart). So what is added
 * here is not a token but a POLICY: LockManager::setRequireLeaseId(), which decides whether the
 * token is optional or mandatory.
 *
 * 🔴 IT IS OFF BY DEFAULT AND NOTHING TURNS IT ON, so B-2② IS STILL OPEN. Turning it on refuses
 * every release and renew sent by Energy-Saving-App, Traffic-Engineering-App, the chaos harness
 * and tools/contract_test/spec.py, none of which send a lease. That is a flag day across four
 * repos and it is Adam's decision, not this class's. The tests below therefore come in two
 * groups, and the first group asserts that the defect is still there:
 *
 *   - "still open" cases pin today's behaviour, so that a future reader cannot mistake the
 *     presence of the switch for the switch being on. When an app starts sending `lease` and the
 *     switch is flipped, these expectations flip with it, and that flip is the evidence;
 *   - "enforcement" cases pin what happens when it is on, so the switch is not an untested claim.
 *
 * No sleeps: every lock here is taken with a long TTL, because B-2② is about LIVE leases. The
 * expired ones are tests/test_LockLeaseExpiry.cpp's subject.
 */

#include <string>

#include <gtest/gtest.h>

#include "ndt_core/lock_management/LockManager.hpp"

namespace
{

using Release = LockManager::ReleaseOutcome;
using Renew = LockManager::RenewOutcome;

}  // namespace

// [Co-developed with claude code -- Adam]
// Every test below builds its own LockManager in place and repeats three or four setup lines.
// That is not an oversight waiting for a fixture: LockManager owns a std::mutex, so it is neither
// copyable nor movable, and a `LockManager makeHeld(...)` helper cannot exist. A fixture holding
// one by value would work, but the setup differs per test (which lock, live or expired,
// enforcement on before or after the acquire) and hiding that in SetUp() is what makes a lock
// test stop saying which sequence it is testing.

// --- group 1: the defect, still open, pinned -----------------------------------------------

TEST(LockOwnershipTest, AnyCallerCanStillReleaseAnyCallersLiveLockWhenNoLeaseIsNamed)
{
    // 🔴 THIS TEST ASSERTS A DEFECT. KNOWN-ISSUES B-2②, verbatim: A holds routing_lock, B has
    // never held anything, B releases, and it works. Measured live on 2026-08-30 as well -- a
    // bare curl that never acquired released the Energy-Saving-App's lock and got 200
    // (doc/audit/2026-08-30_live-traffic-round/FINDING-08, "Also observed, out of PREREG scope").
    //
    // The kernel cannot separate the two requests: `{"type":"routing_lock"}` from A and from B
    // are the same bytes. Closing this means making `lease` mandatory -- see group 2.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &a)) << "A's lease, alive";

    EXPECT_EQ(mgr.release("routing_lock"), Release::Released)
        << "if this is no longer Released, enforcement is on by default -- update KNOWN-ISSUES B-2②";
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 60))
        << "B released A's live lock and a third party can take it: the defect, still open";
}

TEST(LockOwnershipTest, AnyCallerCanStillRenewAnyCallersLiveLease)
{
    // The renew half, which is the example KNOWN-ISSUES B-2 actually writes out. Since B-2① this
    // only works while the lease is alive -- a dead one is refused -- so the live case is exactly
    // what is left of the original defect.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &a));

    EXPECT_EQ(mgr.renewLease("routing_lock", 7200), Renew::Renewed)
        << "if this is no longer Renewed, enforcement is on by default";
}

TEST(LockOwnershipTest, AnUnattributableReleaseIsCountedEvenThoughItIsAllowed)
{
    // The measurement B-2② has never had. The entry has said "any caller can release any caller's
    // lock" since round 2 with no number attached, because nothing counted -- and a defect with
    // no counter cannot tell you when it is safe to close.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &a));
    EXPECT_EQ(mgr.snapshot("routing_lock").unattributedActions, 0u) << "acquire is not an action";

    ASSERT_EQ(mgr.release("routing_lock"), Release::Released);
    EXPECT_EQ(mgr.snapshot("routing_lock").unattributedActions, 1u);

    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &a));
    ASSERT_EQ(mgr.renewLease("routing_lock", 3600), Renew::Renewed);
    EXPECT_EQ(mgr.snapshot("routing_lock").unattributedActions, 2u) << "renew counts too";
}

TEST(LockOwnershipTest, AnAttributedActionIsNotCountedAsUnattributable)
{
    // The control. "Count everything" would satisfy the test above and make the number useless
    // the moment a caller starts doing the right thing -- which is the one moment it has to be
    // right, because that number is what says how far the migration has got.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &a));

    ASSERT_EQ(mgr.renewLease("routing_lock", 3600, a.leaseId), Renew::Renewed);
    ASSERT_EQ(mgr.release("routing_lock", a.leaseId), Release::Released);
    EXPECT_EQ(mgr.snapshot("routing_lock").unattributedActions, 0u)
        << "a caller that named its own lease was counted as unattributable";
}

TEST(LockOwnershipTest, ARefusedActionIsNotCountedAsOneThatHappened)
{
    // The counter says how many unattributable actions were TAKEN, not how many were attempted.
    // A refusal changed nothing, and counting it would inflate exactly the number an operator
    // would use to decide whether enforcement is safe to turn on.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &a));
    mgr.setRequireLeaseId(true);

    ASSERT_EQ(mgr.release("routing_lock"), Release::LeaseRequired);
    EXPECT_EQ(mgr.snapshot("routing_lock").unattributedActions, 0u)
        << "a refused release was counted as an unattributable action that happened";
}

// --- group 2: what the switch does when it is on ---------------------------------------------

TEST(LockOwnershipTest, EnforcementIsOffByDefault)
{
    // Asserted rather than assumed. A default of "on" would break four repos on the next deploy,
    // and the difference between the two defaults is one character in a member initialiser.
    LockManager mgr;
    EXPECT_FALSE(mgr.requiresLeaseId());
}

TEST(LockOwnershipTest, WithEnforcementOnAReleaseNamingNoLeaseIsRefusedAndTheLockStaysHeld)
{
    // The close for B-2②'s release half. The important half of the assertion is the second one:
    // a refusal that still released the lock would be worse than no refusal, because the caller
    // would be told "no" and the holder would lose the lock anyway (memory:
    // rejected-requests-can-still-act).
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &a));
    mgr.setRequireLeaseId(true);
    EXPECT_TRUE(mgr.requiresLeaseId());

    EXPECT_EQ(mgr.release("routing_lock"), Release::LeaseRequired);
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 60))
        << "the refused release freed the lock anyway";
    EXPECT_EQ(mgr.snapshot("routing_lock").leaseId, a.leaseId) << "the holder's lease changed";
}

TEST(LockOwnershipTest, WithEnforcementOnARenewNamingNoLeaseIsRefusedAndNothingIsExtended)
{
    // The renew half. "Nothing is extended" is checked by shrinking the lease to nothing with a
    // legitimate, attributed renew afterwards -- if the refused renew had written the 7200 it
    // asked for, the lock would still be held after the ttl-0 renew.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600, &a));
    mgr.setRequireLeaseId(true);

    EXPECT_EQ(mgr.renewLease("routing_lock", 7200), Renew::LeaseRequired);

    ASSERT_EQ(mgr.renewLease("routing_lock", 0, a.leaseId), Renew::Renewed) << "the holder's own";
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 60))
        << "the refused renew wrote its 7200 anyway";
}

TEST(LockOwnershipTest, WithEnforcementOnTheHolderNamingItsOwnLeaseIsStillServed)
{
    // The control for group 2, and the reason enforcement is worth having at all: it must refuse
    // the stranger WITHOUT refusing the holder. "Refuse every release" passes both tests above.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("power_lock", 3600, &a));
    mgr.setRequireLeaseId(true);

    EXPECT_EQ(mgr.renewLease("power_lock", 7200, a.leaseId), Renew::Renewed);
    EXPECT_EQ(mgr.release("power_lock", a.leaseId), Release::Released);
    EXPECT_TRUE(mgr.acquireLock("power_lock", 60)) << "and the lock really is free afterwards";
}

TEST(LockOwnershipTest, WithEnforcementOnAWrongLeaseIsStillAMismatchNotALeaseRequirement)
{
    // Two different refusals: "you named nothing" and "you named the wrong thing". They are
    // different bugs at the caller -- one has not been updated, the other is holding a stale id
    // -- and collapsing them would send the second one looking in the wrong place.
    LockManager mgr;
    LockManager::AcquireReport a;
    ASSERT_TRUE(mgr.acquireLock("graph_lock", 3600, &a));
    mgr.setRequireLeaseId(true);

    EXPECT_EQ(mgr.release("graph_lock", a.leaseId + 1), Release::LeaseMismatch);
    EXPECT_EQ(mgr.renewLease("graph_lock", 60, a.leaseId + 1), Renew::LeaseMismatch);
    EXPECT_FALSE(mgr.acquireLock("graph_lock", 60)) << "a refusal released the lock";
}

TEST(LockOwnershipTest, EnforcementDoesNotTurnNotHeldOrExpiredIntoALeaseRequirement)
{
    // There is nothing to protect on a lock nobody holds, so demanding a lease id for it would
    // answer 400 to a caller whose real problem is 412 -- and 400 says "do not retry", which is
    // the opposite of the truth here.
    LockManager mgr;
    mgr.setRequireLeaseId(true);

    EXPECT_EQ(mgr.release("routing_lock"), Release::NotHeld) << "never acquired";
    EXPECT_EQ(mgr.renewLease("routing_lock", 60), Renew::NotHeld);

    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0)) << "held, and already run out";
    EXPECT_EQ(mgr.release("routing_lock"), Release::Expired)
        << "an expired lease demanded a lease id instead of reporting that it expired";
}

TEST(LockOwnershipTest, EnforcementDoesNotAffectAcquire)
{
    // An acquire does not name a lease, it creates one. If enforcement reached acquire, turning
    // it on would wedge the kernel completely -- nobody could ever take a lock again.
    LockManager mgr;
    mgr.setRequireLeaseId(true);

    LockManager::AcquireReport a;
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 3600, &a));
    EXPECT_GT(a.leaseId, 0u);
}

TEST(LockOwnershipTest, TheTwoValuedUnlockWrapperReportsAnEnforcementRefusalAsFailure)
{
    // unlock() names no lease, so under enforcement it can only ever be refused. It must report
    // that as false rather than as a release that happened -- the same "a refusal must not read
    // as success" rule the expired case is held to in tests/test_LockLeaseExpiry.cpp.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600));
    mgr.setRequireLeaseId(true);

    EXPECT_FALSE(mgr.unlock("routing_lock"));
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 60)) << "the refused unlock freed the lock";
}
