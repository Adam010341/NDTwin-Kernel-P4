#include "ndt_core/http/HttpSession.hpp"
#include "event_system/EventBus.hpp"
#include "event_system/EventPayloads.hpp"
#include "event_system/PayloadTypes.hpp"
#include "event_system/RequestParser.hpp"
#include "ndt_core/application_management/ApplicationManager.hpp"
#include "ndt_core/application_management/SimulationRequestManager.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/data_management/HistoricalDataManager.hpp"
#include "ndt_core/intent_translator/IntentTranslator.hpp"
#include "ndt_core/lock_management/LockManager.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "ndt_core/routing_management/Controller.hpp"
#include "ndt_core/routing_management/DispatchOutcomeLog.hpp"
#include "ndt_core/routing_management/FlowJob.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "utils/Logger.hpp"
// [Co-developed with claude code -- Adam] B-6: the netem half of /ndt/inject_link_failure.
#include "utils/NetemLinkFault.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <nlohmann/json.hpp>
#include <string>
#include <string_view>

using json = nlohmann::json;

HttpSession::HttpSession(
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
    std::shared_ptr<LockManager> lockManager)
    : m_socket(std::move(socket)),
      m_topologyAndFlowMonitor(std::move(topologyAndFlowMonitor)),
      m_eventBus(std::move(eventBus)),
      m_mode(static_cast<utils::DeploymentMode>(mode)),
      m_flowLinkUsageCollector(std::move(collector)),
      m_flowRoutingManager(std::move(flowRoutingManager)),
      m_deviceConfigurationAndPowerManager(std::move(deviceConfigurationAndPowermanager)),
      m_applicationManager(std::move(appManager)),
      m_simulationRequestManager(std::move(simManager)),
      m_intentTranslator(std::move(intentTranslator)),
      m_historicalDataManager(std::move(historicalDataManager)),
      m_controller(std::move(ctrl)),
      m_lockManager(std::move(lockManager))
{
}

void
HttpSession::start()
{
    readRequest();
}

void
HttpSession::readRequest()
{
    m_req = {}; // Clear request for reuse
    http::async_read(m_socket,
                     m_buffer,
                     m_req,
                     beast::bind_front_handler(&HttpSession::onRead, shared_from_this()));
}

void
HttpSession::onRead(beast::error_code ec, std::size_t bytes_transferred)
{
    boost::ignore_unused(bytes_transferred);

    if (ec == http::error::end_of_stream)
    {
        return closeSocket();
    }
    if (ec)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Read error: {}", ec.message());
        return;
    }

    handleRequest();
}

void
HttpSession::handleRequest()
{
    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "Got request: {} {}",
                       m_req.method_string(),
                       m_req.target());

    m_res = buildResponse();
    writeResponse();
}

// [Co-developed with claude code -- Adam]
// Split out of handleRequest so the routing table and the exception-to-status mapping can be
// exercised without a connected socket -- everything up to writeResponse() is a pure
// request-to-response function.
//
// That mapping is the part that needed a test. `?dpid=abc` and a non-numeric "app_id" were both
// answering 500 because std::stoull/std::stoi throw std::invalid_argument, which lands in the
// std::exception catch rather than the json::exception one. Both were fixed by parsing the value
// explicitly, but nothing could observe the fix: putting std::stoi back left the entire suite
// green, because a test that calls a validation helper directly never sees which catch clause
// would have run. Driving the real router is the only way that distinction is visible.
std::shared_ptr<http::response<http::string_body>>
HttpSession::buildResponse()
{
    auto response =
        std::make_shared<http::response<http::string_body>>(http::status::ok, m_req.version());
    response->keep_alive(m_req.keep_alive());
    response->set(http::field::server, "ndt-server");
    // To prevent CORS issue
    response->set(http::field::access_control_allow_origin, "*");
    response->set(http::field::access_control_allow_methods, "GET, POST, PUT, DELETE, OPTIONS");
    response->set(http::field::access_control_allow_headers,
                  "Content-Type, Authorization, X-Requested-With");
    response->set(http::field::access_control_max_age, "86400");

    response->set(http::field::content_type, "application/json");

    try
    {
        const auto method = m_req.method();
        const std::string_view target = m_req.target();
        const std::string targetStr(target);

        // OPTIONS
        if (method == http::verb::options)
        {
            response->result(http::status::no_content); // 204 No Content
            return response;
        }

        // --- API ROUTING ---
        if (method == http::verb::post && target == "/ndt/link_failure_detected")
        {
            handleLinkFailure(*response);
        }
        else if (method == http::verb::post && target == "/ndt/link_recovery_detected")
        {
            handleLinkRecovery(*response);
        }
        // [Co-developed with claude code -- Adam]
        // doc/KNOWN-ISSUES.md B-6. Separate routes from the two above, not a parameter on them:
        // the notification ("Ryu saw this fail") and the injection ("make this fail") are
        // different acts with different authority, and only one of them may run tc. Folding them
        // into one endpoint would mean a controller's routine notification could cut a link.
        else if (method == http::verb::post && target == "/ndt/inject_link_failure")
        {
            handleInjectLinkFailure(*response);
        }
        else if (method == http::verb::post && target == "/ndt/inject_link_recovery")
        {
            handleInjectLinkRecovery(*response);
        }
        else if (method == http::verb::get && target == "/ndt/get_graph_data")
        {
            handleGetGraphData(*response);
        }
        // [Co-developed with claude code -- Adam]
        // Was `target == "/ndt/get_detected_flow_data"`, an exact match, so the endpoint could
        // never carry a query string: `?liveness=all` fell through every branch and answered 404.
        // utils::pathIs matches the path and an optional query, which is also TIGHTER than the
        // `starts_with` used below -- that one accepts /ndt/get_detected_top_k_flow_dataXYZ.
        // The two routes cannot collide: the top-k path does not begin with this one.
        else if (method == http::verb::get && utils::pathIs(target, "/ndt/get_detected_flow_data"))
        {
            handleGetDetectedFlowData(*response);
        }
        else if (method == http::verb::get &&
                 utils::pathIs(target, "/ndt/get_detected_top_k_flow_data"))
        {
            handleGetDetectedTopKFlowData(*response);
        }
        else if (method == http::verb::get && target == "/ndt/get_switch_openflow_table_entries")
        {
            handleGetSwitchOpenflowEntries(*response);
        }
        else if (method == http::verb::get && target == "/ndt/get_flow_dispatch_status")
        {
            handleGetFlowDispatchStatus(*response);
        }
        else if (method == http::verb::get && target == "/ndt/get_power_report")
        {
            handleGetPowerReport(*response);
        }
        else if (method == http::verb::get && target.starts_with("/ndt/get_switches_power_state"))
        {
            handleGetSwitchesPowerState(*response);
        }
        else if (method == http::verb::post && target.starts_with("/ndt/set_switches_power_state"))
        {
            handleSetSwitchesPowerState(*response);
        }
        else if (method == http::verb::post && target == "/ndt/install_flow_entry")
        {
            handleInstallFlowEntry(*response);
        }
        else if (method == http::verb::post && target == "/ndt/delete_flow_entry")
        {
            handleDeleteFlowEntry(*response);
        }
        else if (method == http::verb::post && target == "/ndt/modify_flow_entry")
        {
            handleModifyFlowEntry(*response);
        }
        else if (method == http::verb::post && target == "/ndt/install_group_entry")
        {
            handleInstallGroupEntry(*response);
        }
        else if (method == http::verb::post && target == "/ndt/delete_group_entry")
        {
            handleDeleteGroupEntry(*response);
        }
        else if (method == http::verb::post && target == "/ndt/modify_group_entry")
        {
            handleModifyGroupEntry(*response);
        }
        else if (method == http::verb::post && target == "/ndt/install_meter_entry")
        {
            handleInstallMeterEntry(*response);
        }
        else if (method == http::verb::post && target == "/ndt/delete_meter_entry")
        {
            handleDeleteMeterEntry(*response);
        }
        else if (method == http::verb::post && target == "/ndt/modify_meter_entry")
        {
            handleModifyMeterEntry(*response);
        }
        else if (method == http::verb::post &&
                 target == "/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries")
        {
            handleInstallModifyDeleteFlowEntries(*response);
        }
        else if (method == http::verb::get && target == "/ndt/get_cpu_utilization")
        {
            handleGetCpuUtilization(*response);
        }
        else if (method == http::verb::get && target == "/ndt/get_memory_utilization")
        {
            handleGetMemoryUtilization(*response);
        }
        else if (method == http::verb::get && target.starts_with("/ndt/inform_switch_entered"))
        {
            handleInformSwitchEntered(*response);
        }
        else if (method == http::verb::post && target.starts_with("/ndt/modify_device_name"))
        {
            handleModifyDeviceName(*response);
        }
        else if (method == http::verb::post &&
                 target.starts_with("/ndt/received_a_simulation_case"))
        {
            handleReceivedSimulationCase(*response);
        }
        else if (method == http::verb::post && target.starts_with("/ndt/simulation_completed"))
        {
            handleSimulationCompleted(*response);
        }
        else if (method == http::verb::get && target.starts_with("/ndt/get_static_topology_json"))
        {
            handleGetStaticTopology(*response);
        }
        else if (method == http::verb::post &&
                 target.starts_with("/ndt/inform_all_destination_paths"))
        {
            handleInformAllDestinationPaths(*response);
        }
        else if (method == http::verb::post && target.starts_with("/ndt/app_register"))
        {
            handleAppRegister(*response);
        }
        else if (method == http::verb::post && target.starts_with("/ndt/intent_translator/text"))
        {
            handleInputTextIntent(*response);
        }
        else if (method == http::verb::get && target.starts_with("/ndt/get_nickname"))
        {
            handleGetNickname(*response);
        }
        else if (method == http::verb::post && target == "/ndt/modify_nickname")
        {
            handleModifyNickname(*response);
        }
        else if (method == http::verb::get && target.starts_with("/ndt/get_temperature"))
        {
            handleGetTemperature(*response);
        }
        else if (method == http::verb::get && target.starts_with("/ndt/get_path_switch_count"))
        {
            handleGetPathSwitchCount(*response);
        }
        else if (method == http::verb::get && target.starts_with("/ndt/get_openflow_capacity"))
        {
            handleGetOpenflowCapacity(*response);
        }
        else if (method == http::verb::post && target.starts_with("/ndt/historical_logging"))
        {
            handleSetHistoricalLoggingState(*response);
        }
        else if (method == http::verb::get && target.starts_with("/ndt/get_average_link_usage"))
        {
            handleGetAvgLinkUsage(*response);
        }
        // [Co-developed with claude code -- Adam] Round 4 lead 5(b): this path answered 404, and
        // so did every other name a consumer might try for the four sFlow drop counters.
        else if (method == http::verb::get && utils::pathIs(target, "/ndt/get_sflow_stats"))
        {
            handleGetSflowStats(*response);
        }
        else if (method == http::verb::post &&
                 target.starts_with("/ndt/get_total_input_traffic_load_passing_a_switch"))
        {
            handleGetTotalInputTrafficLoadPassingASwitch(*response);
        }
        else if (method == http::verb::post &&
                 target.starts_with("/ndt/get_num_of_flows_passing_a_switch"))
        {
            handleGetNumOfFlowsPassingASwitch(*response);
        }
        else if (method == http::verb::post && target.starts_with("/ndt/acquire_lock"))
        {
            handleAcquireLock(*response);
        }
        else if (method == http::verb::post && target.starts_with("/ndt/renew_lock"))
        {
            handleRenewLock(*response);
        }
        else if (method == http::verb::post && target.starts_with("/ndt/release_lock"))
        {
            handleReleaseLock(*response);
        }
        else
        {
            handleNotFound(*response);
        }
    }
    catch (const json::exception& e)
    {
        response->result(http::status::bad_request);
        response->body() = json{{"error", "JSON parsing error"}, {"details", e.what()}}.dump();
        // [Co-developed with claude code -- Adam]
        // WARN, not ERROR: this catch *is* the 400 path. Logging a malformed client request at
        // ERROR makes exactly the conflation the 500-to-400 work removed from the wire -- "you sent
        // rubbish" and "I am broken" become the same entry -- and it makes check_logs.py's rule
        // that an error line is never acceptable unusable, because a contract test that probes the
        // error paths fills the log with them on purpose.
        SPDLOG_LOGGER_WARN(Logger::instance(), "JSON exception in request handler: {}", e.what());
    }
    catch (const std::exception& e)
    {
        response->result(http::status::internal_server_error);
        response->body() = json{{"error", "Internal server error"}, {"details", e.what()}}.dump();
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "Standard exception in request handler: {}",
                            e.what());
    }
    catch (...)
    {
        response->result(http::status::internal_server_error);
        response->body() = json{{"error", "An unknown error occurred"}}.dump();
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Unknown exception in request handler.");
    }

    return response;
}

void
HttpSession::writeResponse()
{
    m_res->prepare_payload();
    SPDLOG_LOGGER_TRACE(Logger::instance(),
                        "Server reply with status {}: {}",
                        m_res->result_int(),
                        m_res->body());
    http::async_write(m_socket,
                      *m_res,
                      beast::bind_front_handler(&HttpSession::onWrite, shared_from_this()));
}

void
HttpSession::onWrite(beast::error_code ec, std::size_t bytes_transferred)
{
    boost::ignore_unused(bytes_transferred);

    if (ec)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Write error: {}", ec.message());
        return;
    }

    // Take & clear the hook so it runs at most once
    auto fn = std::move(after_write_);
    after_write_ = nullptr;

    // Offload heavy work so we don't block the I/O thread
    if (fn)
    {
        std::thread(std::move(fn)).detach();
    }

    // Honor keep-alive
    if (!m_res->keep_alive())
    {
        doClose();
        return;
    }

    m_res.reset(); // free the just-sent message
    readRequest(); // continue serving next request
}

void
HttpSession::closeSocket()
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Close Socket");
    beast::error_code ec;
    m_socket.shutdown(tcp::socket::shutdown_send, ec);
}

// [Co-developed with claude code -- Adam]
// doc/KNOWN-ISSUES.md B-6 (W8-7). The four link-transition endpoints address a link by the two
// dpids at its ends, and the shared refusal they all owe a caller who names dpid 0.
namespace
{

/**
 * @brief Whether a (src_dpid, dst_dpid) pair names two switches, which is the only thing these
 *        four endpoints can act on.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md B-6 §7-7, F-16, Adam's ruling of 2026-09-06 ("host edges are not addressed
 * by this endpoint"). A host vertex carries dpid 0, and findEdgeBySrcAndDstDpid matches on the two
 * dpids ALONE -- so `{"src_dpid":1,"dst_dpid":0}` resolves to whichever host edge of s1 the graph
 * happens to iterate first. Three separate things are wrong with letting that through and only the
 * first is obvious:
 *
 *   1. which host edge it lands on is decided by edge insertion order, not by the payload;
 *   2. updateHosts has no declaration veto (deliberately -- the veto belongs in updateLinks, where
 *      links live), so the declaration is set and the next host poll lifts `isUp` straight back:
 *      B-6 all over again, on the one shape of edge the fix does not cover;
 *   3. an operator who wrote a 0 by mistake gets a 200 and a fault somewhere they did not name.
 *
 * Refused at the door rather than vetoed deeper down, because this is an input-validation problem
 * and not a state-machine one: spraying the veto into updateHosts would be fixing the symptom of a
 * request the twin should never have accepted.
 *
 * @note Ryu never sends this: EventLinkAdd/EventLinkDelete are LLDP switch-to-switch events, and a
 *       host arrives through EventHostAdd, which does not reach these endpoints at all.
 */
bool
namesTwoSwitches(uint64_t srcDpid, uint64_t dstDpid)
{
    return srcDpid != 0 && dstDpid != 0;
}

/// The body a dpid-0 refusal carries. One string, so all four endpoints answer the same sentence.
constexpr const char* kHostEdgeRefusal =
    R"({"error":"src_dpid and dst_dpid must both name a switch: dpid 0 is the host end of a host )"
    R"(edge, and a host edge is not addressed by this endpoint -- it would resolve to whichever )"
    R"(host edge of the other switch comes first in the graph"})";

} // namespace

void
HttpSession::handleLinkFailure(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Link Failure");
    auto data = parseLinkFailedEventPayload(m_req.body());
    if (!data)
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Invalid link-failure payload"})";
        return;
    }
    if (!namesTwoSwitches(data->srcDpid, data->dstDpid))
    {
        res.result(http::status::bad_request);
        res.body() = kHostEdgeRefusal;
        return;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "link failed on {}:{} -> {}:{}",
                       data->srcDpid,
                       data->srcInterface,
                       data->dstDpid,
                       data->dstInterface);

    auto fwdOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({data->srcDpid, data->dstDpid});
    if (!fwdOpt.has_value())
    {
        res.result(http::status::not_found);
        res.body() = R"({"error":"edge not found in topology"})";
        return;
    }
    // [Co-developed with claude code -- Adam]
    // doc/KNOWN-ISSUES.md B-6. Not setEdgeDown: this is the push path, and calling the observation
    // writer from it is the defect -- the graph could not then tell "an operator told us this link
    // failed" from "the poll's own opinion", so the next updateLinks lifted it back. See
    // TopologyAndFlowMonitor.hpp for the writer split.
    //
    // W8b: ...ByReportedFailure, not ...ByDeclaration. THIS endpoint is Ryu's notification, so a
    // call to it is the control plane saying it SAW the break -- and that note is what the matching
    // /ndt/link_recovery_detected later pairs with. /ndt/inject_link_failure calls the plain
    // declaration writer instead, which is what makes an injection immune to a Ryu restart.
    m_topologyAndFlowMonitor->setEdgeDownByReportedFailure(fwdOpt.value());
    m_eventBus->emit(Event{.type = EventType::LinkFailureDetected,
                           .payload = LinkFailureEventData{fwdOpt.value()}});

    auto revOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({data->dstDpid, data->srcDpid});
    if (!revOpt)
    {
        // [Co-developed with claude code -- Adam]
        // Answered 200 "link failure processed" here for months. Every loader and discovery
        // path inserts edges in pairs, so a graph holding s->d without d->s is the kernel's own
        // state gone inconsistent -- hence 500, not 404: the sibling branch above uses 404 for
        // "nothing was done", and by this point the reported direction HAS been marked down and
        // its event emitted. The body says which half happened, because a caller that only reads
        // the status line otherwise repeats the fault-injection run against a graph the kernel
        // itself no longer believes.
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "link failure {}:{} -> {}:{}: reverse edge {} -> {} is missing from "
                           "the topology; forward direction marked down, reverse untouched",
                           data->srcDpid,
                           data->srcInterface,
                           data->dstDpid,
                           data->dstInterface,
                           data->dstDpid,
                           data->srcDpid);
        res.result(http::status::internal_server_error);
        res.body() =
            R"({"error":"reverse edge missing from the topology; the reported direction was marked down, its reverse was not"})";
        return;
    }
    m_topologyAndFlowMonitor->setEdgeDownByReportedFailure(revOpt.value());
    m_eventBus->emit(Event{.type = EventType::LinkFailureDetected,
                           .payload = LinkFailureEventData{revOpt.value()}});
    // [Co-developed with claude code -- Adam]
    // B-6. The body now says how long this lasts, because the answer changed and the old one was
    // never written down: the declaration stands until /ndt/link_recovery_detected withdraws it,
    // rather than until the next topology poll silently undoes it.
    res.body() =
        R"({"status":"link failure processed","down_reason":"declared","until":"/ndt/link_recovery_detected"})";
}

void
HttpSession::handleLinkRecovery(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Link Recovery");
    auto jsonData = json::parse(m_req.body());
    if (!jsonData.contains("src_dpid") || !jsonData.contains("dst_dpid") ||
        !jsonData.contains("src_interface") || !jsonData.contains("dst_interface"))
    {
        res.result(http::status::bad_request);
        res.body() =
            R"({"error":"Missing src_dpid or dst_dpid or src_interface or dst_interface"})";
        return;
    }

    uint64_t srcDpid = jsonData["src_dpid"].get<uint64_t>();
    uint32_t srcInterface = jsonData["src_interface"].get<uint32_t>();
    uint64_t dstDpid = jsonData["dst_dpid"].get<uint64_t>();
    uint32_t dstInterface = jsonData["dst_interface"].get<uint32_t>();

    if (!namesTwoSwitches(srcDpid, dstDpid))
    {
        res.result(http::status::bad_request);
        res.body() = kHostEdgeRefusal;
        return;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "link recovered on {}:{} -> {}:{}",
                       srcDpid,
                       srcInterface,
                       dstDpid,
                       dstInterface);

    auto fwdOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({srcDpid, dstDpid});
    if (!fwdOpt.has_value())
    {
        res.result(http::status::not_found);
        res.body() = R"({"error":"edge not found in topology"})";
        return;
    }
    // [Co-developed with claude code -- Adam]
    // doc/KNOWN-ISSUES.md B-6, and W8b changed which call this is. It used to be
    // `clearEdgeDeclaredDown(e); setEdgeUp(e);` -- an unconditional withdrawal, which made a Ryu
    // restart end every standing injection in the fabric (measured, lw8b 2026-09-07 00:08: within
    // one second of Ryu coming back the kernel logged a recovery POST for every link, and the
    // declaration was gone in 9 of 9 samples). One call now, and it withdraws only when this
    // report pairs with a failure the control plane reported. See applyReportedLinkRecovery.
    const auto fwdOutcome = m_topologyAndFlowMonitor->applyReportedLinkRecovery(fwdOpt.value());
    // TODO: Emit LinkRecoveryDetected event

    auto revOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({dstDpid, srcDpid});
    if (!revOpt)
    {
        // Same shape and same reasoning as handleLinkFailure above: edges exist in pairs, so a
        // missing reverse is kernel-state inconsistency, and by now the forward direction has
        // already been acted on -- report the half that happened. [Co-developed with claude code -- Adam]
        // W8b: "applied" rather than "marked up", because the forward direction may have kept a
        // declaration this report could not pair with. Saying "marked up" would be this branch
        // reporting the outcome it assumed rather than the one it got.
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "link recovery {}:{} -> {}:{}: reverse edge {} -> {} is missing from "
                           "the topology; forward direction applied ({}), reverse untouched",
                           srcDpid,
                           srcInterface,
                           dstDpid,
                           dstInterface,
                           dstDpid,
                           srcDpid,
                           fwdOutcome == LinkRecoveryOutcome::Retained ? "declaration retained"
                                                                      : "marked up");
        res.result(http::status::internal_server_error);
        res.body() =
            R"({"error":"reverse edge missing from the topology; the reported direction was applied, its reverse was not"})";
        return;
    }
    const auto revOutcome = m_topologyAndFlowMonitor->applyReportedLinkRecovery(revOpt.value());

    // [Co-developed with claude code -- Adam]
    // doc/KNOWN-ISSUES.md B-6 (W8b). Still 200 -- the notification WAS processed, and Ryu's
    // on_link_add logs "NDT REJECTED this notification ... the kernel's view is now stale" on any
    // 4xx, which would be false here and would fire once per link on every controller restart.
    // But 200 with the default body would be the older, worse lie: a caller reading only the
    // status line would believe a link is back that this kernel deliberately left down. So the
    // body says so, and names the endpoint that CAN withdraw it.
    if (fwdOutcome == LinkRecoveryOutcome::Retained || revOutcome == LinkRecoveryOutcome::Retained)
    {
        res.body() =
            R"({"status":"link recovery processed","declaration_retained":true,)"
            R"("detail":"a link failure is declared for this link and nothing ever reported it )"
            R"(broken, so this recovery report did not withdraw it and the link is still down. )"
            R"(That is what an injected failure surviving a control-plane restart looks like. )"
            R"(Withdraw it with POST /ndt/inject_link_recovery","until":"/ndt/inject_link_recovery"})";
        return;
    }
    res.body() = R"({"status":"link recovery processed"})";
}

// [Co-developed with claude code -- Adam]
// doc/KNOWN-ISSUES.md B-6. The two inject endpoints. Shared helpers first.
namespace
{

/// The Mininet interface for one end of a link, or empty when the graph cannot name it.
///
/// The bridge name comes from the topology file's `bridge_name`, which is what Mininet was told to
/// call the switch, so `<bridge>-eth<port>` is the interface it created. Returning empty rather
/// than guessing: a switch with no bridge_name is a topology this deployment mode was never
/// configured for, and inventing "s7-eth3" from a dpid would be a fault injected on whatever
/// interface happens to have that name.
std::string
mininetIfaceFor(const Graph& graph, uint64_t dpid, uint32_t port)
{
    for (auto v : boost::make_iterator_range(boost::vertices(graph)))
    {
        const auto& vp = graph[v];
        if (vp.vertexType == VertexType::SWITCH && vp.dpid == dpid &&
            !vp.bridgeNameForMininet.empty())
        {
            return utils::netem::mininetInterfaceName(vp.bridgeNameForMininet, port);
        }
    }
    return {};
}

} // namespace

void
HttpSession::handleInjectLinkFailure(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Inject Link Failure");
    auto data = parseLinkFailedEventPayload(m_req.body());
    if (!data)
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Invalid link-failure payload"})";
        return;
    }
    // W8-7. Refused here for the reason the notification endpoint refuses it, and one more: this
    // endpoint runs tc, so a dpid-0 payload would attach netem to whichever host-facing interface
    // the arbitrarily-chosen edge named. [Co-developed with claude code -- Adam]
    if (!namesTwoSwitches(data->srcDpid, data->dstDpid))
    {
        res.result(http::status::bad_request);
        res.body() = kHostEdgeRefusal;
        return;
    }

    auto fwdOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({data->srcDpid, data->dstDpid});
    if (!fwdOpt.has_value())
    {
        res.result(http::status::not_found);
        res.body() = R"({"error":"edge not found in topology"})";
        return;
    }
    auto revOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({data->dstDpid, data->srcDpid});
    if (!revOpt.has_value())
    {
        // Same reasoning as handleLinkFailure: edges exist in pairs, so a missing reverse is the
        // kernel's own state gone inconsistent. Refused BEFORE anything is changed here, unlike
        // the notification path -- an injection that half-happened would leave both the graph and
        // the machine's qdisc tree in a state the caller did not ask for and cannot name.
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "inject link failure {} -> {}: reverse edge is missing from the "
                           "topology; nothing was injected",
                           data->srcDpid,
                           data->dstDpid);
        res.result(http::status::internal_server_error);
        res.body() =
            R"({"error":"reverse edge missing from the topology; nothing was injected"})";
        return;
    }

    m_topologyAndFlowMonitor->setEdgeDownByDeclaration(fwdOpt.value());
    m_eventBus->emit(Event{.type = EventType::LinkFailureDetected,
                           .payload = LinkFailureEventData{fwdOpt.value()}});
    m_topologyAndFlowMonitor->setEdgeDownByDeclaration(revOpt.value());
    m_eventBus->emit(Event{.type = EventType::LinkFailureDetected,
                           .payload = LinkFailureEventData{revOpt.value()}});

    json body{{"status", "link failure injected"},
              {"down_reason", "declared"},
              {"until", "/ndt/inject_link_recovery"}};

    if (m_mode != utils::DeploymentMode::MININET)
    {
        // The declaration stands either way; what is skipped is the half the twin has no means to
        // perform. Adam's ruling of 2026-09-05: "the physical lab gets C only."
        body["tc"] = "skipped (not MININET)";
        res.body() = body.dump();
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "link {} -> {} declared down; tc skipped (not MININET)",
                           data->srcDpid,
                           data->dstDpid);
        return;
    }

    const auto graph = m_topologyAndFlowMonitor->getGraph();
    const std::string srcIface = mininetIfaceFor(graph, data->srcDpid, data->srcInterface);
    const std::string dstIface = mininetIfaceFor(graph, data->dstDpid, data->dstInterface);

    const auto runner = utils::netem::realTcRunner();
    json tc = json::array();
    for (const std::string& iface : {srcIface, dstIface})
    {
        if (iface.empty())
        {
            tc.push_back({{"interface", nullptr},
                          {"ok", false},
                          {"refused", "the topology file gives this switch no bridge_name, so the "
                                      "twin cannot name its interface"}});
            continue;
        }
        // Loss on BOTH ends, not one. faults.txt L-2 records why one end is its own fault type:
        // unidirectional loss kills LLDP in one direction only and leaves the control plane's
        // graph permanently asymmetric. An injection meant to stand for "this link is gone" has
        // to be symmetric or it is a different, subtler fault.
        tc.push_back(utils::netem::cutInterface(iface, "100%", runner));
    }
    body["tc"] = tc;
    res.body() = body.dump();
}

void
HttpSession::handleInjectLinkRecovery(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Inject Link Recovery");
    auto data = parseLinkFailedEventPayload(m_req.body());
    if (!data)
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Invalid link-failure payload"})";
        return;
    }
    // W8-7, the fourth door. The ruling named the failure endpoints, and this one is refused with
    // them because the family's contract is what is being fixed: a payload this endpoint accepts
    // but its failure sibling refuses is a link nobody could have injected and an interface this
    // endpoint would still run `tc qdisc del` against. [Co-developed with claude code -- Adam]
    if (!namesTwoSwitches(data->srcDpid, data->dstDpid))
    {
        res.result(http::status::bad_request);
        res.body() = kHostEdgeRefusal;
        return;
    }

    auto fwdOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({data->srcDpid, data->dstDpid});
    if (!fwdOpt.has_value())
    {
        res.result(http::status::not_found);
        res.body() = R"({"error":"edge not found in topology"})";
        return;
    }
    auto revOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({data->dstDpid, data->srcDpid});
    if (!revOpt.has_value())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "inject link recovery {} -> {}: reverse edge is missing from the "
                           "topology; nothing was withdrawn",
                           data->srcDpid,
                           data->dstDpid);
        res.result(http::status::internal_server_error);
        res.body() =
            R"({"error":"reverse edge missing from the topology; nothing was withdrawn"})";
        return;
    }

    // [Co-developed with claude code -- Adam]
    // W8b: the UNCONDITIONAL withdrawal, and the only one left. /ndt/link_recovery_detected now
    // withdraws a declaration only when it pairs with a reported break; this endpoint is the
    // operator taking their own injection back, so it needs no agreement from the control plane --
    // and it is the endpoint the caller is pointed at when the other one declines.
    for (const auto& e : {fwdOpt.value(), revOpt.value()})
    {
        m_topologyAndFlowMonitor->clearEdgeDeclaredDown(e);
        m_topologyAndFlowMonitor->setEdgeUp(e);
    }

    json body{{"status", "link recovery injected"}};

    if (m_mode != utils::DeploymentMode::MININET)
    {
        body["tc"] = "skipped (not MININET)";
        res.body() = body.dump();
        return;
    }

    const auto graph = m_topologyAndFlowMonitor->getGraph();
    const std::string srcIface = mininetIfaceFor(graph, data->srcDpid, data->srcInterface);
    const std::string dstIface = mininetIfaceFor(graph, data->dstDpid, data->dstInterface);

    const auto runner = utils::netem::realTcRunner();
    json tc = json::array();
    for (const std::string& iface : {srcIface, dstIface})
    {
        if (iface.empty())
        {
            tc.push_back({{"interface", nullptr},
                          {"ok", false},
                          {"refused", "the topology file gives this switch no bridge_name"}});
            continue;
        }
        tc.push_back(utils::netem::restoreInterface(iface, runner));
    }
    body["tc"] = tc;
    res.body() = body.dump();
}

void
HttpSession::handleGetGraphData(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Graph Data");
    json result;
    result["nodes"] = json::array();
    result["edges"] = json::array();
    // [Co-developed with claude code -- Adam]
    // doc/audit/2026-09-03_night-rounds round 6, finding N1. Read BEFORE the graph, so the verdict
    // cannot describe a later round than the nodes and edges below it: the poll thread may finish
    // a round while this loop runs, and a graph labelled with a fresher round's verdict is a worse
    // lie than a stale label. Additive top-level key; GRAPH_DATA is a non-strict Obj.
    result["topology_round"] = m_topologyAndFlowMonitor->pollRoundJson();

    auto graph = m_topologyAndFlowMonitor->getGraph();
    for (auto vd : boost::make_iterator_range(boost::vertices(graph)))
    {
        result["nodes"].push_back(graph[vd]);
    }

    for (auto ed : boost::make_iterator_range(boost::edges(graph)))
    {
        auto& e = graph[ed];

        auto& ep = graph[ed];
        json flowsJson = json::array();

        for (const auto& [key, last_seen] : ep.flowSet)
        {
            (void)last_seen; // silence unused warning
            flowsJson.push_back(key);
        }

        // [Co-developed with claude code -- Adam]
        // A-4f. The sampler for an edge is the switch it ARRIVES at: samples are keyed by the
        // ingress port of the agent that took them (FlowLinkUsageCollector.cpp:1444) and
        // resolved to an edge through its `dstIp`/`dstInterface`
        // (TopologyAndFlowMonitor::getAgentKeyFromTheOtherSide). So the agent to ask about this
        // edge is dstIp, not srcIp -- and getting that backwards would produce a status field
        // that is confidently wrong for every link, which is worse than not having one.
        //
        // Guarded on dstIp being non-empty: `srcIp`/`dstIp` are vectors and .front() on an empty
        // one is undefined behaviour, not an exception.
        sflow::FlowLinkUsageCollector::LinkTelemetryStatus telemetry;
        telemetry.status = "unknown";
        if (m_flowLinkUsageCollector && !e.dstIp.empty())
        {
            telemetry = m_flowLinkUsageCollector->telemetryStatusFor(e.dstIp.front(),
                                                                     e.dstInterface);
        }

        result["edges"].push_back(
            {{"is_up", e.isUp},
             {"link_bandwidth_bps", e.linkBandwidth},
             // Label AND the two raw ages it was derived from. The same reasoning as the rate
             // divisor gate (FlowLinkUsageCollector.cpp:2010-2019): a lone boolean verdict is
             // the code grading its own homework, and a reader cannot tell a check that passed
             // from a check that never ran. -1 means "never", not "a long time ago".
             {"telemetry_status", telemetry.status},
             {"last_sample_age_seconds", telemetry.lastSampleAgeSeconds},
             {"agent_last_sample_age_seconds", telemetry.agentLastSampleAgeSeconds},
             {"left_link_bandwidth_bps",
              m_mode == utils::DeploymentMode::MININET ? e.leftBandwidthFromFlowSample
                                                       : e.leftBandwidth},
             // [Co-developed with claude code -- Adam]
             // F-8. A new key rather than a changed one: /ndt/ is a cross-repo contract and the
             // sister apps read left_link_bandwidth_bps unconditionally, so its name, type and
             // presence are untouched -- tools/contract_test's GRAPH_EDGE is non-strict, so an
             // added key passes. What the added key buys is the distinction the number cannot
             // carry: "declared" says the figure is the topology file's link_bandwidth_bps with
             // nothing observed on this link yet, "measured" says telemetry produced it. Before
             // this, an unsampled 10 Gbit/s core link and a genuinely idle 1 Gbit/s access link
             // published the same 1000000000 and were indistinguishable.
             {"left_link_bandwidth_source", toString(e.leftBandwidthSource)},
             {"link_bandwidth_usage_bps", e.linkBandwidthUsage},
             {"link_bandwidth_utilization_percent", e.linkBandwidthUtilization},
             {"src_ip", e.srcIp},
             {"src_dpid", e.srcDpid},
             {"src_interface", e.srcInterface},
             {"dst_ip", e.dstIp},
             {"dst_dpid", e.dstDpid},
             {"dst_interface", e.dstInterface},
             {"flow_set", flowsJson},
             // Folded the same way as the node above (which goes through to_json in GraphTypes.hpp
             // via push_back). [Co-developed with claude code -- Adam]
             {"is_enabled", e.isEnabled && !e.adminDisabled},
             {"admin_disabled", e.adminDisabled},
             // [Co-developed with claude code -- Adam]
             // doc/KNOWN-ISSUES.md F-16. Host-facing edges can now read is_up=false, which they
             // could not before -- /ndt/link_failed is keyed on two dpids and a host has none --
             // so a consumer needs to be able to tell an injected link failure ("none") from the
             // twin's own inference that the switch behind this edge is gone
             // ("switch-unreachable"). Added key, same additive shape as admin_disabled; the
             // node objects carry the same key via to_json.
             //
             // [Co-developed with claude code -- Adam]
             // B-6 added a third value, `declared`, and effectiveDownReason decides which of the
             // two an edge that is both publishes -- see GraphTypes.hpp. Scanning for
             // `down_reason == "declared"` is how a forgotten injection is found now that a
             // declaration no longer expires by itself.
             {"down_reason", downReasonToString(effectiveDownReason(e))}});
    }
    res.body() = result.dump();
    SPDLOG_LOGGER_INFO(Logger::instance(), "get_graph_data success");
}

// [Co-developed with claude code -- Adam]
// KNOWN-ISSUES B-x. The API's own default lives here rather than in the collector, so that
// changing what the endpoint returns is one line in one place and no in-repo caller of
// getFlowInfoJson() is dragged along with it.
//
// 🔴 This CHANGES what an existing caller receives, including the out-of-repo one:
// ~/Energy-Saving-App/src/app/energy_saving_app.cpp:741 feeds the whole array into
// json2sim["flowDataList"] and consumes it per flow. Rows dropped by this default all carry rate 0
// -- that much was measured -- so any per-flow bandwidth arithmetic over them contributes nothing.
// What is NOT known is whether anything there uses the LENGTH of the list as a load figure; if it
// does, that consumer has been reading a 13x over-count and this default is the fix rather than
// the regression. Either way `?liveness=all` restores byte-for-byte the old population, which is
// why the parameter exists and why it is spelled out in the API document.
// The value itself now lives in HttpSession.hpp as a public constant, so that a test can pin it
// and a revert is one visible line. [Co-developed with claude code -- Adam]

bool
HttpSession::readLivenessFilter(http::response<http::string_body>& res,
                                sflow::FlowLivenessFilter& filter)
{
    filter = HttpSession::kFlowDataApiDefault;
    const std::string raw = utils::queryParam(m_req.target(), "liveness");
    if (!sflow::parseLivenessFilter(raw, filter))
    {
        // A rejected value, not a silent fallback. A caller who typed `?liveness=alive` and was
        // handed the default would believe the list is unfiltered when it is not -- the same
        // silent-wrong-answer shape as the defect being fixed.
        res.result(http::status::bad_request);
        res.body() =
            json::object({{"error", "liveness must be one of: active, retained, all"}}).dump();
        SPDLOG_LOGGER_WARN(Logger::instance(), "Invalid liveness value: {}", raw);
        return false;
    }
    return true;
}

void
HttpSession::handleGetDetectedFlowData(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Detected Flow Data");

    sflow::FlowLivenessFilter filter = HttpSession::kFlowDataApiDefault;
    if (!readLivenessFilter(res, filter))
    {
        return;
    }
    res.body() = m_flowLinkUsageCollector->getFlowInfoJson(filter).dump();
}

void
HttpSession::handleGetDetectedTopKFlowData(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Detected Top-K Flow Data");


    std::string kStr = utils::queryParam(m_req.target(), "k");

    int k = 50;

    if (kStr != "")
    {
        try
        {
            k = std::stoi(kStr);
        }
        catch (...)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "Invalid k value: {}", kStr);
        }
    }

    if (k < 0)
    {
        k = 0;
    }

    // [Co-developed with claude code -- Adam]
    // KNOWN-ISSUES B-x, second half. The same default as the flow-data endpoint, because the
    // measured harm here is worse: at the churn working point the default k = 50 was returning
    // ~45 rows of rate-0 corpses, and median 4 of the top 10 rows were ended flows. The document
    // calls this endpoint "Top-K active flows" (doc/2026-01-02_ndt_api.md:2395); with this
    // default it is.
    sflow::FlowLivenessFilter filter = HttpSession::kFlowDataApiDefault;
    if (!readLivenessFilter(res, filter))
    {
        return;
    }

    auto j = m_flowLinkUsageCollector->getTopKFlowInfoJson(k, filter);

    res.body() = j.dump();
}

void
HttpSession::handleGetSwitchOpenflowEntries(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Swithc OpenFlow Entries");
    res.body() = m_deviceConfigurationAndPowerManager->getOpenFlowTables().dump();
}

// [Co-developed with claude code -- Adam]
// Answers KNOWN-ISSUES A-7. install_flow_entry replies `queued` and says per-entry outcomes go to
// the kernel log; this is where a program can read what the log was told.
//
// Served straight off the dispatcher's own counters, deliberately NOT through
// DeviceConfigurationAndPowerManager. Every other read endpoint here returns a cache that
// openflowTablesUpdateWorker refreshes on a 10 s sleep plus one southbound poll
// (DeviceConfigurationAndPowerManager.cpp:1885-1908), which is why the table view can be up to
// ~10.7 s behind the write that changed it. A failure counter with that much lag would answer
// "no failures" for the whole window in which the caller is trying to find out whether its write
// failed -- exactly when the question is being asked. These numbers are read under the
// dispatcher's own lock and are current as of the read.
void
HttpSession::handleGetFlowDispatchStatus(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Flow Dispatch Status");

    const auto& outcomes = m_controller->dispatchOutcomes();

    json failures = json::array();
    for (const auto& rec : outcomes.recentFailures())
    {
        failures.push_back(json{{"seq", rec.seq},
                                {"at_unix_ms", rec.atUnixMs},
                                {"op", DispatchOutcomeLog::opName(rec.op)},
                                {"dpid", rec.dpid},
                                // Named "requested" because it is not necessarily what was
                                // programmed: measured 2026-08-30, the southbound programs every
                                // entry at priority 0 whatever was asked for. See
                                // doc/audit/2026-08-30_live-traffic-round/FINDING-07_*.
                                {"requested_priority", rec.requestedPriority},
                                {"match", rec.match},
                                {"controller_status", rec.controllerStatus},
                                {"message", rec.message}});
    }

    json body{
        {"counters",
         {{"dispatched", outcomes.dispatched()},
          {"succeeded", outcomes.succeeded()},
          {"failed", outcomes.failed()},
          // Enqueued after the dispatcher stopped, so never handed to the southbound at all.
          // A different failure from the ones above and counted separately: those were attempted
          // and refused, these were never attempted.
          {"dropped_after_stop", m_controller->dispatcher().droppedAfterStop()}}},
        // [Co-developed with claude code -- Adam]
        // What makes the zero above readable. dropped_after_stop can only leave 0 once stop()
        // has run, so on a healthy kernel it is 0 and on a kernel whose dispatcher has just
        // stopped it is *also* 0 until the next enqueue arrives -- the same number for
        // "everything was delivered" and "delivery has ended and nobody has noticed yet". With
        // this flag the pair is unambiguous: running=true says the queue is live and the zero is
        // health; running=false says every further write will be refused, and the 200
        // {"status":"queued"} the install endpoint is still answering is no longer true.
        {"dispatcher_running", m_controller->dispatcher().running()},
        // [Co-developed with claude code -- Adam]
        // The counters' denominator, published because it is not the one a reader assumes.
        // `dispatched` counts jobs that went through FlowDispatcher::enqueue, and there is
        // exactly one such call site in the kernel (processFlowBatch, below), fed by the four
        // routes named here. It is NOT "entries this fabric has programmed": on a warm fabric
        // with 1280 forwarding rules already installed, `dispatched` reads 0. That is not a
        // fault, and it was mis-registered as one -- the A-7 round predicted `dispatched` would
        // exceed the POSTed count "because other subsystems enqueue too" and the live run
        // refuted it (doc/audit/2026-08-30_a7-dispatch-visibility/FINDINGS.md:26-33).
        //
        // The two exclusions are structural, not oversights:
        //  - boot-time programming runs in a DIFFERENT PROCESS in both fabrics -- the Ryu app
        //    (intelligent_router.py, install_all_pair_paths) under OVS, the FastAPI proxy
        //    (p4_proxy/proxy_agent/topology_manager.py, install_initial_routes) under bmv2.
        //    Neither has an in-process path to this counter, so a boot_installed/boot_failed
        //    bucket here would be pinned at zero forever -- the false affordance FlowDispatcher
        //    removed a `fencePerBurst` parameter over.
        //  - IntentTranslator::performTask calls FlowRoutingManager directly (four sites), so
        //    LLM-driven writes bypass the dispatcher and this log. Counting them is reachable
        //    but needs IntentTranslator to be handed the DispatchOutcomeLog, which changes its
        //    constructor and its ownership graph; that is a separate ticket.
        {"counters_cover",
         {{"dispatch_routes",
           json::array({"/ndt/install_flow_entry",
                        "/ndt/modify_flow_entry",
                        "/ndt/delete_flow_entry",
                        "/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries"})},
          {"includes_boot_time_programming", false},
          {"includes_intent_translator", false}}},
        {"recent_failures", std::move(failures)},
        {"recent_failures_capacity", outcomes.capacity()},
        // Non-zero means the list above is partial. Published rather than left implicit: a
        // silently truncated list reads exactly like a system with fewer failures than it has.
        {"recent_failures_evicted", outcomes.failuresEvicted()}};

    res.body() = body.dump();
}

void
HttpSession::handleGetPowerReport(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Power Report");
    res.body() = m_deviceConfigurationAndPowerManager->getPowerReport().dump();
}

void
HttpSession::handleGetSwitchesPowerState(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Switches Power State");
    // TODO[OPTIMIZATION] remove try catch part after modifying error handling in
    // m_deviceConfigurationAndPowerManager
    try
    {
        json body = m_deviceConfigurationAndPowerManager->getSwitchesPowerState(
            std::string(m_req.target()));
        res.body() = body.dump();
    }
    catch (const std::runtime_error& e)
    {
        res.result(http::status::not_found);
        res.body() = json::object({{"error", e.what()}}).dump();
        SPDLOG_LOGGER_WARN(Logger::instance(), "get_switches_power_state: {}", e.what());
    }
}

void
HttpSession::handleSetSwitchesPowerState(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Set Switches Power State");
    // Helper to parse query params from a target string

    std::string ip = utils::queryParam(m_req.target(), "ip");
    std::string action = utils::queryParam(m_req.target(), "action");

    if (ip.empty() || (action != "on" && action != "off"))
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Missing or invalid ip/action"})";
        return;
    }

    // [Co-developed with claude code -- Adam]
    // OV-2, measured 2026-09-04: ?ip=203.0.113.9&action=off answered
    // 500 {"error":"Failed to change switch power state"} -- an address that names no switch
    // reported as a fault in this kernel. The GET sibling
    // (handleGetSwitchesPowerState, just above) has always answered 404 "Unknown switch IP" for
    // exactly this address, from exactly this lookup; the POST collapsed it into
    // setSwitchPowerState's bool, where it sat next to four `return false` paths that ARE
    // server failures -- the relay refusing, the vertex gone, an unrecognised action, an
    // exception. Checked HERE, before the manager is asked, rather than by widening that bool,
    // because widening it would relabel those four as 404 and lose the real fault.
    //
    // knowsSwitchIp is the GET side's own lookup, per mode, so the two endpoints cannot drift
    // apart again about what "unknown" means.
    if (!m_deviceConfigurationAndPowerManager->knowsSwitchIp(ip))
    {
        res.result(http::status::not_found);
        res.body() = json::object({{"error", "Unknown switch IP"}}).dump();
        SPDLOG_LOGGER_WARN(
            Logger::instance(), "set_switches_power_state: Unknown switch IP {}", ip);
        return;
    }

    bool ok = m_deviceConfigurationAndPowerManager->setSwitchPowerState(ip, action);
    if (ok)
    {
        res.body() = json{{ip, "Success"}}.dump();
    }
    else
    {
        res.result(http::status::internal_server_error);
        res.body() = R"({"error":"Failed to change switch power state"})";
    }
}

void
HttpSession::handleInstallFlowEntry(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Install Flow Entry");

    json entry = json::parse(m_req.body()); // { dpid, priority, match, actions, ... }

    json j;
    j["install_flow_entries"] = json::array({entry});
    j["modify_flow_entries"] = json::array();
    j["delete_flow_entries"] = json::array();

    processFlowBatch(j, res);
}

void
HttpSession::handleDeleteFlowEntry(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Delete Flow Entry");

    json entry = json::parse(m_req.body()); // { dpid, match, ... }

    json j;
    j["install_flow_entries"] = json::array();
    j["modify_flow_entries"] = json::array();
    j["delete_flow_entries"] = json::array({entry});

    processFlowBatch(j, res);
}

void
HttpSession::handleModifyFlowEntry(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Modify Flow Entry");

    json entry = json::parse(m_req.body()); // { dpid, priority, match, actions, ... }

    json j;
    j["install_flow_entries"] = json::array();
    j["modify_flow_entries"] = json::array({entry});
    j["delete_flow_entries"] = json::array();

    processFlowBatch(j, res);
}

// [Co-developed with claude code -- Adam]
// Maps a southbound OpResult onto the HTTP response, so a failure downstream becomes a
// failure the caller sees rather than a 200 with a cheerful message.
void
HttpSession::respondToOpResult(http::response<http::string_body>& res,
                               const OpResult& result,
                               const char* successMessage)
{
    if (result.ok)
    {
        res.result(http::status::ok);
        // [Co-developed with claude code -- Adam] F-13.
        // `status` is the kernel's own past-participle sentence and predates the fix, so it
        // stays exactly as it was -- it is a cross-repo contract. `outcome` is the new bit: for
        // group and meter mods a 200 from Ryu means "forwarded", not "done", so a caller needs
        // to be able to tell a verified success ("deleted") from an unverified one
        // ("unverified"). Added only when the layer below had something to say, because a key
        // that appears unconditionally is a break for a client that counts fields.
        json body{{"status", successMessage}};
        if (!result.outcome.empty())
        {
            body["outcome"] = result.outcome;
        }
        res.body() = body.dump();
        return;
    }

    // 501 means the target data plane cannot express the operation at all (e.g. group
    // entries on bmv2); 502 that the controller behind us failed or never answered.
    // Anything else is passed through so the caller sees what the controller said.
    if (result.httpStatus == 501)
    {
        res.result(http::status::not_implemented);
    }
    else if (result.noResponse())
    {
        res.result(http::status::bad_gateway);
    }
    else if (result.httpStatus >= 400 && result.httpStatus < 600)
    {
        res.result(static_cast<http::status>(result.httpStatus));
    }
    else
    {
        res.result(http::status::bad_gateway);
    }

    json failureBody{{"status", "error"},
                     {"error", result.message},
                     {"controller_status", result.httpStatus}};
    // [Co-developed with claude code -- Adam] F-13. 404 and 400 are each answered for more than
    // one reason here -- "no such switch" and "no such group" are both 404 -- so the machine-
    // readable discriminator goes in the body next to the sentence.
    if (!result.outcome.empty())
    {
        failureBody["outcome"] = result.outcome;
    }
    res.body() = failureBody.dump();

    SPDLOG_LOGGER_WARN(Logger::instance(),
                       "Responding {} for a failed southbound operation: {}",
                       static_cast<int>(res.result_int()),
                       result.message);
}

void
HttpSession::handleInstallGroupEntry(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Install Group Entry");
    auto jsonData = json::parse(m_req.body());

    // [Co-developed with claude code -- Adam]
    // The OpResult used to be discarded and this answered 200 unconditionally, so a
    // rejected entry, an unreachable controller and a success were indistinguishable to
    // the caller. These handlers are synchronous, so the real outcome can be reported.
    const OpResult result = m_flowRoutingManager->installAGroupEntry(jsonData);
    respondToOpResult(res, result, "Group entry installed");
}

void
HttpSession::handleDeleteGroupEntry(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Delete Group Entry");
    auto jsonData = json::parse(m_req.body());

    // [Co-developed with claude code -- Adam]
    // The OpResult used to be discarded and this answered 200 unconditionally, so a
    // rejected entry, an unreachable controller and a success were indistinguishable to
    // the caller. These handlers are synchronous, so the real outcome can be reported.
    const OpResult result = m_flowRoutingManager->deleteAGroupEntry(jsonData);
    respondToOpResult(res, result, "Group entry deleted");
}

void
HttpSession::handleModifyGroupEntry(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Modify Group Entry");
    auto jsonData = json::parse(m_req.body());

    // [Co-developed with claude code -- Adam]
    // The OpResult used to be discarded and this answered 200 unconditionally, so a
    // rejected entry, an unreachable controller and a success were indistinguishable to
    // the caller. These handlers are synchronous, so the real outcome can be reported.
    const OpResult result = m_flowRoutingManager->modifyAGroupEntry(jsonData);
    respondToOpResult(res, result, "Group entry modified");
}

void
HttpSession::handleInstallMeterEntry(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Install Meter Entry");
    auto jsonData = json::parse(m_req.body());

    // [Co-developed with claude code -- Adam]
    // The OpResult used to be discarded and this answered 200 unconditionally, so a
    // rejected entry, an unreachable controller and a success were indistinguishable to
    // the caller. These handlers are synchronous, so the real outcome can be reported.
    const OpResult result = m_flowRoutingManager->installAMeterEntry(jsonData);
    respondToOpResult(res, result, "Meter entry installed");
}

void
HttpSession::handleDeleteMeterEntry(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Delete Meter Entry");
    auto jsonData = json::parse(m_req.body());

    // [Co-developed with claude code -- Adam]
    // The OpResult used to be discarded and this answered 200 unconditionally, so a
    // rejected entry, an unreachable controller and a success were indistinguishable to
    // the caller. These handlers are synchronous, so the real outcome can be reported.
    const OpResult result = m_flowRoutingManager->deleteAMeterEntry(jsonData);
    respondToOpResult(res, result, "Meter entry deleted");
}

void
HttpSession::handleModifyMeterEntry(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Modify Meter Entry");
    auto jsonData = json::parse(m_req.body());

    // [Co-developed with claude code -- Adam]
    // The OpResult used to be discarded and this answered 200 unconditionally, so a
    // rejected entry, an unreachable controller and a success were indistinguishable to
    // the caller. These handlers are synchronous, so the real outcome can be reported.
    const OpResult result = m_flowRoutingManager->modifyAMeterEntry(jsonData);
    respondToOpResult(res, result, "Meter entry modified");
}

static FlowJob
makeInstallJob(const nlohmann::json& entry)
{
    FlowJob j;
    j.dpid = entry.at("dpid").get<uint64_t>();
    j.op = FlowOp::Install;
    j.priority = entry.value("priority", 0);
    j.match = entry.value("match", nlohmann::json::object());
    j.actions = entry.value("actions", nlohmann::json::array());
    j.idleTimeout = entry.value("idle_timeout", 0);
    // [Co-developed with claude code -- Adam] T-11: stamped by processFlowBatch, absent for any
    // other caller, and 0 then means "never withhold the matching row".
    j.token = entry.value(kPendingTokenField, uint64_t{0});

    return j;
}

static FlowJob
makeModifyJob(const nlohmann::json& entry)
{
    FlowJob j;
    j.dpid = entry.at("dpid").get<uint64_t>();
    j.op = FlowOp::Modify;
    j.priority = entry.value("priority", 0);
    j.match = entry.value("match", nlohmann::json::object());
    j.actions = entry.value("actions", nlohmann::json::array());

    return j;
}

static FlowJob
makeDeleteJob(const nlohmann::json& entry)
{
    FlowJob j;
    j.dpid = entry.at("dpid").get<uint64_t>();
    j.op = FlowOp::Delete;
    j.priority = entry.value("priority", -1);
    j.match = entry.value("match", nlohmann::json::object());

    return j;
}

void
HttpSession::processFlowBatch(const json& j, http::response<http::string_body>& res)
{
    std::vector<std::pair<std::vector<std::pair<uint32_t, uint32_t>>, uint32_t>>
        affectedFlowsAndDstIpForEachModifiedEntry;

    SPDLOG_LOGGER_INFO(Logger::instance(), "j {}", j.dump(2));

    const auto& ins = j.value("install_flow_entries", json::array());
    const auto& mods = j.value("modify_flow_entries", json::array());
    const auto& dels = j.value("delete_flow_entries", json::array());

    if (!ins.is_array() || !mods.is_array() || !dels.is_array())
    {
        SPDLOG_LOGGER_ERROR(
            Logger::instance(),
            "install_flow_entries/modify_flow_entries/delete_flow_entries must be arrays");
        res.result(http::status::bad_request);
        res.body() =
            R"({"error":"install_flow_entries/modify_flow_entries/delete_flow_entries must be arrays"})";
        return;
    }

    // [Co-developed with claude code -- Adam]
    // Shape check, before anything is built or queued. See describeFlowEntryShapeProblem for
    // what counts as shape and why each optional field is optional.
    //
    // This exists because `{"dpid": 1}` used to be answered 200 "queued": every field but dpid is
    // read with value(..., default), so the entry became a job with an empty match and empty
    // actions, went out to the proxy, and was refused there -- with the refusal visible only in
    // the kernel log. The caller was told its request was accepted.
    //
    // **All-or-nothing here, unlike the unknown-dpid partition below, and the asymmetry is
    // deliberate.** That one applies its good entries because an absent dpid is a *data* condition
    // -- the topology moved, a switch went away -- which happens to a few entries of an otherwise
    // correct batch, and both flow-writing applications discard the response, so rejecting the
    // whole batch would silently drop their good entries for a condition they cannot act on. A
    // malformed entry is the opposite: it is a *caller* defect, so it is not sporadic. Either the
    // caller composes entries correctly and this never fires, or it does not and every batch it
    // sends carries the same error. Applying the rest would hide a bug rather than tolerate a race.
    std::vector<json> shapeProblems;
    const auto collectShapeProblems = [&](const json& entries, FlowOp op, const char* field) {
        for (size_t i = 0; i < entries.size(); ++i)
        {
            if (const auto why = describeFlowEntryShapeProblem(entries[i], op); !why.empty())
            {
                shapeProblems.push_back(json{{"field", field}, {"index", i}, {"problem", why}});
            }
        }
    };
    collectShapeProblems(ins, FlowOp::Install, "install_flow_entries");
    collectShapeProblems(mods, FlowOp::Modify, "modify_flow_entries");
    collectShapeProblems(dels, FlowOp::Delete, "delete_flow_entries");

    if (!shapeProblems.empty())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "refusing flow batch: {} of {} entries cannot form a rule; first is {} "
                           "at {}[{}]",
                           shapeProblems.size(),
                           ins.size() + mods.size() + dels.size(),
                           shapeProblems.front()["problem"].get<std::string>(),
                           shapeProblems.front()["field"].get<std::string>(),
                           shapeProblems.front()["index"].get<size_t>());
        res.result(http::status::bad_request);
        res.body() = json{{"status", "error"},
                          {"error", "malformed flow entry"},
                          {"entries", shapeProblems},
                          {"detail", "nothing was queued; these entries cannot form a rule "
                                     "whatever the switch answers, so the whole batch is "
                                     "rejected rather than partly applied"}}
                         .dump();
        return;
    }

    // Build jobs
    std::vector<FlowJob> jobs;
    jobs.reserve(ins.size() + mods.size() + dels.size());

    // [Co-developed with claude code -- Adam]
    // T-11. Below, `updateOpenFlowTables` writes every requested install into the table cache
    // immediately, on this thread, before the dispatcher has sent anything -- that optimistic row
    // is the phantom. Mint one token per install and put it on both sides: on the FlowJob, so the
    // southbound's confirmation can be attributed to it, and on the entry handed to the cache, so
    // the read path can withhold the row until that confirmation arrives.
    //
    // Process-wide and monotonic, so a token is never reused across sessions or switches. It is
    // deliberately not derived from the entry's contents: a token must identify *this request*,
    // and two identical requests are two different rows to confirm.
    //
    // Only installs are tokened, because only installs add a row. A refused modify or delete
    // corrupts the cache differently -- it shows a mutation, or a removal, that never reached the
    // switch -- and that is the mirror of this defect rather than this defect. Registered, not
    // silently folded in: see the ticket's "not covered" section.
    static std::atomic<uint64_t> s_nextPendingToken{1};
    json annotatedInstalls = ins;
    for (auto& e : annotatedInstalls)
    {
        if (e.is_object())
        {
            e[kPendingTokenField] = s_nextPendingToken.fetch_add(1, std::memory_order_relaxed);
        }
    }

    try
    {
        for (const auto& e : annotatedInstalls)
        {
            jobs.emplace_back(makeInstallJob(e));
        }
        for (const auto& e : mods)
        {
            jobs.emplace_back(makeModifyJob(e));
        }
        for (const auto& e : dels)
        {
            jobs.emplace_back(makeDeleteJob(e));
        }
    }
    catch (const std::exception& ex)
    {
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "request body {}", j.dump());
        // WARN: answers 400 four lines down, so this is a client error, not a kernel one.
        // [Co-developed with claude code -- Adam]
        SPDLOG_LOGGER_WARN(Logger::instance(), "Bad entry in request: {}", ex.what());
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Bad entry"})";
        return;
    }

    // [Co-developed with claude code -- Adam]
    // Separate out the dpids this kernel does not know about, before enqueueing anything.
    //
    // This endpoint answered 200 for a nonexistent dpid, which the L2 contract had been failing on
    // for as long as it had existed. The instinct is to blame the asynchrony -- the dispatcher
    // drains on worker threads, so the southbound outcome genuinely is not available yet -- but
    // "there is no such switch" is not a southbound outcome. It is knowable here, from the
    // topology the kernel already holds, before a job is queued at all.
    //
    // Partial application, not all-or-nothing. This was all-or-nothing first, reasoning that a
    // caller handed 200 for a half-applied batch cannot find out which half landed. Two things
    // overturned that:
    //
    //   1. Naming the rejected dpids in the body answers the question the objection was about. The
    //      caller is not told "some of it worked"; it is told exactly which entries were dropped.
    //   2. The two applications that write flows both **discard the response entirely** --
    //      Energy-Saving-App at energy_saving_app.cpp:225 and :241 does not bind the returned
    //      std::optional<uint32_t>, and Traffic-Engineering-App at Traffic-engineering-App.py:572
    //      does not assign the requests.post result. So all-or-nothing did not make them handle
    //      the error; it silently converted a batch that used to apply its good entries into one
    //      that applies nothing. For those two callers it was strictly worse than the 200 it
    //      replaced, and would only have paid off after someone else changed their code.
    //
    // A batch where *nothing* is applicable still answers 404: 200 with accepted == 0 would tell a
    // caller that only reads the status code that its request was fine when not one entry landed.
    // See doc/audit/2026-08-08_external-tools-compat-review.md for the client-by-client evidence.
    auto partition = partitionFlowBatchByKnownDpid(
        std::move(jobs),
        [this](uint64_t dpid) { return m_topologyAndFlowMonitor->getSwitchKind(dpid).has_value(); });
    std::vector<FlowJob> acceptedJobs = std::move(partition.accepted);
    const std::vector<uint64_t>& unknownDpids = partition.unknownDpids;
    const size_t rejectedEntries = partition.rejectedEntries;

    if (acceptedJobs.empty() && rejectedEntries > 0)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "refusing flow batch: none of its {} entries names a switch in the "
                           "loaded topology ({} distinct unknown dpid(s))",
                           rejectedEntries,
                           unknownDpids.size());
        res.result(http::status::not_found);
        res.body() = json{{"status", "error"},
                          {"error", "unknown dpid"},
                          {"unknown_dpids", unknownDpids},
                          {"detail", "these dpids are not switches in the loaded topology; check "
                                     "the dpid, or that the topology file matches the running "
                                     "network"}}
                         .dump();
        return;
    }

    if (rejectedEntries > 0)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "dropping {} of {} flow batch entries: {} dpid(s) are not switches in "
                           "the loaded topology; the remaining {} were queued",
                           rejectedEntries,
                           rejectedEntries + acceptedJobs.size(),
                           unknownDpids.size(),
                           acceptedJobs.size());
    }

    // Enqueue once; dispatcher drains per-DPID on worker threads
    const size_t accepted = acceptedJobs.size();
    m_controller->dispatcher().enqueue(std::move(acceptedJobs));

    // TODO: Immediately update the table
    // [Co-developed with claude code -- Adam]
    // T-11: hand the cache the tokened installs, not the raw body, so each optimistic row carries
    // the same token as the job that will (or will not) be confirmed for it. Everything else in
    // the body is passed through untouched.
    json annotated = j;
    if (!annotatedInstalls.empty())
    {
        annotated["install_flow_entries"] = annotatedInstalls;
    }
    m_deviceConfigurationAndPowerManager->updateOpenFlowTables(annotated);

    // [Co-developed with claude code -- Adam]
    // This used to answer {"status":"Flows installed, modified and deleted"} -- a claim it
    // cannot make. FlowDispatcher is asynchronous by design (bursts of up to 2000, one
    // worker per DPID), so the entries are still sitting in a queue at this point and no
    // request has reached the controller yet. A rejected rule or an unreachable controller
    // was therefore reported as a completed installation.
    //
    // The response now says what is actually true: the entries were accepted for
    // programming. Their outcome is logged per entry with the dpid and the controller's
    // reply -- which was claimed here before it was true: Controller's sender discarded every
    // OpResult it received. It logs them now, so check_logs.py can fail a run on a rejected rule.
    //
    // Kept as HTTP 200 rather than 202 Accepted: 202 would be more accurate, but callers
    // that check for exactly 200 would break, and this is the endpoint every writing app
    // uses. Reporting per-entry status to the caller needs either a synchronous path or a
    // completion handle -- an architectural decision, not a wording one.
    res.result(http::status::ok);
    // [Co-developed with claude code -- Adam]
    // `detail` used to end at "reported in the kernel log, not in this response", which was true
    // and was the whole of A-7: the only record of a refused write was in a file no program
    // reads. Now that GET /ndt/get_flow_dispatch_status exists, leaving the sentence unchanged
    // would keep the answer undiscoverable to exactly the caller who needs it. Safe to reword:
    // the two in-repo consumers log this body and neither parses it (auditor cross-repo check,
    // 2026-08-30) -- `status` and `accepted` are unchanged for anything that does.
    json body{{"status", "queued"},
              {"accepted", accepted},
              {"detail", "entries accepted for programming; per-entry outcomes are reported in "
                         "the kernel log and, since they are not in this response, are readable "
                         "afterwards from GET /ndt/get_flow_dispatch_status"}};

    // [Co-developed with claude code -- Adam]
    // Only present when something was actually dropped, so a caller can treat their absence as
    // "all of it was taken". Naming the dpids is the whole reason partial application is
    // acceptable here: without them, 200 would again be a claim the caller cannot check.
    if (rejectedEntries > 0)
    {
        body["rejected"] = rejectedEntries;
        body["rejected_dpids"] = unknownDpids;
        body["detail"] = "some entries were dropped because their dpid is not a switch in the "
                         "loaded topology; the rest were accepted for programming, and per-entry "
                         "outcomes are reported in the kernel log, not in this response";
    }

    res.body() = body.dump();
}

void
HttpSession::handleInstallModifyDeleteFlowEntries(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Install Modify Delete Flow Entries");
    json j = json::parse(m_req.body());
    processFlowBatch(j, res);
}

void
HttpSession::handleGetCpuUtilization(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get CPU Utilization");
    res.body() = m_deviceConfigurationAndPowerManager->getCpuUtilization().dump();
}

void
HttpSession::handleGetMemoryUtilization(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Memory Utilization");
    res.body() = m_deviceConfigurationAndPowerManager->getMemoryUtilization().dump();
}

void
HttpSession::handleInformSwitchEntered(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Inform Switch Entered");

    std::string_view target = m_req.target();
    auto pos = target.find("?dpid=");
    if (pos == std::string_view::npos)
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Missing dpid parameter"})";
        return;
    }
    std::string dpidStr(target.substr(pos + 6));
    if (dpidStr.empty())
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Missing dpid parameter"})";
        return;
    }

    // [Co-developed with claude code -- Adam]
    // std::stoull threw on `?dpid=abc` and the outermost catch turned it into 500 -- the L2 failure
    // inform_switch_entered__bad_dpid. tryParseUint64 is also stricter than stoull, which would
    // read "12abc" as 12 and "-1" as 18446744073709551615: a mistyped dpid must be refused, not
    // silently redirected to a different switch.
    const auto dpidOpt = utils::tryParseUint64(dpidStr);
    if (!dpidOpt)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "inform_switch_entered: dpid '{}' is not an unsigned integer",
                           dpidStr);
        res.result(http::status::bad_request);
        res.body() = json{{"status", "error"},
                          {"error", "invalid dpid"},
                          {"dpid", dpidStr},
                          {"detail", "dpid must be an unsigned integer"}}
                         .dump();
        return;
    }
    const uint64_t dpid = *dpidOpt;
    auto switchVertexOpt = m_topologyAndFlowMonitor->findSwitchByDpid(dpid);
    if (!switchVertexOpt)
    {
        res.result(http::status::not_found);
        res.body() = R"({"error":"Switch not found"})";
        return;
    }

    // [Co-developed with claude code -- Adam] -- FINDINGS #81.
    //
    // This setVertexUp is unconditional ON PURPOSE, and the reason had to be established rather
    // than assumed. FINDINGS #46 taught discovery to decline for a switch with a standing
    // commanded power-off, and the obvious next step was to teach this endpoint the same rule.
    // It would have been wrong. What #46 declines is LIST MEMBERSHIP -- the proxy went on
    // listing a killed switch for D = 3.06 s, so "the control plane still mentions it" is a
    // cache, not a look. This endpoint is a different kind of input:
    //
    //   intelligent_router.py:1202  fires it from an ofp_event.EventOFPStateChange handler when
    //                               a datapath reaches MAIN_DISPATCHER -- a completed handshake;
    //   intelligent_router.py:1059  fires it per dpid drained from _pending_switch_dpids, which
    //                               EventSwitchEnter fills -- also a transition;
    //   kernel_notifier.py:96       is the P4 equivalent, pushed when the proxy adopts a switch.
    //
    // All three are edge-triggered by a session that completed. A dead process does not complete
    // a handshake, so this is evidence about the present and refusing it would make the twin
    // report a switch that is demonstrably answering as unreachable.
    //
    // What it is NOT is evidence that anybody withdrew the power-off, and it must not touch that
    // flag -- setVertexUp is the observation writer and does not (asserted by
    // InformSwitchEnteredTest and by the poll gate's M3). Since Q12 the twin no longer has to
    // choose: it reports admin_state=off with reachable=true, which says out loud that a switch
    // came back without being asked to. The WARN is there because that state is worth seeing and
    // is otherwise inferable only by diffing two API reads.
    if (m_topologyAndFlowMonitor->getVertexAdminPoweredOff(*switchVertexOpt))
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "inform_switch_entered: dpid {} completed a control-plane session "
                           "while a commanded power-off still stands; recording it reachable and "
                           "leaving admin_state off",
                           dpid);
    }

    m_topologyAndFlowMonitor->setVertexUp(*switchVertexOpt);
    m_topologyAndFlowMonitor->setVertexEnable(*switchVertexOpt);
    res.body() = R"({"status":"Switch set to up"})";
}

void
HttpSession::handleModifyDeviceName(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Modify Device Name");

    json body = json::parse(m_req.body());
    int vertexType = body.at("vertex_type").get<int>();
    std::string newName = body.at("new_name").get<std::string>();
    std::optional<Graph::vertex_descriptor> vertexOpt;

    if (vertexType == 0) // Switch
    {
        vertexOpt = m_topologyAndFlowMonitor->findSwitchByDpid(body.at("dpid").get<uint64_t>());
    }
    else if (vertexType == 1) // Host
    {
        // [Co-developed with claude code -- Adam]
        // tryMacToUint64, because macToUint64 throws and the throw reaches buildResponse's
        // std::exception catch -- which answers 500 for a malformed client request. Exactly the
        // defect the dpid and app_id parsing was fixed for; this call site was missed. Found by
        // agy-review 0115.
        const std::string macText = body.at("mac").get<std::string>();
        const auto mac = utils::tryMacToUint64(macText);
        if (!mac)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "modify_device_name: mac '{}' is not a MAC address",
                               macText);
            res.result(http::status::bad_request);
            res.set(http::field::content_type, "application/json");
            res.body() = json{{"status", "error"},
                              {"error", "invalid mac"},
                              {"mac", macText},
                              {"detail", "expected xx:xx:xx:xx:xx:xx"}}
                             .dump();
            return;
        }
        vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(*mac);
    }
    else
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Invalid vertex_type. Must be 0 (switch) or 1 (host)."})";
        return;
    }

    if (!vertexOpt)
    {
        res.result(http::status::not_found);
        res.body() = R"({"error":"Device not found."})";
        return;
    }

    m_topologyAndFlowMonitor->setVertexDeviceName(vertexOpt.value(), newName);
    res.body() = R"({"status":"Device name updated successfully."})";
}

void
HttpSession::handleReceivedSimulationCase(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Recieved Simulation Case");

    // This endpoint used to answer 202 Accepted to *anything*, including `{not json`: the body went
    // straight into a curl command and whatever came back -- including nothing at all -- was
    // wrapped as {"status": "..."}. The five required fields are Simulation-Platform-Manager's own,
    // so a body that fails here would have thrown inside that process instead, where no status code
    // can reach the caller. [Co-developed with claude code -- Adam]
    if (const auto problem = SimulationRequestManager::validateRequestBody(m_req.body()))
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Rejecting simulation case: {}",
                           *problem);
        res.result(http::status::bad_request);
        res.set(http::field::content_type, "application/json");
        res.body() = json{{"error", "Invalid simulation case"}, {"details", *problem}}.dump();
        return;
    }

    const auto dispatch = m_simulationRequestManager->requestSimulation(m_req.body());

    // [Co-developed with claude code -- Adam]
    // doc/KNOWN-ISSUES.md B-4. These four lines used to be three: 202 Accepted, unconditionally,
    // with the return value of requestSimulation() pasted into a hand-built JSON string. Two
    // separate defects sat in that.
    //
    // First, 202 means "I have taken responsibility for this request". Nothing here had checked
    // whether the request left the machine, so a body whose `inputfile` path contained a quote --
    // the ordinary way this failed -- produced a syntax error inside /bin/sh, no curl process at
    // all, and `202 {"status":""}` to the caller. There was no id in the reply either, so the
    // caller could not have discovered the truth later even if it had thought to look. 202 is now
    // sent only when the simulator server has answered, and the simulator's own status is passed
    // through when it refuses, so an application can tell "you sent me a bad case" from "the
    // simulator is down" from "the kernel is broken".
    //
    // Second, `"{\"status\":\"" + resp + "\"}"` is a JSON document built with string concatenation
    // out of a value from another process. A response body containing a quote or a newline made
    // this kernel's reply malformed JSON -- the same class of defect as the shell interpolation
    // one line above it, in the other direction. json{...}.dump() cannot produce that.
    res.set(http::field::content_type, "application/json");

    if (!dispatch.answered)
    {
        // 500 when the request never left this host: the fault is ours, and answering "bad
        // gateway" would blame the simulator for a request it was never sent. 502 when it did
        // leave and nothing came back. This is the distinction B-2b's message collapsed, expressed
        // as a status code so that a program and not just a human can act on it.
        res.result(dispatch.sent ? http::status::bad_gateway
                                 : http::status::internal_server_error);
        res.body() = json{{"status", "error"},
                          {"error", "Simulation case was not accepted"},
                          {"details", dispatch.failureReason}}
                         .dump();
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Responding {} for a simulation case that was not dispatched: {}",
                           static_cast<int>(res.result_int()),
                           dispatch.failureReason);
        return;
    }

    if (dispatch.httpStatus < 200 || dispatch.httpStatus >= 300)
    {
        res.result(static_cast<http::status>(dispatch.httpStatus));
        res.body() = json{{"status", "error"},
                          {"error", "The simulator server rejected the case"},
                          {"simulator_status", dispatch.httpStatus},
                          {"simulator_response", dispatch.response}}
                         .dump();
        return;
    }

    res.result(http::status::accepted);
    res.body() = json{{"status", dispatch.response}}.dump();
}

void
HttpSession::handleSimulationCompleted(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Simulation Completed");
    auto j = json::parse(m_req.body());

    // Malformed JSON and a missing/non-string app_id already answer 400 via the json::exception
    // handler, but std::stoi("abc") throws std::invalid_argument, which does not -- the same
    // mistyped-parameter-reported-as-500 defect that `?dpid=abc` had. [Co-developed with claude
    // code -- Adam]
    const std::string appIdText = j.at("app_id").get<string>();
    const auto parsedAppId = utils::tryParseUint64(appIdText);
    if (!parsedAppId || *parsedAppId > static_cast<uint64_t>(std::numeric_limits<int>::max()))
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Rejecting simulation result: app_id '{}' is not a valid id",
                           appIdText);
        res.result(http::status::bad_request);
        res.set(http::field::content_type, "application/json");
        res.body() = json{{"error", "Invalid app_id"}, {"details", appIdText}}.dump();
        return;
    }
    const int appId = static_cast<int>(*parsedAppId);

    m_simulationRequestManager->onSimulationResult(appId, m_req.body());

    res.result(http::status::ok);
    res.set(http::field::content_type, "application/json");
    res.body() = R"({"status":"result forwarded"})";
}

void
HttpSession::handleGetStaticTopology(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Static Topology");
    // dump(2) here rather than inside getStaticTopologyJson, which now returns the object its
    // signature always promised. Same two-space indentation, so the bytes on the wire are
    // byte-for-byte what they were. [Co-developed with claude code -- Adam]
    res.body() = m_topologyAndFlowMonitor->getStaticTopologyJson().dump(2);
}

void
HttpSession::handleInformAllDestinationPaths(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Infrom All Desination Pahts");

    json body = json::parse(m_req.body());
    const auto& allPathsJson = body.at("all_destination_paths");
    std::vector<sflow::Path> allPathsVector;

    for (const auto& pathJson : allPathsJson)
    {
        sflow::Path tempPath;
        // [Co-developed with claude code -- Adam]
        // The same unchecked indexing as the collector's copy of this loop, but reached from the
        // network rather than from a poll: `nodeJson[0]` / `nodeJson[1]` on a const json forward
        // to std::vector::operator[] with no bounds check, so a body carrying a hop array shorter
        // than two elements read past the end of the heap. ASan calls it a heap-buffer-overflow;
        // the catch below never saw it, because it is not an exception.
        //
        // std::stoi on the port threw std::invalid_argument on "abc", which the outermost handler
        // turned into a 500 -- the same "you sent rubbish reported as I am broken" that the
        // comment sixty lines above records fixing for app_id.
        // The handler refuses rather than skipping, unlike the collector's copy: this body comes
        // from a sibling app making a claim about the network, and quietly accepting the paths it
        // got right would leave the caller believing all of them landed.
        for (const auto& nodeJson : pathJson)
        {
            const auto hop = sflow::tryParsePathNode(nodeJson);
            if (!hop)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "inform_all_destination_paths: a hop is not a well-formed "
                                   "[node, interface] pair; rejecting the request");
                res.result(http::status::bad_request);
                res.body() = json{{"status", "error"},
                                  {"error", "malformed path node"},
                                  {"detail", "each hop must be [node, interface]; node is a "
                                             "dotted IPv4 address or a numeric id, interface is "
                                             "a number or a numeric string"}}
                                 .dump();
                return;
            }
            tempPath.emplace_back(hop->first, hop->second);
        }
        if (!tempPath.empty())
        {
            allPathsVector.push_back(tempPath);
        }
    }
    m_flowLinkUsageCollector->setAllPaths(allPathsVector);
    res.body() = R"({"status":"success"})";
}

void
HttpSession::handleAppRegister(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle App Register");
    // Parse the request body for JSON
    auto json_body = json::parse(m_req.body());

    // Extract "appName"
    if (!json_body.contains("app_name") || !json_body["app_name"].is_string())
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error": "Missing or invalid 'appName'"})";
        res.set(http::field::content_type, "application/json");
        res.prepare_payload();
        return;
    }
    std::string appName = json_body["app_name"];

    // Extract "appName"
    if (!json_body.contains("simulation_completed_url") ||
        !json_body["simulation_completed_url"].is_string())
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error": "Missing or invalid 'simulationCompletedUrl'"})";
        res.set(http::field::content_type, "application/json");
        res.prepare_payload();
        return;
    }
    std::string simulationCompletedUrl = json_body["simulation_completed_url"];

    // Register app via ApplicationManager
    int appId = m_applicationManager->registerApplication(appName, simulationCompletedUrl);

    // Respond with JSON containing App ID
    json response_json = {{"app_id", appId}, {"message", "Application registered successfully"}};

    res.result(http::status::ok);
    res.set(http::field::content_type, "application/json");
    res.body() = response_json.dump();
    res.prepare_payload();
}

void
HttpSession::handleInputTextIntent(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Processing intent_translator text request");

    // [Co-developed with claude code -- Adam]
    // `--no-ai` leaves this pointer null: main.cpp only constructs an IntentTranslator when
    // config.useToken is set, and its else branch just logs. Without this check one well-formed
    // POST dereferences null and takes the whole kernel process with it -- every other endpoint,
    // the topology poll, the sFlow collector -- while it is running a live network. The catch
    // below cannot help: a null dereference is a signal, not a C++ exception.
    //
    // stack.sh starts the kernel with --no-ai, so this is the *normal* configuration here, not a
    // corner case. doc/2026-01-02_ndt_api.md carried the defect as a written warning not to call the endpoint;
    // a three-line guard is a better mitigation than asking people to remember.
    if (this->m_intentTranslator == nullptr)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "intent_translator requested but the translator is disabled (--no-ai)");
        res.result(http::status::service_unavailable);
        res.body() =
            R"({"error":"Intent translator is disabled; the kernel was started with --no-ai."})";
        return;
    }

    try
    {
        json body = json::parse(m_req.body());
        std::unique_ptr<llmResponse::LLMResponse> resultPtr =
            this->m_intentTranslator->inputTextIntent(body["prompt"].get<std::string>(),
                                                      body["session"].get<std::string>());
        json result = resultPtr;
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "Intent translator result: {}", result.dump());
        res.result(http::status::ok);
        res.body() = result.dump();
    }
    catch (const std::exception& e)
    {
        // WARN: answers 400 below. [Co-developed with claude code -- Adam]
        SPDLOG_LOGGER_WARN(Logger::instance(),
                            "Exception in intent_translator: {}, request body: {}",
                            e.what(),
                            m_req.body());
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Invalid request format."})";
    }
}

void
HttpSession::handleGetNickname(http::response<http::string_body>& res)
{
    //  Log the incoming request for debugging purposes.
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Nickname");

    // Extract all possible identifiers from the URL
    std::string dpidStr = utils::queryParam(m_req.target(), "dpid");
    std::string macStr = utils::queryParam(m_req.target(), "mac");
    std::string nameStr = utils::queryParam(m_req.target(), "name");

    // Check that at least one identifier was provided
    if (dpidStr.empty() && macStr.empty() && nameStr.empty())
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Missing dpid, mac, or name parameter"})";
        return;
    }

    std::optional<Graph::vertex_descriptor> vertexOpt;
    auto graph = m_topologyAndFlowMonitor->getGraph();

    // Search with a clear priority: DPID > MAC > Name
    if (!dpidStr.empty())
    {
        {
            // [Co-developed with claude code -- Adam]
            // Same guard as handleInformSwitchEntered: std::stoull threw on `?dpid=abc` and the
            // outermost catch turned it into 500. tryParseUint64 is also stricter than stoull,
            // which would read "12abc" as 12 and "-1" as 18446744073709551615 -- a mistyped dpid
            // must be refused, not silently redirected to a different switch.
            //
            // The message names *this* endpoint. It was copy-pasted from handleInformSwitchEntered
            // with the text unedited, so a bad `?dpid=` on /ndt/get_nickname logged
            // "inform_switch_entered: ..." and sent the reader to the wrong handler. Checked the
            // other forty-odd handlers for the same slip; this was the only one.
            const auto dpidOpt = utils::tryParseUint64(dpidStr);
            if (!dpidOpt)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "get_nickname: dpid '{}' is not an unsigned integer",
                                   dpidStr);
                res.result(http::status::bad_request);
                res.body() = json{{"status", "error"},
                                  {"error", "invalid dpid"},
                                  {"dpid", dpidStr},
                                  {"detail", "dpid must be an unsigned integer"}}
                                 .dump();
                return;
            }
            const uint64_t dpid = *dpidOpt;
            vertexOpt = m_topologyAndFlowMonitor->findSwitchByDpid(dpid);
        }
        // The `catch (const std::exception&)` that used to close this block is gone: nothing inside
        // it throws any more. tryParseUint64 returns nullopt instead of throwing, and
        // findSwitchByDpid is a graph read. A catch that cannot fire is not harmless -- it reads as
        // a claim that this code can throw, so the next person keeps it. Review M2.
        // [Co-developed with claude code -- Adam]
    }
    else if (!macStr.empty())
    {
        // [Co-developed with claude code -- Adam]
        // tryMacToUint64 and an explicit check, matching modify_device_name and modify_nickname.
        // This was the last MAC call site still using the throwing macToUint64 with a local catch.
        // The old form answered 400 too, so this is not a behaviour fix -- it is a consistency one,
        // and the inconsistency was not cosmetic: the two forms produced *different error bodies*
        // for the same mistake, so a client could not parse "invalid mac" uniformly. Found by the
        // http-routing review, M1.
        const auto mac = utils::tryMacToUint64(macStr);
        if (!mac)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_nickname: mac '{}' is not a MAC address",
                               macStr);
            res.result(http::status::bad_request);
            res.set(http::field::content_type, "application/json");
            res.body() = json{{"status", "error"},
                              {"error", "invalid mac"},
                              {"mac", macStr},
                              {"detail", "expected xx:xx:xx:xx:xx:xx"}}
                             .dump();
            return;
        }
        vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(*mac);
    }
    else // nameStr is not empty
    {
        // Iterate over all vertices in the graph to find by name
        for (auto vd : boost::make_iterator_range(boost::vertices(graph)))
        {
            const auto& props = graph[vd];
            // Check if either the deviceName or nickName matches
            if (props.deviceName == nameStr)
            {
                vertexOpt = vd;
                break; // Stop searching once a match is found
            }
        }
    }

    // If no device was found after all searches, return a "Not Found" error
    if (!vertexOpt)
    {
        res.result(http::status::not_found);
        res.body() = R"({"error":"Device not found"})";
        return;
    }

    // If a device was found, construct the successful JSON response
    const auto& vertexProperties = graph[vertexOpt.value()];
    res.body() = json{{"nickname", vertexProperties.nickName}}.dump();
    res.result(http::status::ok);
}

void
HttpSession::handleModifyNickname(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Modify Nickname");

    try
    {
        // 1. Parse the request body as JSON
        json body = json::parse(m_req.body());
        const auto& identifier = body.at("identifier");
        std::string type = identifier.at("type").get<std::string>();
        std::string newNickname = body.at("new_nickname").get<std::string>();

        std::optional<Graph::vertex_descriptor> vertexOpt;

        // 2. Find the device using the provided identifier
        if (type == "dpid")
        {
            uint64_t dpid = identifier.at("value").get<uint64_t>();
            vertexOpt = m_topologyAndFlowMonitor->findSwitchByDpid(dpid);
        }
        else if (type == "mac")
        {
            // Same as above: a malformed MAC is a client error, not a server one.
            // [Co-developed with claude code -- Adam]
            const std::string macText = identifier.at("value").get<std::string>();
            const auto mac = utils::tryMacToUint64(macText);
            if (!mac)
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "modify_nickname: mac '{}' is not a MAC address",
                                   macText);
                res.result(http::status::bad_request);
                res.set(http::field::content_type, "application/json");
                res.body() = json{{"status", "error"},
                                  {"error", "invalid mac"},
                                  {"mac", macText},
                                  {"detail", "expected xx:xx:xx:xx:xx:xx"}}
                                 .dump();
                return;
            }
            vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(*mac);
        }
        else if (type == "name")
        {
            std::string name = identifier.at("value").get<std::string>();
            auto graph = m_topologyAndFlowMonitor->getGraph();
            for (auto vd : boost::make_iterator_range(boost::vertices(graph)))
            {
                if (graph[vd].deviceName == name || graph[vd].nickName == name)
                {
                    vertexOpt = vd;
                    break;
                }
            }
        }
        else
        {
            throw std::runtime_error("Invalid identifier type: " + type);
        }

        // 3. Check if the device was found
        if (!vertexOpt)
        {
            res.result(http::status::not_found);
            res.body() = R"({"error":"Device not found"})";
            return;
        }

        // 4. Update the nickname in the topology monitor
        // NOTE: This assumes you have a function like `setVertexNickname` in your
        // TopologyAndFlowMonitor class. You may need to create it if it doesn't exist.
        m_topologyAndFlowMonitor->setVertexNickname(vertexOpt.value(), newNickname);

        // 5. Send a success response
        res.result(http::status::ok);
        res.body() = R"({"status": "success", "message": "Nickname updated successfully."})";
    }
    catch (const std::exception& e)
    {
        res.result(http::status::bad_request);
        res.body() = json{{"error", "Failed to modify nickname"}, {"details", e.what()}}.dump();
    }
}

void
HttpSession::handleGetTemperature(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Temperature");
    res.body() = m_deviceConfigurationAndPowerManager->getTemperature().dump();
}

void
HttpSession::handleGetPathSwitchCount(http::response<http::string_body>& res)
{
    std::string target(m_req.target());
    std::string srcIpStr = utils::queryParam(target, "src_ip");
    std::string dstIpStr = utils::queryParam(target, "dst_ip");
    json responseJson;
    res.set(http::field::content_type, "application/json");

    // Check if BOTH src_ip and dst_ip were provided for a specific lookup.
    if (!srcIpStr.empty() && !dstIpStr.empty())
    {
        // This is the ORIGINAL logic for fetching a single path's count.
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "Handle Get Path Switch Count for {} -> {}",
                           srcIpStr,
                           dstIpStr);

        // [Co-developed with claude code -- Adam]
        // ipStringToUint32 throws, and the throw escaped to the outermost catch, which answers 500.
        // A malformed query parameter is the caller's mistake, not the kernel breaking, and telling
        // them otherwise sends them looking in the wrong place. This is the L2 failure
        // get_path_switch_count__bad_ip.
        const auto srcIpOpt = utils::tryIpStringToUint32(srcIpStr);
        const auto dstIpOpt = utils::tryIpStringToUint32(dstIpStr);
        if (!srcIpOpt || !dstIpOpt)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_path_switch_count: bad IP parameter(s) src='{}' dst='{}'",
                               srcIpStr,
                               dstIpStr);
            res.result(http::status::bad_request);
            res.body() = json{{"status", "error"},
                              {"error", "invalid IP address"},
                              {"src_ip", srcIpStr},
                              {"dst_ip", dstIpStr},
                              {"detail", "src_ip and dst_ip must be dotted IPv4 addresses"}}
                             .dump();
            return;
        }
        const uint32_t srcIp = *srcIpOpt;
        const uint32_t dstIp = *dstIpOpt;

        auto switchCountOpt = m_flowLinkUsageCollector->getSwitchCount({srcIp, dstIp});

        if (switchCountOpt.has_value())
        {
            res.result(http::status::ok);
            responseJson["status"] = "success";
            responseJson["src_ip"] = srcIpStr;
            responseJson["dst_ip"] = dstIpStr;
            responseJson["switch_count"] = switchCountOpt.value();
        }
        else
        {
            res.result(http::status::not_found);
            responseJson["status"] = "error";
            responseJson["message"] = "Path not found for the given IPs.";
        }
    }
    // If parameters are missing, return all path counts.
    else
    {
        SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get All Path Switch Counts");

        // This call is correct.
        auto allCounts = m_flowLinkUsageCollector->getAllSwitchCounts();

        res.result(http::status::ok);
        responseJson["status"] = "success";

        json dataArray = json::array();

        // The key from the map is an "ipPair", not a "flow" struct.
        for (const auto& [ipPair, count] : allCounts)
        {
            json flowData;

            // Use .first for the source IP and .second for the destination IP.
            flowData["src_ip"] = utils::ipToString(ipPair.first);
            flowData["dst_ip"] = utils::ipToString(ipPair.second);
            flowData["switch_count"] = count;

            dataArray.push_back(flowData);
        }

        responseJson["data"] = dataArray;
    }

    res.body() = responseJson.dump();
}

void
HttpSession::handleGetOpenflowCapacity(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Openflow Capacity");
    std::ifstream file("../doc/2026-01-02_OpenflowCapacity.json");
    if (!file.is_open())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Cannot open 2026-01-02_OpenflowCapacity.json");
        return;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Load 2026-01-02_OpenflowCapacity.json");

    json j;
    file >> j;

    res.result(http::status::ok);
    res.body() = j.dump();
}

void
HttpSession::handleSetHistoricalLoggingState(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "API request to set historical logging state");

    // Helper to parse query params from a target string

    std::string state = utils::queryParam(m_req.target(), "state");

    if (state != "enable" && state != "disable")
    {
        res.result(http::status::bad_request);
        res.body() =
            R"({"error":"Invalid or missing 'state' parameter. Use 'enable' or 'disable'."})";
        return;
    }

    if (!m_historicalDataManager)
    {
        res.body() = R"({"status": "error", "message": "Historical data manager not available."})";
        res.result(http::status::internal_server_error);
        return;
    }

    bool is_enabled = (state == "enable");
    m_historicalDataManager->setLoggingState(is_enabled);

    res.result(http::status::ok);

    // [Co-developed with claude code -- Adam]
    // Say so when the flag has been set but nothing will be written. HistoricalDataManager::start()
    // returns early in MININET, so the recorder thread does not exist and no row will ever appear
    // -- yet this handler used to report plain success either way. Both lab stacks are MININET, so
    // the reply was false on every deployment this project has actually run. The flag really was
    // set, which is why this stays 200 rather than becoming an error: the request was honoured,
    // and it is the consequence that needed stating.
    //
    // KNOWN-ISSUES B-3, second pass. Stating the consequence in `message` was not enough: both
    // branches still answered `"status":"success"`, so the only machine-readable difference was
    // `recording`, and a caller reading the status line or `status` -- which is what a caller
    // reads -- still could not tell the two apart. Three things change here and the status code
    // is not one of them:
    //
    //  * the non-recording branch answers `"status":"not_applicable"`, so `status` carries
    //    information rather than being a constant;
    //  * both branches carry `reason`, a stable token from HistoricalDataManager::reasonCode(),
    //    so nobody has to regex the English;
    //  * the predicate widened from canRecord() to recordingState(). canRecord() asks about the
    //    deployment mode, not about this object -- a TESTBED manager that nobody start()ed, or
    //    one whose every write is being rejected by the output directory (which is the documented
    //    state of OUTPUT_DIR on this machine), answered canRecord() == true and wrote nothing.
    //    The MININET case was simply the one that showed up every day.
    //
    // 200 stays. The flag really was set, `tools/contract_test/spec.py` pins [200, 500] for both
    // states, and doc/2026-01-02_ndt_api.md section 39 documents 200 -- turning a reply that is
    // now fully self-describing into a 501 would break a contract to say something the body
    // already says. `Obj` in the contract schema is non-strict, so the added key is compatible.
    using RecordingState = HistoricalDataManager::RecordingState;
    const auto recState = m_historicalDataManager->recordingState();
    const bool recording = (recState == RecordingState::RECORDING);

    if (is_enabled && !recording)
    {
        // The prose has to follow the reason. Keeping one sentence for every non-recording cause
        // would put "the recorder is only started outside MININET mode" on a TESTBED reply, which
        // is the same defect one level of detail further in. The MININET wording is unchanged
        // from the shape doc/2026-01-02_ndt_api.md section 39 records, deliberately.
        const char* why = "Historical data logging is enabled, but this deployment does not "
                          "record, and no rows will be written.";
        switch (recState)
        {
        case RecordingState::NOT_AVAILABLE_IN_MININET:
            why = "Historical data logging is enabled, but this deployment does not record: the "
                  "recorder is only started outside MININET mode, so no rows will be written.";
            break;
        case RecordingState::RECORDER_NOT_RUNNING:
            why = "Historical data logging is enabled, but the recorder thread is not running, "
                  "so no rows will be written until the kernel starts it.";
            break;
        case RecordingState::WRITES_FAILING:
            why = "Historical data logging is enabled and the recorder is running, but every "
                  "write to the output directory is failing, so no rows are being kept. See the "
                  "kernel log for the path that was refused.";
            break;
        case RecordingState::RECORDING:
        case RecordingState::DISABLED_BY_REQUEST:
            break;
        }

        res.body() = json{{"status", "not_applicable"},
                          {"recording", false},
                          {"reason", HistoricalDataManager::reasonCode(recState)},
                          {"message", why}}
                         .dump();
        return;
    }

    res.body() = json{
        {"status", "success"},
        {"recording", recording},
        {"reason", HistoricalDataManager::reasonCode(recState)},
        {"message",
         "Historical data logging has been " +
             (is_enabled ? std::string("enabled") : std::string("disabled")) +
             "."}}.dump();
}

void
HttpSession::handleGetAvgLinkUsage(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Avg Link Usage");
    double avgLinkUsage =
        m_topologyAndFlowMonitor->getAvgLinkUsage(m_topologyAndFlowMonitor->getGraph());
    res.result(http::status::ok);
    // [Co-developed with claude code -- Adam] Round 4 section 1: under a flood that lost 72.5% of
    // samples this number moved the WRONG WAY (0.0103 -> 0.0221) and still answered 200
    // "success". `status` there is about the request; `telemetry_health` is about the answer.
    json body{{"status", "success"}, {"avg_link_usage", avgLinkUsage}};
    if (m_flowLinkUsageCollector)
    {
        body["telemetry_health"] = m_flowLinkUsageCollector->ingestHealthJson();
    }
    res.body() = body.dump();
}

// [Co-developed with claude code -- Adam]
// The four counters at FlowLinkUsageCollector's tail had exactly one reader before this: a log
// line. This endpoint exists for a consumer that wants them without polling a measurement, and
// carries the same object under the same key as every other response so there is one shape to
// learn. See doc/audit/2026-09-03_night-rounds/FIX-TELEMETRY-HEALTH.md.
void
HttpSession::handleGetSflowStats(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get sFlow Stats");
    if (!m_flowLinkUsageCollector)
    {
        // No collector means no ingest to report on. Answering `{"status":"success"}` with an
        // absent or zeroed health object would say "nothing was lost", which is not known.
        res.result(http::status::service_unavailable);
        res.body() = json{{"status", "error"},
                          {"message", "no sFlow collector in this deployment"}}.dump();
        return;
    }
    res.result(http::status::ok);
    res.body() =
        json{{"status", "success"},
             {"telemetry_health", m_flowLinkUsageCollector->ingestHealthJson()}}.dump();
}

void
HttpSession::handleGetTotalInputTrafficLoadPassingASwitch(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Total Input Traffic Load Passing A Switch");
    auto jsonData = json::parse(m_req.body());
    if (jsonData.contains("dpid"))
    {
        auto dpid = jsonData.at("dpid").get<uint64_t>();
        // [Co-developed with claude code -- Adam]
        // OV-3. See handleGetNumOfFlowsPassingASwitch below for the whole note: without this,
        // a dpid that names no switch is indistinguishable from a real switch carrying nothing,
        // because the scan below never looks anything up -- it only compares.
        if (!m_topologyAndFlowMonitor->getSwitchKind(dpid).has_value())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_total_input_traffic_load_passing_a_switch: dpid {} is not a "
                               "switch in the loaded topology",
                               dpid);
            res.result(http::status::not_found);
            res.body() = json{{"status", "error"},
                              {"error", "unknown dpid"},
                              {"unknown_dpids", json::array({dpid})},
                              {"detail", "these dpids are not switches in the loaded topology; "
                                         "check the dpid, or that the topology file matches the "
                                         "running network"}}
                             .dump();
            return;
        }
        auto g = m_topologyAndFlowMonitor->getGraph();
        uint64_t totalLoad = 0;
        for (const auto& ed : boost::make_iterator_range(boost::edges(g)))
        {
            const auto& e = g[ed];
            // TODO: Debug
            if (e.dstDpid == dpid)
            {
                SPDLOG_LOGGER_INFO(Logger::instance(),
                                   "edge {} to {} link usage {}",
                                   e.srcDpid,
                                   e.dstDpid,
                                   e.linkBandwidthUsage);
                totalLoad += e.linkBandwidthUsage;
            }
        }
        res.body() =
            json{{"status", "success"}, {"total_input_traffic_load_bps", totalLoad}}.dump();
    }
    else
    {
        // [Co-developed with claude code -- Adam]
        // res.result() as well as the body: buildResponse initialises the response to 200, so
        // setting only an error body left a status-code-only client reading success and holding
        // an error object it never parses.
        SPDLOG_LOGGER_WARN(Logger::instance(), "dpid missing");
        res.result(http::status::bad_request);
        res.body() = json{{"status", "error"}, {"message", "dpid missing"}}.dump();
    }
}

void
HttpSession::handleGetNumOfFlowsPassingASwitch(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Num Of Flows Passing A Switch");
    auto jsonData = json::parse(m_req.body());
    if (jsonData.contains("dpid"))
    {
        auto dpid = jsonData.at("dpid").get<uint64_t>();
        // [Co-developed with claude code -- Adam]
        // 🔴 OV-3, measured 2026-09-04: {"dpid":424242} answered 200 {"num_of_flows":0}. There is
        // no lookup in the scan below that can fail -- the dpid is only ever a comparison operand,
        // nothing matches it, and the accumulator is returned at its initial value. So a dpid that
        // names no switch and a real switch with no traffic gave byte-identical answers, and a
        // caller could not tell "I asked about nothing" from "there is nothing to report".
        //
        // getSwitchKind is the validator install_flow_entry already uses for the same question
        // (see the partitionFlowBatchByKnownDpid call above, which answers 404 with the same
        // wording for the same dpid), and its own Doxygen says callers must treat nullopt as an
        // error rather than defaulting. It takes a shared_lock and a hash lookup; it does not
        // copy the graph.
        if (!m_topologyAndFlowMonitor->getSwitchKind(dpid).has_value())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "get_num_of_flows_passing_a_switch: dpid {} is not a switch in the "
                               "loaded topology",
                               dpid);
            res.result(http::status::not_found);
            res.body() = json{{"status", "error"},
                              {"error", "unknown dpid"},
                              {"unknown_dpids", json::array({dpid})},
                              {"detail", "these dpids are not switches in the loaded topology; "
                                         "check the dpid, or that the topology file matches the "
                                         "running network"}}
                             .dump();
            return;
        }
        auto g = m_topologyAndFlowMonitor->getGraph();
        int numOfFlows = 0;
        for (const auto& ed : boost::make_iterator_range(boost::edges(g)))
        {
            const auto& e = g[ed];
            if (e.dstDpid == dpid)
            {
                numOfFlows += e.flowSet.size();
            }
        }
        res.body() = json{{"status", "success"}, {"num_of_flows", numOfFlows}}.dump();
    }
    else
    {
        // See handleGetTotalInputTrafficLoadPassingASwitch: same missing res.result().
        // [Co-developed with claude code -- Adam]
        SPDLOG_LOGGER_WARN(Logger::instance(), "dpid missing");
        res.result(http::status::bad_request);
        res.body() = json{{"status", "error"}, {"message", "dpid missing"}}.dump();
    }
}

void
HttpSession::handleNotFound(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_WARN(Logger::instance(),
                       "Received unsupported request: method={}, target={}",
                       m_req.method_string(),
                       m_req.target());
    res.result(http::status::not_found);
    res.body() = json{{"error", "Not Found"}}.dump();
}

void
HttpSession::handleAcquireLock(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Acquire Lock");
    try
    {
        // [Co-developed with claude code -- Adam]
        // Decide first, acquire second. This used to parse inline with the defaults already
        // assigned, and a `catch (...)` that kept them -- so a malformed body, a body with no
        // "type", and a body naming a lock that does not exist all acquired `routing_lock`,
        // the lock that serialises writes to real switches. Verified live on 2026-08-29 by
        // judging on state: `"{this is not json` returned {"status":"locked",
        // "type":"routing_lock"} and a second client then could not acquire.
        const auto reqLock = LockManager::parseRequest(m_req.body());

        if (!reqLock.ok)
        {
            // 400, not 423. The old code answered every one of these with "System busy or
            // invalid lock type: <substituted value>" -- one sentence for two unrelated
            // conditions, quoting a lock the caller never asked for. "busy" is a retry;
            // "your request is wrong" is not, and a caller cannot tell them apart from 423.
            res.result(http::status::bad_request);
            res.body() = json{{"error", "Invalid lock request"},
                              {"detail", LockManager::describeError(reqLock, "acquired")}}
                             .dump();
            return;
        }

        // [Co-developed with claude code -- Adam]
        // A-9. The report is what makes a lease visible on the wire. `lease` on the 200 is the
        // id the caller may echo back on release/renew to be protected against releasing a lock
        // that has moved on without it; `reclaimed_expired_lease` says this acquire took over a
        // lease whose holder never released it -- which used to be completely silent, and is the
        // fingerprint of the Energy-Saving-App failure this endpoint was measured through.
        LockManager::AcquireReport report;
        if (m_lockManager->acquireLock(reqLock.type, reqLock.ttl, &report))
        {
            res.result(http::status::ok);
            res.body() = json{{"status", "locked"},
                              {"type", reqLock.type},
                              {"ttl", reqLock.ttl},
                              {"lease", report.leaseId},
                              {"reclaimed_expired_lease", report.reclaimedExpiredLease}}
                             .dump();
        }
        else
        {
            // Reaching here now means exactly one thing: the type was valid and the lock is
            // held by someone else. Retrying is the right response, which 423 says and 400
            // does not.
            //
            // `retry_after_s` is the number the old sentence told the caller to work out for
            // itself ("retry after its TTL" -- whose TTL? the caller does not know what ttl the
            // holder asked for). The Energy-Saving-App retries this at 1 Hz for the whole 300 s
            // of somebody else's lease; a client that can read the remaining time can at least
            // log how long it has left to wait instead of only that it is waiting.
            res.result(http::status::locked);
            res.body() = json{{"error", "Lock acquisition failed"},
                              {"detail", "lock \"" + reqLock.type +
                                             "\" is held by another client; retry after its TTL"},
                              {"held_by_lease", report.blockingLeaseId},
                              {"retry_after_s", report.remainingSeconds}}
                             .dump();
        }
    }
    catch (...)
    {
        res.result(http::status::internal_server_error);
        res.body() = json{{"error", "Internal server error"}}.dump();
    }
}

void
HttpSession::handleRenewLock(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Renew Lock");
    try
    {
        // [Co-developed with claude code -- Adam]
        // Decide first, act second -- the same seam handleAcquireLock uses, not a second copy
        // of the rules. This handler used to assign the defaults, parse into them, and swallow
        // every parse failure in an empty `catch (...)`, so a malformed body, a body with no
        // "type", and an absent body all renewed `routing_lock` -- the lock that serialises
        // writes to real switches. The damaging case is not the garbage one: an app holding
        // power_lock that renewed without a body extended somebody else's routing lease, was
        // told 200 "renewed", and let its own lease run down untouched.
        const auto reqLock = LockManager::parseRequest(m_req.body());

        if (!reqLock.ok)
        {
            // 400, not 412. 412 is a state the caller can fix by acquiring first; a request
            // that names no valid lock is not a state, and a caller cannot tell the two apart
            // if they share a status.
            res.result(http::status::bad_request);
            res.body() = json{{"error", "Invalid lock request"},
                              {"detail", LockManager::describeError(reqLock, "renewed")}}
                             .dump();
            return;
        }

        // [Co-developed with claude code -- Adam]
        // A-9. `is expired or not held` was one sentence for two states that send a caller to
        // two different places: "your lease ran out while you were working" means the work you
        // did after it ran out was unprotected, and "you never held this" means you have a bug
        // in your acquire path. The status stays 412 for both -- it is what the contract and
        // tools/contract_test/spec.py expect -- and the body now says which.
        std::uint64_t renewedLease = 0;
        const auto renewOutcome =
            m_lockManager->renewLease(reqLock.type, reqLock.ttl, reqLock.lease, &renewedLease);
        if (renewOutcome == LockManager::RenewOutcome::Renewed)
        {
            // `lease` (B-2②) names the lease this request actually extended. A caller that keeps
            // the id from its own acquire can compare -- which is the only way, today, for the
            // real holder's neighbour to notice it has just extended somebody else's lease.
            res.result(http::status::ok);
            res.body() = json{{"status", "renewed"},
                              {"type", reqLock.type},
                              {"ttl", reqLock.ttl},
                              {"lease", renewedLease}}
                             .dump();
        }
        else if (renewOutcome == LockManager::RenewOutcome::LeaseRequired)
        {
            // 400, not 412: this is a missing required field, not a state the caller can fix by
            // acquiring. Only reachable when LockManager::setRequireLeaseId(true) has been called,
            // which nothing does yet -- see that function for why the switch exists unwired.
            res.result(http::status::bad_request);
            res.body() = json{{"error", "Invalid lock request"},
                              {"reason", "lease_required"},
                              {"detail", "this kernel requires a \"lease\" on renew; lock '" +
                                             reqLock.type +
                                             "' is held and the request named no lease, so it "
                                             "could not be attributed to a holder. Nothing was "
                                             "extended"}}
                             .dump();
        }
        else if (renewOutcome == LockManager::RenewOutcome::LeaseMismatch)
        {
            // 409, not 412: this is not a precondition the caller can satisfy by acquiring, it
            // is a statement that the lock has moved on to a lease that is not the caller's.
            // Only reachable when the caller sent a "lease" -- no existing caller does -- so it
            // cannot change any deployed client's behaviour.
            res.result(http::status::conflict);
            res.body() = json{{"error", "Renew failed"},
                              {"reason", "lease_mismatch"},
                              {"detail", "Lock '" + reqLock.type + "' is no longer on lease " +
                                             std::to_string(reqLock.lease) +
                                             "; nothing was extended"}}
                             .dump();
        }
        else
        {
            // "or invalid type" has gone from this sentence because an invalid type can no
            // longer reach here -- it is a 400 above. What is left is exactly the retryable
            // state 412 is for.
            const bool expired = (renewOutcome == LockManager::RenewOutcome::Expired);
            res.result(http::status::precondition_failed); // 412 Precondition Failed
            res.body() =
                json{{"error", "Renew failed"},
                     {"reason", expired ? "expired" : "not_held"},
                     {"detail", expired ? "Lock '" + reqLock.type +
                                              "' had a lease that already ran out; it has been "
                                              "reclaimed and was not extended"
                                        : "Lock '" + reqLock.type + "' is not held"}}
                    .dump();
        }
    }
    catch (...)
    {
        res.result(http::status::bad_request);
        res.body() = json{{"error", "Invalid Request"}}.dump();
    }
}

void
HttpSession::handleReleaseLock(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Release Lock");
    try
    {
        // [Co-developed with claude code -- Adam]
        // Same seam as acquire and renew. An earlier revision already refused a malformed body
        // and a non-string "type", but an *absent* body still fell through to
        // DEFAULT_LOCK_TYPE_STR, and that remaining hole was the worst of the three: an app
        // holding power_lock that released without a body released `routing_lock` -- held by
        // somebody else, and the lock that serialises writes to real switches -- was answered
        // 200 "released", and still held its own power_lock. Two locks wrong, no error anywhere,
        // and the reply named a lock the caller had never mentioned.
        //
        // That revision kept the fallback on the grounds that doc/2026-01-02_ndt_api.md calls the
        // body optional and that "callers rely on it". Re-checked before removing it: no caller
        // relies on it. All three release callers send an explicit "type" --
        // Energy-Saving-App/src/app/http.cpp:461, Traffic-engineering-App.py:85 and the chaos
        // harness probes.py:206 -- as does every release check in tools/contract_test/spec.py. The
        // documented default had no user, so the doc section is corrected alongside this change
        // rather than kept alive by a fallback nothing was asking for.
        const auto reqLock = LockManager::parseRequest(m_req.body());

        if (!reqLock.ok)
        {
            res.result(http::status::bad_request);
            res.body() = json{{"error", "Invalid lock request"},
                              {"detail", LockManager::describeError(reqLock, "released")}}
                             .dump();
            return;
        }

        // 412, matching the sibling renew handler, for the one condition that is left here:
        // a real lock that is simply not held. tools/contract_test/spec.py expects [412, 400,
        // 404]; doc/2026-07-27_testing_workflow.md documents 412. 423 Locked, which
        // doc/2026-01-02_ndt_api.md mentions, is the wrong shape: 423 means "the resource is
        // locked so your request cannot proceed", whereas the failure here is "there was no
        // lock of yours to release". An invalid type no longer arrives here -- it is a 400
        // above -- so it has been dropped from the sentence.
        //
        // [Co-developed with claude code -- Adam]
        // 🔴 A-9. This used to be `if (!unlock(type))`, and `unlock` answered **true** for a
        // lease that had already run out -- so a release arriving after its own TTL got
        // `200 {"status":"released"}`, byte-identical to a release that actually released
        // something. That is how a lock nobody held stayed indistinguishable from a lock
        // somebody had just tidied up, and it is why the TR-5 write-up could not tell from the
        // kernel side what had happened to the Energy-Saving-App's lease.
        //
        // Four outcomes now, three answers. The status for `expired` stays 412 so that
        // tools/contract_test/spec.py's release_lock_not_held ([412, 400, 404]) and
        // doc/2026-07-27_testing_workflow.md keep their meaning; the body carries the
        // distinction, because "your lease was reclaimed" and "there was nothing here" are
        // different things to have just learned.
        std::uint64_t releasedLease = 0;
        const auto releaseOutcome =
            m_lockManager->release(reqLock.type, reqLock.lease, &releasedLease);

        if (releaseOutcome == LockManager::ReleaseOutcome::LeaseRequired)
        {
            // 400, not 412: a missing required field, not a state. Only reachable when
            // LockManager::setRequireLeaseId(true) has been called, which nothing does yet.
            res.result(http::status::bad_request);
            res.body() = json{{"error", "Invalid lock request"},
                              {"reason", "lease_required"},
                              {"detail", "this kernel requires a \"lease\" on release; lock '" +
                                             reqLock.type +
                                             "' is held and the request named no lease, so it "
                                             "could not be attributed to a holder. Nothing was "
                                             "released"}}
                             .dump();
            return;
        }

        if (releaseOutcome == LockManager::ReleaseOutcome::LeaseMismatch)
        {
            // 409: the lock is held, but on a lease that is not the caller's. Refusing is the
            // whole point -- releasing here would free a lock the caller does not hold, which is
            // the failure this branch exists to prevent. Only reachable when the caller sent a
            // "lease"; no deployed client does yet.
            res.result(http::status::conflict);
            res.body() = json{{"error", "Release failed"},
                              {"reason", "lease_mismatch"},
                              {"detail", "Lock '" + reqLock.type + "' is no longer on lease " +
                                             std::to_string(reqLock.lease) +
                                             "; it was NOT released"}}
                             .dump();
            return;
        }

        if (releaseOutcome != LockManager::ReleaseOutcome::Released)
        {
            const bool expired = (releaseOutcome == LockManager::ReleaseOutcome::Expired);
            res.result(http::status::precondition_failed);
            res.body() =
                json{{"error", "Release failed"},
                     {"reason", expired ? "expired" : "not_held"},
                     {"detail", expired ? "Lock '" + reqLock.type +
                                              "' had a lease that already ran out; it was "
                                              "reclaimed by expiry, not released by this request"
                                        : "Lock '" + reqLock.type + "' is not held"}}
                    .dump();
            return;
        }

        // `lease` (B-2②) names the lease this request actually released. Until every caller sends
        // a lease id, a release names only a lock -- so this field is how a caller finds out,
        // after the fact, that the lease it just freed was not the one it was holding.
        res.result(http::status::ok);
        res.body() =
            json{{"status", "released"}, {"type", reqLock.type}, {"lease", releasedLease}}.dump();
    }
    catch (...)
    {
        res.result(http::status::internal_server_error);
        res.body() = json{{"error", "Release lock failed"}}.dump();
    }
}