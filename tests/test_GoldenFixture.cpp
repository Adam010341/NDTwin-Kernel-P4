// [Co-developed with claude code -- Adam]
//
// Golden-fixture test: real sFlow datagrams captured from a working OVS + Ryu + Mininet run,
// fed to the kernel's own parser.
//
// This exists because Phase 5 of doc/2026-07-27_p4_bmv2_support_plan.md has the P4 proxy synthesise
// sFlow into this same collector. If the emitter's byte layout differs from what OVS
// produces, the twin silently gets no telemetry at all -- so the layout the parser requires
// needs to be a tested fact, not a reading of the code. It was captured with:
//
//   sudo tcpdump -i any -s 0 -w /tmp/ovs_sflow.pcap 'udp port 6343'
//
// while traffic ran between h1 and h2, then the UDP payloads were extracted.
//
//   tcp_*.bin    -- iperf (TCP), the bulk of the capture
//   mixed_*.bin  -- iperf -u (UDP), ping (ICMP) and LLDP, one or two samples each
//
// The captured layout, consistent across all 2863 flow samples in the capture:
//
//   sFlow v5 datagram header ...................... words 0-6
//   flow_sample (type 1) with TWO flow records:
//     record[0] = extended_switch   (format 1001, 16 bytes of data)
//     record[1] = raw packet header (format 1), carrying the Ethernet frame
//
// The parser depends on that two-record shape. In MININET mode it reads record[0]'s length
// and steps over it before reading anything from the packet:
//
//     flowDataLength = data[index + 11];      // record[0] length
//     index += flowDataLength / 4 + 2;        // format + length + data
//
// and only then reads frameLength / etherType / protocol at fixed offsets from the advanced
// index. A flow sample carrying only the raw-header record -- perfectly legal sFlow -- would
// therefore make it skip six words it should have read, landing mid-frame, and every field
// after that would be garbage. That makes the extended_switch record effectively mandatory
// for anything emitting into this collector: the single most important constraint on the
// Phase 5 emitter, and not apparent from reading the parser in isolation.

#include <gtest/gtest.h>

#include "common_types/SFlowType.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <algorithm>
#include <arpa/inet.h>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

namespace
{

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

    using sflow::FlowLinkUsageCollector::handlePacket;
    using sflow::FlowLinkUsageCollector::malformedDatagramCount;
};

/// Finds tests/fixtures whichever directory the test binary was started from.
std::filesystem::path fixtureDir()
{
    for (const auto* candidate :
         {"tests/fixtures", "../tests/fixtures", "../../tests/fixtures"})
    {
        if (std::filesystem::is_directory(candidate))
        {
            return candidate;
        }
    }
    return {};
}

std::vector<std::vector<char>> loadFixtures()
{
    std::vector<std::vector<char>> out;
    const auto dir = fixtureDir();
    if (dir.empty())
    {
        return out;
    }

    std::vector<std::filesystem::path> paths;
    for (const auto& entry : std::filesystem::directory_iterator(dir))
    {
        if (entry.path().extension() != ".bin")
        {
            continue;
        }
        // [Co-developed with claude code -- Adam]
        // The emitted_*.bin files are written by p4_proxy/tests/generate_emitted_fixtures.py --
        // bytes this project's own Python emitter produced, not bytes a switch produced. This
        // loop used to take every .bin in the directory, so the seven emitted files sat in the
        // same set as the twenty-four captures, and the assertions below measured a mixture
        // while claiming to measure real traffic.
        //
        // That was not a cosmetic imprecision: the emitted files alone satisfy every one of
        // them. emitted_tcp.bin is 10.0.0.1:5001 -> 10.0.0.4:40997 TCP, so it yields a flow, it
        // matches the iperf five-tuple check, and emitted_tcp/udp/icmp cover all three protocol
        // paths. If every genuine capture stopped parsing tomorrow, all three tests stayed
        // green -- while this file's own comment says the point is "bytes a switch actually
        // produced, rather than bytes a test invented".
        //
        // The emitted files are not unguarded: test_SFlowEmitterRoundtrip.cpp parses them
        // deliberately, and CommittedFixtureTest checks they have not drifted. They simply do
        // not belong in a suite whose subject is captured traffic.
        if (entry.path().filename().string().rfind("emitted_", 0) == 0)
        {
            continue;
        }
        paths.push_back(entry.path());
    }
    std::sort(paths.begin(), paths.end()); // deterministic order

    for (const auto& p : paths)
    {
        std::ifstream f(p, std::ios::binary);
        out.emplace_back(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    }
    return out;
}

uint32_t wordAt(const std::vector<char>& d, size_t i)
{
    uint32_t v = 0;
    std::memcpy(&v, d.data() + i * 4, sizeof(v));
    return ntohl(v);
}

class GoldenFixtureTest : public ::testing::Test
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
        auto bus = std::make_shared<EventBus>();
        auto monitor = std::make_shared<TopologyAndFlowMonitor>(
            std::make_shared<Graph>(),
            std::make_shared<std::shared_mutex>(),
            bus,
            utils::DeploymentMode::MININET);
        m_collector = std::make_unique<ProbeCollector>(
            monitor, bus, std::make_shared<ndtClassifier::Classifier>());
    }

    /// Feeds every fixture through the parser.
    void feedAll(std::vector<std::vector<char>>& fixtures)
    {
        for (auto& f : fixtures)
        {
            m_collector->handlePacket(f.data(), f.size());
        }
    }

    std::unique_ptr<ProbeCollector> m_collector;
};

} // namespace

TEST_F(GoldenFixtureTest, TheFixtureSetIsCapturedTrafficOnly)
{
    // [Co-developed with claude code -- Adam]
    // The claim this whole suite rests on, asserted rather than assumed. loadFixtures() used to
    // take every .bin in the directory, which put the seven emitted_*.bin files -- written by
    // this project's own Python emitter -- into a set the tests describe as real captured
    // traffic. The emitted files alone satisfy every assertion here, so if every genuine capture
    // stopped parsing tomorrow the suite stayed green while claiming otherwise.
    //
    // Counted from the directory rather than hardcoded: a recapture that adds files must not
    // need this number edited, and a hardcoded count would go stale the way this project's test
    // counts already have, twice.
    const auto dir = fixtureDir();
    ASSERT_FALSE(dir.empty()) << "fixture directory not found";

    size_t captures = 0;
    size_t emitted = 0;
    for (const auto& entry : std::filesystem::directory_iterator(dir))
    {
        if (entry.path().extension() != ".bin")
        {
            continue;
        }
        if (entry.path().filename().string().rfind("emitted_", 0) == 0)
        {
            ++emitted;
        }
        else
        {
            ++captures;
        }
    }

    ASSERT_GT(captures, 0u) << "no captured fixtures at all";
    ASSERT_GT(emitted, 0u)
        << "no emitted fixtures present, so this test cannot observe them being excluded -- it "
           "would pass whether or not the filter exists";

    EXPECT_EQ(loadFixtures().size(), captures)
        << "the fixture set is not captures alone: " << emitted << " emitted file(s) are on disk "
        << "and the loaded count does not match the " << captures << " captures. Every assertion "
        << "in this suite would then be measuring bytes a test invented.";
}

TEST_F(GoldenFixtureTest, FixturesArePresentAndWellFormed)
{
    const auto fixtures = loadFixtures();
    ASSERT_FALSE(fixtures.empty())
        << "no fixtures in tests/fixtures. Recapture from a working OVS run with traffic "
           "flowing: sudo tcpdump -i any -s 0 -w /tmp/ovs_sflow.pcap 'udp port 6343'";

    for (const auto& f : fixtures)
    {
        ASSERT_GE(f.size(), 28u) << "shorter than the sFlow header the parser requires";
        EXPECT_EQ(f.size() % 4, 0u) << "sFlow datagrams are 32-bit aligned";
        EXPECT_EQ(wordAt(f, 0), 5u) << "fixtures should be sFlow v5";
    }
}

TEST_F(GoldenFixtureTest, ParsesRealOvsDatagramsIntoFlows)
{
    // The headline assertion: the parser extracts flows from genuine OVS output. If a future
    // OVS version or sFlow configuration changes the layout, this fails loudly instead of the
    // twin quietly reporting no traffic.
    auto fixtures = loadFixtures();
    ASSERT_FALSE(fixtures.empty());

    feedAll(fixtures);

    EXPECT_GT(m_collector->getFlowInfoTable().size(), 0u)
        << "no flows extracted from " << fixtures.size() << " real OVS datagrams";

    EXPECT_EQ(m_collector->malformedDatagramCount(), 0u)
        << "real OVS datagrams were rejected as malformed";
}

TEST_F(GoldenFixtureTest, ExtractsTheCapturedIperfFlowExactly)
{
    // Asserting the actual 5-tuple, not merely that "some flow appeared", is what makes this
    // a golden fixture: it pins the byte offsets, the network-order handling and the port
    // extraction simultaneously.
    auto fixtures = loadFixtures();
    ASSERT_FALSE(fixtures.empty());

    feedAll(fixtures);

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_GT(table.size(), 0u);

    bool foundIperf = false;
    for (const auto& [key, info] : table)
    {
        const std::string src = utils::ipToString(key.srcIP);
        const std::string dst = utils::ipToString(key.dstIP);

        // Mininet's default host addressing.
        EXPECT_EQ(src.rfind("10.0.0.", 0), 0u) << "unexpected source " << src;
        EXPECT_EQ(dst.rfind("10.0.0.", 0), 0u) << "unexpected destination " << dst;

        // 5001 is iperf's default TCP port.
        if (key.protocol == 6 && (key.srcPort == 5001 || key.dstPort == 5001))
        {
            foundIperf = true;
        }
    }

    EXPECT_TRUE(foundIperf)
        << "no TCP flow on iperf's default port 5001; the capture may not cover the iperf run";
}

TEST_F(GoldenFixtureTest, ExtractsAllThreeProtocolPathsFromRealTraffic)
{
    // The parser branches on protocol: TCP additionally reads the flags word at index+32 --
    // the deepest offset any path reaches -- while ICMP reads type and code where TCP and UDP
    // read ports. Covering all three with real captured packets exercises each branch against
    // bytes a switch actually produced, rather than bytes a test invented.
    auto fixtures = loadFixtures();
    ASSERT_FALSE(fixtures.empty());

    feedAll(fixtures);

    const auto table = m_collector->getFlowInfoTable();
    ASSERT_GT(table.size(), 0u);

    bool tcp = false;
    bool udp = false;
    bool icmp = false;
    for (const auto& [key, info] : table)
    {
        switch (key.protocol)
        {
        case 6:  tcp = true;  break;
        case 17: udp = true;  break;
        case 1:  icmp = true; break;
        default:
            ADD_FAILURE() << "unexpected protocol " << int(key.protocol)
                          << " extracted from the capture";
            break;
        }
    }

    EXPECT_TRUE(tcp) << "no TCP flow (from the iperf capture)";
    EXPECT_TRUE(udp) << "no UDP flow (from the iperf -u capture)";
    EXPECT_TRUE(icmp) << "no ICMP flow (from the ping capture)";
}

TEST_F(GoldenFixtureTest, IgnoresNonIpv4Frames)
{
    // The capture contains LLDP (0x88cc) and one IPv6 frame. The parser only handles IPv4 and
    // must skip the rest without mistaking them for flows -- an off-by-one in the sample
    // advancement would show up here as a bogus flow with a nonsense protocol.
    auto fixtures = loadFixtures();
    ASSERT_FALSE(fixtures.empty());

    feedAll(fixtures);

    for (const auto& [key, info] : m_collector->getFlowInfoTable())
    {
        EXPECT_TRUE(key.protocol == 6 || key.protocol == 17 || key.protocol == 1)
            << "protocol " << int(key.protocol)
            << " suggests a non-IPv4 frame was parsed as a flow";
    }
}

TEST_F(GoldenFixtureTest, RequiresExtendedSwitchRecordBeforeTheRawHeader)
{
    // The constraint the Phase 5 emitter must satisfy, as an executable check rather than a
    // comment. See the file header for why removing record[0] would corrupt every field.
    auto fixtures = loadFixtures();
    ASSERT_FALSE(fixtures.empty());

    size_t flowSamplesChecked = 0;
    for (const auto& f : fixtures)
    {
        const size_t words = f.size() / 4;
        ASSERT_GE(words, 7u);
        const uint32_t sampleCount = wordAt(f, 6);

        size_t index = 7;
        for (uint32_t s = 0; s < sampleCount && index + 16 < words; ++s)
        {
            const uint32_t sampleType = wordAt(f, index);
            const uint32_t sampleLen = wordAt(f, index + 1);

            if (sampleType == 1) // flow sample
            {
                EXPECT_EQ(wordAt(f, index + 9), 2u)
                    << "the parser's MININET path assumes exactly two flow records";
                EXPECT_EQ(wordAt(f, index + 10), 1001u)
                    << "record 0 must be extended_switch (format 1001): the parser steps over "
                       "it by length before reading the packet";
                EXPECT_EQ(wordAt(f, index + 11), 16u)
                    << "extended_switch carries 16 bytes (src/dst vlan and priority)";
                EXPECT_EQ(wordAt(f, index + 16), 1u)
                    << "record 1 must be the raw packet header (format 1)";
                ++flowSamplesChecked;
            }

            if (sampleLen == 0)
            {
                break; // malformed; the parser's own guard covers this case
            }
            index += sampleLen / 4 + 2;
        }
    }

    EXPECT_GT(flowSamplesChecked, 0u) << "fixtures contained no flow samples";
}
