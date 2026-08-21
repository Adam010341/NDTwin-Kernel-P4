# Does Ryu's topology query explain OVS's 128-host failover penalty? No.

[Co-developed with claude code -- Adam]

Experiment ②, first probe. All measurements at `d9f580b`, 2026-08-21, OVS plane only.

## The question

At 128 hosts, OVS failover is **3.12× slower than P4 with zero overlap** (P4 slowest 20.8 s,
OVS fastest 47.0 s), and going 4→128 hosts costs OVS **3.29×** while costing P4 only **1.21×**
(`2026-08-17_p4-vs-ovs-matched-topology/`). The mechanism was never established. The standing
hypothesis was that the *controller's topology query* amplifies with host count.

The cheapest way to test it is to time the endpoints the kernel actually polls —
`TopologyAndFlowMonitor` builds them as `RYU_BASE_URL + {/switches,/hosts,/links}`
(`tests/test_TopologyUrlAndPathJson.cpp:112-114`) — at both host counts.

## Result: the hypothesis is refuted

n=20 per cell after 3 warm-ups, median reported. `ndt down` between every cell; each `ndt up`
printed its own `started kernel` line with a distinct pid (239930 / 261900 / 264715), so no
cell inherited a previous kernel.

| endpoint | 4 host | 128 host | time ratio | byte ratio |
|---|---|---|---|---|
| `/v1.0/topology/switches` | 0.461 ms / 4,158 B | 1.127 ms / 17,154 B | 2.44× | 4.13× |
| `/v1.0/topology/hosts` | 0.346 ms / 812 B | 1.225 ms / 26,345 B | 3.54× | 32.44× |
| `/v1.0/topology/links` | 0.449 ms / 7,176 B | 0.797 ms / 7,176 B | 1.78× | 1.00× |
| `ryu_server/all_destination_paths` | 19.274 ms / 1,110,528 B | 20.936 ms / 1,110,528 B | 1.09× | 1.00× |

**Every topology endpoint answers in under 1.3 ms at either scale.** Against a 47-second
failover this is four orders of magnitude too small to matter, and no amount of ratio-reading
rescues it: 3.54× of 0.346 ms is still 1.2 ms.

The shape is also wrong for the hypothesis. Time ratio runs *behind* byte ratio everywhere
(`/hosts` serves 32× the data for 3.5× the time), which is serialisation scaling sublinearly —
the opposite of a controller doing superlinear work on a bigger graph.

**The controller's topology read path is not where OVS loses its time.** Rule it out and stop
re-deriving it.

## What the paths row actually caught: a live defect in `ndt up ovs4`

`all_destination_paths` returned **1,110,528 bytes on both fabrics — byte-identical.** That is
not a measurement, it is a signal that one cell is mislabelled.

It is. On the 4-host fabric the path table contains `10.0.0.1` .. `10.0.0.128` — all 128 hosts.
`intelligent_router.py:36-38` takes Ryu's host list from **its own** static topology file,
defaulting to the 128-host `StaticNetworkTopologyMininet_10Switches.json`, independent of what
the fabric actually has. `NDTWIN_RYU_TOPO_FILE` overrides it.

**Nothing sets that variable.** `git grep NDTWIN_RYU_TOPO_FILE` over the whole repo returns the
reader in `intelligent_router.py` and one hand-typed `export` in
`2026-08-17_p4-vs-ovs-matched-topology/REPORT.md:182`. There is no automated setter, so
`ndt up ovs4` does not set it.

Measured consequence — `ndt up ovs4`, then ping across the fabric it just declared ready:

```
ok  model matches fabric: 4 hosts, 40 edges
up. ready

h1 -> 10.0.0.2   3 packets transmitted, 0 received, 100% packet loss
h1 -> 10.0.0.3   3 packets transmitted, 0 received, 100% packet loss
h1 -> 10.0.0.4   3 packets transmitted, 0 received, 100% packet loss
```

This is the 2026-08-17 incident that `intelligent_router.py:32-35` documents in a comment,
recurring: the fix then was to add the environment variable, and the tooling built afterwards
never pulled the lever. A reader with no setter — the mirror image of `NDTWIN_CLONE_DISABLE`,
which is a setter with no reader.

⚠️ **Not verified:** the flow-rule layer. `ovs-ofctl` is not in the passwordless sudoers set
(`ovs-vsctl` is), so "s1 gets rules naming a port that does not exist on it" remains the code
comment's account of 08-17. What is measured here is 100% loss on every pair, plus Ryu serving
128 hosts' paths on a 4-host fabric.

**Blast radius.** The 08-17 figures are unaffected — that round set the variable by hand. What
is invalid is any OVS 4-host comparison taken with `ndt up ovs4`, and the failure is
indistinguishable from a broken data plane. Reported to the session that owns `ndt`; not fixed
here to avoid two writers in one file. *(Fixed the same day: `c8d73a5` sets
`NDTWIN_RYU_TOPO_FILE` in `ndt:742` and adds a real-packet `verify_dataplane`.)*

### Consequence for this report's own 4-host cell

The three `/v1.0/topology/*` rows are sound: Ryu's topology *view* was correct (4 hosts, 10
switches, 32 links) and those endpoints serve that view, so they measure what they claim. The
`paths` row's 4-host cell is **not a 4-host control** — it is the 128-host path table under a
4-host label, which is exactly why its ratio is 1.09×. Do not read it as evidence that path
serialisation is host-count-independent.

The probe asserted host count from `/v1.0/topology/hosts` before measuring, and that assertion
passed truthfully — it just did not cover `all_destination_paths`, which does not derive from
discovered hosts. **An assertion has to cover the quantity being varied, not the one next to
it.**

## Where experiment ② should go next

`intelligent_router.py:149-165`. A link change is debounced, then `install_all_pair_paths`
walks **every host pair** — the code's own comment says "16256 of them on the 128-host
topology". At 4 hosts it is 12 pairs. **That is a 1355× swing in work sitting directly on the
failover path**, and P4 does not traverse it (it routes through the proxy).

The measurement to run: time from link-down to routes reinstalled, at 4 vs 128 hosts, with
`NDTWIN_RYU_TOPO_FILE` set correctly for the 4-host cell so the controller workload actually
differs between them.

Noted in passing, unverified: `_route_reinstall_worker` (`:166-169`) says a topology change
arriving while the worker is running is *dropped*. If so it is a correctness issue independent
of timing.

## Files here

| file | what |
|---|---|
| `ryu_topo_latency.py` | the probe; settles on host count before measuring, refuses on mismatch |
| `ryu_topo_4host.json`, `ryu_topo_128host.json` | raw per-rep timings, payload sizes, settle traces, fabric identification |
| `ovs4_connectivity_check.sh` | the ping that caught the `ndt up ovs4` defect |

Compare two cells with `python3 ryu_topo_latency.py --compare <4host.json> <128host.json>`.
