#pragma once

#include <cstdint>
#include <map>
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
 * Not thread-safe: intended for a single worker thread's own loop.
 */
class KeyedFailureLog
{
  public:
    /// What endPass() found: failures seen for the first time, and failures that stopped.
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
     * Call exactly once per pass, after every record(). Calling it twice would report the same
     * recovery twice and then treat every still-failing key as new.
     */
    Report endPass()
    {
        Report report;

        for (const auto& [key, message] : m_thisPass)
        {
            auto it = m_open.find(key);
            if (it == m_open.end())
            {
                report.newFailures.emplace_back(key, message);
                m_open.emplace(key, 1);
            }
            else
            {
                ++it->second;
            }
        }

        for (auto it = m_open.begin(); it != m_open.end();)
        {
            if (m_thisPass.count(it->first) == 0)
            {
                report.recovered.emplace_back(it->first, it->second);
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
    /// key -> message, recorded during the pass in progress.
    std::map<std::string, std::string> m_thisPass;
    /// key -> number of passes it has been failing for.
    std::map<std::string, uint64_t> m_open;
};

} // namespace utils
