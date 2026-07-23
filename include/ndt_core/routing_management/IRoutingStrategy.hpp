// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#pragma once

#include <nlohmann/json.hpp>
#include <stdint.h>

/**
 * @brief Strategy interface for routing and forwarding changes.
 * 
 * This interface abstracts the underlying control plane API (e.g., Ryu REST API 
 * vs. P4 Proxy API). The FlowRoutingManager will hold a strategy and forward
 * the rule installation/deletion requests to it.
 */
class IRoutingStrategy
{
  public:
    virtual ~IRoutingStrategy() = default;

    virtual void deleteAnEntry(uint64_t dpid, nlohmann::json match, int priority = -1) = 0;
    virtual void installAnEntry(uint64_t dpid, int priority, nlohmann::json match, nlohmann::json action, int idleTimeout = 0) = 0;
    virtual void modifyAnEntry(uint64_t dpid, int priority, nlohmann::json match, nlohmann::json action) = 0;

    virtual void installAGroupEntry(nlohmann::json j) = 0;
    virtual void deleteAGroupEntry(nlohmann::json j) = 0;
    virtual void modifyAGroupEntry(nlohmann::json j) = 0;

    virtual void installAMeterEntry(nlohmann::json j) = 0;
    virtual void deleteAMeterEntry(nlohmann::json j) = 0;
    virtual void modifyAMeterEntry(nlohmann::json j) = 0;
};
