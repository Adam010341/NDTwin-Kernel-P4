#include "ndt_core/application_management/SimulationRequestManager.hpp"
#include "ndt_core/application_management/ApplicationManager.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <chrono>
#include <iomanip>
#include <iostream>
#include <memory>
#include <nlohmann/json.hpp>
#include <sstream>
#include <thread>

SimulationRequestManager::SimulationRequestManager(std::shared_ptr<ApplicationManager> appManager,
                                                   std::string simServerUrl,
                                                   int requestTimeoutSeconds)
    : m_applicatonManager(std::move(appManager)),
      SIM_SERVER_URL(simServerUrl),
      m_requestTimeoutSeconds(requestTimeoutSeconds)
{
}

SimulationRequestManager::~SimulationRequestManager() = default;

namespace
{

/// Comma-separates a list for one log/error line. Local because Utils.hpp has no join and this is
/// the only caller. [Co-developed with claude code -- Adam]
std::string
commaSeparated(const std::vector<std::string>& items)
{
    std::string out;
    for (const std::string& item : items)
    {
        if (!out.empty())
        {
            out += ", ";
        }
        out += item;
    }
    return out;
}

} // namespace

// [Co-developed with claude code -- Adam]
const std::vector<std::string>&
SimulationRequestManager::requiredRequestFields()
{
    static const std::vector<std::string> fields = {"simulator",
                                                    "version",
                                                    "app_id",
                                                    "case_id",
                                                    "inputfile"};
    return fields;
}

// [Co-developed with claude code -- Adam]
std::optional<std::string>
SimulationRequestManager::validateRequestBody(const std::string& body)
{
    // parse() rather than accept(): the field checks below need the parsed value, and a body that
    // parses but is a bare `[]` or `"text"` has no fields to check.
    nlohmann::json parsed;
    try
    {
        parsed = nlohmann::json::parse(body);
    }
    catch (const nlohmann::json::parse_error& e)
    {
        return std::string("body is not valid JSON: ") + e.what();
    }

    if (!parsed.is_object())
    {
        return std::string("body must be a JSON object, got ") + parsed.type_name();
    }

    // Every problem at once. Reporting only the first means an application with three mistakes
    // needs three round trips to find out.
    std::vector<std::string> missing;
    std::vector<std::string> wrongType;
    for (const std::string& field : requiredRequestFields())
    {
        const auto it = parsed.find(field);
        if (it == parsed.end() || it->is_null())
        {
            missing.push_back(field);
        }
        else if (!it->is_string())
        {
            // Simulation-Platform-Manager's get_to(std::string) throws on a number, so accepting
            // one here would just relocate the failure to a process that cannot answer the caller.
            wrongType.push_back(field + " (" + it->type_name() + ", expected string)");
        }
    }

    if (missing.empty() && wrongType.empty())
    {
        return std::nullopt;
    }

    std::ostringstream reason;
    if (!missing.empty())
    {
        reason << "missing required field(s): " << commaSeparated(missing);
    }
    if (!wrongType.empty())
    {
        if (!missing.empty())
        {
            reason << "; ";
        }
        reason << "wrong type: " << commaSeparated(wrongType);
    }
    return reason.str();
}

namespace
{

/// Splits `-w '\n%{http_code}'` output into (body, status). Mirrors HttpRoutingStrategyBase's
/// splitter; `present` false means curl wrote no status line, so curl itself did not complete.
/// [Co-developed with claude code -- Adam]
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
        return {output, 0, false};
    }
    try
    {
        return {output.substr(0, lastNewline), std::stoi(output.substr(lastNewline + 1)), true};
    }
    catch (const std::exception&)
    {
        return {output, 0, false};
    }
}

/// Renders a duration a reader can compare with a deadline. Three decimals because the
/// measurement this exists for was 0.007s. [Co-developed with claude code -- Adam]
std::string
formatSeconds(double seconds)
{
    std::ostringstream out;
    out << std::fixed << std::setprecision(3) << seconds << "s";
    return out.str();
}

/// Says what happened to a request that produced no HTTP status, and how long it took.
///
/// [Co-developed with claude code -- Adam]
/// FINDINGS #38. `%{http_code}` is "000" for every failure that produced no HTTP response, so
/// `httpStatus == 0` is the union of "refused", "reset", "could not resolve" and "timed out" --
/// and the branch that tested it hard-coded the timeout wording, reporting a 6 ms refusal as a
/// 30-second wait, five times out of five. What separates them is curl's *exit code*, which
/// execArgv already carries in CommandOutcome::status and which nobody read.
///
/// The codes are curl's documented ones (curl(1), EXIT CODES). Only the ones this kernel can
/// actually provoke are named; anything else falls through to describeCommandStatus rather than
/// being guessed at, because inventing a cause is the defect being fixed, not the fix.
///
/// @param status          wait status from CommandOutcome::status
/// @param elapsedSeconds  measured by the caller around execArgv -- never the deadline
/// @param deadlineSeconds what --max-time was set to, quoted only where it is what expired
/// @param url             the endpoint that was asked
///
/// File-local on purpose: HttpRoutingStrategyBase.cpp has the same "within Ns" wording on two more
/// paths, and lifting this into utils:: is the right move at the moment those are fixed and
/// tested. It is not the right move now -- Utils.hpp is included by most of the tree, so putting
/// it there would make every mutation of this logic a whole-tree rebuild for a gate that covers
/// one call site.
std::string
describeCurlNoReply(int status, double elapsedSeconds, int deadlineSeconds, const std::string& url)
{
    const std::string took = formatSeconds(elapsedSeconds);

    if (status == -1 || !WIFEXITED(status))
    {
        return "curl did not exit normally after " + took + " (" +
               utils::describeCommandStatus(status, "curl") + "), so " + url + " has not answered";
    }

    switch (WEXITSTATUS(status))
    {
    case 0:
        return "curl exited 0 without reporting an HTTP status, after " + took + ", from " + url;
    case 6:
        return "could not resolve the host in " + url + " after " + took + " (curl exit 6)";
    case 7:
        return "connection refused after " + took + ": nothing accepted a connection at " + url +
               " (curl exit 7)";
    case 28:
        return "timed out after " + took + ": no reply from " + url + " within the " +
               std::to_string(deadlineSeconds) + "s deadline (curl exit 28)";
    case 35:
        return "TLS handshake failed after " + took + " with " + url + " (curl exit 35)";
    case 52:
        return "empty reply after " + took + ": " + url +
               " accepted the connection and closed it without answering (curl exit 52)";
    case 55:
        return "send failure after " + took + " while writing to " + url + " (curl exit 55)";
    case 56:
        return "connection reset after " + took + " by " + url + " (curl exit 56)";
    default:
        return "no HTTP status from " + url + " after " + took + " (" +
               utils::describeCommandStatus(status, "curl") + ")";
    }
}

} // namespace

// [Co-developed with claude code -- Adam]
SimulationRequestManager::Dispatch
SimulationRequestManager::requestSimulation(const std::string& body)
{
    // doc/KNOWN-ISSUES.md B-4. This was an std::ostringstream building a shell command line, with
    // `body` between two single quotes and SIM_SERVER_URL between two double quotes, handed to
    // popen(). Both were injection sites and they were not equally obvious: a single quote in the
    // body ended its quoting, but the *double*-quoted URL needed no quote at all, because $(...)
    // and backticks still substitute inside double quotes. Any fix that filtered `'` would have
    // left the second one open -- which is the concrete reason KNOWN-ISSUES says not to add
    // escaping call site by call site.
    //
    // As an argument vector there is nothing to filter: execvp receives the body as one argument.
    //
    // -w is new. Without it curl reports nothing about the far end, so this function could not
    // have told its caller whether the simulator accepted the case even if the caller had asked --
    // and HttpSession's unconditional 202 is what that gap looked like from outside.
    const std::vector<std::string> argv = {"curl",
                                           "-s",
                                           "-w",
                                           "\\n%{http_code}",
                                           "--max-time",
                                           std::to_string(m_requestTimeoutSeconds),
                                           "-X",
                                           "POST",
                                           SIM_SERVER_URL,
                                           "-H",
                                           "Content-Type: application/json",
                                           "-d",
                                           body};

    // FINDINGS #38: the duration is measured here rather than assumed from --max-time. The
    // message that quoted "30s" for a 6 ms request had no measurement behind it at all.
    const auto startedAt = std::chrono::steady_clock::now();
    const utils::CommandOutcome outcome = utils::execArgv(argv);
    const double elapsedSeconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt).count();
    const CurlOutput curl = splitBodyAndStatus(outcome.output);

    Dispatch dispatch;
    if (!outcome.ran || !curl.statusLinePresent)
    {
        // Never left this host. The message names curl and this kernel, not the simulator: the
        // simulator has no case to answer, and telling an operator otherwise is B-2b's defect.
        dispatch.failureReason = "this kernel could not run curl, so " + SIM_SERVER_URL +
                                 " was never asked: " +
                                 utils::describeCommandStatus(outcome.status, "curl");
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "Simulation request not sent: {}",
                            dispatch.failureReason);
        return dispatch;
    }

    dispatch.sent = true;
    dispatch.httpStatus = curl.httpStatus;
    dispatch.response = curl.body;

    if (curl.httpStatus == 0)
    {
        // FINDINGS #38. This read, for every cause alike:
        //     "no response from the simulator server at <url> within 30s"
        // Round 2 measured that sentence coming back in 6.0-9.0 ms, five times out of five, with
        // nothing listening on the port. Two failures that need opposite responses -- start the
        // simulator, versus go and find out why it is slow -- were rendered byte-identically, and
        // the one number in the message was the deadline rather than anything measured.
        dispatch.failureReason = describeCurlNoReply(outcome.status,
                                                     elapsedSeconds,
                                                     m_requestTimeoutSeconds,
                                                     SIM_SERVER_URL);
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "Simulation request unanswered: {}",
                           dispatch.failureReason);
        return dispatch;
    }

    dispatch.answered = true;
    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "Requested simulation on {} - HTTP {} - response: {}",
                       SIM_SERVER_URL,
                       curl.httpStatus,
                       curl.body);
    return dispatch;
}

void
SimulationRequestManager::onSimulationResult(int appId,
                                             const std::string& body)
{
    // Forward the result asynchronously
    std::thread([this, appId, body]() {
        auto apiUrlOpt = m_applicatonManager->getSimulationCompletedUrl(appId);
        if (!apiUrlOpt.has_value())
        {
            SPDLOG_LOGGER_WARN(Logger::instance(), "Cannot get Url from appId: {}", appId);
            return;
        }
        const std::string& apiUrl = apiUrlOpt.value();

        // [Co-developed with claude code -- Adam]
        // doc/KNOWN-ISSUES.md B-4's second site, and the more dangerous of the two: `apiUrl` is
        // whatever string an application supplied as `simulation_completed_url` when it called
        // POST /ndt/app_register, and it was interpolated into a *double*-quoted shell word. A
        // registered URL of the form `http://x/$(command)` therefore ran a command here without
        // containing a single quote anywhere -- so the entry's framing as "the single-quote bug"
        // understated it, and a filter written from that framing would not have caught this.
        //
        // As an argument vector both the URL and the body are transported, not interpreted.
        const std::vector<std::string> argv = {"curl",
                                               "-s",
                                               "-w",
                                               "\\n%{http_code}",
                                               "--max-time",
                                               std::to_string(m_requestTimeoutSeconds),
                                               "-X",
                                               "POST",
                                               apiUrl,
                                               "-H",
                                               "Content-Type: application/json",
                                               "-d",
                                               body};

        const auto startedAt = std::chrono::steady_clock::now();
        const utils::CommandOutcome outcome = utils::execArgv(argv);
        const double elapsedSeconds =
            std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt).count();
        const CurlOutput curl = splitBodyAndStatus(outcome.output);

        // [Co-developed with claude code -- Adam]
        // This thread is detached and HttpSession::handleSimulationCompleted has already answered
        // 200 {"status":"result forwarded"} by the time it runs, so there is no caller left to
        // tell. What can still be fixed is the log: it used to print `response: ` with an empty
        // value for every one of "the app's callback returned nothing", "the app's callback is
        // down" and "the command never ran", which is the same three-into-one collapse B-2b is
        // about. The 200 remains premature by construction -- closing that needs a job id the
        // caller can query, which is a design change and not this one.
        if (!outcome.ran || !curl.statusLinePresent)
        {
            SPDLOG_LOGGER_ERROR(Logger::instance(),
                                "Simulation result for app {} was NOT forwarded: this kernel "
                                "could not run curl ({}). The application has not been told its "
                                "simulation finished.",
                                appId,
                                utils::describeCommandStatus(outcome.status, "curl"));
        }
        else if (curl.httpStatus == 0)
        {
            // FINDINGS #38's second instance, in the same file. Log-only -- the 200 has already
            // gone out -- but an operator reading "nothing answered within 30s" about a callback
            // URL that is simply not listening is being sent to the same wrong place. No test
            // covers this line: it runs on a detached thread with no caller left to observe, so
            // what is tested is the classifier, on the path above; this call site is a reading of
            // the source and nothing stronger.
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "Simulation result for app {} was NOT forwarded -- {}. The "
                               "application has not been told its simulation finished.",
                               appId,
                               describeCurlNoReply(outcome.status,
                                                   elapsedSeconds,
                                                   m_requestTimeoutSeconds,
                                                   apiUrl));
        }
        else
        {
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "Forwarded simulation result for app {} to {} - HTTP {} - "
                               "response: {}",
                               appId,
                               apiUrl,
                               curl.httpStatus,
                               curl.body);
        }
    }).detach();
}