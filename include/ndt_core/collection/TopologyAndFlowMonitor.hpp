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
     * This function loads the static topology **synchronously, on the caller's thread**, and only
     * then sets the running flag and spawns two background threads:
     * 1. The main monitoring thread (run) for fetching topology data.
     * 2. The flow flushing thread (flushEdgeFlowLoop) for cleaning up stale flows.
     *
     * [Co-developed with claude code -- Adam]
     * D15. The load used to be the first statement of `run()`, i.e. on the spawned thread, while
     * `start()` returned immediately -- so everything main.cpp sequences *after* `start()` raced
     * the JSON parse. Loading here makes "after start() returns, the switch-kind index is
     * populated" true by construction, at any file size. isStaticTopologyLoaded() is the
     * observable form of that postcondition.
     */
    void start();

    /**
     * @brief Whether the static topology load has completed.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * The postcondition of start(), and the precondition every consumer of getSwitchKindGroups()
     * actually needs. It exists because that precondition used to be asserted by a *comment*
     * ("the switch-kind index is populated by now") that was false on every shipped topology
     * file, and nothing could tell the difference between "all switches are bmv2" and "no
     * switches have been read yet" -- both answer with an empty or non-bmv2 group set.
     *
     * False until the load pass finishes, true afterwards, and it never goes back: the static
     * topology is loaded exactly once (loadStaticTopologyFromFile refuses a second load).
     */
    bool isStaticTopologyLoaded() const noexcept
    {
        return m_staticTopologyLoaded.load(std::memory_order_acquire);
    }

    /**
     * @brief Which thread performed the static topology load.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * The ordering itself, in a form that can be asserted rather than timed. "The topology is
     * loaded by the time start() returns" is only *usually* observable if the load is on another
     * thread -- a fast enough parse makes a racy implementation look correct, which is exactly
     * how D15 survived on small topology files. Who did the loading does not depend on speed:
     * equal to the caller's id means start() did it synchronously; anything else, including a
     * default-constructed id, means it did not.
     */
    std::thread::id staticTopologyLoadedOnThread() const noexcept
    {
        return m_staticTopologyLoadThread.load(std::memory_order_acquire);
    }

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

    // [Co-developed with claude code -- Adam]
    // A-4f. The sFlow sibling of the two above, and stored the same way for the same reason:
    // `ovs-vsctl del-br` destroys the bridge's sFlow record and the address on its agent
    // interface, so the graph has to hold them across the power cycle or they are gone.
    void setBridgeSflowState(Graph::vertex_descriptor v, SflowBridgeState state);
    SflowBridgeState getBridgeSflowState(Graph::vertex_descriptor v);
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

    /**
     * @brief Applies one poll's three replies and then re-derives what they cannot say.
     *
     * [Co-developed with claude code -- Adam]
     * Moved from private to protected alongside the writers it calls, for a reason a mutation
     * gate made concrete: with the derivation reachable only through this function, a test that
     * calls reconcileDerivedLiveness() directly proves the derivation works and proves nothing
     * about it being wired to anything. Deleting the call from the body left every test green.
     *
     * The ordering inside it is load-bearing -- the discovery writers raise, this lowers, and
     * lowering must come last -- so the ordering is the thing that needs a test, and this is the
     * only seam through which one can see it.
     */
    void updateGraph(const std::string&, const std::string&, const std::string&);

  public:
    /**
     * @brief What the last poll round was, in the shape /ndt/get_graph_data serves it.
     *
     * [Co-developed with claude code -- Adam]
     * The third channel of the A-2 fix, and the one the round-6 evidence
     * (doc/audit/2026-09-03_night-rounds/round6-bug-shapes/11_, 12_) showed was missing entirely:
     * with /links answering HTTP 500 the graph read 14/14 nodes and 40/40 edges up and the
     * response's top-level keys were exactly ["edges","nodes"] -- no field anywhere said the
     * round had been half-read. A log line only helps someone already reading the log; every
     * consumer of the graph reads this endpoint instead.
     *
     * Additive: a new top-level key on an object `tools/contract_test/spec.py:235` declares
     * non-strict (`schema.py:138`, `Obj(strict=False)` exists so "a kernel that *adds* a field is
     * not breaking anything"). Same additive rule the flow-table path used for `stale_since` /
     * `stale_polls` / `last_error`, and for the same reason: wrapping or reshaping breaks the two
     * out-of-repo consumers, adding a key breaks none of them.
     */
    json pollRoundJson() const;

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
     * @brief What separates the body from the HTTP status in one fetch's captured stdout.
     *
     * [Co-developed with claude code -- Adam]
     * `utils::execCommand` is a plain popen(): it hands back stdout and throws the exit status
     * away, so before this the status line was not merely ignored, it was unreachable. curl's
     * `--write-out` is the one channel that survives that, because it writes to the same stdout
     * the body does. The marker is deliberately not JSON and deliberately long: it is split on
     * from the RIGHT, so a body that happens to contain it still cannot move the split.
     *
     * `%{http_code}` is 000 when curl never got a status line at all -- refused connection,
     * DNS failure, or either of the two deadlines -- which is exactly the case that was already
     * being detected by the empty body, so the two agree rather than compete.
     */
    static constexpr const char* kHttpStatusSentinel = "@@ndt-topology-http-status@@";

    /**
     * @brief How one endpoint's reply turned out.
     *
     * [Co-developed with claude code -- Adam]
     * Round 6 finding N1 (doc/audit/2026-09-03_night-rounds/round6-bug-shapes/14_SUMMARY.log):
     * the test was `!body.empty()` and nothing else, so an HTTP 500 with a JSON error body, a 200
     * carrying a JSON object instead of an array, and a 200 carrying `<html>not json</html>` all
     * counted as answered and the round was recorded Complete. Measured, each arm held for at
     * least three poll intervals; only a genuinely empty body ever went red.
     *
     * The vocabulary is the flow-table path's, on purpose -- `no_response`, `reported_failure`,
     * `unparseable` are spelled exactly as `StaleTableCarryForward.hpp` spells them, so a consumer
     * or a scraper that already switches on one path's tokens needs no second table for this one.
     * `wrong_shape` is new to both and is added to both (see classifyFlowStatsReply): it is the
     * case where the body parses and is still not the thing the endpoint promised.
     */
    enum class EndpointOutcome
    {
        Ok,              ///< 2xx, non-empty, parses, and is the JSON array the endpoint promises.
        NoResponse,      ///< Nothing came back at all: status 000, or an empty body.
        ReportedFailure, ///< The control plane answered, with a non-2xx status.
        Unparseable,     ///< 2xx, non-empty, and not JSON.
        WrongShape       ///< 2xx and valid JSON, but not the array this endpoint must return.
    };

    /// @see EndpointOutcome. Kept as literals a runbook can grep, next to the enum they name.
    static constexpr const char* kOutcomeOk = "ok";
    static constexpr const char* kOutcomeNoResponse = "no_response";
    static constexpr const char* kOutcomeReportedFailure = "reported_failure";
    static constexpr const char* kOutcomeUnparseable = "unparseable";
    static constexpr const char* kOutcomeWrongShape = "wrong_shape";

    /// The token for @p outcome. Never a sentence: this is what lands in the API and the log.
    static const char* endpointOutcomeToken(EndpointOutcome outcome);

    /**
     * @brief One endpoint's reply, after the status has been read.
     *
     * [Co-developed with claude code -- Adam]
     * `body` is empty unless the reply is usable, and that is the load-bearing part: it is what
     * lets every writer downstream keep the early-return-on-empty behaviour it already had, so a
     * 500's error body is no longer fed to updateLinks. Before this it was -- the only trace a
     * 500 /links left in the log was 16 lines of "ignoring a links entry with no src/dst
     * endpoint", which reads like a malformed fabric rather than a failed read.
     */
    struct EndpointReply
    {
        std::string body;
        long httpStatus{0};
        EndpointOutcome outcome{EndpointOutcome::NoResponse};

        bool usable() const { return outcome == EndpointOutcome::Ok; }
    };

    /**
     * @brief Splits one fetch's captured stdout into body + status and judges it.
     *
     * [Co-developed with claude code -- Adam]
     * Pure and static for the same reason as buildTopologyFetchCommand: the method around it
     * needs a live control plane, so nothing inside it can be asserted, but this rule can -- and
     * this rule is the fix. Feed it what curl printed; it decides which of the five outcomes the
     * endpoint produced.
     *
     * 🔴 `[]` stays an answer. A 200 carrying two bytes of empty JSON array is Ok, not
     * NoResponse and not WrongShape: an OVS fabric answers exactly that on all three endpoints
     * until LLDP has finished discovering, which is every boot, and calling it a fault is the
     * mistake this file has already made once in the other direction.
     */
    static EndpointReply classifyEndpointReply(const std::string& rawCurlOutput);

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

    /**
     * @brief How much of one control-plane poll round answered.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md A-2, the third explicitly uncovered item. One round fetches switches,
     * hosts and links as three separate requests, and updateSwitches/updateHosts/updateLinks each
     * return early on an empty body -- so a round where only some endpoints answer still applies
     * the part that did, leaving a graph assembled from replies of two different ages.
     *
     * That application policy is deliberately UNCHANGED. See noteAndAnnouncePollRound for why
     * all-or-nothing is the wrong direction for this particular bug. What was missing is that the
     * mixed-age graph was indistinguishable from one a complete round produced: nothing in the
     * log and nothing in this object said which of the two had just happened.
     */
    enum class PollRoundKind
    {
        /// No round has finished yet. The initial value, and never a classification result --
        /// starting at Silent would report a wedge before the first request had been made.
        NotYetPolled,
        /// All three endpoints were READ: 2xx, parsed, and the promised array. Until round 6
        /// this said "produced a body", and that is the defect -- a 500 produces a body.
        Complete,
        Partial, ///< At least one endpoint was read and at least one was not.
        /// None was read. Note this now covers a control plane answering 500 on all three, which
        /// is not silence; the endpoint-level tokens carry that distinction and the log line
        /// beside m_topologyFetchFailures still separates the two by naming the reason.
        Silent
    };

    /**
     * @brief Classifies one round from whether each endpoint produced a body.
     *
     * [Co-developed with claude code -- Adam]
     * Pure and static for the same reason as buildTopologyFetchCommand: the method around it
     * needs a live control plane, so nothing inside that method can be asserted, but this rule
     * can. Never returns NotYetPolled -- a finished round is one of the other three.
     */
    static PollRoundKind classifyPollRound(EndpointOutcome switches,
                                           EndpointOutcome hosts,
                                           EndpointOutcome links);

    /**
     * @brief Whether this round earns the partial-round line, given what the previous round was.
     *
     * [Co-developed with claude code -- Adam]
     * Edge-triggered, the same shape and for the same reason as m_topologyFetchFailures: this
     * poll repeats every 5-30 s forever, and a control plane that stays half-wedged must not
     * write a line per poll until the disk fills. A Silent round does not earn this line -- the
     * warning next to m_topologyFetchFailures already owns that case, and saying it twice would
     * make the two faults harder to tell apart rather than easier.
     */
    static bool shouldAnnouncePartialRound(PollRoundKind previous, PollRoundKind current);

    /**
     * @brief Records this round's completeness and announces a newly partial one.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * Takes the three reply bodies rather than reading them from the poll, so a test can drive it
     * with poll-shaped replies without standing up Ryu. Same seam pattern as the discovery
     * writers above.
     *
     * 🔴 An empty body and an empty JSON list are NOT the same thing, and this is the one place
     * the difference is decided. utils::execCommand returns curl's stdout and swallows its exit
     * status, so a request that timed out yields "" while a fabric that genuinely has no links
     * yields "[]" -- two bytes, and a perfectly good answer. An OVS fabric reports exactly that
     * for as long as LLDP has not finished discovering, which is every boot. Keying silence on
     * anything but `empty()` would turn that normal state into a reported fault, which is the
     * mistake this file has already made in the other direction once.
     *
     * @return this round's kind, which is also what lastPollRoundKind() will now report.
     */
    PollRoundKind noteAndAnnouncePollRound(const EndpointReply& switches,
                                           const EndpointReply& hosts,
                                           const EndpointReply& links);

    /**
     * @brief What the most recently finished poll round was; NotYetPolled before the first.
     *
     * [Co-developed with claude code -- Adam]
     * The readable half of the fix. The log line says a mixed-age graph was applied; this says so
     * to anything that can hold a reference to the monitor, which is what a test can check and
     * what a future /ndt/get_graph_data freshness field would read.
     */
    PollRoundKind lastPollRoundKind() const { return m_lastPollRoundKind; }

    /**
     * @brief The grep token on the partial-round line.
     *
     * [Co-developed with claude code -- Adam]
     * Named so a runbook, a log scraper and the test cannot drift apart -- but the test asserts
     * the literal as well as this constant, because a test that only compares against this symbol
     * would follow a rename and stay green while every existing scraper broke.
     */
    static constexpr const char* kPartialRoundToken = "topology-round-partial";

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

    /// Fetches one topology endpoint, bounded, and reads the status line as well as the body.
    /// [Co-developed with claude code -- Adam]
    EndpointReply fetchTopologyEndpoint(const std::string& url);

    /// The three roles, in the order m_ryuUrl holds them. Named rather than counted for the same
    /// reason the silent-endpoint list is: "hosts is unreadable" and "one of three is unreadable"
    /// are different messages. [Co-developed with claude code -- Adam]
    static constexpr std::array<const char*, 3> kEndpointRoles = {"switches", "hosts", "links"};

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

    /// Per-endpoint outcome of the last finished round, in kEndpointRoles order. Written by the
    /// polling thread, read by pollRoundJson() on an HTTP thread -- hence the mutex, which
    /// m_lastPollRoundKind does without only because a PollRoundKind is a word.
    /// [Co-developed with claude code -- Adam]
    struct EndpointRoundRecord
    {
        long httpStatus{0};
        EndpointOutcome outcome{EndpointOutcome::NoResponse};
    };
    std::array<EndpointRoundRecord, 3> m_lastRoundEndpoints{};
    mutable std::mutex m_pollRoundMutex;

    /// What the last finished poll round was. Read by lastPollRoundKind(), written by
    /// noteAndAnnouncePollRound(), and -- like m_topologyFetchFailures above -- touched only by
    /// the polling thread. [Co-developed with claude code -- Adam]
    PollRoundKind m_lastPollRoundKind = PollRoundKind::NotYetPolled;

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

    // [Co-developed with claude code -- Adam]
    // D15. Read by isStaticTopologyLoaded(); written once, at the end of start()'s synchronous
    // load pass. Release/acquire rather than relaxed: a reader that sees this true must also see
    // every m_dpidToSwitchKind write that preceded it, on whatever thread it is reading from.
    std::atomic<bool> m_staticTopologyLoaded{false};
    std::atomic<std::thread::id> m_staticTopologyLoadThread{};
};
