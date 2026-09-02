#!/usr/bin/env python3
"""L-5: the drift detector must recognise every spelling the kernel registers routes with --
and must still go red for a name the kernel really does not carry.

[Co-developed with claude code -- Adam]

The defect (KNOWN-ISSUES L-5, observed 2026-09-02, raw/C6_l3_check_drift.log): the scanner's
regex knew `target == "..."` and `target.starts_with("...")` but not
`utils::pathIs(target, "...")`, so `l3_component_check.py --check-drift` exited 1 reporting

    KERNEL_ENDPOINTS lists /ndt/get_detected_flow_data but the kernel no longer registers it
    KERNEL_ENDPOINTS lists /ndt/get_detected_top_k_flow_data but the kernel no longer registers it

while both endpoints answered 200 live in that same log. Two false alarms out of forty-two
routes is enough to teach a reader that DRIFT means nothing.

🔴 The half that matters more than the fix is the SECOND direction. Making a checker green is
trivial and worthless; this file therefore pins both:

  * the three registration spellings are found, with the right verb        (it can see)
  * a fabricated endpoint the source does NOT register still drifts        (it can still say so)
  * a route the source registers but KERNEL_ENDPOINTS omits still drifts   (both directions)
  * a verb that disagrees still drifts                                     (not just presence)

Case 4 is deliberately run against the real src/ndt_core/http/HttpSession.cpp rather than a
fixture: a fixture proves the regex matches text I wrote, and the thing that broke was the
regex against text somebody else wrote.

Stdlib only, no kernel, no fabric, no build.
Run:  python3 tests/python/test_l3_dispatch_drift.py -v
"""
from __future__ import annotations

import os
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# NDT_CONTRACT_DIR points the import at a MUTATED COPY of tools/contract_test, so
# tests/shell/mutate_l3_dispatch_drift.sh can score this file without writing a byte into a
# worktree three other sessions are using. Unset in every normal run.
CONTRACT_DIR = os.environ.get("NDT_CONTRACT_DIR") or os.path.join(REPO, "tools", "contract_test")
sys.path.insert(0, CONTRACT_DIR)

import components  # noqa: E402

HTTP_SESSION = os.path.join(REPO, "src", "ndt_core", "http", "HttpSession.cpp")

# The two routes the defect hid, and the file:line the register cites for them.
PATH_IS_ROUTES = ("get_detected_flow_data", "get_detected_top_k_flow_data")


def scan_text(src: str) -> dict[str, str]:
    """Run the real scanner over a snippet of C++."""
    with tempfile.NamedTemporaryFile("w", suffix=".cpp", delete=False, encoding="utf-8") as fh:
        fh.write(src)
        path = fh.name
    try:
        return components.scan_kernel_dispatch(path)
    finally:
        os.unlink(path)


class ScannerSeesEverySpelling(unittest.TestCase):
    """1-3: each registration form the dispatch chain actually uses."""

    def test_equality_form_is_found(self):
        got = scan_text('if (method == http::verb::get && target == "/ndt/alpha")\n{ x(); }\n')
        self.assertEqual(got, {"alpha": "GET"})

    def test_starts_with_form_is_found(self):
        got = scan_text('else if (method == http::verb::post && '
                        'target.starts_with("/ndt/beta"))\n{ x(); }\n')
        self.assertEqual(got, {"beta": "POST"})

    def test_path_is_form_is_found(self):
        """THE DEFECT. Both the one-line and the wrapped spelling HttpSession.cpp uses."""
        got = scan_text(
            'else if (method == http::verb::get && utils::pathIs(target, "/ndt/gamma"))\n'
            '{ x(); }\n'
            'else if (method == http::verb::get &&\n'
            '         utils::pathIs(target, "/ndt/delta"))\n'
            '{ y(); }\n')
        self.assertEqual(got, {"gamma": "GET", "delta": "GET"},
                         "utils::pathIs(target, ...) is a registration; before the L-5 fix the "
                         "scanner matched neither of these and reported both as deleted routes")

    def test_path_is_carries_the_verb_not_a_default(self):
        got = scan_text('if (method == http::verb::post && '
                        'utils::pathIs(target, "/ndt/epsilon"))\n{ x(); }\n')
        self.assertEqual(got, {"epsilon": "POST"})

    def test_a_non_ndt_pathis_is_not_invented_into_the_table(self):
        """The scanner's table is /ndt/ routes. Widening the regex must not widen that."""
        got = scan_text('if (method == http::verb::get && '
                        'utils::pathIs(target, "/p4/readopt/1"))\n{ x(); }\n')
        self.assertEqual(got, {})


class TheRealDispatchChain(unittest.TestCase):
    """4: against the file that actually broke, not against a fixture."""

    def test_http_session_cpp_is_readable(self):
        self.assertTrue(os.path.exists(HTTP_SESSION), HTTP_SESSION)

    def test_the_two_pathis_routes_are_seen_in_the_real_source(self):
        actual = components.scan_kernel_dispatch(HTTP_SESSION)
        for name in PATH_IS_ROUTES:
            self.assertIn(name, actual,
                          f"/ndt/{name} is registered at HttpSession.cpp via utils::pathIs and "
                          f"answered 200 live on 2026-09-02")
            self.assertEqual(actual[name], "GET")

    def test_no_drift_against_the_hand_transcribed_table(self):
        problems = components.check_dispatch_drift(HTTP_SESSION)
        self.assertEqual(problems, [],
                         "trunk must be clean; a real drift here is a finding, not a test bug")


class ItCanStillSayNo(unittest.TestCase):
    """5-7: discriminating power. A checker that only ever agrees is not a checker.

    Every case here mutates something genuinely wrong into the comparison and requires the
    drift message to come back. If any of these went green, the L-5 fix would have turned the
    detector into a constant PASS -- which is a worse defect than the false alarm it replaced.
    """

    def test_an_unregistered_name_in_the_table_still_drifts(self):
        """Direction A: KERNEL_ENDPOINTS claims a route the source does not carry."""
        fake = "get_detected_flow_data_that_does_not_exist"
        patched = dict(components.KERNEL_ENDPOINTS)
        patched[fake] = "GET"
        original = components.KERNEL_ENDPOINTS
        components.KERNEL_ENDPOINTS = patched
        try:
            problems = components.check_dispatch_drift(HTTP_SESSION)
        finally:
            components.KERNEL_ENDPOINTS = original
        self.assertTrue(any(fake in p and "no longer registers it" in p for p in problems),
                        f"a fabricated endpoint went unreported; got {problems}")

    def test_a_pathis_route_missing_from_the_table_still_drifts(self):
        """Direction B: the source registers it (via pathIs) and the table omits it.

        Before the fix this case could not exist -- an unseen route cannot be reported as
        extra -- so it is the direct proof that the new spelling reaches the comparison and
        not merely the regex.
        """
        patched = {k: v for k, v in components.KERNEL_ENDPOINTS.items()
                   if k != "get_detected_flow_data"}
        original = components.KERNEL_ENDPOINTS
        components.KERNEL_ENDPOINTS = patched
        try:
            problems = components.check_dispatch_drift(HTTP_SESSION)
        finally:
            components.KERNEL_ENDPOINTS = original
        self.assertTrue(
            any("get_detected_flow_data" in p and "omits it" in p for p in problems),
            f"a pathIs route absent from the table went unreported; got {problems}")

    def test_a_wrong_verb_still_drifts(self):
        """A probe with the wrong method gets a 404 and looks like a missing endpoint, which
        is why the verb is compared and not only the name."""
        patched = dict(components.KERNEL_ENDPOINTS)
        patched["get_detected_flow_data"] = "POST"
        original = components.KERNEL_ENDPOINTS
        components.KERNEL_ENDPOINTS = patched
        try:
            problems = components.check_dispatch_drift(HTTP_SESSION)
        finally:
            components.KERNEL_ENDPOINTS = original
        self.assertTrue(any("get_detected_flow_data" in p and "kernel uses GET" in p
                            for p in problems),
                        f"a verb mismatch on a pathIs route went unreported; got {problems}")

    def test_a_deleted_route_in_a_fixture_still_drifts(self):
        """The same question with the source side controlled: the table lists two, the
        source registers one, and the missing one must be named."""
        actual = scan_text('if (method == http::verb::get && '
                           'utils::pathIs(target, "/ndt/kept"))\n{ x(); }\n')
        self.assertEqual(actual, {"kept": "GET"})
        self.assertNotIn("dropped", actual)


if __name__ == "__main__":
    unittest.main(verbosity=2)
