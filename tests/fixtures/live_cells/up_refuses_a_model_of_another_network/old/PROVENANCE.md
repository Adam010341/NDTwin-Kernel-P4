# old/ -- up_refuses_a_model_of_another_network

[Co-developed with claude code -- Adam]

**Kind: captured log.** ROLE-2 cycle 07, live 2026-09-11 01:15:58-01:20:58 on the main checkout
at `c81dabbb`.

| file | where it came from |
|---|---|
| `up.log` | `hunt-0911/logs/ROLE-2/cycle-07-up.log`, colour codes stripped. `NDT_TOPO=setting/StaticNetworkTopologyP4_10Switches_128Hosts.json ndt up p4 4`, knob 4 |
| `up.rc` | `124` -- the log's own trailer `=== up rc=124 secs=300` |
| `up.secs` | `300` -- same trailer |
| `knob.before`, `knob.after` | `4` -- the log's header records knob=4 at the start; ROLE-2 did not re-read it afterwards, so both files carry the one value it did record |
| `ids.txt` | `ndt` blob at `76b5d434^` |

**🔴 rc has no discriminating power on this fixture and the judge does not read it.** The pre-fix
run also ended non-zero (124, a timeout, after building ten switches). The four assertions that
carry the H4 finding are `h4_refusal_names_two_networks`, `h4_refusal_names_both_counts`,
`h4_nothing_was_built` and `h4_refusal_is_immediate` (300 s against 0 s);
`h4_no_target_was_recorded` is the fifth and is read off the same log.

## 🔴 The two ids added 2026-09-12 (ROLE-9 §2), and which of them is evidence

`h4_knob_could_show_a_rewrite` **carries a finding, and the finding is about this cell.**
ROLE-9 measured this cell reaching opposite conclusions on two checkouts of the same commit:
the command passes 4, and on the machine that ran it the working tree's
`host_count_override` also read 4, so `ndt up p4 4` writing the knob through was a NO-OP and
`h4_knob_unchanged` was green no matter what `ndt` did -- while on any fresh worktree, where
HEAD's 128 is on disk, the same assertion went red for the defect ROLE-9's own cells 4b/4c had
just found (`hunt-0911/logs/ROLE-9/c4b-metrics.log`: knob `340a` -> `3132380a` on a refused
bring-up; `c4c-metrics.log`: `3132380a` -> `340a`). This assertion fails on `old/` because that
run's knob was 4 -- i.e. because that run had no discriminating power -- which is exactly what
it says. **It is mutated by the gate.**

`h4_knob_put_back` is a **fixture gap, not evidence** (README rule 2). The cell now records what
the knob holds after it has put the tree back; ROLE-2's cycle-07 log kept no such reading, so
the assertion fails here with "no knob.restored in this raw". The gate does not mutate it.

`h4_knob_unchanged` **passes on this fixture and always did** -- 4 against 4 -- so no mutation of
it could be scored here. The evidence that it is load-bearing is ROLE-9's cells 4b/4c above; a
cell whose `old/` is one of those runs is proposed in `FIX-NDT-7-SUMMARY.md` §7.
