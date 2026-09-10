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

#include <algorithm>
#include <cstdint>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "utils/InjectedNetemLedger.hpp"
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
 * @brief Every interface carrying a netem qdisc in a WHOLE-MACHINE `tc qdisc show`, in tree order.
 *
 * [Co-developed with claude code -- Adam]
 * E-20 (Adam, 2026-09-07). @p tree is the output of the bare, no-`dev` form, which prints one line
 * per qdisc with the interface named in it:
 *
 *     qdisc htb 5: dev s1-eth1 root refcnt 2 r2q 10 default 0x1 ...
 *     qdisc netem 10: dev s1-eth1 parent 5:1 limit 1000 loss 100%
 *
 * That extra `dev <name>` is why this cannot reuse findExistingNetem(), which parses the per-device
 * form where those two words are absent (`w[3]` is `root`/`parent` there and the device name here).
 *
 * @note Returns the names verbatim, INCLUDING ones outside the `s<N>-eth<M>` shape: deciding that
 *       `docker0` is not this fabric's business belongs to the caller that knows what the fabric
 *       is, not to a parser. Deduplicated, because an interface may carry more than one netem.
 */
inline std::vector<std::string>
netemInterfacesInTree(const std::string& tree)
{
    std::vector<std::string> ifaces;
    for (const auto& line : qdiscLines(tree))
    {
        const auto w = splitWords(line);
        if (w.size() < 5 || w[0] != "qdisc" || w[1] != "netem")
        {
            continue;
        }
        for (std::size_t i = 2; i + 1 < w.size(); ++i)
        {
            if (w[i] != "dev")
            {
                continue;
            }
            const std::string& name = w[i + 1];
            if (std::find(ifaces.begin(), ifaces.end(), name) == ifaces.end())
            {
                ifaces.push_back(name);
            }
            break;
        }
    }
    return ifaces;
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

/**
 * @brief The tc handle of the netem on this interface, e.g. `801d:`, or empty when there is none.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md B-16. The handle is the only thing on a qdisc that can identify it: `netem
 * loss 100%` attached by faults.sh, by the chaos harness and by this kernel are the same three
 * words, and tc records no owner. So provenance is "the kernel wrote down a handle and this is
 * still that handle" -- see utils::netem::InjectedNetemLedger.
 *
 * @param tree output of `tc qdisc show dev <iface>` -- but `w[2]` is the handle in the
 *        whole-machine form as well (`qdisc netem 10: dev s1-eth1 parent 5:1 ...`), so this reads
 *        either. It is the words AFTER that which differ, which is why findExistingNetem and
 *        netemInterfacesInTree cannot be one function.
 */
inline std::string
netemHandleInTree(const std::string& tree)
{
    for (const auto& line : qdiscLines(tree))
    {
        const auto w = splitWords(line);
        if (w.size() >= 3 && w[0] == "qdisc" && w[1] == "netem")
        {
            return w[2];
        }
    }
    return {};
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

/**
 * @brief The tc the startup sweep runs: the same binary, **without sudo**.
 *
 * [Co-developed with claude code -- Adam]
 * E-20. Reading the qdisc tree needs no privilege at all -- `tools/test_workflow/qdisc_snapshot.sh`
 * has taken whole-machine snapshots with a bare `tc qdisc show` since 2026-08-13 -- and going
 * through sudo here would be worse than pointless:
 *
 *   🔴 the NOPASSWD grants on this machine cover `tc qdisc show dev s[0-9]*-eth[0-9]*`. The bare,
 *      no-`dev` form the sweep needs is NOT one of them, so `sudo -n` would refuse it, and a
 *      refusal with stderr dropped is indistinguishable from "no netem anywhere". That exact
 *      misread scored a live measurement INVALID on 2026-08-21 while the injector was printing
 *      "netem verified present" -- see doc/audit/2026-08-21_p4-beacon-sweep/beacon_sweep.sh:89.
 *
 * A `tc` that cannot be reached at all surfaces as a non-zero status, which the sweep reports as
 * "could not read" rather than as a clean fabric. That is the whole point of the distinction:
 * this runner is allowed to fail, it is not allowed to look clean while failing.
 *
 * @warning Read-only by construction is NOT enforced here -- it is enforced by the caller, which
 *          only ever issues `qdisc show`. Without sudo an add/del would simply fail, but a sweep
 *          that tried is already the wrong sweep. See TopologyAndFlowMonitor::warnAboutResidualNetem.
 */
inline TcRunner
readOnlyTcRunner()
{
    return [](const std::vector<std::string>& args) {
        std::vector<std::string> argv{"tc"};
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

/// `tc qdisc show` for the WHOLE machine: every interface in this network namespace, one call.
/// The form netemInterfacesInTree() parses. E-20.
inline TcOutcome
showAllQdiscs(const TcRunner& run)
{
    return run({"qdisc", "show"});
}

/**
 * @brief Whether the netem on an interface is one THIS kernel attached.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md B-16. `findExistingNetem` answers "is there a netem here, and where", which
 * is what a delete needs to know and is not the question `/ndt/inject_link_recovery` was asking.
 * Measured 2026-09-11 (ROLE-1, 3 of 3): the same tree read was taken as permission, and the
 * endpoint deleted the previous operator's `netem loss 100%` and answered 200 `ok:true`.
 */
enum class NetemProvenance
{
    None,       ///< Nothing is attached. There is nothing to undo, and that is a success.
    Ours,       ///< A netem is attached and the ledger still names this exact handle.
    Foreign,    ///< A netem is attached that this kernel cannot claim. Not its to delete.
    Unreadable  ///< The tree could not be read, or the name is not one tc may be run against.
};

/// One read of one interface's qdisc tree, and everything it established. B-16.
struct NetemSighting
{
    NetemProvenance provenance = NetemProvenance::Unreadable;

    /// The `tc qdisc show dev <iface>` output the three fields below were read from. Reported as
    /// `qdisc_before`, so the caller sees the same bytes the decision was made on.
    std::string tree;

    /// The netem's handle when one is attached, e.g. `801d:`.
    std::string handle;

    /// Where it is attached, for the delete. `safe` is false when nothing is attached AND when
    /// something is attached whose attach point the tree does not name.
    AttachPoint at;

    /// Why this is not Ours, or why nothing could be read. Goes into the reply body: a caller who
    /// is refused cannot act on "refused".
    std::string why;
};

/**
 * @brief Reads @p iface once and says whether the netem on it is this kernel's. B-16.
 *
 * ONE read, and the caller passes the result to whatever it then decides to do -- rather than each
 * step re-reading. Two reads would leave a window in which the qdisc that gets deleted is not the
 * one whose provenance was checked, which is the defect again with a smaller mouth.
 */
inline NetemSighting
inspectNetem(const std::string& iface, const InjectedNetemLedger& ledger, const TcRunner& run)
{
    NetemSighting seen;
    if (!isMininetInterfaceName(iface))
    {
        seen.why = "interface name '" + iface + "' is not of the form s<N>-eth<M>";
        return seen;
    }

    const auto before = showQdisc(iface, run);
    if (!before.succeeded())
    {
        seen.why = "could not read the qdisc tree (tc qdisc show returned " +
                   std::to_string(before.status) +
                   "); on this machine that usually means sudo -n was refused";
        return seen;
    }
    seen.tree = before.output;
    seen.handle = netemHandleInTree(before.output);
    seen.at = findExistingNetem(before.output);

    if (seen.handle.empty())
    {
        seen.provenance = NetemProvenance::None;
        seen.why = "no netem qdisc is attached to this interface";
        return seen;
    }

    const auto recorded = ledger.find(iface);
    if (recorded && recorded->handle == seen.handle && seen.at.safe)
    {
        seen.provenance = NetemProvenance::Ours;
        seen.why = "attached by this kernel at " + utils::formatTime(recorded->attachedAtMs) +
                   " (" + recorded->handle + " at " + recorded->attachPoint + ")";
        return seen;
    }

    // Everything else present is Foreign, INCLUDING a netem whose attach point the tree does not
    // name: a delete at a guessed parent is how the 2026-08-13 shaping was lost.
    seen.provenance = NetemProvenance::Foreign;
    if (recorded)
    {
        seen.why = "this kernel attached " + recorded->handle + " to " + iface + " at " +
                   utils::formatTime(recorded->attachedAtMs) + ", but the netem there now is " +
                   seen.handle + " -- somebody replaced it, so it is not this kernel's to remove";
    }
    else
    {
        seen.why = "this kernel did not attach the netem on " + iface + " (" + seen.handle +
                   "); no injection through /ndt/inject_link_failure recorded it";
    }
    return seen;
}

/**
 * @brief Deletes the netem @p seen found, at the attach point @p seen read, and checks it is gone.
 *
 * Split out of restoreInterface so that the ownership-checked path can delete WITHOUT reading the
 * tree a second time, and so that both paths share one delete: two spellings of `tc qdisc del`
 * would be two places for the parent-versus-root rule to rot.
 */
inline nlohmann::json
detachSightedNetem(const std::string& iface, const NetemSighting& seen, const TcRunner& run)
{
    nlohmann::json report{{"interface", iface}, {"ok", false}, {"qdisc_before", seen.tree}};

    std::vector<std::string> args{"qdisc", "del", "dev", iface};
    args.insert(args.end(), seen.at.tcArgs.begin(), seen.at.tcArgs.end());

    const auto deleted = run(args);
    report["detached_at"] = utils::describeArgv(seen.at.tcArgs);
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

    // [Co-developed with claude code -- Adam] B-16. The delete itself moved into
    // detachSightedNetem so the ownership-checked path shares it. Same commands, same report,
    // same assertion -- and this function still deletes WHOSEVER netem is there, which is why
    // nothing in the kernel calls it any more. See restoreSightedNetem.
    NetemSighting seen;
    seen.tree = before.output;
    seen.at = at;
    seen.handle = netemHandleInTree(before.output);
    seen.provenance = NetemProvenance::Foreign;
    return detachSightedNetem(iface, seen, run);
}

/**
 * @brief The recovery's per-end action: remove the netem if it is this kernel's, and only then.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md B-16, and the whole of the fix on one interface. @p seen must come from
 * inspectNetem against the same @p ledger, so that the qdisc whose provenance was checked is the
 * qdisc this deletes.
 *
 *   - `Ours`     -> delete it, and forget it: a ledger entry that outlives its qdisc would claim
 *                   the next netem to land on that interface.
 *   - `None`     -> `ok` with `noop`. The idempotency the API manual documents and the contract's
 *                   sixth link step checks: a caller must be able to bring a fabric back to health
 *                   without first knowing exactly what was done to it.
 *   - `Foreign`  -> `ok: false` with `refused`, and NO command. Refusing after having run the
 *                   delete would be the defect with better prose.
 *   - `Unreadable` -> `ok: false` with `error`. Not a refusal: this kernel has no opinion.
 */
inline nlohmann::json
restoreSightedNetem(const std::string& iface,
                    const NetemSighting& seen,
                    InjectedNetemLedger& ledger,
                    const TcRunner& run)
{
    switch (seen.provenance)
    {
        case NetemProvenance::Ours:
        {
            auto report = detachSightedNetem(iface, seen, run);
            if (report.value("ok", false))
            {
                ledger.forget(iface);
            }
            report["was"] = seen.why;
            return report;
        }
        case NetemProvenance::None:
        {
            ledger.forget(iface);
            return nlohmann::json{{"interface", iface},
                                  {"ok", true},
                                  {"qdisc_before", seen.tree},
                                  {"noop", seen.why}};
        }
        case NetemProvenance::Foreign:
        {
            return nlohmann::json{
                {"interface", iface},
                {"ok", false},
                {"qdisc_before", seen.tree},
                {"refused", seen.why + ". Nothing was deleted here: remove it yourself with 'sudo "
                                       "tc qdisc del dev " +
                                iface + " " + utils::describeArgv(seen.at.tcArgs) +
                                "' once you know whose experiment it belongs to"}};
        }
        case NetemProvenance::Unreadable:
            break;
    }
    return nlohmann::json{{"interface", iface}, {"ok", false}, {"error", seen.why}};
}

/**
 * @brief Cuts EVERY end of a link with `netem loss 100%`, or none of them.
 *
 * [Co-developed with claude code -- Adam]
 * doc/KNOWN-ISSUES.md B-16, second finding (ROLE-1 2026-09-11, 2 of 2). The loop this replaces
 * called cutInterface once per end and kept going: one end already carried somebody else's netem
 * and was refused, the other end was really cut, and the reply said `link failure injected`. Both
 * ends were `loss 100%` that time so the effect was still symmetric; had the standing netem been
 * a `delay`, the result would be the asymmetric link fault faults.txt L-2 exists to warn about --
 * it kills LLDP in one direction only and leaves the control plane's graph permanently lopsided.
 *
 * Two phases, and a rollback for what neither phase can rule out:
 *   1. every end is read and planned, and nothing is run. An end that cannot be cut stops the
 *      others, which is the check that costs nothing.
 *   2. the attaches happen through cutInterface, which re-reads and re-plans -- so a tree that
 *      changed between the phases is refused rather than acted on.
 *   3. an attach that fails after an earlier one succeeded rolls the earlier ones back, through
 *      restoreSightedNetem, so that even the rollback cannot delete a qdisc that is not ours.
 *
 * @return `{"attached": bool, "tc": [...one report per end, in order...], "why": "<first reason
 *         nothing was attached>"}`. `attached` is the ONLY thing a caller may read as "the wire
 *         was cut"; `tc` is per-end detail and `why` is absent when everything was attached.
 */
inline nlohmann::json
cutLinkEnds(const std::vector<std::string>& ifaces,
            const std::string& loss,
            InjectedNetemLedger& ledger,
            const TcRunner& run)
{
    struct End
    {
        std::string iface;
        bool plannable = false;
        nlohmann::json report;
    };

    std::vector<End> ends;
    std::string blocked;
    const auto blockedBy = [&blocked](const std::string& why) {
        if (blocked.empty()) blocked = why;
    };

    // --- phase 1: ask about every end, run nothing that changes anything -------------------
    for (const auto& iface : ifaces)
    {
        End end;
        end.iface = iface;
        if (iface.empty())
        {
            end.report = {{"interface", nullptr},
                          {"ok", false},
                          {"refused",
                           "the topology file gives this switch no bridge_name, so the twin "
                           "cannot name its interface"}};
            blockedBy("one of this link's switches has no bridge_name in the topology file");
            ends.push_back(end);
            continue;
        }
        if (!isMininetInterfaceName(iface))
        {
            end.report = {{"interface", iface},
                          {"ok", false},
                          {"refused",
                           "interface name '" + iface +
                               "' is not of the form s<N>-eth<M>; the twin will not run tc "
                               "against an interface it cannot have derived from a Mininet "
                               "bridge"}};
            blockedBy(iface + " is not of the form s<N>-eth<M>");
            ends.push_back(end);
            continue;
        }
        const auto before = showQdisc(iface, run);
        if (!before.succeeded())
        {
            end.report = {{"interface", iface},
                          {"ok", false},
                          {"error",
                           "could not read the qdisc tree (tc qdisc show returned " +
                               std::to_string(before.status) +
                               "); on this machine that usually means sudo -n was refused"}};
            blockedBy("the qdisc tree of " + iface + " could not be read");
            ends.push_back(end);
            continue;
        }
        const auto plan = planAttach(before.output);
        if (!plan.safe)
        {
            end.report = {{"interface", iface},
                          {"ok", false},
                          {"qdisc_before", before.output},
                          {"refused", plan.why}};
            blockedBy(iface + ": " + plan.why);
            ends.push_back(end);
            continue;
        }
        end.plannable = true;
        end.report = {{"interface", iface}, {"ok", false}, {"qdisc_before", before.output}};
        ends.push_back(end);
    }

    nlohmann::json out{{"attached", false}, {"tc", nlohmann::json::array()}};
    const auto finish = [&out, &ends, &blocked]() {
        for (const auto& end : ends)
        {
            out["tc"].push_back(end.report);
        }
        if (!blocked.empty()) out["why"] = blocked;
        return out;
    };

    if (!blocked.empty())
    {
        // Nothing ran, and the ends that COULD have been cut say why they were not: an end whose
        // report said nothing would read as a success to anyone scanning for `refused`.
        for (auto& end : ends)
        {
            if (!end.plannable) continue;
            end.report["refused"] = "the other end of this link could not be cut (" + blocked +
                                    "), and a link failure injected at one end only is a "
                                    "different, subtler fault (faults.txt L-2). Nothing was "
                                    "attached here either";
        }
        return finish();
    }

    // --- phase 2: attach, and roll back the moment one of them does not --------------------
    std::vector<std::string> attached;
    for (auto& end : ends)
    {
        end.report = cutInterface(end.iface, loss, run);
        if (!end.report.value("ok", false))
        {
            blockedBy(end.iface + ": " + (end.report.contains("refused")
                                              ? end.report.value("refused", std::string())
                                              : end.report.value("error", std::string())));
            break;
        }
        ledger.record(end.iface,
                      netemHandleInTree(end.report.value("qdisc_after", std::string())),
                      end.report.value("attached_at", std::string()));
        attached.push_back(end.iface);
    }

    if (blocked.empty())
    {
        out["attached"] = true;
        return finish();
    }

    // --- phase 3: the rollback, and a reason for every end --------------------------------
    // An end phase 2 never reached (the loop breaks at the first failure) still carries its
    // phase-1 report, which says `ok: false` and nothing else. Silence there reads as a cut that
    // simply did not happen, so it gets the same sentence the phase-1 refusals get.
    for (auto& end : ends)
    {
        if (end.report.value("ok", false)) continue;
        if (end.report.contains("refused") || end.report.contains("error")) continue;
        end.report["refused"] = "nothing was attached to this end: the cut stopped at " + blocked +
                                ", and this endpoint cuts both ends or neither";
    }

    for (const auto& iface : attached)
    {
        const auto seen = inspectNetem(iface, ledger, run);
        const auto undone = restoreSightedNetem(iface, seen, ledger, run);
        for (auto& end : ends)
        {
            if (end.iface != iface) continue;
            end.report["ok"] = false;
            end.report["rolled_back"] = undone;
            end.report["refused"] = "attached, then removed again: the other end could not be cut "
                                    "(" + blocked + "), and this endpoint cuts both ends or "
                                    "neither";
        }
    }
    return finish();
}

} // namespace netem
} // namespace utils
