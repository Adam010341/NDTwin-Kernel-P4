#pragma once

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
    void setAllPath(std::pair<uint32_t, uint32_t> ipPair, Path path);
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
    void handlePacket(char* buffer, size_t len);
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

    /**
     * @brief Translates an sFlow ifIndex to an OpenFlow port under a shared lock.
     *
     * Returns 0 for an unknown ifIndex, which callers already treat as "no port".
     * Unlike operator[] this never inserts, so it is safe to call concurrently from
     * the sFlow worker threads.
     *
     * [Co-developed with claude code -- Adam]
     */
    uint32_t lookupOfport(uint32_t ifIndex) const;

    std::unordered_map<uint32_t, uint32_t> m_ifIndexToOfportMap;
    // Protects the map: exclusive while populating, shared for per-sample lookups.
    mutable std::shared_mutex m_ifIndexMapMutex;

    // key -> (src ip, dst ip), value -> full path
    std::map<std::pair<uint32_t, uint32_t>, Path> m_allPathMap;

    // calc the count of switch
    std::map<std::pair<uint32_t, uint32_t>, size_t> m_switchCountMap;
    mutable std::shared_mutex m_switchCountMapMutex;

    std::shared_ptr<ndtClassifier::Classifier> m_classifier;

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
