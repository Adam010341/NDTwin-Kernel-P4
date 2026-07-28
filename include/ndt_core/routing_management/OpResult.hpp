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

    static OpResult success(int status = 200)
    {
        return OpResult{true, status, ""};
    }

    static OpResult failure(int status, std::string why)
    {
        return OpResult{false, status, std::move(why)};
    }

    /// No response at all: the far end is unreachable, or the request timed out.
    static OpResult unreachable(std::string why)
    {
        return OpResult{false, 0, std::move(why)};
    }

    /// The target data plane cannot express this operation (e.g. group entries on bmv2).
    static OpResult unsupported(std::string why)
    {
        return OpResult{false, 501, std::move(why)};
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
