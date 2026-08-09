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

