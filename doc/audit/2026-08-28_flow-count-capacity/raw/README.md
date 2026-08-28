# P1-3 raw — how to read it, and one thing you must not do with it

Design: `../PREREG.md` (including AMENDMENT-1 §10 and AMENDMENT-2 §11).
Instrument: `../run_flowcount_arm.sh`. Driver: `../drive_p1_3.sh`. Analysis: `../analyse_p1_3.py`.

## Layout

- `n<N>_<a|b>/` — one arm. `a` = pass A, `b` = pass B. **The arm is the replication unit**
  (PREREG §7); a cell with one arm has been re-read, not replicated.
- `smoke_*/` — instrument validation before the real arms. **Not data.**
- `_discarded/` — arms that were run and then voided, with a note saying why. Never overwritten in
  place, because overwriting would erase the fact that a cell was attempted twice.

`arm.meta` without a `finished=` line means the arm did not complete. A half arm and a whole arm
are otherwise nearly identical on disk (364 B vs 650 B) — check for that line before using a
directory.

## 🔴 The `NO_MEASUREMENT` rungs are NOT missing at random

A rung reads `-1` / `NO_MEASUREMENT` when any of its n flows produced no `sum_received`. The cause,
where it was checked: the iperf3 **control channel** timing out — `unable to read from stream
socket: Resource temporarily unavailable`, with `"connected": []` in the JSON.

**That control channel crosses the same congested path as the traffic being measured.** So:

| arm | JSON files with no `sum_received` |
|---|---|
| n1_a, n2_a, n4_a, n8_a | **0** of 22 / 48 / 92 / 128 |
| **n16_a** | **27 of 256** |
| `_discarded/n16_b_partial` | 9 of 176 |

and within `n16_a` the affected rungs are `8, 20, 30, 45, 70, 110, 160, 240` — **the high end**.

> 🔴 **These losses concentrate where loss is highest, because the instrument's control channel
> competes for the same resource as the thing being measured. Anyone doing secondary analysis must
> NOT treat `NO_MEASUREMENT` as missing-at-random and drop it — dropping those rows makes the high
> rungs look systematically cleaner than they were.**

This does not affect what this round reports: every cell's highest clean rung sits far below where
the failures begin, and every rung at or below it was measured. It bounds what *else* the raw can
be used for.

(Recorded here rather than in `arm.meta` so that `run_flowcount_arm.sh` stays byte-identical
between pass A and pass B. The only instrument change between passes is in `drive_p1_3.sh`:
`PASS_A`/`PASS_B` became environment-overridable so pass B could be resumed alone. **Measurement
semantics — ladder, thresholds, rep rule, settle time, host pair — are unchanged.**)

## Two readouts, and the only informative way to pair the interface counters

`netdev_before/after.txt` are **whole-arm** snapshots; they cannot isolate a rung. Per-rung numbers
come from iperf3 (`ladder.tsv`), a different instrument. The two were reconciled: across all five
pass-A arms, `iperf3 sum_sent.bytes + 42 B/packet` over `netdev s1-eth3 RX bytes` = **1.0000–1.0001**.

🔴 **Every netdev `drop` column reads 0 throughout, including in an arm that lost 79.7% of its
packets.** Loss happens inside bmv2's own buffers, which the kernel does not count. The only
informative pairing is **ingress-RX against egress-TX on the same switch** (`s1-eth3` RX vs
`s1-eth1` TX). Comparing an interface's RX against its own drop column measures nothing here.

[Co-developed with claude code -- Adam]
