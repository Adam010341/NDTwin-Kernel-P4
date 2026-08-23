# 5-tuple live proof: the override works, the counters do not

[Co-developed with claude code -- Adam]

Run 2026-08-24 at `f636f20`, P4 plane, 4 hosts, on the fast bmv2 (identity read from
`/proc`, not from config). Raw: `five_tuple_live.txt`, `raw/`. Driver: `five_tuple_live.sh`.

Steps 1–4 of P2-5 are unit-tested with mutation gates, but none of that proves the compiled
pipeline behaves as the code assumes — that `flow_5tuple` is applied before `ipv4_lpm` and falls
through on `NoAction` is a claim about a program running on a real switch.

## Proven

**1. A 5-tuple rule installs and reads back with all its fields.** Baseline is four
destination-only LPM entries; after one POST there are five, and the new one is

```
prio=101  match={nw_dst: 10.0.0.2, nw_proto: 6, tp_dst: 5001, dl_type: 2048} -> OUTPUT:2
```

**2. The priority survives, which is the original bug.** The defect that started this work was
recorded as: a 5-tuple rule *"was installed as 10.0.0.4/32 -> port 1, the proxy answered 200 …
and the table read back priority 0 rather than 100"*. It now reads back **101** — OpenFlow 100
through the documented `+1` shift. The rule is no longer narrowed to a destination, and its rank
is no longer discarded.

**3. It overrides without widening.** The LPM entry for the same destination is still present
and still points at its original port:

```
prio=101  nw_dst 10.0.0.2, tcp/5001  -> OUTPUT:2     <- the new rule
prio=0    nw_dst 10.0.0.2            -> OUTPUT:1     <- untouched
```

That pair is the whole point. A rule that had replaced or widened the LPM entry would look like
success and be the exact defect this feature exists to end.

**4. Delete removes the right entry.** After the delete the table is back to its four baseline
rules. Since priority is part of a ternary entry's identity, this also shows the delete path
addressed the entry it meant to.

## Not proven: traffic actually matching it

**Every counter read 0, before and after the probe** — including the LPM entries, which
certainly carried the boot's own connectivity traffic. So this run says nothing about whether
packets followed the new rule.

The honest reading is that **the counter readback added in step 4 does not work against a live
switch**, and its unit tests could not have caught that: they feed the renderer a `counters`
dict and assert it comes out the other side, which verifies the plumbing below the switch and
nothing above it. The switch is simply not supplying `counter_data`.

The likely cause is a P4Runtime detail rather than a pipeline one: reading `TableEntry` does not
necessarily populate direct-counter data unless the request asks for it, and
`read_table_entries` issues a bare `table_entry.table_id = 0` read. The fix is probably to
request counter data explicitly, or to read `DirectCounterEntry` separately. **Not attempted
here, and not asserted as the cause** — it is a hypothesis with an obvious experiment attached,
which is a different thing from a diagnosis.

Consequence for step 4's claim: "counters now travel through" is true of the proxy's internals
and false end to end. `/stats/flow/<dpid>` still reports zeroes on the P4 plane.

## An analysis line that manufactured its own contradiction

The first version of the section-4 check selected 5-tuple rules with `len(match) > 1`, which
also matches every LPM entry (`nw_dst` + `dl_type` = 2 fields). It printed

```
priority read back: 0  (installed with OpenFlow 100)
```

against four rules nobody had installed with priority 100 — a line that reads like the original
bug reproducing, produced entirely by the filter. Corrected to select on the presence of an
actual 5-tuple key. Worth recording because the wrong output looked exactly like the failure
being investigated.

## Status of P2-5

The work order's wording ceiling was *"P4 side works, end-to-end pending TE"*. That is now
supportable for **forwarding**: a 5-tuple rule installs, outranks LPM, keeps its priority, and
deletes cleanly, on a live switch.

It is **not** supportable for **telemetry**: per-entry counters read zero, so the endpoint that
was supposed to distinguish a rule carrying gigabytes from one that never matched still cannot.

TE repo untouched throughout, as instructed.
