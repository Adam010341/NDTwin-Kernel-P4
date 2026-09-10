#!/usr/bin/env python3
"""
The -1 "unavailable" sentinel for the three device-health endpoints, on both sides of the
contract test.

[Co-developed with claude code -- Adam]

F-1 (doc/KNOWN-ISSUES.md, entry F-1) is that `get_cpu_utilization` and `get_memory_utilization` return
byte-identical bodies under MININET, because both compute `10 + hash(ip) % 50` from the same
seed, and `get_temperature` is `25 + hash(ip) % 25` from the same seed again. The fix is to stop
inventing a figure and report the sentinel the file, the API document and the Web-GUI already
agree means "unavailable": -1. So under MININET every switch now reads -1 on all three
endpoints, and that is the response shape the contract test has to accept.

`tools/contract_test/spec.py` already accepts it -- `Num(min=-1, max=100)`, with a comment
explaining that -1 is the documented sentinel and not an out-of-range utilisation. Those cases
are pinned here as controls: they must stay green, because the fix depends on them.

The reason this file exists is the other side. `selftest_fixtures.py` carries its **own** copy
of each schema rather than reading spec.py's, and the copies had drifted:

    spec.py:502                 MapOf(Num(min=-1, max=100), ...)
    selftest_fixtures.py:84     MapOf(Num(min=0,  max=100), ...)

A self-test whose stated purpose is "prove the schemas accept what the kernel actually
documents" was validating the documented example against a schema the kernel does not use, and
the narrower copy rejects the one value the API document singles out. It could not have caught
a real -1 response, and after the F-1 fix a real MININET response is -1 for every switch.

The temperature fixture had the same shape of problem in its sample rather than its schema: it
carried "The switch is down.", which spec.py:511-513 records as no longer emitted by any current
build, and did not carry the -1 that replaced it in 2026-08-18.

Lives in tests/python/ rather than p4_proxy/tests/ for the reason test_contract_spec.py gives:
L1 runs this directory under a plain python3 with no PYTHONPATH, so nothing here may import
grpc, networkx or requests. unittest rather than pytest for the same reason -- l1_unit_tests.sh
executes each file directly and parses "Ran N tests".
"""

from __future__ import annotations

import os
import sys
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO_ROOT, "tools", "contract_test"))

import selftest_fixtures as fx  # noqa: E402
import spec  # noqa: E402
from schema import validate  # noqa: E402

#: The value the kernel reports when a health metric cannot be read. Documented in
#: doc/2026-01-02_ndt_api.md sections 12, 13 and 21, produced by the `!isUp` branch of all three
#: fetch*Internal functions, and -- after the F-1 fix -- by the MININET branch as well.
UNAVAILABLE = -1

#: The three endpoints whose values are device health metrics keyed by switch IP.
HEALTH_ENDPOINTS = ("get_cpu_utilization", "get_memory_utilization", "get_temperature")

#: What a MININET fabric answers once F-1 is fixed: every switch present, every value the
#: sentinel. Keys are the management IPs the shipped 10-switch topologies use.
MININET_RESPONSE = {
    "10.0.0.1": UNAVAILABLE,
    "10.0.0.2": UNAVAILABLE,
    "10.0.0.3": UNAVAILABLE,
}


def spec_schema(name: str):
    """The schema the contract test actually runs against a live kernel."""
    for endpoint in spec.ENDPOINTS:
        if endpoint["name"] == name:
            return endpoint["schema"]
    raise AssertionError(f"{name} is not in spec.ENDPOINTS")


def fixture_schema(name: str):
    """The schema --self-test validates the documented example against."""
    schema, _sample = fx.FIXTURES[name]
    return schema


def fixture_sample(name: str):
    _schema, sample = fx.FIXTURES[name]
    return sample


class ShippedSchemaAcceptsTheSentinelTest(unittest.TestCase):
    """Controls. These already pass; the fix depends on them continuing to."""

    def test_every_health_endpoint_schema_accepts_an_all_unavailable_response(self):
        for name in HEALTH_ENDPOINTS:
            with self.subTest(endpoint=name):
                self.assertEqual(validate(spec_schema(name), MININET_RESPONSE), [])

    def test_the_schemas_still_reject_a_value_below_the_sentinel(self):
        # -1 is the sentinel, not a licence for arbitrary negatives: -2 has no meaning and must
        # not slip through as one.
        below = dict(MININET_RESPONSE, **{"10.0.0.1": -2})
        for name in ("get_cpu_utilization", "get_memory_utilization"):
            with self.subTest(endpoint=name):
                self.assertTrue(validate(spec_schema(name), below))

    def test_a_map_of_sentinels_still_satisfies_the_coverage_invariant(self):
        # inv_util_map_covers_switches counts keys, so replacing fabricated values with the
        # sentinel must not make the contract test think switches went missing. This is the
        # invariant that would have caught the fix if it had dropped keys instead.
        class Ctx:
            expected_switches = len(MININET_RESPONSE)

        self.assertEqual(spec.inv_util_map_covers_switches(MININET_RESPONSE, Ctx()), [])


class SelfTestFixtureMatchesTheShippedSchemaTest(unittest.TestCase):
    """
    The self-test validates against a copy. A copy that is narrower than the shipped schema
    reports green while being unable to see the values production emits.
    """

    def test_the_fixture_schema_accepts_the_sentinel_the_shipped_schema_accepts(self):
        for name in HEALTH_ENDPOINTS:
            with self.subTest(endpoint=name):
                self.assertEqual(
                    validate(fixture_schema(name), MININET_RESPONSE), [],
                    f"{name}'s self-test schema rejects -1, which spec.py accepts and "
                    f"doc/2026-01-02_ndt_api.md documents")

    def test_the_documented_example_actually_contains_the_sentinel(self):
        # Otherwise --self-test never exercises the branch. The fixtures' whole claim is that
        # they are the documented examples, and -1 is the value the API document calls out by
        # name for all three endpoints.
        for name in HEALTH_ENDPOINTS:
            with self.subTest(endpoint=name):
                self.assertIn(
                    UNAVAILABLE, list(fixture_sample(name).values()),
                    f"{name}'s self-test sample never shows an unavailable reading, so the "
                    f"self-test cannot tell whether the schema admits one")

    def test_the_dead_switch_is_down_string_is_not_still_being_pinned(self):
        # spec.py:511-513 records that no current build emits it; a fixture that keeps it as its
        # only unavailable case pins a shape the kernel stopped producing in 2026-08-18.
        self.assertNotIn("The switch is down.",
                         list(fixture_sample("get_temperature").values()))


class PowerReportSchemaAcceptsTheSentinelTest(unittest.TestCase):
    """
    The fourth endpoint that reports the same sentinel, and the one whose schema still refused it.

    [Co-developed with claude code -- Adam]

    R5 / F-OFFLINE-1 (2026-09-10). `/ndt/get_power_report` is not in HEALTH_ENDPOINTS above and
    cannot be: those three are maps keyed by switch IP, and this one is a LIST of
    `{dpid, power_consumed, power_path}` objects. So it needs its own case -- and it needed one,
    because the two halves were green apart and red together:

      * the C++ has emitted `power_consumed: -1` on the TESTBED branch since E-23 (2026-09-07)
        for a switch whose `power_path` is "none" and, since FINDINGS #85, for one with no
        management address -- `kHealthMetricUnavailable`, the same -1 the three endpoints above
        report and the API document names for this endpoint too (section 6's "Note");
      * `spec.py`'s entry for it said `Num(min=0)`, so `validate()` on exactly that row answered
        `[0].power_consumed: expected >= 0, got -1`.

    Nothing was red, because the contract runner is pointed at a MININET kernel, where every
    figure is the synthetic one and no row is ever negative. The schema would have failed the
    first time anybody ran it against a testbed with an exempted or address-less switch in the
    fabric -- which is the deployment E-23 exists for.

    🔴 WHY THE FIXTURE SAMPLE IS NOT GIVEN A -1 ROW, unlike the three endpoints above. Their
    samples ARE the API document's examples and the document shows -1 for them. Section 6's
    example is a captured MININET response, and MININET never reports -1 here (the document says
    so in the same paragraph). Adding a sentinel row would make the fixture stop being the
    documented example, which is the one property --self-test relies on. The schema copy is
    pinned instead, by the second case below.
    """

    #: The row the C++ emits in TESTBED for an exempted switch:
    #: DeviceConfigurationAndPowerManager.cpp, fetchPowerReportInternal's exempt exit. dpid 7 and
    #: brand "none" are the same pairing tests/test_ExemptSwitchIsNotDialled.cpp uses.
    TESTBED_EXEMPT_ROW = [{"dpid": 7, "power_consumed": UNAVAILABLE, "power_path": "none"},
                          {"dpid": 8, "power_consumed": 92465, "power_path": "ssh"}]

    def test_the_shipped_schema_accepts_the_sentinel_this_endpoint_reports(self):
        self.assertEqual(
            validate(spec_schema("get_power_report"), self.TESTBED_EXEMPT_ROW), [],
            "spec.py rejects the row the kernel emits for an exempted switch in TESTBED, so "
            "the contract test would fail on a correct kernel")

    def test_the_self_test_copy_accepts_it_too(self):
        # The drift this whole file exists for: selftest_fixtures.py keeps its own copy of this
        # schema, and a copy narrower than the shipped one reports green while being unable to
        # see what production emits.
        self.assertEqual(
            validate(fixture_schema("get_power_report"), self.TESTBED_EXEMPT_ROW), [],
            "the self-test's copy of the power-report schema rejects -1, which spec.py accepts")

    def test_it_still_rejects_a_value_below_the_sentinel(self):
        # -1 is the sentinel, not a licence for arbitrary negatives -- the same control the three
        # endpoints above carry.
        below = [dict(self.TESTBED_EXEMPT_ROW[0], power_consumed=-2)]
        self.assertTrue(validate(spec_schema("get_power_report"), below))

    def test_a_report_of_sentinels_still_satisfies_the_coverage_invariant(self):
        # inv_power_covers_switches reads dpids, not values, so replacing readings with the
        # sentinel must not make the contract test think a switch went missing.
        class Ctx:
            expected_dpids = {7, 8}

        self.assertEqual(
            spec.inv_power_covers_switches(self.TESTBED_EXEMPT_ROW, Ctx()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
