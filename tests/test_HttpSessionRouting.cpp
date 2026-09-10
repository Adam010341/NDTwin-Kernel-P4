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

#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include <spdlog/sinks/ringbuffer_sink.h>

#include <shared_mutex>

#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/http/HttpSession.hpp"
// [Co-developed with claude code -- Adam] W11: the dispatch-status endpoint's own collaborator.
#include "ndt_core/routing_management/Controller.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "utils/Logger.hpp"
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

    /**
     * Real-collaborator variant, for handlers whose *success* path is the subject. The null-
     * dependency constructor above can only witness requests rejected before any collaborator is
     * touched; the link-transition handlers do their work through the monitor and the bus, so a
     * test of what they do -- rather than what they refuse -- needs real ones.
     * [Co-developed with claude code -- Adam]
     */
    /// Mode-carrying variant. [Co-developed with claude code -- Adam] doc/KNOWN-ISSUES.md B-6:
    /// /ndt/inject_link_failure runs tc on a MININET deployment and must NOT on any other, so the
    /// mode is the subject of a case rather than a fixture constant. Kept as a third constructor,
    /// not a default argument on the one below, so that every existing call site keeps naming
    /// MININET by the same route it always did.
    HttpSessionTestPeer(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                        std::shared_ptr<EventBus> bus,
                        utils::DeploymentMode mode)
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                 std::move(monitor),
                                                 std::move(bus),
                                                 mode,
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

    HttpSessionTestPeer(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                        std::shared_ptr<EventBus> bus)
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                 std::move(monitor),
                                                 std::move(bus),
                                                 utils::MININET,
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

    /**
     * Controller variant, for GET /ndt/get_flow_dispatch_status.
     * [Co-developed with claude code -- Adam] W11.
     *
     * That handler reads only the controller, so everything else can stay null and the response
     * body -- the thing W11 changes -- becomes reachable from a unit test for the first time. The
     * A-7 gate declared this endpoint's body uncovered because no suite exercised HttpSession's
     * handlers in-process; the null-dependency peer above could only witness refusals.
     */
    explicit HttpSessionTestPeer(std::shared_ptr<Controller> controller)
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                 nullptr,          // TopologyAndFlowMonitor
                                                 nullptr,          // EventBus
                                                 utils::MININET,
                                                 nullptr,          // FlowLinkUsageCollector
                                                 nullptr,          // FlowRoutingManager
                                                 nullptr,          // DeviceConfig...PowerManager
                                                 nullptr,          // ApplicationManager
                                                 nullptr,          // SimulationRequestManager
                                                 nullptr,          // IntentTranslator
                                                 nullptr,          // HistoricalDataManager
                                                 std::move(controller),
                                                 nullptr))         // LockManager
    {
    }

    /**
     * @brief Points the session's tc seam and provenance ledger at ones the test owns. B-13.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md B-13. This is what makes the MININET half of /ndt/inject_link_failure
     * and /ndt/inject_link_recovery reachable from ctest at all: before it, both handlers built
     * `utils::netem::realTcRunner()` inline and every case here had to use utils::TESTBED, where
     * the handler answers `"tc": "skipped (not MININET)"` and returns.
     *
     * The ledger is the test's own rather than the process one so that no case can leave a
     * recorded netem behind for the next -- an ownership check is exactly the kind of thing that
     * passes for the wrong reason when state leaks between cases.
     */
    void useTcSeam(utils::netem::TcRunner runner, utils::netem::InjectedNetemLedger* ledger)
    {
        m_session->m_tcRunner = std::move(runner);
        m_session->m_injectedNetem = ledger;
        m_seamInstalled = true;
    }

    /// Routes one request and returns the response. No socket I/O happens.
    const http::response<http::string_body>&
    send(http::verb method, const std::string& target, const std::string& body = "")
    {
        refuseRealTc();
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
    /**
     * @brief Makes a case that reaches tc without asking for a fake fail loudly instead. B-13.
     *
     * [Co-developed with claude code -- Adam]
     * Every constructor above builds a MININET session unless told otherwise, and on MININET the
     * two inject endpoints really do run `sudo -n tc`. No case in this file has ever hit that --
     * they all use utils::TESTBED for the inject endpoints, and say so in a comment -- but that is
     * a convention, and the next person to write `HttpSessionTestPeer peer(m_monitor, m_bus)` and
     * POST an injection would run tc against whatever `s1-eth1` is on the machine running ctest.
     * A test suite is not allowed to touch this machine's qdisc tree; that is the rule
     * tests/shell/mutate_declared_link_failure_survives_poll.sh states in its own header.
     *
     * Installed on every send() rather than in the constructors because there are four of those
     * and one send(), and skipped once useTcSeam has put a real fake in place.
     */
    void refuseRealTc()
    {
        if (m_seamInstalled) return;
        m_session->m_tcRunner = [](const std::vector<std::string>& args) {
            ADD_FAILURE() << "an endpoint ran tc against the machine running the tests: "
                          << utils::describeArgv(args)
                          << "\nUse HttpSessionTestPeer::useTcSeam to supply a fake, or build the "
                             "peer with utils::TESTBED if the tc half is not the subject.";
            return utils::netem::TcOutcome{false, -1, ""};
        };
    }

    // Declared before m_session: the socket is constructed from it.
    boost::asio::io_context m_ioc;
    std::shared_ptr<HttpSession> m_session;
    std::shared_ptr<http::response<http::string_body>> m_response;
    bool m_seamInstalled = false;
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

// --- link failure / recovery: the reverse-edge guard -----------------------------------------
// [Co-developed with claude code -- Adam]
// Both handlers used to skip a missing reverse edge silently and answer 200 "processed", so a
// caller could not tell a fully handled transition from one that left the graph asymmetric --
// one direction changed, the pair it belongs to untouched. Edges are inserted in pairs by every
// loader, so a lone directed edge is the kernel's own state gone inconsistent: the handlers now
// answer 500 and say which half happened. Found by agy-review 0198 #4.

class LinkTransitionEndpointsTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_bus = std::make_shared<EventBus>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(m_graph,
                                                             std::make_shared<std::shared_mutex>(),
                                                             m_bus,
                                                             utils::MININET);
    }

    void addDirectedEdge(uint64_t srcDpid, uint64_t dstDpid, bool up)
    {
        EdgeProperties ep;
        ep.srcDpid = srcDpid;
        ep.dstDpid = dstDpid;
        ep.srcInterface = 1;
        ep.dstInterface = 1;
        ep.isUp = up;
        const auto u = boost::add_vertex(*m_graph);
        const auto v = boost::add_vertex(*m_graph);
        boost::add_edge(u, v, ep, *m_graph);
    }

    /// isUp of the (srcDpid, dstDpid) edge, read back through the monitor's own snapshot.
    bool edgeIsUp(uint64_t srcDpid, uint64_t dstDpid)
    {
        const Graph g = m_monitor->getGraph();
        for (auto [ei, eiEnd] = boost::edges(g); ei != eiEnd; ++ei)
        {
            if (g[*ei].srcDpid == srcDpid && g[*ei].dstDpid == dstDpid)
            {
                return g[*ei].isUp;
            }
        }
        ADD_FAILURE() << "edge " << srcDpid << " -> " << dstDpid << " not in the graph";
        return false;
    }

    static constexpr const char* kPayload =
        R"({"src_dpid":1,"src_interface":1,"dst_dpid":5,"dst_interface":1})";

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
};

TEST_F(LinkTransitionEndpointsTest, AFailureWithBothDirectionsPresentTakesBothDownAndAnswers200)
{
    addDirectedEdge(1, 5, /*up=*/true);
    addDirectedEdge(5, 1, /*up=*/true);
    HttpSessionTestPeer peer(m_monitor, m_bus);

    const auto& res = peer.send(http::verb::post, "/ndt/link_failure_detected", kPayload);

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    EXPECT_FALSE(edgeIsUp(1, 5));
    EXPECT_FALSE(edgeIsUp(5, 1));
}

TEST_F(LinkTransitionEndpointsTest, AFailureWhoseReverseEdgeIsMissingIsNotReportedAsSuccess)
{
    // The regression: this answered 200 "link failure processed" with the graph left holding a
    // lone down edge. The forward direction is still processed -- that part of the work is real
    // -- but the status line has to say the pair is broken.
    addDirectedEdge(1, 5, /*up=*/true);
    HttpSessionTestPeer peer(m_monitor, m_bus);

    const auto& res = peer.send(http::verb::post, "/ndt/link_failure_detected", kPayload);

    EXPECT_EQ(res.result_int(), 500u) << "body: " << res.body();
    EXPECT_NE(res.body().find("reverse edge missing"), std::string::npos) << res.body();
    EXPECT_FALSE(edgeIsUp(1, 5)) << "the reported direction must still be marked down";
}

TEST_F(LinkTransitionEndpointsTest, ARecoveryWithBothDirectionsPresentBringsBothUpAndAnswers200)
{
    addDirectedEdge(1, 5, /*up=*/false);
    addDirectedEdge(5, 1, /*up=*/false);
    HttpSessionTestPeer peer(m_monitor, m_bus);

    const auto& res = peer.send(http::verb::post, "/ndt/link_recovery_detected", kPayload);

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    EXPECT_TRUE(edgeIsUp(1, 5));
    EXPECT_TRUE(edgeIsUp(5, 1));
}

TEST_F(LinkTransitionEndpointsTest, ARecoveryWhoseReverseEdgeIsMissingIsNotReportedAsSuccess)
{
    addDirectedEdge(1, 5, /*up=*/false);
    HttpSessionTestPeer peer(m_monitor, m_bus);

    const auto& res = peer.send(http::verb::post, "/ndt/link_recovery_detected", kPayload);

    EXPECT_EQ(res.result_int(), 500u) << "body: " << res.body();
    EXPECT_NE(res.body().find("reverse edge missing"), std::string::npos) << res.body();
    EXPECT_TRUE(edgeIsUp(1, 5)) << "the reported direction must still be marked up";
}

// --- F-8: what /ndt/get_graph_data says about where the headroom figure came from -------------
// [Co-developed with claude code -- Adam]
// The unit-level behaviour is in test_LeftBandwidthCapacity.cpp. This one is here because the
// serialisation is decided by HttpSession -- handleGetGraphData chooses between leftBandwidth and
// leftBandwidthFromFlowSample on m_mode -- and only HttpSession can be asked about it, the same
// argument that put the app_id tests above in this file. The peer is MININET mode, which is the
// mode the defect lives in.

class GraphDataHeadroomTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_bus = std::make_shared<EventBus>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(m_graph,
                                                             std::make_shared<std::shared_mutex>(),
                                                             m_bus,
                                                             utils::MININET);
    }

    void addEdge(uint64_t srcDpid, uint64_t capacity, uint64_t left, BandwidthSource source)
    {
        EdgeProperties ep;
        ep.srcDpid = srcDpid;
        ep.dstDpid = srcDpid + 100;
        ep.srcInterface = 1;
        ep.dstInterface = 1;
        ep.isUp = true;
        ep.linkBandwidth = capacity;
        ep.leftBandwidth = left;
        ep.leftBandwidthFromFlowSample = left;
        ep.leftBandwidthSource = source;
        const auto u = boost::add_vertex(*m_graph);
        const auto v = boost::add_vertex(*m_graph);
        boost::add_edge(u, v, ep, *m_graph);
    }

    /// The serialised edge whose src_dpid is `srcDpid`.
    static nlohmann::json edgeOf(const std::string& body, uint64_t srcDpid)
    {
        const auto parsed = nlohmann::json::parse(body);
        for (const auto& e : parsed.at("edges"))
        {
            if (e.at("src_dpid").get<uint64_t>() == srcDpid)
            {
                return e;
            }
        }
        ADD_FAILURE() << "no edge with src_dpid " << srcDpid << " in: " << body;
        return nlohmann::json::object();
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
};

TEST_F(GraphDataHeadroomTest, TheHeadroomFigureCarriesItsProvenance)
{
    // Two edges that publish the *same* number for opposite reasons: one 10 Gbit/s core link
    // nobody has sampled, and one 10 Gbit/s link observed to be idle. Before the provenance key
    // existed a reader had nothing to tell them apart -- and before the loader was fixed the
    // first of them published 1000000000 instead.
    addEdge(/*srcDpid=*/5, /*capacity=*/10'000'000'000ULL, /*left=*/10'000'000'000ULL,
            BandwidthSource::Declared);
    addEdge(/*srcDpid=*/6, /*capacity=*/10'000'000'000ULL, /*left=*/10'000'000'000ULL,
            BandwidthSource::Measured);
    HttpSessionTestPeer peer(m_monitor, m_bus);

    const auto& res = peer.send(http::verb::get, "/ndt/get_graph_data");
    ASSERT_EQ(res.result_int(), 200u) << "body: " << res.body();

    const auto declared = edgeOf(res.body(), 5);
    const auto measured = edgeOf(res.body(), 6);

    EXPECT_EQ(declared.at("left_link_bandwidth_bps").get<uint64_t>(), 10'000'000'000ULL)
        << "an unsampled 10 Gbit/s link must not advertise a gigabit";
    EXPECT_EQ(declared.at("left_link_bandwidth_source").get<std::string>(), "declared");
    EXPECT_EQ(measured.at("left_link_bandwidth_source").get<std::string>(), "measured");
}

TEST_F(GraphDataHeadroomTest, TheExistingHeadroomKeyKeepsItsNameAndType)
{
    // /ndt/ is a cross-repo contract; the fix is additive by construction and this is the
    // assertion that says so. A rename or a null here breaks the sister apps, not just a test.
    addEdge(/*srcDpid=*/5, /*capacity=*/1'000'000'000ULL, /*left=*/1'000'000'000ULL,
            BandwidthSource::Declared);
    HttpSessionTestPeer peer(m_monitor, m_bus);

    const auto& res = peer.send(http::verb::get, "/ndt/get_graph_data");
    ASSERT_EQ(res.result_int(), 200u) << "body: " << res.body();

    const auto e = edgeOf(res.body(), 5);
    ASSERT_TRUE(e.contains("left_link_bandwidth_bps")) << res.body();
    EXPECT_TRUE(e.at("left_link_bandwidth_bps").is_number_unsigned()) << res.body();
    EXPECT_FALSE(e.at("left_link_bandwidth_bps").is_null());
}

// --- the liveness parameter on the two flow-listing endpoints ---------------------------------
// [Co-developed with claude code -- Adam] KNOWN-ISSUES B-x.
//
// These belong in this file rather than test_FlowLiveness.cpp for the reason its header states:
// the status code is decided by HttpSession, so only HttpSession can be asked about it. They also
// respect this file's constraint -- every case asserts a 4xx reached before any collaborator is
// touched, because readLivenessFilter runs before the null m_flowLinkUsageCollector is
// dereferenced. A valid `liveness` value cannot be tested here at all; it would reach the handler
// and fault on the null collector.
//
// 🔴 What each of these does against the pre-patch code, stated because "red" means two different
// things here:
//   * the get_detected_flow_data case answers 404, cleanly. The route was an exact compare
//     (`target == "/ndt/get_detected_flow_data"`), so any query string fell through to not-found.
//   * the top-k case SEGFAULTS. Its route was already `starts_with`, so the request reaches the
//     handler, which dereferences the null collector. That kills the gtest process, taking the
//     rest of the binary's reporting with it -- a failing run, but an ugly one, and the same
//     hazard this file's header describes. Expect it when running the gate.

TEST(HttpSessionRoutingTest, AQueryStringOnGetDetectedFlowDataStillReachesItsRoute)
{
    // The narrowest statement of the routing half: an unparseable value must be rejected by the
    // handler as 400, not by the router as 404. A 404 here means the endpoint cannot take a
    // parameter at all.
    HttpSessionTestPeer peer;
    const auto& res =
        peer.send(http::verb::get, "/ndt/get_detected_flow_data?liveness=not_a_value");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_NE(res.body().find("liveness"), std::string::npos)
        << "a 400 that does not name the parameter it rejected: " << res.body();
}

TEST(HttpSessionRoutingTest, AnUnrecognisedLivenessValueIsRefusedRatherThanQuietlyDefaulted)
{
    HttpSessionTestPeer peer;
    for (const char* bad : {"alive", "ACTIVE", "true", "1"})
    {
        const auto& res =
            peer.send(http::verb::get, std::string("/ndt/get_detected_flow_data?liveness=") + bad);
        EXPECT_EQ(res.result_int(), 400u) << bad << " -> " << res.body();
    }
}

TEST(HttpSessionRoutingTest, TopKRefusesAnUnrecognisedLivenessValueBeforeTouchingTheCollector)
{
    HttpSessionTestPeer peer;
    const auto& res =
        peer.send(http::verb::get, "/ndt/get_detected_top_k_flow_data?k=5&liveness=bogus");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST(HttpSessionRoutingTest, AMistypedFlowDataEndpointIsNotFoundRatherThanServed)
{
    // The tightening half. `starts_with` on the top-k route accepted any suffix, so a typo was
    // answered as if it were the endpoint; utils::pathIs requires end-of-target or '?'.
    HttpSessionTestPeer peer;
    for (const char* target : {"/ndt/get_detected_flow_dataZZZ",
                               "/ndt/get_detected_top_k_flow_dataZZZ",
                               "/ndt/get_detected_flow_data/extra"})
    {
        const auto& res = peer.send(http::verb::get, target);
        EXPECT_EQ(res.result_int(), 404u) << target << " -> " << res.body();
    }
}

// =================================================================================================
// FINDINGS #81 -- /ndt/inform_switch_entered and a standing commanded power-off
//
// [Co-developed with claude code -- Adam]
//
// handleInformSwitchEntered calls setVertexUp unconditionally. #46 closed the topology poll's
// door onto a commanded-off switch; this is the other push, and it was left alone because
// nobody had established what it is evidence OF.
//
// It was established here, from the callers rather than from taste:
//
//   - intelligent_router.py:1202 fires it from `_state_change_handler`, an
//     `ofp_event.EventOFPStateChange` handler, when a datapath reaches MAIN_DISPATCHER -- i.e.
//     on the transition, when a switch has just completed an OpenFlow handshake;
//   - intelligent_router.py:1059 fires it per dpid drained from `_pending_switch_dpids`, which
//     `EventSwitchEnter` fills -- again a transition, not a scan;
//   - p4_proxy/proxy_agent/kernel_notifier.py:96 is the P4 equivalent, pushed when the proxy
//     adopts a switch.
//
// All three are EDGE-TRIGGERED BY A COMPLETED SESSION. That is categorically different from
// FINDINGS #46's poll, whose input was list membership in a reply the proxy went on serving for
// D = 3.06 s after the switch died. A dead process does not complete a handshake, so this push
// is evidence about the present and is allowed to lift `reachable`.
//
// What it is NOT evidence of is anybody having withdrawn the power-off. Those are now separate
// fields (Q12), so the twin no longer has to pick one: it reports admin_state=off with
// reachable=true and lets the operator see that the switch came back without being asked to.
// =================================================================================================

class InformSwitchEnteredTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_bus = std::make_shared<EventBus>();
        m_monitor = std::make_shared<TopologyAndFlowMonitor>(
            m_graph, std::make_shared<std::shared_mutex>(), m_bus, utils::MININET);

        m_sw = boost::add_vertex(*m_graph);
        (*m_graph)[m_sw].vertexType = VertexType::SWITCH;
        (*m_graph)[m_sw].dpid = kDpid;
        (*m_graph)[m_sw].deviceName = "s1";
        (*m_graph)[m_sw].bridgeNameForMininet = "s1";
        (*m_graph)[m_sw].isUp = true;
    }

    static constexpr uint64_t kDpid = 1;

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    Graph::vertex_descriptor m_sw{};
};

TEST_F(InformSwitchEnteredTest, ASwitchEnteredPushDoesNotClearAStandingCommandedPowerOff)
{
    // 🔴 The assertion #81 is about. If this push could clear the command, every guard #46 built
    // would have a second door: the twin kills a switch, the control plane pushes one enter, and
    // discovery is free to mark it up for ever after.
    m_monitor->setVertexPoweredOffByCommand(m_sw);
    ASSERT_TRUE(m_monitor->getVertexAdminPoweredOff(m_sw));

    HttpSessionTestPeer peer(m_monitor, m_bus);
    const auto& res = peer.send(http::verb::get, "/ndt/inform_switch_entered?dpid=1");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    EXPECT_TRUE(m_monitor->getVertexAdminPoweredOff(m_sw))
        << "a control-plane push withdrew a power-off command. Only a power-on may do that "
           "(FINDINGS #46); this endpoint reports a session, not an instruction";
}

TEST_F(InformSwitchEnteredTest, ASwitchEnteredPushMayStillLiftReachable)
{
    // The other direction, and the reason this endpoint was NOT made to decline. A completed
    // handshake is evidence the process is serving; refusing to record it would make the twin
    // report a switch that is demonstrably answering as unreachable -- the failure mode #46's
    // own write-up names as worse than the defect.
    m_monitor->setVertexPoweredOffByCommand(m_sw);
    ASSERT_FALSE(m_monitor->getVertexIsUp(m_sw));

    HttpSessionTestPeer peer(m_monitor, m_bus);
    const auto& res = peer.send(http::verb::get, "/ndt/inform_switch_entered?dpid=1");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    EXPECT_TRUE(m_monitor->getVertexIsUp(m_sw))
        << "the switch completed a session and the twin refused to observe it";
}

TEST_F(InformSwitchEnteredTest, TheResultingVertexReportsTheDisagreementRatherThanPickingOne)
{
    // Q12 is what makes the paragraph above legal. With one boolean the twin had to choose
    // between "commanded off" and "answering", and either choice was a lie; with two fields it
    // states both and the operator sees a switch that came back without being asked.
    m_monitor->setVertexPoweredOffByCommand(m_sw);

    HttpSessionTestPeer peer(m_monitor, m_bus);
    ASSERT_EQ(peer.send(http::verb::get, "/ndt/inform_switch_entered?dpid=1").result_int(), 200u);

    const nlohmann::json j = m_monitor->getGraph()[m_sw];
    EXPECT_EQ(j.value("admin_state", ""), "off");
    EXPECT_TRUE(j.value("reachable", false));
    EXPECT_TRUE(j.value("is_up", false)) << "the alias must track reachable";
}

// --- W11: GET /ndt/get_flow_dispatch_status ----------------------------------------------------
//
// [Co-developed with claude code -- Adam]
//
// #54 and R6 K-4. Two changes to this endpoint's body and one to its route, and all three are
// only observable from a response: the counters were renamed (`succeeded` -> `dispatched_ok`),
// a second group was added that answers about the switch rather than about the dispatch, and the
// route now accepts `?request_id=`, which the exact-string compare it used to have could not.
//
// The A-7 gate records this endpoint's body as declared-uncovered -- "no suite here exercises
// HttpSession's handlers in-process". That was true while every peer in this file was built with
// null dependencies; the handler needs only a Controller, so it is reachable now. Nothing below
// asserts on `dispatcher_running`, deliberately: that field is what the A-7 gate's mutation 9
// removes, and a test of it here would make that mutation redden something other than the test it
// names, which the gate scores as a survivor.

namespace
{

/// A manager whose answer the test chooses, so both planes' replies can be produced without a
/// controller, a proxy, or a network. The three dispatch methods are all Controller's sender calls.
class PlaneStub : public FlowRoutingManager
{
  public:
    PlaneStub() : FlowRoutingManager(nullptr, nullptr, nullptr) {}

    void answerWith(const OpResult& result)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_result = result;
    }

    uint64_t calls() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_calls;
    }

    OpResult installAnEntry(uint64_t, int, const nlohmann::json&, const nlohmann::json&,
                            int) override
    {
        return answer();
    }
    OpResult modifyAnEntry(uint64_t, int, const nlohmann::json&, const nlohmann::json&) override
    {
        return answer();
    }
    OpResult deleteAnEntry(uint64_t, const nlohmann::json&, int) override { return answer(); }

  private:
    OpResult answer()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        ++m_calls;
        return m_result;
    }

    mutable std::mutex m_mutex;
    uint64_t m_calls = 0;
    OpResult m_result = OpResult::success();
};

FlowJob
dispatchJob(uint64_t requestId, uint64_t dpid = 1)
{
    FlowJob job;
    job.dpid = dpid;
    job.op = FlowOp::Install;
    job.priority = 100;
    job.match = nlohmann::json{{"eth_type", 2048}, {"ipv4_dst", "10.0.0.9"}};
    job.actions = nlohmann::json::array();
    job.requestId = requestId;
    return job;
}

/// Polls until the sender has been called @p n times, so the assertions run on a drained queue.
bool
waitForCalls(const PlaneStub& stub, uint64_t n)
{
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline)
    {
        if (stub.calls() >= n)
        {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return false;
}

/// Controller plus the stub it dispatches through, kept alive together.
struct DispatchFixture
{
    std::shared_ptr<PlaneStub> stub = std::make_shared<PlaneStub>();
    std::shared_ptr<Controller> controller = std::make_shared<Controller>(stub);

    /// Registers one request, dispatches @p n jobs for it, and returns once they have drained.
    bool run(uint64_t requestId, uint64_t n, const OpResult& answer)
    {
        const uint64_t before = stub->calls();
        stub->answerWith(answer);
        controller->noteRequestEnqueued(requestId, n);
        std::vector<FlowJob> jobs;
        for (uint64_t i = 0; i < n; ++i)
        {
            jobs.push_back(dispatchJob(requestId));
        }
        controller->dispatcher().enqueue(std::move(jobs));
        return waitForCalls(*stub, before + n);
    }
};

} // namespace

/**
 * @brief Suite fixture, for one reason: the logger.
 *
 * [Co-developed with claude code -- Adam]
 * Logger::instance() is a static shared_ptr that is null until Logger::init runs, and
 * SPDLOG_LOGGER_* dereferences it. These tests drive Controller's sender from worker threads,
 * which logs on a failed dispatch, so an ordering assumption about which suite ran first would be
 * a crash rather than a failure. init() is idempotent -- same argument as the note in
 * tests/test_SwitchKindDispatch.cpp.
 */
class DispatchStatusEndpointTest : public ::testing::Test
{
  protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

TEST_F(DispatchStatusEndpointTest, TheCountersAreNamedForWhatTheyCount)
{
    // #54's A half, on the wire. `succeeded` is gone: the same match dispatched twice moves this
    // by +2 while a switch gains one row, and the old name asserted the opposite.
    DispatchFixture fx;
    ASSERT_TRUE(fx.run(1, 2, OpResult::success()));

    HttpSessionTestPeer peer(fx.controller);
    const auto& res = peer.send(http::verb::get, "/ndt/get_flow_dispatch_status");
    ASSERT_EQ(res.result_int(), 200u) << "body: " << res.body();

    const auto body = nlohmann::json::parse(res.body());
    const auto& counters = body.at("counters");
    EXPECT_EQ(counters.value("dispatched", 0u), 2u);
    EXPECT_EQ(counters.value("dispatched_ok", 0u), 2u);
    EXPECT_EQ(counters.value("dispatch_failed", 1u), 0u);
    EXPECT_FALSE(counters.contains("succeeded"))
        << "the old name states a claim this counter cannot make; emitting it keeps the claim "
           "alive for every caller that reads it";
    EXPECT_FALSE(counters.contains("failed"));
    // The breadcrumb, so a script that just started reading null can find out where its key went.
    EXPECT_EQ(body.at("renamed_keys").value("succeeded", std::string{}),
              "counters.dispatched_ok");
}

TEST_F(DispatchStatusEndpointTest, AnOvsFabricReportsUnknownAtTheSwitchAndSaysWhy)
{
    // W11's B half. Ryu's 200 is not evidence about a switch, so the second group says `unknown`
    // -- and says why in the body, because a permanently-unknown number with no explanation next
    // to it is read as "checked, nothing wrong".
    DispatchFixture fx;
    ASSERT_TRUE(fx.run(1, 3, OpResult::success()));

    HttpSessionTestPeer peer(fx.controller);
    const auto& res = peer.send(http::verb::get, "/ndt/get_flow_dispatch_status");
    ASSERT_EQ(res.result_int(), 200u) << "body: " << res.body();

    const auto body = nlohmann::json::parse(res.body());
    const auto& sw = body.at("switch_outcome");
    EXPECT_EQ(sw.value("unknown", 0u), 3u);
    EXPECT_EQ(sw.value("accepted_by_switch", 99u), 0u)
        << "dispatch is not programming; if this ever equals dispatched_ok on OVS, the second "
           "group has been wired to the first";
    EXPECT_EQ(sw.value("rejected_by_switch", 99u), 0u);
    EXPECT_NE(sw.value("why_unknown", std::string{}).find("does not acknowledge a FLOW_MOD"),
              std::string::npos)
        << "the reason has to travel with the number: " << sw.dump();

    // Both groups partition the same population, and the second is not part of the first.
    EXPECT_EQ(sw.value("accepted_by_switch", 0u) + sw.value("rejected_by_switch", 0u) +
                  sw.value("unknown", 0u),
              body.at("counters").value("dispatched", 0u));
}

TEST_F(DispatchStatusEndpointTest, AConfirmingPlaneReportsAnAcceptanceBySwitch)
{
    // The control for the test above: `unknown` is a reading, not a constant.
    DispatchFixture fx;
    ASSERT_TRUE(fx.run(1, 1, OpResult::success().withProgrammingConfirmed(true)));

    HttpSessionTestPeer peer(fx.controller);
    const auto body = nlohmann::json::parse(
        peer.send(http::verb::get, "/ndt/get_flow_dispatch_status").body());

    EXPECT_EQ(body.at("switch_outcome").value("accepted_by_switch", 0u), 1u);
    EXPECT_EQ(body.at("switch_outcome").value("unknown", 99u), 0u);
}

TEST_F(DispatchStatusEndpointTest, ARequestIdAnswersForThatBatchAlone)
{
    // R6 K-4: the counters are process-wide, so a caller cannot attribute them to its own POST.
    // Two batches with different outcomes; each id must see only its own.
    DispatchFixture fx;
    ASSERT_TRUE(fx.run(41, 2, OpResult::success()));
    ASSERT_TRUE(fx.run(42, 3, OpResult::failure(400, "refused")));

    HttpSessionTestPeer peer(fx.controller);
    const auto& first = peer.send(http::verb::get, "/ndt/get_flow_dispatch_status?request_id=41");
    ASSERT_EQ(first.result_int(), 200u) << "body: " << first.body();
    const auto firstBody = nlohmann::json::parse(first.body());
    EXPECT_EQ(firstBody.value("request_id", 0u), 41u);
    EXPECT_EQ(firstBody.at("counters").value("dispatched", 0u), 2u);
    EXPECT_EQ(firstBody.at("counters").value("dispatch_failed", 9u), 0u);
    EXPECT_TRUE(firstBody.value("complete", false));

    HttpSessionTestPeer peer2(fx.controller);
    const auto second = nlohmann::json::parse(
        peer2.send(http::verb::get, "/ndt/get_flow_dispatch_status?request_id=42").body());
    EXPECT_EQ(second.at("counters").value("dispatched", 0u), 3u);
    EXPECT_EQ(second.at("counters").value("dispatch_failed", 0u), 3u)
        << "the first batch's successes must not leak into the second batch's answer";
    EXPECT_EQ(second.at("counters").value("dispatched_ok", 9u), 0u);
    EXPECT_EQ(second.value("enqueued", 0u), 3u);
}

TEST_F(DispatchStatusEndpointTest, AnUnknownRequestIdIsNotAnswered200)
{
    // A caller that reads only the status code would take a 200 as "your request is fine" for a
    // request this kernel has never heard of -- the over-claim processFlowBatch already answers
    // 404 for when no entry is applicable.
    DispatchFixture fx;
    HttpSessionTestPeer peer(fx.controller);
    const auto& res = peer.send(http::verb::get, "/ndt/get_flow_dispatch_status?request_id=777");

    EXPECT_EQ(res.result_int(), 404u) << "body: " << res.body();
    const auto body = nlohmann::json::parse(res.body());
    EXPECT_EQ(body.value("error", std::string{}), "unknown request_id");
    // Which of the two reasons is possible, because they lead to different actions.
    EXPECT_TRUE(body.contains("request_ids_forgotten"));
}

TEST_F(DispatchStatusEndpointTest, ANonNumericRequestIdIsAClientErrorNotAServerError)
{
    // The reason this file exists, applied to the new parameter: std::stoull would throw
    // std::invalid_argument into buildResponse's std::exception clause and answer 500.
    DispatchFixture fx;
    HttpSessionTestPeer peer(fx.controller);
    const auto& res = peer.send(http::verb::get, "/ndt/get_flow_dispatch_status?request_id=abc");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
}

TEST_F(DispatchStatusEndpointTest, TheRouteAcceptsAQueryStringAtAll)
{
    // The route was an exact string compare, so any query fell through every branch to the
    // not-found tail: the endpoint could not have grown a parameter without this. Asserted
    // through a parameter the handler rejects, so only the ROUTING is under test -- a 404 here
    // would mean the request never reached the handler.
    DispatchFixture fx;
    HttpSessionTestPeer peer(fx.controller);
    const auto& res = peer.send(http::verb::get, "/ndt/get_flow_dispatch_status?request_id=");

    EXPECT_NE(res.result_int(), 404u) << "body: " << res.body();
    EXPECT_EQ(res.result_int(), 200u) << "an empty value is an absent one; queryParam cannot tell "
                                         "them apart, so this is the process-wide answer";
}

// --- B-6: a declared link failure must survive the topology poll, and say why it is down --------
// [Co-developed with claude code -- Adam]
//
// The unit-level behaviour is in tests/test_PollDoesNotResurrect.cpp, which drives the monitor's
// writers directly. This case is here because it is the only one that runs the WHOLE path an
// operator runs -- POST /ndt/link_failure_detected, a topology poll, GET /ndt/get_graph_data --
// and because two of the three steps are decided by HttpSession: which monitor call the push path
// makes, and which string the edge's `down_reason` is serialised from. A test that reached the
// monitor directly cannot see either, which is the same argument that put the app_id cases above
// in this file.
//
// Measured 2026-09-04 (R2-B): the endpoint answered 200, both directions read is_up=false within
// 0.02 s, and 5 trials of 5 flipped back to is_up=true within 30 s -- each one just after a poll,
// with /ndt/link_recovery_detected never called.

namespace
{

/**
 * @brief Captures every record the global logger emits while it is alive, at trace level.
 *
 * [Co-developed with claude code -- Adam]
 * Restores the logger's previous level and sink list on destruction, so the rest of the suite runs
 * against the `off` level test_LoggerEnvironment installed. Same helper as
 * tests/test_NetemLinkFault.cpp, tests/test_TopologyPollRound.cpp and
 * tests/test_ApiKeyNotLogged.cpp; duplicated rather than shared for the reason written there --
 * hoisting it would create a test-support header several files then have to agree on.
 */
class LogCapture
{
  public:
    LogCapture()
        : m_logger(Logger::instance()),
          m_savedLevel(m_logger->level()),
          m_sink(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(256))
    {
        m_logger->sinks().push_back(m_sink);
        m_logger->set_level(spdlog::level::trace);
    }

    ~LogCapture()
    {
        m_logger->set_level(m_savedLevel);
        auto& sinks = m_logger->sinks();
        for (auto it = sinks.begin(); it != sinks.end(); ++it)
        {
            if (*it == m_sink)
            {
                sinks.erase(it);
                break;
            }
        }
    }

    LogCapture(const LogCapture&) = delete;
    LogCapture& operator=(const LogCapture&) = delete;

    std::string text() const
    {
        std::string all;
        for (const auto& line : m_sink->last_formatted())
        {
            all += line;
        }
        return all;
    }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    spdlog::level::level_enum m_savedLevel;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> m_sink;
};

/// Exposes the protected discovery writer, so a case can apply one control-plane poll.
class PollableMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;
    void pollLinks(const std::string& json) { updateLinks(json); }
};

class DeclaredLinkFailureWireTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        m_graph = std::make_shared<Graph>();
        m_bus = std::make_shared<EventBus>();
        m_monitor = std::make_shared<PollableMonitor>(
            m_graph, std::make_shared<std::shared_mutex>(), m_bus, utils::MININET);

        const auto s1 = addSwitch(1, "s1");
        const auto s5 = addSwitch(5, "s5");
        addEdge(s1, s5, 1, 5);
        addEdge(s5, s1, 5, 1);

        // [Co-developed with claude code -- Adam]
        // W8-7. A host, and the pair of edges that hang it off s1 on a DIFFERENT port. It is here
        // so the dpid-0 cases below have something to hit: a host vertex carries dpid 0, and
        // findEdgeBySrcAndDstDpid matches on the two dpids alone, so without the refusal
        // `{"src_dpid":1,"dst_dpid":0}` RESOLVES -- to whichever host edge of s1 comes first --
        // and the endpoint answers 200 having declared a link the caller never named. A fixture
        // with no host edge would turn the same request into a 404 and the cases would then be
        // pinning "not found" rather than "refused".
        const auto h1 = addHost(kHostIp);
        addEdge(s1, h1, 1, kHostDpid, 2, 1);
        addEdge(h1, s1, kHostDpid, 1, 1, 2);
    }

    Graph::vertex_descriptor addSwitch(uint64_t dpid, const std::string& bridge)
    {
        VertexProperties vp;
        vp.vertexType = VertexType::SWITCH;
        vp.dpid = dpid;
        vp.isUp = true;
        vp.isEnabled = true;
        vp.deviceName = bridge;
        vp.bridgeNameForMininet = bridge;
        return boost::add_vertex(vp, *m_graph);
    }

    /// A host vertex: dpid 0, which is the whole point of the W8-7 cases.
    Graph::vertex_descriptor addHost(uint32_t ip)
    {
        VertexProperties vp;
        vp.vertexType = VertexType::HOST;
        vp.dpid = kHostDpid;
        vp.isUp = true;
        vp.isEnabled = true;
        vp.deviceName = "h1";
        vp.ip = {ip};
        return boost::add_vertex(vp, *m_graph);
    }

    void addEdge(Graph::vertex_descriptor u,
                 Graph::vertex_descriptor v,
                 uint64_t srcDpid,
                 uint64_t dstDpid,
                 uint32_t srcPort = 1,
                 uint32_t dstPort = 1)
    {
        EdgeProperties ep;
        ep.srcDpid = srcDpid;
        ep.dstDpid = dstDpid;
        ep.srcInterface = srcPort;
        ep.dstInterface = dstPort;
        ep.isUp = true;
        ep.isEnabled = true;
        boost::add_edge(u, v, ep, *m_graph);
    }

    /// What /ndt/get_graph_data publishes for the (src, dst) edge.
    nlohmann::json edgeFromGraphData(HttpSessionTestPeer& peer, uint64_t src, uint64_t dst)
    {
        const auto& res = peer.send(http::verb::get, "/ndt/get_graph_data");
        EXPECT_EQ(res.result_int(), 200u) << res.body();
        const auto doc = nlohmann::json::parse(res.body(), nullptr, false);
        EXPECT_FALSE(doc.is_discarded()) << "get_graph_data did not return JSON: " << res.body();
        if (doc.is_discarded()) return {};
        for (const auto& e : doc.at("edges"))
        {
            if (e.value("src_dpid", 0ull) == src && e.value("dst_dpid", 0ull) == dst)
            {
                return e;
            }
        }
        ADD_FAILURE() << "edge " << src << " -> " << dst << " is not in get_graph_data";
        return {};
    }

    /// Ryu's /v1.0/topology/links reply for this pair -- unchanged by the declaration, which is
    /// the whole point: declaring a failure gives the control plane nothing to notice.
    static const char* kLinkListing()
    {
        return R"([{"src":{"dpid":"0000000000000001","port_no":"00000001"},)"
               R"("dst":{"dpid":"0000000000000005","port_no":"00000001"}},)"
               R"({"src":{"dpid":"0000000000000005","port_no":"00000001"},)"
               R"("dst":{"dpid":"0000000000000001","port_no":"00000001"}}])";
    }

    static constexpr const char* kBody =
        R"({"src_dpid":1,"src_interface":1,"dst_dpid":5,"dst_interface":1})";

    /// [Co-developed with claude code -- Adam] W8-7. The degenerate payload: s1 to "the host end",
    /// which names no particular edge at all. 10.0.0.1 in host order.
    static constexpr const char* kHostEdgeBody =
        R"({"src_dpid":1,"src_interface":2,"dst_dpid":0,"dst_interface":1})";
    static constexpr uint64_t kHostDpid = 0;
    static constexpr uint32_t kHostIp = 0x0A000001;

    /// Every endpoint that addresses a link by its two dpids. All four refuse dpid 0.
    static std::vector<std::string> linkEndpoints()
    {
        return {"/ndt/link_failure_detected",
                "/ndt/link_recovery_detected",
                "/ndt/inject_link_failure",
                "/ndt/inject_link_recovery"};
    }

    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<EventBus> m_bus;
    std::shared_ptr<PollableMonitor> m_monitor;
};

} // namespace

TEST_F(DeclaredLinkFailureWireTest, ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy)
{
    HttpSessionTestPeer peer(m_monitor, m_bus);

    ASSERT_EQ(peer.send(http::verb::post, "/ndt/link_failure_detected", kBody).result_int(), 200u);
    ASSERT_FALSE(edgeFromGraphData(peer, 1, 5).value("is_up", true))
        << "the endpoint did not take the link down at all";

    // The reply Ryu goes on serving, because nothing about the fabric changed.
    m_monitor->pollLinks(kLinkListing());

    const auto fwd = edgeFromGraphData(peer, 1, 5);
    const auto rev = edgeFromGraphData(peer, 5, 1);
    EXPECT_FALSE(fwd.value("is_up", true))
        << "a topology poll resurrected a link an operator declared failed -- the injection ends "
           "when the control plane's list is next applied rather than when it is withdrawn (B-6)";
    EXPECT_FALSE(rev.value("is_up", true)) << "the reverse direction came back";
    EXPECT_EQ(fwd.value("down_reason", ""), "declared")
        << "the reason must reach the wire: a permanent state nobody can query for is how a "
           "forgotten injection becomes an unexplained result";
    EXPECT_EQ(rev.value("down_reason", ""), "declared");
}

TEST_F(DeclaredLinkFailureWireTest, ARecoveryWithdrawsTheDeclarationAndTheNextPollRaisesTheLink)
{
    HttpSessionTestPeer peer(m_monitor, m_bus);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/link_failure_detected", kBody).result_int(), 200u);
    m_monitor->pollLinks(kLinkListing());
    ASSERT_FALSE(edgeFromGraphData(peer, 1, 5).value("is_up", true));

    ASSERT_EQ(peer.send(http::verb::post, "/ndt/link_recovery_detected", kBody).result_int(), 200u);

    const auto afterRecovery = edgeFromGraphData(peer, 1, 5);
    EXPECT_TRUE(afterRecovery.value("is_up", false)) << "recovery did not bring the link back";
    EXPECT_EQ(afterRecovery.value("down_reason", ""), "none")
        << "an edge that is up must not carry a reason for being down";

    // And the poll may lift it again, which is what says the declaration was really spent rather
    // than merely overwritten.
    m_monitor->pollLinks(kLinkListing());
    EXPECT_TRUE(edgeFromGraphData(peer, 1, 5).value("is_up", false));
}

// --- B-6, the injection endpoints ---------------------------------------------------------------

/**
 * The physical lab gets the declaration and nothing else -- there is no netem to attach to a
 * cable. What matters is that the reply SAYS the fabric was not touched: a caller reading only the
 * status code would otherwise believe the packets had stopped.
 */
TEST_F(DeclaredLinkFailureWireTest, InjectOutsideMininetDeclaresAndSaysTheCutWasSkipped)
{
    HttpSessionTestPeer peer(m_monitor, m_bus, utils::TESTBED);

    const auto& res = peer.send(http::verb::post, "/ndt/inject_link_failure", kBody);

    ASSERT_EQ(res.result_int(), 200u) << res.body();
    const auto body = nlohmann::json::parse(res.body(), nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << res.body();
    EXPECT_EQ(body.value("tc", ""), "skipped (not MININET)")
        << "the reply must not imply a cut that did not happen: " << res.body();
    EXPECT_EQ(body.value("down_reason", ""), "declared");

    // The declaration half still happened, and still survives the poll.
    m_monitor->pollLinks(kLinkListing());
    HttpSessionTestPeer reader(m_monitor, m_bus);
    EXPECT_FALSE(edgeFromGraphData(reader, 1, 5).value("is_up", true));
    EXPECT_FALSE(edgeFromGraphData(reader, 5, 1).value("is_up", true));
}

TEST_F(DeclaredLinkFailureWireTest, InjectRecoveryOutsideMininetWithdrawsTheDeclaration)
{
    HttpSessionTestPeer peer(m_monitor, m_bus, utils::TESTBED);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/inject_link_failure", kBody).result_int(), 200u);

    const auto& res = peer.send(http::verb::post, "/ndt/inject_link_recovery", kBody);
    ASSERT_EQ(res.result_int(), 200u) << res.body();

    m_monitor->pollLinks(kLinkListing());
    HttpSessionTestPeer reader(m_monitor, m_bus);
    const auto fwd = edgeFromGraphData(reader, 1, 5);
    EXPECT_TRUE(fwd.value("is_up", false)) << "the injection was never withdrawn";
    EXPECT_EQ(fwd.value("down_reason", ""), "none");
}

/**
 * The injection endpoints refuse BEFORE changing anything when the pair is broken, unlike their
 * notification siblings. An injection that half-happened would leave the graph and the machine's
 * qdisc tree in a state the caller did not ask for and cannot name.
 */
TEST_F(DeclaredLinkFailureWireTest, InjectWithNoSuchEdgeChangesNothing)
{
    HttpSessionTestPeer peer(m_monitor, m_bus, utils::TESTBED);

    const auto& res = peer.send(http::verb::post,
                                "/ndt/inject_link_failure",
                                R"({"src_dpid":7,"src_interface":1,"dst_dpid":9,)"
                                R"("dst_interface":1})");

    EXPECT_EQ(res.result_int(), 404u) << res.body();
    HttpSessionTestPeer reader(m_monitor, m_bus);
    EXPECT_TRUE(edgeFromGraphData(reader, 1, 5).value("is_up", false))
        << "a 404 on one edge disturbed another";
}

TEST_F(DeclaredLinkFailureWireTest, InjectWithAnInvalidPayloadIsRejected)
{
    HttpSessionTestPeer peer(m_monitor, m_bus, utils::TESTBED);

    EXPECT_EQ(peer.send(http::verb::post, "/ndt/inject_link_failure", R"({"src_dpid":1})")
                  .result_int(),
              400u);
    EXPECT_EQ(peer.send(http::verb::post, "/ndt/inject_link_recovery", "not json").result_int(),
              400u);
}

// --- B-6 W8b: a withdrawal has to pair with a reported break -------------------------------------
// [Co-developed with claude code -- Adam]
//
// The wire half of the rule Adam settled on 2026-09-07 after the lw8b live arm. These cases run
// the endpoints, because the decision is made in HttpSession -- which monitor call each push path
// takes, and what the reply says when a recovery report is declined. The state-machine half is in
// tests/test_PollDoesNotResurrect.cpp.
//
// Measured 2026-09-07 00:08 (scratch/overnight-2026-09-05/logs/live-round2-console.log, arm lw8b):
// killing Ryu and restarting it with the same argv made intelligent_router.py's on_link_add POST
// /ndt/link_recovery_detected for EVERY link within a second of the controller coming back, and
// the standing declaration was gone in 9 of 9 samples over the next 90 s.

/**
 * 🔴 THE FINDING, end to end and in the shape the live arm ran it: an injection is standing, the
 * control plane restarts, and one recovery report per link arrives for links nobody said broke.
 * The declaration must still be there afterwards, and a poll must still decline the edge.
 */
TEST_F(DeclaredLinkFailureWireTest, ARyuRestartDoesNotWithdrawAnInjectedLinkFailure)
{
    // TESTBED so no tc runs here; the declaration half is identical in both modes and is the half
    // under test. On MININET this is the dangerous case: the netem stays attached.
    HttpSessionTestPeer injector(m_monitor, m_bus, utils::TESTBED);
    ASSERT_EQ(injector.send(http::verb::post, "/ndt/inject_link_failure", kBody).result_int(), 200u);
    ASSERT_FALSE(edgeFromGraphData(injector, 1, 5).value("is_up", true));

    // What Ryu POSTs for this link the instant LLDP rediscovers it after a restart.
    HttpSessionTestPeer peer(m_monitor, m_bus);
    // 🔴 The body is COPIED here, not held by reference. HttpSessionTestPeer::send replaces the
    // response it owns, so a `const auto&` taken from one send dangles the moment the next one
    // runs -- and the assertions below deliberately send again (get_graph_data) before checking
    // what this reply said.
    std::string recoveryBody;
    unsigned recoveryStatus = 0;
    {
        const auto& res = peer.send(http::verb::post, "/ndt/link_recovery_detected", kBody);
        recoveryStatus = res.result_int();
        recoveryBody = res.body();
    }
    ASSERT_EQ(recoveryStatus, 200u) << recoveryBody;

    m_monitor->pollLinks(kLinkListing());

    const auto fwd = edgeFromGraphData(peer, 1, 5);
    const auto rev = edgeFromGraphData(peer, 5, 1);
    EXPECT_FALSE(fwd.value("is_up", true))
        << "a bare rediscovery ended an injection: restarting the control plane withdrew a "
           "declaration nothing ever reported broken, and on MININET the tc netem that "
           "accompanies /ndt/inject_link_failure would still be attached (B-6, W8b)";
    EXPECT_FALSE(rev.value("is_up", true)) << "the reverse direction was withdrawn";
    EXPECT_EQ(fwd.value("down_reason", ""), "declared");

    // 🔴 And the reply must SAY so. A 200 whose body reads "link recovery processed" while the
    // link is deliberately still down is the kernel disagreeing with itself where only the body
    // can tell anyone.
    const auto body = nlohmann::json::parse(recoveryBody, nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << recoveryBody;
    EXPECT_TRUE(body.value("declaration_retained", false))
        << "the recovery was declined and the reply did not say so: " << recoveryBody;
}

/**
 * Direction 2, on the wire: the notification pair must still work end to end. /ndt/link_failure_-
 * detected records the report, and its own /ndt/link_recovery_detected spends it and raises the
 * link. Losing this makes every real link outage permanent.
 */
TEST_F(DeclaredLinkFailureWireTest, AReportedFailureIsStillWithdrawnByItsOwnRecovery)
{
    HttpSessionTestPeer peer(m_monitor, m_bus);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/link_failure_detected", kBody).result_int(), 200u);
    ASSERT_FALSE(edgeFromGraphData(peer, 1, 5).value("is_up", true));

    const auto& res = peer.send(http::verb::post, "/ndt/link_recovery_detected", kBody);
    ASSERT_EQ(res.result_int(), 200u) << res.body();
    const auto body = nlohmann::json::parse(res.body(), nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << res.body();
    EXPECT_FALSE(body.value("declaration_retained", false))
        << "a recovery that pairs with a reported failure reported itself declined: " << res.body();

    const auto fwd = edgeFromGraphData(peer, 1, 5);
    EXPECT_TRUE(fwd.value("is_up", false))
        << "the pairing rule swallowed the ordinary case: a failure the control plane reported "
           "was not withdrawn by the recovery that answers it";
    EXPECT_EQ(fwd.value("down_reason", ""), "none");
}

/**
 * The way out of a retained declaration, which is the endpoint the declined reply names. If this
 * stopped working an injection that survived a controller restart would survive everything.
 */
TEST_F(DeclaredLinkFailureWireTest, InjectRecoveryStillWithdrawsAfterARefusedRediscovery)
{
    HttpSessionTestPeer peer(m_monitor, m_bus, utils::TESTBED);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/inject_link_failure", kBody).result_int(), 200u);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/link_recovery_detected", kBody).result_int(), 200u);
    ASSERT_FALSE(edgeFromGraphData(peer, 1, 5).value("is_up", true));

    ASSERT_EQ(peer.send(http::verb::post, "/ndt/inject_link_recovery", kBody).result_int(), 200u);

    m_monitor->pollLinks(kLinkListing());
    const auto fwd = edgeFromGraphData(peer, 1, 5);
    EXPECT_TRUE(fwd.value("is_up", false))
        << "the operator's own withdrawal did not end an injection the rediscovery rule had "
           "deliberately kept alive -- the declaration is then unwithdrawable";
    EXPECT_EQ(fwd.value("down_reason", ""), "none");
}

// --- 3-52: the log line has to carry the outcome -------------------------------------------------
// [Co-developed with claude code -- Adam]
//
// Adam's ruling E-22, 2026-09-07. handleLinkRecovery logged `link recovered on <s>:<p> -> <d>:<p>`
// BEFORE it looked the edge up and before the pairing rule ran, so a report that was declined, one
// that was applied, and one naming an edge the graph does not hold were the SAME sentence in
// kernel.log -- and that sentence asserted the outcome.
//
// 🟢 MEASURED, arm lw8b2 2026-09-07 (scratch/overnight-2026-09-05/logs/lw8b2-kernel.log):
//     04:33:37.198  DECLINED  link recovered on 1:1 -> 5:1
//     04:33:38.131  APPLIED   link recovered on 1:1 -> 5:1
//     04:33:38.142  APPLIED   link recovered on 5:1 -> 1:1
// The monitor's own WARN did follow the declined one at .198, which is why the fix is "say the
// outcome" rather than "say something": two adjacent lines that contradict each other still leave
// a reader to work out which one is the answer.
//
// These cases assert on the LOG. The wire is unchanged and is pinned by the cases above: same
// status codes, same bodies, same graph. A case that reddens here for a reworded sentence would be
// wrong too, so each one keys on the word that carries the outcome and not on the prose around it.

TEST_F(DeclaredLinkFailureWireTest, ADeclinedRecoveryIsNotLoggedAsARecovery)
{
    HttpSessionTestPeer peer(m_monitor, m_bus, utils::TESTBED);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/inject_link_failure", kBody).result_int(), 200u);

    std::string logged;
    {
        LogCapture log;
        const auto& res = peer.send(http::verb::post, "/ndt/link_recovery_detected", kBody);
        ASSERT_EQ(res.result_int(), 200u) << res.body();
        logged = log.text();
    }

    EXPECT_EQ(logged.find("link recovered on"), std::string::npos)
        << "a recovery report the pairing rule DECLINED logged the sentence an applied one logs, "
           "so kernel.log says the injection ended while the graph still holds it down. Measured "
           "verbatim on arm lw8b2 at 04:33:37.198 (3-52). Log was:\n"
        << logged;
    EXPECT_NE(logged.find("declaration was retained"), std::string::npos)
        << "the endpoint declined the report and said so only in the reply body, which is not what "
           "anyone reads afterwards:\n"
        << logged;

    // The behaviour this ticket must NOT change: a moved log line is all it is.
    EXPECT_FALSE(edgeFromGraphData(peer, 1, 5).value("is_up", true))
        << "the declined recovery raised the link after all";
}

TEST_F(DeclaredLinkFailureWireTest, AnAppliedRecoveryLogsThatTheDeclarationWentAway)
{
    HttpSessionTestPeer peer(m_monitor, m_bus);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/link_failure_detected", kBody).result_int(), 200u);

    std::string logged;
    {
        LogCapture log;
        const auto& res = peer.send(http::verb::post, "/ndt/link_recovery_detected", kBody);
        ASSERT_EQ(res.result_int(), 200u) << res.body();
        logged = log.text();
    }

    EXPECT_NE(logged.find("was withdrawn"), std::string::npos)
        << "the recovery that DID withdraw a declaration did not say so, so an applied report and "
           "a declined one are once again told apart only by the reply body:\n"
        << logged;
    EXPECT_EQ(logged.find("declaration was retained"), std::string::npos)
        << "an applied recovery logged the declined sentence:\n"
        << logged;
    EXPECT_TRUE(edgeFromGraphData(peer, 1, 5).value("is_up", false))
        << "the paired recovery did not raise the link";
}

TEST_F(DeclaredLinkFailureWireTest, ARecoveryForAnEdgeTheGraphDoesNotHoldSaysThatInstead)
{
    // The third outcome, and the one the old placement got most obviously wrong: the line was
    // written before findEdgeBySrcAndDstDpid ran, so a 404 was preceded by "link recovered on".
    HttpSessionTestPeer peer(m_monitor, m_bus);
    static constexpr const char* kUnknownEdgeBody =
        R"({"src_dpid":1,"src_interface":1,"dst_dpid":9,"dst_interface":1})";

    std::string logged;
    {
        LogCapture log;
        const auto& res =
            peer.send(http::verb::post, "/ndt/link_recovery_detected", kUnknownEdgeBody);
        ASSERT_EQ(res.result_int(), 404u) << res.body();
        logged = log.text();
    }

    EXPECT_EQ(logged.find("link recovered on"), std::string::npos)
        << "a report naming a link this topology does not hold was logged as a recovery:\n"
        << logged;
    EXPECT_NE(logged.find("no such edge"), std::string::npos)
        << "the 404 went out with nothing in the log to say the caller had named a link that is "
           "not in the graph:\n"
        << logged;
}

// --- B-6 W8-7: dpid 0 is the host end, and no link endpoint addresses a host edge -----------------
// [Co-developed with claude code -- Adam]
//
// Adam's ruling, 2026-09-06 (grill §4D seventh round, after re-asking): the endpoints must refuse
// it. A host vertex carries dpid 0 and findEdgeBySrcAndDstDpid matches on the two dpids alone, so
// `{"src_dpid":1,"dst_dpid":0}` picks whichever host edge of s1 the graph iterates first -- the
// caller cannot say which one they meant and the kernel does not tell them which one it took. The
// declaration then lands on an edge updateHosts raises again on its next pass, because the veto
// added for B-6 lives in updateLinks where links do: B-6 all over again, on the one edge shape the
// fix does not reach. Refused at the door, because this is an input-validation problem.

TEST_F(DeclaredLinkFailureWireTest, EveryLinkEndpointRefusesAHostEdgeAddressedByDpidZero)
{
    for (const auto& endpoint : linkEndpoints())
    {
        HttpSessionTestPeer peer(m_monitor, m_bus, utils::TESTBED);
        const auto& res = peer.send(http::verb::post, endpoint, kHostEdgeBody);

        EXPECT_EQ(res.result_int(), 400u)
            << endpoint << " accepted a link addressed by dpid 0. Without a refusal it resolves "
            << "to an arbitrary host edge of the other switch: " << res.body();

        const auto body = nlohmann::json::parse(res.body(), nullptr, false);
        ASSERT_FALSE(body.is_discarded()) << endpoint << " answered non-JSON: " << res.body();
        const auto message = body.value("error", std::string{});
        EXPECT_NE(message.find("dpid"), std::string::npos)
            << endpoint << " refused without naming the field that was wrong: " << res.body();
    }
}

/**
 * 🔴 The refusal has to be a refusal. `POST /ndt/link_failure_detected {"dst_dpid":0}` used to
 * answer 200 and mark a host edge down -- the shape doc/KNOWN-ISSUES.md keeps finding, a request
 * that was rejected on paper and did something anyway. Asserted from /ndt/get_graph_data, which is
 * the only place a caller could have seen it.
 */
TEST_F(DeclaredLinkFailureWireTest, ARefusedHostEdgeRequestLeavesTheHostEdgeAlone)
{
    HttpSessionTestPeer peer(m_monitor, m_bus, utils::TESTBED);
    const auto before = edgeFromGraphData(peer, 1, kHostDpid);
    ASSERT_TRUE(before.value("is_up", false)) << "the fixture's host edge did not start up";

    for (const auto& endpoint : {"/ndt/link_failure_detected", "/ndt/inject_link_failure"})
    {
        ASSERT_EQ(peer.send(http::verb::post, endpoint, kHostEdgeBody).result_int(), 400u);
        const auto after = edgeFromGraphData(peer, 1, kHostDpid);
        EXPECT_TRUE(after.value("is_up", false))
            << endpoint << " refused the request and took the host edge down anyway";
        EXPECT_EQ(after.value("down_reason", ""), "none")
            << endpoint << " refused the request and declared the host edge failed anyway";
    }
}

/**
 * Direction 2 for the refusal: it must key on dpid 0 and nothing else. A guard that refused every
 * payload -- or every one naming a host port -- would pass every case above while making the
 * endpoints useless, which is the failure mode of an input check written from the error message
 * outwards.
 */
TEST_F(DeclaredLinkFailureWireTest, TheDpidZeroRefusalDoesNotTouchOrdinarySwitchToSwitchLinks)
{
    HttpSessionTestPeer peer(m_monitor, m_bus, utils::TESTBED);
    for (const auto& endpoint : linkEndpoints())
    {
        EXPECT_EQ(peer.send(http::verb::post, endpoint, kBody).result_int(), 200u)
            << endpoint << " refused a link between two switches: " << endpoint;
    }
}

// =================================================================================================
// B-13 on the wire: /ndt/inject_link_recovery detaches only what this kernel attached, and
//                   /ndt/inject_link_failure cuts both ends or neither
//
// [Co-developed with claude code -- Adam]
//
// 🔴 MEASURED, ROLE-1 2026-09-11 00:52-01:02 CST, OVS 4-host fabric, kernel
// `sha256 356803db69af3b1b…` (scratch/overnight-2026-09-05/hunt-0911/ROLE-1-A1-REPORT.md, 3 of 3
// reproductions plus a 2-of-2 for the second finding). The reply the third round got, verbatim:
//
//     {"status":"link recovery injected","tc":[
//      {"command":"qdisc del dev s1-eth1 root","detached_at":"root","interface":"s1-eth1",
//       "ok":true,"qdisc_before":"qdisc netem 8021: root refcnt 15 limit 1000 loss 100%\n", …}]}
//
// The edge was `is_up:True / down_reason:"none"` before that request: this kernel had never
// declared it down and had never injected anything on it. `netem 8021:` was the previous
// operator's. Nothing in the reply or in kernel.log said whose it was.
//
// These cases are the wire half of that. They are in DeclaredLinkFailureWireTest so that both
// B-6 gates cover them, and they are the FIRST cases in this repository to reach the MININET
// branch of the two inject handlers: until B-13 gave HttpSession a tc seam, `realTcRunner()` was
// written inline in both handlers and `grep -rn realTcRunner tests/` found nothing (A2).
// =================================================================================================

namespace
{

/// A model of the machine's per-device qdisc trees. Duplicated from tests/test_NetemLinkFault.cpp
/// rather than shared, for the reason LogCapture is duplicated three times in this suite: hoisting
/// it would create a test-support header several files then have to agree on, and this copy answers
/// a different question (what the ENDPOINT did) from the copy there (what the helper did).
class FakeWireFabric
{
  public:
    std::vector<std::vector<std::string>> calls;

    std::string treeOf(const std::string& dev) const
    {
        for (std::size_t i = 0; i < m_devs.size(); ++i)
        {
            if (m_devs[i] == dev) return m_trees[i];
        }
        return kUnshaped;
    }

    void put(const std::string& dev, const std::string& tree)
    {
        for (std::size_t i = 0; i < m_devs.size(); ++i)
        {
            if (m_devs[i] == dev)
            {
                m_trees[i] = tree;
                return;
            }
        }
        m_devs.push_back(dev);
        m_trees.push_back(tree);
    }

    /// Somebody else's netem: at the root, with a handle this kernel never recorded. This is the
    /// state ROLE-1 created with a bare `sudo tc qdisc add dev s1-eth1 root netem loss 100%`.
    std::string attachSomebodyElsesNetem(const std::string& dev)
    {
        const std::string handle = nextHandle();
        put(dev, "qdisc netem " + handle + " root refcnt 2 limit 1000 loss 100%\n");
        return handle;
    }

    std::string handleOn(const std::string& dev) const
    {
        return utils::netem::netemHandleInTree(treeOf(dev));
    }

    bool hasNetem(const std::string& dev) const { return !handleOn(dev).empty(); }

    bool ranAnyWrite() const
    {
        for (const auto& c : calls)
        {
            if (c.size() >= 2 && (c[1] == "add" || c[1] == "del")) return true;
        }
        return false;
    }

    int writesOn(const std::string& dev) const
    {
        int n = 0;
        for (const auto& c : calls)
        {
            if (c.size() >= 4 && (c[1] == "add" || c[1] == "del") && c[3] == dev) ++n;
        }
        return n;
    }

    /// Every argv, rendered, for an assertion message.
    std::string argvLog() const
    {
        std::string out;
        for (const auto& c : calls)
        {
            out += "  " + utils::describeArgv(c) + "\n";
        }
        return out;
    }

    utils::netem::TcRunner runner()
    {
        return [this](const std::vector<std::string>& args) {
            calls.push_back(args);
            if (args.size() >= 2 && args[1] == "show")
            {
                const std::string dev = args.size() >= 4 ? args[3] : std::string();
                return utils::netem::TcOutcome{true, 0, treeOf(dev)};
            }
            if (args.size() >= 4 && args[1] == "add")
            {
                put(args[3],
                    "qdisc netem " + nextHandle() + " root refcnt 2 limit 1000 loss 100%\n");
                return utils::netem::TcOutcome{true, 0, ""};
            }
            if (args.size() >= 4 && args[1] == "del")
            {
                put(args[3], kUnshaped);
                return utils::netem::TcOutcome{true, 0, ""};
            }
            return utils::netem::TcOutcome{true, 0, ""};
        };
    }

    static constexpr const char* kUnshaped = "qdisc noqueue 0: root refcnt 2\n";

  private:
    std::string nextHandle() { return "800" + std::to_string(m_handles++) + ":"; }

    std::vector<std::string> m_devs;
    std::vector<std::string> m_trees;
    int m_handles = 1;
};

} // namespace

/**
 * 🔴 THE FINDING, VERBATIM (ROLE-1 round 3, the isolating control: no declaration, no injection,
 * one netem that belongs to somebody else). 409 and nothing run, because the alternative measured
 * on 2026-09-11 was 200 `ok:true` over a deleted `tc qdisc` that this kernel had no claim to.
 */
TEST_F(DeclaredLinkFailureWireTest, AnUndeclaredLinkWhoseNetemIsSomebodyElsesIsRefusedWith409)
{
    FakeWireFabric fabric;
    utils::netem::InjectedNetemLedger ledger;
    const std::string theirs = fabric.attachSomebodyElsesNetem("s1-eth1");

    HttpSessionTestPeer peer(m_monitor, m_bus); // MININET: the tc half is the subject here
    peer.useTcSeam(fabric.runner(), &ledger);
    ASSERT_TRUE(edgeFromGraphData(peer, 1, 5).value("is_up", false))
        << "the fixture link is already down, so this case would not be the undeclared one";

    const auto& res = peer.send(http::verb::post, "/ndt/inject_link_recovery", kBody);

    EXPECT_EQ(res.result_int(), 409u)
        << "a recovery for a link nobody declared down, carrying a netem this kernel did not "
           "attach, was accepted. That is the 2026-09-11 finding: the previous operator's fault "
           "is deleted and the reply says ok. Body: " << res.body();
    EXPECT_FALSE(fabric.ranAnyWrite())
        << "the refusal ran a command that changes the qdisc tree:\n" << fabric.argvLog();
    EXPECT_EQ(fabric.handleOn("s1-eth1"), theirs)
        << "somebody else's netem is gone from the interface";
    EXPECT_TRUE(edgeFromGraphData(peer, 1, 5).value("is_up", false))
        << "the refused request still wrote to the graph";
}

/// A refusal a caller cannot act on is a refusal that gets retried. The body names the interface,
/// says the netem is not this kernel's, and says what to do instead.
TEST_F(DeclaredLinkFailureWireTest, TheRefusalNamesTheInterfaceAndSaysWhoseNetemItIsNot)
{
    FakeWireFabric fabric;
    utils::netem::InjectedNetemLedger ledger;
    fabric.attachSomebodyElsesNetem("s5-eth1");

    HttpSessionTestPeer peer(m_monitor, m_bus);
    peer.useTcSeam(fabric.runner(), &ledger);
    const auto& res = peer.send(http::verb::post, "/ndt/inject_link_recovery", kBody);
    ASSERT_EQ(res.result_int(), 409u) << res.body();

    const auto body = nlohmann::json::parse(res.body(), nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << res.body();
    const std::string error = body.value("error", std::string());
    EXPECT_NE(error.find("s5-eth1"), std::string::npos)
        << "the refusal does not say which interface is in the way: " << res.body();
    EXPECT_NE(error.find("did not attach"), std::string::npos)
        << "the refusal does not say the netem is not this kernel's, which is the whole reason it "
           "refused: " << res.body();
}

/// The behaviour B-13 must NOT break: an operator taking back their OWN injection. Both ends were
/// cut by this kernel, so both come off, and the declaration goes with them.
TEST_F(DeclaredLinkFailureWireTest, AnInjectionThisKernelMadeIsWithdrawnAndItsNetemRemoved)
{
    FakeWireFabric fabric;
    utils::netem::InjectedNetemLedger ledger;
    HttpSessionTestPeer peer(m_monitor, m_bus);
    peer.useTcSeam(fabric.runner(), &ledger);

    const auto& injected = peer.send(http::verb::post, "/ndt/inject_link_failure", kBody);
    ASSERT_EQ(injected.result_int(), 200u) << injected.body();
    ASSERT_TRUE(fabric.hasNetem("s1-eth1")) << injected.body();
    ASSERT_TRUE(fabric.hasNetem("s5-eth1")) << injected.body();
    ASSERT_FALSE(edgeFromGraphData(peer, 1, 5).value("is_up", true)) << "the injection did not "
        "declare the link down, so the recovery below would not be withdrawing anything";

    // Snapshotted, not held by reference: send() replaces the peer's response object, so the
    // edgeFromGraphData() below would leave a reference to it dangling. (It did, and the case
    // segfaulted rather than failing -- which is why the assertions read copies.)
    unsigned status = 0;
    std::string reply;
    {
        const auto& res = peer.send(http::verb::post, "/ndt/inject_link_recovery", kBody);
        status = res.result_int();
        reply = res.body();
    }

    EXPECT_EQ(status, 200u) << reply;
    EXPECT_FALSE(fabric.hasNetem("s1-eth1")) << "this kernel would not remove its own netem: "
                                             << reply;
    EXPECT_FALSE(fabric.hasNetem("s5-eth1")) << reply;
    EXPECT_TRUE(edgeFromGraphData(peer, 1, 5).value("is_up", false))
        << "the declaration was not withdrawn";
    // The SECOND request above is the idempotent repeat, so its status line is the one asserted
    // here only because both must read `link recovery injected`; the dedicated idempotency case
    // is ASecondInjectRecoveryIsStillAnIdempotentNoop.
    const auto body = nlohmann::json::parse(reply, nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << reply;
    EXPECT_EQ(body.value("status", std::string()), "link recovery injected")
        << "the happy path's status line changed, which is a contract change (spec.py's fifth "
           "link step validates this reply): " << reply;
}

/**
 * The contract's sixth link step, pinned in-process. `inject_link_recovery` runs TWICE in
 * tools/contract_test/spec.py -- the second one proves the documented idempotency and doubles as
 * the belt-and-braces restore -- and by then nothing is declared and no netem is left. A 409 for
 * "not declared" would have broken that sequence, which is why the refusal needs a foreign netem
 * to be PRESENT and not merely a missing declaration.
 */
TEST_F(DeclaredLinkFailureWireTest, ASecondInjectRecoveryIsStillAnIdempotentNoop)
{
    FakeWireFabric fabric;
    utils::netem::InjectedNetemLedger ledger;
    HttpSessionTestPeer peer(m_monitor, m_bus);
    peer.useTcSeam(fabric.runner(), &ledger);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/inject_link_failure", kBody).result_int(), 200u);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/inject_link_recovery", kBody).result_int(), 200u);

    const auto& res = peer.send(http::verb::post, "/ndt/inject_link_recovery", kBody);

    ASSERT_EQ(res.result_int(), 200u)
        << "the second recovery was refused, so a caller cannot bring a fabric back to health "
           "without first knowing exactly what was done to it -- and the contract's step 6 fails: "
        << res.body();
    const auto body = nlohmann::json::parse(res.body(), nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << res.body();
    ASSERT_TRUE(body.contains("tc")) << res.body();
    ASSERT_EQ(body.at("tc").size(), 2u) << res.body();
    for (const auto& end : body.at("tc"))
    {
        EXPECT_TRUE(end.value("ok", false)) << res.body();
        EXPECT_FALSE(end.value("noop", std::string()).empty())
            << "removing a netem that is not there must say `noop`: " << res.body();
    }
}

/**
 * 🔴 The third state, and the one the ticket's ruling names: the link IS declared -- this kernel
 * injected it -- and somebody has since replaced the netem. The declaration is the caller's to
 * withdraw and the qdisc is not this kernel's to delete, so it does both halves and says which.
 */
TEST_F(DeclaredLinkFailureWireTest, ANetemSwappedUnderAStandingDeclarationIsLeftStandingAndSaidSo)
{
    FakeWireFabric fabric;
    utils::netem::InjectedNetemLedger ledger;
    HttpSessionTestPeer peer(m_monitor, m_bus);
    peer.useTcSeam(fabric.runner(), &ledger);
    ASSERT_EQ(peer.send(http::verb::post, "/ndt/inject_link_failure", kBody).result_int(), 200u);

    const std::string mine = fabric.handleOn("s1-eth1");
    const std::string theirs = fabric.attachSomebodyElsesNetem("s1-eth1");
    ASSERT_NE(mine, theirs) << "the fixture did not swap the qdisc";

    // Snapshotted for the reason the case above says: edgeFromGraphData() sends again.
    unsigned status = 0;
    std::string reply;
    {
        const auto& res = peer.send(http::verb::post, "/ndt/inject_link_recovery", kBody);
        status = res.result_int();
        reply = res.body();
    }

    EXPECT_EQ(status, 200u)
        << "the declaration is this caller's own and must still be withdrawable: " << reply;
    EXPECT_TRUE(edgeFromGraphData(peer, 1, 5).value("is_up", false))
        << "the declaration was retained even though the caller was entitled to withdraw it";
    EXPECT_EQ(fabric.handleOn("s1-eth1"), theirs)
        << "the netem somebody swapped in was deleted anyway:\n" << fabric.argvLog();
    const auto body = nlohmann::json::parse(reply, nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << reply;
    EXPECT_NE(body.value("status", std::string()), "link recovery injected")
        << "the reply claims the recovery was injected while a netem it did not remove is still "
           "dropping every packet on that interface: " << reply;
    ASSERT_TRUE(body.contains("netem_left_standing")) << reply;
    EXPECT_EQ(body.at("netem_left_standing").size(), 1u) << reply;
    EXPECT_EQ(body.at("netem_left_standing")[0], "s1-eth1") << reply;
}

/**
 * 🔴 THE SECOND FINDING ON THE WIRE (A1 ②, 2 of 2). s1-eth1 already carries somebody else's netem,
 * so it is refused -- and before B-13 the loop went on and really attached `netem loss 100%` to
 * s5-eth1, then answered 200 `"status":"link failure injected"` with both directions declared.
 */
TEST_F(DeclaredLinkFailureWireTest, AnInjectionRefusedAtOneEndAttachesNothingAtTheOther)
{
    FakeWireFabric fabric;
    utils::netem::InjectedNetemLedger ledger;
    const std::string theirs = fabric.attachSomebodyElsesNetem("s1-eth1");

    HttpSessionTestPeer peer(m_monitor, m_bus);
    peer.useTcSeam(fabric.runner(), &ledger);
    const auto& res = peer.send(http::verb::post, "/ndt/inject_link_failure", kBody);

    EXPECT_FALSE(fabric.hasNetem("s5-eth1"))
        << "one end was refused and the other end was cut anyway -- a unidirectional fault the "
           "caller did not ask for (faults.txt L-2), reported as `injected`:\n"
        << fabric.argvLog();
    EXPECT_EQ(fabric.writesOn("s5-eth1"), 0) << fabric.argvLog();
    EXPECT_EQ(fabric.handleOn("s1-eth1"), theirs) << "the refused end was touched anyway";
    EXPECT_EQ(res.result_int(), 200u)
        << "the declaration half succeeded, so this stays 200 and the body carries the outcome -- "
           "see the status assertion in the next case. Body: " << res.body();
}

/// The half of the same fix that is about what the caller is TOLD: `injected` is a claim about the
/// wire, and nothing was attached.
TEST_F(DeclaredLinkFailureWireTest, AHalfDoneInjectionNeverAnswersInjected)
{
    FakeWireFabric fabric;
    utils::netem::InjectedNetemLedger ledger;
    fabric.attachSomebodyElsesNetem("s1-eth1");

    HttpSessionTestPeer peer(m_monitor, m_bus);
    peer.useTcSeam(fabric.runner(), &ledger);
    const auto& res = peer.send(http::verb::post, "/ndt/inject_link_failure", kBody);
    ASSERT_EQ(res.result_int(), 200u) << res.body();

    const auto body = nlohmann::json::parse(res.body(), nullptr, false);
    ASSERT_FALSE(body.is_discarded()) << res.body();
    EXPECT_NE(body.value("status", std::string()), "link failure injected")
        << "nothing was attached to either end and the reply's top line still says the failure "
           "was injected. Measured verbatim on 2026-09-11: " << res.body();
    EXPECT_EQ(body.value("down_reason", std::string()), "declared")
        << "the declaration half did happen and the body must still say so: " << res.body();
    EXPECT_EQ(body.value("until", std::string()), "/ndt/inject_link_recovery") << res.body();
    ASSERT_TRUE(body.contains("tc")) << res.body();
    ASSERT_EQ(body.at("tc").size(), 2u) << res.body();
    EXPECT_FALSE(body.at("tc")[0].value("refused", std::string()).empty())
        << "the refused end does not say why: " << res.body();
}
