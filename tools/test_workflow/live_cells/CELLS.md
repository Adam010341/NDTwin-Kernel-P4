# live_cells -- the regression grid

[Co-developed with claude code -- Adam]

A **cell** is one reproducible action sequence plus one expected verdict. Not a role, not a suite.

* **Entry rule:** a finding enters when it was seen RED for real -- live on the lab, or run
  offline against the tool -- and then fixed. **It never leaves.**
* **The number:** how many cells are red. That is what a night round reports, and it is the only
  number here that is meant to be monotone.
* **A cell going red** is 🔴 at the top of that night's notes (kept outside this repository) and a
  must-fix that night.
* **When to run:** round 0 of a night round (while the code is being read),
  and after every merge that touches `ndt`, the kernel, or the proxy -- `--tag` picks the subset.

```
tools/test_workflow/live_cells/run_cells.sh --list
tools/test_workflow/live_cells/run_cells.sh --requires none     # safe while somebody holds the lab
NDT_ROOT=<checkout> tools/test_workflow/live_cells/run_cells.sh --tag ndt
```

`NDT_ROOT` names the checkout whose `ndt` is driven. The cells are the instrument; the tree under
test is whichever one `NDT_ROOT` points at, and on this machine only the main checkout's `ndt` is
the one `sudo ndtwin-lab` acts for.

## The cells

The raw logs and investigation write-ups named in the `source` column are kept outside this repository.

| name | tag | requires | source: night / run / raw log | fix | expected verdict | `old/` fixture |
|---|---|---|---|---|---|---|
| `up_target_names_a_readable_model` | ndt | ovs4 | 09-11, one session's live run on both planes (§① of its write-up). `51a-up-p4-A.log` (rc 1, 318 s), `20-up-ovs4.log` | `ce2ae2f9` → trunk `5e7a91c8` | `ndt up ovs 4` reaches rc 0, prints no `cannot read expected counts from`, and `.test_run/up.target` carries a 64-hex `topology_sha256`, a counted `model_hosts` and a one-line `topology` path | captured log; **no `up.target` kept** -- see its PROVENANCE.md |
| `up_refuses_a_model_of_another_network` | ndt | idle | 09-11, live (cycle 07). `cycle-07-up.log` (rc 124 after 300 s, ten switches built); the knob half is a second session's measurement of 09-12, runs 4b and 4c (`c4b-metrics.log`, `c4c-metrics.log`) | `76b5d434` (merged `954ab467`); knob half FIXED-ISSUES G-47 | the cell **parks `host_count_override` at 128 itself**, then `NDT_TOPO=<128-host model> ndt up p4 4` refuses in 0 s naming both counts, builds nothing, records no target, and leaves the knob byte-identical **to the 128 the cell set** -- and the cell puts the tree's own bytes back and records that it did | captured log; two ids added 09-12 -- one evidence, one fixture gap, see its PROVENANCE.md |
| `up_refuses_while_a_down_is_in_flight` | ndt | idle | 09-11, live (cycle 13). `cycle-13-up-B.log` (`already up: … reusing`, `model matches fabric` on a dying fabric) | `019b125d` (merged `cb5ab923`) | a bring-up overlapping an `ndt down` is refused rc 5 within 30 s, the refusal quotes `.test_run/down.inflight`, and the marker is gone afterwards | captured log; the marker is `(absent)` because the marker IS the fix |
| `half_stack_is_not_clean` | ndt | ovs4 | 09-11, live (cycle 07). `cycle-07-probe-afterup.log` (`VERDICT: CLEAN` over 10 bmv2 + 14 mininet and no kernel) | `6d081d13` (merged `954ab467`) | whole stack → `VERDICT: CLEAN` / `verdict=whole-up`; kernel stopped by its own pidfile → `VERDICT: NOT CLEAN`, `the stack is HALF up`, rc 1, `verdict=HALF` in the report | captured log, **thin** (one `VERDICT:` line) -- see its PROVENANCE.md |
| `recovery_refuses_foreign_netem` | kernel | ovs4 | 09-11, live 3/3. `07-inject-recovery.log`, `08-tc-after-recovery.log`, premise in `04-tc-netem-on.log` | `0b928fe6` (merged `6c4000eb`; FIXED-ISSUES B-16) | `POST /ndt/inject_link_recovery` on an undeclared link carrying a foreign netem → **409**, `netem_not_ours`, `Nothing was changed`, and the qdisc still on the wire | captured log |
| `link_failure_cuts_both_ends_or_neither` | kernel | ovs4 | 09-11, live 2/2. `06-inject-failure.log` (`netem 801e` really on s5-eth1, status `link failure injected`) | `0b928fe6` (merged `6c4000eb`; B-16) | one end refused → **neither** end carries netem, the status line says `link failure declared; nothing was attached`, the body says which half happened, and the declaration stands | captured log |
| `orphans_blind_probes_not_checked` | ndt | none | 09-11 offline investigation (§1.11 of its write-up), run for real offline | `ded00d06` (merged `954ab467`) | a report with the kernel up and all three lock probes `NOT CHECKED (http 500)` → `VERDICT: NOT CHECKED` rc 3, and **not** the token `VERDICT: CLEAN` | replay of `ded00d06^` |
| `help_drops_deleted_claims` | ndt | none | 09-11 offline investigation (§1.12 and §1.24 of its write-up), run for real offline | `3259d296` (merged `954ab467`) | `ndt help` no longer carries the `has run in THIS checkout` sentence nor the blanket environment-variable guarantee, and does carry the scoped replacements | replay of `3259d296^` |
| `default_round_plane_is_classified` | ndt | none | 09-11 offline investigation (§1.15 of its write-up), run for real offline with its own positive control | `ca9af4f1` (merged `954ab467`) | `last_kernel_plane` reads `Mininet_*` as ovs, `OVS_*` as ovs, `P4_*` as p4, and a physical-mode command as rc 1 / no plane | replay of `ca9af4f1^` |
| `stale_app_pidfile_does_not_frame_the_fabric` | ndt | ovs4 | 09-12 read-only investigation (§1 §2 §6 of its write-up) of `05-check-after-up.log` (`residue 60 rule(s) inside an app window` 22 s after a bring-up that installed them). This cell's own live run of 15:04 is the red | `53a62c71` (the merge of the fix) | the app window opened by a pidfile whose process is dead has a right edge, frames no rule of a fabric built later, and `ndt status --check` carries no `listed by:  ndt apps orphans` line and no problem line about rules inside an app window (the judge does not read that command's rc) | **this cell's own live run**, 2026-09-12 15:04, kernel `c4c8e50310d7e4a1` |
| `northbound_write_reply_names_the_lab_claim` | kernel | ovs4 | 09-11 02:01-02:02, live (§7-1 of a write-up kept outside this repository): writes kept answering 200 across an expiry and across a change of owner | `ea517ed5` (merged `f313b1a4`; FIXED-ISSUES G-32) | both writes of an inject/recover pair and the 400 from an unparseable body carry a `lab_claim` whose `owner`/`expires_at` are `.test_run/lab.claim`'s; a POST outside the twelve and a GET do not | pre-fix reply bodies recorded by another session on 09-12, **thin** -- see its PROVENANCE.md for which two ids are evidence |

`requires` is what a cell NEEDS, and `run_cells.sh --requires` filters on it:

| | |
|---|---|
| `none` | nothing at all. Safe to run while another session holds the lab |
| `idle` | the lab must be down; the cell runs an `ndt` verb that would otherwise refuse or interfere |
| `ovs4` / `p4-4` | the cell brings that fabric up itself, and leaves it up for `run_cells.sh` to take down |

## The red half

`tests/fixtures/live_cells/<cell>/old/` is the raw a pre-fix run produced, and
`tests/shell/mutate_live_cells.sh` requires `judge old/` to fail with exactly the assert ids
`old/EXPECTED-FAILS` names. `tests/fixtures/live_cells/README.md` states the three rules those
directories live by; each `old/PROVENANCE.md` says where every byte came from and -- where the
old evidence is thinner than the judge -- which failing assertions are evidence and which are a
fixture gap.

## Fixture state

- **Every cell has a `new/` fixture.** The gate reports a cell without one as PENDING and counts
  it separately; PENDING is not passing. `up_refuses_while_a_down_is_in_flight` had its `new/`
  replaced when a refused `ndt up` began exiting 5; the first capture, which says 1, is kept as
  `new-0911-pre-rc-contract/`.
- **`stale_app_pidfile_does_not_frame_the_fabric` is red on its `old/` raw and green on its
  `new/`.** `ndt` closes an app's window at its log's last write once the pid is dead
  (`app_window_seal`), so a stale pidfile no longer frames the fabric's own rules. `judge old/`
  fails with exactly the seven ids in `old/EXPECTED-FAILS`; `judge new/` passes (18 asserts).
  It is also the one cell whose `observe` WRITES to the shared `.test_run/`: it plants
  `.test_run/pids/app_te.pid` and removes it again, with an EXIT trap, and never touches
  `app_viz.pid` -- the 2026-09-11 stale one, which this cell leaves for whoever owns the shared
  `.test_run/` to clear.

## 🔴 What these cells do NOT cover

Said here rather than left to be discovered, because a grid that is read as "the fixes are
verified" is worse than no grid.

0. 🔴 **`h4_knob_unchanged` has no fixture that reddens it either, and the reason is not the
   one above.** The second session's runs 4b and 4c ARE runs where a refused `ndt up p4 <n>` left the knob
   rewritten (`340a` -> `3132380a` and the mirror), which is exactly what that assertion is
   for -- but `old/` for this cell is the 09-11 cycle-07 run, where the knob was 4 both times. What
   `old/` can redden is the PREMISE (`h4_knob_could_show_a_rewrite`), and it does. The write
   itself is mutated where the subject lives: `tests/shell/test_ndt_up_down_robust.sh` §18 and
   `mutate_ndt_up_down_robust.sh` M53-M58. A cell whose `old/` is run 4b would close this;
   it is proposed in §7 of the write-up of the 2026-09-12 knob fix
   (kept outside this repository) and not written.
1. **Control assertions have no fixture that reddens them.** Every cell carries assertions for
   the wrong-fix direction -- `f10_p4_is_not_swallowed`, `f10_physical_is_still_unknown`,
   `h2_whole_stack_is_clean`, `a1r_far_end_untouched`, `a1f_declaration_still_stands`. They pass
   on `old/` by design, so deleting one changes no failing set and `mutate_live_cells.sh` cannot
   catch it. Those directions are mutated where the subject lives: `mutate_ndt_honesty.sh`,
   `mutate_ndt_up_down_robust.sh`, `mutate_orphans_verdict.sh` and the B-16 C++ gates.
2. **`up_refuses_while_a_down_is_in_flight` overlaps a teardown of an EMPTY lab**, not of a live
   10-switch stack. So did the session that re-measured it, and for the same reason it wrote down: the guard is in
   `preflight`, before anything reads the machine, so the code path is the same one -- but "the
   teardown of a live fabric was overlapped" is still not measured by anybody.
3. **`up_target_names_a_readable_model` drives OVS; its `old/` is the P4 arm.** The session behind `old/` has no rc
   for the OVS arm at all (its own tool timeout killed the wrapper past 120 s). Two copies of the
   same three lines, one plane each.
4. **The `(c)` half of the gate -- re-running `observe` against the pre-fix tool -- is done for
   the three `requires=none` cells only.** The eight others would need a pre-fix `ndt` driving a
   real bring-up (318 s, or a fabric built and hung) or a pre-fix KERNEL rebuilt from
   `0b928fe6^`. The gate lists each one with its reason.
5. **The lab_claim cell's negative half reads a 404, not a state-changing POST outside the
   twelve.** `acquire_lock` and `set_switches_power_state` are POSTs that do something and are
   deliberately unmarked; staging one costs the lab a lock acquire or a power write. That
   direction is mutated in `tests/shell/mutate_lab_claim_on_writes.sh` (M8), which marks every
   POST and must be caught.
6. **No cell here measures a window that is legitimately open.** Every window these cells stage
   belongs to a process that is dead. An app that is really running has a window that runs to
   `now` and really can have installed the rules inside it -- that is not a defect, and
   `stale_app_pidfile_does_not_frame_the_fabric` sidesteps it with a premise
   (`stale_premise_no_app_was_running`) rather than measuring it.

## Registered and NOT converted

From the night's list of candidates (kept outside this repository; the numbering is that list's). These are the candidates this round
declined, each with the reason -- a cell forced into existence here would be a cell nobody can
trust.

| # | why not |
|---|---|
| 21 `NDT_TOPO=<path outside the repo>` makes `ndt status`'s plane read `names no model this script can classify` | **not fixed.** `ca9af4f1` brought `Mininet_*` into the OVS family; a path whose basename matches neither pattern still classifies as nothing. The entry rule is "red, then fixed", and this one is still open |
| 22 T1, two owners win `ndt claim` in the same second | writing `.test_run/lab.claim` IS the lab's state. Whoever runs the grid live holds the lab claim, and a cell that ran `claim`/`release` would take it from them; against a copied tree it stops being live and becomes `test_ndt_honesty.sh` §6, which already has it |
| 23 T2d, `measuring=` does not protect the owner's own `ndt down` | needs the real claim's `measuring=` written, and then a REGRESSION would tear down whoever's fabric is up. Not a cell to run unattended |
| 25 T2, the foreign-`down` refusal is unpasteable and silent about `measuring=` | cheap and genuinely live -- but if the guard regresses, the cell IS a teardown of somebody else's lab. Not written for that reason |
| 26 T5, `ndt up` writes the wrong note when it is not the owner | needs claim ownership, as 22 |
| 27 T3, same-second double-open | the hypothesis was **falsified** -- `ndt down` did collect both processes. What `daa2d0e7` fixed is a sentence in `ndt status`, and there is no live red to convert |
| 31 I-3, `*.pid` naming a dead pid while `*.exit` records the SIGTERM | The investigation behind it was read-only and kept **no raw `ndt status` output**, only prose. The `old/` fixture would have to be reconstructed by hand, and a reconstruction the author writes is not last night's evidence. A `(c)` run of the pre-fix `ndt status` over a staged `pids/` would be a real red; that raw does not exist yet |
| 33 a session's three re-measurements | **converted**: they are `half_stack_is_not_clean`, `up_refuses_while_a_down_is_in_flight`, `up_refuses_a_model_of_another_network`, plus `up_target_names_a_readable_model` for the regression that session found underneath them |
| 34 I-2, `lab.claim.prev` keeps the replaced claim | needs `ndt claim`, as 22 |
| 10 / F1, `ndt up p4` printed the LIVE plane's sampling rate | the property is which ARGUMENT the call site passes, and observing it needs the whole `up_p4` stub seam -- which is what `test_ndt_up_down_robust.sh` §10 is. A live form would need an OVS fabric up while a P4 bring-up runs; the lab has one fabric |
| 10 / F9, two `--check` suites read the main checkout's root-owned log | the subject is two test suites, not the lab. A cell would be a grep over test sources, which is a gate's job |
