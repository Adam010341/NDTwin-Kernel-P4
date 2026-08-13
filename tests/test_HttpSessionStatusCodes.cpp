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

TEST_F(LockEndpointTest, ReleasingAnUnknownLockTypeIsRefusedRatherThanReportedAsReleased)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/release_lock",
                                   R"({"type":"no_such_lock_type_exists"})");

    EXPECT_EQ(res.result_int(), 412u) << "body: " << res.body();
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
    const auto& res = m_peer->send(http::verb::post, "/ndt/release_lock", R"({"type":123})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

/// The accept path: a held lock releases, and says so.
TEST_F(LockEndpointTest, ReleasingAHeldLockSucceeds)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 30));

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/release_lock",
                                   R"({"type":"routing_lock"})");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    EXPECT_EQ(nlohmann::json::parse(res.body()).value("status", ""), "released");
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

/// An absent body still means "the default lock", which doc/2026-01-02_ndt_api.md documents as supported.
TEST_F(LockEndpointTest, AnAbsentBodyStillReleasesTheDefaultLock)
{
    ASSERT_TRUE(m_locks->acquireLock(LockManager::DEFAULT_LOCK_TYPE_STR, 30));

    const auto& res = m_peer->send(http::verb::post, "/ndt/release_lock", "");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
}

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
