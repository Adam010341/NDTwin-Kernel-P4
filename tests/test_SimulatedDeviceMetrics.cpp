/**
 * Tests for what MININET mode reports on the three device-health endpoints.
 *
 * [Co-developed with claude code -- Adam]
 *
 * F-1, doc/KNOWN-ISSUES.md:886. Mininet and bmv2 have no CPU register, no memory gauge and no
 * thermal sensor, so all three figures were made up:
 *
 *     fetchMemoryReportInternal    memory = 10 + hash(ip) % 50
 *     fetchCpuReportInternal       cpu    = 10 + hash(ip) % 50     <- byte-identical expression
 *     fetchTemperatureReportInternal
 *                                  temp   = 25 + hash(ip) % 25
 *     getSingleSwitchCpuReport     cpu    = 10 + hash(ip) % 50     <- the Intent Translator's copy
 *
 * Two consequences, and the second is the one that gets asked about on stage. First, CPU and
 * memory were the same expression on the same seed, so the two endpoints answered the same
 * bytes. Second, `% 50` draws from fifty buckets: over the ten switches of the shipped
 * topologies, two of them showing the identical percentage is the likely outcome rather than
 * bad luck, and the value never moves, because it is a function of the management IP and
 * nothing else. A switch pinned at 100% and an idle one read the same.
 *
 * The fix reports -1, which is what all three functions already return for a down switch and
 * for an SNMP failure, what doc/2026-01-02_ndt_api.md documents as "SNMP query failed or data
 * is unavailable", and what Web-GUI's DeviceInformation.tsx renders as "unavailable".
 *
 * The assertions below are deliberately written in two halves: the value IS the sentinel, and
 * the value is NOT anything a reader could mistake for a measurement. The second half is the
 * one that matters, because the tempting "fix" for a number that never changes is a number that
 * does -- and a fabricated figure that varies plausibly is strictly worse than this one, since
 * it survives the questions that catch this one.
 *
 * Scope: MININET only. The TESTBED branches shell out to snmpget and are not exercised here.
 */

#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Same test seam as PowerProbe in test_SyntheticPower.cpp and LivenessProbe in
/// test_OvsLiveness.cpp. The public accessors (getCpuUtilization etc.) read m_cached*, which
/// only statusUpdateWorker fills, so reaching the reports through them would mean starting the
/// background thread; the fetch*Internal functions are protected for exactly this.
class MetricProbe : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::DeviceConfigurationAndPowerManager;
    using DeviceConfigurationAndPowerManager::fetchCpuReportInternal;
    using DeviceConfigurationAndPowerManager::fetchMemoryReportInternal;
    using DeviceConfigurationAndPowerManager::fetchTemperatureReportInternal;
    using DeviceConfigurationAndPowerManager::kHealthMetricUnavailable;
};

/// A percentage or a temperature a reader would take for a real reading. -1 is outside it by
/// construction; so is any negative sentinel a future author might prefer.
bool
looksLikeAMeasurement(const nlohmann::json& value)
{
    return value.is_number() && value.get<double>() >= 0.0;
}

class SimulatedDeviceMetricsTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_mutex = std::make_shared<std::shared_mutex>();
        m_bus = std::make_shared<EventBus>();
        m_monitor =
            std::make_shared<TopologyAndFlowMonitor>(m_graph, m_mutex, m_bus, utils::MININET);

        addSwitch("10.0.0.1", 1);
        addSwitch("10.0.0.2", 2);
        addSwitch("10.0.0.3", 3);

        // MININET, not TESTBED: this is the mode under test. Nothing here starts a thread --
        // the constructor only builds the two power strategies, and start() is never called.
        m_manager = std::make_unique<MetricProbe>(m_monitor, utils::MININET, "localhost",
                                                  nullptr);
    }

    void addSwitch(const std::string& ip, uint64_t dpid, bool isUp = true)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].dpid = dpid;
        (*m_graph)[v].isUp = isUp;
        // push_back, not ip[0] = ...: VertexProperties::ip starts empty, so indexed assignment
        // is out of bounds. Same trap as test_IntentTaskOutcomes::addSwitch.
        (*m_graph)[v].ip.push_back(utils::ipStringToUint32(ip));
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::unique_ptr<MetricProbe> m_manager;
};

} // namespace

TEST_F(SimulatedDeviceMetricsTest, CpuReportsUnavailableForEverySwitch)
{
    const nlohmann::json report = m_manager->fetchCpuReportInternal();

    ASSERT_EQ(report.size(), 3u) << "every switch must still have a key: dropping one is how a "
                                   "powered-off switch used to render as 0% in the Web-GUI";
    for (const auto& [ip, value] : report.items())
    {
        EXPECT_EQ(value, MetricProbe::kHealthMetricUnavailable) << ip;
        EXPECT_FALSE(looksLikeAMeasurement(value))
            << ip << " reports " << value.dump()
            << ", which a reader would take for a CPU percentage. Mininet has no CPU register "
               "to read; measure with tools/test_workflow/cpu_probe.py instead.";
    }
}

TEST_F(SimulatedDeviceMetricsTest, MemoryReportsUnavailableForEverySwitch)
{
    const nlohmann::json report = m_manager->fetchMemoryReportInternal();

    ASSERT_EQ(report.size(), 3u);
    for (const auto& [ip, value] : report.items())
    {
        EXPECT_EQ(value, MetricProbe::kHealthMetricUnavailable) << ip;
        EXPECT_FALSE(looksLikeAMeasurement(value)) << ip << " reports " << value.dump();
    }
}

TEST_F(SimulatedDeviceMetricsTest, TemperatureReportsUnavailableForEverySwitch)
{
    const nlohmann::json report = m_manager->fetchTemperatureReportInternal();

    ASSERT_EQ(report.size(), 3u);
    for (const auto& [ip, value] : report.items())
    {
        EXPECT_EQ(value, MetricProbe::kHealthMetricUnavailable) << ip;
        EXPECT_FALSE(looksLikeAMeasurement(value)) << ip << " reports " << value.dump()
                                                   << " degrees, from a process with no sensor";
    }
}

TEST_F(SimulatedDeviceMetricsTest, CpuAndMemoryNoLongerDifferOnlyByAccident)
{
    // The reported symptom: the two endpoints answered byte-identical bodies because they were
    // the same expression on the same seed. They are still equal -- both are the sentinel -- so
    // equality is not the property to pin. What must hold is that neither is a figure at all.
    const nlohmann::json cpu = m_manager->fetchCpuReportInternal();
    const nlohmann::json memory = m_manager->fetchMemoryReportInternal();

    ASSERT_EQ(cpu.size(), memory.size());
    for (const auto& [ip, value] : cpu.items())
    {
        EXPECT_FALSE(looksLikeAMeasurement(value)) << "cpu " << ip;
        EXPECT_FALSE(looksLikeAMeasurement(memory.at(ip))) << "memory " << ip;
    }
}

TEST_F(SimulatedDeviceMetricsTest, NoTwoSwitchesShareAFabricatedNumber)
{
    // This is the demo failure in its own words: someone clicks two switches and reads the same
    // percentage. `% 50` made that the likely case over ten switches. Stated separately from the
    // sentinel assertions so that reintroducing *any* per-switch invented figure fails here,
    // including a wider or better-spread one.
    const nlohmann::json cpu = m_manager->fetchCpuReportInternal();
    for (const auto& [ip, value] : cpu.items())
    {
        ASSERT_FALSE(looksLikeAMeasurement(value))
            << ip << " reports a per-switch number again (" << value.dump()
            << "); two switches showing the same one is what F-1 was about";
    }
}

TEST_F(SimulatedDeviceMetricsTest, TheIntentTranslatorsPerDeviceQueryAgreesWithTheMap)
{
    // getSingleSwitchCpuReport is the fourth copy of the fabrication and the one F-1's entry
    // does not name. IntentTranslator.cpp:447 is its only caller: "what is s1's CPU?".
    const nlohmann::json single = m_manager->getSingleSwitchCpuReport("10.0.0.1");

    ASSERT_TRUE(single.contains("cpu_usage")) << single.dump();
    EXPECT_EQ(single["cpu_usage"], MetricProbe::kHealthMetricUnavailable);
    EXPECT_FALSE(looksLikeAMeasurement(single["cpu_usage"]))
        << "the per-device path still invents a figure: " << single.dump();
    EXPECT_EQ(single["dpid"], 1u);
}

TEST_F(SimulatedDeviceMetricsTest, ADownSwitchStillReportsTheSameSentinel)
{
    // The !isUp branch already returned -1 and must keep doing so: this is what makes the
    // sentinel a single meaning rather than two that happen to share a number. A down switch and
    // a simulated one are both "no reading available", and neither is 0%.
    addSwitch("10.0.0.4", 4, /*isUp=*/false);

    for (const nlohmann::json report : {m_manager->fetchCpuReportInternal(),
                                        m_manager->fetchMemoryReportInternal(),
                                        m_manager->fetchTemperatureReportInternal()})
    {
        ASSERT_TRUE(report.contains("10.0.0.4")) << report.dump();
        EXPECT_EQ(report["10.0.0.4"], MetricProbe::kHealthMetricUnavailable);
    }
}

TEST_F(SimulatedDeviceMetricsTest, HostsAreStillOmittedFromEveryReport)
{
    // A host has no health figure to report and never had a key here. Worth pinning because the
    // fix touched the branch immediately after the vertexType filter in all three functions.
    const auto v = boost::add_vertex(*m_graph);
    (*m_graph)[v].vertexType = VertexType::HOST;
    (*m_graph)[v].ip.push_back(utils::ipStringToUint32("10.0.0.100"));

    for (const nlohmann::json report : {m_manager->fetchCpuReportInternal(),
                                        m_manager->fetchMemoryReportInternal(),
                                        m_manager->fetchTemperatureReportInternal()})
    {
        EXPECT_FALSE(report.contains("10.0.0.100")) << report.dump();
        EXPECT_EQ(report.size(), 3u) << report.dump();
    }
}
