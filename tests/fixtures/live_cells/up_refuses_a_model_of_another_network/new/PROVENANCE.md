# new/ -- up_refuses_a_model_of_another_network

[Co-developed with claude code -- Adam]

**The first run of the fixed cell against the fixed tool, captured 2026-09-12 04:49:39 CST.**
Regenerated here because the cell's `observe` changed: it now parks the knob at 128 itself and
puts the tree's bytes back afterwards, so the raw layout gained `knob.entry` and
`knob.restored` and `knob.before` is the value the cell established rather than the one the
tree happened to hold.

**🔴 NOT A LIVE RUN, and the reason is in the round, not in the cell.** The lab was held by
another role that night (ROLE-10, P4 128-host traffic), and FIX-NDT-7's ticket forbade touching
it. This raw comes from running `observe` alone, offline:

    NDT_ROOT=<worktree> NDT_OWNER=overnight-0905 \
      bash tools/test_workflow/live_cells/up_refuses_a_model_of_another_network.sh observe <dir>

against `scratch/overnight-2026-09-05/wt-ndt7-0912` on branch `fix/ndt-7-0912`. That is the
whole cell: this one refuses inside `up_p4` before the claim check, the in-flight check and
preflight, so it touches no lab even when it is run on one -- the header says so and ROLE-9
measured it twice at 0.1 s with `[1/3]` zero times. The subject is `ndt` blob
`b1d02994ff59b72866a3d15acdf2dbda7251e489`, recorded in `ids.txt` beside this file.

`kernel=unknown` in `ids.txt` is correct and not a gap: a worktree has no `build/bin/`, and
`cell_write_ids` records `unknown` rather than filling the hole from another tree. This cell's
subject is a shell script, and its identifier -- the git blob sha -- is there.

`knob.entry` is `128` because that is what HEAD commits and what a fresh worktree carries; the
cell's premise value is also 128, so its write was a no-op **in this tree** and the restore
had nothing to undo. On Adam's main checkout the two differ (entry 4, premise 128) and both
halves do real work. `git status --porcelain -- p4_proxy/mininet/host_count_override` was empty
before and after the run.

Every file `observe` wrote is here, plus `observe.rc` (0). `judge.txt` is not: it is the judge's
own output, it is derived rather than observed, and `tests/shell/mutate_live_cells.sh`
regenerates it on every run.
