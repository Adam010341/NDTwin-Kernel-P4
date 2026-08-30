/**
 * Tests for DispatchOutcomeLog -- the read side of KNOWN-ISSUES A-7.
 *
 * [Co-developed with claude code -- Adam]
 *
 * A-7 is that a queued write which the switch refuses is recorded only in kernel.log: no counter,
 * no endpoint, no field in any response. The contract suite stays green while the kernel is
 * writing `dispatched install failed`. These tests are about the properties that make the new
 * record *usable as evidence*, which is a stronger bar than "it stores things":
 *
 *   - a failure must still be there after the system has been busy succeeding, which is the
 *     normal case and the one that makes a ring of all outcomes useless;
 *   - when the buffer does overflow it must say so, because a silently truncated list of
 *     failures reads exactly like a healthier system -- the same shape as A-7 itself;
 *   - it must survive concurrent writers, because the callers are one worker thread per DPID.
 *
 * What is deliberately not asserted here: that the numbers reach HTTP. That is
 * test_HttpSessionRouting's job, and the endpoint is checked live in the evidence file's §5.
 */

#include <atomic>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "ndt_core/routing_management/DispatchOutcomeLog.hpp"

namespace
{

FlowJob
jobFor(uint64_t dpid, int priority = 100, const char* dst = "10.0.0.1")
{
    FlowJob job;
    job.dpid = dpid;
    job.op = FlowOp::Install;
    job.priority = priority;
    job.match = nlohmann::json{{"eth_type", 2048}, {"ipv4_dst", dst}};
    job.actions = nlohmann::json::array();
    return job;
}

} // namespace

TEST(DispatchOutcomeLogTest, SuccessesAreCountedButNotStored)
{
    DispatchOutcomeLog log(8);

    for (int i = 0; i < 20; ++i)
    {
        log.record(jobFor(1), OpResult::success());
    }

    EXPECT_EQ(log.dispatched(), 20u);
    EXPECT_EQ(log.succeeded(), 20u);
    EXPECT_EQ(log.failed(), 0u);
    EXPECT_TRUE(log.recentFailures().empty())
        << "storage is for the rare thing; successes are counted only";
    EXPECT_EQ(log.failuresEvicted(), 0u);
}

TEST(DispatchOutcomeLogTest, AFailureKeepsEnoughIdentityToActOn)
{
    DispatchOutcomeLog log(8);

    log.record(jobFor(7, 915, "10.0.0.240"),
               OpResult::failure(400, "eth_type required with tcp_dst"));

    EXPECT_EQ(log.failed(), 1u);
    EXPECT_EQ(log.succeeded(), 0u);

    const auto failures = log.recentFailures();
    ASSERT_EQ(failures.size(), 1u);
    const auto& rec = failures.front();

    EXPECT_EQ(rec.dpid, 7u);
    EXPECT_EQ(rec.controllerStatus, 400);
    EXPECT_EQ(rec.message, "eth_type required with tcp_dst");
    EXPECT_EQ(rec.requestedPriority, 915);
    // The match is the identity that survives the trip to the switch. The priority does not:
    // measured 2026-08-30, every entry is programmed at 0 whatever was asked for, so a consumer
    // that identified this rule by priority would be looking for something that never exists.
    EXPECT_EQ(rec.match.value("ipv4_dst", std::string{}), "10.0.0.240");
    EXPECT_EQ(rec.seq, 1u);
    EXPECT_GT(rec.atUnixMs, 0);
}

TEST(DispatchOutcomeLogTest, UnreachableControllerIsDistinguishableFromRefusal)
{
    // OpResult carries 0 for "nothing answered" specifically so a dead controller and a rejected
    // rule can be told apart. That distinction is worth nothing if the log flattens it, and it is
    // the first thing an operator asks: is my rule wrong, or is the far end down?
    DispatchOutcomeLog log(8);

    log.record(jobFor(1), OpResult::failure(400, "bad match"));
    log.record(jobFor(2), OpResult::unreachable("connection refused"));

    const auto failures = log.recentFailures();
    ASSERT_EQ(failures.size(), 2u);
    EXPECT_EQ(failures[0].controllerStatus, 400);
    EXPECT_EQ(failures[1].controllerStatus, 0);
    EXPECT_EQ(log.failed(), 2u);
}

TEST(DispatchOutcomeLogTest, ASuccessBurstDoesNotEvictAnEarlierFailure)
{
    // The reason the ring holds failures only. A dispatcher burst is up to 2000 jobs; if
    // successes shared the buffer, one healthy burst would erase every failure before anyone
    // asked, and the endpoint would report a clean system precisely because it was busy.
    DispatchOutcomeLog log(4);

    log.record(jobFor(3, 902, "10.0.0.99"), OpResult::failure(404, "no such table"));

    for (int i = 0; i < 400; ++i) // 100x capacity
    {
        log.record(jobFor(1), OpResult::success());
    }

    const auto failures = log.recentFailures();
    ASSERT_EQ(failures.size(), 1u)
        << "the failure was evicted by successes -- the ring is storing outcomes, not failures";
    EXPECT_EQ(failures.front().dpid, 3u);
    EXPECT_EQ(failures.front().controllerStatus, 404);
    EXPECT_EQ(log.failuresEvicted(), 0u) << "nothing was evicted; nothing should be claimed";
    EXPECT_EQ(log.dispatched(), 401u);
}

TEST(DispatchOutcomeLogTest, OverflowDropsTheOldestAndSaysHowMany)
{
    // A bounded buffer that quietly drops its oldest entries presents a partial list as a
    // complete one. That is A-7's own shape one level up, so the count is published.
    DispatchOutcomeLog log(4);

    for (int i = 1; i <= 10; ++i)
    {
        log.record(jobFor(static_cast<uint64_t>(i)), OpResult::failure(400, "refused"));
    }

    const auto failures = log.recentFailures();
    // ASSERT, not EXPECT: front()/back() below are UB on an empty vector, and a mutation that
    // stops storing failures altogether empties it. Found exactly that way -- as EXPECT this
    // segfaulted the whole binary, gtest never printed its summary, and the mutation harness
    // read the missing summary as "no failures" and reported the mutant SURVIVED.
    ASSERT_EQ(failures.size(), 4u);
    EXPECT_EQ(log.failuresEvicted(), 6u)
        << "6 of 10 aged out and a reader has no way to know unless this says so";
    EXPECT_EQ(log.failed(), 10u) << "the total counts every failure, evicted or not";

    // Oldest first, and it is the oldest that goes.
    EXPECT_EQ(failures.front().dpid, 7u);
    EXPECT_EQ(failures.back().dpid, 10u);
}

TEST(DispatchOutcomeLogTest, SeqIsGlobalSoGapsBetweenFailuresAreVisible)
{
    // seq counts every dispatched job, not every failure. The gap between two stored failures is
    // therefore how many writes succeeded in between -- which is the difference between "the
    // switch is refusing everything" and "one rule in a thousand is wrong".
    DispatchOutcomeLog log(8);

    log.record(jobFor(1), OpResult::failure(400, "first"));
    for (int i = 0; i < 5; ++i)
    {
        log.record(jobFor(1), OpResult::success());
    }
    log.record(jobFor(1), OpResult::failure(400, "second"));

    const auto failures = log.recentFailures();
    ASSERT_EQ(failures.size(), 2u);
    EXPECT_EQ(failures[0].seq, 1u);
    EXPECT_EQ(failures[1].seq, 7u) << "5 successes happened between them and the seq should show it";
}

TEST(DispatchOutcomeLogTest, ConcurrentRecordersLoseNothing)
{
    // The real callers are FlowDispatcher worker threads, one per DPID, so record() is called
    // concurrently by construction. A non-atomic counter passes every single-threaded test above
    // and loses counts here.
    constexpr int kThreads = 4;
    constexpr int kPerThread = 500;

    DispatchOutcomeLog log(64);
    std::vector<std::thread> threads;
    threads.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t)
    {
        threads.emplace_back([&log, t] {
            for (int i = 0; i < kPerThread; ++i)
            {
                // Half succeed, half fail, so both counters and the ring are contended.
                if ((i % 2) == 0)
                {
                    log.record(jobFor(static_cast<uint64_t>(t) + 1), OpResult::success());
                }
                else
                {
                    log.record(jobFor(static_cast<uint64_t>(t) + 1),
                               OpResult::failure(400, "refused"));
                }
            }
        });
    }
    for (auto& th : threads)
    {
        th.join();
    }

    constexpr uint64_t kTotal = kThreads * kPerThread;
    EXPECT_EQ(log.dispatched(), kTotal);
    EXPECT_EQ(log.succeeded(), kTotal / 2);
    EXPECT_EQ(log.failed(), kTotal / 2);
    EXPECT_EQ(log.succeeded() + log.failed(), log.dispatched());

    // The ring is full and the eviction count accounts for exactly the rest.
    EXPECT_EQ(log.recentFailures().size(), 64u);
    EXPECT_EQ(log.failuresEvicted(), (kTotal / 2) - 64u);
}

TEST(DispatchOutcomeLogTest, EveryOpHasAName)
{
    // The endpoint puts this string in its body, so an unnamed op would ship as "unknown" to a
    // consumer trying to tell a failed delete from a failed install.
    EXPECT_STREQ(DispatchOutcomeLog::opName(FlowOp::Install), "install");
    EXPECT_STREQ(DispatchOutcomeLog::opName(FlowOp::Modify), "modify");
    EXPECT_STREQ(DispatchOutcomeLog::opName(FlowOp::Delete), "delete");
}

TEST(DispatchOutcomeLogTest, ZeroCapacityStillKeepsOneRatherThanDividingByZero)
{
    // Not a real configuration, but the constructor takes a size_t from a future caller and the
    // degenerate value should not produce a buffer that discards everything while reporting
    // failures exist.
    DispatchOutcomeLog log(0);
    log.record(jobFor(1), OpResult::failure(400, "refused"));

    EXPECT_EQ(log.capacity(), 1u);
    EXPECT_EQ(log.recentFailures().size(), 1u);
    EXPECT_EQ(log.failed(), 1u);
}
