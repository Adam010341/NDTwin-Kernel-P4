/**
 * FINDINGS #61 and #62 -- a topology file the kernel cannot honour must be refused, not
 * quietly reduced to the part of it that happened to resolve.
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT WAS MEASURED (doc/audit/2026-09-03_night-rounds/round5-topology-repro)
 *
 *   #61  topo/m1_host_edge_ghost_dpid.json is the shipped P4 4-host topology with ONE field
 *        changed: edge #32's `dst_dpid` 1 -> 99 (and its `dst_ip` to match), i.e. a host cable
 *        plugged into a switch that is not in the file. The kernel loaded it, wrote one
 *        `[warning] ... Skipping edge:` line, and served a 14-node / **39**-edge graph on
 *        :8000 -- 40 edges went in. Every endpoint answered 200
 *        (03_mutant_m1_host_edge_ghost_dpid.log). A fabric with one cable in the wrong socket
 *        is indistinguishable, from outside, from a healthy one.
 *
 *   #62  topo/m4a_port_zero.json and topo/m4b_port_six_digits.json change edge #0's
 *        `src_interface` -- a SWITCH-side port -- to 0 and to 999999. Both loaded, both were
 *        republished verbatim by /ndt/get_graph_data, and the value flows on into the flow
 *        path (06_/07_mutant logs).
 *
 * WHAT THESE TESTS ASSERT
 *   Behaviour, not prose. The two things claimed are (i) the load fails, and (ii) the failure
 *   names the offending value, so an operator can find the entry in a 138-node file. (ii) is
 *   asserted as "the number appears in the message", never as the wording -- rewording a
 *   diagnostic must stay free, and tests/shell/mutate_topology_input_is_validated.sh has a
 *   widening that proves it is.
 *
 * 🔴 THE HOST SIDE OF A HOST EDGE LEGITIMATELY CARRIES PORT 0, AND THE FLEET IS SPLIT ON IT.
 * doc/2026-01-02_ndt_api.md:233: "At the edge between the switch and host, the dpid and
 * interface on the host side are set to 0." Five shipped TESTBED files
 * (StaticNetworkTopology_ipAlias4_*) do exactly that -- 32 to 96 zero-valued host-side
 * interfaces each -- while the eight OVS/P4/Mininet files put 1 there instead. So "a port
 * index must be >= 1" is not the rule; it is the rule for the side whose dpid is not 0. Both
 * halves are pinned below, because a range check that took the shipped fleet down would be a
 * worse defect than the one being fixed.
 */

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>
#include <system_error>
#include <vector>

#include <unistd.h> // getpid, for a temp-file name no concurrent run collides with

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

using nlohmann::json;

/// Exposes the protected loader, the same seam test_TopologyAndFlowMonitor.cpp uses.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void load(const std::string& path)
    {
        loadStaticTopologyFromFile(path);
    }

    /// BUG-17. The compile-time AppConfig flag, made settable for the cases that are about what
    /// happens when an operator HAS opted in. [Co-developed with claude code -- Adam]
    using TopologyAndFlowMonitor::setAllowMixedDataPlane;
};

/// The repo's `setting/` directory, wherever the binary was started from.
///
/// [Co-developed with claude code -- Adam]
/// Same reasoning as the fixture in test_TopologyAndFlowMonitor.cpp: ctest runs from the build
/// tree and l1_unit_tests.sh runs the binary from the repo root, deliberately. A test that
/// cannot find its input must say so rather than assert vacuously over an empty graph.
std::string
settingDir()
{
    static const char* kCandidates[] = {"setting", "../setting", "../../setting"};
    for (const char* candidate : kCandidates)
    {
        if (std::filesystem::is_directory(candidate))
        {
            return candidate;
        }
    }
    return {};
}

std::string
shippedP4Topology()
{
    const std::string dir = settingDir();
    return dir.empty() ? std::string{}
                       : dir + "/StaticNetworkTopologyP4_10Switches_4Hosts.json";
}

/// What one load attempt did. Deliberately records the graph as well as the throw: "the load
/// failed" and "the load failed without leaving half a topology behind" are two claims, and
/// #61 is precisely a case where the first held and the second did not.
struct LoadOutcome
{
    bool threw = false;
    std::string message;
    /// `message` with the topology's own path removed.
    ///
    /// [Co-developed with claude code -- Adam]
    /// The "the refusal names the offending value" cases search for a number. The real message
    /// begins `topology file "<path>": ...`, and the path here is a temp file carrying this
    /// process's pid -- so a pid of 199843 would satisfy a search for "99" with no help from the
    /// diagnostic at all, and the assertion would pass while proving nothing. The instrument must
    /// not be able to produce the answer, so the path is taken out before the search.
    std::string messageSansPath;
    std::size_t vertices = 0;
    std::size_t edges = 0;
    /// The graph the load produced, kept alive so a case can ask what is ON a vertex.
    ///
    /// [Co-developed with claude code -- Adam]
    /// FINDINGS #91 / W15-2. Counting vertices answers "was the file refused, and refused
    /// whole"; it cannot answer "and what did the twin decide about the switch it accepted",
    /// which is the entire condition attached to the switch_kind exemption. Held by
    /// shared_ptr rather than copied: VertexProperties carries a saved sFlow state and an ecmp
    /// vector, and a copy would be a second answer that could disagree with the first.
    std::shared_ptr<Graph> graph;
};

/// Removes every occurrence of `needle` from `haystack`.
std::string
without(std::string haystack, const std::string& needle)
{
    if (needle.empty())
    {
        return haystack;
    }
    for (auto at = haystack.find(needle); at != std::string::npos; at = haystack.find(needle))
    {
        haystack.erase(at, needle.size());
    }
    return haystack;
}

/// Loads `path` into a fresh monitor and reports what happened.
LoadOutcome
loadFile(const std::string& path, int mode = utils::TESTBED, bool allowMixed = false)
{
    LoadOutcome out;
    auto graph = std::make_shared<Graph>();
    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, mode};
    monitor.setAllowMixedDataPlane(allowMixed);

    try
    {
        monitor.load(path);
    }
    catch (const std::exception& err)
    {
        out.threw = true;
        out.message = err.what();
        out.messageSansPath = without(out.message, path);
    }

    std::shared_lock lock(*mutex);
    out.vertices = boost::num_vertices(*graph);
    out.edges = boost::num_edges(*graph);
    out.graph = graph;
    return out;
}

/// The properties of the switch vertex carrying `dpid`, or nullopt if the graph has no such
/// switch. [Co-developed with claude code -- Adam]
std::optional<VertexProperties>
switchWithDpid(const LoadOutcome& out, std::uint64_t dpid)
{
    if (!out.graph)
    {
        return std::nullopt;
    }
    for (auto [vi, viEnd] = boost::vertices(*out.graph); vi != viEnd; ++vi)
    {
        const auto& v = (*out.graph)[*vi];
        if (v.vertexType == VertexType::SWITCH && v.dpid == dpid)
        {
            return v;
        }
    }
    return std::nullopt;
}

/// A temp copy of the shipped P4 topology with one field changed, removed on destruction.
class MutatedTopology
{
  public:
    explicit MutatedTopology(const std::string& tag)
    {
        const std::string source = shippedP4Topology();
        if (source.empty() || !std::filesystem::exists(source))
        {
            return;
        }
        std::ifstream in(source);
        in >> m_json;

        m_path = (std::filesystem::temp_directory_path() /
                  ("ndt_topoval_" + tag + "_" + std::to_string(::getpid()) + ".json"))
                     .string();
    }

    ~MutatedTopology()
    {
        std::error_code ignored;
        std::filesystem::remove(m_path, ignored);
    }

    MutatedTopology(const MutatedTopology&) = delete;
    MutatedTopology& operator=(const MutatedTopology&) = delete;

    bool usable() const
    {
        return !m_path.empty() && !m_json.is_null();
    }

    json& doc()
    {
        return m_json;
    }

    /// Writes the mutated document out and returns the path.
    const std::string& write()
    {
        std::ofstream out(m_path);
        out << m_json.dump();
        out.close();
        return m_path;
    }

  private:
    json m_json;
    std::string m_path;
};

/// Index of the first edge whose src side is a host, i.e. `src_dpid == 0`. Round 5 mutated
/// edge #32 of this file; finding it by shape rather than by index keeps the test honest if
/// the file is ever regenerated in a different order.
std::size_t
firstHostEdgeIndex(const json& doc)
{
    const auto& edges = doc.at("edges");
    for (std::size_t i = 0; i < edges.size(); ++i)
    {
        if (edges[i].at("src_dpid").get<std::uint64_t>() == 0)
        {
            return i;
        }
    }
    return 0;
}

/// Index of the LAST switch node in the file.
///
/// [Co-developed with claude code -- Adam]
/// FINDINGS #89 door 3. Deliberately the last switch and never the first: every door-3 case below
/// asserts that a refused file leaves `num_vertices == 0`, and a malformed FIRST node would leave
/// zero vertices even with the refusal still sitting inside the builder loop, where node N throws
/// with nodes 0..N-1 already added. A first-node case would therefore be green against the defect
/// it is supposed to be measuring. Only a node with others in front of it can tell "refused" from
/// "refused, and here is most of the graph anyway".
std::size_t
lastSwitchNodeIndex(const json& doc)
{
    const auto& nodes = doc.at("nodes");
    std::size_t found = 0;
    for (std::size_t i = 0; i < nodes.size(); ++i)
    {
        if (static_cast<int>(nodes[i].at("vertex_type").get<int>()) == 0)
        {
            found = i;
        }
    }
    return found;
}

/// Index of the last node carrying a non-empty `ecmp_groups`, for the same reason as above.
std::size_t
lastEcmpNodeIndex(const json& doc)
{
    const auto& nodes = doc.at("nodes");
    std::size_t found = 0;
    for (std::size_t i = 0; i < nodes.size(); ++i)
    {
        if (nodes[i].contains("ecmp_groups") && !nodes[i].at("ecmp_groups").empty() &&
            !nodes[i].at("ecmp_groups")[0].at("members").empty())
        {
            found = i;
        }
    }
    return found;
}

/// Index of the LAST host node in the file.
///
/// [Co-developed with claude code -- Adam]
/// FINDINGS #90 door 3d. Same reason as lastSwitchNodeIndex: the cases below assert
/// `num_vertices == 0`, and a malformed FIRST node leaves zero vertices whether the refusal came
/// before the builder or from inside it. In the shipped P4 4-host file the hosts come after all
/// ten switches, so the last host has thirteen nodes in front of it.
std::size_t
lastHostNodeIndex(const json& doc)
{
    const auto& nodes = doc.at("nodes");
    std::size_t found = 0;
    for (std::size_t i = 0; i < nodes.size(); ++i)
    {
        if (static_cast<int>(nodes[i].at("vertex_type").get<int>()) == 1)
        {
            found = i;
        }
    }
    return found;
}

/// Appends R0b's bad file `a`: one EXTRA host, `"ip": []`, that no edge names.
///
/// [Co-developed with claude code -- Adam]
/// 🔴 EMPTYING AN EXISTING HOST'S "ip" DOES NOT REPRODUCE THE DEFECT, AND THE FIRST DRAFT OF THESE
/// TESTS DID EXACTLY THAT AND WAS GREEN AGAINST IT. Every host in every shipped file is named by
/// two edges through its address, so taking the address away makes those edges resolve to nothing
/// and #61's edge door refuses the file -- for the EDGE, not for the host. Measured 2026-09-06
/// against trunk 1536ff17 with door 3d absent, verbatim:
///
///     "src_dpid" is 0, so this end is resolved by address, and no node in this file carries
///     10.0.0.4. Refusing the file: ...
///
/// The gate said the same thing from the other side: M17 (door 3d never fires) SURVIVED, because
/// that case stayed green with the door switched off. R0b's file `a` ADDED a host instead, and
/// that is the only shape that reaches the node side at all: a host nothing points at. R0b §2
/// had already written down why -- "沒有位址就沒有 edge 指得到它".
///
/// The clone keeps every field the builder reads with at(); only the identity and the address
/// change.
void
appendAddresslessHost(json& doc, const std::string& name)
{
    json host = doc.at("nodes")[lastHostNodeIndex(doc)];
    host["device_name"] = name;
    host["nickname"] = name;
    host["ip"] = json::array();
    host["mac"] = 9999;
    doc["nodes"].push_back(host);
}

/// Index of the first edge with a switch on both sides.
std::size_t
firstSwitchEdgeIndex(const json& doc)
{
    const auto& edges = doc.at("edges");
    for (std::size_t i = 0; i < edges.size(); ++i)
    {
        if (edges[i].at("src_dpid").get<std::uint64_t>() != 0 &&
            edges[i].at("dst_dpid").get<std::uint64_t>() != 0)
        {
            return i;
        }
    }
    return 0;
}

/// Every topology file this repo ships, with the mode each can be loaded in.
///
/// The five `_ipAlias4_` TESTBED files carry no `bridge_name` on their switches, which the
/// MININET branch of the loader reads with at(); they are TESTBED-only by construction.
struct ShippedFile
{
    std::string path;
    std::size_t nodes;
    std::size_t edges;
};

std::vector<ShippedFile>
shippedTopologies()
{
    std::vector<ShippedFile> files;
    const std::string dir = settingDir();
    if (dir.empty())
    {
        return files;
    }
    for (const auto& entry : std::filesystem::directory_iterator(dir))
    {
        const std::string name = entry.path().filename().string();
        if (name.rfind("StaticNetworkTopology", 0) != 0 || entry.path().extension() != ".json")
        {
            continue;
        }
        json doc;
        std::ifstream in(entry.path());
        in >> doc;
        files.push_back({entry.path().string(), doc.at("nodes").size(), doc.at("edges").size()});
    }
    std::sort(files.begin(), files.end(), [](const ShippedFile& a, const ShippedFile& b) {
        return a.path < b.path;
    });
    return files;
}

} // namespace

// =================================================================================================
// #61 -- an edge naming an endpoint that is not in the file
// =================================================================================================

TEST(TopologyInputValidationTest, AnEdgeNamingADpidNoSwitchHasIsRefused)
{
    // round5 topo/m1_host_edge_ghost_dpid.json, reproduced from the shipped file: one host
    // edge's switch side points at dpid 99, which no node declares.
    MutatedTopology topo("ghost_dpid");
    ASSERT_TRUE(topo.usable()) << "could not read " << shippedP4Topology();

    auto& edge = topo.doc()["edges"][firstHostEdgeIndex(topo.doc())];
    edge["dst_dpid"] = 99;
    edge["dst_ip"] = json::array({"192.168.123.99"});

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw)
        << "an edge whose dpid matches no switch was accepted; the kernel would serve the "
           "topology minus that cable and answer 200 to everything";
}

TEST(TopologyInputValidationTest, TheRefusalNamesTheDpidThatMatchedNothing)
{
    // The operator has to find one entry in a file with up to 138 nodes. The number is what
    // makes that possible; the wording around it is free to change.
    MutatedTopology topo("ghost_dpid_named");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstHostEdgeIndex(topo.doc())];
    edge["dst_dpid"] = 99;
    edge["dst_ip"] = json::array({"192.168.123.99"});

    const LoadOutcome out = loadFile(topo.write());

    ASSERT_TRUE(out.threw);
    EXPECT_NE(out.messageSansPath.find("99"), std::string::npos)
        << "the refusal does not name the offending dpid: " << out.message;
}

TEST(TopologyInputValidationTest, AGhostDpidEdgeLeavesNoPartiallyLoadedGraph)
{
    // 🔴 THE 40 -> 39 REPRO. Measured on :8000: nodes=14 edges=39 with 40 edges in the file.
    // A rejected input must not partially apply -- and a graph holding 39 of 40 edges is
    // exactly a partial application, whichever way the load reports itself afterwards.
    MutatedTopology topo("ghost_dpid_partial");
    ASSERT_TRUE(topo.usable());

    const std::size_t declaredEdges = topo.doc().at("edges").size();
    ASSERT_EQ(declaredEdges, 40u) << "the shipped P4 4-host file should declare 40 edges";

    auto& edge = topo.doc()["edges"][firstHostEdgeIndex(topo.doc())];
    edge["dst_dpid"] = 99;
    edge["dst_ip"] = json::array({"192.168.123.99"});

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_EQ(out.edges, 0u) << "the refused topology left " << out.edges
                             << " edges in the graph (the measured defect left 39 of 40)";
    EXPECT_EQ(out.vertices, 0u)
        << "the refused topology left " << out.vertices << " vertices in the graph";
}

TEST(TopologyInputValidationTest, AHostEdgeWhoseAddressMatchesNoNodeIsRefused)
{
    // The other half of the same lookup: `src_dpid == 0` means "resolve this side by IP".
    // An address no node carries fails the same way a ghost dpid does, and used to take the
    // same silent branch.
    MutatedTopology topo("ghost_host_ip");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstHostEdgeIndex(topo.doc())];
    edge["src_ip"] = json::array({"10.9.9.9"});

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "a host edge naming an address no node declares was accepted";
    EXPECT_EQ(out.edges, 0u) << "a refused topology must not partially apply";
}

// =================================================================================================
// #62 -- interface indices outside the range the fleet uses
// =================================================================================================

TEST(TopologyInputValidationTest, AZeroInterfaceOnTheSwitchSideIsRefused)
{
    // round5 topo/m4a_port_zero.json: edge #0's src_interface 1 -> 0, on an edge whose
    // src_dpid is a real switch. Port 0 is not a switch port in any OpenFlow version this
    // project speaks.
    MutatedTopology topo("port_zero");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstSwitchEdgeIndex(topo.doc())];
    edge["src_interface"] = 0;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "src_interface=0 on a switch was accepted and republished verbatim";
    EXPECT_EQ(out.edges, 0u) << "a refused topology must not partially apply";
}

TEST(TopologyInputValidationTest, ASixDigitInterfaceIsRefused)
{
    // round5 topo/m4b_port_six_digits.json: src_interface 1 -> 999999.
    MutatedTopology topo("port_six_digits");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstSwitchEdgeIndex(topo.doc())];
    edge["src_interface"] = 999999;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "src_interface=999999 was accepted";
    EXPECT_EQ(out.edges, 0u) << "a refused topology must not partially apply";
}

TEST(TopologyInputValidationTest, TheRefusalNamesTheInterfaceThatWasOutOfRange)
{
    MutatedTopology topo("port_named");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstSwitchEdgeIndex(topo.doc())];
    edge["src_interface"] = 999999;

    const LoadOutcome out = loadFile(topo.write());

    ASSERT_TRUE(out.threw);
    EXPECT_NE(out.messageSansPath.find("999999"), std::string::npos)
        << "the refusal does not name the offending interface: " << out.message;
}

TEST(TopologyInputValidationTest, ADestinationInterfaceIsCheckedToo)
{
    // Both ends, not just the one round 5 happened to mutate. `dst_interface` reaches
    // FlowLinkUsageCollector through the reverse-edge lookup, so it is if anything the more
    // load-bearing of the two.
    MutatedTopology topo("dst_port");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstSwitchEdgeIndex(topo.doc())];
    edge["dst_interface"] = 999999;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "dst_interface=999999 was accepted";
}

// -------------------------------------------------------------------------------------------------
// The boundary, both sides of it. These are what stop the range check from being off by one.
// -------------------------------------------------------------------------------------------------

TEST(TopologyInputValidationTest, TheLargestInRangeInterfaceIsAccepted)
{
    MutatedTopology topo("port_max");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstSwitchEdgeIndex(topo.doc())];
    edge["src_interface"] = 65535;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_FALSE(out.threw) << "65535 is in range and was refused: " << out.message;
    EXPECT_EQ(out.edges, 40u);
}

TEST(TopologyInputValidationTest, OneAboveTheLargestInRangeInterfaceIsRefused)
{
    MutatedTopology topo("port_max_plus_one");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstSwitchEdgeIndex(topo.doc())];
    edge["src_interface"] = 65536;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "65536 is one past the maximum and was accepted";
}

TEST(TopologyInputValidationTest, TheSmallestInRangeSwitchInterfaceIsAccepted)
{
    // 1 is the smallest switch port, and every shipped file uses it. A check written as
    // `<= 1` rather than `< 1` would take all thirteen of them down.
    MutatedTopology topo("port_one");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstSwitchEdgeIndex(topo.doc())];
    edge["src_interface"] = 1;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_FALSE(out.threw) << "port 1 was refused: " << out.message;
    EXPECT_EQ(out.edges, 40u);
}

TEST(TopologyInputValidationTest, AZeroInterfaceOnTheHostSideIsStillAccepted)
{
    // 🔴 THE FLEET-BREAKING MISTAKE, PINNED. The spec says the host side of a host edge carries
    // dpid 0 AND interface 0, and five shipped TESTBED files do exactly that. Rejecting port 0
    // everywhere would refuse them all -- a wider outage than #62 ever caused.
    MutatedTopology topo("host_port_zero");
    ASSERT_TRUE(topo.usable());

    auto& edge = topo.doc()["edges"][firstHostEdgeIndex(topo.doc())];
    ASSERT_EQ(edge.at("src_dpid").get<std::uint64_t>(), 0u);
    edge["src_interface"] = 0;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_FALSE(out.threw) << "the host side's documented port 0 was refused: " << out.message;
    EXPECT_EQ(out.edges, 40u) << "the host edge was dropped rather than kept";
}

// =================================================================================================
// A valid topology still loads exactly as it did. Nothing here is about the new checks; it is
// about them costing nothing.
// =================================================================================================

TEST(TopologyInputValidationTest, EveryShippedTopologyStillLoadsWithNothingDropped)
{
    // 🔴 The whole point of the two refusals above is that the graph must equal the file. This
    // asserts it against the file itself for all thirteen shipped topologies -- no golden
    // number to go stale, and it is red the moment any of them starts losing an edge.
    //
    // TESTBED for all of them: the five _ipAlias4_ files declare no `bridge_name`, which only
    // the MININET branch reads.
    const auto files = shippedTopologies();
    ASSERT_GE(files.size(), 13u) << "expected at least the 13 shipped topology files, found "
                                 << files.size() << " (settingDir=\"" << settingDir() << "\")";

    for (const auto& f : files)
    {
        const LoadOutcome out = loadFile(f.path, utils::TESTBED);
        EXPECT_FALSE(out.threw) << f.path << " no longer loads: " << out.message;
        EXPECT_EQ(out.vertices, f.nodes) << f.path << ": vertices != the file's node count";
        EXPECT_EQ(out.edges, f.edges) << f.path << ": edges != the file's edge count";
    }
}

TEST(TopologyInputValidationTest, TheTwoMininetCapableTopologiesStillLoadInMininetMode)
{
    // The mode the kernel actually runs the fabric in, for the two files `ndt up` uses.
    const std::string dir = settingDir();
    ASSERT_FALSE(dir.empty());

    for (const char* name : {"StaticNetworkTopologyP4_10Switches_4Hosts.json",
                             "StaticNetworkTopologyOVS_10Switches_4Hosts.json"})
    {
        const std::string path = dir + "/" + name;
        ASSERT_TRUE(std::filesystem::exists(path)) << path;

        json doc;
        std::ifstream in(path);
        in >> doc;

        const LoadOutcome out = loadFile(path, utils::MININET);
        EXPECT_FALSE(out.threw) << path << " no longer loads in MININET mode: " << out.message;
        EXPECT_EQ(out.vertices, doc.at("nodes").size()) << path;
        EXPECT_EQ(out.edges, doc.at("edges").size()) << path;
    }
}

// =================================================================================================
// FINDINGS #89 / W-TOPO-THREE-DOORS -- the other input paths nothing was checking.
//
// [Co-developed with claude code -- Adam]
// #61/#62 established the rule: the whole file is checked before the first add_vertex, so
// "refused" means the graph was never touched. The rule's COVERAGE was transcribed by hand, and
// three doors were left open.
//
//   door 3  Three refusals still lived inside the builder's node loop, below add_vertex's
//           position in the iteration: switch_kind, a switch with no address, and a MININET
//           switch with no bridge_name. Reached on node N they threw with nodes 0..N-1 already
//           in the graph -- the 39-of-40 shape, one door along. The three
//           *LeavesNoPartiallyLoadedGraph cases below therefore assert num_vertices == 0 and NOT
//           merely that something threw: `threw` was already true before this fix, and a suite
//           that only asserted it would have been green against the whole defect.
//
//   door 2  `ecmp_groups[].port_id` -- a switch port index, exactly like an edge's interface
//           index -- got none of the range checking #62 gave its sibling. It is a signed int
//           read straight out of the file, and validateStaticTopologyJson never looked at
//           `ecmp_groups` at all.
//
//   door 1  GraphTypes.hpp's from_json(VertexProperties) is a second, unguarded extraction path
//           that the loader deliberately does not use. Pinned below as a structural assertion,
//           not changed -- see FromJsonHasNoProductionCallers.
//
// 🔴 NONE OF THE THREE WAS OBSERVED LIVE. #61 and #62 above were measured on :8000; these were
// read out of the source and are demonstrated by these tests and by
// tests/shell/mutate_topology_input_is_validated.sh. Do not cite them as field observations.
// =================================================================================================

TEST(TopologyInputValidationTest, AMalformedSwitchKindLeavesNoPartiallyLoadedGraph)
{
    // door 3a. No shipped file declares `switch_kind` at all -- the loader falls back to
    // brand_name -- so the field has to be added to reach its throw.
    MutatedTopology topo("bad_switch_kind");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u) << "the case needs a switch with other nodes in front of it";
    topo.doc()["nodes"][victim]["switch_kind"] = "ovs_typo";

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "an unmappable switch_kind was accepted";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices
        << " vertices were already in the graph -- a partial application of a rejected file";
    EXPECT_EQ(out.edges, 0u);
}

TEST(TopologyInputValidationTest, AnAddresslessSwitchLeavesNoPartiallyLoadedGraph)
{
    // 🔴 door 3b, and the sharpest of the three: before this fix the load DID throw, and threw
    // from the builder, with every earlier switch already added. `threw` proves nothing here;
    // `vertices == 0` is the whole claim. FINDINGS #85's door, seen from the loader's side.
    MutatedTopology topo("addressless_switch");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u) << "the case needs a switch with other nodes in front of it";
    topo.doc()["nodes"][victim]["ip"] = json::array();

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "a switch with an empty \"ip\" array was accepted";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices
        << " vertices were already in the graph -- a partial application of a rejected file";
    EXPECT_EQ(out.edges, 0u);
}

TEST(TopologyInputValidationTest, AMissingBridgeNameInMininetLeavesNoPartiallyLoadedGraph)
{
    // door 3c. MININET mode only -- TESTBED never reads the field, and five shipped files that
    // never declare one must keep loading (EveryShippedTopologyStillLoadsWithNothingDropped).
    MutatedTopology topo("no_bridge_name");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u) << "the case needs a switch with other nodes in front of it";
    topo.doc()["nodes"][victim].erase("bridge_name");

    const LoadOutcome out = loadFile(topo.write(), utils::MININET);

    EXPECT_TRUE(out.threw) << "a MININET switch with no bridge_name was accepted";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices
        << " vertices were already in the graph -- a partial application of a rejected file";
    EXPECT_EQ(out.edges, 0u);
}

TEST(TopologyInputValidationTest, AMissingBridgeNameIsNotCheckedInTestbedMode)
{
    // 🔴 The control that keeps door 3c from becoming the fleet-breaking mistake M8 pins for
    // ports. The same file that must be refused under MININET must still load under TESTBED,
    // because five shipped TESTBED files declare no bridge_name on any switch.
    MutatedTopology topo("no_bridge_name_testbed");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim].erase("bridge_name");

    const LoadOutcome out = loadFile(topo.write(), utils::TESTBED);

    EXPECT_FALSE(out.threw) << "TESTBED does not read bridge_name and must not refuse it missing: "
                            << out.message;
    EXPECT_EQ(out.vertices, 14u);
}

TEST(TopologyInputValidationTest, AnOutOfRangeEcmpPortIdIsRefusedAtLoad)
{
    // door 2, the ceiling. 999999 is the value round 5 fed src_interface; the same number in an
    // ecmp member was accepted, republished, and reached the flow path.
    MutatedTopology topo("ecmp_port_huge");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastEcmpNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u) << "the case needs an ecmp-bearing switch with nodes in front of it";
    topo.doc()["nodes"][victim]["ecmp_groups"][0]["members"][0]["port_id"] = 999999;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "an ecmp port_id of 999999 was accepted";
    EXPECT_NE(out.messageSansPath.find("999999"), std::string::npos)
        << "the refusal does not name the offending value: " << out.messageSansPath;
    EXPECT_EQ(out.vertices, 0u);
}

TEST(TopologyInputValidationTest, AZeroEcmpPortIdIsRefusedAtLoad)
{
    // door 2, the floor. 🔴 Unlike an edge interface there is no host side here to exempt:
    // ecmp_groups appear only on switch nodes and every member names a switch port, so 0 is
    // never legitimate. The gate's M13 is the mutation that grants it the host-side exemption
    // anyway, and this is the case that must catch it.
    MutatedTopology topo("ecmp_port_zero");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastEcmpNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["ecmp_groups"][0]["members"][0]["port_id"] = 0;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "an ecmp port_id of 0 was accepted";
    EXPECT_EQ(out.vertices, 0u);
}

TEST(TopologyInputValidationTest, ANegativeEcmpPortIdIsRefusedAtLoad)
{
    // 🔴 `PortMember::portId` is a SIGNED int (GraphTypes.hpp:186) filled straight from the file,
    // so -1 was a value the loader would carry into the flow path. This case is what separates
    // the gate's M15 (the floor deleted, so 0 AND negatives get in) from its M16 (the host side's
    // port-0 exemption transplanted, so only 0 gets in): without it the two are indistinguishable
    // and one of them is measuring nothing.
    MutatedTopology topo("ecmp_port_negative");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastEcmpNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["ecmp_groups"][0]["members"][0]["port_id"] = -1;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "a negative ecmp port_id was accepted";
    EXPECT_EQ(out.vertices, 0u);
}

TEST(TopologyInputValidationTest, TheLargestInRangeEcmpPortIdIsAccepted)
{
    // The boundary from the other side, so the bound cannot quietly narrow to the fleet's
    // observed maximum (24, on the two HPE files). Same control M9 provides for the edge bound.
    MutatedTopology topo("ecmp_port_max");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastEcmpNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["ecmp_groups"][0]["members"][0]["port_id"] = 65535;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_FALSE(out.threw) << "65535 is in range and was refused: " << out.message;
    EXPECT_EQ(out.vertices, 14u);
    EXPECT_EQ(out.edges, 40u);
}

// -------------------------------------------------------------------------------------------------
// door 1 -- the second extraction path, pinned rather than changed.
// -------------------------------------------------------------------------------------------------

TEST(TopologyInputValidationTest, FromJsonHasNoProductionCallers)
{
    // 🔴 WHAT THIS IS FOR. GraphTypes.hpp defines from_json(json, VertexProperties&) and the
    // EdgeProperties twin, and the loader does NOT use them: TopologyAndFlowMonitor.cpp:702 and
    // DeviceConfigurationAndPowerManager.cpp both carry the call commented out above a hand
    // written field-by-field extraction. So validateStaticTopologyJson guards the hand-written
    // path and nothing guards from_json -- which is fine only for exactly as long as no
    // production code calls it. Its only live callers today are tests (test_IsUpSplit.cpp:309
    // and :339), whose assertions are deliberately left alone by this fix.
    //
    // This test is the tripwire on that "only for as long as". The day someone wires from_json
    // into the kernel, this goes red and door 1 has to be decided rather than inherited.
    //
    // Limitation, stated rather than hidden: line comments are stripped, block comments are not,
    // so a call commented out with a block comment would read as live and this test would be
    // red for the wrong reason. That direction is the safe one.
    const std::string dir = settingDir();
    ASSERT_FALSE(dir.empty()) << "cannot locate the repo from the test's working directory";
    const std::filesystem::path root =
        std::filesystem::path(dir).parent_path().empty() ? std::filesystem::path(".")
                                                         : std::filesystem::path(dir).parent_path();

    std::size_t filesScanned = 0;
    std::vector<std::string> callers;
    for (const char* subdir : {"src", "include"})
    {
        const std::filesystem::path base = root / subdir;
        ASSERT_TRUE(std::filesystem::is_directory(base)) << base.string() << " not found";
        for (const auto& entry : std::filesystem::recursive_directory_iterator(base))
        {
            if (!entry.is_regular_file())
            {
                continue;
            }
            const std::string ext = entry.path().extension().string();
            if (ext != ".cpp" && ext != ".hpp" && ext != ".h" && ext != ".cc")
            {
                continue;
            }
            ++filesScanned;
            std::ifstream in(entry.path());
            std::string line;
            std::size_t lineNo = 0;
            while (std::getline(in, line))
            {
                ++lineNo;
                const auto comment = line.find("//");
                if (comment != std::string::npos)
                {
                    line.erase(comment);
                }
                for (const char* call : {"get<VertexProperties>", "get<EdgeProperties>"})
                {
                    if (line.find(call) != std::string::npos)
                    {
                        callers.push_back(entry.path().string() + ":" + std::to_string(lineNo) +
                                          " " + call);
                    }
                }
            }
        }
    }

    ASSERT_GT(filesScanned, 50u) << "only " << filesScanned
                                 << " sources scanned -- the search, not the answer, is wrong";

    std::string found;
    for (const auto& c : callers)
    {
        found += "\n    " + c;
    }
    EXPECT_TRUE(callers.empty())
        << "from_json now has " << callers.size()
        << " production caller(s), so door 1 of FINDINGS #89 is live and the unguarded extraction "
           "path is reachable from the kernel. Decide it rather than inheriting it:"
        << found;
}

// =================================================================================================
// FINDINGS #90 / door 3d -- the HOST half of door 3b.
//
// [Co-developed with claude code -- Adam]
// 🔴 THIS ONE WAS MEASURED, unlike #89's three doors. R0b (2026-09-05,
// scratch/overnight-2026-09-05/rounds/05-R0b-postmerge2.md, bad file `a`, kernel 862c4bf8) added
// one host with `"ip": []` to the shipped OVS 4-host model and ran it: the kernel ACCEPTED the
// file with **zero** diagnostic -- 50 log lines, one `Server Listening on port 8000` -- and
// /ndt/get_graph_data served the node as `('h9', [])`. The same round's file `b`, a switch with
// the same defect, was refused with a full sentence: door 3b stops at `vertexType == SWITCH`.
//
// WHY THE FILE LAYER, WHEN #88 ALREADY GUARDED THE RUNTIME
// #88 put guards on sixteen `ip.front()` sites so an addressless node cannot take the process
// down. Its own inventory (W2-SUMMARY §2.2) then found seven more dereferences written `ip[0]`,
// **five of them on the host side and production-reachable** -- IntentTranslator.cpp:665,:702,
// LLMAgent.cpp:243, FlowLinkUsageCollector.cpp:2986,:2987 -- and did not fix them. The invariant
// those five assume holds only if no file ever declares such a host. That is this door.
//
// 🔴 AN EXISTING GREEN TEST ASSERTED THE OPPOSITE AND WAS DELIBERATELY REVERSED:
// test_SwitchKindDispatch.cpp's TopologyIpValidationTest.AHostWithNoAddressIsStillAllowed. Its
// stated reason -- "rejecting them would refuse every topology that lists hosts before discovery,
// which is all of them" -- is measurably false of the fleet: all thirteen shipped files give every
// host an address (eight give one, the five _ipAlias4_ files give four), and tools/make_topology.py
// always emits one. See doc/audit/2026-09-06_fix-host-address-door/FIX-HOST-ADDRESS-DOOR.md.
// =================================================================================================

TEST(TopologyInputValidationTest, AnAddresslessHostLeavesNoPartiallyLoadedGraph)
{
    // R0b file `a`, reproduced: one EXTRA host with `"ip": []` that no edge names. See
    // appendAddresslessHost for why emptying an existing host instead measures nothing.
    MutatedTopology topo("addressless_host");
    ASSERT_TRUE(topo.usable());

    const std::size_t before = topo.doc().at("nodes").size();
    appendAddresslessHost(topo.doc(), "h9");
    ASSERT_EQ(topo.doc().at("nodes").size(), before + 1)
        << "the case needs the addressless host to be an addition, and behind every other node";

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "a host with an empty \"ip\" array was accepted; the measured "
                              "consequence was a node served as ('h9', []) on :8000";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices
        << " vertices were already in the graph -- a partial application of a rejected file";
    EXPECT_EQ(out.edges, 0u);
}

TEST(TopologyInputValidationTest, TheAddresslessHostRefusalNamesTheHost)
{
    // 🔴 The search is for `host "h9"`, WITH the noun, not for `h9` on its own -- and that is the
    // whole point. The rethrow prefixes every message with describeTopologyItem's
    // `node #14 "h9" ip=[]`, so a search for the bare name would be satisfied by the prefix and
    // would pass with the diagnostic naming nothing. Same trap `without()` exists for at the top
    // of this file: the instrument must not be able to produce the answer.
    MutatedTopology topo("addressless_host_named");
    ASSERT_TRUE(topo.usable());

    appendAddresslessHost(topo.doc(), "h9");

    const LoadOutcome out = loadFile(topo.write());

    ASSERT_TRUE(out.threw);
    EXPECT_NE(out.messageSansPath.find("host \"h9\""), std::string::npos)
        << "the refusal does not name the offending host: " << out.messageSansPath;
}

TEST(TopologyInputValidationTest, AnExistingHostLosingItsAddressNowNamesTheHostNotTheEdge)
{
    // 🔴 THE OTHER SHAPE, AND WHY IT IS A DIAGNOSTIC CLAIM RATHER THAN AN ACCEPTANCE ONE.
    // Emptying an EXISTING host's "ip" was already refused before door 3d -- but by #61's EDGE
    // door, two doors downstream, because the two edges that name that host by address stopped
    // resolving. The operator was told `"src_dpid" is 0, ... no node in this file carries
    // 10.0.0.4`: a true sentence about the wrong entry. The node they have to edit is the host.
    //
    // Door 3d runs in the node loop, which finishes before the edge loop starts, so the same file
    // is now refused one door earlier and the message names the host. Both assertions matter: the
    // second is what stops this from passing on the old edge-door message.
    MutatedTopology topo("host_address_removed");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastHostNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    const std::string name = topo.doc()["nodes"][victim].at("device_name").get<std::string>();
    topo.doc()["nodes"][victim]["ip"] = json::array();

    const LoadOutcome out = loadFile(topo.write());

    ASSERT_TRUE(out.threw);
    EXPECT_NE(out.messageSansPath.find("host \"" + name + "\""), std::string::npos)
        << "the refusal still points at the edge rather than at the host: " << out.messageSansPath;
    EXPECT_EQ(out.messageSansPath.find("no node in this file carries"), std::string::npos)
        << "the edge door got there first, so the file is refused for the link and not for the "
           "node the operator has to edit: "
        << out.messageSansPath;
    EXPECT_EQ(out.vertices, 0u);
}

TEST(TopologyInputValidationTest, AHostWithNoIpKeyAtAllIsRefusedInPlainLanguage)
{
    // 🔴 WHAT IS RED HERE BEFORE THE FIX IS ONLY THE LAST ASSERTION. The shared
    // `at("ip")` read is inside the validator too, so a missing key already threw, already before
    // the first add_vertex -- `threw` and `vertices` were green against this defect. What the
    // operator got was `[json.exception.out_of_range.403] key 'ip' not found`: an exception class
    // where a sentence belongs. R0b recorded exactly that complaint against door 3c's
    // `bridge_name` before #89 rewrote it, and the same rewrite is owed here.
    MutatedTopology topo("host_no_ip_key");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastHostNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim].erase("ip");

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "a host with no \"ip\" key was accepted";
    EXPECT_EQ(out.vertices, 0u);
    EXPECT_EQ(out.messageSansPath.find("json.exception"), std::string::npos)
        << "the refusal is a raw nlohmann exception, not a diagnostic: " << out.messageSansPath;
}

TEST(TopologyInputValidationTest, AHostWhoseIpIsNotAnArrayIsRefusedInPlainLanguage)
{
    // The other shape of the same operator mistake: `"ip": "10.0.0.4"` instead of
    // `"ip": ["10.0.0.4"]`. nlohmann answers that with type_error.302; same rewrite.
    MutatedTopology topo("host_ip_not_array");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastHostNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["ip"] = "10.0.0.4";

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "a host whose \"ip\" is a bare string was accepted";
    EXPECT_EQ(out.vertices, 0u);
    EXPECT_EQ(out.messageSansPath.find("json.exception"), std::string::npos)
        << "the refusal is a raw nlohmann exception, not a diagnostic: " << out.messageSansPath;
}

// =================================================================================================
// FINDINGS #91 / W15 / door 3e -- a `brand_name` this build has no data plane for.
//
// [Co-developed with claude code -- Adam]
// 🔴 MEASURED, like #90 and unlike #89. R0b (2026-09-05, kernel 862c4bf8, bad file `c`) set one
// switch of the shipped all-OVS model to `brand_name = "NOT_A_REAL_KIND"`. The file was ACCEPTED
// (rc=124, i.e. the kernel was still serving when the harness gave up) and the only thing the
// operator saw was
//
//     [error] ... validateDataPlaneHomogeneity] Topology mixes data planes
//     (ovs=[1,2,3,4,5,6,8,9,10]; hardware=[7]). ... Fix the topology file, or set
//     AppConfig::ALLOW_MIXED_DATAPLANE to override.
//
// R0b's own words: the tone is a refusal and the behaviour is an admission. And the remedy it
// suggests makes the typo permanent -- ALLOW_MIXED_DATAPLANE turns every misspelled brand into a
// hardware switch by consent.
//
// 🔴 THE MIXED-DATA-PLANE PATH IS NOT REMOVED, AND MUST NOT BE. Mixed fabrics are a supported
// opt-in with a flag, a manual section and a unit test of their own
// (setting/AppConfig.hpp.example:15, doc/2026-07-27_p4_bmv2_support_plan.md:213,
// test_SFlowEmitterRoundtrip.cpp's AMixedTopologyDoesNotUseIdentity). What changes is that a typo
// can no longer REACH that message: validateDataPlaneHomogeneity runs at the end of the builder,
// door 3e in the node loop before it. `vertices == 0` below is what pins that ordering, and it is
// the whole of the "drop the ALLOW_MIXED_DATAPLANE advice" half of this fix.
// =================================================================================================

TEST(TopologyInputValidationTest, AnUnknownBrandNameLeavesNoPartiallyLoadedGraph)
{
    // R0b file `c`, reproduced from the shipped file.
    MutatedTopology topo("unknown_brand");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u) << "the case needs a switch with other nodes in front of it";
    topo.doc()["nodes"][victim]["brand_name"] = "NOT_A_REAL_KIND";

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "an unknown brand_name was accepted and mapped to hardware";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices
        << " vertices were already in the graph -- and a graph that reaches "
           "validateDataPlaneHomogeneity is a graph that gets told to set ALLOW_MIXED_DATAPLANE";
    EXPECT_EQ(out.edges, 0u);
}

TEST(TopologyInputValidationTest, AFabricEntirelyOfAnUnknownBrandIsStillRefused)
{
    // 🔴 THIS EXISTS BECAUSE TWO DOORS STARTED OVERLAPPING, AND THE GATE SAID SO FIRST.
    // AnUnknownBrandNameLeavesNoPartiallyLoadedGraph above reproduces R0b's measured file: ONE
    // switch of a homogeneous fabric given a brand nothing knows. Since BUG-17 that file has two
    // things wrong with it -- the brand, and the data-plane MIXTURE the brand causes, because an
    // unrecognised brand maps to HARDWARE and the other nine switches are BMv2 -- and the mixture
    // is now refused before the first add_vertex too. So switching door 3e off no longer changes
    // whether that file loads, only which sentence the operator gets, and
    // mutate_topology_input_is_validated.sh's M21 SURVIVED against it on 2026-09-07.
    //
    // Making EVERY switch the unknown brand takes the mixture away -- all ten map to HARDWARE,
    // one kind -- so door 3e is the only thing left that can refuse the file. This is the case
    // M21 is scored on now, and it is a stricter one: it fails if door 3e stops refusing, and it
    // cannot be rescued by any other door.
    MutatedTopology topo("unknown_brand_whole_fabric");
    ASSERT_TRUE(topo.usable());

    for (auto& node : topo.doc()["nodes"])
    {
        if (node.at("vertex_type").get<int>() == 0)
        {
            node["brand_name"] = "NOT_A_REAL_KIND";
        }
    }

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "a fabric of switches this build has no data plane for was accepted";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices << " vertices were in the graph";
    EXPECT_NE(out.messageSansPath.find("NOT_A_REAL_KIND"), std::string::npos)
        << "the refusal does not name the brand, so it is not door 3e refusing: "
        << out.messageSansPath;
}

TEST(TopologyInputValidationTest, TheUnknownBrandRefusalNamesTheBrandAndTheAcceptedOnes)
{
    // Two claims, and the second is the one the ticket asked for: the message has to say what IS
    // accepted, because "unknown" without a list leaves the operator guessing at a spelling.
    // Searching for the offending value is honest here -- describeTopologyItem's prefix carries
    // device_name, nickname, ip and the edge dpids, and never brand_name.
    MutatedTopology topo("unknown_brand_named");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["brand_name"] = "NOT_A_REAL_KIND";

    const LoadOutcome out = loadFile(topo.write());

    ASSERT_TRUE(out.threw);
    EXPECT_NE(out.messageSansPath.find("NOT_A_REAL_KIND"), std::string::npos)
        << "the refusal does not name the offending brand: " << out.messageSansPath;
    for (const char* accepted : {"OVS", "BMv2", "HPE5520", "BrocadeICX6610", "BrocadeICX7250"})
    {
        EXPECT_NE(out.messageSansPath.find(accepted), std::string::npos)
            << "the refusal does not list " << accepted << " as an accepted brand: "
            << out.messageSansPath;
    }
}

TEST(TopologyInputValidationTest, TheUnknownBrandRefusalDoesNotSuggestAllowingMixedDataPlanes)
{
    // 🔴 R0b's complaint, pinned. The old diagnostic for this file was the data-plane-mixture
    // ERROR, whose remedy is `set AppConfig::ALLOW_MIXED_DATAPLANE to override` -- advice that
    // would silence a TYPO rather than fix it. The refusal that replaces it must not carry the
    // same advice forward.
    //
    // Stated plainly: this assertion cannot go red against the pre-fix tree, because pre-fix
    // there was no refusal at all. Its evidence is the gate's M24, which puts the advice back into
    // the new message and must be caught here.
    MutatedTopology topo("unknown_brand_no_mixed_advice");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["brand_name"] = "NOT_A_REAL_KIND";

    const LoadOutcome out = loadFile(topo.write());

    ASSERT_TRUE(out.threw);
    EXPECT_EQ(out.messageSansPath.find("ALLOW_MIXED_DATAPLANE"), std::string::npos)
        << "the refusal for a misspelled brand tells the operator to allow mixed data planes, "
           "which would make the typo permanent: "
        << out.messageSansPath;
}

TEST(TopologyInputValidationTest, ASwitchWithNoBrandNameIsRefusedInPlainLanguage)
{
    // Same shape as door 3d's two message cases: already refused -- by the BUILDER's
    // at("brand_name"), with nodes 0..N-1 in the graph -- and reported as an exception class.
    // Both halves move here: `vertices == 0` and a sentence.
    MutatedTopology topo("switch_no_brand");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim].erase("brand_name");

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "a switch with no brand_name was accepted";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices << " vertices were in the graph";
    EXPECT_EQ(out.messageSansPath.find("json.exception"), std::string::npos)
        << "the refusal is a raw nlohmann exception, not a diagnostic: " << out.messageSansPath;
}

TEST(TopologyInputValidationTest, EveryBrandTheShippedFleetNamesIsAccepted)
{
    // 🔴 THE FLEET-BREAKING CONTROL, and it derives its expectation from the fleet rather than
    // repeating the list the fix hard-codes -- otherwise it would be the same claim written
    // twice. Eight shipped files are OVS, two BMv2, and five TESTBED files carry HPE5520,
    // BrocadeICX7250 and BrocadeICX6610. A list narrowed to the two virtual kinds would refuse
    // five of thirteen shipped topologies: the M8/M13 shape, on brands.
    std::vector<std::string> brands;
    for (const auto& f : shippedTopologies())
    {
        json doc;
        std::ifstream in(f.path);
        in >> doc;
        for (const auto& node : doc.at("nodes"))
        {
            if (node.at("vertex_type").get<int>() != 0)
            {
                continue;
            }
            const auto brand = node.at("brand_name").get<std::string>();
            if (std::find(brands.begin(), brands.end(), brand) == brands.end())
            {
                brands.push_back(brand);
            }
        }
    }
    std::sort(brands.begin(), brands.end());
    ASSERT_EQ(brands.size(), 5u)
        << "the shipped fleet no longer names five distinct switch brands; if a topology file was "
           "added, kAcceptedSwitchBrands has to learn its brand too";

    for (const auto& brand : brands)
    {
        // Every switch, not one: one switch of a different kind is a MIXED topology, which is a
        // different subject (and a supported one) and would test the homogeneity path instead.
        MutatedTopology topo("fleet_brand");
        ASSERT_TRUE(topo.usable());
        for (auto& node : topo.doc()["nodes"])
        {
            if (node.at("vertex_type").get<int>() == 0)
            {
                node["brand_name"] = brand;
            }
        }

        const LoadOutcome out = loadFile(topo.write());

        EXPECT_FALSE(out.threw) << "a fabric of " << brand << " switches was refused: "
                                << out.message;
        EXPECT_EQ(out.vertices, 14u) << brand;
        EXPECT_EQ(out.edges, 40u) << brand;
    }
}

TEST(TopologyInputValidationTest, AHostBrandNameIsNotChecked)
{
    // 🔴 The control on the `vertexType == SWITCH` guard. Every host in every shipped file carries
    // `"brand_name": ""` -- 1144 of them across this repository -- and nothing dispatches on a
    // host's brand. A check written for "every node" would refuse all thirteen files at once.
    MutatedTopology topo("host_brand");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastHostNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["brand_name"] = "NOT_A_REAL_KIND";

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_FALSE(out.threw) << "a host's brand_name is not a data plane and must not be checked: "
                            << out.message;
    EXPECT_EQ(out.vertices, 14u);
}

TEST(TopologyInputValidationTest, TheAcceptedBrandListCoversEveryBrandTheCodeBranchesOn)
{
    // 🔴 WHAT THIS IS FOR, AND HOW IT CHANGED ON 2026-09-07. Until W15-1(b) the accepted list
    // lived in TopologyAndFlowMonitor.cpp while the code that behaves differently per brand lived
    // in two other files -- GraphTypes.hpp's switchKindFromBrandName and
    // DeviceConfigurationAndPowerManager.cpp's HPE5520 branches -- so this test's job was to
    // notice that two copies of one truth had drifted apart. They are one copy now: five named
    // constants in GraphTypes.hpp, an array built from them, and every comparison naming one.
    // Drift is a compile error, so what is left to check is the way back INTO two copies:
    //
    //   1. the array must list exactly the five constants, not four of them and a stray literal;
    //   2. no brand comparison anywhere in those two files may be written as a bare string
    //      literal the loader would then refuse.
    //
    // (2) is the one that matters. Adding `brandName == "CiscoC9300"` to the power manager
    // compiles, works, and teaches half the kernel about a switch the loader will not admit --
    // which is the exact shape of the pre-2026-09-07 defect, reachable again through the one door
    // single-sourcing does not close.
    //
    // Textual, like FromJsonHasNoProductionCallers, and with the same limitation stated rather
    // than hidden: it reads `brandName ==` / `brandName !=` comparisons. A brand reached some
    // other way (a map lookup, a substring test) is invisible to it, which is why the count of
    // sites it managed to find is asserted rather than assumed.
    const std::string dir = settingDir();
    ASSERT_FALSE(dir.empty());
    const std::filesystem::path root =
        std::filesystem::path(dir).parent_path().empty() ? std::filesystem::path(".")
                                                         : std::filesystem::path(dir).parent_path();
    const std::filesystem::path graphTypes = root / "include/common_types/GraphTypes.hpp";
    const std::filesystem::path powerManager =
        root / "src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp";

    /// Everything on `line` before a `//`, so a comment cannot be read as code.
    const auto codeOf = [](std::string line) {
        const auto comment = line.find("//");
        return comment == std::string::npos ? line : line.substr(0, comment);
    };

    // 1. The five constants, name -> value, read out of the header.
    std::vector<std::pair<std::string, std::string>> brands;
    {
        std::ifstream in(graphTypes);
        ASSERT_TRUE(in.good()) << "cannot read " << graphTypes;
        std::string line;
        while (std::getline(in, line))
        {
            const std::string code = codeOf(line);
            const auto at = code.find("inline constexpr std::string_view kBrand");
            if (at == std::string::npos)
            {
                continue;
            }
            const auto nameStart = code.find("kBrand", at);
            const auto nameEnd = code.find(' ', nameStart);
            const auto open = code.find('"', nameEnd);
            const auto close = code.find('"', open + 1);
            ASSERT_NE(close, std::string::npos) << line;
            brands.emplace_back(code.substr(nameStart, nameEnd - nameStart),
                                code.substr(open + 1, close - open - 1));
        }
    }
    ASSERT_EQ(brands.size(), 5u)
        << "could not read the five kBrand* constants out of GraphTypes.hpp -- the search, not "
           "the answer, is what failed";

    // 2. The array must list exactly those five names.
    std::vector<std::string> listed;
    {
        std::ifstream in(graphTypes);
        ASSERT_TRUE(in.good());
        std::string line;
        bool inList = false;
        while (std::getline(in, line))
        {
            const std::string code = codeOf(line);
            if (code.find("kAcceptedSwitchBrands{") != std::string::npos)
            {
                inList = true;
                continue;
            }
            if (!inList)
            {
                continue;
            }
            if (code.find("};") != std::string::npos)
            {
                break;
            }
            const auto at = code.find("kBrand");
            if (at == std::string::npos)
            {
                EXPECT_EQ(code.find_first_not_of(" \t"), std::string::npos)
                    << "kAcceptedSwitchBrands carries an entry that is not one of the named "
                       "constants, which is a second spelling of a brand: "
                    << line;
                continue;
            }
            const auto end = code.find_first_of(",} \t", at);
            listed.push_back(code.substr(at, end - at));
        }
    }
    std::vector<std::string> names;
    for (const auto& [name, value] : brands)
    {
        names.push_back(name);
    }
    std::sort(names.begin(), names.end());
    std::sort(listed.begin(), listed.end());
    EXPECT_EQ(listed, names)
        << "kAcceptedSwitchBrands and the kBrand* constants have come apart; a constant the array "
           "does not list is a brand the code can branch on and the loader will refuse";

    // 3. Every brand comparison in the mapping and in the power manager.
    std::vector<std::string> literalBrands;
    std::vector<std::string> namedBrands;
    for (const auto& file : {graphTypes, powerManager})
    {
        std::ifstream in(file);
        ASSERT_TRUE(in.good()) << file;
        std::string line;
        while (std::getline(in, line))
        {
            const std::string code = codeOf(line);
            for (const char* op : {"brandName == ", "brandName != "})
            {
                for (auto at = code.find(op); at != std::string::npos;
                     at = code.find(op, at + 1))
                {
                    const auto start = at + std::string(op).size();
                    if (code[start] == '"')
                    {
                        const auto close = code.find('"', start + 1);
                        if (close == std::string::npos)
                        {
                            continue;
                        }
                        literalBrands.push_back(code.substr(start + 1, close - start - 1));
                    }
                    else if (code.compare(start, 6, "kBrand") == 0)
                    {
                        const auto end = code.find_first_of(")|& \t,;", start);
                        namedBrands.push_back(code.substr(start, end - start));
                    }
                }
            }
        }
    }
    ASSERT_GE(literalBrands.size() + namedBrands.size(), 8u)
        << "found only " << literalBrands.size() + namedBrands.size()
        << " brand comparisons in the mapping and the power manager -- the search, not the "
           "answer, is wrong, and a tripwire that cannot find its sites is not a tripwire";

    for (const auto& brand : literalBrands)
    {
        // A literal is not forbidden, but it must name a brand the loader admits. One that does
        // not is the pre-2026-09-07 defect written by hand.
        bool known = false;
        for (const auto& [name, value] : brands)
        {
            known = known || value == brand;
        }
        EXPECT_TRUE(known) << "the code branches on brand_name \"" << brand
                           << "\" written as a bare literal, and the loader refuses that brand: "
                              "the comparison and the accepted list have come apart";
    }
    for (const auto& used : namedBrands)
    {
        EXPECT_NE(std::find(names.begin(), names.end(), used), names.end())
            << "a brand comparison names the constant " << used
            << ", which kAcceptedSwitchBrands does not list";
    }
}

// =================================================================================================
// W15-2 -- the `switch_kind` exemption, and the mark it costs
//
// [Co-developed with claude code -- Adam]
// 🔴 THIS REVERSES HALF OF #91 ON PURPOSE, AND THE RULING SAID SO. #91 refused every
// unrecognised `brand_name`; its own §5 wrote down the price ("a Cisco, an Arista -- one line of
// C++ before the topology loads at all") and asked. Adam ruled on 2026-09-06 (grill §4D round 3):
// exempt a node that declares an explicit, legal `switch_kind`, AND record in the graph and in
// the manual that such a machine's power and telemetry are nobody's job.
//
// So there are two claims here and they fail differently:
//   - the file loads                              (threw == false, 14 vertices, 40 edges)
//   - and the switch is marked unmanaged          (power_path / telemetry_path == "none")
// A fix that did the first without the second would be #91's silent fallback with extra steps,
// which is why the mark has cases of its own rather than being asserted as an aside.
//
// ⚠️ EVERY CASE BELOW KEEPS THE FABRIC HOMOGENEOUS, AND THAT IS NOT DECORATION. The shipped P4
// model is all-BMv2; giving ONE switch `"switch_kind": "hardware"` would make it a mixed data
// plane, which is a different subject with a flag and a manual section of its own -- and which
// the very next branch (BUG-17) turns into a refusal. A case that mixed planes would then be
// measuring that instead, and would flip red for a reason that has nothing to do with W15-2.
// =================================================================================================

TEST(TopologyInputValidationTest, AnUnknownBrandWithAnExplicitSwitchKindIsAccepted)
{
    // The operator this ruling is for: a fabric of a model this build has never heard of, said
    // out loud in the key that exists for saying it. Every switch, so the data plane stays one
    // kind -- this is what a Cisco lab would actually look like.
    MutatedTopology topo("unknown_brand_exempt");
    ASSERT_TRUE(topo.usable());

    for (auto& node : topo.doc()["nodes"])
    {
        if (node.at("vertex_type").get<int>() == 0)
        {
            node["brand_name"] = "CiscoC9300";
            node["switch_kind"] = "hardware";
        }
    }

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_FALSE(out.threw)
        << "a switch that declares its data plane explicitly was still refused for its brand: "
        << out.message;
    EXPECT_EQ(out.vertices, 14u);
    EXPECT_EQ(out.edges, 40u);
}

TEST(TopologyInputValidationTest, TheExemptedSwitchIsMarkedAsHavingNoPowerOrTelemetryPath)
{
    // 🔴 THE CONDITION ADAM ATTACHED TO THE EXEMPTION. Loading is only half of it: the graph has
    // to say that nobody manages this machine, or the exemption reads as support for a switch
    // this build has no OID, no login and no plug logic for.
    MutatedTopology topo("unknown_brand_exempt_mark");
    ASSERT_TRUE(topo.usable());

    for (auto& node : topo.doc()["nodes"])
    {
        if (node.at("vertex_type").get<int>() == 0)
        {
            node["brand_name"] = "CiscoC9300";
            node["switch_kind"] = "hardware";
        }
    }

    const LoadOutcome out = loadFile(topo.write());
    ASSERT_FALSE(out.threw) << out.message;

    const auto sw = switchWithDpid(out, 1);
    ASSERT_TRUE(sw.has_value()) << "dpid 1 is not in the graph";
    EXPECT_EQ(sw->powerPath, "none")
        << "a switch admitted only by its switch_kind is reported as having a power path; this "
           "build has no branch written for brand \"CiscoC9300\"";
    EXPECT_EQ(sw->telemetryPath, "none")
        << "a switch admitted only by its switch_kind is reported as having a telemetry path";
}

TEST(TopologyInputValidationTest, TheExemptionIsPerNodeAndDoesNotUnmarkItsNeighbours)
{
    // The mark is a property of one switch's brand, not of the file. One node gets an unknown
    // brand and `"switch_kind": "p4"` -- which keeps this all-BMv2 model homogeneous -- and the
    // switches beside it must keep the path their own brand really has.
    MutatedTopology topo("unknown_brand_exempt_one");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    const auto victimDpid = topo.doc()["nodes"][victim].at("dpid").get<std::uint64_t>();
    topo.doc()["nodes"][victim]["brand_name"] = "CiscoC9300";
    topo.doc()["nodes"][victim]["switch_kind"] = "p4";

    const LoadOutcome out = loadFile(topo.write());
    ASSERT_FALSE(out.threw) << out.message;
    ASSERT_EQ(out.vertices, 14u);

    const auto exempted = switchWithDpid(out, victimDpid);
    ASSERT_TRUE(exempted.has_value());
    EXPECT_EQ(exempted->powerPath, "none");
    EXPECT_EQ(exempted->telemetryPath, "none");

    const auto neighbour = switchWithDpid(out, 1);
    ASSERT_TRUE(neighbour.has_value());
    ASSERT_EQ(neighbour->brandName, "BMv2") << "the shipped P4 model is all-BMv2";
    EXPECT_EQ(neighbour->powerPath, "synthetic")
        << "an untouched BMv2 switch lost its power path when a neighbour was exempted";
}

TEST(TopologyInputValidationTest, EveryAcceptedBrandCarriesAPowerPathThatIsNotNone)
{
    // 🔴 THE CONTROL THAT GIVES "none" ITS MEANING. If an accepted brand were also marked
    // unmanaged, the mark would say nothing about the exempted switch -- it would just be what
    // every switch says. The five values are written out here rather than derived from the
    // fleet, unlike EveryBrandTheShippedFleetNamesIsAccepted: this test's subject IS the
    // mapping's table, so reading the table back out of the source would make the instrument
    // produce the answer.
    for (const char* brand : {"OVS", "BMv2", "HPE5520", "BrocadeICX6610", "BrocadeICX7250"})
    {
        MutatedTopology topo("accepted_brand_path");
        ASSERT_TRUE(topo.usable());
        for (auto& node : topo.doc()["nodes"])
        {
            if (node.at("vertex_type").get<int>() == 0)
            {
                node["brand_name"] = brand;
            }
        }

        const LoadOutcome out = loadFile(topo.write());
        ASSERT_FALSE(out.threw) << brand << ": " << out.message;

        const auto sw = switchWithDpid(out, 1);
        ASSERT_TRUE(sw.has_value()) << brand;
        EXPECT_NE(sw->powerPath, "none")
            << "brand " << brand
            << " is on the accepted list but is reported as having no power path, which makes "
               "\"none\" useless as the mark of an unsupported switch";
    }
}

TEST(TopologyInputValidationTest, TheStaticTopologyEndpointPublishesTheUnmanagedMark)
{
    // A mark only the graph knows is a mark no operator can read. Manual section 38 documents
    // these two keys on /ndt/get_static_topology_json, so the endpoint is asserted, not assumed.
    MutatedTopology topo("unknown_brand_exempt_served");
    ASSERT_TRUE(topo.usable());
    for (auto& node : topo.doc()["nodes"])
    {
        if (node.at("vertex_type").get<int>() == 0)
        {
            node["brand_name"] = "CiscoC9300";
            node["switch_kind"] = "hardware";
        }
    }

    auto graph = std::make_shared<Graph>();
    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, utils::TESTBED};
    ASSERT_NO_THROW(monitor.load(topo.write()));

    const json served = monitor.getStaticTopologyJson();
    ASSERT_TRUE(served.contains("nodes"));

    std::size_t switchesSeen = 0;
    for (const auto& node : served.at("nodes"))
    {
        if (node.at("vertex_type").get<int>() != 0)
        {
            EXPECT_FALSE(node.contains("power_path"))
                << "a host has no brand, no plug and no OID; publishing a path for one invites "
                   "the reading that some other host might have a real one";
            continue;
        }
        ++switchesSeen;
        ASSERT_TRUE(node.contains("power_path")) << node.dump();
        EXPECT_EQ(node.at("power_path").get<std::string>(), "none");
        EXPECT_EQ(node.at("telemetry_path").get<std::string>(), "none");
    }
    EXPECT_EQ(switchesSeen, 10u) << "the shipped P4 model has ten switches";
}

TEST(TopologyInputValidationTest, TheUnknownBrandRefusalSaysHowToModelAnUnsupportedSwitch)
{
    // The refusal is now also the documentation of the way out: a reader who has a switch this
    // build cannot drive must be able to learn from the message itself that declaring a
    // switch_kind admits the file, and what that costs.
    MutatedTopology topo("unknown_brand_escape_hatch");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["brand_name"] = "NOT_A_REAL_KIND";

    const LoadOutcome out = loadFile(topo.write());

    ASSERT_TRUE(out.threw);
    EXPECT_NE(out.messageSansPath.find("switch_kind"), std::string::npos)
        << "the refusal does not mention the one key that would let this file load: "
        << out.messageSansPath;
    EXPECT_NE(out.messageSansPath.find("power_path"), std::string::npos)
        << "the refusal offers the exemption without naming what it costs: "
        << out.messageSansPath;
}

TEST(TopologyInputValidationTest, ASwitchWithASwitchKindStillNeedsABrandName)
{
    // 🔴 THE EXEMPTION IS ABOUT WHICH BRANDS ARE ACCEPTED, NOT ABOUT WHETHER A BRAND IS NEEDED,
    // and the two are one `&&` apart. The builder reads `brand_name` with at(), so a switch
    // without one throws a raw nlohmann exception from a line the operator cannot place -- the
    // exact defect doors 3c, 3d and 3e were each written to remove. Declaring a switch_kind must
    // not buy a way past that.
    MutatedTopology topo("switch_kind_without_brand");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim].erase("brand_name");
    topo.doc()["nodes"][victim]["switch_kind"] = "p4";

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "a switch with no brand_name was accepted because it named a kind";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices << " vertices were in the graph";
    EXPECT_EQ(out.messageSansPath.find("json.exception"), std::string::npos)
        << "the refusal is a raw nlohmann exception, not a diagnostic: " << out.messageSansPath;
}

TEST(TopologyInputValidationTest, AnUnknownBrandWithAMalformedSwitchKindIsStillRefused)
{
    // 🔴 A CONTROL, AND ITS LIMIT IS STATED RATHER THAN HIDDEN. `"switch_kind": "cisco"` is a
    // second typo, not an escape hatch, and the file must not load. What refuses it, TODAY, is
    // door 3a -- switchKindFromString throws twenty lines above door 3e -- so this case does not
    // exercise declaresLegalSwitchKind's own strictness, and no mutation in
    // mutate_topology_input_is_validated.sh claims that it does. That strictness is written
    // anyway, because "unreachable because of the order of two checks" is not a property anyone
    // maintains; see the predicate's comment.
    MutatedTopology topo("unknown_brand_bad_kind");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["brand_name"] = "CiscoC9300";
    topo.doc()["nodes"][victim]["switch_kind"] = "cisco";

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw) << "an unknown brand was admitted on a switch_kind that names nothing";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices << " vertices were in the graph";
}

// =================================================================================================
// BUG-17 -- a topology that mixes data planes, refused instead of merely reported
//
// [Co-developed with claude code -- Adam]
// 🔴 MEASURED, AND THE MEASUREMENT IS THE WHOLE POINT. R6 (2026-09-05,
// doc/audit/2026-09-02_manual-usertest/run-06-opus/BUGS.md, BUG-17) copied the shipped P4 model,
// changed one switch's brand_name from BMv2 to OVS, and ran the kernel:
//
//     validateDataPlaneHomogeneity] Topology mixes data planes (ovs=[1]; bmv2=[2,3,4,5,6,7,8,9,10]).
//     ... Fix the topology file, or set AppConfig::ALLOW_MIXED_DATAPLANE to override.
//     LISTEN 0 4096 0.0.0.0:8000 ...   :8000 open -- it did NOT refuse
//     nodes 14 edges 40   switch brands: ['BMv2', 'OVS']
//
// The function returned a bool and the loader called it as a statement. Three shipped pages said
// the kernel "refuses to load" such a file; the log's tone said so too; nothing did.
//
// TWO CLAIMS, AND A THIRD THAT IS EASY TO BREAK WHILE FIXING THEM:
//   - a genuine mixture is refused, and refused whole (vertices == 0, like doors 2 and 3a-3e)
//   - the refusal names both planes and their dpids, because "mixed" without the sets leaves an
//     operator diffing a 138-node file by eye
//   - and ALLOW_MIXED_DATAPLANE still works, because mixed fabrics are a supported opt-in with a
//     flag, a manual section and a unit test of their own -- a fix that quietly removed them
//     would be a bigger regression than the defect
// =================================================================================================

TEST(TopologyInputValidationTest, AMixedDataPlaneTopologyIsRefusedAtLoad)
{
    // R6's file, reproduced: the shipped all-BMv2 model with one switch made OVS.
    MutatedTopology topo("mixed_dataplane");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u) << "the case needs a switch with other nodes in front of it";
    topo.doc()["nodes"][victim]["brand_name"] = "OVS";

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw)
        << "a topology mixing OVS and BMv2 switches was accepted; the measured consequence was "
           "an [error] line and :8000 answering with the mixed model";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices
        << " vertices were already in the graph -- refusing at the end of the builder would be "
           "the partial application doors 2 and 3a-3e exist to abolish";
    EXPECT_EQ(out.edges, 0u);
}

TEST(TopologyInputValidationTest, TheMixedDataPlaneRefusalNamesBothPlanesAndTheirDpids)
{
    // The half of the old ERROR line that was worth keeping. R6 called the message "excellent"
    // and the behaviour a lie; this pins the message onto the behaviour.
    MutatedTopology topo("mixed_dataplane_named");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    const auto victimDpid = topo.doc()["nodes"][victim].at("dpid").get<std::uint64_t>();
    topo.doc()["nodes"][victim]["brand_name"] = "OVS";

    const LoadOutcome out = loadFile(topo.write());

    ASSERT_TRUE(out.threw);
    EXPECT_NE(out.messageSansPath.find("ovs=["), std::string::npos)
        << "the refusal does not name the OVS side: " << out.messageSansPath;
    EXPECT_NE(out.messageSansPath.find("bmv2=["), std::string::npos)
        << "the refusal does not name the BMv2 side: " << out.messageSansPath;
    EXPECT_NE(out.messageSansPath.find(std::to_string(victimDpid)), std::string::npos)
        << "the refusal does not say which switch is the odd one out: " << out.messageSansPath;
}

TEST(TopologyInputValidationTest, AMixedDataPlaneTopologyLoadsWhenTheFlagIsSet)
{
    // 🔴 THE CONTROL THAT KEEPS THIS FIX FROM BEING A FEATURE REMOVAL. Mixed fabrics are a
    // supported opt-in: setting/AppConfig.hpp.example:15, doc/2026-07-27_p4_bmv2_support_plan.md,
    // and test_SFlowEmitterRoundtrip's AMixedTopologyDoesNotUseIdentity, which exists precisely
    // because the port mapping has to cope with one. The refusal above must be the default, not
    // the only behaviour -- and before BUG-17 this claim could not be asserted at all, because
    // AppConfig::ALLOW_MIXED_DATAPLANE is a constexpr bool.
    MutatedTopology topo("mixed_dataplane_allowed");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastSwitchNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    topo.doc()["nodes"][victim]["brand_name"] = "OVS";

    const LoadOutcome out = loadFile(topo.write(), utils::TESTBED, /*allowMixed=*/true);

    EXPECT_FALSE(out.threw) << "the opt-in no longer admits a mixed topology: " << out.message;
    EXPECT_EQ(out.vertices, 14u);
    EXPECT_EQ(out.edges, 40u);
}

// =================================================================================================
// E-26 -- a topology that declares no switch at all, refused through the same door
//
// [Co-developed with claude code -- Adam]
// 🔴 THIS ASSERTION WAS REVERSED ON 2026-09-07, ONE DAY AFTER IT WAS WRITTEN, BY RULING. The case
// below used to be `ASwitchlessTopologyIsNotWhatThisRefuses` and asserted the opposite:
//
//     EXPECT_FALSE(out.threw)
//         << "a topology with no switches was refused; BUG-17 was about a MIXTURE, and widening
//            it to cover this is a policy change nobody ruled on";
//
// That was correct on its own terms -- BUG-17 refused a MIXTURE, and its author declined to widen
// the refusal to a question nobody had answered -- and the gate's M31 existed to hold the line at
// exactly one character (`> 1`, not `!= 1`). Adam then answered the question (grill Section 4E,
// E-26, scratch/overnight-2026-09-05/DECISIONS.md:266), against the recommendation: refuse it.
//
// So both the case and its mutation are inverted, deliberately and together. M31 now puts BUG-17's
// own behaviour back -- at BOTH layers, because E-26 also widened the builder's backstop and one
// site is not enough to restore it -- and must go RED. M32 removes only the document-level door
// and is red on `vertices == 4` instead of on `threw`: the backstop still refuses, from the end of
// the builder, with every host already in the graph. W8 and W9 still prove these cases measure
// which topologies are refused rather than how the conditions are spelled.
//
// WHAT IS CLAIMED
//   - a document with hosts and no switch is refused, and refused whole (vertices == 0)
//   - the refusal names the file, says the file "declares no switch node", and says it is
//     refusing -- the three things the ruling asked the operator to be told
//   - and it is refused even under ALLOW_MIXED_DATAPLANE, because that flag is an opt-in to
//     running two data planes and says nothing about running none
// =================================================================================================

namespace
{

/// The shipped P4 model with every switch node -- and therefore every edge -- taken out.
/// Returns how many nodes are left, so each case can assert it kept a real fabric's worth of hosts
/// rather than silently testing an empty file.
///
/// [Co-developed with claude code -- Adam]
/// Built from the shipped file rather than written by hand so that the ONLY thing wrong with it is
/// the missing switches: every host keeps its addresses, its vertex_type and its ecmp field, so a
/// refusal cannot be coming from door 3d or from #61's edge check instead.
std::size_t
stripEverySwitch(MutatedTopology& topo)
{
    json hostsOnly = json::array();
    for (const auto& node : topo.doc().at("nodes"))
    {
        if (node.at("vertex_type").get<int>() != 0)
        {
            hostsOnly.push_back(node);
        }
    }
    topo.doc()["nodes"] = hostsOnly;
    topo.doc()["edges"] = json::array(); // every edge named a switch that is no longer here
    return hostsOnly.size();
}

} // namespace

TEST(TopologyInputValidationTest, ASwitchlessTopologyIsRefusedAtLoad)
{
    MutatedTopology topo("switchless");
    ASSERT_TRUE(topo.usable());
    ASSERT_EQ(stripEverySwitch(topo), 4u) << "the shipped P4 model has four hosts";

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_TRUE(out.threw)
        << "a topology declaring no switch was accepted: every control this kernel has is "
           "addressed by dpid, so :8000 would answer about a fabric of zero switches as though "
           "that were an observation";
    EXPECT_EQ(out.vertices, 0u)
        << "the file was refused only after " << out.vertices
        << " host vertices were already in the graph -- E-26 goes through BUG-17's door, which "
           "sits before the first add_vertex";
    EXPECT_EQ(out.edges, 0u);
}

TEST(TopologyInputValidationTest, TheSwitchlessRefusalNamesTheFileAndWhatIsMissing)
{
    // 🔴 THE WORDING IS PINNED HERE AND NOWHERE ELSE IN THIS FILE, AND THAT IS THE RULING'S DOING.
    // Every other refusal below asserts that the offending NUMBER reaches the operator and leaves
    // the prose free (see W2 in the gate). E-26 named the three things this one has to say -- the
    // file, "declares no switch node", and that it is refusing -- so those three are asserted, and
    // nothing else about the sentence is.
    MutatedTopology topo("switchless_message");
    ASSERT_TRUE(topo.usable());
    ASSERT_EQ(stripEverySwitch(topo), 4u);

    const std::string path = topo.write();
    const LoadOutcome out = loadFile(path);

    ASSERT_TRUE(out.threw);
    EXPECT_NE(out.message.find(path), std::string::npos)
        << "the refusal does not name the file it refused: " << out.message;
    EXPECT_NE(out.messageSansPath.find("declares no switch node"), std::string::npos)
        << "the refusal does not say what is missing: " << out.messageSansPath;
    EXPECT_NE(out.messageSansPath.find("Refusing"), std::string::npos)
        << "the refusal does not say it is refusing -- which is the whole of BUG-17: a sentence "
           "in the voice of a refusal, over a kernel that went on serving: "
        << out.messageSansPath;
}

TEST(TopologyInputValidationTest, ASwitchlessTopologyIsRefusedEvenWithTheMixedPlaneOptIn)
{
    // 🔴 THE FLAG IS ABOUT MIXING, NOT ABOUT HAVING NONE, and the two are one `&&` apart in the
    // source. Writing the switchless door as `!allowMixed && declaredKinds.empty()` compiles,
    // passes every other case in this file, and silently hands a build with
    // ALLOW_MIXED_DATAPLANE = true the exact behaviour E-26 removed. M33 is that mutation.
    MutatedTopology topo("switchless_opted_in");
    ASSERT_TRUE(topo.usable());
    ASSERT_EQ(stripEverySwitch(topo), 4u);

    const LoadOutcome out = loadFile(topo.write(), utils::TESTBED, /*allowMixed=*/true);

    EXPECT_TRUE(out.threw)
        << "the mixed-plane opt-in admitted a topology with no switches at all: " << out.message;
    EXPECT_EQ(out.vertices, 0u);
}

TEST(TopologyInputValidationTest, AHostWithMoreThanOneAddressStillLoads)
{
    // 🔴 The control that keeps door 3d from narrowing to "exactly one address". Five shipped
    // TESTBED files give every host FOUR (they are the _ipAlias4_ files, and that is what the
    // name means), so a check written `size() != 1` would refuse 160 hosts across five files --
    // the fleet-breaking shape M8 pins for ports and M13 for bridge_name.
    MutatedTopology topo("host_two_addresses");
    ASSERT_TRUE(topo.usable());

    const std::size_t victim = lastHostNodeIndex(topo.doc());
    ASSERT_GT(victim, 0u);
    auto addresses = topo.doc()["nodes"][victim].at("ip");
    ASSERT_EQ(addresses.size(), 1u) << "the P4 4-host model gives each host one address";
    addresses.push_back("10.9.9.9");
    topo.doc()["nodes"][victim]["ip"] = addresses;

    const LoadOutcome out = loadFile(topo.write());

    EXPECT_FALSE(out.threw) << "a host with two addresses was refused: " << out.message;
    EXPECT_EQ(out.vertices, 14u);
    EXPECT_EQ(out.edges, 40u);
}
