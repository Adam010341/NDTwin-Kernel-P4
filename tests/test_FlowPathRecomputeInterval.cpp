/**
 * Ticket M: the interval at which every tracked flow's path is re-derived.
 *
 * [Co-developed with claude code -- Adam]
 *
 * calFlowPathByQueried slept 1 ms between passes, so it rebuilt every flow's path a thousand
 * times a second. Profiling put 46.31% of the kernel's CPU in that one function, on a single
 * thread, and the cost was paid in full at the LOWEST sampling rate -- fixed, not per-sample.
 *
 * 🔴 WHAT THESE TESTS DO NOT DO. They cannot show the change is safe, and nothing in a unit test
 * can. What the 1 kHz bought was a 1 ms freshness bound on the API's `path` field; at 1 Hz a flow
 * that starts and ends inside one pass never gets a path at all. Whether that happens in practice
 * is a property of the workload, and ticket M's churn arm is what measures it -- 6-2 predicts the
 * non-empty `path` ratio falls to 70-90% under short flows while a steady 300-second-flow
 * workload would move 0.17% and report green.
 *
 * This repository has already shipped a speedup that measured CPU and connectivity green while
 * what actually broke was model fidelity. So these tests pin the constant and the relationship
 * that makes the risk real, and they say plainly that the acceptance lives in the arms. A test
 * file that implied otherwise would be the more dangerous artifact.
 */
#include <chrono>

#include <gtest/gtest.h>

#include "ndt_core/collection/FlowLinkUsageCollector.hpp"

namespace
{

TEST(FlowPathRecomputeInterval, IsOneSecondNotOneMillisecond)
{
    // A revert to 1 ms is the mutation this file exists to make visible. It is a weak test in
    // the sense that it restates a constant -- but the constant is the whole change, and without
    // this the suite would stay green through a silent revert.
    EXPECT_EQ(sflow::kFlowPathRecomputeInterval, std::chrono::seconds(1));
}

TEST(FlowPathRecomputeInterval, AFlowSurvivingToTheIdleTimeoutGetsManyChancesAtAPath)
{
    // The pair is what matters, not either constant alone. A flow that lives long enough to be
    // timed out has had FLOW_IDLE_TIMEOUT / interval passes to acquire a path; if that ratio
    // ever drops near 1, a flow could be purged having never been given one.
    const auto intervalMs =
        std::chrono::duration_cast<std::chrono::milliseconds>(sflow::kFlowPathRecomputeInterval);
    ASSERT_GT(intervalMs.count(), 0) << "a zero interval would be a busy loop, not a rate";
    EXPECT_GE(FLOW_IDLE_TIMEOUT / intervalMs.count(), 10)
        << "a flow that survives to the idle timeout must get at least ten chances at a path";
}

TEST(FlowPathRecomputeInterval, ShortFlowsCanDieWithoutAPathAndThatIsTheKnownCost)
{
    // Asserted as current behaviour rather than repaired, so that a future fix has to come here
    // and change it deliberately. At this interval any flow shorter than one second may live and
    // die between two passes. That is the cost ticket M accepts in exchange for 46.31% of a
    // thread, and the churn arm is what puts a number on it.
    const auto intervalMs =
        std::chrono::duration_cast<std::chrono::milliseconds>(sflow::kFlowPathRecomputeInterval);
    EXPECT_GT(intervalMs.count(), 100)
        << "if this ever drops back near the old 1 ms, ticket M has been reverted and the CPU "
           "finding with it";
    EXPECT_LT(intervalMs.count(), FLOW_IDLE_TIMEOUT)
        << "an interval at or beyond the idle timeout would mean flows are purged before their "
           "first pass -- every path would be empty, not merely the short ones";
}

}   // namespace
