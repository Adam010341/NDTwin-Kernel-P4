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
loadFile(const std::string& path, int mode = utils::TESTBED)
{
    LoadOutcome out;
    auto graph = std::make_shared<Graph>();
    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    TestableMonitor monitor{graph, mutex, bus, mode};

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
    return out;
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
