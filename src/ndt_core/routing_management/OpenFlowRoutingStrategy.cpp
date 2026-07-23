// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#include "ndt_core/routing_management/OpenFlowRoutingStrategy.hpp"
#include "spdlog/spdlog.h"
#include "utils/Logger.hpp"
#include "utils/Utils.hpp"
#include <sstream>

using json = nlohmann::json;

OpenFlowRoutingStrategy::OpenFlowRoutingStrategy(const std::string& apiUrl)
    : m_apiUrl(apiUrl)
{
}

void OpenFlowRoutingStrategy::executeCommand(const std::string& cmd)
{
    utils::execCommand(cmd);
}


void OpenFlowRoutingStrategy::deleteAnEntry(uint64_t dpid, json match, int priority)
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

void OpenFlowRoutingStrategy::installAnEntry(uint64_t dpid, int priority, json match, json action, int idleTimeout)
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

void OpenFlowRoutingStrategy::modifyAnEntry(uint64_t dpid, int priority, json match, json action)
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

void OpenFlowRoutingStrategy::installAGroupEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/groupentry/add "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void OpenFlowRoutingStrategy::deleteAGroupEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/groupentry/delete "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void OpenFlowRoutingStrategy::modifyAGroupEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/groupentry/modify "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void OpenFlowRoutingStrategy::installAMeterEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/meterentry/add "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void OpenFlowRoutingStrategy::deleteAMeterEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/meterentry/delete "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}

void OpenFlowRoutingStrategy::modifyAMeterEntry(json j)
{
    std::ostringstream cmd;
    cmd << "curl -s -X POST http://" << m_apiUrl << "/stats/meterentry/modify "
        << "-H \"Content-Type: application/json\" " << "-d '" << j.dump() << "'";

    SPDLOG_LOGGER_INFO(Logger::instance(), "execCommand: {}", cmd.str());
    this->executeCommand(cmd.str());
}
