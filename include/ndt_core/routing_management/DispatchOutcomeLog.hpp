// [Co-developed with claude code -- Adam]
#pragma once

#include "ndt_core/routing_management/FlowJob.hpp"
#include "ndt_core/routing_management/OpResult.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <mutex>
#include <nlohmann/json.hpp>
#include <string>
#include <vector>

/**
 * @brief The one place a dispatched flow job's outcome survives long enough to be asked about.
 *
 * [Co-developed with claude code -- Adam]
 *
 * @details Closes KNOWN-ISSUES A-7, "queued writes fail invisibly to every API".
 *
 * The chain this sits in: `POST /ndt/install_flow_entry` validates the batch, calls
 * `FlowDispatcher::enqueue`, and answers `200 {"status":"queued"}`. A worker thread later hands
 * the batch to Controller's sender, which calls `installAnEntry`/`modifyAnEntry`/`deleteAnEntry`
 * and gets back an OpResult saying whether the switch took the rule. Before this class, that
 * OpResult was logged with `SPDLOG_LOGGER_ERROR` and then went out of scope. `kernel.log` said
 * `dispatched install failed`; every API surface said nothing; the contract suite stayed green.
 * The failure was recorded in the one place no program reads.
 *
 * What this adds is deliberately not a fix for the asynchrony. The caller still gets `queued`,
 * because answering per-entry status to the original caller needs either a synchronous southbound
 * path or a completion handle, and both are architectural decisions with cross-repo consequences.
 * What it adds is that the failure is **afterwards answerable**: counters that are always on, and
 * the last few failures with enough identity to act on.
 *
 * ### Three decisions worth defending
 *
 * **The ring holds failures only.** A ring of *all* outcomes is the obvious design and it is the
 * wrong one here: one healthy 2000-job burst would evict every failure before anyone asked. The
 * successes are counted, not stored. Storage is spent on the rare thing.
 *
 * **Eviction is counted and published.** `failuresEvicted()` exists so the endpoint can say the
 * list is partial. A bounded buffer that silently drops its oldest entries reads to its consumer
 * exactly like a system with fewer failures than it has -- the same shape as the bug this class
 * exists to close, one level up.
 *
 * **`record()` sees every outcome, including successes.** It would be shorter to call it only on
 * failure. Routing successes through it too is what leaves the seam: "has this entry been
 * confirmed by the southbound?" is a question about successes, and this is the only point in the
 * process where a job and its OpResult exist together. Whoever answers it (T-11) adds an index
 * here and re-threads no call sites. Deliberately *not* built now -- an index nothing reads is
 * the kind of false affordance that cost this class's neighbour a `fencePerBurst` parameter.
 *
 * ### What it does not tell you
 *
 * Only what the **southbound reported**. A rule the controller accepts (`ok`, HTTP 200) can still
 * fail to be what the caller asked for: measured 2026-08-30, every requested priority is
 * programmed as 0 (`doc/audit/2026-08-30_live-traffic-round/FINDING-07_*`). "Dispatched
 * successfully" therefore means "the far end took it", not "the table now matches the request".
 * That is why the record keeps `requestedPriority` under a name that says *requested*.
 *
 * Thread-safety: `record()` is called from FlowDispatcher worker threads, one per DPID, so it is
 * called concurrently. Counters are atomic; the ring is under `mutex_`. Readers are HTTP threads.
 */
class DispatchOutcomeLog
{
  public:
    /// One dispatched job whose southbound attempt failed.
    struct Record
    {
        uint64_t seq = 0;         ///< Monotonic over all dispatched jobs, so gaps are visible.
        int64_t atUnixMs = 0;     ///< Wall clock, to line the entry up against kernel.log.
        FlowOp op = FlowOp::Install;
        uint64_t dpid = 0;
        /// What the caller asked for. Not necessarily what the switch programmed -- see above.
        int requestedPriority = 0;
        /// The caller's match, which is the identity that survives the trip (FINDING-07).
        nlohmann::json match;
        int controllerStatus = 0; ///< OpResult::httpStatus. 0 means nothing answered at all.
        std::string message;
    };

    /**
     * @param capacity How many failures to keep. 256 is about 12 KB of JSON and covers a burst
     *                 large enough to diagnose without being large enough to hide a leak.
     */
    explicit DispatchOutcomeLog(std::size_t capacity = 256)
    : capacity_(capacity == 0 ? 1 : capacity)
    {
    }

    /**
     * @brief Record the outcome of one dispatched job.
     *
     * Call for every job, success or failure. See the class note on why successes come here too.
     */
    void record(const FlowJob& job, const OpResult& result)
    {
        const uint64_t seq = dispatched_.fetch_add(1, std::memory_order_relaxed) + 1;

        if (result.ok)
        {
            succeeded_.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        failed_.fetch_add(1, std::memory_order_relaxed);

        Record rec;
        rec.seq = seq;
        rec.atUnixMs = nowUnixMs();
        rec.op = job.op;
        rec.dpid = job.dpid;
        rec.requestedPriority = job.priority;
        rec.match = job.match;
        rec.controllerStatus = result.httpStatus;
        rec.message = result.message;

        std::lock_guard<std::mutex> lk(mutex_);
        failures_.push_back(std::move(rec));
        while (failures_.size() > capacity_)
        {
            failures_.pop_front();
            evicted_.fetch_add(1, std::memory_order_relaxed);
        }
    }

    /// Every job handed to the southbound, successful or not.
    uint64_t dispatched() const { return dispatched_.load(std::memory_order_relaxed); }
    /// Jobs the southbound accepted. See the class note on what "accepted" does not mean.
    uint64_t succeeded() const { return succeeded_.load(std::memory_order_relaxed); }
    /// Jobs the southbound refused, or could not be asked because it was unreachable.
    uint64_t failed() const { return failed_.load(std::memory_order_relaxed); }
    /// Failures that have aged out of the ring. Non-zero means recentFailures() is partial.
    uint64_t failuresEvicted() const { return evicted_.load(std::memory_order_relaxed); }
    std::size_t capacity() const { return capacity_; }

    /// Snapshot, oldest first. Copies under the lock so a reader cannot tear a burst.
    std::vector<Record> recentFailures() const
    {
        std::lock_guard<std::mutex> lk(mutex_);
        return std::vector<Record>(failures_.begin(), failures_.end());
    }

    /// "install" / "modify" / "delete", for the response body and for logs.
    static const char* opName(FlowOp op)
    {
        switch (op)
        {
        case FlowOp::Install:
            return "install";
        case FlowOp::Modify:
            return "modify";
        case FlowOp::Delete:
            return "delete";
        }
        return "unknown";
    }

  private:
    static int64_t nowUnixMs()
    {
        using namespace std::chrono;
        return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
    }

    mutable std::mutex mutex_;
    std::deque<Record> failures_;
    const std::size_t capacity_;

    std::atomic<uint64_t> dispatched_{0};
    std::atomic<uint64_t> succeeded_{0};
    std::atomic<uint64_t> failed_{0};
    std::atomic<uint64_t> evicted_{0};
};
