// [Co-developed with claude code -- Adam]
//
// Regression tests for sflow::computeEstimatedRates.
//
// Commit 6f32bca removed the `if (hopsCounter == 0) continue;` guard from
// FlowLinkUsageCollector::calAvgFlowSendingRatesPeriodically while leaving hopsCounter
// as the divisor. hopsCounter only increments for hops reporting a non-zero byte rate,
// so any flow that went idle for a single 1-second tick divided by zero and killed the
// kernel with SIGFPE. These tests pin the guard in place.

#include <gtest/gtest.h>

#include "common_types/SFlowType.hpp"
// For MICE_FLOW_UNDER_THRESHOLD, which is what the wrapped value used to cross.
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"

#include <cstdint>
#include <limits>

TEST(ComputeEstimatedRatesTest, ZeroHopsReportsNoActiveHopsInsteadOfDividing)
{
    // The crash case: an idle flow still carries accumulated totals from earlier ticks
    // but no hop reported traffic in this interval.
    const auto rates = sflow::computeEstimatedRates(8000, 10, 0);

    EXPECT_FALSE(rates.hasActiveHops);
    EXPECT_EQ(rates.flowSendingRate, 0u);
    EXPECT_EQ(rates.packetSendingRate, 0u);
}

TEST(ComputeEstimatedRatesTest, NegativeHopsIsTreatedAsNoActiveHops)
{
    // hopsCounter is a signed int; defend the divisor rather than trusting the caller.
    const auto rates = sflow::computeEstimatedRates(8000, 10, -1);

    EXPECT_FALSE(rates.hasActiveHops);
    EXPECT_EQ(rates.flowSendingRate, 0u);
    EXPECT_EQ(rates.packetSendingRate, 0u);
}

TEST(ComputeEstimatedRatesTest, SingleHopReturnsAccumulatedTotalsUnchanged)
{
    const auto rates = sflow::computeEstimatedRates(1'000'000, 800, 1);

    EXPECT_TRUE(rates.hasActiveHops);
    EXPECT_EQ(rates.flowSendingRate, 1'000'000u);
    EXPECT_EQ(rates.packetSendingRate, 800u);
}

TEST(ComputeEstimatedRatesTest, AveragesAcrossHopsThatObservedTraffic)
{
    // A flow seen by 4 hops on its path: the per-hop sum is divided by the hop count to
    // recover the flow's own rate rather than the sum of every observation of it.
    const auto rates = sflow::computeEstimatedRates(4'000'000, 4'000, 4);

    EXPECT_TRUE(rates.hasActiveHops);
    EXPECT_EQ(rates.flowSendingRate, 1'000'000u);
    EXPECT_EQ(rates.packetSendingRate, 1'000u);
}

TEST(ComputeEstimatedRatesTest, IntegerDivisionTruncatesTowardZero)
{
    // Documents the existing (integer) behaviour so a future change to floating point
    // is a deliberate decision rather than an accident.
    const auto rates = sflow::computeEstimatedRates(10, 7, 3);

    EXPECT_TRUE(rates.hasActiveHops);
    EXPECT_EQ(rates.flowSendingRate, 3u);
    EXPECT_EQ(rates.packetSendingRate, 2u);
}

TEST(ComputeEstimatedRatesTest, ZeroTotalsAcrossActiveHopsStillCountsAsActive)
{
    // A hop can be active with a rate that rounds to zero; that is distinct from
    // "no hop reported traffic" and must not be conflated with the guard case.
    const auto rates = sflow::computeEstimatedRates(0, 0, 2);

    EXPECT_TRUE(rates.hasActiveHops);
    EXPECT_EQ(rates.flowSendingRate, 0u);
    EXPECT_EQ(rates.packetSendingRate, 0u);
}

TEST(ComputeEstimatedRatesTest, FlowAndPacketRatesAreDerivedFromSeparateAccumulators)
{
    // calAvgFlowSendingRatesImmediately divided the *byte* accumulator by hopsCounter for
    // estimatedPacketSendingRateImmediately, so the packet-rate field reported bytes.
    // A realistic case: 3 hops, 1500-byte frames. Bytes and packets differ by ~1500x, so
    // conflating them is unmissable here.
    const uint64_t bytesPerHop = 1500 * 100; // 100 frames of 1500 bytes
    const uint64_t packetsPerHop = 100;
    const int hops = 3;

    const auto rates = sflow::computeEstimatedRates(
        bytesPerHop * hops * 8, packetsPerHop * hops, hops);

    EXPECT_TRUE(rates.hasActiveHops);
    EXPECT_EQ(rates.flowSendingRate, bytesPerHop * 8u); // bits per second
    EXPECT_EQ(rates.packetSendingRate, packetsPerHop);  // packets, NOT bytes
    EXPECT_NE(rates.packetSendingRate, bytesPerHop);
}

TEST(ComputeEstimatedRatesTest, HandlesLargeAccumulatedTotalsWithoutOverflow)
{
    const uint64_t large = std::numeric_limits<uint64_t>::max();
    const auto rates = sflow::computeEstimatedRates(large, large, 2);

    EXPECT_TRUE(rates.hasActiveHops);
    EXPECT_EQ(rates.flowSendingRate, large / 2);
    EXPECT_EQ(rates.packetSendingRate, large / 2);
}

// --- counterDelta ------------------------------------------------------------------------------
//
// [Co-developed with claude code -- Adam]
// The rate loop subtracted two uint64_t counter readings directly. They are meant to be monotonic,
// so a reading that goes backwards does not give a small negative number -- it wraps to ~1.8e19,
// gets multiplied by 8 and the sampling rate, and is reported as the flow's bit rate. That sails
// past MICE_FLOW_UNDER_THRESHOLD (10 Mbps) and, because the clearing `else` was commented out, the
// elephant-flow flag then latched for the rest of the process.
//
// A counter going backwards was reachable: two sFlow workers racing on a newly created flow, where
// the loser's branch assigned the byte count instead of accumulating. That race is fixed, but
// purging and re-creating a flow between intervals reaches the same state, so the subtraction is
// guarded on its own terms.

TEST(CounterDeltaTest, TheOrdinaryForwardCaseIsPlainSubtraction)
{
    EXPECT_EQ(sflow::counterDelta(1500, 500), 1000u);
    EXPECT_EQ(sflow::counterDelta(1, 0), 1u);
}

TEST(CounterDeltaTest, NoTrafficSinceTheLastReadingIsZeroNotAnError)
{
    EXPECT_EQ(sflow::counterDelta(500, 500), 0u);
    EXPECT_EQ(sflow::counterDelta(0, 0), 0u);
}

TEST(CounterDeltaTest, ACounterThatWentBackwardsYieldsZeroRatherThanWrappingTo18Exa)
{
    // The actual defect. A bare `current - previous` here is 18446744073709551615.
    EXPECT_EQ(sflow::counterDelta(0, 1), 0u);
    EXPECT_EQ(sflow::counterDelta(500, 1500), 0u);
}

TEST(CounterDeltaTest, TheWrappedValueWouldHaveBeenReportedAsAnElephantFlow)
{
    // Ties the guard to the consequence rather than to the arithmetic. Reproduce what the call site
    // does with the delta -- x8, x sampling rate -- and check the unguarded form really does cross
    // the threshold while the guarded one does not. If MICE_FLOW_UNDER_THRESHOLD ever moves, this
    // still holds, because the wrapped value is 12 orders of magnitude above any plausible value.
    constexpr uint64_t current = 500;
    constexpr uint64_t previous = 1500; // a lost update: fewer bytes than last interval
    constexpr uint32_t samplingRate = 256;

    const uint64_t guarded = sflow::counterDelta(current, previous) * 8 * samplingRate;
    const uint64_t unguarded = (current - previous) * 8 * samplingRate; // what it used to compute

    EXPECT_EQ(guarded, 0u);
    EXPECT_GT(unguarded, MICE_FLOW_UNDER_THRESHOLD)
        << "the unguarded form no longer reproduces the bug; this test has stopped meaning anything";
    EXPECT_LT(guarded, MICE_FLOW_UNDER_THRESHOLD);
}

TEST(CounterDeltaTest, ARealCounterResetToZeroIsTheCommonBackwardsCase)
{
    // What purge-then-recreate looks like: the flow reappears with its counters at the frame size
    // of one packet while `previous` still holds the pre-purge total.
    EXPECT_EQ(sflow::counterDelta(1514, 9'000'000), 0u);
}

TEST(CounterDeltaTest, LargeForwardDeltasAreNotClamped)
{
    // The guard must not cost real throughput. A 10 Gbps link fills ~1.25 GB in a second.
    constexpr uint64_t previous = 1'000'000'000;
    constexpr uint64_t current = previous + 1'250'000'000;
    EXPECT_EQ(sflow::counterDelta(current, previous), 1'250'000'000u);

    // And the extreme edge stays exact.
    constexpr uint64_t max = std::numeric_limits<uint64_t>::max();
    EXPECT_EQ(sflow::counterDelta(max, 0), max);
    EXPECT_EQ(sflow::counterDelta(max, max), 0u);
}
