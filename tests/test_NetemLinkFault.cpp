/**
 * @file test_NetemLinkFault.cpp
 * @brief doc/KNOWN-ISSUES.md B-6, second half: cutting a link with netem without destroying the
 *        interface's shaping, and putting it back.
 *
 * [Co-developed with claude code -- Adam]
 *
 * ## What is being pinned, and why it is not "we called tc"
 *
 * The defect this code exists to avoid is not "tc failed". It is "tc succeeded and silently
 * replaced the thing under it". On a TCLink interface the root qdisc is htb; `tc qdisc add dev X
 * root netem loss 100%` REPLACES it, so the experiment's bandwidth shaping is gone, and `tc qdisc
 * del dev X root` then restores the KERNEL DEFAULT rather than htb. Both commands report success.
 * The usual teardown check -- "no netem residue" -- passes. The 2026-08-13 overnight OVS round was
 * lost to exactly that, and tools/test_workflow/faults.sh carries the rule that came out of it.
 *
 * So the property under test is WHERE the netem is attached, as a function of what the live qdisc
 * tree says, and the tests feed real `tc qdisc show` output -- shaped, unshaped, already-cut,
 * unreadable -- to a fake runner and assert the argv that comes out. A test that ran real tc would
 * need root and a Mininet fabric, and would still not be able to assert the interesting case
 * (an htb-shaped interface) on a machine where nothing is shaped.
 *
 * The fake also gives the negative controls their teeth: `refuses` cases assert that NO add
 * command reached the runner at all, which is the only way to state "it declined" rather than "it
 * tried and something went wrong".
 */

#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "utils/NetemLinkFault.hpp"

namespace
{

using utils::netem::TcOutcome;

/// Answers `tc qdisc show` from a script and records every argv it is given.
class FakeTc
{
  public:
    /// What `qdisc show` returns, in order. The last one is repeated once the list runs out, so a
    /// test that only cares about the before-tree does not have to write the after-tree twice.
    std::vector<std::string> showReplies;

    /// Non-zero makes every command fail, which is what `sudo -n` being refused looks like.
    int status = 0;

    std::vector<std::vector<std::string>> calls;

    utils::netem::TcRunner runner()
    {
        return [this](const std::vector<std::string>& args) {
            calls.push_back(args);
            if (args.size() >= 2 && args[1] == "show")
            {
                std::string body;
                if (!showReplies.empty())
                {
                    body = m_shown < showReplies.size() ? showReplies[m_shown]
                                                        : showReplies.back();
                    ++m_shown;
                }
                return TcOutcome{true, status, body};
            }
            return TcOutcome{true, status, ""};
        };
    }

    /// Whether any command that CHANGES the tree was issued. `show` does not count.
    bool ranAnyWrite() const
    {
        for (const auto& c : calls)
        {
            if (c.size() >= 2 && (c[1] == "add" || c[1] == "del")) return true;
        }
        return false;
    }

    /// The first add/del argv, rendered for an assertion message.
    std::vector<std::string> firstWrite() const
    {
        for (const auto& c : calls)
        {
            if (c.size() >= 2 && (c[1] == "add" || c[1] == "del")) return c;
        }
        return {};
    }

  private:
    std::size_t m_shown = 0;
};

/// A TCLink interface: htb at the root, one class. This is what every Mininet link in this
/// repository's topologies looks like, and the one the defect is about.
constexpr const char* kShaped =
    "qdisc htb 5: root refcnt 2 r2q 10 default 0x1 direct_packets_stat 0 direct_qlen 1000\n";

/// An unshaped interface. `root` is correct here, and this is why the P4 runbook's recipe works.
constexpr const char* kUnshaped = "qdisc noqueue 0: root refcnt 2\n";

/// The shaped interface after this code has cut it.
constexpr const char* kShapedWithNetem =
    "qdisc htb 5: root refcnt 2 r2q 10 default 0x1 direct_packets_stat 0 direct_qlen 1000\n"
    "qdisc netem 8001: parent 5:1 limit 1000 loss 100%\n";

/// The unshaped interface after this code has cut it.
constexpr const char* kUnshapedWithNetem =
    "qdisc netem 8001: root refcnt 2 limit 1000 loss 100%\n";

} // namespace

// --- where netem may be attached -----------------------------------------------------------------

/**
 * 🔴 THE FINDING. On a shaped interface the attach point must be the htb default class. Attaching
 * at `root` here is the 2026-08-13 defect: it reports success, removes the shaping, and no
 * teardown check in the repository can see that it happened.
 */
TEST(NetemLinkFaultTest, AShapedInterfaceIsCutUnderTheShaperNotOverIt)
{
    const auto plan = utils::netem::planAttach(kShaped);

    ASSERT_TRUE(plan.safe) << plan.why;
    ASSERT_EQ(plan.tcArgs.size(), 2u);
    EXPECT_EQ(plan.tcArgs[0], "parent");
    EXPECT_EQ(plan.tcArgs[1], "5:0x1")
        << "netem must hang off htb's default class; `root` would replace the shaper and `del "
           "root` would then restore the kernel default rather than htb";
}

/// The other half: on an unshaped interface `root` is right, and refusing there would make this
/// endpoint useless on every P4 fabric.
TEST(NetemLinkFaultTest, AnUnshapedInterfaceIsCutAtTheRoot)
{
    const auto plan = utils::netem::planAttach(kUnshaped);

    ASSERT_TRUE(plan.safe) << plan.why;
    ASSERT_EQ(plan.tcArgs.size(), 1u);
    EXPECT_EQ(plan.tcArgs[0], "root");
}

/// Residue from an earlier round. Stacking a second netem makes the restore ambiguous -- there
/// would be no way to tell which one this call attached -- so the answer is a refusal.
TEST(NetemLinkFaultTest, AnInterfaceThatAlreadyCarriesNetemIsRefused)
{
    const auto plan = utils::netem::planAttach(kShapedWithNetem);

    EXPECT_FALSE(plan.safe)
        << "a second netem was stacked onto an interface that already had one; the restore can no "
           "longer tell them apart and the next round inherits the residue";
    EXPECT_NE(plan.why.find("already"), std::string::npos) << plan.why;
}

/// An empty tree means the interface does not exist, or `tc` could not read it. Either way there is
/// nothing to reason about, and guessing `root` would be attaching to whatever appears later.
TEST(NetemLinkFaultTest, AnUnreadableTreeIsRefusedRatherThanGuessed)
{
    EXPECT_FALSE(utils::netem::planAttach("").safe);
    EXPECT_FALSE(utils::netem::planAttach("\n  \n").safe);
}

/// htb with no `default` in its root line: there is no class to hang off, so the only thing left
/// would be the destructive form. Refuse.
TEST(NetemLinkFaultTest, ShapedWithNoDefaultClassIsRefused)
{
    const auto plan = utils::netem::planAttach("qdisc htb 5: root refcnt 2 r2q 10\n");

    EXPECT_FALSE(plan.safe) << "there is no safe attach point, and the unsafe one is the defect";
}

// --- where the netem to remove is --------------------------------------------------------------

/// Restore reads the LIVE tree instead of remembering where it attached, so that a recovery still
/// works after the kernel process has been restarted.
TEST(NetemLinkFaultTest, TheNetemToRemoveIsFoundAtItsParent)
{
    const auto at = utils::netem::findExistingNetem(kShapedWithNetem);

    ASSERT_TRUE(at.safe) << at.why;
    ASSERT_EQ(at.tcArgs.size(), 2u);
    EXPECT_EQ(at.tcArgs[0], "parent");
    EXPECT_EQ(at.tcArgs[1], "5:1");
}

TEST(NetemLinkFaultTest, ARootNetemIsFoundAtTheRoot)
{
    const auto at = utils::netem::findExistingNetem(kUnshapedWithNetem);

    ASSERT_TRUE(at.safe) << at.why;
    ASSERT_EQ(at.tcArgs.size(), 1u);
    EXPECT_EQ(at.tcArgs[0], "root");
}

TEST(NetemLinkFaultTest, ACleanTreeHasNoNetemToRemove)
{
    EXPECT_FALSE(utils::netem::findExistingNetem(kShaped).safe);
}

// --- the interface name ---------------------------------------------------------------------------

/**
 * The name is derived from the topology file's `bridge_name`, and it is checked before tc runs.
 * Not as an escaping measure -- nothing here builds a command line, so a name is never shell input
 * -- but because a name outside `s<N>-eth<M>` is outside this machine's NOPASSWD grant, and the
 * failure mode is then a password prompt the kernel cannot answer, reported as a generic tc error.
 */
TEST(NetemLinkFaultTest, OnlyMininetSwitchInterfaceNamesAreAccepted)
{
    EXPECT_TRUE(utils::netem::isMininetInterfaceName("s1-eth1"));
    EXPECT_TRUE(utils::netem::isMininetInterfaceName("s10-eth24"));

    EXPECT_FALSE(utils::netem::isMininetInterfaceName("eth0"));
    EXPECT_FALSE(utils::netem::isMininetInterfaceName("h1-eth0")) << "a host's interface";
    EXPECT_FALSE(utils::netem::isMininetInterfaceName("s1-eth")) << "no port number";
    EXPECT_FALSE(utils::netem::isMininetInterfaceName("s-eth1")) << "no switch number";
    EXPECT_FALSE(utils::netem::isMininetInterfaceName("s1-eth1x"));
    EXPECT_FALSE(utils::netem::isMininetInterfaceName(""));
}

TEST(NetemLinkFaultTest, TheInterfaceNameIsTheBridgeAndThePort)
{
    EXPECT_EQ(utils::netem::mininetInterfaceName("s3", 7), "s3-eth7");
}

// --- the two operations, end to end against a fake tc --------------------------------------------

TEST(NetemLinkFaultTest, CuttingAShapedInterfaceIssuesTheParentForm)
{
    FakeTc tc;
    tc.showReplies = {kShaped, kShapedWithNetem};

    const auto report = utils::netem::cutInterface("s1-eth1", "100%", tc.runner());

    EXPECT_TRUE(report.value("ok", false)) << report.dump();
    const auto write = tc.firstWrite();
    ASSERT_FALSE(write.empty()) << "nothing was attached at all";
    EXPECT_EQ(utils::describeArgv(write), "qdisc add dev s1-eth1 parent 5:0x1 netem loss 100%");
    EXPECT_EQ(report.value("attached_at", ""), "parent 5:0x1");
}

TEST(NetemLinkFaultTest, CuttingARefusedInterfaceRunsNoCommandAtAll)
{
    FakeTc tc;
    tc.showReplies = {kShapedWithNetem}; // already cut

    const auto report = utils::netem::cutInterface("s1-eth1", "100%", tc.runner());

    EXPECT_FALSE(report.value("ok", true));
    EXPECT_TRUE(report.contains("refused")) << report.dump();
    EXPECT_FALSE(tc.ranAnyWrite())
        << "a refusal that still ran tc is not a refusal: " << utils::describeArgv(tc.firstWrite());
}

/// A name the twin could not have derived from a Mininet bridge never reaches tc. This is the case
/// that stops a topology file with an unexpected `bridge_name` from cutting an interface that
/// belongs to something else entirely.
TEST(NetemLinkFaultTest, ABadInterfaceNameNeverReachesTc)
{
    FakeTc tc;
    tc.showReplies = {kUnshaped};

    const auto report = utils::netem::cutInterface("eth0", "100%", tc.runner());

    EXPECT_FALSE(report.value("ok", true));
    EXPECT_TRUE(tc.calls.empty()) << "tc was invoked for an interface outside the sudo grant";
}

/// `sudo -n` refused, or the interface is gone. Reported, and nothing is attached on top of a tree
/// that could not be read.
TEST(NetemLinkFaultTest, AnUnreadableTreeStopsTheCut)
{
    FakeTc tc;
    tc.showReplies = {""};
    tc.status = 1;

    const auto report = utils::netem::cutInterface("s1-eth1", "100%", tc.runner());

    EXPECT_FALSE(report.value("ok", true));
    EXPECT_TRUE(report.contains("error")) << report.dump();
    EXPECT_FALSE(tc.ranAnyWrite());
}

TEST(NetemLinkFaultTest, RestoringDeletesTheNetemWhereItActuallyIs)
{
    FakeTc tc;
    tc.showReplies = {kShapedWithNetem, kShaped};

    const auto report = utils::netem::restoreInterface("s1-eth1", tc.runner());

    EXPECT_TRUE(report.value("ok", false)) << report.dump();
    EXPECT_EQ(utils::describeArgv(tc.firstWrite()), "qdisc del dev s1-eth1 parent 5:1")
        << "the delete must name the parent the netem is on, so that htb survives it";
    EXPECT_EQ(report.value("qdisc_after", ""), kShaped)
        << "the shaper must still be there once the netem is gone";
}

/// Idempotent on purpose: a caller must be able to bring a fabric back to health without knowing
/// exactly what was done to it, and "there was nothing to undo" is not a failure.
TEST(NetemLinkFaultTest, RestoringACleanInterfaceIsANoopNotAnError)
{
    FakeTc tc;
    tc.showReplies = {kShaped};

    const auto report = utils::netem::restoreInterface("s1-eth1", tc.runner());

    EXPECT_TRUE(report.value("ok", false)) << report.dump();
    EXPECT_TRUE(report.contains("noop"));
    EXPECT_FALSE(tc.ranAnyWrite());
}

/**
 * 🔴 The check faults.sh makes with a whole-tree diff, made here on the interface this call
 * touched. A delete that reports success while netem is still attached is the exact shape of the
 *2026-08-13 loss: the tool says it cleaned up, the next round starts dirty, and its numbers are
 * about a network nobody described.
 */
TEST(NetemLinkFaultTest, ARestoreThatLeftNetemBehindIsReportedAsAFailure)
{
    FakeTc tc;
    tc.showReplies = {kShapedWithNetem, kShapedWithNetem}; // the delete did not take

    const auto report = utils::netem::restoreInterface("s1-eth1", tc.runner());

    EXPECT_FALSE(report.value("ok", true))
        << "a restore that left the fault in place reported success";
    EXPECT_TRUE(report.contains("error")) << report.dump();
}

// =================================================================================================
// doc/KNOWN-ISSUES.md B-6 (W8-4): the startup sweep.
//
// [Co-developed with claude code -- Adam]
//
// WHAT THE GAP WAS
//
// A declaration lives in this process; the `tc netem` that accompanies it lives in the machine's
// qdisc tree. `EdgeProperties::declaredDown` is deliberately not read back from any file, so a
// kernel restart forgets every standing declaration -- and the netem does not go with it. The
// graph then reports a clean `down_reason: "none"` for a link on which 100% of packets are being
// dropped, and nothing anywhere says otherwise. Raised as W8 §7-4; Adam ruled on 2026-09-06:
// **sweep the qdisc tree once at startup and WARN. Do not clear it, and do not turn it into a
// declaration.**
//
// WHY NOT CLEAR IT: tools/test_workflow/faults.sh is entitled to have netem on an interface, and
// a kernel that removed a fault it did not create would destroy whatever experiment did.
// WHY NOT DECLARE IT: inventing a declaration from a qdisc reading is the twin manufacturing its
// own evidence -- and the reading cannot say which of the pair's two directions was meant.
//
// These drive the real method with a fake tc, so what is asserted is the sentence an operator
// reads and the set of interfaces it names.
// =================================================================================================

#include <algorithm>
#include <map>
#include <memory>
#include <set>
#include <shared_mutex>

#include <boost/graph/adjacency_list.hpp>
#include <spdlog/sinks/ringbuffer_sink.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"

namespace
{

/**
 * @brief Captures every record the global logger emits while it is alive, at trace level.
 *
 * Restores the logger's previous level and sink list on destruction, so the rest of the suite runs
 * against the `off` level test_LoggerEnvironment installed. Same helper as
 * tests/test_TopologyPollRound.cpp and tests/test_ApiKeyNotLogged.cpp; duplicated rather than
 * shared for the reason written there -- hoisting it would create a test-support header several
 * files then have to agree on.
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

    std::string text() const
    {
        std::string all;
        for (const auto& line : m_sink->last_formatted())
        {
            all += line;
        }
        return all;
    }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    spdlog::level::level_enum m_savedLevel;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> m_sink;
};

/// Answers `tc qdisc show dev X` from a table keyed by INTERFACE, not by call order: the sweep
/// visits the graph's edges and this fixture must not depend on boost's iteration order to decide
/// which tree each interface gets.
class FakeTcByInterface
{
  public:
    std::map<std::string, std::string> trees;

    /// Interfaces whose `tc qdisc show` fails, as `sudo -n` being refused looks like.
    std::set<std::string> unreadable;

    std::vector<std::string> shown;

    utils::netem::TcRunner runner()
    {
        return [this](const std::vector<std::string>& args) {
            // {"qdisc","show","dev","<iface>"}
            const std::string iface = args.size() >= 4 ? args[3] : std::string{};
            if (args.size() >= 2 && args[1] == "show")
            {
                shown.push_back(iface);
                if (unreadable.count(iface))
                {
                    return utils::netem::TcOutcome{true, 1, ""};
                }
                const auto it = trees.find(iface);
                return utils::netem::TcOutcome{
                    true, 0, it == trees.end() ? std::string{kUnshaped} : it->second};
            }
            // 🔴 Anything that is not a `show` is a WRITE, and this sweep must never issue one.
            wrote.push_back(args);
            return utils::netem::TcOutcome{true, 0, ""};
        };
    }

    std::vector<std::vector<std::string>> wrote;
};

/// Two switches wired s1:1 <-> s5:1 and s1:2 <-> s7:3, one host hanging off s1:9, and one switch
/// the topology file gave no bridge_name. Small, and every exclusion the sweep makes is in it.
class ResidualNetemSweepTest : public ::testing::Test
{
  protected:
    void SetUp() override { build(utils::MININET); }

    void build(utils::DeploymentMode mode)
    {
        m_graph = std::make_shared<Graph>();
        m_mutex = std::make_shared<std::shared_mutex>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(
            m_graph, m_mutex, std::make_shared<EventBus>(), mode);

        const auto s1 = addSwitch(1, "s1");
        const auto s5 = addSwitch(5, "s5");
        const auto s7 = addSwitch(7, "s7");
        const auto nameless = addSwitch(8, ""); // no bridge_name in the topology file
        const auto h1 = addHost();

        addEdge(s1, s5, 1, 5, 1, 1);
        addEdge(s5, s1, 5, 1, 1, 1);
        addEdge(s1, s7, 1, 7, 2, 3);
        addEdge(s7, s1, 7, 1, 3, 2);
        addEdge(s1, h1, 1, 0, 9, 1);
        addEdge(h1, s1, 0, 1, 1, 9);
        addEdge(s5, nameless, 5, 8, 4, 4);
        addEdge(nameless, s5, 8, 5, 4, 4);
    }

    Graph::vertex_descriptor addSwitch(uint64_t dpid, const std::string& bridge)
    {
        VertexProperties vp;
        vp.vertexType = VertexType::SWITCH;
        vp.dpid = dpid;
        vp.isUp = true;
        vp.isEnabled = true;
        vp.deviceName = bridge.empty() ? "unnamed" : bridge;
        vp.bridgeNameForMininet = bridge;
        return boost::add_vertex(vp, *m_graph);
    }

    Graph::vertex_descriptor addHost()
    {
        VertexProperties vp;
        vp.vertexType = VertexType::HOST;
        vp.dpid = 0;
        vp.isUp = true;
        vp.deviceName = "h1";
        return boost::add_vertex(vp, *m_graph);
    }

    void addEdge(Graph::vertex_descriptor u,
                 Graph::vertex_descriptor v,
                 uint64_t srcDpid,
                 uint64_t dstDpid,
                 uint32_t srcPort,
                 uint32_t dstPort)
    {
        EdgeProperties ep;
        ep.srcDpid = srcDpid;
        ep.dstDpid = dstDpid;
        ep.srcInterface = srcPort;
        ep.dstInterface = dstPort;
        ep.isUp = true;
        ep.isEnabled = true;
        boost::add_edge(u, v, ep, *m_graph);
    }

    static bool contains(const std::vector<std::string>& v, const std::string& s)
    {
        return std::find(v.begin(), v.end(), s) != v.end();
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
};

} // namespace

/// The set the sweep reads is exactly the set /ndt/inject_link_failure can write to: both ends of
/// every switch-to-switch link, and nothing else. A wider sweep would report residue this kernel
/// could not have made; a narrower one would miss half of every cut, which is applied to both ends.
TEST_F(ResidualNetemSweepTest, TheSweepCoversBothEndsOfEverySwitchToSwitchLinkAndNothingElse)
{
    const auto ifaces = m_monitor->mininetLinkInterfaces();

    EXPECT_TRUE(contains(ifaces, "s1-eth1")) << "the near end of s1 <-> s5 was not swept";
    EXPECT_TRUE(contains(ifaces, "s5-eth1")) << "the far end of s1 <-> s5 was not swept -- a cut "
                                                "attaches netem to BOTH ends";
    EXPECT_TRUE(contains(ifaces, "s1-eth2"));
    EXPECT_TRUE(contains(ifaces, "s7-eth3"));
    // s5 <-> s8, where s8 has no bridge_name: the END THIS GRAPH CAN NAME is still swept, exactly
    // as /ndt/inject_link_failure still cuts the end it can name and refuses only the other.
    EXPECT_TRUE(contains(ifaces, "s5-eth4"));

    EXPECT_FALSE(contains(ifaces, "s1-eth9"))
        << "a host-facing interface was swept; no link endpoint can address a host edge (W8-7), "
           "so residue there is not this kernel's and naming an owner for it would be a guess";
    for (const auto& iface : ifaces)
    {
        EXPECT_NE(iface.rfind("s8-", 0), 0u)
            << "the sweep invented an interface name for a switch the topology file gave no "
               "bridge_name: " << iface;
    }
    EXPECT_EQ(ifaces.size(), 5u)
        << "the sweep named an interface the graph cannot justify -- a switch with no bridge_name "
           "must be skipped rather than guessed at";
}

/**
 * 🔴 THE FINDING. netem is on the fabric before this kernel has injected anything, and the one
 * line an operator gets must name the interfaces. Without it a restarted kernel reports a clean
 * graph over a link that is dropping every packet.
 */
TEST_F(ResidualNetemSweepTest, ResidualNetemIsNamedInOneWarningAtStartup)
{
    FakeTcByInterface tc;
    tc.trees["s1-eth1"] = kShapedWithNetem;
    tc.trees["s5-eth1"] = kUnshapedWithNetem;

    LogCapture log;
    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    ASSERT_EQ(found.size(), 2u) << "the sweep did not find the netem that is there";
    EXPECT_TRUE(contains(found, "s1-eth1"));
    EXPECT_TRUE(contains(found, "s5-eth1"));

    const auto text = log.text();
    EXPECT_NE(text.find("s1-eth1"), std::string::npos)
        << "the startup sweep found residual netem and said nothing an operator could act on. A "
           "kernel restart forgets standing declarations and the tc qdisc that accompanied one "
           "outlives it, so with no warning the graph's clean down_reason is the only thing "
           "anybody reads (B-6, W8-4). Log was:\n"
        << text;
    EXPECT_NE(text.find("s5-eth1"), std::string::npos)
        << "the warning named one end of the cut and not the other:\n"
        << text;
}

/// 🔴 Adam's ruling, the half a fix is most likely to overshoot: WARN, do not clear. A kernel that
/// removed netem at startup would silently destroy any fault campaign it started underneath.
TEST_F(ResidualNetemSweepTest, TheSweepNeverRunsACommandThatChangesTheTree)
{
    FakeTcByInterface tc;
    tc.trees["s1-eth1"] = kShapedWithNetem;
    tc.trees["s5-eth1"] = kUnshapedWithNetem;

    LogCapture log;
    m_monitor->warnAboutResidualNetem(tc.runner());

    ASSERT_TRUE(tc.wrote.empty())
        << "the startup sweep ran a command that changes the qdisc tree; it is allowed to read "
           "and to complain, and nothing else";
}

/// The other half of the same ruling: the reading must not become a declaration. Manufacturing one
/// from a qdisc tree would make the twin its own witness -- and the tree cannot say which
/// direction of the pair anybody meant.
TEST_F(ResidualNetemSweepTest, TheSweepDoesNotDeclareTheLinkDown)
{
    FakeTcByInterface tc;
    tc.trees["s1-eth1"] = kShapedWithNetem;
    tc.trees["s5-eth1"] = kUnshapedWithNetem;

    LogCapture log;
    m_monitor->warnAboutResidualNetem(tc.runner());

    const auto e = m_monitor->findEdgeBySrcAndDstDpid({1, 5});
    ASSERT_TRUE(e.has_value());
    EXPECT_FALSE(m_monitor->getEdgeDeclaredDown(*e))
        << "the sweep declared a link failed on the strength of a qdisc reading";
    std::shared_lock lock(*m_mutex);
    EXPECT_TRUE((*m_graph)[*e].isUp) << "the sweep took an edge down";
}

/// Direction 2: a clean fabric must produce no warning at all. A sweep that cried residue every
/// time would be turned off within a week, and then the case above would never be read.
TEST_F(ResidualNetemSweepTest, ACleanFabricProducesNoWarning)
{
    FakeTcByInterface tc; // every interface answers kUnshaped
    LogCapture log;

    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    EXPECT_TRUE(found.empty());
    EXPECT_EQ(log.text().find("netem is already attached"), std::string::npos)
        << "a clean fabric was reported as dirty:\n"
        << log.text();
    EXPECT_EQ(tc.shown.size(), 5u) << "the sweep did not read every link interface";
}

/**
 * A shaped interface with no netem is the ordinary Mininet TCLink case. Reporting htb as residue
 * would fire on every OVS fabric in this repository and make the warning worthless.
 */
TEST_F(ResidualNetemSweepTest, TCLinkShapingOnItsOwnIsNotResidue)
{
    FakeTcByInterface tc;
    for (const auto& iface : m_monitor->mininetLinkInterfaces())
    {
        tc.trees[iface] = kShaped;
    }
    LogCapture log;

    EXPECT_TRUE(m_monitor->warnAboutResidualNetem(tc.runner()).empty())
        << "htb was reported as a leftover fault";
}

/**
 * 🔴 "Could not read" is not "clean". An interface whose tree cannot be read (sudo -n refused, the
 * interface gone) is the one case this sweep has no opinion about, and saying nothing there would
 * make silence mean two different things.
 */
TEST_F(ResidualNetemSweepTest, AnUnreadableInterfaceIsReportedAsUnreadNotAsClean)
{
    FakeTcByInterface tc;
    tc.unreadable = {"s1-eth1"};
    LogCapture log;

    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    EXPECT_TRUE(found.empty()) << "an unreadable tree was counted as a finding";
    const auto text = log.text();
    EXPECT_NE(text.find("s1-eth1"), std::string::npos)
        << "an interface the sweep could not read was passed over in silence, which makes a "
           "clean report indistinguishable from an unattempted one:\n"
        << text;
}

/// A testbed deployment has no Mininet interfaces at all, and running tc against the names this
/// graph would produce would be a fault injected on whatever answers to them.
TEST_F(ResidualNetemSweepTest, ATestbedDeploymentRunsNoTcAtAll)
{
    build(utils::TESTBED);
    FakeTcByInterface tc;
    tc.trees["s1-eth1"] = kUnshapedWithNetem;
    LogCapture log;

    EXPECT_TRUE(m_monitor->warnAboutResidualNetem(tc.runner()).empty());
    EXPECT_TRUE(tc.shown.empty())
        << "the sweep ran tc on a deployment that has no Mininet interfaces";
}
