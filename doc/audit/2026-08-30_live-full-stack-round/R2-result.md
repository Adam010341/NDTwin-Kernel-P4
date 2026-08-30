# R-2 — measured, and then measured again with the right key

PREREG §3 R-2: path recompute went 1 kHz → 1 Hz (`2f57ba5`); registered expectation **"no
observable difference"** to consumers. Sample: 1800 records, `--fabric p4 --seconds 900
--interval 0.5`, 2026-08-30 15:09:20–15:24:20.

---

## Sampler health — read before any result

| | |
|---|---|
| samples | **1800** |
| overruns | **0 (0.0 %)** |
| wall span | 899.7 s |
| effective rate | **2.001 Hz** |
| `flows` / `graph` / `paths` | `http={200: 1800}` each, **zero transport errors** |

The sampler resolved what it was asked to resolve. Nothing below is limited by it.

## 🔴 The analyser's §2 could not name the field — and correctly refused to conclude

```
JSON key(s) treated as the path field: NONE FOUND
🔴 No path-like key was found in any sample. … Do NOT report 'paths never changed'
   from this: an absent key is not a stable value.
```

`find_paths()` in `35_r2_r3_analyse.py` tries a list of candidate names; the real key is
**`all_destination_paths`**, which is not among them. Read straight out of a raw body:

```json
{"status": "success",
 "all_destination_paths": [[["10.0.0.1",3],[1,1],[5,2],[2,3],["10.0.0.2",0]], …]}
```

🔑 **Same shape as R-1's**: a zero produced by searching for a name the service does not use.
`PRE-ROUND-R1-determination.md` states the criterion this violates — *establish against the
service side that the name exists, then establish zero against the other side.* §2 did stage 2
without stage 1.

**The guard is the good news.** Unlike `40_r5_p4.sh`'s manifest count — which turned a missing
key into a confident `0` via `d.get("switches", [])` and gated on it — §2 recognised that it had
found nothing and refused to emit a verdict. Two scripts in one harness, opposite handling of
the same situation, and this one is right.

## Re-derived by hand with `all_destination_paths`

| quantity | value |
|---|---|
| samples carrying the key | **1800 / 1800** |
| distinct path-set values over 900 s | **1** |
| paths per sample | **12**, in every sample |
| transitions at 2 Hz (1799 adjacent pairs) | **0** |

At each real consumer cadence (AMENDMENT-1's measured values, not PREREG's assumed 15 s):

| cadence | who | polls | changes |
|---|---|---|---|
| 1 s | viz, te | 900 | **0** |
| 5 s | nsr | 180 | **0** |
| 15 s | *PREREG's assumed cadence — no app uses it* | 60 | **0** |
| 60 s | energy | 15 | **0** |

## Verdict — and the reason it is worth less than it looks

**Registered expectation holds: no consumer-visible difference, at any cadence.**

🔴 **But the check had almost no power to show anything else.** `flows` was `[]` in **all 1800
samples** — the network was completely quiet for the entire window, and the path set was a
static 12.

Apply the project's own criterion — *if the thing this checks were completely broken, would this
go red?* **No.** With no traffic and a static path set, a recompute at 1 kHz and one at 1 Hz
return the same twelve paths forever. A 1000× change in recompute rate is unobservable by
construction here.

⇒ R-2 is recorded as **"registered expectation confirmed, under a condition that makes it nearly
unfalsifiable"** — not as evidence the recompute change is safe. It is closer to *untestable
as run* than to *passed*.

**What would give it power**, for whoever runs it next: traffic, so the path set actually moves.
A quiet network is the one condition under which this measurement cannot fail, and it is the
condition it was taken under. `memory: controls-decide-what-you-learn`.

## ⚠️ Intrusions into the 900 s window — four, and three of them are mine

Recorded rather than subtracted.

| what | window | source |
|---|---|---|
| maven build (viz startup) | 15:09:20 – 15:12:58 (**218 s, 24.2 %**) | the round's own app-start step |
| `agy` from commit `79fa6d8` | 15:11:37 – 15:13:58 | **my commit** — the `post-commit` hook |
| `tectonic` re-compile | 15:16:25 – 15:16:45 (~20 s) | poster author, declared |
| `agy` from commit `945a411` | 15:19:42 – 15:22:54 | **my commit** |

`agy --effort high` is ~2 cores and is invisible to `ndt status`'s `measuring` field. Full
alignment across every phase of the round, including two energy watches:
**`CONTAMINATION-agy-runs-i-started-myself.md`**.

### Ruling: **annotated, usable — not voided**

The verdict this window produced is *"the path set never changed"*, and the sampler's own
health section — taken **under** the contamination — reports **0 overruns, 899.7 s span,
2.001 Hz, 1800/1800 HTTP 200**. CPU contention can make a sampler late; it did not, and it
cannot make a *changing* path set look static.

More decisively: the verdict was already **"confirmed under a condition that makes it nearly
unfalsifiable"**. Re-taking a measurement that could not have failed buys nothing. What the
next round needs is **traffic**, and that round must be clean.

⇒ **This result must not be reused as evidence in a round that gives R-2 real power.**

[Co-developed with claude code -- Adam]
