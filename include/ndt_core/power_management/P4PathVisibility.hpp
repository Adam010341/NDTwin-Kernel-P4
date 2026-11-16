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
//   - each flow row with a path that has a switch on it carries `path_unconfirmed_at`: in path
//     order, every switch on the path whose count is not 0 (a null count included), as
//     {"dpid": <dpid>, "unrendered_entries": <the proxy's value>}. A switch on the path that has
//     no record, while other switches on the fabric do, is listed too, with a null count: nobody
//     said it hides nothing. The first element is the switch at which the twin stops being able
//     to confirm the path. `[]` means every switch on the path had a record and said 0, that is,
//     left out no row it counts.
//
// ABSENCE IS THE BASELINE, as for `capabilities` (P4Capabilities.hpp): a row carries no
// `path_unconfirmed_at` when the proxy has no `flow_stats` record for any switch on the fabric --
// an OVS fabric, a proxy too old to report, or a proxy the kernel could not read on its last
// attempt. Nobody said, so nothing is claimed either way. A row whose path has no switch on it
// carries none either.
//
// What it does not cover: a drop done in pipeline code with no table row behind it (a register, a
// counter-driven branch) is invisible to the proxy's count too. On NDTwin's own pipeline the proxy
// also leaves out, uncounted, a row with no usable match. So 0 means "left out no row it counts",
// not proof that the program forwards what its route table says.
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
 * @brief Adds `path_unconfirmed_at` to each flow row whose path crosses a switch.
 *
 * @param rows  The array getFlowInfoJson / getTopKFlowInfoJson returned. Anything else is left as
 *              it is.
 * @param stats What the proxy last said, per dpid. When it is empty nothing is marked.
 *
 * A path element is a host, and is never looked up, only when it is the one the row names: the
 * first element when its `node` is the row's `src_ip`, the last when its `node` is the row's
 * `dst_ip` and its `interface` is 0 (that is how the walk writes both ends: on a small fabric a
 * host's address and a dpid can be the same integer). The walk can stop at a host that does not
 * own the destination address and push no destination element, and then the path ends at a
 * switch; so every other element, the last included, is scanned like a switch. A row with an
 * empty path, or with no switch on it, gets no key.
 */
void annotateFlowRows(nlohmann::json& rows, const FlowStatsByDpid& stats);

} // namespace p4paths
