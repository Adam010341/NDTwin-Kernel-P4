# new/ -- up_refuses_while_a_down_is_in_flight

[Co-developed with claude code -- Adam]

**Re-captured live under the rc contract FIX-NDT-8 introduced.** The previous `new/` (now
`../new-0911-pre-rc-contract/`, retired with its own `RETIRED.md`) was captured on 2026-09-11 when a
refused `ndt up` still exited 1; since `af5efa4f` (merge of `fix/ndt-8-0912`) a refusal exits 5, and
the cell's judge (`h3_up_rc_is_5`) reads that. This directory is the first green run under that
contract, taken by the orchestrator's post-merge `--tag ndt` round: `tools/test_workflow/live_cells/run_cells.sh --tag ndt`,
2026-09-12 14:41:13-14:42:24 CST, `CELLS: 7/7 pass, 0 FAIL, 0 SKIP`, rc 0; this cell observed at
2026-09-12T14:41:47+08:00. Raw kept at
`scratch/overnight-2026-09-05/hunt-0911/logs/cells-post-ndt8-0912/raw/up_refuses_while_a_down_is_in_flight/`;
the round's log is `scratch/overnight-2026-09-05/logs/cells-post-ndt8-0912/run_cells.af5efa4f-r1.log`
(driver: `driver.log` beside it -- claim, baseline, restore quartet, release, every rc printed).

Subject: the main checkout `/home/adam/Desktop/NDTwin-Kernel` at trunk `af5efa4f`, kernel
`build/bin/ndtwin_kernel` sha256[0:16] `c4c8e50310d7e4a1`, `ndt` blob
`54fd094e2dff10ccbe69a5a3b9028ca8b22c36bc` -- all recorded in `ids.txt` beside this file, as
`run_cells.sh` wrote them. Nothing in this directory was edited after capture; `PROVENANCE.md` is the
only file added.

What the files say: `up.rc` = 5 (the refusal), `down.inflight` / `down.inflight.after` (the down that
was in flight when `up` was asked), `down.rc` = 0, `observe.rc` = 0, `judge.txt` (the judge's own
lines on this raw).
