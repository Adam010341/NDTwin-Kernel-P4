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

#include <filesystem>
#include <memory>
#include <shared_mutex>
#include <string>

#include <boost/graph/adjacency_list.hpp>
#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/data_management/HistoricalDataManager.hpp"
#include "ndt_core/http/HttpSession.hpp"
#include "ndt_core/lock_management/LockManager.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "utils/Utils.hpp"

/**
 * @brief Drives HttpSession::buildResponse() with a real LockManager and HistoricalDataManager.
 *
 * Global scope to match `friend class HttpSessionStatusTestPeer`.
 */
class HttpSessionStatusTestPeer
{
  public:
    /// @param power the real DeviceConfigurationAndPowerManager, for the power endpoints. Defaulted
    ///        to nullptr so every pre-existing caller is unchanged; the power endpoints are the
    ///        only ones that dereference it.
    HttpSessionStatusTestPeer(std::shared_ptr<LockManager> lockManager,
                              std::shared_ptr<TopologyAndFlowMonitor> monitor,
                              std::shared_ptr<HistoricalDataManager> historical,
                              std::shared_ptr<DeviceConfigurationAndPowerManager> power = nullptr)
        : m_session(std::make_shared<HttpSession>(tcp::socket(m_ioc),
                                                  std::move(monitor),
                                                  nullptr,        // EventBus
                                                  utils::MININET, // mode
                                                  nullptr,        // FlowLinkUsageCollector
                                                  nullptr,        // FlowRoutingManager
                                                  std::move(power),
                                                  nullptr, // ApplicationManager
                                                  nullptr, // SimulationRequestManager
                                                  nullptr, // IntentTranslator
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

// --- OV-3: a dpid that names no switch --------------------------------------------------------
//
// [Co-developed with claude code -- Adam]
// LockEndpointTest's graph is empty, so every dpid is unknown there -- which is what the two
// 404 cases need and is exactly why it cannot host the control. `getSwitchKind` is answered from
// m_dpidToSwitchKind, and the only thing that writes that map is the topology loader
// (TopologyAndFlowMonitor.cpp:689). So a fixture that wants a dpid the kernel KNOWS has to load
// a topology, and this is that fixture. Without it, "unknown dpid -> 404" would be satisfied by
// a handler that answered 404 to every dpid, and the endpoint would be broken in the other
// direction with a full set of green tests.

/// Exposes the protected loader, the same seam tests/test_TopologyInputValidation.cpp uses.
class LoadingMonitor : public TopologyAndFlowMonitor
{
  public:
    using TopologyAndFlowMonitor::TopologyAndFlowMonitor;

    void load(const std::string& path)
    {
        loadStaticTopologyFromFile(path);
    }
};

/// The repo's `setting/` directory, wherever the binary was started from. Same three candidates
/// and the same reason as test_TopologyInputValidation.cpp: ctest runs from the build tree,
/// l1_unit_tests.sh runs the binary from the repo root.
std::string
settingDir()
{
    static const char* kCandidates[] = {"setting", "../setting", "../../setting"};
    for (const char* candidate : kCandidates)
    {
        if (std::filesystem::is_directory(candidate))
        {
            return candidate;
        }
    }
    return {};
}

/// Switch dpids 1..10, hosts on 0. Loaded in TESTBED mode: the file carries every field, and
/// MININET adds a bridge_name requirement this test has no reason to depend on.
constexpr uint64_t kAKnownSwitchDpid = 3;

class KnownSwitchEndpointTest : public ::testing::Test
{
  protected:
    void SetUp() override
    {
        const std::string dir = settingDir();
        ASSERT_FALSE(dir.empty()) << "cannot find the repo's setting/ directory from "
                                  << std::filesystem::current_path()
                                  << " -- this test would otherwise assert over an empty graph, "
                                     "which is the very condition it exists to tell apart";

        m_locks = std::make_shared<LockManager>();
        m_graph = std::make_shared<Graph>();
        m_monitor = std::make_shared<LoadingMonitor>(m_graph,
                                                     std::make_shared<std::shared_mutex>(),
                                                     std::make_shared<EventBus>(),
                                                     utils::TESTBED);
        ASSERT_NO_THROW(m_monitor->load(dir + "/StaticNetworkTopologyP4_10Switches_4Hosts.json"));
        ASSERT_TRUE(m_monitor->getSwitchKind(kAKnownSwitchDpid).has_value())
            << "the fixture did not make dpid " << kAKnownSwitchDpid
            << " known, so the control below would pass for the wrong reason";

        m_peer = std::make_unique<HttpSessionStatusTestPeer>(m_locks, m_monitor, nullptr);
    }

    std::shared_ptr<LockManager> m_locks;
    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<LoadingMonitor> m_monitor;
    std::unique_ptr<HttpSessionStatusTestPeer> m_peer;
};

// --- OV-2: an address that names no switch ----------------------------------------------------
//
// A real DeviceConfigurationAndPowerManager over a graph this test builds by hand. Nothing here
// starts a thread and nothing reaches the machine: the constructor only builds the two power
// strategies (same construction as tests/test_CpuReportNoIpSwitch.cpp), start() is never called,
// and the one failing case below fails at getPowerStrategyForDpid -- before any command is built,
// let alone run. That matters on a shared laptop with a lab session live next door.
class PowerStateEndpointTest : public ::testing::Test
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
        addSwitch(kKnownSwitchIp, 1);
        m_power = std::make_shared<DeviceConfigurationAndPowerManager>(m_monitor,
                                                                       utils::MININET,
                                                                       "localhost",
                                                                       nullptr);
        m_peer = std::make_unique<HttpSessionStatusTestPeer>(m_locks, m_monitor, nullptr, m_power);
    }

    void addSwitch(const std::string& ip, uint64_t dpid)
    {
        const auto v = boost::add_vertex(*m_graph);
        (*m_graph)[v].vertexType = VertexType::SWITCH;
        (*m_graph)[v].dpid = dpid;
        (*m_graph)[v].isUp = true;
        (*m_graph)[v].ip.push_back(utils::ipStringToUint32(ip));
    }

    /// In the graph, so findSwitchByIp answers yes. NOT in m_dpidToSwitchKind -- nothing loaded a
    /// topology -- so getPowerStrategyForDpid returns nullptr and the power change genuinely
    /// fails. That is the state the discrimination test needs: a switch this kernel knows, whose
    /// power operation it cannot carry out.
    static constexpr const char* kKnownSwitchIp = "192.168.123.1";
    static constexpr const char* kUnknownSwitchIp = "203.0.113.9";

    std::shared_ptr<LockManager> m_locks;
    std::shared_ptr<Graph> m_graph;
    std::shared_ptr<TopologyAndFlowMonitor> m_monitor;
    std::shared_ptr<DeviceConfigurationAndPowerManager> m_power;
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
    // [Co-developed with claude code -- Adam]
    // 2 -> 3 on 2026-09-02, deliberately: B-2② adds `lease`, naming the lease this request
    // released. The count is kept as an assertion rather than relaxed -- its job is to make any
    // change to this reply a decision somebody had to write down, and this is that write-up.
    // Adding a field is non-breaking for consumers (tools/contract_test/schema.py's Obj is
    // non-strict by default and says why), which is what makes the addition acceptable at all.
    EXPECT_GT(body.value("lease", 0u), 0u) << "no lease named on a release: " << res.body();
    EXPECT_EQ(body.size(), 3u) << "the success reply gained or lost a field: " << res.body();
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
// 🔴 THE SETUP BELOW WAS AN ALREADY-EXPIRED LOCK, AND THE B-2① FIX TOOK ITS POWER AWAY.
// [Co-developed with claude code -- Adam]
// These tests used to acquire with `ttl = 0` -- expiryTime = now, so expired to the next caller
// while still isLocked -- and read "the lease was NOT extended" off a subsequent acquire
// succeeding. That worked only because renew() would revive an expired lease: a request that
// leaked through to routing_lock put it back in force and the acquire failed.
//
// Since 2026-09-01 renew() refuses an expired lease (KNOWN-ISSUES B-2①). On that setup a leaked
// renew is now refused too, so the acquire succeeds whether or not the parser substituted
// routing_lock -- the same answer either way, which is no evidence at all.
//
// So the setup is a LIVE lock now, and the discriminator is the reply: a leaked renew answers
// 200 {"status":"renewed","type":"routing_lock"}, a correctly refused one answers 400 and names
// what the caller sent. That is the loudest available difference and it needs no wall clock.
// ⇒ When a fix lands, re-ask what the tests around it were subtracting; a test can keep passing
// because the thing it was measuring stopped existing.
//
// ⚠️ The probe is the exact key `"status":"renewed"`, not the word "renewed". describeError()
// puts the endpoint's past participle INTO the refusal sentence on purpose -- "...no lock was
// renewed" -- so a substring search for the bare word matches the correct 400 as readily as the
// leaked 200. Written down because the loose version was tried first and all three tests went
// red against a working handler.

TEST_F(LockEndpointTest, ARenewWithAMalformedBodyDoesNotExtendTheDefaultLock)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 3600)) << "held by somebody, and in force";

    const auto& res = m_peer->send(http::verb::post, "/ndt/renew_lock", "{not json");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_EQ(res.body().find(R"("status":"renewed")"), std::string::npos)
        << "the malformed renew extended routing_lock's lease: " << res.body();
}

TEST_F(LockEndpointTest, ARenewWithNoTypeFieldDoesNotExtendTheDefaultLock)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 3600));

    const auto& res = m_peer->send(http::verb::post, "/ndt/renew_lock", R"({"ttl":30})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_EQ(res.body().find(R"("status":"renewed")"), std::string::npos)
        << "a ttl with no type extended routing_lock -- the caller named a duration, not a lock";
}

/// The renew twin of ABodylessReleaseDoesNotReleaseSomebodyElsesRoutingLock.
TEST_F(LockEndpointTest, ABodylessRenewDoesNotExtendSomebodyElsesRoutingLock)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 3600)) << "another app's, in force";
    ASSERT_TRUE(m_locks->acquireLock("power_lock", 0)) << "the caller's own, already run out";

    const auto& res = m_peer->send(http::verb::post, "/ndt/renew_lock", "");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_EQ(res.body().find(R"("status":"renewed")"), std::string::npos)
        << "a bodyless renew extended a routing lease its caller never named";
    // and the caller's own lock is no better off for having asked wrongly -- which is the
    // honest outcome, and the one it can detect from a 400
    EXPECT_TRUE(m_locks->acquireLock("power_lock", 30));
}

TEST_F(LockEndpointTest, ARenewNamingAnUnknownLockTypeIsARequestErrorNotAStateError)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 3600));

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/renew_lock",
                                   R"({"type":"no_such_lock_type_exists","ttl":30})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_EQ(res.body().find(R"("status":"renewed")"), std::string::npos)
        << "an unknown lock name extended routing_lock's lease";
}

/**
 * The endpoint-level twin of LockManagerTest.RenewingAnExpiredLeaseIsRefusedRatherThanResurrecting
 * It. KNOWN-ISSUES B-2①: this request used to answer 200 "renewed", and the caller sending it
 * need never have held the lock -- renew takes a name, not a holder. The lock then stayed
 * unavailable to everyone else for the whole new TTL on behalf of a client that had gone away.
 *
 * 412 rather than 400 on purpose: an expired lease is a STATE the caller can fix by acquiring,
 * which is exactly the distinction the four tests above are protecting from the other side.
 */
TEST_F(LockEndpointTest, RenewingAnExpiredLeaseIs412AndLeavesTheLockAcquirable)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 0)) << "held, and already run out";

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/renew_lock",
                                   R"({"type":"routing_lock","ttl":120})");

    EXPECT_EQ(res.result_int(), 412u) << "body: " << res.body();
    EXPECT_TRUE(m_locks->acquireLock("routing_lock", 30))
        << "the expired lease was put back in force, locking out a legitimate acquire";
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
    // Live, not `ttl = 0`: since B-2① an expired lease is a 412, so the old setup would have
    // turned this accept-path test into a second refusal test without changing a line of it.
    ASSERT_TRUE(m_locks->acquireLock("power_lock", 3600)) << "held, and in force";

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/renew_lock",
                                   R"({"type":"power_lock","ttl":30})");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    const auto body = nlohmann::json::parse(res.body());
    EXPECT_EQ(body.value("status", ""), "renewed");
    EXPECT_EQ(body.value("type", ""), "power_lock");
    EXPECT_EQ(body.value("ttl", -1), 30);
    // 3 -> 4 on 2026-09-02: B-2② adds `lease`, naming the lease this renew extended. Same
    // reasoning as the release reply above.
    EXPECT_GT(body.value("lease", 0u), 0u) << "no lease named on a renew: " << res.body();
    EXPECT_EQ(body.size(), 4u) << "the success reply gained or lost a field: " << res.body();

    // That the handler actually reached renew() and renew() actually wrote, with no wall clock:
    // a second renew to ttl 0 sets expiryTime = now, so the lease ends immediately and the lock
    // becomes acquirable. A handler that answered "renewed" without calling through would leave
    // the original hour-long lease in place and this would fail.
    //
    // The old assertion here was `EXPECT_FALSE(acquireLock("power_lock", 30))` against a ttl-0
    // setup. It cannot be kept: the setup has to be a live lock now, and a live lock refuses
    // that acquire whether or not the handler did anything.
    const auto& shrink = m_peer->send(http::verb::post,
                                      "/ndt/renew_lock",
                                      R"({"type":"power_lock","ttl":0})");
    EXPECT_EQ(shrink.result_int(), 200u) << "body: " << shrink.body();
    EXPECT_TRUE(m_locks->acquireLock("power_lock", 30))
        << "the handler answered 'renewed' but never wrote the new deadline";
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

// --- A-9: an expired lease is not a release, on the wire ----------------------------------------
//
// [Co-developed with claude code -- Adam]
// tests/test_LockLeaseExpiry.cpp pins the LockManager side. These three are the endpoint side,
// which the unit tests cannot see: the status code and the body are chosen in HttpSession, and
// the whole point of A-9 is what a *caller* can tell from the answer it gets back.
//
// Setup uses `acquireLock(name, 0)` -- an already-run-out lease -- rather than a sleep, the same
// device the rest of this file uses.

TEST_F(LockEndpointTest, ReleasingAnExpiredLeaseIs412AndSaysExpiredRatherThan200Released)
{
    // 🔴 THE REGRESSION THIS FILE EXISTS TO CATCH. Before A-9 this answered
    // 200 {"status":"released"} -- byte-identical to a real release -- because unlock() looked at
    // `isLocked`, which expiry never cleared. KNOWN-ISSUES A-9: the Energy-Saving-App holds
    // routing_lock for a 300 s ttl and never releases it on the failing path, so this is the
    // reply an operator following the documented workaround actually gets.
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 0)) << "held, and already run out";

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/release_lock",
                                   R"({"type":"routing_lock"})");

    EXPECT_EQ(res.result_int(), 412u) << "body: " << res.body();
    EXPECT_NE(res.body().find(R"("reason":"expired")"), std::string::npos)
        << "the reply does not say the lease expired: " << res.body();
    EXPECT_EQ(res.body().find(R"("status":"released")"), std::string::npos)
        << "an expired lease was reported as released: " << res.body();

    // and the lock is genuinely free afterwards -- the refusal is about attribution, not about
    // leaving the lock wedged
    EXPECT_TRUE(m_locks->acquireLock("routing_lock", 30))
        << "the refusal left the lock held by nobody";
}

TEST_F(LockEndpointTest, ReleasingALiveLockIsStill200AndStillSaysReleased)
{
    // The control for the case above and for the whole four-outcome split: an implementation that
    // answered 412 to every release would satisfy every A-9 assertion and break the endpoint.
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 3600)) << "held, and in force";

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/release_lock",
                                   R"({"type":"routing_lock"})");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    EXPECT_NE(res.body().find(R"("status":"released")"), std::string::npos) << res.body();
    EXPECT_EQ(res.body().find(R"("reason":)"), std::string::npos)
        << "a successful release carried a failure reason: " << res.body();
}

TEST_F(LockEndpointTest, AnAcquireHandsBackALeaseIdAndSaysWhenItTookOverADeadOne)
{
    // The lease id has to reach the wire or the opt-in release check has no way to be used, and
    // `reclaimed_expired_lease` is the only signal anywhere that a previous holder went away
    // without releasing. Both were completely absent before A-9 -- the acquire reply was
    // {"status","type","ttl"} and nothing else.
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 0)) << "somebody's lease, already run out";

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/acquire_lock",
                                   R"({"type":"routing_lock","ttl":30})");

    ASSERT_EQ(res.result_int(), 200u) << "body: " << res.body();
    const auto body = nlohmann::json::parse(res.body());
    EXPECT_EQ(body.value("status", ""), "locked");
    EXPECT_GT(body.value("lease", 0u), 0u) << "no lease id on a successful acquire: " << res.body();
    EXPECT_TRUE(body.value("reclaimed_expired_lease", false))
        << "this acquire took over a lease that had run out and did not say so: " << res.body();
}

// --- B-2②: the lease requirement, on the wire ---------------------------------------------------
//
// [Co-developed with claude code -- Adam]
// tests/test_LockOwnership.cpp pins the LockManager side and explains why the switch is off by
// default. These two are the endpoint side: the status code and the body, which the unit tests
// cannot see. 400 rather than 412 is the load-bearing choice -- 412 means "acquire it and try
// again", which is wrong advice for a caller whose request is simply missing a field.

TEST_F(LockEndpointTest, WithEnforcementOnAReleaseNamingNoLeaseIs400AndReleasesNothing)
{
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 3600)) << "somebody holds it, on a live lease";
    m_locks->setRequireLeaseId(true);

    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/release_lock",
                                   R"({"type":"routing_lock"})");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
    EXPECT_NE(res.body().find(R"("reason":"lease_required")"), std::string::npos) << res.body();
    EXPECT_EQ(res.body().find(R"("status":"released")"), std::string::npos)
        << "a refused release reported success: " << res.body();

    // The half that matters: the refusal must not have released it anyway.
    EXPECT_FALSE(m_locks->acquireLock("routing_lock", 30))
        << "the request was refused and the lock was freed regardless";
}

TEST_F(LockEndpointTest, WithEnforcementOnAReleaseNamingItsOwnLeaseStillSucceeds)
{
    // The control. "400 to every release" satisfies the test above and breaks the endpoint.
    LockManager::AcquireReport a;
    ASSERT_TRUE(m_locks->acquireLock("routing_lock", 3600, &a));
    m_locks->setRequireLeaseId(true);

    const auto& res =
        m_peer->send(http::verb::post,
                     "/ndt/release_lock",
                     R"({"type":"routing_lock","lease":)" + std::to_string(a.leaseId) + "}");

    EXPECT_EQ(res.result_int(), 200u) << "body: " << res.body();
    EXPECT_NE(res.body().find(R"("status":"released")"), std::string::npos) << res.body();
    EXPECT_TRUE(m_locks->acquireLock("routing_lock", 30)) << "the lock was not actually freed";
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
 * 🔴 THESE TWO REPLACE TWO ASSERTIONS THAT WERE GREEN, and the record of that matters more than
 * the change: rewriting a passing expectation is the cheapest way there is to legalise a defect.
 *
 * [Co-developed with claude code -- Adam]
 * What stood here until 2026-09-04 was `TotalInputTrafficLoadWithADpidStillAnswers200` and
 * `NumOfFlowsWithADpidStillAnswers200`, sending {"dpid":1} against this fixture's EMPTY graph and
 * asserting 200 + status "success". They were green -- verified before the change on the binary
 * this worktree had built at 14:30 (test_routing_strategy, sha256 d05cd399683d8a24): all four
 * cases in this section passed. Their stated job was to stop "always 400" from satisfying the two
 * missing-dpid cases above, and their own comment said "The graph is empty, so the answer is
 * zero, but the status is what is under test here".
 *
 * That is the defect, written down as a requirement. dpid 1 is not a switch in an empty topology,
 * so the answer being asserted was the one OV-3 was filed for: 200 with a zero that a caller
 * cannot tell from a real, idle switch.
 *
 * The accept-path job they were doing is real, and it has NOT been dropped -- it moved to
 * KnownSwitchEndpointTest.AKnownButIdleSwitchStillAnswersZero, which asks a dpid that really is
 * in the loaded topology and requires 200 + zero. Between them the two pairs say the thing
 * neither could say alone: zero and unknown are different answers.
 */
TEST_F(LockEndpointTest, TotalInputTrafficLoadForAnUnknownDpidIsA404NotAZero)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/get_total_input_traffic_load_passing_a_switch",
                                   R"({"dpid":1})");

    EXPECT_EQ(res.result_int(), 404u) << "body: " << res.body();
    const auto body = nlohmann::json::parse(res.body());
    EXPECT_EQ(body.value("error", ""), "unknown dpid") << res.body();
    EXPECT_EQ(body.value("unknown_dpids", nlohmann::json::array()), nlohmann::json::array({1}))
        << "the refusal must name the dpid it refused: " << res.body();
    EXPECT_EQ(body.count("total_input_traffic_load_bps"), 0u)
        << "a refusal must not also carry a number, or a caller reading the body still sees a "
           "measurement: "
        << res.body();
}

TEST_F(LockEndpointTest, NumOfFlowsForAnUnknownDpidIsA404NotAZero)
{
    const auto& res = m_peer->send(http::verb::post,
                                   "/ndt/get_num_of_flows_passing_a_switch",
                                   R"({"dpid":1})");

    EXPECT_EQ(res.result_int(), 404u) << "body: " << res.body();
    const auto body = nlohmann::json::parse(res.body());
    EXPECT_EQ(body.value("error", ""), "unknown dpid") << res.body();
    EXPECT_EQ(body.value("unknown_dpids", nlohmann::json::array()), nlohmann::json::array({1}))
        << "the refusal must name the dpid it refused: " << res.body();
    EXPECT_EQ(body.count("num_of_flows"), 0u)
        << "a refusal must not also carry a count: " << res.body();
}

/**
 * 🔴 The control, and the half that makes the two above mean anything: a dpid that IS a switch in
 * the loaded topology, carrying no traffic, still answers 200 and zero. Without this, "404 for an
 * unknown dpid" is satisfied by a handler that answers 404 for every dpid -- the same endpoint
 * broken in the opposite direction, with a green suite.
 */
TEST_F(KnownSwitchEndpointTest, AKnownButIdleSwitchStillAnswersZero)
{
    const auto& flows = m_peer->send(http::verb::post,
                                     "/ndt/get_num_of_flows_passing_a_switch",
                                     R"({"dpid":3})");
    EXPECT_EQ(flows.result_int(), 200u) << "body: " << flows.body();
    EXPECT_EQ(nlohmann::json::parse(flows.body()).value("status", ""), "success") << flows.body();
    EXPECT_EQ(nlohmann::json::parse(flows.body()).value("num_of_flows", -1), 0) << flows.body();

    const auto& load = m_peer->send(http::verb::post,
                                    "/ndt/get_total_input_traffic_load_passing_a_switch",
                                    R"({"dpid":3})");
    EXPECT_EQ(load.result_int(), 200u) << "body: " << load.body();
    EXPECT_EQ(nlohmann::json::parse(load.body()).value("status", ""), "success") << load.body();
    EXPECT_EQ(nlohmann::json::parse(load.body()).value("total_input_traffic_load_bps", -1), 0)
        << load.body();
}

// --- OV-2: /ndt/set_switches_power_state -------------------------------------------------------
//
// Measured 2026-09-04 on OVS: ?ip=203.0.113.9&action=off answered 500, while a GET of the same
// address answered 404 and action=sideways answered 400. One address, two endpoints, two verdicts
// on the same question.

TEST_F(PowerStateEndpointTest, SetSwitchesPowerStateWithAnUnknownIpIsA404NotA500)
{
    const auto& res =
        m_peer->send(http::verb::post,
                     std::string("/ndt/set_switches_power_state?ip=") + kUnknownSwitchIp +
                         "&action=off");

    EXPECT_EQ(res.result_int(), 404u) << "body: " << res.body();
    // The same sentence the GET side answers, from the same lookup. Two wordings for one state
    // is how a caller ends up writing two error branches for one condition.
    EXPECT_EQ(nlohmann::json::parse(res.body()).value("error", ""), "Unknown switch IP")
        << res.body();
}

TEST_F(PowerStateEndpointTest, SetSwitchesPowerStateWithAKnownIpStillReachesTheManager)
{
    // The accept-path control: the guard must not swallow addresses the kernel does know. The
    // manager is reached and fails downstream (no power strategy for this dpid), which is a 500 --
    // asserted properly in the next test. Here the point is only that it is NOT the 404 above.
    const auto& res = m_peer->send(http::verb::post,
                                   std::string("/ndt/set_switches_power_state?ip=") +
                                       kKnownSwitchIp + "&action=on");

    EXPECT_NE(res.result_int(), 404u)
        << "a known switch address was refused as unknown: " << res.body();
}

/**
 * 🔴 The discrimination test. Without it, "answer 404 whenever the bool is false" passes every
 * other case in this file and relabels four genuine server failures -- the relay refusing, the
 * vertex gone, an unrecognised action, an exception -- as "no such switch".
 */
TEST_F(PowerStateEndpointTest, ARealPowerFailureIsStillA500)
{
    const auto& res = m_peer->send(http::verb::post,
                                   std::string("/ndt/set_switches_power_state?ip=") +
                                       kKnownSwitchIp + "&action=on");

    EXPECT_EQ(res.result_int(), 500u) << "body: " << res.body();
    EXPECT_NE(res.body().find("Failed to change switch power state"), std::string::npos)
        << res.body();
}

TEST_F(PowerStateEndpointTest, SetSwitchesPowerStateWithABadActionIsStillA400)
{
    // The pre-existing guard, kept honest: an unknown IP now short-circuits to 404, and it must
    // not have overtaken the malformed-request check. A bad action is a 400 whatever the address.
    const auto& res = m_peer->send(http::verb::post,
                                   std::string("/ndt/set_switches_power_state?ip=") +
                                       kUnknownSwitchIp + "&action=sideways");

    EXPECT_EQ(res.result_int(), 400u) << "body: " << res.body();
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
