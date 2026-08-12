#pragma once

#include "utils/Utils.hpp" // For utils::DeploymentMode
#include <boost/asio/ip/tcp.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <memory>
#include <nlohmann/json.hpp>
#include "ndt_core/routing_management/OpResult.hpp" // [Co-developed with claude code -- Adam]

using json = nlohmann::json;

// Forward declarations to reduce header dependencies
class TopologyAndFlowMonitor;
class EventBus;
class FlowRoutingManager;
class DeviceConfigurationAndPowerManager;
class ApplicationManager;
class SimulationRequestManager;
class IntentTranslator;
class HistoricalDataManager;
class Controller;
class LockManager;

namespace sflow
{
class FlowLinkUsageCollector;
}

namespace beast = boost::beast;
namespace http = beast::http;
namespace net = boost::asio;
using tcp = net::ip::tcp;

/**
 * @class HttpSession
 * @brief Manages an asynchronous HTTP server session using Boost.Beast.
 *
 * This class handles reading an HTTP request from a connected socket,
 * processing it, and sending back an appropriate HTTP response. It is
 * designed to be managed by a std::shared_ptr and keeps itself alive
 * during asynchronous operations.
 */
class HttpSession : public std::enable_shared_from_this<HttpSession>
{
  public:
    /**
     * @brief Construct a new Http Session object.
     * @param socket The connected TCP socket to handle.
     * @param ...deps Various shared pointers to core application components.
     */
    HttpSession(
        tcp::socket socket,
        std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
        std::shared_ptr<EventBus> eventBus,
        int mode,
        std::shared_ptr<sflow::FlowLinkUsageCollector> collector,
        std::shared_ptr<FlowRoutingManager> flowRoutingManager,
        std::shared_ptr<DeviceConfigurationAndPowerManager> deviceConfigurationAndPowermanager,
        std::shared_ptr<ApplicationManager> appManager,
        std::shared_ptr<SimulationRequestManager> simManager,
        std::shared_ptr<IntentTranslator> intentTranslator,
        std::shared_ptr<HistoricalDataManager> historicalDataManager,
        std::shared_ptr<Controller> ctrl,
        std::shared_ptr<LockManager> lockManager);

    /**
     * @brief Starts the asynchronous operation for the session.
     */
    void start();

  private:
    // [Co-developed with claude code -- Adam]
    // Test seam. tests/test_HttpSessionRouting.cpp constructs a session over an unconnected
    // socket, sets m_req and calls buildResponse(), which does no I/O. Granted to one named peer
    // rather than opening the routing internals up, and preferred over testing extracted helpers
    // because the thing worth asserting -- which status code an endpoint answers with -- is
    // decided by the catch clauses in buildResponse and is not observable anywhere else.
    friend class HttpSessionTestPeer;

    // [Co-developed with claude code -- Adam]
    // Second peer, for tests/test_HttpSessionStatusCodes.cpp. Separate from HttpSessionTestPeer
    // rather than an overload of it because that class lives in another translation unit and one
    // name can only have one definition; two peers is the ODR-safe way for two test files to
    // reach the same seam. This one supplies real collaborators (a LockManager, a
    // HistoricalDataManager) because the endpoints it covers are asserted on their *success*
    // paths as well as their refusals.
    friend class HttpSessionStatusTestPeer;

    // --- Asynchronous Operation Handlers ---
    void readRequest();
    void onRead(beast::error_code ec, std::size_t bytesTransferred);
    void writeResponse();
    void onWrite(beast::error_code ec, std::size_t bytesTransferred);
    void closeSocket();

    // --- Request Routing and Handling ---
    void handleRequest();

    /**
     * @brief Route m_req to its handler and return the response, mapping any escaping exception
     *        to a status code: json::exception to 400, anything else to 500.
     *
     * Performs no socket I/O; handleRequest() is this followed by writeResponse().
     *
     * @return The response to send. Never null.
     */
    std::shared_ptr<http::response<http::string_body>> buildResponse();

    // Each API endpoint gets its own handler function for clarity.
    /**
     * @brief Handles a link-failure notification sent by the Ryu controller.
     *
     * This HTTP handler is invoked by Ryu when a link-down event is detected in the OpenFlow
     * network (e.g., port/link failure). It parses the request payload, marks the corresponding
     * directed edge(s) as DOWN in the topology monitor (both directions if present), and emits
     * LinkFailureDetected events on the internal event bus.
     *
     * Error responses:
     * - 400 Bad Request if the payload is invalid
     * - 404 Not Found if the referenced edge is not found in the current topology
     *
     * @param[out] res HTTP response returned to Ryu (status code + JSON body).
     *
     * @note This endpoint is triggered by the Ryu application (controller -> this service),
     *       not directly by the switches.
     */
    void handleLinkFailure(http::response<http::string_body>& res);
    /**
     * @brief Handles a link-recovery notification sent by the Ryu controller.
     *
     * This HTTP handler is invoked by Ryu when it detects that a previously failed link
     * between two switches/ports has come back up. It validates the JSON payload, looks up
     * the corresponding topology edge(s), marks them UP in the topology monitor (forward
     * direction and reverse direction if present), and returns a JSON acknowledgement.
     *
     * Error responses:
     * - 400 Bad Request: missing required JSON fields
     * - 404 Not Found: referenced edge does not exist in the current topology
     *
     * @param[out] res HTTP response returned to Ryu (status code + JSON body).
     *
     * @note This endpoint is triggered by the Ryu application (controller -> this service),
     *       not directly by the switches.
     */
    void handleLinkRecovery(http::response<http::string_body>& res);
    /**
     * @brief Returns the current topology graph (nodes + edges) as JSON.
     *
     * This HTTP handler queries the in-memory topology graph from TopologyAndFlowMonitor and
     * serializes it into a JSON object with two arrays:
     *   - "nodes": all vertex properties
     *   - "edges": per-link attributes including state (is_up), bandwidth/usage/utilization,
     *              endpoints (dpid/interface/ip), flow_set, and enable flags.
     *
     * @param[out] res HTTP response containing the serialized graph JSON.
     *
     * @note Intended for clients that need to visualize or consume the live network graph
     *       (e.g., GUI/dashboard). In MININET mode, "left_link_bandwidth_bps" is derived from
     *       flow samples; otherwise it reflects the configured/measured link bandwidth.
     */
    void handleGetGraphData(http::response<http::string_body>& res);
    /**
     * @brief Returns the currently detected flows and their estimated rates as JSON.
     *
     * This HTTP handler serializes the current flow table maintained by FlowLinkUsageCollector
     * (learned from sFlow/telemetry) and returns it as a JSON array. Each element contains the
     * 5-tuple (src/dst IP, src/dst port, protocol), estimated sending/packet rates (periodic
     * and immediate), first/latest sampled timestamps, and the computed path (node/interface list).
     *
     * @param[out] res HTTP response whose body is set to the serialized detected-flow JSON.
     *
     * @note Intended for clients such as a dashboard/GUI to query live flow visibility.
     */
    void handleGetDetectedFlowData(http::response<http::string_body>& res);

    /**
     * @brief Returns the top-K detected flows (ranked by estimated rate) as JSON.
     *
     * This HTTP handler queries the current flow table maintained by FlowLinkUsageCollector and
     * returns only the top-K flows according to a ranking metric (the most recent
     * estimated sending rate). The response body is a JSON array where each element contains
     * the flow’s 5-tuple (src/dst IP, src/dst port, protocol), estimated sending/packet rates
     * (periodic and immediate), first/latest sampled timestamps, and the computed path
     * (node/interface list), consistent with handleGetDetectedFlowData().
     *
     * @param[out] res HTTP response whose body is set to the serialized top-K detected-flow JSON.
     *
     * @note Intended for dashboards/GUI clients to fetch a bounded subset of “heavy hitter” flows
     *       to reduce payload size and query latency compared to the full flow list.
     * @note The value of K and the ranking metric may be configured by the request (e.g., query
     *       parameter) or by server defaults, depending on the API design.
     */
    void handleGetDetectedTopKFlowData(http::response<http::string_body>& res);
    /**
     * @brief Returns the cached OpenFlow flow entries for all switches as JSON.
     *
     * This HTTP handler serves a snapshot of the current OpenFlow tables maintained by
     * DeviceConfigurationAndPowerManager. The data is read from an in-memory cache that is
     * periodically refreshed by a background worker, so the response may be up to one update
     * interval stale.
     *
     * @param[out] res HTTP response whose body is set to the JSON-serialized OpenFlow tables.
     *
     * @note Intended for clients (e.g., GUI/debug tools) to inspect the controller-installed
     *       OpenFlow rules per switch (dpid).
     */
    void handleGetSwitchOpenflowEntries(http::response<http::string_body>& res);
    /**
     * @brief Returns the latest cached device power report as JSON.
     *
     * This HTTP handler serves a snapshot of the current power metrics maintained by
     * DeviceConfigurationAndPowerManager. The returned data comes from an in-memory cache that
     * is refreshed periodically by a background status update worker, so the response may be
     * slightly stale relative to real-time switch state.
     *
     * @param[out] res HTTP response whose body is set to the JSON-serialized power report.
     *
     * @note Intended for monitoring/visualization clients (e.g., GUI/dashboard).
     */
    void handleGetPowerReport(http::response<http::string_body>& res);
    /**
     * @brief Returns power state (ON/OFF) for switches, optionally filtered by switch IP.
     *
     * This HTTP handler parses the request target for an optional "ip" query parameter and
     * returns a JSON object mapping switch_ip -> power_state.
     * - In TESTBED mode, it queries the smart-plug proxy (via /relay) for each switch.
     * - In MININET mode, it derives power state from the topology monitor (vertex up/down).
     *
     * If an unknown switch IP is requested, the handler returns 404 with an error message.
     *
     * @param[out] res HTTP response containing the JSON-serialized power-state map.
     */
    void handleGetSwitchesPowerState(http::response<http::string_body>& res);
    /**
     * @brief Sets the power state of a specific switch (on/off) via query parameters.
     *
     * This HTTP handler expects two query parameters:
     *   - ip=<switch_ip>
     *   - action=on|off
     *
     * It validates the parameters and delegates the operation to
     * DeviceConfigurationAndPowerManager::setSwitchPowerState(). In TESTBED mode, the power
     * change is performed through the smart-plug /relay proxy; in MININET mode, it toggles the
     * switch vertex state in the simulated topology.
     *
     * Responses:
     *  - 200 OK with { "<ip>": "Success" } on success
     *  - 400 Bad Request if ip/action is missing or invalid
     *  - 500 Internal Server Error if the power change fails
     *
     * @param[out] res HTTP response returned to the caller (status code + JSON body).
     */
    void handleSetSwitchesPowerState(http::response<http::string_body>& res);
    /**
     * @brief Installs a single OpenFlow rule (one entry) via HTTP.
     *
     * Expects the request body to be a JSON object representing one flow entry
     * (e.g., { "dpid", "priority", "match", "actions", ... }). The entry is wrapped into a
     * batch request under "install_flow_entries" and forwarded to processFlowBatch().
     *
     * @param[out] res HTTP response returned to the caller.
     */
    void handleInstallFlowEntry(http::response<http::string_body>& res);
    /**
     * @brief Deletes a single OpenFlow rule (one entry) via HTTP.
     *
     * Expects the request body to be a JSON object that identifies the flow to delete
     * (e.g., { "dpid", "match", ... }). The entry is wrapped into a batch request under
     * "delete_flow_entries" and forwarded to processFlowBatch().
     *
     * @param[out] res HTTP response returned to the caller.
     */
    void handleDeleteFlowEntry(http::response<http::string_body>& res);
    /**
     * @brief Modifies a single OpenFlow rule (one entry) via HTTP.
     *
     * Expects the request body to be a JSON object representing a flow entry update
     * (e.g., { "dpid", "priority", "match", "actions", ... }). The entry is wrapped into a
     * batch request under "modify_flow_entries" and forwarded to processFlowBatch().
     *
     * @param[out] res HTTP response returned to the caller.
     */
    void handleModifyFlowEntry(http::response<http::string_body>& res);
    /**
     * @brief Installs an OpenFlow group entry via the Ryu REST API.
     *
     * This HTTP handler is invoked by the Ryu application (or a northbound client) with a JSON
     * payload describing a group entry. The payload is forwarded to FlowRoutingManager, which
     * relays the request to Ryu's REST endpoint (/stats/groupentry/add).
     *
     * @param[out] res HTTP response returned to the caller (JSON acknowledgement).
     *
     * @note The request body must be valid JSON in the format expected by Ryu's group-entry API.
     */
    /**
     * @brief Maps a southbound OpResult onto the HTTP response.
     *
     * 501 when the data plane cannot express the operation; 502 when the controller failed, never
     * answered, **or answered 2xx with an error body** -- HttpRoutingStrategyBase turns that last
     * case into OpResult::failure, so it arrives here indistinguishable from a transport failure and
     * is reported as one, which is the honest answer: the operation did not happen. Otherwise the
     * controller's own 4xx/5xx is passed through unchanged, and anything outside 400-599 becomes
     * 502 rather than being forwarded as a status the caller cannot interpret.
     *
     * Replaces handlers that discarded the result and answered 200 regardless.
     *
     * The 2xx-with-error-body path was missing from this comment, which the http-routing review
     * caught as M5. It is the case most worth naming: a proxy reporting failure inside a success
     * envelope is exactly the conflation this whole mechanism exists to remove, so a reader needs to
     * know it is handled here rather than looking for it upstream.
     *
     * [Co-developed with claude code -- Adam]
     */
    void respondToOpResult(http::response<http::string_body>& res,
                           const OpResult& result,
                           const char* successMessage);

    void handleInstallGroupEntry(http::response<http::string_body>& res);
    /**
     * @brief Deletes an OpenFlow group entry via the Ryu REST API.
     *
     * Parses the JSON request body that identifies the group entry to remove and forwards it
     * to FlowRoutingManager, which calls Ryu's REST endpoint (/stats/groupentry/delete).
     *
     * @param[out] res HTTP response returned to the caller (JSON acknowledgement).
     */
    void handleDeleteGroupEntry(http::response<http::string_body>& res);
    /**
     * @brief Modifies an existing OpenFlow group entry via the Ryu REST API.
     *
     * Parses the JSON request body describing the updated group entry and forwards it to
     * FlowRoutingManager, which calls Ryu's REST endpoint (/stats/groupentry/modify).
     *
     * @param[out] res HTTP response returned to the caller (JSON acknowledgement).
     */
    void handleModifyGroupEntry(http::response<http::string_body>& res);
    /**
     * @brief Installs an OpenFlow meter entry via the Ryu REST API.
     *
     * Parses the JSON request body describing a meter entry and forwards it to FlowRoutingManager,
     * which calls Ryu's REST endpoint (/stats/meterentry/add).
     *
     * @param[out] res HTTP response returned to the caller (JSON acknowledgement).
     *
     * @note The request body must be valid JSON in the format expected by Ryu's meter-entry API.
     */
    void handleInstallMeterEntry(http::response<http::string_body>& res);
    /**
     * @brief Deletes an OpenFlow meter entry via the Ryu REST API.
     *
     * Parses the JSON request body that identifies the meter entry to remove and forwards it to
     * FlowRoutingManager, which calls Ryu's REST endpoint (/stats/meterentry/delete).
     *
     * @param[out] res HTTP response returned to the caller (JSON acknowledgement).
     */
    void handleDeleteMeterEntry(http::response<http::string_body>& res);
    /**
     * @brief Modifies an existing OpenFlow meter entry via the Ryu REST API.
     *
     * Parses the JSON request body describing the updated meter entry and forwards it to
     * FlowRoutingManager, which calls Ryu's REST endpoint (/stats/meterentry/modify).
     *
     * @param[out] res HTTP response returned to the caller (JSON acknowledgement).
     */
    void handleModifyMeterEntry(http::response<http::string_body>& res);
    /**
     * @brief Applies a batch of OpenFlow rule operations (install/modify/delete) via HTTP.
     *
     * Expects the request body to be a JSON object with three array fields:
     *   - "install_flow_entries": [ ... ]
     *   - "modify_flow_entries" : [ ... ]
     *   - "delete_flow_entries" : [ ... ]
     *
     * The request is validated and executed by processFlowBatch().
     *
     * @param[out] res HTTP response returned to the caller.
     */
    void handleInstallModifyDeleteFlowEntries(http::response<http::string_body>& res);
    /**
     * @brief Returns the latest cached CPU utilization report as JSON.
     *
     * This HTTP handler serves a snapshot of CPU utilization metrics collected by
     * DeviceConfigurationAndPowerManager. The response is backed by an in-memory cache
     * (m_cachedCpuReport) that is refreshed asynchronously by statusUpdateWorker(), so the
     * returned data may lag behind real-time device readings by up to the polling interval.
     *
     * @param[out] res HTTP response whose body is set to the JSON-serialized CPU report.
     *
     * @note Intended for monitoring/visualization clients (e.g., dashboard/GUI).
     */
    void handleGetCpuUtilization(http::response<http::string_body>& res);
    /**
     * @brief Returns the latest cached memory utilization report as JSON.
     *
     * This HTTP handler serves a snapshot of memory utilization metrics collected by
     * DeviceConfigurationAndPowerManager. The response is backed by an in-memory cache
     * (m_cachedMemoryReport) that is refreshed asynchronously by statusUpdateWorker(), so the
     * returned data may be slightly stale relative to the current device state.
     *
     * @param[out] res HTTP response whose body is set to the JSON-serialized memory report.
     *
     * @note Intended for monitoring/visualization clients (e.g., dashboard/GUI).
     */
    void handleGetMemoryUtilization(http::response<http::string_body>& res);
    /**
     * @brief Handles a "switch entered" notification from the Ryu controller.
     *
     * This function is called when the Ryu controller reports that an OpenFlow switch has
     * successfully connected (i.e., a SwitchEnter / datapath join event). The handler
     * acknowledges the event by populating the HTTP response (status code + body), and may
     * also trigger internal bookkeeping such as registering the switch or updating state.
     *
     * @param[out] res HTTP response returned to Ryu (e.g., 200 OK with an acknowledgement body).
     *
     * @note This is invoked by Ryu (controller -> this service), not by the switch directly.
     */
    void handleInformSwitchEntered(http::response<http::string_body>& res);
    /**
     * @brief Updates the human-readable device name for a switch or host.
     *
     * This HTTP handler accepts a JSON request body with:
     *   - "vertex_type": 0 for switch, 1 for host
     *   - "new_name":    new device name string
     *   - If vertex_type == 0: "dpid" (uint64) to identify the switch
     *   - If vertex_type == 1: "mac"  (string) to identify the host
     *
     * The handler locates the corresponding vertex in the current topology graph and updates
     * its deviceName via TopologyAndFlowMonitor::setVertexDeviceName(). The updated name is
     * also persisted to the topology configuration file by the monitor.
     *
     * Responses:
     *   - 200 OK with {"status":"Device name updated successfully."} on success
     *   - 400 Bad Request if vertex_type is invalid
     *   - 404 Not Found if the target device cannot be found in the graph
     *
     * @param[out] res HTTP response returned to the caller.
     *
     * @note Intended for UI/configuration clients to rename nodes in the topology view.
     */
    void handleModifyDeviceName(http::response<http::string_body>& res);
    /**
     * @brief Receives a simulation case request and forwards it to the external simulation server.
     *
     * This HTTP handler accepts a JSON request body describing a simulation case, then delegates
     * to SimulationRequestManager::requestSimulation() to POST the payload to the configured
     * simulation server (SIM_SERVER_URL). The handler responds with HTTP 202 (Accepted) and a
     * JSON acknowledgement containing the simulation server's response string.
     *
     * Response:
     *   - 202 Accepted with {"status":"<simulation_server_response>"} on success
     *
     * @param[out] res HTTP response returned to the caller.
     *
     * @note This endpoint only forwards the request; it does not run the simulation locally.
     */
    void handleReceivedSimulationCase(http::response<http::string_body>& res);
    /**
     * @brief Handles a simulation-completed callback and forwards the result to the registered
     * application.
     *
     * This HTTP handler is invoked when the simulation service reports completion. It parses the
     * JSON request body, extracts "app_id", and delegates to
     * SimulationRequestManager::onSimulationResult() to forward the full result payload to the
     * application-specific callback URL associated with that app_id.
     *
     * Response:
     *   - 200 OK with {"status":"result forwarded"} (acknowledgement that forwarding was triggered)
     *
     * @param[out] res HTTP response returned to the caller.
     *
     * @note Forwarding to the application is performed asynchronously; this endpoint only
     * acknowledges receipt and initiation of forwarding.
     */
    void handleSimulationCompleted(http::response<http::string_body>& res);
    void handleGetStaticTopology(http::response<http::string_body>& res);
    /**
     * @brief Receives and stores all-destination paths computed/installed by the Ryu controller.
     *
     * This HTTP handler is invoked by the Ryu application after it installs the
     * "all-destination" OpenFlow entries and computes the corresponding forwarding paths.
     * The request body must contain an "all_destination_paths" field, which is a list of paths.
     *
     * Expected payload (conceptually):
     *   {
     *     "all_destination_paths": [
     *       [ [node_id_or_ip, port], [node_id_or_ip, port], ... ],   // one path
     *       ...
     *     ]
     *   }
     *
     * For each hop, node_id may be a numeric datapath/node identifier or an IP string (converted
     * to uint32). Port may be numeric or a numeric string. Parsed paths are converted to
     * std::vector<sflow::Path> (each Path is a vector of (nodeId, port) pairs) and stored in
     * FlowLinkUsageCollector via setAllPaths().
     *
     * @param[out] res HTTP response returned to Ryu (JSON acknowledgement).
     *
     * @note This endpoint is triggered by Ryu (controller -> this service), not directly by
     * switches.
     */
    void handleInformAllDestinationPaths(http::response<http::string_body>& res);
    /**
     * @brief Registers an external application and returns an application ID.
     *
     * This HTTP handler accepts a JSON request body containing:
     *   - "app_name": string identifying the application
     *   - "simulation_completed_url": string callback URL to receive simulation completion results
     *
     * On success, it registers the application via ApplicationManager and returns a JSON response
     * containing the assigned "app_id". On invalid input, it returns 400 Bad Request with an
     * error message.
     *
     * Responses:
     *   - 200 OK: {"app_id": <int>, "message": "Application registered successfully"}
     *   - 400 Bad Request: {"error": "..."} if required fields are missing/invalid
     *
     * @param[out] res HTTP response returned to the caller.
     *
     * @note The registered callback URL is later used to forward simulation results when a
     *       simulation-completed event is received.
     */
    void handleAppRegister(http::response<http::string_body>& res);
    void handleNotFound(http::response<http::string_body>& res);
    void handleInputTextIntent(http::response<http::string_body>& res);
    void handleGetNickname(http::response<http::string_body>& res);
    void handleModifyNickname(http::response<http::string_body>& res);
    /**
     * @brief Returns the latest cached temperature report as JSON.
     *
     * This HTTP handler serves a snapshot of device temperature metrics maintained by
     * DeviceConfigurationAndPowerManager. The data is returned from an in-memory cache
     * (m_cachedTemperatureReport) that is refreshed asynchronously by statusUpdateWorker(),
     * therefore the response may lag behind real-time readings by up to the polling interval.
     *
     * @param[out] res HTTP response whose body is set to the JSON-serialized temperature report.
     *
     * @note Intended for monitoring/visualization clients (e.g., dashboard/GUI).
     */
    void handleGetTemperature(http::response<http::string_body>& res);
    /**
     * @brief Returns hop-distance (switch count) for host-to-host paths to support NTG flow
     * generation.
     *
     * This HTTP handler reports the number of switches on the forwarding path between two hosts.
     * It is primarily used by the Network Traffic Generator (NTG) to estimate “distance” between
     * host pairs and compare it with topology diameter, enabling categorization of flows into
     * near / middle / far groups.
     *
     * Query parameters:
     *   - src_ip (optional): source host IPv4 string
     *   - dst_ip (optional): destination host IPv4 string
     *
     * Behavior:
     *   - If both src_ip and dst_ip are provided, returns the switch count for that specific
     *     host pair using FlowLinkUsageCollector::getSwitchCount().
     *   - If either parameter is missing, returns switch counts for all known host pairs using
     *     FlowLinkUsageCollector::getAllSwitchCounts().
     *
     * Response (specific lookup):
     *   - 200 OK: {"status":"success","src_ip":"...","dst_ip":"...","switch_count":N}
     *   - 404 Not Found: {"status":"error","message":"Path not found for the given IPs."}
     *
     * Response (all pairs):
     *   - 200 OK: {"status":"success","data":[{"src_ip":"...","dst_ip":"...","switch_count":N},
     * ...]}
     *
     * @param[out] res HTTP response returned to the caller (JSON).
     *
     * @note “switch_count” represents hop distance in terms of traversed switches (not including
     * hosts).
     */
    void handleGetPathSwitchCount(http::response<http::string_body>& res);
    void handleGetOpenflowCapacity(http::response<http::string_body>& res);
    void handleSetHistoricalLoggingState(http::response<http::string_body>& res);
    /**
     * @brief Returns the average utilization of active inter-switch links in the current topology.
     *
     * This HTTP handler computes and returns the mean link utilization across the topology graph.
     * The average is calculated by TopologyAndFlowMonitor::getAvgLinkUsage() using only:
     *   - links that are **usable** -- `isUsable(edge)`, i.e. `isUp && isEnabled &&
     *     !adminDisabled`,
     *   - links whose endpoints are both switches (HOST vertices are excluded),
     *   - links with non-zero measured usage (edge.linkBandwidthUsage != 0).
     *
     * [Co-developed with claude code -- Adam]
     * The first bullet used to read "links that are currently UP (edge.isUp == true)". That was
     * the predicate before adminDisabled existed, and the implementation deliberately abandoned
     * it: `isUp` alone was the only one of the six availability checks not taking the full
     * intersection, so a link an operator had taken out of service still counted towards the
     * average as long as residual traffic was flowing over it. The .cpp comment above the filter
     * records the same reasoning. This figure is what Energy-Saving-App reads, so a header that
     * teaches the superseded predicate is a header that misdescribes the input to another
     * component's decisions.
     *
     * For each qualifying directed edge, utilization is computed as:
     *   linkBandwidthUsage / linkBandwidth
     * and the handler returns the arithmetic mean across all qualifying edges.
     *
     * Response:
     *   - 200 OK: {"status":"success","avg_link_usage":<double>}
     *
     * @param[out] res HTTP response returned to the caller (JSON).
     *
     * @note If no qualifying links exist, avg_link_usage is 0.
     */
    void handleGetAvgLinkUsage(http::response<http::string_body>& res);
    /**
     * @brief Returns the total incoming traffic load (bps) entering a given switch.
     *
     * This HTTP handler expects a JSON request body containing:
     *   - "dpid" (uint64): datapath ID of the target switch.
     *
     * It scans the current topology graph and sums the link bandwidth usage
     * (edge.linkBandwidthUsage) of all directed edges whose destination switch matches the given
     * dpid (i.e., edges where e.dstDpid == dpid). The resulting sum represents the aggregate input
     * traffic load currently arriving at that switch (in bits per second).
     *
     * Response:
     *   - success: {"status":"success","total_input_traffic_load_bps":<uint64>}
     *   - error  : {"status":"error","message":"dpid missing"} if "dpid" is not provided
     *
     * @param[out] res HTTP response returned to the caller (JSON).
     *
     * @note This sums per-edge usage values from the in-memory graph snapshot. It does not
     *       account for link direction normalization or packet drops; it simply aggregates
     *       all edges terminating at the specified dpid.
     */
    void handleGetTotalInputTrafficLoadPassingASwitch(http::response<http::string_body>& res);
    /**
     * @brief Returns the total number of flows entering/passing through a given switch.
     *
     * This HTTP handler expects a JSON request body containing:
     *   - "dpid" (uint64): datapath ID of the target switch.
     *
     * It takes a snapshot of the current topology graph and iterates over all directed edges.
     * For each edge whose destination switch matches the given dpid (e.dstDpid == dpid), it adds
     * the size of that edge's flowSet to an accumulator. The final value represents the total
     * count of flow identifiers currently associated with incoming links to the specified switch.
     *
     * Response:
     *   - success: {"status":"success","num_of_flows":<int>}
     *   - error  : {"status":"error","message":"dpid missing"} if "dpid" is not provided
     *
     * @param[out] res HTTP response returned to the caller (JSON).
     *
     * @note This is an aggregate count across all incoming edges. If the same flow key appears on
     *       multiple incoming edges, it will be counted multiple times (no global deduplication).
     */
    void handleGetNumOfFlowsPassingASwitch(http::response<http::string_body>& res);
    /**
     * @brief Attempts to acquire a global application lock to prevent conflicting operations.
     *
     * This endpoint provides mutual exclusion for operations that should not run concurrently
     * across applications (e.g., topology updates, flow programming, power actions). The caller
     * may specify a lock "type" and a time-to-live ("ttl") in seconds; if the request body is
     * missing/invalid JSON, default values are used.
     *
     * Request body (optional JSON):
     *   - "type": string lock category/name (defaults to LockManager::DEFAULT_LOCK_TYPE_STR)
     *   - "ttl" : integer TTL seconds (defaults to LockManager::DEFAULT_TTL_SECONDS)
     *
     * Responses:
     *   - 200 OK:   {"status":"locked","type":"...","ttl":N} if the lock is acquired
     *   - 423 Locked: {"error":"Lock acquisition failed", ...} if already held or invalid type
     *   - 500 Internal Server Error on unexpected failures
     *
     * @param[out] res HTTP response returned to the caller (JSON).
     *
     * @note TTL is used to automatically expire the lock if the owner crashes or fails to renew.
     */
    void handleAcquireLock(http::response<http::string_body>& res);
    /**
     * @brief Renews (extends) an existing application lock to prevent it from expiring.
     *
     * This endpoint extends the TTL of an already-held lock to maintain exclusive access while
     * a long-running operation is in progress. The caller may specify "type" and "ttl"; missing
     * or invalid JSON falls back to LockManager defaults.
     *
     * Request body (optional JSON):
     *   - "type": string lock category/name (defaults to LockManager::DEFAULT_LOCK_TYPE_STR)
     *   - "ttl" : integer TTL seconds (defaults to LockManager::DEFAULT_TTL_SECONDS)
     *
     * Responses:
     *   - 200 OK: {"status":"renewed","type":"...","ttl":N} if renewal succeeds
     *   - 412 Precondition Failed if the lock is expired, not held, or the type is invalid
     *   - 400 Bad Request for malformed requests (fallback error path)
     *
     * @param[out] res HTTP response returned to the caller (JSON).
     */
    void handleRenewLock(http::response<http::string_body>& res);
    /**
     * @brief Releases an application lock, allowing other applications to proceed.
     *
     * This endpoint unlocks the specified lock type (or the default lock type if not provided).
     * It is used when the caller finishes a protected operation and wants to relinquish exclusive
     * access so that other applications can acquire the lock.
     *
     * Request body (optional JSON):
     *   - "type": string lock category/name (defaults to LockManager::DEFAULT_LOCK_TYPE_STR)
     *
     * Responses:
     *   - 200 OK: {"status":"released","type":"..."} on success
     *   - 500 Internal Server Error if releasing fails unexpectedly
     *
     * @param[out] res HTTP response returned to the caller (JSON).
     */
    void handleReleaseLock(http::response<http::string_body>& res);

    void processFlowBatch(const json& j, http::response<http::string_body>& res);

    std::function<void()> after_write_;

    void doClose()
    {
        beast::error_code ec;
        m_socket.shutdown(tcp::socket::shutdown_send, ec);
    }

    // --- Member Variables ---
    tcp::socket m_socket;
    beast::flat_buffer m_buffer;
    http::request<http::string_body> m_req;

    // The response must be stored in a shared_ptr to keep it alive during async write
    std::shared_ptr<http::response<http::string_body>> m_res;

    // Core application components (dependencies)
    std::shared_ptr<TopologyAndFlowMonitor> m_topologyAndFlowMonitor;
    std::shared_ptr<EventBus> m_eventBus;
    utils::DeploymentMode m_mode;
    std::shared_ptr<sflow::FlowLinkUsageCollector> m_flowLinkUsageCollector;
    std::shared_ptr<FlowRoutingManager> m_flowRoutingManager;
    std::shared_ptr<DeviceConfigurationAndPowerManager> m_deviceConfigurationAndPowerManager;
    std::shared_ptr<ApplicationManager> m_applicationManager;
    std::shared_ptr<SimulationRequestManager> m_simulationRequestManager;
    std::shared_ptr<IntentTranslator> m_intentTranslator;
    std::shared_ptr<HistoricalDataManager> m_historicalDataManager;
    std::shared_ptr<Controller> m_controller;
    std::shared_ptr<LockManager> m_lockManager;
};