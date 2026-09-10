#pragma once
#include "ndt_core/routing_management/DispatchOutcomeLog.hpp"
#include "ndt_core/routing_management/FlowDispatcher.hpp"

class FlowRoutingManager;

/**
 * @brief Owns long-lived control-plane components and exposes a shared FlowDispatcher.
 *
 * Controller wires together the FlowRoutingManager with a single FlowDispatcher instance
 * that is shared across all sessions/requests. The dispatcher is constructed with a sender
 * callback that ultimately applies FlowJobs through the FlowRoutingManager.
 *
 * Lifetime / ordering:
 *  - m_flowRoutingManager is declared before dispatcher_ to ensure it is constructed first
 *    and remains valid for the lifetime of dispatcher_ (the dispatcher may capture/use it).
 */
class Controller
{
  public:
    /**
     * @brief Construct the controller.
     *
     * @param flowRoutingManager Shared routing manager used by the dispatcher sender callback
     *                           to install/modify/delete flow rules.
     */
    Controller(std::shared_ptr<FlowRoutingManager> flowRoutingManager);

    /**
     * @brief Destroy the controller and release owned resources.
     *
     * Ensures the dispatcher is destroyed after the FlowRoutingManager pointer remains valid
     * for its lifetime (member destruction happens in reverse declaration order).
     */
    ~Controller();

    /**
     * @brief Access the shared FlowDispatcher.
     *
     * Returned reference is valid as long as this Controller instance lives.
     */
    FlowDispatcher& dispatcher()
    {
        return dispatcher_;
    }

    /**
     * @brief Outcomes of jobs the dispatcher has already handed to the southbound.
     *
     * [Co-developed with claude code -- Adam]
     *
     * Read-only for callers outside the sender: the only writer is the sender callback, which is
     * the sole point where a FlowJob and its OpResult exist together. Exposed so the HTTP layer
     * can answer "did the writes I was told were queued actually land?" -- a question that had no
     * answer anywhere in the API before (KNOWN-ISSUES A-7).
     */
    const DispatchOutcomeLog& dispatchOutcomes() const
    {
        return outcomes_;
    }

    /**
     * @brief Register an HTTP batch's request id before its jobs are enqueued.
     *
     * [Co-developed with claude code -- Adam]
     *
     * W11. The one write to the outcome log that does not come from the sender callback, and it
     * is deliberately a named method rather than a mutable accessor: handing out a non-const
     * DispatchOutcomeLog& would let any caller move any counter, and the "one writer for the
     * outcomes" property above is worth more than the two lines it saves. This adds an id and a
     * job count; it cannot touch an outcome.
     *
     * Called from the HTTP thread, which is the only place a request id exists.
     */
    void noteRequestEnqueued(uint64_t requestId, uint64_t jobs)
    {
        outcomes_.noteRequestEnqueued(requestId, jobs);
    }

  private:
    // Declare m_flowRoutingManager BEFORE dispatcher_ so it's constructed first
    std::shared_ptr<FlowRoutingManager> m_flowRoutingManager;

    // [Co-developed with claude code -- Adam]
    // Before dispatcher_ for the same reason m_flowRoutingManager is: the sender callback writes
    // to it from worker threads, and members are destroyed in reverse declaration order, so
    // dispatcher_ (whose destructor stops and joins those workers) must be destroyed first.
    // Reversing these two is a use-after-free during shutdown, not a style question.
    DispatchOutcomeLog outcomes_;

    FlowDispatcher dispatcher_; // long-lived, shared by all sessions
};
