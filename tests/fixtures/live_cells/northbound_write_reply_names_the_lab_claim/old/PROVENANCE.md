# old/ -- northbound_write_reply_names_the_lab_claim

[Co-developed with claude code -- Adam]

**Kind: last night's evidence, copied out of another role's logs.** ROLE-11 posted the two writes
this cell posts, against a kernel built before the fix, and kept the reply bodies verbatim. It is
not a replay: the pre-fix kernel is C++ and rebuilding it was out of this ticket's scope (no
build), so the bodies ROLE-11 recorded are the only pre-fix evidence there is.

| | |
|---|---|
| when | 2026-09-12 02:22:01 and 02:22:42 CST |
| where | main checkout, trunk **`d7aa176e`**, OVS 4-host fabric ROLE-11 brought up at 02:20:23 |
| kernel | sha256[0:16] **`73c831b30bb49843`**, named by ROLE-11 in the log's own second line |
| the fix | `ea517ed5` (merged as `f313b1a4`, 2026-09-12 04:23) -- **not** an ancestor of `d7aa176e`, so this really is the pre-fix reply |

| file here | copied from | which bytes |
|---|---|---|
| `failure.body` | `hunt-0911/logs/ROLE-11/08-inject-failure.log` | line 4, the whole JSON reply |
| `failure.code` | same log | its `HTTP=200` line, value only |
| `recovery.body` | `hunt-0911/logs/ROLE-11/11-inject-recovery.log` | line 3, the whole JSON reply |
| `recovery.code` | same log | its `HTTP=200` line, value only |
| `up.rc` | `hunt-0911/logs/ROLE-11/04-ndt-up-4.log` | its `RC=0` line, value only |
| `ids.txt` | written here | `kernel=` is the sha ROLE-11 printed in `08-inject-failure.log`; `ndt=unknown` because ROLE-11 recorded no blob sha for `ndt`, and filling it in from this tree would be inventing provenance for somebody else's evidence |

## 🔴 Which of the twelve failing assertions are evidence, and which are a fixture gap

**Evidence -- these two are the finding, and they are the only two `mutate_live_cells.sh` mutates:**

| id | what it read here |
|---|---|
| `lc_write_reply_carries_the_claim` | the 200 from `/ndt/inject_link_failure` has no `lab_claim` key at all. Verbatim, it opens `{"down_reason":"declared","status":"link failure injected","tc":[...` -- after the fix `"lab_claim":{...}` sorts in between `down_reason` and `status` |
| `lc_recovery_reply_carries_it` | the same of `/ndt/inject_link_recovery`: `{"status":"link recovery injected","tc":[...` |

**Fixture gap -- ROLE-11 was not running this cell and kept no such file. They fail honestly
(`no such raw file`, or a needle built from a claim file that is not here) and they are NOT
evidence of anything:**

`lc_claim_file_copied`, `lc_premise_a_claim_was_held`, `lc_claim_owner_is_the_holder`,
`lc_claim_expiry_is_the_file_s`, `lc_claim_state_is_active` -- ROLE-11 did not copy
`.test_run/lab.claim`, and a claim file written by hand here would be a fixture that makes a
judge go red on demand.
`lc_badreq_is_a_refusal`, `lc_refusal_carries_it_too`, `lc_a_post_outside_the_twelve_is_unmarked`,
`lc_a_read_is_unmarked` -- ROLE-11 made none of those three requests.
`lc_control_cell_left_no_netem` -- ROLE-11's recovery log records `--- tc qdisc show | grep -c
netem ---` then `0`, which is the same reading, but writing that number into this cell's own
sentence would be a reconstruction rather than a copy.

**Passing here on purpose:** `lc_write_reply_present` and `lc_control_write_was_accepted` (200).
The pre-fix endpoint worked; what it did not do is say whose lab it had just written to.
