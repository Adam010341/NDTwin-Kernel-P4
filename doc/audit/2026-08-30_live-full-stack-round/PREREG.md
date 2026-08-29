# Pre-registration — live full-stack round #2, 2026-08-30

[Co-developed with claude code -- Adam]

Written **before** the round, while the lab is held by `開機手冊` for the installation-manual
VM replay. Nothing here has been run. Registered by `8/29 auditor`.

Kernel under test: `faffdbe`. Reference round: `doc/audit/2026-08-18_live-full-stack-round/`
against `04b8933` (2026-08-18 16:26).

---

## §1 Why this round exists — the gap is measured, not felt

"Full stack" here means what the 08-18 round meant: fabric → kernel :8000 → **all five
consumer apps** (`ndt apps`: `energy sim nsr viz te`). Dated by each app's own output:

| App | Last artefact it wrote |
|---|---|
| Energy-Saving-App | **2026-08-18 21:17** (`Graph.json`, `FlowDataList.json`, `SwitchFlowRuleTables.json`) |
| Traffic-Engineering-App | **nothing since 08-18** |
| Simulation-Platform-Manager | **nothing since 08-18** |
| Network-State-Recorder | 2026-08-20 17:08 (`recorded_info/2026_08_20_17-07-31_*.json`) |
| Network-Traffic-Visualizer | 2026-08-20 00:31 (`settings.json` only — config, not a run) |

Corroborating: `.test_run/logs/app_nsr.log` is **0 bytes, mtime 08-20 17:09**; `app_viz.log`
and `app_te.log` were never created; `tmux ls` reports no server, so the two tmux-hosted apps
(`energy`, `sim`) are not running either.

⇒ **All five last ran together on 08-18. Twelve days.** Everything live since then has been
fabric + kernel + proxy only (flow-count capacity, packet-size sweep, single-switch build
ratio, jitter working point, receiver-bottleneck, chaos harness first live run).

This matters because `/ndt/` is a **cross-repo contract**: the callers live in seven sibling
repos, none of them here, so nothing in this repo's test suite goes red when one breaks.

## §2 🔴 The headline hypothesis was killed before the round, by measurement

**What I proposed:** ticket Q (`f5e3556`, 08-27 21:53) added the missing division —
`estimatedIn = accumulatedBytes*8/elapsedSeconds`, where before it was `accumulatedBytes*8`
consumed as bits-per-second. The wire field is literally named `link_bandwidth_usage_bps`.
Since the rate loop sleeps a full second **and then** runs its body, the old figure was
inflated by the body time, so the fix should lower reported utilisation and therefore push
Energy-App's groups **below** `LOW_WATER_MARK = 0.40` more often ⇒ more shutdowns.

**The chain is real.** Every link read from source, callers checked in both directions:

| # | Site | What happens |
|---|---|---|
| 1 | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1087` | `estimatedIn = bytes*8/elapsedSeconds` (ticket Q) |
| 2 | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1114-1116` | `leftBandwidthFromFlowSample = linkBandwidth - estimatedIn`; `linkBandwidthUtilization = (1 - leftIn/linkBandwidth)*100` |
| 3 | `src/ndt_core/http/HttpSession.cpp:553-557` | emits `left_link_bandwidth_bps` (MININET ⇒ the FromFlowSample variant) and `link_bandwidth_utilization_percent` |
| 4 | Energy-App `src/app/http.cpp:337` | `GET /ndt/get_graph_data` |
| 5 | Energy-App `src/app/energy_saving_app.cpp:701,704` | fetch → `json2sim["Graph"]` |
| 6 | Energy-App `src/app/energy_saving_app.cpp:888,895` | `json2sim = easy_get_info_from_ndt()`; `Graph g = json2sim.at("Graph").get<Graph>()` |
| 7 | Energy-App `include/common/GraphTypes.hpp:92` | `linkBandwidthUtilization = j.at("link_bandwidth_utilization_percent")` |
| 8 | Energy-App `src/common/types.cpp:411,427` | sums it over up+enabled edges, `return utilizationSum / (edgeCount * 100.0)` |
| 9 | Energy-App `src/app/energy_saving_app.cpp:911,926` | `<= LOW_WATER_MARK` ⇒ `easy_disable_switch` |
| 10 | Energy-App `src/app/energy_saving_app.cpp:958` | driven by a periodic loop, gated by `acquire_lock()` |

⚠️ Two links pass through **commented-out code** and would read as broken if skimmed:
`energy_saving_app.cpp:702` (`// g = graph.get<Graph>();`) and `types.cpp:220`
(`// data.linkBandwidthUsage = g[*ei].linkBandwidthUsage;`). Neither breaks the chain — the
parse happens at `:895` from the same JSON, and the decision path reads
`link_bandwidth_utilization_percent` **straight off the wire** rather than recomputing it.

**And the magnitude is nil.** The kernel logs both sides of ticket Q's gate every 30
iterations in MININET mode (`FlowLinkUsageCollector.cpp:2013-2021`). `.test_run/logs/kernel.log`
from the 08-29 22:19 run already contains them:

```
n=704   min=1.000212   p50=1.000616   p95=1.001046   max=1.122825
```

⇒ the divisor is **1.0006 s median, 1.0010 at p95**. Ticket Q therefore moves reported
utilisation by **−0.06% median, −0.10% at p95**, with one 11% excursion in 704 iterations.

🔑 **A 0.1% correction cannot move a 0.40 threshold except for a group already sitting within
0.1% of it.** The bug was real and the fix is right — the field name was a lie whenever the
period was not exactly 1 s — but **it is not a reason to run this round, and no prediction in
§3 rests on it.** Registering this here so the round is not later credited with confirming it.

Also checked and cleared: `e72f34d` ("batched sFlow datagram banks every sample's bytes") is
**test-only** — it adds `sampledByteCreditFor()`, a read accessor, and changes no behaviour.

## §3 What is actually registered

Behavioural changes in the window `04b8933..faffdbe` that reach outside this repo. Four source
files changed, 303 insertions.

**R-1 — response-body shape change on `/ndt/set_historical_logging_state`.**
`HttpSession.cpp:1793-1815` adds a `"recording"` field to the success body and a new
early-return branch with a different `message` when `is_enabled && !canRecord()`. Both lab
stacks are MININET, and `HistoricalDataManager::start()` returns early there, so **the new
branch is the one that fires in every run this project does**.
*Registered check:* every app that calls this endpoint still parses the reply. Break condition
is a parse throw or a behaviour change in the caller, not the presence of the new field.
*Registered null branch:* **no app calls this endpoint at all** — in which case R-1 is
untestable by this round and must be reported as untestable, not as passed.

**R-2 — path recompute 1 kHz → 1 Hz** (`2f57ba5`). `flowPath` freshness changes by three
orders of magnitude. Consumers poll on a 15 s cadence, so the registered expectation is **no
observable difference**; a difference would mean something reads paths far more often than the
15 s cadence suggests. Cross-check against
`memory: destination-paths-not-monotonic` (refresh thread, ceiling ≈60 s) before concluding.

**R-3 — kernel no longer blocks its own API on an unsatisfiable fetch** (`b539be7`).
Changes **startup ordering** as seen by apps that poll on boot. Registered: convergence time
from `ndt up` to all five apps serving. 08-18 reference: **69 s (OVS)** / **2 s (P4)**.
Break condition is failure to converge, not a different number.

**R-4 — the unknowns.** Three silent-failure fixes plus an API concurrency change (`aabe605`).
No specific prediction; this is the part of the round whose value is that it is run at all
(`memory: live-runs-find-what-tests-cannot` — 8 of 9 bugs came from live runs).

**R-5 — the 08-18 findings, re-checked.** `live-findings-2026-08-18-{ovs,p4}.md` F-1…F-5b are
re-run as-is. Each gets one of: still present / fixed / **no longer reachable** (the third
branch is registered on purpose so a finding that merely became untestable is not scored as
fixed).

## §4 Preconditions — this round must not start until all four hold

1. `開機手冊`'s lab claim is **released** (`ndt status` → `claim` empty). It runs a 4-vCPU QEMU
   VM doing apt+pip+cmake+ninja that is **invisible to `measuring`**; overlapping it would put
   an unbookkept load on the same cores.
2. Claim the lab with `NDT_OWNER` set, `exclusive_cpu=yes`, and a `note` naming this round.
3. Record the kernel binary the way `memory: benchmark-must-name-the-binary-it-measured`
   requires — commit sha **and** which kind of identifier it is — plus the bmv2 build in use
   (`ndt status` currently shows `/usr/local/bmv2-fast/bin/simple_switch_grpc`).
4. `ndt status` → `measuring` reads `nothing` and no `claude` session is running a heavy job
   (`memory: vm-on-this-machine-is-invisible-to-ndt-status` — an idle session is ≈29% of one
   core, and the session doing the recording is itself a covariate).

## §5 Out of scope, stated so it is not read as covered

- **Timing/throughput numbers.** This is a wiring and correctness round. Nothing measured here
  may be quoted as a performance figure.
- **`/ndt/acquire_lock`'s three defects** (`doc/audit/2026-08-28_chaos-harness/06_ticket_acquire-lock.md`)
  — still 待裁, not opened. Noted here only because Energy-App's power loop is gated by exactly
  that endpoint (`energy_saving_app.cpp:952`), so the round will exercise it incidentally
  without testing it.
- **The poster / bmv2 report work.** Untouched by this round.
