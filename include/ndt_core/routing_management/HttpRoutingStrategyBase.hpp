// [Co-developed with claude code -- Adam]
#pragma once

#include "ndt_core/routing_management/IRoutingStrategy.hpp"
#include <nlohmann/json.hpp>
#include <stdint.h>
#include <string>
#include <utility>

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
     * @brief GETs a path on this strategy's endpoint, returning the outcome and the body.
     *
     * [Co-developed with claude code -- Adam] F-13.
     * The read half of `post`. Unlike `post` it interpolates nothing from a caller-supplied
     * JSON body -- every path it is given is built from integers here in this file -- so the
     * shell-quoting hazard `post` still carries does not apply to it, and must not be
     * introduced by a future caller that passes a string through.
     */
    std::pair<OpResult, std::string> get(const std::string& path, const char* operation);

    /// Which table an operation is about. Group and meter differ only in route and field name.
    enum class EntryKind
    {
        Group,
        Meter
    };

    /// Which OpenFlow *_MOD command an operation maps to.
    enum class EntryOp
    {
        Add,
        Modify,
        Delete
    };

    /**
     * @brief Whether the switch has the named entry -- or whether that is unknowable right now.
     *
     * Three states, not two, and the third one is the point. "I asked and it is not there" and
     * "I could not ask" must never collapse into the same answer, because only the first may
     * become a 404: a controller that has gone away would otherwise make the kernel report
     * every group in the fabric as nonexistent, which is the instrument reporting its own
     * failure as a finding.
     */
    enum class Existence
    {
        Present,
        Absent,
        Unknown
    };

    /// @see Existence. Virtual so a test can pin the guard's decisions without a controller.
    virtual Existence entryExists(EntryKind kind, uint64_t dpid, long long id);

    /**
     * @brief Checks the precondition an OpenFlow *_MOD carries, then forwards the request.
     *
     * [Co-developed with claude code -- Adam] F-13. The whole fix lives here; see the
     * implementation for what Ryu and the switch do and do not report.
     */
    OpResult guardedMod(const nlohmann::json& j,
                        EntryKind kind,
                        EntryOp op,
                        const std::string& path,
                        const char* operation);

    /**
     * @brief Runs a shell command and returns its stdout.
     *
     * The test seam. Kept as the single point where a command is executed so a mock can
     * capture the request without a live controller, and so the shell-injection fix that
     * this construction still needs lands in one place.
     */
    virtual std::string executeCommand(const std::string& cmd);

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
