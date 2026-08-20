# Ladder jitter: is it abnormal, and does it shrink with load?

2026-08-20. Prompted by two review comments on the progress report:

1. "page39 quantisation ladder 那張圖看起來 jitter 太大了，不太正常"
2. Adam: "我們量 200MB 的時候 jitter 小很多，會不會是因為 20MB 太少了?"

[Co-developed with claude code -- Adam]

## 🔴 What this is NOT

**No new live measurement was taken.** Nothing was run on a fabric for this note. Every number
below is a re-analysis of poll traces already committed under `doc/audit/`. The fabric was not
up (`pgrep simple_switch_grpc` = 0; OVS was running but idle).

Adam asked for the 200 Mbit/s case to be "量測一次" (measured). It was already measured, on
2026-08-18 (OVS) and 2026-08-19 (P4), under the *same* protocol as the 20 Mbit/s runs that
produced the existing ladder — so the ladder at 200 Mbit/s is a rendering of data in hand, not
a new experiment. **If a fresh run is wanted, this note does not supply it.**

## The four traces

| run | file | edge | build |
|---|---|---|---|
| OVS 20 Mbit/s | `2026-08-18_live-full-stack-round/sflow_runB_20M.jsonl.gz` | s1-eth2 | — |
| P4 20 Mbit/s | `p4_stock_20M.jsonl.gz` | s1-eth1 | bmv2 stock `-O0` |
| OVS 200 Mbit/s | `2026-08-18_live-full-stack-round/sflow_runA_200M.jsonl.gz` | s1-eth2 | — |
| P4 200 Mbit/s | `p4_fast_200M.jsonl.gz` | s5-eth2 | bmv2 fast `-O3` |

Collection protocol (unchanged, `2026-08-18_live-full-stack-round/run.py`): one fixed-rate UDP
flow; poll `/ndt/get_graph_data` at **4 Hz** while reading `/proc/net/dev` `tx_bytes` for every
`s*-eth*` in the **same pass**; ground truth is the tx_bytes delta over the same wall-clock
window, not the iperf3 target rate. 4 Hz is deliberate oversampling — the twin refreshes at
1 Hz, so polling at 1 Hz would alias.

⚠️ **Two variables move between the rows, not one.** The 200 Mbit/s P4 run needed the `-O3`
fast bmv2 build (stock tops out ~40 Mbps) and a different edge. Load is the variable of
interest; build and edge are confounds carried along with it. This is the same caveat already
on Page 39b and it is not removed by anything here.

## Method

The twin's reading divided by the quantum **is** the sFlow sample count for that window, so the
counting process can be recovered and tested directly instead of inferred from the spread:

- `quantum` = GCD of all non-zero readings on that edge = `256 × frame_bytes × 8`. Measured per
  run, never hard-coded — it is per-flow (four rounds, four values: 1490/1490/1494/1506 B).
- One count per **twin update**, not per poll. Counting polls would multiply every window by 4.
- **Fano factor** = variance/mean of those counts. A Poisson process gives exactly 1.00; above
  1.00 means something adds dispersion beyond the sampling itself.

Scripts: `analyse_q.py` (existing, unchanged), plus `sample_stats()` and `fig_quantum_load()`
added to `plot_figures.py`. Figure: `figures/page39_quantisation-ladder-load.png`.

## Results

| run | λ (samples/window) | Fano | measured sd/mean | 1/√λ predicted |
|---|---|---|---|---|
| OVS 20 Mbit/s | 6.84 | **1.43** | 45.7% | 38.2% |
| P4 20 Mbit/s | 6.81 | 1.08 | 39.7% | 38.3% |
| OVS 200 Mbit/s | 67.53 | 1.14 | 13.0% | 12.2% |
| P4 200 Mbit/s | 67.26 | **0.98** | 12.1% | 12.2% |

**Adam's hypothesis is confirmed.** 10× the load puts 9.9× the samples in the same 1 s window
and the dispersion falls by 3.5× (OVS) and 3.3× (P4) — √9.9 = 3.15. The jitter is not a
property of the instrument; it is 1/√(sample count), and sample count is set by load × window.

**The dispersion is not abnormal — it is Poisson.** P4 at 200 Mbit/s has Fano 0.98, i.e. a
textbook counting process with nothing added on top.

## Two corrections to Page 39b

**(1) The "P4 散布一致低於理論地板，機制未明" open question is answered, and it was an artefact
of the analysis script, not a property of bmv2.**

`analyse_q.py` slices 1 s windows out of the 4 Hz poll, but the twin refreshes on *its own*
1 s boundary, which those slices are not aligned to. Each analysis window is therefore a
time-weighted blend of two consecutive twin readings, and blending two independent draws
reduces variance. Taking one twin update per window instead — aligned by construction —
pushes the spread back up onto the theory line:

| run | sliced at 4 Hz | aligned to twin updates | theory |
|---|---|---|---|
| OVS 20 Mbit/s | 70.9% | **91.1%** | 74.9% |
| P4 20 Mbit/s | 54.6% | **78.7%** | 75.1% |
| OVS 200 Mbit/s | 20.7% | **25.6%** | 23.9% |
| P4 200 Mbit/s | 18.2% | **23.7%** | 23.9% |

Three of the four land on theory once aligned. **The slide's speculative explanations —
"bmv2 的 `random()` 每包不獨立 / systematic 而非 Bernoulli" — are not needed and are not
supported.** P4 sits on the floor, it does not sit below it.

**(2) The residual anomaly is OVS at 20 Mbit/s, not P4.** It is the one cell that stays above
theory after alignment (91.1% vs 74.9%) and the one with Fano 1.43. Restricting to windows
that held exactly 1 s makes it *worse* (Fano 1.54), so the first hypothesis — that the twin's
refresh window sometimes stretches to 2 s and inflates the tail — is **refuted**: 2 s holds
carry the same mean count as 1 s holds (6.4 vs 6.9), not double.

**The mechanism for OVS/20M overdispersion is unknown.** It is not claimed here. Candidates not
tested: iperf3 UDP pacing burstiness at low rate; OVS's sampler not being a clean per-packet
Bernoulli draw. Note it is absent at 200 Mbit/s on the same plane.

## Baseline check (`28b8b13`)

Does the inherited fork have this jitter? **Yes — the arithmetic that produces it is inherited
verbatim.** Verified by extracting the function from both trees and diffing:

- `TopologyAndFlowMonitor::updateLinkInfoLeftLinkBandwidth` — **byte-identical**, 37 lines.
- The accumulator `inputByteCountOnALinkMultiplySampingRate += frameLength * samplingRate`
  and the report-then-reset (`... * 8`, then `= 0`) are baseline code
  (`FlowLinkUsageCollector.cpp:1365-1366` at `28b8b13`).

So `linkBandwidthUsage` = (bytes seen this tick) × 256 × 8, reset each tick — which is exactly
why readings are integer multiples of `256 × frame_bytes × 8`, and why a 1 s window at 20 Mbit/s
can only report ~7 rungs. **The quantisation and its dispersion are baseline behaviour that our
P4 work reproduced faithfully, not something introduced by it.**

⚠️ Not verified live: no baseline binary was built or run for this note. The claim is a
code-identity claim, not a measurement.
