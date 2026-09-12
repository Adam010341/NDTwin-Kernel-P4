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
edited, trimmed or re-indented. `flow_entries.json` (14 KB of the whole table) and
`flow_entries.after.json` are the only observe outputs NOT copied -- the judge does not read
them, and their counts are here in `flow_entries.count` / `flow_entries.after.count`.

## The five assertions that carry the finding

All five, and they are the whole of `EXPECTED-FAILS`:

| id | what it read here |
|---|---|
| `stale_window_has_a_right_edge` | `  te     window 2026-09-05 19:38:31 -> now (588377s)` -- the pidfile's process is dead and the window still runs to `now` |
| `stale_window_frames_no_rule` | the line under it is `  XX        rule  dpid=1 table=0 pri=65535 ...  installed 14s ago`, not `no flow entry arrived during that window` |
| `stale_app_block_lists_no_rule` | 62 -- 61 rule lines plus the block's own `61 rule(s) listed:` summary |
| `stale_check_does_not_list_them` | `--check` printed `residue        122 rule(s) inside an app window, 0 lock(s) HELD` and under it `listed by:  ndt apps orphans` |
| `stale_check_rc_is_0` | `check.rc` is `1`: `- the network carries app residue: 122 rule(s) installed inside an app's window and 0 held lock(s)` |

122 is 61 + 61: the `te` pidfile this cell planted and the real `app_viz.pid` of 2026-09-11
14:04:25 each frame the same whole table. `viz_scene.txt` records that the 09-11 file was still
there and untouched when this ran.

**There is no fixture gap here.** Every other assertion passes, and the nine that pass are the
premises and the controls -- this run had a dead pid, a pidfile 588358 s older than the bring-up,
a converged fabric, 61 rules on the wire and no app running.

## What the first attempt got wrong, and why the premise assertions exist

`run_cells_stalepid.cells2-0912-r1.log`, 15:00:47, is kept and is NOT this fixture. It read the
kernel's flow table straight after `ndt up ovs 4` returned and got `[]`, so the open window
framed nothing and four of the five assertions above passed -- **on the buggy tree**.
`stale_premise_flow_table_not_empty` is what said so. `flow_poll.log` from this run explains it:

```
sample 1 at 1789196677: 0 entrie(s)
sample 2 at 1789196682: 0 entrie(s)
sample 3 at 1789196687: 61 entrie(s)
```

The table needs about ten seconds after the bring-up returns. `observe` now polls, and installs
one rule of its own (`install.body`, `install.code`) so that a rule whose install time is inside
the window exists whatever the fabric's own timing does.
