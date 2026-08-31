#!/usr/bin/env python3
"""Mutation table + applier for the behavior fix bundle (11_behavior-evidence.md S4).

Two subcommands:
  apply <ID>   exact-text replace; exits 2 if any anchor is not found EXACTLY ONCE.
  assert <ID>  re-read from disk: every marker must be present, every anchor gone.

`apply` never edits a file unless every anchor for that mutation resolved uniquely,
so a partial mutation cannot reach the compiler.
"""
import sys, os, tempfile

W = "/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a2c2a6601f812a7eb"


def atomic_write(path, text):
    """Never truncate the real file. The root filesystem is oscillating at 100% and another
    agent's plain `cp` already produced a 0-byte file under it; a short write must land on a
    throwaway temp, not on a source file the fix lives in."""
    data = text.encode("utf-8")
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".mut_tmp_")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        got = os.path.getsize(tmp)
        if got != len(data):
            raise IOError("short write: %d bytes on disk, %d expected" % (got, len(data)))
        os.replace(tmp, path)          # atomic within one filesystem
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

PWR_CPP = "src/ndt_core/power_management/P4PowerStrategy.cpp"
RTG_CPP = "src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp"
P4R_HPP = "include/ndt_core/routing_management/P4RoutingStrategy.hpp"
TOP_CPP = "src/ndt_core/collection/TopologyAndFlowMonitor.cpp"
TOP_HPP = "include/ndt_core/collection/TopologyAndFlowMonitor.hpp"

# id -> (description, [(file, old, new), ...], [predicted red test ids])
MUT = {}

MUT["M1"] = (
    "Restore the old guard: drop `&& !poweredOffWithinDistrustWindow(swName)`",
    [(PWR_CPP,
      "    if (topoMonitor->getVertexIsUp(node) && !poweredOffWithinDistrustWindow(swName))\n",
      "    if (topoMonitor->getVertexIsUp(node)) // MUTANT_M1\n")],
    ["P4PowerStrategyTest.PowerOnActsWhenTheGraphSaysUpButThisStrategyJustStoppedTheSwitch"],
)

MUT["M2"] = (
    "Make the window unbounded: poweredOffWithinDistrustWindow returns it != end()",
    [(PWR_CPP,
      "    return at - it->second < kPostPowerOffDistrustWindow;\n",
      "    (void)at; // MUTANT_M2\n    return it != m_lastPowerOffAt.end(); // MUTANT_M2\n")],
    ["P4PowerStrategyTest.PowerOnTrustsTheGraphAgainOnceTheDistrustWindowHasPassed"],
)

MUT["M3"] = (
    "Delete the clearPowerOffRecord(swName) call after helper-on",
    [(PWR_CPP,
      "    clearPowerOffRecord(swName);\n\n    // Step 2, the relationship.",
      "    // MUTANT_M3 deleted: clearPowerOffRecord(swName);\n\n    // Step 2, the relationship.")],
    ["P4PowerStrategyTest.ASuccessfulPowerOnClosesTheWindowSoAnImmediateRepeatIsStillANoOp"],
)

MUT["M4"] = (
    "Move notePowerOff(swName) above the helper-off failure return",
    [(PWR_CPP,
      "    notePowerOff(swName);\n    topoMonitor->setVertexDown(node);\n",
      "    // MUTANT_M4 moved away from here\n    topoMonitor->setVertexDown(node);\n"),
     (PWR_CPP,
      '    if (!executeSystemCommand(std::string("sudo -n ") + kPowerHelper + " off " + swName))\n',
      '    notePowerOff(swName); // MUTANT_M4 moved above the helper-off failure return\n'
      '    if (!executeSystemCommand(std::string("sudo -n ") + kPowerHelper + " off " + swName))\n')],
    ["P4PowerStrategyTest.AFailedPowerOffDoesNotOpenTheDistrustWindow"],
)

MUT["M5"] = (
    "Replace the per-switch map with one process-wide timestamp (ignore swName)",
    [(PWR_CPP,
      "    const auto it = m_lastPowerOffAt.find(swName);\n",
      '    const auto it = m_lastPowerOffAt.find(std::string("")); // MUTANT_M5 process-wide\n'),
     (PWR_CPP,
      "    m_lastPowerOffAt[swName] = at;\n",
      '    m_lastPowerOffAt[std::string("")] = at; // MUTANT_M5 process-wide\n'),
     (PWR_CPP,
      "    m_lastPowerOffAt.erase(swName);\n",
      '    m_lastPowerOffAt.erase(std::string("")); // MUTANT_M5 process-wide\n')],
    ["P4PowerStrategyTest.TheDistrustWindowIsPerSwitchNotFabricWide"],
)

MUT["M6"] = (
    'Post the literal "/stats/flowentry/modify" instead of strictModifyPath()',
    [(RTG_CPP,
      '    return post(strictModifyPath(), body, "modify flow entry (strict)");\n',
      '    return post("/stats/flowentry/modify", body, "modify flow entry (strict)"); // MUTANT_M6\n')],
    ["RoutingStrategyFixture.ModifyWithPriorityUsesTheStrictRouteSoItCanOnlyHitThatEntry",
     "RoutingStrategyFixture.ModifyAndDeleteAgreeOnWhatAPriorityMeans"],
)

MUT["M7"] = (
    "Delete the if (priority == -1) branch (always strict)",
    [(RTG_CPP,
      '    if (priority == -1)\n'
      '    {\n'
      '        return post("/stats/flowentry/modify", body, "modify flow entry (non-strict)");\n'
      '    }\n'
      '\n'
      '    body["priority"] = priority;\n',
      '    // MUTANT_M7 deleted the priority == -1 branch\n'
      '    body["priority"] = priority;\n')],
    ["RoutingStrategyFixture.ModifyWithoutAPriorityStaysOnTheNonStrictRoute"],
)

MUT["M8"] = (
    "Delete P4RoutingStrategy::strictModifyPath()",
    [(P4R_HPP,
      '    const char* strictModifyPath() const override { return "/stats/flowentry/modify"; }\n',
      '    // MUTANT_M8 deleted: strictModifyPath() override\n')],
    ["RoutingStrategyFixture.ModifyOnTheP4ProxyKeepsTheRouteTheProxyActuallyServes"],
)

MUT["M9"] = (
    'Set body["priority"] = priority; above the -1 branch',
    [(RTG_CPP,
      '\n    body["priority"] = priority;\n    return post(strictModifyPath(), body, "modify flow entry (strict)");\n',
      '\n    return post(strictModifyPath(), body, "modify flow entry (strict)"); // MUTANT_M9\n'),
     (RTG_CPP,
      '    json body;\n'
      '    body["dpid"] = dpid;\n'
      '    body["match"] = match;\n'
      '    body["actions"] = action;\n',
      '    json body;\n'
      '    body["dpid"] = dpid;\n'
      '    body["match"] = match;\n'
      '    body["actions"] = action;\n'
      '    body["priority"] = priority; // MUTANT_M9 hoisted above the -1 branch\n')],
    ["RoutingStrategyFixture.ModifyWithoutAPriorityStaysOnTheNonStrictRoute"],
)

MUT["M10"] = (
    "Drop --max-time from buildTopologyFetchCommand",
    [(TOP_CPP,
      '    return "curl -sS -X GET --connect-timeout " +\n'
      '           std::to_string(kTopologyConnectTimeoutSeconds) + " --max-time " +\n'
      '           std::to_string(kTopologyRequestTimeoutSeconds) + " " + url;\n',
      '    return "curl -sS -X GET --connect-timeout " + // MUTANT_M10 dropped --max-time\n'
      '           std::to_string(kTopologyConnectTimeoutSeconds) + " " + url;\n')],
    ["RequestDeadlines.TheTopologyPollIsBounded"],
)

MUT["M11"] = (
    "Drop --connect-timeout from buildTopologyFetchCommand",
    [(TOP_CPP,
      '    return "curl -sS -X GET --connect-timeout " +\n'
      '           std::to_string(kTopologyConnectTimeoutSeconds) + " --max-time " +\n'
      '           std::to_string(kTopologyRequestTimeoutSeconds) + " " + url;\n',
      '    return "curl -sS -X GET --max-time " + // MUTANT_M11 dropped --connect-timeout\n'
      '           std::to_string(kTopologyRequestTimeoutSeconds) + " " + url;\n')],
    ["RequestDeadlines.TheTopologyPollBoundsTheConnectAndNotJustTheTransfer"],
)

MUT["M12"] = (
    "Raise kTopologyRequestTimeoutSeconds to 15",
    [(TOP_HPP,
      "    static constexpr int kTopologyRequestTimeoutSeconds = 5;\n",
      "    static constexpr int kTopologyRequestTimeoutSeconds = 15; // MUTANT_M12\n")],
    ["RequestDeadlines.TheWholeTopologyPassFitsInsideItsOwnPollInterval"],
)

MUT["M13"] = (
    "-sS -> -s in buildTopologyFetchCommand",
    [(TOP_CPP,
      '    return "curl -sS -X GET --connect-timeout " +\n',
      '    return "curl -s -X GET --connect-timeout " + // MUTANT_M13\n')],
    ["RequestDeadlines.TheTopologyRequestKeepsCurlsOwnDiagnosisOnStderr"],
)

ORDER = ["M%d" % i for i in range(1, 14)]
CONTROL = "P4PowerStrategyTest.PowerOnOnAnAlreadyUpSwitchRunsNothing"


def files_of(mid):
    return sorted({f for f, _, _ in MUT[mid][1]})


def cmd_apply(mid):
    edits = MUT[mid][1]
    # Pass 1: resolve every anchor against the CURRENT on-disk text, in order,
    # against an in-memory copy. Nothing is written unless all of them are unique.
    bufs = {}
    for path, old, new in edits:
        full = os.path.join(W, path)
        if path not in bufs:
            with open(full, "r", encoding="utf-8") as fh:
                bufs[path] = fh.read()
        n = bufs[path].count(old)
        if n != 1:
            sys.stderr.write(
                "APPLY-FAIL %s: anchor occurs %d times (need exactly 1) in %s\n--- anchor ---\n%s\n"
                % (mid, n, path, old))
            return 2
        bufs[path] = bufs[path].replace(old, new, 1)
    for path, text in bufs.items():
        atomic_write(os.path.join(W, path), text)
    print("APPLY-OK %s -> %s" % (mid, ", ".join(sorted(bufs))))
    return 0


def cmd_assert(mid):
    """Independent re-read from disk. sed/replace silently succeeding on no match is
    the failure mode this guards; so is a restore that did not restore."""
    ok = True
    for path, old, new in MUT[mid][1]:
        with open(os.path.join(W, path), "r", encoding="utf-8") as fh:
            text = fh.read()
        if new not in text:
            sys.stderr.write("DISK-ASSERT-FAIL %s: replacement text absent from %s\n%s\n"
                             % (mid, path, new))
            ok = False
        # "the original must be gone" only makes sense for a REPLACEMENT. M4 and M9 are
        # insertions: they prepend/append around the anchor, so `new` legitimately CONTAINS
        # `old` and demanding its absence can never be satisfied. Asserting it anyway made M4
        # SKIP -- correctly refusing to score itself, but for a defect in this checker rather
        # than in the mutation. Skip the check exactly when the edit is an insertion.
        elif old not in new and old in text:
            sys.stderr.write("DISK-ASSERT-FAIL %s: original text STILL PRESENT in %s\n%s\n"
                             % (mid, path, old))
            ok = False
    if ok:
        print("DISK-ASSERT-OK %s" % mid)
        return 0
    return 3


def cmd_predicted(mid):
    for t in MUT[mid][2]:
        print(t)
    return 0


def cmd_desc(mid):
    print(MUT[mid][0])
    return 0


def cmd_files(mid):
    for f in files_of(mid):
        print(f)
    return 0


if __name__ == "__main__":
    sub, mid = sys.argv[1], sys.argv[2]
    if mid not in MUT:
        sys.stderr.write("unknown mutation %s\n" % mid)
        sys.exit(4)
    sys.exit({"apply": cmd_apply, "assert": cmd_assert, "predicted": cmd_predicted,
              "desc": cmd_desc, "files": cmd_files}[sub](mid))
