---
name: ndtwin-static-arp-blocks-host-discovery
description: "二度更正 — 08-22 終局見 punt-window-host-learning：empty ipv4 只在 settle 窗內 transient、窗外永久；snapshot 修法只治了 kernel 下游。128/128 量在 08-07（settle=60 時代）"
metadata:
  node_type: memory
  type: project
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-22T03:55:45.403Z
---

**🔴 2026-08-22 二度更正：下文的「empty ipv4 是 transient」只在 settle（規則安裝前）窗內成立，窗外是永久的——機制與介入證明見 [[punt-window-host-learning]]（`e5e4980`）。** 下文的 snapshot 修法（71d27c1 polling）真實且必要，但只治 kernel 下游；「how to apply」裡「查 kernel 相對 Mininet 的啟動時機」已過時，該查的是 **settle 窗有沒有接住 ping burst**。表中 08-07 的 128/128 量在 settle=60 時代。

**This memory previously recorded the wrong cause. Both the cause and the operational advice are corrected below; the old version told the next person to stop investigating, which would have hidden a real fault.**

The symptom was real: `get_graph_data` reported 254 of 256 host edges down in **OVS** mode, failing the L2 API contract.

**The cause I originally recorded — and disproved.** I wrote that `testbed_topo.py` gives every host a static ARP entry (`arp -s`), so hosts never send ARP, so Ryu's host tracker never learns their IPs, so `updateHosts`' opening `if (host["ipv4"].empty()) continue;` skips them all — permanently. The static ARP is real, but the conclusion is not: `testbed_topo.py` **pings all 128 hosts in parallel itself** right after setting the ARP entries (64 pairs, both directions), and those IP packets are what teach Ryu. An empty `ipv4` is **transient**, not a permanent limitation.

| measured | hosts reported by Ryu | with non-empty `ipv4` | kernel graph |
|---|---|---|---|
| 2026-07-29 | 128 | **1** | 254/256 host edges down |
| 2026-08-07, after 3.6 days uptime | 128 | **128** | 288/288 edges, 138/138 nodes up |

**The actual cause, and it is much broader.** `TopologyAndFlowMonitor::run()` called `fetchAndUpdateTopologyData()` once and returned — measured 88 ms from entry to exit, then never re-read for the entire process lifetime. The whole graph (switches, hosts **and** links) was whatever Ryu happened to know in that instant. So the deciding variable was the **startup gap**: starting the kernel 73 s after Mininet meant the ping burst had finished (128/128 up), while `stack.sh up ovs` back-to-back put the snapshot mid-burst (permanently missing data). Same code, same network, opposite verdict. Hosts were the loudest symptom because nothing pushes host updates — switches have `/ndt/inform_switch_entered` and links have `/ndt/link_failure_detected`, but hosts have no push path at all.

Fixed 2026-08-03 (commit `71d27c1`) by making `run()` poll periodically (every 5 s for 90 s, then every 30 s).

**Why:** this is the clearest instance of the pattern in [[live-runs-find-what-tests-cannot]] — I reached a plausible mechanism from reading `testbed_topo.py`, stopped, and wrote it down as settled. It survived a week because the symptom matched. What broke it was re-measuring the same endpoint under different conditions, not re-reading code.

**How to apply:** if host edges are down, do **not** conclude static ARP and stop. Check `curl localhost:8080/v1.0/topology/hosts` for empty `ipv4` fields, and if they are empty, check **how long ago the kernel started relative to Mininet** — that is the variable. Still true and worth knowing: vertex lookup is `findVertexByMac` (works without an IP), only the edge lookup `findEdgeByHostIp` needs the address, so that early `continue` is stricter than the code below it requires. Related: [[eventbus-deadlock-deferred]] for the "one snapshot that should have been a reconcile" shape, which turned up three times in one day.
