#include "ndt_core/intent_translator/IntentTranslator.hpp"
#include "ndt_core/intent_translator/LLMResponseTypes.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <iostream>

IntentTranslator::IntentTranslator(
    std::shared_ptr<DeviceConfigurationAndPowerManager> deviceConfigManager,
    std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
    std::shared_ptr<FlowRoutingManager> flowRoutingManager,
    std::shared_ptr<sflow::FlowLinkUsageCollector> flowLinkUsageCollector,
    std::string openaiModel
) : m_deviceConfigManager(std::move(deviceConfigManager)),
    m_topologyAndFlowMonitor(std::move(topologyAndFlowMonitor)),
    m_flowRoutingManager(std::move(flowRoutingManager)),
    m_flowLinkUsageCollector(std::move(flowLinkUsageCollector))
{
    // [Co-developed with claude code -- Adam]
    // `openaiModel`, not the literal "gpt-5-nano" it used to be. The parameter was taken and
    // then dropped -- no member held it, and both agents were built with the literal -- so
    // main.cpp prompted the operator for a model (promptOpenAIModel), logged the answer, passed
    // it in, and the answer changed nothing. Same shape as the `is_mininet` knob in
    // intelligent_router.py: a value that reads as configuration and functions as a constant.
    //
    // Wiring it makes one previously dead branch reachable: LLMAgent sets m_rateLimit for any
    // model whose name contains neither "mini" nor "nano", i.e. exactly the full-size models an
    // operator would now be able to select. That branch's log and its sleep disagreed; they are
    // one constant now. See LLMAgent's kRateLimitPause.
    const std::string model = openaiModel.empty() ? std::string("gpt-5-nano") : openaiModel;
    this->m_answerAgent = std::make_shared<LLMAgent>(
        this->m_answerAgentPromptFilePath,
        this->m_topologyAndFlowMonitor,
        this->m_deviceConfigManager,
        model
    );
    this->m_validationAgent = std::make_shared<LLMAgent>(
        this->m_validationAgentPromptFilePath,
        this->m_topologyAndFlowMonitor,
        this->m_deviceConfigManager,
        model
    );
}

std::unique_ptr<llmResponse::LLMResponse>
IntentTranslator::inputTextIntent(
    std::string inputText,
    const std::string &sessionId)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Input text intent: {}", inputText);

    int maxRetryCount = 5;
    std::unique_ptr<llmResponse::LLMResponse> result;
    while (maxRetryCount--)
    {
        result = this->m_answerAgent->callOpenAIApi(inputText, sessionId);
        if (result == nullptr)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "Error from answer agent, retry");
            continue;
        }

        if (result->state == llmResponse::State::DISCUSSION)
        {
            return result;
        }
        else
        {   
            break;
            /*
            json resultJson = result;
            SPDLOG_LOGGER_DEBUG(Logger::instance(), 
                "Answer state, proceeding to validation: {}", resultJson.dump());
            break;
            */
        }
    }

    //json validatedResult = this->performAgentsNegotiation(sessionId);
    std::unique_ptr<llmResponse::LLMResponse> finalAns = std::move(result);
    
    llmResponse::Answer* ans = dynamic_cast<llmResponse::Answer*>(finalAns.get());
    if (ans == nullptr)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Failed to cast final answer to Answer type");
        throw std::runtime_error("Failed to cast final answer to Answer type");
    }

    for (const auto& task: ans->tasks)
    {
        try
        {
            std::string res = this->performTask(task.get());
            task->result = res;
        }
        catch (const std::exception &e)
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(), "Failed to perform task: {}, error: {}", 
                llmResponse::taskTypeToString(task->type), e.what());
            throw;
        }
    }

    //this->cleanSession(sessionId);

    return finalAns;
}

json
IntentTranslator::performAgentsNegotiation(const std::string &sessionId)
{
    json payloadForValidation;
    json historyDiscussionJson;
    std::vector<std::pair<LLMAgent::Role, json>> historyDiscussion = this->m_answerAgent->getSessionMsgs(sessionId);
    for (const auto &msg : historyDiscussion)
    {
        if (msg.first == LLMAgent::Role::AGENT && msg.second["msg"]["state"] == "answer") break;
        if (msg.first == LLMAgent::Role::USER)
        {
            historyDiscussionJson.push_back({{"role", "user"}, {"content", msg.second["msg"].get<std::string>()}});
        }
        else
        {
            historyDiscussionJson.push_back({{"role", "agent"}, {"content", msg.second["msg"]["prompt"].get<std::string>()}});
        }
    }
    payloadForValidation["discussion"] = historyDiscussionJson;
    payloadForValidation["proposed_tasks"] = historyDiscussion.back().second["msg"]["tasks"];

    int maxNegotiateRound = 10;
    bool valid = historyDiscussion.back().second["msg"]["valid"].get<int>();
    
    while(maxNegotiateRound--)
    {
        if (!valid) break;
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "============================ Validation Agent ============================");
        auto result = this->m_validationAgent->callOpenAIApi(payloadForValidation.dump(), sessionId);
        if (result == nullptr)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "validation agent reply with wrong format, retry");
            continue;
        }
        std::unique_ptr<llmResponse::Validation> validationRes;
        try
        {
            validationRes = std::unique_ptr<llmResponse::Validation>(
                dynamic_cast<llmResponse::Validation*>(result.release()));
            if (validationRes->errorMsg == "")
            {
                SPDLOG_LOGGER_INFO(Logger::instance(), "pass validation");
                SPDLOG_LOGGER_DEBUG(Logger::instance(), "==========================================================================");

                // TODO: refactor
                return json{
                    {"tasks", payloadForValidation["proposed_tasks"]},
                    {"valid", 1},
                    {"explanation", ""},
                    {"state", "answer"}
                };
            }
        }
        catch (const std::exception &e)
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(), "Failed to cast validation response: {}", e.what());
            continue;
        }
        SPDLOG_LOGGER_DEBUG(Logger::instance(), 
            "validation agent's reply: {}, retry", validationRes->errorMsg);
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "==========================================================================");
        
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "============================== Answer Agent ==============================");
        auto newTasks = this->m_answerAgent->callOpenAIApi(
            validationRes->errorMsg + "\nPlease regenerate the answer. DO NOT enter discussion state anymore.", 
            sessionId);
        if (newTasks == nullptr)
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "answer agent reply with wrong format, retry");
            continue;
        }
        
        json newTasksJson = newTasks;
        
        SPDLOG_LOGGER_DEBUG(Logger::instance(), 
            "New tasks proposed by answer agent: {}", newTasksJson.dump());

        payloadForValidation["proposed_tasks"].clear();
        payloadForValidation["proposed_tasks"] = newTasksJson["tasks"];
        valid = newTasksJson["valid"].get<int>();
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "==========================================================================");
    }

    // negotiate round is larger than 10, return the last result
    historyDiscussion = this->m_answerAgent->getSessionMsgs(sessionId);
    return historyDiscussion.back().second["msg"];
}

optional<std::string>
IntentTranslator::getSwitchIpByName(const std::string &switchName)
{
    auto vdOpt = this->m_topologyAndFlowMonitor->findVertexByMininetBridgeName(switchName);
    if (!vdOpt.has_value())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Switch {} not found in topology", switchName);
        return std::nullopt;
    }
    auto graph = this->m_topologyAndFlowMonitor->getGraph();
    auto& vertex = graph[vdOpt.value()];
    if (vertex.vertexType != VertexType::SWITCH)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Vertex {} is not a switch", switchName);
        return std::nullopt;
    }
    return utils::ipToString(vertex.ip[0]);
}

// [Co-developed with claude code -- Adam]
optional<uint64_t>
IntentTranslator::dpidForSwitchIp(const std::string& switchIp) const
{
    const auto& map = this->m_topologyAndFlowMonitor->m_ipStrToDpidMap;
    const auto it = map.find(switchIp);
    if (it == map.end())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "No dpid registered for switch IP {}", switchIp);
        return std::nullopt;
    }
    return it->second;
}

// [Co-developed with claude code -- Adam]
// The three reply renderers below are pure and static so the shape of a reply is assertable on
// its own, following interpretRelayResponse / ovsLivenessFor / p4LivenessFor. json{}.dump() is
// used rather than the string concatenation the DISABLE/ENABLE cases above use: a device name
// containing a quote would otherwise emit a malformed body, and device names arrive from an LLM.
std::string
IntentTranslator::switchNotFoundReply(const std::string& deviceName)
{
    return json{{"error", "Switch not found"}, {"device", deviceName}}.dump();
}

std::string
IntentTranslator::powerReply(bool ok, const std::string& action, const std::string& deviceName)
{
    if (!ok)
    {
        return json{{"error", "Power " + action + " failed"}, {"device", deviceName}}.dump();
    }
    return json{{"status", action == "off" ? "powered_off" : "powered_on"},
                {"device", deviceName}}
        .dump();
}

std::string
IntentTranslator::flowReply(const OpResult& result,
                            const std::string& operation,
                            const std::string& deviceName)
{
    if (!result.ok)
    {
        return json{{"error", "Flow entry " + operation + " failed"},
                    {"device", deviceName},
                    {"http_status", result.httpStatus},
                    {"detail", result.message}}
            .dump();
    }
    return json{{"status", operation + "ed"}, {"device", deviceName}}.dump();
}

std::string
IntentTranslator::performTask(llmResponse::Task* task)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Performing task: {}", llmResponse::taskTypeToString(task->type));
    switch (task->type)
    {
        case llmResponse::TaskType::DISABLE_SWITCH:
        {
            llmResponse::DisableSwitchTask* disableTask = dynamic_cast<llmResponse::DisableSwitchTask*>(task);
            auto deviceIpOpt = this->getSwitchIpByName(disableTask->deviceName);
            if (!deviceIpOpt.has_value())
            {
                return "{\"error\": \"Switch not found\", \"device\": \"" + disableTask->deviceName + "\"}";
            }
            // [Co-developed with claude code -- Adam]
            // find(), not operator[]: on a map, operator[] default-constructs a missing key, so an
            // IP the map has never seen silently became dpid 0 -- and inserted that, mutating the
            // map as a side effect of reading it.
            const auto it = this->m_topologyAndFlowMonitor->m_ipStrToDpidMap.find(deviceIpOpt.value());
            if (it == this->m_topologyAndFlowMonitor->m_ipStrToDpidMap.end())
            {
                return "{\"error\": \"Switch has no dpid\", \"device\": \"" + disableTask->deviceName + "\"}";
            }
            if (!this->m_topologyAndFlowMonitor->disableSwitchAndEdges(it->second))
            {
                return "{\"error\": \"Switch not present in the topology graph\", \"device\": \"" + disableTask->deviceName + "\"}";
            }
            return "{\"status\": \"disabled\", \"device\": \"" + disableTask->deviceName + "\"}";
        }
        case llmResponse::TaskType::ENABLE_SWITCH:
        {
            llmResponse::EnableSwitchTask* enableTask = dynamic_cast<llmResponse::EnableSwitchTask*>(task);
            auto deviceIpOpt = this->getSwitchIpByName(enableTask->deviceName);
            if (!deviceIpOpt.has_value())
            {
                return "{\"error\": \"Switch not found\", \"device\": \"" + enableTask->deviceName + "\"}";
            }
            const auto it = this->m_topologyAndFlowMonitor->m_ipStrToDpidMap.find(deviceIpOpt.value());
            if (it == this->m_topologyAndFlowMonitor->m_ipStrToDpidMap.end())
            {
                return "{\"error\": \"Switch has no dpid\", \"device\": \"" + enableTask->deviceName + "\"}";
            }
            if (!this->m_topologyAndFlowMonitor->enableSwitchAndEdges(it->second))
            {
                return "{\"error\": \"Switch not present in the topology graph\", \"device\": \"" + enableTask->deviceName + "\"}";
            }
            return "{\"status\": \"enabled\", \"device\": \"" + enableTask->deviceName + "\"}";
        }
        case llmResponse::TaskType::POWEROFF_SWITCH:
        {
            llmResponse::PowerOffSwitchTask* poweroffTask = dynamic_cast<llmResponse::PowerOffSwitchTask*>(task);
            auto deviceIpOpt = this->getSwitchIpByName(poweroffTask->deviceName);
            if (!deviceIpOpt.has_value())
            {
                return switchNotFoundReply(poweroffTask->deviceName);
            }
            SPDLOG_LOGGER_DEBUG(Logger::instance(), "Powering off switch: {}", deviceIpOpt.value());
            return powerReply(this->m_deviceConfigManager->setSwitchPowerState(deviceIpOpt.value(),
                                                                              "off"),
                              "off",
                              poweroffTask->deviceName);
        }
        case llmResponse::TaskType::POWERON_SWITCH:
        {
            llmResponse::PowerOnSwitchTask* powerOnTask = dynamic_cast<llmResponse::PowerOnSwitchTask*>(task);
            auto deviceIpOpt = this->getSwitchIpByName(powerOnTask->deviceName);
            if (!deviceIpOpt.has_value())
            {
                return switchNotFoundReply(powerOnTask->deviceName);
            }
            SPDLOG_LOGGER_DEBUG(Logger::instance(), "Powering on switch: {}", deviceIpOpt.value());
            return powerReply(this->m_deviceConfigManager->setSwitchPowerState(deviceIpOpt.value(),
                                                                               "on"),
                              "on",
                              powerOnTask->deviceName);
        }
        case llmResponse::TaskType::INSTALL_FLOW_ENTRY:
        {
            llmResponse::InstallFlowEntryTask* installTask = dynamic_cast<llmResponse::InstallFlowEntryTask*>(task);
            auto deviceIpOpt = this->getSwitchIpByName(installTask->deviceName);
            if (deviceIpOpt.has_value())
            {
                const auto dpidOpt = this->dpidForSwitchIp(deviceIpOpt.value());
                if (!dpidOpt.has_value())
                {
                    return "{\"error\": \"Switch has no dpid\", \"device\": \"" + installTask->deviceName + "\"}";
                }
                uint64_t dpid = *dpidOpt;
                json installTaskJson = *installTask;
                json match = installTaskJson["parameters"]["match"];

                match["dl_type"] = match["eth_type"];
                match.erase("eth_type");
                match["nw_dst"] = match["ipv4_dst"];
                match.erase("ipv4_dst");

                return flowReply(this->m_flowRoutingManager->installAnEntry(
                                     dpid,
                                     installTaskJson["parameters"]["priority"].get<int>(),
                                     match,
                                     installTaskJson["parameters"]["actions"]),
                                 "install",
                                 installTask->deviceName);
            }
            return switchNotFoundReply(installTask->deviceName);
        }
        case llmResponse::TaskType::MODIFY_FLOW_ENTRY:
        {
            llmResponse::ModifyFlowEntryTask* modifyTask = dynamic_cast<llmResponse::ModifyFlowEntryTask*>(task);
            auto deviceIpOpt = this->getSwitchIpByName(modifyTask->deviceName);
            if (deviceIpOpt.has_value())
            {
                const auto dpidOpt = this->dpidForSwitchIp(deviceIpOpt.value());
                if (!dpidOpt.has_value())
                {
                    return "{\"error\": \"Switch has no dpid\", \"device\": \"" + modifyTask->deviceName + "\"}";
                }
                uint64_t dpid = *dpidOpt;
                json modifyTaskJson = *modifyTask;
                json match = modifyTaskJson["parameters"]["match"];

                match["dl_type"] = match["eth_type"];
                match.erase("eth_type");
                match["nw_dst"] = match["ipv4_dst"];
                match.erase("ipv4_dst");
                
                return flowReply(this->m_flowRoutingManager->modifyAnEntry(
                                     dpid,
                                     modifyTaskJson["parameters"]["priority"].get<int>(),
                                     match,
                                     modifyTaskJson["parameters"]["actions"]),
                                 "modify",
                                 modifyTask->deviceName);
            }
            return switchNotFoundReply(modifyTask->deviceName);
        }
        case llmResponse::TaskType::DELETE_FLOW_ENTRY:
        {
            llmResponse::DeleteFlowEntryTask* deleteTask = dynamic_cast<llmResponse::DeleteFlowEntryTask*>(task);
            auto deviceIpOpt = this->getSwitchIpByName(deleteTask->deviceName);
            if (deviceIpOpt.has_value())
            {
                const auto dpidOpt = this->dpidForSwitchIp(deviceIpOpt.value());
                if (!dpidOpt.has_value())
                {
                    return "{\"error\": \"Switch has no dpid\", \"device\": \"" + deleteTask->deviceName + "\"}";
                }
                uint64_t dpid = *dpidOpt;
                json deleteTaskJson = *deleteTask;
                return flowReply(this->m_flowRoutingManager->deleteAnEntry(
                                     dpid, deleteTaskJson["parameters"]["match"]),
                                 "delete",
                                 deleteTask->deviceName);
            }
            return switchNotFoundReply(deleteTask->deviceName);
        }
        case llmResponse::TaskType::GET_TOP_K_FLOWS:
        {
            llmResponse::GetTopKFlowsTask* getTopKFlowTask = dynamic_cast<llmResponse::GetTopKFlowsTask*>(task);
            json topKFlows = this->m_flowLinkUsageCollector->getTopKFlowInfoJson(getTopKFlowTask->k);
            return topKFlows.dump();
        }
        case llmResponse::TaskType::GET_SWITCH_CPU_UTILIZATION:
        {
            json cpuUtil = this->m_deviceConfigManager->getCpuUtilization();
            return cpuUtil.dump();
        }
        case llmResponse::TaskType::GET_TOTAL_POWER_CONSUMPTION: 
        {

            json powerConsumption = this->m_deviceConfigManager->getPowerReport();
            return powerConsumption.dump();
        }
        case llmResponse::TaskType::GET_A_SWITCH_CPU_UTILIZATION: 
        {
            llmResponse::GetASwitchCpuUtilizationTask* getSingleSwitchCpuReport = dynamic_cast<llmResponse:: GetASwitchCpuUtilizationTask*>(task);
            json cpuSingleSwitchConsumption;
            auto deviceIpOpt = this->getSwitchIpByName(getSingleSwitchCpuReport->deviceName);
            if (deviceIpOpt.has_value()){
                cpuSingleSwitchConsumption = this->m_deviceConfigManager->getSingleSwitchCpuReport(*deviceIpOpt);
            }
            return cpuSingleSwitchConsumption.dump();

        }
        case llmResponse::TaskType::GET_A_SWITCH_POWER_CONSUMPTION: 
        {
            llmResponse::GetASwitchPowerConsumptionTask* getASwitchPowerConsumptionTask = dynamic_cast<llmResponse::GetASwitchPowerConsumptionTask*>(task);
            json powerSingleSwitchConsumption;
            auto deviceIpOpt = this->getSwitchIpByName(getASwitchPowerConsumptionTask->deviceName);
            if (deviceIpOpt.has_value()){
                powerSingleSwitchConsumption = this->m_deviceConfigManager->getSingleSwitchPowerReport(*deviceIpOpt);
            }
            return powerSingleSwitchConsumption.dump();
        }
        case llmResponse::TaskType::GET_A_LINK_BANDWIDTH_UTILIZATION:
        {   
            
            // 1. Safely cast the generic task to our specific task type
            llmResponse::GetALinkBandwidthUtilizationTask*  getLinkBandwidthTask = dynamic_cast<llmResponse::GetALinkBandwidthUtilizationTask*>(task);
            json linkBandwidth; // Default to an empty JSON object

            // 2. Get the DPIDs for both device names provided in the task
            //    (You will need to implement getSwitchDpidByName, see below)
            auto dpid1_opt = this->getSwitchIpByName(getLinkBandwidthTask->srcDeviceName);
            auto dpid2_opt = this->getSwitchIpByName(getLinkBandwidthTask->dstDeviceName);

            // 3. If both switches were found, call the manager function
            if (dpid1_opt.has_value() && dpid2_opt.has_value())
            {
                SPDLOG_LOGGER_ERROR(Logger::instance(), "Finding link bandwidth between {} and {}"
                    ,getLinkBandwidthTask->srcDeviceName, 
                    getLinkBandwidthTask->dstDeviceName);

                linkBandwidth = this->m_topologyAndFlowMonitor->getLinkBandwidthBetweenSwitches(
                    *dpid1_opt, *dpid2_opt
                );
            }

            else
            {
                SPDLOG_LOGGER_WARN(Logger::instance(),"Could not find DPIDs for one or both switches: '{}', '{}'", 
                    getLinkBandwidthTask->srcDeviceName, getLinkBandwidthTask->dstDeviceName);
            }

            // 4. Return the resulting JSON as a string
            return linkBandwidth.dump();
            
        }
        case llmResponse::TaskType::GET_TOP_K_CONGESTED_LINKS:
        {
            // 1. Safely cast the generic task to our specific task type
            llmResponse::GetTopKCongestedLinksTask* getTopKLinksTask = 
                dynamic_cast<llmResponse::GetTopKCongestedLinksTask*>(task);
            
            // 2. Check if the cast was successful
            if (!getTopKLinksTask)
            {
                SPDLOG_LOGGER_ERROR(Logger::instance(), "Task cast to GetTopKCongestedLinksTask failed.");
                return {"error:" "Internal server error during task processing."};
            }

            // 3. Call the manager to get the top K congested links as a JSON object
            json topKLinks = this->m_topologyAndFlowMonitor->getTopKCongestedLinksJson(getTopKLinksTask->k);

            // 4. Return the resulting JSON as a string
            return topKLinks.dump();

        }
        case llmResponse::TaskType::GET_TOP_K_BANDWIDTH_USERS: 
        {
            // 1. Safely cast the generic task to our specific task type.
            auto* getTopKUsersTask =
                dynamic_cast<llmResponse::GetTopKBandwidthUsersTask*>(task);
            
            if (!getTopKUsersTask)
            {
                SPDLOG_LOGGER_ERROR(Logger::instance(), "Task cast to GetTopKBandwidthUsersTask failed.");
                return {"error:" "Internal server error during task processing."};
            }

            // 2. Call the collector to get the top K flows. The source IPs in these
            //    flows represent the top bandwidth users.
            json topKUsers = this->m_flowLinkUsageCollector->getTopKFlowInfoJson(getTopKUsersTask->k);

            // 3. Return the resulting JSON as a string.
            return topKUsers.dump();

        }    
        case llmResponse::TaskType::GET_PATH:
        {
            llmResponse::GetPathTask* getPathTask = dynamic_cast<llmResponse::GetPathTask*>(task);
            if (!getPathTask)
            {
                SPDLOG_LOGGER_ERROR(Logger::instance(), "Task cast to GetPathTask failed.");
                return {"error" "Internal server error during task processing."};
            }

            json path = this->m_flowLinkUsageCollector->getPathBetweenHostsJson(
                getPathTask->srcHostName,
                getPathTask->dstHostName
            );

            return path.dump();

        }
        case llmResponse::TaskType::GET_ACTIVE_FLOW_COUNT:
        {
            // Get the current flow table from the collector
            auto flowTable = this->m_flowLinkUsageCollector->getFlowInfoTable();
            size_t flowCount = flowTable.size();
            json result;
            result["active_flow_count"] = flowCount;
            // Return the JSON object as a string
            return result.dump();
        }
        case llmResponse::TaskType::GET_FLOW_ENTRY_COUNT:  
        {
            llmResponse::GetFlowEntryCountTask* getCountTask =
                dynamic_cast<llmResponse::GetFlowEntryCountTask*>(task);
            if (!getCountTask) { /* ... error handling ... */ }

            // Call the helper function
            auto flowEntriesOpt = this->getFlowEntriesForSwitch(getCountTask->deviceName);

            // Check if the helper succeeded
            if (!flowEntriesOpt.has_value())
            {
                return "{\"error\": \"Could not retrieve flow information for switch.\", \"device_name\": \"" + getCountTask->deviceName + "\"}";
            }

            // The only logic left is to get the size
            json result;
            result["switch_name"] = getCountTask->deviceName;
            result["flow_entry_count"] = flowEntriesOpt->size();
            return result.dump();
        }
        case llmResponse::TaskType::GET_FLOW_ENTRIES:  
        {
            llmResponse::GetFlowEntriesTask* getEntriesTask =
                dynamic_cast<llmResponse::GetFlowEntriesTask*>(task);
            if (!getEntriesTask) { /* ... error handling ... */ }

            // Call the same helper function
            auto flowEntriesOpt = getFlowEntriesForSwitch(getEntriesTask->deviceName);

            // Check if the helper succeeded
            if (!flowEntriesOpt.has_value())
            {
                return "{\"error\": \"Could not retrieve flow information for switch.\", \"device_name\": \"" + getEntriesTask->deviceName + "\"}";
            }
            
            // The only logic left is to use the full result
            json result;
            result["switch_name"] = getEntriesTask->deviceName;
            result["flow_entries"] = *flowEntriesOpt; // Use the returned json directly
            return result.dump();

        }

        case llmResponse::TaskType::GET_NETWORK_TOPOLOGY:
        {

            auto graph = this->m_topologyAndFlowMonitor->getGraph();
            json topoJson;
            topoJson["switches"] = json::array();
            topoJson["hosts"] = json::array();
            topoJson["links"] = json::array();


            for (auto [vi, viEnd] = boost::vertices(graph); vi != viEnd; ++vi)
            {
                const auto& vprop = (graph)[*vi];
                if (vprop.vertexType == VertexType::SWITCH)
                {
                    topoJson["switches"].push_back({
                        {"name", vprop.deviceName},
                        {"dpid", vprop.dpid},
                        {"ip", utils::ipToString(vprop.ip[0])},
                        {"status", (vprop.isUp ? "UP" : "DOWN")}
                    });
                }
                else if (vprop.vertexType == VertexType::HOST)
                {
                    topoJson["hosts"].push_back({
                        {"name", vprop.deviceName},
                        {"ip", utils::ipToString(vprop.ip[0])},
                        {"mac", vprop.mac}
                    });
                }
            }


            for (auto [ei, eiEnd] = boost::edges(graph); ei != eiEnd; ++ei)
            {
                const auto& eprop = (graph)[*ei];
                auto e = *ei;
                auto srcVd = boost::source(e, graph); 
                auto targetVd = boost::target(e, graph);
                
                topoJson["links"].push_back({
                    {"src", graph[srcVd].deviceName},
                    {"dst", graph[targetVd].deviceName},
                    {"src_port", eprop.srcInterface},
                    {"dst_port", eprop.dstInterface},
                    {"status", (eprop.isUp ? "UP" : "DOWN")}
                });
            }

            return topoJson.dump();
        }

        case llmResponse::TaskType::GET_ALL_HOSTS:
        {

            auto graph = this->m_topologyAndFlowMonitor->getGraph();
            json hostsJson = json::array();
            for (auto [vi, viEnd] = boost::vertices(graph); vi != viEnd; ++vi)
            {
                const auto& vprop = (graph)[*vi];
                if (vprop.vertexType == VertexType::HOST) {
                    hostsJson.push_back({
                        {"name", vprop.deviceName},
                        {"ip", utils::ipToString(vprop.ip[0])},
                        {"mac", vprop.mac}
                    });
                }
            }
            return hostsJson.dump();
        }

        case llmResponse::TaskType::BLOCK_HOST:
        {
            auto* blockTask = dynamic_cast<llmResponse::BlockHostTask*>(task);
            if (!blockTask) return "{\"error\": \"Task cast failed\"}";


            auto hostVertexOpt = this->m_topologyAndFlowMonitor->findVertexByDeviceName(blockTask->host_id);
            if (!hostVertexOpt.has_value())
            {
                return "{\"error\": \"Host not found in topology\", \"host\": \"" + blockTask->host_id + "\"}";
            }

            auto graph = this->m_topologyAndFlowMonitor->getGraph();
            auto hostVd = *hostVertexOpt;
            auto& hostProp = graph[hostVd];


            if (hostProp.vertexType != VertexType::HOST)
            {
                 return "{\"error\": \"Device is not a host\", \"device\": \"" + blockTask->host_id + "\"}";
            }


            if (hostProp.ip.empty())
            {
                return "{\"error\": \"Host has no IP address assigned\", \"device\": \"" + blockTask->host_id + "\"}";
            }
            std::string hostIp = utils::ipToString(hostProp.ip[0]);

            auto neighbors = boost::adjacent_vertices(hostVd, graph);
            if (neighbors.first == neighbors.second)
            {
                 return "{\"error\": \"Host is not connected to any switch\"}";
            }


            auto switchVd = *neighbors.first;
            auto& switchProp = graph[switchVd];


            if (switchProp.vertexType != VertexType::SWITCH)
            {
                return "{\"error\": \"Connected neighbor is not a switch\"}";
            }


            json match;
            match["eth_type"] = 0x0800; 
            match["ipv4_src"] = hostIp; 

            json actions = json::array();

            int priority = 50000; 

            try {
                this->m_flowRoutingManager->installAnEntry(switchProp.dpid, priority, match, actions);
                
                SPDLOG_LOGGER_INFO(Logger::instance(), 
                    "Blocked host {} (IP: {}) on switch {} (DPID: {})", 
                    blockTask->host_id, hostIp, switchProp.deviceName, switchProp.dpid);

                return "{\"status\": \"success\", \"message\": \"Host " + blockTask->host_id + " blocked.\", \"target_switch\": \"" + switchProp.deviceName + "\"}";
            }
            catch (const std::exception& e) {
                SPDLOG_LOGGER_ERROR(Logger::instance(), "Failed to install block rule: {}", e.what());
                return "{\"error\": \"Internal error installing flow rule\"}";
            }
        }

        case llmResponse::TaskType::GET_LINK_LATENCY:
        {
            //llmResponse::GetLinkLatencyTask* latencyTask = dynamic_cast<llmResponse::GetLinkLatencyTask*>(task);
            // Assuming a performance monitor can measure latency between two switches by name.
            //this->m_performanceMonitor->measureLinkLatency(latencyTask->src, latencyTask->dst);
            break;
        }

        case llmResponse::TaskType::GET_PACKET_LOSS_RATE:
        {
            auto* lossTask = dynamic_cast<llmResponse::GetPacketLossRateTask*>(task);
            if (!lossTask) return "{\"error\": \"Task cast failed\"}";


            auto srcIpOpt = this->getSwitchIpByName(lossTask->src);
            auto dstIpOpt = this->getSwitchIpByName(lossTask->dst);

            if (srcIpOpt.has_value() && dstIpOpt.has_value())
            {
                const auto srcDpidOpt = this->dpidForSwitchIp(*srcIpOpt);
                const auto dstDpidOpt = this->dpidForSwitchIp(*dstIpOpt);
                if (!srcDpidOpt.has_value() || !dstDpidOpt.has_value())
                {
                    return "{\"error\": \"Switch has no dpid\", \"src\": \"" + lossTask->src
                           + "\", \"dst\": \"" + lossTask->dst + "\"}";
                }
                uint64_t srcDpid = *srcDpidOpt;
                uint64_t dstDpid = *dstDpidOpt;


                auto edgeOpt = this->m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({srcDpid, dstDpid});

                if (edgeOpt.has_value())
                {
                    auto graph = this->m_topologyAndFlowMonitor->getGraph();
                    const auto& edge = graph[*edgeOpt];

                    double lossRate = 0.0;


                    if (!edge.isUp) 
                    {
   
                        lossRate = 100.0;
                    }
                    else 
                    {

                        double util = edge.linkBandwidthUtilization;
                        
                        if (util > 100.0) lossRate = 5.0 + (util - 100.0) * 0.5; 
                        else if (util > 90.0) lossRate = (util - 90.0) * 0.1;   
                        else lossRate = 0.0; // 正常

                    }

                    return json{
                        {"src", lossTask->src},
                        {"dst", lossTask->dst},
                        {"packet_loss_rate", lossRate},
                        {"utilization", edge.linkBandwidthUtilization},
                        {"status", edge.isUp ? "UP" : "DOWN"}
                    }.dump();
                }
                else
                {
                    return "{\"error\": \"No direct link found between " + lossTask->src + " and " + lossTask->dst + "\"}";
                }
            }
            return "{\"error\": \"One or both switches not found\"}";
        }

        case llmResponse::TaskType::GET_SWITCH_PORTS:
        {
            auto* portsTask = dynamic_cast<llmResponse::GetSwitchPortsTask*>(task);
            if (!portsTask) return "{\"error\": \"Task cast failed\"}";

 
            auto switchVertexOpt = this->m_topologyAndFlowMonitor->findVertexByDeviceName(portsTask->deviceName);
            
            if (!switchVertexOpt.has_value())
            {
                return "{\"error\": \"Switch not found\", \"device\": \"" + portsTask->deviceName + "\"}";
            }

            auto graph = this->m_topologyAndFlowMonitor->getGraph();
            auto swVd = *switchVertexOpt;
            

            if (graph[swVd].vertexType != VertexType::SWITCH)
            {
                 return "{\"error\": \"Device is not a switch\", \"device\": \"" + portsTask->deviceName + "\"}";
            }

            json portsArray = json::array();


            for (auto [ei, eiEnd] = boost::out_edges(swVd, graph); ei != eiEnd; ++ei)
            {
                auto edge = *ei;
                const auto& edgeProp = graph[edge];
                

                auto targetVd = boost::target(edge, graph);
                const auto& targetProp = graph[targetVd];

                json portInfo;

                portInfo["port_id"] = edgeProp.srcInterface; 
                portInfo["status"] = edgeProp.isUp ? "UP" : "DOWN";
                portInfo["connected_to"] = targetProp.deviceName; 

                portInfo["speed_bps"] = edgeProp.linkBandwidth;

                portsArray.push_back(portInfo);
            }


            json result;
            result["device_name"] = portsTask->deviceName;
            result["ports"] = portsArray;
            

            if (portsArray.empty()) {
                result["message"] = "No active links found on this switch.";
            }

            return result.dump();
        }

        case llmResponse::TaskType::REROUTE_FLOW:
        {

        }

        case llmResponse::TaskType::GET_SWITCH_MEMORY_UTILIZATION:
        {
            // Assuming a device monitor can fetch this data for all switches.
            //this->m_deviceMonitor->getMemoryUtilization();
            break;
        }

        case llmResponse::TaskType::GET_SWITCH_TEMPERATURE:
        {
            // Assuming a device monitor can fetch temperature data for all switches.
            //this->m_deviceMonitor->getSwitchTemperatures();
            break;
        }


        case llmResponse::TaskType::SET_SWITCH_POWER_STATE:
        {
            //llmResponse::SetSwitchPowerStateTask* powerTask = dynamic_cast<llmResponse::SetSwitchPowerStateTask*>(task);
            // Assuming a power management component handles this.
            //this->m_powerManager->setPowerState(powerTask->deviceName, powerTask->state);
            break;
        }

        case llmResponse::TaskType::GET_PATH_SWITCH_COUNT:
        {
            //llmResponse::GetPathSwitchCountTask* pathTask = dynamic_cast<llmResponse::GetPathSwitchCountTask*>(task);
            // Assuming a topology monitor can calculate the hop count.
            //this->m_topologyMonitor->getPathSwitchCount(pathTask->src, pathTask->dst);
            break;
        }

        case llmResponse::TaskType::SET_DEVICE_NICKNAME:
        {
            //llmResponse::SetDeviceNicknameTask* nicknameTask = dynamic_cast<llmResponse::SetDeviceNicknameTask*>(task);
            // Assuming a central manager for device metadata.
            //this->m_deviceManager->setNickname(nicknameTask->deviceName, nicknameTask->nickname);
            break;
        }

        case llmResponse::TaskType::TOGGLE_HISTORICAL_LOGGING:
        {
            //llmResponse::ToggleHistoricalLoggingTask* loggingTask = dynamic_cast<llmResponse::ToggleHistoricalLoggingTask*>(task);
            // Assuming a logging manager component.
            /*
            bool enable = (loggingTask->state == "enable");
            this->m_loggingManager->setLoggingState(enable);
            */
            break;
        }

        case llmResponse::TaskType::GET_SWITCH_CAPABILITIES:
        {   /*
            // Assuming a component can query and report switch model capabilities.
            this->m_deviceManager->getSwitchCapabilities();
            */
            break;
        }

        case llmResponse::TaskType::INSTALL_GROUP_ENTRY:
        {
            //llmResponse::InstallGroupEntryTask* groupTask = dynamic_cast<llmResponse::InstallGroupEntryTask*>(task);
            /*
            auto deviceIpOpt = this->getSwitchIpByName(groupTask->deviceName);
            if (deviceIpOpt.has_value())
            {
                uint64_t dpid = this->m_topologyAndFlowMonitor->m_ipStrToDpidMap[deviceIpOpt.value()];
                // Assuming a flow manager can install OpenFlow group entries.
                this->m_flowManager->installGroupEntry(dpid, groupTask->group_id, groupTask->group_type, groupTask->buckets);
            }
            */
            break;
        }

        case llmResponse::TaskType::INSTALL_METER_ENTRY:
        {
            //llmResponse::InstallMeterEntryTask* meterTask = dynamic_cast<llmResponse::InstallMeterEntryTask*>(task);
            /*
            auto deviceIpOpt = this->getSwitchIpByName(meterTask->deviceName);
            if (deviceIpOpt.has_value())
            {
                uint64_t dpid = this->m_topologyAndFlowMonitor->m_ipStrToDpidMap[deviceIpOpt.value()];
                // Assuming a flow manager can install OpenFlow meter entries.
                this->m_flowManager->installMeterEntry(dpid, meterTask->meter_id, meterTask->flags, meterTask->bands);
            }
            */
            break;
        }
        case llmResponse::TaskType::GET_DEVICE_UPTIME:
        {
            break;
        }
        case llmResponse::TaskType::RESTART_DEVICE:
        {
            break;
        }
        case llmResponse::TaskType::BACKUP_CONFIGURATION:
        {
            break;
        }
        case llmResponse::TaskType::RESTORE_CONFIGURATION:
        {
            break;
        }
        case llmResponse::TaskType::PING_HOST:
        {
            break;
        }
        case llmResponse::TaskType::TRACEROUTE_HOST:
        {
            break;
        }
        case llmResponse::TaskType::GET_ARP_TABLE:
        {
            break;
        }
        case llmResponse::TaskType::GET_MAC_TABLE:
        {
            break;
        }
        case llmResponse::TaskType::SET_PORT_STATUS:
        {
            break;
        }
        case llmResponse::TaskType::GET_PORT_STATISTICS:
        {
            break;
        }
        case llmResponse::TaskType::GET_DEVICE_LOGS:
        {
            break;
        }
        case llmResponse::TaskType::CLEAR_DEVICE_LOGS:
        {
            break;
        }
        case llmResponse::TaskType::UPDATE_DEVICE_FIRMWARE:
        {
            break;
        }
        case llmResponse::TaskType::GET_DEVICE_HEALTH:
        {
            break;
        }
        case llmResponse::TaskType::MONITOR_REAL_TIME_TRAFFIC:
        {
            break;
        }
        case llmResponse::TaskType::REQUEST_UI_FORM:
        {
            auto* uiTask = dynamic_cast<llmResponse::RequestUIFormTask*>(task);
            if (!uiTask) return "{\"error\": \"Task cast failed\"}";
            
            SPDLOG_LOGGER_INFO(Logger::instance(), 
                "LLM requested UI form: {} for device {}", 
                uiTask->formType, uiTask->deviceName);

            return "{\"status\": \"ui_triggered\", \"form\": \"" + uiTask->formType + "\"}";
        }
        default:
            throw std::runtime_error(std::string("Unknown task type: ") + llmResponse::taskTypeToString(task->type));
    }
    SPDLOG_LOGGER_INFO(Logger::instance(), "Finish performing task");
    return "ok";
}

void 
IntentTranslator::cleanSession(const std::string &sessionId)
{
    this->m_answerAgent->cleanSession(sessionId);
    this->m_validationAgent->cleanSession(sessionId);
}

std::optional<nlohmann::json>
IntentTranslator::getFlowEntriesForSwitch(const std::string& deviceName)
{
    // 1. Find the switch in the topology to get its DPID
    auto switchVertexOpt = m_topologyAndFlowMonitor->findVertexByDeviceName(deviceName);
    if (!switchVertexOpt.has_value())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Switch '{}' not found in topology.", deviceName);
        return std::nullopt; // Switch not found
    }
    auto graph = m_topologyAndFlowMonitor->getGraph();
    uint64_t dpid = graph[*switchVertexOpt].dpid;
    std::string dpid_str = std::to_string(dpid);

    // 2. Get the current flow tables for all switches
    json openflowTables = this->m_deviceConfigManager->getOpenFlowTables();

    // 3. Find the specific switch's table and return its flow entries
    for (const auto& switchTable : openflowTables)
    {
        if (switchTable["dpid"].get<uint64_t>() == dpid)
        {
            if (switchTable.contains("flows") && switchTable["flows"].contains(dpid_str))
            {
                return switchTable["flows"][dpid_str]; // Success! Return the array of flows.
            }
            else
            {
                return json::array(); // Switch found but has no flows, return empty array.
            }
        }
    }

    SPDLOG_LOGGER_WARN(Logger::instance(), "Flow table for switch '{}' (DPID {}) not available.", deviceName, dpid);
    return std::nullopt; // Flow table data for the switch was not found
}