// [Co-developed with claude code -- Adam]
// The rules a P4 pipeline push took with it, carried from the proxy into the kernel's log and onto
// /ndt/get_graph_data.
//
// KNOWN-ISSUES A-4c. A proxy restart and a readopt push the pipeline, and the push empties every
// table. The rules written through the Ryu-compatible API (/stats/flowentry/*) are NOT replayed --
// the proxy's journal records requests, not the reasons behind them, and a replayed
// traffic-engineering detour is a path nobody wants any more. Instead the proxy serves, per switch
// on GET /p4/switch_state, a `ryu_rules_lost` record of what the last push of that switch
// discarded: {id, cause, at, count (null = unknown), count_unknown, rules, rules_omitted,
// journal_unreadable, journal_write_failures, replayed}. The kernel reads it on the same 1 Hz
// request that feeds bmv2 liveness, logs an ERROR once per record id per kernel process, and
// copies the record verbatim onto the switch's graph node, which is where the apps (which poll
// get_graph_data) find it. Whoever installed the rules resends them.
//
// Absence means what it means for `capabilities` (P4Capabilities.hpp): the proxy said nothing, or
// could not be read. A record whose `count` is 0 is a push that took nothing of the Ryu path.
#pragma once

#include <nlohmann/json.hpp>

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

// Declared, not included, for the reason P4Capabilities.hpp gives.
struct VertexProperties;

namespace p4loss
{

/// dpid -> the `ryu_rules_lost` object the proxy served for that switch, verbatim.
using RecordsByDpid = std::map<std::uint64_t, nlohmann::json>;

/// Every switch's `ryu_rules_lost` in one GET /p4/switch_state body; same reading rules as
/// p4caps::fromSwitchState (a `null` record is no entry).
RecordsByDpid fromSwitchState(const std::optional<nlohmann::json>& payload);

/// One record the kernel has not announced before and that says something was lost.
struct Announcement
{
    std::uint64_t dpid = 0;
    std::string id;
    std::string cause;
    /// nullopt when the record's `count` is not a non-negative integer -- null is how the proxy
    /// says it cannot know: announced anyway, because a count nobody knows is not a zero.
    std::optional<std::int64_t> count;
    /// The proxy's `count_unknown`, when it gave one.
    std::string countUnknown;
    std::int64_t unreadable = 0;
    /// Writes the switch took that the proxy's journal could not record.
    std::int64_t writeFailures = 0;
};

/**
 * @brief Decides which records get an ERROR line: each `id` once per kernel process.
 *
 * A record is announced the first time its `id` (a non-empty string) is seen, unless it is a
 * known zero: `count` 0 with `journal_unreadable` and `journal_write_failures` both 0. A record without a usable `id` is never announced:
 * it could not be told apart from itself a second later, and the loop runs once a second.
 */
class Announcer
{
  public:
    std::vector<Announcement> observe(const RecordsByDpid& records);

  private:
    std::set<std::string> m_seen;
};

/// The ERROR line for one announcement.
std::string describe(const Announcement& announcement);

/// Adds `ryu_rules_lost` to one serialised switch node, when the proxy served one for it.
void attachToNode(nlohmann::json& node, const VertexProperties& vertex, const RecordsByDpid& records);

} // namespace p4loss
