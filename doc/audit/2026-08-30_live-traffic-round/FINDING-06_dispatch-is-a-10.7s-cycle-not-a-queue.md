# Finding 06 — the "exposure window" is a **10.70 s dispatch cycle**, not queue pressure

**Status: CONFIRMED, 2026-08-30 21:07–21:14 CST.** Round: live-traffic (full-stack #3), arm 1,
P4 128 hosts, kernel `1208d22` (sha256 `66f437a5…`). This is a **system** finding. It answers
TR-3's registered question and it revises T-4's FINDING-03 without contradicting any of its data.

[Co-developed with claude code -- Adam]

---

## TR-3 asked whether the window grows under contention. It does not — it is a clock.

PREREG §3 TR-3: *"does the queued-but-unprogrammed exposure window grow under contention?"*

**No.** The interval between a `200` from `POST /ndt/install_flow_entry` and the rule actually
being programmed is the distance from the POST to **the next tick of a 10.70 s cycle**. It is set
by a clock, not by how much work is queued, so load cannot lengthen it and an idle fabric cannot
shorten it.

## The observation that settles it

Eight rules, posted 3 s apart, each to its own unused destination, watched continuously from
before the first POST (`tr3_simultaneity.py --n 8 --spacing 3`):

| requested priority | destination | posted | **programmed at** |
|---|---|---|---|
| 920 | 10.0.0.230 | …250.364 | **…260.335** |
| 921 | 10.0.0.231 | …253.405 | **…260.335** |
| 922 | 10.0.0.232 | …256.383 | **…260.335** |
| 923 | 10.0.0.233 | …259.386 | **…260.335** |
| 924 | 10.0.0.234 | …262.367 | **…271.050** |
| 925 | 10.0.0.235 | …265.385 | **…271.050** |
| 926 | 10.0.0.236 | …268.383 | **…271.050** |
| 927 | 10.0.0.237 | …271.381 | **…281.702** |

**Four rules posted nine seconds apart were programmed at the same instant, to within 0 ms.**
A per-rule schedule cannot do that; it would reproduce the posting spread. Inter-cycle gaps:

```
grid run  : 10.71, 10.65 s
idle run  : 10.76, 10.68 s          (4 rules, 5 s apart -> 3 cycles)
pooled    : mean 10.70 s, sd 0.05 s  (n=4 independent gaps)
```

Consequences that follow directly, and are worth more than the number:

* the window has a **hard upper bound of ~10.7 s** that no load can exceed;
* its **mean is ~5.35 s**, and its distribution is the POST's phase within the cycle — which is
  why single measurements scatter so widely (observed 0.89 s … 11.3 s) while the *cycle* is
  stable to 0.5 %;
* **the phantom ends exactly when programming begins** — handover measured at 35–55 ms, one
  sample period. There is no gap in which the rule is neither pending nor installed.

## The API says so itself, and that is worth quoting

The `200` from `install_flow_entry` is not a claim that the rule is installed:

```json
{"accepted":1,"status":"queued",
 "detail":"entries accepted for programming; per-entry outcomes are reported in the kernel log,
           not in this response"}
```

So the queue-then-dispatch model is **deliberate and documented in the response body**. This
finding is not "the kernel lies about installing rules" — it says `queued`, and it means it.
What was not knowable from the outside until now is *how long* `queued` lasts and what governs
it: up to 10.70 s, governed by a cycle, with a mean of ~5.35 s.

The consumer-facing consequence is the pairing of that window with the phantom: for those
seconds `GET /ndt/get_switch_openflow_table_entries` returns the rule **as though it were a table
entry**, carrying the requested priority and no counters. A caller that POSTs and then reads back
to confirm gets a confirmation either way, and the two answers differ (see
[FINDING-07](FINDING-07_install-flow-entry-drops-the-priority.md)).

## What this revises in T-4 FINDING-03, and what it leaves standing

FINDING-03 recorded the phantom present at t=0 and absent at t=2 s, on a quiet 4-host fabric.
**Every one of those numbers is still right.** What changes is the reading:

| | FINDING-03's reading | what it actually was |
|---|---|---|
| "absent by t=2 s" | the window is short | that POST landed ~2 s before a cycle tick. A phase draw, not a bound. |
| the disappearance | the pending entry is dropped | the rule is **programmed** at that instant (see [FINDING-07](FINDING-07_install-flow-entry-drops-the-priority.md)) |

🔑 FINDING-03's own sharpest line was that 08-18 "sampled a grid whose first rung is past the
event". The same shape one level up: a **single** observation of a uniformly-distributed quantity
reads as a bound. Neither round was careless; both were sampling a phase without knowing there
was a cycle to have a phase in.

## Why "contention lengthens it" was the wrong answer, and how it nearly got recorded

Measured under the traffic block (8 pairs at 10.29 Mbit/s + churn at 5.15, datapath-verified),
two reps gave **4.1 s and 11.3 s**, against T-4's 2 s. That is a 2–6× "growth" and it fits the
registered hypothesis exactly. It is also meaningless: the idle control at the *same* working
point gave **2.0 s and 6.8 s**, and six idle reps spanned **1.1–9.0 s**. The arms overlap
completely, because both are draws from the same [0, 10.7] distribution.

Three variables had changed at once between T-4 and the first contended measurement — load,
fabric size (4 → 128 hosts), and rule subject (invalid → valid). Attributing the difference to
the registered one would have been arithmetic that fits, not a mechanism.

**What broke the tie was not more reps.** Six idle reps only produced a wider range. The
staggered run then showed disappearance times ~10× more regular than the POSTs that caused them
(σ 0.22 s vs 2.3 s), which *suggested* periodicity — and a suggestion that fits is still not a
mechanism. The test that settled it made the two stories disagree about an observation neither
had made: post rules at different times and see whether they land together.
(memory: `replication-unit-not-the-rep`, `arithmetic-that-fits-is-not-the-mechanism`.)

## 🔴 A discriminator that announced the wrong verdict on correct data

`tr3_simultaneity.py`'s first verdict compared `spread(programmed)` with `spread(posted)` and
printed **"PER-RULE (A)"** over the eight-rule table above — the most periodic data in the round.

A grid and a per-rule schedule have the *same* max–min spread as soon as the posts span more than
one period, so the statistic is blind to the structure it was written to find. It could go red
and it could go green; it simply could not tell the two apart, and it announced a verdict anyway.

This is the mirror shape from `memory: failures-that-report-success`, and the force-red table
would not have caught it: every recipe there tests the refusal direction. The question that
catches it is **"what would the data look like under the other hypothesis, and does this statistic
differ between them?"** The verdict now comes from clustering (`tr3_grid_analyse.py`), which reads
the run's own TSV, so it can be re-derived and argued with without touching the lab.

## Reproduce

```bash
. doc/audit/2026-08-30_live-traffic-round/harness/round.env
python3 doc/audit/2026-08-30_live-traffic-round/harness/tr3_simultaneity.py \
        --n 8 --spacing 3 --watch 30 --first-octet 230 --label simult-grid
python3 doc/audit/2026-08-30_live-traffic-round/harness/tr3_grid_analyse.py
```

Artefacts: `raw/arm1-p4-128/tr3_simult-grid.tsv`, `tr3_simult-idle.tsv`,
`tr3_f5_window_{contended-valid,idle-valid,idle-invalid,period}.tsv`.

## Not established, stated so it is not read as covered

* **The source of the 10.70 s period has not been located in the code.** It is measured
  behaviour, not a read constant. Until someone names the timer, "10.70 s" is an observation
  about this build at this working point.
* **OVS is untested.** Everything here is the P4/BMv2 arm. Whether the same cycle governs the
  Ryu path is open, and F-5's original OVS phantom is a different question again.
* **Fabric size is uncontrolled.** All of this is at 128 hosts. Whether the period is the same at
  4 hosts — where T-4 measured — was not tested, and it is the one comparison that would let this
  finding speak directly to T-4's numbers rather than merely reinterpret them.
