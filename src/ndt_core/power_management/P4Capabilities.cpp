// [Co-developed with claude code -- Adam]
// See P4Capabilities.hpp for what this carries and why absence has to survive the trip.
#include "ndt_core/power_management/P4Capabilities.hpp"

#include "common_types/GraphTypes.hpp" // VertexProperties, VertexType

#include <limits>
#include <string>

namespace p4caps
{

// RED-FIRST STUB: the API exists so the tests compile; the behaviour does not.
CapabilitiesByDpid
fromSwitchState(const std::optional<nlohmann::json>& payload)
{
    (void)payload;
    return {};
}

void
attachToNode(nlohmann::json& node, const VertexProperties& vertex, const CapabilitiesByDpid& caps)
{
    (void)node;
    (void)vertex;
    (void)caps;
}

} // namespace p4caps
