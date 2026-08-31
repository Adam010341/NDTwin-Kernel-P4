#!/usr/bin/env python3
"""Verdict for one gtest run. Reads rc FIRST, then demands a summary line, then names.

States: BUILD-FAIL | CRASH-RED | NO-SUMMARY | SKIP | SURVIVED | KILLED
SKIP and NO-SUMMARY and CRASH-RED are all distinct from GREEN and from a pass count.
"""
import re, sys, json

SUMMARY = re.compile(r"^\[=+\]\s+(\d+) tests? from (\d+) test suites? ran\.")
PASSED = re.compile(r"^\[\s+PASSED\s+\]\s+(\d+) tests?\.")
FAILED_NAME = re.compile(r"^\[\s+FAILED\s+\]\s+([A-Za-z0-9_]+\.[A-Za-z0-9_/]+)")
CONTROL = "P4PowerStrategyTest.PowerOnOnAnAlreadyUpSwitchRunsNothing"


def main():
    mid, build_rc, test_rc, logpath, predicted_csv = sys.argv[1:6]
    build_rc, test_rc = int(build_rc), int(test_rc)
    predicted = [p for p in predicted_csv.split(",") if p]
    try:
        with open(logpath, "r", errors="replace") as fh:
            out = fh.read()
    except OSError:
        out = ""
    lines = out.splitlines()

    ran = suites = passed = None
    for ln in lines:
        m = SUMMARY.match(ln)
        if m:
            ran, suites = int(m.group(1)), int(m.group(2))
        m = PASSED.match(ln)
        if m:
            passed = int(m.group(1))
    failed = sorted({m.group(1) for ln in lines for m in [FAILED_NAME.match(ln)] if m})

    if build_rc != 0:
        state = "BUILD-FAIL"
    elif test_rc >= 128 or test_rc < 0:
        state = "CRASH-RED"          # killed by a signal; not GREEN, not merely RED
    elif ran is None:
        state = "NO-SUMMARY"         # summary absent => may never be called GREEN
    elif not failed and test_rc == 0:
        state = "SURVIVED"           # mutation reddened nothing == a finding
    elif failed:
        state = "KILLED"
    else:
        state = "NO-SUMMARY"         # nonzero rc with no named failures: unclassifiable

    missing = [t for t in predicted if t not in failed]
    extra = [t for t in failed if t not in predicted]
    control_red = CONTROL in failed
    control_seen = (CONTROL in out)

    print(json.dumps({
        "id": mid, "state": state, "build_rc": build_rc, "test_rc": test_rc,
        "ran": ran, "suites": suites, "passed": passed,
        "failed": failed, "predicted": predicted,
        "predicted_but_green": missing, "red_but_unpredicted": extra,
        "control_red": control_red, "control_present_in_output": control_seen,
        "match": (state == "KILLED" and not missing),
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
