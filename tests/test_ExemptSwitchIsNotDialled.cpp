/**
 * E-23 / E-25 / E-30 -- the `switch_kind` exemption stops being a note to itself.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT WAS MEASURED
 *
 * W15-2 (2026-09-06) let a topology declare a switch whose `brand_name` this build has no data
 * plane for, provided the node also declares an explicit `switch_kind`. The condition Adam
 * attached to that ruling was that such a machine be MARKED as one whose power and telemetry
 * nobody manages, so the exemption could not be mistaken for support. The mark was written --
 * `VertexProperties::powerPath` / `::telemetryPath`, both "none" -- and then two things were
 * true of it:
 *
 *   1. E-23. `DeviceConfigurationAndPowerManager` never read it. In TESTBED mode its six
 *      brand-branching sites all fall into an `else` written for
 *      "Brocade / Others (Currently via SSH)", so a switch admitted only by its `switch_kind`
 *      was sent Brocade's power OID, Brocade's CPU OID, Brocade's memory OID and an SSH
 *      `show power` -- once every ten seconds, forever, to a machine that was never going to
 *      answer any of them.
 *
 *   2. E-25/E-30. Nothing outside the process could see the mark. Measured 2026-09-07, round-2
 *      log lw17c: a kernel carrying the exemption (branch binary 85822a97) was fed a topology
 *      whose dpid 7 has `brand_name: "NOT_A_REAL_KIND"` and `switch_kind: "ovs"`, accepted it,
 *      and served that node from /ndt/get_graph_data with `brand_name`, `admin_state` and
 *      `is_up` -- no `power_path`, no `telemetry_path`, and no line anywhere in the log saying a
 *      switch had been admitted this way (grepped for unmanaged / power_path / admitted: 0
 *      hits). The mark existed only in memory.
 *
 * WHAT THIS FILE ASSERTS
 *
 *   A. The six sites do not dial an exempted switch, and each of them says so in its answer.
 *      "Does not dial" is a claim about a call that does NOT happen, so it is asserted by
 *      COUNTING calls through three virtual seams -- readFromDevice, readFromDeviceArgv and
 *      readPowerOverSsh -- which is why those seams exist. A non-exempt switch in the same
 *      graph, in the same round, still dials: that pairing is what stops "0 calls" from being
 *      satisfied by a manager that dials nobody.
 *
 *   B. MININET is untouched. An exempted switch still gets its synthetic power figure, because
 *      that figure is a function of the dpid alone and was never a question asked of the
 *      machine. Over-guarding is how a fix for "asks the wrong question" turns into a silent
 *      loss of data, and this file has the widening test to say so.
 *
 *   C. The two marks reach /ndt/get_graph_data, on switch nodes and not on hosts, and the load
 *      that admits an exempted switch says so once in the log.
 *
 *   D. R5 (Adam's ruling of 2026-09-10). `power_path` reaches /ndt/get_power_report as well, on
 *      every entry the report can emit. E-25 marked the switch on the topology endpoint and left
 *      the number it qualifies on another one: measured 2026-09-10 on a live OVS fabric, the
 *      exempted dpid 7 answered `power_consumed: 44487` there and the real OVS at dpid 1
 *      answered 92465, with nothing in that body to tell them apart. Section 10 holds these
 *      cases and the reasoning for asserting a key rather than a changed value.
 *
 * 🔴 WHY THE COUNTING DOUBLE MUST REPLACE ALL THREE SEAMS. The same warning OVSPowerStrategy.hpp
 * gives about executeArgvCommand. A double that overrode readFromDevice alone would still let
 * getSingleSwitchCpuReport's argv calls and the power report's SSH call through to the real
 * machine: the test would run `snmpget` and `ssh` against an address that is not there, take ten
 * seconds a case, and report a call count that was a comfortable lie.
 */

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <string>
#include <system_error>
#include <vector>

#include <unistd.h> // getpid, for a temp-file name no concurrent run collides with

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>
#include <nlohmann/json.hpp>
#include <spdlog/sinks/ringbuffer_sink.h>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

namespace
{

using nlohmann::json;

/// A brand no shipped topology file names and no branch in this build is written for. The same
/// spelling the W15-2 suite uses, so the two files agree about what "unknown" means.
constexpr const char* kUnknownBrand = "CiscoC9300";

/// dpids. 7 is exempt; 8 is a Brocade, i.e. the control that must keep being dialled.
constexpr std::uint64_t kExemptDpid = 7;
constexpr std::uint64_t kBrocadeDpid = 8;

/// [Co-developed with claude code -- Adam] (R5.) An OVS bridge, i.e. the control for the MININET
/// cases: same mode, same synthetic figure, `power_path` "synthetic" rather than "none". 6 and
/// not 1 so it cannot be confused with the live fabric's dpid 1 in a failure message.
constexpr std::uint64_t kOvsDpid = 6;

/**
 * @brief The manager with its three transport seams replaced by counters.
 *
 * Records every command it was asked to run rather than running it, so a case can assert both
 * "how many" and "what" -- the second matters because a count alone cannot tell an SNMP read of
 * the exempted switch from one of its neighbour.
 */
class DialCountingManager : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::DeviceConfigurationAndPowerManager;
    using DeviceConfigurationAndPowerManager::fetchCpuReportInternal;
    using DeviceConfigurationAndPowerManager::fetchMemoryReportInternal;
    using DeviceConfigurationAndPowerManager::fetchPowerReportInternal;
    using DeviceConfigurationAndPowerManager::fetchTemperatureReportInternal;
    using DeviceConfigurationAndPowerManager::kHealthMetricUnavailable;

    /// Every command handed to any of the three seams, in order.
    std::vector<std::string> dialled;

    /// How many of them mention @p needle -- in practice a management address.
    std::size_t dialledMentioning(const std::string& needle) const
    {
        std::size_t n = 0;
        for (const auto& cmd : dialled)
        {
            if (cmd.find(needle) != std::string::npos)
            {
                ++n;
            }
        }
        return n;
    }

    /// Everything dialled, for a failure message. "0 calls" is unreadable without the list of
    /// calls that were nonetheless made.
    std::string dialledLog() const
    {
        if (dialled.empty())
        {
            return "(nothing was dialled)";
        }
        std::string all;
        for (const auto& cmd : dialled)
        {
            all += "\n    " + cmd;
        }
        return all;
    }

  protected:
    std::string readFromDevice(const std::string& cmd) override
    {
        dialled.push_back(cmd);
        // Empty: every caller's regex fails to match and the value stays at its sentinel, which
        // is what a real switch that does not answer produces too. Returning a plausible reading
        // would make a dialled site indistinguishable from an undialled one in the body.
        return "";
    }

    std::string readFromDeviceArgv(const std::vector<std::string>& argv) override
    {
        dialled.push_back(utils::describeArgv(argv));
        return "";
    }

    std::string readPowerOverSsh(const std::string& ip, const std::string& username) override
    {
        dialled.push_back("ssh " + username + "@" + ip + " show power");
        return "";
    }
};

/// Exposes the protected loader. Same seam as test_TopologyInputValidation.cpp's.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void load(const std::string& path)
    {
        loadStaticTopologyFromFile(path);
    }
};

/**
 * @brief Captures every record the global logger emits while it is alive, at trace level.
 *
 * The helper tests/test_CpuReportNoIpSwitch.cpp and tests/test_TopologyPollRound.cpp already
 * carry, duplicated for the reason those files give: hoisting it would create a test-support
 * header several suites then have to agree on.
 */
class LogCapture
{
  public:
    LogCapture()
        : m_logger(Logger::instance()),
          m_savedLevel(m_logger->level()),
          m_sink(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(512))
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

class ExemptSwitchTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_mutex = std::make_shared<std::shared_mutex>();
        m_bus = std::make_shared<EventBus>();
    }

    void buildManager(utils::DeploymentMode mode)
    {
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(m_graph, m_mutex, m_bus, mode);
        // Nothing here starts a thread: the constructor only builds the power strategies, and
        // start() is never called.
        m_manager = std::make_unique<DialCountingManager>(m_monitor, mode, "localhost", nullptr);
    }

    /**
     * @brief A switch vertex whose power/telemetry marks are derived the way the loader derives
     *        them -- from the brand, through the one pair of functions in GraphTypes.hpp.
     *
     * 🔴 Derived, never hand-set. Writing `powerPath = "none"` here would make this suite green
     * against a build whose loader had stopped setting the field at all, which is the mark's
     * whole point of failure. The load-time half is pinned separately, over a real file, by
     * TheLoadedExemptSwitchIsMarkedAndAnnounced below.
     *
     * @return the vertex descriptor, so a case can say "and this one is down" or "and this one
     *         has no address" without a second copy of the derivation above. (R5.)
     */
    boost::graph_traits<Graph>::vertex_descriptor
    addSwitch(const std::string& ip, std::uint64_t dpid, const std::string& brand)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].dpid = dpid;
        (*m_graph)[v].isUp = true;
        (*m_graph)[v].brandName = brand;
        (*m_graph)[v].powerPath = powerPathForBrandName(brand);
        (*m_graph)[v].telemetryPath = telemetryPathForBrandName(brand);
        (*m_graph)[v].ip.push_back(utils::ipStringToUint32(ip));
        return v;
    }

    /// The one entry of @p report whose "dpid" is @p dpid. Fails the case rather than throwing:
    /// a missing entry is a different defect from a wrong value and must not read as a crash.
    static json entryForDpid(const json& report, std::uint64_t dpid)
    {
        for (const auto& entry : report)
        {
            if (entry.value("dpid", std::uint64_t{0}) == dpid)
            {
                return entry;
            }
        }
        ADD_FAILURE() << "no entry for dpid " << dpid << " in " << report.dump();
        return json::object();
    }

    /// The exempted switch and, beside it, a Brocade that must keep being dialled. Both up, both
    /// addressed: the ONLY difference between them is the brand.
    void addTheExemptSwitchAndItsControl()
    {
        addSwitch(kExemptIp, kExemptDpid, kUnknownBrand);
        addSwitch(kBrocadeIp, kBrocadeDpid, std::string(kBrandBrocadeICX7250));
    }

    /// One round of statusUpdateWorker's four fetches, in the order that worker calls them.
    void oneStatusRound()
    {
        m_manager->fetchPowerReportInternal();
        m_manager->fetchCpuReportInternal();
        m_manager->fetchMemoryReportInternal();
        m_manager->fetchTemperatureReportInternal();
    }

    static constexpr const char* kExemptIp = "192.168.123.17";
    static constexpr const char* kBrocadeIp = "192.168.123.18";
    /// [Co-developed with claude code -- Adam] (R5.) @see kOvsDpid.
    static constexpr const char* kOvsIp = "192.168.123.16";

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_mutex;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::unique_ptr<DialCountingManager> m_manager;
};

} // namespace

// -------------------------------------------------------------------------------------------
// 0. The premise. If this is not true the six cases below are asserting nothing.
// -------------------------------------------------------------------------------------------

TEST_F(ExemptSwitchTest, TheMarkIsWhatTellsTheTwoSwitchesApart)
{
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const VertexProperties* exempt = nullptr;
    const VertexProperties* brocade = nullptr;
    for (auto v : boost::make_iterator_range(boost::vertices(*m_graph)))
    {
        if ((*m_graph)[v].dpid == kExemptDpid)
        {
            exempt = &(*m_graph)[v];
        }
        else if ((*m_graph)[v].dpid == kBrocadeDpid)
        {
            brocade = &(*m_graph)[v];
        }
    }
    ASSERT_NE(exempt, nullptr);
    ASSERT_NE(brocade, nullptr);

    EXPECT_TRUE(isExemptFromBrandPaths(*exempt))
        << "brand " << kUnknownBrand << " was given a power path by this build, so nothing below "
        << "is testing an exemption: power_path=" << exempt->powerPath;
    EXPECT_FALSE(isExemptFromBrandPaths(*brocade))
        << "the control switch is itself exempt, so every \"still dialled\" assertion below is "
        << "vacuous: power_path=" << brocade->powerPath;
    EXPECT_EQ(brocade->powerPath, "ssh")
        << "the control is supposed to be on the SSH branch -- the one an exempted switch used "
           "to fall into by accident";
}

// -------------------------------------------------------------------------------------------
// 1-4. The four status-worker reports. E-23 sites 1-4.
// -------------------------------------------------------------------------------------------

TEST_F(ExemptSwitchTest, TheTestbedPowerReportDoesNotSshTheExemptSwitch)
{
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const json report = m_manager->fetchPowerReportInternal();

    EXPECT_EQ(m_manager->dialledMentioning(kExemptIp), 0u)
        << "the exempted switch was dialled anyway: " << m_manager->dialledLog();
    EXPECT_EQ(m_manager->dialledMentioning(kBrocadeIp), 1u)
        << "the control switch stopped being dialled, so the guard is wider than the exemption: "
        << m_manager->dialledLog();

    ASSERT_EQ(report.size(), 2u) << report.dump();
    for (const auto& entry : report)
    {
        if (entry.at("dpid").get<std::uint64_t>() == kExemptDpid)
        {
            EXPECT_EQ(entry.at("power_consumed"), DialCountingManager::kHealthMetricUnavailable)
                << "0 is this endpoint's answer for a switch that is powered OFF, and an "
                   "unreadable switch reported as 0 mW is the Energy-Saving App's cue to act: "
                << report.dump();
        }
    }
}

TEST_F(ExemptSwitchTest, TheCpuReportDoesNotSnmpTheExemptSwitch)
{
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const json report = m_manager->fetchCpuReportInternal();

    EXPECT_EQ(m_manager->dialledMentioning(kExemptIp), 0u)
        << m_manager->dialledLog();
    EXPECT_EQ(m_manager->dialledMentioning(kBrocadeIp), 1u)
        << m_manager->dialledLog();
    EXPECT_EQ(report.at(kExemptIp), DialCountingManager::kHealthMetricUnavailable)
        << report.dump();
}

TEST_F(ExemptSwitchTest, TheMemoryReportDoesNotSnmpTheExemptSwitch)
{
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const json report = m_manager->fetchMemoryReportInternal();

    EXPECT_EQ(m_manager->dialledMentioning(kExemptIp), 0u)
        << m_manager->dialledLog();
    EXPECT_EQ(m_manager->dialledMentioning(kBrocadeIp), 1u)
        << m_manager->dialledLog();
    EXPECT_EQ(report.at(kExemptIp), DialCountingManager::kHealthMetricUnavailable)
        << report.dump();
}

TEST_F(ExemptSwitchTest, TheTemperatureReportAnswersTheSentinelRatherThanTheHpeSentence)
{
    // 🔴 THE ONE SITE WHERE E-23 CHANGES WHAT IS SAID AND NOT WHAT IS DONE, and it is written
    // down rather than folded into the other three. This report already returned before its
    // snmpget for any non-HPE switch in TESTBED, so it never dialled an exempted switch even
    // before the fix -- what it did was answer "The temperature function only supports the
    // HPE 5520.", which reads as "we have a path, just not for this model" about a machine this
    // build has no path for at all.
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const json report = m_manager->fetchTemperatureReportInternal();

    EXPECT_EQ(m_manager->dialled.size(), 0u)
        << "neither switch is an HPE, so this report has nothing to dial: "
        << m_manager->dialledLog();
    EXPECT_EQ(report.at(kExemptIp), DialCountingManager::kHealthMetricUnavailable)
        << report.dump();
    EXPECT_EQ(report.at(kBrocadeIp), "The temperature function only supports the HPE 5520.")
        << "the Brocade's answer changed. E-23 is about the switch nobody wrote a branch for, "
           "not about the ones somebody did: "
        << report.dump();
}

// -------------------------------------------------------------------------------------------
// 5-6. The two single-switch endpoints. E-23 sites 5-6, and the two that answer a caller.
// -------------------------------------------------------------------------------------------

TEST_F(ExemptSwitchTest, TheSingleSwitchPowerReportSaysExemptRatherThanFailing)
{
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const json report = m_manager->getSingleSwitchPowerReport(kExemptIp);

    EXPECT_EQ(m_manager->dialled.size(), 0u) << m_manager->dialledLog();
    ASSERT_TRUE(report.contains("exempt"))
        << "the reply carries no reason, so the Intent Translator has nothing to turn into a "
           "sentence and the -1 reads as a switch that could not be reached: "
        << report.dump();
    EXPECT_NE(report.at("exempt").get<std::string>().find("power_path none"), std::string::npos)
        << report.dump();
    EXPECT_EQ(report.at("dpid"), kExemptDpid) << report.dump();
    EXPECT_EQ(report.at("power_consumed"), DialCountingManager::kHealthMetricUnavailable)
        << report.dump();
}

TEST_F(ExemptSwitchTest, TheSingleSwitchPowerReportStillSshesANonExemptSwitch)
{
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const json report = m_manager->getSingleSwitchPowerReport(kBrocadeIp);

    EXPECT_EQ(m_manager->dialledMentioning(kBrocadeIp), 1u)
        << "the control switch stopped being dialled: " << m_manager->dialledLog();
    EXPECT_FALSE(report.contains("exempt")) << report.dump();
}

TEST_F(ExemptSwitchTest, TheSingleSwitchCpuReportSaysExemptRatherThanFailing)
{
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const json report = m_manager->getSingleSwitchCpuReport(kExemptIp);

    EXPECT_EQ(m_manager->dialled.size(), 0u) << m_manager->dialledLog();
    ASSERT_TRUE(report.contains("exempt")) << report.dump();
    EXPECT_EQ(report.at("dpid"), kExemptDpid) << report.dump();
    EXPECT_EQ(report.at("cpu_usage"), DialCountingManager::kHealthMetricUnavailable)
        << report.dump();
}

TEST_F(ExemptSwitchTest, TheSingleSwitchCpuReportStillSnmpsANonExemptSwitch)
{
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const json report = m_manager->getSingleSwitchCpuReport(kBrocadeIp);

    EXPECT_EQ(m_manager->dialledMentioning(kBrocadeIp), 1u)
        << m_manager->dialledLog();
    EXPECT_FALSE(report.contains("exempt")) << report.dump();
}

// -------------------------------------------------------------------------------------------
// 7. The widening tests. Over-guarding is the failure mode a "does not dial" fix invites.
// -------------------------------------------------------------------------------------------

TEST_F(ExemptSwitchTest, MininetStillGivesTheExemptSwitchItsSyntheticPowerFigure)
{
    // The MININET power figure is syntheticPowerMilliwattsFor(dpid) -- a function of the dpid
    // alone, never a question asked of the machine -- so the exemption has no business
    // suppressing it. The same shape as
    // NoIpSwitchTest.MininetPowerStillReportsARealFigureForAnAddresslessSwitch: a guard hoisted
    // above the mode check compiles, looks tidier, and silently loses data.
    buildManager(utils::MININET);
    addSwitch(kExemptIp, kExemptDpid, kUnknownBrand);

    const json report = m_manager->fetchPowerReportInternal();

    ASSERT_EQ(report.size(), 1u) << report.dump();
    const auto mW = report[0].at("power_consumed").get<std::int64_t>();
    EXPECT_GE(mW, 30000) << report.dump();
    EXPECT_LE(mW, 149999) << report.dump();
}

TEST_F(ExemptSwitchTest, MininetStillGivesTheExemptSwitchTheSameSyntheticFigureThroughBothPaths)
{
    // getSingleSwitchPowerReport is the second copy of the synthetic figure, and the two used to
    // disagree (test_SyntheticPower.cpp). A TESTBED-only exemption guard must not make them
    // disagree again by short-circuiting one of them in MININET.
    buildManager(utils::MININET);
    addSwitch(kExemptIp, kExemptDpid, kUnknownBrand);

    const json single = m_manager->getSingleSwitchPowerReport(kExemptIp);
    const json map = m_manager->fetchPowerReportInternal();

    ASSERT_FALSE(single.contains("exempt"))
        << "MININET has nothing to exempt the switch from: " << single.dump();
    EXPECT_EQ(single.at("power_consumed"), map[0].at("power_consumed"))
        << single.dump() << " vs " << map.dump();
}

// -------------------------------------------------------------------------------------------
// 8. The log. One line, not one line every ten seconds.
// -------------------------------------------------------------------------------------------

TEST_F(ExemptSwitchTest, TheExemptionIsLoggedOncePerEpisodeAndNotOncePerRound)
{
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    LogCapture log;
    oneStatusRound();
    const std::size_t afterOne = log.count("power_path none");
    oneStatusRound();
    oneStatusRound();

    EXPECT_EQ(afterOne, 1u)
        << "one status round calls four reports, and an un-edge-triggered line here is four "
           "lines every ten seconds forever -- the shape that put 3596 sudo errors in one run:\n"
        << log.text();
    EXPECT_EQ(log.count("power_path none"), 1u)
        << "the line came back on a later round, so it is per-round and not per-episode:\n"
        << log.text();
    EXPECT_NE(log.text().find(kUnknownBrand), std::string::npos)
        << "the line does not name the brand, so an operator cannot tell which model this "
           "build is missing:\n"
        << log.text();
}

// -------------------------------------------------------------------------------------------
// 9. E-25 / E-30: the marks on the wire, and the line at load.
// -------------------------------------------------------------------------------------------

TEST_F(ExemptSwitchTest, GetGraphDataCarriesBothMarksOnASwitchAndNeitherOnAHost)
{
    // /ndt/get_graph_data serialises its nodes with `result["nodes"].push_back(graph[vd])`
    // (HttpSession.cpp), which is to_json(VertexProperties). That is a DIFFERENT serialiser from
    // getStaticTopologyJson's hand-written initialiser, which is where W15-2 put the marks -- so
    // this is the endpoint the four external apps read and the one lw17c measured as unmarked.
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const auto host = boost::add_vertex(*m_graph);
    (*m_graph)[host].vertexType = VertexType::HOST;
    (*m_graph)[host].dpid = 0;

    json exemptNode;
    json brocadeNode;
    json hostNode;
    for (auto v : boost::make_iterator_range(boost::vertices(*m_graph)))
    {
        const json serialised = (*m_graph)[v];
        if ((*m_graph)[v].vertexType == VertexType::HOST)
        {
            hostNode = serialised;
        }
        else if ((*m_graph)[v].dpid == kExemptDpid)
        {
            exemptNode = serialised;
        }
        else
        {
            brocadeNode = serialised;
        }
    }

    ASSERT_TRUE(exemptNode.contains("power_path"))
        << "the exemption is invisible from outside the process again: " << exemptNode.dump();
    EXPECT_EQ(exemptNode.at("power_path"), "none") << exemptNode.dump();
    EXPECT_EQ(exemptNode.at("telemetry_path"), "none") << exemptNode.dump();

    EXPECT_EQ(brocadeNode.at("power_path"), "ssh")
        << "a supported brand must not read as unmanaged, or \"none\" means nothing: "
        << brocadeNode.dump();
    EXPECT_EQ(brocadeNode.at("telemetry_path"), "snmp") << brocadeNode.dump();

    EXPECT_FALSE(hostNode.contains("power_path"))
        << "a host has no brand, no plug and no OID; publishing \"none\" for one invites the "
           "reading that some OTHER host might have a path: "
        << hostNode.dump();
    EXPECT_FALSE(hostNode.contains("telemetry_path")) << hostNode.dump();

    // Purely additive: nothing a consumer reads today changed spelling, type or value.
    EXPECT_TRUE(exemptNode.contains("brand_name")) << exemptNode.dump();
    EXPECT_TRUE(exemptNode.contains("is_up")) << exemptNode.dump();
    EXPECT_TRUE(exemptNode.contains("admin_state")) << exemptNode.dump();
}

namespace
{

/// The shipped P4 4-host topology with dpid 7's brand replaced and a `switch_kind` added -- the
/// same file shape round-2's lw17c fed a real kernel. Removed on destruction.
class ExemptedTopologyFile
{
  public:
    explicit ExemptedTopologyFile(bool exemptOne)
    {
        for (const char* dir : {"setting", "../setting", "../../setting"})
        {
            if (std::filesystem::is_directory(dir))
            {
                m_source = std::string(dir) + "/StaticNetworkTopologyP4_10Switches_4Hosts.json";
                break;
            }
        }
        if (m_source.empty() || !std::filesystem::exists(m_source))
        {
            return;
        }
        std::ifstream in(m_source);
        in >> m_json;

        if (exemptOne)
        {
            for (auto& node : m_json.at("nodes"))
            {
                if (node.at("vertex_type").get<int>() == 0 &&
                    node.at("dpid").get<std::uint64_t>() == kExemptDpid)
                {
                    node["brand_name"] = kUnknownBrand;
                    // Without this the loader refuses the file outright (W15 door 3e). The
                    // exemption IS this key.
                    node["switch_kind"] = "bmv2";
                }
            }
        }

        m_path = (std::filesystem::temp_directory_path() /
                  ("ndt_exempt_" + std::string(exemptOne ? "one" : "none") + "_" +
                   std::to_string(::getpid()) + ".json"))
                     .string();
        std::ofstream out(m_path);
        out << m_json.dump();
    }

    ~ExemptedTopologyFile()
    {
        std::error_code ignored;
        std::filesystem::remove(m_path, ignored);
    }

    ExemptedTopologyFile(const ExemptedTopologyFile&) = delete;
    ExemptedTopologyFile& operator=(const ExemptedTopologyFile&) = delete;

    bool usable() const { return !m_path.empty(); }
    const std::string& path() const { return m_path; }

  private:
    json m_json;
    std::string m_source;
    std::string m_path;
};

} // namespace

TEST_F(ExemptSwitchTest, TheLoadedExemptSwitchIsMarkedAndAnnounced)
{
    ExemptedTopologyFile file(true);
    ASSERT_TRUE(file.usable()) << "the shipped P4 topology was not found next to the test binary";

    auto graph = std::make_shared<Graph>();
    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, utils::MININET};

    LogCapture log;
    ASSERT_NO_THROW(monitor.load(file.path()))
        << "the exemption stopped admitting the file, so nothing below is about the exemption";

    bool found = false;
    for (auto [vi, viEnd] = boost::vertices(*graph); vi != viEnd; ++vi)
    {
        const auto& v = (*graph)[*vi];
        if (v.vertexType == VertexType::SWITCH && v.dpid == kExemptDpid)
        {
            found = true;
            // Set by the LOADER, from the brand -- the half the hand-built fixtures above cannot
            // reach.
            EXPECT_EQ(v.powerPath, "none") << "the loader stopped marking the exempted switch";
            EXPECT_EQ(v.telemetryPath, "none");
        }
    }
    EXPECT_TRUE(found) << "dpid " << kExemptDpid << " is not in the loaded graph";

    EXPECT_EQ(log.count("exempt from power/telemetry (power_path=none)"), 1u)
        << "the kernel admitted a switch it cannot read power or health from and said nothing "
           "about it in the log -- exactly what round-2's lw17c measured:\n"
        << log.text();
    EXPECT_NE(log.text().find("dpid 7"), std::string::npos)
        << "the line does not name which switch:\n" << log.text();
}

TEST_F(ExemptSwitchTest, AFleetWithNoExemptSwitchSaysNothingAtAll)
{
    // The control for the line above. A message on every start is a message nobody reads, and
    // the shipped fleet has no exempted switch in it -- so the quiet case is the normal one.
    ExemptedTopologyFile file(false);
    ASSERT_TRUE(file.usable()) << "the shipped P4 topology was not found next to the test binary";

    auto graph = std::make_shared<Graph>();
    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, utils::MININET};

    LogCapture log;
    ASSERT_NO_THROW(monitor.load(file.path()));

    EXPECT_EQ(log.count("exempt from power/telemetry"), 0u)
        << "a fleet this build can drive end to end was warned about anyway:\n"
        << log.text();
}

// -------------------------------------------------------------------------------------------
// 10. R5: /ndt/get_power_report says which path each figure came from.
// -------------------------------------------------------------------------------------------
//
// [Co-developed with claude code -- Adam]
//
// WHAT WAS MEASURED. 2026-09-10, live four-host OVS fabric, kernel binary 433f48a6223c7ef7,
// the exempted topology loaded through NDT_TOPO
// (scratch/overnight-2026-09-05/fix/R4-LIVE-SUMMARY.md §4-A15 and §7-1): /ndt/get_power_report
// answered `power_consumed: 44487` for dpid 7 -- whose `power_path` is "none" -- and `92465`
// for the real OVS at dpid 1. Ten switches, ten different plausible figures, and nothing in the
// body to say which of them came from a path this build has. The mark E-25 put on
// /ndt/get_graph_data's nodes was one endpoint away from the number it qualifies, and a consumer
// had to fetch a second endpoint and join on `dpid` to find it.
//
// 🔴 WHY THESE CASES ASSERT A KEY AND NOT A CHANGED VALUE. Section 7 above is the reason: E-23
// ruled that MININET keeps the synthetic figure for an exempted switch, because that figure is
// syntheticPowerMilliwattsFor(dpid) and was never a question asked of the machine, and M11 of
// this suite's gate pins the widening that would take it away. So "44487 must not appear" is
// not available here without reversing that ruling; what was actually missing is the field, and
// E-25's own serialiser says how to add one -- "purely additive: no existing key changes type,
// spelling or value" (GraphTypes.hpp, to_json). Same key, same four-word vocabulary, read from
// the same vertex field, so the two endpoints cannot disagree.
//
// The four exits are asserted separately (case 3) because the mark is emitted in one place
// precisely so it cannot be on three of them: a key that appears and disappears is worse for a
// consumer than no key, and the loop's exits are powered-off, no-address, exempt and read.

TEST_F(ExemptSwitchTest, ThePowerReportSaysWhichPathEachFigureCameFrom)
{
    // MININET, because that is the mode the defect was measured in and the mode where the number
    // alone carries no information at all: every figure here is synthetic.
    buildManager(utils::MININET);
    addSwitch(kExemptIp, kExemptDpid, kUnknownBrand);
    addSwitch(kOvsIp, kOvsDpid, std::string(kBrandOVS));

    const json report = m_manager->fetchPowerReportInternal();
    ASSERT_EQ(report.size(), 2u) << report.dump();

    const json exempt = entryForDpid(report, kExemptDpid);
    const json ovs = entryForDpid(report, kOvsDpid);

    ASSERT_TRUE(exempt.contains("power_path"))
        << "the exempted switch's figure is unqualified, which is what was measured on the live "
           "fabric: a reader of this endpoint cannot tell it from a measured one: "
        << report.dump();
    EXPECT_EQ(exempt.at("power_path"), "none")
        << "not the vocabulary /ndt/get_graph_data publishes for the same vertex: "
        << report.dump();
    ASSERT_TRUE(ovs.contains("power_path")) << report.dump();
    EXPECT_EQ(ovs.at("power_path"), "synthetic") << report.dump();

    // 🔴 The zero-discrimination point, and the reason the key is the fix. Both figures are in
    // the synthetic band and both are perfectly plausible; the ONLY thing in this body that
    // tells the exempted machine from the one this build has a path for is the key above. If
    // this pair ever stops holding, the two switches differ in some other way and the case above
    // is no longer asserting what it claims to.
    const auto exemptMw = exempt.at("power_consumed").get<std::int64_t>();
    const auto ovsMw = ovs.at("power_consumed").get<std::int64_t>();
    EXPECT_GE(exemptMw, 30000) << report.dump();
    EXPECT_LE(exemptMw, 149999) << report.dump();
    EXPECT_GE(ovsMw, 30000) << report.dump();
    EXPECT_LE(ovsMw, 149999) << report.dump();
    EXPECT_NE(exempt.at("power_path"), ovs.at("power_path"))
        << "the two entries are indistinguishable, so this suite is pinning nothing: "
        << report.dump();
}

TEST_F(ExemptSwitchTest, TheTestbedPowerReportSaysWhetherItsMinusOneIsUnaskedOrUnanswered)
{
    // doc/2026-01-02_ndt_api.md §6 has said since E-23 that "a -1 from a switch whose power_path
    // is snmp or ssh is a device that did not answer; a -1 from one whose power_path is none is a
    // device nobody asked" -- and until R5 this body carried neither path, so the sentence was
    // only checkable by fetching /ndt/get_graph_data too. The exempted switch and an addressed
    // Brocade whose SSH reply is empty are the two halves of it.
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();

    const json report = m_manager->fetchPowerReportInternal();
    ASSERT_EQ(report.size(), 2u) << report.dump();

    const json exempt = entryForDpid(report, kExemptDpid);
    const json brocade = entryForDpid(report, kBrocadeDpid);

    EXPECT_EQ(exempt.at("power_consumed"), DialCountingManager::kHealthMetricUnavailable)
        << report.dump();
    EXPECT_EQ(exempt.at("power_path"), "none")
        << "the -1 is unqualified, so it reads as a switch that failed to answer: "
        << report.dump();

    // The control. It WAS dialled -- the counting double returns an empty reply, which is what a
    // machine that does not answer produces -- and its entry says a path exists for it.
    EXPECT_EQ(m_manager->dialledMentioning(kBrocadeIp), 1u) << m_manager->dialledLog();
    EXPECT_EQ(brocade.at("power_path"), "ssh")
        << "the non-exempt switch is marked as though nobody managed it either, i.e. the mark is "
           "wider than the exemption: "
        << report.dump();
}

TEST_F(ExemptSwitchTest, EveryExitOfThePowerReportCarriesThePath)
{
    // All four ways an entry can be produced, in one body, because the failure this guards is a
    // key present on some entries and absent from others -- a consumer that reads
    // `entry["power_path"]` then throws on the one switch the key was added for.
    buildManager(utils::TESTBED);
    addTheExemptSwitchAndItsControl();                                        // exempt + read
    const auto down = addSwitch("192.168.123.19", 9, std::string(kBrandBrocadeICX7250));
    (*m_graph)[down].isUp = false;                                            // powered off
    const auto noIp = addSwitch("192.168.123.20", 10, std::string(kBrandBrocadeICX7250));
    (*m_graph)[noIp].ip.clear();                                              // no address

    const json report = m_manager->fetchPowerReportInternal();
    ASSERT_EQ(report.size(), 4u) << report.dump();

    for (const auto& entry : report)
    {
        EXPECT_TRUE(entry.contains("power_path"))
            << "one exit of the loop emits an entry with no path on it: " << entry.dump()
            << " in " << report.dump();
    }
    // The two values each exit reports are unchanged by R5; asserted here so a future edit
    // cannot buy the key by moving a number.
    EXPECT_EQ(entryForDpid(report, 9).at("power_consumed"), 0)
        << "0 is this endpoint's answer for a switch that is powered off: " << report.dump();
    EXPECT_EQ(entryForDpid(report, 10).at("power_consumed"),
              DialCountingManager::kHealthMetricUnavailable)
        << report.dump();
    EXPECT_EQ(entryForDpid(report, 9).at("power_path"), "ssh") << report.dump();
    EXPECT_EQ(entryForDpid(report, 10).at("power_path"), "ssh") << report.dump();
}
