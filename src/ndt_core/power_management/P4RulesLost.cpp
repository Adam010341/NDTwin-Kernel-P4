// [Co-developed with claude code -- Adam]
// See P4RulesLost.hpp for what this carries and why nothing is replayed.
#include "ndt_core/power_management/P4RulesLost.hpp"

#include "common_types/GraphTypes.hpp" // VertexProperties, VertexType
#include "ndt_core/power_management/P4Capabilities.hpp"

namespace p4loss
{

namespace
{

/// A JSON integer >= 0, or nullopt.
std::optional<std::int64_t>
nonNegative(const nlohmann::json& record, const char* key)
{
    const auto it = record.find(key);
    if (it == record.end() || !it->is_number_integer())
    {
        return std::nullopt;
    }
    const auto value = it->get<std::int64_t>();
    if (value < 0)
    {
        return std::nullopt;
    }
    return value;
}

} // namespace

RecordsByDpid
fromSwitchState(const std::optional<nlohmann::json>& payload)
{
    return p4caps::objectsUnder(payload, "ryu_rules_lost");
}

std::vector<Announcement>
Announcer::observe(const RecordsByDpid& records)
{
    std::vector<Announcement> out;
    for (const auto& [dpid, record] : records)
    {
        const auto idIt = record.find("id");
        if (idIt == record.end() || !idIt->is_string() || idIt->get<std::string>().empty())
        {
            continue;
        }
        const std::string id = idIt->get<std::string>();
        if (!m_seen.insert(id).second)
        {
            continue;
        }
        Announcement a;
        a.dpid = dpid;
        a.id = id;
        const auto causeIt = record.find("cause");
        a.cause = (causeIt != record.end() && causeIt->is_string()) ? causeIt->get<std::string>()
                                                                     : "pipeline push";
        a.count = nonNegative(record, "count");
        const auto whyIt = record.find("count_unknown");
        if (whyIt != record.end() && whyIt->is_string())
        {
            a.countUnknown = whyIt->get<std::string>();
        }
        a.unreadable = nonNegative(record, "journal_unreadable").value_or(0);
        a.writeFailures = nonNegative(record, "journal_write_failures").value_or(0);
        if (a.count.has_value() && *a.count == 0 && a.unreadable == 0 && a.writeFailures == 0)
        {
            continue;
        }
        out.push_back(std::move(a));
    }
    return out;
}

std::string
describe(const Announcement& a)
{
    const std::string count = a.count.has_value() ? std::to_string(*a.count) : "an unknown number of";
    std::string line = "P4 switch dpid " + std::to_string(a.dpid) + ": the proxy's " + a.cause +
                       " pushed its pipeline and wiped " + count +
                       " rule(s) installed through the Ryu-compatible API (/stats/flowentry/*)";
    if (!a.countUnknown.empty())
    {
        line += " (count unknown: " + a.countUnknown + ")";
    }
    if (a.unreadable > 0)
    {
        line += "; " + std::to_string(a.unreadable) +
                " line(s) of its journal could not be read, so the count may be short";
    }
    if (a.writeFailures > 0)
    {
        line += "; " + std::to_string(a.writeFailures) +
                " write(s) could not be journaled, so the count may be short";
    }
    line += ". They were NOT replayed: this switch no longer holds what the twin and its apps "
            "installed on it until whoever installed them resends them. The record (" +
            a.id + ") is on this switch's /ndt/get_graph_data node as `ryu_rules_lost`.";
    return line;
}

void
attachToNode(nlohmann::json& node, const VertexProperties& vertex, const RecordsByDpid& records)
{
    if (vertex.vertexType != VertexType::SWITCH)
    {
        return;
    }
    const auto it = records.find(vertex.dpid);
    if (it == records.end())
    {
        return;
    }
    node["ryu_rules_lost"] = it->second;
}

} // namespace p4loss
