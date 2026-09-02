#pragma once
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>
#include <nlohmann/json.hpp>
#include "utils/Logger.hpp"

// Define available lock types using an Enum Class for type safety
enum class LockType {
    Routing,
    Graph,
    Power,
    Unknown // Used to indicate an invalid string input
};

// Structure to hold the state of a single lock
struct LockState {
    bool isLocked = false;
    std::chrono::steady_clock::time_point expiryTime;

    /**
     * [Co-developed with claude code -- Adam]
     * Identifies one *lease*, not one holder. Bumped by every successful acquire, never reused.
     *
     * This is deliberately not an owner field. An owner field means the kernel knows *who* is
     * calling, which it does not and cannot without a credential on the wire; KNOWN-ISSUES B-2②
     * is that problem and it is not this one. A lease id answers a narrower question that the
     * kernel *can* answer -- "is the lock still on the same lease it was on when you took it?"
     * -- and a caller that echoes the id it was given gets told when the answer is no.
     */
    std::uint64_t leaseId = 0;

    /// The lease that was last reclaimed by expiry on this lock, and how many have been. Kept so
    /// that a late release can be told what happened to it instead of being answered "released".
    std::uint64_t expiredLeaseId = 0;
    std::uint64_t expiredLeaseCount = 0;
};

class LockManager
{
  public:
    // --- Constants for Default Values (Single Source of Truth) ---
    static constexpr int DEFAULT_TTL_SECONDS = 5;
    static constexpr const char* DEFAULT_LOCK_TYPE_STR = "routing_lock";

  private:
    std::mutex m_mutex;
    // Using Enum as the key for the map is more efficient than using strings
    std::unordered_map<LockType, LockState> m_locks;

    /// Monotonic across every lock in this manager, so a lease id is unique per process run and
    /// two locks can never present the same id. Starts at 1: 0 means "no lease".
    std::uint64_t m_nextLeaseId = 1;

    /**
     * @brief Helper function to convert string input to LockType enum.
     * This enforces the naming convention (routing_lock, graph_lock, power_lock).
     *
     * static because it reads no member state, and because parseRequest() below needs it
     * before any LockManager exists. [Co-developed with claude code -- Adam]
     */
    static LockType stringToLockType(const std::string& str) {
        if (str == "routing_lock") return LockType::Routing;
        if (str == "graph_lock")   return LockType::Graph;
        if (str == "power_lock")   return LockType::Power;
        return LockType::Unknown;
    }

    /**
     * @brief The wire name of a LockType, for messages and logs.
     *
     * [Co-developed with claude code -- Adam]
     * The inverse of stringToLockType, written out rather than derived, so that a log line
     * always quotes the vocabulary the caller used rather than an enum's spelling.
     */
    static const char* lockTypeToString(LockType type) {
        switch (type) {
            case LockType::Routing: return "routing_lock";
            case LockType::Graph:   return "graph_lock";
            case LockType::Power:   return "power_lock";
            default:                return "unknown_lock";
        }
    }

    /**
     * @brief If this lock's lease has run out, end it -- visibly -- and report that it did.
     *
     * [Co-developed with claude code -- Adam]
     * 🔴 THIS IS THE CHANGE A-9 IS. Before it, expiry was a thing only `acquireLock` and (since
     * B-2①) `renew` *asked about*; nothing ever *recorded* it. `isLocked` stayed true forever,
     * so:
     *
     *   - `unlock()` answered true for a lease that had been dead for hours, and the endpoint
     *     answered 200 {"status":"released"} -- byte-identical to a real release;
     *   - worse, if somebody else had legitimately acquired in the meantime, that same late
     *     release cleared the NEW holder's flag. The new holder was never told. Two apps then
     *     both believed they held the lock that serialises writes to real switches;
     *   - and nothing anywhere -- no log line, no counter, no endpoint -- said a lease had ever
     *     been reclaimed. The TR-5 diagnosis (doc/audit/2026-08-30_live-traffic-round/
     *     FINDING-08) had to be made from the *application's* tmux buffer, because the kernel
     *     side of a held lock is not observable at all.
     *
     * The previous revision saw this and wrote it down rather than doing it, on the explicit
     * grounds that clearing `isLocked` on a refusal path "would silently alter what unlock()
     * answers for the same lock ... That is its own decision and it is not smuggled in here."
     * This is that decision, taken deliberately and pinned by tests: an expired lease is ended
     * here, once, in the one place all three of acquire/renew/release consult -- so the three
     * cannot drift apart about what "held" means, which is the failure that produced B-2① in the
     * first place.
     *
     * @return true if a lease was reclaimed by THIS call (so the caller can say `expired` rather
     *         than `not held`, which are different sentences to a client that thought it held it).
     *
     * @note Called with m_mutex already held, and it logs while holding it. That is a deliberate
     *       trade: the lock endpoints run at roughly 1 Hz (Energy-Saving-App's retry loop) and
     *       one WARN under a mutex costs less than the alternative, which is returning the fact
     *       out to three separate call sites and trusting each to log it.
     */
    bool reapIfExpired(LockType type, LockState& state,
                       std::chrono::steady_clock::time_point now)
    {
        if (!state.isLocked || now < state.expiryTime) {
            return false;
        }
        const auto overdue =
            std::chrono::duration_cast<std::chrono::seconds>(now - state.expiryTime).count();
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "lock {} lease {} expired {}s ago and is being reclaimed; its holder "
                           "never released it",
                           lockTypeToString(type), state.leaseId, overdue);
        state.isLocked = false;
        state.expiredLeaseId = state.leaseId;
        state.expiredLeaseCount += 1;
        return true;
    }

  public:
    /**
     * @brief What a release attempt actually did. [Co-developed with claude code -- Adam]
     *
     * Four answers, because the caller's next move differs for each and the old `bool` could
     * only say two. `Expired` in particular used to be reported as success.
     */
    enum class ReleaseOutcome {
        Released,      ///< a lease that was still in force was released by this call
        Expired,       ///< the lease had already run out and was reclaimed; nothing was released
        NotHeld,       ///< no lease at all, or an unknown lock name
        LeaseMismatch  ///< the caller named a lease that is not the current one -- refused
    };

    /// The renew twin of ReleaseOutcome, for the same reason: "expired" and "never held" are
    /// different problems with different fixes, and 412 alone cannot tell them apart.
    enum class RenewOutcome {
        Renewed,
        Expired,
        NotHeld,
        LeaseMismatch
    };

    /**
     * @brief What an acquire attempt saw, for callers that want to say more than "no".
     *
     * [Co-developed with claude code -- Adam]
     * Every field is optional to consume; the parameter defaults to nullptr so that every
     * existing caller and test compiles and behaves exactly as before.
     */
    struct AcquireReport {
        std::uint64_t leaseId = 0;             ///< set on success: the lease the caller now holds
        std::uint64_t blockingLeaseId = 0;     ///< set on refusal: the lease that is in the way
        long long     remainingSeconds = 0;    ///< set on refusal: how long that lease has left
        bool          reclaimedExpiredLease = false; ///< this acquire took over a dead lease
    };

    /// A read-only view of one lock, so that "who holds it and for how long" is answerable
    /// without having to try to take it. Nothing in the kernel could answer that before.
    struct LockSnapshot {
        bool          held = false;
        std::uint64_t leaseId = 0;
        long long     remainingSeconds = 0;
        std::uint64_t expiredLeaseCount = 0;
        std::uint64_t lastExpiredLeaseId = 0;
    };

    /**
     * @brief Check if the provided lock type string is valid.
     */
    static bool isValidType(const std::string& typeStr) {
        return stringToLockType(typeStr) != LockType::Unknown;
    }

    /**
     * @brief Why a lock request was refused, kept distinct because they need different answers.
     * [Co-developed with claude code -- Adam]
     */
    enum class RequestError {
        None,
        MalformedBody,   // the body is not JSON at all
        MissingType,     // no body, or valid JSON with no "type" field
        NonStringType,   // "type" present but not a string
        InvalidType      // "type" is a string, but not one of the three locks
    };

    /**
     * @brief Parse a lock-endpoint body into a decision, WITHOUT touching any lock.
     *
     * [Co-developed with claude code -- Adam]
     * This exists because the endpoints used to answer three different questions with one
     * behaviour: a malformed body, a body with no "type", and a body naming a lock that does
     * not exist all ended up acting on `routing_lock` on the caller's behalf -- the real lock
     * that serialises writes to the network. The handlers' `catch (...)` swallowed the parse
     * error and fell through with the defaults still in place, so "your JSON was rubbish" and
     * "you asked for routing_lock" were indistinguishable to the code and to the caller.
     *
     * Nothing is defaulted here. A caller that wants routing_lock has to say so. All in-tree
     * and sibling-repo consumers of all three endpoints already do -- acquire from
     * Energy-Saving-App http.cpp:425 and Traffic-Engineering-App:71, release from
     * Energy-Saving-App/src/app/http.cpp:461, Traffic-engineering-App.py:85 and the chaos
     * harness probes.py:206, renew only from probes.py:210 -- so refusing the implicit case
     * breaks no existing caller.
     *
     * `ttl` still defaults: it is a duration, not a target, and getting it wrong cannot make a
     * request act on something other than what it named.
     *
     * Shared by all three of acquire/renew/release (T-7b). The three endpoints disagreeing
     * about what a request means is precisely the failure being removed, so they are not given
     * three parsers to disagree with.
     */
    struct LockRequest {
        bool ok = false;
        std::string type;
        int ttl = DEFAULT_TTL_SECONDS;
        RequestError error = RequestError::None;
        std::string requestedType;   // what the caller actually sent, for the error message

        // [Co-developed with claude code -- Adam]
        // A-9. Optional, and 0 means "not named" -- see LockManager::release(). It gets the same
        // treatment as `ttl` and for the same stated reason: it cannot make a request act on
        // something other than the lock it named, it can only make the request act on LESS.
        // A wrong lease id refuses; it never redirects.
        std::uint64_t lease = 0;
    };

    static LockRequest parseRequest(const std::string& body)
    {
        LockRequest out;

        // An absent body is "you named no lock", not "your JSON is broken". They are both 400
        // and neither touches a lock, but only one of them is true, and an error message that
        // is false about what the caller sent is the bug this seam exists to remove.
        // [Co-developed with claude code -- Adam]
        if (body.find_first_not_of(" \t\r\n") == std::string::npos) {
            out.error = RequestError::MissingType;
            return out;
        }

        nlohmann::json parsed;
        try {
            parsed = nlohmann::json::parse(body);
        } catch (...) {
            out.error = RequestError::MalformedBody;
            return out;
        }
        if (!parsed.is_object() || !parsed.contains("type")) {
            out.error = RequestError::MissingType;
            return out;
        }
        if (!parsed["type"].is_string()) {
            // Present but not a string. Reported apart from "missing" because telling a caller
            // a field is missing when it can see the field in its own request body sends it
            // looking in the wrong place. handleReleaseLock already drew this distinction
            // before T-7b; folding it into the shared parser keeps it for all three endpoints
            // instead of losing it. [Co-developed with claude code -- Adam]
            out.requestedType = parsed["type"].dump();
            out.error = RequestError::NonStringType;
            return out;
        }
        out.requestedType = parsed["type"].get<std::string>();
        if (!isValidType(out.requestedType)) {
            out.error = RequestError::InvalidType;
            return out;
        }
        if (parsed.contains("lease") && parsed["lease"].is_number_unsigned()) {
            out.lease = parsed["lease"].get<std::uint64_t>();
        }
        if (parsed.contains("ttl") && parsed["ttl"].is_number_integer()) {
            out.ttl = parsed["ttl"].get<int>();
        }
        out.type = out.requestedType;
        out.ok = true;
        return out;
    }

    /**
     * @brief The refusal message for a parseRequest() decision.
     *
     * [Co-developed with claude code -- Adam]
     * One message table, not one per handler. `action` is the past participle the endpoint
     * would have performed ("acquired", "renewed", "released") so the sentence names what did
     * NOT happen -- the caller's next question after a 400 is always "did it do it anyway?",
     * which for these endpoints used to be "yes".
     *
     * Every message quotes what the caller sent, never what the server would have substituted.
     * The old shared sentence -- "System busy or invalid lock type: routing_lock" -- named a
     * lock the caller had not asked for, which is how the substitution stayed invisible.
     */
    static std::string describeError(const LockRequest& req, const char* action)
    {
        switch (req.error)
        {
            case RequestError::MalformedBody:
                return std::string("request body is not valid JSON; no lock was ") + action;
            case RequestError::MissingType:
                return std::string(
                           "missing required field \"type\"; expected one of routing_lock, "
                           "graph_lock, power_lock. There is no default on purpose -- it used "
                           "to be routing_lock, the lock that serialises writes to real "
                           "switches, so a request that never named it could still have it ")
                       + action;
            case RequestError::NonStringType:
                return "field \"type\" must be a string naming one of routing_lock, graph_lock, "
                       "power_lock; received " + req.requestedType;
            case RequestError::InvalidType:
                return "unknown lock type \"" + req.requestedType +
                       "\"; expected one of routing_lock, graph_lock, power_lock";
            default:
                return "invalid request";
        }
    }

    /**
     * @brief Attempt to acquire a lock.
     * @param lockNameStr The string name of the lock (e.g., "routing_lock").
     * @param ttlSeconds Time-To-Live in seconds.
     * @param report Optional; filled in with the lease taken, or with what blocked the attempt.
     * @return true if acquired successfully, false if busy or invalid name.
     *
     * [Co-developed with claude code -- Adam]
     * `report` defaults to nullptr so that every existing caller -- the endpoint, 29 unit tests,
     * the endpoint tests -- compiles and behaves exactly as it did. The endpoint passes one so
     * that a 200 can hand back the lease id, and a 423 can say how long the caller has to wait
     * instead of only that it must.
     */
    bool acquireLock(const std::string& lockNameStr, int ttlSeconds,
                     AcquireReport* report = nullptr)
    {
        // 1. Convert string to Enum
        LockType type = stringToLockType(lockNameStr);

        // 2. Validation: Reject unknown lock types
        if (type == LockType::Unknown) {
            SPDLOG_LOGGER_WARN(Logger::instance(), "Invalid lock type requested: {}", lockNameStr);
            return false;
        }

        std::lock_guard<std::mutex> lock(m_mutex);

        // 3. Access lock state using the Enum key
        LockState& state = m_locks[type];
        auto now = std::chrono::steady_clock::now();

        // 4. End an expired lease before deciding, so that "the previous holder's lease ran out"
        //    is recorded once, here, rather than being an invisible side effect of somebody
        //    else's successful acquire. The comparison itself is unchanged -- this call is what
        //    acquireLock's own `now < expiryTime` test always implied and never wrote down.
        const bool reclaimed = reapIfExpired(type, state, now);

        // 5. Check if it is currently locked and has not expired
        if (state.isLocked && now < state.expiryTime)
        {
            if (report) {
                report->blockingLeaseId = state.leaseId;
                report->remainingSeconds = std::chrono::duration_cast<std::chrono::seconds>(
                                               state.expiryTime - now)
                                               .count();
            }
            return false; // Lock is held by someone else
        }

        // 6. Acquire the lock, on a new lease. The id is never reused, so a caller that echoes
        //    it back on release or renew can be told when the lock has moved on without it.
        state.isLocked = true;
        state.expiryTime = now + std::chrono::seconds(ttlSeconds);
        state.leaseId = m_nextLeaseId++;
        if (report) {
            report->leaseId = state.leaseId;
            report->reclaimedExpiredLease = reclaimed;
        }
        return true;
    }

    /**
     * @brief Release a lock.
     *
     * @return true if a *held* lock of a *valid* type was released; false otherwise.
     *
     * [Co-developed with claude code -- Adam]
     * This used to return void and bare-return on an unknown type, so releasing a lock nobody
     * held and releasing a lock whose type does not exist were both silent no-ops -- and
     * /ndt/release_lock, having nothing to test, answered 200 "released" to each. An app that
     * typoed its release believed the lock was free while the real lock stayed held until TTL
     * expiry, blocking every other acquire with no error anywhere.
     *
     * The sibling renew() already returns bool and distinguishes exactly these three cases, so
     * this is the shape the class had settled on; only unlock had not been given it.
     *
     * 🔴 2026-09-02, A-9: this is now a two-valued view of release()'s four-valued answer, kept
     * so that existing callers compile and read the same. ONE ANSWER CHANGED: releasing a lease
     * that has already run out used to return **true** and now returns **false**, because the
     * lock was reclaimed by expiry rather than released by the caller. Callers that need to tell
     * `Expired` from `NotHeld` -- the endpoint does, they are different sentences to a client
     * that believed it held the lock -- must call release() directly.
     */
    bool unlock(const std::string& lockNameStr)
    {
        return release(lockNameStr) == ReleaseOutcome::Released;
    }

    /**
     * @brief Release a lock, and say which of the four things actually happened.
     *
     * [Co-developed with claude code -- Adam]
     * 🔴 A-9. `unlock()` above used to BE this function, and it could only answer two of the four:
     * it looked at `isLocked` and nothing else. Since expiry never cleared `isLocked`, a release
     * arriving after its own lease had run out found the flag still set, cleared it, and was
     * answered `200 {"status":"released"}` -- the same bytes as a real release. That is the shape
     * KNOWN-ISSUES A-9 was measured through: the Energy-Saving-App takes routing_lock with
     * ttl=300 and reaches its two release_lock() calls only on paths that need a
     * Simulation-Platform-Manager round trip, so on the TR-5 arms it never released at all.
     *
     * 🔑 THE DANGEROUS CASE IS NOT THE APP'S OWN. It is the one where somebody else has since
     * acquired legitimately:
     *
     *     t=0    A acquires routing_lock ttl=300           lease 7
     *     t=300  the lease runs out. Nothing notices.      isLocked is still true
     *     t=301  B acquires -- correctly, the lock is free lease 8
     *     t=302  A finally releases                        cleared LEASE 8, answered 200
     *
     * B was never told, and both apps then believed they held the lock that serialises writes to
     * real switches. Two things are done about it here, and it is worth being exact about which
     * one closes what:
     *
     *   1. The expired-lease case is no longer reported as a release. reapIfExpired() ends the
     *      lease first, so at t=302-with-nobody-else A gets `Expired`, not `Released`. Closed.
     *   2. The t=302-with-B-holding case CANNOT be closed by the kernel alone, because the two
     *      requests are byte-identical: `POST /ndt/release_lock {"type":"routing_lock"}`, with
     *      nothing in either that says who is asking. So `leaseId` is offered instead: a caller
     *      that passes back the id its acquire returned is refused with LeaseMismatch rather than
     *      releasing a stranger's lock. A caller that passes 0 -- which is every caller today --
     *      gets exactly the old behaviour. **This is opt-in, and until the sibling apps opt in,
     *      case 2 is still open.** It is KNOWN-ISSUES B-2②'s cross-repo protocol change, and
     *      pretending otherwise here would be the more expensive lie.
     *
     * @param leaseId 0 (the default) means "I am not naming a lease" and keeps the old,
     *                name-only behaviour. Non-zero is checked against the current lease.
     */
    ReleaseOutcome release(const std::string& lockNameStr, std::uint64_t leaseId = 0)
    {
        LockType type = stringToLockType(lockNameStr);
        if (type == LockType::Unknown) {
            SPDLOG_LOGGER_WARN(Logger::instance(), "Invalid lock type released: {}", lockNameStr);
            return ReleaseOutcome::NotHeld;
        }

        std::lock_guard<std::mutex> lock(m_mutex);
        const auto it = m_locks.find(type);
        if (it == m_locks.end()) {
            return ReleaseOutcome::NotHeld;
        }

        // Same reap the acquire path runs, in the same place in the sequence, so that the three
        // endpoints cannot disagree about whether this lock is held. Two functions in one class
        // answering that question differently is precisely how B-2① happened.
        if (reapIfExpired(type, it->second, std::chrono::steady_clock::now())) {
            return ReleaseOutcome::Expired;
        }

        if (!it->second.isLocked) {
            return ReleaseOutcome::NotHeld;
        }

        if (leaseId != 0 && leaseId != it->second.leaseId) {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "refused a release of {} naming lease {}; the current lease is {}. "
                               "The lock was NOT released",
                               lockTypeToString(type), leaseId, it->second.leaseId);
            return ReleaseOutcome::LeaseMismatch;
        }

        it->second.isLocked = false;
        return ReleaseOutcome::Released;
    }

    /**
     * @brief Read one lock's state without trying to take it.
     *
     * [Co-developed with claude code -- Adam]
     * Added for A-9. There was no way to ask this: the only three entry points all *change* the
     * lock, so "is routing_lock held, and for how long" could only be answered by trying to
     * acquire it -- which either fails (telling you nothing about how long) or succeeds (which is
     * not a read). The TR-5 write-up had to reconstruct the answer from the application's own
     * tmux buffer for exactly this reason.
     *
     * @note This does NOT reap. A read must not change what it is reading; `held` is reported
     *       against the same `now < expiryTime` test every writer uses, so an expired lease reads
     *       back as not held whether or not anybody has reaped it yet.
     */
    LockSnapshot snapshot(const std::string& lockNameStr)
    {
        LockSnapshot out;
        LockType type = stringToLockType(lockNameStr);
        if (type == LockType::Unknown) {
            return out;
        }

        std::lock_guard<std::mutex> lock(m_mutex);
        const auto it = m_locks.find(type);
        if (it == m_locks.end()) {
            return out;
        }

        const auto now = std::chrono::steady_clock::now();
        out.expiredLeaseCount = it->second.expiredLeaseCount;
        out.lastExpiredLeaseId = it->second.expiredLeaseId;
        if (it->second.isLocked && now < it->second.expiryTime) {
            out.held = true;
            out.leaseId = it->second.leaseId;
            out.remainingSeconds =
                std::chrono::duration_cast<std::chrono::seconds>(it->second.expiryTime - now)
                    .count();
        }
        return out;
    }

    /**
     * @brief Renew the TTL of a lock that is still in force.
     *
     * @return true if a held, unexpired lock of a valid type was extended; false otherwise.
     *
     * [Co-developed with claude code -- Adam]
     * 🔴 THIS USED TO RENEW AN EXPIRED LEASE, AND THAT IS HOW A NON-HOLDER LOCKED EVERYONE OUT.
     * The guard was `entry exists && isLocked`, with no time comparison anywhere. `isLocked` is
     * cleared only by unlock() and acquireLock(); expiry does not clear it. So an entry whose
     * lease had run out sat there `isLocked == true` forever, and renew() would put it back in
     * force for whoever asked -- with no requirement that the asker had ever held it:
     *
     *     A acquires routing_lock ttl=3 and dies.        the lease runs out; acquireLock would
     *                                                    now hand the lock to anybody
     *     C, holding nothing, renews it with ttl=120.    200 "renewed"
     *     D acquires.                                    refused, "held by another client",
     *                                                    for 120s, on behalf of nobody
     *
     * The contract has always said this is 412 (doc/2026-07-27_testing_workflow.md:221,
     * "renew_lock 用沒持有／過期的 lock -> 412"); the implementation just never asked the
     * question. KNOWN-ISSUES B-2①.
     *
     * 🔑 THE CONTROL GROUP WAS FORTY LINES UP THE SAME FILE. acquireLock() writes
     * `if (state.isLocked && now < state.expiryTime)` -- it compares. Two functions in one class
     * disagreeing about whether a lock is held is not a subtle bug; it is the same question
     * answered twice, and only one of them was ever asked.
     *
     * 🔴 WHAT THIS DOES **NOT** FIX, so nobody reads it as more than it is: renewing somebody
     * else's *live* lock still succeeds, because LockState has no owner field and unlock() takes
     * a lock name rather than a holder. That is B-2②, it is a separate change with a cross-repo
     * protocol cost, and it is not done here. This one closes only the case where the lease is
     * already dead -- i.e. it stops a lock nobody holds from being kept alive forever.
     *
     * An expired entry is deliberately left `isLocked == true` on the refusal path. Clearing it
     * would be a state change made by a call that returns false, and it would silently alter what
     * unlock() answers for the same lock (unlock currently reports true for an expired-but-flagged
     * entry). That is its own decision and it is not smuggled in here.
     *
     * 🔴 2026-09-02, A-9: THAT DECISION HAS NOW BEEN TAKEN, AND THE OPPOSITE WAY. An expired
     * entry IS cleared, by reapIfExpired(), on this path and on the release and acquire paths --
     * once, in one place, so the three cannot drift. The objection above was right about the
     * consequence and right to refuse to smuggle it in: unlock() *does* now answer differently
     * for an expired lock (false, not true), and that change is the point rather than a side
     * effect. See reapIfExpired() and release() for why.
     */
    bool renew(const std::string& lockNameStr, int ttlSeconds)
    {
        return renewLease(lockNameStr, ttlSeconds) == RenewOutcome::Renewed;
    }

    /**
     * @brief Renew, saying which of the four things happened. [Co-developed with claude code -- Adam]
     *
     * The renew twin of release(). `bool renew()` above is the two-valued view of it and is what
     * every existing caller and test uses; the endpoint calls this one so that its 412 can say
     * *which* precondition failed. "Your lease ran out while you were working" and "you never
     * held this" send a caller to two different places, and one status code cannot carry both.
     *
     * @param leaseId 0 (the default) keeps the old name-only behaviour. Non-zero is checked
     *                against the current lease -- see release() for why this is opt-in and what
     *                it does NOT close.
     */
    RenewOutcome renewLease(const std::string& lockNameStr, int ttlSeconds,
                            std::uint64_t leaseId = 0)
    {
        LockType type = stringToLockType(lockNameStr);
        if (type == LockType::Unknown) return RenewOutcome::NotHeld;

        std::lock_guard<std::mutex> lock(m_mutex);

        const auto it = m_locks.find(type);
        const auto now = std::chrono::steady_clock::now();

        if (it == m_locks.end()) {
            return RenewOutcome::NotHeld;
        }

        // Cannot renew a lock that does not exist, is not held, or whose lease has already run
        // out. The third clause is the one that was missing; the same `now < expiryTime` test
        // acquireLock uses, so the two agree about what "held" means. Since A-9 the expiry test
        // also *ends* the lease rather than only refusing on it, which is what makes the refusal
        // reportable as `expired` instead of being folded into `not held`.
        if (reapIfExpired(type, it->second, now)) {
            return RenewOutcome::Expired;
        }
        if (!it->second.isLocked) {
            return RenewOutcome::NotHeld;
        }

        if (leaseId != 0 && leaseId != it->second.leaseId) {
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "refused a renew of {} naming lease {}; the current lease is {}. "
                               "The lease was NOT extended",
                               lockTypeToString(type), leaseId, it->second.leaseId);
            return RenewOutcome::LeaseMismatch;
        }

        // Extend the expiry time
        it->second.expiryTime = now + std::chrono::seconds(ttlSeconds);
        return RenewOutcome::Renewed;
    }
};