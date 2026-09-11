# old/ -- recovery_refuses_foreign_netem

[Co-developed with claude code -- Adam]

**Kind: captured log.** ROLE-1, live on an OVS 4-host fabric, 2026-09-11 00:55-00:58, main
checkout; 3 reproductions of 3.

| file | where it came from |
|---|---|
| `recovery.body` | the verbatim response line under `=== RESPONSE (verbatim) ===` in `hunt-0911/logs/ROLE-1/07-inject-recovery.log` (00:57:40). The pretty-printed copy below it in that log is the same bytes and is not duplicated here |
| `recovery.code` | `200` -- that log's `http_code=200` |
| `tc_before.txt` | the `sudo -n tc qdisc show dev s1-eth1` reading from `04-tc-netem-on.log`, where ROLE-1 asserted its hand-attached `netem loss 100%` had landed |
| `tc_after.txt`, `tc_after_far.txt` | the s1-eth1 and s5-eth1 sections of `08-tc-after-recovery.log` -- both `qdisc noqueue`, i.e. the previous operator's blackhole GONE |
| `netem_final.txt` | `0`, from the whole-machine sweep in `08-tc-after-recovery.log` (`no netem anywhere`). ROLE-1's round ended with nothing attached, so this cleanliness assertion passes on the fixture and is not evidence here |
| `ids.txt` | kernel `unknown`: ROLE-1 identified its binary in `00b-binary-identification.log` but this fixture does not depend on it, and inventing a sha for it would be provenance this file cannot support |

**Six of the nine assertions carry the finding**, all content readings of files this fixture has:
`a1r_http_is_409`, `a1r_body_names_foreign_netem`, `a1r_body_says_nothing_changed`,
`a1r_no_qdisc_was_deleted`, `a1r_did_not_claim_a_recovery`, `a1r_foreign_netem_survived`.
The last of those is the one on the WIRE, and is the assertion a 200 reply could never have
satisfied. No fixture gap.
