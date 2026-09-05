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
