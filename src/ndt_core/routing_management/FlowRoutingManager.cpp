#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "event_system/EventBus.hpp"                      // for Event
#include "event_system/EventPayloads.hpp"                 // for FlowAd...
#include "event_system/PayloadTypes.hpp"                  // for FlowAd...
#include "ndt_core/collection/FlowLinkUsageCollector.hpp" // for FlowLi...
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp" // for Topolo...
#include "nlohmann/json.hpp"                              // for basic_...
#include "spdlog/spdlog.h"                                // for SPDLOG...
#include "utils/Logger.hpp"                               // for Logger
#include "utils/Utils.hpp"                                // for ipToSt...
#include <any>                                            // for any_cast
#include <functional>                                     // for function
#include <sstream>                                        // for basic_...
#include <stddef.h>                                       // for size_t
#include <unordered_map>                                  // for unorde...
#include <utility>                                        // for pair
#include <vector>                                         // for vector
#include "../setting/AppConfig.hpp"                       // for AppConfig::RYU_IP_AND_PORT

// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#include "ndt_core/routing_management/OpenFlowRoutingStrategy.hpp"
#include "ndt_core/routing_management/P4RoutingStrategy.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"

using json = nlohmann::json;

FlowRoutingManager::FlowRoutingManager(
    std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
    std::shared_ptr<sflow::FlowLinkUsageCollector> collector,
    std::shared_ptr<EventBus> eventBus)
{
    m_topologyAndFlowMonitor = std::move(topologyAndFlowMonitor);
    m_flowLinkUsageCollector = std::move(collector);
    m_eventBus = std::move(eventBus);

    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    // Initialize with both OpenFlow Strategy (pointing to Ryu) and P4 Strategy (pointing to Proxy Agent)
    m_ovsStrategy = std::make_unique<OpenFlowRoutingStrategy>(AppConfig::RYU_IP_AND_PORT);
    m_p4Strategy = std::make_unique<P4RoutingStrategy>(AppConfig::P4_PROXY_IP_AND_PORT);
}

FlowRoutingManager::~FlowRoutingManager()
{
}

IRoutingStrategy* FlowRoutingManager::getStrategyForDpid(uint64_t dpid)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    // Use the topology monitor to check if the switch is BMv2
    if (m_topologyAndFlowMonitor)
    {
        auto switchNode = m_topologyAndFlowMonitor->findSwitchByDpid(dpid);
        if (switchNode.has_value())
        {
            Graph g = m_topologyAndFlowMonitor->getGraph();
            auto props = g[switchNode.value()];
            if (props.brandName == "BMv2")
            {
                return m_p4Strategy.get();
            }
        }
    }
    // Default to OVS/Ryu if not found or not BMv2
    return m_ovsStrategy.get();
}

void
FlowRoutingManager::deleteAnEntry(uint64_t dpid, json match, int priority)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    getStrategyForDpid(dpid)->deleteAnEntry(dpid, match, priority);
}

void
FlowRoutingManager::installAnEntry(uint64_t dpid,
                                   int priority,
                                   json match,
                                   json action,
                                   int idleTimeout)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    getStrategyForDpid(dpid)->installAnEntry(dpid, priority, match, action, idleTimeout);
}

void
FlowRoutingManager::modifyAnEntry(uint64_t dpid, int priority, json match, json action)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    getStrategyForDpid(dpid)->modifyAnEntry(dpid, priority, match, action);
}

void
FlowRoutingManager::installAGroupEntry(json j)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    // Global/group commands that don't specify DPID go to OVS by default for now
    m_ovsStrategy->installAGroupEntry(j);
}

void
FlowRoutingManager::deleteAGroupEntry(json j)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    m_ovsStrategy->deleteAGroupEntry(j);
}

void
FlowRoutingManager::modifyAGroupEntry(json j)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    m_ovsStrategy->modifyAGroupEntry(j);
}

void
FlowRoutingManager::installAMeterEntry(json j)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    m_ovsStrategy->installAMeterEntry(j);
}

void
FlowRoutingManager::deleteAMeterEntry(json j)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    m_ovsStrategy->deleteAMeterEntry(j);
}

void
FlowRoutingManager::modifyAMeterEntry(json j)
{
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    m_ovsStrategy->modifyAMeterEntry(j);
}