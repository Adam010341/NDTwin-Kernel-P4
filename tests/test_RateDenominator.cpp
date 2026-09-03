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
 *
 * ===========================================================================================
 * THE SECOND SUITE IN THIS FILE -- FlowRateDenominator -- IS THE HALF Q NEVER COVERED.
 * [Co-developed with claude code -- Adam]
 *
 * Everything above concerns the LINK rate. Q's pre-registration enumerated its targets by
 * grepping `MultiplySampingRate`, which finds the two link accumulators and nothing else, so
 * f5e35561 divided the link path and left the per-flow rates beside it computing
 * `delta * 8 * samplingRate` -- bits per loop period, published as
 * `estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot`. Six tests, all six driving
 * updateLinkInfoLeftLinkBandwidth, and the defect the file exists to prevent survived one
 * function away. That is the reason the flow tests live in this file rather than a new one: a
 * reader who comes here to check "is the denominator gated" must not be able to read a green
 * suite and conclude yes for a path it never touches.
 *
 * FLOW MUTATION GATE -- tests/shell/mutate_flow_rate_denominator.sh, results recorded in
 * doc/audit/2026-09-02_live-round/FLOW-RATE-DENOMINATOR.md.
 *
 *   F1. drop `/ elapsedSeconds` on the bit rate     -> FlowSameBytesOverTwoSecondsIsHalfTheRate
 *   F2. drop `/ elapsedSeconds` on the packet rate  -> FlowPacketRateIsPerSecondToo
 *   F3. `> 0.0` becomes `>= 0.0`                    -> ZeroIntervalLeavesTheFlowAlone
 *   F4. the loop passes a constant 1.0 (WIRING)     -> TheFlowDivisorIsMeasuredNotAssumed
 *
 * F4 is the one that matters most and the one an arithmetic-only test suite cannot have. A fix
 * wired to a constant passes every other test in this suite, and that is not hypothetical --
 * it is precisely the state this file was in between f5e35561 and today.
 */
#include <chrono>
#include <memory>
#include <shared_mutex>
#include <thread>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>

#include "common_types/GraphTypes.hpp"
#include "common_types/SFlowType.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
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

// ============================== the per-flow rate ==========================================
// [Co-developed with claude code -- Adam]  See this file's header for why these are here.

namespace
{

constexpr uint32_t kSamplingRate = 256;

/// One flow observed at one hop, with `sampledBytes` sampled bytes and `sampledPackets` sampled
/// packets banked since the last pass. Both counters are on the ingress side; the production
/// code sums ingress and egress before differencing, and which side carried the bytes is not
/// what these tests are about.
sflow::FlowInfo
oneHopFlow(uint64_t sampledBytes, uint64_t sampledPackets, uint32_t samplingRate = kSamplingRate)
{
    sflow::FlowInfo info;
    sflow::AgentKey hop{};
    hop.agentIP = 0x0A000001;
    hop.interfacePort = 3;
    sflow::FlowStats& stats = info.agentFlowStats[hop];
    stats.samplingRate = samplingRate;
    stats.ingressByteCountCurrent = sampledBytes;
    stats.ingresspacketCountCurrent = sampledPackets;
    return info;
}

/// The whole point of the sampling multiplier: `sampledBytes` observed at 1/N stands for N times
/// as many bytes on the wire. Written out here so the tests state the expected rate from the
/// definition of bits per second rather than from the expression under test.
uint64_t
expectedBps(uint64_t sampledBytes, double seconds, uint32_t samplingRate = kSamplingRate)
{
    return static_cast<uint64_t>(static_cast<double>(sampledBytes) * 8.0 * samplingRate / seconds);
}

}   // namespace

TEST(FlowRateDenominator, FlowSameBytesOverTwoSecondsIsHalfTheRate)
{
    // LOAD-BEARING, and the exact analogue of SameBytesOverTwoSecondsIsHalfTheRate one suite up.
    // On the unfixed code both calls produce `delta * 8 * samplingRate` and the two figures come
    // out equal. Stated as a relationship between two intervals so it tests the division rather
    // than one arithmetic spelling.
    sflow::FlowInfo oneSecond = oneHopFlow(1'000, 10);
    sflow::FlowInfo twoSeconds = oneHopFlow(1'000, 10);

    ASSERT_TRUE(sflow::updateFlowRatesForInterval(oneSecond, 1.0, MICE_FLOW_UNDER_THRESHOLD));
    ASSERT_TRUE(sflow::updateFlowRatesForInterval(twoSeconds, 2.0, MICE_FLOW_UNDER_THRESHOLD));

    EXPECT_EQ(oneSecond.estimatedFlowSendingRatePeriodically, expectedBps(1'000, 1.0));
    EXPECT_EQ(twoSeconds.estimatedFlowSendingRatePeriodically, expectedBps(1'000, 2.0))
        << "the same sampled bytes over twice the interval is half the rate; equal figures here "
           "mean nothing divided by the interval";
    EXPECT_EQ(oneSecond.estimatedFlowSendingRatePeriodically,
              2 * twoSeconds.estimatedFlowSendingRatePeriodically);
}

TEST(FlowRateDenominator, FlowPacketRateIsPerSecondToo)
{
    // Its own test rather than an extra assertion above: the two rates are two statements in the
    // source and a fix applied to one of them must not be able to pass by borrowing the other's
    // coverage. That is the shape of this whole ticket in miniature.
    sflow::FlowInfo oneSecond = oneHopFlow(1'000, 40);
    sflow::FlowInfo twoSeconds = oneHopFlow(1'000, 40);

    ASSERT_TRUE(sflow::updateFlowRatesForInterval(oneSecond, 1.0, MICE_FLOW_UNDER_THRESHOLD));
    ASSERT_TRUE(sflow::updateFlowRatesForInterval(twoSeconds, 2.0, MICE_FLOW_UNDER_THRESHOLD));

    EXPECT_EQ(oneSecond.estimatedPacketSendingRatePeriodically, 40u * kSamplingRate);
    EXPECT_EQ(twoSeconds.estimatedPacketSendingRatePeriodically, 40u * kSamplingRate / 2);
}

TEST(FlowRateDenominator, ARealisticLoopPeriodOverstatesTheFlowRateByThatPeriod)
{
    // The measured quantity, at this project's own recorded loop periods. 1.0432 s is ticket P's
    // quiet arm; 1.2487 s is the windowed mean this repo logged at 64 flows on 2026-08-25
    // (FlowLinkUsageCollector.hpp, kFlowActiveWindowMs's rationale). The second number is the
    // point of the test: the error is not a fixed unit slip, it grows with the flow count, so
    // two readings taken at different loads were never comparable with each other either.
    sflow::FlowInfo quiet = oneHopFlow(1'000, 10);
    sflow::FlowInfo busy = oneHopFlow(1'000, 10);

    ASSERT_TRUE(sflow::updateFlowRatesForInterval(quiet, 1.0432, MICE_FLOW_UNDER_THRESHOLD));
    ASSERT_TRUE(sflow::updateFlowRatesForInterval(busy, 1.2487, MICE_FLOW_UNDER_THRESHOLD));

    const double asIfOneSecond = static_cast<double>(expectedBps(1'000, 1.0));
    EXPECT_NEAR(static_cast<double>(quiet.estimatedFlowSendingRatePeriodically),
                asIfOneSecond / 1.0432, 1.0);
    EXPECT_NEAR(static_cast<double>(busy.estimatedFlowSendingRatePeriodically),
                asIfOneSecond / 1.2487, 1.0);
    EXPECT_LT(busy.estimatedFlowSendingRatePeriodically,
              quiet.estimatedFlowSendingRatePeriodically)
        << "a longer period must LOWER the rate, and it must do so by more at 64 flows than at "
           "one -- that load dependence is the damage this ticket is about";
}

TEST(FlowRateDenominator, AnElephantIsDecidedOnTheDividedRate)
{
    // The consequence, not the arithmetic, and the one that changed decisions rather than
    // citations. MICE_FLOW_UNDER_THRESHOLD is an ABSOLUTE 10 Mbit/s, so a uniform rescale walks
    // flows across it -- which is why the ordering survived the defect (see the test above) and
    // the flag did not.
    //
    // 5000 sampled bytes at 1/256 is 10.24 Mbit banked in the interval. Over the 1.2487 s period
    // this repo logged at 64 flows that is a flow really sending 8.20 Mbit/s -- a mouse. The
    // undivided figure is the same 10.24 Mbit/s the one-second column shows, so it was promoted.
    // Same bytes, same threshold, two periods, two verdicts, and only one of them is true.
    constexpr uint64_t kSampledBytes = 5'000;   // *8*256 = 10.24 Mbit in the interval
    sflow::FlowInfo overOneSecond = oneHopFlow(kSampledBytes, 10);
    sflow::FlowInfo overRealPeriod = oneHopFlow(kSampledBytes, 10);

    ASSERT_TRUE(
        sflow::updateFlowRatesForInterval(overOneSecond, 1.0, MICE_FLOW_UNDER_THRESHOLD));
    ASSERT_TRUE(
        sflow::updateFlowRatesForInterval(overRealPeriod, 1.2487, MICE_FLOW_UNDER_THRESHOLD));

    EXPECT_GE(overOneSecond.estimatedFlowSendingRatePeriodically, MICE_FLOW_UNDER_THRESHOLD);
    EXPECT_TRUE(overOneSecond.isElephantFlowPeriodically)
        << "10.24 Mbit in one second really is an elephant";

    EXPECT_LT(overRealPeriod.estimatedFlowSendingRatePeriodically, MICE_FLOW_UNDER_THRESHOLD);
    EXPECT_FALSE(overRealPeriod.isElephantFlowPeriodically)
        << "the same bytes over a 1.2487 s period are 8.20 Mbit/s, a mouse -- an elephant here "
           "means the threshold was applied to a figure that never had a denominator";
}

TEST(FlowRateDenominator, OneDivisorForEveryFlowSoTheOrderSurvives)
{
    // The question that separates "the numbers were wrong" from "the decisions were wrong".
    //
    // runFlowRatePass measures ONE interval and hands the same value to every flow in the walk,
    // so the defect was a uniform rescale within a pass. That is why top-k ORDER was never
    // affected -- getTopKFlowInfoJson sorts on this field, and a common positive factor cannot
    // reorder anything -- while the ELEPHANT flag was, because MICE_FLOW_UNDER_THRESHOLD is an
    // absolute 10 Mbit/s and a rescale walks flows across it. This test pins both halves so a
    // future change that gave flows different denominators (per-flow last-sample timestamps,
    // say) could not be made without a red light: that change would be a correctness improvement
    // for the absolute values and a silent reordering of every consumer's top-k.
    sflow::FlowInfo bigQuiet = oneHopFlow(4'000, 40);
    sflow::FlowInfo smallQuiet = oneHopFlow(1'000, 10);
    sflow::FlowInfo bigBusy = oneHopFlow(4'000, 40);
    sflow::FlowInfo smallBusy = oneHopFlow(1'000, 10);

    ASSERT_TRUE(sflow::updateFlowRatesForInterval(bigQuiet, 1.0, MICE_FLOW_UNDER_THRESHOLD));
    ASSERT_TRUE(sflow::updateFlowRatesForInterval(smallQuiet, 1.0, MICE_FLOW_UNDER_THRESHOLD));
    ASSERT_TRUE(sflow::updateFlowRatesForInterval(bigBusy, 1.2487, MICE_FLOW_UNDER_THRESHOLD));
    ASSERT_TRUE(sflow::updateFlowRatesForInterval(smallBusy, 1.2487, MICE_FLOW_UNDER_THRESHOLD));

    EXPECT_GT(bigQuiet.estimatedFlowSendingRatePeriodically,
              smallQuiet.estimatedFlowSendingRatePeriodically);
    EXPECT_GT(bigBusy.estimatedFlowSendingRatePeriodically,
              smallBusy.estimatedFlowSendingRatePeriodically)
        << "a common divisor must not reorder two flows";

    // 4:1 in, 4:1 out, at both periods -- to a truncation unit.
    EXPECT_NEAR(static_cast<double>(bigQuiet.estimatedFlowSendingRatePeriodically) /
                    static_cast<double>(smallQuiet.estimatedFlowSendingRatePeriodically),
                4.0, 0.001);
    EXPECT_NEAR(static_cast<double>(bigBusy.estimatedFlowSendingRatePeriodically) /
                    static_cast<double>(smallBusy.estimatedFlowSendingRatePeriodically),
                4.0, 0.001);
}

TEST(FlowRateDenominator, ZeroIntervalLeavesTheFlowAlone)
{
    // Same refusal as the link path, and the same reason: a flow reading 0 is indistinguishable
    // from a flow that stopped, and this file has already paid once for a stale rate that looked
    // like a measurement. The counters must survive too -- unlike the link accumulator, which
    // its caller zeroes unconditionally, these bytes are still owed to the next interval.
    sflow::FlowInfo info = oneHopFlow(1'000, 10);
    ASSERT_TRUE(sflow::updateFlowRatesForInterval(info, 1.0, MICE_FLOW_UNDER_THRESHOLD));
    const uint64_t before = info.estimatedFlowSendingRatePeriodically;
    ASSERT_GT(before, 0u);

    info.agentFlowStats.begin()->second.ingressByteCountCurrent += 9'999;
    EXPECT_FALSE(sflow::updateFlowRatesForInterval(info, 0.0, MICE_FLOW_UNDER_THRESHOLD));

    EXPECT_EQ(info.estimatedFlowSendingRatePeriodically, before)
        << "a zero interval must not overwrite a real measurement";
    EXPECT_EQ(info.agentFlowStats.begin()->second.ingressByteCountPrevious, 1'000u)
        << "and it must not drain the counters either -- those bytes are owed to the next pass";
}

TEST(FlowRateDenominator, NegativeIntervalLeavesTheFlowAlone)
{
    sflow::FlowInfo info = oneHopFlow(1'000, 10);
    ASSERT_TRUE(sflow::updateFlowRatesForInterval(info, 1.0, MICE_FLOW_UNDER_THRESHOLD));
    const uint64_t before = info.estimatedFlowSendingRatePeriodically;

    EXPECT_FALSE(sflow::updateFlowRatesForInterval(info, -0.5, MICE_FLOW_UNDER_THRESHOLD));
    EXPECT_EQ(info.estimatedFlowSendingRatePeriodically, before);
}

TEST(FlowRateDenominator, CountersAreDrainedSoTheNextIntervalStartsFromHere)
{
    // The numerator is a delta, so the divisor is only correct if the subtrahend advances with
    // it. A pass that computed the right rate and forgot to snapshot would report the whole
    // flow's lifetime bytes over one interval, every interval.
    sflow::FlowInfo info = oneHopFlow(1'000, 10);
    ASSERT_TRUE(sflow::updateFlowRatesForInterval(info, 1.0, MICE_FLOW_UNDER_THRESHOLD));
    ASSERT_GT(info.estimatedFlowSendingRatePeriodically, 0u);

    ASSERT_TRUE(sflow::updateFlowRatesForInterval(info, 1.0, MICE_FLOW_UNDER_THRESHOLD));
    EXPECT_EQ(info.estimatedFlowSendingRatePeriodically, 0u)
        << "no new bytes in the second interval means no rate in the second interval";
    EXPECT_FALSE(info.isElephantFlowPeriodically);
}

// --- the wiring, which no arithmetic test can reach ----------------------------------------

namespace
{

/// Exposes one rate pass, same pattern as ConcurrentCollector in test_FlowTableConcurrency.cpp.
class RatePassCollector : public sflow::FlowLinkUsageCollector
{
  public:
    RatePassCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                      std::shared_ptr<EventBus> bus,
                      std::shared_ptr<ndtClassifier::Classifier> classifier)
        : sflow::FlowLinkUsageCollector(std::move(monitor),
                                        nullptr,
                                        std::move(bus),
                                        utils::DeploymentMode::MININET,
                                        std::move(classifier))
    {
    }

    using sflow::FlowLinkUsageCollector::runFlowRatePass;
};

std::unique_ptr<RatePassCollector>
makeRatePassCollector()
{
    auto bus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                           std::make_shared<std::shared_mutex>(),
                                                           bus,
                                                           utils::DeploymentMode::MININET);
    return std::make_unique<RatePassCollector>(
        monitor, bus, std::make_shared<ndtClassifier::Classifier>());
}

}   // namespace

TEST(FlowRateDenominator, TheFlowDivisorIsMeasuredNotAssumed)
{
    // 🔴 THE TEST THIS TICKET EXISTS FOR. Every other assertion in this suite passes against a
    // fix that computes `bytes * 8 * rate / elapsedSeconds` and is then handed a hardcoded 1.0
    // by the loop -- which is exactly the state the kernel was in for the per-flow path, with a
    // fully tested divided link path one function away.
    //
    // It asserts the divisor against a clock the collector does not share, rather than against a
    // fixed band: if this laptop stalls mid-test both numbers grow together and the test stays
    // honest, while a constant 1.0 diverges from a 300 ms wait by twenty times the tolerance.
    auto collector = makeRatePassCollector();

    collector->runFlowRatePass();   // anchors the interval
    const auto opened = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    collector->runFlowRatePass();   // measures it
    const double wallSeconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - opened).count();

    const double divisor = collector->lastFlowRateDivisorSeconds();
    ASSERT_GT(divisor, 0.0) << "no per-flow divisor was recorded at all";
    EXPECT_NEAR(divisor, wallSeconds, 0.02 + wallSeconds * 0.10)
        << "the divisor must be the interval that actually elapsed (" << wallSeconds
        << " s), not a constant";
}

TEST(FlowRateDenominator, TheFlowDivisorStartsAtASentinelNotZero)
{
    auto collector = makeRatePassCollector();
    EXPECT_LT(collector->lastFlowRateDivisorSeconds(), 0.0)
        << "'no per-flow rate published yet' must not be readable as a legal divisor";
}

}   // namespace
