/**
 * Tests for OVSPowerStrategy, which had none.
 *
 * [Co-developed with claude code -- Adam]
 *
 * This is the code that starts and stops switches in Mininet mode, and it is the one place where
 * getting it wrong destroys state rather than just reporting it wrongly: powerOff() deletes the OVS
 * bridge, and the list of ports it saves to the graph beforehand is the *only* record of what
 * powerOn() must reattach.
 *
 * Writing them turned up a fault the audit had not mentioned. executeListPorts() returned an empty
 * vector both when the bridge genuinely had no ports and when `ovs-vsctl list-ports` failed --
 * verified against a live ovs-vsctl, which writes nothing and exits 1 for a bridge that does not
 * exist, so the discarded exit status was the only thing that told them apart. powerOff() then
 * wrote that empty list over the graph's saved ports *before* checking anything and deleted the
 * bridge, so both records were gone; powerOn() built a bridge with no ports and marked the vertex
 * UP. A switch reporting healthy with no data plane attached, and no command had visibly failed.
 * Same conflation as the `list-br` bug that showed the whole fabric as dead, but permanent.
 *
 * The fixture drives a real TopologyAndFlowMonitor rather than a mock -- its constructor only stores
 * shared_ptrs, and the accessors used here are plain graph reads under a mutex, so a hand-built
 * two-vertex graph is enough and the assertions are about the real thing. Only the two shell seams
 * are overridden.
 */

#include <atomic>
#include <filesystem>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

#include <gtest/gtest.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/OVSPowerStrategy.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Records the commands instead of running them, and answers list-ports from a script.
class FakeOvs : public OVSPowerStrategy
{
  public:
    std::vector<std::string> commands;

    /// What executeListPorts() should return. nullopt models a failed query.
    std::optional<std::vector<std::string>> listPortsResult = std::vector<std::string>{};
    int listPortsCalls = 0;

    /// Commands matching this substring "fail". Empty means everything succeeds.
    std::string failSubstring;

  protected:
    bool executeSystemCommand(const std::string& cmd) override
    {
        commands.push_back(cmd);
        return failSubstring.empty() || cmd.find(failSubstring) == std::string::npos;
    }

    std::optional<std::vector<std::string>> executeListPorts(const std::string& br) override
    {
        ++listPortsCalls;
        return listPortsResult;
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

    size_t countContaining(const std::string& fragment) const
    {
        size_t n = 0;
        for (const std::string& cmd : commands)
        {
            if (cmd.find(fragment) != std::string::npos)
            {
                ++n;
            }
        }
        return n;
    }
};

/// Raises the shell seam to public so a test can call the *real* body. Overrides nothing:
/// this is the one class in the file that does not replace executeSystemCommand.
class RealSeamOvs : public OVSPowerStrategy
{
  public:
    using OVSPowerStrategy::executeSystemCommand;
};

/// A two-vertex graph plus a monitor over it. No threads: start() is never called.
struct Fixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    std::unique_ptr<TopologyAndFlowMonitor> monitor;
    Graph::vertex_descriptor sw{};

    Fixture()
    {
        sw = boost::add_vertex(*graph);
        (*graph)[sw].dpid = 1;
        (*graph)[sw].deviceName = "s1";
        (*graph)[sw].isUp = true;
        monitor = std::make_unique<TopologyAndFlowMonitor>(graph, mutex, bus, utils::MININET);
    }

    bool isUp() const
    {
        return (*graph)[sw].isUp;
    }

    std::vector<std::string> savedPorts() const
    {
        return (*graph)[sw].bridgeConnectedPortsForMininet;
    }

    void setSavedPorts(std::vector<std::string> ports)
    {
        (*graph)[sw].bridgeConnectedPortsForMininet = std::move(ports);
    }
};

} // namespace

// --- powerOff: the destructive direction.

TEST(OvsPowerStrategyTest, PowerOffSavesThePortsThenDeletesTheBridge)
{
    Fixture fix;
    FakeOvs ovs;
    ovs.listPortsResult = std::vector<std::string>{"s1-eth1", "s1-eth2"};

    const OpResult result = ovs.powerOff(fix.sw, "s1", fix.monitor.get());

    EXPECT_TRUE(result.ok) << result.message;
    EXPECT_EQ(fix.savedPorts(), (std::vector<std::string>{"s1-eth1", "s1-eth2"}))
        << "powerOn has nothing else to reattach from";
    EXPECT_TRUE(ovs.ran("ifconfig s1-eth1 down"));
    EXPECT_TRUE(ovs.ran("ifconfig s1-eth2 down"));
    EXPECT_TRUE(ovs.ran("del-br s1"));
    EXPECT_FALSE(fix.isUp());
}

TEST(OvsPowerStrategyTest, PowerOffRefusesWhenItCannotReadThePorts)
{
    // The fault this file was written to catch. A failed list-ports returned an empty vector, so
    // powerOff overwrote the saved ports with nothing and deleted the bridge anyway -- the only two
    // records of what to reattach, both gone, with no command having visibly failed.
    Fixture fix;
    fix.setSavedPorts({"s1-eth1", "s1-eth2"});
    FakeOvs ovs;
    ovs.listPortsResult = std::nullopt;

    const OpResult result = ovs.powerOff(fix.sw, "s1", fix.monitor.get());

    EXPECT_FALSE(result.ok) << "reported success while destroying unknown state";
    EXPECT_FALSE(ovs.ran("del-br"))
        << "deleted the bridge without knowing what was attached to it";
    EXPECT_EQ(fix.savedPorts(), (std::vector<std::string>{"s1-eth1", "s1-eth2"}))
        << "erased the saved ports on the failure path";
    EXPECT_TRUE(fix.isUp()) << "marked a switch down that is still running";
}

TEST(OvsPowerStrategyTest, PowerOffDistinguishesABridgeWithNoPortsFromAFailedQuery)
{
    // The other half of the same conflation: an empty list is a legitimate answer and must still
    // power the switch off. If this and the test above ever agree, the distinction has been lost.
    Fixture fix;
    FakeOvs ovs;
    ovs.listPortsResult = std::vector<std::string>{};

    const OpResult result = ovs.powerOff(fix.sw, "s1", fix.monitor.get());

    EXPECT_TRUE(result.ok) << result.message;
    EXPECT_TRUE(ovs.ran("del-br s1"));
    EXPECT_TRUE(fix.savedPorts().empty());
    EXPECT_FALSE(fix.isUp());
}

TEST(OvsPowerStrategyTest, PowerOffLeavesTheVertexUpWhenACommandFails)
{
    // Claiming a switch is off while it is still forwarding is the twin/network disagreement this
    // class exists to avoid.
    Fixture fix;
    FakeOvs ovs;
    ovs.listPortsResult = std::vector<std::string>{"s1-eth1"};
    ovs.failSubstring = "del-br";

    const OpResult result = ovs.powerOff(fix.sw, "s1", fix.monitor.get());

    EXPECT_FALSE(result.ok);
    EXPECT_EQ(result.httpStatus, 500);
    EXPECT_NE(result.message.find("s1"), std::string::npos)
        << "an operator needs to know which switch: " << result.message;
    EXPECT_TRUE(fix.isUp());
}

TEST(OvsPowerStrategyTest, PowerOffOnAnAlreadyDownSwitchDoesNothing)
{
    // Idempotent, and it must not re-run list-ports: that would overwrite the ports saved by the
    // powerOff that actually worked with whatever a now-deleted bridge reports.
    Fixture fix;
    fix.setSavedPorts({"s1-eth1", "s1-eth2"});
    (*fix.graph)[fix.sw].isUp = false;
    FakeOvs ovs;
    ovs.listPortsResult = std::nullopt;

    const OpResult result = ovs.powerOff(fix.sw, "s1", fix.monitor.get());

    EXPECT_TRUE(result.ok) << result.message;
    EXPECT_EQ(ovs.listPortsCalls, 0);
    EXPECT_TRUE(ovs.commands.empty());
    EXPECT_EQ(fix.savedPorts(), (std::vector<std::string>{"s1-eth1", "s1-eth2"}));
}

// --- powerOn.

TEST(OvsPowerStrategyTest, PowerOnRecreatesTheBridgeWithTheSavedPorts)
{
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    fix.setSavedPorts({"s1-eth1", "s1-eth2"});
    FakeOvs ovs;

    const OpResult result = ovs.powerOn(fix.sw, "s1", 1, fix.monitor.get());

    EXPECT_TRUE(result.ok) << result.message;
    EXPECT_TRUE(ovs.ran("add-br s1"));
    EXPECT_TRUE(ovs.ran("add-port s1 s1-eth1"));
    EXPECT_TRUE(ovs.ran("add-port s1 s1-eth2"));
    EXPECT_TRUE(ovs.ran("ifconfig s1-eth1 up"));
    EXPECT_TRUE(ovs.ran("set-controller s1 tcp:127.0.0.1:6633"))
        << "without a controller the bridge is up but unmanaged";
    EXPECT_TRUE(fix.isUp());
}

TEST(OvsPowerStrategyTest, PowerOnSetsTheDatapathIdAsSixteenHexDigits)
{
    // Ryu identifies switches by datapath-id, so a wrongly formatted one produces a bridge that
    // connects and is then unmatchable against the graph -- a switch that is up and invisible.
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    FakeOvs ovs;

    ovs.powerOn(fix.sw, "s1", 1, fix.monitor.get());
    EXPECT_TRUE(ovs.ran("other-config:datapath-id=0000000000000001")) << "dpid 1";

    FakeOvs wide;
    Fixture fix2;
    (*fix2.graph)[fix2.sw].isUp = false;
    wide.powerOn(fix2.sw, "s10", 255, fix2.monitor.get());
    EXPECT_TRUE(wide.ran("other-config:datapath-id=00000000000000ff"))
        << "hex, lower case, zero padded to 16";
}

TEST(OvsPowerStrategyTest, PowerOnDoesNotMarkUpWhenACommandFails)
{
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    fix.setSavedPorts({"s1-eth1"});
    FakeOvs ovs;
    ovs.failSubstring = "add-br";

    const OpResult result = ovs.powerOn(fix.sw, "s1", 1, fix.monitor.get());

    EXPECT_FALSE(result.ok);
    EXPECT_EQ(result.httpStatus, 500);
    EXPECT_FALSE(fix.isUp()) << "reported a switch as running when the command to start it failed";
}

TEST(OvsPowerStrategyTest, AFailedPortCommandFailsTheWholeOperation)
{
    // A bridge that comes up with some of its ports missing is a partial network, which is harder
    // to diagnose than one that plainly did not start. add-br succeeds here so the failure is
    // solely the port.
    //
    // The *first* port fails and the second is asserted to have run anyway. An earlier version had
    // this the other way round -- it failed s1-eth2 and asserted s1-eth1 ran -- but s1-eth1 is
    // attached first, so that assertion held whatever the code did after the failure. Verified by
    // mutation: adding `if (m_lastCommandFailed) break;` to the port loop left the whole suite green.
    // [Co-developed with claude code -- Adam]
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    fix.setSavedPorts({"s1-eth1", "s1-eth2", "s1-eth3"});
    FakeOvs ovs;
    ovs.failSubstring = "add-port s1 s1-eth1";

    const OpResult result = ovs.powerOn(fix.sw, "s1", 1, fix.monitor.get());

    EXPECT_FALSE(result.ok);
    EXPECT_FALSE(fix.isUp());
    EXPECT_TRUE(ovs.ran("add-port s1 s1-eth2"))
        << "abandoned the ports after the failing one; the bridge is left with a partial port set, "
           "and the next powerOff would record that partial set as the thing to restore";
    EXPECT_TRUE(ovs.ran("add-port s1 s1-eth3")) << "stopped before the last port";
    EXPECT_TRUE(ovs.ran("ifconfig s1-eth3 up")) << "attached the port but never brought it up";
}

TEST(OvsPowerStrategyTest, PowerOnOnAnAlreadyUpSwitchDoesNothing)
{
    // Energy-Saving-App sends action=on to switches that are already on, and the L2 contract check
    // does the same deliberately. Running add-br again would exit 1 -- verified against a live
    // ovs-vsctl, which refuses with "a bridge named s1 already exists" -- so this early return is
    // what keeps that case from reporting a spurious failure.
    Fixture fix;
    FakeOvs ovs;

    const OpResult result = ovs.powerOn(fix.sw, "s1", 1, fix.monitor.get());

    EXPECT_TRUE(result.ok) << result.message;
    EXPECT_TRUE(ovs.commands.empty()) << "ran " << ovs.commands.size() << " commands anyway";
    EXPECT_TRUE(fix.isUp());
}

TEST(OvsPowerStrategyTest, PowerOnWithNoSavedPortsStillReportsSuccessButBuildsAnEmptyBridge)
{
    // Recording current behaviour rather than endorsing it. Vertices start isUp=false, so a
    // powerOn on a freshly loaded topology -- one that never went through powerOff -- has no saved
    // ports and produces a bridge with none: up, controller attached, no data plane. It is not
    // wrong for this class to report success (every command it ran did succeed), but nothing
    // upstream notices either. Tracked as a follow-up; the ports would have to come from the static
    // topology. If a fix lands, this expectation is the one to change.
    Fixture fix;
    (*fix.graph)[fix.sw].isUp = false;
    FakeOvs ovs;

    const OpResult result = ovs.powerOn(fix.sw, "s1", 1, fix.monitor.get());

    EXPECT_TRUE(result.ok);
    EXPECT_EQ(ovs.countContaining("add-port"), 0u);
    EXPECT_TRUE(fix.isUp());
}

// --- The seam itself, unfaked.

TEST(OvsPowerStrategyTest, TheRealShellSeamRunsTheCommandAndReportsItsExitStatus)
{
    // [Co-developed with claude code -- Adam]
    //
    // Every other test in this file replaces executeSystemCommand -- deliberately, since one of
    // them would otherwise really run `sudo ovs-vsctl add-br` against the developer's machine
    // (see the comment in OVSPowerStrategy::powerOn about the hole that used to be in this
    // seam). The cost is that the real body, the one the implementation comment identifies as
    // where "a failed ovs-vsctl looked exactly like a success", ran in no test at all:
    // `if (rc != 0)` -> `if (false)` reddened nothing.
    //
    // Contract, from OVSPowerStrategy.hpp: "Runs a shell command; returns false when it
    // failed." Two programs whose entire specified behaviour is their exit status settle that,
    // and neither needs ovs-vsctl, sudo or a bridge to exist.
    //
    // Asserting the exit status alone would still pass an implementation that never ran
    // anything and returned `cmd != "/bin/false"`, so the first assertion is a side effect:
    // the command has to have actually executed.
    RealSeamOvs ovs;

    const std::filesystem::path marker =
        std::filesystem::temp_directory_path() /
        ("ndtwin-ovs-seam-" + std::to_string(::getpid()));
    std::filesystem::remove(marker);

    EXPECT_TRUE(ovs.executeSystemCommand("touch " + marker.string()))
        << "touch exits 0";
    EXPECT_TRUE(std::filesystem::exists(marker))
        << "the seam reported success without running the command at all";
    std::filesystem::remove(marker);

    EXPECT_TRUE(ovs.executeSystemCommand("/bin/true"))
        << "a command that exited 0 must be reported as having worked";

    EXPECT_FALSE(ovs.executeSystemCommand("/bin/false"))
        << "a command that exited non-zero must be reported as having failed -- this is the "
           "exact shape of the bug the seam's comment describes";
}

TEST(OvsPowerStrategyTest, DescribesItselfForLogsAndErrors)
{
    FakeOvs ovs;
    EXPECT_STREQ(ovs.describe(), "Open vSwitch");
}

// --- The wait-status decoding, now shared with DeviceConfigurationAndPowerManager.
//
// executeSystemCommand logged std::system's return value raw. Neither std::system nor pclose
// returns an exit code -- both return a wait status -- so `add-br` on an existing bridge, which
// exits 1, was logged as "status 256". The decoding already existed for the liveness probe; it was
// open-coded there, so this one was still printing the raw number.

TEST(CommandStatusTest, DecodesAWaitStatusRatherThanPrintingIt)
{
    EXPECT_EQ(utils::describeCommandStatus(3 << 8), "exit code 3");
    EXPECT_EQ(utils::describeCommandStatus(0), "exit code 0");
}

TEST(CommandStatusTest, NamesTheTwoCasesThatSendAnOperatorElsewhere)
{
    const std::string missing = utils::describeCommandStatus(127 << 8, "sudo ovs-vsctl list-br");
    EXPECT_NE(missing.find("command not found"), std::string::npos) << missing;
    EXPECT_NE(missing.find("ovs-vsctl"), std::string::npos)
        << "must name the tool that is missing, not a fixed one: " << missing;

    const std::string refused = utils::describeCommandStatus(1 << 8, "sudo ovs-vsctl list-br");
    EXPECT_NE(refused.find("sudo password prompt"), std::string::npos) << refused;
}

// --- The hints must belong to the command that produced them.
//
// This decoder was written inside DeviceConfigurationAndPowerManager, where hardcoding `ovs-vsctl`
// was correct because that class runs nothing else. Moving it into utils:: wired it into
// utils::execCommand -- the generic shell-out behind `curl` to Ryu and the proxy and 13
// snmpget/snmpwalk call sites -- so a TESTBED machine without net-snmp reported "is ovs-vsctl
// installed?" for every power reading, on a path where nobody runs ovs-vsctl at all.
//
// Caught by review, and the regression was mine. A misleading diagnostic costs more than a missing
// one, which is the whole reason this decoder exists. [Co-developed with claude code -- Adam]

TEST(CommandStatusTest, NamesTheToolTheCommandActuallyRan)
{
    EXPECT_NE(utils::describeCommandStatus(127 << 8, "snmpget -v2c -c public 10.0.0.1 1.3.6")
                  .find("snmpget"),
              std::string::npos);
    EXPECT_NE(utils::describeCommandStatus(127 << 8, "curl -s http://127.0.0.1:8080/x")
                  .find("curl"),
              std::string::npos);
    EXPECT_NE(utils::describeCommandStatus(127 << 8, "sudo /usr/bin/ifconfig s1-eth1 up")
                  .find("ifconfig"),
              std::string::npos)
        << "should strip the directory and skip sudo";
}

TEST(CommandStatusTest, DoesNotBlameOvsVsctlForAnotherToolsFailure)
{
    // The exact regression. Every one of these reached the decoder through execCommand.
    for (const std::string& cmd : {std::string("snmpget -v2c -c public 10.0.0.1 1.3.6"),
                                   std::string("snmpwalk -v2c -c public 10.0.0.1 1.3.6"),
                                   std::string("curl -s http://127.0.0.1:8080/stats/flow/1")})
    {
        const std::string missing = utils::describeCommandStatus(127 << 8, cmd);
        EXPECT_EQ(missing.find("ovs-vsctl"), std::string::npos)
            << cmd << " -> " << missing;
    }
}

TEST(CommandStatusTest, TheSudoHintOnlyAppliesWhenSudoWasUsed)
{
    // snmpget exits 1 on a timeout or an unknown OID, and curl exits 1 on an unsupported protocol.
    // Neither has anything to do with a password prompt, and saying so sends the reader to the wrong
    // place with confidence.
    for (const std::string& cmd : {std::string("snmpget -v2c -c public 10.0.0.1 1.3.6"),
                                   std::string("curl -s http://127.0.0.1:8080/x")})
    {
        const std::string refused = utils::describeCommandStatus(1 << 8, cmd);
        EXPECT_EQ(refused.find("sudo"), std::string::npos) << cmd << " -> " << refused;
        EXPECT_EQ(refused, "exit code 1") << cmd;
    }

    // And it still applies where it is true.
    EXPECT_NE(utils::describeCommandStatus(1 << 8, "sudo ovs-vsctl add-br s1").find("sudo password"),
              std::string::npos);
}

TEST(CommandStatusTest, SaysSomethingUsefulWithNoCommandAtAll)
{
    // The default argument, for a caller that does not have the command line to hand. It must not
    // invent a tool name.
    const std::string missing = utils::describeCommandStatus(127 << 8);
    EXPECT_NE(missing.find("command not found"), std::string::npos) << missing;
    EXPECT_EQ(missing.find("installed?"), std::string::npos)
        << "asked whether an unnamed tool is installed: " << missing;
    EXPECT_EQ(utils::describeCommandStatus(1 << 8), "exit code 1");
}

TEST(CommandToolNameTest, PicksTheToolOutOfACommandLine)
{
    EXPECT_EQ(utils::commandToolName("ovs-vsctl list-br"), "ovs-vsctl");
    EXPECT_EQ(utils::commandToolName("sudo ovs-vsctl list-br"), "ovs-vsctl");
    EXPECT_EQ(utils::commandToolName("  sudo   ovs-vsctl  list-br"), "ovs-vsctl");
    EXPECT_EQ(utils::commandToolName("sudo -n ovs-vsctl list-br"), "ovs-vsctl")
        << "sudo's own options must be skipped";
    EXPECT_EQ(utils::commandToolName("/usr/bin/snmpget -v2c"), "snmpget");
    EXPECT_EQ(utils::commandToolName("sudo /usr/sbin/ifconfig s1-eth1 up"), "ifconfig");
}

TEST(CommandToolNameTest, ReturnsNothingRatherThanGuessing)
{
    EXPECT_EQ(utils::commandToolName(""), "");
    EXPECT_EQ(utils::commandToolName("   "), "");
    EXPECT_EQ(utils::commandToolName("sudo"), "") << "sudo alone names no tool";
    EXPECT_EQ(utils::commandToolName("sudo -n"), "");
}

TEST(CommandStatusTest, ReportsSignalsAndUnreapedChildren)
{
    EXPECT_EQ(utils::describeCommandStatus(9), "killed by signal 9");
    EXPECT_NE(utils::describeCommandStatus(-1).find("could not be reaped"), std::string::npos);
}

TEST(CommandStatusTest, TheNumberInTheMessageIsNeverTheRawStatus)
{
    // The whole point. 256 must not appear when the command exited 1.
    EXPECT_EQ(utils::describeCommandStatus(1 << 8).find("256"), std::string::npos)
        << utils::describeCommandStatus(1 << 8);
    EXPECT_EQ(utils::describeCommandStatus(127 << 8).find("32512"), std::string::npos)
        << utils::describeCommandStatus(127 << 8);
}

// --- concurrency: two power requests must not report each other's outcome.

namespace
{

/**
 * One strategy object serving two concurrent requests, with a rendezvous so the overlap is chosen
 * by the test rather than by the scheduler.
 *
 * [Co-developed with claude code -- Adam]
 * "Start two threads and hope" would be flaky in the direction that matters -- it would pass on a
 * good day against the broken code. Here request A is parked *inside* powerOn, between its own
 * commands, for exactly as long as it takes request B to run and fail. Commands are routed by the
 * switch name they carry, which is how one shared object can answer differently for each request.
 */
class RendezvousOvs : public OVSPowerStrategy
{
  public:
    std::atomic<bool> aParked{false};
    std::atomic<bool> bFinished{false};

  protected:
    bool executeSystemCommand(const std::string& cmd) override
    {
        if (cmd.find("s1") != std::string::npos && !aParked.exchange(true))
        {
            while (!bFinished.load())
            {
                std::this_thread::yield();
            }
        }
        // Everything naming s2 fails; everything naming s1 succeeds.
        return cmd.find("s2") == std::string::npos;
    }

    std::optional<std::vector<std::string>> executeListPorts(const std::string&) override
    {
        return std::vector<std::string>{};
    }
};

} // namespace

TEST(OvsPowerStrategyConcurrencyTest, AFailedRequestDoesNotMakeAConcurrentOneReportFailure)
{
    // powerOn/powerOff used to reset and read a *member* flag, and there is one OVSPowerStrategy for
    // the whole process (DeviceConfigurationAndPowerManager::m_ovsPowerStrategy) while the HTTP
    // server runs one io_context across std::thread::hardware_concurrency() threads with no strand.
    // So bringing s1 up while s2 failed to come up reported s1 as failed too.
    //
    // Against the member-flag version this fails deterministically: B sets the shared flag while A
    // is parked mid-powerOn, and A reads it on the way out.
    Fixture fixA;
    Fixture fixB;
    (*fixA.graph)[fixA.sw].isUp = false;
    (*fixB.graph)[fixB.sw].isUp = false;

    RendezvousOvs shared;

    OpResult resultA = OpResult::failure(0, "never ran");
    std::thread a([&] { resultA = shared.powerOn(fixA.sw, "s1", 1, fixA.monitor.get()); });

    while (!shared.aParked.load())
    {
        std::this_thread::yield();
    }

    const OpResult resultB = shared.powerOn(fixB.sw, "s2", 2, fixB.monitor.get());
    shared.bFinished.store(true);
    a.join();

    EXPECT_FALSE(resultB.ok) << "every command request B issued failed";
    EXPECT_TRUE(resultA.ok) << "every command request A issued succeeded, but it reported: "
                            << resultA.message;
    EXPECT_TRUE(fixA.isUp()) << "a successful power-on must mark its own vertex up";
    EXPECT_FALSE(fixB.isUp()) << "a failed power-on must not mark its vertex up";
}
