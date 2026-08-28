# Context for whoever runs P1-3, written at handover

Written 2026-08-28 ~19:35 by the retiring `8/27 mainDev` (the session titled that; it spent the
day calling itself `8/28 mainDev`, which is a separate mess — see §5). The `PREREG.md` beside
this file is the design. This file is the part that was in my head and nowhere else.
**[Co-developed with claude code -- Adam]**

## 1. The fabric is UP right now and it is exactly what P1-3 needs

```
10 bmv2 switches, manifest written, 22 s bring-up
binary: /usr/local/bmv2-fast/bin/simple_switch_grpc     ← NOT stock; the two differ 12-18x
140 host namespaces, 128-host P4 topology
kernel: 1 running, build/bin/ndtwin_kernel = a40e04ce
```

I brought it up for P1-3 and then was retired before running a single flow. **No traffic has been
sent. No data exists.** The lab claim is released and `.test_run/lab.handoff` says the fabric is
up deliberately. Reusing it saves ~25 s and, more importantly, keeps the binary identification
above valid — rebuild or restart and you must re-establish it.

## 2. Two instrument facts that cost time to establish

**`pgrep -af 'simple_switch_g[r]pc'` — no `-x`.** `-x` compares the *whole* command line, so any
process with arguments reports as absent. `pgrep -axf` reported a kernel that had been running all
night as dead, and fooled two sessions. The bracket is to stop the pattern matching this shell's
own argv; it protects the pattern only, not other text on the same command line.

**`nm -C <binary> | grep kFlowPathRecomputeInterval` identifies ticket M's build.** 5 hits on
`a40e04ce`, 0 on `ab2d7ed1` and `3367d0e9`. `3367d0e9` answers no to both Q and M and is the
negative control — without a binary that *should* answer no, "present" and "broken grep" look
identical. 🔴 **mtime points the wrong way here**: `a40e04ce`'s mtime is 26 s *earlier* than
commit `2f57ba5` which describes it, because it was built from the worktree before the commit.
So mtime cannot even give you a lower bound.

## 3. The receiver-bottleneck sweep, and the part not in `c294ffc`

The committed finding is `doc/audit/2026-08-28_receiver-bottleneck-sweep/FINDINGS.md`. What is
not written there:

- The candidate list came from `git grep -ln -iE 'iperf|Mbit|Gbit|bits_per_second|lost_percent|
  throughput' -- 'doc/audit/*/*.md' 'doc/*.md'`, which returned 74 files. I triaged to nine by
  reading titles, not contents. **A round with a rate conclusion whose prose avoids all those
  words would not be in my list.**
- `08-25`'s receiver check is `/proc/net/udp` on port 6343 — 291 samples, drops all 0, `rx_queue`
  max 960 B. I read that from its REPORT, **not from its raw**, and did not verify the samples
  came from the window they are cited for.
- The 08-15 loopback control (42.4 / 63.5 Gbit/s) is the single strongest number in the sweep and
  it is one line in a two-week-old report. **It was already there and nobody had used it.**

## 4. P1-3: the design decisions that are NOT obvious from the PREREG

- **Why one path class rather than reproducing the 16-flow spread.** The bottleneck is per-switch
  CPU; spreading flows over four path classes makes flows-per-switch depend on which switch you
  ask about. Pinning all flows to h1→h65 makes flows/switch = flows/link = n by construction. The
  cost is that the existing 16-flow point is no longer comparable, which is why n=16 is re-run.
- **Distinguish flows by port, same host pair.** 16 flows h1→h65 on 16 ports all traverse s1→s3.
  Using 16 different host pairs would change the switch's table occupancy at the same time as the
  flow count, confounding the very variable being swept.
- **Why the ladder is ×1.5 and not ×2.** A ×2 ladder bounds capacity to a factor of 2, which is
  wider than the effect being measured between adjacent cells. This is the one place I would push
  back on my own PREREG if the run is slow: ×1.5 over 13 rungs is ~3 min/arm, 10 arms ≈ 40 min of
  traffic. If that is too long, drop rungs from the *bottom* (1, 2, 3 Mbit are almost certainly
  clean at every n), never from the top.
- **What would make me abandon the round:** if n=2 lands outside 95–150 in both arms. That would
  mean the two-point model that generated every interval is wrong, and continuing to 4 and 8 would
  just produce three numbers with no frame. Stop and re-derive.

## 5. Four things that will otherwise become false premises

1. **The session that wrote all of today's `8/28 mainDev` artifacts is titled `8/27 mainDev`.**
   `.test_run/lab.claim` was written with `owner=8/28 mainDev`. If a claim refuses you, that is
   why.
2. **`testbed_topo.py` in the repo root is not the one that runs.** `~/Network-Traffic-Generator/
   testbed_topo.py` is. Editing the wrong one is silent and cost an arm once.
3. **`b8f7540` on `rescue/literature-search-round1` is a dirty duplicate of `e3bfac1`.** Same work,
   two zero-byte test files extra. Do not merge it. It exists because I re-attached HEAD while
   another session had committed onto the detached HEAD.
4. **Raw goes to `audit-raw`, enforced by `.git/hooks/pre-commit`.** Hooks are not carried by
   clone. In a fresh worktree, `tools/githooks/install.sh`. An uninstalled hook looks exactly like
   an installed one until it fails to fire.

## 6. Untested paths I am naming rather than leaving silent

- 🔴 **The raw gate's ACCEPT path has never been run.** Staging a raw file on `audit-raw` should
  exit 0. I tested refuse-on-branch, refuse-on-detached-HEAD, and pass-for-non-raw, all live.
  Testing accept requires checking out `audit-raw` in a worktree four sessions share. **Verify it
  the next time anyone actually pushes raw.**
- 🔴 **Nothing in the 9/03 deck has been confirmed to render.** matplotlib is absent from every
  interpreter on this machine as of ~19:00, and there is no PNG output anywhere in the repo or the
  working tree. My own `aa10c8e` says so in its commit message. `54551bc` (not mine) claims
  "measuring bottom ink margin on all six outputs", which requires renders that no longer exist.
  **Both commits are public.**
