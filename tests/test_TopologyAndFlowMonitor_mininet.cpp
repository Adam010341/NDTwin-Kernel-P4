/**
 * Tests for TopologyAndFlowMonitor covering the isEnabled lifecycle, edge lookup,
 * edge up/down toggling, topology loading counts, flow table accumulation, and
 * getSwitchKind.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Expected behaviour is derived from:
 *   1. doc/2026-07-27_p4_bmv2_support_plan.md (issues #4, #5, #12)
 *   2. doc/audit/2026-08-08_external-tools-compat-review.md
 *   3. include/ndt_core/collection/TopologyAndFlowMonitor.hpp (interface contract)
 *   4. setting/StaticNetworkTopologyMininet_10Switches.json (data)
 *   5. doc/audit/2026-08-08_external-tools-compat-review.md (external tool expectations)
 *
 * The implementation (.cpp) is read ONLY for function signatures and object
 * construction; no assertion is derived from reading the implementation.
 */

#include <filesystem>
#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>

#include "common_types/GraphTypes.hpp"
#include "common_types/SFlowType.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Exposes the protected loadStaticTopologyFromFile for testing.
/// [Co-developed with claude code -- Adam]
class TestableTopologyAndFlowMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    /// Public seam for the protected loader.
    void load(const std::string& path)
    {
        loadStaticTopologyFromFile(path);
    }
};

/// Fixture holding a graph + monitor pair, loading the 138-node Mininet topology.
/// [Co-developed with claude code -- Adam]
struct MininetTopologyFixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    TestableTopologyAndFlowMonitor monitor{graph, mutex, bus, utils::TESTBED};

    /// Loads the Mininet 10-switch topology and returns the number of vertices.
    ///
    /// [Co-developed with claude code -- Adam]
    /// Tries multiple candidate paths relative to cwd.  If none exist, fails loudly
    /// with ADD_FAILURE rather than silently producing an empty graph (which would
    /// make every per-vertex/per-edge loop vacuously pass).
    size_t loadMininetTopology()
    {
        static const char* kCandidates[] = {
            "setting/StaticNetworkTopologyMininet_10Switches.json",
            "../setting/StaticNetworkTopologyMininet_10Switches.json",
            "../../setting/StaticNetworkTopologyMininet_10Switches.json",
        };

        std::string found;
        for (const char* candidate : kCandidates)
        {
            if (std::filesystem::exists(candidate))
            {
                found = candidate;
                break;
            }
        }

        if (found.empty())
        {
            ADD_FAILURE() << "could not find StaticNetworkTopologyMininet_10Switches.json "
                             "relative to the working directory ("
                          << std::filesystem::current_path().string()
                          << "); the assertions below would be vacuous";
            return 0;
        }

        monitor.load(found);
        std::shared_lock lock(*mutex);
        return boost::num_vertices(*graph);
    }

    /// Counts edges where both endpoints are switches (dpid != 0).
    /// [Co-developed with claude code -- Adam]
    size_t countSwitchToSwitchEdges()
    {
        std::shared_lock lock(*mutex);
        size_t count = 0;
        const auto [ei, ee] = boost::edges(*graph);
        for (auto e = ei; e != ee; ++e)
        {
            auto srcV = boost::source(*e, *graph);
            auto dstV = boost::target(*e, *graph);
            if ((*graph)[srcV].vertexType == VertexType::SWITCH &&
                (*graph)[dstV].vertexType == VertexType::SWITCH)
            {
                ++count;
            }
        }
        return count;
    }
};

} // namespace

// [Co-developed with claude code -- Adam]
// Spec source: doc/2026-07-27_p4_bmv2_support_plan.md issue #4 —
// "node 和 edge 初始都是 false"
TEST(MininetTopologyTest, AfterLoadingTopologyAllVerticesAndEdgesAreDisabled)
{
    MininetTopologyFixture fix;
    const size_t nVertices = fix.loadMininetTopology();

    // Guard: without this, every loop below is vacuous on an empty graph.
    // Spec source 4: topology file has 138 nodes, 288 edges.
    ASSERT_EQ(nVertices, 138u) << "fixture loaded nothing, per-vertex checks would be vacuous";

    std::shared_lock lock(*fix.mutex);

    // Check all vertices: isEnabled == false, isUp == false.
    const auto [vi, ve] = boost::vertices(*fix.graph);
    size_t vertsChecked = 0;
    for (auto v = vi; v != ve; ++v)
    {
        ++vertsChecked;
        const auto& vp = (*fix.graph)[*v];
        EXPECT_FALSE(vp.isEnabled)
            << "vertex " << vp.deviceName << " (dpid=" << vp.dpid
            << ") should have isEnabled==false after loading, per issue #4";
        EXPECT_FALSE(vp.isUp)
            << "vertex " << vp.deviceName << " (dpid=" << vp.dpid
            << ") should have isUp==false after loading, per issue #4";
    }
    EXPECT_EQ(vertsChecked, 138u);

    // Check all edges: isEnabled == false, isUp == false.
    const auto [ei, ee] = boost::edges(*fix.graph);
    size_t edgesChecked = 0;
    for (auto e = ei; e != ee; ++e)
    {
        ++edgesChecked;
        const auto& ep = (*fix.graph)[*e];
        EXPECT_FALSE(ep.isEnabled)
            << "edge srcDpid=" << ep.srcDpid << " dstDpid=" << ep.dstDpid
            << " should have isEnabled==false after loading, per issue #4";
        EXPECT_FALSE(ep.isUp)
            << "edge srcDpid=" << ep.srcDpid << " dstDpid=" << ep.dstDpid
            << " should have isUp==false after loading, per issue #4";
    }
    // Spec source 4: the topology file has exactly 288 directed edges.
    EXPECT_EQ(edgesChecked, 288u);
}

// [Co-developed with claude code -- Adam]
// Spec source: task coverage area #1 — inform_switch_entered should enable
// the switch AND all its adjacent edges (including host edges).
// Tests enableSwitchAndEdges, which implements this semantic.
TEST(MininetTopologyTest, EnableSwitchAndEdgesEnablesSwitchAndAllItsAdjacentEdgesButNotOtherSwitches)
{
    MininetTopologyFixture fix;
    const size_t n = fix.loadMininetTopology();
    ASSERT_EQ(n, 138u) << "fixture loaded nothing";

    // Pick a switch with known edges: dpid=1 (s1).
    // Spec source 4: s1 connects to s5, s6, and hosts h1-h16.
    const uint64_t kTestDpid = 1;
    const uint64_t kOtherDpid = 2;  // s2, should stay disabled

    // --- Pre-condition: everything is disabled ---
    {
        std::shared_lock lock(*fix.mutex);
        auto v1 = fix.monitor.findSwitchByDpidNoLock(kTestDpid);
        ASSERT_TRUE(v1.has_value()) << "s1 (dpid=1) must exist in topology";
        EXPECT_FALSE((*fix.graph)[*v1].isEnabled)
            << "pre-condition: s1 should be disabled before enableSwitchAndEdges";
    }

    // --- Act: enable switch 1 and all its edges ---
    fix.monitor.enableSwitchAndEdges(kTestDpid);

    // --- Assert: s1 is enabled ---
    {
        std::shared_lock lock(*fix.mutex);
        auto v1 = fix.monitor.findSwitchByDpidNoLock(kTestDpid);
        ASSERT_TRUE(v1.has_value());
        EXPECT_TRUE((*fix.graph)[*v1].isEnabled)
            << "s1 should be enabled after enableSwitchAndEdges";
    }

    // --- Assert: all edges incident to s1 are enabled ---
    {
        std::shared_lock lock(*fix.mutex);
        auto v1 = fix.monitor.findSwitchByDpidNoLock(kTestDpid);
        ASSERT_TRUE(v1.has_value());

        size_t incidentEdges = 0;
        size_t enabledIncidentEdges = 0;
        const auto [ei, ee] = boost::edges(*fix.graph);
        for (auto e = ei; e != ee; ++e)
        {
            auto srcV = boost::source(*e, *fix.graph);
            auto dstV = boost::target(*e, *fix.graph);
            if (srcV == *v1 || dstV == *v1)
            {
                ++incidentEdges;
                if ((*fix.graph)[*e].isEnabled)
                {
                    ++enabledIncidentEdges;
                }
            }
        }

        // Spec source 4: s1 has edges to s5, s6, and 16 hosts → 2*2 + 2*16 = 36 directed edges
        // (both directions: s1→neighbor and neighbor→s1)
        EXPECT_GT(incidentEdges, 0u)
            << "s1 should have incident edges";
        EXPECT_EQ(incidentEdges, enabledIncidentEdges)
            << "ALL edges incident to s1 should be enabled after enableSwitchAndEdges";
    }

    // --- Assert: other switches (e.g., s2) remain disabled ---
    {
        std::shared_lock lock(*fix.mutex);
        auto v2 = fix.monitor.findSwitchByDpidNoLock(kOtherDpid);
        ASSERT_TRUE(v2.has_value()) << "s2 (dpid=2) must exist in topology";
        EXPECT_FALSE((*fix.graph)[*v2].isEnabled)
            << "s2 should remain disabled; enableSwitchAndEdges(1) must not affect s2";
    }
}

// [Co-developed with claude code -- Adam]
// Spec source 3: TopologyAndFlowMonitor.hpp lines 143-144 —
// setVertexEnable and setEdgeEnable are separate methods, implying they are
// orthogonal: enabling a vertex must not implicitly enable its edges.
// Contrast with enableSwitchAndEdges, which does both.
TEST(MininetTopologyTest, SetVertexEnableOnlyEnablesThatVertexNotItsEdges)
{
    MininetTopologyFixture fix;
    const size_t n = fix.loadMininetTopology();
    ASSERT_EQ(n, 138u) << "fixture loaded nothing";

    const uint64_t kTestDpid = 1;

    // Find vertex for s1
    std::shared_lock readLock(*fix.mutex);
    auto v1Opt = fix.monitor.findSwitchByDpidNoLock(kTestDpid);
    ASSERT_TRUE(v1Opt.has_value());
    auto v1 = *v1Opt;
    readLock.unlock();

    // --- Act: enable only the vertex ---
    fix.monitor.setVertexEnable(v1);

    // --- Assert: vertex is enabled ---
    {
        std::shared_lock lock(*fix.mutex);
        EXPECT_TRUE((*fix.graph)[v1].isEnabled)
            << "setVertexEnable should enable the vertex";
    }

    // --- Assert: edges incident to s1 are still disabled ---
    {
        std::shared_lock lock(*fix.mutex);
        size_t enabledEdges = 0;
        const auto [ei, ee] = boost::edges(*fix.graph);
        for (auto e = ei; e != ee; ++e)
        {
            auto srcV = boost::source(*e, *fix.graph);
            auto dstV = boost::target(*e, *fix.graph);
            if ((srcV == v1 || dstV == v1) && (*fix.graph)[*e].isEnabled)
            {
                ++enabledEdges;
            }
        }
        EXPECT_EQ(enabledEdges, 0u)
            << "setVertexEnable must NOT enable incident edges; "
               "that is enableSwitchAndEdges' job";
    }
}

// [Co-developed with claude code -- Adam]
// Spec source 3: TopologyAndFlowMonitor.hpp lines 113-116 —
// findEdgeBySrcAndDstDpid takes a (srcDpid, dstDpid) pair and returns an
// optional edge_descriptor.
// Spec source 4: the topology has edge s1→s5 (srcDpid=1, dstDpid=5, iface 1→1)
// and edge s5→s1 (srcDpid=5, dstDpid=1, iface 1→1) as two distinct directed edges.
TEST(MininetTopologyTest, FindEdgeBySrcAndDstDpidFindsCorrectEdgeAndDistinguishesDirection)
{
    MininetTopologyFixture fix;
    const size_t n = fix.loadMininetTopology();
    ASSERT_EQ(n, 138u) << "fixture loaded nothing";

    // Spec source 4: s1→s5 exists with srcDpid=1, dstDpid=5.
    {
        auto edgeOpt = fix.monitor.findEdgeBySrcAndDstDpid({1, 5});
        ASSERT_TRUE(edgeOpt.has_value())
            << "edge 1→5 must exist in the Mininet topology";
        std::shared_lock lock(*fix.mutex);
        const auto& ep = (*fix.graph)[*edgeOpt];
        EXPECT_EQ(ep.srcDpid, 1u);
        EXPECT_EQ(ep.dstDpid, 5u);
    }

    // Reverse direction: s5→s1 must also exist AND be a different edge.
    {
        auto edgeOpt = fix.monitor.findEdgeBySrcAndDstDpid({5, 1});
        ASSERT_TRUE(edgeOpt.has_value())
            << "edge 5→1 must exist in the Mininet topology";
        std::shared_lock lock(*fix.mutex);
        const auto& ep = (*fix.graph)[*edgeOpt];
        EXPECT_EQ(ep.srcDpid, 5u);
        EXPECT_EQ(ep.dstDpid, 1u);
    }

    // The two edges must be distinct objects.
    {
        auto e15 = fix.monitor.findEdgeBySrcAndDstDpid({1, 5});
        auto e51 = fix.monitor.findEdgeBySrcAndDstDpid({5, 1});
        ASSERT_TRUE(e15.has_value());
        ASSERT_TRUE(e51.has_value());
        EXPECT_NE(*e15, *e51)
            << "edges 1→5 and 5→1 must be different edge descriptors in a directed graph";
    }

    // Non-existent edge: src dpid not in topology.
    {
        auto edgeOpt = fix.monitor.findEdgeBySrcAndDstDpid({1, 99});
        EXPECT_FALSE(edgeOpt.has_value())
            << "edge to non-existent dpid 99 must return nullopt";
    }

    // Non-existent edge: valid dpids but no edge between them.
    // Spec source 4: s1 and s2 are not directly connected.
    {
        auto edgeOpt = fix.monitor.findEdgeBySrcAndDstDpid({1, 2});
        EXPECT_FALSE(edgeOpt.has_value())
            << "s1→s2 does not exist in the topology; must return nullopt";
    }
}

// [Co-developed with claude code -- Adam]
// Spec source 3: TopologyAndFlowMonitor.hpp lines 132-135 —
// setEdgeDown/setEdgeUp take a single edge_descriptor and toggle isUp on that edge.
// In a directed graph, A→B and B→A are distinct edges; operating on one must not
// affect the other. Repeated calls should be idempotent.
TEST(MininetTopologyTest, SetEdgeDownAffectsOnlyTargetEdgeNotReverseAndIsIdempotent)
{
    MininetTopologyFixture fix;
    const size_t n = fix.loadMininetTopology();
    ASSERT_EQ(n, 138u) << "fixture loaded nothing";

    // First, enable the edges we're testing so isUp can be toggled meaningfully.
    // (After loading, isUp is false for all edges. We set them up first, then test
    // setEdgeDown.)
    auto e15Opt = fix.monitor.findEdgeBySrcAndDstDpid({1, 5});
    auto e51Opt = fix.monitor.findEdgeBySrcAndDstDpid({5, 1});
    ASSERT_TRUE(e15Opt.has_value()) << "edge 1→5 must exist";
    ASSERT_TRUE(e51Opt.has_value()) << "edge 5→1 must exist";
    auto e15 = *e15Opt;
    auto e51 = *e51Opt;

    // Set both edges up as baseline.
    fix.monitor.setEdgeUp(e15);
    fix.monitor.setEdgeUp(e51);

    // Verify baseline: both are up.
    {
        std::shared_lock lock(*fix.mutex);
        EXPECT_TRUE((*fix.graph)[e15].isUp) << "baseline: e15 should be up";
        EXPECT_TRUE((*fix.graph)[e51].isUp) << "baseline: e51 should be up";
    }

    // --- Act 1: set edge 1→5 down ---
    fix.monitor.setEdgeDown(e15);

    // --- Assert 1: only 1→5 is down, 5→1 is still up ---
    {
        std::shared_lock lock(*fix.mutex);
        EXPECT_FALSE((*fix.graph)[e15].isUp)
            << "e15 should be down after setEdgeDown(e15)";
        EXPECT_TRUE((*fix.graph)[e51].isUp)
            << "e51 must NOT be affected by setEdgeDown(e15); directed edges are independent";
    }

    // --- Act 2: set edge 1→5 down again (idempotent) ---
    fix.monitor.setEdgeDown(e15);

    // --- Assert 2: still down ---
    {
        std::shared_lock lock(*fix.mutex);
        EXPECT_FALSE((*fix.graph)[e15].isUp)
            << "setEdgeDown must be idempotent: e15 should still be down";
    }

    // --- Act 3: set edge 1→5 back up ---
    fix.monitor.setEdgeUp(e15);

    // --- Assert 3: 1→5 is up again, 5→1 unchanged ---
    {
        std::shared_lock lock(*fix.mutex);
        EXPECT_TRUE((*fix.graph)[e15].isUp)
            << "e15 should be up after setEdgeUp(e15)";
        EXPECT_TRUE((*fix.graph)[e51].isUp)
            << "e51 should still be up (was never set down)";
    }

    // --- Act 4: set edge 1→5 up again (idempotent) ---
    fix.monitor.setEdgeUp(e15);

    // --- Assert 4: still up ---
    {
        std::shared_lock lock(*fix.mutex);
        EXPECT_TRUE((*fix.graph)[e15].isUp)
            << "setEdgeUp must be idempotent: e15 should still be up";
    }
}

// [Co-developed with claude code -- Adam]
// Spec source 4: StaticNetworkTopologyMininet_10Switches.json —
// 10 switches (dpid 1-10) + 128 hosts (dpid 0) = 138 vertices.
// 32 switch↔switch directed edges + 256 host↔switch directed edges = 288 edges.
TEST(MininetTopologyTest, MininetTopologyHasCorrectVertexAndEdgeCounts)
{
    MininetTopologyFixture fix;
    const size_t nVertices = fix.loadMininetTopology();
    ASSERT_EQ(nVertices, 138u)
        << "expected 10 switches + 128 hosts = 138 vertices";

    std::shared_lock lock(*fix.mutex);
    const size_t nEdges = boost::num_edges(*fix.graph);
    EXPECT_EQ(nEdges, 288u)
        << "expected 32 switch↔switch + 256 host↔switch = 288 directed edges";
}

// [Co-developed with claude code -- Adam]
// Spec source 4: the topology file has exactly 10 switches with dpid 1-10.
TEST(MininetTopologyTest, MininetTopologyHasExactly10SwitchesWithDpid1Through10)
{
    MininetTopologyFixture fix;
    const size_t n = fix.loadMininetTopology();
    ASSERT_EQ(n, 138u) << "fixture loaded nothing";

    std::shared_lock lock(*fix.mutex);
    std::set<uint64_t> switchDpids;
    size_t switchCount = 0;
    const auto [vi, ve] = boost::vertices(*fix.graph);
    for (auto v = vi; v != ve; ++v)
    {
        const auto& vp = (*fix.graph)[*v];
        if (vp.vertexType == VertexType::SWITCH)
        {
            ++switchCount;
            switchDpids.insert(vp.dpid);
        }
    }
    EXPECT_EQ(switchCount, 10u) << "expected exactly 10 switches";

    // Verify dpids are exactly 1 through 10.
    EXPECT_EQ(switchDpids.size(), 10u);
    for (uint64_t dpid = 1; dpid <= 10; ++dpid)
    {
        EXPECT_TRUE(switchDpids.count(dpid))
            << "dpid " << dpid << " must be present";
    }
}

// [Co-developed with claude code -- Adam]
// Spec source 4: every host in the topology JSON has an "ip" array with at
// least one entry (e.g., "10.0.0.1" for h1 through "10.0.0.128" for h128).
TEST(MininetTopologyTest, EveryHostHasAtLeastOneIpv4Address)
{
    MininetTopologyFixture fix;
    const size_t n = fix.loadMininetTopology();
    ASSERT_EQ(n, 138u) << "fixture loaded nothing";

    std::shared_lock lock(*fix.mutex);
    size_t hostsChecked = 0;
    const auto [vi, ve] = boost::vertices(*fix.graph);
    for (auto v = vi; v != ve; ++v)
    {
        const auto& vp = (*fix.graph)[*v];
        if (vp.vertexType == VertexType::HOST)
        {
            ++hostsChecked;
            EXPECT_FALSE(vp.ip.empty())
                << "host " << vp.deviceName << " has empty ip list";
        }
    }
    // Guard: ensure we actually checked hosts (not an empty loop).
    EXPECT_EQ(hostsChecked, 128u) << "expected 128 hosts to check";
}

// [Co-developed with claude code -- Adam]
// Spec source 4: the topology has exactly 32 switch↔switch directed edges
// (16 bidirectional links). Verified by manual count from the JSON edges array:
//   1↔5, 1↔6, 5↔9, 6↔9, 2↔5, 2↔6, 3↔7, 3↔8, 7↔9, 8↔9,
//   4↔7, 4↔8, 5↔10, 6↔10, 7↔10, 8↔10  (16 pairs × 2 directions = 32).
TEST(MininetTopologyTest, SwitchToSwitchEdgesCountIsExactly32)
{
    MininetTopologyFixture fix;
    const size_t n = fix.loadMininetTopology();
    ASSERT_EQ(n, 138u) << "fixture loaded nothing";

    const size_t swSwEdges = fix.countSwitchToSwitchEdges();
    EXPECT_EQ(swSwEdges, 32u)
        << "there should be exactly 32 switch↔switch directed edges";
}

// [Co-developed with claude code -- Adam]
// SPEC-UNKNOWN: the header does not specify whether touchEdgeFlow replaces or
// accumulates. This test documents the CURRENT behaviour (accumulation).
//
// If the intended semantic is "replace the entire flow set when a new batch
// arrives", this test SHOULD FAIL, and the assertion below that old flows
// are still present should be changed to assert they are gone.
TEST(MininetTopologyTest, TouchEdgeFlowAccumulatesEntriesCurrentBehavior)
{
    MininetTopologyFixture fix;
    const size_t n = fix.loadMininetTopology();
    ASSERT_EQ(n, 138u) << "fixture loaded nothing";

    // Find a known edge: s1→s5.
    auto eOpt = fix.monitor.findEdgeBySrcAndDstDpid({1, 5});
    ASSERT_TRUE(eOpt.has_value()) << "edge 1→5 must exist";
    auto edge = *eOpt;

    // Create two distinct flow keys.
    // Spec source for FlowKey structure: SFlowType.hpp lines 25-42.
    sflow::FlowKey flow1{};
    flow1.srcIP = 0x0A000001;   // 10.0.0.1
    flow1.dstIP = 0x0A000002;   // 10.0.0.2
    flow1.srcPort = 1234;
    flow1.dstPort = 80;
    flow1.protocol = 6;         // TCP

    sflow::FlowKey flow2{};
    flow2.srcIP = 0x0A000003;   // 10.0.0.3
    flow2.dstIP = 0x0A000004;   // 10.0.0.4
    flow2.srcPort = 5678;
    flow2.dstPort = 80;
    flow2.protocol = 6;         // TCP

    // --- Act 1: touch first flow ---
    bool inserted1 = fix.monitor.touchEdgeFlow(edge, flow1);
    EXPECT_TRUE(inserted1) << "first touch of a new flow should return true (inserted)";

    // --- Assert 1: flow1 is in the edge's flow set ---
    {
        auto flowSet = fix.monitor.getEdgeFlowSet(edge);
        EXPECT_EQ(flowSet.size(), 1u) << "after touching one flow, flow set size should be 1";
        EXPECT_TRUE(flowSet.count(flow1))
            << "flow1 should be in the edge's flow set";
    }

    // --- Act 2: touch second flow ---
    bool inserted2 = fix.monitor.touchEdgeFlow(edge, flow2);
    EXPECT_TRUE(inserted2) << "first touch of flow2 should return true (inserted)";

    // --- Assert 2: BOTH flows are present (current accumulation behaviour) ---
    {
        auto flowSet = fix.monitor.getEdgeFlowSet(edge);
        EXPECT_EQ(flowSet.size(), 2u)
            << "SPEC-UNKNOWN: current behaviour accumulates flows; "
               "if replace semantics are intended, this should be 1 (only flow2)";
        EXPECT_TRUE(flowSet.count(flow1))
            << "flow1 should still be present (accumulation behaviour)";
        EXPECT_TRUE(flowSet.count(flow2))
            << "flow2 should be present";
    }

    // --- Act 3: re-touch flow1 (refresh) ---
    bool inserted3 = fix.monitor.touchEdgeFlow(edge, flow1);
    EXPECT_FALSE(inserted3)
        << "re-touching an existing flow should return false (not a new insertion)";

    // --- Assert 3: still 2 flows, no duplication ---
    {
        auto flowSet = fix.monitor.getEdgeFlowSet(edge);
        EXPECT_EQ(flowSet.size(), 2u)
            << "re-touching a flow must not duplicate it";
    }
}

// [Co-developed with claude code -- Adam]
// Spec source 3: TopologyAndFlowMonitor.hpp line 173 —
// getSwitchKind returns nullopt when dpid is not a switch in the loaded topology.
// Spec source 4: all switches in the Mininet topology have brand_name "OVS".
// Spec source (GraphTypes.hpp lines 55-67): brand_name "OVS" maps to SwitchKind::OVS.
TEST(MininetTopologyTest, GetSwitchKindReturnsOvsForKnownDpidsAndNulloptForUnknown)
{
    MininetTopologyFixture fix;
    const size_t n = fix.loadMininetTopology();
    ASSERT_EQ(n, 138u) << "fixture loaded nothing";

    // Known dpids 1-10 must return OVS.
    for (uint64_t dpid = 1; dpid <= 10; ++dpid)
    {
        auto kind = fix.monitor.getSwitchKind(dpid);
        ASSERT_TRUE(kind.has_value())
            << "dpid " << dpid << " is a switch in the topology; getSwitchKind must not be nullopt";
        EXPECT_EQ(*kind, SwitchKind::OVS)
            << "dpid " << dpid << " has brand_name OVS, so SwitchKind must be OVS";
    }

    // Unknown dpid must return nullopt.
    {
        auto kind = fix.monitor.getSwitchKind(99);
        EXPECT_FALSE(kind.has_value())
            << "dpid 99 is not in the topology; getSwitchKind must return nullopt";
    }

    // dpid 0 (host dpid) — hosts are not switches.
    // Spec source 3: the doc says "when the dpid is not a switch".
    // Hosts have dpid=0 but vertexType=HOST; m_dpidToSwitchKind is only
    // populated for SWITCH vertices.
    {
        auto kind = fix.monitor.getSwitchKind(0);
        EXPECT_FALSE(kind.has_value())
            << "dpid 0 is used by hosts, not switches; getSwitchKind must return nullopt";
    }
}

