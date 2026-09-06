/**
 * FINDINGS #88, W18: the eighth `ip[0]`, in TopologyAndFlowMonitor::updateHosts.
 *
 * [Co-developed with claude code -- Adam]
 *
 * W2 (#88) guarded sixteen `ip.front()` dereferences and its own grep turned up seven more spelled
 * `ip[0]`; W14 guarded those seven and its rescan turned up one more, in the file W2 had spent the
 * most time in:
 *
 *     TopologyAndFlowMonitor.cpp   updateHosts, the attachment switch   SWITCH
 *
 *         auto edgeRevOpt = findEdgeBySrcAndDstIp((*m_graph)[*vertexOpt2].ip[0], ip);
 *
 * It is not new. `git show f0687b34` -- W2's own base -- already has the line. The inventory that
 * called the total sixteen, and then the one that called it twenty-three, both walked past it, so
 * the correct number is TWENTY-FOUR.
 *
 * `operator[]` is not a milder `front()`: libstdc++ defines both as `*(_M_start + n)`, and a
 * default-constructed std::vector has `_M_start == nullptr`, so this binds a reference to a null
 * pointer and reads through it.
 *
 * WHAT THIS SITE READS, AND WHY IT IS PINNED ANYWAY
 *
 * `vertexOpt2` comes from findSwitchByDpid, so it is always a SWITCH -- the same reachability class
 * as W14's sites 1, 2, 6 and 7, and NOT the class its five HOST sites were in. Every SWITCH vertex
 * comes from loadStaticTopologyFromFile, and both the pre-validation pass and the builder's
 * backstop refuse a SWITCH whose "ip" array is empty (TopologyAndFlowMonitor.cpp, "has an empty
 * \"ip\" array"); updateSwitches creates no vertex for a dpid it has not seen. So no production
 * route to an address-less SWITCH was found, and the fixture below builds the graph with
 * boost::add_vertex rather than claiming one.
 *
 * That is the reason to fix it, not a reason to skip it: the invariant is one `if` in another
 * subsystem, it is younger than the call sites that lean on it, and the same sentence was true of
 * the six other SWITCH-class sites in this finding before someone wrote that `if`. W14's file makes
 * the same argument in the same words.
 *
 * WHY THE FIRST TEST FORKS
 *
 * The failure is a null dereference. On an ordinary build the unfixed code produces no red line --
 * it takes the whole binary down mid-suite, with no `[  FAILED  ]` for anything and no result for
 * any suite that had not run yet. W2's mutation gate scored a mutant SURVIVED for exactly that
 * reason (W2-SUMMARY §4.2). So the site gets a death test, declared before every in-process test in
 * this file, asserting `ExitedWithCode(0)`: the child runs one poll and exits cleanly. On the
 * unfixed code the child dies of SIGSEGV and the parent prints a named red line.
 *
 * WHAT THE OTHER TESTS ARE FOR
 *
 * A guard that stops the crash by dropping the entry has moved the defect rather than fixed it, and
 * this entry carries three separate pieces of work:
 *
 *     the MAC-keyed vertex update      -- not keyed by the switch's address
 *     the host-side edge               -- keyed by the HOST's address
 *     the reverse edge                 -- keyed by (switch address, host address)  <-- only this
 *
 * Only the third one needs the value that is missing, so only the third one may be lost. Two of the
 * mutations in tests/shell/mutate_attachment_switch_index_zero.sh are the same guard hoisted one
 * and two steps too high; each costs a piece of work that had nothing to do with the missing field,
 * and each has its own test here.
 *
 * The fourth in-process test is about the log, because for a void function that only writes the
 * graph the log IS the answer. A substituted 0.0.0.0 does not crash and does not raise a wrong edge
 * in any realistic topology -- what it does is resolve to nothing and hand the operator the
 * "Rev Edge ... not found in static network topology file" line, which says go and edit a file that
 * cannot express this. That test asserts the two identifiers an operator needs and the absence of
 * the misdiagnosis; it deliberately does not assert the prose, and control C3 in the gate is a
 * reworded message that has to stay green.
 */

#include <cstdlib>
#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>
#include <spdlog/sinks/ringbuffer_sink.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Reaches updateHosts, the ingest point for the control plane's `/v1.0/topology/hosts` reply.
/// Same seam as TestableTopologyAndFlowMonitor in test_TopologyAndFlowMonitor.cpp and TestableMonitor
/// in test_OptimisticTopologyReporting.cpp; a third one because both of those are class definitions
/// in other translation units and a same-named class here would be an ODR violation with no
/// diagnostic required.
class AttachmentPollMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void pollHosts(const std::string& reply) { updateHosts(reply); }
};

/**
 * @brief Captures every record the global logger emits while it is alive, at trace level.
 *
 * Same helper as tests/test_CpuReportNoIpSwitch.cpp, tests/test_TopologyPollRound.cpp and
 * tests/test_ApiKeyNotLogged.cpp; duplicated rather than shared for the reason those files give --
 * hoisting it would create a test-support header several suites then have to agree on.
 */
class LogCapture
{
  public:
    LogCapture()
        : m_logger(Logger::instance()),
          m_savedLevel(m_logger->level()),
          m_sink(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(256))
    {
        m_logger->sinks().push_back(m_sink);
        m_logger->set_level(spdlog::level::trace);
    }

    ~LogCapture()
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

    LogCapture(const LogCapture&) = delete;
    LogCapture& operator=(const LogCapture&) = delete;

    std::vector<std::string> records() const { return m_sink->last_formatted(); }

    std::string text() const
    {
        std::string all;
        for (const auto& line : records())
        {
            all += line;
        }
        return all;
    }

    /// The first captured record containing @p token, or an empty string if there is none.
    /// Per-record rather than over the whole text, so a test can assert that two identifiers are
    /// on the SAME line -- two separate substring hits in a poll that logs several things would
    /// not be evidence that either line names both.
    std::string recordContaining(const std::string& token) const
    {
        for (const auto& line : records())
        {
            if (line.find(token) != std::string::npos)
            {
                return line;
            }
        }
        return {};
    }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    spdlog::level::level_enum m_savedLevel;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> m_sink;
};

/// The address-less attachment switch. 4242 rather than a small number because the guard's warning
/// prints it in decimal and the test greps the log for it: "2" would also be a port number, an
/// index and half the hex dpids in the same reply.
constexpr uint64_t kAddresslessDpid = 4242;   ///< 0x1092, as the reply spells it.
constexpr uint64_t kAddressedDpid = 1;

const char* const kHostOnAddresslessSwitchMac = "00:00:00:00:00:11";
const char* const kHostOnAddressedSwitchMac = "00:00:00:00:00:12";
const char* const kHostOnAddresslessSwitchIp = "10.0.0.11";
const char* const kHostOnAddressedSwitchIp = "10.0.0.12";
const char* const kAddressedSwitchIp = "192.168.123.11";

/**
 * @brief One reply naming both attachment switches, applied as one poll.
 *
 * The shape is Ryu's `/v1.0/topology/hosts`: a list of entries, each with `mac`, `ipv4`, `ipv6` and
 * a `port` object whose `dpid` is sixteen hex digits. Both entries are in ONE body on purpose --
 * the control and the defect then travel through the same call, so "the guarded entry still worked"
 * is not a separate run that could have differed for another reason, and a guard that abandons the
 * whole reply rather than one entry is visible immediately.
 */
const char* const kHostsReply = R"([
    {
        "mac": "00:00:00:00:00:11",
        "ipv4": ["10.0.0.11"],
        "ipv6": [],
        "port": {"dpid": "0000000000001092", "port_no": "00000001",
                 "hw_addr": "00:00:00:00:10:92", "name": "s_no_address-eth1"}
    },
    {
        "mac": "00:00:00:00:00:12",
        "ipv4": ["10.0.0.12"],
        "ipv6": [],
        "port": {"dpid": "0000000000000001", "port_no": "00000001",
                 "hw_addr": "00:00:00:00:00:01", "name": "s1-eth1"}
    }
])";

/**
 * @brief Two switches and two hosts, one attachment addressed and one not.
 *
 *   s1            SWITCH  dpid 1     192.168.123.11      h_on_s1   HOST  10.0.0.12  (attached to s1)
 *   s_no_address  SWITCH  dpid 4242  no address          h_on_sx   HOST  10.0.0.11  (attached to it)
 *
 * Four directed edges, as loadStaticTopologyFromFile builds them: a host-side edge whose `src_dpid`
 * is 0 and whose `src_ip` is the host's, and a switch-side edge whose `dst_dpid` is 0 and whose
 * `dst_ip` is the host's. The address-less switch's edges carry an empty address list on the switch
 * end, which is what a topology file declaring `"ip": []` would produce -- an edge key it never had.
 *
 * 🔴 Every vertex and every edge is created DOWN. VertexProperties and EdgeProperties both default
 * `isUp`/`isEnabled` to **true**, so a fixture that leaves them alone makes every "still marked up"
 * assertion below vacuously true no matter what updateHosts does. The loader writes false into both
 * (loadStaticTopologyFromFile, node branch and edge branch) precisely because discovery is what
 * raises them; this fixture does the same.
 */
class AddresslessAttachmentSwitchTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_mutex = std::make_shared<std::shared_mutex>();
        m_bus = std::make_shared<EventBus>();

        m_addressedSwitch = addSwitch("s1", kAddressedDpid, kAddressedSwitchIp);
        m_addresslessSwitch = addSwitchWithoutAddress("s_no_address", kAddresslessDpid);
        m_hostOnAddressless =
            addHost("h_on_sx", kHostOnAddresslessSwitchMac, kHostOnAddresslessSwitchIp);
        m_hostOnAddressed = addHost("h_on_s1", kHostOnAddressedSwitchMac, kHostOnAddressedSwitchIp);

        // h_on_sx <-> s_no_address. The switch end carries no address, in both directions.
        m_hostSideEdgeOfAddresslessSwitch =
            addEdge(m_hostOnAddressless, m_addresslessSwitch, {ipOf(kHostOnAddresslessSwitchIp)}, 0,
                    {}, kAddresslessDpid);
        // The reverse edge exists and NOTHING BELOW ASSERTS ON IT, deliberately. It is here so the
        // graph is the shape a topology file would produce -- without it, "the reverse edge was not
        // raised" would be true of a graph that has no reverse edge to raise, which is not evidence
        // about the guard. Whether an address-less switch's reverse edge SHOULD instead be raised
        // from the host's address alone (findReverseEdgeByHostIp) is an open design question --
        // FIX-ATTACHMENT-SWITCH-INDEX-ZERO.md §3.4 -- and pinning it either way here would turn a
        // preference into a rule.
        (void)addEdge(m_addresslessSwitch, m_hostOnAddressless, {}, kAddresslessDpid,
                      {ipOf(kHostOnAddresslessSwitchIp)}, 0);

        // h_on_s1 <-> s1. The control pair: every key this function needs exists.
        m_hostSideEdgeOfAddressedSwitch =
            addEdge(m_hostOnAddressed, m_addressedSwitch, {ipOf(kHostOnAddressedSwitchIp)}, 0,
                    {ipOf(kAddressedSwitchIp)}, kAddressedDpid);
        m_switchSideEdgeOfAddressedSwitch =
            addEdge(m_addressedSwitch, m_hostOnAddressed, {ipOf(kAddressedSwitchIp)},
                    kAddressedDpid, {ipOf(kHostOnAddressedSwitchIp)}, 0);

        m_monitor =
            std::make_shared<AttachmentPollMonitor>(m_graph, m_mutex, m_bus, utils::MININET);
    }

    static uint32_t ipOf(const std::string& dotted) { return utils::ipStringToUint32(dotted); }

    Graph::vertex_descriptor addSwitch(const std::string& name, uint64_t dpid,
                                       const std::string& ip)
    {
        const auto v = addSwitchWithoutAddress(name, dpid);
        // push_back, never `ip[0] = ...`: VertexProperties::ip is a std::vector that starts empty,
        // so indexed assignment is the very out-of-bounds write this suite is about.
        (*m_graph)[v].ip.push_back(ipOf(ip));
        return v;
    }

    Graph::vertex_descriptor addSwitchWithoutAddress(const std::string& name, uint64_t dpid)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].deviceName = name;
        (*m_graph)[v].bridgeNameForMininet = name;
        (*m_graph)[v].dpid = dpid;
        (*m_graph)[v].isUp = false;
        (*m_graph)[v].isEnabled = false;
        // `ip` left empty on purpose in the no-address case. That is the whole fixture.
        return v;
    }

    Graph::vertex_descriptor addHost(const std::string& name, const std::string& mac,
                                     const std::string& ip)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::HOST;
        (*m_graph)[v].deviceName = name;
        // Parsed with the production converter rather than written as a hex literal: the reply
        // below carries the dotted form, and a literal would let the two drift apart silently.
        (*m_graph)[v].mac = utils::macToUint64(mac);
        (*m_graph)[v].dpid = 0;
        (*m_graph)[v].ip.push_back(ipOf(ip));
        (*m_graph)[v].isUp = false;
        (*m_graph)[v].isEnabled = false;
        return v;
    }

    Graph::edge_descriptor addEdge(Graph::vertex_descriptor from, Graph::vertex_descriptor to,
                                   std::vector<uint32_t> srcIp, uint64_t srcDpid,
                                   std::vector<uint32_t> dstIp, uint64_t dstDpid)
    {
        EdgeProperties ep;
        ep.isUp = false;
        ep.isEnabled = false;
        ep.srcIp = std::move(srcIp);
        ep.srcDpid = srcDpid;
        ep.dstIp = std::move(dstIp);
        ep.dstDpid = dstDpid;
        // srcInterface/dstInterface carry no in-class initialiser, so a default-constructed
        // EdgeProperties leaves them indeterminate. Nothing on this path reads them; written
        // anyway, because "nothing reads it today" is not a property of the struct.
        ep.srcInterface = 0;
        ep.dstInterface = 0;
        const auto added = boost::add_edge(from, to, ep, *m_graph);
        EXPECT_TRUE(added.second) << "the fixture failed to add an edge";
        return added.first;
    }

    bool vertexIsUp(Graph::vertex_descriptor v) const
    {
        std::shared_lock lock(*m_mutex);
        return (*m_graph)[v].isUp;
    }

    bool edgeIsUp(Graph::edge_descriptor e) const
    {
        std::shared_lock lock(*m_mutex);
        return (*m_graph)[e].isUp;
    }

    /// One poll of the reply above, then a clean exit. A member rather than a lambda inside the
    /// macro because EXPECT_EXIT is a macro and a braced list inside one is split on its commas --
    /// the trap test_LoggerCliArgs.cpp records.
    void pollHostsThenExitZero()
    {
        m_monitor->pollHosts(kHostsReply);
        std::exit(0);
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<AttachmentPollMonitor> m_monitor;

    Graph::vertex_descriptor m_addressedSwitch{};
    Graph::vertex_descriptor m_addresslessSwitch{};
    Graph::vertex_descriptor m_hostOnAddressless{};
    Graph::vertex_descriptor m_hostOnAddressed{};

    Graph::edge_descriptor m_hostSideEdgeOfAddresslessSwitch{};
    Graph::edge_descriptor m_hostSideEdgeOfAddressedSwitch{};
    Graph::edge_descriptor m_switchSideEdgeOfAddressedSwitch{};
};

} // namespace

// =================================================================================================
// The site itself, contained. Declared before every in-process test in this file: gtest runs a
// suite's tests in declaration order, and on the unfixed code the tests below take the binary down
// before it can print anything.
// =================================================================================================

TEST_F(AddresslessAttachmentSwitchTest, AnAddresslessAttachmentSwitchDoesNotKillTheProcess)
{
    EXPECT_EXIT(pollHostsThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "updateHosts read `(*m_graph)[*vertexOpt2].ip[0]` on the switch a hosts entry says the "
           "host is attached to. findSwitchByDpid checks the datapath id and nothing else, so "
           "nothing between it and this subscript looks at the address list it indexes.";
}

// =================================================================================================
// What the guarded code does with the rest of the entry. Three pieces of work; only one of them is
// keyed by the address that is missing, so only that one may be lost.
// =================================================================================================

TEST_F(AddresslessAttachmentSwitchTest, TheHostOnAnAddresslessAttachmentSwitchIsStillMarkedUp)
{
    ASSERT_FALSE(vertexIsUp(m_hostOnAddressless)) << "fixture precondition: the loader starts every "
                                                     "vertex down and discovery is what raises it";

    m_monitor->pollHosts(kHostsReply);

    EXPECT_TRUE(vertexIsUp(m_hostOnAddressless))
        << "the host's own liveness is keyed by its MAC, not by its attachment switch's address. A "
           "guard that abandons the entry costs this host every poll for as long as the switch has "
           "no address -- and a host can never be marked down again by anything else (F-14), so "
           "the loss would be permanent.";
}

TEST_F(AddresslessAttachmentSwitchTest,
       TheHostSideEdgeIsStillRaisedWhenTheAttachmentSwitchHasNoAddress)
{
    ASSERT_FALSE(edgeIsUp(m_hostSideEdgeOfAddresslessSwitch)) << "fixture precondition";

    m_monitor->pollHosts(kHostsReply);

    EXPECT_TRUE(edgeIsUp(m_hostSideEdgeOfAddresslessSwitch))
        << "findEdgeByHostIp keys on the HOST's address, which this entry has. The guard belongs "
           "at the one lookup that needs the switch's address, not above this one.";
}

TEST_F(AddresslessAttachmentSwitchTest, TheWarningNamesTheHostAndTheSwitchAndNotTheTopologyFile)
{
    LogCapture log;
    m_monitor->pollHosts(kHostsReply);

    const std::string warning = log.recordContaining(std::to_string(kAddresslessDpid));
    ASSERT_FALSE(warning.empty())
        << "nothing in the log named dpid " << kAddresslessDpid
        << ". This function returns void and writes only the graph, so the log is the whole answer: "
           "an operator who never hears that a switch carries no address sees a host-side edge come "
           "up and its reverse stay down, with nothing to connect the two.\n"
        << log.text();

    EXPECT_NE(warning.find(kHostOnAddresslessSwitchMac), std::string::npos)
        << "the same line has to name the host, or it cannot be acted on: " << warning;

    EXPECT_EQ(log.text().find("Rev Edge"), std::string::npos)
        << "\"Rev Edge (host ...) not found in static network topology file\" is the line a "
           "SUBSTITUTED address produces -- the lookup resolves to nothing and the caller is told "
           "to go and edit a file that cannot express this. An address the switch does not have is "
           "not an edge key any file could have written.\n"
        << log.text();
}

// =================================================================================================
// Controls. Without these, "the mutation was caught" would also be produced by a guard that turned
// updateHosts into a function that does nothing.
// =================================================================================================

TEST_F(AddresslessAttachmentSwitchTest, TheReverseEdgeOfAnAddressedAttachmentSwitchIsStillRaised)
{
    ASSERT_FALSE(edgeIsUp(m_switchSideEdgeOfAddressedSwitch)) << "fixture precondition";

    m_monitor->pollHosts(kHostsReply);

    EXPECT_TRUE(edgeIsUp(m_switchSideEdgeOfAddressedSwitch))
        << "s1 has an address, so its reverse edge is exactly the lookup this function is for. A "
           "guard that skips the lookup for everybody satisfies every assertion above and deletes "
           "the feature.";
}

TEST_F(AddresslessAttachmentSwitchTest, TheOtherHostAndItsEdgeAreUntouchedByTheGuardedEntry)
{
    m_monitor->pollHosts(kHostsReply);

    // The second control, and the reason both entries are in one reply: the address-less entry is
    // FIRST, so a guard written as a `return` rather than a `continue`, or a fault that escaped to
    // the function-level catch, costs everything after it and nothing here would otherwise say so.
    EXPECT_TRUE(vertexIsUp(m_hostOnAddressed))
        << "the entry after the guarded one was never applied";
    EXPECT_TRUE(edgeIsUp(m_hostSideEdgeOfAddressedSwitch))
        << "the entry after the guarded one was never applied";
}
