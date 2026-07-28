// [Co-developed with claude code -- Adam]
#pragma once

#include "ndt_core/routing_management/IRoutingStrategy.hpp"
#include <nlohmann/json.hpp>
#include <stdint.h>
#include <string>

/**
 * @brief Shared implementation for control planes reached over Ryu-shaped HTTP.
 *
 * OpenFlowRoutingStrategy and P4RoutingStrategy were byte-for-byte identical apart from
 * their class names -- `diff` on the two files, with the names normalised, produced nothing.
 * Both built the same curl invocations against the same Ryu route names; only the host and
 * port differed. Keeping two copies meant every fix had to be applied twice and the pair
 * would inevitably drift.
 *
 * They are now thin subclasses of this. The P4 proxy deliberately impersonates Ryu's
 * northbound API, so sharing the request construction is not a coincidence to be tidied
 * away -- it is the actual design. What legitimately differs is expressed by overriding:
 * the endpoint, and which operations the target can honour at all.
 *
 * Errors are reported rather than swallowed. Every request asks curl for the real HTTP
 * status (`-w '\n%{http_code}'`, which yields 000 when nothing answered) and imposes a
 * timeout, so a dead controller, a rejected rule and a success are finally distinguishable.
 */
class HttpRoutingStrategyBase : public IRoutingStrategy
{
  public:
    explicit HttpRoutingStrategyBase(std::string apiUrl)
        : m_apiUrl(std::move(apiUrl))
    {
    }

    OpResult deleteAnEntry(uint64_t dpid,
                           const nlohmann::json& match,
                           int priority) override;
    OpResult installAnEntry(uint64_t dpid,
                            int priority,
                            const nlohmann::json& match,
                            const nlohmann::json& action,
                            int idleTimeout) override;
    OpResult modifyAnEntry(uint64_t dpid,
                           int priority,
                           const nlohmann::json& match,
                           const nlohmann::json& action) override;

    OpResult installAGroupEntry(const nlohmann::json& j) override;
    OpResult deleteAGroupEntry(const nlohmann::json& j) override;
    OpResult modifyAGroupEntry(const nlohmann::json& j) override;

    OpResult installAMeterEntry(const nlohmann::json& j) override;
    OpResult deleteAMeterEntry(const nlohmann::json& j) override;
    OpResult modifyAMeterEntry(const nlohmann::json& j) override;

  protected:
    /**
     * @brief POSTs a JSON body to a path on this strategy's endpoint.
     *
     * @param path      Route on the control plane, e.g. "/stats/flowentry/add".
     * @param body      Request body.
     * @param operation Short label used in the failure message, e.g. "install flow entry".
     */
    OpResult post(const std::string& path,
                  const nlohmann::json& body,
                  const char* operation);

    /**
     * @brief Runs a shell command and returns its stdout.
     *
     * The test seam. Kept as the single point where a command is executed so a mock can
     * capture the request without a live controller, and so the shell-injection fix that
     * this construction still needs lands in one place.
     */
    virtual std::string executeCommand(const std::string& cmd);

    /// Seconds before a request is abandoned. Bounded so a hung controller cannot wedge
    /// a FlowDispatcher worker indefinitely.
    static constexpr int REQUEST_TIMEOUT_SECONDS = 5;

    const std::string& apiUrl() const { return m_apiUrl; }

  private:
    std::string m_apiUrl;
};
