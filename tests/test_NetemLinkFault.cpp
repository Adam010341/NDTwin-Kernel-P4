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
#include <optional>
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

/// One line of a WHOLE-MACHINE `tc qdisc show` -- the bare, no-`dev` form, which names the
/// interface inside each line. The shape is taken from tests/shell/test_faults.sh and
/// tests/shell/test_qdisc_snapshot.sh, whose fixtures were captured from live output.
std::string
netemLine(const std::string& dev)
{
    return "qdisc netem 10: dev " + dev + " parent 5:1 limit 1000 loss 100%\n";
}

/// A TCLink-shaped interface with no netem: the ordinary state of every Mininet link here.
std::string
htbLine(const std::string& dev)
{
    return "qdisc htb 5: dev " + dev + " root refcnt 2 r2q 10 default 0x1 direct_packets_stat 0\n";
}

/// What the root namespace of the machine this repository runs on carries anyway. Captured from
/// `tc qdisc show` on 2026-09-07 (no sudo -- reading the tree needs no privilege).
constexpr const char* kMachineNoise =
    "qdisc noqueue 0: dev lo root refcnt 2 \n"
    "qdisc noqueue 0: dev wlp0s20f3 root refcnt 2 \n"
    "qdisc noqueue 0: dev docker0 root refcnt 2 \n"
    "qdisc noqueue 0: dev veth11f0754 root refcnt 2 \n";

/**
 * @brief Answers the ONE `tc qdisc show` the sweep issues, and records every argv it was given.
 *
 * E-20 replaced a per-interface fake with this one on purpose. A fake still keyed by interface
 * would answer a question the sweep no longer asks, and could not express the property the ticket
 * is about: residue on an interface the graph does not name at all.
 */
class FakeMachineTc
{
  public:
    /// What `tc qdisc show` prints for the whole namespace.
    std::string tree = kMachineNoise;

    /// False makes the read fail, which is what `sudo -n` being refused or a missing tc looks like.
    bool readable = true;

    std::vector<std::vector<std::string>> calls;

    utils::netem::TcRunner runner()
    {
        return [this](const std::vector<std::string>& args) {
            calls.push_back(args);
            if (args.size() >= 2 && args[1] == "show")
            {
                if (!readable)
                {
                    return utils::netem::TcOutcome{true, 1, ""};
                }
                if (args.size() >= 4 && args[2] == "dev")
                {
                    return utils::netem::TcOutcome{true, 0, perDevice(args[3])};
                }
                return utils::netem::TcOutcome{true, 0, tree};
            }
            return utils::netem::TcOutcome{true, 0, ""};
        };
    }

    /**
     * @brief What `tc qdisc show dev X` prints: the lines naming X, with the `dev X` words gone.
     *
     * 🔴 THIS FIDELITY IS LOAD-BEARING, and the gate is what proved it. The first run of
     * mutate_withdrawal_needs_observed_failure.sh against E-20 scored M17 -- "the sweep clears the
     * netem it finds", the over-correction Adam ruled against by name -- as a SURVIVOR, because
     * this fake used to answer the whole-machine tree to a per-device question. The mutant calls
     * utils::netem::restoreInterface(), which parses the PER-DEVICE form; handed the whole-machine
     * form it could not read an attach point, returned a no-op, and issued no tc write at all. The
     * fake made a real defect look harmless. Real tc drops those two words, so this does too.
     */
    std::string perDevice(const std::string& dev) const
    {
        std::string out;
        for (const auto& line : utils::netem::qdiscLines(tree))
        {
            const auto w = utils::netem::splitWords(line);
            std::string kept;
            bool named = false;
            for (std::size_t i = 0; i < w.size(); ++i)
            {
                if (w[i] == "dev" && i + 1 < w.size())
                {
                    if (w[i + 1] == dev) named = true;
                    ++i; // the device name goes with the word that introduces it
                    continue;
                }
                if (!kept.empty()) kept += ' ';
                kept += w[i];
            }
            if (named)
            {
                out += kept;
                out += '\n';
            }
        }
        return out;
    }

    /// 🔴 Anything that is not a `show` is a WRITE, and this sweep must never issue one.
    std::vector<std::vector<std::string>> writes() const
    {
        std::vector<std::vector<std::string>> out;
        for (const auto& c : calls)
        {
            if (c.size() < 2 || c[1] != "show") out.push_back(c);
        }
        return out;
    }
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

    /// The interfaces a sweep result names, in the order it reported them.
    static std::vector<std::string> namesOf(const std::vector<ResidualNetem>& found)
    {
        std::vector<std::string> out;
        for (const auto& hit : found) out.push_back(hit.interface);
        return out;
    }

    /// What the sweep decided @p iface is. Absent means it was not reported at all, which is a
    /// different failure from being reported under the wrong heading -- so it gets its own value.
    static std::optional<SweptInterface> kindOf(const std::vector<ResidualNetem>& found,
                                                const std::string& iface)
    {
        for (const auto& hit : found)
        {
            if (hit.interface == iface) return hit.kind;
        }
        return std::nullopt;
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
};

} // namespace

/// Both ends of every switch-to-switch link, and nothing else: exactly the set
/// /ndt/inject_link_failure can write to. Since E-20 this is no longer the sweep's SCOPE -- it is
/// the sweep's `link` classifier, and a host-facing port must not fall into it or the warning
/// would tell an operator to POST /ndt/inject_link_recovery for a link that does not exist.
TEST_F(ResidualNetemSweepTest, TheSweepCoversBothEndsOfEverySwitchToSwitchLinkAndNothingElse)
{
    const auto ifaces = m_monitor->mininetLinkInterfaces();

    EXPECT_TRUE(contains(ifaces, "s1-eth1")) << "the near end of s1 <-> s5 is not classed a link";
    EXPECT_TRUE(contains(ifaces, "s5-eth1")) << "the far end of s1 <-> s5 is not classed a link -- "
                                                "a cut attaches netem to BOTH ends";
    EXPECT_TRUE(contains(ifaces, "s1-eth2"));
    EXPECT_TRUE(contains(ifaces, "s7-eth3"));
    // s5 <-> s8, where s8 has no bridge_name: the END THIS GRAPH CAN NAME is still a link end,
    // exactly as /ndt/inject_link_failure still cuts the end it can name and refuses only the other.
    EXPECT_TRUE(contains(ifaces, "s5-eth4"));

    EXPECT_FALSE(contains(ifaces, "s1-eth9"))
        << "a host-facing interface was classed as a link end; no link endpoint can address a host "
           "edge (W8-7), so the recovery this warning points at could not take it back";
    for (const auto& iface : ifaces)
    {
        EXPECT_NE(iface.rfind("s8-", 0), 0u)
            << "an interface name was invented for a switch the topology file gave no "
               "bridge_name: " << iface;
    }
    EXPECT_EQ(ifaces.size(), 5u)
        << "the link set names an interface the graph cannot justify -- a switch with no "
           "bridge_name must be skipped rather than guessed at";
}

/// 🆕 E-20. The other half of the classification: the switch-side port of each host attachment.
/// This is where tools/test_workflow/faults.sh and the chaos harness put netem, and before E-20
/// the sweep could not see any of it.
TEST_F(ResidualNetemSweepTest, TheHostFacingSetIsEveryPortAHostHangsOff)
{
    const auto ifaces = m_monitor->mininetHostFacingInterfaces();

    EXPECT_TRUE(contains(ifaces, "s1-eth9"))
        << "the port h1 hangs off is not in the host-facing set, so netem attached there by "
           "faults.sh would be reported as belonging to no part of this fabric";
    EXPECT_FALSE(contains(ifaces, "s1-eth1"))
        << "a switch-to-switch link end was called host-facing; the two sets must not overlap or "
           "the warning's advice is wrong for one of them";
    EXPECT_EQ(ifaces.size(), 1u) << "this topology has exactly one host attachment";
}

/**
 * 🔴 E-20's mechanism, stated on its own. ONE bare `tc qdisc show` for the whole namespace -- not
 * `show dev <iface>` per graph edge.
 *
 * The per-device form can only ask about names the graph already holds, which is precisely why the
 * old sweep could not see a host-facing port or a switch that is running but not in the topology
 * file. It is also the only form the sudoers grant covers, so the temptation to "fix" this back is
 * real: see utils::netem::readOnlyTcRunner for why the bare form needs no privilege at all.
 */
TEST_F(ResidualNetemSweepTest, TheSweepReadsTheWholeMachineInOneCall)
{
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + htbLine("s1-eth1");
    LogCapture log;

    m_monitor->warnAboutResidualNetem(tc.runner());

    ASSERT_EQ(tc.calls.size(), 1u)
        << "the sweep issued " << tc.calls.size()
        << " tc commands; one read of the whole namespace is the point -- a read per graph edge "
           "cannot see an interface the graph does not name";
    EXPECT_EQ(tc.calls[0], (std::vector<std::string>{"qdisc", "show"}))
        << "the sweep asked tc about a specific device: " << utils::describeArgv(tc.calls[0])
        << ". The `dev` form answers only for names already in the graph";
}

/**
 * 🔴 THE FINDING W8-4 EXISTS FOR. netem is on the fabric before this kernel has injected anything,
 * and the one line an operator gets must name the interfaces. Without it a restarted kernel
 * reports a clean graph over a link that is dropping every packet.
 */
TEST_F(ResidualNetemSweepTest, ResidualNetemIsNamedInOneWarningAtStartup)
{
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + htbLine("s1-eth1") + netemLine("s1-eth1") +
              netemLine("s5-eth1");

    LogCapture log;
    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    ASSERT_EQ(found.size(), 2u) << "the sweep did not find the netem that is there";
    EXPECT_EQ(kindOf(found, "s1-eth1"), std::make_optional(SweptInterface::Link));
    EXPECT_EQ(kindOf(found, "s5-eth1"), std::make_optional(SweptInterface::Link));

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

/**
 * 🔴 E-20, THE DEFECT VERBATIM. `tools/test_workflow/faults.sh` and the chaos harness attach netem
 * to the switch port a HOST hangs off. The pre-E-20 sweep read only switch-to-switch link ends, so
 * for exactly those faults it said nothing -- and silence from this sweep reads as "clean fabric",
 * which is the one thing it exists not to say by accident.
 */
TEST_F(ResidualNetemSweepTest, NetemOnAHostFacingPortIsFoundAndSaidToBeHostFacing)
{
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + netemLine("s1-eth9");

    LogCapture log;
    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    ASSERT_EQ(found.size(), 1u)
        << "netem on the port a host hangs off was not reported at all. faults.sh puts it there, "
           "and a sweep that only reads link ends calls that fabric clean";
    EXPECT_EQ(found[0].interface, "s1-eth9");
    EXPECT_EQ(found[0].kind, SweptInterface::HostFacing)
        << "a host-facing port was reported under the wrong heading. It matters: no link endpoint "
           "can address a host edge (W8-7), so /ndt/inject_link_recovery cannot take this one back";

    const auto text = log.text();
    EXPECT_NE(text.find("s1-eth9 (host-facing)"), std::string::npos)
        << "the warning did not say whose the interface is, so an operator cannot tell a link this "
           "kernel could take back from a fault only its own tool can:\n"
        << text;
}

/**
 * 🔴 E-20's other half. An `s<N>-eth<M>` this topology does not name is the most alarming finding
 * of the three -- it means the fabric on this machine is not the fabric in the topology file -- so
 * dropping it because there is nothing to attribute it to would throw away the loudest signal.
 */
TEST_F(ResidualNetemSweepTest, NetemOnAnInterfaceThisTopologyDoesNotNameIsReportedAsUnknown)
{
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + netemLine("s9-eth2");

    LogCapture log;
    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    ASSERT_EQ(found.size(), 1u)
        << "an interface carrying netem was dropped because the graph does not name it. A switch "
           "running here that is not in the topology file is a finding, not noise";
    EXPECT_EQ(found[0].interface, "s9-eth2");
    EXPECT_EQ(found[0].kind, SweptInterface::Unknown);
    EXPECT_NE(log.text().find("s9-eth2 (unknown)"), std::string::npos)
        << "the warning named the interface without saying the topology does not contain it:\n"
        << log.text();
}

/// The three kinds in one sweep, with the counts. An operator reading one line needs to know how
/// much of each -- "3 interfaces" over a fabric with one link fault and two stray switches is a
/// different morning from three link faults.
TEST_F(ResidualNetemSweepTest, TheWarningSeparatesTheThreeKindsAndCountsThem)
{
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + netemLine("s1-eth1") + netemLine("s1-eth9") +
              netemLine("s9-eth2");

    LogCapture log;
    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    ASSERT_EQ(found.size(), 3u);
    EXPECT_EQ(namesOf(found), (std::vector<std::string>{"s1-eth1", "s1-eth9", "s9-eth2"}))
        << "the sweep reports in the order the qdisc tree lists, so an operator can line the "
           "warning up against `tc qdisc show` by eye";

    const auto text = log.text();
    EXPECT_NE(text.find("s1-eth1 (link)"), std::string::npos) << text;
    EXPECT_NE(text.find("s1-eth9 (host-facing)"), std::string::npos) << text;
    EXPECT_NE(text.find("s9-eth2 (unknown)"), std::string::npos) << text;
    EXPECT_NE(text.find("1 link end(s), 1 host-facing port(s), 1 not named by this topology"),
              std::string::npos)
        << "the warning listed the interfaces without counting the kinds:\n"
        << text;
}

/**
 * The boundary, stated as a test rather than only as a sentence in the manual. The root namespace
 * also carries `lo`, `docker0`, veths and the operator's wifi, and a host's own `h<N>-eth0` is not
 * in it at all (it lives in the host's namespace and needs `mnexec -a` to reach).
 *
 * 🔴 So a quiet sweep does NOT mean the fabric is clean. It means the root namespace is.
 */
TEST_F(ResidualNetemSweepTest, NetemOutsideThisFabricsInterfaceShapeIsNotReported)
{
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + netemLine("docker0") + netemLine("wlp0s20f3") +
              netemLine("h1-eth0");

    LogCapture log;
    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    EXPECT_TRUE(found.empty())
        << "the sweep reported netem on an interface that is not this fabric's shape. A warning "
           "that fires on the operator's wifi is a warning nobody reads";
    EXPECT_EQ(log.text().find("netem is already attached"), std::string::npos) << log.text();
}

/// 🔴 Adam's ruling, the half a fix is most likely to overshoot: WARN, do not clear. A kernel that
/// removed netem at startup would silently destroy any fault campaign it started underneath -- and
/// since E-20 the sweep sees host-facing and unfamiliar interfaces too, so this matters more, not
/// less: those are residue it definitely does not own.
TEST_F(ResidualNetemSweepTest, TheSweepNeverRunsACommandThatChangesTheTree)
{
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + netemLine("s1-eth1") + netemLine("s1-eth9") +
              netemLine("s9-eth2");

    LogCapture log;
    m_monitor->warnAboutResidualNetem(tc.runner());

    ASSERT_TRUE(tc.writes().empty())
        << "the startup sweep ran a command that changes the qdisc tree; it is allowed to read "
           "and to complain, and nothing else";
}

/// The other half of the same ruling: the reading must not become a declaration. Manufacturing one
/// from a qdisc tree would make the twin its own witness -- and the tree cannot say which
/// direction of the pair anybody meant.
TEST_F(ResidualNetemSweepTest, TheSweepDoesNotDeclareTheLinkDown)
{
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + netemLine("s1-eth1") + netemLine("s5-eth1");

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
    FakeMachineTc tc; // the machine's own interfaces, no netem anywhere
    LogCapture log;

    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    EXPECT_TRUE(found.empty());
    EXPECT_EQ(log.text().find("netem is already attached"), std::string::npos)
        << "a clean fabric was reported as dirty:\n"
        << log.text();
    EXPECT_EQ(tc.calls.size(), 1u) << "the sweep did not read the qdisc tree at all";
}

/**
 * A shaped interface with no netem is the ordinary Mininet TCLink case. Reporting htb as residue
 * would fire on every OVS fabric in this repository and make the warning worthless.
 */
TEST_F(ResidualNetemSweepTest, TCLinkShapingOnItsOwnIsNotResidue)
{
    FakeMachineTc tc;
    tc.tree = kMachineNoise;
    for (const auto& iface : m_monitor->mininetLinkInterfaces())
    {
        tc.tree += htbLine(iface);
    }
    for (const auto& iface : m_monitor->mininetHostFacingInterfaces())
    {
        tc.tree += htbLine(iface);
    }
    LogCapture log;

    EXPECT_TRUE(m_monitor->warnAboutResidualNetem(tc.runner()).empty())
        << "htb was reported as a leftover fault";
}

/**
 * 🔴 "Could not read" is not "clean". A tree that cannot be read (tc missing, `sudo -n` refused if
 * anybody ever puts sudo back in front of it) is the one case this sweep has no opinion about, and
 * saying nothing there would make silence mean two different things.
 */
TEST_F(ResidualNetemSweepTest, AnUnreadableQdiscTreeIsReportedAsUnreadNotAsClean)
{
    FakeMachineTc tc;
    tc.readable = false;
    LogCapture log;

    const auto found = m_monitor->warnAboutResidualNetem(tc.runner());

    EXPECT_TRUE(found.empty()) << "an unreadable tree was counted as a finding";
    const auto text = log.text();
    EXPECT_NE(text.find("could not read"), std::string::npos)
        << "a qdisc tree the sweep could not read was passed over in silence, which makes a clean "
           "report indistinguishable from an unattempted one:\n"
        << text;
}

/// A testbed deployment has no Mininet interfaces at all, and running tc against the names this
/// graph would produce would be a fault injected on whatever answers to them.
TEST_F(ResidualNetemSweepTest, ATestbedDeploymentRunsNoTcAtAll)
{
    build(utils::TESTBED);
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + netemLine("s1-eth1");
    LogCapture log;

    EXPECT_TRUE(m_monitor->warnAboutResidualNetem(tc.runner()).empty());
    EXPECT_TRUE(tc.calls.empty())
        << "the sweep ran tc on a deployment that has no Mininet interfaces";
}

// --- the parser the whole-machine read needs -----------------------------------------------------

/// The bare `tc qdisc show` prints `dev <name>` inside each line; the per-device form does not.
/// findExistingNetem() parses the latter, so the sweep needed its own reader -- and this is the
/// case that says the two forms are not interchangeable.
TEST(NetemLinkFaultTest, TheWholeMachineTreeNamesTheInterfaceInsideEachLine)
{
    const std::string tree =
        "qdisc noqueue 0: dev lo root refcnt 2 \n"
        "qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10 default 0x1 direct_packets_stat 0\n"
        "qdisc netem 10: dev s1-eth1 parent 5:1 limit 1000 loss 100%\n"
        "qdisc netem 8001: dev s9-eth1 root refcnt 2 limit 1000\n";

    EXPECT_EQ(utils::netem::netemInterfacesInTree(tree),
              (std::vector<std::string>{"s1-eth1", "s9-eth1"}));

    // The per-device form has no `dev` words at all, so nothing may be read out of it. A parser
    // that guessed here would name whatever word happened to sit in that column.
    EXPECT_TRUE(utils::netem::netemInterfacesInTree(kShapedWithNetem).empty());
    EXPECT_TRUE(utils::netem::netemInterfacesInTree("").empty());
}

/// An interface may carry more than one netem, and a tree lists a qdisc per line. Reporting it
/// twice would double the count the warning prints.
TEST(NetemLinkFaultTest, AnInterfaceCarryingTwoNetemsIsNamedOnce)
{
    const std::string tree = "qdisc netem 10: dev s1-eth1 parent 5:1 limit 1000 loss 100%\n"
                             "qdisc netem 11: dev s1-eth1 parent 10:1 limit 1000 delay 5ms\n";

    EXPECT_EQ(utils::netem::netemInterfacesInTree(tree), (std::vector<std::string>{"s1-eth1"}));
}

/**
 * 🔴 THE SWEEP'S FAKE HAS TO ANSWER THE PER-DEVICE QUESTION IN THE PER-DEVICE FORM, and this case
 * exists because the first gate run proved it the hard way: with the fake answering the
 * whole-machine tree to `show dev X`, the mutation that makes the sweep CLEAR what it finds went
 * green. restoreInterface() parses the per-device form, could not read an attach point out of the
 * wrong one, and no-oped -- so a fake that got this wrong made a real defect look harmless.
 *
 * The two assertions are the two halves of that: the words `dev X` are gone, and what remains is
 * something findExistingNetem() can actually locate a netem in.
 */
TEST(NetemLinkFaultTest, TheFakesPerDeviceViewIsTheFormRestoreInterfaceCanRead)
{
    FakeMachineTc tc;
    tc.tree = std::string(kMachineNoise) + htbLine("s1-eth1") + netemLine("s1-eth1") +
              netemLine("s5-eth1");

    const auto view = tc.perDevice("s1-eth1");

    EXPECT_EQ(view.find("dev "), std::string::npos)
        << "`tc qdisc show dev X` does not repeat the device in every line; a fake that does is "
           "handing the code under test a tree no real tc would produce:\n"
        << view;
    EXPECT_EQ(view.find("s5-eth1"), std::string::npos) << "another interface's lines leaked in:\n"
                                                       << view;

    const auto at = utils::netem::findExistingNetem(view);
    ASSERT_TRUE(at.safe) << "the per-device view is not readable by the function every restore "
                            "goes through, so a sweep that ran a restore would look like a sweep "
                            "that ran nothing: "
                         << at.why << "\n"
                         << view;
    EXPECT_EQ(at.tcArgs, (std::vector<std::string>{"parent", "5:1"}));
}
