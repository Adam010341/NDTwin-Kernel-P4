// [Co-developed with claude code -- Adam]
// See P4PathVisibility.hpp for what these keys mean and why the path itself is left alone.
#include "ndt_core/power_management/P4PathVisibility.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>

#include "common_types/GraphTypes.hpp" // VertexProperties, VertexType
#include "ndt_core/power_management/P4Capabilities.hpp"

namespace
{

/// A JSON integer that fits an unsigned 64-bit value, else nothing.
std::optional<std::uint64_t>
unsignedOf(const nlohmann::json& value)
{
    if (!value.is_number_integer() || (!value.is_number_unsigned() && value.get<std::int64_t>() < 0))
    {
        return std::nullopt;
    }
    return value.get<std::uint64_t>();
}

/// True when the row's @p key holds exactly the integer @p expected.
bool
holds(const nlohmann::json& row, const char* key, std::uint64_t expected)
{
    const auto it = row.find(key);
    if (it == row.end())
    {
        return false;
    }
    const std::optional<std::uint64_t> value = unsignedOf(*it);
    return value.has_value() && *value == expected;
}

/// True when the path element's `interface` is the integer 0, which is how the walk writes the
/// destination host (the host has no egress port).
bool
interfaceIsZero(const nlohmann::json& hop)
{
    const auto it = hop.find("interface");
    return it != hop.end() && unsignedOf(*it).value_or(1) == 0;
}

} // namespace

namespace p4paths
{

FlowStatsByDpid
fromSwitchState(const std::optional<nlohmann::json>& payload)
{
    return p4caps::objectsUnder(payload, "flow_stats");
}

void
attachToNode(nlohmann::json& node, const VertexProperties& vertex, const FlowStatsByDpid& stats)
{
    if (vertex.vertexType != VertexType::SWITCH)
    {
        return;
    }
    const auto it = stats.find(vertex.dpid);
    if (it == stats.end())
    {
        return;
    }
    node["flow_stats"] = it->second;
}

void
annotateFlowRows(nlohmann::json& rows, const FlowStatsByDpid& stats)
{
    if (!rows.is_array() || stats.empty())
    {
        return;
    }
    for (nlohmann::json& row : rows)
    {
        if (!row.is_object())
        {
            continue;
        }
        const auto pathIt = row.find("path");
        if (pathIt == row.end() || !pathIt->is_array())
        {
            continue;
        }
        const nlohmann::json& path = *pathIt;

        bool anySwitch = false;
        nlohmann::json unconfirmed = nlohmann::json::array();
        for (std::size_t i = 0; i < path.size(); ++i)
        {
            const nlohmann::json& hop = path[i];
            if (!hop.is_object())
            {
                continue;
            }
            const auto nodeIt = hop.find("node");
            if (nodeIt == hop.end())
            {
                continue;
            }
            const std::optional<std::uint64_t> node = unsignedOf(*nodeIt);
            if (!node.has_value())
            {
                continue;
            }
            const std::uint64_t dpid = *node;

            // The walk starts at the source host and, when it reaches the destination host,
            // ends there with interface 0. A path the walk could not finish ends at a switch.
            // An element is a host only when it is the one the row's own address names; anything
            // else is scanned like a switch, so a path that stops short never loses its last one.
            const bool isSource = i == 0 && holds(row, "src_ip", dpid);
            const bool isDestination = i != 0 && i + 1 == path.size() &&
                                       holds(row, "dst_ip", dpid) && interfaceIsZero(hop);
            if (isSource || isDestination)
            {
                continue;
            }
            anySwitch = true;

            const auto record = stats.find(dpid);
            if (record == stats.end())
            {
                // Other switches have a record and this one has none: nobody said it hides
                // nothing, so it is listed as unconfirmed, with a null count.
                unconfirmed.push_back({{"dpid", dpid}, {"unrendered_entries", nullptr}});
                continue;
            }

            const auto countIt = record->second.find("unrendered_entries");
            const nlohmann::json count =
                countIt == record->second.end() ? nlohmann::json(nullptr) : *countIt;
            // 0 is the only value that says "left out no row I count". null is "not rendered
            // yet", which is not a zero, and anything else is the proxy's own number.
            if (count.is_number_integer() && count.get<std::int64_t>() == 0)
            {
                continue;
            }
            unconfirmed.push_back({{"dpid", dpid}, {"unrendered_entries", count}});
        }
        if (anySwitch)
        {
            row["path_unconfirmed_at"] = std::move(unconfirmed);
        }
    }
}

} // namespace p4paths
