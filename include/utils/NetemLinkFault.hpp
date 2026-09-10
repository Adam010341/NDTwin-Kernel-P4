#pragma once

/**
 * @file NetemLinkFault.hpp
 * @brief Making a DECLARED link failure be a real one, on a Mininet fabric, without destroying the
 *        interface's shaping on the way.
 *
 * [Co-developed with claude code -- Adam]
 *
 * doc/KNOWN-ISSUES.md B-6, second half. Adam's question on 2026-09-05 was "why can a link the API
 * says is down still carry packets" -- so /ndt/inject_link_failure both declares the failure in the
 * twin AND cuts the link, and /ndt/inject_link_recovery puts both back.
 *
 * 🔴 THE ONE THING THIS FILE EXISTS TO GET RIGHT, and it is not "run tc":
 *
 *     `tc qdisc add dev X root netem loss 100%` does NOT stack a layer on a TCLink interface.
 *     It REPLACES htb -- the bandwidth shaping the whole experiment depends on is silently gone
 *     -- and `tc qdisc del dev X root` then restores the KERNEL DEFAULT, not htb. The customary
 *     teardown check ("no netem residue") is blind to it, and the NOPASSWD sudo grants on this
 *     machine cannot put htb back.
 *
 * That cost a whole overnight OVS round on 2026-08-13. tools/test_workflow/faults.sh carries the
 * rule that came out of it -- read the live qdisc tree and attach UNDER the shaper rather than over
 * it -- and this file is that logic moved into the kernel, deliberately as a straight port rather
 * than a reimplementation:
 *
 *   - under `htb`, netem hangs off the default class: `parent <handle><default>`
 *   - on an unshaped interface, `root` is correct (and is why the P4 runbook's recipe is valid)
 *   - a netem already present means an earlier round did not clean up: REFUSE, because stacking
 *     onto it makes the restore ambiguous and this endpoint would then be the thing that corrupts
 *     the next experiment
 *
 * Restore reads the tree again and deletes the netem at the parent it is actually attached to,
 * rather than remembering where it was put. That is on purpose: the kernel process may have been
 * restarted between the injection and the recovery, and a restore that depends on in-process
 * memory would leave the fault in place for ever in exactly that case. The tree is the state.
 *
 * @note The sudo grants this needs were confirmed present on this machine with `sudo -n -l` on
 *       2026-09-06:
 *         tc qdisc add dev s[0-9]*-eth[0-9]* root netem *   |  del dev ... root
 *         tc qdisc add dev s[0-9]*-eth[0-9]* parent * netem *  |  del dev ... parent *
 *         tc qdisc show dev s[0-9]*-eth[0-9]*
 *       Both attach forms are permitted, so the safe one is the one that gets used. The interface
 *       name is checked against that same shape before anything runs -- see
 *       isMininetInterfaceName, which is a refusal, not an escape: nothing here builds a command
 *       line, so a name is never shell input, but a name outside the grant would fail with a
 *       password prompt the kernel cannot answer and the caller deserves the clearer error.
 */

#include <cstdint>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "utils/Utils.hpp"

namespace utils
{
namespace netem
{

/// What running one tc command produced. Mirrors utils::CommandOutcome, kept separate so a test
/// can supply one without linking the executor.
struct TcOutcome
{
    bool ran = false;
    int status = -1;
    std::string output;

    bool succeeded() const { return ran && status == 0; }
};

/// The seam. A test supplies one that answers from a script; production supplies realTcRunner().
using TcRunner = std::function<TcOutcome(const std::vector<std::string>&)>;

/// Where netem may be attached (or is attached), as the tc arguments that name it.
struct AttachPoint
{
    /// True when @c tcArgs names a place. False means read @c why and do nothing.
    bool safe = false;

    /// Either {"root"} or {"parent", "<handle><classid>"} -- passed to tc as separate argv words.
    std::vector<std::string> tcArgs;

    /// Why not, when !safe. Goes into the response body: this endpoint refuses more often than it
    /// fails, and a caller cannot tell the two apart from a status code.
    std::string why;
};

/// `sN-ethM`, the interface Mininet gives switch @p bridge's port @p port.
inline std::string
mininetInterfaceName(const std::string& bridge, uint32_t port)
{
    return bridge + "-eth" + std::to_string(port);
}

/**
 * @brief Whether @p name is inside the shape the sudoers grant covers: s<digits>-eth<digits>.
 *
 * Stricter than the glob in sudoers (`s[0-9]*-eth[0-9]*`, which also matches `s-eth`) on purpose:
 * a name that cannot be produced by Mininet means the bridge name in the topology file is not what
 * this code assumes, and guessing past that is how a fault gets injected on the wrong interface.
 */
inline bool
isMininetInterfaceName(const std::string& name)
{
    const auto dash = name.find("-eth");
    if (name.size() < 6 || name[0] != 's' || dash == std::string::npos || dash < 2)
    {
        return false;
    }
    for (std::size_t i = 1; i < dash; ++i)
    {
        if (name[i] < '0' || name[i] > '9') return false;
    }
    const std::size_t digits = dash + 4;
    if (digits >= name.size()) return false;
    for (std::size_t i = digits; i < name.size(); ++i)
    {
        if (name[i] < '0' || name[i] > '9') return false;
    }
    return true;
}

/// Splits one `tc qdisc show` line into whitespace-separated words.
inline std::vector<std::string>
splitWords(const std::string& line)
{
    std::istringstream in(line);
    std::vector<std::string> words;
    std::string w;
    while (in >> w)
    {
        words.push_back(w);
    }
    return words;
}

/// The lines of a `tc qdisc show dev X` reply, blank ones dropped.
inline std::vector<std::string>
qdiscLines(const std::string& tree)
{
    std::vector<std::string> out;
    std::istringstream in(tree);
    std::string line;
    while (std::getline(in, line))
    {
        if (!splitWords(line).empty())
        {
            out.push_back(line);
        }
    }
    return out;
}

/**
 * @brief Where netem may be attached on this interface without destroying its shaping.
 *
 * Straight port of faults.sh's netem_attach_point. @p tree is the output of
 * `tc qdisc show dev <iface>`.
 */
inline AttachPoint
planAttach(const std::string& tree)
{
    AttachPoint plan;
    const auto lines = qdiscLines(tree);
    if (lines.empty())
    {
        plan.why = "the qdisc tree for this interface is empty or could not be read";
        return plan;
    }

    std::string rootLine;
    for (const auto& line : lines)
    {
        const auto w = splitWords(line);
        if (w.size() >= 2 && w[0] == "qdisc" && w[1] == "netem")
        {
            // Residue from an earlier round. Stacking onto it would make the restore ambiguous --
            // and an injection tool that corrupts the next experiment is worse than none.
            plan.why = "netem is already attached to this interface; refusing to stack a second "
                       "one, because the restore could then not tell them apart. Remove the "
                       "existing one first";
            return plan;
        }
        for (std::size_t i = 3; i < w.size(); ++i)
        {
            if (w[i] == "root")
            {
                if (rootLine.empty()) rootLine = line;
                break;
            }
        }
    }

    if (rootLine.empty())
    {
        plan.why = "no root qdisc line in the tree for this interface";
        return plan;
    }

    const auto w = splitWords(rootLine);
    if (w.size() < 3)
    {
        plan.why = "the root qdisc line is not in the shape tc produces";
        return plan;
    }
    const std::string& kind = w[1];
    const std::string& handle = w[2];

    if (kind == "htb")
    {
        // TCLink's shaper. netem hangs off the default class, so `del parent H:D` later removes
        // the netem and leaves htb standing. `default` is printed in hex on some kernels and in
        // decimal on others; tc parses either, which is why the token is concatenated verbatim
        // rather than reformatted -- faults.sh does exactly the same and has the live evidence.
        for (std::size_t i = 3; i + 1 < w.size(); ++i)
        {
            if (w[i] == "default")
            {
                plan.safe = true;
                plan.tcArgs = {"parent", handle + w[i + 1]};
                return plan;
            }
        }
        plan.why = "the interface is shaped by htb but its root line names no default class, so "
                   "there is nowhere to attach netem without replacing the shaper";
        return plan;
    }

    plan.safe = true;
    plan.tcArgs = {"root"};
    return plan;
}

/**
 * @brief Where the netem on this interface is attached, for the delete that removes it.
 *
 * Read from the live tree rather than remembered, so a recovery still works after a kernel
 * restart. @p tree is the output of `tc qdisc show dev <iface>`.
 */
inline AttachPoint
findExistingNetem(const std::string& tree)
{
    AttachPoint at;
    for (const auto& line : qdiscLines(tree))
    {
        const auto w = splitWords(line);
        if (w.size() < 4 || w[0] != "qdisc" || w[1] != "netem")
        {
            continue;
        }
        if (w[3] == "root")
        {
            at.safe = true;
            at.tcArgs = {"root"};
            return at;
        }
        if (w[3] == "parent" && w.size() >= 5)
        {
            at.safe = true;
            at.tcArgs = {"parent", w[4]};
            return at;
        }
        at.why = "a netem qdisc is present but its attach point could not be read from the tree";
        return at;
    }
    at.why = "no netem qdisc is attached to this interface";
    return at;
}

/// The tc this kernel runs. `sudo -n`, argv form, never a shell -- see utils::execArgv.
inline TcRunner
realTcRunner()
{
    return [](const std::vector<std::string>& args) {
        std::vector<std::string> argv{"sudo", "-n", "tc"};
        argv.insert(argv.end(), args.begin(), args.end());
        const auto out = utils::execArgv(argv);
        return TcOutcome{out.ran, out.status, out.output};
    };
}

/// `tc qdisc show dev <iface>`, as this file's other functions want it.
inline TcOutcome
showQdisc(const std::string& iface, const TcRunner& run)
{
    return run({"qdisc", "show", "dev", iface});
}

/**
 * @brief Cut @p iface with `netem loss 100%`, under the shaper rather than over it.
 * @return A report: what the tree held before, where the netem went, what it holds now.
 *         `"ok": false` with a `"refused"` or `"error"` key when nothing was attached.
 */
inline nlohmann::json
cutInterface(const std::string& iface, const std::string& loss, const TcRunner& run)
{
    nlohmann::json report{{"interface", iface}, {"ok", false}};

    if (!isMininetInterfaceName(iface))
    {
        report["refused"] = "interface name '" + iface +
                            "' is not of the form s<N>-eth<M>; the twin will not run tc against "
                            "an interface it cannot have derived from a Mininet bridge";
        return report;
    }

    const auto before = showQdisc(iface, run);
    if (!before.succeeded())
    {
        report["error"] = "could not read the qdisc tree (tc qdisc show returned " +
                          std::to_string(before.status) +
                          "); on this machine that usually means sudo -n was refused";
        return report;
    }
    report["qdisc_before"] = before.output;

    const auto plan = planAttach(before.output);
    if (!plan.safe)
    {
        report["refused"] = plan.why;
        return report;
    }

    std::vector<std::string> args{"qdisc", "add", "dev", iface};
    args.insert(args.end(), plan.tcArgs.begin(), plan.tcArgs.end());
    args.push_back("netem");
    args.push_back("loss");
    args.push_back(loss);

    const auto added = run(args);
    report["attached_at"] = utils::describeArgv(plan.tcArgs);
    report["command"] = utils::describeArgv(args);
    if (!added.succeeded())
    {
        report["error"] = "tc refused the attach (status " + std::to_string(added.status) + ")";
        return report;
    }

    report["ok"] = true;
    report["qdisc_after"] = showQdisc(iface, run).output;
    return report;
}

/**
 * @brief Remove the netem this file attached to @p iface, leaving whatever was under it.
 * @return A report. Removing a netem that is not there is `"ok": true` with `"noop"` set: a
 *         recovery must be idempotent, because the alternative is a caller that cannot get a
 *         fabric back to health without knowing what it did to it.
 */
inline nlohmann::json
restoreInterface(const std::string& iface, const TcRunner& run)
{
    nlohmann::json report{{"interface", iface}, {"ok", false}};

    if (!isMininetInterfaceName(iface))
    {
        report["refused"] = "interface name '" + iface + "' is not of the form s<N>-eth<M>";
        return report;
    }

    const auto before = showQdisc(iface, run);
    if (!before.succeeded())
    {
        report["error"] = "could not read the qdisc tree (tc qdisc show returned " +
                          std::to_string(before.status) + ")";
        return report;
    }
    report["qdisc_before"] = before.output;

    const auto at = findExistingNetem(before.output);
    if (!at.safe)
    {
        // Not an error: there is nothing to undo, and the twin's declaration is withdrawn either
        // way. Said out loud so a caller can tell "already clean" from "cleaned by me".
        report["ok"] = true;
        report["noop"] = at.why;
        return report;
    }

    std::vector<std::string> args{"qdisc", "del", "dev", iface};
    args.insert(args.end(), at.tcArgs.begin(), at.tcArgs.end());

    const auto deleted = run(args);
    report["detached_at"] = utils::describeArgv(at.tcArgs);
    report["command"] = utils::describeArgv(args);
    if (!deleted.succeeded())
    {
        report["error"] = "tc refused the delete (status " + std::to_string(deleted.status) + ")";
        return report;
    }

    const auto after = showQdisc(iface, run);
    report["qdisc_after"] = after.output;
    // The assertion faults.sh makes with a whole-tree diff, made here on the one interface this
    // call touched: a restore that leaves netem behind is not a restore, and saying "ok" then
    // would be the injection tool lying about its own cleanup.
    if (findExistingNetem(after.output).safe)
    {
        report["error"] = "netem is still attached after the delete";
        return report;
    }
    report["ok"] = true;
    return report;
}

} // namespace netem
} // namespace utils
