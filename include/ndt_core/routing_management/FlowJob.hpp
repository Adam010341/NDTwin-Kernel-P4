#pragma once
#include <algorithm>
#include <arpa/inet.h>
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
 * @brief An IPv4 match value as the switch matches it: an address and a mask, both host order.
 *
 * [Co-developed with claude code -- Adam]
 */
struct Ipv4MatchValue
{
    uint32_t address = 0;
    uint32_t mask = 0xFFFFFFFFu;
};

/**
 * @brief Read one IPv4 match field (`ipv4_dst`, `nw_dst`, `ipv4_src`, `nw_src`), or nullopt.
 *
 * [Co-developed with claude code -- Adam]
 *
 * @details Accepts what a caller or a poll can put there: a bare address or a number (a /32, as
 * before), `a.b.c.d/len` with len 0..32 (accepted on the Ryu-compatible path since 2026-10-23), and
 * `a.b.c.d/m.m.m.m`, which is how Ryu's flow stats spell a masked match. Host bits are kept as
 * sent; whether a plane accepts them, or /0, is that plane's decision. Anything else is nullopt,
 * and processFlowBatch refuses the entry before queueing it (describeFlowEntryShapeProblem).
 */
inline std::optional<Ipv4MatchValue>
parseIpv4MatchValue(const nlohmann::json& v)
{
    if (v.is_number_unsigned())
    {
        const std::uint64_t n = v.get<std::uint64_t>();
        if (n > 0xFFFFFFFFull)
        {
            return std::nullopt;
        }
        return Ipv4MatchValue{static_cast<uint32_t>(n), 0xFFFFFFFFu};
    }
    if (v.is_number_integer())
    {
        const std::int64_t n = v.get<std::int64_t>();
        if (n < 0 || n > 0xFFFFFFFFll)
        {
            return std::nullopt;
        }
        return Ipv4MatchValue{static_cast<uint32_t>(n), 0xFFFFFFFFu};
    }
    if (!v.is_string())
    {
        return std::nullopt;
    }

    const std::string s = v.get<std::string>();
    // [Co-developed with claude code -- Adam] inet_pton reads through c_str(), so "10.0.0.4\0x" would
    // be read as 10.0.0.4; the proxy refuses it, and so must this.
    if (s.find('\0') != std::string::npos)
    {
        return std::nullopt;
    }
    const auto slash = s.find('/');
    const std::string addr = s.substr(0, slash);
    in_addr a{};
    if (inet_pton(AF_INET, addr.c_str(), &a) != 1)
    {
        return std::nullopt;
    }
    Ipv4MatchValue out{ntohl(a.s_addr), 0xFFFFFFFFu};
    if (slash == std::string::npos)
    {
        return out;
    }

    const std::string suffix = s.substr(slash + 1);
    const bool digits = !suffix.empty() && suffix.size() <= 2 &&
                        std::all_of(suffix.begin(), suffix.end(),
                                    [](char c) { return c >= '0' && c <= '9'; });
    if (digits)
    {
        const int len = std::stoi(suffix);
        if (len > 32)
        {
            return std::nullopt;
        }
        out.mask = (len == 0) ? 0u : (0xFFFFFFFFu << (32 - len));
        return out;
    }
    in_addr m{};
    if (inet_pton(AF_INET, suffix.c_str(), &m) != 1)
    {
        return std::nullopt;
    }
    out.mask = ntohl(m.s_addr);
    return out;
}

/// The four IPv4 match fields this kernel reads, in the order the shape check reports them.
inline constexpr const char* kIpv4MatchFields[] = {"ipv4_dst", "nw_dst", "ipv4_src", "nw_src"};

/// The two spellings of each of those fields: the kernel's cache reads the first of a pair, the
/// P4 proxy the second, so a request carrying both has to mean one address by them.
/// [Co-developed with claude code -- Adam]
inline constexpr const char* kIpv4MatchFieldPairs[][2] = {{"ipv4_dst", "nw_dst"},
                                                         {"ipv4_src", "nw_src"}};

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
 *
 * An IPv4 address field the kernel cannot read is refused here too, on every op -- a field that
 * is present as "" or null included; an absent field is simply absent. If both spellings of one
 * field are present (`ipv4_dst` with `nw_dst`, `ipv4_src` with `nw_src`) they must name the same
 * address once normalised (host bits below the mask ignored, `/32` the same as the bare address);
 * two different addresses are refused rather than left to whichever spelling a plane reads
 * first. These and the priority range check are the only content checks; the address checks exist
 * because the table cache reads these fields after the jobs are queued
 * (DeviceConfigurationAndPowerManager::updateOpenFlowTables): an unreadable one used to throw
 * there, turning the reply into an error for a request that had already been sent to the switch.
 * [Co-developed with claude code -- Adam]
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
    // [Co-developed with claude code -- Adam]
    // An OpenFlow priority is an integer from 0 to 65535. The job builders read it with
    // value("priority", default), which takes `true` as 1, truncates 1.5 and lets 2^32 wrap in an
    // int -- so a priority nobody asked for was queued, and on bmv2 a delete could be refused or
    // honoured by the proxy depending on which number it had become (KNOWN-ISSUES C-7). Absent
    // stays legal: install and modify default to 0, delete to the non-strict route.
    if (entry.contains("priority"))
    {
        const auto& priority = entry["priority"];
        const bool inRange =
            (priority.is_number_unsigned() && priority.get<std::uint64_t>() <= 65535) ||
            (priority.is_number_integer() && !priority.is_number_unsigned() &&
             priority.get<std::int64_t>() >= 0 && priority.get<std::int64_t>() <= 65535);
        if (!inRange)
        {
            return R"("priority" must be an integer from 0 to 65535 (omit it for the default))";
        }
    }
    if (const auto match = entry.find("match"); match != entry.end() && match->is_object())
    {
        for (const char* field : kIpv4MatchFields)
        {
            const auto v = match->find(field);
            if (v != match->end() && !parseIpv4MatchValue(*v))
            {
                return "\"match." + std::string(field) + "\" is " + v->dump() +
                       ", which is not an IPv4 address, a.b.c.d/len or a.b.c.d/mask";
            }
        }
        // [Co-developed with claude code -- Adam] Every present field is readable here.
        for (const auto& pair : kIpv4MatchFieldPairs)
        {
            const auto a = match->find(pair[0]);
            const auto b = match->find(pair[1]);
            if (a == match->end() || b == match->end())
            {
                continue;
            }
            const auto va = parseIpv4MatchValue(*a);
            const auto vb = parseIpv4MatchValue(*b);
            if (!va || !vb)
            {
                continue; // unreachable (the loop above refused it); keeps the dereferences checked
            }
            if (va->mask != vb->mask || (va->address & va->mask) != (vb->address & vb->mask))
            {
                return "\"match." + std::string(pair[0]) + "\" is " + a->dump() +
                       " and \"match." + std::string(pair[1]) + "\" is " + b->dump() +
                       ", which name different addresses; send one of them, or the same "
                       "address in both";
            }
        }
    }
    return {};
}

/**
 * @brief The match fields that send a P4 rule to flow_5tuple instead of ipv4_lpm.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md C-7. The kernel's copy of the P4 proxy's FIVE_TUPLE_ONLY_FIELDS
 * (p4_proxy/proxy_agent/topology_manager.py): every spelling the proxy maps to a flow_5tuple key,
 * minus the destination. A match naming none of them compiles to ipv4_lpm, which has no priority
 * column and one entry per destination. p4_proxy/tests/test_kernel_five_tuple_mirror.py reads
 * this list out of this file and fails if the two sets ever differ.
 */
inline constexpr const char* kP4FiveTupleOnlyMatchFields[] = {
    "in_port", "nw_src", "ipv4_src", "nw_proto", "ip_proto", "tp_src",
    "tcp_src", "udp_src", "tp_dst",  "tcp_dst",  "udp_dst",
};

/**
 * @brief Whether a delete entry is one the P4 proxy is known to refuse whatever the switch holds.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md C-7. A strict delete that names a priority, against a match that compiles
 * to ipv4_lpm, is refused by the proxy with 501 `priority not honourable on this table`
 * (api_routes._refuse_unhonourable_priority) before it reaches the topology -- and it used to be
 * queued here first, so every caller got 200 "queued" for a delete that could not happen.
 * Measured 2026-09-11: 2152 of 2152 such deletes refused, every POST answered 200.
 *
 * The same predicate as the proxy's, deliberately, so that for every entry that reaches it the two
 * refuse exactly the same requests. "Reaches it" matters: processFlowBatch runs
 * describeFlowEntryShapeProblem first, which refuses (400) any priority that is not an integer from
 * 0 to 65535 -- `true`, 1.5, "100", -1, 2^32 -- so here a priority is absent or such an integer, and
 * on that domain the proxy's slot_priority.named_priority is exactly "above 0":
 *   - absent and 0 name no entry (FlowRoutingManager's -1 sentinel never comes from a request);
 *   - the match names none of kP4FiveTupleOnlyMatchFields, or is not an object at all
 *     (needs_five_tuple answers False for a non-dict, and the refusal then fires).
 * The non-integer branches below are kept so a caller that skips the shape check is not refused on
 * a guess; they are not reachable from processFlowBatch.
 *
 * Pure and plane-blind: the caller decides whether the entry's dpid is a bmv2 switch.
 */
inline bool
isPriorityDeleteP4CannotHonour(const nlohmann::json& entry)
{
    if (!entry.is_object() || !entry.contains("priority"))
    {
        return false;
    }
    const auto& priority = entry["priority"];
    if (!priority.is_number() || priority.is_boolean())
    {
        return false;
    }
    const bool named = priority.is_number_float() ? priority.get<double>() >= 1.0
                       : priority.is_number_unsigned() ? priority.get<std::uint64_t>() > 0
                                                       : priority.get<std::int64_t>() > 0;
    if (!named)
    {
        return false;
    }
    const auto it = entry.find("match");
    if (it == entry.end() || !it->is_object())
    {
        return true;
    }
    for (const char* field : kP4FiveTupleOnlyMatchFields)
    {
        if (it->contains(field))
        {
            return false;
        }
    }
    return true;
}

/**
 * @brief The deletes of a batch split into those to queue and those refused up front on P4.
 *
 * [Co-developed with claude code -- Adam] doc/KNOWN-ISSUES.md C-7.
 */
struct P4DeleteRefusals
{
    /// The delete entries to queue, in their original order (a JSON array).
    nlohmann::json admitted = nlohmann::json::array();
    /// One object per refused entry: its index in the batch's delete list, dpid and priority.
    std::vector<nlohmann::json> refused;
};

/**
 * @brief Take out of @p deletes every entry that is a bmv2 switch's isPriorityDeleteP4CannotHonour.
 *
 * [Co-developed with claude code -- Adam] doc/KNOWN-ISSUES.md C-7. Run on the raw entries, before
 * any job is built, so that what is refused is neither queued NOR applied to the flow-table cache
 * (processFlowBatch hands the cache the request body; a delete the switch will never perform must
 * not remove a row from the view either).
 *
 * @param deletes The batch's `delete_flow_entries`. Precondition: already through
 *        describeFlowEntryShapeProblem, as processFlowBatch does, so every entry is an object with
 *        a non-negative integer `dpid` and a `priority` that is absent or an integer 0..65535.
 *        The function does not rely on it: see the note in the loop.
 * @param dpidIsBmv2 True when the dpid is a bmv2 switch of the loaded topology.
 */
inline P4DeleteRefusals
refusePriorityDeletesP4CannotHonour(const nlohmann::json& deletes,
                                    const std::function<bool(uint64_t)>& dpidIsBmv2)
{
    P4DeleteRefusals out;
    for (std::size_t i = 0; i < deletes.size(); ++i)
    {
        const auto& entry = deletes[i];
        // [Co-developed with claude code -- Adam]
        // No const operator[] here: on a missing key it asserts and aborts the process rather than
        // throwing. Under the @p deletes precondition every entry has a dpid and this never
        // matters; a caller that breaks it still gets an answer, not an abort: an entry without a
        // usable dpid is not refused here and comes back in `admitted` untouched (refusing a
        // malformed entry is the shape check's job, which such a caller skipped). `priority` is
        // present whenever the predicate is true; it is read with a default all the same.
        const auto dpid = entry.is_object() ? entry.find("dpid") : entry.end();
        const bool hasDpid =
            dpid != entry.end() &&
            (dpid->is_number_unsigned() ||
             (dpid->is_number_integer() && dpid->get<std::int64_t>() >= 0));
        if (isPriorityDeleteP4CannotHonour(entry) && hasDpid &&
            dpidIsBmv2(dpid->get<uint64_t>()))
        {
            out.refused.push_back(nlohmann::json{
                {"index", i},
                {"dpid", *dpid},
                {"requested_priority", entry.value("priority", nlohmann::json())}});
        }
        else
        {
            out.admitted.push_back(entry);
        }
    }
    return out;
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

