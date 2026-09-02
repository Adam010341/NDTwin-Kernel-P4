#!/usr/bin/env python3
"""G-3: the chaos harness's `_c07` control must be able to come out BOTH ways.

[Co-developed with claude code -- Adam]

The defect (KNOWN-ISSUES G-3, confirmed live 2026-09-02, raw/C8_b3_historical_logging.log).
`_c07` was a positive control for B-3 -- "historical_logging answers enabled and writes zero
rows" -- built out of three ingredients, each fatal on its own:

  1. it called /ndt/set_historical_logging, /ndt/get_historical_data and
     /ndt/set_historical_logging_state; the kernel registers none of them, all three 404;
  2. `probes.api_get` discarded the status, so each 404 came back as None;
  3. the criterion was `rows == 0 => B-3 reproduced`, and None is zero rows.

So the control answered "reproduced" on a healthy kernel, on a defective one, and against no
kernel at all -- and `doc/audit/2026-08-28_chaos-harness/05_first-live-run.md:203` published a
claim resting on it.

🔴 THIS FILE IS ABOUT DISCRIMINATING POWER, NOT ABOUT GREEN. Repairing only the route would
leave the shape: a probe that discards status codes fabricates the same false pass the next
time a route moves. So both halves are pinned, and in both directions:

  * the routes the control names are checked against the kernel's REAL dispatch chain, and
    the three phantom names must not come back;
  * a 404 must produce a refusal, never a reproduction        (defect absent -> not "found")
  * a non-recording kernel must produce "reproduced"          (defect present -> found)
  * a recording kernel must produce "did NOT reproduce"       (the side the old code could
                                                               never reach)

Stdlib only. No kernel, no fabric: the one place probes.py shells out to curl is replaced.
Run:  python3 tests/python/test_chaos_c07_control.py -v
"""
from __future__ import annotations

import ast
import inspect
import json
import os
import re
import sys
import textwrap
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# NDT_CHAOS_HARNESS points the import at a MUTATED COPY of the harness, so
# tests/shell/mutate_chaos_c07_control.sh can score this file without writing into a worktree
# other sessions are using. Unset in every normal run.
HARNESS = os.environ.get("NDT_CHAOS_HARNESS") or os.path.join(
    REPO, "doc", "audit", "2026-08-28_chaos-harness", "harness")
sys.path.insert(0, HARNESS)
sys.path.insert(0, os.path.join(REPO, "tools", "contract_test"))

import actions  # noqa: E402
import components  # noqa: E402
import probes  # noqa: E402

HTTP_SESSION = os.path.join(REPO, "src", "ndt_core", "http", "HttpSession.cpp")

# The three names the control used to call. Named here so a revert is caught by name and not
# only by symptom.
PHANTOM_ROUTES = ("/ndt/set_historical_logging",
                  "/ndt/get_historical_data",
                  "/ndt/set_historical_logging_state")

CONTROL_FUNCS = ("_c07_apply", "_c07_verify", "_c07_undo")

NOT_RECORDING = {"status": "not_applicable", "recording": False,
                 "reason": "not-available-in-mininet-mode",
                 "message": "Historical data logging is enabled, but this deployment does not "
                            "record: the recorder is only started outside MININET mode, so no "
                            "rows will be written."}
RECORDING = {"status": "success", "recording": True, "reason": "recording",
             "message": "Historical data logging has been enabled."}


def control_strings() -> list[str]:
    """Every string literal `_c07` EXECUTES, plus the route constant it interpolates.

    Docstrings and comments are excluded on purpose: the retraction note in `_c07_verify`
    names the three phantom routes so the next reader knows what they were, and a grep over
    raw source would then read the explanation as the defect. What matters is which strings
    reach a request, so the check is on the AST rather than on the text.
    """
    out: list[str] = []
    for fname in CONTROL_FUNCS:
        fn = ast.parse(textwrap.dedent(inspect.getsource(getattr(actions, fname)))).body[0]
        docstrings = {id(n.value) for n in ast.walk(fn)
                      if isinstance(n, ast.Expr) and isinstance(n.value, ast.Constant)}
        for node in ast.walk(fn):
            if (isinstance(node, ast.Constant) and isinstance(node.value, str)
                    and id(node) not in docstrings):
                out.append(node.value)
    out.append(actions.HISTORICAL_LOGGING)
    return out


class FakeCurl:
    """Stands in for probes._curl. Records what was asked and answers from a script."""

    def __init__(self, status=200, body=None, rc=0, stderr=""):
        self.status, self.body, self.rc, self.stderr = status, body, rc, stderr
        self.calls: list[list[str]] = []
        self.stdins: list[str | None] = []

    def __call__(self, argv, stdin=None):
        self.calls.append(list(argv))
        self.stdins.append(stdin)
        if self.rc != 0:
            return self.rc, "", self.stderr
        text = self.body if isinstance(self.body, str) else json.dumps(self.body or {})
        return 0, f"{text}\n{self.status}", ""

    @property
    def urls(self) -> list[str]:
        return [c[-1] for c in self.calls]


class ProbeBase(unittest.TestCase):
    def setUp(self):
        self._real_curl = probes._curl
        self._real_sleep = actions.time.sleep
        actions.time.sleep = lambda *_a, **_k: None

    def tearDown(self):
        probes._curl = self._real_curl
        actions.time.sleep = self._real_sleep

    def curl(self, **kw) -> FakeCurl:
        fake = FakeCurl(**kw)
        probes._curl = fake
        return fake


# ============================================================================================
# Half 1 -- the routes are real
# ============================================================================================
class TheRoutesExist(ProbeBase):

    def test_the_control_names_no_phantom_route(self):
        strings = control_strings()
        for bad in PHANTOM_ROUTES:
            self.assertNotIn(bad, strings,
                             f"{bad} is not registered by the kernel; calling it is how a 404 "
                             f"became 'B-3 reproduced'")

    def test_every_ndt_route_the_control_calls_is_registered(self):
        """Checked against the real dispatch chain, not against a list I would have written
        from the same belief that produced the phantom names."""
        registered = components.scan_kernel_dispatch(HTTP_SESSION)
        named = {m for s in control_strings()
                 for m in re.findall(r"(/ndt/[^\"'?\s]*)", s)}
        self.assertTrue(named, "the control names no /ndt/ route at all")
        for path in sorted(named):
            self.assertIn(path.removeprefix("/ndt/"), registered,
                          f"{path} is not in HttpSession.cpp's dispatch chain")

    def test_the_route_is_a_post(self):
        registered = components.scan_kernel_dispatch(HTTP_SESSION)
        self.assertEqual(registered.get("historical_logging"), "POST")

    def test_state_travels_as_a_query_parameter(self):
        """The handler reads utils::queryParam(target, "state") and ignores the body, so a
        body-only `{"enabled": true}` sets nothing even when the route is right."""
        fake = self.curl(body=RECORDING)
        actions._c07_apply(False)
        self.assertTrue(any("state=enable" in u for u in fake.urls), fake.urls)

    def test_undo_disables_through_the_same_route(self):
        fake = self.curl(body=RECORDING)
        actions._c07_undo()
        self.assertTrue(any("state=disable" in u for u in fake.urls), fake.urls)


# ============================================================================================
# Half 2 -- the status is not discarded
# ============================================================================================
class StatusIsNotDiscarded(ProbeBase):

    def test_2xx_returns_the_parsed_body(self):
        self.curl(status=200, body={"ok": 1})
        self.assertEqual(probes.api_get_checked("/ndt/get_graph_data"), {"ok": 1})

    def test_404_raises_and_carries_the_status(self):
        self.curl(status=404, body={"error": "no such endpoint"})
        with self.assertRaises(probes.NotAnswered) as cm:
            probes.api_get_checked("/ndt/get_historical_data")
        self.assertEqual(cm.exception.status, 404)
        self.assertIn("not registered", str(cm.exception))

    def test_500_raises(self):
        self.curl(status=500, body={"error": "manager unavailable"})
        with self.assertRaises(probes.NotAnswered) as cm:
            probes.api_post_checked("/ndt/historical_logging?state=enable", {})
        self.assertEqual(cm.exception.status, 500)

    def test_a_failed_transfer_raises_with_no_status(self):
        self.curl(rc=7, stderr="Failed to connect")
        with self.assertRaises(probes.NotAnswered) as cm:
            probes.api_get_checked("/ndt/get_graph_data")
        self.assertIsNone(cm.exception.status)

    def test_a_2xx_that_is_not_json_raises_rather_than_becoming_none(self):
        self.curl(status=200, body="<html>gateway</html>")
        with self.assertRaises(probes.NotAnswered):
            probes.api_get_checked("/ndt/get_graph_data")

    def test_a_multiline_body_is_recovered_whole(self):
        """The status is appended on its own last line, so the split must be on the LAST
        newline; splitting on the first would truncate any pretty-printed body."""
        self.curl(status=200, body='{\n  "a": 1,\n  "b": 2\n}')
        self.assertEqual(probes.api_get_checked("/ndt/get_graph_data"), {"a": 1, "b": 2})

    def test_the_lenient_probes_still_answer_none_for_callers_that_tolerate_it(self):
        """Unchanged contract: existing callers that genuinely cope with a missing endpoint
        keep their behaviour. What changed is that a verdict may no longer be built on it."""
        self.curl(status=404, body={"error": "x"})
        self.assertIsNone(probes.api_get("/ndt/whatever"))
        self.assertIsNone(probes.api_post("/ndt/whatever", {}))


# ============================================================================================
# The whole point: the control can come out both ways
# ============================================================================================
class ItDiscriminates(ProbeBase):

    def test_a_404_is_refused_not_scored_as_a_reproduction(self):
        """THE DEFECT. Against the old code this returned ok=True -- 'none written, B-3
        reproduced' -- from three routes that do not exist."""
        self.curl(status=404, body={"error": "no such endpoint"})
        applied = actions._c07_apply(False)
        self.assertFalse(applied.ok, f"a 404 was scored as an applied injection: {applied.detail}")
        verified = actions._c07_verify()
        self.assertFalse(verified.ok,
                         f"a 404 was scored as B-3 reproduced: {verified.detail}")
        self.assertIn("404", verified.detail)

    def test_a_500_is_refused(self):
        """500 is a documented answer here (no HistoricalDataManager) and it is not the
        defect: the request never reached the flag."""
        self.curl(status=500, body={"error": "Historical data manager not available."})
        self.assertFalse(actions._c07_apply(False).ok)
        self.assertFalse(actions._c07_verify().ok)

    def test_a_non_recording_kernel_reproduces_b3(self):
        """Defect present -> the control finds it."""
        self.curl(status=200, body=NOT_RECORDING)
        applied = actions._c07_apply(False)
        self.assertTrue(applied.ok, applied.detail)
        verified = actions._c07_verify()
        self.assertTrue(verified.ok, verified.detail)
        self.assertIn("reproduced", verified.detail)
        self.assertEqual(verified.evidence["reason"], "not-available-in-mininet-mode")

    def test_a_recording_kernel_does_not_reproduce_b3(self):
        """Defect absent -> the control says so. The old criterion could never reach this
        side: `rows == 0` was true for every answer it was capable of receiving."""
        self.curl(status=200, body=RECORDING)
        self.assertTrue(actions._c07_apply(False).ok)
        verified = actions._c07_verify()
        self.assertFalse(verified.ok,
                         f"a live recorder was still scored as B-3: {verified.detail}")
        self.assertIn("did NOT reproduce", verified.detail)

    def test_a_reply_without_the_recording_field_is_refused(self):
        """A kernel predating the disclosure makes the two cases indistinguishable again, so
        the control must refuse rather than pick the accusatory reading."""
        self.curl(status=200, body={"status": "success",
                                    "message": "Historical data logging has been enabled."})
        verified = actions._c07_verify()
        self.assertFalse(verified.ok, verified.detail)
        self.assertIn("recording", verified.detail)

    def test_the_verdict_is_not_a_row_count(self):
        """An empty 200 must not be read as 'zero rows, therefore reproduced'."""
        self.curl(status=200, body="")
        self.assertFalse(actions._c07_verify().ok)

    def test_the_dry_run_touches_nothing(self):
        fake = self.curl(body=RECORDING)
        res = actions._c07_apply(True)
        self.assertTrue(res.dry_run)
        self.assertEqual(fake.calls, [], "the dry run issued a request")


class TheRetractionIsRecorded(unittest.TestCase):
    """The published claim that rested on this control must not read as current."""

    # Beside the harness, so NDT_CHAOS_HARNESS moves this too and the mutation gate can score
    # the retraction the same way it scores the code.
    CLAIM = os.path.join(os.path.dirname(HARNESS.rstrip(os.sep)), "05_first-live-run.md")

    def test_h9_is_marked_retracted(self):
        with open(self.CLAIM, encoding="utf-8") as fh:
            text = fh.read()
        head = text.split("## H-10", 1)[0].split("## H-9", 1)[-1]
        self.assertIn("RETRACTED", head,
                      "05_first-live-run.md H-9 still asserts the control 'verified true'")
        self.assertIn("G-3", head, "the retraction does not name its reason")
        self.assertIn("2026-09-03", head, "the retraction is not dated")


if __name__ == "__main__":
    unittest.main(verbosity=2)
