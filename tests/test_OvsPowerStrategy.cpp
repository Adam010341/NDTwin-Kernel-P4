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

#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>
#include <vector>

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
    void executeSystemCommand(const std::string& cmd) override
    {
        commands.push_back(cmd);
        if (!failSubstring.empty() && cmd.find(failSubstring) != std::string::npos)
        {
            m_lastCommandFailed = true;
        }
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
    EXPECT_NE(utils::describeCommandStatus(127 << 8).find("command not found"), std::string::npos);
    EXPECT_NE(utils::describeCommandStatus(1 << 8).find("sudo password prompt"), std::string::npos);
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
