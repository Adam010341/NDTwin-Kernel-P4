#pragma once

#include "common_types/GraphTypes.hpp" // for Graph
#include "utils/Utils.hpp"             // for DeploymentMode
#include <atomic>                      // for atomic
#include <chrono>                      // for minutes
#include <cstddef>                     // for size_t
#include <ctime>                       // for time_t
#include <memory>                      // for shared_ptr
#include <string>                      // for string
#include <thread>                      // for thread
class TopologyAndFlowMonitor; // lines 34-34

/**
 * @brief Periodically records historical link-bandwidth usage.
 */
class HistoricalDataManager
{
  public:
    static constexpr std::chrono::minutes DEFAULT_INTERVAL{5};
    /**
     * @param monitor  Shared pointer to the topology & flow monitor
     *                 from which to fetch bandwidth data.
     * @param interval Interval between recordings (default: 5 minutes).
     */
    HistoricalDataManager(std::shared_ptr<TopologyAndFlowMonitor> monitor,
                          int mode,
                          std::chrono::minutes interval = DEFAULT_INTERVAL);

    ~HistoricalDataManager();

    /// Start the recording thread.
    void start();

    /// Request shutdown and join the thread.
    void stop();
    void setLoggingState(bool enable);

    /**
     * @brief Where the per-link CSVs are written.
     *
     * @warning This is an absolute path into another user's home directory. It is a known defect
     * -- on this machine the directory is root-owned and the kernel runs unprivileged -- and it is
     * deliberately left alone, because something outside this repository is understood to read
     * from there. It is a named constant rather than two string literals so that the two places
     * that used it cannot drift apart.
     * [Co-developed with claude code -- Adam]
     */
    static constexpr const char* OUTPUT_DIR = "/home/of-controller-sflow-collector/LinkData";

    /**
     * @brief Whether the REST toggle currently permits writing.
     *
     * [Co-developed with claude code -- Adam]
     * m_loggingEnabled used to be stored by setLoggingState and read by nothing at all, so
     * /ndt/set_historical_logging_state was inert even where it was reachable. writeSnapshot now
     * consults it, and this accessor exists so a test can see the same answer the writer does.
     */
    bool isLoggingEnabled() const { return m_loggingEnabled.load(); }

    /**
     * @brief Append one snapshot of every edge in @p graph to its per-link CSV under @p outDir.
     *
     * @return the number of rows actually written. Zero when logging is disabled, and zero when
     *         the output stream could not be opened.
     *
     * [Co-developed with claude code -- Adam]
     * Extracted from run() so the thing worth asserting -- that a row is written when it should
     * be, and is *not* written when logging is off or the directory is unwritable -- can be
     * asserted without starting a thread and without waiting an interval. outDir is a parameter
     * for the same reason; production passes OUTPUT_DIR and the path is unchanged.
     *
     * Every write used to be unchecked: the stream was opened per edge and neither is_open() nor
     * the stream state was ever consulted, so on this machine every TESTBED run appended into
     * dead streams and produced nothing, with no log line ever.
     */
    std::size_t writeSnapshot(const Graph& graph, const std::string& outDir, std::time_t when);

    /**
     * @brief How many times a write failure has been *reported*.
     *
     * A failing directory fails for every edge on every interval, so the report is emitted once
     * per unbroken run of failures rather than once per row. This counter makes that policy
     * testable. [Co-developed with claude code -- Adam]
     */
    unsigned writeFailureReports() const { return m_writeFailureReports.load(); }

  private:
    /// Main loop executed in the background thread.
    void run();

    std::shared_ptr<TopologyAndFlowMonitor> m_topologyAndFlowMonitor;
    utils::DeploymentMode m_mode;

  public:
    /**
     * @brief Whether this deployment can actually record anything.
     *
     * start() returns early in MININET, so the recorder thread is never spawned and no row is
     * ever written -- but setLoggingState() still flips the flag and the endpoint still answered
     * `200 {"status":"success","Historical data logging has been enabled."}`. Both lab stacks run
     * MININET, so every measurement round this project has taken was against a deployment where
     * that success message was false. Callers can now ask instead of assuming.
     *
     * [Co-developed with claude code -- Adam]
     */
    bool canRecord() const { return m_mode != utils::DeploymentMode::MININET; }

    /**
     * @brief Whether the recorder thread is actually running.
     *
     * [Co-developed with claude code -- Adam]
     * canRecord() answers a question about the *deployment mode*, not about this object. A
     * TESTBED manager that nobody ever start()ed answers canRecord() == true and writes exactly
     * as many rows as a MININET one. This accessor is the liveness half, and start() had to be
     * reordered before it could tell the truth -- see the comment there.
     */
    bool isRecorderRunning() const { return m_running.load(); }

    /**
     * @brief Why -- or whether -- a row will actually appear.
     *
     * [Co-developed with claude code -- Adam]
     * KNOWN-ISSUES B-3. The endpoint used to answer `200 {"status":"success"}` on both branches,
     * so a caller reading the status line or the `status` field could not tell "recording" from
     * "this deployment will never record", and the second branch is the one every run of this
     * project has actually taken. Splitting the answer into a named state, rather than a second
     * bool, is what lets the reply carry a machine-readable reason instead of prose.
     *
     * The order of the checks is the answer's precedence, and it is deliberate: mode is a
     * permanent property of the deployment and dominates a flag the caller can flip, so a
     * MININET manager with logging switched off reports NOT_AVAILABLE_IN_MININET rather than
     * DISABLED_BY_REQUEST -- turning the flag back on would still not produce a row.
     */
    enum class RecordingState
    {
        RECORDING,                ///< thread running, logging on, writes landing
        DISABLED_BY_REQUEST,      ///< the REST toggle is off; everything else is fine
        NOT_AVAILABLE_IN_MININET, ///< start() refuses in MININET, so no thread exists
        RECORDER_NOT_RUNNING,     ///< could record, but start() has not run (or stop() has)
        WRITES_FAILING            ///< thread running, but the output directory is rejecting rows
    };

    RecordingState recordingState() const
    {
        if (!canRecord())
        {
            return RecordingState::NOT_AVAILABLE_IN_MININET;
        }
        if (!m_loggingEnabled.load())
        {
            return RecordingState::DISABLED_BY_REQUEST;
        }
        if (!m_running.load())
        {
            return RecordingState::RECORDER_NOT_RUNNING;
        }
        if (m_writeFailureActive.load())
        {
            return RecordingState::WRITES_FAILING;
        }
        return RecordingState::RECORDING;
    }

    /**
     * @brief A stable, machine-readable token for @p state, for the REST reply.
     *
     * These strings are wire contract: they exist so a caller can branch without parsing the
     * English message, which is the thing B-3 left it no choice but to do.
     * [Co-developed with claude code -- Adam]
     */
    static const char* reasonCode(RecordingState state);

  private:
    std::chrono::minutes m_interval;
    std::atomic<bool> m_running{false};
    std::thread m_thread;
    std::atomic<bool> m_loggingEnabled{true};

    /// True while a run of write failures is in progress, so it is reported once and not per row.
    std::atomic<bool> m_writeFailureActive{false};
    std::atomic<unsigned> m_writeFailureReports{0};
};