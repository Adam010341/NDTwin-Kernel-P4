# 5-tuple live proof: the override works, and the counters do too (after a fix this run found)

[Co-developed with claude code -- Adam]

Two runs, 2026-08-24, P4 plane, 4 hosts, on the fast bmv2 (identity read from `/proc`, not from
config). Raw: `five_tuple_live.txt`, `raw/`. Driver: `five_tuple_live.sh`.

Steps 1–4 of P2-5 are unit-tested with mutation gates, but none of that proves the compiled
pipeline behaves as the code assumes — that `flow_5tuple` is applied before `ipv4_lpm` and falls
through on `NoAction` is a claim about a program running on a real switch.

## What the live run shows

**1. A 5-tuple rule installs and reads back with every field.** Baseline is four
destination-only LPM entries; after one POST there are five, and exactly one is keyed on more
than a destination:

```
prio=101  match={nw_dst: 10.0.0.2, nw_proto: 6, tp_dst: 5001, dl_type: 2048} -> OUTPUT:2
```

**2. The priority survives — this is the original defect closing.** The bug that started this
work was recorded as: a 5-tuple rule *"was installed as 10.0.0.4/32 -> port 1, the proxy
answered 200 … and the table read back priority 0 rather than 100"*. It now reads back **101**,
OpenFlow 100 through the documented `+1` shift.

**3. It overrides without widening, and the counters prove which traffic went where.** Three TCP
probes to port 5001 were sent, with h1's own `tx_packets` counted independently so a zero could
not be mistaken for a probe that never fired:

```
h1 tx_packets: 11 -> 14   (delta 3)

prio=101  nw_dst 10.0.0.2, tcp/5001  -> OUTPUT:2   pkts=3  bytes=222   <- the new rule
prio=0    nw_dst 10.0.0.2            -> OUTPUT:1   pkts=2  bytes=196   <- untouched, still used
```

The 3 matched packets are exactly h1's send delta, and the LPM entry for the *same destination*
kept its own port and carried its own separate traffic. A rule that had replaced or widened the
LPM entry would look like success and be the exact defect this feature exists to end; this is
the measurement that tells the two apart.

**4. Delete removes the right entry.** Afterwards the table is back to its four baseline rules,
with their counters intact. Since priority is part of a ternary entry's identity, this also
shows the delete addressed the entry it meant to.

## The counter bug this run found, and the fix

The **first** run reported `pkts=0 bytes=0` on every entry, including LPM rules that had
certainly carried the fabric's own boot traffic. Step 4 had added counter plumbing and its unit
tests passed — because they hand the renderer a `counters` dict and assert it survives, which
exercises everything *below* the switch and nothing *above* it. The switch was never sending
counter data at all.

Cause, confirmed by intervention rather than argument: `read_table_entries` issued a bare
`table_entry.table_id = 0` read. P4Runtime treats a present (even empty) `counter_data` in the
**request** as "send me the counters"; without it the server returns entries with the field
unset. Adding `requested.counter_data.SetInParent()` turned every zero into a real number in the
next run, on the same fabric and the same probe.

This is worth keeping as a shape: **a test that supplies the data it is checking the transport
of cannot detect that the source never supplies it.** The unit tests were not wrong, they were
scoped one layer too low, and only a live read distinguished the two.

## Status of P2-5

The work order's wording ceiling was *"P4 side works, end-to-end pending TE"*. That is now
supportable for **both** halves:

* **forwarding** — a 5-tuple rule installs, outranks LPM, keeps its priority, steers only the
  flow it names, and deletes cleanly, on a live switch.
* **telemetry** — per-entry byte and packet counts reach `/stats/flow/<dpid>`, which is what the
  pipeline's `direct_counter` declarations were added for.

TE repo untouched throughout, so end-to-end remains pending TE exactly as instructed.

## Also recorded

An analysis line in this script's first version selected 5-tuple rules with `len(match) > 1`,
which matches every LPM entry too (`nw_dst` + `dl_type` = 2 fields), and printed
`priority read back: 0 (installed with OpenFlow 100)` against four rules nobody installed with
100 — output that read exactly like the original bug reproducing, manufactured entirely by the
filter. Corrected to select on the presence of an actual 5-tuple key; the run above reports
`rules with more than one match field: 1`, which is the truth.
