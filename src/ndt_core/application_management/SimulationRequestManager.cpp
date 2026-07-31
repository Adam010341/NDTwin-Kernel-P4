#include "ndt_core/application_management/SimulationRequestManager.hpp"
#include "ndt_core/application_management/ApplicationManager.hpp"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <iostream>
#include <memory>
#include <nlohmann/json.hpp>
#include <sstream>
#include <thread>

SimulationRequestManager::SimulationRequestManager(std::shared_ptr<ApplicationManager> appManager,
                                                   std::string simServerUrl)
    : m_applicatonManager(std::move(appManager)),
      SIM_SERVER_URL(simServerUrl)
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

std::string
SimulationRequestManager::requestSimulation(const std::string& body)
{
    // NOTE: `body` is interpolated into a shell command line without escaping, and json::dump()
    // does not escape single quotes. That is a known, deliberately-deferred issue shared by every
    // southbound curl call in the kernel -- validateRequestBody() above checks *shape only* and
    // must not be mistaken for a fix. Do not add sanitising here piecemeal; it needs to be done
    // once, for all call sites, with a proper argv-based executor.
    std::ostringstream cmd;
    cmd << "curl -s -X POST \"" << SIM_SERVER_URL << "\" "
        << "-H \"Content-Type: application/json\" " << "-d '" << body << "'";

    std::string resp = utils::execCommand(cmd.str());
    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "Requested simulation on {} - response: {}",
                       SIM_SERVER_URL,
                       resp);
    return resp;
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

        std::ostringstream cmd;
        cmd << "curl -s -X POST \"" << apiUrl << "\" " << "-H \"Content-Type: application/json\" "
            << "-d '" << body << "'";

        std::string result = utils::execCommand(cmd.str());
        SPDLOG_LOGGER_INFO(Logger::instance(), "Forwarded simulation result, response: {}", result);
    }).detach();
}