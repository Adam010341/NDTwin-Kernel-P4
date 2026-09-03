// [Co-developed with claude code -- Adam]
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

/**
 * @file StaleTableCarryForward.hpp
 * @brief Carry a switch's last known flow table into the next poll when this poll could not read
 *        it -- and say so in the answer.
 *
 * [Co-developed with claude code -- Adam]
 *
 * @details KNOWN-ISSUES F-6.
 *
 * ### What was wrong
 *
 * `fetchOpenFlowTablesInternal` builds a **fresh** array every poll and `continue`s past any
 * switch whose read failed; `openflowTablesUpdateWorker` then **replaces** the cache with that
 * array wholesale. So the four skip paths -- empty body, unparseable body, a proxy that reported
 * a read failure, and an empty-but-slow reply -- did not keep anything. They deleted the switch.
 *
 * Four places said otherwise, in the code that does the deleting:
 *
 *   - `DeviceConfigurationAndPowerManager.cpp:1079`  "tables are left as they were"
 *   - `:1098`  "Keeping the previous table is the same conservative choice the timeout path makes"
 *   - `:1122`  "Skipping leaves the previous table in place, the conservative direction"
 *   - `:1149`  "not as a switch with no rules. Keeping the previous table."
 *
 * plus the header's own `SuspectTimedOut, ///< ... Keep the previous table` and two test files
 * that describe the system that way. Nine statements of a policy, no implementation of it.
 *
 * ### Why deleting is worse than it looks
 *
 * Every consumer asks the same question the same way -- walk the array, match on `dpid`:
 * `HttpSession.cpp:622` serves the array verbatim; `IntentTranslator.cpp:1069` and
 * `LLMAgent.cpp:275` read it whole; `tools/contract_test/spec.py:295` (`inv_tables_non_empty`),
 * `doc/audit/2026-08-28_chaos-harness/harness/invariants.py:147` and
 * `doc/audit/2026-08-31_live-acceptance-batch/probe.py:52` all iterate and skip non-matching
 * dpids. For all of them a **missing** switch and a switch reporting **zero rules** produce the
 * identical answer.
 *
 * Which means the deletion silently re-created the exact defect `classifyFlowStatsReply` exists
 * to prevent. That verdict was written after 2026-08-07, when a wedged Ryu made the kernel state
 * that all ten switches held zero rules while s1 held 130. The verdict correctly refuses to
 * *apply* the empty table -- and then the wholesale swap applied it anyway, by omission.
 *
 * And the omission is not detectable by anything already in the tree: `inv_tables_non_empty`
 * iterates only the entries that are present, so a vanished switch produces no finding at all.
 *
 * ### The rule implemented here
 *
 * Keep the last copy **and mark it**. A stale table served as if it were fresh is one dishonesty
 * and a silently missing switch is another; a stale table that says `stale_since`, `stale_polls`
 * and `last_error` is neither, because the consumer can now tell.
 *
 * Markers are added to the switch object, never to the array's shape. That is deliberate: the
 * response's top level is a JSON array (`OF_TABLES = List(Obj(...))`,
 * `tools/contract_test/spec.py:121`) consumed by two repos this one cannot change, and
 * `schema.py:138` defaults `Obj(strict=False)` precisely so that "a kernel that *adds* a field is
 * not breaking anything". Wrapping the array in an object to hold a sibling `unreadable: [...]`
 * list would break every consumer above; adding fields breaks none of them.
 *
 * ### The distinction this must never lose
 *
 * Only switches whose read was **attempted and failed** are carried forward. A switch skipped
 * because it is down (`DeviceConfigurationAndPowerManager.cpp:1027`) was never read, is not in
 * the unread list, and must stay out: carrying those forward would keep a dead switch's rules
 * alive indefinitely, which is the optimistic direction of KNOWN-ISSUES F-4/F-16 -- a worse
 * failure than the one being fixed here.
 *
 * Free function in a header, like `PendingEntryFilter.hpp` and for the same reason: the rule can
 * be tested without constructing DeviceConfigurationAndPowerManager, which owns a topology
 * monitor, a classifier and three background threads. What stays in the caller is the lock and
 * the poll; what lives here is the decision.
 */

/// Epoch seconds (system clock) at which this switch first became unreadable. Preserved across
/// consecutive failed polls, so it answers "since when", not "as of this poll".
inline constexpr const char* kStaleSinceField = "stale_since";

/// Consecutive polls this switch has been unreadable, starting at 1. Clock-free, so a consumer
/// can threshold on it without agreeing with the kernel about what time it is.
inline constexpr const char* kStalePollsField = "stale_polls";

/// Why the last read failed. One of the kUnreadReason* tokens below -- a fixed vocabulary a
/// consumer can switch on, not a sentence. The human-readable version is already in the log.
inline constexpr const char* kLastErrorField = "last_error";

/// Present and true only when there is no previous copy to carry: this switch has never been read
/// successfully, so `flows` is empty because nothing is known, not because the switch has no
/// rules. Absent otherwise.
inline constexpr const char* kNeverReadField = "never_read";

/// Empty body: the control plane did not answer at all (connection refused, or curl printed
/// nothing). DeviceConfigurationAndPowerManager.cpp:1073.
inline constexpr const char* kUnreadNoResponse = "no_response";

/// A non-empty body that will not parse as JSON. DeviceConfigurationAndPowerManager.cpp:1095.
inline constexpr const char* kUnreadUnparseable = "unparseable";

/// The control plane answered "I could not read this switch" ({"error": ...}).
/// DeviceConfigurationAndPowerManager.cpp:1125.
inline constexpr const char* kUnreadReportedFailure = "reported_failure";

/// A body that parses, and whose per-switch value is still not a list of rules -- an object, a
/// number, a string. Round 6 finding N2: this was the one unreadable shape of three that carried
/// no marker at all, so `{"dpid":3,"flows":{"3":{"unexpected":"object"}}}` was republished
/// verbatim while its two neighbours were marked. Spelled the same in the topology path
/// (TopologyAndFlowMonitor::kOutcomeWrongShape), which is one vocabulary on purpose.
inline constexpr const char* kUnreadWrongShape = "wrong_shape";

/// Empty *and* slower than kFlowStatsSuspectSeconds: Ryu's stats timeout, not an empty table.
/// DeviceConfigurationAndPowerManager.cpp:1143.
inline constexpr const char* kUnreadSuspectTimeout = "suspect_timeout";

/**
 * @brief One switch whose flow-table read was attempted this poll and failed.
 *
 * [Co-developed with claude code -- Adam]
 */
struct UnreadSwitch
{
    std::uint64_t dpid{0};
    /// One of the kUnreadReason* tokens.
    std::string reason;
};

namespace ndt_detail
{

/// Index of the entry for `dpid` in a table array, or `tables.size()` if absent.
/// Tolerates malformed elements rather than throwing: this runs on the poll thread, and a
/// half-written cache must not take the worker down.
inline std::size_t
findSwitchIndex(const nlohmann::json& tables, std::uint64_t dpid)
{
    if (!tables.is_array())
    {
        return 0;
    }
    for (std::size_t i = 0; i < tables.size(); ++i)
    {
        const auto& sw = tables[i];
        if (sw.is_object() && sw.contains("dpid") && sw["dpid"].is_number() &&
            sw["dpid"].get<std::uint64_t>() == dpid)
        {
            return i;
        }
    }
    return tables.size();
}

} // namespace ndt_detail

/**
 * @brief Append the last known table of every switch this poll could not read, marked as stale.
 *
 * @param fresh            The array this poll built, holding only switches read successfully.
 *                         Modified in place.
 * @param previous         The cache as it stood before this poll. Read only.
 * @param unread           Switches whose read was attempted and failed, with the reason.
 * @param nowEpochSeconds  Wall-clock seconds, passed in rather than read here so the rule is
 *                         deterministic under test.
 * @return How many switches were carried forward, so a caller can log or assert on it.
 *
 * @details A switch already present in `fresh` is never touched: it was read successfully this
 * poll, so it carries no markers and any markers it had are gone. Recovery needs no separate
 * path -- the fresh entry simply replaces the stale one.
 *
 * `stale_since` is taken from the previous copy when that copy was itself stale, so it keeps
 * naming the first failed poll instead of resetting every ten seconds. `stale_polls` increments.
 * `last_error` is always this poll's reason: the reason can change while the switch stays
 * unreadable, and the latest one is the useful one.
 *
 * When there is no previous copy at all -- the read has failed since boot -- the switch is still
 * emitted, with an empty `flows` and `never_read: true`. That is the honest form of "I have
 * nothing for this switch": an empty table that says why it is empty. Omitting it is what this
 * function exists to stop.
 */
inline std::size_t
carryForwardUnreadTables(nlohmann::json& fresh,
                         const nlohmann::json& previous,
                         const std::vector<UnreadSwitch>& unread,
                         std::int64_t nowEpochSeconds)
{
    if (!fresh.is_array())
    {
        return 0;
    }

    std::size_t carried = 0;

    for (const auto& u : unread)
    {
        // Defensive: a dpid cannot be both read and unread in one poll, but if the caller ever
        // gets that wrong the successful read must win. Never overwrite fresh data with stale.
        if (ndt_detail::findSwitchIndex(fresh, u.dpid) != fresh.size())
        {
            continue;
        }

        nlohmann::json entry;
        bool hadPrevious = false;

        const std::size_t prevIndex = ndt_detail::findSwitchIndex(previous, u.dpid);
        if (previous.is_array() && prevIndex != previous.size())
        {
            entry = previous[prevIndex];
            hadPrevious = true;
        }

        if (!hadPrevious || !entry.is_object())
        {
            entry = nlohmann::json{{"dpid", u.dpid}, {"flows", nlohmann::json::object()}};
            entry[kNeverReadField] = true;
        }
        else
        {
            // A switch that was never read and still is not stays never_read; one that was read
            // once keeps its table and never acquires the flag.
            entry["dpid"] = u.dpid;
            if (!entry.contains("flows"))
            {
                entry["flows"] = nlohmann::json::object();
            }
        }

        const std::int64_t staleSince =
            (hadPrevious && entry.contains(kStaleSinceField) && entry[kStaleSinceField].is_number())
                ? entry[kStaleSinceField].get<std::int64_t>()
                : nowEpochSeconds;
        const std::int64_t priorPolls =
            (hadPrevious && entry.contains(kStalePollsField) && entry[kStalePollsField].is_number())
                ? entry[kStalePollsField].get<std::int64_t>()
                : 0;

        entry[kStaleSinceField] = staleSince;
        entry[kStalePollsField] = priorPolls + 1;
        entry[kLastErrorField] = u.reason;

        fresh.push_back(std::move(entry));
        ++carried;
    }

    return carried;
}
