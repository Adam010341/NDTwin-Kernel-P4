# ② — is bmv2's forwarding ceiling pps or bps? Result: **pps**

**Created 2026-08-29 by `8/28 mainDev`.** Design: `PREREG.md` §1–§6 + AMENDMENT-1 §7.
Instrument: `run_size_arm.sh`. Driver: `drive_p2.sh`. Analysis: `analyse_p2.py`. Raw → `audit-raw`.

Six arms, mirrored `64 256 1024 | 1024 256 64`, 2026-08-29 09:13–09:35, single flow h1→h65
(s1→s3), 10 × `simple_switch_grpc` from `/usr/local/bmv2-fast/`, kernel `a40e04ce`, 128-host P4
topology. **Frame sizes, not payloads** — iperf3 `-l` 22 / 214 / 982 (frame = payload + 42).

---

## 1. The result

**Highest offered rate at which the flow stayed ≤ 0.5% loss:**

| frame | arm a | arm b | mean |
|---|---|---|---|
| **64 B** | 20 kpps | 12 kpps | **16.0** |
| **256 B** | 20 kpps | 20 kpps | **20.0** |
| **1024 B** | 12 kpps | 20 kpps | **16.0** |

### The registered ratios (PREREG §4, fixed before any arm ran)

| ratio | measured | H1 (pps ceiling) | H2 (bps ceiling) | verdict |
|---|---|---|---|---|
| P(256)/P(64) | **1.25** | 0.75 – 1.30 | 0.15 – 0.40 | ✅ **H1** |
| P(1024)/P(64) | **1.00** | 0.65 – 1.30 | 0.03 – 0.12 | ✅ **H1** |

⇒ **H1: the ceiling is packets per second, not bits per second.** Both registered ratios land
inside H1 and nowhere near H2.

### The same six numbers stated as bandwidth

| frame | clean kpps | frame Mbit/s |
|---|---|---|
| 64 B | 16.0 | **8.2** |
| 256 B | 20.0 | **41.0** |
| 1024 B | 16.0 | **131.1** |

🔑 **pps varies 1.25×; bits/s varies 16.0×.** A bps ceiling would produce the opposite — a flat
Mbit/s column and a pps column falling 16×. **Reporting bmv2's capacity in Mbps without stating
the packet size is therefore not an imprecision, it is a 16× ambiguity.** That is C2.

---

## 2. Three independent supports that were not part of the registered test

1. **Every one of the six arms truncated at the same rung — 110 kpps.** The truncation rule
   ("two consecutive rungs above 25% loss") is computed per arm from loss alone and knows nothing
   about frame size, yet all three sizes broke down at the same *packet* rate while their bit rates
   at that rung differ 16×.
2. **bmv2's own CPU share is near-constant across the axis**: 0.1456 – 0.1660 (spread 0.0204) over
   all six arms, measured per-process from `/proc/<pid>/stat`. At the clean rung the switch costs
   the same CPU regardless of how big the packets are — the mechanism H1 asserts.
3. **A fourth point from an independent round** (registered in AMENDMENT-1 §7.4.2 *before* this
   round): ③ measured n=1 clean at 160 and 240 Mbit/flow with 1400 B payloads ⇒ **14.3 and
   21.4 kpps, mean 17.9 kpps at a 1442 B frame.** ②'s 1024 B cell is 16.0 kpps — **ratio 1.12**.
   ③'s ladder was denominated in Mbit/s, not pps, so that point could not have been shaped by ②'s
   axis.

---

## 3. The confounder that would have faked this result was measured, not assumed

**"pps is constant across packet size" is exactly what a sender-limited experiment produces.**
PREREG §3 registered the gate before any arm:

> A 64 B frame loopback run not traversing bmv2 must sustain ≥ **5×** the highest 64 B pps this
> round measures through bmv2, or the round is invalid and reports only "generator-limited".

| | |
|---|---|
| highest 64 B pps through bmv2 | 16.0 kpps |
| requirement (5×) | 80.0 kpps |
| **measured generator ceiling** (h1→h1 loopback, 64 B frames, 3 reps: 770.7 / 761.0 / 771.6) | **770.7 kpps** |

✅ **Passes by 9.6×.** The generator is nowhere near its own knee at any point on this axis.

⚠️ 08-15's loopback figures (42.4 / 63.5 Gbit/s) do **not** serve as this control — that round
fixes its method at 1400 B, and small-packet generation is bound by per-packet cost, not bandwidth.
This control was run fresh at 64 B for that reason.

---

## 4. The load gate was replaced before the round, and it has a positive control

The gate inherited from ③ (§6, total `/proc/stat` busy fraction) was **not usable here**. ③'s
AMENDMENT-3 had just shown it measures the arm's own forwarding intensity. In ② that is not a
nuisance — **64 B produces the most packets per second, hence the most CPU, hence the highest busy
fraction**, so the gate would have demanded a rerun of exactly the arms carrying the headline, and
every rerun would have fired again. AMENDMENT-1 §7 replaced it, before any arm:

> **external = total busy − Σ(utime+stime of the 10 `simple_switch_grpc`) − Σ(utime+stime of iperf3)**

PIDs are enumerated by exact `comm` and recorded in every `arm.meta`, never discovered by a pattern
over argv — a pattern matches the searching process's own command line.

| arm | external | vs median (0.0827) |
|---|---|---|
| 64 a / b | 0.0899 / 0.0111 | +0.0072 / −0.0716 |
| 256 a / b | 0.0970 / 0.0650 | +0.0144 / −0.0176 |
| 1024 a / b | 0.1052 / 0.0754 | +0.0226 / −0.0073 |

**No arm fired** (threshold +0.15 absolute).

🔑 **That is a measurement rather than an untested gate, because the gate has a positive control**
(AMENDMENT-1 §7.3, required before the round could start): a throwaway arm with 4 CPU burners
started partway through read **external = 0.2959** against **0.0178** without — and `bmv2_share`
and `iperf3_share` stayed correctly attributed, so the burner load landed entirely in the residual.
③'s gate was never once shown to detect real foreign load; this one was, before it was trusted.

📌 **A bug the positive control caught first.** The first build of the sampler summed
`utime+stime` over *currently alive* iperf3 processes. Every rep spawns fresh iperf3 processes that
then exit, so the sum returns to ~0 between reps and last-minus-first read **0.0000** — the
generator's entire cost would have landed in `external`, and it is largest at 64 B, which is the
treatment. **The bug I was removing would have rebuilt itself inside the fix.** Corrected to a
per-PID accumulator: `iperf3_share` 0.0000 → 0.0572, `external` 0.1052 → 0.0178 on the same
workload.

---

## 5. Threats to validity

1. 🔴 **The within-cell spread equals the between-cell spread.** 64 B and 1024 B each have arms one
   ladder rung apart (12 and 20); 256 B has both arms at 20. On a ×1.5 ladder one rung *is* the
   instrument's resolution. ⇒ **The honest statement is that the three sizes are indistinguishable
   at ±1 rung.** That is what H1 predicts, and the registered intervals were sized to accommodate
   it — but this round cannot exclude a real effect smaller than one rung. It excludes H2, which
   predicts a 16× difference, by a very wide margin.
2. 🔴 **One cell sits on the threshold's waist.** The 1024 B pass B confirmation scored a median of
   **0.4969%** against a 0.5% clean threshold — a margin of 0.0031 percentage points. Had it read
   0.5001 the walk-down would have reported 12 kpps instead of 20, moving the 1024 B mean from 16.0
   to 14.0 and P(1024)/P(64) from 1.00 to 0.88 — **still inside H1**, so the verdict does not turn
   on it, but the cell value does. Same shape as ③'s AMENDMENT-1 finding.
3. **Single flow, single path class, single fabric, single build.** The axis was swept; nothing
   else was.
4. **The sampler's own CPU is unattributed** and lands in `external`. It is the same 1 Hz loop in
   every arm regardless of frame size, so it is a constant offset and the gate is relative.
5. **08-15's "64 B" row is still not reconciled against this round**, because that report never
   states whether its 64 B is a frame or a payload. PREREG §2 forbids reconciling until it is
   settled from its raw. Unchanged.

---

## 6. What this licenses

| ✅ supported | 🔴 not supported |
|---|---|
| bmv2's clean forwarding rate is set by pps, not bps (H1, both registered ratios) | A precise pps figure — the cells resolve to ±1 rung |
| Reporting bmv2 throughput in Mbps without the packet size is a 16× ambiguity | That pps is *exactly* constant; an effect below one rung is not excluded |
| The generator was not the limit (9.6× margin, measured) | Any statement about other builds, flow counts or fabrics |
| Foreign CPU load did not gate any arm, on a gate proven able to fire | That the arms were free of *all* foreign load — only above the threshold |

## 08-30 更正（metrologist 外審 R-1/R-2；收案後追註，不改上文）

本檔多處以「×1.5 ladder」描述梯子——那是**名目值**。照本檔印出的階值逐一計算，
**實現步距＝1.4545×（110→160）到 2.0×（1→2）**；本輪兩個格值所在的 12→20 kpps
一階＝**1.667×**。任何把 ±1 階換算成倍率的敘述（含衍生稿）應以實現步距為準，
不得寫成 "<1.5×"。連帶：兩臂格值 {20,12}/{20,20}/{12,20} 的格平均 16.0/20.0/16.0
是**兩臂平均值、沒有任何一臂讀到 16.0**——引用格值時要帶臂值（本檔 §1 原表即有）。

**[Co-developed with claude code -- Adam]**
