/**
 * @file test_FlowBatchPartition.cpp
 * @brief Tests for partitionFlowBatchByKnownDpid, the flow-batch admission decision.
 *
 * [Co-developed with claude code -- Adam]
 *
 * The batch endpoint used to answer 200 for a batch naming a switch that does not exist. The first
 * fix rejected such a batch whole, with 404. That was wrong for the two applications that actually
 * write flows: both discard the response (Energy-Saving-App energy_saving_app.cpp:225 and :241,
 * Traffic-Engineering-App Traffic-engineering-App.py:572), so all-or-nothing did not make them
 * notice the error -- it silently turned a batch that used to apply its good entries into one that
 * applied nothing. The endpoint now applies what it can and names what it dropped.
 *
 * These tests cover the partition itself. The 404-versus-200 branch that consumes it lives in
 * HttpSession::processFlowBatch and needs a TopologyAndFlowMonitor, which the routing test harness
 * passes as nullptr, so that branch is covered by the L2 contract case batch_flow_entries__mixed
 * against a running kernel rather than here.
 */

#include "ndt_core/routing_management/FlowJob.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <set>
#include <vector>

namespace
{

FlowJob job(uint64_t dpid, int priority = 1)
{
    FlowJob j{};
    j.dpid = dpid;
    j.op = FlowOp::Install;
    j.priority = priority;
    j.match = nlohmann::json{{"eth_type", 2048}};
    j.actions = nlohmann::json::array({{{"type", "OUTPUT"}, {"port", 1}}});
    return j;
}

/// Known switches are 1..10, mirroring the ten-switch testbed topology.
auto knownIsOneToTen()
{
    return [](uint64_t dpid) { return dpid >= 1 && dpid <= 10; };
}

} // namespace

TEST(FlowBatchPartitionTest, ABatchOfKnownDpidsIsAcceptedWhole)
{
    std::vector<FlowJob> jobs{job(1), job(5), job(10)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    EXPECT_EQ(out.accepted.size(), 3u);
    EXPECT_EQ(out.rejectedEntries, 0u);
    EXPECT_TRUE(out.unknownDpids.empty());
}

TEST(FlowBatchPartitionTest, AnUnknownDpidIsDroppedAndTheRestSurvive)
{
    // The behaviour the whole change is about: one bad entry must not take the good ones with it.
    std::vector<FlowJob> jobs{job(1), job(999999999999ULL), job(3)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    ASSERT_EQ(out.accepted.size(), 2u);
    EXPECT_EQ(out.accepted[0].dpid, 1u);
    EXPECT_EQ(out.accepted[1].dpid, 3u);
    EXPECT_EQ(out.rejectedEntries, 1u);
    ASSERT_EQ(out.unknownDpids.size(), 1u);
    EXPECT_EQ(out.unknownDpids[0], 999999999999ULL);
}

TEST(FlowBatchPartitionTest, ABatchWhereNothingIsKnownAcceptsNothing)
{
    // Distinguished from the mixed case by the caller: accepted.empty() with rejectedEntries > 0 is
    // the only shape that still answers 404, because 200 with accepted == 0 would tell a caller
    // that reads only the status code that its request was fine.
    std::vector<FlowJob> jobs{job(777), job(888)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    EXPECT_TRUE(out.accepted.empty());
    EXPECT_EQ(out.rejectedEntries, 2u);
    EXPECT_EQ(out.unknownDpids.size(), 2u);
}

TEST(FlowBatchPartitionTest, EntriesAreCountedButDpidsAreDeduplicated)
{
    // Forty entries naming one absent switch is one thing to fix and forty things to re-send, so
    // the entry count and the dpid list are deliberately different numbers.
    std::vector<FlowJob> jobs{job(1), job(500), job(500), job(500), job(2)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    EXPECT_EQ(out.accepted.size(), 2u);
    EXPECT_EQ(out.rejectedEntries, 3u);
    ASSERT_EQ(out.unknownDpids.size(), 1u);
    EXPECT_EQ(out.unknownDpids[0], 500u);
}

TEST(FlowBatchPartitionTest, UnknownDpidsAreReportedInAscendingOrder)
{
    std::vector<FlowJob> jobs{job(900), job(100), job(500)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    ASSERT_EQ(out.unknownDpids.size(), 3u);
    EXPECT_EQ(out.unknownDpids[0], 100u);
    EXPECT_EQ(out.unknownDpids[1], 500u);
    EXPECT_EQ(out.unknownDpids[2], 900u);
}

TEST(FlowBatchPartitionTest, AcceptedEntriesKeepTheirRequestedOrder)
{
    // The dispatcher applies a modify after the install it supersedes only if the order survives,
    // so a partition that reorders would silently change which rule wins.
    std::vector<FlowJob> jobs{job(4, 10), job(4, 20), job(4, 30)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    ASSERT_EQ(out.accepted.size(), 3u);
    EXPECT_EQ(out.accepted[0].priority, 10);
    EXPECT_EQ(out.accepted[1].priority, 20);
    EXPECT_EQ(out.accepted[2].priority, 30);
}

TEST(FlowBatchPartitionTest, AnEmptyBatchIsNotAnError)
{
    // Reaches the 200 path with accepted == 0 and no rejections: a caller that sent nothing is not
    // told a switch is missing.
    const auto out = partitionFlowBatchByKnownDpid({}, knownIsOneToTen());

    EXPECT_TRUE(out.accepted.empty());
    EXPECT_EQ(out.rejectedEntries, 0u);
    EXPECT_TRUE(out.unknownDpids.empty());
}

TEST(FlowBatchPartitionTest, ThePayloadOfAnAcceptedEntrySurvivesTheMove)
{
    // The accepted jobs are moved out and then enqueued; a partition that copied only the dpid
    // would enqueue empty rules, and every assertion above would still pass.
    std::vector<FlowJob> jobs{job(6, 42)};
    jobs[0].match = nlohmann::json{{"eth_type", 2048}, {"ipv4_dst", "10.9.9.9"}};
    jobs[0].idleTimeout = 17;

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    ASSERT_EQ(out.accepted.size(), 1u);
    EXPECT_EQ(out.accepted[0].match.value("ipv4_dst", std::string{}), "10.9.9.9");
    EXPECT_EQ(out.accepted[0].idleTimeout, 17);
    EXPECT_EQ(out.accepted[0].priority, 42);
    EXPECT_EQ(out.accepted[0].op, FlowOp::Install);
}
