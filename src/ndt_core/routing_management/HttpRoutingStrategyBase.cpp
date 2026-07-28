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

/// Splits curl's output into (body, httpStatus). The status is the trailing line produced
/// by -w '\n%{http_code}'; curl reports 000 there when it could not connect at all.
std::pair<std::string, int>
splitBodyAndStatus(const std::string& output)
{
    const auto lastNewline = output.find_last_of('\n');
    if (lastNewline == std::string::npos)
    {
        // No status line: curl itself failed to run, or produced nothing.
        return {output, 0};
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
        return {output, 0};
    }
    return {body, status};
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

std::string
HttpRoutingStrategyBase::executeCommand(const std::string& cmd)
{
    return utils::execCommand(cmd);
}

OpResult
HttpRoutingStrategyBase::post(const std::string& path, const json& body, const char* operation)
{
    std::ostringstream cmd;
    // -w appends the status on its own line so both body and status come back through
    // stdout; --max-time bounds a hung controller. Note this still interpolates the JSON
    // into a shell command inside single quotes, which json::dump() does not escape --
    // tracked as a separate hardening task, and the reason this construction now lives in
    // exactly one place.
    cmd << "curl -s -w '\\n%{http_code}' --max-time " << REQUEST_TIMEOUT_SECONDS
        << " -X POST http://" << apiUrl() << path
        << " -H \"Content-Type: application/json\" -d '" << body.dump() << "'";

    SPDLOG_LOGGER_DEBUG(Logger::instance(), "execCommand: {}", cmd.str());

    const std::string output = executeCommand(cmd.str());
    const auto [responseBody, status] = splitBodyAndStatus(output);

    if (status == 0)
    {
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
    body["priority"] = priority;
    body["match"] = match;
    body["actions"] = action;

    return post("/stats/flowentry/modify", body, "modify flow entry");
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
