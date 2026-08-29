#!/usr/bin/env python3
"""Self-test for the harness's own parsing, against a REAL captured graph payload.

    python3 test_probes.py [fixtures/graph_p4_138nodes.json]

Why this file exists: on 2026-08-29 the first null round reported

    "graph claims 11 switches up, only 10 BMv2 processes exist -- the twin is certifying
     dead switches (A-1 shape)"

on a completely healthy fabric, because `switch_flags` keyed every node by `dpid` and all 128
hosts carry `dpid: 0`. The harness had no test of its own parsing, so the only thing that could
catch it was a live round -- and a live round reports it as a finding about NDTwin.

The fixture is a real captured payload, not a hand-written one. A hand-written fixture would
have had one host with `dpid: 0` and passed, because I would have written down what I believed
rather than what the kernel sends. `verify-against-known-good-output` is the rule; the captured
file is the known-good output.

Each case below has a mutation attached: the assertion is not just "the right answer comes out"
but "a wrong payload does NOT come out looking right".

[Co-developed with claude code -- Adam]
"""
from __future__ import annotations

import copy
import json
import sys

import probes

FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if cond else 'FAIL'}  {name}" + (f"  -- {detail}" if detail else ""))
    if not cond:
        FAILURES.append(name)


def expect_drift(name: str, fn) -> None:
    """The point of SchemaDrift is that it is LOUD. A test that only checks the happy path
    would have passed against the buggy version too."""
    try:
        got = fn()
    except probes.SchemaDrift as e:
        print(f"  ok    {name}  -- refused: {str(e)[:90]}")
        return
    print(f"  FAIL  {name}  -- returned {len(got)} entries instead of refusing")
    FAILURES.append(name)


def main(path: str) -> int:
    with open(path) as f:
        real = json.load(f)
    nodes = real["nodes"]
    print(f"fixture: {path}  ({len(nodes)} nodes)")

    # ---- 1. the real payload classifies correctly --------------------------------------
    flags = probes.switch_flags(real)
    hosts = [n for n in nodes if n.get("vertex_type") == probes.VERTEX_TYPE_HOST]
    check("switches only", len(flags) == 10, f"got {len(flags)}, hosts excluded: {len(hosts)}")
    check("every returned node really is a switch",
          all(n["vertex_type"] == probes.VERTEX_TYPE_SWITCH for n in flags.values()))
    check("no host leaked in by name",
          not any(str(n.get("device_name", "")).startswith("h") for n in flags.values()))

    # ---- 2. THE REGRESSION ITSELF ------------------------------------------------------
    # The exact arithmetic INV-01 does. Against the old code this was 11.
    up_in_graph = sum(1 for n in flags.values() if n.get("is_up") is True)
    check("INV-01 numerator equals the switch count, not switches+1",
          up_in_graph == 10, f"up_in_graph={up_in_graph} (was 11 before the fix)")
    # And prove the collision was real, so this test still means something if the fabric
    # is ever captured with differently-numbered hosts.
    dpid0 = [n for n in nodes if n.get("dpid") == 0]
    check("the fixture actually contains the colliding hosts",
          len(dpid0) > 1, f"{len(dpid0)} nodes share dpid 0 -- this is what collapsed to 1")

    # ---- 3. mutations that must be REFUSED, not absorbed --------------------------------
    m = copy.deepcopy(real)
    for n in m["nodes"]:
        n.pop("vertex_type", None)
    expect_drift("field renamed away -> refuse, not classify by guess",
                 lambda: probes.switch_flags(m))

    m2 = copy.deepcopy(real)
    del m2["nodes"][0]["vertex_type"]          # one node only: partial drift
    expect_drift("even ONE untyped node -> refuse", lambda: probes.switch_flags(m2))

    m3 = copy.deepcopy(real)
    sw = [n for n in m3["nodes"] if n["vertex_type"] == 0]
    sw[1]["dpid"] = sw[0]["dpid"]              # two switches, one dpid
    expect_drift("two switches on one dpid -> refuse, don't drop one",
                 lambda: probes.switch_flags(m3))

    expect_drift("no switches at all -> refuse", lambda: probes.switch_flags({"nodes": hosts}))
    expect_drift("not an object -> refuse", lambda: probes.switch_flags([]))

    # ---- 4. the invariant must still be able to FAIL ------------------------------------
    # A fix that makes INV-01 always pass is worse than the bug. Feed it a graph where a
    # switch really is up-but-dead and confirm the numerator moves.
    m4 = copy.deepcopy(real)
    for n in m4["nodes"]:
        if n["vertex_type"] == 0 and n["dpid"] == 3:
            n["is_up"] = False
    check("numerator tracks a switch going down",
          sum(1 for n in probes.switch_flags(m4).values() if n.get("is_up") is True) == 9,
          "so INV-01 still has resolving power; it did not become a constant PASS")

    # ---- 5. provenance: the LOUD branches must actually be reachable ---------------------
    # A mismatch warning nobody has watched fire is the same as no warning. Both branches are
    # driven here by faking pgrep's output, because the real fabric cannot be put into a
    # mixed-build state just to test a print statement.
    real_run = probes.run

    def fake_run(argv, timeout=5.0, env=None):
        if argv[0] == "pgrep":
            return 0, fake_run.pgrep_out, ""
        if argv[0] == "sha256sum":
            return 0, f"deadbeef  {argv[1]}", ""
        return real_run(argv, timeout, env)

    probes.run = fake_run
    try:
        fake_run.pgrep_out = "111 /usr/local/bin/simple_switch_grpc -i 1@s1-eth1\n"
        p = probes.bmv2_provenance()
        check("override mismatch is reported",
              "OVERRIDE_MISMATCH" in p, p.get("OVERRIDE_MISMATCH", "NOT REPORTED")[:70])

        fake_run.pgrep_out = ("111 /usr/local/bin/simple_switch_grpc -i 1@s1-eth1\n"
                              "112 /usr/local/bmv2-fast/bin/simple_switch_grpc -i 1@s2-eth1\n")
        p = probes.bmv2_provenance()
        check("mixed-build fabric is reported",
              "MIXED_BUILD" in p, f"{len(p.get('running', {}))} distinct binaries seen")

        fake_run.pgrep_out = "111 /usr/local/bmv2-fast/bin/simple_switch_grpc -i 1@s1-eth1\n"
        p = probes.bmv2_provenance()
        check("and it stays QUIET when the fabric is consistent",
              "MIXED_BUILD" not in p and "OVERRIDE_MISMATCH" not in p,
              "otherwise the warning is a constant and says nothing")
    finally:
        probes.run = real_run

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("all parser checks passed")
    return 0


if __name__ == "__main__":
    # The fixture lives HERE, not in ../raw/, because raw/ is gitignored (it belongs on the
    # audit-raw orphan branch). A self-test whose fixture is on a different branch is a test
    # nobody can run -- and this one exists precisely because the harness had no parser test.
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "fixtures/graph_p4_138nodes.json"))
