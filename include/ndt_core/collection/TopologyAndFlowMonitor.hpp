#pragma once

#include "../setting/AppConfig.hpp"
#include "common_types/GraphTypes.hpp" // for Graph
#include "common_types/SFlowType.hpp"  // for FlowKey, Path
#include "utils/Utils.hpp"             // for DeploymentMode
#include <array>                       // for array
#include <atomic>                      // for atomic
#include <cstdint>                     // for uint32_t, uint64_t, int64_t
#include <map>                         // for map
#include <memory>                      // for shared_ptr
#include <mutex>                       // for mutex
#include <nlohmann/json.hpp>           // for json
#include <optional>                    // for optional
#include <set>                         // for set
#include <shared_mutex>                // for shared_mutex
#include <string>                      // for string, allocator
#include <thread>                      // for thread
#include <unordered_map>               // for unordered_map
#include <utility>                     // for pair
#include <vector>                      // for vector


static const std::string TOPOLOGY_FILE = AppConfig::TOPOLOGY_FILE;

static const std::string TOPOLOGY_FILE_MININET = AppConfig::TOPOLOGY_FILE_MININET;

static constexpr uint64_t EMPTY_LINK_THRESHOLD = 700000000;
static constexpr uint64_t MICE_FLOW_UNDER_THRESHOLD = 10000000;

using json = nlohmann::json;

class EventBus;

class TopologyAndFlowMonitor
{
  public:
    TopologyAndFlowMonitor(std::shared_ptr<Graph> graph,
                           std::shared_ptr<std::shared_mutex> graphMutex,
                           std::shared_ptr<EventBus> eventBus,
                           int mode);
    ~TopologyAndFlowMonitor();

    /**
     * @brief Starts the topology and flow monitoring services.
     *
     * This function sets the running flag to true and spawns two background threads:
     * 1. The main monitoring thread (run) for fetching topology data.
     * 2. The flow flushing thread (flushEdgeFlowLoop) for cleaning up stale flows.
     */
    void start();

    /**
     * @brief Destructor for the TopologyAndFlowMonitor class.
     *
     * Calls the stop() method to terminate the monitoring thread and the edge flow
     * flushing thread, ensuring a clean shutdown and proper resource release.
     */
    void stop();

    /**
     * @brief Loads and constructs the static network topology from a JSON configuration file.
     *
     * This function parses the specified JSON file to populate the internal graph structure
     * (`m_graph`). The process involves two main stages:
     * 1. **Nodes Parsing**: Iterates through the "nodes" array to create vertices (Switches or
     * Hosts), setting properties like DPID, MAC, IP, and device metadata. Special handling is
     * applied if the deployment mode is set to MININET (e.g., reading `bridge_name`).
     * 2. **Edges Parsing**: Iterates through the "edges" array to create connections between
     * vertices. Endpoints are resolved using DPID for switches or IP addresses for hosts.
     *
     * @param path The file system path to the JSON topology file.
     *
     * @note If the file cannot be opened, an error is logged and the function returns without
     * modifying the graph.
     * @note If an edge's source or destination cannot be resolved in the graph, the edge is skipped
     * and a warning is logged.
     */
    void logGraph();

    void updateLinkInfo(std::pair<uint32_t, uint32_t> agentIpAndPort,
                        uint64_t leftIn,
                        uint64_t leftOut,
                        uint64_t interfaceSpeed);

    void updateLinkInfoLeftLinkBandwidth(std::pair<uint32_t, uint32_t> agentIpAndPort,
                                         uint64_t estimatedIn);

    std::optional<Graph::vertex_descriptor> findVertexByIp(uint32_t ip) const;
    std::optional<Graph::vertex_descriptor> findVertexByIpNoLock(uint32_t ip) const;

    std::optional<Graph::edge_descriptor> findEdgeByAgentIpAndPort(
        const std::pair<uint32_t, uint32_t>& agentIpAndPort) const;
    std::optional<Graph::edge_descriptor> findEdgeByAgentIpAndPortNoLock(
        const std::pair<uint32_t, uint32_t>& agentIpAndPort) const;

    std::optional<Graph::edge_descriptor> findReverseEdgeByAgentIpAndPort(
        const std::pair<uint32_t, uint32_t>& agentIpAndPort) const;
    std::optional<Graph::edge_descriptor> findReverseEdgeByAgentIpAndPortNoLock(
        const std::pair<uint32_t, uint32_t>& agentIpAndPort) const;

    std::optional<std::pair<uint32_t, uint32_t>> getAgentKeyFromTheOtherSide(
        const std::pair<uint32_t, uint32_t>& agentIpAndPort) const;
    std::optional<std::pair<uint32_t, uint32_t>> getAgentKeyFromTheOtherSideNoLock(
        const std::pair<uint32_t, uint32_t>& agentIpAndPort) const;

    std::optional<Graph::edge_descriptor> findEdgeByDpidAndPort(
        std::pair<uint64_t, uint32_t> dpidAndPort) const;
    std::optional<Graph::edge_descriptor> findEdgeByDpidAndPortNoLock(
        std::pair<uint64_t, uint32_t> dpidAndPort) const;

    std::optional<Graph::edge_descriptor> findEdgeBySrcAndDstDpid(
        std::pair<uint64_t, uint64_t> srcDpidAndDstDpid) const;
    std::optional<Graph::edge_descriptor> findEdgeBySrcAndDstDpidNoLock(
        std::pair<uint64_t, uint64_t> srcDpidAndDstDpid) const;

    std::optional<Graph::edge_descriptor> findEdgeByHostIp(uint32_t hostIp) const;
    std::optional<Graph::edge_descriptor> findEdgeByHostIpNoLock(uint32_t hostIp) const;
    std::optional<Graph::edge_descriptor> findEdgeByHostIp(std::vector<uint32_t> hostIp) const;
    std::optional<Graph::edge_descriptor> findEdgeByHostIpNoLock(
        std::vector<uint32_t> hostIp) const;
    std::optional<Graph::edge_descriptor> findReverseEdgeByHostIp(uint32_t hostIp) const;
    std::optional<Graph::edge_descriptor> findReverseEdgeByHostIp(
        std::vector<uint32_t> hostIp) const;

    std::optional<Graph::edge_descriptor> findEdgeBySrcAndDstIp(uint32_t srcIp,
                                                                uint32_t dstIp) const;
    std::optional<Graph::edge_descriptor> findEdgeBySrcAndDstIpNoLock(uint32_t srcIp,
                                                                      uint32_t dstIp) const;

    void setEdgeDown(Graph::edge_descriptor e);
    void setEdgeDownNoLock(Graph::edge_descriptor e);
    void setEdgeUp(Graph::edge_descriptor e);
    void setEdgeUpNoLock(Graph::edge_descriptor e);
    void setEdgeEnable(Graph::edge_descriptor e);
    void setEdgeEnableNoLock(Graph::edge_descriptor e);
    void setEdgeDisable(Graph::edge_descriptor e);
    void setEdgeDisableNoLock(Graph::edge_descriptor e);
    void setVertexDown(Graph::vertex_descriptor v);
    void setVertexUp(Graph::vertex_descriptor v);
    bool getVertexIsUp(Graph::vertex_descriptor v);
    void setVertexEnable(Graph::vertex_descriptor v);
    void setVertexDisable(Graph::vertex_descriptor v);
    std::pair<uint64_t, uint32_t> getEdgeStats(Graph::edge_descriptor e) const;
    std::pair<uint64_t, uint32_t> getEdgeStatsNoLock(Graph::edge_descriptor e) const;
    std::set<sflow::FlowKey> getEdgeFlowSet(Graph::edge_descriptor e) const;
    std::set<sflow::FlowKey> getEdgeFlowSetNoLock(Graph::edge_descriptor e) const;
    Graph getGraph() const;
    void setVertexDeviceName(Graph::vertex_descriptor v, std::string name);
    void setVertexNickname(Graph::vertex_descriptor v, std::string name);
    bool getVertexIsEnabled(Graph::vertex_descriptor v);
    void setMininetBridgePorts(Graph::vertex_descriptor v, std::vector<std::string> ports);
    std::vector<std::string> getMininetBridgePorts(Graph::vertex_descriptor v);
    double getAvgLinkUsage(const Graph& g) const;

    std::optional<Graph::vertex_descriptor> findSwitchByDpid(uint64_t dpid) const;
    std::optional<Graph::vertex_descriptor> findSwitchByDpidNoLock(uint64_t dpid) const;

    /**
     * @brief Returns which data plane a switch runs, in O(1).
     *
     * Built once when the topology loads. Callers on the flow-install hot path use this
     * instead of getGraph() + findSwitchByDpid(): the former deep-copied the entire BGL
     * graph (every vertex string, ip vector and ecmp group) and the latter did an O(V)
     * scan, once per flow entry, from one worker thread per DPID.
     *
     * @return nullopt when the dpid is not a switch in the loaded topology. Callers must
     *         treat that as an error rather than defaulting to a data plane.
     *
     * [Co-developed with claude code -- Adam]
     */
    std::optional<SwitchKind> getSwitchKind(uint64_t dpid) const;

    /**
     * @brief The topology file this run actually uses.
     *
     * Single source of truth, honouring the NDTWIN_TOPO_FILE override. Every read and
     * every write of the topology JSON must go through this: the device-rename paths used
     * to hardcode the OVS file, so renaming a device while running the P4 fabric wrote
     * into the wrong topology.
     *
     * [Co-developed with claude code -- Adam]
     */
    std::string activeTopologyPath() const;

    /**
     * @brief Groups the loaded switches by data plane, for validation and logging.
     *
     * [Co-developed with claude code -- Adam]
     */
    std::map<SwitchKind, std::vector<uint64_t>> getSwitchKindGroups() const;

    /**
     * @brief Fails loudly when the loaded topology mixes data planes.
     *
     * The strategy dispatch is per-DPID and would happily drive a mixed fabric, but
     * nothing else in the stack is ready for one: a single Mininet run is either OVS or
     * bmv2, and the telemetry and liveness paths assume one kind. Validating here turns a
     * confusing runtime mixture into a clear startup error. Enabling mixed topologies
     * later means relaxing this check, not redesigning the dispatch.
     *
     * @param allowMixed when true, logs the mixture as a warning instead of failing.
     * @return true when the topology is acceptable.
     *
     * [Co-developed with claude code -- Adam]
     */
    bool validateDataPlaneHomogeneity(bool allowMixed) const;

    std::optional<Graph::vertex_descriptor> findSwitchByIp(uint32_t ip) const;
    std::optional<Graph::vertex_descriptor> findSwitchByIpNoLock(uint32_t ip) const;

    std::optional<Graph::vertex_descriptor> findVertexByMac(uint64_t mac) const;
    std::optional<Graph::vertex_descriptor> findVertexByMacNoLock(uint64_t mac) const;

    std::optional<Graph::vertex_descriptor> findVertexByMininetBridgeName(
        const std::string& name) const;
    std::optional<Graph::vertex_descriptor> findVertexByMininetBridgeNameNoLock(
        const std::string& name) const;

    std::optional<Graph::vertex_descriptor> findVertexByDeviceName(const std::string& name) const;
    std::optional<Graph::vertex_descriptor> findVertexByDeviceNameNoLock(
        const std::string& name) const;

    std::map<uint64_t, std::string> m_dpidToIpStrMap;
    std::map<std::string, std::string> m_dpidStrToIpStrMap;
    std::map<std::string, uint64_t> m_ipStrToDpidMap;
    std::map<std::string, std::string> m_ipStrToDpidStrMap;

    std::vector<sflow::Path> getAllPathsBetweenTwoHosts(sflow::FlowKey flowKey,
                                                        uint64_t swDpid,
                                                        uint64_t dstSwDpid);

    void disableSwitchAndEdges(uint64_t dpid);
    void enableSwitchAndEdges(uint64_t dpid);

    std::vector<sflow::Path> bfsAllPathsToDst(
        const Graph& g,
        Graph::vertex_descriptor dstSwitch,
        const uint32_t& dstIp,
        const std::vector<uint32_t>& allHostIps,
        std::unordered_map<uint64_t,
                           std::vector<std::tuple<uint32_t, uint32_t, uint32_t, uint32_t>>>&
            newOpenflowTables);

    json getStaticTopologyJson();

    // for llm
    json getLinkBandwidthBetweenSwitches(const std::string& dpid1, const std::string& dpid2);
    json getTopKCongestedLinksJson(int k);
    // for llm

    bool touchEdgeFlow(Graph::edge_descriptor e, const sflow::FlowKey& key);

  private:
    std::mutex m_configurationFileMutex;
    void run();

    void fetchAndUpdateTopologyData();
    void updateSwitches(const std::string& topologyData);
    void updateHosts(const std::string& topologyData);
    void updateLinks(const std::string& topologyData);
    void updateGraph(const std::string&, const std::string&, const std::string&);

  protected:
    /**
     * @brief Loads nodes and edges from a topology JSON.
     *
     * Protected rather than private so tests can load a purpose-built topology without
     * standing up the Ryu REST calls that fetchAndUpdateTopologyData performs. Same seam
     * pattern as IPowerStrategy::executeSystemCommand.
     *
     * [Co-developed with claude code -- Adam]
     */
    void loadStaticTopologyFromFile(const std::string& path);

  private:
    void initializeMappingsFromGraph();
    void flushEdgeFlowLoop();

    uint64_t hashDstIp(const std::string& str);

    std::array<std::string, 3> m_ryuUrl;

    std::atomic<bool> m_running{false};

    std::thread m_thread;
    std::thread m_flushEdgeFlowLoop;

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_graphMutex;
    std::shared_ptr<EventBus> m_eventBus;

    utils::DeploymentMode m_mode;

    // [Co-developed with claude code -- Adam]
    // dpid -> data plane, built once in loadStaticTopologyFromFile. Has its own mutex so
    // the flow-install hot path never contends with graph readers or writers.
    std::unordered_map<uint64_t, SwitchKind> m_dpidToSwitchKind;
    mutable std::shared_mutex m_switchKindMutex;
};
