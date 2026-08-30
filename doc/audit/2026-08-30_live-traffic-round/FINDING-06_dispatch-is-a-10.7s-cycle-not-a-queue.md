# Finding 06 — the table view is **blind for up to 10.7 s**; the rule is programmed in ~20 ms

> **🔴 CORRECTED 2026-08-30 22:10, and the correction changes the severity, not the numbers.**
> The first version of this file was titled *"the exposure window is a 10.70 s dispatch cycle"*
> and read the window as **time the rule is not on the switch**. That is wrong. The rule reaches
> the switch in ~20 ms. The 10.70 s is the refresh period of the **kernel's cached table view** —
> i.e. of my own instrument's upstream. Mechanism traced to source by `mainDev` during A-7,
> relayed by the `8/29 auditor`; every anchor re-read here, and then measured directly.
> **Old reading:** a rule may sit unprogrammed for 10.7 s.
> **New reading:** a rule is programmed at once and the twin **cannot see it** for up to 10.7 s.
> Everything below is the corrected text. What survived and what died is itemised at the end.

**Status: CONFIRMED (corrected), 2026-08-30.** Round: live-traffic (full-stack #3), P4/BMv2,
kernel `1208d22`. **System** finding.

[Co-developed with claude code -- Adam]

---

## The measurement that decides it

One POST, two readers polled concurrently: the **P4 proxy's `/stats/flow/<dpid>`** (its read of
the switch) and the **kernel's `/ndt/get_switch_openflow_table_entries`** (the cached view).

| rep | southbound has the rule | kernel view: phantom | kernel view: real entry | gap |
|---|---|---|---|---|
| 1 | **t+0.02 s** | t+0.01 s | t+2.22 s | 2.21 s |
| 2 | **t+0.02 s** | t+0.01 s | t+1.31 s | 1.30 s |
| 3 | **t+0.01 s** | t+0.01 s | t+10.04 s | 10.02 s |

**The switch has the rule within 20 ms, every time.** The kernel's view publishes it 1.3–10.0 s
later, and that lag is the distance to the next cache refresh — which is why it scatters while
the southbound number does not.

## The mechanism, from source

Four anchors, each re-read rather than taken on relay:

1. **The dispatch path has no clock.** `FlowDispatcher::workerLoop_` is
   `cv_.wait(lk, …!queues_[dpid].empty())` → `sender_(burst)`. It wakes on work and sends. There
   is no sleep in it.
2. **The 10 s period is the view cache.**
   `DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker` (`:1877`) fetches, does
   `m_cachedOpenFlowTables = std::move(newTables)` (`:1890`), then `// 3. Sleep for 10 seconds`
   (`:1900`). **10.70 s ≈ 10 s fixed sleep + ~0.7 s poll.**
3. **The phantom is a synchronous write into that same cache.** `HttpSession.cpp` calls
   `dispatcher().enqueue(...)` and then, under `// TODO: Immediately update the table`,
   `m_deviceConfigurationAndPowerManager->updateOpenFlowTables(j)` — on the HTTP thread, with the
   raw request body.
4. **My instrument read that cache.** `HttpSession.cpp:622` serves
   `getOpenFlowTables()`, which is `return m_cachedOpenFlowTables;` (`:1944`) under a shared lock.

⇒ So the "programmed at" I measured was **"the next cache overwrite made it visible at"**.
🔑 This is `memory: instrument-must-not-mimic-its-own-finding` one layer further out than the two
instances already recorded in this round: the period I measured belonged to my reader, not to the
system under test. The give-away was available and I did not use it — *the phantom appears
instantly and the real entry appears on a clock* is the signature of two different write paths
into one store, not of a queue draining.

## The simultaneity result survives, and is now explained

Eight rules posted 3 s apart became visible in three bursts — 4, 3 and 1 — each burst internally
within **0 ms**, gaps 10.71 and 10.65 s; a second run gave 10.76 and 10.68 s. Pooled: **10.70 s,
sd 0.05 (n=4)**.

That is exactly what a single `m_cachedOpenFlowTables = std::move(newTables)` predicts: everything
the poll picked up becomes visible in the same assignment. The observation was right and its
interpretation was wrong — it is evidence about **one shared cache**, not about one dispatch tick.

## What this means for anyone reading the twin

* **The twin's table view can be up to ~10.7 s stale**, and during that window it serves a
  *request-shaped echo* of pending installs alongside genuinely polled entries. A consumer that
  POSTs and reads back gets its own request reflected, not switch state.
* **The severity is "blind", not "not installed".** Anything built on "the rule is not there yet"
  is built on the retracted reading. **T-11-A** (Adam's ruling: the table listing reports only
  programmed entries) turns on exactly this distinction.
* The source already knew part of it: `DeviceConfigurationAndPowerManager.cpp:2001` records
  *"measured: dpid 999999999999 visible for ~7s, until openflowTablesUpdateWorker re-polled Ryu
  and overwrote the cache."* **That ~7 s is one draw from the same [0, 10.7] phase distribution** —
  the same single-sample-reads-as-a-bound error this round has now made twice and found twice.
  The period is 10.70 s; ~7 s is a sample of the wait, not the period.

## Retracted, and what stands

| claim in the first version | status |
|---|---|
| title: "a 10.70 s **dispatch** cycle" | **RETRACTED** — it is the table-view cache refresh |
| "the phantom ends exactly when programming begins" | **RETRACTED** — it ends when the cache is overwritten; programming was ~20 ms in |
| "no load can exceed the bound / contention cannot lengthen it" | **RETRACTED** — the 10 s sleep is fixed, but the poll it precedes scales with fabric size (699 ms for paths at 128 hosts vs 1 ms at 4) |
| "up to 10.7 s **unprogrammed**" | **RETRACTED** → up to 10.7 s **invisible** |
| the window exists, upper bound ~10.7 s, phase-distributed | **stands** |
| 10.70 s ± 0.05, n=4 | **stands**, now attributed to the right component |
| rules posted apart become visible at one instant, 0 ms spread | **stands**, and is now explained |
| TR-3's registered answer: contention does not change the window | **stands**, for a better reason — a fixed sleep dominates it |
| the max−min discriminator announced the wrong verdict on correct data | **stands** (below) |

## 🔴 A discriminator that announced the wrong verdict on correct data

`tr3_simultaneity.py`'s first verdict compared `spread(programmed)` with `spread(posted)` and
printed **"PER-RULE"** over the eight-rule table above — the most periodic data in the round. A
grid and a per-rule schedule have the same max−min spread once the posts span more than one
period, so the statistic is blind to the structure it was written to find. It could go red and it
could go green; it just could not tell the two apart, and it announced a verdict anyway. The
verdict now comes from clustering (`tr3_grid_analyse.py`). Ask of any discriminator: **what would
the data look like under the other hypothesis, and does this statistic differ between them?**

## Reproduce

```bash
. doc/audit/2026-08-30_live-traffic-round/harness/round.env
/usr/bin/python3 doc/audit/2026-08-30_live-traffic-round/harness/tr3_programmed_vs_visible.py --octet 250
```

Artefacts: `raw/arm4-f06-check/` (the three reps), `raw/arm1-p4-128/tr3_simult-{grid,idle}.tsv`.

## Not established

* **The southbound reader is the proxy's view, not the BMv2 table itself.** It is one layer
  closer to the switch than the kernel cache, and it disagrees with the kernel view by 1.3–10 s,
  which is what the argument needs. A `simple_switch_CLI table_dump` would close the last layer
  and was not run.
* **Whether the poll's ~0.7 s scales badly enough to matter at larger fabrics** is not measured;
  the 10 s sleep dominates at every size tested.
* **OVS is untested** for this mechanism.
