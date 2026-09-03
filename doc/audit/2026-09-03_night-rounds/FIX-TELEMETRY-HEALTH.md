# Fix: make sample loss visible to the people who read the API

[Co-developed with claude code -- Adam]

Branch `fix/telemetry-health-visible`, off `trunk` at `128bfc6b`. **Behaviour-changing (response
shape), so branch only, never trunk.** Not pushed.

Defects addressed, all measured in
`doc/audit/2026-09-03_night-rounds/round4-traffic-measurement/SUMMARY.md` (lead 5(b), section 1, R4)
and **cited here, not re-derived**:

1. The four drop counters at `FlowLinkUsageCollector.hpp` were reachable from **none** of the 105
   JSON keys the kernel serves. At 654 709 datagrams/s the socket dropped **72.5%**; the only
   reader was a log line.
2. Under that load the twin reported a 20 Mbit/s flow (0% wire loss) as **7.14 Mbit/s -- 2.76x
   under** -- while every endpoint answered 200 `success`, all three flow windows said `active`,
   and `avg_link_usage` moved the **wrong way**.
3. `rx` had no steady-state channel: the INFO fires once per process, the rest is TRACE, so
   "no WARN" and "we have received nothing" were the same observation from outside.

---

## What is exposed, and where

One object, `telemetry_health`, built in one place
(`FlowLinkUsageCollector::ingestHealthJson()`), so every carrier has identical keys:

| key | meaning |
|---|---|
| `status` | `unknown` \| `no_samples` \| `ok` \| `lossy` \| `severe_loss` |
| `samples_in_window` | samples the rates beside it were actually computed from |
| `offered_in_window` | **the denominator**: samples + socket drops + app drops |
| `dropped_in_window`, `socket_drops_in_window`, `app_drops_in_window` | the numerator, split |
| `loss_fraction` | dropped/offered; `-1.0` only when no window has closed |
| `window_seconds` | the window those counts cover |
| `rx_total`, `addressed_total`, `sock_ovfl_total`, `app_drop_total` | the four counters, for a consumer keeping its own baseline |

Carried by:

- **every row of `GET /ndt/get_detected_flow_data`** (`FlowLinkUsageCollector.cpp`,
  `getFlowInfoJson`) -- the endpoint that under-reported by 2.76x;
- **`GET /ndt/get_average_link_usage`** (`HttpSession.cpp`, `handleGetAvgLinkUsage`) -- the number
  that moved the wrong way;
- **`GET /ndt/get_sflow_stats`** (new; `HttpSession::handleGetSflowStats`) -- 404 before this.

## Why this shape, and what it costs

**Field beside the data, not an endpoint alone.** An endpoint nobody calls reproduces the defect:
the counters already existed and were already correct -- the failure was that reading them was a
separate, optional act, and no consumer performed it. A field in the same body cannot be skipped by
a consumer who never learned it exists; at minimum it appears in their logs the first time they
print a response. The dedicated endpoint is kept as well, for a consumer that wants the health
without paying for a measurement, but it is the secondary channel, not the fix.

**Cost, stated plainly.** (a) Every flow row grows by ~200 bytes, and the same object repeats on
every row of the array -- `get_detected_flow_data` bodies get materially larger with flow count.
That is the price of `get_detected_flow_data` returning a bare JSON *array*: there is no envelope
to put a single copy in, and adding one would break every existing consumer, which is a worse
trade than repetition. (b) Three response shapes change. By the repo's own contract rules this is
additive and safe (`tools/contract_test/schema.py`: `Obj` is non-strict by default -- "a kernel
that *adds* a field is not breaking its consumers"), but it is still a shape change, hence the
branch.

**Why the number alone was not enough.** `dropped: 41273` does not tell a reader whether their
measurement is usable. `offered_in_window` is published over the *same* window so the fraction is
recomputable, and `loss_fraction` is derived from the two published numbers rather than stored, so
it cannot disagree with them. A reader who dislikes our thresholds can ignore `status` entirely.

**"We failed to ask" vs "the network is idle."** These are separated by construction, and this is
the part the gate is pointed at:

- `unknown` -- the rate loop has not closed a window. Nothing measured, so nothing claimed.
- `no_samples` -- a window closed and **zero** samples arrived. This is `rx`'s missing steady-state
  channel: a consumer polling any of the three carriers sees it every second, without log access.
- `ok` -- samples arrived, nothing lost.

`no_samples` is deliberately **not** `ok` with a zero count, because that is precisely the pair
that was indistinguishable before.

## Who consumes this today

- `tools/contract_test/spec.py:827` pins `get_detected_flow_data` as `List(FLOW_RECORD)` and
  `:865-868` pins `get_average_link_usage` as `Obj({"status","avg_link_usage"})`. Both are
  **non-strict**, so the added fields pass unchanged -- **no spec edit was required and none was
  made.**
- `/ndt/get_sflow_stats` is a **new** path and is therefore **unpinned**: nothing asserts its
  shape. Adding a spec entry for it is the follow-up, and it belongs in a **separate commit that
  can be dropped on its own** -- it needs a live kernel to verify, which this job did not have
  (the lab is held by another agent). **Left undone, listed below.**
- `SUMMARY.md` records `get_detected_flow_data` as "used by 5 components" and `get_graph_data` as
  "used by all 7 tools/apps". `get_graph_data` is **untouched** here.

## Gate

`tests/test_TelemetryHealth.cpp`, 11 tests against the pure static
`FlowLinkUsageCollector::classifyIngestHealth(...)`. Pure and static for the same reason
`classifyTelemetry` is: a verdict reachable only by standing up a collector and flooding a real
socket is a verdict no test will reach, and a mutation pinning it to `"ok"` would survive.

Gate results are in the "Mutation gate" section appended below.

## Left undone

- No live verification. The claims here are about code paths and unit-level behaviour; **nothing
  was run against a live kernel or a real sFlow flood** -- the lab was held. The measured numbers
  quoted are round 4's, cited.
- `tools/contract_test/spec.py` has no entry for `get_sflow_stats` (separate commit, needs a live
  run).
- `get_detected_top_k_flow_data` and the per-edge `telemetry_status` block were **not** given the
  field; only the two measurement carriers above and the new endpoint were.
- The thresholds (1% / 10%) are judgement, not measurement. The raw numerator and denominator are
  published so a consumer can overrule them.
- `no_samples` is per-window: a consumer polling faster than the 1 s rate loop can read the same
  window twice. It is not a rate limiter.
