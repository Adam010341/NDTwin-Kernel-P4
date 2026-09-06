#!/usr/bin/env python3
"""
L2 contract test for the NDTwin kernel's /ndt/* HTTP API.

Every tool and app in the workspace talks to the kernel only through this API, so
verifying it here verifies the foundation all of them stand on. See
doc/2026-07-27_testing_workflow.md for how this fits the wider test layers.

Checks three things per endpoint:
  1. structure  -- valid JSON, right fields, right types
  2. invariants -- values are consistent with the topology file and with each other
  3. error path -- bad input yields a sane 4xx rather than a 500 or a fake 200

Usage
-----
  # read-only checks (safe against a running system)
  ./run_contract_test.py --topology setting/StaticNetworkTopologyP4_10Switches_4Hosts.json

  # after starting traffic, also require flows/paths/rates to be present
  ./run_contract_test.py --topology <file> --with-traffic

  # include endpoints that change flow rules or power state
  ./run_contract_test.py --topology <file> --allow-mutations

  # verify the schemas themselves against the examples in doc/2026-01-02_ndt_api.md
  ./run_contract_test.py --self-test

Exit code
---------
  0  every selected check passed
  1  at least one check FAILED -- a claim about the system
  2  usage error (no topology, no matching checks)
  3  TOOL-PRECONDITION-FAILED -- the suite could not establish what it needed to know
     before judging, so it makes no claim about the system. Distinct from 1 on purpose:
     a tool must never be able to fail in a way that looks like the system failing
     (KNOWN-ISSUES A-8). Callers that only test `rc != 0` still fail closed.
     [Co-developed with claude code -- Adam]

[Co-developed with claude code -- Adam]
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import spec  # noqa: E402
from schema import validate  # noqa: E402
from spec import (  # noqa: E402
    ERRORPATH,
    MUTATE,
    READ,
    PowerState,
    classify_power_state,
    endpoints_by_category,
    partition_messages,
)

# Re-exported: PowerState and classify_power_state live in spec.py (pure, importable by the
# fixtures without pulling in the runner), but l3_component_check.py and the tests have
# always reached for run_contract_test for runner-side names.
# [Co-developed with claude code -- Adam]
__all__ = ["PowerState", "classify_power_state", "probe_power_state", "Context", "Palette",
           "Result", "check_endpoint", "request", "supports_colour", "EXIT_PRECONDITION"]

RESET, RED, GREEN, YELLOW, DIM = "\033[0m", "\033[31m", "\033[32m", "\033[33m", "\033[2m"

#: Exit code for "the suite could not establish its own preconditions". See the module
#: docstring. [Co-developed with claude code -- Adam]
EXIT_PRECONDITION = 3

#: The endpoint that answers "which switches has the operator deliberately powered down?".
#: Already part of the contract table (spec.py get_switches_power_state); read once up front
#: because the graph invariants need the answer before the table reaches it.
POWER_STATE_PATH = "/ndt/get_switches_power_state"


def supports_colour() -> bool:
    return sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


class Palette:
    def __init__(self, enabled: bool):
        self.on = enabled

    def _w(self, code, s):
        return f"{code}{s}{RESET}" if self.on else s

    def red(self, s):
        return self._w(RED, s)

    def green(self, s):
        return self._w(GREEN, s)

    def yellow(self, s):
        return self._w(YELLOW, s)

    def dim(self, s):
        return self._w(DIM, s)


def probe_power_state(base_url, ctx, timeout) -> PowerState:
    """Read POWER_STATE_PATH once, before the endpoint table runs. [Co-developed ... -- Adam]"""
    ep = {"name": "probe_power_state", "method": "GET", "path": POWER_STATE_PATH,
          "category": READ}
    status, data, err = request(base_url, ep, ctx, timeout)
    if err:
        return PowerState.unknown(f"{POWER_STATE_PATH}: {err}")
    if status != 200:
        return PowerState.unknown(f"{POWER_STATE_PATH} answered HTTP {status}")
    return classify_power_state(data, ctx.switch_ip_to_dpid)


class Context:
    """
    Expectations derived from the topology file rather than hardcoded.

    Point the runner at a different topology and the invariants adapt, which is what
    lets the same suite validate both the OVS (10 switches / 128 hosts) and P4
    (10 switches / 4 hosts) environments.
    """

    def __init__(self, topology_path: str, topk: int, probe_ip: str):
        with open(topology_path) as fh:
            topo = json.load(fh)

        nodes = topo["nodes"]
        switches = [n for n in nodes if n.get("vertex_type") == 0]
        hosts = [n for n in nodes if n.get("vertex_type") == 1]

        self.topology_path = topology_path
        self.expected_switches = len(switches)
        self.expected_hosts = len(hosts)
        self.expected_edges = len(topo.get("edges", []))
        self.expected_dpids = {s["dpid"] for s in switches}
        self.brand_names = sorted({s.get("brand_name", "") for s in switches})
        self.topk = topk
        self.probe_ip = probe_ip

        # [Co-developed with claude code -- Adam] -- W3b-3, 2026-09-07.
        # Per-node identity, so inv_graph_matches_topology can answer "is this the right
        # network" and not only "is it the right size". Switches are keyed by dpid; hosts by
        # mac, because every host carries dpid 0 and device_name is the field a rename moves.
        # Built here rather than in spec.py so the invariant stays pure and testable, and built
        # UNCONDITIONALLY: an invariant that silently does less when an expectation is missing
        # is the shape this suite has already been burned by, so spec.py's fallback is for
        # hand-built stand-ins only and tests/python/test_contract_spec.py pins that the real
        # Context never takes it.
        #
        # 🔴 Both maps are keyed, and a key that repeats in the FILE silently loses a node --
        # the last one written wins and the comparison then runs against a node that is not
        # there. Doing an unreliable comparison quietly is the failure this whole check exists
        # to remove, so a repeated key means the map is not built at all and the invariant is
        # told WHY. That is a TOOL-PRECONDITION (a fact about the model handed in), never a
        # verdict about the kernel.
        self.expected_switch_identity, self.switch_identity_unavailable = self._identity(
            switches, "dpid", "switch", lambda s: s["dpid"],
            lambda s: {"device_name": s.get("device_name", ""),
                       "brand_name": s.get("brand_name", ""),
                       "ips": spec.address_set(s)})
        self.expected_host_identity, self.host_identity_unavailable = self._identity(
            hosts, "mac", "host", lambda h: h.get("mac"),
            lambda h: {"device_name": h.get("device_name", ""),
                       "ips": spec.address_set(h)})

        # [Co-developed with claude code -- Adam] -- A-8.
        # /ndt/get_switches_power_state is keyed by IPv4 string, the graph by dpid. This is
        # the join, and it comes from the topology file so it needs no kernel to build.
        self.switch_ip_to_dpid = {}
        for s in switches:
            switch_ip = self._first_ip(s)
            if switch_ip:
                self.switch_ip_to_dpid[switch_ip] = s["dpid"]

        # Replaced by probe_power_state() before the endpoint table runs. Until then the
        # reading is UNKNOWN -- deliberately not "everything is on", which is the assumption
        # that produced A-8. A caller that constructs a Context and skips the probe gets
        # TOOL-PRECONDITION-FAILED on a degraded fabric, not a wrong answer.
        self.power_state = PowerState.unknown("the runner has not read it yet")

        # A switch dpid to use for per-switch queries. min() keeps runs reproducible.
        self.a_dpid = min(self.expected_dpids) if self.expected_dpids else 1

        # The chosen switch's current name and IP, read from the topology so that
        # mutating checks can write back what is already there instead of changing it.
        # modify_device_name persists to the topology JSON, so sending a different name
        # would edit a file on disk; set_switches_power_state can cut a real device.
        chosen = next((s for s in switches if s.get("dpid") == self.a_dpid), None) or {}
        self.original_device_name = chosen.get("device_name", "s1")
        # Same reasoning for the nickname: it is its own topology field, so write back
        # what is there rather than branding a switch after a test run.
        self.original_nickname = chosen.get("nickname", self.original_device_name)
        self.a_switch_ip = self._first_ip(chosen) or "127.0.0.1"

        # Two host IPs for path queries. Topology stores IPs as network-order uint32.
        host_ips = [self._first_ip(h) for h in hosts]
        host_ips = [ip for ip in host_ips if ip]
        self.src_host_ip = host_ips[0] if host_ips else "10.0.0.1"
        self.dst_host_ip = host_ips[-1] if len(host_ips) > 1 else "10.0.0.2"

    @staticmethod
    def _identity(nodes, key_field, kind, key_of, value_of):
        """(map from key to identity, or (None, why the file cannot supply one)).

        [Co-developed with claude code -- Adam] -- W3b-3.
        """
        keys = [key_of(n) for n in nodes]
        repeated = sorted({k for k in keys if keys.count(k) > 1}, key=repr)
        if repeated:
            return None, (f"the topology file gives more than one {kind} the same "
                          f"{key_field} ({repeated}), so per-{kind} identity cannot be "
                          f"established from it; the counts and the graph's own duplicate "
                          f"check still apply")
        return {key_of(n): value_of(n) for n in nodes}, None

    @staticmethod
    def _first_ip(node) -> str | None:
        # Topology JSON stores network order, i.e. first octet in the low byte. The decoding
        # is spec.dotted_ip's, not a second copy of it: inv_graph_matches_topology compares
        # the two sides with that function, and a Context that normalised addresses even
        # slightly differently would make the comparison find a difference on every node of a
        # healthy fabric. [Co-developed with claude code -- Adam]
        ips = node.get("ip") or []
        if not ips:
            return None
        return spec.dotted_ip(ips[0])

    def describe(self) -> str:
        return (f"{os.path.basename(self.topology_path)}: "
                f"{self.expected_switches} switches ({'/'.join(self.brand_names) or 'unknown'}), "
                f"{self.expected_hosts} hosts, {self.expected_edges} edges")


class Result:
    def __init__(self, name, ok, failures=None, status=None, skipped=False, note=None,
                 known_gap=None, gap_closed=False, data=None,
                 preconditions=None, accounted_for=None):
        self.name = name
        self.ok = ok
        self.failures = failures or []
        # [Co-developed with claude code -- Adam] -- A-8.
        # `preconditions` is the check saying it could not establish what it needed before
        # judging; it is NOT a claim that the system is broken, and it is reported and
        # exit-coded separately for that reason. `accounted_for` is the opposite end: a
        # deviation the run can explain, printed so it is never silently swallowed -- the
        # same "the note travels with it" rule l3_component_check.py already applies to a 503.
        self.preconditions = preconditions or []
        self.accounted_for = accounted_for or []
        self.status = status
        self.skipped = skipped
        self.note = note
        # A recorded kernel defect: the check legitimately fails, so it reports yellow
        # rather than red. Same principle as the log and baseline allowlists -- a known
        # problem must not mask a new one by keeping the suite permanently red.
        self.known_gap = known_gap
        # Set when a check with a known_gap unexpectedly PASSES, i.e. the defect was
        # fixed and the marker should be deleted.
        self.gap_closed = gap_closed
        # The parsed response, kept so --save-json does not have to request again.
        self.data = data


def resolve(value, ctx):
    return value(ctx) if callable(value) else value


def request(base_url, ep, ctx, timeout) -> tuple[int, object, str | None]:
    """Returns (status, parsed_json_or_None, transport_error)."""
    url = base_url.rstrip("/") + ep["path"]
    query = resolve(ep.get("query"), ctx)
    if query:
        url += "?" + urllib.parse.urlencode(query)

    data, headers = None, {"User-Agent": "ndt-contract-test/1.0"}
    if "raw_body" in ep:
        data = ep["raw_body"].encode()
        headers["Content-Type"] = "application/json"
    elif ep.get("body") is not None:
        data = json.dumps(resolve(ep["body"], ctx)).encode()
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=ep["method"])
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            status = resp.status
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        status = exc.code
    except urllib.error.URLError as exc:
        return 0, None, f"cannot reach kernel: {exc.reason}"
    except (TimeoutError, socket.timeout):
        # socket.timeout only became an alias of TimeoutError in Python 3.10; catch
        # both so this works on the 3.8 interpreter the Ryu environment pins.
        return 0, None, f"timed out after {timeout}s"

    if not raw.strip():
        return status, None, "empty response body"
    try:
        return status, json.loads(raw), None
    except json.JSONDecodeError as exc:
        preview = raw[:120] + ("..." if len(raw) > 120 else "")
        return status, None, f"response is not valid JSON ({exc}); body starts: {preview!r}"


def check_endpoint(base_url, ep, ctx, args) -> Result:
    status, data, transport_err = request(base_url, ep, ctx, args.timeout)
    name = ep["name"]
    gap = ep.get("known_gap")

    def finish(_ok_hint, messages):
        """
        Splits the invariant output three ways, then applies known-gap handling.

        [Co-developed with claude code -- Adam] -- A-8.
        The split comes first because a TOOL-PRECONDITION-FAILED message is not a claim
        about the kernel, so it must not be excused by a known_gap (there is nothing to
        excuse) and must not be counted as a contract failure (there is no verdict). An
        ACCOUNTED-FOR message is a deviation the run can explain: it is printed, and it does
        not fail the check.

        A known_gap excuses only the specific shortcoming it documents -- a wrong-but-sane
        response. It must NOT excuse the kernel throwing (5xx) or being unreachable:
        marking those as an accepted gap would hide a crashed or hung kernel behind a
        yellow tick, which is the opposite of the point.
        """
        failures, preconditions, accounted = partition_messages(messages)
        # Derived, not taken from the caller: every call site passes `not failures` anyway,
        # and after the split an ACCOUNTED-FOR-only message list must read as a pass, which
        # the caller's pre-split hint gets wrong. _ok_hint is kept only so the call sites
        # still read as statements of intent. [Co-developed with claude code -- Adam]
        ok = not failures

        def build(res_ok, res_failures, **kw):
            return Result(name, res_ok, res_failures, status, note=ep.get("note"),
                          data=data, preconditions=preconditions, accounted_for=accounted,
                          **kw)

        if preconditions and not failures:
            # No verdict on the system: neither a pass nor a contract failure.
            return build(False, [])

        if gap:
            if ok:
                # The defect was fixed: say so loudly rather than staying quiet.
                return build(True, [], known_gap=gap, gap_closed=True)

            unexcusable = None
            if status == 0:
                unexcusable = "the kernel did not respond"
            elif status >= 500:
                unexcusable = f"the kernel returned {status}"
            if unexcusable:
                return build(False,
                             failures + [f"not excused by the known gap: {unexcusable}"],
                             known_gap=gap)

            return build(True, failures, known_gap=gap)
        return build(ok, failures)

    expected = ep.get("expect_status", [200])
    if status not in expected:
        got = "no response" if status == 0 else str(status)
        msg = f"HTTP status {got}, expected {' or '.join(map(str, expected))}"
        if transport_err:
            msg += f" ({transport_err})"
        # A 500 on an error-path check is the specific thing we are hunting.
        if status >= 500:
            msg += " -- a 5xx means an unhandled exception, not input validation"
        return finish(False, [msg])

    # Error-path checks care only about the status code.
    if ep["category"] == ERRORPATH:
        return finish(True, [])

    if transport_err:
        return finish(False, [transport_err])

    failures = validate(ep["schema"], data)
    if failures:
        return finish(False, failures)

    invariants = list(ep.get("invariants", []))
    if args.with_traffic:
        invariants += ep.get("traffic_invariants", [])
    for inv in invariants:
        try:
            failures.extend(inv(data, ctx))
        except Exception as exc:  # an invariant itself blowing up is a test bug
            failures.append(f"invariant {inv.__name__} raised {type(exc).__name__}: {exc}")

    return finish(not failures, failures)


def run_self_test(pal: Palette) -> int:
    """
    Validate the schemas against the examples in doc/2026-01-02_ndt_api.md.

    This is what makes the suite trustworthy without a running kernel: if a schema
    rejects the documented example, the schema is wrong.
    """
    import selftest_fixtures as fx

    print("Self-test: validating schemas against doc/2026-01-02_ndt_api.md examples\n")
    passed = failed = 0
    for name, (schema, sample) in fx.FIXTURES.items():
        errs = validate(schema, sample)
        if errs:
            failed += 1
            print(f"  {pal.red('FAIL')}  {name}")
            for e in errs:
                print(f"          {e}")
        else:
            passed += 1
            print(f"  {pal.green('ok')}    {name}")

    print(f"\n  Invariants against documented/synthetic data:")
    for name, fn, data, ctx, expect_failures in fx.INVARIANT_CASES:
        got = fn(data, ctx)
        # [Co-developed with claude code -- Adam] -- A-8.
        # `bool(got)` alone would let a TOOL-PRECONDITION-FAILED message satisfy a case that
        # was written to assert a real failure -- the same "a red light is not an identity"
        # trap the mutation gate exists for. Only unprefixed messages count as failures here.
        real_failures, _pre, _acc = partition_messages(got)
        ok = bool(real_failures) == expect_failures
        if ok:
            passed += 1
            if real_failures:
                detail = f" (correctly reported: {real_failures[0][:70]})"
            elif got:
                detail = f" (no failure; said: {got[0][:70]})"
            else:
                detail = ""
            print(f"  {pal.green('ok')}    {name}{pal.dim(detail)}")
        else:
            failed += 1
            print(f"  {pal.red('FAIL')}  {name}: "
                  f"expected {'failures' if expect_failures else 'no failures'}, got {got}")

    print(f"\n{'=' * 70}")
    if failed:
        print(pal.red(f"Self-test FAILED: {failed} problem(s), {passed} ok"))
        return 1
    print(pal.green(f"Self-test passed: {passed} checks"))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="L2 contract test for the NDTwin kernel /ndt/* API",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default=os.environ.get("NDT_API_URL", "http://localhost:8000"),
                    help="kernel base URL (default: %(default)s)")
    ap.add_argument("--topology", help="topology JSON the kernel was started with; "
                                       "invariant expectations are derived from it")
    ap.add_argument("--with-traffic", action="store_true",
                    help="also require flows, non-empty paths and non-zero rates")
    ap.add_argument("--allow-mutations", action="store_true",
                    help="include endpoints that change flow rules / power / names")
    ap.add_argument("--timeout", type=float, default=10.0, help="per-request timeout (s)")
    ap.add_argument("--topk", type=int, default=5, help="k for get_detected_top_k_flow_data")
    ap.add_argument("--probe-ip", default="10.255.255.254",
                    help="dst IP for probe flow rules; must not collide with real hosts")
    ap.add_argument("--save-json", metavar="DIR",
                    help="write each response to DIR (baseline capture for OVS/P4 diffing)")
    ap.add_argument("--only", metavar="NAME", action="append",
                    help="run only the named check(s); repeatable")
    ap.add_argument("--self-test", action="store_true",
                    help="validate the schemas against doc/2026-01-02_ndt_api.md examples and exit")
    args = ap.parse_args()

    pal = Palette(supports_colour())

    if args.self_test:
        return run_self_test(pal)

    if not args.topology:
        ap.error("--topology is required (or use --self-test)")
    if not os.path.exists(args.topology):
        print(pal.red(f"topology file not found: {args.topology}"))
        return 2

    ctx = Context(args.topology, args.topk, args.probe_ip)
    # [Co-developed with claude code -- Adam] -- A-8.
    # Read the power state before anything judges the graph. get_switches_power_state is
    # already in the endpoint table, but it sits *after* get_graph_data in declaration order,
    # so the graph invariants would reach their verdict before the answer existed.
    ctx.power_state = probe_power_state(args.url, ctx, args.timeout)

    categories = [READ, ERRORPATH] + ([MUTATE] if args.allow_mutations else [])
    endpoints = endpoints_by_category(categories)
    if args.only:
        endpoints = [e for e in endpoints if e["name"] in set(args.only)]
        if not endpoints:
            print(pal.red(f"no checks match --only {args.only}"))
            return 2

    print(f"NDTwin L2 contract test")
    print(f"  kernel   : {args.url}")
    print(f"  topology : {ctx.describe()}")
    print(f"  traffic  : {'expected' if args.with_traffic else 'not expected'}")
    print(f"  mutations: {'included' if args.allow_mutations else 'skipped'}")
    print(f"  power    : {ctx.power_state.describe()}")
    print(f"  checks   : {len(endpoints)}\n")

    if args.save_json:
        os.makedirs(args.save_json, exist_ok=True)

    results = []
    started = time.time()
    for ep in endpoints:
        res = check_endpoint(args.url, ep, ctx, args)
        results.append(res)

        # Reuse the response the check already fetched. Requesting again would double
        # every mutation under --allow-mutations, and would capture acquire_lock's
        # *conflict* reply rather than the successful one.
        if args.save_json and ep["category"] != ERRORPATH:
            with open(os.path.join(args.save_json, f"{ep['name']}.json"), "w") as fh:
                json.dump(res.data, fh, indent=2, sort_keys=True)

        # [Co-developed with claude code -- Adam] -- A-8: PRECOND is its own tag, checked
        # before FAIL, so "the tool could not decide" never renders as "the system is broken".
        if res.gap_closed:
            tag = pal.yellow("FIXED")
        elif res.preconditions and not res.failures:
            tag = pal.yellow("PRECOND")
        elif res.known_gap and res.failures:
            tag = pal.yellow("GAP ")
        elif res.ok:
            tag = pal.green("PASS")
        else:
            tag = pal.red("FAIL")
        status = f"[{res.status}]" if res.status else "[---]"
        print(f"  {tag} {status:6} {res.name}")

        if res.gap_closed:
            print(f"           {pal.yellow('this known gap now PASSES')} — remove the "
                  f"known_gap marker from spec.py")
            print(f"           {pal.dim('was: ' + res.known_gap)}")
        elif res.failures:
            for f in res.failures:
                marker = pal.yellow('-') if res.known_gap else pal.red('-')
                print(f"           {marker} {f}")
            if res.known_gap:
                print(f"           {pal.dim('known kernel gap: ' + res.known_gap)}")
            elif res.note:
                print(f"           {pal.dim('note: ' + res.note)}")

        for p in res.preconditions:
            print(f"           {pal.yellow('?')} {p}")
        # Printed on every result, pass or fail: an explained deviation that nobody sees is
        # indistinguishable from no deviation at all.
        for a in res.accounted_for:
            print(f"           {pal.dim('accounted for: ' + a)}")

    elapsed = time.time() - started
    failed = [r for r in results if not r.ok and not (r.preconditions and not r.failures)]
    blocked = [r for r in results if r.preconditions and not r.failures]
    gaps = [r for r in results if r.known_gap and r.failures and not r.gap_closed]
    fixed = [r for r in results if r.gap_closed]

    print(f"\n{'=' * 70}")
    print(f"{len(results) - len(failed) - len(blocked)}/{len(results)} passed in {elapsed:.1f}s")
    if gaps:
        print(pal.yellow(f"{len(gaps)} known kernel gap(s) (not counted as failures): "
                         f"{', '.join(r.name for r in gaps)}"))
    if fixed:
        print(pal.yellow(f"{len(fixed)} known gap(s) now pass — remove their markers: "
                         f"{', '.join(r.name for r in fixed)}"))
    if failed:
        print(pal.red(f"\nFAILED checks: {', '.join(r.name for r in failed)}"))
        if not args.with_traffic:
            print(pal.dim("\nhint: flow/path/rate checks are skipped without --with-traffic;"
                          " start traffic and re-run to cover the telemetry path"))
        return 1
    if blocked:
        # Deliberately not the word FAIL and deliberately not exit 1: this run makes no
        # claim about the kernel. [Co-developed with claude code -- Adam]
        print(pal.yellow(f"\nTOOL-PRECONDITION-FAILED: "
                         f"{', '.join(r.name for r in blocked)}"))
        print(pal.dim("  These checks could not establish what they needed before judging, "
                      "so they judged nothing."))
        print(pal.dim(f"  Power state: {ctx.power_state.describe()}"))
        return EXIT_PRECONDITION
    print(pal.green("\nAll contract checks passed."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
