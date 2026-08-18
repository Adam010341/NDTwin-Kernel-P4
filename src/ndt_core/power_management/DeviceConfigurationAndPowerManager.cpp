#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "common_types/GraphTypes.hpp" // for VertexProp...
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp" // for TopologyAn...
#include "nlohmann/json.hpp"                              // for basic_json
#include "spdlog/spdlog-inl.h"                            // for default_lo...
#include "spdlog/spdlog.h"                                // for SPDLOG_LOG...
#include "utils/Logger.hpp"                               // for Logger
#include "utils/SSHHelper.hpp"                            // for getPowerRe...
#include "utils/Utils.hpp"                                // for Deployment...
#include <algorithm>                                      // for find_if
#include <cerrno>                                         // for errno
#include <cstring>                                        // for strerror
#include <sys/wait.h>                                     // for WIFEXITED, WEXITSTATUS
#include <boost/graph/detail/adjacency_list.hpp>          // for vertices
#include <boost/iterator/iterator_categories.hpp>         // for random_acc...
#include <boost/iterator/iterator_facade.hpp>             // for operator!=
#include <boost/range/irange.hpp>                         // for integer_it...
#include <boost/range/iterator_range_core.hpp>            // for iterator_r...
#include <chrono>                                         // for seconds
#include <cstdint>                                        // for uint32_t
#include "ndt_core/power_management/OVSPowerStrategy.hpp"
#include "ndt_core/power_management/P4PowerStrategy.hpp"
#include <cstdlib>                                        // for system
#include <ctype.h>                                        // for isdigit
#include <exception>                                      // for exception
#include <fstream>                                        // for basic_ostream
#include <iomanip>                                        // for std::setw and std::setfill
#include <optional>                                       // for optional
#include <random>                                         // for random_device
#include <regex>                                          // for regex_search
#include <spdlog/fmt/fmt.h>                               // for format
#include <sstream>                                        // for basic_ostr...
#include <stdexcept>                                      // for runtime_error
#include <stdio.h>                                        // for fgets, pclose
#include <thread>                                         // for thread
#include <utility>                                        // for pair, move

using namespace std;
using json = nlohmann::json;

DeviceConfigurationAndPowerManager::DeviceConfigurationAndPowerManager(
    shared_ptr<TopologyAndFlowMonitor> topoMonitor,
    int mode,
    std::string gwUrl,
    shared_ptr<ndtClassifier::Classifier> classifier)
    : m_topologyAndFlowMonitor(std::move(topoMonitor)),
      m_mode(static_cast<utils::DeploymentMode>(mode)),
      m_cachedPowerReport(nlohmann::json::array()),
      m_cachedCpuReport(nlohmann::json::object()),
      m_cachedMemoryReport(nlohmann::json::object()),
      m_cachedTemperatureReport(nlohmann::json::object()),
      GW_IP(gwUrl),
      m_classifier(classifier)
{
    m_ovsPowerStrategy = std::make_unique<OVSPowerStrategy>();
    m_p4PowerStrategy = std::make_unique<P4PowerStrategy>();
}

// [Co-developed with claude code -- Adam]
// Takes a dpid rather than a vertex descriptor so it can use the O(1) switch-kind index.
// The previous version called getGraph() -- a full deep copy of the graph -- even though
// its only caller had already copied it six lines earlier and had the dpid to hand.
// Returns nullptr for an unknown dpid instead of defaulting to the OVS strategy, which
// would have run ovs-vsctl against a bmv2 switch.
IPowerStrategy*
DeviceConfigurationAndPowerManager::getPowerStrategyForDpid(uint64_t dpid) const
{
    if (!m_topologyAndFlowMonitor)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "No topology monitor available; cannot power-manage dpid {}",
                            dpid);
        return nullptr;
    }

    const auto kind = m_topologyAndFlowMonitor->getSwitchKind(dpid);
    if (!kind.has_value())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "dpid {} is not a switch in the loaded topology; refusing to "
                           "guess how to power-manage it",
                           dpid);
        return nullptr;
    }

    switch (*kind)
    {
    case SwitchKind::BMV2:
        return m_p4PowerStrategy.get();
    case SwitchKind::OVS:
    case SwitchKind::HARDWARE:
        return m_ovsPowerStrategy.get();
    }

    SPDLOG_LOGGER_ERROR(Logger::instance(),
                        "dpid {} has an unhandled switch kind; this is a bug",
                        dpid);
    return nullptr;
}

// [Co-developed with claude code -- Adam]
void
DeviceConfigurationAndPowerManager::refreshDataPlaneKind()
{
    m_dataPlaneIsBmv2 = false;
    if (!m_topologyAndFlowMonitor)
    {
        return;
    }
    const auto groups = m_topologyAndFlowMonitor->getSwitchKindGroups();
    m_dataPlaneIsBmv2 = (groups.size() == 1 && groups.count(SwitchKind::BMV2) == 1);
}

void
DeviceConfigurationAndPowerManager::start()
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "DeviceConfigurationAndPowerManager Starts Up");
    // The topology is loaded by TopologyAndFlowMonitor before this runs, so the switch-kind
    // index is populated by now.
    refreshDataPlaneKind();

    if (m_mode == utils::DeploymentMode::TESTBED)
    {
        fetchSmartPlugInfoFromFile(TOPOLOGY_FILE);
    }

    this->m_running.store(true);
    m_pingThread = thread(&DeviceConfigurationAndPowerManager::pingWorker, this, 1);
    m_statusUpdateThread = thread(&DeviceConfigurationAndPowerManager::statusUpdateWorker, this);
    m_openflowTablesUpdateThread =
        thread(&DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker, this);
}

void
DeviceConfigurationAndPowerManager::stop()
{
    this->m_running.store(false);

    SPDLOG_LOGGER_INFO(Logger::instance(), "Collector Stops");

    if (m_pingThread.joinable())
    {
        m_pingThread.join();
    }

    if (m_statusUpdateThread.joinable())
    {
        m_statusUpdateThread.join();
    }
}

std::string
DeviceConfigurationAndPowerManager::parseIpParam(const std::string& target) const
{
    auto qpos = target.find('?');
    if (qpos == std::string::npos)
    {
        return {};
    }
    auto query = target.substr(qpos + 1);
    auto p = query.find("ip=");
    if (p == std::string::npos)
    {
        return {};
    }
    auto val = query.substr(p + 3);
    if (auto amp = val.find('&'); amp != std::string::npos)
    {
        val.resize(amp);
    }
    return val;
}

json
DeviceConfigurationAndPowerManager::getSwitchesPowerState(const std::string& target)
{
    const auto ip = parseIpParam(target);
    if (m_mode == utils::DeploymentMode::TESTBED)
    {
        return queryTestbed(ip);
    }
    else
    {
        return queryMininet(ip);
    }
}

json
DeviceConfigurationAndPowerManager::queryTestbed(const std::string& ipParam) const
{
    json result = json::object();
    std::vector<SwitchInfo> toQuery;

    SPDLOG_LOGGER_INFO(Logger::instance(), "query testbed {}", ipParam);

    // 1. decide which switches to query
    if (ipParam.empty())
    {
        toQuery = switchSmartPlugTable;
        SPDLOG_LOGGER_INFO(Logger::instance(), "toQuery size: {}", toQuery.size());
    }
    else
    {
        auto it = std::find_if(switchSmartPlugTable.begin(),
                               switchSmartPlugTable.end(),
                               [&](auto& si) { return si.switchIp == ipParam; });
        if (it == switchSmartPlugTable.end())
        {
            throw std::runtime_error("Unknown switch IP");
        }
        toQuery.push_back(*it);
    }

    // TODO: Do it parallelly
    // 2. for each switch, call the Flask /relay proxy with resource=outlet
    for (auto& si : toQuery)
    {
        try
        {
            std::ostringstream cmd;
            cmd << "curl -k -s -X GET " << "\"http://" << GW_IP << ":8000/relay"
                << "?ip=" << si.plugIp << "&resource=outlet" << "&index=" << si.plugIdx << "\"";

            std::string raw = utils::execCommand(cmd.str());

            std::string status;
            try
            {
                // first try JSON
                auto j = json::parse(raw);
                status = j.value("status", raw);
            }
            catch (json::parse_error&)
            {
                // fallback: extract between 2nd '>' and next '<'
                auto p1 = raw.find('>');
                auto p2 = (p1 != std::string::npos) ? raw.find('>', p1 + 1) : std::string::npos;
                if (p2 != std::string::npos)
                {
                    auto p3 = raw.find('<', p2 + 1);
                    if (p3 != std::string::npos && p3 > p2 + 1)
                    {
                        status = raw.substr(p2 + 1, p3 - p2 - 1);
                    }
                    else
                    {
                        status = raw; // give up
                    }
                }
                else
                {
                    status = raw;
                }
            }

            result[si.switchIp] = status;
        }
        catch (const std::exception& e)
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(),
                                "Error querying plug on {}: {}",
                                si.switchIp,
                                e.what());
            result[si.switchIp] = "error";
        }
    }

    return result;
}

json
DeviceConfigurationAndPowerManager::queryMininet(const std::string& ipParam) const
{
    json result = json::object();
    std::vector<std::string> ips;

    if (ipParam.empty())
    {
        auto graph = m_topologyAndFlowMonitor->getGraph();
        for (auto v : boost::make_iterator_range(vertices(graph)))
        {
            if (graph[v].vertexType == VertexType::SWITCH)
            {
                ips.push_back(utils::ipToString(graph[v].ip.front()));
            }
        }
    }
    else
    {
        ips.push_back(ipParam);
    }

    for (auto& sip : ips)
    {
        auto ipUint = utils::ipStringToUint32(sip);
        auto nodeOpt = m_topologyAndFlowMonitor->findSwitchByIp(ipUint);
        if (!nodeOpt.has_value())
        {
            throw std::runtime_error("Unknown switch IP");
        }
        bool isUp = m_topologyAndFlowMonitor->getVertexIsUp(nodeOpt.value());
        result[sip] = (isUp ? "ON" : "OFF");
    }
    return result;
}

bool
DeviceConfigurationAndPowerManager::pingSwitch(const std::string& ip, int timeout_sec = 5)
{
    const int max_attempts = 3;
    const auto retry_delay = std::chrono::seconds(1);

    for (int attempt = 1; attempt <= max_attempts; ++attempt)
    {
        std::string cmd = "ping -c 1 -W " + std::to_string(timeout_sec) + " " + ip + " 2>&1";
        SPDLOG_LOGGER_TRACE(Logger::instance(),
                            "Execute {} (attempt {}/{})",
                            cmd,
                            attempt,
                            max_attempts);

        std::string output = utils::execCommand(cmd);

        bool success = output.find("1 received") != std::string::npos ||
                       output.find("bytes from") != std::string::npos;

        if (success)
        {
            return true;
        }

        // If not last attempt, wait a bit before retrying
        if (attempt < max_attempts)
        {
            std::this_thread::sleep_for(retry_delay);
        }
    }

    return false; // all attempts failed
}

/** @brief Decides an OVS switch's liveness from the reported bridge list.
 *
 * [Co-developed with claude code -- Adam]
 * See the header for why this is a named function rather than an if/else in the loop.
 */
DeviceConfigurationAndPowerManager::OvsLiveness
DeviceConfigurationAndPowerManager::ovsLivenessFor(
    const std::string& bridgeName, const std::optional<std::vector<std::string>>& bridges)
{
    if (!bridges.has_value())
    {
        return OvsLiveness::Unknown;
    }
    const auto& list = *bridges;
    return std::find(list.begin(), list.end(), bridgeName) != list.end() ? OvsLiveness::Up
                                                                        : OvsLiveness::Down;
}

/** @brief Decides one bmv2 switch's liveness from the proxy's evidence. See the header for the
 *         policy and why each branch is the state it is.
 *
 * [Co-developed with claude code -- Adam]
 */
DeviceConfigurationAndPowerManager::OvsLiveness
DeviceConfigurationAndPowerManager::p4LivenessFor(uint64_t dpid,
                                                  const std::optional<json>& payload)
{
    // The proxy could not be reached, or said something unparseable. This is the branch that must
    // never be Down: one unreachable proxy would otherwise take all ten switches down at once.
    if (!payload.has_value())
    {
        return OvsLiveness::Unknown;
    }

    const auto switchesIt = payload->find("switches");
    if (switchesIt == payload->end() || !switchesIt->is_object())
    {
        return OvsLiveness::Unknown;
    }

    // Keyed by decimal string: JSON object keys cannot be numbers.
    const auto entryIt = switchesIt->find(std::to_string(dpid));
    if (entryIt == switchesIt->end() || !entryIt->is_object())
    {
        // The proxy does not know this switch. A disagreement between the topology file and the
        // proxy's switch table, not a dead switch.
        return OvsLiveness::Unknown;
    }

    const json& entry = *entryIt;

    // Three outcomes, not two, and the distinction decides a verdict.
    //
    // Absent or null is the proxy saying "nothing to report" -- expected, meaningful, and it must
    // not block a Down verdict, or a switch could never be reported dead until it had first been
    // seen alive. A *string where a number belongs* is something else entirely: the two processes
    // disagree about the schema. That is not evidence, it is a broken reading, and this policy's
    // whole premise is that a reading it cannot trust must not become "dead" -- a field rename on
    // the proxy side would otherwise black out the entire fabric.
    enum class Field
    {
        Value,
        Absent,
        Malformed
    };
    double value = 0.0;
    const auto read = [&entry, &value](const char* key) -> Field {
        const auto it = entry.find(key);
        if (it == entry.end() || it->is_null())
        {
            return Field::Absent;
        }
        if (!it->is_number())
        {
            return Field::Malformed;
        }
        value = it->get<double>();
        return Field::Value;
    };

    const auto probeOkIt = entry.find("probe_ok");
    if (probeOkIt == entry.end() || !probeOkIt->is_boolean())
    {
        // null until the proxy's first probe of this switch completes. Reporting Down here would
        // mark the whole fabric dead for the first seconds of every run.
        return OvsLiveness::Unknown;
    }

    if (probeOkIt->get<bool>())
    {
        // A P4Runtime RPC was round-tripped. The only signal that proves a bmv2 process is serving.
        return OvsLiveness::Up;
    }

    // A failure is only worth acting on if it is current. A stale result means the proxy's poller
    // stalled, which says nothing about the switch.
    switch (read("probe_age_s"))
    {
    case Field::Malformed:
        return OvsLiveness::Unknown;
    case Field::Value:
        if (value > kProbeStaleSeconds)
        {
            return OvsLiveness::Unknown;
        }
        break;
    case Field::Absent:
        break;
    }

    // Conflicting evidence. bmv2 answers control-plane RPCs whether or not its pipeline forwards,
    // and a loaded switch can miss an RPC deadline while forwarding perfectly well, so a fresh
    // beacon against a failed probe is a disagreement rather than a verdict.
    switch (read("last_lldp_age_s"))
    {
    case Field::Malformed:
        return OvsLiveness::Unknown;
    case Field::Value:
        if (value <= kLldpFreshSeconds)
        {
            return OvsLiveness::Unknown;
        }
        break;
    case Field::Absent:
        break;
    }

    return OvsLiveness::Down;
}

/** @brief Fetches the proxy's liveness evidence. See the header for why all failures collapse to
 *         nullopt.
 *
 * [Co-developed with claude code -- Adam]
 */
std::optional<json>
DeviceConfigurationAndPowerManager::fetchP4SwitchState()
{
    const std::string cmd = buildSwitchStateCommand(AppConfig::P4_PROXY_IP_AND_PORT);

    const auto fail = [this](const std::string& reason) -> std::optional<json> {
        if (m_switchStateFailures.recordFailure())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "cannot read bmv2 liveness from the proxy ({}); switch state is "
                               "left unchanged rather than reported as down",
                               reason);
        }
        return std::nullopt;
    };

    std::string response;
    try
    {
        response = utils::execCommand(cmd);
    }
    catch (const std::exception& e)
    {
        return fail(std::string("could not run curl: ") + e.what());
    }

    const auto lastNewline = response.find_last_of('\n');
    if (lastNewline == std::string::npos)
    {
        return fail(response.empty() ? "no response at all -- is the proxy running?"
                                     : "response had no status line");
    }

    const std::string statusText = response.substr(lastNewline + 1);
    const std::string body = response.substr(0, lastNewline);
    if (statusText != "200")
    {
        return fail("HTTP " + statusText);
    }

    json parsed;
    try
    {
        parsed = json::parse(body);
    }
    catch (const json::exception& e)
    {
        return fail(std::string("body did not parse: ") + e.what());
    }

    if (const auto failures = m_switchStateFailures.recordSuccess())
    {
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "bmv2 liveness readable again after {} failed attempt(s)",
                           *failures);
    }
    return parsed;
}

/** @brief A plausible synthetic power draw in mW for a simulated switch. See the header for why.
 *
 * [Co-developed with claude code -- Adam]
 */
uint64_t
DeviceConfigurationAndPowerManager::syntheticPowerMilliwattsFor(uint64_t dpid)
{
    // 30 W baseline plus up to 120 W, spanning what a real access-to-aggregation switch draws.
    constexpr uint64_t kBaselineMilliwatts = 30'000;
    constexpr uint64_t kSpanMilliwatts = 120'000;

    // The dpid is mixed explicitly rather than run through std::hash, which for integers is the
    // identity function on libstdc++: `std::hash<uint64_t>{}(dpid) % 120000` returns the dpid, so
    // all ten switches reported 30.0 W and differed only in single milliwatts. Caught by running
    // it, not by the unit tests, which saw ten "distinct" values and passed.
    //
    // This is splitmix64's finalizer -- well distributed, and fixed arithmetic rather than a
    // standard-library detail, so the figure is reproducible across platforms and runs.
    uint64_t mixed = dpid + 0x9E3779B97F4A7C15ULL;
    mixed = (mixed ^ (mixed >> 30)) * 0xBF58476D1CE4E5B9ULL;
    mixed = (mixed ^ (mixed >> 27)) * 0x94D049BB133111EBULL;
    mixed ^= mixed >> 31;

    return kBaselineMilliwatts + (mixed % kSpanMilliwatts);
}

/** @brief Renders pclose()'s wait status as something an operator can act on. See the header.
 *
 * [Co-developed with claude code -- Adam]
 */
std::string
DeviceConfigurationAndPowerManager::describeCommandStatus(int status)
{
    // Moved to utils:: when OVSPowerStrategy turned out to need the identical decoding -- it runs
    // the same `sudo ovs-vsctl` commands and was logging the raw wait status. Kept as a member so
    // the existing tests keep naming the class that motivated it.
    //
    // The command is named explicitly because the only caller is the `sudo ovs-vsctl list-br`
    // liveness probe. utils::describeCommandStatus no longer assumes that -- it was wrong for the
    // 13 snmpget/snmpwalk sites that reach it through execCommand.
    return utils::describeCommandStatus(status, "sudo ovs-vsctl list-br");
}

/** @brief Logs the first failure of a run of failures, and how many followed. See the header.
 *
 * [Co-developed with claude code -- Adam]
 */
void
DeviceConfigurationAndPowerManager::reportBridgeQueryFailure(const std::string& reason)
{
    if (m_bridgeQueryFailures.recordFailure())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "`ovs-vsctl list-br` failed ({}); OVS switch liveness is frozen at its "
                           "last known state until it succeeds again",
                           reason);
    }
}

/** @brief Closes the run opened by reportBridgeQueryFailure(), reporting how long it lasted.
 *
 * [Co-developed with claude code -- Adam]
 */
void
DeviceConfigurationAndPowerManager::reportBridgeQueryRecovered()
{
    if (const auto failures = m_bridgeQueryFailures.recordSuccess())
    {
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "`ovs-vsctl list-br` is working again after {} consecutive failures; "
                           "OVS switch liveness is being tracked again",
                           *failures);
    }
}

void
DeviceConfigurationAndPowerManager::pingWorker(int interval_sec = 1)
{
    while (m_running.load())
    {
        std::this_thread::sleep_for(std::chrono::seconds(interval_sec));

        Graph graph = m_topologyAndFlowMonitor->getGraph();
        auto [vi, vi_end] = boost::vertices(graph);

        // [Co-developed with claude code -- Adam]
        // std::optional, so "the query failed" is distinguishable from "there are no bridges".
        // It used to return an empty vector for both, and the loop below read that as every
        // switch being down -- so one dropped `ovs-vsctl` call (a sudo prompt on a detached
        // process, or a timeout under load) marked the whole fabric dead. Observed in practice.
        std::optional<std::vector<std::string>> listOvsBridges;
        if (m_mode == utils::DeploymentMode::MININET)
        {
            listOvsBridges = [&]() -> std::optional<std::vector<std::string>> {
                FILE* fp = popen("sudo ovs-vsctl list-br 2>/dev/null", "r");
                if (!fp)
                {
                    reportBridgeQueryFailure("could not run the command at all");
                    return std::nullopt;
                }

                std::vector<std::string> bridges;
                char buf[128];
                while (fgets(buf, sizeof(buf), fp))
                {
                    std::string line(buf);
                    // Trim trailing newline and whitespace
                    line.erase(line.find_last_not_of(" \n\r\t") + 1);
                    if (!line.empty())
                    {
                        bridges.push_back(line);
                    }
                }

                // The exit status was previously discarded, which is how a failing sudo looked
                // exactly like a healthy machine with no bridges.
                const int rc = pclose(fp);
                if (rc != 0)
                {
                    reportBridgeQueryFailure(describeCommandStatus(rc));
                    return std::nullopt;
                }
                reportBridgeQueryRecovered();
                return bridges;
            }();
        }

        // [Co-developed with claude code -- Adam]
        // Fetched once per tick, not once per switch: ten curl calls a second to the same endpoint
        // would be the same mistake as the log flood, just in network traffic. nullopt means no
        // evidence, and p4LivenessFor turns that into Unknown for every switch.
        //
        // Guarded on m_dataPlaneIsBmv2 so an OVS run never talks to a proxy that is not there --
        // the same conservatism as configureTopologyApiUrls.
        std::optional<json> p4SwitchState;
        if (m_mode == utils::DeploymentMode::MININET && m_dataPlaneIsBmv2)
        {
            p4SwitchState = fetchP4SwitchState();
        }

        for (; vi != vi_end; ++vi)
        {
            auto v = *vi;
            if (graph[v].vertexType == VertexType::SWITCH)
            {
                if (m_mode == utils::DeploymentMode::TESTBED)
                {
                    vector<uint32_t> ipVector = graph[v].ip;

                    for (uint32_t ip : ipVector)
                    {
                        bool alive = pingSwitch(utils::ipToString(ip), 5);
                        if (!alive)
                        {
                            SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                                "{} ping unreachable",
                                                graph[v].deviceName);
                            m_topologyAndFlowMonitor->setVertexDown(v);
                            m_topologyAndFlowMonitor->setVertexDisable(v);
                            // TODO: Emit switch failed event
                        }
                        else
                        {
                            m_topologyAndFlowMonitor->setVertexUp(v);
                            SPDLOG_LOGGER_TRACE(Logger::instance(),
                                                "{} ping reachable",
                                                graph[v].deviceName);
                        }
                    }
                }
                else
                {
                    std::string swName = graph[v].bridgeNameForMininet;
                    // [Co-developed with claude code -- Adam]
                    // Was gated on the topology *filename* containing "P4" (case
                    // sensitive), which is both fragile and the wrong question. Now keyed
                    // on the switch's own typed kind.
                    //
                    // A NOTE used to sit here saying bmv2 liveness "remains a stub that
                    // assumes bmv2 switches are always up" and that "the honest fix needs
                    // the proxy to expose that state, which it does not yet". Both halves
                    // were false by the time anyone could read them: the branch below calls
                    // p4LivenessFor, and the proxy does expose the state. The stub was
                    // replaced and the note describing it was not deleted, so the file
                    // contained two comments contradicting each other -- and the stale one
                    // was the more prominent, telling a reader to go and implement
                    // something already finished. Deleted rather than corrected, because
                    // the branch below documents what it does. Found by a review of this
                    // change; see doc/audit/2026-08-08_commit-review/power.md H2.
                    if (graph[v].switchKind == SwitchKind::BMV2)
                    {
                        // [Co-developed with claude code -- Adam]
                        // Was an unconditional setVertexUp with no evidence at all, so a switch
                        // that had been killed reported healthy again within one second. Now keyed
                        // on what the proxy actually observed: a round-tripped P4Runtime RPC, and
                        // LLDP freshness as corroboration. See p4LivenessFor for the policy.
                        switch (p4LivenessFor(graph[v].dpid, p4SwitchState))
                        {
                        case OvsLiveness::Up:
                            SPDLOG_LOGGER_DEBUG(Logger::instance(), "{} reachable", swName);
                            m_topologyAndFlowMonitor->setVertexUp(v);
                            break;
                        case OvsLiveness::Down:
                            SPDLOG_LOGGER_DEBUG(Logger::instance(), "{} unreachable", swName);
                            m_topologyAndFlowMonitor->setVertexDown(v);
                            break;
                        case OvsLiveness::Unknown:
                            // Same rule as the OVS branch: cannot tell, so do not touch the graph.
                            // The fetch failure is logged once by fetchP4SwitchState, not per
                            // switch -- ten identical warnings per second is how the last log
                            // flood happened.
                            break;
                        }
                    }
                    else
                    {
                        // [Co-developed with claude code -- Adam]
                        // Symmetric, and silent when the query failed. Previously this only ever
                        // called setVertexDown -- a switch found present was logged and left
                        // alone -- so "down" was permanent: nothing here could ever bring one
                        // back, and only Ryu re-announcing the switch (which happens on
                        // reconnect) would. Combined with a failed query being read as "all
                        // down", one blip took the whole graph down for the rest of the run,
                        // which is what made every node red in the Web GUI.
                        switch (ovsLivenessFor(swName, listOvsBridges))
                        {
                        case OvsLiveness::Up:
                            SPDLOG_LOGGER_DEBUG(Logger::instance(), "{} reachable", swName);
                            m_topologyAndFlowMonitor->setVertexUp(v);
                            break;
                        case OvsLiveness::Down:
                            SPDLOG_LOGGER_DEBUG(Logger::instance(), "{} unreachable", swName);
                            m_topologyAndFlowMonitor->setVertexDown(v);
                            // TODO: Emit switch failed event
                            break;
                        case OvsLiveness::Unknown:
                            // Cannot tell, so say nothing. Reporting "dead" here is the whole
                            // bug; the warning is emitted once by the query itself, not per
                            // switch.
                            break;
                        }
                    }
                }
            }
            // Hosts are deliberately not touched here.
            //
            // [Co-developed with claude code -- Adam]
            // There used to be a branch that force-marked every host up whenever the fabric was
            // bmv2. Its stated reason -- "the P4 proxy has no host feed yet" -- had stopped being
            // true: the proxy serves `/v1.0/topology/hosts` through ryu_topology.render_hosts,
            // which emits a MAC and a non-empty `ipv4`, and that is exactly what
            // TopologyAndFlowMonitor::updateHosts needs to set a host up.
            //
            // Keeping it would have been worse than redundant. A host is up if it answers, and
            // nothing here asks it anything; the branch asserted liveness for a machine it had
            // never contacted. It would also have masked the failure it was covering for: if the
            // proxy's MAC formatting ever stopped matching findVertexByMac, host discovery would be
            // broken and every host would still read as up.
            //
            // Before it was an outright fabrication: it was gated on the topology *filename*
            // containing "P4" and sat outside the TESTBED/else split, so a stray NDTWIN_TOPO_FILE
            // in the environment marked hosts up in TESTBED mode too -- where ping-based liveness
            // is the entire point of the mode.
        }
    }
}

std::string
DeviceConfigurationAndPowerManager::buildRelayPowerCommand(const std::string& gwUrl,
                                                           const SwitchInfo& si,
                                                           const std::string& action)
{
    // [Co-developed with claude code -- Adam]
    // --max-time bounds an unresponsive gateway (this runs inside a request handler), and
    // -w appends the HTTP status on its own line, which is what interpretRelayResponse reads its
    // verdict from. Neither was on the request this replaces: it was a bare `curl -s`, whose exit
    // status is 0 for a 500 as readily as for a 200.
    //
    // resource=outlet is carried over deliberately. The unreachable overload this logic came from
    // had dropped it, so adopting that code as-is would have quietly changed the request the
    // testbed's gateway receives. The power report hits the same endpoint with the same three
    // parameters, and it is the only working example of this API in the repo.
    std::ostringstream cmd;
    cmd << "curl -s --max-time 8 -w '\\n%{http_code}' -X POST "
        << "\"http://" << gwUrl << ":8000/relay"
        << "?ip=" << si.plugIp
        << "&resource=outlet"
        << "&index=" << si.plugIdx
        << "&method=" << action << "\"";
    return cmd.str();
}

/** @brief Builds the P4 liveness request. See the header for why this is a separate function. */
std::string
DeviceConfigurationAndPowerManager::buildSwitchStateCommand(const std::string& proxyIpAndPort)
{
    // -w writes the status after the body so a non-2xx is distinguishable from an empty 200, and
    // --max-time bounds a hung proxy: this runs inside the 1 Hz ping loop.
    return "curl -s --max-time 3 -w '\\n%{http_code}' http://" + proxyIpAndPort +
           "/p4/switch_state 2>/dev/null";
}

/** @brief Builds the flow-table request. See the header for why this is a separate function. */
std::string
DeviceConfigurationAndPowerManager::buildFlowStatsCommand(const std::string& ipAndPort,
                                                          uint64_t dpid)
{
    // [Co-developed with claude code -- Adam]
    // --max-time, for the same reason the liveness fetch carries one: it bounds a hung control
    // plane. This was the last bare `curl -s` in this file. 8 s rather than the liveness poll's
    // 3 s -- see the header for why the looser bound is the right trade here.
    return fmt::format("curl -s --max-time 8 -X GET http://{}/stats/flow/{}", ipAndPort, dpid);
}

/** @brief Reads the smart-plug gateway's reply. See the header for why this is a separate function.
 *
 * [Co-developed with claude code -- Adam]
 */
DeviceConfigurationAndPowerManager::RelayResult
DeviceConfigurationAndPowerManager::interpretRelayResponse(const std::string& response)
{
    if (response.empty())
    {
        return {false, "no response at all -- is the gateway reachable?"};
    }

    const auto lastNewline = response.find_last_of('\n');
    if (lastNewline == std::string::npos)
    {
        // curl always appends the status on its own line, so this means the output was truncated or
        // came from something other than the command we built.
        return {false, "response carried no HTTP status line"};
    }

    const std::string statusCode = response.substr(lastNewline + 1);
    const std::string body = response.substr(0, lastNewline);

    if (statusCode == "000")
    {
        // curl's own code for "never got a response": connection refused, DNS failure, timeout.
        return {false, "could not reach the gateway (curl reported no HTTP response)"};
    }
    if (statusCode.size() != 3 || statusCode[0] != '2')
    {
        return {false, "HTTP " + statusCode};
    }

    // Accepted. Pull the status text out of the HTML for the log -- between the second '>' and the
    // next '<', which is where this gateway puts it. Only ever reported, never used as the verdict:
    // the page can be redesigned, the status code cannot.
    std::string text = body;
    if (auto p1 = body.find('>'); p1 != std::string::npos)
    {
        if (auto p2 = body.find('>', p1 + 1); p2 != std::string::npos)
        {
            if (auto p3 = body.find('<', p2 + 1); p3 != std::string::npos && p3 > p2 + 1)
            {
                text = body.substr(p2 + 1, p3 - p2 - 1);
            }
        }
    }
    return {true, text};
}

json
DeviceConfigurationAndPowerManager::fetchMemoryReportInternal()
{
    nlohmann::json result_json;
    Graph graph = m_topologyAndFlowMonitor->getGraph();

    for (auto v : boost::make_iterator_range(vertices(graph)))
    {
        const auto& vp = graph[v];
        if (vp.vertexType != VertexType::SWITCH)
        {
            continue;
        }

        std::string ip_str = utils::ipToString(vp.ip.front());

        // [Co-developed with claude code -- Adam]
        // A switch that is down gets the documented sentinel, not a missing key.
        //
        // `continue` here dropped the entry entirely, so a powered-off switch simply vanished from
        // the response -- and the Web-GUI's `data[ip] || 0` then rendered it as **0%**, which reads
        // as an idle switch rather than a dead one. That is the worst available answer: it is
        // exactly the state the Energy-Saving App is looking for.
        //
        // -1 is not invented here. This file already initialises these values to -1 for the SNMP
        // failure path, the API document says "A value of -1 means SNMP query failed or data is
        // unavailable", and Web-GUI/src/components/DeviceInformation.tsx has had a
        // `=== -1 ? unavailable` branch for all three endpoints all along. The sentinel was
        // documented and consumed at both ends and produced by neither -- for a down switch the
        // `continue` above always fired first. Found 2026-08-18.
        //
        // Non-switch vertices stay omitted: a host has no memory figure to report and never had a key here.
        if (!vp.isUp)
        {
            result_json[ip_str] = -1;
            continue;
        }

        int memory = -1;

        if (m_mode == utils::DeploymentMode::MININET)
        {
            // dummy between 10 and 59
            memory = 10 + (std::hash<std::string>{}(ip_str) % 50);
        }
        else if (vp.brandName == "HPE5520")
        {
            auto cmd = fmt::format("snmpget -v2c -c public {} 1.3.6.1.4.1.25506.2.6.1.1.1.1.8.212",
                                   ip_str);
            std::string snmp_result = utils::execCommand(cmd);

            static const std::regex re(R"(INTEGER:\s*(\d+))");
            std::smatch match;
            if (std::regex_search(snmp_result, match, re))
            {
                memory = std::stoi(match[1]);
            }
        }
        else
        {
            auto cmd =
                fmt::format("snmpget -v2c -c public {} 1.3.6.1.4.1.1991.1.1.2.1.53.0", ip_str);

            std::string snmp_result = utils::execCommand(cmd);

            std::smatch match;
            static const std::regex regex(R"(Gauge32:\s*(\d+))");
            if (std::regex_search(snmp_result, match, regex))
            {
                memory = std::stoi(match[1]);
            }
        }

        result_json[ip_str] = memory;
    }

    return result_json;
}

// [Co-developed with claude code -- Adam]
DeviceConfigurationAndPowerManager::FlowStatsVerdict
DeviceConfigurationAndPowerManager::classifyFlowStatsReply(const nlohmann::json& flows,
                                                           double elapsedSeconds)
{
    // Before the entry scan, not after: an {"error": ...} body must never count as "no entries,
    // fast, therefore usable" -- failing is faster than timing out, which is exactly how it slid
    // past the latency guard. See the header comment. [Co-developed with claude code -- Adam]
    if (flows.is_object() && (flows.contains("error") || flows.contains("detail")))
    {
        return FlowStatsVerdict::ReportedFailure;
    }

    // Any entry at all makes this a real observation. Checked first and unconditionally, so a large
    // table that legitimately took a second is never discarded.
    if (flows.is_object())
    {
        for (const auto& entry : flows.items())
        {
            if (entry.value().is_array() && !entry.value().empty())
            {
                return FlowStatsVerdict::Usable;
            }
        }
    }
    else if (flows.is_array() && !flows.empty())
    {
        // The P4 proxy's shape. Same rule.
        return FlowStatsVerdict::Usable;
    }

    // Nothing anywhere. Believe it only if it arrived too fast to be Ryu's timeout.
    return (elapsedSeconds >= kFlowStatsSuspectSeconds) ? FlowStatsVerdict::SuspectTimedOut
                                                        : FlowStatsVerdict::Usable;
}

json
DeviceConfigurationAndPowerManager::fetchOpenFlowTablesInternal()
{
    nlohmann::json result = nlohmann::json::array();
    auto graph = m_topologyAndFlowMonitor->getGraph();

    for (auto v : boost::make_iterator_range(vertices(graph)))
    {
        const auto& props = graph[v];
        if (props.vertexType != VertexType::SWITCH || props.isUp == false)
        {
            continue;
        }

        uint64_t dpid = props.dpid;
        // [Co-developed with claude code -- Adam]
        // Typed kind rather than a brand-name string compare: a topology that spelled it
        // "bmv2" or "BMV2" previously polled Ryu for a bmv2 switch and got nothing back.
        std::string ip_and_port = (props.switchKind == SwitchKind::BMV2)
                                      ? AppConfig::P4_PROXY_IP_AND_PORT
                                      : AppConfig::RYU_IP_AND_PORT;

        std::string cmd = buildFlowStatsCommand(ip_and_port, dpid);

        // TRACE, not INFO: one line per switch per poll, and the TRACE line just below already
        // reports the same request together with its response, which is the useful half.
        // [Co-developed with claude code -- Adam]
        SPDLOG_LOGGER_TRACE(spdlog::default_logger(),
                            "DeviceManager: querying switch {} -> `{}`",
                            dpid,
                            cmd);

        // [Co-developed with claude code -- Adam]
        // Timed, because the round trip is the only thing separating "this switch has no rules"
        // from "Ryu waited out its 1 s stats timeout and gave up". See classifyFlowStatsReply.
        const auto requestStart = std::chrono::steady_clock::now();
        std::string raw = utils::execCommand(cmd);
        const double elapsedSeconds =
            std::chrono::duration<double>(std::chrono::steady_clock::now() - requestStart).count();
        SPDLOG_LOGGER_TRACE(spdlog::default_logger(),
                            "DeviceManager: raw response for {}: {}",
                            dpid,
                            raw);

        // [Co-developed with claude code -- Adam]
        // An empty body is not malformed JSON, it is an absent control plane -- curl printing
        // nothing because the connection was refused. Feeding it to the parser produced
        // "[error] JSON parsing failed: attempting to parse an empty input" once per switch per
        // poll: measured at **216 error lines** during a four-minute proxy outage, none of them
        // allowlisted, so the log check would fail on a condition that is already reported
        // properly one line at a time by the liveness fetch.
        //
        // Edge-triggered and keyed on nothing, because the whole control plane is either reachable
        // or it is not; per-dpid runs would be ten simultaneous reports of one fault.
        if (raw.empty())
        {
            if (m_flowStatsFetchFailures.recordFailure())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "no flow-table response from {} (switch {} and possibly others); "
                                   "tables are left as they were",
                                   ip_and_port,
                                   dpid);
            }
            continue;
        }
        if (const auto failures = m_flowStatsFetchFailures.recordSuccess())
        {
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "flow tables readable again after {} empty response(s)",
                               *failures);
        }

        // Still an error, and still worth one: a *non-empty* body that will not parse means the
        // control plane answered with something unexpected, which no other check would catch.
        const auto parsed = parseFlowStatsTextToJson(raw);
        if (!parsed)
        {
            // [Co-developed with claude code -- Adam]
            // A body that will not parse is not a report of an empty table. Keeping the previous
            // table is the same conservative choice the timeout path makes, and for the same
            // reason: stale data that was once true beats a confident claim that is false now.
            // The parse error itself is already logged one line up.
            if (m_flowStatsTimeouts.recordFailure())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "{} sent an unparseable flow table for switch {} -- keeping the "
                                   "previous table rather than treating it as a switch with no "
                                   "rules",
                                   ip_and_port,
                                   dpid);
            }
            continue;
        }
        const nlohmann::json& flows = *parsed;

        // [Co-developed with claude code -- Adam]
        // Why this check exists, measured 2026-08-07: with Ryu wedged the kernel reported all ten
        // switches as holding zero flow rules while s1 actually held 130 and the fabric was
        // forwarding normally -- and every liveness indicator stayed green (288/288 edges, 138/138
        // nodes), so nothing suggested distrusting it. Applying that empty table is what blanked
        // every flow's path.
        //
        // Skipping leaves the previous table in place, the conservative direction: stale data that
        // was once true beats a confident claim that is false now.
        const auto verdict = classifyFlowStatsReply(flows, elapsedSeconds);
        if (verdict == FlowStatsVerdict::ReportedFailure)
        {
            // The proxy answered "I could not read this switch" ({"error": ...}, HTTP 503 -- but
            // curl -s never shows the status, so the body is the signal). Same conservative
            // treatment as the other three skip paths: the previous table stays.
            // [Co-developed with claude code -- Adam]
            if (m_flowStatsTimeouts.recordFailure())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "{} reported a read failure for switch {} ({}) -- keeping the "
                                   "previous table rather than treating it as a switch with no "
                                   "rules",
                                   ip_and_port,
                                   dpid,
                                   flows.dump());
            }
            continue;
        }
        if (verdict == FlowStatsVerdict::SuspectTimedOut)
        {
            if (m_flowStatsTimeouts.recordFailure())
            {
                SPDLOG_LOGGER_WARN(
                    Logger::instance(),
                    "{} returned an empty flow table for switch {} after {:.3f}s, at or beyond its "
                    "{:.1f}s suspicion threshold -- treating it as a lost reply, not as a switch "
                    "with no rules. Keeping the previous table. Check whether the controller has "
                    "stopped reading its switch connections.",
                    ip_and_port,
                    dpid,
                    elapsedSeconds,
                    kFlowStatsSuspectSeconds);
            }
            continue;
        }
        if (const auto timeouts = m_flowStatsTimeouts.recordSuccess())
        {
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "flow tables are being answered again after {} timed-out reply(ies)",
                               *timeouts);
        }

        result.push_back({{"dpid", dpid}, {"flows", flows}});

        // TODO: Test Classifier
        m_classifier->updateFromQueriedTables(result);
    }

    return result;
}

std::optional<json>
DeviceConfigurationAndPowerManager::parseFlowStatsTextToJson(const std::string& responseText) const
{
    try
    {
        return json::parse(responseText);
    }
    catch (const std::exception& e)
    {
        // [Co-developed with claude code -- Adam]
        // nullopt, not json::array(). Returning an empty array here made "the control plane sent
        // something that is not JSON" identical to "this switch has no rules", and applying the
        // latter sweeps every rule for the dpid. See the declaration for the full story.
        SPDLOG_LOGGER_ERROR(Logger::instance(), "JSON parsing failed: {}", e.what());
        return std::nullopt;
    }
}

// static bool
// is_digits(const std::string& s)
// {
//     return !s.empty() &&
//            std::all_of(s.begin(), s.end(), [](unsigned char c) { return std::isdigit(c); });
// }

// static bool
// parseIpv4WithMask(const std::string& s, uint32_t& net, uint32_t& mask)
// {
//     std::string ipPart = s;
//     std::string maskPart;

//     if (auto slash = s.find('/'); slash != std::string::npos)
//     {
//         ipPart = s.substr(0, slash);
//         maskPart = s.substr(slash + 1);
//     }

//     // default: /32
//     mask = 0xFFFFFFFFu;

//     try
//     {
//         uint32_t ip = utils::ipStringToUint32(ipPart);

//         if (!maskPart.empty())
//         {
//             if (maskPart.find('.') != std::string::npos)
//             {
//                 // dotted mask: 255.255.255.0
//                 mask = utils::ipStringToUint32(maskPart);
//             }
//             else if (is_digits(maskPart))
//             {
//                 // prefix mask: 24
//                 int p = std::stoi(maskPart);
//                 if (p < 0 || p > 32)
//                 {
//                     return false;
//                 }
//                 if (p == 0)
//                 {
//                     mask = 0u;
//                 }
//                 else
//                 {
//                     mask = 0xFFFFFFFFu << (32 - p); // safe because p!=0
//                 }
//             }
//             else
//             {
//                 return false;
//             }
//         }

//         net = ip & mask; // store the network part
//         return true;
//     }
//     catch (...)
//     {
//         return false;
//     }
// }

json
DeviceConfigurationAndPowerManager::fetchPowerReportInternal()
{
    nlohmann::json result = nlohmann::json::array();

    auto graph = m_topologyAndFlowMonitor->getGraph();
    for (auto v : boost::make_iterator_range(vertices(graph)))
    {
        const auto& props = graph[v];
        uint64_t dpid = props.dpid;
        uint64_t power_mW = 0;
        if (props.vertexType != VertexType::SWITCH)
        {
            continue;
        }
        else if (!props.isUp)
        {
            result.push_back({{"dpid", dpid}, {"power_consumed", 0}});
            continue;
        }

        if (m_mode == utils::DeploymentMode::MININET)
        {
            power_mW = syntheticPowerMilliwattsFor(dpid);
        }
        else if (m_mode == utils::DeploymentMode::TESTBED)
        {
            const std::string username = "admin";
            std::string ip_str = utils::ipToString(props.ip.front());

            SPDLOG_INFO("Getting power report from DPID {} at IP {}", dpid, ip_str);

            // hpe switch
            if (props.brandName == "HPE5520")
            {
                auto cmd =
                    fmt::format("snmpwalk -v2c -c public {} 1.3.6.1.4.1.25506.8.35.9.1.1.1.6",
                                ip_str);
                std::string snmp_result = utils::execCommand(cmd);

                static const std::regex re(R"(INTEGER:\s*(\d+))");
                std::smatch match;
                if (std::regex_search(snmp_result, match, re))
                {
                    power_mW = std::stoi(match[1]);
                }
                SPDLOG_DEBUG("Get HPE switch power ip{} power{}", ip_str, power_mW);
            }
            // brocade
            else
            {
                std::string raw = getPowerReportViaSsh(ip_str, username);
                power_mW = parsePowerOutput(raw);
                if (power_mW == 0 && !raw.empty())
                {
                    SPDLOG_WARN("Could not parse power value from raw: {}", raw);
                }
                else if (raw.empty())
                {
                    SPDLOG_WARN("Empty SSH output for {}", ip_str);
                }

                SPDLOG_DEBUG("Brocade Switch Raw SSH output for {}: {}", ip_str, raw);
            }
        }

        result.push_back({{"dpid", dpid}, {"power_consumed", power_mW}});
    }

    return result;
}

bool
DeviceConfigurationAndPowerManager::setSwitchPowerState(const std::string& ip,
                                                        const std::string& action)
{
    if (m_mode == utils::DeploymentMode::TESTBED)
    {
        // find the SwitchInfo entry
        auto it = std::find_if(switchSmartPlugTable.begin(),
                               switchSmartPlugTable.end(),
                               [&](const auto& si) { return si.switchIp == ip; });
        if (it == switchSmartPlugTable.end())
        {
            SPDLOG_LOGGER_DEBUG(Logger::instance(), "switch not found {}", ip);
            return false;
        }

        return setPowerStateTestbed(*it, action);
    }
    else if (m_mode == utils::DeploymentMode::MININET)
    {
        // convert IP to uint and find vertex
        uint32_t ipUint = utils::ipStringToUint32(ip);
        return setPowerStateMininet(ipUint, action);
    }
    return false;
}

bool
DeviceConfigurationAndPowerManager::setPowerStateTestbed(const SwitchInfo& si,
                                                         const std::string& action)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "TESTBED: setting switch {} -> {}", si.switchIp, action);

    // [Co-developed with claude code -- Adam]
    // This function used to be `std::system(bare curl); return rc == 0;`. curl exits 0 for any
    // HTTP response it managed to receive, so a gateway answering 500 -- or 401, or an error
    // page -- was reported to the caller as Success, and the endpoint returned
    // {"<ip>": "Success"} for a switch whose power had not changed. On TESTBED the switches are
    // real, which is the whole reason this path is the one that must not guess.
    //
    // The honest version of this existed already, in an overload with zero call sites. It has
    // been moved here rather than called from here, because it is only honest where it runs.
    if (action != "on" && action != "off")
    {
        // Reachable: `action` is a free-text query parameter on /ndt/set_switches_power_state.
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "unrecognised power action '{}' for {}; nothing was changed",
                           action,
                           si.switchIp);
        return false;
    }

    try
    {
        const RelayResult relay =
            interpretRelayResponse(utils::execCommand(buildRelayPowerCommand(GW_IP, si, action)));

        if (!relay.ok)
        {
            // Deliberately does NOT touch the graph. Marking a switch off because we *asked* for
            // it to go off, when the request failed, is the twin stating something about the
            // network that nobody established -- and the switch is real and still forwarding.
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "power {} for {} (plug {}:{}) was not accepted: {}; the graph is "
                               "left as it was",
                               action,
                               si.switchIp,
                               si.plugIp,
                               si.plugIdx,
                               relay.detail);
            return false;
        }

        const auto nodeOpt =
            m_topologyAndFlowMonitor->findSwitchByIp(utils::ipStringToUint32(si.switchIp));
        if (!nodeOpt)
        {
            // The gateway did switch the plug, but the graph has no vertex for it, so the twin
            // and the network now disagree and this call cannot claim success.
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "cannot find graph vertex for switch IP {}; the plug was switched "
                               "{} but the graph does not reflect it",
                               si.switchIp,
                               action);
            return false;
        }

        if (action == "on")
        {
            m_topologyAndFlowMonitor->setVertexUp(*nodeOpt);
        }
        else
        {
            m_topologyAndFlowMonitor->setVertexDown(*nodeOpt);
        }

        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "set graph attributes for {} -> {} (gateway returned \"{}\")",
                           si.switchIp,
                           action,
                           relay.detail);
        return true;
    }
    catch (const std::exception& e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "TESTBED power {}: {}", si.switchIp, e.what());
        return false;
    }
}

bool
DeviceConfigurationAndPowerManager::setPowerStateMininet(uint32_t ipUint, const std::string& action)
{
    auto nodeOpt = m_topologyAndFlowMonitor->findSwitchByIp(ipUint);
    if (!nodeOpt)
    {
        return false;
    }
    else
    {
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "ipUint {}", utils::ipToString(ipUint));
    }

    auto g = m_topologyAndFlowMonitor->getGraph();
    auto node = nodeOpt.value();
    const std::string swName = g[node].bridgeNameForMininet;
    auto dpid = g[node].dpid;

    SPDLOG_LOGGER_DEBUG(Logger::instance(), "swName {}", swName);

    // [Co-developed with claude code -- Adam]
    IPowerStrategy* strategy = getPowerStrategyForDpid(dpid);
    if (strategy == nullptr)
    {
        return false;
    }

    // The strategies' return value was previously discarded, and an action that was neither
    // "on" nor "off" fell through both branches yet still logged success and returned true.
    // Now an OpResult, so the reason a power change failed survives to the log.
    OpResult result = OpResult::failure(400, "no power action performed");
    if (action == "on")
    {
        result = strategy->powerOn(node, swName, dpid, m_topologyAndFlowMonitor.get());
    }
    else if (action == "off")
    {
        result = strategy->powerOff(node, swName, m_topologyAndFlowMonitor.get());
    }
    else
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "Unrecognised power action '{}' for switch {}; expected 'on' "
                            "or 'off'",
                            action,
                            swName);
        return false;
    }

    if (!result.ok)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "MININET: switch {} -> {} failed on the {} data plane: {}",
                           swName,
                           action,
                           strategy->describe(),
                           result.message);
        return false;
    }

    SPDLOG_INFO("MININET: switch {} -> {}", swName, action);
    return true;
}

json
DeviceConfigurationAndPowerManager::fetchCpuReportInternal()
{
    nlohmann::json result;
    auto graph = m_topologyAndFlowMonitor->getGraph();

    for (auto v : boost::make_iterator_range(vertices(graph)))
    {
        const auto& vp = graph[v];
        if (vp.vertexType != VertexType::SWITCH)
        {
            continue;
        }

        std::string ip_str = utils::ipToString(vp.ip.front());

        // [Co-developed with claude code -- Adam]
        // A switch that is down gets the documented sentinel, not a missing key.
        //
        // `continue` here dropped the entry entirely, so a powered-off switch simply vanished from
        // the response -- and the Web-GUI's `data[ip] || 0` then rendered it as **0%**, which reads
        // as an idle switch rather than a dead one. That is the worst available answer: it is
        // exactly the state the Energy-Saving App is looking for.
        //
        // -1 is not invented here. This file already initialises these values to -1 for the SNMP
        // failure path, the API document says "A value of -1 means SNMP query failed or data is
        // unavailable", and Web-GUI/src/components/DeviceInformation.tsx has had a
        // `=== -1 ? unavailable` branch for all three endpoints all along. The sentinel was
        // documented and consumed at both ends and produced by neither -- for a down switch the
        // `continue` above always fired first. Found 2026-08-18.
        //
        // Non-switch vertices stay omitted: a host has no CPU to report and never had a key here.
        if (!vp.isUp)
        {
            result[ip_str] = -1;
            continue;
        }

        int cpu = -1;

        if (m_mode == utils::DeploymentMode::MININET)
        {
            // dummy: 10–59
            cpu = 10 + (std::hash<std::string>{}(ip_str) % 50);
        }
        else if (vp.brandName == "HPE5520")
        {
            auto cmd = fmt::format("snmpget -v2c -c public {} 1.3.6.1.4.1.25506.2.6.1.1.1.1.6.212",
                                   ip_str);
            std::string snmp_result = utils::execCommand(cmd);

            static const std::regex re(R"(INTEGER:\s*(\d+))");
            std::smatch match;
            if (std::regex_search(snmp_result, match, re))
            {
                cpu = std::stoi(match[1]);
            }
        }
        else
        {
            // SNMP OID for CPU (Brocade ICX 7250)
            auto cmd =
                fmt::format("snmpget -v2c -c public {} 1.3.6.1.4.1.1991.1.1.2.1.52.0", ip_str);
            std::string snmp_result = utils::execCommand(cmd);

            static const std::regex re(R"(Gauge32:\s*(\d+))");
            std::smatch match;
            if (std::regex_search(snmp_result, match, re))
            {
                cpu = std::stoi(match[1]);
            }
        }

        result[ip_str] = cpu;
    }

    return result;
}

json
DeviceConfigurationAndPowerManager::fetchTemperatureReportInternal()
{
    nlohmann::json result;
    auto graph = m_topologyAndFlowMonitor->getGraph();

    for (auto v : boost::make_iterator_range(vertices(graph)))
    {
        const auto& vp = graph[v];

        std::string ip_str = utils::ipToString(vp.ip.front());
        if (vp.vertexType != VertexType::SWITCH)
        {
            continue;
        }
        else if (!vp.isUp)
        {
            // [Co-developed with claude code -- Adam]
            // -1, matching CPU and memory. This used to answer the string "The switch is down.",
            // which made three sibling endpoints say the same thing three different ways and put
            // an int and a string under the same key in one JSON object -- `data[ip] + 0` on the
            // client works until a switch goes down.
            //
            // Ironically this string was the only one of the three a user could read: the
            // Web-GUI's temperature branch falls through to `value || unavailable` and printed it,
            // while CPU and memory silently rendered 0%. Both now take the -1 branch that
            // component has always had.
            result[ip_str] = -1;
            continue;
        }
        else if (vp.brandName != "HPE5520" && m_mode != utils::DeploymentMode::MININET)
        {
            result[ip_str] = "The temperature function only supports the HPE 5520.";
            continue;
        }

        int temp = -1; // Temperature in Celsius

        if (m_mode == utils::DeploymentMode::MININET)
        {
            // Dummy value for Mininet simulation: 25–49°C
            temp = 25 + (std::hash<std::string>{}(ip_str) % 25);
        }
        else
        {
            auto cmd = fmt::format("snmpget -v2c -c public {} 1.3.6.1.4.1.25506.2.6.1.1.1.1.12.212",
                                   ip_str);
            std::string snmp_result = utils::execCommand(cmd);

            // The regex for parsing an INTEGER response
            static const std::regex re(R"(INTEGER:\s*(\d+))");
            std::smatch match;
            if (std::regex_search(snmp_result, match, re))
            {
                temp = std::stoi(match[1]);
            }
        }

        result[ip_str] = temp;
    }

    return result;
}

void
DeviceConfigurationAndPowerManager::fetchSmartPlugInfoFromFile(const std::string& path)
{
    std::ifstream file(path);
    if (!file.is_open())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Error: Cannot open topology file:  {}", path);
        return;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Load Static Topology File from {}", path);

    json j;
    file >> j;

    // Add nodes
    for (const auto& nodeJson : j["nodes"])
    {
        // VertexProperties vp = nodeJson.get<VertexProperties>();
        // Custom extraction (like from_json function)
        VertexProperties vp;
        vp.vertexType = static_cast<VertexType>(nodeJson.at("vertex_type").get<int>());
        vp.ip = utils::ipStringVecToUint32Vec(nodeJson.at("ip").get<std::vector<std::string>>());

        if (vp.vertexType == VertexType::SWITCH and m_mode == utils::DeploymentMode::TESTBED)
        {
            if (vp.ip.empty())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(), "vertex has no ip");
                continue;
            }
            string swIpStr = utils::ipToString(vp.ip.front());
            string smartPlugIpStr = nodeJson.at("smart_plug_ip").get<std::string>();
            int smartPlugOutLet = nodeJson.at("smart_plug_outlet").get<int>();
            switchSmartPlugTable.emplace_back(swIpStr, smartPlugIpStr, smartPlugOutLet);
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "Load Smart Plug Info {} {} {}",
                               swIpStr,
                               smartPlugIpStr,
                               smartPlugOutLet);
        }
    }
}

nlohmann::json
DeviceConfigurationAndPowerManager::getSingleSwitchPowerReport(const std::string& deviceIdentifier)
{
    auto graph = m_topologyAndFlowMonitor->getGraph();

    // Helper lambda to calculate power for a single switch's properties.
    auto calculate_power_for_switch = [&](const auto& props,
                                          const std::string& ip_str) -> uint64_t {
        uint64_t power_mW = 0;
        if (m_mode == utils::DeploymentMode::MININET)
        {
            power_mW = syntheticPowerMilliwattsFor(props.dpid);
        }
        else if (m_mode == utils::DeploymentMode::TESTBED)
        {
            const std::string username = "admin";
            SPDLOG_INFO("Getting power report from DPID {} at IP {}", props.dpid, ip_str);

            if (props.brandName == "HPE5520")
            {
                // HPE switch (SNMP)
                auto cmd =
                    fmt::format("snmpwalk -v2c -c public {} 1.3.6.1.4.1.25506.8.35.9.1.1.1.6",
                                ip_str);
                std::string snmp_result = utils::execCommand(cmd);

                static const std::regex re(R"(INTEGER:\s*(\d+))");
                std::smatch match;
                if (std::regex_search(snmp_result, match, re))
                {
                    power_mW = std::stoi(match[1]);
                }
                SPDLOG_DEBUG("Get HPE switch power ip{} power{}", ip_str, power_mW);
            }
            else
            {
                // Brocade / Others (Currently via SSH)
                // TODO: Change to SNMP if OID is known
                std::string raw = getPowerReportViaSsh(ip_str, username);
                power_mW = parsePowerOutput(raw);
                if (power_mW == 0 && !raw.empty())
                {
                    SPDLOG_WARN("Could not parse power value from raw: {}", raw);
                }
                else if (raw.empty())
                {
                    SPDLOG_WARN("Empty SSH output for {}", ip_str);
                }
                SPDLOG_DEBUG("Brocade Switch Raw SSH output for {}: {}", ip_str, raw);
            }
        }
        return power_mW;
    };

    std::optional<Graph::vertex_descriptor> foundVertex;

    uint32_t ip_val = utils::ipStringToUint32(deviceIdentifier);

    foundVertex = m_topologyAndFlowMonitor->findSwitchByIp(ip_val);

    // If a switch was found by either method, calculate and return its power.
    if (foundVertex)
    {
        const auto& props = graph[*foundVertex];
        std::string ip_str = utils::ipToString(props.ip.front());

        uint64_t power_mW = calculate_power_for_switch(props, ip_str);

        return {{"dpid", props.dpid}, {"power_consumed", power_mW}};
    }

    // If the device was not found, return an empty object.
    SPDLOG_WARN("Could not find switch with identifier: {}", deviceIdentifier);
    return nlohmann::json();
}

// In DeviceConfigurationAndPowerManager.cpp

json
DeviceConfigurationAndPowerManager::getSingleSwitchCpuReport(const std::string& deviceIdentifier)
{
    nlohmann::json result;
    auto graph = m_topologyAndFlowMonitor->getGraph();
    int cpu = -1;

    // --- FIX 1: Use a pointer instead of std::optional<T&> ---
    // A null pointer will mean the switch was not found.
    const VertexProperties* targetSwitch = nullptr;

    for (auto v : boost::make_iterator_range(vertices(graph)))
    {
        const auto& vp = graph[v];
        if (vp.vertexType == VertexType::SWITCH &&
            utils::ipToString(vp.ip.front()) == deviceIdentifier)
        {
            // --- FIX 2: Assign the address of the object to the pointer ---
            targetSwitch = &vp;
            break;
        }
    }

    // --- FIX 3: Check against nullptr instead of .has_value() ---
    if (!targetSwitch)
    {
        result[deviceIdentifier] = "Switch not found in topology";
        return result;
    }

    // The -> operator now works correctly with a pointer.
    if (!targetSwitch->isUp)
    {
        result[deviceIdentifier] = "Switch is currently down";
        return result;
    }

    // The rest of your logic remains the same...
    if (m_mode == utils::DeploymentMode::MININET)
    {
        cpu = 10 + (std::hash<std::string>{}(deviceIdentifier) % 50);
    }
    else if (targetSwitch->brandName == "HPE5520")
    {
        auto cmd = fmt::format("snmpget -v2c -c public {} 1.3.6.1.4.1.25506.2.6.1.1.1.1.6.212",
                               deviceIdentifier);
        std::string snmp_result = utils::execCommand(cmd);
        static const std::regex re(R"(INTEGER:\s*(\d+))");
        std::smatch match;
        if (std::regex_search(snmp_result, match, re))
        {
            cpu = std::stoi(match[1]);
        }
    }
    else
    {
        auto cmd = fmt::format("snmpget -v2c -c public {} 1.3.6.1.4.1.1991.1.1.2.1.52.0",
                               deviceIdentifier);
        std::string snmp_result = utils::execCommand(cmd);
        static const std::regex re(R"(Gauge32:\s*(\d+))");
        std::smatch match;
        if (std::regex_search(snmp_result, match, re))
        {
            cpu = std::stoi(match[1]);
        }
    }
    return {{"dpid", targetSwitch->dpid}, {"cpu_usage", cpu}};
}

void
DeviceConfigurationAndPowerManager::statusUpdateWorker()
{
    // Main update loop
    while (m_running.load())
    {
        try
        {
            // 1. Fetch new data (SLOW part, no lock held)
            json newPower = fetchPowerReportInternal();
            json newCpu = fetchCpuReportInternal();
            json newMemory = fetchMemoryReportInternal();
            json newTemp = fetchTemperatureReportInternal();

            // 2. Lock and update caches (FAST part)
            {
                std::lock_guard<std::shared_mutex> lock(m_statusMutex);
                m_cachedPowerReport = std::move(newPower);
                m_cachedCpuReport = std::move(newCpu);
                m_cachedMemoryReport = std::move(newMemory);
                m_cachedTemperatureReport = std::move(newTemp);
            }
        }
        catch (const std::exception& e)
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(), "Error in statusUpdateWorker: {}", e.what());
        }

        // 3. Sleep for 10 seconds (in an interruptible way)
        for (int i = 0; i < 10; ++i) // 10 * 1s = 10s sleep
        {
            if (!m_running.load())
            {
                break; // Exit loop early if stop() was called
            }
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }
}

void
DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker()
{
    // Main update loop
    while (m_running.load())
    {
        try
        {
            // 1. Fetch new data (SLOW part, no lock held)
            json newTables = fetchOpenFlowTablesInternal();

            // 2. Lock and update caches (FAST part)
            {
                std::lock_guard<std::shared_mutex> lock(m_openflowTablesMutex);
                m_cachedOpenFlowTables = std::move(newTables);
            }
        }
        catch (const std::exception& e)
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(),
                                "Error in openflowTablesUpdateWorker: {}",
                                e.what());
        }

        // 3. Sleep for 10 seconds (in an interruptible way)
        for (int i = 0; i < 10; ++i) // 10 * 1s = 10s sleep
        {
            if (!m_running.load())
            {
                break; // Exit loop early if stop() was called
            }
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }
}

json
DeviceConfigurationAndPowerManager::getTemperature()
{
    std::shared_lock<std::shared_mutex> lock(m_statusMutex);
    return m_cachedTemperatureReport;
}

json
DeviceConfigurationAndPowerManager::getPowerReport()
{
    std::shared_lock<std::shared_mutex> lock(m_statusMutex);
    return m_cachedPowerReport;
}

json
DeviceConfigurationAndPowerManager::getCpuUtilization()
{
    std::shared_lock<std::shared_mutex> lock(m_statusMutex);
    return m_cachedCpuReport;
}

json
DeviceConfigurationAndPowerManager::getMemoryUtilization()
{
    std::shared_lock<std::shared_mutex> lock(m_statusMutex);
    return m_cachedMemoryReport;
}

json
DeviceConfigurationAndPowerManager::getOpenFlowTables()
{
    std::shared_lock<std::shared_mutex> lock(m_openflowTablesMutex);
    return m_cachedOpenFlowTables;
}

static uint32_t
parseIpv4U32(const nlohmann::json& v)
{
    if (v.is_number_unsigned() || v.is_number_integer())
    {
        return v.get<uint32_t>(); // already numeric (define: host-order)
    }

    if (v.is_string())
    {
        const std::string s = v.get<std::string>();
        in_addr a{};
        if (inet_pton(AF_INET, s.c_str(), &a) != 1)
        {
            throw std::runtime_error("invalid ipv4 string: " + s);
        }

        // inet_pton gives network order; convert to host order
        return ntohl(a.s_addr);
    }

    throw std::runtime_error("ipv4 must be number or string");
}

// [Co-developed with claude code -- Adam]
// This runs AFTER HttpSession::processFlowBatch has already enqueued the jobs, so anything it
// throws is thrown too late to stop the write -- it only replaces the response. It used to read
// priority/match/actions with .at(), which throws json::out_of_range on a missing key, while
// makeInstallJob one layer up reads the same three fields with .value() and defaults. A body
// missing only `priority` therefore programmed the switch and answered
// 400 {"error":"JSON parsing error"} -- measured live 2026-08-17 on a bmv2 fabric, switch 1 going
// from five entries to six while the caller was told its request had been rejected. The Web-GUI
// reaches this: SwitchFlowTable.tsx only sets priority when it parses greater than zero, and its
// own API notes call the field optional.
//
// The accessors below now match makeInstallJob's exactly (priority 0, match {}, actions []), so
// the two layers agree on what an absent field means and this function can no longer be the one
// that decides a request failed. Report: doc/audit/2026-08-17_install-rejected-but-applied.md.
void
DeviceConfigurationAndPowerManager::updateOpenFlowTables(const json& j)
{
    const auto& ins = j.value("install_flow_entries", json::array());
    const auto& mods = j.value("modify_flow_entries", json::array());
    const auto& dels = j.value("delete_flow_entries", json::array());

    std::lock_guard<std::shared_mutex> lock(m_openflowTablesMutex);

    // Get (or create) the flow array for a given dpid, or nullptr if there is no such switch.
    //
    // [Co-developed with claude code -- Adam]
    // Returns a pointer rather than a reference so an unknown dpid can be refused. It used to
    // create a cache entry for whatever dpid the request named, and HttpSession hands the raw
    // request body straight here (`// TODO: Immediately update the table`), so
    // `install_flow_entry` with a nonexistent dpid invented a whole switch in
    // /ndt/get_switch_openflow_table_entries -- measured: dpid 999999999999 visible for ~7s,
    // until openflowTablesUpdateWorker re-polled Ryu and overwrote the cache. Two applications
    // read that endpoint, and the contract check fails on the phantom because a request-shaped
    // entry has no table_id.
    //
    // The install itself is already refused, with a warning, by
    // FlowRoutingManager::getStrategyForDpid; this is the same question asked one layer up.
    auto getFlowsArrayForDpid = [this](uint64_t dpid) -> json* {
        for (auto& sw : m_cachedOpenFlowTables)
        {
            if (sw.at("dpid").get<uint64_t>() == dpid)
            {
                return &sw["flows"][std::to_string(dpid)];
            }
        }

        if (!m_topologyAndFlowMonitor->findSwitchByDpid(dpid).has_value())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "dpid {} is not a switch in the loaded topology; not caching a "
                               "flow table for it",
                               dpid);
            return nullptr;
        }

        json sw;
        sw["dpid"] = dpid;
        sw["flows"] = json::object();
        sw["flows"][std::to_string(dpid)] = json::array();

        m_cachedOpenFlowTables.push_back(std::move(sw));

        return &m_cachedOpenFlowTables.back()["flows"][std::to_string(dpid)];
    };

    // Build or match identifier fields for a flow.
    auto extractKey = [](const json& e) {
        int tableId = e.value("table_id", 0);
        int priority = e.value("priority", 0);
        // [Co-developed with claude code -- Adam]
        // .value(), not .at(), and the defaults are HttpSession's makeInstallJob's -- see the
        // note above updateOpenFlowTables for what the mismatch cost.
        static const json kEmptyMatch = json::object();
        const json& match = e.contains("match") ? e.at("match") : kEmptyMatch;

        ndtClassifier::FlowKey fk{};
        fk.ethType = match.value("eth_type", 0);
        fk.ipProto = match.value("ip_proto", 0);

        fk.ipv4Dst = match.contains("ipv4_dst") ? parseIpv4U32(match.at("ipv4_dst")) : 0;
        fk.ipv4Src = match.contains("ipv4_src") ? parseIpv4U32(match.at("ipv4_src")) : 0;

        if (fk.ipProto == 6)
        {
            fk.tpDst = match.value("tcp_dst", 0);
            fk.tpSrc = match.value("tcp_src", 0);
        }
        else if (fk.ipProto == 17)
        {
            fk.tpDst = match.value("udp_dst", 0);
            fk.tpSrc = match.value("udp_src", 0);
        }

        return std::tuple<int, int, ndtClassifier::FlowKey>{tableId, priority, fk};
    };

    // --- INSTALL ---
    auto installOne = [&](const json& e) {
        uint64_t dpid = e.at("dpid").get<uint64_t>();

        json* flows = getFlowsArrayForDpid(dpid);
        if (!flows)
        {
            return;
        }

        json newFlow;
        newFlow["priority"] = e.value("priority", 0);
        newFlow["match"] = e.value("match", json::object());
        newFlow["actions"] = e.value("actions", json::array());
        // [Co-developed with claude code -- Adam]
        // table_id is stamped because this array is served from
        // /ndt/get_switch_openflow_table_entries alongside entries polled from Ryu, whose stats
        // always carry it. Without it the cache briefly holds two different schemas -- measured
        // as a real entry lacking table_id for ~1s after each install, until the next poll --
        // and consumers that require the field see a malformed rule.
        newFlow["table_id"] = e.value("table_id", 0);

        flows->push_back(std::move(newFlow));
    };

    // --- MODIFY ---
    auto modifyOne = [&](const json& e) {
        uint64_t dpid = e.at("dpid").get<uint64_t>();
        auto key = extractKey(e);

        json* flowsPtr = getFlowsArrayForDpid(dpid);
        if (!flowsPtr)
        {
            return;
        }
        for (auto& f : *flowsPtr)
        {
            auto fKey = extractKey(f);
            if (fKey == key)
            {
                // Update fields; we assume match+priority identifies the rule.
                f["priority"] = e.value("priority", 0);
                f["match"] = e.value("match", json::object());
                f["actions"] = e.value("actions", json::array());
                // If you may have multiple identical rules, remove this break.
                break;
            }
        }
    };

    // --- DELETE ---
    auto deleteOne = [&](const json& e) {
        uint64_t dpid = e.at("dpid").get<uint64_t>();
        auto key = extractKey(e);

        json* flows = getFlowsArrayForDpid(dpid);
        if (!flows)
        {
            return;
        }
        auto it = std::remove_if(flows->begin(), flows->end(), [&](const json& f) {
            return extractKey(f) == key;
        });
        flows->erase(it, flows->end());
    };

    // Apply all operations
    for (const auto& e : ins)
    {
        installOne(e);
    }

    for (const auto& e : mods)
    {
        modifyOne(e);
    }

    for (const auto& e : dels)
    {
        deleteOne(e);
    }
}