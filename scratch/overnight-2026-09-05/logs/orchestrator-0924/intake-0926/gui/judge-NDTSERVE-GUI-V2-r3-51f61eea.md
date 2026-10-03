## Round-3 review: feat/ndt-serve-gui-v2-0927 @ 51f61eea (code head 0170df28), merge 1ee0089f

**VERDICT: MERGE AFTER FIXES.**
- **What holds up:**
  - The lighter probe does what Adam's form 7 asked, at the ndt, server and page levels.
  - Every item on my round-2 fix list is done.
  - The interrupted-gate fix is correct, and the old bug was reproduced red before the fix.
  - The recomputed line citations in 1ee0089f hold against the merged ndt.
- **What still needs work** (tests and docs only; no product code):
  - The "no sudo, no kernel request" pin is a PATH denylist. ndt's own `/dev/tcp` and python3-urllib idioms would get past it, so a regression of that kind would never turn anything red.
  - 1ee0089f lacks some of the evidence the branch has.
  - Five small inaccuracies in the SUMMARY.

**How I read it.** Read-only: no git, nothing executed. I used SUMMARY-v2-r3.md, the two patches, the worktree at 51f61eea, and the logs. I did not read the handoff note. The RULINGS-1001.md form 6/7 wording was used only to check what was asked.

Path roots:
- WT = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-gui-v2-0927`
- L = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/ndt-serve-gui-v2`
- I = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926`
- P = `I/gui/diff-r3-59e3ba1f..51f61eea.patch`

### (1) My round-2 fix list, item by item

1. **Down and "blocker does not disable Confirm" seen red: DONE.**
   - CF3 (Down request with `preview: false`) fails on "blocker for down with `claim none`" (L/page-gate-r3-0170df28.log:129-130).
   - CF4 (blocker shown, but Confirm not disabled) fails on "Confirm is on for up with `claim none`" (:132-133).
   - Both are defined at WT/tests/shell/mutate_ndt_serve_page.sh:588-601.
   - The page suite and page gate were re-run at 0170df28 with porcelain 0 (page-suite-r3-0170df28.log:5-6; page-gate:3-8, 292-293).
2. **"Light" re-measured in the measuring state: DONE, then superseded.**
   - Live figures without strace: L/live-probe-cost/RESULTS.md:27-35.
   - Adam then ruled for the lighter probe (I/RULINGS-1001.md:108-109), and it is implemented (P:2364-2470, :2229-2270, :1259-1263).
   - The full gate re-run is done (§5 below).
3. **Arithmetic: DONE, then superseded by the live figures.**
   - README: P:969-996. Manual §9: P:1197-1215.
   - SUMMARY-v2-r2.md:19-23 and :38 are marked as overturned.
4. **Public content: DONE.**
   - Adam ruled the sentence is a public fact: a normal `--no-ff` merge, with the pointer trimmed (RULINGS-1001.md:95-96).
   - SUMMARY-v2-r2.md:24 no longer has the string or 0d7f6ce8. No `0.0.0.0` remains anywhere in the doc directory.
5. **Provenance: DONE.**
   - The headers print `?` when git fails, for example mergedc-1ee0089f-main-gate-py312.log:5-6.
   - G-N7 was redone at 23e9b76f with porcelain 0 and the committed test (gn7-red-first-r3-23e9b76f.log:1-27):
     - "old" is named as fed37cff's serve.py, and every case has an rc line.
     - Its "now" serve.py hash, 4e318360, equals the 0170df28 serve.py (main-gate-r3-py312-0170df28.log:211).
   - SUMMARY-v2-r2.md:5-9, :57-62 and :88 now state the exceptions.
6. **Nits: DONE.**
   - test_ndt_serve_gui.py:163 now says "four files".
   - The "last read" label: the probe no longer touches it (Q12 is caught, page-gate:243-245), and a separate "last probe" was added.

My round-2 tests 1–9 are all run:
- CF3 and CF4.
- RESULTS.md.
- Q8 and Q8b (:247-254), Q9 (:255-258), Q10 (:259-262).
- G-N7 at 23e9b76f.
- A2 and A2b (:135-140).
- Merged-commit headers that print commit, tree, parents, extraction command, directory and rc (mergedc-1ee0089f-*.log:1-4).

### (2) `ndt status --measuring`

**One source of truth: SUPPORTED.**
- The 34 lines move unchanged into `status_measuring_rows` (P:2384-2419). Both plain status (P:2470) and the early `--measuring` return (P:2422-2428) call it.
- The line numbers check out: the function is at 6682-6717 and `return 0` is at 6725. The branch itself starts at 6720, not 6721.
- Output is identical in 8 fixture states (ndt-measuring-test-r3-0170df28.log:7-81).
- Copy mutants L2 and L3 are caught (ndt-measuring-gate-r3-0170df28.log:14-15).
- On the server side, `measuring_fields` is shared with /lab (P:2260-2269), and the copy mutant G62c is caught (main-gate-r3-py312-0170df28.log:203).

**"Cannot regress": PARTLY.**
- What is pinned:
  - 15 PATH shims (P:2063-2073), with a control showing plain status does hit them (:2165-2167).
  - Mutants L1, L4, L5 and L5b are caught (gate :13-18).
  - CI runs the test: the L1 lane globs `tests/shell/test_*.sh` (WT/tools/test_workflow/l1_unit_tests.sh:454).
  - The other layers are pinned too: G62 and G62b (server runs plain status) and G59g and Q4b (page reads /lab).
- What is not:
  - ndt's own `port_open` is bash `/dev/tcp` (WT/tools/test_workflow/ndt:148).
  - ndt already fetches from the kernel with python3 urllib (:7317, :7359).
  - Neither goes through PATH. A `port_open 8000` or urllib call added to the shared function would reach the kernel under measurement and pass all 79 checks and all 14 mutants. Absolute-path commands (`/usr/bin/sudo`) also bypass the shims.

### (3) The page probe: DONE

- **What `readProbe` does:**
  - It GETs /measuring and sets only `setProbeAt` (P:1259-1263).
  - The full read clears the probe time (P:1243).
  - "Last probe" is shown only while paused (P:1279, :1307-1311).
- **Pinned statically:** the SourceLint test allows exactly one setter, one path, and /measuring in one file only (P:702-711).
- **Seen red in the browser:**
  - Q1–Q5, Q4b and Q12 (page-gate:219-246).
  - Resume after a measuring pause, a declared pause, and after a timed-out probe.
- **Round-2 tests 4–6 against /measuring:** each mutant fails for its named reason (:247-262).

### (4) Interrupted-gate fix: DONE

- **Applied to all four gates:** P:219-402.
  - TERM, INT and HUP are trapped and exit 143, 130 and 129.
  - A run that never reaches its verdict prints INCOMPLETE, and an rc of 0 is forced to 2.
  - The end lines go to fd 7.
- **Red before the fix:** killed-old-{main,page,measuring}-gate.log:10-17 show exit 143 but a last line of `rc=0`. killed-old-rebuild-gate.log:12-17 shows no rc line and no INCOMPLETE.
- **Green after:** killed-new-*.log:15-16 show INCOMPLETE then `rc=143` for all four.
- **Other paths:**
  - Refusal: page-gate-r3-refusal-path.log:8-10.
  - Normal completion: the 0170df28 measuring gate ends `rc=0` (:32-34).
- **Limits:**
  - The killed-new page gate's sha (7e71944f) matches the committed one (page-gate-r3-0170df28.log:7). The other three gates don't print their own sha, so for them the claim can't be checked.
  - INT and HUP were never exercised.
  - "Nothing left" was checked only inside the gate's process group. Chrome runs in its own session.

### (5) The merge resolution

**Citations: SUPPORTED.**
- On 1ee0089f (merged ndt 581c236e), the baselines are green: 75/35/39/18 under both interpreters, which includes RcProvenance.
- M61, M63, M64 and M65 are caught (mergedc-1ee0089f-main-gate-py312.log:75, :104-106). Anchors pass 4/4 and 129/129.
- Independent cross-check (an observation of the shared main checkout's trunk ndt):
  - `acquire_lock` is at /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt:9444. Adding the branch's +23 gives 9467.
  - apps.status `return 0` is at :10382, giving 10405.
  - apps.stop is at :10449, :10452 and :10455, giving 10472, 10475 and 10478.
  - All match the resolution patch.
- The merged ndt, serve.py, verbs.py and README are byte-identical between 8dfe18a4 and 1ee0089f (both gate hash lists).

**Not run on 1ee0089f:**
- The page suite, page gate and rebuild gate.
- The honesty, status_check, round_baseline and sudo_surface gates, and the lab_handoff and residue_row tests (all ran only at 23e9b76f, against ndt 408310c7).

SUMMARY:125 names only the page suite. Its claims that the merge-tree gives rc 1 at 1e350bf2 and rc 0 for 1ee0089f rest only on r3-notes.log:17 and :24.

### (6) Idle re-measure, 397 vs 448: explained by the logs

The ndt is the same; the lab state was not.
- **RESULTS' idle run had an up.target record.** It ran at 16:57:19 (live-probe-cost/10-idle-forks.log:1). Plain status at 16:57:02 still printed the full "up target" comparison from the 09-30 record (00-pre-status.txt:44-52).
- **That comparison is where the extra sudo comes from.** It includes a third `ovs-vsctl list-br` (11-idle-sudo-status.log:8).
- **The record was gone before the r3 run.** `ndt down` cleared it at 17:11:35 (RESULTS.md:61; 57-pre-vs-after.diff:24-29). The r3 re-measure at 19:55 shows 7 sudo per run, with no third `list-br` (live-probe-cost-r3/31-old-idle-sudo.log:1-7).
- **The machine was also busier at 19:55.** The 2.2 s wall time and wider spread come from that: idle windows saw 63–99 forks (30-old-idle-forks.log:1-7) against 0–14 earlier (10-idle-forks.log:2-8).
- **Impact:** none on the new-vs-old comparison. README's "idle round 596 tasks, 10 sudo" is the figure with a stale up.target present.

### New defects, ranked

1. **[MEDIUM-LOW] The probe pin is a PATH denylist.** `/dev/tcp`, python3 urllib and absolute paths bypass it (see 2).
2. **[LOW] Merge-evidence gaps** (see 5).
   - 1ee0089f's second parent is 0170df28, not the delivered head. Merging it as-is would leave SUMMARY-v2-r3.md off trunk.
   - The merged `mutate_ndt_serve.sh` keeps trunk's comment "apps.status 10346 -> 10382" (resolution patch :22-23), while its anchor is 10405.
3. **[LOW] Two "independent" runs report an identical duration.**
   - The standalone page suite (page-suite-r3-0170df28.log:56) and the page gate's baseline 1 (page-gate-r3-0170df28.log:46) both say `Ran 32 tests in 617.823s`.
   - Other 32-case runs range from 615.037 to 617.823 s (page-suite-r3-23e9b76f.log:56, page-gate-r3-23e9b76f.log:46, page-gate-r3-dev-probe-only.log:47, page-suite-r3-dev1.log:85).
   - It is either a roughly 1-in-1000 coincidence or the two lines are not independent. The logs can't tell which.
4. **[LOW] Kill-evidence limits** (see 4).
5. **[LOW] SUMMARY inaccuracies.**
   - SUM:5 says "第 4 節的正式閘門"; the final run is §5.
   - The §5 "r2 (3b6e533c)" column gives 52/0 and ok(42). Those are 59e3ba1f's numbers (anchors-all-r3-base-59e3ba1f.log:88); 3b6e533c had 48/0 and ok(39).
   - SUM:77 and :189 say "原因沒追", but the cause is in the logs (see 6).
6. **[INFO]** "上次探測" is set even when the probe fails or times out (P:1260-1261).
7. **[INFO]** Phases B and C of the final run ran at the same time (both logs start at 01:06:05). They use copies, so only timing is affected.

### Claims classified

- **SUPPORTED:**
  - §1.1 (one shared function; the serve and page changes).
  - §1.2: the red-first run fails 11 checks with rc 1 (ndt-measuring-red-first-r3.log:478-479); 14/14 measuring mutants; G62–G62h; G59g and G59h.
  - §1.3 (the shifted citations).
  - §2: the measured rows; new ndt 408310c7 is the delivered file (main-gate-r3-py312-0170df28.log:218).
  - §3.1, §3.2, §3.4, §4 and the §5 0170df28 column.
  - §3.3: the conflict at d452d111 (merged-812dacd3-suites-py312.log:2-9) and the runs on 1ee0089f.
- **UNDER-EVIDENCED:**
  - §1.2 "no kernel request" beyond curl/wget/nc.
  - §3.3: the 1e350bf2 rc 1 and rc 0 claims (notes only), and the not-run-on-merge list (incomplete).
  - §4: the gate sha match, for 3 of 4 gates.
  - §5: whether the page suite and the gate's baseline 1 are independent runs (identical 617.823 s).
- **INFERRED and disclosed:**
  - The new probe's cost in the measuring state.
  - The page suite on the merged tree.
- **CONTRADICTED:**
  - §5's r2 column values.
  - "原因沒追": the cause is answerable from the logs.

### Fixes before merge

1. Close the probe pin.
   - Add mutants to `mutate_ndt_status_measuring.sh` that put `port_open 8000 >/dev/null`, and a python3 urllib GET, into `status_measuring_rows`.
   - Make `test_ndt_status_measuring.sh` catch them. Two CI-friendly ways:
     - run a TCP listener on 127.0.0.1:8000, :8081 and :8080 during `light()` and assert zero accepted connections;
     - run `light()` on an allowlist-only PATH, using `command_not_found_handle` to record any other command.
   - Re-run the measuring test, the measuring gate and anchors at the new head.
2. Re-make the merge from the final head (not 0170df28), against trunk's current tip.
   - On that merge commit, run the four Python suites, both main gates, the measuring test and gate, and anchors.
   - Also run the page suite from the extraction (this also settles item 3 of the defects).
   - Also run `mutate_ndt_status_check.sh`, `mutate_ndt_honesty.sh`, `test_ndt_status_residue_row.sh` and `test_lab_handoff.sh`.
   - Update the stale "10346 -> 10382" comment.
3. Correct the SUMMARY:
   - SUM:5's §4 reference should be §5.
   - Fix the r2 column (48/0 and ok(39) at 3b6e533c), or relabel it 59e3ba1f.
   - List everything that did not run on the merge.
   - Cite command output, not notes, for the merge-tree rc values.
   - Replace "原因沒追" with the up.target explanation.
4. Optional:
   - Have the kill harness scan /proc for the gate's temp dir after the kill.
   - Have the main, measuring and rebuild gates print their own sha256.
   - Exercise INT once.
   - Show a failed probe as "no answer" instead of a fresh time.
