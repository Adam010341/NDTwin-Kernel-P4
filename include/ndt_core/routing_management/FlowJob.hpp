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
 * @brief Name of the provenance stamp carried by an optimistically-cached, not-yet-programmed
 *        flow entry. See FlowJob::token and KNOWN-ISSUES T-11.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Leading underscore because it is internal: DeviceConfigurationAndPowerManager::getOpenFlowTables
 * strips it before serving, so it never reaches a consumer and no consumer can come to depend on
 * it. Declared here, next to the token it names, so the writer (HttpSession), the stamper and the
 * filter cannot drift apart on a spelling -- a mismatch would silently disable the filter, which
 * is the failure this whole ticket is about.
 */
inline constexpr const char* kPendingTokenField = "_ndt_pending_token";

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

    /**
     * @brief Ties this job to the optimistic cache entry the HTTP layer wrote for it.
     *
     * [Co-developed with claude code -- Adam]
     *
     * KNOWN-ISSUES T-11. `install_flow_entry` writes the requested rule straight into the table
     * cache on the HTTP thread, before anything has been programmed, so
     * `get_switch_openflow_table_entries` serves it as though it were a table entry. The view
     * must only report entries the southbound has confirmed, and deciding which those are needs
     * an identity that survives the trip.
     *
     * **The match does not, and neither does the priority.** Measured 2026-08-30: every entry is
     * programmed at priority 0 whatever was requested (FINDING-07), and the cached copy carries
     * the caller's field vocabulary (`ipv4_dst`) while a polled one carries the switch's
     * (`nw_dst`). Matching a pending entry against a confirmation by comparing its *contents*
     * would therefore be comparing two different spellings of two different values.
     *
     * So the link is an opaque token minted once per entry, carried on the job and stamped on the
     * cache entry. It is **provenance, not a fingerprint**: it says "this cache row and this
     * dispatched job are the same request", which is a fact about where the row came from rather
     * than an inference from what it looks like. Deliberately not derived from any field, so no
     * future change to the wire format can make two different requests collide.
     *
     * 0 means "not minted by this path" -- an entry polled from the switch, or a job built by a
     * caller that predates tokens. Such entries are never filtered.
     */
    uint64_t token = 0;

    /**
     * @brief Which POST this job came from, so its outcome can be attributed to that caller.
     *
     * [Co-developed with claude code -- Adam]
     *
     * W11, from R6 K-4. `get_flow_dispatch_status` is the only programmatic read-back the flow
     * endpoints name in their own 200 body, and its counters are process-wide totals: a caller
     * reading them before and after its own POST is measuring every other writer as well. The
     * manual said so in as many words when the endpoint was first documented (§42, limit 1), and
     * "read them before and after" is only sound if you are the only writer -- which §27's
     * advisory lock does not let anyone guarantee.
     *
     * **One id per batch, not per entry.** The question a caller asks is "did the request I just
     * sent land", and the request is the batch. Per-entry ids would be a different endpoint (they
     * would have to be returned as a list the caller correlates by position, and both in-repo
     * writers discard the response body entirely), so this is deliberately the coarser identity.
     *
     * Distinct from `token`: a token is minted per *install* and exists to link an optimistic
     * cache row to its confirmation (T-11), so modifies and deletes have none. Every accepted job
     * of a batch carries the batch's request id, including deletes -- K-4 is a delete.
     *
     * 0 means "not from a tokened HTTP batch": a job built in a test, or by a caller predating
     * W11. Such a job is counted in the global totals only.
     */
    uint64_t requestId = 0;
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

