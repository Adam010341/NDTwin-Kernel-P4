# Contamination record — ten `agy` runs inside my own measurement window, all of them mine

**Status: CONFIRMED after the round, from `.git/agy-reviews/` mtimes and `git log` commit times.**
Raised by `8/29 auditor`, who flagged two of the ten. **The full alignment below is worse than
the two they had**, and the extra ones land on the energy phases, not just on R-2.

---

## The rule I broke, and why I did not know it

The auditor's GO message carried a new hard rule — *"T-4 量測窗內，本 repo（含所有 worktree）
禁止任何 `git commit`"* — because this repo's `post-commit` hook unconditionally launches
`nohup agy --effort high`: up to 900 s, ~2 cores, **invisible to `ndt status`'s `measuring`
field**, with no opt-out, and it fires from worktrees too.

That message was **queued behind my in-flight turn and arrived after the round had finished**.
I committed 11 times during the window. The rule is not retroactive, but the **contamination
is**, and the round's results have to carry it.

🔑 `memory: vm-on-this-machine-is-invisible-to-ndt-status` records this exact shape —
*"記錄實驗的動作本身污染實驗"*. I hit it again, and at a scale I did not hit before: **ten
runs, and I created every one of them.** The instrument that recorded the experiment was also
its largest uncontrolled load.

## The alignment

Start = commit time (`git log --date=format:%H:%M:%S`). End = the review file's mtime, which is
when `agy` finished writing.

| agy run | window | what it lands on |
|---|---|---|
| `79fa6d8` | 15:11:37 – 15:13:58 | **R-2 sampling** (15:09:20–15:24:20) |
| `945a411` | 15:19:42 – 15:22:54 | **R-2 sampling** |
| `569f976` | 15:32:10 – 15:35:45 | 🔴 **P4 energy watch** (15:30:54–15:35:04) |
| `adf9685` | 15:33:00 – 15:36:14 | 🔴 **P4 energy watch** + the `--f2f3-only` run |
| `5a9c13a` | 15:43:10 – 15:47:26 | restore / rebuild — not a measurement |
| `17fd816` | 15:43:45 – 15:48:16 | ditto — **this one is the `--amend`** (see below) |
| `dbfe782` | 15:49:53 – 15:54:14 | 🔴 `ndt up ovs4` + **`50_r5_ovs`** (15:51:45–15:52:23) |
| `0deb693` | 15:53:17 – 15:54:59 | 🔴 `50_r5_ovs` tail + **OVS energy watch** start |
| `c1176e0` | 15:54:38 – 15:57:18 | 🔴 **OVS energy watch** |
| `e5462e2` | 16:04:44 – 16:08:36 | after the OVS watch ended — clean |

**Concurrency, not just presence.** Two overlapped the P4 energy watch (≈174 s of its 250 s);
**three** overlapped the OVS energy watch's opening minutes. At ~2 cores each that is ~4 and ~6
cores of 14, on top of the fabric, the kernel, the app and this session.

Two further intrusions, declared by others and not mine:
* **tectonic** 15:16:25–15:16:45 (~20 s, 1–2 cores) — poster author, inside the R-2 window.
* The auditor's own reading of `945a411` assumed it might run to ~15:50; the review file's mtime
  says it ended **15:22:54**. Bounded, and inside R-2.

### The `--amend` cost a second run

`5a9c13a` and `17fd816` are the **same commit**: I amended it to repair a message mangled by
`$(...)` substitution. The hook fired on both — **50 s apart, ~4 min of ~2-core work each**.
Fixing a commit message was not free, and nothing in the workflow said so.

## What this does to each result

| result | ruling |
|---|---|
| **R-2** | **annotated, usable — not voided.** Reasons below. |
| **R-3 `T_stack` / te / viz / nsr convergence** | **clean.** 15:03–15:10:44, and the previous agy ended 14:58:44. The auditor established this and it holds. |
| **F-1 / F-4 / F-5 / F-5b (P4 arm, 15:25:40–15:26:20)** | **clean** — the nearest agy ended 15:22:54 and the next began 15:32:10. |
| **F-2 (P4, `--f2f3-only`)** | contaminated, and **it does not matter**: the verdict is a *count of log lines* the contract suite emits, not a timing or a rate. |
| **F-5 / F-5b (OVS arm)** | contaminated by one agy. Same argument: the verdicts are *presence/absence of log lines and table entries*, not timings. |
| **FINDING-05 (energy declined on OVS)** | 🔴 **weakened — see below.** |

### Why R-2 is annotated rather than voided

R-2's measurement is **whether `all_destination_paths` changes**, and the answer was one
distinct value across 1800 samples. CPU contention can plausibly make the *sampler* late — and
the sampler's own health section says it was not: **0 overruns, 899.7 s span, 2.001 Hz,
1800/1800 HTTP 200 on all three channels**, measured under the contamination. What CPU load
cannot plausibly do is make a *changing* path set look static.

And R-2 was already recorded as **"confirmed under a condition that makes it nearly
unfalsifiable"** because the network was quiet. The contamination does not move that verdict;
it is a second reason not to lean on it. Re-taking a measurement whose verdict is "this could
not have failed" buys nothing.

⇒ **Annotated. `R2-result.md` carries the three intrusion windows.** If a future round gives
R-2 real power (traffic), that round must be clean — this one's answer should not be reused.

### 🔴 Why FINDING-05 is weakened

FINDING-05's observation is that the Energy-App powered **3** switches off on P4 and **0** on
OVS. Both watches were contaminated:

| | agy overlap | outcome |
|---|---|---|
| P4 watch (250 s) | **two** runs, ≈174 s | 3 switches off |
| OVS watch (474 s) | **three** runs across its opening | 0 switches off |

So CPU contention is **a live alternative explanation** for the difference, and it was heavier
on the arm that did nothing. It does not explain it away — the P4 arm powered switches off
*while* two agy runs were going — but it is no longer a controlled comparison, and I did not
control it because I did not know I was creating it.

**FINDING-05's ticket keeps its question and loses its cleanliness.** The re-run must be done
with zero commits in the window, which is now the standing rule anyway.

## The rule I am carrying forward

**Inside a measurement window, `git commit` is an experimental intervention on this machine.**
Not a bookkeeping action. It costs ~2 cores for minutes, `ndt status` cannot see it, and
`--amend` costs it twice.

The counter-argument I used at the time — *"an uncommitted findings file is too fragile in a
worktree two sessions are writing to"* — does not survive the arithmetic: the loss risk over a
one-hour window is negligible, and what I bought with it was load in my own samples.
**Write findings to disk during the window; commit them after release, with the evidence.**

[Co-developed with claude code -- Adam]
