/**
 * Tests for the smart-plug fields /ndt/get_static_topology_json serves.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Both branches of the node loop used to push a constant
 * `{"smart_plug_ip": "172.25.166.135", "smart_plug_outlet": 3}` for *every* switch. Per
 * setting/StaticNetworkTopology_ipAlias4_10Switches_all_1g_cable.json that pair is s2's, so a
 * consumer trusting this endpoint on real hardware would cycle one wrong outlet for all ten
 * switches. The topology file has always carried genuine per-switch assignments and the loader
 * was reading straight past them.
 *
 * The kernel's own power path never used these -- it reads switchSmartPlugTable, which
 * DeviceConfigurationAndPowerManager builds from the same file -- so the endpoint was serving
 * fiction with no consumer. That is why it survived: nothing contradicted it.
 *
 * The assertions come from the topology file, not from the endpoint's implementation. The three
 * switches chosen make a constant impossible to fake in either field: s1 and s2 share a PDU on
 * different outlets, and s3 sits on a different PDU at the same outlet number as s2. Echoing
 * only the IP, only the outlet, or either as a constant fails at least one of them.
 */

#include <filesystem>
#include <memory>
#include <set>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

using json = nlohmann::json;

namespace
{

/// Exposes the protected loader, as the sibling topology suites do.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;
    void load(const std::string& path)
    {
        loadStaticTopologyFromFile(path);
    }
};

/// A TESTBED monitor over the hardware topology -- the only mode whose branch emits these
/// fields, and the only file that carries real plug assignments.
struct PlugFixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, utils::TESTBED};

    /// Loads the hardware topology, failing loudly if the file cannot be found: every
    /// assertion below would otherwise be vacuous over an empty node array.
    bool load()
    {
        static const char* kCandidates[] = {
            "setting/StaticNetworkTopology_ipAlias4_10Switches_all_1g_cable.json",
            "../setting/StaticNetworkTopology_ipAlias4_10Switches_all_1g_cable.json",
            "../../setting/StaticNetworkTopology_ipAlias4_10Switches_all_1g_cable.json",
        };
        for (const char* candidate : kCandidates)
        {
            if (std::filesystem::exists(candidate))
            {
                monitor.load(candidate);
                return true;
            }
        }
        ADD_FAILURE() << "could not find the hardware topology relative to "
                      << std::filesystem::current_path().string();
        return false;
    }

    /// The served node for this device name, or a null json.
    json nodeNamed(const json& served, const std::string& deviceName)
    {
        for (const auto& node : served.value("nodes", json::array()))
        {
            if (node.value("device_name", "") == deviceName)
            {
                return node;
            }
        }
        return json{};
    }
};

} // namespace

TEST(SmartPlugFieldsTest, EachSwitchIsServedItsOwnPlugAssignment)
{
    PlugFixture fix;
    ASSERT_TRUE(fix.load());

    const json served = fix.monitor.getStaticTopologyJson();

    const json s1 = fix.nodeNamed(served, "s1");
    const json s2 = fix.nodeNamed(served, "s2");
    const json s3 = fix.nodeNamed(served, "s3");
    ASSERT_FALSE(s1.is_null()) << "s1 missing from the served topology";
    ASSERT_FALSE(s2.is_null());
    ASSERT_FALSE(s3.is_null());

    // Straight from the topology file.
    EXPECT_EQ(s1.value("smart_plug_ip", ""), "172.25.166.135");
    EXPECT_EQ(s1.value("smart_plug_outlet", -1), 5);

    // Same PDU as s1, different outlet: a constant outlet cannot satisfy both.
    EXPECT_EQ(s2.value("smart_plug_ip", ""), "172.25.166.135");
    EXPECT_EQ(s2.value("smart_plug_outlet", -1), 3);

    // Different PDU, same outlet number as s2: a constant IP cannot satisfy both.
    EXPECT_EQ(s3.value("smart_plug_ip", ""), "172.25.166.136");
    EXPECT_EQ(s3.value("smart_plug_outlet", -1), 3);
}

TEST(SmartPlugFieldsTest, TheSwitchesDoNotAllShareOnePlug)
{
    // The shape of the original defect stated directly: every switch carrying the same pair.
    // Kept separate from the values above so a future topology file with different assignments
    // still leaves this claim meaningful.
    PlugFixture fix;
    ASSERT_TRUE(fix.load());

    const json served = fix.monitor.getStaticTopologyJson();

    std::set<std::string> pairs;
    size_t switchesSeen = 0;
    for (const auto& node : served.value("nodes", json::array()))
    {
        if (!node.contains("smart_plug_ip"))
        {
            continue;
        }
        ++switchesSeen;
        pairs.insert(node.value("smart_plug_ip", "") + "#" +
                     std::to_string(node.value("smart_plug_outlet", -1)));
    }

    ASSERT_GT(switchesSeen, 1u) << "fewer than two switches served; the claim would be vacuous";
    EXPECT_GT(pairs.size(), 1u)
        << "every switch was served the same plug assignment -- on real hardware a consumer "
           "would power-cycle one outlet for all of them";
}

TEST(SmartPlugFieldsTest, ASwitchWithNoAssignmentIsServedAnEmptyOneRatherThanSomeoneElses)
{
    // The Mininet topology declares no plugs. Serving a borrowed constant there is how the
    // original defect would have read as "working" under the mode it was tested in.
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, utils::MININET};

    static const char* kCandidates[] = {
        "setting/StaticNetworkTopologyMininet_10Switches.json",
        "../setting/StaticNetworkTopologyMininet_10Switches.json",
        "../../setting/StaticNetworkTopologyMininet_10Switches.json",
    };
    bool loaded = false;
    for (const char* candidate : kCandidates)
    {
        if (std::filesystem::exists(candidate))
        {
            monitor.load(candidate);
            loaded = true;
            break;
        }
    }
    ASSERT_TRUE(loaded) << "could not find the Mininet topology";

    const json served = monitor.getStaticTopologyJson();
    ASSERT_FALSE(served.value("nodes", json::array()).empty());

    for (const auto& node : served.value("nodes", json::array()))
    {
        if (!node.contains("smart_plug_ip"))
        {
            continue;
        }
        EXPECT_NE(node.value("smart_plug_ip", ""), "172.25.166.135")
            << node.value("device_name", "?")
            << " was served a hardware PDU address it has no connection to";
    }
}
