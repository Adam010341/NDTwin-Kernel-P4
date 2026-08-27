// [Co-developed with claude code -- Adam]
//
// Last-hop link attribution: the switch-to-host edge of a flow's path.
//
// Link usage is credited from the ingress side -- a sample taken at (switch, inputPort) is
// attributed to the edge *arriving* at that port -- so every edge's accounting is owned by the
// switch downstream of it. The final hop of a path ends at a host, hosts run no sampler, and
// under that rule alone the last-hop edge reads usage=0 and flow_set=[] forever while the bytes
// demonstrably move. Found live by the memory-free acceptance round
// (doc/audit/2026-08-15_fresh-acceptance-report.md §3c: 0-for-7 polls across 2 directions and
// 3 egress switches, against 115 MB on the veth), and reproduced under concurrent NTG traffic
// on 2026-08-16: all four switch-to-host edges at 0 against 1.28 GB of ground truth.
//
// The fix banks the egress side of every ingress sample under (agentIp, outputPort) and pays
// out only the entries whose far end is a host (edge dstDpid == 0), once per rate-loop second.
// Switch-far-end entries are dropped: the downstream sampler owns those edges, and a second
// writer would fight it.
//
// The fixtures are the emitter's own committed bytes (generate_emitted_fixtures.py):
// emitted_udp.bin samples at ingress port 3 / egress port 4, emitted_tcp.bin at 1 / 2, both
// with sampling_rate 256 from agent 192.168.123.11. The switch kinds are loaded from a real
// (nodes-only) topology file naming every switch bmv2, because that is what switches
// lookupOfport to the identity mapping -- with kinds absent, both ports translate to 0 and the
// egress bank never fills, which is a different bug than the one under test.

#include <gtest/gtest.h>

#include <boost/graph/adjacency_list.hpp>

#include "common_types/GraphTypes.hpp"
#include "common_types/SFlowType.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>
#include <vector>

namespace
{

// [Co-developed with claude code -- Adam]
// Ticket Q gave creditHostBoundEgressEdges the interval its bytes accumulated over, because the
// rate it feeds was never divided by one. These tests are about WHICH edge gets the bytes, not
// about the rate, so they pass exactly one second: bytes * 8 / 1.0 is the arithmetic they were
// written against, and every expected value below is unchanged.
constexpr double kOneSecond = 1.0;

// The agent the committed fixtures are emitted from (dpid 1 in the topology below maps to
// 192.168.123.11), and the ports inside them.
const std::string kAgentIpStr = "192.168.123.11";
const uint32_t kAgentIp = utils::ipStringToUint32(kAgentIpStr);
const uint32_t kPeerIp = utils::ipStringToUint32("192.168.123.15");
const uint32_t kHostIp = utils::ipStringToUint32("10.0.0.3");
constexpr uint32_t kUdpIngressPort = 3;
constexpr uint32_t kUdpEgressPort = 4;  // leads to the host in this fixture's graph
constexpr uint32_t kTcpEgressPort = 2;  // leads to the peer switch
constexpr uint32_t kSamplingRate = 256;
// frame_udp(): 14 Ethernet + 20 IPv4 + 8 UDP + 20 payload.
constexpr uint64_t kUdpFrameLen = 62;

class ProbeCollector : public sflow::FlowLinkUsageCollector
{
  public:
    ProbeCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                   std::shared_ptr<EventBus> bus,
                   std::shared_ptr<ndtClassifier::Classifier> classifier)
        : sflow::FlowLinkUsageCollector(std::move(monitor),
                                        nullptr,
                                        std::move(bus),
                                        utils::DeploymentMode::MININET,
                                        std::move(classifier))
    {
    }

    using sflow::FlowLinkUsageCollector::creditHostBoundEgressEdges;

    using sflow::FlowLinkUsageCollector::handlePacket;
};

/// Exposes the protected loader, which is the production writer of the switch-kind index.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    TestableMonitor(std::shared_ptr<Graph> g,
                    std::shared_ptr<std::shared_mutex> m,
                    std::shared_ptr<EventBus> bus)
        : TopologyAndFlowMonitor(std::move(g), std::move(m), std::move(bus), utils::MININET)
    {
    }

    using TopologyAndFlowMonitor::loadStaticTopologyFromFile;
};

std::filesystem::path fixtureDir()
{
    for (const auto* candidate : {"tests/fixtures", "../tests/fixtures", "../../tests/fixtures"})
    {
        if (std::filesystem::is_directory(candidate))
        {
            return candidate;
        }
    }
    return {};
}

std::vector<char> loadFixture(const std::string& name)
{
    const auto dir = fixtureDir();
    if (dir.empty())
    {
        return {};
    }
    std::ifstream f(dir / name, std::ios::binary);
    if (!f)
    {
        return {};
    }
    return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}

std::string switchNode(uint64_t dpid)
{
    return R"({
      "vertex_type": 0,
      "mac": 0,
      "ip": ["192.168.123.)" + std::to_string(10 + dpid) + R"("],
      "dpid": )" + std::to_string(dpid) + R"(,
      "device_name": "s)" + std::to_string(dpid) + R"(",
      "nickname": "",
      "brand_name": "BMv2",
      "bridge_name": "s)" + std::to_string(dpid) + R"(",
      "device_layer": 1,
      "ecmp_groups": []
    })";
}

/// One sampling switch (dpid 1), the peer switch behind it (dpid 5), and the host its
/// port 4 leads to. Switch vertices and kinds come from the loader; the host vertex and
/// the three edges are added by hand so their descriptors stay in reach of assertions.
class LastHopAttributionTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }

    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_graphMutex = std::make_shared<std::shared_mutex>();
        auto bus = std::make_shared<EventBus>();
        m_monitor = std::make_shared<TestableMonitor>(m_graph, m_graphMutex, bus);

        m_topoPath = std::filesystem::temp_directory_path() /
                     ("ndt_lasthop_test_" + std::to_string(::getpid()) + ".json");
        {
            std::ofstream ofs(m_topoPath);
            ofs << "{\n  \"nodes\": [\n" << switchNode(1) << ",\n" << switchNode(5)
                << "\n  ],\n  \"edges\": []\n}\n";
        }
        m_monitor->loadStaticTopologyFromFile(m_topoPath.string());

        auto aOpt = m_monitor->findSwitchByDpid(1);
        auto bOpt = m_monitor->findSwitchByDpid(5);
        ASSERT_TRUE(aOpt.has_value());
        ASSERT_TRUE(bOpt.has_value());

        auto h = boost::add_vertex(*m_graph);
        (*m_graph)[h].vertexType = VertexType::HOST;
        (*m_graph)[h].deviceName = "h3";
        (*m_graph)[h].ip = {kHostIp};

        // The last hop: the sampling switch's egress port 4 to the host. dstDpid 0 is the
        // loader's marker for a non-switch endpoint.
        m_edgeToHost = addEdge(*aOpt, h, kAgentIp, kUdpEgressPort, kHostIp, 1, 1, 0);
        // A switch-to-switch egress from the same agent (the TCP fixture's egress port).
        m_edgeToPeer = addEdge(*aOpt, *bOpt, kAgentIp, kTcpEgressPort, kPeerIp, 2, 1, 5);
        // The edge the *ingress* attribution credits for the UDP fixture, so the normal
        // path has its answer and the fixture stays representative of a real topology.
        m_edgeFromPeer = addEdge(*bOpt, *aOpt, kPeerIp, 1, kAgentIp, kUdpIngressPort, 5, 1);

        m_collector = std::make_unique<ProbeCollector>(
            m_monitor, bus, std::make_shared<ndtClassifier::Classifier>());
    }

    void TearDown() override
    {
        std::error_code ec;
        std::filesystem::remove(m_topoPath, ec);
    }

    Graph::edge_descriptor addEdge(Graph::vertex_descriptor src,
                                   Graph::vertex_descriptor dst,
                                   uint32_t srcIp,
                                   uint32_t srcIf,
                                   uint32_t dstIp,
                                   uint32_t dstIf,
                                   uint64_t srcDpid,
                                   uint64_t dstDpid)
    {
        auto [e, added] = boost::add_edge(src, dst, *m_graph);
        EXPECT_TRUE(added);
        (*m_graph)[e].srcIp = {srcIp};
        (*m_graph)[e].srcInterface = srcIf;
        (*m_graph)[e].dstIp = {dstIp};
        (*m_graph)[e].dstInterface = dstIf;
        (*m_graph)[e].srcDpid = srcDpid;
        (*m_graph)[e].dstDpid = dstDpid;
        (*m_graph)[e].isUp = true;
        return e;
    }

    void feed(const std::string& name)
    {
        auto data = loadFixture(name);
        ASSERT_FALSE(data.empty())
            << name << " missing. Generate it with:\n"
            << "  python3 p4_proxy/tests/generate_emitted_fixtures.py";
        m_collector->handlePacket(data.data(), data.size());
    }

    uint64_t usageOf(Graph::edge_descriptor e) const
    {
        std::shared_lock lock(*m_graphMutex);
        return (*m_graph)[e].linkBandwidthUsage;
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_graphMutex;
    std::shared_ptr<TestableMonitor> m_monitor;
    std::unique_ptr<ProbeCollector> m_collector;
    std::filesystem::path m_topoPath;
    Graph::edge_descriptor m_edgeToHost{};
    Graph::edge_descriptor m_edgeToPeer{};
    Graph::edge_descriptor m_edgeFromPeer{};
};

} // namespace

TEST_F(LastHopAttributionTest, FindEdgeToHostReturnsTheHostBoundEdgeOnly)
{
    const auto host = m_monitor->findEdgeToHostByAgentIpAndPort({kAgentIp, kUdpEgressPort});
    ASSERT_TRUE(host.has_value());
    EXPECT_TRUE(host.value() == m_edgeToHost);

    EXPECT_FALSE(m_monitor->findEdgeToHostByAgentIpAndPort({kAgentIp, kTcpEgressPort}))
        << "a switch far end has its own sampler; it must not be classified host-bound";
    EXPECT_FALSE(m_monitor->findEdgeToHostByAgentIpAndPort({kAgentIp, 9}))
        << "a port with no edge at all";
}

TEST_F(LastHopAttributionTest, TheHostBoundSiteDividesByTheIntervalItWasGiven)
{
    // NEGATIVE CONTROL for ticket Q, required by the auditor: "deliberately leave one site
    // unfixed and assert it must go red -- without having seen it red, 'every site is asserted'
    // has no evidence behind it."
    //
    // There are two sites that publish a rate. Fixing one and not the other produces a read-out
    // where one edge class is corrected and another is not, which reads as "further from 1" or
    // "a third mechanism is acting" -- both wrong verdicts aimed at problems that do not exist.
    // This is the assertion for the switch->host site; the main-loop site is not reachable from
    // a unit test (it lives inside a threaded loop that sleeps a second per iteration) and is
    // covered by segment 2's live gate instead. That split is stated rather than papered over.
    //
    // To exercise the control: change creditHostBoundEgressEdges' call to
    // updateLinkInfoLeftLinkBandwidth to pass a literal 1.0 instead of elapsedSeconds. This test
    // must fail. tests/shell/mutate_rate_denominator.sh does exactly that.
    feed("emitted_udp.bin");
    m_collector->creditHostBoundEgressEdges(2.0);

    EXPECT_EQ(usageOf(m_edgeToHost), kUdpFrameLen * kSamplingRate * 8 / 2)
        << "the same bytes over two seconds is half the rate; the one-second value here means "
           "this call site ignored the interval it was handed";
}

TEST_F(LastHopAttributionTest, OneSampleCreditsTheLastHopEdgeWithSampledBytesTimesRate)
{
    feed("emitted_udp.bin");

    EXPECT_EQ(usageOf(m_edgeToHost), 0u)
        << "ingest banks the bytes; only the rate-loop drain may write the graph";

    m_collector->creditHostBoundEgressEdges(kOneSecond);

    EXPECT_EQ(usageOf(m_edgeToHost), kUdpFrameLen * kSamplingRate * 8)
        << "one sampled frame is worth frameLength x samplingRate bytes on the last hop";
}

TEST_F(LastHopAttributionTest, SwitchToSwitchEgressEntriesAreDroppedNotWritten)
{
    feed("emitted_tcp.bin"); // egress port 2: the edge to the peer switch

    m_collector->creditHostBoundEgressEdges(kOneSecond);

    EXPECT_EQ(usageOf(m_edgeToPeer), 0u)
        << "the downstream switch's ingress samples own this edge; the egress bank must "
           "drop the entry, not write it";
}

TEST_F(LastHopAttributionTest, TheCreditDecaysToZeroWhenTrafficStops)
{
    feed("emitted_udp.bin");
    m_collector->creditHostBoundEgressEdges(kOneSecond);
    ASSERT_NE(usageOf(m_edgeToHost), 0u);

    // A second pass with no new samples: the accumulator was zeroed by the first, so the
    // edge must read idle, exactly like every ingress-credited edge does.
    m_collector->creditHostBoundEgressEdges(kOneSecond);

    EXPECT_EQ(usageOf(m_edgeToHost), 0u)
        << "a drained entry that still carries last second's bytes would freeze the edge "
           "at its last rate instead of decaying";
}

TEST_F(LastHopAttributionTest, TwoSamplesInOneSecondAccumulate)
{
    feed("emitted_udp.bin");
    feed("emitted_udp.bin");

    m_collector->creditHostBoundEgressEdges(kOneSecond);

    EXPECT_EQ(usageOf(m_edgeToHost), 2 * kUdpFrameLen * kSamplingRate * 8)
        << "samples within one second must add, not overwrite";
}

TEST_F(LastHopAttributionTest, AnIngressLessSampleIsNotBankedTwice)
{
    auto data = loadFixture("emitted_udp.bin");
    ASSERT_FALSE(data.empty());
    // Word 14 of the datagram is the sample's input interface (see the layout table in
    // sflow_emitter.py). Zeroing it makes an egress-style sample: the parser then keys the
    // *ingress* bank by the output port, and banking the egress side too would count the
    // same bytes twice on (agent, outputPort).
    ASSERT_GE(data.size(), size_t(15 * 4));
    data[14 * 4] = data[14 * 4 + 1] = data[14 * 4 + 2] = data[14 * 4 + 3] = 0;

    m_collector->handlePacket(data.data(), data.size());
    m_collector->creditHostBoundEgressEdges(kOneSecond);

    EXPECT_EQ(usageOf(m_edgeToHost), 0u)
        << "an ingress-less sample is already keyed by its output port in the ingress bank; "
           "the egress bank must not take it as well";
}

TEST_F(LastHopAttributionTest, TheLastHopEdgeJoinsTheFlowSetOnceThePathIsKnown)
{
    // First sample: the path is not known yet, so no edge may be touched.
    feed("emitted_udp.bin");

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_EQ(table.size(), 1u);
    const sflow::FlowKey key = table.begin()->first;

    {
        std::shared_lock lock(*m_graphMutex);
        EXPECT_TRUE((*m_graph)[m_edgeToHost].flowSet.empty())
            << "flow_set was touched while the flow's path was still unknown";
    }

    sflow::Path path;
    path.emplace_back(key.srcIP, 0u);
    path.emplace_back(uint64_t(1), 1u); // through the sampling switch
    path.emplace_back(key.dstIP, 0u);
    m_collector->setAllPaths({path});

    feed("emitted_udp.bin");

    std::shared_lock lock(*m_graphMutex);
    EXPECT_EQ((*m_graph)[m_edgeToHost].flowSet.count(key), 1u)
        << "the flow's own path names this edge as its last hop, so the flow must appear "
           "in the edge's flow_set";
    EXPECT_TRUE((*m_graph)[m_edgeToPeer].flowSet.empty())
        << "the egress touch is for host-bound edges only";
}
