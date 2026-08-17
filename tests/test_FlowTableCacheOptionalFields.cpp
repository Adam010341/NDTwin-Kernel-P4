/**
 * updateOpenFlowTables must not throw on the fields makeInstallJob treats as optional.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Why this file exists, and why the assertions are about *not throwing*.
 *
 * HttpSession::processFlowBatch builds its jobs with `.value("priority", 0)`,
 * `.value("match", {})` and `.value("actions", [])`, enqueues them, and writes a 200. Only
 * afterwards does it reach this cache update, which read the same three fields with `.at()`.
 * A body missing only `priority` therefore passed validation, was dispatched, reached the
 * switch -- and then threw here, and the outer handler in buildResponse replaced the 200 that
 * had already been written with `400 {"error":"JSON parsing error"}`.
 *
 * Measured live on 2026-08-17 against a ten-switch bmv2 fabric: switch 1's table went from
 * five entries to six while the caller was told its request was rejected. The full account,
 * including why delete and modify were unaffected, is in
 * doc/audit/2026-08-17_install-rejected-but-applied.md.
 *
 * So the property under test is not "the cache holds the right number". It is that the two
 * layers agree on what an absent optional field means. If they ever disagree again, the
 * symptom will not be an exception anyone sees -- it will be a rejection message sitting on
 * top of a switch that was programmed anyway.
 *
 * The defaults asserted here are makeInstallJob's, not this function's: priority 0,
 * match {}, actions []. That direction matters. Deriving them from the code under test would
 * make this a change detector; deriving them from the layer that already enqueued the work
 * makes it a contract.
 */

#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Utils.hpp"

using json = nlohmann::json;

namespace
{

/// TESTBED with an empty smart-plug table and a null classifier: nothing this test calls
/// reaches the network, and the cache is plain member state. Same construction as
/// test_IntentTaskOutcomes.cpp, which is the pattern for driving the real class rather than a
/// double -- these methods are not virtual, so a double would test nothing.
std::shared_ptr<DeviceConfigurationAndPowerManager>
makeCache()
{
    auto graph = std::make_shared<Graph>();
    // dpid 1 has to exist as a SWITCH vertex or getFlowsArrayForDpid refuses to cache anything
    // for it -- deliberately, so an install for an invented dpid cannot invent a switch. Without
    // this the no-throw tests would still pass while proving nothing, because the function would
    // return before reaching the field reads under test.
    const auto v = boost::add_vertex(*graph);
    (*graph)[v].vertexType = VertexType::SWITCH;
    (*graph)[v].dpid = 1;
    (*graph)[v].ip.push_back(utils::ipStringToUint32("192.168.123.11"));

    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(graph, mutex, bus, utils::MININET);
    return std::make_shared<DeviceConfigurationAndPowerManager>(monitor, utils::TESTBED,
                                                                "localhost", nullptr);
}

json
installBatch(const json& entry)
{
    return json{{"install_flow_entries", json::array({entry})},
                {"modify_flow_entries", json::array()},
                {"delete_flow_entries", json::array()}};
}

/// The entry the Web-GUI sends when its priority field parses to zero: everything else present.
json
entryWithoutPriority()
{
    return json{{"dpid", 1},
                {"match", {{"eth_type", 2048}, {"ipv4_dst", "10.44.44.44"}}},
                {"actions", json::array({{{"type", "OUTPUT"}, {"port", 1}}})}};
}

const json*
findFlowFor(const json& tables, uint64_t dpid, const std::string& dst)
{
    for (const auto& sw : tables)
    {
        if (sw.value("dpid", 0ULL) != dpid)
        {
            continue;
        }
        for (const auto& [_, flows] : sw.at("flows").items())
        {
            for (const auto& f : flows)
            {
                if (f.value("match", json::object()).value("ipv4_dst", "") == dst)
                {
                    return &f;
                }
            }
        }
    }
    return nullptr;
}

TEST(FlowTableCacheOptionalFields, AnInstallWithoutPriorityDoesNotThrow)
{
    auto cache = makeCache();
    // CATCHES the defect exactly: with .at("priority") this throws json::out_of_range, which
    // at runtime lands after the switch has already been programmed.
    EXPECT_NO_THROW(cache->updateOpenFlowTables(installBatch(entryWithoutPriority())));
}

TEST(FlowTableCacheOptionalFields, AnInstallWithoutPriorityIsCachedAtMakeInstallJobsDefault)
{
    auto cache = makeCache();
    ASSERT_NO_THROW(cache->updateOpenFlowTables(installBatch(entryWithoutPriority())));

    const json tables = cache->getOpenFlowTables();
    const json* flow = findFlowFor(tables, 1, "10.44.44.44");
    ASSERT_NE(flow, nullptr) << "the entry never reached the cache";
    // 0 is makeInstallJob's default, which is what the switch was actually programmed with.
    // Any other value here means the cache is describing a rule the switch does not have.
    EXPECT_EQ(flow->value("priority", -1), 0);
}

TEST(FlowTableCacheOptionalFields, AnInstallWithoutActionsDoesNotThrowEither)
{
    auto cache = makeCache();
    json e = entryWithoutPriority();
    e.erase("actions");
    // The write fails honestly at the proxy for this body, but that is the proxy's decision to
    // make. This layer must not turn it into a rejection after the fact.
    EXPECT_NO_THROW(cache->updateOpenFlowTables(installBatch(e)));
}

TEST(FlowTableCacheOptionalFields, AModifyWithoutPriorityDoesNotThrow)
{
    auto cache = makeCache();
    ASSERT_NO_THROW(cache->updateOpenFlowTables(installBatch(entryWithoutPriority())));

    json mods{{"install_flow_entries", json::array()},
              {"modify_flow_entries", json::array({entryWithoutPriority()})},
              {"delete_flow_entries", json::array()}};
    // The modify branch had the same three .at() calls. It is reachable the same way.
    EXPECT_NO_THROW(cache->updateOpenFlowTables(mods));
}

// The install branch never calls extractKey -- only modify (via the two calls that compare an
// incoming entry against each cached one) and delete do. The first version of this test used an
// install batch and a surviving mutant said so: removing extractKey's match guard failed nothing.
// makeModifyJob and makeDeleteJob both read match with .value(..., object()), so a modify or
// delete without one is enqueued exactly like the priority case and then throws here.
TEST(FlowTableCacheOptionalFields, AModifyWithoutAMatchDoesNotThrow)
{
    auto cache = makeCache();
    ASSERT_NO_THROW(cache->updateOpenFlowTables(installBatch(entryWithoutPriority())));

    json e{{"dpid", 1}, {"actions", json::array({{{"type", "OUTPUT"}, {"port", 2}}})}};
    json mods{{"install_flow_entries", json::array()},
              {"modify_flow_entries", json::array({e})},
              {"delete_flow_entries", json::array()}};
    EXPECT_NO_THROW(cache->updateOpenFlowTables(mods));
}

TEST(FlowTableCacheOptionalFields, ADeleteWithoutAMatchDoesNotThrow)
{
    auto cache = makeCache();
    ASSERT_NO_THROW(cache->updateOpenFlowTables(installBatch(entryWithoutPriority())));

    json dels{{"install_flow_entries", json::array()},
              {"modify_flow_entries", json::array()},
              {"delete_flow_entries", json::array({json{{"dpid", 1}}})}};
    EXPECT_NO_THROW(cache->updateOpenFlowTables(dels));
}

} // namespace
