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

#include <nlohmann/json.hpp>
#include <string>
#include <vector>

using json = nlohmann::json;

namespace
{

/// Records the commands a strategy builds and returns a canned reply, so the request shape
/// and the response handling can both be asserted without a controller.
template <typename Strategy>
class RecordingStrategy : public Strategy
{
  public:
    explicit RecordingStrategy(const std::string& apiUrl)
        : Strategy(apiUrl)
    {
    }

    std::vector<std::string> commands;

    /// What executeCommand returns. curl is invoked with -w '\n%{http_code}', so the reply
    /// is the body followed by a newline and the status; "000" means nothing answered.
    std::string cannedReply = "\n200";

    const std::string& lastCommand() const
    {
        static const std::string empty;
        return commands.empty() ? empty : commands.back();
    }

  protected:
    std::string executeCommand(const std::string& cmd) override
    {
        commands.push_back(cmd);
        return cannedReply;
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
    RecordingOpenFlow s("localhost:8080");
    s.cannedReply = "";

    const OpResult r = s.installAnEntry(1, 1, sampleMatch(), sampleActions(), 0);
    EXPECT_FALSE(r.ok);
    EXPECT_TRUE(r.noResponse());
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
