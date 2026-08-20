#include "ndt_core/routing_management/FlowDispatcher.hpp"

#include "utils/Logger.hpp"

FlowDispatcher::FlowDispatcher(SenderFn sender, size_t burstSize)
: sender_(std::move(sender)), burstSize_(burstSize) {}

FlowDispatcher::~FlowDispatcher() { stop(); }

void FlowDispatcher::start() {
    // [Co-developed with claude code -- Adam] Under the lock, so a worker cannot observe
    // running_ changing between its predicate check and its wait; see stop().
    std::lock_guard<std::mutex> lk(mtx_);
    running_ = true;
}

// [Co-developed with claude code -- Adam]
// Three separate faults here, none of which had a test:
//
//  1. workers_ was iterated and cleared with no lock at all, while enqueue() inserts into it
//     under mtx_. A job arriving during shutdown could rehash the map mid-iteration.
//
//  2. A lost wakeup that deadlocks stop() itself. running_ was written outside mtx_, so this
//     interleaving was possible: a worker holds the lock, evaluates the wait predicate as false
//     (running_ true, queue empty), and is about to sleep; stop() then sets running_ = false and
//     calls notify_all() with no waiter yet registered; the worker sleeps and is never woken, and
//     stop() blocks in join() forever. Writing running_ under mtx_ closes it, because the worker
//     holds that same lock across both the check and the sleep.
//
//  3. The map could not simply be locked for the whole function: workerLoop_ takes mtx_, so
//     joining while holding it would deadlock immediately. The threads are moved out under the
//     lock and joined after releasing it.
void FlowDispatcher::stop() {
    std::unordered_map<uint64_t, std::thread> toJoin;
    {
        std::lock_guard<std::mutex> lk(mtx_);
        running_ = false;
        toJoin.swap(workers_);
    }
    cv_.notify_all();

    for (auto& [dpid, th] : toJoin) {
        if (th.joinable()) th.join();
    }
}

// [Co-developed with claude code -- Adam]
// Records a shutdown-window drop and says so once.
//
// Once, not per job: a bulk enqueue arriving during shutdown would otherwise emit a line per
// job, and the thing worth knowing -- that delivery stopped while callers were still being told
// "queued" -- is established by the first one. The running total is what a test or a post-mortem
// reads; the log line is what makes it visible to somebody who was not looking for it.
void FlowDispatcher::noteDropped_(size_t n)
{
    const uint64_t before = droppedAfterStop_.fetch_add(n, std::memory_order_relaxed);
    if (before == 0 && n > 0)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "FlowDispatcher is stopped; dropping {} flow job(s). Anything that "
                           "already answered \"queued\" for these will not be delivered.",
                           n);
    }
}

void FlowDispatcher::enqueue(const FlowJob& job) {
    {
        std::lock_guard<std::mutex> lk(mtx_);
        // [Co-developed with claude code -- Adam]
        // Refuse once stopped. A worker spawned after stop() has moved workers_ out is owned by
        // nobody: its std::thread is destroyed while joinable, which is std::terminate. Dropping
        // the job is the honest outcome -- the dispatcher is shutting down and cannot deliver it.
        if (!running_) {
            noteDropped_(1);
            return;
        }
        auto& q = queues_[job.dpid];
        q.push_back(job);
        if (!workers_.count(job.dpid)) {
            // spawn worker lazily per DPID
            workers_[job.dpid] = std::thread(&FlowDispatcher::workerLoop_, this, job.dpid);
        }
    }
    cv_.notify_all();
}

void FlowDispatcher::enqueue(std::vector<FlowJob> jobs) {
    {
        std::lock_guard<std::mutex> lk(mtx_);
        // [Co-developed with claude code -- Adam] As the single-job overload.
        if (!running_) {
            noteDropped_(jobs.size());
            return;
        }
        for (auto& job : jobs) {
            queues_[job.dpid].push_back(std::move(job));
            if (!workers_.count(job.dpid)) {
                workers_[job.dpid] = std::thread(&FlowDispatcher::workerLoop_, this, job.dpid);
            }
        }
    }
    cv_.notify_all();
}

void FlowDispatcher::workerLoop_(uint64_t dpid) {
    std::vector<FlowJob> burst;
    burst.reserve(burstSize_);

    while (true) {
        {
            std::unique_lock<std::mutex> lk(mtx_);
            cv_.wait(lk, [&]{
                return !running_ || !queues_[dpid].empty();
            });
            if (!running_ && queues_[dpid].empty()) break;

            burst.clear();
            auto& q = queues_[dpid];

            // Optional: coalesce pending ops by (match key) here if desired.

            while (!q.empty() && burst.size() < burstSize_) {
                burst.push_back(std::move(q.front()));
                q.pop_front();
            }
        }
        if (!burst.empty()) {
            sender_(burst); // send to southbound in one big push
        }
    }
}
