# E round — findings and deliverables

Opened 2026-08-31 during the measurement window, by `8/31 mainDev`.
F-1 … F-15 are from the **gate-bringup phase**, which ran 20:16–23:16 and produced fifteen
findings before a single cell was measured. Plan (b) leg 1 started **23:15:57**; anything found
during the ladder itself is appended after F-15.
[Co-developed with claude code -- Adam]

---

## D-1. 🔴 DELIVERABLE, NOT YET STARTED: the 2×2 sampling-ceiling figure

**Do not start this until E's data has landed.** Registered here 2026-08-31 (auditor, prompted by
Adam asking whether the figure existed) because **PREREG registers the measurement and never
registered the figure** — so the data would land with nothing on disk saying it must be drawn,
and it would fall into the gap between "E finishes" and "the 903 deck gets built".
This is a reporting artefact, not a measurement: it needs no amendment, only to be written down.

**Baseline layout** = the existing single-arm figure
`~/Desktop/NDTwin slide material/NDTwin slide material 827/figures/page_sampling-ceiling.png`
— three panels (throughput delivered / receiver packet loss / samples per second λ) against
sampling rate, one line each. Same layout, **four lines**: `bl` (off/1 kHz), `m` (on/1 kHz),
`p` (off/1 Hz), `mp` (on/1 Hz). The fifth BL-true control goes in if it can, and if it cannot
the figure must say so rather than omit it silently (§3a(c): it is **not** runnable as registered).

### 🔴 Three ways to draw this wrongly

1. **The top rung is right-censored.** §3 E1: a cell healthy at the top rung is recorded `>=1/1`,
   never "the ceiling is 1/1", and **two censored cells are INDISTINGUISHABLE, not equal**.
   ⇒ A censored point must not be drawn as a value — no solid marker, no line terminating on it.
   Use an explicit censoring mark, and say in the caption that both arms are censored there and
   therefore not comparable at that rung.
   🔑 **Drawing a censored point as a number converts "we did not measure the ceiling" into
   "the ceiling is here", which is a false conclusion the figure would be asserting on its own.**
2. **The detection floor belongs in the caption, and it is not one number.** Cells are gated at
   **0.5 cores over a per-cell baseline** taken in the same teardown gap, so for the cells the
   registered floor holds. The **gate phase** is a different story: its baseline's own range is
   0.444 cores, so its effective floor is **≈0.95 cores** (F-13a, binding disclosure). A caption
   that quotes 0.5 for the whole round would overstate what was verified before the first cell.
   Per Adam's 2026-08-31 ruling the run **crosses from night into day**; if the boundary shows a
   real baseline shift, the figure must make clear which cells sit on which side. That shift is
   **a finding to report, not noise to average away**.
3. **§6's reconciliation is cross-interpreter** (PREREG v1.1). If any comparison against earlier
   rounds appears in the figure, it must not be worded as "same instrument, per-cell".

**Delivery**: script and PNG together under `$ROUND`, and **the script must reproduce the PNG
byte-exactly** — all eight 903 figures currently satisfy this and it must not regress. Whether it
enters the 903 deck is a separate decision; do not move it there unasked.

---

## F-1. 🔴 The dry run is systematically blind to the defects that stop the round

Four defects tonight, every one of them fatal to the round, **every one green in the dry run**:

| | defect | why the dry run missed it |
|---|---|---|
| 1 | no live fabric | preflight's fabric check is not reached |
| 2 | `PY_PLOT` pointed at an interpreter that does not exist | `check_interpreter` does `return 0` under `DRY_RUN=1` |
| 3 | UDP counter parse returned the string `InDatagrams` | whole branch replaced by a `dry_note` |
| 4 | G1 could not go green for any input | records a **synthetic PASS** |

⇒ This is not four coincidences. **The dry run verifies that control flow reaches each step; every
one of these defects is in the step actually reading a real thing.** A dry run cannot be evidence
that a gate works — only that it is reachable.
🔑 Sharpest instance: G1's recorded history was **4 PASS, all `synthetic`; 0 live passes; 2 live
failures**. `gates_e.sh` entered version control at 15:12 today, so **G1 §2.1 had never once
passed live** before 21:23 tonight.

## F-2. 🔴 Five diagnoses that pointed at the wrong component

Every one of these is a message written to be read at the moment of failure, and every one sent
the reader somewhere other than the fault:

| | the gate said | the fault actually was |
|---|---|---|
| 1 | "a counter reads zero against a live ten-switch fabric — a broken reader, not a quiet fabric" | the parse: `-A1` pulled in the `UdpLite:` header, so `$2` was the string `InDatagrams` |
| 2 | same sentence, second occasion | nothing: G1 generated no traffic, so the fabric **was** quiet and a zero was correct |
| 3 | "a process burning a whole core did NOT turn the gate red" | it **did** — two lines above, `verdict=RED`, `force-test OK`. The exit code was overloaded |
| 4 | "Not green ⇒ the THRESHOLD is wrong" (G5b) | the allow list: bmv2 counted as foreign. The module docstring had it right; the call site did not |
| 5 | `cpu_gate.py`'s header comment: "matching a longer name would silently never fire" | it guarded the too-**long** direction; the entry was too **short** |

🔑 Common structure: **each message was written assuming the defect could not be in the act of
reading or recording the quantity itself.** The author imagined "if this fails here, it must be
because of X" and the actual failure was in the measurement plumbing.
⇒ Transferable test when writing an abort message: **"if the broken thing were the way I read or
record this quantity, would this sentence still be true?"** All five fail it.

## F-3. 🔴 Two of my own runs had zero discriminating power, and both looked fine

1. **20 packets at 1/256** to test whether sFlow emits when idle. `P(0 samples) = (255/256)^20 ≈
   0.925` ⇒ **that run returns 0 whether the hypothesis is true or false.** Only the 3000-packet
   run established anything (25 datagrams, 25 samples).
2. **A leaked burner.** `. ./round.env && awk 'BEGIN{while(1){}}' … &` backgrounds the *whole
   chain*, so `$!` is the bash subshell and the `awk` it spawns is not it — **I killed the wrapper,
   not the work**, and 1.0 core kept burning. The force-red-with-no-burner control then returned
   `rc=0` "force matched" — **and it matched for a reason unrelated to what I was testing**,
   because the machine was already red.

🔑 Neither failed. Both produced **the answer I expected, for the wrong reason.**
⇒ Transferable test, to run *before* accepting a result that came out as predicted:
**"if the thing I am testing had not happened at all, would I have got this same answer?"**
If yes, the run is not evidence and does not belong in the evidence column.
Related: `process-liveness-checks-lie-in-two-ways` — "a background *completed* describes the
wrapper, not the work" — reproduced here first-hand.

## F-4. ✅ G5b worked exactly as designed — this one is not a broken gate

Listed separately from F-1/F-2 on purpose: read together they would suggest every gate this round
is defective, and **this one is the counter-example that shows the design paying off.**

G5b's own comment, written long before tonight: *if a normal arm's own load reads as
contamination, the gate would demand re-running exactly the arms that carry the result.*
That is precisely what happened — `cpu_gate` classified its own bmv2 switches (1.93 cores) as
foreign — **the design anticipated the failure mode, the implementation was one character short,
and G5b caught it.**

## F-5. 🔴 `comm` truncation, the project's second time in the same pit

`FABRIC_COMMS` held `"simple_switch_"` (14 chars) with a comment correctly noting that
`/proc/<pid>/comm` truncates at 15. The real comm is `simple_switch_g` (15). The test was set
membership — exact equality — so the entry **never matched anything**.
First occurrence: pgrep's 15-char comm in the power-on round (`power-on-reports-success-without-acting`),
where the pattern likewise "correctly anticipated" truncation and was still wrong.
⇒ **Knowing a name is truncated is not the same as having counted the truncation correctly.**
Anywhere `comm` is compared: match on a prefix, or write the number 15 down and explain it.

### F-5a. The chosen fix fails in the unsafe direction, and that is accepted, not absent

|  | misclassifies | consequence |
|---|---|---|
| exact, too narrow (before) | ours → foreign | **false alarm** (safe side) |
| prefix (now) | foreign → ours | **contamination missed** (unsafe side) |

This is a contamination gate, so the second is the direction it least wants to fail in. The prefix
form is used anyway because reaching the unsafe case needs someone violating the lab claim **and**
running bmv2 on this machine — what `ndt claim` + `NDT_EXCLUSIVE_CPU=1` exist to prevent.
⇒ Available tightening, **not done**: require the comm prefix **and** the pid to be in the fabric
manifest. Recorded so the next reader does not mistake this for a free choice.

## F-6. 🔴 `ratio_gate.py:157` — latent, deliberately not fixed

Identical line to the `cpu_gate.py` defect: `return 0 if verdict == "GREEN" else 1`, with an
`--expect green|red` argument. **It has no `--expect red` caller today** (G6 uses the separate
`--make-forcered` mode), so it is latent rather than live.
Not fixed during the stamped round because **nothing in this round's forcing would reach it** — the
change would be unverifiable here, which is the shape we have been refusing all evening.
⇒ Fix after E, and add an `--expect red` call site as its own mutation proof.

## F-7. The mutation gate caught a defect the repair itself introduced

Replacing G1's `sleep 6` with the load made the **Udp counter's observation window equal to the
load's duration**. At 1/256 that is ~3 s and fine; at 1/1 it is 12 packets in ~12 ms, and G1 would
have gone red for a reason unrelated to what it tests — **intermittently, only at certain sampling
rates**, which is harder to find than the permanent failure it replaced.
Caught by the force-red run reading `udp=+0` where the old code read `+84`.
⇒ "A test you have not seen fail is not delivered" paid out here on **the repair**, not the
original defect. And it only surfaced because the packet count was required to be *derived*: with a
hardcoded 3000 this would have lain dormant until the rate changed.

## F-8. Single-writer assumptions on a shared worktree

I argued for squashing two commits with "rewriting history is free right now, nothing has started".
It is not: **I had taken "I have nothing unpushed" to mean "nobody has anything unpushed."**
Ten minutes later another session's `22f2b92` landed *between* my two commits, so a rebase would
have moved someone else's work. Citability came from the stamp naming a sha, not from the commits
being adjacent.

## F-3a. 🔴 The GREEN half of a two-way force can be as empty as the red half

Extends F-3, and it is the half nobody checks. Every "forced both ways" claim in this script family
is really two claims, and the habit is to interrogate only the red one:

* **red half**: would this have gone red anyway, without the injection? (F-3's two cases)
* **green half**: would this have gone green anyway, **whether or not the fix works**?

`FORCE_CPU_GATE_DISOWN_FABRIC` is the live example. Against an **idle** fabric the allow-list fix
gives GREEN — and so does the unfixed code, because there is nothing to misclassify. The green
arm therefore has **zero discriminating power at idle**, and three attempts to raise enough load
to give it any all failed (idle fabric / ping flood / ping ended early). What carried the G5b
conclusion until 22:50 was the natural experiment (21:24:19 vs 22:02:33, Δ≈1.43 cores = three
switches changing sides), not the injected green.
⇒ State the rule for both halves: **"if the thing I am testing had not happened, would I have got
this same answer?"** — asked of the *green* run as well as the red one.

✅ **Closed at 22:50** on the fourth attempt, once the load recipe was taken from G5b itself
(`measure.sh` at 200 Mbit ⇒ ~1.5 cores across three switches, 3× the threshold):

| | | |
|---|---|---|
| `ctl_disown_off` | `foreign_cores=0.534  excess=-0.421` | GREEN |
| `ctl_disown_on` | `foreign_cores=3.313  excess=+2.358` | RED |

🔑 The separation is 2.78 cores, so the run answers differently depending on the thing under test —
which is the whole property the first three attempts lacked. **Three of the four attempts produced
the right answer; only the fourth produced evidence.**

## F-9. ✅ Foreign load 22:10:10–22:10:58 reconciled against this round's ledger: **no reading hit**

Reported voluntarily by `bmv2 論文審查` (8/29 poster-reviewer): an `iperf3` loopback probe in the
root netns, nine sequential pairings at `-b 0 -t 5`, i.e. ~45 s of one-to-two cores, inside this
round's exclusive-CPU claim. They read the claim afterwards, not before.
🔑 Their own sharpest point: **`measuring nothing` is a point sample taken later, not the state
during those 48 seconds** — so only this round's ledger can answer whether anything was hit.

**What I checked, and what it says.** Every reading this round has taken:

| reading | when (CST) | in window? |
|---|---|---|
| CPU-gate verdicts, `raw/gates.jsonl` (8 records) | 21:11:02 … **22:02:33** | no |
| continuous 2 Hz CPU trace, `raw/cells/g_gate_load_cpu.jsonl` (181 samples) | 22:01:35.99 – **22:03:05.51** | no |
| `raw/cpu_baseline.json` | 20:21 | no |
| last line written to `gates_e.log` | **22:03:26** | no |
| any file under `$ROUND` with mtime > 22:05 | *(none exist)* | — |
| ladder cells | **not one has run** | — |

The window opens **6 min 44 s after the last thing this round wrote**. The fabric was already torn
down (`restore_production` at 22:03:10) and `ndt status` still reports 0 switches, so at 22:10 this
round had nothing running to perturb. **Nothing is contaminated; nothing needs re-running.**
🔑 Recorded because "checked and clean" and "did not check" are different states, and a findings
file that only records hits cannot tell you which one you are in.

**Taken on trust vs. verified.** The window itself is theirs; I have no independent record of their
iperf3 and am not claiming one. What is verified here is only my side of the reconciliation.

### F-9a. 🔴 And the contamination gate is itself a point sample — it watched 3.1% of the gate phase

**First half of a two-part finding; the second half is F-16**, where the same night supplies the
contrast case — a foreign load that landed inside a continuously-sampled cell and *was* caught.

Summing `window_s` over the eight CPU-gate records: **200 s observed** across a gate phase running
20:16:29 → 22:03:26 (**6 417 s**) — **3.1%**. A 48-second foreign load placed anywhere in the other
96.9% produces exactly the same green verdicts. Tonight's intrusion missed the round by seven
minutes; an intrusion at 21:40 would have been just as invisible and would have left the same
transcript.
⇒ The asymmetry that matters: **ladder cells are not exposed this way.** `measure.sh:52` runs
`cpu_probe.py "$DUR" 2` for the whole of every cell, so a cell is watched continuously at 2 Hz and
a ≥0.5-core intruder inside it *would* register. The blind spot is the **gate phase** — which is
precisely where the "the machine is clean, proceed" decision is taken.
⇒ Not fixed this round (§0-ter's detection floor is registered as-is and the round has started).
The cheap fix for the next one: run the CPU probe continuously for the whole gate phase and gate on
its maximum, rather than sampling at the moments the gates happen to fire.

## F-10. 🔴 G10 and G11 are half-gates: forced red, never forced green

`gates_e.sh` — the `G10 #14` block (`say "--- G10 #14: topology invariant…"`, currently line 608)
and the `G11 #3` block (line 617). Both force **red** and assert the message appears. Neither ever
runs the clean direction, so neither has shown it can come out green — the same shape as G4's
"force-red can never be recorded as a pass" and as G9 before tonight's split (F-11).
**The verification method is itself unverified.** Deliberately not fixed inside the stamped round:
widening the change surface mid-window is what §3b(C5) exists to stop.
⇒ After E: give each a clean-direction call, and note that for G11 the clean direction is nearly
free (`assert_same_boot` unforced) while for G10 it needs a real edge count, i.e. a live fabric —
which is *why* it was skipped, and why the tail of `main()` (F-11) is the place to put it.

🔴 **Amended the same night — and G10 turned out to be worse than half-covered.** Live, `G10`'s
forced red did nothing at all: `DRY_FAIL=edgecount` only acts inside `edge_count`'s `DRY_RUN`
branch, and the injected `EDGE_BASELINE=288` is the **dry run's synthetic count**, which happens
to equal the real one. So the invariant compared 288 with 288, said "matches baseline", and the
gate **failed** at 22:42:09. 🔑 And the constant was worse than merely inert: on a fabric with a
different edge count it would have gone red — *passing* the gate — because a stale constant
disagreed with reality rather than because the injection worked. **Both outcomes are independent
of the thing under test.**
⇒ The baseline is now derived from the live count (`real+1`), so the two differ by construction in
dry and live runs alike. That repair **required** a clean direction as its own mutation control —
"it went red" is worth nothing until the same call is shown not to go red when the counts agree —
so G10 now has one. **G11 remains red-only**, deliberately: nothing changed tonight depends on it.
The asymmetry is a decision, not an oversight.

## F-11. G9 #11 could not go green where it was asked to, and the repair moves it rather than fakes it

**The defect.** G9's clean half ran mid-gates. By that point G8 has left a staged arm's kernel in
`$KBIN` and the P4 source at that arm's rate, so `assert_restore_landed` is **correctly red**. The
gate read its own round's state as a broken check and stopped the round at 22:03:09 — a true
negative reported as a gate failure.
🔑 Three repairs were possible and two were worse: temporarily restoring `build/bin` mid-run makes
**the gate mutate the system it is checking**; a synthetic pair tests the comparison logic, and G9
exists precisely to stop an assertion being vacuously true — proving it non-vacuous with a
synthetic green is self-defeating.

**The repair (Adam's delegate ruled 乙).** The clean half moves to the tail of `main()`, after
`restore_production`. **That is a stronger green than the original, not a weaker one: it is not a
situation arranged so a gate can pass, it is the gate applied to the restore this round actually
performed.**

**The cost, and how it is paid.** Splitting a gate across two points means an abort can run the red
half and never reach the green one. That must be **a recorded gap, not a silent pass**, so
`g9_coverage_note` runs from the `EXIT` trap (reached on abort paths too) and both halves carry the
same `G9 #11` label, the clean half printing the timestamp of the red half.

**Mutation evidence** (three dry runs, `ROUND`/`OUT` redirected to a scratchpad, mutants removed):

| | mutation | result |
|---|---|---|
| M0 | none (control) | red PASS 22:32:56, clean PASS 22:33:09, `halves: … BOTH ran`, rc=0 |
| M1 | `abort` injected directly after the red half | `🔴 G9 #11 COVERAGE GAP … clean half <NOT RUN>`, rc=9 |
| M2 | clean half forced red | clean half FAIL + abort, `BOTH ran` (both did), rc=9 |

⇒ M1 is the one that matters: the gap **announces itself**.
✅ **The partial coverage closed itself the same night.** `raw/G9-COVERAGE.txt` is not written
under `DRY_RUN=1`, so the three mutants exercised only the transcript channel — but the live run
that aborted at G10 wrote the `HALF-COVERED` line at 22:42:25, and the passing run wrote the
`BOTH` line at 23:03:29. Both branches of the file write are now exercised live:

```
G9 #11 2026-08-31T22:42:25+08:00 HALF-COVERED red=22:42:09 rc=1 clean=none
G9 #11 2026-08-31T23:03:29+08:00 BOTH        red=23:03:00 rc=1 clean=23:03:29 rc=0
```

## F-12. 🔴 A forced abort ran the production restore, and live that tears the fabric down

`abort()` ends with `restore_production`. G10 and G11 force their aborts inside
`$( ( … ) 2>&1 || true )`, where `exit 9` kills only the subshell — but `restore_production` does
not respect that boundary: live it runs `teardown` (stack down, `topo-stop`, `mn -c`), recompiles
the P4 source and swaps the kernel binary. **A force in the middle of the gates demolishes the
fabric every later gate and the whole ladder need**, in ~16 s, with nothing in the transcript
saying the fabric had gone.

Invisible in every dry run twice over: `RUN` is a no-op there, **and** the G-MATRIX rows that
exercise `edgecount` and `bootid` all run with `DRY_RUN=1`. Neither force had ever executed live,
so this had never had the chance to fire. It would have fired tonight at G11 regardless of the
G10 repair.

**Evidence, both directions, live** (`gates_e.controls.log`):

| | | result |
|---|---|---|
| C1 | the force **without** the guard | `--- restoring production config ---` ran; **fabric DOWN** afterwards |
| C2 | the same force **with** `FORCED_ABORT=1` | `(FORCED_ABORT set … the production restore is NOT run)`; **fabric still UP** |

⇒ Fixed by making a forced abort say so and skip the restore. 🔑 The general shape: **a test *of*
a failure path and a real trip *of* it must not do the same thing** — the injected one has to be
inert in the world.
🔴 I then repeated the same mistake in my own harness: the first `record_bmv2_identity` control
(F-15) ran **without** `FORCED_ABORT`, aborted for real, and tore down the fabric I had just spent
90 s bringing up. A control that can abort must be run with the abort guard.

## F-13. 🔴 The gate-phase CPU baseline went stale by 0.7 cores, and G4 is what caught it

At 22:53 the burner force failed: `foreign_cores=1.277 baseline=0.955 excess=0.293` → GREEN.
A process burning **a whole core** did not turn the contamination gate red.

The baseline was recorded at 20:19 with the desktop busy (`claude-desktop 0.45 cores`); by 22:53
that had fallen to 0.013. A baseline that is too **high** understates excess, i.e. it fails in the
**unsafe** direction — the gate goes blind to real contamination rather than inventing it.

🔑 **§0-ter's range check cannot see this.** It takes three readings one minute apart and reports
their range; the three at 20:19/20:20/20:21 gave 0.955 / 0.889 / 0.925, **range 0.066** — a
reassuring number. The drift that actually mattered was **0.7 cores over 2.5 hours, ten times the
measured range.** Short-term jitter was being used to bound long-term drift.

**What was done, and what it is not.** The baseline was **re-measured** (3 × 60 s, fabric down),
which changes an *input*, not the threshold — §2.4's 0.5 cores is untouched. The test that this is
a repair and not a way past the gate: with the new baseline **both** directions come out right —
G5a idle GREEN (`excess=-0.467`) **and** G4 burner RED (`excess=+0.54`). Moving a threshold to pass
a force breaks the other direction; correcting a stale input does not.
🔴 The superseded file is kept at `raw/cpu_baseline.2019-superseded.json`. **This is the most
"moving the goalposts"-shaped action of the round and is reversible** — it is flagged for the
auditor rather than buried here.

### F-13a. 🔴 The new baseline's own range is 89% of the threshold — disclose it with any "no interference" claim

`BASELINE n=3 min=0.293 max=0.737 range=0.444 threshold=0.5` — §0-ter's disclosure clause fired.
`cpu_gate.py` reads **the first line** of the file, which was 0.737, the *least* sensitive of the
three; G4 still went red, but at `excess=0.54` against a 0.5 threshold, a margin of 0.04.

### 🔴 BINDING DISCLOSURE (auditor's condition on approving the re-measurement, 2026-08-31)

> **The gate phase's effective detection floor is ≈0.95 cores, not 0.5. Every statement this round
> makes about foreign load during the gate phase must carry that number.**

⇒ In particular, **"all §2 gates green" must not be read as "no contamination above 0.5 cores".**
It means **"no contamination above roughly 0.95 cores"**. Same discipline as §0-ter's own clause,
except that here the floor came out at nearly twice the registered one.
⇒ It also re-scopes F-9: the reported iperf3 was "one to two cores", i.e. **straddling** what this
instrument could have seen, rather than comfortably inside it.
⇒ Ladder cells are unaffected — `run_e.sh:103` takes a per-cell baseline in the gap `teardown`
already creates, so each cell's baseline is contemporaneous with its own measurement.

### F-13b. 🔴 §0-ter's range check has no discriminating power over the quantity it protects

Listed separately from F-13 on purpose: F-13 is a stale input, **this is a registered check that
cannot see the thing it exists to bound**, which is the more serious of the two.

§0-ter takes **three readings a minute apart** and reports their range, on the stated reasoning
that "the baseline's source is operator behaviour, so one reading is a point sample of a moving
quantity: the real detection floor is 0.5 cores PLUS that movement". The reasoning is right and the
instrument does not implement it:

| | | |
|---|---|---|
| range across the three 20:19–20:21 readings | **0.066 cores** | what the check reported |
| drift 20:19 → 22:53 | **~0.7 cores** | what actually determined the floor |

**Ten times the measured range, and the check reports the small number.** It measures short-term
jitter and the round then uses it to bound long-term drift. A reassuring `range=0.066` was produced
by an instrument that had, by construction, no chance of observing the movement that mattered —
three samples inside a three-minute window cannot say anything about the next two hours.
🔑 Same shape as F-1/F-14/F-16, but **this one is written into the registration**, which is the
highest position any of tonight's defects occupies.
⇒ Fix for the next round: space the baseline readings across the *round's own duration*, or
re-take the baseline immediately before each phase that consumes it, and report the spread over
that span rather than over three minutes.
⇒ Not amended here: the round has started, and §0-ter's numbers are registered.

## F-14. 🔴 The ladder aborted on the first cell of every rung, because a precondition checked what the cell was about to destroy

`run_cell` opened with `preflight measure`, which **requires a live P4 fabric**. But the rung loop
(`run_e.sh:199-206`) is:

```
say "===== rung 1/$rate ====="
teardown          # ← fabric DOWN
compile_at "$rate"
  → run_cell → preflight measure   # ← demands a live fabric
```

and `run_cell`'s own next three actions are `teardown`, `cell_baseline` (which *needs* the fabric
down) and `bringup`. **At a cell's entry the fabric is down by design**, so the check asked the
cell to prove a precondition it was about to destroy. Live at 23:06:44: `ABORT(§4): preconditions
no longer hold at cell e_bl_1024_1` — the first cell of the first rung, and by construction the
first cell of *every* rung. **The ladder could not have completed a single rung.**

Invisible in the dry run for the fifth time tonight (F-1): `fabric_is_up` synthesises TRUE under
`DRY_RUN=1`.

⇒ Repair: a `cell` stage that keeps the claim, disk, staged-binary and neighbouring-round-marker
checks — every one of which really can change during a 7-hour run — and drops only the fabric
check. `plan` was not usable for this: it returns early and would have dropped the other three too.
🔑 The fabric a cell measures on **is** checked, after the cell builds it: `bringup || abort`,
`assert_batch_took`, `assert_truncate_128`, `assert_running_arm`, `record_bmv2_identity`,
`assert_recompute_running`, `assert_same_boot`, `assert_topology_invariant`. The repair moves the
check from *before the teardown* to *after the bringup* — from the wrong object to the right one.

## F-15. 🔴 The bmv2 identity record was empty all round, and its own guard made that a pass

Two defects stacked, the second hidden inside the first.

1. **The same 14-vs-15 comm mistake, in a second file.** `lib_e.sh:510` matched
   `$2=="simple_switch_"` — exact equality on 14 characters, against a comm the kernel truncates
   to 15 (`simple_switch_g`). It matched nothing, so every `identity_bmv2_*.txt` this round wrote
   contained no `running pid=` lines at all and the transcript said `bmv2: 0 running switch(es)`.
   🔑 **I repaired `cpu_gate.py`'s copy of this bug at 21:54 and did not grep for others.** The
   fix was applied where the failure was *observed* rather than everywhere the *pattern* occurred.
   The other two exact-comm matches in the file (`iperf3` :287, `ndtwin_kernel` :417) are 6 and 13
   characters — checked, not assumed.
   ⇒ **Rule: fixing one instance obliges you to grep the class immediately** — here, every site
   that compares a `comm`. The grep costs seconds; it is the only thing that distinguishes "I fixed
   the bug" from "I fixed the one I tripped over".
   🔴 **Counted properly, tonight is occurrences three and four.** The project's ledger already
   held two before today (pgrep's 15-char comm in the power-on round is the one with its own
   memory entry); tonight adds `cpu_gate.py` at 21:54 and this site. **Every one of the four sat
   next to a comment that already said the name was truncated. Knowing about the truncation has
   never once been enough; only counting the characters has.**
2. **`if (( n > 0 && d != 1 ))` turned an empty read into a pass.** The guard against a mixed
   fabric was itself guarded by "if we found anything", so the state where we found *nothing*
   sailed through. **The clause protecting the check was the clause that made it vacuous.**
3. **A third defect was sitting inside the block that never ran**: `sudo -n readlink` and
   `sudo -n sha256sum` are not in this machine's NOPASSWD list, so both returned empty and every
   `sha256=` field was blank. `mnexec` *is* passwordless and is now the privileged reader.
   🔑 Fixing (1) is what made (3) observable at all — a defect inside dead code is invisible until
   the code stops being dead.
4. **"0 distinct" and "2 distinct" now have different messages.** The old text reported a reader
   that could read nothing as "the ten switches are not all running the same binary", pointing the
   next reader at the fabric when the fault was in this function's own privileges — F-2's shape, a
   sixth time.

**Evidence, both directions, live**: fabric down → `bmv2: 0 running switch(es)` → `ABORT(§4 bmv2)`
rc=9 (23:11:26); fabric up → `bmv2: 10 running switch(es), 1 distinct binary/binaries` (23:15:57),
and every ladder cell since records the same.

---

## F-16. ✅ F-9a's second half: the night's second foreign load landed *inside* a cell, and was caught

**F-9a and F-16 are one finding in two halves and should be read together** — F-9a is the failure
mode stated, F-16 is the same night providing the contrast case eight minutes later.

The first ladder cell aborted at 23:22:32, 270 s into its window:

```
cell CPU gate: RED excess=0.638   (threshold 0.5)
foreign  pid=2698465  comm=rev  cores=0.999
mine     ndtwin_kernel 0.577 · simple_switch_g 0.549/0.517/0.453 · python 0.069
```

Attribution, walked up `ps -o ppid` to the owning process, then read that process's own argv:

```
/bin/bash -c … eval 'sed -n '171p' …/NSLAB-USAGE-RULES.md | rev | cut -c1-140 | rev'
  ← claude pid 1503442
     /proc/1503442/cmdline → --resume=46992009-fcf0-4ceb-955d-f16e090060c5   (re-read 23:56, still live)
     = session `開機手冊`
```

🔴 **The pid and the transcript id above are right. The reason first given for them was not, and
the session named from that reason was the wrong one.** The original basis was *"that transcript
mentions `NSLAB-USAGE-RULES.md` 67 times, so it is the remote-machine line"*. `遠端機器測試`
refuted it with its own count: **382 mentions in their transcript — more than five times as many**
— because four lines were reading and writing that file tonight.
⇒ **On a shared object, attribution by content frequency is not merely error-prone; it is the wrong
kind of evidence, and it fails persuasively.** The right evidence was one `tr` away: a process
carries its own session id in argv. **Hard identifier over content feature, always.**

✅ **Re-identified twice, from unrelated channels, the second carrying the control the first
lacked.** Besides the argv above, the session registry's `lastActivityAt` for `開機手冊` and the
mtime of `46992009-….jsonl` agree to **79 ms**, while every other live session matches its own
transcript and none cross-matches:

| session | registry lastActivityAt | transcript mtime | Δ |
|---|---|---|---|
| **`開機手冊`** | 23:55:41.791 | `46992009-…` 23:55:41.870 | **79 ms** |
| `bmv2 論文審查` | 23:57:36.682 | `034fd7dd-…` 23:57:36.782 | 100 ms |
| `遠端機器測試` | 23:52:23.925 | `103a1748-…` 23:52:20.767 | 3.2 s |

Two chains rather than one **because the first attribution was wrong and was one step away from
being relayed to a third party.**

A `rev` reading **one line of text** was in state `R` with elapsed 14:15 and CPU time 14:15 — 100%
spinning, not blocked. Stopped with `kill <PID>` (by pid, never `pkill -f`), one signal. Leg 1
restarted 23:26:01; the failed transcript is kept as
`run_e.leg1.attempt1-foreign-load.stdout.log`.

⚠️ **The hang was deliberately not reproduced.** Reproducing it means spinning a core for another
14 minutes inside the exclusive window that runs to 09:37 — **the cost of establishing why is
exactly the thing the window exists to prevent.** It stays recorded as observed-once /
not-reproduced, and the replacement idiom (`sed -E 's/.*(.{140})$/\1/'`) is recommended on cost
asymmetry, not on a proven mechanism. Characterising it belongs after the window closes, or on a
machine that is not under claim.

⚠️ **Third instance this round of the F-3a / F-10 shape: the answer came out right and the stated
justification had no discriminating power.** Nothing about "67 mentions" would have read differently
had any of the other three lines been the culprit. What discriminates is a *candidate-unique*
signature carrying a control — `遠端機器測試` supplied one: a phrase sent only to `開機手冊` appears
**2** times in `46992009`, a phrase sent only to the auditor appears **0**. Without the second half,
the first is just "it occurs".

🔑 **A transcript grep cannot separate an executed command from quoted command text.** Checking
their own side, `遠端機器測試` got three `rev` hits — **all three were the commands they had just
run to investigate this**, whose text contains `'| rev'`. The instrument wrote its own actions into
the population it was measuring; only parsing the `tool_use` records tells the two apart.
(`instrument-must-not-mimic-its-own-finding`)

🔑 **This is F-9a's asymmetry paying out within eight minutes of being written down.** Two foreign
loads tonight, both ~1 core, on a machine under an exclusive-CPU claim:

| | when | where it landed | did the round see it? |
|---|---|---|---|
| iperf3, 48 s (F-9) | 22:10:10 | **between** gate samples, after the run had stopped | no — and it could not have, the gate watched 3.1% of that phase |
| stuck `rev`, 14 min | 23:08–23:22 | **inside a cell**, continuously sampled at 2 Hz | **yes — red at 270 s, round stopped** |

⇒ **The protection that worked is the one that samples continuously over the thing being claimed.
The one that failed measures the same quantity, at moments chosen by the gate's own schedule.**
⇒ Neither incident involved anyone ignoring the claim on purpose: the first party read the claim
late, the second leaked a hung utility they had no reason to think was still running. **The most
common threat to an exclusive-CPU window is a leaked process** — the same shape as this round's own
leaked burner (F-3.2).
🔴 **"Most common", not "real".** The accidental case is the frequent one, but its frequency says
nothing about the deliberate one, and **an accidental case systematically understates how bad the
deliberate case is** (`accidental-case-understates-deliberate-case`). The argument for continuous
accounting holds for both and does not need everyone to be well-intentioned: a schedule-driven
sampler is evadable *by construction*, whether or not anyone is trying.

## F-17. 🔴 Renewing the lab claim silently drops `exclusive_cpu`

`ndt claim <min> "<note>"` reads `NDT_EXCLUSIVE_CPU` from the environment. Renewing from a shell
that has not sourced `round.env` therefore **re-writes the claim without the exclusive flag** and
reports success:

```
22:47  ndt claim 660 "…"                       →  ok  lab claimed …
       ndt status → exclusive cpu  no (heavy local jobs may overlap this claim)
22:48  NDT_EXCLUSIVE_CPU=1 ndt claim 660 "…"   →  exclusive cpu  yes … holding
```

For about 60 seconds `ndt status` was telling every other session on this machine that heavy local
jobs were welcome — **an invitation, printed by the very tool whose job is to prevent the thing**,
in the middle of a 7-hour exclusive window.

🔑 Two properties make this worse than an ordinary flag default:
* **It fails toward silently weakened protection.** The renewal succeeds, the claim still exists,
  the owner is still right; only the one field that does the protecting is gone.
* **The action that triggers it is the safety action.** Renewing early to avoid mid-measurement
  expiry — exactly what the round was told to do — is what drops the flag.

⇒ This is a **tool defect, not an operator slip**: a renewal should default to preserving the
existing claim's fields, and downgrading a live claim's protection should require saying so.
⇒ Candidate for `KNOWN-ISSUES`; the auditor is collecting tonight's gate defects under their task
#5 and this goes in with them.
⇒ Workaround until then: renew only from a shell that has sourced `round.env`, and **read
`ndt status` back afterwards** — the renewal's own output does not show the flag.

---

## F-18. 🔴 E-P4's own guard makes it fail open — F-15's shape, second instance tonight

The frozen stop rule at `run_e.sh:181-193` compares an `m`/`mp` cell against its batching-off
partner at the same rung and rep:

```bash
pv=$(grep -m1 "^$partner	" "$RESULTS" 2>/dev/null || true)
if [[ -n "$pv" && "$pv" != *SATURATED* && "$v" == *SATURATED* ]]; then
```

`$RESULTS` is sound: fixed path, single write site (`:172`), append-only, never truncated by
`ladder()` or `plan()` — leg 1's rows do survive into leg 2, so the lookup is live **when the rows
exist**.

🔴 **But `-n "$pv"` is the hole.** Leg 2's four rungs (1/32, 1/16, 1/8, 1/4) are leg 1's rungs 4–7.
If leg 1 stops early, the missing partner rows make the condition false and **a frozen safety rule
silently stops applying to those rungs.** It prints nothing. The round would continue, and the one
check that distinguishes "batching implementation bug" from "the ceiling moved" would be absent
exactly where a bug is most likely — the low rungs, on batching's first live cells of the night.

🔑 **Same shape as F-15's `n > 0 &&`: the clause added to make the check safe is the clause that
makes it vacuous.** Second instance tonight, in a *frozen* rule this time.

⚠️ **Not repaired in-round.** Changing the instrument mid-round is worse than the hole; registered
for the next round. The in-round mitigation is a precondition outside the script, ruled by the
auditor as three branches, none of which lets leg 2 start with a hollow rule:

| leg 1 state | partner rows | action |
|---|---|---|
| no `ladder complete` (abort or stop) | any | 🔴 **do not start; report.** `abort()` says "the round stops here" — **no follow-on action is safe until the reason for stopping is understood**, including running only the rungs that do have partners |
| `ladder complete` printed | **all 24** | start leg 2 |
| `ladder complete` printed | any missing | 🔴 **do not start; report.** That is a leg 1 defect and must be understood first |

🔑 **Why the row count and not the banner.** `ladder complete` is a *proxy*; the partner rows are
the object the rule actually reads. The proxy lies in one direction — leg 1 can print the banner
with a cell missing from the tsv — and it lies toward "go".

---

## F-19. 🔴 The round's own operators are a measurable term in its contamination gate

Cell CPU-gate margins over leg 1's first 19 cells (`excess`, threshold +0.5):

| period | excess | `claude-desktop` | `gnome-shell` | `chrome` |
|---|---|---|---|---|
| 23:32–00:04 | −0.417 … −0.533 | 0.007–0.164 | 0–0.068 | 0–0.008 |
| 00:11–01:02 | **−0.541 … −0.609** | 0–0.024 | 0–0.005 | 0–0.006 |
| 01:09 | −0.130 | **0.305** | 0.087 | 0.005 |
| 01:15 | −0.020 | **0.368** | 0.114 | 0 |
| 01:21 | **+0.138** | 0.243 | 0.104 | **0.300** |

**Quietest and noisiest are twenty minutes apart and differ by 0.75 cores.** This is F-13b's claim
instantiated: a single reading cannot characterise the same quantity in another period, and
§0-ter's registered range check is built from short-term jitter.
🔴 **Not to be averaged.** Averaging a bimodal quantity reports a middle value that never occurred.

🔑 **The mechanism is specific and the magnitude is measured: the desktop is rendering the output
of the sessions running and auditing this round.** `claude-desktop` + `gnome-shell` reached ≈0.35
cores — **70% of the 0.5-core threshold**. Both parties have disclosed their share: this session's
long reports, and the auditor's status queries, long reply and an interactive form during
01:09–01:21.

⇒ **This is a declared covariate, not environmental noise, and it must not be written as noise.**
§0-ter declares the working point as "desktop not closed", so it is inside the declared working
point — but it still reds cells, and a red cell aborts the round, which **directly opens F-18's
hole** by truncating leg 1 before the partner rows exist. The two findings are one causal chain.

⇒ Both sessions have cut output for the remainder of the round. Recorded because the mitigation is
behavioural and therefore expires silently.

🔑 First instance with numbers of `vm-on-this-machine-is-invisible-to-ndt-status`'s third source —
"the claude session itself". The existing entry measured `agy`; the mechanism here is different.

---

## F-20. 🔴 A `pkill -f` inside the reused instrument makes a *string* hazardous for the round

`lib_e.sh:271`'s comment records that `measure.sh` — reused **byte-identical** so that this round's
cells stay comparable with the D round's (`round.env:16-22`) — clears stale servers with
`pkill -f iperf3`, and notes that mininet hosts share the root PID namespace "which is why a plain
pkill reaches them at all".

`pkill -f` matches the **full command line**. The Bash tool's own process carries its script text in
its command line. Therefore, for as long as this round runs, **any command containing the literal
string `iperf3` is a target of the instrument's own cleanup** — grepping for it, tailing a file
named after it, opening an editor on it. The process killed is the one that mentioned the string,
not a stale server.

⚠️ **Not repaired in-round**: `measure.sh` must stay byte-identical or §6's cross-round
comparability is void. Registered for the next round.
⇒ In-round mitigation is a naming discipline, not a code change: **no command line may contain
`iperf3` until leg 2's `restore_production` completes.** Verified for both parties' running
monitors at 01:34.
🔑 This is the seventh time this project has been bitten by `pkill -f`, and the first where the
hazard is **a string rather than an action** — nothing is being killed on purpose, and the victim
is chosen by what it happens to mention.

### The same defect in the tools written tonight to investigate it, and the durable repair

Both sessions hit it while checking for it. The `/proc/*/cmdline` enumeration written here to find
qemu processes **listed its own shell**, because that shell's command line contained the string.
The auditor's equivalent survived only by accident: it used a *prefix* test (`case "$c" in
qemu-system*`) and a shell's command line begins `bash -c`. **A substring test would have matched;
the anchoring was not a decision.**

⇒ The durable repair is two things together, and neither alone is enough:
* **Discriminate on `/proc/<pid>/exe`, not on `argv`/`comm`** — a process cannot set its own `exe`,
  and `遠端機器測試`'s fixtures prove `argv[0]` is freely forgeable (six stand-ins whose `argv[0]`
  is literally `qemu-system-x86_64`).
* **Anchor the match** — prefix or exact, never substring.

🔴 **"Be careful next time" does not repair this.** `ps | grep` always matches itself is already a
recorded lesson in this project, and it recurred twice tonight in tools written by people who had
just read it. Same family as `_is_fabric()`'s `comm.startswith()` including `iperf3` (F-21 hole 3):
**one string kills whatever mentions it and absolves whatever mentions it.** Registered together.

---

## F-21. 🔴 CORRECTED — the gate's blind spot is not an allow-list. It is three narrower holes,
## and one of them swallows exactly the load shape that was hardest to see

**The first version of this finding was wrong and is withdrawn.** It claimed the gate scopes its
population from a four-name allow-list (`claude-desktop`, `claude`, `gnome-shell`, `chrome`) and is
therefore blind to anything unnamed. **That is false.** `cpu_gate.py:167-190` walks *every* pid in
`/proc`, splits it into `mine`/`foreign`, and reports `foreign_cores` as the sum over **all**
foreign pids. The four names are a **rollup for the log line only**; the per-cell JSON keeps a
per-pid list. The evidence was in the round's own files the whole time: across 23 cell records the
recorded foreign comms include `agy`, `Discord`, `pulsesecure`, `kworker/u56:2-i915` and `rev` —
none of them on that list.

🔑 **I made the mistake this finding is about.** I read the *log line*, inferred the *scope*, and
stated it as a structural property — without opening `raw/cell_cpu/*_gate.jsonl`, which is one
directory away and answers the question directly.

### What is actually wrong — three holes, in order of how much they matter

1. 🔴 **`if pid not in a: continue` (`:176`) — a process that starts mid-window is dropped from the
   aggregate, not merely from the itemisation.** The gate takes a `/proc` snapshot, sleeps, snapshots
   again, and can only difference pids present in *both*. Its own comment says why: *"started
   mid-window: no baseline, cannot attribute."* The consequence is that **dozens of short-lived
   `bash`/`awk`/`sed` and repeated `qemu-img` invocations — precisely band A's described shape —
   never enter `foreign_cores` at all.** A cell contaminated entirely by short-lived processes reads
   identically to a quiet one.
2. 🔴 **`cores <= 0.005` (`:182`)** — many small processes, each under the cut, vanish from both the
   list and the total. Compounds hole 1 for the same load shape.
3. ⚠️ **`_is_fabric()` (`:163`) is a `comm.startswith()` test**, and `FABRIC_PREFIXES` includes
   **`iperf3`**. A *foreign* process whose comm starts with a fabric prefix is counted as **mine** and
   leaves the foreign accounting entirely.
   🔑 **Symmetric with F-20, on the same string**: `measure.sh`'s `pkill -f iperf3` *kills* whatever
   mentions it; the gate's prefix test *absolves* whatever mentions it. One string, two opposite
   failures, neither requiring anyone to be careless. (The pid-in-manifest tightening for
   `FORCE_CPU_GATE_DISOWN_FABRIC` is already a registered deferral; this is its second reason.)

### 🔴 Hole 1 is *lifetime blindness*, and it is orthogonal to the detection floor

The two limits are different axes and the report must state **both** wherever it says a gate was
GREEN:

| limit | axis | what escapes |
|---|---|---|
| effective detection floor ≈0.95 cores (F-13a) | **magnitude** | anything small enough |
| lifetime blindness (`:176`) | **time** | **anything that starts inside the window — at any size** |

⇒ Stating only the floor invites the reading *"then a big enough load would have been caught"*.
**It would not.** A 4-core burst that starts and ends inside the window contributes zero to
`foreign_cores`. And `遠端機器測試` has since described its load precisely: **dozens of short-lived
`bash`/`awk`/`sed`, repeated `qemu-img`, and two python socket servers, each 20–40 s** — *entirely*
inside the class hole 1 removes. **That is not the gate judging wrongly; it is the gate structurally
unable to see.**

#### 🔴 REQUIRED WORDING — three sentences, none optional, wherever this round reports a green gate

1. **Magnitude floor.** The effective detection floor is **≈0.95 cores of excess** (baseline + 0.5),
   not the nominal 0.5.
2. **Lifetime blindness.** A process that starts and ends inside the window contributes **zero at
   any size** (`cpu_gate.py:176`).
3. 🔴 **Not retrospectively quantifiable.** `excluded_midwindow` **does not exist for any completed
   cell and cannot be reconstructed** — the per-sample snapshots were not retained. **The report
   must say the quantity was not recorded.** A blank here reads as zero.

⚠️ The third sentence is the one that changes the meaning of the first two (auditor). On their own
they describe *what the gate cannot see*, which a reader will size up as a bounded known error.
**Together with the third they describe a gap whose magnitude is also unknown.**

🔴 **No in-round repair, and the reason is stronger than for F-18 or F-20.** `excluded_midwindow`
would be a **new measurement**: added now, cells 1–24 lack it and 25–48 carry it, so **the two
halves of one ladder would be measured with different instruments — and this round's claim is
precisely the comparison across rungs.** Those two findings are "leave a defect in place"; this one
would be "make the completed half incomparable". Text-only disclosure in-round; repair registered
for the next.

### 🔑 The code is more honest than its use

`:177`'s comment reads `no baseline, cannot attribute`. **`cpu_gate.py` never claimed those
processes were counted.** The defect is not on that line — it is downstream, where `foreign_cores`
is consumed as if it were a total, by a reader who has not read line 177 (`遠端機器測試`).

> **A quantity that honestly annotates its own limit, used as though it had none. The annotation
> stays where it was written; the use happens somewhere else.**

⇒ Repair shape, and it generalises past this gate: **carry the bound inside the value.** Return
`foreign_cores_attributable` rather than `foreign_cores`, and emit `excluded_midwindow=N` beside
it. Otherwise the limit lives only in the heads of people who have read the source, and every
consumer re-derives it or does not.

### What the round's own continuous records do and do not establish

Computed here from `raw/cell_cpu/*_gate.jsonl` — same machine, continuous, 270 s windows:

* The itemisation is truncated at `foreign[:10]` (jsonl) and `foreign[:15]` (baseline json), but
  **`foreign_cores` is summed before truncation**, so the difference is a usable residual.
* That residual — foreign load seen in the aggregate but not itemised — **peaks at 0.132 cores**
  (`e_p_0064_3`) and sits at or below 0.06 in 20 of 23 records.
* **No `qemu`, `qemu-img`, `bash`, `awk`, `sed` or foreign `python` comm appears in any cell.**

⇒ **This bounds one part of the question and names the part it cannot bound.** Within each cell
window, itemised foreign load was ordinary desktop processes and unlisted-but-counted load was
≤0.132 cores. **It says nothing about processes that started and ended inside the window**, which
hole 1 removes upstream of the total — and that is the category band A consisted of.

### Repair shape, registered for the next round

Keep the `/proc` population (it is already right) and close the three holes:
1. **Account for mid-window starts** rather than skipping them — attribute from process start via
   `/proc/<pid>/stat` field 22, and where that is impossible, **emit an explicit
   `UNACCOUNTED-SHORT-LIVED` count that can make the cell suspect.** A skipped process must not
   print the same as no process.
2. **Report the residual** (`foreign_cores − Σ itemised`) as a field, not as something a reader has
   to subtract.
3. **Discriminate `mine` by pid membership in the fabric manifest**, with comm prefix as a
   cross-check only — never as the sole test.

Three companions, from `遠端機器測試`, each paid for tonight:
* 🔴 An "unattributed" signal must be able to **make the cell suspect**, not merely log a line.
* 🔑 Its control is the same shape: a parser matching *nothing* prints "zero unattributed"
  identically to one that attributed everything ⇒ one case must assert it can see a process known
  to exist. (F-3a's rule: the green half needs discriminating power too.)
* ⚠️ **Fixtures must include a form the program itself would never emit** — their first three
  stand-ins were written in their own format, so everything passed.

`遠端機器測試` has committed a rewritten `tools/remote-lab/host_witness.sh` (`beb45fc`) that carries
`host=` on every line, discriminates via `/proc/<pid>/exe` instead of argv, and is three-state
rather than two. Available to the next round; its `--self-test` is pure and runs inside an
exclusive window.

⚠️ **Not repaired in-round** — same reason as F-18 and F-20: it would void the comparability of the
cells already measured.

🔴 **Registered decision point — leg 2's start, not now.** An out-of-band `/proc` accountant that
*does* handle mid-window starts touches neither the round's instrument nor its decision rules, and
leg 2 begins from a fresh launcher. Against it: it adds load to the window whose margin is the
binding risk (F-19), and **a runaway sampler is precisely the failure that already cost this round a
cell** (F-16). ⇒ Auditor's call, with the leg-1 completion report; if taken it must **declare and
measure its own CPU cost** rather than assert it is negligible.

---

## F-22. 🔴 Four times in one night, across three sessions: a summary was read to answer a
## question only the source could answer

Each of these was made by someone who had, the same night, told someone else to go back to the
source. None was careless in the ordinary sense; each is a summary being used as a field.

| # | who | the summary read | the question it was used to answer | what it actually cost |
|---|---|---|---|---|
| 1 | mainDev | the `covariates:` **log line** (4-name rollup) | *what population does the gate measure?* | F-21 v1, wrong, published |
| 2 | auditor | the **filename** `host_witness_*.log` | *which machine is this about?* | band C: a withdrawal, a rewrite and two onward relays |
| 3 | mainDev | `ls … \| head -5` | *what is in this directory?* | told the auditor they had cited the wrong path; they had not |
| 4 | 遠端機器測試 | **mainDev's description** of its own instrument | *how does that instrument scope itself?* | the "sixth layer", built and returned as a finding |

🔑 **The common shape: a summary is lossy, and the way it is lossy is not written in the summary.**
A rollup does not say which processes it dropped; a filename does not say which host; `head -5`
does not say that `cal*` sorts before `e_*`; a colleague's description does not say which parts
they inferred. In every case the source was one command away.

⇒ **Operational form**: *"are these numbers real"* and *"what are they about"* are different
questions, and **only the first one has an obvious place to look.** The second needs the source.

### The specific trap in #2 and #3: a container's name claims what its contents do not promise

`doc/audit/2026-08-20_sampling-rate-and-cpu/raw/` holds **both** the 08-20 round's calibration files
**and 101 of this round's live cell files** — `e_p_1024_3_cpu.jsonl`, mtime `Sep 1 00:04`, three
seconds before that cell's VERDICT. This is by design and documented: `round.env:16-22` records that
the 08-20 round owns `measure.sh` *and the raw directory it hardcodes*, that neither may be copied
or edited because PREREG §6's comparability rests on identical bytes, and that **"cells land in
PRIOR_RAW first and are COPIED here afterwards"**.

⇒ **"Which round does this directory belong to" has two answers: the name says one, the contents
span two.** Third instance tonight of a container name being used as a field (`host_witness` was
the first, `raw/` the second).
⇒ **Criterion: mtime + naming rule + the pids inside the file — all three.** Directory membership
is not evidence of provenance.
⚠️ And #3's mechanism is already a recorded lesson in this project — **`| head -N` gives an
incomplete answer** — committed *while investigating* whether someone else's citation was wrong.

### One that cost nothing, and why

`遠端機器測試` checked before retracting #4 and found it had **reached no durable artefact**
(`grep -rn` across `doc/`, `tools/` and the memory directory: zero hits) — it existed only in one
message. **A wrong finding that never landed has no citation points to repair.** The others each
required chasing readers: band C alone produced a withdrawal, a code rewrite, a reinstatement and
four cross-session corrections. 🔑 **Cost is not proportional to how wrong a claim was — it is
proportional to how far it travelled before being checked.**

⇒ Adopted by the auditor as a process change: **the more destructive a cross-session instruction,
the higher the evidence bar before sending it** — and "go retract a conclusion you already hold" is
the most expensive cell in that table. Band C was not expensive because it was wildly wrong (three
of its four counter-checks were runnable on the spot); it was expensive because **instructions went
out before the checks came back.**

---

## F-23. 🔴 A quantity that honestly declares its own limit, consumed as if it had none

`cpu_gate.py:177` reads, verbatim: `# started mid-window: no baseline, cannot attribute`. **The gate
never claimed those processes were counted.** The defect is not on that line and not in that file —
it is wherever `foreign_cores` is read as *the* foreign total, by a reader who has not read line 177.

> **The annotation stays where it was written. The use happens somewhere else.**

🔑 **This is why code review does not catch it.** Any review scoped to `cpu_gate.py` correctly
reports that the function is honest, documented and behaving as described — because *in place*, it
is. The defect exists only in the join between a correctly-annotated producer and a consumer that
never saw the annotation. **A per-file review cannot see a defect that lives between files.**

### The repair generalises: a value must carry its own scope, because names travel and comments do not

Rename the thing to what it actually is — `foreign_cores_attributable`, not `foreign_cores` — and
emit the exclusion count beside it. A caller cannot use `foreign_cores_attributable` as a total
without noticing; a caller can use `foreign_cores` as a total forever.

**Third face of a rule this project has now hit three ways:**

| instance | the artefact | the scope it must carry |
|---|---|---|
| `benchmark-must-name-the-binary-it-measured` | a timing number | *which binary produced it* |
| tonight's witness logs (band C) | a sample series | *which host it was taken on* |
| **this** | a CPU figure | *which processes it could account for* |

⇒ **An artefact must carry its own scope declaration.** Documentation of scope is not a substitute:
the artefact gets copied, quoted, tabulated and cross-referenced, and **the scope has to survive
every one of those moves.** A comment survives none of them.

---

## F-24. 🔴 The abort destroyed the only record of why it aborted — and the branch that would
## have preserved it is wired to the case that does not need it

Leg 1 aborted at **02:10:58** on cell `e_p_0016_1`, 25 of 48 cells in:

```
topo session started (attach: sudo tmux -L ndtwinlab attach -t topo)
[02:10:58]     fabric short of 10          ← 200 seconds in between.  No error. No output at all.
[02:10:58] 🔴 ABORT(bringup): e_p_0016_1: the fabric would not come up
```

`bringup` (`lib_e.sh:603-604`) polls 40 × 5 s for `bmv2: 10` and returns 1 on timeout. **`fabric
short of 10` is the symptom the poller can see, not the reason.** `stack up.` never printed, so the
failure was at the *topology* stage — before the kernel and proxy stage — and `$LAB topo-start`
returns as soon as it has started a tmux session. **Everything the topology says about its own
startup goes to that tmux pane. None of it reaches `$LOG`.**

Then `abort()` ran `restore_production` → `teardown` → the tmux session is gone.

> 🔴 **The cleanup that destroyed the evidence is the correct action.** It put the production
> kernel, the P4 constants and the compiled artefact back, verified them, and left the lab safe to
> hand over. Nothing here is "the wrong thing happened" — **it is two correct actions in the wrong
> order.**

Two independent barriers, either of which alone would have been fatal: the session was destroyed,
**and** `sudo -n tmux` is not passwordless on this machine, so this session could not have read the
pane even had it survived.

### 🔑 The mechanism to preserve the scene already exists, and is attached to the wrong case

`abort()` (`lib_e.sh:72-77`):

```bash
if [[ -n "${FORCED_ABORT:-}" ]]; then
    say "🔴 (FORCED_ABORT set: this abort is an injected test; the production restore is NOT
    say "🔴  run, and the fabric is left standing for the gates that follow.)"
else
    restore_production || say "🔴 and the production restore ALSO failed -- check before release"
fi
```

**An *injected* abort leaves the scene standing. A *real* abort tears it down.** That is exactly
inverted: an injected abort's cause is known by construction — it was chosen — while a real abort's
cause is the entire reason anyone is looking. The flag was added for a good reason (F-12: forced
aborts were tearing down live fabrics during gate tests) and it accidentally created the right
behaviour for the wrong half of the population.

### Why the contamination questions were answerable and this one is not

The CPU gate writes per-cell JSON to `raw/cell_cpu/` **as it goes**, which is the only reason the
foreign-load questions could be settled hours later from same-machine data. `bringup` writes
nothing but a one-line verdict. ⇒ **Continuous accounting to disk is not a nicety of the CPU gate;
it is the difference between a question that can be answered after the fact and one that cannot.**

### Repair, registered for the next round (not in-round — the run has ended, but the rule stands)

1. **Capture the pane before teardown**: `tmux -L ndtwinlab capture-pane -p -S - -t topo` into the
   round directory, in `abort()` *before* `restore_production`, and on the bringup timeout path.
2. **Or remove the dependency**: have `topo-start` tee to a file, so the reason exists on disk
   whether or not anyone thinks to capture it.
3. **Invert the `FORCED_ABORT` asymmetry** — or rather, split it: a real abort should preserve
   *diagnostics* while still restoring *production state*. Those are not in conflict; the current
   code just does not separate them.

⚠️ **In-round consequence, stated plainly: this failure has a symptom and no mechanism.** No
resource cause was found — disk 9.4 G, `load1` 0.14, zero orphan bmv2/veth/netns, 25 successful
bringups immediately before. Any decision about resuming has to be taken **without knowing why the
26th bringup failed**, and that limitation is a consequence of this finding, not an aside to it.
