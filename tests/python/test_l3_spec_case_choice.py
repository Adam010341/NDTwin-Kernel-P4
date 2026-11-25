#!/usr/bin/env python3
"""
The component check judges each route by its ordinary case, not by an error-path case.

[Co-developed with claude code -- Adam]

tools/contract_test/l3_component_check.py keeps one spec entry per path. It used to keep the
first one it met, so an error-path case written ahead of the ordinary one made the check judge
the route by a case that expects a refusal: against a kernel without that refusal the route was
reported BROKEN, and against one with it the check no longer exercised a successful call. The
choice must not depend on the order of spec.py.

Stdlib only, no kernel. Run:  python3 tests/python/test_l3_spec_case_choice.py -v
"""
from __future__ import annotations

import os
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONTRACT_DIR = os.environ.get("NDT_CONTRACT_DIR") or os.path.join(REPO, "tools", "contract_test")
sys.path.insert(0, CONTRACT_DIR)

import l3_component_check as l3  # noqa: E402
from spec import ENDPOINTS, ERRORPATH  # noqa: E402


def _case(name, path, category):
    return {"name": name, "path": path, "category": category}


class RealSpecChoice(unittest.TestCase):
    def test_delete_flow_entry_uses_ordinary_case(self):
        self.assertEqual(l3.SPEC_BY_ENDPOINT["delete_flow_entry"]["name"], "delete_flow_entry")

    def test_install_flow_entry_uses_ordinary_case(self):
        self.assertEqual(l3.SPEC_BY_ENDPOINT["install_flow_entry"]["name"], "install_flow_entry")

    def test_no_route_with_an_ordinary_case_is_judged_by_an_error_case(self):
        ordinary = {e["path"] for e in ENDPOINTS if e["category"] != ERRORPATH}
        for name, ep in l3.SPEC_BY_ENDPOINT.items():
            if ep["path"] in ordinary:
                self.assertNotEqual(ep["category"], ERRORPATH, name)

    def test_error_only_path_still_gets_a_case(self):
        only_error = {e["path"] for e in ENDPOINTS} - {
            e["path"] for e in ENDPOINTS if e["category"] != ERRORPATH}
        self.assertTrue(only_error)
        for path in only_error:
            self.assertIn(path.removeprefix("/ndt/"), l3.SPEC_BY_ENDPOINT)


class OrderIndependence(unittest.TestCase):
    P = "/ndt/x"

    def _pick(self, cases):
        return l3.build_spec_by_endpoint(cases)["x"]["name"]

    def test_error_case_first(self):
        self.assertEqual(self._pick([_case("x__bad", self.P, ERRORPATH),
                                     _case("x", self.P, "mutate")]), "x")

    def test_error_case_last(self):
        self.assertEqual(self._pick([_case("x", self.P, "mutate"),
                                     _case("x__bad", self.P, ERRORPATH)]), "x")

    def test_first_ordinary_case_wins_among_ordinary(self):
        self.assertEqual(self._pick([_case("x__bad", self.P, ERRORPATH),
                                     _case("x", self.P, "read"),
                                     _case("x_other", self.P, "mutate")]), "x")

    def test_only_error_cases_keeps_the_first(self):
        self.assertEqual(self._pick([_case("x__a", self.P, ERRORPATH),
                                     _case("x__b", self.P, ERRORPATH)]), "x__a")


if __name__ == "__main__":
    unittest.main()
