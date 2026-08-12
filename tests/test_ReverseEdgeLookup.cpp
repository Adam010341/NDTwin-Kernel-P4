/**
 * Tests for the reverse-edge lookups the sFlow ingest path uses.
 *
 * [Co-developed with claude code -- Adam]
 *
 * `boost::edge(u, v, g)` returns a pair: the descriptor, and a bool saying whether the edge
 * exists. `findReverseEdgeByAgentIpAndPort` and its NoLock twin took `.first` and discarded
 * `.second`, so a missing reverse edge came back as a *singular* edge_descriptor wrapped in an
 * engaged std::optional. Every caller checks the optional, and the optional says yes.
 *
 * FlowLinkUsageCollector writes through that descriptor on the sFlow ingest path
 * (`touchEdgeFlow(edgeOpt.value(), key)`), so per-edge flow bookkeeping ran on an invalid edge
 * whenever the graph held only one direction of a link. That state is reachable and acknowledged:
 * 7f738e6 exists precisely to report half-processed link transitions. It is a dropped error flag,
 * not a race, so no sanitizer flags it and nothing logs.
 *
 * The expectations here are the function's own signature: it returns an optional, and an optional
 * is how a lookup says "not found". Both directions are covered -- a missing reverse must be
 * nullopt, and a present reverse must still be found and be the *reverse*, not the edge that
 * matched the agent key. A guard that refuses everything would satisfy the first alone.
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

constexpr uint32_t kAgentIp = 0xC0A87B0B; // 192.168.123.11
constexpr uint32_t kPeerIp = 0xC0A87B0F;  // 192.168.123.15
constexpr uint32_t kPort = 1;

/// Two switches and whichever directions of the link between them a test asks for.
struct LinkFixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    std::unique_ptr<TopologyAndFlowMonitor> monitor;
    Graph::vertex_descriptor a{};
    Graph::vertex_descriptor b{};

    LinkFixture()
    {
        a = boost::add_vertex(*graph);
        (*graph)[a].dpid = 1;
        (*graph)[a].deviceName = "s1";
        (*graph)[a].ip = {kAgentIp};

        b = boost::add_vertex(*graph);
        (*graph)[b].dpid = 5;
        (*graph)[b].deviceName = "s5";
        (*graph)[b].ip = {kPeerIp};

        monitor = std::make_unique<TopologyAndFlowMonitor>(graph, mutex, bus, utils::MININET);
    }

    /// The direction the agent key names: a -> b, sampled at (kAgentIp, kPort).
    Graph::edge_descriptor addForward()
    {
        auto [e, added] = boost::add_edge(a, b, *graph);
        EXPECT_TRUE(added);
        (*graph)[e].srcIp = {kAgentIp};
        (*graph)[e].srcInterface = kPort;
        (*graph)[e].dstIp = {kPeerIp};
        (*graph)[e].dstInterface = kPort;
        return e;
    }

    /// The direction that has to exist for a reverse lookup to have an answer.
    Graph::edge_descriptor addReverse()
    {
        auto [e, added] = boost::add_edge(b, a, *graph);
        EXPECT_TRUE(added);
        (*graph)[e].srcIp = {kPeerIp};
        (*graph)[e].srcInterface = kPort;
        (*graph)[e].dstIp = {kAgentIp};
        (*graph)[e].dstInterface = kPort;
        return e;
    }
};

} // namespace

TEST(ReverseEdgeLookupTest, AMissingReverseEdgeIsReportedAsNotFound)
{
    LinkFixture fix;
    fix.addForward(); // one direction only

    const auto found = fix.monitor->findReverseEdgeByAgentIpAndPort({kAgentIp, kPort});

    EXPECT_FALSE(found.has_value())
        << "an absent reverse edge came back as an engaged optional holding a singular "
           "descriptor; the sFlow path writes through it";
}

TEST(ReverseEdgeLookupTest, AMissingReverseEdgeIsReportedAsNotFoundByTheNoLockTwin)
{
    LinkFixture fix;
    fix.addForward();

    // The two are copies of each other, so a fix applied to one and not the other is the likely
    // mistake, and the NoLock twin is the one on the hot path under a held lock.
    std::shared_lock lock(*fix.mutex);
    const auto found = fix.monitor->findReverseEdgeByAgentIpAndPortNoLock({kAgentIp, kPort});

    EXPECT_FALSE(found.has_value());
}

TEST(ReverseEdgeLookupTest, ThePresentReverseEdgeIsStillFound)
{
    LinkFixture fix;
    fix.addForward();
    const auto reverse = fix.addReverse();

    const auto found = fix.monitor->findReverseEdgeByAgentIpAndPort({kAgentIp, kPort});

    ASSERT_TRUE(found.has_value()) << "the guard refuses the case it exists to serve";
    EXPECT_EQ(*found, reverse) << "returned an edge, but not the reverse one";
    // Named the reverse direction, not the edge that matched the agent key.
    EXPECT_EQ(boost::source(*found, *fix.graph), fix.b);
    EXPECT_EQ(boost::target(*found, *fix.graph), fix.a);
}

TEST(ReverseEdgeLookupTest, AnAgentKeyThatMatchesNoEdgeIsNotFound)
{
    LinkFixture fix;
    fix.addForward();
    fix.addReverse();

    EXPECT_FALSE(fix.monitor->findReverseEdgeByAgentIpAndPort({kAgentIp, 99}).has_value())
        << "no edge leaves this agent on port 99";
    EXPECT_FALSE(fix.monitor->findReverseEdgeByAgentIpAndPort({0x0A000001, kPort}).has_value())
        << "no edge leaves this agent at all";
}
