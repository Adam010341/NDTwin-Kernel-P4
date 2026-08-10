#pragma once

#include "common_types/GraphTypes.hpp" // for SwitchKind
#include "common_types/SFlowType.hpp" // for Path, CounterInfo, FlowInfo
#include "utils/Utils.hpp"            // for DeploymentMode
#include <atomic>                     // for atomic
#include <cstdint>                    // for uint32_t
#include <map>                        // for map
#include <memory>                     // for shared_ptr
#include <mutex>                      // for mutex
#include <nlohmann/json.hpp>          // for json
#include <shared_mutex>               // for shared_mutex
#include <string>                     // for string
#include <thread>                     // for thread
#include <unordered_map>              // for unordered_map
#include <utility>                    // for pair
#include <vector>                     // for vector

class DeviceConfigurationAndPowerManager; // lines 48-48
class EventBus;                           // lines 47-47
class FlowRoutingManager;                 // lines 46-46
class TopologyAndFlowMonitor;             // lines 45-45

namespace ndtClassifier
{
class Classifier;
struct FlowKey;
} // namespace ndtClassifier

namespace sflow
{

#define SFLOW_PORT 6343
#define BUFFER_SIZE 65535
#define FLOW_IDLE_TIMEOUT 15000 // milliseconds

struct Packet; // forward declare
template <typename T>
class SPSCQueue; // forward declare template

/**
 * @brief Collects sFlow samples and derives per-flow / per-link usage and paths.
 *
 * FlowLinkUsageCollector listens for sFlow datagrams (flow samples + counter samples),
 * maintains an in-memory flow table (m_flowInfoTable) and per-interface counter snapshots
 * (m_counterReports), and periodically computes average sending rates and other statistics.
 *
 * It also maintains a (src,dst) -> Path mapping and switch-count metadata, and can refresh
 * these paths after routing changes (e.g., OpenFlow entry modifications).
 *
 * Concurrency:
 *  - start()/stop() control background threads.
 *  - m_flowInfoTable is protected by a shared mutex (readers/writers).
 *  - counter report map and IF-index mapping are updated internally; callers should treat
 *    returned data as snapshots.
 *
 * Deployment modes:
 *  - Behavior may differ depending on m_mode (e.g., MININET vs TESTBED), such as how
 *    sampling rate or counter conversion is handled.
 */
class FlowLinkUsageCollector
{
  public:
    FlowLinkUsageCollector(std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
                           std::shared_ptr<FlowRoutingManager> flowRoutingManager,
                           std::shared_ptr<DeviceConfigurationAndPowerManager> deviceManager,
                           std::shared_ptr<EventBus> eventBusm,
                           int mode,
                           std::shared_ptr<ndtClassifier::Classifier> classifier);
    ~FlowLinkUsageCollector();

    /**
     * @brief Start sFlow reception and background maintenance threads.
     *
     * This function creates/opens a non-blocking UDP socket bound to SFLOW_PORT and
     * launches background threads for packet processing and maintenance.
     *
     * Threads started:
     *  - RX thread: polls/recvmmsg() to read sFlow datagrams in batches and dispatches
     *    them to per-worker queues (round-robin).
     *  - Worker threads (numWorkers): parse/process packets from their assigned queues.
     *  - Periodic maintenance: average-rate/link-usage calculation.
     *  - Idle-flow purge: removes stale flow entries.
     *  - Optional debug/testing tasks (if enabled).
     *
     * Queueing behavior:
     *  - Per-worker queues are bounded (queueCapacity).
     *  - The RX thread uses non-blocking enqueue (no waiting). If a target queue is full,
     *    the datagram is dropped at the application level and a drop counter is incremented,
     *    while the RX thread continues draining the socket to reduce kernel RX-buffer drops.
     *
     * @param numWorkers      Number of worker threads to spawn (defaults to hardware concurrency;
     * at least 1).
     * @param queueCapacity   Capacity of each per-worker queue (bounded buffering per worker).
     */
    void start(size_t numWorkers = std::thread::hardware_concurrency(),
               size_t queueCapacity = 1024);
    /**
     * @brief Stop all worker threads and close the sFlow socket.
     *
     * Signals threads to exit (m_running=false), joins them, and releases socket resources.
     * Safe to call during shutdown.
     */
    void stop();

    // TODO: Prevent to get the whole flow table
    /**
     * @brief Return a snapshot of the current flow table.
     *
     * The returned map is a copy of internal state, keyed by FlowKey with FlowInfo values.
     * Intended for external consumers (e.g., REST handlers) to query current flow statistics.
     *
     * @note Copying the whole table can be expensive for large workloads.
     *       Consider adding query filters or a "top-K" interface for production use.
     */
    std::unordered_map<FlowKey, FlowInfo, FlowKeyHash> getFlowInfoTable();

    nlohmann::json getFlowInfoJson();
    nlohmann::json getTopKFlowInfoJson(int k);

    /**
     * @brief Replace the entire (src,dst)->Path map using a vector of paths.
     *
     * Typically called after the topology monitor or routing manager produces updated
     * end-to-end paths.
     *
     * @param allPathsVector List of paths to be loaded into the internal map.
     */
    void setAllPaths(std::vector<sflow::Path> allPathsVector);
    std::map<std::pair<uint32_t, uint32_t>, Path> getAllPaths();
    /**
     * @brief Update the path for one specific (srcIp,dstIp) pair.
     *
     * @param ipPair (srcIp, dstIp)
     * @param path   Full path for that pair
     */
    /**
     * @brief Return all host IPs known to the collector / path map.
     *
     * Used by higher layers to enumerate endpoints for querying paths/stats.
     */
    std::vector<uint32_t> getAllHostIps();
    void printAllPathMap();

    /**
     * @brief Get the number of switches on the path between a (src,dst) pair.
     *
     * @param ipPair (srcIp,dstIp)
     * @return Optional switch count if the path is known; std::nullopt otherwise.
     */
    std::optional<size_t> getSwitchCount(std::pair<uint32_t, uint32_t> ipPair);
    /**
     * @brief Return a snapshot of all computed switch counts for all (src,dst) pairs.
     *
     * @return Map from (srcIp,dstIp) to switch count.
     */
    std::map<std::pair<uint32_t, uint32_t>, size_t> getAllSwitchCounts();

    json getPathBetweenHostsJson(const std::string& srcHostName, const std::string& dstHostName);

  private:
    inline std::string ourIpToString(uint32_t ipFront, uint32_t ipBack);
    inline uint32_t ipFromFrontBack(uint32_t ipFront, uint32_t ipBack);
    void calAvgFlowSendingRatesPeriodically();
    void calAvgFlowSendingRatesImmediately();
    void testCalAvgFlowSendingRatesRandomly();
    void run(size_t numWorkers, size_t queueCapacity);

    /// @brief Opens and binds the sFlow receive socket. Called by start() on the caller's thread,
    ///        never from a std::thread entry point -- an exception out of one of those terminates
    ///        the process. Throws std::runtime_error if the port cannot be bound.
    void openReceiveSocket();

  protected:
    /**
     * @brief Chooses between identity and ovs-vsctl port mapping, once.
     *
     * Deliberately *not* called from start(). The topology is loaded by the monitor's own
     * thread, and measurement showed the collector reliably wins that race:
     *
     *     23:53:25.283  Collector Starts Up
     *     23:53:25.283  Populating ifIndex to OFPort map...     <- decided here
     *     23:53:25.283  Load Static Topology File
     *     23:53:25.286  Data plane: bmv2 (10 switch(es))        <- known only here
     *
     * So deciding in start() always saw an empty topology and always took the ovs-vsctl
     * branch -- which under bmv2 produced "Size: 0" and resolved every port to 0. Deferring
     * to the first lookup fixes it, because a sample cannot arrive before the network exists.
     *
     * [Co-developed with claude code -- Adam]
     */
    void configurePortMapping();

    /**
     * @brief host:port of the control plane that owns this data plane.
     *
     * @details
     * The P4 proxy for an all-bmv2 topology, Ryu otherwise. Resolved on each call rather than
     * cached at construction, because the switch kinds come from the topology file and that is
     * not loaded when this object is built.
     *
     * [Co-developed with claude code -- Adam]
     */
    std::string controlPlaneHostAndPort() const;

    /**
     * @brief Re-pulls the destination paths until they arrive, then keeps them fresh.
     *
     * @details
     * The one-shot call in start() cannot work on its own: it runs before the topology file is
     * loaded (a different thread does that) and before the control plane has finished LLDP
     * discovery, and `fetchAllDestinationPaths` silently returns on an empty response. So the
     * paths stayed empty for the whole run, and `get_path_switch_count` always answered "Path
     * not found".
     *
     * [Co-developed with claude code -- Adam]
     */
    void refreshDestinationPathsPeriodically();

    /**
     * @brief Translates an sFlow ifIndex to an OpenFlow port under a shared lock.
     *
     * Returns 0 for an unknown ifIndex, which callers already treat as "no port".
     * Unlike operator[] this never inserts, so it is safe to call concurrently from
     * the sFlow worker threads.
     *
     * Not const: the first call decides how the mapping works (see configurePortMapping).
     *
     * [Co-developed with claude code -- Adam]
     */
    uint32_t lookupOfport(uint32_t ifIndex);

    /**
     * @brief Whether ifIndex values can be used as port numbers without translation.
     *
     * The OVS path needs translation because sFlow reports kernel interface indices while the
     * rest of the kernel speaks OpenFlow port numbers, and `ovs-vsctl list interface` is what
     * relates the two. Under bmv2 there is no such indirection: the sFlow emitter in
     * p4_proxy/proxy_agent/sflow_emitter.py puts the P4 port straight into ifIndex, and
     * `ovs-vsctl` knows nothing about bmv2 interfaces, so it would return an empty map and
     * every port would resolve to 0 -- silently emptying link usage and flow paths.
     *
     * Only returns true when the topology positively says every switch is bmv2. An empty or
     * mixed topology keeps the ovs-vsctl behaviour, so nothing changes for existing setups.
     *
     * Static and taking the groups by argument so it is unit-testable without a live topology.
     *
     * [Co-developed with claude code -- Adam]
     */
    static bool usesIdentityPortMapping(
        const std::map<SwitchKind, std::vector<uint64_t>>& switchKindGroups);

    /**
     * @brief Parses one sFlow datagram.
     *
     * Protected so tests can feed it malformed datagrams directly. This is the kernel's
     * second external input surface -- the first being the /ndt/ HTTP API -- and the only
     * one reachable by anything that can send a UDP packet to port 6343, so its robustness
     * needs to be covered by tests rather than assumed.
     *
     * Never throws: a malformed datagram is logged and discarded.
     *
     * [Co-developed with claude code -- Adam]
     */
    void handlePacket(char* buffer, size_t len);

    /**
     * @brief Number of datagrams discarded as malformed since startup.
     *
     * Exposed so a test or a future metrics endpoint can assert that bad input was counted
     * rather than having to scrape the log, which is rate-limited.
     *
     * [Co-developed with claude code -- Adam]
     */
    uint64_t malformedDatagramCount() const
    {
        return m_malformedDatagrams.load(std::memory_order_relaxed);
    }

  private:
    /**
     * @brief Counts a malformed datagram and logs at most one per thousand.
     *
     * Unbounded logging on an unauthenticated UDP port is a denial-of-service vector in its
     * own right, so the count is always exact but the log volume is capped.
     *
     * [Co-developed with claude code -- Adam]
     */
    void reportMalformedDatagram(size_t len, const char* reason);

    std::atomic<uint64_t> m_malformedDatagrams{0};

    void purgeIdleFlows();
    void fetchAllDestinationPaths();
    void calFlowPathByQueried();
    void workerLoop(size_t qid);

    std::unordered_map<FlowKey, FlowInfo, FlowKeyHash> m_flowInfoTable;

    // key -> agent_ip and port
    // value -> last_report_time, last_received_input_octets and
    // last_received_output_octets, ...
    std::map<std::pair<uint32_t, uint32_t>, CounterInfo> m_counterReports;

    std::atomic<int> m_sockfd{-1};
    std::atomic<bool> m_running{false};

    std::thread m_pktRcvThread;
    std::thread m_calAvgFlowSendingRateThreadPeriodically;

    /**
     * @brief Re-pulls the destination paths periodically.
     *
     * [Co-developed with claude code -- Adam]
     */
    std::thread m_destinationPathRefreshThread;
    std::thread m_testCalAvgFlowSendingRatesRandomly;
    std::thread m_purgeThread;
    std::thread m_calFlowPathByQueried;

    mutable std::shared_mutex m_flowInfoTableMutex;

    std::shared_ptr<TopologyAndFlowMonitor> m_topologyAndFlowMonitor;
    std::shared_ptr<FlowRoutingManager> m_flowRoutingManager;
    std::shared_ptr<DeviceConfigurationAndPowerManager> m_deviceConfigurationAndPowerManager;
    std::shared_ptr<EventBus> m_eventBus;

    utils::DeploymentMode m_mode;

    void populateIfIndexToOfportMap();


    std::unordered_map<uint32_t, uint32_t> m_ifIndexToOfportMap;
    // Protects the map: exclusive while populating, shared for per-sample lookups.
    mutable std::shared_mutex m_ifIndexMapMutex;

    // Decided on the first lookup, then read by every sFlow worker. Atomic because the
    // deciding thread and the reading threads are not the same.
    std::atomic<bool> m_identityPortMapping{false};
    std::once_flag m_portMappingOnce;

    // key -> (src ip, dst ip), value -> full path
    std::map<std::pair<uint32_t, uint32_t>, Path> m_allPathMap;

    // calc the count of switch
    std::map<std::pair<uint32_t, uint32_t>, size_t> m_switchCountMap;
    mutable std::shared_mutex m_switchCountMapMutex;

    std::shared_ptr<ndtClassifier::Classifier> m_classifier;

    /// Signals the worker pool to finish and joins it. Idempotent. See the definition for why the
    /// join cannot live only at the end of run(). [Co-developed with claude code -- Adam]
    void stopAndJoinWorkers();

    std::vector<std::unique_ptr<SPSCQueue<Packet>>> m_queues;
    std::vector<std::thread> m_workers;
    std::atomic_uint32_t m_rr{0}; // round-robin index

    std::atomic_uint64_t receivedPacketNumFromSocket{0};
    std::atomic_uint64_t addresedSampleNum{0};

    mutable std::shared_mutex m_counterReportsMutex;
    mutable std::shared_mutex m_allPathMapMutex;
    mutable std::shared_mutex m_topologyMutex;
    std::atomic_uint64_t droppedPackets{0};
    std::atomic<uint64_t> m_sockOvflDrops{0};
};

} // namespace sflow
