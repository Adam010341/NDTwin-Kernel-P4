/**
 * IntentTranslator::performTask must report what actually happened.
 *
 * [Co-developed with claude code -- Adam]
 *
 * POWEROFF and POWERON called setSwitchPowerState and threw the bool away; an unknown device
 * name skipped the call entirely with no `else`; both fell through to `return "ok"`. The
 * INSTALL / MODIFY / DELETE_FLOW_ENTRY cases discarded their OpResult the same way. The
 * DISABLE and ENABLE cases immediately above already returned error JSON per failure, so the
 * asymmetry was per-case rather than a design.
 *
 * The tests come in two layers, deliberately:
 *
 *  - The reply renderers (switchNotFoundReply / powerReply / flowReply) are pure statics and are
 *    asserted directly. That is the codebase's usual seam -- interpretRelayResponse,
 *    ovsLivenessFor, p4LivenessFor -- and the reasoning is in DeviceConfigurationAndPowerManager.hpp.
 *
 *  - performTask itself is then driven through the real switch statement, because renderers that
 *    are correct in isolation would not show that performTask calls them. "Answers ok regardless"
 *    was a wiring bug, not a rendering bug, and a test that only exercised the renderers would
 *    have stayed green through the entire defect.
 *
 * Constructing a real IntentTranslator is awkward and the rig below is the price: the constructor
 * unconditionally builds two LLMAgents, which require OPENAI_API_KEY and read their system
 * prompts from paths relative to the *current working directory*
 * (the "../src/ndt_core/intent_translator/" prefix). Rather than depend on where the
 * test binary happens to be invoked from, the fixture builds that exact shape inside a temporary
 * directory and chdir()s into it for the duration. This is the cwd-relative-config defect from
 * AUDIT C observed from the inside; it is not fixed here, only worked around.
 *
 * setSwitchPowerState is not virtual, so the failing power path is produced honestly instead of
 * by a double: a DeviceConfigurationAndPowerManager in TESTBED mode with an empty
 * switchSmartPlugTable returns false for any IP, before any I/O.
 */

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/intent_translator/IntentTranslator.hpp"
#include "ndt_core/intent_translator/LLMResponseTypes.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "utils/Logger.hpp"

/**
 * @brief Calls the private performTask. Must live at global scope to match the friend declaration.
 */
class IntentTranslatorTestPeer
{
  public:
    explicit IntentTranslatorTestPeer(std::shared_ptr<IntentTranslator> translator)
        : m_translator(std::move(translator))
    {
    }

    std::string perform(llmResponse::Task* task) { return m_translator->performTask(task); }

  private:
    std::shared_ptr<IntentTranslator> m_translator;
};

namespace
{

/// A FlowRoutingManager whose three virtual operations answer whatever the test wants.
class ScriptedFlowRoutingManager : public FlowRoutingManager
{
  public:
    ScriptedFlowRoutingManager(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                               std::shared_ptr<sflow::FlowLinkUsageCollector> collector,
                               std::shared_ptr<EventBus> bus)
        : FlowRoutingManager(std::move(monitor), std::move(collector), std::move(bus))
    {
    }

    OpResult nextResult = OpResult::success();
    int installCalls = 0;
    int modifyCalls = 0;
    int deleteCalls = 0;

    OpResult installAnEntry(uint64_t, int, const json&, const json&, int) override
    {
        ++installCalls;
        return nextResult;
    }

    OpResult modifyAnEntry(uint64_t, int, const json&, const json&) override
    {
        ++modifyCalls;
        return nextResult;
    }

    OpResult deleteAnEntry(uint64_t, const json&, int) override
    {
        ++deleteCalls;
        return nextResult;
    }
};

/**
 * @brief A temporary directory shaped like the kernel's launch layout, plus a chdir into it.
 *
 * IntentTranslator's LLMAgents read their prompts from under "../src/ndt_core/intent_translator",
 * so the rig creates <tmp>/src/ndt_core/intent_translator/ with both files and chdir()s to
 * <tmp>/run. Restores the previous cwd and OPENAI_API_KEY on destruction.
 */
class LaunchLayoutRig
{
  public:
    LaunchLayoutRig()
    {
        m_previousCwd = std::filesystem::current_path();
        m_root = std::filesystem::temp_directory_path() / "ndtwin_test_intent_task_outcomes";
        std::filesystem::remove_all(m_root);

        const auto promptDir = m_root / "src" / "ndt_core" / "intent_translator";
        std::filesystem::create_directories(promptDir);
        for (const char* name : {"answer_agent_prompt.txt", "validation_agent_prompt.txt"})
        {
            std::ofstream out(promptDir / name);
            out << "test prompt\n";
        }

        const auto runDir = m_root / "run";
        std::filesystem::create_directories(runDir);
        std::filesystem::current_path(runDir);

        const char* previousKey = std::getenv("OPENAI_API_KEY");
        m_hadKey = previousKey != nullptr;
        if (m_hadKey)
        {
            m_previousKey = previousKey;
        }
        ::setenv("OPENAI_API_KEY", "sk-test-not-used-no-request-is-made", 1);
    }

    ~LaunchLayoutRig()
    {
        std::filesystem::current_path(m_previousCwd);
        std::error_code ec;
        std::filesystem::remove_all(m_root, ec);
        if (m_hadKey)
        {
            ::setenv("OPENAI_API_KEY", m_previousKey.c_str(), 1);
        }
        else
        {
            ::unsetenv("OPENAI_API_KEY");
        }
    }

  private:
    std::filesystem::path m_previousCwd;
    std::filesystem::path m_root;
    bool m_hadKey = false;
    std::string m_previousKey;
};

class IntentTaskOutcomesTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_mutex = std::make_shared<std::shared_mutex>();
        m_bus = std::make_shared<EventBus>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(m_graph, m_mutex, m_bus,
                                                             utils::MININET);
        m_collector = nullptr;

        // TESTBED with an empty smart-plug table: setSwitchPowerState returns false for every IP
        // without touching the network. That is the "the operation failed" condition, produced by
        // the real function rather than by a double, because it is not virtual.
        m_power = std::make_shared<DeviceConfigurationAndPowerManager>(m_monitor,
                                                                       utils::TESTBED,
                                                                       "localhost",
                                                                       nullptr);

        m_routing = std::make_shared<ScriptedFlowRoutingManager>(m_monitor, m_collector, m_bus);

        m_translator = std::make_shared<IntentTranslator>(m_power, m_monitor, m_routing,
                                                          m_collector, "gpt-5-nano");
        m_peer = std::make_unique<IntentTranslatorTestPeer>(m_translator);
    }

    /// Adds a switch vertex the intent layer can resolve by its Mininet bridge name.
    void addSwitch(const std::string& bridgeName, const std::string& ip, uint64_t dpid)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].bridgeNameForMininet = bridgeName;
        // push_back, not ip[0] = ...: VertexProperties::ip is a std::vector that starts empty, so
        // indexed assignment is out of bounds. Writing it that way segfaulted this suite, and
        // IntentTranslator::getSwitchIpByName reads vertex.ip[0] with no emptiness check of its
        // own -- a switch vertex carrying no IP would fault there too.
        (*m_graph)[v].ip.push_back(utils::ipStringToUint32(ip));
        m_monitor->m_ipStrToDpidMap[ip] = dpid;
    }

    // Declared first so it is constructed first and destroyed last: the translator's LLMAgents
    // are built inside SetUp and need the layout to already exist.
    LaunchLayoutRig m_rig;

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::shared_ptr<sflow::FlowLinkUsageCollector> m_collector;
    std::shared_ptr<DeviceConfigurationAndPowerManager> m_power;
    std::shared_ptr<ScriptedFlowRoutingManager> m_routing;
    std::shared_ptr<IntentTranslator> m_translator;
    std::unique_ptr<IntentTranslatorTestPeer> m_peer;
};

} // namespace

// --- the wiring: performTask driven through its real switch statement --------------------------

TEST_F(IntentTaskOutcomesTest, PowerOffOnAnUnknownDeviceReportsAnErrorRatherThanOk)
{
    llmResponse::PowerOffSwitchTask task;
    task.deviceName = "s99_does_not_exist";

    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    EXPECT_TRUE(reply.contains("error")) << "reply was: " << reply.dump();
    EXPECT_EQ(reply.value("device", ""), "s99_does_not_exist");
}

TEST_F(IntentTaskOutcomesTest, PowerOffThatFailsReportsTheFailureRatherThanOk)
{
    addSwitch("s1", "10.0.0.1", 1);

    llmResponse::PowerOffSwitchTask task;
    task.deviceName = "s1";

    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    EXPECT_TRUE(reply.contains("error"))
        << "setSwitchPowerState returned false and the reply still claimed success: "
        << reply.dump();
}

TEST_F(IntentTaskOutcomesTest, PowerOnOnAnUnknownDeviceReportsAnErrorRatherThanOk)
{
    llmResponse::PowerOnSwitchTask task;
    task.deviceName = "s99_does_not_exist";

    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    EXPECT_TRUE(reply.contains("error")) << "reply was: " << reply.dump();
}

TEST_F(IntentTaskOutcomesTest, PowerOnThatFailsReportsTheFailureRatherThanOk)
{
    addSwitch("s1", "10.0.0.1", 1);

    llmResponse::PowerOnSwitchTask task;
    task.deviceName = "s1";

    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    EXPECT_TRUE(reply.contains("error")) << "reply was: " << reply.dump();
}

TEST_F(IntentTaskOutcomesTest, AFailedInstallReportsTheControllersVerdictRatherThanOk)
{
    addSwitch("s1", "10.0.0.1", 1);
    m_routing->nextResult = OpResult::failure(409, "controller rejected the entry");

    llmResponse::InstallFlowEntryTask task;
    task.deviceName = "s1";
    task.priority = 100;
    task.match = nlohmann::json{{"eth_type", 2048}, {"ipv4_dst", "10.0.0.2"}};
    task.actionType = "OUTPUT";
    task.actionOutPort = 2;

    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    EXPECT_EQ(m_routing->installCalls, 1) << "the operation was never attempted";
    EXPECT_TRUE(reply.contains("error")) << "reply was: " << reply.dump();
    EXPECT_EQ(reply.value("http_status", 0), 409)
        << "OpResult::httpStatus distinguishes 'the controller said no' from 'the controller is "
           "not there' and must survive to the caller: "
        << reply.dump();
}

/**
 * The accept path. A guard that refuses everything passes every refusal test, so a *successful*
 * install must still be reported as a success -- and must not be turned into an error by the fix.
 */
TEST_F(IntentTaskOutcomesTest, ASuccessfulInstallIsStillReportedAsSuccess)
{
    addSwitch("s1", "10.0.0.1", 1);
    m_routing->nextResult = OpResult::success();

    llmResponse::InstallFlowEntryTask task;
    task.deviceName = "s1";
    task.priority = 100;
    task.match = nlohmann::json{{"eth_type", 2048}, {"ipv4_dst", "10.0.0.2"}};
    task.actionType = "OUTPUT";
    task.actionOutPort = 2;

    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    EXPECT_EQ(m_routing->installCalls, 1);
    EXPECT_FALSE(reply.contains("error")) << "reply was: " << reply.dump();
    EXPECT_TRUE(reply.contains("status")) << "reply was: " << reply.dump();
}

TEST_F(IntentTaskOutcomesTest, AFailedDeleteReportsTheFailureRatherThanOk)
{
    addSwitch("s1", "10.0.0.1", 1);
    m_routing->nextResult = OpResult::failure(0, "controller unreachable");

    llmResponse::DeleteFlowEntryTask task;
    task.deviceName = "s1";
    task.match = nlohmann::json{{"nw_dst", "10.0.0.2"}};

    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    EXPECT_EQ(m_routing->deleteCalls, 1) << "the operation was never attempted";
    EXPECT_TRUE(reply.contains("error")) << "reply was: " << reply.dump();
}

TEST_F(IntentTaskOutcomesTest, AnUnknownDeviceOnAFlowInstallIsRefusedBeforeTheControllerIsCalled)
{
    llmResponse::InstallFlowEntryTask task;
    task.deviceName = "s99_does_not_exist";
    task.priority = 100;
    task.match = nlohmann::json{{"eth_type", 2048}, {"ipv4_dst", "10.0.0.2"}};
    task.actionType = "OUTPUT";
    task.actionOutPort = 2;

    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    EXPECT_EQ(m_routing->installCalls, 0)
        << "an unresolvable device name must not reach the controller";
    EXPECT_TRUE(reply.contains("error")) << "reply was: " << reply.dump();
}

// --- the renderers, asserted directly ---------------------------------------------------------

TEST(IntentReplyRenderingTest, SwitchNotFoundNamesTheDevice)
{
    const auto reply = nlohmann::json::parse(IntentTranslator::switchNotFoundReply("s7"));
    EXPECT_EQ(reply.value("error", ""), "Switch not found");
    EXPECT_EQ(reply.value("device", ""), "s7");
}

TEST(IntentReplyRenderingTest, PowerReplyDistinguishesSuccessFromFailure)
{
    const auto failed = nlohmann::json::parse(IntentTranslator::powerReply(false, "off", "s3"));
    EXPECT_TRUE(failed.contains("error"));
    EXPECT_FALSE(failed.contains("status"));

    const auto worked = nlohmann::json::parse(IntentTranslator::powerReply(true, "off", "s3"));
    EXPECT_FALSE(worked.contains("error"));
    EXPECT_EQ(worked.value("status", ""), "powered_off");
}

TEST(IntentReplyRenderingTest, FlowReplyCarriesTheHttpStatusAndDetail)
{
    const auto reply = nlohmann::json::parse(
        IntentTranslator::flowReply(OpResult::failure(503, "ryu is down"), "install", "s3"));

    EXPECT_EQ(reply.value("http_status", 0), 503);
    EXPECT_EQ(reply.value("detail", ""), "ryu is down");
}

/**
 * A device name from an LLM can contain a quote. The DISABLE/ENABLE cases build their replies by
 * string concatenation and would emit a malformed body; the renderers here must not.
 */
TEST(IntentReplyRenderingTest, ADeviceNameContainingAQuoteStillProducesParseableJson)
{
    const std::string nasty = R"(s1", "injected": "yes)";
    const auto reply = nlohmann::json::parse(IntentTranslator::switchNotFoundReply(nasty));

    EXPECT_EQ(reply.value("device", ""), nasty);
    EXPECT_FALSE(reply.contains("injected"));
}
