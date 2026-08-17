#!/usr/bin/env python3
"""
L3: per-component contract check.

L2 asks "is the kernel's API correct?". L3 asks "which components would break?" -- so
after changing an endpoint you know the blast radius without launching all seven tools.

Two checks per component:

  1. existence -- every endpoint it calls must exist. A 404 means the component is
     calling something the kernel does not implement. Energy-Saving-App's
     /ndt/disable_switch is the example, and it also marks this check's limit: the call
     really is in the source (src/app/http.cpp:269) and the kernel really does not
     implement it, so MISSING is correct -- but that function has **zero call sites**.
     It is dead code, and the live energy-saving path uses
     /ndt/set_switches_power_state instead. So "the app swallows a 404 at runtime" does
     not follow. What this check scans is which endpoints appear in the source, which is
     a superset of the endpoints actually reached at run time; separating the two needs
     call-graph analysis or runtime observation, neither of which is in this layer.
     [Co-developed with claude code -- Adam]

  2. contract  -- for endpoints covered by spec.py, run the L2 structure and invariant
     checks and attribute any failure to the components that depend on it.

Usage
-----
  ./l3_component_check.py --topology <file>              # all components
  ./l3_component_check.py --topology <file> --component Web-GUI
  ./l3_component_check.py --blast-radius get_graph_data  # offline; no kernel needed
  ./l3_component_check.py --map                          # offline dependency table

Exit code 0 only when every selected component's dependencies hold.

[Co-developed with claude code -- Adam]
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from components import (  # noqa: E402
    COMPONENTS,
    KERNEL_ENDPOINTS,
    KNOWN_MISSING_ENDPOINTS,
    check_dispatch_drift,
    endpoint_consumers,
    scan_kernel_dispatch,
)

# Default location of the kernel's dispatch chain, used for the drift check.
DEFAULT_HTTP_SESSION = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "src", "ndt_core", "http", "HttpSession.cpp")
from run_contract_test import Context, Palette, check_endpoint, request, supports_colour  # noqa: E402
from spec import ENDPOINTS  # noqa: E402

# Endpoints whose contract is covered by spec.py, keyed by bare endpoint name.
SPEC_BY_ENDPOINT = {}
for _ep in ENDPOINTS:
    _name = _ep["path"].removeprefix("/ndt/")
    # Keep the first (canonical) spec for each path; later entries are error-path variants.
    SPEC_BY_ENDPOINT.setdefault(_name, _ep)


def probe_exists(base_url, endpoint, ctx, timeout) -> tuple[bool, int, str]:
    """
    Does the kernel route this endpoint at all?

    Sends a deliberately minimal request with the correct method. The kernel matches on
    (method, target) together, so the method must be right or an existing endpoint looks
    missing. Any status other than 404 proves the route exists -- a 400 for missing
    parameters is a perfectly good answer to "are you there?".
    """
    method = KERNEL_ENDPOINTS.get(endpoint)
    if method is None:
        return False, 0, "not in the kernel's dispatch table"

    ep = {"name": f"probe_{endpoint}", "method": method,
          "path": f"/ndt/{endpoint}", "category": "probe"}
    if method == "POST":
        ep["body"] = {}

    status, _data, err = request(base_url, ep, ctx, timeout)
    if status == 0:
        return False, 0, err or "no response"
    if status == 404:
        return False, 404, "kernel returned 404 -- endpoint not implemented"
    if status == 503:
        # [Co-developed with claude code -- Adam]
        # 503 is not the same failure as the 5xx below, and calling it MISSING was wrong.
        # A route answers 503 when it is routed, reached, and deliberately declining --
        # /ndt/intent_translator/text does exactly that under --no-ai, which is how
        # stack.sh always starts the kernel, and that guard is itself the fix for the null
        # dereference that used to segfault the process (2026-01-02_ndt_api.md section 41).
        # Reporting the guard as a missing endpoint told the reader the opposite of what
        # happened, and made L3 fail on every normal run, which is how a red check stops
        # being read. It exists; the note travels with it so a 503 nobody expected is still
        # visible.
        return True, 503, "exists but declining: 503, the documented answer for a disabled feature"
    if status >= 500:
        # The route exists but blew up on a minimal request. Reporting this as "exists"
        # would let an endpoint that 500s on every call look healthy to its consumers.
        return False, status, (
            f"kernel returned {status} on a minimal request -- the route exists but "
            f"throws instead of validating input, so its consumers see a 5xx")
    return True, status, ""


def print_drift(pal: Palette, http_session_cpp: str) -> int:
    """Proves the hand-transcribed dispatch table still matches HttpSession.cpp."""
    problems = check_dispatch_drift(http_session_cpp)
    if not problems:
        actual = scan_kernel_dispatch(http_session_cpp)
        print(pal.green(
            f"KERNEL_ENDPOINTS is in sync with HttpSession.cpp ({len(actual)} endpoints)"))
        return 0
    print(pal.red("KERNEL_ENDPOINTS has drifted from HttpSession.cpp:"))
    for p in problems:
        print(f"  - {p}")
    print(pal.dim("\n  Update KERNEL_ENDPOINTS in components.py to match."))
    return 1


def print_map(pal: Palette, http_session_cpp: str | None = None) -> int:
    if http_session_cpp and os.path.exists(http_session_cpp):
        drift = check_dispatch_drift(http_session_cpp)
        if drift:
            print(pal.red("WARNING: the endpoint table below is out of date\n"))
            for d in drift:
                print(f"  - {d}")
            print()

    print("Endpoint dependency map (measured from component source)\n")
    index = endpoint_consumers()
    width = max(len(e) for e in index)
    for ep, comps in index.items():
        missing = "" if ep in KERNEL_ENDPOINTS else pal.red("  [NOT IMPLEMENTED BY KERNEL]")
        marker = pal.yellow("*") if len(comps) >= 5 else " "
        print(f" {marker} {ep:<{width}}  {len(comps)}  {', '.join(comps)}{missing}")

    print(f"\n {pal.yellow('*')} = 5 or more consumers; breaking these breaks most of the system")

    unimplemented = sorted({ep for ep in index if ep not in KERNEL_ENDPOINTS})
    known = [ep for ep in unimplemented if ep in KNOWN_MISSING_ENDPOINTS]
    new = [ep for ep in unimplemented if ep not in KNOWN_MISSING_ENDPOINTS]

    if known:
        print(f"\n{pal.yellow('KNOWN GAPS')} "
              f"(called by a component, not implemented by the kernel, acknowledged)")
        for ep in known:
            print(f"   /ndt/{ep}  <- {', '.join(index[ep])}")
            print(f"      {pal.dim(KNOWN_MISSING_ENDPOINTS[ep])}")

    if new:
        print(f"\n{pal.red('UNACKNOWLEDGED MISSING ENDPOINTS')}")
        for ep in new:
            print(f"   /ndt/{ep}  <- {', '.join(index[ep])}")
        print(pal.dim("\n   Either implement these, remove the calls, or record them in"
                      " KNOWN_MISSING_ENDPOINTS (components.py) with a reason."))
        return 1
    return 0


def print_blast_radius(endpoint: str, pal: Palette) -> int:
    endpoint = endpoint.removeprefix("/ndt/")
    comps = endpoint_consumers().get(endpoint)
    if not comps:
        print(f"/ndt/{endpoint}: no component depends on it "
              f"(safe to change from the workspace's point of view)")
        return 0
    print(f"/ndt/{endpoint} is used by {len(comps)} component(s):")
    for c in comps:
        comp = next(x for x in COMPONENTS if x.name == c)
        w = pal.yellow(" (writes network state)") if comp.writes else ""
        print(f"   - {c}  [{comp.language}]{w}")
    if endpoint not in KERNEL_ENDPOINTS:
        print(pal.red(f"\n   and the kernel does not implement it at all"))
        return 1
    return 0


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="L3 per-component contract check")
    ap.add_argument("--url", default=os.environ.get("NDT_API_URL", "http://localhost:8000"))
    ap.add_argument("--topology", help="topology JSON the kernel was started with")
    ap.add_argument("--component", action="append",
                    help="check only this component; repeatable")
    ap.add_argument("--with-traffic", action="store_true")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--topk", type=int, default=5)
    ap.add_argument("--probe-ip", default="10.255.255.254")
    ap.add_argument("--allow-mutations", action="store_true",
                    help="also run contract checks for write endpoints")
    ap.add_argument("--map", action="store_true",
                    help="print the dependency map and exit (no kernel needed)")
    ap.add_argument("--blast-radius", metavar="ENDPOINT",
                    help="list components affected by one endpoint, then exit")
    ap.add_argument("--check-drift", action="store_true",
                    help="verify the hand-transcribed KERNEL_ENDPOINTS table still "
                         "matches HttpSession.cpp, then exit (no kernel needed)")
    ap.add_argument("--http-session", default=DEFAULT_HTTP_SESSION,
                    help="path to HttpSession.cpp for the drift check")
    args = ap.parse_args()

    pal = Palette(supports_colour())

    if args.check_drift:
        return print_drift(pal, args.http_session)
    if args.map:
        return print_map(pal, args.http_session)
    if args.blast_radius:
        return print_blast_radius(args.blast_radius, pal)

    if not args.topology:
        ap.error("--topology is required (or use --map / --blast-radius)")
    if not os.path.exists(args.topology):
        print(pal.red(f"topology file not found: {args.topology}"))
        return 2

    ctx = Context(args.topology, args.topk, args.probe_ip)
    selected = COMPONENTS
    if args.component:
        wanted = set(args.component)
        selected = [c for c in COMPONENTS if c.name in wanted]
        if not selected:
            print(pal.red(f"no component matches {sorted(wanted)}; known: "
                          f"{[c.name for c in COMPONENTS]}"))
            return 2

    print("NDTwin L3 component contract check")
    print(f"  kernel   : {args.url}")
    print(f"  topology : {ctx.describe()}")
    print(f"  components: {len(selected)}\n")

    # Probe and validate each distinct endpoint once, then attribute results.
    needed = sorted({ep for c in selected for ep in c.endpoints})
    existence: dict[str, tuple[bool, int, str]] = {}
    contract: dict[str, tuple[bool, list[str]]] = {}

    print("Shared endpoint checks:")
    for ep in needed:
        ok, status, why = probe_exists(args.url, ep, ctx, args.timeout)
        existence[ep] = (ok, status, why)
        if not ok:
            print(f"  {pal.red('MISSING')} /ndt/{ep}  {pal.dim(why)}")
            continue

        # An endpoint can exist and still have something worth saying about it -- a 503
        # from a deliberately disabled feature is routed and reachable, but a reader who
        # sees a bare "ok" will not know the feature is off.
        if why:
            print(f"  {pal.green('exists')}  /ndt/{ep}  {pal.dim(why)}")

        spec_ep = SPEC_BY_ENDPOINT.get(ep)
        if spec_ep is None:
            print(f"  {pal.green('exists')}  /ndt/{ep} {pal.dim('(no contract spec)')}")
            continue
        if spec_ep["category"] == "mutate" and not args.allow_mutations:
            print(f"  {pal.green('exists')}  /ndt/{ep} "
                  f"{pal.dim('(contract skipped: needs --allow-mutations)')}")
            continue

        res = check_endpoint(args.url, spec_ep, ctx, args)
        contract[ep] = (res.ok, res.failures)
        tag = pal.green("ok") if res.ok else pal.red("BROKEN")
        print(f"  {tag:>7}  /ndt/{ep}")
        for f in res.failures:
            print(f"           {pal.red('-')} {f}")

    # --- attribute to components -----------------------------------------------
    print(f"\n{'=' * 70}\nPer-component verdict\n")
    broken_components = []
    degraded_components = []
    for comp in selected:
        problems, known_gaps = [], []
        for ep in comp.endpoints:
            ok, status, why = existence[ep]
            if not ok:
                # An acknowledged gap degrades the component; an unacknowledged one is a
                # regression. Keeping them apart stops the known ones masking new ones.
                if ep in KNOWN_MISSING_ENDPOINTS:
                    known_gaps.append(f"/ndt/{ep} missing (known gap)")
                else:
                    problems.append(f"/ndt/{ep} missing ({why})")
                continue
            c_ok, c_failures = contract.get(ep, (True, []))
            if not c_ok:
                problems.append(f"/ndt/{ep} contract violated: {c_failures[0]}")

        writes = pal.yellow(" [writes]") if comp.writes else ""
        if problems:
            broken_components.append(comp.name)
            print(f"  {pal.red('AFFECTED')} {comp.name}{writes}")
            for p in problems + known_gaps:
                print(f"             - {p}")
        elif known_gaps:
            degraded_components.append(comp.name)
            print(f"  {pal.yellow('DEGRADED')} {comp.name}{writes}")
            for p in known_gaps:
                print(f"             - {p}")
        else:
            print(f"  {pal.green('OK')}       {comp.name}{writes} "
                  f"{pal.dim(f'({len(comp.endpoints)} endpoints)')}")

    print(f"\n{'=' * 70}")
    if degraded_components:
        print(pal.yellow(f"{len(degraded_components)} component(s) degraded by a known gap: "
                         f"{', '.join(degraded_components)}"))
    if broken_components:
        print(pal.red(f"{len(broken_components)} component(s) affected: "
                      f"{', '.join(broken_components)}"))
        return 1
    print(pal.green(f"All {len(selected)} component(s) have their dependencies satisfied "
                    f"(known gaps aside)."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
