# Adversarial audit — METHOD_jitter-and-load.md

Auditor: separate Claude session, 2026-08-20. Independent recomputation; the author's
`analyse_q.py` / `plot_figures.py` were read only to find out *what* was claimed, and all
numbers below come from a script written from scratch
(`scratchpad/aud1.py`, `aud2.py`, …).

Status: COMPLETE. Sections A–K.

---

## A. Facts in the note's own methods table that are wrong

### A-1 — "P4 200 Mbit/s … edge s5-eth2" — **REFUTED**

The note's trace table (line 28) says the P4 200 Mbit/s run was analysed on `s5-eth2`, and the
⚠️ box at line 36 uses that to declare "a different edge" as a confound alongside the `-O3`
build.

`plot_figures.py:631-640` passes `busiest_edge(p4F)`, not a literal. I recomputed
`busiest_edge` on both P4 traces:

| trace | Σ twin s1-eth1 | Σ twin s5-eth2 | `busiest_edge` returns |
|---|---|---|---|
| `p4_stock_20M` | 49,739,776,000 | 49,330,872,320 | **s1-eth1** |
| `p4_fast_200M` | 738,519,715,840 | 738,516,664,320 | **s1-eth1** |

Both P4 runs are analysed on **the same edge, s1-eth1**. The "different edge" confound as
written does not exist.

Worse in the other direction: the margin in the 200 Mbit/s trace is **3,051,520 out of
7.4e11 — 0.0004%, exactly one quantum**. `busiest_edge` is an argmax over two edges that carry
the same flow and differ by one sample out of ~242,000. Which edge gets analysed is decided by
a coin-flip-scale difference. That is a real fragility the note does not mention, and it is a
*better* criticism than the one the note volunteered. (I checked whether the two edges are
telemetry duplicates of each other — the "proxy restart × warm fabric" shape. They are not:
the s5-eth2/s1-eth1 per-row ratio ranges 0.125–12.0, mean 1.23, i.e. two independent counting
processes on the same flow. That alternative is ruled out, not assumed away.)

### A-2 — "four rounds, four values: 1490/1490/1494/1506 B" — **MISLEADING AS PLACED** (not fabricated)

Measured GCD/2048 on the four traces actually analysed:

| run | edge | quantum | frame bytes |
|---|---|---|---|
| OVS 20M | s1-eth2 | 3,059,712 | **1494** |
| P4 20M | s1-eth1 | 3,051,520 | **1490** |
| OVS 200M | s1-eth2 | 3,059,712 | **1494** |
| P4 200M | s1-eth1 | 3,051,520 | **1490** |

The note's four traces yield **1494 / 1490 / 1494 / 1490** — two distinct values, and **1506 does
not occur in any of them**.

I traced the list and it is not invented: Page 39b of the slide says
「現在有四個值（1490 / 1490 / 1494 / 1506）」, a four-*round* history
(08-15 = 1490, this P4 round = 1490, this OVS round = 1494, the previous round = 1506, per
`2026-08-18_live-full-stack-round/sflow-accuracy-2026-08-18.md:116`). The note copied it verbatim.

Two defects remain. (i) It is placed in the Method section immediately under "Measured per run,
never hard-coded", directly below a four-row table — so it reads as *this table's four rows*,
which it is not, and the reader who checks will get 1494/1490/1494/1490 and think the note is
wrong. (ii) "four values" is not four values in either source: 1490 appears twice, so it is
three distinct values over four rounds. The slide has the same error; the note inherited it
rather than checking. **Fix by writing "four rounds have measured three distinct values
(1490, 1494, 1506); this note's own four traces measured 1494/1490/1494/1490."**

---

## B. The quantum estimator (audit item 1)

### B-1 — "exact integer multiples" is **CIRCULAR, not a check**

`quantum()` returns `reduce(gcd, distinct_nonzero_readings)`. A GCD divides every element of the
set it was computed from, so `reading % quantum == 0` for **100.0000% of readings in all four
traces, necessarily**. I ran it and got exactly 100% four times — and that number carries zero
information. Any dataset whatsoever scores 100% here. If the note (or the slide) ever leans on
"the readings are exact multiples of the quantum" as *evidence* that the quantum is the sample
size, that is an unfalsifiable claim. The note does not state it that baldly, but the Method
bullet "The twin's reading divided by the quantum **is** the sFlow sample count" is asserted,
never tested against anything that could have failed.

**The check that would not have been circular, and that I ran:** the recovered integers must be
*small and contiguous* if the quantum is one sample-batch. They are:

| run | reading/q integer range | # distinct |
|---|---|---|
| OVS 20M | 1 … 19 (17 present) | 17 |
| P4 20M | 1 … 16 | 16 |
| OVS 200M | 40 … 94 (51 present) | 51 |
| P4 200M | 41 … 94 (47 present) | 47 |

and the implied `q/2048` must land on a physically legal Ethernet frame length. 1490 B and
1494 B both do (1490 = 1448 payload + 8 UDP + 20 IP + 14 Ethernet, corroborated independently at
`2026-08-15_fresh-acceptance-report.md:125` from a packets/bytes division that never touches the
twin). **This is the load-bearing evidence, and the note does not cite it.**

### B-2 — mixed frame sizes: the estimator **does** collapse, and nothing guards it — **CONFIRMED RISK**

The audit prompt's worry is correct and the failure mode is silent. If a flow mixed 1490 B and
1494 B frames, `gcd(256·1490·8, 256·1494·8) = 2048·gcd(1490,1494) = 2048·2 = 4096`. Every
downstream number then changes by a factor of ~745: λ would read ~5,100 instead of 6.84, Fano
would read ~1/745 of its true value, and `1/√λ` would predict a spread of 2.7% — and **the note's
100%-exact-multiple check would still pass**, because it always passes.

`quantum()` has no sanity assertion. Nothing checks that `q/2048` is an integer, that it lies in
[64, 9000], or that the recovered counts are O(10)–O(100). A single stray reading from a
different-MTU flow on the same edge silently destroys the entire analysis. The four traces here
happen to be single-flow and clean — I verified each run's readings are all multiples of a
single plausible frame size — so **the published numbers are not affected**. But the method as
written is not safe to re-run on any mixed trace, and the note presents it as a general
technique ("Measured per run, never hard-coded") without that caveat.

---

## C. λ and Fano (audit item 2) — reproduced exactly, then re-tested

I reimplemented the estimator from the note's prose and hit the published numbers to 3 s.f.:

| run | note λ | **mine** | note Fano | **mine** |
|---|---|---|---|---|
| OVS 20M | 6.84 | **6.842** | 1.43 | **1.428** |
| P4 20M | 6.81 | **6.811** | 1.08 | **1.075** |
| OVS 200M | 67.53 | **67.532** | 1.14 | **1.140** |
| P4 200M | 67.26 | **67.264** | 0.98 | **0.982** |

Arithmetic: **CONFIRMED**. The estimator behind it: **BIASED, and the note never establishes its
null.**

### C-1 — `sample_stats` silently discards ~1 update in 9 — **NEW, not disclosed**

`sample_stats` emits a count only when `v != prev`. Two consecutive twin refreshes that land on
the same integer are recorded **once**. Measured retention against the wall-clock 1 Hz refresh:

| run | counts emitted | 1 Hz updates in span | retained |
|---|---|---|---|
| OVS 20M | 526 | 600 | **87.7%** |
| P4 20M | 546 | 600 | **91.0%** |
| OVS 200M | 871 | 900 | **96.8%** |
| P4 200M | 864 | 900 | **96.0%** |

The discarded updates are not a random sample — a repeat is likeliest at the mode, so
de-duplication preferentially deletes *central* values and **inflates** variance and Fano. This
is a bias in the direction that makes the note's conclusions look better, and it is larger at
20 Mbit/s than at 200 Mbit/s, i.e. it is confounded with the note's own independent variable.

### C-2 — I measured the null the note never measured

Fed i.i.d. Poisson (true Fano = 1.000 by construction) through the note's estimator, 3000 trials:

| stream | Fano with no de-dup | **Fano through the note's estimator** | 95% null band |
|---|---|---|---|
| λ=6.84, n=600 | 0.998 ± 0.057 | **1.053 ± 0.059** | 0.942 – 1.169 |
| λ=67.4, n=900 | 1.001 ± 0.048 | **1.019 ± 0.049** | 0.925 – 1.115 |

So "Fano = 1.00 means Poisson" is **wrong for this estimator**: a perfect Poisson process scores
1.053 at 20 Mbit/s and 1.019 at 200 Mbit/s. Re-reading the four results against their correct
null:

| run | Fano | expected under Poisson | z | verdict |
|---|---|---|---|---|
| OVS 20M | 1.428 | 1.053 | **+6.4** | genuinely over-dispersed — note is right |
| P4 20M | 1.075 | 1.053 | +0.4 | indistinguishable from Poisson — note is right |
| OVS 200M | **1.140** | 1.019 | **+2.5** | **over-dispersed. The note treats this as clean.** |
| P4 200M | 0.982 | 1.019 | −0.8 | consistent with Poisson (its de-biased value is ~0.96) |

### C-3 — "Note it is absent at 200 Mbit/s on the same plane" — **REFUTED**

That clause (line 101) is the note's reason for shelving the OVS over-dispersion as a low-rate
curiosity. It is not absent. OVS at 200 Mbit/s scores Fano 1.140 against a null of 1.019 ± 0.049
— **+2.5σ, p ≈ 0.007 one-tailed** — while P4 on the same statistic at the same load scores
−0.8σ. Over-dispersion is present on OVS at *both* loads and on P4 at *neither*. That is a
consistent per-plane signal, and the note argues the opposite from the same four numbers,
because it compared 1.14 against 1.00 instead of against the null its own estimator produces.

This is exactly the failure mode the audit brief warned about: 1.14 is "close to 1", the
direction was agreeable, and the magnitude was never given a yardstick.

---

## D. The "2 s window" refutation (audit item 5) — **CONFIRMED, and stronger than the note knew**

Note's numbers, and mine:

| quantity | note | **mine (OVS 20M)** |
|---|---|---|
| mean count, 1 s holds | 6.9 | **6.91** (n=462) |
| mean count, 2 s holds | 6.4 | **6.38** (n=55) |
| Fano restricted to 1 s holds | 1.54 | **1.533** |

The stretch hypothesis predicts the 2 s holds carry **13.7**. They carry 6.38. **Refutation:
CONFIRMED.** The arithmetic and the logic both hold.

### D-1 — the note stopped one step short of the *positive* result

Refuting "the window stretches" leaves the holds unexplained. They are fully explained by chance:
two consecutive independent Poisson draws landing on the same integer. I computed that null:

| | observed (OVS 20M) | i.i.d. Poisson prediction |
|---|---|---|
| P(a reading repeats) | 12.3% | **10.9%** (analytic Σp(k)²; 3.44% at λ=67.5, observed 3.2%/4.0%) |
| mean count of a 2 s hold | 6.38 | **6.60** (analytic E[k·p(k)²]/Σp(k)² = λ − 0.25) |
| number of ≥3 s holds | 7 (OVS), 6 (P4) | **≈7.1** (600·0.109²) |

Chance repeats predict the repeat rate, the *depth* of the dip in their mean count, **and** the
triple-hold count, at both loads, on both planes. The twin's refresh is a clean 1 Hz with no
stretching whatsoever — a stronger and more useful statement than "hypothesis refuted", and the
note does not make it.

### D-2 — "restricting to 1 s holds makes it *worse* (1.54)" is mostly the selection, not a finding

The note offers 1.428 → 1.533 as if the rise were informative. Under **pure i.i.d. Poisson** the
same restriction raises the note's Fano from 1.053 → **1.114 ± 0.067**: removing the repeats
removes near-mode values, so Fano must rise. The observed rise (+0.105) is barely larger than the
null rise (+0.061). The conclusion drawn from it is still correct; the number is presented as
evidence with more weight than it carries.

### D-3 — the alternative reading the note misses, and it indicts the note's own estimator

Once D-1 establishes that 2 s holds are coincidental repeats rather than stretched windows, it
follows immediately that **each one is two real twin updates recorded as one** — which is exactly
the C-1 de-duplication defect. The note's own §(2) proves the premise and never draws the
conclusion. The "6.4 vs 6.9" that the note uses to close one question is simultaneously the
measurement that opens another about its own instrument.

---

## E. The alignment hypothesis (audit item 4) — **DIRECTION RIGHT, MAGNITUDE WRONG**

This is the note's most load-bearing claim, so it gets the harshest test. My reimplementation
reproduces the note's *sliced* column to 0.1 pp and its *aligned* column to ~1.6 pp:

| run | sliced (note / **mine**) | aligned (note / **mine**) |
|---|---|---|
| OVS 20M | 70.9 / **70.9** | 91.1 / **89.5** |
| P4 20M | 54.6 / **54.6** | 78.7 / **77.9** |
| OVS 200M | 20.7 / **20.7** | 25.6 / **25.5** |
| P4 200M | 18.2 / **18.2** | 23.7 / **23.7** |

### E-1 — the "aligned" column is not independent evidence; it is the Fano column re-expressed

`aligned = 1.96·√(Fano/λ)` identically. Check: 1.96·√(1.43/6.84) = 89.6 ≈ 91.1;
1.96·√(1.08/6.81) = 78.0 ≈ 78.7; 1.96·√(1.14/67.53) = 25.5 ≈ 25.6;
1.96·√(0.98/67.26) = 23.7 = 23.7. And `theory = 1.96/√λ`. So "**three of the four land on
theory once aligned**" is an algebraic restatement of "**three of the four have Fano ≈ 1**". It
is presented as a second, corroborating observation. It is the same observation.

Consequence: the aligned column inherits the C-1 de-dup inflation in full. The note's headline
"**P4 sits on the floor, it does not sit below it**" rests on an estimator biased *upward* by
~5% in variance at 20 Mbit/s. De-biased, P4 200M's aligned spread is 23.5% against a 23.9% floor
and OVS 20M's is 87.3% — i.e. **the de-biased P4 numbers sit slightly BELOW the theory line
again**, which is the very open question the note claims to have closed.

### E-2 — I computed the predicted variance-reduction factor. It does not match. — **the headline defect**

The mechanism is: a 1 s analysis window straddles two twin readings with time weights *w* and
*1−w*, so `Var = (w² + (1−w)²)·σ²`. This factor **cannot go below 0.500** (attained only at
w = 0.5 in every window) and equals 0.667 for uniformly-distributed phase.

I did not assume the phase — I **measured** it, window by window, from the poll timestamps, and
took `E[w² + (1−w)²]` over the actual weights:

| run | measured w (mode) | **predicted var factor** | **observed (sliced/aligned)²** | shortfall |
|---|---|---|---|---|
| OVS 20M | 0.75 / 1.0 / 0.5 mixed, mean 0.768 | **0.713** | **0.627** | −12.1% |
| P4 20M | 0.50 in 544/599 windows | **0.546** | **0.492** | −9.9% |
| OVS 200M | mean 0.761 | **0.702** | **0.660** | −6.0% |
| P4 200M | 0.75 in 852/899 windows | **0.645** | **0.593** | −8.1% |

**All four observed reductions are stronger than the mechanism can produce, in the same
direction, by 6–12%.** And P4 20M's 0.492 is below 0.500 — *below the hard floor of the
mechanism the note invokes*. A two-reading blend cannot do that at any phase.

So: blending is real (the measured phases are genuinely non-degenerate — note that the P4 runs
sit almost perfectly on w = 0.5 and w = 0.75, which is itself a finding: the poll clock is
phase-locked to the twin, it is not drifting), it is the dominant term, and it points the right
way. **But it does not account for the whole gap, and the note declares the question "answered"
on the strength of the direction alone.** That is the documented failure mode, reproduced.

Residual to be explained: 6–12% of variance. Tested next.

### E-3 — I chased the residual. One of my own hypotheses died; the survivor is the hypothesis the note dismissed

**My first guess — REFUTED by my own test.** The sliced estimator divides each window by a
ground truth measured over that same window, cancelling traffic-rate jitter; the aligned column
divides by the grand mean and keeps it. If so, apples-to-oranges. I rebuilt the aligned column
with a per-window `tx_bytes` denominator: **identical to 0.1 pp in all four runs**, because the
iperf3 rate jitter is only **0.2%** (0.7% for P4 200M) and contributes nothing next to a 50–90%
sampling spread. Dead end, stated because it is the check that could have rescued the note's
number and did not.

**What actually accounts for it: the de-dup bias plus a lag-1 correlation the note rules out.**

Two terms are missing from the note's reasoning.

*(i)* The aligned denominator is the de-dup-inflated variance (C-1). Restoring the repeats —
justified by D-1, which shows holds are coincidental, so a k-second hold is k identical updates —
gives the **unbiased** Fano:

| run | note's Fano | **unbiased Fano** |
|---|---|---|
| OVS 20M | 1.428 | **1.318** |
| P4 20M | 1.075 | **1.028** |
| OVS 200M | 1.140 | **1.116** (still +2.4σ over-dispersed — C-3 survives) |
| P4 200M | 0.982 | **0.963** (sub-Poisson, −0.8σ, not significant alone) |

*(ii)* The blending formula `w² + (1−w)²` assumes the two readings are **independent**. The full
expression is `w² + (1−w)² + 2w(1−w)·ρ₁`. I measured ρ₁ on the reconstructed true update
sequence against a simulated null of 0.000 ± 0.041 (n=600) / ± 0.034 (n=900):

| run | **measured ρ₁** | z | blend only | blend + ρ₁ | observed (both corrections) | gap |
|---|---|---|---|---|---|---|
| OVS 20M | **−0.150** | **−3.7** | 0.713 | **0.670** | **0.677** | **+0.007 ✔** |
| P4 20M | +0.014 | +0.3 | 0.546 | 0.552 | 0.516 | −0.036 |
| OVS 200M | −0.047 | −1.4 | 0.702 | 0.688 | 0.675 | −0.013 |
| P4 200M | −0.046 | −1.4 | 0.645 | 0.629 | 0.605 | −0.023 |

**Verdict on the alignment hypothesis: CONFIRMED IN MAGNITUDE, but only after two corrections
the note never made.** Done properly it closes to +0.007 on OVS 20M and to within 2–4% on the two
200 Mbit/s runs; P4 20M still leaves 3.6% of variance unexplained. Done the note's way — compare
70.9 to 91.1, observe the direction, declare the question answered — it is off by up to 12% and
one cell (P4 20M, 0.492) sits *below the mechanism's hard floor of 0.500*, which should have been
caught as impossible.

### E-4 — the note's dismissal of the slide's hypothesis is right for P4 and **wrong as written**

Line 89-91: *"The slide's speculative explanations — bmv2 的 `random()` 每包不獨立 / systematic
而非 Bernoulli — are not needed and are not supported."*

- **"Not supported" for bmv2/P4: CONFIRMED.** P4 20M has ρ₁ = +0.014 (z = +0.3) and unbiased
  Fano 1.028. On the plane the slide's speculation was actually about, per-packet independence is
  not detectably violated at 20 Mbit/s. The note reaches the right answer.
- **"Not needed" as a blanket statement: REFUTED.** Non-independence is not a spare hypothesis —
  it is the term that makes the note's own alignment arithmetic balance. On OVS 20 Mbit/s
  ρ₁ = −0.150 at 3.7σ, and putting it in is what takes the predicted factor from 0.713 to 0.670
  against an observed 0.677. Negative lag-1 correlation with an over-dispersed marginal is the
  classic signature of a sampler carrying residue across its reset — i.e. *systematic rather than
  Bernoulli* — which is the mechanism the note declares unnecessary, on the plane where it is
  measurable.

The note never ran an independence test in either direction. It dismissed a mechanism hypothesis
because a *different* explanation pointed the right way. That is the same move the audit brief
flags, applied to the note's own most confident sentence.

### E-5 — a real finding the note walked past

The measured phase weights are not drifting: P4 20M sits at w = 0.50 in **544 of 599** windows and
P4 200M at w = 0.75 in **852 of 899**. The 4 Hz poll is phase-locked to the twin's 1 Hz refresh,
not sliding through it. That matters two ways the note does not mention: (a) it means the
"misalignment" is a *fixed* offset, so the artefact is deterministic and exactly correctable
rather than something that averages out over a long run; (b) OVS shows a genuine mixture
(0.75/1.0/0.5) while P4 is locked — the two planes are not being sliced the same way, which is a
methodological asymmetry sitting underneath a P4-vs-OVS comparison.

---

## F. The headline: 10× load → √10 tighter (audit item 3)

### F-1 — every number in the Results table reproduces — **CONFIRMED**

| quantity | note | mine |
|---|---|---|
| λ ratio OVS | 9.9× | **9.870×** |
| λ ratio P4 | 9.9× | **9.876×** |
| sd/mean, 4 cells | 45.7 / 39.7 / 13.0 / 12.1 | **45.7 / 39.7 / 13.0 / 12.1** |
| 1/√λ, 4 cells | 38.2 / 38.3 / 12.2 / 12.2 | **38.2 / 38.3 / 12.2 / 12.2** |
| dispersion falls by | 3.5× (OVS), 3.3× (P4) | **3.515× / 3.281×** |

The headline survives de-biasing too: with unbiased Fano the ratios are 3.41× and 3.25×, still
√10. **Claim CONFIRMED.**

### F-2 — but the note's own prediction misses by 11% and it does not say so

"the dispersion falls by **3.5×** (OVS) and 3.3× (P4) — **√9.9 = 3.15**." 3.515 against 3.15 is
**+11.6%**. The note prints the miss and reads it as agreement.

The miss is not noise, it is a known quantity: the correct prediction is
`√(λ₂₀₀/λ₂₀) · √(Fano₂₀/Fano₂₀₀)`, which for OVS is 3.142 × 1.119 = **3.516** against an observed
3.515, and for P4 3.142 × 1.046 = **3.288** against an observed 3.281. Both exact to three
figures. The extra factor is the OVS over-dispersion ratio — the very thing the note discusses
two sections later without connecting it to the headline. **A committee member who divides
3.5/3.15 in their head gets 1.11 and asks where it went; the note has no answer prepared,
though the answer is in its own table.**

### F-3 — the note's headline sentence overstates what a counting argument can establish

"10× the load puts 9.9× the samples in the same 1 s window and the dispersion falls by 3.5×."
Given λ = rate·T/q, **λ ∝ rate is arithmetic, not a result**, and 1/√λ follows from Poisson.
The only empirical content in the whole headline is *Fano ≈ 1*, i.e. that the counting really is
Poisson at both loads. Framed as "Adam's hypothesis is confirmed" it reads as an experimental
finding; it is one measurement (Fano) plus two divisions. That is not wrong, it is oversold —
and it matters because the actual empirical content is precisely where the estimator bias of
C-1/C-2 lives.

### F-4 — the −O3 confound: disclosure is **NOT** sufficient, but not for the reason the note fears

The note's ⚠️ box treats "build + edge" as a blanket caveat on the whole table and says it "is
not removed by anything here". Two problems, in opposite directions.

**(a) The note fails to invoke the controls its own design already contains.**
- *Load claim* (10× → √10): demonstrated on **OVS alone**, where there is no build change and no
  edge change (s1-eth2 both times), at 3.515× vs 3.516× predicted. The confound cannot touch it.
  The P4 row corroborates. The load claim is far better protected than the note admits.
- *Plane claim at 20 Mbit/s* (P4 cleaner than OVS): P4 20M is the **stock −O0** build. Fano 1.075
  vs 1.428, same load, neither side modified. Also clean.

**(b) The note states one claim confidently that the confound genuinely does hit.** §"Two
corrections", point (2): *"The residual anomaly is OVS at 20 Mbit/s, not P4"*, supported by
"P4 at 200 Mbit/s has Fano 0.98, i.e. a textbook counting process with nothing added on top."
That specific cell is the **only** one produced by a rebuilt binary, and Fano is a property of
the sampler — which is code that `-O3` recompiled. There is no OVS-side equivalent rebuild, so
nothing in the design isolates it. Combined with C-3 (OVS at 200 Mbit/s is *also* over-dispersed,
+2.5σ), the "textbook 0.98" cell is doing more work than any single confounded cell should.

So: **disclosure is necessary and not sufficient.** A blanket ⚠️ that applies the caveat
everywhere is indistinguishable from applying it nowhere. What is missing is one sentence per
claim saying which cells carry it and whether those cells are confounded — at which point three
of the note's claims get *stronger* and one gets weaker. **And the disclosure is factually wrong
about half its content: the edge does not change (A-1).**

---

## G. The baseline claim (audit item 6)

### G-1 — byte-identity: **CONFIRMED**, verified independently

`git show 28b8b13:…TopologyAndFlowMonitor.cpp | sed -n '675,719p'` vs
`git show HEAD:… | sed -n '1066,1110p'` → `diff` reports **no differences over 45 lines**
(the note says 37; the difference is where you cut the signature and blank line, immaterial).
`FlowLinkUsageCollector.cpp:1365-1366 at 28b8b13` reads exactly as the note quotes it. Both
citations check out — worth confirming first given this project's history of a misread line
number propagating into four documents, and they hold.

### G-2 — but the byte-identical function **contains none of the arithmetic being claimed**

Substance of the whole verified function:

```
uint64_t leftIn = estimatedIn > linkBandwidth ? 0 : linkBandwidth - estimatedIn;
edgeProps.leftBandwidthFromFlowSample = leftIn;
edgeProps.linkBandwidthUtilization   = (1.0 - (double)leftIn/linkBandwidth) * 100;
edgeProps.linkBandwidthUsage         = leftIn > linkBandwidth ? 0 : linkBandwidth - leftIn;
```

`linkBandwidthUsage` = `linkBandwidth − (linkBandwidth − estimatedIn)` = **`estimatedIn`**. A
subtract-and-add-back round trip. No `× 256`, no `× 8`, no accumulator, no reset — the quantum is
fully determined before this function is entered.

**The note verifies byte-identity of a pass-through and presents it as verification that "the
arithmetic that produces it is inherited verbatim."** Different artefact. The accumulator and
reset are then *asserted* to be baseline without extending the diff to them.

### G-3 — what else on the path changed: a lot, and the note checks none of it

`git diff --stat 28b8b13 HEAD`:

| file | lines changed |
|---|---|
| `src/ndt_core/collection/FlowLinkUsageCollector.cpp` — **the file that actually does the quantising** | **1127** |
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp` | 956 |
| `src/ndt_core/http/HttpSession.cpp` — serves `/ndt/get_graph_data`, the trace's only input | 867 |

Structurally the producer side has **doubled**:

| | 28b8b13 | HEAD |
|---|---|---|
| accumulate `frameLength × samplingRate` | 1 site (L1108) | **2 sites** (L1433, L1445) |
| report `× 8` then reset to 0 | 1 site (L1365-66) | **2 sites** (L1841-42, L1672-74) |

The second of each is new code in a new function `creditHostBoundEgressEdges()`, carrying
`[Co-developed with claude code -- Adam]`. There is now a second producer writing into the
byte-identical consumer the note diffed. **Byte-identity of a consumer says nothing about a new
producer.** Nor does it cover the sampling rate (256), the tick period, or the new
`isIngress && outputPort != 0` guard that changes which samples get banked at all.

### G-4 — I ran the check the note should have run, and the claim survives on the merits

Verdict: **CONFIRMED, but by different evidence than the note offers.**

- The ingress accumulation line — the one that produces the analysed readings — *is*
  byte-identical: `m_counterReports[…].inputByteCountOnALinkMultiplySampingRate += uint64_t(frameLength) * samplingRate;`
  at 28b8b13 L1108 and HEAD L1432, with identical `relevantPort` derivation
  (`isIngress ? inputPort : outputPort`) at 28b8b13 L1067-68 and HEAD L1392-93.
- The report-and-reset tick block is byte-identical; `creditHostBoundEgressEdges()` is *appended
  after* it, not woven into it.
- The new path pays out **host-bound** edges only. Every analysed edge is switch-to-switch —
  `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json` gives `s1-eth1 → s5-eth1`,
  `s5-eth2 → s2-eth1`, `s1-eth2 → s6-eth1` — so **none of the four analysed cells is produced by
  the new code.** That is the fact which makes the note's conclusion true, and the note does not
  contain it.
- The 1 Hz tick is confirmed empirically rather than from source: 462 of 524 OVS-20M holds last
  exactly 1 s, and the ≥2 s holds are accounted for by chance repeats (D-1).

Had the analysed edge been host-bound, the note's conclusion would have been exactly backwards —
at 28b8b13 a host-bound edge reads zero, so the reading would not have existed — and nothing in
the note's chosen evidence would have caught it. `busiest_edge()` picks the edge automatically
(A-1) by a margin of **one quantum** in the 200 Mbit/s trace, so which side of that line the
analysis lands on is not currently under anyone's control.

### G-5 — a live clipping hazard, unremarked

`estimatedIn > linkBandwidth ? 0 : …` silently saturates the reading at `linkBandwidth`
(1,000,000,000 bps per the topology JSON). A clipped reading is 10⁹, which is **not** a multiple
of 3,051,520 — so one clipped sample collapses the GCD (B-2) and silently destroys every number
in the note. Max observed reading is 287,612,928 (28.8% of the link), so it did not fire, and the
100%-exact-multiple result — useless as a test of the quantum — is a valid *proof that no clip
occurred*. Worth stating because at high utilisation this analysis returns nonsense with no
error.

### G-6 — the note diffs the wrong pair of commits

The traces were not collected at HEAD. Page 39 dates the OVS curve to `04b8933`; Page 39b dates
the P4 stock run to `b6b75fa`. The note diffs `28b8b13` against **HEAD**. I ran the diff the
claim actually needs — the function is **identical at `04b8933` and `b6b75fa` too**, so the
conclusion is unaffected. But note what the same check turned up: `creditHostBoundEgressEdges`
was **already present at both collection commits** (3 occurrences each), so the new producer was
live while the data was being taken. G-4 is what saves the claim, not G-1.

**And the note never states which commit produced `p4_fast_200M.jsonl.gz` at all.** Three of the
four traces have a documented provenance commit somewhere; the fourth — the one carrying the
"textbook 0.98" cell and the `-O3` confound — has none in the note, in the slide, or in the
filename.

---

## H. Overconfidence sweep (audit item 7), including against the slide it corrects

The note's explicit disclaimers are genuinely good and unusually complete for this project: the
🔴 "no new measurement" box, "if a fresh run is wanted, this note does not supply it", "the
mechanism for OVS/20M overdispersion is unknown, it is not claimed here", "not verified live: no
baseline binary was built". None of those is overstated. Credit where due — and each of them is a
place I looked for an overclaim and did not find one.

The failures are elsewhere, and they cluster in one shape: **claims stated as settled that rest on
a comparison whose magnitude was never checked.**

| # | statement | why it exceeds its evidence |
|---|---|---|
| H-1 | "the **P4 散布一致低於理論地板** open question **is answered**, and it was an artefact of the analysis script" | The mechanism under-predicts by 6–12% of variance (E-2) and one cell falls below the mechanism's hard floor. "Answered" should be "largely accounted for, with a 3–4% residual". |
| H-2 | "The slide's speculative explanations … **are not needed and are not supported**" | The note quotes only **one** of the slide's two candidates. Page 39b also offers 「或連續兩次孿生讀值之間有相關性」 — consecutive-reading correlation. The note does not restate it, does not test it, and declares it unsupported. I tested it: **ρ₁ = −0.150 at 3.7σ on OVS 20M**, and it is the term that makes the note's own arithmetic balance (E-3/E-4). |
| H-3 | "**Three of the four land on theory** once aligned" | No threshold is given. The deviations called "on theory" are +4.8% and +7.1%; the one called an anomaly is +21.6%. Against a proper null, OVS 200M (+2.5σ) is not on theory (C-3). |
| H-4 | "P4 at 200 Mbit/s has Fano 0.98, i.e. **a textbook counting process with nothing added on top**" | Fano 1.00 is not this estimator's null; its null is 1.019 (C-2). It is the single cell produced by the rebuilt `-O3` binary (F-4b) and by an undocumented commit (G-6). Three separate reasons to soften one sentence. |
| H-5 | "**the arithmetic that produces it is inherited verbatim.** Verified by extracting the function from both trees and diffing" | The diffed function performs none of that arithmetic (G-2), and the file that does changed by 1127 lines and gained a second producer (G-3). |
| H-6 | "**Adam's hypothesis is confirmed.** … the dispersion falls by 3.5× … — √9.9 = 3.15" | 3.5 vs 3.15 is an unremarked 11.6% miss whose cause is in the note's own table (F-2). |
| H-7 | ⚠️ "**Two variables move between the rows, not one.** … build and edge" | The edge does not move (A-1). And there is a confound the note omits that **the slide it is correcting already documents**: Page 39b says 「P4 這輪跑 4-host cell、OVS 那輪跑 128-host cell」 — different topology, and 2 hops vs 4. Harmless for the within-plane load claim; live for every P4-vs-OVS sentence in the note, including H-4 and "the residual anomaly is OVS … not P4". **A correction note that drops a caveat the corrected document carried is a regression.** |
| H-8 | "the counting process can be **recovered and tested directly** instead of inferred from the spread" | The recovery is by GCD, and the only stated confirmation (exact multiples) is circular (B-1). Nothing in the note could have failed. |

One further item, not overconfidence but incompleteness: applying the note's own correction
changes a talking point on the slide and the note does not say so. Page 39b's second scripted
sentence is 「合成路徑沒有引入額外誤差——P4 的散布在每個窗長都**等於或小於**取樣理論地板」.
After the alignment correction P4 at 1 s is **78.7% against a 75.1% floor** — no longer ≤. The
note's own framing ("P4 sits on the floor") is the right replacement, but the note flags the
*explanation* as corrected and not the *claim that depended on it*.

---

## I. Verdict table — the note's number beside mine

| # | claim | note | **mine** | verdict |
|---|---|---|---|---|
| 1 | quantum = GCD of non-zero readings = 256×frame×8 | 3,051,520 / 3,059,712 | **identical** | **CONFIRMED as a value.** Sound *here*; the stated confirmation is circular (B-1) and it collapses silently on mixed frame sizes (B-2) |
| 2 | λ per 1 s window | 6.84 / 6.81 / 67.53 / 67.26 | **6.842 / 6.811 / 67.532 / 67.264** | **CONFIRMED** |
| 3 | Fano | 1.43 / 1.08 / 1.14 / 0.98 | **1.428 / 1.075 / 1.140 / 0.982** | **CONFIRMED arithmetically; MISINTERPRETED** — null is 1.053 / 1.019, not 1.00 (C-2) |
| 3b | unbiased Fano (repeats restored) | — | **1.318 / 1.028 / 1.116 / 0.963** | new |
| 4 | sd/mean, and 1/√λ | 45.7/39.7/13.0/12.1, 38.2/38.3/12.2/12.2 | **identical to 0.1 pp** | **CONFIRMED** |
| 5 | 10× load → √10 tighter | 9.9× → 3.5× / 3.3×, "√9.9 = 3.15" | **9.870× / 9.876× → 3.515× / 3.281×**; exact prediction incl. Fano **3.516 / 3.288** | **CONFIRMED**, with an unremarked 11.6% miss the note could have closed (F-2) |
| 6 | Fano 0.98 = "textbook counting process" | 0.98 | **0.982; null 1.019; de-biased 0.963** | **CANNOT VERIFY as stated** — only `-O3` cell, no provenance commit (F-4b, G-6) |
| 7 | sliced-at-4 Hz spreads | 70.9 / 54.6 / 20.7 / 18.2 | **70.9 / 54.6 / 20.7 / 18.2** | **CONFIRMED** |
| 8 | aligned-to-twin spreads | 91.1 / 78.7 / 25.6 / 23.7 | **89.5 / 77.9 / 25.5 / 23.7** | **CONFIRMED**, but algebraically the Fano column, not independent evidence (E-1) |
| 9 | alignment explains the sub-floor spread | qualitative | predicted var factor **0.713 / 0.546 / 0.702 / 0.645** vs observed **0.627 / 0.492 / 0.660 / 0.593** | **DIRECTION CONFIRMED, MAGNITUDE REFUTED as stated.** 6–12% short; P4 20M is below the mechanism's 0.500 floor. Closes to +0.007…−0.036 only after two corrections the note never made (E-3) |
| 10 | "P4 sits on the floor, it does not sit below it" | — | de-biased P4 200M **23.5% vs 23.9% floor** | **WEAKENED** — de-biased it is marginally below again |
| 11 | 2 s-hold hypothesis refuted (6.4 vs 6.9, not double) | 6.4 / 6.9 | **6.38 / 6.91**; stretch predicts **13.7** | **CONFIRMED.** Stronger alternative reading available: chance repeats predict the 10.9% repeat rate (obs 12.3%), the 6.60 dip (obs 6.38) and 7 triple-holds (obs 7) — D-1 |
| 12 | 1 s-holds-only Fano 1.54 "makes it worse" | 1.54 | **1.533**; Poisson null for the same restriction **1.114** | **CONFIRMED but over-read** (D-2) |
| 13 | over-dispersion "absent at 200 Mbit/s on the same plane" | — | OVS 200M Fano **1.140 vs null 1.019, +2.5σ** | **REFUTED** (C-3) |
| 14 | slide's `random()`/systematic speculation "not needed and not supported" | — | P4 20M ρ₁ **+0.014** (z = +0.3); OVS 20M ρ₁ **−0.150** (z = −3.7) | **"not supported" CONFIRMED for P4; "not needed" REFUTED** — and the slide's *second* candidate was never restated or tested (E-4, H-2) |
| 15 | `updateLinkInfoLeftLinkBandwidth` byte-identical 28b8b13↔HEAD | 37 lines | **45 lines, `diff` clean**; also identical at `04b8933` and `b6b75fa` | **CONFIRMED** |
| 16 | "the quantisation is inherited" | — | ingress accumulate + report/reset byte-identical; **all four analysed edges switch-to-switch, so none uses the new producer** | **CONFIRMED, by different evidence** — the note's evidence does not support it (G-2/G-3/G-4) |
| 17 | P4 200 Mbit/s edge = s5-eth2 | s5-eth2 | **s1-eth1** (both P4 runs) | **REFUTED** (A-1) |
| 18 | "four rounds, four values 1490/1490/1494/1506" | — | this note's four traces: **1494/1490/1494/1490** | **MISLEADING AS PLACED**; three distinct values, not four (A-2) |

---

## J. What a thesis committee will attack that the note does not pre-empt

1. **"What is the null distribution of your Fano estimator?"** The note asserts "A Poisson process
   gives exactly 1.00". For *this* estimator it gives 1.053 at λ≈7. Every Fano judgement in the
   note is made against the wrong reference. **Most damaging question available, and the note has
   no answer.** (C-2)
2. **"Show me the predicted variance-reduction factor."** The alignment argument is the note's
   load-bearing correction and is given in words only. The number is 0.713 (or 0.546), it can
   never fall below 0.500, and one of the note's own cells sits at 0.492. (E-2)
3. **"n = 1 per cell and no error bars anywhere."** Four single runs, no repetition, not one
   confidence interval in the document. The sampling sd of Fano at n = 600 is ±0.059, so the
   1.08-vs-0.98 pair the note leans on is **not separable**. The 1.43-vs-1.08 gap *is* — but the
   note never says which of its differences it claims are real.
4. **"You chose the window alignment after seeing that the first one gave an uncomfortable
   answer."** The "aligned" estimator exists to move P4 off a sub-floor result. Legitimate fix
   *and* a textbook researcher-degrees-of-freedom target. No criterion for "lands on theory"
   (H-3), applied to all four cells only after the fact. **The defence exists — the 4 Hz-vs-1 Hz
   mismatch justifies alignment a priori, independent of the result — and the note never makes
   it.**
5. **"Which commit produced the 200 Mbit/s P4 trace?"** Unanswered anywhere. Also the only `-O3`
   cell and the source of the "textbook 0.98" claim. (G-6)
6. **"Different topology, 2 hops versus 4."** Page 39b documents it; the note drops it while
   claiming to correct Page 39b. Every P4-vs-OVS sentence in the note is exposed. (H-7)
7. **"Your edge is chosen by an argmax with a 0.0004% margin."** Re-collect the trace and
   `busiest_edge` may return the other edge. Nothing pins it, and the note records the wrong one.
   (A-1)
8. **"What result would have falsified 'reading ÷ quantum = sample count'?"** Nothing offered;
   exact-multiplicity is a theorem about GCDs. The genuine evidence — 1490 B recovered
   independently from a packets/bytes division on 2026-08-15, plus small contiguous integers — is
   not cited. (B-1)
9. **"You call 4 Hz 'deliberate oversampling' to avoid aliasing."** The measured phase is
   *locked*, not sliding: w = 0.5 in 544/599 windows (P4 20M), w = 0.75 in 852/899 (P4 200M).
   Oversampling a 1 Hz signal at exactly 4× with a fixed phase does not average the artefact away,
   it makes it deterministic. The stated rationale is the opposite of what the data shows. (E-5)
10. **"Is your headline a measurement or a division?"** λ ∝ rate is definitional, 1/√λ is Poisson.
    The only empirical content is Fano ≈ 1 — the quantity attacked by point 1. (F-3)

---

## K. Two things that are right, and the checks that could have broken them

Not a courtesy paragraph — these are checks that could have overturned the note and did not:

- **The 2 s-hold refutation is correct and its numbers are exact** (6.38 / 6.91 against a stretch
  prediction of 13.7). Attacked three ways: recomputed both means; computed the analytic
  repeat-coincidence null; checked the ≥3 s hold count against 600·p². All three agree, and the
  third — 7 predicted, 7 observed — is a prediction the note never made that would have exposed a
  stretched refresh immediately had one existed. (D)
- **"The quantisation is inherited" is true.** I did not take the byte-identical function on
  trust: I traced the actual producer, found the file changed by 1127 lines and grown a *second*
  accumulate-report-reset path in our own code, then established from
  `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json` that every analysed edge is
  switch-to-switch and therefore fed by the byte-identical inherited line. Had `busiest_edge`
  landed on a host-bound edge the conclusion would have inverted. It did not. (G-4)

---

*Audit complete. No product code, no trace file and no figure was modified by this audit.*
