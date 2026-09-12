# old/ -- stale_app_pidfile_does_not_frame_the_fabric

[Co-developed with claude code -- Adam]

**Kind: last night's evidence, and it is this cell's own first live run.** Not a replay and not a
reconstruction: every file here was written by `cell_observe` against the live lab, and the
defect it shows is the one the tree still has.

| | |
|---|---|
| when | 2026-09-12 15:04:29 -> 15:05:14 CST |
| where | main checkout `/home/adam/Desktop/NDTwin-Kernel`, trunk `af5efa4f` (**before** FIX-NDT-9) |
| kernel | `build/bin/ndtwin_kernel` sha256[0:16] **`c4c8e50310d7e4a1`** (`ids.txt`) |
| `ndt` | blob **`54fd094e2dff10ccbe69a5a3b9028ca8b22c36bc`** (`ids.txt`) |
| driven by | `run_cells.sh --cell stale_app_pidfile_does_not_frame_the_fabric`, window 1 of the CELLS-2 live window (`hunt-0911/CELLS-2-LIVE-WINDOW.txt`), claim held by the orchestrator |
| runner log | `scratch/overnight-2026-09-05/logs/gates-0910/run_cells_stalepid.cells2-0912-r2.log` |

Every file is a byte copy out of
`.test_run/live_cells/2026-09-12/stale_app_pidfile_does_not_frame_the_fabric/`. Nothing was
edited, trimmed or re-indented. `flow_entries.json` (14 KB, the table at the moment the report was
taken) is the only observe output NOT copied -- the judge does not read it, and its count is here
in `flow_entries.count`.

## 🔴 The judge that produced the 7 ids in EXPECTED-FAILS is NOT the judge that ran live

The live run of 15:04:29 scored **13 ok / 4 FAIL** (`run_cells_stalepid.cells2-0912-r2.log` l.17,
and `judge.txt` in the raw). The judge has been changed three times since, twice because a
read-only audit found it wrong, and those changes are what make the set 7:

| id | live at 15:04 | now | why it changed |
|---|---|---|---|
| `stale_app_block_lists_no_rule` | **ok `[0]`** | FAIL `[62]` | the awk closed the block on the first rule it was meant to count (`^  [a-z]+ +window ` ends a block; `  XX        rule ...` does not) |
| `stale_check_rc_is_0` | FAIL `[1]` | *(gone)* | replaced: the rc is one number for every problem, and this run had two |
| `stale_check_raises_no_rules_in_window_problem` | *(did not exist)* | FAIL | counts the `  - ` problem lines about rules in a window |
| `stale_premise_no_app_was_running` | **ok** | FAIL | it grepped `none running`, which is the `apps` row, and passed with `untracked sim(1166836) -- running` on the next line |
| `stale_own_rule_gone` | *(did not exist)* | FAIL | the after-read really does still contain `10.99.99.99` |
| `stale_window_has_a_right_edge`, `stale_window_frames_no_rule`, `stale_check_does_not_list_them` | FAIL | FAIL | unchanged |

The replay that produced the current set is
`logs/gates-0910/run_cells_stalepid_replay.cells2-0912-r3.log`. **The raw was not touched** --
`judge` is a pure function of this directory, which is the whole reason a fixture can be re-judged
at all -- but a reader comparing this file with the runner log must know that the two numbers are
from two judges.

## Which of the 7 carry the finding

**The finding, and the four `mutate_live_cells.sh` mutates (M20, M21, M21c, M21d):**

| id | what it read here |
|---|---|
| `stale_window_has_a_right_edge` | `  te     window 2026-09-05 19:38:31 -> now (588377s)` -- the pidfile's process is dead and the window still runs to `now`. 588377 s is 6 days 19 h, not the 12.3 h of the 09-11 viz case RESIDUE-1 described; this cell's plant is dated from `app_te.log`'s own mtime |
| `stale_window_frames_no_rule` | the line under it is `  XX        rule  dpid=1 table=0 pri=65535 ...  installed 14s ago` |
| `stale_app_block_lists_no_rule` | 62 -- 61 rule lines plus the block's own `61 rule(s) listed:` summary |
| `stale_check_does_not_list_them` | `--check` printed `residue        122 rule(s) inside an app window, 0 lock(s) HELD` and under it `listed by:  ndt apps orphans` |
| `stale_check_raises_no_rules_in_window_problem` | `  - the network carries app residue: 122 rule(s) installed inside an app's window and 0 held lock(s)` |

122 is 61 + 61: the `te` pidfile this cell planted and the real `app_viz.pid` of 2026-09-11
14:04:25 each frame the same table once (`orphans.txt` l.87 and l.154). **61, not 60, because one
of them is this cell's own rule** -- the fabric's own baseline is 60. `viz_scene.txt` records that
the 09-11 file was still there and untouched.

**NOT the finding -- this run's own pollution, and mutated nowhere:**

- `stale_premise_no_app_was_running`. A `sim` belonging to another worktree's test fixture was on
  the machine (`check.log` l.37, `check: 2 problem(s)` at l.60). It did **not** touch the five ids
  above: its window was `sim window 2026-09-12 15:04:48 -> now (0s)` (`orphans.txt` l.19), zero
  seconds wide, and it framed nothing -- the two 61-rule blocks are viz and te. The premise's own
  oracle is `../control-untracked/`, not this directory.
- `stale_own_rule_gone`. This cell installed one rule and posted `delete_flow_entry`, which
  answered 200 -- and 200 means `entries accepted for programming`, not "it is off the wire".
  `flow_entries.after.json` still contains `10.99.99.99`, and the after-read was taken
  immediately. `observe` now polls for it to disappear; on this raw it simply was not, and the
  honest reading of this fixture is that the rule was still there when the report was written.
  The fabric was destroyed by the restore's `ndt down` about forty seconds later, so nothing
  outlived the run.

## What the first attempt got wrong, and why the premise assertions exist

`run_cells_stalepid.cells2-0912-r1.log`, 15:00:47, is kept and is NOT this fixture. It read the
kernel's flow table straight after `ndt up ovs 4` returned and got `[]`, so the open window framed
nothing and the assertions passed -- **on the buggy tree**.
`stale_premise_flow_table_not_empty` is what said so. `flow_poll.log` from this run explains it:

```
sample 1 at 1789196677: 0 entrie(s)
sample 2 at 1789196682: 0 entrie(s)
sample 3 at 1789196687: 61 entrie(s)
```

The table needs about ten seconds after the bring-up returns. `observe` now polls, and installs
one rule of its own (`install.body`, `install.code`) so that a rule whose install time is inside
the window exists whatever the fabric's own timing does.
