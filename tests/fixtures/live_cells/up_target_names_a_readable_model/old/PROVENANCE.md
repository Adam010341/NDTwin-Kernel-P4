# old/ -- up_target_names_a_readable_model

[Co-developed with claude code -- Adam]

**Kind: captured log.** ROLE-6's live run on the main checkout at trunk `954ab467`, which carried
H4's fix and therefore the newline regression.

| file | where it came from |
|---|---|
| `up.log` | `hunt-0911/logs/ROLE-6/51a-up-p4-A.log`, colour codes stripped (`sed 's/\x1b\[[0-9;]*m//g'`). `NDT_OWNER=overnight-0905 ndt up p4 4`, started 02:55:10 |
| `up.rc` | `1` -- ROLE-6-SUCCESSOR2-REPORT §① |
| `up.secs` | `318` -- same source |
| `ids.txt` | kernel sha16 `356803db69af3b1b` (the binary ROLE-6 identified, `logs/ROLE-6/01-binaries.log`); `ndt` blob at `5e7a91c8^` |

**The P4 arm, not the OVS arm, and the cell drives OVS.** The raw layout is plane-agnostic
(`up.log`, `up.rc`, `up.target`), and ROLE-6 has no rc for the OVS arm at all: its `ndt up ovs 4`
was still running past 120 s when the role's own tool timeout killed the wrapper
(`logs/ROLE-6/20-up-ovs4.log`). The defect was two copies of the same three lines, `ndt:1948`
(p4) and `ndt:2287` (ovs), and ROLE-6 proved both offline; the P4 arm is the one with a number.

**Assertions that carry the finding on this fixture** (the gate mutates only these):
`h4nl_up_rc_is_0`, `h4nl_model_counts_were_readable`, `h4nl_no_incomplete_rollback`,
`h4nl_kernel_did_not_die_starting`.

**Fixture gap, recorded rather than papered over:** ROLE-6 did not keep that round's
`.test_run/up.target`, so `h4nl_target_record_written`, `h4nl_topology_sha_is_a_reading`,
`h4nl_model_hosts_were_counted` and `h4nl_topology_path_is_one_line` fail here with
`no such raw file`. The report states what that file contained
(`topology_sha256=unavailable`, an empty `model_hosts=`), and the offline half of the same
finding -- section 11 of `tests/shell/test_ndt_up_down_robust.sh` -- asserts exactly those four
readings against a fixture `up.target` it writes itself. They are kept in the judge because the
live round is where they are worth reading; they are not evidence on THIS fixture.
