---
name: kernel-idle-cpu-spin
description: RESOLVED 2026-07-30 — the idle 100%-CPU burn was poll() with a 0ms timeout in the sFlow receive loop; fixed in d79979e
metadata: 
  node_type: memory
  type: project
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-07-30T02:14:33.489Z
---

**Resolved.** `ndtwin_kernel` used to pin ~100% of a core while completely idle. Cause: `POLL_TIMEOUT_MS = 0` in `FlowLinkUsageCollector::run()`'s receive loop. A 0ms timeout means *return immediately* — `-1` is the blocking form — so with no traffic the loop was `poll` → `ret==0` → `continue` → `poll`, a pure busy-wait. The comment above it read "poll without timeout", which made the bug look deliberate. Fixed by using 100ms (commit `d79979e`).

Measured before and after on an idle kernel with no data plane, no controller and zero flows:

| | CPU |
|---|---|
| before | `run` thread 100.9%, process 101% |
| after | process **1.7%** |

Telemetry verified unaffected: 7 fixtures in → `rx=7 app_drop=0 addressed=8`, 5 flows parsed. A readable socket wakes `poll()` immediately whatever the timeout, so throughput is unchanged; 100ms only bounds shutdown latency, which is the sole reason the loop polls instead of blocking forever.

**How it was found, which is the transferable part:** per-thread sampling of `/proc/PID/task/*/stat`, not guessing. My two prior suspects — the 1-second loops in `calAvgFlowSendingRatesPeriodically` and `pingWorker` — measured 1.9% and ~0%. Both were plausible from reading the code (they log every second, and `pingWorker` deep-copies the graph and shells out to `ovs-vsctl` per tick), and both were wrong. The earlier version of this note said "measure with perf before guessing"; that advice paid off.

Turned up while checking whether a refresh thread I had just added for [[live-runs-find-what-tests-cannot]] Phase 6 work had made the CPU problem worse. It had not — it shows as ~0% — but looking properly at the question found the real cause.
