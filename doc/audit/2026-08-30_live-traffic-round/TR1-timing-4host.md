# TR-1, timing half — answered on a 4-host fabric, with traffic

**2026-08-30 21:41–21:51 CST.** Arm 3: P4 / BMv2, **4 hosts**, 10 switches, kernel `1208d22`.
Run because the 128-host arm made this question structurally unmeasurable, not because 128 hosts
gave an inconvenient answer — the reason is arithmetic and is stated in [RESULTS.md](RESULTS.md).

[Co-developed with claude code -- Adam]

---

## The instrument kept its schedule this time

| | 128-host arm | **4-host arm** |
|---|---|---|
| samples | 833 | **1200** |
| overruns | **832 (50.0 %)** — section 2 declared unusable | **0 (0.0 %)** |
| effective rate | 0.818 Hz (asked 2 Hz) | **2.001 Hz** (asked 2 Hz) |
| HTTP | 200 ×833 on all three endpoints | 200 ×1200 on all three |

The ladder is now much shorter than the thing it measures, which is the precondition R-2 needs
and has never had: T-4 had the resolution but an **empty** flow set, the 128-host arm had a full
flow set but **no** resolution. This arm has both.

## What a consumer actually sees

Traffic: 2 base pairs at 10 Mbit/s plus 6 never-before-used churn pairs, one every 30 s.
**7 flow keys observed, 6 of which changed at least once.**

```
inter-change intervals (s):  n=56   min=0.50   p50=28.01   p95=60.01   max=60.52
intervals in [50,70] s : 3  (5 %)
intervals < 1 s        : 3  (5 %)
```

| consumer cadence | polls | changes | app |
|---|---|---|---|
| 1 s | 599 | 56 | viz, te (`NetworkTopologyApp.java:424`, `Traffic-engineering-App.py:41`) |
| 5 s | 119 | 50 | nsr (`recorder_setting.yaml:5`) |
| 15 s | 39 | 48 | **PREREG §3 R-2's registered cadence — used by no app** |
| 60 s | 9 | 25 | energy (`settings.hpp:8`) |

## R-2: **no consumer-visible difference** — but not for the registered reason

The 1 kHz → 1 Hz recompute change is **not observable by any consumer**, and the evidence is the
shape of the distribution rather than the absence of an effect:

* **p95 = 60.01 s, max = 60.52 s.** The intervals are capped just above 60 s. That ceiling is the
  refresh thread (`memory: destination-paths-not-monotonic`), not the recompute.
* **p50 = 28.01 s.** The median value a consumer reads survives ~28 s unchanged.

Both timescales are **one to two orders of magnitude slower than 1 Hz**. A recompute at 1 kHz and
a recompute at 1 Hz are both far faster than the rate at which the value a consumer can read
actually changes, so the change is masked by whatever governs the 28–60 s band. **R-2's registered
expectation is met and its stated reason is wrong**: it rested on "consumers poll on a 15 s
cadence", and no app does — three of five poll *faster* than 1 Hz. The conclusion survives the
premise's failure, which is worth saying explicitly rather than quietly reusing the verdict.

🔑 This is the only branch of R-2 that was ever decidable from outside. The recompute *rate* is
not observable through the API; what is observable is how often the value changes. Nothing here
is evidence about the recompute rate itself, and none is claimed.

## 🔴 Three intervals under 1 second are NOT explained

`min = 0.50 s`, and 3 of 56 intervals are sub-second — faster than the 1 Hz recompute they are
supposed to be downstream of. The analyser flags exactly this and says it "needs explaining
before R-2 is called 'no observable difference'".

**It has not been explained.** Candidates, none tested: a sampling artefact at the 0.5 s
boundary; two different flow keys aliasing into one; a genuine event-driven update path separate
from the periodic recompute. 5 % of the sample is small but it is the *only* part of the
distribution inconsistent with the story above, which is precisely why it should not be rounded
away. Registered as the first thing to look at next round.

## Limits, stated

* **7 flow keys.** A 4-host fabric with 8 pairs cannot produce many. The percentiles are computed
  on n=56 intervals and should be read as shape, not as precision.
* **One arm, one run.** No OVS comparator for the timing half.
* **The per-pair datapath ledger for this arm is not usable** and its numbers are not quoted
  anywhere: with 4 hosts each host is the source or sink of several pairs at once, so host-level
  `tx/rx` counters cannot be attributed per pair (the script says so at the foot of its own
  report). The aggregate is valid — **offered 239.57 Mbit/s, delivered 239.57, ~0 % loss** — and
  the aggregate is what PREREG §2 asks for.
