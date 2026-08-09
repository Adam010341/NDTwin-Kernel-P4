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
#include "ndt_core/routing_management/OpResult.hpp"
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
    ///
    /// [Co-developed with claude code -- Adam] Virtual so the three *flow-entry* dispatch methods
    /// below -- installAnEntry, modifyAnEntry, deleteAnEntry -- can be overridden in a test, which
    /// requires deletion through a base pointer to be well-defined.
    ///
    /// Naming them matters because the set is not "all the dispatch methods": the group and meter
    /// methods are not virtual, so a test double cannot intercept them. That is deliberate for now
    /// -- nothing overrides them and P4RoutingStrategy answers them with an explicit "unsupported"
    /// rather than doing work worth intercepting -- but it is an asymmetry, not an oversight, and a
    /// comment that says "the three dispatch methods" without saying which invites the reader to
    /// assume otherwise. Review M4.
    virtual ~FlowRoutingManager();

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
    /// [Co-developed with claude code -- Adam] virtual: the test seam for Controller. Controller's
    /// sender is the only place a dispatched job's OpResult exists, and it discarded every one of
    /// them until 8c25dbc. Testing that it now acts on them needs a manager whose results the test
    /// chooses, and nothing else about FlowRoutingManager is substitutable.
    virtual OpResult deleteAnEntry(uint64_t dpid, const json& match, int priority = -1);
    /**
     * @brief Install a flow entry on a switch.
     *
     * @param dpid Target switch datapath ID.
     * @param priority Flow priority.
     * @param match JSON match fields (e.g., includes "ipv4_dst" by convention).
     * @param action JSON action(s) describing forwarding behavior.
     * @param idleTimeout Idle timeout in seconds (0 means no idle timeout).
     */
    virtual OpResult installAnEntry(uint64_t dpid,
                                    int priority,
                                    const json& match,
                                    const json& action,
                                    int idleTimeout = 0);
    /**
     * @brief Modify an existing flow entry on a switch.
     *
     * @param dpid Target switch datapath ID.
     * @param priority New/desired priority (or used to identify the rule depending on backend).
     * @param match JSON match fields identifying the entry to modify.
     * @param action Replacement action(s).
     */
    virtual OpResult modifyAnEntry(uint64_t dpid,
                                   int priority,
                                   const json& match,
                                   const json& action);

    /**
     * @brief Install a group entry.
     *
     * @param j JSON payload describing the group (schema is controller-dependent).
     */
    OpResult installAGroupEntry(const json& j);
    /**
     * @brief Delete a group entry.
     *
     * @param j JSON payload describing which group to delete.
     */
    OpResult deleteAGroupEntry(const json& j);
    /**
     * @brief Modify a group entry.
     *
     * @param j JSON payload describing the group modification.
     */
    OpResult modifyAGroupEntry(const json& j);

    /**
     * @brief Install a meter entry.
     *
     * @param j JSON payload describing the meter (schema is controller-dependent).
     */
    OpResult installAMeterEntry(const json& j);
    /**
     * @brief Delete a meter entry.
     *
     * @param j JSON payload describing which meter to delete.
     */
    OpResult deleteAMeterEntry(const json& j);
    /**
     * @brief Modify a meter entry.
     *
     * @param j JSON payload describing the meter modification.
     */
    OpResult modifyAMeterEntry(const json& j);

  protected:
    /**
     * @brief Selects the routing strategy for a switch from its typed SwitchKind.
     *
     * @return nullptr when the dpid is not a switch in the loaded topology. Callers must
     *         report and drop rather than guessing a data plane -- an earlier version
     *         defaulted to the OVS strategy, silently sending P4 rules to Ryu.
     *
     * Protected so tests can assert the dispatch directly; it is the whole point of the
     * strategy pattern and was previously untestable.
     *
     * [Co-developed with claude code -- Adam]
     */
    IRoutingStrategy* getStrategyForDpid(uint64_t dpid);

    /// Signature of a group/meter call on a strategy, for dispatchByPayloadDpid.
    using StrategyCall = OpResult (*)(IRoutingStrategy&, const json&);

    /**
     * @brief Routes a group/meter payload to the strategy owning its dpid.
     *
     * Group and meter payloads carry their target dpid in the body, so they can and should
     * be dispatched per-switch like flow entries. They previously all went to the OVS
     * strategy regardless.
     *
     * [Co-developed with claude code -- Adam]
     */
    OpResult dispatchByPayloadDpid(const json& j, const char* operation, StrategyCall call);

    /// Accessors so tests can assert *which* strategy was selected.
    IRoutingStrategy* ovsStrategy() const { return m_ovsStrategy.get(); }
    IRoutingStrategy* p4Strategy() const { return m_p4Strategy.get(); }

  private:
    std::shared_ptr<EventBus> m_eventBus;

    std::shared_ptr<TopologyAndFlowMonitor> m_topologyAndFlowMonitor;
    std::shared_ptr<sflow::FlowLinkUsageCollector> m_flowLinkUsageCollector;

    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    std::unique_ptr<IRoutingStrategy> m_ovsStrategy;
    std::unique_ptr<IRoutingStrategy> m_p4Strategy;
};