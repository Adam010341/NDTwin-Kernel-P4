#pragma once

#include "common_types/SFlowType.hpp"
#include <algorithm> // for transform
#include <boost/graph/adjacency_list.hpp>
#include <boost/range/iterator_range.hpp>
#include <cctype>    // for tolower
#include <cstdint>
#include <set>
#include <stdexcept> // for invalid_argument
#include <string>
#include <variant>
#include <vector>

#define MININET_INTERFACE_SPEED 1000000000

// TODO[OPTIMIZE] the Graph and corelated function (in Topology Monitor)

using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;


enum class VertexType
{
    SWITCH,
    HOST
};

/**
 * @brief Data-plane implementation of a switch, which selects its control strategy.
 *
 * Drives which IRoutingStrategy / IPowerStrategy a switch is actuated through, so it
 * must be a typed value rather than a brand-name string comparison: a misspelled
 * brand name would otherwise silently route P4 rules to the Ryu controller.
 *
 * [Co-developed with claude code -- Adam]
 */
enum class SwitchKind
{
    OVS,     // Open vSwitch under Mininet, controlled via Ryu OpenFlow 1.3
    BMV2,    // P4 behavioural model, controlled via the P4 proxy agent over P4Runtime
    HARDWARE // Physical OpenFlow switch in the testbed (Brocade, HPE, ...)
};

/**
 * @brief Maps a topology JSON "brand_name" to a SwitchKind.
 *
 * Kept for backward compatibility with the existing topology files, which carry only
 * brand_name. Prefer the explicit "switch_kind" key in new topologies. Unknown brands
 * are treated as HARDWARE, matching the pre-existing behaviour where anything that was
 * not recognised as Mininet-managed fell through to the SNMP/SSH testbed paths.
 *
 * [Co-developed with claude code -- Adam]
 */
inline SwitchKind
switchKindFromBrandName(const std::string& brandName)
{
    if (brandName == "BMv2")
    {
        return SwitchKind::BMV2;
    }
    if (brandName == "OVS")
    {
        return SwitchKind::OVS;
    }
    return SwitchKind::HARDWARE;
}

/**
 * @brief Parses an explicit "switch_kind" string, case-insensitively.
 *
 * @throws std::invalid_argument if the value names no known kind, so a typo in a
 *         topology file fails loudly at load instead of misrouting rules at runtime.
 *
 * [Co-developed with claude code -- Adam]
 */
inline SwitchKind
switchKindFromString(std::string s)
{
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });

    if (s == "ovs")
    {
        return SwitchKind::OVS;
    }
    if (s == "bmv2" || s == "p4")
    {
        return SwitchKind::BMV2;
    }
    if (s == "hardware")
    {
        return SwitchKind::HARDWARE;
    }
    throw std::invalid_argument("Unknown switch_kind '" + s +
                                "' (expected ovs, bmv2/p4, or hardware)");
}

/**
 * @brief Human-readable name for logs and error messages.
 *
 * [Co-developed with claude code -- Adam]
 */
inline const char*
switchKindToString(SwitchKind kind)
{
    switch (kind)
    {
    case SwitchKind::OVS:
        return "ovs";
    case SwitchKind::BMV2:
        return "bmv2";
    case SwitchKind::HARDWARE:
        return "hardware";
    }
    return "unknown";
}

/**
 * @brief Kind of ECMP group member.
 *
 * Currently only physical ports are supported, but the enum is extensible
 * to Lag or NextHop members in the future.
 */
enum class MemberType
{
    Port /*, Lag, NextHop */
};

inline MemberType
memberTypeFromString(const std::string& s)
{
    if (s == "port")
    {
        return MemberType::Port;
    }
    // if(s == "lag") return MemberType::Lag;
    // if(s == "next_hop") return MemberType::NextHop;
    throw std::invalid_argument("Unknown ECMP member type " + s);
}


struct PortMember
{
    int portId = 0;
};


using EcmpMember = std::variant<PortMember /*, LagMember, NextHopMember */>;


struct EcmpGroup
{
    std::vector<EcmpMember> members;
};


inline std::string
to_string(MemberType t)
{
    switch (t)
    {
    case MemberType::Port:
        return "port";
        // case MemberType::Lag: return "lag";
        // case MemberType::NextHop: return "next_hop";
    }
    return "unknown";
}

/**
 * @brief Properties associated with a vertex in the topology graph.
 *
 * Stores addressing, identity and configuration information for either
 * a switch or a host, including ECMP groups where applicable.
 */
struct VertexProperties
{
    VertexType vertexType;
    uint64_t mac = 0;
    std::vector<uint32_t> ip;
    uint64_t dpid;
    bool isUp = true;
    bool isEnabled = true;

    /** @brief An operator asked for this to be out of service, and discovery may not overrule it.
     *
     * [Co-developed with claude code -- Adam]
     * Third flag rather than reusing `isEnabled`, because the two answer different questions and
     * different writers own them:
     *
     *   - `isUp`          -- powered / reachable. Written by liveness probing.
     *   - `isEnabled`     -- the control plane can drive this. Written by **discovery**
     *                        (`updateSwitches`/`updateLinks`/`updateHosts`), unconditionally true
     *                        for everything the poll reports.
     *   - `adminDisabled` -- administrative intent. Written **only** by the Intent Translator's
     *                        DisableSwitch/EnableSwitch. Discovery must never touch it.
     *
     * Before this existed, `DisableSwitch` cleared `isEnabled` and the next topology poll (5 s for
     * the process's first 90 s, then 30 s -- `kWhileConverging` / `kOnceConverged` /
     * `kConvergingFor` in TopologyAndFlowMonitor::run()) set it straight back to true, with no
     * log. The operator's instruction was silently discarded while every consumer went on showing
     * the switch as usable.
     *
     * ⚠️ The obvious alternative -- "let discovery write only `isUp`" -- does not work: the loader
     * starts everything at `isEnabled = false` (both the node and the edge branch of
     * TopologyAndFlowMonitor::loadStaticTopologyFromFile) and discovery is the *only* thing that
     * ever sets it true, so forbidding it blanks the whole graph.
     *
     * Serialised as `admin_disabled`, and folded into the `is_enabled` that `/ndt/get_graph_data`
     * emits (HttpSession.cpp) so the four consumers that read `is_enabled` -- Energy-Saving-App,
     * Network-Traffic-Visualizer, Web-GUI, Traffic-Engineering-App -- see an operator's disable
     * without any change on their side. They already treat it as "usable": the Energy-Saving
     * simulator's own walk is `if (!isUp || !isEnabled) continue;`.
     */
    bool adminDisabled = false;

    std::string deviceName = "";
    std::string nickName = "";
    std::string bridgeNameForMininet = "";
    std::string brandName = "";
    // [Co-developed with claude code -- Adam]
    // Which data plane this switch runs, and therefore which routing/power strategy
    // actuates it. Derived from the topology JSON's optional "switch_kind", falling back
    // to brandName. Typed so a misspelled brand name cannot silently send P4 rules to Ryu.
    SwitchKind switchKind = SwitchKind::HARDWARE;
    int deviceLayer = -1;

    /**
     * @brief Which smart plug outlet powers this switch, as recorded in the topology file.
     *
     * [Co-developed with claude code -- Adam]
     * Carried on the vertex so /ndt/get_static_topology_json can echo the real per-switch
     * assignment. That endpoint used to emit a constant `{"smart_plug_ip": "172.25.166.135",
     * "smart_plug_outlet": 3}` for *every* switch -- which is s2's outlet. The topology files
     * have always had genuine per-switch values (the ten switches in
     * StaticNetworkTopology_ipAlias4_10Switches_all_1g_cable.json span three PDUs), so the
     * endpoint was inventing data the loader was already reading past.
     *
     * The kernel's own power path does not use these: it reads switchSmartPlugTable, which
     * DeviceConfigurationAndPowerManager builds from the same file. These exist for the
     * endpoint, so that what it serves and what the kernel actuates come from one source.
     *
     * Empty / -1 mean the file did not say, which is the case for host vertices.
     */
    std::string smartPlugIp = "";
    int smartPlugOutlet = -1;

    std::vector<std::string> bridgeConnectedPortsForMininet;
    std::vector<EcmpGroup> ecmpGroups;
};

/**
 * @brief Is this vertex/edge available to carry traffic?
 *
 * [Co-developed with claude code -- Adam]
 * One definition instead of the intersection written out at each call site. It is written out at
 * six of them today, and the seventh -- `getAvgLinkUsage` -- tested only `isUp`, which is exactly
 * the failure this shape invites: nothing tells you a site is missing a flag, and adding a third
 * flag would have meant finding all of them by eye.
 *
 * All three must hold: powered (`isUp`), reachable by the control plane (`isEnabled`), and not
 * administratively taken out of service (`adminDisabled`).
 */
inline bool
isUsable(const VertexProperties& v)
{
    return v.isUp && v.isEnabled && !v.adminDisabled;
}

inline void
from_json(const nlohmann::json& j, PortMember& m)
{
    m.portId = j.at("port_id").get<int>();
}

inline void
to_json(nlohmann::json& j, const PortMember& m)
{
    j = {{"type", "port"}, {"port_id", m.portId}};
}

inline void
from_json(const nlohmann::json& j, EcmpMember& m)
{
    const auto& t = j.at("type").get_ref<const std::string&>();
    if (t == "port")
    {
        m = j.get<PortMember>();
        return;
    }
    // ...more types
    throw std::invalid_argument("Unsupported ECMP member type: " + t);
}

inline void
to_json(nlohmann::json& j, const EcmpMember& m)
{
    std::visit([&](auto&& x) { j = nlohmann::json(x); }, m);
}

inline void
from_json(const nlohmann::json& j, EcmpGroup& g)
{
    g.members = j.at("members").get<std::vector<EcmpMember>>();
}

inline void
to_json(nlohmann::json& j, const EcmpGroup& g)
{
    j = {{"members", g.members}};
}

inline void
from_json(const json& j, VertexProperties& v)
{
    v.vertexType = static_cast<VertexType>(j.at("vertex_type").get<int>());
    v.mac = j.at("mac").get<uint64_t>();
    v.ip = j.at("ip").get<std::vector<uint32_t>>();
    v.dpid = j.at("dpid").get<uint64_t>();
    v.isUp = j.at("is_up").get<bool>();
    v.isEnabled = j.at("is_enabled").get<bool>();
    // .value() not .at(): this field postdates every topology JSON on disk, and a missing one
    // means "nobody has disabled it". [Co-developed with claude code -- Adam]
    v.adminDisabled = j.value("admin_disabled", false);
    v.deviceName = j.at("device_name").get<std::string>();
    v.nickName = j.at("nickname").get<std::string>();
    v.brandName = j.at("brand_name").get<std::string>();
    v.deviceLayer = j.at("device_layer").get<int>();
    v.ecmpGroups = j.at("ecmp_groups").get<std::vector<EcmpGroup>>();
}

inline void
to_json(nlohmann::json& j, const VertexProperties& v)
{
    j = nlohmann::json{{"vertex_type", v.vertexType},
                       {"mac", v.mac},
                       {"ip", v.ip},
                       {"dpid", v.dpid},
                       {"is_up", v.isUp},
                       // Folded, so the four apps that read is_enabled see an operator's
                       // disable with no change on their side; admin_disabled is emitted
                       // alongside for anything that wants to tell the two apart.
                       // [Co-developed with claude code -- Adam]
                       {"is_enabled", v.isEnabled && !v.adminDisabled},
                       {"admin_disabled", v.adminDisabled},
                       {"device_name", v.deviceName},
                       {"nickname", v.nickName},
                       {"brand_name", v.brandName},
                       {"device_layer", v.deviceLayer},
                       {"ecmp_groups", v.ecmpGroups}};
}

/**
 * @brief Properties associated with an edge in the topology graph.
 *
 * Tracks link state, capacity, utilization and the set of flows that
 * currently traverse this edge, as well as addressing on both ends.
 */
struct EdgeProperties
{
    bool isUp = true;
    bool isEnabled = true;

    //: Administrative intent for this direction; see VertexProperties::adminDisabled for why it is
    //: a third flag and not a reuse of isEnabled. Set by disableSwitchAndEdges on every edge
    //: incident to the switch; discovery never writes it. [Co-developed with claude code -- Adam]
    bool adminDisabled = false;

    uint64_t leftBandwidth = 0;
    uint64_t linkBandwidth = MININET_INTERFACE_SPEED;
    uint64_t linkBandwidthUsage = 0;
    double linkBandwidthUtilization = 0;

    uint64_t leftBandwidthFromFlowSample = MININET_INTERFACE_SPEED;

    // srcIp (host or agent ip), port represents "physical" port (on switch)
    std::vector<uint32_t> srcIp;
    uint64_t srcDpid;
    uint32_t srcInterface;

    std::vector<uint32_t> dstIp;
    uint64_t dstDpid;
    uint32_t dstInterface;

    std::unordered_map<sflow::FlowKey, TimePoint, sflow::FlowKeyHash> flowSet;  // For finding max flow count, and link failure detection
};

/** @brief Edge overload of isUsable; see the VertexProperties one for why this exists. */
inline bool
isUsable(const EdgeProperties& e)
{
    return e.isUp && e.isEnabled && !e.adminDisabled;
}

inline void
from_json(const json& j, EdgeProperties& e)
{
    e.isUp = j.at("is_up").get<bool>();
    e.isEnabled = j.at("is_enabled").get<bool>();
    e.adminDisabled = j.value("admin_disabled", false);
    e.leftBandwidth = j.at("left_link_bandwidth_bps").get<uint64_t>();
    e.linkBandwidth = j.at("link_bandwidth_bps").get<uint64_t>();
    e.linkBandwidthUsage = j.at("link_bandwidth_usage_bps").get<uint64_t>();
    e.linkBandwidthUtilization = j.at("link_bandwidth_utilization_percent").get<double>();
    e.srcIp = j.at("src_ip").get<std::vector<uint32_t>>();
    e.srcDpid = j.at("src_dpid").get<uint64_t>();
    e.srcInterface = j.at("src_interface").get<uint32_t>();
    e.dstIp = j.at("dst_ip").get<std::vector<uint32_t>>();
    e.dstDpid = j.at("dst_dpid").get<uint64_t>();
    e.dstInterface = j.at("dst_interface").get<uint32_t>();


    e.flowSet.clear();
    const auto now = Clock::now();

    if (j.contains("flow_set"))
    {
        for (const auto& fk : j.at("flow_set").get<std::vector<sflow::FlowKey>>())
        {
            e.flowSet.emplace(fk, now);
        }
    }
}

/**
 * @brief Directed topology graph with annotated vertices and edges.
 *
 * Uses Boost adjacency_list to represent the network, with VertexProperties
 * on each vertex and EdgeProperties on each edge.
 */
using Graph = boost::
    adjacency_list<boost::setS, boost::vecS, boost::directedS, VertexProperties, EdgeProperties>;


