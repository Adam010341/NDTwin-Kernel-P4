// [Co-developed with claude code -- Adam]
//
// Robustness tests for the sFlow datagram parser.
//
// The kernel has two external input surfaces: the /ndt/ HTTP API, and the sFlow UDP
// collector on port 6343. Everything else in the test suite covers the first. This covers
// the second, which is reachable by anything that can send a UDP packet.
//
// The parser validated only two things -- at least 28 bytes, and a length that is a
// multiple of 4 -- then indexed roughly 40 fixed word offsets (up to index+38) using a
// sample count and lengths taken straight from the datagram, with no further checks. So a
// truncated or crafted packet read past the end of the buffer: wrong numbers, or an
// occasional crash, from a source that needs no authentication. Two of the advancement
// expressions are also unsigned subtractions that wrap when the packet says so.
//
// Every test here asserts the same two things: the parser does not crash, and it returns.
// Under ASan the first would be an out-of-bounds report; without it, these still pin the
// termination behaviour and document the shapes that used to be mishandled.

#include <gtest/gtest.h>

#include "common_types/SFlowType.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <arpa/inet.h>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

namespace
{

/// Builds sFlow v5 datagrams word by word, so a test can express a malformed shape exactly.
class DatagramBuilder
{
  public:
    /// Standard v5 header: version, address type, agent IP, sub-agent, seq, uptime, count.
    DatagramBuilder& header(uint32_t sampleCount, uint32_t version = 5)
    {
        word(version);
        word(1);                       // address type: IPv4
        raw(inet_addr("192.168.123.11")); // agent IP is stored without ntohl by the parser
        word(0);                       // sub-agent id
        word(1);                       // datagram sequence number
        word(1000);                    // uptime
        word(sampleCount);
        return *this;
    }

    DatagramBuilder& word(uint32_t hostOrderValue)
    {
        m_words.push_back(htonl(hostOrderValue));
        return *this;
    }

    /// Appends a word that is already in network order (or is opaque bytes).
    DatagramBuilder& raw(uint32_t networkOrderValue)
    {
        m_words.push_back(networkOrderValue);
        return *this;
    }

    DatagramBuilder& words(size_t count, uint32_t hostOrderValue = 0)
    {
        for (size_t i = 0; i < count; ++i)
        {
            word(hostOrderValue);
        }
        return *this;
    }

    /// Appends opaque bytes, zero-padded to the 32-bit boundary sFlow requires. For frames,
    /// which are the one part of a datagram that is not word-shaped.
    /// [Co-developed with claude code -- Adam] TICKET-P3 §2.3.
    DatagramBuilder& bytesPadded(const std::vector<uint8_t>& payload)
    {
        for (size_t i = 0; i < payload.size(); i += 4)
        {
            uint32_t word = 0;
            for (size_t b = 0; b < 4; ++b)
            {
                const uint8_t octet = (i + b < payload.size()) ? payload[i + b] : uint8_t(0);
                word = (word << 8) | octet;
            }
            this->word(word);
        }
        return *this;
    }

    /// Mutable byte buffer, since handlePacket takes char*.
    std::vector<char> bytes() const
    {
        std::vector<char> out(m_words.size() * sizeof(uint32_t));
        // Guarded: memcpy with null src/dst is undefined even for a length of zero, and the
        // zero-word case is exercised by the too-short-datagram test. UBSan flags it.
        if (!m_words.empty())
        {
            std::memcpy(out.data(), m_words.data(), out.size());
        }
        return out;
    }

    size_t wordCount() const { return m_words.size(); }

  private:
    std::vector<uint32_t> m_words;
};

// [Co-developed with claude code -- Adam] TICKET-P3 §2.3.
// One flow sample in the two-record shape the parser's MININET path requires (see
// test_GoldenFixture.cpp for why record[0] is effectively mandatory), carrying an arbitrary
// frame. The emitter's committed fixtures cover the frames that matter in production; this is
// for the ones a test has to build because no emitter produces them on purpose -- a chain of
// IPv6 extension headers, and every truncation of it.
void appendFlowSample(DatagramBuilder& b,
                      const std::vector<uint8_t>& frame,
                      uint32_t ingress,
                      uint32_t egress)
{
    const size_t paddedFrameBytes = ((frame.size() + 3) / 4) * 4;
    const auto rawRecordBytes = static_cast<uint32_t>(16 + paddedFrameBytes);
    // Everything after the type and length words: 8 sample words, record[0] (2 + 4 words),
    // record[1]'s own two words, and the raw-header record's body.
    const uint32_t bodyBytes = 8 * 4 + (2 + 4) * 4 + 2 * 4 + rawRecordBytes;

    b.word(1)                      // sample type: flow_sample
        .word(bodyBytes)           // sample length, bytes, counted from the next word
        .word(1)                   // sample sequence
        .word((2u << 24) | ingress) // source id: type 2 (ifIndex) | ifIndex
        .word(256)                 // sampling rate
        .word(256)                 // sample pool
        .word(0)                   // dropped
        .word(ingress)
        .word(egress)
        .word(2)                   // flow record count
        .word(1001)                // record[0] format: extended_switch
        .word(16)
        .words(4)                  // src/dst vlan and priority, all zero
        .word(1)                   // record[1] format: raw packet header
        .word(rawRecordBytes)
        .word(1)                   // header protocol: Ethernet
        .word(static_cast<uint32_t>(frame.size())) // original frame length
        .word(0)                                   // stripped
        .word(static_cast<uint32_t>(frame.size())) // captured header length
        .bytesPadded(frame);
}

void appendBigEndian16(std::vector<uint8_t>& out, uint16_t value)
{
    out.push_back(static_cast<uint8_t>(value >> 8));
    out.push_back(static_cast<uint8_t>(value & 0xFF));
}

/// Ethernet + IPv6 + hop-by-hop + routing + fragment + UDP, in that order.
///
/// The chain is the point: §2.3 requires the parser to step over those three header types to
/// reach the ports, and every step is a length taken from the packet itself -- which is exactly
/// the shape that reads past the end of a truncated buffer.
std::vector<uint8_t> ipv6FrameWithExtensionChain()
{
    std::vector<uint8_t> frame;
    for (int i = 0; i < 6; ++i) { frame.push_back(0x02); } // dst mac
    for (int i = 0; i < 6; ++i) { frame.push_back(0x01); } // src mac
    appendBigEndian16(frame, 0x86DD);

    std::vector<uint8_t> payload;
    // hop-by-hop: next header = routing (43), length 0 (=> 8 bytes), then six bytes of options.
    payload.push_back(43);
    payload.push_back(0);
    for (int i = 0; i < 6; ++i) { payload.push_back(0x01); }
    // routing: next header = fragment (44), length 0 (=> 8 bytes).
    payload.push_back(44);
    payload.push_back(0);
    for (int i = 0; i < 6; ++i) { payload.push_back(0x00); }
    // fragment: next header = UDP, reserved, offset 0 / more-fragments 0, identification.
    payload.push_back(17);
    payload.push_back(0);
    appendBigEndian16(payload, 0x0000);
    for (int i = 0; i < 4; ++i) { payload.push_back(0x00); }
    // UDP: 4242 -> 4243.
    appendBigEndian16(payload, 4242);
    appendBigEndian16(payload, 4243);
    appendBigEndian16(payload, 8);
    appendBigEndian16(payload, 0);

    // IPv6 header: version 6, payload length, next header = hop-by-hop (0), hop limit.
    frame.push_back(0x60);
    frame.push_back(0x00);
    appendBigEndian16(frame, 0x0000);
    appendBigEndian16(frame, static_cast<uint16_t>(payload.size()));
    frame.push_back(0);  // next header: hop-by-hop
    frame.push_back(64); // hop limit
    for (int i = 0; i < 16; ++i) { frame.push_back(static_cast<uint8_t>(i == 15 ? 1 : 0)); }
    for (int i = 0; i < 16; ++i) { frame.push_back(static_cast<uint8_t>(i == 15 ? 2 : 0)); }

    frame.insert(frame.end(), payload.begin(), payload.end());
    return frame;
}

/// Finds tests/fixtures whichever directory the test binary was started from.
/// Same search as test_GoldenFixture.cpp and test_SFlowEmitterRoundtrip.cpp.
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

/// Overwrites word 0, the sFlow version field, leaving every other byte untouched.
void setVersionWord(std::vector<char>& datagram, uint32_t version)
{
    const uint32_t netOrder = htonl(version);
    std::memcpy(datagram.data(), &netOrder, sizeof(netOrder));
}

/// Exposes handlePacket. The collector's collaborators are only stored, not used, by the
/// parsing path under test, so the fixture keeps them minimal.
class TestableCollector : public sflow::FlowLinkUsageCollector
{
  public:
    TestableCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                      std::shared_ptr<EventBus> bus,
                      std::shared_ptr<ndtClassifier::Classifier> classifier,
                      int mode)
        : sflow::FlowLinkUsageCollector(std::move(monitor),
                                        nullptr,
                                        std::move(bus),
                                        mode,
                                        std::move(classifier))
    {
    }

    using sflow::FlowLinkUsageCollector::handlePacket;
    using sflow::FlowLinkUsageCollector::malformedDatagramCount;
};

class SFlowParsingFixture : public ::testing::Test
{
  protected:
    /// The parser logs, and Logger::instance() is null until init runs, so logging without
    /// it segfaults. Must be done per suite rather than relying on another one -- see the
    /// note in test_SwitchKindDispatch.cpp. Logger::init is idempotent.
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off; // the expected warnings would otherwise be noise
        Logger::init(cfg);
    }

    void SetUp() override { resetCollector(); }

    /// Discards the collector and its accumulated flow table. Tests that feed several
    /// datagrams and assert on the table after each one need a clean slate between feeds,
    /// otherwise the first feed's flows satisfy the next feed's assertion.
    void resetCollector()
    {
        auto bus = std::make_shared<EventBus>();
        auto monitor = std::make_shared<TopologyAndFlowMonitor>(
            std::make_shared<Graph>(),
            std::make_shared<std::shared_mutex>(),
            bus,
            utils::DeploymentMode::MININET);
        m_collector = std::make_unique<TestableCollector>(
            monitor, bus, std::make_shared<ndtClassifier::Classifier>(),
            utils::DeploymentMode::MININET);
    }

    /// Feeds a datagram to the parser. Returns normally iff the parser did.
    void feed(const DatagramBuilder& builder)
    {
        auto buf = builder.bytes();
        m_collector->handlePacket(buf.data(), buf.size());
    }

    void feed(std::vector<char>& buf)
    {
        m_collector->handlePacket(buf.data(), buf.size());
    }

    std::unique_ptr<TestableCollector> m_collector;
};

} // namespace

// =====================================================================================
// The pre-existing length checks
// =====================================================================================

TEST_F(SFlowParsingFixture, RejectsNullBuffer)
{
    EXPECT_NO_THROW(m_collector->handlePacket(nullptr, 64));
}

TEST_F(SFlowParsingFixture, RejectsDatagramShorterThanTheHeader)
{
    // Fewer than 7 words: the header reads alone would run off the end.
    for (size_t w = 0; w < 7; ++w)
    {
        DatagramBuilder b;
        b.words(w, 5);
        EXPECT_NO_THROW(feed(b)) << "failed at " << w << " word(s)";
    }
}

TEST_F(SFlowParsingFixture, RejectsUnalignedLength)
{
    DatagramBuilder b;
    b.header(0);
    auto buf = b.bytes();
    buf.pop_back(); // 4n-1 bytes: not 32-bit aligned
    EXPECT_NO_THROW(feed(buf));
}

// [Co-developed with claude code -- Adam]
//
// The two tests below are a matched pair over one buffer: a real OVS capture, with word 0 --
// the sFlow version field, fixed there by the v5 datagram format -- either left at 5 or
// overwritten. Everything else is byte-identical, so the only thing either test can be
// measuring is the version guard.
//
// They replace a single `EXPECT_NO_THROW(feed(b))` over hand-built bodies. A silent drop
// returns normally, so "does not throw" is also what deleting the guard does: the datagrams
// flowed into sample parsing and the test stayed green, as did every other suite, because
// every other suite feeds v5. The observable consequence of a drop is that nothing is
// extracted, so that is what these assert.
//
// The refusal test alone is not enough either -- a guard that rejected *every* version would
// satisfy it. Hence the accept-path test on the same bytes.
//
// The buffer is a captured datagram rather than a DatagramBuilder body because the assertion
// is "these bytes would otherwise yield flows", and only something a real sFlow agent emitted
// can establish that independently of the parser being tested. The fixture below was captured
// from a working OVS + Ryu + Mininet run (see test_GoldenFixture.cpp) in a test-only commit
// that predates this parser's rewrite.
//
// Not every capture qualifies. Decoding the committed set shows tcp_00, tcp_02, mixed_01 and
// mixed_02 carry LLDP frames (ethertype 0x88cc) and tcp_01 carries IPv6 (0x86dd) -- none of
// which is a flow the parser is meant to extract, so using one of those as the control would
// have made "no flows" the right answer on both sides of the guard and the pair would have
// proved nothing. tcp_03.bin is six samples of the captured iperf flow, IPv4/TCP 36154->5001.
constexpr const char* kCapturedV5Fixture = "tcp_03.bin";

TEST_F(SFlowParsingFixture, ExtractsFlowsWhenTheVersionIsFive)
{
    auto v5 = loadFixture(kCapturedV5Fixture);
    ASSERT_FALSE(v5.empty()) << "tests/fixtures/" << kCapturedV5Fixture
                             << " missing; run the test binary from the repository root";

    EXPECT_NO_THROW(feed(v5));

    EXPECT_GT(m_collector->getFlowInfoTable().size(), 0u)
        << "the control for IgnoresUnsupportedVersion: a genuine v5 datagram has to produce "
           "flows, or 'an unsupported version produces none' proves nothing";
}

TEST_F(SFlowParsingFixture, IgnoresUnsupportedVersion)
{
    const auto v5 = loadFixture(kCapturedV5Fixture);
    ASSERT_FALSE(v5.empty()) << "tests/fixtures/" << kCapturedV5Fixture
                             << " missing; run the test binary from the repository root";

    for (uint32_t version : {0u, 4u, 6u, 0xFFFFFFFFu})
    {
        // A fresh collector per version: the flow table accumulates, so one version's leak
        // would otherwise be indistinguishable from the previous version's.
        resetCollector();

        auto datagram = v5;
        setVersionWord(datagram, version);

        EXPECT_NO_THROW(feed(datagram)) << "failed for version " << version;

        EXPECT_TRUE(m_collector->getFlowInfoTable().empty())
            << "version " << version << " is not sFlow v5, so the datagram must be dropped "
            << "whole; " << m_collector->getFlowInfoTable().size()
            << " flow(s) were extracted from it instead";
    }
}

// =====================================================================================
// Truncation -- the shape that used to read past the end of the buffer
// =====================================================================================

TEST_F(SFlowParsingFixture, HandlesHeaderThatPromisesASampleWithNoBodyAtAll)
{
    // Claims one sample, then ends. Previously read data[index] and data[index+1] beyond
    // the buffer.
    DatagramBuilder b;
    b.header(1);
    EXPECT_NO_THROW(feed(b));
}

TEST_F(SFlowParsingFixture, HandlesEveryTruncationOfACounterSample)
{
    // A counter sample reads up to index+38. Cutting a full-length datagram at every word
    // between the header and that maximum exercises each offset's bounds check.
    DatagramBuilder full;
    full.header(1).word(2).word(4 * 40).words(45);
    auto complete = full.bytes();

    for (size_t keepWords = 7; keepWords * 4 <= complete.size(); ++keepWords)
    {
        std::vector<char> truncated(complete.begin(),
                                    complete.begin() + static_cast<long>(keepWords * 4));
        EXPECT_NO_THROW(feed(truncated)) << "failed at " << keepWords << " word(s)";
    }
}

TEST_F(SFlowParsingFixture, HandlesEveryTruncationOfAFlowSample)
{
    // Flow samples reach index+32 on the TCP path.
    DatagramBuilder full;
    full.header(1).word(1).word(4 * 40).words(45);
    auto complete = full.bytes();

    for (size_t keepWords = 7; keepWords * 4 <= complete.size(); ++keepWords)
    {
        std::vector<char> truncated(complete.begin(),
                                    complete.begin() + static_cast<long>(keepWords * 4));
        EXPECT_NO_THROW(feed(truncated)) << "failed at " << keepWords << " word(s)";
    }
}

// =====================================================================================
// Values the datagram controls
// =====================================================================================

TEST_F(SFlowParsingFixture, RejectsAnImpossibleSampleCount)
{
    // sampleCount was trusted verbatim: 2^32-1 meant that many loop iterations.
    DatagramBuilder b;
    b.header(0xFFFFFFFF).words(10);
    EXPECT_NO_THROW(feed(b));
}

TEST_F(SFlowParsingFixture, TerminatesWhenSampleLengthIsZero)
{
    // A zero length leaves the read position unchanged in some branches, which used to spin
    // forever. If the progress guard regresses, this test hangs rather than failing --
    // which is itself the signal.
    for (uint32_t sampleType : {1u, 2u, 3u, 4u, 99u})
    {
        DatagramBuilder b;
        b.header(4).word(sampleType).word(0).words(45);
        EXPECT_NO_THROW(feed(b)) << "failed for sampleType " << sampleType;
    }
}

TEST_F(SFlowParsingFixture, TerminatesWhenFlowDataLengthExceedsSampleLength)
{
    // The dangerous one. Two advancement expressions compute
    //     index += (sampleLen / 4 + 2 - (flowDataLength / 4 + 2));
    // in unsigned arithmetic, so flowDataLength > sampleLen wraps the result to near 2^32
    // and index leaps far outside the buffer.
    //
    // Layout for sampleType 1: word[index+1] = sampleLen, word[index+11] = flowDataLength.
    DatagramBuilder b;
    b.header(2)
        .word(1)        // sampleType: flow sample
        .word(4 * 4)    // sampleLen: deliberately small
        .words(9)       // index+2 .. index+10
        .word(4 * 1000) // index+11: flowDataLength, far larger than sampleLen
        .words(60);
    EXPECT_NO_THROW(feed(b));
}

TEST_F(SFlowParsingFixture, HandlesSampleLengthLargerThanTheDatagram)
{
    DatagramBuilder b;
    b.header(1).word(2).word(0xFFFFFFF0).words(45);
    EXPECT_NO_THROW(feed(b));
}

TEST_F(SFlowParsingFixture, HandlesUnknownSampleTypes)
{
    // Only 1-4 are recognised; the parser must skip the rest by length, not guess.
    for (uint32_t sampleType : {0u, 5u, 6u, 1000u, 0xFFFFFFFFu})
    {
        DatagramBuilder b;
        b.header(1).word(sampleType).word(4 * 10).words(45);
        EXPECT_NO_THROW(feed(b)) << "failed for sampleType " << sampleType;
    }
}

TEST_F(SFlowParsingFixture, HandlesManySamplesWithinOneDatagram)
{
    // Several well-formed-looking samples back to back, to confirm the loop walks them and
    // stops at the end rather than one word past it.
    DatagramBuilder b;
    b.header(5);
    for (int i = 0; i < 5; ++i)
    {
        b.word(2).word(4 * 12).words(10);
    }
    EXPECT_NO_THROW(feed(b));
}

TEST_F(SFlowParsingFixture, HandlesNonIpv4EtherType)
{
    // ARP / IPv6 / LLDP frames take the early-continue path, which also advances the index
    // via the unsigned expression above.
    for (uint32_t etherType : {0x0806u, 0x86DDu, 0x88CCu})
    {
        DatagramBuilder b;
        b.header(1).word(1).word(4 * 30).words(11);
        b.word(4 * 8);              // flowDataLength
        b.word(64);                 // frameLength
        b.words(5);
        b.word(etherType << 16);    // the parser reads the top 16 bits
        b.words(30);
        EXPECT_NO_THROW(feed(b)) << "failed for etherType " << etherType;
    }
}

// =====================================================================================
// Fuzz-ish sweep: structured garbage must never crash or hang
// =====================================================================================

TEST_F(SFlowParsingFixture, SurvivesStructuredGarbage)
{
    // Deterministic pseudo-random payloads with a valid header, so the parser gets past the
    // version check and into the offset arithmetic with arbitrary lengths and types.
    uint32_t seed = 0x12345678;
    auto next = [&seed]() {
        seed = seed * 1664525u + 1013904223u; // numerical recipes LCG
        return seed;
    };

    for (int iteration = 0; iteration < 500; ++iteration)
    {
        DatagramBuilder b;
        b.header(next() % 8);
        const size_t payloadWords = next() % 60;
        for (size_t w = 0; w < payloadWords; ++w)
        {
            b.raw(next());
        }
        EXPECT_NO_THROW(feed(b)) << "failed at iteration " << iteration;
    }
}

TEST_F(SFlowParsingFixture, SurvivesTruncationSweepOverGarbage)
{
    uint32_t seed = 0xDEADBEEF;
    auto next = [&seed]() {
        seed = seed * 1664525u + 1013904223u;
        return seed;
    };

    for (int iteration = 0; iteration < 100; ++iteration)
    {
        DatagramBuilder b;
        b.header(1 + next() % 4);
        for (size_t w = 0; w < 50; ++w)
        {
            b.raw(next());
        }
        auto complete = b.bytes();
        // Cut at a random 4-byte boundary at or after the header.
        const size_t keepWords = 7 + (next() % (complete.size() / 4 - 7));
        std::vector<char> truncated(complete.begin(),
                                    complete.begin() + static_cast<long>(keepWords * 4));
        EXPECT_NO_THROW(feed(truncated)) << "failed at iteration " << iteration;
    }
}

// =====================================================================================
// Malformed-packet accounting
// =====================================================================================

TEST_F(SFlowParsingFixture, CountsEveryMalformedDatagramEvenThoughLoggingIsRateLimited)
{
    // The log is capped at one per thousand so a flood cannot fill the disk, but the count
    // must stay exact -- otherwise rate limiting would hide how bad the input is.
    const uint64_t before = m_collector->malformedDatagramCount();

    for (int i = 0; i < 50; ++i)
    {
        DatagramBuilder b;
        b.header(1).word(2).word(4 * 40); // promises a counter sample, then ends
        EXPECT_NO_THROW(feed(b));
    }

    EXPECT_EQ(m_collector->malformedDatagramCount(), before + 50);
}

// =====================================================================================
// The bounded view itself
// =====================================================================================

TEST(BoundedWordsTest, ReadsInRangeWordsUnchanged)
{
    const uint32_t raw[3] = {0x11111111, 0x22222222, 0x33333333};
    const sflow::BoundedWords view(raw, 3);

    EXPECT_EQ(view[0], 0x11111111u);
    EXPECT_EQ(view[2], 0x33333333u);
    EXPECT_EQ(view.size(), 3u);
}

TEST(BoundedWordsTest, ThrowsPastTheEnd)
{
    const uint32_t raw[2] = {1, 2};
    const sflow::BoundedWords view(raw, 2);

    EXPECT_NO_THROW(view[1]);
    EXPECT_THROW(view[2], sflow::TruncatedDatagram);
    EXPECT_THROW(view[1000000], sflow::TruncatedDatagram);
}

TEST(BoundedWordsTest, ReportsTheOffendingOffset)
{
    const uint32_t raw[2] = {1, 2};
    const sflow::BoundedWords view(raw, 2);

    try
    {
        (void)view[38]; // the deepest offset the counter-sample path reaches
        FAIL() << "expected TruncatedDatagram";
    }
    catch (const sflow::TruncatedDatagram& e)
    {
        EXPECT_EQ(e.requestedWord(), 38u);
        EXPECT_EQ(e.availableWords(), 2u);
    }
}

TEST(BoundedWordsTest, EmptyViewThrowsOnAnyAccess)
{
    const sflow::BoundedWords view(nullptr, 0);
    EXPECT_THROW(view[0], sflow::TruncatedDatagram);
    EXPECT_FALSE(view.has(0));
}

// --- A-4f: telling "this link is idle" apart from "nothing is measuring this link".
//
// [Co-developed with claude code -- Adam]
// An OVS power cycle deletes the bridge and with it the sFlow record, so the switch keeps
// forwarding and stops sampling. The links arriving at it then publish exactly 0 bps for ever,
// which is bit-identical to an idle link's 0 and to a kernel that started a moment ago.
//
// 🔑 The hard limit these tests encode: with polling=0 an idle interface emits nothing at all,
// so ONE link cannot answer the question about itself. The only signal above that noise floor is
// whether the same agent is reporting on any of its other ports. Every case below is really a
// case about that distinction, and the two that carry it are the pair
// `AnAgentStillReportingElsewhereMakesThisLinksZeroAMeasurement` /
// `AnAgentReportingNowhereMakesThisLinksZeroAnAbsence` -- identical silence on the port itself,
// opposite verdicts. A classifier that cannot separate those has not implemented this feature.

namespace
{
constexpr int64_t kNow = 1000000; // arbitrary steady-clock millisecond reading
using Telemetry = sflow::FlowLinkUsageCollector;
} // namespace

TEST(TelemetrySilenceTest, AnAgentThatHasNeverReportedIsUnknownRatherThanSilent)
{
    // A kernel ten seconds old and a switch that was never given an sFlow record look identical
    // from in here. "unknown" is the only one of the four answers that is not a guess.
    const auto out = Telemetry::classifyTelemetry(kNow, 0, 0, 5.0);
    EXPECT_EQ(out.status, "unknown");
    EXPECT_DOUBLE_EQ(out.lastSampleAgeSeconds, -1.0);
    EXPECT_DOUBLE_EQ(out.agentLastSampleAgeSeconds, -1.0);
}

TEST(TelemetrySilenceTest, ARecentSampleOnThisPortIsLive)
{
    const auto out = Telemetry::classifyTelemetry(kNow, kNow - 300, kNow - 300, 5.0);
    EXPECT_EQ(out.status, "live");
    EXPECT_DOUBLE_EQ(out.lastSampleAgeSeconds, 0.3);
}

TEST(TelemetrySilenceTest, AnAgentStillReportingElsewhereMakesThisLinksZeroAMeasurement)
{
    // Nothing on this port for a minute, but the agent sampled 400 ms ago on another one. The
    // sampler is alive, so this link really is carrying nothing: the 0 is a measurement.
    const auto out = Telemetry::classifyTelemetry(kNow, kNow - 60000, kNow - 400, 5.0);
    EXPECT_EQ(out.status, "idle");
    EXPECT_DOUBLE_EQ(out.lastSampleAgeSeconds, 60.0);
    EXPECT_DOUBLE_EQ(out.agentLastSampleAgeSeconds, 0.4);
}

TEST(TelemetrySilenceTest, AnAgentReportingNowhereMakesThisLinksZeroAnAbsence)
{
    // A-4f itself. The port has been silent for exactly as long as in the case above; the whole
    // difference is in the agent, which is the only place the difference exists.
    const auto out = Telemetry::classifyTelemetry(kNow, kNow - 60000, kNow - 60000, 5.0);
    EXPECT_EQ(out.status, "silent");
}

TEST(TelemetrySilenceTest, APortNeverSeenUnderALiveAgentIsIdleNotUnknown)
{
    // The link has never carried a sampled packet, but the switch is demonstrably sampling. That
    // is an ordinary quiet link, not an unmeasurable one.
    const auto out = Telemetry::classifyTelemetry(kNow, 0, kNow - 100, 5.0);
    EXPECT_EQ(out.status, "idle");
    EXPECT_DOUBLE_EQ(out.lastSampleAgeSeconds, -1.0);
}

TEST(TelemetrySilenceTest, TheWindowBoundaryIsInclusiveOnBothSides)
{
    // Exactly at the window is still current; one millisecond past it is not. Pinned because an
    // off-by-one here turns healthy links `silent` once a second, which is the fastest way to
    // get a real check switched off for crying wolf.
    EXPECT_EQ(Telemetry::classifyTelemetry(kNow, kNow - 5000, kNow - 5000, 5.0).status, "live");
    EXPECT_EQ(Telemetry::classifyTelemetry(kNow, kNow - 5001, kNow - 5001, 5.0).status, "silent");
}

TEST(TelemetrySilenceTest, TheWindowIsConsultedRatherThanHardcoded)
{
    // Same instants, different window, opposite verdicts -- so the parameter is really read.
    EXPECT_EQ(Telemetry::classifyTelemetry(kNow, kNow - 8000, kNow - 8000, 5.0).status, "silent");
    EXPECT_EQ(Telemetry::classifyTelemetry(kNow, kNow - 8000, kNow - 8000, 30.0).status, "live");
}

TEST(TelemetrySilenceTest, TheRawAgesAreReportedAlongsideEveryVerdict)
{
    // The label is a verdict; the ages are the evidence it was derived from. Serving only the
    // verdict is the code grading its own homework -- the same reason the rate-divisor gate logs
    // two numbers instead of a boolean -- and a reader could not tell a check that fired from a
    // check that never ran.
    const auto out = Telemetry::classifyTelemetry(kNow, kNow - 2500, kNow - 1250, 5.0);
    EXPECT_DOUBLE_EQ(out.lastSampleAgeSeconds, 2.5);
    EXPECT_DOUBLE_EQ(out.agentLastSampleAgeSeconds, 1.25);
}

// =====================================================================================
// IPv6 extension headers -- TICKET-P3 §2.3
//
// [Co-developed with claude code -- Adam]
// The chain walk is the one loop in the frame parser whose step size comes out of the packet:
// each extension header says how long it is, in 8-octet units, and the next one starts there.
// That is the same shape as every other read this suite exists for -- a length taken from an
// unauthenticated UDP datagram and used as an offset -- with one addition: it can also loop.
// The bound is kMaxIpv6ExtensionHeaders; the truncations below are the other half.
//
// The frames here are built rather than captured because no emitter in this project produces an
// extension-header chain on purpose. Where a committed fixture exists (plain IPv6/UDP), the
// assertions live in test_FlowKeyFamilies.cpp against the emitter's own bytes.
// =====================================================================================

TEST_F(SFlowParsingFixture, HandlesEveryTruncationOfAnIpv6ExtensionHeaderChain)
{
    DatagramBuilder b;
    b.header(1);
    appendFlowSample(b, ipv6FrameWithExtensionChain(), 3, 4);
    const auto complete = b.bytes();

    for (size_t keepWords = 7; keepWords * 4 <= complete.size(); ++keepWords)
    {
        // A fresh collector per truncation: this asserts termination, and an accumulated flow
        // table from a longer prefix would make a later failure harder to attribute.
        resetCollector();
        std::vector<char> truncated(complete.begin(),
                                    complete.begin() + static_cast<long>(keepWords * 4));
        EXPECT_NO_THROW(feed(truncated)) << "failed at " << keepWords << " word(s)";
    }
}

TEST_F(SFlowParsingFixture, AFullIpv6ExtensionChainResolvesToTheUpperLayerPorts)
{
    // The control for the two cases below: without it, "the chain was not resolved" would be
    // satisfied by a parser that never resolves one.
    DatagramBuilder b;
    b.header(1);
    appendFlowSample(b, ipv6FrameWithExtensionChain(), 3, 4);
    feed(b);

    const auto observed = m_collector->nonIpv4Observations();
    ASSERT_EQ(observed.size(), 1u);
    const auto& key = observed.begin()->first;
    EXPECT_EQ(key.family, sflow::FlowKeyFamily::IPv6);
    EXPECT_EQ(int(key.protocol), 17) << "hop-by-hop, routing and fragment were to be stepped over";
    EXPECT_EQ(key.srcPort, 4242);
    EXPECT_EQ(key.dstPort, 4243);
}

TEST_F(SFlowParsingFixture, AnOpaqueIpv6ExtensionHeaderFallsBackToTheL2Identity)
{
    // ESP (50) is encrypted: its payload is not an L4 header and reading one out of it would be
    // an invented five-tuple. §2.3's rule is to report what is still known -- the two MAC
    // addresses -- rather than to guess.
    auto frame = ipv6FrameWithExtensionChain();
    ASSERT_GT(frame.size(), size_t(54 + 8));
    frame[54 + 8] = 50; // the routing header's own next-header byte

    DatagramBuilder b;
    b.header(1);
    appendFlowSample(b, frame, 3, 4);
    feed(b);

    const auto observed = m_collector->nonIpv4Observations();
    ASSERT_EQ(observed.size(), 1u);
    const auto& key = observed.begin()->first;
    EXPECT_EQ(key.family, sflow::FlowKeyFamily::L2)
        << "an unsteppable header must not leave an IPv6 key carrying whatever byte was at the "
           "port offset";
    EXPECT_EQ(key.ethType, 0x86DD) << "the ethertype is still known and still says IPv6";
    EXPECT_EQ(int(key.protocol), 0);
    EXPECT_EQ(key.srcPort, 0);
}

TEST_F(SFlowParsingFixture, AChainCutOffInsideTheCapturedHeaderDoesNotInventPorts)
{
    // The realistic case, not a crafted one: the agent captures 128 bytes and a long chain runs
    // past them. The walk then runs out of frame rather than out of chain.
    auto frame = ipv6FrameWithExtensionChain();
    ASSERT_GT(frame.size(), size_t(54 + 16));
    frame.resize(54 + 16); // Ethernet + IPv6 + hop-by-hop + routing, and nothing after

    DatagramBuilder b;
    b.header(1);
    appendFlowSample(b, frame, 3, 4);
    feed(b);

    const auto observed = m_collector->nonIpv4Observations();
    ASSERT_EQ(observed.size(), 1u);
    EXPECT_EQ(observed.begin()->first.family, sflow::FlowKeyFamily::L2);
    EXPECT_EQ(observed.begin()->first.srcPort, 0);
    EXPECT_EQ(m_collector->malformedDatagramCount(), 0u)
        << "the datagram is well formed; it is the captured header that ends early";
}
