# new/ -- link_failure_cuts_both_ends_or_neither

[Co-developed with claude code -- Adam]

**The first fixed run, captured live.** `tools/test_workflow/live_cells/run_cells.sh` over all
nine cells, 2026-09-11 13:32:37-13:34:11 CST, `CELLS: 9/9 pass, 0 FAIL, 0 SKIP`, rc 0. Raw kept
at `scratch/overnight-2026-09-05/hunt-0911/logs/CELLS-1/raw-full/2026-09-11/link_failure_cuts_both_ends_or_neither/`;
the round's own log is `scratch/overnight-2026-09-05/logs/gates-0910/run_cells_all.cells1-0911-r1.log`.

Subject: the main checkout `/home/adam/Desktop/NDTwin-Kernel` at trunk `6c4000eb`, kernel
`build/bin/ndtwin_kernel` sha256[0:16] `048b842efa16178a`, `ndt` blob
`516e28a0a98585eb1e6be548b72e10bd0360dd14` -- all three recorded in `ids.txt` beside this file,
which is where the CELL: line reads them from.

Every file `observe` wrote is here except `judge.txt`: that is the judge's own output, it is
derived rather than observed, and `tests/shell/mutate_live_cells.sh` regenerates it on every run.
