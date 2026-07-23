// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#pragma once

#include "ndt_core/routing_management/IRoutingStrategy.hpp"
#include <string>

/**
 * @brief P4 specific routing strategy (Ryu Controller).
 * 
 * This strategy implements the IRoutingStrategy interface by sending curl 
 * requests to the Ryu REST API.
 */
class P4RoutingStrategy : public IRoutingStrategy
{
  public:
    P4RoutingStrategy(const std::string& apiUrl);
    virtual ~P4RoutingStrategy() = default;

    void deleteAnEntry(uint64_t dpid, nlohmann::json match, int priority = -1) override;
    void installAnEntry(uint64_t dpid, int priority, nlohmann::json match, nlohmann::json action, int idleTimeout = 0) override;
    void modifyAnEntry(uint64_t dpid, int priority, nlohmann::json match, nlohmann::json action) override;

    void installAGroupEntry(nlohmann::json j) override;
    void deleteAGroupEntry(nlohmann::json j) override;
    void modifyAGroupEntry(nlohmann::json j) override;

    void installAMeterEntry(nlohmann::json j) override;
    void deleteAMeterEntry(nlohmann::json j) override;
    void modifyAMeterEntry(nlohmann::json j) override;

  protected:
    // [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
    // Virtual method to allow overriding in unit tests without executing real commands
    virtual void executeCommand(const std::string& cmd);

  private:
    std::string m_apiUrl;
};
