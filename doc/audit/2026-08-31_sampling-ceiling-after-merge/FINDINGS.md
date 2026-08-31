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
