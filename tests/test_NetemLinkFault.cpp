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
