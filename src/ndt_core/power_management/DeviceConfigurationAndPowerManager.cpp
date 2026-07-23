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

IPowerStrategy* DeviceConfigurationAndPowerManager::getPowerStrategyForNode(Graph::vertex_descriptor node) const
{
    auto g = m_topologyAndFlowMonitor->getGraph();
    if (g[node].brandName == "BMv2")
    {
        return m_p4PowerStrategy.get();
    }
    return m_ovsPowerStrategy.get();
}

void
DeviceConfigurationAndPowerManager::start()
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "DeviceConfigurationAndPowerManager Starts Up");

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

void
DeviceConfigurationAndPowerManager::pingWorker(int interval_sec = 1)
{
    while (m_running.load())
    {
        std::this_thread::sleep_for(std::chrono::seconds(interval_sec));

        Graph graph = m_topologyAndFlowMonitor->getGraph();
        auto [vi, vi_end] = boost::vertices(graph);

        std::vector<std::string> listOvsBridges;
        if (m_mode == utils::DeploymentMode::MININET)
        {
            listOvsBridges = [&]() {
                std::vector<std::string> bridges;
                FILE* fp = popen("sudo ovs-vsctl list-br", "r");
                if (!fp)
                {
                    SPDLOG_LOGGER_ERROR(Logger::instance(), "Failed to run command");
                    return bridges;
                }

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

                pclose(fp);
                return bridges;
            }();
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
                    if (std::getenv("NDTWIN_TOPO_FILE") && 
                        std::string(std::getenv("NDTWIN_TOPO_FILE")).find("P4") != std::string::npos)
                    {
                        SPDLOG_LOGGER_DEBUG(Logger::instance(), "{} assumed reachable (P4 mode)", swName);
                        m_topologyAndFlowMonitor->setVertexUp(v);
                    }
                    else if (std::find(listOvsBridges.begin(), listOvsBridges.end(), swName) !=
                        listOvsBridges.end())
                    {
                        SPDLOG_LOGGER_DEBUG(Logger::instance(), "{} reachable", swName);
                    }
                    else
                    {
                        SPDLOG_LOGGER_DEBUG(Logger::instance(), "{} unreachable", swName);
                        m_topologyAndFlowMonitor->setVertexDown(v);
                        // TODO: Emit switch failed event
                    }
                }
            }
            else if (graph[v].vertexType == VertexType::HOST)
            {
                if (std::getenv("NDTWIN_TOPO_FILE") && 
                    std::string(std::getenv("NDTWIN_TOPO_FILE")).find("P4") != std::string::npos)
                {
                    m_topologyAndFlowMonitor->setVertexUp(v);
                }
            }
        }
    }
}

bool
DeviceConfigurationAndPowerManager::setSwitchPowerState(std::string ip,
                                                        std::string action,
                                                        SwitchInfo si)
{
    try
    {
        // 1. Build curl POST command
        //    -s           : silent
        //    -X POST      : HTTP POST
        //    -H "Host: …"
        //    -H "User-Agent: …"
        std::ostringstream cmd;
        cmd << "curl -s -X POST " << "-H \"Host: 127.0.0.1\" "
            << "-H \"User-Agent: Beast-C++-Client\" "
            // Quote full URL so shell expands safely
            << "\"http://" << GW_IP << ":8000/relay?ip=" << si.plugIp << "&index=" << si.plugIdx
            << "&method=" << action << "\"";

        // 2. Execute and grab raw HTML response
        std::string raw = utils::execCommand(cmd.str());

        // 3. Extract status text between the 2nd '>' and next '<'
        std::string status = raw;
        if (auto p1 = raw.find('>'); p1 != std::string::npos)
        {
            if (auto p2 = raw.find('>', p1 + 1); p2 != std::string::npos)
            {
                if (auto p3 = raw.find('<', p2 + 1); p3 != std::string::npos && p3 > p2 + 1)
                {
                    status = raw.substr(p2 + 1, p3 - p2 - 1);
                }
            }
        }

        // 4. Update the topology graph vertex accordingly
        auto ip_uint = utils::ipStringToUint32(ip);
        if (auto node_opt = m_topologyAndFlowMonitor->findSwitchByIp(ip_uint))
        {
            if (action == "on")
            {
                m_topologyAndFlowMonitor->setVertexUp(*node_opt);
            }
            else if (action == "off")
            {
                m_topologyAndFlowMonitor->setVertexDown(*node_opt);
            }

            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "set graph attributes for {} -> {} (controller returned “{}”)",
                               ip,
                               action,
                               status);
        }
        else
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "cannot find graph vertex for switch IP {}", ip);
        }

        return true;
    }
    catch (const std::exception& e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Error in setSwitchPowerStateCurl: {}", e.what());
        return false;
    }
}

json
DeviceConfigurationAndPowerManager::fetchMemoryReportInternal()
{
    nlohmann::json result_json;
    Graph graph = m_topologyAndFlowMonitor->getGraph();

    for (auto v : boost::make_iterator_range(vertices(graph)))
    {
        const auto& vp = graph[v];
        if (vp.vertexType != VertexType::SWITCH || !vp.isUp)
        {
            continue;
        }

        std::string ip_str = utils::ipToString(vp.ip.front());
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
        std::string ip_and_port = AppConfig::RYU_IP_AND_PORT;
        if (props.brandName == "BMv2") {
            ip_and_port = AppConfig::P4_PROXY_IP_AND_PORT;
        }

        std::string cmd =
            fmt::format("curl -s -X GET http://{}/stats/flow/{}", ip_and_port, dpid);

        SPDLOG_LOGGER_INFO(spdlog::default_logger(),
                           "DeviceManager: querying switch {} -> `{}`",
                           dpid,
                           cmd);

        std::string raw = utils::execCommand(cmd);
        SPDLOG_LOGGER_TRACE(spdlog::default_logger(),
                            "DeviceManager: raw response for {}: {}",
                            dpid,
                            raw);

        // TODO[DEBUG]: parseFlowStatsTextToJson may throw; let caller handle exceptions
        nlohmann::json flows = parseFlowStatsTextToJson(raw);

        result.push_back({{"dpid", dpid}, {"flows", flows}});

        // TODO: Test Classifier
        m_classifier->updateFromQueriedTables(result);
    }

    return result;
}

json
DeviceConfigurationAndPowerManager::parseFlowStatsTextToJson(const std::string& responseText) const
{
    try
    {
        return json::parse(responseText);
    }
    catch (const std::exception& e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "JSON parsing failed: {}", e.what());
        return json::array(); // Return empty array on failure
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

    // Prepare RNG for MININET
    static std::mt19937_64 gen{std::random_device{}()};
    static std::uniform_int_distribution<uint64_t> dis(0, UINT64_MAX >> 4);

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
            // fake/demo value
            power_mW = dis(gen);
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

    // Tell server (run on gateway port 8000) who relays the api request to smart plug
    // pass:
    //   ip       = the PDU’s IP (plug_ip)
    //   resource = "outlet"   (or "bank"/"device" if you extend SwitchInfo)
    //   index    = the plug number
    //   method   = action
    auto cmd = fmt::format("curl -s -X POST "
                           "\"http://{}:8000/relay"
                           "?ip={}"
                           "&resource=outlet"
                           "&index={}"
                           "&method={}\"",
                           GW_IP,
                           si.plugIp,
                           si.plugIdx,
                           action);

    int rc = std::system(cmd.c_str());
    return rc == 0;
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

    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    IPowerStrategy* strategy = getPowerStrategyForNode(node);

    if (action == "on")
    {
        strategy->powerOn(node, swName, dpid, m_topologyAndFlowMonitor.get());
    }
    else if (action == "off")
    {
        strategy->powerOff(node, swName, m_topologyAndFlowMonitor.get());
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
        if (vp.vertexType != VertexType::SWITCH || !vp.isUp)
        {
            continue;
        }

        std::string ip_str = utils::ipToString(vp.ip.front());
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
            result[ip_str] = "The switch is down.";
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
    // Prepare RNG for MININET
    static std::mt19937_64 gen{std::random_device{}()};
    static std::uniform_int_distribution<uint64_t> dis(0, UINT64_MAX >> 4);

    auto graph = m_topologyAndFlowMonitor->getGraph();

    // Helper lambda to calculate power for a single switch's properties.
    auto calculate_power_for_switch = [&](const auto& props,
                                          const std::string& ip_str) -> uint64_t {
        uint64_t power_mW = 0;
        if (m_mode == utils::DeploymentMode::MININET)
        {
            // fake/demo value
            power_mW = dis(gen);
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

void
DeviceConfigurationAndPowerManager::updateOpenFlowTables(const json& j)
{
    const auto& ins = j.value("install_flow_entries", json::array());
    const auto& mods = j.value("modify_flow_entries", json::array());
    const auto& dels = j.value("delete_flow_entries", json::array());

    std::lock_guard<std::shared_mutex> lock(m_openflowTablesMutex);

    // Get (or create) the flow array for a given dpid.
    auto getFlowsArrayForDpid = [this](uint64_t dpid) -> json& {
        for (auto& sw : m_cachedOpenFlowTables)
        {
            if (sw.at("dpid").get<uint64_t>() == dpid)
            {
                return sw["flows"][std::to_string(dpid)];
            }
        }

        json sw;
        sw["dpid"] = dpid;
        sw["flows"] = json::object();
        sw["flows"][std::to_string(dpid)] = json::array();

        m_cachedOpenFlowTables.push_back(std::move(sw));

        return m_cachedOpenFlowTables.back()["flows"][std::to_string(dpid)];
    };

    // Build or match identifier fields for a flow.
    auto extractKey = [](const json& e) {
        int tableId = e.value("table_id", 0);
        int priority = e.value("priority", 0);
        const json& match = e.at("match");

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

        json newFlow;
        newFlow["priority"] = e.at("priority");
        newFlow["match"] = e.at("match");
        newFlow["actions"] = e.at("actions");
        // If your real flow stats have more fields (cookie, table_id, etc.),
        // you can add them here as needed.

        json& flows = getFlowsArrayForDpid(dpid);
        flows.push_back(std::move(newFlow));
    };

    // --- MODIFY ---
    auto modifyOne = [&](const json& e) {
        uint64_t dpid = e.at("dpid").get<uint64_t>();
        auto key = extractKey(e);

        json& flows = getFlowsArrayForDpid(dpid);
        for (auto& f : flows)
        {
            auto fKey = extractKey(f);
            if (fKey == key)
            {
                // Update fields; we assume match+priority identifies the rule.
                f["priority"] = e.at("priority");
                f["match"] = e.at("match");
                f["actions"] = e.at("actions");
                // If you may have multiple identical rules, remove this break.
                break;
            }
        }
    };

    // --- DELETE ---
    auto deleteOne = [&](const json& e) {
        uint64_t dpid = e.at("dpid").get<uint64_t>();
        auto key = extractKey(e);

        json& flows = getFlowsArrayForDpid(dpid);
        auto it = std::remove_if(flows.begin(), flows.end(), [&](const json& f) {
            return extractKey(f) == key;
        });
        flows.erase(it, flows.end());
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