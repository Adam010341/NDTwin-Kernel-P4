#!/usr/bin/env python3
"""FINDINGS-ALL #17: the chaos harness must not send a method the kernel does not register,
and must never read the resulting 404/405 as a finding about NDTwin.

[Co-developed with claude code -- Adam]

The defect (#17, fourth instance). `harness/invariants.py` inv01_powercycle_latency sent

    GET /ndt/set_switches_power_state?dpid={dpid}&action=on

against a route `src/ndt_core/http/HttpSession.cpp:189` registers under `http::verb::post`
alone, whose handler reads `ip` and not `dpid` (`:866-867`). Both halves were wrong. The
request 404'd, `api_get_timed` is lenient so the body became `None`, nothing looked at it, and
the only surviving number was the clock -- ~0.007 s, because an unrouted request is fast. The
criterion `dt < 0.1` then returned, on every round, forever:

    "power-on answered in 0.0069s; the honest path measures ~1.27s, so nothing was attempted
     (A-1 early return)"

A CONSTANT verdict: it fired whether or not A-1 existed, on any fabric and on none. The third
instance of the same family (`actions.py:_h23_verify` reading an unregistered route) was fixed
in efd2fe10 by refusing instead of accusing; this file pins the fourth, the fifth found while
sweeping for it (`actions.py:_c01_undo`), and the structural guard that makes a sixth fail loud.

🔴 BOTH DIRECTIONS, because only one of them is about being strict:

  * `ItMustRefuse`      -- a wrong method, a wrong key, an unregistered route, and a refusal
                           dressed up as an invariant conclusion.
  * `ItMustStillFire`   -- the invariant can still return FAIL when the defect is really there.
                           A guard that turns INV-01 into a constant SKIPPED is a worse
                           instrument than the constant FAIL it replaced, and every case in
                           `ItMustRefuse` would pass against it.
  * `ToleratedAbsence`  -- a legitimate 404 for a flow that is not there must STILL come back
                           as `None` from the lenient readers and STILL be SKIPPED, not FAIL.
                           "Refuse every non-200" is the over-correction, and it breaks
                           INV-03 and the B-3 control, both of which tolerate one on purpose.

`TheWholeHarnessConforms` is the completeness half. #17 named one line; grep for the others
misses variable-held paths, f-strings and wrapper functions, so that class re-derives the call
list by walking every harness module's AST and checks each site against the kernel's real
dispatch chain. A sixth instance added tomorrow fails here without anyone remembering #17.

Stdlib only, no kernel, no fabric, no build: `probes._curl` is the seam its own docstring
declares for exactly this ("Replaced by the self-tests, so every status-handling branch below
can be watched go both ways without a kernel").

Run:  python3 tests/python/test_chaos_invariants_method.py -v
"""
from __future__ import annotations

import ast
import os
import sys
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# NDT_CHAOS_HARNESS points the import at a MUTATED COPY of the harness so
# tests/shell/mutate_chaos_invariants_method.sh can score this file without writing a byte
# into a worktree three other sessions are using. Unset in every normal run.
HARNESS = os.environ.get("NDT_CHAOS_HARNESS") or os.path.join(
    REPO, "doc", "audit", "2026-08-28_chaos-harness", "harness")
sys.path.insert(0, HARNESS)
# The copy lives in /tmp, where walking up from probes.py finds no repo. The route table must
# still come from the REAL kernel source -- mutating the harness must not also mutate the
# authority it is checked against.
os.environ.setdefault("NDT_KERNEL_REPO", REPO)

import actions  # noqa: E402
import invariants  # noqa: E402
import probes  # noqa: E402

HTTP_SESSION = os.path.join(REPO, "src", "ndt_core", "http", "HttpSession.cpp")
S1 = "192.168.123.11"


# ------------------------------------------------------------------------------------------
# A fake kernel. Records what was asked, answers what the test says to answer.
# ------------------------------------------------------------------------------------------
class FakeKernel:
    """Replaces probes._curl. `calls` is the argv of every request that got past the guard."""

    def __init__(self, status: int = 200, body: str = "{}", delay: float = 0.0):
        self.status, self.body, self.delay = status, body, delay
        self.calls: list[list[str]] = []

    def __call__(self, argv, stdin=None):
        self.calls.append(list(argv))
        if self.delay:
            time.sleep(self.delay)
        return 0, f"{self.body}\n{self.status}", ""

    @property
    def method(self) -> str:
        return "POST" if "-X" in self.calls[-1] else "GET"

    @property
    def url(self) -> str:
        return self.calls[-1][-1]


class WithFakeKernel(unittest.TestCase):
    def install(self, **kw) -> FakeKernel:
        fake = FakeKernel(**kw)
        real = probes._curl
        probes._curl = fake
        self.addCleanup(lambda: setattr(probes, "_curl", real))
        return fake


# ------------------------------------------------------------------------------------------
class TheRouteGuard(unittest.TestCase):
    """assert_route against the kernel's real dispatch chain, not a transcription."""

    def test_the_table_is_read_from_the_kernel_source(self):
        table = probes.kernel_routes()
        self.assertGreater(len(table), 30, "the scanner found almost nothing; that is a "
                                           "scanner failure, not a kernel without endpoints")
        self.assertEqual(table["set_switches_power_state"], "POST")
        self.assertEqual(table["get_graph_data"], "GET")

    def test_the_query_string_is_not_part_of_the_route(self):
        """The chain matches the path; handlers pull ip/action/state/dpid out afterwards with
        utils::queryParam. A wrong parameter is a 400, a wrong method is a 404."""
        self.assertEqual(probes.route_name("/ndt/historical_logging?state=enable"),
                         "historical_logging")
        self.assertEqual(probes.route_name("/ndt/get_graph_data"), "get_graph_data")

    def test_a_registered_pair_passes(self):
        probes.assert_route("POST", f"/ndt/set_switches_power_state?ip={S1}&action=on")
        probes.assert_route("GET", "/ndt/get_graph_data")
        probes.assert_route("GET", "/ndt/get_switch_openflow_table_entries?dpid=1")

    def test_the_proxy_is_out_of_scope_and_passes(self):
        """A documented gap, not an oversight: this repo does not own Ryu's dispatch table."""
        probes.assert_route("GET", "/stats/flow/1", base=probes.PROXY)
        probes.assert_route("POST", "/p4/readopt/1", base=probes.PROXY)

    def test_harness_bug_is_not_a_notanswered(self):
        """🔴 THE STRUCTURAL PIN. If this ever becomes a subclass, `api_get`/`api_post` absorb
        a wrong-method request into None again and the whole family comes back silently."""
        self.assertFalse(issubclass(probes.HarnessBug, probes.NotAnswered))
        self.assertTrue(issubclass(probes.RouteNotRegistered, probes.HarnessBug))
        self.assertTrue(issubclass(probes.RouteTableUnavailable, probes.HarnessBug))


class ItMustRefuse(WithFakeKernel):
    """Every shape #17 names, refused before a byte goes out."""

    def test_get_at_a_post_only_route_is_refused(self):
        """THE DEFECT. The exact line invariants.py used to carry."""
        with self.assertRaises(probes.RouteNotRegistered) as cm:
            probes.assert_route("GET", "/ndt/set_switches_power_state?dpid=1&action=on")
        self.assertIn("POST", str(cm.exception),
                      "the refusal must name the verb the kernel does register, or the next "
                      "reader has to go find HttpSession.cpp themselves")

    def test_an_unregistered_route_is_refused(self):
        """The third instance's route, now stopped without a round trip."""
        with self.assertRaises(probes.RouteNotRegistered):
            probes.assert_route("GET", "/ndt/get_all_destination_paths")

    def test_the_lenient_wrappers_do_not_swallow_it(self):
        """`api_get` returning None here is the defect itself: None already means "answered,
        with nothing", so a harness bug would score as a real, empty reading."""
        self.install()
        with self.assertRaises(probes.HarnessBug):
            probes.api_get("/ndt/set_switches_power_state?dpid=1&action=on")
        with self.assertRaises(probes.HarnessBug):
            probes.api_post("/ndt/get_all_destination_paths", {})

    def test_nothing_is_sent_when_the_route_is_wrong(self):
        """A wrong-method request costs a real 404 in ~0.007 s, and 'suspiciously fast' is the
        signature INV-01 weighs. Sending it manufactures the evidence."""
        fake = self.install()
        with self.assertRaises(probes.HarnessBug):
            probes.api_get_timed("/ndt/set_switches_power_state?dpid=1&action=on")
        self.assertEqual(fake.calls, [], "curl ran for a route the guard had already refused")

    def test_an_unreadable_route_table_refuses_rather_than_permits(self):
        """"Could not check" must not read as "checked and fine" -- the OVERRIDE_UNREADABLE
        precedent in probes.bmv2_provenance."""
        cached, repo = probes._ROUTES, os.environ.get("NDT_KERNEL_REPO")
        probes._ROUTES = None
        os.environ["NDT_KERNEL_REPO"] = "/nonexistent-repo-for-this-test"
        try:
            with self.assertRaises(probes.RouteTableUnavailable):
                probes.assert_route("GET", "/ndt/get_graph_data")
        finally:
            probes._ROUTES, os.environ["NDT_KERNEL_REPO"] = cached, repo


class Inv01SendsTheRightRequest(WithFakeKernel):
    """The fourth instance, at the call site."""

    def test_it_posts_with_ip_not_gets_with_dpid(self):
        fake = self.install(delay=0.2)
        invariants.inv01_powercycle_latency(S1)
        self.assertEqual(fake.method, "POST",
                         "HttpSession.cpp:189 registers this route under http::verb::post only")
        self.assertIn(f"ip={S1}", fake.url,
                      "handleSetSwitchesPowerState reads utils::queryParam(target, \"ip\")")
        self.assertNotIn("dpid=", fake.url,
                         "dpid is not a parameter this handler reads; it answers 400 without ip")

    def test_a_refusal_is_never_reported_as_an_early_return(self):
        """🔴 THE HEART OF #17. 404, 405, 400 and 500 all come back fast. None of them is
        evidence that the kernel returned early having skipped the work."""
        for status in (404, 405, 400, 500):
            with self.subTest(status=status):
                self.install(status=status, body='{"error":"Missing or invalid ip/action"}')
                f = invariants.inv01_powercycle_latency(S1)
                self.assertEqual(f.verdict, invariants.SKIPPED,
                                 f"HTTP {status} produced {f.verdict}: {f.detail}")
                self.assertNotIn("A-1", f.detail,
                                 "a refused request must not be described in the vocabulary of "
                                 "the defect this invariant hunts")
                self.assertNotIn("early return", f.detail)

    def test_a_transport_failure_is_also_skipped_not_accused(self):
        real = probes._curl
        probes._curl = lambda argv, stdin=None: (7, "", "connection refused")
        self.addCleanup(lambda: setattr(probes, "_curl", real))
        f = invariants.inv01_powercycle_latency(S1)
        self.assertEqual(f.verdict, invariants.SKIPPED)
        self.assertNotIn("A-1", f.detail)


class ItMustStillFire(WithFakeKernel):
    """🔴 The other direction. A fix that turns INV-01 into a constant SKIPPED passes every
    case above and detects nothing -- the same trade the harness already made once, when a
    guard added to INV-06 swallowed its own positive control."""

    def test_a_genuine_fast_success_is_still_a_finding(self):
        """A 2xx in well under 1.27 s IS the A-1 fingerprint, and must still be reported."""
        self.install(status=200, body='{"192.168.123.11":"Success"}', delay=0.0)
        f = invariants.inv01_powercycle_latency(S1)
        self.assertEqual(f.verdict, invariants.FAIL,
                         "the invariant lost its resolving power: a real A-1 reproduction is "
                         "now reported as SKIPPED")
        self.assertIn("A-1", f.detail)

    def test_an_honest_slow_success_passes(self):
        self.install(status=200, body='{"192.168.123.11":"Success"}', delay=0.2)
        f = invariants.inv01_powercycle_latency(S1)
        self.assertEqual(f.verdict, invariants.PASS, f.detail)

    def test_the_three_verdicts_are_actually_distinct(self):
        """Belt and braces: a constant of ANY value would satisfy one case above."""
        seen = set()
        for kw in (dict(status=200, delay=0.0), dict(status=200, delay=0.2),
                   dict(status=404, delay=0.0)):
            self.install(body='{"192.168.123.11":"Success"}', **kw)
            seen.add(invariants.inv01_powercycle_latency(S1).verdict)
        self.assertEqual(seen, {invariants.FAIL, invariants.PASS, invariants.SKIPPED},
                         f"INV-01 produced {seen} across three genuinely different inputs")


class ToleratedAbsence(WithFakeKernel):
    """🔴 The over-correction control. "Refuse every non-200" is a real temptation here and it
    breaks two callers that tolerate one deliberately. These cases must stay GREEN."""

    def test_a_legitimate_404_still_comes_back_as_none(self):
        """A flow or switch that is not there is a state, not a harness bug. The lenient
        readers exist for it and must keep absorbing it."""
        self.install(status=404, body="")
        self.assertIsNone(probes.api_get("/ndt/get_switch_openflow_table_entries?dpid=99"))
        self.assertIsNone(probes.api_post("/ndt/historical_logging?state=enable", {}))

    def test_inv03_skips_rather_than_accuses_when_a_table_is_unreadable(self):
        """INV-03 reads a registered route that legitimately answers nothing. Scoring that as
        'the cache diverged' would be a false positive produced by the gate, not the data."""
        self.install(status=404, body="")
        f = invariants.inv03_flow_table_identity(invariants.Context(), 1)
        self.assertEqual(f.verdict, invariants.SKIPPED, f.detail)

    def test_the_b3_control_still_refuses_a_500_by_saying_it_did_not_land(self):
        """500 is a documented answer for historical_logging (no HistoricalDataManager) and it
        is NOT the defect. _c07_apply must refuse, and must do it as a refusal."""
        self.install(status=500, body='{"error":"no manager"}')
        r = actions._c07_apply(dry=False)
        self.assertFalse(r.ok)
        self.assertIn("did not land", r.detail)

    def test_a_registered_route_is_never_refused_by_the_guard(self):
        """If assert_route ever refuses what the kernel serves, the harness stops working and
        the report says the kernel is broken."""
        fake = self.install(status=200, body="{}")
        probes.api_get("/ndt/get_graph_data")
        probes.api_post("/ndt/acquire_lock", {"type": "power_lock"})
        self.assertEqual(len(fake.calls), 2, "a registered route was blocked before curl")


# ------------------------------------------------------------------------------------------
# Completeness: re-derive the call list instead of trusting a hand-written table.
# ------------------------------------------------------------------------------------------
# Everything in probes.py that ultimately issues a request, and the method it issues.
WRAPPER_METHOD = {
    "api_get_checked": "GET", "api_get": "GET", "api_get_timed": "GET",
    "api_post_checked": "POST", "api_post": "POST", "api_post_timed": "POST",
    "api_post_checked_timed": "POST",
}
# Convenience readers whose path is fixed inside probes.py.
FIXED_PATH = {
    "graph_data": ("GET", "/ndt/get_graph_data"),
    "flow_data": ("GET", "/ndt/get_detected_flow_data"),
    "acquire_lock": ("POST", "/ndt/acquire_lock"),
    "release_lock": ("POST", "/ndt/release_lock"),
    "renew_lock": ("POST", "/ndt/renew_lock"),
}

# Call sites that deliberately name a route the kernel does not register, with the reason.
# Same idiom, and the same purpose, as KNOWN_MISSING_ENDPOINTS in tools/contract_test/
# components.py: a known gap is written down so that a NEW one fails the check instead of
# being lost among the ones already tolerated. Removing the call deletes the entry.
#
# 🔴 An entry here buys ONE thing only -- exemption from the conformance sweep. It does not
# exempt the call from refusing: `_h23_verify` still has to catch the refusal and still has to
# report NOT-ANSWERED rather than a verdict, which `test_an_unregistered_route_is_refused`
# and the fixed `_h23_verify` both pin. An allowlist that let a call proceed would reinstate
# the third instance of the family this file exists for.
KNOWN_UNREGISTERED = {
    ("actions.py", "/ndt/get_all_destination_paths"): (
        "efd2fe10 (#17, third instance). The kernel exposes no such endpoint at all, so this "
        "read always 404'd and `n` fell to 0, and _h23_verify reported 'the path map was "
        "wiped' on every run. It now calls api_get_checked and REFUSES. Naming the route it "
        "should read instead is a separate ticket -- the proxy's "
        "/ryu_server/all_destination_paths is a different population, not a replacement."
    ),
}


def _module_constants(tree: ast.Module) -> dict[str, str]:
    """Module-level `NAME = "literal"`, so a path held in a variable still resolves.

    HISTORICAL_LOGGING is the case that makes this necessary: actions.py deliberately spells
    that route once and interpolates it at three call sites, and a grep for "/ndt/" finds none
    of the three.
    """
    out: dict[str, str] = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) \
                and isinstance(node.value.value, str):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    out[t.id] = node.value.value
    return out


def _static_path(node: ast.AST, consts: dict[str, str]) -> str | None:
    """The path argument as a string, or None if it cannot be resolved statically.

    Only the part before `?` has to resolve: the query is not part of the route. So
    f"{HISTORICAL_LOGGING}?state=enable" resolves and f"/ndt/x?dpid={dpid}" does too.
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        parts = []
        for v in node.values:
            if isinstance(v, ast.Constant):
                parts.append(str(v.value))
            elif isinstance(v, ast.FormattedValue) and isinstance(v.value, ast.Name) \
                    and v.value.id in consts:
                parts.append(consts[v.value.id])
            else:
                parts.append("\x00")           # unresolved
        joined = "".join(parts)
        head = joined.split("?", 1)[0]
        return joined if "\x00" not in head else None
    return None


def harness_http_calls() -> list[dict]:
    """Every HTTP call site in the harness, by AST.

    Deliberately not grep. The four ways grep is wrong here are all present in this harness:
    a route held in a module constant (HISTORICAL_LOGGING, 3 sites), f-string interpolation
    (7 sites), wrapper functions that hide the path entirely (graph_data, flow_data and the
    three lock helpers, 16 sites), and a raw subprocess argv that never mentions the wrapper
    names at all (_h5_apply).

    probes.py itself is excluded as the chokepoint's own implementation: its four delegating
    wrappers take the path as a parameter, and its fixed-path readers are resolved through
    FIXED_PATH at their call sites instead.
    """
    found: list[dict] = []
    for fn in sorted(os.listdir(HARNESS)):
        if not fn.endswith(".py") or fn == "probes.py":
            continue
        path = os.path.join(HARNESS, fn)
        with open(path, encoding="utf-8") as fh:
            tree = ast.parse(fh.read(), filename=fn)
        consts = _module_constants(tree)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            f = node.func
            name = f.attr if isinstance(f, ast.Attribute) else (
                f.id if isinstance(f, ast.Name) else None)
            base = "KERNEL"
            for kw in node.keywords:
                if kw.arg == "base":
                    base = ast.unparse(kw.value)
            if name in FIXED_PATH:
                method, p = FIXED_PATH[name]
                found.append(dict(file=fn, line=node.lineno, call=name,
                                  method=method, path=p, base=base, resolved=True))
            elif name in WRAPPER_METHOD:
                method = WRAPPER_METHOD[name]
                npos = 3 if method == "POST" else 2
                if len(node.args) >= npos:
                    base = ast.unparse(node.args[npos - 1])
                p = _static_path(node.args[0], consts) if node.args else None
                found.append(dict(file=fn, line=node.lineno, call=name, method=method,
                                  path=p, base=base, resolved=p is not None))
            # a raw curl argv, which bypasses probes._request entirely
            for a in node.args:
                if isinstance(a, ast.List):
                    lits = [e.value for e in a.elts if isinstance(e, ast.Constant)]
                    if lits and lits[0] == "curl":
                        url = _static_path(a.elts[-1], {**consts, "probes.KERNEL": ""})
                        found.append(dict(file=fn, line=node.lineno, call="raw curl",
                                          method="POST" if "-X" in lits else "GET",
                                          path=url, base="KERNEL", resolved=False, raw=True))
    return found


class TheWholeHarnessConforms(unittest.TestCase):
    """🔴 #17 named one line. This class is why a sixth instance cannot hide.

    The finding recorded a third and a fourth example of the family. A fifth was sitting in
    `actions.py:_c01_undo` and no finding mentions it -- it was found by enumerating the call
    sites rather than by reading the one the finding pointed at. So the enumeration is the
    deliverable, and it runs on every invocation of this file.
    """

    def test_the_inventory_is_not_empty(self):
        """A conformance check over zero call sites is a green light that means nothing."""
        calls = harness_http_calls()
        self.assertGreater(len(calls), 20,
                           f"only {len(calls)} call sites found; the walker has stopped seeing "
                           f"the harness and every conformance result below is vacuous")

    def test_every_kernel_path_resolves_statically(self):
        """"Could not check" is not "checked and fine". A KERNEL call whose route cannot be
        read here is reported, not skipped.

        Proxy calls are excluded because they are out of scope for the guard, not because they
        are fine: `/stats/flow/{dpid}` does not resolve and nothing in this repo could check it
        if it did. That gap is in FIX-CHAOS-INVARIANTS.md §6.
        """
        unresolved = [c for c in harness_http_calls()
                      if not c["resolved"] and not c.get("raw") and c["base"] == "KERNEL"]
        self.assertEqual(unresolved, [],
                         "these call sites hide their route from static reading, so nothing "
                         "below verified them")

    def test_every_kernel_call_uses_a_registered_method(self):
        """The table in FIX-CHAOS-INVARIANTS.md, executable."""
        bad = []
        for c in harness_http_calls():
            if c["base"] != "KERNEL" or c["path"] is None:
                continue
            if (c["file"], c["path"]) in KNOWN_UNREGISTERED:
                continue
            try:
                probes.assert_route(c["method"], c["path"])
            except probes.RouteNotRegistered as e:
                bad.append(f"{c['file']}:{c['line']} {c['call']} -- {e}")
        self.assertEqual(bad, [], "\n".join(bad))

    def test_the_allowlist_still_describes_real_call_sites(self):
        """An allowlist entry for a call nobody makes any more is a tolerance nobody granted,
        and it would silently cover a NEW call that reused the same route."""
        live = {(c["file"], c["path"]) for c in harness_http_calls()}
        stale = [k for k in KNOWN_UNREGISTERED if k not in live]
        self.assertEqual(stale, [], f"{stale} is allowlisted but no longer called; delete it")

    def test_the_allowlist_covers_only_genuinely_unregistered_routes(self):
        """The other direction: an entry must not be quietly hiding a route that IS registered
        under another verb -- that is instance one through five, not a documented gap."""
        table = probes.kernel_routes()
        wrong = [k for k in KNOWN_UNREGISTERED if probes.route_name(k[1]) in table]
        self.assertEqual(wrong, [],
                         f"{wrong} names a route the kernel DOES register; that is a method "
                         f"defect to fix, not a gap to tolerate")

    def test_the_one_chokepoint_bypass_asserts_its_own_route(self):
        """_h5_apply must build a non-JSON body, so it cannot go through probes._request and
        the guard there cannot cover it. A hole in a chokepoint is only safe while it is
        marked, and this is the marker."""
        with open(os.path.join(HARNESS, "actions.py"), encoding="utf-8") as fh:
            tree = ast.parse(fh.read())
        holes = []
        for fn in ast.walk(tree):
            if not isinstance(fn, ast.FunctionDef):
                continue
            body = ast.unparse(fn)
            if "'curl'" in body or '"curl"' in body:
                if "assert_route" not in body:
                    holes.append(fn.name)
        self.assertEqual(holes, [],
                         f"{holes} shells out to curl without calling probes.assert_route, so "
                         f"the route guard does not cover it")

    def test_no_alternate_http_client_exists(self):
        """The completeness argument rests on probes._request being the only way out. An
        `import requests` anywhere would silently end that."""
        offenders = []
        for fn in sorted(os.listdir(HARNESS)):
            if not fn.endswith(".py"):
                continue
            with open(os.path.join(HARNESS, fn), encoding="utf-8") as fh:
                tree = ast.parse(fh.read())
            for node in ast.walk(tree):
                names = []
                if isinstance(node, ast.Import):
                    names = [a.name for a in node.names]
                elif isinstance(node, ast.ImportFrom):
                    names = [node.module or ""]
                for n in names:
                    if n.split(".")[0] in {"requests", "urllib", "httpx", "aiohttp", "socket"}:
                        offenders.append(f"{fn}:{node.lineno} imports {n}")
        self.assertEqual(offenders, [], "\n".join(offenders))


if __name__ == "__main__":
    unittest.main(verbosity=2)
