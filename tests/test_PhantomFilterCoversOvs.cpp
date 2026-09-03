/**
 * Tests for KNOWN-ISSUES C-4: B-1's phantom-rule filter did not cover the OVS write path.
 *
 * [Co-developed with claude code -- Adam]
 *
 * ## What was measured
 *
 * `doc/audit/2026-09-03_night-rounds/round1-ovs/22_x5_b1_phantom_window_ovs.log`, on `ovs4`:
 * after `POST /ndt/install_flow_entry`, `get_switch_openflow_table_entries` served a
 * request-shaped row (`ipv4_dst`, no counters, the caller's priority) at **t=0.257 s** and kept
 * serving it for ~1.0 s. The genuinely polled row arrived at **t=13.4 s**. The same recipe on P4
 * gave `first_sighting=never`.
 *
 * The log's own positive control is the part that decides what the fix must be: a **legitimate**
 * port-2 rule produced the *same* phantom at t=0.255 s. So the row being served is the optimistic
 * cache row, and the question it answers wrong is not "is this rule legal" but "has anything
 * observed this rule on a switch". Probe resolution was 0.25 s against a ~1.0 s window, so "the
 * probe was too slow" is excluded.
 *
 * ## Why the T-11 filter did not stop it
 *
 * The filter withholds a row whose token `DispatchOutcomeLog::isProgrammed` cannot confirm, and a
 * token is stamped by `record()` whenever `OpResult::ok`. `ok` is decided in
 * `HttpRoutingStrategyBase::post()`, whose last gate is a comment that names the whole defect:
 *
 *     // Some proxies answer 200 with {"status":"error"} in the body. Ryu does not, but the P4
 *     // proxy agent does, so a 2xx alone is not proof of success.
 *
 * Ryu's `/stats/flowentry/add` builds an `OFPFlowMod` and returns; OpenFlow does not acknowledge
 * a FLOW_MOD, so the 200 is emitted before any switch has adjudicated anything. On P4 the proxy
 * programs the table and reports per-entry failure, so its 200 *is* an adjudication. Identical
 * code, two different meanings of the same status line -- and the filter read both as
 * observation.
 *
 * ## The contract these tests pin
 *
 * **A dispatched-but-unobserved entry is never served as an observed row.** "Observed" is a
 * property of the control plane's answer, not of elapsed time, so the OVS half is not fixed by
 * delaying the cache write or by polling harder: it is fixed by refusing to read Ryu's
 * fire-and-forget 200 as evidence. The entry becomes visible when the periodic poll reads it
 * back off the switch, which is what `first_sighting = the first real poll` means in the live arm.
 *
 * ## Why nothing here names the new field
 *
 * Every assertion below is on a **consequence** -- what the confirmation index answers, what the
 * endpoint's cache serves, what kernel.log says -- and none on the mechanism that produces it.
 * That is not style. It is what let this file be compiled and run against trunk's *unfixed*
 * production code and observed red: a test written against the new spelling could only ever have
 * failed to compile, and a test that has never been red is not evidence. It also means the fix
 * can be re-implemented some other way without rewriting the tests that judge it.
 *
 * Both directions are asserted, and on both planes, because a filter that only ever hides is an
 * outage and a control that only ever shows is the defect:
 *
 *   - force-red:   an OVS install, valid or invalid, is withheld until a poll observes it;
 *   - force-green: the poll makes it appear, untouched;
 *   - P4 control:  a proxy-confirmed entry is still served immediately -- unchanged from today;
 *   - P4 control:  a proxy-refused entry is still withheld.
 */

#include <gtest/gtest.h>

#include <spdlog/sinks/base_sink.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <memory>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#include "common_types/GraphTypes.hpp"
#include "event_system/EventBus.hpp"
#include "ndt_core/collection/TopologyAndFlowMonitor.hpp"
#include "ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp"
#include "ndt_core/routing_management/Controller.hpp"
#include "ndt_core/routing_management/DispatchOutcomeLog.hpp"
#include "ndt_core/routing_management/FlowJob.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "ndt_core/routing_management/OpResult.hpp"
#include "ndt_core/routing_management/OpenFlowRoutingStrategy.hpp"
#include "ndt_core/routing_management/P4RoutingStrategy.hpp"
#include "ndt_core/routing_management/PendingEntryFilter.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

using nlohmann::json;

namespace
{

constexpr uint64_t kDpid = 1;

// --- a strategy whose curl is scripted, so a plane's real reply can be replayed --------------

/// Same seam as tests/test_RoutingStrategies.cpp: executeArgv is the single point where a
/// command is run, so replacing it replays a control plane without one being present. The
/// strategies themselves are the real ones -- the property under test is what each plane's
/// answer *means*, so substituting the strategy would substitute the thing being measured.
template <typename Strategy>
class ScriptedStrategy : public Strategy
{
  public:
    ScriptedStrategy(const std::string& apiUrl, std::string reply)
        : Strategy(apiUrl), m_reply(std::move(reply))
    {
    }

  protected:
    utils::CommandOutcome executeArgv(const std::vector<std::string>& argv) override
    {
        (void)argv;
        return utils::CommandOutcome{m_reply, true, 0};
    }

  private:
    std::string m_reply;
};

/// What Ryu answers `/stats/flowentry/add`: 200 and an empty body. curl is run with
/// -w '\n%{http_code}', so the body is followed by a newline and the status.
constexpr const char* kRyuAccepted = "\n200";

/// What the P4 proxy agent answers once it has programmed the entry.
constexpr const char* kProxyProgrammed = "{\"status\":\"success\"}\n200";

/// What the P4 proxy agent answers when the pipeline refused the entry: 200 with an error body,
/// which is the case post() already turns into ok=false.
constexpr const char* kProxyRefused = "{\"status\":\"error\",\"message\":\"no such port\"}\n200";

/// The install the live recipe sends: the invalid-port arm of 22_x5_b1_phantom_window_ovs.log.
json
invalidPortMatch()
{
    return json{{"eth_type", 2048}, {"ipv4_dst", "10.0.0.241"}};
}

/// The live log's own positive control: a legitimate rule out of port 2.
json
validPortMatch()
{
    return json{{"eth_type", 2048}, {"ipv4_dst", "10.0.0.242"}};
}

json
outputTo(int port)
{
    return json::array({{{"type", "OUTPUT"}, {"port", port}}});
}

FlowJob
installJob(uint64_t token, json match, json actions, int priority)
{
    FlowJob job;
    job.dpid = kDpid;
    job.op = FlowOp::Install;
    job.priority = priority;
    job.match = std::move(match);
    job.actions = std::move(actions);
    job.token = token;
    return job;
}

/// The row `HttpSession` writes into the cache before anything has been dispatched: the caller's
/// own vocabulary, the requested priority, no counters, and the provenance stamp.
json
optimisticRow(uint64_t token, const json& match, const json& actions, int priority)
{
    return json{{"dpid", kDpid},
                {"priority", priority},
                {"match", match},
                {"actions", actions},
                {kPendingTokenField, token}};
}

/// The row the periodic poll reads back off the switch: switch vocabulary, counters, no token.
json
polledRow(const char* dst)
{
    return json{{"priority", 0},
                {"match", {{"dl_type", 2048}, {"nw_dst", dst}}},
                {"actions", json::array({"OUTPUT:2"})},
                {"byte_count", 0},
                {"packet_count", 0},
                {"duration_sec", 3},
                {"table_id", 0}};
}

// --- a manager whose cache can be driven without a fabric ------------------------------------

/// Publishes the protected poll-application step. Same construction as
/// tests/test_StaleTableCarryForward.cpp: start() is never called, so no worker thread exists and
/// nothing these tests call reaches the network.
class CacheDriver : public DeviceConfigurationAndPowerManager
{
  public:
    using DeviceConfigurationAndPowerManager::DeviceConfigurationAndPowerManager;
    using DeviceConfigurationAndPowerManager::applyFetchedTables;
    using DeviceConfigurationAndPowerManager::FlowTableFetch;
};

std::shared_ptr<CacheDriver>
makeManager()
{
    auto graph = std::make_shared<Graph>();
    const auto v = boost::add_vertex(*graph);
    (*graph)[v].vertexType = VertexType::SWITCH;
    (*graph)[v].dpid = kDpid;
    (*graph)[v].ip.push_back(utils::ipStringToUint32("192.168.123.11"));

    auto mutex = std::make_shared<std::shared_mutex>();
    auto bus = std::make_shared<EventBus>();
    auto monitor = std::make_shared<TopologyAndFlowMonitor>(graph, mutex, bus, utils::MININET);
    return std::make_shared<CacheDriver>(monitor, utils::TESTBED, "localhost", nullptr);
}

/// The rows `get_switch_openflow_table_entries` would show for dpid 1.
json
servedRows(const json& tables)
{
    for (const auto& sw : tables)
    {
        if (sw.is_object() && sw.value("dpid", uint64_t{0}) == kDpid && sw.contains("flows") &&
            sw["flows"].contains(std::to_string(kDpid)))
        {
            return sw["flows"][std::to_string(kDpid)];
        }
    }
    return json::array();
}

// --- log capture -----------------------------------------------------------------------------

class CapturingSink : public spdlog::sinks::base_sink<std::mutex>
{
  public:
    std::vector<std::string> lines()
    {
        std::lock_guard<std::mutex> lock(m_linesMutex);
        return m_lines;
    }

  protected:
    void sink_it_(const spdlog::details::log_msg& msg) override
    {
        spdlog::memory_buf_t formatted;
        formatter_->format(msg, formatted);
        std::lock_guard<std::mutex> lock(m_linesMutex);
        m_lines.push_back(fmt::to_string(formatted));
    }

    void flush_() override {}

  private:
    std::mutex m_linesMutex;
    std::vector<std::string> m_lines;
};

/// Attaches a CapturingSink for the duration of a test and puts the logger back afterwards.
class LogCapture
{
  public:
    LogCapture()
        : m_logger(Logger::instance()), m_sink(std::make_shared<CapturingSink>()),
          m_previousLevel(m_logger->level())
    {
        m_sink->set_pattern("%v");
        m_logger->sinks().push_back(m_sink);
        m_logger->set_level(spdlog::level::trace);
    }

    ~LogCapture()
    {
        auto& sinks = m_logger->sinks();
        sinks.erase(std::remove(sinks.begin(), sinks.end(), m_sink), sinks.end());
        m_logger->set_level(m_previousLevel);
    }

    LogCapture(const LogCapture&) = delete;
    LogCapture& operator=(const LogCapture&) = delete;

    /// True when one line contains every fragment, so a reworded message still passes but a
    /// deleted one cannot.
    bool sawLineContaining(const std::vector<std::string>& fragments) const
    {
        for (const auto& line : m_sink->lines())
        {
            bool all = true;
            for (const auto& fragment : fragments)
            {
                if (line.find(fragment) == std::string::npos)
                {
                    all = false;
                    break;
                }
            }
            if (all)
            {
                return true;
            }
        }
        return false;
    }

    std::string joined() const
    {
        std::string out;
        for (const auto& line : m_sink->lines())
        {
            out += line;
            out += '\n';
        }
        return out;
    }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    std::shared_ptr<CapturingSink> m_sink;
    spdlog::level::level_enum m_previousLevel;
};

/// A manager whose dispatch results the test chooses, so Controller's sender can be driven with
/// no control plane present. Same shape as tests/test_Controller.cpp's ScriptedManager.
class AcceptingManager : public FlowRoutingManager
{
  public:
    AcceptingManager() : FlowRoutingManager(nullptr, nullptr, nullptr) {}

    OpResult installAnEntry(uint64_t dpid,
                            int priority,
                            const json& match,
                            const json& action,
                            int idleTimeout = 0) override
    {
        (void)dpid;
        (void)priority;
        (void)match;
        (void)action;
        (void)idleTimeout;
        m_calls.fetch_add(1, std::memory_order_relaxed);
        // "The far end took it", with no claim about the switch -- which is exactly what an empty
        // 200 from Ryu means, and what the sender must not read as an observation.
        return OpResult::success();
    }

    unsigned calls() const { return m_calls.load(std::memory_order_relaxed); }

  private:
    std::atomic<unsigned> m_calls{0};
};

template <typename Pred>
bool
waitFor(Pred pred, std::chrono::milliseconds limit = std::chrono::seconds(5))
{
    const auto deadline = std::chrono::steady_clock::now() + limit;
    while (std::chrono::steady_clock::now() < deadline)
    {
        if (pred())
        {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return pred();
}

class PhantomOvsFixture : public ::testing::Test
{
  protected:
    // Logger::init must happen in this suite rather than be inherited from another one; it is
    // idempotent. See the note in tests/test_SwitchKindDispatch.cpp.
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

/// Runs one arm of the live recipe end to end: the optimistic write the HTTP thread performs,
/// the real strategy's answer for the given plane, and the confirmation index they meet in.
struct Recipe
{
    std::shared_ptr<CacheDriver> mgr = makeManager();
    DispatchOutcomeLog log;

    /// Wires the manager to the outcome log exactly as src/main.cpp does, writes the optimistic
    /// row, and records what the plane answered for it.
    void dispatch(uint64_t token,
                  const json& match,
                  const json& actions,
                  int priority,
                  const OpResult& southbound)
    {
        mgr->setProgrammedPredicate([this](uint64_t t) { return log.isProgrammed(t); });

        json body;
        body["install_flow_entries"] = json::array({optimisticRow(token, match, actions, priority)});
        mgr->updateOpenFlowTables(body);

        log.record(installJob(token, match, actions, priority), southbound);
    }

    /// The periodic poll: t = 13.4 s in the live log. It replaces the whole cache with what the
    /// switch said, so every row it brings is untokened.
    void poll(const char* dst)
    {
        CacheDriver::FlowTableFetch fetch;
        json sw;
        sw["dpid"] = kDpid;
        sw["flows"] = json::object();
        sw["flows"][std::to_string(kDpid)] = json::array({polledRow(dst)});
        fetch.tables = json::array({std::move(sw)});
        mgr->applyFetchedTables(std::move(fetch), 1000);
    }

    json served() { return servedRows(mgr->getOpenFlowTables()); }
};

/// What Ryu really answers an install, produced by the real OpenFlow strategy.
OpResult
ryuAnswersInstall(const json& match, const json& actions, int priority)
{
    ScriptedStrategy<OpenFlowRoutingStrategy> ryu("localhost:8080", kRyuAccepted);
    return ryu.installAnEntry(kDpid, priority, match, actions, 0);
}

/// What the P4 proxy really answers an install it programmed.
OpResult
proxyAnswersInstall(const json& match, const json& actions, int priority)
{
    ScriptedStrategy<P4RoutingStrategy> proxy("localhost:8081", kProxyProgrammed);
    return proxy.installAnEntry(kDpid, priority, match, actions, 0);
}

/// What the P4 proxy really answers an install its pipeline refused.
OpResult
proxyRefusesInstall(const json& match, const json& actions, int priority)
{
    ScriptedStrategy<P4RoutingStrategy> proxy("localhost:8081", kProxyRefused);
    return proxy.installAnEntry(kDpid, priority, match, actions, 0);
}

} // namespace

// =============================================================================================
// 1. The confirmation index: what each plane's real answer is allowed to confirm.
// =============================================================================================

TEST_F(PhantomOvsFixture, ARyuAcceptanceIsSuccessfulButConfirmsNothing)
{
    DispatchOutcomeLog log;

    const OpResult answer = ryuAnswersInstall(invalidPortMatch(), outputTo(999), 915);
    log.record(installJob(101, invalidPortMatch(), outputTo(999), 915), answer);

    EXPECT_TRUE(answer.ok) << "the request really was accepted, and the API is honest about that";
    EXPECT_FALSE(log.isProgrammed(101))
        << "Ryu's fire-and-forget 200 stamped the token, so the view served the optimistic row "
           "0.257 s after the POST -- 13 seconds before anything observed the rule. Ryu returns "
           "as soon as it has built the OFPFlowMod, and OpenFlow does not acknowledge a FLOW_MOD.";
}

TEST_F(PhantomOvsFixture, AProxySuccessStillConfirmsTheEntry)
{
    // The P4 control. The proxy programs the table before answering and reports per-entry failure
    // in the body, so its 200 IS an adjudication and must keep counting as one.
    DispatchOutcomeLog log;

    const OpResult answer = proxyAnswersInstall(invalidPortMatch(), outputTo(999), 915);
    log.record(installJob(202, invalidPortMatch(), outputTo(999), 915), answer);

    EXPECT_TRUE(answer.ok);
    EXPECT_TRUE(log.isProgrammed(202)) << "P4 behaviour changed; this fix must be OVS-only";
}

TEST_F(PhantomOvsFixture, AProxyRefusalConfirmsNothingEither)
{
    DispatchOutcomeLog log;

    const OpResult answer = proxyRefusesInstall(invalidPortMatch(), outputTo(999), 915);
    log.record(installJob(203, invalidPortMatch(), outputTo(999), 915), answer);

    EXPECT_FALSE(answer.ok);
    EXPECT_FALSE(log.isProgrammed(203)) << "B-1's original guarantee regressed";
}

TEST_F(PhantomOvsFixture, TheCountersStillMeanWhatA7SaysTheyMean)
{
    // Withholding is not failing. An accepted-but-unconfirmed entry must still count as a
    // success, or A-7's /ndt/get_flow_dispatch_status starts reporting a healthy OVS fabric as a
    // fabric full of rejected rules -- swapping one false alarm for another.
    DispatchOutcomeLog log;

    log.record(installJob(204, invalidPortMatch(), outputTo(999), 915),
               ryuAnswersInstall(invalidPortMatch(), outputTo(999), 915));

    EXPECT_EQ(log.dispatched(), 1u);
    EXPECT_EQ(log.succeeded(), 1u);
    EXPECT_EQ(log.failed(), 0u);
    EXPECT_TRUE(log.recentFailures().empty());
}

// =============================================================================================
// 2. End to end, through the cache the endpoint actually reads: the 22_ recipe in miniature.
// =============================================================================================

TEST_F(PhantomOvsFixture, AnOvsInstallIsNotServedBeforeAPollObservesIt)
{
    Recipe r;
    r.dispatch(301, invalidPortMatch(), outputTo(999), 915,
               ryuAnswersInstall(invalidPortMatch(), outputTo(999), 915));

    // t = 0.257 s in the live log. THE DEFECT, AT THE PLACE THE USER SEES IT.
    const json before = r.served();
    EXPECT_EQ(before.size(), 0u)
        << "get_switch_openflow_table_entries served a row nothing has observed: " << before.dump();

    r.poll("10.0.0.241");

    // t = 13.4 s in the live log. force-green: a filter that only ever hides is an outage.
    const json after = r.served();
    ASSERT_EQ(after.size(), 1u) << "first_sighting must be the first real poll, not never";
    EXPECT_TRUE(after.at(0).at("match").contains("nw_dst"))
        << "the surviving row must be the polled one -- switch vocabulary, with counters";
    EXPECT_FALSE(after.at(0).contains(kPendingTokenField));
}

TEST_F(PhantomOvsFixture, TheLegitimateOvsRuleIsWithheldTooBecauseTheRowIsACacheArtefact)
{
    // The live log's positive control. A valid port-2 rule showed the SAME phantom at t=0.255 s,
    // so the row being served is the cache's own, and the property is about observation, not
    // legality. A fix that withheld only the rules it judged invalid would pass the invalid arm
    // and reproduce the finding on this one -- and it would be a legality verdict this kernel has
    // no standing to make, because the switch is what decides.
    Recipe r;
    r.dispatch(302, validPortMatch(), outputTo(2), 916,
               ryuAnswersInstall(validPortMatch(), outputTo(2), 916));

    EXPECT_EQ(r.served().size(), 0u)
        << "a legitimate but unobserved rule was served as an observed row";

    r.poll("10.0.0.242");
    EXPECT_EQ(r.served().size(), 1u) << "and it must appear once the poll observes it";
}

TEST_F(PhantomOvsFixture, AConfirmedP4InstallIsStillServedImmediately)
{
    // The other half of the P4 control, and the reason this fix is narrow: where the plane's
    // acceptance really is an adjudication the row appears as soon as it is confirmed, before any
    // poll, exactly as it does today. Without this, "make OVS honour the contract" could be
    // satisfied by withholding everything everywhere -- an outage wearing a fix's clothes.
    Recipe r;
    r.dispatch(303, invalidPortMatch(), outputTo(999), 915,
               proxyAnswersInstall(invalidPortMatch(), outputTo(999), 915));

    const json served = r.served();
    ASSERT_EQ(served.size(), 1u) << "the P4 path lost a confirmed entry";
    EXPECT_EQ(served.at(0).at("match").at("ipv4_dst"), "10.0.0.241");
    EXPECT_FALSE(served.at(0).contains(kPendingTokenField));
}

TEST_F(PhantomOvsFixture, AP4RefusalIsStillWithheld)
{
    Recipe r;
    r.dispatch(304, invalidPortMatch(), outputTo(999), 915,
               proxyRefusesInstall(invalidPortMatch(), outputTo(999), 915));

    EXPECT_EQ(r.served().size(), 0u) << "B-1's original guarantee regressed";
}

TEST_F(PhantomOvsFixture, PolledRowsAreNeverWithheldOnEitherPlane)
{
    // The catastrophic failure mode of this change: read "unconfirmed" too broadly and the view
    // empties, because everything a real switch reports arrives untokened.
    Recipe r;
    r.poll("10.0.0.7");

    EXPECT_EQ(r.served().size(), 1u) << "the table view lost rows read off a real switch";
}

// =============================================================================================
// 3. The kernel log says when an entry is being withheld, and why.
// =============================================================================================

TEST_F(PhantomOvsFixture, TheViewSaysItIsWithholdingRows)
{
    // KNOWN-ISSUES B-1's 2026-09-02 review, clause 3: stripUnprogrammedEntries returns a count
    // whose own docstring says "so a caller can log or assert on it", and the caller dropped it.
    // A view that is quietly short of rows is the same shape as one that is quietly long of them,
    // which is the defect this filter exists to remove.
    Recipe r;
    LogCapture capture;

    r.dispatch(305, invalidPortMatch(), outputTo(999), 915,
               ryuAnswersInstall(invalidPortMatch(), outputTo(999), 915));
    (void)r.served();

    EXPECT_TRUE(capture.sawLineContaining({"withholding", "not observed"}))
        << "nothing in kernel.log says the table view is short of a row, or why. Lines seen:\n"
        << capture.joined();
}

TEST_F(PhantomOvsFixture, TheViewDoesNotClaimToWithholdWhatItServed)
{
    // Force-green on the instrument. A line that appears when nothing is withheld is noise, and
    // noise is how a real line stops being read.
    Recipe r;
    LogCapture capture;

    r.dispatch(306, invalidPortMatch(), outputTo(999), 915,
               proxyAnswersInstall(invalidPortMatch(), outputTo(999), 915));
    ASSERT_EQ(r.served().size(), 1u) << "precondition: this row is served";

    EXPECT_FALSE(capture.sawLineContaining({"withholding"}))
        << "the view reported withholding a row it served. Lines seen:\n"
        << capture.joined();
}

TEST_F(PhantomOvsFixture, TheDispatchSaysWhyAnAcceptedEntryIsStillWithheld)
{
    // The "why" belongs where the decision is made, because that is where the plane's answer is
    // in scope. One line per batch and not per entry: a burst is 2000 jobs, and a per-entry line
    // would be its own outage.
    auto manager = std::make_shared<AcceptingManager>();
    LogCapture capture;
    Controller controller(manager);

    FlowJob job = installJob(307, invalidPortMatch(), outputTo(999), 915);
    controller.dispatcher().enqueue(job);
    ASSERT_TRUE(waitFor([&] { return manager->calls() == 1; }));
    ASSERT_TRUE(waitFor([&] {
        return capture.sawLineContaining({"not evidence", "dpid 1"});
    })) << "kernel.log does not say why an accepted entry is being kept out of the table view. "
           "Lines seen:\n"
        << capture.joined();

    // The A-7 failure line must not have been reused for this: "failed" is what check_logs.py
    // fails a run on, and an accepted-but-unconfirmed entry has not failed.
    EXPECT_FALSE(capture.sawLineContaining({"dispatched", "failed"}))
        << "an accepted entry was reported as a dispatch failure. Lines seen:\n"
        << capture.joined();
}
