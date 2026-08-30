# Finding 03 — F-5's phantom **does** occur on P4, and it is the request echoed back

**Status: CONFIRMED, 2026-08-30 15:25.** Round: T-4, R-5 / F-5. This is a **system** finding,
not a harness one. It revises an 08-18 result without contradicting its data.

---

## What 08-18 recorded, and why it was right about its own data

`live-findings-2026-08-18-p4.md`, quoted by `40_r5_p4.sh:207`:

> on P4: "kernel=4 proxy=4 at t=2,4,8,16,30s — no phantom, ever."

**Its first sample is at t=2 s.** This round sampled `t ∈ {0, 2, 4, 7, 9, 12, 16, 20, 30, 45,
60, 84}` and found the phantom **only at t=0**:

```
elapsed_s   entries matching priority 901
0           1        <- present
2           0
4           0
…           0   (through t=84)
```

⇒ 08-18 did not observe an absence. **It sampled a grid whose first rung is past the event.**
🔑 Same family as `memory: instrument-must-not-mimic-its-own-finding` — *the ladder was shorter
than the thing it measured*, except here the ladder's first rung was simply too late. "No
phantom, ever" should have been "no phantom at t ≥ 2 s", and the difference is the whole finding.

## The phantom is real, not a substring artefact

The harness detects with `grep -c '901'` on the response body — a **substring** count, and on a
body with no newlines `grep -c` can never exceed 1 regardless of how many rules match (the H-16
shape, met once already this round). So the count was re-derived structurally before being
believed:

| t | `raw.count("901")` | entries with `priority == 901` (parsed) |
|---|---|---|
| 0 | 1 | **1** |
| 2 | 0 | 0 |
| 4 | 0 | 0 |
| 9 | 0 | 0 |

The structured count agrees. **The substring critique was worth raising and came out the other
way** — `grep -c` is still the wrong instrument here, it simply did not produce a false positive
this time.

## The fingerprint: it is the POST body, re-served

`40_r5_p4.sh:223` registered the discriminating test in advance — *"if the actions field is an
OBJECT among strings … the kernel is echoing the request rather than reporting the table."*
Applied to the t=0 body, which holds **42** entries carrying a `priority` field:

**The phantom**
```json
{"actions": [{"port": 999, "type": "OUTPUT"}],
 "match": {"eth_type": 2048, "ipv4_dst": "10.0.0.98"},
 "priority": 901, "table_id": 0}
```

**A sibling — all 41 others have this shape**
```json
{"actions": ["OUTPUT:3"], "byte_count": 196, "cookie": 0, "duration_nsec": 0,
 "duration_sec": 0, "flags": 0, "hard_timeout": 0, "idle_timeout": 0, "length": 0,
 "match": {"dl_type": 2048, "nw_dst": "10.0.0.1"}, "packet_count": 2,
 "priority": 0, "table_id": 0}
```

Three independent discriminators, all pointing the same way:

| | phantom | the other 41 |
|---|---|---|
| fields | 4 | 13 |
| statistics (`byte_count`, `packet_count`, `duration_*`, `cookie`, timeouts) | **all absent** | all present |
| `actions` elements | **objects** `{"port":999,"type":"OUTPUT"}` | strings `"OUTPUT:3"` |
| `match` vocabulary | **`eth_type` / `ipv4_dst`** — the POST's spelling | `dl_type` / `nw_dst` — OpenFlow's spelling |

The match-vocabulary row is the strongest. A row read back from a switch table would be
rendered in the switch's vocabulary; this one is in **the vocabulary of the request I sent**.

⚠️ Stated precisely: it is **not byte-identical** to the POST body — `dpid` is dropped and key
order differs — so the registered fingerprint's strict form does not hold. The claim is
structural identity with the request, not byte identity, and the verdict rests on the three
rows above rather than on the byte test.

## What this changes

* **F-5 on P4: `still present`**, where 08-18 said the window did not exist here. The 08-18
  reasoning (*"the P4 proxy writes synchronously and reports inside its 200, so the window F-5
  describes does not exist"*) explains why the phantom is **short**, not why it is absent — and
  it is not absent.
* **The mechanism is now named**: the kernel's table view serves a queued-but-unprogrammed
  request as though it were a table row, stripped of every statistic a real row carries. That
  is the same `replace-vs-add` / "accepted ⇒ shown as installed" family as
  `memory: rejected-requests-can-still-act`, and it is visible for well under 2 s.
* **F-5b is unaffected.** It is a differential and still needs the OVS arm.

The kernel's 200 for the invalid rule is honest about itself, and worth quoting because it is
the part that works:

> `{"accepted":1,"detail":"entries accepted for programming; per-entry outcomes are reported in
> the kernel log, not in this response","status":"queued"}`

and the log did carry `dispatched <op> failed`, first seen at +2 s. **The API says "queued" and
means it; the table view is what over-claims.**

## What was not established

* Whether the phantom is visible for 0.1 s or 1.9 s — the grid's second rung is t=2. Bounding it
  needs a finer grid near zero, and that is a separate run, not a re-reading of this one.
* Whether the same echo happens for a **valid** rule (the control installed at priority 902 was
  checked for presence, not for shape). If it does, the echo is unconditional rather than a
  rejection-path artefact — a materially different finding, and untested.

[Co-developed with claude code -- Adam]
