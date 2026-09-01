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
 * `isLocked` and `expiryTime` are independent, and the tests below rely on that distinction: an
 * expired lock is still `isLocked == true`. That is a fact about the representation, not a
 * licence -- see the renew section, where this file used to draw the wrong conclusion from it.
 *
 * 🔴 2026-09-01: THIS FILE USED TO PIN KNOWN-ISSUES B-2① AS INTENDED BEHAVIOUR.
 * `RenewingAnExpiredLockPutsItBackInForce` asserted that renewing a lease that had already run
 * out must succeed, and justified it with "the renew path exists for a long operation that
 * outlives its own TTL". That reasoning covers the holder renewing late. It does not cover the
 * case the endpoint actually admits, because renew takes a lock NAME and no holder: a caller
 * that has never held anything can revive a dead lease and keep every other client out of a lock
 * nobody owns. The contract said 412 for an expired lock the whole time
 * (doc/2026-07-27_testing_workflow.md:221).
 *
 * 🔑 The test was not wrong about the code -- it described it exactly. It was wrong about which
 * of the two it was doing, and a passing test that pins a defect is worse than no test, because
 * the next reader takes the assertion for a decision. When retargeting a test like this, the old
 * rationale gets written down (above) rather than deleted: it was the stated reason, and reasons
 * outlive conclusions.
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
    // DEFAULT_LOCK_TYPE_STR is declared next to the enum as a "single source of truth", but
    // nothing makes the two agree: if the enum mapping is renamed and the constant is not, a
    // request naming the constant starts returning false, which reads as "someone else holds
    // the lock" rather than as a bug.
    //
    // As of T-7b (2026-08-30) no handler falls back to this constant any more -- acquire, renew
    // and release all require an explicit "type". It survives as the documented name of the
    // routing lock and is still referenced by callers and tests, so the agreement it asserts is
    // still worth pinning; it is simply no longer reachable by omitting a field.
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

TEST(LockManagerTest, RenewingALockThatIsStillInForceRewritesItsDeadline)
{
    // The accept path, and the one every refusal test below has to be read against: a change
    // that made renew answer false unconditionally would satisfy all of them and break the only
    // thing renew is for.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600));
    ASSERT_TRUE(mgr.renew("routing_lock", 7200)) << "renew refused a lease that is still running";
    EXPECT_FALSE(mgr.acquireLock("routing_lock", 60)) << "renew released the lock";

    // ...and that the deadline was actually WRITTEN, with no wall clock involved. Renewing to
    // ttl 0 sets expiryTime = now, so the lease ends immediately and the lock becomes
    // acquirable. A renew that answered true without touching expiryTime would leave 7200
    // seconds on the lock and this acquire would fail.
    //
    // 🔑 Needed because the obvious assertion -- "it is still held afterwards" -- is true of a
    // renew that does nothing at all, and every other test in the renew group is a refusal.
    ASSERT_TRUE(mgr.renew("routing_lock", 0)) << "the lock was in force when this was called";
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 60))
        << "renew answered true without writing the new deadline";
}

TEST(LockManagerTest, RenewingAnExpiredLeaseIsRefusedRatherThanResurrectingIt)
{
    // KNOWN-ISSUES B-2①. `acquireLock(name, 0)` sets expiryTime = now and the held test is the
    // strict `now < expiryTime`, so the lock is expired to the next caller while still being
    // flagged isLocked -- exactly the state renew() used to accept.
    //
    // Once the lease has run out the lock is, by the class's own rule in acquireLock, free. The
    // way back in is to acquire it, which can be lost to another client. Renew must not be a
    // second door into a lock that is standing open.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0)) << "held, and already expired";

    EXPECT_FALSE(mgr.renew("routing_lock", 3600))
        << "an expired lease was renewed; a caller holding nothing can now hold the lock that "
           "serialises writes to real switches";

    // And the refusal must not have taken the lock as a side effect, or renew becomes acquire
    // with the held check skipped.
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 60))
        << "the refused renew left the lock unavailable to a legitimate acquire";
}

TEST(LockManagerTest, ANonHolderCannotKeepADeadLeaseAliveAndLockEverybodyOut)
{
    // The shape the defect actually took, written out as the sequence rather than as a property.
    // A holds a lock and goes away; the lease runs out, so the lock is free. C has never held
    // anything and renews. Before the fix C got 200 and D was refused for another two minutes,
    // on behalf of a client that no longer existed.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 0)) << "A's lease, already run out";

    EXPECT_FALSE(mgr.renew("routing_lock", 120)) << "C revived a lease it never held";
    EXPECT_TRUE(mgr.acquireLock("routing_lock", 120))
        << "D was locked out of a lock that nobody was holding";

    // Repeating the call must not accumulate anything either: the entry is live now (D holds
    // it), so a renew succeeds -- that is D's lock and this is what renew is for.
    EXPECT_TRUE(mgr.renew("routing_lock", 120));
}

TEST(LockManagerTest, RenewIsRefusedOnAnExpiredLockForEachOfTheThreeLocks)
{
    // Not a generalisation for its own sake: routing_lock is the one the endpoint used to
    // substitute, so a fix applied only where the reported symptom was would leave the other two
    // able to be revived by a stranger.
    for (const auto& name : kValidNames)
    {
        LockManager mgr;
        ASSERT_TRUE(mgr.acquireLock(name, 0)) << name;
        EXPECT_FALSE(mgr.renew(name, 3600)) << name << ": expired lease renewed";
        EXPECT_TRUE(mgr.acquireLock(name, 60)) << name;
    }
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
    // The probe is the second renew, not an acquire. graph_lock is left expired, so a renew of
    // it must be refused; if renewing routing_lock had leaked into graph_lock's entry, that
    // entry would be back in force and the second renew would succeed. An acquire cannot tell
    // the two apart any more -- after the B-2① fix a leaked renew of an expired lock is refused
    // as well, so `acquireLock("graph_lock", 0)` returns true either way and proves nothing.
    LockManager mgr;
    ASSERT_TRUE(mgr.acquireLock("routing_lock", 3600)) << "live: the one being renewed";
    ASSERT_TRUE(mgr.acquireLock("graph_lock", 0)) << "expired: the one that must stay expired";

    ASSERT_TRUE(mgr.renew("routing_lock", 7200));

    EXPECT_FALSE(mgr.renew("graph_lock", 3600))
        << "renewing routing_lock put graph_lock's lease back in force";
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

// ============================================================================================
// Parsing an /ndt/acquire_lock body is a decision, and it used to be made by falling through.
//
// [Co-developed with claude code -- Adam]
// The endpoint answered three different questions with one behaviour. A malformed body, a body
// with no "type", and a body naming a lock that does not exist all ended up holding
// `routing_lock` -- the lock that serialises writes to real switches. This was verified live on
// 2026-08-29 by judging on state rather than on the reply: sending `"{this is not json` returned
// {"status":"locked","type":"routing_lock"} and a second client then could not acquire, so the
// malformed request was genuinely holding it.
//
// These tests are about which request is refused and why the caller is told, because "refused"
// and "refused for the right reason" are different properties and only the second one lets an
// operator fix anything.
// ============================================================================================

TEST(LockRequestParsing, MalformedBodyIsRefusedRatherThanDefaulted)
{
    auto r = LockManager::parseRequest("{this is not json");
    EXPECT_FALSE(r.ok) << "a body that is not JSON was accepted";
    EXPECT_EQ(r.error, LockManager::RequestError::MalformedBody);
    EXPECT_TRUE(r.type.empty())
        << "a malformed body resolved to lock type '" << r.type
        << "'; it must name nothing, or garbage acquires the routing lock";
}

TEST(LockRequestParsing, MissingTypeIsRefusedRatherThanSubstituted)
{
    auto r = LockManager::parseRequest(R"({"ttl": 30})");
    EXPECT_FALSE(r.ok) << "a body with no \"type\" was accepted";
    EXPECT_EQ(r.error, LockManager::RequestError::MissingType);
    EXPECT_TRUE(r.type.empty())
        << "no type was requested but '" << r.type << "' came back; a caller that believes it "
           "holds a private lock would be holding the one routing actually uses";
}

TEST(LockRequestParsing, InvalidTypeIsDistinguishedFromMissingType)
{
    auto r = LockManager::parseRequest(R"({"type": "alpha"})");
    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.error, LockManager::RequestError::InvalidType)
        << "an unknown lock name must not be reported the same way as a missing one";
    EXPECT_EQ(r.requestedType, "alpha")
        << "the error must carry what the caller sent, not what the server substituted";
}

// The accept path. Every test above would also pass if parseRequest refused everything.
TEST(LockRequestParsing, AllThreeRealLocksAreAccepted)
{
    for (const auto* name : {"routing_lock", "graph_lock", "power_lock"})
    {
        auto r = LockManager::parseRequest(std::string(R"({"type": ")") + name + R"("})");
        EXPECT_TRUE(r.ok) << name << " was refused";
        EXPECT_EQ(r.type, name);
        EXPECT_EQ(r.ttl, LockManager::DEFAULT_TTL_SECONDS) << "ttl may default; the target may not";
    }
}

TEST(LockRequestParsing, ExplicitTtlIsHonoured)
{
    auto r = LockManager::parseRequest(R"({"type": "power_lock", "ttl": 30})");
    ASSERT_TRUE(r.ok);
    EXPECT_EQ(r.ttl, 30);
    EXPECT_EQ(r.type, "power_lock");
}

// Both production callers send this exact shape; it must keep working.
TEST(LockRequestParsing, TheShapeBothSiblingAppsSendStillWorks)
{
    auto r = LockManager::parseRequest(R"({"ttl": 300, "type": "routing_lock"})");
    ASSERT_TRUE(r.ok) << "Energy-Saving-App and Traffic-Engineering-App both send this";
    EXPECT_EQ(r.type, "routing_lock");
    EXPECT_EQ(r.ttl, 300);
}

// ============================================================================================
// T-7b: the same parser now decides for release_lock and renew_lock too.
//
// [Co-developed with claude code -- Adam]
// Those two handlers kept their own copies of the rules, and the copies had drifted: renew
// swallowed every parse failure in an empty catch and renewed routing_lock; release refused a
// malformed body but still fell through to routing_lock when the body was absent. Both are now
// the seam below, so the three endpoints cannot disagree about what a request means.
//
// The cases here are the ones the two extra endpoints introduced. The endpoint-level tests --
// which judge on lock STATE rather than on the reply, because the reply was never the thing
// that was wrong -- are in tests/test_HttpSessionStatusCodes.cpp with the LockManager fixture.
// ============================================================================================

TEST(LockRequestParsing, AnAbsentBodyNamesNoLockAtAll)
{
    // This is the request that mattered: `POST /ndt/release_lock` with no body used to mean
    // "release routing_lock". A power_lock holder sending it released a lock it had never
    // held, and was told 200.
    auto r = LockManager::parseRequest("");
    EXPECT_FALSE(r.ok) << "an empty body was accepted";
    EXPECT_EQ(r.error, LockManager::RequestError::MissingType)
        << "an absent body is 'you named no lock', not 'your JSON is broken'";
    EXPECT_TRUE(r.type.empty())
        << "an absent body resolved to lock type '" << r.type << "'";
}

TEST(LockRequestParsing, AWhitespaceOnlyBodyIsTreatedAsAbsentRatherThanAsMalformed)
{
    auto r = LockManager::parseRequest("  \n\t ");
    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.error, LockManager::RequestError::MissingType);
    EXPECT_TRUE(r.type.empty());
}

TEST(LockRequestParsing, ANonStringTypeIsDistinguishedFromAMissingOne)
{
    // handleReleaseLock drew this distinction before T-7b and it must survive being folded
    // into the shared parser: telling a caller "type" is missing, when the caller can see
    // "type" in the body it just sent, sends it looking in the wrong place.
    auto r = LockManager::parseRequest(R"({"type": 123})");
    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.error, LockManager::RequestError::NonStringType)
        << "a present-but-wrong-typed field was reported as missing";
    EXPECT_EQ(r.requestedType, "123") << "the error must carry what the caller sent";
    EXPECT_TRUE(r.type.empty());
}

// The accept path for the two endpoints T-7b brings in. Every refusal test above would also
// pass against a parseRequest that refused everything.
TEST(LockRequestParsing, TheExactBodiesTheReleaseAndRenewCallersSendAreAccepted)
{
    // Energy-Saving-App/src/app/http.cpp:461, Traffic-engineering-App.py:85, probes.py:206
    auto rel = LockManager::parseRequest(R"({"type": "routing_lock"})");
    ASSERT_TRUE(rel.ok) << "the body all three release callers send was refused";
    EXPECT_EQ(rel.type, "routing_lock");

    // the chaos harness is the only renew caller: probes.py:210 sends type + ttl
    auto ren = LockManager::parseRequest(R"({"type": "graph_lock", "ttl": 5})");
    ASSERT_TRUE(ren.ok) << "the body the only renew caller sends was refused";
    EXPECT_EQ(ren.type, "graph_lock");
    EXPECT_EQ(ren.ttl, 5);
}

// A refusal has to say which thing was wrong, or an operator cannot act on it. This is the
// property that "everything is 400" would silently lose.
TEST(LockRequestParsing, EachRefusalReasonProducesADistinctMessageQuotingTheCaller)
{
    const auto malformed = LockManager::describeError(
        LockManager::parseRequest("{not json"), "released");
    const auto missing = LockManager::describeError(
        LockManager::parseRequest("{}"), "released");
    const auto nonString = LockManager::describeError(
        LockManager::parseRequest(R"({"type": 123})"), "released");
    const auto invalid = LockManager::describeError(
        LockManager::parseRequest(R"({"type": "alpha"})"), "released");

    EXPECT_NE(malformed, missing);
    EXPECT_NE(missing, nonString);
    EXPECT_NE(nonString, invalid);

    EXPECT_NE(invalid.find("alpha"), std::string::npos)
        << "the message must quote the lock the caller named: " << invalid;
    EXPECT_NE(nonString.find("123"), std::string::npos)
        << "the message must quote what the caller sent: " << nonString;

    // The old sentence was "System busy or invalid lock type: routing_lock" -- it named the
    // lock the SERVER had substituted, at a caller that had never mentioned it, which is how
    // the substitution stayed invisible for as long as it did. A body that parsed to nothing
    // at all must therefore not mention routing_lock anywhere.
    //
    // Only `malformed` can carry this assertion. The missing/non-string/invalid messages
    // legitimately list all three lock names as guidance, so the presence of the string
    // proves nothing about them -- asserting it there would be a check that cannot fail for
    // the right reason.
    EXPECT_EQ(malformed.find("routing_lock"), std::string::npos)
        << "a request that parsed to nothing was answered with routing_lock, the lock the "
           "server used to substitute: " << malformed;

    // and the verb is the endpoint's, so the message says what did not happen
    EXPECT_NE(malformed.find("released"), std::string::npos) << malformed;
    EXPECT_NE(LockManager::describeError(LockManager::parseRequest("{not json"), "renewed")
                  .find("renewed"),
              std::string::npos);
}
