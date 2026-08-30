// [Co-developed with claude code -- Adam]
#pragma once

#include "ndt_core/routing_management/FlowJob.hpp"

#include <cstdint>
#include <functional>
#include <nlohmann/json.hpp>

/**
 * @brief Remove flow-table rows that were cached optimistically and never confirmed.
 *
 * [Co-developed with claude code -- Adam]
 *
 * @details KNOWN-ISSUES T-11, ruled option A: the table listing reports only entries that have
 * actually been programmed.
 *
 * Separated from DeviceConfigurationAndPowerManager::getOpenFlowTables so the decision can be
 * tested without constructing that class, which owns background threads, a topology monitor and a
 * classifier -- the same reason `partitionFlowBatchByKnownDpid` lives outside HttpSession. What is
 * left in the method is the lock and the copy; what is here is the rule.
 *
 * ### The rule, and the one thing it must never become
 *
 * A row is withheld when it **carries a token** and that token is **not confirmed**. Nothing else.
 * In particular it is never withheld for *looking like* a request -- four fields, no counters, the
 * caller's field vocabulary rather than the switch's. That signature is real, and it is what
 * FINDING-03 used to detect the phantom, but a filter keyed on it would be the same shape as the
 * thing it measures: a polled entry that happened to arrive without counters would vanish, and a
 * pending entry that happened to look complete would survive. Provenance answers "where did this
 * row come from", which is the actual question. Resemblance only ever answers "what does it look
 * like", and this project has already paid twice for instruments that confused the two.
 *
 * @param tables    The cached table view, modified in place.
 * @param isProgrammed Answers whether a token was confirmed by the southbound. May be empty, in
 *                  which case **every tokened row is withheld** -- the conservative default: an
 *                  unwired filter under-reports for up to one poll interval, where the opposite
 *                  default silently restores the phantom this exists to remove.
 * @return How many rows were withheld, so a caller can log or assert on it.
 */
inline std::size_t
stripUnprogrammedEntries(nlohmann::json& tables,
                         const std::function<bool(uint64_t)>& isProgrammed)
{
    std::size_t withheld = 0;

    if (!tables.is_array())
    {
        return withheld;
    }

    for (auto& sw : tables)
    {
        if (!sw.is_object() || !sw.contains("flows") || !sw["flows"].is_object())
        {
            continue;
        }

        for (auto& tableEntry : sw["flows"].items())
        {
            auto& entries = tableEntry.value();
            if (!entries.is_array())
            {
                continue;
            }

            nlohmann::json kept = nlohmann::json::array();
            for (auto& entry : entries)
            {
                const uint64_t token =
                    entry.is_object() ? entry.value(kPendingTokenField, uint64_t{0}) : 0;

                // Token 0 means the row did not come through the optimistic write path: it was
                // polled from the actual switch, or written by a caller predating tokens. The
                // filter has no provenance claim about those and must not hide them.
                if (token != 0 && !(isProgrammed && isProgrammed(token)))
                {
                    ++withheld;
                    continue;
                }

                // Strip on the way out, so the stamp never reaches a consumer and no consumer can
                // start depending on an internal field.
                if (entry.is_object())
                {
                    entry.erase(kPendingTokenField);
                }
                kept.push_back(std::move(entry));
            }
            entries = std::move(kept);
        }
    }

    return withheld;
}
