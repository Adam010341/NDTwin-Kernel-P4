# PREREG — bmv2 capacity as a function of flow count (2, 4, 8)

**Registered 2026-08-28 evening, before any data. Assigned by `8/28 auditor` as P1-3.**
**[Co-developed with claude code -- Adam]**

Fills the middle of the collapse curve whose ends are the only measured points today:
one flow clean to ~160 Mbit, sixteen flows clean only to ~48 Mbit aggregate.

---

## 1. 🔴 What this must NOT be reconciled against

`01_capacity.md` used to say "with four flows sharing, that link's usable total drops to about
12 Mbit". **That is not a measurement.** It is `3 M/flow × 4 flows/link`, the sixteen-flow row
divided. Corrected in `6d67d45`. **There is no existing four-flow data point.**

⇒ If this round lands near 3 M/flow at n=4, **that is not confirmation of anything**, because the
number it would agree with was computed from the sixteen-flow measurement by division. Registering
this here so a later reader cannot mistake the agreement for replication.

## 2. 🔴 The x-axis, stated before the data — and why the existing 16-flow point is not on it

`02_result.md:19` says the bottleneck is bmv2's **per-packet CPU, shared across the whole
switch**. So the causal unit is **flows per switch**, not per link. But the existing sixteen-flow
measurement spread its flows over **four path classes**, so its flows-per-link is 4 and its
flows-per-switch depends on which switch. The two units coincided there by accident.

**Registered choice: every cell puts all n flows on ONE path class, h1→h65 (s1→s3).**
Then flows/switch = flows/link = n, with no mapping to argue about.

| | flows | placement | on this curve? |
|---|---|---|---|
| existing 1-flow, 160 M | 1 | h1→h65, one path | ✅ yes — same placement |
| **existing 16-flow, 48 M** | 16 | **four path classes** | 🔴 **NO — different placement** |
| this round: n = 1, 2, 4, 8, 16 | n | h1→h65, one path | ✅ |

⇒ **The old 16-flow point must not be plotted on this curve.** Running our own n=16 under the
registered placement gives a same-placement endpoint, and the difference between it and the old
spread-out 16 is a free bonus: it measures whether spreading flows across path classes matters at
all. Registered as a secondary observation, not as this round's question.

## 3. 🔴 The endpoints are only known to within a factor of two, so they get re-measured

The 160 M figure comes from a geometric ladder (`5 10 20 40 80 160 320 640 1280`). "160 clean,
320 not" means true capacity ∈ [160, 320) — **a factor of 2**. The 3 M/flow figure comes from
rungs `30 10 5 3`, so per-flow ∈ [3, 5).

Registering middle cells on a finer ladder while inheriting coarse endpoints would produce a curve
whose shape is partly an artifact of the ends being measured with a blunter instrument — the
resolution-equals-threshold trap. **So n=1 and n=16 are re-measured on the same ladder as
2/4/8.** Nothing is inherited.

**Ladder, same for every cell** (per-flow offered Mbit):
`1 2 3 5 8 12 20 30 45 70 110 160 240` — roughly ×1.5, so a rung bounds capacity to ±20% rather
than ±100%.

**Clean rung** = highest offered rate where **every** flow's loss ≤ 0.5%, the same noise floor the
capacity ladder used and fixed before it ran. **Aggregate clean** = n × that rung.

## 4. Registered predictions — intervals, not directions

Two models fit both existing endpoints and disagree in the middle. That is what makes the middle
worth measuring.

| model | form | n=2 | n=4 | n=8 |
|---|---|---|---|---|
| **per-flow fixed overhead** | `agg = 160/(1+0.156(n−1))` | 138 | 109 | 77 |
| **power law** | `agg = 160·n^−0.434` | 118 | 88 | 65 |

**Registered intervals for aggregate clean throughput (Mbit):**

| n | interval | |
|---|---|---|
| 2 | **95 – 150** | |
| 4 | **65 – 125** | |
| 8 | **45 – 90** | |
| 16 | **35 – 70** | same-placement endpoint |

Intervals are wide because they inherit the ±20% rung resolution **and** the spread between the
two models. A derived quantity's tolerance must be at least as wide as the noise it inherits.

**Outcomes, all three registered now:**
- Inside interval and separating the models ⇒ report which model, with the residual.
- Inside interval but **not** separating them ⇒ report "consistent with both", not a winner.
- 🔴 **H3: no collapse at all between 2 and 8** (aggregate flat near 160) ⇒ that is a result about
  where the collapse starts, not a failed measurement. It would mean the 16-flow collapse is
  concentrated above n=8, and the next cell to run is 12.

## 5. Both readouts, every cell — non-negotiable

Registered as a deliverable by the auditor, and for a measured reason: today's jitter round showed
that when a receiving socket fills, **iperf3's delivered figure reports the receiver's limit while
looking exactly like a forwarding limit**.

| readout | where | why |
|---|---|---|
| iperf3 `sum_sent` / `sum_received` | both ends | what the flow experienced |
| `/proc/net/dev` on `s1-eth*`, `s3-eth*` | interface | **upstream of every socket** ⇒ immune |
| `tc -s qdisc` before/after | qdisc | cumulative, so baseline first |
| `/proc/net/snmp` Udp on the receiver | socket | names the receiver if it is the limit |

⇒ **Without the interface counters, "collapse" and "the receiver could not drain" produce the same
iperf3 numbers.** At 45–160 Mbit an unloaded receiver is far from its limit (measured today:
800 Mbit single flow, no load, 0.459% loss), so this is expected to be a null check — but a null
check that was actually run.

## 6. The constant that has to be shown to be constant

The machine being idle is pinned as a constant (no burners). A pinned confounder needs a
measurement proving it stayed pinned.

- `load1` and `/proc/stat` **deltas** sampled every 2 s for the whole of every arm.
- **Arm-invalidating gate, fixed now:** any arm whose in-window busy fraction exceeds the median
  arm's by more than 0.15 absolute, or whose load1 max exceeds 3.0, is **rerun**, not adjusted.
- 🔴 **No commits inside a measurement window.** Each commit spawns a background `agy` review;
  one instance was measured today at 54.7% of a core for up to ten minutes. Recording the
  experiment contaminates the experiment.

## 7. Replication unit

**The arm, not the rep.** Reps inside one arm are re-reads of one arm. **Two arms per cell
minimum**, arms separated in time and interleaved across cells rather than run back to back, so a
drift in machine state cannot align with a single cell.

Cell order, both passes, mirrored so linear drift cancels:
`1 2 4 8 16 | 16 8 4 2 1`

## 8. Binary and fabric, named before the run

- Fabric: bmv2, 10 switches. **`pgrep -af 'simple_switch_g[r]pc'`** to record whether the running
  switches are `/usr/local/bmv2-fast/` or stock — the two differ by 12–18×, and PATH does not
  answer this.
- `build/bin/ndtwin_kernel` sha256 prefix recorded at start and again at end. Currently
  `a40e04ce` = ticket M's binary, path recompute at 1 Hz, established by symbol
  (`nm -C | grep kFlowPathRecomputeInterval`, 5 hits; `3367d0e9` answers no to both Q and M and
  is the negative control). **`commit=UNKNOWN` in its provenance is a measurement, not a blank.**

## 9. Raw

Raw goes to the `audit-raw` branch, never to a working branch; the pre-commit hook from `f1df56e`
enforces it. Figures citing raw resolve through `audit-raw` by content hash (`aa10c8e`).

---

## 10. AMENDMENT-1 — registered 2026-08-28 evening by `8/28 mainDev`, before any data

**Not one packet of this round has been sent.** This amendment cites only pre-existing data
(`doc/audit/2026-08-28_jitter-working-point/raw/capacity_interleave/`) and only tightens.

### The problem: the registered clean threshold sits inside the noise at its own anchor rung

§3 sets **clean = every flow's loss ≤ 0.5%**. Full-precision `lost_percent` from the three
interleaved 160 Mbit reps that established the n=1 anchor — read from the JSON, not from the
rounded table in `01_capacity.md`:

| rep | `sum_received.lost_percent` | clean at ≤0.5%? |
|---|---|---|
| `i1_160M` | 0.3579148 | ✅ |
| `i3_160M` | **0.5005557** | ❌ **by 0.0006 pp** |
| `i5_160M` | 0.0665074 | ✅ |

**One rep in three classifies the anchor rung as not clean.** The instrument this round reuses,
`measure_bmv2_capacity.sh`, runs **one 8 s rep per rung**, so the highest-clean-rung decision
inside an arm rests on a single draw from a distribution the threshold bisects.

This is the same defect `01_capacity.md:27` names as having invalidated the first capacity
measurement — one rep per cell, so rung-to-rung differences are drowned by within-rung variance.
**§7 fixed the replication unit at the arm level; it did not fix it at the rung level, and the
clean-rung determination lives at the rung level.**

**Consequence, stated before the data:** the ladder has no rung between 110 and 160, so n=1
reports either 160 or 110 on one 8 s coin flip — a **31% swing in the anchor of the entire
curve**, larger than the 20 Mbit that separates the two models at n=2 (138 vs 118), which is the
separation this round exists to measure.

### The amendment

1. **Ambiguous band ⇒ 3 reps, scored on the median.** Any rung whose first rep lands in
   **0.2% ≤ loss ≤ 1.0%** is repeated to 3 reps and scored on the **median**. Below 0.2% and
   above 1.0%, one rep stands. Median rather than mean because the 160M triple's median is
   0.358% — clean and stable — while its mean is dragged by the tail rep.
2. **The budget comes from the bottom of the ladder**, following the rule HANDOFF-CONTEXT §4
   wrote down in advance: rungs `1 2 3` Mbit are almost certainly clean at every n, so they run
   one rep and are dropped first if an arm exceeds its time box. **Never drop from the top.**
3. **Nothing else changes.** Intervals, cell order, replication unit, both-readouts, the load
   gate, and the abandon criterion stand as registered in §1–§9.

### What this amendment does not do

It changes no registered interval and no prediction, and it *cannot*: no data from this round
exists to have suggested one. It changes only how a single rung is scored, in the direction of
more evidence per decision.

**[Co-developed with claude code -- Adam]**

---

## 11. AMENDMENT-2 — registered 2026-08-28 ~20:0x by `8/28 mainDev`, still before any arm data

Two tightenings required by `8/28 auditor` on AMENDMENT-1, plus three cross-checks found in
08-15 material that nobody had used. **No cell of this round has been measured.** The only traffic
this instrument has sent is four labelled runs in `raw/smoke_*` — instrument validation, not cells.

### 11.1 The ambiguous band was reverse-engineered. Replacing it with a rule that has no tunable edge.

AMENDMENT-1 set the band at 0.2%–1.0%. The auditor's objection is correct and the arithmetic is
worse than the objection states:

| | ratio |
|---|---|
| measured within-rung spread at 160M (0.0665 / 0.3579 / 0.5006) | **7.53×** |
| AMENDMENT-1's band (0.2 → 1.0) | 5× |

**The measured noise is wider than the band meant to contain it**, and the band's edges were placed
by looking at where 160M's three reps happened to land — using a result to set a rule, even though
the data is old.

But the 100M triple shows the deeper problem: **0.0000 / 0.3892 / 0.0238**. One rep at that rung
lost *no datagram at all* while another lost 0.389%. A spread that includes an exact zero is not
multiplicative, so **no ratio-based band can be derived from it**, and widening 0.2 to 0.1 would
just be a smaller arbitrary edge.

⇒ **Registered rule, replacing AMENDMENT-1's band:**

> **Any rung whose first rep reports loss > 0.0000% is repeated to three reps and scored on the
> median. Only an exact 0.0000% — not one datagram lost — is settled by a single rep.**
> Above **2.0%** a single rep stands and the rung is dirty.

**Why an exact zero is the one reading a single draw can settle:** it is the only value on this
scale with a hard physical floor. Every nonzero reading on this fabric sits in a distribution
whose observed within-rung span reaches 0.5006 at a rung that is genuinely clean, so no nonzero
reading is licensed as "safely far from 0.5%". This removes the tunable lower edge rather than
choosing a defensible value for it, and it is strictly more replication than either
AMENDMENT-1 or the auditor's suggested widening.

**Why 2.0% at the top is not the same kind of arbitrary:** the largest within-rung spread observed
anywhere is 0.5 percentage points *absolute*. A rung reading above 2.0% would have to move four
times that to reach the threshold. The cost of being wrong there is also asymmetric — a rung
misclassified as dirty cannot become the *highest clean rung*, which is the only quantity extracted.

#### 11.1(b) — the hole in the rule above, found while validating it, and closed

Validating this rule, 160 M/flow at n=1 read **exactly 0.0000%** — while the three reps of the
same rung in `capacity_interleave` read 0.0665 / 0.3579 / 0.5006. **An exact zero and a 0.5006
come from the same rung.** So "zero has a hard physical floor" justifies that *no datagram was
lost on that draw*; it does **not** establish that the rung's median is safely below 0.5%.

That hole can only change the answer in one place: the rung finally reported as the **highest
clean** one. A rung wrongly called clean lower down is invisible — a higher clean rung supersedes
it. A rung wrongly called clean at the top *is* the answer.

⇒ **Registered:** the rung finally reported as the highest clean rung is **re-confirmed with three
reps and scored on the median, regardless of its first reading.** If the confirmation fails, the
ladder walks down to the next clean candidate and confirms that one. Both the first reading and
the confirmation are recorded, so a disagreement between them is visible rather than overwritten.

Cost is two extra reps per arm. This closes the hole at the only rung where it can alter the
result, rather than paying three reps at every zero-reading rung.

### 11.2 The load gate measures the wrong quantity. Switching to the one §6 already collects.

**Decision: option B.** Registered now, before any arm data.

The auditor measured, independently and with `/proc/<pid>/stat` differencing rather than `ps`
lifetime averages: total CPU across the `agy` instances was **209.3%** while `load1` read **6.11**.
This machine has **14 cores** (`nproc` = 14, verified here). 209.3% of 14 cores is ~15% utilisation
with twelve cores idle.

`load1` counts uninterruptible sleep and is a one-minute decaying average ⇒ **lagging and
composite**. On a 14-core box `load1 max > 3.0` measures neither "is the machine busy now" nor
"how busy".

⇒ **The gate becomes the in-window busy fraction from `/proc/stat` deltas — the quantity §6 was
already sampling every 2 s.** §6's *relative* clause is retained verbatim: an arm is rerun if its
in-window busy fraction exceeds the median arm's by more than **0.15 absolute**. The absolute
`load1 > 3.0` clause is **withdrawn**; `load1` is still recorded in `arm.meta` as a coarse
pre-screen, and is no longer a gate.

🔴 **The reason this is not "moving a threshold because it blocked me"**, which would be the worst
possible justification: the absolute clause would have fired on **the arm's own forwarding load**.
This round's premise is that bmv2's bottleneck is per-packet CPU, so an arm pushing 160 Mbit
through ten software switches raises `load1` *by working correctly*. A gate that fires on the
signal it exists to protect cannot discriminate contamination from operation. That defect holds
whether or not the gate is currently in my way — and at the moment of this decision it is **not**:
`load1` is 2.53 with zero `agy` running, so both option A and option B permit the run to start.

### 11.3 Three things found in 08-15 material, recorded before the run

The auditor flagged that the receiver-bottleneck sweep's candidate list came from a keyword grep,
so rounds whose prose avoids those words were never in it. `doc/2026-08-15_bmv2-performance-report.md`
is one such round.

1. ✅ **The receiver control §5 asks for already exists.** Loopback h1→h1 measured **42.4 Gbps**
   (stock) and **63.5 Gbps** (bmv2-fast) — roughly 400× above the top of this ladder. §5's
   receiver null check should **cite this**, not re-derive it.

2. 🔴 **A landmine for §5's interface readout.** That round measured loss occurring *inside the
   bmv2 process's input buffer*, where a per-interface drop counter cannot see it: h1 sent 89,296,
   `s1-eth3` RX recorded 89,296 with zero interface-level loss and zero packet-socket movement,
   while `s1-eth1` TX was only 33,456. ⇒ **§5's `/proc/net/dev` readout is only informative read as
   ingress-port RX versus egress-port TX on the same switch.** Read as per-interface drops it
   reports zero while a third of the traffic is disappearing. The runner captures both sides; the
   analysis must pair them, and this round's report must state which pairing it used.

3. ⚠️ **A cross-check to explain, not to reconcile against.** That round put bmv2-fast's UDP
   zero-loss point at **300 Mbps** (1400 B, 3-hop h1→h2, **4-host** fabric); today's anchor is
   ~160 Mbit (2-hop h1→h65, **128-host** fabric). Same binary family, different fabric size and
   path length. This is registered as an **open observation**: if the 128-host fabric roughly halves
   single-flow capacity, that is a table-occupancy effect, which is precisely the confound §2 avoids
   by separating flows with ports rather than host pairs. **It is not a number this round's n=1 cell
   is required to agree with**, and agreement or disagreement with it proves nothing on its own —
   the same rule §1 applies to the 12 Mbit figure.

**[Co-developed with claude code -- Adam]**
