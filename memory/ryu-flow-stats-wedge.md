---
name: ryu-flow-stats-wedge
description: "Restarting Ryu under a live Mininet wedges /stats/flow into returning an empty table forever; root cause unproven but the harm is fixed kernel-side by refusing an empty table that took ~1s"
metadata:
  node_type: memory
  type: project
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-19T04:21:28.868Z
---

**Trigger, reproducible twice**: restart Ryu while Mininet is still running. Healthy for ~9 s after the switches reconnect, then `/stats/flow/<dpid>` returns `{"N": []}` in 1.011 s forever. Correct order (Ryu first, then Mininet) ran 7.5 min / 223 samples and 3.6 days / continuous with zero degradation.

**Measured while degraded** (`doc/audit/2026-08-07_ryu-wedge-trace.tsv`, 151 samples): Ryu's `Recv-Q` climbs 12.5 → 25 → 37 → 62 → 75 KB then pegs at 90120 on all ten connections (the rmem ceiling); 877 KB unread on Ryu's side, 1.22 MB stuck on OVS's; Ryu's `Send-Q` to the switches is **0**. Ryu has simply stopped reading.

**Root cause: still unproven.** Best remaining candidate is `send_q = hub.Queue(16)` plus its `BoundedSemaphore` in `ryu/controller/controller.py:283-284`, which every sender must acquire at `:417` — but `Send-Q=0` weakens it. Proving it needs instrumentation inside Ryu; py-spy only sees OS threads and Ryu has one.

**Four hypotheses were falsified, all mine**, and the profile was over-read three times — most recently reading 8/27 samples in `_send_loop→sendall` as "blocked writing" when `Send-Q=0` disproves it. The recurring error is taking the first salient number for the whole explanation.

**The harm, and the fix that does not need Ryu.** The kernel reported all ten switches as holding zero flow rules while s1 really held 130 and the fabric forwarded normally — with every liveness indicator green (288/288 edges, 138/138 nodes). Confidently wrong, with nothing suggesting distrust. The discriminator is latency: 1.011 s ± 0.002 wedged against 0.027–0.083 s healthy, and 1.0 s is not a coincidence — it is `DEFAULT_TIMEOUT` in `ryu/lib/ofctl_utils.py:28`, awaited at `:253`. So `classifyFlowStatsReply` refuses an empty table that took ≥ 0.5 s, keeps the previous one and warns. A reply with any entry is always accepted however slow.

**How to apply**: during integration testing, never restart Ryu alone — restart Mininet with it. If flow tables read empty across the board, check the round-trip time before believing it.

**2026-08-13: the rule is now enforced in code.** `stack.sh up ovs` refuses to start Ryu while
mininet: processes exist (`--force` to override; commit `d2a609a`, shell-tested via the
`count_mininet_procs` seam). Trigger for the guard: the overnight OVS round's teardown left
Mininet running for the morning, and the documented restart path was exactly `stack.sh up ovs`
— agent C spotted the collision and deliberately skipped its kill-controller phase rather than
walk into it (the right call; its report §Phase 5 documents the reasoning).

**Three doors into the same wrong answer, all now shut.** The latency guard only catches the *slow* empty reply; every other route to "confidently empty" had to be closed separately, and each was found independently:

1. A body that fails to parse used to return `json::array()` — byte-identical to "no rules" and *fast*. Now returns `nullopt`.
2. The P4 proxy answered `{dpid: []}` when it could not read a switch, on the documented theory that "a transient failure should cost one poll". Fast, so it sailed under the 0.5 s threshold and was applied as an authoritative snapshot. Fixed 2026-08-11 (`42d86cd`): the proxy now answers 503 with `{"error": ...}`, and `classifyFlowStatsReply` gained a third verdict, `ReportedFailure`, checked *before* the entry scan. Note the kernel fetches with `curl -s` and never sees the status code — the body shape is the only channel the failure can travel on.
3. The original wedge itself, caught by latency.

The general shape: **failing is faster than timing out**, so any latency-based guard is structurally blind to a fast failure. If a component reports "empty" as its failure mode, no timing heuristic can save the consumer — the failure has to be *said*.

---

## 2026-08-19：**第二個 wedge，不同端點、不同機制、相反方向的謊**

Adam 自己在 Visualizer 看到 `enable: no, status: up`、Web-GUI 看不到流表，查出來的。
**症狀不會存活於乾淨的 bring-up**（重帶之後 10/10 switch、40/40 邊都 `enabled=true`），
但查下去挖到兩個真缺陷。

**指紋**：`is_enabled` 只有**一個**寫入者——`pollControlPlaneTopology` 餵的
`updateSwitches`/`updateLinks`/`updateHosts`（`TopologyAndFlowMonitor.cpp:566/863/688/728`），
loader 初始化全是 false（`:244`、`:319`）。而 switch 的 `is_up` 有**第二個**寫入者
（1 Hz liveness 迴圈 → `setVertexUp`，只碰 `isUp`）。
所以 **`up=true, enabled=false` 就是「liveness 跑了、topology poll 沒跑」的指紋**。

🔴 **kernel 這端沒有任何 timeout。** `utils::execCommand`（`Utils.hpp:543-568`）是裸 `popen()`，
而那條 curl 也沒有 `--max-time`。**一個沒反應的 controller 就能讓那條執行緒死到行程結束**——
沒有重試、沒有 watchdog、**一行 log 都沒有**。實測抓到 curl 活了 **733 秒**，跟 kernel 同秒啟動。

🔴 **Ryu 這端**：`intelligent_router.py:304` 的 `get_link()` 永久阻塞。
它的兄弟 `get_switch`（`:284-288`）有 20 秒的有界重試，**`get_link` 沒有**。
三個 `/v1.0/topology/*` 全回 HTTP 000，而**同一個行程**的
`/ryu_server/all_destination_paths` 在 0.2 ms 內回答——所以「Ryu 活著」不能當作證據。

**方向與上面那個 wedge 相反**：這次 fabric 一直正常轉發（h1→h2/h3/h4 全 0% loss），
twin 卻說 40 條 link 全 down。**悲觀的謊**，不是樂觀的。

**一行運維檢查**（值得寫進 runbook）：
```bash
curl -s -o /dev/null --max-time 3 -w '%{http_code}\n' http://localhost:8080/v1.0/topology/switches
```
回 `000` 就是 wedge 了，而且 **kernel 必須在 Ryu 之後重啟**。

**與 §「三道門」的關係**：那三道門關的是「空的回答被當成權威快照」。
這個 wedge 連回答都沒有——執行緒卡在 `popen()` 裡。
latency guard 對它無效，因為**根本沒有 reply 可以量延遲**。
缺的是 `execCommand` 的 timeout，那是結構性的，不是某個端點的問題。

相關：[[inherited-simulator-had-silent-bugs]]、[[replace-vs-add-bug-shape]]、
[[phase2-round-2026-08-19]]、[[process-liveness-checks-lie-in-two-ways]]。
