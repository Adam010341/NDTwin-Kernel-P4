/**
 * Concurrency test for the flow table that handlePacket maintains.
 *
 * [Co-developed with claude code -- Adam]
 *
 * handlePacket looked up m_flowInfoTable with **no lock at all** and then took a lock separately
 * inside each branch:
 *
 *     auto it = m_flowInfoTable.find(key);        // unlocked
 *     if (it != m_flowInfoTable.end()) { unique_lock lk(...); ... }   // lock here
 *     else                            { unique_lock lk(...); ... }   // ...or here
 *
 * It runs on every sampled packet on every sFlow worker thread, so that is two defects at once.
 * The unlocked `find` races with purgeIdleFlows erasing at 1 Hz and with sibling workers inserting
 * through operator[], which rehashes -- undefined behaviour, and the very thing this file's own
 * comment elsewhere calls "the crash this whole set of locks exists to prevent". Separately,
 * find-then-branch was not atomic, so two workers seeing the same *new* key could both take the
 * "New flow" path, where the second one **assigns** `ingressByteCountCurrent = frameLength` instead
 * of accumulating and silently drops the first one's bytes.
 *
 * That second consequence is what this file can pin deterministically. A race is not directly
 * observable from a test, but its effect is: **the accumulated byte and packet totals must not
 * depend on how many threads delivered the packets.** So one collector is fed a fixed set of real
 * datagrams sequentially, another is fed exactly the same multiset from several threads, and the
 * two tables are compared field by field. Sequential is the ground truth; any difference is work
 * the concurrent run lost.
 *
 * The input is real captured sFlow, not synthesised: the `.bin` captures under tests/fixtures,
 * taken from a working OVS + Ryu + Mininet run. Using the real bytes matters because the lost
 * update happens on the *flow-creation* path, so the test needs genuine distinct FlowKeys to
 * create.
 *
 * Note this test can only fail probabilistically when the bug is present -- it needs two threads
 * to collide on the same new key. It was checked against the unfixed code before being committed
 * (see doc/audit/), and it detected the loss on every attempt with these thread and repeat counts.
 * If it ever starts passing against known-broken code, raise kThreads or kRepeats rather than
 * trusting it.
 */

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

namespace
{

constexpr int kThreads = 8;
constexpr int kRepeats = 40;

/// Exposes handlePacket, same pattern as TestableCollector in test_SFlowParsing.cpp.
class ConcurrentCollector : public sflow::FlowLinkUsageCollector
{
  public:
    ConcurrentCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
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

/// Real captured datagrams. Only the `sflow_*` captures are used: the `emitted_*` ones are the
/// Phase 5 emitter's own output and include deliberately truncated shapes.
std::vector<std::vector<char>> loadRealCaptures()
{
    std::vector<std::vector<char>> out;
    const auto dir = fixtureDir();
    if (dir.empty())
    {
        return out;
    }
    std::vector<std::filesystem::path> paths;
    for (const auto& e : std::filesystem::directory_iterator(dir))
    {
        if (e.path().extension() == ".bin" &&
            e.path().filename().string().rfind("emitted_", 0) != 0)
        {
            paths.push_back(e.path());
        }
    }
    std::sort(paths.begin(), paths.end());
    for (const auto& p : paths)
    {
        std::ifstream f(p, std::ios::binary);
        out.emplace_back(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    }
    return out;
}

std::unique_ptr<ConcurrentCollector>
makeCollector()
{
    auto bus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                            std::make_shared<std::shared_mutex>(),
                                                            bus,
                                                            utils::DeploymentMode::MININET);
    return std::make_unique<ConcurrentCollector>(
        monitor, bus, std::make_shared<ndtClassifier::Classifier>());
}

/// Totals per flow, reduced to the numbers a lost update would change.
struct Totals
{
    uint64_t ingressBytes = 0;
    uint64_t egressBytes = 0;
    uint64_t ingressPackets = 0;
    uint64_t egressPackets = 0;
};

std::map<std::string, Totals>
summarise(sflow::FlowLinkUsageCollector& collector)
{
    std::map<std::string, Totals> out;
    for (const auto& [key, info] : collector.getFlowInfoTable())
    {
        // Keyed by text so the comparison does not depend on FlowKey's ordering or hashing.
        const std::string id = utils::ipToString(key.srcIP) + ">" + utils::ipToString(key.dstIP) +
                               ":" + std::to_string(key.srcPort) + ">" +
                               std::to_string(key.dstPort) + "/" + std::to_string(key.protocol);
        Totals t;
        for (const auto& [agent, stats] : info.agentFlowStats)
        {
            (void)agent;
            t.ingressBytes += stats.ingressByteCountCurrent;
            t.egressBytes += stats.egressByteCountCurrent;
            t.ingressPackets += stats.ingresspacketCountCurrent;
            t.egressPackets += stats.egresspacketCountCurrent;
        }
        out[id] = t;
    }
    return out;
}

} // namespace

class FlowTableConcurrencyFixture : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off; // the parser's warnings would drown the run
        Logger::init(cfg);
    }
};

TEST_F(FlowTableConcurrencyFixture, TheAccumulatedTotalsDoNotDependOnHowManyThreadsDeliveredThem)
{
    auto captures = loadRealCaptures();
    ASSERT_FALSE(captures.empty()) << "no sflow_*.bin fixtures found; run from the repo root";

    // --- ground truth: one thread, every datagram kThreads * kRepeats times ------------------
    auto sequential = makeCollector();
    for (int i = 0; i < kThreads * kRepeats; ++i)
    {
        for (auto& c : captures)
        {
            auto copy = c; // handlePacket takes char* and may write through it
            sequential->handlePacket(copy.data(), copy.size());
        }
    }
    const auto expected = summarise(*sequential);
    ASSERT_FALSE(expected.empty()) << "the fixtures produced no flows at all";

    // --- the same multiset, delivered by kThreads threads -------------------------------------
    auto concurrent = makeCollector();
    std::vector<std::thread> workers;
    workers.reserve(kThreads);
    for (int t = 0; t < kThreads; ++t)
    {
        workers.emplace_back([&captures, &concurrent] {
            for (int i = 0; i < kRepeats; ++i)
            {
                for (auto& c : captures)
                {
                    auto copy = c;
                    concurrent->handlePacket(copy.data(), copy.size());
                }
            }
        });
    }
    for (auto& w : workers)
    {
        w.join();
    }
    const auto actual = summarise(*concurrent);

    // --- the invariant -------------------------------------------------------------------------
    EXPECT_EQ(actual.size(), expected.size())
        << "the concurrent run ended up with a different number of flows";

    for (const auto& [id, want] : expected)
    {
        const auto found = actual.find(id);
        ASSERT_NE(found, actual.end()) << "flow " << id << " is missing after the concurrent run";
        const Totals& got = found->second;

        EXPECT_EQ(got.ingressBytes, want.ingressBytes)
            << "flow " << id << " lost ingress bytes: " << want.ingressBytes - got.ingressBytes
            << " of " << want.ingressBytes;
        EXPECT_EQ(got.egressBytes, want.egressBytes) << "flow " << id << " lost egress bytes";
        EXPECT_EQ(got.ingressPackets, want.ingressPackets)
            << "flow " << id << " lost ingress packets";
        EXPECT_EQ(got.egressPackets, want.egressPackets) << "flow " << id << " lost egress packets";
    }
}

TEST_F(FlowTableConcurrencyFixture, ConcurrentDeliveryOfTheSameFlowNeitherCrashesNorLosesPackets)
{
    // The narrower half: every thread sends the *same* datagram, so they contend on one key and
    // the create race is as likely as it gets. Packet counts are exact arithmetic, so this needs no
    // reference run -- N deliveries of one datagram must be counted N times.
    auto captures = loadRealCaptures();
    ASSERT_FALSE(captures.empty());

    auto one = makeCollector();
    {
        auto probe = captures.front();
        one->handlePacket(probe.data(), probe.size());
    }
    const auto afterOne = summarise(*one);
    ASSERT_FALSE(afterOne.empty()) << "the first fixture produced no flow";

    auto many = makeCollector();
    std::vector<std::thread> workers;
    for (int t = 0; t < kThreads; ++t)
    {
        workers.emplace_back([&captures, &many] {
            for (int i = 0; i < kRepeats; ++i)
            {
                auto copy = captures.front();
                many->handlePacket(copy.data(), copy.size());
            }
        });
    }
    for (auto& w : workers)
    {
        w.join();
    }
    const auto actual = summarise(*many);

    const uint64_t deliveries = static_cast<uint64_t>(kThreads) * kRepeats;
    for (const auto& [id, single] : afterOne)
    {
        const auto found = actual.find(id);
        ASSERT_NE(found, actual.end()) << "flow " << id << " vanished";
        EXPECT_EQ(found->second.ingressPackets, single.ingressPackets * deliveries)
            << "flow " << id << ": ingress packets are not " << deliveries << "x the single-delivery"
            << " count -- updates were lost";
        EXPECT_EQ(found->second.egressPackets, single.egressPackets * deliveries)
            << "flow " << id << ": egress packets are not " << deliveries << "x";
        EXPECT_EQ(found->second.ingressBytes, single.ingressBytes * deliveries)
            << "flow " << id << ": ingress bytes are not " << deliveries << "x";
    }
}
