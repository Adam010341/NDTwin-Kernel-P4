# 交接筆記（2026-07-29 收尾）

[Co-developed with claude code -- Adam]

這份是「還沒歸檔的東西」清單。已經歸檔的請直接看：

| 內容 | 在哪 |
|---|---|
| 各 Phase 進度、Phase 6 入手點 | [p4_bmv2_support_plan.md](p4_bmv2_support_plan.md) 開頭的「目前進度」 |
| 測試流程、實測數據、通過標準 | [p4_status_and_test_guide.md](p4_status_and_test_guide.md) |
| 環境陷阱（sudo、pgrep、清理、順序） | [environment_gotchas.md](environment_gotchas.md) |
| OVS↔P4 的 170 個已接受差異＋原因 | [../tools/contract_test/baseline_diff_allowlist.txt](../tools/contract_test/baseline_diff_allowlist.txt) |
| 每個 bug 的完整分析 | git log（commit message 寫得很詳細，`3acad16`..`02c4913`）|

---

## 下一步：Phase 6

計畫在 `p4_bmv2_support_plan.md`。**先讀那裡的「Phase 6 的具體入手點」**（5 條實測發現）。

核心事實：`GET /ndt/inform_switch_entered` 是**唯一**會把 `isEnabled` 設成 true 的東西，
proxy 完全沒呼叫它。連帶 `path=[]`、速率 0、link usage 0。
**telemetry 資料已經進到 kernel 了，缺的是把它掛到圖上。**

⚠️ **開始 Phase 6 之前**：`EventBus::emit()` 有一個確認過但目前休眠的 deadlock
（持有 `shared_lock` 時同步呼叫 handler）。全專案目前**沒有任何** `registerHandler()` 呼叫，
所以踩不到；但 Phase 6 接第一個 handler 的那一刻它就活了。修法（已討論、未套用）：在持鎖區間內把
handler vector 複製出來、放鎖後再呼叫。

---

## 還沒歸檔 / 未解決的事

### 1. ~~kernel 閒置時燒 100% CPU~~ ✅ 已解決（2026-07-30，commit `d79979e`）

原因是 `FlowLinkUsageCollector::run()` 的 `POLL_TIMEOUT_MS = 0`。**0 的意思是「立刻返回」，不是
「不設逾時」**（`-1` 才是阻塞），所以沒流量時迴圈是 `poll` → `ret==0` → `continue` → `poll`，
純忙等。而它上面的註解寫「poll without timeout」，讓這個錯看起來像刻意的。

| | CPU |
|---|---|
| 修正前 | `run` thread 100.9%、process 101% |
| 修正後 | process **1.7%** |

功能無損：灌 7 個 fixture → `rx=7 app_drop=0 addressed=8`、解析出 5 筆 flow。

**過程中值得記的一點**：我原本懷疑的兩個一秒迴圈
（`calAvgFlowSendingRatesPeriodically` 和 `pingWorker`）實測是 **1.9% 和 ~0%** —— 兩個都很合理
（都每秒印 log、`pingWorker` 還每次深拷貝整張圖 + shell 出去跑 `ovs-vsctl`），但**兩個都猜錯**。
是靠 `/proc/PID/task/*/stat` 的 per-thread 取樣定位的，不是靠讀程式碼。

### 2. L2 契約還有 6 個 FAIL（全部既有，與 P4 無關）

帶流量的 OVS 迴歸跑到 **30/36**。剩下的：

| 項目 | 原因 |
|---|---|
| `get_graph_data`（254 條 host edge down）| static ARP → Ryu 學不到 host IP → `updateHosts` 跳過 127 台。詳見計畫書 Phase 6 入手點第 1 條 |
| `install_flow_entry__unknown_dpid` → 200 | Phase 2 的 propagation 缺口：kernel **有**正確拒絕並記 WARN，只是 `OpResult` 沒反映到 HTTP status |
| `get_path_switch_count__bad_ip` → 500 | `Invalid IP address` 例外沒接 |
| `inform_switch_entered__bad_dpid` → 500 | `std::stoull` 沒包 try |
| `received_a_simulation_case` ×2 → 202 | 收到爛 JSON 也回 202 |

後三類是同一個模式：**輸入驗證缺口讓例外變成 500**。可以一起修，但會動到共用的 `HttpSession`。

### 3. 刻意延後的技術債

- **shell injection**：每條南向指令都是 `popen("curl … -d '" + json.dump() + "'")`，
  `nlohmann::json::dump()` 不會 escape 單引號，而 JSON 來自未認證的 REST body 和 LLM 輸出。
  3 個檔案共 22 處。**你說過要先跟其他人討論再處理。**
- **P4 parser 沒檢查 IHL**、**分片封包繞過 L4 規則**：Mininet 環境不會觸發，修要動 pipeline。
- **`send_to_cpu` 沒有 rate limiter**：任何 controller-based learning switch 的通病，OVS 那側也一樣。

### 4. 沒驗證成功的東西

- **P4 的 direct counter / per-port counter**：讀不到。`simple_switch_CLI` 需要 `thrift` 的
  Python binding，兩個 interpreter 都沒裝（見 environment_gotchas）。要驗證得先 `pip install thrift`。
- **`P4RoutingStrategy` 實際下規則的完整路徑**：每一段都有單元測試，但 curl → proxy → P4Runtime
  整條沒對活的 switch 跑過。
- **PI 對重複 clone session 回什麼 status code**：`write_clone_session()` 的 `ALREADY_EXISTS` →
  `MODIFY` fallback 從來沒在實機上被觸發驗證過。曾經看到一次失敗但 `details()` 是空字串所以無法判斷
  （已改成連 `code().name` 一起印）。要驗證的話：對活的 switch 連續寫兩次同一個 session。

### 5. 未清理的執行環境狀態

- kernel / proxy / ryu 都已停，`:8000`/`:8080`/`:8081` 全空。
- **Mininet 還開著**（bmv2 10 台）。要收：Mininet terminal 打 `exit`，然後
  `sudo mn -c && pkill -f simple_switch_grpc`。
- `.test_run/baseline/{ovs,p4}` 兩份基準都是**在正確設定下、有流量時**抓的，可以信任。
  Phase 6 做完之後會產生大量預期差異，屆時 allowlist 裡標了「Phase 6」的項目應該變成 unused
  —— 那正是它們該消失的訊號。
