// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
// [Co-developed with claude code -- Adam]
#include "ndt_core/routing_management/P4RoutingStrategy.hpp"

using json = nlohmann::json;

namespace
{

/// Shared explanation, so all six refusals say the same thing for the same reason.
OpResult
refuse(const char* what)
{
    return OpResult::unsupported(
        std::string(what) + " is not supported on a P4/bmv2 data plane: OpenFlow groups and "
        "meters have no direct equivalent, the P4 proxy agent implements no such route, and "
        "the pipeline has no ActionSelector yet (Phase 4). Previously this was POSTed to a "
        "nonexistent proxy route and the 404 went unnoticed.");
}

} // namespace

OpResult P4RoutingStrategy::installAGroupEntry(const json&) { return refuse("group entry install"); }
OpResult P4RoutingStrategy::deleteAGroupEntry(const json&)  { return refuse("group entry delete"); }
OpResult P4RoutingStrategy::modifyAGroupEntry(const json&)  { return refuse("group entry modify"); }

OpResult P4RoutingStrategy::installAMeterEntry(const json&) { return refuse("meter entry install"); }
OpResult P4RoutingStrategy::deleteAMeterEntry(const json&)  { return refuse("meter entry delete"); }
OpResult P4RoutingStrategy::modifyAMeterEntry(const json&)  { return refuse("meter entry modify"); }
