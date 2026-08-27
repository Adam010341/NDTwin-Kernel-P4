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
#include <thread>
#include <tuple>                      // for thread
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
     * @brief Prints the current graph -- every vertex and edge -- to the log at DEBUG.
     *
     * Debug output only. Takes no arguments, reads nothing but `m_graph`, and modifies nothing.
     *
     * [Co-developed with claude code -- Adam]
     * This declaration used to carry a nineteen-line docblock describing
     * `loadStaticTopologyFromFile` -- node/edge parsing stages, `@param path`, the file-not-found
     * behaviour -- none of which has anything to do with a parameterless printer. The header's
     * public section therefore taught that `logGraph()` builds the graph from a file. The real
     * loader is declared further down, `protected`, with its own accurate comment.
     */
    void logGraph();

    void updateLinkInfo(std::pair<uint32_t, uint32_t> agentIpAndPort,
                        uint64_t leftIn,
                        uint64_t leftOut,
                        uint64_t interfaceSpeed);

    // [Co-developed with claude code -- Adam]
    // Takes BYTES and the interval they accumulated over, and does the bits-per-second
    // conversion itself. It used to take a finished bps figure, and both callers produced that
    // figure as `accumulator * 8` -- no division by anything. The rate loop's period is a second
    // of sleep PLUS the body, never exactly 1000 ms, so every published rate was overstated by
    // (real period / 1 s).
    //
    // WHY THE SIGNATURE CHANGED RATHER THAN THE CALL SITES. There are two call sites, and a
    // partial fix is worse than none: ticket Q's read-out table would show one edge class
    // corrected and another not, which reads as "further from 1" or "a third mechanism is
    // acting" -- both wrong verdicts pointing at problems that do not exist. Taking an argument
    // that did not exist before makes a missed call site a compile error instead.
    //
    // elapsedSeconds must be the interval between the PREVIOUS drain of the accumulator and this
    // one, not the loop's start-to-start period: the bytes accumulated over the former.
    void updateLinkInfoLeftLinkBandwidth(std::pair<uint32_t, uint32_t> agentIpAndPort,
                                         uint64_t accumulatedBytes,
                                         double elapsedSeconds);

    // The divisor the most recent call actually used. Ticket Q's acceptance gate asserts this
    // equals the independently measured interval for the same iteration, which is a check the
    // code can fail -- unlike "the loop period should read ~1000 ms", which stays true whether
    // or not the division was ever added.
    double lastRateDivisorSeconds() const { return m_lastRateDivisorSeconds.load(); }

    std::optional<Graph::vertex_descriptor> findVertexByIp(uint32_t ip) const;
    std::optional<Graph::vertex_descriptor> findVertexByIpNoLock(uint32_t ip) const;

    std::optional<Graph::edge_descriptor> findEdgeByAgentIpAndPort(
        const std::pair<uint32_t, uint32_t>& agentIpAndPort) const;
    std::optional<Graph::edge_descriptor> findEdgeByAgentIpAndPortNoLock(
        const std::pair<uint32_t, uint32_t>& agentIpAndPort) const;

    /// The edge leaving (agentIp, port), but only when its far end is a host (dstDpid == 0 --
    /// hosts carry no datapath id in this graph). Engaged for the last hop of a flow's path;
    /// nullopt for switch-to-switch edges and unknown ports.
    std::optional<Graph::edge_descriptor> findEdgeToHostByAgentIpAndPort(
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
     * @brief Sets the three `/v1.0/topology/` URLs (switches, hosts, links) from a base.
     *
     * [Co-developed with claude code -- Adam]
     */
    void setTopologyApiUrls(const std::string& base);

    /**
     * @brief The three URLs the topology poll will actually fetch: switches, hosts, links.
     *
     * [Co-developed with claude code -- Adam]
     * The read side of setTopologyApiUrls, and the only way to observe which control plane this
     * monitor is aimed at. It exists because the default used to be a file-local constant
     * hard-coding localhost:8080 rather than AppConfig::RYU_IP_AND_PORT, and no test could see
     * the difference -- the symptom of the bug was a poll that quietly fetched nothing, which
     * looks identical to a control plane with nothing to report.
     */
    const std::array<std::string, 3>& topologyApiUrls() const { return m_ryuUrl; }

    /**
     * @brief Aims the topology poll at Ryu or at the P4 proxy, based on the loaded switch kinds.
     *
     * @details
     * Must run after the topology file is loaded; calling it earlier always sees an empty graph
     * and silently keeps the Ryu default. Only an all-bmv2 topology is re-pointed.
     *
     * [Co-developed with claude code -- Adam]
     */
    void configureTopologyApiUrls();

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

    /// @return false when no switch in the graph carries that dpid, in which case nothing was
    ///         written. The caller answers an operator and must not report work it did not do.
    bool disableSwitchAndEdges(uint64_t dpid);
    bool enableSwitchAndEdges(uint64_t dpid);

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
    /**
     * @brief Bandwidth and status of the link between two switches, identified by **IP address**.
     *
     * [Co-developed with claude code -- Adam]
     * The parameters were named `dpid1`/`dpid2` here while the definition names them `ip1_str`/
     * `ip2_str` and parses them with `ipStringToUint32` + `findSwitchByIpNoLock`. Behaviour was
     * never wrong -- the one caller (IntentTranslator's GET_A_LINK_BANDWIDTH_UTILIZATION branch)
     * passes the result of `getSwitchIpByName` -- but it stores it in a variable called
     * `dpid1_opt` under a comment saying "Get the DPIDs", so every name on the path said dpid and
     * only the body said IP.
     * Renamed rather than left alone because it has already cost someone a wrong call: a test
     * written against this declaration passed dpids, landed in the not-found branch, and the reply
     * on that branch carries `error`/`missing_devices` and **no `status` key** at all.
     */
    json getLinkBandwidthBetweenSwitches(const std::string& switchIp1, const std::string& switchIp2);
    json getTopKCongestedLinksJson(int k);
    // for llm

    bool touchEdgeFlow(Graph::edge_descriptor e, const sflow::FlowKey& key);

  private:
    std::mutex m_configurationFileMutex;
    void run();

  protected:
    /**
     * @brief Applies one control-plane topology reply to the graph.
     *
     * Protected rather than private for the same reason as loadStaticTopologyFromFile below: these
     * are the discovery writers, and the property worth testing about them is what they must
     * *not* do -- overwrite an operator's `adminDisabled`. Driving them with a poll-shaped reply
     * is the only way to assert that without standing up Ryu.
     *
     * [Co-developed with claude code -- Adam]
     */
    void updateSwitches(const std::string& topologyData);
    void updateHosts(const std::string& topologyData);
    void updateLinks(const std::string& topologyData);

  private:
    void updateGraph(const std::string&, const std::string&, const std::string&);

  protected:
    /**
     * @brief Loads nodes and edges from a topology JSON.
     *
     * Protected rather than private so tests can load a purpose-built topology without
     * standing up the Ryu REST calls that pollControlPlaneTopology performs. Same seam
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

    /// (switches up, hosts up, edges up). Change signal for the polling loop in run().
    /// [Co-developed with claude code -- Adam]
    std::tuple<std::size_t, std::size_t, std::size_t> graphLivenessSummary() const;

    /// The REST poll alone, without re-reading the static topology file. See the implementation for
    /// why the two must not be repeated together. [Co-developed with claude code -- Adam]
    void pollControlPlaneTopology();

    std::atomic<bool> m_running{false};

    std::thread m_thread;
    std::thread m_flushEdgeFlowLoop;

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_graphMutex;
    std::shared_ptr<EventBus> m_eventBus;

    // [Co-developed with claude code -- Adam]
    // Written by updateLinkInfoLeftLinkBandwidth, read by ticket Q's acceptance gate. Starts at
    // a negative sentinel rather than 0: zero is a legal-looking divisor and would let "nobody
    // has published a rate yet" pass a gate that is checking the divisor was correct.
    std::atomic<double> m_lastRateDivisorSeconds{-1.0};

    utils::DeploymentMode m_mode;

    // [Co-developed with claude code -- Adam]
    // dpid -> data plane, built once in loadStaticTopologyFromFile. Has its own mutex so
    // the flow-install hot path never contends with graph readers or writers.
    std::unordered_map<uint64_t, SwitchKind> m_dpidToSwitchKind;
    mutable std::shared_mutex m_switchKindMutex;
};
