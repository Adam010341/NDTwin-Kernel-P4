/**
 * Tests for P4PowerStrategy, written against the Phase 7 specs rather than the implementation.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Sources of truth, in order: doc/2026-07-27_p4_bmv2_support_plan.md (the Phase 7 acceptance line: commands
 * target a single switch and NEVER contain `pkill -f`), the IPowerStrategy doc comments (ok only
 * when the operation actually happened; an implementation that cannot start a switch must not mark
 * the twin up), and doc/2026-08-11_phase7_power_mechanism_design.md decisions 1-3:
 *
 *  - powerOff runs the helper -- `sudo -n /usr/local/sbin/ndtwin-p4-power off <name>` -- and marks
 *    the vertex down only when it succeeds. A helper failure leaves the vertex up: the process was
 *    left running, so left running is left up.
 *  - powerOn is two commands in order: helper `on`, then a POST to the proxy readopt endpoint for
 *    that dpid (curl with --fail-with-body, so a non-2xx answer fails *and* the endpoint's
 *    step detail still reaches the log). The vertex is marked up only when BOTH
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

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <iterator>
#include <memory>
#include <shared_mutex>
#include <sstream>
#include <string>
#include <vector>

#include <unistd.h>

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

/// Raises the shell seam to public so a test can call the *real* body. Overrides nothing:
/// this is the one class in the file that does not replace executeSystemCommand.
class RealSeamP4 : public P4PowerStrategy
{
  public:
    using P4PowerStrategy::executeSystemCommand;
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

/// A command's arguments as whole tokens.
///
/// [Co-developed with claude code -- Adam]
/// Substring search cannot tell curl's two fail-on-error flags apart: "-f" is a substring of
/// "--fail-with-body", so `cmd.find("-f")` passes for the flag that keeps the response body and
/// equally for the one that throws it away. Those are the two behaviours these tests exist to
/// distinguish, so the comparison has to be on tokens.
std::vector<std::string> commandTokens(const std::string& cmd)
{
    std::istringstream in(cmd);
    return {std::istream_iterator<std::string>(in), std::istream_iterator<std::string>()};
}

bool hasFlag(const std::string& cmd, const std::string& flag)
{
    const std::vector<std::string> tokens = commandTokens(cmd);
    return std::find(tokens.begin(), tokens.end(), flag) != tokens.end();
}

/// [Co-developed with claude code -- Adam]
/// Whole-token matching opened the opposite blind spot: curl bundles short options, so "-sSf"
/// carries -f without ever producing a "-f" token. A command written that way alongside
/// --fail-with-body would pass keepsTheFailureBody here and then die at runtime -- curl
/// refuses the two fail flags together as mutually exclusive -- which is a broken power op
/// under a green test. Any single-dash token whose letters include 'f' is the fail flag.
bool hasBundledShortF(const std::string& cmd)
{
    for (const std::string& token : commandTokens(cmd)) {
        if (token.size() > 1 && token[0] == '-' && token[1] != '-'
            && token.find('f') != std::string::npos) {
            return true;
        }
    }
    return false;
}

/// Does a non-2xx answer become a non-zero exit? Any member of curl's --fail family does this.
bool failsOnNon2xx(const std::string& cmd)
{
    return hasBundledShortF(cmd) || hasFlag(cmd, "--fail") || hasFlag(cmd, "--fail-with-body");
}

/// Does the response body survive a non-2xx answer? Only --fail-with-body keeps it.
bool keepsTheFailureBody(const std::string& cmd)
{
    return hasFlag(cmd, "--fail-with-body") && !hasBundledShortF(cmd) && !hasFlag(cmd, "--fail");
}

/// The helpers above are themselves load-bearing: every scenario's curl assertion routes
/// through them, so their blind spots are the suite's blind spots.
TEST(CurlFlagHelpersTest, BundledShortOptionsCarryTheFailFlag)
{
    EXPECT_TRUE(failsOnNon2xx("curl -sSf http://h/x"));
    EXPECT_TRUE(hasBundledShortF("curl -fsS http://h/x"));
    EXPECT_FALSE(keepsTheFailureBody("curl -sSf --fail-with-body http://h/x"));
    EXPECT_TRUE(keepsTheFailureBody("curl -sS --fail-with-body http://h/x"));
    EXPECT_FALSE(hasBundledShortF("curl -sS --fail-with-body http://h/x"));
}

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
    EXPECT_TRUE(failsOnNon2xx(readopt))
        << "without a fail-on-error flag a 5xx from the proxy exits 0 and a dead readopt reads "
           "as success: "
        << readopt;
    EXPECT_TRUE(readopt.find("-X POST") != std::string::npos ||
                readopt.find("--request POST") != std::string::npos ||
                readopt.find("-d") != std::string::npos)
        << "the readopt endpoint is a POST: " << readopt;

    EXPECT_TRUE(fix.isUp());
    expectNoNameMatchingKills(p4);
}

TEST(P4PowerStrategyTest, TheReadoptCurlKeepsTheProxysAccountOfWhatBroke)
{
    // [Co-developed with claude code -- Adam]
    // The readopt endpoint answers a failure with the step it died on -- mastership, pipeline,
    // clone or routes -- precisely so this side can log it. `curl -f` and `--fail-with-body`
    // both make a 502 exit non-zero, so the seam's control flow cannot tell them apart; the
    // difference is entirely in whether the body survives, and `-f` deletes it.
    //
    // Measured on a live fabric (2026-08-12): powerOn failed, and the kernel log held exactly
    // `curl: (22) The requested URL returned error: 502` -- no step, no reason. The proxy's log
    // had only uvicorn's one-line 502. Re-running the same endpoint by hand without `-f`
    // returned `step: "pipeline"` immediately. The diagnostic had been produced, travelled the
    // whole way, and was discarded by the caller in its last inch.
    //
    // This test is why the flag cannot quietly regress: the assertion an earlier version made,
    // `readopt.find("-f") != npos`, is satisfied by BOTH flags, so it would have watched the
    // repair be undone without failing once.
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    FakeP4 p4;

    p4.powerOn(fix.sw, "s1", 7, fix.monitor.get());

    ASSERT_EQ(p4.commands.size(), 2u);
    const std::string& readopt = p4.commands[1];

    EXPECT_TRUE(keepsTheFailureBody(readopt))
        << "the 502's step detail must reach the kernel log, so the readopt curl needs "
           "--fail-with-body and must not use plain -f/--fail, which discard it: "
        << readopt;
    EXPECT_TRUE(failsOnNon2xx(readopt))
        << "and it must still exit non-zero on a 502, or the seam reads a dead readopt as "
           "success: "
        << readopt;
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
    // 2026-08-11_phase7_power_mechanism_design.md, so this OpResult is the only honest witness.
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

TEST(P4PowerStrategyTest, TheReadoptFailureNamesARecoveryThatCanActuallyRun)
{
    // [Co-developed with claude code -- Adam]
    // This message has now named two recoveries that do not work, so the assertions name both.
    //
    // First it ended "retrying this power-on retries the readopt." It cannot: helper-on has
    // already succeeded at this point, so bmv2 is serving; p4LivenessFor answers Up on probe_ok
    // alone and the 1 Hz pingWorker calls setVertexUp within a second; the retry then hits
    // powerOn's own getVertexIsUp early-return and answers 200 without going near the readopt.
    //
    // Its replacement said "power off and then power on". Run against a live fabric on
    // 2026-08-12, that returned 500 too -- powering off leaves the proxy's prober hammering the
    // dead port, and grpc's process-global subchannel pool hands the accumulated backoff to the
    // fresh channel readopt builds. Calling the readopt endpoint directly is what recovered the
    // switch. So the earlier repair swapped unworkable advice for untested advice, and this
    // test now pins the property both versions failed rather than the wording of either.
    //
    // Asserted as message content because the message *is* the deliverable here: this OpResult
    // is the only honest witness to the half-state, so what it tells the operator to do next is
    // the contract, not decoration.
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    FakeP4 p4;
    p4.failSubstring = "readopt";

    const OpResult result = p4.powerOn(fix.sw, "s1", 7, fix.monitor.get());

    ASSERT_FALSE(result.ok);
    const std::string msg = result.message;
    EXPECT_NE(msg.find("/p4/readopt/7"), std::string::npos)
        << "the recovery that was measured to work is calling readopt directly, and the message "
           "has to name it, for this dpid: " << msg;
    EXPECT_EQ(msg.find("retrying this power-on retries the readopt"), std::string::npos)
        << "the message promises a retry that early-returns success instead: " << msg;
    EXPECT_NE(msg.find("not work either"), std::string::npos)
        << "off-then-on was measured to fail, so the message must warn against it rather than "
           "leave it looking like the obvious thing to try: " << msg;
}

// --- The seam itself, unfaked.

TEST(P4PowerStrategyTest, TheRealShellSeamRunsTheCommandAndReportsItsExitStatus)
{
    // [Co-developed with claude code -- Adam]
    //
    // Every other test in this file replaces executeSystemCommand, which is what makes them
    // able to assert command sequences -- and also what left the real body untested. Its
    // header calls that body "the whole test surface", and the comment on the implementation
    // names it as the site of the historical bug: the function was void once, so a power
    // action that failed reported success. `if (rc != 0)` -> `if (false)` reddened nothing.
    //
    // Contract, from P4PowerStrategy.hpp: "Returns whether the command exited 0." Two
    // programs whose entire specified behaviour is their exit status settle that, and neither
    // needs the helper, sudo, or a bmv2 to be installed.
    //
    // Asserting the exit status alone would still pass an implementation that never ran
    // anything and returned `cmd != "/bin/false"`, so the first assertion is a side effect:
    // the command has to have actually executed.
    RealSeamP4 p4;

    const std::filesystem::path marker =
        std::filesystem::temp_directory_path() /
        ("ndtwin-p4-seam-" + std::to_string(::getpid()));
    std::filesystem::remove(marker);

    EXPECT_TRUE(p4.executeSystemCommand("touch " + marker.string()))
        << "touch exits 0";
    EXPECT_TRUE(std::filesystem::exists(marker))
        << "the seam reported success without running the command at all";
    std::filesystem::remove(marker);

    EXPECT_TRUE(p4.executeSystemCommand("/bin/true"))
        << "a command that exited 0 must be reported as having worked";

    EXPECT_FALSE(p4.executeSystemCommand("/bin/false"))
        << "a command that exited non-zero must be reported as having failed -- this is the "
           "exact shape of the bug the seam's comment describes";
}

TEST(P4PowerStrategyTest, DescribesItselfForLogsAndErrors)
{
    FakeP4 p4;
    EXPECT_STREQ(p4.describe(), "P4/bmv2");
}
