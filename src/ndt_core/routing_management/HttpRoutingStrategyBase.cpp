// [Co-developed with claude code -- Adam]
#include "ndt_core/routing_management/HttpRoutingStrategyBase.hpp"

#include "spdlog/spdlog.h"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"

#include <sstream>
#include <string>

using json = nlohmann::json;

namespace
{

/// What curl's stdout told us.
///
/// [Co-developed with claude code -- Adam]
/// `statusLinePresent` is new, and it is the fix for doc/KNOWN-ISSUES.md B-2b's misattribution.
/// The old version returned `{output, 0}` for two situations that mean opposite things:
///   - curl ran, could not connect, and wrote `000` -- the component really is unreachable;
///   - curl produced nothing at all -- it never ran, so nothing was ever asked of the component.
/// Collapsing both to status 0 is what let a broken command line be reported as a dead controller.
/// -w '\n%{http_code}' is written by curl on every completed invocation, connection failures
/// included, so its absence is a reliable signal that curl itself did not run.
struct CurlOutput
{
    std::string body;
    int httpStatus = 0;
    bool statusLinePresent = false;
};

CurlOutput
splitBodyAndStatus(const std::string& output)
{
    const auto lastNewline = output.find_last_of('\n');
    if (lastNewline == std::string::npos)
    {
        // No status line: curl itself failed to run, or produced nothing.
        return {output, 0, false};
    }

    const std::string statusText = output.substr(lastNewline + 1);
    const std::string body = output.substr(0, lastNewline);

    int status = 0;
    try
    {
        status = std::stoi(statusText);
    }
    catch (const std::exception&)
    {
        // Trailing line was not a number, so treat it as part of the body.
        return {output, 0, false};
    }
    return {body, status, true};
}

/// Trims to a length that is useful in a log line without dumping a whole response.
std::string
briefly(const std::string& text, size_t limit = 200)
{
    std::string out = text;
    // Collapse newlines so a multi-line error body stays on one log line.
    for (char& c : out)
    {
        if (c == '\n' || c == '\r')
        {
            c = ' ';
        }
    }
    if (out.size() > limit)
    {
        out.resize(limit);
        out += "...";
    }
    return out;
}

} // namespace

utils::CommandOutcome
HttpRoutingStrategyBase::executeArgv(const std::vector<std::string>& argv)
{
    return utils::execArgv(argv);
}

OpResult
HttpRoutingStrategyBase::post(const std::string& path, const json& body, const char* operation)
{
    // [Co-developed with claude code -- Adam]
    // doc/KNOWN-ISSUES.md B-2b. This was one std::ostringstream producing a shell command line,
    // with body.dump() interpolated between two single quotes. json::dump() escapes what JSON
    // needs escaped, and `'` is not a JSON metacharacter, so it went through untouched: a match
    // value containing a quote ended the quoting and everything after it was read by /bin/sh as
    // commands. Since the northbound API listens on 0.0.0.0:8000 with no authentication and match
    // values come straight from it, that was remote command execution, not a formatting bug.
    //
    // An argument vector has no such reading. Each element is one argument to execvp, so a quote,
    // a semicolon, a newline, `$(...)` and a backtick are all just bytes inside the body. Note
    // this is not "escaping done right" -- there is no character table here to get wrong, which is
    // the property that makes it a fix rather than a patch. -w still asks for the status on its
    // own line; --max-time still bounds a hung controller.
    //
    // The one subtlety worth stating: "\\n%{http_code}" keeps its backslash-n. The shell used to
    // strip the single quotes and hand curl a literal backslash followed by 'n', which curl itself
    // turns into a newline. Passing an actual newline here instead would change curl's output
    // shape and break splitBodyAndStatus.
    const std::vector<std::string> argv = {"curl",
                                           "-s",
                                           "-w",
                                           "\\n%{http_code}",
                                           "--max-time",
                                           std::to_string(REQUEST_TIMEOUT_SECONDS),
                                           "-X",
                                           "POST",
                                           "http://" + apiUrl() + path,
                                           "-H",
                                           "Content-Type: application/json",
                                           "-d",
                                           body.dump()};

    SPDLOG_LOGGER_DEBUG(Logger::instance(), "execArgv: {}", utils::describeArgv(argv));

    const utils::CommandOutcome outcome = executeArgv(argv);
    const CurlOutput curl = splitBodyAndStatus(outcome.output);

    // [Co-developed with claude code -- Adam]
    // The honesty half of B-2b, and the half that is not fixed by removing the shell. Whenever the
    // request did not leave this host, the verdict must name this host. It used to name the
    // component -- "no response from <component> at <url> within 5s" -- for causes the component
    // had no part in, and round 4 measured that a genuinely dead controller produced that exact
    // sentence, so the log could not tell the two apart. Naming the local cause is what makes the
    // message actionable; the status code (500, not 502) is what makes it actionable to a program.
    if (!outcome.ran)
    {
        auto result = OpResult::notSent(
            std::string("this kernel could not run curl, so the ") + describe() + " at " +
            apiUrl() + " was never asked: " + utils::describeCommandStatus(outcome.status));
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} failed: {}", operation, result.message);
        return result;
    }

    if (!curl.statusLinePresent)
    {
        // curl writes the -w line on every completed invocation, connection failures included, so
        // its absence means curl did not complete. Exit 127 is the common cause (not installed).
        auto result = OpResult::notSent(
            std::string("curl produced no status line, so the ") + describe() + " at " + apiUrl() +
            " was never asked: " + utils::describeCommandStatus(outcome.status, "curl"));
        SPDLOG_LOGGER_WARN(Logger::instance(), "{} failed: {}", operation, result.message);
        return result;
    }

    const std::string& responseBody = curl.body;
    const int status = curl.httpStatus;

    if (status == 0)
    {
        // Now unambiguous: curl ran, reported %{http_code} == 000, and that means it really could
        // not get an answer. This sentence has earned the right to name the component.
        auto result = OpResult::unreachable(
            std::string("no response from ") + describe() + " at " + apiUrl() +
            " within " + std::to_string(REQUEST_TIMEOUT_SECONDS) + "s");
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} failed: {}",
                           operation,
                           result.message);
        return result;
    }

    if (status < 200 || status >= 300)
    {
        auto result = OpResult::failure(
            status,
            std::string(describe()) + " returned HTTP " + std::to_string(status) +
                (responseBody.empty() ? "" : ": " + briefly(responseBody)));
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} failed: {}",
                           operation,
                           result.message);
        return result;
    }

    // Some proxies answer 200 with {"status":"error"} in the body. Ryu does not, but the P4
    // proxy agent does, so a 2xx alone is not proof of success.
    if (!responseBody.empty())
    {
        try
        {
            const auto parsed = json::parse(responseBody);
            if (parsed.is_object() && parsed.contains("status") &&
                parsed["status"].is_string() &&
                parsed["status"].get<std::string>() == "error")
            {
                auto result = OpResult::failure(
                    status,
                    std::string(describe()) + " reported an error in a " +
                        std::to_string(status) + " response: " + briefly(responseBody));
                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "{} failed: {}",
                                   operation,
                                   result.message);
                return result;
            }
        }
        catch (const json::exception&)
        {
            // Not JSON. Ryu's success replies are not always JSON, so this is not an error.
        }
    }

    return OpResult::success(status);
}

// --- flow entries -----------------------------------------------------------------

OpResult
HttpRoutingStrategyBase::deleteAnEntry(uint64_t dpid, const json& match, int priority)
{
    json body;
    body["dpid"] = dpid;
    body["match"] = match;

    // A priority of -1 means "delete anything matching", which is the non-strict route.
    // With a priority the strict route removes only the exact entry.
    if (priority == -1)
    {
        return post("/stats/flowentry/delete", body, "delete flow entry (non-strict)");
    }

    body["priority"] = priority;
    return post("/stats/flowentry/delete_strict", body, "delete flow entry (strict)");
}

OpResult
HttpRoutingStrategyBase::installAnEntry(uint64_t dpid,
                                        int priority,
                                        const json& match,
                                        const json& action,
                                        int idleTimeout)
{
    json body;
    body["dpid"] = dpid;
    body["priority"] = priority;
    body["match"] = match;
    body["actions"] = action;
    // -1 is the sentinel for "no timeout"; 0 means the same thing to Ryu but is also the
    // declared default, so both are treated as "omit the field".
    if (idleTimeout != -1 && idleTimeout != 0)
    {
        body["idle_timeout"] = idleTimeout;
    }

    return post("/stats/flowentry/add", body, "install flow entry");
}

OpResult
HttpRoutingStrategyBase::modifyAnEntry(uint64_t dpid,
                                       int priority,
                                       const json& match,
                                       const json& action)
{
    json body;
    body["dpid"] = dpid;
    body["match"] = match;
    body["actions"] = action;

    // [Co-developed with claude code -- Adam]
    // doc/KNOWN-ISSUES.md A-4e. This function used to set body["priority"] and then post to the
    // non-strict route -- the two lines contradicting each other, forty lines below a delete that
    // gets the same decision right. OFPFC_MODIFY does not compare priority, so the field was
    // carried all the way to the controller and ignored, and the modify landed on whichever entry
    // matched first. Measured on a live fabric: a request naming the caller's own priority-100
    // rule edited the router's priority-10 rule instead (same entry, confirmed by its unchanged
    // duration/n_packets), moved 32 MB of traffic onto the wrong port, and the damage outlived
    // deleting the caller's rule -- because the caller's rule had never been the one edited.
    //
    // The rule is now the same one deleteAnEntry has always used: a priority names an entry, so a
    // request that supplies one gets the strict route and can only ever touch that entry.
    //
    // The -1 branch is the caller who did not name an entry. Nothing in the kernel produces -1 for
    // a modify today (HttpSession::makeModifyJob defaults an absent priority to 0, unlike
    // makeDeleteJob which defaults to -1), so this is the symmetry with delete rather than a live
    // path -- and it is deliberately not "fixed" by changing that default, because FlowJob.hpp
    // records that `ad49347` aligned the flow-table cache with the dispatcher on absent-means-0
    // and de-aligning them again is a second defect, not a fix. An omitted priority therefore
    // still reaches here as 0 and now goes strict, which is safe in a way the old code was not:
    // strict compares the caller's own match as well, so priority 0 with a non-empty match hits
    // the caller's entry or nothing, where non-strict hit anybody's.
    if (priority == -1)
    {
        return post("/stats/flowentry/modify", body, "modify flow entry (non-strict)");
    }

    body["priority"] = priority;
    return post(strictModifyPath(), body, "modify flow entry (strict)");
}

/** @brief The route that modifies exactly the named entry. See the header for why this is virtual.
 *
 * [Co-developed with claude code -- Adam]
 */
const char*
HttpRoutingStrategyBase::strictModifyPath() const
{
    return "/stats/flowentry/modify_strict";
}

// --- group and meter entries -------------------------------------------------------

OpResult
HttpRoutingStrategyBase::installAGroupEntry(const json& j)
{
    return post("/stats/groupentry/add", j, "install group entry");
}

OpResult
HttpRoutingStrategyBase::deleteAGroupEntry(const json& j)
{
    return post("/stats/groupentry/delete", j, "delete group entry");
}

OpResult
HttpRoutingStrategyBase::modifyAGroupEntry(const json& j)
{
    return post("/stats/groupentry/modify", j, "modify group entry");
}

OpResult
HttpRoutingStrategyBase::installAMeterEntry(const json& j)
{
    return post("/stats/meterentry/add", j, "install meter entry");
}

OpResult
HttpRoutingStrategyBase::deleteAMeterEntry(const json& j)
{
    return post("/stats/meterentry/delete", j, "delete meter entry");
}

OpResult
HttpRoutingStrategyBase::modifyAMeterEntry(const json& j)
{
    return post("/stats/meterentry/modify", j, "modify meter entry");
}
