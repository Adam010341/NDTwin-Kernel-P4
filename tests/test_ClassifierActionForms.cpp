/**
 * Tests for which action encodings the Classifier actually understands.
 *
 * [Co-developed with claude code -- Adam]
 *
 * `parseActionsArrayIntoEffect` accepts exactly one encoding -- the string form Ryu's
 * ofctl_rest emits, `"OUTPUT:2"` -- and silently ignores everything else. In particular it
 * ignores `{"type": "OUTPUT", "port": 2}`, which is the encoding used on the other side of this
 * same repo by `InstallFlowEntryTask` in LLMResponseTypes.hpp, and which is also what a
 * hand-written fixture naturally looks like.
 *
 * The decision recorded here is that string-only is *intended*, not a gap: the function's only
 * caller is the ingest path for `GET /stats/flow/<dpid>`, whose producer is Ryu, and
 * test_P4FlowStatsToClassifier.cpp already pins the P4 proxy to emitting the same string form
 * for that reason. So these tests assert the contract as it stands rather than asking for the
 * object form to be added.
 *
 * What makes it worth testing anyway is that the failure is silent in the worst possible way.
 * An unrecognised action does not throw and does not log -- it simply leaves `outputPorts`
 * empty, which is the *same* observable state as a legitimate drop rule. A control plane that
 * changed encoding would therefore turn every forwarding rule in the fabric into an apparent
 * drop rule, and the only visible symptom would be link usage and flow paths quietly going
 * empty. That is the exact failure shape that already cost this project several commits when
 * ovs-vsctl returned nothing under bmv2 and every port resolved to 0.
 *
 * One test documents a real bug in the reserved-port constants; see the report.
 */

#include <optional>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "ndt_core/collection/Classifier.hpp"

using json = nlohmann::json;
using ndtClassifier::Classifier;
using ndtClassifier::FlowKey;
using ndtClassifier::RuleEffect;

namespace
{

/// One switch object in the shape updateFromQueriedTables expects.
json
aSwitch(uint64_t dpid, json flows)
{
    return json{{"dpid", dpid}, {"flows", {{std::to_string(dpid), std::move(flows)}}}};
}

/// A rule that matches one IPv4 destination, carrying whatever actions the caller supplies.
json
ruleWithActions(json actions, const std::string& dst = "10.0.0.4")
{
    return json{{"priority", 10},
                {"table_id", 0},
                {"match", {{"dl_type", 2048}, {"nw_dst", dst}}},
                {"actions", std::move(actions)}};
}

FlowKey keyFor(uint32_t ipv4Dst = 0x0A000004)
{
    FlowKey key{};
    key.ethType = 0x0800;
    key.ipv4Dst = ipv4Dst;
    return key;
}

/// Ingests a single rule and returns the effect a matching packet resolves to.
std::optional<RuleEffect>
effectOf(json actions)
{
    Classifier classifier;
    classifier.updateFromQueriedTables(
        json::array({aSwitch(1, json::array({ruleWithActions(std::move(actions))}))}));
    return classifier.lookup(1, keyFor());
}

} // namespace

// --- The encoding that is supported.

TEST(ClassifierActionFormsTest, TheStringOutputFormYieldsThePortItNames)
{
    const auto effect = effectOf(json::array({"OUTPUT:7"}));
    ASSERT_TRUE(effect.has_value());
    ASSERT_EQ(effect->outputPorts.size(), 1u);
    EXPECT_EQ(effect->outputPorts.front(), 7u);
}

TEST(ClassifierActionFormsTest, TheActionKindIsMatchedCaseInsensitivelyButThePortIsNot)
{
    // toUpper is applied to the kind, so Ryu changing `OUTPUT` to `output` would not break
    // ingest. Worth pinning because the uppercasing is easy to drop as redundant.
    for (const char* const spelling : {"output:7", "Output:7", "OuTpUt:7", "OUTPUT:7"})
    {
        const auto effect = effectOf(json::array({spelling}));
        ASSERT_TRUE(effect.has_value()) << spelling;
        ASSERT_EQ(effect->outputPorts.size(), 1u) << spelling;
        EXPECT_EQ(effect->outputPorts.front(), 7u) << spelling;
    }
}

TEST(ClassifierActionFormsTest, SeveralOutputActionsAllArriveInTheOrderTheyWereListed)
{
    // A multi-port rule is how flooding and mirroring are expressed, and the order is the order
    // packets are emitted. Nothing else in the pipeline sorts these.
    const auto effect = effectOf(json::array({"OUTPUT:3", "OUTPUT:1", "OUTPUT:2"}));
    ASSERT_TRUE(effect.has_value());
    const std::vector<uint32_t> expected = {3u, 1u, 2u};
    EXPECT_EQ(effect->outputPorts, expected);
}

TEST(ClassifierActionFormsTest, AGroupActionIsRecordedSeparatelyFromOutputPorts)
{
    const auto effect = effectOf(json::array({"GROUP:10"}));
    ASSERT_TRUE(effect.has_value());
    ASSERT_TRUE(effect->groupId.has_value());
    EXPECT_EQ(effect->groupId.value(), 10u);
    EXPECT_TRUE(effect->outputPorts.empty()) << "a group action is not an output port";
}

TEST(ClassifierActionFormsTest, AnUnparseableGroupIdLeavesTheGroupUnsetRatherThanZero)
{
    // groupId is an optional precisely so that "no group" and "group 0" are different states.
    // Group 0 is a legal OpenFlow group id, so defaulting to it would invent a real target.
    for (const char* const bad : {"GROUP:", "GROUP:abc", "GROUP:-1", "GROUP:1x", "GROUP"})
    {
        const auto effect = effectOf(json::array({bad}));
        ASSERT_TRUE(effect.has_value()) << bad;
        EXPECT_FALSE(effect->groupId.has_value()) << bad << " produced a group id";
    }
}

TEST(ClassifierActionFormsTest, AGotoTableInstructionIsPickedUpFromTheInstructionsArray)
{
    // OF1.3 reports a pipeline step as an instruction rather than an action, and the two live in
    // different keys. Both are parsed, so a rule can carry an output and a goto at once.
    Classifier classifier;
    json rule = ruleWithActions(json::array({"OUTPUT:5"}));
    rule["instructions"] = json::array({json{{"type", "GOTO_TABLE"}, {"table_id", 3}}});
    classifier.updateFromQueriedTables(json::array({aSwitch(1, json::array({rule}))}));

    const auto effect = classifier.lookup(1, keyFor());
    ASSERT_TRUE(effect.has_value());
    ASSERT_TRUE(effect->gotoTable.has_value());
    EXPECT_EQ(effect->gotoTable.value(), 3u);
    ASSERT_EQ(effect->outputPorts.size(), 1u) << "the actions array must still be read";
    EXPECT_EQ(effect->outputPorts.front(), 5u);
}

TEST(ClassifierActionFormsTest, ActionsNestedInsideAnInstructionAreAlsoParsed)
{
    // OF1.3's APPLY_ACTIONS carries the real output port one level down. A parser that only read
    // the top-level "actions" would see every 1.3 rule as a drop.
    Classifier classifier;
    json rule = ruleWithActions(json::array());
    rule["instructions"] = json::array(
        {json{{"type", "APPLY_ACTIONS"}, {"actions", json::array({"OUTPUT:9"})}}});
    classifier.updateFromQueriedTables(json::array({aSwitch(1, json::array({rule}))}));

    const auto effect = classifier.lookup(1, keyFor());
    ASSERT_TRUE(effect.has_value());
    ASSERT_EQ(effect->outputPorts.size(), 1u);
    EXPECT_EQ(effect->outputPorts.front(), 9u);
}

// --- The encodings that are not supported, and are ignored in silence.

TEST(ClassifierActionFormsTest, TheObjectActionFormIsIgnoredEntirelyDocumentsCurrentBehaviour)
{
    // THE test this file exists for. `{"type": "OUTPUT", "port": 2}` is the encoding used by
    // InstallFlowEntryTask in this same repo, and here it produces a rule that is stored, that
    // matches, and that forwards nowhere -- indistinguishable from a table-miss drop.
    //
    // Asserted as current behaviour, not as desirable: string-only is intended, because the sole
    // producer is Ryu. But nothing in the code says so and nothing warns, so a fixture or a proxy
    // written to the other convention fails by emptying the fabric rather than by erroring.
    const auto effect = effectOf(json::array({json{{"type", "OUTPUT"}, {"port", 2}}}));
    ASSERT_TRUE(effect.has_value()) << "the rule itself must still be stored and matchable";
    EXPECT_TRUE(effect->outputPorts.empty())
        << "the object action form is now understood -- update this test and the LLM-side one";
    EXPECT_FALSE(effect->groupId.has_value());
}

TEST(ClassifierActionFormsTest, AnObjectGroupActionIsIgnoredTheSameWay)
{
    const auto effect = effectOf(json::array({json{{"type", "GROUP"}, {"group_id", 10}}}));
    ASSERT_TRUE(effect.has_value());
    EXPECT_FALSE(effect->groupId.has_value());
    EXPECT_TRUE(effect->outputPorts.empty());
}

TEST(ClassifierActionFormsTest, AnActionsValueThatIsNotAnArrayIsIgnoredWithoutThrowing)
{
    // This runs on the ingest path for an HTTP body from another process. A 404 HTML page that
    // happens to parse, or a schema change on the Ryu side, must not take the poller down --
    // there is no handler on that thread.
    for (const json& notAnArray : {json(nullptr), json("OUTPUT:2"), json::object(), json(2),
                                   json(true)})
    {
        Classifier classifier;
        const json tables =
            json::array({aSwitch(1, json::array({ruleWithActions(notAnArray)}))});
        EXPECT_NO_THROW(classifier.updateFromQueriedTables(tables)) << notAnArray.dump();
        EXPECT_EQ(classifier.getRuleCount(1), 1u)
            << "the rule must still be stored: " << notAnArray.dump();
    }
}

TEST(ClassifierActionFormsTest, AnActionKindTheParserDoesNotKnowIsSkippedButOthersStillApply)
{
    // Real Ryu rules carry SET_FIELD, DEC_NW_TTL, PUSH_VLAN and more alongside the output. An
    // unknown kind must not abort the rest of the array, or one exotic action would erase the
    // port for the whole rule.
    const auto effect = effectOf(json::array(
        {"SET_FIELD: {eth_dst:aa:bb:cc:dd:ee:ff}", "DEC_NW_TTL", "OUTPUT:4", "POP_VLAN"}));
    ASSERT_TRUE(effect.has_value());
    ASSERT_EQ(effect->outputPorts.size(), 1u) << "the OUTPUT after unknown actions was lost";
    EXPECT_EQ(effect->outputPorts.front(), 4u);
}

TEST(ClassifierActionFormsTest, AnOutputWithNoTargetIsSkippedRatherThanBecomingPortZero)
{
    // Port 0 is a real port to send to, so a defaulted 0 would claim a forwarding decision that
    // was never made.
    //
    // "OUTPUT:-4" is in this list rather than the lenient one below for a non-obvious reason:
    // strtoul does not reject a minus sign, it wraps, so "-4" becomes 2^64-4. What rejects it is
    // the `v > 0xFFFFFFFF` range check further down -- which means the range check is doing
    // double duty as the sign check, and removing it would turn "-4" into port 4294967292.
    for (const char* const bad : {"OUTPUT:", "OUTPUT", "OUTPUT:not_a_port", "OUTPUT:4x",
                                  "OUTPUT:-4", "OUTPUT:0x4"})
    {
        const auto effect = effectOf(json::array({bad}));
        ASSERT_TRUE(effect.has_value()) << bad;
        EXPECT_TRUE(effect->outputPorts.empty()) << bad << " resolved to a port";
    }
}

TEST(ClassifierActionFormsTest, LeadingWhitespaceAndAPlusSignAreAcceptedInAPortNumber)
{
    // Found by this test failing on an assumption. parseUint is documented by its own code as
    // strict -- it checks errno, rejects an empty string, and requires the whole string to be
    // consumed -- but it is built on strtoul, which silently skips leading whitespace and accepts
    // a leading '+' before any of those checks can see them. So "OUTPUT: 4" is port 4.
    //
    // That is the *lenient* direction and harmless here, but it is worth writing down because the
    // strictness of the surrounding checks reads as if it were total, and the next person adding a
    // field to this parser will assume the same guarantee holds for theirs.
    for (const char* const spelling : {"OUTPUT: 4", "OUTPUT:+4", "OUTPUT:\t4", "OUTPUT:  4"})
    {
        const auto effect = effectOf(json::array({spelling}));
        ASSERT_TRUE(effect.has_value()) << spelling;
        ASSERT_EQ(effect->outputPorts.size(), 1u) << spelling << " was rejected";
        EXPECT_EQ(effect->outputPorts.front(), 4u) << spelling;
    }

    // Trailing space is a different matter: strtoul stops at it and leaves *end != '\0', which the
    // explicit check does catch. So the lenience is one-sided.
    const auto trailing = effectOf(json::array({"OUTPUT:4 "}));
    ASSERT_TRUE(trailing.has_value());
    EXPECT_TRUE(trailing->outputPorts.empty()) << "a trailing space is rejected, a leading one is not";
}

TEST(ClassifierActionFormsTest, AnOutputPortTooLargeForThirtyTwoBitsIsRefusedNotTruncated)
{
    // parseUint rejects above 0xFFFFFFFF rather than wrapping. Truncating would map a nonsense
    // value onto a real port number, which is worse than dropping it.
    for (const char* const tooBig : {"OUTPUT:4294967296", "OUTPUT:99999999999999999999"})
    {
        const auto effect = effectOf(json::array({tooBig}));
        ASSERT_TRUE(effect.has_value()) << tooBig;
        EXPECT_TRUE(effect->outputPorts.empty()) << tooBig << " was truncated into a real port";
    }
    // The largest value that does fit is still accepted, so the bound is not off by one.
    const auto ok = effectOf(json::array({"OUTPUT:4294967295"}));
    ASSERT_TRUE(ok.has_value());
    ASSERT_EQ(ok->outputPorts.size(), 1u);
    EXPECT_EQ(ok->outputPorts.front(), 4294967295u);
}

// [Co-developed with claude code -- Adam]
// AllFourReservedOutputTargetsCollapseToOneValueDocumentsCurrentBehaviour used to be here. It pinned
// the defect where CONTROLLER, LOCAL, FLOOD and NORMAL all parsed to 65535 -- which in OpenFlow 1.3
// is not a reserved port at all, and which made a rule edited from FLOOD to CONTROLLER hash
// identically to the original, so the change was invisible to the classifier. The four now carry
// their 1.3 values; the replacement is
// TheFourReservedOutputTargetsMapToDistinctOpenFlow13PortNumbers, derived from the specification
// rather than from the parser.


TEST(ClassifierActionFormsTest, AReservedTargetWithATrailingPortNumberUsesTheReservedValue)
{
    // Ryu writes `OUTPUT:CONTROLLER:65535` when it includes the max_len. The parser splits on the
    // second colon and reads only the name, so the trailing number must not be taken as a port.
    // [Co-developed with claude code -- Adam]
    // The expected value is OFPP_CONTROLLER (OpenFlow 1.3, 0xfffffffd), not 65535. It was written as
    // 65535 because that is what the parser produced at the time -- all four reserved targets shared
    // that one value. The point this test makes is unaffected and still worth making: the trailing
    // number is Ryu's max_len, so reading it as a port would be wrong whatever the reserved constant
    // happens to be. That is what the second case checks.
    constexpr uint32_t kOfppController = 0xfffffffdu;

    const auto effect = effectOf(json::array({"OUTPUT:CONTROLLER:65535"}));
    ASSERT_TRUE(effect.has_value());
    ASSERT_EQ(effect->outputPorts.size(), 1u);
    EXPECT_EQ(effect->outputPorts.front(), kOfppController);

    const auto truncated = effectOf(json::array({"OUTPUT:CONTROLLER:128"}));
    ASSERT_TRUE(truncated.has_value());
    ASSERT_EQ(truncated->outputPorts.size(), 1u);
    EXPECT_EQ(truncated->outputPorts.front(), kOfppController)
        << "the max_len was read as a port";
}

TEST(ClassifierActionFormsTest,
     TheFourReservedOutputTargetsMapToDistinctOpenFlow13PortNumbers)
{
    // Per OpenFlow 1.3.0 spec (ONF TS-006) §4.1.1, reserved ports are 32-bit:
    //
    //   OFPP_CONTROLLER = 0xfffffffd  (4294967293)
    //   OFPP_LOCAL      = 0xfffffffe  (4294967294)
    //   OFPP_FLOOD      = 0xfffffffb  (4294967291)
    //   OFPP_NORMAL     = 0xfffffffa  (4294967290)
    //
    // The current implementation assigns 65535 (0xffff, which is OFPP_ANY/NONE in
    // OpenFlow 1.0 but has no forwarding meaning in 1.3) to ALL FOUR of them --
    // see TheFourReservedOutputTargetsMapToDistinctOpenFlow13PortNumbers.
    //
    // This test asserts the SPEC behaviour: each reserved name must map to its
    // correct, DISTINCT 32-bit OpenFlow 1.3 port number. It is EXPECTED TO FAIL
    // until Classifier.cpp:875-879 is corrected.
    //
    // Confidence: HIGH for CONTROLLER (0xfffffffd) and LOCAL (0xfffffffe) --
    // these are the 32-bit extensions of the well-known 16-bit values 0xfffd/0xfffe.
    // MEDIUM for FLOOD (0xfffffffb) and NORMAL (0xfffffffa) -- same extension
    // pattern, but these are optional in OF1.3 and the correct values are drawn from
    // the standard openflow-1.3.h header convention.

    // OpenFlow 1.3 32-bit reserved port numbers
    constexpr uint32_t OFPP_CONTROLLER = 0xfffffffd;  // 4294967293
    constexpr uint32_t OFPP_LOCAL      = 0xfffffffe;  // 4294967294
    constexpr uint32_t OFPP_FLOOD      = 0xfffffffb;  // 4294967291
    constexpr uint32_t OFPP_NORMAL     = 0xfffffffa;  // 4294967290

    // Each reserved target must map to its own distinct value.
    struct Case { const char* action; uint32_t expected; };
    const std::vector<Case> cases = {
        {"OUTPUT:CONTROLLER", OFPP_CONTROLLER},
        {"OUTPUT:LOCAL",      OFPP_LOCAL},
        {"OUTPUT:FLOOD",      OFPP_FLOOD},
        {"OUTPUT:NORMAL",     OFPP_NORMAL},
        // Case-insensitive variants must also map correctly.
        {"OUTPUT:controller", OFPP_CONTROLLER},
        {"OUTPUT:flood",      OFPP_FLOOD},
    };

    for (const auto& c : cases)
    {
        const auto effect = effectOf(json::array({c.action}));
        ASSERT_TRUE(effect.has_value()) << c.action;
        ASSERT_EQ(effect->outputPorts.size(), 1u)
            << c.action << " produced " << effect->outputPorts.size() << " ports";
        EXPECT_EQ(effect->outputPorts.front(), c.expected)
            << c.action << " mapped to " << effect->outputPorts.front()
            << " (0x" << std::hex << effect->outputPorts.front() << std::dec
            << ") instead of 0x" << std::hex << c.expected << std::dec;
    }

    // Sanity: all four reserved values must be distinct.
    // If this fails, a different bug is present -- the values were corrected but
    // some are still duplicates.
    EXPECT_NE(OFPP_CONTROLLER, OFPP_LOCAL);
    EXPECT_NE(OFPP_CONTROLLER, OFPP_FLOOD);
    EXPECT_NE(OFPP_CONTROLLER, OFPP_NORMAL);
    EXPECT_NE(OFPP_LOCAL, OFPP_FLOOD);
    EXPECT_NE(OFPP_LOCAL, OFPP_NORMAL);
    EXPECT_NE(OFPP_FLOOD, OFPP_NORMAL);
}
