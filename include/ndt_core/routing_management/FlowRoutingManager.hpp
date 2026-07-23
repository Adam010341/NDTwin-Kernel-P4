#pragma once

#include "common_types/SFlowType.hpp" // for FlowKey (ptr only), Path
#include <memory>                     // for shared_ptr, unique_ptr
#include <nlohmann/json.hpp>          // for json
#include <optional>                   // for optional
#include <stdint.h>                   // for uint64_t
#include <string>                     // for string
class EventBus;                       // lines 44-44
class TopologyAndFlowMonitor;         // lines 36-36

// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#include "ndt_core/routing_management/IRoutingStrategy.hpp"
#include <memory>
namespace sflow
{
class FlowLinkUsageCollector;
} // namespace sflow
struct FlowAddedEventPayload;

using json = nlohmann::json;
using namespace std;

/**
 * @brief Applies routing/forwarding changes by programming switch flow/group/meter entries.
 *
 * FlowRoutingManager is the control-plane component responsible for issuing
 * OpenFlow-related operations (flow entries, group entries, meter entries) to
 * the underlying controller / southbound API (identified by apiUrl in the constructor).
 *
 * It integrates with:
 *  - TopologyAndFlowMonitor: for topology lookup and endpoint/switch context
 *  - sflow::FlowLinkUsageCollector: for flow/path awareness (e.g., affected flows)
 *  - EventBus: to publish events when entries are installed/modified/deleted
 *
 * This class provides higher-level, typed methods (install/modify/delete) that
 * accept JSON match/action payloads and translate them into controller API calls.
 */
class FlowRoutingManager
{
  public:
    /**
     * @brief Construct the routing manager.
     *
     * @param apiUrl Base URL of the controller/southbound API used to program entries.
     * @param topologyAndFlowMonitor Topology/flow monitor for context and lookups.
     * @param collector sFlow collector for flow/path awareness and affected-flow updates.
     * @param eventBus Event bus used to publish routing/flow-change events.
     */
    FlowRoutingManager(std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
                       std::shared_ptr<sflow::FlowLinkUsageCollector> collector,
                       std::shared_ptr<EventBus> eventBus);

    /// Release resources (does not own the shared components).
    ~FlowRoutingManager();

    /**
     * @brief Delete an OpenFlow flow entry on a given switch.
     *
     * If @p priority is -1 (default), this issues a non-strict delete request
     * (POST /stats/flowentry/delete) and may remove multiple entries that match
     * the provided @p match fields.
     *
     * If @p priority is provided (>= 0), this issues a strict delete request
     * (POST /stats/flowentry/delete_strict) where both @p match and @p priority
     * must match exactly, deleting at most one rule (depending on controller behavior).
     *
     * @param dpid     Target switch datapath ID.
     * @param match    Flow match fields in JSON format (e.g., eth_type, ipv4_dst).
     * @param priority Rule priority. Use -1 to perform non-strict delete.
     *
     * @note This function calls the local controller REST API via curl.
     */
    void deleteAnEntry(uint64_t dpid, json match, int priority = -1);
    /**
     * @brief Install a flow entry on a switch.
     *
     * @param dpid Target switch datapath ID.
     * @param priority Flow priority.
     * @param match JSON match fields (e.g., includes "ipv4_dst" by convention).
     * @param action JSON action(s) describing forwarding behavior.
     * @param idleTimeout Idle timeout in seconds (0 means no idle timeout).
     */
    void installAnEntry(uint64_t dpid, int priority, json match, json action, int idleTimeout = 0);
    /**
     * @brief Modify an existing flow entry on a switch.
     *
     * @param dpid Target switch datapath ID.
     * @param priority New/desired priority (or used to identify the rule depending on backend).
     * @param match JSON match fields identifying the entry to modify.
     * @param action Replacement action(s).
     */
    void modifyAnEntry(uint64_t dpid, int priority, json match, json action);

    /**
     * @brief Install a group entry.
     *
     * @param j JSON payload describing the group (schema is controller-dependent).
     */
    void installAGroupEntry(json j);
    /**
     * @brief Delete a group entry.
     *
     * @param j JSON payload describing which group to delete.
     */
    void deleteAGroupEntry(json j);
    /**
     * @brief Modify a group entry.
     *
     * @param j JSON payload describing the group modification.
     */
    void modifyAGroupEntry(json j);

    /**
     * @brief Install a meter entry.
     *
     * @param j JSON payload describing the meter (schema is controller-dependent).
     */
    void installAMeterEntry(json j);
    /**
     * @brief Delete a meter entry.
     *
     * @param j JSON payload describing which meter to delete.
     */
    void deleteAMeterEntry(json j);
    /**
     * @brief Modify a meter entry.
     *
     * @param j JSON payload describing the meter modification.
     */
    void modifyAMeterEntry(json j);

  private:
    std::shared_ptr<EventBus> m_eventBus;

    std::shared_ptr<TopologyAndFlowMonitor> m_topologyAndFlowMonitor;
    std::shared_ptr<sflow::FlowLinkUsageCollector> m_flowLinkUsageCollector;
    
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    std::unique_ptr<IRoutingStrategy> m_ovsStrategy;
    std::unique_ptr<IRoutingStrategy> m_p4Strategy;

    // Helper method to determine which strategy to use for a given dpid
    IRoutingStrategy* getStrategyForDpid(uint64_t dpid);
};