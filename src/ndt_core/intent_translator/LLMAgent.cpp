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

    std::ifstream in(m_systemPromptFilePath);
    std::string systemPrompt((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    json payload;

    std::string instructions = systemPrompt;
    // Check if this is the first message in the session (no previous message ID exists)
    // dont send topo every session
    if (lastMsgId.empty())
    {
        // [Co-developed with claude code -- Adam]
        // 🔴 THIS LINE USED TO SAY "sending topology" AND NO TOPOLOGY WAS EVER SENT.
        // doc/audit/2026-07-29_codebase-review/AUDIT_A_hallucinations.md:48-56 recorded it on
        // 2026-07-29 -- "The only line that would send topology is commented out; `instructions`
        // stays the bare system prompt" -- and it was still saying it on 2026-09-11, when the
        // member it named was deleted as dead code. Corrected on Adam's ruling of 2026-09-11.
        //
        // The three facts behind the wording, all of them still true of the line below:
        //   1. `instructions += this->getCurrentTopology();` has been a comment since d6f7c014
        //      (2025-12-15), so nothing appends a topology here;
        //   2. a whole-repo grep found no second caller, which is why the member was deleted;
        //   3. `instructions` is the bare contents of m_systemPromptFilePath, read above.
        // What IS true, and worth an INFO, is the branch itself: this is the first message of a
        // session, which is why no `previous_response_id` goes on the payload below.
        SPDLOG_LOGGER_INFO(Logger::instance(),
                           "First message in session {}; the instructions are the bare system "
                           "prompt and no topology is attached.",
                           sessionId);
    }

    payload["model"] = this->m_model;
    // [Co-developed with claude code -- Adam] 2026-09-11: the tail of this line was
    // `//+ this->getCurrentFlowEntries();`, a comment since d6f7c014 (2025-12-15) and the second
    // of that member's two dead call sites. The member was deleted with it.
    payload["instructions"] = instructions;
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

// [Co-developed with claude code -- Adam]
// LLMAgent::getCurrentFlowEntries stood here, ~40 lines of it, and was deleted on 2026-09-11.
//
// Both of its call sites were comments and had been since d6f7c014 (2025-12-15): the local
// `currentFlowEntries` in callOpenAIApi and the `//+ this->getCurrentFlowEntries();` tail on the
// `payload["instructions"]` line. It had no test, no mutation and no second caller anywhere in
// the repository. doc/audit/2026-07-29_codebase-review/AUDIT_A_hallucinations.md:56 named it with
// getCurrentTopology in July -- the pair were "dead code kept alive by the false log line" -- and
// that log line was corrected in the same change, so nothing is keeping this one alive either.
//
// What it did, for anyone bringing it back: it asked DeviceConfigurationAndPowerManager for
// getOpenFlowTables() and flattened them into a "# Current Flow Entries" markdown block for the
// LLM prompt, one `dpid:<n>` heading per switch and one `<match> <action> [priority]` line per
// entry, omitting priority when it was 10. Note that the reader it fed is the same one
// tests/python/test_t11_filter_is_wired.py:357 names: getOpenFlowTables() is the single read exit
// that applies stripUnprogrammedEntries, so a revived version gets B-1's phantom filter for free.

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
