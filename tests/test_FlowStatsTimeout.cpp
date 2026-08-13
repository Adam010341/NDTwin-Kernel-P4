/**
 * Tests for telling a real empty flow table apart from Ryu's stats timeout.
 *
 * [Co-developed with claude code -- Adam]
 *
 * On 2026-08-07 the kernel reported that all ten OVS switches held **zero** flow rules. s1 actually
 * held 130 and the fabric was forwarding normally -- verified with `ovs-ofctl dump-flows` as uid 0 --
 * and every liveness indicator read green at the same time: 288/288 edges up, 138/138 nodes up. The
 * twin was not missing data. It was stating a specific, confident falsehood, with nothing anywhere
 * to suggest distrusting it.
 *
 * The cause is that Ryu's `ofctl_rest` answers with whatever it has after
 * `DEFAULT_TIMEOUT = 1.0` seconds (`ryu/lib/ofctl_utils.py:28`, awaited at `:253`). When the switch's
 * reply never arrives, "whatever it has" is an empty table -- and on the wire that is
 * byte-for-byte identical to a switch that genuinely has no rules. Both are `{"1": []}`.
 *
 * The one thing that does differ is the round trip, and it differs by 25x. From
 * `doc/audit/2026-08-07_ryu-wedge-trace.tsv`, 151 samples:
 *
 *     healthy   0.027 - 0.083 s   ~35 KB body
 *     wedged    1.009 - 1.013 s   9-byte body, 116 consecutive samples
 *
 * So the rule is not "empty is bad" -- an empty table is a legitimate answer -- it is "empty *and*
 * slow is not evidence", because a genuinely empty table is the *fastest* possible reply: Ryu
 * already holds it and returns at once, while a lost reply costs the full timeout.
 *
 * Worth recording that this failure was made worse by a change of mine. commit 820c2a2 made the
 * Classifier apply an empty flow table instead of ignoring it, on the reasoning that an empty array
 * arriving with a dpid is a definite statement. That is right for a real empty table and wrong for a
 * timed-out one, and the two were indistinguishable until now.
 */

#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"

using nlohmann::json;

/// Reaches the protected static without constructing the manager, which would need a topology
/// monitor, a classifier and background threads. Same pattern as RelayReader and LivenessPolicy.
class FlowStatsReader : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::classifyFlowStatsReply;
    using DeviceConfigurationAndPowerManager::FlowStatsVerdict;
    using DeviceConfigurationAndPowerManager::kFlowStatsSuspectSeconds;
};

using Verdict = FlowStatsReader::FlowStatsVerdict;

namespace
{

Verdict
classify(const json& flows, double elapsed)
{
    return FlowStatsReader::classifyFlowStatsReply(flows, elapsed);
}

/// The exact body Ryu returns while wedged: one table id, no entries. 9 bytes on the wire.
json
wedgedBody()
{
    return json{{"1", json::array()}};
}

/// A table with real content, in the shape the OVS path produces.
json
populatedBody()
{
    return json{{"0",
                 json::array({json{{"priority", 100}, {"actions", json::array({"OUTPUT:2"})}},
                              json{{"priority", 10}, {"actions", json::array({"OUTPUT:1"})}}})}};
}

} // namespace

// --- the regression itself --------------------------------------------------------------------

TEST(FlowStatsTimeoutTest, AnEmptyTableThatTookRyusFullTimeoutIsNotBelieved)
{
    // The measured wedge: 1.011 s and 9 bytes, 116 samples in a row.
    EXPECT_EQ(classify(wedgedBody(), 1.011), Verdict::SuspectTimedOut);
}

TEST(FlowStatsTimeoutTest, AnEmptyTableThatCameBackImmediatelyIsBelieved)
{
    // A switch really can have no rules, and when it does Ryu answers at once because it already
    // holds the table. Refusing this would make the twin unable to represent an empty switch at all.
    EXPECT_EQ(classify(wedgedBody(), 0.031), Verdict::Usable);
}

TEST(FlowStatsTimeoutTest, TheWholeHealthyLatencyRangeIsBelievedForAnEmptyTable)
{
    // Every healthy sample from the 151-sample trace, so the threshold cannot drift down into the
    // range that real traffic produces.
    for (const double healthy : {0.027, 0.031, 0.034, 0.047, 0.056, 0.083})
    {
        EXPECT_EQ(classify(wedgedBody(), healthy), Verdict::Usable)
            << "a healthy round trip of " << healthy << "s was called a timeout";
    }
}

TEST(FlowStatsTimeoutTest, TheWholeWedgedLatencyRangeIsRefusedForAnEmptyTable)
{
    for (const double wedged : {1.009, 1.010, 1.011, 1.012, 1.013})
    {
        EXPECT_EQ(classify(wedgedBody(), wedged), Verdict::SuspectTimedOut)
            << "a wedged round trip of " << wedged << "s was believed";
    }
}

// --- slowness alone must never discard real data ----------------------------------------------

TEST(FlowStatsTimeoutTest, ATableWithEntriesIsAlwaysBelievedNoMatterHowSlow)
{
    // This is the half that protects against over-correcting. A large table on a loaded machine can
    // legitimately take longer than the threshold; discarding it would trade one wrong answer for
    // another. Entries present means the switch answered, and that is the whole question.
    EXPECT_EQ(classify(populatedBody(), 5.0), Verdict::Usable);
    EXPECT_EQ(classify(populatedBody(), 1.011), Verdict::Usable);
    EXPECT_EQ(classify(populatedBody(), 0.031), Verdict::Usable);
}

TEST(FlowStatsTimeoutTest, EntriesInAnyTableCountNotJustTheFirst)
{
    // Ryu keys the reply by table id and a switch may use several. An implementation that only looked
    // at the first table would throw away a real reply whenever table 0 happened to be empty.
    const json laterTableOnly{{"0", json::array()},
                              {"1", json::array()},
                              {"2", json::array({json{{"priority", 1}}})}};
    EXPECT_EQ(classify(laterTableOnly, 1.011), Verdict::Usable);
}

// --- shapes the parser can actually hand over --------------------------------------------------

TEST(FlowStatsTimeoutTest, AnObjectWithNoTablesAtAllIsTreatedTheSameAsEmptyTables)
{
    // `{}` rather than `{"1": []}`. Same meaning: nothing was reported.
    EXPECT_EQ(classify(json::object(), 1.011), Verdict::SuspectTimedOut);
    EXPECT_EQ(classify(json::object(), 0.031), Verdict::Usable);
}

TEST(FlowStatsTimeoutTest, TheP4ProxyArrayShapeIsHandledToo)
{
    // The P4 proxy returns a bare array rather than a table-id map. It has its own timeouts, so the
    // same reasoning applies and the function must not silently treat an array as "no entries".
    EXPECT_EQ(classify(json::array({json{{"priority", 1}}}), 1.011), Verdict::Usable);
    EXPECT_EQ(classify(json::array(), 1.011), Verdict::SuspectTimedOut);
    EXPECT_EQ(classify(json::array(), 0.031), Verdict::Usable);
}

TEST(FlowStatsTimeoutTest, AShapeTheParserShouldNeverProduceIsNotTakenAsEvidence)
{
    // Defensive: null or a scalar means the parse produced something unexpected. Treating that as a
    // real empty table would be the same class of mistake this file exists to prevent.
    EXPECT_EQ(classify(json(nullptr), 1.011), Verdict::SuspectTimedOut);
    EXPECT_EQ(classify(json(42), 1.011), Verdict::SuspectTimedOut);
}

// --- the boundary ------------------------------------------------------------------------------

TEST(FlowStatsTimeoutTest, TheThresholdIsInclusiveAndSitsBetweenTheTwoMeasuredRanges)
{
    const double t = FlowStatsReader::kFlowStatsSuspectSeconds;

    EXPECT_EQ(classify(wedgedBody(), t), Verdict::SuspectTimedOut) << "exactly at the threshold";
    EXPECT_EQ(classify(wedgedBody(), t - 0.001), Verdict::Usable) << "just under";

    // Pin the gap rather than the number: the threshold has to stay clear of both measured ranges,
    // so raising it to 1.0 (Ryu's own timeout, where the wedged samples live) or dropping it into
    // the healthy range both fail here.
    EXPECT_GT(t, 0.083) << "threshold sank into the healthy range";
    EXPECT_LT(t, 1.009) << "threshold rose into the wedged range";
}

/*
 * Not covered here: that fetchOpenFlowTablesInternal actually calls this and actually skips the
 * switch. It reaches the control plane through utils::execCommand directly rather than a virtual, so
 * driving it needs a live graph, a Classifier and a fake HTTP endpoint. The verdict logic above is
 * the part where the reasoning lives, but a mutation that deletes the *call* at the use site would
 * not be caught by anything in this file. Recorded as a real gap, not as covered.
 */

// --- a body that will not parse is not a report of an empty table -------------------------------
//
// [Co-developed with claude code -- Adam]
// Found by agy-review 0109, and it is a hole this very file's fix did not close.
//
// parseFlowStatsTextToJson used to return `json::array()` when the body was not JSON at all -- an
// HTTP 500 error page, a truncated response, anything. That made "the control plane sent garbage"
// byte-identical to "this switch has no rules", and applying the latter bumps the Classifier's epoch
// and sweeps every rule for that dpid.
//
// It was harmless until it was not: while updateFromQueriedTables ignored empty arrays, a corrupted
// response accidentally left the table alone. commit 820c2a2 -- mine -- made empty tables apply, and
// in doing so turned that accident into silent data loss.
//
// The latency guard above does not cover it, which is the part worth remembering: a parse failure is
// *local*, so it returns immediately, and immediate-and-empty is precisely the combination that
// check certifies as trustworthy. Two different doors into the same wrong answer.
//
// So the parser now returns nullopt and the caller keeps the previous table. What can be tested here
// without a control plane is the classifier's half of the contract: that an empty table which
// arrives fast really is treated as usable, and therefore that the parser must never present a
// failed parse as one.

TEST(FlowStatsTimeoutTest, AFastEmptyTableIsUsableWhichIsWhyAFailedParseMustNotLookLikeOne)
{
    // Pinning the trap rather than just the fix. If this ever stops holding, the reasoning in
    // parseFlowStatsTextToJson's nullopt return no longer applies and should be revisited.
    EXPECT_EQ(classify(json::array(), 0.004), Verdict::Usable)
        << "a fast empty table is trusted -- so a parse failure returning an empty array would be "
           "trusted too, which is the bug agy-review 0109 found";
    EXPECT_EQ(classify(json::object(), 0.004), Verdict::Usable);
}

// --- a reported failure is never a snapshot ---------------------------------------------------
// [Co-developed with claude code -- Adam]
// The P4 proxy answers {"error": ...} (HTTP 503) when it cannot read a switch. The fetch goes
// through `curl -s`, which never surfaces the status code, so this body shape is the only channel
// the failure travels on. Before the ReportedFailure verdict existed, this body had no array
// entries and came back *fast* -- failing is faster than timing out -- so it classified Usable and
// was applied as an authoritative empty snapshot, sweeping every rule the Classifier held for that
// switch. Found by agy-review 0170 #2.

TEST(FlowStatsTimeoutTest, AnErrorBodyIsAReportedFailureNoMatterHowFastItArrived)
{
    // The exact shape the proxy sends, at a latency far under the suspicion threshold -- the
    // combination the latency guard is structurally unable to catch.
    const json errorBody{{"error", "reading tables from switch 7 failed: RpcError"}};
    EXPECT_EQ(classify(errorBody, 0.004), Verdict::ReportedFailure);
}

TEST(FlowStatsTimeoutTest, AnErrorBodyIsAReportedFailureEvenWhenSlow)
{
    // Latency must play no part in this verdict: a slow failure is still a failure, not a
    // suspected timeout -- the caller's log message names the actual cause either way.
    const json errorBody{{"error", "stream broken"}};
    EXPECT_EQ(classify(errorBody, 1.7), Verdict::ReportedFailure);
}

TEST(FlowStatsTimeoutTest, AFastApiDetailBodyIsAlsoAReportedFailure)
{
    // FastAPI answers {"detail": ...} for an exception the handler did not catch itself. Same
    // meaning, same verdict, so an unhandled proxy bug cannot masquerade as an empty table.
    const json detailBody{{"detail", "Internal Server Error"}};
    EXPECT_EQ(classify(detailBody, 0.010), Verdict::ReportedFailure);
}

TEST(FlowStatsTimeoutTest, ARealTableIsNeverMistakenForAFailureReport)
{
    // Genuine tables key on numeric table-id strings, never "error"/"detail" -- the zero-false-
    // positive claim in the header comment, held down by a test.
    EXPECT_EQ(classify(populatedBody(), 0.031), Verdict::Usable);
    EXPECT_EQ(classify(wedgedBody(), 0.031), Verdict::Usable);
}

