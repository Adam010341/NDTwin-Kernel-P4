#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"

// --- System & Library Headers ---
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <queue>
#include <shared_mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

// --- Third-Party Headers ---
#include "spdlog/spdlog.h"
#include <boost/graph/adjacency_list.hpp>
#include <boost/graph/detail/adj_list_edge_iterator.hpp>
#include <boost/graph/detail/adjacency_list.hpp>
#include <boost/graph/detail/edge.hpp>
#include <boost/iterator/iterator_categories.hpp>
#include <boost/iterator/iterator_facade.hpp>
#include <boost/move/utility_core.hpp>
#include <boost/range/irange.hpp>
#include <boost/range/iterator_range_core.hpp>
#include <nlohmann/json.hpp>
#include <openssl/sha.h>

// --- Local Headers ---
#include "utils/Logger.hpp"
#include "utils/KeyedFailureLog.hpp"
#include "utils/Utils.hpp"

using json = nlohmann::json;
using namespace std;

namespace
{
// [Co-developed with claude code -- Adam]
// Shared by both findReverseEdgeByAgentIpAndPort twins, so the same missing link is reported once
// rather than once per copy. A function-local static rather than a member: both finders are
// const, and a member would have to be mutable for no gain.
utils::KeyedFailureLog&
reverseEdgeFailures()
{
    static utils::KeyedFailureLog log{std::chrono::seconds(60)};
    return log;
}
} // namespace

/**
 * @brief The Ryu topology API base, derived from the one configured Ryu address.
 *
 * [Co-developed with claude code -- Adam]
 * This used to be `static const std::string RYU_BASE_URL = "http://localhost:8080/v1.0/topology"`
 * under a "---Please change to your own RYU base url---" comment, which bypassed
 * AppConfig::RYU_IP_AND_PORT -- the knob the flow-stats poll (FlowLinkUsageCollector.cpp) and the
 * OVS routing strategy (FlowRoutingManager.cpp) already read, and the one an operator would
 * expect to be sufficient.
 *
 * The consequence of the split was silent: redeploy Ryu elsewhere and update AppConfig, and
 * switch/host/link liveness would go on polling a dead localhost:8080. execCommand returns an
 * empty body on failure and updateSwitches/updateHosts/updateLinks all early-return on empty
 * without logging, so the graph simply stops tracking the control plane with no error anywhere.
 *
 * A function rather than a namespace-scope std::string: the value depends on another
 * dynamically-initialised object (AppConfig::RYU_IP_AND_PORT), and computing it on demand sidesteps
 * initialisation-order questions entirely. It is called once, from the constructor.
 *
 * Note this is only the *default*. configureTopologyApiUrls() still re-points the poll at the P4
 * proxy for an all-bmv2 MININET topology, and must keep running after the topology file is
 * loaded -- see its own comment for why it cannot move into the constructor.
 */
static std::string
ryuTopologyBaseUrl()
{
    return "http://" + AppConfig::RYU_IP_AND_PORT + "/v1.0/topology";
}

TopologyAndFlowMonitor::TopologyAndFlowMonitor(std::shared_ptr<Graph> graph,
                                               std::shared_ptr<std::shared_mutex> graphMutex,
                                               std::shared_ptr<EventBus> eventBus,
                                               int mode)
    : m_graph(std::move(graph)),
      m_graphMutex(std::move(graphMutex)),
      m_eventBus(std::move(eventBus)),
      m_mode(static_cast<utils::DeploymentMode>(mode))
{
    // Defaults to Ryu. Re-pointed at the P4 proxy in configureTopologyApiUrls(), which cannot
    // run here: the switch kinds come from the topology file, and that is not loaded yet.
    setTopologyApiUrls(ryuTopologyBaseUrl());
}

void
TopologyAndFlowMonitor::setTopologyApiUrls(const std::string& base)
{
    m_ryuUrl[0] = base + "/switches";
    m_ryuUrl[1] = base + "/hosts";
    m_ryuUrl[2] = base + "/links";
}

/** @brief Point the topology poll at whichever control plane owns this data plane.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * The proxy serves Ryu's `/v1.0/topology` shapes, so the kernel polls it the same way and
 * updateSwitches/updateHosts/updateLinks need no P4-specific branch.
 *
 * Must be called *after* loadStaticTopologyFromFile, because it asks the graph what kinds of
 * switch it holds. Calling it from the constructor would always observe an empty topology and
 * silently keep the Ryu default -- exactly the bug that made the identity ifIndex mapping dead
 * code for several commits, so it is done at the point of use instead.
 *
 * Only an all-bmv2 topology is re-pointed. Empty or mixed keeps Ryu, which is the conservative
 * choice: an OVS deployment must not start polling a proxy that is not there.
 */
void
TopologyAndFlowMonitor::configureTopologyApiUrls()
{
    if (m_mode != utils::MININET)
    {
        return;
    }

    const auto groups = getSwitchKindGroups();
    const bool allBmv2 = groups.size() == 1 && groups.begin()->first == SwitchKind::BMV2;
    if (!allBmv2)
    {
        return;
    }

    const std::string base = "http://" + AppConfig::P4_PROXY_IP_AND_PORT + "/v1.0/topology";
    setTopologyApiUrls(base);
    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "All-bmv2 topology: polling {} for switch/host/link state instead of Ryu.",
                       base);
}

TopologyAndFlowMonitor::~TopologyAndFlowMonitor()
{
    stop();
}

void
TopologyAndFlowMonitor::start()
{
    m_running.store(true);
    m_thread = thread(&TopologyAndFlowMonitor::run, this);
    m_flushEdgeFlowLoop = thread(&TopologyAndFlowMonitor::flushEdgeFlowLoop, this);
}

void
TopologyAndFlowMonitor::stop()
{
    m_running.store(false);
    if (m_thread.joinable())
    {
        m_thread.join();
    }
    // [Co-developed with claude code -- Adam]
    // Must be joined too: a joinable std::thread destructor calls std::terminate.
    if (m_flushEdgeFlowLoop.joinable())
    {
        m_flushEdgeFlowLoop.join();
    }
}

void
TopologyAndFlowMonitor::loadStaticTopologyFromFile(const std::string& path)
{
    // [Co-developed with claude code -- Adam]
    // Refused rather than repeated. This function *adds* vertices and edges from the file; it does
    // not reconcile against what is already there, so a second call duplicates the whole topology.
    // Measured the first time a poll loop called it twice: switches 10 -> 20 -> 30 -> 40 -> 50,
    // hosts 128 -> 640, edges 288 -> 1440, one extra copy every five seconds.
    //
    // The guard is here rather than only at the call site because the hazard belongs to this
    // function, and it was invisible for as long as there happened to be exactly one caller.
    // Reconciling properly would be the better answer; refusing is the honest one until then.
    {
        std::shared_lock lock(*m_graphMutex);
        if (boost::num_vertices(*m_graph) > 0)
        {
            SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                "static topology already loaded ({} vertices); ignoring a second "
                                "load of {}",
                                boost::num_vertices(*m_graph),
                                path);
            return;
        }
    }

    std::ifstream file(path);
    if (!file.is_open())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Cannot open topology file:  {}", path);
        return;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Load Static Topology File");

    json j;
    file >> j;

    // [Co-developed with claude code -- Adam]
    // This was commented out, and it is not an oversight that can be undone by uncommenting: the
    // body used to call findVertexByIp(), which takes a shared_lock on this same non-recursive
    // shared_mutex, so taking the write lock here deadlocked the kernel at startup. That is almost
    // certainly why it was commented out rather than fixed.
    //
    // Without it, add_vertex/add_edge mutate the graph unlocked while start() has already spawned
    // flushEdgeFlowLoop, and main.cpp starts the collector and power manager around the same time --
    // any of which may read the graph. A genuine data race, pre-existing since the d6f7c01 refactor.
    //
    // The two calls in the body now use findVertexByIpNoLock, which already existed: this class has
    // a NoLock variant of essentially every lookup precisely for callers that already hold the lock.
    // m_switchKindMutex below is a different mutex and does not participate.
    std::unique_lock lock(*m_graphMutex);

    std::unordered_map<uint64_t, Graph::vertex_descriptor> dpidToVertex;

    // Add nodes
    for (const auto& nodeJson : j["nodes"])
    {
        // VertexProperties vp = nodeJson.get<VertexProperties>();
        // Custom extraction (like from_json function)
        VertexProperties vp;
        vp.vertexType = static_cast<VertexType>(nodeJson.at("vertex_type").get<int>());
        vp.mac = nodeJson.at("mac").get<uint64_t>();
        vp.ip = utils::ipStringVecToUint32Vec(nodeJson.at("ip").get<std::vector<std::string>>());
        vp.dpid = nodeJson.at("dpid").get<uint64_t>();
        vp.isUp = false;
        vp.isEnabled = false;
        vp.deviceName = nodeJson.at("device_name").get<std::string>();
        vp.nickName = nodeJson.at("nickname").get<std::string>();
        vp.brandName = nodeJson.at("brand_name").get<std::string>();

        // [Co-developed with claude code -- Adam]
        // Prefer an explicit "switch_kind"; fall back to mapping brand_name so both
        // existing topology files keep working unchanged. A malformed switch_kind throws
        // out of switchKindFromString, which is deliberate: failing at load is far better
        // than misrouting flow rules at runtime.
        if (nodeJson.contains("switch_kind"))
        {
            vp.switchKind = switchKindFromString(nodeJson.at("switch_kind").get<std::string>());
        }
        else
        {
            vp.switchKind = switchKindFromBrandName(vp.brandName);
        }

        vp.deviceLayer = nodeJson.at("device_layer").get<int>();

        // [Co-developed with claude code -- Adam]
        // value(), not at(): host nodes carry no plug assignment and every switch node in every
        // shipped topology file does. Read here so /ndt/get_static_topology_json can echo the
        // real per-switch pair instead of the constant it used to fabricate.
        vp.smartPlugIp = nodeJson.value("smart_plug_ip", std::string{});
        vp.smartPlugOutlet = nodeJson.value("smart_plug_outlet", -1);

        vp.ecmpGroups = nodeJson.value("ecmp_groups", std::vector<EcmpGroup>{});

        // [Co-developed with claude code -- Adam]
        // Ten places call `ip.front()` on a switch's address list without checking it, including
        // findSwitchByIp(), which does so for *every* switch vertex while searching -- so one
        // switch with `"ip": []` is undefined behaviour that takes out IP lookup for the whole
        // graph, not just that switch. `at("ip")` throws on a missing key but accepts an empty
        // array, so only the file has to be wrong.
        //
        // Rejected here rather than guarding each call site: this makes the invariant those ten
        // sites already assume actually true, and failing at load with the offending dpid beats
        // undefined behaviour later. Same reasoning as the malformed-switch_kind throw above.
        if (vp.vertexType == VertexType::SWITCH && vp.ip.empty())
        {
            throw std::runtime_error(
                "switch dpid " + std::to_string(vp.dpid) + " (\"" + vp.nickName +
                "\") has an empty \"ip\" array; every switch needs at least one management "
                "address, because address lookup reads the first one unconditionally");
        }

        if (m_mode == utils::DeploymentMode::MININET && vp.vertexType == VertexType::SWITCH)
        {
            vp.bridgeNameForMininet = nodeJson.at("bridge_name").get<std::string>();
            SPDLOG_LOGGER_DEBUG(Logger::instance(),
                                "vp.bridgeNameForMininet {}",
                                vp.bridgeNameForMininet);
        }

        auto v = boost::add_vertex(vp, *m_graph);

        if (vp.vertexType == VertexType::SWITCH)
        {
            dpidToVertex[vp.dpid] = v;
            // [Co-developed with claude code -- Adam]
            // Index the data plane while we are here, so the flow-install path can look it
            // up in O(1) instead of copying the whole graph per entry.
            std::unique_lock kindLock(m_switchKindMutex);
            m_dpidToSwitchKind[vp.dpid] = vp.switchKind;
        }
    }
    // Add edges
    for (const auto& edgeJson : j["edges"])
    {
        // EdgeProperties ep = edgeJson.get<EdgeProperties>();
        // Custom extraction (like above, like from_json function)
        EdgeProperties ep;
        ep.isUp = false;
        ep.isEnabled = false;
        ep.linkBandwidth = edgeJson.at("link_bandwidth_bps").get<uint64_t>();
        ep.leftBandwidth = ep.linkBandwidth;
        ep.linkBandwidthUsage = 0;
        ep.linkBandwidthUtilization = 0;
        ep.srcIp =
            utils::ipStringVecToUint32Vec(edgeJson.at("src_ip").get<std::vector<std::string>>());
        ep.srcDpid = edgeJson.at("src_dpid").get<uint64_t>();
        ep.srcInterface = edgeJson.at("src_interface").get<uint32_t>();
        ep.dstIp =
            utils::ipStringVecToUint32Vec(edgeJson.at("dst_ip").get<std::vector<std::string>>());
        ep.dstDpid = edgeJson.at("dst_dpid").get<uint64_t>();
        ep.dstInterface = edgeJson.at("dst_interface").get<uint32_t>();
        // ep.flowSet = std::set<sflow::FlowKey>();
        ep.flowSet = {};

        std::optional<Graph::vertex_descriptor> srcVertexOpt;
        std::optional<Graph::vertex_descriptor> dstVertexOpt;

        // Lookup switch by src DPID, or host by IP if src_dpid == 0
        if (ep.srcDpid != 0)
        {
            auto it_src = dpidToVertex.find(ep.srcDpid);
            if (it_src != dpidToVertex.end())
            {
                srcVertexOpt = it_src->second;
            }
        }
        else if (!ep.srcIp.empty())
        {
            srcVertexOpt = findVertexByIpNoLock(ep.srcIp[0]);
        }

        // Lookup switch by dst DPID, or host by IP if dst_dpid == 0
        if (ep.dstDpid != 0)
        {
            auto it_dst = dpidToVertex.find(ep.dstDpid);
            if (it_dst != dpidToVertex.end())
            {
                dstVertexOpt = it_dst->second;
            }
        }
        else if (!ep.dstIp.empty())
        {
            dstVertexOpt = findVertexByIpNoLock(ep.dstIp[0]);
        }

        // Add edge if both endpoints found
        if (srcVertexOpt.has_value() && dstVertexOpt.has_value())
        {
            boost::add_edge(srcVertexOpt.value(), dstVertexOpt.value(), ep, *m_graph);
        }
        else
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "Skipping edge: src_dpid={} dst_dpid={}, src_ip={} dst_ip={}",
                               ep.srcDpid,
                               ep.dstDpid,
                               ep.srcIp.empty() ? 0 : ep.srcIp[0],
                               ep.dstIp.empty() ? 0 : ep.dstIp[0]);
        }
    }

    // [Co-developed with claude code -- Adam]
    // Report the data plane, and refuse a mixed topology unless explicitly allowed. Doing
    // this at load turns a confusing runtime mixture into a clear startup message.
    validateDataPlaneHomogeneity(AppConfig::ALLOW_MIXED_DATAPLANE);
}

std::optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByIp(uint32_t ip) const
{
    std::shared_lock lock(*m_graphMutex);

    for (auto [v_it, v_end] = boost::vertices(*m_graph); v_it != v_end; ++v_it)
    {
        const auto& props = (*m_graph)[*v_it];
        if (std::find(props.ip.begin(), props.ip.end(), ip) != props.ip.end())
        {
            return *v_it;
        }
    }

    return std::nullopt;
}

std::optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByIpNoLock(uint32_t ip) const
{
    for (auto [v_it, v_end] = boost::vertices(*m_graph); v_it != v_end; ++v_it)
    {
        const auto& props = (*m_graph)[*v_it];
        if (std::find(props.ip.begin(), props.ip.end(), ip) != props.ip.end())
        {
            return *v_it;
        }
    }

    return std::nullopt;
}

// [Co-developed with claude code -- Adam]
//
// The one place that decides which topology file this run uses.
//
// NDTWIN_TOPO_FILE was previously honoured in exactly one of five places. The other four
// -- the read-modify-rename pairs in setVertexDeviceName and setVertexNickname -- used the
// hardcoded TOPOLOGY_FILE_MININET. Since dpids 1-10 exist in both the OVS and P4 topology
// files, renaming a device while running the P4 fabric found a matching dpid in the OVS
// file and wrote the new name *into the OVS topology*, corrupting it, while hosts threw
// "No matching node in JSON".
std::string
TopologyAndFlowMonitor::activeTopologyPath() const
{
    // The override is checked before the mode defaults, so --topology (which sets this env
    // var) works in TESTBED as well as MININET. Checking the mode first meant
    // `--mode testbed --topology custom.json` silently loaded the default file instead --
    // the same class of quiet-wrong-topology failure this function exists to prevent.
    // An empty value counts as unset. getenv returns a valid pointer to "" for
    // NDTWIN_TOPO_FILE= , which would otherwise make this return "" -- and since the rename
    // paths append ".tmp" to whatever comes back, the kernel would write a stray ".tmp" into
    // its working directory and rename it over nothing.
    const char* custom = std::getenv("NDTWIN_TOPO_FILE");
    if (custom != nullptr && custom[0] != '\0')
    {
        return custom;
    }
    if (m_mode == utils::TESTBED)
    {
        return TOPOLOGY_FILE;
    }
    return TOPOLOGY_FILE_MININET;
}

/** @brief The REST poll on its own, without re-reading the static topology file.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * Split out because the loop in run() must not repeat the static load.
 * loadStaticTopologyFromFile *adds* vertices and edges; it does not reconcile. Calling it a second
 * time duplicates the entire topology, and the first time the poll loop ran this was measured
 * immediately -- switches 10 -> 20 -> 30 -> 40 -> 50, hosts 128 -> 640, edges 288 -> 1440, growing by
 * one whole topology every five seconds.
 *
 * That was invisible before because the load ran exactly once per process. It is the kind of latent
 * trap a unit test would not have found either: the duplication only appears on the *second* call,
 * and there had never been one. loadStaticTopologyFromFile now refuses a second load outright, so
 * the trap is gone rather than merely avoided here.
 */
void
TopologyAndFlowMonitor::pollControlPlaneTopology()
{
    // GET switches
    string curlCommand = "curl -s -X GET " + m_ryuUrl[0];
    string switchesStr;
    try
    {
        switchesStr = utils::execCommand(curlCommand);
    }
    catch (const exception& ex)
    {
        cerr << "Error executing curl command: " << ex.what() << endl;
        return;
    }

    // GET hosts
    curlCommand = "curl -s -X GET " + m_ryuUrl[1];
    string hostsStr;
    try
    {
        hostsStr = utils::execCommand(curlCommand);
    }
    catch (const exception& ex)
    {
        cerr << "Error executing curl command: " << ex.what() << endl;
        return;
    }

    // GET links
    curlCommand = "curl -s -X GET " + m_ryuUrl[2];
    string linksStr;
    try
    {
        linksStr = utils::execCommand(curlCommand);
    }
    catch (const exception& ex)
    {
        cerr << "Error executing curl command: " << ex.what() << endl;
        return;
    }

    updateGraph(switchesStr, hostsStr, linksStr);
}

void
TopologyAndFlowMonitor::updateSwitches(const string& topologyData)
{
    // Update Vertex(Switch) from ryu's REST api
    if (topologyData.empty()) return;
    try
    {
        auto switchesInfoJson = json::parse(topologyData);

        // PRINT JSON IN STRING PATTERN
        SPDLOG_LOGGER_TRACE(Logger::instance(), "update switch json: {}", switchesInfoJson.dump(4));

        for (const auto& switchInfoJson : switchesInfoJson)
        {
            // Note that the "dpid" is written in base 16
            const string switchDpidStr = switchInfoJson.value("dpid", "");
            // [Co-developed with claude code -- Adam]
            // Was `stoull(switchDpidStr, nullptr, 16)`. An entry carrying no "dpid" yields ""
            // here, and stoull("") throws std::invalid_argument -- which is not a
            // json::exception, so it walked straight past the catch below, past updateGraph
            // (pollControlPlaneTopology calls it outside all three of its try blocks), past
            // run(), and out of the thread entry into std::terminate. The catch's comment
            // claimed a malformed reply cost us the poll; for this flavour it cost the process.
            // One bad entry now costs that entry.
            const auto switchDpidOpt = utils::tryParseHexUint64(switchDpidStr);
            if (!switchDpidOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a switches entry whose dpid is not a hex string: "
                                   "'{}'",
                                   switchDpidStr);
                continue;
            }
            const uint64_t switchDpidUint64 = *switchDpidOpt;

            // TRACE, not INFO. This printed once per switch per process while updateSwitches was
            // called exactly once; making run() poll periodically turned it into ten lines every
            // interval, which is my own regression from that change. The WARN below is the line
            // that carries information -- a dpid the static topology does not know about.
            // [Co-developed with claude code -- Adam]
            SPDLOG_LOGGER_TRACE(Logger::instance(),
                                "switchDpidStr {} switchDpidUint64 {}",
                                switchDpidStr,
                                switchDpidUint64);

            // Update switch isUp status
            // Keep Thread Safe
            {
                unique_lock lock(*m_graphMutex);
                auto vertexSwitchOpt = findSwitchByDpidNoLock(switchDpidUint64);
                if (vertexSwitchOpt)
                {
                    (*m_graph)[*vertexSwitchOpt].isUp = true;
                    (*m_graph)[*vertexSwitchOpt].isEnabled = true;
                }
                else
                {
                    SPDLOG_LOGGER_WARN(Logger::instance(),
                                       "Switch ({}) not found in static network topology file",
                                       switchDpidStr);
                }
            }
        }
    }
    catch (const std::exception& err)
    {
        // [Co-developed with claude code -- Adam]
        // std::exception, not json::exception, and not json::parse_error. Each widening
        // happened because the previous one turned out to be a claim the code did not honour:
        //   parse_error -> json::exception: a field of an unexpected *type* throws
        //     json::type_error, so `"mac": 1` used to terminate the kernel.
        //   json::exception -> std::exception: so did a *missing* dpid, because stoull("")
        //     throws std::invalid_argument, which is not a json::exception at all. That escaped
        //     here, escaped updateGraph (pollControlPlaneTopology calls it outside its try
        //     blocks), escaped run(), and left the thread entry as std::terminate.
        // The individual parses above are guarded now, so this is the backstop rather than the
        // mechanism -- but it is what makes the sentence "should cost us this poll, not the
        // process" true for a reply shape nobody has thought of yet. This data comes from
        // another process over HTTP; it is not a place to trust our own exhaustiveness.
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "{}: ignoring malformed control-plane response: {}",
                            __func__,
                            err.what());
        return;
    }
}

void
TopologyAndFlowMonitor::updateHosts(const string& topologyData)
{
    // Update Vertex(Host) and Edge(Host to Switch) from ryu's REST api
    if (topologyData.empty()) return;
    try
    {
        auto hostsInfoJson = json::parse(topologyData);

        // PRINT JSON IN STRING PATTERN
        SPDLOG_LOGGER_TRACE(Logger::instance(), "update hosts json: {}", hostsInfoJson.dump(4));

        for (const auto& host : hostsInfoJson)
        {
            // [Co-developed with claude code -- Adam]
            // contains() before operator[]: see updateLinks. On a const json a missing key is
            // undefined behaviour under NDEBUG, not a catchable exception.
            if (!host.contains("ipv4") || host["ipv4"].empty())
            {
                SPDLOG_LOGGER_DEBUG(Logger::instance(), "Skipping host with no IPv4 address");
                continue;
            }

            auto vecIpStr = host["ipv4"];
            // [Co-developed with claude code -- Adam]
            // Every parse below this line used to be a throwing one on data from another
            // process: macToUint64, ipStringToUint32 and hexStringToUint64 all raise
            // std::invalid_argument, which is not a json::exception, so a well-typed but
            // unparseable field escaped the catch at the end of this function and terminated
            // the kernel from the poll thread. The wrong-*type* case was already handled (that
            // throws json::type_error); the wrong-*value* case was not. Held in a named string
            // so the WARNs below do not have to touch host["mac"] again -- on a const json a
            // missing key is undefined behaviour, not an exception, so `host["mac"].dump()` in
            // an error path was its own crash waiting for an entry with no mac.
            const std::string macStr = host.value("mac", "");
            const auto hostMacOpt = utils::tryMacToUint64(macStr);
            if (!hostMacOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a hosts entry whose mac is not a MAC address: '{}'",
                                   macStr);
                continue;
            }
            auto vertexOpt = findVertexByMac(*hostMacOpt);
            if (vertexOpt)
            {
                unique_lock lock(*m_graphMutex);
                (*m_graph)[*vertexOpt].isUp = true;
                (*m_graph)[*vertexOpt].isEnabled = true;
            }
            else
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "Host ({}) not found in static network topology file",
                                   macStr);
            }

            // [Co-developed with claude code -- Adam]
            // The type check is here because the *value* check below is not enough. `.get<>()` on
            // a non-string throws json::type_error, which the function-level catch does see -- but
            // seeing it means returning, so `"ipv4": [1234]` cost every host listed after it. The
            // commit that added the value guard claimed the individual parses were all guarded;
            // this was the one it missed, and an independent review of that claim found it.
            if (!vecIpStr[0].is_string())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring host {}: its ipv4[0] is {}, not a string",
                                   macStr,
                                   vecIpStr[0].type_name());
                continue;
            }
            std::string ipStr = vecIpStr[0].get<std::string>();
            const auto ipOpt = utils::tryIpStringToUint32(ipStr);
            if (!ipOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring host {}: its ipv4[0] '{}' is not an address",
                                   macStr,
                                   ipStr);
                continue;
            }
            const uint32_t ip = *ipOpt;
            auto edgeOpt = findEdgeByHostIp(ip);

            if (edgeOpt)
            {
                unique_lock lock(*m_graphMutex);
                (*m_graph)[*edgeOpt].isUp = true;
                (*m_graph)[*edgeOpt].isEnabled = true;
            }
            else
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "Edge (host {} {} {}) not found in static network topology file",
                                   macStr,
                                   ipStr,
                                   ip);
            }

            // The attachment port. `host["port"]["dpid"]` was two unchecked lookups on a const
            // json plus a throwing hex parse; Ryu sends all three, but this function's contract
            // is that a reply which does not costs the entry, not the process.
            if (!host.contains("port") || !host["port"].contains("dpid"))
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "host {} has no port.dpid; its switch-side edge is left as it "
                                   "was",
                                   macStr);
                continue;
            }
            const auto attachDpidOpt = utils::tryParseHexUint64(host["port"].value("dpid", ""));
            if (!attachDpidOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "host {} reports attachment dpid '{}', which is not hex; its "
                                   "switch-side edge is left as it was",
                                   macStr,
                                   host["port"].value("dpid", ""));
                continue;
            }
            auto vertexOpt2 = findSwitchByDpid(*attachDpidOpt);
            if (vertexOpt2.has_value())
            {
                auto edgeRevOpt = findEdgeBySrcAndDstIp((*m_graph)[*vertexOpt2].ip[0], ip);
                if (edgeRevOpt.has_value())
                {
                    unique_lock lock(*m_graphMutex);
                    (*m_graph)[edgeRevOpt.value()].isUp = true;
                    (*m_graph)[edgeRevOpt.value()].isEnabled = true;
                }
                else
                {
                    SPDLOG_LOGGER_WARN(
                        Logger::instance(),
                        "Rev Edge (host {}) not found in static network topology file",
                        macStr);
                }
            }
        }
    }
    catch (const std::exception& err)
    {
        // [Co-developed with claude code -- Adam]
        // std::exception, not json::exception, and not json::parse_error. Each widening
        // happened because the previous one turned out to be a claim the code did not honour:
        //   parse_error -> json::exception: a field of an unexpected *type* throws
        //     json::type_error, so `"mac": 1` used to terminate the kernel.
        //   json::exception -> std::exception: so did a *missing* dpid, because stoull("")
        //     throws std::invalid_argument, which is not a json::exception at all. That escaped
        //     here, escaped updateGraph (pollControlPlaneTopology calls it outside its try
        //     blocks), escaped run(), and left the thread entry as std::terminate.
        // The individual parses above are guarded now, so this is the backstop rather than the
        // mechanism -- but it is what makes the sentence "should cost us this poll, not the
        // process" true for a reply shape nobody has thought of yet. This data comes from
        // another process over HTTP; it is not a place to trust our own exhaustiveness.
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "{}: ignoring malformed control-plane response: {}",
                            __func__,
                            err.what());
        return;
    }
}

void
TopologyAndFlowMonitor::updateLinks(const string& topologyData)
{
    // Update Edge(Switch to Switch) from ryu's REST api
    if (topologyData.empty()) return;
    try
    {
        auto linksInfoJson = json::parse(topologyData);

        // PRINT JSON IN STRING PATTERN
        SPDLOG_LOGGER_TRACE(Logger::instance(), "update links json: {}", linksInfoJson.dump(4));

        for (const auto& link : linksInfoJson)
        {
            // [Co-developed with claude code -- Adam]
            // contains() before operator[]: on a *const* json, operator[] with a missing key is
            // undefined behaviour (the bounds check is a JSON_ASSERT, compiled out under NDEBUG),
            // so a link entry without "src" was not even an exception to catch.
            if (!link.contains("src") || !link.contains("dst"))
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a links entry with no src/dst endpoint");
                continue;
            }
            string srcDpidStr = link["src"].value("dpid", "");
            string srcPortStr = link["src"].value("port_no", "");
            string dstDpidStr = link["dst"].value("dpid", "");
            string dstPortStr = link["dst"].value("port_no", "");
            if (srcDpidStr.empty() || dstDpidStr.empty())
            {
                SPDLOG_LOGGER_WARN(Logger::instance(), "Empty DPID");
                continue;
            }

            // Check if both switches exist in the graph
            // [Co-developed with claude code -- Adam]
            // tryParseHexUint64, not stoull: the empty case is guarded just above, but a
            // non-empty non-hex dpid still threw std::invalid_argument past every catch on the
            // way to the run() thread. See the same change in updateSwitches.
            const auto srcDpidOpt = utils::tryParseHexUint64(srcDpidStr);
            const auto dstDpidOpt = utils::tryParseHexUint64(dstDpidStr);
            if (!srcDpidOpt || !dstDpidOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a links entry whose dpids are not hex strings: "
                                   "'{}' -> '{}'",
                                   srcDpidStr,
                                   dstDpidStr);
                continue;
            }
            uint64_t srcDpid = *srcDpidOpt;
            uint32_t srcPort = utils::portStringToUint(srcPortStr);
            uint64_t dstDpid = *dstDpidOpt;
            // uint64_t dstPort = utils::portStringToUint(dstPortStr);

            auto srcVertexOpt = findSwitchByDpid(srcDpid);
            auto dstVertexOpt = findSwitchByDpid(dstDpid);

            if (!srcVertexOpt.has_value() or !dstVertexOpt.has_value())
            {
                // [Co-developed with claude code -- Adam]
                // `continue`, not `return`. A link naming a switch the static topology does not
                // contain is one unusable entry, not a reason to abandon the reply -- and this
                // one is persistent rather than transient: the control plane sends the same list
                // every poll, so every link *after* the offender stayed at whatever state it was
                // last given, indefinitely. That is the failure this whole ingest was hardened
                // against, still present in the one branch that used a bare return.
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "ignoring a link whose endpoints are not both in the static "
                                   "topology: {} -> {}",
                                   srcDpidStr,
                                   dstDpidStr);
                continue;
            }

            {
                unique_lock lock(*m_graphMutex);
                auto srcVertex = *srcVertexOpt;
                // ==============================================
                // auto dstVertex = *dstVertexOpt;
                // auto [e, added] = boost::add_edge(srcVertex, dstVertex, *m_graph);
                // if (added)
                // {
                //     (*m_graph)[e].isUp = true;
                //     (*m_graph)[e].srcDpid = (*m_graph)[srcVertex].dpid;
                //     (*m_graph)[e].srcIp = (*m_graph)[srcVertex].ip;
                //     (*m_graph)[e].srcInterface = srcPort;
                //     (*m_graph)[e].dstDpid = (*m_graph)[dstVertex].dpid;
                //     (*m_graph)[e].dstIp = (*m_graph)[dstVertex].ip;
                //     (*m_graph)[e].dstInterface = dstPort;
                //     (*m_graph)[e].linkBandwidth = 1000000000;
                // }
                // ==============================================

                // Update link isUp status
                auto edgeOpt = findEdgeByDpidAndPortNoLock({(*m_graph)[srcVertex].dpid, srcPort});

                if (edgeOpt.has_value())
                {
                    (*m_graph)[edgeOpt.value()].isUp = true;
                    (*m_graph)[edgeOpt.value()].isEnabled = true;
                }
                else
                {
                    SPDLOG_LOGGER_WARN(
                        Logger::instance(),
                        "Link (dpid {} port {}) not found in static network topology file",
                        srcDpidStr,
                        srcPortStr);
                }
            }
        }
    }
    catch (const std::exception& err)
    {
        // [Co-developed with claude code -- Adam]
        // std::exception, not json::exception, and not json::parse_error. Each widening
        // happened because the previous one turned out to be a claim the code did not honour:
        //   parse_error -> json::exception: a field of an unexpected *type* throws
        //     json::type_error, so `"mac": 1` used to terminate the kernel.
        //   json::exception -> std::exception: so did a *missing* dpid, because stoull("")
        //     throws std::invalid_argument, which is not a json::exception at all. That escaped
        //     here, escaped updateGraph (pollControlPlaneTopology calls it outside its try
        //     blocks), escaped run(), and left the thread entry as std::terminate.
        // The individual parses above are guarded now, so this is the backstop rather than the
        // mechanism -- but it is what makes the sentence "should cost us this poll, not the
        // process" true for a reply shape nobody has thought of yet. This data comes from
        // another process over HTTP; it is not a place to trust our own exhaustiveness.
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "{}: ignoring malformed control-plane response: {}",
                            __func__,
                            err.what());
        return;
    }
}

void
TopologyAndFlowMonitor::updateGraph(const string& switchesStr,
                                    const string& hostsStr,
                                    const string& linksStr)
{
    updateSwitches(switchesStr);
    updateHosts(hostsStr);
    updateLinks(linksStr);
    // DEBUG, not INFO, matching logGraph() below. Unconditional and content-free: it says a poll
    // ran, not that anything changed. run()'s poll loop already prints one line when the up-counts
    // actually move, which is the version worth keeping. [Co-developed with claude code -- Adam]
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "\033[1;32mTopology Update From REST\033[0m");
    logGraph();
}

void
TopologyAndFlowMonitor::logGraph()
{
    constexpr char RESET[] = "\033[0m";
    constexpr char COLOR_SWITCH[] = "\033[1;34m"; // Bold blue
    constexpr char COLOR_HOST[] = "\033[1;32m";   // Bold green
    constexpr char COLOR_EDGE[] = "\033[1;37m";   // Bold white

    std::shared_lock lock(*m_graphMutex);

    std::vector<Graph::vertex_descriptor> verts;
    verts.reserve(boost::num_vertices(*m_graph));
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        verts.push_back(*vi);
    }

    std::sort(verts.begin(), verts.end(), [&](auto a, auto b) {
        return (*m_graph)[a].ip < (*m_graph)[b].ip;
    });

    SPDLOG_LOGGER_DEBUG(Logger::instance(),
                        "{}=== Vertices ({}) ==={}",
                        COLOR_EDGE,
                        verts.size(),
                        RESET);

    for (auto v : verts)
    {
        const auto& P = (*m_graph)[v];
        const char* col = (P.vertexType == VertexType::SWITCH ? COLOR_SWITCH : COLOR_HOST);
        const char* tag = (P.vertexType == VertexType::SWITCH ? "[SWITCH]" : "[HOST]");

        auto ips = utils::ipToString(P.ip);
        std::ostringstream oss;
        for (size_t i = 0; i < ips.size(); ++i)
        {
            if (i)
            {
                oss << ", ";
            }
            oss << ips[i];
        }

        SPDLOG_LOGGER_DEBUG(Logger::instance(),
                            "{}{}{} IPs: {} | DPID: {}",
                            col,
                            tag,
                            RESET,
                            oss.str(),
                            P.dpid);
    }

    std::vector<Graph::edge_descriptor> eds;
    eds.reserve(boost::num_edges(*m_graph));
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        eds.push_back(*ei);
    }

    std::sort(eds.begin(), eds.end(), [&](auto a, auto b) {
        return (*m_graph)[a].dstIp < (*m_graph)[b].dstIp;
    });

    SPDLOG_LOGGER_DEBUG(Logger::instance(),
                        "\n{}=== Edges ({}) ==={}",
                        COLOR_EDGE,
                        eds.size(),
                        RESET);

    for (auto e : eds)
    {
        const auto& E = (*m_graph)[e];
        auto srcIps = utils::ipToString(E.srcIp);
        std::ostringstream ossS;
        for (size_t i = 0; i < srcIps.size(); ++i)
        {
            if (i)
            {
                ossS << ", ";
            }
            ossS << srcIps[i];
        }
        auto dstIps = utils::ipToString(E.dstIp);
        std::ostringstream ossD;
        for (size_t i = 0; i < dstIps.size(); ++i)
        {
            if (i)
            {
                ossD << ", ";
            }
            ossD << dstIps[i];
        }

        SPDLOG_LOGGER_DEBUG(Logger::instance(),
                            "{}[EDGE]{} {} (DPID:{}, port:{})  ->  {} (DPID:{}, port:{})",
                            COLOR_EDGE,
                            RESET,
                            ossS.str(),
                            E.srcDpid,
                            E.srcInterface,
                            ossD.str(),
                            E.dstDpid,
                            E.dstInterface);
    }
}

// TODO[OPTIMIZE] Granuality Lock (Need to Carefully Check SflowCollector)
void
TopologyAndFlowMonitor::updateLinkInfo(pair<uint32_t, uint32_t> agentIpAndPort,
                                       uint64_t leftIn,
                                       uint64_t leftOut,
                                       uint64_t interfaceSpeed)
{
    auto edgeOpt = findEdgeByAgentIpAndPort(agentIpAndPort);
    if (!edgeOpt.has_value())
    {
        // SPDLOG_LOGGER_ERROR(Logger::instance(), "Link not found for agentIpAndPort");
        // SPDLOG_LOGGER_ERROR(Logger::instance(),
        //                     "Agent_ip: {}, port: {}",
        //                     utils::ipToString(agentIpAndPort.first),
        //                     agentIpAndPort.second);
        return;
    }

    auto edge = edgeOpt.value();
    auto& edgeProps = (*m_graph)[edge];

    auto revEdgeAgentIpAndPort = make_pair(edgeProps.dstIp.front(), edgeProps.dstInterface);
    auto revEdgeOpt = findEdgeByAgentIpAndPort(revEdgeAgentIpAndPort);

    if (!revEdgeOpt)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Link not found for agentIpAndPort");
        return;
    }

    auto revEdge = *revEdgeOpt;
    auto& revEdgeProps = (*m_graph)[revEdge];

    // Edge: from src (agent) to dst
    edgeProps.leftBandwidth = leftOut; // TX side: how much unused bandwidth remains
    edgeProps.linkBandwidthUtilization = (1.0 - (double)leftOut / interfaceSpeed) * 100;
    edgeProps.linkBandwidthUsage = interfaceSpeed - leftOut;
    edgeProps.linkBandwidth = interfaceSpeed;

    // Reverse Edge: from dst to src
    revEdgeProps.leftBandwidth = leftIn; // RX side
    revEdgeProps.linkBandwidthUtilization = (1.0 - (double)leftIn / interfaceSpeed) * 100;
    revEdgeProps.linkBandwidthUsage = interfaceSpeed - leftIn;
    revEdgeProps.linkBandwidth = interfaceSpeed;
}

void
TopologyAndFlowMonitor::updateLinkInfoLeftLinkBandwidth(
    std::pair<uint32_t, uint32_t> agentIpAndPort,
    uint64_t accumulatedBytes,
    double elapsedSeconds)
{
    // [Co-developed with claude code -- Adam]
    // A non-positive interval cannot produce a rate. Publishing anything here -- 0, the
    // undivided byte count, a clamped interval -- puts a number on an edge that looks exactly
    // like a measurement, and the reader has no way to tell it apart from a real one. Refuse,
    // say so, and leave the edge holding its previous value, which at least IS a measurement.
    if (!(elapsedSeconds > 0.0))
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "rate update skipped: elapsed interval {} s is not positive, so "
                            "{} bytes cannot be converted to a rate. Edge left unchanged.",
                            elapsedSeconds,
                            accumulatedBytes);
        return;
    }
    m_lastRateDivisorSeconds.store(elapsedSeconds);

    // The whole point of ticket Q: this division did not exist. The accumulator was handed on as
    // `bytes * 8` and consumed as bits-per-second, which is only correct when the interval is
    // exactly one second -- and the rate loop sleeps a full second and then runs its body.
    const uint64_t estimatedIn =
        static_cast<uint64_t>(static_cast<double>(accumulatedBytes) * 8.0 / elapsedSeconds);

    auto edgeOpt = findEdgeByAgentIpAndPort(agentIpAndPort);
    if (!edgeOpt.has_value())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Link not found for agentIpAndPort");
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "Agent_ip: {}, port: {}",
                            utils::ipToString(agentIpAndPort.first),
                            agentIpAndPort.second);
        return;
    }

    auto edge = edgeOpt.value();

    {
        std::unique_lock lock(*m_graphMutex);

        auto& edgeProps = (*m_graph)[edge];

        uint64_t leftIn =
            estimatedIn > edgeProps.linkBandwidth ? 0 : edgeProps.linkBandwidth - estimatedIn;
        edgeProps.leftBandwidthFromFlowSample = leftIn;
        edgeProps.linkBandwidthUtilization = (1.0 - (double)leftIn / edgeProps.linkBandwidth) * 100;
        edgeProps.linkBandwidthUsage =
            leftIn > edgeProps.linkBandwidth ? 0 : edgeProps.linkBandwidth - leftIn;

        SPDLOG_LOGGER_TRACE(
            Logger::instance(),
            "leftBandwidthFromFlowSample {}, linkBandwidthUtilization {}, linkBandwidthUsage {}",
            edgeProps.leftBandwidthFromFlowSample,
            edgeProps.linkBandwidthUtilization,
            edgeProps.linkBandwidthUsage);
    }
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findSwitchByDpid(uint64_t dpid) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].vertexType == VertexType::SWITCH && (*m_graph)[*vi].dpid == dpid)
        {
            return *vi;
        }
    }
    return nullopt;
}

// [Co-developed with claude code -- Adam]
std::optional<SwitchKind>
TopologyAndFlowMonitor::getSwitchKind(uint64_t dpid) const
{
    std::shared_lock lock(m_switchKindMutex);
    auto it = m_dpidToSwitchKind.find(dpid);
    if (it == m_dpidToSwitchKind.end())
    {
        return nullopt;
    }
    return it->second;
}

// [Co-developed with claude code -- Adam]
std::map<SwitchKind, std::vector<uint64_t>>
TopologyAndFlowMonitor::getSwitchKindGroups() const
{
    std::map<SwitchKind, std::vector<uint64_t>> groups;
    {
        std::shared_lock lock(m_switchKindMutex);
        for (const auto& [dpid, kind] : m_dpidToSwitchKind)
        {
            groups[kind].push_back(dpid);
        }
    }
    for (auto& [kind, dpids] : groups)
    {
        (void)kind;
        std::sort(dpids.begin(), dpids.end());
    }
    return groups;
}

// [Co-developed with claude code -- Adam]
bool
TopologyAndFlowMonitor::validateDataPlaneHomogeneity(bool allowMixed) const
{
    const auto groups = getSwitchKindGroups();

    if (groups.empty())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "Topology contains no switches; nothing can be controlled");
        return false;
    }

    if (groups.size() == 1)
    {
        const auto& [kind, dpids] = *groups.begin();
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "Data plane: {} ({} switch(es))",
                           switchKindToString(kind),
                           dpids.size());
        return true;
    }

    std::ostringstream detail;
    bool first = true;
    for (const auto& [kind, dpids] : groups)
    {
        if (!first)
        {
            detail << "; ";
        }
        first = false;
        detail << switchKindToString(kind) << "=[";
        for (size_t i = 0; i < dpids.size(); ++i)
        {
            detail << (i ? "," : "") << dpids[i];
        }
        detail << "]";
    }

    if (allowMixed)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Topology mixes data planes ({}). Proceeding because mixed "
                           "operation was explicitly allowed; telemetry and liveness are "
                           "not validated for this configuration.",
                           detail.str());
        return true;
    }

    SPDLOG_LOGGER_ERROR(Logger::instance(),
                        "Topology mixes data planes ({}). A single run must be all-OVS or "
                        "all-BMv2: the flow dispatch is per-DPID and would cope, but the "
                        "telemetry and liveness paths assume one kind. Fix the topology "
                        "file, or set AppConfig::ALLOW_MIXED_DATAPLANE to override.",
                        detail.str());
    return false;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findSwitchByDpidNoLock(uint64_t dpid) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].vertexType == VertexType::SWITCH && (*m_graph)[*vi].dpid == dpid)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByMac(uint64_t mac) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].mac == mac)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByMacNoLock(uint64_t mac) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].mac == mac)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByMininetBridgeName(const std::string& mininetBridgeName) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].bridgeNameForMininet == mininetBridgeName)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByMininetBridgeNameNoLock(
    const std::string& mininetBridgeName) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].bridgeNameForMininet == mininetBridgeName)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByDeviceName(const std::string& deviceName) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].deviceName == deviceName)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findVertexByDeviceNameNoLock(const std::string& deviceName) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if ((*m_graph)[*vi].deviceName == deviceName)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByAgentIpAndPort(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            return edge;
        }
    }
    return nullopt;
}

// [Co-developed with claude code -- Adam]
optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeToHostByAgentIpAndPort(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            // dstDpid == 0 is how the topology loader marks a non-switch endpoint: hosts are
            // the only vertices without a datapath id (see the dstDpid != 0 branch where edges
            // are loaded). A switch far end means a sampler exists over there and owns the
            // edge's accounting; a host far end has no sampler at all.
            if (props.dstDpid == 0)
            {
                return edge;
            }
            return nullopt;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findReverseEdgeByAgentIpAndPortNoLock(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            auto sourceNode = boost::source(edge, *m_graph);
            auto targetNode = boost::target(edge, *m_graph);
            // [Co-developed with claude code -- Adam]
            // `.second` is the found flag, and dropping it turned a miss into a hit: a singular
            // edge_descriptor wrapped in an *engaged* optional, which every caller then treats
            // as a real edge. FlowLinkUsageCollector writes through this one on the sFlow
            // ingest path (touchEdgeFlow), so a graph holding only the forward direction of a
            // link -- reachable, which is why 7f738e6 exists to report half-processed link
            // transitions -- had per-edge flow bookkeeping running on an invalid descriptor.
            // No sanitizer flags an unchecked `.second`; it is a dropped error flag, not a race.
            //
            // Reported through KeyedFailureLog, not at DEBUG. The first version of this used
            // DEBUG on the reasoning that a per-sample WARN is how this process once reached
            // 138,000 log lines a day -- true, but the wrong conclusion, and an independent
            // review caught it: a missing reverse edge is a *persistent structural* condition,
            // not a per-sample transient. DEBUG does not thin a flood there, it converts a
            // permanent condition into permanent silence, because LogConfig defaults to info and
            // the running kernel passes no level flag. The graph would stay asymmetric and the
            // one place that notices would say nothing -- which is the state this guard exists
            // to surface. KeyedFailureLog is the instrument this repo already built for exactly
            // that shape, and FlowLinkUsageCollector -- the caller on this path -- already uses
            // it: first occurrence per key, recovery, nothing in between.
            const auto reverse = boost::edge(targetNode, sourceNode, *m_graph);
            if (!reverse.second)
            {
                reverseEdgeFailures().record(
                    utils::ipToString(agentIpAndPort.first) + ":" +
                        std::to_string(agentIpAndPort.second),
                    "no reverse edge for this agent and port; the graph holds only one direction "
                    "of the link, so per-edge flow bookkeeping for it is skipped");
                return nullopt;
            }
            return reverse.first;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findReverseEdgeByAgentIpAndPort(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            auto sourceNode = boost::source(edge, *m_graph);
            auto targetNode = boost::target(edge, *m_graph);
            // [Co-developed with claude code -- Adam]
            // `.second` is the found flag, and dropping it turned a miss into a hit: a singular
            // edge_descriptor wrapped in an *engaged* optional, which every caller then treats
            // as a real edge. FlowLinkUsageCollector writes through this one on the sFlow
            // ingest path (touchEdgeFlow), so a graph holding only the forward direction of a
            // link -- reachable, which is why 7f738e6 exists to report half-processed link
            // transitions -- had per-edge flow bookkeeping running on an invalid descriptor.
            // No sanitizer flags an unchecked `.second`; it is a dropped error flag, not a race.
            //
            // Reported through KeyedFailureLog, not at DEBUG. The first version of this used
            // DEBUG on the reasoning that a per-sample WARN is how this process once reached
            // 138,000 log lines a day -- true, but the wrong conclusion, and an independent
            // review caught it: a missing reverse edge is a *persistent structural* condition,
            // not a per-sample transient. DEBUG does not thin a flood there, it converts a
            // permanent condition into permanent silence, because LogConfig defaults to info and
            // the running kernel passes no level flag. The graph would stay asymmetric and the
            // one place that notices would say nothing -- which is the state this guard exists
            // to surface. KeyedFailureLog is the instrument this repo already built for exactly
            // that shape, and FlowLinkUsageCollector -- the caller on this path -- already uses
            // it: first occurrence per key, recovery, nothing in between.
            const auto reverse = boost::edge(targetNode, sourceNode, *m_graph);
            if (!reverse.second)
            {
                reverseEdgeFailures().record(
                    utils::ipToString(agentIpAndPort.first) + ":" +
                        std::to_string(agentIpAndPort.second),
                    "no reverse edge for this agent and port; the graph holds only one direction "
                    "of the link, so per-edge flow bookkeeping for it is skipped");
                return nullopt;
            }
            return reverse.first;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByAgentIpAndPortNoLock(
    const pair<uint32_t, uint32_t>& agentIpAndPort) const
{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.srcIp.front() == agentIpAndPort.first and
            props.srcInterface == agentIpAndPort.second)
        {
            return edge;
        }
    }
    return nullopt;
}

std::optional<std::pair<uint32_t, uint32_t>>
TopologyAndFlowMonitor::getAgentKeyFromTheOtherSide(
    const std::pair<uint32_t, uint32_t>& agentIpAndPort) const

{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.dstIp.front() == agentIpAndPort.first and
            props.dstInterface == agentIpAndPort.second)
        {
            return make_pair(props.srcIp.front(), props.srcInterface);
        }
    }
    return nullopt;
}

std::optional<std::pair<uint32_t, uint32_t>>
TopologyAndFlowMonitor::getAgentKeyFromTheOtherSideNoLock(
    const std::pair<uint32_t, uint32_t>& agentIpAndPort) const

{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.dstIp.front() == agentIpAndPort.first and
            props.dstInterface == agentIpAndPort.second)
        {
            return make_pair(props.srcIp.front(), props.srcInterface);
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByDpidAndPort(pair<uint64_t, uint32_t> dpid_and_port) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        const auto& eprop = (*m_graph)[*ei];

        if (eprop.srcDpid == dpid_and_port.first && eprop.srcInterface == dpid_and_port.second)
        {
            return *ei;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByDpidAndPortNoLock(pair<uint64_t, uint32_t> dpid_and_port) const
{
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        const auto& eprop = (*m_graph)[*ei];

        if (eprop.srcDpid == dpid_and_port.first && eprop.srcInterface == dpid_and_port.second)
        {
            return *ei;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeBySrcAndDstDpid(
    pair<uint64_t, uint64_t> src_dpid_and_dst_dpid) const
{
    std::shared_lock lock(*m_graphMutex);
    SPDLOG_LOGGER_TRACE(Logger::instance(),
                        "Enter TopologyAndFlowMonitor::findEdgeBySrcAndDstDpid");
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        const auto& eprop = (*m_graph)[*ei];

        if (eprop.srcDpid == src_dpid_and_dst_dpid.first &&
            eprop.dstDpid == src_dpid_and_dst_dpid.second)
        {
            return *ei;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeBySrcAndDstDpidNoLock(
    pair<uint64_t, uint64_t> src_dpid_and_dst_dpid) const
{
    SPDLOG_LOGGER_TRACE(Logger::instance(),
                        "Enter TopologyAndFlowMonitor::findEdgeBySrcAndDstDpid");
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        const auto& eprop = (*m_graph)[*ei];

        if (eprop.srcDpid == src_dpid_and_dst_dpid.first &&
            eprop.dstDpid == src_dpid_and_dst_dpid.second)
        {
            return *ei;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByHostIp(uint32_t hostIp) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (find(props.srcIp.begin(), props.srcIp.end(), hostIp) != props.srcIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findReverseEdgeByHostIp(uint32_t hostIp) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (find(props.dstIp.begin(), props.dstIp.end(), hostIp) != props.dstIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByHostIpNoLock(uint32_t hostIp) const
{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (find(props.srcIp.begin(), props.srcIp.end(), hostIp) != props.srcIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByHostIp(vector<uint32_t> hostIp) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.srcIp == hostIp)
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findReverseEdgeByHostIp(vector<uint32_t> hostIp) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.dstIp == hostIp)
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeByHostIpNoLock(vector<uint32_t> hostIp) const
{
    for (auto edgeIt = boost::edges(*m_graph).first; edgeIt != boost::edges(*m_graph).second;
         ++edgeIt)
    {
        auto edge = *edgeIt;
        const auto& props = (*m_graph)[edge];
        if (props.srcIp == hostIp)
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeBySrcAndDstIp(uint32_t src_ip, uint32_t dst_ip) const
{
    std::shared_lock lock(*m_graphMutex);
    for (const auto& edge : boost::make_iterator_range(boost::edges(*m_graph)))
    {
        const auto& props = (*m_graph)[edge];
        auto itSrc = find(props.srcIp.begin(), props.srcIp.end(), src_ip);
        auto itDst = find(props.dstIp.begin(), props.dstIp.end(), dst_ip);
        if (itSrc != props.srcIp.end() && itDst != props.dstIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

optional<Graph::edge_descriptor>
TopologyAndFlowMonitor::findEdgeBySrcAndDstIpNoLock(uint32_t src_ip, uint32_t dst_ip) const
{
    for (const auto& edge : boost::make_iterator_range(boost::edges(*m_graph)))
    {
        const auto& props = (*m_graph)[edge];
        auto itSrc = find(props.srcIp.begin(), props.srcIp.end(), src_ip);
        auto itDst = find(props.dstIp.begin(), props.dstIp.end(), dst_ip);
        if (itSrc != props.srcIp.end() && itDst != props.dstIp.end())
        {
            return edge;
        }
    }
    return nullopt;
}

void
TopologyAndFlowMonitor::setEdgeDown(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    std::unique_lock lock(*m_graphMutex);
    (*m_graph)[e].isUp = false;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeDown {}", (*m_graph)[e].isUp);
}

void
TopologyAndFlowMonitor::setEdgeDownNoLock(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    (*m_graph)[e].isUp = false;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeDownNoLock {}", (*m_graph)[e].isUp);
}

void
TopologyAndFlowMonitor::setEdgeUp(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    std::unique_lock lock(*m_graphMutex);
    (*m_graph)[e].isUp = true;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeUp {}", (*m_graph)[e].isUp);
}

void
TopologyAndFlowMonitor::setEdgeUpNoLock(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    (*m_graph)[e].isUp = true;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeUpNoLock {}", (*m_graph)[e].isUp);
}

void
TopologyAndFlowMonitor::setEdgeEnable(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    std::unique_lock lock(*m_graphMutex);
    (*m_graph)[e].isEnabled = true;
}

void
TopologyAndFlowMonitor::setEdgeEnableNoLock(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    (*m_graph)[e].isEnabled = true;
}

void
TopologyAndFlowMonitor::setEdgeDisable(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    std::unique_lock lock(*m_graphMutex);
    (*m_graph)[e].isEnabled = false;
}

void
TopologyAndFlowMonitor::setEdgeDisableNoLock(Graph::edge_descriptor e)
{
    // TODO[OPTIMIZE]: Use atomic<bool> in data structure
    (*m_graph)[e].isEnabled = false;
}

pair<uint64_t, uint32_t>
TopologyAndFlowMonitor::getEdgeStats(Graph::edge_descriptor e) const
{
    std::shared_lock lock(*m_graphMutex);
    const auto& edgeProps = (*m_graph)[e];
    return {m_mode == utils::MININET ? edgeProps.leftBandwidthFromFlowSample
                                     : edgeProps.leftBandwidth,
            edgeProps.flowSet.size()};
}

pair<uint64_t, uint32_t>
TopologyAndFlowMonitor::getEdgeStatsNoLock(Graph::edge_descriptor e) const
{
    const auto& edgeProps = (*m_graph)[e];
    return {m_mode == utils::MININET ? edgeProps.leftBandwidthFromFlowSample
                                     : edgeProps.leftBandwidth,
            edgeProps.flowSet.size()};
}


std::set<sflow::FlowKey>
TopologyAndFlowMonitor::getEdgeFlowSet(Graph::edge_descriptor e) const
{
    std::shared_lock<std::shared_mutex> lock(*m_graphMutex);
    std::set<sflow::FlowKey> out;
    const auto& mp = (*m_graph)[e].flowSet; // unordered_map<FlowKey, TimePoint>
    for (const auto& kv : mp)
    {
        out.insert(kv.first);
    }
    return out;
}

std::set<sflow::FlowKey>
TopologyAndFlowMonitor::getEdgeFlowSetNoLock(Graph::edge_descriptor e) const
{
    std::set<sflow::FlowKey> out;
    const auto& mp = (*m_graph)[e].flowSet; // unordered_map<FlowKey, TimePoint>
    for (const auto& kv : mp)
    {
        out.insert(kv.first);
    }
    return out;
}

Graph
TopologyAndFlowMonitor::getGraph() const
{
    std::shared_lock lock(*m_graphMutex);
    return *m_graph;
}

void
TopologyAndFlowMonitor::setVertexDeviceName(Graph::vertex_descriptor v, std::string name)
{
    {
        std::unique_lock lock(*m_graphMutex);
        (*m_graph)[v].deviceName = name;
    }

    // Also modify configuration file
    {
        std::lock_guard guard(m_configurationFileMutex);
        nlohmann::json j;
        {
            // [Co-developed with claude code -- Adam]
            // activeTopologyPath() honours NDTWIN_TOPO_FILE; the mode branch this replaces
            // always read the OVS file in Mininet mode, even when running the P4 fabric.
            std::ifstream ifs;
            ifs.open(activeTopologyPath());
            if (!ifs.is_open())
            {
                throw std::runtime_error("Cannot open topology file");
            }
            ifs >> j;
        }

        bool updated = false;
        // TODO: Read Lock? (But these information wouldn't change in reality)
        auto vertexType = (*m_graph)[v].vertexType == VertexType::SWITCH ? 0 : 1;
        auto vertexDpid = (*m_graph)[v].dpid;
        auto vertexMac = (*m_graph)[v].mac;

        for (auto& node : j["nodes"])
        {
            int vt = node.value("vertex_type", -1);
            if (vt != vertexType)
            {
                continue;
            }

            if (vertexType == 0)
            {
                if (node.value("dpid", (uint64_t)0) == vertexDpid)
                {
                    node["device_name"] = name;
                    updated = true;
                    break;
                }
            }
            else
            {
                if (node.value("mac", (uint64_t)0) == vertexMac)
                {
                    node["device_name"] = name;
                    updated = true;
                    break;
                }
            }
        }

        if (!updated)
        {
            throw std::runtime_error("No matching node in JSON");
        }

        // [Co-developed with claude code -- Adam]
        const auto topoPath = activeTopologyPath();
        const auto tmp = topoPath + ".tmp";
        {
            std::ofstream ofs(tmp);
            if (!ofs.is_open())
            {
                throw std::runtime_error("Cannot open temp file");
            }
            ofs << std::setw(2) << j << std::endl;
        }
        std::filesystem::rename(tmp,
                                topoPath);
    }
}

void
TopologyAndFlowMonitor::setVertexNickname(Graph::vertex_descriptor v, std::string nickname)
{
    // 1. Update the nickname for the device in the live, in-memory graph.
    // This is protected by a mutex for thread safety.
    {
        std::unique_lock lock(*m_graphMutex);
        (*m_graph)[v].nickName = nickname;
    }

    // 2. Update the nickname in the persistent JSON configuration file.
    {
        std::lock_guard guard(m_configurationFileMutex);
        nlohmann::json j;

        // Read the entire contents of the current topology file.
        {
            // [Co-developed with claude code -- Adam]
            // activeTopologyPath() honours NDTWIN_TOPO_FILE; the mode branch this replaces
            // always read the OVS file in Mininet mode, even when running the P4 fabric.
            std::ifstream ifs;
            ifs.open(activeTopologyPath());
            if (!ifs.is_open())
            {
                throw std::runtime_error("Cannot open topology file");
            }
            ifs >> j;
        }

        bool updated = false;
        auto vertexType = (*m_graph)[v].vertexType == VertexType::SWITCH ? 0 : 1;
        auto vertexDpid = (*m_graph)[v].dpid;
        auto vertexMac = (*m_graph)[v].mac;

        // Find the matching device in the JSON data structure.
        for (auto& node : j["nodes"])
        {
            int vt = node.value("vertex_type", -1);
            if (vt != vertexType)
            {
                continue;
            }

            if (vertexType == 0) // It's a switch
            {
                if (node.value("dpid", (uint64_t)0) == vertexDpid)
                {
                    node["nickname"] = nickname; // Update the nickname field
                    updated = true;
                    break;
                }
            }
            else // It's a host
            {
                if (node.value("mac", (uint64_t)0) == vertexMac)
                {
                    node["nickname"] = nickname; // Update the nickname field
                    updated = true;
                    break;
                }
            }
        }

        if (!updated)
        {
            throw std::runtime_error("No matching node in JSON");
        }

        // Safely write the modified JSON data back to the file.
        // [Co-developed with claude code -- Adam]
        const auto topoPath = activeTopologyPath();
        const auto tmp = topoPath + ".tmp";
        {
            std::ofstream ofs(tmp);
            if (!ofs.is_open())
            {
                throw std::runtime_error("Cannot open temp file");
            }
            ofs << std::setw(2) << j << std::endl;
        }
        std::filesystem::rename(tmp,
                                topoPath);
    }
}

/** @brief Keeps the graph in step with the control plane, instead of snapshotting it once.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 *
 * This used to call fetchAndUpdateTopologyData() exactly once and return. Measured on a live run:
 * `run` was entered at 13:55:55.154 and exited at **.242** -- 88 milliseconds -- and the entire
 * graph, switches and hosts and links, was whatever Ryu happened to know in that instant. Nothing
 * re-read it for the life of the process.
 *
 * That is the actual cause of the "flaky" `get_graph_data` contract failure, and the explanation
 * previously recorded for it was wrong. The note said static ARP stops Ryu ever learning host IPs;
 * in fact `testbed_topo.py` sets the static ARP entries and *then pings all 128 hosts in parallel*,
 * which is what teaches Ryu. So the empty-`ipv4` state is transient, and whether the one snapshot
 * catches it depends entirely on when the kernel starts:
 *
 *   - started 73 s after Mininet (by hand): Ryu already knows all 128 IPs -> 128/128 hosts up
 *   - started back-to-back (stack.sh up ovs): the snapshot lands mid-burst -> permanently short
 *
 * Same commit, same network, different verdict. Hosts are the visible symptom because they have no
 * push path at all -- switches arrive via /ndt/inform_switch_entered and link failures via
 * /ndt/link_failure_detected, but nothing ever pushes a host.
 *
 * Re-polling is safe for links, which was the thing worth checking before writing this: verified
 * live that Ryu's `/v1.0/topology/links` really does drop a failed link (32 -> 30 within 2 s) and
 * restore it on recovery (-> 32 within 8 s), and that `updateLinks` only ever sets `isUp = true`.
 * So a poll can fill in what was missed but cannot resurrect an edge the push path correctly took
 * down.
 *
 * Fast at first, then slow, and time-boxed rather than gated on a convergence test: a genuinely
 * absent host would keep a convergence gate in fast mode forever.
 */
void
TopologyAndFlowMonitor::run()
{
    using namespace std::chrono_literals;
    constexpr auto kWhileConverging = 5s;
    constexpr auto kOnceConverged = 30s;
    constexpr auto kConvergingFor = 90s; // covers the ping burst and LLDP discovery

    SPDLOG_LOGGER_INFO(Logger::instance(), "TopologyAndFlowMonitor Run");

    // Once: the static topology is static, and loading it twice duplicates it.
    loadStaticTopologyFromFile(activeTopologyPath());
    initializeMappingsFromGraph();
    // Only now is it known whether this is a bmv2 fabric, so only now can the poll be aimed.
    configureTopologyApiUrls();

    const auto startedAt = std::chrono::steady_clock::now();
    auto previous = graphLivenessSummary();
    bool first = true;

    while (m_running.load())
    {
        pollControlPlaneTopology();

        // Reported only when something moved. One line per poll forever is how the two 1 Hz INFO
        // lines elsewhere in this process reached 138,000 lines a day.
        const auto now = graphLivenessSummary();
        if (first || now != previous)
        {
            const auto [switchesUp, hostsUp, edgesUp] = now;
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "topology from the control plane: {} switches, {} hosts, {} edges up",
                               switchesUp,
                               hostsUp,
                               edgesUp);
            previous = now;
            first = false;
        }

        const auto interval = (std::chrono::steady_clock::now() - startedAt < kConvergingFor)
                                  ? kWhileConverging
                                  : kOnceConverged;
        // Sliced so stop() does not wait out a whole interval.
        for (auto slept = 0s; slept < interval && m_running.load(); slept += 1s)
        {
            std::this_thread::sleep_for(1s);
        }
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Exiting TopologyAndFlowMonitor's updating");
}

/** @brief (switches up, hosts up, edges up). Cheap change signal for the poll loop.
 *
 * [Co-developed with claude code -- Adam]
 */
std::tuple<std::size_t, std::size_t, std::size_t>
TopologyAndFlowMonitor::graphLivenessSummary() const
{
    std::shared_lock lock(*m_graphMutex);
    std::size_t switchesUp = 0;
    std::size_t hostsUp = 0;
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        if (!(*m_graph)[*vi].isUp)
        {
            continue;
        }
        if ((*m_graph)[*vi].vertexType == VertexType::SWITCH)
        {
            ++switchesUp;
        }
        else
        {
            ++hostsUp;
        }
    }

    std::size_t edgesUp = 0;
    for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
    {
        if ((*m_graph)[*ei].isUp)
        {
            ++edgesUp;
        }
    }
    return {switchesUp, hostsUp, edgesUp};
}

vector<sflow::Path>
TopologyAndFlowMonitor::getAllPathsBetweenTwoHosts(sflow::FlowKey flow_key,
                                                   uint64_t src_sw_dpid,
                                                   uint64_t dst_sw_dpid)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "DFS Ready");
    vector<sflow::Path> paths;
    shared_lock lock(*m_graphMutex);

    // 1. Locate source and destination switch vertices
    Graph::vertex_descriptor src_v, dst_v;

    auto srcVertexOpt = findSwitchByDpidNoLock(src_sw_dpid);
    auto dstVertexOpt = findSwitchByDpidNoLock(dst_sw_dpid);

    if (!srcVertexOpt or !dstVertexOpt)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Cannot Find Certain Switches");
        return paths;
    }

    src_v = *srcVertexOpt;
    dst_v = *dstVertexOpt;

    // 2. Prepare for DFS
    unordered_set<Graph::vertex_descriptor> visited;
    visited.reserve(boost::num_vertices(*m_graph));

    sflow::Path current_path;
    current_path.push_back({flow_key.srcIP, 0U});

    // 3. Recursive DFS lambda
    function<void(Graph::vertex_descriptor)> dfs = [&](Graph::vertex_descriptor u) {
        if (u == dst_v)
        {
            // Found a full path—store a copy
            current_path.push_back({dst_sw_dpid, 0U});
            current_path.push_back({flow_key.dstIP, 0U});
            paths.push_back(current_path);
            current_path.pop_back();
            current_path.pop_back();
            return;
        }
        visited.insert(u);

        // Explore all outgoing edges
        auto [ei, eiEnd] = boost::out_edges(u, *m_graph);

        for (; ei != eiEnd; ++ei)
        {
            auto e = *ei;
            auto v = boost::target(e, *m_graph);
            if (visited.count(v))
            {
                continue;
            }

            const auto& ep = (*m_graph)[e];
            // Only traverse the active and enabled links
            if (isUsable(ep))
            {
                current_path.push_back({ep.srcDpid, ep.srcInterface});
                dfs(v);
                current_path.pop_back();
            }
        }
        visited.erase(u);
    };

    // 4. Kick off the search
    SPDLOG_LOGGER_INFO(Logger::instance(), "DFS Start");
    dfs(src_v);

    string paths_str;
    for (auto path : paths)
    {
        for (auto node : path)
        {
            paths_str += "(" + to_string(node.first) + "," + to_string(node.second) + ") ";
        }
        paths_str += "| ";
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "{}", paths_str);
    return paths;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findSwitchByIp(uint32_t ip) const
{
    std::shared_lock lock(*m_graphMutex);
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        const auto& vprop = (*m_graph)[*vi];
        if (vprop.vertexType == VertexType::SWITCH && vprop.ip.front() == ip)
        {
            return *vi;
        }
    }
    return nullopt;
}

optional<Graph::vertex_descriptor>
TopologyAndFlowMonitor::findSwitchByIpNoLock(uint32_t ip) const
{
    for (auto [vi, viEnd] = boost::vertices(*m_graph); vi != viEnd; ++vi)
    {
        const auto& vprop = (*m_graph)[*vi];
        if (vprop.vertexType == VertexType::SWITCH && vprop.ip.front() == ip)
        {
            return *vi;
        }
    }
    return nullopt;
}

void
TopologyAndFlowMonitor::setVertexDown(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].isUp = false;
}

void
TopologyAndFlowMonitor::setVertexUp(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].isUp = true;
}

bool
TopologyAndFlowMonitor::getVertexIsUp(Graph::vertex_descriptor v)
{
    shared_lock lock(*m_graphMutex);
    return (*m_graph)[v].isUp;
}

bool
TopologyAndFlowMonitor::getVertexIsEnabled(Graph::vertex_descriptor v)
{
    shared_lock lock(*m_graphMutex);
    return (*m_graph)[v].isEnabled;
}

void
TopologyAndFlowMonitor::setMininetBridgePorts(Graph::vertex_descriptor v,
                                              std::vector<std::string> ports)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].bridgeConnectedPortsForMininet = ports;
}

std::vector<std::string>
TopologyAndFlowMonitor::getMininetBridgePorts(Graph::vertex_descriptor v)
{
    shared_lock lock(*m_graphMutex);
    return (*m_graph)[v].bridgeConnectedPortsForMininet;
}

void
TopologyAndFlowMonitor::setVertexEnable(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].isEnabled = true;
}

void
TopologyAndFlowMonitor::setVertexDisable(Graph::vertex_descriptor v)
{
    unique_lock lock(*m_graphMutex);
    (*m_graph)[v].isEnabled = false;
}

bool
TopologyAndFlowMonitor::disableSwitchAndEdges(uint64_t dpid)
{
    std::unique_lock lock(*m_graphMutex);
    auto vertexOpt = findSwitchByDpidNoLock(dpid);
    if (!vertexOpt)
    {
        // [Co-developed with claude code -- Adam]
        // Returned rather than only logged: the caller composes the operator's answer, and while
        // this was void it answered "ok" to a disable that had touched nothing.
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "administrative disable of dpid {} did nothing: no such switch in the "
                           "graph",
                           dpid);
        return false;
    }

    auto vertex = *vertexOpt;

    // [Co-developed with claude code -- Adam]
    // Both flags, and they do different jobs. `isEnabled = false` makes the disable take effect
    // now; `adminDisabled = true` makes it *survive*, because the next topology poll sets
    // `isEnabled` back to true unconditionally for everything it reports and has no idea an
    // operator ever spoke. Writing only the first is what made DisableSwitch a silent no-op.
    (*m_graph)[vertex].isEnabled = false;
    (*m_graph)[vertex].adminDisabled = true;

    for (auto [ei, ei_end] = boost::edges(*m_graph); ei != ei_end; ++ei)
    {
        auto src_v = boost::source(*ei, *m_graph);
        auto dst_v = boost::target(*ei, *m_graph);

        if (src_v == vertex || dst_v == vertex)
        {
            (*m_graph)[*ei].isEnabled = false;
            (*m_graph)[*ei].adminDisabled = true;
        }
    }

    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "administrative disable of dpid {} recorded (survives topology polls)",
                       dpid);
    return true;
}

bool
TopologyAndFlowMonitor::enableSwitchAndEdges(uint64_t dpid)
{
    std::unique_lock lock(*m_graphMutex);
    auto vertexOpt = findSwitchByDpidNoLock(dpid);
    if (!vertexOpt)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "administrative enable of dpid {} did nothing: no such switch in the "
                           "graph",
                           dpid);
        return false;
    }

    auto vertex = *vertexOpt;

    // Clears the administrative intent as well as enabling: "enable s3" from an operator has to be
    // able to undo "disable s3" from the same operator, and only the second line does that.
    // [Co-developed with claude code -- Adam]
    (*m_graph)[vertex].isEnabled = true;
    (*m_graph)[vertex].adminDisabled = false;

    for (auto [ei, ei_end] = boost::edges(*m_graph); ei != ei_end; ++ei)
    {
        auto src_v = boost::source(*ei, *m_graph);
        auto dst_v = boost::target(*ei, *m_graph);

        if (src_v == vertex || dst_v == vertex)
        {
            (*m_graph)[*ei].isEnabled = true;
            (*m_graph)[*ei].adminDisabled = false;
        }
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "administrative enable of dpid {} recorded", dpid);
    return true;
}

void
TopologyAndFlowMonitor::initializeMappingsFromGraph()
{
    std::shared_lock lock(*m_graphMutex);
    for (const auto& v : boost::make_iterator_range(boost::vertices(*m_graph)))
    {
        const auto& props = (*m_graph)[v];

        if (props.vertexType != VertexType::SWITCH || props.ip.empty())
        {
            continue;
        }

        uint64_t dpid = props.dpid;
        std::string ipStr = utils::ipToString(props.ip[0]);

        m_dpidToIpStrMap[dpid] = ipStr;
        m_dpidStrToIpStrMap[std::to_string(dpid)] = ipStr;
        m_ipStrToDpidMap[ipStr] = dpid;
        m_ipStrToDpidStrMap[ipStr] = std::to_string(dpid);
    }

    SPDLOG_LOGGER_TRACE(Logger::instance(), "=== m_dpidToIpStrMap ===");
    for (const auto& [dpid, ip] : m_dpidToIpStrMap)
    {
        SPDLOG_LOGGER_TRACE(Logger::instance(), "{} -> {}", dpid, ip);
    }

    SPDLOG_LOGGER_TRACE(Logger::instance(), "=== m_dpidStrToIpStrMap ===");
    for (const auto& [dpidStr, ip] : m_dpidStrToIpStrMap)
    {
        SPDLOG_LOGGER_TRACE(Logger::instance(), "{} -> {}", dpidStr, ip);
    }

    SPDLOG_LOGGER_TRACE(Logger::instance(), "=== m_ipStrToDpidMap ===");
    for (const auto& [ip, dpid] : m_ipStrToDpidMap)
    {
        SPDLOG_LOGGER_TRACE(Logger::instance(), "{} -> {}", ip, dpid);
    }

    SPDLOG_LOGGER_TRACE(Logger::instance(), "=== m_ipStrToDpidStrMap ===");
    for (const auto& [ip, dpidStr] : m_ipStrToDpidStrMap)
    {
        SPDLOG_LOGGER_TRACE(Logger::instance(), "{} -> {}", ip, dpidStr);
    }
}

uint64_t
TopologyAndFlowMonitor::hashDstIp(const std::string& str)
{
    unsigned char hash[SHA256_DIGEST_LENGTH];
    SHA256(reinterpret_cast<const unsigned char*>(str.c_str()), str.size(), hash);

    uint64_t result = 0;
    for (int i = 0; i < 8; ++i)
    {
        result = (result << 8) | hash[i];
    }
    return result;
}

std::vector<sflow::Path>
TopologyAndFlowMonitor::bfsAllPathsToDst(
    const Graph& g,
    Graph::vertex_descriptor dstSwitch,
    const uint32_t& dstIp,
    const std::vector<uint32_t>& allHostIps,
    std::unordered_map<uint64_t, std::vector<std::tuple<uint32_t, uint32_t, uint32_t, uint32_t>>>&
        newOpenflowTables)
{
    constexpr uint32_t kHostMask = 0xFFFFFFFFu; // /32
    constexpr uint32_t kPriority = 100;

    auto ruleExists = [](const auto& flowTable, uint32_t net, uint32_t mask, uint32_t pri) {
        return std::any_of(flowTable.begin(), flowTable.end(), [&](const auto& entry) {
            return std::get<0>(entry) == net && std::get<1>(entry) == mask &&
                   std::get<3>(entry) == pri; // include priority in identity
        });
    };

    std::unordered_map<Graph::vertex_descriptor, Graph::vertex_descriptor> parent;
    std::unordered_map<Graph::vertex_descriptor, bool> visited;
    std::queue<Graph::vertex_descriptor> q;

    visited[dstSwitch] = true;
    Graph::vertex_descriptor NULL_NODE = Graph::null_vertex();
    parent[dstSwitch] = NULL_NODE;
    q.push(dstSwitch);

    // BFS
    while (!q.empty())
    {
        Graph::vertex_descriptor current = q.front();
        q.pop();

        Graph::vertex_descriptor prev = parent[current];

        if (prev != NULL_NODE)
        {
            auto edgePair = boost::edge(current, prev, g);
            if (edgePair.second)
            {
                const auto& edgeProps = g[edgePair.first];

                uint64_t dpid = g[current].dpid;           // switch that will install the rule
                uint32_t outPort = edgeProps.srcInterface; // port on *current* leading to prev
                                                           // (depends on your edge model)

                if (dpid != 0)
                {
                    auto& flowTable = newOpenflowTables[dpid];

                    uint32_t net = dstIp & kHostMask;
                    uint32_t mask = kHostMask;

                    if (!ruleExists(flowTable, net, mask, kPriority))
                    {
                        flowTable.emplace_back(net, mask, outPort, kPriority);
                        SPDLOG_LOGGER_INFO(
                            Logger::instance(),
                            "Added OF rule on switch {} for {} /32 -> outPort {} (pri={})",
                            dpid,
                            utils::ipToString(net),
                            outPort,
                            kPriority);
                    }
                }
            }
        }

        // neighbor discovery
        std::vector<Graph::vertex_descriptor> neighbors;
        for (auto edge : boost::make_iterator_range(boost::out_edges(current, g)))
        {
            Graph::vertex_descriptor neighbor = boost::target(edge, g);

            if (!isUsable(g[neighbor]))
            {
                continue;
            }
            if (!isUsable(g[edge]))
            {
                continue;
            }
            if (visited[neighbor])
            {
                continue;
            }

            neighbors.push_back(neighbor);
        }

        std::sort(neighbors.begin(),
                  neighbors.end(),
                  [this, &dstIp, &g](const auto& a, const auto& b) {
                      std::string combinedA = utils::ipToString(dstIp) + std::to_string(g[a].dpid);
                      std::string combinedB = utils::ipToString(dstIp) + std::to_string(g[b].dpid);
                      return hashDstIp(combinedA) < hashDstIp(combinedB);
                  });

        for (Graph::vertex_descriptor neighbor : neighbors)
        {
            parent[neighbor] = current;
            visited[neighbor] = true;
            q.push(neighbor);
        }
    }

    // Path reconstruction (mostly unchanged)
    std::vector<sflow::Path> allPaths;

    for (const auto& srcIp : allHostIps)
    {
        if (srcIp == dstIp)
        {
            continue;
        }

        auto srcHostOpt = findVertexByIp(srcIp);
        if (!srcHostOpt.has_value())
        {
            continue;
        }

        sflow::Path path;
        uint32_t srcOutPort = 0;
        Graph::vertex_descriptor srcSwitch;

        auto edgeOpt = findEdgeByHostIp(srcIp);
        if (edgeOpt)
        {
            srcSwitch = boost::target(edgeOpt.value(), g);
            srcOutPort = g[edgeOpt.value()].dstInterface;
        }
        else
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "No edge found for host IP {}", srcIp);
            continue;
        }

        if (!visited[srcSwitch])
        {
            continue;
        }

        path.emplace_back(srcIp, srcOutPort);

        Graph::vertex_descriptor v = srcSwitch;
        while (v != dstSwitch)
        {
            Graph::vertex_descriptor nextHop = parent[v];
            auto edgePair = boost::edge(v, nextHop, g);
            if (edgePair.second)
            {
                uint64_t nodeId = g[v].dpid;
                uint32_t outPort = g[edgePair.first].srcInterface;
                path.emplace_back(nodeId, outPort);
            }
            v = nextHop;
        }

        // ---- FIXED dstSwitch -> dstHost edge handling ----
        auto dstHostOpt = findVertexByIp(dstIp);
        if (!dstHostOpt.has_value())
        {
            continue;
        }

        auto edgePair = boost::edge(dstSwitch, dstHostOpt.value(), g);
        if (edgePair.second)
        {
            uint32_t outPortToHost = g[edgePair.first].srcInterface;

            path.emplace_back(g[dstSwitch].dpid, outPortToHost);

            // also store rule on dstSwitch
            auto& flowTable = newOpenflowTables[g[dstSwitch].dpid];
            uint32_t net = dstIp & kHostMask;
            uint32_t mask = kHostMask;

            if (!ruleExists(flowTable, net, mask, kPriority))
            {
                flowTable.emplace_back(net, mask, outPortToHost, kPriority);
                SPDLOG_LOGGER_INFO(Logger::instance(),
                                   "Added OF rule on switch {} for {} /32 -> outPort {} (pri={})",
                                   g[dstSwitch].dpid,
                                   utils::ipToString(net),
                                   outPortToHost,
                                   kPriority);
            }
        }
        // -----------------------------------------------

        path.emplace_back(dstIp, 0);
        allPaths.push_back(std::move(path));
    }

    return allPaths;
}

json
TopologyAndFlowMonitor::getStaticTopologyJson()
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Processing static topology json file request");
    std::shared_lock lock(*m_graphMutex);
    json result;
    try
    {
        result["nodes"] = json::array();
        result["edges"] = json::array();

        auto graph = *m_graph;
        // Nodes
        for (auto vd : boost::make_iterator_range(boost::vertices(graph)))
        {
            auto& v = graph[vd];
            if (v.vertexType == VertexType::SWITCH)
            {
                if (m_mode == utils::DeploymentMode::TESTBED)
                {
                    // [Co-developed with claude code -- Adam]
                    // The switch's own plug assignment, read from the topology file, not the
                    // constant {"172.25.166.135", 3} that used to be emitted for every switch --
                    // that pair is s2's, and on real hardware a consumer trusting this endpoint
                    // would have power-cycled one wrong outlet for all ten switches. The
                    // duplicate {"brand_name", v.brandName} that appeared twice in this
                    // initialiser is also gone; nlohmann just overwrote it, so it was dead.
                    result["nodes"].push_back({{"ip", utils::ipToString(v.ip)},
                                               {"dpid", v.dpid},
                                               {"mac", v.mac},
                                               {"vertex_type", v.vertexType},
                                               {"device_name", v.deviceName},
                                               {"brand_name", v.brandName},
                                               {"device_layer", v.deviceLayer},
                                               {"smart_plug_ip", v.smartPlugIp},
                                               {"smart_plug_outlet", v.smartPlugOutlet}});
                }
                else
                {
                    result["nodes"].push_back({{"ip", utils::ipToString(v.ip)},
                                               {"dpid", v.dpid},
                                               {"mac", v.mac},
                                               {"vertex_type", v.vertexType},
                                               {"device_name", v.deviceName},
                                               {"bridge_name", v.bridgeNameForMininet},
                                               {"brand_name", v.brandName},
                                               {"device_layer", v.deviceLayer},
                                               {"smart_plug_ip", v.smartPlugIp},
                                               {"smart_plug_outlet", v.smartPlugOutlet}});
                }
            }
            else
            {
                result["nodes"].push_back({{"ip", utils::ipToString(v.ip)},
                                           {"dpid", v.dpid},
                                           {"mac", v.mac},
                                           {"vertex_type", v.vertexType},
                                           {"device_name", v.deviceName},
                                           {"brand_name", v.brandName},
                                           {"device_layer", v.deviceLayer},
                                           {"brand_name", v.brandName}});
            }
        }

        // Edges
        for (auto ed : boost::make_iterator_range(boost::edges(graph)))
        {
            auto& e = graph[ed];

            result["edges"].push_back({{"link_bandwidth_bps", e.linkBandwidth},
                                       {"src_ip", utils::ipToString(e.srcIp)},
                                       {"src_dpid", e.srcDpid},
                                       {"src_interface", e.srcInterface},
                                       {"dst_ip", utils::ipToString(e.dstIp)},
                                       {"dst_dpid", e.dstDpid},
                                       {"dst_interface", e.dstInterface}});
        }

        SPDLOG_LOGGER_INFO(Logger::instance(), "get static topo file success");
    }
    catch (const exception& e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Exception in get_graph_data: {}", e.what());
    }
    // [Co-developed with claude code -- Adam]
    // `result`, not `result.dump(2)`. The declared return type is json, and dumping here made
    // this function return a json *string value* whose content happens to be JSON -- the same
    // shape that was just fixed in getPathBetweenHostsJson, except there it was only the error
    // paths and here it was every path.
    //
    // The wire was never wrong, which is why it survived: the sole caller assigns straight into
    // res.body(), a std::string, so nlohmann converted the string-valued json back to the text
    // it came from and the two conversions cancelled. Any caller that treated the result as the
    // object its signature promises got a string instead -- as a test written against the
    // signature immediately did. The caller now dumps, so the served bytes are unchanged.
    return result;
}

double
TopologyAndFlowMonitor::getAvgLinkUsage(const Graph& g) const
{
    int noneZeroEdgeNum = 0;
    double sum = 0.0;

    for (auto e : boost::make_iterator_range(boost::edges(g)))
    {
        // [Co-developed with claude code -- Adam]
        // Was `if (!g[e].isUp)`: the only one of the six availability checks that did not take
        // the full intersection, so an administratively disabled link with residual traffic still
        // counted towards the average. Made consistent when adminDisabled was introduced -- an
        // operator who takes a link out of service should not see it in the utilisation figure
        // that Energy-Saving-App reads.
        if (!isUsable(g[e]))
        {
            continue;
        }
        // [Co-developed with claude code -- Adam]
        // Resolve against `g`, the graph we are iterating, not the member graph. Callers pass a
        // snapshot -- handleGetAvgLinkUsage passes getGraph(), which is a copy, precisely so it
        // does not hold the lock -- so mixing the two reads a graph this function was given no
        // lock for. It happens to work today only because adjacency_list's source()/target()
        // return the descriptor's stored endpoints and ignore the graph argument entirely; the
        // moment that stops being true it is an out-of-bounds vertex lookup.
        auto targetNode = boost::target(e, g);
        auto sourceNode = boost::source(e, g);
        if (g[e].linkBandwidthUsage != 0 && g[sourceNode].vertexType != VertexType::HOST &&
            g[targetNode].vertexType != VertexType::HOST)
        {
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "{} to {} linkBandwidthUsage {} linkBandwidth {}",
                               g[sourceNode].nickName,
                               g[targetNode].nickName,
                               g[e].linkBandwidthUsage,
                               g[e].linkBandwidth);
            noneZeroEdgeNum++;
            sum += (static_cast<double>(g[e].linkBandwidthUsage) /
                    static_cast<double>(g[e].linkBandwidth));
        }
    }

    if (!noneZeroEdgeNum)
    {
        return 0;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "none zero edge number {}", noneZeroEdgeNum);

    return sum / static_cast<double>(noneZeroEdgeNum);
}

json
TopologyAndFlowMonitor::getLinkBandwidthBetweenSwitches(const std::string& ip1_str,
                                                        const std::string& ip2_str)
{
    json result;
    std::shared_lock lock(*m_graphMutex); // Ensure thread-safe read access to the graph

    // 1. Convert string IPs to uint32_t and find the corresponding vertices in the graph.
    // We use the "NoLock" versions of find functions because we already hold a lock.
    uint32_t ip1 = utils::ipStringToUint32(ip1_str);
    uint32_t ip2 = utils::ipStringToUint32(ip2_str);

    auto v1_opt = findSwitchByIpNoLock(ip1);
    auto v2_opt = findSwitchByIpNoLock(ip2);

    // 2. Handle cases where one or both switches are not found in the topology.
    if (!v1_opt.has_value() || !v2_opt.has_value())
    {
        result["error"] = "One or both switches could not be found in the topology.";
        if (!v1_opt.has_value())
        {
            result["missing_devices"].push_back(ip1_str);
        }
        if (!v2_opt.has_value())
        {
            result["missing_devices"].push_back(ip2_str);
        }
        return result;
    }

    auto v1 = *v1_opt;
    auto v2 = *v2_opt;

    // 3. Find the directed edge between the two switches.
    // A physical link consists of two directed edges in the graph.
    auto edge_pair_1_to_2 = boost::edge(v1, v2, *m_graph);

    // 4. Handle the case where no direct link exists.
    if (!edge_pair_1_to_2.second) // .second is a bool indicating if the edge was found
    {
        result["error"] = "No direct link found between the specified switches.";
        result["from"] = ip1_str;
        result["to"] = ip2_str;
        return result;
    }

    // 5. If a link exists, get the edges for both directions.
    auto edge1_to_2 = edge_pair_1_to_2.first;
    // [Co-developed with claude code -- Adam]
    // `.second` checked here for the same reason it is checked four lines above, where it was
    // the only one of the pair that was. A physical link is two directed edges, but nothing
    // guarantees the graph holds both: the topology file could declare one direction, and
    // updateLinks only ever adds. When the reverse was absent, `.first` was a singular
    // descriptor and `(*m_graph)[edge2_to_1]` read whatever it addressed -- so the reverse
    // direction of this report was built on an invalid edge, with no error anywhere.
    auto edge_pair_2_to_1 = boost::edge(v2, v1, *m_graph);
    if (!edge_pair_2_to_1.second)
    {
        result["error"] = "Only one direction of this link exists in the topology.";
        result["from"] = ip1_str;
        result["to"] = ip2_str;
        result["missing_direction"] = ip2_str + "_to_" + ip1_str;
        return result;
    }
    auto edge2_to_1 = edge_pair_2_to_1.first;

    const auto& props1 = (*m_graph)[edge1_to_2];
    const auto& props2 = (*m_graph)[edge2_to_1];

    // 6. Populate the JSON object with the link's bandwidth information.
    result["link_found"] = true;
    result["status"] = isUsable(props1) ? "up" : "down";

    // Direction from switch 1 to switch 2
    result[ip1_str + "_to_" + ip2_str] = {{"total_bandwidth_bps", props1.linkBandwidth},
                                          {"used_bandwidth_bps", props1.linkBandwidthUsage},
                                          {"utilization", props1.linkBandwidthUtilization},
                                          {"source_port", props1.srcInterface},
                                          {"destination_port", props1.dstInterface}};

    // Direction from switch 2 to switch 1
    result[ip2_str + "_to_" + ip1_str] = {{"total_bandwidth_bps", props2.linkBandwidth},
                                          {"used_bandwidth_bps", props2.linkBandwidthUsage},
                                          {"utilization", props2.linkBandwidthUtilization},
                                          {"source_port", props2.srcInterface},
                                          {"destination_port", props2.dstInterface}};

    return result;
}

json
TopologyAndFlowMonitor::getTopKCongestedLinksJson(int k)
{
    json result;
    if (k <= 0)
    {
        result["top_k_links"] = json::array();
        return result;
    }

    // Use the actual vertex descriptor type from your Graph definition.
    using VertexDescriptor = Graph::vertex_descriptor;

    struct LinkInfo
    {
        VertexDescriptor v1; // FIX: Use the defined type.
        VertexDescriptor v2; // FIX: Use the defined type.
        double max_utilization;

        // Comparison operator to sort links by utilization in descending order.
        bool operator<(const LinkInfo& other) const
        {
            return max_utilization > other.max_utilization;
        }
    };

    std::vector<LinkInfo> all_links;
    std::shared_lock lock(*m_graphMutex);

    auto edge_iter_pair = boost::edges(*m_graph);
    for (auto it = edge_iter_pair.first; it != edge_iter_pair.second; ++it)
    {
        auto edge = *it;
        VertexDescriptor src_v = boost::source(edge, *m_graph); // FIX: Use the defined type.
        VertexDescriptor dst_v = boost::target(edge, *m_graph); // FIX: Use the defined type.

        if (src_v < dst_v)
        {
            auto edge_rev_pair = boost::edge(dst_v, src_v, *m_graph);
            if (!edge_rev_pair.second)
            {
                continue;
            }

            const auto& props_fwd = (*m_graph)[edge];
            const auto& props_rev = (*m_graph)[edge_rev_pair.first];

            if (isUsable(props_fwd) && isUsable(props_rev))
            {
                double max_util = std::max(props_fwd.linkBandwidthUtilization,
                                           props_rev.linkBandwidthUtilization);
                all_links.push_back({src_v, dst_v, max_util});
            }
        }
    }

    std::sort(all_links.begin(), all_links.end());

    json links_array = json::array();
    size_t links_to_return = std::min(static_cast<size_t>(k), all_links.size());

    for (size_t i = 0; i < links_to_return; ++i)
    {
        const auto& link = all_links[i];
        auto v1 = link.v1;
        auto v2 = link.v2;

        std::string ip1_str = utils::ipToString((*m_graph)[v1].ip).front();
        std::string ip2_str = utils::ipToString((*m_graph)[v2].ip).front();

        auto edge1_to_2 = boost::edge(v1, v2, *m_graph).first;
        auto edge2_to_1 = boost::edge(v2, v1, *m_graph).first;
        const auto& props1 = (*m_graph)[edge1_to_2];
        const auto& props2 = (*m_graph)[edge2_to_1];

        json link_json;
        link_json["rank"] = i + 1;
        link_json["status"] = "up";

        // FIX: Removed extra semicolon from the end of the initializer list.
        link_json[ip1_str + "_to_"s + ip2_str] = {{"total_bandwidth_bps", props1.linkBandwidth},
                                                  {"used_bandwidth_bps", props1.linkBandwidthUsage},
                                                  {"utilization", props1.linkBandwidthUtilization},
                                                  {"source_port", props1.srcInterface},
                                                  {"destination_port", props1.dstInterface}};

        // FIX: Removed extra semicolon from the end of the initializer list.
        link_json[ip2_str + "_to_"s + ip1_str] = {{"total_bandwidth_bps", props2.linkBandwidth},
                                                  {"used_bandwidth_bps", props2.linkBandwidthUsage},
                                                  {"utilization", props2.linkBandwidthUtilization},
                                                  {"source_port", props2.srcInterface},
                                                  {"destination_port", props2.dstInterface}};

        links_array.push_back(link_json);
    }

    result["top_k_links"] = links_array;
    return result;
}

void
TopologyAndFlowMonitor::flushEdgeFlowLoop()
{
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "flushEdgeFlowLoop started");

    while (m_running.load())
    {
        // prune under graph lock
        {
            std::unique_lock lock(*m_graphMutex);
            for (auto e : boost::make_iterator_range(boost::edges(*m_graph)))
            {
                auto& edge = (*m_graph)[e];
                for (auto it = edge.flowSet.begin(); it != edge.flowSet.end();)
                {
                    const auto& k = it->first;   // FlowKey
                    const auto& ts = it->second; // last_seen
                    if (Clock::now() - ts > std::chrono::seconds(2))
                    {
                        SPDLOG_LOGGER_TRACE(Logger::instance(),
                                            "TTL expire flow {} -> {} on edge {}->{}",
                                            utils::ipToString(k.srcIP),
                                            utils::ipToString(k.dstIP),
                                            edge.srcDpid,
                                            edge.dstDpid);
                        it = edge.flowSet.erase(it);
                    }
                    else
                    {
                        ++it;
                    }
                }
            }
        }

        this_thread::sleep_for(chrono::milliseconds(1000));
    }

    SPDLOG_LOGGER_DEBUG(Logger::instance(), "flushEdgeFlowLoop stopped");
}

bool
TopologyAndFlowMonitor::touchEdgeFlow(Graph::edge_descriptor e, const sflow::FlowKey& key)
{
    std::unique_lock lk(*m_graphMutex);
    auto& mp = (*m_graph)[e].flowSet;
    auto now = Clock::now();

    auto [it, inserted] = mp.emplace(key, now);
    if (!inserted)
    {
        it->second = now; // refresh last_seen
    }
    return inserted; // true if it was newly added
}