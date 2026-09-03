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
 * @brief Why the twin last moved a vertex or edge to `isUp = false`.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md F-14 / F-16. Before this existed, `isUp = false` on an edge could only
 * come from an operator POSTing /ndt/link_failed, and on a host vertex it could not come from
 * anywhere at all -- so "down" carried no question about its own provenance. Making a host
 * markable down introduces one: the twin has no host liveness probe and never will have one on
 * this path, so a host reading down is always a *derived* statement ("the only switch it hangs
 * off is unreachable"), never an observed one ("I asked it and it did not answer").
 *
 * A consumer that cannot tell those apart would be right to distrust both. This field is what
 * lets it tell them apart, and it is emitted as `down_reason` alongside `is_up` rather than
 * folded into it -- the same shape as `admin_disabled`, which is emitted beside `is_enabled`
 * for exactly the same reason.
 *
 * `None` on something that is down means one of the pre-existing writers put it there:
 * a power actuation, the liveness poll, or /ndt/link_failed.
 */
enum class DownReason
{
    None,             ///< Not moved down by liveness derivation. The default for everything.
    SwitchUnreachable ///< Reached only through a switch the twin has repeatedly found unusable.
};

/** @brief Wire form of DownReason. Hyphenated, matching the rest of the /ndt/ JSON vocabulary.
 *  [Co-developed with claude code -- Adam] */
inline const char*
downReasonToString(DownReason reason)
{
    switch (reason)
    {
    case DownReason::None:
        return "none";
    case DownReason::SwitchUnreachable:
        return "switch-unreachable";
    }
    return "none";
}

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
 * @brief One OVS bridge's sFlow configuration, as read back off the live switch.
 *
 * @details
 * [Co-developed with claude code -- Adam]
 * KNOWN-ISSUES A-4f. This is what `ovs-vsctl del-br` destroys along with the bridge, and what
 * powerOn has to put back. It is a value, not a command string, so the strategy that saves it
 * and the strategy that replays it cannot disagree about the format.
 *
 * 🔑 `agentIpCidr` is here and is NOT optional. The sFlow row alone is not enough: the agent is
 * the bridge's own internal port, whose IPv4 address `del-br` also takes with it, and that
 * address is what the collector reads as `AgentKey.agentIP` to attribute samples to an edge
 * (FlowLinkUsageCollector.cpp:1442-1447 keys on the agent IP; TopologyAndFlowMonitor.cpp:1571
 * resolves it against `dstIp`). Restoring the record onto an address-less interface would be a
 * restore that runs, succeeds, and lands somewhere the samples cannot be attributed from --
 * the shape memory `injections-must-assert-their-own-success` calls the ninth form.
 *
 * The three-state contract mirrors executeListPorts':
 *   - `std::nullopt` from the reader           -- the query failed; we do not know
 *   - `configured == false`                    -- the bridge genuinely has no sFlow (TESTBED,
 *                                                 or a bridge nobody wanted sampled)
 *   - `configured == true`                     -- these are its settings
 * Collapsing the first two is the conflation that cost this file its port list once already.
 */
struct SflowBridgeState
{
    /// The bridge had an sFlow record. False means it genuinely had none -- not "we could not tell".
    bool configured = false;

    /// True when powerOff could not read the state at all, so powerOn must not claim to restore it.
    bool unknown = false;

    /**
     * @brief powerOn still owes this bridge an sFlow restore.
     *
     * Set by powerOff whenever there was (or might have been) a record to lose; cleared by
     * powerOn only once the restore has been read back and confirmed.
     *
     * 🔴 It is also the second half of powerOn's early-return guard, and that is not incidental.
     * powerOn marks the vertex up even when the sFlow restore failed -- the switch really is
     * forwarding -- so on `getVertexIsUp` alone a retry would take the early return, report
     * success, and never re-attempt the restore. That is the exact trap
     * P4PowerStrategy.cpp:100-114 documents from a live fabric, and reproducing it here while
     * fixing A-4f would be trading one silent failure for another.
     */
    bool restorePending = false;

    std::string agentIface;   ///< sFlow `agent`, i.e. the interface whose IP stamps the datagrams.
    std::string agentIpCidr;  ///< That interface's IPv4/prefix, e.g. "192.168.123.13/24".
    std::string targets;      ///< sFlow `targets`, e.g. "192.168.123.1:6343".
    std::string header;       ///< sFlow `header`, e.g. "128".
    std::string sampling;     ///< sFlow `sampling`, e.g. "256".
    std::string polling;      ///< sFlow `polling`. "0" in MININET, deliberately -- see testbed_topo.py.
};

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

    /** @brief A power-off was commanded for this switch and confirmed, and discovery may not
     *         overrule it.
     *
     * [Co-developed with claude code -- Adam]
     * FINDINGS #46 (with #35 and #36, which are the same root). `isUp` carries two questions at
     * once -- "did anyone command this off" and "is it reachable" -- and only the second one has
     * a writer that re-derives it every poll. So the first one lost:
     *
     *   updateSwitches sets `isUp = true` for every dpid the control plane lists, with no else
     *   branch that ever writes false. The proxy keeps listing a killed switch for about three
     *   seconds after it dies (measured D = 3.06 s), so a power-off that lands shortly before a
     *   poll is overwritten by that poll's answer -- and because nothing else writes `isUp =
     *   false` on the discovery path, the resurrection is permanent: every later poll re-asserts
     *   it. Measured on a live 10-switch bmv2 fabric: a power-off fired 1.5 s before the next
     *   poll was lost 8 times in 14, one fired 2 s after a poll 0 times in 4, and every loss put
     *   `is_up` back to 1 at t_off + 2.31 s -- the instant the poll that still listed the switch
     *   was applied (round3 08_/09_/11_).
     *
     * A fourth flag rather than a new meaning for an existing one, for exactly the reasons
     * `adminDisabled` is a third one:
     *
     *   - `isUp`             -- powered / reachable. Written by liveness probing AND, today, by
     *                           discovery. An observation.
     *   - `adminPoweredOff`  -- an intent that was carried out. Written ONLY by the power
     *                           strategies, on the path where the actuation was confirmed.
     *                           Discovery must never touch it.
     *
     * What it buys: `updateSwitches` still lifts `isUp` for everything else -- which it must,
     * since discovery is a real source of evidence and a poll that never wrote up would leave
     * the graph dark -- but it declines for a switch the twin has been told is off, and says so
     * once. Power-on clears the flag as soon as the helper confirms a process is serving again,
     * which is the same moment P4PowerStrategy already closes its distrust window and for the
     * same reason: the graph is once more backed by something real.
     *
     * 🔴 SERIALISED AS `admin_state`, since Q12 was answered. Adam ruled option (a) on
     * 2026-09-03 (doc/audit/2026-09-03_night-rounds/QUESTIONS-FOR-ADAM.md): split the wire field
     * into `admin_state` ("on"/"off", this flag) and `reachable` (a bool, `isUp`), and keep
     * `is_up` as a DEPRECATED ALIAS of `reachable` so external readers keep working. See
     * doc/audit/2026-09-03_fix-is-up-split/FIX-IS-UP-SPLIT.md.
     *
     * A string, not a bool, and not `admin_powered_off`. "off" and "on" are the vocabulary the
     * power API already speaks (`?action=on|off`), so a caller does not have to remember which
     * way a boolean called `admin_disabled`-something points; and a string leaves room for a
     * third state (say "unknown" on a plane where the twin cannot know) without another key.
     */
    bool adminPoweredOff = false;

    /** @brief Why `isUp` is false, when the twin derived it rather than observing it.
     *  @see DownReason. Owned by TopologyAndFlowMonitor::reconcileDerivedLiveness; every other
     *  writer of `isUp` leaves it at None. [Co-developed with claude code -- Adam] */
    DownReason downReason = DownReason::None;

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

    /**
     * @brief What this bridge's sFlow looked like before powerOff deleted it.
     *
     * [Co-developed with claude code -- Adam]
     * KNOWN-ISSUES A-4f. Saved for the same reason and at the same moment as
     * bridgeConnectedPortsForMininet: `ovs-vsctl del-br` destroys the Bridge row, and the sFlow
     * row hangs off it. The sFlow table is not an OVSDB root table, so once no Bridge references
     * it, it is garbage-collected -- the bridge is the only record of it, exactly as the bridge
     * was once the only record of its ports.
     *
     * Not serialised, like bridgeConnectedPortsForMininet: this is live state about a running
     * fabric, not part of the topology file or of any /ndt/ response shape.
     */
    SflowBridgeState savedSflow;

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
    // [Co-developed with claude code -- Adam] -- Q12.
    // `reachable` is the field; `is_up` is the deprecated alias to_json still emits. Read the
    // field where it exists and fall back to the alias, because a payload written by a kernel
    // that predates the split carries only `is_up` -- and those payloads outlive the release
    // that wrote them. .at() on the fallback, so a payload with NEITHER is still an error with
    // a message rather than a silent default.
    v.isUp = j.contains("reachable") ? j.at("reachable").get<bool>() : j.at("is_up").get<bool>();
    v.isEnabled = j.at("is_enabled").get<bool>();
    // .value() not .at(), and defaulting to "on": an old payload says nothing about commands,
    // and "nothing" means "nobody commanded this off". Defaulting the other way would read every
    // archived graph as a fabric somebody had deliberately powered down.
    v.adminPoweredOff = j.value("admin_state", std::string("on")) == "off";
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
                       // [Co-developed with claude code -- Adam] -- Q12, Adam's ruling (a) of
                       // 2026-09-03. `is_up` used to answer two questions with one bit:
                       // "did anybody command this off" and "can the twin reach it". They have
                       // different writers (the power strategies vs liveness probing), different
                       // lifetimes, and they can legitimately disagree -- a switch commanded off
                       // and restarted out of band is commanded-off AND reachable. With one bit
                       // the twin had to pick a lie; these are the two answers.
                       {"admin_state", v.adminPoweredOff ? "off" : "on"},
                       {"reachable", v.isUp},
                       // 🔴 DEPRECATED ALIAS OF `reachable`, kept deliberately and not merely
                       // left behind. Four consumers read `is_up` by name -- Energy-Saving-App,
                       // Network-Traffic-Visualizer, Web-GUI, Traffic-Engineering-App -- and the
                       // Energy-Saving-App parses it with `j.at("is_up")`, which THROWS on a
                       // missing key: removing this line is a hard parse failure in another
                       // repository, not a deprecation. It tracks `reachable` and nothing else;
                       // wiring it to admin_state would put the old ambiguity back under a new
                       // name. New readers must use `reachable`.
                       {"is_up", v.isUp},
                       // Folded, so the four apps that read is_enabled see an operator's
                       // disable with no change on their side; admin_disabled is emitted
                       // alongside for anything that wants to tell the two apart.
                       // [Co-developed with claude code -- Adam]
                       {"is_enabled", v.isEnabled && !v.adminDisabled},
                       {"admin_disabled", v.adminDisabled},
                       // [Co-developed with claude code -- Adam]
                       // An added key, not a changed one: every consumer that reads is_up by
                       // name is unaffected, and one that wants to know whether a host is down
                       // because we asked it or because we inferred it now can. Same additive
                       // shape as admin_disabled above.
                       //
                       // Deliberately not read back by from_json: nothing restores liveness from
                       // a file -- loadStaticTopologyFromFile starts every vertex and edge at
                       // isUp = false with no reason -- so a from_json that parsed it would be
                       // reading a key no writer in this process ever puts into a file.
                       {"down_reason", downReasonToString(v.downReason)},
                       {"device_name", v.deviceName},
                       {"nickname", v.nickName},
                       {"brand_name", v.brandName},
                       {"device_layer", v.deviceLayer},
                       {"ecmp_groups", v.ecmpGroups}};
}

/**
 * @brief Where an edge's remaining-bandwidth figure came from.
 *
 * [Co-developed with claude code -- Adam]
 *
 * F-8: `leftBandwidthFromFlowSample` used to be initialised to MININET_INTERFACE_SPEED and the
 * topology loader never touched it, so before the first flow sample every edge advertised
 * exactly 1 Gbit/s of headroom -- including the sixteen core edges the topology files declare
 * at 10 Gbit/s. The number was wrong on 16 of 288 edges and *right on the other 272 by
 * coincidence*, because the sentinel happened to equal their declared capacity. No field
 * distinguished the two cases, which is the "sentinel value that looks like data" shape.
 *
 * A wider number cannot carry that distinction: 0 is a producible measurement (the capacity
 * clamp at TopologyAndFlowMonitor.cpp publishes 0 left for a saturated link) and so is every
 * other uint64_t. The provenance therefore has to be its own field.
 *
 * Declared is NOT a weaker spelling of Measured. Under Mininet the declared 10 Gbit/s is never
 * enforced at all -- Mininet silently ignores `bw>1000` (link.py:238), so those core links carry
 * no shaper, and this topology cannot reach 10 Gbit/s arithmetically anyway (two 1 Gbit/s uplinks
 * per access switch). "Declared" is the honest word for it: this is what the model says, and
 * nobody has measured it.
 */
enum class BandwidthSource : uint8_t
{
    Unknown = 0,  // nothing has been read or declared for this edge -- do not treat as capacity
    Declared = 1, // from the topology file's link_bandwidth_bps; a model figure, not an observation
    Measured = 2  // from a telemetry sample (sFlow flow sample, or a testbed counter sample)
};

/** @brief Wire spelling of BandwidthSource for the /ndt/ JSON. [Co-developed with claude code -- Adam] */
inline const char*
toString(BandwidthSource s)
{
    switch (s)
    {
    case BandwidthSource::Declared:
        return "declared";
    case BandwidthSource::Measured:
        return "measured";
    case BandwidthSource::Unknown:
        break;
    }
    return "unknown";
}

/** @brief Inverse of toString; anything unrecognised reads back as Unknown, never as a capacity. */
inline BandwidthSource
bandwidthSourceFromString(const std::string& s)
{
    if (s == "declared")
    {
        return BandwidthSource::Declared;
    }
    if (s == "measured")
    {
        return BandwidthSource::Measured;
    }
    return BandwidthSource::Unknown;
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

    /** @brief Why `isUp` is false, when the twin derived it rather than being told.
     *  @see DownReason. Owned by TopologyAndFlowMonitor::reconcileDerivedLiveness; setEdgeDown
     *  (the /ndt/link_failed path) leaves it at None. [Co-developed with claude code -- Adam] */
    DownReason downReason = DownReason::None;

    uint64_t leftBandwidth = 0;
    uint64_t linkBandwidth = MININET_INTERFACE_SPEED;
    uint64_t linkBandwidthUsage = 0;
    double linkBandwidthUtilization = 0;

    // [Co-developed with claude code -- Adam]
    // F-8. This used to read `= MININET_INTERFACE_SPEED`, and loadStaticTopologyFromFile never
    // wrote it, so an edge that had never been sampled reported a full gigabit of free headroom
    // -- a number indistinguishable from a real reading of an idle 1 Gbit/s link. It is now 0 and
    // paired with leftBandwidthSource, which is the field a reader must consult: 0 is itself a
    // producible measurement (a saturated link publishes 0 left), so the number alone can never
    // say "nobody has looked at this edge yet".
    uint64_t leftBandwidthFromFlowSample = 0;

    // Provenance of leftBandwidth / leftBandwidthFromFlowSample, in that order of precedence per
    // deployment mode; see BandwidthSource. Written by the topology loader (Declared) and by the
    // two telemetry write paths (Measured). [Co-developed with claude code -- Adam]
    BandwidthSource leftBandwidthSource = BandwidthSource::Unknown;

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
    // [Co-developed with claude code -- Adam]
    // value(), not at(): a payload produced before this field existed carries no provenance, and
    // the honest reading of that is Unknown rather than a guess in either direction. Mirrors the
    // key HttpSession emits so a round trip through /ndt/get_graph_data keeps the distinction.
    e.leftBandwidthSource =
        bandwidthSourceFromString(j.value("left_link_bandwidth_source", std::string{}));
    e.leftBandwidthFromFlowSample = e.leftBandwidth;
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


