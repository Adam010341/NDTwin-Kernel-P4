/**
 * Tests for KNOWN-ISSUES F-6: a switch whose flow-table read failed must not vanish.
 *
 * [Co-developed with claude code -- Adam]
 *
 * `fetchOpenFlowTablesInternal` builds a fresh array every poll and `continue`s past any switch it
 * could not read; `openflowTablesUpdateWorker` then assigned that array over the whole cache. So
 * the four skip paths deleted the switch -- while saying, in four places, that they were doing the
 * opposite:
 *
 *     DeviceConfigurationAndPowerManager.cpp:1079  "tables are left as they were"
 *     :1098  "Keeping the previous table is the same conservative choice the timeout path makes"
 *     :1122  "Skipping leaves the previous table in place, the conservative direction"
 *     :1149  "not as a switch with no rules. Keeping the previous table."
 *
 * plus `FlowStatsVerdict::SuspectTimedOut`'s own "Keep the previous table" in the header, the note
 * on buildFlowStatsCommand, and -- the reason this survived -- two test files whose prose already
 * described the system as keeping it (`test_FlowStatsTimeout.cpp:206`,
 * `test_RequestDeadlines.cpp:126`). Nine statements of a policy and no implementation of it, so
 * everything that looked like coverage was coverage of the verdict, never of what was done with it.
 *
 * ### Why deleting is the worse of the two dishonesties
 *
 * Every consumer walks the array matching on `dpid` -- `HttpSession.cpp:622` serves it verbatim,
 * `IntentTranslator.cpp:1069` and `LLMAgent.cpp:275` read it whole, and the three checkers
 * (`tools/contract_test/spec.py:295`, `doc/audit/2026-08-28_chaos-harness/harness/invariants.py:147`,
 * `doc/audit/2026-08-31_live-acceptance-batch/probe.py:52`) all iterate and skip non-matching
 * dpids. For every one of them, a *missing* switch and a switch reporting *zero rules* are the
 * same answer -- which is precisely the 2026-08-07 failure `classifyFlowStatsReply` was written to
 * prevent. The verdict refused to apply the empty table; the wholesale swap applied it anyway, by
 * omission. And `inv_tables_non_empty` iterates only the entries that are present, so nothing in
 * the tree could see it happen.
 *
 * So the property under test is not "the table is right". It is that **an answer the kernel is not
 * sure of says so**: the entry is present, and it carries `stale_since`, `stale_polls` and
 * `last_error`. Both directions are asserted, because a rule that only ever keeps things is as
 * wrong as one that never does -- `ASwitchThatWasNeverAttemptedIsNotCarriedForward` is the guard
 * against turning F-6 into F-4/F-16, where a dead switch's rules live on forever.
 *
 * The wiring half -- that openflowTablesUpdateWorker actually calls this, against the real cache,
 * under the real lock -- is not testable here without a control plane. See the findings file.
 */

#include <cstdint>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "ndt_core/power_management/StaleTableCarryForward.hpp"
#include "ndt_core/routing_management/PendingEntryFilter.hpp"

using nlohmann::json;

namespace
{

/// Wall-clock stand-in. Passed in rather than read inside the rule, so "since when" is assertable.
constexpr std::int64_t kT0 = 1756800000; // 2026-09-02T00:00:00Z, near enough
constexpr std::int64_t kT1 = kT0 + 10;   // one poll interval later
constexpr std::int64_t kT2 = kT0 + 20;

/// One switch entry in the shape `result.push_back({{"dpid", dpid}, {"flows", flows}})` produces.
json
switchWithRules(std::uint64_t dpid, const char* dst)
{
    return json{{"dpid", dpid},
                {"flows",
                 {{"0",
                   json::array({json{{"priority", 100},
                                     {"match", {{"dl_type", 2048}, {"nw_dst", dst}}},
                                     {"actions", json::array({"OUTPUT:2"})},
                                     {"byte_count", 4096},
                                     {"packet_count", 32}}})}}}};
}

/// The entry for `dpid`, or nullptr. Written the way every real consumer walks this array.
const json*
find(const json& tables, std::uint64_t dpid)
{
    for (const auto& sw : tables)
    {
        if (sw.is_object() && sw.value("dpid", std::uint64_t{0}) == dpid)
        {
            return &sw;
        }
    }
    return nullptr;
}

} // namespace

// --- the defect itself ---------------------------------------------------------------------

TEST(StaleTableCarryForward, AnUnreadSwitchKeepsItsPreviousTable)
{
    const json previous = json::array({switchWithRules(1, "10.0.0.1"), switchWithRules(3, "10.0.0.3")});
    // This poll read switch 1 and could not read switch 3.
    json fresh = json::array({switchWithRules(1, "10.0.0.1")});

    const std::size_t carried =
        carryForwardUnreadTables(fresh, previous, {{3, kUnreadSuspectTimeout}}, kT0);

    EXPECT_EQ(carried, 1u);
    // CATCHES THE DEFECT: before the fix `fresh` was assigned over the cache exactly as it stands
    // on the line above, so this is nullptr and dpid 3 has left the twin's flow-table listing
    // without a trace.
    const json* sw3 = find(fresh, 3);
    ASSERT_NE(sw3, nullptr) << "switch 3 vanished from the listing because its read failed";
    EXPECT_EQ(sw3->at("flows").at("0").size(), 1u) << "its last known rule should still be there";
}

TEST(StaleTableCarryForward, TheCarriedTableSaysItIsStaleAndWhy)
{
    const json previous = json::array({switchWithRules(3, "10.0.0.3")});
    json fresh = json::array();

    carryForwardUnreadTables(fresh, previous, {{3, kUnreadReportedFailure}}, kT0);

    const json* sw3 = find(fresh, 3);
    ASSERT_NE(sw3, nullptr);
    // Without all three a consumer cannot tell this apart from a fresh read, which is the other
    // half of the dishonesty: a stale copy served silently as current.
    EXPECT_EQ(sw3->value(kStaleSinceField, std::int64_t{0}), kT0);
    EXPECT_EQ(sw3->value(kStalePollsField, std::int64_t{0}), 1);
    EXPECT_EQ(sw3->value(kLastErrorField, std::string{}), std::string(kUnreadReportedFailure));
}

/// Failure injection, one case per skip path in fetchOpenFlowTablesInternal. If a fifth skip path
/// is ever added without a reason token, its dpid still has to arrive here with *some* token --
/// this is what stops "the read failed" from silently becoming "the read succeeded and was empty".
TEST(StaleTableCarryForward, EveryReadFailureModeCarriesTheTableAndNamesItself)
{
    const std::vector<std::string> reasons = {kUnreadNoResponse,
                                              kUnreadUnparseable,
                                              kUnreadReportedFailure,
                                              kUnreadSuspectTimeout};

    for (const auto& reason : reasons)
    {
        const json previous = json::array({switchWithRules(7, "10.0.0.7")});
        json fresh = json::array();

        EXPECT_EQ(carryForwardUnreadTables(fresh, previous, {{7, reason}}, kT0), 1u) << reason;

        const json* sw = find(fresh, 7);
        ASSERT_NE(sw, nullptr) << "switch 7 vanished after: " << reason;
        EXPECT_EQ(sw->value(kLastErrorField, std::string{}), reason);
        EXPECT_FALSE(sw->contains(kNeverReadField)) << "it had been read before: " << reason;
    }
}

// --- staleness has to accumulate honestly --------------------------------------------------

TEST(StaleTableCarryForward, StaleSinceNamesTheFirstFailedPollNotTheLatest)
{
    json cache = json::array({switchWithRules(3, "10.0.0.3")});

    json poll1 = json::array();
    carryForwardUnreadTables(poll1, cache, {{3, kUnreadSuspectTimeout}}, kT0);
    cache = poll1;

    json poll2 = json::array();
    carryForwardUnreadTables(poll2, cache, {{3, kUnreadSuspectTimeout}}, kT1);
    cache = poll2;

    json poll3 = json::array();
    carryForwardUnreadTables(poll3, cache, {{3, kUnreadSuspectTimeout}}, kT2);

    const json* sw3 = find(poll3, 3);
    ASSERT_NE(sw3, nullptr);
    // Resetting this every poll would make a switch unreadable for an hour look one poll stale --
    // "since when" is the whole value of the field, and a consumer thresholding on age would never
    // fire.
    EXPECT_EQ(sw3->value(kStaleSinceField, std::int64_t{0}), kT0);
    EXPECT_EQ(sw3->value(kStalePollsField, std::int64_t{0}), 3);
    EXPECT_EQ(sw3->at("flows").at("0").size(), 1u) << "the table survives repeated carries";
}

TEST(StaleTableCarryForward, LastErrorReportsTheLatestReasonNotTheFirst)
{
    json cache = json::array({switchWithRules(3, "10.0.0.3")});

    json poll1 = json::array();
    carryForwardUnreadTables(poll1, cache, {{3, kUnreadSuspectTimeout}}, kT0);

    json poll2 = json::array();
    carryForwardUnreadTables(poll2, poll1, {{3, kUnreadNoResponse}}, kT1);

    const json* sw3 = find(poll2, 3);
    ASSERT_NE(sw3, nullptr);
    // A switch that went from timing out to not answering at all has changed state, and the newer
    // reason is the one that describes the fabric now. stale_since still points at the first.
    EXPECT_EQ(sw3->value(kLastErrorField, std::string{}), std::string(kUnreadNoResponse));
    EXPECT_EQ(sw3->value(kStaleSinceField, std::int64_t{0}), kT0);
}

// --- the other direction: things that must NOT be kept --------------------------------------

TEST(StaleTableCarryForward, ASwitchThatWasNeverAttemptedIsNotCarriedForward)
{
    // A switch that is down is skipped before any request is made
    // (DeviceConfigurationAndPowerManager.cpp:1027), so it never reaches the unread list.
    const json previous = json::array({switchWithRules(3, "10.0.0.3")});
    json fresh = json::array();

    const std::size_t carried = carryForwardUnreadTables(fresh, previous, {}, kT0);

    // The guard against fixing F-6 into F-4/F-16: keeping a dead switch's rules alive for as long
    // as it stays dead is a worse answer than dropping them, because it is optimistic rather than
    // merely stale, and nothing ever retracts it.
    EXPECT_EQ(carried, 0u);
    EXPECT_EQ(find(fresh, 3), nullptr) << "a switch nobody asked about must not be resurrected";
    EXPECT_TRUE(fresh.empty());
}

TEST(StaleTableCarryForward, ASwitchReadSuccessfullyCarriesNoStaleMarkers)
{
    // It was stale last poll and answered this poll.
    json previous = json::array();
    carryForwardUnreadTables(previous, json::array({switchWithRules(3, "10.0.0.3")}),
                             {{3, kUnreadNoResponse}}, kT0);
    const json* stale = find(previous, 3);
    ASSERT_NE(stale, nullptr) << "precondition";
    ASSERT_TRUE(stale->contains(kStaleSinceField)) << "precondition";

    json fresh = json::array({switchWithRules(3, "10.0.0.3")});
    carryForwardUnreadTables(fresh, previous, {}, kT1);

    const json* sw3 = find(fresh, 3);
    ASSERT_NE(sw3, nullptr);
    // Recovery needs no separate path -- the fresh entry replaces the stale one -- but a marker
    // that outlived the fault would make every later reading look untrustworthy, and a warning
    // nobody can clear is a warning everybody learns to ignore.
    EXPECT_FALSE(sw3->contains(kStaleSinceField));
    EXPECT_FALSE(sw3->contains(kStalePollsField));
    EXPECT_FALSE(sw3->contains(kLastErrorField));
}

TEST(StaleTableCarryForward, AFreshReadIsNeverOverwrittenByAStaleCopy)
{
    const json previous = json::array({switchWithRules(3, "10.0.0.99")});
    json fresh = json::array({switchWithRules(3, "10.0.0.3")});

    // Defensive: one poll cannot both read and fail to read the same dpid, but if a caller ever
    // gets that wrong, the measurement has to win over the memory of one.
    EXPECT_EQ(carryForwardUnreadTables(fresh, previous, {{3, kUnreadNoResponse}}, kT0), 0u);
    ASSERT_EQ(fresh.size(), 1u);
    const json* sw3 = find(fresh, 3);
    ASSERT_NE(sw3, nullptr);
    EXPECT_EQ(sw3->at("flows").at("0").at(0).at("match").at("nw_dst"), "10.0.0.3");
}

// --- nothing to carry is still not nothing to say -------------------------------------------

TEST(StaleTableCarryForward, ASwitchNeverReadIsStillListedAndSaysSo)
{
    // Nothing in the cache: the read has failed since boot.
    json fresh = json::array();

    EXPECT_EQ(carryForwardUnreadTables(fresh, json::array(), {{5, kUnreadNoResponse}}, kT0), 1u);

    const json* sw5 = find(fresh, 5);
    ASSERT_NE(sw5, nullptr) << "an unreadable switch must not be omitted just because it is empty";
    EXPECT_TRUE(sw5->at("flows").empty());
    // The one field that separates "I know this switch has no rules" from "I have never managed
    // to ask". Without it this entry is the confident falsehood of 2026-08-07, restated.
    EXPECT_TRUE(sw5->value(kNeverReadField, false));
    EXPECT_EQ(sw5->value(kLastErrorField, std::string{}), std::string(kUnreadNoResponse));
    EXPECT_EQ(sw5->value(kStalePollsField, std::int64_t{0}), 1);
}

TEST(StaleTableCarryForward, ASwitchThatStaysUnreadSinceBootKeepsCountingAndStaysFlagged)
{
    json poll1 = json::array();
    carryForwardUnreadTables(poll1, json::array(), {{5, kUnreadNoResponse}}, kT0);

    json poll2 = json::array();
    carryForwardUnreadTables(poll2, poll1, {{5, kUnreadNoResponse}}, kT1);

    const json* sw5 = find(poll2, 5);
    ASSERT_NE(sw5, nullptr);
    EXPECT_TRUE(sw5->value(kNeverReadField, false)) << "still never read, so still flagged";
    EXPECT_EQ(sw5->value(kStalePollsField, std::int64_t{0}), 2);
    EXPECT_EQ(sw5->value(kStaleSinceField, std::int64_t{0}), kT0);
}

// --- the two fixes on this cache must not eat each other ------------------------------------

TEST(StaleTableCarryForward, TheStaleMarkersSurviveTheT11PendingEntryFilter)
{
    // getOpenFlowTables copies the cache and runs stripUnprogrammedEntries over it before
    // answering (DeviceConfigurationAndPowerManager.cpp:1974-1975). That filter rewrites
    // sw["flows"]; if it ever rebuilt the switch object instead, F-6's markers would be silently
    // dropped on the way out and the endpoint would be back to serving a stale table as fresh --
    // with the unit test above still green, because it never runs the filter.
    json previous = json::array({switchWithRules(3, "10.0.0.3")});
    json fresh = json::array();
    carryForwardUnreadTables(fresh, previous, {{3, kUnreadSuspectTimeout}}, kT0);

    // Empty predicate: the conservative default, which withholds every *tokened* row. The carried
    // rows were polled from a switch and carry no token, so none of them is withheld.
    const std::size_t withheld = stripUnprogrammedEntries(fresh, {});

    EXPECT_EQ(withheld, 0u);
    const json* sw3 = find(fresh, 3);
    ASSERT_NE(sw3, nullptr);
    EXPECT_EQ(sw3->value(kLastErrorField, std::string{}), std::string(kUnreadSuspectTimeout));
    EXPECT_EQ(sw3->value(kStalePollsField, std::int64_t{0}), 1);
    EXPECT_EQ(sw3->at("flows").at("0").size(), 1u);
}

// --- malformed input must not take the poll thread down --------------------------------------

TEST(StaleTableCarryForward, AMalformedPreviousCacheIsTreatedAsHavingNothingToCarry)
{
    json fresh = json::array();

    // This runs on the worker thread inside the write lock. A throw here would kill the poll
    // loop's iteration and leave the cache frozen -- a bigger outage than the one being reported.
    EXPECT_NO_THROW(carryForwardUnreadTables(fresh, json("not an array"),
                                             {{3, kUnreadNoResponse}}, kT0));
    const json* sw3 = find(fresh, 3);
    ASSERT_NE(sw3, nullptr) << "with no previous copy it still has to be listed";
    EXPECT_TRUE(sw3->value(kNeverReadField, false));
}

TEST(StaleTableCarryForward, MalformedEntriesInThePreviousCacheAreSkippedNotDereferenced)
{
    const json previous = json::array({json("garbage"),
                                       json::object(),
                                       json{{"dpid", "not a number"}},
                                       switchWithRules(3, "10.0.0.3")});
    json fresh = json::array();

    EXPECT_NO_THROW(carryForwardUnreadTables(fresh, previous, {{3, kUnreadUnparseable}}, kT0));
    const json* sw3 = find(fresh, 3);
    ASSERT_NE(sw3, nullptr) << "the good entry must still be found past the malformed ones";
    EXPECT_EQ(sw3->at("flows").at("0").size(), 1u);
}
