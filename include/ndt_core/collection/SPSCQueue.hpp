#pragma once

/**
 * @file SPSCQueue.hpp
 * @brief The sFlow collector's per-worker packet queue, and the loop a worker runs over it.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Moved out of FlowLinkUsageCollector.cpp so the queue's shutdown protocol can be tested on its
 * own, without a socket, a topology or a running collector. The collector includes this header
 * before any of its member functions, which is what makes SPSCQueue a complete type wherever its
 * std::unique_ptr is destroyed (see the note at the top of FlowLinkUsageCollector.cpp).
 */

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <deque>
#include <exception>
#include <mutex>
#include <utility>

namespace sflow
{

// Single-producer / single-consumer queue
template <typename T>
class SPSCQueue
{
  public:
    explicit SPSCQueue(size_t capacity)
        : m_capacity(capacity)
    {
    }

    bool tryPush(T&& item, const std::atomic_bool& running)
    {
        if (!running.load(std::memory_order_relaxed))
        {
            return false;
        }

        std::unique_lock<std::mutex> lk(m_mu);

        if (m_q.size() >= m_capacity)
        {
            return false;
        }
        m_q.emplace_back(std::move(item));
        lk.unlock();
        m_cv_not_empty.notify_one();
        return true;
    }

    /// Waits for an item, or for @p running to read false with the queue empty.
    ///
    /// @p running is anything with a `load()` that returns bool; the collector passes its
    /// std::atomic_bool. A template so a test can hand in a flag whose load() is slow, which
    /// widens the gap between this function's check and its wait enough to hit on purpose.
    template <typename Running>
    bool pop(T& out, const Running& running)
    {
        std::unique_lock<std::mutex> lk(m_mu);
        m_cv_not_empty.wait(lk, [&] { return !m_q.empty() || !running.load(); });
        if (m_q.empty())
        {
            return false; // stop and drained
        }
        out = std::move(m_q.front());
        m_q.pop_front();
        lk.unlock();
        return true;
    }

    /// Wakes every waiter so it re-reads the stop flag. Call it after storing that flag.
    ///
    /// [Co-developed with claude code -- Adam]
    /// Takes m_mu first, and the empty critical section is the whole fix. pop() holds m_mu from
    /// its check of `running` until wait() has queued it on the condition variable. Without the
    /// lock this was possible: a worker checks, sees `running` still true and the queue empty,
    /// and before it is queued the stopper stores false and notifies nobody; the worker then
    /// sleeps for good, run()'s join of the pool never returns, and neither does stop(). With
    /// the lock the notify waits until that worker is either queued (and is woken) or has not
    /// checked yet (and will read false). FlowDispatcher::stop() documents the same shape.
    void notify_all()
    {
        {
            std::lock_guard<std::mutex> lk(m_mu);
        }
        m_cv_not_empty.notify_all();
    }

  private:
    size_t m_capacity;
    std::mutex m_mu;
    std::condition_variable m_cv_not_empty;
    std::deque<T> m_q;
};

/// Calls handle(item); an exception goes to report() instead of out of the worker thread.
template <typename T, typename Handle, typename Report>
void
handleReporting(T& item, Handle& handle, Report& report)
{
    try
    {
        handle(item);
    }
    catch (const std::exception& e)
    {
        report(&e);
    }
    catch (...)
    {
        report(nullptr);
    }
}

/**
 * @brief The worker loop: handle items until @p running reads false, then handle what is left.
 *
 * @param handle  called with each item. May throw.
 * @param report  called with the exception when @p handle throws a std::exception, or with
 *                nullptr when it throws anything else; the loop then goes on with the next item.
 */
template <typename T, typename Running, typename Handle, typename Report>
void
serveUntilDrained(SPSCQueue<T>& queue, const Running& running, Handle&& handle, Report&& report)
{
    T item;
    while (running.load())
    {
        if (!queue.pop(item, running))
        {
            break;
        }
        handleReporting(item, handle, report);
    }

    // Drain remaining after stop
    //
    // [Co-developed with claude code -- Adam]
    // Through the same handling as the loop above. This drain used to call the handler bare, so a
    // packet that threw while the queues emptied at shutdown would leave a worker thread with an
    // exception nothing catches: std::terminate, an abort in the middle of an orderly stop.
    while (queue.pop(item, running))
    {
        handleReporting(item, handle, report);
    }
}

} // namespace sflow
