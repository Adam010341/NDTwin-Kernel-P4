/**
 * An operator's DisableSwitch must survive the topology poll.
 *
 * [Co-developed with claude code -- Adam]
 *
 * The defect these pin: `disableSwitchAndEdges` cleared only `isEnabled`, and `updateSwitches` /
 * `updateLinks` set `isEnabled = true` unconditionally for everything the control plane reports.
 * The poll runs every 5 s for the process's first 90 s and every 30 s after that
 * (TopologyAndFlowMonitor.cpp:1793-1795), so the operator's instruction was undone within one
 * interval, silently, while `/ndt/get_graph_data` went on reporting the switch as enabled.
 *
 * Expected behaviour is derived from:
 *   1. doc/audit/2026-08-10_tfm-spec-unknown-adjudication.md (SU-3 and the Option 1' adjudication)
 *   2. include/common_types/GraphTypes.hpp (the three flags and what owns each)
 *   3. LLMAgent.cpp:216-217, which is where the kernel states the semantics in its own words:
 *      "(administratively <isEnabled>, powered <isUp>)"
 *
 * The last test is the one that matters most and is easy to overlook: forbidding discovery from
 * writing `isEnabled` was the *rejected* design, because the loader starts everything disabled and
 * discovery is the only thing that ever enables it. `DiscoveryStillEnablesEverythingElse` fails if
 * anyone implements that version later.
 */

#include <filesystem>
#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Exposes the protected loader and the protected discovery writers.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void load(const std::string& path) { loadStaticTopologyFromFile(path); }

    /// One control-plane poll, as the kernel would apply it.
    void pollSwitches(const std::string& json) { updateSwitches(json); }
    void pollLinks(const std::string& json) { updateLinks(json); }
};

struct Fixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, utils::TESTBED};

    /// Loads the 10-switch Mininet topology; fails loudly rather than leaving an empty graph,
    /// which would make every per-vertex assertion below vacuously true.
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
                ASSERT_GT(boost::num_vertices(*graph), 0u) << "loaded topology is empty";
                return;
            }
        }
        FAIL() << "could not find StaticNetworkTopologyMininet_10Switches.json relative to "
               << std::filesystem::current_path().string();
    }

    /// Ryu's /v1.0/topology/switches shape: dpid as a hex string.
    static std::string switchReply(uint64_t dpid)
    {
        char hex[32];
        std::snprintf(hex, sizeof(hex), "%016lx", static_cast<unsigned long>(dpid));
        return std::string(R"([{"dpid":")") + hex + R"("}])";
    }

    /// Ryu's /v1.0/topology/links shape, keyed on the source endpoint like updateLinks is.
    static std::string linkReply(uint64_t srcDpid, uint32_t srcPort, uint64_t dstDpid)
    {
        char srcHex[32], dstHex[32], portHex[32];
        std::snprintf(srcHex, sizeof(srcHex), "%016lx", static_cast<unsigned long>(srcDpid));
        std::snprintf(dstHex, sizeof(dstHex), "%016lx", static_cast<unsigned long>(dstDpid));
        std::snprintf(portHex, sizeof(portHex), "%08x", srcPort);
        return std::string(R"([{"src":{"dpid":")") + srcHex + R"(","port_no":")" + portHex +
               R"("},"dst":{"dpid":")" + dstHex + R"(","port_no":"00000001"}}])";
    }
};

constexpr uint64_t kDpid = 1;

} // namespace

TEST(AdministrativeDisableTest, ADisableSurvivesTheTopologyPollThatUsedToUndoIt)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());

    fix.monitor.enableSwitchAndEdges(kDpid); // an operator, or discovery, had it in service
    fix.monitor.disableSwitchAndEdges(kDpid);

    auto vOpt = fix.monitor.findSwitchByDpidNoLock(kDpid);
    ASSERT_TRUE(vOpt.has_value());

    {
        std::shared_lock lock(*fix.mutex);
        ASSERT_FALSE(isUsable((*fix.graph)[*vOpt])) << "pre-condition: the disable must have taken";
    }

    // Exactly what the poll does when the control plane still reports this switch: it is alive and
    // reachable, so discovery says so. That must not amount to overruling the operator.
    fix.monitor.pollSwitches(Fixture::switchReply(kDpid));

    std::shared_lock lock(*fix.mutex);
    const auto& v = (*fix.graph)[*vOpt];
    EXPECT_TRUE(v.isEnabled) << "discovery must still record that the control plane can reach it";
    EXPECT_TRUE(v.adminDisabled) << "the poll overwrote the operator's intent";
    EXPECT_FALSE(isUsable(v)) << "the switch became usable again without anyone asking for it";
}

TEST(AdministrativeDisableTest, TheDisabledSwitchsEdgesAlsoSurviveALinkPoll)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());

    // Find a real switch-to-switch edge leaving dpid 1, so the poll reply names something the
    // static topology actually has -- updateLinks looks the edge up by (src dpid, src port).
    uint32_t srcPort = 0;
    uint64_t dstDpid = 0;
    Graph::edge_descriptor target{};
    bool found = false;
    {
        std::shared_lock lock(*fix.mutex);
        for (auto e : boost::make_iterator_range(boost::edges(*fix.graph)))
        {
            const auto& ep = (*fix.graph)[e];
            const auto& dstV = (*fix.graph)[boost::target(e, *fix.graph)];
            if (ep.srcDpid == kDpid && dstV.vertexType == VertexType::SWITCH)
            {
                srcPort = ep.srcInterface;
                dstDpid = ep.dstDpid;
                target = e;
                found = true;
                break;
            }
        }
    }
    ASSERT_TRUE(found) << "no switch-to-switch edge leaves dpid 1; the assertion would be vacuous";

    fix.monitor.enableSwitchAndEdges(kDpid);
    fix.monitor.disableSwitchAndEdges(kDpid);
    fix.monitor.pollLinks(Fixture::linkReply(kDpid, srcPort, dstDpid));

    std::shared_lock lock(*fix.mutex);
    const auto& ep = (*fix.graph)[target];
    EXPECT_TRUE(ep.isEnabled) << "discovery must still record the link as present";
    EXPECT_TRUE(ep.adminDisabled) << "the link poll overwrote the operator's intent";
    EXPECT_FALSE(isUsable(ep)) << "traffic could be routed over a link taken out of service";
}

TEST(AdministrativeDisableTest, AnAdministrativeEnableClearsIt)
{
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());

    fix.monitor.disableSwitchAndEdges(kDpid);
    fix.monitor.enableSwitchAndEdges(kDpid);

    auto vOpt = fix.monitor.findSwitchByDpidNoLock(kDpid);
    ASSERT_TRUE(vOpt.has_value());

    // Scoped: every setter on the monitor takes a unique_lock on this same non-recursive
    // shared_mutex, so holding a shared_lock across the call deadlocks. (It did, first time.)
    {
        std::shared_lock lock(*fix.mutex);
        const auto& v = (*fix.graph)[*vOpt];
        EXPECT_FALSE(v.adminDisabled) << "an operator must be able to undo their own disable";
        EXPECT_TRUE(v.isEnabled);

        // Not usable yet, and that is correct: `enableSwitchAndEdges` never touches `isUp`, and
        // the loader starts every vertex down. An administrative enable withdraws an objection; it
        // does not assert that the switch is powered -- only liveness can say that. Asserting
        // isUsable() here is what this test did first, and it failed for exactly this reason.
        EXPECT_FALSE(v.isUp) << "pre-condition: liveness has not run in this fixture";
        EXPECT_FALSE(isUsable(v)) << "an admin enable must not stand in for evidence of liveness";
    }

    fix.monitor.setVertexUp(*vOpt);

    std::shared_lock lock(*fix.mutex);
    EXPECT_TRUE(isUsable((*fix.graph)[*vOpt])) << "up, enabled and not disabled is usable";
}

TEST(AdministrativeDisableTest, DiscoveryStillEnablesEverythingElse)
{
    // The rejected design was "let discovery write only isUp". It blanks the graph: the loader
    // starts every vertex and edge at isEnabled = false, and discovery is the only thing that ever
    // sets it true. This fails if anyone implements that version.
    Fixture fix;
    ASSERT_NO_FATAL_FAILURE(fix.load());

    auto vOpt = fix.monitor.findSwitchByDpidNoLock(kDpid);
    ASSERT_TRUE(vOpt.has_value());
    {
        std::shared_lock lock(*fix.mutex);
        ASSERT_FALSE((*fix.graph)[*vOpt].isEnabled)
            << "pre-condition: the loader must start it disabled";
    }

    fix.monitor.pollSwitches(Fixture::switchReply(kDpid));

    std::shared_lock lock(*fix.mutex);
    const auto& v = (*fix.graph)[*vOpt];
    EXPECT_TRUE(v.isEnabled) << "discovery is the only path that enables anything";
    EXPECT_TRUE(isUsable(v)) << "a switch nobody disabled must be usable after discovery sees it";
}

TEST(AdministrativeDisableTest, IsUsableNeedsAllThreeFlags)
{
    VertexProperties v;
    v.isUp = true;
    v.isEnabled = true;
    v.adminDisabled = false;
    EXPECT_TRUE(isUsable(v));

    v.isUp = false;
    EXPECT_FALSE(isUsable(v)) << "unpowered";
    v.isUp = true;

    v.isEnabled = false;
    EXPECT_FALSE(isUsable(v)) << "control plane cannot drive it";
    v.isEnabled = true;

    v.adminDisabled = true;
    EXPECT_FALSE(isUsable(v)) << "administratively out of service";

    EdgeProperties e;
    e.isUp = true;
    e.isEnabled = true;
    e.adminDisabled = false;
    EXPECT_TRUE(isUsable(e));
    e.adminDisabled = true;
    EXPECT_FALSE(isUsable(e)) << "the edge overload must apply the same rule";
}

TEST(AdministrativeDisableTest, TheEmittedIsEnabledFoldsInTheAdministrativeDisable)
{
    // /ndt/get_graph_data serialises nodes with this to_json (HttpSession pushes the vertex
    // directly). Four downstream apps read `is_enabled` and treat it as "usable" -- the
    // Energy-Saving simulator's own walk is `if (!isUp || !isEnabled) continue;` -- so folding is
    // what makes an operator's disable visible to them with no change on their side.
    VertexProperties v;
    v.vertexType = VertexType::SWITCH;
    v.dpid = kDpid;
    v.isUp = true;
    v.isEnabled = true;
    v.adminDisabled = true;

    const nlohmann::json j = v;
    EXPECT_FALSE(j.at("is_enabled").get<bool>())
        << "a disabled switch must not be reported as enabled to the apps";
    EXPECT_TRUE(j.at("admin_disabled").get<bool>())
        << "the raw flag is still emitted so a consumer can tell the two causes apart";

    v.adminDisabled = false;
    const nlohmann::json ok = v;
    EXPECT_TRUE(ok.at("is_enabled").get<bool>()) << "folding must not change the undisabled case";
}
