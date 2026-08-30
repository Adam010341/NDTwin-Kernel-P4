# Finding 07 — `install_flow_entry` programs every rule at **priority 0**, whatever you asked for

**Status: CONFIRMED, 2026-08-30 21:05–21:14 CST.** Round: live-traffic (full-stack #3), arm 1,
P4 128 hosts, kernel `1208d22` (sha256 `66f437a5…`). **System** finding.

[Co-developed with claude code -- Adam]

---

## What was asked for and what was installed

Seventeen rules were POSTed to `/ndt/install_flow_entry` across the round, at priorities
902 and 910–927. Every one whose action named a port that exists **was programmed**, correctly,
with the right match and the right output port — and with

```
"priority": 0
```

Not one of the requested priorities survived. Read straight off the live table view
(`GET /ndt/get_switch_openflow_table_entries`), once the view cache had refreshed from the
switch — and independently off the **proxy's own read of the switch** at t+20 ms, which agrees:

```json
{"actions": ["OUTPUT:2"], "byte_count": 0, "cookie": 0, "duration_nsec": 0,
 "duration_sec": 0, "flags": 0, "hard_timeout": 0, "idle_timeout": 0, "length": 0,
 "match": {"dl_type": 2048, "nw_dst": "10.0.0.220"}, "packet_count": 0,
 "priority": 0, "table_id": 0}
```

The whole table is priority 0: a histogram over all 1285 entries on all ten switches returns
`{0: 1285}`. The 128 base routes per switch are priority 0, and so is every rule installed on
top of them.

Rules whose action named **port 999** (a port that does not exist) were correctly *not*
programmed — destinations `.202`–`.205` never appear. So the write path does discriminate; it is
specifically the priority field that does not arrive.

## Why this matters more than it looks

Priority is the entire mechanism by which a specific rule overrides a general one. With every
entry at 0:

* **two rules matching the same packet have no defined order.** Which one wins is whatever the
  table's internal ordering happens to be — not something the caller can express.
* **the API's `priority` argument is accepted, echoed back, and discarded.** For up to ~10.7 s
  the kernel's cached table view *reports the requested priority*, because `HttpSession` writes
  the raw request into that cache synchronously (that is the phantom — see
  [FINDING-06](FINDING-06_dispatch-is-a-10.7s-cycle-not-a-queue.md)); once the cache is refreshed
  from the switch it reports 0. A caller that reads back inside the window sees its own value
  confirmed; a caller that reads back later sees 0. **Both are the same rule, and the switch had
  0 the whole time.**
* it is invisible to any check that trusts the value it just sent.

The 08-18 F-5b probe used priority 902 for its control and 901 for its subject precisely so the
two could be told apart. At the switch they are the same number.

## 🔴 This finding began as its own opposite — the instrument produced the exciting version

For about twenty minutes the working conclusion was **"an installed rule never becomes a
programmed entry"** — a far bigger and far more alarming claim, and false.

`tr3_f5_window.py` counted programmed entries with `priority == <the priority I posted>`. Since
the system rewrites that field, the count was structurally pinned at zero, in every run, on both
fabric states. Every observation agreed with the wrong conclusion, and the agreement was
manufactured by the instrument keying on the one field that does not survive the trip.

What caught it was not a test. It was **asking the other side**: the entry count had drifted
1280 → 1285 while "no rule was ever programmed", so the extra five were worth identifying. They
were the five installed rules, at priority 0, at exactly the destinations posted.

🔑 `memory: grep-endpoints-misses-concatenation` — before reporting an absence, ask the other
side. And the reason this one nearly landed: **"never programmed" is a much better sentence than
"programmed at a different priority"**, which is precisely the direction this project's errors
have been observed to fall in (`memory: the-clean-version-is-the-one-to-recheck`). An instrument
with no discriminating power for the success case reported a confident FAIL, and a confident FAIL
is not a finding.

The fix is to key rule identity on the **destination**, which the caller chooses and which does
survive. `scan()` now does that, with the reasoning recorded at the definition.

## Reproduce

```bash
curl -s -X POST http://localhost:8000/ndt/install_flow_entry \
  -H 'Content-Type: application/json' \
  -d '{"dpid":1,"priority":915,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.240"},"actions":[{"type":"OUTPUT","port":2}]}'
sleep 12   # long enough for the view cache to refresh -- see FINDING-06
curl -s http://localhost:8000/ndt/get_switch_openflow_table_entries \
 | python3 -c 'import sys,json
d=json.load(sys.stdin)
for el in d:
  for t,l in (el.get("flows") or {}).items():
    for e in l:
      m=e.get("match") or {}
      if (m.get("nw_dst") or m.get("ipv4_dst"))=="10.0.0.240":
        print(el["dpid"], t, json.dumps(e))'
```

Expected: the entry is present, `actions` is `["OUTPUT:2"]`, and `priority` is `0`, not `915`.

## Not established

* **Where the priority is dropped is narrowed but not identified.** 🆕 2026-08-30 22:10: the
  **P4 proxy's own read of the switch** (`/stats/flow/<dpid>`) reports `priority: 0` too, in all
  three reps of the programmed-vs-visible check — measured ~20 ms after the POST, long before the
  kernel's cached view publishes anything. **So the kernel's display cache is eliminated**: the
  priority is already gone one layer closer to the switch than the view I originally read it in.
  Remaining candidates: the kernel's southbound encoder, the proxy's `/stats/flowentry/add`, or
  the BMv2 table write. A source read, not another live run.
* **Whether BMv2 could honour a priority at all** on this pipeline is unknown; a P4 table's match
  kind may make priority meaningless for these entries, in which case the defect is that the API
  accepts and echoes a field it cannot implement — a documentation and contract problem rather
  than a forwarding one. **These two have very different fixes and the evidence here does not
  choose between them.**
* **OVS is untested.**
