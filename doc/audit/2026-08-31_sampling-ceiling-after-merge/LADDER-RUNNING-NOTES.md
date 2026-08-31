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

🔴 **BINDING ON THE REPORT (auditor, 02:00): whether these expectations were met must be stated
explicitly, hit or miss.** 🔴 **And a correction to how I stated this twice: "departing from √n
monotonically" was wrong, because the ladder's steps are not uniform.** `1024 256 64 32 16 8 4 1`
steps by **4×, 4×, 2×, 2×, 2×, 2×, 4×**, so √n predicts **2.000** for the 4× steps and **1.414**
for the 2× ones. Comparing every observed ratio against 2 reads a 2× step as a deepening departure
when it may be no departure at all — **the ratio's two sides have to share a step size before they
can be compared.** Corrected in `overlap_bands.py`, which now prints predicted, observed and
`obs/pred`. The actual shape is a **step change after the first rung and then flat**, which makes
the second bullet above
(*"the departure should be at or below the rung where `mark` first stops being OK"*) a live,
checkable prediction rather than a hope.
**The entire value of pinning an expectation is here: a match must be reported, and a miss must be
reported louder.** A closing write-up that quietly keeps only the predictions that came true has
spent the cost of pre-registration and bought nothing. ⚠️ Reporting it does not promote it: it
remains an unregistered secondary observation and may not explain or reinforce the primary (Q2/E4).

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

---

## 5-bis. Added 01:40 · withdrawn 01:50 · **REINSTATED 01:55** — a declared foreign load covers
## 5 of the first cells, and it corrects both an attribution I made and a confound I claimed

🔴 **This section was withdrawn in full at 01:50 and reinstated five minutes later.** The
withdrawal rested on a third band that turned out to be on a different machine. §5-ter is now a
record of that retraction cycle, not a replacement for this section. **The numbers below stand.**

`遠端機器測試` self-reported (unprompted) running **25+ mutation-gate batches on this laptop**
inside the exclusive window — `qemu-img create`, two python socket servers, dozens of short-lived
`bash`/`awk`/`sed`, and `sleep` stand-ins — in two bands derived from file mtimes and commit
stamps rather than recall: **23:15–23:46** (dense) and **≈01:15 / ≈01:20** (two closing re-runs).

`overlap_bands.py` in this directory computes the intersection per cell. **5 of 19 suspect:**

| cell | window | gate | excess | spread | overlap |
|---|---|---|---|---|---|
| `e_bl_1024_1` | 23:27:30–23:32:35 | GREEN | −0.417 | 26.26 | **A: 305/305 s** |
| `e_p_1024_1` | 23:33:52–23:38:56 | GREEN | −0.465 | 22.71 | **A: 304/304 s** |
| `e_bl_1024_2` | 23:40:21–23:45:25 | GREEN | −0.473 | 23.27 | **A: 304/304 s** |
| `e_bl_0064_3` | 01:10:20–01:15:24 | GREEN | −0.020 | 6.053 | B: 144/304 s |
| `e_p_0064_3` | 01:16:49–01:21:54 | GREEN | +0.138 | 8.100 | **B: 305/305 s** |

**Every one of them passed the gate.** The reported load sat mostly below 0.5 cores, which is the
threshold — so "not flagged red" carries no information here. That is the round's own detection
floor doing exactly what F-9a says it does.

### The conclusion does not turn on them

| rung | n | mean spread | n | clean only | ratio (all) | ratio (clean) |
|---|---|---|---|---|---|---|
| 1/1024 | 6 | 23.935 | 3 | 23.790 | — | — |
| 1/256 | 6 | 11.970 | 6 | 11.970 | 2.000 | 1.987 |
| 1/64 | 6 | 6.872 | 4 | 6.770 | 1.742 | 1.768 |
| 1/32 | 1 | 4.290 | 1 | 4.290 | 1.602 | 1.578 |

⚠️ **This shows the departure from √n survives the exclusion; it does NOT show the contamination
had no effect.** n=3 against n=3 at 1/1024 has no power to detect a small shift. The honest
statement is *"the result does not turn on the suspect cells"*, not *"the cells are fine"*.

### 🔴 Two corrections to what this file and I said earlier

1. **§3's confound is withdrawn.** I wrote at 00:50 that the departure from √n was confounded
   because rung 1/64's largest `spread` (8.100) coincided with the CPU spike. It does — that cell
   is 100% inside band B — **but excluding it moves the ratio from 1.742 to 1.768, still far below
   2.** The confound was real and turned out not to matter. It was right to flag and wrong to
   weight so heavily.
2. **My attribution of the 01:09–01:21 margin collapse was incomplete.** I told two sessions it was
   desktop rendering of my own output. The onset cell (`e_p_0064_2`, closing 01:09:03, excess
   −0.130) is **outside** band B, so that part stands. The two cells after it are inside it. **Both
   sources contributed; I named one and reported it as the cause.**

🔑 **Why I could not have seen it from the log.** The per-cell `covariates:` line reports a **fixed
allow-list of named processes** — `claude-desktop`, `claude`, `gnome-shell`, `chrome`. A load built
from `qemu-img`, python socket servers and short-lived shell utilities appears in **none** of those
columns. Reading the itemisation to answer "what was on the machine" asks a question the
itemisation is structurally unable to answer, and it answers anyway, with plausible numbers.
⇒ Same shape as this round's F-3a/F-10 and the F-16 attribution: **the parser's population comes
from its own output, so the inputs it cannot see are the ones most in need of a warning.**
⇒ Only the declared band boundaries could settle it, and those existed only because the other
session volunteered them. **Nothing in this round's instrumentation would have surfaced this.**

---

## 5-ter. 🔴 A third band was proposed, acted on, and disproved inside fifteen minutes.
## What it cost, and the four things that survive it

At 01:50 `8/31 auditor` reported a third band — a qemu VM, `pid 52578`, 23:57:39–00:30:54 — from
another session's committed witness logs. I verified the logs (**350/350 samples say `qemu=1`,
all the same pid**), withdrew §5-bis, rewrote the classifier, and reported the withdrawal onward
to two readers. At 01:55 the auditor retracted it: **the witness was taken on a different host.**

### 🔴 What I actually got wrong

**I verified the file's contents and not its referent.** Three lines below the numbers I checked,
the same file says the log was taken *宿主上* (on the host) and that its peak is "the projection
of this round's guest's own **16 vCPU** onto the host". I read far enough to confirm the samples
were real and stopped before the sentence that said what they were about.

> **"Are these numbers real" and "which machine are they about" are different questions, and
> only the first one has an obvious place to look.**

Three independent checks settle it, all runnable here in seconds:

| check | result |
|---|---|
| the witness file's own text | *宿主上*; peak = a **16 vCPU** guest's projection |
| `nproc` on this laptop | **14** — a 16-vCPU guest does not project onto it |
| every `/proc/*/cmdline` containing `qemu` | only `405062 qemu-system-x86_64 -name claude-cowork-vm`; **`/proc/52578` does not exist** |

⚠️ **The third check matched itself.** The enumeration written to find qemu processes listed the
shell running it, because that shell's own command line contained the string `qemu`. Same family
as F-20's `pkill -f`: **the victim is chosen by what it happens to mention.** Caught live, while
checking for exactly this class of defect.

### Standing constant, not a treatment — do not re-derive it as a finding

`pid 405062` `qemu-system-x86_64 -name claude-cowork-vm` has been up since **2026-08-30 19:41:30**
— about **30 hours**, spanning §0-ter's baseline measurement and every cell of this round — for a
total of **6m55s of CPU, ≈0.004 cores averaged**. It was already running when the baseline was
measured, so **it is inside the baseline and must not be counted again as contamination.**

⚠️ **Counting qemu by name is unsound on this machine anyway**: `遠端機器測試` disclosed that its
fixtures spawn stand-ins whose `argv[0]` is literally `qemu-system-x86_64` (six sites). A witness
that counts by name counts them as VMs. Registered for the next round with F-20.

### What is restored, and what survives the retraction

**Restored, unchanged:** the ratios **1.987** and **1.768**, and the KNOWN-OVERLAP set. Bands A
and B only. The classifier reproduces both numbers exactly.

**Survives, because none of it depended on the third band:**
* 🔴 **No `clean` category** — but the *reason changes*. Not "we know the list is incomplete"
  (that instance was withdrawn); rather **enumeration of foreign load yields a lower bound, never
  a list.** Band A and B were derived from `scratchpad/mut/` mtimes and commit stamps, which are
  structurally blind to a period where something ran without writing files — the reporting session
  says exactly that of its own method: *"I had no such period this time, but that is luck, not
  design."* **"Cannot be shown complete" is weaker than "shown incomplete", and the report must use
  the weaker one.**
* The categories: **KNOWN-OVERLAP** / **BRINGUP-ONLY** / **UNKNOWN**, where UNKNOWN is not clean.
* The **≈0.95-core** effective floor travelling with every GREEN statement (F-13a).
* The machine-readable sidecar with **named readers** (`raw/cell_overlap.tsv`; the 2×2 figure and
  FINDINGS, not prose).
* The **downgrade of the direction-is-conservative argument** — every affected cell sits at the
  bottom of the ladder where saturation was never going to occur, so the primary is protected by
  the ceiling landing at the top rungs hours after every known band, not by that argument.

**Weakened, but not lost — and the surviving version is cleaner.** The auditor's form of the
argument — *"re-running is ill-defined because the dirty set is not enumerable"* — was demonstrated
with "one afternoon took the population from 5 to 14". That instance is withdrawn with band C. The
correct instance is **5 → 7**, and it is a better demonstration precisely because it is smaller:

🔑 **The two extra cells (`e_p_1024_2`, 35 s; `e_bl_0032_1`, 49 s) came from a change of method,
not from a new source of contamination.** Nothing on the machine changed; the span convention did.
**A count that moves when the analyst's convention moves is not a list of the contaminated cells —
it is one reading of them.** That is what makes "re-run the dirty ones" ill-defined, and it needs
no undiscovered band to make the point.

⚠️ **A correct general rule paired with a wrong instance is harder to retract than no instance at
all, because the rule vouches for the instance** (`遠端機器測試`). Band C is the example: the rule
"enumeration gives a lower bound" was and is right, and it lent credibility to an instance that was
about another machine. **Retract instances separately from the rules they were recruited to
support.**

### 🔴 Which span decides — settled, because the retraction cycle exposed it

🔑 **The general rule, which is larger than this round: the unit of classification must match the
unit of the quantity being analysed.** The first attempt to settle this used "the wider span finds
more cells" as its justification — **finding more is not a reason**, it is just a bigger number,
and it would equally justify widening the span until everything is suspect. The reason has to come
from the quantity: `spread` is computed from the measurement window, so the measurement window is
what can contaminate it.

`spread` is computed from the **measurement window**, so that window decides KNOWN-OVERLAP.
Bringup (teardown, rebuild, P4 recompile) is reported in its own column rather than folded either
way: **silently including it inflates the suspect set, silently dropping it hides a real overlap.**
Under the full-cell convention `e_p_1024_2` and `e_bl_0032_1` would have been suspect; under the
measurement window they are BRINGUP-ONLY. The convention was ambiguous for two hours and the
ambiguity was worth 35 s and 49 s of overlap — the kind of difference that decides whether a rung
has enough cells to compare at all.

| rung | n | all-cell | KNOWN | elig | mean elig | step | √n pred | obs | **obs/pred** |
|---|---|---|---|---|---|---|---|---|---|
| 1/1024 | 6 | 23.935 | 3 | 3 | 23.790 | — | — | — | — |
| 1/256 | 6 | 11.970 | 0 | 6 | 11.970 | 4× | 2.000 | 1.987 | **0.994** |
| 1/64 | 6 | 6.872 | 2 | 4 | 6.770 | 4× | 2.000 | 1.768 | **0.884** |
| 1/32 | 6 | 5.361 | 0 | 6 | 5.361 | **2×** | **1.414** | 1.263 | **0.893** |
| 1/16 | 6 | 5.399 | 0 | 6 | 5.399 | **2×** | **1.414** | **0.993** | **0.702** |

🔴 **Read `obs/pred`, not `obs`** — the ladder's steps are 4×, 4×, 2×, 2×, 2×, 2×, 4×, so the
prediction is not a constant.

## 🔴 MORATORIUM: no shape description of `spread` until the ladder finishes (auditor, 03:4x)

**The same observation has been described three times tonight, and all three descriptions were
relayed onward:**

| version | the shape claimed | rungs of data | how far it travelled |
|---|---|---|---|
| 1 | "monotonically departing from 2" | 3 | me → auditor → Adam |
| 2 | "one step to ≈11% short, then flat" | 3 (step sizes corrected) | me → auditor → Adam |
| 3 | "minimum at 1/32, a turning point" | 6 | me → auditor |

**All three were honest, each was the best reading of the data in hand, and each was overwritten by
the next batch.** Version 1's *method* was wrong (comparing against a constant); versions 2 and 3
had correct method and were overturned by new data. With 1/8 included the sequence of `obs/pred` is
**0.994, 0.884, 0.893, 0.702, 0.625** — which is neither "flat after one step" nor a simple turn.

⇒ **There will be no version 4.** Two rungs remain and they finish tonight. `overlap_bands.py`
keeps printing the numbers — those are data — but **no shape adjective travels until 1/1 is in.**
"Floor", "turning point", "monotonic", "plateau" are all shapes, and **shape is the thing that has
been overturned four times in one night.**

🔑 The rule generalises past this quantity: **a description of shape is a claim about the data you
have not collected yet.** The numbers are safe to publish while the run is live; the adjective is
not.
🔴 **口徑 unchanged: this remains an unregistered secondary observation and may not explain or
reinforce the primary (Q2/E4).** If the ceiling moves, the reason is stated in rung language.
⚠️ Every cell through 1/16 still reads `mark=OK` — so the departure is happening **while the
primary's own criterion is still clean**, which is the opposite of what §4 pinned. That is to be
reported as a miss, loudly, whatever the remaining rungs do.

🔴 **These figures are the corrected ones.** Until 02:52 this table was computed from
`run_e.leg1.stdout.log`, which does not contain the cells the 02:18 resume produced, so 1/16 read
as "1 of 6". `overlap_bands.py` now reads `run_e.log` — the union across both runs — and
**reconciles its parse against `raw/cells.tsv` before printing anything**, so a stale source names
itself instead of quietly shortening a rung. The PROVISIONAL marker is what caught it; a marker is
not a substitute for reading the right file.

🔑 **The uncorrected version of this table said "1.987 → 1.768 → 1.417, monotonically departing".**
That reading compared ratios taken over different step sizes against the same 2, which is the
ratio-with-mismatched-sides error in a new costume: **the two sides of a comparison must share a
step before the comparison means anything.** The last figure also moved (1.417 → 1.263) when the
rung completed from 3 cells to 6 — an interim mean read as a result.

`8/31 auditor` found a band neither of the two self-reports covered, from evidence neither this
round's instruments nor the reporting session's own accounting could produce: **a qemu VM,
`pid 52578`, in that session's committed witness logs** —
`…/2026-08-31_completeness-experiments/B-nslab-build/raw/host_witness_a_rerun.log` (150 samples,
23:57:39→00:10:10) and `host_witness_bcd.log` (200 samples, 00:14:12→00:30:54). Verified here:
**350/350 samples say `qemu=1`, all `pid=52578`.**

🔴 **Band C is a lower bound.** A witness log records only while the witness process lives; the VM
may have started earlier and stopped later. **`pid 52578` is gone, so its `utime`/`stime` died with
it** — "a VM was up" can no longer be converted into "it drew N cores" by any measurement that
still exists.

`overlap_bands.py` now classifies each cell over its **full span** (header → gate line, including
bringup), which is the conservative choice and is what makes the 35 s, 36 s, 9 s and 49 s edges
count. Result: **KNOWN-OVERLAP 14/20, UNKNOWN 6/20.**

| rung | n | all-cell mean spread | KNOWN | UNKNOWN | ratio over UNKNOWN cells |
|---|---|---|---|---|---|
| 1/1024 | 6 | 23.935 | **6** | **0** | n/a |
| 1/256 | 6 | 11.970 | 5 | 1 | n/a |
| 1/64 | 6 | 6.872 | 2 | 4 | — |
| 1/32 | 3 | 4.779 | 1 | 2 | n/a |

### 🔴 What is withdrawn, and what replaces the reasoning

* **The word `clean` is withdrawn from this file, from `overlap_bands.py`'s output and from its
  table headers.** No cell on this machine can be shown to be free of foreign load. There are two
  defensible categories and neither is "clean": **KNOWN-OVERLAP** and **UNKNOWN** (nobody has
  evidence either way).
* **The sensitivity ratios 1.987 and 1.768 are withdrawn.** Both were computed over cells now known
  to overlap. 1/1024 has **zero** non-overlapping cells left and 1/256 has one. **The comparison
  cannot be computed at all — that is the result, and recomputing it against a longer band list
  would repeat the error with a fresher number.** A third band appeared after the first two were
  believed complete; the population of bands is not enumerable by anything this round runs (F-21).
* **The reason for keeping the cells changes.** Re-running "the contaminated ones" presupposes that
  set is enumerable. It is not: one afternoon's reading took it from 5 to 14, and the VM's true
  extent is unrecoverable. **For a population you cannot enumerate there is no such action as
  "re-run the dirty ones"** — it converts five unknowns into fourteen and relocates them into
  another unaccounted period. The option is *ill-defined*, not merely expensive.
  🔴 **Keeping the cells is justified because the alternatives cannot be defined — NOT because the
  contamination was shown harmless. Those two sentences may not be interchanged in the report.**
* **The "direction is conservative" argument survives but carries less weight than it looks.**
  Stealing CPU can only make a cell look saturated earlier, so it can produce a falsely *low*
  ceiling and never a falsely high one; all affected cells read `mark=OK`. Verified. **But every
  affected cell sits at 1/1024–1/32, the bottom of the ladder, where saturation was never going to
  occur.** The primary is protected because the ceiling will be found at the top rungs, hours after
  every known band — not by this argument, which is nearly empty where it applies.
* 🔴 **Every statement that a gate was GREEN must carry the effective floor ≈0.95 cores (F-13a),
  not the nominal 0.5.** All 20 cells passed; all three bands sat mostly below that floor; so GREEN
  carries no information about them. The number travels with the claim, not only with the argument.

### The marking has a named reader

`raw/cell_overlap.tsv` is written machine-readable next to `cells.tsv`. **Its readers are the 2×2
figure and FINDINGS — not this file's prose.** A suspect marker that lives only in markdown is a
writer with no reader, which is a defect this project has already paid for.

---

## 5-quater. 03:30 — the arms separate for the first time, on Q2's factor, at 1/8

| rung | `bl` ratio (1 kHz) | `p` ratio (1 Hz) | Δ(p−bl) | `bl` spread | `p` spread | marks |
|---|---|---|---|---|---|---|
| 1/1024 | 0.9996 | 1.0016 | +0.0020 | 24.353 | 23.517 | OK |
| 1/256 | 1.0008 | 1.0063 | +0.0056 | 11.917 | 12.023 | OK |
| 1/64 | 1.0027 | 0.9961 | −0.0066 | 6.629 | 7.115 | OK |
| 1/32 | 0.9996 | 0.9996 | −0.0000 | 5.323 | 5.399 | OK |
| 1/16 | 1.0006 | 0.9995 | −0.0011 | 4.994 | 5.805 | OK |
| **1/8** | **0.9717** | **1.0008** | **+0.0292** | 6.351 | 5.874 | OK |

The two arms track each other within **±0.007** across five rungs and then separate by **0.0292** at
1/8 — four to fifteen times any earlier rung's difference. The individual cells do not overlap:
`bl` = 0.9692 / 0.9751 / 0.9707, `p` = 0.9998 / 1.0030 / 0.9997, with a gap of ~0.024 between the
closest pair. **`bl` and `p` differ only in recompute period** (1 kHz vs 1 Hz), which is Q2's factor.

🔴 **SUPERSEDED at 06:50 — see §5-undecies.** With only two arms this reads as a recompute-axis
effect, and it was relayed onward as one. **Four arms show it is an interaction**: the recompute
period moves `ratio` only when batching is off. **No main effect of either axis is supported.**

### 🔴 What this is not

* **It is not a ceiling.** Every cell reads `mark=OK`; 0.9717 is above `cell_verdict`'s frozen 0.95.
  **The registered primary is the ceiling rung, and no rung has stopped being healthy.**
* **It is not R-E2.** R-E2 compares `P`/`MP`'s ceiling rung against `BL`/`M`'s. That comparison
  needs a rung where the marks differ. It does not exist yet.
* **It cannot address Q1 or Q3 at all** — batching is the `m`/`mp` arms, which are leg 2.
* **n = 3 per arm.** The separation is clean for n=3 (disjoint, wide margin) and it is still one rung.

### 🔴 WITHDRAWN: "R-E2 is answerable from leg 1 alone"

I wrote, and told the auditor, that *"if `bl` crosses 0.95 at 1/4 or 1/1 while `p` does not, then
`P`'s ceiling rung is strictly higher than `BL`'s and R-E2 is answerable from leg 1 alone."*
**That is wrong on two counts, both of them written verbatim in `run_e.sh:21-26`:**

> *"The top rung's availability is judged on **MP** — the production-side cell, expected highest —
> **never on BL**. Dropping the top rung because BL died there would cut exactly where the effect
> is. So there is NO stop condition in this loop that removes a rung."*
>
> *"A cell that reads healthy at the top rung is recorded as **RIGHT-CENSORED** (`">=1/1"`), never
> as 'the ceiling is 1/1'. **Two censored cells compared to each other are INDISTINGUISHABLE.**"*

1. **Availability at the top is judged on `MP`, which is leg 2.** `BL` saturating first would be
   **`BL`'s ceiling, not the ceiling** — and treating it as the latter cuts exactly where the effect
   is expected to live.
2. **If both arms stay healthy through 1/1 they are both right-censored, and two censored values are
   `INDISTINGUISHABLE`** — not "equal", and not a result. I had not accounted for this at all: a
   large ratio separation at 1/1 with both marks OK still yields *indistinguishable*.

### 🔴 Both branches committed to NOW, before the data that decides between them

| what 1/4 and 1/1 show | what the report says |
|---|---|
| `bl` saturates while `p` does not | `P ≥1/1 > BL` — a right-censored value already above the other's determined value still supports the inequality, so **R-E2 *is* answerable for this pair from leg 1** (auditor confirms this branch) |
| **both arms still OK at 1/1** | 🔴 **both right-censored ⇒ `INDISTINGUISHABLE` ⇒ R-E2 not answerable from leg 1. The report says "indistinguishable" and stops there.** That is a legitimate outcome of the registered design, **not a failure.** |

⚠️ **Why this is written before the data and not after.** The second branch arrives at ~05:00 with
seven hours of measurements in hand and a primary that cannot be answered — **the exact moment of
maximum motivation to reach for the unregistered `ratio` separation in order to "say something".**
Q2/E4 forbids precisely that action. 🔑 **Committing to the wording now is what makes it a decision;
leaving it to 05:00 makes it a test of self-restraint, and this round has no evidence that mine is
adequate to that moment.**

✅ The code protects itself — **no stop condition removes a rung**, so 1/4 and 1/1 will run whatever
`bl` does. **The risk was never in the loop; it was in a person reading "bl is falling" as "we found
the ceiling."** Caught by the auditor before the 1/4 data existed, which is the only time such a
correction is free.

### 口徑, stated precisely

`ratio` **is** registered — as one of three health conditions (`ratio ≥ 0.95`, λ of the same order
as the control arm, `distinct` non-zero: PREREG §236, §296), which is what sets `mark`. What is
**not** registered is **comparing the arms by ratio magnitude while both are healthy.** That
comparison is an unregistered secondary observation on the recompute axis, the same tier as
`spread`, and by Q2/E4 it is reported separately and **may not explain or reinforce the primary**.
Round-wide `SATURATED` count is **0**: no rung has stopped being healthy, so no ceiling exists yet
for any arm.

⚠️ Separately, the `spread` means through 1/8 are **23.790, 11.970, 6.770, 5.361, 5.399, 6.113**
and `obs/pred` is **0.994, 0.884, 0.893, 0.702, 0.625**. 🔴 **No shape is asserted — see the
moratorium in §5-ter.** Two rungs remain; the description is written once, after 1/1. This is in any
case the unregistered secondary observation and may not explain or reinforce anything above (Q2/E4).

---

## 5-quinquies. 03:36 — the first non-OK cell, and it is not `SATURATED`

```
VERDICT cell=e_bl_0004_1  mark=DATAPLANE-HURT  ratio=1.002
        gt_mbit=109.6  lost_pct=45.21  lam=1.1e+08  spread=30.53  distinct=231
```

Every earlier cell: `gt_mbit ≈ 206`, `lost_pct` 0.01–0.33, `lam ≈ 2.05e+08`. **200 Mbit/s was
offered and the data plane delivered 109.6 — 45% lost.** The run did not stop (no stop condition
removes a rung, by design) and `e_p_0004_1` began immediately. **Not contamination:** that cell's
CPU gate read `GREEN excess=-0.529, foreign_cores=0.208`.

### 🔑 `ratio = 1.002` is the most dangerous number on this line

It looks perfect. What it means is that **the twin faithfully reported a switch that was dropping
45% of its traffic.** `cell_verdict.py`'s docstring states why, verbatim:

> *"packets lost in the fabric UPSTREAM → gt falls WITH twin → ratio stays ~1, **invisible**"*

`gt` is that interface's **own tx counter**, so upstream loss moves both sides of the ratio
together. **"Sampling started hurting the data plane" is structurally invisible to `ratio`**, and
the receiver-side `end.sum.lost_percent` check exists for exactly that reason.
⇒ Same shape as F-3a, F-10, F-16 and F-21: **a correct-looking answer produced by a quantity with
no discriminating power over the thing being asked.** The difference is that here the instrument's
authors saw it coming and added a third check.

### 🔴 MY READING WITHDRAWN — `DATAPLANE-HURT` does not set the ceiling (auditor, 03:5x)

I submitted that :296's three conditions abbreviate an inherited four-condition criterion, so
`e_bl_0004_1` would be unhealthy and **`BL`'s ceiling would be 1/8**. **Overturned.** The registered
text separates the two on purpose — **08-25 PREREG:131-134, verified here verbatim:**

> - `mean(vs)/gt < 0.95` ⇒ 該格標 **SATURATED**，**不進精度曲線**，**只進天花板敘事**。
> - `end.sum.lost_percent > 2.0%` ⇒ 該格標 **DATAPLANE-HURT**，**與 SATURATED 分開記**。
> - 兩者皆未觸發 ⇒ 該格進精度曲線。

**"Only enters the ceiling narrative" is attached to `SATURATED` alone, and `DATAPLANE-HURT` is
explicitly required to be recorded separately.** That is not an omission being abbreviated; it is
two phenomena deliberately registered apart — *sampling broke the measurement* versus *sampling
broke the network*. `cell_verdict.py:83-93` agrees: `marks` is a list, `OK` means no flag fired, and
`mark != OK` spans `SATURATED`, `DATAPLANE-HURT` and `LOSS-UNKNOWN` — while the registered ceiling
language is locked to `SATURATED`.

⇒ **`e_bl_0004_1` does not establish `BL`'s ceiling. No arm's ceiling has been read yet; 1/1
remains.**
⇒ Per the same registered line, **`e_bl_0004_1` does not enter the precision curve.**

### 🔑 The finding this actually produced — and it is bigger than the ceiling number

**The registered "ceiling" is a ceiling on telemetry fidelity, not on how densely you can safely
sample.** At 1/4 the fidelity was intact — `ratio = 1.002` — while the data plane lost **45%**
(`gt` 109.6 against 206).

🔴 **The report must say this in as many words**, because a reader will take "ceiling ≥ 1/1" as an
operational recommendation. **A ceiling that says "1/4 is fine" sits precisely on the rung where the
data plane loses 45% of its traffic.**

### What the report must do — four things, all of them

1. **Compute the primary as registered**: the ceiling comes from `SATURATED` only; `DATAPLANE-HURT`
   is recorded separately.
2. **Print both readings' answers**, labelled *registered* and *alternative (mainDev's)*. The data
   supports both computations; listing both costs nothing, and **a reader is entitled to see where
   the registration did not disambiguate.**
3. 🔴 **State that the disambiguation happened after the data was seen.** Even read literally, the
   *timing* is post hoc — **omitting this would package a post-hoc ruling as pre-registration.**
4. Keep `e_bl_0004_1` out of the precision curve (08-25, explicit, no ambiguity).

⚠️ **And record the direction of the ruling.** My reading produced a *definite* answer (ceiling =
1/8); the auditor's leaves the primary open. Tonight every failure leaned toward "easier to tell",
so the auditor checked their own ruling for over-correction against that bias and concluded the text
is explicit and the code agrees. **That self-check belongs in the report so the reader can judge it
rather than take it on trust.**

### Registered for the next round: a defect in the criterion, not an error in this round

**A rung that costs 45% of the data plane is "healthy" under the registered three conditions.**
Either `lost_pct` belongs in the ceiling criterion, or "ceiling" needs a name that says which
ceiling it measures. The D round was right to separate the two; what nobody did on inheriting it
was ask **"which of these two ceilings am I reporting?"**

### Reconciliation against a prior round, as required

**08-25 PREREG:276 (D-P1)** predicted that *if* proxy cost were **per byte**, the wall would move
about an order of magnitude and **1/8 and 1/4 would become healthy**. That per-byte hypothesis was
subsequently **refuted** — the cost is per-sample. ⇒ **1/4 being hurt is consistent with that
refutation**, not a fresh surprise. This is the round's reconciliation entry for this cell.

⚠️ `spread`, `floor` and `distinct` all moved sharply in this cell. **No shape is described** — the
moratorium in §5-ter holds until 1/1 is in.

---

## 5-sexies. 04:08 — rung 1/4 complete, and the trap that appears once three rungs sit side by side

Verified from `raw/cells.tsv`, all six cells of each rung:

| rung | arm | ratio range | `gt_mbit` | `lost_pct` |
|---|---|---|---|---|
| 1/16 | bl | 0.9988–1.0030 | 205.8–206.0 | 0.015–0.10 |
| 1/16 | p | 0.9981–1.0020 | 206.0 | 0.008–0.02 |
| **1/8** | **bl** | **0.9692–0.9751** | **206.0** | **0.011–0.33** |
| **1/8** | **p** | **0.9997–1.0030** | **206.0** | **0.014–0.02** |
| **1/4** | bl | 0.9985–1.0070 | **109.6–111.0** | **43.08–45.21** |
| **1/4** | p | 1.0020–1.0100 | **109.4–117.6** | **41.24–42.43** |

Rungs 1/1024 through 1/8: `gt` 205.4–206.0, loss 0.008–0.36%. **The fabric was healthy for six
rungs and collapsed at the seventh.**

### It is a property of the rung, not of the arm

All six cells hurt; the two arms are numerically indistinguishable (bl 45.21/43.47/43.08, p
41.24/42.26/42.43). ⇒ **The recompute period does not modulate the data-plane damage.** The harm
comes from the sampling itself, not from the kernel's recompute load. **One cell could not say this;
the completed rung can** — the same observation only acquired a population when the rung finished.

### 🔴 The trap: `bl`'s ratio goes 1.00 → 0.97 → 1.00, and that reads exactly backwards

A reader's first reaction is *"it got worse, then recovered."* **It is the opposite.**

* At **1/8** the fabric was healthy — `gt` 206.0, loss ≤0.33% — so `bl` falling to 0.97 is a **real
  signal**.
* At **1/4** the fabric collapsed — `gt` halved, 43% lost — and **`ratio` returned to 1.00 because
  the gauge went blind.** Upstream loss drags `gt` down together with the twin
  (`cell_verdict.py:14-15`), so the ratio recovers while the system degrades.

The arithmetic closes: 43% lost ⇒ 57% delivered ⇒ 57% × 200 Mbit/s = **114**, against a measured
109.4–117.6. **The twin faithfully tracked a network delivering half of what it was given.**

🔴 **The report must state that `ratio` improves as the system gets worse.** Without that sentence
the column lies by itself — and it tells the most reassuring lie available. This is tonight's
recurring shape once more, with a twist: the quantity is not merely undiscriminating here, **it
moves in the wrong direction.**

### 1/8 is the only rung that can speak about the recompute axis — and it is one rung

| rungs | fabric | arms |
|---|---|---|
| 1/1024 – 1/16 | healthy | **do not separate** |
| **1/8** | **healthy (loss ≤0.33%)** | **cleanly separated** |
| 1/4 | **collapsed** | do not separate — **and the gauge is blind** |

⇒ **The recompute-axis effect is speakable at 1/8 and nowhere else**: above it there is no signal,
below it there is no discriminating power. **That is one rung, n = 3 against 3.**
⚠️ **Written in the same breath as the signal, deliberately.** Split into two paragraphs, a reader
keeps the signal and drops the limitation.

### Unchanged

Ceiling from `SATURATED` only ⇒ **neither arm has a ceiling yet**; 1/1 is running. If it too has no
`SATURATED`, both arms are right-censored ⇒ **`INDISTINGUISHABLE`**, written as already committed in
§5-quater, and the report stops there. All six 1/4 cells stay **out of the precision curve**.
`spread`/`floor` shapes remain under moratorium until 1/1 is in.

---

## 5-septies. The reconciliation constraints, pinned before the last rung lands

PREREG §6 governs how this round may be compared with earlier ones. Writing them down **now**,
while the final rung is still running, so the 05:00 write-up cannot loosen them by accident.

**① The prior figure this round exists to update: "取樣天花板 ≈1/16", and it is the *pre-change*
binary's number.** §6: *"天花板若動 ⇒ 更新「取樣天花板 ≈1/16」與
`telemetry-cost-is-fixed-not-per-sample`"*.

🔴 **② Cross-binary ⇒ direction and rung-distance ONLY.** §6, verbatim: *"**同 fabric、同 binary
才逐格比，跨 binary 只比方向與格距**"*. This round's cells against the 08-20 `t008_poll` /
`t004_poll` cells is a cross-binary comparison. **Per-cell value comparisons are not permitted; the
comparison is "did it move, and by how many rungs".**

🔴 **③ The reconciliation is cross-interpreter, and the wording is fixed.** §6 v1.1: the prior
verdicts were produced by a Python in a dead session's scratchpad that no longer exists. Measured:
`miniconda3` and `.plotvenv` give **byte-identical** verdicts for `t004_poll`/`t008_poll`. ⇒ the
round may write ***"there is currently no evidence this axis moves the numbers"*** and **may not**
write *"it has been shown not to move them"*. **"No evidence" is not "proved absent."**

**④ E-P4 already has a prior, and it points the other way.** §6 (v0.3): `gate_e.out` (1/256,
batch 1 vs 8) and `wall_f.out` (1/16), both on the 1 kHz side, are partial `BL` vs `M` cells.
**Batching did not move `ratio` at either working point** (1/16: six cells 0.9955–1.004; 1/256:
1.016 → 1.008). ⇒ **If leg 2 sees `ratio` fall, that contradicts a prior measurement and is
reported as a bug under §3b — not as a ceiling movement.** This strengthens E-P4 from a rule into a
rule with a prior.

**⑤ Retracted, must not be cited**: the *"~4,900 samples/sec ceiling"* extrapolated from
206 µs/sample (`ab-control-deleted-nothing`).

⚠️ **What this round can say about ① at all.** With `SATURATED` count 0 through 1/1, the
telemetry-fidelity ceiling is **right-censored at ≥1/1** for both arms. Against a prior of ≈1/16
that is a *direction* (higher) and a *rung-distance* (≥4 rungs) — **which is exactly and only what
constraint ② allows.** 🔴 And it must carry §5-quinquies' sentence: the ceiling that moved is the
**telemetry-fidelity** ceiling, on a ladder whose top four rungs cost 43–85% of the data plane.

---

## 5-octies. 🔴 The precision curve ends at 1/8, and no later rung can extend it

`spread` is `sd_mean` — `sqrt(pvariance(counts)) / lam * 100` (`plot_ladder_rates.py:84`), a
relative dispersion of the sample counts. **It is a precision-curve quantity.** The registered
inclusion rule (08-25 PREREG, verbatim) is:

> `mean(vs)/gt < 0.95` ⇒ **SATURATED**, **不進精度曲線** … 兩者皆未觸發 ⇒ **該格進精度曲線**。

Counted from `cells.tsv`:

| rung | cells entering the precision curve |
|---|---|
| 1/1024, 1/256, 1/64, 1/32, 1/16, 1/8 | **6/6 each** |
| 1/4 | **0/6** |
| 1/1 | **0/6** (0/3 at the time of writing) |

⇒ **The √n comparison legitimately ends at 1/8. The sequence is already complete:**
means `23.790, 11.970, 6.770, 5.361, 5.399, 6.113`; `obs/pred` `0.994, 0.884, 0.893, 0.702, 0.625`.
🔴 **Extending it into 1/4 or 1/1 would use those cells for exactly the purpose the registration
excluded them from.** Their `spread` figures (28–63) are recorded, and they are not points on this
curve.

⚠️ **This changes what waiting for 1/1 buys.** It settles the ceiling narrative — the `SATURATED`
count, hence the primary — but it **cannot add a point to the precision curve**. The moratorium on
describing the curve's shape is therefore not waiting for more curve data; there is none coming.
🔑 **It is held anyway until the run ends**, because the reason to wait was never only "more data" —
it was that four shape claims tonight were overturned, and there is no cost to fifteen more minutes
against a demonstrated cost to describing early.

---

## 5-novies. 🏁 04:47:45 — leg 1 complete (48/48). The moratorium lifts; this is the one description

`ladder complete` printed, `restore verified`, `rc=0`. Frozen before leg 2 could append:
`raw/leg1-final-analysis.txt`.

| rung | n | mean (eligible) | step | √n pred | obs | **obs/pred** | status |
|---|---|---|---|---|---|---|---|
| 1/1024 | 3 elig / 6 | 23.790 | — | — | — | — | on curve |
| 1/256 | 6 | 11.970 | 4× | 2.000 | 1.987 | **0.994** | on curve |
| 1/64 | 4 elig / 6 | 6.770 | 4× | 2.000 | 1.768 | **0.884** | on curve |
| 1/32 | 6 | **5.361** | 2× | 1.414 | 1.263 | **0.893** | on curve |
| 1/16 | 6 | 5.399 | 2× | 1.414 | 0.993 | **0.702** | on curve |
| 1/8 | 6 | 6.113 | 2× | 1.414 | 0.883 | **0.625** | on curve |
| 1/4 | 6 | 29.613 | — | — | — | — | 🔴 **OFF-CURVE 0/6 OK** |
| 1/1 | 6 | 57.523 | — | — | — | — | 🔴 **OFF-CURVE 0/6 OK** |

### The description, once

**√n holds essentially exactly at the sparse end and then fails progressively, and the mean spread
stops improving after 1/32.** `obs/pred` runs 0.994, 0.884, 0.893, 0.702, 0.625. In absolute terms
the mean falls 23.790 → 11.970 → 6.770 → 5.361 and then does not fall again: 5.399 at 1/16, 6.113
at 1/8. **The minimum is at 1/32; past it, denser sampling bought no precision and then cost it.**

Caveats, in the same breath and not in a later paragraph:
* **Six rungs is the entire curve.** 1/4 and 1/1 are excluded by registration (0/6 OK) and **no
  rung can ever be added** — the tool now refuses to print `obs/pred` for them.
* **Eligible n is 3 at 1/1024 and 4 at 1/64** (evidenced foreign-load overlap), 6 elsewhere. **Two
  of the six points rest on fewer cells than the rest.**
* 🔴 **Unregistered secondary observation** (Q2/E4): reported separately, and it **may not explain
  or reinforce the primary.**
* This is a description of a **complete** dataset, not a prediction. That distinction is the whole
  reason it was withheld — four earlier shape claims were made on incomplete data and all four were
  overturned.

### 🔴 The pinned expectation was MISSED, and this is the loud version

§4, pinned 00:50 before rungs 3–8 existed: *"if it stops halving at some rung, I expect the
departure to be **at or below** the rung where `mark` first stops being OK, not above it."*

* `mark` first stops being OK at **1/4**.
* The departure from √n begins at the **256 → 64 step**, i.e. at **1/64**.
* **The gap is `1/64 → 1/4`** — the intervening rungs are 64, 32, 16, 8, 4, i.e. **four steps**.
  🔴 I first wrote *"five rungs earlier"*. **Counted, it is four steps** (five rungs inclusive), and
  this is the **third** rung-distance miscount in this project. ⇒ **Write the interval and let the
  reader count, or count it before writing — never from a feeling of how far apart they are.**
  The expectation is not marginally wrong; it is wrong by half the ladder.

🔑 **What it got wrong is the assumption behind it** — that precision degradation and health
failure share a cause, so one would herald the other. They do not: precision stopped improving at
1/32 while every cell stayed healthy for three more rungs, and health then failed for an unrelated
reason (the data plane, not the sampling path). **Reporting the miss is the point of pinning it.**

### The primary

**`SATURATED` count = 0 across all 48 cells.** Neither arm reached the registered ceiling.
⇒ Both arms are **right-censored at ≥1/1** ⇒ two censored values ⇒ **`INDISTINGUISHABLE`**, exactly
the branch committed in §5-quater before the data existed. **R-E2 is not answerable from leg 1, the
report says so, and it stops there** — that is a legitimate outcome of the registered design, not a
failure.
🔴 **And ">=1/1" names a rung that destroys 85% of the traffic** (F-26).

---

## 5-decies. 🔴 Written 06:10, BEFORE any 1/8 cell of leg 2 existed — both outcomes assigned now

Leg 2's rungs 1/32 and 1/16 came back clean: 12 cells, all `mark=OK`, ratios 0.9967–1.004, `gt` 206,
loss ~0.02%. ⇒ **merge does not change `ratio` there.** But those rungs **had no signal to change** —
leg 1's four arms all sat at 1.00 on them.

**1/8 is the only rung in leg 2 that can carry information**, because it is the only rung where leg 1
had both a healthy fabric and a separation: `bl` 0.9692/0.9751/0.9707 against `p`
0.9998/1.0030/0.9997.

| outcome | meaning, assigned in advance (auditor) |
|---|---|
| **(A)** `m` ≈ 0.97, i.e. it falls with `bl` | the 3% is caused by **1 kHz recompute**, and batching does not modulate it. **Recompute-axis attribution confirmed by an independent arm** — stronger than leg 1's bl-vs-p alone. |
| **(B)** `m` ≈ 1.00, i.e. it does not fall | batching **cancels** the 1 kHz loss ⇒ **attribution reversal**: 0.97 is not "1 kHz's property" but "1 kHz *and unmerged*'s property". |

### 🔴 (B) has no registered home, and neither does (A) — E-P4 is blind to this entire band

E-P4 (`run_e.sh:186`) fires only when `"$v" == *SATURATED*`, and `SATURATED_RATIO = 0.95`.

* **(B) is one-sided out:** a *rise* from 0.97 to 1.00 is merge changing `ratio`, but in the
  "better" direction. The rule registers only the fall. It will not fire and does not say what to do.
* 🔑 **And (A) cannot fire it either** — 0.97 is **above** 0.95. **The whole observed effect lives
  inside E-P4's blind band.** The rule speaks only about saturation-level changes; the phenomenon
  here is 3%.

⇒ **Disposition, fixed before the data:** whichever way it falls, **do not abort** — the guard is not
triggered, and aborting would be acting outside the registration. **Do not report (B) as a positive
result for merge.** The wording is:

> **"E-P4's premise — that merge does not change `ratio` — was violated at 1/8, in a direction the
> rule does not register. This round does not adjudicate its meaning. Registered for the next
> round."**

⚠️ **And in the same paragraph as whatever is concluded, never a later one:** *one rung, n = 3
against 3, and it is the only rung with discriminating power* — below 1/16 there is no signal, at
1/4 and above the gauge is blind (F-26).

🔑 **Why this is written before the numbers.** Four shape claims were overturned tonight and all four
shared one thing: **the number was seen first and its meaning decided after.** Both outcomes here are
attractive to write up — (A) is a clean confirmation, (B) is a more striking reversal — **which is
exactly what makes this the rung that most needs its meanings assigned in advance.** The timestamp
preceding the data is the only thing that gives this section any value.

---

## 5-undecies. 06:46 — the 1/8 rung came back **(B)**, and (B) is the branch with no registered home

Assigned in advance at **06:10:28** (`1c3712a`), before any leg-2 cell of this rung existed:

| cell | arm | ratio | `gt` | loss | mark |
|---|---|---|---|---|---|
| `e_bl_0008_1..3` | 1 kHz, **batch 1** | **0.9692 / 0.9751 / 0.9707** | 206.0 | 0.011–0.331% | OK |
| `e_m_0008_1..3` | 1 kHz, **batch 8** | **1.0020 / 1.0010 / 0.9998** | 205.9–206.0 | 0.011–0.037% | OK |
| `e_p_0008_1..3` | 1 Hz, batch 1 | 0.9998 / 1.0030 / 0.9997 | 206.0 | 0.014–0.020% | OK |
| `e_mp_0008_1..3` | 1 Hz, batch 8 | 1.0010 / 0.9996 / 1.0050 | 206.0 | 0.011–0.018% | OK |

**Δ(m − bl) = +0.0293. Δ(mp − p) = +0.0010.** The three `m` cells are **disjoint** from the three
`bl` cells with a gap of ≈0.025.

### 🔴 The framing that matters: `bl` is the outlier, not "merge rescued it"

**Three arms sit at 1.00 and one drops.** Narration order decides what a reader keeps:

* ❌ *"merge lifted 0.97 back to 1.00"* — reads as merge having a positive benefit. **Unregistered,
  unproven, and the most tellable direction available.**
* ✅ *"a 3% gap appears only in the 1 kHz-**and**-unmerged cell; the other three arms do not have
  one."*

**The second is what the data says. The first adds a causal direction the data does not carry** —
and `mp` against `p` shows merge on its own changes nothing, so merge only "changes" `ratio` in the
one cell whose partner was already anomalous.

### It is an interaction. Neither axis has a main effect

| comparison | isolates | result |
|---|---|---|
| `mp` (1 Hz, on) vs `p` (1 Hz, off) | merge alone | 1.0019 vs 1.0008 — **no change** |
| `m` (1 kHz, on) vs `mp` (1 Hz, on) | recompute alone, **with** merge | 1.0009 vs 1.0019 — **no change** |
| `bl` (1 kHz, off) vs `p` (1 Hz, off) | recompute alone, **without** merge | 0.9717 vs 1.0008 — **drops** |

⇒ **The effect of the recompute period depends on batching. That is an interaction, and no main
effect of either axis is supported.**
🔴 **This retracts the earlier reading** — recorded in §5-quater and relayed to two readers — that
the 1/8 separation was *"the recompute axis"*. That was the honest reading of two arms; **four arms
overturn it.** The correction goes back to the original readers, not only into this file.

### 🔴 DOWNGRADED — the 2×2 does not share a time window, so the interaction is inferred, not measured

The four arms at 1/8 were **not** run together. Verified from `run_e.log`:

| contrast | when | interleaved within the rung? |
|---|---|---|
| `bl` vs `p` | **02:57:19 – 03:29:37** (leg 1) | ✅ bl,p,bl,p,bl,p — clean |
| `m` vs `mp` | **06:14:35 – 06:46:43** (leg 2) | ✅ m,mp,m,mp,m,mp — clean |
| **`bl` vs `m`** | **2 h 45 m apart** | 🔴 **confounded with time of night** |

`run_e.sh:32-33`'s protection — *"drift across the rung is shared by all four arms instead of being
confounded with one of them"* — **holds only within a single leg.** Plan (b) split 72 cells into
48 + 24 to fit the window, and this is the cost.

**What is measured, each clean inside its own leg:**
* leg 1, 1/8: **(bl − p) = −0.0292** — 1 kHz unmerged sits 3% below 1 Hz unmerged.
* leg 2, 1/8: **(m − mp) = −0.0009** — with merge on, the recompute period makes no difference.

**What is inferred:** the interaction is the **difference-in-differences, +0.0282**, and it holds
**only if the time of night does not modulate the `1 kHz vs 1 Hz` contrast itself.** Not "does not
affect the level" — level drift cancels inside a contrast — but **does not affect the contrast**.
🔴 **That assumption is untested, and this round has no data capable of testing it**: each leg ran
in exactly one period.

⇒ **Report the two within-leg contrasts as the results, and the interaction as an inference under a
stated, untested assumption.** The phrase *"a clean 2×2"* is withdrawn — it was mine and the
auditor's both.

⚠️ **The same confound covers the 1/4 comparison** (`m`/`mp` `gt` 127–139 against `bl`/`p` 109–118).
Cross-leg, **and** on a rung where the fidelity gauge is blind. **Not to be interpreted, and to be
labelled uninterpretable wherever it is mentioned** rather than quietly omitted.

### 🔴 No mechanism is established, and this belongs in the same paragraph as the result

**Two different interventions removing the same effect does not identify a mechanism.** The
observation is compatible with several (contention between 1 kHz recompute and per-item emission,
queueing, lock hold time…) and **the data cannot distinguish between them.** The permitted sentence
is: *"at this working point, changing either of the two factors removed the gap; the mechanism is
undetermined."* — **not** *"X causes Y"*.

⚠️ **And in that same paragraph, never a later one: one rung, n = 3 per arm, and it is the only rung
in the round with discriminating power** — at 1/16 and below all four arms sit at 1.00 with nothing
to move, and at 1/4 and above the gauge is blind (F-26).

### 🔴 Disposition, exactly as fixed before the data

1. **No abort.** E-P4 is not triggered: it requires `*SATURATED*`, and every cell here is ≥0.9692,
   above the 0.95 line. **The entire effect lives inside the rule's blind band** — (A) could not have
   fired it either. Aborting would be acting outside the registration.
2. **This is not reported as a positive result for merge.** The registered wording stands:

> **"E-P4's premise — that merge does not change `ratio` — was violated at 1/8, in a direction the
> rule does not register. This round does not adjudicate its meaning. Registered for the next
> round."**

3. 🔴 **And attribution is not discussable at all under the registration.** R-E3 permits talk of
   attribution *"only when at least one of R-E1 / R-E2 is distinguishable"* — both are stated in
   **ceiling rungs**, and **no arm has a ceiling** (`SATURATED` = 0 everywhere). The precondition is
   unmet, so this rung sits **outside the registered attribution framework entirely**, however clean
   it looks.

⚠️ **Same paragraph, not a later one: one rung, n = 3 against 3, and the only rung in the round with
discriminating power** — below 1/16 there is no signal to move, and at 1/4 and above the gauge is
blind (F-26).

### Reconciliation with the prior (§6), which is subtler than "conflict"

§6 records that `gate_e.out` (1/256) and `wall_f.out` (1/16) measured this same batching factor on
the 1 kHz side and found **batching did not move `ratio`**, and it registers that *a fall* in this
round would conflict with them.

* **The prior is reproduced at its own working points**: leg 2's 1/32 gives Δ(m−bl) = +0.0031 and
  1/16 gives +0.0000 — no movement, exactly as before.
* **The new observation is at a working point the prior never covered.** At 1/8 there is a deficit
  to cancel, and batching cancels it.
* **It is a rise, not the registered fall** ⇒ it is not the conflict §6 anticipated either.

⇒ **Not "the prior was wrong". The prior holds where it was measured, and this is one rung beyond
it.**

---

## 5-duodecies. 🏁 07:25:28 — round complete, 72/72. The 1/4 rung, looked at once

`ladder complete`, `restore verified`, `rc=0`. Lab down and clean; `ndtwin_switch.p4` back to
production and git-clean; claim held, not renewed; `SATURATED = 0` across all 72 cells.

| arm | `gt_mbit` | `lost_pct` | `ratio` |
|---|---|---|---|
| `bl` 1 kHz b1 | 109.6–111.0 | 43.08–45.21% | 0.9985–1.0070 |
| `p` 1 Hz b1 | 109.4–117.6 | 41.24–42.43% | 1.0020–1.0100 |
| `m` 1 kHz **b8** | **126.6–130.4** | **35.70–36.98%** | 0.9979–1.0020 |
| `mp` 1 Hz **b8** | **127.5–139.3** | **32.15–34.65%** | 0.9866–0.9970 |

🔴 **WITHDRAWN — this comparison is not about batching.** `batch OFF` = leg 1 (`bl`,`p`),
`batch ON` = leg 2 (`m`,`mp`). **Verified: `batch=1` appears only in leg 1 and `batch=8` only in
leg 2 — the two are perfectly aliased.** The groups do differ (`gt` 112.0 vs 131.8, loss 42.95% vs
34.77%, disjoint on both, 6 v 6) — **but they differ in two things at once, and the group's name is
not "batching", it is "leg".**

🔑 **Six against six being disjoint does not repair a systematic confound; it only shows the two
*groups* differ.** This is `ratio-sides-must-share-a-population` in its sharper form: *can this
population answer to the name it is being used to represent?* **It cannot.** And the rung is one
where the fidelity gauge is blind anyway (F-26).

⚠️ **"Less broken", not "fixed"** — both groups still lose over 30%. And this rung is where the
fidelity gauge is blind (F-26): `ratio` reads ~1.00 on both sides and carries no information.

### 🔴 The registered null wording conflicts with the observations — raised, not resolved

**R-E1-null** fires when the batching effect is below the detection floor, and prescribes:
*"打開 batching **買不到可量測的東西**"*, explicitly forbidding "no conclusion" / "round failed".
Its trigger **is** met: the ceiling is indistinguishable.

🔴 **But "bought nothing measurable" is contradicted by the data.** Batching is measurable in two
places, neither of them the registered outcome: the 1/8 fidelity interaction (Δ +0.0293, disjoint)
and this rung's data-plane difference (disjoint on two quantities, 6 v 6).

⇒ **The registered sentence assumed "no effect"; what happened is "an effect that is not on the
registered quantity". Those are different, and the wording cannot express the second.** Referred to
the auditor. Suggested (not adopted): report the primary as *ceiling did not move, indistinguishable*
and state separately that **batching had measurable effects on two non-registered quantities, which
may not reinforce the primary**.

### Mechanism still not claimed

At 1/8 batching removed a fidelity gap; at 1/4 it reduced data-plane loss. Both are compatible with
"batching reduces per-item work on some shared path" and **the data cannot distinguish mechanisms.**
Wording stays *"changing either factor changed the quantity; mechanism undetermined"*, in the same
paragraph as the limits — 1/8 is one rung at n=3 per arm, and at 1/4 the fidelity gauge is blind.

## 6. Standing constraint

🔴 **C5: no rung, rep or arm is added from here on.** If the ladder proves too short, that is a
finding to register for the NEXT round, not an edit to this one.

[Co-developed with claude code -- Adam]
