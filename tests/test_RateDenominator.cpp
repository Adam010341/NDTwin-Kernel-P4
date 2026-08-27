/**
 * Ticket Q: a published link rate must be bytes converted to bits per second over the interval
 * those bytes accumulated.
 *
 * [Co-developed with claude code -- Adam]
 *
 * THE DEFECT. updateLinkInfoLeftLinkBandwidth used to take a finished bits-per-second figure,
 * and both of its callers produced that figure as `accumulator * 8` -- nothing on the path
 * divided by elapsed time. The rate loop sleeps a full second and then runs its body, so its
 * period is 1000 ms plus the body and never exactly 1000. Every rate the kernel published was
 * therefore overstated by (real period / 1 s): tickets 1 and P measured that period between
 * 1001 and 1074 ms depending on load, and generation 1's in-loop instrument read 1249 ms at 64
 * flows.
 *
 * WHY THESE ASSERTIONS AND NOT OTHERS. The specification is "bits per second", so the tests fix
 * the relationship between bytes, an interval, and the published figure, and derive nothing from
 * how the conversion is written. In particular they do NOT assert that the loop period reads
 * ~1000 ms after the fix -- that gate was proposed, and it is wrong: dividing by the measured
 * interval corrects the arithmetic without changing how long an iteration takes, so it would
 * stay true whether or not the division was ever added.
 *
 * WHAT THE FIRST TEST IS FOR. SameBytesOverTwoSecondsIsHalfTheRate is the one that fails on the
 * unfixed code; the rest constrain the shape of the fix. If only one test in this file can be
 * kept, keep that one.
 *
 * MUTATION GATE -- each mutation was applied, the suite run, and the named test confirmed to be
 * the one that went red. "The gate turned red" is not the check; which light turned red is.
 *
 *   1. drop the `/ elapsedSeconds`         -> SameBytesOverTwoSecondsIsHalfTheRate
 *   2. `> 0.0` becomes `>= 0.0`            -> ZeroIntervalPublishesNothing
 *   3. sentinel `-1.0` becomes `0.0`       -> DivisorStartsAtASentinelNotZero
 *   4. store elapsed BEFORE the guard      -> ZeroIntervalDoesNotRecordADivisor
 */
#include <memory>
#include <shared_mutex>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

constexpr uint32_t kAgentIp = 0x0A000001;   // 10.0.0.1
constexpr uint32_t kPeerIp = 0x0A000002;    // 10.0.0.2
constexpr uint32_t kPort = 3;
constexpr uint64_t kLinkBandwidth = 1'000'000'000ULL;   // 1 Gbit/s, well above every rate here

/// One switch-to-switch edge addressable by (kAgentIp, kPort), which is the key the rate loop
/// hands to updateLinkInfoLeftLinkBandwidth.
struct RateFixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    std::unique_ptr<TopologyAndFlowMonitor> monitor;
    Graph::edge_descriptor edge;

    RateFixture()
    {
        auto a = boost::add_vertex(*graph);
        (*graph)[a].vertexType = VertexType::SWITCH;
        (*graph)[a].dpid = 1;
        (*graph)[a].deviceName = "s1";
        (*graph)[a].ip = {kAgentIp};

        auto b = boost::add_vertex(*graph);
        (*graph)[b].vertexType = VertexType::SWITCH;
        (*graph)[b].dpid = 5;
        (*graph)[b].deviceName = "s5";
        (*graph)[b].ip = {kPeerIp};

        auto [e, added] = boost::add_edge(a, b, *graph);
        EXPECT_TRUE(added);
        (*graph)[e].srcIp = {kAgentIp};
        (*graph)[e].srcInterface = kPort;
        (*graph)[e].dstIp = {kPeerIp};
        (*graph)[e].dstInterface = kPort;
        (*graph)[e].linkBandwidth = kLinkBandwidth;
        edge = e;

        monitor = std::make_unique<TopologyAndFlowMonitor>(graph, mutex, bus, utils::MININET);
    }

    void publish(uint64_t bytes, double seconds)
    {
        monitor->updateLinkInfoLeftLinkBandwidth({kAgentIp, kPort}, bytes, seconds);
    }

    uint64_t usage() const { return (*graph)[edge].linkBandwidthUsage; }
};

// --- the rate itself ---------------------------------------------------------------------

TEST(RateDenominator, SameBytesOverTwoSecondsIsHalfTheRate)
{
    // LOAD-BEARING. This is the defect: on the unfixed code both calls publish bytes*8 and the
    // two figures come out equal. Stated as a relationship between two calls rather than as an
    // absolute so that it tests the division and not one particular arithmetic spelling.
    RateFixture oneSecond;
    RateFixture twoSeconds;

    oneSecond.publish(1'000'000, 1.0);
    twoSeconds.publish(1'000'000, 2.0);

    EXPECT_EQ(oneSecond.usage(), 8'000'000u) << "1 MB in 1 s is 8 Mbit/s";
    EXPECT_EQ(twoSeconds.usage(), 4'000'000u)
        << "the same bytes over twice the interval is half the rate; equal figures here mean "
           "nothing divided by the interval";
}

TEST(RateDenominator, TheIntervalActuallyUsedIsTheOneSupplied)
{
    // Ticket Q's acceptance gate reads this accessor and compares it against the interval
    // measured independently for the same iteration. If the accessor reported anything other
    // than the divisor, the gate would be checking itself.
    RateFixture fix;
    fix.publish(500'000, 1.0432);
    EXPECT_DOUBLE_EQ(fix.monitor->lastRateDivisorSeconds(), 1.0432);
}

TEST(RateDenominator, ARealisticLoopPeriodOverstatesByExactlyThatPeriod)
{
    // The measured quantity, stated as the thing the round cares about: at ticket P's quiet-arm
    // period the old code overstates by 4.3%, which is the size of the effect ticket Q exists to
    // remove. Pinned so a future "simplification" back to bytes*8 has to argue with a number.
    RateFixture fix;
    fix.publish(1'000'000, 1.0432);
    const double asIfOneSecond = 8'000'000.0;
    EXPECT_NEAR(static_cast<double>(fix.usage()), asIfOneSecond / 1.0432, 1.0);
    EXPECT_LT(fix.usage(), asIfOneSecond) << "a period longer than 1 s must LOWER the rate";
}

// --- the interval that cannot produce a rate ---------------------------------------------

TEST(RateDenominator, ZeroIntervalPublishesNothing)
{
    // Zero bytes per zero seconds is not zero bits per second, and an edge carrying 0 looks
    // exactly like an idle link. Refusing leaves the previous measurement in place, which is at
    // least a measurement.
    RateFixture fix;
    fix.publish(1'000'000, 1.0);
    const uint64_t before = fix.usage();

    fix.publish(9'999'999, 0.0);
    EXPECT_EQ(fix.usage(), before) << "a zero interval must not overwrite a real measurement";
}

TEST(RateDenominator, NegativeIntervalPublishesNothing)
{
    RateFixture fix;
    fix.publish(1'000'000, 1.0);
    const uint64_t before = fix.usage();

    fix.publish(9'999'999, -0.5);   // a clock that went backwards
    EXPECT_EQ(fix.usage(), before);
}

TEST(RateDenominator, ZeroIntervalDoesNotRecordADivisor)
{
    // The gate asserts lastRateDivisorSeconds equals the measured interval. If a refused call
    // still recorded its interval, a run in which every publish was refused would present a
    // divisor the gate could pass -- the instrument would agree with itself about a rate that
    // was never published.
    RateFixture fix;
    fix.publish(1'000'000, 1.25);
    fix.publish(1'000'000, 0.0);
    EXPECT_DOUBLE_EQ(fix.monitor->lastRateDivisorSeconds(), 1.25)
        << "the last divisor must be the last one actually used";
}

TEST(RateDenominator, DivisorStartsAtASentinelNotZero)
{
    // Before anything is published there is no divisor. Zero is a value the gate could read as
    // "an interval was used", so the initial value has to sit outside the legal range.
    RateFixture fix;
    EXPECT_LT(fix.monitor->lastRateDivisorSeconds(), 0.0)
        << "'no rate published yet' must not be representable as a legal divisor";
}

}   // namespace
