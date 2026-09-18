// [Co-developed with claude code -- Adam]
//
// TICKET-P3 §2.2 / §2.3: what the collector does with a sampled frame that is not IPv4/TCP.
//
// Before this ticket the answer was "nothing at all". The parser read the ethertype at a fixed
// word offset and, if it was not 0x0800, executed `continue` -- discarding the sample whole. Two
// consequences, and the second one is the expensive one:
//
//   1. the frame had no identity anywhere: ARP, LLDP, IPv6 and every P4 exercise's own ethertype
//      (source routing 0x1234, the tunnels, MRI) were invisible rather than unclassified;
//   2. THE LINK IT CROSSED READ ZERO. The byte counter that becomes `link_bandwidth_usage_bps`
//      was incremented inside that same discarded block, so a link carrying nothing but
//      source-routed frames reported an idle link -- which is indistinguishable, to every
//      consumer, from a link that really is idle. PLAN §8.3's first claim is that link
//      utilisation is a property of the link and not of the application; this is the file where
//      that claim is executable.
//
// The fixtures are the emitter's own committed bytes (p4_proxy/tests/generate_emitted_fixtures.py,
// guarded against drift by test_sflow_emitter.py::CommittedFixtureTest), for the reason the
// generator's docstring gives: a frame a C++ test invents proves nothing about the bytes the
// Python emitter will send. The two contract suites -- test_GoldenFixture.cpp (real OVS capture)
// and test_SFlowEmitterRoundtrip.cpp -- are untouched by this ticket and still green; this file
// is additive.
//
// 🔴 The topology below is not decoration. lookupOfport() maps every ifIndex to 0 unless the
// loaded topology is all-bmv2, and with both ports 0 there is no ingress/egress distinction left
// to assert -- which is exactly the state test_SFlowEmitterRoundtrip's byte-credit test runs in,
// and why it can only assert sums. Every port assertion here depends on the identity mapping.

#include <gtest/gtest.h>

#include "common_types/GraphTypes.hpp"
#include "common_types/SFlowType.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <arpa/inet.h>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>
#include <vector>

namespace
{

const std::string kAgentIpStr = "192.168.123.11";
const uint32_t kAgentIp = utils::ipStringToUint32(kAgentIpStr);
constexpr uint32_t kSamplingRate = 256;

// Frame lengths, derived from generate_emitted_fixtures.py rather than measured here, so a change
// to a fixture's frame fails these loudly instead of being absorbed.
constexpr uint64_t kArpFrameLen = 14 + 28;                  // Ethernet + 28 bytes of ARP
constexpr uint64_t kCustomFrameLen = 14 + 32;               // Ethernet + 8 * 4 opaque bytes
constexpr uint64_t kIpv6UdpFrameLen = 14 + 40 + 8 + 20;     // Ethernet + IPv6 + UDP + payload
constexpr uint64_t kUdpFrameLen = 14 + 20 + 8 + 20;         // emitted_udp.bin / emitted_egress_only
constexpr uint64_t kIhl6FrameLen = 14 + 24 + 20 + 20;       // IPv4 with one 4-byte option + TCP
constexpr uint64_t kVlanFrameLen = 14 + 4 + 20 + 8 + 20;    // one 802.1Q tag

// The ports the fixtures were emitted on.
constexpr uint32_t kArpIngressPort = 2;
constexpr uint32_t kArpEgressPort = 1;
constexpr uint32_t kIngressPort = 3; // the ipv6/custom/ihl6/vlan fixtures
constexpr uint32_t kEgressPort = 4;

class ProbeCollector : public sflow::FlowLinkUsageCollector
{
  public:
    ProbeCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                   std::shared_ptr<EventBus> bus,
                   std::shared_ptr<ndtClassifier::Classifier> classifier)
        : sflow::FlowLinkUsageCollector(std::move(monitor),
                                        nullptr,
                                        std::move(bus),
                                        utils::DeploymentMode::MININET,
                                        std::move(classifier))
    {
    }

    using sflow::FlowLinkUsageCollector::egressByteCreditFor;
    using sflow::FlowLinkUsageCollector::handlePacket;
    using sflow::FlowLinkUsageCollector::malformedDatagramCount;
    using sflow::FlowLinkUsageCollector::sampledByteCreditFor;
};

/// Exposes the protected loader, which is the production writer of the switch-kind index.
class TestableMonitor : public TopologyAndFlowMonitor
{
  public:
    TestableMonitor(std::shared_ptr<Graph> g,
                    std::shared_ptr<std::shared_mutex> m,
                    std::shared_ptr<EventBus> bus)
        : TopologyAndFlowMonitor(std::move(g), std::move(m), std::move(bus), utils::MININET)
    {
    }

    using TopologyAndFlowMonitor::loadStaticTopologyFromFile;
};

std::filesystem::path fixtureDir()
{
    for (const auto* candidate : {"tests/fixtures", "../tests/fixtures", "../../tests/fixtures"})
    {
        if (std::filesystem::is_directory(candidate))
        {
            return candidate;
        }
    }
    return {};
}

std::vector<char> loadFixture(const std::string& name)
{
    const auto dir = fixtureDir();
    if (dir.empty())
    {
        return {};
    }
    std::ifstream f(dir / name, std::ios::binary);
    if (!f)
    {
        return {};
    }
    return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}

std::string switchNode(uint64_t dpid)
{
    return R"({
      "vertex_type": 0,
      "mac": 0,
      "ip": ["192.168.123.)" + std::to_string(10 + dpid) + R"("],
      "dpid": )" + std::to_string(dpid) + R"(,
      "device_name": "s)" + std::to_string(dpid) + R"(",
      "nickname": "",
      "brand_name": "BMv2",
      "bridge_name": "s)" + std::to_string(dpid) + R"(",
      "device_layer": 1,
      "ecmp_groups": []
    })";
}

/// The pre-P3 hash, written out by hand. It is the *expectation* in
/// Ipv4KeyHashIsBitIdenticalToThePreFamilyExpression, which is the only way to state "this value
/// did not change" once the code that produced it is gone -- comparing FlowKeyHash to itself
/// would pass whatever it returns.
std::size_t preFamilyHash(const sflow::FlowKey& key)
{
    std::size_t seed = 0;
    sflow::hashCombine(seed, key.srcIP);
    sflow::hashCombine(seed, key.dstIP);
    sflow::hashCombine(seed, key.srcPort);
    sflow::hashCombine(seed, key.dstPort);
    sflow::hashCombine(seed, key.protocol);
    return seed;
}

class FlowKeyFamiliesTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }

    void SetUp() override
    {
        m_topoPath = std::filesystem::temp_directory_path() /
                     ("ndt_families_test_" + std::to_string(::getpid()) + ".json");
        {
            std::ofstream ofs(m_topoPath);
            ofs << "{\n  \"nodes\": [\n" << switchNode(1) << "\n  ],\n  \"edges\": []\n}\n";
        }
        resetCollector();
    }

    void TearDown() override
    {
        std::error_code ec;
        std::filesystem::remove(m_topoPath, ec);
    }

    /// A collector with an all-bmv2 topology, so lookupOfport is the identity and the ports in
    /// the fixtures survive into the counter keys.
    void resetCollector()
    {
        m_graph = std::make_shared<Graph>();
        m_graphMutex = std::make_shared<std::shared_mutex>();
        auto bus = std::make_shared<EventBus>();
        m_monitor = std::make_shared<TestableMonitor>(m_graph, m_graphMutex, bus);
        m_monitor->loadStaticTopologyFromFile(m_topoPath.string());
        m_collector = std::make_unique<ProbeCollector>(
            m_monitor, bus, std::make_shared<ndtClassifier::Classifier>());
    }

    void feed(const std::string& name)
    {
        auto data = loadFixture(name);
        ASSERT_FALSE(data.empty())
            << name << " missing. Generate it with:\n"
            << "  p4_proxy/venv/bin/python p4_proxy/tests/generate_emitted_fixtures.py";
        m_collector->handlePacket(data.data(), data.size());
    }

    void feedBytes(std::vector<char>& data) { m_collector->handlePacket(data.data(), data.size()); }

    /// The single observation in the non-IPv4 table, or nullopt if there is not exactly one.
    std::optional<std::pair<sflow::FlowKey, sflow::FlowLinkUsageCollector::FamilyObservation>>
    soleObservation() const
    {
        const auto table = m_collector->nonIpv4Observations();
        if (table.size() != 1)
        {
            return std::nullopt;
        }
        return *table.begin();
    }

    nlohmann::json families() const
    {
        return m_collector->frameFamilyStatsJson().at("samples_by_family");
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<std::shared_mutex> m_graphMutex;
    std::shared_ptr<TestableMonitor> m_monitor;
    std::unique_ptr<ProbeCollector> m_collector;
    std::filesystem::path m_topoPath;
};

} // namespace

// =================================================================================================
// The IPv4 calibre does not move
// =================================================================================================

TEST_F(FlowKeyFamiliesTest, Ipv4KeyHashIsBitIdenticalToThePreFamilyExpression)
{
    // §2.3. FlowKey gained six members; FlowKeyHash must still return, for an IPv4 key, the exact
    // integer it returned before they existed. Not a tidiness point: the flow table is an
    // unordered_map keyed by this hash and the edge flow sets are too, so a changed hash silently
    // re-buckets every stored key -- and a stored key that hashes elsewhere is a leak, not an
    // error.
    sflow::FlowKey key{};
    key.srcIP = ::inet_addr("10.0.0.1");
    key.dstIP = ::inet_addr("10.0.0.4");
    key.srcPort = 5001;
    key.dstPort = 40997;
    key.protocol = 6;

    EXPECT_EQ(sflow::FlowKeyHash{}(key), preFamilyHash(key));
    EXPECT_EQ(key.family, sflow::FlowKeyFamily::IPv4) << "IPv4 must be the default family, or "
                                                         "every default-constructed key changes "
                                                         "bucket";

    // The other two families must NOT collapse onto that value, or the table could not tell an
    // IPv4 flow from an L2 one with coincidentally equal zeros.
    sflow::FlowKey l2{};
    l2.family = sflow::FlowKeyFamily::L2;
    l2.ethType = 0x1234;
    l2.srcMac = 0x000000000001ULL;
    l2.dstMac = 0x000000000002ULL;
    EXPECT_NE(sflow::FlowKeyHash{}(l2), preFamilyHash(l2));
}

TEST_F(FlowKeyFamiliesTest, TwoL2KeysDifferingOnlyInTheirMacsHashDifferently)
{
    // The L2 family's whole identity is its two MACs and its ethertype. A hash that ignored the
    // MACs would still give a working map -- operator== separates the keys -- so nothing would
    // fail except the bucket distribution, which nothing observes. Hence the direct assertion.
    sflow::FlowKey a{};
    a.family = sflow::FlowKeyFamily::L2;
    a.ethType = 0x1234;
    a.srcMac = 0x000000000001ULL;
    a.dstMac = 0x000000000002ULL;

    sflow::FlowKey b = a;
    b.srcMac = 0x0000000000AAULL;

    EXPECT_NE(a, b);
    EXPECT_NE(sflow::FlowKeyHash{}(a), sflow::FlowKeyHash{}(b));

    sflow::FlowKey c = a;
    c.dstMac = 0x0000000000BBULL;
    EXPECT_NE(sflow::FlowKeyHash{}(a), sflow::FlowKeyHash{}(c));
}

TEST_F(FlowKeyFamiliesTest, OrderingAmongIpv4KeysStillFollowsTheFiveTuple)
{
    // operator< gained eight members. For two IPv4 keys every one of them is equal (family) or
    // zero (the rest), so the comparison must still be decided by the five it always compared.
    sflow::FlowKey low{};
    low.srcIP = ::inet_addr("10.0.0.1");
    low.dstIP = ::inet_addr("10.0.0.2");
    low.srcPort = 1;

    sflow::FlowKey high = low;
    high.srcPort = 2;

    EXPECT_TRUE(low < high);
    EXPECT_FALSE(high < low);

    // And a family separates keys that are otherwise identical, rather than comparing equal.
    sflow::FlowKey asL2 = low;
    asL2.family = sflow::FlowKeyFamily::L2;
    EXPECT_TRUE(low < asL2);
}

TEST_F(FlowKeyFamiliesTest, AnIpv4SampleIsStillAnIpv4FlowWithTheSameFiveTuple)
{
    feed("emitted_tcp.bin");

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_EQ(table.size(), 1u);
    const sflow::FlowKey key = table.begin()->first;

    EXPECT_EQ(key.family, sflow::FlowKeyFamily::IPv4);
    EXPECT_EQ(utils::ipToString(key.srcIP), "10.0.0.1");
    EXPECT_EQ(utils::ipToString(key.dstIP), "10.0.0.4");
    EXPECT_EQ(key.srcPort, 5001);
    EXPECT_EQ(key.dstPort, 40997);
    EXPECT_EQ(int(key.protocol), 6);

    EXPECT_EQ(families().at("ipv4").get<uint64_t>(), 1u);
    EXPECT_EQ(families().at("ipv6").get<uint64_t>(), 0u);
    EXPECT_EQ(families().at("l2").get<uint64_t>(), 0u);
    EXPECT_TRUE(m_collector->nonIpv4Observations().empty())
        << "an IPv4 frame belongs in the flow table, not in the non-IPv4 side table";
}

// =================================================================================================
// §2.2 third rule: the bytes are banked before anything asks what the frame was
// =================================================================================================

TEST_F(FlowKeyFamiliesTest, AnArpSampleBanksItsLinkBytesAndIsObservedAsL2)
{
    feed("emitted_arp.bin");

    // 🔴 The claim. Before P3 this was 0: the sample was discarded at the ethertype test, which
    // sat above the byte counter.
    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, kArpIngressPort),
              kArpFrameLen * kSamplingRate)
        << "a frame that is not IPv4 still crossed the link it was sampled on";
    EXPECT_EQ(m_collector->egressByteCreditFor(kAgentIp, kArpEgressPort),
              kArpFrameLen * kSamplingRate);

    // Unchanged, and asserted here as well as in the frozen suite: ARP is not a flow.
    EXPECT_TRUE(m_collector->getFlowInfoTable().empty());
    EXPECT_EQ(m_collector->malformedDatagramCount(), 0u);

    const auto observation = soleObservation();
    ASSERT_TRUE(observation.has_value()) << "exactly one non-IPv4 identity was expected";
    const auto& [key, seen] = *observation;
    EXPECT_EQ(key.family, sflow::FlowKeyFamily::L2);
    EXPECT_EQ(key.ethType, 0x0806);
    EXPECT_EQ(sflow::macToString(key.dstMac), "ff:ff:ff:ff:ff:ff");
    EXPECT_EQ(sflow::macToString(key.srcMac), "00:00:00:00:00:01");
    EXPECT_EQ(seen.samples, 1u);
    EXPECT_EQ(seen.estimatedBytes, kArpFrameLen * kSamplingRate);

    EXPECT_EQ(families().at("l2").get<uint64_t>(), 1u);
    EXPECT_EQ(families().at("ipv4").get<uint64_t>(), 0u);
}

TEST_F(FlowKeyFamiliesTest, ACustomEtherTypeSampleBanksItsLinkBytesAndIsObservedAsL2)
{
    // 0x1234 is the source-routing exercise's own ethertype: no IP header anywhere in the frame.
    // This is the shape the generic link-usage cell (§2.7) runs over, so it is the one that has
    // to bank bytes without an L3 identity.
    feed("emitted_custom_0x1234.bin");

    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, kIngressPort),
              kCustomFrameLen * kSamplingRate);
    EXPECT_EQ(m_collector->egressByteCreditFor(kAgentIp, kEgressPort),
              kCustomFrameLen * kSamplingRate);

    const auto observation = soleObservation();
    ASSERT_TRUE(observation.has_value());
    EXPECT_EQ(observation->first.family, sflow::FlowKeyFamily::L2);
    EXPECT_EQ(observation->first.ethType, 0x1234);
    EXPECT_EQ(sflow::etherTypeToString(observation->first.ethType), "0x1234");
    EXPECT_EQ(families().at("l2").get<uint64_t>(), 1u);
}

TEST_F(FlowKeyFamiliesTest, AnIpv6UdpSampleIsObservedWithItsAddressesAndPorts)
{
    feed("emitted_ipv6_udp.bin");

    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, kIngressPort),
              kIpv6UdpFrameLen * kSamplingRate);

    const auto observation = soleObservation();
    ASSERT_TRUE(observation.has_value());
    const auto& key = observation->first;
    EXPECT_EQ(key.family, sflow::FlowKeyFamily::IPv6);
    EXPECT_EQ(sflow::ipv6ToString(key.srcIp6), "2001:db8::1");
    EXPECT_EQ(sflow::ipv6ToString(key.dstIp6), "2001:db8::2");
    EXPECT_EQ(int(key.protocol), 17);
    EXPECT_EQ(key.srcPort, 5201);
    EXPECT_EQ(key.dstPort, 33334);
    EXPECT_EQ(key.srcIP, 0u) << "an IPv6 key must not pretend to carry an IPv4 address";
    EXPECT_EQ(key.dstIP, 0u);

    EXPECT_EQ(families().at("ipv6").get<uint64_t>(), 1u);
    EXPECT_EQ(families().at("l2").get<uint64_t>(), 0u)
        << "an IPv6 frame that parses must not fall back to the L2 family";
}

// =================================================================================================
// §2.3: ihl and VLAN -- the two things that move the L4 offset
// =================================================================================================

TEST_F(FlowKeyFamiliesTest, Ipv4OptionsMoveThePortsAndTheParserFollowsThem)
{
    // The mri exercise emits IPv4 packets carrying an option, i.e. ihl > 5. The pre-P3 parser
    // read the L4 ports at a constant offset, so for this frame it would have read the option
    // bytes 01 01 and 01 00 -- ports 257 and 256 -- and recorded a flow that never existed.
    feed("emitted_ipv4_ihl6_tcp.bin");

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_EQ(table.size(), 1u);
    const sflow::FlowKey key = table.begin()->first;

    EXPECT_EQ(utils::ipToString(key.srcIP), "10.0.0.5");
    EXPECT_EQ(utils::ipToString(key.dstIP), "10.0.0.6");
    EXPECT_EQ(key.srcPort, 6001);
    EXPECT_EQ(key.dstPort, 40999);
    EXPECT_NE(key.srcPort, 257) << "257 is the option's own bytes read as a port: the header "
                                   "length was ignored";
    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, kIngressPort),
              kIhl6FrameLen * kSamplingRate);
    EXPECT_EQ(m_collector->frameFamilyStatsJson().at("malformed_ipv4_ihl").get<uint64_t>(), 0u);
}

TEST_F(FlowKeyFamiliesTest, AVlanTaggedIpv4SampleIsIdentifiedAsIpv4AfterOneTagIsStripped)
{
    feed("emitted_vlan_ipv4.bin");

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_EQ(table.size(), 1u) << "a VLAN tag must not hide the IPv4 header behind it";
    const sflow::FlowKey key = table.begin()->first;

    EXPECT_EQ(key.family, sflow::FlowKeyFamily::IPv4);
    EXPECT_EQ(utils::ipToString(key.srcIP), "10.0.0.7");
    EXPECT_EQ(utils::ipToString(key.dstIP), "10.0.0.8");
    EXPECT_EQ(key.srcPort, 4444);
    EXPECT_EQ(key.dstPort, 5555);
    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, kIngressPort),
              kVlanFrameLen * kSamplingRate);
}

TEST_F(FlowKeyFamiliesTest, AnIhlBelowFiveIsCountedAndRecordedAsNoFlowButStillBanksItsBytes)
{
    // An IPv4 header cannot be shorter than five words. The old parser had no opinion: it read
    // the ports from the constant offset regardless and recorded whatever came out.
    auto data = loadFixture("emitted_tcp.bin");
    ASSERT_FALSE(data.empty());

    // Locate the IPv4 header by its source address rather than by a hardcoded offset, so this
    // test cannot silently patch the wrong byte if the datagram layout ever shifts.
    const uint32_t srcIp = ::inet_addr("10.0.0.1");
    size_t ipHeaderAt = std::string::npos;
    for (size_t i = 0; i + 4 <= data.size(); ++i)
    {
        if (std::memcmp(data.data() + i, &srcIp, 4) == 0 && i >= 12)
        {
            ipHeaderAt = i - 12; // src address sits 12 bytes into the IPv4 header
            break;
        }
    }
    ASSERT_NE(ipHeaderAt, std::string::npos) << "the fixture's source address was not found";
    ASSERT_EQ(static_cast<uint8_t>(data[ipHeaderAt]), 0x45) << "expected version 4, ihl 5";
    data[ipHeaderAt] = static_cast<char>(0x44); // version 4, ihl 4: malformed

    feedBytes(data);

    EXPECT_EQ(m_collector->frameFamilyStatsJson().at("malformed_ipv4_ihl").get<uint64_t>(), 1u);
    EXPECT_TRUE(m_collector->getFlowInfoTable().empty())
        << "a header whose length field is impossible cannot yield a five-tuple";
    EXPECT_EQ(families().at("ipv4").get<uint64_t>(), 1u)
        << "it is still an IPv4 sample; the counters must say so rather than hide it";
    EXPECT_GT(m_collector->sampledByteCreditFor(kAgentIp, 1u), 0u)
        << "the bytes crossed the link whatever the header said";
}

// =================================================================================================
// §2.2 second rule: which bank an egress-only sample lands in
// =================================================================================================

TEST_F(FlowKeyFamiliesTest, AnEgressOnlySampleCreditsTheEgressBankAndOnlyThat)
{
    // The shape B's egress tc filters produce on host-facing ports: an output port, no input
    // port. Banked in the ingress map -- which is what the pre-P3 code did, keyed by the *output*
    // port -- the drain reads it as bytes arriving on that port and credits the reverse edge.
    feed("emitted_egress_only.bin");

    EXPECT_EQ(m_collector->egressByteCreditFor(kAgentIp, kEgressPort),
              kUdpFrameLen * kSamplingRate);
    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, kEgressPort), 0u)
        << "the ingress bank must not take an egress-only sample: that is the reverse edge";
}

TEST_F(FlowKeyFamiliesTest, TheTwoHalvesOfADualPortSampleAreTheTwoOneSidedSamples)
{
    // §2.2: "the two added together equal the effect of one of today's dual-port samples". Stated
    // as an equality between three collectors rather than as three separate absolute numbers,
    // because the interesting failure -- a sample counted on both sides, or on neither -- keeps
    // every individual number plausible.
    const uint64_t expected = kUdpFrameLen * kSamplingRate;

    // (a) dual-port: emitted_udp.bin is ingress 3, egress 4.
    feed("emitted_udp.bin");
    const uint64_t dualIngress = m_collector->sampledByteCreditFor(kAgentIp, kIngressPort);
    const uint64_t dualEgress = m_collector->egressByteCreditFor(kAgentIp, kEgressPort);
    ASSERT_EQ(dualIngress, expected);
    ASSERT_EQ(dualEgress, expected);

    // (b) ingress-only: the same datagram with its output interface (word 15) zeroed.
    resetCollector();
    auto ingressOnly = loadFixture("emitted_udp.bin");
    ASSERT_GE(ingressOnly.size(), size_t(16 * 4));
    ingressOnly[15 * 4] = ingressOnly[15 * 4 + 1] = ingressOnly[15 * 4 + 2] =
        ingressOnly[15 * 4 + 3] = 0;
    feedBytes(ingressOnly);

    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, kIngressPort), dualIngress);
    EXPECT_EQ(m_collector->egressByteCreditFor(kAgentIp, kEgressPort), 0u)
        << "there is no egress port on this sample, so nothing may be banked for one";

    // (c) egress-only: the committed fixture with ingress 0.
    resetCollector();
    feed("emitted_egress_only.bin");

    EXPECT_EQ(m_collector->egressByteCreditFor(kAgentIp, kEgressPort), dualEgress);
    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, kIngressPort), 0u);
}

// =================================================================================================
// What the endpoint publishes
// =================================================================================================

TEST_F(FlowKeyFamiliesTest, TheStatsObjectCarriesEveryFamilyAndTheNonIpv4Identities)
{
    // This object is what GET /ndt/get_sflow_stats puts on the wire verbatim, so its shape is the
    // API's shape.
    feed("emitted_tcp.bin");
    feed("emitted_arp.bin");
    feed("emitted_ipv6_udp.bin");
    feed("emitted_custom_0x1234.bin");

    const auto stats = m_collector->frameFamilyStatsJson();
    ASSERT_TRUE(stats.contains("samples_by_family"));
    ASSERT_TRUE(stats.contains("malformed_ipv4_ihl"));
    ASSERT_TRUE(stats.contains("non_ipv4_flows"));

    EXPECT_EQ(stats.at("samples_by_family").at("ipv4").get<uint64_t>(), 1u);
    EXPECT_EQ(stats.at("samples_by_family").at("ipv6").get<uint64_t>(), 1u);
    EXPECT_EQ(stats.at("samples_by_family").at("l2").get<uint64_t>(), 2u);
    EXPECT_EQ(stats.at("samples_by_family").at("undecodable").get<uint64_t>(), 0u);
    EXPECT_EQ(stats.at("malformed_ipv4_ihl").get<uint64_t>(), 0u);

    const auto& nonIpv4 = stats.at("non_ipv4_flows");
    EXPECT_EQ(nonIpv4.at("tracked").get<size_t>(), 3u) << "ARP, IPv6 and 0x1234";
    EXPECT_EQ(nonIpv4.at("dropped_over_capacity").get<uint64_t>(), 0u);
    ASSERT_EQ(nonIpv4.at("observed").size(), 3u);

    // Each row must carry the keys its own family is described by, and not the other families'.
    size_t l2Rows = 0;
    size_t ipv6Rows = 0;
    for (const auto& row : nonIpv4.at("observed"))
    {
        ASSERT_TRUE(row.contains("family"));
        if (row.at("family") == "l2")
        {
            ++l2Rows;
            EXPECT_TRUE(row.contains("src_mac"));
            EXPECT_TRUE(row.contains("dst_mac"));
            EXPECT_TRUE(row.contains("ethertype"));
            EXPECT_FALSE(row.contains("src_ip"))
                << "an L2 row has no IP address, and publishing 0 would read as one";
        }
        else if (row.at("family") == "ipv6")
        {
            ++ipv6Rows;
            EXPECT_EQ(row.at("src_ip6").get<std::string>(), "2001:db8::1");
            EXPECT_EQ(row.at("dst_ip6").get<std::string>(), "2001:db8::2");
            EXPECT_EQ(row.at("protocol_number").get<int>(), 17);
        }
        EXPECT_GT(row.at("samples").get<uint64_t>(), 0u);
        EXPECT_GT(row.at("estimated_bytes").get<uint64_t>(), 0u);
    }
    EXPECT_EQ(l2Rows, 2u);
    EXPECT_EQ(ipv6Rows, 1u);
}

TEST_F(FlowKeyFamiliesTest, RepeatedFramesOfOneIdentityAccumulateOnOneRow)
{
    feed("emitted_custom_0x1234.bin");
    feed("emitted_custom_0x1234.bin");
    feed("emitted_custom_0x1234.bin");

    const auto observation = soleObservation();
    ASSERT_TRUE(observation.has_value()) << "three frames of one identity are one row";
    EXPECT_EQ(observation->second.samples, 3u);
    EXPECT_EQ(observation->second.estimatedBytes, 3 * kCustomFrameLen * kSamplingRate);
    EXPECT_GT(observation->second.lastSeenMs, 0);
    EXPECT_EQ(families().at("l2").get<uint64_t>(), 3u);
}
