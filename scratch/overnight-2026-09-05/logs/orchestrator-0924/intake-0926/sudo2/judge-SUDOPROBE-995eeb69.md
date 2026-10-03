# JUDGE: sudo probe 995eeb69

**Verdict: MERGE AFTER FIXES.** Only documentation needs fixing. The code, the new cells and both mutation gates hold up as delivered, and no shell gate needs re-running.

- F1, F2 and F3 are closed, each with logged evidence.
- The `test_ndt_serve` red already exists on trunk 4ff4eee8, and probe5b reproduces it there under the same TMPDIR.
- What must change before merge is that G-59 states something the code contradicts (R1), the standing gate for that document was never run on this branch (R2), and the delivery summary's header names the wrong head (R3).

Everything here was read-only: summary §8, the six changed files, the ndt functions involved, the frozen driver copies, and every probe5/probe5b log. I used no git, executed nothing, and did not read the prior judge report. Every claim about individual commits (which files each commit touched, commit-message format) is therefore **not verified by me**.

## Per-question verdicts

**1. F1: SUPPORTED.**
- The new cell (`test_ndt_sudo_surface.sh:299-301`) feeds sudo the line `sudo: error initializing audit plugin sudoers_audit (setrlimit(RLIMIT_CORE): Operation not permitted)` with rc 1.
- At HEAD, the anchored match `"sudo: $w"*` (`sudo_surface.sh:203`) fails for both list entries. The line is recorded as unread, and the probe returns 2.
- An unanchored `*"$w"*` finds `setrlimit(RLIMIT_CORE)` mid-line and treats the line as a warning. `ndt_sudo_unread` then returns 1 and the probe returns **0** (`:250`). So the cell does discriminate.
- S13 (`mutate_ndt_sudo_surface.sh:269-273`) makes exactly that swap and is caught on this cell (`mutate_ndt_sudo_surface.probe5-995eeb69.log:37`).
- Tracing every other cell's stderr, this is the only cell that turns red under S13. That "only" comes from my trace, not the log: `report()` (`:40`) checks only that the named check went red.
- The existing S12 cell (`unable to execute`) does not catch un-anchoring, so this is the first time that half of the rule has been seen red.

**2. sudo-rs control and G-59: the control is SUPPORTED; G-59 is partly CONTRADICTED.**
- The control (`test :302-307`) expects 0. S14 widens `sudo:` to `sudo` and is caught on it (`log :38`).
- G-59 `:5296` says that from stderr these two cases cannot be told apart from the program's own failure. That is true of a silent refusal and false of the prefix case. A `sudo-rs:` line is right there in stderr; the rule chooses not to read it.
  - The suite itself says so (`test :302-304`: "reads sudo's own diagnostics by their prefix and nothing else").
  - S14 is a working reader that picks such a line out.
- G-59 `:5292` says "no `sudo:` line at all ⇒ granted". The code actually returns granted whenever there is no `sudo:` line *outside the warning list* (`sudo_surface.sh:202-209`). A listed warning followed by a silent refusal therefore also reads as granted.
- G-59 `:5295` (and the check's name) uses sudo-rs as *the* example, while admitting its prefix is unverified. That half is UNDER-EVIDENCED.
- **Documenting instead of fixing is reasonable:**
  - A silent refusal carries no information to read.
  - For the prefix case, reading `sudo-rs:` as "could not tell" would be cheap and would fail in the safe direction. Deferring it is still defensible (wording unverified, ticket scope), provided G-59 calls it a choice.
- **Security: no privilege consequence.**
  - The guard that stops the irreversible teardown takes its verdict from the exit status: `ndt:6003` and `ndt:6030-6031` (any non-zero → stop). The same holds for `dataplane_ok` (`ndt:6094-6100`).
  - A misread can therefore neither unblock `topo-stop` nor produce a false "not forwarding".
  - What remains is operational:
    - `--check` exits 0 (false green).
    - The guard prints the wrong wording, "ovs-vsctl is permitted but did not answer" (`ndt:6034-6035`).
    - On the lab row, `lab_session` reads any refusal as "no session" (`ndt:1375-1379`), so a false "lab granted" sits beside an "absent" topo session.
  - My recollection, not verified here: newer Ubuntu releases ship sudo-rs as the default sudo. If its prefix is `sudo-rs:`, G-59 covers every refusal on those hosts. The "real sudo-rs" open item deserves a tracked ticket, not just "記錄在案".

**3. F2: SUPPORTED.**
- The stubbed cases are `test_ndt_status_check_baseline.sh:630-635`.
- S1 and S2 delete `ndt:6943` and `ndt:6946` respectively. Both are caught on the **exit-code** checks (`mutate_ndt_status_check.probe5-995eeb69.log:32-33`).
  - That check can only go red if the exit code leaves 1.
  - So at that point in the fixture, the sudo problem is the only problem, and the sudo arm is what drives the exit code.
- The measured case (`:640-647`) re-sources the real `sudo_surface.sh` over the stubs, then:
  - cuts the table to the ovs-vsctl row;
  - puts a fake `sudo` (nolab wording, exit 1) and a fake `ovs-vsctl` in front of PATH.
- It cannot reach the real sudo or ndtwin-lab: ndt never calls sudo by absolute path (grep: none), and the tripwire log has 0 lines (`nolab_tripwire.probe5 :20-21`).
- R4 (`redfirst_probe.probe5 :88-95`) runs this suite against base's `sudo_surface.sh`:
  - it exits 0 (`expected: [1] actual: [0]`), with exactly 3 reds;
  - against HEAD's it is green.
  - So the rest of the fixture is healthy and the flip is the sudo arm alone.
- One note on wording: "measured" means the real functions with a fake sudo, not a measurement on a live machine.

**4. F3: SUPPORTED** (`sweep_probe.probe5-995eeb69.log`).
- 8 files differ from base (`:10-18`).
- Result: 61 suites `same` plus 2 `FLIP` = 63, with no FLAKY or NEW.
- `test_ndt_status_check_baseline`: 7 checks added, 0 removed, 104→111 (`:55-64`).
- `test_ndt_sudo_surface`: 20 checks added, 2 renamed (before `:75/:78` → after `:77/:79`), 33→53 (`:66-92`).
- Both suites stay rc 0 → 0.
- The four suites red in both trees keep the same counts (78/2/7/4). Lab calls: 0 and 0 (`:117-118`).

**5. `test_ndt_serve` red: SUPPORTED.**
- At HEAD with the long TMPDIR, the failure is `(400, {... 'note is longer than 200 characters'})` (`test_ndt_serve.probe5 :94, :110`).
- On trunk 4ff4eee8's tree (`git archive`, `gates_probe5b.sh:54-56`) under the same TMPDIR, the assertion text is identical (`base_longtmp.probe5b :95, :111`).
- At HEAD with `/tmp/qn5b`:
  - `test_ndt_serve`: OK, 74 tests (`:104`);
  - cells: 35 OK; gui: 40 OK;
  - `mutate_ndt_serve`: 150/0 (`:178`);
  - probe5b result: ALL-AS-EXPECTED.
- Mechanism: in this worktree, `test_ndt_serve.py:616-617` builds the note from two absolute paths under TMPDIR, and TMP_LONG is 108 characters.
- The main checkout's working-tree copy (`:615-630`; commit state not checked) has the length-independent version. That is consistent with the explanation, but I could not verify the shas `c0411e16` / `fed37cff`.

**6. Gate table: every number is in a log whose first line is 995eeb69.**
- The numbers: 53/0; 29/0 (S13 `:37`, S14 `:38`); 111/0; 22/0 (S1/S2 `:32-33`); 14/0; 113/0; serve 74 with 1 FAIL; cells OK; gui OK; mutate rc 2 on a red baseline; anchors 122/122; tripwire 0.
- The probe5b rows also match.
- **Omission:** `gates.probe5-995eeb69.result:2` reads `GATES-PROBE5 … RED`, `# rc=1`. §8 never quotes this, while §3 and §7 quoted ALL-AS-EXPECTED for their probes.

**7. Discipline: SUPPORTED, with one scratch lapse.**
- Tags are present: `test_ndt_status_check_baseline.sh:615` and `mutate_ndt_status_check.sh:313`. The new sudo_surface cells and S13/S14 sit inside the tagged 09-27 blocks (`test :243`, `mutate :199`).
- No `pkill -f` / `pgrep -f` in the changed files or the drivers.
- The suites use `mktemp` plus a cleanup trap.
- Scratch lapse: `gates_probe5b.sh:53` uses the fixed `/tmp/qn5b` (not `mktemp`, never removed). It is empty or absent now.
- Scope across the whole branch is the 8 expected files. Scope per commit and message format: UNTESTED by me.

## Findings

**Required (small, doc-only):**

- **R1. Correct G-59** (`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-sudo-probe-unknown-0927/doc/KNOWN-ISSUES.md`):
  - `:5296`: the prefix case can be read from stderr; this rule does not read it by choice (and S14 pins that choice).
  - `:5292`: should say "no `sudo:` line other than the listed warnings".
  - `:5295`: present sudo-rs as a suggested, unverified example.
  - Add a numbering note for `:2625`, which mentions a `G-59` that was never opened (the index-zero family). The precedent is G-58's numbering blockquote at `:5249-5250`.
- **R2. Run KIREF once.** After R1, run `tests/python/test_known_issues_references.py` (and optionally its mutate gate). No KIREF log exists for probe4 or probe5, although KNOWN-ISSUES.md changed in both rounds. Risk is low: I found no line-number citation of KNOWN-ISSUES in any file it scans.
- **R3. Fix the summary.**
  - Lines 3-10: the header still gives Head `d57f90f1`, but §8 and `:308` deliver `995eeb69`.
  - State probe5's RED verdict and that probe5b resolves it.

**Non-blocking:**

4. The F1 cell does not rule out a "match after any `: `" implementation (`*": $w"*`), because in its line the entry follows `(`. A line like `sudo: ovs-vsctl: setrlimit(RLIMIT_CORE): …` would close that gap.
5. `test_ndt_status_check_baseline.sh:646` matches "could not be tested", which also appears in the problem line (`ndt:6946`). The check would stay green if the row print at `ndt:6944` were removed. Anchor it on the row label instead.
6. Group S has no positive control (report rc 0 → exit 0) inside the group. Also, the measured case has been seen red only in the scratch R4 run. Consider a `mutate_ndt_status_check.sh` mutant against the `sudo_surface.sh` copy it already makes (`:79`), for example `ndt_sudo_unread && return 2` → `:`, named on the "measured:" check.
7. S14 is labelled "(control)", yet it kills the natural fix for G-59's prefix half. That is transparent (the name says "known limit"), but G-59 should warn that whoever fixes the limit must flip this pin.
8. §8 `:298` says "約 1.5 小時". The header timestamps put the gui cell at about 1 h 48 min (`test_ndt_serve_gui.probe5b:2` 21:10:10Z → `mutate_ndt_serve.probe5b:2` 22:59:00Z, of which the run was 14.5 s). That is still under LOCK_WAIT, so the conclusion holds.
9. Process wording will ship into public code: `sudo_surface.sh:180` ("the orchestrator's ruling") and `:72-75`. This does not break CLAUDE.md, which covers only PR and commit text.
10. The fixed `/tmp/qn5b` in the probe5b driver (see question 7).

## Tests I would have run

- KIREF (R2).
- `check_test_tmpdirs` at 995eeb69: new test code has landed since probe4.
- The F1 variant from finding 4.
- A pinned control for a listed warning followed by a silent refusal → 0 (the third path G-59 omits).
- The group S positive control and an in-repo red for the measured case (finding 6).
- Real sudo-rs wording, captured in a container or VM.
- Optional: base 4ff4eee8 under the short TMPDIR, completing the 2×2.
- `mutate_nickname_overlay.sh` also runs `test_ndt_status_check_baseline.sh` and was not run. It needs a C++ build, so skipping it here is justified, but it remains an unexercised consumer of the changed suite.

## Internal inconsistencies

- The summary header's head (`d57f90f1`) disagrees with the delivered head (`995eeb69`).
- "約 1.5 小時" versus about 1.8 h from the log timestamps.
- probe5's RED verdict is not stated.
- The claim that the driver never restarted during the 429 interruptions cannot be checked from the logs. It is consistent with the driver's refuse-if-the-log-exists logic.

## Files

- `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/SUDO-PROBE-UNKNOWN-SUMMARY.md`
- Worktree, `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-sudo-probe-unknown-0927/`:
  - `tools/test_workflow/sudo_surface.sh`
  - `tools/test_workflow/ndt`
  - `tests/shell/test_ndt_sudo_surface.sh`
  - `tests/shell/mutate_ndt_sudo_surface.sh`
  - `tests/shell/test_ndt_status_check_baseline.sh`
  - `tests/shell/mutate_ndt_status_check.sh`
  - `tests/python/test_ndt_serve.py`
  - `doc/KNOWN-ISSUES.md`
- Logs and drivers, `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/`:
  - `*.probe5-995eeb69.log`, `*.probe5b-995eeb69.log`
  - `gates.probe5-995eeb69.result`, `gates.probe5b-995eeb69.result`
  - `scripts-probe5-995eeb69/`, `scripts-probe5b-995eeb69/`
- `/home/adam/Desktop/NDTwin-Kernel/tests/python/test_ndt_serve.py` (main checkout, read from the working tree)