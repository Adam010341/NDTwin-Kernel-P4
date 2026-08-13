/**
 * Proves the P4 proxy's /stats/flow/<dpid> output is usable by the real Classifier.
 *
 * [Co-developed with claude code -- Adam]
 *
 * This is the acceptance test doc/2026-07-27_p4_bmv2_support_plan.md asks for in Phase 6: the proxy's
 * response must parse through `Classifier` and yield a non-empty forwarding effect. Without
 * that, `Classifier` stays empty and every flow's `path` is `[]` -- which is exactly the state
 * P4 mode was in before this endpoint existed.
 *
 * The payloads below are **the actual bytes** produced by
 * `proxy_agent/ryu_flow_stats.render_flow_stats()`, pasted verbatim rather than hand-written, so
 * this checks the two languages agree rather than checking my idea of the format twice. Same
 * approach as the sFlow round-trip test.
 *
 * The specific traps it guards, each of which fails silently rather than loudly:
 *
 *  - actions must be *strings* (`"OUTPUT:9"`); `parseActionsArrayIntoEffect` ignores the object
 *    form `{"type":"OUTPUT","port":N}` without comment.
 *  - IPv4 rules need `dl_type`, or the packed key does not match at lookup time.
 *  - priority must be >= 0; the lookup starts at `bestPriority = -1`, so a negative rule can
 *    never win (and used to crash the process outright).
 */

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "ndt_core/collection/Classifier.hpp"
#include "utils/Logger.hpp"

using json = nlohmann::json;
using ndtClassifier::Classifier;
using ndtClassifier::FlowKey;

namespace
{

/// Verbatim output of render_flow_stats(1, ...) for an LPM route and a 5-tuple ternary rule.
constexpr const char* kProxyFlowStats = R"([
  {"table_id":0,"priority":0,
   "match":{"nw_dst":"10.0.0.4","dl_type":2048},
   "actions":["OUTPUT:6"],
   "byte_count":0,"packet_count":0,"duration_sec":0,"duration_nsec":0,
   "idle_timeout":0,"hard_timeout":0,"cookie":0,"flags":0,"length":0},
  {"table_id":0,"priority":100,
   "match":{"nw_src":"10.0.0.1","nw_dst":"10.0.0.4","nw_proto":6,"dl_type":2048},
   "actions":["OUTPUT:9"],
   "byte_count":0,"packet_count":0,"duration_sec":0,"duration_nsec":0,
   "idle_timeout":0,"hard_timeout":0,"cookie":0,"flags":0,"length":0}
])";

/// A rule matching on a VLAN, as Ryu's OFPMatch renders one. The field is `vlan_vid`; there is no
/// `vlan_id` in OpenFlow, in Ryu, or anywhere else in this repo.
constexpr const char* kVlanFlowStats = R"([
  {"table_id":0,"priority":100,
   "match":{"vlan_vid":4096,"nw_dst":"10.0.0.4","dl_type":2048},
   "actions":["OUTPUT:6"],
   "byte_count":0,"packet_count":0,"duration_sec":0,"duration_nsec":0,
   "idle_timeout":0,"hard_timeout":0,"cookie":0,"flags":0,"length":0}
])";

/// The kernel wraps the proxy body as {"dpid": N, "flows": <body>} before handing it to the
/// Classifier -- see DeviceConfigurationAndPowerManager::fetchOpenFlowTablesInternal. Doing the
/// same here keeps this test on the real path rather than a convenient one.
json
asQueriedTables(uint64_t dpid, const char* proxyBody)
{
    return json::array({{{"dpid", dpid}, {"flows", {{std::to_string(dpid), json::parse(proxyBody)}}}}});
}

FlowKey
anIpv4Key(uint32_t src, uint32_t dst, uint8_t proto = 6, uint16_t sport = 1234,
          uint16_t dport = 80)
{
    FlowKey k{};
    k.ethType = 0x0800;
    k.ipProto = proto;
    k.ipv4Src = src;
    k.ipv4Dst = dst;
    k.tpSrc = sport;
    k.tpDst = dport;
    return k;
}

constexpr uint32_t kH1 = 0x0A000001; // 10.0.0.1
constexpr uint32_t kH4 = 0x0A000004; // 10.0.0.4
constexpr uint32_t kH9 = 0x0A000009; // 10.0.0.9

} // namespace

class P4FlowStatsToClassifier : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        // Required: the code under test logs, and Logger::instance() is a null shared_ptr until
        // init runs. Each suite must do this itself because ctest gives every test its own
        // process. Level off also means the trace lines still evaluate their arguments, which
        // is the condition that used to crash the Classifier.
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }

    Classifier classifier;
};

// --- What an EMPTY table must do to rules already ingested.
//
// [Co-developed with claude code -- Adam]
// updateFromQueriedTables skips a switch whose flow array is empty:
//
//     if (!flowsArray || !flowsArray->is_array() || flowsArray->empty()) { continue; }
//
// updateOneSwitch is what bumps the epoch and sweeps rules that were not in the new snapshot, so
// skipping it means an empty table cannot remove anything -- every previously-ingested rule
// survives untouched, indefinitely.
//
// That is not a hypothetical input. Measured today: with Ryu in a degraded state, `/stats/flow/1`
// returned `{"1": []}` for 110 consecutive seconds while the switch itself still held 130 rules.
// A control plane that answers with an empty table is exactly what this path receives, and the
// Classifier then keeps computing paths from rules it can no longer confirm. Empty paths are a
// visible failure; confidently wrong paths are not.
//
// Found via agy-review 0067, which framed it as knowsSwitch() returning false for an empty table.
// That framing is true but minor -- "no table for dpid N" is arguably the better diagnostic for an
// empty response anyway. Following the `continue` is what turns it into a staleness bug.

TEST_F(P4FlowStatsToClassifier, AnEmptyTableClearsTheRulesItReplaces)
{
    classifier.updateFromQueriedTables(asQueriedTables(1, kProxyFlowStats));
    ASSERT_EQ(classifier.getRuleCount(1), 2u) << "precondition: rules were ingested";
    ASSERT_TRUE(classifier.lookup(1, anIpv4Key(kH1, kH4)).has_value());

    // The switch now reports an empty table -- the state a degraded control plane produces.
    classifier.updateFromQueriedTables(
        json::array({{{"dpid", 1}, {"flows", {{"1", json::array()}}}}}));

    EXPECT_EQ(classifier.getRuleCount(1), 0u)
        << "the old rules survived an empty snapshot, so every path computed from now on is based "
           "on rules the control plane no longer reports";
    EXPECT_FALSE(classifier.lookup(1, anIpv4Key(kH1, kH4)).has_value())
        << "a stale rule still matches after the table it came from was reported empty";
}

TEST_F(P4FlowStatsToClassifier, AnEmptyTableStillCountsAsHavingHeardFromTheSwitch)
{
    // knowsSwitch is how calFlowPathByQueried decides between "no table for this switch" and "no
    // rule matched" -- two failures that send a reader to different places. An empty response is a
    // response, so once it has been ingested the switch is known.
    // Only an empty table, with nothing ingested before it -- otherwise the earlier non-empty
    // snapshot is what registers the switch and this proves nothing.
    ASSERT_FALSE(classifier.knowsSwitch(1)) << "precondition: nothing ingested yet";
    classifier.updateFromQueriedTables(
        json::array({{{"dpid", 1}, {"flows", {{"1", json::array()}}}}}));

    EXPECT_TRUE(classifier.knowsSwitch(1))
        << "reported as never polled, when in fact it was polled and answered with nothing";
}

TEST_F(P4FlowStatsToClassifier, AMalformedTableLeavesTheExistingRulesAlone)
{
    // The other direction, and the reason the empty case cannot simply be folded in with it: a body
    // that is not an array at all means the response was not understood, which is no evidence about
    // the switch's rules. Those must survive.
    classifier.updateFromQueriedTables(asQueriedTables(1, kProxyFlowStats));
    ASSERT_EQ(classifier.getRuleCount(1), 2u);

    classifier.updateFromQueriedTables(
        json::array({{{"dpid", 1}, {"flows", {{"1", "not an array"}}}}}));

    EXPECT_EQ(classifier.getRuleCount(1), 2u)
        << "an unparseable response discarded rules it said nothing about";
}

TEST_F(P4FlowStatsToClassifier, TheProxyResponseIsIngestedAtAll)
{
    ASSERT_NO_FATAL_FAILURE(
        classifier.updateFromQueriedTables(asQueriedTables(1, kProxyFlowStats)));
    EXPECT_EQ(classifier.getRuleCount(1), 2u)
        << "both rules from the proxy response must be stored";
}

TEST_F(P4FlowStatsToClassifier, ALookupYieldsANonEmptyOutputPort)
{
    // The whole point of Phase 6's flow-table work: without a usable effect here, every flow's
    // `path` stays empty no matter how much telemetry arrives.
    classifier.updateFromQueriedTables(asQueriedTables(1, kProxyFlowStats));

    const auto effect = classifier.lookup(1, anIpv4Key(kH1, kH4));

    ASSERT_TRUE(effect.has_value()) << "no rule matched the proxy's own 5-tuple rule";
    ASSERT_FALSE(effect->outputPorts.empty())
        << "matched, but with no output port -- the string action form was not parsed";
}

TEST_F(P4FlowStatsToClassifier, TheHigherPriorityFiveTupleRuleWins)
{
    // flow_5tuple sits ahead of ipv4_lpm in the pipeline, and the proxy reports that as a
    // higher priority. If the priorities were dropped in translation both rules would match on
    // nw_dst and the LPM port would win, sending traffic out the wrong interface.
    classifier.updateFromQueriedTables(asQueriedTables(1, kProxyFlowStats));

    const auto effect = classifier.lookup(1, anIpv4Key(kH1, kH4));

    ASSERT_TRUE(effect.has_value());
    ASSERT_FALSE(effect->outputPorts.empty());
    EXPECT_EQ(effect->outputPorts.front(), 9u)
        << "expected the priority-100 5-tuple rule (port 9), not the LPM default (port 6)";
}

TEST_F(P4FlowStatsToClassifier, TrafficNotCoveredByTheFiveTupleRuleFallsBackToTheLpmRoute)
{
    // A different source, so only the destination-based rule can match. This is the fallback
    // the pipeline relies on, and it must survive translation too.
    classifier.updateFromQueriedTables(asQueriedTables(1, kProxyFlowStats));

    const auto effect = classifier.lookup(1, anIpv4Key(kH9, kH4));

    ASSERT_TRUE(effect.has_value());
    ASSERT_FALSE(effect->outputPorts.empty());
    EXPECT_EQ(effect->outputPorts.front(), 6u) << "expected the LPM route's port";
}

TEST_F(P4FlowStatsToClassifier, AnObjectFormActionWouldNotHaveWorked)
{
    // Pins the reason ryu_flow_stats emits strings. parseActionsArrayIntoEffect handles only
    // the string form; the object form is dropped silently, so the rule is stored, matches, and
    // forwards nowhere. Asserting the failure keeps the constraint from being "tidied up" into
    // the object form later.
    json objectForm = json::parse(kProxyFlowStats);
    objectForm[1]["actions"] = json::array({{{"type", "OUTPUT"}, {"port", 9}}});

    Classifier other;
    other.updateFromQueriedTables(
        json::array({{{"dpid", 1}, {"flows", {{"1", objectForm}}}}}));

    const auto effect = other.lookup(1, anIpv4Key(kH1, kH4));
    if (effect.has_value() && !effect->outputPorts.empty())
    {
        EXPECT_NE(effect->outputPorts.front(), 9u)
            << "the object action form now parses -- if that is intentional, update "
               "ryu_flow_stats and delete this test";
    }
}

TEST_F(P4FlowStatsToClassifier, AnEmptyFlowListIsHandledCleanly)
{
    // What the endpoint returns for an unknown or unreachable switch. Must not throw, and must
    // not invent rules.
    ASSERT_NO_FATAL_FAILURE(classifier.updateFromQueriedTables(asQueriedTables(1, "[]")));
    EXPECT_EQ(classifier.getRuleCount(1), 0u);
}

// --- A rule that matches on a VLAN.
//
// [Co-developed with claude code -- Adam]
// The ingest guarded on `match.contains("vlan_vid")` and then read `match.at("vlan_id")`. There is
// no `vlan_id` -- not in OpenFlow, not in Ryu's rendering, not anywhere else in this repo -- so
// `.at()` threw json::out_of_range on any flow that actually carried a VLAN match.
//
// The throw is the small half. It escapes to openflowTablesUpdateWorker's catch, which logs and
// swallows it, and the rule that provoked it is in every subsequent poll: the same switch dies at
// the same flow every time. updateOneSwitch never completes for it, so its mark-and-sweep never
// runs, the switches after it in the loop never update, and the cached table the
// get_switch_openflow_table_entries endpoint serves never refreshes again -- reported as one
// repeated line in the worker's log.
//
// Nothing emits vlan_vid today. That is why it would have arrived as a mystery rather than as a
// regression: the first VLAN rule anyone installs stops flow-table collection for the fabric.

TEST_F(P4FlowStatsToClassifier, AVlanMatchIsIngestedRatherThanPoisoningEveryLaterPoll)
{
    classifier.updateFromQueriedTables(asQueriedTables(1, kVlanFlowStats));

    EXPECT_EQ(classifier.getRuleCount(1), 1u)
        << "the VLAN rule was not ingested: the match parser read a key it had not checked for";
}

TEST_F(P4FlowStatsToClassifier, AVlanRuleDoesNotStopTheSwitchesPolledAfterIt)
{
    // The consequence that outlives the poll. Switch 1 carries the VLAN rule; switch 2 is behind
    // it in the same reply, which is how the worker receives them.
    json tables = json::array({
        {{"dpid", 1}, {"flows", {{"1", json::parse(kVlanFlowStats)}}}},
        {{"dpid", 2}, {"flows", {{"2", json::parse(kProxyFlowStats)}}}},
    });

    classifier.updateFromQueriedTables(tables);

    EXPECT_EQ(classifier.getRuleCount(2), 2u)
        << "switch 2's table never landed -- one VLAN rule on an earlier switch took the rest of "
           "the poll down with it, every poll, for as long as the rule exists";
}
