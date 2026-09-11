# old/ -- up_refuses_while_a_down_is_in_flight

[Co-developed with claude code -- Adam]

**Kind: captured log.** ROLE-2 cycle 13, live 2026-09-11 on the main checkout at `c81dabbb`,
driven by `logs/ROLE-2/overlap.sh` (background `ndt down`, then `ndt up p4` one second later).

| file | where it came from |
|---|---|
| `up.log` | `hunt-0911/logs/ROLE-2/cycle-13-up-B.log`, colour codes stripped. The second `ndt up p4` |
| `up.rc` | `1` -- ROLE-2-CYCLES-REPORT, cycle-13 paragraph |
| `up.secs` | `13` -- the overlap delay the harness used; `overlap.sh` measures from the background down, so this is the elapsed figure that log's own trailer reports |
| `down.rc` | `1` -- the background teardown, which reported the SECOND up's kernel and proxy as residue |
| `down.inflight`, `down.inflight.after` | `(absent)`. **Not a gap: the marker is the fix.** `.test_run/down.inflight` did not exist at `019b125d^`, so "absent" is what any reader would have found |
| `ids.txt` | `ndt` blob at `019b125d^` |

**Assertions that carry the finding:** `h3_refusal_names_the_teardown`,
`h3_refusal_quotes_the_marker`, `h3_did_not_reuse_the_fabric`,
`h3_did_not_verify_a_dying_fabric`. `h3_marker_was_in_place` also fails, correctly, and for the
reason above.

`h3_up_rc_is_1`, `h3_refusal_is_immediate` and `h3_marker_was_removed` PASS on this fixture and
are not evidence here -- the pre-fix run also ended rc 1, thirteen seconds in, with no marker to
leave behind. They are in the judge for the live round, where a refusal that takes 300 s or
leaves a marker standing is a different defect.
