#!/usr/bin/env python3
"""FINDINGS-ALL #75: the chaos RUNNER must actually run INV-01's latency check.

[Co-developed with claude code -- Adam]

The defect. #17 rewrote `inv01_powercycle_latency` so it finally sends the request the kernel
registers (POST, `ip=`) and refuses to score a 404 as an A-1 finding. It fixed a function with
**zero call sites**: `chaos.py`'s round called `inv01_power_state_agreement` and nothing else,
so no round -- null, dry-run, controls or full -- has ever evaluated the latency half. Same
family as #71: `existence != wiring`. A check nobody calls is indistinguishable, in a report,
from a check that passed.

The second half of #17 is the precondition, and it is why this file is not simply "call it":

    INV-01's latency check has never measured a power-on.

`P4PowerStrategy::powerOn` returns success immediately when the vertex is already up, so
timing a power-on of a healthy, running switch measures the CORRECT early return -- and this
check reads a fast answer as the A-1 lie. Calling it unconditionally would therefore
manufacture a FAIL on a healthy fabric, which is the failure this harness has already produced
twice (`switch_flags`' host collision, and #17's own 404 timing). So the round asks first
whether it has a power-on worth timing, and when it does not the report says **not measured**
-- never "pass". A check that could not run and a check that ran clean are different facts.

Both directions, because only one of them is about calling the function:

  * `TheRunnerRunsBothHalves`  -- the latency check is invoked and its result reaches the round
                                 report, named separately, with its measured latency and the
                                 threshold it was judged against.
  * `WhenThereIsNothingToTime` -- no power-on to time is NOT-MEASURED, sends no request at all,
                                 and never reads as a pass.
  * `ItStillResolves`          -- a duration on the failing side of the threshold still fails
                                 the round, and one on the honest side still leaves it passing.
                                 A wiring that always answers "not measured" would satisfy the
                                 two classes above and detect nothing.

🔴 Note on polarity, because it inverts the usual reading: for THIS check the failing side of
the threshold is the FAST one. A-1's signature is a power-on that returns in ~0.01 s having
done nothing; the honest path measures ~1.27 s. "Slow" is the passing side.

Stdlib only, no kernel, no fabric, no build, no lab: `probes._curl` is the seam its own
docstring declares for this, and the round's other two system reads (`bmv2_process_count`,
`cpu_busy_fraction`) are replaced in setUp.

Run:  python3 tests/python/test_chaos_runner_wiring.py -v
"""
from __future__ import annotations

import inspect
import json
import os
import sys
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# Same seam as tests/python/test_chaos_invariants_method.py: NDT_CHAOS_HARNESS points the
# import at a MUTATED COPY so tests/shell/mutate_chaos_runner_wiring.sh can score this file
# without writing a byte into a worktree other sessions are reading. Unset in a normal run.
HARNESS = os.environ.get("NDT_CHAOS_HARNESS") or os.path.join(
    REPO, "doc", "audit", "2026-08-28_chaos-harness", "harness")
sys.path.insert(0, HARNESS)
# The copy lives in /tmp, where walking up from probes.py finds no repo. The route table must
# still come from the REAL kernel source: mutating the harness must not also mutate the
# authority it is checked against.
os.environ.setdefault("NDT_KERNEL_REPO", REPO)

import antioracle  # noqa: E402
import chaos  # noqa: E402
import invariants  # noqa: E402
import probes  # noqa: E402

S1 = "192.168.123.11"
S2 = "192.168.123.12"

# 🔴 The name is part of the report's contract, not an implementation detail: it is what a
# reader -- or a grep over a round's JSON -- looks for to tell the two INV-01 checks apart.
# Spelled here as a literal so the test cannot agree with a renamed constant and still pass.
LATENCY = "INV-01-latency"
AGREEMENT = "INV-01"


def ip_u32(dotted: str) -> int:
    """The graph emits addresses as raw little-endian uint32 (probes.decode_ip)."""
    return sum(int(p) << (8 * i) for i, p in enumerate(dotted.split(".")))


def graph(s1_up: bool, s2_up: bool = True) -> dict:
    """A minimal but REAL-shaped graph: switches carry vertex_type 0 and an `ip` list, hosts
    carry vertex_type 1 and all share dpid 0 (the collision that produced the 11-vs-10 false
    positive on 2026-08-29 -- keeping two hosts here means switch_flags is exercised, not
    assumed)."""
    return {"nodes": [
        {"vertex_type": 0, "dpid": 1, "device_name": "s1", "ip": [ip_u32(S1)],
         "is_up": s1_up, "is_enabled": True},
        {"vertex_type": 0, "dpid": 2, "device_name": "s2", "ip": [ip_u32(S2)],
         "is_up": s2_up, "is_enabled": True},
        {"vertex_type": 1, "dpid": 0, "device_name": "h1", "ip": [ip_u32("10.0.0.1")],
         "is_up": True, "is_enabled": True},
        {"vertex_type": 1, "dpid": 0, "device_name": "h2", "ip": [ip_u32("10.0.0.2")],
         "is_up": True, "is_enabled": True},
    ]}


class FakeKernel:
    """Replaces probes._curl and answers per ROUTE, so the power-on can be slow while the
    graph read stays instant. `calls` is every request that got past the route guard."""

    def __init__(self, graph_body: dict, power=(200, '{"192.168.123.11":"Success"}', 0.0)):
        self.graph_body = graph_body
        self.power = power
        self.calls: list[list[str]] = []

    def __call__(self, argv, stdin=None):
        url = argv[-1]
        self.calls.append(list(argv))
        if "get_graph_data" in url:
            status, body, delay = 200, json.dumps(self.graph_body), 0.0
        elif "get_detected_flow_data" in url:
            status, body, delay = 200, "[]", 0.0
        elif "set_switches_power_state" in url:
            status, body, delay = self.power
        else:
            status, body, delay = 200, "{}", 0.0        # locks: `{}` is "not acquired"
        if delay:
            time.sleep(delay)
        return 0, f"{body}\n{status}", ""

    @property
    def power_calls(self) -> list[list[str]]:
        return [c for c in self.calls if "set_switches_power_state" in c[-1]]


class RoundHarness(unittest.TestCase):
    """A whole round with every system read replaced. No kernel, no fabric, no sleep."""

    def install(self, graph_body: dict, processes: int, power=(200, '{"x":"Success"}', 0.0)):
        fake = FakeKernel(graph_body, power)
        real_curl, real_count = probes._curl, probes.bmv2_process_count
        real_cpu = antioracle.cpu_busy_fraction
        probes._curl = fake
        probes.bmv2_process_count = lambda: processes
        # CpuGate resolves this as a module global at call time, and the real one sleeps 1 s
        # three times per round.
        antioracle.cpu_busy_fraction = lambda window_s=1.0: 0.0

        def restore():
            probes._curl = real_curl
            probes.bmv2_process_count = real_count
            antioracle.cpu_busy_fraction = real_cpu
        self.addCleanup(restore)
        return fake

    def null_round(self, power_ip: str | None = S1) -> dict:
        """The runner's null round.

        `power_ip` is passed only if the runner accepts one. On trunk it does not, and the
        cases below then go red on the ASSERTION -- "the report has no latency check in it" --
        instead of on a TypeError, which is the difference between a red that names the defect
        and a red that names a signature.
        """
        kw = {}
        if "power_ip" in inspect.signature(chaos.null_round).parameters:
            kw["power_ip"] = power_ip
        return chaos.null_round(None, None, None, False, **kw)

    def by_name(self, report: dict, name: str) -> list[dict]:
        return [f for f in report["findings"] if f["inv"] == name]

    def one(self, report: dict, name: str) -> dict:
        rows = self.by_name(report, name)
        self.assertEqual(len(rows), 1,
                         f"expected exactly one {name} row in the round report, found "
                         f"{len(rows)}: {[f['inv'] for f in report['findings']]}")
        return rows[0]


# ------------------------------------------------------------------------------------------
class TheRunnerRunsBothHalves(RoundHarness):
    """#75 itself: the round has to CALL the latency check, and its answer has to land in the
    report where a reader can see it."""

    def test_the_latency_check_reaches_the_round_report(self):
        """🔴 THE DEFECT. Red on trunk: `chaos.py` calls inv01_power_state_agreement and
        nothing else, so this row does not exist in any round anyone has ever run."""
        fake = self.install(graph(s1_up=False), processes=1)
        r = self.null_round()
        self.assertTrue(self.by_name(r, LATENCY),
                        f"no {LATENCY} row in the round report; the round evaluated "
                        f"{[f['inv'] for f in r['findings']]} -- the latency check has zero "
                        f"call sites, which is finding #75")
        self.assertTrue(fake.power_calls,
                        "the latency row exists but no power-on was ever sent, so whatever it "
                        "reports was not measured from a request")

    def test_the_two_checks_are_reported_separately(self):
        """Two different questions about INV-01: 'does the graph agree with the process table'
        and 'does a power-on take long enough to have done the work'. One row cannot carry two
        verdicts, and a merged row would let a pass hide a failure."""
        self.install(graph(s1_up=False), processes=1)
        r = self.null_round()
        agree, latency = self.one(r, AGREEMENT), self.one(r, LATENCY)
        self.assertNotEqual(agree["detail"], latency["detail"])
        self.assertIn("verdict", latency)

    def test_the_latency_row_carries_its_measurement_and_its_threshold(self):
        """A duration without the threshold it was judged against is not a result anyone can
        check, and this threshold has moved once already (#17)."""
        self.install(graph(s1_up=False), processes=1, power=(200, '{"x":"Success"}', 0.0))
        ev = self.one(self.null_round(), LATENCY)["evidence"]
        self.assertIn("elapsed_s", ev)
        self.assertIn("threshold_s", ev)
        self.assertIsInstance(ev["elapsed_s"], float)
        self.assertIsInstance(ev["threshold_s"], float)

    def test_an_injection_round_runs_it_too(self):
        """Not only the null round. A wiring that reaches one mode and not the others is the
        same defect one layer down."""
        self.install(graph(s1_up=False), processes=1)
        act = chaos.A.Action("T-1", "", "a no-op action for this test", destructive=False,
                             apply=lambda dry: chaos.A.ActionResult(True, "applied"),
                             verify=lambda: chaos.A.ActionResult(True, "verified"))
        kw = {}
        if "power_ip" in inspect.signature(chaos.injection_round).parameters:
            kw["power_ip"] = S1
        r = chaos.injection_round(act, False, None, None, None, False, **kw)
        self.assertTrue([f for f in r["findings"] if f["inv"] == LATENCY],
                        f"the injection round evaluated {[f['inv'] for f in r['findings']]}")


# ------------------------------------------------------------------------------------------
class WhenThereIsNothingToTime(RoundHarness):
    """#17's second half. The precondition is a power-on that OUGHT to do work; without one the
    duration measures a correct early return and means nothing."""

    def test_a_healthy_fabric_reports_not_measured_and_sends_nothing(self):
        """Every switch the graph calls up has a live process, so powering one on legitimately
        returns at once. Scoring that PASS claims "checked, and it was fine" about a check that
        did not run -- the same claim INCONCLUSIVE-CPU exists to refuse. And nothing may be
        sent: a power-on here would both change the fabric and manufacture the very number the
        check is about to weigh."""
        fake = self.install(graph(s1_up=True), processes=2)
        f = self.one(self.null_round(), LATENCY)
        self.assertNotEqual(f["verdict"], antioracle.PASS,
                            f"a check that never ran was reported as a pass: {f['detail']}")
        self.assertIn("not measured", f["detail"].lower(),
                      f"the report has to SAY it did not measure: {f['detail']}")
        self.assertIsNone(f["evidence"].get("elapsed_s"),
                          "an unmeasured duration must be null, never 0.0 -- 0.0 is exactly "
                          "the fast-return signature this check reads as the defect")
        self.assertEqual(fake.power_calls, [],
                         "a power-on was sent for a round that had no power-on to time, which "
                         "both changes the fabric and manufactures the number being weighed")

    def test_no_target_address_is_also_not_measured(self):
        self.install(graph(s1_up=False), processes=1)
        f = self.one(self.null_round(power_ip=None), LATENCY)
        self.assertNotEqual(f["verdict"], antioracle.PASS)
        self.assertIn("not measured", f["detail"].lower())

    def test_an_unreadable_graph_is_not_measured_rather_than_measured_blind(self):
        """If the power-state check could not read the fabric, whether a power-on has work to
        do is unknown -- and unknown is not permission to time one."""
        fake = self.install({"nodes": "not a list"}, processes=1)
        f = self.one(self.null_round(), LATENCY)
        self.assertNotEqual(f["verdict"], antioracle.PASS)
        self.assertEqual(fake.power_calls, [])

    def test_not_measured_does_not_fail_the_round_on_its_own(self):
        """The other direction of the same rule: 'could not measure' must not be scored as a
        violation either, or every healthy round reports one."""
        self.install(graph(s1_up=True), processes=2)
        r = self.null_round()
        self.assertEqual(r["verdict"], antioracle.PASS, r.get("verdict_detail"))


# ------------------------------------------------------------------------------------------
class ItStillResolves(RoundHarness):
    """🔴 The control block. A wiring that answers NOT-MEASURED every time passes every case
    above and detects nothing -- the same trade #17's gate caught as a constant SKIPPED."""

    def test_a_duration_on_the_failing_side_of_the_threshold_fails_the_round(self):
        """s1 is DOWN in the graph, so this power-on must really start a switch; a 200 in ~0 s
        is the A-1 fingerprint. The agreement check PASSES in this state (2 up in the graph is
        not more than 2 processes), so the round can only go red through the latency check --
        which is what makes this case discriminating rather than decorative."""
        self.install(graph(s1_up=False), processes=2,
                     power=(200, '{"192.168.123.11":"Success"}', 0.0))
        r = self.null_round()
        self.assertEqual(self.one(r, AGREEMENT)["verdict"], antioracle.PASS,
                         "the fixture is wrong: this round must fail ONLY through the latency "
                         "check, or it proves nothing about the wiring")
        self.assertEqual(self.one(r, LATENCY)["verdict"], antioracle.FAIL,
                         self.one(r, LATENCY)["detail"])
        self.assertEqual(r["verdict"], antioracle.FAIL,
                         f"the latency check failed and the round did not: {r.get('verdict_detail')}")

    def test_a_duration_on_the_honest_side_leaves_the_round_passing(self):
        self.install(graph(s1_up=False), processes=2,
                     power=(200, '{"192.168.123.11":"Success"}', 0.2))
        r = self.null_round()
        self.assertEqual(self.one(r, LATENCY)["verdict"], antioracle.PASS,
                         self.one(r, LATENCY)["detail"])
        self.assertEqual(r["verdict"], antioracle.PASS, r.get("verdict_detail"))

    def test_the_threshold_in_the_report_is_the_one_the_check_judges_by(self):
        """Otherwise the report's threshold is a second copy of the number and can drift from
        the comparison silently. Read the threshold OUT of the report, then straddle it."""
        self.install(graph(s1_up=False), processes=2, power=(200, '{"x":"ok"}', 0.0))
        thr = self.one(self.null_round(), LATENCY)["evidence"]["threshold_s"]
        self.doCleanups()
        self.install(graph(s1_up=False), processes=2, power=(200, '{"x":"ok"}', thr * 2.0))
        self.assertEqual(self.one(self.null_round(), LATENCY)["verdict"], antioracle.PASS,
                         f"a duration of {thr * 2:.3f}s is above the reported threshold "
                         f"{thr} and was still scored as the defect")

    def test_a_refusal_is_not_a_measurement_and_not_a_pass(self):
        """#17, at the runner. A 404 comes back fast; the round must not read that as either
        the defect or a clean reading."""
        self.install(graph(s1_up=False), processes=2,
                     power=(404, '{"error":"Missing or invalid ip/action"}', 0.0))
        f = self.one(self.null_round(), LATENCY)
        self.assertNotEqual(f["verdict"], antioracle.PASS)
        self.assertNotEqual(f["verdict"], antioracle.FAIL)
        self.assertNotIn("A-1", f["detail"])

    def test_the_verdicts_are_actually_distinct(self):
        """Belt and braces: a constant of ANY value satisfies one case above."""
        seen = set()
        for g, procs, power in ((graph(s1_up=False), 2, (200, '{"x":"ok"}', 0.0)),
                                (graph(s1_up=False), 2, (200, '{"x":"ok"}', 0.2)),
                                (graph(s1_up=True), 2, (200, '{"x":"ok"}', 0.0))):
            self.install(g, procs, power)
            seen.add(self.one(self.null_round(), LATENCY)["verdict"])
            self.doCleanups()
        self.assertEqual(len(seen), 3,
                         f"the latency row produced {seen} across three genuinely different "
                         f"rounds; fewer than three means it is not resolving them")


if __name__ == "__main__":
    unittest.main(verbosity=2)
