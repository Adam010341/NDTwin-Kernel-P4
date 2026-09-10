#pragma once

#include "common_types/SFlowType.hpp"
#include <algorithm> // for transform
#include <array>     // for kAcceptedSwitchBrands
#include <boost/graph/adjacency_list.hpp>
#include <boost/range/iterator_range.hpp>
#include <cctype>    // for tolower
#include <cstdint>
#include <set>
#include <stdexcept> // for invalid_argument
#include <string>
#include <string_view> // for the brand constants
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
 * a power actuation or the liveness poll.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md B-6 added the third value. `Declared` is not a derivation: it is the
 * provenance of an edge an operator POSTed /ndt/link_failure_detected about, and the reason it is
 * PUBLIC rather than an internal bool is that the declaration is now permanent until someone
 * withdraws it. A forgotten injection used to disappear by itself within 30 s; it now stays, so
 * "which edges are down because somebody said so" has to be answerable by reading the graph
 * rather than by remembering. Same trade `admin_state` makes for the power intent.
 */
enum class DownReason
{
    None,              ///< Not moved down by liveness derivation. The default for everything.
    SwitchUnreachable, ///< Reached only through a switch the twin has repeatedly found unusable.
    Declared ///< An operator declared this link failed (/ndt/link_failure_detected). B-6.
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
    case DownReason::Declared:
        return "declared";
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

/// @name The switch `brand_name` values this build knows how to drive.
///
/// [Co-developed with claude code -- Adam]
/// FINDINGS #91 / W15. `switchKindFromBrandName` below maps "BMv2" and "OVS" and returns HARDWARE
/// for **everything else**, which is a default, not a decision: a typo in a topology file became
/// a hardware switch silently. Measured 2026-09-05 (R0b, kernel 862c4bf8, bad file `c`):
/// `brand_name = "NOT_A_REAL_KIND"` on one switch of an all-OVS fabric was ACCEPTED, and the only
/// thing the operator saw was
///
///     [error] ... Topology mixes data planes (ovs=[1,2,3,4,5,6,8,9,10]; hardware=[7]). ...
///     Fix the topology file, or set AppConfig::ALLOW_MIXED_DATAPLANE to override.
///
/// -- an error-level sentence in the voice of a refusal, followed by the kernel opening :8000 and
/// serving the model. Worse, its advice would make the typo permanent: setting that flag turns
/// every misspelled brand into a hardware switch by consent.
///
/// 🔴 THIS LIST IS THE FLEET, NOT A GUESS, and it must not be narrowed to the two virtual kinds.
/// Every `brand_name` literal in every JSON file in this repository (2026-09-06): "" (hosts),
/// "BMv2", "OVS", "HPE5520", "BrocadeICX7250", "BrocadeICX6610" -- nothing else. Five of the
/// thirteen shipped topologies are TESTBED files whose switches are HPE or Brocade, so a list of
/// {OVS, BMv2} would refuse all five: a wider outage than the defect.
///
/// Each entry is a brand some code actually branches on. OVS and BMv2 select the routing
/// strategy through SwitchKind; kBrandHPE5520 selects the SNMP power/temperature path in
/// DeviceConfigurationAndPowerManager.cpp, and the two Brocade models are what its else-branch
/// ("Brocade / Others (Currently via SSH)") was written for. A brand outside this list gets that
/// SSH branch by accident rather than by design, which is what makes accepting it a lie rather
/// than a limitation.
///
/// 🔴 HERE, NOT IN THE VALIDATOR, SINCE 2026-09-07 (W15-1(b), Adam's ruling of 2026-09-06). #91
/// put the list in TopologyAndFlowMonitor.cpp's anonymous namespace for a scheduling reason --
/// this header is included by 43 translation units, so touching it rebuilds the tree -- and paid
/// for it with two copies of one truth: a list in the validator, a mapping here, and six string
/// comparisons in the power manager, held together by a textual tripwire. The five names below
/// are now the only place a brand is spelled, every comparison names one of them, and the
/// tripwire's job has changed accordingly (see
/// TopologyInputValidationTest.TheAcceptedBrandListCoversEveryBrandTheCodeBranchesOn): drift is a
/// compile error now, so what it looks for is a brand comparison written as a bare literal.
///
/// A new switch model belongs here AND in a power/telemetry path -- or, if this build only has to
/// model it, in a topology file that declares an explicit `switch_kind` (manual section 38).
/// @{
inline constexpr std::string_view kBrandOVS = "OVS";
inline constexpr std::string_view kBrandBMv2 = "BMv2";
inline constexpr std::string_view kBrandHPE5520 = "HPE5520";
inline constexpr std::string_view kBrandBrocadeICX6610 = "BrocadeICX6610";
inline constexpr std::string_view kBrandBrocadeICX7250 = "BrocadeICX7250";

inline constexpr std::array<std::string_view, 5> kAcceptedSwitchBrands{
    kBrandOVS,            // Mininet bridge, driven through Ryu             -> SwitchKind::OVS
    kBrandBMv2,           // P4 behavioural model, driven through the proxy -> SwitchKind::BMV2
    kBrandHPE5520,        // testbed hardware, SNMP power + temperature
    kBrandBrocadeICX6610, // testbed hardware, SSH power
    kBrandBrocadeICX7250, // testbed hardware, SSH power
};
/// @}

/**
 * @brief The value `power_path` and `telemetry_path` take when this build has no branch
 *        written for a switch's brand.
 *
 * [Co-developed with claude code -- Adam]
 * E-23 / E-25 (Adam's rulings of 2026-09-07). Named rather than spelled out at each site
 * because it is now load-bearing in four places -- the two path functions below write it, the
 * power manager short-circuits on it, the loader counts it for one startup WARN, and
 * `tools/contract_test/spec.py` lists it in the node schema's vocabulary. A fifth spelling of
 * this word in any one of them is a silent hole, not a compile error.
 */
inline constexpr std::string_view kPathNone = "none";

/// The accepted brands as one comma-separated string, for a refusal to print.
/// [Co-developed with claude code -- Adam]
inline std::string
acceptedSwitchBrandList()
{
    std::string joined;
    for (const auto brand : kAcceptedSwitchBrands)
    {
        if (!joined.empty())
        {
            joined += ", ";
        }
        joined += brand;
    }
    return joined;
}

/**
 * @brief Maps a topology JSON "brand_name" to a SwitchKind.
 *
 * Kept for backward compatibility with the existing topology files, which carry only
 * brand_name. Prefer the explicit "switch_kind" key in new topologies. Unknown brands
 * are treated as HARDWARE, matching the pre-existing behaviour where anything that was
 * not recognised as Mininet-managed fell through to the SNMP/SSH testbed paths.
 *
 * ⚠️ That fallback is still here and is still a fallback. What stops it from being reached by a
 * typo is the loader (door 3e), not this function: a topology file naming a brand outside
 * kAcceptedSwitchBrands is refused unless the node also declares an explicit `switch_kind`.
 * Anything that builds a graph WITHOUT going through validateStaticTopologyJson gets the old
 * behaviour, which is why option (c) of W15-1 -- throwing from here -- was left on the table.
 *
 * [Co-developed with claude code -- Adam]
 */
inline SwitchKind
switchKindFromBrandName(const std::string& brandName)
{
    if (brandName == kBrandBMv2)
    {
        return SwitchKind::BMV2;
    }
    if (brandName == kBrandOVS)
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
 * @brief Which power path this build has written for a switch of this `brand_name`.
 *
 * [Co-developed with claude code -- Adam]
 * FINDINGS #91 / W15-2. The topology validator admits a `brand_name` this build has no data
 * plane for **when the node also declares an explicit, legal `switch_kind`** (Adam's ruling,
 * 2026-09-06 grill §4D round 3): the alternative was that an operator with a Cisco or an Arista
 * had to edit one line of C++ before the kernel would read their topology at all. The ruling
 * came with a condition, and this is it -- such a machine must be marked in the graph as one
 * whose power and telemetry **nobody manages**, so the exemption cannot be mistaken for support.
 *
 * 🔴 WHAT THESE TWO FIELDS MEAN, EXACTLY, BECAUSE A VAGUER READING WOULD BE A LIE. They name the
 * mechanism the *brand-specific* branches of DeviceConfigurationAndPowerManager.cpp use to READ
 * this switch's power draw and health. They do **not** describe power on/off actuation, which is
 * dispatched on SwitchKind and not on the brand at all (getPowerStrategyForDpid: BMV2 -> the P4
 * proxy, OVS **and HARDWARE** -> OVSPowerStrategy). A switch admitted by the exemption still gets
 * whatever actuation its declared `switch_kind` selects; what it has none of is a path written
 * for its brand.
 *
 * Each value is the branch it names, not a guess:
 *   "snmp"      kBrandHPE5520                 -> HPE OIDs (power :1805/:2308, cpu :2120,
 *                                                memory :1342, and temperature :2209, which
 *                                                refuses every other brand in so many words)
 *   "ssh"       the two Brocade models        -> the else-branch those same sites fall into,
 *                                                written for "Brocade / Others (Currently via
 *                                                SSH)" and firing Brocade OIDs
 *   "synthetic" OVS / BMv2                    -> MININET mode short-circuits power to
 *                                                syntheticPowerMilliwattsFor(dpid) (:1777,
 *                                                :2301)
 *   "none"      anything else                 -> only reachable through the switch_kind
 *                                                exemption, and the honest answer for it
 *
 * ⚠️ `telemetry_path` is "none" for OVS and BMv2 as well, and that is not a mistake or a
 * softening of the mark: MININET mode returns kHealthMetricUnavailable (-1) for CPU, memory and
 * temperature alike (KNOWN-ISSUES F-1), so a software switch genuinely has no health telemetry
 * either. **`power_path == "none"` is the mark that is unique to an exempted switch** -- every
 * accepted brand has some power path, and only a brand this build does not know has none.
 *
 * @param brandName the topology file's `brand_name`, verbatim and case-sensitively.
 */
inline const char*
powerPathForBrandName(const std::string& brandName)
{
    if (brandName == kBrandOVS || brandName == kBrandBMv2)
    {
        return "synthetic";
    }
    if (brandName == kBrandHPE5520)
    {
        return "snmp";
    }
    if (brandName == kBrandBrocadeICX6610 || brandName == kBrandBrocadeICX7250)
    {
        return "ssh";
    }
    return kPathNone.data();
}

/**
 * @brief Which CPU / memory / temperature path this build has written for this `brand_name`.
 * @see powerPathForBrandName -- same contract, same citations, same "none".
 * [Co-developed with claude code -- Adam]
 */
inline const char*
telemetryPathForBrandName(const std::string& brandName)
{
    if (brandName == kBrandHPE5520 || brandName == kBrandBrocadeICX6610 ||
        brandName == kBrandBrocadeICX7250)
    {
        return "snmp";
    }
    return kPathNone.data();
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

    /** @brief Which brand-specific power / health path this build has for this switch.
     *
     * [Co-developed with claude code -- Adam]
     * FINDINGS #91 / W15-2. Set by loadStaticTopologyFromFile from powerPathForBrandName /
     * telemetryPathForBrandName -- one source, so the two words on the wire cannot drift from
     * the branches they describe. Emitted by /ndt/get_static_topology_json (manual section 38)
     * on SWITCH nodes only; a host has no data plane, no plug and no OID.
     *
     * 🔴 `powerPath == "none"` is the mark of a switch admitted only because it declared a
     * `switch_kind`: this build has no power or telemetry path written for its brand, and the
     * generic else-branches it falls into are written for Brocade hardware and will not answer
     * for it. The exemption is what lets an unknown model be modelled at all; this field is what
     * stops that from reading as support. See powerPathForBrandName for the full contract.
     *
     * Default "none" rather than "": a vertex nobody set is a vertex nothing manages, and the
     * safe reading of silence here is "no path", never "some path we forgot to name".
     */
    std::string powerPath = "none";
    std::string telemetryPath = "none"; ///< @see powerPath.

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

/**
 * @brief Is this a switch whose brand this build has no power or telemetry path for?
 *
 * [Co-developed with claude code -- Adam]
 * E-23 (Adam's ruling of 2026-09-07). `power_path == "none"` is the ONE mark that is unique to a
 * switch admitted by the `switch_kind` exemption -- `telemetry_path` is "none" for OVS and BMv2
 * as well, because a software switch genuinely has no CPU or thermal telemetry (KNOWN-ISSUES
 * F-1), so it cannot carry this question. See powerPathForBrandName for the full contract.
 *
 * One predicate rather than five copies of `v.powerPath == "none"`, because it is now asked at
 * six sites in DeviceConfigurationAndPowerManager.cpp and once more by the loader's startup
 * count, and a site that asked it a slightly different way would dial a machine nobody wrote a
 * branch for -- which is the whole defect E-23 names.
 *
 * The `vertexType` half is not decoration: `powerPath` defaults to "none" on every vertex, so a
 * HOST -- which has no brand, no plug and no OID and is skipped by every caller anyway -- would
 * otherwise answer yes to a question that is only meaningful about a switch.
 */
inline bool
isExemptFromBrandPaths(const VertexProperties& v)
{
    return v.vertexType == VertexType::SWITCH && v.powerPath == kPathNone;
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

    // [Co-developed with claude code -- Adam]
    // E-25 / E-30 (Adam's ruling of 2026-09-07). The two marks, on the wire at last.
    //
    // 🔴 WHY THIS IS HERE AND NOT ONLY IN getStaticTopologyJson. W15-2 wrote the marks onto the
    // vertex and published them from TopologyAndFlowMonitor::getStaticTopologyJson, i.e. from
    // /ndt/get_static_topology_json. That is a DIFFERENT serialiser from this one:
    // /ndt/get_graph_data builds its nodes with `result["nodes"].push_back(graph[vd])`
    // (HttpSession.cpp), which is this function -- so an exempted switch was marked in the
    // endpoint hardly anybody reads and unmarked in the one four external apps do. Measured
    // 2026-09-07 (round-2 log lw17c): a kernel carrying the exemption served that node with
    // brand_name, admin_state and is_up and no power_path at all. The mark existed only in
    // memory.
    //
    // SWITCH nodes only, and on purpose -- the same rule getStaticTopologyJson already follows.
    // A host has no brand, no plug and no OID; publishing "none" for one would invite the reading
    // that some OTHER host might have a path.
    //
    // Purely additive: no existing key changes type, spelling or value, so a consumer that has
    // never heard of these two keeps parsing exactly what it parsed yesterday. The baseline this
    // is measured against is 28b8b13, which had no `switch_kind` at all -- there, brand_name was
    // just a string, anything that was neither HPE nor MININET went down the Brocade SSH branch,
    // and NOTHING on the wire ever admitted that this build could not read the machine. W15-2 was
    // the first build to admit it; this is the first one that says so out loud.
    if (v.vertexType == VertexType::SWITCH)
    {
        j["power_path"] = v.powerPath;
        j["telemetry_path"] = v.telemetryPath;
    }
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
     *  (the observation path) leaves it at None. [Co-developed with claude code -- Adam] */
    DownReason downReason = DownReason::None;

    /**
     * @brief An operator declared this link failed, and discovery may not overrule it.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md **B-6**, and the edge half of FINDINGS #46. A fifth flag rather than a
     * new meaning for `isUp` or a third value written into `downReason`, for the reasons
     * `adminPoweredOff` is a fourth one on the vertex:
     *
     *   - `isUp`         -- carrying traffic. Written by liveness derivation AND by discovery.
     *                       An observation.
     *   - `downReason`   -- why the DERIVATION took it down. Owned by
     *                       reconcileDerivedLiveness, which rewrites it every poll.
     *   - `declaredDown` -- an intent that was carried out: /ndt/link_failure_detected said this
     *                       link is gone. Written ONLY by the push path. Discovery and the
     *                       derivation must never touch it.
     *
     * Why not simply `downReason = Declared`: reconcileDerivedLiveness OWNS that field and
     * rewrites it on every poll (SwitchUnreachable when a switch at either end is isolating,
     * None when it is not), so a declaration stored there is erased by the first switch outage
     * that touches this edge and never comes back. The flag is separate precisely so that
     * nothing which re-derives liveness can spend it.
     *
     * Before this existed, `POST /ndt/link_failure_detected` marked both directions down and the
     * next `updateLinks` set them straight back to `isUp = true` -- 5 times in 5, 0-30 s later,
     * with no line in the log and `/ndt/link_recovery_detected` never called (09-04 night round,
     * r2-20-linkfail-probe.log). The endpoint's 200 was true and its effect was not.
     *
     * @warning It is PERMANENT until it is withdrawn -- and, since W8b, only two things withdraw
     *          it: `/ndt/inject_link_recovery`, or a `/ndt/link_recovery_detected` that PAIRS with
     *          a `failureReported` below. It survives Ryu reconverging and a switch restart, by
     *          design. That is why it is visible on the wire as `down_reason: "declared"` -- see
     *          effectiveDownReason below.
     */
    bool declaredDown = false;

    /**
     * @brief The control plane reported a failure on this edge, and no recovery report has spent
     *        it yet. The thing a `/ndt/link_recovery_detected` has to pair with.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md **B-6**, second round (W8b). A SIXTH flag, and the reason it is not a
     * reuse of `declaredDown` is that the two answer different questions:
     *
     *   - `declaredDown`    -- "the twin is holding this link down because it was told to."
     *                          Set by BOTH /ndt/link_failure_detected and /ndt/inject_link_failure.
     *   - `failureReported` -- "the control plane said it saw this link break." Set ONLY by
     *                          /ndt/link_failure_detected, which is Ryu's notification endpoint.
     *                          An injection made through /ndt/inject_link_failure sets the
     *                          declaration and NOT this: nobody observed anything, an operator
     *                          asked for it.
     *
     * WHY IT EXISTS -- measured, 2026-09-07 00:08 (scratch .../logs/live-round2-console.log, arm
     * lw8b, OVS 4 hosts): a link failure was declared, Ryu was killed and restarted with the same
     * argv, and within one second of Ryu coming back the kernel logged a
     * `POST /ndt/link_recovery_detected` for EVERY link in the fabric -- Ryu's topology module
     * raises `EventLinkAdd` when LLDP first discovers a link, and `intelligent_router.py`'s
     * `on_link_add` notifies the twin from there. The standing declaration was gone in 9 of 9
     * samples over the following 90 s. A declaration that outlives a topology poll but not a
     * control-plane restart is still an injection that ends when something unrelated happens.
     *
     * So a recovery report may only withdraw a declaration it can PAIR with: one failure report,
     * one withdrawal. A bare rediscovery -- a recovery report for an edge nothing ever reported
     * broken -- marks the edge up and leaves any declaration standing.
     *
     * @note Cleared by the recovery that spends it and by `/ndt/inject_link_recovery`; never
     *       written by discovery or by the derived-liveness pass, for the reason `declaredDown`
     *       is not.
     */
    bool failureReported = false;

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

/**
 * @brief The `down_reason` an edge publishes: the declaration wins over the derivation.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md B-6. The two can hold at once -- an edge can be declared down AND sit
 * behind a switch the twin has isolated -- and a reader gets one string. It is the declaration,
 * because the two answers differ in what the reader has to DO about them: `switch-unreachable`
 * clears itself when the switch comes back, `declared` does not clear until somebody POSTs
 * /ndt/link_recovery_detected. Reporting the self-healing one would hide the standing one behind
 * a reason that is about to disappear.
 *
 * Single point of computation on purpose: `declaredDown` is a flag and `downReason` is a field,
 * and the moment two call sites decide the precedence for themselves they will differ.
 */
inline DownReason
effectiveDownReason(const EdgeProperties& e)
{
    return e.declaredDown ? DownReason::Declared : e.downReason;
}

inline void
from_json(const json& j, EdgeProperties& e)
{
    e.isUp = j.at("is_up").get<bool>();
    e.isEnabled = j.at("is_enabled").get<bool>();
    e.adminDisabled = j.value("admin_disabled", false);
    // [Co-developed with claude code -- Adam]
    // `declaredDown` and `failureReported` are deliberately NOT read back, for the reason
    // `down_reason` is not: no writer puts them in a file, the loader starts every edge down
    // anyway, and a declaration restored from a payload would be an injection nobody in this
    // process ever made. A kernel restart forgets standing declarations -- which is the honest
    // answer, because the tc netem that may accompany one lives in the machine's qdisc tree and
    // not in this file. That asymmetry is why the kernel now sweeps the qdisc tree at startup and
    // says what it finds; see TopologyAndFlowMonitor::warnAboutResidualNetem. B-6.
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


