/**
 * @file test_P4Capabilities.cpp
 * @brief Each bmv2 switch's `capabilities`, from GET /p4/switch_state onto /ndt/get_graph_data.
 *
 * [Co-developed with claude code -- Adam]
 *
 * THE CONTRACT (doc/2026-01-02_ndt_api.md section 3, "`capabilities` -- what a P4 switch may be
 * asked to do"):
 *
 *   - a switch node MAY carry `capabilities`, and when it does the object is the proxy's
 *     per-switch `capabilities` from GET /p4/switch_state, copied verbatim;
 *   - when the kernel cannot read it in P4 mode it does not carry the key, and on OVS it never
 *     does;
 *   - no `capabilities` means every operation is supported. A consumer must never read the
 *     missing key as "unsupported", so the kernel must never manufacture one.
 *
 * "Verbatim" means equal as JSON values: nlohmann re-serialises the object with its keys sorted,
 * so the bytes on the wire need not match the proxy's.
 *
 * THE FIXTURES are the four cases the API doc names, and each one is also what a live proxy served
 * (doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs/):
 *
 *   (1) no `capabilities`    -- OVS, an old kernel, a proxy that does not report
 *   (2) NDTwin pipeline      -- 2026-09-26T175610Z_01_baseline/20_switch_state.json, all 10
 *   (3) foreign, owned       -- 2026-09-24T160256Z_07_roles_basic/30_switch_state_roles.json
 *   (4) foreign, unbound     -- 2026-09-24T160256Z_07_roles_basic/71_switch_state_plain.json
 *
 * Three layers, because each can be wrong while the others are right:
 *
 *   P4Capabilities.*      the two pure functions: reading the proxy's body, writing one node.
 *   P4CapabilitiesPoll.*  the power manager's 1 Hz step, with the proxy replaced: that it asks
 *                         only on an all-bmv2 fabric, records what it was told, and forgets it
 *                         when the next read fails.
 *   P4CapabilitiesWire.*  GET /ndt/get_graph_data itself, through HttpSession::buildResponse.
 *
 * The power manager is never start()ed -- its ping loop runs `sudo ovs-vsctl` -- and the proxy
 * is a virtual override. The monitor IS started and stopped at once, because only start() marks
 * a topology as loaded and the bmv2 verdict refuses to answer before that (D15); that start does
 * launch its poll thread, whose one round curls a control plane that is not there and changes
 * nothing these cases read.
 *
 * NOT COVERED OFFLINE: the mutex around the record. Every case here is single-threaded, so
 * removing either lock (the write in pollP4SwitchState, the read in p4CapabilitiesSnapshot) goes
 * unnoticed; a poll-versus-snapshot race would need a sanitizer run with two threads, which is
 * not attempted because a timing-dependent test would be flaky rather than red. The locks are
 * checked by reading them.
 *
 * The wiring pingWorker -> pollP4SwitchState -> fetchP4SwitchState cannot be reached without
 * start(); tests/shell/test_p4_capabilities_wired.sh checks it statically.
 */

#include <unistd.h> // getpid, for per-process fixture paths

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <string>

#include <boost/graph/adjacency_list.hpp>
#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include <spdlog/sinks/ringbuffer_sink.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/http/HttpSession.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "ndt_core/power_management/P4Capabilities.hpp"
#include "ndt_core/power_management/P4RulesLost.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

/**
 * @brief Drives HttpSession::buildResponse() for GET /ndt/get_graph_data, with a power manager.
 *
 * Global scope to match `friend class HttpSessionP4CapabilitiesTestPeer`; its own class for the
 * ODR reason HttpSession.hpp gives for every peer.
 */
class HttpSessionP4CapabilitiesTestPeer
{
  public:
    HttpSessionP4CapabilitiesTestPeer(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                                      std::shared_ptr<DeviceConfigurationAndPowerManager> manager)
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                  std::move(monitor),
                                                  nullptr,        // EventBus
                                                  utils::MININET, // mode
                                                  nullptr,        // FlowLinkUsageCollector
                                                  nullptr,        // FlowRoutingManager
                                                  std::move(manager),
                                                  nullptr, // ApplicationManager
                                                  nullptr, // SimulationRequestManager
                                                  nullptr, // IntentTranslator
                                                  nullptr, // HistoricalDataManager
                                                  nullptr, // Controller
                                                  nullptr)) // LockManager
    {
    }

    /// The body of GET /ndt/get_graph_data, parsed.
    nlohmann::json getGraphData()
    {
        m_session->m_req = {};
        m_session->m_req.version(11);
        m_session->m_req.method(http::verb::get);
        m_session->m_req.target("/ndt/get_graph_data");
        m_session->m_req.prepare_payload();

        m_response = m_session->buildResponse();
        return nlohmann::json::parse(m_response->body());
    }

  private:
    boost::asio::io_context m_ioc;
    std::shared_ptr<HttpSession> m_session;
    std::shared_ptr<http::response<http::string_body>> m_response;
};

namespace
{

// --- the four documented cases ----------------------------------------------------------------

/// (2) A switch running NDTwin's own pipeline on an all-NDTwin fabric.
const json kNdtwinPipeline = {{"ipv4_route", "ndtwin"},
                              {"five_tuple", true},
                              {"reroute", true},
                              {"link_discovery", "lldp"},
                              {"binding_source", "baseline"}};

/// (3) A foreign pipeline whose package gives its route table to NDTwin (`owner: ndtwin`).
const json kForeignOwned = {{"ipv4_route", "ndtwin"},
                            {"five_tuple", false},
                            {"reroute", false},
                            {"link_discovery", "declared"},
                            {"binding_source", "package"}};

/// (4) A foreign pipeline whose package declares no route role. `binding_source` is a JSON null,
///     and verbatim means it stays one -- it is a value, not a missing key.
const json kForeignUnbound = {{"ipv4_route", "unbound"},
                              {"five_tuple", false},
                              {"reroute", false},
                              {"link_discovery", "declared"},
                              {"binding_source", nullptr}};

/// One switch's entry in the shape the proxy serves it, with `capabilities` among the rest.
json
entryWith(const json& capabilities)
{
    return json{{"probe_ok", true},
                {"probe_age_s", 0.4},
                {"last_lldp_age_s", nullptr},
                {"stream_alive", true},
                {"grpc_addr", "127.0.0.1:50051"},
                {"entries_recorded", 0},
                {"capabilities", capabilities}};
}

/// (1) as a proxy too old to report serves it: the entry, and no `capabilities` key at all.
json
entryWithout()
{
    json e = entryWith(json::object());
    e.erase("capabilities");
    return e;
}

/// A whole GET /p4/switch_state body around the given `switches` map.
json
switchState(const json& switches)
{
    return json{{"status", "success"},
                {"probe_interval_s", 2.0},
                {"control_plane", {{"mode", "ndtwin"}, {"package", nullptr}, {"skipped", json::array()}}},
                {"switches", switches}};
}

/// The four cases on one fabric, keyed as the proxy keys them. dpid 10 is in the set
/// because the proxy writes decimal and "10" is where a hex reading would first go wrong.
/// (The kernel copies; it does not judge whether (2) beside (3) is a fabric that can exist.)
json
fourCaseSwitchState()
{
    return switchState({{"1", entryWithout()},
                        {"2", entryWith(kNdtwinPipeline)},
                        {"3", entryWith(kForeignOwned)},
                        {"10", entryWith(kForeignUnbound)}});
}

VertexProperties
switchVertex(std::uint64_t dpid)
{
    VertexProperties v;
    v.vertexType = VertexType::SWITCH;
    v.dpid = dpid;
    // Not equal to the dpid, so an attach that looked the record up by mac would miss.
    v.mac = 0x020000000000ULL + dpid;
    v.ip = {0x0B7BA8C0u + static_cast<std::uint32_t>(dpid)};
    v.deviceName = "s" + std::to_string(dpid);
    v.nickName = v.deviceName;
    v.brandName = "BMv2";
    v.switchKind = SwitchKind::BMV2;
    v.deviceLayer = 2;
    return v;
}

VertexProperties
hostVertex(std::uint64_t dpid)
{
    VertexProperties v;
    v.vertexType = VertexType::HOST;
    v.dpid = dpid;
    v.mac = 0xAA0000000000ULL + dpid;
    v.ip = {0x0100000Au};
    v.deviceName = "h1";
    v.nickName = "h1";
    return v;
}

/// A record describing switch 3 alone, as fixture (3).
p4caps::CapabilitiesByDpid
onlySwitch3()
{
    p4caps::CapabilitiesByDpid caps;
    caps.emplace(3, kForeignOwned);
    return caps;
}

} // namespace

// === 1. the two pure functions ==================================================================

TEST(P4Capabilities, TheFourFixturesAreCopiedVerbatim)
{
    const p4caps::CapabilitiesByDpid got = p4caps::fromSwitchState(fourCaseSwitchState());

    ASSERT_EQ(got.size(), 3u) << "one entry per switch that carries an object, and no more";
    ASSERT_EQ(got.count(2), 1u);
    ASSERT_EQ(got.count(3), 1u);
    ASSERT_EQ(got.count(10), 1u) << "the key \"10\" names dpid 10";
    EXPECT_EQ(got.at(2), kNdtwinPipeline);
    EXPECT_EQ(got.at(3), kForeignOwned);
    EXPECT_EQ(got.at(10), kForeignUnbound);
    // Named on its own: dropping null-valued keys is the one "tidy-up" that changes the meaning,
    // because the GUI tells "absent" from "present and null" apart.
    ASSERT_TRUE(got.at(10).contains("binding_source"));
    EXPECT_TRUE(got.at(10).at("binding_source").is_null());
}

TEST(P4Capabilities, NoAnswerMeansNoCapabilities)
{
    EXPECT_TRUE(p4caps::fromSwitchState(std::nullopt).empty()) << "proxy not asked or unreadable";
    EXPECT_TRUE(p4caps::fromSwitchState(json{{"status", "success"}}).empty()) << "no `switches`";
    EXPECT_TRUE(p4caps::fromSwitchState(json{{"switches", json::array()}}).empty());
    EXPECT_TRUE(p4caps::fromSwitchState(json::array()).empty());
}

TEST(P4Capabilities, ASwitchTheProxyDoesNotDescribeGetsNoEntry)
{
    // Fixture (1) the three ways a proxy says nothing: no key (older than the first cut), `null`
    // (it has recorded nothing for this dpid -- api_routes.py `caps.get(str(dpid))`), and a value
    // that is not an object. None of them may become an entry: an entry is what puts the key on
    // the node, and a key present with nothing usable in it is what a GUI could read as "none".
    const json body = switchState({{"1", entryWithout()},
                                   {"2", entryWith(nullptr)},
                                   {"3", entryWith("ndtwin")},
                                   {"4", "not an entry"}});
    EXPECT_TRUE(p4caps::fromSwitchState(body).empty())
        << "got an entry for a switch the proxy did not describe";
}

TEST(P4Capabilities, KeysAndValuesTheKernelHasNeverHeardOfPassThrough)
{
    // Verbatim is the contract. The proxy's vocabulary has already grown once since the first cut
    // (`link_discovery: "heartbeat"`, the second cut), and a kernel that rebuilt the object from
    // the keys it knows, or checked the words against a list, would silently drop the next one.
    const json grown = {{"ipv4_route", "ndtwin"},
                        {"five_tuple", false},
                        {"reroute", true},
                        {"link_discovery", "heartbeat"},
                        {"binding_source", "package"},
                        {"l2_route", "unbound"}};
    const auto got = p4caps::fromSwitchState(switchState({{"7", entryWith(grown)}}));
    ASSERT_EQ(got.count(7), 1u);
    EXPECT_EQ(got.at(7), grown);
}

TEST(P4Capabilities, ASwitchWhoseProbeFailedStillCarriesWhatTheProxySaysOfIt)
{
    // `capabilities` is configuration -- which pipeline and binding the switch was started with --
    // not liveness. A switch whose last probe failed is still that switch; whether it is up is
    // the node's `reachable`, decided elsewhere from the same body. Copying only answering
    // switches would make the key blink with every missed probe.
    json down = entryWith(kForeignOwned);
    down["probe_ok"] = false;
    down["probe_detail"] = "UNAVAILABLE: failed to connect";
    const auto got = p4caps::fromSwitchState(switchState({{"4", down}}));
    ASSERT_EQ(got.count(4), 1u) << "a switch with a failed probe lost its capabilities";
    EXPECT_EQ(got.at(4), kForeignOwned);
}

TEST(P4Capabilities, AKeyThatIsNotAPlainDecimalDpidIsSkipped)
{
    const json body = switchState({{"0x2", entryWith(kNdtwinPipeline)},
                                   {"+3", entryWith(kNdtwinPipeline)},
                                   {" 4", entryWith(kNdtwinPipeline)},
                                   {"5x", entryWith(kNdtwinPipeline)},
                                   {"", entryWith(kNdtwinPipeline)},
                                   {"18446744073709551616", entryWith(kNdtwinPipeline)},
                                   {"18446744073709551615", entryWith(kForeignOwned)}});
    const auto got = p4caps::fromSwitchState(body);
    ASSERT_EQ(got.size(), 1u) << "only the largest 64-bit dpid is a dpid here";
    EXPECT_EQ(got.at(18446744073709551615ULL), kForeignOwned);
}

TEST(P4Capabilities, AttachPutsTheObjectOnItsSwitchAndChangesNothingElse)
{
    const VertexProperties v = switchVertex(3);
    const json before = v;
    json node = v;
    p4caps::attachToNode(node, v, onlySwitch3());

    ASSERT_TRUE(node.contains("capabilities"));
    EXPECT_EQ(node.at("capabilities"), kForeignOwned);
    node.erase("capabilities");
    EXPECT_EQ(node, before) << "attaching changed a key that was already there";
}

TEST(P4Capabilities, AttachLeavesAnUndescribedSwitchExactlyAsItWas)
{
    // Fixture (1) on the node: no entry, no key -- not `{}`, not `null`.
    const VertexProperties v = switchVertex(1);
    json node = v;
    p4caps::attachToNode(node, v, onlySwitch3());
    EXPECT_FALSE(node.contains("capabilities")) << node.dump();
    EXPECT_EQ(node, json(v));
}

TEST(P4Capabilities, AttachNeverTouchesAHost)
{
    // A host has no pipeline. Its dpid collides with a described switch here on purpose, so only
    // the vertex type can keep the switch's object off it.
    const VertexProperties h = hostVertex(3);
    json node = h;
    p4caps::attachToNode(node, h, onlySwitch3());
    EXPECT_FALSE(node.contains("capabilities")) << node.dump();
}

// === 2. the 1 Hz step, with the proxy replaced ===================================================

namespace
{

/// The power manager with GET /p4/switch_state answered by the test instead of by curl.
class ProxyStandIn : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::DeviceConfigurationAndPowerManager;
    using DeviceConfigurationAndPowerManager::pollP4SwitchState;

    std::optional<json> answer; ///< What the "proxy" says next; nullopt = could not be read.
    int asked = 0;              ///< How many times the proxy was asked.

  private:
    std::optional<json> fetchP4SwitchState() override
    {
        ++asked;
        return answer;
    }
};

json
switchNodeJson(std::uint64_t dpid, const std::string& brand)
{
    const std::string name = "s" + std::to_string(dpid);
    return json{{"brand_name", brand},
                {"bridge_name", name},
                {"device_layer", 2},
                {"device_name", name},
                {"nickname", name},
                {"dpid", dpid},
                {"ip", json::array({"192.168.123." + std::to_string(10 + dpid)})},
                {"mac", dpid},
                {"smart_plug_ip", ""},
                {"smart_plug_outlet", 0},
                {"vertex_type", 0}};
}

/**
 * A loaded fabric -- four switches, dpids 1, 2, 3 and 10, all of one brand -- and a power manager
 * over it whose proxy is a ProxyStandIn. Loaded the way main.cpp loads it (monitor start()), then
 * the monitor is stopped again so no thread is running while a case reads the graph.
 */
class LoadedFabric : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }

    void load(const std::string& brand)
    {
        m_topoPath = std::string(::testing::TempDir()) + "p4caps_" + brand + "_" +
                     ::testing::UnitTest::GetInstance()->current_test_info()->name() + "_" +
                     std::to_string(static_cast<long>(::getpid())) + ".json";
        const json topology = {{"nodes",
                                {switchNodeJson(1, brand),
                                 switchNodeJson(2, brand),
                                 switchNodeJson(3, brand),
                                 switchNodeJson(10, brand)}},
                               {"edges", json::array()},
                               {"links", json::array()}};
        {
            std::ofstream out(m_topoPath);
            ASSERT_TRUE(out.is_open()) << "cannot write the fixture topology to " << m_topoPath;
            out << topology.dump();
        }
        ::setenv("NDTWIN_TOPO_FILE", m_topoPath.c_str(), 1);

        m_graph = std::make_shared<Graph>();
        m_graphMutex = std::make_shared<std::shared_mutex>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(m_graph,
                                                             m_graphMutex,
                                                             std::make_shared<EventBus>(),
                                                             utils::MININET);
        m_monitor->start();
        m_monitor->stop();
        ASSERT_EQ(boost::num_vertices(*m_graph), 4u) << "the fixture topology did not load";

        m_manager = std::make_shared<ProxyStandIn>(m_monitor, utils::MININET, "127.0.0.1", nullptr);
        // Derived here, as pollP4SwitchState derives it. Without the check that follows, "an OVS
        // fabric never asks" would also pass on a fabric that had simply not loaded -- the D15
        // shape, where an undetermined verdict reads as "not bmv2".
        (void)m_manager->dataPlaneIsBmv2();
        ASSERT_TRUE(m_manager->dataPlaneKindDetermined()) << "the data-plane kind is not known";
    }

    void TearDown() override
    {
        ::unsetenv("NDTWIN_TOPO_FILE");
        if (!m_topoPath.empty())
        {
            std::remove(m_topoPath.c_str());
        }
    }

    std::string m_topoPath;
    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_graphMutex;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::shared_ptr<ProxyStandIn> m_manager;
};

class P4CapabilitiesPoll : public LoadedFabric
{
};

class P4CapabilitiesWire : public LoadedFabric
{
};

} // namespace

TEST_F(P4CapabilitiesPoll, AnAllBmv2FabricRecordsWhatTheProxySaid)
{
    ASSERT_NO_FATAL_FAILURE(load("BMv2"));
    ASSERT_TRUE(m_manager->dataPlaneIsBmv2());
    m_manager->answer = fourCaseSwitchState();

    const std::optional<json> handedOn = m_manager->pollP4SwitchState();

    EXPECT_EQ(m_manager->asked, 1);
    const p4caps::CapabilitiesByDpid expected = {
        {2, kNdtwinPipeline}, {3, kForeignOwned}, {10, kForeignUnbound}};
    EXPECT_EQ(m_manager->p4CapabilitiesSnapshot(), expected);
    // The same answer still reaches the liveness verdicts: one request a tick serves both.
    ASSERT_TRUE(handedOn.has_value());
    EXPECT_EQ(*handedOn, fourCaseSwitchState());
}

TEST_F(P4CapabilitiesPoll, AnOvsFabricNeverAsksTheProxyAndCarriesNothing)
{
    ASSERT_NO_FATAL_FAILURE(load("OVS"));
    ASSERT_FALSE(m_manager->dataPlaneIsBmv2());
    // A proxy that WOULD describe every switch, so staying empty proves it was not asked.
    m_manager->answer = fourCaseSwitchState();

    const std::optional<json> handedOn = m_manager->pollP4SwitchState();

    EXPECT_EQ(m_manager->asked, 0) << "an OVS fabric asked a P4 proxy that is not there";
    EXPECT_TRUE(m_manager->p4CapabilitiesSnapshot().empty());
    EXPECT_FALSE(handedOn.has_value());
}

TEST_F(P4CapabilitiesPoll, AnUnreadableProxyWithdrawsTheLastAnswer)
{
    ASSERT_NO_FATAL_FAILURE(load("BMv2"));
    m_manager->answer = fourCaseSwitchState();
    m_manager->pollP4SwitchState();
    ASSERT_EQ(m_manager->p4CapabilitiesSnapshot().size(), 3u);

    m_manager->answer = std::nullopt; // down, restarting, or answering garbage
    m_manager->pollP4SwitchState();

    EXPECT_EQ(m_manager->asked, 2);
    EXPECT_TRUE(m_manager->p4CapabilitiesSnapshot().empty())
        << "kept an answer from a proxy the kernel can no longer read";
}

TEST_F(P4CapabilitiesPoll, AnAnswerWithNoSwitchesClearsTheRecord)
{
    // A 200 whose body has no `switches` map (a proxy mid-restart, or a different service on the
    // port) describes no switch. It must clear the record exactly as an unreadable answer does,
    // not be skipped as "nothing new" while the previous answer goes on being served.
    ASSERT_NO_FATAL_FAILURE(load("BMv2"));
    m_manager->answer = fourCaseSwitchState();
    m_manager->pollP4SwitchState();
    ASSERT_EQ(m_manager->p4CapabilitiesSnapshot().size(), 3u);

    m_manager->answer = json{{"status", "success"}};
    m_manager->pollP4SwitchState();

    EXPECT_EQ(m_manager->asked, 2);
    EXPECT_TRUE(m_manager->p4CapabilitiesSnapshot().empty())
        << "a body with no switches left the previous answer standing";
}

TEST_F(P4CapabilitiesPoll, EachAnswerReplacesThePreviousOneWhole)
{
    ASSERT_NO_FATAL_FAILURE(load("BMv2"));
    m_manager->answer = fourCaseSwitchState();
    m_manager->pollP4SwitchState();

    // The proxy restarted on another package: switch 2 is now unbound, and 3 and 10 are no longer
    // described at all. What it no longer says must go, not linger from the earlier answer.
    m_manager->answer = switchState({{"2", entryWith(kForeignUnbound)}, {"3", entryWithout()}});
    m_manager->pollP4SwitchState();

    const p4caps::CapabilitiesByDpid expected = {{2, kForeignUnbound}};
    EXPECT_EQ(m_manager->p4CapabilitiesSnapshot(), expected);
}

// === 3. GET /ndt/get_graph_data ====================================================================

TEST_F(P4CapabilitiesWire, EachSwitchNodeCarriesItsOwnCapabilitiesVerbatim)
{
    ASSERT_NO_FATAL_FAILURE(load("BMv2"));
    {
        // A host whose dpid collides with a described switch; see AttachNeverTouchesAHost.
        std::unique_lock lock(*m_graphMutex);
        boost::add_vertex(hostVertex(2), *m_graph);
    }
    m_manager->answer = fourCaseSwitchState();
    m_manager->pollP4SwitchState();

    HttpSessionP4CapabilitiesTestPeer peer{m_monitor, m_manager};
    const json body = peer.getGraphData();
    // The served body, for a consumer's fixture: --gtest_output=xml records it as a property. The
    // Web-GUI's src/utils/p4Capabilities.kernel-graph.json is this value. It asserts nothing.
    RecordProperty("graph_data_body", body.dump());

    std::map<std::uint64_t, json> switches;
    int hosts = 0;
    for (const json& node : body.at("nodes"))
    {
        if (node.at("vertex_type").get<int>() == static_cast<int>(VertexType::HOST))
        {
            ++hosts;
            EXPECT_FALSE(node.contains("capabilities")) << "a host carried capabilities";
            continue;
        }
        switches[node.at("dpid").get<std::uint64_t>()] = node;
    }
    ASSERT_EQ(hosts, 1);
    ASSERT_EQ(switches.size(), 4u);

    EXPECT_FALSE(switches.at(1).contains("capabilities"))
        << "(1): the proxy said nothing about switch 1, so the node must not say anything either";
    ASSERT_TRUE(switches.at(2).contains("capabilities")) << switches.at(2).dump();
    ASSERT_TRUE(switches.at(3).contains("capabilities")) << switches.at(3).dump();
    ASSERT_TRUE(switches.at(10).contains("capabilities")) << switches.at(10).dump();
    EXPECT_EQ(switches.at(2).at("capabilities"), kNdtwinPipeline) << "(2)";
    EXPECT_EQ(switches.at(3).at("capabilities"), kForeignOwned) << "(3)";
    EXPECT_EQ(switches.at(10).at("capabilities"), kForeignUnbound) << "(4)";
}

TEST_F(P4CapabilitiesWire, TheKeyIsAddedAndNothingElseOnTheResponseChanges)
{
    ASSERT_NO_FATAL_FAILURE(load("BMv2"));
    m_manager->answer = fourCaseSwitchState();
    m_manager->pollP4SwitchState();

    // The same graph served twice: by a kernel with no power manager (every build before this
    // one reads no capabilities at all), and by this one.
    const json baseline = HttpSessionP4CapabilitiesTestPeer{m_monitor, nullptr}.getGraphData();
    json withCaps = HttpSessionP4CapabilitiesTestPeer{m_monitor, m_manager}.getGraphData();

    for (const json& node : baseline.at("nodes"))
    {
        EXPECT_FALSE(node.contains("capabilities")) << "no manager, yet a node carried the key";
    }
    int carried = 0;
    for (json& node : withCaps.at("nodes"))
    {
        carried += node.contains("capabilities") ? 1 : 0;
        node.erase("capabilities");
    }
    EXPECT_EQ(carried, 3);
    EXPECT_EQ(withCaps, baseline) << "adding `capabilities` changed some other part of the response";
}

TEST_F(P4CapabilitiesWire, AnOvsFabricServesNoCapabilities)
{
    // Fixture (1) end to end: an OVS fabric, a stand-in proxy that would describe every switch if
    // it were asked, and a graph whose nodes carry nothing.
    ASSERT_NO_FATAL_FAILURE(load("OVS"));
    m_manager->answer = fourCaseSwitchState();
    m_manager->pollP4SwitchState();

    const json body = HttpSessionP4CapabilitiesTestPeer{m_monitor, m_manager}.getGraphData();
    ASSERT_FALSE(body.at("nodes").empty());
    for (const json& node : body.at("nodes"))
    {
        EXPECT_FALSE(node.contains("capabilities")) << node.dump();
    }
}

// === 4. `ryu_rules_lost` -- what a pipeline push wiped of the Ryu-path rules =====================
//
// [Co-developed with claude code -- Adam]
// KNOWN-ISSUES A-4c: the proxy does not replay the rules written through
// /stats/flowentry/* after a restart or readopt; it reports them per switch on GET /p4/switch_state,
// and the kernel must (a) log an ERROR once per record, (b) serve the record on the switch's
// /ndt/get_graph_data node. Same three layers as above: the pure functions, the 1 Hz poll, the
// endpoint. The fixture is the record the proxy serves (p4_proxy/proxy_agent/rule_journal.py
// loss_record).

namespace
{

json
lossRecord(const std::string& id, json count, std::int64_t unreadable = 0)
{
    return json{{"id", id},
                {"cause", "proxy_restart"},
                {"at", 1761200000.5},
                {"count", count},
                {"rules",
                 json::array({{{"op", "install"},
                               {"match", {{"nw_dst", "10.0.0.4"}, {"tp_dst", 80}}},
                               {"actions", json::array({{{"type", "OUTPUT"}, {"port", 3}}})},
                               {"priority", 100}}})},
                {"rules_omitted", 0},
                {"journal_unreadable", unreadable},
                {"replayed", false}};
}

json
entryLosing(const json& record)
{
    json e = entryWith(kNdtwinPipeline);
    e["ryu_rules_lost"] = record;
    return e;
}

/// Every record the global logger emits while alive, at trace level (the helper
/// tests/test_CpuReportNoIpSwitch.cpp carries, duplicated for the reason it gives).
class LossLogCapture
{
  public:
    LossLogCapture()
        : m_logger(Logger::instance()),
          m_savedLevel(m_logger->level()),
          m_sink(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(256))
    {
        m_logger->sinks().push_back(m_sink);
        m_logger->set_level(spdlog::level::trace);
    }
    ~LossLogCapture()
    {
        m_logger->set_level(m_savedLevel);
        auto& sinks = m_logger->sinks();
        for (auto it = sinks.begin(); it != sinks.end(); ++it)
        {
            if (*it == m_sink)
            {
                sinks.erase(it);
                break;
            }
        }
    }
    LossLogCapture(const LossLogCapture&) = delete;
    LossLogCapture& operator=(const LossLogCapture&) = delete;

    /// How many ERROR records contain @p token.
    int errorsContaining(const std::string& token) const
    {
        int n = 0;
        for (const auto& msg : m_sink->last_raw())
        {
            if (msg.level == spdlog::level::err &&
                std::string(msg.payload.data(), msg.payload.size()).find(token) != std::string::npos)
            {
                ++n;
            }
        }
        return n;
    }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    spdlog::level::level_enum m_savedLevel;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> m_sink;
};

class P4RulesLostPoll : public LoadedFabric
{
};

class P4RulesLostWire : public LoadedFabric
{
};

} // namespace

TEST(P4RulesLost, ARecordIsCopiedVerbatimAndNullIsNoEntry)
{
    json absent = entryWith(kNdtwinPipeline);
    json nulled = entryLosing(nullptr);
    const json payload = switchState(
        {{"1", absent}, {"2", nulled}, {"3", entryLosing(lossRecord("g3", 2))}});

    const p4loss::RecordsByDpid records = p4loss::fromSwitchState(payload);

    const p4loss::RecordsByDpid expected = {{3, lossRecord("g3", 2)}};
    EXPECT_EQ(records, expected);
    EXPECT_TRUE(p4loss::fromSwitchState(std::nullopt).empty());
}

TEST(P4RulesLost, EachRecordIsAnnouncedOnceAndANewOneAgain)
{
    p4loss::Announcer announcer;
    const p4loss::RecordsByDpid first = {{3, lossRecord("g3", 2)}};

    const auto a = announcer.observe(first);
    ASSERT_EQ(a.size(), 1u);
    EXPECT_EQ(a[0].dpid, 3u);
    EXPECT_EQ(a[0].count, std::optional<std::int64_t>(2));
    EXPECT_EQ(a[0].cause, "proxy_restart");
    EXPECT_TRUE(announcer.observe(first).empty()) << "the same record was announced twice";

    const auto b = announcer.observe({{3, lossRecord("g3-readopt", 1)}});
    EXPECT_EQ(b.size(), 1u) << "a second push of the same switch went unannounced";
}

TEST(P4RulesLost, APushThatTookNothingIsNotAnnounced)
{
    p4loss::Announcer announcer;
    EXPECT_TRUE(announcer.observe({{1, lossRecord("g1", 0)}}).empty());
}

TEST(P4RulesLost, UnreadableJournalLinesAreAnnouncedEvenWithACountOfZero)
{
    p4loss::Announcer announcer;
    const auto a = announcer.observe({{1, lossRecord("g1", 0, 2)}});
    ASSERT_EQ(a.size(), 1u);
    EXPECT_EQ(a[0].unreadable, 2);
    EXPECT_NE(p4loss::describe(a[0]).find("the count may be short"), std::string::npos);
}

TEST(P4RulesLost, ACountTheKernelCannotReadIsAnnouncedAsUnknown)
{
    p4loss::Announcer announcer;
    const auto a = announcer.observe({{1, lossRecord("g1", "lots")}});
    ASSERT_EQ(a.size(), 1u);
    EXPECT_FALSE(a[0].count.has_value());
    EXPECT_NE(p4loss::describe(a[0]).find("unknown number"), std::string::npos);
}

TEST(P4RulesLost, JournalWriteFailuresAreAnnouncedEvenWithACountOfZero)
{
    p4loss::Announcer announcer;
    json record = lossRecord("g1", 0);
    record["journal_write_failures"] = 3;
    const auto a = announcer.observe({{1, record}});
    ASSERT_EQ(a.size(), 1u);
    EXPECT_EQ(a[0].writeFailures, 3);
    EXPECT_NE(p4loss::describe(a[0]).find("3 write(s) could not be journaled"), std::string::npos);
}

TEST(P4RulesLost, ANullCountIsAnnouncedWithTheProxysReason)
{
    p4loss::Announcer announcer;
    json record = lossRecord("g1", nullptr);
    record["count_unknown"] = "the pipeline push raised";
    const auto a = announcer.observe({{1, record}});
    ASSERT_EQ(a.size(), 1u);
    EXPECT_FALSE(a[0].count.has_value());
    const std::string line = p4loss::describe(a[0]);
    EXPECT_NE(line.find("unknown number"), std::string::npos) << line;
    EXPECT_NE(line.find("the pipeline push raised"), std::string::npos) << line;
}

TEST(P4RulesLost, ARecordWithoutAnIdIsNotAnnounced)
{
    p4loss::Announcer announcer;
    json record = lossRecord("x", 4);
    record.erase("id");
    EXPECT_TRUE(announcer.observe({{1, record}}).empty());
}

TEST(P4RulesLost, TheLineNamesTheSwitchTheCountAndThatNothingWasReplayed)
{
    p4loss::Announcement a;
    a.dpid = 10;
    a.id = "g10";
    a.cause = "readopt";
    a.count = 7;
    const std::string line = p4loss::describe(a);
    EXPECT_NE(line.find("dpid 10"), std::string::npos) << line;
    EXPECT_NE(line.find("wiped 7 rule(s)"), std::string::npos) << line;
    EXPECT_NE(line.find("readopt"), std::string::npos) << line;
    EXPECT_NE(line.find("NOT replayed"), std::string::npos) << line;
    EXPECT_NE(line.find("g10"), std::string::npos) << line;
}

TEST(P4RulesLost, AttachPutsTheRecordOnItsSwitchOnly)
{
    const p4loss::RecordsByDpid records = {{3, lossRecord("g3", 2)}};
    json node3 = json::object(), node2 = json::object(), host = json::object();
    p4loss::attachToNode(node3, switchVertex(3), records);
    p4loss::attachToNode(node2, switchVertex(2), records);
    p4loss::attachToNode(host, hostVertex(3), records);
    EXPECT_EQ(node3, (json{{"ryu_rules_lost", lossRecord("g3", 2)}}));
    EXPECT_EQ(node2, json::object());
    EXPECT_EQ(host, json::object());
}

TEST_F(P4RulesLostPoll, ThePollLogsOneErrorPerRecordAndKeepsTheRecord)
{
    ASSERT_NO_FATAL_FAILURE(load("BMv2"));
    LossLogCapture log;
    m_manager->answer = switchState({{"2", entryLosing(lossRecord("g2", 3))},
                                     {"3", entryLosing(lossRecord("g3", 0))}});

    m_manager->pollP4SwitchState();
    m_manager->pollP4SwitchState(); // the next tick serves the same record

    EXPECT_EQ(log.errorsContaining("NOT replayed"), 1);
    EXPECT_EQ(log.errorsContaining("dpid 2"), 1);
    EXPECT_EQ(log.errorsContaining("dpid 3"), 0) << "a push that took nothing was logged";
    const p4loss::RecordsByDpid expected = {{2, lossRecord("g2", 3)}, {3, lossRecord("g3", 0)}};
    EXPECT_EQ(m_manager->p4RulesLostSnapshot(), expected);
}

TEST_F(P4RulesLostPoll, AnUnreadableProxyWithdrawsTheRecord)
{
    ASSERT_NO_FATAL_FAILURE(load("BMv2"));
    m_manager->answer = switchState({{"2", entryLosing(lossRecord("g2", 3))}});
    m_manager->pollP4SwitchState();
    ASSERT_EQ(m_manager->p4RulesLostSnapshot().size(), 1u);

    m_manager->answer = std::nullopt;
    m_manager->pollP4SwitchState();

    EXPECT_TRUE(m_manager->p4RulesLostSnapshot().empty());
}

TEST_F(P4RulesLostWire, TheSwitchNodeCarriesTheRecordVerbatim)
{
    ASSERT_NO_FATAL_FAILURE(load("BMv2"));
    m_manager->answer = switchState({{"2", entryLosing(lossRecord("g2", 3))}, {"3", entryWithout()}});
    m_manager->pollP4SwitchState();

    const json body = HttpSessionP4CapabilitiesTestPeer{m_monitor, m_manager}.getGraphData();

    int carried = 0;
    for (const json& node : body.at("nodes"))
    {
        if (!node.contains("ryu_rules_lost"))
        {
            continue;
        }
        ++carried;
        EXPECT_EQ(node.at("dpid").get<std::uint64_t>(), 2u) << node.dump();
        EXPECT_EQ(node.at("ryu_rules_lost"), lossRecord("g2", 3));
    }
    EXPECT_EQ(carried, 1);
}
