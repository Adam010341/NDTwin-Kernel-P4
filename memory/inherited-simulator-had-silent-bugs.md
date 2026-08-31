---
name: inherited-simulator-had-silent-bugs
description: "The OVS simulator handed to Adam before his P4 work was NOT functionally sound — 11 named defects verified present at baseline 28b8b13, all silent. Correct the premise if it appears in a paper or report"
metadata:
  node_type: memory
  type: project
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-08T12:57:56.666Z
---

Adam's working premise was that the OVS/Mininet simulator handed to him was functionally correct before his first commit, so the P4 work would be pure addition. **That premise is false**, verified against the actual baseline rather than assumed.

**Baseline**: `28b8b13` (2026-04-20, xxxPatty, 182 files) — the parent of Adam's P4 groundwork commit `6f32bca`. Original authors: patty, joemou, JM (2025-12 → 2026-04). Note `9626b2a` "Initial commit" is only a README, so it is the wrong baseline to diff against.

Checked by reading file contents at that commit; **all of these were already present**: `handlePacket` querying the flow table with no lock at all (every sFlow worker, every sampled packet); two `uint64_t` subtractions in the rate loop that underflow to 1.8e19; the elephant-flow flag's clearing `else` commented out; `macToUint64` with no length validation returning silently wrong MACs; `setAllPaths` only ever adding; `Classifier` skipping empty flow tables so old rules never swept; counter-sample parsing on Brocade-calibrated fixed offsets; MININET discarding counter samples; the topology taken as a single startup snapshot and never re-read; `stoull` making malformed parameters answer 500; and `poll()` with a 0 ms timeout burning 100% CPU at idle.

**Why the premise looked right**: every one is *silent*. Nothing crashes, nothing logs an error, every endpoint answers 200. All 128 hosts read green. Finding them requires asking "is this number correct?", not "is anything broken?".

**Commit split since `6f32bca`** (140 commits): 42 touched shared kernel code only, 8 touched both shared and P4, 13 were P4-only, 27 tooling/tests, 50 docs. Lines: shared kernel +5087/-511, P4-specific +7365, tests +9868. The six most-changed files are all original-simulator files, not P4 ones.

**How to apply**: if a paper, report or thesis frames this work as "P4 support added on top of a working OVS simulator", that framing needs correcting — the work is *two* things, and fixing the shared-path correctness defects was a prerequisite for the second, because a lying baseline cannot verify a new data plane (see [[ryu-flow-stats-wedge]]). Don't overclaim in the other direction either: Claude introduced defects too, including three holes in its own same-day fixes and a polling loop that made the graph grow without bound. Related: [[live-runs-find-what-tests-cannot]].
