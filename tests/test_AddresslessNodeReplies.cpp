/**
 * FINDINGS #88, W14: the seven `ip[0]` sites W2 found and did not fix.
 *
 * [Co-developed with claude code -- Adam]
 *
 * W2 (#88) guarded sixteen unguarded `ip.front()` dereferences. Its own grep then turned up seven
 * more that it left alone, in three other subsystems, written as `ip[0]` instead of `.front()`:
 *
 *     IntentTranslator.cpp   getSwitchIpByName                 SWITCH
 *     IntentTranslator.cpp   GET_NETWORK_TOPOLOGY, switches[]  SWITCH
 *     IntentTranslator.cpp   GET_NETWORK_TOPOLOGY, hosts[]     HOST
 *     IntentTranslator.cpp   GET_ALL_HOSTS                     HOST
 *     LLMAgent.cpp           getCurrentTopology                HOST
 *     FlowLinkUsageCollector.cpp  getPathBetweenHostsJson, src HOST
 *     FlowLinkUsageCollector.cpp  getPathBetweenHostsJson, dst HOST
 *
 * `operator[]` is not a milder `front()`. libstdc++ defines both as `*(_M_start + n)`, and a
 * default-constructed std::vector has `_M_start == nullptr`, so `ip[0]` on a node with no address
 * binds a reference to a null pointer and then reads through it. The only difference from #88 is
 * spelling.
 *
 * WHY THE HOST SITES ARE THE ONES THAT MATTER
 *
 * The invariant that made all of this look safe -- "every node carries at least one address" -- is
 * enforced in a different subsystem, at load time, by a single `if` that tests SWITCH vertices
 * only (TopologyAndFlowMonitor.cpp:216, whose own comment says ten call sites lean on it). Five of
 * the seven read a HOST, and every one of those five loops filters on `vertexType` and on nothing
 * else. Nothing between the loader and them excludes a host with an empty `ip` array.
 *
 * The two SWITCH sites are fixed here for consistency, not because a route to them was found. A
 * guard that covers six of seven identical expressions in one file is the state this finding
 * started from.
 *
 * WHY THE FIRST SEVEN TESTS FORK
 *
 * The failure is a null dereference, so on an ordinary build the unfixed code does not produce a
 * red line -- it takes the whole binary down, mid-suite, with no `[  FAILED  ]` for anything and
 * no result for any suite that had not run yet. That is not evidence, and W2's mutation gate
 * proved it: its M2 mutant was scored SURVIVED on 2026-09-04 because the fault landed in an
 * in-process test and killed the process before gtest could return a verdict (W2-SUMMARY §4.2).
 *
 * So each of the seven sites gets a death test, declared before every in-process test in this
 * file, and the assertion is `ExitedWithCode(0)`: the child performs the operation and exits
 * cleanly. On the unfixed code the child dies of SIGSEGV and the parent prints a named red line.
 * That containment is the whole point -- it converts "the run died" into "this test failed".
 *
 * The in-process tests that follow assert what the guarded code ANSWERS, which is the other half
 * and not the same half. A guard that stops the crash by emitting "0.0.0.0", or by dropping the
 * node from a listing whose question is "which nodes are there", has moved the defect rather than
 * fixed it. Those are mutations M8-M11 in tests/shell/mutate_index_zero_guards.sh.
 */

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>

#include <unistd.h>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/intent_translator/IntentTranslator.hpp"
#include "ndt_core/intent_translator/LLMAgent.hpp"
#include "ndt_core/intent_translator/LLMResponseTypes.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

/**
 * @brief Calls IntentTranslator's private performTask and getSwitchIpByName.
 *
 * Global scope, to match the friend declaration in IntentTranslator.hpp. A second peer rather than
 * a reuse of test_IntentTaskOutcomes.cpp's IntentTranslatorTestPeer: that one is a class
 * *definition* in another translation unit, so a same-named class here would be an ODR violation
 * with no diagnostic required.
 */
class AddresslessNodePeer
{
  public:
    explicit AddresslessNodePeer(std::shared_ptr<IntentTranslator> translator)
        : m_translator(std::move(translator))
    {
    }

    std::string perform(llmResponse::Task* task) { return m_translator->performTask(task); }

    std::optional<std::string> switchIp(const std::string& switchName)
    {
        return m_translator->getSwitchIpByName(switchName);
    }

  private:
    std::shared_ptr<IntentTranslator> m_translator;
};

/**
 * @brief Calls LLMAgent's private getCurrentTopology.
 *
 * Its only production caller is callOpenAIApi, which issues an HTTP request, so the graph walk is
 * unreachable from any public entry point a test can drive without a network.
 */
class AddresslessTopologyPeer
{
  public:
    explicit AddresslessTopologyPeer(LLMAgent& agent) : m_agent(agent) {}

    std::string topology() { return m_agent.getCurrentTopology(); }

  private:
    LLMAgent& m_agent;
};

namespace
{

/**
 * @brief A temporary directory shaped like the kernel's launch layout, plus a chdir into it.
 *
 * Same rig as LaunchLayoutRig in test_IntentTaskOutcomes.cpp and duplicated for the reason that
 * file gives about LogCapture: hoisting it would create a test-support header several suites then
 * have to agree on. The temp directory name differs so the two suites cannot collide, and the
 * previous cwd and OPENAI_API_KEY are restored on destruction.
 *
 * IntentTranslator's constructor unconditionally builds two LLMAgents, which read their system
 * prompts from paths relative to the *current working directory* -- the "../src/ndt_core/
 * intent_translator/" prefix -- and throw if the file is not there. This is the cwd-relative
 * config defect observed from the inside; it is worked around here, not fixed.
 */
class PromptLayoutRig
{
  public:
    PromptLayoutRig()
    {
        m_previousCwd = std::filesystem::current_path();
        m_root = std::filesystem::temp_directory_path() / "ndtwin_test_addressless_node_replies";
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

    ~PromptLayoutRig()
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

    PromptLayoutRig(const PromptLayoutRig&) = delete;
    PromptLayoutRig& operator=(const PromptLayoutRig&) = delete;

    /// The path an LLMAgent built by this test should be handed, relative to the rig's cwd.
    static const char* promptPath() { return "../src/ndt_core/intent_translator/answer_agent_prompt.txt"; }

  private:
    std::filesystem::path m_previousCwd;
    std::filesystem::path m_root;
    bool m_hadKey = false;
    std::string m_previousKey;
};

/// Same seam as PathCollector in test_AllDestinationPaths.cpp and TestableCollector in
/// test_SFlowParsing.cpp: the power manager is untouched by the path maps, so it can be null.
class PathQueryCollector : public sflow::FlowLinkUsageCollector
{
  public:
    PathQueryCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                       std::shared_ptr<EventBus> bus,
                       std::shared_ptr<ndtClassifier::Classifier> classifier)
        : sflow::FlowLinkUsageCollector(std::move(monitor),
                                        nullptr,
                                        std::move(bus),
                                        utils::DeploymentMode::MININET,
                                        std::move(classifier))
    {
    }
};

/**
 * @brief One graph, shared by all seven sites, holding both shapes of the defect.
 *
 * The graph is deliberately not minimal. Every site walks every vertex, so a graph with only the
 * address-less node in it could not tell "the guard skipped the node it cannot name" apart from
 * "the guard emptied the whole reply" -- W2's M4 mutant is exactly that confusion, and it needs a
 * node that DOES have an address sitting next to the one that does not.
 *
 *   s1  SWITCH, 10.0.0.1     h1  HOST, 10.0.0.11     h3  HOST, 10.0.0.13
 *   s2  SWITCH, no address   h2  HOST, no address
 */
class AddresslessNodeTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_mutex = std::make_shared<std::shared_mutex>();
        m_bus = std::make_shared<EventBus>();
        m_monitor =
            std::make_shared<TopologyAndFlowMonitor>(m_graph, m_mutex, m_bus, utils::MININET);

        addSwitch("s1", "10.0.0.1", 1);
        addSwitchWithoutAddress("s2", 2);
        addHost("h1", "10.0.0.11", 0x0011u);
        addHostWithoutAddress("h2", 0x0012u);
        addHost("h3", "10.0.0.13", 0x0013u);

        // TESTBED with an empty smart-plug table, as in test_IntentTaskOutcomes.cpp: no I/O, and
        // nothing in these seven sites touches it.
        m_power = std::make_shared<DeviceConfigurationAndPowerManager>(m_monitor,
                                                                       utils::TESTBED,
                                                                       "localhost",
                                                                       nullptr);

        // Null routing manager and null collector: neither GET_NETWORK_TOPOLOGY, GET_ALL_HOSTS
        // nor getSwitchIpByName reaches either one.
        m_translator = std::make_shared<IntentTranslator>(m_power, m_monitor, nullptr, nullptr,
                                                          "gpt-5-nano");
        m_peer = std::make_unique<AddresslessNodePeer>(m_translator);

        m_agent = std::make_unique<LLMAgent>(PromptLayoutRig::promptPath(), m_monitor, m_power,
                                             "gpt-5-nano");
        m_agentPeer = std::make_unique<AddresslessTopologyPeer>(*m_agent);

        m_collector = std::make_unique<PathQueryCollector>(
            m_monitor, m_bus, std::make_shared<ndtClassifier::Classifier>());
    }

    void addSwitch(const std::string& name, const std::string& ip, uint64_t dpid)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].deviceName = name;
        (*m_graph)[v].bridgeNameForMininet = name;
        (*m_graph)[v].dpid = dpid;
        // push_back, never `ip[0] = ...`: VertexProperties::ip is a std::vector that starts empty,
        // so indexed assignment is the very out-of-bounds write this suite is about.
        (*m_graph)[v].ip.push_back(utils::ipStringToUint32(ip));
        m_monitor->m_ipStrToDpidMap[ip] = dpid;
    }

    void addSwitchWithoutAddress(const std::string& name, uint64_t dpid)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].deviceName = name;
        (*m_graph)[v].bridgeNameForMininet = name;
        (*m_graph)[v].dpid = dpid;
        // `ip` left empty on purpose. That is the whole fixture.
    }

    void addHost(const std::string& name, const std::string& ip, uint64_t mac)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::HOST;
        (*m_graph)[v].deviceName = name;
        (*m_graph)[v].mac = mac;
        (*m_graph)[v].ip.push_back(utils::ipStringToUint32(ip));
    }

    void addHostWithoutAddress(const std::string& name, uint64_t mac)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::HOST;
        (*m_graph)[v].deviceName = name;
        (*m_graph)[v].mac = mac;
    }

    /// Finds one element of a JSON array by its "name". Returns a null json if there is none.
    static nlohmann::json named(const nlohmann::json& array, const std::string& name)
    {
        for (const auto& entry : array)
        {
            if (entry.value("name", "") == name)
            {
                return entry;
            }
        }
        return nlohmann::json(nullptr);
    }

    // --- the seven operations, each ending in exit(0) -------------------------------------------
    //
    // Written as members rather than inline in the macro because EXPECT_EXIT is a macro and a
    // braced list inside one is split on its commas -- the same trap test_LoggerCliArgs.cpp
    // records.

    void networkTopologyThenExitZero()
    {
        llmResponse::GetNetworkTopologyTask task;
        (void)m_peer->perform(&task);
        std::exit(0);
    }

    void allHostsThenExitZero()
    {
        llmResponse::GetAllHostsTask task;
        (void)m_peer->perform(&task);
        std::exit(0);
    }

    void agentPromptThenExitZero()
    {
        (void)m_agentPeer->topology();
        std::exit(0);
    }

    void pathFromAddresslessHostThenExitZero()
    {
        (void)m_collector->getPathBetweenHostsJson("h2", "h1");
        std::exit(0);
    }

    void pathToAddresslessHostThenExitZero()
    {
        (void)m_collector->getPathBetweenHostsJson("h1", "h2");
        std::exit(0);
    }

    void switchIpByNameThenExitZero()
    {
        (void)m_peer->switchIp("s2");
        std::exit(0);
    }

    // Constructed first and destroyed last: the translator's two LLMAgents and this suite's own
    // are built inside SetUp and need the layout to already exist.
    PromptLayoutRig m_rig;

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::shared_ptr<DeviceConfigurationAndPowerManager> m_power;
    std::shared_ptr<IntentTranslator> m_translator;
    std::unique_ptr<AddresslessNodePeer> m_peer;
    std::unique_ptr<LLMAgent> m_agent;
    std::unique_ptr<AddresslessTopologyPeer> m_agentPeer;
    std::unique_ptr<PathQueryCollector> m_collector;
};

} // namespace

// =================================================================================================
// The seven sites, one contained death test each. Declared before every in-process test in this
// file: gtest runs a suite's tests in declaration order, and on the unfixed code the in-process
// tests below take the binary down before it can print anything.
// =================================================================================================

/// IntentTranslator.cpp, GET_NETWORK_TOPOLOGY, hosts[] -- HOST, reachable.
TEST_F(AddresslessNodeTest, TheTopologyReplyOverAnAddresslessHostDoesNotKillTheProcess)
{
    EXPECT_EXIT(networkTopologyThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "GET_NETWORK_TOPOLOGY read vprop.ip[0] on a HOST whose address list is empty. The loop "
           "filters on vertexType and nothing else, and the load-time gate that keeps `ip` "
           "non-empty covers SWITCH vertices only.";
}

/// IntentTranslator.cpp, GET_ALL_HOSTS -- HOST, reachable.
TEST_F(AddresslessNodeTest, TheHostListingOverAnAddresslessHostDoesNotKillTheProcess)
{
    EXPECT_EXIT(allHostsThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "GET_ALL_HOSTS read vprop.ip[0] on every HOST in the graph.";
}

/// LLMAgent.cpp, getCurrentTopology -- HOST, reachable.
TEST_F(AddresslessNodeTest, TheAgentPromptOverAnAddresslessHostDoesNotKillTheProcess)
{
    EXPECT_EXIT(agentPromptThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "getCurrentTopology builds the system prompt for every LLM call, so this one faulted "
           "on the request path rather than on a reporting path.";
}

/// FlowLinkUsageCollector.cpp, getPathBetweenHostsJson, source end -- HOST, reachable.
TEST_F(AddresslessNodeTest, APathQueryFromAnAddresslessHostDoesNotKillTheProcess)
{
    EXPECT_EXIT(pathFromAddresslessHostThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "findVertexByDeviceName matches on the name, so the not-found branch above does not "
           "cover a host that exists and has no address.";
}

/// FlowLinkUsageCollector.cpp, getPathBetweenHostsJson, destination end -- HOST, reachable.
TEST_F(AddresslessNodeTest, APathQueryToAnAddresslessHostDoesNotKillTheProcess)
{
    EXPECT_EXIT(pathToAddresslessHostThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "The destination subscript is a separate expression on its own line and needs its own "
           "evidence; a fix to the source end alone would leave this one standing.";
}

/// IntentTranslator.cpp, getSwitchIpByName -- SWITCH. Consistency, no production route found.
TEST_F(AddresslessNodeTest, ResolvingAnAddresslessSwitchByNameDoesNotKillTheProcess)
{
    EXPECT_EXIT(switchIpByNameThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "A SWITCH site: the load-time gate does cover this one, so no production route was "
           "found to it. Fixed and pinned anyway -- that gate is one `if` in another subsystem "
           "that did not exist five weeks ago.";
}

// The seventh site, GET_NETWORK_TOPOLOGY's switches[] branch, shares its walk with the first death
// test above: one address-less SWITCH and one address-less HOST are both in the graph, so
// networkTopologyThenExitZero() crosses both expressions in one pass. It is named separately
// because the mutation gate restores the two subscripts independently.
TEST_F(AddresslessNodeTest, TheTopologyReplyOverAnAddresslessSwitchDoesNotKillTheProcess)
{
    EXPECT_EXIT(networkTopologyThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "GET_NETWORK_TOPOLOGY's switches[] branch read vprop.ip[0] with no check of its own.";
}

// =================================================================================================
// What the guarded code answers. A guard that stops the crash and loses the disclosure has moved
// the defect, not fixed it.
// =================================================================================================

TEST_F(AddresslessNodeTest, TheTopologyReplyStillNamesEveryHostAndSwitch)
{
    llmResponse::GetNetworkTopologyTask task;
    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    ASSERT_TRUE(reply.contains("hosts")) << reply.dump();
    ASSERT_TRUE(reply.contains("switches")) << reply.dump();

    // Three hosts and two switches went in; the address-less ones are still there. Dropping a node
    // would answer a different question than "what is the topology".
    EXPECT_EQ(reply["hosts"].size(), 3u) << "h2 has no address; it is still a host: " << reply.dump();
    EXPECT_EQ(reply["switches"].size(), 2u) << "s2 has no address; it is still a switch: "
                                            << reply.dump();
}

TEST_F(AddresslessNodeTest, TheTopologyReplyGivesTheAddresslessNodesNullAndNotAnAddress)
{
    llmResponse::GetNetworkTopologyTask task;
    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    const auto h2 = named(reply["hosts"], "h2");
    ASSERT_FALSE(h2.is_null()) << "h2 vanished from the reply: " << reply.dump();
    ASSERT_TRUE(h2.contains("ip")) << "the key must stay present for a reader indexing [\"ip\"]: "
                                   << h2.dump();
    EXPECT_TRUE(h2["ip"].is_null()) << "an address-less host must not be given one: " << h2.dump();

    const auto s2 = named(reply["switches"], "s2");
    ASSERT_FALSE(s2.is_null()) << "s2 vanished from the reply: " << reply.dump();
    EXPECT_TRUE(s2["ip"].is_null()) << "an address-less switch must not be given one: " << s2.dump();

    // The failure mode this file has been burned by twice: a plausible-looking substitute no
    // caller can tell apart from a measurement.
    EXPECT_EQ(reply.dump().find("0.0.0.0"), std::string::npos)
        << "a fabricated address reached the reply: " << reply.dump();
}

TEST_F(AddresslessNodeTest, TheTopologyReplyStillCarriesTheAddressesItDoesHave)
{
    llmResponse::GetNetworkTopologyTask task;
    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    // The control against an over-guard. A guard written as "skip any node whose address list is
    // empty" placed one loop level too high, or a `continue` that swallows the rest of the body,
    // empties the whole reply -- and every assertion above would still pass on an empty array.
    EXPECT_EQ(named(reply["hosts"], "h1").value("ip", ""), "10.0.0.11") << reply.dump();
    EXPECT_EQ(named(reply["hosts"], "h3").value("ip", ""), "10.0.0.13") << reply.dump();
    EXPECT_EQ(named(reply["switches"], "s1").value("ip", ""), "10.0.0.1") << reply.dump();
}

TEST_F(AddresslessNodeTest, TheHostListingKeepsTheAddresslessHostWithANullAddress)
{
    llmResponse::GetAllHostsTask task;
    const auto reply = nlohmann::json::parse(m_peer->perform(&task));

    ASSERT_TRUE(reply.is_array()) << reply.dump();
    EXPECT_EQ(reply.size(), 3u) << "h2 has no address; it is still a host: " << reply.dump();

    const auto h2 = named(reply, "h2");
    ASSERT_FALSE(h2.is_null()) << reply.dump();
    EXPECT_TRUE(h2["ip"].is_null()) << h2.dump();
    EXPECT_EQ(reply.dump().find("0.0.0.0"), std::string::npos) << reply.dump();

    // Control, as above: the hosts that do have addresses still report them.
    EXPECT_EQ(named(reply, "h1").value("ip", ""), "10.0.0.11") << reply.dump();
    EXPECT_EQ(named(reply, "h3").value("ip", ""), "10.0.0.13") << reply.dump();
}

TEST_F(AddresslessNodeTest, ThePromptDescribesTheAddresslessHostWithoutGivingItAnAddress)
{
    const std::string prompt = m_agentPeer->topology();

    EXPECT_NE(prompt.find("h2"), std::string::npos)
        << "the host is still part of the topology being described: " << prompt;
    EXPECT_EQ(prompt.find("0.0.0.0"), std::string::npos)
        << "this string IS the system prompt an LLM then proposes flow rules against, so a "
           "fabricated address here is a fabricated fact acted on: "
        << prompt;

    // Control: the hosts that have addresses still carry them into the prompt, and the count line
    // still counts every host.
    EXPECT_NE(prompt.find("10.0.0.11"), std::string::npos) << prompt;
    EXPECT_NE(prompt.find("There are 3 hosts"), std::string::npos) << prompt;
}

TEST_F(AddresslessNodeTest, APathQueryFromAnAddresslessHostIsRefusedAndSaysWhich)
{
    const auto reply = m_collector->getPathBetweenHostsJson("h2", "h1");

    ASSERT_TRUE(reply.is_object()) << reply.dump();
    ASSERT_TRUE(reply.contains("error")) << reply.dump();
    ASSERT_TRUE(reply.contains("hosts_without_address")) << reply.dump();
    EXPECT_EQ(reply["hosts_without_address"], nlohmann::json::array({"h2"}))
        << "the refusal has to name the host it is about; h1 has an address: " << reply.dump();
}

TEST_F(AddresslessNodeTest, APathQueryToAnAddresslessHostIsRefusedAndSaysWhich)
{
    const auto reply = m_collector->getPathBetweenHostsJson("h1", "h2");

    ASSERT_TRUE(reply.contains("hosts_without_address")) << reply.dump();
    EXPECT_EQ(reply["hosts_without_address"], nlohmann::json::array({"h2"})) << reply.dump();
}

TEST_F(AddresslessNodeTest, APathBetweenTwoAddressedHostsStillAnswers)
{
    // The control for both path tests. A guard that refuses every query would satisfy the two
    // above and destroy the endpoint.
    sflow::Path path;
    path.emplace_back(utils::ipStringToUint32("10.0.0.11"), 0u);
    path.emplace_back(uint64_t{1}, 1u);
    path.emplace_back(utils::ipStringToUint32("10.0.0.13"), 0u);
    m_collector->setAllPaths({path});

    const auto reply = m_collector->getPathBetweenHostsJson("h1", "h3");

    EXPECT_FALSE(reply.contains("error")) << reply.dump();
    EXPECT_FALSE(reply.contains("hosts_without_address")) << reply.dump();
}

TEST_F(AddresslessNodeTest, AnAddresslessSwitchIsNotResolvedToAnAddress)
{
    EXPECT_FALSE(m_peer->switchIp("s2").has_value())
        << "the return type was already optional<string>, so nullopt costs no new shape and "
           "\"0.0.0.0\" would flow on to dpidForSwitchIp as a lookup key: "
        << m_peer->switchIp("s2").value_or("<nullopt>");
}

TEST_F(AddresslessNodeTest, ASwitchWithAnAddressStillResolves)
{
    // Control: the guard must not have turned getSwitchIpByName into a function that answers
    // nullopt for everything.
    const auto ip = m_peer->switchIp("s1");
    ASSERT_TRUE(ip.has_value());
    EXPECT_EQ(*ip, "10.0.0.1");
}

// =================================================================================================
// Where an address-less HOST comes from. This is the half W2 left at "read from the code", and
// these three tests turn it into a file that loads.
//
// The fixture above builds its graph with boost::add_vertex directly, which proves the guards work
// but says nothing about whether production can produce that graph. The loader is the answer: both
// the pre-validation pass (validateStaticTopologyJson, TopologyAndFlowMonitor.cpp:219) and the
// builder's backstop (:759) refuse an empty "ip" array for a **SWITCH** and say so in the message.
// Neither looks at a HOST. `at("ip")` throws on a missing key and accepts an empty array, so a
// topology file declaring a host with `"ip": []` reaches boost::add_vertex.
//
// These do not use the fixture: PromptLayoutRig chdir()s into a temp directory, and the shipped
// topology is found relative to the cwd.
//
// 🔴 THIS RECORDS A REGIME, AND THE REGIME IS SCHEDULED TO CHANGE. Branch
// fix/w3-door3b-host-empty-ip is being written in parallel and closes exactly this route at the
// file level. When the two meet, the middle case below goes red on purpose; the message on that
// assertion says what to do about it. The runtime guards are not affected either way -- a
// file-level refusal and a runtime non-crash are two layers, and W3's own ticket says both stay.
// =================================================================================================

namespace
{

/// Exposes the protected loader, the same seam test_TopologyInputValidation.cpp uses.
class TopologyLoadProbe : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void load(const std::string& path) { loadStaticTopologyFromFile(path); }
};

/// The repo's `setting/` directory, wherever the binary was started from. Duplicated from
/// test_TopologyInputValidation.cpp for the reason that file gives: ctest runs from the build tree
/// and l1_unit_tests.sh runs the binary from the repo root, deliberately.
std::string
settingDirectory()
{
    for (const char* candidate : {"setting", "../setting", "../../setting"})
    {
        if (std::filesystem::is_directory(candidate))
        {
            return candidate;
        }
    }
    return {};
}

/// What one load attempt did: whether it threw, and how big a graph it left behind.
struct LoadAttempt
{
    bool threw = false;
    std::string message;
    std::size_t vertices = 0;
    std::size_t hostsWithoutAnAddress = 0;
};

/// Writes `topology` to a temp file, loads it into a fresh monitor, and reports what happened.
LoadAttempt
loadTopology(const nlohmann::json& topology, const std::string& tag)
{
    const auto path = std::filesystem::temp_directory_path() /
                      ("ndt_w14_" + tag + "_" + std::to_string(::getpid()) + ".json");
    {
        std::ofstream out(path);
        out << topology.dump();
    }

    LoadAttempt attempt;
    auto graph = std::make_shared<Graph>();
    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    TopologyLoadProbe monitor{graph, mutex, bus, utils::TESTBED};

    try
    {
        monitor.load(path.string());
    }
    catch (const std::exception& err)
    {
        attempt.threw = true;
        attempt.message = err.what();
    }

    {
        std::shared_lock lock(*mutex);
        attempt.vertices = boost::num_vertices(*graph);
        for (auto [vi, viEnd] = boost::vertices(*graph); vi != viEnd; ++vi)
        {
            const auto& vprop = (*graph)[*vi];
            if (vprop.vertexType == VertexType::HOST && vprop.ip.empty())
            {
                ++attempt.hostsWithoutAnAddress;
            }
        }
    }

    std::error_code ignored;
    std::filesystem::remove(path, ignored);
    return attempt;
}

/// The shipped P4 topology as JSON, or a null json if this binary cannot find `setting/`.
nlohmann::json
shippedTopology()
{
    const std::string dir = settingDirectory();
    if (dir.empty())
    {
        return nlohmann::json(nullptr);
    }
    const auto path = dir + "/StaticNetworkTopologyP4_10Switches_4Hosts.json";
    if (!std::filesystem::exists(path))
    {
        return nlohmann::json(nullptr);
    }
    std::ifstream in(path);
    nlohmann::json parsed;
    in >> parsed;
    return parsed;
}

} // namespace

TEST(AddresslessHostLoadTest, TheShippedTopologyLoads)
{
    const auto topology = shippedTopology();
    ASSERT_FALSE(topology.is_null())
        << "setting/StaticNetworkTopologyP4_10Switches_4Hosts.json was not found from this "
           "working directory. A test that cannot find its input must say so rather than assert "
           "vacuously.";

    const auto baseline = loadTopology(topology, "baseline");
    ASSERT_FALSE(baseline.threw) << "the unmodified shipped file must load, or the two tests "
                                    "below prove nothing about the edit they make: "
                                 << baseline.message;
    EXPECT_EQ(baseline.hostsWithoutAnAddress, 0u) << "precondition: every shipped host has an "
                                                     "address";
}

TEST(AddresslessHostLoadTest, AHostDeclaringAnEmptyIpArrayIsAcceptedAndReachesTheGraph)
{
    auto topology = shippedTopology();
    ASSERT_FALSE(topology.is_null()) << "setting/ not found from this working directory";

    const auto baseline = loadTopology(topology, "base_for_host");
    ASSERT_FALSE(baseline.threw) << baseline.message;

    // A new host node, cloned from a shipped one so every key the loader reads is present, with
    // its address list emptied. No edge names it, because an edge endpoint with dpid 0 is resolved
    // by address and validateStaticTopologyJson refuses one whose address no node holds -- that
    // rule is about the EDGE's own "src_ip"/"dst_ip", and it is why blanking an attached host's
    // address is refused while declaring an unattached one is not.
    nlohmann::json host;
    for (const auto& node : topology["nodes"])
    {
        if (node.value("vertex_type", -1) == static_cast<int>(VertexType::HOST))
        {
            host = node;
            break;
        }
    }
    ASSERT_FALSE(host.is_null()) << "the shipped file declares no host";
    host["ip"] = nlohmann::json::array();
    host["device_name"] = "h_no_address";
    host["nickname"] = "h_no_address";
    host["mac"] = 0xADD1E55ull;
    topology["nodes"].push_back(host);

    const auto attempt = loadTopology(topology, "host_without_address");

    EXPECT_FALSE(attempt.threw)
        << "READ THIS BEFORE 'FIXING' THE TEST. A throw here means the loader has grown a "
           "host-side address check -- almost certainly W3 door 3b, branch "
           "fix/w3-door3b-host-empty-ip, which is being written in parallel with this one and "
           "whose whole purpose is to refuse `\"ip\": []` on a host. That is GOOD NEWS and this "
           "red is the intended signal, not a broken test.\n"
           "The correct edit is to flip this case to expect the refusal -- assert threw, assert "
           "the message names the host, assert vertices == 0, exactly like "
           "TheSameEditOnASwitchIsRefused below -- and to record in "
           "doc/audit/2026-09-06_fix-index-zero-guards/FIX-INDEX-ZERO-GUARDS.md section 2 that "
           "file-level door now closes this route. Do NOT delete the case: the runtime guards "
           "this suite pins stay justified either way (a file-level refusal and a runtime "
           "non-crash are two layers, and the invariant would once again be one `if` in another "
           "subsystem), and this is the record of which layer was load-bearing when.\n"
           "The load reported: "
        << attempt.message;
    EXPECT_EQ(attempt.vertices, baseline.vertices + 1) << "the address-less host became a vertex";
    EXPECT_EQ(attempt.hostsWithoutAnAddress, 1u)
        << "this vertex is what every one of the five reachable sites then reads ip[0] on";
}

TEST(AddresslessHostLoadTest, TheSameEditOnASwitchIsRefused)
{
    // The control, and the reason the test above is not an artifact of how this file writes JSON:
    // the identical edit to a SWITCH node is refused at load, by name, in the same code path.
    auto topology = shippedTopology();
    ASSERT_FALSE(topology.is_null()) << "setting/ not found from this working directory";

    for (auto& node : topology["nodes"])
    {
        if (node.value("vertex_type", -1) == static_cast<int>(VertexType::SWITCH))
        {
            node["ip"] = nlohmann::json::array();
            break;
        }
    }

    const auto attempt = loadTopology(topology, "switch_without_address");

    EXPECT_TRUE(attempt.threw) << "a switch with no address is refused; a host with none is not, "
                                  "and that asymmetry is the whole reachability argument";
    EXPECT_NE(attempt.message.find("empty \"ip\" array"), std::string::npos) << attempt.message;
    EXPECT_EQ(attempt.vertices, 0u) << "refused without leaving a partial graph (#61)";
}
