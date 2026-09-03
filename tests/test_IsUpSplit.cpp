/**
 * @file test_IsUpSplit.cpp
 * @brief Q12: `is_up` carried two questions at once. It now answers one, and the other has its
 *        own name.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT THE DEFECT WAS
 *
 * One boolean on the wire meant both "nobody has commanded this off" and "the twin can reach
 * it", and the two have different writers, different lifetimes and different truth conditions.
 * The consequences were measured, not argued:
 *
 *   - `/ndt/get_switches_power_state` derived its ON/OFF answer from that boolean, so TWO
 *     EQUALLY DEAD SWITCHES REPORTED DIFFERENT POWER STATES ONLY BY ACCIDENT OF WHICH WRITER
 *     GOT THERE FIRST: the one the twin had commanded off read OFF, and the one that had
 *     crashed read ON, because nothing had told the graph otherwise yet.
 *   - the contract suite's A-8 three-state check read the same bit on both sides of its own
 *     comparison ("is this switch down" vs "is it down because we powered it off"), so
 *     `unexplained_down` was structurally empty and the check could not fire, ever.
 *   - FINDINGS #46's fix separated the two INTERNALLY (`adminPoweredOff`) and deliberately left
 *     the wire alone, because splitting it is a design decision. Adam ruled on 2026-09-03:
 *     option (a), `admin_state` + `reachable`, with `is_up` kept as a deprecated alias of
 *     `reachable` so external readers keep working.
 *
 * WHAT THESE ASSERT
 *
 *  1. the emitted vertex carries all three keys, and `is_up` is exactly `reachable` -- in BOTH
 *     directions, because an alias that is only checked when it is true is not an alias;
 *  2. the four combinations of (commanded, reachable) are all four distinguishable, and in
 *     particular the two that used to be indistinguishable: commanded-off-and-dead versus
 *     crashed-while-commanded-on;
 *  3. from_json accepts an OLD payload that carries only `is_up`, because a payload written by
 *     a kernel that predates this change must still load;
 *  4. `/ndt/get_switches_power_state` reports both fields per switch, which is the endpoint the
 *     whole finding is about;
 *  5. FINDINGS #80: the post-power-off distrust window closes on EVIDENCE, not on a clock. The
 *     graph's `reachable` is believable again when a probe taken AFTER the kill says the switch
 *     is serving -- not fifteen seconds after the kill regardless of what anybody observed.
 *
 * WHAT IS DELIBERATELY NOT HERE
 *
 * #81 (`/ndt/inform_switch_entered` must not clear the commanded power-off) is in
 * tests/test_HttpSessionRouting.cpp, because the assertion is about what the HTTP handler does
 * and that file already owns the peer that can drive one.
 */

#include <chrono>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "ndt_core/power_management/P4PowerStrategy.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Records commands instead of running them, and drives the distrust bookkeeping's clock. Same
/// shape as the fakes in test_P4PowerStrategy.cpp and test_PollDoesNotResurrect.cpp.
class FakeP4 : public P4PowerStrategy
{
  public:
    std::vector<std::string> commands;
    std::string failSubstring;

    /// Starts at the steady_clock epoch, not at the real now(): a test that forgets to advance
    /// it cannot then pass by accident on however long the suite happened to take.
    std::chrono::steady_clock::time_point fakeNow{};
    void advance(std::chrono::seconds by) { fakeNow += by; }
    std::chrono::steady_clock::time_point at(std::chrono::seconds offset) const
    {
        return fakeNow + offset;
    }

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

/// Two switches and a monitor over them. No threads: start() is never called, so nothing in
/// this file depends on a proxy, a fabric or a clock that ticks on its own.
struct Fixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    std::shared_ptr<TopologyAndFlowMonitor> monitor;
    Graph::vertex_descriptor commanded{};
    Graph::vertex_descriptor crashed{};

    Fixture()
    {
        commanded = addSwitch(1, "s1", "192.168.123.11");
        crashed = addSwitch(2, "s2", "192.168.123.12");
        monitor = std::make_shared<TopologyAndFlowMonitor>(graph, mutex, bus, utils::MININET);
    }

    Graph::vertex_descriptor addSwitch(uint64_t dpid, const std::string& name,
                                       const std::string& ip)
    {
        const Graph::vertex_descriptor v = boost::add_vertex(*graph);
        (*graph)[v].vertexType = VertexType::SWITCH;
        (*graph)[v].dpid = dpid;
        (*graph)[v].deviceName = name;
        (*graph)[v].bridgeNameForMininet = name;
        (*graph)[v].ip = {utils::ipStringToUint32(ip)};
        (*graph)[v].isUp = true;
        (*graph)[v].isEnabled = true;
        return v;
    }

    nlohmann::json emit(Graph::vertex_descriptor v) const
    {
        std::shared_lock lock(*mutex);
        return (*graph)[v];
    }
};

/// Re-exports the 1 Hz worker's two policy helpers and hands it a strategy whose shell calls are
/// recorded rather than run.
///
/// [Co-developed with claude code -- Adam] -- FINDINGS #80.
/// Same pattern as PowerProbe in test_SyntheticPower.cpp and LivenessProbe in
/// test_OvsLiveness.cpp: the helpers are protected so a derived class in a test can drive the
/// real function. The strategy override is what makes the DECLINE path reachable at all -- a
/// distrust window opens only on a confirmed stop, and confirming one means running the real
/// root helper against a real bmv2.
class TestableManager : public DeviceConfigurationAndPowerManager
{
  public:
    TestableManager(std::shared_ptr<TopologyAndFlowMonitor> monitor, FakeP4* fake)
        : DeviceConfigurationAndPowerManager(std::move(monitor), utils::MININET, "127.0.0.1",
                                             nullptr),
          m_fake(fake)
    {
    }

    using DeviceConfigurationAndPowerManager::acceptP4LivenessUp;
    using DeviceConfigurationAndPowerManager::p4ProbeAgeSeconds;
    using DeviceConfigurationAndPowerManager::p4VerdictFor;
    using DeviceConfigurationAndPowerManager::OvsLiveness;

  protected:
    P4PowerStrategy* p4Strategy() override { return m_fake; }

  private:
    FakeP4* m_fake;
};

/// The proxy's `/p4/switch_state` shape, cut down to the two fields the policy reads.
nlohmann::json switchState(uint64_t dpid, bool probeOk, std::optional<double> ageSeconds)
{
    nlohmann::json entry = {{"probe_ok", probeOk}};
    entry["probe_age_s"] = ageSeconds.has_value() ? nlohmann::json(*ageSeconds) : nlohmann::json();
    return {{"switches", {{std::to_string(dpid), entry}}}};
}

class IsUpSplitTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

// --- 1. the wire shape ---------------------------------------------------------------------

/**
 * The decision, as a shape. Three keys where there was one, and the old name still present --
 * Adam's ruling keeps `is_up` alive as an alias so the four external readers (Energy-Saving-App,
 * Network-Traffic-Visualizer, Web-GUI, Traffic-Engineering-App) keep working unchanged. The
 * Energy-Saving-App's own from_json uses `j.at("is_up")`, which THROWS on a missing key, so this
 * assertion is the one standing between that app and a hard parse failure.
 */
TEST_F(IsUpSplitTest, AVertexCarriesAdminStateReachableAndTheIsUpAlias)
{
    Fixture fix;

    const nlohmann::json j = fix.emit(fix.commanded);

    EXPECT_TRUE(j.contains("admin_state")) << "the commanded half has no name on the wire";
    EXPECT_TRUE(j.contains("reachable")) << "the observed half has no name on the wire";
    EXPECT_TRUE(j.contains("is_up"))
        << "is_up is what four consumers read and one of them uses j.at(); removing it is a "
           "parse failure in another repository, not a deprecation";
}

/**
 * An alias checked in one direction is not an alias. Both values, because a `to_json` that
 * emitted a constant `true` for `is_up` would satisfy a one-sided check.
 */
TEST_F(IsUpSplitTest, TheIsUpAliasEqualsReachableInBothDirections)
{
    Fixture fix;

    // .value(), not operator[]: a missing key on a const json is undefined behaviour, and a
    // case that aborts the process takes the rest of the binary's reporting with it.
    fix.monitor->setVertexUp(fix.crashed);
    const nlohmann::json up = fix.emit(fix.crashed);
    EXPECT_TRUE(up.value("reachable", false));
    EXPECT_EQ(up.value("is_up", false), up.value("reachable", true));

    fix.monitor->setVertexDown(fix.crashed);
    const nlohmann::json down = fix.emit(fix.crashed);
    EXPECT_FALSE(down.value("reachable", true));
    EXPECT_EQ(down.value("is_up", true), down.value("reachable", false));
}

/**
 * 🔴 THE FINDING ITSELF. Two switches, both unreachable, one commanded off and one not. Before
 * the split these were the same vertex shape and the same power-state answer; the entire point
 * of Q12 is that they are now different.
 */
TEST_F(IsUpSplitTest, ACommandedOffSwitchAndACrashedSwitchAreDistinguishableOnTheWire)
{
    Fixture fix;

    fix.monitor->setVertexPoweredOffByCommand(fix.commanded); // the twin killed this one
    fix.monitor->setVertexDown(fix.crashed);                  // this one just died

    const nlohmann::json off = fix.emit(fix.commanded);
    const nlohmann::json dead = fix.emit(fix.crashed);

    EXPECT_EQ(off.value("admin_state", ""), "off");
    EXPECT_FALSE(off.value("reachable", true));

    EXPECT_EQ(dead.value("admin_state", ""), "on")
        << "a switch nobody commanded off must not report admin_state off just because it died; "
           "that is the conflation Q12 rules on";
    EXPECT_FALSE(dead.value("reachable", true));

    EXPECT_NE(off.value("admin_state", "?"), dead.value("admin_state", "?"))
        << "the two dead switches are still indistinguishable, which is the whole finding";
}

/**
 * The fourth combination, and the one only the split can express: commanded off, but observed
 * reachable. Somebody restarted the switch out of band. Before the split the twin had one bit
 * and had to pick a lie; now it states the disagreement.
 */
TEST_F(IsUpSplitTest, ACommandedOffSwitchThatIsReachableAgainReportsBothHonestly)
{
    Fixture fix;

    fix.monitor->setVertexPoweredOffByCommand(fix.commanded);
    fix.monitor->setVertexUp(fix.commanded); // an observation: it is answering again

    const nlohmann::json j = fix.emit(fix.commanded);

    EXPECT_EQ(j.value("admin_state", ""), "off")
        << "an observation withdrew a command. FINDINGS #46: only a power-on may do that";
    EXPECT_TRUE(j.value("reachable", false))
        << "the twin observed the switch answering and refused to say so";
    EXPECT_TRUE(j.value("is_up", false)) << "the alias must track reachable, not admin_state";
}

// --- 2. reading it back --------------------------------------------------------------------

/**
 * A payload written before this change carries `is_up` and neither new key. It must still load,
 * because from_json is what reads a topology/graph document off disk or off another process,
 * and those documents outlive a release.
 */
TEST_F(IsUpSplitTest, FromJsonAcceptsAnOldPayloadThatCarriesOnlyIsUp)
{
    const nlohmann::json old = {{"vertex_type", 0},
                                {"mac", 0},
                                {"ip", nlohmann::json::array({1u})},
                                {"dpid", 1},
                                {"is_up", false},
                                {"is_enabled", true},
                                {"device_name", "s1"},
                                {"nickname", "s1"},
                                {"brand_name", "BMv2"},
                                {"device_layer", 2},
                                {"ecmp_groups", nlohmann::json::array()}};

    VertexProperties v;
    ASSERT_NO_THROW(v = old.get<VertexProperties>())
        << "a payload from a kernel that predates the split no longer parses";

    EXPECT_FALSE(v.isUp) << "the old is_up must land on the observation, which is what it meant";
    EXPECT_FALSE(v.adminPoweredOff)
        << "an old payload says nothing about commands, and 'nothing' is 'not commanded off' -- "
           "defaulting the other way would mark every switch in every archived graph as "
           "deliberately powered down";
}

/**
 * A new payload round-trips, and `reachable` is the field that decides -- not the alias. Pinned
 * with the two DISAGREEING, which is the only arrangement that can tell which one was read.
 */
TEST_F(IsUpSplitTest, FromJsonReadsReachableAndAdminStateWhenBothArePresent)
{
    nlohmann::json j = {{"vertex_type", 0},
                        {"mac", 0},
                        {"ip", nlohmann::json::array({1u})},
                        {"dpid", 1},
                        {"is_up", true}, // the stale alias, deliberately disagreeing
                        {"reachable", false},
                        {"admin_state", "off"},
                        {"is_enabled", true},
                        {"device_name", "s1"},
                        {"nickname", "s1"},
                        {"brand_name", "BMv2"},
                        {"device_layer", 2},
                        {"ecmp_groups", nlohmann::json::array()}};

    const auto v = j.get<VertexProperties>();

    EXPECT_FALSE(v.isUp) << "reachable is the field; is_up is the alias and must not win";
    EXPECT_TRUE(v.adminPoweredOff) << "admin_state=off did not restore the commanded state";
}

// --- 3. the endpoint the finding is about ---------------------------------------------------

/**
 * 🔴 `/ndt/get_switches_power_state` reported the COMMAND while claiming to report the STATE,
 * and derived even that from an observation. Measured consequence: a switch the twin had killed
 * and a switch that had crashed gave different answers for no reason a caller could see.
 *
 * The endpoint must now report both, per switch, so the caller can tell the two apart itself.
 */
TEST_F(IsUpSplitTest, PowerStateEndpointReportsAdminStateAndReachableForEverySwitch)
{
    Fixture fix;
    auto manager = std::make_shared<DeviceConfigurationAndPowerManager>(
        fix.monitor, utils::MININET, "127.0.0.1", nullptr);

    fix.monitor->setVertexPoweredOffByCommand(fix.commanded);
    fix.monitor->setVertexDown(fix.crashed);

    const nlohmann::json body = manager->getSwitchesPowerState("/ndt/get_switches_power_state");

    ASSERT_TRUE(body.contains("192.168.123.11")) << body.dump();
    ASSERT_TRUE(body.contains("192.168.123.12")) << body.dump();

    const nlohmann::json& off = body["192.168.123.11"];
    const nlohmann::json& dead = body["192.168.123.12"];

    ASSERT_TRUE(off.is_object()) << "the per-switch answer must carry two facts, not one: "
                                 << off.dump();
    EXPECT_EQ(off.value("admin_state", ""), "off");
    EXPECT_FALSE(off.value("reachable", true));

    EXPECT_EQ(dead.value("admin_state", ""), "on")
        << "the crashed switch is reported as commanded off; that is the defect this endpoint "
           "is named in";
    EXPECT_FALSE(dead.value("reachable", true));
}

/**
 * The single-switch form takes the same shape. A caller that has to parse two shapes depending
 * on a query parameter has not been given a contract.
 */
TEST_F(IsUpSplitTest, PowerStateEndpointForOneIpCarriesBothFieldsToo)
{
    Fixture fix;
    auto manager = std::make_shared<DeviceConfigurationAndPowerManager>(
        fix.monitor, utils::MININET, "127.0.0.1", nullptr);

    fix.monitor->setVertexPoweredOffByCommand(fix.commanded);

    const nlohmann::json body = manager->getSwitchesPowerState(
        "/ndt/get_switches_power_state?ip=192.168.123.11");

    ASSERT_EQ(body.size(), 1u) << body.dump();
    ASSERT_TRUE(body.contains("192.168.123.11")) << body.dump();
    EXPECT_EQ(body["192.168.123.11"].value("admin_state", ""), "off");
    EXPECT_FALSE(body["192.168.123.11"].value("reachable", true));
}

// --- 4. FINDINGS #80: distrust bounded by evidence, not by a clock --------------------------

/**
 * 🔴 THE #80 DEFECT. `kPostPowerOffDistrustWindow` was fifteen seconds, and fifteen seconds is
 * not a fact about a switch. Live measurement (FIX-POLL-RESURRECT §3.3.2, 18 of 18 trials): after
 * a kill the proxy's cached `probe_ok` still reads true for 0.3-1.5 s and the graph carries the
 * wrong `isUp` for 8-13 s. The window was sized to cover that -- but the thing it covers is an
 * OBSERVATION going stale, and an observation going stale is not something a timer can know.
 *
 * The window must therefore stay open until something is OBSERVED. Here nothing is: time passes,
 * and the graph is lifted by exactly the writer whose staleness caused the finding.
 *
 * The commanded flag is cleared by hand first, standing in for the one thing that really does
 * clear it without a power-on -- a topology reload rebuilding the graph. That is what leaves the
 * window as the only remaining guard, and therefore what this case is about.
 */
TEST_F(IsUpSplitTest, TheDistrustWindowDoesNotCloseOnTimeAlone)
{
    Fixture fix;
    FakeP4 p4;

    ASSERT_TRUE(p4.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);
    ASSERT_FALSE(fix.monitor->getVertexIsUp(fix.commanded));

    // The graph is rebuilt (a topology change), so the commanded flag is gone.
    fix.monitor->clearVertexAdminPowerOff(fix.commanded);
    // ... and the stale cache writes up, exactly as the 1 Hz worker does.
    fix.monitor->setVertexUp(fix.commanded);

    p4.advance(std::chrono::seconds(60)); // four windows' worth. Still no observation.
    p4.commands.clear();

    const OpResult r = p4.powerOn(fix.commanded, "s1", 1, fix.monitor.get());

    EXPECT_TRUE(r.ok) << r.message;
    EXPECT_TRUE(p4.ran("ndtwin-p4-power on s1"))
        << "the distrust window expired on a clock. Nothing observed this switch after it was "
           "killed, so the graph's reachable is still the pre-kill cache -- and a power-on that "
           "believes it returns 200 Success having started nothing (FINDINGS #36, measured 4 of "
           "4 past the old 15 s window)";
}

/**
 * The other direction, and the one that makes the change a narrowing rather than a refusal: a
 * probe taken AFTER the kill that says the switch is serving closes the window immediately --
 * two seconds, not fifteen. Evidence is allowed to arrive early.
 */
TEST_F(IsUpSplitTest, AProbeTakenAfterTheKillClosesTheWindow)
{
    Fixture fix;
    FakeP4 p4;

    ASSERT_TRUE(p4.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);
    fix.monitor->clearVertexAdminPowerOff(fix.commanded);

    // Somebody restarted it out of band; the 1 Hz worker's next probe round-trips.
    EXPECT_TRUE(p4.acceptLivenessUp("s1", p4.at(std::chrono::seconds(2))))
        << "a probe taken two seconds after the kill is evidence about the present and must be "
           "allowed to move the graph";
    fix.monitor->setVertexUp(fix.commanded);

    p4.advance(std::chrono::seconds(3)); // still well inside the old fifteen
    p4.commands.clear();

    const OpResult r = p4.powerOn(fix.commanded, "s1", 1, fix.monitor.get());

    EXPECT_TRUE(r.ok) << r.message;
    EXPECT_TRUE(p4.commands.empty())
        << "the window stayed shut against a probe that had actually seen the switch serving. "
           "That converts a correct no-op into a helper run against a live bmv2, which refuses "
           "to start a second instance -- a 500 naming the wrong step";
}

/**
 * 🔴 THE STALE READING, WHICH IS THE ONE THE 15 s WINDOW EXISTED TO HIDE. The proxy's cache
 * answers `probe_ok: true` from a probe taken BEFORE the kill. That is a reading of the past.
 * It must not close the window and it must not count as evidence -- otherwise "evidence-based"
 * is just "time-based" with an extra step, since a stale cache is exactly what arrives first.
 */
TEST_F(IsUpSplitTest, AProbeTakenBeforeTheKillIsNotEvidenceAndDoesNotCloseTheWindow)
{
    Fixture fix;
    FakeP4 p4;

    p4.advance(std::chrono::seconds(30)); // so "before the kill" is expressible
    ASSERT_TRUE(p4.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);
    fix.monitor->clearVertexAdminPowerOff(fix.commanded);

    // The cached probe: taken one second before the kill, delivered after it.
    EXPECT_FALSE(p4.acceptLivenessUp("s1", p4.at(std::chrono::seconds(-1))))
        << "a probe that predates the kill was accepted as evidence the switch is serving. It "
           "is the same cache that made is_up read true for 8-13 s after every kill in the live "
           "measurement";

    fix.monitor->setVertexUp(fix.commanded); // the write the caller must now decline to make
    p4.commands.clear();

    const OpResult r = p4.powerOn(fix.commanded, "s1", 1, fix.monitor.get());

    EXPECT_TRUE(r.ok) << r.message;
    EXPECT_TRUE(p4.ran("ndtwin-p4-power on s1"))
        << "a pre-kill probe closed the distrust window, so the power-on believed the graph and "
           "started nothing";
}

/**
 * An Up with no timestamp at all is not evidence either. The proxy always sends `probe_age_s`
 * alongside a non-null `probe_ok`, so an absent age means the two processes disagree about the
 * schema -- and p4LivenessFor's standing policy for a reading it cannot trust is to decline a
 * verdict, not to pick the optimistic one.
 */
TEST_F(IsUpSplitTest, AnUpWithNoProbeTimestampIsNotEvidence)
{
    Fixture fix;
    FakeP4 p4;

    ASSERT_TRUE(p4.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);

    EXPECT_FALSE(p4.acceptLivenessUp("s1", std::nullopt))
        << "an Up verdict whose probe carries no age closed the window; a reading that cannot be "
           "placed in time cannot be shown to postdate the kill";
}

/**
 * The switch nobody has killed is untouched by any of this. Every liveness Up for it is
 * evidence, because there is no command it could be stale with respect to -- and if this stopped
 * being true the 1 Hz worker would stop writing up for the entire fabric.
 */
TEST_F(IsUpSplitTest, AnUncommandedSwitchAcceptsEveryLivenessUp)
{
    FakeP4 p4;

    EXPECT_TRUE(p4.acceptLivenessUp("s2", p4.at(std::chrono::seconds(0))));
    EXPECT_TRUE(p4.acceptLivenessUp("s2", std::nullopt))
        << "an untimed Up was refused for a switch this strategy has never stopped. Nothing is "
           "being distrusted here, so there is nothing for the age to settle";
}

/**
 * Keyed by switch, like the record it reads. One switch's kill must not make another switch's
 * probe worthless -- the Energy-Saving-App powers switches off in groups.
 */
TEST_F(IsUpSplitTest, EvidenceIsPerSwitchNotFabricWide)
{
    Fixture fix;
    FakeP4 p4;

    ASSERT_TRUE(p4.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);

    EXPECT_TRUE(p4.acceptLivenessUp("s2", p4.at(std::chrono::seconds(-5))))
        << "s1's power-off invalidated s2's probe";
    EXPECT_FALSE(p4.acceptLivenessUp("s1", p4.at(std::chrono::seconds(-5))))
        << "s1's own pre-kill probe was accepted";
}

// --- 5. the 1 Hz worker's join: dating a probe, and refusing one from before the kill --------

/**
 * The age is read from the payload the proxy actually sends, and an unreadable one is nullopt
 * rather than zero. Zero would mean "taken just now", which is the confident wrong answer the
 * whole finding is about.
 */
TEST_F(IsUpSplitTest, TheProbeAgeIsReadFromThePayloadAndIsNulloptWhenItCannotBe)
{
    EXPECT_EQ(TestableManager::p4ProbeAgeSeconds(1, switchState(1, true, 1.25)), 1.25);
    EXPECT_FALSE(TestableManager::p4ProbeAgeSeconds(1, switchState(1, true, std::nullopt)))
        << "a null age was read as a number";
    EXPECT_FALSE(TestableManager::p4ProbeAgeSeconds(9, switchState(1, true, 1.0)))
        << "an age was invented for a dpid the proxy did not report";
    EXPECT_FALSE(TestableManager::p4ProbeAgeSeconds(1, std::nullopt))
        << "an age was invented for a payload that never arrived";

    nlohmann::json malformed = switchState(1, true, 1.0);
    malformed["switches"]["1"]["probe_age_s"] = "1.0"; // the schema disagreement branch
    EXPECT_FALSE(TestableManager::p4ProbeAgeSeconds(1, malformed))
        << "a string where a number belongs became a confident age; p4LivenessFor refuses to "
           "render a verdict on exactly this reading and so must this";
}

/**
 * 🔴 THE WIRING, and the line that decides whether any of the rest reaches the graph. A switch
 * the twin killed, and a probe reported as 30 s old -- which places it before the kill. The
 * worker must not write up.
 */
TEST_F(IsUpSplitTest, TheWorkerDeclinesAnUpWhoseProbePredatesTheKill)
{
    Fixture fix;
    FakeP4 fake;
    TestableManager manager(fix.monitor, &fake);

    // The fake's clock is the steady_clock epoch; the manager dates probes against the real
    // clock, which is far later. A 30 s old probe is therefore still after the epoch -- so the
    // fake is advanced to the real now first, and the kill is stamped there.
    fake.fakeNow = std::chrono::steady_clock::now();
    ASSERT_TRUE(fake.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);

    EXPECT_FALSE(manager.acceptP4LivenessUp("s1", 1, switchState(1, true, 30.0)))
        << "the worker accepted a probe taken thirty seconds ago for a switch killed just now. "
           "This is the 8-13 s of `is_up=true` measured after every kill on the live fabric";
}

/**
 * The other direction: a probe reported as fresh postdates the kill, so it is a real observation
 * and the worker must both write it and close the window. Without this the fix is "never trust
 * liveness again", which is a bigger outage than the defect.
 */
TEST_F(IsUpSplitTest, TheWorkerAcceptsAFreshUpAndItClosesTheWindow)
{
    Fixture fix;
    FakeP4 fake;
    TestableManager manager(fix.monitor, &fake);

    fake.fakeNow = std::chrono::steady_clock::now();
    ASSERT_TRUE(fake.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);

    EXPECT_TRUE(manager.acceptP4LivenessUp("s1", 1, switchState(1, true, 0.0)))
        << "a probe taken now was refused for a switch killed a moment ago";

    // The window is what the accepted probe must have closed, so read it through the guard that
    // consults it -- with the commanded flag cleared, since that flag would decide the branch on
    // its own and this case is not about it.
    fix.monitor->clearVertexAdminPowerOff(fix.commanded);
    fix.monitor->setVertexUp(fix.commanded);
    fake.commands.clear();

    EXPECT_TRUE(fake.powerOn(fix.commanded, "s1", 1, fix.monitor.get()).ok);
    EXPECT_TRUE(fake.commands.empty())
        << "the window was still open after a probe that had seen the switch serving; ran: "
        << (fake.commands.empty() ? std::string{} : fake.commands[0]);
}

/**
 * 🔴 THE VERDICT THE WORKER ACTS ON, which is the only thing the graph ever sees. The case above
 * proves the judgement; this one proves it is WIRED -- that a declined Up becomes Unknown, the
 * one verdict the worker does not write. The gate found this gap: while the check sat inline in
 * pingWorker's switch, no test could reach it and deleting it survived.
 */
TEST_F(IsUpSplitTest, AStaleUpBecomesUnknownSoTheWorkerWritesNothing)
{
    Fixture fix;
    FakeP4 fake;
    TestableManager manager(fix.monitor, &fake);

    fake.fakeNow = std::chrono::steady_clock::now();
    ASSERT_TRUE(fake.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);

    EXPECT_EQ(manager.p4VerdictFor("s1", 1, switchState(1, true, 30.0)),
              TestableManager::OvsLiveness::Unknown)
        << "a pre-kill probe still reaches the graph as Up. Unknown is the verdict the worker "
           "does not act on, and it is the only one that leaves the vertex alone";

    EXPECT_EQ(manager.p4VerdictFor("s1", 1, switchState(1, true, 0.0)),
              TestableManager::OvsLiveness::Up)
        << "a probe taken now was downgraded too; that is 'never believe liveness again'";
}

/**
 * Downgraded, not inverted. A stale Up must not become Down -- the twin would be asserting that
 * a switch is dead on the strength of a reading it has just declared unusable.
 */
TEST_F(IsUpSplitTest, ADownVerdictIsPassedThroughUntouched)
{
    Fixture fix;
    FakeP4 fake;
    TestableManager manager(fix.monitor, &fake);

    fake.fakeNow = std::chrono::steady_clock::now();
    ASSERT_TRUE(fake.powerOff(fix.commanded, "s1", fix.monitor.get()).ok);

    EXPECT_EQ(manager.p4VerdictFor("s1", 1, switchState(1, false, 0.5)),
              TestableManager::OvsLiveness::Down)
        << "the evidence check touched a verdict that was not Up; it exists to stop a stale "
           "reading LIFTING a switch, not to stop the twin noticing a dead one";
}

/**
 * The switch nobody killed: the worker must not start asking permission for the whole fabric.
 */
TEST_F(IsUpSplitTest, TheWorkerAcceptsEveryUpForASwitchItNeverStopped)
{
    Fixture fix;
    FakeP4 fake;
    TestableManager manager(fix.monitor, &fake);

    EXPECT_TRUE(manager.acceptP4LivenessUp("s2", 2, switchState(2, true, 99.0)))
        << "an old probe was refused for a switch with no standing power-off; nothing is being "
           "distrusted, so the age settles nothing";
}

} // namespace
