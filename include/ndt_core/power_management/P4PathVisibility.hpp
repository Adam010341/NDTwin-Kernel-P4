// [Co-developed with claude code -- Adam]
// Which switches on a flow's path the twin cannot fully read, carried from the proxy onto
// /ndt/get_graph_data and onto the flow rows of /ndt/get_detected_flow_data and
// /ndt/get_detected_top_k_flow_data.
//
// The kernel works out a flow's path by walking the forwarding tables the control plane renders
// for it (GET /stats/flow). On a P4 switch the proxy renders only what it can describe in that
// shape. On a package's pipeline that is the bound route table alone: an ACL, a firewall table or
// any other table's rows are left out, and so is a ternary or range row Ryu cannot spell. The
// proxy counts what it left out, per switch, as `flow_stats.unrendered_entries` on
// GET /p4/switch_state (null until that switch's first render). A path the walk completes through
// such a switch is a path through the one table the twin saw; a row of a table it did not see may
// drop or redirect the flow there.
//
// So the kernel does two things with that count, and neither changes the path itself:
//
//   - each switch node of /ndt/get_graph_data carries the proxy's `flow_stats` object verbatim;
//   - each flow row with a non-empty path carries `path_unconfirmed_at`: in path order, every
//     switch on the path whose count is not 0 (a null count included), as
//     {"dpid": <dpid>, "unrendered_entries": <the proxy's value>}. The first element is the switch
//     at which the twin stops being able to confirm the path. `[]` means every switch on the path
//     that has a record said it left nothing out.
//
// ABSENCE IS THE BASELINE, as for `capabilities` (P4Capabilities.hpp): a row carries no
// `path_unconfirmed_at` when no switch on its path has a `flow_stats` record -- an OVS fabric, a
// proxy too old to report, or a proxy the kernel could not read on its last attempt. Nobody said,
// so nothing is claimed either way.
//
// What it does not cover: a drop done in pipeline code with no table row behind it (a register, a
// counter-driven branch) is invisible to the proxy's count too. A switch reporting 0 has no
// unrendered rows; it is not proof the program forwards what its route table says.
#pragma once

#include <nlohmann/json.hpp>

#include <cstdint>
#include <map>
#include <optional>

// Declared, not included, for the reason P4Capabilities.hpp gives.
struct VertexProperties;

namespace p4paths
{

/// dpid -> the `flow_stats` object the proxy served for that switch, verbatim.
using FlowStatsByDpid = std::map<std::uint64_t, nlohmann::json>;

/// Every switch's `flow_stats` in one GET /p4/switch_state body; same reading rules as
/// p4caps::fromSwitchState (only a JSON object is an entry).
FlowStatsByDpid fromSwitchState(const std::optional<nlohmann::json>& payload);

/// Adds `flow_stats` to one serialised switch node, when the proxy served one for it.
void attachToNode(nlohmann::json& node, const VertexProperties& vertex, const FlowStatsByDpid& stats);

/**
 * @brief Adds `path_unconfirmed_at` to each flow row whose path crosses a switch with a record.
 *
 * @param rows  The array getFlowInfoJson / getTopKFlowInfoJson returned. Anything else is left as
 *              it is.
 * @param stats What the proxy last said, per dpid.
 *
 * The first and last elements of a `path` are the two hosts (their IPs), never dpids, and are
 * never looked up: on a small fabric a host's address and a dpid can be the same integer. A row
 * with an empty path, or whose switches have no record, gets no key.
 */
void annotateFlowRows(nlohmann::json& rows, const FlowStatsByDpid& stats);

} // namespace p4paths
