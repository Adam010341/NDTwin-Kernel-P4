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

// [Co-developed with claude code -- Adam]
//
// Was: findSwitchByDpid() (O(V) scan under the graph lock) followed by getGraph(), which
// deep-copies the entire BGL graph -- every vertex's strings, ip vector and ecmp groups --
// and then copied VertexProperties a third time. That ran once per flow entry, from one
// worker thread per DPID, so a 2000-entry burst meant 2000 full graph copies while
// starving every graph writer. Now a single O(1) hash lookup returning a 4-byte enum.
//
// Also no longer defaults to OVS on an unknown dpid. That silently sent P4 rules to Ryu
// (where they vanish) for a mistyped dpid, a switch missing from the topology file, or a
// null monitor -- with no log line at all. Returning nullptr forces the caller to report.
IRoutingStrategy*
FlowRoutingManager::getStrategyForDpid(uint64_t dpid)
{
    if (!m_topologyAndFlowMonitor)
    {
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "No topology monitor available; cannot route dpid {}",
                            dpid);
        return nullptr;
    }

    const auto kind = m_topologyAndFlowMonitor->getSwitchKind(dpid);
    if (!kind.has_value())
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "dpid {} is not a switch in the loaded topology; refusing to "
                           "guess a data plane. Check the dpid, or that the topology file "
                           "matches the running network.",
                           dpid);
        return nullptr;
    }

    switch (*kind)
    {
    case SwitchKind::BMV2:
        return m_p4Strategy.get();
    case SwitchKind::OVS:
    case SwitchKind::HARDWARE:
        // Hardware switches are OpenFlow too, so they share the Ryu-facing strategy.
        return m_ovsStrategy.get();
    }

    SPDLOG_LOGGER_ERROR(Logger::instance(),
                        "dpid {} has an unhandled switch kind; this is a bug",
                        dpid);
    return nullptr;
}

void
FlowRoutingManager::deleteAnEntry(uint64_t dpid, json match, int priority)
{
    // [Co-developed with claude code -- Adam]
    // getStrategyForDpid now returns nullptr for an unroutable dpid rather than silently
    // falling back to Ryu, so every caller must check. The warning is logged there.
    IRoutingStrategy* strategy = getStrategyForDpid(dpid);
    if (strategy == nullptr)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Dropping flow delete for dpid {}", dpid);
        return;
    }
    strategy->deleteAnEntry(dpid, match, priority);
}

void
FlowRoutingManager::installAnEntry(uint64_t dpid,
                                   int priority,
                                   json match,
                                   json action,
                                   int idleTimeout)
{
    // [Co-developed with claude code -- Adam]
    IRoutingStrategy* strategy = getStrategyForDpid(dpid);
    if (strategy == nullptr)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Dropping flow install for dpid {}", dpid);
        return;
    }
    strategy->installAnEntry(dpid, priority, match, action, idleTimeout);
}

void
FlowRoutingManager::modifyAnEntry(uint64_t dpid, int priority, json match, json action)
{
    // [Co-developed with claude code -- Adam]
    IRoutingStrategy* strategy = getStrategyForDpid(dpid);
    if (strategy == nullptr)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "Dropping flow modify for dpid {}", dpid);
        return;
    }
    strategy->modifyAnEntry(dpid, priority, match, action);
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