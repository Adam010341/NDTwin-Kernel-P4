# PREREG — ② packet size sweep: is the ceiling pps or bps?

**Registered 2026-08-28 evening by `8/28 mainDev`, before any data. Assigned by `8/28 auditor` as P1-②.**
**[Co-developed with claude code -- Adam]**

---

## 1. The claim, and the shape of the contribution

The claim is that bmv2's forwarding ceiling is set by **packets per second**, not bits per second —
i.e. per-packet cost dominates and packet length is nearly irrelevant to the rate limit.

The contribution is **not** the method. It is that the standard NFV-benchmarking axis has never
been run against bmv2. So the axis is theirs, not ours: **64 / 256 / 1024 B**, as used by NetSoft
'19 and CompNet 2021. Inventing a different axis would make the result uncitable against the very
literature it is meant to slot into.

**Literature hook, registered so it cannot be retrofitted:** TSSA 2023 reports two points, 64 B and
128 B. Converted to pps they are ~1.0–1.1 kpps — near-constant — **but the paper's entire narrative
is in Kbps and it never computes pps.** "The constancy is already in their data and absent from
their conclusions" is a defensible sentence *only if* our sweep independently establishes it. This
round is what gives that sentence its footing; it is not evidence by itself.

## 2. 🔴 Frame size, not payload — and the conversion is not optional

The NFV axis is **Ethernet frame size** (64 B is the Ethernet minimum, RFC 2544 convention).
iperf3's `-l` sets the **UDP payload**. Frame = payload + 8 (UDP) + 20 (IPv4) + 14 (Ethernet) =
payload + 42.

| axis point (frame) | iperf3 `-l` (payload) |
|---|---|
| 64 B | **22** |
| 256 B | **214** |
| 1024 B | **982** |

⇒ Running `-l 64` would measure a 106 B frame and silently produce a curve that cannot be compared
to any paper on the axis. **The arm meta records both numbers for every point.**

⚠️ **Unresolved and registered as such:** 08-15's "64 B small-packet" row (3,619 / 50,786 pps) does
not state whether 64 was frame or payload. **It must not be reconciled against this round until
that is established from its raw.** If it turns out to be payload, it is a 106 B frame point and
belongs at a different x than where it would naively be plotted.

## 3. 🔴 The confounder that would fake the headline result

**"pps is constant across packet size" is exactly what a sender-limited experiment produces.** If
the generator hits its own pps ceiling at 64 B, the sweep returns a flat line — and the flat line
is the generator's, not bmv2's. The headline and the artifact are indistinguishable in the data.

This is the fifth form of *the instrument must not mimic its own finding*: **the most downstream
bottleneck hides everything upstream of it.** The receiver-socket round earlier today was the same
shape, one hop further along the path.

### The control, and the 08-15 loopback measurement that does **not** serve as one

The auditor suggested the unused 08-15 loopback control might cover this. **It does not.** That
report fixes its method at `UDP ramp 1400B×10s/點` — so its 42.4 / 63.5 Gbit/s loopback figures are
**1400 B** measurements (≈3.79 / 5.67 Mpps at that size). Small-packet generation is bound by
per-packet cost, not bandwidth, so a 1400 B result establishes nothing about the generator's 64 B
pps ceiling. That is precisely the quantity in question.

⇒ **Registered gate, run before any bmv2 arm and recorded whether it passes or fails:**

> A 64 B **frame** loopback/direct run, not traversing bmv2, must sustain at least **5×** the
> highest 64 B pps this round measures through bmv2. If it does not, **the round is invalid** and
> reports only "generator-limited at 64 B" — no statement about bmv2's pps constancy may be made
> from it.

**Why 5×:** the generator must be far enough from its own knee that its variance does not shape the
curve. At 2× the generator is on its own shoulder and its noise enters the measurement; 5× puts it
in the regime where its output rate is set by the requested rate rather than by its own limit.
08-15 puts bmv2-fast near 50.8 kpps at small packets, so the control must clear roughly 254 kpps.

## 4. Registered predictions — intervals, and every outcome has a meaning

Let **P(s)** = delivered pps at frame size s, bmv2-fast, one flow, highest clean rung (clean rule
inherited from ③ AMENDMENT-2 11.1).

| model | P(256)/P(64) | P(1024)/P(64) |
|---|---|---|
| **H1 — per-packet cost dominates** (the claim) | **[0.75, 1.30]** | **[0.65, 1.30]** |
| **H2 — bandwidth-limited** (pps ∝ 1/size) | **[0.15, 0.40]** | **[0.03, 0.12]** |
| **H3 — mixed fixed + proportional cost** | anything between the H1 and H2 intervals | |

- **H1** ⇒ the headline stands; report pps constancy with the residual.
- **H2** ⇒ the headline is **wrong for this build** and the paper must say the ceiling is bps.
  Registered as a real outcome, not a failure.
- 🔴 **H3** ⇒ **a result, and arguably the most interesting one**: it decomposes the cost into a
  fixed per-packet part and a per-byte part, and the decomposition is recoverable from the two
  ratios. Registered now so that landing between the intervals is not written up as "inconclusive".

Intervals are wide because they inherit the rung resolution of the underlying ladder (±20%) on both
sides of a ratio, the same reason ①'s H1 interval is wide.

## 5. Design

- **Axis**: 64 / 256 / 1024 B frames (payload 22 / 214 / 982).
- **Primary readout is pps**, computed from delivered datagrams and the run duration — **not**
  back-derived from a bps figure and a nominal size, which would bake the conclusion in.
- **bps recorded alongside**, because H1 and H2 make opposite predictions about it and reporting
  only the one that matches would be choosing after the fact.
- **Replication unit is the arm**; two arms per frame size, interleaved and mirrored
  `64 256 1024 | 1024 256 64`.
- **Ladder per size**: the ×1.5 ladder, expressed in pps rather than Mbit so the three sizes are
  climbed on the same axis as the quantity being measured.
- Build identified by symbol signature, never PATH; `pgrep -af 'simple_switch_g[r]pc'`, no `-x`.

## 6. Load and raw

Gate is ③'s AMENDMENT-2 11.2 (in-window busy fraction from `/proc/stat` deltas; rerun if it exceeds
the median arm's by more than 0.15 absolute). **🔴 SUPERSEDED by AMENDMENT-1 §7 below — that gate
was shown to have no discriminating power. See §7.** No commits inside a measurement window. Raw to
`audit-raw` only.

---

## 7. AMENDMENT-1 — the inherited load gate is replaced, because ③ proved it broken

**Registered 2026-08-29 01:25 +0800 by `8/28 mainDev`, directed by `8/28 auditor`. Appended.**

**Approval conditions, all three met:**

| | status |
|---|---|
| zero packets this round | ✅ **no arm of ② has been run; `raw/` does not exist** |
| reasons cite only pre-existing data | ✅ cites ③'s AMENDMENT-3 result (`../2026-08-28_flow-count-capacity/FINDINGS.md` §5) and nothing from ② |
| tightening only | ✅ replaces a gate with **no** discriminating power with one that has a positive control; adds a control arm |

### 7.1 Why the inherited gate cannot be used here

③ registered, before its data, the prediction that its §6 busy-fraction gate fires on the cell's
own forwarding intensity rather than on foreign load. **The prediction was confirmed**: `n8_a`
(0.7134) *and* `n8_b` (0.7044) both fired while `n1_b` (0.2048) and `n2_b` (0.3552) did not.

🔴 **In ③ that gate aligned with a cell. In ② it would align with the treatment itself:**

> **64 B frames produce the highest pps at any given bps, therefore the highest per-packet CPU,
> therefore the highest busy fraction.** The gate would demand a rerun of **exactly the arms that
> carry the headline**, and every rerun would fire again.

That is a treatment effect being classified as contamination — the same disease as the withdrawn
`load1 > 3.0` clause, one level worse because it is correlated with the independent variable rather
than with one cell.

### 7.2 The replacement: gate on the **foreign residual**, not on the total

> **external = total busy − Σ(utime+stime deltas of the 10 `simple_switch_grpc` processes)
> − Σ(utime+stime deltas of the iperf3 processes)**
>
> Sampled every second from `/proc/<pid>/stat`. **PIDs are recorded when the processes are spawned,
> never discovered by pattern** — a pattern search matches the searching process's own command line
> (observed twice today) and would silently attribute the wrong processes.
>
> **The gate is on `external`.** Total busy and the bmv2 self-attributed share are still recorded
> for every arm, but they do not gate anything.

**Threshold:** an arm whose mean `external` exceeds the median arm's by more than **0.15 absolute**
is rerun — the same numeric clause as §6, moved onto the quantity it was always meant to measure.

### 7.3 🔴 The new gate does not count as delivered until it has been seen to fire

Replacing a gate that fires wrongly with one that never fires is not an improvement, and nothing in
③ ever demonstrated that its gate could detect real foreign load.

⇒ **Registered positive control, to run before any measurement arm:**

> A **throwaway arm** is run with a known CPU burner started partway through. It must show
> `external` rising when the burner starts, and the gate must **reject** that arm.
> **If the control does not fire, ② does not start** and the gate is reported as unvalidated.

Both the control's raw and its verdict are recorded whether it passes or fails.

### 7.4 Two cross-checks against existing data, registered now so they cannot be chosen later

Both are **secondary observations**. Neither may adjust any interval, threshold or prediction in
§4, and both are reported whichever way they come out.

1. **③'s n=1 against 08-15's fast-side figure.** ③ measured n=1 clean to **≥240 Mbit/flow** (arm b
   was clean at the ladder's top rung, so this is a lower bound), at 1442 B frames, 3 hops, 128
   hosts. 08-15 puts bmv2-fast's UDP zero-loss point at **300 Mbps**, also 3 hops. **Agreement to
   better than a factor of 1.5 ⇒ the fast side is reproducible.**
   🔑 **Consequence for ①, recorded here because ① runs after ②:** ①'s premise is that the 08-15
   ratio may be path-contaminated. Its **numerator has now been independently reproduced**, so if
   ① lands in H2 (R < 9), the stock-side 25 Mbps is the more likely suspect, not the fast side.
   **This does not change any of ①'s registered intervals.**
2. **②'s 1024 B point against ③'s n=1.** ③'s raw already holds delivered datagram counts and
   durations at 1442 B frames ⇒ **a pps figure can be computed from it for free**, giving a fourth
   point on ②'s axis from an independent round. **H1 predicts the two are close; H2 predicts they
   differ substantially.** Registered now, computed after ② closes.

### 7.5 The pps ladder, fixed numerically (§5 left it as "the ×1.5 ladder")

**Fixed 2026-08-29 01:35, still before any bmv2 arm.** §5 registered the *shape* (×1.5, expressed
in pps) but never wrote the rungs down, so they are pinned here rather than chosen while looking at
results.

**Ladder (kpps, offered): `1 2 3 5 8 12 20 30 45 70 110 160 240`** — the same numeric sequence ③
used, reinterpreted on the pps axis. Requested rate is set as `-b <pps × payload × 8>` because
iperf3's `-b` is an application-layer bitrate; **pps is still read back from delivered datagrams
and duration, never re-derived from the requested rate.**

⚠️ **Disclosure: the top rung was checked against the sender control, which had already run.** The
control measured a 64 B generator ceiling of **770.7 kpps**, so 240 kpps is reachable at every size
and the ladder is not silently truncated by the generator at its top. That is the only way the
control's result influenced this choice — it fixes the *feasible range*, not where the effect is
expected to lie. Recorded because "we pinned the ladder before the data" is otherwise unverifiable.

**Clean rung** = highest offered pps where the flow's loss ≤ 0.5%, same threshold and same
median-of-three rule for any nonzero reading as ③'s AMENDMENT-2 §11.1, including the top-rung
three-rep re-confirmation with walk-down (§11.1(b)). Single flow per arm.

**[Co-developed with claude code -- Adam]**
