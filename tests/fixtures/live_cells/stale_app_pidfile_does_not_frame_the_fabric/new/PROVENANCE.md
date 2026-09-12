# new/ -- stale_app_pidfile_does_not_frame_the_fabric

[Co-developed with claude code -- Adam]

**The first green run, captured live, on the tree that carries the fix.** FIX-NDT-9 (merged as
`53a62c71`) closes an app's window at its log's last write once the pid is dead
(`app_window_seal`), so a stale pidfile no longer frames the fabric's own forwarding rules as that
app's rules-in-window. This directory is the orchestrator's "window 2" run of this one cell:
`tools/test_workflow/live_cells/run_cells.sh --cell stale_app_pidfile_does_not_frame_the_fabric`,
2026-09-12 16:34:52-16:35:47 CST, `CELLS: 1/1 pass, 0 FAIL, 0 SKIP`, 18 assertions ok, restore
quartet clean (down 0, clean 0, VERDICT: CLEAN before and after, final --check rc 3). The cell
observed at 2026-09-12T16:34:53+08:00. Raw kept at
`scratch/overnight-2026-09-05/hunt-0911/logs/cells-window2-0912/raw/stale_app_pidfile_does_not_frame_the_fabric/`;
the round's log is `scratch/overnight-2026-09-05/logs/cells-window2-0912/run_cells.53a62c71-r1.log`
(driver: `driver.log` beside it).

Subject: the main checkout `/home/adam/Desktop/NDTwin-Kernel` at trunk `53a62c71`, kernel
`build/bin/ndtwin_kernel` sha256[0:16] `c4c8e50310d7e4a1`, `ndt` blob
`a6b2029c4db5bf38b3413843839675d0d576f928` -- all recorded in `ids.txt` beside this file, as
`run_cells.sh` wrote them. Nothing in this directory was edited after capture; `PROVENANCE.md` is
the only file added.

The pair: `../old/` is the same cell on `af5efa4f` (before the fix, window 1, 15:04:29) where the
window ran to "now" and 122 rules were counted inside it; here `stale_window_has_a_right_edge` =
closed, `stale_window_frames_no_rule` = none, `stale_own_rule_gone` reads the table back. The real
stale pidfile from 09-11 14:04 (`.test_run/pids/app_viz.pid`) was still present during both
captures; the cell plants and removes its own, so it does not depend on that file.
