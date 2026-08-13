// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam] -- collapsed onto HttpRoutingStrategyBase,
// and now declares what bmv2 cannot do instead of pretending it can.
#pragma once

#include "ndt_core/routing_management/HttpRoutingStrategyBase.hpp"
#include <string>

/**
 * @brief Routing strategy for P4/bmv2 switches, via the P4 proxy agent.
 *
 * The proxy agent deliberately impersonates Ryu's northbound API so NDTwin applications need
 * no changes, which is why the request construction is shared with the OpenFlow strategy
 * rather than duplicated. The previous version took that to an extreme: it was a byte-for-byte
 * copy of the OpenFlow strategy, so it advertised group and meter support that neither the
 * proxy nor a bmv2 pipeline has.
 *
 * Group and meter entries are now refused explicitly. P4 has no OpenFlow group or meter
 * concept -- the equivalents would be an ActionSelector and direct/indirect meters, which the
 * proxy does not implement -- so posting to those routes previously produced a silent 404 that
 * nothing observed. Reporting "unsupported" tells the caller the truth, and Phase 4 of
 * doc/2026-07-27_p4_bmv2_support_plan.md is where the P4 pipeline grows an ECMP selector.
 */
class P4RoutingStrategy : public HttpRoutingStrategyBase
{
  public:
    explicit P4RoutingStrategy(const std::string& apiUrl)
        : HttpRoutingStrategyBase(apiUrl)
    {
    }

    const char* describe() const override { return "P4 proxy agent"; }

    OpResult installAGroupEntry(const nlohmann::json& j) override;
    OpResult deleteAGroupEntry(const nlohmann::json& j) override;
    OpResult modifyAGroupEntry(const nlohmann::json& j) override;

    OpResult installAMeterEntry(const nlohmann::json& j) override;
    OpResult deleteAMeterEntry(const nlohmann::json& j) override;
    OpResult modifyAMeterEntry(const nlohmann::json& j) override;
};
