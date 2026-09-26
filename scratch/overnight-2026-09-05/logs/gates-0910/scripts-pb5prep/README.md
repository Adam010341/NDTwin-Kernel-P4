# scripts-pb5prep — worker pb5prep (2026-09-26), branch fix/p4proxy-protobuf5-0926

[Co-developed with claude code -- Adam]

Offline verification of the protobuf-5 candidate rebased on trunk. Logs are
`../<name>.pb5prep-<sha8>.log`: first line `# HEAD <full sha>`, last line `rc=<n>`. Every venv
these scripts make lives under the worktree's `scratch/pb5prep/` (gitignored).
The main checkout's `p4_proxy/venv` is only ever run with `PYTHONDONTWRITEBYTECODE=1`, and
fingerprinted before and after (`mainvenv_fp.sh`).

| file | what |
|---|---|
| `common.sh` | paths, sha, `new_log`, `pyid`, main-venv fingerprint |
| `phase0_prep.sh` | main venv fingerprint, .gitignore red/green v1 (**its expectation was wrong**, see v2), copy of `p4_src/build` |
| `phase0b_gitignore_v2.sh` | .gitignore red/green with sample paths no other rule covers (the rule was dropped again in `ac8f0f3f`) |
| `mainvenv_fp.sh` | main venv fingerprint, read-only |
| `l1_derive.py` | copy of `l1_unit_tests.sh` with the C++ sections cut (and `--ci`: the p4dev fallback path replaced) |
| `phase1_py312.sh` | 3.12 venv by the install commands; CI-shaped l1 P4 lane before and after regen; regen prefix refusal |
| `gen_rehearsal.py` | turns requirements.txt's "UPGRADING AN EXISTING VENV" into a script that runs its commands verbatim (only V and PARK edited); asserts the procedure's shape |
| `phase2_rehearsal_forward.sh` | stand-in old venv (trunk's file, protobuf 3.20.3) + blocks 1-3 of the procedure |
| `phase3_suites.sh` | both suites, one verdict per test id (REQ's `verdicts.py`) |
| `phase3_lanes.sh` | l1's Python lanes (C++ cut) with `P4_PROXY_PY=<python>` |
| `phase4_misc.sh` | import coverage, pins vs venvs, the thrift CLI recipe's imports |
| `phase5_rehearsal_rollback.sh` | ROLLBACK and ROLLBACK IN PLACE blocks + in-place repair |
| `phase6_verdictdiff.sh` | whole per-id diffs between two labels |
| `run_all.sh` | every phase in order at the current HEAD (the 08483aa5 run) |
| `phase7_trunk_ab.sh` | the same derived lanes with the worktree detached at trunk 580767a8 (then back on the branch); `test_apps_residue.sh` x3 at HEAD |
| `phase8_final.sh` | on the final HEAD: procedure commands identical to the rehearsed ones, comment-only diff since 08483aa5, gate anchors, the wedge-guard test, a publication scan of the added lines |
| `verdicts.py`, `check_imports_vs_requirements.py`, `check_pins_vs_venv.py` | REQ's tools, copied unchanged (`FROM-scripts-p4req.sha256` = their `SHA256SUMS.r2` values) |

`SHA256SUMS` = the scripts as last run. Superseded runs, kept as written: `*.pb5prep-98e9f873.log` (the gitignore checks; the py312 lane was stopped while waiting for the lock) and `*.pb5prep-958bec1c.log` (phase 1 and a RED rehearsal that found the step-3 defects fixed in 8f10b203).
