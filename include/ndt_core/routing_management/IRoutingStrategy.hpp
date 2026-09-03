// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- OpResult returns, const& parameters.
#pragma once

#include "ndt_core/routing_management/OpResult.hpp"
#include <nlohmann/json.hpp>
#include <stdint.h>

/**
 * @brief Strategy interface for routing and forwarding changes.
 *
 * This interface abstracts the underlying control plane API (e.g., Ryu REST API
 * vs. P4 Proxy API). The FlowRoutingManager will hold a strategy and forward
 * the rule installation/deletion requests to it.
 *
 * Two things changed from the original shape, both about being able to tell whether an
 * operation worked:
 *
 * 1. Every method returned void, so failures had nowhere to go. They now return OpResult.
 *
 * 2. The json parameters were taken by value, copying every match and action object once
 *    more per entry on a path that batches 2000 at a time, for no reason -- no
 *    implementation mutates them. They are now const references.
 *
 * The default arguments that used to sit on these pure virtuals were removed as well.
 * Default arguments on virtual functions bind to the *static* type of the pointer, so a
 * derived class silently changing one would make the value depend on how the object was
 * referred to. They live on FlowRoutingManager's public API instead, which is where callers
 * actually see them.
 */
class IRoutingStrategy
{
  public:
    virtual ~IRoutingStrategy() = default;

    virtual OpResult deleteAnEntry(uint64_t dpid,
                                   const nlohmann::json& match,
                                   int priority) = 0;
    virtual OpResult installAnEntry(uint64_t dpid,
                                    int priority,
                                    const nlohmann::json& match,
                                    const nlohmann::json& action,
                                    int idleTimeout) = 0;
    virtual OpResult modifyAnEntry(uint64_t dpid,
                                   int priority,
                                   const nlohmann::json& match,
                                   const nlohmann::json& action) = 0;

    virtual OpResult installAGroupEntry(const nlohmann::json& j) = 0;
    virtual OpResult deleteAGroupEntry(const nlohmann::json& j) = 0;
    virtual OpResult modifyAGroupEntry(const nlohmann::json& j) = 0;

    virtual OpResult installAMeterEntry(const nlohmann::json& j) = 0;
    virtual OpResult deleteAMeterEntry(const nlohmann::json& j) = 0;
    virtual OpResult modifyAMeterEntry(const nlohmann::json& j) = 0;

    /**
     * @brief Whether a successful answer from this control plane is evidence that a switch
     *        programmed the rule.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md C-4. The two planes answer the same route with the same status code and
     * mean different things by it, and until this question was asked the kernel could not tell
     * them apart: DispatchOutcomeLog stamped a flow entry as programmed on any 200, so on OVS the
     * optimistic cache row was served 0.257 s after the POST while the polled row arrived at 13.4 s.
     *
     * Pure virtual on purpose. A default would be a guess made once, here, on behalf of every
     * control plane added later -- and it fails silently in both directions: guess true and the
     * phantom comes back, guess false and real entries vanish for a poll interval. A new plane has
     * to answer for itself.
     */
    virtual bool successConfirmsProgramming() const = 0;

    /// Name of the control plane this strategy talks to, for log messages.
    virtual const char* describe() const = 0;
};
