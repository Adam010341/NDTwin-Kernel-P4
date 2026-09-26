# Judge report: `fix/hb-test-no-venv-0926` @ `c4cb36b9` (on trunk `68ace017`)

(opus-judge final reply, saved by the orchestrator 2026-09-26; content as delivered. Orchestrator's note: the judge
read `rerun-mutate.c4cb36b9.log` mid-run; that rerun has since completed -- caught 39, survived 0, invalid 0,
restore byte-identical, `guarded_build: exit 0`, worktree clean afterwards.)

## Verdict: **MERGE**

I found no blocking defects. Every item on the ticket's Required list has evidence behind it: the python3 fallback, red only when nothing imports or the constants disagree, explicit `PYTHON=` still honoured, the interpreter used is named, red-first logs, and a fallback-removal mutant that the gate catches. The real GitHub CI result is still unverified. The worker says so, and it should be checked on the first CI run after merge. Merge the commit, not the worktree: the orchestrator's `rerun-mutate` was still running when I read it, so the worktree files may be mid-mutation.

---

## Per-claim classification

| # | Claim | Class | Basis |
|---|---|---|---|
| 1a | Red first, explicit `PYTHON=/nonexistent` ⇒ 196/2, the two pin cells | **SUPPORTED** | `.../gates-0910/suite-explicit-nonexistent.hbnovenv-pre-68ace017.log`: line 1 is `68ace017…`, `actual: 'no-venv'` / `'/nonexistent/python'`, `Ran 196 checks, 2 failed`. It is secondary evidence because CI never sets PYTHON. |
| 1b | Red first, CI shape on the default path ⇒ 2 failed | **SUPPORTED** | `.../suite-cishape-copy.hbnovenv-pre-68ace017.log` reproduces the ticket's `got=["no-venv", …]` with an importing python3 first on PATH, which shows the pre-fix code never tries python3. The edited copy is disclosed (one-line diff `43c43` in the header). The "Killed … line 328" line number matches pre-fix numbering. |
| 2a | Local 196/0 | **SUPPORTED** | Worker `suite-local.hbnovenv-c4cb36b9.log` and orchestrator `rerun-local.c4cb36b9.log` both show the main-checkout venv answering, 196/0. |
| 2b | CI shape via hook 196/0, answered by the shim | **SUPPORTED** | `suite-cishape…` and orchestrator `rerun-cishape…` both print `the pins' interpreter: …/python3 (python3 on PATH)`. The worker's shim runs the 3.13 venv python, not CI's interpreter. The orchestrator's shim contents are not recorded. |
| 2c | Copy without the hook 196/0 | **SUPPORTED** | `suite-cishape-copy.hbnovenv-c4cb36b9.log` (diff `48c48` shown). This is the run closest to CI: PYTHON and HB_PIN_VENVS both unset. |
| 2d | Python 3.12.3 shim 194/0 | **SUPPORTED, with caveats** | The version is not in the captured output; it is only asserted in the header. I confirmed it read-only: `/usr/bin` holds only `python3.12`, and `/usr/include/python3.12/patchlevel.h:26` is `"3.12.3"`. The header says PYTHONPATH points at "the venv's pure-python networkx", but `…/site-packages/networkx/..` is the **whole** 3.13 site-packages. 194 = 196 − the 2 tutorials checks (`TUT_EXERCISES=/nonexistent`). |
| 2e | Nothing importable ⇒ 2 failed, with reasons | **SUPPORTED** | `suite-nopy-usrbin`, `suite-nopy-ambient` and orchestrator `rerun-noimport` all show `…: not found \| /usr/bin/python3: import failed: ModuleNotFoundError: No module named 'networkx'`. |
| 2f | Explicit `PYTHON=/nonexistent` stays strict | **SUPPORTED for the "not found" branch only** | The cmd line puts `shim-wrap` first on PATH, and the log lists only `'/nonexistent/python: not found'`. The case of an explicit interpreter that exists but cannot import was not run. No test or mutant guards strictness. |
| 2g | Explicit `PYTHON=<venv>` 196/0 | **SUPPORTED** | `suite-explicit-venv…`. |
| 3 | L1 scorer: pre CI-shape FAIL-RC, post PASS, no-import FAIL-RC; the "--" line does not confuse the count | **SUPPORTED** | `l1-scorer.hbnovenv-c4cb36b9.log` scored logs that contain the new "--" line and got ran=196 → PASS. By code, `shell_summary` forms A, B and C in `tools/test_workflow/l1_unit_tests.sh` (lines 98, 106, 111) cannot match a line starting `  --`, and the `SKIP:` count (line 500) is unaffected. Only the scorer functions were run, not the whole L1 run; rc came from each log's `# rc=` line. |
| 4 | Gate: 38 named + control + `pin-no-path-fallback`; caught 39, survived 0, invalid 0; guard gives rc 2 when the shape is not CI's | **SUPPORTED** | `mutate-heartbeat.hbnovenv-c4cb36b9.log`: 38 caught lines, control survived, `ci-shape baseline rc=0 … answered the pin: yes`, the mutant caught by the named check, restore byte-identical. The real exit is `guarded_build: exit 0`, which is the child's rc (`tools/build_guard/guarded_build.sh:136-138`). The top-of-log `# rc=0 finished` is false, as the worker acknowledged. The shapecheck log proves only the "shim did not answer" branch, and it ran a sed-trimmed copy of the gate (disclosed). |
| 4' | Orchestrator `rerun-mutate.c4cb36b9.log` | **not judged (incomplete)** | It stops at mutant 25/38 (`report-makes-a-verdict`) with no VERDICT. The 25 lines it has match the worker's run. |
| 5 | check_gate_anchors 118/118; only change ok(39)→ok(40) | **SUPPORTED** | I compared pre and post line by line; the only difference is line 92. The orchestrator's rerun is identical. By code, `check_gate_anchors.py:850-853` (`python3 - "$FILE"` sets the target) and `:506` (`old = …`) mean the +1 is `"    PIN_PYS+=(python3)\n"` checked against `$SUITE` at HEAD. So the new anchor is watched by the anchor-check step of L1. |
| 6 | Not verified: real CI; CI's python3 importing topology_manager is inferred | **Accurately disclosed. The inference holds by source; real CI is UNTESTED.** | `topology_manager.py:1-12` imports only the stdlib, `networkx`, and `boot_identity` (time, uuid), `ryu_topology` (typing; networkx only lazily at `:250`) and `sflow_emitter` (stdlib). There is no `__init__.py` (namespace package). The only env read at import time is `NDTWIN_P4_BEACON_S` (`:385`), which the harness strips. `networkx==3.6.1` is pinned, and its METADATA says `Requires-Python: !=3.14.1,>=3.11`. |

## Internal consistency of the numbers

- **Consistent:** 196 − 2 tutorials checks = 194. CASES = 39 = 38 named + control; caught 39 = 38 + the suite mutant. Anchors 39 → 40. The secret scan's `117 insertions, 20 deletions` matches the hunk-by-hunk count (gate +86/−7, suite +31/−13). The "Killed" line moving from 328 to 334 equals the +6 lines of hunk 1. The PIDs on the Killed lines (15001…18779) are all below the detached guard pid 18943, so the suite logs were taken before the gate started mutating the helper.
- **Inconsistent:** (a) The mutate log's `# rc=0 finished` has the same timestamp as its start, and its body shows a ~7-minute run (acknowledged). (b) The shapecheck summary says "38 named + 1 control" when only the control ran; the counter uses `${#CASES[@]}`, not what actually ran. (c) The py312 header describes a networkx-only PYTHONPATH; the actual path is the whole site-packages directory.

## Your specific questions

- **Does the fallback weaken the pin?** Not in what it compares. The values are source literals and do not depend on the interpreter; the env override is stripped. The loop `break`s at the first successful import (`test_ndtwin_lab_heartbeat.sh:820-835`), so it cannot go looking for an interpreter that agrees. It does lose one diagnostic: before the fix, a venv that exists but fails to import was red (`import-failed`); now, if a later candidate answers, the failure is discarded (`tried` is printed only when every candidate fails). The only trace is the "pins' interpreter" line naming something other than the venv. That is acceptable, because the pin is about constants, not about the venv's health. It would be better if skipped candidates were printed as `--` lines.
- **Is the gate's CI-shape construction sound?** Yes. Assignments written before a function call in bash are exported to that function's children, and the log proves it: the shim answered. The PATH shim is sound; `%q` quotes the path. The suite snapshot, EXIT/INT/TERM trap, `restore` at the start of section 1b (which undoes the control mutant) and the final `cmp` are all sound. The `shim_answered` guard is the right control, and the shapecheck shows it has teeth. Limitation: the shape is structural only. The interpreter is the 3.13 venv via the shim, the tutorials tree is present, and `PYTHON=` is set empty rather than unset, which is equivalent for `${PYTHON:-}`.
- **Anything else likely to keep this file red in CI?** Not by the code. `HB_TEST_PY`/`HB_PYTHON=/usr/bin/python3` (`ndtwin-lab:642`) exists on ubuntu-24.04 and needs only the stdlib. A missing tutorials tree prints a `--` line and drops to 194 checks, which scores PASS. `ethtool_driver` is an ioctl that returns `<unknown…>` on OSError, not a call to a binary (`ndtwin-lab:941-951`). With no veth, the veth check prints a `--` line. `components.env` neither sets nor exports `PYTHON`, and no tool under `tools/` does either. This rests on the ticket's own CI output naming only the two pin cells; I did not observe it.

## Tests I would have run that the report did not

1. **Real CI.** Confirm this file's line in the L1 output reads PASS with 194 ran and names `/opt/hostedtoolcache/…/python3`, and that the problem-group count drops by one.
2. A real Python 3.12 venv with `pip install -r p4_proxy/requirements.txt` as python3 on PATH, using the copy trick with PYTHON and HB_PIN_VENVS unset and `TUT_EXERCISES=/nonexistent`.
3. A fall-through demonstration: `HB_PIN_VENVS=/usr/bin/python3` (exists, no networkx) plus an importing shim. Expect green with the shim named and `/usr/bin/python3`'s failure unshown.
4. Strict mode with an existing but failing interpreter: `PYTHON=/usr/bin/python3` plus an importing shim should be red and list only `/usr/bin/python3`.
5. `period-drift` run in CI shape, to prove the fallback interpreter's answer is compared and not just imported. Also export `NDTWIN_P4_BEACON_S=2` in CI shape to prove the env scrub reaches the fallback.
6. `tests/shell/check_test_tmpdirs.py` (L1 step 0b, runs in CI). By reading it, the risk is low: every new path comes from `mktemp` or from under `$MUT_DIR`.
7. Extra suite mutants: `shutil.which(py)` replaced by a path-exists test; `PIN_PYS=("$PYTHON" python3)` (removes strictness); deleting the interpreter `print` (today only a gate "no verdict", rc 2, not a catch).

## Findings

1. **note:** The real GitHub CI outcome is unverified. Check the first CI run after merge for this file's L1 line and the group count.
2. **note:** A broken venv is silently bypassed when a later candidate imports. Print the skipped candidates' reasons as `--` lines (`test_ndtwin_lab_heartbeat.sh:820-833`).
3. **note:** "Explicit PYTHON is strict" and "the interpreter is named" have no check in the suite that can go red. Only the gate's precondition guards the naming line (rc 2, not a caught mutant), and nothing guards strictness.
4. **note:** Header wording (`test_ndtwin_lab_heartbeat.sh:33-39`): "the pin is red only when none can import it" leaves out "or the constants disagree"; the CI-shape recipe leaves out unsetting `PYTHON`; `HB_PIN_VENVS` takes interpreter paths, not venvs.
5. **note:** The gate's "CI's shape" is structural only (the 3.13 venv behind the shim, tutorials present). The only Python 3.12 evidence is a one-off run with the whole 3.13 site-packages on PYTHONPATH; the header understates that.
6. **note:** Evidence hygiene: the setsid `# rc=0` line; the shapecheck has no timestamp; the shapecheck's counter line overstates what ran; the orchestrator's rerun-mutate was incomplete when read.
7. **note:** The hard-coded `/home/adam/Desktop/NDTwin-Kernel/...` main-checkout path was already there before this fix. It is now in the new default string (`:48`), while the gate works out `MAIN_WT` from `git worktree list`. Not introduced by this change.
