# §6 reconciliation — E round against prior results

PREREG §6 (Adam's standing rule: every experiment states what it overturns, updates, or can be
compared with). 🔴 **Constraint ② governs everything below: cross-binary comparisons may use
direction and rung-distance only, never per-cell values.** 🔴 **Constraint ③: the comparison is
cross-interpreter; the permitted wording is *"there is currently no evidence this axis moves the
numbers"*, never *"it has been shown not to"*.**

---

## 1. UPDATED — "取樣天花板 ≈1/16" (the pre-change binary's figure)

**This round: `SATURATED = 0` across all 72 cells ⇒ the telemetry-fidelity ceiling is
right-censored at ≥1/1 for all four arms.**

* **Direction:** higher.
* **Rung-distance:** ≥4 rungs above 1/16.
* **No per-cell values compared** (constraint ②).

🔴 **And the ceiling that moved is the telemetry-fidelity ceiling.** At ≥1/1 the data plane loses
**85%** of offered traffic (F-26). A reader taking "ceiling ≥1/1" as an operating recommendation
would be reading a sentence this round did not write.

---

## 2. BOUNDED AND EXTENDED — `telemetry-cost-is-fixed-not-per-sample`

⚠️ **Read this caveat before the numbers: the round was not designed to measure this.** §6 obliges a
re-test, and the obligation is discharged with data collected for another purpose. Every figure is a
**lower bound** — `mine` truncates at top-10 (F-21) — with n = 3–4 per rung, cross-binary and
cross-round, so **direction and magnitude-class only.**

Measured within a **single arm and a single leg** (`bl` — the only arm spanning all eight rungs), so
neither the batching aliasing (F-28) nor the leg confound (F-27) touches it:

| rung | n | kernel cores | proxy cores | switches |
|---|---|---|---|---|
| 1/1024 | 4 | 0.551 | 0.064 | 1.426 |
| 1/256 | 3 | 0.568 | 0.095 | 1.374 |
| **1/64** | 3 | **0.665** | **0.243** | 1.519 |
| 1/32 | 3 | 0.776 | 0.393 | 1.584 |
| 1/16 | 3 | 0.995 | 0.694 | 1.691 |
| 1/8 | 3 | 1.478 | 1.409 | 2.074 |
| 1/4 | 3 | 1.472 | 1.457 | 1.538 |
| 1/1 | 3 | 1.494 | 1.403 | 1.037 |

### ✅ Instrument cross-validation at 1/64 — the most load-bearing line in this entry

`2026-08-20_sampling-rate-and-cpu/REPORT.md:101` records the 1/64 cell **with sampling on** as
**kernel 67.9% / proxy 26.6%**. This round's `bl` at 1/64: **kernel 66.9% / proxy 24.3%.**

**Within 1.0 and 2.3 points — different round, different binary, twelve days apart.**

🔑 **Without this, "the new round says cost grows" and "the new round changed the ruler" are
indistinguishable.** It is the known-good output this entry is checked against, and it happened to
be in hand.

⚠️ **The 1/1024 comparison could NOT be made.** The prior round's `m*` per-cell CPU raws are not in
the working tree (only `t00*`, `cal*`, `f16*`, `qa/qb*` and this round's `e_*`), and no quoted figure
was located. **A 1/1024 cross-check was suggested to me; I am not citing a number I could not
verify.**

### The claim is bounded, not refuted

The prior's behavioural fingerprint was computed over **1/1024 → 1/64** (`2026-08-25_sampling-rounds/PREREG.md:95`).

| range | rate | kernel | verdict |
|---|---|---|---|
| 1/1024 → 1/64 (**the claim's own range**) | ×16 | 0.551 → 0.665 = **×1.21** | ✅ **confirmed** — nearly paid at the lowest rate |
| 1/64 → 1/8 (**outside it**) | ×8 | 0.665 → **1.478** = **×2.22** | 🔴 the claim does not extend here |

⇒ **Wording: "independently confirmed within its own range (and cross-validated at 1/64 to ~1–2
points); above 1/64 kernel cost rises ×2.2."** 🔴 **Not "the claim is false"** — it was right where
it was measured. **The over-extension was ours, not its.**

### 🔴 The proxy ×22 is a NEW result, not a refutation of anything

The prior claim is **entirely about kernel threads** — `calFlowPathByQueried` at 46.31% CPU, single
thread (`2026-08-25_large-scale-concurrent/PREREG.md:642`), and `run` ×3.48 for ingest. **The proxy
was never in its scope.**

⇒ **Proxy CPU rising 0.064 → 1.409 (×22) across 1/1024 → 1/8 is a new finding and is reported on its
own.** Filing it under that memory would be **using something the memory never claimed in order to
overturn it** — the fourth instance tonight of a population being asked to answer to a name that is
not its own.

⚠️ **The 1/4 and 1/1 rows are not a cost plateau.** The data plane had collapsed, so fewer packets
existed to sample; the switch figure falls with them (2.074 → 1.538 → 1.037).

---

## 3. Comparable — 08-20 `t008_poll` / `t004_poll`, and that round's own ladder boundary

`plot_ladder_rates.py:60-65` records the 08-20 round seeing `gt` collapse 196 → 29.5, excluding
those cells from its quantisation ladder, and naming **1/16 as "the last healthy cell" (0.025%
loss)**; its `CELLS` list ends at `r016`.

* **Direction — same.** `gt` collapses at high sampling rates in both rounds.
* **Rung-distance — the last healthy rung moved 1/16 → 1/8, one rung higher.**
* No per-cell comparison (constraint ②).

---

## 4. Reproduced then extended — `gate_e.out` (1/256) and `wall_f.out` (1/16)

Prior: batching did not move `ratio` at either working point.

* **Consistent at both** — stated without the confounded contrast: at 1/32 and 1/16 **all four
  arms sit at ~1.00** (max deviation 0.0031), so nothing measurable moved there, by batching, by
  period, or by their interaction. ⚠️ Δ(m−bl) would itself be a **cross-leg** comparison and is not
  used.
* **Extended:** at 1/8 the unmerged 1 kHz arm sits 3% low and the merged one does not — a working
  point the prior never covered.
* It is a **rise**, not the *fall* §6 registered as a conflict ⇒ **not the anticipated conflict,
  and not "the prior was wrong."**

---

## 5. 🔴 SELF-CORRECTION — my own leg-1 reading, twice downgraded, and it was relayed

* **First stated** (03:31, to the auditor and to Adam): the 1/8 separation is *"the recompute axis /
  Q2's factor"* — a **main effect**.
* **First downgrade** (06:50): four arms show it is an **interaction**; neither axis has a main
  effect.
* **Second downgrade** (07:3x, F-27): the 2×2 **does not share a time window** — `bl` vs `p` ran
  02:57–03:29 and `m` vs `mp` 06:14–06:46. The within-leg contrasts are measurements
  (**−0.0292** and **−0.0009**); the interaction is their **difference, +0.0282**, valid only if
  the period does not modulate the contrast. **Untested and untestable from this round.**

**Both corrections were relayed back to the original readers, not left in the file.**

---

## 6. Consistent — D-P1's per-byte hypothesis (already refuted)

08-25 §D-P1 predicted that *if* proxy cost were **per byte**, the wall would move about an order of
magnitude and **1/8 and 1/4 would become healthy**. That hypothesis was refuted; the cost is
per-sample. ⇒ **1/4 being data-plane-hurt is consistent with the refutation**, not a fresh surprise.
⚠️ Note the tension with §2 above: cost is **not fixed** and **not per-byte**; §2 measures how it
actually scales at this working point, and does not identify a mechanism.

---

## 7. 🔴 RETRACTED — must not be cited

The **"~4,900 samples/sec ceiling"** extrapolated from 206 µs/sample (`ab-control-deleted-nothing`).

---

## 8. Not discharged

**Nothing in §6 is left unanswered**, but two items are answered with data gathered for another
purpose (§2) or under an untested assumption (§5). Both say so in place.

[Co-developed with claude code -- Adam]
