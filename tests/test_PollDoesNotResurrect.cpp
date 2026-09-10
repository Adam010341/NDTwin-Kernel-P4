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
// [Co-developed with claude code -- Adam] B-6: the link half loads the shipped topology, which the
// switch half above does not need.
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <stdexcept>
#include <string>
#include <vector>

#include <unistd.h> // getpid, for the per-process fixture path

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include <boost/graph/adjacency_list.hpp>

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

    /// FINDINGS #82. The bridge this fake's machine has, rather than a constant: `del-br` takes
    /// it away and `add-br` puts it back, so a power-off followed by a power-on sees the machine
    /// it just changed. A fixed answer would make one of the two directions untestable here --
    /// "exists" always would stop power-on ever rebuilding, "absent" always would stop power-off
    /// ever tearing down -- and the cases below need both to happen in sequence.
    /// [Co-developed with claude code -- Adam]
    bool bridgePresent = true;

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
        if (cmd.find("del-br") != std::string::npos)
        {
            bridgePresent = false;
        }
        else if (cmd.find("add-br") != std::string::npos)
        {
            bridgePresent = true;
        }
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

    /// FINDINGS #82's seam. Covered here for the reason the other four are: without it these
    /// cases would run `sudo ovs-vsctl br-exists` against whatever machine the suite is on, and
    /// the answer would depend on whether a fabric happened to be up.
    std::optional<bool> executeBridgeExists(const std::string&) override
    {
        return bridgePresent;
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
        // [Co-developed with claude code -- Adam]
        // 🔴 PER PROCESS AND PER CASE. This was a single fixed name, and ctest runs one process
        // per case (gtest_discover_tests) -- so two cases of this suite running at the same time
        // wrote, read and std::remove()d ONE file. The loser's start() found no topology, sw()
        // then indexed an empty graph, and the case died with SIGSEGV rather than failing.
        // Measured before this line existed: `ctest -j8 -R PollDoesNotResurrectTest` eight times
        // gave five failing runs and seven SegFaults, across five different cases; the same
        // command at -j2 passed six times out of six, which is why it survived until a suite
        // this size made the window wide enough. The test name is in the path as well as the
        // pid, so a future --gtest_repeat or a sharded run cannot collide with itself either.
        m_topoPath = std::string(::testing::TempDir()) + "f46_one_bmv2_switch_" +
                     ::testing::UnitTest::GetInstance()->current_test_info()->name() + "_" +
                     std::to_string(static_cast<long>(::getpid())) + ".json";
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
    ///
    /// [Co-developed with claude code -- Adam]
    /// 🔴 THROWS rather than returning a default descriptor. It used to be
    ///
    ///     EXPECT_TRUE(vOpt.has_value()) << "the fixture topology did not load";
    ///     return vOpt.value_or(Graph::vertex_descriptor{});
    ///
    /// -- and every caller feeds the result straight to `(*m_graph)[...]`. A default descriptor
    /// indexed into an empty graph is undefined behaviour, so a fixture that failed to load did
    /// not fail its case: it took the whole test process down with SIGSEGV, and under ctest that
    /// is one line of "Exception: SegFault" with the EXPECT's message nowhere in sight.
    ///
    /// The EXPECT was the giveaway -- a non-fatal assertion in a function whose return value is
    /// then dereferenced can only report the problem, never prevent it, and ASSERT_ is not
    /// available here because it needs a void return. gtest reports an escaped exception as a
    /// failure of the case that threw, which is what a broken fixture should be.
    Graph::vertex_descriptor sw()
    {
        const auto vOpt = m_monitor->findSwitchByDpid(kDpid);
        if (!vOpt.has_value())
        {
            throw std::runtime_error("the fixture topology did not load: no switch with dpid " +
                                     std::to_string(kDpid) + " (topology file " + m_topoPath +
                                     ")");
        }
        return *vOpt;
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

    p4.advance(std::chrono::seconds(60));
    m_monitor->setVertexUp(sw());         // the graph now lies about this switch

    // [Co-developed with claude code -- Adam] -- FINDINGS #80.
    // 🔴 THIS LINE IS WHAT MAKES THE CASE DISCRIMINATE, and it was not needed before. The
    // distrust window used to expire on a clock, so `advance(60)` above closed it and the only
    // thing left forcing this power-on to act was the standing COMMAND -- which is what the case
    // is named for. The window is now bounded by evidence, so time alone leaves it open and the
    // call would actuate whether or not the command survived: the case would pass while saying
    // nothing about the flag. mutate_poll_does_not_resurrect.sh M2/M3/M8 caught exactly that.
    //
    // A probe taken after the kill is also the real scenario: somebody restarted the switch out
    // of band, the twin has seen it serving, and the command has still not been withdrawn.
    ASSERT_TRUE(p4.acceptLivenessUp("s1", p4.fakeNow))
        << "a probe dated after the kill did not close the window, so the assertion below would "
           "pass on the window rather than on the command";

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

/**
 * FINDINGS #82: the OVS half of #35, and the reason #46's fix was conditional on this plane.
 *
 * [Co-developed with claude code -- Adam]
 * OVSPowerStrategy::powerOff opened with `if (!getVertexIsUp(node)) return success;`, and that
 * early return sits ABOVE setVertexPoweredOffByCommand. So on OVS the commanded-off record was
 * written only when the graph happened to say up at the moment the power-off arrived -- and after
 * a first power-off the graph says down by construction. A second `action=off` therefore returned
 * 200 having recorded nothing, and any poll that still listed the switch lifted it straight back.
 *
 * This is the same shape as AnOvsPowerOffAlsoSurvivesThePoll one case up, entered from the state
 * that used to defeat it: the bridge is already gone, so there is nothing to tear down, and the
 * ONLY thing the power-off has to do is the thing the early return skipped.
 */
TEST_F(PollDoesNotResurrectTest, ARedundantOvsPowerOffIsStillRecordedAsACommand)
{
    startMonitor();
    converge();
    FakeOvs ovs;

    ASSERT_EQ(ovs.powerOff(sw(), "s1", m_monitor.get()).ok, true);
    ASSERT_TRUE(ovs.ran("del-br s1"));

    // The graph now says down and the bridge is really gone -- the exact state the early return
    // read as "nothing to do". Clear the command first, so this case cannot pass on the record
    // the FIRST power-off left behind: what is asserted below has to have been written by the
    // second one.
    m_monitor->clearVertexAdminPowerOff(sw());
    ASSERT_FALSE(m_monitor->getVertexAdminPoweredOff(sw()));
    ovs.commands.clear();

    const OpResult again = ovs.powerOff(sw(), "s1", m_monitor.get());

    EXPECT_EQ(again.ok, true) << again.message;
    EXPECT_FALSE(ovs.ran("del-br"))
        << "deleted a bridge that ovs-vsctl says is not there; on a fabric whose bridge names are "
           "reused that is somebody else's switch";
    EXPECT_TRUE(m_monitor->getVertexAdminPoweredOff(sw()))
        << "the redundant power-off returned 200 and recorded nothing. FINDINGS #82: on OVS this "
           "is how a power-off stopped being protected by #46 at all";

    m_monitor->pollSwitches(switchListing(kDpid));

    EXPECT_FALSE(isUp())
        << "the poll lifted a switch whose bridge does not exist, because the power-off that "
           "would have vetoed it took an early return on the graph's own cached isUp";
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

// =================================================================================================
// doc/KNOWN-ISSUES.md B-6 -- the EDGE half of the same defect.
//
// [Co-developed with claude code -- Adam]
//
// WHAT THE DEFECT WAS
//
// TopologyAndFlowMonitor::updateLinks applied Ryu's link list with
//
//     (*m_graph)[edgeOpt.value()].isUp = true;
//
// and, exactly like updateSwitches above it, no else branch anywhere in the function. So a poll
// could only ever say "up" about a link. That was believed to be safe, and the belief is written
// down in this file's own run() header: Ryu DROPS a failed link from /v1.0/topology/links, "so a
// poll can fill in what was missed but cannot resurrect an edge the push path correctly took
// down". True for a link that really broke. False for one that was only DECLARED broken through
// POST /ndt/link_failure_detected: nothing about the fabric changed, so Ryu keeps listing it.
//
// Measured 2026-09-04 (night round R2-B, logs/r2-20-linkfail-probe.log): the endpoint answered 200
// and both directions read is_up=false within 0.02 s; 5 trials out of 5 flipped back to is_up=true
// within 30 s, each one ~0.6 s after a topology poll, with /ndt/link_recovery_detected never
// called and no line in kernel.log. The netem control arm (a real cut) stayed down 0 of 1.
//
// WHAT THESE ASSERT -- 🔴 BOTH DIRECTIONS, for the reason spelled out at the top of this file:
//
//   1. a poll must NOT lift a link with a standing declaration, however many polls arrive;
//   2. a poll MUST still lift every link nobody declared down -- including one the derived
//      liveness pass took down when its switch went away. updateLinks is the ONLY writer that
//      brings a link back, so an implementation that stops writing `isUp = true` passes every
//      assertion in direction 1 and is a worse outage than the defect.
//
// plus the seam that makes (1) possible -- the observation writers must not be able to set or
// clear the declaration -- and the administrative axis, which the veto must leave alone.
// =================================================================================================

namespace
{

/// s1:1 <-> s5:1 in the shipped 10-switch Mininet topology. A real pair from a real file, so the
/// case cannot pass against a graph shape the kernel never loads.
constexpr uint64_t kLinkS1 = 1;
constexpr uint64_t kLinkS5 = 5;
constexpr uint32_t kLinkPort = 1;

/// Exposes the protected loader and the protected discovery/derivation writers for the link half.
class LinkTestableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void load(const std::string& path) { loadStaticTopologyFromFile(path); }
    void pollLinks(const std::string& json) { updateLinks(json); }
    void reconcile() { reconcileDerivedLiveness(); }
    static constexpr unsigned missesBeforeIsolating() { return kMissesBeforeIsolating; }
};

class DeclaredLinkFailureTest : public ::testing::Test
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
        m_graph = std::make_shared<Graph>();
        m_mutex = std::make_shared<std::shared_mutex>();
        m_monitor = std::make_shared<LinkTestableMonitor>(
            m_graph, m_mutex, std::make_shared<EventBus>(), utils::MININET);

        // The shipped topology, not a hand-written one: updateLinks resolves an edge by
        // (dpid, port) out of the STATIC file, so a fixture that invented the pairing would be
        // testing its own arithmetic. Nothing is written to it -- this is a read.
        static const char* kCandidates[] = {
            "setting/StaticNetworkTopologyMininet_10Switches.json",
            "../setting/StaticNetworkTopologyMininet_10Switches.json",
            "../../setting/StaticNetworkTopologyMininet_10Switches.json",
        };
        bool loaded = false;
        for (const char* candidate : kCandidates)
        {
            if (std::filesystem::exists(candidate))
            {
                m_monitor->load(candidate);
                loaded = true;
                break;
            }
        }
        ASSERT_TRUE(loaded) << "could not find StaticNetworkTopologyMininet_10Switches.json from "
                            << std::filesystem::current_path().string();
        {
            std::shared_lock lock(*m_mutex);
            ASSERT_EQ(boost::num_edges(*m_graph), 288u) << "wrong topology loaded";
        }
        converge();
    }

    /// The state a converged fabric is in. The loader starts everything down, so without this
    /// every assertion about "the poll lifted it" would be about an edge that was never up and
    /// every assertion about "it stayed down" would be vacuous.
    void converge()
    {
        std::unique_lock lock(*m_mutex);
        for (auto v : boost::make_iterator_range(boost::vertices(*m_graph)))
        {
            (*m_graph)[v].isUp = true;
            (*m_graph)[v].isEnabled = true;
            (*m_graph)[v].downReason = DownReason::None;
        }
        for (auto e : boost::make_iterator_range(boost::edges(*m_graph)))
        {
            (*m_graph)[e].isUp = true;
            (*m_graph)[e].isEnabled = true;
            (*m_graph)[e].downReason = DownReason::None;
        }
    }

    /// The forward edge s1:1 -> s5. Throws rather than returning a default descriptor, for the
    /// reason sw() above does: a default descriptor indexed into a graph is undefined behaviour,
    /// and a broken fixture must fail its case rather than take the process down.
    Graph::edge_descriptor fwd() { return edgeOrThrow(kLinkS1, kLinkS5); }
    Graph::edge_descriptor rev() { return edgeOrThrow(kLinkS5, kLinkS1); }

    Graph::edge_descriptor edgeOrThrow(uint64_t src, uint64_t dst)
    {
        const auto eOpt = m_monitor->findEdgeBySrcAndDstDpid({src, dst});
        if (!eOpt.has_value())
        {
            throw std::runtime_error("the fixture topology has no edge " + std::to_string(src) +
                                     " -> " + std::to_string(dst));
        }
        return *eOpt;
    }

    bool edgeIsUp(Graph::edge_descriptor e)
    {
        std::shared_lock lock(*m_mutex);
        return (*m_graph)[e].isUp;
    }

    bool edgeIsEnabled(Graph::edge_descriptor e)
    {
        std::shared_lock lock(*m_mutex);
        return (*m_graph)[e].isEnabled;
    }

    /// What /ndt/get_graph_data publishes for this edge. The precedence rule, not the raw field.
    std::string edgeDownReason(Graph::edge_descriptor e)
    {
        std::shared_lock lock(*m_mutex);
        return downReasonToString(effectiveDownReason((*m_graph)[e]));
    }

    /// Ryu's /v1.0/topology/links shape: dpids as 16-digit hex, ports as 8-digit hex. Both
    /// directions of the s1 <-> s5 link, which is what the real reply carries -- and the whole
    /// point of the case is that this reply is IDENTICAL before and after a declaration, because
    /// declaring a failure changes nothing on the fabric for Ryu to notice.
    static std::string linkListing()
    {
        return endpointPair(kLinkS1, kLinkPort, kLinkS5, kLinkPort) + "," +
               endpointPair(kLinkS5, kLinkPort, kLinkS1, kLinkPort);
    }

    static std::string bothDirections() { return "[" + linkListing() + "]"; }

    static std::string endpointPair(uint64_t srcDpid,
                                    uint32_t srcPort,
                                    uint64_t dstDpid,
                                    uint32_t dstPort)
    {
        char s[64];
        std::snprintf(s,
                      sizeof(s),
                      R"({"src":{"dpid":"%016lx","port_no":"%08x"},)",
                      static_cast<unsigned long>(srcDpid),
                      srcPort);
        char d[64];
        std::snprintf(d,
                      sizeof(d),
                      R"("dst":{"dpid":"%016lx","port_no":"%08x"}})",
                      static_cast<unsigned long>(dstDpid),
                      dstPort);
        return std::string(s) + d;
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<LinkTestableMonitor> m_monitor;
};

} // namespace

// --- direction 1: the finding -- a declaration must survive the poll -----------------------------

/**
 * 🔴 THE FINDING. The declaration is made, and the poll that arrives next still lists the link,
 * because a declaration has no LLDP consequence and Ryu has nothing to notice. That poll used to
 * put is_up back to true, 5 times in 5, within 30 s.
 */
TEST_F(DeclaredLinkFailureTest, ADeclaredLinkFailureSurvivesATopologyPoll)
{
    m_monitor->setEdgeDownByDeclaration(fwd());
    m_monitor->setEdgeDownByDeclaration(rev());
    ASSERT_FALSE(edgeIsUp(fwd())) << "the declaration did not take the link down at all";
    ASSERT_FALSE(edgeIsUp(rev())) << "the declaration did not take the reverse direction down";

    // The reply Ryu really keeps serving, applied exactly as the poll thread applies it.
    m_monitor->pollLinks(bothDirections());

    EXPECT_FALSE(edgeIsUp(fwd()))
        << "a topology poll lifted a link an operator declared failed; the injection ends when the "
           "control plane's list is next applied rather than when it is withdrawn (B-6)";
    EXPECT_FALSE(edgeIsUp(rev()))
        << "the reverse direction was resurrected by the poll, so the link is half up and no "
           "caller asked for that";
    EXPECT_EQ(edgeDownReason(fwd()), "declared")
        << "an edge that is down because somebody said so must say so: that is the whole "
           "difference between this fix and an internal flag";
}

/**
 * The permanence half. One declined poll could be a phase accident; the defect was that the poll
 * ran every 30 s for ever and each one undid the injection again. Ten polls stands for "for ever":
 * nothing in updateLinks counts, so a rule that holds ten times holds indefinitely.
 */
TEST_F(DeclaredLinkFailureTest, EveryLaterPollDeclinesTheDeclaredLinkToo)
{
    m_monitor->setEdgeDownByDeclaration(fwd());

    for (int poll = 0; poll < 10; ++poll)
    {
        m_monitor->pollLinks(bothDirections());
        ASSERT_FALSE(edgeIsUp(fwd()))
            << "poll " << poll << " lifted the declared link; a measurement window longer than "
            << "one polling interval cannot rely on the injection holding";
    }
    EXPECT_EQ(edgeDownReason(fwd()), "declared");
}

// --- direction 2: the poll must still be a writer ------------------------------------------------

/**
 * 🔴 THE OVER-CORRECTION, and the reason this suite is not just the finding. A poll that never
 * writes `isUp = true` satisfies every assertion above and is a bigger outage than the defect:
 * updateLinks is the ONLY writer that brings an inter-switch link back, so `// isUp = true;` would
 * leave the graph dark for every link that was ever down.
 */
TEST_F(DeclaredLinkFailureTest, APollStillRaisesALinkNobodyDeclaredDown)
{
    // Down by observation, not by declaration -- the state a real link failure leaves behind, and
    // the state the loader starts every edge in.
    m_monitor->setEdgeDown(fwd());
    ASSERT_FALSE(edgeIsUp(fwd()));

    m_monitor->pollLinks(bothDirections());

    EXPECT_TRUE(edgeIsUp(fwd()))
        << "discovery stopped lifting a link nobody declared down; Ryu listing a link is real "
           "evidence and this is the only writer that acts on it";
    EXPECT_EQ(edgeDownReason(fwd()), "none");
}

/**
 * The recovery path end to end: Ryu drops a genuinely failed link and lists it again when it comes
 * back, and the twin must follow. Distinct from the case above because it starts from a
 * DECLARATION that was then withdrawn -- the sequence a fault-injection round actually runs.
 */
TEST_F(DeclaredLinkFailureTest, ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery)
{
    m_monitor->setEdgeDownByDeclaration(fwd());
    m_monitor->pollLinks(bothDirections());
    ASSERT_FALSE(edgeIsUp(fwd())) << "pre-condition: the declaration must be holding";

    m_monitor->clearEdgeDeclaredDown(fwd());
    m_monitor->pollLinks(bothDirections());

    EXPECT_TRUE(edgeIsUp(fwd()))
        << "the declaration was withdrawn and the control plane still lists the link, so the next "
           "poll must bring it back -- otherwise a withdrawn injection is unrecoverable";
    EXPECT_EQ(edgeDownReason(fwd()), "none");
}

/**
 * The withdrawal itself, asserted on the flag rather than through a poll: recovery must SPEND the
 * declaration. A recovery handler that raises `isUp` but leaves the declaration standing publishes
 * `is_up: true, down_reason: "declared"` and the next poll declines an edge nobody is holding.
 */
TEST_F(DeclaredLinkFailureTest, ADeclaredRecoveryLetsThePollRaiseTheEdgeAgain)
{
    m_monitor->setEdgeDownByDeclaration(fwd());
    ASSERT_TRUE(m_monitor->getEdgeDeclaredDown(fwd()));

    m_monitor->clearEdgeDeclaredDown(fwd());

    EXPECT_FALSE(m_monitor->getEdgeDeclaredDown(fwd()))
        << "the declaration outlived its withdrawal; nothing else clears it, so this edge would "
           "be suppressed for the rest of the process";
    m_monitor->pollLinks(bothDirections());
    EXPECT_TRUE(edgeIsUp(fwd()));
}

// --- the axes the veto must not touch ------------------------------------------------------------

/**
 * `isEnabled` is the ADMINISTRATIVE axis -- "the control plane can drive this" -- and it is
 * written unconditionally by discovery for everything it reports. A veto that also blocks it turns
 * /ndt/link_failure_detected into a covert DisableSwitch: the link would stop being routable
 * rather than stop being up, and nothing in the API says that.
 */
TEST_F(DeclaredLinkFailureTest, ADeclaredDownEdgeIsStillAdministrativelyEnabled)
{
    // The descriptor is resolved BEFORE the lock is taken: findEdgeBySrcAndDstDpid takes a
    // shared_lock on the same mutex, and std::shared_mutex is not recursive -- calling fwd()
    // inside the block below throws "Resource deadlock avoided" rather than blocking, which is
    // how this was found. [Co-developed with claude code -- Adam]
    const auto e = fwd();
    {
        std::unique_lock lock(*m_mutex);
        (*m_graph)[e].isEnabled = false; // as the loader leaves it
    }
    m_monitor->setEdgeDownByDeclaration(fwd());

    m_monitor->pollLinks(bothDirections());

    EXPECT_TRUE(edgeIsEnabled(fwd()))
        << "the liveness veto swallowed the administrative axis as well; a declared link failure "
           "is not an out-of-service order";
    EXPECT_FALSE(edgeIsUp(fwd())) << "and it must still be down";
}

/**
 * 🔴 The derived half must NOT be sticky. reconcileDerivedLiveness takes an edge down when a switch
 * at either end has been unusable for kMissesBeforeIsolating polls, and that state is supposed to
 * end by itself when the switch comes back. A veto keyed on "is this edge down for any reason"
 * rather than on the declaration would make every switch outage permanent -- the twin would never
 * report a recovered fabric again.
 */
TEST_F(DeclaredLinkFailureTest, ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack)
{
    const auto s5 = m_monitor->findSwitchByDpid(kLinkS5);
    ASSERT_TRUE(s5.has_value());

    m_monitor->setVertexDown(*s5);
    for (unsigned i = 0; i < LinkTestableMonitor::missesBeforeIsolating(); ++i)
    {
        m_monitor->reconcile();
    }
    ASSERT_FALSE(edgeIsUp(fwd())) << "pre-condition: the derivation must have isolated s5's links";
    ASSERT_EQ(edgeDownReason(fwd()), "switch-unreachable")
        << "pre-condition: this edge must be down by DERIVATION, not by declaration";

    // The switch comes back, and the control plane lists its links again.
    m_monitor->setVertexUp(*s5);
    m_monitor->reconcile();
    m_monitor->pollLinks(bothDirections());

    EXPECT_TRUE(edgeIsUp(fwd()))
        << "an edge the derivation took down never came back; the veto is reading something other "
           "than the declaration and every switch outage is now permanent";
    EXPECT_EQ(edgeDownReason(fwd()), "none");
}

/**
 * The seam that makes the veto possible, pointed the other way: the OBSERVATION writers must not
 * be able to set or clear a declaration. setEdgeDown from the push path is the defect (it is
 * indistinguishable from the poll's own opinion), and setEdgeUp from the liveness side must not
 * spend a declaration nobody withdrew.
 */
TEST_F(DeclaredLinkFailureTest, ObservationWritersNeitherSetNorClearTheDeclaration)
{
    m_monitor->setEdgeDown(fwd());
    EXPECT_FALSE(m_monitor->getEdgeDeclaredDown(fwd()))
        << "an observation created a declaration; the poll would then decline an edge no operator "
           "ever declared";

    m_monitor->setEdgeDownByDeclaration(fwd());
    m_monitor->setEdgeUp(fwd());
    EXPECT_TRUE(m_monitor->getEdgeDeclaredDown(fwd()))
        << "an observation withdrew a standing declaration; only /ndt/link_recovery_detected may";
}

/**
 * Both reasons can hold at once -- a declared link whose switch then dies -- and a reader gets one
 * string. It must be the declaration: `switch-unreachable` clears itself when the switch returns,
 * `declared` does not clear until somebody withdraws it, so publishing the self-healing one hides
 * the standing one behind a reason that is about to disappear.
 */
TEST_F(DeclaredLinkFailureTest, ADeclaredEdgeBehindADeadSwitchStillReadsDeclared)
{
    const auto s5 = m_monitor->findSwitchByDpid(kLinkS5);
    ASSERT_TRUE(s5.has_value());

    m_monitor->setEdgeDownByDeclaration(fwd());
    m_monitor->setVertexDown(*s5);
    for (unsigned i = 0; i < LinkTestableMonitor::missesBeforeIsolating(); ++i)
    {
        m_monitor->reconcile();
    }

    EXPECT_EQ(edgeDownReason(fwd()), "declared")
        << "the derivation's reason masked the standing declaration; a sweep for forgotten "
           "injections would miss this edge exactly while it is hardest to notice";

    // And the declaration outlives the switch outage it was masked by.
    m_monitor->setVertexUp(*s5);
    m_monitor->reconcile();
    m_monitor->pollLinks(bothDirections());
    EXPECT_FALSE(edgeIsUp(fwd()))
        << "the declaration was spent by a switch outage; a state field the derivation rewrites "
           "every poll cannot hold an intent";
    EXPECT_EQ(edgeDownReason(fwd()), "declared");
}

// =================================================================================================
// doc/KNOWN-ISSUES.md B-6, SECOND ROUND (W8b): a withdrawal has to pair with a reported break.
//
// [Co-developed with claude code -- Adam]
//
// WHAT THE REMAINING DEFECT WAS
//
// The fix above makes a declaration survive a topology poll. It did not make one survive the
// CONTROL PLANE RESTARTING, and that turned out to be a door of the same size. Measured live on
// 2026-09-07 00:08 (arm lw8b, OVS 4 hosts, branch fix/w8-declared-link-failure-sticky @ 017c060f,
// kernel 37d641fa9fd6fc14; console log scratch/overnight-2026-09-05/logs/live-round2-console.log):
//
//   00:08:44  declare s1:1 -> s5:1 down    -> is_up=False down_reason=declared
//   00:08:47  Ryu killed by pid            -> still is_up=False down_reason=declared
//   00:08:54  Ryu restarted, same argv     -> ryu.log "Link added: ..." for every link
//   00:08:53+ kernel.log                   -> one POST /ndt/link_recovery_detected per link
//   00:09:04  t+10 s .. t+90 s             -> is_up=True down_reason=none, 9 of 9 samples
//
// Ryu's topology module raises EventLinkAdd when LLDP FIRST discovers a link, so a restart looks
// exactly like a fabric-wide recovery, and intelligent_router.py's on_link_add notifies the twin
// from there. handleLinkRecovery then called clearEdgeDeclaredDown unconditionally.
//
// Adam's ruling, 2026-09-07 00:1x, option (b): a recovery report may only withdraw a declaration
// it PAIRS with -- one that /ndt/link_failure_detected reported broken. A bare rediscovery is not
// a repair.
//
// WHAT THESE ASSERT -- 🔴 BOTH DIRECTIONS again, because the failure mode of over-fixing this is
// worse than the defect:
//
//   1. a declaration nothing reported broken survives a recovery report, and the edge stays down;
//   2. a declaration that WAS reported broken is still withdrawn by its own recovery, one report
//      per withdrawal -- and a recovery for an edge nobody declared down still raises it. Lose
//      that and /ndt/link_recovery_detected stops working at all, which is a link that never
//      comes back rather than one that comes back too early.
// =================================================================================================

/**
 * 🔴 THE FINDING. An injected failure (declared, never reported broken by anyone) meets the
 * fabric-wide recovery burst a Ryu restart produces. It must not be withdrawn -- and this is the
 * dangerous half, because /ndt/inject_link_failure leaves a `tc netem loss 100%` on both
 * interfaces: withdrawing the declaration publishes a link that is up and does not carry packets.
 */
TEST_F(DeclaredLinkFailureTest, ARediscoveryDoesNotWithdrawADeclarationNothingReportedBroken)
{
    m_monitor->setEdgeDownByDeclaration(fwd());
    ASSERT_TRUE(m_monitor->getEdgeDeclaredDown(fwd()));
    ASSERT_FALSE(m_monitor->getEdgeFailureReported(fwd()))
        << "an injection recorded a control-plane failure report; there was nothing to report";

    // What Ryu's on_link_add produces for this link the moment LLDP rediscovers it.
    EXPECT_EQ(m_monitor->applyReportedLinkRecovery(fwd()), LinkRecoveryOutcome::Retained);

    EXPECT_TRUE(m_monitor->getEdgeDeclaredDown(fwd()))
        << "a bare rediscovery withdrew a declaration nothing ever reported broken; a control "
           "plane restart therefore ends every standing injection in the fabric, and for an "
           "injection made through /ndt/inject_link_failure the netem stays attached (B-6, W8b)";
    EXPECT_FALSE(edgeIsUp(fwd()))
        << "the edge was marked up while its declaration still stands, which publishes "
           "is_up: true with down_reason: declared";
    EXPECT_EQ(edgeDownReason(fwd()), "declared");

    // ... and the poll that follows still declines it, which is what makes the survival permanent
    // rather than one-poll-long.
    m_monitor->pollLinks(bothDirections());
    EXPECT_FALSE(edgeIsUp(fwd()));
    EXPECT_EQ(edgeDownReason(fwd()), "declared");
}

/**
 * Direction 2. The pairing must still work: a failure the control plane REPORTED is withdrawn by
 * the recovery report that answers it. Losing this makes /ndt/link_recovery_detected useless and
 * every real link outage permanent.
 */
TEST_F(DeclaredLinkFailureTest, AReportedFailureIsWithdrawnByItsMatchingRecovery)
{
    m_monitor->setEdgeDownByReportedFailure(fwd());
    ASSERT_TRUE(m_monitor->getEdgeDeclaredDown(fwd()));
    ASSERT_TRUE(m_monitor->getEdgeFailureReported(fwd()))
        << "the notification path did not record that the break was reported, so nothing can "
           "ever pair with it and the declaration is unwithdrawable";
    ASSERT_FALSE(edgeIsUp(fwd()));

    EXPECT_EQ(m_monitor->applyReportedLinkRecovery(fwd()), LinkRecoveryOutcome::Applied);
    EXPECT_FALSE(m_monitor->getEdgeDeclaredDown(fwd()))
        << "a recovery that pairs with a reported failure did not withdraw the declaration";
    EXPECT_TRUE(edgeIsUp(fwd())) << "the paired recovery did not bring the link back";
    EXPECT_EQ(edgeDownReason(fwd()), "none");

    // And a later poll may raise it, which is what says the declaration was spent and not merely
    // overwritten.
    m_monitor->pollLinks(bothDirections());
    EXPECT_TRUE(edgeIsUp(fwd()));
}

/**
 * ONE report, ONE withdrawal. The report is spent by the recovery that pairs with it, so a second
 * recovery report -- the next Ryu restart -- has nothing left to pair with and cannot reach a
 * declaration made after it.
 */
TEST_F(DeclaredLinkFailureTest, ARecoveryReportIsSpentAndDoesNotWithdrawTheNextDeclaration)
{
    m_monitor->setEdgeDownByReportedFailure(fwd());
    ASSERT_EQ(m_monitor->applyReportedLinkRecovery(fwd()), LinkRecoveryOutcome::Applied);
    ASSERT_FALSE(m_monitor->getEdgeFailureReported(fwd()));

    // A fresh injection, then the next fabric-wide rediscovery.
    m_monitor->setEdgeDownByDeclaration(fwd());
    EXPECT_EQ(m_monitor->applyReportedLinkRecovery(fwd()), LinkRecoveryOutcome::Retained)
        << "a failure report was spent twice: one report has to buy exactly one withdrawal, or a "
           "single real outage licenses every later rediscovery to end an injection";
    EXPECT_TRUE(m_monitor->getEdgeDeclaredDown(fwd()));
    EXPECT_FALSE(edgeIsUp(fwd()));
}

/**
 * Direction 2, the blunt over-correction: a recovery report for an edge NOBODY declared down must
 * still mark it up. Ryu POSTs one of these per link on every restart, and they are the only thing
 * besides the 30 s poll that raises an edge between polls -- an implementation that refuses them
 * all satisfies every assertion above and leaves the graph dark.
 */
TEST_F(DeclaredLinkFailureTest, ARecoveryStillRaisesAnEdgeNobodyDeclaredDown)
{
    m_monitor->setEdgeDown(fwd()); // an observation, not a declaration
    ASSERT_FALSE(edgeIsUp(fwd()));
    ASSERT_FALSE(m_monitor->getEdgeDeclaredDown(fwd()));

    EXPECT_EQ(m_monitor->applyReportedLinkRecovery(fwd()), LinkRecoveryOutcome::Applied);
    EXPECT_TRUE(edgeIsUp(fwd()))
        << "a recovery report stopped raising an edge that carried no declaration at all; the "
           "pairing rule swallowed the endpoint's ordinary job";
    EXPECT_EQ(edgeDownReason(fwd()), "none");
}

/**
 * The operator's own withdrawal answers to nobody: /ndt/inject_link_recovery ends an injection
 * whether or not the control plane ever agreed a link was broken. It is the endpoint the refused
 * recovery above points the caller at, so if it stopped working a retained declaration would have
 * no way out at all.
 */
TEST_F(DeclaredLinkFailureTest, TheInjectionWithdrawalNeedsNoReportToPairWith)
{
    m_monitor->setEdgeDownByDeclaration(fwd());
    ASSERT_TRUE(m_monitor->getEdgeDeclaredDown(fwd()));

    m_monitor->clearEdgeDeclaredDown(fwd());
    EXPECT_FALSE(m_monitor->getEdgeDeclaredDown(fwd()))
        << "the unconditional withdrawal stopped being unconditional; an injected failure that "
           "nothing reported broken would then be unwithdrawable";

    m_monitor->pollLinks(bothDirections());
    EXPECT_TRUE(edgeIsUp(fwd()));
}

/**
 * The withdrawal spends the report as well. Otherwise `inject_link_failure` on an edge Ryu had
 * once reported broken, followed by `inject_link_recovery`, would leave a report behind for the
 * NEXT rediscovery to spend on the next injection.
 */
TEST_F(DeclaredLinkFailureTest, TheInjectionWithdrawalAlsoSpendsAStandingReport)
{
    m_monitor->setEdgeDownByReportedFailure(fwd());
    m_monitor->clearEdgeDeclaredDown(fwd());
    EXPECT_FALSE(m_monitor->getEdgeFailureReported(fwd()))
        << "a failure report outlived the episode it belonged to";

    m_monitor->setEdgeDownByDeclaration(fwd());
    EXPECT_EQ(m_monitor->applyReportedLinkRecovery(fwd()), LinkRecoveryOutcome::Retained);
}

/**
 * The seam again, for the second flag: discovery and the derived-liveness pass must not be able to
 * manufacture a failure report. If they could, every edge the twin took down by itself would license
 * the next rediscovery to withdraw a declaration.
 */
TEST_F(DeclaredLinkFailureTest, ObservationWritersNeitherSetNorClearTheFailureReport)
{
    m_monitor->setEdgeDown(fwd());
    EXPECT_FALSE(m_monitor->getEdgeFailureReported(fwd()))
        << "an observation manufactured a control-plane failure report";

    m_monitor->setEdgeDownByReportedFailure(fwd());
    m_monitor->setEdgeUp(fwd());
    EXPECT_TRUE(m_monitor->getEdgeFailureReported(fwd()))
        << "an observation spent a failure report; only a recovery report or "
           "/ndt/inject_link_recovery may";

    m_monitor->pollLinks(bothDirections());
    EXPECT_TRUE(m_monitor->getEdgeFailureReported(fwd()))
        << "a topology poll spent a failure report";
}

/**
 * Direction 2 for the notification path: recording the report must not cost the stickiness the
 * first half of B-6 bought. A failure reported by the control plane is still declared, and a poll
 * still declines it.
 */
TEST_F(DeclaredLinkFailureTest, AReportedFailureStillSurvivesATopologyPoll)
{
    m_monitor->setEdgeDownByReportedFailure(fwd());
    m_monitor->setEdgeDownByReportedFailure(rev());
    ASSERT_FALSE(edgeIsUp(fwd()));

    m_monitor->pollLinks(bothDirections());

    EXPECT_FALSE(edgeIsUp(fwd()))
        << "recording the report cost the declaration its stickiness -- B-6's first half undone "
           "by its second";
    EXPECT_FALSE(edgeIsUp(rev()));
    EXPECT_EQ(edgeDownReason(fwd()), "declared");
}

// =================================================================================================
// B-13, third half: the poll's advice has to name the endpoint that can actually clear THIS
//                   declaration
//
// [Co-developed with claude code -- Adam]
//
// 🔴 THE FINDING (ROLE-1, 2026-09-11, read from a live kernel.log). A successor who does not
// restart the kernel sees exactly one sentence about a standing declaration, and it is this poll's:
//
//     TopologyAndFlowMonitor.cpp:2563 updateLinks] the control plane still lists link (dpid
//     0000000000000005 port 00000001), but a link failure was declared for it, so this poll is not
//     marking it up. … POST /ndt/link_recovery_detected to clear this
//
// For a declaration that came from /ndt/inject_link_failure that advice is WRONG since W8b:
// /ndt/link_recovery_detected pairs a recovery report with a reported break, finds none, and
// DECLINES -- it logs "link recovery declined … the declaration was retained". The sentence that
// names the endpoint which does work (/ndt/inject_link_recovery) is E-20's, and E-20's is printed
// at ONE call site, src/main.cpp:398, at kernel startup. So the successor is told to use the
// endpoint that will refuse him, and never shown the one that will not.
//
// One state, two sentences, two endpoints. The fix is to make this sentence -- the one that is
// printed every poll and therefore the one that is read -- name the right endpoint for the
// declaration actually standing, which the poll can tell apart because `failureReported` is right
// there in the edge it is refusing to raise.
//
// The two cases below are a discriminating pair on purpose: each asserts the endpoint its own
// state needs AND (for the reported one) the absence of the other. One case alone would pass on a
// sentence that listed both endpoints and left the reader to guess.
// =================================================================================================

#include <spdlog/sinks/ringbuffer_sink.h>

namespace
{

/**
 * @brief Captures every record the global logger emits while it is alive, at trace level.
 *
 * Same helper as tests/test_NetemLinkFault.cpp, tests/test_HttpSessionRouting.cpp and
 * tests/test_TopologyPollRound.cpp; duplicated rather than shared for the reason written there.
 * This file installs `spdlog::level::off` in SetUpTestSuite, so without something like this the
 * poll's WARN goes nowhere and a case about its wording could not exist.
 */
class PollLogCapture
{
  public:
    PollLogCapture()
        : m_logger(Logger::instance()),
          m_savedLevel(m_logger->level()),
          m_sink(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(256))
    {
        m_logger->sinks().push_back(m_sink);
        m_logger->set_level(spdlog::level::trace);
    }

    ~PollLogCapture()
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

    PollLogCapture(const PollLogCapture&) = delete;
    PollLogCapture& operator=(const PollLogCapture&) = delete;

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

} // namespace

/**
 * 🔴 THE FINDING. Nothing reported this link broken -- it was injected -- so the endpoint the poll
 * used to name would decline. The successor has to be told the other one.
 */
TEST_F(DeclaredLinkFailureTest, ThePollPointsAnInjectedDeclarationAtTheInjectionEndpoint)
{
    m_monitor->setEdgeDownByDeclaration(fwd());
    m_monitor->setEdgeDownByDeclaration(rev());

    std::string logged;
    {
        PollLogCapture log;
        m_monitor->pollLinks(bothDirections());
        logged = log.text();
    }

    ASSERT_NE(logged.find("not marking it up"), std::string::npos)
        << "the poll did not print the declined-resurrection line at all, so this case is not "
           "reading what it thinks it is reading:\n"
        << logged;
    EXPECT_NE(logged.find("/ndt/inject_link_recovery"), std::string::npos)
        << "the only sentence a successor who did not restart the kernel ever sees points at "
           "/ndt/link_recovery_detected, which since W8b DECLINES a declaration nothing reported "
           "broken. He is told to use the endpoint that will refuse him (B-13, measured "
           "2026-09-11). Log was:\n"
        << logged;
}

/**
 * The other side of the pair, and the behaviour that must not change: a break the CONTROL PLANE
 * reported is cleared by the control plane's own recovery report, and that is the endpoint to
 * name. A fix that pointed everything at /ndt/inject_link_recovery would be just as wrong, and
 * every assertion in the case above would still pass.
 */
TEST_F(DeclaredLinkFailureTest, ThePollStillPointsAReportedFailureAtTheNotificationEndpoint)
{
    m_monitor->setEdgeDownByReportedFailure(fwd());
    m_monitor->setEdgeDownByReportedFailure(rev());

    std::string logged;
    {
        PollLogCapture log;
        m_monitor->pollLinks(bothDirections());
        logged = log.text();
    }

    ASSERT_NE(logged.find("not marking it up"), std::string::npos) << logged;
    EXPECT_NE(logged.find("/ndt/link_recovery_detected"), std::string::npos)
        << "a failure the control plane reported is withdrawn by its own recovery report, and the "
           "poll stopped saying so:\n"
        << logged;
    EXPECT_EQ(logged.find("/ndt/inject_link_recovery"), std::string::npos)
        << "the poll sent an operator to the injection withdrawal for a break Ryu reported. That "
           "endpoint would work, and it would also spend a report the control plane is entitled "
           "to pair with -- and the advice would be wrong on the one axis this fix is about:\n"
        << logged;
}
