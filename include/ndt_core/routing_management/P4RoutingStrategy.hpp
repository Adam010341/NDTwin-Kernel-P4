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

  protected:
    /**
     * @brief The proxy has one modify route, and it already compares priority.
     *
     * [Co-developed with claude code -- Adam]
     * The base class posts `modify_strict` because that is the only spelling in which Ryu's
     * ofctl_rest compares priority (doc/KNOWN-ISSUES.md A-4e). The proxy is not Ryu: it exposes
     * `/stats/flowentry/{add,delete,delete_strict,modify}` and nothing else, and its `modify`
     * reads `priority` from the body and uses it to identify the entry on the ternary five-tuple
     * table -- so the guarantee the strict route buys on OpenFlow is already the behaviour here.
     * Inheriting the base's path would post a route the proxy does not serve; the 404 would be
     * invisible to the caller, because the flow path answers 200 "queued" before the southbound
     * request is made.
     *
     * The alias route is the other way to settle this (delete_strict is exactly that alias on the
     * proxy side). It is not taken here because it would put the fix in a repo this one cannot
     * test against, to buy a wire spelling neither side needs.
     */
    const char* strictModifyPath() const override { return "/stats/flowentry/modify"; }
};
