# opus-judge round 2 on 571fa6fd (2026-10-01)

## Round-2 re-audit: fix/residue-live-pid-wait-0928 @ 571fa6fd (read-only; nothing executed, no git)

**Bottom line: MERGE AFTER FIXES.** The product change and the new tests are correct, and I found no new defect in the round-2 code. Seven of the eight items are done. Item 3 is missing its CI run. One evidence carry-over (9ec12523 → 571fa6fd) fits everything I can read but is not shown. One number in PROGRESS is wrong.

Paths:
- WT = …/scratch/overnight-2026-09-05/wt-residue-flake-0928
- G = …/logs/gates-0910/residue-0928
- IN = …/logs/orchestrator-0924/intake-0926/residue
- R2C / R2H = G/round4/l1-nobuild-{control-3368412d,head-571fa6fd}-r2.log

### Per item

**1. Cached-table wording — DONE (claim SUPPORTED)**
- ndt:9799-9806 now says duration_sec is NOT the switch's answer at this fetch: the kernel serves a cached table, polled about every 10 s and carried forward when a poll fails. So `now - duration_sec` is never earlier than the install second but can be later by up to the cache's age. A poll landing between `now` and the fetch is called "possible in principle and no more".
- The test says the same in the 5N header (test_apps_residue.sh:373-375) and the dead-app comment (:554-556).
- I grepped WT (tools, tests, src, p4_proxy) for "answer at the fetch", "switch's answer" and "at the fetch". The only hits are ndt:9799 (where it is negated) and test:374/556, which describe the fake switch. The gate header (mutate_apps_residue_one_clock.sh:17-19) and G-62 (:5376-5377, :5391) also describe only the fake.
- The kernel facts check out:
  - getOpenFlowTables returns the cache (DeviceConfigurationAndPowerManager.cpp:2920-2927).
  - The cache is refreshed by a fetch → apply → 10 s sleep loop (:2838-2858).
  - Switches that could not be read are carried forward (:2799-2812).

**2. CI ratio — DONE (SUPPORTED)**
- No ratio or run count remains in ndt:9291-9301, test:327-339 or :363-368, gate:12, or the commit message (line 6 just says "the intermittent test_apps_residue failure on CI").
- One run id remains at test:329, "(run 36373153486 and others)". It is an identifier, not a count. It does not appear in the five PR-15 job logs in IN/.. (those carry job ids), so I could not check it locally.

**3. Robustness — PARTLY (the parts PROGRESS lists are SUPPORTED; the CI clause is UNTESTED)**
- Try count: test:503 sets "yes, try N of 5 (Ms)", printed at :511, :517 and :523. The 5-try cap is at :502.
- The 30 s check (:504) runs only between failed tries, so a case can run past 30 s by one try. The header (:380-381, "at most 5 tries and 30 s of wall clock each") overstates this, but it is enough for round 1's headroom concern.
- Old-case budget widened as claimed: fork window .40-.43 (:457, :474-477), rule at fork + 0.1 s (:478-480), report started at (k+2).58 (:487). That leaves about 420 ms to reach `now`.
- The robustness runs are at the claimed sha and show what PROGRESS says:
  - robust-idle.log:1 and robust-loaded.log:1 are both 571fa6fdb8ab….
  - Both are 0/50 red (:53).
  - Every one of the 100 rows shows "try 1 of 5" for young, old and scan (300 of 300). The summaries and evidence4b-driver.log:3-16 agree.
- "Loaded" really was loaded:
  - evidence4b.sh:16-18 starts four `taskset -c 2,3` busy loops, and :26 pins the suite to the same two CPUs.
  - robust-loaded.log:2 records the load pids.
  - Suite wall time was 33/48/55 s loaded against 18/20/21 s idle.
- Caveats on the load runs:
  - CLOCK_R reports whole seconds, and the per-case times are the same 1-3 s idle and loaded. So the 420 ms and 400 ms budgets held in all 150 loaded case-runs, but the remaining margin is unknown.
  - The retry path never ran in these 100 runs. M7 exercises only the case where every try fails.
- **NOT DONE:** round 1 asked for "one green GCC CI run at the head". There is none, and the branch is unpushed (PROGRESS:4). PROGRESS marks item 3 "done" without mentioning it.

**4. Age asserts — DONE (SUPPORTED)**
- The asserts exist: "installed 0s ago" for young (test:512) and scan (:524), "installed 2s ago" for old (:518). The retry wording is fixed (:379-384).
- They can fail, and have:
  - Against the unfixed ndt: round4/redfirst-unfixed.log:4, 7 and 10.
  - Under M3, M4 and M6 at both shas: round4/gate-mutate_apps_residue_one_clock.log:7-14, and IN/rerun-mutate_apps_residue_one_clock.571fa6fd.log:9-16.
- When the premises hold, the old case's rule age is fixed at 2: the rule is in [k.50, k.53) and the fetch in [k+2.58, k+3). The new .43 premise plus the age assert close round 1's "dur=1" hole.
- Not shown: the age part of the assert going red by itself. Every red so far comes from the rule being excluded. This is optional.

**5. Early window — DONE (SUPPORTED); no extra documentation needed before merge**
- Order in ndt: the fetch at 9792-9793, `now` at 9807, every app dated at 9813-9817, the lock probes at 9860-9876, and the stored date used at 9890.
  - `dated` is a `local -A` used only at 9813, 9816 and 9890.
- The new "early window" case is test:526-549 (stub probes at :423-428, rule 2 s before the fork at :532-534, premise at :545).
- M9 (gate:150-154) puts back 600f0ca0's placement (dating after the probes). It is caught at 9ec12523 (gate log:15-16) and at 571fa6fd (IN rerun:17-18).
- On documentation: there is nothing to record relative to trunk.
  - Trunk computed `$(date +%s) - et` at a single moment, so it never opened a window early. That is why the early-window checks stay green on the unfixed ndt (redfirst-unfixed.log:4 lists six reds, none of them early-window).
  - The early opening only ever existed in the unmerged 600f0ca0.
  - The placement and its reason are already written in ndt:9808-9812, the commit message (lines 8-10) and KNOWN-ISSUES.md:5371. So "not documented" in PROGRESS undersells it.
  - What remains is whole-second rounding plus the time the dating loop takes. It errs toward over-listing, so a clause in the ndt comment would be nice but is not needed before merge.

**6. Fold — DONE as far as can be read without git (SUPPORTED)**
- The trunk..head diff has 11 files, matching the `git diff --stat` count reported in CLASSIFY §3.
- Nothing from c2c9293d's age wait is left:
  - 5K waits only for the argv (test:343-350), and its comment (:333-335) rules out an age wait.
  - mutate_apps_residue_one_clock.sh is the only mutate_apps_residue* file, and "live_fixture" / "live_pid_wait" appear nowhere in WT.
- The head itself is green: robust 100/100, R2H:159 (PASS 145), R2H:138 (test_ndt_serve PASS 74), R2H:7 (anchors 127/127), and two orchestrator runs.
- "One commit" comes only from git output reported by others (PROGRESS:3; IN/rerun-residue-571fa6fd.frozen.sh:2,6). I could not verify it read-only.

**7. G-62 — DONE (SUPPORTED)**
- KNOWN-ISSUES.md:5368-5396 covers everything asked:
  - S1 (:5378-5382), including app_stop's `wstart` → app_window_record, which later orphans and --check read. This matches ndt:9005, 9053, 9187 and 10429-10432.
  - S2 and S3 (:5383-5385).
  - The cache-age bound, labelled as read from code (:5386-5391).
  - The ruling: (a) sub-second comparison, with a 1 s tolerance explicitly rejected (:5393-5396).
- Nits, none blocking:
  1. "0–10 s" leaves out the poll's own duration (the loop sleeps 10 s after each fetch).
  2. The measurements are at 3368412d and 74d1383f, not the merged ndt. They carry over by reading, since round 2 does not touch the S1-S3 paths.
  3. Two other effects of the same cache are not stated. Both predate this branch, and I did not find either in KNOWN-ISSUES:
     - rules newer than the last poll are missing from the table entirely (an optimistic miss);
     - rules installed up to one cache age before an app started are dated inside its window (over-listing).

**8. Evidence hygiene — DONE; the 42/42 BOTH classification is SUPPORTED by the r2 logs**
- The empty "5N windows" extractor is gone from every round-4 script and log. The round-4 scripts extract the try lines instead (4a.sh:26-28, 4b.sh:29-32).
- The shared ndt blob is stated at round4/redfirst-unfixed.log:1 and evidence4a-driver.log:6.
- The anchors log cited is green: check-gate-anchors-HEAD.log:136-137 (127/127, rc=0, at 9ec12523). At 571fa6fd, the lane's own anchors check shows the same: R2H:7 and l1-nobuild-head.log:5.
- L1 classification:
  - R2C:3 is 3368412d and R2H:3 is 571fa6fd; both end FAILURES=42 at :240.
  - The same 42 FAIL rows sit at the same line numbers on both sides (P4 at :14-103, kernel-side at :107-191).
  - The only result lines that differ are :7 (126→127 anchors), :10 (396→397 files) and :159 (PASS 131→145).
  - I spot-checked l1_kernel_test_mutate_gate_dead_mutant.log on both sides; they match.
  - Scope: sections 0/0b/3/3b only, run with a mawk shim on both sides.
  - 32 of the 42 assert nothing on either side (23 ran zero tests, 9 skipped everything). None of the 42 files is touched by the branch, and the branch touches no C++.
- New hygiene gaps (not blocking):
  - The 4a logs are pinned to 9ec12523, which PROGRESS:6-7 does not list as kept reachable by the backup branch.
  - evidence4b.sh, which produced the robustness runs, has no "uncommitted changes — refused" guard, unlike 4a.sh:13 and 4c.sh:14.
  - The scripts/l1_nobuild.sh on disk (:20-24, slicing rewritten on 2026-10-01) is not the version that produced R2C/R2H. CLASSIFY §2 D1 and §9 describe the old `awk -v` version and say it was not edited.

### 9ec12523 vs 571fa6fd: claim UNDER-EVIDENCED, but consistent with everything readable
- **ndt is byte-identical.** sha256 81c1326aee348e19… appears at both: gate-mutate_apps_stop_lists_rules.log:44 (full value) and the one-clock gate log:26 at 9ec12523, and IN/rerun-mutate_apps_residue_one_clock.571fa6fd.log:28 at 571fa6fd.
- **test_apps_residue.sh differs:** 680c31e3… at 9ec12523 against 7e5c0ade… at 571fa6fd. The 145 check names and the CLOCK_R format are the same.
- **Not shown anywhere:** that the suite change is "a 3-line comment", or that the other 9 files are identical.
- Which 9ec12523 logs can stand for 571fa6fd:

| 9ec12523 log | Status at 571fa6fd |
|---|---|
| gate anchors | Re-shown at the head (R2H:7) |
| KNOWN-ISSUES references | Re-shown at the head (R2H:124) |
| one-clock gate | Re-run at the head by the orchestrator, 9 of 9 caught (not cited by PROGRESS) |
| suite green | Re-shown at the head |
| mutate_ndt_helper_apps_window 38/0 | Stands: ndt is identical and its own suite is outside the change |
| red-first 3/3 | Stands only if the claim holds: its suite changed |
| mutate_apps_stop_lists_rules 35/0 | Stands only if the claim holds: its baseline runs test_apps_residue.sh (log:4). The orchestrator's head run has no verdict line yet (ends after M16; may still be running) |
| mutate_ndt_serve 150/0 | Stands only if the claim holds: verbs.py/README/serve.py identity not logged |

- One saved `git diff --stat 9ec12523 571fa6fd` settles all three conditional rows.

### New defects from round 2: none found
- **ndt:** I checked that the scoping is right (9775, 9813), the set of apps dated is unchanged, and the RESIDUE_WINDOW skip is identical. app_started_at writes nothing to stderr and runs in a subshell before and after the change, so output order and global state are unchanged. The code is safe under `set -u`. The RC rows re-check at 10382, 10449, 10452 and 10455, and lock_probe at 9429-9444.
- **Tests:** each case is deterministic when its premises hold.
  - young: rule dated 0 s old;
  - old: rule dated 2 s old;
  - early window: the rule is excluded whenever fetch → dating takes under 1 s;
  - dead app: the rule is dated k or k+1, inside [k, k+2].
- **Optional nit:** EPOCHREALTIME is split on ".", which depends on the locale. Under a comma locale the suite goes red rather than silently green; `LC_ALL=C` in the suite would remove it.

### Internal inconsistencies
1. PROGRESS says "all 15 added checks seen red", but 14 checks were added: 131→145 (R2C:159 vs R2H:159; CLASSIFY §6 agrees). The 15th red is the pre-existing 5K "-> now" check (test:357).
2. PROGRESS marks item 3 "done" while its CI clause was never addressed.
3. The test header's "30 s of wall clock each" (:380-381) does not match the between-tries cutoff (:504).
4. CLASSIFY says l1_nobuild.sh was "not edited", but the file on disk has since been rewritten.

### Tests I would have run
1. The PR's GCC CI job at 571fa6fd, quoting its three "(young/old/scan: …)" lines.
2. `git diff --stat 9ec12523 571fa6fd`, or evidence4c.sh at the head.
3. Headroom logging under load: the sub-second phase at `now` and at the post-report ps.
4. A one-off injected stall, to show a retry recovering on try 2.
5. A test mutation putting the old case's rule in the next second, to show the age clause turns red by itself.
6. A fake kernel that models the cache (stale durations, newest rules absent), for S2/S3 and the left-edge over-listing.
7. Timing of the dating loop with 15 apps.

### MERGE AFTER FIXES
1. Get the PR's GCC CI green at 571fa6fd before the squash, and record the 5N try lines from its log. This is round 1's item 3, still open.
2. Show the carry-over: save `git diff --stat 9ec12523 571fa6fd` beside round4/, or rerun evidence4c.sh at the head. Until then, label red-first, mutate_apps_stop_lists_rules and mutate_ndt_serve as "run at 9ec12523".
3. Correct PROGRESS to 14 added checks (15 distinct reds including the pre-existing "-> now").
4. (Recommended, as a follow-up; do not move the head for it) Reword test:380-381 to "no new try after 30 s", and add the dirty-tree guard to evidence4b.sh.
5. (Recommended, follow-up) In G-62, give the age bound as 10 s plus the poll's own duration, and state, or point to, the two other cache effects.
6. (Optional) Add `LC_ALL=C` to the suite.

