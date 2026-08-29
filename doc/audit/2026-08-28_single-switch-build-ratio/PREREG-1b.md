# PREREG — ①b: rerun of ① with a ladder whose top is decided by a rule

**Registered 2026-08-29 10:55 +0800 by `8/28 mainDev`, ordered by `8/28 auditor`. Zero packets.**

**This is a new round, not an amendment to ①.** `PREREG.md` and `FINDINGS.md` for ① stand exactly
as they are and are **not** superseded. The paper should carry both: *the first instrument could
not reach the answer, we said so, and this is the rerun whose ladder length is decided by the stop
rule.* That is more persuasive than having got it right first time, and we caught it ourselves.

---

## 1. Why a rerun is legitimate here when it was forbidden in ③

`8/28 auditor` ruled during ③ that **lengthening an instrument because the result is unwelcome is
the opposite of the discipline this work argues for.** That ruling stands. This round is a
different case, and the distinction is the whole justification:

| | ③'s n=1 | **①'s fast side** |
|---|---|---|
| Does the surviving claim need that ceiling? | ❌ No — the per-flow curve measured five cells on one scale, internally consistent | ✅ **Yes** — the entire question is a ratio R; there is no framing that avoids it |
| Extending the ladder would | **rescue a ratio that was already withdrawn** | **let the instrument reach the registered quantity** |
| Knowing this in advance, would the design have been different? | ❌ No, the ladder was adequate for the claim | ✅ **Yes, obviously** — the top was never checked against the fast build at all |

⇒ **③ was "change the instrument because you dislike the answer". ①b is "the instrument does not
reach the registered question". The first is forbidden; the second is a bug fix.**

The root cause is on record in ①'s FINDINGS §1.1: §3 built that ladder by extending ③'s **downward**
to reach stock's expected ~25 Mbps, and **nobody asked whether the top still covered the fast build
once two hops were removed. The ladder was checked against the slow arm only.**

## 2. 🔴 The directional hazard, and the design that removes it

**Lengthening the ladder can only move R upward** (360 was a lower bound) ⇒ toward H1/H3 ⇒ toward
*"this build really is ~12× faster"*, which is the more publishable direction. This is exactly the
failure direction this project keeps finding in its own work.

**The ladder therefore has no fixed top, and no person chooses where it ends.**

> Rungs are ①'s **registered** ladder verbatim — `1 2 3 5 8 12 20 30 45 70 110 160 240 360` — and
> then continue **×1.5, rounded to two significant figures** (540, 810, 1200, 1800, 2700, …),
> climbing until the **already-registered saturation stop fires**: two consecutive rungs above
> 25% loss. **Where the ladder ends is decided by loss, not by a number anyone picked.**

Each arm records the rung it stopped at and why. A `RUNAWAY_MAX` of 40 rungs exists purely as a
bug backstop; **if it ever fires the arm says so loudly and its highest clean rung must not be read
as a saturation point.** Verified in isolation against a stub before any arm ran: the loop climbed
past the registered top to 540 and 810, and stopped at 1200 when the rule fired twice.

## 3. 🔴 The intervals are inherited verbatim and are NOT re-derived

| outcome | interval |
|---|---|
| **H1 — build property** | **R ∈ [9, 20]** |
| **H2 — partly the path** | **R < 9** |
| **H3 — path was capping fast** | **R > 20** |

**Identical to ① §4, deliberately.** Re-deriving intervals after seeing R ≥ 8 would be drawing the
target around the arrow, and is the most serious violation available in this design. The meaning of
each outcome is inherited unchanged, including the follow-up branch registered in ① AMENDMENT-1
§8.2: **if R lands in H2, "path or control plane" is a separate round and this one may not
attribute the shortfall to either.**

## 4. Design, inherited from ① except where stated

- **Four arms, interleaved `stock fast stock fast`**, one fabric generation each. **All four are
  re-run** — not just the fast pair. Topping up only the censored side would let fabric-generation
  drift align with build, which is the exact thing interleaving exists to prevent. Within-build
  spread in ① was zero, so the risk is low; that is a reason to do it properly, not to skip it.
- **The mirror (8 arms) runs only if budget allows.** If it does not, that is **disclosed as a
  deviation, not written up as the registered design** — same handling as ①.
- Everything else is ①'s: one hop h1→h2 verified by interface counters **on every fabric
  generation**, 1400 B payload, control plane live, build asserted by bidirectional `EventLogger`
  signature at every arm, kernel negative control `3367d0e9` recorded, `external` residual gate
  with its positive control **re-run per build, not inherited**.

## 5. 🔴 New control: the generator must be shown not to be the limit at the top rung actually reached

②'s sender-side control was measured at 64 B frames and cleared 770.7 kpps. **It does not transfer**:
this round runs 1400 B payloads at rungs that may exceed 1 Gbit/s, and a generator limit there
would masquerade as a bmv2 saturation point — the same shape as ②'s confounder, one axis over.

> **After the arms, a loopback run (h1→h1, not traversing bmv2) at the highest rung any arm
> actually reached must sustain at least that rate.** If it does not, the fast side is reported as
> **generator-limited**, an upper bound is disclosed, and no R is claimed.

Measured whichever way it comes out, and recorded before it is interpreted.

## 6. What must be reported regardless of outcome

- Both arms' stop rung and stop reason per build.
- R with its arithmetic shown, and **explicitly whether either side is censored**.
- If the fast side saturates this time and stock's 45 M reproduces, R is a measurement and one of
  H1/H2/H3 is decided. **If the fast side is still censored, the answer is again "cannot decide",
  and that must be reported as such rather than as the lower bound rounded up.**

**[Co-developed with claude code -- Adam]**
