#include "ndt_core/intent_translator/LLMAgent.hpp"
#include "common_types/GraphTypes.hpp"
#include "utils/Utils.hpp"
#include <iostream>
#include <fstream>
#include <chrono>

using Clock = std::chrono::steady_clock;

LLMAgent::LLMAgent(
    std::string systemPromptFilePath,
    std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
    std::shared_ptr<DeviceConfigurationAndPowerManager> deviceConfigurationAndPowerManager,
    std::string model
)
    : m_systemPromptFilePath(std::move(systemPromptFilePath)),
      m_topologyAndFlowMonitor(std::move(topologyAndFlowMonitor)),
      m_deviceConfigManager(std::move(deviceConfigurationAndPowerManager)),
      m_model(model)
{
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "LLMAgent initialized with system prompt file: {}", m_systemPromptFilePath);
    if (!std::filesystem::exists(this->m_systemPromptFilePath)){
        SPDLOG_LOGGER_ERROR(Logger::instance(), "system prompt file not exist");
        throw std::runtime_error("system prompt file not exist");
    }

    char* apiKey = std::getenv("OPENAI_API_KEY");

    // [Co-developed with claude code -- Adam]
    // The secret is never logged. This used to be `SPDLOG_LOGGER_INFO(..., "api_key={}", apiKey)`
    // at INFO -- the default-on level -- so every AI-enabled start wrote the key into the kernel
    // log, and this project routinely pastes log excerpts into doc/debug-log/ and handoff
    // documents. The null check now runs *first* as well: the old order formatted apiKey before
    // testing it, and fmt formatting a null char* is not a printable "(null)" path.
    if (apiKey == nullptr)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "OPENAI_API_KEY environment variable is not set.");
        throw std::runtime_error("OPENAI_API_KEY environment variable is not set.");
    }
    this->m_apiKey = apiKey;
    // Presence, not value: enough to tell "the key is missing" from "the key is wrong" in a log.
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "OPENAI_API_KEY loaded from the environment.");

    // Check if m_model string contains "mini" or "nano", if not, set m_rateLimit to true
    if (this->m_model.find("mini") == std::string::npos && this->m_model.find("nano") == std::string::npos)
    {
        this->m_rateLimit = true;
    }
}

std::string
LLMAgent::shellEscapeSingleQuotes(const std::string &str) {
    std::string out;
    out.reserve(str.size());
    for (char c : str)
    {
        if (c == '\'') 
        {
            out += "'\\''";
        }
        else 
        {
            out += c;
        }
    }
    return out;
}

std::string
LLMAgent::getLastMsgId(const std::string &sessionId) const 
{
    auto it = m_sessionIdToMsgMap.find(sessionId);
    if (it == m_sessionIdToMsgMap.end()) return "";

    for (auto msgIt = it->second.rbegin(); msgIt != it->second.rend(); ++msgIt)
        if (msgIt->first == LLMAgent::Role::AGENT)
            return msgIt->second["id"].get<std::string>();

    return "";
}

std::unique_ptr<llmResponse::LLMResponse>
LLMAgent::callOpenAIApi(
    const std::string &inputText,
    const std::string &sessionId)
{
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "callOpenAIApi: sessionId: {}", sessionId);
    std::string lastMsgId = this->getLastMsgId(sessionId);

    // std::string currentFlowEntries = this->getCurrentFlowEntries();
    // SPDLOG_LOGGER_DEBUG(Logger::instance(), "flow entries:\n{}\n", currentFlowEntries);

    std::ifstream in(m_systemPromptFilePath);
    std::string systemPrompt((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    json payload;

    std::string instructions = systemPrompt;
    // Check if this is the first message in the session (no previous message ID exists)
    // dont send topo every session
    if (lastMsgId.empty())
    {
        SPDLOG_LOGGER_INFO(Logger::instance(), "First message in session {}, sending topology.", sessionId);
        //instructions += this->getCurrentTopology(); // Append topology only for the first message
    }

    payload["model"] = this->m_model;
    payload["instructions"] = instructions; //+ this->getCurrentFlowEntries();
    payload["input"]  = inputText;
    // payload["reasoning"]["effort"] = "minimal";
    if (!lastMsgId.empty())
    {
        payload["previous_response_id"] = lastMsgId;
    }
    std::string data = payload.dump();

    SPDLOG_LOGGER_INFO(Logger::instance(), "httpsPost: send request to openai api.");

    auto start = Clock::now();
    std::string response;
    try
    {
        response = utils::httpsPost("https://api.openai.com/v1/responses", data, "application/json", "Bearer " + this->m_apiKey);
    }
    catch (const std::exception &e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Failed to call openai API: {}", e.what());
        return nullptr;
    }
    auto end = Clock::now();
    
    if (this->m_rateLimit)
    {
        // [Co-developed with claude code -- Adam]
        // One constant, because the message and the sleep disagreed: it announced 45 seconds and
        // slept 20. Both values entered this repo together in d6f7c01 and neither was ever
        // changed, so this was not a stale edit -- the line was wrong from the first commit that
        // contained it, and nothing noticed because the branch was unreachable until the model
        // parameter was wired through (IntentTranslator's constructor).
        //
        // Kept at 20 s, the only value that has ever executed. 45 has no evidence behind it, and
        // adopting it would have made every full-size-model call 2.25x slower on the strength of
        // a log line that was never true. If the real rate limit needs longer, change this
        // constant -- the message cannot drift from it again.
        constexpr auto kRateLimitPause = std::chrono::seconds(20);
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "Rate limit enabled for model {}, waiting for {} seconds.",
                           this->m_model,
                           kRateLimitPause.count());
        std::this_thread::sleep_for(kRateLimitPause);
    }
    int responseTimeMs = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
    SPDLOG_LOGGER_INFO(Logger::instance(), "Input{}, time{}", inputText, responseTimeMs );
    this->m_responseTime.push_back(responseTimeMs);
    json responseJson;
    try
    {
        responseJson = json::parse(response);
    }
    catch (const json::parse_error &e)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Failed to parse OpenAI API response: {}", e.what());
        return nullptr;
    }

    if (!responseJson["error"].is_null())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "OpenAI API error: {}", responseJson["error"].dump());
        return nullptr;
    }

    std::unique_ptr<llmResponse::LLMResponse> resPtr;
    int inputTokens = 0, outputTokens = 0;
    json resultJson;
    try {
        std::string result = responseJson["output"].back()["content"][0]["text"];
        SPDLOG_LOGGER_DEBUG(Logger::instance(), "OpenAI API response: {}", result);
        resultJson = json::parse(result);
        resPtr = resultJson;
        inputTokens = responseJson["usage"]["input_tokens"].get<int>();
        outputTokens = responseJson["usage"]["output_tokens"].get<int>();
        SPDLOG_LOGGER_INFO(Logger::instance(), 
            "OpenAI API usage: input token: {}, output token: {} (reasoning token: {}), used model: {}", 
            inputTokens,
            outputTokens,
            responseJson["usage"]["output_tokens_details"]["reasoning_tokens"].get<int>(),
            responseJson["model"].get<std::string>());
    }
    catch (const std::exception& e) {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Failed to parse OpenAI API response content: {}\n\n{}", e.what(), resultJson.dump());
        return nullptr;
    }

    this->m_sessionIdToMsgMap[sessionId].push_back( {LLMAgent::Role::USER, json{{"msg", inputText}}} );
    this->m_sessionIdToMsgMap[sessionId].push_back(
        {LLMAgent::Role::AGENT, json{
            {"id", responseJson["id"]},
            {"msg", resultJson}
        }});

    if (this->m_sessionTokensCount.find(sessionId) == this->m_sessionTokensCount.end())
    {
        this->m_sessionTokensCount[sessionId] = {inputTokens, outputTokens};
    }
    else
    {
        this->m_sessionTokensCount[sessionId].first += inputTokens;
        this->m_sessionTokensCount[sessionId].second += outputTokens;
    }

    return resPtr;
}

std::vector<std::pair<LLMAgent::Role, json>>
LLMAgent::getSessionMsgs(const std::string &sessionId)
{
    auto it = m_sessionIdToMsgMap.find(sessionId);
    if (it == m_sessionIdToMsgMap.end())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Session ID not found: {}", sessionId);
        return {};
    }
    return it->second;
}

std::string
LLMAgent::getCurrentTopology()
{
    std::string switchDescription, hostDescription, edgeDescription;
    int switchCnt = 0, hostCnt = 0, edgeCnt = 0;

    Graph graph = this->m_topologyAndFlowMonitor->getGraph();

    for (auto [vi, viEnd] = boost::vertices(graph); vi != viEnd; ++vi)
    {
        const auto& vprop = (graph)[*vi];
        if (vprop.vertexType == VertexType::SWITCH) {
            switchDescription += (vprop.deviceName + 
                "(administratively " + (vprop.isEnabled ? "up" : "down") + 
                ", powered " + (vprop.isUp ? "on" : "off") + "), "
            );
            switchCnt++;
        } else if (vprop.vertexType == VertexType::HOST) {
            std::string ip = utils::ipToString(vprop.ip[0]);
            hostDescription  += (vprop.deviceName + "(" + ip + "), ");
            hostCnt++;
        }
    }

    for (auto [ei, eiEnd] = boost::edges(graph); ei != eiEnd; ++ei)
    {
        const auto& eprop = (graph)[*ei];
        auto e = *ei;
        auto srcVd = boost::source(e, graph); auto src = graph[srcVd];
        auto targetVd = boost::target(e, graph); auto target = graph[targetVd];
        edgeDescription += (
            "(" + 
            (src.vertexType == VertexType::HOST ? src.deviceName : (src.deviceName + " port " + std::to_string(eprop.srcInterface))) + 
            ", " +
            (target.vertexType == VertexType::HOST ? target.deviceName : (target.deviceName + " port " + std::to_string(eprop.dstInterface))) +
            "), "
        );
        edgeCnt++;
    }

    switchDescription = "There are " + std::to_string(switchCnt) + " Openflow switches: " + switchDescription;
    hostDescription = "There are " + std::to_string(hostCnt) + " hosts: " + hostDescription;
    edgeDescription = "There are " + std::to_string(edgeCnt) + " links:\n " + edgeDescription;

    return "# Topology\n\n" + switchDescription + "\n" + hostDescription + "\n" + edgeDescription;
}

std::string
LLMAgent::getCurrentFlowEntries()
{
    json openflowTable = this->m_deviceConfigManager->getOpenFlowTables();
    
    std::string openflowTableStr;
    for (auto& switchTable: openflowTable)
    {
        openflowTableStr += ("dpid:" + std::to_string(switchTable["dpid"].get<int>()) + "\n");
        for (auto& entry: switchTable["flows"][std::to_string(switchTable["dpid"].get<int>())])
        {
            std::string action;
            if (entry["actions"].empty())
            {
                action = "DROP";
            }
            else
            {
                action = entry["actions"][0].get<std::string>();
            }

            json match = entry["match"];
            if (match.contains("dl_type"))
            {
                match.erase("dl_type");
            }

            std::string entryStr = fmt::format(
                "{} {} {}\n",
                match.dump(),
                action,
                entry["priority"].get<int>() == 10 ? "" : std::to_string(entry["priority"].get<int>())
            );

            openflowTableStr += entryStr;
        }
    }

    return "# Current Flow Entries\n\n"
           "Below are the openflow flow entry installed in each switch currently, \n"
           "if the priority is not specified, it is 10 by default.\n"
           "#legend: match action[:port] [priority]\n" + openflowTableStr + "\n";
}

void
LLMAgent::cleanSession(const std::string &sessionId)
{
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "cleanSession: sessionId: {}", sessionId);
    auto it = m_sessionIdToMsgMap.find(sessionId);
    if (it == m_sessionIdToMsgMap.end())
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(), "Session ID not found: {}", sessionId);
        return;
    }
    auto tokensIt = m_sessionTokensCount.find(sessionId);

    int agentRespondCount = it->second.size();
    for (const auto& msg : it->second)
        if (msg.first == LLMAgent::Role::USER) 
            agentRespondCount--;

    std::string respondTime;
    for (const auto& time : this->m_responseTime)
    {
        respondTime += std::to_string(time) + " ";
    }
    respondTime += "ms";

    SPDLOG_LOGGER_INFO(Logger::instance(), "Session {} agent respond count: {}", sessionId, agentRespondCount);
    SPDLOG_LOGGER_INFO(Logger::instance(), "Session {} total input tokens: {}, total output tokens: {}", 
        sessionId, tokensIt->second.first, tokensIt->second.second);
    SPDLOG_LOGGER_INFO(Logger::instance(), "Session {} response time: {}", sessionId, respondTime);

    m_sessionIdToMsgMap.erase(it);
    m_sessionTokensCount.erase(tokensIt);
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "finish cleanSession: sessionId: {}", sessionId);
}
