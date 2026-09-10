#pragma once
#include <nlohmann/json.hpp>
#include <map>
#include <vector>

#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "ndt_core/intent_translator/LLMResponseTypes.hpp"

using json = nlohmann::json;

class LLMAgent
{
    public:
        enum Role : bool {
            USER = true,
            AGENT = false
        };
        LLMAgent(
            std::string systemPromptFilePath,
            std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
            std::shared_ptr<DeviceConfigurationAndPowerManager> deviceConfigurationAndPowerManager,
            std::string model
        );
        std::unique_ptr<llmResponse::LLMResponse> callOpenAIApi(const std::string &inputText, const std::string &sessionId);
        std::vector<std::pair<Role, json>> getSessionMsgs(const std::string &sessionId);
        void addMsgToSession(const std::string &sessionId, Role role, const json &msg);
        void cleanSession(const std::string &sessionId);

    private:
        // [Co-developed with claude code -- Adam]
        // FINDINGS #88, W14 site 5 (D3) lived here: `std::string getCurrentTopology();`, plus a
        // `friend class AddresslessTopologyPeer;` test seam for it. Both were deleted on
        // 2026-09-11 because the member was dead code -- its only caller, in callOpenAIApi, has
        // been commented out since d6f7c014 (2025-12-15). See
        // doc/audit/2026-09-06_fix-index-zero-guards/FIX-INDEX-ZERO-GUARDS.md section 7.
        std::string shellEscapeSingleQuotes(const std::string &str);
        std::string getLastMsgId(const std::string &sessionId) const;
        std::string getCurrentFlowEntries();

        std::string m_systemPromptFilePath;
        std::shared_ptr<TopologyAndFlowMonitor> m_topologyAndFlowMonitor;
        std::shared_ptr<DeviceConfigurationAndPowerManager> m_deviceConfigManager;
        std::string m_model;
        std::string m_apiKey;
        std::map<std::string, std::vector<std::pair<Role, json>>> m_sessionIdToMsgMap;
        std::map<std::string, std::pair<int, int>> m_sessionTokensCount; // session id -> {input tokens, output tokens}
        std::vector<int> m_responseTime;
        bool m_rateLimit = false;
};