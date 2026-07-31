/**
 * Tests for Controller's dispatcher sender, which had none.
 *
 * [Co-developed with claude code -- Adam]
 *
 * This lambda is the only place a dispatched job's outcome exists. FlowJob is fire-and-forget, so
 * once the sender returns, the OpResult is gone. It used to discard all three of them:
 *
 *     case FlowOp::Install:
 *         m_flowRoutingManager->installAnEntry(...);   // result dropped
 *
 * which quietly undid Phase 2 -- FlowRoutingManager was changed from void to OpResult, and
 * HttpRoutingStrategyBase taught to parse curl's real status, so a rejected rule could be told
 * apart from an unreachable controller -- and then nothing looked at the answer. HttpSession's own
 * comment claimed the outcome was "logged per entry with the dpid and the controller's reply", which
 * was true of nothing. An audit of the routing subsystem found it; this file is what stops it coming
 * back.
 *
 * The tests are about dispatch and result handling, not about routing: which manager method each
 * FlowOp reaches, with which arguments, and that a failure is not swallowed.
 */

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include <spdlog/sinks/base_sink.h>

#include "ndt_core/routing_management/Controller.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "utils/Logger.hpp"

namespace
{

/// One call the sender made, as the manager saw it.
struct Call
{
    std::string op;
    uint64_t dpid;
    int priority;
    int idleTimeout;
};

/**
 * A FlowRoutingManager whose results the test chooses.
 *
 * Constructed with null components: Controller's sender only ever calls the three dispatch methods,
 * all of which are overridden here, so nothing reaches the real implementation that would
 * dereference them.
 */
class ScriptedManager : public FlowRoutingManager
{
  public:
    ScriptedManager() : FlowRoutingManager(nullptr, nullptr, nullptr) {}

    OpResult installAnEntry(uint64_t dpid,
                            int priority,
                            const json& match,
                            const json& action,
                            int idleTimeout = 0) override
    {
        (void)match;
        (void)action;
        record({"install", dpid, priority, idleTimeout});
        return nextResult();
    }

    OpResult modifyAnEntry(uint64_t dpid,
                           int priority,
                           const json& match,
                           const json& action) override
    {
        (void)match;
        (void)action;
        record({"modify", dpid, priority, 0});
        return nextResult();
    }

    OpResult deleteAnEntry(uint64_t dpid, const json& match, int priority = -1) override
    {
        (void)match;
        record({"delete", dpid, priority, 0});
        return nextResult();
    }

    /// What every call returns. Defaults to success.
    void setResult(OpResult result)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_result = std::move(result);
    }

    std::vector<Call> calls() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_calls;
    }

    size_t callCount() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_calls.size();
    }

  private:
    void record(Call call)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_calls.push_back(std::move(call));
    }

    OpResult nextResult()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_result;
    }

    mutable std::mutex m_mutex;
    std::vector<Call> m_calls;
    OpResult m_result{};
};

/**
 * Captures formatted log lines so a test can assert on what was reported.
 *
 * [Co-developed with claude code -- Adam]
 * Needed because the bug being guarded against is *the absence of a log line*. The first version of
 * this file asserted only on dispatch and on failures not aborting a batch -- and passed with the
 * bug reintroduced, verified by putting `if (false)` back around the reporting. A test file that
 * cannot fail for the reason it exists is worse than none, because it says the opposite.
 */
class CapturingSink : public spdlog::sinks::base_sink<std::mutex>
{
  public:
    std::vector<std::string> lines()
    {
        std::lock_guard<std::mutex> lock(m_lines_mutex);
        return m_lines;
    }

  protected:
    void sink_it_(const spdlog::details::log_msg& msg) override
    {
        spdlog::memory_buf_t formatted;
        formatter_->format(msg, formatted);
        std::lock_guard<std::mutex> lock(m_lines_mutex);
        m_lines.push_back(fmt::to_string(formatted));
    }

    void flush_() override {}

  private:
    std::mutex m_lines_mutex;
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

    /// True when some captured line contains every one of the given fragments.
    bool sawLineContaining(const std::vector<std::string>& fragments)
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

    std::vector<std::string> lines()
    {
        return m_sink->lines();
    }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    std::shared_ptr<CapturingSink> m_sink;
    spdlog::level::level_enum m_previousLevel;
};

FlowJob jobFor(FlowOp op, uint64_t dpid, int priority = 7)
{
    FlowJob job;
    job.op = op;
    job.dpid = dpid;
    job.priority = priority;
    job.match = json::object();
    job.actions = json::array();
    return job;
}

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

class ControllerTest : public ::testing::Test
{
  protected:
    /// The sender logs on failure, and Logger::instance() is a null shared_ptr until init runs --
    /// the same trap documented in SwitchKindFixture. Idempotent, so several suites may call it.
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off;
        Logger::init(cfg);
    }
};

} // namespace

TEST_F(ControllerTest, EachFlowOpReachesItsOwnManagerMethod)
{
    // A mis-wired switch would send deletes to installAnEntry, which no functional test would
    // notice: both answer 200 and the endpoint reports "queued" either way.
    auto manager = std::make_shared<ScriptedManager>();
    Controller controller(manager);

    controller.dispatcher().enqueue(jobFor(FlowOp::Install, 1));
    controller.dispatcher().enqueue(jobFor(FlowOp::Modify, 2));
    controller.dispatcher().enqueue(jobFor(FlowOp::Delete, 3));

    ASSERT_TRUE(waitFor([&] { return manager->callCount() == 3; }))
        << "only " << manager->callCount() << " of 3 jobs reached the manager";

    // One worker per DPID, so arrival order across DPIDs is not defined; check the set.
    std::vector<std::string> ops;
    for (const auto& call : manager->calls())
    {
        ops.push_back(call.op + ":" + std::to_string(call.dpid));
    }
    std::sort(ops.begin(), ops.end());
    EXPECT_EQ(ops, (std::vector<std::string>{"delete:3", "install:1", "modify:2"}));
}

TEST_F(ControllerTest, TheJobsFieldsArePassedThroughRatherThanDefaulted)
{
    // priority and idle_timeout are carried on the job and are easy to drop silently when the
    // dispatch is rewritten -- a rule installed at the wrong priority still installs.
    auto manager = std::make_shared<ScriptedManager>();
    Controller controller(manager);

    FlowJob job = jobFor(FlowOp::Install, 5, /*priority*/ 123);
    job.idleTimeout = 45;
    controller.dispatcher().enqueue(job);

    ASSERT_TRUE(waitFor([&] { return manager->callCount() == 1; }));
    const Call call = manager->calls().front();
    EXPECT_EQ(call.dpid, 5u);
    EXPECT_EQ(call.priority, 123);
    EXPECT_EQ(call.idleTimeout, 45) << "idle_timeout was dropped between the job and the manager";
}

TEST_F(ControllerTest, ADeleteKeepsItsPriorityIncludingTheNonStrictDefault)
{
    // -1 is the wire value for "non-strict delete", the default path for the Intent Translator.
    // Turning it into 0 would silently change which entries a delete matches.
    auto manager = std::make_shared<ScriptedManager>();
    Controller controller(manager);

    controller.dispatcher().enqueue(jobFor(FlowOp::Delete, 9, /*priority*/ -1));

    ASSERT_TRUE(waitFor([&] { return manager->callCount() == 1; }));
    EXPECT_EQ(manager->calls().front().priority, -1);
}

TEST_F(ControllerTest, AFailedResultDoesNotStopTheRestOfTheBatch)
{
    // The regression this file exists for is that failures were dropped. The opposite mistake is
    // just as bad: letting one rejected rule abandon the jobs behind it, so a burst of 2000 stops
    // at the first switch that says no.
    auto manager = std::make_shared<ScriptedManager>();
    manager->setResult(OpResult{false, 400, "controller rejected the rule"});
    Controller controller(manager);

    std::vector<FlowJob> batch;
    for (uint64_t dpid = 1; dpid <= 6; ++dpid)
    {
        batch.push_back(jobFor(FlowOp::Install, dpid));
    }
    controller.dispatcher().enqueue(std::move(batch));

    EXPECT_TRUE(waitFor([&] { return manager->callCount() == 6; }))
        << "stopped after " << manager->callCount() << " of 6 once a result came back failing";
}

TEST_F(ControllerTest, ASuccessfulResultIsAlsoFineAndNothingIsRetried)
{
    // A retry loop hiding in the sender would double-install every rule; one job must mean exactly
    // one call.
    auto manager = std::make_shared<ScriptedManager>();
    manager->setResult(OpResult{true, 200, "ok"});
    Controller controller(manager);

    controller.dispatcher().enqueue(jobFor(FlowOp::Install, 1));
    ASSERT_TRUE(waitFor([&] { return manager->callCount() == 1; }));

    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    EXPECT_EQ(manager->callCount(), 1u) << "the job was dispatched more than once";
}

// --- The regression this file exists for: a failed dispatch must be reported.

TEST_F(ControllerTest, AFailedDispatchIsReportedWithTheDpidAndTheControllersReply)
{
    // The bug: Controller's sender discarded every OpResult, so a rejected rule was
    // indistinguishable from a successful one anywhere in the system. Nothing else can observe this
    // -- the endpoint answers "queued" either way and the job is gone once the sender returns -- so
    // the log line is the assertion.
    LogCapture capture;

    auto manager = std::make_shared<ScriptedManager>();
    manager->setResult(OpResult{false, 400, "Ryu rejected the match"});
    Controller controller(manager);

    controller.dispatcher().enqueue(jobFor(FlowOp::Install, 42, /*priority*/ 99));
    ASSERT_TRUE(waitFor([&] { return manager->callCount() == 1; }));
    ASSERT_TRUE(waitFor([&] { return !capture.lines().empty(); }));

    EXPECT_TRUE(capture.sawLineContaining({"install", "42", "99", "400", "Ryu rejected the match"}))
        << "the failure was not reported with enough to act on. Captured:\n"
        << [&] {
               std::string all;
               for (const auto& line : capture.lines())
               {
                   all += "  " + line + "\n";
               }
               return all;
           }();
}

TEST_F(ControllerTest, EachOperationNamesItselfWhenItFails)
{
    // "dispatched install failed" and "dispatched delete failed" send an operator to different
    // places. A single hardcoded label would misreport two of the three.
    for (const auto& [op, label] : std::vector<std::pair<FlowOp, std::string>>{
             {FlowOp::Install, "install"}, {FlowOp::Modify, "modify"}, {FlowOp::Delete, "delete"}})
    {
        LogCapture capture;
        auto manager = std::make_shared<ScriptedManager>();
        manager->setResult(OpResult{false, 500, "boom"});
        Controller controller(manager);

        controller.dispatcher().enqueue(jobFor(op, 3));
        ASSERT_TRUE(waitFor([&] { return manager->callCount() == 1; }));
        ASSERT_TRUE(waitFor([&] { return !capture.lines().empty(); }));

        EXPECT_TRUE(capture.sawLineContaining({label, "3", "500"}))
            << "a failed " << label << " did not name itself";
    }
}

TEST_F(ControllerTest, ASuccessfulDispatchReportsNothing)
{
    // The common path. Logging every success would put one line per rule in the log, and a burst is
    // up to 2000 -- the same flood that made the path-walk warnings unreadable.
    LogCapture capture;

    auto manager = std::make_shared<ScriptedManager>();
    manager->setResult(OpResult{true, 200, "ok"});
    Controller controller(manager);

    controller.dispatcher().enqueue(jobFor(FlowOp::Install, 1));
    ASSERT_TRUE(waitFor([&] { return manager->callCount() == 1; }));
    std::this_thread::sleep_for(std::chrono::milliseconds(80));

    EXPECT_FALSE(capture.sawLineContaining({"dispatched", "failed"}))
        << "a successful dispatch was reported as a failure";
}
