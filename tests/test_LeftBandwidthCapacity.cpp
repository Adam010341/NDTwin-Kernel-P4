/**
 * F-8: the headroom a link advertises must come from that link's declared capacity, and a link
 * nobody has measured must not be able to pass itself off as one that has been.
 *
 * [Co-developed with claude code -- Adam]
 *
 * THE DEFECT. EdgeProperties::leftBandwidthFromFlowSample was initialised to
 * MININET_INTERFACE_SPEED -- a literal 1 Gbit/s -- and loadStaticTopologyFromFile never wrote it.
 * It read link_bandwidth_bps out of the topology file on one line and assigned it to
 * `leftBandwidth` on the next, which is the field TESTBED mode reports; the field MININET mode
 * reports (HttpSession::handleGetGraphData picks between the two on m_mode) kept the literal. So
 * every core link the shipped topologies declare at 10 Gbit/s advertised 1 Gbit/s of headroom.
 *
 * IT IS NOT TRANSIENT ON A SILENT LINK. The only writer of leftBandwidthFromFlowSample is
 * updateLinkInfoLeftLinkBandwidth, and its callers iterate FlowLinkUsageCollector's
 * m_counterReports / m_egressCounterReports. Under MININET those maps are filled by *flow
 * samples* only -- the counter-sample branch returns early in that mode -- so an edge that never
 * carries traffic never gets an entry, never gets the call, and holds the wrong figure for the
 * lifetime of the process.
 *
 * WHY A PROVENANCE FIELD AND NOT JUST A BETTER NUMBER. On the 128-host topology 272 of the 288
 * edges read *correctly* before the fix, because the sentinel happened to equal their declared
 * 1 Gbit/s. Right for the wrong reason is the dangerous half: nothing in the response separated
 * those 272 from the 16 that were wrong by 10x. No uint64_t can carry that separation either --
 * 0 is a producible measurement (a saturated link publishes 0 left, via the capacity clamp), and
 * so is every other value. Hence BandwidthSource, asserted here alongside the numbers.
 *
 * WHAT THE FIRST TEST IS FOR. ADeclaredTenGigabitLinkAdvertisesTenGigabitsBeforeAnySample is the
 * one that fails on the unfixed code, and it is the only test here that compiles against the
 * unfixed headers. If only one test in this file can be kept, keep that one.
 *
 * MUTATION GATE -- each mutation names the single line to revert and the test that must be the
 * one to go red. NOT RUN: this worktree is forbidden from building (a CPU-sensitive measurement
 * is in flight), so no test in this file has been seen red or green. Treat the file as
 * UNVERIFIED until someone runs the list below.
 *
 *   1. TopologyAndFlowMonitor.cpp: drop `ep.leftBandwidthFromFlowSample = ep.linkBandwidth;`
 *        -> ADeclaredTenGigabitLinkAdvertisesTenGigabitsBeforeAnySample
 *   2. TopologyAndFlowMonitor.cpp: drop `ep.leftBandwidthSource = BandwidthSource::Declared;`
 *        -> AnUnsampledEdgeIsNotReportedAsMeasured
 *   3. TopologyAndFlowMonitor.cpp: drop the `Measured` stamp in
 *      updateLinkInfoLeftLinkBandwidth
 *        -> TheFirstFlowSampleTurnsDeclaredIntoMeasured
 *   4. GraphTypes.hpp: restore `leftBandwidthFromFlowSample = MININET_INTERFACE_SPEED`
 *        -> ADefaultConstructedEdgeDoesNotAdvertiseAGigabitOfHeadroom
 *   5. GraphTypes.hpp: make bandwidthSourceFromString return Declared for an unknown string
 *        -> AnUnrecognisedProvenanceReadsBackAsUnknownNotAsCapacity
 */

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
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

constexpr uint64_t kTenGig = 10'000'000'000ULL;
constexpr uint64_t kOneGig = 1'000'000'000ULL;

/// Writes a topology file and removes it again, so the test owns no state between runs.
class CapacityTopologyFile
{
  public:
    explicit CapacityTopologyFile(const std::string& body)
    {
        m_path = std::filesystem::temp_directory_path() /
                 ("ndt_f8_topo_" + std::to_string(++s_counter) + ".json");
        std::ofstream ofs(m_path);
        ofs << body;
    }

    ~CapacityTopologyFile()
    {
        std::error_code ec;
        std::filesystem::remove(m_path, ec);
    }

    CapacityTopologyFile(const CapacityTopologyFile&) = delete;
    CapacityTopologyFile& operator=(const CapacityTopologyFile&) = delete;

    std::string path() const { return m_path.string(); }

  private:
    std::filesystem::path m_path;
    static int s_counter;
};

int CapacityTopologyFile::s_counter = 0;

/// Exposes the protected loader. The loader is the subject here: the declared capacity has to
/// reach the reported field at load, not at first traffic.
class CapacityMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;
    using TopologyAndFlowMonitor::loadStaticTopologyFromFile;
};

/**
 * Three BMv2 switches wired like the shipped 128-host fabric in miniature: one 10 Gbit/s core
 * link (s5 -> s9, the class that was wrong) and one 1 Gbit/s access-layer link (s5 -> s10, the
 * class that was right by coincidence). Homogeneous brand_name so the loader's data-plane
 * check has nothing to complain about.
 */
const char* kTwoSpeedTopology = R"JSON({
  "nodes": [
    {"vertex_type": 0, "dpid": 5, "mac": 0, "ip": ["192.168.123.15"], "device_name": "s5",
     "nickname": "s5", "brand_name": "BMv2", "bridge_name": "s5", "device_layer": 2},
    {"vertex_type": 0, "dpid": 9, "mac": 0, "ip": ["192.168.123.19"], "device_name": "s9",
     "nickname": "s9", "brand_name": "BMv2", "bridge_name": "s9", "device_layer": 1},
    {"vertex_type": 0, "dpid": 10, "mac": 0, "ip": ["192.168.123.20"], "device_name": "s10",
     "nickname": "s10", "brand_name": "BMv2", "bridge_name": "s10", "device_layer": 3}
  ],
  "edges": [
    {"src_dpid": 5, "src_interface": 3, "src_ip": ["192.168.123.15"],
     "dst_dpid": 9, "dst_interface": 1, "dst_ip": ["192.168.123.19"],
     "link_bandwidth_bps": 10000000000},
    {"src_dpid": 5, "src_interface": 4, "src_ip": ["192.168.123.15"],
     "dst_dpid": 10, "dst_interface": 1, "dst_ip": ["192.168.123.20"],
     "link_bandwidth_bps": 1000000000}
  ]
})JSON";

class LeftBandwidthCapacityTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_file = std::make_unique<CapacityTopologyFile>(kTwoSpeedTopology);
        m_monitor = std::make_unique<CapacityMonitor>(m_graph,
                                                      m_mutex,
                                                      m_bus,
                                                      utils::MININET);
        m_monitor->loadStaticTopologyFromFile(m_file->path());
    }

    /// The edge (srcDpid -> dstDpid), by value. Fails the test rather than returning a default
    /// if it is absent: a missing edge would otherwise read as a zeroed EdgeProperties and every
    /// assertion below would be about a struct the loader never produced.
    EdgeProperties edge(uint64_t srcDpid, uint64_t dstDpid) const
    {
        for (auto [ei, eiEnd] = boost::edges(*m_graph); ei != eiEnd; ++ei)
        {
            if ((*m_graph)[*ei].srcDpid == srcDpid && (*m_graph)[*ei].dstDpid == dstDpid)
            {
                return (*m_graph)[*ei];
            }
        }
        ADD_FAILURE() << "edge " << srcDpid << " -> " << dstDpid << " is not in the graph";
        return {};
    }

    /// Feeds one flow-sample payout to the edge, keyed the way the rate loop keys it: by the
    /// sampling agent's (ip, port). Read back off the loaded edge rather than recomputed, so the
    /// test never has to reason about the byte order the loader stores addresses in.
    void sample(uint64_t srcDpid, uint64_t dstDpid, uint64_t bytes, double seconds)
    {
        const EdgeProperties e = edge(srcDpid, dstDpid);
        ASSERT_FALSE(e.srcIp.empty()) << "edge has no agent address to key on";
        m_monitor->updateLinkInfoLeftLinkBandwidth({e.srcIp.front(), e.srcInterface},
                                                   bytes,
                                                   seconds);
    }

    std::shared_ptr<Graph> m_graph = std::make_shared<Graph>();
    std::shared_ptr<std::shared_mutex> m_mutex = std::make_shared<std::shared_mutex>();
    std::shared_ptr<EventBus> m_bus = std::make_shared<EventBus>();
    std::unique_ptr<CapacityTopologyFile> m_file;
    std::unique_ptr<CapacityMonitor> m_monitor;
};

// --- the defect itself -----------------------------------------------------------------------

TEST_F(LeftBandwidthCapacityTest, ADeclaredTenGigabitLinkAdvertisesTenGigabitsBeforeAnySample)
{
    // LOAD-BEARING. On the unfixed code this reads 1000000000: the loader assigns the declared
    // capacity to leftBandwidth and leaves leftBandwidthFromFlowSample -- the field MININET mode
    // publishes -- holding its in-class initialiser. Stated against the declared figure rather
    // than the literal 10000000000 so the test follows the topology, not a constant.
    EXPECT_EQ(edge(5, 9).leftBandwidthFromFlowSample, kTenGig)
        << "a 10 Gbit/s link that has not been sampled must advertise its declared capacity, "
           "not a hardcoded gigabit";
    EXPECT_EQ(edge(5, 9).leftBandwidthFromFlowSample, edge(5, 9).linkBandwidth)
        << "with no traffic seen, remaining headroom is the whole declared capacity";
}

TEST_F(LeftBandwidthCapacityTest, ADeclaredOneGigabitLinkIsRightForARecordedReason)
{
    // The other 272 of 288 edges. The number was already correct before the fix -- by
    // coincidence, because the sentinel equalled their declared capacity -- so the number alone
    // cannot witness the fix. The provenance can.
    EXPECT_EQ(edge(5, 10).leftBandwidthFromFlowSample, kOneGig);
    EXPECT_EQ(edge(5, 10).leftBandwidthSource, BandwidthSource::Declared);
}

// --- provenance ------------------------------------------------------------------------------

TEST_F(LeftBandwidthCapacityTest, AnUnsampledEdgeIsNotReportedAsMeasured)
{
    EXPECT_EQ(edge(5, 9).leftBandwidthSource, BandwidthSource::Declared)
        << "nothing has observed this link; saying so is the whole point of the field";
    EXPECT_NE(edge(5, 9).leftBandwidthSource, BandwidthSource::Measured);
}

TEST_F(LeftBandwidthCapacityTest, TheFirstFlowSampleTurnsDeclaredIntoMeasured)
{
    ASSERT_EQ(edge(5, 9).leftBandwidthSource, BandwidthSource::Declared);

    sample(5, 9, /*bytes=*/125'000'000, /*seconds=*/1.0); // 1 Gbit/s of traffic

    EXPECT_EQ(edge(5, 9).leftBandwidthSource, BandwidthSource::Measured);
    EXPECT_EQ(edge(5, 9).leftBandwidthFromFlowSample, kTenGig - kOneGig)
        << "10 Gbit/s declared minus 1 Gbit/s observed";
}

TEST_F(LeftBandwidthCapacityTest,
       AnIdleMeasuredEdgeAndAnUnsampledEdgeShareANumberAndDifferInProvenance)
{
    // THE REASON THE FIELD EXISTS, stated as an assertion. Sample the 1 Gbit/s edge with zero
    // bytes: it is idle and *observed* to be idle, and it publishes exactly the figure the
    // never-observed edge publishes for its own capacity. Two different states, one number.
    sample(5, 10, /*bytes=*/0, /*seconds=*/1.0);

    EXPECT_EQ(edge(5, 10).leftBandwidthFromFlowSample, edge(5, 10).linkBandwidth);
    EXPECT_EQ(edge(5, 9).leftBandwidthFromFlowSample, edge(5, 9).linkBandwidth);

    EXPECT_EQ(edge(5, 10).leftBandwidthSource, BandwidthSource::Measured);
    EXPECT_EQ(edge(5, 9).leftBandwidthSource, BandwidthSource::Declared)
        << "sampled-and-idle and never-sampled must not be the same answer";
}

// --- the sentinel, at its source ---------------------------------------------------------------

TEST(LeftBandwidthDefaultTest, ADefaultConstructedEdgeDoesNotAdvertiseAGigabitOfHeadroom)
{
    // An edge nobody has loaded and nobody has sampled. It used to claim a full gigabit was free,
    // which is a plausible reading of a real idle access link -- the sentinel was
    // indistinguishable from data. The number is now 0 *and* labelled Unknown; the label is the
    // load-bearing half, because 0 is itself a value the capacity clamp can publish.
    EdgeProperties fresh;
    EXPECT_EQ(fresh.leftBandwidthFromFlowSample, 0u);
    EXPECT_EQ(fresh.leftBandwidthSource, BandwidthSource::Unknown);
}

TEST(LeftBandwidthDefaultTest, AnUnrecognisedProvenanceReadsBackAsUnknownNotAsCapacity)
{
    // from_json accepts payloads produced before the field existed. Defaulting those to Declared
    // would manufacture a provenance nobody claimed -- the same shape as the defect being fixed.
    EXPECT_EQ(bandwidthSourceFromString(""), BandwidthSource::Unknown);
    EXPECT_EQ(bandwidthSourceFromString("Declared"), BandwidthSource::Unknown)
        << "the wire vocabulary is lower case; a near-miss is not a match";
    EXPECT_EQ(bandwidthSourceFromString("declared"), BandwidthSource::Declared);
    EXPECT_EQ(bandwidthSourceFromString("measured"), BandwidthSource::Measured);
}

TEST(LeftBandwidthDefaultTest, TheWireVocabularyIsExactlyThreeWords)
{
    // tools/contract_test/spec.py pins this same set for GRAPH_EDGE. Asserted on both sides so
    // a fourth value cannot be added on the kernel side alone.
    EXPECT_STREQ(toString(BandwidthSource::Declared), "declared");
    EXPECT_STREQ(toString(BandwidthSource::Measured), "measured");
    EXPECT_STREQ(toString(BandwidthSource::Unknown), "unknown");
}

} // namespace
