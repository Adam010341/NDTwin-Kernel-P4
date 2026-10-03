## Re-audit, round 2: feat/ndt-serve-gui-v2-0927 @ 189e89a0 (gates run on 3b6e533c)

**VERDICT: MERGE AFTER FIXES.**
- The Q6 probe is implemented correctly and pinned at both the static and browser layers.
- Every formal gate is now tied to a clean 3b6e533c, and its interpreter is printed.
- Two rulings are not fully met:
  - **Ruling (b):** the Down half of the no-claim browser case has never been seen red.
  - **Ruling (a):** the "light" figures given to Adam were measured on an idle lab, where the probe never runs. They also miss that each probe sends a request to the kernel, and the sudo arithmetic is wrong.
- No product code needs to change unless Adam rules the probe too heavy.

**How I read it.** Read-only: no git, nothing executed. I read the worktree files as the delivered tree. I can't hash them, but the built bundle contains the probe exactly as the sources do: `WT/tools/ndt_serve/static/app.js:51` has `Ic=6e4`, `setTimeout(Q,Ic)` behind a visibility check, and `readLab` reading `/lab` only.

Path roots:
- WT = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-gui-v2-0927`
- LOGS = `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/ndt-serve-gui-v2`
- SUM = `WT/doc/audit/2026-09-27_ndt-serve-gui/SUMMARY-v2-r2.md`

**Is 189e89a0 only the SUMMARY on top of 3b6e533c? SUPPORTED.**
- `LOGS/evidence-r2-3b6e533c.log:114-116`: `git diff --stat 3b6e533c 189e89a0` shows one file, SUMMARY-v2-r2.md, +107. SUM has 107 lines.
- Each formal log opens with head 3b6e533c and porcelain 0, printed by the tool itself:
  - `main-gate-r2-py312-3b6e533c.log:1-4`
  - `main-gate-r2-py38-3b6e533c.log:1-4`
  - `page-suite-v2-r2-1001.log:5-7`
  - `page-gate-v2-r2-1001.log:3-8` (this one also counts untracked files and hashes the gate script)
  - `rebuild-gate-r2-3b6e533c.log:1-3`
  - `anchors-r2-3b6e533c.log:1`
- Interpreters: `/usr/bin/python3.12 3.12.3` (py312:4) and ryu-env `python3.8 3.8.20` (py38:4). The page suite and page gate run on miniconda 3.13.13, which the SUMMARY discloses.
- Exceptions:
  - `gn7-red-first-r2.log:1` ran at head 0fde4678 with porcelain 1.
  - The merged-tree logs are tied to 3a186b15 only by their filenames.

### Round-1 findings
1. **Q6 not implemented: DONE.**
   - Code:
     - `WT/tools/ndt_serve/web/src/hooks/useAutoRefresh.ts:61-75`: `arm()` sets a probe timer only while measuring and visible.
     - `useAutoRefresh.ts:89-98`: the probe reads `labRef` only and checks visibility.
     - `NdtServeApp.tsx:121-127`: `readLab` is one GET of /lab.
     - `serve.py:648`: the server runs plain `ndt status` for it.
   - Tests and gates:
     - `tests/browser/test_ndt_serve_page.py:703-745` and `tests/python/test_ndt_serve_web.py:230-275`.
     - Page-gate mutants Q1–Q7 caught (`page-gate-v2-r2-1001.log:204-231`); the equivalent mutants Q7a and Q7b stay green (:232-235).
     - Main-gate mutants G59–G59f caught under both interpreters (main gate :167-172).
   - Docs: `README.md:182-189`, `web/manual/zh.md:176-193`, `zh.json:31`.
   - Caveat: see N1.
2. **Gate results not tied to the head: DONE.**
   - The main gate prints its own head, porcelain, date and interpreter (`tests/shell/mutate_ndt_serve.sh:87-90`) and its rc (:85).
   - The page gate hashes itself, the suite, the driver and the harness at start and at end (`mutate_ndt_serve_page.sh:79`, :120-123, :781-786).
   - Remaining gaps are in N4 and N5.
3. **"Claim first" points at the smaller gap: PARTLY.**
   - The browser case now drives Up and Down, each with `claim none` and with no claim row (`test_ndt_serve_page.py:528-542`).
   - The mutants CF1 and CF2 are caught (`page-gate:120-125`).
   - But the loop runs Up before Down (:532-534), and both mutants' required failure text names Up (`mutate_ndt_serve_page.sh:523`, :529). So these assertions have never been seen red:
     - every Down assertion;
     - "Confirm stays off after typing the exact word" (:540).
   - `preview: true` is pinned:
     - statically for every write path (`test_ndt_serve_web.py:277-300`; G60, G60b and G60c caught at main gate :173-175);
     - in the browser only for apps (A1, `page-gate:126-129`).
4. **Python 3.12 not evidenced: DONE.** py312:4 and py38:4 print it, and so does line 1 of each `merged-3a186b15-suites-*.log`.
5. **G58c overstated: DONE.**
   - The label is narrowed (main gate :184; `mutate_ndt_serve.sh:1373-1377`), and SUM:36 corrects the claim.
   - SUMMARY-v2.md:91 keeps the old wording, but SUM:7 says the round-2 file takes precedence.
6. **G-N7 red on the wrong assertion: DONE in substance.**
   - `gn7-red-first-r2.log:8` and :15 now fail on the token assertion: the child received 198 bytes including `X-NDT-Token`.
   - The test now asserts the token first (`tests/python/test_ndt_serve_gui.py:494-500`).
   - Provenance problems:
     - The run is at 0fde4678 with porcelain 1 and an uncommitted test file (log:1-3).
     - "old" is named only by a sha prefix (8932c2a1), never as fed37cff.
     - There is no rc line.
     - SUM:80 labels it OBSERVED, which SUM:8 defines as run on 3b6e533c.
7. **Sub-guarantees never seen red: DONE.**
   - Typed word: W1–W3 at `page-gate:130-141` (including `upx`).
   - Cookie and IndexedDB: T5 and T6 at :70-77.
   - CSP listener: X2 at :102-105. The style attribute is set after the listener is registered (`main.tsx:20-24`).
   - 立即更新 while measuring: R6 at :200-203.
   - Extra file in the manifest: G58d and G58e at main gate :185-186.
8. **Claims with no saved artifact: DONE.**
   - The evidence log now holds:
     - merge-tree against trunk 584905d8 (:6-8) and against da10d3a3 (:101-103);
     - the diff-stat (:19-84) and the ls-tree check (:86-87);
     - the ndt line counts and empty ndt diff (:89-91).
   - Gaps that remain:
     - The d452d111 merge-tree shows a tree id but no rc (:117-119).
     - SUM:24 says 571fa6fd changed "only RC_SOURCE line numbers and lock-probe citations". The log shows only a diff-stat, and that section's own "(expect none)" check came out non-empty (:10-16).
9. **Numbers that don't match: PARTLY.**
   - Now correct:
     - app.js is 51 lines and 291,374 bytes (evidence:93).
     - web/src is 34 files and 3,189 lines (evidence:94). The diff-stat entries at :47-80 sum to 3,189, and to 32 files and 2,866 lines for TS/TSX.
     - The anchors log names c0 (anchors:1). ok(39) matches my count of distinct page-gate anchors.
     - 5.4 rounds a minute (60 / 11.2 s, `strace/untraced-wall.txt:1`) and about 1,550 processes a minute are right.
   - Still wrong:
     - "約 38 次 sudo" (SUM:35) counts only `ndt status`'s 7. `ndt apps status` adds 2 per tick (`strace/summary.json:98`), so it is about 49 a minute.
     - README:183-184 says "7 of them sudo" per 221 + 66 read; it should be 9.
     - SUM:15 says 1,500 a minute, SUM:35 says 1,550.
10. **Stale "three files" docstrings: DONE** (`serve.py:10`, :19, :84, :181). Nit: `test_ndt_serve_gui.py:161` still says "the page's three files".
11. **No Set-Cookie test: DONE.**
    - `test_ndt_serve_gui.py:201-216` checks 13 answers.
    - G61 adds the cookie at the single shared header line (`mutate_ndt_serve.sh:1466-1471`) and is caught at main gate :198 under both interpreters.
12. **SCOPE-v2.md:295-297 public content: DONE for SCOPE.**
    - SCOPE-v2.md:292-300 is clean. Item 3 at :296 now only says what a host app must send.
    - No "0.0.0.0" or "Web-GUI without CSP" text remains in that directory, except SUM:19.
    - At 3b6e533c the tree grep returns rc 1 (evidence:96-97).
    - The original text is still in branch history at 0d7f6ce8 (evidence:98-99). See N6.

### Round-1 "tests I would have run"
- **1 DONE:** Q6 probe in the browser, with page-gate mutants.
- **2 PARTLY:** Up and Down with no claim row, plus a foreign-claim-only mutant. Down has never been seen red.
- **3 DONE:** apps dialog in the browser (A1). The cell-run `preview:false` mutant is static only (G60b).
- **4 DONE:** typed-word mutants W1–W3.
- **5 DONE:** browser positive controls T5, T6 and X2.
- **6 DONE:** server case that no answer sets a cookie (G61).
- **7 DONE:** Python suites with explicit 3.12 and 3.8.
- **8 DONE:** G-N7 red-first with the token assertion first, but not at 3b6e533c.
- **9 DONE:** hash lists, merge-tree, diff-stat and ls-tree saved.
- **10 DONE:** extra-file mutants G58d and G58e.

### Adam's rulings
- **(a) Q6 automatic probe.**
  - Implemented and read-only: SUPPORTED.
    - The probe is GET /lab, which runs plain `ndt status`. G9 pins "no `--check`" (main gate :124). G59f and Q4 pin "no /apps".
    - The 7 sudo calls are `ovs-vsctl list-br` ×2, `ndtwin-lab status` ×4 and `mnexec -a 1 true` ×1 (`strace/status.strace:58,339,407,428,449,475,487`). All are list or status calls.
  - "Light": UNDER-EVIDENCED. See N1.
- **(b) Browser claim cases, each seen red: PARTLY** (finding 3).
- **(c) Bundle and lockfile committed: DONE.**
  - static/ and package-lock.json (+2,914) are in the diff-stat (evidence:32-36, :42).
  - They are hashed at porcelain 0 (main gate :209-219).
  - A clean `npm ci` rebuild matches byte for byte (rebuild:4-12).
  - No node_modules or dist in ls-tree (evidence:86-87).

### New defects in the round-2 changes
- **N1 [MEDIUM] "Light" was measured in the wrong state.**
  - The traced `ndt status` ran with nothing measuring, 0 bmv2 switches and the kernel on :8000 closed (`strace/precheck-status.out:7`, :31, :33). The probe never runs in that state.
  - When :8000 is open, plain status also runs `curl --max-time 5 http://localhost:8000/ndt/get_graph_data` plus a python3 parse (`WT/tools/test_workflow/ndt:6892-6894`, :7078).
  - So every probe sends one northbound-API read to the kernel under measurement, and the process count in that state has never been measured.
  - Unstated as well: a probe that lands in a gap between runs brings the 10 s tick back. One full tick (about 287 processes, 9 sudo) can then land in the next run before the pause re-engages, unless the measurement is declared.
  - None of this is in SUM:13-17, README:183-188 or zh.md:180-185, and Adam is asked to rule on "light" from those figures.
- **N2 [MEDIUM] Two new assertions were never seen red.**
  - Which: Down with no claim, and "Confirm stays off once blocked" (`test_ndt_serve_page.py:534-540`).
  - Why it matters: for up or down with no claim at all, the page is the only guard (README:196-197). The claim check also runs only when the request asks for a dry run (`ConfirmDialog.tsx:132-134`).
  - What escapes as a result:
    - Down's request losing its dry run is caught only by the static lint (G60c).
    - A blocker that is shown but doesn't disable Confirm is caught by nothing.
  - The apps case's claim-first half (:554-558) has the same problem: A1 fails earlier, at :548.
- **N3 [LOW] Load arithmetic** (finding 9).
- **N4 [LOW] The provenance headers print "porcelain 0" when git fails.**
  - Affected: `mutate_ndt_serve.sh:88`, `mutate_ndt_serve_page.sh:76`, `test_ndt_serve_page.py:814`.
  - `LOGS/merged-3a186b15-main-gate-py312.log:1-4` shows "fatal: not a git repository" followed by "porcelain 0 tracked file(s) differ from HEAD", a false clean reading.
- **N5 [LOW] The SUMMARY claims more about its logs than they show.**
  - SUM:5 and :39 say everything ran on 3b6e533c; the G-N7 log did not.
  - SUM:54 says each log is written once by its command and opens with head, porcelain, date and interpreter. That is untrue of three logs:
    - the evidence log: its header is 15:34:54 with trunk 584905d8 (:3), but :114-119 cite 189e89a0 and trunk d452d111, so it was appended later;
    - the merged-tree suite logs: interpreter only, no date, directory or rc;
    - the anchors log.
  - The merged-tree logs don't record how the tree was extracted or where the suites ran. The merged main gate's file hashes do differ from the branch's in the way the trunk commit 571fa6fd would cause (merged log :203-210 vs py312 :201-208), which partly supports the binding.
- **N6 [LOW] Public content.**
  - SUM:18-21 puts the literal string `0.0.0.0:3000`, and a pointer to 0d7f6ce8 as holding "描述 Web-GUI 現狀的原文", back into the delivered tree. This happened after the evidence-log grep, which ran at 3b6e533c.
  - doc/audit goes to trunk, which is public. The trunk merge must also keep 0d7f6ce8 out of history.
- **N7 [INFO] Stale "last read" label.** While paused, the probe updates the top bar's "last read" time (`NdtServeApp.tsx:124-125`, :221). Meanwhile /apps, /health (including the ndt-drift warning) and /jobs go stale, so the label overstates how fresh the other tabs are.
- **N8 [INFO] Incomplete cookie reasoning.** Cookies are scoped by host, not port. Other services on 127.0.0.1 can still put cookies in `document.cookie`, and `testhooks.ts:21-29` copies them into the DOM whatever G61 pins. That is harmless for the token, but the reason at SUM:96 is incomplete.

### Other SUMMARY claims, classified
- SUPPORTED:
  - SUM:32 interpreters; SUM:33-34 file counts; SUM:36-38.
  - SUM:58-64: 188/0 under both interpreters with baselines 75/35/36/18; rebuild; page suite 29 cases, 332.7 s, 34 temp dirs; page gate 48/0, 3 equivalents, 1,377 s; anchors 162/39.
  - Every §5 log line number checks out: Q1 204 … Q7b 234, CF1 120, CF2 123, A1 126, W1–W3 130/134/138, T5 70, T6 74, X2 102.
  - SUM:84-89.
- UNDER-EVIDENCED:
  - SUM:14, the 221 processes and 7 sudo per probe (N1).
  - SUM:23 for d452d111 (no rc printed).
  - SUM:24 (571fa6fd's content).
  - SUM:25 and :65, the merged-tree binding.
- CONTRADICTED:
  - SUM:35's "38 sudo" (about 49).
  - SUM:5 and :39 "all on 3b6e533c", for the G-N7 log.
- UNTESTED, and disclosed as such: SUM:93-97.

### Tests I would have run
1. A page-gate mutant that sets Down's request to `preview: false`, required failure text "blocker for down with `claim none`".
2. A page-gate mutant where blockers no longer disable Confirm, required failure text "Confirm is on for up with".
3. strace of a plain `ndt status` with a fabric up and a measurement running (read-only).
4. Shown again while measuring: exactly one /lab read about 60 s later.
5. A declared-only pause resumed by the probe (DECLARED → IDLE); only MEASURING → IDLE is driven today.
6. A /lab timeout, then recovery by the probe.
7. The G-N7 red-first re-run with the committed test at the final head, naming the old serve.py's commit and printing rc.
8. Merged-tree runs that print the extraction command, directory, tree id and rc inside each log.

### MERGE AFTER FIXES
1. **Ruling (b):** add mutants 1 and 2 to `mutate_ndt_serve_page.sh`. Re-run the page suite and page gate on the final head; both mutants must be caught for their named reason.
2. **Ruling (a):**
   - Restate the per-probe cost for the measuring state: run test 3, or mark 221 processes / 7 sudo as idle-lab figures.
   - Add the kernel graph GET and the gap-resume effect to SUM §1.1, README:183-188 and manual §9.
   - Then get Adam's "light" ruling on the corrected figures. If he rules it too heavy, this becomes FIX: code change and full re-run.
3. **Arithmetic:** README:183-184 should say 9 sudo, not 7. SUM:35 should say about 49 a minute. Reconcile SUM:15 with SUM:35.
4. **Public content:**
   - Remove `0.0.0.0:3000` and the 0d7f6ce8 description from SUM:18-21.
   - Merge into trunk by squash, or by a history rewrite of 0d7f6ce8 that Adam approves, so the original text never reaches public history.
5. **Provenance:**
   - Make the three headers print "?" for porcelain when git fails.
   - Relabel the G-N7 run as 0fde4678 plus an uncommitted test, or redo it as test 7.
   - Make SUM:5, :39 and :54 match what the logs actually show.
6. **Nits:** `test_ndt_serve_gui.py:161` "three files"; optionally make the "last read" label say it covers /lab only during the probe.
