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

// ---------------------------------------------------------------------------
// Deterministic lost-wakeup test using a rendezvous, so the interleaving is
// chosen by the test rather than by the scheduler.
//
// The scenario: a worker thread has drained its queue and is about to sleep on
// the condition variable. At that exact moment, a producer enqueues a job. The
// job must be picked up on the next wake, not left in the queue forever.
//
// The existing StopReturnsRatherThanDeadlockingOnAnIdleWorker test covers the
// stop-path lost-wakeup (running_ written outside mtx_), but is probabilistic:
// it relies on the OS scheduler to produce the unlucky interleaving within a
// 10-second window. On a fast or deterministic machine it could pass against
// broken code.
//
// The test below uses a blocking sender to park the worker at a known point,
// then enqueues while the worker is not holding mtx_. When the sender is
// released, the worker must loop back, reacquire mtx_, and see the new job.
// This is the same shape as the real lost-wakeup: a job arriving while the
// worker is between releasing the lock and reacquiring it for the next wait.
// ---------------------------------------------------------------------------

TEST(FlowDispatcherTest, DeterministicNoLostWakeupWhenEnqueueRacesWithWorkerSleep)
{
    // A sender that blocks on the SECOND batch, parking the worker outside mtx_.
    // The test then enqueues a job while the worker is parked. After release,
    // the worker must pick up the new job -- a lost wakeup would leave it
    // sitting in the queue forever.
    std::atomic<int> batchCount{0};
    std::atomic<bool> parkWorker{false};
    std::atomic<bool> workerParked{false};
    std::atomic<bool> releaseWorker{false};

    Recorder recorder;
    auto sender = [&](const std::vector<FlowJob>& batch) {
        {
            std::lock_guard<std::mutex> lock(recorder.mutex);
            recorder.seen.insert(recorder.seen.end(), batch.begin(), batch.end());
        }
        const int n = ++batchCount;
        if (n == 2 && parkWorker.load())
        {
            workerParked.store(true);
            // Busy-wait until the test releases us. We cannot use a mutex here
            // because the worker must not hold mtx_ while parked -- that would
            // prevent enqueue from pushing work, which is the whole point.
            while (!releaseWorker.load())
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
    };

    FlowDispatcher dispatcher(sender, /*burstSize*/ 1);
    dispatcher.start();

    // Batch 1: create the worker and let it run through once.
    dispatcher.enqueue(jobFor(42));
    ASSERT_TRUE(waitFor([&] { return recorder.count() >= 1; }));

    // Now tell the sender to park on the NEXT batch.
    parkWorker.store(true);

    // Batch 2: this will park the worker inside the sender callback.
    dispatcher.enqueue(jobFor(42));
    ASSERT_TRUE(waitFor([&] { return workerParked.load(); }))
        << "worker did not park within the timeout";

    // The worker is now parked in the sender (NOT holding mtx_).
    // Enqueue a job while the worker is between iterations.
    // This is the critical moment: the job must be seen when the worker
    // loops back, even though no notify_all() reaches a sleeping worker
    // (because the worker is not sleeping -- it's in the sender).
    dispatcher.enqueue(jobFor(42));
    const size_t countBeforeRelease = recorder.count();

    // Release the worker.
    releaseWorker.store(true);

    // The worker should now finish the sender, loop back, acquire mtx_,
    // see the new job in the queue, and process it as batch 3.
    ASSERT_TRUE(waitFor([&] { return recorder.count() > countBeforeRelease; }))
        << "worker did not pick up the job enqueued while it was parked; "
        << "count stuck at " << recorder.count();

    EXPECT_GE(recorder.count(), 3u)
        << "expected at least 3 deliveries (batches 1, 2, 3), got " << recorder.count();

    dispatcher.stop();
}

TEST(FlowDispatcherTest, JobsDroppedAfterStopAreCountedAndNotSilent)
{
    // The shutdown window. Dropping is correct -- a worker spawned after stop() has moved
    // workers_ out is owned by nobody, and destroying a joinable std::thread is std::terminate --
    // but both enqueue overloads used to return with no log, no counter and no status. A batch
    // enqueued here vanished while the HTTP layer had already answered 200 {"status":"queued"},
    // and every layer of the test suite stayed green, because nothing observable distinguished
    // "delivered" from "silently discarded".
    //
    // Asserting on the sender alone cannot catch that: a dropped job and a never-sent job look
    // identical from there. The counter is what makes the difference observable, which is the
    // whole reason it exists.
    Recorder recorder;
    FlowDispatcher dispatcher(recorder.sender(), /*burstSize*/ 8);
    dispatcher.start();
    dispatcher.enqueue(jobFor(1));
    EXPECT_TRUE(waitFor([&] { return recorder.count() == 1; }));
    dispatcher.stop();

    EXPECT_EQ(dispatcher.droppedAfterStop(), 0u)
        << "nothing was refused while the dispatcher was running";

    const size_t deliveredBeforeStop = recorder.count();

    dispatcher.enqueue(jobFor(2));                              // single overload
    dispatcher.enqueue(std::vector<FlowJob>{jobFor(3), jobFor(4), jobFor(5)});  // bulk overload

    EXPECT_EQ(dispatcher.droppedAfterStop(), 4u)
        << "expected 1 from the single overload and 3 from the bulk one";
    EXPECT_EQ(recorder.count(), deliveredBeforeStop)
        << "a job enqueued after stop() reached the sender, which means a worker was spawned "
           "after workers_ was moved out -- the crash this refusal exists to prevent";
}
