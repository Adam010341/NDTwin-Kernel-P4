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
#include <unordered_set>
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
            // [Co-developed with claude code -- Adam]
            // doc/KNOWN-ISSUES.md C-4. This was an unconditional noteProgrammed_(job.token), and
            // that one line is the whole of the OVS half of B-1: `ok` means the far end took the
            // request, and only on P4 does the far end taking it imply that a switch programmed
            // it. Counting is deliberately unchanged -- an accepted entry is still a success.
            // Withholding a row from the table view is not the same claim as failing to dispatch
            // it, and merging the two would report a healthy OVS fabric as one full of rejected
            // rules: a different false alarm, not one fewer.
            if (result.confirmsProgramming)
            {
                noteProgrammed_(job.token);
            }
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

    /**
     * @brief Has the southbound confirmed the job that wrote this cache entry?
     *
     * [Co-developed with claude code -- Adam]
     *
     * KNOWN-ISSUES T-11's filter predicate. This is the index the A-7 note said a future ticket
     * would add here; adding it needed no change to any call site, which was the point of routing
     * successes through record().
     *
     * "Confirmed" means the plane's answer was an *adjudication*, not merely an acceptance --
     * see OpResult::confirmsProgramming. On OVS no answer to a flow-mod is an adjudication, so a
     * token there is confirmed by nothing and its row becomes visible when the periodic poll reads
     * it back off the switch. That is the contract, and it is about observation, not about elapsed
     * time: nothing here is waiting for a timer to expire.
     *
     * `token == 0` answers **true**: an untokened entry was not minted by the optimistic write
     * path -- it came from a poll of the actual switch, or from a caller predating tokens -- and
     * the filter must not hide entries it has no provenance claim about.
     *
     * Bounded, and the bound has a direction. Tokens age out oldest-first, and an aged-out token
     * reads as *unconfirmed*, so the failure mode is a real entry briefly hidden, never a phantom
     * shown. That is the conservative direction and it is chosen deliberately: the whole ticket
     * exists because the view was optimistic. The window is also self-limiting -- the periodic
     * poll replaces the entire cache roughly every 10.7 s, taking every pending entry with it, so
     * a token only has to survive that long to have done its job.
     */
    bool isProgrammed(uint64_t token) const
    {
        if (token == 0)
        {
            return true;
        }
        std::lock_guard<std::mutex> lk(mutex_);
        return programmed_.count(token) != 0;
    }

    /// How many confirmations aged out. Non-zero means isProgrammed() may be answering false for
    /// entries that really were programmed -- see the note there on why that direction was chosen.
    uint64_t confirmationsForgotten() const
    {
        return forgotten_.load(std::memory_order_relaxed);
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
    /// Remember a confirmed token, forgetting the oldest once the budget is spent.
    void noteProgrammed_(uint64_t token)
    {
        if (token == 0)
        {
            return;
        }
        std::lock_guard<std::mutex> lk(mutex_);
        if (programmed_.insert(token).second)
        {
            programmedOrder_.push_back(token);
        }
        while (programmedOrder_.size() > kProgrammedBudget)
        {
            programmed_.erase(programmedOrder_.front());
            programmedOrder_.pop_front();
            forgotten_.fetch_add(1, std::memory_order_relaxed);
        }
    }

    /// Enough to cover a full dispatcher burst (2000) several times over, which is the largest
    /// number of entries that can be pending against one cache generation.
    static constexpr std::size_t kProgrammedBudget = 8192;

    static int64_t nowUnixMs()
    {
        using namespace std::chrono;
        return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
    }

    mutable std::mutex mutex_;
    std::deque<Record> failures_;
    const std::size_t capacity_;

    /// Tokens of jobs the southbound confirmed, with insertion order so the oldest can be dropped.
    std::unordered_set<uint64_t> programmed_;
    std::deque<uint64_t> programmedOrder_;

    std::atomic<uint64_t> dispatched_{0};
    std::atomic<uint64_t> succeeded_{0};
    std::atomic<uint64_t> failed_{0};
    std::atomic<uint64_t> evicted_{0};
    std::atomic<uint64_t> forgotten_{0};
};
