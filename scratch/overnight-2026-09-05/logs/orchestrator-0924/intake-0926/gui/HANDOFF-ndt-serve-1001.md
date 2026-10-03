# GUI v2 handoff from the ndt serve session (2026-10-01 ~17:2x, verbatim content, condensed formatting)

From this message on, ndt serve makes no more commits on the branch. Adam agreed to fold the work into the orchestrator session.

## 1. Branch and worktree
- Branch feat/ndt-serve-gui-v2-0927, head 59e3ba1fc1a04fd910c8d001968f7f31be4b5465.
- Worktree /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-gui-v2-0927. Base fed37cff.
- At trunk d452d111 merge-tree was clean; on merged tree 3a186b15 the four suites (3.12, 3.8) were green and the main gate 188/0 (head 3b6e533c then).
- porcelain empty. --ignored: three __pycache__ (tests/browser, tests/python, tools/ndt_serve) and web/node_modules (88 MB, ignored by web/.gitignore, needed to build — do not delete).
- Its opus worker (a subagent of the ndt serve session) wrote the browser suite and page gate; it waited for "FROZEN <sha>" to do the formal page-suite-v2-r3-1001.log and page-gate-v2-r3-1001.log. Not reachable from here: dispatch a new worker.

## 2. The r2 fix list
- (1) ruling (b) mutants: done, 59e3ba1f. CF3 = Down's preview:false (Down seen red for the first time); CF4 = Confirm not locked when blocked; A2, A2b = the apps claim-first half. Only an ONLY= partial run: page-gate-v2-r3-dev-1001.log, 4/0, rc 0. Full page gate not run.
- (2) arithmetic: README 7→9 sudo in 84f97a4d; SUMMARY-r2 49 and 1,550 in c1212944 — but both use the OLD strace idle figures (221+66), now overturned by live-probe-cost/RESULTS.md (idle 448/596, sudo 8/10; measuring 564/719, 6/8, plus 1 kernel request). README:183-189, manual §9, SUMMARY §1.1 must take the measured values. NOT DONE.
- (3) public content: SUM:18-21 removed in c1212944. Normal --no-ff, no history rewrite (Adam).
- (4) provenance headers print "?": main gate and rebuild gate 3200e714, page suite 0580140a, page gate 59e3ba1f. SUM:5/:39/:54 wording c1212944.
  - NOT DONE: G-N7 red-first at the final head. Script ready: logs/ndt-serve-gui-v2/gn7-red-first.sh <worktree> (prints head, porcelain, interpreter, old = fed37cff in full, rc per run).
  - NOT DONE: merged-tree logs that print their own provenance. Script: logs/ndt-serve-gui-v2/merged-tree-run.sh <worktree> <head> <logdir> (prints merge-tree command, tree id, git archive command, dir, rc per run).
- (5) nits: "three files" in test_ndt_serve_gui.py, 9186afe5; N7 ("last read" covers /lab only while paused) in README and manual, 84f97a4d.
- r2 review's "tests I would have run" 4–6 not done: back to foreground → exactly one /lab ~60 s later; declared-only resume; /lab timeout then recovery by the probe. Item 3 (measuring-state cost) done without ptrace.
- SUMMARY-v2-r3.md not written. The final round reruns everything, then writes it with OBSERVED / INFERRED.

## 3. How to run (current head's expected numbers)
- Main gate (pure Python, no guard):
  - `PYTHON=/usr/bin/python3.12 bash tests/shell/mutate_ndt_serve.sh > LOG 2>&1`
  - `PYTHON=$HOME/miniconda3/envs/ryu-env/bin/python3.8 bash tests/shell/mutate_ndt_serve.sh > LOG 2>&1`
  - Expect 188 mutations, 0 survived; baselines 75/35/36/18 (serve/cells/gui/web); last line rc=0; ~5 min each.
  - First line prints head, porcelain, date, python. It hashes README, serve.py, web/**, static/*: editing them during a run → exit 3.
- Single suites: `/usr/bin/python3.12 tests/python/test_ndt_serve*.py`. 3.8 by path only: `$HOME/miniconda3/envs/ryu-env/bin/python3.8 tests/python/X.py` (`-m unittest tests.python.X` is shadowed by another `tests` package in ryu-env). Bare python3 is miniconda 3.13.13; CI pins 3.12.
- Page suite (miniconda 3.13): `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh env PYTHONDONTWRITEBYTECODE=1 python3 tests/browser/test_ndt_serve_page.py > LOG 2>&1`
  - Refuses to run outside the guard (no NDTWIN_GUARD_HELD). Expect 29 cases OK, ~333 s, every class prints "chrome leftovers (X): 0".
- Page gate: `bash tests/shell/mutate_ndt_serve_page.sh > LOG 2>&1`
  - Do not wrap in a guard: it calls the guard itself per build and per Chrome (re-entrant).
  - Expect 52 mutations, 0 survived; 3 known equivalents (E1, Q7a, Q7b) stay green, 0 overturned; rc=0. ~25 min with the lock free, up to 85 min when held (dev2 took 5,102 s).
  - `ONLY="label …"` runs only those, marked partial.
  - TMPDIR must be short: Chrome's SingletonSocket path > 107 bytes fails; the suite refuses first; the gate's mutant dirs are numbered.
- Rebuild gate: `bash tests/shell/rebuild_ndt_serve_web.sh > LOG 2>&1` — calls the guard itself; refuses below 2 GB free; rc 2 if Node/npm differ from BUILD.json. Expect 5 files same; BUILD.json 5f11b9a3…, app.js 10859125…, manual.html b873dcd6….
- Anchors: `python3.12 tests/shell/check_gate_anchors.py --gates-from HEAD --gates mutate_ndt_serve.sh mutate_ndt_serve_page.sh -- HEAD` → ok(162) and ok(42).
- Logs in scratch/overnight-2026-09-05/logs/ndt-serve-gui-v2/.

## 4. Rebuilding the bundle
- Node is ~/.local/node/bin (v24.20.0, npm 11.19.0), not conda.
- ~/.npmrc registry is npmmirror; lockfile resolved is npmjs; npm ci swaps host automatically.
- First time: `npm --prefix tools/ndt_serve/web ci --ignore-scripts` (already installed in the worktree).
- Build: `JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh env PATH=$HOME/.local/node/bin:$PATH npm --prefix tools/ndt_serve/web run build` (tsc, vite, manual, then BUILD.json).
- Any change to web/** or manual/zh.md → rebuild and commit static/'s four to five files, or BuildManifest goes red.
- Byte-for-byte: the rebuild gate; CI layer: BuildManifest in test_ndt_serve_web.py.
- Check `df -h /` before each step; no build under 2 GB (about 3.0 GB at handoff).

## 5. Traps not in the docs
- Root .gitignore line 5 ignores every .gitignore, so web/.gitignore was added with `add -f`.
- check_gate_anchors reads `mapfile … < <(find "$A" "$B")` as one mutant call — use while read.
- `setsid bash gate.sh > log; echo rc >> log`: when the caller is a process group leader, setsid forks and returns at once; the rc line is overwritten by later gate output. Use setsid -w, or no setsid.
- bash executes a script as it reads it. The page gate is wrapped in { …; exit; }; the MAIN gate is not — do not edit it while it runs.
- When ndt's line count moves (e.g. trunk 571fa6fd added 36 lines): verbs.RC_SOURCE line numbers, the lock-probe citations in README and serve.py comments, and main-gate anchors M61/M64/M65 move together. G49 and ClaimFormProvenance locate claim_line's printf by function + text; update them if that line changes.
- Never measure ndt's cost with strace: setuid is dropped under ptrace and every sudo fails.
- `sudo -n` cannot kill: run iperf3 with -t and the server with -1 so they end themselves.
- With measuring= in the claim, `ndt down` returns rc 5. After a measurement, re-claim without NDT_MEASURING to clear the declaration, then down (no --force).
- preview_start reads the main checkout's .claude/launch.json and starts Adam's hugo site. Editing launch.json was blocked by the classifier; leave it.
- Flaky cases: none now. Page-suite time windows are 12 s, 5.5 s, 25 s, 66 s — at risk only under a full CPU.
- serve token ~/.config/ndt-serve/token (0600), url ~/.config/ndt-serve/url, state ~/.local/state/ndt-serve/ (guided/ holds the two 09-24 walks, judged green). Tests use private_home and never touch these.
- feat/ndt-serve-0924 is retired, not deleted; its worktree is scratch/overnight-2026-09-05/wt-ndt-serve-0924.

## 6. Open items beyond GUI v2
- G-N9: the reason strings in mutate_ndt_serve.sh, planned for another branch (source: the round-1 G-N series, intake-0926/judge-NDTSERVE-GUI-*.md). Its memory says "G-N9 deferred; G-N6 the orchestrator opens separately".
- SLOT wait has no upper bound: owes the orchestrator a three-line design note, not written.
- Open questions from the 0924 first cut (its memory ndt-serve-state.md): no live evidence for post-r2 code; ndt help lacks cells, guided and XDG; NoPatternKill was loosened; the shared-state register covers only four knob files; walks claim per owner and the status step does not block; --force not exposed to the API (agreed).
- SCOPE-v2 §9 second delivery: English string table and language switch, manual screenshots and polish, walk panel details, per-cell explanations.
- Raw records in logs/ndt-serve-gui-v2/; live-probe-cost/ has RESULTS.md and the restore logs; the two scripts are in logs/ndt-serve-gui-v2/.

## Orchestrator intake notes (after handoff)
- 2026-10-01 r3 (opus-worker): light probe = `ndt status --measuring` (status_measuring_rows shared with plain status) + serve GET /measuring + page probe. Head 23e9b76f.
  New probe idle: 12 tasks, 0 sudo, 0 curl, 0.14 s (old while measuring: 564 / 6 / 1 kernel GET). NOT DELIVERED: page gate stopped at 31/58 and rebuild gate refused, both for disk (<2 GB).
  Branch no longer merges cleanly with trunk (5 files, ndt citations); resolved merge 8dfe18a4 (parents d452d111, 23e9b76f) green on suites/main gate/ndt test+gate/anchors.
  Found: a SIGTERM'd page gate prints rc=0 from its EXIT trap. Handback text saved as gui/REPORT-r3-23e9b76f.handback.txt.
- 2026-10-02 ~00:xx: freed 1.9 GB (finished scratch trees), 3.3 GB free; worker resumed: fix the killed-gate rc=0 pattern, full page gate + rebuild gate at the new head, merge rebuilt on trunk 1e350bf2, final SUMMARY text.
- 2026-10-02 r3 DELIVERED 0170df28 (+ the gate fix: an interrupted serve gate never ends on rc=0, all four gates, red on 23e9b76f).
  Final run at 0170df28: main gate 198/0 (3.12, 3.8), suites 75/35/39/18, page suite 32 OK, page gate 58/0 + 3 equivalents (22,315 s,
  mostly waiting on the guard lock held by B's gates), rebuild gate 5 files identical from clean npm ci, anchors 123/123.
  Resolved merge 1ee0089f (parents trunk 1e350bf2, 0170df28; branch feat/ndt-serve-gui-v2-0927-r3-merge-1e350bf2) green on suites,
  main gate, ndt measuring test/gate, anchors; page suite not run on the merged tree. 8dfe18a4 superseded (delete).
  Harness refused SUMMARY write again: I committed SUMMARY-v2-r3.md as 51f61eea. Scan fed37cff..51f61eea 0, privacy 0, messages clean.
  Handback text: gui/REPORT-r3-0170df28.handback.txt. Review r3 sent to the r2 judge (same agent).
  Merge plan once MERGE: --no-ff into trunk with 1ee0089f's resolution + the SUMMARY commit (parents trunk, 51f61eea), then PR.
  B must then re-merge trunk (ndt moved) and rerun its gates before the live run.
- Review r3 (same judge as r2): MERGE AFTER FIXES, gui/judge-NDTSERVE-GUI-V2-r3-51f61eea.md. r2 list all DONE; probe implemented as ruled;
  gate fix correct; merge citations hold. Fixes: the probe pin is a PATH denylist (/dev/tcp, urllib, absolute paths bypass it); merge
  evidence gaps (second parent 0170df28 not the delivered head; page suite and four ndt gates not on the merge); SUMMARY inaccuracies
  (r2 column, §4/§5, 397-vs-448 is explained by a stale up.target). Round 4 sent to the same worker.
  Deferred to the next GUI delivery (SCOPE-v2 §9 list): "上次探測" is set even when the probe fails or times out.
- Review r4 (same judge): **MERGE**, gui/judge-NDTSERVE-GUI-V2-r4-fb18f59c.md (to be saved). r4 delivered 73889e54 (probe pin past PATH:
  allowlist PATH, netns listeners, static closure; 19 measuring mutants; gates print their sha), I committed the corrected SUMMARY fb18f59c.
- Merge: tree 274a9e4c = 3e8148ab's reviewed tree (dcdc2380) + SUMMARY only; commit 67ec9f9e (parents trunk 1e350bf2, fb18f59c);
  main checkout had no dirty or untracked overlap; ff-only; pushed to both repos (push-gui-v2-67ec9f9e.log, unauthenticated ls-remote).
- PR #24 from pr/ndt-serve-gui-v2 969251eb on main a1f1bc3d (7 doc/audit md paths excluded; invariant 0; scan 0; privacy 0; no binaries);
  prediction ci-prediction-pr24.txt written first. B worker told trunk moved to 67ec9f9e.
- Follow-ups (next GUI delivery / small): "上次探測" on a failed probe; kill harness pre-kill snapshot; listener drain of queued
  connections; watch test_ndt_status_measuring on CI (netns may be blocked); HANDOFF §6 items (G-N9, SLOT bound, SCOPE-v2 §9).
  Delete local branches feat/ndt-serve-gui-v2-0927-r3-merge-d452d111, -r3-merge-1e350bf2, -r4-merge-1e350bf2 after #24 merges.
- PR #24 CI all MATCH (ci-compare-pr24.txt; spot-checked); new test passed on the runner (which network path ran is not printed). Squashed 0965ccaa; ndtwin-lab main synced; both mains 0965ccaa, trunk 67ec9f9e (push-pr24-1002.log). Superseded merge-candidate branches deleted.
