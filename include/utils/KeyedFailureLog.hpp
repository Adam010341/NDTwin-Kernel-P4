#pragma once

#include <chrono>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

/**
 * @file KeyedFailureLog.hpp
 * @brief Edge-triggered logging for a loop that re-checks the same conditions thousands of times
 *        a second.
 *
 * [Co-developed with claude code -- Adam]
 */

namespace utils
{

/**
 * @brief Reports the first occurrence of each distinct failure, and its recovery. Nothing else.
 *
 * @details
 * The path-walk loop in FlowLinkUsageCollector re-derives every tracked flow's path every
 * millisecond, and warns on each failure. One persistent failure therefore writes roughly a
 * thousand identical lines per second per flow. Measured on a two-flow run: **270,991**
 * occurrences of `edge not found by dpid/port 4:3`, a 41 MB kernel log.
 *
 * That flood is not merely untidy -- it is actively harmful, and this class exists because of
 * what it cost. That warning named the exact port that was misconfigured, so it was the answer
 * to a bug that took a separate investigation to find. It was allowlisted (so the log layer
 * stayed green) and buried in 41 MB (so nobody read it). A signal repeated a quarter of a
 * million times is indistinguishable from noise.
 *
 * Keyed rather than a single flag because these loops fail for several independent reasons at
 * once -- a missing host edge, a missing inter-switch edge, a hop-count blowout -- and
 * collapsing them would hide all but the first.
 *
 * Usage, once per pass of the loop:
 * @code
 *   for (const auto& flow : flows) {
 *       if (failed) { log.record(key, message); }
 *   }
 *   for (const auto& [key, message] : log.endPass().newFailures) { WARN(message); }
 *   for (const auto& [key, count]   : log.endPass().recovered)   { INFO(...); }
 * @endcode
 *
 * A failure can also be required to persist before it is reported at all. The path-walk loop needs
 * that: for the first seconds after startup the flow tables are still being fetched one switch at a
 * time, so "no table for dpid 10" is true, transient, and not a fault. Measured on one real start:
 * 7454, 37 and 29 passes before each cleared. Reporting those puts three warnings in every clean
 * startup, and the only ways to get the log check green again are to allowlist them -- which is
 * exactly how the previous version of this warning became unread -- or to raise the bar here.
 *
 * Not thread-safe: intended for a single worker thread's own loop.
 */
class KeyedFailureLog
{
  public:
    using Clock = std::chrono::steady_clock;

    /**
     * @param reportAfter How long a failure must persist before it is reported at all. Zero reports
     *                    the first occurrence, which is what a low-frequency caller wants.
     * @param forgetAfter How long a failure may be absent before its history is discarded. Defaults
     *                    to twice @p reportAfter, and to zero when @p reportAfter is zero.
     *
     * @details
     * [Co-developed with claude code -- Adam]
     * @p forgetAfter exists because without it the hold-off measured *consecutive* presence, and a
     * fault that is intermittent -- which is most of them -- was therefore reported never. Measured
     * on the real header at the path-walk loop's 1 kHz cadence with a 15 s hold-off: a failure
     * present in **99% of 600,000 passes over ten minutes reported zero times**, and 10-second
     * bursts of a permanently broken flow also reported zero times. One absent pass in a hundred was
     * enough, because an unreported key was erased the moment it went missing and its clock restarted
     * from scratch on the next appearance.
     *
     * That is not a theoretical gap. The keys in the path-walk loop come from flows in
     * `m_flowInfoTable`, which `purgeIdleFlows` removes and `handlePacket` re-creates, so their
     * presence tracks traffic and is not monotonic -- and the warning this class was built to ration,
     * `edge not found by dpid/port 4:3`, is the line that answered the P4 host-port bug. Rationing it
     * to zero is worse than the 270,991 copies it replaced: a flood can be grepped, silence cannot.
     */
    explicit KeyedFailureLog(Clock::duration reportAfter = Clock::duration::zero(),
                             std::optional<Clock::duration> forgetAfter = std::nullopt)
        : m_reportAfter(reportAfter),
          m_forgetAfter(forgetAfter.value_or(reportAfter * 2))
    {
    }

    /// What endPass() found: failures newly worth reporting, and reported failures that stopped.
    struct Report
    {
        /// key -> message, for failures not present in the previous pass.
        std::vector<std::pair<std::string, std::string>> newFailures;
        /// key -> how many passes it was seen in, for failures absent from this pass.
        std::vector<std::pair<std::string, uint64_t>> recovered;
    };

    /// Records one failure during the current pass. Repeats within a pass count once.
    void record(const std::string& key, const std::string& message)
    {
        m_thisPass[key] = message;
    }

    /**
     * @brief Closes the pass and reports only the edges.
     *
     * Call exactly once per pass, after every record().
     *
     * A second call in the same pass reports **every still-open, already-reported failure as
     * recovered** -- for faults that have not recovered at all -- and then forgets them. That is a
     * false statement about the network written at INFO, so a log check looking for warnings would
     * not catch it. (An earlier version of this comment said a second call would report the same
     * recovery twice; it cannot, because a recovered key is erased in the call that reports it.)
     * [Co-developed with claude code -- Adam]
     */
    Report endPass(Clock::time_point now = Clock::now())
    {
        Report report;

        // Expire first, record second.
        //
        // [Co-developed with claude code -- Adam]
        // The order matters and the other way round was wrong. The record loop below refreshes
        // lastSeen, and the prune loop skips any key present in this pass -- so if a key reappeared
        // after being absent longer than m_forgetAfter, `now - lastSeen` was already 0 by the time
        // the prune loop looked, the entry survived with its ancient firstSeen, and
        // `now - firstSeen >= m_reportAfter` fired on that very first pass. A fault seen once, then
        // once again a hundred seconds later, was reported immediately -- the hold-off bypassed
        // entirely.
        //
        // Only reachable when endPass() is not called during the gap, which the 1 kHz path-walk loop
        // always does; but this class lives in utils/ and a caller that only closes a pass when it
        // has something to report would hit it. Found by review. My own test for the gap case called
        // endPass every second throughout, so the prune loop cleaned up and the test passed.
        for (auto it = m_open.begin(); it != m_open.end();)
        {
            if (now - it->second.lastSeen >= m_forgetAfter && m_forgetAfter > Clock::duration::zero())
            {
                if (it->second.reported)
                {
                    report.recovered.emplace_back(it->first, it->second.passes);
                }
                it = m_open.erase(it);
            }
            else
            {
                ++it;
            }
        }

        for (const auto& [key, message] : m_thisPass)
        {
            auto it = m_open.find(key);
            if (it == m_open.end())
            {
                it = m_open.emplace(key, Entry{now, now, 1, false}).first;
            }
            else
            {
                ++it->second.passes;
                it->second.lastSeen = now;
            }

            // Reported on the pass where it has persisted long enough, and only once. A failure
            // that clears before then is never reported at all, and neither is its recovery --
            // otherwise the hold-off would just move the noise to the recovery line.
            //
            // Persistence is measured from firstSeen, which survives gaps shorter than
            // m_forgetAfter. It used to be reset by any single absent pass, which is how an
            // intermittent fault reported nothing at all.
            if (!it->second.reported && now - it->second.firstSeen >= m_reportAfter)
            {
                it->second.reported = true;
                report.newFailures.emplace_back(key, message);
            }
        }

        for (auto it = m_open.begin(); it != m_open.end();)
        {
            // Absent, but remembered until it has been gone for m_forgetAfter -- so a fault that
            // flaps accumulates towards its hold-off instead of restarting, while one that genuinely
            // stops is forgotten and (if it was ever reported) reported as recovered.
            if (m_thisPass.count(it->first) == 0 && now - it->second.lastSeen >= m_forgetAfter)
            {
                if (it->second.reported)
                {
                    report.recovered.emplace_back(it->first, it->second.passes);
                }
                it = m_open.erase(it);
            }
            else
            {
                ++it;
            }
        }

        m_thisPass.clear();
        return report;
    }

    /// How many distinct failures are currently open. For tests and diagnostics.
    std::size_t openCount() const
    {
        return m_open.size();
    }

  private:
    struct Entry
    {
        Clock::time_point firstSeen;
        /// Last pass this key was recorded in. Kept so a gap shorter than m_forgetAfter does not
        /// restart firstSeen. [Co-developed with claude code -- Adam]
        Clock::time_point lastSeen;
        uint64_t passes;
        bool reported;
    };

    /// key -> message, recorded during the pass in progress.
    std::map<std::string, std::string> m_thisPass;
    /// key -> when it started failing, how many passes, and whether it was reported.
    std::map<std::string, Entry> m_open;
    Clock::duration m_reportAfter;
    /// How long an absent key is remembered before its history is discarded.
    Clock::duration m_forgetAfter;
};

} // namespace utils
