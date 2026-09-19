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
#include <array>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>
#include <thread>
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
    // Round 3, ruling 11b: there is no `dropped_over_capacity` key any more. The table evicts,
    // so that key could only ever have read 0, and asserting a constant is not a test.
    // [Co-developed with claude code -- Adam]
    EXPECT_FALSE(nonIpv4.contains("dropped_over_capacity"))
        << "a key that can only read 0 is a claim that something was measured";
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
    EXPECT_GT(observation->second.lastSeenSteadyMs, 0) << "the clock eviction orders by";
    EXPECT_GT(observation->second.lastSeenWallMs, 0) << "the clock the API publishes";
    EXPECT_EQ(families().at("l2").get<uint64_t>(), 3u);
}

// =================================================================================================
// ROUND 2 -- the fable-judge's findings on d3c65dd4
//
// [Co-developed with claude code -- Adam]
// F1 is the one that mattered: identifyFrame wrote the frame's MAC addresses and ethertype into
// the key before it knew which family it was building, and the IPv4 branch never cleared them.
// FlowKey::operator== is defaulted and the flow table is an unordered_map keyed on the whole
// struct, so on the fabric this ticket exists for -- where ndtwin_switch.p4 rewrites both MACs at
// every hop and the sample is an I2E clone carrying the ingress-time addresses -- ONE FLOW WOULD
// HAVE BECOME ONE ROW PER HOP. None of the round-1 tests could see it: they assert five fields at
// a time, the hash case builds its key by hand with zero MACs, the golden capture is a single OVS
// bridge that rewrites nothing, and the emitted fixtures all carry one fixed MAC pair.
//
// These cases are built rather than emitted for the same reason: the property is about two frames
// that differ ONLY in their MACs, which no committed fixture can express.
// =================================================================================================

namespace
{

void pushWord(std::vector<char>& out, uint32_t hostOrder)
{
    const uint32_t net = htonl(hostOrder);
    const char* p = reinterpret_cast<const char*>(&net);
    out.insert(out.end(), p, p + 4);
}

void pushNetworkWord(std::vector<char>& out, uint32_t networkOrder)
{
    const char* p = reinterpret_cast<const char*>(&networkOrder);
    out.insert(out.end(), p, p + 4);
}

void pushFrame(std::vector<char>& out, const std::vector<uint8_t>& frame)
{
    for (size_t i = 0; i < frame.size(); i += 4)
    {
        uint32_t word = 0;
        for (size_t b = 0; b < 4; ++b)
        {
            word = (word << 8) | ((i + b < frame.size()) ? frame[i + b] : uint8_t(0));
        }
        pushWord(out, word);
    }
}

void pushBe16(std::vector<uint8_t>& out, uint16_t value)
{
    out.push_back(static_cast<uint8_t>(value >> 8));
    out.push_back(static_cast<uint8_t>(value & 0xFF));
}

/// dst/src MAC as six repeats of one byte each, then the ethertype.
std::vector<uint8_t> ethernetHeader(uint8_t dstByte, uint8_t srcByte, uint16_t ethType)
{
    std::vector<uint8_t> out(6, dstByte);
    out.insert(out.end(), 6, srcByte);
    pushBe16(out, ethType);
    return out;
}

/// Ethernet + IPv4 + 8 bytes of L4. `fragmentOffset` is in 8-octet units, as on the wire.
std::vector<uint8_t> ipv4Frame(uint8_t dstMacByte,
                               uint8_t srcMacByte,
                               const char* srcIp,
                               const char* dstIp,
                               uint8_t protocol,
                               uint16_t srcPort,
                               uint16_t dstPort,
                               uint16_t fragmentOffset = 0,
                               size_t trailingPayloadBytes = 0)
{
    std::vector<uint8_t> frame = ethernetHeader(dstMacByte, srcMacByte, 0x0800);
    frame.push_back(0x45); // version 4, ihl 5
    frame.push_back(0x00);
    pushBe16(frame, 28);   // total length
    pushBe16(frame, 1);    // identification
    pushBe16(frame, static_cast<uint16_t>(fragmentOffset & 0x1FFF));
    frame.push_back(64);   // ttl
    frame.push_back(protocol);
    pushBe16(frame, 0);    // checksum
    const uint32_t src = ::inet_addr(srcIp);
    const uint32_t dst = ::inet_addr(dstIp);
    const uint8_t* srcBytes = reinterpret_cast<const uint8_t*>(&src);
    const uint8_t* dstBytes = reinterpret_cast<const uint8_t*>(&dst);
    frame.insert(frame.end(), srcBytes, srcBytes + 4);
    frame.insert(frame.end(), dstBytes, dstBytes + 4);
    pushBe16(frame, srcPort);
    pushBe16(frame, dstPort);
    pushBe16(frame, 8);
    pushBe16(frame, 0);
    frame.insert(frame.end(), trailingPayloadBytes, 0x00);
    return frame;
}

/// An L2-only frame whose source address is a function of @p index, so a test can mint as many
/// distinct L2 identities as it needs. Six bytes of MAC, not one: the L2 key is (dst, src,
/// ethertype), so varying a payload byte -- or only the low byte of the MAC -- mints far fewer
/// identities than the loop appears to. [Co-developed with claude code -- Adam] Round 2.
std::vector<uint8_t> l2FrameWithSourceIndex(uint32_t index)
{
    std::vector<uint8_t> frame(6, 0x02); // one destination for all of them
    frame.push_back(0x00);
    frame.push_back(0x00);
    frame.push_back(static_cast<uint8_t>((index >> 24) & 0xFF));
    frame.push_back(static_cast<uint8_t>((index >> 16) & 0xFF));
    frame.push_back(static_cast<uint8_t>((index >> 8) & 0xFF));
    frame.push_back(static_cast<uint8_t>(index & 0xFF));
    pushBe16(frame, 0x1234);
    frame.insert(frame.end(), 18, 0x00);
    return frame;
}

struct SampleSpec
{
    std::vector<uint8_t> frame;
    uint32_t ingress = 0;
    uint32_t egress = 0;
};

/// A Brocade (type 1) flow sample in the two-record shape the parser's MININET path requires --
/// the same layout p4_proxy/proxy_agent/sflow_emitter.py produces and test_GoldenFixture.cpp
/// pins. Built here only for frames no committed fixture can express.
void appendBrocadeSample(std::vector<char>& out, const SampleSpec& spec)
{
    const size_t paddedFrameBytes = ((spec.frame.size() + 3) / 4) * 4;
    const auto rawRecordBytes = static_cast<uint32_t>(16 + paddedFrameBytes);
    const uint32_t bodyBytes = 8 * 4 + (2 + 4) * 4 + 2 * 4 + rawRecordBytes;

    pushWord(out, 1);         // sample type: flow_sample
    pushWord(out, bodyBytes); // sample length
    pushWord(out, 1);         // sample sequence
    pushWord(out, (2u << 24) | spec.ingress);
    pushWord(out, kSamplingRate);
    pushWord(out, kSamplingRate); // sample pool
    pushWord(out, 0);             // dropped
    pushWord(out, spec.ingress);
    pushWord(out, spec.egress);
    pushWord(out, 2);    // flow record count
    pushWord(out, 1001); // record[0]: extended_switch
    pushWord(out, 16);
    for (int i = 0; i < 4; ++i) { pushWord(out, 0); }
    pushWord(out, 1); // record[1]: raw packet header
    pushWord(out, rawRecordBytes);
    pushWord(out, 1); // header protocol: Ethernet
    pushWord(out, static_cast<uint32_t>(spec.frame.size()));
    pushWord(out, 0); // stripped
    pushWord(out, static_cast<uint32_t>(spec.frame.size()));
    pushFrame(out, spec.frame);
}

std::vector<char> brocadeDatagram(const std::vector<SampleSpec>& samples)
{
    std::vector<char> out;
    pushWord(out, 5);                            // version
    pushWord(out, 1);                            // address type: IPv4
    pushNetworkWord(out, ::inet_addr(kAgentIpStr.c_str()));
    pushWord(out, 1);                            // sub-agent id
    pushWord(out, 1);                            // datagram sequence
    pushWord(out, 125000);                       // uptime
    pushWord(out, static_cast<uint32_t>(samples.size()));
    for (const auto& s : samples)
    {
        appendBrocadeSample(out, s);
    }
    return out;
}

/// An HPE (type 3) flow sample, AS THIS PARSER READS ONE.
///
/// 🔴 What this pins is the branch, not a vendor. No capture of a real HPE agent exists in this
/// repository and none ever has -- the type-3 branch has been uncovered since it was written, and
/// TICKET-P3 did not change that. It is built here from the offsets the branch itself uses
/// (sampling rate +5, input +9, output +11, frame length +16, frame at +20) so that the rewrite
/// -- which now reads the frame through identifyFrame instead of through fixed word offsets --
/// has at least one executable check that it reads the frame where it claims to.
///
/// One consequence is visible and left alone: under MININET the advancement at the end of the
/// branch subtracts the extended-switch record that a type-3 sample does not have, so the parser
/// believes the sample ends two words before it does. The frame read is bounded by that, i.e. the
/// last 8 bytes of the frame are invisible to it. That arithmetic predates this ticket; a
/// single-sample datagram is used here so it cannot desynchronise a sample chain.
std::vector<char> hpeDatagram(const SampleSpec& spec)
{
    const size_t frameWords = (spec.frame.size() + 3) / 4;
    std::vector<char> out;
    pushWord(out, 5);
    pushWord(out, 1);
    pushNetworkWord(out, ::inet_addr(kAgentIpStr.c_str()));
    pushWord(out, 1);
    pushWord(out, 1);
    pushWord(out, 125000);
    pushWord(out, 1); // one sample

    pushWord(out, 3);                                                  // +0 sample type: HPE
    pushWord(out, static_cast<uint32_t>((18 + frameWords) * 4));       // +1 length
    pushWord(out, 0);                                                  // +2
    pushWord(out, 0);                                                  // +3
    pushWord(out, 0);                                                  // +4
    pushWord(out, kSamplingRate);                                      // +5 sampling rate
    pushWord(out, 0);                                                  // +6
    pushWord(out, 0);                                                  // +7
    pushWord(out, 0);                                                  // +8
    pushWord(out, spec.ingress);                                       // +9 input interface
    pushWord(out, 0);                                                  // +10
    pushWord(out, spec.egress);                                        // +11 output interface
    for (int i = 12; i <= 15; ++i) { pushWord(out, 0); }               // +12..+15
    pushWord(out, static_cast<uint32_t>(spec.frame.size()));           // +16 frame length
    for (int i = 17; i <= 19; ++i) { pushWord(out, 0); }               // +17..+19
    pushFrame(out, spec.frame);                                        // +20..
    return out;
}

} // namespace

TEST_F(FlowKeyFamiliesTest, OneIpv4FlowStaysOneRowWhenTheMacsChangeAtEveryHop)
{
    // 🔴 F1. Two samples of the SAME five-tuple whose only difference is the Ethernet addresses
    // and the port they arrived on -- which is precisely what the twin sees for one flow crossing
    // two hops of an NDTwin fabric. One row, two per-agent stats entries.
    //
    // At d3c65dd4 this was two rows, and every consumer of the flow table would have reported the
    // flow twice with each copy's rate averaged over its own hop.
    const std::vector<SampleSpec> firstHop{
        {ipv4Frame(0x02, 0x01, "10.0.0.1", "10.0.0.4", 6, 5001, 40997), 1, 2}};
    const std::vector<SampleSpec> secondHop{
        {ipv4Frame(0xAA, 0xBB, "10.0.0.1", "10.0.0.4", 6, 5001, 40997), 3, 4}};

    auto first = brocadeDatagram(firstHop);
    auto second = brocadeDatagram(secondHop);
    feedBytes(first);
    feedBytes(second);

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_EQ(table.size(), 1u)
        << "the same five-tuple seen at two hops is one flow; " << table.size()
        << " rows means the key is carrying something the fabric rewrites per hop";

    const auto& [key, info] = *table.begin();
    EXPECT_EQ(key.srcMac, 0u);
    EXPECT_EQ(key.dstMac, 0u);
    EXPECT_EQ(key.ethType, 0u);
    EXPECT_EQ(info.agentFlowStats.size(), 2u)
        << "one row, but the two hops must still be distinguishable inside it";
}

TEST_F(FlowKeyFamiliesTest, TheParsersOwnIpv4KeyCarriesNoL2Fields)
{
    // The same property stated where it is caused rather than where it is felt, so a future
    // change that reintroduces it fails here first and with a legible message. The hash case
    // cannot do this job: it builds its key by hand, so it would keep passing.
    feed("emitted_tcp.bin");

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_EQ(table.size(), 1u);
    const sflow::FlowKey key = table.begin()->first;

    EXPECT_EQ(key.family, sflow::FlowKeyFamily::IPv4);
    EXPECT_EQ(key.srcMac, 0u) << "an IPv4 key must carry the five-tuple and nothing else";
    EXPECT_EQ(key.dstMac, 0u);
    EXPECT_EQ(key.ethType, 0u) << "0x0800 here would still be a per-family constant in the key";
    EXPECT_EQ(sflow::FlowKeyHash{}(key), preFamilyHash(key))
        << "and therefore the pre-family hash, which is what the early return promises";
}

TEST_F(FlowKeyFamiliesTest, AnIpv6KeyCarriesNoL2FieldsEither)
{
    // Same reasoning one family over: an IPv6 key with MACs would split the side table per hop.
    feed("emitted_ipv6_udp.bin");

    const auto observation = soleObservation();
    ASSERT_TRUE(observation.has_value());
    EXPECT_EQ(observation->first.srcMac, 0u);
    EXPECT_EQ(observation->first.dstMac, 0u);
    EXPECT_EQ(observation->first.ethType, 0u);
}

TEST_F(FlowKeyFamiliesTest, ANonFirstFragmentBanksItsBytesAndDoesNotEndTheDatagram)
{
    // Two samples in one datagram: a non-first fragment, then an ordinary packet. Before this
    // ticket the fragment took `continue`, and every later sample in that datagram was lost --
    // a fragment on the wire cost the twin everything batched behind it.
    //
    // 🔴 HOW it was lost is not what round 1 and round 2 said, and the difference matters because
    // the wrong mechanism suggests the wrong fix. [Co-developed with claude code -- Adam]
    // Round 3, ruling 11g. The loop's own "read position did not advance" guard did NOT fire: the
    // MININET index shift (base FlowLinkUsageCollector.cpp:1259,
    // `index += flowDataLength / 4 + 2;`) runs BEFORE the `continue` at base :1455, so the read
    // position HAD advanced -- just into the middle of the sample rather than past it. The parser
    // then read the sample's own dropped/ingress words as the next sample's type and length and
    // desynchronised from there. The symptom was the same, which is why a guard that never ran
    // could be blamed for it.
    const std::vector<SampleSpec> samples{
        {ipv4Frame(0x02, 0x01, "10.0.0.1", "10.0.0.4", 17, 1111, 2222, /*fragmentOffset=*/100),
         1, 2},
        {ipv4Frame(0x02, 0x01, "10.0.0.5", "10.0.0.6", 17, 3333, 4444), 1, 2}};
    auto datagram = brocadeDatagram(samples);
    feedBytes(datagram);

    EXPECT_EQ(m_collector->malformedDatagramCount(), 0u);

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_EQ(table.size(), 1u) << "the fragment is not a flow (it carries no ports), and the "
                                  "sample behind it must still have been parsed";
    EXPECT_EQ(table.begin()->first.srcPort, 3333) << "the surviving flow is the second sample";

    const uint64_t bothFrames = 2 * samples[0].frame.size() * kSamplingRate;
    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, 1u), bothFrames)
        << "both samples' bytes crossed the link, fragment included";
    EXPECT_EQ(families().at("ipv4").get<uint64_t>(), 2u);
}

TEST_F(FlowKeyFamiliesTest, AnHpeSampleIsReadFromWhereTheBranchSaysTheFrameIs)
{
    // See hpeDatagram's note: this pins the type-3 branch's own arithmetic, not a vendor's wire
    // format. It exists because the rewrite moved that branch from fixed word offsets to
    // identifyFrame and there was no coverage of it at all, before or after.
    //
    // The 20 trailing bytes are load-bearing, and their reason is the shortfall hpeDatagram
    // documents: the parser believes a type-3 sample ends two words before it does, so the last
    // 8 bytes of the frame are outside the bound it reads through. With a minimal 42-byte frame
    // that shortfall lands exactly on the L4 ports and this test would be asserting the
    // truncation instead of the offset. Measured, not guessed -- the first draft came back with
    // both ports 0.
    const SampleSpec spec{
        ipv4Frame(0x02, 0x01, "10.0.0.7", "10.0.0.8", 6, 8001, 9001, 0, /*trailing=*/20), 1, 2};
    auto datagram = hpeDatagram(spec);
    feedBytes(datagram);

    EXPECT_EQ(m_collector->malformedDatagramCount(), 0u);

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_EQ(table.size(), 1u) << "the HPE branch did not find an IPv4 frame where it looked";
    const sflow::FlowKey key = table.begin()->first;
    EXPECT_EQ(utils::ipToString(key.srcIP), "10.0.0.7");
    EXPECT_EQ(utils::ipToString(key.dstIP), "10.0.0.8");
    EXPECT_EQ(key.srcPort, 8001);
    EXPECT_EQ(key.dstPort, 9001);
    EXPECT_EQ(key.srcMac, 0u);
    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, 1u),
              spec.frame.size() * kSamplingRate);
}

TEST_F(FlowKeyFamiliesTest, TheSideTableEvictsItsOldestIdentityRatherThanRefusingNewOnes)
{
    // The table is capped at 1024 because its keys come off an unauthenticated UDP port. The cap
    // has to evict rather than refuse: an IPv6 key carries the L4 ports, so ordinary traffic
    // mints a new identity per ephemeral port and a refusing table freezes on whatever it saw
    // first -- and the identity an operator is looking for is the one happening now.
    constexpr uint32_t kIdentities = 1025;
    for (uint32_t i = 0; i < kIdentities; ++i)
    {
        auto datagram = brocadeDatagram({{l2FrameWithSourceIndex(i), 1, 2}});
        feedBytes(datagram);
    }

    const auto stats = m_collector->frameFamilyStatsJson();
    EXPECT_EQ(stats.at("samples_by_family").at("l2").get<uint64_t>(), uint64_t(kIdentities))
        << "every sample is counted whether or not its identity survived in the table";
    EXPECT_EQ(stats.at("non_ipv4_flows").at("tracked").get<size_t>(), 1024u);
    EXPECT_GE(stats.at("non_ipv4_flows").at("evicted_least_recently_seen").get<uint64_t>(), 1u)
        << "the cap was reached, so something must have been evicted and said so";
}

TEST_F(FlowKeyFamiliesTest, AnArpOnlySwitchCountsAsASwitchThatIsSampling)
{
    // A behaviour change round 1 did not state: m_lastSampleFromAgentMillis and the per-port
    // timestamp are now written for EVERY MININET flow sample, so a switch whose only traffic is
    // ARP or LLDP reads `live` on that port and `idle` (not `silent`) elsewhere. That is the
    // intended semantics -- A-4f's question is "is this switch sampling at all", and a switch
    // sending us ARP samples demonstrably is -- but before this ticket a non-IPv4 sample updated
    // neither, so an all-ARP link was indistinguishable from a dead sampler.
    feed("emitted_arp.bin"); // ingress port 2

    const auto onThePort = m_collector->telemetryStatusFor(kAgentIp, kArpIngressPort, 5.0);
    EXPECT_EQ(onThePort.status, "live") << "a sample arrived on this port a moment ago";

    const auto elsewhere = m_collector->telemetryStatusFor(kAgentIp, 7u, 5.0);
    EXPECT_EQ(elsewhere.status, "idle")
        << "the agent is reporting, so a quiet port really is quiet -- not unmeasurable";

    const auto otherAgent = m_collector->telemetryStatusFor(::inet_addr("192.168.123.99"), 1u, 5.0);
    EXPECT_EQ(otherAgent.status, "unknown")
        << "the control: an agent we have never heard from is not made live by someone else's ARP";
}

// =================================================================================================
// ROUND 3 -- the orchestrator's ruling 11e
//
// [Co-developed with claude code -- Adam]
// Five behaviours round 2 changed or introduced and did not pin. Four of them are cheap to state
// and were simply not stated; the fifth -- which identity the side table evicts -- is the one that
// was measured the wrong way round: round 2's case counted how many rows survived and never
// asked WHICH, so a table that evicted the newest arrival every time would have passed it.
// =================================================================================================

namespace
{

/// The key l2FrameWithSourceIndex(index) produces, so a test can ask the table about one identity
/// by name instead of counting rows. Six bytes of destination, the index in the low four bytes of
/// the source, and the exercise ethertype -- read by mac48(), which is big-endian.
sflow::FlowKey l2KeyForSourceIndex(uint32_t index)
{
    sflow::FlowKey key{};
    key.family = sflow::FlowKeyFamily::L2;
    key.dstMac = 0x020202020202ULL;
    key.srcMac = index;
    key.ethType = 0x1234;
    return key;
}

const std::array<uint8_t, 16> kIpv6Src{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11};
const std::array<uint8_t, 16> kIpv6Dst{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x22};

/// Ethernet (optionally carrying one 802.1Q tag) + IPv6 + 8 bytes of upper layer.
///
/// @p firstL4Word and @p secondL4Word are the two 16-bit words the L4 header opens with. For TCP
/// and UDP those are the source and destination ports; for ICMPv6 the first byte is the type and
/// the second the code, and this parser puts both in the port fields -- so an ICMPv6 case passes
/// (type << 8) | code as the first word. Stating it once here is cheaper than two builders that
/// would differ only in the names of two arguments.
std::vector<uint8_t> ipv6Frame(uint8_t dstMacByte,
                               uint8_t srcMacByte,
                               uint8_t nextHeader,
                               uint16_t firstL4Word,
                               uint16_t secondL4Word,
                               bool withVlanTag = false)
{
    std::vector<uint8_t> frame =
        ethernetHeader(dstMacByte, srcMacByte, withVlanTag ? uint16_t(0x8100) : uint16_t(0x86DD));
    if (withVlanTag)
    {
        pushBe16(frame, 100);    // priority 0, CFI 0, VID 100
        pushBe16(frame, 0x86DD); // and the real ethertype behind the tag
    }
    frame.push_back(0x60); // version 6
    frame.push_back(0x00);
    pushBe16(frame, 0); // flow label, low 16 bits
    pushBe16(frame, 8); // payload length
    frame.push_back(nextHeader);
    frame.push_back(64); // hop limit
    frame.insert(frame.end(), kIpv6Src.begin(), kIpv6Src.end());
    frame.insert(frame.end(), kIpv6Dst.begin(), kIpv6Dst.end());
    pushBe16(frame, firstL4Word);
    pushBe16(frame, secondL4Word);
    pushBe16(frame, 8); // length
    pushBe16(frame, 0); // checksum
    return frame;
}

} // namespace

TEST_F(FlowKeyFamiliesTest, TheSideTableEvictsTheLeastRecentlySeenIdentityAndAHitCountsAsSeen)
{
    // 🔴 WHICH identity leaves, not how many. Round 2 asserted `tracked == 1024` and
    // `evicted >= 1`, both of which a table that threw away its newest arrival would satisfy --
    // and that table is the exact failure the eviction policy exists to avoid, because the
    // identity an operator is looking for is the one happening now.
    //
    // The sleeps are the instrument, not a delay: the ordering clock is in milliseconds and a
    // thousand of these feeds fit inside one tick, so without a gap every entry carries the same
    // timestamp and "the oldest" is decided by std::map's key order. Identity 0 is made strictly
    // older than everything else; that makes it the unique minimum.
    constexpr uint32_t kCapacity = 1024;

    {
        auto first = brocadeDatagram({{l2FrameWithSourceIndex(0), 1, 2}});
        feedBytes(first);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(3));

    for (uint32_t i = 1; i <= kCapacity; ++i)
    {
        auto datagram = brocadeDatagram({{l2FrameWithSourceIndex(i), 1, 2}});
        feedBytes(datagram);
    }

    auto table = m_collector->nonIpv4Observations();
    ASSERT_EQ(table.size(), size_t(kCapacity));
    EXPECT_EQ(table.count(l2KeyForSourceIndex(0)), 0u)
        << "the identity nobody has seen since before every other one is the one that leaves";
    EXPECT_EQ(table.count(l2KeyForSourceIndex(kCapacity)), 1u)
        << "and the newest arrival is in the table, not refused at the door";

    // Now the other half: a HIT is a sighting. Identity 1 is the oldest survivor, so it is next
    // in line; touching it must move it to the back of the queue and send identity 2 instead.
    // Without this, the table would evict in insertion order regardless of who is busy.
    std::this_thread::sleep_for(std::chrono::milliseconds(3));
    {
        auto hit = brocadeDatagram({{l2FrameWithSourceIndex(1), 1, 2}});
        feedBytes(hit);
        auto newcomer = brocadeDatagram({{l2FrameWithSourceIndex(kCapacity + 1), 1, 2}});
        feedBytes(newcomer);
    }

    table = m_collector->nonIpv4Observations();
    ASSERT_EQ(table.size(), size_t(kCapacity));
    EXPECT_EQ(table.count(l2KeyForSourceIndex(1)), 1u)
        << "it was the oldest by insertion, but it was seen a moment ago";
    EXPECT_EQ(table.count(l2KeyForSourceIndex(2)), 0u)
        << "so the eviction fell on the one behind it";
    EXPECT_EQ(table.count(l2KeyForSourceIndex(kCapacity + 1)), 1u);
}

TEST_F(FlowKeyFamiliesTest, AnIcmpv6SampleCarriesItsTypeAndItsWholeCodeInThePortFields)
{
    // Type 1 (destination unreachable), code 0x1F. The code is the point: IPv4's ICMP code is
    // masked to four bits here because the pre-P3 parser did that and an IPv4 number may not
    // move, and round 2 copied the mask onto the new family by reflex. 0x1F masked would read
    // 0x0F -- a different code, silently.
    auto datagram = brocadeDatagram({{ipv6Frame(0x02, 0x01, 58, 0x011F, 0), 1, 2}});
    feedBytes(datagram);

    const auto observation = soleObservation();
    ASSERT_TRUE(observation.has_value());
    EXPECT_EQ(observation->first.family, sflow::FlowKeyFamily::IPv6);
    EXPECT_EQ(int(observation->first.protocol), 58);
    EXPECT_EQ(observation->first.srcPort, 1) << "the ICMPv6 type, in the source-port field";
    EXPECT_EQ(observation->first.dstPort, 0x1F)
        << "the whole code byte; 0x0F here would be IPv4's four-bit mask copied to a family that "
           "never had it";
}

TEST_F(FlowKeyFamiliesTest, AnIpv4SampleOfAnotherProtocolBanksItsBytesAndIsCountedWithoutBeingAFlow)
{
    // OSPF and IGMP: IPv4 frames with no five-tuple. §2.2's rule is that the link bytes are
    // recorded for every well-formed sample, and §2.3's is that the flow table stays TCP/UDP/ICMP
    // -- so these three assertions have to hold together, which is the combination round 1 said
    // only in prose ("non-IPv4 also banks") and round 2 left untested.
    const std::vector<SampleSpec> samples{
        {ipv4Frame(0x02, 0x01, "10.0.0.1", "10.0.0.2", 89, 0, 0), 1, 2},
        {ipv4Frame(0x02, 0x01, "10.0.0.3", "10.0.0.4", 2, 0, 0), 1, 2}};
    auto datagram = brocadeDatagram(samples);
    feedBytes(datagram);

    EXPECT_EQ(m_collector->malformedDatagramCount(), 0u);
    EXPECT_TRUE(m_collector->getFlowInfoTable().empty())
        << "an OSPF packet has no ports, and a row keyed on two zeros would merge every one of "
           "them into one flow";
    EXPECT_TRUE(m_collector->nonIpv4Observations().empty())
        << "and it is not the side table's business either -- it is IPv4";

    const uint64_t bothFrames =
        uint64_t(samples[0].frame.size() + samples[1].frame.size()) * kSamplingRate;
    EXPECT_EQ(m_collector->sampledByteCreditFor(kAgentIp, 1u), bothFrames)
        << "the bytes crossed the link whatever the protocol was";
    EXPECT_EQ(families().at("ipv4").get<uint64_t>(), 2u)
        << "both are IPv4 frames and samples_by_family counts frames, not flows";
    EXPECT_EQ(m_collector->ingestHealthJson().at("addressed_total").get<uint64_t>(), 2u)
        << "telemetry_health.addressed_total is now every flow sample. That outward calibre "
           "change is accepted in doc/audit/2026-09-04_p4-tutorial-exercise-prep/"
           "TICKET-P3-observation.md section 9, ruling 8 item 4; E reconciles sampling error "
           "against this number";
}

TEST_F(FlowKeyFamiliesTest, AnHpeIcmpSampleCarriesTheRealIcmpTypeRatherThanAConstantZero)
{
    // The second deliberate difference from the pre-P3 reads (the TCP ACK offset is the first).
    // The deleted HPE branch computed the ICMP type as `ntohl(word >> 8) & 0xFF` -- the shift on
    // the wrong side of the byte swap -- which is 0 for every frame on a little-endian host. No
    // capture from that vendor exists in this repository, which is why a constant went unnoticed.
    //
    // 0x0301 as the first L4 word is type 3, code 1: this parser puts an ICMP type and code in
    // the port fields. The 20 trailing bytes are hpeDatagram's documented shortfall -- the branch
    // believes the sample ends two words early, so a minimal frame would have its L4 header
    // outside the bound and this test would be measuring the truncation instead.
    const SampleSpec spec{
        ipv4Frame(0x02, 0x01, "10.0.0.7", "10.0.0.8", 1, 0x0301, 0, 0, /*trailing=*/20), 1, 2};
    auto datagram = hpeDatagram(spec);
    feedBytes(datagram);

    EXPECT_EQ(m_collector->malformedDatagramCount(), 0u);
    const auto table = m_collector->getFlowInfoTable();
    ASSERT_EQ(table.size(), 1u);
    const sflow::FlowKey key = table.begin()->first;
    EXPECT_EQ(int(key.protocol), 1);
    EXPECT_EQ(key.srcPort, 3) << "the real ICMP type; this branch used to report 0 for all of them";
    EXPECT_EQ(key.dstPort, 1) << "and the code, masked to four bits exactly as IPv4 always was";
}

TEST_F(FlowKeyFamiliesTest, AVlanTaggedIpv6SampleIsIdentifiedAsIpv6AfterOneTagIsStripped)
{
    // The tag strip and the IPv6 branch meet here. A committed fixture covers 0x8100 over IPv4
    // (emitted_vlan_ipv4.bin); nothing covered 0x8100 over IPv6, and the two share exactly one
    // line of code -- the one that rewrites `ethType` after stepping over the tag.
    auto datagram = brocadeDatagram(
        {{ipv6Frame(0x02, 0x01, 17, 5201, 33334, /*withVlanTag=*/true), 1, 2}});
    feedBytes(datagram);

    const auto observation = soleObservation();
    ASSERT_TRUE(observation.has_value()) << "0x8100 wrapping 0x86DD is an IPv6 frame";
    EXPECT_EQ(observation->first.family, sflow::FlowKeyFamily::IPv6);
    EXPECT_EQ(observation->first.srcIp6, kIpv6Src);
    EXPECT_EQ(observation->first.dstIp6, kIpv6Dst);
    EXPECT_EQ(int(observation->first.protocol), 17);
    EXPECT_EQ(observation->first.srcPort, 5201);
    EXPECT_EQ(observation->first.dstPort, 33334);
    EXPECT_EQ(observation->first.ethType, 0u)
        << "an L3 key carries no L2 fields, and 0x8100 in one would be the tag becoming part of "
           "the flow's identity";
    EXPECT_EQ(families().at("ipv6").get<uint64_t>(), 1u);
    EXPECT_EQ(families().at("l2").get<uint64_t>(), 0u)
        << "one tag is stripped; a frame reported as L2 here means it was not";
}
