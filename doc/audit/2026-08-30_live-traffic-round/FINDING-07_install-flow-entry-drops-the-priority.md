# Finding 07 — the API accepts a `priority` the table it routes to has no column for

> **🔴 CORRECTED 2026-08-30 23:00 — the severity drops; the observations do not move.**
> The first version was titled *"programs every rule at priority 0, whatever you asked for"* and
> read it as a **value being discarded**, with "two rules matching the same packet have no
> defined order" as the consequence. That consequence is **wrong**. Mechanism traced by
> `mainDev` (the `.p4`) and the `8/29 auditor` (the proxy's table selection); both anchors
> re-read here.
> **Old reading:** priority is dropped ⇒ rule precedence is unavailable ⇒ forwarding order is
> undefined.
> **New reading:** destination-only matches compile to an **LPM** table, which *has no priority
> column at all* — ordering there is prefix length, which is deterministic. **No packet is
> misforwarded.** What remains is an **API contract defect**: the endpoint accepts `priority`,
> routes the rule to a table that cannot use it, and answers success without saying so.

**Status: CONFIRMED (corrected), 2026-08-30.** Round: live-traffic (full-stack #3), arm 1,
P4 128 hosts, kernel `1208d22` (sha256 `66f437a5…`). **API-contract** finding.

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

## The mechanism: it is not a dropped value, it is a table without that column

Two anchors, re-read rather than taken on relay:

1. **`p4_proxy/p4_src/ndtwin_switch.p4`** has no exact-match table on the forwarding path.
   `table flow_5tuple` keys **six fields, all `ternary`** (`:329-336`) and falls through —
   `default_action = NoAction();   // fall through to ipv4_lpm` (`:345`). `table ipv4_lpm`
   (`:350-352`) keys exactly one field, `hdr.ipv4.dstAddr: lpm`. A P4 **LPM table has no
   priority**; its tiebreak is prefix length.
2. **`p4_proxy/proxy_agent/api_routes.py:204-214`**, the `add_flow_entry` docstring, states it
   outright: *"`priority` is now READ … It had no meaning while every rule went to ipv4_lpm — an
   LPM table's tiebreak is the prefix length and nothing else — but a match naming more than a
   destination now compiles to the ternary flow_5tuple table, where priority is both meaningful
   and mandatory. **It is still ignored for the destination-only path**."*

**All seventeen of my rules were destination-only**, so all seventeen went to `ipv4_lpm`. The
`priority: 0` I read back is not a discarded 915 — it is the field's absence, rendered as a
default.

## Why it still matters, narrowed to what the evidence supports

* **No packet is misforwarded, and rule ordering is not undefined.** Within a destination family
  the order is prefix length: deterministic, and not something the caller needed to express.
  ~~two rules matching the same packet have no defined order~~ — **RETRACTED**. That risk exists
  only if someone sends a *multi-field* match, which compiles to the ternary table, **with equal
  priorities**; nothing in this round did, and the kernel itself writes destination-only rules.
* **the API's `priority` argument is accepted, routed to a table that cannot use it, and answered
  with success.** For up to ~10.7 s
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

## 🔴 The binary on disk has moved on since this was measured

Measured on `1208d22` / sha256 `66f437a5…`. At **22:32 on the same evening** another session
rebuilt `build/bin/ndtwin_kernel` to sha256 `4e7afe2d…`, including `91e7743` **"Serve only the
flow entries that were actually programmed"** (T-11-A) — which touches exactly this path. **The
recipe below may not reproduce on the current build, and if T-11-A does what its subject says it
should not: the phantom is gone by design.** A non-reproduction is the fix working, not a
refutation of what was measured here.

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

* ~~Where the priority is dropped is narrowed but not identified.~~ **ANSWERED** — it is not
  dropped anywhere; `ipv4_lpm` has no such field. The intermediate step still stands as
  evidence: the proxy's own read of the switch reports `priority: 0` at t+20 ms, which is why
  the kernel's display cache was eliminated as a candidate before the source settled it.
* ~~Whether BMv2 could honour a priority at all on this pipeline is unknown.~~ **ANSWERED, and
  it was the branch I flagged as having a different fix.** It is the contract/documentation
  branch: the fix belongs at the API and its docs, not in the forwarding path.
* **Still open: what the endpoint should do instead.** Reject a `priority` it will ignore? Return
  it in the response with a note? Silently accept, as now? That is a design call, not a
  measurement, and it is not made here.
* **OVS is untested.**
