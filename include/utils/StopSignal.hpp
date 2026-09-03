#pragma once

/**
 * @file StopSignal.hpp
 * @brief One stop request that a worker can observe *while* it is blocked, not only between rounds.
 *
 * [Co-developed with claude code -- Adam]
 *
 * FINDINGS #27 and #76. Both are the same sentence -- "said it would stop, hasn't" -- and both are
 * the same mechanism: a worker loop whose only stop check is the `while (m_running.load())` at the
 * top, wrapped around a round that shells out to `curl` once per switch.
 *
 *   #27  DeviceConfigurationAndPowerManager::fetchOpenFlowTablesInternal walks every up switch and
 *        runs `curl -s --max-time 8` for each. Nothing in that walk reads the stop flag, so a stop
 *        arriving at the first switch is answered after the last one. Measured on the 10-switch
 *        bmv2 fabric with the proxy not answering: SIGINT took **81.09 s**, ~72 s of it inside
 *        DeviceConfigurationAndPowerManager::stop()'s join -- which is 9 remaining switches times
 *        the 8 s deadline, to the second. Idle, the same shutdown was 2.40-3.00 s.
 *
 *   #76  TopologyAndFlowMonitor's poll thread does the same thing three times per round (switches,
 *        links, hosts) at `--connect-timeout 2 --max-time 5`. With the proxy wedged, a kernel whose
 *        sFlow bind had already failed printed `Exiting` and was still alive 8 s later, because
 *        main.cpp calls stop() *after* printing it and stop() waited out the in-flight curl.
 *
 * WHAT THIS TYPE IS FOR, AND WHY IT IS ONE TYPE AND NOT THREE
 *
 * Bounding a stop needs three things, and all three have to agree about the same instant or the
 * bound is not a bound:
 *
 *   1. **A flag the round itself reads.** Checking between switches is what turns "one round" from
 *      the unit of shutdown latency into one request.
 *   2. **A sleep that ends early.** The two workers slice their 10 s sleep into ten 1 s naps to get
 *      this, which costs up to a second and needs writing out at every call site. waitFor() is that
 *      loop, once, and it wakes on the condition variable instead -- so the nap contributes ~0 to
 *      the bound rather than 1 s.
 *   3. **A child process that dies with the request.** This is the half that cannot be done by
 *      checking a flag, and it is where #27's 72 s and #76's 8 s actually live: the flag is not
 *      readable from inside a blocking `popen()` read. request() SIGKILLs the process group of
 *      every child registered at that moment, which closes the pipe, which ends the read.
 *
 * A worker that uses all three stops in the time its *current* request takes to be killed, which is
 * a syscall, not a deadline.
 *
 * @warning **request() is not idempotent with reset().** reset() exists for start(), and for tests
 *          that stop and restart one object. A StopSignal that has been requested stays requested
 *          until something calls reset(), so a late-registered child is killed on arrival rather
 *          than being allowed to run to its deadline.
 *
 * @note No lock in here is ever held across a call into any other subsystem. The mutex guards a
 *       pid set and a name multiset, nothing else, and request() calls only ::kill() while holding
 *       it. That matters because the EventBus deadlock family in doc/audit is exactly what happens
 *       when a shutdown path takes a second lock while holding the first; this type deliberately
 *       has nothing to take.
 */

#include "utils/Utils.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace utils
{

/**
 * @brief The stop request for one subsystem's worker threads.
 *
 * Owned by the object whose stop() is being bounded, one per object. Not copyable or movable: the
 * children registered against it hold a reference, and the workers counted in it hold another.
 */
class StopSignal
{
  public:
    StopSignal() = default;
    StopSignal(const StopSignal&) = delete;
    StopSignal& operator=(const StopSignal&) = delete;

    /// True once request() has run and until reset() does. Cheap: no lock.
    bool stopRequested() const noexcept { return m_stopped.load(std::memory_order_acquire); }

    /// Arms the signal for a fresh run. Call from start(), before any worker is launched.
    void reset()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_stopped.store(false, std::memory_order_release);
    }

    /**
     * @brief Requests the stop: sets the flag, wakes every sleeper, kills every in-flight child.
     *
     * @return how many child processes were signalled. Zero is the common case (nothing was
     *         mid-request); it is returned so a caller can report the interesting case.
     *
     * Safe to call more than once, and safe to call when no worker was ever started.
     */
    std::size_t request()
    {
        std::size_t signalled = 0;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_stopped.store(true, std::memory_order_release);
            for (const pid_t pid : m_children)
            {
                // The negative pid is the point: execCommandCancellable puts each child in its own
                // process group precisely so that `sh -c "curl ..."` dies together with the curl it
                // forked. A shell that exec'd the curl (which is what dash and bash both do for a
                // single simple command) is the same pid either way, so this is correct in both
                // shapes rather than in the one that happens to be installed.
                if (::kill(-pid, SIGKILL) == 0)
                {
                    ++signalled;
                }
            }
        }
        m_wake.notify_all();
        return signalled;
    }

    /**
     * @brief Sleeps for @p duration, or until the stop is requested, whichever comes first.
     *
     * @return true if the stop was requested (so the caller must not start another round).
     *
     * This replaces the `for (int i = 0; i < 10; ++i) { if (!m_running) break; sleep(1s); }` idiom.
     * That idiom is correct but its resolution *is* its cost: it answers a stop after up to a
     * second, every time, on every worker, and main.cpp stops five subsystems in a row.
     */
    template <class Rep, class Period>
    bool waitFor(std::chrono::duration<Rep, Period> duration)
    {
        std::unique_lock<std::mutex> lock(m_mutex);
        m_wake.wait_for(lock, duration, [this] { return m_stopped.load(std::memory_order_acquire); });
        return m_stopped.load(std::memory_order_acquire);
    }

    /**
     * @brief Counts one running worker for as long as it lives, under a name a human can read.
     *
     * The names are what makes "the kernel logs exactly what it is still waiting on" possible:
     * without them the report can only say how many threads have not finished, which is the number
     * an operator already has and cannot act on.
     */
    class WorkerScope
    {
      public:
        WorkerScope(StopSignal& signal, std::string name) : m_signal(&signal), m_name(std::move(name))
        {
            std::lock_guard<std::mutex> lock(m_signal->m_mutex);
            m_signal->m_workers.push_back(m_name);
        }
        ~WorkerScope()
        {
            {
                std::lock_guard<std::mutex> lock(m_signal->m_mutex);
                const auto at = std::find(m_signal->m_workers.begin(), m_signal->m_workers.end(), m_name);
                if (at != m_signal->m_workers.end())
                {
                    m_signal->m_workers.erase(at);
                }
            }
            m_signal->m_wake.notify_all();
        }
        WorkerScope(const WorkerScope&) = delete;
        WorkerScope& operator=(const WorkerScope&) = delete;

      private:
        StopSignal* m_signal;
        std::string m_name;
    };

    /**
     * @brief Waits up to @p bound for every WorkerScope to be gone.
     *
     * @return the names still running when the bound expired, in registration order; **empty means
     *         they all finished in time**.
     *
     * Deliberately does not join anything and deliberately does not give up on anything: the caller
     * still joins, because detaching a thread that touches the object's members is a use-after-free
     * and a bounded stop that crashes is not a bounded stop. What this buys is the ability to say
     * *what* is being waited on before the wait becomes indistinguishable from a hang.
     */
    std::vector<std::string> waitForWorkers(std::chrono::milliseconds bound)
    {
        std::unique_lock<std::mutex> lock(m_mutex);
        m_wake.wait_for(lock, bound, [this] { return m_workers.empty(); });
        return m_workers;
    }

    /// How many workers are currently counted. For tests and for the report's arithmetic.
    std::size_t runningWorkers()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_workers.size();
    }

  private:
    friend class WorkerScope;
    friend class ChildProcessRegistration;

    /**
     * @brief Registers @p pid as killable until this object dies. Returns false if already stopped.
     *
     * A false return is not an error: it means the stop landed between the fork and here, so the
     * child was never in the set request() walked, and the caller must kill it itself. Returning a
     * bool rather than doing the kill in here keeps ::kill out of the constructor's failure path.
     */
    bool addChild(pid_t pid)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_stopped.load(std::memory_order_acquire))
        {
            return false;
        }
        m_children.push_back(pid);
        return true;
    }

    /**
     * @brief Forgets @p pid.
     *
     * 🔴 Called BEFORE waitpid(), never after, and that ordering is the whole of this function's
     * correctness. A pid is reusable by the kernel the instant it is reaped; leaving it in the set
     * across the reap means a request() racing the reap can signal an unrelated process that has
     * just been given the same number. Removing first gives up something much smaller: a stop
     * arriving in the window between the child closing its stdout and its exit status being
     * collected will not signal it -- and a child that has closed stdout has already finished
     * writing, so that wait is the kernel reaping a dead process, not a request in flight.
     */
    void removeChild(pid_t pid)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        const auto at = std::find(m_children.begin(), m_children.end(), pid);
        if (at != m_children.end())
        {
            m_children.erase(at);
        }
    }

    std::atomic<bool> m_stopped{false};
    mutable std::mutex m_mutex;
    std::condition_variable m_wake;
    std::vector<pid_t> m_children;
    std::vector<std::string> m_workers;
};

/// RAII for the pid set. Also carries "the stop beat me here", which the runner must act on.
class ChildProcessRegistration
{
  public:
    ChildProcessRegistration(StopSignal& signal, pid_t pid) : m_signal(&signal), m_pid(pid)
    {
        m_registered = m_signal->addChild(pid);
    }
    ~ChildProcessRegistration() { release(); }

    /// False when the stop had already been requested; the caller kills @p pid itself.
    bool registered() const noexcept { return m_registered; }

    /// Forgets the pid. Idempotent, and called explicitly before waitpid() -- see removeChild().
    void release()
    {
        if (m_registered)
        {
            m_signal->removeChild(m_pid);
            m_registered = false;
        }
    }

    ChildProcessRegistration(const ChildProcessRegistration&) = delete;
    ChildProcessRegistration& operator=(const ChildProcessRegistration&) = delete;

  private:
    StopSignal* m_signal;
    pid_t m_pid;
    bool m_registered = false;
};

/**
 * @brief Waits for @p signal's workers, and says what is still running if @p bound expires.
 *
 * [Co-developed with claude code -- Adam]
 *
 * FINDINGS #27 / #76, the third of the three things the required behaviour asks for: *or the kernel
 * logs exactly what it is still waiting on, once, with the elapsed time.*
 *
 * @param signal    the subsystem's stop signal. request() must already have been called.
 * @param bound     how long to wait quietly. Zero makes the report unconditional, which is how the
 *                  test drives it.
 * @param subsystem what to call this object in the message.
 * @return true if the bound was exceeded and the report was emitted.
 *
 * Emits **one** line, not one per worker and not one per second: a shutdown that has gone wrong is
 * already going to be read under pressure, and a repeating line is how the two 1 Hz INFO messages
 * elsewhere in this process reached 138,000 lines a day. It does not detach, abandon or kill the
 * worker threads -- the caller still joins them. Detaching a thread that touches the object's
 * members is a use-after-free, and a "bounded" stop that returns by crashing is not bounded; what
 * this buys is that the remaining wait is *explained* rather than looking like a hang.
 */
inline bool
reportIfWorkersOutlastTheBound(StopSignal& signal,
                               std::chrono::milliseconds bound,
                               const std::string& subsystem)
{
    const auto startedAt = std::chrono::steady_clock::now();
    const std::vector<std::string> stragglers = signal.waitForWorkers(bound);
    if (stragglers.empty())
    {
        return false;
    }

    std::string names;
    for (const std::string& name : stragglers)
    {
        if (!names.empty())
        {
            names += ", ";
        }
        names += name;
    }

    SPDLOG_LOGGER_WARN(Logger::instance(),
                       "{}: still waiting on {} worker(s) [{}] {:.2f} s after the stop request; "
                       "the process will not exit until they return",
                       subsystem,
                       stragglers.size(),
                       names,
                       std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt)
                           .count());
    return true;
}

/**
 * @brief execCommand(), except that a stop request kills it instead of being waited out.
 *
 * [Co-developed with claude code -- Adam]
 *
 * @param cmd   the same shell command string execCommand() takes. **Identical semantics**: the
 *              string still goes to `/bin/sh -c`, so the builders that produce it, the tests that
 *              pin their wire format (tests/test_RequestDeadlines.cpp) and the per-site shell
 *              classification (tests/python/test_shell_command_construction.py) all keep meaning
 *              exactly what they meant. This is not the popen-to-execArgv conversion that
 *              doc/audit/2026-09-03_fix-cloexec/FIX-CLOEXEC.md §7 lists as deliberately not
 *              attempted; it is popen with a pid the caller can reach.
 * @param stop  killed by stop.request(), and consulted before the fork.
 *
 * @return the child's stdout, plus ran/status as CommandOutcome documents them. A cancelled child
 *         reports ran == true with a status of "killed by SIGKILL" -- it did run -- so callers
 *         distinguish "cancelled" by asking @p stop, never by inspecting the status.
 *
 * WHY THIS EXISTS AND popen() COULD NOT BE MADE TO WORK
 *   popen() does not expose the child's pid. Nothing else in the process can find it, so nothing
 *   can end it early: the only bound on `curl -s --max-time 8` is the 8 s, per switch, serially.
 *   Owning the fork is the whole change; everything below is popen's own behaviour re-implemented.
 *
 * THREE DIFFERENCES FROM popen(), ALL DELIBERATE
 *   1. **Its own process group** (`setpgid` on both sides of the fork, which is the race-free
 *      idiom). request() then signals the group, so a `/bin/sh` that forked rather than exec'd its
 *      curl takes the curl with it. The cost is that a Ctrl-C at a terminal no longer reaches these
 *      children through the tty -- they are no longer in the kernel's foreground group. That is a
 *      change in who kills them, not in whether: SIGINT now reaches main, main calls stop(), and
 *      stop() kills them explicitly. It is also the safer direction, because it no longer depends
 *      on the kernel having a controlling terminal at all (`ndt up` runs it under setsid).
 *   2. **close_range(3, ...) in the child**, which execArgv already does and popen never did.
 *      FINDINGS #47 was fixed at the socket, so this is defence in depth rather than the fix -- but
 *      routing two of the kernel's hottest spawn sites through here makes that hole smaller, not
 *      bigger, which is the direction a change in this area has to move.
 *   3. **SIGKILL, not SIGTERM.** There is nothing for an abandoned `curl` to clean up, and a
 *      SIGTERM it chooses to handle would put an unbounded step back into a function whose entire
 *      purpose is to remove one.
 */
inline CommandOutcome
execCommandCancellable(const std::string& cmd, StopSignal& stop)
{
    // Asked before the fork as well as after: a stop that has already been requested must not start
    // one more 8 s request, and the cheapest way not to wait for a child is not to create it.
    if (stop.stopRequested())
    {
        return CommandOutcome{"", false, -1};
    }

    int fds[2];
    if (::pipe(fds) != 0)
    {
        // Same exception execCommand throws when popen() fails, for the same reason: the callers
        // already catch it, and the alternative is reporting "the control plane said nothing".
        throw std::runtime_error("pipe() failed!");
    }

    const pid_t pid = ::fork();
    if (pid < 0)
    {
        const int savedErrno = errno;
        ::close(fds[0]);
        ::close(fds[1]);
        std::cerr << "Command failed (could not fork: " << std::strerror(savedErrno) << "): " << cmd
                  << "\n";
        return CommandOutcome{"", false, -1};
    }

    if (pid == 0)
    {
        // Child. Async-signal-safe calls only, all the way to execl. cmd was built before the fork
        // and c_str() allocates nothing, which is why the string may be read here.
        ::setpgid(0, 0);
        ::close(fds[0]);
        if (::dup2(fds[1], STDOUT_FILENO) < 0)
        {
            ::_exit(127);
        }
        ::close(fds[1]);
        (void)::close_range(3, ~0U, 0);
        ::execl("/bin/sh", "sh", "-c", cmd.c_str(), static_cast<char*>(nullptr));
        ::_exit(127);
    }

    // Also on the parent side, and its failure is ignored: whichever of the two runs first wins,
    // and the loser fails with EACCES because the child has already exec'd. Doing it in only one
    // place leaves a window in which the group does not exist yet and request() would miss it.
    (void)::setpgid(pid, pid);

    ChildProcessRegistration registration(stop, pid);
    if (!registration.registered())
    {
        // The stop landed between stopRequested() above and addChild(). The child is not in the set
        // request() walked, so nobody else will ever signal it.
        ::kill(-pid, SIGKILL);
    }

    ::close(fds[1]);

    std::string result;
    std::array<char, 256> buffer;
    for (;;)
    {
        const ssize_t n = ::read(fds[0], buffer.data(), buffer.size());
        if (n > 0)
        {
            result.append(buffer.data(), static_cast<size_t>(n));
            continue;
        }
        if (n < 0 && errno == EINTR)
        {
            continue;
        }
        break;
    }
    ::close(fds[0]);

    // Before waitpid, never after. See StopSignal::removeChild for why the ordering is the
    // correctness of this function and not a detail.
    registration.release();

    int status = 0;
    while (::waitpid(pid, &status, 0) < 0)
    {
        if (errno != EINTR)
        {
            return CommandOutcome{result, false, -1};
        }
    }

    // A killed child is not a fault to report. Without this test every cancelled request would
    // print "Command failed (killed by signal 9)" on the way down -- one line per switch, at the
    // exact moment an operator is trying to read why the kernel is stopping.
    if (status != 0 && !stop.stopRequested())
    {
        const int savedErrno = errno;
        const std::string why = describeCommandStatus(status, cmd, savedErrno);
        std::cerr << "Command failed (" << why << "): " << cmd << "\n";
    }
    return CommandOutcome{result, true, status};
}

} // namespace utils
