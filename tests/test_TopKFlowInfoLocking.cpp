/**
 * Tests for getTopKFlowInfoJson, the /ndt/get_top_k_flow_info handler's data source.
 *
 * [Co-developed with claude code -- Adam]
 *
 * ## What was wrong (KNOWN-ISSUES §E-2, fixed 2026-09-01)
 *
 * The function opened with `shared_lock lock(m_flowInfoTableMutex);` one line above a call to
 * getFlowInfoJson(), which opens with the same acquisition. Recursively acquiring a
 * std::shared_mutex is undefined behaviour -- [thread.sharedmutex.requirements] forbids a thread
 * from calling lock_shared while it already owns the mutex -- and five writers take unique_lock
 * on that same mutex.
 *
 * It never bit, and the reason is a property of this machine's C++ library rather than of the
 * code: glibc's pthread_rwlock defaults to PTHREAD_RWLOCK_PREFER_READER_NP, so a reader does not
 * yield to a waiting writer and the second rdlock on the same thread succeeds. Switching the
 * rwlock kind, or building libstdc++ without _GLIBCXX_USE_PTHREAD_RWLOCK_T, turns it into a
 * self-deadlock with a writer wedged in the middle -- and because the northbound API serialises,
 * one stuck handler thread holds the entire server, not one endpoint.
 *
 * The fix is a deletion: nothing out there needed protecting. getFlowInfoJson() returns a freshly
 * built array and every line after it works on that local copy. Deleting the outer lock also
 * moved the std::sort out of the critical section, which is the second half of the KNOWN-ISSUES
 * note -- the section used to grow O(n log n) in the size of the flow table.
 *
 * ## 🔴 What this file does NOT test, said out loud
 *
 * **The deadlock is not reproducible here**, on this libstdc++, by construction -- that is the
 * whole reason the defect was latent rather than live. A "does it hang?" case would pass against
 * the broken code and the fixed code alike, which is not a test, it is a green tick. The
 * structural property -- that this function does not take m_flowInfoTableMutex -- is pinned
 * instead by tests/shell/test_topk_no_recursive_shared_lock.sh, which reads the shipped source
 * and can be made to go red by putting the line back.
 *
 * **The ordering is not exercised either.** The sort key is
 * `estimated_packet_rate_in_the_proceeding_1sec_timeslot`, written only by the 1 Hz rate loop.
 * These tests drive handlePacket directly without standing that thread up, so every row's key is
 * 0 and any "the rows come back in descending order" assertion would hold for every possible
 * permutation. Recorded rather than written: an assertion that cannot fail is worse than a
 * missing one, because it reads like coverage.
 *
 * What is left is what the fix could actually have broken -- the bounds, the row contents, and
 * the agreement between the field name the sort reads and the field name getFlowInfoJson emits.
 * Before this file, getTopKFlowInfoJson had no test of any kind.
 *
 * ## ⚠️ The field-name case is louder than it looks, and the mutation run is how that was learnt
 *
 * The comparator takes `const nlohmann::json& a` and writes `a["..."]`, so it calls nlohmann's
 * **const** operator[]. That overload does not insert and does not throw: it is
 * `JSON_ASSERT(it != m_data.m_value.object->end())`, i.e. **abort()** in a build with assertions,
 * and with `-DNDEBUG` (this repo's Release flags, CMakeLists.txt:76) the assert is compiled out
 * and it dereferences a past-the-end iterator instead. So a drift between the emitter's field
 * name and the comparator's does not produce a 500 on one endpoint -- it takes the process down,
 * or is undefined.
 *
 * 🔑 That is why TheSortKeyIsAFieldTheRowsActuallyCarry checks the field BEFORE calling
 * getTopKFlowInfoJson. The first version of it asserted afterwards, and the mutation that renames
 * the field was reported as SURVIVED: the binary aborted inside an earlier case, so no gtest
 * failure line was ever printed for the case named after the mutation. A test that dies before
 * its assertion runs is indistinguishable, in the log, from one that passed.
 */

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <set>
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

/// Same shape as ConcurrentCollector in test_FlowTableConcurrency.cpp: handlePacket is protected,
/// and it is the only way to put real flows in the table from a test.
class TopKCollector : public sflow::FlowLinkUsageCollector
{
  public:
    TopKCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
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

/// Real captured datagrams, same selection rule as test_FlowTableConcurrency.cpp: the `emitted_*`
/// captures are the emitter's own output and include deliberately truncated shapes.
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

std::unique_ptr<TopKCollector> makeCollector()
{
    auto bus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                           std::make_shared<std::shared_mutex>(),
                                                           bus,
                                                           utils::DeploymentMode::MININET);
    return std::make_unique<TopKCollector>(
        monitor, bus, std::make_shared<ndtClassifier::Classifier>());
}

/// A collector with a non-empty flow table, or nullptr if the fixtures are missing.
std::unique_ptr<TopKCollector> populatedCollector()
{
    auto collector = makeCollector();
    for (auto& capture : loadRealCaptures())
    {
        if (!capture.empty())
        {
            collector->handlePacket(capture.data(), capture.size());
        }
    }
    return collector;
}

std::multiset<std::string> rowsOf(const nlohmann::json& arr)
{
    std::multiset<std::string> out;
    for (const auto& row : arr)
    {
        out.insert(row.dump());
    }
    return out;
}

} // namespace

class TopKFlowInfoTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_collector = populatedCollector();
        ASSERT_NE(m_collector, nullptr);
        m_full = m_collector->getFlowInfoJson();
        // Not a skip. Every case below is about how a k relates to the table size, and against an
        // empty table they would all pass without touching the code -- the same shape as the
        // ordering assertion this file refuses to write. A missing fixture directory is a broken
        // checkout, and it must be loud.
        ASSERT_FALSE(m_full.empty())
            << "the sFlow captures under tests/fixtures produced no flows; every case in this "
               "file would be vacuously true against an empty table";
    }

    std::unique_ptr<TopKCollector> m_collector;
    nlohmann::json m_full;
};

/**
 * Declared FIRST on purpose, and its precondition is checked before the call it protects.
 *
 * gtest runs a suite in declaration order, and the failure this case exists for -- the
 * comparator's field name drifting from the emitter's -- aborts the process rather than throwing
 * (see the header). If a case that sorts ran first, the binary would die there and this one would
 * never report; if the assertion came after the call, it would die inside this case before
 * asserting. Either way the log shows no failure line for the case named after the defect, and
 * the mutation run reports SURVIVED against code that is comprehensively broken.
 */
TEST_F(TopKFlowInfoTest, TheSortKeyIsAFieldTheRowsActuallyCarry)
{
    for (const auto& row : m_full)
    {
        ASSERT_TRUE(row.contains("estimated_packet_rate_in_the_proceeding_1sec_timeslot"))
            << "the field getTopKFlowInfoJson sorts on is missing from the rows it sorts, and "
               "the const operator[] that reads it aborts rather than throwing: "
            << row.dump();
    }

    // Only now, with the precondition established, is it safe to run the sort.
    EXPECT_NO_THROW({ (void)m_collector->getTopKFlowInfoJson(5); });
}

TEST_F(TopKFlowInfoTest, TopKReturnsKRowsAndEveryOneOfThemIsARowOfTheTable)
{
    const int k = 2;
    ASSERT_GT(static_cast<int>(m_full.size()), k) << "the fixture must hold more flows than k, or "
                                                     "the truncation is not being exercised";

    const auto topK = m_collector->getTopKFlowInfoJson(k);

    EXPECT_EQ(static_cast<int>(topK.size()), k);
    const auto full = rowsOf(m_full);
    for (const auto& row : topK)
    {
        EXPECT_NE(full.find(row.dump()), full.end())
            << "top-k returned a row that is not in the flow table: " << row.dump();
    }
}

TEST_F(TopKFlowInfoTest, AskingForMoreRowsThanExistReturnsTheTableRatherThanReadingPastTheEnd)
{
    // `std::min(k, size)` is the whole guard, and indexing a json array past its end is not a
    // caught error -- it is undefined behaviour on the underlying vector.
    const auto topK = m_collector->getTopKFlowInfoJson(static_cast<int>(m_full.size()) + 50);

    EXPECT_EQ(topK.size(), m_full.size());
    EXPECT_EQ(rowsOf(topK), rowsOf(m_full)) << "the over-long request changed the rows";
}

TEST_F(TopKFlowInfoTest, AKOfZeroOrLessIsAnEmptyArrayRatherThanTheWholeTable)
{
    // k arrives from a query parameter. The failure direction that matters is the one where a
    // caller asking for nothing is handed every flow the kernel knows about.
    EXPECT_TRUE(m_collector->getTopKFlowInfoJson(0).empty());
    EXPECT_TRUE(m_collector->getTopKFlowInfoJson(-1).empty());
    EXPECT_TRUE(m_collector->getTopKFlowInfoJson(-1000).empty());
}

TEST_F(TopKFlowInfoTest, TopKKeepsAnsweringWhileAWriterIsFeedingTheTable)
{
    // What this DOES cover: the ordinary races between this reader and handlePacket's writers --
    // a rehash under a reader is a segfault, not a stale value.
    //
    // 🔴 What it does NOT cover, so the green is not read as more than it is: the recursive
    // shared_lock this file exists for. Under PREFER_READER_NP the recursion succeeds, so this
    // case passes against the broken code too. The structural guard is the one with the
    // discriminating power -- tests/shell/test_topk_no_recursive_shared_lock.sh.
    constexpr int kReaders = 6;
    constexpr int kRounds = 60;
    auto captures = loadRealCaptures();
    ASSERT_FALSE(captures.empty());

    std::atomic<bool> stop{false};
    std::atomic<int> completed{0};

    std::thread writer([&] {
        while (!stop.load(std::memory_order_relaxed))
        {
            for (auto& capture : captures)
            {
                if (!capture.empty())
                {
                    m_collector->handlePacket(capture.data(), capture.size());
                }
            }
        }
    });

    std::vector<std::thread> readers;
    readers.reserve(kReaders);
    for (int i = 0; i < kReaders; ++i)
    {
        readers.emplace_back([&] {
            for (int r = 0; r < kRounds; ++r)
            {
                const auto topK = m_collector->getTopKFlowInfoJson(3);
                if (topK.size() > 3)
                {
                    return; // leaves `completed` short, which fails below
                }
            }
            completed.fetch_add(1, std::memory_order_relaxed);
        });
    }
    for (auto& t : readers)
    {
        t.join();
    }
    stop.store(true, std::memory_order_relaxed);
    writer.join();

    EXPECT_EQ(completed.load(), kReaders)
        << "a reader returned more rows than it asked for while the table was being written";
}
