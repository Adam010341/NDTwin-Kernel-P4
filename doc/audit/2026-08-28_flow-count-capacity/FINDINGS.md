# P1-3 — bmv2 clean rate as a function of flow count: results

**Created 2026-08-29 by `8/28 mainDev`.** Design: `PREREG.md` §1–§9 + AMENDMENT-1/2/3.
Instrument: `run_flowcount_arm.sh` (byte-identical across both passes). Driver: `drive_p1_3.sh`.
Analysis: `analyse_p1_3.py`, **written before pass B data existed**. Raw: `raw/` → `audit-raw`.

Ten arms, mirrored `1 2 4 8 16 | 16 8 4 2 1`, 2026-08-28 20:15–20:35 (pass A) and
2026-08-29 00:35–00:56 (pass B). Same fabric throughout: 10 × `simple_switch_grpc` from
`/usr/local/bmv2-fast/`, kernel `a40e04ce`, 128-host P4 topology, h1→h65 (s1→s3), flows separated
by port. Pass A and pass B are **not** contiguous — see §6.

> 🔴 **`a40e04ce` 是那顆 kernel binary 自己的 sha256 前 8 碼，不是 git commit。**
> 一行可驗：`sha256sum .test_run/binaries/ndtwin_kernel.a40e04ce`
> ⇒ `a40e04ce93b0e2263f715780cc146a46bedaca680641ed224c8f51ddc985dad7`。
> 拿 git 去解析它會得到 `Not a valid object name`，**那是預期的，不是缺陷**。
>
> **真正的缺口在別處且早已在案**：KNOWN-ISSUES〈生產線在跑的那顆 kernel 的重建配方〉——這顆的 provenance 是
> **事後補寫的，只記得下 `commit=UNKNOWN`** ⇒ 「**哪一顆在跑**」答得出來（sha 對得到），
> 「**怎麼再造一顆一樣的**」答不出來。
>
> 🔑 這一條補的是 CLAUDE.md「benchmark 必指認 binary（**sha ＋哪種識別碼**）」的後半：
> sha 一直都在，**「哪種」從來沒寫**。八位十六進位擺在 `kernel` 後面已經被獨立誤讀三次
> （Muse 草稿讀成 Linux 版本；`REVIEW.md:589` 在**更正前一次誤讀的那一句裡**讀成 commit；
> 09-01 `8/29 poster-reviewer` 讀成 commit 並發了一個假告警）。
> （09-01 由 `9/1 auditor` 裁定、`8/29 poster-reviewer` 落。原文未改。）

---

## 1. The headline: per-flow highest clean rate falls monotonically, in each arm separately

**Highest offered per-flow rate at which every flow stayed ≤ 0.5% loss:**

| n (flows, all on one path class) | 1 | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| **arm a** (M/flow) | 160 | 110 | 30 | 5 | 2 |
| **arm b** (M/flow) | 240 | 110 | 45 | 8 | 1 |

🔑 **Both arms are independently monotone decreasing.** That is the claim this round supports, and
it needs no ratio. Aggregate (`n ×` the above) is an arithmetic consequence, not a second finding.

**This is the measurement C3 should cite.** The withdrawn "collapse 3.3×" framing divided a
*highest-clean threshold* (which sits on a plateau) by a *knee* — two different quantities. See
the retraction blocks in `doc/2026-08-28_bmv2-throughput-literature-vs-ours.md` §3-3,
`../2026-08-28_jitter-working-point/02_result.md` §1, and `04_ovs_result.md` §5.

---

## 2. Aggregate against the registered intervals — the round does not land where it predicted

| n | arm a | arm b | spread | registered interval | verdict |
|---|---|---|---|---|---|
| 1 | 160.0 | **240.0** | 80.0 | — (anchor) | anchor cell |
| 2 | 220.0 | 220.0 | **0.0** | **95 – 150** | 🔴 **both arms outside (high)** |
| 4 | 120.0 | 180.0 | 60.0 | 65 – 125 | ⚠️ arms straddle the edge — interval does not decide |
| 8 | 40.0 | 64.0 | 24.0 | 45 – 90 | ⚠️ arms straddle the edge — interval does not decide |
| 16 | 32.0 | 16.0 | 16.0 | **35 – 70** | 🔴 **both arms outside (low)** |

**Only one of four registered cells is decided by its interval, and two are decided against it in
opposite directions.** Neither registered model survives: measured aggregate means are
200 / 220 / 150 / 52 / 24 against per-flow-fixed-overhead 160 / 138 / 109 / 76 / 48 and power-law
160 / 118 / 88 / 65 / 48.

🔴 **Residuals are reported against the anchor as registered, not re-fitted.** The n=1 anchor of 160
is now known to be a *lower bound* (see §3), so the model curve is pinned too low at its left end.
Re-anchoring after seeing the data would not be pre-registration.

## 2.1 🔴 The registered abandon criterion FIRED

Registered in `HANDOFF-CONTEXT.md:65-67` by `8/27 mainDev`, commit `48487ed`, **before any data**
(*not* in `PREREG.md` — an earlier draft of `analyse_p1_3.py` mis-cited it and has been corrected):

> **What would make me abandon the round:** if n=2 lands outside 95–150 in both arms. That would
> mean the two-point model that generated every interval is wrong, and continuing to 4 and 8 would
> just produce three numbers with no frame. **Stop and re-derive.**

**n=2 measured 220.0 in both arms.** The criterion is met exactly, and its stated reason is
confirmed rather than merely triggered: the two-point model that generated every interval was
anchored on 160 at n=1, and n=1 arm b reached 240.

⇒ **§1's monotone per-flow curve stands on its own** (it is measured, not modelled).
⇒ **§2's intervals do not.** They should be re-derived from the five measured cells, and this
round should not be reported as testing them. **That is an escalation, not something this session
decides.**

---

## 3. n=1 cannot find its own ceiling — now shown, not argued

Pass A: 240 M/flow read 0.6091% (dirty), 160 clean.
**Pass B: 240 M/flow read 0.2089% — clean, and 240 is the top rung of the ladder.**

⇒ The n=1 cell **ran out of ladder before it ran out of switch, in a directly observed way**. The
ladder is a *per-flow* scale, so n=1 can offer at most 240 Mbit aggregate, while the single-flow
delivered ceiling measured separately is ~486 Mbit (`../2026-08-28_jitter-working-point/01_capacity.md`).

⚠️ **Precise wording matters here.** In pass A the ladder *did* produce a dirty rung at n=1, so
"highest clean rung" is a well-defined quantity measured on the same scale in all five cells. What
n=1 cannot reach is the **saturation ceiling**. The reported claim (§1) does not need it.

🔴 **The ladder was not extended to chase it.** Extending an instrument because the result is
unwelcome is the opposite of the discipline this work argues for; ruled by `8/28 auditor`.

---

## 4. Arm-to-arm spread is the most important instrument result

| n | spread (arm a vs arm b) |
|---|---|
| 2 | **0%** — 220.0 vs 220.0, identical |
| 1 | 1.5× |
| 4 | 1.5× |
| 8 | 1.6× |
| 16 | **2.0×** |

**Four of five cells differ by 1.5–2× between two arms of the same cell.** Any single-arm number
from this design is unreliable at that scale — which is exactly why PREREG §7 makes the **arm**,
not the rep, the replication unit. A round reporting pass A alone would have published a different
curve with the same apparent precision.

📌 n=2's exact agreement across arms is *not* evidence that n=2 is better measured; with n=5 cells
one exact match is unremarkable. It is recorded because it is the cell that fires the abandon
criterion.

> 📌 **08-29 auditor restatement (recorded by the report session; same numbers, stronger frame):**
> in ladder-rung terms the five cells differ by **at most one rung** (n=2: zero rungs). "1.5–2×"
> *is* the distance between adjacent marks on this ×1.5 ladder, not a noise magnitude. ⇒ **The two
> arms agree within instrument resolution; the ladder's coarseness is the error bar (±1 rung).**
> The paragraph above stands, with its reason replaced: a single arm is not imprecise — it simply
> cannot resolve past ±1 rung, so a single-arm curve carries false apparent precision.

---

## 5. AMENDMENT-3: the registered prediction about the §6 gate was confirmed

Registered 00:37:35, **before `n8_b` ran** (`raw/` then held only `n16_b`; see PREREG §12.0 for the
state capture). The prediction was: *if §6 measures the cell's own forwarding intensity, `n8_b`
will also fire and `n1_b`/`n2_b` will not.*

Measured (median arm busy fraction 0.4485, gate at 0.5985):

| arm | busy | gate |
|---|---|---|
| n8_a | 0.7134 | 🔴 fires |
| **n8_b** | **0.7044** | 🔴 **fires** |
| n1_b | 0.2048 | ok |
| n2_b | 0.3552 | ok |

⇒ **Row 1 of the registered table.** §6 **has no discriminating power in this design** — it measures
the cell's own effect. **n=8 keeps both arms, with this disclosure.**

🔴 **Recorded as required: this round had no working detector for foreign CPU contamination.**
Neither `load1 > 3.0` (withdrawn, §11.2) nor the `/proc/stat` busy fraction separates foreign load
from "this cell is simply working harder"; making the comparison relative did not cure it. The fix
— attributing CPU per process via `/proc/<pid>/stat` — belongs to tickets ① and ②, which have zero
data. **It was not applied retroactively here.**

Supporting (unregistered, printed in its own panel): CPU per Mbit actually moved rises with n in
both passes — 0.00219/0.00203, 0.00266/0.00222, 0.00379/0.00308, **0.00946/0.00821** for
n = 1,2,4,8. That is this round's own premise appearing in the gate's input.

---

## 6. Threats to validity

1. 🔴 **The two passes are 4 hours apart, not interleaved as designed.** PREREG §7 asks for arms
   "separated in time and interleaved across cells" so drift cannot align with a cell — the mirror
   order does that *within* a pass. Pass B was killed at 20:38 by a `/compact` that reset the
   owning shell (see `raw/_discarded/n16_b_partial/WHY-DISCARDED.md`) and restarted at 00:35.
   **Any drift between 20:35 and 00:35 is confounded with the pass, not with the cell.** The mirror
   order still protects cell-to-cell comparison *within* each pass, and both passes are
   independently monotone (§1), which is the main claim.
2. **`NO_MEASUREMENT` is not missing at random** — 27/256 (n16_a) and 29/288 (n16_b), zero in every
   other cell, concentrated at the high rungs, caused by the iperf3 control channel failing under
   the congestion being measured. Full statement and the instruction not to drop those rows in
   secondary analysis: `raw/README.md`.
3. **Single fabric, single machine, single build.** n=16 aggregate here (24.0 mean) is not
   comparable to the older spread-over-four-path-classes 48 Mbit point except directionally (§7).
4. **No foreign-contamination detector** (§5).

---

## 7. Secondary observation registered in PREREG §2 (free, directional)

| placement of 16 flows | aggregate clean |
|---|---|
| **all on one path class** (this round, 2 arms) | **24.0 Mbit** (32.0, 16.0) |
| spread over four path classes (older, 1 arm) | 48.0 Mbit |

⇒ **Spreading flows across path classes raises the aggregate**, consistent with the mechanism
(per-packet CPU shared per switch). ⚠️ The old point is one arm on a coarser ladder (rungs
30/10/5/3), and this round's own n=16 arms differ by 2×. **Directional only; do not quote the
difference as a number.**

---

## 8. Readouts that were run and what they showed (PREREG §5)

**Cross-instrument reconciliation, all ten arms**: `iperf3 sum_sent.bytes + 42 B/packet` over
`netdev s1-eth3 RX bytes` = **1.0000–1.0001**. This validates the `sum_sent` parsing, the netdev
capture, and that no other traffic crossed that interface.

**Interface counters paired ingress-RX vs egress-TX on the same switch** (the only informative
pairing — §11.3):

| arm | s1 in (pkt) | s1 out (pkt) | lost inside s1 | netdev drop columns |
|---|---|---|---|---|
| n1_a / n1_b | 1,575,884 / 1,747,303 | 1,572,429 / 1,745,893 | 0.22% / 0.08% | **0** |
| n16_a / n16_b | 6,164,860 / 5,990,713 | 1,254,175 / 1,437,803 | 79.66% / 76.00% | **0** |

🔴 **Every netdev drop column reads 0 in every arm, including one that lost 79.66% of its packets.**
Loss is inside bmv2's own buffers, where no kernel counter can see it. Read as per-interface drops,
this readout reports "no loss" while three quarters of the traffic disappears.

**Receiver null check**: cited, not re-derived — loopback h1→h1 measured 42.4 Gbps (stock) /
63.5 Gbps (bmv2-fast), ~400× above the top of this ladder, so the receiver is not the limit.

---

## 9. What this round does and does not license

| ✅ supported | 🔴 not supported |
|---|---|
| Per-flow highest clean rate falls monotonically with flow count on one path class (§1), replicated | Any ratio between an n=1 number and an n=16 number |
| The registered intervals and the two-point model they came from are wrong (§2.1) | A specific corrected collapse factor |
| n=1's ceiling is not reachable by this instrument (§3) | The value of that ceiling from this round |
| Single-arm results from this design are unreliable at 1.5–2× (§4) | Any single-arm number quoted with precision |
| §6 cannot detect foreign load in this design (§5) | That the arms were free of foreign load |


---

## 補報（2026-08-31，reviewer 線；原文一字未改）

🔴 **漏報事實**：本輪**每臂都採了** `/proc/net/snmp` 的收端計數
（31 個 raw 檔 `snmp_recv_{before,after}.txt`，在 `audit-raw`），
**而 §5 的 receiver null check 沒有用它們**——它引的是 08-15 的 loopback 值，
且原文自陳 **"cited, not re-derived"**。2026-08-31 的回報義務清償盤點發現此事，
本節於同日補報。

### 這是**替換**，不是補強

| | 原論證 | 補報的論證 |
|---|---|---|
| 形態 | **能力式**：「收端有 ~400× 餘裕，所以不是它」 | **觀測式**：「在要緊的那些格，收端一個封包都沒丟」 |
| 依據 | 08-15 的 loopback 42.4／63.5 Gbps，**跨兩週、跨輪** | **本輪、同 fabric、同臂**的逐臂計數 |
| 已知問題 | 🔴 該值比三次直接量測高 **5–8 倍**（①b 實測 7902.3、OvS gate 7311、08-31 另一台 VM 8331.3）——見 `2026-08-31_completeness-experiments/FINDING-loopback-ceiling-disagreement.md` | 無跨輪可比性假設 |

⇒ **本輪的收端 null check 自此改以下表為據；那個 loopback 值不再是它的支柱**
（可保留為佐證，但必須同時揭露它的「未重推」與 5–8 倍歧異）。

### 逐臂 `RcvbufErrors`（自 `audit-raw` 取出）

| 臂 | before → after | Δ |
|---|---|---|
| n1_a | 281 → 293 | **12** |
| n1_b | 308 → 337 | **29** |
| n2_a | 293 → 308 | **15** |
| n2_b | 308 → 308 | 0 |
| n4_a／n4_b | 308 → 308 | **0／0** |
| n8_a／n8_b | 308 → 308 | **0／0** |
| **n16_a／n16_b** | 308 → 308 | **0／0** |

全輪合計 **56** 個 datagram，**全部落在 n=1／n=2；n=4 以上全零**——
**包含 n=16，即 79.66% 封包消失在 s1 內部的那一格。**
⇒ 「損失在交換機不在收端」由**推論**升為**同輪直接觀測**。

🔑 **第 3 點才是它真正的力量**：本輪其他結論都靠「同輪同臂」才成立，
**這一處卻曾經破例去引一個兩週前的外部數字**。

### 順帶：一個本來就在資料裡、沒人用的內部一致性檢查

n=1／n=2 的**非零** Δ，與本輪對 n=1 格「收端限」的既有註記**吻合**。
⇒ 這是「**我們手上的資料比我們用掉的多**」的直接證據。

**[Co-developed with claude code -- Adam]**

### 補報之二（2026-08-31）：`PREREG.md:305-312` 的 open observation

🔴 **漏報事實**：該條註冊為 **open observation**——
「if the 128-host fabric roughly halves single-flow capacity, that is a table-occupancy effect」
——**從未在本檔處理**。2026-08-31 盤點發現，同日補報。

**照結果報（而結果是「本輪的解析度答不出來」）**：

| 比較對象 | 值 | 對 08-15 的 300 Mbps |
|---|---|---|
| 本輪 n=1 arm a | 160 Mbit/flow | **0.53×**（≈ 減半 ✅） |
| 本輪 n=1 arm b | 240 Mbit/flow | **0.80×**（不算減半 ❌） |

🔑 **決定性的一點：160 與 240 是本梯上的相鄰兩階。**
依本輪自己的解析度規矩（「差 1 階＝解析度內，不是複製精度」），
**兩臂在儀器解析度內一致——而「是否約略減半」這個問題，答案在那一階之內就翻面了。**
⇒ **本輪的梯階解析度不足以回答這個 open observation。**

⚠️ **一個看似的反例，其實不可用**：①b 在**同一個 128-host fabric** 上讀到 **360**，
高於 08-15 的 4-host 三跳 300——**但它是單跳**，同時改變了跳數與 fabric 大小
⇒ **混淆，不構成對「表格佔用效應」的否證**。照 §「不得強行歸入最近的一列」的紀律，
本節不把它算成證據。

⇒ **結論：報「在本輪解析度下不可判定」，而不是報「減半」或「沒有減半」。**
要回答它需要**更細的梯階**或**固定跳數只變 fabric 大小的專門對照**，兩者皆非本輪設計。

