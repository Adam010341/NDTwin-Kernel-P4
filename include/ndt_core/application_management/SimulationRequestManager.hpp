#pragma once
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

class ApplicationManager;

/**
 * @brief Coordinates simulation execution requests and result forwarding.
 *
 * SimulationRequestManager acts as a bridge between applications and the
 * simulator server. It sends simulation requests to the configured simulator
 * endpoint and, when the network layer reports completion, forwards the result
 * back to the originating application using the callback URL registered in
 * ApplicationManager.
 *
 * Typical flow:
 *  1. requestSimulation(body): send a run request to SIM_SERVER_URL for an app/case
 *  2. onSimulationResult(appId, body): invoked by the network layer upon completion
 *     - looks up the application's "simulation completed" callback via ApplicationManager
 *     - forwards the result payload to that callback (implementation-dependent)
 *
 * Notes:
 *  - This class does not own ApplicationManager; it stores a shared_ptr reference.
 *  - Thread-safety depends on ApplicationManager and the caller's network layer threading model.
 */
class SimulationRequestManager
{
  public:
    SimulationRequestManager(std::shared_ptr<ApplicationManager> appManager,
                             std::string simServerUrl);
    ~SimulationRequestManager();

    /**
     * @brief The fields POST /ndt/received_a_simulation_case must carry, all of them strings.
     *
     * @details Not this kernel's invention: Simulation-Platform-Manager's `from_json(SimulationTask)`
     * calls `j.at(...).get_to(std::string)` on exactly these five, so a body missing one -- or
     * carrying it as a number -- throws over there. Checking here moves that failure to the request
     * boundary, where the caller can still be told about it.
     *
     * [Co-developed with claude code -- Adam]
     */
    static const std::vector<std::string>& requiredRequestFields();

    /**
     * @brief Names what is wrong with a simulation-request body, or nothing if it is usable.
     *
     * @details Separate from requestSimulation() and free of side effects so it can be unit-tested
     * without a simulator server, and so the caller can choose a status code. `/ndt/received_a_
     * simulation_case` used to answer **202 Accepted** to anything at all, including `{not json` --
     * the body went straight to curl and whatever the simulator server said (including nothing) was
     * wrapped as `{"status": "..."}`. An application had no way to learn it had sent rubbish.
     *
     * Validation only. It deliberately does **not** sanitise: the body still reaches a shell in
     * requestSimulation(), and making this look like a sanitiser would be worse than not having one.
     * See the note on requestSimulation().
     *
     * @param body Raw request body.
     * @return A human-readable reason, or std::nullopt when the body has all of
     *         requiredRequestFields() as strings.
     */
    static std::optional<std::string> validateRequestBody(const std::string& body);

    /**
     * @brief Asynchronously request the simulator server to run a case
     *
     * @warning `body` is interpolated into a shell command line unescaped (see the implementation).
     *          Callers must not treat validateRequestBody() as making an untrusted body safe -- it
     *          checks shape, not content. Hardening this is tracked separately and deliberately
     *          deferred; it covers every southbound curl call in the kernel, not just this one.
     *
     * @param body Request body, forwarded verbatim to SIM_SERVER_URL.
     */
    std::string requestSimulation(const std::string& body);

    /**
     * @brief This method should be called by the network layer when the simulator server
     *        notifies that the simulation has finished. It will forward the result
     *        back to the application via the registered callback.
     * @param appId            Application ID
     * @param caseId           Case ID
     * @param outputFilePath   Path to the output file produced by the simulation
     */
    void onSimulationResult(int appId, const std::string& body);

  private:
    std::shared_ptr<ApplicationManager> m_applicatonManager;
    std::string SIM_SERVER_URL;
};