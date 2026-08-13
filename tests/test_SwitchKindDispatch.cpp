// [Co-developed with claude code -- Adam]
//
// Tests for the typed switch-kind dispatch introduced in Phase 1 of
// doc/2026-07-27_p4_bmv2_support_plan.md.
//
// Before this, choosing between the OpenFlow and P4 strategies compared
// VertexProperties::brandName against the literal "BMv2" in three separate places, and an
// unknown dpid silently fell back to the OVS strategy with no log line -- so a mistyped
// dpid, a switch missing from the topology file, or a topology spelling it "bmv2" all sent
// P4 rules to Ryu, where they vanish. None of it was covered by a test.

#include <gtest/gtest.h>

#include "../setting/AppConfig.hpp"
#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <string>

namespace
{

// --- topology fixture helpers ------------------------------------------------------

/// Builds one switch node. brandName and switchKind are separately controllable so the
/// back-compat fallback and the explicit override can both be exercised.
std::string
switchNode(uint64_t dpid,
           const std::string& brandName,
           const std::string& explicitKind = "")
{
    std::string kindField;
    if (!explicitKind.empty())
    {
        kindField = ",\n      \"switch_kind\": \"" + explicitKind + "\"";
    }
    return R"({
      "vertex_type": 0,
      "mac": 0,
      "ip": ["192.168.123.)" + std::to_string(10 + dpid) + R"("],
      "dpid": )" + std::to_string(dpid) + R"(,
      "device_name": "s)" + std::to_string(dpid) + R"(",
      "nickname": "",
      "brand_name": ")" + brandName + R"(",
      "bridge_name": "s)" + std::to_string(dpid) + R"(",
      "device_layer": 1,
      "ecmp_groups": [])" + kindField + R"(
    })";
}

/// Writes a topology JSON containing just the given nodes and no edges.
class TempTopology
{
  public:
    explicit TempTopology(const std::string& nodesJson)
    {
        m_path = std::filesystem::temp_directory_path() /
                 ("ndt_topo_test_" + std::to_string(++s_counter) + ".json");
        std::ofstream ofs(m_path);
        ofs << "{\n  \"nodes\": [\n" << nodesJson << "\n  ],\n  \"edges\": []\n}\n";
    }

    ~TempTopology()
    {
        std::error_code ec;
        std::filesystem::remove(m_path, ec);
    }

    TempTopology(const TempTopology&) = delete;
    TempTopology& operator=(const TempTopology&) = delete;

    std::string path() const { return m_path.string(); }

  private:
    std::filesystem::path m_path;
    static int s_counter;
};

int TempTopology::s_counter = 0;

/// Exposes the protected loader so a test can supply its own topology without the Ryu
/// REST fetches that pollControlPlaneTopology performs.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    TestableMonitor(std::shared_ptr<Graph> g,
                    std::shared_ptr<std::shared_mutex> m,
                    std::shared_ptr<EventBus> bus,
                    int mode)
        : TopologyAndFlowMonitor(std::move(g), std::move(m), std::move(bus), mode)
    {
    }

    using TopologyAndFlowMonitor::loadStaticTopologyFromFile;
};

/// Exposes the dispatch under test.
class TestableRoutingManager : public FlowRoutingManager
{
  public:
    TestableRoutingManager(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                           std::shared_ptr<EventBus> bus)
        // The collector is stored but never read by FlowRoutingManager, so a null one is
        // safe here and keeps the fixture from dragging in the sFlow machinery.
        : FlowRoutingManager(std::move(monitor), nullptr, std::move(bus))
    {
    }

    using FlowRoutingManager::getStrategyForDpid;
    using FlowRoutingManager::ovsStrategy;
    using FlowRoutingManager::p4Strategy;
};

/// Loads a topology and hands back the monitor. MININET mode, since that is where the
/// bridge_name field is required and where both data planes are selectable.
std::shared_ptr<TestableMonitor>
loadTopology(const std::string& nodesJson, const TempTopology*& outFile)
{
    auto* file = new TempTopology(nodesJson);
    outFile = file;
    auto monitor = std::make_shared<TestableMonitor>(std::make_shared<Graph>(),
                                                     std::make_shared<std::shared_mutex>(),
                                                     std::make_shared<EventBus>(),
                                                     utils::DeploymentMode::MININET);
    monitor->loadStaticTopologyFromFile(file->path());
    return monitor;
}

class SwitchKindFixture : public ::testing::Test
{
  protected:
    /**
     * The code under test logs, and Logger::instance() is a null shared_ptr until
     * Logger::init runs -- so logging without it segfaults.
     *
     * This must be done here rather than relying on another suite: without it these tests
     * pass when the whole binary runs (the routing-strategy suites happen to init the
     * logger first) but crash when run alone or under ctest, which gives every test its
     * own process. That is precisely the cross-test interference the double run in
     * tools/test_workflow/l1_unit_tests.sh exists to catch, and it caught this.
     *
     * Logger::init is idempotent, so several suites calling it is fine.
     */
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off; // keep expected warnings out of the test output
        Logger::init(cfg);
    }

    void TearDown() override
    {
        delete m_file;
        m_file = nullptr;
    }

    std::shared_ptr<TestableMonitor> load(const std::string& nodesJson)
    {
        const TempTopology* f = nullptr;
        auto m = loadTopology(nodesJson, f);
        m_file = f;
        return m;
    }

    const TempTopology* m_file = nullptr;
};

} // namespace

// =====================================================================================
// The pure mapping helpers
// =====================================================================================

TEST(SwitchKindMappingTest, MapsKnownBrandNames)
{
    EXPECT_EQ(switchKindFromBrandName("BMv2"), SwitchKind::BMV2);
    EXPECT_EQ(switchKindFromBrandName("OVS"), SwitchKind::OVS);
}

TEST(SwitchKindMappingTest, UnknownBrandNameIsHardware)
{
    // Physical switches carry vendor names; anything unrecognised keeps the pre-existing
    // behaviour of falling through to the SNMP/SSH testbed paths.
    EXPECT_EQ(switchKindFromBrandName("HPE5520"), SwitchKind::HARDWARE);
    EXPECT_EQ(switchKindFromBrandName(""), SwitchKind::HARDWARE);
}

TEST(SwitchKindMappingTest, BrandNameMappingIsCaseSensitiveByDesign)
{
    // Documents that brand_name is matched exactly. This is precisely why the explicit
    // switch_kind key exists and is parsed case-insensitively: a topology that wrote
    // "bmv2" used to be treated as an OpenFlow switch, silently.
    EXPECT_EQ(switchKindFromBrandName("bmv2"), SwitchKind::HARDWARE);
    EXPECT_EQ(switchKindFromString("bmv2"), SwitchKind::BMV2);
}

TEST(SwitchKindMappingTest, ExplicitKindStringIsCaseInsensitiveAndAcceptsP4Alias)
{
    EXPECT_EQ(switchKindFromString("bmv2"), SwitchKind::BMV2);
    EXPECT_EQ(switchKindFromString("BMv2"), SwitchKind::BMV2);
    EXPECT_EQ(switchKindFromString("P4"), SwitchKind::BMV2);
    EXPECT_EQ(switchKindFromString("ovs"), SwitchKind::OVS);
    EXPECT_EQ(switchKindFromString("OVS"), SwitchKind::OVS);
    EXPECT_EQ(switchKindFromString("hardware"), SwitchKind::HARDWARE);
}

TEST(SwitchKindMappingTest, GarbageKindThrowsRatherThanDefaulting)
{
    // Failing at load beats misrouting rules at runtime.
    EXPECT_THROW(switchKindFromString("ovs_typo"), std::invalid_argument);
    EXPECT_THROW(switchKindFromString(""), std::invalid_argument);
}

TEST(SwitchKindMappingTest, ToStringCoversEveryKind)
{
    EXPECT_STREQ(switchKindToString(SwitchKind::OVS), "ovs");
    EXPECT_STREQ(switchKindToString(SwitchKind::BMV2), "bmv2");
    EXPECT_STREQ(switchKindToString(SwitchKind::HARDWARE), "hardware");
}

// =====================================================================================
// Topology parsing
// =====================================================================================

TEST_F(SwitchKindFixture, DerivesKindFromBrandNameWhenSwitchKindAbsent)
{
    // Back-compat: neither shipped topology file has a switch_kind key.
    auto monitor = load(switchNode(1, "BMv2") + ",\n" + switchNode(2, "BMv2"));

    ASSERT_TRUE(monitor->getSwitchKind(1).has_value());
    EXPECT_EQ(*monitor->getSwitchKind(1), SwitchKind::BMV2);
    EXPECT_EQ(*monitor->getSwitchKind(2), SwitchKind::BMV2);
}

TEST_F(SwitchKindFixture, DerivesOvsFromBrandName)
{
    auto monitor = load(switchNode(1, "OVS"));
    ASSERT_TRUE(monitor->getSwitchKind(1).has_value());
    EXPECT_EQ(*monitor->getSwitchKind(1), SwitchKind::OVS);
}

TEST_F(SwitchKindFixture, ExplicitSwitchKindOverridesBrandName)
{
    // A topology can be migrated to switch_kind without touching brand_name, which the
    // Web GUI still displays.
    auto monitor = load(switchNode(1, "OVS", "bmv2"));
    ASSERT_TRUE(monitor->getSwitchKind(1).has_value());
    EXPECT_EQ(*monitor->getSwitchKind(1), SwitchKind::BMV2);
}

TEST_F(SwitchKindFixture, UnknownDpidHasNoKind)
{
    auto monitor = load(switchNode(1, "BMv2"));
    EXPECT_FALSE(monitor->getSwitchKind(999).has_value());
}

TEST_F(SwitchKindFixture, GroupsSwitchesByKind)
{
    auto monitor = load(switchNode(1, "BMv2") + ",\n" + switchNode(2, "OVS") + ",\n" +
                        switchNode(3, "BMv2"));
    const auto groups = monitor->getSwitchKindGroups();

    ASSERT_EQ(groups.size(), 2u);
    ASSERT_EQ(groups.at(SwitchKind::BMV2).size(), 2u);
    EXPECT_EQ(groups.at(SwitchKind::BMV2)[0], 1u);
    EXPECT_EQ(groups.at(SwitchKind::BMV2)[1], 3u);
    ASSERT_EQ(groups.at(SwitchKind::OVS).size(), 1u);
    EXPECT_EQ(groups.at(SwitchKind::OVS)[0], 2u);
}

// =====================================================================================
// Homogeneity validation
// =====================================================================================

TEST_F(SwitchKindFixture, HomogeneousTopologyValidates)
{
    auto monitor = load(switchNode(1, "BMv2") + ",\n" + switchNode(2, "BMv2"));
    EXPECT_TRUE(monitor->validateDataPlaneHomogeneity(/*allowMixed=*/false));
}

TEST_F(SwitchKindFixture, MixedTopologyIsRejectedByDefault)
{
    auto monitor = load(switchNode(1, "BMv2") + ",\n" + switchNode(2, "OVS"));
    EXPECT_FALSE(monitor->validateDataPlaneHomogeneity(/*allowMixed=*/false));
}

TEST_F(SwitchKindFixture, MixedTopologyIsAllowedWhenOptedIn)
{
    // The single switch that unlocks mixed fabrics later: the dispatch is already
    // per-DPID, so enabling them means relaxing this check, not redesigning anything.
    auto monitor = load(switchNode(1, "BMv2") + ",\n" + switchNode(2, "OVS"));
    EXPECT_TRUE(monitor->validateDataPlaneHomogeneity(/*allowMixed=*/true));
}

TEST_F(SwitchKindFixture, EmptyTopologyFailsValidation)
{
    // A graph with no switches cannot control anything, so it is never acceptable.
    auto monitor = load("");
    EXPECT_FALSE(monitor->validateDataPlaneHomogeneity(/*allowMixed=*/true));
}

// =====================================================================================
// activeTopologyPath -- which file a run reads AND writes
// =====================================================================================

namespace
{

/// Sets NDTWIN_TOPO_FILE for the duration of a test and restores it afterwards, so these
/// tests cannot leak state into the others (or into whatever ran before them).
class ScopedTopoEnv
{
  public:
    explicit ScopedTopoEnv(const char* value)
    {
        if (const char* existing = std::getenv("NDTWIN_TOPO_FILE"))
        {
            m_had = true;
            m_previous = existing;
        }
        if (value)
        {
            setenv("NDTWIN_TOPO_FILE", value, 1);
        }
        else
        {
            unsetenv("NDTWIN_TOPO_FILE");
        }
    }

    ~ScopedTopoEnv()
    {
        if (m_had)
        {
            setenv("NDTWIN_TOPO_FILE", m_previous.c_str(), 1);
        }
        else
        {
            unsetenv("NDTWIN_TOPO_FILE");
        }
    }

    ScopedTopoEnv(const ScopedTopoEnv&) = delete;
    ScopedTopoEnv& operator=(const ScopedTopoEnv&) = delete;

  private:
    bool m_had = false;
    std::string m_previous;
};

std::shared_ptr<TestableMonitor>
makeMonitor(int mode)
{
    return std::make_shared<TestableMonitor>(std::make_shared<Graph>(),
                                             std::make_shared<std::shared_mutex>(),
                                             std::make_shared<EventBus>(),
                                             mode);
}

} // namespace

TEST_F(SwitchKindFixture, TopologyOverrideAppliesInMininetMode)
{
    ScopedTopoEnv env("/tmp/ndt_override_mininet.json");
    auto monitor = makeMonitor(utils::DeploymentMode::MININET);
    EXPECT_EQ(monitor->activeTopologyPath(), "/tmp/ndt_override_mininet.json");
}

TEST_F(SwitchKindFixture, TopologyOverrideAlsoAppliesInTestbedMode)
{
    // Regression: the mode check used to come first, so --mode testbed --topology X
    // silently loaded the default file. Since the rename paths write to whatever this
    // returns, that also meant edits landed in the wrong topology.
    ScopedTopoEnv env("/tmp/ndt_override_testbed.json");
    auto monitor = makeMonitor(utils::DeploymentMode::TESTBED);
    EXPECT_EQ(monitor->activeTopologyPath(), "/tmp/ndt_override_testbed.json");
}

TEST_F(SwitchKindFixture, EmptyOverrideCountsAsUnset)
{
    // getenv returns a valid pointer to "" for `NDTWIN_TOPO_FILE=`. Returning that would
    // make the rename paths write a stray ".tmp" into the working directory.
    ScopedTopoEnv env("");
    auto monitor = makeMonitor(utils::DeploymentMode::MININET);
    EXPECT_EQ(monitor->activeTopologyPath(), AppConfig::TOPOLOGY_FILE_MININET);
}

TEST_F(SwitchKindFixture, FallsBackToModeDefaultWithoutOverride)
{
    ScopedTopoEnv env(nullptr); // ensure unset

    auto mininet = makeMonitor(utils::DeploymentMode::MININET);
    EXPECT_EQ(mininet->activeTopologyPath(), AppConfig::TOPOLOGY_FILE_MININET);

    auto testbed = makeMonitor(utils::DeploymentMode::TESTBED);
    EXPECT_EQ(testbed->activeTopologyPath(), AppConfig::TOPOLOGY_FILE);

    EXPECT_NE(mininet->activeTopologyPath(), testbed->activeTopologyPath());
}

// =====================================================================================
// The dispatch itself -- the point of the strategy pattern, previously untested
// =====================================================================================

TEST_F(SwitchKindFixture, Bmv2DpidSelectsTheP4Strategy)
{
    auto monitor = load(switchNode(1, "BMv2"));
    auto bus = std::make_shared<EventBus>();
    TestableRoutingManager mgr(monitor, bus);

    EXPECT_EQ(mgr.getStrategyForDpid(1), mgr.p4Strategy());
}

TEST_F(SwitchKindFixture, OvsDpidSelectsTheOpenFlowStrategy)
{
    auto monitor = load(switchNode(1, "OVS"));
    auto bus = std::make_shared<EventBus>();
    TestableRoutingManager mgr(monitor, bus);

    EXPECT_EQ(mgr.getStrategyForDpid(1), mgr.ovsStrategy());
}

TEST_F(SwitchKindFixture, HardwareDpidSelectsTheOpenFlowStrategy)
{
    // Physical OpenFlow switches share the Ryu-facing strategy.
    auto monitor = load(switchNode(1, "HPE5520"));
    auto bus = std::make_shared<EventBus>();
    TestableRoutingManager mgr(monitor, bus);

    EXPECT_EQ(mgr.getStrategyForDpid(1), mgr.ovsStrategy());
}

TEST_F(SwitchKindFixture, UnknownDpidReturnsNullptrRatherThanFallingBackToOvs)
{
    // The regression this whole change exists to prevent. The previous implementation
    // returned the OVS strategy here, so rules for a dpid that was not in the topology
    // were POSTed to Ryu and silently discarded.
    auto monitor = load(switchNode(1, "BMv2"));
    auto bus = std::make_shared<EventBus>();
    TestableRoutingManager mgr(monitor, bus);

    EXPECT_EQ(mgr.getStrategyForDpid(999), nullptr);
    EXPECT_NE(mgr.getStrategyForDpid(999), mgr.ovsStrategy());
}

TEST_F(SwitchKindFixture, MixedTopologyDispatchesPerDpid)
{
    // Proves the mechanism is per-DPID, so allowing mixed fabrics is a policy change
    // rather than a redesign.
    auto monitor = load(switchNode(1, "BMv2") + ",\n" + switchNode(2, "OVS"));
    auto bus = std::make_shared<EventBus>();
    TestableRoutingManager mgr(monitor, bus);

    EXPECT_EQ(mgr.getStrategyForDpid(1), mgr.p4Strategy());
    EXPECT_EQ(mgr.getStrategyForDpid(2), mgr.ovsStrategy());
    EXPECT_NE(mgr.p4Strategy(), mgr.ovsStrategy());
}

// --- A switch with no management address is rejected at load.
//
// Ten places call `ip.front()` on a switch's address list with no check, including
// findSwitchByIp(), which does it for *every* switch vertex while searching -- so one switch with
// `"ip": []` is undefined behaviour that takes out address lookup for the whole graph. `at("ip")`
// throws on a missing key but happily accepts an empty array, so only the file has to be wrong.
// Found by a review of 0e84234, which pointed at one of the ten call sites; the load-time check
// is what makes the invariant all ten already assume actually true.

namespace
{

/// A switch node with a caller-supplied "ip" field, which switchNode() always populates.
std::string
switchNodeWithIpField(uint64_t dpid, const std::string& ipArrayJson)
{
    return R"({
      "vertex_type": 0,
      "mac": 0,
      "ip": )" + ipArrayJson + R"(,
      "dpid": )" + std::to_string(dpid) + R"(,
      "device_name": "s)" + std::to_string(dpid) + R"(",
      "nickname": "core-)" + std::to_string(dpid) + R"(",
      "brand_name": "OVS",
      "bridge_name": "s)" + std::to_string(dpid) + R"(",
      "device_layer": 1,
      "ecmp_groups": []
    })";
}

/// The loader logs, and Logger::instance() is a null shared_ptr until Logger::init runs, so these
/// tests segfault without it -- which is exactly what happened when they were plain TESTs: they
/// crashed run alone and under ctest, while passing in a full-binary run where another suite had
/// already initialised the logger. The same trap SwitchKindFixture above documents.
class TopologyIpValidationTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off; // the rejection path logs; keep it out of test output
        Logger::init(cfg);
    }

    static std::shared_ptr<TestableMonitor> freshMonitor()
    {
        return std::make_shared<TestableMonitor>(std::make_shared<Graph>(),
                                                 std::make_shared<std::shared_mutex>(),
                                                 std::make_shared<EventBus>(),
                                                 utils::DeploymentMode::MININET);
    }
};

} // namespace

TEST_F(TopologyIpValidationTest, ASwitchWithAnEmptyIpArrayIsRejectedAtLoad)
{
    TempTopology file(switchNodeWithIpField(7, "[]"));
    auto monitor = freshMonitor();
    try
    {
        monitor->loadStaticTopologyFromFile(file.path());
        FAIL() << "an empty ip array must not load: findSwitchByIp would read ip.front()";
    }
    catch (const std::exception& err)
    {
        // The dpid has to be in the message, or the operator cannot find the offending node in a
        // 130-node file.
        EXPECT_NE(std::string(err.what()).find("dpid 7"), std::string::npos) << err.what();
    }
}

TEST_F(TopologyIpValidationTest, ASwitchWithAnAddressStillLoads)
{
    // The check must not reject the normal case.
    TempTopology file(switchNodeWithIpField(7, R"(["192.168.123.17"])"));
    auto monitor = freshMonitor();
    EXPECT_NO_THROW(monitor->loadStaticTopologyFromFile(file.path()));
}

TEST_F(TopologyIpValidationTest, AHostWithNoAddressIsStillAllowed)
{
    // The invariant belongs to switches only. Hosts are discovered by Ryu and legitimately have
    // no address until then -- rejecting them would refuse every topology that lists hosts before
    // discovery, which is all of them.
    const std::string host = R"({
      "vertex_type": 1,
      "mac": 0,
      "ip": [],
      "dpid": 0,
      "device_name": "h1",
      "nickname": "",
      "brand_name": "",
      "device_layer": 0,
      "ecmp_groups": []
    })";
    TempTopology file(switchNodeWithIpField(1, R"(["192.168.123.11"])") + ",\n" + host);
    auto monitor = freshMonitor();
    EXPECT_NO_THROW(monitor->loadStaticTopologyFromFile(file.path()));
}
