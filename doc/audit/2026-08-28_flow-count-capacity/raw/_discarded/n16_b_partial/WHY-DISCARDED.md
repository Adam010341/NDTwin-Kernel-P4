# n16_b, first attempt — DISCARDED, do not use

**Discarded 2026-08-29 00:15 by `8/28 mainDev`, on `8/28 auditor`'s instruction. Whole arm, not repaired.**

## What this is

The first attempt at arm 6/10 (n=16, pass B). It started 2026-08-28 20:35:25 and was
**killed at 20:38 partway through the 45 M/flow rung**. The replacement arm is
`raw/n16_b/`, run from scratch.

## Why it stopped

Session `2eda4620-b411-463a-9ae4-d3b86e933050` ran `/compact` at **20:38:19 CST**. The last entry
in that session's transcript is the system line `Shell cwd was reset to
/home/adam/Desktop/NDTwin-Kernel` at 20:38:27. The driver was a background shell owned by that
session, so it died with the shell — mid-arm, mid-rung.

**Not a measurement failure. Not a fabric failure.** The fabric was intact afterwards
(10 `simple_switch_grpc`, kernel pid 2500608 on `a40e04ce`, both namespaces, zero interface drops).

## Why the whole arm is discarded rather than repaired

The ladder had climbed to 45 M/flow and stopped there. **The highest clean rung is the arm's
answer, and this arm never finished asking the question** — the climb walks to the top of the
ladder on purpose, because loss on this fabric is non-monotonic and "first rung over the
threshold" does not point at anything (see `run_flowcount_arm.sh` header). A truncated climb has
no highest clean rung, only a highest-clean-*so-far*.

The second reason is the one that decided the move rather than an overwrite: **a half arm on disk
is almost indistinguishable from a complete one.** `arm.meta` here is 364 B against n16_a's 650 B,
and the only structural difference is a missing `finished=` line. Overwriting in place would have
destroyed the record that this cell was ever attempted twice.

## What it contained (for the record only — not a result)

182 files. Ladder as far as it got:

| rate M/flow | reps | loss scored | clean |
|---|---|---|---|
| 1 | 1 | 0.0000 | yes |
| 2 | 3 | 0.5598 | no |
| 3 | 1 | 2.1465 | no |
| 5 | 1 | 10.5263 | no |
| 8 | 1 | 25.7788 | no |
| 12, 20, 30 | 1 | -1 | NO_MEASUREMENT |
| 45 | — | (files written, never scored — killed here) | — |

🔴 Note the 2 M/flow rung read **0.5598%** here and **0.0700%** in `n16_a`. Both are the same cell.
That spread is the reason AMENDMENT-2 §11.1 exists; it is not evidence about either arm.

## Provenance

- driver stdout: `/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/2eda4620-b411-463a-9ae4-d3b86e933050/tasks/brctq5h6o.output` (ephemeral)
- 9 of this arm's 176 JSON files have no `sum_received`; error is
  `unable to read from stream socket: Resource temporarily unavailable` — the iperf3 control
  channel failing under the congestion being measured. n=16 only; n=1/2/4/8 had zero such
  failures. See the round report.

[Co-developed with claude code -- Adam]
