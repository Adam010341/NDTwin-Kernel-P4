#pragma once
#include "ndt_core/routing_management/FlowJob.hpp"
#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

/**
 * @brief Per-switch (per-DPID) flow job dispatcher with batching.
 *
 * FlowDispatcher decouples flow-programming requests (FlowJob) from the caller thread by
 * queueing jobs and sending them asynchronously to a provided southbound sender function.
 *
 * Design:
 *  - Maintains one FIFO queue per switch DPID (queues_).
 *  - Spawns one worker thread per active DPID (workers_) that drains its queue.
 *  - Sends jobs in batches (bursts) up to burstSize_ to reduce overhead.
 *
 * The sender callback is responsible for actually applying the batch (e.g., install/modify/delete
 * OpenFlow entries) and for any additional synchronization with the controller datapath.
 *
 * Concurrency:
 *  - enqueue() is thread-safe.
 *  - Workers block on a condition variable when no work is available.
 *  - start()/stop() control the lifetime of worker threads.
 *
 * Ordering:
 *  - Jobs targeting the same DPID are processed in FIFO order.
 *  - Different DPIDs are processed independently (parallelism across switches).
 */
class FlowDispatcher
{
  public:
    using SenderFn = std::function<void(const std::vector<FlowJob>& batch)>;

    /**
     * @brief Construct a dispatcher.
     *
     * @param sender    Callback invoked by worker threads to send a batch of jobs.
     * @param burstSize Max number of jobs to send per batch (per DPID) before yielding.
     *
     * [Co-developed with claude code -- Adam]
     * There used to be a third parameter, `bool fencePerBurst`, documented as "enforces a fence
     * between bursts ... typically used to guarantee completion/ordering semantics across batches".
     * It guaranteed nothing: the value was stored in a member that was never read, and the only
     * mention of it in the implementation was a commented-out line. A caller could pass true and
     * believe it had ordering guarantees it did not have, which is worse than the parameter not
     * existing -- dead code is inert, but a false affordance is load-bearing in someone's head.
     * Removed rather than implemented, because nothing asked for it: the sole caller
     * (Controller.cpp) passed false explicitly. Found by clang's -Wunused-private-field, which GCC
     * does not have.
     */
    explicit FlowDispatcher(SenderFn sender, size_t burstSize = 2000);

    /**
     * @brief Stop workers and release resources.
     *
     * Equivalent to calling stop() if still running.
     */
    ~FlowDispatcher();

    /**
     * @brief Start the dispatcher.
     *
     * Enables worker processing (running_=true). Worker threads are created lazily
     * when jobs for a new DPID are first enqueued (common pattern), or eagerly if
     * implemented that way in the .cpp.
     */
    void start();
    /**
     * @brief Stop the dispatcher and join worker threads.
     *
     * Signals all workers to exit, wakes them via cv_, and joins all threads.
     * Safe to call multiple times.
     */
    void stop();

    /**
     * @brief Enqueue a single flow job.
     *
     * Adds the job to the per-DPID queue and wakes the corresponding worker.
     * If the worker for this DPID does not exist yet, it may be created.
     *
     * Thread-safe.
     */
    void enqueue(const FlowJob& job); // single
    /**
     * @brief Enqueue multiple flow jobs in bulk.
     *
     * Efficiently appends jobs to their per-DPID queues and wakes workers.
     * Thread-safe.
     */
    void enqueue(std::vector<FlowJob> jobs); // bulk

    /**
     * @brief How many jobs have been dropped because the dispatcher was already stopped.
     *
     * Dropping is the right behaviour -- a worker spawned after stop() has moved workers_ out is
     * owned by nobody, and destroying a joinable std::thread is std::terminate. What was wrong
     * was doing it *silently*: both enqueue overloads returned without a log, a counter or a
     * status, so a batch enqueued during the shutdown window vanished while the HTTP layer had
     * already answered `200 {"status":"queued"}` and L2/L4 stayed green. The rule the queued
     * response depends on -- accepted means it will be attempted -- was broken with nothing
     * anywhere to show it.
     *
     * Returning a status instead would be stronger, but the two overloads return void and are
     * called from several places; a counter plus a warning is the change that adds evidence
     * without changing the contract, and it is what a test can assert on.
     *
     * [Co-developed with claude code -- Adam]
     */
    uint64_t droppedAfterStop() const { return droppedAfterStop_.load(std::memory_order_relaxed); }

  private:
    /// Worker thread for one DPID: waits for jobs, pops from queues_[dpid], and calls sender_ in
    /// bursts.
    void workerLoop_(uint64_t dpid);

    /// Counts a shutdown-window drop and warns on the first one. See droppedAfterStop().
    void noteDropped_(size_t n);

    // One queue per DPID
    std::unordered_map<uint64_t, std::deque<FlowJob>> queues_;
    std::unordered_map<uint64_t, std::thread> workers_;

    std::mutex mtx_;
    std::condition_variable cv_;
    std::atomic<bool> running_{false};

    /// Jobs refused because running_ was already false. See droppedAfterStop().
    std::atomic<uint64_t> droppedAfterStop_{0};

    // Sender callback that applies a batch of FlowJobs to the datapath/controller.
    SenderFn sender_;
    size_t burstSize_;
};
