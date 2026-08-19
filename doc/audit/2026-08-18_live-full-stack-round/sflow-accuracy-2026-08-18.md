# sFlow measurement accuracy — controlled run, 2026-08-18

Kernel `04b8933`, OVS/Ryu, NTG's 128-host topology with **no NTG traffic and no applications
running** (`stack.sh up ovs` covers steps 1–3 only; Energy-Saving and Traffic-Engineering are
launched separately and were not). Single fixed-rate UDP flow, h1 (10.0.0.1) → h65 (10.0.0.65).

Raw data and scripts: `runA_200M.jsonl`, `runB_20M.jsonl`, `run.py`, `analyse.py`,
`method_check.py`, `cadence.py`.

## Why this run exists

The previous round left two measurements filed as **open, mechanism not established**: on OVS
the twin's aggregate link usage ran ~17% *above* the kernel's byte counters (F-10), and on P4
it ran ~21% *below* (F-18). Two candidate explanations could not be separated at the time:
sampling noise plus a window mismatch (a methodology artefact), or a real defect.

Both were measured with a 1 s instantaneous twin read compared against a 25 s ground-truth
average, under varied NTG traffic. This run removes every one of those confounders.

## Instrument characterisation (done first, and it changed the design)

- **The twin refreshes `link_bandwidth_usage_bps` exactly once per second** — 32 value changes
  in 31.8 s at 4 Hz polling. Sampling at 1 Hz aliases; the previous round's 25 s interval
  observed ~4% of the seconds.
- **A value can hold for two consecutive seconds** (observed once in 32 s). So "count the
  transitions" drops a second. The run integrates `value × dt` instead, which is correct
  whatever the cadence does.
- **`get_graph_data` costs 57 ms** for the 128-host graph, so 4 Hz polling is comfortable.
- **ECMP put the flow on s1's *second* uplink**: the path is
  `s1-eth2 → s6-eth3 → s9-eth3 → s7-eth1`. The target link `s1-eth2` is a real 1 Gbit/s shaped
  link, which keeps F-8 (the hard-coded 1 Gbit/s default on 10 Gbit/s core links) out of the
  measurement.

## Run A — 200 Mbit/s, 900 s, 3599 samples at 4.00 Hz, 0 dropped

Ground truth 205.8 Mbit/s (tx_bytes delta on `s1-eth2`; above the 200 Mbit/s iperf3 payload
rate because it includes framing). Twin mean over all 1471 in-flow samples: **205.5 Mbit/s,
0.15% low**. Individual 1-second readings ranged 122.4 – 287.6 Mbit/s.

### Per-link `s1-eth2`

| T (s) | windows | ratio med | ratio min | ratio max | observed ±% | theory 196√(1/c) |
|---|---|---|---|---|---|---|
| 1 | 899 | 0.999 | 0.714 | 1.384 | 20.7 | 23.9 |
| 2 | 449 | 1.004 | 0.751 | 1.274 | 15.9 | 16.9 |
| 5 | 179 | 1.002 | 0.871 | 1.231 | 10.6 | 10.7 |
| 10 | 89 | 1.006 | 0.912 | 1.131 | 8.1 | 7.6 |
| 30 | 29 | 1.006 | 0.962 | 1.055 | 4.5 | 4.4 |
| 60 | 14 | 1.001 | 0.985 | 1.042 | 3.1 | 3.1 |
| 150 | 5 | 1.005 | 0.992 | 1.018 | 1.9 | 2.0 |
| 430 | 2 | 1.005 | 0.999 | 1.011 | 1.2 | 1.2 |

### Aggregate over all 32 switch-to-switch edges

| T (s) | windows | ratio med | observed ±% | theory ±% |
|---|---|---|---|---|
| 1 | 899 | 1.007 | 10.5 | 11.9 |
| 2 | 449 | 1.009 | 8.5 | 8.4 |
| 5 | 179 | 1.005 | 5.8 | 5.3 |
| 10 | 89 | 1.008 | 3.8 | 3.8 |
| 30 | 29 | 1.004 | 2.0 | 2.2 |
| 60 | 14 | 1.007 | 1.7 | 1.5 |
| 150 | 5 | 1.006 | 1.0 | 1.0 |
| 430 | 2 | 1.007 | 0.7 | 0.6 |

**Verdict: the estimator is unbiased (≤1% at every window) and its spread is the sampling-theory
floor, not something above it.** From 5 s outward the observed spread matches `196√(1/c)` to
within a fraction of a percent. There is a residual ~+0.5% in the aggregate that is consistent
across windows; it is small enough that this run cannot distinguish it from zero.

## Run B — 20 Mbit/s, 600 s, 2399 samples at 4.00 Hz, 0 dropped

One tenth the load, so a 1 s window carries ~7 samples instead of ~67. This is the regime where
the estimator is expected to be visibly bad, and the question is whether it stays *unbiased*
while being imprecise, or whether something else takes over once the sample count collapses.

Ground truth 20.6 Mbit/s. The twin never read zero (0 of 2399 samples).

### Per-link `s1-eth2`

| T (s) | windows | ratio med | ratio min | ratio max | observed ±% | theory ±% |
|---|---|---|---|---|---|---|
| 1 | 599 | 0.966 | 0.149 | 2.382 | 70.9 | 75.6 |
| 2 | 299 | 0.967 | 0.409 | 1.859 | 51.3 | 53.4 |
| 5 | 119 | 0.989 | 0.624 | 1.442 | 35.0 | 33.8 |
| 10 | 59 | 1.022 | 0.751 | 1.275 | 25.7 | 23.9 |
| 30 | 19 | 0.990 | 0.878 | 1.120 | 11.8 | 13.8 |
| 60 | 9 | 1.007 | 0.953 | 1.058 | 6.8 | 9.8 |
| 150 | 3 | 1.022 | 0.975 | 1.034 | 4.9 | 6.2 |

### Aggregate

| T (s) | windows | ratio med | observed ±% | theory ±% |
|---|---|---|---|---|
| 1 | 599 | 1.004 | 34.7 | 37.8 |
| 2 | 299 | 1.004 | 26.6 | 26.7 |
| 5 | 119 | 1.004 | 18.4 | 16.9 |
| 10 | 59 | 1.015 | 12.8 | 11.9 |
| 30 | 19 | 1.001 | 6.8 | 6.9 |
| 60 | 9 | 1.010 | 4.0 | 4.9 |
| 150 | 3 | 1.017 | 1.1 | 3.1 |

**It stays unbiased.** Nothing takes over at low sample counts: the median ratio is 0.97–1.02
throughout, and the spread again sits on `196√(1/c)`. What changes is only precision — a single
1-second reading at 20 Mbit/s ranged **0.149 to 2.382**, i.e. 85% low to 138% high.

Taken with run A, the formula is validated across a 10× range of offered load and a 430× range
of window length on the same instrument.

## The quantisation quantum is per-flow, not a constant

GCD of all 49 distinct non-zero values on `s1-eth2` in run A: **3,059,712 = 256 × 1494 × 8** —
the sFlow sampling rate times *this flow's* frame length. Run B gives the identical GCD from 17
distinct values, as it must: same flow shape, one tenth the rate.

Three rounds have now measured three different quanta (1494 here, 1506 in the previous round,
1490 on 2026-08-15) because each measured a different traffic mix. It is a sampling-granularity
effect that tracks real frame lengths, not a fixed multiplier.

Run B shows the consequence most clearly: at 20 Mbit/s the twin's reading takes only **15
distinct values across 10 minutes**, every one a multiple of 3.06 Mbit/s. On a 1 Gbit/s link a
flow is invisible below ~3 Mbit/s and `link_bandwidth_utilization_percent` moves in 0.31% steps.

## F-10 and F-18 revisited

`scratch/lab/tel.py` selected ground-truth interfaces with `int(k.split('-eth')[1]) <= 4`. On
the access switches s1–s4 only eth1/eth2 are uplinks — **hosts start at eth3** — so that rule
folds host-facing links into a "switch-to-switch" ground truth while the twin's sum correctly
excludes them. Ground truth is inflated; the ratio is pushed down by a fixed amount that does
not shrink with window length, which is exactly what a real bias looks like.

Applying each method to run A's data, where the corrected method returns 1.000:

| method | median ratio (35 windows) |
|---|---|
| `tel.py` as written (25 s, instantaneous twin read, `eth<=4`, >100 kbps floor) | **0.797** |
| … but integrating the twin over the window | 0.804 |
| … but using the real switch-to-switch interface set | **0.996** |
| … both fixes together | **1.006** |

The interface set is the entire bias. The instantaneous-read issue contributes spread
(min/max 0.717–0.901 vs 0.789–0.825) but no bias.

- **F-18 (P4, 0.79) is quantitatively consistent with being nothing but this artefact** and
  should not be treated as a kernel defect without a re-measurement.
- **F-10 (OVS, 1.17) is NOT explained by it.** The artefact pushes downward, so if it was
  present in that run the underlying discrepancy was *larger* than 1.17, not smaller. F-10
  stays open. What can now be said is that it is not a property of the measurement path in
  isolation — under a controlled single flow that path is unbiased — so any re-run should vary
  what F-10's configuration added: many concurrent flows, NTG's traffic pattern, and the
  applications being live.

## What this supports on a slide, and what it does not

Supported:

- The twin's per-link and aggregate usage estimates are unbiased against kernel byte counters —
  median ratio 0.97–1.02 at every window, at both loads.
- Their error is the sampling-theory floor `196√(1/c)`, validated across a 430× range of window
  length and a 10× range of offered load.
- Therefore accuracy is a function of window length and offered load, and is predictable in
  advance from `c = R·T / (256 · framebytes · 8)`.
- The measured resolution floor: one quantum of 3.06 Mbit/s, i.e. 0.31% of a 1 Gbit/s link.

The honest headline is not a number but a curve. A defensible one-line version: *"unbiased, with
precision set by sample count — ±21% at a 1 s window and 200 Mbit/s, ±1.2% at 430 s, exactly as
sampling theory predicts."*

Not supported by this run:

- Any single "we are accurate to X%" figure quoted without its window and load.
- Anything about P4/bmv2. This run is OVS only, and the P4 pipeline samples by a different
  mechanism (clone-based), so it needs its own measurement.
- Accuracy under many concurrent flows, or with the applications live. This is one flow on a
  quiet fabric by design — that is what makes it a clean instrument check, and also what stops
  it from settling F-10.
