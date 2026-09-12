# control-untracked/ -- the negative control for `stale_premise_no_app_was_running`

[Co-developed with claude code -- Adam]

🔴 **THIS IS NOT `old/` AND NOT `new/`, AND IT IS SYNTHETIC ON PURPOSE.** The three rules in
`tests/fixtures/live_cells/README.md` are about `old/` -- last night's evidence, never written by
hand. A negative control is the opposite kind of object: it is a reading that would PASS but for
one line, written so that exactly one assertion has something to be wrong about.
`tests/shell/mutate_live_cells.sh` step (a3) requires `judge` on this directory to fail with the
failing set **`stale_premise_no_app_was_running`, and nothing else**.

## Why it has to exist

`(a)` can only redden an assertion that is red on `old/`. A premise that is green on both fixtures
has no oracle at all -- so the first draft of this cell shipped a premise that passed while a
foreign app process was on the machine. It asserted `a_has ... 'none running'`, and `none running`
is the `apps` row, which is about apps **this checkout tracks**. In the very run `old/` came out
of, that row said `apps  none running` and the row under it said
`untracked  sim(1166836) -- running` -- a test fixture belonging to another worktree. The premise
passed. The read-only auditor found it; this directory is what stops it coming back.

## Where the bytes came from

| | |
|---|---|
| `flow_entries.after.json` | `../old/flow_entries.after.json` with the one rule this cell installs (`10.99.99.99`) filtered out, so that `stale_own_rule_gone` -- which reads the table and not the delete's status code -- is green here. Without it this directory would redden two ids and stop being a control for one. |
| every other file except `check.log` | the hand-written expected-green raw the CELLS-2 agent used on 2026-09-12 15:21 to show this judge can pass at all before window 2 supplies a real `new/` (`logs/gates-0910/judge_dryrun_expected_green.cells2-0912-r1.log`). **Written by hand**, in this cell's raw layout, with the values a fixed tree would produce: a closed `te` window, `no flow entry arrived during that window`, `check.rc` 0, 60 rules on the wire. |
| `check.log`'s four `untracked` lines | **verbatim from `../old/check.log` lines 37-40**, the real reading `ndt status --check` produced at 15:04:47. Nothing about them is invented -- the pid, the wording and the three continuation lines are `ndt`'s own. |

So the ONE thing that differs between this directory and a clean fixed-tree reading is four lines
of real `ndt` output, inserted after the `apps` row where `ndt` itself puts them.

## What it does NOT prove

That the premise is right about the machine -- only that it reads the row. Whether an untracked
app process really can open a legitimately-wide window is measured nowhere in this directory;
`CELLS.md` §what these cells do NOT cover item 8 says so.
