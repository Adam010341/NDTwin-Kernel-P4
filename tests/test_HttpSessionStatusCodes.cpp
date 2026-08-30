/**
 * Endpoints that answered the wrong HTTP status.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Two separate defects, both of the same shape -- the body said one thing and the status line
 * said another, and a status-code-only client believed the status line:
 *
 *  1. /ndt/release_lock answered 200 {"status":"released"} no matter what. LockManager::unlock
 *     was void and bare-returned on an unknown type; releasing a lock nobody held was a silent
 *     no-op; and an empty `catch (...)` around the body parse degraded a malformed request into
 *     releasing the DEFAULT lock type. An app that typoed its release got
 *     {"status":"released","type":"bogus"} with 200 and believed the lock was free, while the
 *     real lock stayed held until TTL expiry and blocked every other acquire with no error
 *     anywhere. The sibling *renew* handler already proved the intended contract: it returns
 *     bool and answers 412 for the same three inputs.
 *
 *  2. get_total_input_traffic_load_passing_a_switch and get_num_of_flows_passing_a_switch logged
 *     "dpid missing" and set an error body but never called res.result(), so the 200 that
 *     buildResponse initialises stood.
 *
 * Both success and failure paths are asserted. A guard that refuses everything passes every
 * refusal test, and for release_lock in particular the refusal is the easy half -- the
 * interesting assertion is that a genuinely held lock still releases with 200 and is genuinely
 * acquirable afterwards.
 *
 * T-7b (2026-08-30) finished (1) and brought renew_lock in beside it. Two things were left:
 * release_lock still fell back to the DEFAULT lock type when the body was *absent* rather than
 * merely unparseable, and renew_lock still had the empty `catch (...)` that release_lock had
 * lost, plus no endpoint tests at all. Both now go through LockManager::parseRequest, the seam
 * T-7 built for acquire_lock, so the three endpoints cannot drift apart again about what a
 * request means.
 *
 * Two assertions in this file were deliberately reversed by T-7b and say so at their own
 * definitions: an absent body is now refused rather than releasing the default lock, and an
 * unknown lock type is now 400 rather than 412. Every refusal case added since judges on lock
 * STATE as well as on the status line, because in the original defect the status line was
 * never the part that was wrong.
 */

#include <memory>
#include <shared_mutex>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/data_management/HistoricalDataManager.hpp"
#include "ndt_core/http/HttpSession.hpp"
#include "ndt_core/lock_management/LockManager.hpp"
#include "utils/Utils.hpp"

/**
 * @brief Drives HttpSession::buildResponse() with a real LockManager and HistoricalDataManager.
 *
 * Global scope to match `friend class HttpSessionStatusTestPeer`.
 */
class HttpSessionStatusTestPeer
{
  public:
    HttpSessionStatusTestPeer(std::shared_ptr<LockManager> lockManager,
                              std::shared_ptr<TopologyAndFlowMonitor> monitor,
                              std::shared_ptr<HistoricalDataManager> historical)
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                  std::move(monitor),
                                                  nullptr,        // EventBus
                                                  utils::MININET, // mode
                                                  nullptr,        // FlowLinkUsageCollector
                                                  nullptr,        // FlowRoutingManager
                                                  nullptr,        // DeviceConfig...PowerManager
                                                  nullptr,        // ApplicationManager
                                                  nullptr,        // SimulationRequestManager
                                                  nullptr,        // IntentTranslator
                                                  std::move(historical),
                                                  nullptr, // Controller
                                                  std::move(lockManager)))
    {
    }

    const http::response<http::string_body>&
    send(http::verb method, const std::string& target, const std::string& body = "")
    {
        m_session->m_req = {};
        m_session->m_req.version(11);
        m_session->m_req.method(method);
        m_session->m_req.target(target);
        m_session->m_req.body() = body;
        m_session->m_req.prepare_payload();

        m_response = m_session->buildResponse();
        return *m_response;
    }

  private:
    boost::asio::io_context m_ioc;
    std::shared_ptr<HttpSession> m_session;
    std::shared_ptr<http::response<http::string_body>> m_response;
};

namespace
{

class LockEndpointTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_locks = std::make_shared<LockManager>();
        m_graph = std::make_shared<Graph>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(m_graph,
                                                             std::make_shared<std::shared_mutex>(),
                                                             std::make_shared<EventBus>(),
                                                             utils::MININET);
        m_peer = std::make_unique<HttpSessionStatusTestPeer>(m_locks, m_monitor, nullptr);
    }

    std::shared_ptr<LockManager> m_locks;
    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::unique_ptr<HttpSessionStatusTestPeer> m_peer;
};

} // namespace

// --- /ndt/release_lock -------------------------------------------------------------------------

TEST_F(LockEndpointTest, ReleasingALockNobodyHoldsIsRefusedRatherThanReportedAsReleased)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/release_lock",
                                   R"({"type":"routing_lock"})");

    EXPECT_EQ(res.result_int(), 412u) << "body: " << res.body();
}

/**
 * T-7b changed this from 412 to 400, deliberately.
 *
 * [Co-developed with claude code -- Adam]
 * 412 was chosen when release and renew both answered 412 for all three of "expired", "not
 * held" and "invalid type" -- the value of matching the sibling handler outweighed the
 * conflation. T-7 then split that conflation on acquire_lock: a name that is not a lock is a
 * permanent client error (400, do not retry), while a lock that is merely not held right now
 * is a state (412, acquire and try again). Keeping 412 here would leave release as the one
 * endpoint that still answers the same number to a bug in the caller and to a race.
 */
TEST_F(LockEndpointTest, ReleasingAnUnknownLockTypeIsARequestErrorNotAStateError)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 30)) << "precondition";

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/release_lock",
                                   R"({"type":"no_such_lock_type_exists"})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_FALSE(m_locks->acquireLock("routing_lock", 30))
        << "an unknown lock name released routing_lock as a side effect";
}

TEST_F(LockEndpointTest, AMalformedBodyIsRejectedRatherThanReleasingTheDefaultLock)
{
    // The old empty catch(...) swallowed the parse error and fell through to the DEFAULT type,
    // so this request released routing_lock -- a lock the caller never named.
    m_locks->acquireLock("routing_lock", 30);

    const auto& res = m_peer->send(http::verb::post, "/ndt/release_lock", "{not json");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_FALSE(m_locks->acquireLock("routing_lock", 30))
        << "the malformed request released routing_lock as a side effect";
}

/**
 * A "type" field of the wrong JSON type is rubbish from the client, not a kernel fault.
 *
 * json::value("type", <const char*>) calls get<std::string>() on the found element, which throws
 * json::type_error when the element is a number -- so this is not caught by the parse guard and
 * would reach handleReleaseLock's outer catch(...), which answers 500. That is the exact
 * confusion tests/test_HttpSessionRouting.cpp was written to prevent: a caller must be able to
 * tell "you sent me rubbish" from "I am broken".
 */
TEST_F(LockEndpointTest, ATypeFieldOfTheWrongJsonTypeIsAClientErrorNotAServerError)
{
    m_locks->acquireLock("routing_lock", 30);

    const auto& res = m_peer->send(http::verb::post, "/ndt/release_lock", R"({"type":123})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_FALSE(m_locks->acquireLock("routing_lock", 30))
        << "a wrong-typed \"type\" released routing_lock as a side effect";
}

/// The accept path: a held lock releases, and says so.
TEST_F(LockEndpointTest, ReleasingAHeldLockSucceeds)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 30));

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/release_lock",
                                   R"({"type":"routing_lock"})");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    const auto body = nlohmann::json::parse(res.body());
    EXPECT_EQ(body.value("status", ""), "released");
    // /ndt/ is a cross-repo contract; T-7b must not have altered the success reply.
    EXPECT_EQ(body.value("type", ""), "routing_lock");
    EXPECT_EQ(body.size(), 2u) << "the success reply gained or lost a field: " << res.body();
}

/// ...and the release was real, not just reported. This is the assertion that a "return false
/// always" implementation of unlock would fail.
TEST_F(LockEndpointTest, AReleasedLockIsAcquirableAgain)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 30));
    ASSERT_FALSE(m_locks->acquireLock("routing_lock", 30)) << "precondition: the lock is held";

    m_peer->send(http::verb::post, "/ndt/release_lock", R"({"type":"routing_lock"})");

    EXPECT_TRUE(m_locks->acquireLock("routing_lock", 30))
        << "release answered 200 but the lock was still held";
}

/**
 * This test asserted the opposite until T-7b, and the reversal is the point of T-7b.
 *
 * [Co-developed with claude code -- Adam]
 * It used to read "AnAbsentBodyStillReleasesTheDefaultLock", on the grounds that
 * doc/2026-01-02_ndt_api.md documents the body as optional and that callers relied on it. The
 * first half was true and the second half was not: all three release callers send an explicit
 * "type" (Energy-Saving-App/src/app/http.cpp:461, Traffic-engineering-App.py:85, chaos
 * harness probes.py:206), as does every release check in tools/contract_test/spec.py. The
 * documented default had no user, and it was the last way for a request to act on a lock it
 * had not named. The doc section is corrected in the same commit.
 */
TEST_F(LockEndpointTest, AnAbsentBodyIsRefusedRatherThanReleasingTheDefaultLock)
{
    ASSERT_TRUE(m_locks->acquireLock(LockManager::DEFAULT_LOCK_TYPE_STR, 30));

    const auto& res = m_peer->send(http::verb::post, "/ndt/release_lock", "");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_FALSE(m_locks->acquireLock(LockManager::DEFAULT_LOCK_TYPE_STR, 30))
        << "the bodyless request released the default lock anyway; the status line was the "
           "only thing that changed";
}

/**
 * The whole defect, as an application would meet it.
 *
 * [Co-developed with claude code -- Adam]
 * Two apps, two locks. The caller holds power_lock; somebody else holds routing_lock. The
 * caller releases without a body -- which its own API doc told it was allowed -- and the
 * handler substituted routing_lock. Result before T-7b: somebody else's routing lock was
 * released, the caller's own power_lock stayed held, and the caller was told 200 "released"
 * with a "type" it had never mentioned. Every one of those three is asserted here, because
 * the reply was never the part that was wrong.
 */
TEST_F(LockEndpointTest, ABodylessReleaseDoesNotReleaseSomebodyElsesRoutingLock)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 30)) << "another app's lock";
    ASSERT_TRUE(m_locks->acquireLock("power_lock", 30)) << "the caller's own lock";

    const auto& res = m_peer->send(http::verb::post, "/ndt/release_lock", "");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_FALSE(m_locks->acquireLock("routing_lock", 30))
        << "the request freed routing_lock, which it never named, for a third party to take";
    EXPECT_FALSE(m_locks->acquireLock("power_lock", 30))
        << "power_lock -- the lock the caller actually held -- must be untouched by a refusal";

    // A refusal must leave the caller able to do the thing it meant to do. Without this, a
    // handler that wedged every lock on the first bad request would pass everything above.
    const auto& retry = m_peer->send(http::verb::post,
                                     "/ndt/release_lock",
                                     R"({"type":"power_lock"})");
    EXPECT_EQ(retry.result_int(), 200u) << "body: " << retry.body();
    EXPECT_TRUE(m_locks->acquireLock("power_lock", 30))
        << "the named release after the refusal did not actually free the lock";
}

// --- /ndt/renew_lock ---------------------------------------------------------------------------
//
// [Co-developed with claude code -- Adam]
// renew_lock had no endpoint-level tests at all. It carried the same defect release_lock did,
// plus an empty `catch (...)` around the body parse that release_lock had already lost: a
// malformed body, a body with no "type" and an absent body all renewed routing_lock.
//
// The state assertions below do not sleep. `acquireLock(name, 0)` sets expiryTime = now, so the
// lock is already expired to the next caller while still being isLocked -- which is exactly the
// state renew() acts on (see LockManagerTest.RenewingAnExpiredLockPutsItBackInForce). So "the
// lease was NOT extended" is observable as "the lock is still acquirable", with no wall clock
// involved. A renew that leaked through would put the lease back in force and that acquire
// would fail.

TEST_F(LockEndpointTest, ARenewWithAMalformedBodyDoesNotExtendTheDefaultLock)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 0)) << "held, and already expired";

    const auto& res = m_peer->send(http::verb::post, "/ndt/renew_lock", "{not json");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_TRUE(m_locks->acquireLock("routing_lock", 30))
        << "the malformed renew put routing_lock's lease back in force";
}

TEST_F(LockEndpointTest, ARenewWithNoTypeFieldDoesNotExtendTheDefaultLock)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 0));

    const auto& res = m_peer->send(http::verb::post, "/ndt/renew_lock", R"({"ttl":30})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_TRUE(m_locks->acquireLock("routing_lock", 30))
        << "a ttl with no type extended routing_lock -- the caller named a duration, not a lock";
}

/// The renew twin of ABodylessReleaseDoesNotReleaseSomebodyElsesRoutingLock.
TEST_F(LockEndpointTest, ABodylessRenewDoesNotExtendSomebodyElsesRoutingLock)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 0)) << "another app's, running out";
    ASSERT_TRUE(m_locks->acquireLock("power_lock", 0)) << "the caller's own, running out";

    const auto& res = m_peer->send(http::verb::post, "/ndt/renew_lock", "");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_TRUE(m_locks->acquireLock("routing_lock", 30))
        << "a bodyless renew extended a routing lease its caller never named";
    // and the caller's own lock is no better off for having asked wrongly -- which is the
    // honest outcome, and the one it can detect from a 400
    EXPECT_TRUE(m_locks->acquireLock("power_lock", 30));
}

TEST_F(LockEndpointTest, ARenewNamingAnUnknownLockTypeIsARequestErrorNotAStateError)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 0));

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/renew_lock",
                                   R"({"type":"no_such_lock_type_exists","ttl":30})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_TRUE(m_locks->acquireLock("routing_lock", 30))
        << "an unknown lock name extended routing_lock's lease";
}

/**
 * The accept path, and the reply shape.
 *
 * Every refusal above would also pass against a handler that answered 400 to everything, and
 * /ndt/ is a cross-repo contract, so the three field names are pinned by count as well as by
 * value -- an added field is as much a break as a renamed one for a strict client.
 */
TEST_F(LockEndpointTest, ARenewNamingItsOwnLockSucceedsAndKeepsItsReplyShape)
{
    ASSERT_TRUE(m_locks->acquireLock("power_lock", 0)) << "held, and already expired";

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/renew_lock",
                                   R"({"type":"power_lock","ttl":30})");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    const auto body = nlohmann::json::parse(res.body());
    EXPECT_EQ(body.value("status", ""), "renewed");
    EXPECT_EQ(body.value("type", ""), "power_lock");
    EXPECT_EQ(body.value("ttl", -1), 30);
    EXPECT_EQ(body.size(), 3u) << "the success reply gained or lost a field: " << res.body();

    EXPECT_FALSE(m_locks->acquireLock("power_lock", 30))
        << "the handler answered 'renewed' but the lease was not actually extended";
}

/**
 * 412 must survive the change. Splitting "bad request" out of the failure path is only worth
 * anything if the state condition keeps its own status: 412 tells a caller to acquire and try
 * again, 400 tells it to stop. Collapsing both into 400 would pass every refusal test above.
 */
TEST_F(LockEndpointTest, RenewingAValidLockNobodyHoldsIsStill412NotA400)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/renew_lock",
                                   R"({"type":"graph_lock","ttl":30})");

    EXPECT_EQ(res.result_int(), 412u) << "body: " << res.body();
}

// The release-side twin of the assertion above is
// ReleasingALockNobodyHoldsIsRefusedRatherThanReportedAsReleased, at the top of this file --
// it already pins 412 for a valid, unheld lock and keeps doing so after T-7b.

// --- LockManager::unlock, directly --------------------------------------------------------------

TEST(LockManagerUnlockTest, UnlockDistinguishesHeldFromNotHeldFromInvalid)
{
    LockManager locks;

    EXPECT_FALSE(locks.unlock("routing_lock")) << "nothing was ever acquired";
    EXPECT_FALSE(locks.unlock("no_such_lock_type_exists")) << "invalid type";

    ASSERT_TRUE(locks.acquireLock("routing_lock", 30));
    EXPECT_TRUE(locks.unlock("routing_lock")) << "a held lock releases";
    EXPECT_FALSE(locks.unlock("routing_lock")) << "and does not release twice";
}

// --- the per-switch stat endpoints --------------------------------------------------------------

TEST_F(LockEndpointTest, TotalInputTrafficLoadWithoutADpidIsABadRequestNotA200)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/get_total_input_traffic_load_passing_a_switch",
                                   "{}");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST_F(LockEndpointTest, NumOfFlowsWithoutADpidIsABadRequestNotA200)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/get_num_of_flows_passing_a_switch",
                                   "{}");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

/**
 * The accept path for both. A present dpid must still answer 200 -- otherwise "always 400" would
 * pass the two tests above. The graph is empty, so the answer is zero, but the status is what is
 * under test here.
 */
TEST_F(LockEndpointTest, TotalInputTrafficLoadWithADpidStillAnswers200)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/get_total_input_traffic_load_passing_a_switch",
                                   R"({"dpid":1})");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    EXPECT_EQ(nlohmann::json::parse(res.body()).value("status", ""), "success");
}

TEST_F(LockEndpointTest, NumOfFlowsWithADpidStillAnswers200)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/get_num_of_flows_passing_a_switch",
                                   R"({"dpid":1})");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    EXPECT_EQ(nlohmann::json::parse(res.body()).value("status", ""), "success");
}

// ---------------------------------------------------------------------------
// POST /ndt/inform_all_destination_paths -- a malformed hop.
//
// [Co-developed with claude code -- Adam]
// The body comes from the sibling apps over the network, and the loop that reads it indexed
// nodeJson[0] / nodeJson[1] on a const json with no size check. nlohmann's const array
// operator[] forwards straight to std::vector::operator[] -- unlike the object overload, which
// asserts -- so a hop array shorter than two elements read past the end of the heap in every
// build type. It is not an exception, so the handler's catch never saw it; ASan calls it a
// heap-buffer-overflow.
//
// The handler refuses the whole request rather than skipping the bad path, unlike the collector's
// copy of the same loop: a sibling app is making a claim about the network, and silently keeping
// the paths it got right would leave the caller believing all of them landed. That asymmetry is
// deliberate and is what these two cases pin.
//
// The collector is null in this fixture, which is exactly why these can run: the refusal happens
// before anything is stored. A well-formed body would reach setAllPaths and need a real one.
// ---------------------------------------------------------------------------

TEST_F(LockEndpointTest, APathHopWithOnlyOneElementIsRejectedRatherThanReadPastTheEnd)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/inform_all_destination_paths",
                                   R"({"all_destination_paths": [[["10.0.0.1"]]]})");

    EXPECT_EQ(res.result(), http::status::bad_request)
        << "a one-element hop is the heap-buffer-overflow trigger; it must be refused before "
           "the second element is read. Body: " << res.body();
    EXPECT_NE(res.body().find("error"), std::string::npos) << res.body();
}

TEST_F(LockEndpointTest, APathInterfaceThatIsNotANumberIsAClientErrorNotAServerError)
{
    // std::stoi("abc") threw std::invalid_argument out of the loop, and the outermost handler
    // turned it into a 500 -- the same conflation this file's sibling cases removed for the lock
    // endpoints, and that HttpSession.cpp records fixing for app_id sixty lines above the loop.
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/inform_all_destination_paths",
                                   R"({"all_destination_paths": [[[5, "abc"], [6, 2]]]})");

    EXPECT_EQ(res.result(), http::status::bad_request)
        << "answered " << res.result_int() << " for a malformed request body: " << res.body();
}
