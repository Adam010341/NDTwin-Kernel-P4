/**
 * Tests for TopologyAndFlowMonitor's static topology loading.
 *
 * [Co-developed with claude code -- Adam]
 *
 * TopologyAndFlowMonitor is a 2675-line class with no dedicated test file. Its
 * loadStaticTopologyFromFile method is the single point where a topology JSON becomes
 * the in-memory graph that every routing, power, and telemetry path reads. Getting the
 * vertex/edge counts or the vertex types wrong would silently corrupt every downstream
 * computation.
 *
 * These tests load a real topology file (StaticNetworkTopologyP4_10Switches_4Hosts.json)
 * and verify the resulting graph against the counts and invariants documented in
 * 2026-01-02_ndt_api.md and the file's own structure. Nothing is mocked: the graph, mutex, and
 * EventBus are the real objects, exactly as the OvsPowerStrategy Fixture does.
 *
 * The assertions are derived from the spec (2026-01-02_ndt_api.md lines 124-250) and the topology
 * file's own structure (10 switches, 4 hosts, 40 directed edges), not from reading
 * loadStaticTopologyFromFile's implementation.
 */

#include <filesystem>
#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <boost/graph/adjacency_list.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Utils.hpp"

namespace
{

/// Exposes the protected loadStaticTopologyFromFile for testing.
class TestableTopologyAndFlowMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    /// Public seam for the protected loader.
    void load(const std::string& path)
    {
        loadStaticTopologyFromFile(path);
    }

    // [Co-developed with claude code -- Adam]
    // The three ingest points for the control plane's REST replies. They take a raw string
    // because that is what pollControlPlaneTopology hands them -- curl's stdout, unvalidated,
    // produced by another process. Exposed so a test can feed the shapes that process is free
    // to send, which is the only way to observe what a malformed reply costs.
    using TopologyAndFlowMonitor::updateHosts;
    using TopologyAndFlowMonitor::updateLinks;
    using TopologyAndFlowMonitor::updateSwitches;
};

/// A graph + monitor pair. The graph is shared so the test can inspect it after loading.
struct TopologyFixture
{
    std::shared_ptr<Graph> graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> bus = std::make_shared<EventBus>();
    TestableTopologyAndFlowMonitor monitor{graph, mutex, bus, utils::TESTBED};

    /// Loads the P4 topology and returns the number of vertices present afterwards.
    ///
    /// [Co-developed with claude code -- Adam]
    /// The path is resolved against several candidates rather than assumed relative to the build
    /// tree. The first version of this fixture used "../setting/..." on the reasoning that CMake
    /// runs tests from the build directory -- but the binary is also run directly from the repo
    /// root (l1_unit_tests.sh does exactly that, deliberately, because ctest masks suite-level
    /// failures), and there "../setting" is outside the repo.
    ///
    /// That mattered more than a wrong path usually does. loadStaticTopologyFromFile returns void
    /// and only logs on a file it cannot open, so a bad path produces an *empty graph* rather than
    /// an error the test can see: four tests failed with "0 != 14", which looks exactly like a
    /// topology-loading bug in the kernel, and one test PASSED because iterating an empty graph
    /// satisfies every assertion vacuously. Hence the ASSERT below -- a fixture that cannot find
    /// its input must fail loudly, not quietly produce nothing.
    size_t loadP4Topology()
    {
        static const char* kCandidates[] = {
            "setting/StaticNetworkTopologyP4_10Switches_4Hosts.json",
            "../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json",
            "../../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json",
        };

        std::string found;
        for (const char* candidate : kCandidates)
        {
            if (std::filesystem::exists(candidate))
            {
                found = candidate;
                break;
            }
        }

        // Not EXPECT: every assertion after this would be about an empty graph, and some of them
        // would pass.
        if (found.empty())
        {
            ADD_FAILURE() << "could not find StaticNetworkTopologyP4_10Switches_4Hosts.json "
                             "relative to the working directory ("
                          << std::filesystem::current_path().string()
                          << "); the assertions below would be vacuous";
            return 0;
        }

        monitor.load(found);
        std::shared_lock lock(*mutex);
        return boost::num_vertices(*graph);
    }
};

} // namespace

// ---------------------------------------------------------------------------
// Vertex and edge counts, derived from the topology file name and structure.
// The file name promises 10 switches and 4 hosts = 14 vertices.
// The edge count is verified by inspecting the JSON directly in the test.
// ---------------------------------------------------------------------------

TEST(TopologyAndFlowMonitorTest, LoadingTheP4TopologyProducesTheCorrectNumberOfVertices)
{
    // StaticNetworkTopologyP4_10Switches_4Hosts.json contains exactly:
    //   10 switches (vertex_type=0) + 4 hosts (vertex_type=1) = 14 vertices.
    // This count is derived from the file name and confirmed by counting the
    // "device_name" entries in the JSON.
    TopologyFixture fix;
    const size_t n = fix.loadP4Topology();
    EXPECT_EQ(n, 14u) << "expected 10 switches + 4 hosts = 14 vertices";
}

TEST(TopologyAndFlowMonitorTest, LoadingTheP4TopologyProducesTheCorrectNumberOfEdges)
{
    // The P4 topology has 32 switch-to-switch directed edges (16 bidirectional links)
    // plus 8 host-to-switch directed edges (4 bidirectional links) = 40 total.
    // Counted from the "src_dpid" entries in the JSON edges array.
    TopologyFixture fix;
    fix.loadP4Topology();
    std::shared_lock lock(*fix.mutex);
    EXPECT_EQ(boost::num_edges(*fix.graph), 40u);
}

TEST(TopologyAndFlowMonitorTest, SwitchVerticesHaveVertexTypeZeroHostsHaveVertexTypeOne)
{
    // Per 2026-01-02_ndt_api.md lines 127-128: "vertex_type = 0 means a switch, and vertex_type = 1 means a host."
    TopologyFixture fix;
    fix.loadP4Topology();
    std::shared_lock lock(*fix.mutex);

    size_t switches = 0;
    size_t hosts = 0;
    const auto [vi, ve] = boost::vertices(*fix.graph);
    for (auto v = vi; v != ve; ++v)
    {
        const auto& vp = (*fix.graph)[*v];
        if (vp.vertexType == VertexType::SWITCH)
        {
            ++switches;
            EXPECT_EQ(static_cast<int>(vp.vertexType), 0)
                << "switch " << vp.deviceName << " has vertex_type != 0";
        }
        else if (vp.vertexType == VertexType::HOST)
        {
            ++hosts;
            EXPECT_EQ(static_cast<int>(vp.vertexType), 1)
                << "host " << vp.deviceName << " has vertex_type != 1";
        }
    }
    EXPECT_EQ(switches, 10u);
    EXPECT_EQ(hosts, 4u);
}

TEST(TopologyAndFlowMonitorTest, HostEdgesHaveDpidZeroOnTheHostSide)
{
    // Per 2026-01-02_ndt_api.md line 130: "At the edge between the switch and host, the dpid
    // and interface on the host side are set to 0."
    TopologyFixture fix;
    fix.loadP4Topology();
    std::shared_lock lock(*fix.mutex);

    size_t hostEdgesChecked = 0;
    const auto [ei, ee] = boost::edges(*fix.graph);
    for (auto e = ei; e != ee; ++e)
    {
        const auto& ep = (*fix.graph)[*e];
        const auto srcV = boost::source(*e, *fix.graph);
        const auto dstV = boost::target(*e, *fix.graph);
        const bool srcIsHost = (*fix.graph)[srcV].vertexType == VertexType::HOST;
        const bool dstIsHost = (*fix.graph)[dstV].vertexType == VertexType::HOST;

        if (srcIsHost)
        {
            ++hostEdgesChecked;
            EXPECT_EQ(ep.srcDpid, 0u)
                << "host " << (*fix.graph)[srcV].deviceName
                << " edge has non-zero src_dpid " << ep.srcDpid;
            EXPECT_EQ(ep.srcInterface, 1u)
                << "host edge src_interface should be 1 (the host's single interface)";
        }
        if (dstIsHost)
        {
            ++hostEdgesChecked;
            EXPECT_EQ(ep.dstDpid, 0u)
                << "host " << (*fix.graph)[dstV].deviceName
                << " edge has non-zero dst_dpid " << ep.dstDpid;
            EXPECT_EQ(ep.dstInterface, 1u)
                << "host edge dst_interface should be 1";
        }
    }
    EXPECT_EQ(hostEdgesChecked, 8u)
        << "there should be 8 directed edges involving hosts (4 hosts × 2 directions)";
}

TEST(TopologyAndFlowMonitorTest, EveryVertexHasTheFieldsRequiredByTheApiSpec)
{
    // Per 2026-01-02_ndt_api.md lines 150-225 and tools/contract_test/schema.py lines 61-71,
    // every node in the graph response must have: device_name, dpid, ip, is_enabled,
    // is_up, mac, vertex_type, brand_name, device_layer.
    //
    // After loadStaticTopologyFromFile, these fields must be present on every vertex
    // because they come directly from the topology JSON. We check that:
    //   - deviceName is non-empty
    //   - dpid is present (can be 0 for hosts)
    //   - ip is non-empty (the code enforces this for switches; hosts also carry IPs)
    //   - vertexType is SWITCH or HOST
    //   - brandName is set (may be empty for hosts per the topology)
    //   - deviceLayer is >= 0 (the topology sets layer 2 for switches, 3 for hosts)

    TopologyFixture fix;
    const size_t loaded = fix.loadP4Topology();
    std::shared_lock lock(*fix.mutex);

    // [Co-developed with claude code -- Adam]
    // Without this, the test passes on an empty graph: the loop below runs zero times and every
    // EXPECT inside it is vacuously satisfied. It really did pass that way -- while its four
    // siblings failed with "0 != 14" -- which is the shape of a false test, and the reason this
    // project treats "a test that cannot fail" as undelivered.
    ASSERT_EQ(loaded, 14u) << "fixture loaded nothing, so the per-vertex checks below would prove "
                              "nothing at all";

    const auto [vi, ve] = boost::vertices(*fix.graph);
    for (auto v = vi; v != ve; ++v)
    {
        const auto& vp = (*fix.graph)[*v];
        EXPECT_FALSE(vp.deviceName.empty())
            << "vertex has empty device_name";
        // dpid 0 is valid for hosts
        EXPECT_FALSE(vp.ip.empty())
            << "vertex " << vp.deviceName << " has empty ip array";
        EXPECT_TRUE(vp.vertexType == VertexType::SWITCH || vp.vertexType == VertexType::HOST)
            << "vertex " << vp.deviceName << " has unexpected vertexType";
        EXPECT_GE(vp.deviceLayer, 0)
            << "vertex " << vp.deviceName << " has negative device_layer";
    }
}

// ---------------------------------------------------------------------------
// What a malformed control-plane reply costs.
//
// [Co-developed with claude code -- Adam]
// These three functions are fed curl's stdout: a string produced by Ryu or by the P4 proxy,
// two processes this one does not control, over HTTP. The catch inside each of them carries
// the claim that a bad reply "should cost us this poll, not the process".
//
// The expectations below are that sentence, not the implementation. They were written against
// the contract and each was checked to fail before the fix: with the previous
// `stoull(dpidStr, nullptr, 16)`, a switches entry carrying no "dpid" throws
// std::invalid_argument, which is not a json::exception, so it escaped the catch here, escaped
// updateGraph (pollControlPlaneTopology calls it outside all three of its try blocks), escaped
// run(), and reached the thread entry -- std::terminate, the whole kernel, from one field.
//
// "Costs the entry, not the reply" is asserted separately from "does not throw", because a
// `return` in place of a `continue` also stops the throw while silently discarding every
// switch listed after the bad one -- which would look exactly like a healthy poll.
// ---------------------------------------------------------------------------

namespace
{

/// The vertex carrying this dpid, or nullopt. Reads under the fixture's own mutex.
std::optional<Graph::vertex_descriptor>
vertexWithDpid(const TopologyFixture& fix, uint64_t dpid)
{
    std::shared_lock lock(*fix.mutex);
    const auto [vi, ve] = boost::vertices(*fix.graph);
    for (auto v = vi; v != ve; ++v)
    {
        if ((*fix.graph)[*v].vertexType == VertexType::SWITCH && (*fix.graph)[*v].dpid == dpid)
        {
            return *v;
        }
    }
    return std::nullopt;
}

bool
vertexIsUp(const TopologyFixture& fix, Graph::vertex_descriptor v)
{
    std::shared_lock lock(*fix.mutex);
    return (*fix.graph)[v].isUp;
}

} // namespace

TEST(ControlPlaneReplyRobustnessTest, ASwitchesEntryWithNoDpidDoesNotTerminateTheProcess)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    // Ryu is free to send this: the kernel's own comment names "a control plane answering with
    // an unexpected shape" as the case being defended against.
    EXPECT_NO_THROW(fix.monitor.updateSwitches(R"([{"ports": []}])"))
        << "a switches entry with no dpid escaped as an uncaught exception; on the poll thread "
           "that is std::terminate";
}

TEST(ControlPlaneReplyRobustnessTest, ASwitchesEntryWithANonHexDpidDoesNotTerminateTheProcess)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    EXPECT_NO_THROW(fix.monitor.updateSwitches(R"([{"dpid": "not-a-dpid"}])"));
    EXPECT_NO_THROW(fix.monitor.updateSwitches(R"([{"dpid": ""}])"));
    EXPECT_NO_THROW(fix.monitor.updateSwitches(R"([{"dpid": "1z"}])"))
        << "trailing junk must be refused, not silently parsed as switch 1";
}

TEST(ControlPlaneReplyRobustnessTest, OneBadSwitchesEntryDoesNotCostTheEntriesAfterIt)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    const auto s3 = vertexWithDpid(fix, 3);
    ASSERT_TRUE(s3.has_value()) << "topology has no switch 3; the assertion below would be vacuous";
    ASSERT_FALSE(vertexIsUp(fix, *s3))
        << "switch 3 is already up before the reply is fed, so this test cannot observe the "
           "reply being applied";

    // dpid "3" is 3 in base 16 as well as base 10, so this does not quietly depend on which
    // base the reader assumes.
    fix.monitor.updateSwitches(R"([{"dpid": ""}, {"dpid": "3"}])");

    EXPECT_TRUE(vertexIsUp(fix, *s3))
        << "the entry after the malformed one was never applied: the bad entry cost the whole "
           "reply rather than itself, which reports a live switch as unchanged and looks "
           "exactly like a healthy poll";
}

TEST(ControlPlaneReplyRobustnessTest, AHostsEntryWithAMalformedMacDoesNotTerminateTheProcess)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    // Well-typed (a string) but unparseable. The type error was already handled -- that throws
    // json::type_error, which is a json::exception; this one throws std::invalid_argument.
    EXPECT_NO_THROW(fix.monitor.updateHosts(R"([{"mac": "zz:zz:zz:zz:zz:zz", "ipv4": ["10.0.0.1"]}])"));
    EXPECT_NO_THROW(fix.monitor.updateHosts(R"([{"ipv4": ["10.0.0.1"]}])"))
        << "a hosts entry with no mac at all";
}

TEST(ControlPlaneReplyRobustnessTest, OneBadHostsEntryDoesNotCostTheEntriesAfterIt)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    std::optional<Graph::vertex_descriptor> h1;
    {
        std::shared_lock lock(*fix.mutex);
        const auto [vi, ve] = boost::vertices(*fix.graph);
        for (auto v = vi; v != ve; ++v)
        {
            if ((*fix.graph)[*v].vertexType == VertexType::HOST && (*fix.graph)[*v].mac == 1)
            {
                h1 = *v;
                break;
            }
        }
    }
    ASSERT_TRUE(h1.has_value()) << "topology has no host with mac 1";
    ASSERT_FALSE(vertexIsUp(fix, *h1));

    fix.monitor.updateHosts(
        R"([{"mac": "zz:zz:zz:zz:zz:zz", "ipv4": ["10.0.0.9"]},
            {"mac": "00:00:00:00:00:01", "ipv4": ["10.0.0.1"]}])");

    EXPECT_TRUE(vertexIsUp(fix, *h1))
        << "the host after the malformed one was never applied";
}

TEST(ControlPlaneReplyRobustnessTest, ALinksEntryWithMissingEndpointsDoesNotTerminateTheProcess)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    // No "src"/"dst" at all. On a const json, operator[] with a missing key is undefined
    // behaviour rather than a catchable exception, so this shape cannot be defended by a catch.
    EXPECT_NO_THROW(fix.monitor.updateLinks(R"([{}])"));
    EXPECT_NO_THROW(fix.monitor.updateLinks(R"([{"src": {"dpid": "1", "port_no": "1"}}])"))
        << "a links entry with a src but no dst";
}

TEST(ControlPlaneReplyRobustnessTest, ALinksEntryWithANonHexDpidDoesNotTerminateTheProcess)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    EXPECT_NO_THROW(fix.monitor.updateLinks(
        R"([{"src": {"dpid": "zz", "port_no": "1"}, "dst": {"dpid": "2", "port_no": "1"}}])"));
    EXPECT_NO_THROW(fix.monitor.updateLinks(
        R"([{"src": {"dpid": "1", "port_no": "1"}, "dst": {"dpid": "1z", "port_no": "1"}}])"));
}

TEST(ControlPlaneReplyRobustnessTest, AHostsEntryWithNoAttachmentPortDoesNotTerminateTheProcess)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    // mac and ipv4 are both well-formed, so this reaches the attachment-port lookup -- which
    // was `host["port"]["dpid"]`: two unchecked lookups on a const json (undefined behaviour
    // for a missing key, not an exception) feeding a throwing hex parse. Found by the
    // malformed-mac test above crashing the suite on its *second*, well-formed entry.
    EXPECT_NO_THROW(
        fix.monitor.updateHosts(R"([{"mac": "00:00:00:00:00:01", "ipv4": ["10.0.0.1"]}])"));
    EXPECT_NO_THROW(fix.monitor.updateHosts(
        R"([{"mac": "00:00:00:00:00:01", "ipv4": ["10.0.0.1"], "port": {}}])"))
        << "a port object with no dpid in it";
}

TEST(ControlPlaneReplyRobustnessTest, AHostsEntryWithANonHexAttachmentDpidDoesNotTerminateTheProcess)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    EXPECT_NO_THROW(fix.monitor.updateHosts(
        R"([{"mac": "00:00:00:00:00:01", "ipv4": ["10.0.0.1"],
             "port": {"dpid": "not-hex"}}])"));
}

TEST(ControlPlaneReplyRobustnessTest, AHostsEntryWithAnUnparseableIpDoesNotTerminateTheProcess)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    // ipStringToUint32 throws std::invalid_argument, the same non-json escape route.
    EXPECT_NO_THROW(fix.monitor.updateHosts(
        R"([{"mac": "00:00:00:00:00:01", "ipv4": ["not.an.address"],
             "port": {"dpid": "1"}}])"));
}

TEST(ControlPlaneReplyRobustnessTest, OneBadLinksEntryDoesNotCostTheEntriesAfterIt)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    // The topology's first edge: dpid 1 port 1 -> dpid 5. updateLinks keys on (src dpid,
    // src port), so that pair is what the reply below claims is up.
    const auto edgeUp = [&fix]() {
        std::shared_lock lock(*fix.mutex);
        for (auto e : boost::make_iterator_range(boost::edges(*fix.graph)))
        {
            const auto& ep = (*fix.graph)[e];
            if (ep.srcDpid == 1 && ep.srcInterface == 1)
            {
                return std::optional<bool>(ep.isUp);
            }
        }
        return std::optional<bool>();
    };

    ASSERT_TRUE(edgeUp().has_value()) << "no edge leaves dpid 1 on port 1; assertion is vacuous";
    ASSERT_FALSE(*edgeUp()) << "already up before the reply is fed";

    fix.monitor.updateLinks(
        R"([{"src": {"dpid": "zz", "port_no": "1"}, "dst": {"dpid": "5", "port_no": "1"}},
            {"src": {"dpid": "1",  "port_no": "1"}, "dst": {"dpid": "5", "port_no": "1"}}])");

    EXPECT_TRUE(*edgeUp())
        << "the link after the malformed one was never applied: one unparseable dpid cost the "
           "whole reply, so every link listed after it silently keeps its old state";
}

TEST(ControlPlaneReplyRobustnessTest, OneBadHostIpDoesNotCostTheEntriesAfterIt)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    const auto h2Up = [&fix]() {
        std::shared_lock lock(*fix.mutex);
        for (auto v : boost::make_iterator_range(boost::vertices(*fix.graph)))
        {
            const auto& vp = (*fix.graph)[v];
            if (vp.vertexType == VertexType::HOST && vp.mac == 2)
            {
                return std::optional<bool>(vp.isUp);
            }
        }
        return std::optional<bool>();
    };

    ASSERT_TRUE(h2Up().has_value()) << "topology has no host with mac 2";
    ASSERT_FALSE(*h2Up());

    fix.monitor.updateHosts(
        R"([{"mac": "00:00:00:00:00:01", "ipv4": ["not.an.address"], "port": {"dpid": "1"}},
            {"mac": "00:00:00:00:00:02", "ipv4": ["10.0.0.2"],       "port": {"dpid": "2"}}])");

    EXPECT_TRUE(*h2Up())
        << "the host after the unparseable address was never applied";
}

// ---------------------------------------------------------------------------
// The two flavours the first pass missed.
//
// [Co-developed with claude code -- Adam]
// OneBadHostIpDoesNotCostTheEntriesAfterIt and OneBadLinksEntryDoesNotCostTheEntriesAfterIt both
// feed input whose *value* is wrong, which reaches the `continue` those guards added. An
// independent review pointed out that neither pins the property its name claims, because each
// ingest still had a path where a bad entry cost the whole reply:
//
//   - a hosts entry whose ipv4[0] is the wrong *type* threw json::type_error out of the loop,
//     and the function-level catch turns that into a return;
//   - a links entry naming a switch absent from the static topology hit a bare `return`, and
//     that one is persistent rather than transient -- the control plane sends the same list on
//     every poll, so every link after the offender stays at its last state indefinitely.
// ---------------------------------------------------------------------------

TEST(ControlPlaneReplyRobustnessTest, AHostIpOfTheWrongTypeDoesNotCostTheEntriesAfterIt)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    const auto h2Up = [&fix]() {
        std::shared_lock lock(*fix.mutex);
        for (auto v : boost::make_iterator_range(boost::vertices(*fix.graph)))
        {
            const auto& vp = (*fix.graph)[v];
            if (vp.vertexType == VertexType::HOST && vp.mac == 2)
            {
                return std::optional<bool>(vp.isUp);
            }
        }
        return std::optional<bool>();
    };
    ASSERT_TRUE(h2Up().has_value());
    ASSERT_FALSE(*h2Up());

    // A number, not an unparseable string: `.get<std::string>()` throws json::type_error, which
    // the value guard never sees because it runs after the conversion.
    fix.monitor.updateHosts(
        R"([{"mac": "00:00:00:00:00:01", "ipv4": [1234],      "port": {"dpid": "1"}},
            {"mac": "00:00:00:00:00:02", "ipv4": ["10.0.0.2"], "port": {"dpid": "2"}}])");

    EXPECT_TRUE(*h2Up())
        << "the host after the wrong-typed address was never applied: the throw escaped to the "
           "function-level catch, which returns";
}

TEST(ControlPlaneReplyRobustnessTest, AKnownHexDpidThatIsNotInTheTopologyDoesNotCostTheRest)
{
    TopologyFixture fix;
    ASSERT_EQ(fix.loadP4Topology(), 14u);

    const auto edgeUp = [&fix]() {
        std::shared_lock lock(*fix.mutex);
        for (auto e : boost::make_iterator_range(boost::edges(*fix.graph)))
        {
            const auto& ep = (*fix.graph)[e];
            if (ep.srcDpid == 1 && ep.srcInterface == 1)
            {
                return std::optional<bool>(ep.isUp);
            }
        }
        return std::optional<bool>();
    };
    ASSERT_TRUE(edgeUp().has_value());
    ASSERT_FALSE(*edgeUp());

    // "ff" is 255: perfectly good hex, so it clears the parse guard, and absent from a ten-switch
    // topology, so it reaches the endpoint lookup. That branch used to `return`.
    fix.monitor.updateLinks(
        R"([{"src": {"dpid": "ff", "port_no": "1"}, "dst": {"dpid": "5", "port_no": "1"}},
            {"src": {"dpid": "1",  "port_no": "1"}, "dst": {"dpid": "5", "port_no": "1"}}])");

    EXPECT_TRUE(*edgeUp())
        << "one link naming an unknown switch discarded every link after it -- and the control "
           "plane repeats that reply on every poll, so this does not recover";
}
