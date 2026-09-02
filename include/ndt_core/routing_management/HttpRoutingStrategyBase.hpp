// [Co-developed with claude code -- Adam]
#pragma once

#include "ndt_core/routing_management/IRoutingStrategy.hpp"
// [Co-developed with claude code -- Adam] For utils::CommandOutcome, which is the seam's return
// type. This pulls Utils.hpp into every translation unit that includes this header; that cost is
// accepted because the alternative -- an incomplete return type -- cannot be overridden by the
// test double, and a seam a test cannot override is not a seam.
#include "utils/Utils.hpp"
#include <nlohmann/json.hpp>
#include <stdint.h>
#include <string>
#include <vector>

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
     * @brief Runs curl with an explicit argument vector and returns what happened.
     *
     * The test seam. Kept as the single point where a command is executed so a mock can
     * capture the request without a live controller.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md B-2b. This was `std::string executeCommand(const std::string&)`, and both
     * halves of that signature were defects rather than style. The string parameter meant post()
     * had to flatten a JSON body into shell source, where a single quote in a match value ended
     * the quoting and the rest became commands. The string return meant the caller could not learn
     * whether curl had run at all, so "the shell rejected my command line" and "the controller is
     * dead" arrived as the same empty string and got the same verdict.
     *
     * Renaming rather than adding an overload is deliberate. An added executeArgv() would leave
     * every existing executeCommand() override -- including the one in test_RoutingStrategies.cpp
     * -- compiling, silently unused, and no longer intercepting anything, so the tests would start
     * running real curl against localhost while still passing. Removing the old name makes that a
     * compile error instead. See MEMORY [[existence-is-not-wiring]].
     */
    virtual utils::CommandOutcome executeArgv(const std::vector<std::string>& argv);

    /**
     * @brief The route that modifies exactly the entry named by (match, priority).
     *
     * [Co-developed with claude code -- Adam]
     * Virtual because the two control planes spell the same guarantee differently, and getting
     * this wrong is a 404 on every modify rather than a visible error. Ryu's ofctl_rest maps the
     * route name onto an OpenFlow command, so priority is only compared on `modify_strict`. The
     * P4 proxy has one flow-entry modify route and reads `priority` out of the body itself
     * (proxy_agent/topology_manager.py modify_flow uses it to identify the entry on the ternary
     * five-tuple table), so there is no strict spelling for it to serve and none to ask for.
     * Posting `modify_strict` at the proxy would 404 -- and, because the flow path is
     * asynchronous, the caller would still be told 200 "queued" while nothing happened.
     */
    virtual const char* strictModifyPath() const;

    /// Seconds before a request is abandoned. Bounded so a hung controller cannot wedge
    /// a FlowDispatcher worker indefinitely.
    static constexpr int REQUEST_TIMEOUT_SECONDS = 5;

    const std::string& apiUrl() const { return m_apiUrl; }

  private:
    std::string m_apiUrl;
};
