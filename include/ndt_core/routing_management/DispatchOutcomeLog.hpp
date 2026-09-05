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
#include <optional>
#include <string>
#include <unordered_map>
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
 * ### The second counter group (W11, 2026-09-06)
 *
 * Everything above counts **dispatch**: did the far end take the request. That is the question
 * `succeeded` was named for and it is not the question it was read as. Measured 2026-09-05: the
 * same match installed 20 times moved it by +20 while the switch gained one row, and 15 deletes of
 * a match that had never existed moved it by a further +15 with nothing changing on any switch
 * (#54; R6 K-4). The number was never wrong -- it answered a different question from the one being
 * asked, which is why the fix is a second group and a rename, not an arithmetic change.
 *
 * So `acceptedBySwitch`/`rejectedBySwitch`/`switchOutcomeUnknown` count what is known about the
 * **switch**, from the one bit that carries it: the plane's own answer (OpResult). They partition
 * the same population as `dispatched`, so `accepted + rejected + unknown == dispatched` always --
 * and they are deliberately NOT part of `dispatched == dispatchedOk + dispatchFailed`, because a
 * dispatch that succeeded may still be unknown at the switch, which is the normal case on OVS.
 *
 * 🔴 **On today's OVS plane the answer is always `unknown`, and that is the honest answer rather
 * than a gap in the instrument.** OpenFlow does not acknowledge a FLOW_MOD and Ryu answers before
 * any switch has adjudicated anything, so nothing in the reply is evidence about a switch. The
 * temptation is to let `dispatchedOk` stand in for it; that would report a healthy OVS fabric as a
 * confirmed one and put the endpoint back to making the claim this ticket exists to remove. The
 * endpoint publishes the reason next to the number so a reader cannot mistake a permanent
 * `unknown` for "checked, nothing wrong" -- an always-unknown field that does not say why it is
 * unknown is the instrument-shaped-like-its-own-finding failure this repo keeps paying for.
 *
 * ### Per-request attribution (W11, 2026-09-06)
 *
 * The counters above are process-wide, so a caller cannot tell its own POST's outcome from a
 * concurrent writer's (R6 K-4). `noteRequestEnqueued()` registers a batch before it is dispatched
 * and `record()` attributes each outcome to it, so `tallyFor()` answers for one request. The map
 * is bounded like the failure ring and, like it, publishes how many entries it has forgotten:
 * a per-request answer that silently ages out reads exactly like a request that never existed.
 *
 * Thread-safety: `record()` is called from FlowDispatcher worker threads, one per DPID, so it is
 * called concurrently. Counters are atomic; the ring is under `mutex_` and the per-request map
 * under `requestMutex_` (a separate lock so the two are never held together). `noteRequestEnqueued`
 * is called from an HTTP thread -- the only writer here that is not the sender callback, and it
 * is a narrow one: it adds a request id, it does not touch any outcome. Readers are HTTP threads.
 */
class DispatchOutcomeLog
{
  public:
    /**
     * @brief What the plane's answer says about the switch, as opposed to about the dispatch.
     *
     * [Co-developed with claude code -- Adam] W11.
     * Three states rather than two, because "no answer to this question" is the answer on the OVS
     * plane and it must be representable. Derived from OpResult alone, so the classification lives
     * next to the bits that carry it and no caller can reach a fourth conclusion.
     */
    enum class SwitchOutcome
    {
        AcceptedBySwitch, ///< The plane adjudicated and the switch holds the rule.
        RejectedBySwitch, ///< The plane adjudicated and the switch does not hold it.
        Unknown           ///< Nothing in the answer is evidence about any switch.
    };

    /**
     * @brief One HTTP batch's own share of both counter groups.
     *
     * [Co-developed with claude code -- Adam] W11.
     * `enqueued` is set when the batch is handed to the dispatcher and the rest as its jobs come
     * back, so `dispatched < enqueued` means the batch is still draining -- a distinction the
     * global counters cannot express and the one a caller polling for its own result needs.
     */
    struct RequestTally
    {
        uint64_t enqueued = 0;
        uint64_t dispatched = 0;
        uint64_t dispatchedOk = 0;
        uint64_t dispatchFailed = 0;
        uint64_t acceptedBySwitch = 0;
        uint64_t rejectedBySwitch = 0;
        uint64_t switchOutcomeUnknown = 0;
    };
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
     * @brief Failure-ring size, in records.
     *
     * [Co-developed with claude code -- Adam] W11.
     * Was 256, "about 12 KB of JSON and a burst large enough to diagnose". 2026-09-05 ruling
     * (fifth grill round, honesty item 4): the ring is sized to the batch. FlowDispatcher's burst
     * is 2000 (FlowDispatcher.hpp: `burstSize = 2000`), so at 256 one bad burst could evict the
     * evidence of its own first three quarters, and `recent_failures_evicted` would be the only
     * trace -- a bounded buffer that drops its oldest entries reads to its consumer exactly like a
     * system with fewer failures than it has, which is the shape A-7 exists to close.
     *
     * Kept as a constructor parameter as well: the number that matters is the dispatcher's burst,
     * and the two live in different classes, so a caller that changes one can pass the other.
     */
    static constexpr std::size_t kDefaultCapacity = 2000;

    /**
     * @brief How many requests keep a per-request tally before the oldest is forgotten.
     *
     * [Co-developed with claude code -- Adam] W11. One entry is ~56 bytes, so this is under 15 KB
     * for the whole map. It bounds how far back a caller can ask about its own POST; the forgotten
     * count is published so "I have no record of that request" is never confused with "that
     * request had no outcomes".
     */
    static constexpr std::size_t kRequestBudget = 256;

    /**
     * @param capacity How many failures to keep. See kDefaultCapacity for why it is the
     *                 dispatcher's burst size rather than a round number.
     */
    explicit DispatchOutcomeLog(std::size_t capacity = kDefaultCapacity)
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

        // [Co-developed with claude code -- Adam] W11.
        // Before the ok/not-ok split, and above the early return the ok branch takes: the second
        // group partitions EVERY dispatched job, and a bucket that is only reached on one of the
        // two paths would stop closing against `dispatched` exactly when a burst was failing.
        const SwitchOutcome switchOutcome = classifySwitchOutcome(result);
        countSwitchOutcome_(switchOutcome);
        noteRequestOutcome_(job.requestId, result.ok, switchOutcome);

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

    /**
     * @brief Which of the three switch-side buckets this answer belongs in.
     *
     * [Co-developed with claude code -- Adam] W11.
     * Static and total: every OpResult lands in exactly one bucket, so the group closes against
     * `dispatched` by construction rather than by three call sites agreeing. The two OpResult bits
     * are set on different code paths and can never both be true; if they somehow were,
     * `AcceptedBySwitch` wins here only because a first branch has to win -- the invariant is
     * asserted in DispatchOutcomeLogTest.TheTwoSwitchSideBitsAreNeverBothSet, not assumed.
     */
    static SwitchOutcome classifySwitchOutcome(const OpResult& result)
    {
        if (result.confirmsProgramming)
        {
            return SwitchOutcome::AcceptedBySwitch;
        }
        if (result.confirmsNotProgrammed)
        {
            return SwitchOutcome::RejectedBySwitch;
        }
        return SwitchOutcome::Unknown;
    }

    /// Every job handed to the southbound, successful or not.
    uint64_t dispatched() const { return dispatched_.load(std::memory_order_relaxed); }

    /**
     * @brief Jobs the far end accepted the *request* for. Published as `dispatched_ok`.
     *
     * [Co-developed with claude code -- Adam] W11 (#54). This is the counter that used to be
     * called `succeeded` on the wire, and the rename is the whole of the A half: "succeeded" is
     * read as "the switch now has the rule" and it never meant that. It counts one thing well --
     * the request left this kernel and was not refused -- and it answers nothing about the
     * network. For that, read the switch-side group below.
     */
    uint64_t dispatchedOk() const { return succeeded_.load(std::memory_order_relaxed); }
    /// Jobs the southbound refused, or could not be asked because it was unreachable.
    /// Published as `dispatch_failed`.
    uint64_t dispatchFailed() const { return failed_.load(std::memory_order_relaxed); }

    /// The pre-W11 spellings, kept because the atomics and the existing tests use them. Not on
    /// the wire any more; prefer dispatchedOk()/dispatchFailed(), whose names say what they count.
    uint64_t succeeded() const { return dispatchedOk(); }
    uint64_t failed() const { return dispatchFailed(); }

    /// The plane adjudicated and the switch holds the rule. Always 0 on OVS -- see the class note.
    uint64_t acceptedBySwitch() const { return acceptedBySwitch_.load(std::memory_order_relaxed); }
    /// The plane adjudicated and the switch does not hold it. R6 K-4's no-op delete, on P4.
    uint64_t rejectedBySwitch() const { return rejectedBySwitch_.load(std::memory_order_relaxed); }
    /// Nothing in the answer was evidence about a switch. Every OVS dispatch lands here today.
    uint64_t switchOutcomeUnknown() const
    {
        return switchOutcomeUnknown_.load(std::memory_order_relaxed);
    }
    /// Failures that have aged out of the ring. Non-zero means recentFailures() is partial.
    uint64_t failuresEvicted() const { return evicted_.load(std::memory_order_relaxed); }
    std::size_t capacity() const { return capacity_; }

    /**
     * @brief Register a batch about to be dispatched, so its outcomes can be asked about later.
     *
     * [Co-developed with claude code -- Adam] W11.
     *
     * Called from the HTTP thread at enqueue time, which is the only place the request id and the
     * job count are both in scope. **Registration is what makes "I have never heard of that
     * request" a different answer from "that request has produced nothing yet"** -- without it, a
     * caller querying immediately after its POST (the normal case, since the dispatcher drains
     * asynchronously) would be told its id is unknown, and would not be able to tell that from a
     * typo. Both readings would be "no evidence", and only one of them is a reason to retry.
     *
     * Ignores id 0, which means "not from an HTTP batch", and ignores a re-registration of an id
     * already present so a caller cannot reset another request's counts by replaying its id.
     */
    void noteRequestEnqueued(uint64_t requestId, uint64_t jobs)
    {
        if (requestId == 0)
        {
            return;
        }
        std::lock_guard<std::mutex> lk(requestMutex_);
        auto [it, inserted] = requests_.try_emplace(requestId);
        if (!inserted)
        {
            return;
        }
        it->second.enqueued = jobs;
        requestOrder_.push_back(requestId);
        evictOldestRequests_();
    }

    /// One request's tally, or nullopt when this log has no record of that id -- which means
    /// either it was never registered, or it has aged out (requestsForgotten() says which is
    /// possible).
    std::optional<RequestTally> tallyFor(uint64_t requestId) const
    {
        if (requestId == 0)
        {
            return std::nullopt;
        }
        std::lock_guard<std::mutex> lk(requestMutex_);
        const auto it = requests_.find(requestId);
        if (it == requests_.end())
        {
            return std::nullopt;
        }
        return it->second;
    }

    /// How many requests currently have a tally.
    std::size_t requestsTracked() const
    {
        std::lock_guard<std::mutex> lk(requestMutex_);
        return requests_.size();
    }

    /// How many requests have aged out. Non-zero means an unknown id may once have been real.
    uint64_t requestsForgotten() const
    {
        return requestsForgotten_.load(std::memory_order_relaxed);
    }

    std::size_t requestCapacity() const { return kRequestBudget; }

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
    // [Co-developed with claude code -- Adam] W11.
    void countSwitchOutcome_(SwitchOutcome outcome)
    {
        switch (outcome)
        {
        case SwitchOutcome::AcceptedBySwitch:
            acceptedBySwitch_.fetch_add(1, std::memory_order_relaxed);
            return;
        case SwitchOutcome::RejectedBySwitch:
            rejectedBySwitch_.fetch_add(1, std::memory_order_relaxed);
            return;
        case SwitchOutcome::Unknown:
            switchOutcomeUnknown_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
    }

    /**
     * Add one outcome to its request's tally.
     *
     * [Co-developed with claude code -- Adam] W11. An unregistered id is NOT created here. A
     * tally that appeared on first outcome would make "unknown request" mean "unknown, or known
     * and not yet drained", collapsing the distinction noteRequestEnqueued exists to draw. A job
     * whose request has aged out is counted in the global totals only, which is what
     * requestsForgotten() warns a reader about.
     */
    void noteRequestOutcome_(uint64_t requestId, bool ok, SwitchOutcome outcome)
    {
        if (requestId == 0)
        {
            return;
        }
        std::lock_guard<std::mutex> lk(requestMutex_);
        const auto it = requests_.find(requestId);
        if (it == requests_.end())
        {
            return;
        }
        RequestTally& tally = it->second;
        ++tally.dispatched;
        if (ok)
        {
            ++tally.dispatchedOk;
        }
        else
        {
            ++tally.dispatchFailed;
        }
        switch (outcome)
        {
        case SwitchOutcome::AcceptedBySwitch:
            ++tally.acceptedBySwitch;
            break;
        case SwitchOutcome::RejectedBySwitch:
            ++tally.rejectedBySwitch;
            break;
        case SwitchOutcome::Unknown:
            ++tally.switchOutcomeUnknown;
            break;
        }
    }

    /// Caller must hold requestMutex_.
    void evictOldestRequests_()
    {
        while (requestOrder_.size() > kRequestBudget)
        {
            requests_.erase(requestOrder_.front());
            requestOrder_.pop_front();
            requestsForgotten_.fetch_add(1, std::memory_order_relaxed);
        }
    }

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

    // [Co-developed with claude code -- Adam] W11. Its own lock, never held together with mutex_:
    // record() calls noteRequestOutcome_ and then, on the failure path, takes mutex_ for the ring.
    // One lock covering both would make that a nesting order to maintain for no benefit -- the two
    // structures share no data.
    mutable std::mutex requestMutex_;
    std::unordered_map<uint64_t, RequestTally> requests_;
    std::deque<uint64_t> requestOrder_;
    std::atomic<uint64_t> requestsForgotten_{0};

    std::atomic<uint64_t> dispatched_{0};
    std::atomic<uint64_t> succeeded_{0};
    std::atomic<uint64_t> failed_{0};
    std::atomic<uint64_t> evicted_{0};
    std::atomic<uint64_t> forgotten_{0};

    // [Co-developed with claude code -- Adam] W11. The second group. Disjoint from the three
    // above and summing to the same total: accepted + rejected + unknown == dispatched.
    std::atomic<uint64_t> acceptedBySwitch_{0};
    std::atomic<uint64_t> rejectedBySwitch_{0};
    std::atomic<uint64_t> switchOutcomeUnknown_{0};
};
