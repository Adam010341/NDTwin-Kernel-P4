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
#include <functional>
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

// [Co-developed with claude code -- Adam]
// The three flow methods share the same shape: resolve the strategy, refuse if the dpid is
// not routable, delegate, and hand the outcome back to the caller instead of discarding it.
OpResult
FlowRoutingManager::deleteAnEntry(uint64_t dpid, const json& match, int priority)
{
    IRoutingStrategy* strategy = getStrategyForDpid(dpid);
    if (strategy == nullptr)
    {
        // getStrategyForDpid already logged why.
        return OpResult::failure(404, "no routing strategy for dpid " + std::to_string(dpid));
    }
    return strategy->deleteAnEntry(dpid, match, priority);
}

OpResult
FlowRoutingManager::installAnEntry(uint64_t dpid,
                                   int priority,
                                   const json& match,
                                   const json& action,
                                   int idleTimeout)
{
    IRoutingStrategy* strategy = getStrategyForDpid(dpid);
    if (strategy == nullptr)
    {
        return OpResult::failure(404, "no routing strategy for dpid " + std::to_string(dpid));
    }
    return strategy->installAnEntry(dpid, priority, match, action, idleTimeout);
}

OpResult
FlowRoutingManager::modifyAnEntry(uint64_t dpid, int priority, const json& match, const json& action)
{
    IRoutingStrategy* strategy = getStrategyForDpid(dpid);
    if (strategy == nullptr)
    {
        return OpResult::failure(404, "no routing strategy for dpid " + std::to_string(dpid));
    }
    return strategy->modifyAnEntry(dpid, priority, match, action);
}

// --- group and meter entries -------------------------------------------------------
//
// [Co-developed with claude code -- Adam]
// These used to go to m_ovsStrategy unconditionally, with a comment claiming that "global
// commands that don't specify DPID go to OVS by default". The comment was wrong: Ryu's
// /stats/groupentry and /stats/meterentry schemas both require a dpid, and HttpSession
// forwards the REST body verbatim, so the dpid is right there in the payload. The effect was
// that a group or meter operation aimed at a bmv2 switch went to Ryu -- where, in a mixed
// fabric, it could even land on a different switch that happened to share the dpid.
//
// Now dispatched per-DPID like everything else, which also means the P4 strategy gets to
// refuse them explicitly rather than having them silently succeed against the wrong target.

OpResult
FlowRoutingManager::dispatchByPayloadDpid(const json& j,
                                          const char* operation,
                                          StrategyCall call)
{
    if (!j.contains("dpid"))
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} rejected: payload has no dpid, so the target switch is unknown",
                           operation);
        return OpResult::failure(400, std::string(operation) + " requires a dpid");
    }

    uint64_t dpid = 0;
    try
    {
        dpid = j.at("dpid").get<uint64_t>();
    }
    catch (const json::exception& e)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} rejected: bad dpid: {}", operation, e.what());
        return OpResult::failure(400, std::string(operation) + " has an unreadable dpid");
    }

    IRoutingStrategy* strategy = getStrategyForDpid(dpid);
    if (strategy == nullptr)
    {
        return OpResult::failure(404, "no routing strategy for dpid " + std::to_string(dpid));
    }

    OpResult result = call(*strategy, j);
    if (!result.ok)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} on dpid {} failed: {}",
                           operation,
                           dpid,
                           result.message);
    }
    return result;
}

OpResult
FlowRoutingManager::installAGroupEntry(const json& j)
{
    return dispatchByPayloadDpid(j, "install group entry",
        [](IRoutingStrategy& s, const json& body) { return s.installAGroupEntry(body); });
}

OpResult
FlowRoutingManager::deleteAGroupEntry(const json& j)
{
    return dispatchByPayloadDpid(j, "delete group entry",
        [](IRoutingStrategy& s, const json& body) { return s.deleteAGroupEntry(body); });
}

OpResult
FlowRoutingManager::modifyAGroupEntry(const json& j)
{
    return dispatchByPayloadDpid(j, "modify group entry",
        [](IRoutingStrategy& s, const json& body) { return s.modifyAGroupEntry(body); });
}

OpResult
FlowRoutingManager::installAMeterEntry(const json& j)
{
    return dispatchByPayloadDpid(j, "install meter entry",
        [](IRoutingStrategy& s, const json& body) { return s.installAMeterEntry(body); });
}

OpResult
FlowRoutingManager::deleteAMeterEntry(const json& j)
{
    return dispatchByPayloadDpid(j, "delete meter entry",
        [](IRoutingStrategy& s, const json& body) { return s.deleteAMeterEntry(body); });
}

OpResult
FlowRoutingManager::modifyAMeterEntry(const json& j)
{
    return dispatchByPayloadDpid(j, "modify meter entry",
        [](IRoutingStrategy& s, const json& body) { return s.modifyAMeterEntry(body); });
}
