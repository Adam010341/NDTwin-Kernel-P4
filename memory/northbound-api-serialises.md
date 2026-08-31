---
name: northbound-api-serialises
description: "2026-08-20 實測：`/ndt/` 一次只服務一個請求。吞吐跨 16× 併發持平在 84 req/s、延遲線性上升（與序列化預測差 <2%）。今天不咬人（7 app @1Hz = 8.3% 執行緒），但界定了一個可講的邊界"
metadata: 
  node_type: memory
  type: project
  originSessionId: 38b035fc-b098-4e53-9db6-78561882a7f2
  modified: 2026-08-20T09:11:07.263Z
---

**孿生的核心主張是「七個 app 同時透過 `/ndt/` 消費它」，而那從來沒有在並發下被測過**
——`run_layers.sh` 和 `run_contract_test.py` 都是**序列**發請求，所以 L2/L3 全綠說明不了任何事。

`doc/audit/2026-08-20_sampling-rate-and-cpu/headline_blocking.py`，每個等級 30 s，**全部是 GET**：

| N | 吞吐 | p50 | vs N=1 | 序列化預測 |
|---|---|---|---|---|
| 1 | 78.4 req/s | 11.9 ms | 1.00× | — |
| 2 | 84.6 | 23.4 ms | **1.96×** | 2.00× |
| 4 | 84.3 | 47.0 ms | **3.93×** | 4.00× |
| 8 | 84.1 | 93.9 ms | **7.87×** | 8.00× |
| 16 | 84.7 | 188.0 ms | **15.75×** | 16.00× |

🔑 **`1 / 11.9 ms = 84.0 req/s`，與實測吞吐三位數字吻合** —— 天花板就是「同時一個請求在飛」。
**不需要注入故障就看得到**：單執行緒伺服器的簽名是吞吐釘死、延遲線性。

成因：`src/main.cpp:316` 的 `net::io_context ioc{1}`，而 handler 裡有同步的 `popen`
（`HttpRoutingStrategyBase.cpp:70` 南向、`TopologyAndFlowMonitor.cpp:476-502` 拓撲輪詢）。

## 怎麼講才誠實

**今天不咬人**：7 個 app @ 1 Hz = **8.3% 的執行緒、12× 餘裕**。
**它買到的是有界的後果**：一個卡 **500 ms** 的南向呼叫（死掉的 Ryu/proxy）佔住唯一的執行緒
**42 個請求的時間**，期間每個消費者都在排隊。

⚠️ **不要當 bug 報。** 「我們量出了自己架構的運作邊界」是系統論文該有的東西；
「我們有個 bug」是弱的。而且**已知、已量化、已解釋的限制是強項，沒量過的才是洞**。

⚠️ **單次、單一圖大小。** 服務時間隨圖大小變（這是 128-host、288 條邊）；序列化本身是結構性質，
與大小無關。

**想在 MININET 注入一個慢 handler 是行不通的**：`get_cpu_utilization` /
`get_memory_utilization` / `get_temperature` 根本不碰 SNMP/SSH，只做 hash 算術
（見 [[fabricated-switch-cpu-in-mininet-mode]]），是這裡**最快**的端點。真正會阻塞的是南向
`popen`，但碰它要改路由狀態。

圖：`NDTwin slide material 827/figures/page_api-concurrency-envelope.png`

**2026-08-20 補**：`net::io_context ioc{1}` 在 **28b8b13 的 `main.cpp:119` 就有**（git grep 直接確認）——序列化是**繼承的**，不是我們引入的。歸屬歸屬，「今天不咬人」的結論不變。
