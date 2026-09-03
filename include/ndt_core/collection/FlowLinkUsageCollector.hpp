#pragma once

#include "common_types/GraphTypes.hpp" // for SwitchKind
#include "common_types/SFlowType.hpp" // for Path, CounterInfo, FlowInfo
#include "utils/Utils.hpp"            // for DeploymentMode
#include <chrono>
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

// [Co-developed with claude code -- Adam]
// Ticket M. How often calFlowPathByQueried re-derives every tracked flow's path, and therefore
// the freshness bound on the API's `path` field. It was 1 ms, which cost 46.31% of the kernel's
// CPU on one thread and was paid in full at the lowest sampling rate -- a fixed cost, not a
// per-sample one.
//
// It sits next to FLOW_IDLE_TIMEOUT because the pair is what matters, not either alone: a flow
// that starts and ends inside one interval never gets a path at all. At 1 ms that was
// impossible; at 1 s it needs a flow shorter than a second, which is ordinary. The ratio here
// is 1:15 against the idle timeout, so a flow that survives to be timed out has had at least a
// dozen chances -- but a short flow has not, and that is what ticket M's churn arm measures.
//
// Named rather than a literal so an arm can report which value it measured instead of citing a
// line number that moves. This file's own line numbers moved during ticket Q.
constexpr auto kFlowPathRecomputeInterval = std::chrono::seconds(1);

// [Co-developed with claude code -- Adam]
// KNOWN-ISSUES B-x. How stale a flow's most recent sample may be before the API stops calling it
// `active`. It sits beside FLOW_IDLE_TIMEOUT for the same reason kFlowPathRecomputeInterval does:
// the pair is what matters. FLOW_IDLE_TIMEOUT decides when a flow leaves the table; this decides
// when the API stops claiming it is sending. Everything between the two is `idle` -- retained, and
// labelled as retained.
//
// Why 3000 and not 1000. The value has to clear one full rate-loop period plus slack, because a
// live flow's freshness is bounded by how often samples arrive, and the loop that consumes them
// does not run at exactly 1 Hz. The loop prints its own period, and at 64 flows on 2026-08-25 the
// windowed mean was 1248.7 ms (the cumulative mean printed 1106.3 ms, which is the figure that
// used to be grepped and was systematically low -- see the note at FlowLinkUsageCollector.cpp
// :1901). A 1000 ms window would therefore flap on a continuously sending flow at ordinary table
// sizes, and a demo that alternates `active`/`idle` on a flow that never stopped is worse than
// one that over-reports. 3000 ms is ~2.4 measured periods of headroom while still recovering 12
// of the 15 seconds of tail.
//
// ⚠️ This bound is a claim about OBSERVATION, not about the world: `active` means "a sample
// reached us within 3 s", which is the only thing the twin can know. Under a low sampling rate a
// genuinely sending flow can miss that window. The failure direction is pessimistic (a live flow
// reported idle) rather than optimistic, which is the direction to prefer for a twin whose reason
// to exist is catching faults -- but it is a real cost, and it is the reason `?liveness=retained`
// exists for a caller that would rather over-report.
//
// Named rather than a literal so an arm can report which value it measured.
constexpr int64_t kFlowActiveWindowMs = 3000;

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

    /**
     * @brief Serialise the flow table, optionally dropping rows by liveness.
     *
     * [Co-developed with claude code -- Adam] KNOWN-ISSUES B-x.
     *
     * 🔴 The default is `All`, which is today's behaviour, and that is deliberate. The endpoint's
     * default lives in HttpSession, not here, so no in-repo caller of this function changes what
     * it receives without someone editing that call site. The two consumer classes want opposite
     * things and must not be served by one hidden default: a UI listing "active flows" is
     * embarrassed by every corpse, while the rate and routing paths read per-flow rates that are
     * already 0 for a dead flow and are unharmed by its presence. Breaking the second to please
     * the first is the failure mode this signature is shaped to prevent.
     *
     * Every row carries `liveness`, `last_seen_ms` and `ended_at_ms` in all three modes, so a
     * consumer that wants the whole population can still tell the classes apart. Adding fields is
     * contract-compatible: tools/contract_test's `Obj` is non-strict by default
     * (tools/contract_test/schema.py:129-138).
     */
    nlohmann::json getFlowInfoJson(sflow::FlowLivenessFilter filter = sflow::FlowLivenessFilter::All);
    nlohmann::json getTopKFlowInfoJson(int k,
                                       sflow::FlowLivenessFilter filter = sflow::FlowLivenessFilter::All);

    /**
     * @brief How many tracked flows are active, idle and ended, counted in one locked pass.
     *
     * Exists so a caller that only needs counts does not serialise the whole table to get them,
     * and so `active_flow_count` can mean active. [Co-developed with claude code -- Adam]
     */
    sflow::FlowLivenessCounts countFlowsByLiveness();

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
    // [Co-developed with claude code -- Adam]
    // The docblock for `setAllPath` (singular) used to float here, in front of an unrelated
    // declaration -- the method itself was removed from the .cpp (see the note there) for having
    // no callers and for writing m_allPathMap while leaving m_switchCountMap untouched, so the
    // first caller to use it would have made getSwitchCount answer from a path it no longer
    // matched. Only the .cpp half was deleted; the header half stayed and went on documenting an
    // API that does not exist, with exactly the single-pair semantics that motivated the removal.
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

    /**
     * @brief Is this link's reading a measurement, or an absence of one?
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * KNOWN-ISSUES A-4f, the half nobody could see. A switch that loses its sFlow record keeps
     * forwarding and keeps its links marked up, but stops producing samples -- so the edges
     * arriving at it publish exactly 0 bps for ever, which is bit-identical to an idle link and
     * to a kernel that started a moment ago. Three different worlds, one number.
     *
     * 🔑 There is a hard limit on what can be answered here and it is worth stating rather than
     * papering over. `polling=0` (testbed_topo.py:118-120, and correct: MININET discards counter
     * samples anyway) means an idle interface emits *nothing at all*. On the wire, one idle link
     * and one unsampled link are the same silence. The only signal above that noise floor is a
     * level up: whether the SAME AGENT is reporting on any of its other ports. So:
     *
     *   live    -- this (agent, ifIndex) reported inside `windowSeconds`
     *   idle    -- it did not, but the agent reported on some other port, so the agent is alive
     *              and this link's 0 IS a measurement
     *   silent  -- the agent reported on no port at all, so the 0 is an absence
     *   unknown -- that agent has never reported since this process started
     *
     * ⚠️ Known and deliberate false positive: a switch that is genuinely idle on every port
     * reads `silent`. That is the pessimistic direction -- healthy reported as broken -- which
     * KNOWN-ISSUES' own failure-direction axis ranks well below the silent one it replaces, and
     * the raw ages returned alongside let a reader overturn it on the spot.
     *
     * @param agentIp   The sampling agent, i.e. the edge's `dstIp` -- samples are keyed by the
     *                  ingress port of the switch the edge arrives at.
     * @param ifIndex   That switch's ingress port for this edge, i.e. the edge's `dstInterface`.
     * @param windowSeconds How stale a sample may be and still count as current.
     */
    struct LinkTelemetryStatus
    {
        /// One of "live", "idle", "silent", "unknown". A string because it crosses /ndt/.
        std::string status;
        /// Seconds since a sample was attributed to this (agent, ifIndex); -1 for never.
        double lastSampleAgeSeconds = -1.0;
        /// Seconds since a sample arrived from this agent on any port; -1 for never.
        double agentLastSampleAgeSeconds = -1.0;
    };
    LinkTelemetryStatus telemetryStatusFor(uint32_t agentIp,
                                           uint32_t ifIndex,
                                           double windowSeconds = 5.0) const;

    /**
     * @brief The four-way decision on its own, with no clock, no maps and no locks.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * Split out from telemetryStatusFor because the two halves are different kinds of thing and
     * only one of them has a judgement in it. The gathering half is two map lookups under a
     * shared lock; the deciding half is the whole claim this feature makes about when a 0 bps
     * reading may be trusted. Left inside, that claim would have been reachable from a test only
     * by standing up a collector, its monitor, its device manager and its classifier, and by
     * making real time pass -- so in practice it would not have been tested at all, and a
     * mutation that pinned every link to "live" would have survived the suite.
     *
     * Pure and static: every input is an argument, so a test states the exact instant it means.
     *
     * @param nowMillis                 Steady-clock reading to judge against.
     * @param portLastSampleMillis      Last sample on this (agent, ifIndex); 0 for never.
     * @param agentLastSampleMillis     Last sample from this agent on any port; 0 for never.
     * @param windowSeconds             How stale a sample may be and still count as current.
     */
    static LinkTelemetryStatus classifyTelemetry(int64_t nowMillis,
                                                 int64_t portLastSampleMillis,
                                                 int64_t agentLastSampleMillis,
                                                 double windowSeconds);

    /**
     * @brief The interval the last per-flow rate pass actually divided by, in seconds.
     *
     * [Co-developed with claude code -- Adam]
     *
     * The flow-side twin of TopologyAndFlowMonitor::lastRateDivisorSeconds(), and it exists for
     * the same reason: the acceptance criterion for a denominator fix is that the value used as
     * the divisor equals the interval measured independently for the same pass, and a criterion
     * that cannot be read from a running kernel is not a gate. Negative means no per-flow rate
     * has been published yet -- which is not a pass.
     */
    double lastFlowRateDivisorSeconds() const { return m_lastFlowRateDivisorSeconds.load(); }
     * @brief What the sFlow ingest did during the most recently *closed* rate window.
     *
     * @details
     * [Co-developed with claude code -- Adam] doc/audit/2026-09-03_night-rounds/
     * round4-traffic-measurement/SUMMARY.md, lead 5(b) and section 1.
     *
     * The four drop counters existed and were correct; they were reachable from none of the 105
     * JSON keys the kernel serves, so under a 72.5% socket-drop flood the twin reported a
     * 20 Mbit/s flow as 7.14 Mbit/s while every endpoint answered 200 `success`, every flow read
     * `active`, and `avg_link_usage` moved the wrong way. The only trace was 33 WARN lines in a
     * file no API consumer reads.
     *
     * 🔴 A drop count on its own is not actionable: `dropped_in_window: 41273` does not tell a
     * reader whether their measurement is usable. So this carries the DENOMINATOR over the same
     * window -- `offered_in_window` = what arrived plus what was lost -- and `samples_in_window`,
     * which is the count the rates in this response were actually computed from. `loss_fraction`
     * is derived from those two rather than stored, so it cannot disagree with them.
     *
     * `samples_in_window == 0` is also the steady-state channel `rx` never had: before this, the
     * ingest INFO line fired once per process and everything after it was TRACE, so from outside
     * "no warning" and "we have received nothing since boot" were the same observation.
     * `status` separates them: **"no_samples" is not "ok"**.
     */
    struct IngestHealth
    {
        /// "unknown" | "no_samples" | "ok" | "lossy" | "severe_loss". A string because it
        /// crosses /ndt/, and never omitted -- an absent field reads as a passing one.
        std::string status;
        /// Samples the collector actually took delivery of in the window. The rates beside this
        /// field were computed from these and no others.
        uint64_t samplesInWindow = 0;
        /// Lost to the socket receive queue in the window (SO_RXQ_OVFL).
        uint64_t socketDropsInWindow = 0;
        /// Dropped by us in the window, when a worker queue was full.
        uint64_t appDropsInWindow = 0;
        /// The denominator: samples + both kinds of drop. What the network tried to tell us.
        uint64_t offeredInWindow = 0;
        /// (socket + app drops) / offered, in [0,1]. -1.0 when no window has closed yet, and
        /// 0.0 for a closed window that was offered nothing -- those are different facts.
        double lossFraction = -1.0;
        /// Length of the window the counts above cover. 0 when none has closed.
        double windowSeconds = 0.0;
    };

    /**
     * @brief The verdict on its own -- no clock, no socket, no collector.
     *
     * @details
     * Pure and static for the same reason `classifyTelemetry` is: left inside the rate loop, the
     * one claim this feature makes ("this measurement is usable / is not") would have been
     * reachable from a test only by standing up a collector and flooding a real socket, so a
     * mutation pinning every answer to "ok" would have survived the suite. That is the defect
     * this fix exists to remove; it must not be reintroduced by the fix's own shape.
     *
     * @param windowClosed        False until the rate loop has completed one window. Forces
     *                            "unknown": at start-up we have not yet failed to receive, and
     *                            claiming health before measuring it is the original defect.
     * @param samplesInWindow     Samples delivered in that window.
     * @param socketDropsInWindow Socket-queue overflow delta over that window.
     * @param appDropsInWindow    Application-level drop delta over that window.
     * @param windowSeconds       Length of the window in seconds.
     */
    static IngestHealth classifyIngestHealth(bool windowClosed,
                                             uint64_t samplesInWindow,
                                             uint64_t socketDropsInWindow,
                                             uint64_t appDropsInWindow,
                                             double windowSeconds);

    /// Loss above this fraction of the offered samples means the numbers in the same response are
    /// materially understated: round 4 measured a 2.76x under-report at 0.725. 0.01 is one lost
    /// sample in a hundred, which at 18.5 samples/s is already visible in a per-second rate.
    static constexpr double kIngestLossyFraction = 0.01;
    /// Above this, do not treat the response's rates as a measurement at all.
    static constexpr double kIngestSevereLossFraction = 0.10;

    /// The most recently closed window's health, safe to call from any thread.
    IngestHealth ingestHealth() const;

    /// `ingestHealth()` as the JSON object published as `telemetry_health`. One place, so every
    /// endpoint that carries it carries the same keys. [Co-developed with claude code -- Adam]
    nlohmann::json ingestHealthJson() const;

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

    /**
     * @brief Writes the accumulated egress byte counts onto switch-to-host edges.
     *
     * @details
     * Link usage is normally credited from the *ingress* side: a sample taken at (switch,
     * inputPort) is attributed to the edge arriving at that port, so every switch-to-switch
     * edge is owned by the downstream switch's samples. The final hop of a path has no
     * downstream sampler -- hosts do not run agents -- so under that rule alone the
     * switch-to-host edge of every flow reads 0 forever while the bytes demonstrably move
     * (doc/audit/2026-08-15_fresh-acceptance-report.md §3c).
     *
     * This drain closes exactly that gap and nothing else: entries whose far end is another
     * switch are skipped, because the downstream sampler already owns them and a second
     * writer would fight it. Runs once per rate-loop second, like the ingress drain above it.
     *
     * Protected so tests can run one drain pass without standing up the rate-loop thread.
     *
     * [Co-developed with claude code -- Adam]
     */
    // Takes the drain-to-drain interval; see updateLinkInfoLeftLinkBandwidth for why bytes and
    // an interval rather than a finished bps. [Co-developed with claude code -- Adam]
    void creditHostBoundEgressEdges(double elapsedSeconds);

    /**
     * @brief One per-flow rate pass: measure the interval, republish every flow's rates over it.
     *
     * [Co-developed with claude code -- Adam]
     *
     * Protected so a test can run one pass without standing up the rate-loop thread -- and that
     * is not a convenience. The arithmetic can be unit-tested on its own (sflow::
     * updateFlowRatesForInterval), but "the loop hands it the measured interval" cannot, and a
     * fix wired to a constant would pass every arithmetic test ever written. That is not a
     * hypothetical failure mode: it is what f5e35561 did to this very file, correcting the link
     * accumulator while the flow rates beside it kept publishing bits-per-loop-period. A test
     * calls this twice with a known sleep between and reads lastFlowRateDivisorSeconds().
     *
     * Not thread safe with respect to itself: m_lastFlowDrainAt is a plain member because
     * exactly one thread (the rate loop) calls this in production.
     */
    void runFlowRatePass();

    /**
     * @brief Sampled bytes x sampling rate banked so far for one (agent IP, port).
     *
     * This is the quantity the rate loop turns into `linkBandwidthUsage` -- it multiplies this
     * by 8 and resets it -- so it is what every reported link rate is made of.
     *
     * Protected as a read-only test seam. Nothing observable distinguishes "walked every sample
     * in a batched datagram" from "walked the first and banked only its bytes": both leave the
     * right number of flows in the flow table, and only the accounting differs. A parser that
     * chained correctly through N samples but banked one would understate every rate by N with
     * no error anywhere, which is precisely the shape of defect this codebase keeps producing.
     * Asserting on the flow table alone cannot catch it; this can.
     *
     * Returns 0 for an unknown key, which is indistinguishable from a known key that has banked
     * nothing -- callers that need to tell those apart should assert on a delta.
     *
     * [Co-developed with claude code -- Adam]
     */
    uint64_t sampledByteCreditFor(uint32_t agentIp, uint32_t port) const;

    /**
     * @brief The active window this collector applies, in ms. Production always leaves it alone.
     *
     * [Co-developed with claude code -- Adam]
     *
     * A seam, and it is here because the alternative was worse. The one assertion that matters
     * for KNOWN-ISSUES B-x -- that a flow which stopped is actually dropped from the default view
     * -- needs a row whose last sample is older than the window, and the only ways to get one are
     * to sleep past kFlowActiveWindowMs (3 s of wall clock in a suite that today contains no
     * multi-second sleep at all, and a timing-dependent test to maintain forever) or to write
     * FlowInfo::endTime from a test, which would mean exposing the table for mutation.
     *
     * Nothing in this class ever writes it, so its production value is the constant and a
     * mutation that changed the constant would still be caught. A test subclass narrows it to
     * make every retained row idle deterministically.
     */
    int64_t m_flowActiveWindowMs = kFlowActiveWindowMs;

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

    // [Co-developed with claude code -- Adam]
    // Where the per-flow counters were last drained. Separate from the link path's lastDrainAt
    // because it marks a different drain: the flow walk snapshots ...Previous = ...Current near
    // the top of the loop body, the counter reports are zeroed near the bottom, and the two
    // spans differ by however long the walk takes. Anchored at construction rather than at the
    // first pass so the first interval is a real one -- the counters start at zero at the same
    // instant, so the first pass measures bytes since construction over the time since
    // construction, which is consistent (slightly long, hence slightly conservative, because
    // the socket is not receiving for the first few ms of it).
    std::chrono::steady_clock::time_point m_lastFlowDrainAt{std::chrono::steady_clock::now()};

    // Written by runFlowRatePass, read by the acceptance gate. Starts negative for the same
    // reason the link path's does: 0 is a value a gate could read as "an interval was used".
    std::atomic<double> m_lastFlowRateDivisorSeconds{-1.0};

    // key -> agent_ip and port
    // value -> last_report_time, last_received_input_octets and
    // last_received_output_octets, ...
    std::map<std::pair<uint32_t, uint32_t>, CounterInfo> m_counterReports;

    // key -> agent_ip and *output* port of the sampling switch. Shares
    // m_counterReportsMutex with m_counterReports: the two are filled by the same ingest
    // line and drained by the same rate-loop pass, so a second lock would only add an
    // ordering question. Only entries whose far end is a host are ever written to the
    // graph -- see creditHostBoundEgressEdges.
    std::map<std::pair<uint32_t, uint32_t>, CounterInfo> m_egressCounterReports;

    // [Co-developed with claude code -- Adam]
    // A-4f. When each agent last sent us anything, on any port, in steady-clock milliseconds.
    // Per *agent*, not per port, because that is the only level at which "no samples" can be
    // told apart from "no traffic": with polling=0 an idle port is silent on the wire, so the
    // question can only be answered by asking whether the switch is sampling at all.
    //
    // Shares m_counterReportsMutex with the two maps above -- written on the same ingest line,
    // under the lock that line already takes, so it costs no second acquisition.
    std::map<uint32_t, int64_t> m_lastSampleFromAgentMillis;

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
    // There is deliberately no FlowRoutingManager handle here. That manager already owns this
    // collector (FlowRoutingManager::m_flowLinkUsageCollector), so a shared_ptr pointing back
    // would close an ownership cycle and neither object would ever be destroyed. The member this
    // replaces was never read, and the constructor never even initialised it.
    // [Co-developed with claude code -- Adam]
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

    // [Co-developed with claude code -- Adam]
    // The most recently CLOSED rate window, published for ingestHealth(). Written once per
    // second by the rate loop, read by HTTP handler threads, hence atomics: the totals above are
    // monotonic and useless for "is the answer I am holding right now trustworthy", which is a
    // question about one window. m_healthWindowClosed gates the whole thing so a reader can tell
    // "not measured yet" from "measured, nothing lost".
    std::atomic<bool> m_healthWindowClosed{false};
    std::atomic<uint64_t> m_healthSamplesInWindow{0};
    std::atomic<uint64_t> m_healthSockDropsInWindow{0};
    std::atomic<uint64_t> m_healthAppDropsInWindow{0};
    // Stored as microseconds because std::atomic<double> is not lock-free everywhere.
    std::atomic<uint64_t> m_healthWindowMicros{0};
};

} // namespace sflow
