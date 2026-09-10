// [Co-developed with claude code -- Adam]
//
// Tests for the HTTP routing strategies: the requests they build, and -- new in Phase 2 --
// whether they report failure at all.
//
// Replaces test_OpenFlowRoutingStrategy.cpp and test_P4RoutingStrategy.cpp, which were
// themselves byte-identical apart from the class name and the port, and which asserted that
// the P4 strategy emitted OpenFlow-shaped requests to port 8081. That was true, because the
// P4 strategy was a copy of the OpenFlow one -- so those tests pinned the duplication in
// place as if it were intended behaviour.

#include <gtest/gtest.h>

#include "ndt_core/routing_management/HttpRoutingStrategyBase.hpp"
#include "ndt_core/routing_management/OpResult.hpp"
#include "ndt_core/routing_management/OpenFlowRoutingStrategy.hpp"
#include "ndt_core/routing_management/P4RoutingStrategy.hpp"
#include "utils/Logger.hpp"

#include <algorithm>
#include <nlohmann/json.hpp>
#include <string>
#include <vector>

using json = nlohmann::json;

namespace
{

/// Records the commands a strategy builds and returns a canned reply, so the request shape
/// and the response handling can both be asserted without a controller.
///
/// [Co-developed with claude code -- Adam]
/// The seam is now executeArgv(), because post() no longer builds a shell command line
/// (doc/KNOWN-ISSUES.md B-2b). `commands` keeps holding a flat string so the existing request-shape
/// assertions read the same, but note what that string now is: a *rendering* of the argument
/// vector, not a command line. `argvs` holds the real thing, and the injection tests below assert
/// on that -- because the whole property being pinned is that arguments stay separate, and a joined
/// string is exactly the representation that loses it.
template <typename Strategy>
class RecordingStrategy : public Strategy
{
  public:
    explicit RecordingStrategy(const std::string& apiUrl)
        : Strategy(apiUrl)
    {
    }

    std::vector<std::string> commands;
    std::vector<std::vector<std::string>> argvs;

    /// What executeArgv returns as stdout. curl is invoked with -w '\n%{http_code}', so the reply
    /// is the body followed by a newline and the status; "000" means nothing answered.
    std::string cannedReply = "\n200";

    /// Whether curl is pretended to have run at all. False stands for fork failing or curl being
    /// absent -- the cases where the request never left the host and no component may be blamed.
    bool cannedRan = true;

    /// Wait status reported alongside cannedRan. 127 << 8 is "command not found".
    int cannedStatus = 0;

    const std::string& lastCommand() const
    {
        static const std::string empty;
        return commands.empty() ? empty : commands.back();
    }

    const std::vector<std::string>& lastArgv() const
    {
        static const std::vector<std::string> empty;
        return argvs.empty() ? empty : argvs.back();
    }

  protected:
    utils::CommandOutcome executeArgv(const std::vector<std::string>& argv) override
    {
        argvs.push_back(argv);
        commands.push_back(utils::describeArgv(argv));
        return utils::CommandOutcome{cannedRan ? cannedReply : std::string(),
                                     cannedRan,
                                     cannedStatus};
    }
};

using RecordingOpenFlow = RecordingStrategy<OpenFlowRoutingStrategy>;
using RecordingP4 = RecordingStrategy<P4RoutingStrategy>;

json sampleMatch()
{
    return json{{"eth_type", 2048}, {"ipv4_dst", "10.0.0.3"}};
}

json sampleActions()
{
    return json::array({{{"type", "OUTPUT"}, {"port", 24}}});
}

class RoutingStrategyFixture : public ::testing::Test
{
  protected:
    // Logger::init must happen in this suite, not be inherited from another one -- see the
    // note in test_SwitchKindDispatch.cpp. It is idempotent.
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

} // namespace

// =====================================================================================
// Request construction
// =====================================================================================

TEST_F(RoutingStrategyFixture, InstallTargetsTheRyuAddRoute)
{
    RecordingOpenFlow s("localhost:8080");
    ASSERT_TRUE(s.installAnEntry(1, 99, sampleMatch(), sampleActions(), 0).ok);

    EXPECT_NE(s.lastCommand().find("http://localhost:8080/stats/flowentry/add"),
              std::string::npos)
        << s.lastCommand();
    EXPECT_NE(s.lastCommand().find("-X POST"), std::string::npos);
    EXPECT_NE(s.lastCommand().find("\"ipv4_dst\":\"10.0.0.3\""), std::string::npos);
}

TEST_F(RoutingStrategyFixture, EveryRequestAsksForTheStatusCodeAndBoundsItsTime)
{
    // Without -w the strategy cannot tell success from failure, and without --max-time a hung
    // controller wedges a FlowDispatcher worker. Both were missing before Phase 2.
    RecordingOpenFlow s("localhost:8080");
    ASSERT_TRUE(s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0).ok);

    EXPECT_NE(s.lastCommand().find("%{http_code}"), std::string::npos) << s.lastCommand();
    EXPECT_NE(s.lastCommand().find("--max-time"), std::string::npos) << s.lastCommand();
}

TEST_F(RoutingStrategyFixture, DeleteWithoutPriorityUsesTheNonStrictRoute)
{
    // priority == -1 is the default everywhere in the kernel, so this is the common path.
    RecordingOpenFlow s("localhost:8080");
    ASSERT_TRUE(s.deleteAnEntry(1, sampleMatch(), -1).ok);

    EXPECT_NE(s.lastCommand().find("/stats/flowentry/delete"), std::string::npos);
    EXPECT_EQ(s.lastCommand().find("delete_strict"), std::string::npos)
        << "a priority-less delete must not use the strict route";
}

TEST_F(RoutingStrategyFixture, DeleteWithPriorityUsesTheStrictRoute)
{
    RecordingOpenFlow s("localhost:8080");
    ASSERT_TRUE(s.deleteAnEntry(1, sampleMatch(), 42).ok);

    EXPECT_NE(s.lastCommand().find("/stats/flowentry/delete_strict"), std::string::npos);
    EXPECT_NE(s.lastCommand().find("\"priority\":42"), std::string::npos);
}

// --- A-4e: a modify names one entry, and must be able to touch only that one.
//
// [Co-developed with claude code -- Adam]
// doc/KNOWN-ISSUES.md A-4e. modifyAnEntry was the one write verb no test round had ever called,
// which is how it kept a defect the delete two tests up does not have: it set "priority" in the
// body and posted the non-strict route, where OpenFlow does not compare priority at all.

TEST_F(RoutingStrategyFixture, ModifyWithPriorityUsesTheStrictRouteSoItCanOnlyHitThatEntry)
{
    // The measured harm: a modify naming priority 100 edited the router's priority-10 rule,
    // moved 32 MB onto the wrong port, and survived deleting the caller's own rule.
    RecordingOpenFlow s("localhost:8080");
    ASSERT_TRUE(s.modifyAnEntry(1, 100, sampleMatch(), sampleActions()).ok);

    EXPECT_NE(s.lastCommand().find("/stats/flowentry/modify_strict"), std::string::npos)
        << "the non-strict route ignores priority, so the entry named here is not the entry "
           "edited: "
        << s.lastCommand();
    EXPECT_NE(s.lastCommand().find("\"priority\":100"), std::string::npos) << s.lastCommand();
}

TEST_F(RoutingStrategyFixture, ModifyWithoutAPriorityStaysOnTheNonStrictRoute)
{
    // Symmetry with deleteAnEntry: -1 is "I am not naming an entry". Nothing in the kernel
    // produces it for a modify today, so this pins the sentinel rather than a live path -- and
    // pins that a priority-less modify does not acquire a priority on the way out.
    RecordingOpenFlow s("localhost:8080");
    ASSERT_TRUE(s.modifyAnEntry(1, -1, sampleMatch(), sampleActions()).ok);

    EXPECT_NE(s.lastCommand().find("/stats/flowentry/modify"), std::string::npos);
    EXPECT_EQ(s.lastCommand().find("modify_strict"), std::string::npos)
        << "a priority-less modify must not use the strict route";
    EXPECT_EQ(s.lastCommand().find("\"priority\""), std::string::npos)
        << "-1 is a sentinel, not a priority to send: " << s.lastCommand();
}

TEST_F(RoutingStrategyFixture, ModifyOnTheP4ProxyKeepsTheRouteTheProxyActuallyServes)
{
    // The proxy serves add/delete/delete_strict/modify and nothing else, and its modify reads
    // priority from the body itself. Posting modify_strict there is a 404 -- and an invisible
    // one, because the flow path answers 200 "queued" before the southbound request is made.
    // This test is the whole reason strictModifyPath() is virtual.
    RecordingP4 s("localhost:9090");
    ASSERT_TRUE(s.modifyAnEntry(1, 100, sampleMatch(), sampleActions()).ok);

    EXPECT_NE(s.lastCommand().find("/stats/flowentry/modify"), std::string::npos)
        << s.lastCommand();
    EXPECT_EQ(s.lastCommand().find("modify_strict"), std::string::npos)
        << "the P4 proxy has no modify_strict route; this 404s and nothing observes it: "
        << s.lastCommand();
    EXPECT_NE(s.lastCommand().find("\"priority\":100"), std::string::npos)
        << "the proxy identifies the entry by the priority in the body, so it still has to be "
           "sent: "
        << s.lastCommand();
}

TEST_F(RoutingStrategyFixture, ModifyAndDeleteAgreeOnWhatAPriorityMeans)
{
    // The defect was an asymmetry between two functions forty lines apart, so the property worth
    // pinning is the agreement itself rather than either route name. A future edit that "tidies"
    // one of them back to non-strict has to fail here.
    RecordingOpenFlow modify("localhost:8080");
    RecordingOpenFlow del("localhost:8080");
    ASSERT_TRUE(modify.modifyAnEntry(1, 7, sampleMatch(), sampleActions()).ok);
    ASSERT_TRUE(del.deleteAnEntry(1, sampleMatch(), 7).ok);

    EXPECT_NE(modify.lastCommand().find("_strict"), std::string::npos)
        << "delete treats a supplied priority as naming one entry; modify must too: "
        << modify.lastCommand();
    EXPECT_NE(del.lastCommand().find("_strict"), std::string::npos) << del.lastCommand();
}

TEST_F(RoutingStrategyFixture, IdleTimeoutIsOmittedForBothSentinels)
{
    // 0 is the declared default and -1 the historical "no timeout" sentinel; neither should
    // appear in the request.
    for (int sentinel : {0, -1})
    {
        RecordingOpenFlow s("localhost:8080");
        ASSERT_TRUE(s.installAnEntry(1, 1, sampleMatch(), sampleActions(), sentinel).ok);
        EXPECT_EQ(s.lastCommand().find("idle_timeout"), std::string::npos)
            << "sentinel " << sentinel << " leaked into the request";
    }

    RecordingOpenFlow s("localhost:8080");
    ASSERT_TRUE(s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 30).ok);
    EXPECT_NE(s.lastCommand().find("\"idle_timeout\":30"), std::string::npos);
}

TEST_F(RoutingStrategyFixture, P4StrategyTargetsTheProxyNotRyu)
{
    RecordingP4 s("localhost:8081");
    ASSERT_TRUE(s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0).ok);

    EXPECT_NE(s.lastCommand().find("http://localhost:8081/"), std::string::npos);
    EXPECT_EQ(s.lastCommand().find("8080"), std::string::npos);
}

// =====================================================================================
// Failure reporting -- the point of Phase 2
// =====================================================================================

TEST_F(RoutingStrategyFixture, ReportsFailureWhenNothingAnswers)
{
    // curl prints 000 for %{http_code} when it cannot connect. Previously the return value
    // was discarded entirely, so a dead controller looked exactly like a success.
    RecordingOpenFlow s("localhost:8080");
    s.cannedReply = "\n000";

    const OpResult r = s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);

    EXPECT_FALSE(r.ok);
    EXPECT_TRUE(r.noResponse());
    EXPECT_EQ(r.httpStatus, 0);
    EXPECT_NE(r.message.find("no response"), std::string::npos) << r.message;
    EXPECT_NE(r.message.find("Ryu controller"), std::string::npos)
        << "the message should name which control plane failed: " << r.message;
}

TEST_F(RoutingStrategyFixture, ReportsFailureOnHttpErrorStatus)
{
    for (const auto& [reply, expected] : std::vector<std::pair<std::string, int>>{
             {"{\"error\":\"bad dpid\"}\n400", 400},
             {"not found\n404", 404},
             {"boom\n500", 500}})
    {
        RecordingOpenFlow s("localhost:8080");
        s.cannedReply = reply;

        const OpResult r = s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);

        EXPECT_FALSE(r.ok) << reply;
        EXPECT_EQ(r.httpStatus, expected) << reply;
        EXPECT_FALSE(r.noResponse()) << "a real status is not the same as no response";
    }
}

TEST_F(RoutingStrategyFixture, TreatsAnErrorBodyInA200AsFailure)
{
    // The P4 proxy answers {"status":"error"} with HTTP 200 for a rejected rule, so a 2xx
    // alone is not proof of success.
    RecordingP4 s("localhost:8081");
    s.cannedReply = "{\"status\":\"error\",\"message\":\"Failed to add route\"}\n200";

    const OpResult r = s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);

    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.httpStatus, 200);
    EXPECT_NE(r.message.find("Failed to add route"), std::string::npos) << r.message;
}

TEST_F(RoutingStrategyFixture, AcceptsASuccessBodyAndANonJsonBody)
{
    RecordingP4 s("localhost:8081");

    s.cannedReply = "{\"status\":\"success\"}\n200";
    EXPECT_TRUE(s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0).ok);

    // Ryu's replies are not always JSON; that must not be mistaken for an error.
    s.cannedReply = "OK\n200";
    EXPECT_TRUE(s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0).ok);
}

TEST_F(RoutingStrategyFixture, HandlesOutputWithNoStatusLine)
{
    // If curl itself fails to run there is no trailing status at all.
    //
    // [Co-developed with claude code -- Adam]
    // This test used to end `EXPECT_TRUE(r.noResponse())`, and that expectation *was* the defect
    // in doc/KNOWN-ISSUES.md B-2b, written down and pinned: "curl never ran" was being recorded as
    // "the controller did not respond". Kept as a reminder that a test can hold a bug in place
    // while looking like coverage -- the assertion is now the opposite one.
    RecordingOpenFlow s("localhost:8080");
    s.cannedReply = "";

    const OpResult r = s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);
    EXPECT_FALSE(r.ok);
    EXPECT_FALSE(r.noResponse())
        << "no status line means curl did not run, which is not the controller failing to answer";
    EXPECT_EQ(r.httpStatus, 500) << "the fault is local, so it must not map to 502 Bad Gateway";
}

// =====================================================================================
// doc/KNOWN-ISSUES.md B-2b: a single quote must not break the request, and must not make
// the kernel accuse a component it never contacted.
//
// [Co-developed with claude code -- Adam]
// Round 4 measured that a quote in a match value and a genuinely dead controller produced the
// byte-identical verdict `no response from <component> at <url> within 5s`. Two properties have to
// hold for that to be over: the quote must be transported rather than interpreted, and the two
// causes must produce different verdicts. One test each.
// =====================================================================================

TEST_F(RoutingStrategyFixture, AQuoteInAMatchValueIsSentAsDataAndDoesNotBreakTheRequest)
{
    // The body is one argv element, so a quote -- or a whole shell command -- is just bytes in it.
    // This is the assertion that would have failed before the argv migration: the old code built
    // `-d '<body>'` for /bin/sh, where this value ends the quoting on its first character.
    RecordingOpenFlow s("localhost:8080");
    json match = sampleMatch();
    match["eth_dst"] = R"(aa'; touch /tmp/pwned; echo ')";

    const OpResult r = s.installAnEntry(1, 1, match, sampleActions(), 0);

    EXPECT_TRUE(r.ok) << "a quote in a match value is data, not a transport failure: " << r.message;

    // The payload travels in exactly one argument, immediately after -d. If it were ever split
    // across arguments, or a shell were reintroduced, that argument would stop being the body.
    const std::vector<std::string>& argv = s.lastArgv();
    const auto dashD = std::find(argv.begin(), argv.end(), "-d");
    ASSERT_NE(dashD, argv.end()) << "the request must still carry a body";
    ASSERT_NE(dashD + 1, argv.end()) << "-d must be followed by the body";
    const std::string& sentBody = *(dashD + 1);

    EXPECT_NE(sentBody.find(R"(aa'; touch /tmp/pwned; echo ')"), std::string::npos)
        << "the value must arrive intact, neither escaped nor stripped: " << sentBody;
    EXPECT_EQ(json::parse(sentBody)["match"]["eth_dst"].get<std::string>(),
              R"(aa'; touch /tmp/pwned; echo ')")
        << "round-trips as JSON, so the controller sees what the caller sent";

    // No element may be a shell invocation. This is the property, not the quoting.
    for (const std::string& arg : argv)
    {
        EXPECT_EQ(arg.find("sh -c"), std::string::npos) << "a shell is back in the path: " << arg;
    }
    EXPECT_EQ(argv.front(), "curl") << "argv[0] must be the program, not a shell";
}

TEST_F(RoutingStrategyFixture, ARequestThatNeverRanDoesNotAccuseTheController)
{
    // The honesty half. curl absent / fork failed: the controller was never contacted, so naming
    // it is a false accusation, and round 4 showed the message was indistinguishable from a real
    // outage. The two verdicts are compared against each other here rather than matched against
    // fixed strings, because "they differ" is the property that was broken.
    RecordingOpenFlow neverRan("localhost:8080");
    neverRan.cannedRan = false;
    neverRan.cannedStatus = 127 << 8;

    RecordingOpenFlow deadController("localhost:8080");
    deadController.cannedReply = "\n000";

    const OpResult notSent = neverRan.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);
    const OpResult unreachable =
        deadController.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);

    ASSERT_FALSE(notSent.ok);
    ASSERT_FALSE(unreachable.ok);

    EXPECT_NE(notSent.message, unreachable.message)
        << "the whole defect is that these two were the same sentence";
    EXPECT_NE(notSent.httpStatus, unreachable.httpStatus)
        << "and that a program could not tell them apart either";

    EXPECT_EQ(notSent.message.find("no response from"), std::string::npos)
        << "must not report an absent response from a component that was never asked: "
        << notSent.message;
    EXPECT_NE(notSent.message.find("curl"), std::string::npos)
        << "must name the local cause so an operator looks at this host: " << notSent.message;
    EXPECT_EQ(notSent.httpStatus, 500) << "our fault, not the gateway's";

    EXPECT_NE(unreachable.message.find("no response from"), std::string::npos)
        << unreachable.message;
    EXPECT_EQ(unreachable.httpStatus, 0) << "a real outage is still a 0/502";
}

// =====================================================================================
// P4 declares its limits instead of pretending
// =====================================================================================

TEST_F(RoutingStrategyFixture, P4RefusesGroupAndMeterEntriesWithoutSendingAnything)
{
    RecordingP4 s("localhost:8081");
    const json payload = json{{"dpid", 1}, {"group_id", 10}};

    const std::vector<OpResult> results = {
        s.installAGroupEntry(payload), s.deleteAGroupEntry(payload),
        s.modifyAGroupEntry(payload),  s.installAMeterEntry(payload),
        s.deleteAMeterEntry(payload),  s.modifyAMeterEntry(payload)};

    for (const auto& r : results)
    {
        EXPECT_FALSE(r.ok);
        EXPECT_EQ(r.httpStatus, 501) << "should report 'not implemented', not a transport error";
        EXPECT_NE(r.message.find("not supported"), std::string::npos) << r.message;
    }

    // Nothing was sent: the old version POSTed to proxy routes that do not exist and the
    // resulting 404s went unnoticed.
    EXPECT_TRUE(s.commands.empty())
        << "refused operations must not reach the network; got: " << s.lastCommand();
}

TEST_F(RoutingStrategyFixture, OpenFlowStillSupportsGroupAndMeterEntries)
{
    // The OVS/hardware path genuinely has these, so the refusal must be P4-specific.
    //
    // [Co-developed with claude code -- Adam] F-13 added an existence check before each of these
    // six, and this test still passes for a reason worth naming rather than leaving to be
    // rediscovered: RecordingStrategy answers every command with the same "\n200", so the check
    // gets an empty body, cannot read an answer out of it, and returns Unknown -- which forwards
    // the mod rather than refusing it. So what this pins is still "OpenFlow does not refuse
    // these", not "the guard is absent". The guard's own decisions are asserted in
    // tests/test_GroupMeterExistence.cpp, against a recorder that answers GET and POST separately.
    RecordingOpenFlow s("localhost:8080");
    const json payload = json{{"dpid", 1}, {"group_id", 10}};

    EXPECT_TRUE(s.installAGroupEntry(payload).ok);
    EXPECT_NE(s.lastCommand().find("/stats/groupentry/add"), std::string::npos);

    EXPECT_TRUE(s.installAMeterEntry(payload).ok);
    EXPECT_NE(s.lastCommand().find("/stats/meterentry/add"), std::string::npos);
}

TEST_F(RoutingStrategyFixture, StrategiesNameThemselvesForLogs)
{
    EXPECT_STREQ(OpenFlowRoutingStrategy("x").describe(), "Ryu controller");
    EXPECT_STREQ(P4RoutingStrategy("x").describe(), "P4 proxy agent");
}

// =====================================================================================
// W11 (#54): the refusal half of the plane's verdict
//
// [Co-developed with claude code -- Adam]
//
// C-4 made a plane's *acceptance* carry whether it is evidence of programming
// (OpResult::confirmsProgramming). W11 needs the other direction, because a refusal is the only
// switch-side answer the OVS plane never gives and the P4 plane routinely does: R6 K-4's delete
// of a match no switch held returns {"status":"error"} from the proxy, and that is the kernel
// knowing the switch does not hold the rule -- a fact `get_flow_dispatch_status` had no bucket
// for and reported as a success.
//
// These test the CARRIER: that post() attaches the bit on the paths where the far end answered
// and withholds it on the paths where it did not. What the bit is then used for is
// tests/test_DispatchOutcomeLog.cpp's; the two halves are separable and both have to hold.
// =====================================================================================

TEST_F(RoutingStrategyFixture, AProxyRefusalIsAVerdictAboutTheSwitch)
{
    // The proxy programs the table before replying and reports a per-entry refusal in the body,
    // so "no" from it means the entry is not there.
    RecordingP4 s("localhost:8081");
    s.cannedReply = "{\"status\":\"error\",\"message\":\"Failed to delete route\"}\n200";

    const OpResult r = s.deleteAnEntry(1, sampleMatch(), -1);

    EXPECT_FALSE(r.ok);
    EXPECT_TRUE(r.confirmsNotProgrammed)
        << "R6 K-4: this is the one plane that can tell the caller its delete removed nothing";
    EXPECT_FALSE(r.confirmsProgramming) << "the two bits are mutually exclusive by construction";
}

TEST_F(RoutingStrategyFixture, AProxyErrorStatusIsAlsoAVerdictAboutTheSwitch)
{
    // The 501 the proxy raises for a priority ipv4_lpm cannot honour, and the 400 for an
    // unsupported match. Both are raised BEFORE the write, so the entry is definitively absent.
    RecordingP4 s("localhost:8081");
    s.cannedReply = "{\"detail\":{\"error\":\"priority not honourable on this table\"}}\n501";

    const OpResult r = s.deleteAnEntry(1, sampleMatch(), 999);

    EXPECT_FALSE(r.ok);
    EXPECT_EQ(r.httpStatus, 501);
    EXPECT_TRUE(r.confirmsNotProgrammed);
}

TEST_F(RoutingStrategyFixture, ARyuRejectionIsNotAVerdictAboutTheSwitch)
{
    // The control that stops the bit from becoming "the operation failed". Ryu declining to build
    // a FlowMod is a control-plane fact; nothing on the OVS plane adjudicates, in either
    // direction, which is why the switch-side counter reads `unknown` there and not `rejected`.
    RecordingOpenFlow s("localhost:8080");
    s.cannedReply = "{\"error\":\"bad dpid\"}\n400";

    const OpResult r = s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);

    EXPECT_FALSE(r.ok) << "it did fail";
    EXPECT_FALSE(r.confirmsNotProgrammed)
        << "attributing this to a switch would name a component that was never consulted -- the "
           "misattribution OpResult::notSent exists to stop, pointed at the new counter";
}

TEST_F(RoutingStrategyFixture, AnUnansweredRequestIsNoVerdictOnEitherPlane)
{
    // Nothing answered, so there is nothing to adjudicate -- on the plane that otherwise would.
    RecordingP4 s("localhost:8081");
    s.cannedReply = "\n000";
    const OpResult unreachable = s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);
    EXPECT_TRUE(unreachable.noResponse());
    EXPECT_FALSE(unreachable.confirmsNotProgrammed);

    // And the case where the request never left this host at all.
    s.cannedRan = false;
    s.cannedStatus = 127 << 8;
    const OpResult notSent = s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);
    EXPECT_FALSE(notSent.ok);
    EXPECT_FALSE(notSent.confirmsNotProgrammed)
        << "curl never ran; blaming the switch here is the B-2b defect in a new field";
}
