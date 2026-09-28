// [Co-developed with claude code -- Adam]
// See P4Capabilities.hpp for what this carries and why absence has to survive the trip.
#include "ndt_core/power_management/P4Capabilities.hpp"

#include "common_types/GraphTypes.hpp" // VertexProperties, VertexType

#include <limits>
#include <string>

namespace p4caps
{

namespace
{

/// The dpid a `switches` key names, or nullopt when the key is not a plain decimal number that
/// fits in 64 bits. Hand-rolled rather than std::stoull, which accepts leading whitespace, a sign
/// and trailing junk -- "+3", " 3" and "3x" would all have named switch 3.
std::optional<std::uint64_t>
dpidFromKey(const std::string& key)
{
    if (key.empty())
    {
        return std::nullopt;
    }
    constexpr std::uint64_t kMax = std::numeric_limits<std::uint64_t>::max();
    std::uint64_t value = 0;
    for (const char c : key)
    {
        if (c < '0' || c > '9')
        {
            return std::nullopt;
        }
        const auto digit = static_cast<std::uint64_t>(c - '0');
        if (value > (kMax - digit) / 10)
        {
            return std::nullopt;
        }
        value = value * 10 + digit;
    }
    return value;
}

} // namespace

CapabilitiesByDpid
fromSwitchState(const std::optional<nlohmann::json>& payload)
{
    CapabilitiesByDpid out;
    if (!payload.has_value() || !payload->is_object())
    {
        return out;
    }
    const auto switchesIt = payload->find("switches");
    if (switchesIt == payload->end() || !switchesIt->is_object())
    {
        return out;
    }
    for (const auto& item : switchesIt->items())
    {
        const auto dpid = dpidFromKey(item.key());
        const nlohmann::json& entry = item.value();
        if (!dpid.has_value() || !entry.is_object())
        {
            continue;
        }
        const auto capsIt = entry.find("capabilities");
        // Only an object is a description. `null` is what the proxy serves for a switch it has
        // recorded nothing for (api_routes.py: `caps.get(str(dpid))`), and it must read the same
        // as the key being absent -- "nobody said", never "supports nothing".
        if (capsIt == entry.end() || !capsIt->is_object())
        {
            continue;
        }
        out.emplace(*dpid, *capsIt);
    }
    return out;
}

void
attachToNode(nlohmann::json& node, const VertexProperties& vertex, const CapabilitiesByDpid& caps)
{
    if (vertex.vertexType != VertexType::SWITCH)
    {
        return;
    }
    const auto it = caps.find(vertex.dpid);
    if (it == caps.end())
    {
        return;
    }
    node["capabilities"] = it->second;
}

} // namespace p4caps
