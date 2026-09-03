// [Co-developed with claude code -- Adam]
//
// The gate for the sFlow ingest health signal.
// doc/audit/2026-09-03_night-rounds/round4-traffic-measurement/SUMMARY.md, lead 5(b), R4.
//
// 🔴 What these tests are FOR: a health field that is always present and always says "ok" is
// worse than no field, because it converts an unknown into a false reassurance. So every case
// below pins the verdict to a DIFFERENT underlying condition, and the mutation gate for this
// file is run by pinning classifyIngestHealth to a constant answer -- any such mutation must
// turn at least one of these red. Asserting only "the key exists" would let all of them live.
//
// classifyIngestHealth is pure and static precisely so this file needs no collector, no socket
// and no clock: the numbers below are stated, not produced.

#include "ndt_core/collection/FlowLinkUsageCollector.hpp"

#include <gtest/gtest.h>

// [Co-developed with claude code -- Adam] auditor 2026-09-03: the class lives in `namespace
// sflow` (FlowLinkUsageCollector.hpp:30). Every sibling that compiles qualifies it the same way
// -- e.g. test_SFlowParsing.cpp:140. Unqualified, the whole file fails to name the type.
using Collector = sflow::FlowLinkUsageCollector;
using Health = sflow::FlowLinkUsageCollector::IngestHealth;

namespace
{

// Before the rate loop has closed its first window nothing has been measured. "ok" here would be
// the code grading a check that never ran.
TEST(TelemetryHealth, BeforeTheFirstWindowClosesTheAnswerIsUnknownNotOk)
{
    const Health h = Collector::classifyIngestHealth(false, 0, 0, 0, 0.0);
    EXPECT_EQ(h.status, "unknown");
    EXPECT_NE(h.status, "ok");
    // -1.0, not 0.0: "no fraction is known" is not "nothing was lost".
    EXPECT_DOUBLE_EQ(h.lossFraction, -1.0);
    EXPECT_EQ(h.offeredInWindow, 0u);
}

// R4, the defect this exists to close: from outside the process, "the collector received nothing"
// and "the network is idle" produced identical observations. They must not produce identical
// verdicts. This test and the next differ ONLY in samplesInWindow.
TEST(TelemetryHealth, AClosedWindowWithNoSamplesIsNotOk)
{
    const Health h = Collector::classifyIngestHealth(true, 0, 0, 0, 1.0);
    EXPECT_EQ(h.status, "no_samples");
    EXPECT_NE(h.status, "ok");
    EXPECT_NE(h.status, "unknown"); // we did measure; the answer was zero
    EXPECT_EQ(h.samplesInWindow, 0u);
    EXPECT_EQ(h.offeredInWindow, 0u);
    // We asked and nothing was lost, so the fraction is a real 0 rather than "unknown".
    EXPECT_DOUBLE_EQ(h.lossFraction, 0.0);
}

TEST(TelemetryHealth, SamplesWithNoDropsIsOk)
{
    const Health h = Collector::classifyIngestHealth(true, 18, 0, 0, 1.0);
    EXPECT_EQ(h.status, "ok");
    EXPECT_EQ(h.samplesInWindow, 18u);
    EXPECT_EQ(h.offeredInWindow, 18u);
    EXPECT_DOUBLE_EQ(h.lossFraction, 0.0);
}

// The denominator is the whole point: a consumer holding `dropped_in_window` alone cannot tell a
// usable measurement from an unusable one. offered = delivered + lost, over the same window.
TEST(TelemetryHealth, TheDenominatorIsSamplesPlusBothKindsOfDrop)
{
    const Health h = Collector::classifyIngestHealth(true, 700, 200, 100, 1.0);
    EXPECT_EQ(h.offeredInWindow, 1000u);
    EXPECT_EQ(h.socketDropsInWindow, 200u);
    EXPECT_EQ(h.appDropsInWindow, 100u);
    EXPECT_DOUBLE_EQ(h.lossFraction, 0.3);
    EXPECT_EQ(h.status, "severe_loss");
}

// Application-level loss alone must move the verdict. Round 4 never observed app_drop_total
// leaving 0, so this arm has no live evidence behind it -- which is exactly why it is pinned
// here: an unexercised path is where a wrong constant survives.
TEST(TelemetryHealth, AppDropsAloneMoveTheVerdict)
{
    const Health h = Collector::classifyIngestHealth(true, 900, 0, 100, 1.0);
    EXPECT_EQ(h.status, "severe_loss");
    EXPECT_DOUBLE_EQ(h.lossFraction, 0.1 * 1000.0 / 1000.0);
    EXPECT_EQ(h.offeredInWindow, 1000u);
}

// Round 4's 150 000 datagrams/s cell: 0.34% lost. Small, and still an under-report -- so it is
// reported as loss, not rounded into "ok".
TEST(TelemetryHealth, SmallLossIsReportedAsLossNotOk)
{
    const Health h = Collector::classifyIngestHealth(true, 149490, 510, 0, 1.0);
    EXPECT_EQ(h.status, "lossy");
    EXPECT_NE(h.status, "ok");
    EXPECT_NEAR(h.lossFraction, 0.0034, 0.0002);
}

// A single lost sample out of a large window is still not "ok". The boundary between "ok" and
// "lossy" is zero drops, not a threshold -- the thresholds only separate lossy from severe.
TEST(TelemetryHealth, OneLostSampleIsEnoughToLeaveOk)
{
    const Health h = Collector::classifyIngestHealth(true, 999999, 1, 0, 1.0);
    EXPECT_EQ(h.status, "lossy");
    EXPECT_GT(h.lossFraction, 0.0);
}

// Round 4 section 1, the cell that under-reported a 20 Mbit/s flow as 7.14 Mbit/s: 6 548 000
// datagrams offered, 4 745 333 lost. Every endpoint answered 200 "success" and every flow read
// "active". This is the reading that must not be able to look healthy.
TEST(TelemetryHealth, TheMeasuredSevereLossCellReadsSevere)
{
    const Health h = Collector::classifyIngestHealth(true, 1802667, 4745333, 0, 1.0);
    EXPECT_EQ(h.status, "severe_loss");
    EXPECT_EQ(h.offeredInWindow, 6548000u);
    EXPECT_NEAR(h.lossFraction, 0.725, 0.001);
}

// The three loss bands must be three different answers, in order. A classifier collapsing them
// to one string passes every "is the key there" test and fails this one.
TEST(TelemetryHealth, TheBandsAreOrderedAndDistinct)
{
    const Health none = Collector::classifyIngestHealth(true, 1000, 0, 0, 1.0);
    const Health small = Collector::classifyIngestHealth(true, 995, 5, 0, 1.0);   // 0.5%
    const Health mid = Collector::classifyIngestHealth(true, 950, 50, 0, 1.0);    // 5%
    const Health severe = Collector::classifyIngestHealth(true, 500, 500, 0, 1.0); // 50%

    EXPECT_EQ(none.status, "ok");
    EXPECT_EQ(small.status, "lossy");
    EXPECT_EQ(mid.status, "lossy");
    EXPECT_EQ(severe.status, "severe_loss");

    EXPECT_LT(none.lossFraction, small.lossFraction);
    EXPECT_LT(small.lossFraction, mid.lossFraction);
    EXPECT_LT(mid.lossFraction, severe.lossFraction);

    // Four conditions, three distinct verdicts, and the distinctions are the load-bearing part.
    EXPECT_NE(none.status, small.status);
    EXPECT_NE(mid.status, severe.status);
}

// The window length travels with the counts, so a reader can turn them into a rate and can tell a
// 1 s window from a 30 s one. A count without its window is not interpretable either.
TEST(TelemetryHealth, TheWindowLengthIsCarriedThrough)
{
    const Health h = Collector::classifyIngestHealth(true, 10, 0, 0, 2.5);
    EXPECT_DOUBLE_EQ(h.windowSeconds, 2.5);
    const Health unmeasured = Collector::classifyIngestHealth(false, 10, 0, 0, 2.5);
    EXPECT_DOUBLE_EQ(unmeasured.windowSeconds, 0.0);
}

} // namespace
