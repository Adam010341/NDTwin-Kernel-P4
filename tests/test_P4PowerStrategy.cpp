/**
 * Tests for P4PowerStrategy, written against the Phase 7 specs rather than the implementation.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Sources of truth, in order: doc/p4_bmv2_support_plan.md (the Phase 7 acceptance line: commands
 * target a single switch and NEVER contain `pkill -f`), the IPowerStrategy doc comments (ok only
 * when the operation actually happened; an implementation that cannot start a switch must not mark
 * the twin up), and doc/phase7_power_mechanism_design.md decisions 1-3:
 *
 *  - powerOff runs the helper -- `sudo -n /usr/local/sbin/ndtwin-p4-power off <name>` -- and marks
 *    the vertex down only when it succeeds. A helper failure leaves the vertex up: the process was
 *    left running, so left running is left up.
 *  - powerOn is two commands in order: helper `on`, then a POST to the proxy readopt endpoint for
 *    that dpid (curl with -f, so a non-2xx answer fails). The vertex is marked up only when BOTH
 *    succeed; a failure of either leaves it untouched and returns a failure OpResult -- 500 for the
 *    helper, 502 for readopt -- whose message says what happened. The readopt step exists because a
 *    restarted bmv2 has no pipeline, no clone session, no mastership and no routes: a process that
 *    is up and a switch that works are different claims, and only the proxy can certify the second.
 *  - Already-up powerOn and already-down powerOff are successful no-ops that run no commands.
 *
 * The history behind the pkill assertion: the original baseline ran
 * `mnexec -a s1 pkill -f simple_switch_grpc`, which was wrong twice over -- `-a` takes a PID and
 * was given a name, and `pkill -f` matches globally, so fixing the first mistake would have killed
 * all ten switches. The design's hard rule is that no command, in any scenario, contains a
 * process-name-matching kill.
 *
 * Fixture follows test_OvsPowerStrategy.cpp: a real TopologyAndFlowMonitor over a hand-built
 * graph, no threads, only the shell seam overridden.
 */

#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/P4PowerStrategy.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Records the commands instead of running them; commands matching failSubstring "fail".
class FakeP4 : public P4PowerStrategy
{
  public:
    std::vector<std::string> commands;

    /// Commands matching this substring "fail". Empty means everything succeeds.
    std::string failSubstring;

  protected:
    bool executeSystemCommand(const std::string& cmd) override
    {
        commands.push_back(cmd);
        return failSubstring.empty() || cmd.find(failSubstring) == std::string::npos;
    }

  public:
    bool ran(const std::string& fragment) const
    {
        for (const std::string& cmd : commands)
        {
            if (cmd.find(fragment) != std::string::npos)
            {
                return true;
            }
        }
        return false;
    }
};

/// One switch plus a monitor over it. No threads: start() is never called.
struct Fixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    std::unique_ptr<TopologyAndFlowMonitor> monitor;
    Graph::vertex_descriptor sw{};

    // dpid 7 deliberately: a value whose decimal and hex spellings agree, so the readopt URL
    // assertion tests "the URL carries this dpid" without also baking in a numeral base the
    // design doc never specified.
    Fixture()
    {
        sw = boost::add_vertex(*graph);
        (*graph)[sw].dpid = 7;
        (*graph)[sw].deviceName = "s1";
        (*graph)[sw].isUp = true;
        monitor = std::make_unique<TopologyAndFlowMonitor>(graph, mutex, bus, utils::MININET);
    }

    bool isUp() const
    {
        return (*graph)[sw].isUp;
    }
};

/// The design's hard rule, checked against every command a scenario produced.
void expectNoNameMatchingKills(const FakeP4& p4)
{
    for (const std::string& cmd : p4.commands)
    {
        EXPECT_EQ(cmd.find("pkill"), std::string::npos)
            << "the baseline's mistake, back again: " << cmd;
        EXPECT_EQ(cmd.find("killall"), std::string::npos) << cmd;
    }
}

} // namespace

// --- powerOff.

TEST(P4PowerStrategyTest, PowerOffRunsTheHelperOnceAgainstExactlyThatSwitch)
{
    Fixture fix;
    FakeP4 p4;

    const OpResult result = p4.powerOff(fix.sw, "s1", fix.monitor.get());

    EXPECT_TRUE(result.ok) << result.message;
    ASSERT_EQ(p4.commands.size(), 1u)
        << "one switch, one command; anything more is collateral";
    EXPECT_NE(p4.commands[0].find("sudo -n /usr/local/sbin/ndtwin-p4-power off s1"),
              std::string::npos)
        << "sudoers pins the root-owned path with -n, and the helper is the only thing allowed "
           "to touch a PID: "
        << p4.commands[0];
    EXPECT_FALSE(fix.isUp());
    expectNoNameMatchingKills(p4);
}

TEST(P4PowerStrategyTest, PowerOffFailureLeavesTheVertexUp)
{
    // The helper refuses (stale manifest, comm mismatch, a process that would not die) and the
    // bmv2 process is still running. Left running is left up: marking it down would be the twin
    // asserting a power state the network does not have.
    Fixture fix;
    FakeP4 p4;
    p4.failSubstring = "ndtwin-p4-power off";

    const OpResult result = p4.powerOff(fix.sw, "s1", fix.monitor.get());

    EXPECT_FALSE(result.ok) << "reported a switch as stopped that the helper never stopped";
    EXPECT_EQ(result.httpStatus, 500);
    EXPECT_NE(result.message.find("s1"), std::string::npos)
        << "an operator needs to know which switch: " << result.message;
    EXPECT_TRUE(fix.isUp());
    expectNoNameMatchingKills(p4);
}

TEST(P4PowerStrategyTest, PowerOffOnAnAlreadyDownSwitchRunsNothing)
{
    // Energy-Saving-App re-sends the state it wants, so the already-down case is routine, and
    // running the helper anyway would make it report "no live pid" as a failure.
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    FakeP4 p4;

    const OpResult result = p4.powerOff(fix.sw, "s1", fix.monitor.get());

    EXPECT_TRUE(result.ok) << result.message;
    EXPECT_TRUE(p4.commands.empty()) << "ran " << p4.commands.size() << " commands anyway";
    EXPECT_FALSE(fix.isUp());
}

// --- powerOn: two commands, both load-bearing.

TEST(P4PowerStrategyTest, PowerOnRunsHelperThenReadoptInThatOrder)
{
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    FakeP4 p4;

    const OpResult result = p4.powerOn(fix.sw, "s1", 7, fix.monitor.get());

    EXPECT_TRUE(result.ok) << result.message;
    ASSERT_EQ(p4.commands.size(), 2u) << "helper on, then readopt -- nothing else";
    EXPECT_NE(p4.commands[0].find("sudo -n"), std::string::npos) << p4.commands[0];
    EXPECT_NE(p4.commands[0].find("ndtwin-p4-power on s1"), std::string::npos)
        << "the process must exist before the proxy can adopt it: " << p4.commands[0];

    const std::string& readopt = p4.commands[1];
    EXPECT_NE(readopt.find("curl"), std::string::npos) << readopt;
    EXPECT_NE(readopt.find("readopt/7"), std::string::npos)
        << "the proxy readopts one dpid, and it had better be this one: " << readopt;
    EXPECT_NE(readopt.find("-f"), std::string::npos)
        << "without -f a 5xx from the proxy exits 0 and a dead readopt reads as success: "
        << readopt;
    EXPECT_TRUE(readopt.find("-X POST") != std::string::npos ||
                readopt.find("--request POST") != std::string::npos ||
                readopt.find("-d") != std::string::npos)
        << "the readopt endpoint is a POST: " << readopt;

    EXPECT_TRUE(fix.isUp());
    expectNoNameMatchingKills(p4);
}

TEST(P4PowerStrategyTest, PowerOnHelperFailureIsA500AndReadoptNeverRuns)
{
    // No process came up, so there is nothing for the proxy to adopt; asking it to would at best
    // waste a request and at worst adopt whatever stale thing answers on that port.
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    FakeP4 p4;
    p4.failSubstring = "ndtwin-p4-power on";

    const OpResult result = p4.powerOn(fix.sw, "s1", 7, fix.monitor.get());

    EXPECT_FALSE(result.ok);
    EXPECT_EQ(result.httpStatus, 500);
    EXPECT_NE(result.message.find("s1"), std::string::npos) << result.message;
    EXPECT_FALSE(p4.ran("readopt")) << "readopted a switch whose process never started";
    EXPECT_FALSE(fix.isUp())
        << "marked a switch as running when the command to start it failed";
    expectNoNameMatchingKills(p4);
}

TEST(P4PowerStrategyTest, PowerOnReadoptFailureIsA502AndDoesNotMarkUp)
{
    // The dangerous half-state: the process is alive and answers liveness probes, but it has no
    // pipeline, no clone session, no mastership and no routes. Reporting failure here is what
    // keeps the twin honest -- the liveness probe cannot tell the difference, by design note in
    // phase7_power_mechanism_design.md, so this OpResult is the only honest witness.
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    FakeP4 p4;
    p4.failSubstring = "readopt";

    const OpResult result = p4.powerOn(fix.sw, "s1", 7, fix.monitor.get());

    EXPECT_FALSE(result.ok);
    EXPECT_EQ(result.httpStatus, 502) << "the proxy is a gateway and it said no (or nothing)";
    EXPECT_NE(result.message.find("readopt"), std::string::npos)
        << "the message must say which of the two steps died: " << result.message;
    EXPECT_TRUE(p4.ran("ndtwin-p4-power on s1")) << "the helper step should still have run";
    EXPECT_FALSE(fix.isUp())
        << "a process without a pipeline is not a switch that is up";
    expectNoNameMatchingKills(p4);
}

TEST(P4PowerStrategyTest, PowerOnOnAnAlreadyUpSwitchRunsNothing)
{
    // The helper's `on` refuses entries whose pid is still alive, so re-running it against an
    // already-up switch would turn a routine repeat request into a reported failure.
    Fixture fix;
    FakeP4 p4;

    const OpResult result = p4.powerOn(fix.sw, "s1", 7, fix.monitor.get());

    EXPECT_TRUE(result.ok) << result.message;
    EXPECT_TRUE(p4.commands.empty()) << "ran " << p4.commands.size() << " commands anyway";
    EXPECT_TRUE(fix.isUp());
}

TEST(P4PowerStrategyTest, DescribesItselfForLogsAndErrors)
{
    FakeP4 p4;
    EXPECT_STREQ(p4.describe(), "P4/bmv2");
}
