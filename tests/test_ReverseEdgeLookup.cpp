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
#include <string>
#include <shared_mutex>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>

#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

using json = nlohmann::json;

namespace
{

const std::string kAgentIpStr = "192.168.123.11";
const std::string kPeerIpStr = "192.168.123.15";
// Derived rather than written as a literal: the graph stores whatever ipStringToUint32 produces,
// and a test that hard-codes one byte order silently tests that assumption instead of the code.
const uint32_t kAgentIp = utils::ipStringToUint32(kAgentIpStr);
const uint32_t kPeerIp = utils::ipStringToUint32(kPeerIpStr);
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
        (*graph)[a].vertexType = VertexType::SWITCH;
        (*graph)[a].dpid = 1;
        (*graph)[a].deviceName = "s1";
        (*graph)[a].ip = {kAgentIp};

        b = boost::add_vertex(*graph);
        (*graph)[b].vertexType = VertexType::SWITCH;
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

// ---------------------------------------------------------------------------
// The same dropped flag, in the endpoint that reports a link's bandwidth.
//
// [Co-developed with claude code -- Adam]
// getLinkBandwidthBetweenSwitches checked `.second` for the forward direction and not for the
// reverse, four lines apart, then read properties off whatever the singular descriptor addressed
// and published them as that direction's bandwidth.
//
// This case was added because the mutation run found it: dropping the reverse check reddened
// nothing, while dropping the same check in the finders above reddened three tests. A guard with
// no test is a guard that comes back.
// ---------------------------------------------------------------------------

TEST(ReverseEdgeLookupTest, ALinkWithOnlyOneDirectionIsReportedAsSuchNotAnswered)
{
    LinkFixture fix;
    fix.addForward(); // no reverse

    const json result = fix.monitor->getLinkBandwidthBetweenSwitches(kAgentIpStr, kPeerIpStr);

    EXPECT_TRUE(result.contains("error"))
        << "answered with bandwidth figures for a direction the graph does not hold: " << result.dump();
    EXPECT_FALSE(result.value("link_found", false))
        << "claimed a full link: " << result.dump();
}

TEST(ReverseEdgeLookupTest, ALinkWithBothDirectionsIsStillReported)
{
    LinkFixture fix;
    const auto forward = fix.addForward();
    const auto reverse = fix.addReverse();
    (*fix.graph)[forward].linkBandwidth = 1000;
    (*fix.graph)[reverse].linkBandwidth = 2000;

    const json result = fix.monitor->getLinkBandwidthBetweenSwitches(kAgentIpStr, kPeerIpStr);

    ASSERT_FALSE(result.contains("error")) << result.dump();
    EXPECT_TRUE(result.value("link_found", false)) << result.dump();
    // Each direction reports its own edge, not the other one's.
    EXPECT_EQ(result[kAgentIpStr + "_to_" + kPeerIpStr]["total_bandwidth_bps"], 1000);
    EXPECT_EQ(result[kPeerIpStr + "_to_" + kAgentIpStr]["total_bandwidth_bps"], 2000);
}
