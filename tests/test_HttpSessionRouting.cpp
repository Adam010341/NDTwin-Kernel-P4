/**
 * Tests for HttpSession's routing table and its exception-to-status-code mapping.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Two endpoints were answering **500 Internal Server Error** to a mistyped parameter:
 * `GET /ndt/inform_switch_entered?dpid=abc` and `POST /ndt/simulation_completed` with a
 * non-numeric `app_id`. Both were `std::stoull`/`std::stoi` throwing `std::invalid_argument`,
 * which lands in the `catch (const std::exception&)` clause -- 500 -- rather than the
 * `catch (const json::exception&)` clause above it -- 400. A caller could not distinguish
 * "you sent me rubbish" from "I am broken".
 *
 * Both were fixed by parsing explicitly with utils::tryParseUint64. **Neither fix was
 * observable.** Putting `std::stoi` back left all 258 tests green, because every test in the
 * suite reached the validation logic through a helper called directly, and a helper cannot
 * tell you which catch clause would have run. The status code is decided by HttpSession, so
 * only HttpSession can be asked about it.
 *
 * Hence the seam: `buildResponse()` is everything `handleRequest()` does except
 * `writeResponse()`, so it performs no socket I/O and a test can drive the real routing table
 * over an unconnected socket. HttpSessionTestPeer is the granted friend.
 *
 * The dependencies are null shared_ptrs. That is deliberate and it constrains what belongs in
 * this file: only requests that are *rejected before any collaborator is touched*. Every test
 * here asserts a 4xx, and any mutation that lets a request through to a handler will fault on a
 * null dereference rather than report a clean failure -- still a failing binary, just an ugly
 * one. Handlers whose success paths need real collaborators are covered elsewhere; see the note
 * at the bottom of this file about get_nickname, which validates its dpid *after* calling
 * getGraph() and so cannot be reached this way at all.
 */

#include <memory>
#include <string>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "ndt_core/http/HttpSession.hpp"
#include "utils/Utils.hpp"

/**
 * @brief Drives HttpSession::buildResponse() over a synthetic request.
 *
 * Must live at global scope: `friend class HttpSessionTestPeer` names ::HttpSessionTestPeer, so a
 * copy of this class inside an anonymous namespace would be a different, non-friend type and would
 * not compile.
 */
class HttpSessionTestPeer
{
  public:
    HttpSessionTestPeer()
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                 nullptr,          // TopologyAndFlowMonitor
                                                 nullptr,          // EventBus
                                                 utils::MININET,   // mode
                                                 nullptr,          // FlowLinkUsageCollector
                                                 nullptr,          // FlowRoutingManager
                                                 nullptr,          // DeviceConfig...PowerManager
                                                 nullptr,          // ApplicationManager
                                                 nullptr,          // SimulationRequestManager
                                                 nullptr,          // IntentTranslator
                                                 nullptr,          // HistoricalDataManager
                                                 nullptr,          // Controller
                                                 nullptr))         // LockManager
    {
    }

    /// Routes one request and returns the response. No socket I/O happens.
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
    // Declared before m_session: the socket is constructed from it.
    boost::asio::io_context m_ioc;
    std::shared_ptr<HttpSession> m_session;
    std::shared_ptr<http::response<http::string_body>> m_response;
};

namespace
{

/// A body the JSON parser will reject outright, as opposed to one it parses into the wrong shape.
constexpr const char* kUnparseableBody = "{not json";

} // namespace

// --- the app_id regression -------------------------------------------------------------------
// These are the reason this file exists. Restoring `std::stoi(appIdText)` in
// handleSimulationCompleted turns every one of them from 400 into 500.

TEST(HttpSessionRoutingTest, ANonNumericAppIdIsAClientErrorNotAServerError)
{
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::post,
                                "/ndt/simulation_completed",
                                R"({"app_id":"abc"})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, AnAppIdWithTrailingGarbageIsRejectedRatherThanTruncated)
{
    // std::stoi("12abc") is 12 and std::stoull would agree, so the request would be attributed to
    // application 12 -- a different application's simulation result, delivered silently.
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::post,
                                "/ndt/simulation_completed",
                                R"({"app_id":"12abc"})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, ANegativeAppIdIsRejectedRatherThanWrappedAround)
{
    // std::stoull("-1") is 18446744073709551615, not an error.
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::post,
                                "/ndt/simulation_completed",
                                R"({"app_id":"-1"})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, AnAppIdTooWideForIntIsRejected)
{
    // Parses as a uint64 but does not fit the int that onSimulationResult takes. Guards the
    // std::numeric_limits<int>::max() half of the check specifically: 2147483648 is exactly
    // INT_MAX + 1, so a test using a larger value would also pass with that check deleted.
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::post,
                                "/ndt/simulation_completed",
                                R"({"app_id":"2147483648"})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, AnAppIdTooWideForUint64IsRejected)
{
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::post,
                                "/ndt/simulation_completed",
                                R"({"app_id":"99999999999999999999999"})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, AnAppIdSentAsANumberIsAClientError)
{
    // The field is read with get<string>(), so a JSON number raises json::type_error. That is a
    // json::exception, so it must reach the 400 clause -- this pins that the two catch clauses are
    // in the right order, since json::exception derives from std::exception and an inverted order
    // would silently answer 500.
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::post,
                                "/ndt/simulation_completed",
                                R"({"app_id":123})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, AMissingAppIdIsAClientError)
{
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::post, "/ndt/simulation_completed", "{}");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

// --- the dpid regression ---------------------------------------------------------------------

TEST(HttpSessionRoutingTest, ANonNumericDpidIsAClientErrorNotAServerError)
{
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::get, "/ndt/inform_switch_entered?dpid=abc");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, ADpidWithTrailingGarbageIsRejectedRatherThanTruncated)
{
    // std::stoull("12abc") is 12: the switch-entered notification would be applied to switch 12.
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::get, "/ndt/inform_switch_entered?dpid=12abc");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

// These two assert the *body*, not just the status, and that is not padding. Both wrote 400 no
// matter what was done to the two early-return guards, because tryParseUint64 rejects whatever
// reaches it and answers 400 anyway -- deleting both guards outright still left the status at 400,
// so as status assertions they could not fail and proved nothing. What the guards genuinely decide
// is which of two client errors the caller is told about: a parameter that is **absent** versus one
// that is **malformed**. That distinction is the only observable effect they have, so it is what
// gets pinned.
//
// (Deleting the `pos == npos` guard is survivable for a second reason worth knowing: `npos + 6`
// wraps to 5, so `substr(5)` returns a harmless non-numeric tail rather than throwing.)

TEST(HttpSessionRoutingTest, AnAbsentDpidParameterIsReportedAsMissingNotAsMalformed)
{
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::get, "/ndt/inform_switch_entered");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_NE(res.body().find("Missing"), std::string::npos)
        << "a caller that sent no dpid at all was told its dpid was invalid: " << res.body();
}

TEST(HttpSessionRoutingTest, AnEmptyDpidParameterIsReportedAsMissingNotAsMalformed)
{
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::get, "/ndt/inform_switch_entered?dpid=");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_NE(res.body().find("Missing"), std::string::npos)
        << "`?dpid=` is an absent value, not a malformed one: " << res.body();
}

// --- the exception-to-status mapping itself --------------------------------------------------

TEST(HttpSessionRoutingTest, AnUnparseableBodyIsAClientError)
{
    // inform_all_destination_paths parses before it touches the collector, so this reaches the
    // json::exception clause without dereferencing a null dependency.
    HttpSessionTestPeer peer;
    const auto& res =
        peer.send(http::verb::post, "/ndt/inform_all_destination_paths", kUnparseableBody);

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, AParseableBodyMissingItsRequiredKeyIsAClientError)
{
    // json::out_of_range from .at(), a different json::exception subclass than the parse error
    // above, so this is not a duplicate of the previous test.
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::post, "/ndt/inform_all_destination_paths", "{}");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, AClientErrorStillCarriesADiagnosticBody)
{
    // A bare 400 with an empty body is nearly as unhelpful as a 500. Whatever the wording, the
    // response has to say something.
    HttpSessionTestPeer peer;
    const auto& res =
        peer.send(http::verb::post, "/ndt/inform_all_destination_paths", kUnparseableBody);

    ASSERT_EQ(res.result_int(), 400u);
    EXPECT_FALSE(res.body().empty()) << "400 with no explanation";
}

// --- the routing table ----------------------------------------------------------------------

TEST(HttpSessionRoutingTest, AnUnknownEndpointIsNotFound)
{
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::get, "/ndt/no_such_endpoint");

    EXPECT_EQ(res.result_int(), 404u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, TheMethodIsPartOfTheRoute)
{
    // Every route matches on method *and* target. Dropping the method half would send a GET into
    // a POST handler; with null dependencies that faults rather than returning, which still fails
    // this test, just less tidily than a 404 mismatch would.
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::get, "/ndt/link_failure_detected");

    EXPECT_EQ(res.result_int(), 404u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, APreflightIsAnsweredWithoutRunningAHandler)
{
    // The browser preflight has to short-circuit before routing: OPTIONS matches no route, so
    // falling through would answer 404 and the real request would never be sent.
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::options, "/ndt/link_failure_detected");

    EXPECT_EQ(res.result_int(), 204u);
    EXPECT_TRUE(res.body().empty()) << "204 No Content with a body: " << res.body();
}

TEST(HttpSessionRoutingTest, CorsHeadersAreSetEvenOnAFailedRequest)
{
    // The Web-GUI is served from a different origin, so a response without these headers is
    // unreadable to it -- including the error responses, which are the ones worth reading.
    HttpSessionTestPeer peer;
    const auto& res = peer.send(http::verb::get, "/ndt/no_such_endpoint");

    EXPECT_EQ(res[http::field::access_control_allow_origin], "*");
    EXPECT_EQ(res[http::field::content_type], "application/json");
}

/*
 * Not covered here, and why:
 *
 * - `GET /ndt/get_nickname?dpid=abc` has the same dpid guard, but handleGetNickname calls
 *   m_topologyAndFlowMonitor->getGraph() *before* parsing the parameter, so it cannot be reached
 *   without a real monitor. Validating input after doing work is the actual finding; the guard
 *   itself is identical to the one tested above.
 *
 * - The success path of handleSimulationCompleted. onSimulationResult spawns a **detached**
 *   thread that runs curl, so a unit test would either shell out or race fixture teardown with a
 *   thread holding `this`.
 */
