# Ladder running notes — leg 1 (bl / p), written while the round is still running

🔴 **This file is NOT part of PREREG.** It registers no threshold, amends no rule, and has no
standing in the Q1/Q2/Q3 verdict. Its only job is to **pin an expectation to a timestamp before
the data that would test it exists**, so that nothing here can be retrofitted after the fact.

Status when written: **00:50, 2026-09-01. 12 of 48 cells done — rungs 1/1024 and 1/256 only.**
Rungs 1/64, 1/32, 1/16, 1/8, 1/4 and 1/1 had not been observed.

---

## 1. The observation

| rung | cells | mean `spread` | mean `ratio` | `floor` | `distinct` | all `mark` |
|---|---|---|---|---|---|---|
| 1/1024 | 6 | **23.935** | 1.0006 | 0.00696 | 240–241 | OK |
| 1/256 | 6 | **11.970** | 1.0036 | 0.00695 | 240–241 | OK |

`23.935 / 11.970 = ` **2.000**. A 4× sampling rate against a √n expectation predicts exactly 2.

## 2. 🔴 What this is, and what it may not be used for

`spread` is **not a registered outcome of this round.** PREREG mentions no equivalent term
(散布 / 離散 / 標準差 / 誤差 / 抖動 / spread all return zero; the two hits for 變異 are §0-ter's
*baseline* variance, an instrument property, not an outcome). The registered primary is the
**ceiling rung**, and R-E1/R-E2/R-E3 are stated entirely in rung language.

⇒ **This observation inherits the ruling the auditor already made for kernel-side CPU in Q2/E4:**
a secondary observation is *reported separately* and **may not be used to explain or reinforce the
primary verdict.** If the ceiling moves, the reason must be stated in rung language. This number may
not be recruited to make that story sound better.

## 3. 🔴 Why 2.000 is worth less than it looks

Two points define a line. A ratio landing on the predicted value to three significant figures is
the exact shape this project has been burned by before — an arithmetic fit taken for a mechanism,
and a direction-match mistaken for a result. Concretely, **√n was not at risk here**: the two rungs
are the two *highest* sampling rates on the ladder, where sample counts are largest and any
sampling-noise model behaves. Nothing about these two points could have come out otherwise.

**The check that would discriminate:** √n scaling has to fail somewhere, or there is no ceiling to
find. Where it departs — and whether the departure coincides with the rung at which `mark` stops
being OK — is the only part of this that carries information.

## 4. Expectation, pinned now (00:50, before rungs 3–8 exist)

* If `spread` keeps halving per 4× rate all the way to 1/1, **the sampling-noise model is not the
  binding constraint anywhere on this ladder**, and any ceiling seen must be explained by something
  else. That would be a *negative* result for the mechanism, not a confirmation.
* If it stops halving at some rung, I expect the departure to be **at or below** the rung where
  `mark` first stops being OK, not above it.
* `floor` (0.00695–0.00697) and `distinct` (240–241) have been constant across both rungs and both
  arms. **I expect them to stay constant.** If `floor` moves with sampling rate it is an instrument
  property leaking into the measurement and that is a defect, not a finding.
* No prediction is offered about the ceiling rung itself. That is the registered question and it is
  not mine to anticipate here.

## 5. Two things being watched that DO bear on registered rules

* **E-P4 (frozen):** merge must not change `ratio`. If `ratio` drops on the `m`/`mp` arms in leg 2,
  that is a **batching implementation bug — most likely `_pending` not flushed at close — and the
  round stops and reports the bug.** It must not be read as a ceiling change. Leg 1's arms
  (`bl`, `p`) have no batching, so leg 1 cannot exercise this; `ratio` sitting at 1.00 here is the
  *reference*, not a pass.
* **Baseline drift, for the 04:20 report.** Cell CPU-gate margins have widened as the night went on:
  rung 1/1024 spanned −0.267 … −0.533, rung 1/256 spanned −0.541 … −0.578. This is the operator-
  behaviour baseline of §0-ter moving, and per the auditor it is **a finding, to be reported as
  drift — not noise to be averaged away.** Per-cell baselines must not be averaged.

## 6. Standing constraint

🔴 **C5: no rung, rep or arm is added from here on.** If the ladder proves too short, that is a
finding to register for the NEXT round, not an edit to this one.

[Co-developed with claude code -- Adam]
