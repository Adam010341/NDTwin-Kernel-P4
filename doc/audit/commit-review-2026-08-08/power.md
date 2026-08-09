# `src/ndt_core/power_management/` + `include/ndt_core/power_management/` commit review

## 摘要（先講結論：找到幾條、最嚴重的是什麼）

從 baseline `28b8b13` 到 `HEAD`，此範圍共 12 個 commit、8 個檔案、+1487/-134 行。
改動主軸是把原本全寫死在 `DeviceConfigurationAndPowerManager` 裡的 OVS 電源控制抽成
`IPowerStrategy` 策略模式，並加入 P4/bmv2 的 stub 實作；同時修復了 liveness 三態
（Up/Down/Unknown）、flow-stats 逾時守衛、RelayResult 解讀等多項長期缺陷。

**找到 2 條高嚴重度、5 條中嚴重度、3 條低嚴重度發現。**
最嚴重的是：
1. **`OVSPowerStrategy::m_lastCommandFailed` 的競爭條件**（新引入）—— 兩個 HTTP 請求
   同時對不同 OVS 交換機做 power on/off 時，共用旗標會互相汙染，導致成功的操作回報失敗
   （或反之）。
2. **`pingWorker` 內註解宣稱 bmv2 仍是 stub，但實際程式碼已實作真實 liveness 檢查**
   —— 註解明確說假話，會誤導後續維護者。


---

## 高嚴重度發現

### H1. `OVSPowerStrategy::m_lastCommandFailed` 旗標無同步保護，並行 power 操作會互相汙染

- 位置：`src/ndt_core/power_management/OVSPowerStrategy.cpp:78,127`（寫入）、`:103,154`（讀取）；`include/ndt_core/power_management/OVSPowerStrategy.hpp:43`（宣告）
- 現象：
  `OVSPowerStrategy` 是 `DeviceConfigurationAndPowerManager` 的**唯一成員**
  （`m_ovsPowerStrategy`，見 `.hpp:455`），所有 OVS 交換機的 power on/off 請求
  都打到同一個物件上。`powerOn()` 與 `powerOff()` 的流程都是：
  1. `m_lastCommandFailed = false;`（reset）
  2. 多次呼叫 `executeSystemCommand()`，該函式在 `std::system()` 回傳非零時
     設定 `m_lastCommandFailed = true`
  3. 結尾檢查 `if (m_lastCommandFailed)` 決定回傳成功或失敗

  如果兩個 HTTP 請求同時抵達（例如對 s1 做 power on、對 s2 做 power off），
  執行序 A 的 reset 可能被 B 覆蓋，A 的失敗可能被 B 讀到（或 B 的成功被 A 的
  失敗汙染）。`std::system()` 本身雖然是 thread-safe，但 `m_lastCommandFailed`
  只是一個普通 `bool`，沒有任何 mutex 或 atomic 保護。

- 為什麼不合理：
  這是**新引入的共用可變狀態**。baseline 的 `setPowerStateMininet`（見
  `git show 28b8b13:src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`
  第 757-807 行）完全沒有這類跨請求的狀態——所有邏輯都在區域變數上完成，
  `std::system` 的回傳值直接用完即丟（雖然 baseline 也丟了回傳值本身就是另一個 bug）。
  新架構把狀態提升到策略物件的成員變數，卻沒有提供任何同步機制。

- 證據：
  - 宣告：`OVSPowerStrategy.hpp:43` — `bool m_lastCommandFailed = false;`
  - 寫入：`OVSPowerStrategy.cpp:25` — `m_lastCommandFailed = true;`
  - reset：`:78` — `m_lastCommandFailed = false;`（powerOn），`:127`（powerOff）
  - 讀取：`:103`、`:154`
  - 呼叫鏈：`HttpSession.cpp:681` → `setSwitchPowerState()` → `setPowerStateMininet()`
    → `strategy->powerOn()`/`powerOff()`。HTTP 請求預設是並行的。
  - 兩個策略物件都是 `DeviceConfigurationAndPowerManager` 的成員（`.hpp:455-456`），
    整個 process 生命週期只有一份。

- 建議：
  最輕量的修法是讓 `powerOn()`/`powerOff()` 內部改用**區域變數**追蹤成敗，
  不要共用 `m_lastCommandFailed`。例如把 `executeSystemCommand()` 改成回傳
  `bool`，由呼叫端累積。這樣既保有可測試性（mock 仍可覆蓋 `executeSystemCommand`），
  又消除了共用狀態。如果堅持要保留成員變數（例如為了跨函式追蹤），至少要用
  `std::atomic<bool>` 並接受其 weak memory ordering 的語意限制。

### H2. `pingWorker` 內註解宣稱 bmv2 liveness 仍是 stub，與實際程式碼矛盾

- 位置：`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:718-722`
- 現象：
  ```cpp
  // NOTE: this remains a stub that assumes bmv2 switches are always up,
  // so a powered-off switch reports UP again within one second. Replacing
  // it with real liveness (proxy gRPC channel state + LLDP freshness)
  // is Phase 6 of doc/p4_bmv2_support_plan.md; the honest fix needs the
  // proxy to expose that state, which it does not yet.
  ```
  這段註解正下方（第 723-746 行）的程式碼**已經實作了真實的 liveness 檢查**：
  ```cpp
  switch (p4LivenessFor(graph[v].dpid, p4SwitchState))
  {
  case OvsLiveness::Up:    ... setVertexUp(v);   break;
  case OvsLiveness::Down:  ... setVertexDown(v); break;
  case OvsLiveness::Unknown: /* leave graph alone */ break;
  }
  ```
  `p4LivenessFor()`（第 366-471 行）是一個 105 行的函式，檢查 `probe_ok`、
  `probe_age_s`、`last_lldp_age_s` 三項證據，實作三態判定。**這不是 stub。**

- 為什麼不合理：
  註解明確告訴讀者「bmv2 交換機永遠被當作 up」「Phase 6 才會實作」，但 Phase 6
  已經實作完了，註解卻沒刪。後人若只看註解，會以為這段邏輯還沒做，可能重複實作
  或誤判 bug。**說謊的註解比沒有註解更糟**（任務提示第 2 類）。

- 證據：
  - 假註解：第 718-722 行
  - 真實程式碼：第 723-746 行（`if (graph[v].switchKind == SwitchKind::BMV2)` 分支）
  - `p4LivenessFor` 完整實作：第 366-471 行
  - 另一段註解（第 725-729 行）**正確地**描述了新行為：「Was an unconditional
    setVertexUp with no evidence at all ... Now keyed on what the proxy actually
    observed」。兩段註解在同一區塊內互相矛盾。

- 建議：
  刪除第 718-722 行的過時 NOTE。第 725-729 行的註解已經充分說明現況。


---

## 中嚴重度發現

### M1. `stop()` 未 join `m_openflowTablesUpdateThread`（既有 bug，未隨改動修正）

- 位置：`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:135-151`
- 現象：
  `start()` 啟動了三條執行緒：
  ```cpp
  m_pingThread                    // line 129
  m_statusUpdateThread            // line 130
  m_openflowTablesUpdateThread    // line 131
  ```
  `stop()` 只 join 了前兩條：
  ```cpp
  if (m_pingThread.joinable()) { m_pingThread.join(); }           // line 143
  if (m_statusUpdateThread.joinable()) { m_statusUpdateThread.join(); } // line 148
  ```
  `m_openflowTablesUpdateThread` 從未被 join。這在 baseline 就已存在
  （`git show 28b8b13:src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`
  第 71-79 行完全相同的模式），但這次 144 個 commit 的改動沒有趁機修掉。

- 為什麼不合理：
  這屬於「治症狀不治病」的鏡像——**該修而未修**。`openflowTablesUpdateWorker`
  在 `m_running` 被設為 false 後會在下一次 sleep 醒來時退出（第 1798-1801 行
  的中斷式 sleep），但在它退出前 `stop()` 已經回傳，`DeviceConfigurationAndPowerManager`
  的 destructor 可能銷毀成員（如 `m_openflowTablesMutex`），而 worker 還在執行
  `fetchOpenFlowTablesInternal()`。這是 use-after-destroy 風險。

- 建議：
  補上 `if (m_openflowTablesUpdateThread.joinable()) { m_openflowTablesUpdateThread.join(); }`

### M2. `IPowerStrategy` 介面不一致：`powerOn` 有 `dpid` 參數，`powerOff` 沒有

- 位置：`include/ndt_core/power_management/IPowerStrategy.hpp:36-50`
- 現象：
  ```cpp
  virtual OpResult powerOn(Graph::vertex_descriptor node,
                           const std::string& swName,
                           uint64_t dpid,                    // ← 有 dpid
                           TopologyAndFlowMonitor* topoMonitor) = 0;

  virtual OpResult powerOff(Graph::vertex_descriptor node,
                            const std::string& swName,
                            // ← 沒有 dpid
                            TopologyAndFlowMonitor* topoMonitor) = 0;
  ```
  目前 `OVSPowerStrategy::powerOn` 確實需要 `dpid`（用來設定 bridge datapath-id），
  `powerOff` 不需要（只需刪除 bridge）。但 `P4PowerStrategy` 的 Phase 7
  （見 `P4PowerStrategy.cpp:17-18`）需要按 switch name/dpid 查 PID 來發信號，
  屆時 `powerOff` 也會需要 `dpid`。到那時要改介面就是 breaking change。

- 為什麼不合理：
  這是「新舊兩種寫法並存」的介面設計不一致。如果 `dpid` 對 power 操作是基本識別
  資訊（它確實是），那兩個方向都該有。`setPowerStateMininet` 呼叫端（`.cpp:1379-1403`）
  已經有 `dpid` 在手，只是沒傳給 `powerOff`。

- 建議：
  給 `powerOff` 補上 `uint64_t dpid` 參數。目前只有兩個實作，修改成本極低。

### M3. `FailureRun` 類別註解「only pingWorker's thread touches it」不準確

- 位置：`include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp:54`
- 現象：
  類別級註解寫著：
  > Not thread-safe: only pingWorker's thread touches it.
  
  但這個類別被實例化了**四次**（`.hpp:517,537,542,548`），其中：
  - `m_bridgeQueryFailures` — 確實只被 `pingWorker` 碰（無誤）
  - `m_switchStateFailures` — 只被 `fetchP4SwitchState()` 碰，而它只被 `pingWorker` 呼叫（無誤）
  - `m_flowStatsFetchFailures` — 被 `fetchOpenFlowTablesInternal()` 碰，
    而它執行在 `openflowTablesUpdateWorker` **不是** `pingWorker`
  - `m_flowStatsTimeouts` — 同上

  後兩個實例的註解「只被 pingWorker 碰」是錯的。

- 為什麼不合理：
  類別層級的 thread-safety 註解應該描述「這個型別本身的特性」（它是 data-race-free
  的前提），而不是只描述其中一個實例的使用方式。當有四個實例且兩個在不同執行緒時，
  這個註解會誤導讀者以為所有使用都是安全的（因為都在同一條 thread），而忽略
  `openflowTablesUpdateWorker` 也在碰其中兩個。好在目前這四個實例**各自**只被一條
  執行緒觸碰，所以實際上沒有 data race——但註解的理由是錯的。

- 建議：
  把類別註解改為「Not thread-safe: each instance must be confined to a single thread」，
  並在每個成員變數旁註明它屬於哪個 worker。

### M4. `fetchOpenFlowTablesInternal` 在迴圈內重複呼叫 `m_classifier->updateFromQueriedTables`（既有）

- 位置：`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:1150-1151`
- 現象：
  ```cpp
  for (auto v : ...) {
      // ... 對每個 switch 查 flow table ...
      result.push_back({{"dpid", dpid}, {"flows", flows}});
      // TODO: Test Classifier
      m_classifier->updateFromQueriedTables(result);  // ← 在迴圈內，result 逐次增長
  }
  ```
  如果 topology 有 10 個 switch，`updateFromQueriedTables` 會被呼叫 10 次：
  第一次帶 1 個 switch 的資料、第二次帶 2 個、…、第十次帶 10 個。
  這既是 CPU 浪費（同一筆資料被分類器重複處理），也可能造成分類器內部狀態
  在「不完整快照」上多次迭代。Baseline 就有此行為，新程式碼沒有修正。

- 為什麼不合理：
  雖然是既有問題，但這次改動重寫了 `fetchOpenFlowTablesInternal` 的大部分邏輯
  （加入逾時守衛、parse 失敗區分、edge-triggered logging），卻保留了這個
  有問題的呼叫位置。屬於「同樣的錯誤形狀在別處還有」的鏡像——改動者注意到了
  很多細節但沒注意到這個。

- 建議：
  把 `m_classifier->updateFromQueriedTables(result)` 移到 for 迴圈**之後**。

### M5. `describeCommandStatus` 的 wrapper 方法保留了不準確的命令名稱

- 位置：`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:570-581`
- 現象：
  ```cpp
  std::string
  DeviceConfigurationAndPowerManager::describeCommandStatus(int status)
  {
      return utils::describeCommandStatus(status, "sudo ovs-vsctl list-br");
  }
  ```
  註解說「the only caller is the `sudo ovs-vsctl list-br` liveness probe」，
  目前確實如此（只有 `reportBridgeQueryFailure` 在第 659 行呼叫它）。
  但 `OVSPowerStrategy` 中執行的也是 `sudo ovs-vsctl` 系列指令
  （`add-br`、`add-port`、`del-br`、`set-controller`），它們透過
  `utils::describeCommandStatus(rc, cmd)` 直接傳入真實命令字串。
  兩條路徑對同一類命令（ovs-vsctl）使用了**不同的命令名稱**：
  一條永遠回報 "sudo ovs-vsctl list-br"，另一條精確回報實際的命令。
  這在診斷時會造成混淆：某個 `add-br` 失敗的 log 可能看起來像是 `list-br` 失敗。

- 為什麼不合理：
  不一致性。Wrapper 存在的原因是「讓現有測試可以繼續用這個類別名稱」
  （見第 573-575 行註解），但這個理由現在已經很薄弱——`utils::describeCommandStatus`
  本身就可測試，wrapper 只多了一層 indirection 和一個硬寫的命令名。

- 建議：
  要麼刪除 wrapper，讓呼叫端直接使用 `utils::describeCommandStatus(status, cmd)`；
  要麼讓 wrapper 也接受命令字串參數。前者的 diff 更小。


---

## 低嚴重度發現

### L1. `FailureRun::recordFailure()` 使用 `unsigned` 計數器，理論上溢位後會誤報

- 位置：`include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp:62-65`
- 現象：
  ```cpp
  bool recordFailure() { return m_consecutive++ == 0; }
  ```
  `m_consecutive` 是 `unsigned`（32-bit）。如果連續失敗 2^32 次（約 136 年
  @1Hz），計數器溢位歸零，下一次 `recordFailure()` 會回傳 `true`（誤報為
  「新 run 的第一個失敗」）。同時 `recordSuccess()` 看到 `m_consecutive == 0`
  會回傳 `nullopt`，復原事件被靜默吞掉。

- 為什麼不合理：
  實際上不可能發生，但這是一個**可以用一行的型別變更消除的邊界條件**。
  `uint64_t` 或 `std::atomic<unsigned>`（如果未來要跨執行緒使用）就能讓
  溢位不可能在宇宙壽命內發生。

- 建議：
  改為 `uint64_t m_consecutive = 0;`。

### L2. `P4PowerStrategy::executeSystemCommand` 拋棄 `std::system` 回傳值，與 OVS 版不一致

- 位置：`src/ndt_core/power_management/P4PowerStrategy.cpp:9-12`
- 現象：
  ```cpp
  void P4PowerStrategy::executeSystemCommand(const std::string& cmd)
  {
      std::system(cmd.c_str());
  }
  ```
  `OVSPowerStrategy::executeSystemCommand` 會檢查 exit status 並記錄失敗；
  P4 版完全拋棄。雖然目前 P4 的 `powerOn`/`powerOff` 根本不會呼叫它（兩個
  方法都直接 `return OpResult::unsupported(...)`），但這個函式是 `protected virtual`，
  子類別或測試可能呼叫它並期待它跟 OVS 版有一致的行為。

- 為什麼不合理：
  同名函式、同介面、不同語意。這是典型的「不一致」——如果有人寫測試 mock 了
  `executeSystemCommand`，OVS 版會觸發 observable side effect（`m_lastCommandFailed`），
  P4 版是 no-op。

- 建議：
  讓 P4 版至少 log 一個 WARN，或讓它回傳 `bool` 反映成敗。不過 Phase 7
  實作完成後這個函式可能會被改寫，目前影響極低。

### L3. `pingWorker` 每次迭代都做 `getGraph()` 全圖複製，新程式碼未改善

- 位置：`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:622`
- 現象：
  ```cpp
  Graph graph = m_topologyAndFlowMonitor->getGraph();  // full deep copy every second
  ```
  這是 baseline 就行為，每秒一次的全圖複製。`getPowerStrategyForDpid` 的註解
  （`.cpp:62-63`）明確指出 `getGraph()` 是 "a full deep copy of the graph"，
  並以此為理由改用 O(1) 的 `getSwitchKind(dpid)`。但 `pingWorker` 本身仍然在
  複製。新程式碼還在同一個迴圈內新增了 `p4SwitchState` 的 fetch 和
  `p4LivenessFor` 的呼叫，雖然這些本身不重，但圖複製的成本沒有被處理。

- 為什麼不合理：
  屬於「同樣的錯誤形狀在別處還有」——改動者知道 `getGraph()` 很貴
  （甚至在註解裡寫了），但沒有對最頻繁的呼叫點（1 Hz）做任何改善。

- 建議：
  長期考慮讓 `pingWorker` 直接走 BGL 的 `vertices()` 迭代而不複製整個圖，
  或至少把 `getGraph()` 換成更低開銷的查詢方式。不過這需要改 `TopologyAndFlowMonitor`
  的介面，超出本次範圍。


---

## 註解宣稱查證表

以下抽樣查證了程式碼中「宣稱具體事實」的註解，驗證其是否與實際程式碼或資料一致。

| # | 註解位置 | 它宣稱什麼 | 查證結果 |
|---|---------|-----------|---------|
| 1 | `DeviceConfigurationAndPowerManager.hpp:46-47` | 「3596 lines of sudo errors in a single run」 | **無法驗證**。沒有對應的 log 檔案或 repro 腳本。但同檔案內 `FailureRun` 的設計確實是為了解決 log flood，方向合理。 |
| 2 | `DeviceConfigurationAndPowerManager.hpp:276-277` | 「Measured on the OVS testbed, 2026-08-07, 151 samples (`doc/audit/ryu-wedge-trace-2026-08-07.tsv`)」 | **部分不準確**。`git show HEAD:doc/audit/ryu-wedge-trace-2026-08-07.tsv` 顯示該檔案只有 ~132 行資料（含 header），不是 151 筆。 |
| 3 | `DeviceConfigurationAndPowerManager.hpp:279` | healthy 的 round trip 落在 `0.027 - 0.083 s` | **略有偏差**。TSV 資料中 35KB body 的 latency 範圍是 0.031–0.097 s，最小值 0.031 而非 0.027，最大值 0.097 而非 0.083。差異不大（都在同一數量級），但不精確。 |
| 4 | `DeviceConfigurationAndPowerManager.hpp:280` | wedged 的 round trip 落在 `1.009 - 1.013 s` | **大致正確**。TSV 中 9-byte body 的 latency 多數落在 1.009–1.014，有一個 outlier 在 1.814 和一個在 1.025。範圍描述大致符合主體資料。 |
| 5 | `DeviceConfigurationAndPowerManager.hpp:556-558` | 「`std::hash<uint64_t>{}(dpid) % 120000` returns the dpid, so all ten switches reported 30.0 W」 | **可合理推斷為真**。libstdc++ 的 `std::hash<uint64_t>` 確實是 identity function。dpid 通常是小整數（例如 1–10），`dpid % 120000` = dpid，加上 baseline 30,000 mW 後差異僅在個位數 mW。註解的解釋合理。 |
| 6 | `DeviceConfigurationAndPowerManager.cpp:579` | 「13 snmpget/snmpwalk sites that reach it through execCommand」 | **無法精確驗證，但數量級合理**。在 `DeviceConfigurationAndPowerManager.cpp` 中可數出 9 個 snmpget/snmpwalk 呼叫點（`fetchMemoryReportInternal` 2 個、`fetchPowerReportInternal` 1 個、`fetchCpuReportInternal` 2 個、`fetchTemperatureReportInternal` 1 個、`getSingleSwitchPowerReport` 1 個、`getSingleSwitchCpuReport` 2 個）。其他檔案可能有另外 4 個。宣稱的「13」可能來自某個歷史版本或包含其他檔案的站點。 |
| 7 | `DeviceConfigurationAndPowerManager.cpp:718-722` | 「NOTE: this remains a stub that assumes bmv2 switches are always up … Phase 6 … the proxy to expose that state, which it does not yet」 | **❌ 明確錯誤**。此註解正下方的程式碼（第 723–746 行）已實作 `p4LivenessFor()` 三態判定，這不是 stub。Phase 6 已完成。詳見 **H2**。 |
| 8 | `DeviceConfigurationAndPowerManager.hpp:54` | FailureRun 類別「Not thread-safe: only pingWorker's thread touches it」 | **❌ 不準確**。此類別有四個實例，其中兩個（`m_flowStatsFetchFailures`、`m_flowStatsTimeouts`）被 `openflowTablesUpdateWorker` 碰，不是 `pingWorker`。詳見 **M3**。 |
| 9 | `DeviceConfigurationAndPowerManager.cpp:60-63` | 「The previous version called getGraph() -- a full deep copy of the graph -- even though its only caller had already copied it six lines earlier」 | **可驗證為真**。對照 `git show 28b8b13:src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp` 第 757-770 行（baseline 的 `setPowerStateMininet`），在該函式中確實先呼叫了 `getGraph()`（第 766 行），然後內部的策略選擇邏輯（不存在於 baseline，是後來加入的）在舊版中沒有。不過 `getPowerStrategyForDpid` 是新函式，其註解描述的是它**取代**的舊邏輯（舊 `setPowerStateMininet` 內部又呼叫了一次 `getGraph()`）。baseline 的 `setPowerStateMininet` 只在第 766 行呼叫了一次 `getGraph()`，沒有「its only caller had already copied it six lines earlier」的情況——這個宣稱描述的是某個中間版本的狀態，不是 baseline。**宣稱的「six lines earlier」無法在 baseline 找到對應**。 |
| 10 | `IPowerStrategy.hpp:15-19` | 「The bool was decoration: both implementations returned true unconditionally … and the only caller discarded it and logged success regardless」 | **可驗證為真**。Baseline `setPowerStateMininet`（`git show 28b8b13:...` 第 802-807 行）無論 `action` 是什麼都 `return true`，且結尾永遠 `SPDLOG_INFO("MININET: switch {} -> {}", swName, action);`。 |


---

## 逐類檢查記錄

### 1. 改動與 commit message 宣稱的意圖不符
檢查了所有 12 個 commit 的 message 與其實際 diff：
- `6f32bca`（Add P4 switch support via routing/power strategy pattern）：實際 diff 包含了策略模式介面、OVS/P4 兩個實作、以及 `FailureRun` 和 `OvsLiveness` 等輔助型別。commit message 說「Add P4 switch support via routing/power strategy pattern」，但這個 commit 的 scope 極大（+1487/-134 行），把 liveness 三態、flow-stats timeout、RelayResult、FailureRun 全部包進一個 commit。這使得「回退 P4 支援」就必須同時回退 liveness 修復。詳見**可回退性**檢查。
- 其他 commit message 與 diff 比對後**大致相符**。沒有發現明顯的「夾帶無關改動」或「做的事與說的不同」。
- 較小的問題：`2979ec8`（Stop four INFO lines that nobody could read）只改了一行 log level（INFO→TRACE），不是四行。實際上是把 `fetchOpenFlowTablesInternal` 中對每個 switch 的 `SPDLOG_LOGGER_INFO` 改成 `SPDLOG_LOGGER_TRACE`，但 diff 只有一處。commit message 的「four」可能指的是原本有四個 INFO log site，但這個 commit 只修了其中一個？或是誇大了。

**結論：有一個 scope 過大的 commit（6f32bca），見第 9 類。其他大致相符。**

### 2. 註解宣稱的事實與程式碼不符
**重點檢查**。詳見上方「註解宣稱查證表」10 條抽樣。
- 發現 **2 條明確錯誤**（#7: bmv2 stub 宣稱、#8: FailureRun thread 宣稱）
- 發現 **2 條不精確**（#2: 151 vs ~132 samples、#3: latency range 略有偏差）
- 其他 6 條為真或無法驗證但方向合理。

**結論：有兩條註解明確說假話，嚴重度中至高。註解品質整體不錯但細節數字有鬆散。**

### 3. 治症狀不治病
- `parseFlowStatsTextToJson` 從回傳 `json::array()` 改成 `std::nullopt` 是正確的根因修復（之前空陣列被當作「交換機無規則」）。
- `classifyFlowStatsReply` 新增了 timeout 檢測，這是根因修復而非治標。
- `ovsLivenessFor` 三態（Up/Down/Unknown）取代了原本的「空列表=全部 down」，是根因修復。
- **發現一個「該修而未修」**：`stop()` 未 join `m_openflowTablesUpdateThread`（M1）。
- **發現一個「同模式別處還有」**：`fetchOpenFlowTablesInternal` 在迴圈內重複呼叫 `updateFromQueriedTables`（M4），改動者修了很多東西但沒修這個。

**結論：改動整體上偏向根因修復（這是好事）。但漏掉了兩處既有問題。**

### 4. 不一致
- `IPowerStrategy::powerOn` 有 `dpid` 參數，`powerOff` 沒有（M2）。
- `OVSPowerStrategy::executeSystemCommand` 檢查 exit status，`P4PowerStrategy::executeSystemCommand` 拋棄（L2）。
- `describeCommandStatus` wrapper 永遠回報 "sudo ovs-vsctl list-br"，但 OVS 策略內部用真實命令字串呼叫 `utils::describeCommandStatus`（M5）。
- `syntheticPowerMilliwattsFor` 刻意不用 `ip.front()`（註解有說明），但 `fetchCpuReportInternal`、`fetchMemoryReportInternal`、`fetchTemperatureReportInternal` 仍直接呼叫 `ip.front()` 無防護（既有）。
- `FailureRun` 有四個實例，其中兩個給 `openflowTablesUpdateWorker` 用、兩個給 `pingWorker` 用；但分離的理由（「不同 fault、不同 fix」）只對 flow-stats 的兩個成立，對 bridge 和 switch-state 的兩個也成立。分離策略一致，是好的。

**結論：有三處不一致需要收斂（M2、M5、L2）。**

### 5. 過度工程
- `FailureRun` 獨立成一個 class 而非 bare counter：**合理**。理由是「manager 無法在測試中建構，而這個行為值得單獨測試」。類別只有 15 行，不算過度。
- `IPowerStrategy` 策略模式：**合理**。OVS 和 P4 確實需要不同的 power 實作。介面只有 3 個方法，沒有過度抽象。
- `OpResult` 回傳型別 vs `bool`：**合理**。註解中詳細說明了 `bool` 的失敗模式（兩邊都無條件回傳 true，呼叫端拋棄回傳值並 log 成功）。
- `OvsLiveness` 三態 enum vs 布林：**合理**。這是整份改動的核心修正。
- `RelayResult` struct：**合理**。把 HTTP status 和 human-readable text 分開。
- 註解長度：部分註解非常長（例如 `p4LivenessFor` 的 30 行 doc、`classifyFlowStatsReply` 的 15 行），但它們在解釋**為什麼**某個 branch 是某個狀態，而非重述程式碼。這是好的註解。**唯一的例外是 H2 中的過時註解**。

**結論：沒有過度工程。新增的抽象都有對應的實際需求。**

### 6. 新引入的缺陷
- **H1**：`m_lastCommandFailed` 競爭條件 —— 新引入的可變共用狀態，無同步。
- `P4PowerStrategy::executeSystemCommand` 拋棄回傳值（L2）—— 不是 defect，因為目前沒人呼叫它，但為未來埋了不一致的陷阱。
- `FailureRun` 的 `unsigned` 溢位（L1）—— 極不可能，但理論上存在。
- 生命週期：`m_ovsPowerStrategy` 和 `m_p4PowerStrategy` 是 `unique_ptr`，在 `DeviceConfigurationAndPowerManager` 建構時分配、解構時自動釋放，無洩漏。
- 例外安全：`fetchP4SwitchState` 用 try/catch 包住 `utils::execCommand`，失敗回傳 `nullopt`。OK。
- 鎖的範圍：`statusUpdateWorker` 和 `openflowTablesUpdateWorker` 都在鎖外做 I/O、鎖內只做 `std::move`。OK。
- `pingWorker` 沒有鎖──它讀取 `m_dataPlaneIsBmv2`（plain bool），但該值只在 `start()` 中寫入一次（在執行緒啟動前），所以 safe。

**結論：新引入了一個競爭條件（H1），其他方面穩健。**

### 7. 效能退步
- `pingWorker` 每次迭代呼叫 `getGraph()`（全圖複製，既有）—— 未改善（L3）。
- `fetchP4SwitchState` 新增了每秒一次的 HTTP GET 到 proxy（`curl -s --max-time 3`），但只在 `m_dataPlaneIsBmv2` 為 true 時執行，且只做一次（不是 per-switch）。**設計合理，不算退步。**
- `fetchOpenFlowTablesInternal` 新增了 `std::chrono::steady_clock::now()` 兩次呼叫來計時（為了 `classifyFlowStatsReply`），開銷微不足道。
- `classifyFlowStatsReply` 對每個 switch 的 flow table reply 做 JSON 走訪，但只檢查「是否有任何非空 entry」—— O(n) 但 n 是 table 數量（通常個位數）。**可忽略。**
- `syntheticPowerMilliwattsFor` 用 splitmix64 finalizer 取代 `std::mt19937_64` + `uniform_int_distribution`。splitmix 是純整數運算，比 Mersenne Twister 快很多。**這是效能改善，不是退步。**
- `updateOpenFlowTables` 中 `getFlowsArrayForDpid` 從回傳 reference 改成回傳 pointer（為了支援 nullptr），增加了一次 nullptr check，開銷可忽略。

**結論：沒有新引入的效能退步。部分路徑有改善（syntheticPowerMilliwattsFor）。**

### 8. 半成品與死碼
- `P4PowerStrategy::powerOn` 和 `powerOff` 都是 stub，回傳 `OpResult::unsupported`。這是**明確標記的半成品**——程式碼註解指向 Phase 7 of `doc/p4_bmv2_support_plan.md`。合理。
- `P4PowerStrategy::executeSystemCommand` 存在但未被任何 production 程式碼呼叫。它是 `protected virtual`，為未來或測試預留。不算死碼，但接近（L2）。
- `TODO: Do it parallelly`（`.cpp:215`，`queryTestbed` 中）—— 既有 TODO，未處理。
- `TODO: Emit switch failed event`（`.cpp:699,768`）—— 既有 TODO。
- `TODO: Test Classifier`（`.cpp:1150`）—— 既有 TODO。
- `// TODO: change to exexCommand`（baseline 中存在，現已刪除）—— 已處理。
- `// TODO[DEBUG]: parseFlowStatsTextToJson may throw`（baseline 中存在，現已刪除）—— 已處理。
- 被註解掉的 `is_digits` 和 `parseIpv4WithMask` 函式（`.cpp:1175-1238`）—— 既有 dead code，未刪除但也沒新增。

**結論：P4 策略的 stub 狀態是誠實標記的半成品。既有 TODO 和 dead code 未被清理但也未被擴大。**

### 9. 可回退性
- **commit `6f32bca`**（「Add P4 switch support via routing/power strategy pattern」）把至少六件獨立的事綁在一起：
  1. `IPowerStrategy` / `OVSPowerStrategy` / `P4PowerStrategy` 策略模式
  2. `FailureRun` 邊緣觸發降噪
  3. `OvsLiveness` 三態
  4. `RelayResult` + `interpretRelayResponse`
  5. `classifyFlowStatsReply` + `FlowStatsVerdict`
  6. `syntheticPowerMilliwattsFor`
  7. `describeCommandStatus`
  8. `p4LivenessFor` + `fetchP4SwitchState`
  
  這個 commit 的 diff 約 1500 行。如果要回退其中任何一件事（例如 `FailureRun` 有 bug），就必須回退整個 commit，包含不相關的 P4 支援和 liveness 修復。**這是本次 review 範圍內可回退性最差的 commit。**

- 其他 commit 的粒度較細（例如 `3367fa7` 只修 parse 失敗時不應 wipe flow table），各自獨立。

**結論：`6f32bca` 的 scope 過大，違反「一 commit 一事」原則。**


---

## 無法判定

1. **「3596 lines of sudo errors」**：`FailureRun` 類別註解（`.hpp:46`）宣稱某次執行中產生了 3596 行 sudo 錯誤。沒有對應的 log 檔或 repro 步驟，無法驗證此數字。但 `FailureRun` 的設計動機（防止 log flood）是合理的，不以數字精確度為前提。

2. **「13 snmpget/snmpwalk sites」**：`.cpp:579` 的註解宣稱有 13 個 SNMP 呼叫點。在本檔案內可數出 9 個；其餘 4 個可能在其他翻譯單元。沒有進行全 repository 的詳盡統計，無法確認「13」是否精確。

3. **`getPowerStrategyForDpid` 註解宣稱的「its only caller had already copied it six lines earlier」**：這個宣稱描述的是某個中間重構版本的狀態，不是 baseline `28b8b13`。在 baseline 的 `setPowerStateMininet` 中只呼叫了一次 `getGraph()`。無法確定「six lines earlier」指的是哪個版本、哪個 caller。

4. **`m_lastCommandFailed` 競爭條件的實際觸發機率**：無法在不執行並行壓力測試的情況下判定兩個 HTTP 請求同時做 OVS power on/off 的機率。但程式碼結構（共用 `unique_ptr<IPowerStrategy>` 單例）使競爭**可能**發生。

5. **`kFlowStatsSuspectSeconds = 0.5` 的閾值選擇**：註解說這是「six times above the worst healthy sample and half of Ryu's own timeout」。從 trace 資料看，worst healthy 是 0.097 s，6× = 0.582 s；Ryu timeout 是 1.0 s，一半是 0.5 s。0.5 的選擇略低於 6× worst healthy，但仍在合理範圍。無法在不重現 wedged 場景的情況下判定 0.5 是否最優。

