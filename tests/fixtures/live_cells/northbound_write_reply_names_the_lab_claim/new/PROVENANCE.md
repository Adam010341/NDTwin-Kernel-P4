# new/ -- northbound_write_reply_names_the_lab_claim

[Co-developed with claude code -- Adam]

**Kind: a live run, this cell's own first.** Not regenerated and not edited.

| | |
|---|---|
| when | 2026-09-12 15:00:09 -> 15:00:35 CST (26 s) |
| where | main checkout `/home/adam/Desktop/NDTwin-Kernel`, trunk `af5efa4f` |
| kernel | sha256[0:16] **`c4c8e50310d7e4a1`**, built 2026-09-12 04:25:15 -- the first build carrying `ea517ed5` |
| `ndt` | blob **`54fd094e2dff10ccbe69a5a3b9028ca8b22c36bc`** |
| driven by | `run_cells.sh --cell northbound_write_reply_names_the_lab_claim`, window 1 of the CELLS-2 live window; the claim was the orchestrator's and this cell only read it |
| runner log | `scratch/overnight-2026-09-05/logs/gates-0910/run_cells_labclaim.cells2-0912-r1.log` (`CELLS: 1/1 pass`) |

Every file is a byte copy out of
`.test_run/live_cells/2026-09-12/northbound_write_reply_names_the_lab_claim/`, `read.body`
included -- 24 KB of graph JSON, kept whole because the assertion on it is that a key is ABSENT
and a truncated body could lose one.

The reply this fixture exists for, verbatim from `failure.body`:

```
{"down_reason":"declared","lab_claim":{"expires_at":1789204584,"note":"in use: ndt up ovs 4 at 2026-09-12 15:00:10 by overnight-0905","owner":"overnight-0905","state":"active"},"status":"link failure injected","tc":[...]}
```

(`...` is this file's elision of the eight-element `tc` array; everything before it is
byte-for-byte `failure.body`. The `note` is not the one the CELLS-2 window file carries -- `ndt up`
rewrites it: `claim note now says the lab is in use (owner and expiry unchanged)`, up.log l.5.)

`lab.claim` in this directory is the file it was read from, so the judge compares one against
the other rather than against a constant.

**What it does not cover.** `lc_a_post_outside_the_twelve_is_unmarked` reads a 404, not a POST
that does something -- a POST outside the twelve that really changes state (`acquire_lock`,
`set_switches_power_state`) would be a stronger negative, and staging one costs the lab a lock
acquire or a power write. The C++ side of that direction is mutated where the subject lives:
`tests/shell/mutate_lab_claim_on_writes.sh` M8 marks every POST and must be caught.
