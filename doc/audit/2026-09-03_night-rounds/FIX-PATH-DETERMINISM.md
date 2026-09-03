# Fix: the routing table is now a function of the topology, not of LLDP arrival order

Branch `fix/deterministic-path-tiebreak`. Fixes round 5's P3/P5 -- the highest-value finding of the
six overnight rounds. Evidence for the defect:
`doc/audit/2026-09-03_night-rounds/round5-topology-repro/SUMMARY.md` section B and step `25_`.
Not re-derived here; this document is what was changed, why that shape of change, and what the gate
proves.

[Co-developed with claude code -- Adam]

## 1. What was wrong

Eight bring-ups of one command, one topology file, one machine, each from a state verified clean,
produced **four different fabric-wide routing tables**. With identical h3 -> h1 traffic, s3 left via
s7 four times and via s8 four times, and the utilisation published for the s3-s7 link took five
distinct values: `{0.0, 1.476, 1.771, 2.951, 2.952}`. `/ndt/get_path_switch_count` was byte-identical
in all eight, because it returns a hop *count*.

`nx.shortest_path` on an unweighted graph is BFS; BFS breaks an equal-length tie by the order it
iterates a node's neighbours; `nx.DiGraph` iterates in insertion order; and insertion is
`TopologyManager.add_link` called from ten concurrent gRPC receive threads as LLDP discovers links.
The shipped 4-host P4 fabric has **eight** equal-length h3 -> h1 paths, so the tie was settled by
which packet-in landed first.

Rebuilding that same edge set here in 500 different insertion orders returns **all eight paths**
(71/70/67/66/64/56/56/50 out of 500). The round demonstrated two of the eight; the harness now
covers the whole tie.

## 2. The tie-break chosen

> Among the neighbours that are strictly closer to the destination, take the one with the smallest
> BLAKE2b digest of `(destination, this node, candidate)`.

Ordinary destination-based ECMP with a fixed hash. `p4_proxy/proxy_agent/ryu_topology.py`:
`hop_distances_to` / `canonical_next_hop` / `canonical_path` / `canonical_paths_to`, used by
`_shortest_path` (the renderer) and by `TopologyManager.calculate_all_paths` (the route installer),
so both now answer from one rule.

Three properties were wanted; two of them constrain the key.

**Deterministic.** Distances were never the problem -- BFS distances do not depend on traversal
order. Only the choice among equal-distance candidates did, and that choice is now a pure function
of the edge set.

**Destination-keyed, not source-keyed.** `install_initial_routes` writes one rule per
`(switch, destination IP)` into `ipv4_lpm`; a switch has exactly one next hop per destination
regardless of who sent the packet. Put the source in the tie-break key and the path advertised for
h3 -> h1 can disagree with the rule s7 actually holds for `10.0.0.1`. Measured on this fabric: **22
advertised hops out of the all-pairs set disagreed** with the rule the switch would install for
itself. Keying on `(destination, here, candidate)` makes the advertised path and the installed
hop-by-hop forwarding the same object by construction -- so `get_path_switch_count` counts the hops
of a path that does not need to be trusted separately. That is the honesty half of the fix, and it
is why the key is not simply "hash the flow".

**Spread, not concentrated.** The obvious canonical rule -- lowest dpid wins -- is equally
deterministic and collapses the load: on this fabric it makes **s6, s8 and s9 the next hop for
nothing at all**, all 24 rules landing on s5, s7 and s10. The digest is just as deterministic and
uses all ten, because it varies with the destination.

### Do deterministic and balanced conflict? Only for one kind of balance -- and that kind loses.

*Static* balance does not conflict: spreading by a fixed function of `(destination, here, candidate)`
is still a pure function of the topology, so it costs determinism nothing. That is what is
implemented.

*Load-adaptive* balance -- "leave by whichever uplink is quieter right now" -- would balance better
and would **put the defect straight back**: the path would depend on traffic at the moment of
computation, and the same experiment would stop being reproducible again for a new reason. Where the
two conflict, **determinism wins**; a twin whose published numbers cannot be reproduced is not
measuring anything. If load-aware placement is ever wanted, it belongs behind an explicit,
recorded input (a weight in the topology file, or an operator-set policy), not in the boot path.

`hashlib`, not the builtin `hash()`: `hash()` on a str is salted per process by `PYTHONHASHSEED`, so
it would trade an insertion-order race for a per-process one -- the same defect wearing a hat. M5 in
the gate exists for exactly that.

### What this does not change

It does not serialise anything. `add_link` keeps its existing lock; the fix is not a synchronisation
change, and serialising the inserts would only have made one arbitrary order likelier -- the answer
would still have been undefined. The number of paths, their length, and the output shape of
`calculate_all_paths` are unchanged; only *which* of the equal-length paths is returned. As a side
effect the all-pairs computation does one distance sweep per destination instead of a full search
per (source, destination) pair.

## 3. The gate

`p4_proxy/tests/test_path_determinism.py` -- 10 tests, run with the proxy venv:

```
cd p4_proxy && PYTHONPATH=. ./venv/bin/python tests/test_path_determinism.py -v
```

🔴 The gate asserts **determinism, not an answer**. Nothing in it says "the path is via s7". A test
pinned to one of the eight would pass on the unfixed code roughly half the time by luck, and would
go red the day the tie-break is legitimately changed. What is pinned:

| # | assertion |
|---|---|
| 1 | the shipped fabric really does contain the 8-way tie -- otherwise everything below is vacuous |
| 2 | **control:** raw `nx.shortest_path` over these same insertion orders is *not* stable; if it ever is, the harness can no longer see the defect and the passes mean nothing |
| 3 | the same edge set in 120 insertion orders gives **one** path, for every host pair, for every switch source, and through `TopologyManager.calculate_all_paths` itself |
| 4 | every hop on an advertised path is the hop that switch would install for itself |
| 5 | `render_destination_paths` and the path computation agree |
| 6 | no switch that lies on a shortest path is left carrying nothing |
| 7 | the answer is the same under `PYTHONHASHSEED` 0, 1 and 12345, in separate processes |

**Mutation gate:** `tests/shell/mutate_path_determinism.sh` (no build needed; snapshots the working
tree, restores on any exit, asserts byte-identity afterwards).

```
5 mutations, 0 survived
  M1 canonical_path -> nx.shortest_path        caught by test_every_host_pair_is_insertion_order_independent
  M2 calculate_all_paths -> nx.shortest_path   caught by test_topology_manager_all_pairs_is_stable
  M3 digest -> lowest node token               caught by test_no_switch_on_a_shortest_path_is_left_dark
  M4 hop rank keyed on the source              caught by test_advertised_hops_match_each_switch_own_next_hop
  M5 blake2b -> builtin hash()                 caught by test_same_answer_under_different_hash_seeds
```

M1 and M2 are the original defect put back at each of the two call sites. M3 is the simplification a
reviewer is most likely to propose. Every test in the file has been seen red.

Two mutations survived the first run and are recorded rather than quietly patched away: M3 was
caught only after `test_the_core_is_not_half_idle` was replaced with the eligible-set comparison
above (the threshold version passed on "lowest dpid wins", which uses 7 of 10 switches), and the
first M4 salted the digest with a constant instead of the source, so it was not the mutation it
claimed to be. Both are the harness being wrong, not the fix.

**Not done:** no fabric was brought up. This is an offline gate over the real shipped topology file,
plus the existing proxy suites re-run green (`test_ryu_topology`, `test_link_watchdog`,
`test_topology_properties`, `test_startup`, `test_readopt`, `test_delete_restores_route`,
`test_switch_state`, `test_journal_wiring`, `test_kernel_notifier`). A live confirmation -- ten
bring-ups, all producing one routing table -- is the obvious next round and is **not** claimed here.

## 4. `/ndt/get_path_switch_count`: should it also publish the hops?

**Not changed. Nothing on this branch touches the endpoint** -- so there is nothing to drop, and the
determinism fix can be taken on its own. This section is the case, for Adam to rule on.

**For.** The count is what a researcher reaches for to ask "did the path change?", and it
structurally cannot answer: it was byte-identical across all eight bring-ups whose routing tables
differed. The information already exists on the wire -- `/ndt/get_all_destination_paths` carries the
node lists this count is derived from -- so exposing it here adds no new computation, only a second
place to read it. After this fix the count is stable, which makes the blind spot *more* dangerous,
not less: a stable count now reads as evidence the path is stable, and would keep reading that way
after a topology edit that moved the path.

**Against.** It is an API change, and the count's consumers are load-bearing: `spec.py:916` pins its
schema, `tests/python/test_contract_spec.py:1130` asserts that schema, the kernel's
`m_switchCountMap` / `FlowLinkUsageCollector::setAllPaths` feed it,
`tools/contract_test/components.py:200` pairs it with `get_graph_data`, and
`baseline_diff_allowlist.txt:113` and `warning_allowlist.txt:160` both encode its current error
shapes. A widened response body has to survive all of those. There is also a real argument that the
right fix is *not here*: the hops are already published by `get_all_destination_paths`, and
duplicating them creates two sources that can disagree -- exactly the failure mode section 2 spent
its design budget eliminating.

**Blast radius, measured** (main worktree, excluding `.claude/worktrees/` and `build/`): 6 non-test
source references, 5 test/contract references, 2 allowlists, 3 CHANGELOG entries. No external
consumer is known to this repo, but "known to this repo" is the limit of what was checked -- the
paper's own scripts were not searched.

**Blind spots in this argument.** Not established: whether any published figure or script reads the
count today; whether the kernel's JSON consumer tolerates unknown fields (an additive field may be
free, or may not be, and that was not tested); and whether adding hops here would be preferred over
making the existing `get_all_destination_paths` more discoverable in the docs. Those three decide
it, and none of them was resolved in this session.

**Recommendation, held lightly:** if it changes, prefer an **additive optional field** (`hops`,
absent unless asked for) over widening the default body, and pin it in `spec.py` in the same commit
so the contract test moves with it -- as a separate commit that can be reverted alone.

## 5. Files

| file | change |
|---|---|
| `p4_proxy/proxy_agent/ryu_topology.py` | canonical tie-break; `_shortest_path` now calls it |
| `p4_proxy/proxy_agent/topology_manager.py` | `calculate_all_paths` uses `canonical_paths_to` |
| `p4_proxy/tests/test_path_determinism.py` | new -- the 10-test gate |
| `tests/shell/mutate_path_determinism.sh` | new -- the mutation gate |
| `doc/audit/2026-09-03_night-rounds/FIX-PATH-DETERMINISM.md` | this file |
