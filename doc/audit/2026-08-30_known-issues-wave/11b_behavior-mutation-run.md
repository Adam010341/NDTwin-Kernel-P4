# Bundle 2 mutation gate — EXECUTED

Companion to `11_behavior-evidence.md`. That file's §4 registered thirteen mutations and a
control **before** anything was built or run, and said so. This file is the run: every row below
was applied to disk, compiled, and executed. Nothing here is read-not-executed.

Branch `fix-demo-behavior`, worktree
`/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a2c2a6601f812a7eb`, base `1208d22`.

---

## 0. What was measured, and on which binary

`benchmark-must-name-the-binary-it-measured` applies to a mutation gate too: a verdict that
cannot name the binary it ran is not a verdict.

| | |
|---|---|
| Sources under mutation | the five files listed in §2, **in the worktree on disk** |
| Source state each verdict is relative to | the five blob hashes in §2 — the auditor's baseline, byte-for-byte |
| Build tree | `/dev/shm/ndtmut/build` (tmpfs) — see §1.2 for why not `build/` |
| Configure | `cmake -S <worktree> -B /dev/shm/ndtmut/build -DCMAKE_BUILD_TYPE=Debug -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=/dev/shm/ndtmut/gtest-src` |
| Compiler | GNU 13.3.0 (`/usr/bin/c++`), the same as the on-disk build's `CMakeCache.txt` |
| Binary | `/dev/shm/ndtmut/build/bin/test_routing_strategy`, relinked for every row |
| Filter (never narrowed) | `P4PowerStrategyTest.*:RoutingStrategyFixture.*:RequestDeadlines.*` |
| Baseline this build reproduces | **46 tests from 3 test suites ran / 46 passed**, identical to the on-disk build |

The tmpfs build is a *fresh full compile* of the restored sources, not a continuation of the
on-disk build. That it reproduces 46/46 is therefore also the independent check on §1.1.

### 0.1 Verdict states, and why there are six of them

Reading a summary line and counting `[  FAILED  ]` is not enough; two of last night's false
findings came from exactly that. The classifier reads **rc first**:

| State | Meaning | Why it is separate |
|---|---|---|
| `BUILD-FAIL` | the mutant did not compile | not evidence about a test |
| `CRASH-RED` | test binary died on a signal (rc ≥ 128) | a segfaulting run can print a *perfectly green* log; rc is the only witness |
| `NO-SUMMARY` | no `N tests ... ran.` line | **may never be scored green** — an absent summary is an absent run |
| `SKIP-*` | the mutation never reached the disk | never counted in any pass total |
| `SURVIVED` | built, ran, summary present, **nothing red** | this is a finding, not a pass |
| `KILLED` | at least one test red | compared by name against the prediction |

All six were forced before the run: a real green log with rc=139 was scored `CRASH-RED`, a
truncated log with rc=0 was scored `NO-SUMMARY`, a synthetic failure log was scored `KILLED`, a
build rc of 2 was scored `BUILD-FAIL`, and the applier was made to refuse a consumed anchor.
`failures-that-report-success` asks for force-red **and** force-green on every gate; that is what
this paragraph records.

### 0.2 Three guards on "the mutation actually happened"

`injections-must-assert-their-own-success`. A `sed` that matches nothing exits 0, so:

1. the applier does exact-string replacement and **refuses unless the anchor occurs exactly
   once**, resolving every anchor in memory before it writes anything (no partial mutant reaches
   the compiler);
2. an independent re-read of the file asserts the new text is present **and the old text is
   gone**;
3. a `grep -rn MUTANT_<id>` witness on disk, recorded per row.

Guard 2 was itself force-failed against unmutated source before the run.

---

## 1. Two incidents during harness bring-up, both mine, both recorded

`the-clean-version-is-the-one-to-recheck` and `evidence-must-outlive-the-handoff` are the reason
these are in the deliverable rather than in a scratch note.

### 1.1 🔴 I deleted the A-1 fix with `git checkout --`, and recovered it byte-for-byte

The first harness draft used `git checkout -- <file>` to restore between mutations. **The fix is
unstaged.** `git checkout -- <path>` restores from the *index*, and for an unstaged modification
the index is `HEAD` — so the command reverted
`src/ndt_core/power_management/P4PowerStrategy.cpp` to the pre-fix version and dropped it out of
`git status`'s modified list. `git diff` then printed nothing for that file, which reads exactly
like "clean restore".

This is the `failures-that-report-success` shape and the mirror of the trap §4 warned about:
last night's version was "restored the source but not the binary"; this one was "ran the restore
command, and the restore command was the destroyer".

Recovery, and why it is not a reconstruction from memory:

- The complete `git diff` of that file had been captured **before** the damage, in this session,
  as tool output — including the diff header `index 614e5af..2257f1f`.
- The three hunk headers (`-43,9 +43,37`, `-62,6 +90,17`, `-158,6 +197,64`) were checked against
  a line-by-line count of the captured hunks before applying: 30/11/58 added lines. All three
  matched, which is a completeness check independent of the content.
- `git apply` re-verified every context line against the on-disk HEAD text.
- The restored file hashes **`2257f1fbc5b0542ccd85172b3731c02eb3e0d295`** — the exact post-image
  blob hash git had recorded before the loss. The restoration is byte-identical, not
  approximately right.
- A full fresh compile of the restored tree then passed all 46 tests including the 12 A-1 tests.

Restore is now an **atomic, sha256-verified copy** from a pristine snapshot (§1.3), plus an
assertion that the `MUTANT_<id>` text is gone. `git checkout --` is not used anywhere in this
harness.

The coordinator independently flagged this same trap while the run was in progress, with the
same diagnosis. Their requested check was run and is in §1.4.

### 1.3 The restore path was hardened again — plain `cp` is not safe on this machine either

The coordinator's second correction: on this box another agent's plain `cp` **truncated a file
to 0 bytes** under the full-disk condition. My restore was a `cp`. `cp` opens the destination
with `O_TRUNC` and then writes, so a short write leaves a truncated *source file of the fix* —
the same class of loss as §1.1, from the operation meant to prevent it.

The restore now (`restore.py`):

1. verifies the **pristine copy itself** still hashes correctly before trusting it (the snapshot
   lives on the same sick filesystem);
2. writes to a temp file in the destination directory, `fsync`s it;
3. checks size **and** sha256 of the temp;
4. `os.replace()`s it into place — atomic, so the real file is never in a half-written state;
5. re-hashes the destination;
6. and is then double-witnessed by `git hash-object`, so one hash implementation cannot vouch
   for itself.

The mutation applier writes the same way. Each row also refuses to start unless `/` has ≥ 512 MB
free.

Forced in both directions before resuming: a clean tree restores OK; a file deliberately
truncated to **0 bytes** is repaired and re-verified to blob `2257f1f`; and a deliberately
corrupted *pristine* copy makes the restore **refuse** (rc=1) rather than propagate the
corruption.

### 1.4 Proof the fix is intact, on the coordinator's request

| Check | Result |
|---|---|
| `git diff 1208d22 --stat` | 12 files, **+726 / −37** |
| — the 7 fix source/header files | +371 / −32 |
| — tests | +323 / −1 |
| — docs | +32 / −4 |
| sha256 of all 5 mutated files vs pristine | all **MATCH**, no 0-byte files |
| blob hash of all **7** fix files vs the `index` lines captured before any damage | all **7 match** (`cd29cd5`, `2257f1f`, `54eb389`, `821aedf`, `dddcee0`, `af2d78e`, `0706223`) |
| every completed row's post-restore baseline | 46/46 |

⚠️ The coordinator's expected magnitude was "+479/−25 量級". The measured total is **+726/−37**,
and no subset of the diff sums to +479/−25. This is reported as a **discrepancy against a
remembered number, not as damage**: the seven fix files each hash to the exact blob git recorded
for them before any mutation or any `git checkout` ran, which is a stronger and more direct
statement than any line count. The +479/−25 figure should be re-derived from last night's report
rather than taken from this run.

### 1.5 A third harness bug, caught by its own symptom

My "wait until the driver finishes" loop grepped `PROGRESS` for `DRIVER-DONE` — a marker **run 1
had already left in that file**. The wait returned instantly and the summary printed *twelve
NOT-RUN rows* while M2 was mid-compile. Had the summary been trusted, this file would have
reported twelve mutations as unrun.

The fix is the general one from `verify-against-known-good-output`: wait on a marker that cannot
already be present — here, the *second* occurrence. The `NOT-RUN` state existing at all is what
turned this from a false result into a visible one.

### 1.2 🔴 The root filesystem is 100% full — machine-level, not caused by this work

Mid-run, every command started failing with ENOSPC. `/dev/nvme0n1p5` (98 G, mounted on `/`, and
the only filesystem — `/tmp` is on it too) had **6.7 MB free**. A relink of this 170 MB test
binary cannot happen there, and neither can `ar` rewriting a 59 MB static library.

Largest consumers observed (read-only survey; **nothing was deleted**):

| Path | Size | mtime |
|---|---|---|
| `~/.config/Claude/vm_bundles/claudevm.bundle/rootfs.img` | 10 GiB | 08-31 10:19 (live) |
| `~/.config/Claude/vm_bundles/claudevm.bundle/sessiondata.img` | 10 GiB | 08-30 20:38 |
| `~/.config/Claude/vm_bundles/claudevm.bundle/rootfs.img.zst` | 1.3 GiB | 07-25 |
| `Desktop/NDTwin-Kernel/scratch/lab/logs/viz.log` | 2.9 GiB | 08-18 |
| `Desktop/NDTwin-Kernel/scratch/lab/logs/viz_p4.log` | 533 MiB | 08-18 |
| `/var/log/journal` | 2.8 GiB | — |
| three agent worktree `build/` trees | 1.3–1.4 GiB each | — |

Nothing was deleted, because none of it is mine to delete and a live measurement claim was
running. Instead the **build tree was moved into tmpfs** (`/dev/shm`, 7.6 G, 7.0 G free,
executable — verified). Sources are still read and mutated in the worktree on disk; only object
files and the binary live in RAM, peak 2.2 GB of a 7.6 GB tmpfs. This touches nobody's data and
is reversible by `rm -rf /dev/shm/ndtmut`.

**This needs Adam's or the auditor's decision** — it is a machine-level condition that outlives
this task, it will block the next person who tries to build or capture evidence, and a 100% full
root filesystem is a plausible source of trouble for the live traffic round that was claimed at
the time.

---

## 2. Pristine snapshot the verdicts are relative to

Every restore is checked against these. All five match the `index <pre>..<post>` post-image
hashes recorded in the `git diff` output captured at the start of this session, before any
mutation or any damage:

| File | blob |
|---|---|
| `src/ndt_core/power_management/P4PowerStrategy.cpp` | `2257f1fbc5b0542ccd85172b3731c02eb3e0d295` |
| `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp` | `dddcee047838ed81d65126bf8055975a11f1cd23` |
| `include/ndt_core/routing_management/P4RoutingStrategy.hpp` | `821aedf4a03ade8aa575f5277330b710d31e0da4` |
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp` | `07062236003923db11838139a790a28782b34ca5` |
| `include/ndt_core/collection/TopologyAndFlowMonitor.hpp` | `af2d78e59e878ad42d7b9329fe506b8cd3c78124` |

---

## 3. Results

**13 of 13 mutations were KILLED, every one by the test §4 predicted, with the control green in
all thirteen and the 46/46 baseline restored after each.** No mutation survived; nothing crashed;
no summary was missing.

| # | mutation | on disk | build rc | test rc | state | red (actual) | predicted | control | restored 46/46 |
|---|---|---|---|---|---|---|---|---|---|
| M1 | drop `&& !poweredOffWithinDistrustWindow(swName)` | grep 1 | 0 | 1 | **KILLED** | `PowerOnActsWhenTheGraphSaysUpButThisStrategyJustStoppedTheSwitch` | same | green | yes |
| M2 | window unbounded (`return it != end()`) | grep 2 | 0 | 1 | **KILLED** | `PowerOnTrustsTheGraphAgainOnceTheDistrustWindowHasPassed` | same | green | yes |
| M3 | delete `clearPowerOffRecord(swName)` after helper-on | grep 1 | 0 | 1 | **KILLED** | `ASuccessfulPowerOnClosesTheWindowSoAnImmediateRepeatIsStillANoOp` | same | green | yes |
| M4 | move `notePowerOff` above the helper-off failure return | grep 2 | 0 | 1 | **KILLED** | `AFailedPowerOffDoesNotOpenTheDistrustWindow` | same | green | yes |
| M5 | one process-wide timestamp instead of the per-switch map | grep 3 | 0 | 1 | **KILLED** | `TheDistrustWindowIsPerSwitchNotFabricWide` | same | green | yes |
| M6 | literal `/stats/flowentry/modify` instead of `strictModifyPath()` | grep 1 | 0 | 1 | **KILLED** | `ModifyWithPriorityUsesTheStrictRouteSoItCanOnlyHitThatEntry` **+** `ModifyAndDeleteAgreeOnWhatAPriorityMeans` | **both** | green | yes |
| M7 | delete the `priority == -1` branch | grep 1 | 0 | 1 | **KILLED** | `ModifyWithoutAPriorityStaysOnTheNonStrictRoute` | same | green | yes |
| M8 | delete `P4RoutingStrategy::strictModifyPath()` | grep 1 | 0 | 1 | **KILLED** | `ModifyOnTheP4ProxyKeepsTheRouteTheProxyActuallyServes` | same | green | yes |
| M9 | hoist `body["priority"]` above the `-1` branch | grep 2 | 0 | 1 | **KILLED** | `ModifyWithoutAPriorityStaysOnTheNonStrictRoute` | same | green | yes |
| M10 | drop `--max-time` | grep 1 | 0 | 1 | **KILLED** | `TheTopologyPollIsBounded` **+** `TheTopologyPollBoundsTheConnectAndNotJustTheTransfer` | first only | green | yes |
| M11 | drop `--connect-timeout` | grep 1 | 0 | 1 | **KILLED** | `TheTopologyPollBoundsTheConnectAndNotJustTheTransfer` | same | green | yes |
| M12 | `kTopologyRequestTimeoutSeconds` 5 → 15 | grep 1 | 0 | 1 | **KILLED** | `TheWholeTopologyPassFitsInsideItsOwnPollInterval` | same | green | yes |
| M13 | `-sS` → `-s` | grep 1 | 0 | 1 | **KILLED** | `TheTopologyRequestKeepsCurlsOwnDiagnosisOnStderr` | same | green | yes |

Counts: **KILLED 13, matched-prediction 13, SURVIVED 0, CRASH-RED 0, NO-SUMMARY 0, BUILD-FAIL 0**.
Every row: `ran=46, suites=3, passed=45`, test rc=1 — i.e. exactly one test red per row (two for
M6 and M10), never a collapsed or partial run.

### 3.1 M6 reddened both tests, as §4 required

§4 said "M6 must redden **two** tests. If only one reddens, say which and why." Both went red.
The symmetry property `ModifyAndDeleteAgreeOnWhatAPriorityMeans` is therefore not a restatement
of the route-name assertion — it fails independently, which is the reason §2.4 gave for it
existing.

### 3.2 One unpredicted red, and it is a real coupling rather than noise

M10 (drop `--max-time`) also reddened `TheTopologyPollBoundsTheConnectAndNotJustTheTransfer`,
which §4 assigned to M11. Reading the test, this is correct behaviour and the prediction was
simply incomplete: that test's third assertion is

```
EXPECT_LE(connectDeadlineOf(cmd), deadlineOf(cmd))
    << "a connect deadline longer than the total deadline is not a deadline: " << cmd;
```

With `--max-time` gone there is no total deadline for the connect deadline to sit inside, so the
comparison fails. The test is about the *relationship* between the two bounds, not about
`--connect-timeout` alone — so it is sensitive to either flag disappearing. Recorded here rather
than by editing §4's prediction, per the rule that the registered prediction is not rewritten to
match the result.

Nothing else reddened that was not predicted, and **no predicted test stayed green**.

### 3.3 What this run does and does not establish

It establishes that all thirteen tests have discriminating power against the specific defect each
one names: remove the fix and the test fails; restore it and the suite is 46/46 again, verified
26 times over.

It does **not** touch what `11_behavior-evidence.md` §3.4 and §4 already recorded as unreachable
from a test binary: deleting the A-2 WARN block, deleting the recovery INFO, or making the
failure counter per-endpoint rather than per-pass — none of which any mutation here can catch.
Nor does it retire §3.3's blocking `modify_strict` check, which still needs a live Ryu. A green
mutation gate is evidence the tests can fail, not evidence the fix is right on a fabric.

---

## 3.4 Closing state

Nothing was committed. Nothing outside the worktree was modified or deleted.

| Check | Result |
|---|---|
| `git status --porcelain` | **identical to the start of this session** — the same 12 modified files and the same 4 untracked entries; nothing added, nothing dropped |
| `git diff 1208d22 --shortstat` | 12 files, +726 / −37 (unchanged by the run) |
| blob hash of all 7 fix files | all 7 match the pre-run values |
| `grep -rn MUTANT_M src/ include/ tests/` | no hits |
| final rebuild of **`<worktree>/build`** (the on-disk tree, the binary the dispatch named) | build rc 0, 0 errors |
| final run of `build/bin/test_routing_strategy` on the full filter | **46 tests from 3 test suites ran / 46 passed**, rc 0 |

The complete final output is at `11b_mutation-harness/final-baseline-46-of-46.log`. The on-disk
build tree was deliberately rebuilt at the end so that the binary the dispatch pointed at matches
the sources again — during the run it was stale, because the mutation builds happened in tmpfs.

The tmpfs build tree (`/dev/shm/ndtmut`) was removed afterwards so it does not hold ~2 GB of RAM
on a machine carrying a live measurement.

---

## 4. Harness

Copied out of the session scratchpad (which does not survive the session) into
`11b_mutation-harness/` next to this file:

- `mutations.py` — the thirteen mutations as exact-text edits, each with its registered
  prediction; the applier that refuses a non-unique anchor and writes atomically
- `classify.py` — the rc-first verdicts of §0.1
- `restore.py` — the atomic, sha256-verified restore of §1.3
- `run_one.sh` / `driver.sh` / `summarize.py`
- `verdicts/` — the 13 per-row verdict JSONs and their grep witnesses
- `final-baseline-46-of-46.log`, `pristine-SHA256.txt`

Per `put-measurement-commands-in-script-files`, no measurement command was typed ad hoc; every
row went through `run_one.sh`.

### 4.1 Three harness defects found by running it, all in the harness

`new-tools-are-the-first-thing-under-test` predicts this, and it held: everything that went
wrong today was in the instrument, not in the fix.

1. **`git checkout --` restored to HEAD, not to the fix** (§1.1) — destroyed the A-1 fix;
   recovered byte-for-byte.
2. **plain `cp` can truncate under a full disk** (§1.3) — replaced with atomic write + sha256.
3. **the "original text must be gone" assertion cannot hold for an insertion** — M4 and M9
   prepend around their anchor, so `new` legitimately contains `old`. M4 scored `SKIP-NOT-ON-DISK`
   and was re-run after the fix; M9 was fixed before it was reached. The `SKIP` state is why this
   surfaced as a refusal instead of as a false "the mutation survived".
4. (bonus, §1.5) **a completion wait that matched a stale marker**, which briefly printed twelve
   `NOT-RUN` rows as though the run were finished.

Each of the four was caught by a guard that existed *because* of a previously recorded lesson,
not by noticing something looked odd.
