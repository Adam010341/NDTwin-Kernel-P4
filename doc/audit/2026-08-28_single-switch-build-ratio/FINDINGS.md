# ① — is 12× a property of the build or of the path? **The registered ladder cannot answer.**

**Created 2026-08-29 by `8/28 mainDev`.** Design: `PREREG.md` §1–§7 + AMENDMENT-1 §8.
Instrument: `run_build_arm.sh`. Driver: `drive_p1.sh`. Raw → `audit-raw`.

Four arms, interleaved `stock fast stock fast`, 2026-08-29 10:11–10:28, one hop h1→h2 on s1,
1400 B payload, 128-host P4 topology **held identical across all four arms**, control plane live.

---

## 1. The result, and why it is not a verdict

| arm | build | highest clean | ladder | `external` | `EventLogger` | sha256 |
|---|---|---|---|---|---|---|
| stock_a | stock | **45 M** | truncated at 160 | 0.0654 | 24 | `327fa7d1` |
| stock_b | stock | **45 M** | truncated at 160 | 0.1028 | 24 | `327fa7d1` |
| fast_a | fast | **360 M** | 🔴 **not truncated** | 0.0510 | 0 | `3ff54b5c` |
| fast_b | fast | **360 M** | 🔴 **not truncated** | 0.0491 | 0 | `3ff54b5c` |

**Both builds reproduced exactly across their two arms — zero spread on either side.**

**R = 360 / 45 = 8.0.**

## 1.1 🔴 R is a LOWER BOUND, and the registered intervals cannot be decided

**360 M is the top rung of the registered ladder** (`… 160 240 360`, §3). Both fast arms were clean
there, and `ladder_truncated_at=not-truncated` means **neither ever reached the 25% saturation stop
— the ladder ran out before the fast build did.**

⇒ **The fast side is censored. R ≥ 8.0 is all this round measured.**

| registered outcome | interval | can this round decide it? |
|---|---|---|
| H1 — build property | R ∈ [9, 20] | ❌ |
| H2 — partly the path | R < 9 | ❌ |
| H3 — path was capping fast | R > 20 | ❌ |

**R = 8.0 read naively lands in H2. Reporting that would be wrong**, and wrong in the direction
that makes a more interesting claim — the numerator is not a measurement of the fast build's
zero-loss point, it is the largest number the instrument can emit. One more ×1.5 rung (540 M) would
give R = 12.0, squarely H1.

🔑 **This is the same failure ③ hit at n=1, in a worse place.** There the censored quantity was a
*secondary* one (the saturation ceiling) and the reported claim did not need it. **Here the
censored quantity IS the registered readout.**

📌 §3 chose the ladder by extending ③'s **downward** — "extended down to cover stock's expected
~25 Mbps region". Nobody asked whether the top still covered the fast build **once two hops were
removed**. 08-15 measured fast at 300 Mbps over *three* hops; on one hop it is ≥ 360.
**The ladder was checked against the slow arm and not against the fast one.**

## 1.2 What was NOT done about it

**The ladder was not extended.** Data for this round exists, so the first amendment condition (zero
packets) fails and no amendment is legal. Independently, `8/28 auditor` ruled during ③ that
extending an instrument because the result is unwelcome is the opposite of the discipline this work
argues for. **Rerunning ① with a longer ladder is a decision for the auditor, not this session.**

⇒ **Escalated, not resolved here.**

---

## 2. What this round did establish

1. **Both builds are internally reproducible at one hop**: 45/45 and 360/360, zero spread, each
   top rung re-confirmed at three reps (stock: 0.0000 ×3 both arms; fast: medians 0.1431 / 0.1610).
2. **The stock side is a real measurement, not a censored one** — both stock arms hit the 25%
   saturation stop at 160 M, so 45 M is bounded above by measured failure rather than by the
   instrument.
3. **A lower bound worth stating**: at one hop, with the control plane live, **bmv2-fast is at
   least 8× the stock build's UDP zero-loss point**. That is compatible with H1 and H3 and excludes
   nothing, but it is measured, replicated, and free of the path confound the round was built to
   remove.
4. **Both builds are faster at one hop than 08-15 reported at three** (stock 45 vs 25, fast ≥360 vs
   300). ⚠️ Directional only — different path length is exactly the variable under test, and 08-15
   is not a control for this round.

---

## 3. Controls, all run, all recorded

| control | result |
|---|---|
| **Kernel negative control** `3367d0e9` (`kFlowPathRecomputeInterval`) | **0 hits** ✅ — and `a40e04ce` gives 5, asserted at every arm |
| **bmv2 build signature**, both directions | `EventLogger` fast=0 / stock=24; a mislabelled arm **exits non-zero** (verified by running `stock` against the fast fabric) |
| **One hop**, re-verified on **every** fabric generation | exactly **2 interfaces on 1 switch** each time (`s1-eth3` RX, `s1-eth4` TX) |
| **Gate positive control, fast** | `external` 0.0464 → **0.2385** with 4 burners |
| **Gate positive control, stock** | `external` → **0.2584** with 4 burners — **re-run, not inherited**, because the binary changed |
| **Gate on the real arms** | median 0.0582, threshold 0.2082, **no arm fired** |

🔴 **§3's registered negative control could not test what this round identifies.** `3367d0e9` is an
`ndtwin_kernel` binary answering a *kernel* symbol; it cannot distinguish two *bmv2 builds*. It was
still run (it is a valid control for the kernel identity every arm meta carries), and a real
bidirectional bmv2 signature was added in AMENDMENT-1 §8.4. See that section.

⚠️ **Binary provenance is one notch below the best available.** `/proc/<pid>/exe` is unreadable by
this uid (switches run as root, no passwordless sudo for `readlink`), so the binary is resolved from
the process's argv and cross-checked against `bmv2_binary_override`, with the arm aborting if they
disagree. sha256 recorded per arm. AMENDMENT-1 §8.5.

---

## 4. Threats to validity

1. 🔴 **The fast side is censored** (§1.1). This is the round's dominant limitation.
2. 🔴 **The registered mirror pass was not run.** §3 registers `fast stock fast stock` **and then
   mirrored** = 8 arms. **4 arms ran**: `stock_a fast_a stock_b fast_b`, interleaved, two per build,
   no two same-build arms adjacent. The mirror was dropped because each arm needs its own fabric
   generation and the session's budget did not cover 8 restarts. **Disclosed rather than presented
   as the registered design.** Given zero within-build spread, a mirror would very likely have
   added nothing — but that is a guess, not a result.
3. **Two variables were deliberately left bound together.** §1's premise names "three-hop path
   **with a live control plane on it**" — two confounds. This round removed only the path; the
   control plane ran normally (AMENDMENT-1 §8.2), because changing both at once would make a
   shrunken R unattributable and because the paper's claim is about the build as deployed.
   **If a future round resolves R into H2, "path or control plane" is still open.**
4. **Single machine, single fabric, single host pair, single payload size.**

---

## 5. What this licenses

| ✅ supported | 🔴 not supported |
|---|---|
| At one hop, fast ≥ **8×** stock on the UDP zero-loss point, replicated | **Any of H1/H2/H3** — the ladder cannot decide between them |
| Stock's one-hop zero-loss point is **45 M**, bounded by measured saturation | That fast's one-hop point *is* 360 M — that is the instrument's ceiling |
| The two builds were correctly identified at every arm, by symbol, both directions | That 12× "survives isolation" — this round did not measure a point estimate |
| No arm was gated by foreign CPU, on a gate shown to fire on both builds | That the mirror pass would have agreed |

**[Co-developed with claude code -- Adam]**
