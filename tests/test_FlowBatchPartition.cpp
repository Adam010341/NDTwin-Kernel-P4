/**
 * @file test_FlowBatchPartition.cpp
 * @brief Tests for partitionFlowBatchByKnownDpid, the flow-batch admission decision.
 *
 * [Co-developed with claude code -- Adam]
 *
 * The batch endpoint used to answer 200 for a batch naming a switch that does not exist. The first
 * fix rejected such a batch whole, with 404. That was wrong for the two applications that actually
 * write flows: both discard the response (Energy-Saving-App energy_saving_app.cpp:225 and :241,
 * Traffic-Engineering-App Traffic-engineering-App.py:572), so all-or-nothing did not make them
 * notice the error -- it silently turned a batch that used to apply its good entries into one that
 * applied nothing. The endpoint now applies what it can and names what it dropped.
 *
 * These tests cover the partition itself. The 404-versus-200 branch that consumes it lives in
 * HttpSession::processFlowBatch and needs a TopologyAndFlowMonitor, which the routing test harness
 * passes as nullptr, so that branch is covered by the L2 contract case batch_flow_entries__mixed
 * against a running kernel rather than here.
 */

#include "ndt_core/routing_management/FlowJob.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace
{

FlowJob job(uint64_t dpid, int priority = 1)
{
    FlowJob j{};
    j.dpid = dpid;
    j.op = FlowOp::Install;
    j.priority = priority;
    j.match = nlohmann::json{{"eth_type", 2048}};
    j.actions = nlohmann::json::array({{{"type", "OUTPUT"}, {"port", 1}}});
    return j;
}

/// Known switches are 1..10, mirroring the ten-switch testbed topology.
auto knownIsOneToTen()
{
    return [](uint64_t dpid) { return dpid >= 1 && dpid <= 10; };
}

} // namespace

TEST(FlowBatchPartitionTest, ABatchOfKnownDpidsIsAcceptedWhole)
{
    std::vector<FlowJob> jobs{job(1), job(5), job(10)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    EXPECT_EQ(out.accepted.size(), 3u);
    EXPECT_EQ(out.rejectedEntries, 0u);
    EXPECT_TRUE(out.unknownDpids.empty());
}

TEST(FlowBatchPartitionTest, AnUnknownDpidIsDroppedAndTheRestSurvive)
{
    // The behaviour the whole change is about: one bad entry must not take the good ones with it.
    std::vector<FlowJob> jobs{job(1), job(999999999999ULL), job(3)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    ASSERT_EQ(out.accepted.size(), 2u);
    EXPECT_EQ(out.accepted[0].dpid, 1u);
    EXPECT_EQ(out.accepted[1].dpid, 3u);
    EXPECT_EQ(out.rejectedEntries, 1u);
    ASSERT_EQ(out.unknownDpids.size(), 1u);
    EXPECT_EQ(out.unknownDpids[0], 999999999999ULL);
}

TEST(FlowBatchPartitionTest, ABatchWhereNothingIsKnownAcceptsNothing)
{
    // Distinguished from the mixed case by the caller: accepted.empty() with rejectedEntries > 0 is
    // the only shape that still answers 404, because 200 with accepted == 0 would tell a caller
    // that reads only the status code that its request was fine.
    std::vector<FlowJob> jobs{job(777), job(888)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    EXPECT_TRUE(out.accepted.empty());
    EXPECT_EQ(out.rejectedEntries, 2u);
    EXPECT_EQ(out.unknownDpids.size(), 2u);
}

TEST(FlowBatchPartitionTest, EntriesAreCountedButDpidsAreDeduplicated)
{
    // Forty entries naming one absent switch is one thing to fix and forty things to re-send, so
    // the entry count and the dpid list are deliberately different numbers.
    std::vector<FlowJob> jobs{job(1), job(500), job(500), job(500), job(2)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    EXPECT_EQ(out.accepted.size(), 2u);
    EXPECT_EQ(out.rejectedEntries, 3u);
    ASSERT_EQ(out.unknownDpids.size(), 1u);
    EXPECT_EQ(out.unknownDpids[0], 500u);
}

TEST(FlowBatchPartitionTest, UnknownDpidsAreReportedInAscendingOrder)
{
    std::vector<FlowJob> jobs{job(900), job(100), job(500)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    ASSERT_EQ(out.unknownDpids.size(), 3u);
    EXPECT_EQ(out.unknownDpids[0], 100u);
    EXPECT_EQ(out.unknownDpids[1], 500u);
    EXPECT_EQ(out.unknownDpids[2], 900u);
}

TEST(FlowBatchPartitionTest, AcceptedEntriesKeepTheirRequestedOrder)
{
    // The dispatcher applies a modify after the install it supersedes only if the order survives,
    // so a partition that reorders would silently change which rule wins.
    std::vector<FlowJob> jobs{job(4, 10), job(4, 20), job(4, 30)};

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    ASSERT_EQ(out.accepted.size(), 3u);
    EXPECT_EQ(out.accepted[0].priority, 10);
    EXPECT_EQ(out.accepted[1].priority, 20);
    EXPECT_EQ(out.accepted[2].priority, 30);
}

TEST(FlowBatchPartitionTest, AnEmptyBatchIsNotAnError)
{
    // Reaches the 200 path with accepted == 0 and no rejections: a caller that sent nothing is not
    // told a switch is missing.
    const auto out = partitionFlowBatchByKnownDpid({}, knownIsOneToTen());

    EXPECT_TRUE(out.accepted.empty());
    EXPECT_EQ(out.rejectedEntries, 0u);
    EXPECT_TRUE(out.unknownDpids.empty());
}

TEST(FlowBatchPartitionTest, ThePayloadOfAnAcceptedEntrySurvivesTheMove)
{
    // The accepted jobs are moved out and then enqueued; a partition that copied only the dpid
    // would enqueue empty rules, and every assertion above would still pass.
    std::vector<FlowJob> jobs{job(6, 42)};
    jobs[0].match = nlohmann::json{{"eth_type", 2048}, {"ipv4_dst", "10.9.9.9"}};
    jobs[0].idleTimeout = 17;

    const auto out = partitionFlowBatchByKnownDpid(std::move(jobs), knownIsOneToTen());

    ASSERT_EQ(out.accepted.size(), 1u);
    EXPECT_EQ(out.accepted[0].match.value("ipv4_dst", std::string{}), "10.9.9.9");
    EXPECT_EQ(out.accepted[0].idleTimeout, 17);
    EXPECT_EQ(out.accepted[0].priority, 42);
    EXPECT_EQ(out.accepted[0].op, FlowOp::Install);
}

// --- describeFlowEntryShapeProblem: the synchronous half of the admission decision -------------
//
// [Co-developed with claude code -- Adam]
// The partition above answers "is this switch here". This answers the question that comes before
// it: "could this entry become a rule at all". Both are knowable on the HTTP thread; neither
// needs the switch. `{"dpid": 1}` used to pass both and be answered 200 "queued", because
// makeInstallJob reads every field but dpid with value(..., default) -- so a body with a typo in
// it produced a job with an empty match and empty actions, which the proxy then refused with the
// refusal visible only in the kernel log.
//
// The interesting cases are the ones that must stay LEGAL. An empty action list is a drop rule
// and Ryu's own table-miss entry is exactly that, so the check is presence and not emptiness.

namespace
{
nlohmann::json entryWith(std::initializer_list<std::pair<const std::string, nlohmann::json>> kv)
{
    return nlohmann::json(nlohmann::json::object_t(kv.begin(), kv.end()));
}
} // namespace

TEST(FlowEntryShapeTest, TheBodyThatStartedThisIsRejected)
{
    // {"dpid": 1} -- no actions. Answered 200 "queued" before, then refused southbound.
    const auto why = describeFlowEntryShapeProblem(entryWith({{"dpid", 1}}), FlowOp::Install);
    EXPECT_NE(why.find("actions"), std::string::npos) << why;
}

TEST(FlowEntryShapeTest, AnExplicitlyEmptyActionListIsADropRuleAndStaysLegal)
{
    // Ryu's table-miss rule is literally "actions": []. Rejecting it would break the one entry
    // every OVS switch carries -- and it is the same rule whose empty vector once crashed the
    // Classifier, so it is not hypothetical here.
    EXPECT_EQ("",
              describeFlowEntryShapeProblem(
                  entryWith({{"dpid", 1}, {"actions", nlohmann::json::array()}}), FlowOp::Install));
}

TEST(FlowEntryShapeTest, AbsentMatchAndPriorityAreAcceptedBecauseTheyMeanSomething)
{
    // No match is match-all (what a table-miss needs); no priority is 0, which both the
    // dispatcher and the table cache agree on since ad49347. Neither inverts the rule's meaning.
    EXPECT_EQ("",
              describeFlowEntryShapeProblem(
                  entryWith({{"dpid", 7},
                             {"actions", nlohmann::json::array({{{"type", "OUTPUT"}, {"port", 2}}})}}),
                  FlowOp::Install));
}

TEST(FlowEntryShapeTest, DeleteNeedsOnlyADpid)
{
    // "delete everything on this switch" is a real operation, and actions mean nothing here.
    EXPECT_EQ("", describeFlowEntryShapeProblem(entryWith({{"dpid", 3}}), FlowOp::Delete));
}

TEST(FlowEntryShapeTest, ModifyIsHeldToTheSameBarAsInstall)
{
    const auto why = describeFlowEntryShapeProblem(entryWith({{"dpid", 3}}), FlowOp::Modify);
    EXPECT_NE(why.find("actions"), std::string::npos) << why;
}

TEST(FlowEntryShapeTest, AMissingDpidIsNamedRatherThanThrown)
{
    // Reachable before this check too -- makeInstallJob's .at("dpid") throws and the catch
    // answers 400 -- but as the generic "Bad entry". Naming the field is the point.
    const auto why = describeFlowEntryShapeProblem(
        entryWith({{"actions", nlohmann::json::array()}}), FlowOp::Install);
    EXPECT_NE(why.find("dpid"), std::string::npos) << why;
}

TEST(FlowEntryShapeTest, ADpidThatIsNotANonNegativeIntegerIsRejected)
{
    // A string dpid would throw out of .at("dpid").get<uint64_t>() otherwise, and a negative one
    // would convert to a huge unsigned that silently misses the topology lookup.
    //
    // The first version of this check was is_number_unsigned(), which these tests failed: the
    // JSON *parser* stores a non-negative literal as number_unsigned, but a json built in C++
    // from an int literal holds number_integer, so the check passed over the wire and rejected
    // the same dpid from any in-process caller. Kept as a case because the two storages are
    // invisible at the call site.
    EXPECT_NE(describeFlowEntryShapeProblem(entryWith({{"dpid", "0x1"}, {"actions", nlohmann::json::array()}}),
                                            FlowOp::Install)
                  .find("dpid"),
              std::string::npos);
    EXPECT_NE(describeFlowEntryShapeProblem(entryWith({{"dpid", -1}, {"actions", nlohmann::json::array()}}),
                                            FlowOp::Install)
                  .find("dpid"),
              std::string::npos);
}

TEST(FlowEntryShapeTest, ANonObjectEntryIsRejectedBeforeAnyFieldLookup)
{
    EXPECT_NE(describeFlowEntryShapeProblem(nlohmann::json::array({1, 2}), FlowOp::Install), "");
    EXPECT_NE(describeFlowEntryShapeProblem(nlohmann::json("dpid=1"), FlowOp::Install), "");
}

TEST(FlowEntryShapeTest, AWellFormedEntryReportsNoProblem)
{
    EXPECT_EQ("",
              describeFlowEntryShapeProblem(
                  entryWith({{"dpid", 106225808380928ULL},
                             {"priority", 99},
                             {"match", {{"eth_type", 2048}, {"ipv4_dst", "10.0.0.2"}}},
                             {"actions", nlohmann::json::array({{{"type", "OUTPUT"}, {"port", 1}}})}}),
                  FlowOp::Install));
}

// --- doc/FIXED-ISSUES.md C-7: deletes the P4 proxy refuses, answered before the queue ----------
//
// [Co-developed with claude code -- Adam]
// The proxy refuses a strict delete that names a priority against a destination-only match (501,
// ipv4_lpm has no priority column), and the kernel used to queue it first and answer 200
// "queued". The predicate below has to refuse exactly what the proxy refuses -- no more, or a
// delete the proxy would honour is lost; no less, or the 200 comes back.

namespace
{

nlohmann::json deleteEntry(nlohmann::json priority, nlohmann::json match)
{
    nlohmann::json e{{"dpid", 1}, {"match", std::move(match)}};
    if (!priority.is_null())
    {
        e["priority"] = std::move(priority);
    }
    return e;
}

const nlohmann::json kDestOnly{{"eth_type", 2048}, {"ipv4_dst", "10.0.0.2"}};

} // namespace

TEST(P4PriorityDeleteTest, ANamedPriorityOnADestinationOnlyMatchIsRefused)
{
    EXPECT_TRUE(isPriorityDeleteP4CannotHonour(deleteEntry(100, kDestOnly)));
    EXPECT_TRUE(isPriorityDeleteP4CannotHonour(deleteEntry(1, kDestOnly)));
    EXPECT_TRUE(isPriorityDeleteP4CannotHonour(deleteEntry(10, {{"nw_dst", "10.0.0.2"}})));
}

TEST(P4PriorityDeleteTest, TheThreeNotANameValuesAreLeftAloneAsTheProxyDoes)
{
    // slot_priority.named_priority: absent, -1 and 0 name no entry, and the proxy honours those
    // as the non-strict route. Refusing them would refuse every delete the apps send.
    EXPECT_FALSE(isPriorityDeleteP4CannotHonour(deleteEntry(nullptr, kDestOnly)));
    EXPECT_FALSE(isPriorityDeleteP4CannotHonour(deleteEntry(-1, kDestOnly)));
    EXPECT_FALSE(isPriorityDeleteP4CannotHonour(deleteEntry(0, kDestOnly)));
    EXPECT_FALSE(isPriorityDeleteP4CannotHonour(deleteEntry(-7, kDestOnly)));
}

TEST(P4PriorityDeleteTest, AFiveTupleMatchIsHonouredOnP4AndNotRefused)
{
    // flow_5tuple has a priority column; the proxy honours these. Every spelling it maps.
    for (const char* field : kP4FiveTupleOnlyMatchFields)
    {
        auto match = kDestOnly;
        match[field] = 80;
        EXPECT_FALSE(isPriorityDeleteP4CannotHonour(deleteEntry(100, match))) << field;
    }
}

TEST(P4PriorityDeleteTest, AMissingOrNonObjectMatchIsRefusedAsTheProxyRefusesIt)
{
    // needs_five_tuple(non-dict) is False on the proxy, so its refusal fires.
    EXPECT_TRUE(isPriorityDeleteP4CannotHonour(nlohmann::json{{"dpid", 1}, {"priority", 5}}));
    EXPECT_TRUE(isPriorityDeleteP4CannotHonour(deleteEntry(5, nlohmann::json::array())));
}

// [Co-developed with claude code -- Adam]
// A priority is an OpenFlow priority: an integer from 0 to 65535. Anything else used to be taken
// by makeInstallJob/makeDeleteJob's `value("priority", ...)` -- nlohmann converts `true` to 1 and
// truncates 1.5 -- or wrapped (2^32 into an int), and was queued as some other priority. The shape
// check, which runs before any job is built, now refuses it; the endpoint tests in
// test_HttpSessionRouting.cpp drive the same values through processFlowBatch.
TEST(FlowEntryShapeTest, APriorityThatIsNotAnIntegerFrom0To65535IsRefused)
{
    for (const auto op : {FlowOp::Install, FlowOp::Modify, FlowOp::Delete})
    {
        for (const nlohmann::json& bad :
             {nlohmann::json(true), nlohmann::json(false), nlohmann::json(1.5),
              nlohmann::json(100.0), nlohmann::json("100"), nlohmann::json(-1),
              nlohmann::json(65536), nlohmann::json(4294967296LL), nlohmann::json(nullptr),
              nlohmann::json::array({1})})
        {
            auto e = entryWith({{"dpid", 1}, {"priority", bad}, {"actions", nlohmann::json::array()}});
            EXPECT_NE(describeFlowEntryShapeProblem(e, op), "")
                << "priority " << bad.dump() << " was accepted";
        }
    }
}

TEST(FlowEntryShapeTest, APriorityFrom0To65535OrNoneAtAllIsAccepted)
{
    for (const auto op : {FlowOp::Install, FlowOp::Modify, FlowOp::Delete})
    {
        for (const nlohmann::json& good : {nlohmann::json(0), nlohmann::json(65535),
                                           nlohmann::json(10), nlohmann::json(50000u)})
        {
            auto e = entryWith({{"dpid", 1}, {"priority", good}, {"actions", nlohmann::json::array()}});
            EXPECT_EQ(describeFlowEntryShapeProblem(e, op), "") << good.dump();
        }
        EXPECT_EQ(describeFlowEntryShapeProblem(
                      entryWith({{"dpid", 1}, {"actions", nlohmann::json::array()}}), op),
                  "");
    }
}

TEST(P4PriorityDeleteTest, OnlyBmv2DpidsAreRefusedAndTheRestKeepTheirOrder)
{
    const auto dels = nlohmann::json::array({
        nlohmann::json{{"dpid", 1}, {"priority", 100}, {"match", kDestOnly}},   // bmv2: refused
        nlohmann::json{{"dpid", 2}, {"priority", 100}, {"match", kDestOnly}},   // OVS: kept
        nlohmann::json{{"dpid", 1}, {"match", kDestOnly}},                      // non-strict: kept
        nlohmann::json{{"dpid", 1}, {"priority", 7}, {"match", kDestOnly}},     // bmv2: refused
    });
    const auto out =
        refusePriorityDeletesP4CannotHonour(dels, [](uint64_t dpid) { return dpid == 1; });

    ASSERT_EQ(out.refused.size(), 2u);
    EXPECT_EQ(out.refused[0].at("index"), 0);
    EXPECT_EQ(out.refused[0].at("requested_priority"), 100);
    EXPECT_EQ(out.refused[1].at("index"), 3);
    EXPECT_EQ(out.refused[1].at("dpid"), 1);
    ASSERT_EQ(out.admitted.size(), 2u);
    EXPECT_EQ(out.admitted[0].at("dpid"), 2);
    EXPECT_EQ(out.admitted[1], dels[2]);
}

// [Co-developed with claude code -- Adam]
// refusePriorityDeletesP4CannotHonour is a public inline function. processFlowBatch only calls it
// after the shape check, but nothing stops another caller from handing it raw entries -- and it used
// to read `dpid` and `priority` through nlohmann's const operator[], which asserts (aborts the
// process) on a missing key instead of throwing. These pin that an entry missing either key is
// admitted untouched, left for the shape check to refuse.
TEST(P4PriorityDeleteTest, ADeleteWithoutAPriorityIsAdmittedUntouched)
{
    const auto dels = nlohmann::json::array({nlohmann::json{{"dpid", 1}, {"match", kDestOnly}}});
    const auto out = refusePriorityDeletesP4CannotHonour(dels, [](uint64_t) { return true; });
    EXPECT_TRUE(out.refused.empty());
    ASSERT_EQ(out.admitted.size(), 1u);
    EXPECT_EQ(out.admitted[0], dels[0]);
}

TEST(P4PriorityDeleteTest, ADeleteWithoutADpidIsAdmittedRatherThanReadPastItsKeys)
{
    const auto dels =
        nlohmann::json::array({nlohmann::json{{"priority", 100}, {"match", kDestOnly}}});
    bool asked = false;
    const auto out = refusePriorityDeletesP4CannotHonour(dels, [&asked](uint64_t) {
        asked = true;
        return true;
    });
    EXPECT_FALSE(asked) << "the plane was asked about a dpid the entry does not have";
    EXPECT_TRUE(out.refused.empty());
    ASSERT_EQ(out.admitted.size(), 1u);
    EXPECT_EQ(out.admitted[0], dels[0]);
}

// --- OpenFlow keys the kernel does not send to the controller ---------------------------------
//
// [Co-developed with claude code -- Adam]
// Ryu's flow-mod reads cookie, cookie_mask, table_id, hard_timeout, flags, buffer_id, out_port and
// out_group from the body it is sent, and the kernel sends none of them; idle_timeout it sends on
// an install only. An entry carrying one was answered 200 "queued" and programmed as if the key
// were absent: an untagged permanent rule, a rule in table 0 instead of the table named, a delete
// that dropped its cookie or out_port filter and so removed more than it named. The shape check
// now refuses such a key, unless its value is the one the controller uses anyway.
//
// The cases below are the tests' own list, written out here rather than read from the kernel's
// table, so that they compile against a tree without the check and a key dropped from that table
// is a test that goes red rather than one that quietly disappears.

namespace
{

struct UnsentKeyCase
{
    const char* key;
    nlohmann::json value; ///< a value the controller acts on and the kernel would not send
    bool onInstall;       ///< refused on an install too, not only on modify and delete
    const char* name = nullptr; ///< the case's name when the key alone does not tell it apart
};

nlohmann::json
unsentKeyEntry(FlowOp op)
{
    nlohmann::json e{{"dpid", 1},
                     {"priority", 10},
                     {"match", {{"eth_type", 2048}, {"ipv4_dst", "10.0.0.2"}}}};
    if (op != FlowOp::Delete)
    {
        e["actions"] = nlohmann::json::array({{{"type", "OUTPUT"}, {"port", 1}}});
    }
    return e;
}

const char*
opName(FlowOp op)
{
    return op == FlowOp::Install ? "install" : op == FlowOp::Modify ? "modify" : "delete";
}

class FlowEntryUnsentKeyTest : public ::testing::TestWithParam<UnsentKeyCase>
{
};

} // namespace

TEST_P(FlowEntryUnsentKeyTest, AKeyTheKernelDoesNotSendIsRefusedOnEveryOp)
{
    const auto& c = GetParam();
    std::vector<FlowOp> ops{FlowOp::Modify, FlowOp::Delete};
    if (c.onInstall)
    {
        ops.push_back(FlowOp::Install);
    }
    for (const auto op : ops)
    {
        auto e = unsentKeyEntry(op);
        e[c.key] = c.value;
        const auto why = describeFlowEntryShapeProblem(e, op);
        EXPECT_NE(why.find(std::string("\"") + c.key + "\""), std::string::npos)
            << opName(op) << " with " << c.key << " " << c.value.dump() << ": "
            << (why.empty() ? std::string("accepted, so the value would be lost") : why);
    }
}

INSTANTIATE_TEST_SUITE_P(
    EveryUnsentKey,
    FlowEntryUnsentKeyTest,
    ::testing::Values(UnsentKeyCase{"cookie", 7, true},
                      UnsentKeyCase{"cookie_mask", 1, true},
                      UnsentKeyCase{"table_id", 1, true},
                      UnsentKeyCase{"hard_timeout", 30, true},
                      UnsentKeyCase{"flags", 1, true},
                      UnsentKeyCase{"buffer_id", 1, true},
                      UnsentKeyCase{"out_port", 2, true},
                      UnsentKeyCase{"out_group", 1, true},
                      UnsentKeyCase{"idle_timeout", 30, false},
                      // Exact 64-bit comparison: neither wraps to OFPP_ANY's 32 bits.
                      UnsentKeyCase{"out_port", -1, true, "out_port_minus_1"},
                      UnsentKeyCase{"out_port", 8589934591LL, true, "out_port_8589934591"}),
    [](const ::testing::TestParamInfo<UnsentKeyCase>& info) {
        return std::string(info.param.name ? info.param.name : info.param.key);
    });

TEST(FlowEntryShapeTest, TheControllersOwnDefaultIsAcceptedBecauseNothingIsLost)
{
    // A caller that echoes a read-back row (cookie 0, table_id 0, ...) loses nothing by it: the
    // controller uses these values when the key is absent. Each value is tried both as a json
    // built in C++ (number_integer) and as the parser stores it (number_unsigned), the two
    // storages the dpid check once told apart by mistake.
    const std::pair<const char*, std::uint64_t> defaults[] = {
        {"cookie", 0},           {"cookie_mask", 0},          {"table_id", 0},
        {"hard_timeout", 0},     {"flags", 0},                {"buffer_id", 4294967295u},
        {"out_port", 4294967295u}, {"out_group", 4294967295u}, {"idle_timeout", 0}};
    for (const auto op : {FlowOp::Install, FlowOp::Modify, FlowOp::Delete})
    {
        auto all = unsentKeyEntry(op);
        for (const auto& [key, value] : defaults)
        {
            for (const auto& v : {nlohmann::json(static_cast<std::int64_t>(value)),
                                  nlohmann::json::parse(std::to_string(value))})
            {
                auto e = unsentKeyEntry(op);
                e[key] = v;
                EXPECT_EQ(describeFlowEntryShapeProblem(e, op), "")
                    << opName(op) << " with " << key << " " << v.dump();
            }
            all[key] = value;
        }
        EXPECT_EQ(describeFlowEntryShapeProblem(all, op), "") << opName(op) << " " << all.dump();
    }
}

TEST(FlowEntryShapeTest, ADefaultSpelledAsSomethingElseIsStillRefused)
{
    // Ryu would read "0" or 0.0 as 0, but the kernel's own table view reads table_id as an
    // integer after the entry is queued, and a string or a null there threw: the reply became an
    // error for an entry already on its way to the switch. Only a JSON integer is the default.
    const std::pair<const char*, nlohmann::json> spelled[] = {
        {"table_id", nlohmann::json("0")},
        {"table_id", nlohmann::json(nullptr)},
        {"table_id", nlohmann::json(0.0)},
        {"cookie", nlohmann::json(false)},
        {"out_port", nlohmann::json(4294967295.0)}};
    for (const auto op : {FlowOp::Install, FlowOp::Modify, FlowOp::Delete})
    {
        for (const auto& [key, value] : spelled)
        {
            auto e = unsentKeyEntry(op);
            e[key] = value;
            const auto why = describeFlowEntryShapeProblem(e, op);
            EXPECT_NE(why.find(std::string("\"") + key + "\""), std::string::npos)
                << opName(op) << " with " << key << " " << value.dump() << ": "
                << (why.empty() ? std::string("accepted") : why);
        }
    }
}

TEST(FlowEntryShapeTest, IdleTimeoutIsNotRefusedOnAnInstall)
{
    // The one key of the nine that the kernel does send, and only on an install. That it then
    // reaches the southbound is UnsentFlowKeyEndpointTest.IdleTimeoutStillTravelsOnAnInstall.
    for (const auto& v : {nlohmann::json(30), nlohmann::json(0), nlohmann::json::parse("300")})
    {
        auto e = unsentKeyEntry(FlowOp::Install);
        e["idle_timeout"] = v;
        EXPECT_EQ(describeFlowEntryShapeProblem(e, FlowOp::Install), "") << v.dump();
    }
}

// [Co-developed with claude code -- Adam]
// The refusal's text has to be true on every op. It once said "the rule gets cookie 0", which
// describes an install: a delete changes no rule's cookie, and a modify leaves it as it was. What
// holds on every op is what the controller puts in the flow-mod when the key is absent.
TEST(FlowEntryShapeTest, EveryRefusalSaysWhatTheControllerUsesInstead)
{
    const std::pair<const char*, nlohmann::json> refused[] = {
        {"cookie", 7},   {"cookie_mask", 1}, {"table_id", 1}, {"hard_timeout", 30},
        {"flags", 1},    {"buffer_id", 1},   {"out_port", 2}, {"out_group", 1},
        {"idle_timeout", 30}};
    for (const auto op : {FlowOp::Install, FlowOp::Modify, FlowOp::Delete})
    {
        for (const auto& [key, value] : refused)
        {
            if (op == FlowOp::Install && std::string(key) == "idle_timeout")
            {
                continue;
            }
            auto e = unsentKeyEntry(op);
            e[key] = value;
            const auto why = describeFlowEntryShapeProblem(e, op);
            EXPECT_NE(why.find(std::string("(the controller uses ") + key + " "), std::string::npos)
                << opName(op) << " with " << key << ": " << why;
        }
    }
}

TEST(FlowEntryShapeTest, TheIdleTimeoutRefusalSaysItIsSentOnAnInstallOnly)
{
    for (const auto op : {FlowOp::Modify, FlowOp::Delete})
    {
        auto e = unsentKeyEntry(op);
        e["idle_timeout"] = 30;
        EXPECT_EQ(describeFlowEntryShapeProblem(e, op),
                  "\"idle_timeout\" is 30, but the kernel does not send idle_timeout to the "
                  "controller on a modify or a delete (the controller uses idle_timeout 0); omit "
                  "it, or send the integer 0")
            << opName(op);
    }
}

TEST(FlowEntryShapeTest, AFullReadBackRowIsTakenOnEveryOp)
{
    // A row as the controller's flow stats return it, echoed back: the nine keys at the values
    // the controller uses anyway, and the counters it reports but does not read from a flow-mod.
    // Nothing in it is lost, so nothing in it is refused.
    for (const auto op : {FlowOp::Install, FlowOp::Modify, FlowOp::Delete})
    {
        auto row = unsentKeyEntry(op);
        row["cookie"] = 0;
        row["cookie_mask"] = 0;
        row["table_id"] = 0;
        row["hard_timeout"] = 0;
        row["flags"] = 0;
        row["buffer_id"] = 4294967295u;
        row["out_port"] = 4294967295u;
        row["out_group"] = 4294967295u;
        row["idle_timeout"] = 0;
        row["byte_count"] = 238;
        row["packet_count"] = 3;
        row["duration_sec"] = 12;
        row["duration_nsec"] = 345000000;
        row["length"] = 96;
        EXPECT_EQ(describeFlowEntryShapeProblem(nlohmann::json::parse(row.dump()), op), "")
            << opName(op) << " " << row.dump();
    }
}
