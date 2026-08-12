/**
 * Tests for the all-destination-path map: what a new snapshot does to the old one.
 *
 * [Co-developed with claude code -- Adam]
 *
 * `setAllPaths` filled `m_allPathMap` and `m_switchCountMap` with `operator[]` and never cleared
 * them, so an entry outlived the path that produced it. Paths do disappear -- a link failure makes
 * some host pairs unreachable and the control plane stops reporting them -- and
 * `refreshDestinationPathsPeriodically` calls this every 5-60 seconds for the life of the process.
 * `get_path_switch_count` would keep answering from a route that no longer exists.
 *
 * Same shape as the Classifier's empty-table bug fixed alongside this: a snapshot that only ever
 * added. Both were found by review, not by these suites, and neither had a test.
 *
 * The empty case is deliberately NOT symmetric with the Classifier's. There the empty array arrives
 * keyed by dpid, so it states something definite about one switch. Here it means "no paths at all",
 * which before convergence is a transient -- and the HTTP push path calls this unconditionally, so a
 * POST carrying `{"all_destination_paths": []}` must not wipe a populated map.
 */

#include <memory>
#include <shared_mutex>
#include <vector>

#include <gtest/gtest.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Same seam as TestableCollector in test_SFlowParsing.cpp: the power manager is not touched by
/// the path maps, so it can be null.
class PathCollector : public sflow::FlowLinkUsageCollector
{
  public:
    PathCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                  std::shared_ptr<EventBus> bus,
                  std::shared_ptr<ndtClassifier::Classifier> classifier)
        : sflow::FlowLinkUsageCollector(std::move(monitor),
                                        nullptr,
                                        std::move(bus),
                                        utils::DeploymentMode::MININET,
                                        std::move(classifier))
    {
    }
};

/// A path is a vector of (nodeId, port). Hosts carry an IP as the node id; switches carry a dpid.
/// The switch count the collector derives is `size() - 2`, i.e. everything between the endpoints.
sflow::Path
pathOf(uint32_t srcIp, std::vector<uint64_t> switchDpids, uint32_t dstIp)
{
    sflow::Path p;
    p.emplace_back(srcIp, 0u);
    for (const uint64_t dpid : switchDpids)
    {
        p.emplace_back(dpid, 1u);
    }
    p.emplace_back(dstIp, 0u);
    return p;
}

class AllDestinationPaths : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        auto bus = std::make_shared<EventBus>();
        auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                               std::make_shared<std::shared_mutex>(),
                                                               bus,
                                                               utils::DeploymentMode::MININET);
        m_collector = std::make_unique<PathCollector>(monitor,
                                                      bus,
                                                      std::make_shared<ndtClassifier::Classifier>());
    }

    std::unique_ptr<PathCollector> m_collector;

    static constexpr uint32_t kA = 0x0100000A; // 10.0.0.1 as in_addr::s_addr
    static constexpr uint32_t kB = 0x0200000A;
    static constexpr uint32_t kC = 0x0300000A;
};

} // namespace

TEST_F(AllDestinationPaths, ASnapshotIsStored)
{
    m_collector->setAllPaths({pathOf(kA, {1, 5, 2}, kB)});

    const auto paths = m_collector->getAllPaths();
    ASSERT_EQ(paths.size(), 1u);
    EXPECT_EQ(m_collector->getSwitchCount({kA, kB}).value_or(0), 3u) << "three switches between the endpoints";
}

TEST_F(AllDestinationPaths, ALaterSnapshotReplacesRatherThanMerges)
{
    // The bug. A -> B stops being reachable, so the control plane reports only A -> C. The old
    // A -> B entry used to survive, and get_path_switch_count kept answering from it.
    m_collector->setAllPaths({pathOf(kA, {1, 5, 2}, kB), pathOf(kA, {1, 6}, kC)});
    ASSERT_EQ(m_collector->getAllPaths().size(), 2u) << "precondition";

    m_collector->setAllPaths({pathOf(kA, {1, 6}, kC)});

    const auto paths = m_collector->getAllPaths();
    EXPECT_EQ(paths.size(), 1u)
        << "a path the control plane stopped reporting survived the new snapshot";
    EXPECT_EQ(paths.count({kA, kB}), 0u) << "the vanished route is still being served";
    EXPECT_EQ(paths.count({kA, kC}), 1u) << "the surviving route was lost";

    // The switch-count map has to lose it too, and this is the assertion that actually requires the
    // map to be cleared: a pair that is still present gets overwritten by operator[] anyway, so only
    // a *vanished* pair can detect a missing clear. Verified by mutation -- clearing just
    // m_allPathMap left every other test in this file green.
    EXPECT_FALSE(m_collector->getSwitchCount({kA, kB}).has_value())
        << "get_path_switch_count still answers for a pair the control plane stopped reporting";
    EXPECT_EQ(m_collector->getSwitchCount({kA, kC}).value_or(0), 2u);
}

TEST_F(AllDestinationPaths, ThePairThatSurvivesGetsItsNewCount)
{
    // A pair still present in the new snapshot must reflect the new route. This one passes with or
    // without the clear -- operator[] overwrites it -- and is here for the behaviour, not as the
    // guard against staleness. The guard is in ALaterSnapshotReplacesRatherThanMerges.
    m_collector->setAllPaths({pathOf(kA, {1, 5, 2}, kB)});
    ASSERT_EQ(m_collector->getSwitchCount({kA, kB}).value_or(0), 3u);

    // The same pair, now routed the short way.
    m_collector->setAllPaths({pathOf(kA, {1}, kB)});

    EXPECT_EQ(m_collector->getSwitchCount({kA, kB}).value_or(0), 1u)
        << "the switch count still reflects the old three-hop route";
}

TEST_F(AllDestinationPaths, AnEmptySnapshotDoesNotWipeAPopulatedMap)
{
    // Deliberately asymmetric with the Classifier's empty-table handling; see the file header.
    // handleInformAllDestinationPaths calls this unconditionally, so an external POST carrying an
    // empty list must not be able to blank the twin's routing view.
    m_collector->setAllPaths({pathOf(kA, {1, 5, 2}, kB)});
    ASSERT_EQ(m_collector->getAllPaths().size(), 1u);

    m_collector->setAllPaths({});

    EXPECT_EQ(m_collector->getAllPaths().size(), 1u)
        << "an empty snapshot cleared paths it said nothing about";
    EXPECT_EQ(m_collector->getSwitchCount({kA, kB}).value_or(0), 3u);
}

TEST_F(AllDestinationPaths, AnEmptySnapshotOnAnEmptyMapIsHarmless)
{
    m_collector->setAllPaths({});
    EXPECT_TRUE(m_collector->getAllPaths().empty());
}

TEST_F(AllDestinationPaths, RepeatingTheSameSnapshotIsStable)
{
    // refreshDestinationPathsPeriodically re-applies an unchanged snapshot every 5-60 seconds for
    // the life of the process. It must neither grow the maps nor lose entries.
    const std::vector<sflow::Path> snapshot = {pathOf(kA, {1, 5, 2}, kB), pathOf(kA, {1, 6}, kC)};
    for (int i = 0; i < 50; ++i)
    {
        m_collector->setAllPaths(snapshot);
    }

    EXPECT_EQ(m_collector->getAllPaths().size(), 2u);
    EXPECT_EQ(m_collector->getSwitchCount({kA, kB}).value_or(0), 3u);
    EXPECT_EQ(m_collector->getSwitchCount({kA, kC}).value_or(0), 2u);
}

// --- an empty path inside a non-empty snapshot -------------------------------------------------
//
// [Co-developed with claude code -- Adam]
// setAllPaths guarded the snapshot being empty but not an individual Path being empty, and then did
// path.front() / path.back() -- undefined behaviour on an empty container, not an empty result.
// Both callers today do filter empty paths out, but this is a public method, so a caller that does
// not is a segfault in the sFlow rate loop's neighbour rather than a rejected input. The switchCount
// line right below already guarded on size, so varying sizes were known about.
//
// Found by agy-review 0110.

TEST_F(AllDestinationPaths, AnEmptyPathInASnapshotIsSkippedRatherThanDereferenced)
{
    // Under the unguarded version this is UB; in practice a crash or a garbage key.
    EXPECT_NO_FATAL_FAILURE(m_collector->setAllPaths({sflow::Path{}}));
    EXPECT_TRUE(m_collector->getAllPaths().empty()) << "an empty path produced an entry";
}

TEST_F(AllDestinationPaths, TheUsablePathsInAMixedSnapshotAreStillStored)
{
    // The reason it skips rather than rejecting the whole snapshot: one bad path among hundreds
    // must not discard the good ones.
    m_collector->setAllPaths({sflow::Path{}, pathOf(kA, {1, 5, 2}, kB), sflow::Path{}});

    const auto paths = m_collector->getAllPaths();
    EXPECT_EQ(paths.size(), 1u) << "the good path was lost, or an empty one was stored";
    EXPECT_EQ(m_collector->getSwitchCount({kA, kB}).value_or(0), 3u);
}

TEST_F(AllDestinationPaths, AnEmptyPathDoesNotPreventTheReplacementOfEarlierData)
{
    // A snapshot that is non-empty overall still replaces, even if some of its entries are junk --
    // otherwise a single malformed path would freeze the map at its previous contents.
    m_collector->setAllPaths({pathOf(kA, {1, 5, 2}, kB)});
    ASSERT_EQ(m_collector->getAllPaths().size(), 1u) << "precondition";

    m_collector->setAllPaths({sflow::Path{}, pathOf(kA, {1, 6}, kC)});

    EXPECT_FALSE(m_collector->getSwitchCount({kA, kB}).has_value())
        << "the stale A->B entry survived a snapshot that no longer contains it";
    EXPECT_EQ(m_collector->getSwitchCount({kA, kC}).value_or(0), 2u);
}
