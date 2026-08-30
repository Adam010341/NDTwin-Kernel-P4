/**
 * Tests for KNOWN-ISSUES T-11 (option A: the table listing reports only programmed entries).
 *
 * [Co-developed with claude code -- Adam]
 *
 * `install_flow_entry` writes the requested rule straight into the table cache on the HTTP thread,
 * before the dispatcher has sent anything, so `get_switch_openflow_table_entries` served it as
 * though it were a table entry -- carrying the requested priority and no counters, for as long as
 * it took the periodic poll to overwrite the cache (~10.7 s, measured).
 *
 * Both directions are asserted here, because a filter that only ever hides things is as useless as
 * one that never does:
 *
 *   - **force-red**: an unconfirmed row must be withheld, and if the filter stops working the
 *     phantom comes straight back (`APendingEntryIsWithheldUntilConfirmed`);
 *   - **force-green**: a confirmed row must appear, and a row that never had a token -- everything
 *     polled from an actual switch -- must appear untouched.
 *
 * The live half of the acceptance (post a real rule, watch it absent at t=0 and present after the
 * southbound confirms) needs a fabric and is recorded in the ticket, not here.
 */

#include <gtest/gtest.h>

#include "ndt_core/routing_management/DispatchOutcomeLog.hpp"
#include "ndt_core/routing_management/PendingEntryFilter.hpp"

using nlohmann::json;

namespace
{

/// One switch with one table holding the given entries.
json
tableWith(json entries)
{
    json sw;
    sw["dpid"] = 1;
    sw["flows"] = json::object();
    sw["flows"]["1"] = std::move(entries);
    return json::array({std::move(sw)});
}

/// A row as the periodic poll produces it: switch vocabulary, counters, no token.
json
polledEntry(const char* dst)
{
    return json{{"priority", 0},
                {"match", {{"dl_type", 2048}, {"nw_dst", dst}}},
                {"actions", json::array({"OUTPUT:2"})},
                {"byte_count", 0},
                {"packet_count", 0},
                {"table_id", 0}};
}

/// A row as the optimistic write produces it: caller vocabulary, requested priority, a token.
json
pendingEntry(const char* dst, uint64_t token, int priority = 915)
{
    return json{{"priority", priority},
                {"match", {{"eth_type", 2048}, {"ipv4_dst", dst}}},
                {"actions", json::array()},
                {"table_id", 0},
                {kPendingTokenField, token}};
}

std::size_t
entryCount(const json& tables)
{
    return tables.at(0).at("flows").at("1").size();
}

} // namespace

TEST(PendingEntryFilterTest, APendingEntryIsWithheldUntilConfirmed)
{
    json tables = tableWith(json::array({pendingEntry("10.0.0.240", 7)}));

    const auto withheld = stripUnprogrammedEntries(tables, [](uint64_t) { return false; });

    EXPECT_EQ(withheld, 1u);
    EXPECT_EQ(entryCount(tables), 0u)
        << "an unprogrammed entry is being served as a table entry -- this is the phantom";
}

TEST(PendingEntryFilterTest, AConfirmedEntryIsServedAndLosesItsStamp)
{
    // force-green. A filter that only ever hides is not a fix, it is an outage.
    json tables = tableWith(json::array({pendingEntry("10.0.0.240", 7)}));

    const auto withheld = stripUnprogrammedEntries(tables, [](uint64_t t) { return t == 7; });

    EXPECT_EQ(withheld, 0u);
    ASSERT_EQ(entryCount(tables), 1u) << "a confirmed rule vanished from the view";

    const json& entry = tables.at(0).at("flows").at("1").at(0);
    EXPECT_FALSE(entry.contains(kPendingTokenField))
        << "the internal stamp reached a consumer, which can then come to depend on it";
    EXPECT_EQ(entry.at("match").at("ipv4_dst"), "10.0.0.240");
}

TEST(PendingEntryFilterTest, PolledEntriesAreNeverTouchedEvenWhenNothingIsConfirmed)
{
    // Everything read back from a real switch arrives without a token. If the filter withheld
    // those, a predicate returning false -- which is also the unwired default -- would empty the
    // entire table view of every switch in the fabric.
    json tables = tableWith(json::array({polledEntry("10.0.0.1"), polledEntry("10.0.0.2")}));

    const auto withheld = stripUnprogrammedEntries(tables, [](uint64_t) { return false; });

    EXPECT_EQ(withheld, 0u);
    EXPECT_EQ(entryCount(tables), 2u) << "real switch entries were hidden";
}

TEST(PendingEntryFilterTest, TheFilterIsKeyedOnProvenanceNotOnLookingLikeARequest)
{
    // The trap this ticket must not fall into. FINDING-03 detected the phantom by its shape --
    // four fields, no counters, the caller's vocabulary -- and that signature is real. Keying the
    // *fix* on it would make the instrument the same shape as the thing it measures.
    //
    // Left entry: looks exactly like a phantom (caller vocabulary, no counters) but has no token,
    // so it came from somewhere the filter has no claim about. It must survive.
    // Right entry: looks exactly like a polled row (counters, switch vocabulary) but carries an
    // unconfirmed token, so it was written optimistically. It must be withheld.
    json requestShaped = json{{"priority", 915},
                              {"match", {{"eth_type", 2048}, {"ipv4_dst", "10.0.0.9"}}},
                              {"actions", json::array()}};
    json switchShaped = polledEntry("10.0.0.8");
    switchShaped[kPendingTokenField] = 42;

    json tables = tableWith(json::array({requestShaped, switchShaped}));

    const auto withheld = stripUnprogrammedEntries(tables, [](uint64_t) { return false; });

    EXPECT_EQ(withheld, 1u);
    ASSERT_EQ(entryCount(tables), 1u);
    EXPECT_EQ(tables.at(0).at("flows").at("1").at(0).at("match").at("ipv4_dst"), "10.0.0.9")
        << "the surviving row should be the untokened one, whatever either of them looks like";
}

TEST(PendingEntryFilterTest, AnUnwiredPredicateWithholdsRatherThanRestoresThePhantom)
{
    // If the wiring in main.cpp is ever dropped, the predicate is empty. The failure must be
    // "entries missing for up to one poll interval", never "the phantom is back".
    json tables = tableWith(json::array({pendingEntry("10.0.0.240", 7), polledEntry("10.0.0.1")}));

    const auto withheld = stripUnprogrammedEntries(tables, {});

    EXPECT_EQ(withheld, 1u);
    ASSERT_EQ(entryCount(tables), 1u);
    EXPECT_TRUE(tables.at(0).at("flows").at("1").at(0).at("match").contains("nw_dst"))
        << "the polled entry should be the survivor";
}

TEST(PendingEntryFilterTest, MalformedShapesAreLeftAloneRatherThanThrowing)
{
    // The cache is assembled from two sources and has held two schemas at once before. Throwing
    // here would take out every reader of the table view.
    json notAnArray = json::object({{"nonsense", 1}});
    EXPECT_EQ(stripUnprogrammedEntries(notAnArray, {}), 0u);

    json noFlows = json::array({json::object({{"dpid", 1}})});
    EXPECT_EQ(stripUnprogrammedEntries(noFlows, {}), 0u);

    json flowsNotArray = json::array({json{{"dpid", 1}, {"flows", {{"1", 5}}}}});
    EXPECT_EQ(stripUnprogrammedEntries(flowsNotArray, {}), 0u);
}

// --- The confirmation signal itself, which is what the predicate reads in production.

TEST(ProgrammedTokenTest, OnlyASouthboundSuccessConfirmsAToken)
{
    DispatchOutcomeLog log;

    FlowJob confirmed;
    confirmed.dpid = 1;
    confirmed.op = FlowOp::Install;
    confirmed.priority = 900;
    confirmed.match = json::object();
    confirmed.token = 11;

    FlowJob refused = confirmed;
    refused.token = 22;

    log.record(confirmed, OpResult::success());
    log.record(refused, OpResult::failure(400, "rejected"));

    EXPECT_TRUE(log.isProgrammed(11));
    EXPECT_FALSE(log.isProgrammed(22)) << "a refused rule must never be reported as programmed";
    EXPECT_FALSE(log.isProgrammed(33)) << "a token nobody has answered for yet";
    EXPECT_TRUE(log.isProgrammed(0)) << "untokened rows are not the filter's business";
}

TEST(ProgrammedTokenTest, ForgettingATokenHidesARealEntryRatherThanShowingAPhantom)
{
    // The confirmation set is bounded, so under sustained load the oldest tokens age out. The
    // direction of that failure is the whole point: an aged-out token reads as unconfirmed, so the
    // row is withheld. Withholding a real entry for one poll interval is recoverable; showing an
    // unprogrammed one is the defect being fixed.
    DispatchOutcomeLog log;

    FlowJob job;
    job.dpid = 1;
    job.op = FlowOp::Install;
    job.match = json::object();

    constexpr uint64_t kOverflow = 9000; // > kProgrammedBudget
    for (uint64_t t = 1; t <= kOverflow; ++t)
    {
        job.token = t;
        log.record(job, OpResult::success());
    }

    EXPECT_TRUE(log.isProgrammed(kOverflow)) << "the most recent confirmation must survive";
    EXPECT_FALSE(log.isProgrammed(1)) << "the oldest should have aged out";
    EXPECT_GT(log.confirmationsForgotten(), 0u)
        << "aging out is invisible unless it is counted, and it changes what the view shows";
}
