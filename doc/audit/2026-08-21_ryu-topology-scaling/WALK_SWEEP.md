# The 128-host all-pairs walk takes 2.2 s, not 13 s and not 60 s

[Co-developed with claude code -- Adam]

Measured 2026-08-21 at `91229f5`, OVS plane. Raw output in `walk_sweep.txt`, script
`walk_sweep.sh`.

## The question

Experiment ① has to make detection + recompute + rule-install add up to the 51.75 s OVS
128-host failover. The recompute term had two figures on record and they disagreed by 4.6x:

| | figure | where it came from |
|---|---|---|
| derived | **<= 13 s** | 73 s control-plane start (2026-08-19) minus the 60 s `hub.sleep` -- an upper bound covering the JSON parse and graph build as well |
| asserted | **~60 s** | `intelligent_router.py:113`, `:127`, `test_route_reinstall.py`'s docstring, `5affd93`'s commit message -- all tracing to `doc/2026-07-29_HANDOFF.md 1g`, which predates `cc249c8` and therefore predates 128 hosts being runnable |

Neither was a measurement of the function. `c2afbac` added one.

## Answer

```
install_all_pair_paths done: hosts=128 pairs=16256 rules=1280 paths=16256
                             walk=2.166s install=0.103s report=2.063s
```

**2.166 s.** The asserted figure is off by 28x; the derived bound holds but is six times
looser than it needed to be.

Sweep, one cell per model size, `n=1`:

| hosts | pairs | rules | walk (s) | install (s) | report (s) | report share |
|---:|---:|---:|---:|---:|---:|---:|
| 8 | 56 | 80 | 0.010 | 0.007 | 0.003 | 30% |
| 16 | 240 | 160 | 0.018 | 0.009 | 0.009 | 50% |
| 32 | 992 | 320 | 0.074 | 0.022 | 0.052 | 70% |
| 64 | 4032 | 640 | 0.331 | 0.044 | 0.286 | 86% |
| 128 | 16256 | 1280 | **2.166** | 0.103 | **2.063** | **95%** |

`install` grows 14.7x across a 16x increase in hosts -- linear, as expected for one OpenFlow
entry per (switch, destination).

## What the walk actually spends its time on

**Not installing rules.** At 128 hosts the 1280 OpenFlow writes cost 0.103 s. The other
**95%** is the loop that builds `all_destination_paths` -- one entry per ordered host pair,
16256 of them -- which exists only so the kernel can read the path table. Every "16256 pairs"
remark in this repo is about that structure, not about the rules.

### It is cubic, and the cause was confirmed by changing it

The report phase's log-log slope against host count *rises* with scale -- 2.4, 2.65, 2.85 --
which is steeper than the quadratic the pair count would predict. The suspect is
`find_host_by_ip` (`intelligent_router.py:641-647`), which linear-scans `net.nodes`, called
from inside the innermost loop of the path reconstruction.

Arithmetic fitting a hypothesis is not the mechanism, so this was tested by intervention: run
the real extracted method twice over the same fabric, changing only that helper.

| hosts | real helper (linear scan) | slope | dict lookup O(1) | slope | ratio |
|---:|---:|---:|---:|---:|---:|
| 32 | 0.0080 | 3.00 | 0.0020 | — | 4.0x |
| 64 | 0.0590 | 2.88 | 0.0080 | 2.00 | 7.4x |
| 128 | 0.3960 | 2.75 | 0.0290 | 1.86 | **13.7x** |

Replacing the scan with an index collapses the cubic term to quadratic. **The cubic term is
that one line.** (Absolute values are from the offline harness and are smaller than live --
its `add_flow` is a list append; only the scaling transfers.)

**Not fixed here.** `install_all_pair_paths` is on the live OVS control path and this round set
out to measure it, not to change it. Filed as a finding.

## What this does to experiment ①'s budget

The recompute term is **~2 s of a 51.75 s failover, about 4%**. Combined with the topology
read path already ruled out at sub-1.3 ms (`REPORT.md`), the two mechanisms that were most
suspected of explaining OVS's penalty together account for under 5% of it.

**Roughly 46 s remains unattributed**, and the remaining candidates are detection latency and
the debounce, not path computation. The slide must not carry 13 s or 60 s for this term.

⚠️ **This is the startup walk, not the failover walk.** Both call the same function over a
graph of the same size, so the cost should carry, but they are different call sites
(`load_static_topology` vs `_route_reinstall_worker`). `c2afbac` instruments the function, so
the next link-down run reports its own figure without extra setup -- that is the measurement
that closes this, and it needs the lab.

Other caveats: `n=1` per cell; every cell ran on the same 128-host NTG fabric (see below), so
background LLDP and packet-in load is constant across the sweep but is not zero.

## Method note: the walk is driven by the model, not the fabric

`install_all_pair_paths(self.static_net)` walks a graph built entirely from the topology JSON.
The only thing it takes from the live fabric is `self.switches` -- ten datapaths, identical in
every cell. So sweeping the model on one fixed fabric varies exactly one thing and holds the
noise floor constant. It is a better-controlled experiment than rebuilding the fabric per cell
would have been, and it is also the only one available: see below.

## Found on the way: `ndt up ovs <N>` builds 128 hosts for any N and reports success

`ovs-topo-start` runs `~/Network-Traffic-Generator/testbed_topo.py`, a fixed 128-host topology
in another repo with no host-count parameter. Only `ovs4` dispatches elsewhere
(`ovs_4host_topo.py`). So **the OVS plane has exactly two fabric sizes, 4 and 128.**

`ndt up ovs 16` nonetheless reports success:

```
ok  139 host/switch processes after 2s
ok  model matches fabric: 16 hosts, 64 edges
ok  data plane: h1 -> 10.0.0.2 forwards
up. ready
```

The fabric was 128 hosts -- 160 `s*-eth*` interfaces, of which 32 are inter-switch. Three
checks pass anyway:

* `ndt:730-737` wants `hosts + 10` processes and tests `-ge`, so 139 >= 26.
* `ndt:784` labels itself "model matches fabric" but compares the **kernel's graph** (built
  from `TOPO_OVS`) against **the same file** the kernel read. It is tautological for host
  count. Its comment shows it was built for a different job -- catching the kernel's one-shot
  topology pull landing in a link-count dip -- which it still does.
* `verify_dataplane h1 10.0.0.2` passes because h1 and h2 exist in both layouts.

This is the mirror of the defect fixed earlier the same day: then a 4-host fabric carried a
128-host Ryu model, now a 128-host fabric carries an N-host model. Reported to the session that
owns `ndt`; not fixed here.

**It does not invalidate this sweep** -- the walk reads the model, and the fabric was constant
and correctly identified in every cell by counting veths rather than by trusting the report.
Any measurement that depends on the *fabric* size, however, cannot use `ndt up ovs <N>` for N
outside {4, 128} today.
