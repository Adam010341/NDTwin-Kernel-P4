# SUMMARY: TICKET hb-test-no-venv (branch `fix/hb-test-no-venv-0926`)

(Worker's final reply, saved by the orchestrator 2026-09-26; content as delivered.)

**Branch head:** `c4cb36b9c400bb0a3c305a8375ffd2ea59d5b748`. This is one commit on trunk `68ace017`. Nothing was pushed or merged. The worktree is clean.
**Worktree:** /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-hb-novenv-0926
**Logs:** /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/*.hbnovenv-*.log. Line 1 of each log is the full sha it tested (`68ace017…` for the pre-fix runs, `c4cb36b9…` for the rest).

## Files changed (numstat)
| file | + | − |
|---|---|---|
| tests/shell/test_ndtwin_lab_heartbeat.sh | 31 | 13 |
| tests/shell/mutate_ndtwin_lab_heartbeat.sh | 86 | 7 |

## What changed
**Suite**
- If `PYTHON` is set, it is the only interpreter tried. That is today's behaviour.
- If `PYTHON` is unset, the candidates are, in order: the venvs in `HB_PIN_VENVS`, then `python3` on PATH. `HB_PIN_VENVS` is a new hook, `:`-separated; its default is the two paths used before (this checkout's `p4_proxy/venv`, then the main checkout's hardcoded one).
- The harness gets the candidates as `argv[5:]`. Section 7 resolves each one with `shutil.which` and tries to import `proxy_agent.topology_manager` with it. `NDTWIN_P4_BEACON_S` is still removed from the environment. The first interpreter whose import works answers.
- The interpreter that answered is printed as a note line: `  --       the pins' interpreter: <exe> [(python3 on PATH)]`.
- The two pin cells are red only in two cases:
  - No candidate can import the module. `actual` then holds each candidate's reason, e.g. `/nonexistent/...: not found | /usr/bin/python3: import failed: ModuleNotFoundError: No module named 'networkx'`.
  - The constants disagree.
- The header comment (old lines 33-34, now 33-39) describes the new default and how to get CI's shape.

**Gate**
- New mutant `pin-no-path-fallback`. It deletes `    PIN_PYS+=(python3)\n` from the **suite**, not from the helper.
- It runs in its own section 1b, in CI's shape:
  - `PYTHON=` (empty)
  - `HB_PIN_VENVS=/nonexistent/p4_proxy/venv/bin/python`
  - PATH's first `python3` is a shim that execs an interpreter the gate found able to import the proxy.
- The CI-shape baseline has to be green **and** print that the shim answered. Otherwise the gate gives no verdict (exit 2).
- The suite is now snapshotted, restored and byte-compared at the end, the same as the helper.
- I did not touch `apply()` or `write_case`, so the checker still attributes the other 39 anchors to the helper.

## Red first (pre-fix, `68ace017`)
| run | command | result | log |
|---|---|---|---|
| local, normal | `env -u PYTHON bash tests/shell/test_ndtwin_lab_heartbeat.sh` | 196 checks, 0 failed, rc 0 | suite-local.hbnovenv-pre-68ace017.log |
| R1 | `PYTHON=/nonexistent/python PATH=<shim-wrap>:$PATH bash tests/shell/test_ndtwin_lab_heartbeat.sh` | **196 checks, 2 failed, rc 1**: exactly the two pin cells (`'no-venv'`, `'/nonexistent/python'`) | suite-explicit-nonexistent.hbnovenv-pre-68ace017.log |
| R2, CI shape on the default path | copy of the suite in a scratch tree; `tools/`, `p4_proxy/`, `doc/` symlinked to the worktree (no venv there); only the main-checkout venv line sed'd to `/nonexistent/...` (diff is in the log); `env -u PYTHON PATH=<shim-wrap>:$PATH bash <copy>` | **196 checks, 2 failed, rc 1**: the same two cells, even with an importing python3 on PATH. L1's scorer says FAIL-RC. | suite-cishape-copy.hbnovenv-pre-68ace017.log |

`<shim-wrap>/python3` is `exec /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python "$@"`. A plain symlink does not work: I observed that it does not activate the venv (no networkx).

## Green after (`c4cb36b9`)
| case | command | result | log |
|---|---|---|---|
| (a) normal local | `env -u PYTHON bash tests/shell/test_ndtwin_lab_heartbeat.sh` | 196/0, rc 0; answered by the main venv | suite-local.hbnovenv-c4cb36b9.log |
| (b) CI shape | `env -u PYTHON HB_PIN_VENVS=/nonexistent/p4_proxy/venv/bin/python PATH=<shim-wrap>:$PATH bash …` | 196/0, rc 0; answered by `…/shim-wrap/python3 (python3 on PATH)` | suite-cishape.hbnovenv-c4cb36b9.log |
| (b) without the new hook | R2's copy procedure on the fixed suite, `HB_PIN_VENVS` unset | 196/0, rc 0; answered by the shim | suite-cishape-copy.hbnovenv-c4cb36b9.log |
| (b′) closest to CI | as (b), plus `TUT_EXERCISES=/nonexistent`; the shim is **Python 3.12.3** (`/usr/bin/python3` with `PYTHONPATH` set to the venv's pure-python networkx 3.6.1) | 194/0, rc 0 (2 fewer checks: the tutorials note, as on a runner); answered by the 3.12 shim | suite-cishape-py312.hbnovenv-c4cb36b9.log |
| (c) nothing can import | `env -u PYTHON HB_PIN_VENVS=/nonexistent/… PATH=/usr/bin:/bin bash …` (python3 = /usr/bin/python3 3.12.3; I checked it has no networkx) | **196 checks, 2 failed, rc 1**: `'no interpreter could import proxy_agent.topology_manager'` / `"…: not found \| /usr/bin/python3: import failed: ModuleNotFoundError: No module named 'networkx'"` | suite-nopy-usrbin.hbnovenv-c4cb36b9.log |
| (c′) same, with the ambient PATH | python3 = miniconda base, no networkx | 196/2, rc 1 | suite-nopy-ambient.hbnovenv-c4cb36b9.log |
| (d) explicit override is still strict | `PYTHON=/nonexistent/python PATH=<shim-wrap>:$PATH` | 196/2, rc 1 (`/nonexistent/python: not found`); the importing python3 on PATH is **not** used | suite-explicit-nonexistent.hbnovenv-c4cb36b9.log |
| (e) explicit override works | `PYTHON=<main venv python> HB_PIN_VENVS=/nonexistent/…` | 196/0, rc 0 | suite-explicit-venv.hbnovenv-c4cb36b9.log |

I also ran L1's own scorer over these logs (`shell_summary` and `l1_lane_verdict`, sourced with `NDTWIN_L1_LIB_ONLY=1`; nothing was built). Pre-fix R2 gives FAIL-RC; post-fix copy, (b) and (b′) give PASS; (c) gives FAIL-RC. Log: l1-scorer.hbnovenv-c4cb36b9.log. Its first line is c4cb36b9, but it also scores the pre-fix log.

## Mutation gate
- **Command:** `env -u PYTHON JOBS=1 LOCK_WAIT=10800 setsid tools/build_guard/guarded_build.sh ./tests/shell/mutate_ndtwin_lab_heartbeat.sh`
- **Result:** 38 named mutants, 1 control, and 1 suite mutant (**`pin-no-path-fallback`**): **caught 39, survived 0, invalid 0**. The control survived, as it should.
- **CI-shape pair:**
  - `ci-shape baseline rc=0 … answered the pin: yes`
  - `pin-no-path-fallback caught by: PERIOD_S is the proxy's LLDP_BEACON_INTERVAL_S`
- After the run, the helper and the suite were byte-identical to their snapshots.
- The guard's last line is `guarded_build: exit 0`. Log: mutate-heartbeat.hbnovenv-c4cb36b9.log.
- **Log caveat:** the `# rc=0 finished 04:26:56` line near the top of that log is setsid's own return code, not the gate's. setsid forked and returned immediately while the gate kept running detached. I appended a note to the log saying this. The gate's real exit code is the guard's `exit 0` line.
- **Check that the CI-shape assertion does something:** I ran the gate at HEAD, trimmed to the control only, with the **pre-fix** suite temporarily in the tree, then restored the suite with `git checkout`. The gate printed `answered the pin: no`, then `the unmutated suite is not green through the fallback in CI's shape -- no verdict`, and exited **rc 2**. So a fake CI shape is not scored. Log: mutate-heartbeat-shapecheck.hbnovenv-c4cb36b9.log.

## check_gate_anchors
- `python3 tests/shell/check_gate_anchors.py HEAD` gives **118/118 cells ok, rc 0**.
- Compared with the pre-change baseline (also 118/118), the only difference is `mutate_ndtwin_lab_heartbeat.sh ok(39)` becoming `ok(40)`.
- I called `extract()` directly to check where the checker counts the new anchor. It counts it in `tests/shell/test_ndtwin_lab_heartbeat.sh` (want 1); the other 39 stay on `tools/test_workflow/ndtwin-lab`; problems is empty.
- Only this gate refers to the suite, so no other gate's anchors moved.
- Logs: check-gate-anchors.hbnovenv-pre-68ace017.log, check-gate-anchors.hbnovenv-c4cb36b9.log.

## Observed vs inferred, and what I could not verify
- **Not verified: that GitHub CI goes back to 14 groups.** I did not run the real CI and did not push. Every "CI shape" above is a local stand-in: the venvs hidden by the hook or by a copy, and PATH's python3 replaced by a shim. The closest one used Python 3.12.3 with networkx borrowed from a 3.13 venv through PYTHONPATH. That is not setup-python's 3.12 with `pip install -r p4_proxy/requirements.txt`.
- **Inferred, not observed, that CI's python3 can import `topology_manager`:**
  - I found that the only non-stdlib module it pulls in is `networkx`. I measured this by importing it in the venv and listing new top-level modules.
  - networkx 3.6.1 is in requirements.txt.
  - ci.yml says setup-python is first on PATH.
- **Inferred from grep of l1_unit_tests.sh and ci.yml: neither sets `PYTHON`,** so CI takes the default path.
- **I did not create a 3.12 venv,** because that would mean downloading packages.
- **No lab, sudo, C++ build, `l1_unit_tests.sh` or `local_ci.sh` runs.** The only thing run from l1 was its scorer functions, in lib-only mode.
- **Helper files are in the session scratchpad,** which is not kept: the shims, the scratch-tree copies, and the trimmed gate `gate-trim.sh`. Each log header records what was used.

DELIVERED c4cb36b9c400bb0a3c305a8375ffd2ea59d5b748
