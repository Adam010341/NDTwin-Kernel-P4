// [Co-developed with claude code -- Adam]
// What each P4 switch may be asked to do, carried from the proxy onto /ndt/get_graph_data.
//
// The proxy decides a switch's `capabilities` (GET /p4/switch_state, one object per switch:
// ipv4_route, five_tuple, reroute, link_discovery, binding_source). The kernel does not
// interpret it. It copies the object as it was served onto that switch's node, so the one
// consumer that acts on it -- the Web-GUI greying out writes a switch cannot take -- reads the
// proxy's answer and not a kernel paraphrase of it.
//
// ABSENCE IS THE BASELINE, NOT A VERDICT. A node without `capabilities` means "nobody said":
// an OVS fabric (no proxy), a proxy too old to report, a switch the proxy does not list, or a
// proxy that could not be read on the last attempt. Every one of those must read as "every
// operation is supported", which is what the kernel served before this key existed. So nothing
// here ever manufactures an object -- not `{}`, not `null`, not a default -- for a switch the
// proxy did not describe.
#pragma once

#include <nlohmann/json.hpp>

#include <cstdint>
#include <map>
#include <optional>

// Declared, not included: DeviceConfigurationAndPowerManager.hpp includes this header and
// deliberately keeps GraphTypes.hpp out of its own include set (see its note on VertexProperties).
struct VertexProperties;

namespace p4caps
{

/// dpid -> the `capabilities` object the proxy served for that switch, verbatim.
using CapabilitiesByDpid = std::map<std::uint64_t, nlohmann::json>;

/**
 * @brief Every switch's `capabilities` in one GET /p4/switch_state body.
 *
 * @param payload The parsed body, or nullopt when the proxy was not asked or could not be read.
 * @return One entry per switch whose entry carries a JSON object under `capabilities`, copied
 *         whole -- keys the kernel has never heard of and `null` values included. A switch whose
 *         entry lacks the key, or carries something that is not an object, gets no entry.
 *
 * Keys of `switches` are the dpid in decimal, as the proxy writes them (and as p4LivenessFor
 * reads them). A key that is not a plain decimal number is skipped rather than guessed at.
 */
CapabilitiesByDpid fromSwitchState(const std::optional<nlohmann::json>& payload);

/**
 * @brief Adds `capabilities` to one serialised /ndt/get_graph_data node, when there is one.
 *
 * @param node   The node as to_json(VertexProperties) produced it.
 * @param vertex The vertex it was produced from.
 * @param caps   What the proxy last said, per dpid.
 *
 * Switch nodes only: a host has no pipeline. A switch the map does not know is left exactly as
 * it was -- see the file header for why absence must survive.
 */
void attachToNode(nlohmann::json& node,
                  const VertexProperties& vertex,
                  const CapabilitiesByDpid& caps);

} // namespace p4caps
