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
| OVS 20 Mbit/s | `2026-08-18_live-full-stack-round/sflow_runB_20M.jsonl.gz` | s1-eth2 † | — |
| P4 20 Mbit/s | `p4_stock_20M.jsonl.gz` | s1-eth1 | bmv2 stock `-O0` |
| OVS 200 Mbit/s | `2026-08-18_live-full-stack-round/sflow_runA_200M.jsonl.gz` | s1-eth2 † | — |
| P4 200 Mbit/s | `p4_fast_200M.jsonl.gz` | s1-eth1 | bmv2 fast `-O3` |

🔴 **Corrected 2026-08-20 after audit.** This table first said the P4 200 Mbit/s edge was
`s5-eth2`. **It is `s1-eth1`** — the same edge as the P4 20 Mbit/s run. The wrong value came
from an earlier throwaway script that picked the busiest edge by *tx-byte delta*, while
`plot_figures.py` picks by *summed twin reading*; the two disagree on three of the four runs,
and I merged output from both into one table without noticing.

Two consequences, in opposite directions:

- **The "different edge" confound disclosed below does not exist between the two P4 runs.** Both
  are `s1-eth1`. The load comparison is cleaner than the note originally claimed.
- **But `busiest_edge()` is dangerously fragile here.** On the P4 200 Mbit/s run the winning
  edge leads the runner-up by **1.0 quanta out of ~242,000 samples**. That argmax is decided by
  a single sFlow sample and could flip on a re-run. Any future analysis should name the edge
  explicitly rather than compute it.

† The two OVS edges are **hard-coded `s1-eth2`, inherited from the 08-18 round — not the busiest
edge**. `busiest_edge()` would return `s6-eth3` (20 Mbit/s) and `s9-eth3` (200 Mbit/s). Both
carry the flow, so the analysis stands, but the OVS and P4 cells were not selected by the same
rule and the note originally did not say so.

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

| run | λ (samples/window) | Fano (change-counted) | Fano (every window) | measured sd/mean | 1/√λ predicted |
|---|---|---|---|---|---|
| OVS 20 Mbit/s | 6.84 | 1.451 | **1.359** | 45.7% | 38.2% |
| P4 20 Mbit/s | 6.81 | 1.075 | **1.026** | 39.7% | 38.3% |
| OVS 200 Mbit/s | 67.53 | 1.064 | **1.040** | 13.0% | 12.2% |
| P4 200 Mbit/s | 67.26 | 0.982 | **0.963** | 12.1% | 12.2% |

🔴 **Corrected 2026-08-20 after audit — the third column is the one to quote.** `sample_stats()`
appends a count only when the twin reading *changes*. When two consecutive windows happen to
hold the same number of samples the second one is invisible, and those collisions cluster at the
mode — so dropping them removes mass from the centre and **biases Fano upward**. Measured drop
rate: **9.0% / 9.7%** at 20 Mbit/s (where λ is small and collisions are common) and **4.0% /
3.7%** at 200 Mbit/s. Counting every refresh window instead lowers every Fano by 0.02–0.09.

The qualitative conclusions survive — P4/200M is still the tightest at 0.963, OVS/20M is still
the clear outlier at 1.359 — but **"Fano ≈ 1.00 means Poisson" must be tested against a
simulated null, not against 1.00**, because the estimator itself does not score 1.00 on a
perfect Poisson stream. The figure `page39_quantisation-ladder-load.png` still prints the
change-counted values and should be re-rendered before use.

**Adam's hypothesis is confirmed.** 10× the load puts 9.9× the samples in the same 1 s window
and the dispersion falls by 3.5× (OVS) and 3.3× (P4) — √9.9 = 3.15. The jitter is not a
property of the instrument; it is 1/√(sample count), and sample count is set by load × window.

**The dispersion is not abnormal — it is Poisson.** P4 at 200 Mbit/s has Fano 0.98, i.e. a
textbook counting process with nothing added on top.

## Two corrections to Page 39b

🔴 **RETRACTED IN PART, 2026-08-20, after audit.** Correction (1) below claimed too much and its
final sentence — that the slide's speculative explanations are "not needed and not supported" —
**is withdrawn**. Blending is real and is *part* of the effect, but it cannot be the whole of it,
and I dismissed a rival explanation without testing it. See the retraction block after the table.

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

Three of the four land on theory once aligned.

### 🔴 Retraction: blending is real but is not the whole mechanism

The blend argument has a **hard arithmetic floor** that I did not check before publishing it.
Averaging two adjacent readings with weights `w` and `1-w` scales the variance by
`w² + (1-w)²`, which is minimised at `w = 0.5` and **cannot go below 0.500**. Measured
`var(sliced) / var(aligned)`:

| run | observed ratio | blending's hard floor |
|---|---|---|
| P4 20 Mbit/s | **0.482** | 0.500 — **violated** |
| P4 200 Mbit/s | 0.594 | 0.500 |
| OVS 20 Mbit/s | 0.641 | 0.500 |
| OVS 200 Mbit/s | 0.665 | 0.500 |

**P4 at 20 Mbit/s reduces variance by more than blending two draws can possibly explain.** So
something else is also at work, and the mechanism is not established.

Worse, the sentence this replaces declared the slide's two candidate explanations "not needed
and not supported" — while **quoting only the first of the two**. The slide's second candidate
was 「連續兩次孿生讀值之間有相關性」 (consecutive twin readings are correlated), and lag-1
autocorrelation is exactly what would push the ratio below the floor. Measured:

| run | ρ₁ | significance |
|---|---|---|
| OVS 20 Mbit/s | −0.094 | 2.2σ — significant |
| P4 200 Mbit/s | −0.067 | 2.0σ — marginal |
| OVS 200 Mbit/s | −0.062 | 1.8σ |
| P4 20 Mbit/s | **−0.032** | **0.8σ — not significant** |

So the correlation hypothesis **is** supported on OVS, and I dismissed it without testing it.
But it does **not** rescue the one cell that breaks the floor: on P4/20M, ρ₁ is not significant.

**Honest position: P4 does not sit below the floor once aligned (the original open question is
answered), but *why the sliced estimator under-reports by more than blending allows* is a new
open question, and neither my explanation nor the slide's covers P4/20M.** Do not put a
mechanism claim for this on a slide.

This is a repeat of a failure mode already on record: the arithmetic pointed the right
direction, and I stopped before checking whether the magnitude worked.

**(2) The residual anomaly is OVS at 20 Mbit/s, not P4.** It is the one cell that stays above
theory after alignment (91.1% vs 74.9%) and the one with Fano 1.43. Restricting to windows
that held exactly 1 s makes it *worse* (Fano 1.54), so the first hypothesis — that the twin's
refresh window sometimes stretches to 2 s and inflates the tail — is **refuted**: 2 s holds
carry the same mean count as 1 s holds (6.4 vs 6.9), not double.

**The mechanism for OVS/20M overdispersion is unknown.** It is not claimed here. Candidates not
tested: iperf3 UDP pacing burstiness at low rate; OVS's sampler not being a clean per-packet
Bernoulli draw. Note it is absent at 200 Mbit/s on the same plane.

## Answers to the three outstanding review questions (2026-08-20)

Two independent reviews — a Claude audit and a DeepSeek pass — converged on the same defects.
Four of their questions were answered by the corrections above. These three were not.

### Q4 — does the headline ratio hide the anomaly? **Yes, entirely, and it is quantifiable.**

The note reported "10× the load, 3.4× tighter, √9.9 = 3.15 predicted" as confirmation. Recomputed
with the corrected estimator:

| plane | λ ratio | observed tightening | pure-Poisson | gap | √(Fano₂₀/Fano₂₀₀) |
|---|---|---|---|---|---|
| OVS | 9.95 | 3.432× | 3.155× | **+8.1%** | **1.088** |
| P4 | 9.90 | 3.249× | 3.147× | +3.2% | 1.033 |

**The gap equals the Fano ratio to within a fraction of a percent on both planes.** So the
"better than predicted" tightening is not extra precision — it is the over-dispersion at
20 Mbit/s decaying toward Poisson at 200. The anomaly the note calls unexplained two sections
later was leaking into its own headline number, unlabelled.

What survives: **λ ∝ rate is arithmetic and 1/√λ is Poisson, so neither is a finding.** The
empirical content of the sweep is exactly one thing — **Fano ≈ 1**, i.e. that the counts really
are a Poisson process with nothing added. Adam's hypothesis is confirmed by that, not by the
3.4×. State it that way.

### Q5 — which commit produced `p4_fast_200M.jsonl.gz`? **`213d209` added it; but the commit is the wrong pin, and that is the real answer.**

Both `.jsonl.gz` files were added by `213d209`, collected against the tree at `b6b75fa`. So
"no commit documented" is answerable for the file.

🔴 **But a repo commit cannot pin this cell, because the thing that differs is not in the repo.**
The 200 Mbit/s P4 round required the `-O3` bmv2, selected by `bmv2_binary_override` pointing at
`/usr/local/bmv2-fast/bin/simple_switch_grpc` — an installed binary, 92,147,960 bytes, built
2026-08-15 15:11, with **no version file, no build record and no behavioral-model source SHA
stored anywhere beside it**. `tools/test_workflow/build_bmv2_fast.sh` is the recipe; nothing
records what it produced.

So the deck's A2b rule — every measured number carries the commit it was measured at — is
**unsatisfiable for this cell by a commit**. The honest citation names the binary and its build
date, not a SHA. **Actionable fix: have `build_bmv2_fast.sh` write a manifest (source SHA,
configure flags, date) into `/usr/local/bmv2-fast/`**, so future rounds can cite the data plane
they actually ran on. Until that exists, every `-O3` result in this project has an unpinned
dependency.

### Q7 — the "four rounds, four values" line. **Wrong, and it was copied rather than measured.**

The line "1490/1490/1494/1506 B" sits directly under a four-row table of these four traces,
which reads as if these traces produced it. They did not — it is a four-round history lifted
from the slide. Measured on the four traces in this document:

| trace | quantum | frame |
|---|---|---|
| OVS 20 Mbit/s | 3,059,712 | 1494 B |
| OVS 200 Mbit/s | 3,059,712 | 1494 B |
| P4 20 Mbit/s | 3,051,520 | 1490 B |
| P4 200 Mbit/s | 3,051,520 | 1490 B |

**Two distinct values, not four. 1506 occurs in none of them.** The underlying claim — the
quantum is per-flow and must not be hard-coded — still holds (1490 ≠ 1494), but the evidence
*in this document* is two values from two flow configurations, and the pairs repeat precisely
because each plane ran the same flow at both loads. Cite the history to the round that produced
it or drop it.

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
