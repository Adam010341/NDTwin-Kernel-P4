#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <vector>

/**
 * @brief Operation type for a flow rule update.
 */
enum class FlowOp : uint8_t
{
    Install,
    Modify,
    Delete
};

/**
 * @brief A unit of work for OpenFlow rule updates.
 *
 * FlowJob represents one requested change to a switch flow table (install/modify/delete).
 * It carries the original JSON match/actions payload to send southbound, and also caches
 * parsed IPv4 destination information for fast lookups and “affected-flow” recomputation.
 *
 * Fields:
 *  - dpid: Target switch datapath ID.
 *  - op: Operation type (Install / Modify / Delete).
 *  - priority: Flow priority (OpenFlow rule priority).
 *  - match: Match fields in JSON form (e.g., eth_type, ipv4_dst).
 *  - actions: Actions in JSON form (e.g., OUTPUT port).
 *  - idleTimeout: Optional idle timeout in seconds (0 means no idle timeout unless your controller
 *    interprets it differently).
 */

struct FlowJob {
    uint64_t dpid;
    FlowOp op;
    int priority;
    nlohmann::json match;
    nlohmann::json actions;

    int idleTimeout = 0;
};

/**
 * @brief Why one flow-batch entry cannot become a rule, or an empty string if it can.
 *
 * [Co-developed with claude code -- Adam]
 *
 * @details Shape, not semantics. The distinction is what makes this answerable synchronously on
 * the HTTP thread: whether a field is present is O(1) and needs nothing outside the entry, while
 * whether the switch will *accept* the rule needs a round trip and belongs to the dispatcher.
 *
 * The gap this closes: `makeInstallJob` reads every field but `dpid` with `value(..., default)`,
 * so a body of `{"dpid": 1}` became a valid job -- priority 0, empty match, empty actions -- and
 * the caller got 200 "queued" for something that can never program anything. Answering 200 there
 * is defensible in isolation (it *was* queued) but it makes "accepted" mean nothing, since a
 * request with a typo in it is indistinguishable from a correct one.
 *
 * Deliberately NOT required, and each for a reason:
 *
 *  - **`actions: []` stays legal.** An empty action list is a drop rule, and Ryu's own table-miss
 *    entry is exactly `"actions": []`. The check is therefore *presence*, not non-emptiness --
 *    "I want this dropped" and "I forgot to say what to do" are different intents and only the
 *    second is an error.
 *  - **`match` is optional.** An absent match is match-all, which is what a table-miss rule needs.
 *  - **`priority` is optional.** Absent means 0, and both layers now agree on that (`ad49347`
 *    aligned the table cache with the dispatcher). It degrades precedence rather than inverting
 *    the rule's meaning, so it does not meet the bar above.
 *  - **Delete needs only `dpid`.** No match means "delete everything on this switch", which is a
 *    real operation, and actions are meaningless for a delete.
 */
inline std::string
describeFlowEntryShapeProblem(const nlohmann::json& entry, FlowOp op)
{
    if (!entry.is_object())
    {
        return "entry is not a JSON object";
    }
    if (!entry.contains("dpid"))
    {
        return R"(missing "dpid")";
    }
    // Non-negative integer, tested without assuming which of nlohmann's two integer storages the
    // value landed in. is_number_unsigned() alone is not that test: the parser picks it for a
    // non-negative literal, but a json built in C++ from an int holds number_integer, so the
    // stricter check passes over the wire and rejects the same dpid constructed in a test or by
    // any in-process caller. Found exactly that way.
    const auto& dpid = entry["dpid"];
    const bool nonNegativeInteger =
        dpid.is_number_unsigned() ||
        (dpid.is_number_integer() && dpid.get<std::int64_t>() >= 0);
    if (!nonNegativeInteger)
    {
        return R"("dpid" must be a non-negative integer)";
    }
    if (op != FlowOp::Delete && !entry.contains("actions"))
    {
        return R"(missing "actions" -- send "actions": [] if a drop rule is what you meant)";
    }
    return {};
}

/**
 * @brief The result of splitting a flow batch into what can be programmed and what cannot.
 *
 * [Co-developed with claude code -- Adam]
 *
 * @details `rejectedEntries` counts **entries**, `unknownDpids` lists **distinct switches**, and the
 * two are deliberately different numbers: forty entries naming one absent switch is one thing to
 * fix and forty things to re-send, so a caller needs both. unknownDpids is sorted and duplicate-free
 * so the same absent switch is named once however many entries mentioned it.
 */
struct FlowBatchPartition
{
    std::vector<FlowJob> accepted;
    std::vector<uint64_t> unknownDpids;
    std::size_t rejectedEntries = 0;
};

/**
 * @brief Split a flow batch by whether each entry's dpid is a switch this kernel knows about.
 *
 * [Co-developed with claude code -- Adam]
 *
 * @details Separated from HttpSession::processFlowBatch so the decision can be tested without a
 * TopologyAndFlowMonitor -- the routing test drives the real router with a null monitor, so any
 * logic that dereferences it is unreachable from a unit test. The topology lookup arrives as a
 * predicate; everything else here is arithmetic on a vector.
 *
 * Accepted entries keep their original relative order, because the dispatcher applies a modify
 * after the install it supersedes only if the order survives.
 *
 * @param jobs Parsed batch. Consumed: accepted entries are moved out.
 * @param dpidIsKnown Returns true when the dpid is a switch in the loaded topology.
 */
inline FlowBatchPartition
partitionFlowBatchByKnownDpid(std::vector<FlowJob> jobs,
                              const std::function<bool(uint64_t)>& dpidIsKnown)
{
    FlowBatchPartition out;
    out.accepted.reserve(jobs.size());

    for (auto& job : jobs)
    {
        if (dpidIsKnown(job.dpid))
        {
            out.accepted.push_back(std::move(job));
        }
        else
        {
            out.unknownDpids.push_back(job.dpid);
            ++out.rejectedEntries;
        }
    }

    std::sort(out.unknownDpids.begin(), out.unknownDpids.end());
    out.unknownDpids.erase(std::unique(out.unknownDpids.begin(), out.unknownDpids.end()),
                           out.unknownDpids.end());

    return out;
}

