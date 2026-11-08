# new/ -- default_round_plane_is_classified

[Co-developed with claude code -- Adam]

**The first fixed run, captured live.** `tools/test_workflow/live_cells/run_cells.sh` over all
nine cells, 2026-09-11 13:32:37-13:34:11 CST, `CELLS: 9/9 pass, 0 FAIL, 0 SKIP`, rc 0. The raw is
that cell's directory of the round; it and the round's own log are kept outside this
repository.

Subject: the main checkout at trunk `6c4000eb`, kernel
`build/bin/ndtwin_kernel` sha256[0:16] `048b842efa16178a`, `ndt` blob
`516e28a0a98585eb1e6be548b72e10bd0360dd14` -- all three recorded in `ids.txt` beside this file,
which is where the CELL: line reads them from.

Every file `observe` wrote is here except `judge.txt`: that is the judge's own output, it is
derived rather than observed, and `tests/shell/mutate_live_cells.sh` regenerates it on every run.
