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

`spread` is computed from the **measurement window**, so that window decides KNOWN-OVERLAP.
Bringup (teardown, rebuild, P4 recompile) is reported in its own column rather than folded either
way: **silently including it inflates the suspect set, silently dropping it hides a real overlap.**
Under the full-cell convention `e_p_1024_2` and `e_bl_0032_1` would have been suspect; under the
measurement window they are BRINGUP-ONLY. The convention was ambiguous for two hours and the
ambiguity was worth 35 s and 49 s of overlap — the kind of difference that decides whether a rung
has enough cells to compare at all.

| rung | n | all-cell mean | KNOWN | eligible | mean over eligible | ratio |
|---|---|---|---|---|---|---|
| 1/1024 | 6 | 23.935 | 3 | 3 | 23.790 | — |
| 1/256 | 6 | 11.970 | 0 | 6 | 11.970 | **1.987** |
| 1/64 | 6 | 6.872 | 2 | 4 | 6.770 | **1.768** |
| 1/32 | 3 | 4.779 | 0 | 3 | 4.779 | **1.417** |

The departure from √n deepens monotonically — 1.987, 1.768, 1.417 — while every cell still reads
`mark=OK`. That is the ladder doing what §4 said would be the only informative part of it.

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

## 6. Standing constraint

🔴 **C5: no rung, rep or arm is added from here on.** If the ladder proves too short, that is a
finding to register for the NEXT round, not an edit to this one.

[Co-developed with claude code -- Adam]
