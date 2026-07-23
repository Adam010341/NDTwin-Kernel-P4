// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#include "ndt_core/routing_management/P4RoutingStrategy.hpp"
#include "spdlog/spdlog.h"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <sstream>

using json = nlohmann::json;

P4RoutingStrategy::P4RoutingStrategy(const std::string& apiUrl)
    : m_apiUrl(apiUrl)
{
}

void P4RoutingStrategy::executeCommand(const std::string& cmd)
{
    utils::execCommand(cmd);
}


void P4RoutingStrategy::deleteAnEntry(uint64_t dpid, json match, int priority)
{
    json jsonData;
    jsonData["dpid"] = dpid;
    jsonData["match"] = match;

    std::ostringstream cmd;

    if (priority == -1)
    {
        cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/flowentry/delete "
            << "-H \"Content-Type: application/json\" " << "-d '" << jsonData.dump() << "'";
    }
    else
    {
        jsonData["priority"] = priority;
        cmd << "curl -s -X POST http://" << m_apiUrl
            << "/stats/flowentry/delete_strict " << "-H \"Content-Type: application/json\" "
            << "-d '" << jsonData.dump() << "'";
    }

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void P4RoutingStrategy::installAnEntry(uint64_t dpid, int priority, json match, json action, int idleTimeout)
{
    json jsonData;
    jsonData["dpid"] = dpid;
    jsonData["priority"] = priority;
    jsonData["match"] = match;
    jsonData["actions"] = action;
    if (idleTimeout != -1)
    {
        jsonData["idle_timeout"] = idleTimeout;
    }

    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/flowentry/add "
        << "-H \"Content-Type: application/json\" " << "-d '" << jsonData.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void P4RoutingStrategy::modifyAnEntry(uint64_t dpid, int priority, json match, json action)
{
    json jsonData;
    jsonData["dpid"] = dpid;
    jsonData["priority"] = priority;
    jsonData["match"] = match;
    jsonData["actions"] = action;

    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/flowentry/modify "
        << "-H \"Content-Type: application/json\" " << "-d '" << jsonData.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void P4RoutingStrategy::installAGroupEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/groupentry/add "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void P4RoutingStrategy::deleteAGroupEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/groupentry/delete "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void P4RoutingStrategy::modifyAGroupEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/groupentry/modify "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void P4RoutingStrategy::installAMeterEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/meterentry/add "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void P4RoutingStrategy::deleteAMeterEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/meterentry/delete "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void P4RoutingStrategy::modifyAMeterEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/meterentry/modify "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}
