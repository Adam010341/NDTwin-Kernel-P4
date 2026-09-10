#pragma once

/**
 * @file InjectedNetemLedger.hpp
 * @brief Which netem qdiscs THIS kernel attached, so a recovery can refuse to remove anyone else's.
 *
 * [Co-developed with claude code -- Adam]
 *
 * doc/KNOWN-ISSUES.md B-16. Measured on a live OVS fabric on 2026-09-11 (ROLE-1, 3 of 3
 * reproductions, scratch/overnight-2026-09-05/hunt-0911/ROLE-1-A1-REPORT.md): a successor POSTed
 * /ndt/inject_link_recovery for a link this kernel had never declared down, and the kernel ran
 * `tc qdisc del dev s1-eth1 root` on somebody else's `netem loss 100%` and answered
 * `200 {"ok":true,"detached_at":"root"}`. The previous operator's chaos blackhole disappeared, and
 * neither the reply nor kernel.log said one word about whose qdisc it had been.
 *
 * 🔴 WHY A LEDGER AND NOT A TREE READ. utils::netem::findExistingNetem answers "is there a netem
 * here", which is the question restoreInterface needed and is NOT the question this endpoint is
 * asking. "Whose is it" cannot be read off the qdisc tree at all: a netem carries no owner, and
 * `loss 100%` attached by faults.sh, by the chaos harness and by this kernel are the same three
 * words. The only party that can answer is the process that ran the `add`, and only if it wrote it
 * down. This is that writing down.
 *
 * The handle is the identity, not the interface: `tc` assigns one (`801d:`) per qdisc, so an
 * interface whose netem was removed and replaced by someone else between the injection and the
 * recovery reads as FOREIGN rather than as ours. Interface alone would have said "mine".
 *
 * 🔴 WHAT THIS DELIBERATELY DOES NOT SURVIVE: a kernel restart. It is process memory, like the
 * `declaredDown` flag it pairs with (EdgeProperties says why that one is not read back from disk
 * either), so a kernel that has just started owns nothing and will refuse to detach anything --
 * which is the honest answer, because it genuinely cannot tell its own residue from a colleague's.
 * The startup sweep (TopologyAndFlowMonitor::warnAboutResidualNetem, E-20) is what tells an
 * operator that residue is there, and since B-16 it says to remove it by hand rather than pointing
 * at an endpoint that will now refuse. Whether the ledger should be persisted to
 * `.test_run/`, so a restarted kernel could still take its own injection back, is a question for
 * Adam and is recorded in scratch/overnight-2026-09-05/fix/FIX-A1-SUMMARY.md §7.
 */

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "utils/Utils.hpp"

namespace utils
{
namespace netem
{

/// One netem qdisc this kernel attached: where, which qdisc, and when.
struct InjectedNetem
{
    /// The Mininet interface, `sN-ethM`.
    std::string interface;

    /// The tc handle, verbatim, e.g. `801d:`. Empty when the tree could not be re-read after the
    /// attach -- see InjectedNetemLedger::find, which treats an empty handle as "cannot claim it".
    std::string handle;

    /// Where it went, as utils::describeArgv rendered it: `root` or `parent 5:1`.
    std::string attachPoint;

    /// System-clock milliseconds at the moment of the attach. Formatted with utils::formatTime for
    /// the reply body, so a caller reading "this kernel attached it" can check it against its own
    /// round's clock.
    int64_t attachedAtMs = 0;
};

/**
 * @brief The netem qdiscs this kernel currently believes it attached.
 *
 * Thread-safe: /ndt/inject_link_failure and /ndt/inject_link_recovery each run on their own
 * HttpSession, and two sessions can be in flight at once.
 *
 * Small by construction -- one entry per cut interface, and a fabric has tens of interfaces -- so
 * a vector scan is the whole implementation and no index is worth its bookkeeping.
 */
class InjectedNetemLedger
{
  public:
    /**
     * @brief Records that this kernel attached @p handle at @p attachPoint on @p iface, now.
     *
     * Replaces any earlier entry for the same interface: an interface carries at most one netem
     * this kernel attached (cutInterface refuses to stack a second one), so a second record for
     * the same name means the first one is gone.
     */
    void
    record(const std::string& iface, const std::string& handle, const std::string& attachPoint)
    {
        std::lock_guard<std::mutex> guard(m_mutex);
        for (auto& entry : m_entries)
        {
            if (entry.interface == iface)
            {
                entry.handle = handle;
                entry.attachPoint = attachPoint;
                entry.attachedAtMs = utils::getCurrentTimeMillisSystemClock();
                return;
            }
        }
        m_entries.push_back(InjectedNetem{iface,
                                          handle,
                                          attachPoint,
                                          utils::getCurrentTimeMillisSystemClock()});
    }

    /**
     * @brief What this kernel attached to @p iface, if anything, and only if it can name it.
     *
     * An entry whose handle is empty is NOT returned: the attach happened but the tree could not
     * be re-read afterwards, so this kernel cannot prove that the netem sitting there now is the
     * one it added. Claiming it anyway is the defect this file exists to close, one step smaller.
     */
    std::optional<InjectedNetem>
    find(const std::string& iface) const
    {
        std::lock_guard<std::mutex> guard(m_mutex);
        for (const auto& entry : m_entries)
        {
            if (entry.interface == iface && !entry.handle.empty())
            {
                return entry;
            }
        }
        return std::nullopt;
    }

    /// Forgets @p iface, whether or not it was known. Called after a successful detach, and after a
    /// rollback: a ledger that outlives the qdisc it describes would claim the next one.
    void
    forget(const std::string& iface)
    {
        std::lock_guard<std::mutex> guard(m_mutex);
        for (auto it = m_entries.begin(); it != m_entries.end(); ++it)
        {
            if (it->interface == iface)
            {
                m_entries.erase(it);
                return;
            }
        }
    }

    /// How many interfaces this kernel believes it has cut. For tests and for a log line.
    std::size_t
    size() const
    {
        std::lock_guard<std::mutex> guard(m_mutex);
        return m_entries.size();
    }

  private:
    mutable std::mutex m_mutex;
    std::vector<InjectedNetem> m_entries;
};

/**
 * @brief The one ledger the kernel writes to.
 *
 * A process-wide instance rather than a constructor argument threaded through HttpSession: a
 * session is created per connection, so the injection and the recovery that takes it back are
 * always two different sessions, and anything owned by a session could not answer the question at
 * all. Reached through a function so the storage is initialised on first use in every translation
 * unit that asks (the same reason Logger::instance() is a function).
 *
 * @note Tests do not use this one. HttpSession holds a pointer to it that HttpSessionTestPeer
 *       repoints at a ledger the test owns, so no case can leave state behind for the next.
 */
inline InjectedNetemLedger&
processInjectedNetemLedger()
{
    static InjectedNetemLedger ledger;
    return ledger;
}

} // namespace netem
} // namespace utils
