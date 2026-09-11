# old/ -- half_stack_is_not_clean

[Co-developed with claude code -- Adam]

**Kind: captured log, and a thin one.** ROLE-2 cycle 07, 2026-09-11 01:21:14, read by
`logs/ROLE-2/probe.sh`.

| file | where it came from |
|---|---|
| `half.verdict.txt` | the `VERDICT:` line of `hunt-0911/logs/ROLE-2/cycle-07-probe-afterup.log`, verbatim. The machine at that moment: `bridges=0 ... bmv2=10 mininet=14`, a live `p4_proxy` on :8081, and **no kernel** |
| `half.orphans.rc` | `5` -- the same log's `orphans_rc=5` |
| `ids.txt` | `ndt` blob at `6d081d13^` |

**🔴 The old evidence is thinner than the cell.** `probe.sh` piped the report into
`orphans_verdict.sh`, grepped one line out of the result, and kept neither the report
(`$SCRATCH/orphans.log`, overwritten every cycle) nor the helper's rc. So on this fixture:

* **carrying the finding:** `h2_half_stack_is_not_clean`, `h2_half_stack_says_not_clean`,
  `h2_half_stack_names_the_half` -- three content readings of the one file that exists, and the
  `VERDICT: CLEAN` token is precisely what every restore gate in this repo greps for. The gate
  mutates only these three.
* **fixture gap:** `h2_whole_verdict_present`, `h2_whole_stack_is_clean`,
  `h2_whole_stack_reads_whole_up`, `h2_half_verdict_rc_is_1`, `h2_report_names_the_half` fail
  for want of a file. The whole-up control in particular has no pre-fix counterpart here; ROLE-2
  recorded it separately (cycle 07 `AFTERUP` row of `cycles.tsv`, `CLEAN`) and ROLE-6 re-measured
  it after the fix (`logs/ROLE-6/31-h2-control.log`).

ROLE-6 also recorded why `cycle-13-orphan-halfstack.log` -- the other, mirror-image half stack --
is NOT usable here: it is that role's own probe output, not an `ndt apps orphans` report, so
feeding it to the helper yields `stack=not-reported` and proves nothing about either version.
