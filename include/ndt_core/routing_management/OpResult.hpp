// [Co-developed with claude code -- Adam]
#pragma once

#include <string>
#include <utility>

/**
 * @brief Outcome of a southbound operation against a controller or proxy.
 *
 * Every routing and power method used to return void, and the layers beneath them threw
 * results away: curl ran with -s and no --fail, its return value was discarded,
 * executeCommand returned void, and the P4 proxy answered `{"status":"error"}` to nobody.
 * A dead controller, a rejected rule and a successful install were therefore
 * indistinguishable to the kernel, and /ndt/install_flow_entry answered 200 either way.
 *
 * This type is the smallest thing that fixes that: did it work, what did the far end say,
 * and why not. It is deliberately not an exception -- a rejected flow rule is an expected
 * outcome on a hot path handling thousands of entries per burst, not an exceptional one.
 */
struct OpResult
{
    bool ok = false;

    /**
     * HTTP status from the controller, or 0 when no response arrived at all.
     *
     * 0 is what curl reports as %{http_code} when it cannot connect, so it distinguishes
     * "the controller said no" from "the controller is not there" -- a distinction the
     * kernel could not previously make.
     */
    int httpStatus = 0;

    /// Human-readable reason, for logs and for the /ndt/ response body. Empty on success.
    std::string message;

    /**
     * Machine-readable name for what actually happened, for the /ndt/ response body.
     *
     * [Co-developed with claude code -- Adam] F-13.
     * `ok` and `httpStatus` answer "did the far end accept the request". They cannot answer
     * "and did the thing the caller named actually change", because for group and meter mods
     * Ryu answers 200 before the switch has adjudicated anything -- see
     * HttpRoutingStrategyBase::entryExists for the citation. This field carries the extra bit:
     * `deleted` means an entry that was verified present is now gone through, `unverified`
     * means the operation was forwarded but its precondition could not be checked, and
     * `no_such_group` names the reason for a refusal that shares its status code with another.
     *
     * Empty means the operation says nothing beyond `ok`, and respondToOpResult then omits the
     * field entirely -- an added key is a contract break for a strict client, so paths that
     * have nothing to add must not grow one.
     */
    std::string outcome;

    /**
     * Whether this answer is evidence that a switch now holds the rule.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md C-4. `ok` answers "did the far end accept the request". On the P4 plane
     * that is the same question, because the proxy agent programs the table before replying and
     * reports a per-entry refusal as {"status":"error"} in a 200 body. On the OVS plane it is not:
     * Ryu's /stats/flowentry/add returns once it has built the OFPFlowMod, and OpenFlow does not
     * acknowledge a FLOW_MOD, so its 200 is emitted before any switch has adjudicated anything.
     *
     * Measured 2026-09-03 on ovs4: a cache row served 0.257 s after the POST whose first real
     * sighting was 13.4 s later -- and the same for a legitimate rule as for an illegitimate one,
     * which is what proves the row is the cache's own rather than a verdict about the rule.
     *
     * So this is a second bit, answered by the strategy that owns the connection, and it is what
     * DispatchOutcomeLog::record requires before it will stamp a token as programmed.
     *
     * **Default false, and the direction is deliberate.** An answer that says nothing about
     * programming must not be read as confirming it. The cost of the conservative direction is a
     * real entry withheld until the next poll, which is recoverable; the cost of the optimistic
     * one is the phantom this exists to remove.
     */
    bool confirmsProgramming = false;

    /**
     * @brief Whether this answer is evidence that no switch holds the rule.
     *
     * [Co-developed with claude code -- Adam]
     * W11 (#54, R6 K-4). The mirror of confirmsProgramming, and the two are deliberately NOT a
     * single tri-state: they are set on different code paths by different facts, and a bool pair
     * that can be (false, false) is exactly the point -- "neither" is the answer on the OVS plane
     * and it has to be representable, because a counter that has to pick one of two buckets will
     * always pick the wrong one for a plane that adjudicates nothing.
     *
     * True requires BOTH halves: the far end answered at all (a request that never left this host,
     * or one that timed out, has told us nothing about any switch -- the misattribution
     * OpResult::notSent exists to stop), AND the plane that answered decides the entry before it
     * replies. On P4 the proxy programs the table and then reports a per-entry refusal, so a
     * refusal there is a verdict about the switch: the delete found nothing, the priority was not
     * honourable, the match was unsupported -- in every case the entry is not on the switch and we
     * know it. On OVS a Ryu rejection means Ryu declined to build the FlowMod, which is a
     * control-plane fact, not a switch's adjudication, so this stays false there.
     *
     * Read only by DispatchOutcomeLog::record, which uses it for the `rejected_by_switch` bucket
     * of the second counter group. Never read as "the operation failed" -- `ok` answers that, and
     * a failure with this bit clear has still failed.
     */
    bool confirmsNotProgrammed = false;

    /// A copy of this result carrying @p confirmed. Chainable at a return statement.
    OpResult withProgrammingConfirmed(bool confirmed) const
    {
        OpResult copy = *this;
        copy.confirmsProgramming = confirmed;
        return copy;
    }

    /// A copy of this result carrying @p refused as confirmsNotProgrammed. Chainable.
    /// [Co-developed with claude code -- Adam] W11.
    OpResult withProgrammingRefused(bool refused) const
    {
        OpResult copy = *this;
        copy.confirmsNotProgrammed = refused;
        return copy;
    }

    /// A copy of this result carrying @p name as its outcome. Chainable at a return statement.
    OpResult withOutcome(std::string name) const
    {
        OpResult copy = *this;
        copy.outcome = std::move(name);
        return copy;
    }

    static OpResult success(int status = 200)
    {
        return OpResult{true, status, "", ""};
    }

    static OpResult failure(int status, std::string why)
    {
        return OpResult{false, status, std::move(why), ""};
    }

    /// No response at all: the far end is unreachable, or the request timed out.
    static OpResult unreachable(std::string why)
    {
        return OpResult{false, 0, std::move(why), ""};
    }

    /**
     * @brief The request never left this host, so the far end has no case to answer.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md B-2b. unreachable() was being used for this too, and its message names
     * the component ("no response from <component> at <url>"). When the request was never sent --
     * the shell could not parse the command line, curl is not installed, fork failed -- that
     * sentence accuses a component the kernel never contacted, and it is byte-identical to what a
     * genuinely dead controller produces. An operator reading the log is sent to the wrong machine.
     *
     * 500 rather than 0: httpStatus 0 means noResponse(), which HttpSession maps to 502 Bad
     * Gateway -- "the gateway failed", which is the accusation being retracted. The fault is here,
     * so it is a 500, and it reaches the caller as one through the existing 400..599 passthrough
     * in HttpSession::respondToSouthboundResult without that function needing to change.
     *
     * @param why Must name the local cause, not the component. That is the whole point of the type.
     */
    static OpResult notSent(std::string why)
    {
        return OpResult{false, 500, std::move(why), ""};
    }

    /// The target data plane cannot express this operation (e.g. group entries on bmv2).
    static OpResult unsupported(std::string why)
    {
        return OpResult{false, 501, std::move(why), ""};
    }

    /// True when nothing answered, as opposed to answering with an error.
    bool noResponse() const
    {
        return httpStatus == 0;
    }

    explicit operator bool() const
    {
        return ok;
    }
};
