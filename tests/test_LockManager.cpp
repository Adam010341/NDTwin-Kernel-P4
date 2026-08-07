/**
 * Tests for the TTL locks that serialise writes to the network.
 *
 * [Co-developed with claude code -- Adam]
 *
 * LockManager.hpp had no tests. It is 120 lines and looks obviously correct, which is exactly
 * the shape of thing this repo has been caught by before -- and it is load-bearing: the three
 * locks exist so that a routing change, a graph rebuild and a power operation cannot run over
 * each other, and every one of those writes to real switches.
 *
 * The reason it needs tests is that the whole design rests on a TTL rather than on ownership.
 * There are no handles and no tokens: `unlock("routing_lock")` releases the lock whoever is
 * holding it, and expiry is decided by comparing against `steady_clock::now()` on each attempt.
 * That makes two things testable and worth pinning:
 *
 *   - a lock must actually become re-acquirable when its TTL runs out, or a crashed HTTP client
 *     wedges the kernel until restart;
 *   - it must NOT become re-acquirable early, or two writers proceed at once and the lock has
 *     bought nothing.
 *
 * The TTL boundary is exercised without sleeping. `acquireLock(name, 0)` sets
 * `expiryTime = now`, and the held test is the strict `now < expiryTime`, so a zero TTL is
 * already expired on the next call. That is a real behaviour an HTTP caller can reach --
 * `{"ttl": 0}` is accepted by the lock endpoint -- and it doubles as a deterministic way to test
 * the expired branch, which is otherwise a one-second wait.
 *
 * `isLocked` and `expiryTime` are independent, and the tests below rely on that distinction:
 * an expired lock is still `isLocked == true`, which is what makes `renew` on it succeed.
 */

#include <atomic>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "ndt_core/lock_management/LockManager.hpp"

namespace
{

/// The three names the private stringToLockType recognises. Written out rather than derived,
/// because the point is to pin the wire vocabulary that HttpSession forwards verbatim.
const std::vector<std::string> kValidNames = {"routing_lock", "graph_lock", "power_lock"};

} // namespace

TEST(LockManagerTest, TheThreeDocumentedLockNamesAreValidAndNothingElseIs)
{
    // The name arrives from an HTTP body (`jsonBody.value("type", ...)`) and is never checked
    // anywhere else, so this list is the whole input validation. A typo has to be refused rather
    // than silently mapped onto one of the real locks.
    LockManager mgr;
    for (const auto& name : kValidNames)
    {
        EXPECT_TRUE(mgr.isValidType(name)) << name;
    }
    for (const char* const bad : {"routing", "ROUTING_LOCK", "routing_lock ", "", "lock",
                                  "unknown", "graph", "power_lock_2"})
    {
        EXPECT_FALSE(mgr.isValidType(bad)) << bad;
    }
}

TEST(LockManagerTest, TheDefaultLockNameConstantIsOneTheManagerActuallyAccepts)
{
    // DEFAULT_LOCK_TYPE_STR is what HttpSession falls back to when a request omits "type", and
    // it is declared next to the enum as a "single source of truth" -- but nothing makes the two
    // agree. If the enum mapping is renamed and the constant is not, every default lock request
    // starts returning false, which reads as "someone else holds the lock" rather than as a bug.
    LockManager mgr;
    EXPECT_TRUE(mgr.isValidType(LockManager::DEFAULT_LOCK_TYPE_STR))
        << "the documented default '" << LockManager::DEFAULT_LOCK_TYPE_STR
        << "' is not a name acquireLock will accept";
    EXPECT_TRUE(mgr.acquireLock(LockManager::DEFAULT_LOCK_TYPE_STR,
                                LockManager::DEFAULT_TTL_SECONDS));
}

TEST(LockManagerTest, AnUnknownLockNameIsRefusedRatherThanCreatingAFourthLock)
{
    // m_locks is an unordered_map indexed with operator[], so an accepted unknown name would
    // create a lock under LockType::Unknown -- and every unknown name would then share one lock.
    // Refusing at the door is what stops "typo_lock" and "typoo_lock" from excluding each other.
    LockManager mgr;
    EXPECT_FALSE(mgr.acquireLock("routing", 5));
    EXPECT_FALSE(mgr.acquireLock("", 5));
    EXPECT_FALSE(mgr.renew("routing", 5));

    // And refusing must not have disturbed the real locks.
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 5));
}

TEST(LockManagerTest, ASecondAcquireOfAHeldLockIsRefused)
{
    // The entire purpose of the class in one assertion.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 60));
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 60))
        << "two callers both believe they hold the routing lock";
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 1));
}

TEST(LockManagerTest, TheThreeLocksAreIndependentOfEachOther)
{
    // They are separate entries keyed by enum, and they protect different subsystems: a power
    // operation must not be blocked by a routing change. A single shared flag would pass the test
    // above and fail this one.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 60));
    EXPECT_TRUE(mgr.acquireLock("graph_lock", 60)) << "graph_lock was blocked by routing_lock";
    EXPECT_TRUE(mgr.acquireLock("power_lock", 60)) << "power_lock was blocked by another lock";

    // Releasing one must not release the others.
    mgr.unlock("graph_lock");
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 60)) << "unlocking graph_lock freed routing_lock";
    EXPECT_FALSE(mgr.acquireLock("power_lock", 60));
    EXPECT_TRUE(mgr.acquireLock("graph_lock", 60));
}

TEST(LockManagerTest, UnlockingMakesTheLockAvailableAgain)
{
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("power_lock", 60));
    mgr.unlock("power_lock");
    EXPECT_TRUE(mgr.acquireLock("power_lock", 60));
}

TEST(LockManagerTest, UnlockingIsIdempotentAndSafeOnALockNobodyEverTook)
{
    // The unlock endpoint is reachable without a matching acquire -- a client that retries a
    // release, or one that releases after its own TTL already expired. Neither may throw, and
    // neither may leave the map in a state where the next acquire is refused.
    LockManager mgr;
    EXPECT_NO_THROW(mgr.unlock("routing_lock"));
    EXPECT_NO_THROW(mgr.unlock("routing_lock"));
    EXPECT_NO_THROW(mgr.unlock("not_a_lock"));
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 60));
    mgr.unlock("routing_lock");
    EXPECT_NO_THROW(mgr.unlock("routing_lock"));
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 60));
}

TEST(LockManagerTest, UnlockingAnUnknownNameDoesNotReleaseARealLock)
{
    // stringToLockType returns Unknown for a typo, and the early return is what stops that typo
    // from being treated as a lock name. Without it, `unlock("routing")` would touch the
    // LockType::Unknown entry -- or worse, a future refactor could map it onto a real one.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 60));
    mgr.unlock("routing");
    mgr.unlock("");
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 60))
        << "an unknown unlock name released the routing lock";
}

TEST(LockManagerTest, AZeroTtlLockIsAlreadyExpiredWhenTheNextCallerAsks)
{
    // `expiryTime = now + seconds(0)` and the held test is the strict `now < expiryTime`, so a
    // zero TTL never holds anyone off. Documented rather than asserted as good: the lock endpoint
    // accepts `{"ttl": 0}` from any client, and this is what that request buys -- an acquire that
    // reports success and excludes nobody.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0));
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 0))
        << "a zero-TTL lock unexpectedly held; the expiry comparison changed";
}

TEST(LockManagerTest, ANegativeTtlIsTreatedAsAlreadyExpiredRatherThanAsForever)
{
    // `ttl` comes straight off the wire as an int with no floor, so a negative value puts
    // expiryTime in the past. That direction is the safe one -- the alternative reading, an
    // unsigned conversion, would produce a lock held for 5.8 million centuries.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("graph_lock", -1));
    EXPECT_TRUE(mgr.acquireLock("graph_lock", -1000))
        << "a negative TTL produced a lock that outlives the process";
    EXPECT_TRUE(mgr.acquireLock("graph_lock", 60)) << "and it must not block a real acquire";
}

TEST(LockManagerTest, APositiveTtlStillHoldsTheLockWhileItHasTimeLeft)
{
    // The contrast that stops the two expiry tests above from being satisfied by "never hold
    // anything". Deliberately paired: a change that made every lock look expired would pass both
    // of them and fail here.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600));
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 3600));
}

TEST(LockManagerTest, RenewingAnExpiredLockPutsItBackInForce)
{
    // The renew path exists for a long operation that outlives its own TTL. It works on an
    // expired lock because `isLocked` stays true after expiry -- only `expiryTime` has passed --
    // and this is the test that pins that distinction, without waiting a second for a real TTL.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0));
    ASSERT_TRUE(mgr.renew("routing_lock", 3600))
        << "renew refused a lock that is still flagged as held";
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 60))
        << "renew reported success without extending the deadline";
}

TEST(LockManagerTest, RenewingALockNobodyHoldsIsRefused)
{
    // Renew must not be a back door to acquiring. If it created or re-flagged an entry, a client
    // could take the lock with `renew` and bypass the held check entirely.
    LockManager mgr;
    EXPECT_FALSE(mgr.renew("routing_lock", 60)) << "renewed a lock that was never acquired";
    EXPECT_FALSE(mgr.renew("not_a_lock", 60));

    // Also after a release: the entry exists but is not held.
    ASSERT_TRUE(mgr.acquireLock("power_lock", 60));
    mgr.unlock("power_lock");
    EXPECT_FALSE(mgr.renew("power_lock", 60)) << "renewed a lock that had been released";

    // And a refused renew must not have taken the lock as a side effect.
    EXPECT_TRUE(mgr.acquireLock("power_lock", 60));
}

TEST(LockManagerTest, RenewingOneLockDoesNotExtendAnother)
{
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0));
    ASSERT_TRUE(mgr.acquireLock("graph_lock", 0));
    ASSERT_TRUE(mgr.renew("routing_lock", 3600));
    EXPECT_TRUE(mgr.acquireLock("graph_lock", 0))
        << "renewing routing_lock also extended graph_lock";
}

TEST(LockManagerTest, ExactlyOneOfManyConcurrentAcquiresWins)
{
    // The map is shared mutable state reached from the HTTP thread pool, so several requests can
    // land in acquireLock at once. The mutex is what makes "check then set" atomic; without it two
    // callers can both read isLocked == false and both return true, which is the failure the whole
    // class exists to prevent and the one a single-threaded test cannot see.
    LockManager mgr;
    constexpr int kThreads = 16;
    std::atomic<int> winners{0};
    std::atomic<bool> go{false};
    std::vector<std::thread> threads;
    threads.reserve(kThreads);

    for (int i = 0; i < kThreads; ++i)
    {
        threads.emplace_back([&mgr, &winners, &go] {
            while (!go.load(std::memory_order_acquire))
            {
                std::this_thread::yield();
            }
            if (mgr.acquireLock("routing_lock", 3600))
            {
                winners.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }
    go.store(true, std::memory_order_release);
    for (auto& t : threads)
    {
        t.join();
    }

    EXPECT_EQ(winners.load(), 1) << "the lock was handed to " << winners.load()
                                 << " callers at once";
}
