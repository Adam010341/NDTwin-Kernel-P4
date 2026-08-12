#pragma once
#include <nlohmann/json.hpp>
#include <string>
#include <map>
#include "ndt_core/intent_translator/LLMAgent.hpp"
#include "ndt_core/intent_translator/LLMResponseTypes.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

using json = nlohmann::json;

class IntentTranslator
{
    public:
        IntentTranslator(
            std::shared_ptr<DeviceConfigurationAndPowerManager> deviceConfigManager,
            std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
            std::shared_ptr<FlowRoutingManager> flowRoutingManager,
            std::shared_ptr<sflow::FlowLinkUsageCollector> flowUsageCollector,
            std::string openaiModel
        );
        std::unique_ptr<llmResponse::LLMResponse> inputTextIntent(std::string inputText, const std::string &sessionId);
        void cleanSession(const std::string &sessionId);

        /**
         * @brief The reply for an intent naming a device the topology does not have.
         *
         * [Co-developed with claude code -- Adam]
         * Extracted rather than inlined so the shape of a refusal is one thing that can be
         * asserted on, in the manner of interpretRelayResponse and ovsLivenessFor. The
         * POWEROFF/POWERON/INSTALL/MODIFY/DELETE cases used to skip their operation entirely
         * when the name did not resolve -- no else, no return -- and fall through to "ok".
         */
        static std::string switchNotFoundReply(const std::string &deviceName);

        /**
         * @brief The reply for a power operation, carrying whether it actually happened.
         *
         * @param ok     What setSwitchPowerState returned. It was previously discarded.
         * @param action "on" or "off".
         */
        static std::string powerReply(bool ok, const std::string &action, const std::string &deviceName);

        /**
         * @brief The reply for a flow-table operation, carrying the OpResult's own verdict.
         *
         * @details OpResult already distinguishes "the controller said no" (httpStatus 4xx/5xx)
         * from "the controller is not there" (httpStatus 0), and both were being dropped on the
         * floor. Both reach the caller here.
         */
        static std::string flowReply(const OpResult &result,
                                     const std::string &operation,
                                     const std::string &deviceName);

    private:
        // [Co-developed with claude code -- Adam]
        // Test seam. tests/test_IntentTaskOutcomes.cpp calls performTask directly with a real
        // FlowRoutingManager double and a real topology, because the reply renderers being
        // correct in isolation would not show that performTask actually calls them -- and
        // "returns ok regardless" was exactly a wiring bug, not a rendering one.
        friend class IntentTranslatorTestPeer;

        json performAgentsNegotiation(const std::string &sessionId);
        std::string performTask(llmResponse::Task* task);
        optional<std::string> getSwitchIpByName(const std::string &switchName);

        /**
         * @brief The dpid registered for a switch IP, or nullopt if the map has never seen it.
         *
         * [Co-developed with claude code -- Adam]
         * Exists so the lookup cannot be written with operator[] again. On a std::map that
         * default-constructs the missing key and *inserts* it, so reading an unknown IP both
         * answered dpid 0 -- installing the rule on a switch that does not exist instead of
         * reporting the bad name -- and mutated the map from an HTTP thread. The kernel serves
         * requests on hardware_concurrency() threads, so two of those at once were a concurrent
         * std::map insertion, which is undefined behaviour rather than a stale read.
         */
        optional<uint64_t> dpidForSwitchIp(const std::string &switchIp) const;

        std::shared_ptr<DeviceConfigurationAndPowerManager> m_deviceConfigManager;
        std::shared_ptr<TopologyAndFlowMonitor> m_topologyAndFlowMonitor;
        std::shared_ptr<FlowRoutingManager> m_flowRoutingManager;
        std::shared_ptr<sflow::FlowLinkUsageCollector> m_flowLinkUsageCollector;
        std::shared_ptr<LLMAgent> m_answerAgent;
        std::string m_answerAgentPromptFilePath = "../src/ndt_core/intent_translator/answer_agent_prompt.txt";
        std::shared_ptr<LLMAgent> m_validationAgent;
        std::string m_validationAgentPromptFilePath = "../src/ndt_core/intent_translator/validation_agent_prompt.txt";
        
        std::optional<nlohmann::json> getFlowEntriesForSwitch(const std::string& deviceName);
};