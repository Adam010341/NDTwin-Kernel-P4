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
    /**
     * @brief Seconds before a request to the simulator server is abandoned.
     *
     * [Co-developed with claude code -- Adam]
     * There was no bound at all. Both curl calls in this class ran with neither --max-time nor
     * --connect-timeout, so a simulator server that accepted the connection and then stalled held
     * an HttpSession thread indefinitely -- the same failure that was fixed for the topology poll
     * and for the routing strategies, on the one path that still had it. 30s rather than the
     * routing strategies' 5s because starting a simulation case is not a hot path and the far end
     * does real work before replying.
     *
     * Declared before the constructor because it is that constructor's default argument.
     */
    static constexpr int REQUEST_TIMEOUT_SECONDS = 30;

    /**
     * @param appManager             Owner of the per-application callback URLs.
     * @param simServerUrl           Where a simulation case is POSTed.
     * @param requestTimeoutSeconds  The deadline given to curl's --max-time, and the number the
     *                               timeout message quotes. Defaults to REQUEST_TIMEOUT_SECONDS,
     *                               so production behaviour is unchanged.
     *
     * [Co-developed with claude code -- Adam]
     * FINDINGS #38 made the deadline a parameter. It was a compile-time constant, and the only
     * way to exercise the *timed out* branch was to let a test wait the full 30 s -- which is why
     * no test had ever exercised it, and why the branch could go on describing a 6 ms connection
     * refusal as a 30-second wait without anything noticing. A deadline that cannot be shortened
     * is a deadline nothing can test.
     */
    SimulationRequestManager(std::shared_ptr<ApplicationManager> appManager,
                             std::string simServerUrl,
                             int requestTimeoutSeconds = REQUEST_TIMEOUT_SECONDS);
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
     * Validation only, and still not a sanitiser -- but the reason has changed. It used to be "the
     * body still reaches a shell, so do not mistake this for protection". requestSimulation() no
     * longer builds shell source at all (see its note), so there is nothing left here to sanitise
     * against: content is transported, not interpreted. This function's job is and always was to
     * answer the caller about shape.
     *
     * @param body Raw request body.
     * @return A human-readable reason, or std::nullopt when the body has all of
     *         requiredRequestFields() as strings.
     */
    static std::optional<std::string> validateRequestBody(const std::string& body);

    /**
     * @brief What happened to one simulation request.
     *
     * [Co-developed with claude code -- Adam]
     * doc/KNOWN-ISSUES.md B-4. requestSimulation() returned std::string, and that type cannot say
     * "this never left the host" -- an empty string meant the simulator answered with nothing,
     * meant curl was not installed, and meant /bin/sh had refused to parse the command line,
     * indistinguishably. HttpSession did not even look at it: it answered 202 Accepted
     * unconditionally, so a request that was never sent was reported as accepted, with no id the
     * caller could later query. That is the "silent" failure direction in one sentence.
     */
    struct Dispatch
    {
        /**
         * @brief True when the request actually left this host.
         *
         * False means curl never ran -- so the simulator server has no case to answer, and any
         * message about it would be an accusation the kernel cannot support. Kept separate from
         * @c answered rather than inferred from the other fields, because the caller has to pick
         * between "500, this is our fault" and "502, the far end failed" and inferring that from
         * an empty string is how the two got confused in the first place.
         */
        bool sent = false;

        /// True only when the simulator server actually answered. Not "curl exited 0".
        bool answered = false;

        /// The simulator's HTTP status, or 0 when it did not answer.
        int httpStatus = 0;

        /// The simulator's response body, with curl's status line removed.
        std::string response;

        /// Names the local cause when answered is false. Must never name the simulator for a
        /// failure the simulator had no part in -- that is B-2b's mistake, in this file.
        std::string failureReason;
    };

    /**
     * @brief Request the simulator server to run a case, and report whether it was reached.
     *
     * @details The body is passed to curl as a single argument vector element, so its content is
     * never parsed as shell source. It used to be interpolated between two single quotes on a
     * command line handed to popen(): a `'` anywhere in any of the five fields ended the quoting,
     * /bin/sh reported a syntax error to a stderr nobody read, curl never ran, and the caller got
     * 202 Accepted. A deliberate `'` got command execution rather than a syntax error, and
     * `inputfile` is a path -- the one field most likely to carry a quote by accident.
     *
     * @param body Request body, forwarded verbatim to SIM_SERVER_URL.
     * @return Whether the simulator answered, and what it said.
     */
    Dispatch requestSimulation(const std::string& body);

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
    int m_requestTimeoutSeconds;
};