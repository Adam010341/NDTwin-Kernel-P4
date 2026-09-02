/**
 * Tests for flow liveness: the field the detected-flow record never had, and the filter that
 * keeps ended flows out of the endpoint that calls itself "active".
 *
 * [Co-developed with claude code -- Adam]
 *
 * KNOWN-ISSUES B-x. A flow stays in the table for FLOW_IDLE_TIMEOUT -- 15000 ms -- after its last
 * sample, and getFlowInfoJson walked the whole table with no predicate whatsoever, so
 * /ndt/get_detected_flow_data listed flows that had already ended. Measured on 2026-08-27 at one
 * churn working point of 1.6 new flows per second: mean 4.7 flows actually sending against
 * mean 63.0 listed, a factor of 13.3, and the ratio never fell below 1 in any of the samples.
 * ~92% of the list was corpses. The 92% is a reading at that working point, not a constant; the
 * model is `1 + 15 * new_flow_rate / mean_concurrency`, which approaches 1 for long flows.
 *
 * 🔴 What these tests deliberately do NOT assert, because it was measured and did not hold: that
 * dead flows outrank live ones in top-k by keeping a stale non-zero sort key. That compounding was
 * proposed, and on 2026-08-28 it was refuted on both arms -- 3040 observations, dead-and-non-zero
 * came back 0 -- because the periodic rates are cleared whenever no hop reported traffic
 * (FlowLinkUsageCollector.cpp:1911). The harm that WAS measured is the population: median 4 of the
 * top 10 rows were ended flows, not because they beat anything but because fewer than ten flows
 * were alive and they filled the space underneath. No rate-field fix can reach that. Only a
 * predicate can, which is what is under test here.
 *
 * The retention itself is not the defect and nothing here changes it. A flow that starts and ends
 * between two polls would otherwise be invisible. The defect was that the record carried no field
 * saying which kind of flow you were holding: the twelve fields emitted were the 5-tuple, four
 * rates, two preformatted timestamps and the path, and the only staleness hint was
 * `latest_sampled_time`, a "%Y-%m-%d %H:%M:%S" string that is unusable for arithmetic and useless
 * without knowing FLOW_IDLE_TIMEOUT -- which doc/2026-01-02_ndt_api.md does not publish. What it
 * does publish, at :358, is that the endpoint returns "all active flows".
 *
 * MUTATION GATE: tests/shell/mutate_bx_flow_liveness.sh -- seven mutations plus a comment-only
 * negative control, each naming the cases that must go red.
 *
 * 🔴 NOT RUN. A CPU-sensitive measurement was live for the whole of the session that wrote this,
 * so nothing here has been compiled or executed. Every case below names the line of the pre-patch
 * code that makes it red; none of them has been SEEN red. UNVERIFIED until someone runs the gate.
 *
 * Two cases in this file exist only because writing that gate found holes: the constant-relation
 * case and the endpoint-default case. Every other case drives the active window through the test
 * seam, so none of them reads kFlowActiveWindowMs, and nothing in this repository serves a request
 * from a real collector, so nothing observed the API default. Both mutations survived on paper
 * before those two cases were added -- which is what a gate is for, and it worked before it ran.
 */

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <shared_mutex>
#include <string>
#include <utility>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/SFlowType.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/Classifier.hpp"
#include "ndt_core/collection/FlowLinkUsageCollector.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/http/HttpSession.hpp" // for HttpSession::kFlowDataApiDefault
#include "utils/Utils.hpp"

using sflow::FlowLiveness;
using sflow::FlowLivenessFilter;

namespace
{

/// The two bounds the production classifier is driven with, restated here so a case reads without
/// chasing constants. Kept as literals on purpose: if kFlowActiveWindowMs or FLOW_IDLE_TIMEOUT
/// moves, the boundary cases below must be re-derived by a human rather than silently following.
constexpr int64_t kWindow = 3000;
constexpr int64_t kTimeout = 15000;

FlowLiveness
at(int64_t ageMs)
{
    // now is fixed and lastSeen is moved backwards, which is the direction the real data takes.
    constexpr int64_t kNow = 1'700'000'000'000;
    return sflow::classifyFlowLiveness(kNow, kNow - ageMs, kWindow, kTimeout);
}

} // namespace

// --- the classifier's boundaries --------------------------------------------------------------
// Red before the patch for the plainest reason: sflow::classifyFlowLiveness does not exist. There
// was no function anywhere in the kernel that answered "has this flow stopped" -- that is the
// defect in one sentence.

TEST(FlowLivenessTest, AFlowSampledJustNowIsActive)
{
    EXPECT_EQ(at(0), FlowLiveness::Active);
    EXPECT_EQ(at(1), FlowLiveness::Active);
}

TEST(FlowLivenessTest, TheActiveWindowIsHalfOpenSoItsUpperBoundIsAlreadyIdle)
{
    // Stated as three cases rather than one so an off-by-one in either direction is a named
    // failure. A `<=` in place of the `<` would make 3000 active and this is what would catch it.
    EXPECT_EQ(at(kWindow - 1), FlowLiveness::Active);
    EXPECT_EQ(at(kWindow), FlowLiveness::Idle);
    EXPECT_EQ(at(kWindow + 1), FlowLiveness::Idle);
}

TEST(FlowLivenessTest, TheWholeRetentionTailIsIdleRatherThanActiveOrEnded)
{
    // This span IS the defect: ~92% of the listed flows sat somewhere in here, and before the
    // patch every one of them was indistinguishable from a flow sending right now.
    for (const int64_t ageMs : {3'000, 4'000, 7'500, 10'000, 14'000, 14'999})
    {
        EXPECT_EQ(at(ageMs), FlowLiveness::Idle) << "age " << ageMs << " ms";
    }
}

TEST(FlowLivenessTest, EndedBeginsExactlyWherePurgeIdleFlowsWouldRemoveTheRow)
{
    // purgeIdleFlows removes at `idle_time >= FLOW_IDLE_TIMEOUT` (FlowLinkUsageCollector.cpp:2247).
    // The classifier has to use the same comparison or the API and the purge would disagree about
    // what has ended -- one field, one clock, two readers.
    EXPECT_EQ(at(kTimeout - 1), FlowLiveness::Idle);
    EXPECT_EQ(at(kTimeout), FlowLiveness::Ended);
    EXPECT_EQ(at(kTimeout + 60'000), FlowLiveness::Ended);
}

TEST(FlowLivenessTest, ASampleStampedInTheFutureIsActiveBecauseThePurgeAlsoSkipsIt)
{
    // 🔴 Pinning a deliberate wart, not endorsing it. endTime comes from the system clock, so an
    // NTP step or a VM resume can put it ahead of now; purgeIdleFlows skips exactly that row
    // (`if (now <= info.endTime) continue;`, :2242) and so produces an unbounded zombie -- the
    // shape behind the 291 s record seen in the 2026-08-13 OVS overnight round, 19x past the 15 s
    // ceiling this code can otherwise reach, which is how that observation was shown to be a
    // DIFFERENT defect from this one. The classifier agrees with the purge so the new filter
    // cannot hide such a row: a zombie stays in the default view, loudly. Whoever fixes the clock
    // must change this case, and should have to.
    EXPECT_EQ(at(-1), FlowLiveness::Active);
    EXPECT_EQ(at(-500'000), FlowLiveness::Active);
}

// --- the filter -------------------------------------------------------------------------------

TEST(FlowLivenessTest, ActiveOnlyAdmitsNothingButActive)
{
    EXPECT_TRUE(passesLivenessFilter(FlowLiveness::Active, FlowLivenessFilter::ActiveOnly));
    EXPECT_FALSE(passesLivenessFilter(FlowLiveness::Idle, FlowLivenessFilter::ActiveOnly));
    EXPECT_FALSE(passesLivenessFilter(FlowLiveness::Ended, FlowLivenessFilter::ActiveOnly));
}

TEST(FlowLivenessTest, RetainedKeepsIdleAndIsThereforeNotTheDefault)
{
    // The distinction this enum exists to force. "Not ended" is NOT the fix: Ended rows barely
    // exist, because the purge sweeps them within a second. The ~92% are Idle. A filter spelled as
    // a boolean "exclude ended" would have passed review and removed almost nothing.
    EXPECT_TRUE(passesLivenessFilter(FlowLiveness::Active, FlowLivenessFilter::ActiveAndIdle));
    EXPECT_TRUE(passesLivenessFilter(FlowLiveness::Idle, FlowLivenessFilter::ActiveAndIdle));
    EXPECT_FALSE(passesLivenessFilter(FlowLiveness::Ended, FlowLivenessFilter::ActiveAndIdle));
}

TEST(FlowLivenessTest, AllAdmitsEveryClass)
{
    EXPECT_TRUE(passesLivenessFilter(FlowLiveness::Active, FlowLivenessFilter::All));
    EXPECT_TRUE(passesLivenessFilter(FlowLiveness::Idle, FlowLivenessFilter::All));
    EXPECT_TRUE(passesLivenessFilter(FlowLiveness::Ended, FlowLivenessFilter::All));
}

// --- the two constants that are decisions rather than derivations -----------------------------
// [Co-developed with claude code -- Adam]
//
// 🔴 Both of these were added because the mutation gate found them missing, not because they were
// designed in. tests/shell/mutate_bx_flow_liveness.sh applies `kFlowActiveWindowMs = 0`,
// `= 1000000000` and `API default -> All`, and without these cases the first survived in one
// direction and the other two survived outright: every collector-level case drives the window
// through the test seam, so it never reads the constant, and no case in this repository serves a
// request from a real collector, so nothing observed the API default at all.
//
// They are weak tests in the sense that they restate decisions. That is the same trade
// FlowPathRecomputeInterval.IsOneSecondNotOneMillisecond makes and for the same stated reason: the
// decision IS the change, and without the pin a silent revert leaves the suite green.

TEST(FlowLivenessTest, TheActiveWindowSitsBetweenARateLoopPeriodAndTheIdleTimeout)
{
    // Not a restatement of 3000. It is the relationship that makes three states possible at all.
    //
    // Upper bound: at or above FLOW_IDLE_TIMEOUT, `Idle` becomes unreachable -- every retained row
    // is Active until the purge deletes it -- and the whole lifecycle collapses back into the two
    // states that produced the defect. Strict, because equality already empties the middle.
    //
    // Lower bound: the window has to clear one rate-loop period, or a continuously sending flow
    // flaps between active and idle whenever the loop runs slow. The loop's own measured windowed
    // mean was 1248.7 ms at 64 flows on 2026-08-25 and grows with table size, so 2000 is the
    // floor with the least slack anyone should accept -- and 0 is far below it.
    EXPECT_LT(sflow::kFlowActiveWindowMs, static_cast<int64_t>(FLOW_IDLE_TIMEOUT))
        << "an active window at or past the idle timeout makes `idle` unreachable and returns the "
           "API to the two-state behaviour this ticket is about";
    EXPECT_GE(sflow::kFlowActiveWindowMs, 2000)
        << "an active window shorter than a measured rate-loop period makes a flow that never "
           "stopped flap between active and idle";
}

TEST(FlowLivenessTest, TheEndpointDefaultIsActiveOnlyRatherThanTheWholeTable)
{
    // The one line that decides whether the endpoint keeps contradicting its own documentation.
    // ⚠️ This pins the VALUE, not the behaviour: nothing here shows the handler reads it. A test
    // that serves the route from a real collector is the missing piece and is noted in the gate.
    EXPECT_EQ(HttpSession::kFlowDataApiDefault, FlowLivenessFilter::ActiveOnly);
}

TEST(FlowLivenessTest, EndedAtIsExactlyOneTimeoutAfterTheLastSample)
{
    // The number the API never gave a consumer. Without it, `latest_sampled_time` can only be
    // interpreted by someone who already knows FLOW_IDLE_TIMEOUT.
    EXPECT_EQ(sflow::flowEndedAtMs(1'000, kTimeout), 16'000);
    EXPECT_EQ(sflow::flowEndedAtMs(0, kTimeout), kTimeout);
}

// --- the query parameter ----------------------------------------------------------------------

TEST(FlowLivenessTest, TheThreeAcceptedValuesParseToTheirFilters)
{
    for (const auto& [text, want] : std::vector<std::pair<std::string, FlowLivenessFilter>>{
             {"active", FlowLivenessFilter::ActiveOnly},
             {"retained", FlowLivenessFilter::ActiveAndIdle},
             {"all", FlowLivenessFilter::All}})
    {
        FlowLivenessFilter got = FlowLivenessFilter::ActiveAndIdle;
        ASSERT_TRUE(sflow::parseLivenessFilter(text, got)) << text << " was rejected";
        EXPECT_EQ(got, want) << text;
    }
}

TEST(FlowLivenessTest, AnAbsentValueLeavesTheCallersDefaultAlone)
{
    // utils::queryParam returns "" both for an absent key and for `?liveness=`, and the handlers
    // treat them alike, so "" must mean "not supplied" rather than "invalid".
    FlowLivenessFilter got = FlowLivenessFilter::ActiveOnly;
    EXPECT_TRUE(sflow::parseLivenessFilter("", got));
    EXPECT_EQ(got, FlowLivenessFilter::ActiveOnly);
}

TEST(FlowLivenessTest, AnUnrecognisedValueIsRejectedRatherThanFallingBackToTheDefault)
{
    // The failure this refuses is the same shape as the bug being fixed: a caller who typed
    // `?liveness=alive` and got a silently filtered list would believe it was unfiltered.
    for (const char* bad : {"alive", "ACTIVE", "dead", "true", "1", "activex", " active"})
    {
        FlowLivenessFilter got = FlowLivenessFilter::All;
        EXPECT_FALSE(sflow::parseLivenessFilter(bad, got)) << "accepted " << bad;
        EXPECT_EQ(got, FlowLivenessFilter::All) << "rejected " << bad << " but wrote to out";
    }
}

// --- the route --------------------------------------------------------------------------------
// Red before the patch because utils::pathIs does not exist; the behaviour it replaces is asserted
// against HttpSession in test_HttpSessionRouting.cpp.

TEST(FlowLivenessTest, PathIsAcceptsTheBarePathAndTheSamePathWithAQuery)
{
    EXPECT_TRUE(utils::pathIs("/ndt/get_detected_flow_data", "/ndt/get_detected_flow_data"));
    EXPECT_TRUE(
        utils::pathIs("/ndt/get_detected_flow_data?liveness=all", "/ndt/get_detected_flow_data"));
    EXPECT_TRUE(utils::pathIs("/ndt/get_detected_flow_data?", "/ndt/get_detected_flow_data"));
}

TEST(FlowLivenessTest, PathIsRejectsASuffixThatIsNotAQuery)
{
    // The half the old `starts_with` on the top-k route got wrong: a mistyped endpoint answered as
    // if it were the real one.
    EXPECT_FALSE(utils::pathIs("/ndt/get_detected_flow_dataZZZ", "/ndt/get_detected_flow_data"));
    EXPECT_FALSE(utils::pathIs("/ndt/get_detected_flow_data/x", "/ndt/get_detected_flow_data"));
    EXPECT_FALSE(utils::pathIs("/ndt/get_detected_flow", "/ndt/get_detected_flow_data"));
    EXPECT_FALSE(
        utils::pathIs("/ndt/get_detected_top_k_flow_data", "/ndt/get_detected_flow_data"));
}

// --- against a real flow table ------------------------------------------------------------------

namespace
{

/// Same shape as TopKCollector in test_TopKFlowInfoLocking.cpp and ConcurrentCollector in
/// test_FlowTableConcurrency.cpp: handlePacket is protected and is the only way to put real flows
/// in the table from a test.
class LivenessCollector : public sflow::FlowLinkUsageCollector
{
  public:
    LivenessCollector(std::shared_ptr<TopologyAndFlowMonitor> monitor,
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

    /**
     * Ages every retained row without sleeping and without writing FlowInfo::endTime.
     *
     * A window of 0 makes `now - lastSeen < 0` false for every row whose sample is not in the
     * future, so every one of them classifies Idle -- which is exactly the state the ~92% sit in.
     * The alternative was a 3 s sleep, in a suite that currently contains no multi-second sleep,
     * for an assertion that would then be timing-dependent forever.
     */
    void collapseActiveWindow() { m_flowActiveWindowMs = 0; }
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

/// Real captured datagrams, same selection rule as test_TopKFlowInfoLocking.cpp: the `emitted_*`
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

} // namespace

class FlowLivenessTableTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        auto bus = std::make_shared<EventBus>();
        auto monitor = std::make_shared<TopologyAndFlowMonitor>(std::make_shared<Graph>(),
                                                               std::make_shared<std::shared_mutex>(),
                                                               bus,
                                                               utils::DeploymentMode::MININET);
        m_collector = std::make_unique<LivenessCollector>(
            monitor, bus, std::make_shared<ndtClassifier::Classifier>());

        for (auto& capture : loadRealCaptures())
        {
            if (!capture.empty())
            {
                m_collector->handlePacket(capture.data(), capture.size());
            }
        }

        // Not a skip. Every case below is about which rows survive a predicate, and against an
        // empty table they would all pass without touching the code. A missing fixture directory
        // is a broken checkout and it must be loud. Same rule as test_TopKFlowInfoLocking.cpp.
        ASSERT_FALSE(m_collector->getFlowInfoJson(FlowLivenessFilter::All).empty())
            << "the sFlow captures under tests/fixtures produced no flows; every case in this "
               "file would be vacuously true against an empty table";
    }

    std::unique_ptr<LivenessCollector> m_collector;
};

TEST_F(FlowLivenessTableTest, EveryRowCarriesTheThreeFieldsThatSayWhetherItIsStillSending)
{
    // 🔴 The core red. Before the patch the emitter at FlowLinkUsageCollector.cpp:2298-2323 built
    // exactly twelve keys -- src_ip, dst_ip, src_port, dst_port, protocol_id, four rates,
    // first_sampled_time, latest_sampled_time, path -- and not one of them said whether the flow
    // had stopped. Every row fails the first ASSERT below.
    for (const auto& row : m_collector->getFlowInfoJson(FlowLivenessFilter::All))
    {
        ASSERT_TRUE(row.contains("liveness")) << row.dump();
        ASSERT_TRUE(row.contains("last_seen_ms")) << row.dump();
        ASSERT_TRUE(row.contains("ended_at_ms")) << row.dump();

        // Epoch milliseconds, not a display string: the whole point is that a consumer can
        // subtract them. `latest_sampled_time` stays, formatted, for the humans.
        EXPECT_TRUE(row["last_seen_ms"].is_number_integer()) << row.dump();
        EXPECT_EQ(row["ended_at_ms"].get<int64_t>() - row["last_seen_ms"].get<int64_t>(), kTimeout)
            << "ended_at must be derivable from last_seen and the timeout, or the two can drift";
        EXPECT_TRUE(row.contains("latest_sampled_time")) << "the human-readable stamp was dropped";
    }
}

TEST_F(FlowLivenessTableTest, RowsJustReplayedAreActiveAndSurviveTheDefaultFilter)
{
    // The over-correction guard, and it is the half that protects the second consumer class. A
    // filter that dropped live flows to make the demo tidy would break the rate and routing paths
    // in the direction that actually matters -- missing traffic that is really there. handlePacket
    // stamps endTime with now, so every fixture row is genuinely active at this instant.
    const auto all = m_collector->getFlowInfoJson(FlowLivenessFilter::All);
    const auto active = m_collector->getFlowInfoJson(FlowLivenessFilter::ActiveOnly);

    EXPECT_EQ(active.size(), all.size()) << "a freshly fed table lost rows to the active filter";
    for (const auto& row : active)
    {
        EXPECT_EQ(row["liveness"].get<std::string>(), "active") << row.dump();
    }
}

TEST_F(FlowLivenessTableTest, AStoppedFlowIsGoneFromTheDefaultViewAndStillThereUnderAll)
{
    // The ticket, end to end. Before the patch getFlowInfoJson had no predicate at all
    // (FlowLinkUsageCollector.cpp:2296, `for (const auto& [flowKey, flowInfo] : m_flowInfoTable)`
    // straight into the emit), so both sides of this comparison were the same array and the first
    // EXPECT_TRUE below could never hold.
    const auto before = m_collector->getFlowInfoJson(FlowLivenessFilter::All);
    ASSERT_FALSE(before.empty());

    m_collector->collapseActiveWindow();

    const auto active = m_collector->getFlowInfoJson(FlowLivenessFilter::ActiveOnly);
    const auto all = m_collector->getFlowInfoJson(FlowLivenessFilter::All);

    EXPECT_TRUE(active.empty()) << "a flow with no recent sample is still listed as active: "
                                << active.dump();
    EXPECT_EQ(all.size(), before.size()) << "the rows were removed from the table, not filtered "
                                            "from the view -- retention must not change";
    for (const auto& row : all)
    {
        EXPECT_EQ(row["liveness"].get<std::string>(), "idle")
            << "a retained row inside the timeout must read idle, not ended: " << row.dump();
    }

    // `retained` is the compatibility escape hatch: it must hand back everything the table holds
    // while the timeout has not expired, which is precisely the old behaviour.
    EXPECT_EQ(m_collector->getFlowInfoJson(FlowLivenessFilter::ActiveAndIdle).size(),
              before.size());
}

TEST_F(FlowLivenessTableTest, TopKFiltersBeforeItTruncatesRatherThanAfter)
{
    // Filtering the k rows that come out instead of the rows going in would return fewer than k
    // while live flows sat below the cut. With every row idle, top-k under the default must be
    // empty rather than a short list.
    m_collector->collapseActiveWindow();

    EXPECT_TRUE(m_collector->getTopKFlowInfoJson(50, FlowLivenessFilter::ActiveOnly).empty())
        << "top-k served rows it had just been told to exclude";
    EXPECT_FALSE(m_collector->getTopKFlowInfoJson(50, FlowLivenessFilter::All).empty())
        << "the filter leaked into the unfiltered mode";
}

TEST_F(FlowLivenessTableTest, TheCountsAddUpToTheWholeTableAndMoveTogether)
{
    // The IntentTranslator GET_ACTIVE_FLOW_COUNT path reported getFlowInfoTable().size() under the
    // key `active_flow_count` (IntentTranslator.cpp:556-559): at the measured working point that
    // answered 63 when 4.7 flows were sending. Counted in one pass so the two numbers it now
    // publishes cannot come from two different instants.
    const auto fresh = m_collector->countFlowsByLiveness();
    const std::size_t tableSize = m_collector->getFlowInfoTable().size();

    EXPECT_EQ(fresh.retained(), tableSize);
    EXPECT_EQ(fresh.active, tableSize) << "a freshly fed table is entirely active";
    EXPECT_EQ(fresh.idle, 0u);

    m_collector->collapseActiveWindow();

    const auto stale = m_collector->countFlowsByLiveness();
    EXPECT_EQ(stale.retained(), tableSize) << "retention changed; only the classification should";
    EXPECT_EQ(stale.active, 0u) << "active_flow_count is still counting flows that stopped";
    EXPECT_EQ(stale.idle, tableSize);
}
