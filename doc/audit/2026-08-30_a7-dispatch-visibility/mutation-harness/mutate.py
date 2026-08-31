#!/usr/bin/env python3
"""Apply one mutation, build, run the two suites, restore, verify restoration.

[Co-developed with claude code -- Adam]

Guards its own baseline: refuses to start if the target file is not byte-identical to the
saved pristine copy, and verifies restoration after every run. An interrupted mutation run
that leaves a mutant behind is the failure mode this is written against
(memory: mutation-harness-must-guard-its-baseline).

This is the harness that produced the A-7 (M1-M12/C1) and T-11-A (T1-T5/C1) tables in
../FINDINGS.md and ../T-11_programmed-only-table-view.md. Read ../FINDINGS.md "the mutation
harness reported the most severe outcome as a survival" before trusting a verdict from it:
two defects in this file were found *by* the pre-registered predictions, not by review, and
a third mutation silently matched zero times. The fixes are already in this copy --
the verdict now reads the process return code first (CRASH-RED / NO-SUMMARY / RED-rc /
GREEN-with-count) instead of grepping only for a gtest summary line, which a SIGSEGV never
prints. A SKIP is still not a pass; it is printed as SKIP on purpose.

Baselines are NOT stored here -- see pristine-SHA256.txt for the hashes and the exact
`git show 91e7743:...` commands that regenerate them beside this script.
"""
import hashlib
import re
import shutil
import subprocess
import sys
import os

ROOT = "/home/adam/Desktop/NDTwin-Kernel"
SCRATCH = os.path.dirname(os.path.abspath(__file__))
HDR = "include/ndt_core/routing_management/DispatchOutcomeLog.hpp"
CTL = "src/ndt_core/routing_management/Controller.cpp"
PEF = "include/ndt_core/routing_management/PendingEntryFilter.hpp"
FILTER = ("DispatchOutcomeLogTest.*:ControllerTest.*:"
          "PendingEntryFilterTest.*:ProgrammedTokenTest.*")

# id -> (file, old, new, what we predict goes red)
MUTATIONS = {
    "M1": (HDR,
           "        failed_.fetch_add(1, std::memory_order_relaxed);\n",
           "        failed_.fetch_add(1, std::memory_order_relaxed);\n        return;\n",
           "failures never stored"),
    "M2": (HDR,
           "        if (result.ok)\n        {\n            succeeded_.fetch_add(1, std::memory_order_relaxed);\n            return;\n        }\n\n        failed_.fetch_add(1, std::memory_order_relaxed);\n",
           "        if (result.ok)\n        {\n            succeeded_.fetch_add(1, std::memory_order_relaxed);\n        }\n        else\n        {\n            failed_.fetch_add(1, std::memory_order_relaxed);\n        }\n",
           "ring stores every outcome, not just failures"),
    "M3": (HDR,
           "            evicted_.fetch_add(1, std::memory_order_relaxed);\n",
           "",
           "eviction happens silently"),
    "M4": (HDR,
           "            failures_.pop_front();\n",
           "            failures_.pop_back();\n",
           "newest evicted instead of oldest"),
    "M7": (HDR,
           "    : capacity_(capacity == 0 ? 1 : capacity)\n",
           "    : capacity_(capacity)\n",
           "zero capacity discards everything"),
    "M8": (HDR,
           "        const uint64_t seq = dispatched_.fetch_add(1, std::memory_order_relaxed) + 1;\n",
           "        dispatched_.fetch_add(1, std::memory_order_relaxed);\n        const uint64_t seq = failed_.load(std::memory_order_relaxed) + 1;\n",
           "seq counts failures, so gaps vanish"),
    "M9": (HDR,
           "        case FlowOp::Modify:\n            return \"modify\";\n",
           "        case FlowOp::Modify:\n            return \"install\";\n",
           "modify mislabelled"),
    "M11": (CTL,
            "                  outcomes_.record(job, result);\n",
            "",
            "THE WIRING MUTATION -- record() never called"),
    "M12": (CTL,
            "                  outcomes_.record(job, result);\n\n                  if (!result.ok)\n",
            "                  if (!result.ok)\n                      outcomes_.record(job, result);\n                  if (!result.ok)\n",
            "only failures recorded (success path unwired)"),
    # --- T-11 ---
    "T1": (PEF,
           "                    ++withheld;\n                    continue;\n",
           "                    ++withheld;\n",
           "THE PHANTOM MUTATION -- filter never withholds anything"),
    "T2": (PEF,
           "                if (token != 0 && !(isProgrammed && isProgrammed(token)))\n",
           "                if (!(isProgrammed && isProgrammed(token)))\n",
           "untokened (polled) rows also withheld -- empties the whole view"),
    "T3": (PEF,
           "                    entry.erase(kPendingTokenField);\n",
           "",
           "internal stamp leaks to consumers"),
    "T4": (HDR,
           "        return programmed_.count(token) != 0;\n",
           "        return true;\n",
           "isProgrammed always true -- filter is a no-op"),
    "T5": (HDR,
           "        failed_.fetch_add(1, std::memory_order_relaxed);\n",
           "        failed_.fetch_add(1, std::memory_order_relaxed);\n        noteProgrammed_(job.token);\n",
           "a refused rule confirms its own token"),
    "C1": (HDR,
           "    explicit DispatchOutcomeLog(std::size_t capacity = 256)",
           "    explicit DispatchOutcomeLog(std::size_t capacity = 512)",
           "GREEN CONTROL -- all 20 must stay green"),
}


def sha(p):
    return hashlib.sha256(open(os.path.join(ROOT, p), "rb").read()).hexdigest()


def pristine_path(p):
    return os.path.join(SCRATCH, "pristine_" + os.path.basename(p))


def main():
    os.chdir(ROOT)
    for f in (HDR, CTL, PEF):
        pp = pristine_path(f)
        if not os.path.exists(pp):
            shutil.copy(f, pp)

    # Baseline guard.
    for f in (HDR, CTL, PEF):
        if open(f, "rb").read() != open(pristine_path(f), "rb").read():
            print(f"REFUSING TO START: {f} differs from pristine copy -- a previous run left a mutant")
            return 2

    results = []
    for mid in sys.argv[1:] or MUTATIONS.keys():
        f, old, new, why = MUTATIONS[mid]
        src = open(f).read()
        n = src.count(old)
        if n != 1:
            results.append((mid, "SKIP", f"pattern matched {n} times", why))
            continue
        open(f, "w").write(src.replace(old, new))

        build = subprocess.run(["cmake", "--build", "build", "--target",
                                "test_routing_strategy", "-j4"],
                               capture_output=True, text=True, timeout=900)
        if build.returncode != 0:
            errs = [l for l in build.stdout.splitlines() + build.stderr.splitlines()
                    if "error" in l.lower()]
            results.append((mid, "BUILD-FAIL", errs[0][:90] if errs else "?", why))
        else:
            run = subprocess.run(["./build/bin/test_routing_strategy",
                                  f"--gtest_filter={FILTER}"],
                                 capture_output=True, text=True, timeout=900)
            failed = sorted(set(re.findall(r"^\[  FAILED  \] (\S+)$", run.stdout, re.M)))
            ran = re.search(r"^\[==========\] (\d+) tests? from .* ran\.", run.stdout, re.M)
            # The return code is the gate, not the summary block. A mutant that SEGVs the binary
            # prints no summary at all, so keying on "no FAILED lines" reports the most severe
            # outcome as a survival -- observed, M1, first run of this harness.
            if run.returncode < 0:
                verdict = "CRASH-RED"
                detail = f"killed by signal {-run.returncode} after {ran.group(1) if ran else '?'} tests"
            elif not ran:
                verdict = "NO-SUMMARY"
                detail = f"rc={run.returncode}, suite did not finish -- inspect by hand"
            elif failed:
                verdict = "RED"
                detail = ", ".join(t.split(".")[-1] for t in failed)
            elif run.returncode != 0:
                verdict = "RED-rc"
                detail = f"rc={run.returncode} with no FAILED lines"
            else:
                verdict = "GREEN"
                detail = f"all {ran.group(1)} green"
            results.append((mid, verdict, detail, why))

        shutil.copy(pristine_path(f), f)
        assert open(f, "rb").read() == open(pristine_path(f), "rb").read(), f"restore failed for {f}"

    print("\n=== MUTATION RESULTS ===")
    for mid, verdict, detail, why in results:
        print(f"{mid:5s} {verdict:10s} {why}")
        print(f"      -> {detail}")

    # Final restoration proof.
    print("\n=== restoration check ===")
    for f in (HDR, CTL, PEF):
        same = open(f, "rb").read() == open(pristine_path(f), "rb").read()
        print(f"{'OK  ' if same else 'DIRTY'} {f}  sha={sha(f)[:12]}")
    return 0


sys.exit(main())
