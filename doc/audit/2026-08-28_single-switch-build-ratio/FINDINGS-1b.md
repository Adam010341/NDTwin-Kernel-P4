# ①b — R = 8.0, and this time both sides are measurements. **Registered outcome: H2.**

**Created 2026-08-29 by `8/28 mainDev`.** Design: `PREREG-1b.md`, which inherits ①'s `PREREG.md`
§1–§7 + AMENDMENT-1 §8 unchanged except for the ladder's top.
Instrument: `run_build_arm.sh` (`RATES_MBIT=AUTO`). Driver: `drive_p1.sh`. Raw → `audit-raw`.

Four arms, interleaved `stock fast stock fast`, 2026-08-29 10:39–10:57, one fabric generation each,
one hop h1→h2 on s1, 1400 B payload, control plane live.

**① is not superseded.** Its finding — that the first instrument could not reach its own question —
stands on its own and is the reason this round exists.

---

## 1. The result

| arm | build | highest clean | ladder stopped at | why it stopped | `external` |
|---|---|---|---|---|---|
| b_stock_a | stock | **45 M** | 160 M | saturation rule | 0.0377 |
| b_fast_a | fast | **360 M** | **810 M** | **saturation rule** | 0.0298 |
| b_stock_b | stock | **45 M** | 160 M | saturation rule | 0.0377 |
| b_fast_b | fast | **360 M** | **810 M** | **saturation rule** | 0.0152 |

🔑 **Every arm stopped because loss stopped it. No arm ran out of ladder.** That is the entire
difference from ①, where both fast arms were still clean at the ladder's last rung.

**R = 360 / 45 = 8.0**, and both sides are now bounded above by measured failure.

### The knee above 360 M is sharp and reproduced

| rung | b_fast_a | b_fast_b |
|---|---|---|
| 240 M | 0.0443% | 0.0700% |
| **360 M** | **0.1540%** | **0.3275%** |
| 540 M | **25.80%** | **26.62%** |
| 810 M | 46.40% | 44.84% |

⇒ 360 M is not a threshold artifact sitting on a plateau — the next ×1.5 rung costs **~170×** the
loss, in both arms independently. Contrast ③'s n=1, where the rung above the reported one cost only
3.5× and the number turned out to be a plateau position.

## 1.1 🔴 Registered outcome: **H2 — R < 9**

| outcome | interval | |
|---|---|---|
| H1 — build property | R ∈ [9, 20] | ✗ |
| **H2 — partly the path** | **R < 9** | ✅ **8.0** |
| H3 — path was capping fast | R > 20 | ✗ |

**Registered meaning, written before the number existed** (① §4, inherited verbatim by `PREREG-1b`
§3 and explicitly not re-derived):

> Part of the reported ratio came from the three-hop path and the live control plane on it, not
> from the compiler flags. **The main claim narrows to "12× along a three-hop production path", and
> the paper must say which.**

⚠️ **8.0 against a boundary of 9 is close.** The ladder's resolution is ×1.5, so the nearest
alternative values of the numerator are 240 (R = 5.3) and 540 (R = 12.0); the denominator's are 30
(R = 12.0) and 70 (R = 5.1). **A one-rung error on either side moves the verdict.** What supports
the call is not the margin but the replication: **six stock arms across ① and ①b all read 45, four
fast arms all read 360, with zero spread on either side.**

## 1.2 🔴 What this round may NOT say

Registered in ① AMENDMENT-1 §8.2 before any arm ran, because H2 was foreseeable:

> If R lands in H2, the next question is *path or control plane*, and that is **another round**.
> **This round may not attribute the shortfall to either.**

This round removed the path (three hops → one) and deliberately left the control plane running.
It therefore shows that **something outside the compiler flags contributed to the 12×** — it does
not say which of the two, and the arithmetic here cannot separate them.

---

## 2. 🔑 ①b did not change the number. It changed whether we were entitled to it.

① reported fast = 360 M. So does ①b. **The measurement never moved.**

What moved is its status: in ① the fast arms were clean at the ladder's top rung and had never met
the saturation rule, so 360 was *the largest value the instrument could emit*. In ①b the ladder
kept climbing — by rule, to 540 and 810 — and loss ended it. **The same number, once an artifact
and once a measurement.**

📌 This is why ① is kept rather than replaced. Had ① been quietly rerun with a longer ladder and
only the second result published, the record would show a clean 8.0 with no trace of the round that
could not have known it was clean.

⚠️ **And note the direction.** Lengthening the ladder could only move R **upward**, toward H1 and
the more publishable "the build really is ~12× faster". It did not move at all, and the verdict
landed on the **less** convenient outcome. The safeguard in `PREREG-1b` §2 — the ladder's top chosen
by the stop rule rather than by a person — was never actually load-bearing here, but that could not
have been known in advance, which is when it had to be decided.

---

## 3. Controls

| control | result |
|---|---|
| **Sender-side control** (`PREREG-1b` §5), loopback h1→h1 at 1400 B, not through bmv2 | **7902.3 Mbit/s** (7685.9 / 7902.3 / 7913.0) against the **810 M** highest rung any arm reached ⇒ ✅ **passes by 9.8×** |
| **Ladder top chosen by rule** | verified in isolation against a stub before any arm: climbed past the registered top to 540 and 810, stopped when the rule fired twice. `RUNAWAY_MAX` never fired in any arm |
| **One hop**, re-verified per fabric generation | exactly **2 interfaces on 1 switch** all four times |
| **Build signature**, both directions, every arm | `EventLogger` fast=0 (`3ff54b5c`) / stock=24 (`327fa7d1`) |
| **Kernel negative control** `3367d0e9` | 0 hits every arm; `a40e04ce` 5 hits |
| **`external` gate** | median 0.0337, threshold 0.1837, range 0.0152–0.0377 ⇒ **no arm fired**, on a gate whose positive control fired on **both** builds (0.2385 fast / 0.2584 stock) |

⚠️ The sender-side control is **not** inherited from ②: that one measured 64 B frames and 770.7 kpps,
which says nothing about 1400 B at 810 Mbit/s. Re-measured here for that reason.

---

## 4. Threats to validity

1. 🔴 **R = 8.0 sits one ladder rung from the H1 boundary** (§1.1). The verdict rests on replication,
   not on margin. A finer ladder around 45 and 360 would tighten it; this round did not run one.
2. 🔴 **The registered mirror pass was not run** — 4 arms, not 8, same as ①, because each arm needs
   its own fabric generation. Interleaved with two arms per build and no two same-build arms
   adjacent. **Disclosed, not presented as the registered design.**
3. **Path and control plane remain bound together** (§1.2). Deliberate, registered, and open.
4. **Single machine, single host pair, single payload size, single topology.**
5. **Binary provenance is argv + override cross-check, not `/proc/<pid>/exe`** — one notch below
   kernel-verified, because this uid cannot read a root process's exe link. AMENDMENT-1 §8.5.

---

## 5. What this licenses

| ✅ supported | 🔴 not supported |
|---|---|
| At one hop with the control plane live, **R = 8.0**, both sides measured, four arms | That the shortfall from 12× is due to the path *or* to the control plane — that is another round |
| **H2**: part of the reported 12× is not the compiler flags | That the paper's 12× is wrong — it is right *for the three-hop production path*, which is what it measured |
| stock = 45 M and fast = 360 M at one hop, each replicated with zero spread | A precision better than ±1 ladder rung on either side |
| The generator was not the limit (9.8× margin, measured at the actual top rung) | That the mirror pass would have agreed |

**[Co-developed with claude code -- Adam]**
