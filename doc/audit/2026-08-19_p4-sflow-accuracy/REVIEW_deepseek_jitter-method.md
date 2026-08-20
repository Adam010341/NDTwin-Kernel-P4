# Review of `METHOD_jitter-and-load.md` — method interrogation

Reviewer: this session. What I could and could not do:

- I read the METHOD note, `run.py`, `analyse_q.py`, `plot_figures.py` (including the **uncommitted**
  `sample_stats()` / `fig_quantum_load()` additions), `FlowLinkUsageCollector.cpp`,
  `TopologyAndFlowMonitor.cpp`, `sflow_emitter.py`, `ndtwin_switch.p4`, and the 2026-08-18 round docs.
- I recomputed the OVS halves of both result tables **from the raw traces** with jq
  (`scratch/sflow/runB_20M.jsonl`, `runA_200M.jsonl` — the un-gzipped sources archived as
  `sflow_runB_20M.jsonl.gz` / `sflow_runA_200M.jsonl.gz` 90 s later per `stat`; row counts, spans and
  values match the archived report exactly. I cannot byte-compare raw vs gz with the allowed tools —
  treating them as the same runs is an INFERENCE, though a well-supported one).
- The two P4 traces exist only as `.gz`, which I cannot decompress with the allowed toolset.
  **Everything about the P4 rows is therefore CANNOT VERIFY from my side**, except where it follows
  from the METHOD's own published numbers or from committed code.
- Mid-session, `AUDIT_jitter-method.md` (a 63-byte stub when I started) grew to a 639-line complete
  audit by "a separate Claude session". I use it as a *second source* with attribution; its own
  scratchpad scripts are not in the repo, so its P4 numbers are also unverifiable from here. Where its
  OVS numbers overlap mine, they match to 3 s.f.
- `pgrep simple_switch_grpc` = no processes now — consistent with, but not proof of, the note's
  "fabric was not up".

Terminology: OBSERVED = I saw it in a file / computed it from raw data / confirmed with git.
INFERRED = deduced from source or other evidence. CANNOT VERIFY = would need gz access or a run.

---

# PART A — Findings by claim

## A.1 Claim: "Dispersion is Poisson, not a defect" (Fano 1.43 / 1.08 / 1.14 / 0.98)

**Verdict: OVS rows CONFIRMED as arithmetic; the Poisson interpretation is UNSUPPORTED as stated.**

OBSERVED (my jq recomputation, sample_stats replication):
- OVS 20M: λ = 6.842, Fano = 1.428 → matches note's 6.84 / 1.43 exactly. 526 counts from 2,399 polls /
  599.8 s.
- OVS 200M: λ = 67.532, Fano = 1.140 → matches 67.53 / 1.14. 871 counts / 899.9 s.
- P4 rows: CANNOT VERIFY (gz). A concurrent audit reproduces 6.811/1.075 and 67.264/0.982.

The problems are in the interpretation, two of which I verified independently:

1. **The estimator's null is not 1.00.** `sample_stats` emits a count only when `v != prev`, so two
   consecutive windows with equal counts are merged into one record. The merged values are
   preferentially near the mode (the mode is where repeats happen), so de-duplication deletes central
   values and inflates variance/Fano. A concurrent audit's simulation gives the estimator a null of
   ~1.05 at λ=6.84 (n=600) and ~1.02 at λ=67 (n=900). I independently confirmed the direction with a
   repair: expanding repeat-holds back to one count per refresh gives **OVS 20M Fano 1.328** instead
   of 1.428, and **OVS 200M Fano 1.116** instead of 1.140 (my expansion thresholds differ slightly
   from the audit's 1.318; both agree the published values are inflated by ~0.10 at 20M).
2. **De-biased P4-200M ≈ 0.96** (audit; consistent with the same bias direction). The sentence
   "P4 sits on the floor, it does not sit below it" rests on an estimator biased upward ~5% in
   variance. De-biased, P4-200M is again *marginally below* the floor — the very open question the
   note claims to close.
3. OBSERVED from the raw OVS-20M trace: one genuine zero-sample second exists at row 1145
   (t≈1787062999), contradicting the 08-18 report's "the twin never read zero"; minor, but the note's
   lineage claim of "re-analysis of already-committed data" inherits that discrepancy unnoticed.

Also OBSERVED: Fano 1.14 for OVS-200M is ~2.5σ above the estimator's ~1.02 null (sd of Fano ≈
√(2/871) ≈ 0.048) — see A.4.

## A.2 Claim: "10× load gives √10 tighter spread — Adam's hypothesis confirmed"

**Verdict: arithmetic CONFIRMED; the presentation hides an 11% miss whose cause is in the note's own table.**

OBSERVED: λ ratio = 67.532/6.842 = **9.870×** (OVS), audit gives 9.876× (P4). sd/mean ratios
45.7%/13.0% (OVS) and 39.7%/12.1% (P4) → falls of **3.515×** and **3.281×**. The note prints
"3.5× … √9.9 = 3.15" as agreement. 3.515/3.15 = **+11.6%** and the gap is exactly
√(Fano₂₀/Fano₂₀₀) = √(1.428/1.140) = 1.119 — i.e. the same OVS overdispersion the note two sections
later calls unexplained. It is not noise and not acknowledged. Also: λ ∝ rate is definitional and
1/√λ is Poisson, so the only empirical content in the headline is "Fano ≈ 1 at both loads" — the
quantity the biased estimator (A.1) attacks.

Confound check: the OVS pair (s1-eth2 both times, same kernel, same protocol) is clean and carries
the load claim on its own. The P4 pair is confounded (build, and — per the concurrent audit — not
actually the edge the note names; see A.6) plus a topology change the note drops (A.8). The note's
blanket ⚠️ applies the caveat everywhere and nowhere; it does not say which sentences each confound
can touch.

## A.3 Claim: below-floor P4 spread is a 4 Hz/1 Hz misalignment artefact; re-aligning restores theory

**Verdict: direction CONFIRMED and quantitatively reproduced for OVS; magnitude NOT demonstrated, and one of the note's own cells violates the mechanism's hard floor.**

OBSERVED (my recomputation, OVS):
- Sliced-at-4 Hz T=1 spreads: 70.87% (20M) and 20.69% (200M) — reproduce the note's 70.9 / 20.7 to
  0.1 pp, and the note's "aligned" 91.1 / 25.6 reproduce as 90.97 / 25.58 (ratio estimator).
- The note's "aligned" column is (to ~1.5 pp) the Fano column re-expressed: 1.96√(Fano/λ) gives
  89.5 / 78.0 / 25.5 / 23.7. It is not independent evidence; "three of the four land on theory" is
  algebraically "three of the four have Fano ≈ 1", with the biased Fano (A.1).
- **Phase weights measured, OVS-20M:** w = 0.25/0.5/0.75/1.0 with counts 148/148/113/190 over 599
  slice windows. The blend mechanism predicts E[w²+(1−w)²] = **0.713** (identical to the concurrent
  audit's number). Observed (sliced/aligned)² = (70.87/89.53)² = **0.627** — the blending accounts
  for the direction but **under-predicts the variance reduction by ~12%**.
- **Hard-floor violation from the note's own published numbers:** P4-20M (54.6/78.7)² = **0.481**.
  A blend of two independent readings has variance factor w²+(1−w)² ≥ **0.500 for any phase**. The
  note's own P4-20M numbers are below the floor of the mechanism it invokes. Either the two columns
  were computed on different edges (A.6), or independence fails (negative lag-1 correlation — the
  concurrent audit measures ρ₁ = −0.150, 3.7σ, on OVS-20M, and adding 2w(1−w)ρ₁ closes its gap to
  +0.007), or the mechanism is wrong.
- The slide's second speculative candidate — correlation between consecutive twin readings — was
  never restated by the note, never tested, and was declared "not needed and not supported". The
  independence test is exactly the test that separates this claim from a mechanism guess.

So: the note's central correction is *directionally right and partly right in size*, but it declares
the question "answered" without ever computing the predicted magnitude — the documented failure mode
the reviewer brief warned about.

## A.4 Claim: "the remaining anomaly is OVS at 20 Mbit/s (Fano 1.43); absent at 200 Mbit/s on the same plane"

**Verdict: "absent at 200 Mbit/s" is REFUTED by the note's own table.**

OBSERVED: OVS-200M Fano = 1.140 (n=871) against the estimator's ~1.02 null is ~+2.5σ; aligned spread
25.6% vs theory 23.9% (+7%). OVS sits above the floor at *both* loads; P4 sits at/below it at both.
The defensible reading is a per-plane signal with load-dependent amplitude, not "a 20 Mbit/s
curiosity". The note compared 1.14 to 1.00 instead of to its estimator's null.

The OVS-20M anomaly itself is real even after de-biasing (1.33 vs Poisson 1.00, ≈5σ) — the note's
"mechanism unknown, not claimed" is honest, but its magnitude is overstated by ~0.10.

## A.5 Claim: quantisation is inherited from baseline (byte-identical function)

**Verdict: conclusion CONFIRMED; the cited evidence is insufficient for it.**

OBSERVED with git:
- `git log -L :updateLinkInfoLeftLinkBandwidth:…TopologyAndFlowMonitor.cpp` shows the function was
  introduced by d6f7c01 (2025-12-15) and never modified since → byte-identical at 28b8b13 and every
  later commit. Blame of HEAD 1067–1104 is uniformly `^d6f7c01`.
- `git blame 28b8b13 -L 1360,1370 -- …FlowLinkUsageCollector.cpp` shows L1365-66 are exactly the
  `* 8` report and `= 0` reset the note quotes. The accumulate line (`+= frameLength*samplingRate`)
  blames to dfaa8cc8/2f0251f2 (Dec 2025); `git rev-list --count 2f0251f2..28b8b13` = 30 → ancestor.
- 28b8b13 is an ancestor of HEAD (`git rev-list --count 28b8b13..HEAD` = 379).

But: **the byte-identical function contains none of the quantising arithmetic.** It is a
subtract-and-clamp pass-through (`linkBandwidthUsage = linkBandwidth − (linkBandwidth − estimatedIn)`).
The quantum is produced in `FlowLinkUsageCollector.cpp`, which changed by **1127 lines** since the
fork and grew a *second* accumulate-report-reset producer (`creditHostBoundEgressEdges()`, Adam's
commit e86cb4d7). The note never establishes that the analysed readings come from the inherited
producer rather than the new one. The concurrent audit supplies the missing fact: all four analysed
edges are switch-to-switch, and the new producer pays out host-bound edges only — so the conclusion
happens to be true, but the note's chosen evidence would not have caught it being false. Also: the
note diffs 28b8b13↔HEAD while the traces were collected at 04b8933 (OVS) / b6b75fa (P4 stock); the
function is identical there too (the `log -L` proves it for every commit), but the diff target is
not the collection commit, and **no commit is documented at all for p4_fast_200M.jsonl.gz** — the
trace carrying the "textbook 0.98" cell and the −O3 confound.

## A.6 Factual errors in the note's own trace table

- **Quantum list wrong for its own table.** OBSERVED: both OVS traces measure GCD 3,059,712 =
  256×1494×8. The note's "(four rounds, four values: 1490/1490/1494/1506 B)" as placed maps 1490 to
  OVS-20M; the correct values for this note's four traces are 1494/1490/1494/1490 (P4 values per the
  concurrent audit; CANNOT VERIFY myself). 1506 occurs in none of them — it is history from a
  previous round, copied without checking.
- **Edge claim vs committed code.** OBSERVED in `plot_figures.py:631-635`: the figure selects the P4
  edge via `busiest_edge(p4s)` / `busiest_edge(p4F)`, not a literal. The note's table asserts
  s1-eth1 and s5-eth2. The concurrent audit measures `busiest_edge` → **s1-eth1 for both P4 runs**,
  with the 200M argmax decided by **one quantum out of 7.4e11 (0.0004%)**. CANNOT VERIFY myself.
  If true, the note's self-declared "different edge" confound does not exist — and a coin-flip-scale
  argmax decides which edge the analysis lands on.
- **Topology confound dropped.** OBSERVED: the OVS runs used the 128-host NTG topology
  (h1→h65, path s1→s6→s9→s7, per the 08-18 report); the P4 runs used the 10-switch/4-host fabric
  (per the 08-18/08-19 P4 notes). Page 39b already carried this caveat; the note claims to correct
  Page 39b and drops it. Live for every P4-vs-OVS sentence.

## A.7 Reproducibility and state of the artefact

OBSERVED: `METHOD_jitter-and-load.md`, `AUDIT_jitter-method.md`, and the `sample_stats()` /
`fig_quantum_load()` additions are all **uncommitted** working-tree changes (`git status`). The
figure the note points to, `figures/page39_quantisation-ladder-load.png`, **exists nowhere in the
repo** (`find` for `page39*` and `*quantisation*` is empty). The code behind the "aligned to twin
updates" column and the "restricted to windows that held exactly 1 s" analysis is committed nowhere —
only the 4 Hz sliced analysis (`analyse_q.py`) and the Fano/λ (`sample_stats`) have code. A committee
cannot re-run the two tables the note leans on hardest from the repository alone.

Also OBSERVED in `sample_stats`: the first poll's value is always emitted (`prev = None`), so a
zero/partial first reading enters the count list as a "window"; and there is no hold-duration gating —
the note's claim "one count per twin update" is violated ~1 time in 9 at 20M by equal-count merges.

## A.8 GCD-based quantum recovery (method soundness)

The GCD estimator is sound *on these four single-flow traces* but has an unfalsifiable-looking
confirmation: `reading % quantum == 0` for 100% of readings is a theorem about GCDs, not evidence.
The real evidence the note never cites: the recovered integers are small and contiguous
(1–19 at 20M, 40–94 at 200M — OBSERVED for OVS, audit for P4) and q/2048 lands on legal frame
lengths. Failure mode under mixed frame sizes (e.g. ARP or a second MTU on the edge):
gcd(256·1490·8, 256·1494·8) = 4096, silently scaling λ by ~745 — and the exact-multiple check still
passes. Also: a saturated reading (clamped to linkBandwidth = 1e9, per
`updateLinkInfoLeftLinkBandwidth`) is not a multiple of the quantum and would collapse the GCD; the
max observed reading is 287.6 Mbps so it did not fire here, but nothing guards it.

---

# PART B — Questions for the Claude session (ranked by damage a bad answer would do)

1. **You assert "a Poisson process gives exactly 1.00" as the reference for your Fano values. Your
   `sample_stats` deduplicates equal consecutive readings, which preferentially deletes counts near
   the mode; my repair (one count per refresh) turns your OVS-20M 1.43 into ≈1.33, and a concurrent
   audit's simulation puts your estimator's Poisson null near 1.05 at λ≈7. What is the null
   distribution of *your estimator*, which of the four Fano judgements survive re-referencing
   against it, and does "P4 sits on the floor, not below it" survive the de-biased P4-200M value of
   ≈0.96?**

2. **You assert the below-floor spread "was an artefact of the analysis script" and declare the
   question answered on the direction of the correction. Your own published P4-20M numbers give
   (54.6/78.7)² = 0.481 — below 0.500, the hard floor of blending two independent draws at any
   phase; and I measured OVS-20M's actual phase weights (0.25/0.5/0.75/1.0 → predicted factor 0.713
   vs observed 0.627). What is the predicted variance-reduction factor per run, what explains the
   6–12% residual in all four cells, and what rules out the slide's second candidate
   (correlation between consecutive twin readings) that you dismissed without testing?**

3. **You assert OVS overdispersion is "absent at 200 Mbit/s on the same plane". Your own aligned
   table has OVS-200M at 25.6% vs theory 23.9% and Fano 1.14, which is +2.5σ against your
   estimator's null. What statistical test establishes "absent", and if the correct reading is a
   per-plane signal (OVS above the floor at both loads, P4 at/below), what happens to the framing
   "the remaining anomaly is OVS at 20 Mbit/s"?**

4. **You print "3.5× (OVS) … √9.9 = 3.15" as confirmation. The gap is +11.6% and equals
   √(Fano₂₀/Fano₂₀₀) = 1.119 — the same OVS overdispersion you call unexplained two sections later.
   Given λ ∝ rate is arithmetic and 1/√λ is Poisson, what empirical content does "Adam's hypothesis
   is confirmed" carry beyond Fano ≈ 1, and why is the 11% miss not reported as the anomaly leaking
   into the headline?**

5. **Your "textbook counting process" sentence rests on the single cell produced by the rebuilt −O3
   binary, the only one with no documented provenance commit, analysed on an edge chosen by
   `busiest_edge()` — an argmax a concurrent audit finds decided by one quantum out of 7.4e11. You
   disclose build+edge as a blanket caveat, then draw per-plane conclusions from that cell. Which
   sentences does the caveat apply to, which commit produced `p4_fast_200M.jsonl.gz`, and is the
   analysed edge s5-eth2 (your table) or `busiest_edge()`'s output (the committed code)?**

6. **Your trace table names s1-eth1 (P4-20M) and s5-eth2 (P4-200M) while `fig_quantum_load` uses
   `busiest_edge()` for both. A concurrent audit measures s1-eth1 for both. If table and code
   disagree, what edge was the sliced/aligned pair for P4-20M actually computed on, and is the
   54.6-vs-78.7 comparison even same-edge?**

7. **You state "four rounds, four values: 1490/1490/1494/1506 B" directly under your four-row trace
   table, under a bullet claiming the quantum is measured per run. I measure both OVS traces at
   1494 B. What do your four traces actually measure, and why does 1506 — which occurs in none of
   them — appear in the Method section of a note whose reader will check?**

8. **The OVS runs were on the 128-host topology (4 hops) and the P4 runs on the 4-host fabric
   (2 hops) — a caveat Page 39b carried and your correction note drops. Which of your P4-vs-OVS
   sentences ("residual anomaly is OVS, not P4"; "textbook counting process on P4") are robust to
   hop count and topology size, and why did the note drop a caveat the document it corrects kept?**

9. **`reading/quantum = sample count` smuggles in single-frame-length traffic and no clipped
   readings. GCD collapses to 2048·gcd(len1,len2) under mixed frame sizes, and your exact-multiple
   confirmation would still pass 100% of the time because it is implied by the GCD construction.
   What check did you run that could have failed, and did you verify small contiguous integer
   counts and a legal frame length for all four runs?**

10. **You refute the stretched-window hypothesis from holds with mean 6.4 vs 6.9 — but chance
    repeats predict ~65 merged pairs at λ=6.84 and I count 62 holds ≥2 s in your own trace. That
    means each 2 s hold is two real 1 Hz updates recorded once by `sample_stats` (~1 update in 9
    lost at 20M). Do you agree your estimator loses ~12% of updates, and how does that bias the
    Fano values your "Poisson" verdict rests on?**

11. **The METHOD file, `sample_stats`, and `fig_quantum_load` are uncommitted; the referenced
    figure `figures/page39_quantisation-ladder-load.png` is not in the repo; and the code behind the
    "aligned to twin updates" column and the "restricted to exactly 1 s" analysis is committed
    nowhere. What is the commit of record for this note, and how does a committee re-run your two
    result tables from the repository alone?**

12. **"Three of the four land on theory once aligned": the two cells you call on-theory are +4.8%
    (P4-20M 78.7 vs 75.1) and +7.1% (OVS-200M 25.6 vs 23.9) above the line. What threshold defines
    "on theory", was it set before or after seeing the realignment, and does it survive the
    estimator-bias correction from question 1?**

13. **You justify 4 Hz polling as deliberate oversampling against aliasing. The measured slice
    phases are a fixed discrete mixture — OVS-20M w = 0.25/0.5/0.75/1.0 at 148/148/113/190 windows;
    the concurrent audit finds P4 locked at w = 0.5 and 0.75 for hundreds of windows. A phase-locked
    4× oversample makes the blending artefact deterministic, not averaged away, and it applies
    differently to the two planes. How does the oversampling rationale survive, and why is the
    phase-locking itself not reported as a methodological asymmetry between the planes you compare?**

14. **You verify byte-identity of `updateLinkInfoLeftLinkBandwidth` and present it as "the
    arithmetic that produces it is inherited verbatim". That function contains none of the
    quantising arithmetic (it is a subtract-and-clamp pass-through); the file that accumulates and
    resets changed by 1127 lines and gained a second producer, `creditHostBoundEgressEdges()`, in
    Adam's fork. What establishes that the analysed readings come from the inherited
    accumulate-report-reset path and not the new producer, and why is the diff taken against HEAD
    when the traces were collected at 04b8933 / b6b75fa?**

15. **Your λ = 6.84 × 3.059712 Mbps = 20.93 Mbps against a 20.58 Mbps ground truth — a +1.7% mean
    over-read — while the archived 08-18 report claims the twin is unbiased within 1%. Where does
    the count-mean's excess come from, and does it affect the claim that the re-analysis changes no
    measurement conclusions?**

---

## Appendix: what I verified vs what I took from the concurrent audit

Mine (jq from raw OVS traces): λ/Fano both OVS rows; GCD/quantum both OVS runs (1494 B); sliced
spreads 70.87/20.69; aligned spreads 90.97/25.58 (ratio) and 89.29 (count-based); 1 s-vs-2 s hold
means 6.90/6.44; Fano restricted to <1.5 s holds = 1.532; phase-weight histogram for OVS-20M;
unbiased-Fano repair 1.328; zero-count window at row 1145.
Mine (git): byte-identity of `updateLinkInfoLeftLinkBandwidth` across all history; baseline L1365-66
citation exact; accumulate line predates the fork; 28b8b13 ancestor of HEAD; uncommitted state of the
note and its code; figure absent.
Concurrent audit only (attributed, unverified by me): all P4 numbers (busiest_edge sums, P4 λ/Fano,
P4 quanta 1490, P4 phase locking, ρ₁ measurements, estimator nulls by simulation, unbiased Fano
table, per-run predicted factors).

---

## Addendum — corrected attribution (post-write check)

In A.1 I wrote the repaired Fano for OVS-200M as if already computed. I have now computed it the
same way as the 20M repair (expand repeat-holds back to one count per refresh):

- OVS-20M: n=590, Fano **1.3277** (published 1.428)
- OVS-200M: n=896, Fano **1.1164** (published 1.140)

Both are my own jq computations from the raw traces, and both agree with the concurrent audit's
independent values (1.318 / 1.116) within its threshold conventions. The statement "de-duplication
inflates the published Fano values by ~0.10 at 20M and ~0.024 at 200M" is now OBSERVED by me on both
OVS cells. The P4 de-biased values (~1.028 / ~0.963) remain audit-reported, CANNOT VERIFY by me (gz).
