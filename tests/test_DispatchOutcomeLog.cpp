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

// ---------------------------------------------------------------------------------------------
// W11 (#54, R6 K-4): the second counter group, and per-request attribution.
//
// [Co-developed with claude code -- Adam]
//
// The counters above answer "did the far end take my request". Everything below is about the
// question that was being asked of them instead -- "is the rule on the switch" -- and about the
// question no global counter can answer: "was it MY request".
//
// The two planes are represented by the two OpResult bits rather than by a strategy object,
// because that is exactly what record() sees. A test that constructed a P4RoutingStrategy would
// be testing the strategy's answer as well, and the mutation this file has to catch is one that
// mis-reads an answer, not one that produces a wrong answer.
// ---------------------------------------------------------------------------------------------

namespace
{

/// What the P4 proxy's reply looks like by the time record() sees it: it programmed the entry
/// before answering, so its 200 is an adjudication.
OpResult
p4Accepted()
{
    return OpResult::success().withProgrammingConfirmed(true);
}

/// The P4 proxy's per-entry refusal -- `{"status":"error"}` in a 200 body, or a 501 for a
/// priority it cannot honour. It looked, and the entry is not there.
OpResult
p4Refused(int status = 200, const char* why = "proxy reported an error in a 200 response")
{
    return OpResult::failure(status, why).withProgrammingRefused(true);
}

/// Ryu's answer to a flow-mod. `ok`, and evidence of nothing: OpenFlow does not acknowledge a
/// FLOW_MOD, so this 200 is emitted before any switch has adjudicated (KNOWN-ISSUES C-4).
OpResult
ovsAccepted()
{
    return OpResult::success();
}

FlowJob
jobForRequest(uint64_t requestId, uint64_t dpid = 1, FlowOp op = FlowOp::Install)
{
    FlowJob job = jobFor(dpid);
    job.op = op;
    job.requestId = requestId;
    return job;
}

} // namespace

TEST(DispatchOutcomeLogTest, TheSameMatchDispatchedTwentyTimesCountsTwentyDispatches)
{
    // #54 pinned as a specification rather than left as a surprise. Measured 2026-09-05: this is
    // +20 while the switch gains one row. The number is correct and the old NAME was not, so the
    // assertion here is that dispatch counting is unchanged -- the fix is that nothing now calls
    // this "succeeded", and that the switch-side group answers separately.
    DispatchOutcomeLog log(8);
    for (int i = 0; i < 20; ++i)
    {
        log.record(jobFor(1, 100, "10.0.0.7"), p4Accepted());
    }

    EXPECT_EQ(log.dispatched(), 20u);
    EXPECT_EQ(log.dispatchedOk(), 20u);
    EXPECT_EQ(log.dispatchFailed(), 0u);
}

TEST(DispatchOutcomeLogTest, AnOvsDispatchIsUnknownAtTheSwitchAndNotAnAcceptance)
{
    // The B half. Ryu's 200 is not evidence about any switch, so the honest bucket is `unknown`.
    // The tempting shortcut -- let dispatched_ok stand in for accepted_by_switch -- would report
    // a healthy OVS fabric as a confirmed one, which is the claim this whole ticket removes.
    DispatchOutcomeLog log(8);
    for (int i = 0; i < 5; ++i)
    {
        log.record(jobFor(1), ovsAccepted());
    }

    EXPECT_EQ(log.dispatchedOk(), 5u) << "the dispatch itself did succeed";
    EXPECT_EQ(log.acceptedBySwitch(), 0u)
        << "an OVS acceptance is not a switch's acceptance; if this is ever non-zero on the OVS "
           "plane, something has started reading dispatch as programming again";
    EXPECT_EQ(log.rejectedBySwitch(), 0u);
    EXPECT_EQ(log.switchOutcomeUnknown(), 5u);
}

TEST(DispatchOutcomeLogTest, AConfirmedP4DispatchIsAnAcceptanceBySwitch)
{
    // The control for the test above: the bucket is not simply pinned at unknown. Without this,
    // a mutation that hard-codes Unknown would pass everything else in this file.
    DispatchOutcomeLog log(8);
    log.record(jobFor(1), p4Accepted());

    EXPECT_EQ(log.acceptedBySwitch(), 1u);
    EXPECT_EQ(log.switchOutcomeUnknown(), 0u);
    EXPECT_EQ(log.rejectedBySwitch(), 0u);
}

TEST(DispatchOutcomeLogTest, ANoOpDeleteIsNotAnAcceptanceBySwitch)
{
    // R6 K-4: a delete of a match that never existed anywhere. On the P4 plane the proxy answers
    // {"status":"error"} because unroute_flow found nothing, so the kernel knows the switch does
    // not hold it -- that is rejected_by_switch, and it must NOT be an acceptance. On the OVS
    // plane Ryu answers 200 and the kernel knows nothing, which is `unknown`. The one thing
    // neither may be is accepted_by_switch, and that is what K-4 saw reported as `succeeded`.
    DispatchOutcomeLog log(8);
    log.record(jobForRequest(0, 1, FlowOp::Delete), p4Refused());
    log.record(jobForRequest(0, 2, FlowOp::Delete), ovsAccepted());

    EXPECT_EQ(log.acceptedBySwitch(), 0u)
        << "a delete that removed nothing has not been accepted by any switch";
    EXPECT_EQ(log.rejectedBySwitch(), 1u) << "the P4 plane looked and said no";
    EXPECT_EQ(log.switchOutcomeUnknown(), 1u) << "the OVS plane did not look";
}

TEST(DispatchOutcomeLogTest, TheSwitchSideGroupClosesAgainstDispatched)
{
    // The cheapest proof that no path increments one bucket without the others, and the reason
    // the second group is published as its own object: it partitions the SAME population as
    // `dispatched`, while dispatched == dispatched_ok + dispatch_failed partitions it a second,
    // independent way. A record() that returned early on some op would break one sum or the other.
    DispatchOutcomeLog log(64);
    log.record(jobFor(1), p4Accepted());
    log.record(jobFor(1), p4Refused(501, "priority not honourable on this table"));
    log.record(jobFor(1), ovsAccepted());
    log.record(jobFor(1), OpResult::unreachable("no response from Ryu"));
    log.record(jobFor(1), OpResult::notSent("this kernel could not run curl"));

    EXPECT_EQ(log.dispatched(), 5u);
    EXPECT_EQ(log.dispatchedOk() + log.dispatchFailed(), log.dispatched());
    EXPECT_EQ(log.acceptedBySwitch() + log.rejectedBySwitch() + log.switchOutcomeUnknown(),
              log.dispatched());

    // And the two ways of partitioning are genuinely different, which is the whole point: three
    // of these five dispatches tell us nothing about a switch, and only one of those three failed.
    EXPECT_EQ(log.switchOutcomeUnknown(), 3u);
    EXPECT_EQ(log.dispatchFailed(), 3u);
    EXPECT_EQ(log.acceptedBySwitch(), 1u);
    EXPECT_EQ(log.rejectedBySwitch(), 1u);
}

TEST(DispatchOutcomeLogTest, AnUnansweredRequestBlamesNoSwitch)
{
    // The B-2b lesson, applied to the new counters. A request that never left this host, or one
    // nothing answered, has told us nothing about a switch -- counting it as rejected_by_switch
    // would accuse a component the kernel never reached, in a field an operator acts on.
    DispatchOutcomeLog log(8);
    log.record(jobFor(1), OpResult::notSent("curl is not installed"));
    log.record(jobFor(1), OpResult::unreachable("no response from the P4 proxy within 5s"));

    EXPECT_EQ(log.dispatchFailed(), 2u);
    EXPECT_EQ(log.rejectedBySwitch(), 0u);
    EXPECT_EQ(log.switchOutcomeUnknown(), 2u);
}

TEST(DispatchOutcomeLogTest, TheTwoSwitchSideBitsAreNeverBothSet)
{
    // classifySwitchOutcome has to break a tie it should never be handed. The bits are set on
    // different code paths -- one on post()'s success return, one on its two refusal returns --
    // so a result carrying both means those paths have been merged. Asserted rather than assumed,
    // because the classification silently prefers "accepted" and that is the optimistic direction.
    OpResult impossible = OpResult::success().withProgrammingConfirmed(true);
    EXPECT_FALSE(impossible.confirmsNotProgrammed);

    OpResult refusal = OpResult::failure(400, "refused").withProgrammingRefused(true);
    EXPECT_FALSE(refusal.confirmsProgramming);

    EXPECT_EQ(DispatchOutcomeLog::classifySwitchOutcome(impossible),
              DispatchOutcomeLog::SwitchOutcome::AcceptedBySwitch);
    EXPECT_EQ(DispatchOutcomeLog::classifySwitchOutcome(refusal),
              DispatchOutcomeLog::SwitchOutcome::RejectedBySwitch);
    EXPECT_EQ(DispatchOutcomeLog::classifySwitchOutcome(OpResult::success()),
              DispatchOutcomeLog::SwitchOutcome::Unknown);
}

TEST(DispatchOutcomeLogTest, TwoRequestsDoNotPolluteEachOther)
{
    // R6 K-4's core complaint: the counters are global, so "did my POST land" cannot be asked.
    // Two batches, interleaved the way two worker threads would interleave them, and each id
    // answers for its own jobs only.
    DispatchOutcomeLog log(64);
    log.noteRequestEnqueued(11, 2);
    log.noteRequestEnqueued(22, 3);

    log.record(jobForRequest(11), p4Accepted());
    log.record(jobForRequest(22), p4Refused());
    log.record(jobForRequest(11), p4Accepted());
    log.record(jobForRequest(22), ovsAccepted());
    log.record(jobForRequest(22), p4Refused());

    const auto first = log.tallyFor(11);
    ASSERT_TRUE(first.has_value());
    EXPECT_EQ(first->enqueued, 2u);
    EXPECT_EQ(first->dispatched, 2u);
    EXPECT_EQ(first->dispatchedOk, 2u);
    EXPECT_EQ(first->dispatchFailed, 0u);
    EXPECT_EQ(first->acceptedBySwitch, 2u);
    EXPECT_EQ(first->rejectedBySwitch, 0u);

    const auto second = log.tallyFor(22);
    ASSERT_TRUE(second.has_value());
    EXPECT_EQ(second->enqueued, 3u);
    EXPECT_EQ(second->dispatched, 3u);
    EXPECT_EQ(second->dispatchedOk, 1u);
    EXPECT_EQ(second->dispatchFailed, 2u);
    EXPECT_EQ(second->rejectedBySwitch, 2u);
    EXPECT_EQ(second->switchOutcomeUnknown, 1u);

    // The globals still see everything -- the per-request tallies are an extra view, not a
    // replacement, and a caller comparing the two must find them consistent.
    EXPECT_EQ(log.dispatched(), 5u);
    EXPECT_EQ(first->dispatched + second->dispatched, log.dispatched());
}

TEST(DispatchOutcomeLogTest, ARequestStillDrainingSaysSoRatherThanLookingFinished)
{
    // `enqueued` is what makes an in-flight batch readable. Without it, a caller polling one
    // second after its POST sees "2 dispatched, all ok" for a batch of five and stops watching.
    DispatchOutcomeLog log(64);
    log.noteRequestEnqueued(7, 5);
    log.record(jobForRequest(7), ovsAccepted());
    log.record(jobForRequest(7), ovsAccepted());

    const auto tally = log.tallyFor(7);
    ASSERT_TRUE(tally.has_value());
    EXPECT_EQ(tally->enqueued, 5u);
    EXPECT_EQ(tally->dispatched, 2u);
    EXPECT_LT(tally->dispatched, tally->enqueued);
}

TEST(DispatchOutcomeLogTest, AnUnregisteredRequestIsNotInvented)
{
    // The distinction registration exists to draw. An outcome for an id nobody registered must
    // not create a tally: if it did, "unknown request" would also mean "known but not yet
    // drained", and those two lead to opposite actions -- fix your id, or wait.
    DispatchOutcomeLog log(64);
    log.record(jobForRequest(99), p4Accepted());

    EXPECT_FALSE(log.tallyFor(99).has_value());
    EXPECT_FALSE(log.tallyFor(0).has_value()) << "0 means 'not from an HTTP batch'";
    EXPECT_EQ(log.dispatched(), 1u) << "still counted globally";
}

TEST(DispatchOutcomeLogTest, ReRegisteringAnIdDoesNotResetItsCounts)
{
    // Ids are minted by one atomic and cannot repeat within a process, so this is defence
    // against a future caller, not against today's. It matters because the failure would be
    // silent: a reset tally reads exactly like a request that has not been dispatched yet.
    DispatchOutcomeLog log(64);
    log.noteRequestEnqueued(5, 1);
    log.record(jobForRequest(5), p4Accepted());
    log.noteRequestEnqueued(5, 99);

    const auto tally = log.tallyFor(5);
    ASSERT_TRUE(tally.has_value());
    EXPECT_EQ(tally->enqueued, 1u);
    EXPECT_EQ(tally->dispatched, 1u);
}

TEST(DispatchOutcomeLogTest, TheOldestRequestAgesOutAndTheLogSaysHowMany)
{
    // Same argument as recent_failures_evicted, one level up: a per-request answer that silently
    // ages out reads exactly like a request that never existed, and only one of those is a reason
    // for the caller to distrust its own id.
    DispatchOutcomeLog log(64);
    const uint64_t overflow = DispatchOutcomeLog::kRequestBudget + 10;
    for (uint64_t id = 1; id <= overflow; ++id)
    {
        log.noteRequestEnqueued(id, 1);
    }

    EXPECT_EQ(log.requestsTracked(), DispatchOutcomeLog::kRequestBudget);
    EXPECT_EQ(log.requestsForgotten(), 10u);
    EXPECT_FALSE(log.tallyFor(1).has_value()) << "the oldest went first";
    EXPECT_TRUE(log.tallyFor(overflow).has_value()) << "the newest is still there";
}

TEST(DispatchOutcomeLogTest, TheFailureRingIsAsLargeAsADispatcherBurst)
{
    // 2026-09-05 ruling (fifth grill round, honesty item 4). At the old 256 a single 2000-entry
    // burst could evict the evidence of its own first three quarters, leaving the operator with
    // an eviction count in place of the failures -- the shape A-7 exists to close.
    EXPECT_EQ(DispatchOutcomeLog::kDefaultCapacity, 2000u)
        << "FlowDispatcher's burstSize default is 2000; these two numbers are meant to match";
    DispatchOutcomeLog log;
    EXPECT_EQ(log.capacity(), DispatchOutcomeLog::kDefaultCapacity);
}
