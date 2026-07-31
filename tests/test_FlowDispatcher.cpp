/**
 * Tests for FlowDispatcher's lifecycle, which had none.
 *
 * [Co-developed with claude code -- Adam]
 *
 * An audit pointed out that this class -- one worker thread per DPID, draining shared queues --
 * had no test file at all, and that stop() touched workers_ with no lock while enqueue() inserts
 * into it under mtx_. Reading the code to confirm that turned up two more faults it had not
 * mentioned:
 *
 *   - a lost wakeup that deadlocks stop() itself, because running_ was written outside mtx_; and
 *   - enqueue() spawning a worker after stop() had already moved workers_ out, leaving a joinable
 *     std::thread with no owner, which is std::terminate at destruction.
 *
 * These tests are deliberately about lifecycle rather than throughput: every one of the three is a
 * hang or a crash at shutdown, which is the part no functional test exercises.
 */

#include <atomic>
#include <chrono>
#include <future>
#include <mutex>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "ndt_core/routing_management/FlowDispatcher.hpp"

namespace
{

/// Records the jobs it is handed, so a test can tell delivery from silent drops.
struct Recorder
{
    std::mutex mutex;
    std::vector<FlowJob> seen;

    FlowDispatcher::SenderFn sender()
    {
        return [this](const std::vector<FlowJob>& batch) {
            std::lock_guard<std::mutex> lock(mutex);
            seen.insert(seen.end(), batch.begin(), batch.end());
        };
    }

    size_t count()
    {
        std::lock_guard<std::mutex> lock(mutex);
        return seen.size();
    }
};

FlowJob jobFor(uint64_t dpid)
{
    FlowJob job;
    job.op = FlowOp::Install;
    job.dpid = dpid;
    job.priority = 1;
    return job;
}

/// Waits for a predicate rather than sleeping a fixed time, so the tests neither flake on a slow
/// machine nor waste a second on a fast one.
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

} // namespace

TEST(FlowDispatcherTest, DeliversWhatWasEnqueued)
{
    Recorder recorder;
    FlowDispatcher dispatcher(recorder.sender(), /*burstSize*/ 8);
    dispatcher.start();

    for (uint64_t dpid = 1; dpid <= 4; ++dpid)
    {
        dispatcher.enqueue(jobFor(dpid));
    }

    EXPECT_TRUE(waitFor([&] { return recorder.count() == 4; })) << "delivered " << recorder.count();
    dispatcher.stop();
}

TEST(FlowDispatcherTest, StopReturnsRatherThanDeadlockingOnAnIdleWorker)
{
    // The lost wakeup. running_ used to be written outside mtx_, so stop() could flip it and
    // notify in the window between a worker evaluating the wait predicate and actually sleeping.
    // The worker then slept forever and stop() blocked in join() forever. Run on a separate
    // thread with a deadline, because the failure mode is a hang: a plain call would take the
    // whole suite down with it rather than failing one test.
    auto recorder = std::make_shared<Recorder>();
    auto dispatcher = std::make_shared<FlowDispatcher>(recorder->sender(), 8);
    dispatcher->start();

    dispatcher->enqueue(jobFor(7));
    ASSERT_TRUE(waitFor([&] { return recorder->count() == 1; }));

    std::promise<void> stopped;
    auto done = stopped.get_future();
    std::thread stopper([dispatcher, p = std::move(stopped)]() mutable {
        dispatcher->stop();
        p.set_value();
    });

    const bool returned = done.wait_for(std::chrono::seconds(10)) == std::future_status::ready;
    if (returned)
    {
        stopper.join();
    }
    else
    {
        // Leak the thread deliberately: it is stuck inside stop(), and joining it here would hang
        // the process instead of reporting a failure. The shared_ptr keeps the dispatcher alive so
        // the stuck thread does not touch freed memory.
        stopper.detach();
    }
    EXPECT_TRUE(returned) << "stop() did not return within 10s -- lost wakeup";
}

TEST(FlowDispatcherTest, StopIsSafeWhileJobsAreStillArriving)
{
    // The audit's finding: stop() iterated and cleared workers_ unlocked while enqueue() inserted
    // into it under mtx_. This is the interleaving that made that matter -- a producer running
    // flat out across many DPIDs while stop() runs.
    Recorder recorder;
    FlowDispatcher dispatcher(recorder.sender(), 4);
    dispatcher.start();

    std::atomic<bool> keepGoing{true};
    std::thread producer([&] {
        for (uint64_t i = 0; keepGoing.load(std::memory_order_relaxed); ++i)
        {
            dispatcher.enqueue(jobFor(i % 16));
        }
    });

    ASSERT_TRUE(waitFor([&] { return recorder.count() > 0; }));
    dispatcher.stop();
    keepGoing.store(false, std::memory_order_relaxed);
    producer.join();

    // The assertion is that we got here at all: the old code's failure was a crash or a hang
    // inside stop(), not a wrong count. Post-stop enqueues are dropped by design, so no count is
    // predictable here.
    SUCCEED();
}

TEST(FlowDispatcherTest, EnqueueAfterStopIsDroppedRatherThanSpawningAnUnownedThread)
{
    // A worker spawned after stop() moved workers_ out belongs to nobody, so its std::thread is
    // destroyed while joinable -- std::terminate, taking the process down at shutdown.
    Recorder recorder;
    {
        FlowDispatcher dispatcher(recorder.sender(), 8);
        dispatcher.start();
        dispatcher.enqueue(jobFor(1));
        ASSERT_TRUE(waitFor([&] { return recorder.count() == 1; }));

        dispatcher.stop();

        dispatcher.enqueue(jobFor(2));
        dispatcher.enqueue(std::vector<FlowJob>{jobFor(3), jobFor(4)});

        // Give a wrongly-spawned worker time to pick the job up, so a regression shows as a
        // delivery rather than being missed by a fast destructor.
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    } // ~FlowDispatcher calls stop() again; must not terminate.

    EXPECT_EQ(recorder.count(), 1u) << "a job enqueued after stop() was delivered anyway";
}

TEST(FlowDispatcherTest, StopIsIdempotentBecauseTheDestructorCallsItToo)
{
    // ~FlowDispatcher calls stop(), so every explicit stop() is followed by a second one. The
    // second must not join an already-joined thread, which is undefined behaviour.
    Recorder recorder;
    FlowDispatcher dispatcher(recorder.sender(), 8);
    dispatcher.start();
    dispatcher.enqueue(jobFor(5));
    ASSERT_TRUE(waitFor([&] { return recorder.count() == 1; }));

    dispatcher.stop();
    dispatcher.stop();
    dispatcher.stop();
    SUCCEED();
}

TEST(FlowDispatcherTest, EnqueueBeforeStartDoesNotRunWork)
{
    // start() is what makes the dispatcher live. Accepting work before it would spawn workers that
    // exit immediately on the !running_ predicate, and the jobs would vanish with no record.
    Recorder recorder;
    FlowDispatcher dispatcher(recorder.sender(), 8);

    dispatcher.enqueue(jobFor(1));
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    EXPECT_EQ(recorder.count(), 0u);

    // And it recovers: starting afterwards must work normally.
    dispatcher.start();
    dispatcher.enqueue(jobFor(1));
    EXPECT_TRUE(waitFor([&] { return recorder.count() == 1; }));
    dispatcher.stop();
}
