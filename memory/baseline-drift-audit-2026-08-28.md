---
name: baseline-drift-audit-2026-08-28
description: 08-28 兩輪純讀稽核的結論——657 個 commit 只有「一次快照→持續輪詢」一處是真架構改動；跨 repo wire 相容性只剩 Visualizer 一條迴歸未修
metadata: 
  node_type: memory
  type: project
  originSessionId: c0b9d217-a751-4b19-9f97-47a9aaadacf4
  modified: 2026-08-28T06:05:45.828Z
---

2026-08-28，8/27 auditor 派的兩輪**純讀**稽核（沒有改任何程式碼）。
Adam 的原始疑慮：「我怕我們這幾百個 commit 把實驗室原本的架構設計給改掉了」。

**正本在 repo，不要從這裡讀細節：**
- `doc/audit/2026-08-28_baseline-architecture-drift/`（SUMMARY.md / FINDINGS.md 68 條 / METHOD.md / raw/）
- `doc/audit/2026-08-28_wire-consumer-compat/FINDINGS.md`

比對範圍：**`28b8b13`（fork point）→ `b024354`**，657 commits，只看 `src/`+`include/`（50 檔）。
（依 [[benchmark-must-name-the-binary-it-measured]] 的規則指名 commit。）

## 🔑 頭條：只有一處是真的架構改動

**`TopologyAndFlowMonitor::run()` 從「開機拍一張快照」改成「持續輪詢控制平面」。**
`28b8b13` 的 `run()` 呼叫 `fetchAndUpdateTopologyData()` **一次就 return**
（碼內留有實測：進 13:55:55.154、出 .242，**88 毫秒**），之後整個 process 生命期沒有東西再讀拓樸。

**它有明確的波及半徑**——下面全是它的下游，該當成**一個決定**評估而不是七個：
新增 `adminDisabled` 旗標／`is_enabled` 折算／`isUsable()` 取代 `isUp && isEnabled`／
靜態載入拒絕第二次（否則每 5 秒複製一整份拓樸：switches 10→20→30→40→50、hosts 128→640）／
三個 `update*` 的例外邊界從 `json::parse_error` 放寬到 `std::exception`。

**其餘 60 幾條不是換設計，是同一個形狀的修正**：
*baseline 在某處回報了一個它沒有建立的事實，改動把回報改誠實。*
（電源對任何 HTTP 回應都回 Success／bmv2 交換機無條件標 up／一次失敗的 `ovs-vsctl`
把整個 fabric 標死／`{"dpid":1}` 空殼請求回 200 queued。）

## 結構讀數：這 657 個 commit 偏向疊加

**baseline 的 56 個檔案零刪除、零改名**（`--diff-filter=D` 與 `-R` 皆空，已驗）。
移除的只有 7 個函式、4 個參數/成員、3 個行為分支，每一個在 baseline 裡都是
**零呼叫端**或**存了從不讀**（例：`FlowDispatcher` 的 `fencePerBurst` 文件寫著保證 batch 間順序，
值存進一個從沒被讀過的成員）。

## 🔴 唯一還沒處理的東西

**B-45 對 Network-Traffic-Visualizer 是真迴歸。**
CPU/記憶體報告：`28b8b13` 對關機交換機**省略該鍵**，`b024354` 改回 `-1`。
- Web-GUI ✅ 有 `=== -1` 分支（`DeviceInformation.tsx:380,390`），而且 `|| 0` 不會吃掉 truthy 的 `-1`
- **Visualizer 🔴 全 repo 沒有任何 `-1` 分支** ⇒ `NetworkTopologyApp.java:704` 的
  `if (cpu != null)` 收下 `-1` ⇒ `InfoDialog.java:338,343` 顯示 **"-1%"**（原為 "N/A"）

修法在 Visualizer 側一行（`if (cpu != null && cpu >= 0)`）。**指示是只記錄不修，所以沒動。**
⚠️ **讀碼確認，未實跑 Visualizer。** 已查證引用的兩行在**已提交**狀態（`InfoDialog.java`
有未提交修改，但那 3 行沒碰 cpu/mem，且 `HEAD:` 版本逐字相同）。

## 兩條會誤導後人的宣稱（都在我們自己的碼裡）

1. **`HttpSession.hpp` 寫「This figure is what Energy-Saving-App reads … another component's
   decisions」——不成立。** ESA 有 `get_average_link_usage()`（`src/app/http.cpp:393`），
   **全 repo 零呼叫端**（grep 驗證，ESA `HEAD=9facb78`，`src/`/`include/` 無未提交修改）。
   連「餵進去」都不成立。改動本身對，理由寫得比證據強。
2. **`FlowLinkUsageCollector.cpp` 寫某 stale-rate 行為是「Introduced on this branch by the
   divide-by-zero guard (31b357a6)」——方向反了。** `28b8b13:1304` 本來就有
   `if (hopsCounter == 0) { continue; }` 且同樣沒清零；是 `6f32bca` 移除、`31b357a` **復原**。
   照那條註解行動的人會去我們的 commit 裡找一個不在那裡的迴歸。**建議更正，未動。**

## 🔴 我沒查、所以結論管不到的

1. **正確性完全沒驗**——沒 build、沒跑、沒跑測試。只答「有沒有被改掉」，不答「改得對不對」。
2. **13 個新檔案的內部只計數未逐行讀**（`IRoutingStrategy` 等八個 + 三個 power strategy +
   `OpResult` + `KeyedFailureLog`）。⇒「選對了 strategy」驗到了，
   **「strategy 做的事等價於 baseline 的 curl」沒驗**。
3. **W2（可能比任何一條都重要）**：B-17（sFlow `outputPort` 從硬寫 0 改成讀真值）與
   B-4（rate 真的除以實測間隔）**改的是 `get_graph_data` 裡的數值**，而
   **Network-State-Recorder 正在把這些值錄進歷史資料** ⇒ **跨 kernel 換版的歷史資料
   不是同一個量測**。本輪只追 `is_enabled`，沒追數值欄位。
4. 只搜字面字串 ⇒ 端點名被拆開拼接的消費者會漏（見 [[grep-endpoints-misses-concatenation]]）。

## 附帶：一個已修掉的安全問題

`28b8b13` 在 **INFO 等級**把 OpenAI API 金鑰印進 kernel log
（`LLMAgent.cpp`，`SPDLOG_LOGGER_INFO(..., "api_key={}", apiKey)`），而這是**公開 repo**。
HEAD 已移除。**要不要通知上游是 Adam 的決定**，auditor 說會列進報告，我不用做事。
⚠️ **baseline 時期產生的舊 log 可能含金鑰——未查。**

相關：[[benchmark-must-name-the-binary-it-measured]]、[[p4-128-hosts-four-hardcoded-lists]]、
[[cross-repo-component-ecosystem]]、[[existence-is-not-wiring]]、[[upstream-merge-state-fork-28b8b13]]
