#pragma once

#include "utils/Utils.hpp"   // for DeploymentMode
#include <atomic>            // for atomic
#include <memory>            // for shared_ptr
#include <nlohmann/json.hpp> // for json
#include <shared_mutex>
#include <stdint.h>           // for uint32_t, uint64_t
#include <optional>           // for optional
#include <string>             // for string, basic_string
#include <thread>             // for thread
#include <tuple>              // for tuple
#include <unordered_map>      // for unordered_map
#include <vector>             // for vector
class TopologyAndFlowMonitor; // lines 34-34

// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#include "ndt_core/power_management/IPowerStrategy.hpp"

using json = nlohmann::json;

namespace ndtClassifier
{
class Classifier;
}

/**
 * @brief Mapping between a switch management IP and its smart plug control endpoint.
 *
 * Used in TESTBED mode to power on/off a physical switch through a smart plug relay.
 */
struct SwitchInfo
{
    std::string switchIp;
    std::string plugIp;
    int plugIdx;
};

// This should align with real-world smart plug configuration

/**
 * @brief Tracks a run of consecutive failures so only its edges get logged.
 *
 * @details
 * The bridge query runs at 1 Hz, so logging every failure means one line per second for as long
 * as the fault lasts. That is how the liveness bug announced itself the first time: 3596 lines of
 * sudo errors in a single run, which buried everything else in the log. Reporting only the edges
 * keeps the fault visible without the flood.
 *
 * Its own type rather than a bare counter in the manager because the manager cannot be
 * constructed in a test without a topology monitor, a classifier and three background threads,
 * and "is it quiet after the first failure?" is exactly the property worth pinning.
 *
 * Not thread-safe: only pingWorker's thread touches it.
 *
 * [Co-developed with claude code -- Adam]
 */
class FailureRun
{
  public:
    /// @return true only for the first failure of a run, i.e. when the caller should log.
    bool recordFailure()
    {
        return m_consecutive++ == 0;
    }

    /// @return how many failures the run that just ended contained, or nullopt if none was open.
    std::optional<unsigned> recordSuccess()
    {
        if (m_consecutive == 0)
        {
            return std::nullopt;
        }
        return std::exchange(m_consecutive, 0u);
    }

  private:
    unsigned m_consecutive = 0;
};

/**
 * @brief Central manager for switch power control and device status telemetry.
 *
 * DeviceConfigurationAndPowerManager provides a unified interface to:
 *  - query and toggle switch power state (TESTBED: via smart plug / gateway; MININET: via
 * simulator),
 *  - periodically collect and cache device health metrics (power, CPU, memory, temperature),
 *  - fetch and cache OpenFlow table snapshots for switches, and
 *  - expose results in JSON form for REST/API handlers.
 *
 * The class runs background worker threads when start() is called:
 *  - a ping worker to track reachability (optional/implementation-defined),
 *  - a status update worker that refreshes cached telemetry,
 *  - an OpenFlow table update worker that refreshes cached flow tables.
 *
 * Concurrency:
 *  - Cached status JSON is protected by m_statusMutex (shared_mutex).
 *  - Cached OpenFlow tables are protected by m_openflowTablesMutex.
 *  - Public getters return snapshots from the cache.
 *
 * Deployment:
 *  - TESTBED mode controls real hardware using the smart plug table and GW_IP gateway URL.
 *  - MININET mode derives state from the simulator (e.g., OVS/Mininet topology).
 */
class DeviceConfigurationAndPowerManager
{
  public:
    /**
     * @brief Construct the device manager.
     *
     * @param topoMonitor Topology monitor used for mapping/lookup (e.g., IP<->switch).
     * @param mode        Deployment mode (TESTBED / MININET).
     * @param gwUrl       Gateway URL/IP used to reach the testbed control service (TESTBED).
     */
    DeviceConfigurationAndPowerManager(std::shared_ptr<TopologyAndFlowMonitor> topoMonitor,
                                       int mode,
                                       std::string gwUrl,
                                       std::shared_ptr<ndtClassifier::Classifier> classifier);

    /**
     * @brief Query power state for one or more switches.
     *
     * Parses the "ip" query parameter from @p target. If ip is omitted or indicates
     * "all" (implementation-defined), it returns states for all known switches.
     *
     * @param target Full request target, e.g. "/ndt/get_switches_power_state?ip=10.10.10.12".
     * @return JSON mapping switch IP -> state string (e.g., "ON", "OFF", "error").
     * @throws std::runtime_error if the requested IP is unknown or not resolvable.
     */
    json getSwitchesPowerState(const std::string& target);

    /**
     * @brief Toggle power for a specific switch using a provided SwitchInfo record.
     *
     * Primarily intended for TESTBED mode where the plug endpoint is already known.
     *
     * [Co-developed with claude code -- Adam]
     * The three-argument overload that used to live here is gone. It was the honest
     * implementation -- bounded curl, HTTP status read, graph untouched on failure -- and it had
     * zero call sites on the day it was written and zero the day it was removed, while the
     * reachable path next to it kept answering `rc == 0`. Two implementations of one operation,
     * with the tested one unreachable, is worse than either alone: its URL had also drifted
     * (no `resource=outlet`), so "just wire it up" would have changed the request on real
     * hardware. Its logic now lives in setPowerStateTestbed, which is the path that runs.
     */

    /**
     * @brief Toggle power for a switch using the appropriate backend.
     *
     * @param ip     Switch IP address.
     * @param action "on" or "off" (case handling is implementation-defined).
     * @return true on success; false if the IP is unknown or the operation fails.
     */
    bool setSwitchPowerState(const std::string& ip, const std::string& action);

    /**
     * @brief Get the latest cached power report for all devices.
     *
     * @return JSON snapshot of the most recent power report.
     */
    json getPowerReport();
    /**
     * @brief Get the latest cached memory utilization report.
     */
    json getMemoryUtilization();
    /**
     * @brief Get the latest cached OpenFlow table snapshot as JSON.
     *
     * @return JSON describing OpenFlow tables for switches (schema implementation-defined).
     */
    json getOpenFlowTables();

    /**
     * @brief Get the latest cached CPU utilization report.
     */
    json getCpuUtilization();
    /**
     * @brief Get the latest cached temperature report.
     */
    json getTemperature();

    /**
     * @brief Get the cached power report for one device/switch.
     *
     * @param deviceIdentifier Switch identifier (IP, name, or DPID depending on implementation).
     * @return JSON report for the specified device, or an error JSON if unknown.
     */
    json getSingleSwitchPowerReport(const std::string& deviceIdentifier);
    /**
     * @brief Get the cached CPU report for one device/switch.
     *
     * @param deviceIdentifier Switch identifier (IP, name, or DPID depending on implementation).
     * @return JSON report for the specified device, or an error JSON if unknown.
     */
    json getSingleSwitchCpuReport(const std::string& deviceIdentifier);

    /**
     * @brief Update cached OpenFlow tables with externally provided JSON.
     *
     * Useful when another subsystem fetches OpenFlow state and pushes it into this manager.
     *
     * @param j OpenFlow table JSON snapshot.
     */
    void updateOpenFlowTables(const json& j);

    /**
     * @brief Start background workers that refresh cached status and OpenFlow tables.
     *
     * Launches m_pingThread, m_statusUpdateThread and m_openflowTablesUpdateThread.
     */
    void start();
    /**
     * @brief Stop all background workers and release resources.
     *
     * Signals shutdown, joins threads, and leaves cached values intact.
     */
    void stop();

  protected:
    /**
     * @brief What the bridge list implies about one OVS switch.
     *
     * [Co-developed with claude code -- Adam]
     */
    enum class OvsLiveness
    {
        Up,      ///< The bridge is present.
        Down,    ///< The bridge list was read successfully and this bridge is absent.
        Unknown, ///< The bridge list could not be read; nothing can be concluded.
    };

    /**
     * @brief Decides an OVS switch's liveness from the bridges `ovs-vsctl list-br` reported.
     *
     * @param bridgeName The switch's Mininet bridge name, e.g. "s1".
     * @param bridges    The reported bridges, or nullopt when the query failed.
     *
     * @details
     * Separated out because the policy is what went wrong, twice over, and a policy in the
     * middle of a 100-line loop over a BGL graph cannot be tested:
     *
     *  - A failed query used to be indistinguishable from "no bridges exist", so one dropped
     *    `ovs-vsctl` call marked every switch down. Now that is Unknown, and the caller leaves
     *    the graph alone -- "cannot tell" must not be reported as "dead".
     *  - The old code never set a switch back *up* on success, only down on failure, so a
     *    single transient blip was permanent until Ryu happened to re-announce the switch.
     *
     * [Co-developed with claude code -- Adam]
     */
    static OvsLiveness ovsLivenessFor(const std::string& bridgeName,
                                      const std::optional<std::vector<std::string>>& bridges);

    /**
     * @brief How long a switch's last LLDP beacon may be before it stops counting as evidence.
     *
     * @details The proxy broadcasts beacons every 5 seconds, so anything under two intervals is
     * healthy and this leaves room for one missed round. [Co-developed with claude code -- Adam]
     */
    static constexpr double kLldpFreshSeconds = 12.0;

    /**
     * @brief How stale the proxy's own probe result may be before it is no longer trusted.
     *
     * @details The proxy probes every 2 seconds. A result older than this means its poller has
     * stalled, which is a fact about the proxy, not about the switch -- so it yields Unknown rather
     * than Down. [Co-developed with claude code -- Adam]
     */
    static constexpr double kProbeStaleSeconds = 15.0;

    /**
     * @brief Above this round-trip, an *empty* flow table is treated as a timeout, not as a fact.
     *
     * @details Ryu's `ofctl_rest` waits `DEFAULT_TIMEOUT = 1.0` seconds
     * (`ryu/lib/ofctl_utils.py:28`, awaited by `send_stats_request` at `:253`) for the switch's stats
     * reply and then answers with whatever it has -- which, when the reply never came, is an empty
     * table. On the wire that is byte-identical to "this switch genuinely has no rules": both are
     * `{"1": []}`. The round trip is the only thing that differs, and it differs widely.
     *
     * Measured on the OVS testbed, 2026-08-07, 151 samples
     * (`doc/audit/2026-08-07_ryu-wedge-trace.tsv`):
     *
     * | state   | round trip      | body    |
     * |---------|-----------------|---------|
     * | healthy | 0.027 - 0.083 s | ~35 KB  |
     * | wedged  | 1.009 - 1.013 s | 9 bytes |
     *
     * 0.5 s sits six times above the worst healthy sample and half of Ryu's own timeout. The
     * asymmetry is deliberate: a false positive keeps the previous table and logs a warning, while a
     * false negative tells the twin a working fabric has no rules at all. Erring toward suspicion
     * costs a log line; erring the other way is what made the twin confidently wrong.
     *
     * [Co-developed with claude code -- Adam]
     */
    static constexpr double kFlowStatsSuspectSeconds = 0.5;

    /**
     * @brief Whether one `/stats/flow` reply may be believed.
     */
    enum class FlowStatsVerdict
    {
        Usable,          ///< Apply it: it has entries, or it was too fast to be a timeout.
        SuspectTimedOut, ///< Empty *and* slow. Keep the previous table; do not apply this one.
        ReportedFailure, ///< The body says "error": the control plane could not read the switch.
    };

    /**
     * @brief Decide whether a `/stats/flow` reply is evidence or an artefact of Ryu's timeout.
     *
     * @param flows          The parsed `flows` value: table-id -> array of entries, or a bare array.
     * @param elapsedSeconds Round trip actually measured for this request.
     *
     * @details A reply carrying any entry at all is always usable -- slowness alone is not a fault
     * and a large table legitimately takes longer. Only the *combination* of "no entries anywhere"
     * and "slow" is suspect, because a genuinely empty table is the fastest possible answer: Ryu
     * already holds it and returns at once, whereas a lost reply costs the full timeout.
     *
     * An object carrying an "error" (or FastAPI's "detail") key is the P4 proxy saying the read
     * itself failed, and is ReportedFailure regardless of latency. This closed a real hole: the
     * fetch goes through `curl -s`, which never surfaces the HTTP status, so the body shape is the
     * only channel the failure can travel on -- and before this verdict existed, a proxy-side read
     * failure came back fast, sailed under kFlowStatsSuspectSeconds as an "empty table", and was
     * applied as an authoritative snapshot that blanked every flow's path for that switch. The
     * latency guard cannot catch it precisely because failing is faster than timing out. Zero
     * false-positive risk: a genuine table's keys are numeric table-id strings, never "error".
     *
     * Stateless and total, so it is testable without a control plane.
     * See tests/test_FlowStatsTimeout.cpp. [Co-developed with claude code -- Adam]
     */
    static FlowStatsVerdict classifyFlowStatsReply(const nlohmann::json& flows,
                                                   double elapsedSeconds);

    /**
     * @brief Decides one bmv2 switch's liveness from the evidence `GET /p4/switch_state` reported.
     *
     * @param dpid    The switch's datapath id.
     * @param payload The parsed proxy response, or nullopt when the proxy could not be reached or
     *                its answer did not parse.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     *
     * Replaces a stub that called `setVertexUp` for every bmv2 switch once a second with no
     * evidence at all, so a switch that had been killed reported healthy again within one second and
     * the twin could never show a fault. `is_up` also gates the power, CPU and temperature reports
     * and `getAvgLinkUsage`, so that one fabricated field made several others meaningless.
     *
     * Same three-state shape as ovsLivenessFor, and for the same reason: **Unknown must not be
     * reported as Down.** On the OVS side, conflating "the query failed" with "the bridge is absent"
     * marked an entire fabric dead from one dropped `ovs-vsctl` call. Here the equivalent mistake
     * would be worse, because a single unreachable proxy would take all ten switches down at once.
     *
     * The policy, in order:
     *
     *  - No payload (proxy unreachable, or unparseable) -> **Unknown**. This is the case that must
     *    never be Down.
     *  - No entry for this dpid -> **Unknown**. The proxy does not know about it, which is a
     *    configuration disagreement between the topology file and the proxy's switch table, not a
     *    dead switch.
     *  - `probe_ok` is null (no probe has completed yet) -> **Unknown**. Otherwise every run reports
     *    the whole fabric dead for its first two seconds.
     *  - `probe_ok` true -> **Up**. A P4Runtime RPC was round-tripped, which is the only signal that
     *    actually proves a bmv2 process is alive and serving.
     *  - `probe_age_s` beyond kProbeStaleSeconds -> **Unknown**. The proxy's poller has stalled; its
     *    last verdict says nothing about the switch now.
     *  - `probe_ok` false, but a beacon from this switch arrived within kLldpFreshSeconds ->
     *    **Unknown**. The two signals disagree, and acting on conflicting evidence is what a
     *    three-state policy exists to avoid. bmv2 answers control-plane RPCs whether or not its
     *    pipeline forwards, and conversely a busy switch can miss an RPC deadline while forwarding
     *    perfectly well.
     *  - `probe_ok` false with no fresh beacon -> **Down**. We asked, it did not answer, and nothing
     *    else suggests otherwise.
     */
    static OvsLiveness p4LivenessFor(uint64_t dpid, const std::optional<nlohmann::json>& payload);

    /// What the smart-plug gateway's reply says about a power request.
    /// [Co-developed with claude code -- Adam]
    struct RelayResult
    {
        bool ok = false;         ///< The gateway accepted the request.
        std::string detail;      ///< For the log: the status text, or why this failed.
    };

    /**
     * @brief Reads the smart-plug gateway's reply to a power request.
     *
     * @param response curl's output with the HTTP status appended on its own last line, i.e. what
     *                 `-w '\n%{http_code}'` produces. Empty when curl could not connect at all.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     *
     * Extracted as a pure function for the same reason ovsLivenessFor and p4LivenessFor were: the
     * decision is what was wrong, and a decision buried in a method that needs a topology monitor, a
     * classifier and a live gateway cannot be tested.
     *
     * What was wrong: the reply was scraped for a status string, that string was **only logged**,
     * and the graph was then updated to whatever state the caller had *asked for* -- so the twin
     * reported the request rather than the outcome. The curl had no `--fail`, no `%{http_code}` and
     * no `--max-time`, so an unreachable gateway produced an empty string and the code carried on to
     * mark the switch powered off. TESTBED-only, but TESTBED is where the switches are real.
     *
     * Keyed on the HTTP status rather than on the HTML text, because the status is a contract and the
     * text is a page that can be redesigned. The text is still reported, since it is what a human
     * needs when the status is 200 and the plug still did not move.
     *
     * A 200 does not prove the plug switched -- it proves the gateway accepted the request. That is
     * the strongest claim available here, and it is enough, because `pingWorker` pings the switch
     * once a second and will correct the graph if the plug did not actually operate. Updating the
     * graph on a *failed* request is what had no recovery path: nothing would contradict it until the
     * next ping, and in the meantime the twin actively lied.
     */
    static RelayResult interpretRelayResponse(const std::string& response);

    /**
     * @brief Builds the gateway request that switches one smart-plug outlet.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * Pure, and separate from the method that runs it, for the reason stated above
     * interpretRelayResponse: the method needs a topology monitor, a classifier and a live
     * gateway, so nothing inside it can be asserted. What is asserted here is the wire format,
     * and it is worth asserting because getting it wrong is silent -- `curl -s` prints nothing,
     * and the reply to a request missing `resource` looks like the reply to a rejected one.
     *
     * `--max-time` because this runs inside a request handler, and `-w '\n%{http_code}'` because
     * interpretRelayResponse reads its verdict from that line. The query parameters match the
     * ones the power *report* sends to the same endpoint (see fetchPowerReportInternal), which
     * is the only evidence available here of what this gateway actually accepts.
     *
     * @param gwUrl  Gateway host (AppConfig::GW_IP).
     * @param si     Smart plug mapping for this switch.
     * @param action "on" or "off".
     */
    static std::string buildRelayPowerCommand(const std::string& gwUrl,
                                              const SwitchInfo& si,
                                              const std::string& action);

    /**
     * @brief Builds the request that reads per-switch bmv2 liveness from the P4 proxy.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * Extracted for the same reason as buildRelayPowerCommand: the method around it needs a live
     * proxy, so the only assertable thing is the wire format. `--max-time` matters here more than
     * anywhere else in this file -- this runs inside the 1 Hz ping loop, so an unbounded request
     * stalls liveness for every switch at once.
     *
     * @param proxyIpAndPort Host:port of the P4 proxy (AppConfig::P4_PROXY_IP_AND_PORT).
     */
    static std::string buildSwitchStateCommand(const std::string& proxyIpAndPort);

    /**
     * @brief Builds the request that reads one switch's flow tables from Ryu or the P4 proxy.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * This one was a bare `curl -s` until 2026-08-13 -- the last unbounded request in this file,
     * and on the worst path to leave unbounded: the sweep is serial over every switch, so one
     * unresponsive dpid stalled every later dpid's table too. Measured against a SIGSTOPed bmv2,
     * the proxy never answered at all.
     *
     * The bound is deliberately looser than the liveness poll's. The P4 proxy caps its own gRPC
     * read at 5 s and then answers {"error": ...} naming the switch; cutting before that trades a
     * body that identifies the failure for an empty one, which the caller can only report as
     * "switch N and possibly others". Losing that race costs diagnosis, not safety -- an empty
     * body is already handled by keeping the previous tables.
     *
     * @param ipAndPort Host:port of the controller for this switch (Ryu or the P4 proxy).
     * @param dpid      The switch's datapath id.
     */
    static std::string buildFlowStatsCommand(const std::string& ipAndPort, uint64_t dpid);

    /**
     * @brief A plausible synthetic power draw, in milliwatts, for a simulated switch.
     *
     * @param dpid The switch's datapath id, used as the seed.
     *
     * @details
     * Mininet and bmv2 have no PSU to read, so MININET mode has always made this figure up. It
     * used to be `uniform_int_distribution<uint64_t>(0, UINT64_MAX >> 4)` -- uniform over
     * [0, 2^60) -- which produced values like 193112054821787525 mW, i.e. 1.9x10^14 watts, and
     * re-rolled every poll so the number also jumped by 17 orders of magnitude between ticks.
     *
     * That matters more than "it is only a demo value": the Energy-Saving application consumes
     * this figure, so any decision it reached was made on noise.
     *
     * Seeded rather than random so a given switch reports a stable draw, which is what makes a
     * change meaningful -- the useful signal is a switch going to 0 when powered off (the caller's
     * `!isUp` branch), not per-tick jitter. Same idiom as the neighbouring synthetic CPU
     * (`10 + hash % 50` percent) and temperature (`25 + hash % 25` degrees) values, which seed on
     * the management IP because their JSON is keyed by it; this report is keyed by dpid, and a dpid
     * is always present, whereas a vertex's `ip` vector can be empty -- the MININET path must not
     * call `ip.front()`.
     *
     * Shared by the `/ndt/get_power_report` path and the Intent Translator's per-device query
     * (`getSingleSwitchPowerReport`), which previously had a private RNG each and so disagreed
     * about the same switch at the same instant.
     *
     * [Co-developed with claude code -- Adam]
     */
    static uint64_t syntheticPowerMilliwattsFor(uint64_t dpid);

    /**
     * @brief Renders a `pclose()` return value as something an operator can act on.
     *
     * @param status `pclose()`'s return value: a `waitpid()` wait status, or -1.
     *
     * @details
     * `pclose()` does not return the child's exit code -- it returns the wait status, so exit
     * code 1 is 256 and 127 is 32512. Logging it raw sent the reader looking for a meaning that
     * does not exist. Decoded here, and the two statuses this command actually produces are named:
     * 127 means ovs-vsctl is missing, 1 means it refused, which is what a sudo password prompt
     * looks like on a process with no controlling terminal -- the original cause of the fabric
     * showing as dead.
     *
     * [Co-developed with claude code -- Adam]
     */
    static std::string describeCommandStatus(int status);

  private:
    std::shared_ptr<TopologyAndFlowMonitor> m_topologyAndFlowMonitor;
    utils::DeploymentMode m_mode;
    std::atomic<bool> m_running{false};
    std::thread m_pingThread;

    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    std::unique_ptr<IPowerStrategy> m_ovsPowerStrategy;
    std::unique_ptr<IPowerStrategy> m_p4PowerStrategy;

    /**
     * @brief Selects the power strategy for a switch, in O(1).
     *
     * Keyed on the switch's typed SwitchKind rather than a brand-name string compare, and
     * takes a dpid so it needs no graph copy. Returns nullptr for an unknown dpid instead
     * of defaulting to OVS, which would run ovs-vsctl against a bmv2 switch.
     *
     * [Co-developed with claude code -- Adam]
     */
    IPowerStrategy* getPowerStrategyForDpid(uint64_t dpid) const;

    /**
     * @brief True when every switch in the loaded topology is bmv2.
     *
     * Cached once by refreshDataPlaneKind() because the liveness worker runs every second
     * and hosts carry no SwitchKind of their own.
     *
     * [Co-developed with claude code -- Adam]
     */
    bool m_dataPlaneIsBmv2 = false;

    /**
     * @brief Recomputes m_dataPlaneIsBmv2 from the loaded topology. Call after load.
     *
     * [Co-developed with claude code -- Adam]
     */
    void refreshDataPlaneKind();

    void fetchSmartPlugInfoFromFile(const std::string& path);
    // Extract "ip" parameter from target; empty if absent
    std::string parseIpParam(const std::string& target) const;

    // Query real hardware via Flask relay for TESTBED mode
    json queryTestbed(const std::string& ipParam) const;

    // Query Mininet topology for switch up/down state
    json queryMininet(const std::string& ipParam) const;
    /**
     * @brief Parse a `/stats/flow` body, distinguishing "did not parse" from "parsed as empty".
     *
     * @return The parsed value, or nullopt when the body is not JSON at all.
     *
     * @details It used to return `json::array()` on a parse failure, which made a corrupted body
     * indistinguishable from a switch reporting no rules. That was harmless while
     * `Classifier::updateFromQueriedTables` ignored empty arrays -- and became data loss the moment
     * it stopped, because applying an empty snapshot bumps the epoch and sweeps every rule for that
     * dpid. An HTTP 500 error page or a truncated body would silently wipe a switch's flow table.
     *
     * The latency check in classifyFlowStatsReply does not cover this: a parse failure is local, so
     * it comes back fast, and fast-and-empty is exactly what that check treats as trustworthy.
     *
     * Found by agy-review 0109. [Co-developed with claude code -- Adam]
     */
    std::optional<json> parseFlowStatsTextToJson(const std::string& responseText) const;

    bool pingSwitch(const std::string& ip, int timeout_sec);
    void pingWorker(int interval_sec);

    /// Failure-run state for the `ovs-vsctl list-br` query. [Co-developed with claude code -- Adam]
    FailureRun m_bridgeQueryFailures;

    /**
     * @brief Warns on the first failure of a run only, then stays quiet. See FailureRun.
     *
     * [Co-developed with claude code -- Adam]
     */
    void reportBridgeQueryFailure(const std::string& reason);

    /**
     * @brief Reports recovery, once, including how many failures the run contained.
     *
     * [Co-developed with claude code -- Adam]
     */
    void reportBridgeQueryRecovered();

    /// Failure-run state for the `GET /p4/switch_state` fetch. Separate from the OVS one because a
    /// run of failures against the proxy is a different fault with a different fix, and folding
    /// them together would report a recovery that did not happen.
    /// [Co-developed with claude code -- Adam]
    FailureRun m_switchStateFailures;

    /// Failure-run state for the per-switch `/stats/flow/<dpid>` fetch, which previously logged an
    /// error per switch per poll when the control plane was absent -- 216 of them during one
    /// four-minute outage. [Co-developed with claude code -- Adam]
    FailureRun m_flowStatsFetchFailures;

    /// [Co-developed with claude code -- Adam]
    /// Separate run from m_flowStatsFetchFailures: "the control plane did not answer" and "it
    /// answered with an empty table it could not actually see" are different faults with different
    /// fixes, and collapsing them would report the wedge as an outage.
    FailureRun m_flowStatsTimeouts;

    /**
     * @brief Fetches `GET /p4/switch_state` from the proxy, or nullopt if it could not be read.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * nullopt covers an unreachable proxy, a non-2xx reply and a body that does not parse, because
     * all three mean the same thing to the caller: no evidence. Distinguishing them in the *log* is
     * useful and done; distinguishing them in the return value would invite a branch that treats one
     * of them as "down".
     *
     * Edge-triggered logging, as with the bridge query: this runs at 1 Hz, so warning every time is
     * how the sudo failure buried the log in 3596 lines.
     */
    std::optional<json> fetchP4SwitchState();

    // Helpers for TESTBED mode
    bool setPowerStateTestbed(const SwitchInfo& si, const std::string& action);
    // Helpers for MININET mode
    bool setPowerStateMininet(uint32_t ipUint, const std::string& action);

    /**
     * @brief The main loop for the m_statsUpdateThread.
     *
     * Periodically calls all the "fetch...Internal" functions and
     * updates the cached member variables under a lock.
     */
    void statusUpdateWorker();
    void openflowTablesUpdateWorker();
    // --- The *actual* (slow) data-fetching functions ---
    // These are the original implementations, just renamed.
    json fetchPowerReportInternal();
    json fetchMemoryReportInternal();
    json fetchCpuReportInternal();
    json fetchTemperatureReportInternal();
    json fetchOpenFlowTablesInternal();

    std::vector<SwitchInfo> switchSmartPlugTable;

    std::thread m_statusUpdateThread;
    std::thread m_openflowTablesUpdateThread;
    mutable std::shared_mutex m_statusMutex;
    mutable std::shared_mutex m_openflowTablesMutex;

    json m_cachedPowerReport;
    json m_cachedCpuReport;
    json m_cachedMemoryReport;
    json m_cachedTemperatureReport;
    json m_cachedOpenFlowTables;

    std::string GW_IP;

    std::shared_ptr<ndtClassifier::Classifier> m_classifier;
};