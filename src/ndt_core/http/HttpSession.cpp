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
#include "ndt_core/routing_management/FlowJob.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "utils/Logger.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
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
            m_res = response;
            writeResponse();
            return;
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
        else if (method == http::verb::get && target == "/ndt/get_graph_data")
        {
            handleGetGraphData(*response);
        }
        else if (method == http::verb::get && target == "/ndt/get_detected_flow_data")
        {
            handleGetDetectedFlowData(*response);
        }
        else if (method == http::verb::get && target.starts_with("/ndt/get_detected_top_k_flow_data"))
        {
            handleGetDetectedTopKFlowData(*response);
        }
        else if (method == http::verb::get && target == "/ndt/get_switch_openflow_table_entries")
        {
            handleGetSwitchOpenflowEntries(*response);
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
        SPDLOG_LOGGER_ERROR(Logger::instance(), "JSON exception in request handler: {}", e.what());
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

    m_res = response;
    writeResponse();
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
    m_topologyAndFlowMonitor->setEdgeDown(fwdOpt.value());
    m_eventBus->emit(Event{.type = EventType::LinkFailureDetected,
                           .payload = LinkFailureEventData{fwdOpt.value()}});

    auto revOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({data->dstDpid, data->srcDpid});
    if (revOpt)
    {
        m_topologyAndFlowMonitor->setEdgeDown(revOpt.value());
        m_eventBus->emit(Event{.type = EventType::LinkFailureDetected,
                               .payload = LinkFailureEventData{revOpt.value()}});
    }
    res.body() = R"({"status":"link failure processed"})";
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
    m_topologyAndFlowMonitor->setEdgeUp(fwdOpt.value());
    // TODO: Emit LinkRecoveryDetected event

    auto revOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({dstDpid, srcDpid});
    if (revOpt)
    {
        m_topologyAndFlowMonitor->setEdgeUp(revOpt.value());
    }
    res.body() = R"({"status":"link recovery processed"})";
}

void
HttpSession::handleGetGraphData(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Graph Data");
    json result;
    result["nodes"] = json::array();
    result["edges"] = json::array();

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

        result["edges"].push_back(
            {{"is_up", e.isUp},
             {"link_bandwidth_bps", e.linkBandwidth},
             {"left_link_bandwidth_bps",
              m_mode == utils::DeploymentMode::MININET ? e.leftBandwidthFromFlowSample
                                                       : e.leftBandwidth},
             {"link_bandwidth_usage_bps", e.linkBandwidthUsage},
             {"link_bandwidth_utilization_percent", e.linkBandwidthUtilization},
             {"src_ip", e.srcIp},
             {"src_dpid", e.srcDpid},
             {"src_interface", e.srcInterface},
             {"dst_ip", e.dstIp},
             {"dst_dpid", e.dstDpid},
             {"dst_interface", e.dstInterface},
             {"flow_set", flowsJson},
             {"is_enabled", e.isEnabled}});
    }
    res.body() = result.dump();
    SPDLOG_LOGGER_INFO(Logger::instance(), "get_graph_data success");
}

void
HttpSession::handleGetDetectedFlowData(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Detected Flow Data");
    res.body() = m_flowLinkUsageCollector->getFlowInfoJson().dump();
}

void
HttpSession::handleGetDetectedTopKFlowData(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Detected Top-K Flow Data");

    auto get_param = [](std::string_view target, std::string_view key) -> std::string {
        auto qpos = target.find('?');
        if (qpos == std::string_view::npos)
        {
            return "";
        }
        target.remove_prefix(qpos + 1);
        while (!target.empty())
        {
            auto key_end = target.find('=');
            if (key_end == std::string_view::npos)
            {
                break;
            }
            if (target.substr(0, key_end) == key)
            {
                target.remove_prefix(key_end + 1);
                auto val_end = target.find('&');
                return std::string(target.substr(0, val_end));
            }
            auto amp_pos = target.find('&');
            if (amp_pos == std::string_view::npos)
            {
                break;
            }
            target.remove_prefix(amp_pos + 1);
        }
        return "";
    };

    std::string kStr = get_param(m_req.target(), "k");

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

    auto j = m_flowLinkUsageCollector->getTopKFlowInfoJson(k);

    res.body() = j.dump();
}

void
HttpSession::handleGetSwitchOpenflowEntries(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Swithc OpenFlow Entries");
    res.body() = m_deviceConfigurationAndPowerManager->getOpenFlowTables().dump();
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
    auto get_param = [](std::string_view target, std::string_view key) -> std::string {
        auto qpos = target.find('?');
        if (qpos == std::string_view::npos)
        {
            return "";
        }
        target.remove_prefix(qpos + 1);
        while (!target.empty())
        {
            auto key_end = target.find('=');
            if (key_end == std::string_view::npos)
            {
                break;
            }
            if (target.substr(0, key_end) == key)
            {
                target.remove_prefix(key_end + 1);
                auto val_end = target.find('&');
                return std::string(target.substr(0, val_end));
            }
            auto amp_pos = target.find('&');
            if (amp_pos == std::string_view::npos)
            {
                break;
            }
            target.remove_prefix(amp_pos + 1);
        }
        return "";
    };

    std::string ip = get_param(m_req.target(), "ip");
    std::string action = get_param(m_req.target(), "action");

    if (ip.empty() || (action != "on" && action != "off"))
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Missing or invalid ip/action"})";
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
        res.body() = json{{"status", successMessage}}.dump();
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

    res.body() = json{{"status", "error"},
                      {"error", result.message},
                      {"controller_status", result.httpStatus}}
                     .dump();

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

    // Build jobs
    std::vector<FlowJob> jobs;
    jobs.reserve(ins.size() + mods.size() + dels.size());

    try
    {
        for (const auto& e : ins)
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
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Bad entry in request: {}", ex.what());
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Bad entry"})";
        return;
    }

    // [Co-developed with claude code -- Adam]
    // Reject dpids this kernel does not know about, before enqueueing anything.
    //
    // This endpoint answered 200 for a nonexistent dpid, which the L2 contract has been failing on
    // for as long as it has existed. The instinct is to blame the asynchrony -- the dispatcher
    // drains on worker threads, so the southbound outcome genuinely is not available yet -- but
    // "there is no such switch" is not a southbound outcome. It is knowable here, from the
    // topology the kernel already holds, before a job is queued at all.
    //
    // All-or-nothing: a batch naming one bad dpid is rejected whole rather than partially applied,
    // because a caller that gets 200 for a partially-applied batch has no way to find out which
    // half landed. The genuinely asynchronous outcomes are still asynchronous, and are logged per
    // entry by Controller's sender.
    std::vector<uint64_t> unknownDpids;
    for (const auto& job : jobs)
    {
        if (!m_topologyAndFlowMonitor->getSwitchKind(job.dpid).has_value())
        {
            unknownDpids.push_back(job.dpid);
        }
    }
    if (!unknownDpids.empty())
    {
        std::sort(unknownDpids.begin(), unknownDpids.end());
        unknownDpids.erase(std::unique(unknownDpids.begin(), unknownDpids.end()),
                           unknownDpids.end());
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "refusing flow batch: {} dpid(s) are not switches in the loaded "
                           "topology",
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

    // Enqueue once; dispatcher drains per-DPID on worker threads
    const size_t accepted = jobs.size();
    m_controller->dispatcher().enqueue(std::move(jobs));

    // TODO: Immediately update the table
    m_deviceConfigurationAndPowerManager->updateOpenFlowTables(j);

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
    res.body() = json{{"status", "queued"},
                      {"accepted", accepted},
                      {"detail", "entries accepted for programming; per-entry outcomes are "
                                 "reported in the kernel log, not in this response"}}
                     .dump();
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
        vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(
            utils::macToUint64(body.at("mac").get<std::string>()));
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

    std::string resp = m_simulationRequestManager->requestSimulation(m_req.body());

    res.result(http::status::accepted);
    res.set(http::field::content_type, "application/json");
    std::string bodyStr = std::string("{\"status\":\"") + resp + "\"}";
    res.body() = std::move(bodyStr);
}

void
HttpSession::handleSimulationCompleted(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Simulation Completed");
    auto j = json::parse(m_req.body());

    int appId = std::stoi(j.at("app_id").get<string>());

    m_simulationRequestManager->onSimulationResult(appId, m_req.body());

    res.result(http::status::ok);
    res.set(http::field::content_type, "application/json");
    res.body() = R"({"status":"result forwarded"})";
}

void
HttpSession::handleGetStaticTopology(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Static Topology");
    res.body() = m_topologyAndFlowMonitor->getStaticTopologyJson();
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
        for (const auto& nodeJson : pathJson)
        {
            uint64_t nodeId = 0;
            if (nodeJson[0].is_string())
            {
                nodeId = utils::ipStringToUint32(nodeJson[0].get<std::string>());
            }
            else if (nodeJson[0].is_number())
            {
                nodeId = nodeJson[0].get<uint64_t>();
            }

            uint32_t port = 0;
            if (nodeJson[1].is_number())
            {
                port = nodeJson[1].get<int>();
            }
            else if (nodeJson[1].is_string())
            {
                port = std::stoi(nodeJson[1].get<std::string>());
            }

            tempPath.emplace_back(nodeId, port);
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
        SPDLOG_LOGGER_ERROR(Logger::instance(),
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

    //  helper function to easily parse query parameters (e.g., "?dpid=123") from the request URL.
    auto get_param = [](std::string_view target, std::string_view key) -> std::string {
        // 1. Find the start of the query string (the '?'). If it doesn't exist, there are no
        // parameters.
        auto qpos = target.find('?');
        if (qpos == std::string_view::npos)
        {
            return "";
        }

        // 2. Remove the path part of the URL, leaving only the query string (e.g.,
        // "dpid=123&action=on").
        target.remove_prefix(qpos + 1);

        // 3. Loop through the remaining string, which contains key=value pairs separated by '&'.
        while (!target.empty())
        {
            // 4. Find the '=' to separate the key from the value.
            auto key_end = target.find('=');
            if (key_end == std::string_view::npos)
            {
                break; // Malformed pair, stop parsing.
            }

            // 5. Check if the current key is the one we're looking for.
            if (target.substr(0, key_end) == key)
            {
                // It's a match! Remove the key and '='.
                target.remove_prefix(key_end + 1);

                // Find the end of the value (the next '&').
                auto val_end = target.find('&');

                // Extract the value and return it as a new std::string.
                return std::string(target.substr(0, val_end));
            }

            // 6. If it wasn't a match, skip to the next key-value pair.
            auto amp_pos = target.find('&');
            if (amp_pos == std::string_view::npos)
            {
                break; // No more pairs, stop parsing.
            }
            target.remove_prefix(amp_pos + 1);
        }

        // 7. If the loop finishes without finding the key, return an empty string.
        return "";
    };

    // Extract all possible identifiers from the URL
    std::string dpidStr = get_param(m_req.target(), "dpid");
    std::string macStr = get_param(m_req.target(), "mac");
    std::string nameStr = get_param(m_req.target(), "name");

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
        try
        {
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
            vertexOpt = m_topologyAndFlowMonitor->findSwitchByDpid(dpid);
        }
        catch (const std::exception& e)
        {
            res.result(http::status::bad_request);
            res.body() = json{{"error", "Invalid DPID format"}, {"details", e.what()}}.dump();
            return;
        }
    }
    else if (!macStr.empty())
    {
        try
        {
            uint64_t mac = utils::macToUint64(macStr);
            vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(mac);
        }
        catch (const std::exception& e)
        {
            res.result(http::status::bad_request);
            res.body() =
                json{{"error", "Invalid MAC address format"}, {"details", e.what()}}.dump();
            return;
        }
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
            uint64_t mac = utils::macToUint64(identifier.at("value").get<std::string>());
            vertexOpt = m_topologyAndFlowMonitor->findVertexByMac(mac);
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
    // This helper lambda remains the same.
    auto get_param = [](std::string_view target, std::string_view key) -> std::string {
        auto qpos = target.find('?');
        if (qpos == std::string_view::npos)
        {
            return "";
        }
        target.remove_prefix(qpos + 1);
        while (!target.empty())
        {
            auto key_end = target.find('=');
            if (key_end == std::string_view::npos)
            {
                break;
            }
            if (target.substr(0, key_end) == key)
            {
                target.remove_prefix(key_end + 1);
                auto val_end = target.find('&');
                return std::string(target.substr(0, val_end));
            }
            auto amp_pos = target.find('&');
            if (amp_pos == std::string_view::npos)
            {
                break;
            }
            target.remove_prefix(amp_pos + 1);
        }
        return "";
    };

    std::string target(m_req.target());
    std::string srcIpStr = get_param(target, "src_ip");
    std::string dstIpStr = get_param(target, "dst_ip");
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
    std::ifstream file("../doc/OpenflowCapacity.json");
    if (!file.is_open())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Cannot open OpenflowCapacity.json");
        return;
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "Load OpenflowCapacity.json");

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
    auto get_param = [](std::string_view target, std::string_view key) -> std::string {
        auto qpos = target.find('?');
        if (qpos == std::string_view::npos)
        {
            return "";
        }
        target.remove_prefix(qpos + 1);
        while (!target.empty())
        {
            auto key_end = target.find('=');
            if (key_end == std::string_view::npos)
            {
                break;
            }
            if (target.substr(0, key_end) == key)
            {
                target.remove_prefix(key_end + 1);
                auto val_end = target.find('&');
                return std::string(target.substr(0, val_end));
            }
            auto amp_pos = target.find('&');
            if (amp_pos == std::string_view::npos)
            {
                break;
            }
            target.remove_prefix(amp_pos + 1);
        }
        return "";
    };

    std::string state = get_param(m_req.target(), "state");

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
    res.body() = json{
        {"status", "success"},
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
    res.body() = json{{"status", "success"}, {"avg_link_usage", avgLinkUsage}}.dump();
}

void
HttpSession::handleGetTotalInputTrafficLoadPassingASwitch(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Get Total Input Traffic Load Passing A Switch");
    auto jsonData = json::parse(m_req.body());
    if (jsonData.contains("dpid"))
    {
        auto dpid = jsonData.at("dpid").get<uint64_t>();
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
        SPDLOG_LOGGER_WARN(Logger::instance(), "dpid missing");
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
        SPDLOG_LOGGER_WARN(Logger::instance(), "dpid missing");
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
        // Use constants defined in the header for default values
        int ttl = LockManager::DEFAULT_TTL_SECONDS;
        std::string lockType = LockManager::DEFAULT_LOCK_TYPE_STR;

        try
        {
            auto jsonBody = json::parse(m_req.body());
            // If "type" or "ttl" are missing in JSON, use the defaults
            lockType = jsonBody.value("type", LockManager::DEFAULT_LOCK_TYPE_STR);
            ttl = jsonBody.value("ttl", LockManager::DEFAULT_TTL_SECONDS);
        }
        catch (...)
        {
            // Keep default values if JSON parsing fails
        }

        // Pass the string to LockManager; it will handle Enum conversion internally
        bool success = m_lockManager->acquireLock(lockType, ttl);

        if (success)
        {
            res.result(http::status::ok);
            res.body() = json{{"status", "locked"}, {"type", lockType}, {"ttl", ttl}}.dump();
        }
        else
        {
            // Locked by another app or invalid type
            res.result(http::status::locked);
            res.body() = json{{"error", "Lock acquisition failed"},
                              {"detail", "System busy or invalid lock type: " + lockType}}
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
        // Use constants defined in the header for default values
        int ttl = LockManager::DEFAULT_TTL_SECONDS;
        std::string lockType = LockManager::DEFAULT_LOCK_TYPE_STR;

        try
        {
            auto jsonBody = json::parse(m_req.body());
            if (jsonBody.contains("ttl"))
            {
                ttl = jsonBody.value("ttl", LockManager::DEFAULT_TTL_SECONDS);
            }
            if (jsonBody.contains("type"))
            {
                lockType = jsonBody.value("type", LockManager::DEFAULT_LOCK_TYPE_STR);
            }
        }
        catch (...)
        {
        }

        if (m_lockManager->renew(lockType, ttl))
        {
            res.result(http::status::ok);
            res.body() = json{{"status", "renewed"}, {"type", lockType}, {"ttl", ttl}}.dump();
        }
        else
        {
            res.result(http::status::precondition_failed); // 412 Precondition Failed
            res.body() =
                json{{"error", "Renew failed"},
                     {"detail", "Lock '" + lockType + "' is expired, not held, or invalid type"}}
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
        // Use constants defined in the header for default values
        std::string lockType = LockManager::DEFAULT_LOCK_TYPE_STR;

        try
        {
            auto jsonBody = json::parse(m_req.body());
            if (jsonBody.contains("type"))
            {
                lockType = jsonBody.value("type", LockManager::DEFAULT_LOCK_TYPE_STR);
            }
        }
        catch (...)
        {
        }

        m_lockManager->unlock(lockType);

        res.result(http::status::ok);
        res.body() = json{{"status", "released"}, {"type", lockType}}.dump();
    }
    catch (...)
    {
        res.result(http::status::internal_server_error);
        res.body() = json{{"error", "Release lock failed"}}.dump();
    }
}