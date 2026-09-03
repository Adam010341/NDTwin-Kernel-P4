/**
 * @file test_PollDoesNotResurrect.cpp
 * @brief FINDINGS #46 (with #35 and #36): the topology poll used to overwrite a commanded
 *        power-off, permanently, and the power API then declined to fix it.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT THE DEFECT WAS
 *
 * TopologyAndFlowMonitor::updateSwitches applied the control plane's switch list with
 *
 *     (*m_graph)[*vertexSwitchOpt].isUp = true;
 *
 * and no else branch anywhere in the function. So the poll was not a liveness writer at all, it
 * was a one-way ratchet: the only thing it could ever say about a switch's power was "up".
 *
 * That matters because being listed is not evidence of being powered. The P4 proxy went on
 * listing a killed switch for D = 3.06 s after it died (round3 07_), so a power-off landing
 * shortly before a poll was undone by that poll -- and because nothing on the discovery path
 * ever writes false, the resurrection was permanent, re-asserted every 30 s for ever.
 *
 * Measured on the live 10-switch bmv2 fabric (round3 08_/09_/11_):
 *   - power-off fired ~1.5 s BEFORE the next poll  -> lost 8 times in 14
 *   - power-off fired ~2 s AFTER a poll            -> lost 0 times in 4
 *   - every loss put is_up back to 1 at t_off + 2.31 s -- the instant the poll that still listed
 *     the switch was applied. A phase-dependent defect, not a flaky one.
 *
 * #35 is the other half and is what made it unrecoverable (#36): both power directions returned
 * early on the graph's `isUp`. After a resurrection the graph said up, so `power on` returned
 * 200 "Success" in ~1 ms having run no command -- 4 of 4 past the 15 s distrust window -- and the
 * switch could only be recovered out of band.
 *
 * WHAT THESE ASSERT
 *
 * 🔴 BOTH DIRECTIONS, because only one of them is the finding and a gate that pins only that one
 * would pass a poll that never marks anything up:
 *
 *   1. discovery must NOT lift `isUp` for a switch with a standing commanded power-off, and must
 *      keep not lifting it however many polls arrive (the permanence half);
 *   2. discovery MUST still lift `isUp` for every switch that has no such command -- including
 *      one the liveness worker has just marked down. Losing this is a bigger outage than the
 *      defect: it is the only writer that brings a switch back for anything liveness answers
 *      Unknown about.
 *
 * plus the seam that makes (1) possible -- the observation writers (setVertexUp/setVertexDown,
 * which the 1 Hz pingWorker calls) must not be able to set or clear the commanded state -- and
 * the two #35 early returns, each asserted by the commands that did or did not reach the seam.
 *
 * WHY THE FIXTURE STARTS THE POWER MANAGER TOO
 *
 * The resurrection has two possible doors and only one of them is this finding. The other is the
 * 1 Hz liveness worker, which reads the proxy's cached `probe_ok` and calls setVertexUp on a
 * switch it has already been told is dead (P4PowerStrategy.cpp records that sequence from a live
 * fabric). A fixture that never starts DeviceConfigurationAndPowerManager cannot tell a fix that
 * closes the poll door from one that happens to run with the other door bolted, so this one
 * starts it -- monitor first, manager second, exactly as main.cpp does, stopped in reverse.
 *
 * The fixture switch carries dpid 46288 (0xb4d0) for a reason: no fabric in this repository uses
 * it, so p4LivenessFor's "the proxy does not know this switch" branch answers Unknown and the
 * running worker cannot write to this vertex even if a real proxy happens to be up on the machine
 * while the suite runs. The concurrency is real; the outcome is not left to it.
 */

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "ndt_core/power_management/OVSPowerStrategy.hpp"
#include "ndt_core/power_management/P4PowerStrategy.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

namespace
{

/// 0xb4d0. Deliberately not a dpid any topology in this repository uses -- see the file header.
constexpr uint64_t kDpid = 46288;

/// One bmv2 switch, no edges. Small on purpose: nothing here depends on parse time, and a small
/// file is the one a racy implementation gets away with, so nothing can pass by being slow.
constexpr const char* kOneBmv2Switch =
    R"({"nodes":[{"brand_name":"BMv2","bridge_name":"s1","device_layer":2,"device_name":"s1",)"
    R"("nickname":"s1","dpid":46288,"ip":["192.168.123.11"],"mac":0,"smart_plug_ip":"",)"
    R"("smart_plug_outlet":0,"vertex_type":0}],"edges":[],"links":[]})";

/// Exposes the protected discovery writer. One control-plane poll, as the kernel applies it.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;
    void pollSwitches(const std::string& json) { updateSwitches(json); }
};

/// Records commands instead of running them, and drives the distrust-window clock. Same shape as
/// tests/test_P4PowerStrategy.cpp's fake, for the same reason: both power operations are command
/// sequences, so "did this actuate" is answerable only by what reached the seam.
class FakeP4 : public P4PowerStrategy
{
  public:
    std::vector<std::string> commands;
    std::string failSubstring;

    /// Starts at the steady_clock epoch, not at the real now(): a test that forgets to advance it
    /// cannot then pass by accident on however long the suite happened to take.
    std::chrono::steady_clock::time_point fakeNow{};
    void advance(std::chrono::seconds by) { fakeNow += by; }

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

  protected:
    bool executeSystemCommand(const std::string& cmd) override
    {
        commands.push_back(cmd);
        return failSubstring.empty() || cmd.find(failSubstring) == std::string::npos;
    }

    std::chrono::steady_clock::time_point now() const override { return fakeNow; }
};

/// The OVS half. Every seam OVSPowerStrategy shells through is covered, including the argv one:
/// tests/test_OvsPowerStrategy.cpp's header records that a fake covering only the string seam let
/// `sudo ovs-vsctl add-br` really run against the developer's machine.
class FakeOvs : public OVSPowerStrategy
{
  public:
    std::vector<std::string> commands;

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

  protected:
    bool executeSystemCommand(const std::string& cmd) override
    {
        commands.push_back(cmd);
        return true;
    }

    bool executeArgvCommand(const std::vector<std::string>& argv) override
    {
        return executeSystemCommand(utils::describeArgv(argv));
    }

    std::optional<std::vector<std::string>> executeListPorts(const std::string&) override
    {
        return std::vector<std::string>{};
    }

    std::optional<SflowBridgeState> executeReadSflowState(const std::string&) override
    {
        return SflowBridgeState{};
    }
};

class PollDoesNotResurrectTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }

    void SetUp() override
    {
        m_topoPath = std::string(::testing::TempDir()) + "f46_one_bmv2_switch.json";
        std::ofstream out(m_topoPath);
        ASSERT_TRUE(out.is_open()) << "cannot write the fixture topology to " << m_topoPath;
        out << kOneBmv2Switch;
        out.close();

        // activeTopologyPath() honours this, so start() loads the fixture rather than a shipped
        // model, and nothing here touches a file under version control.
        ::setenv("NDTWIN_TOPO_FILE", m_topoPath.c_str(), 1);

        m_graph = std::make_shared<Graph>();
        m_mutex = std::make_shared<std::shared_mutex>();
        m_monitor = std::make_shared<TestableMonitor>(m_graph, m_mutex,
                                                      std::make_shared<EventBus>(), utils::MININET);
        m_manager = std::make_shared<DeviceConfigurationAndPowerManager>(m_monitor, utils::MININET,
                                                                        "127.0.0.1", nullptr);
    }

    void TearDown() override
    {
        if (m_started)
        {
            // Reverse of the start order. The manager's stop() joins all three of its threads only
            // since fix/b5-kernel-shutdown; before that this would have aborted.
            m_manager->stop();
            m_monitor->stop();
        }
        ::unsetenv("NDTWIN_TOPO_FILE");
        std::remove(m_topoPath.c_str());
    }

    /// The start sequence main.cpp uses -- monitor (main.cpp:409) then power manager
    /// (main.cpp:432) -- plus the bookkeeping that makes TearDown join both.
    void startMonitor()
    {
        m_monitor->start();
        m_manager->start();
        m_started = true;
    }

    /// A converged fabric. loadStaticTopologyFromFile starts every vertex at `isUp = false`, so
    /// without this a "power-off" is being applied to a switch the twin already calls down -- which
    /// makes several of the cases below vacuous and lets OVS's own already-down guard swallow the
    /// whole operation. Written through the observation writer, because that is what puts it there
    /// in production: the 1 Hz liveness worker, on the first probe that answers.
    void converge() { m_monitor->setVertexUp(sw()); }

    /// The fixture switch, after start() has loaded the topology.
    Graph::vertex_descriptor sw()
    {
        const auto vOpt = m_monitor->findSwitchByDpid(kDpid);
        EXPECT_TRUE(vOpt.has_value()) << "the fixture topology did not load";
        return vOpt.value_or(Graph::vertex_descriptor{});
    }

    bool isUp()
    {
        std::shared_lock lock(*m_mutex);
        return (*m_graph)[sw()].isUp;
    }

    bool isEnabled()
    {
        std::shared_lock lock(*m_mutex);
        return (*m_graph)[sw()].isEnabled;
    }

    /// Ryu's /v1.0/topology/switches shape: dpid as a 16-digit hex string. This is the reply the
    /// proxy really served for 3.06 s after each kill -- the switch is still in it.
    static std::string switchListing(uint64_t dpid)
    {
        char hex[32];
        std::snprintf(hex, sizeof(hex), "%016lx", static_cast<unsigned long>(dpid));
        return std::string(R"([{"dpid":")") + hex + R"("}])";
    }

    std::string m_topoPath;
    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<TestableMonitor> m_monitor;
    std::shared_ptr<DeviceConfigurationAndPowerManager> m_manager;
    bool m_started = false;
};

} // namespace

// --- 1. the finding: a commanded power-off must survive the poll ---------------------------------

/**
 * The defect itself, in the phase that lost it: the switch is killed, and the poll that arrives
 * next still lists it because the control plane has not noticed yet. That poll used to put `is_up`
 * back to 1 at t_off + 2.31 s, 8 times in 14.
 */
TEST_F(PollDoesNotResurrectTest, ACommandedPowerOffSurvivesTheNextPollThatStillListsTheSwitch)
{
    startMonitor();
    converge();
    FakeP4 p4;

    ASSERT_EQ(p4.powerOff(sw(), "s1", m_monitor.get()).ok, true)
        << "the fixture's power-off did not succeed, so nothing below is about resurrection";
    ASSERT_FALSE(isUp()) << "power-off did not take the switch down at all";

    // The stale reply, applied exactly as the poll thread applies it.
    m_monitor->pollSwitches(switchListing(kDpid));

    EXPECT_FALSE(isUp())
        << "the topology poll marked a commanded-off switch up again. This is FINDINGS #46: the "
           "control plane lists a switch it has not yet noticed is gone, and being listed is not "
           "evidence of being powered";
}

/**
 * The half that makes the defect matter. A transient overwrite would age out; this one did not,
 * because no writer on the discovery path ever sets false. Three polls, because one proves only
 * that the first was declined.
 */
TEST_F(PollDoesNotResurrectTest, EveryLaterPollDeclinesToo)
{
    startMonitor();
    converge();
    FakeP4 p4;
    ASSERT_EQ(p4.powerOff(sw(), "s1", m_monitor.get()).ok, true);

    for (int poll = 1; poll <= 3; ++poll)
    {
        m_monitor->pollSwitches(switchListing(kDpid));
        EXPECT_FALSE(isUp()) << "poll " << poll << " marked the commanded-off switch up. The "
                                "resurrection was permanent precisely because it repeated";
    }
}

/**
 * Only the power axis is vetoed. `isEnabled` means "the control plane can drive this", discovery
 * is its only writer, and the loader starts everything false -- so a fix that stopped writing it
 * would blank the graph. This is the same trap AdministrativeDisableTest's last case guards.
 */
TEST_F(PollDoesNotResurrectTest, DiscoveryStillEnablesACommandedOffSwitch)
{
    startMonitor();
    converge();
    FakeP4 p4;
    ASSERT_EQ(p4.powerOff(sw(), "s1", m_monitor.get()).ok, true);

    m_monitor->pollSwitches(switchListing(kDpid));

    EXPECT_TRUE(isEnabled())
        << "the poll stopped writing isEnabled. That flag answers a different question, discovery "
           "is the only thing that ever sets it true, and the loader starts it false";
}

// --- 2. the relaxation control: discovery must still mark switches up ----------------------------

/**
 * 🔴 THE TEST THAT MAKES THE ONES ABOVE WORTH ANYTHING. A poll that never marks anything up passes
 * every assertion in section 1 and is a worse defect than the one being fixed: for everything the
 * liveness worker answers Unknown about, discovery is the only writer that brings a switch back.
 *
 * The switch starts down the way it really does -- setVertexDown is what the 1 Hz worker calls on
 * a failed probe -- and no power-off has been commanded.
 */
TEST_F(PollDoesNotResurrectTest, DiscoveryStillMarksAnUncommandedSwitchUp)
{
    startMonitor();

    m_monitor->setVertexDown(sw()); // the liveness worker's opinion, not a command
    ASSERT_FALSE(isUp());

    m_monitor->pollSwitches(switchListing(kDpid));

    EXPECT_TRUE(isUp())
        << "the control plane listed a switch nobody had powered off and the poll left it down. "
           "Discovery is real evidence; a poll that never writes up is not a fix, it is a fabric "
           "that never comes back";
}

/**
 * The same control, after the command has been withdrawn. Power-on must not leave the veto
 * standing, or a switch could be brought up and then never confirmed up by the only writer that
 * covers the Unknown case.
 */
TEST_F(PollDoesNotResurrectTest, APowerOnLetsDiscoveryLiftTheSwitchAgain)
{
    startMonitor();
    converge();
    FakeP4 p4;
    ASSERT_EQ(p4.powerOff(sw(), "s1", m_monitor.get()).ok, true);
    ASSERT_EQ(p4.powerOn(sw(), "s1", kDpid, m_monitor.get()).ok, true);
    EXPECT_FALSE(m_monitor->getVertexAdminPoweredOff(sw()))
        << "power-on left the commanded-off record standing";

    // A later probe blip takes it down; the poll must be allowed to lift it.
    m_monitor->setVertexDown(sw());
    m_monitor->pollSwitches(switchListing(kDpid));

    EXPECT_TRUE(isUp()) << "discovery is still vetoed after a successful power-on";
}

// --- 3. the seam: observation writers must not touch the commanded state -------------------------

/**
 * The second door. Within a second of a confirmed kill the pingWorker reads the proxy's cached
 * `probe_ok: true`, answers Up and calls setVertexUp -- on a switch it has been told is dead. If
 * that call cleared the command, the fix would hold for one tick and then not.
 */
TEST_F(PollDoesNotResurrectTest, TheLivenessWorkersUpDoesNotWithdrawTheCommand)
{
    startMonitor();
    converge();
    FakeP4 p4;
    ASSERT_EQ(p4.powerOff(sw(), "s1", m_monitor.get()).ok, true);

    m_monitor->setVertexUp(sw()); // exactly what the 1 Hz worker calls on a stale probe_ok

    EXPECT_TRUE(m_monitor->getVertexAdminPoweredOff(sw()))
        << "a liveness observation withdrew a power-off command. The 1 Hz worker would then clear "
           "it within a tick of every kill and the poll would resurrect the switch as before";
}

// --- 4. FINDINGS #35: the early returns must consult a measurement, not the graph ----------------

/**
 * Power-off. The guard was `if (!getVertexIsUp(node)) return success;` -- and the graph reads down
 * for a running switch whenever the proxy's probe is failing: mid-restart, reconnect backoff, a
 * missed RPC deadline. A power-off then returned 200 having signalled nothing.
 *
 * The helper is the measurement and is already idempotent: it re-verifies the manifest pid against
 * /proc and prints already-stopped with exit 0 when there is nothing to kill.
 */
TEST_F(PollDoesNotResurrectTest, PowerOffActuatesEvenWhenTheGraphAlreadySaysDown)
{
    startMonitor();
    converge();
    FakeP4 p4;

    m_monitor->setVertexDown(sw()); // a probe blip, not a kill: the process is still running

    const OpResult r = p4.powerOff(sw(), "s1", m_monitor.get());

    EXPECT_EQ(r.ok, true);
    EXPECT_TRUE(p4.ran("ndtwin-p4-power off s1"))
        << "power-off returned success without running a single command, because the graph "
           "already said down. FINDINGS #35: the graph is a cache of someone else's opinion, and "
           "'Success' has to mean /proc was consulted";
}

/**
 * Power-on, past the distrust window. This is #36 exactly: after the poll resurrected a dead
 * switch, `power on` saw `isUp == true`, the 15 s window had expired, and it returned Success in
 * ~1 ms having run nothing -- 4 of 4. The switch was only recoverable out of band.
 *
 * setVertexUp here is the resurrection itself, reproduced through the writer that performed it.
 */
TEST_F(PollDoesNotResurrectTest, PowerOnActuatesWhenACommandedOffIsStillStanding)
{
    startMonitor();
    converge();
    FakeP4 p4;
    ASSERT_EQ(p4.powerOff(sw(), "s1", m_monitor.get()).ok, true);

    p4.advance(std::chrono::seconds(60)); // time alone; the window is closed by evidence now
    m_monitor->setVertexUp(sw());         // the graph now lies about this switch
    p4.commands.clear();

    const OpResult r = p4.powerOn(sw(), "s1", kDpid, m_monitor.get());

    EXPECT_EQ(r.ok, true);
    EXPECT_TRUE(p4.ran("ndtwin-p4-power on s1"))
        << "power-on returned success without starting anything. The graph said up because a poll "
           "had put it there; the process was gone. This is what made #46 unrecoverable";
    EXPECT_TRUE(p4.ran("/p4/readopt/"))
        << "the process was started but never re-adopted: a bmv2 with no pipeline forwards nothing";
}

/**
 * The idempotence the early return existed to provide must still hold, or the Energy-Saving-App's
 * repeated desired-state requests turn into helper failures. Nothing has been commanded off here
 * and the graph is up on its own evidence, so the call is a no-op success that runs no commands.
 */
TEST_F(PollDoesNotResurrectTest, AnAlreadyUpUncommandedPowerOnStillRunsNoCommands)
{
    startMonitor();
    FakeP4 p4;

    m_monitor->setVertexUp(sw());
    p4.advance(std::chrono::seconds(60));

    const OpResult r = p4.powerOn(sw(), "s1", kDpid, m_monitor.get());

    EXPECT_EQ(r.ok, true);
    EXPECT_TRUE(p4.commands.empty())
        << "an already-up switch with no standing command actuated anyway; the helper refuses to "
           "start a second instance, so every repeated desired-state request would 500";
}

// --- 5. the same rule on the OVS plane -----------------------------------------------------------

/**
 * updateSwitches is plane-agnostic -- it applies one reply shape to whatever the switches behind
 * it are -- so a fix wired only into P4PowerStrategy would hold on the plane the evidence came
 * from and not on the default one (`ndt up` with no argument is OVS).
 */
TEST_F(PollDoesNotResurrectTest, AnOvsPowerOffAlsoSurvivesThePoll)
{
    startMonitor();
    converge();
    FakeOvs ovs;

    ASSERT_EQ(ovs.powerOff(sw(), "s1", m_monitor.get()).ok, true);
    ASSERT_TRUE(ovs.ran("del-br s1"));
    ASSERT_FALSE(isUp());

    m_monitor->pollSwitches(switchListing(kDpid));

    EXPECT_FALSE(isUp()) << "the poll marked a deleted OVS bridge up again";

    ASSERT_EQ(ovs.powerOn(sw(), "s1", kDpid, m_monitor.get()).ok, true);
    EXPECT_TRUE(ovs.ran("add-br s1")) << "power-on did not rebuild the bridge";
    EXPECT_FALSE(m_monitor->getVertexAdminPoweredOff(sw()))
        << "the OVS power-on left the commanded-off record standing, so discovery would go on "
           "refusing to mark a live bridge up";
}

// --- 6. Q12: the wire shape, after the ruling ----------------------------------------------------

/**
 * Q12 asked Adam whether `is_up` should become `admin_state` + `reachable` on the wire. He ruled
 * (a) on 2026-09-03: split them, and keep `is_up` as a deprecated alias of `reachable` so the
 * external readers keep working. This case used to assert the opposite -- that no new key
 * appeared -- and was written to go red the moment the question was answered, which is what it
 * has now done.
 *
 * It stays here, pointed the other way, because the state it checks the shape in is this file's
 * state and no other: after a commanded power-off AND the poll that used to undo it. The wider
 * shape and alias assertions live in tests/test_IsUpSplit.cpp.
 */
TEST_F(PollDoesNotResurrectTest, TheEmittedVertexShapeCarriesAdminStateAndReachable)
{
    startMonitor();
    converge();
    FakeP4 p4;
    ASSERT_EQ(p4.powerOff(sw(), "s1", m_monitor.get()).ok, true);

    // After the poll, because the shape has to be right in the state the finding is about.
    m_monitor->pollSwitches(switchListing(kDpid));

    nlohmann::json j;
    {
        std::shared_lock lock(*m_mutex);
        j = (*m_graph)[sw()];
    }

    EXPECT_EQ(j.value("admin_state", ""), "off")
        << "the commanded half of the old is_up now has its own name, and this switch was "
           "commanded off";
    EXPECT_FALSE(j.value("reachable", true))
        << "the observed half must still say the poll did not resurrect it";
    EXPECT_TRUE(j.contains("is_up")) << "is_up is what four consumers read; the ruling keeps it "
                                        "as an alias rather than removing it";
    EXPECT_EQ(j.value("is_up", true), j.value("reachable", false))
        << "the alias drifted from the field it aliases";
}
