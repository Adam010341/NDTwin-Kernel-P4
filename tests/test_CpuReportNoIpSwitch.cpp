/**
 * FINDINGS #85: a SWITCH vertex carrying no management address killed the kernel.
 *
 * [Co-developed with claude code -- Adam]
 *
 * `DeviceConfigurationAndPowerManager::fetchCpuReportInternal` opened its loop body with
 *
 *     std::string ip_str = utils::ipToString(vp.ip.front());
 *
 * and `VertexProperties::ip` is a `std::vector<uint32_t>` that starts empty. `front()` on an empty
 * vector is undefined behaviour; in practice it faulted, on the status worker's thread, and an
 * unhandled SIGSEGV on any thread ends the process -- so one switch with no address took the whole
 * kernel down. gdb caught it doing exactly that (thread 4, fetchCpuReportInternal <-
 * statusUpdateWorker); the stack is in audit-raw under
 * doc/audit/2026-09-03_fix-kernel-stop-bounded/raw/logs/gdb_segfault_no_ip.log.
 *
 * THE REACHABILITY QUESTION, AND ITS ANSWER
 *
 * The finding suspected a live crash: that TopologyAndFlowMonitor::updateSwitches adds a switch
 * vertex for any dpid the control plane lists but the static topology file does not declare, and
 * that Ryu's `/v1.0/topology/switches` reply carries no IP -- which would make "the control plane
 * mentions an unknown dpid" a remote kill switch.
 *
 * It does not, and the first test below is the evidence. `updateSwitches` adds no vertex: for an
 * unknown dpid it logs one WARN and moves on. The second closure is at the other end --
 * `loadStaticTopologyFromFile` refuses a switch node with an empty "ip" array at load (2da6954f,
 * 2026-07-30), so the file cannot produce one either, and main.cpp exits on that refusal. Those
 * two are the only writers of `VertexProperties::ip` and the only production `add_vertex`.
 *
 * So this crash is NOT reachable in a running kernel today, and the finding is downgraded on that
 * evidence. It is still fixed here, for a reason the fix's own history makes concrete: the
 * invariant "every switch has an address" is enforced in a different subsystem, in a different
 * file, by a single `if` that did not exist five weeks ago -- and the penalty for it ever being
 * wrong again is not a bad reading, it is the process. The four reports now answer instead of
 * faulting. Belt, and the loader keeps its braces.
 *
 * WHAT THE TESTS PIN
 *
 *  1. updateSwitches invents no vertex for an unknown dpid   (green before and after: the
 *     reachability evidence, and a regression guard on it)
 *  2. a status round over an address-less switch does not kill the process, in MININET
 *     (SIGSEGV -> exit 0)
 *  3. the same round in TESTBED, which is a different code path and not a duplicate: in MININET
 *     the power report reads no address at all, so mode 2 cannot reach the power guard
 *  4. the switch keeps a key, at the documented sentinel, in all three IP-keyed reports
 *  5. the WARN is edge-triggered: once per episode, not once per round
 *  6. the power report -- keyed by dpid, so it needs no substitute key -- reports the sentinel in
 *     TESTBED mode, and STILL reports a real synthetic figure in MININET mode, where the value
 *     never depended on the address in the first place
 *
 * Tests 2 and 3 are death tests on purpose. The later assertions would also go red on the old
 * code, but only by taking the whole binary with them: a SEGFAULT produces no "[  FAILED  ]" line
 * and every later suite in test_routing_strategy silently never runs. Forking a child to contain
 * the crash is what turns "the run died" into a named red line.
 *
 * Test 3 exists because the mutation gate proved test 2 alone was not enough: on 2026-09-04 the
 * M2 mutant (TESTBED power path dereferences an empty ip) was scored SURVIVED, because the fault
 * landed in an in-process test and killed the binary with no verdict. Both death tests are
 * declared before every in-process test for that reason.
 */

#include <cstdlib>
#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>
#include <nlohmann/json.hpp>
#include <spdlog/sinks/ringbuffer_sink.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Same test seam as MetricProbe in test_SimulatedDeviceMetrics.cpp, plus the power report, which
/// moved into the protected section for this test: statusUpdateWorker runs all four in one round
/// and all four read an address, so "one status round" has to be able to call all four.
class ReportProbe : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::DeviceConfigurationAndPowerManager;
    using DeviceConfigurationAndPowerManager::fetchCpuReportInternal;
    using DeviceConfigurationAndPowerManager::fetchMemoryReportInternal;
    using DeviceConfigurationAndPowerManager::fetchPowerReportInternal;
    using DeviceConfigurationAndPowerManager::fetchTemperatureReportInternal;
    using DeviceConfigurationAndPowerManager::kHealthMetricUnavailable;
    using DeviceConfigurationAndPowerManager::reportKeyForSwitchWithoutIp;
};

/// Reaches updateSwitches, the ingest point for the control plane's `/v1.0/topology/switches`
/// reply. Same seam as TestableTopologyAndFlowMonitor in test_TopologyAndFlowMonitor.cpp.
class SwitchListingMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;
    using TopologyAndFlowMonitor::updateSwitches;
};

/**
 * @brief Captures every record the global logger emits while it is alive, at trace level.
 *
 * Same helper as tests/test_TopologyPollRound.cpp and tests/test_ApiKeyNotLogged.cpp; duplicated
 * rather than shared for the reason given there -- hoisting it would create a test-support header
 * several files then have to agree on.
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

    /// How many captured records contain @p token.
    std::size_t count(const std::string& token) const
    {
        const std::string all = text();
        std::size_t n = 0;
        for (std::size_t at = all.find(token); at != std::string::npos;
             at = all.find(token, at + token.size()))
        {
            ++n;
        }
        return n;
    }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    spdlog::level::level_enum m_savedLevel;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> m_sink;
};

/// The dpid of the one switch in these fixtures that carries no management address.
constexpr uint64_t kAddresslessDpid = 7;

class NoIpSwitchTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_mutex = std::make_shared<std::shared_mutex>();
        m_bus = std::make_shared<EventBus>();
    }

    /// Builds the monitor and the manager in @p mode. Called by each test rather than by SetUp so
    /// a test can populate the graph first, and so the mode is visible in the test body.
    void buildManager(utils::DeploymentMode mode)
    {
        m_monitor = std::make_shared<SwitchListingMonitor>(m_graph, m_mutex, m_bus, mode);
        // Nothing here starts a thread: the constructor only builds the two power strategies, and
        // start() is never called. That also keeps the death test below single-threaded, which is
        // what makes forking it safe.
        m_manager = std::make_unique<ReportProbe>(m_monitor, mode, "localhost", nullptr);
    }

    void addSwitch(const std::string& ip, uint64_t dpid)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].dpid = dpid;
        (*m_graph)[v].isUp = true;
        // push_back, not ip[0] = ...: VertexProperties::ip starts empty.
        (*m_graph)[v].ip.push_back(utils::ipStringToUint32(ip));
    }

    /// The vertex under test. Deliberately NO ip.push_back() -- that is the whole condition.
    void addSwitchWithNoIp(uint64_t dpid)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].dpid = dpid;
        (*m_graph)[v].isUp = true;
    }

    /// Gives @p dpid an address, so the next round sees it as recovered and the WARN re-arms.
    void giveTheSwitchAnAddress(uint64_t dpid, const std::string& ip)
    {
        for (auto v : boost::make_iterator_range(vertices(*m_graph)))
        {
            if ((*m_graph)[v].dpid == dpid)
            {
                (*m_graph)[v].ip.push_back(utils::ipStringToUint32(ip));
            }
        }
    }

    void takeTheAddressAway(uint64_t dpid)
    {
        for (auto v : boost::make_iterator_range(vertices(*m_graph)))
        {
            if ((*m_graph)[v].dpid == dpid)
            {
                (*m_graph)[v].ip.clear();
            }
        }
    }

    /// One round of statusUpdateWorker's four fetches, in the order that worker calls them, then
    /// a clean exit. Runs inside the death-test child: on the pre-fix code the first of the four
    /// to reach the address-less switch faults, and the child dies of SIGSEGV rather than
    /// reaching std::exit. A single call, no comma at macro level -- see the note in
    /// test_LoggerCliArgs.cpp about braced lists inside EXPECT_EXIT.
    void oneStatusRoundThenExitZero()
    {
        m_manager->fetchPowerReportInternal();
        m_manager->fetchCpuReportInternal();
        m_manager->fetchMemoryReportInternal();
        m_manager->fetchTemperatureReportInternal();
        std::exit(0);
    }

    std::size_t vertexCount() const { return boost::num_vertices(*m_graph); }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<SwitchListingMonitor> m_monitor;
    std::unique_ptr<ReportProbe> m_manager;
};

} // namespace

// ---------------------------------------------------------------------------------------------
// 1. Reachability. This is the test that decides whether #85 is a live crash or a latent one.
// ---------------------------------------------------------------------------------------------

TEST_F(NoIpSwitchTest, UpdateSwitchesInventsNoVertexForADpidTheTopologyDoesNotDeclare)
{
    buildManager(utils::MININET);
    addSwitch("10.0.0.1", 1);
    ASSERT_EQ(vertexCount(), 1u);

    LogCapture log;

    // The shape of Ryu's GET /v1.0/topology/switches reply: dpids in base 16, ports, and -- the
    // point of the whole finding -- no address anywhere in it. dpid 2 is not in this graph.
    m_monitor->updateSwitches(R"([{"dpid": "0000000000000001", "ports": []},
                                  {"dpid": "0000000000000002", "ports": []}])");

    EXPECT_EQ(vertexCount(), 1u)
        << "updateSwitches created a vertex for a dpid the static topology does not declare. That "
           "is the mechanism FINDINGS #85 suspected: such a vertex would carry no address (the "
           "reply has none to give it), and the status worker's reports would then fault on "
           "ip.front(). If this ever goes red, #85 is a live remote crash again and the fix in "
           "DeviceConfigurationAndPowerManager is the only thing standing in front of it.";

    EXPECT_NE(log.text().find("not found in static network topology file"), std::string::npos)
        << "the unknown dpid should still be reported, just not materialised: " << log.text();
}

// ---------------------------------------------------------------------------------------------
// 2. The crash itself.
// ---------------------------------------------------------------------------------------------

TEST_F(NoIpSwitchTest, AStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess)
{
    // Set rather than inherited. This flag is global and sticky, and test_LoggerCliArgs.cpp --
    // linked into the same binary -- sets it per death test, so whatever this suite got would
    // depend on execution order. "threadsafe" re-executes the binary for the child instead of
    // forking it, which is what the other suites here use and what keeps gtest from warning
    // about the threads test_KernelStopIsBounded leaves behind. The child re-runs this test body
    // from the top, so the graph below is rebuilt in it.
    GTEST_FLAG_SET(death_test_style, "threadsafe");

    buildManager(utils::MININET);
    addSwitch("10.0.0.1", 1);
    addSwitchWithNoIp(kAddresslessDpid);

    // Red on the pre-fix code as `died with signal 11 (SIGSEGV)`; green as a clean exit 0.
    EXPECT_EXIT(oneStatusRoundThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "a switch with no management address must not be able to end the process. The status "
           "worker runs these four in one round every 10 s, and an unhandled SIGSEGV on that "
           "thread ends the kernel, not just the round.";
}

// [Co-developed with claude code -- Adam]
// The second mode, and it is not redundant. The test above builds the manager in MININET, where
// fetchPowerReportInternal never reads an address at all -- the synthetic figure is a function of
// the dpid -- so the guard on the power path's TESTBED branch is not exercised by it. The
// mutation gate proved that the hard way on 2026-09-04: M2 (the TESTBED power site dereferences
// an empty ip again) was NOT caught by the test above. It faulted in
// TestbedPowerReportsTheSentinelForAnAddresslessSwitch instead, which is an ordinary in-process
// call, so the binary died with no verdict line and the gate scored it SURVIVED rather than
// letting a crash read as a clean red.
//
// Declared HERE, above every in-process TESTBED test, on purpose: gtest runs a suite in
// declaration order, so this fork has to happen before anything that would take the process down
// with it. Moving it below them puts the gate back where it was.
TEST_F(NoIpSwitchTest, ATestbedStatusRoundOverASwitchWithNoAddressDoesNotKillTheProcess)
{
    GTEST_FLAG_SET(death_test_style, "threadsafe");

    // TESTBED, and only the address-less switch in the graph. Nothing here shells out: the power
    // path's guard returns before the SSH/SNMP branch, and the other three answer the sentinel
    // before their snmpget. A switch WITH an address in this mode would run real commands, which
    // is why there is not one.
    buildManager(utils::TESTBED);
    addSwitchWithNoIp(kAddresslessDpid);

    EXPECT_EXIT(oneStatusRoundThenExitZero(), ::testing::ExitedWithCode(0), "")
        << "in TESTBED mode the power report is the FIRST of the four the status worker calls "
           "and the first to read the address, so this is the site that actually faults on a "
           "real testbed -- before the CPU report the gdb backtrace happened to name.";
}

// ---------------------------------------------------------------------------------------------
// 3. What it reports instead.
// ---------------------------------------------------------------------------------------------

TEST_F(NoIpSwitchTest, TheAddresslessSwitchKeepsAKeyAtTheDocumentedSentinel)
{
    buildManager(utils::MININET);
    addSwitch("10.0.0.1", 1);
    addSwitchWithNoIp(kAddresslessDpid);

    const std::string key = ReportProbe::reportKeyForSwitchWithoutIp(kAddresslessDpid);

    for (const nlohmann::json& report : {m_manager->fetchCpuReportInternal(),
                                        m_manager->fetchMemoryReportInternal(),
                                        m_manager->fetchTemperatureReportInternal()})
    {
        // Two switches, two keys. Dropping the address-less one is the 2026-08-18 bug again: a
        // switch missing from the body renders as 0% through the Web-GUI's `data[ip] || 0`, i.e.
        // as an idle switch rather than an unreadable one.
        EXPECT_EQ(report.size(), 2u) << report.dump();
        ASSERT_TRUE(report.contains(key)) << report.dump();
        EXPECT_EQ(report[key], ReportProbe::kHealthMetricUnavailable) << report.dump();

        // The key must not be mistakable for an address, and must not shadow a real switch's.
        EXPECT_EQ(key.find("dpid:"), 0u) << key;
        EXPECT_TRUE(report.contains("10.0.0.1")) << report.dump();
    }
}

TEST_F(NoIpSwitchTest, TheSentinelIsNotSomethingAReaderWouldTakeForAMeasurement)
{
    buildManager(utils::MININET);
    addSwitchWithNoIp(kAddresslessDpid);

    const std::string key = ReportProbe::reportKeyForSwitchWithoutIp(kAddresslessDpid);
    const nlohmann::json cpu = m_manager->fetchCpuReportInternal();

    ASSERT_TRUE(cpu.contains(key)) << cpu.dump();
    EXPECT_TRUE(cpu[key].is_number()) << cpu.dump();
    EXPECT_LT(cpu[key].get<double>(), 0.0)
        << "0 would read as an idle switch and any positive number as a load figure. The value "
           "has to be outside the range a reader could take for a percentage, which is what "
           "doc/2026-01-02_ndt_api.md's -1 (\"data is unavailable\") already is.";
}

// ---------------------------------------------------------------------------------------------
// 4. The WARN, and how often it fires.
// ---------------------------------------------------------------------------------------------

TEST_F(NoIpSwitchTest, TheMissingAddressWarnsOncePerEpisodeAndNamesTheDpid)
{
    buildManager(utils::MININET);
    addSwitchWithNoIp(kAddresslessDpid);

    LogCapture log;

    m_manager->fetchCpuReportInternal();
    ASSERT_EQ(log.count("carries no management address"), 1u)
        << "the first round must say so, naming the dpid: " << log.text();
    EXPECT_NE(log.text().find("dpid " + std::to_string(kAddresslessDpid)), std::string::npos)
        << "the WARN has to name which switch, or nobody can fix the topology file: "
        << log.text();

    // Three more rounds, and the other three reports too. statusUpdateWorker ticks every 10 s and
    // reads the whole graph each time; a per-round WARN is a line every 10 s for as long as the
    // topology is wrong. That is the shape that put 3596 sudo errors into one run.
    for (int round = 0; round < 3; ++round)
    {
        m_manager->fetchPowerReportInternal();
        m_manager->fetchCpuReportInternal();
        m_manager->fetchMemoryReportInternal();
        m_manager->fetchTemperatureReportInternal();
    }

    EXPECT_EQ(log.count("carries no management address"), 1u)
        << "still exactly one after 3 more rounds x 4 reports: " << log.text();
}

TEST_F(NoIpSwitchTest, ANewEpisodeWarnsAgain)
{
    buildManager(utils::MININET);
    addSwitchWithNoIp(kAddresslessDpid);

    LogCapture log;

    m_manager->fetchCpuReportInternal();
    ASSERT_EQ(log.count("carries no management address"), 1u) << log.text();

    // Recovered: the switch is seen with an address, which ends the episode.
    giveTheSwitchAnAddress(kAddresslessDpid, "10.0.0.7");
    m_manager->fetchCpuReportInternal();
    EXPECT_EQ(log.count("carries no management address"), 1u)
        << "a recovered switch must not warn: " << log.text();

    // And gone again. A second episode is a second thing worth knowing about, not a repeat.
    takeTheAddressAway(kAddresslessDpid);
    m_manager->fetchCpuReportInternal();
    EXPECT_EQ(log.count("carries no management address"), 2u)
        << "edge-triggered means silent within an episode, not silent for ever: " << log.text();
}

// ---------------------------------------------------------------------------------------------
// 5. The power report, which is keyed by dpid and so is a different question.
// ---------------------------------------------------------------------------------------------

TEST_F(NoIpSwitchTest, TestbedPowerReportsTheSentinelForAnAddresslessSwitch)
{
    // TESTBED, not MININET: this is the mode whose power branch SSHes and SNMPs to the address,
    // and so is the one with nothing to ask. The graph holds only the address-less switch, so
    // nothing here shells out to anything.
    buildManager(utils::TESTBED);
    addSwitchWithNoIp(kAddresslessDpid);

    const nlohmann::json report = m_manager->fetchPowerReportInternal();

    ASSERT_EQ(report.size(), 1u) << report.dump();
    EXPECT_EQ(report[0]["dpid"], kAddresslessDpid) << report.dump();
    EXPECT_EQ(report[0]["power_consumed"], ReportProbe::kHealthMetricUnavailable)
        << "0 is already this endpoint's answer for a switch that is powered OFF. An unreadable "
           "switch reported as 0 mW is the Energy-Saving App's cue to act: " << report.dump();
}

TEST_F(NoIpSwitchTest, MininetPowerStillReportsARealFigureForAnAddresslessSwitch)
{
    // The guard must not spread further than the harm. The MININET power figure is a function of
    // the dpid alone -- syntheticPowerMilliwattsFor's doc comment says so, and says this path
    // must not call ip.front() -- so a switch with no address has a perfectly real answer here
    // and must keep getting it. This is the widening test: over-guarding shows up as a sentinel.
    buildManager(utils::MININET);
    addSwitchWithNoIp(kAddresslessDpid);

    const nlohmann::json report = m_manager->fetchPowerReportInternal();

    ASSERT_EQ(report.size(), 1u) << report.dump();
    EXPECT_EQ(report[0]["dpid"], kAddresslessDpid) << report.dump();

    // 30 000 - 149 999 mW, the documented range of the deterministic mixer (API doc §6).
    const auto mW = report[0]["power_consumed"].get<std::int64_t>();
    EXPECT_GE(mW, 30000) << report.dump();
    EXPECT_LE(mW, 149999) << report.dump();
}
