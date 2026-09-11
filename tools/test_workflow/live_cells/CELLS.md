# live_cells -- the regression grid

[Co-developed with claude code -- Adam]

A **cell** is one reproducible action sequence plus one expected verdict. Not a role, not a suite.

* **Entry rule:** a finding enters when it was seen RED for real -- live on the lab, or run
  offline against the tool -- and then fixed. **It never leaves.**
* **The number:** how many cells are red. That is what a night round reports, and it is the only
  number here that is meant to be monotone.
* **A cell going red** is 🔴 at the top of `WAKEUP.md` and a must-fix that night.
* **When to run:** round 0 of a night round (while the reconnaissance agents are reading code),
  and after every merge that touches `ndt`, the kernel, or the proxy -- `--tag` picks the subset.

```
tools/test_workflow/live_cells/run_cells.sh --list
tools/test_workflow/live_cells/run_cells.sh --requires none     # safe while somebody holds the lab
NDT_ROOT=/home/adam/Desktop/NDTwin-Kernel tools/test_workflow/live_cells/run_cells.sh --tag ndt
```

`NDT_ROOT` names the checkout whose `ndt` is driven. The cells are the instrument; the tree under
test is whichever one `NDT_ROOT` points at, and on this machine only the main checkout's `ndt` is
the one `sudo ndtwin-lab` acts for.

## The cells

| name | tag | requires | source: night / role / raw log | fix | expected verdict | `old/` fixture |
|---|---|---|---|---|---|---|
| `up_target_names_a_readable_model` | ndt | ovs4 | 09-11 ROLE-6 §①, live both planes. `hunt-0911/logs/ROLE-6/51a-up-p4-A.log` (rc 1, 318 s), `20-up-ovs4.log` | `ce2ae2f9` → trunk `5e7a91c8` | `ndt up ovs 4` reaches rc 0, prints no `cannot read expected counts from`, and `.test_run/up.target` carries a 64-hex `topology_sha256`, a counted `model_hosts` and a one-line `topology` path | captured log; **no `up.target` kept** -- see its PROVENANCE.md |
| `up_refuses_a_model_of_another_network` | ndt | idle | 09-11 ROLE-2 cycle 07, live. `logs/ROLE-2/cycle-07-up.log` (rc 124 after 300 s, ten switches built) | `76b5d434` (merged `954ab467`) | `NDT_TOPO=<128-host model> ndt up p4 4` refuses in 0 s naming both counts, builds nothing, records no target, and leaves `host_count_override` byte-identical | captured log |
| `up_refuses_while_a_down_is_in_flight` | ndt | idle | 09-11 ROLE-2 cycle 13, live. `logs/ROLE-2/cycle-13-up-B.log` (`already up: … reusing`, `model matches fabric` on a dying fabric) | `019b125d` (merged `cb5ab923`) | a bring-up overlapping an `ndt down` is refused rc 1 in 0 s, the refusal quotes `.test_run/down.inflight`, and the marker is gone afterwards | captured log; the marker is `(absent)` because the marker IS the fix |
| `half_stack_is_not_clean` | ndt | ovs4 | 09-11 ROLE-2 cycle 07, live. `logs/ROLE-2/cycle-07-probe-afterup.log` (`VERDICT: CLEAN` over 10 bmv2 + 14 mininet and no kernel) | `6d081d13` (merged `954ab467`) | whole stack → `VERDICT: CLEAN` / `verdict=whole-up`; kernel stopped by its own pidfile → `VERDICT: NOT CLEAN`, `the stack is HALF up`, rc 1, `verdict=HALF` in the report | captured log, **thin** (one `VERDICT:` line) -- see its PROVENANCE.md |
| `recovery_refuses_foreign_netem` | kernel | ovs4 | 09-11 ROLE-1, live 3/3. `logs/ROLE-1/07-inject-recovery.log`, `08-tc-after-recovery.log`, premise in `04-tc-netem-on.log` | `0b928fe6` (merged `6c4000eb`; KNOWN-ISSUES B-16) | `POST /ndt/inject_link_recovery` on an undeclared link carrying a foreign netem → **409**, `netem_not_ours`, `Nothing was changed`, and the qdisc still on the wire | captured log |
| `link_failure_cuts_both_ends_or_neither` | kernel | ovs4 | 09-11 ROLE-1, live 2/2. `logs/ROLE-1/06-inject-failure.log` (`netem 801e` really on s5-eth1, status `link failure injected`) | `0b928fe6` (merged `6c4000eb`; B-16) | one end refused → **neither** end carries netem, the status line says `link failure declared; nothing was attached`, the body says which half happened, and the declaration stands | captured log |
| `orphans_blind_probes_not_checked` | ndt | none | 09-11 F-OFFLINE-1 §1.11, run for real offline. `hunt-0911/F-OFFLINE-1-REPORT.md` | `ded00d06` (merged `954ab467`) | a report with the kernel up and all three lock probes `NOT CHECKED (http 500)` → `VERDICT: NOT CHECKED` rc 3, and **not** the token `VERDICT: CLEAN` | replay of `ded00d06^` |
| `help_drops_deleted_claims` | ndt | none | 09-11 F-OFFLINE-1 §1.12 and §1.24, run for real offline | `3259d296` (merged `954ab467`) | `ndt help` no longer carries the `has run in THIS checkout` sentence nor the blanket environment-variable guarantee, and does carry the scoped replacements | replay of `3259d296^` |
| `default_round_plane_is_classified` | ndt | none | 09-11 F-OFFLINE-1 §1.15, run for real offline with its own positive control | `ca9af4f1` (merged `954ab467`) | `last_kernel_plane` reads `Mininet_*` as ovs, `OVS_*` as ovs, `P4_*` as p4, and a physical-mode command as rc 1 / no plane | replay of `ca9af4f1^` |

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

## 🔴 What these cells do NOT cover

Said here rather than left to be discovered, because a grid that is read as "the fixes are
verified" is worse than no grid.

1. **Control assertions have no fixture that reddens them.** Every cell carries assertions for
   the wrong-fix direction -- `f10_p4_is_not_swallowed`, `f10_physical_is_still_unknown`,
   `h2_whole_stack_is_clean`, `a1r_far_end_untouched`, `a1f_declaration_still_stands`. They pass
   on `old/` by design, so deleting one changes no failing set and `mutate_live_cells.sh` cannot
   catch it. Those directions are mutated where the subject lives: `mutate_ndt_honesty.sh`,
   `mutate_ndt_up_down_robust.sh`, `mutate_orphans_verdict.sh` and the B-16 C++ gates.
2. **`up_refuses_while_a_down_is_in_flight` overlaps a teardown of an EMPTY lab**, not of a live
   10-switch stack. So did ROLE-6, and for the same reason it wrote down: the guard is in
   `preflight`, before anything reads the machine, so the code path is the same one -- but "the
   teardown of a live fabric was overlapped" is still not measured by anybody.
3. **`up_target_names_a_readable_model` drives OVS; its `old/` is the P4 arm.** ROLE-6 has no rc
   for the OVS arm at all (its own tool timeout killed the wrapper past 120 s). Two copies of the
   same three lines, one plane each.
4. **The `(c)` half of the gate -- re-running `observe` against the pre-fix tool -- is done for
   the three `requires=none` cells only.** The six others would need a pre-fix `ndt` driving a
   real bring-up (318 s, or a fabric built and hung) or a pre-fix KERNEL rebuilt from
   `0b928fe6^`. The gate lists each one with its reason.
5. **Six cells have no `new/` fixture yet** -- the first fixed run of the live half. The gate
   reports them PENDING and counts them separately. PENDING is not passing.

## Registered and NOT converted

From `WAKEUP.md` §7.3 (the numbering is that section's). These are the candidates this round
declined, each with the reason -- a cell forced into existence here would be a cell nobody can
trust.

| §7.3 | why not |
|---|---|
| 21 `NDT_TOPO=<path outside the repo>` makes `ndt status`'s plane read `names no model this script can classify` | **not fixed.** `ca9af4f1` brought `Mininet_*` into the OVS family; a path whose basename matches neither pattern still classifies as nothing. The entry rule is "red, then fixed", and this one is still open |
| 22 T1, two owners win `ndt claim` in the same second | writing `.test_run/lab.claim` IS the lab's state. The orchestrator holds today's claim and forbids `claim`/`release`; against a copied tree it stops being live and becomes `test_ndt_honesty.sh` §6, which already has it |
| 23 T2d, `measuring=` does not protect the owner's own `ndt down` | needs the real claim's `measuring=` written, and then a REGRESSION would tear down whoever's fabric is up. Not a cell to run unattended |
| 25 T2, the foreign-`down` refusal is unpasteable and silent about `measuring=` | cheap and genuinely live -- but if the guard regresses, the cell IS a teardown of somebody else's lab. Written up for Adam's ruling instead (CELLS-1 SUMMARY §7) |
| 26 T5, `ndt up` writes the wrong note when it is not the owner | needs claim ownership, as 22 |
| 27 T3, same-second double-open | the hypothesis was **falsified** -- `ndt down` did collect both processes. What `daa2d0e7` fixed is a sentence in `ndt status`, and there is no live red to convert |
| 31 I-3, `*.pid` naming a dead pid while `*.exit` records the SIGTERM | R7 was read-only and kept **no raw `ndt status` output**, only prose. The `old/` fixture would have to be reconstructed by hand, and a reconstruction the author writes is not last night's evidence. A `(c)` run of the pre-fix `ndt status` over a staged `pids/` would be a real red; that raw does not exist yet |
| 33 ROLE-6's three re-measurements | **converted**: they are `half_stack_is_not_clean`, `up_refuses_while_a_down_is_in_flight`, `up_refuses_a_model_of_another_network`, plus `up_target_names_a_readable_model` for the regression ROLE-6 found underneath them |
| 34 I-2, `lab.claim.prev` keeps the replaced claim | needs `ndt claim`, as 22 |
| 10 / F1, `ndt up p4` printed the LIVE plane's sampling rate | the property is which ARGUMENT the call site passes, and observing it needs the whole `up_p4` stub seam -- which is what `test_ndt_up_down_robust.sh` §10 is. A live form would need an OVS fabric up while a P4 bring-up runs; the lab has one fabric |
| 10 / F9, two `--check` suites read the main checkout's root-owned log | the subject is two test suites, not the lab. A cell would be a grep over test sources, which is a gate's job |
