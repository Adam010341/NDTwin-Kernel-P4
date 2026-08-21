"""Does the model-derived fabric match the hard-coded one, exactly?

[Co-developed with claude code -- Adam]

This is the gate for replacing the literal `addLink` lists with a reader. The lists are the
known-good output: they built every fabric this project has ever measured. A derived wiring
that differs from them by one port is not a refactor, it is a new topology wearing the old
one's name -- and this codebase has already shown that a wrong-but-plausible fabric passes
every structural check downstream.

So the derived lists are compared element by element against the literals transcribed here
from the files they replace. Run:

    python3 tools/test_workflow/test_topo_from_json.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE)) if os.path.basename(HERE) == "test_workflow" else None
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "p4_proxy", "mininet"))

import topo_from_json as T  # noqa: E402

# --- the known-good wiring, transcribed from p4_testbed_topo.py:263-279 -------------------
# (a_dpid, a_port, b_dpid, b_port), normalised lower-dpid-first the same way the reader does.
LITERAL_SWITCH_LINKS = sorted([
    (1, 1, 5, 1), (1, 2, 6, 1), (2, 1, 5, 2), (2, 2, 6, 2),
    (3, 1, 7, 1), (3, 2, 8, 1), (4, 1, 7, 2), (4, 2, 8, 2),
    (5, 3, 9, 1), (5, 4, 10, 1), (6, 3, 9, 2), (6, 4, 10, 2),
    (7, 3, 9, 3), (7, 4, 10, 3), (8, 3, 9, 4), (8, 4, 10, 4),
])


def literal_host_links(host_num):
    """p4_testbed_topo.py:307-312 -- hosts split evenly over s1-s4, switch ports from 3."""
    per_switch = host_num // 4
    return sorted(
        [(f"h{i + 1}", 1 + i // per_switch, 3 + i % per_switch) for i in range(host_num)],
        key=lambda t: (int(t[0][1:]), t[1], t[2]),
    )


def check(label, got, want):
    if got == want:
        print(f"  ok    {label}: {len(got)} entries identical")
        return 0
    print(f"  FAIL  {label}")
    only_got = [x for x in got if x not in want]
    only_want = [x for x in want if x not in got]
    print(f"          derived-only ({len(only_got)}): {only_got[:6]}")
    print(f"          literal-only ({len(only_want)}): {only_want[:6]}")
    return 1


def main():
    bad = 0
    for name, host_num in (("P4_10Switches_4Hosts", 4), ("P4_10Switches_128Hosts", 128)):
        path = os.path.join(REPO, "setting", f"StaticNetworkTopology{name}.json")
        if not os.path.exists(path):
            print(f"  skip  {name}: not present")
            continue
        print(f"{name}")
        m = T.load(path)

        sw = T.switches(m)
        if [d for d, _ in sw] == list(range(1, 11)):
            print(f"  ok    switches: {len(sw)} dpids 1..10, names {sw[0][1]}..{sw[-1][1]}")
        else:
            print(f"  FAIL  switches: {[d for d, _ in sw]}"); bad += 1

        bad += check("inter-switch links", T.switch_links(m), LITERAL_SWITCH_LINKS)
        bad += check("host attachment", T.host_links(m), literal_host_links(host_num))

        hs = T.hosts(m)
        want_hosts = [f"h{i}" for i in range(1, host_num + 1)]
        if [n for n, _, _ in hs] == want_hosts:
            print(f"  ok    hosts: {len(hs)}, h1..h{host_num}, first ip {hs[0][1]}")
        else:
            print(f"  FAIL  hosts: {[n for n, _, _ in hs][:8]} ..."); bad += 1
        print()

    # The OVS model of the same size must describe the same cabling -- that is the premise of
    # comparing the two data planes at all.
    ovs = os.path.join(REPO, "setting", "StaticNetworkTopologyOVS_10Switches_4Hosts.json")
    if os.path.exists(ovs):
        print("OVS_10Switches_4Hosts (must be cabled identically to the P4 model)")
        m = T.load(ovs)
        bad += check("inter-switch links", T.switch_links(m), LITERAL_SWITCH_LINKS)
        bad += check("host attachment", T.host_links(m), literal_host_links(4))
        print()

    print("PASS -- derived wiring is identical to the hard-coded lists" if not bad
          else f"FAIL -- {bad} mismatch(es); do NOT switch the builder over")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
