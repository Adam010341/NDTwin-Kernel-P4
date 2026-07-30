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
     * @param ip     Switch IP address (typically matches si.switch_ip).
     * @param action "on" or "off".
     * @param si     Smart plug mapping for this switch.
     * @return true on success; false on failure.
     */
    bool setSwitchPowerState(std::string ip, std::string action, SwitchInfo si);

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
    json parseFlowStatsTextToJson(const std::string& responseText) const;

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