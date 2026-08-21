# The missing 46 s is link-failure detection, and one line takes it back

[Co-developed with claude code -- Adam]

Measured 2026-08-21 at `07ae07c`, OVS plane. Raw output `lldp_detection.txt`, probe
`lldp_detection.sh`.

## What was open

`WALK_SWEEP.md` closed the recompute term at 2.166 s and left **46.6 s of the 51.75 s
128-host OVS outage unattributed**, with detection the only remaining candidate. This measures
detection directly.

## The mechanism, read from Ryu before measuring

`ryu/topology/switches.py`:

| constant | value | what it does |
|---|---|---|
| `LLDP_SEND_GUARD` | **0.05 s** | `hub.sleep()` after every send, so the loop is serialised |
| `LINK_LLDP_DROP` | **5** | a link dies only after 6 consecutive unanswered sends |
| `TIMEOUT_CHECK_PERIOD` | 5 s | how often `link_loop` looks |

`lldp_loop` walks **every port**, host-facing ones included, and nothing on a host answers
LLDP. So the interval between two probes of the *same* port is `ports x 0.05 s`, and detection
costs about six of those. Port count tracks host count while the switch topology does not move.

Predicted before running: 36 ports -> 10.8 s at 4 hosts, 160 ports -> 48.0 s at 128.

## Measured

n=3 per cell, `netem loss 100%` on an inter-switch link, same interface and same resolution
method as `measure_failover.sh`.

| | ports | detection | +debounce +walk | 2026-08-19 outage | detection's share |
|---|---:|---:|---:|---:|---:|
| 4 hosts | 36 | 10.26 / 14.30 / 14.77 → **13.11 s** | 16.11 s | 15.70 s | **84%** |
| 128 hosts | 160 | 42.48 / 45.84 / 46.25 → **44.86 s** | 51.30 s | 51.75 s | **87%** |

**The budget closes.** 44.86 + 3.00 debounce + 2.17 walk = 50.0 s against an independently
measured 51.75 s outage. Predicted detection was 48.0 s against 44.86 measured, within 7%.

Two internal checks fell out of the data rather than being aimed at: every cell's
`detect+debounce+walk` exceeded its detection by **exactly 3.00 s**, which is
`reinstall_quiet_period`; and the port counts were 36 and 160 exactly, as the layout predicts.

**So the answer to "why is OVS failover so slow at 128 hosts" is: it is not doing anything
slowly. It is waiting for six LLDP probes, and adding hosts stretches the interval between
them.** This is also why P4 does not scale the same way — the proxy beacons on a fixed
interval that does not depend on port count, which is the 3.30x vs 1.21x in
`page36_failover-decomposition.png`.

## The fix, measured rather than proposed

`NDTWIN_RYU_LLDP_GUARD` (new, `intelligent_router.py`) sets `Switches.LLDP_SEND_GUARD`.
Default unchanged; the override prints a line into the Ryu log so a run can prove it was in
effect, which this repo has twice needed and not had.

| 128 hosts | detection | +debounce +walk |
|---|---:|---:|
| guard 0.05 (Ryu default) | 44.86 s | 51.30 s |
| guard 0.01 | 12.74 / 10.84 / 10.95 → **11.51 s** | **17.91 s** |
| | **3.9x faster** | |

A 51.75 s outage becomes roughly **18 s** — the same band as P4's 16.59 s. The shortfall
against the predicted 5x is `TIMEOUT_CHECK_PERIOD`, a 5 s floor the guard cannot move.

### Why this lever and not the obvious one

The obvious lever is `LINK_LLDP_DROP`: require 2 misses instead of 5 and detection drops the
same way. **Do not.** That lowers the evidence needed to declare a link dead, and
`topology_manager.py:147-150` already argues a flapping link report is worse than a slow one —
every false positive tears an edge out of the graph and recomputes every route.

`LLDP_SEND_GUARD` is a different kind of change: **the threshold is untouched.** A link still
has to miss six consecutive probes. Only the interval between probes shrinks. The confidence
required to call a link dead is exactly what it was.

### What is not established

- **The false-positive rate.** B2 ②'s criterion is explicitly "judge by false positives, not
  by detection time", and this is n=3 over about five minutes with zero spurious deletions —
  nowhere near a false-positive study. **The number above is not a result against that
  criterion.** It says the lever exists and how far it moves; it does not say it is safe.
- **The control-channel cost.** At 160 ports, 0.05 -> 0.01 takes LLDP from ~20 to ~100
  packets/s to the controller. Nothing here measured what that does under load.
- **Whether 0.01 is the right value.** It was chosen to make the effect unambiguous, not
  tuned.

### The better fix, not implemented

Back off on ports that have **never** answered. Host ports never do; a failed inter-switch
port has answered before, so a "has ever received" bit separates them cleanly and a failed
link keeps full-rate probing. That makes detection depend on *switch* count instead of host
count — the scaling goes away rather than being divided by five. Ryu already has the predicate
(`_is_edge_port`); `lldp_loop` just does not consult it. Roughly ten lines, and it needs the
false-positive study either way.

## A probe defect worth recording

The first two attempts at the 128-host cell reported **"NO DETECTION within 180 s"**, which
read like a spectacular finding. It was a broken probe, twice over:

1. **The destination was wrong for the layout.** Hosts fill s1..s4 in blocks, so at 4 hosts
   `10.0.0.4` is on s4 and the path crosses an inter-switch link, but at 128 hosts it is on s1
   — the same switch as h1. The probe injected into `s1-eth6`, the **access link to h4**.
   There is no `Link` object on an access port, so no `EventLinkDelete` can ever fire, and no
   alternative path to a directly-attached host exists. The 2026-08-19 round used `10.0.0.33`;
   the probe now does too, per size.
2. **The guard meant to catch that was itself broken, twice.** It compared Ryu's REST
   `port_no` (zero-padded **hex**) against `ovs-ofctl`'s decimal as strings, so it disagreed
   for every port above 9; and it set its input with `VAR=x curl ... | python3`, which exports
   to `curl`, not to the checker. The checker died with `KeyError` and its failure shared an
   exit code with "not an inter-switch link", so **a guard that never ran was indistinguishable
   from a guard that had run and said no**.

Both are the same lesson one level up from the usual one: an injection must assert not only
that it took, but that it landed **in the right place** — and a guard that can fail must not
report failure the same way it reports a verdict. The probe now prints the flow-table rule it
resolved and the inter-switch ports Ryu can see, so a future run shows its own working.

A third run was uninterpretable for a duller reason: two invocations were writing to one
output file at once, because the previous background run had not finished when the next was
started. Its `detection=132.78s` line is discarded, not explained.
