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

TEST(ComputeEstimatedRatesTest, HandlesLargeAccumulatedTotalsWithoutOverflow)
{
    const uint64_t large = std::numeric_limits<uint64_t>::max();
    const auto rates = sflow::computeEstimatedRates(large, large, 2);

    EXPECT_TRUE(rates.hasActiveHops);
    EXPECT_EQ(rates.flowSendingRate, large / 2);
    EXPECT_EQ(rates.packetSendingRate, large / 2);
}
