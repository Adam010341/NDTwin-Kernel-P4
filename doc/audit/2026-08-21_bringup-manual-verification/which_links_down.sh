#!/bin/bash
# On OVS, `ndt status --check` reports 256 of 288 links down on a fabric whose cross-quadrant
# pings all pass. 288 - 32 = 256 and 128 hosts x 2 = 256, so the arithmetic says "the host
# edges". Arithmetic that fits is not the mechanism -- this reads the kernel's own graph and
# classifies every down edge by its endpoints instead of inferring it.
# [Co-developed with claude code -- Adam]
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
NDT="$REPO/tools/test_workflow/ndt"
export NDT_OWNER=manual-verify-0821
export TERM="${TERM:-dumb}"

echo "== claiming and bringing OVS up =="
"$NDT" claim 20 "classify down links on OVS" >/dev/null || exit 1
"$NDT" up ovs 2>&1 | tail -8

echo
echo "== classifying every edge in the kernel graph =="
curl -sf --max-time 10 http://localhost:8000/ndt/get_graph_data > /tmp/graph_ovs.json
"$REPO/p4_proxy/venv/bin/python" - /tmp/graph_ovs.json <<'PY'
import json, sys, collections
g = json.load(open(sys.argv[1]))
# vertex_type 1 == host (same convention ndt's topo_for_hosts uses)
kind = {}
for n in g.get("nodes", []):
    nid = n.get("id", n.get("name"))
    kind[nid] = "host" if n.get("vertex_type") == 1 else "switch"

tally = collections.Counter()
examples = {}
for e in g.get("edges", []):
    a, b = e.get("source"), e.get("target")
    ka, kb = kind.get(a, "?"), kind.get(b, "?")
    pair = "-".join(sorted([ka, kb]))
    # an edge is "down" when the kernel says so; field name varies, try the usual ones
    down = not e.get("is_up", e.get("up", e.get("status") != "down" if "status" in e else True))
    key = (pair, "down" if down else "up")
    tally[key] += 1
    examples.setdefault(key, f"{a}({ka}) <-> {b}({kb})")

print(f"{'endpoints':<16} {'state':<6} {'count':>6}   example")
for (pair, state), n in sorted(tally.items()):
    print(f"{pair:<16} {state:<6} {n:>6}   {examples[(pair,state)]}")
print()
print("total edges:", len(g.get("edges", [])))
print("hosts:", sum(1 for k in kind.values() if k == "host"),
      " switches:", sum(1 for k in kind.values() if k == "switch"))
print()
print("edge keys present:", sorted(g["edges"][0].keys()) if g.get("edges") else "(none)")
PY

echo
echo "== tearing down =="
"$NDT" down 2>&1 | tail -4
"$NDT" release
