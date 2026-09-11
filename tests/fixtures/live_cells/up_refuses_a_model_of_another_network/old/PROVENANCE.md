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
run also ended non-zero (124, a timeout, after building ten switches). `h4_knob_unchanged` also
passes here, for the reason in the table. The four assertions that carry the finding are
`h4_refusal_names_two_networks`, `h4_refusal_names_both_counts`, `h4_nothing_was_built` and
`h4_refusal_is_immediate` (300 s against 0 s); `h4_no_target_was_recorded` is the fifth and is
read off the same log. No fixture gap.
