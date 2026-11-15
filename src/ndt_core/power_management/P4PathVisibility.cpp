// [Co-developed with claude code -- Adam]
// See P4PathVisibility.hpp for what these keys mean and why the path itself is left alone.
#include "ndt_core/power_management/P4PathVisibility.hpp"

#include "common_types/GraphTypes.hpp" // VertexProperties, VertexType
#include "ndt_core/power_management/P4Capabilities.hpp"

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

        bool anyRecord = false;
        nlohmann::json unconfirmed = nlohmann::json::array();
        // Elements 1 .. size-2 are the switches; the two ends are hosts.
        for (std::size_t i = 1; i + 1 < path.size(); ++i)
        {
            const nlohmann::json& hop = path[i];
            if (!hop.is_object())
            {
                continue;
            }
            const auto nodeIt = hop.find("node");
            if (nodeIt == hop.end() || !nodeIt->is_number_integer() ||
                (!nodeIt->is_number_unsigned() && nodeIt->get<std::int64_t>() < 0))
            {
                continue;
            }
            const std::uint64_t dpid = nodeIt->get<std::uint64_t>();
            const auto record = stats.find(dpid);
            if (record == stats.end())
            {
                continue;
            }
            anyRecord = true;

            const auto countIt = record->second.find("unrendered_entries");
            const nlohmann::json count =
                countIt == record->second.end() ? nlohmann::json(nullptr) : *countIt;
            // 0 is the only value that says "nothing left out". null is "not rendered yet", which
            // is not a zero, and anything else is the proxy's own number.
            if (count.is_number_integer() && count.get<std::int64_t>() == 0)
            {
                continue;
            }
            unconfirmed.push_back({{"dpid", dpid}, {"unrendered_entries", count}});
        }
        if (anyRecord)
        {
            row["path_unconfirmed_at"] = std::move(unconfirmed);
        }
    }
}

} // namespace p4paths
