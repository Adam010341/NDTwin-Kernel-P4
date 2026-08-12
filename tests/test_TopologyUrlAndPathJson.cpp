/**
 * Two independent defects, both about a value that looked right and was not.
 *
 * [Co-developed with claude code -- Adam]
 *
 * 1. TopologyAndFlowMonitor's constructor aimed the topology poll at a file-local
 *    `static const std::string RYU_BASE_URL = "http://localhost:8080/v1.0/topology"`, under a
 *    "---Please change to your own RYU base url---" comment, bypassing
 *    AppConfig::RYU_IP_AND_PORT -- which is what the flow-stats poll and the OVS routing strategy
 *    already read. Move Ryu and update AppConfig, and switch/host/link liveness would keep
 *    polling a dead localhost:8080; execCommand returns an empty body and all three update
 *    functions early-return on empty with no log, so the graph just stops tracking the control
 *    plane. Silent by construction.
 *
 * 2. FlowLinkUsageCollector::getPathBetweenHostsJson declares `json` as its return type, but both
 *    error paths returned a JSON *string value* -- one `errorJson.dump()`, one a
 *    `"{\"error\":\"No active or known path found...\"}"` literal -- while the success path
 *    returned an object. The consumer in IntentTranslator does `json path = ...; return
 *    path.dump();`, so errors came back double-encoded as a quoted, escaped string while success
 *    parsed as an object: a client doing parsed["error"] hit a type mismatch exactly and only
 *    when something had gone wrong.
 */

#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "../setting/AppConfig.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

class TopologyApiUrlTest : public ::testing::Test
{
  protected:
    std::shared_ptr<TopologyAndFlowMonitor> makeMonitor(int mode = utils::MININET)
    {
        m_graph = std::make_shared<Graph>();
        return std::make_shared<TopologyAndFlowMonitor>(m_graph,
                                                        std::make_shared<std::shared_mutex>(),
                                                        std::make_shared<EventBus>(),
                                                        mode);
    }

    std::shared_ptr<Graph> m_graph;
};

} // namespace

// --- the Ryu base URL --------------------------------------------------------------------------

TEST_F(TopologyApiUrlTest, TheDefaultPollFollowsAppConfigRatherThanAHardCodedHost)
{
    auto monitor = makeMonitor();
    const auto& urls = monitor->topologyApiUrls();

    for (const auto& url : urls)
    {
        EXPECT_NE(url.find(AppConfig::RYU_IP_AND_PORT), std::string::npos)
            << "the topology poll is aimed at " << url << ", which does not contain the "
            << "configured Ryu address " << AppConfig::RYU_IP_AND_PORT
            << " -- re-pointing Ryu in AppConfig would not move this poll";
    }
}

/**
 * The assertion above would still hold if the constant were re-hard-coded to today's AppConfig
 * value, because they are the same string on this machine. This one does not: it builds the URL
 * the way the production code is now required to and compares, so a literal that happens to match
 * today still fails the moment the two are asked to agree on a *derived* value.
 */
TEST_F(TopologyApiUrlTest, TheDefaultPollIsTheAppConfigAddressWithTheTopologyPathAppended)
{
    auto monitor = makeMonitor();
    const std::string expectedBase = "http://" + AppConfig::RYU_IP_AND_PORT + "/v1.0/topology";

    EXPECT_EQ(monitor->topologyApiUrls()[0], expectedBase + "/switches");
    EXPECT_EQ(monitor->topologyApiUrls()[1], expectedBase + "/hosts");
    EXPECT_EQ(monitor->topologyApiUrls()[2], expectedBase + "/links");
}

/**
 * configureTopologyApiUrls() was added after the constant and must keep working: an empty
 * topology is not all-bmv2, so it must leave the Ryu default alone rather than re-point at a
 * proxy that is not there. This pins that the fix to the default did not disturb the override.
 */
TEST_F(TopologyApiUrlTest, ConfigureLeavesTheRyuDefaultAloneForANonBmv2Topology)
{
    auto monitor = makeMonitor();
    const auto before = monitor->topologyApiUrls();

    monitor->configureTopologyApiUrls();

    EXPECT_EQ(monitor->topologyApiUrls(), before)
        << "an empty or mixed topology must keep polling Ryu; re-pointing it at the P4 proxy "
           "would aim an OVS deployment at a proxy that is not running";
}

TEST_F(TopologyApiUrlTest, SetTopologyApiUrlsOverridesAllThreeEndpoints)
{
    auto monitor = makeMonitor();

    monitor->setTopologyApiUrls("http://10.9.8.7:9999/v1.0/topology");

    EXPECT_EQ(monitor->topologyApiUrls()[0], "http://10.9.8.7:9999/v1.0/topology/switches");
    EXPECT_EQ(monitor->topologyApiUrls()[1], "http://10.9.8.7:9999/v1.0/topology/hosts");
    EXPECT_EQ(monitor->topologyApiUrls()[2], "http://10.9.8.7:9999/v1.0/topology/links");
}

// --- getPathBetweenHostsJson -------------------------------------------------------------------

namespace
{

class PathJsonTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(m_graph,
                                                             std::make_shared<std::shared_mutex>(),
                                                             std::make_shared<EventBus>(),
                                                             utils::MININET);
        m_collector = std::make_shared<sflow::FlowLinkUsageCollector>(m_monitor,
                                                                       nullptr,
                                                                       nullptr,
                                                                       utils::MININET,
                                                                       nullptr);
    }

    void addHost(const std::string& name, const std::string& ip)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::HOST;
        (*m_graph)[v].deviceName = name;
        (*m_graph)[v].ip.push_back(utils::ipStringToUint32(ip));
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::shared_ptr<sflow::FlowLinkUsageCollector> m_collector;
};

} // namespace

TEST_F(PathJsonTest, AMissingHostYieldsAnObjectNotAJsonStringValue)
{
    const json result = m_collector->getPathBetweenHostsJson("h1", "h2");

    ASSERT_TRUE(result.is_object())
        << "the error path returned a " << result.type_name()
        << ", so the caller's .dump() double-encodes it into a quoted string: " << result.dump();
    EXPECT_TRUE(result.contains("error"));
    EXPECT_TRUE(result.contains("missing_hosts"));
}

/**
 * The consumer's exact shape, reproduced. IntentTranslator does
 * `json path = getPathBetweenHostsJson(...); return path.dump();` and the client then parses that
 * string. This is the assertion that failed before the fix.
 */
TEST_F(PathJsonTest, TheIntentTranslatorsRoundTripLeavesAnErrorClientReadable)
{
    const json path = m_collector->getPathBetweenHostsJson("h1", "h2");
    const std::string wire = path.dump();

    const json reparsed = json::parse(wire);

    ASSERT_TRUE(reparsed.is_object())
        << "after the caller's dump(), the client parsed a " << reparsed.type_name()
        << " and cannot reach [\"error\"]: " << wire;
    EXPECT_EQ(reparsed.value("error", ""),
              "One or both hosts could not be found in the topology.");
}

TEST_F(PathJsonTest, TwoKnownHostsWithNoPathAlsoYieldAnObject)
{
    addHost("h1", "10.0.0.1");
    addHost("h2", "10.0.0.2");

    const json result = m_collector->getPathBetweenHostsJson("h1", "h2");

    ASSERT_TRUE(result.is_object()) << "got a " << result.type_name() << ": " << result.dump();
    EXPECT_NE(result.value("error", ""), "")
        << "expected the no-path error, got: " << result.dump();
}

TEST_F(PathJsonTest, TheNoPathErrorSurvivesTheCallersDumpAndReparse)
{
    addHost("h1", "10.0.0.1");
    addHost("h2", "10.0.0.2");

    const json reparsed = json::parse(m_collector->getPathBetweenHostsJson("h1", "h2").dump());

    ASSERT_TRUE(reparsed.is_object());
    EXPECT_NE(reparsed.value("error", "").find("No active or known path"), std::string::npos)
        << reparsed.dump();
}

/**
 * Only one host missing: the object must name which one. Guards against an error path that
 * reports "something went wrong" without saying what, which is what the caller needs most.
 */
TEST_F(PathJsonTest, OnlyTheMissingHostIsNamed)
{
    addHost("h1", "10.0.0.1");

    const json result = m_collector->getPathBetweenHostsJson("h1", "h2");

    ASSERT_TRUE(result.is_object());
    ASSERT_TRUE(result.contains("missing_hosts"));
    ASSERT_EQ(result["missing_hosts"].size(), 1u) << result.dump();
    EXPECT_EQ(result["missing_hosts"][0], "h2");
}
