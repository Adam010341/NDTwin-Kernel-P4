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

    /**
     * @brief Moves what a repeatedly-unusable switch carries to down, and says why.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md F-14 and F-16. The three discovery writers above assign `isUp = true`
     * at six sites and `false` at none, and the only writers of `false` anywhere in the process
     * are the power actuation paths, the liveness poll (switch vertices only -- see the comment
     * at DeviceConfigurationAndPowerManager.cpp:781) and `/ndt/link_failed`, which is keyed on a
     * pair of dpids and so cannot name a host-facing edge at all. Between them, no host vertex
     * and no host-facing edge had any path to `false`.
     *
     * What this does NOT do, and why. The obvious repair is to make the poll reconciling --
     * remember what the control plane reported this pass and take down whatever it stopped
     * reporting. That repair is unrunnable on the feed that matters: **both control planes'
     * host tables are append-only.** Ryu's `HostState` (ryu/topology/switches.py:190-200) is a
     * `setdefault` map with no timeout, whose only deletion path fires when a port turns out not
     * to be an edge port; the P4 proxy's graph says so in its own words at
     * p4_proxy/proxy_agent/topology_manager.py:539 -- "The graph is append-only -- nothing
     * anywhere calls remove_node/remove_edge". A host that has been unplugged for an hour is
     * still in both replies. Absence-based reconciliation would compile, would pass any unit
     * test that feeds it a reply with the host removed, and would never once fire against a real
     * control plane. On the links feed it would be worse than useless: a legal empty array from
     * a converging Ryu would take the whole graph down, which is the failure
     * kTopologyConnectTimeoutSeconds exists to prevent.
     *
     * So this derives instead of reconciling, from the one signal that *is* evidence-backed:
     * the switch's own liveness, which the 1 Hz poll writes through a three-state policy
     * (`ovsLivenessFor` / `p4LivenessFor`) where "could not tell" never writes the graph. A
     * vertex reading `isUp = false` therefore means some poll positively observed the switch
     * absent. Everything reachable only through such a switch is unreachable, and that is a
     * statement the twin is entitled to make.
     *
     * Recovery clears the reason but does **not** set anything back up: bringing a thing up is
     * discovery's job, because discovery has evidence for it. A derivation that both took
     * something down and put it back would be the seventh site in this file asserting liveness
     * it never observed.
     *
     * Called at the end of updateGraph, so within one pass the discovery writers run first and
     * this has the last word. Protected for the same reason as the writers above: the property
     * worth testing is what it does to a graph, and that needs no Ryu.
     */
    void reconcileDerivedLiveness();

    /**
     * @brief Consecutive topology polls a switch must be unusable before what it carries is
     *        taken down.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * The noise this guards against is not in the derivation, which has none -- it is in the
     * signal being derived from. `isUp = false` on a switch is a positive observation (the
     * bridge list was read and the bridge was absent), but a power cycle produces a real one
     * between `del-br` and `add-br`, and so does a bmv2 restart.
     *
     * Two, not one, because one would let that window isolate a dozen hosts and put them back
     * a poll later. Two, not more, because the poll is 5 s while converging and 30 s after
     * (run()), so two passes already span at least five independent 1 Hz liveness observations
     * -- and every extra pass is another 30 s in which an isolated host reads as connected,
     * which is the optimistic direction this whole family of defects lives in.
     *
     * Recovery is deliberately asymmetric at one pass: a switch that answers is unambiguous,
     * and being slow in that direction means reporting an outage that has ended.
     */
    static constexpr unsigned kMissesBeforeIsolating = 2;

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

    /**
     * @brief Builds the curl command for one topology endpoint.
     *
     * [Co-developed with claude code -- Adam]
     * Extracted for the same reason as DeviceConfigurationAndPowerManager::buildFlowStatsCommand:
     * the method around it needs a live control plane, so nothing inside it can be asserted, but
     * the wire format can -- and here the wire format *is* the fix. See
     * kTopologyConnectTimeoutSeconds for why both deadlines are on it.
     */
    static std::string buildTopologyFetchCommand(const std::string& url);

    /**
     * @brief Seconds curl may spend reaching the control plane before giving up on one request.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md A-2. This poll used to be three bare `curl -s` calls through
     * utils::execCommand, which is a plain popen(): no deadline anywhere, so an unresponsive
     * controller held the polling thread until the process exited. Measured once at 733 seconds
     * and still climbing -- the twin showed all 40 links down and 10 switches disabled while the
     * fabric forwarded at 0% loss, and nothing recovered it short of a restart.
     *
     * Two deadlines because they cover different failures, both observed in this repo:
     * connect-timeout is the one that bit FlowLinkUsageCollector, where a curl to a `localhost`
     * that resolved to an IPv6 loopback nobody was listening on took **131 seconds** because the
     * SYNs were dropped rather than refused; max-time bounds a control plane that accepts the
     * connection and then stalls mid-body, which is the shape of the Ryu wedge itself.
     *
     * 2 s and 5 s: the poll runs every 5 s while converging and every 30 s afterwards, and makes
     * three of these requests in sequence. A fully wedged control plane therefore costs at most
     * ~15 s per pass instead of the rest of the run. The comparable in-repo numbers are the 1 Hz
     * liveness poll's `--max-time 3` and this exact wedge's `--connect-timeout 2 --max-time 10`.
     */
    static constexpr int kTopologyConnectTimeoutSeconds = 2;
    /// @see kTopologyConnectTimeoutSeconds
    static constexpr int kTopologyRequestTimeoutSeconds = 5;

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

    /// Fetches one topology endpoint, bounded. Empty means it did not answer.
    /// [Co-developed with claude code -- Adam]
    std::string fetchTopologyEndpoint(const std::string& url);

    /// How many consecutive polling passes left at least one endpoint silent.
    ///
    /// [Co-developed with claude code -- Adam]
    /// Edge-triggered on purpose, the same shape as FailureRun in
    /// DeviceConfigurationAndPowerManager.hpp -- a persistent wedge is one warning, not one every
    /// poll. Not that class itself only because reusing it would pull that whole header into this
    /// one; the duplication is two lines and is noted here so it can be hoisted into utils/ later.
    /// Touched only by the polling thread.
    unsigned m_topologyFetchFailures = 0;

    /// dpid -> consecutive topology polls this switch has been unusable. Cleared the moment it is
    /// usable again. Touched only by reconcileDerivedLiveness, i.e. only by the polling thread --
    /// same ownership as m_topologyFetchFailures above, and for the same reason it needs no mutex.
    /// [Co-developed with claude code -- Adam]
    std::map<uint64_t, unsigned> m_switchUnusablePolls;

    /// Switch management addresses this run has already seen offered as hosts, so the warning is
    /// written once and not once every 5 to 30 seconds forever.
    ///
    /// [Co-developed with claude code -- Adam]
    /// Edge-triggered for the reason KeyedFailureLog exists in this repo at all: the condition is
    /// structural, not transient -- neither control plane's host table forgets anything -- so it
    /// holds for the life of the process, and a line that repeats for the life of the process is
    /// how a warning naming the exact misconfigured port ended up buried in 41 MB and unread.
    /// Never cleared, because there is no recovery anyone needs a second line about.
    /// Touched only by the polling thread.
    std::set<uint32_t> m_switchIpsOfferedAsHosts;

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
