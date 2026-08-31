# ①b — R = 8.0, both sides measured. **H2 — but the crude interval spans the boundary; see §1.2–1.3.**

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

## 1.2 🔴 Correction: replication does NOT support this verdict, and the crude interval spans the boundary

An earlier draft of this section said the call was supported "not by the margin but by the
replication". **`8/28 auditor` refuted that and is right — it is withdrawn.**

A ladder rung measures *the highest offered rate whose loss is ≤ 0.5%*, so the true zero-loss point
lies **between that rung and the next**:

| | interval |
|---|---|
| stock | **[45, 70)** |
| fast | **[360, 540)** |
| ⇒ **R** | **(360/70, 540/45) = (5.14, 12.0)** |

**The H1/H2 boundary of 9 is inside that interval.**

🔑 **Replication cannot narrow it.** Six stock arms reading 45 and four fast arms reading 360 with
zero spread proves the *rung* is stable — but the uncertainty here is **quantisation, not noise**.
Ten arms landing on the same rung say nothing about where inside that rung's interval the true
value sits. PREREG §4 said this in advance — "two rungs of resolution on a quotient is roughly
±45%" — and 8.0 ± 45% = [4.4, 11.6] spans the boundary too.

⇒ 🔴 **The decision rule was missing a branch.** H1/H2/H3 are exhaustive over point estimates but
there was no "the interval spans a boundary ⇒ report indistinguishable" case. **That is a design
defect, recorded in §4.**

## 1.3 The knee shape narrows it, using only data already collected

How far past 0.5% the **next** rung reads says how far the true point is from the rung below: a
huge overshoot means we sailed well past the crossing, so the crossing sits near the bottom of the
interval. Read from raw, no new arms:

| build | clean rung | **next rung** | |
|---|---|---|---|
| stock_a / stock_b / b_stock_a / b_stock_b | 0.0000 / 0.3174 / 0.0000 / 0.0000 % | **12.12 / 24.49 / 4.44 / 7.64 %** | ≥ an order of magnitude in every arm |
| b_fast_a / b_fast_b | 0.1540 / 0.3275 % | **25.80 / 26.62 %** | 168× / 81× |

**Both knees are sharp in every arm.** Interpolating linearly for the 0.5% crossing:

| | crossing | position in its interval |
|---|---|---|
| stock (4 arms) | 45.2 – 47.8 | bottom **0.8 – 11.3%** |
| fast (2 arms) | 361.2 – 362.4 | bottom **0.7 – 1.3%** |
| ⇒ **R** | **≈ 7.8** | |

⚠️ **Linear interpolation on a convex curve gives a LOWER bound on each crossing, not an estimate.**
The real curve is flat then steep, so it crosses 0.5% *later* than a straight line does. Both sides
are biased the same way and R is a ratio, so the bias partly cancels — but this is **supporting
evidence, not a measurement**, and it is not what the round registered.

⇒ **Verdict: H2, as the point estimate and as the interval once knee shape is used. Reported with
the crude interval (5.14, 12.0) shown, because that is what the registered instrument alone
delivers.**

📌 Note which way the correction points: R ≈ 7.8 is **further into H2**, i.e. further from the more
publishable H1. **No finer ladder was run to settle it.** ①'s rerun was legitimate because the
instrument could not reach the registered question; here it reached it and honestly reported a
resolution limit. Re-measuring because the answer landed near a boundary would be
"the answer is inconvenient, measure again" — refused.

## 1.4 🔴 What this round may NOT say

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

1. 🔴 **The decision rule had no branch for "the interval spans a boundary".** H1/H2/H3 partition
   point estimates, but a rung measurement carries a quantisation interval, and R's — (5.14, 12.0)
   — contains the H1/H2 boundary of 9. PREREG §4 anticipated the width ("±45% on a quotient") and
   still registered only point-estimate outcomes. **Any future ratio round must register an
   indistinguishable branch alongside its intervals.** Resolved here by knee shape (§1.3), which is
   supporting evidence, not the registered instrument.
2. 🔴 **Replication does not narrow a quantisation interval.** Ten arms on the same rung prove the
   rung is stable and say nothing about position within it. An earlier draft claimed otherwise;
   withdrawn in §1.2.
3. 🔴 **The registered mirror pass was not run** — 4 arms, not 8, same as ①, because each arm needs
   its own fabric generation. Interleaved with two arms per build and no two same-build arms
   adjacent. **Disclosed, not presented as the registered design.**
4. **Path and control plane remain bound together** (§1.4). Deliberate, registered, and open.
5. **Single machine, single host pair, single payload size, single topology.**
6. **Binary provenance is argv + override cross-check, not `/proc/<pid>/exe`** — one notch below
   kernel-verified, because this uid cannot read a root process's exe link. AMENDMENT-1 §8.5.

---

## 5. What this licenses

| ✅ supported | 🔴 not supported |
|---|---|
| At one hop with the control plane live, **R = 8.0** (≈7.8 once knee shape is used), both sides measured | That the shortfall from 12× is due to the path *or* to the control plane — that is another round |
| **H2**: part of the reported 12× is not the compiler flags | That the paper's 12× is wrong — it is right *for the three-hop production path*, which is what it measured |
| stock = 45 M and fast = 360 M at one hop, each replicated with zero spread | **R to better than its quantisation interval (5.14, 12.0) from the registered instrument alone** — the narrowing in §1.3 rests on an interpolation assumption |
| The generator was not the limit (9.8× margin, measured at the actual top rung) | That the mirror pass would have agreed |

**[Co-developed with claude code -- Adam]**

---

## 補報（2026-08-31，reviewer 線；原文一字未改）

🔴 **漏報事實**：PREREG §「Both, every arm … **interface counters read as ingress-port RX
against egress-port TX on the same switch**」——**每臂都採了**
（`raw/<arm>/netdev_{before,after}.txt` 在 `audit-raw`），**但從未回報**。
2026-08-31 的回報義務清償盤點發現，本節同日補報。

### 回收的值（我方自 `audit-raw` 逐臂重算，非轉述）

s1-eth3 的 RX 封包對 s1-eth4 的 TX 封包，取 after − before：

| 臂 | ingress-RX | egress-TX | **交換機內部損失** | netdev 各 drop 欄合計 |
|---|---|---|---|---|
| b_stock_a | 429,504 | 332,488 | **22.59%** | **0** |
| b_stock_b | 429,503 | 331,062 | **22.92%** | **0** |
| b_fast_a | 3,740,019 | 3,368,908 | **9.92%** | **0** |
| b_fast_b | 3,582,865 | 3,216,786 | **10.22%** | **0** |

### 它證明什麼

🔑 **一個不經 iperf3 的獨立佐證**：封包在 **s1 內部**消失（進得去、出不來），
而 **Linux 的每一個 netdev drop 欄位都是 0**。
⇒ 本研究「核心的丟包計數器對 bmv2 內部的損失完全無感」這個宣稱，
在 ① 這一輪有**自己的、與 iperf3 正交的證據**，不必只靠 ③ 的 79.66% 那一格。

### ⚠️ 口徑限制（必須隨數字一起引用）

**這是「整臂累計」不是「某一階的損失」**：`netdev_before/after` 跨越該臂**整條梯子**，
因此包含**乾淨階之上的髒階**。⇒
- **不得**把 22.59% 讀成「stock 在其乾淨階損失 22.6%」；
- **不得**跨輪直接比（① 的 fast 臂 0.10–0.19% vs ①b 的 9.9–10.2% 是**同一顆 build**——
  差別在於**①b 的梯子爬得更高**，於是更多時間待在膝蓋之上，不是 build 變差了）。
- 可用的比較是**同輪同梯內**：stock 22.6–22.9% vs fast 9.9–10.2%，
  兩臂走**同一條梯子**⇒ 這個對比有意義。

⇒ **登記的用途（「收端不是限制、損失在交換機」）成立；
跨輪的絕對值比較不成立，且本節明文禁止之。**

