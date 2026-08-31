# E round — findings and deliverables

Opened 2026-08-31 during the measurement window, by `8/31 mainDev`.
Findings below are from the **gate-bringup phase**; not one ladder cell has run yet.
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
2. **§0-ter's detection floor belongs in the caption**: this round only detects foreign load
   **above 0.5 cores over baseline**, and per Adam's 2026-08-31 ruling the run **crosses from
   night into day**, with a per-cell baseline measured for every cell. If the night/day boundary
   shows a real baseline shift, the figure must make clear which cells sit on which side.
   That shift is **a finding to report, not noise to average away**.
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
to give it any all failed (idle fabric / ping flood / ping ended early). What actually carries the
G5b conclusion is the natural experiment (21:24:19 vs 22:02:33, Δ≈1.43 cores = three switches
changing sides), not the injected green.
⇒ State the rule for both halves: **"if the thing I am testing had not happened, would I have got
this same answer?"** — asked of the *green* run as well as the red one.

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
🔴 **Partial coverage, stated rather than glossed**: `raw/G9-COVERAGE.txt` is not written under
`DRY_RUN=1`, so all three mutants exercised only the transcript channel. The live gates run
exercises the file's `BOTH` branch; the `HALF-COVERED` branch's *write* is covered only by
inference from sharing one `printf … >>"$f"` with it. Branch selection is proven, the file write
on that branch is not.
