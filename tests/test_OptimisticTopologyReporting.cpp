/**
 * The twin must be able to move topology state toward "down", and must not move it toward "up"
 * on evidence that does not mean what the code thought it meant.
 *
 * [Co-developed with claude code -- Adam]
 *
 * The defects these pin are doc/KNOWN-ISSUES.md §C F-4, F-14 and F-16, which are one family:
 * every one of them is in the "optimistic" column, meaning the twin says healthy when the fabric
 * is not.
 *
 *   F-14  A host can never be marked down: no code path does it. The four production callers of
 *         setVertexDown all sit behind `vertexType == VertexType::SWITCH`
 *         (DeviceConfigurationAndPowerManager.cpp:684), and the only writer of a host vertex is
 *         updateHosts, which assigns `isUp = true` and nothing else.
 *   F-16  When a switch dies, only switch-to-switch edges are marked down. The only writer of
 *         edge-down is HttpSession::handleLinkFailure, which locates its edge by a *pair of
 *         dpids* (HttpSession.cpp:426, :437) -- and a host has no dpid, so a host-facing edge was
 *         not addressable by it at all.
 *   F-4   A dead switch-to-switch link is resurrected to is_up=true on the next poll, because
 *         updateHosts locates a host's edges by IP alone and a switch's own management address is
 *         learned as a host by both control planes.
 *
 * Expected behaviour is derived from:
 *   1. doc/KNOWN-ISSUES.md §C rows F-4 (:881), F-14 (:883), F-16 (:884) and the §D ruling (:965)
 *   2. include/common_types/GraphTypes.hpp -- the three availability flags, DownReason, and the
 *      rule that hosts are the vertices carrying no datapath id
 *   3. include/ndt_core/collection/TopologyAndFlowMonitor.hpp -- reconcileDerivedLiveness's
 *      contract and kMissesBeforeIsolating's justification
 *   4. setting/StaticNetworkTopologyMininet_10Switches.json (data: 10 switches on
 *      192.168.123.11-20, 128 hosts on 10.0.0.x, 32 switch-to-switch edges, 32 hosts on s1)
 *
 * Two of these tests are negative controls and are the ones to read first if this file ever goes
 * green for the wrong reason. `AHostWhoseSwitchIsHealthyStaysUp` fails if the derivation takes
 * everything down rather than the right things, which is the failure mode that would make every
 * other assertion here pass while the twin became useless. `OneMissedPollDoesNotIsolateAnything`
 * fails if the hysteresis is dropped, which is the failure mode that turns a power cycle into a
 * flap storm across /ndt/get_graph_data.
 */

#include <cstdio>
#include <filesystem>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Exposes the protected loader, the protected discovery writers and the protected derivation.
/// Same seam pattern as tests/test_AdministrativeDisable.cpp.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void load(const std::string& path) { loadStaticTopologyFromFile(path); }

    void pollHosts(const std::string& json) { updateHosts(json); }
    void pollLinks(const std::string& json) { updateLinks(json); }

    /// One derivation pass, as updateGraph runs it after the three discovery writers.
    void reconcile() { reconcileDerivedLiveness(); }

    /// The constant under test, so a test can say "one fewer than enough" without restating it.
    static constexpr unsigned missesBeforeIsolating() { return kMissesBeforeIsolating; }
};

constexpr uint64_t kS1 = 1;   ///< 192.168.123.11; 32 hosts and links to s5 and s6 hang off it.
constexpr uint64_t kS5 = 5;   ///< 192.168.123.15; s1's neighbour.
constexpr uint32_t kHostOnS1 = 1;  ///< 10.0.0.1, attached to s1 and to nothing else.
constexpr uint32_t kHostElsewhere = 100; ///< 10.0.0.100, attached to some switch that is not s1.

struct Fixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, utils::TESTBED};

    /// Loads the 10-switch / 128-host Mininet topology, failing loudly rather than leaving an
    /// empty graph -- every per-edge loop below would be vacuously true on one.
    void load()
    {
        static const char* kCandidates[] = {
            "setting/StaticNetworkTopologyMininet_10Switches.json",
            "../setting/StaticNetworkTopologyMininet_10Switches.json",
            "../../setting/StaticNetworkTopologyMininet_10Switches.json",
        };
        for (const char* candidate : kCandidates)
        {
            if (std::filesystem::exists(candidate))
            {
                monitor.load(candidate);
                std::shared_lock lock(*mutex);
                ASSERT_EQ(boost::num_vertices(*graph), 138u) << "wrong topology loaded";
                ASSERT_EQ(boost::num_edges(*graph), 288u) << "wrong topology loaded";
                return;
            }
        }
        FAIL() << "could not find StaticNetworkTopologyMininet_10Switches.json relative to "
               << std::filesystem::current_path().string();
    }

    /// The state the graph reaches once discovery has seen everything: all up, all enabled.
    /// The loader starts everything down (TopologyAndFlowMonitor.cpp:243, :318), so without this
    /// every switch is unusable and the derivation would isolate the entire fabric -- which would
    /// make the assertions below pass for a reason that has nothing to do with the defect.
    void converge()
    {
        std::unique_lock lock(*mutex);
        for (auto v : boost::make_iterator_range(boost::vertices(*graph)))
        {
            (*graph)[v].isUp = true;
            (*graph)[v].isEnabled = true;
            (*graph)[v].downReason = DownReason::None;
        }
        for (auto e : boost::make_iterator_range(boost::edges(*graph)))
        {
            (*graph)[e].isUp = true;
            (*graph)[e].isEnabled = true;
            (*graph)[e].downReason = DownReason::None;
        }
    }

    /// Marks every switch-to-switch edge down, the way an injected link failure would.
    /// @return how many it marked, so a test can assert the loop was not empty.
    size_t markEverySwitchToSwitchEdgeDown()
    {
        std::unique_lock lock(*mutex);
        size_t marked = 0;
        for (auto e : boost::make_iterator_range(boost::edges(*graph)))
        {
            auto& ep = (*graph)[e];
            if (ep.srcDpid != 0 && ep.dstDpid != 0)
            {
                ep.isUp = false;
                ++marked;
            }
        }
        return marked;
    }

    /// @return how many switch-to-switch edges currently read up.
    size_t switchToSwitchEdgesUp()
    {
        std::shared_lock lock(*mutex);
        size_t up = 0;
        for (auto e : boost::make_iterator_range(boost::edges(*graph)))
        {
            const auto& ep = (*graph)[e];
            if (ep.srcDpid != 0 && ep.dstDpid != 0 && ep.isUp)
            {
                ++up;
            }
        }
        return up;
    }

    /// The vertex for host 10.0.0.<last>, by IP.
    std::optional<Graph::vertex_descriptor> hostVertex(uint32_t last)
    {
        return monitor.findVertexByIp(utils::ipStringToUint32("10.0.0." + std::to_string(last)));
    }

    /// The switch-to-host edge s<dpid> -> 10.0.0.<last>, i.e. the one whose far end has no dpid.
    std::optional<Graph::edge_descriptor> switchToHostEdge(uint64_t dpid, uint32_t last)
    {
        std::shared_lock lock(*mutex);
        const uint32_t hostIp = utils::ipStringToUint32("10.0.0." + std::to_string(last));
        for (auto e : boost::make_iterator_range(boost::edges(*graph)))
        {
            const auto& ep = (*graph)[e];
            if (ep.srcDpid == dpid && ep.dstDpid == 0 && !ep.dstIp.empty() &&
                ep.dstIp[0] == hostIp)
            {
                return e;
            }
        }
        return std::nullopt;
    }

    void setSwitchUnusable(uint64_t dpid)
    {
        auto vOpt = monitor.findSwitchByDpid(dpid);
        ASSERT_TRUE(vOpt.has_value());
        monitor.setVertexDown(*vOpt);
    }

    /// A /v1.0/topology/hosts entry, in Ryu's shape.
    /// @param mac      what the control plane says the MAC is
    /// @param ipv4     what the control plane says the address is -- which is the whole point of
    ///                 the F-4 test, because it is allowed to be a switch's management address
    /// @param attachDpid  host["port"]["dpid"]
    static std::string hostReply(const std::string& mac,
                                 const std::string& ipv4,
                                 uint64_t attachDpid)
    {
        char hex[32];
        std::snprintf(hex, sizeof(hex), "%016lx", static_cast<unsigned long>(attachDpid));
        return std::string(R"([{"mac":")") + mac + R"(","ipv4":[")" + ipv4 +
               R"("],"ipv6":[],"port":{"dpid":")" + hex + R"(","port_no":"00000001"}}])";
    }
};

} // namespace

// ---------------------------------------------------------------------------------------------
// F-4 -- doc/KNOWN-ISSUES.md:881
// ---------------------------------------------------------------------------------------------

/**
 * Both control planes learn hosts from traffic, and a switch's management interface emits
 * traffic, so /v1.0/topology/hosts contains entries whose address belongs to a switch. updateHosts
 * resolves a host's edges by IP alone -- findEdgeByHostIp matches on srcIp, findEdgeBySrcAndDstIp
 * on the (srcIp, dstIp) pair, and neither looks at a datapath id -- so such an entry lands on a
 * switch-to-switch edge and sets it up. Every poll. That is what made an injected link failure
 * heal itself within one interval.
 *
 * Asserted over the whole set of 32 switch-to-switch edges rather than one named edge, so the
 * test does not depend on which of s1's out-edges the BGL out-edge set happens to order first.
 */
TEST(OptimisticTopologyReportingTest, ASwitchLearnedAsAHostDoesNotResurrectASwitchLink)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());
    fix.converge();

    const size_t marked = fix.markEverySwitchToSwitchEdgeDown();
    ASSERT_EQ(marked, 32u) << "pre-condition: the topology's 32 inter-switch links must be down, "
                              "otherwise this test cannot observe a resurrection";
    ASSERT_EQ(fix.switchToSwitchEdgesUp(), 0u) << "pre-condition did not take";

    // s1's management address, offered as a host, attached to its neighbour s5. The MAC is one no
    // vertex in the topology carries: that is the real shape of the entry, and it matters, because
    // updateHosts only WARNs when the MAC does not resolve and then carries on to the IP lookups.
    fix.monitor.pollHosts(Fixture::hostReply("aa:bb:cc:dd:ee:ff", "192.168.123.11", kS5));

    EXPECT_EQ(fix.switchToSwitchEdgesUp(), 0u)
        << "a hosts entry naming a switch's management address brought an inter-switch link back "
           "up; an operator's injected link failure does not survive one poll";
}

/**
 * The rejected shape of the fix above is "stop updateHosts writing edges at all", which would
 * break discovery: the loader starts every edge down and updateHosts is the only thing that ever
 * raises a host's two edges. This is the test that fails if anyone implements that version.
 *
 * Same role as DiscoveryStillEnablesEverythingElse in test_AdministrativeDisable.cpp.
 */
TEST(OptimisticTopologyReportingTest, ARealHostEntryStillRaisesItsOwnTwoEdges)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());
    // Deliberately NOT converged: this is the state discovery actually starts from.

    auto fwd = fix.monitor.findEdgeByHostIp(utils::ipStringToUint32("10.0.0.1"));
    auto rev = fix.switchToHostEdge(kS1, kHostOnS1);
    ASSERT_TRUE(fwd.has_value()) << "fixture: h1's edge to s1 is missing";
    ASSERT_TRUE(rev.has_value()) << "fixture: s1's edge to h1 is missing";

    {
        std::shared_lock lock(*fix.mutex);
        ASSERT_FALSE((*fix.graph)[*fwd].isUp) << "pre-condition: the loader starts edges down";
        ASSERT_FALSE((*fix.graph)[*rev].isUp) << "pre-condition: the loader starts edges down";
    }

    // h1's MAC in the topology file is 1, so this entry resolves everywhere it should.
    fix.monitor.pollHosts(Fixture::hostReply("00:00:00:00:00:01", "10.0.0.1", kS1));

    std::shared_lock lock(*fix.mutex);
    EXPECT_TRUE((*fix.graph)[*fwd].isUp) << "discovery stopped raising a real host's edge";
    EXPECT_TRUE((*fix.graph)[*rev].isUp) << "discovery stopped raising a real host's return edge";
}

// ---------------------------------------------------------------------------------------------
// F-16 -- doc/KNOWN-ISSUES.md:884
// ---------------------------------------------------------------------------------------------

/**
 * A switch that is gone takes its host-facing edges with it. Before, only the inter-switch edges
 * could be marked down -- /ndt/link_failed names its edge by (src_dpid, dst_dpid) and a host has
 * no dpid -- so the 32 hosts on s1 went on showing a live link to a switch that was not there.
 */
TEST(OptimisticTopologyReportingTest, HostFacingEdgesOfAnUnreachableSwitchGoDownWithAReason)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());
    fix.converge();

    auto hostEdge = fix.switchToHostEdge(kS1, kHostOnS1);
    ASSERT_TRUE(hostEdge.has_value());
    {
        std::shared_lock lock(*fix.mutex);
        ASSERT_TRUE((*fix.graph)[*hostEdge].isUp) << "pre-condition: converged means up";
    }

    ASSERT_NO_FATAL_FAILURE(fix.setSwitchUnusable(kS1));
    for (unsigned i = 0; i < TestableMonitor::missesBeforeIsolating(); ++i)
    {
        fix.monitor.reconcile();
    }

    std::shared_lock lock(*fix.mutex);
    const auto& ep = (*fix.graph)[*hostEdge];
    EXPECT_FALSE(ep.isUp) << "s1 is unreachable and its host-facing edge still reads up; a host "
                             "with no path to the fabric looks connected";
    EXPECT_EQ(ep.downReason, DownReason::SwitchUnreachable)
        << "the transition happened but says nothing about why, so a consumer cannot tell it from "
           "an injected link failure";
}

// ---------------------------------------------------------------------------------------------
// F-14 -- doc/KNOWN-ISSUES.md:883
// ---------------------------------------------------------------------------------------------

/**
 * A host behind an unreachable switch must be markable down, and must say why. The "why" is not
 * decoration: this is a derived statement, not a probed one -- nothing asked the host anything --
 * and a consumer that cannot tell the two apart would be right to distrust both.
 */
TEST(OptimisticTopologyReportingTest, AHostBehindAnUnreachableSwitchIsMarkedDownWithAReason)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());
    fix.converge();

    auto h = fix.hostVertex(kHostOnS1);
    ASSERT_TRUE(h.has_value()) << "fixture: 10.0.0.1 is not in the topology";

    ASSERT_NO_FATAL_FAILURE(fix.setSwitchUnusable(kS1));
    for (unsigned i = 0; i < TestableMonitor::missesBeforeIsolating(); ++i)
    {
        fix.monitor.reconcile();
    }

    std::shared_lock lock(*fix.mutex);
    const auto& vp = (*fix.graph)[*h];
    EXPECT_FALSE(vp.isUp) << "no code path can mark a host down; is_up is a constant true once "
                             "discovery has seen it";
    EXPECT_EQ(vp.downReason, DownReason::SwitchUnreachable)
        << "a host reported down without a reason is the twin claiming a probe it never ran";
}

// ---------------------------------------------------------------------------------------------
// Negative controls. Read these first when this file goes green for the wrong reason.
// ---------------------------------------------------------------------------------------------

/**
 * The derivation must isolate the right things, not everything. A host on a healthy switch is
 * untouched, and so are edges that do not end on the unreachable switch.
 *
 * Without this, a reconcileDerivedLiveness that simply took the whole graph down would pass every
 * other assertion in this file.
 */
TEST(OptimisticTopologyReportingTest, AHostWhoseSwitchIsHealthyStaysUp)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());
    fix.converge();

    auto elsewhere = fix.hostVertex(kHostElsewhere);
    ASSERT_TRUE(elsewhere.has_value());

    // Resolved before any lock is taken. Every find* on this class takes its own shared_lock, and
    // std::shared_mutex is not recursive: acquiring it twice on one thread is undefined behaviour,
    // not a no-op. The same hazard is why loadStaticTopologyFromFile calls findVertexByIpNoLock.
    auto far = fix.monitor.findEdgeBySrcAndDstDpid({5, 9});
    ASSERT_TRUE(far.has_value()) << "fixture: the s5-s9 link is missing";

    {
        std::shared_lock lock(*fix.mutex);
        ASSERT_NE(boost::out_degree(*elsewhere, *fix.graph), 0u)
            << "fixture: 10.0.0.100 must attach to something, or this control is vacuous";
    }

    ASSERT_NO_FATAL_FAILURE(fix.setSwitchUnusable(kS1));
    for (unsigned i = 0; i < TestableMonitor::missesBeforeIsolating() + 1; ++i)
    {
        fix.monitor.reconcile();
    }

    std::shared_lock lock(*fix.mutex);
    const auto& vp = (*fix.graph)[*elsewhere];
    EXPECT_TRUE(vp.isUp) << "one unreachable switch took down a host that does not attach to it";
    EXPECT_EQ(vp.downReason, DownReason::None);

    // And an inter-switch link with no endpoint on s1 is untouched: s5 <-> s9 in this topology.
    EXPECT_TRUE((*fix.graph)[*far].isUp) << "an unrelated inter-switch link was taken down";
}

/**
 * One poll of "unusable" is a power cycle between del-br and add-br, not an outage. Isolating on
 * it turns every restart into a flap across /ndt/get_graph_data for 32 hosts and 66 edges at once.
 *
 * This is the test that fails if kMissesBeforeIsolating is dropped to 1 or the counter is reset
 * in the wrong place.
 */
TEST(OptimisticTopologyReportingTest, OneMissedPollDoesNotIsolateAnything)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());
    fix.converge();

    ASSERT_GT(TestableMonitor::missesBeforeIsolating(), 1u)
        << "this test only means something while the derivation has hysteresis at all";

    auto h = fix.hostVertex(kHostOnS1);
    auto hostEdge = fix.switchToHostEdge(kS1, kHostOnS1);
    ASSERT_TRUE(h.has_value());
    ASSERT_TRUE(hostEdge.has_value());

    ASSERT_NO_FATAL_FAILURE(fix.setSwitchUnusable(kS1));
    fix.monitor.reconcile(); // exactly one

    std::shared_lock lock(*fix.mutex);
    EXPECT_TRUE((*fix.graph)[*h].isUp)
        << "a single poll of switch-unusable isolated a host; a power cycle now flaps the twin";
    EXPECT_TRUE((*fix.graph)[*hostEdge].isUp)
        << "a single poll of switch-unusable took an edge down";
}

/**
 * Recovery releases the reason; it does not raise anything by itself.
 *
 * This one guards a rule that is easy to lose in a later edit and impossible to see afterwards:
 * the derivation may take things down, because it has evidence (a switch positively observed
 * absent), but it has no evidence that anything is up. Raising is discovery's job. A derivation
 * that both lowered and raised would be the seventh site in TopologyAndFlowMonitor.cpp asserting
 * liveness it never observed -- which is exactly the branch that was deleted from
 * DeviceConfigurationAndPowerManager.cpp:781-802 for the same reason.
 */
TEST(OptimisticTopologyReportingTest, RecoveryClearsTheReasonWithoutRaisingAnything)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());
    fix.converge();

    auto hostEdge = fix.switchToHostEdge(kS1, kHostOnS1);
    ASSERT_TRUE(hostEdge.has_value());

    ASSERT_NO_FATAL_FAILURE(fix.setSwitchUnusable(kS1));
    for (unsigned i = 0; i < TestableMonitor::missesBeforeIsolating(); ++i)
    {
        fix.monitor.reconcile();
    }
    {
        std::shared_lock lock(*fix.mutex);
        ASSERT_FALSE((*fix.graph)[*hostEdge].isUp) << "pre-condition: it must be down first";
        ASSERT_EQ((*fix.graph)[*hostEdge].downReason, DownReason::SwitchUnreachable);
    }

    // The switch answers again. Discovery has not run, so nothing has re-observed the edge.
    auto s1 = fix.monitor.findSwitchByDpid(kS1);
    ASSERT_TRUE(s1.has_value());
    fix.monitor.setVertexUp(*s1);
    fix.monitor.reconcile();

    std::shared_lock lock(*fix.mutex);
    const auto& ep = (*fix.graph)[*hostEdge];
    EXPECT_EQ(ep.downReason, DownReason::None) << "the reason outlived the condition it names";
    EXPECT_FALSE(ep.isUp)
        << "the derivation raised an edge nobody had re-observed; only discovery may do that";
}

/*
 * [Co-developed with claude code -- Adam]
 * Mutation gate -- what each test dies to, so a future reader can check they still discriminate:
 *
 *  - ASwitchLearnedAsAHostDoesNotResurrectASwitchLink
 *        dies if the findSwitchByIp rejection in updateHosts is removed AND either direction
 *        guard (srcDpid == 0 / dstDpid == 0) is removed. Removing only one of the three still
 *        leaves it green, which is the point of having all three: they are three routes to the
 *        same edge, not one check written out three times.
 *  - ARealHostEntryStillRaisesItsOwnTwoEdges
 *        dies if the F-4 guards are widened into "updateHosts writes no edges".
 *  - HostFacingEdgesOfAnUnreachableSwitchGoDownWithAReason
 *        dies if pass 2 of reconcileDerivedLiveness skips edges whose far end has dstDpid == 0,
 *        i.e. if the fix is applied only to inter-switch edges -- which is F-16 restored.
 *  - AHostBehindAnUnreachableSwitchIsMarkedDownWithAReason
 *        dies if pass 3 is removed, which is F-14 restored.
 *  - AHostWhoseSwitchIsHealthyStaysUp
 *        dies if `isolatedAttachments == attachments` becomes `> 0`, or if pass 2's `cut` is
 *        made unconditional.
 *  - OneMissedPollDoesNotIsolateAnything
 *        dies if kMissesBeforeIsolating becomes 1, or if the counter is incremented twice per
 *        pass, or if `>=` becomes `>` in a way that shifts the threshold down.
 *  - RecoveryClearsTheReasonWithoutRaisingAnything
 *        dies if the release branch sets isUp = true.
 */
