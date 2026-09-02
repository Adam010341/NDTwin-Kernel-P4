"""
T-11-A wiring guard: the phantom filter must stay CONNECTED, not merely present.

[Co-developed with claude code -- Adam]

## Why this file exists

`91e7743` ("Serve only the flow entries that were actually programmed") fixed KNOWN-ISSUES
B-1 by filtering unconfirmed rows out of the flow-table view. It shipped
`tests/test_PendingEntryFilter.cpp`, eight gtest cases, and those are good tests -- but they
include exactly two headers:

    #include "ndt_core/routing_management/DispatchOutcomeLog.hpp"
    #include "ndt_core/routing_management/PendingEntryFilter.hpp"

They call the pure function `stripUnprogrammedEntries()` directly. They never construct
`DeviceConfigurationAndPowerManager`, never call `getOpenFlowTables()`, and never go near
`HttpSession`. So they verify that the RULE is written correctly and say nothing about
whether the rule RUNS.

The fix has three wiring points. Cut any of them and all eight gtest cases stay green:

    W1  DeviceConfigurationAndPowerManager::getOpenFlowTables() calls the filter.
        Cut it -> the phantom returns in full, to all three cache consumers.

    W2  main.cpp injects the confirmation predicate.
        Cut it -> the predicate is empty. That default withholds every tokened row
        (deliberately conservative), so the failure is a view that under-reports for one
        poll interval rather than a phantom -- still wrong, and still silent.

    W3  HttpSession stamps the token onto the rows it hands the cache.
        Cut it -> rows arrive untokened, the filter reads them as polled-from-the-switch
        entries and must not touch them, and the phantom returns in full.

The only thing that ever exercised the wiring was the live acceptance
(`doc/audit/2026-08-31_live-acceptance-batch/`), which needs a fabric and therefore cannot
run in CI. This file is the CI-runnable half: it does not re-test the filter's logic, it
asserts the three joints are still joined.

## What this file is NOT

A source-text guard is a weak instrument and is labelled as one. It proves the call is
written, not that it executes; a behavioural test of W1-W3 needs the C++ suite to construct
the power manager, which is why the filter was extracted in the first place. Treat this as a
tripwire against silent disconnection during refactors, not as evidence the filter works --
that evidence is `tests/test_PendingEntryFilter.cpp` plus the live batch.

Related: memory `existence-is-not-wiring`.

## Standard library only

Everything in tests/python runs under plain `python3` and may depend on nothing outside the
standard library; l1_unit_tests.sh enforces that.
"""

from __future__ import annotations

import os
import re
import unittest


def _repo_root() -> str:
    """Walk up from this file until the directory holding src/main.cpp is found."""
    here = os.path.dirname(os.path.abspath(__file__))
    while True:
        if os.path.isfile(os.path.join(here, "src", "main.cpp")):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            raise AssertionError("repo root not found: no ancestor contains src/main.cpp")
        here = parent


ROOT = _repo_root()

DEVICE_MANAGER = os.path.join(
    ROOT, "src", "ndt_core", "power_management", "DeviceConfigurationAndPowerManager.cpp"
)
MAIN_CPP = os.path.join(ROOT, "src", "main.cpp")
HTTP_SESSION = os.path.join(ROOT, "src", "ndt_core", "http", "HttpSession.cpp")


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _function_body(source: str, signature: str, path: str) -> str:
    """Return the text of the function whose definition line is `signature`.

    This repo puts both the opening and the closing brace of a free-standing definition in
    column 0, so the body runs from the signature to the next line that is exactly "}".
    Scoping the search this way matters: a repo-wide substring search would still pass if
    the call were moved into a function nobody calls.
    """
    start = source.find(signature)
    if start == -1:
        raise AssertionError(
            "{}: definition {!r} not found. If it was renamed, this guard must be "
            "updated deliberately -- do not delete it.".format(path, signature)
        )
    end = source.find("\n}\n", start)
    if end == -1:
        raise AssertionError(
            "{}: could not find the end of {!r}".format(path, signature)
        )
    return source[start:end]


class FilterIsWiredIntoTheReadPath(unittest.TestCase):
    """W1: the one common read exit applies the filter."""

    def test_get_openflow_tables_calls_the_filter(self):
        body = _function_body(
            _read(DEVICE_MANAGER),
            "DeviceConfigurationAndPowerManager::getOpenFlowTables()",
            DEVICE_MANAGER,
        )
        self.assertIn(
            "stripUnprogrammedEntries(",
            body,
            msg=(
                "getOpenFlowTables() no longer calls stripUnprogrammedEntries(). This is the "
                "single read exit shared by /ndt/get_switch_openflow_table_entries, "
                "LLMAgent::getCurrentFlowEntries() and IntentTranslator -- without this call "
                "every one of them serves KNOWN-ISSUES B-1's phantom again. The eight cases in "
                "tests/test_PendingEntryFilter.cpp cannot see this: they call the filter "
                "directly and stay green."
            ),
        )

    def test_the_filter_is_applied_to_the_copy_that_is_returned(self):
        """Filtering a different object than the one returned would be a silent no-op."""
        body = _function_body(
            _read(DEVICE_MANAGER),
            "DeviceConfigurationAndPowerManager::getOpenFlowTables()",
            DEVICE_MANAGER,
        )
        match = re.search(r"stripUnprogrammedEntries\(\s*([A-Za-z_][A-Za-z0-9_]*)", body)
        self.assertIsNotNone(
            match, msg="stripUnprogrammedEntries() is not called with a named variable"
        )
        filtered = match.group(1)
        self.assertRegex(
            body,
            r"return\s+" + re.escape(filtered) + r"\s*;",
            msg=(
                "getOpenFlowTables() filters {0!r} but does not return it. Filtering an object "
                "that is then discarded restores the phantom while looking, in a diff, exactly "
                "like a working filter.".format(filtered)
            ),
        )


class ConfirmationPredicateIsInjected(unittest.TestCase):
    """W2: the predicate that answers 'was this token programmed?' is actually supplied."""

    def test_main_wires_the_programmed_predicate(self):
        # assertTrue on a boolean, not assertIn on the file: assertIn renders the whole
        # haystack into the failure message, which for a 500-line source file buries the
        # explanation under the thing it is explaining.
        self.assertTrue(
            "setProgrammedPredicate(" in _read(MAIN_CPP),
            msg=(
                "src/main.cpp no longer calls setProgrammedPredicate(). The predicate then "
                "stays empty, and PendingEntryFilter's documented default withholds EVERY "
                "tokened row -- so the flow-table view silently under-reports for up to one "
                "poll interval. That default is the safe direction on purpose, which is "
                "precisely why a dropped wire here is invisible without this assertion."
            ),
        )


class TokensReachTheCache(unittest.TestCase):
    """W3: rows written optimistically carry the token the filter keys on."""

    def test_http_session_stamps_a_token_on_the_cached_rows(self):
        self.assertTrue(
            "kPendingTokenField" in _read(HTTP_SESSION),
            msg=(
                "HttpSession.cpp no longer stamps kPendingTokenField. Untokened rows are "
                "treated by the filter as entries polled from a real switch -- which it must "
                "not hide -- so the optimistic row is served again and B-1's phantom is back."
            ),
        )

    def test_the_cache_is_handed_the_annotated_batch_not_the_raw_body(self):
        """The pre-fix line was `updateOpenFlowTables(j)` -- the raw request body."""
        source = _read(HTTP_SESSION)
        calls = re.findall(r"updateOpenFlowTables\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", source)
        self.assertTrue(
            calls, msg="no call to updateOpenFlowTables() found in HttpSession.cpp"
        )
        for argument in calls:
            self.assertNotEqual(
                argument,
                "j",
                msg=(
                    "HttpSession passes the raw request body `j` to updateOpenFlowTables(). "
                    "That is the pre-T-11 line: the untokened rows it writes are "
                    "indistinguishable to the filter from rows polled off a real switch, so "
                    "they are served as table entries. Hand it the tokened copy instead."
                ),
            )


if __name__ == "__main__":
    unittest.main()
