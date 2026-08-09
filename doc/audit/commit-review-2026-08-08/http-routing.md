# `src/ndt_core/http/` + `include/ndt_core/http/` + `src/ndt_core/routing_management/` + `include/ndt_core/routing_management/` commit review

## 摘要（先講結論：找到幾條、最嚴重的是什麼）

共找到 **7 條**值得報告的發現：**高 0 條**、**中 5 條**、**低 2 條**。

最嚴重的問題是**中嚴重度**的：
1. `handleGetNickname` 的 MAC 查詢路徑仍使用拋異常版 `macToUint64`，與其他兩個已修復的 handler 不一致（M1）。
2. `handleGetNickname` 的 DPID 解析路徑在改用 `tryParseUint64` 後留下一段已死碼的 `catch` 區塊（M2）。
3. `get_param` lambda 在五個 handler 裡逐字重複，共約 125 行重複程式碼（M3）。
4. `respondToOpResult` 的註解說「otherwise the controller's own status」但遺漏了 200-with-error-body → 502 的對映路徑（M5）。
5. `FlowRoutingManager` 解構子註解說「the three dispatch methods below」但未指明是哪三個，且 group/meter 方法並非 virtual，形成設計不一致（M4）。

沒有發現高嚴重度的正確性／安全／資料遺失問題。本範圍的改動整體品質良好：狀態碼修正、輸入驗證強化、生命週期修復、失敗回報鏈都有實質改善。


## 中嚴重度發現

### M1. `handleGetNickname` MAC 查詢仍用拋異常版 `macToUint64`，與其他兩處不一致
- 位置：`src/ndt_core/http/HttpSession.cpp:1461`
- 現象：
  ```cpp
  uint64_t mac = utils::macToUint64(macStr);
  ```
  `handleModifyDeviceName`（line 1130）和 `handleModifyNickname`（line 1527）已改用不回拋異常的 `utils::tryMacToUint64`，直接回傳 400 並附上具體錯誤訊息（`"expected xx:xx:xx:xx:xx:xx"`）。`handleGetNickname` 仍用拋異常版本，靠外層 `catch (const std::exception& e)` 回 400，錯誤訊息較籠統。
- 為什麼不合理：commit `9d46302`（"Refuse a malformed MAC instead of returning a wrong one"）的 message 說 "The third site, get_nickname, already had its own try/catch answering 400." 所以這是**刻意的保留**而非遺漏。但：
  1. 錯誤訊息不一致：`handleModifyDeviceName` 和 `handleModifyNickname` 給出 `"expected xx:xx:xx:xx:xx:xx"`，`handleGetNickname` 只給 `e.what()`。
  2. 用異常做控制流正是這系列 commit 要消除的模式（見 `buildResponse()` 的註解：「std::stoull threw … which lands in the std::exception catch rather than the json::exception one」）。此處把同一個模式保留在 MAC 路徑，是**治症狀不治病**——DPID 改了但 MAC 沒改。
  3. `handleGetNickname` 的 DPID 路徑（line 1433）已經改用 `tryParseUint64`，同一函式內新舊兩種風格並存，不一致。
- 證據：`git show 9d46302` 的 diff 顯示只改了 `handleModifyDeviceName` 和 `handleModifyNickname` 兩處 MAC 處理。`handleGetNickname` 的 MAC 路徑未被觸及。
- 建議：將 line 1457-1470 改為 `tryMacToUint64` + explicit check，與其他兩處一致，並移除外層已無必要的 `catch (const std::exception&)`。

### M2. `handleGetNickname` DPID 解析改用 `tryParseUint64` 後留下死碼 catch 區塊
- 位置：`src/ndt_core/http/HttpSession.cpp:1450-1455`
- 現象：
  ```cpp
  const auto dpidOpt = utils::tryParseUint64(dpidStr);
  if (!dpidOpt)
  {
      // ... return 400
  }
  const uint64_t dpid = *dpidOpt;
  vertexOpt = m_topologyAndFlowMonitor->findSwitchByDpid(dpid);
  // ...
  catch (const std::exception& e)   // <-- line 1450, dead code
  {
      res.result(http::status::bad_request);
      res.body() = json{{"error", "Invalid DPID format"}, {"details", e.what()}}.dump();
      return;
  }
  ```
  `tryParseUint64` 不回拋異常。`findSwitchByDpid` 只是 hash 查表，也不拋。這個 `catch` 區塊在 DPID 路徑上已不可能被觸發。
- 為什麼不合理：程式碼給人一個「這裡還會失敗」的錯覺。註解（line 1429-1432）專注解釋 log 訊息被修正（從 `"inform_switch_entered"` 改成 `"get_nickname"`），但未提及這個 catch 區塊現在是死碼。這是**改一半**的殘留物。
- 證據：`utils::tryParseUint64` 宣告在 `include/utils/Utils.hpp`，其語意就是不拋異常（回傳 `std::optional<uint64_t>`）。`TopologyAndFlowMonitor::findSwitchByDpid` 也不拋異常。
- 建議：移除 DPID 路徑上已無作用的 try-catch，或至少加註解說明它現在只保護 MAC 路徑（但 MAC 路徑有自己的 try-catch，見 M1）。

### M3. `get_param` lambda 在五個 handler 內逐字重複
- 位置：
  - `handleGetDetectedTopKFlowData`（line 546-573）
  - `handleSetSwitchesPowerState`（line 641-668）
  - `handleGetNickname`（line 1353-1400）
  - `handleGetPathSwitchCount`（line 1597-1625）
  - `handleSetHistoricalLoggingState`（line 1742-1770）
- 現象：同一個 ~25 行 query string 解析 lambda 被 copy-paste 五次，邏輯完全相同，僅註解詳略不同。
- 為什麼不合理：這系列 commit 做了大量重構（抽出 `buildResponse`、`respondToOpResult`、`HttpRoutingStrategyBase`），顯示開發者對 DRY 有意識。但這個最顯眼的重複卻被放過。如果 query string 解析有 bug（例如 edge case 處理不正確），需要在五處獨立修復。
- 證據：`grep -n "auto get_param = \[\]" src/ndt_core/http/HttpSession.cpp` 可得五個位置，每個的迴圈邏輯一模一樣。
- 建議：抽出為 private static 輔助函式（例如 `HttpSession::parseQueryParam`）。

### M4. `FlowRoutingManager` 解構子註解模糊，且 virtual 方法集合不一致
- 位置：`include/ndt_core/routing_management/FlowRoutingManager.hpp:57-59`
- 現象：
  ```cpp
  /// [Co-developed with claude code -- Adam] Virtual so the three dispatch methods below can be
  /// overridden in a test, which requires deletion through a base pointer to be well-defined.
  virtual ~FlowRoutingManager();
  ```
  「the three dispatch methods below」未指名是哪三個。實際上是 `deleteAnEntry`、`installAnEntry`、`modifyAnEntry`（三者皆 virtual）。但 `installAGroupEntry` 等六個 group/meter 方法也是 "dispatch methods"，卻不是 virtual。如果未來有人需要為 group/meter 寫類似 `ScriptedManager` 的測試替身，會發現無法覆寫。
- 為什麼不合理：這是**設計不一致**——同一類別裡，flow entry 操作可被測試替換，group/meter 操作不行。目前 test_Controller.cpp 的 `ScriptedManager` 只覆寫 flow entry 方法所以沒觸發問題，但設計意圖未在註解中說清楚。
- 證據：`test_Controller.cpp:58-91` 的 `ScriptedManager` 只 `override` 了三個 flow entry 方法。
- 建議：註解改為「…so the three *flow-entry* dispatch methods (deleteAnEntry, installAnEntry, modifyAnEntry) can be overridden…」，並考慮是否要讓 group/meter 方法也 virtual（或明確說明為什麼不需要）。

### M5. `respondToOpResult` 註解對 200-with-error-body 的對映描述不完整
- 位置：`include/ndt_core/http/HttpSession.hpp:288-298`
- 現象：註解說：
  > "501 when the data plane cannot express the operation, 502 when the controller failed or never answered, otherwise the controller's own status."
  
  但當 P4 proxy 回 HTTP 200 且 body 為 `{"status":"error"}` 時，`HttpRoutingStrategyBase::post()` 產生 `OpResult::failure(200, msg)`。`respondToOpResult` 的邏輯是 `httpStatus == 501` → 501、`noResponse()` → 502、`400-599` → pass through、**其餘 → 502**。因為 `httpStatus=200` 不滿足前三個條件，最終對映為 **502 Bad Gateway**，而非「the controller's own status」（200）。
- 為什麼不合理：這個對映行為本身是正確的——proxy 回 200 但內容是 error，kernel 轉回 502 是合理的。但註解沒提到這條路徑，讀者會誤以為 200 會被原樣傳遞。
- 證據：`HttpRoutingStrategyBase.cpp:118-136` 檢測 `{"status":"error"}` 並回傳 `OpResult::failure(status, ...)`；`HttpSession.cpp:764` 的 `else if (result.httpStatus >= 400 ...)` 不會匹配 200，落入 `else → bad_gateway`。
- 建議：在註解中加入「a proxy that answers 200 with an error body also becomes 502」。


## 低嚴重度發現

### L1. 三個 handler 的 log 訊息有英文拼字錯誤（pre-existing，未在本次修正）
- 位置：
  - `src/ndt_core/http/HttpSession.cpp:605` — `"Handle Get Swithc OpenFlow Entries"`（Swithc → Switch）
  - `src/ndt_core/http/HttpSession.cpp:1168` — `"Handle Recieved Simulation Case"`（Recieved → Received）
  - `src/ndt_core/http/HttpSession.cpp:1235` — `"Handle Infrom All Desination Pahts"`（多處錯誤）
- 現象：baseline 就有這些 typo，本次範圍內的 commit 沒有修正它們。`handleGetNickname` 的 log 訊息被修正過（從 `"inform_switch_entered"` 改為 `"get_nickname"`），表示開發者**有能力注意到並修正** log 訊息文字，但這三處被放過。
- 為什麼不合理：雖然不影響功能，但表明 log 訊息沒有被系統性地檢查過。`handleInformAllDestinationPaths` 的訊息尤其嚴重：三個單字錯了兩個（"Infrom" → "Inform", "Desination" → "Destination", "Pahts" → "Paths"），這會讓 grep log 的人找不到對應訊息。
- 建議：修正拼字。

### L2. `after_write_` 成員變數是 dead code（pre-existing）
- 位置：`include/ndt_core/http/HttpSession.hpp:682`（宣告）、`src/ndt_core/http/HttpSession.cpp:374-375`（使用）
- 現象：`after_write_` 是 `std::function<void()>` 型別，在 `onWrite()` 中被 move 後執行。但整個 codebase 中沒有任何程式碼設定它。這是 pre-existing 的 dead code。
- 為什麼不合理：雖然是 baseline 就有的，但在這次重構中（`handleRequest` 被拆成 `buildResponse` + `writeResponse`）沒有順手清理。
- 建議：若確定未來不會用到就移除；若預留給未來功能則加註解說明。


## 註解宣稱查證表

| # | 註解位置 | 它宣稱什麼 | 查證結果 |
|---|---------|-----------|---------|
| 1 | `OpResult.hpp:11-14` | "curl ran with -s and no --fail, its return value was discarded, executeCommand returned void" | **屬實。** `git show 28b8b13:src/ndt_core/routing_management/FlowRoutingManager.cpp` 第 34 行：`utils::execCommand(cmd.str());` 沒有接收回傳值。curl 命令使用 `-s` 但無 `--fail` 也無 `-w`。 |
| 2 | `HttpSession.cpp:108-114` (buildResponse 上方) | "`?dpid=abc` and a non-numeric 'app_id' were both answering 500 because std::stoull/std::stoi throw std::invalid_argument, which lands in the std::exception catch rather than the json::exception one" | **屬實。** `git show 28b8b13:src/ndt_core/http/HttpSession.cpp` 中 `handleInformSwitchEntered` 使用 `std::stoull(dpidStr)`（無 try-catch），`handleSimulationCompleted` 使用 `std::stoi(...)`。`std::invalid_argument` 繼承自 `std::exception`，會被最外層 `catch (const std::exception&)` 捕獲並回 500。 |
| 3 | `FlowRoutingManager.cpp:47-56` (getStrategyForDpid 上方) | "Was: findSwitchByDpid() (O(V) scan under the graph lock) followed by getGraph(), which deep-copies the entire BGL graph … once per flow entry … a 2000-entry burst meant 2000 full graph copies" | **屬實。** `git show 6f32bca -- src/ndt_core/routing_management/FlowRoutingManager.cpp` 顯示當時的 `getStrategyForDpid` 確實在每筆 flow entry 都呼叫 `findSwitchByDpid()` + `getGraph()`（回傳 graph 拷貝）+ 再拷貝 `VertexProperties`。 |
| 4 | `FlowRoutingManager.cpp:138-143` | "These used to go to m_ovsStrategy unconditionally, with a comment claiming that 'global commands that don't specify DPID go to OVS by default'. The comment was wrong: Ryu's /stats/groupentry and /stats/meterentry schemas both require a dpid" | **屬實。** `git show 6f32bca -- src/ndt_core/routing_management/FlowRoutingManager.cpp` 顯示 group/meter 方法全都無條件轉發給 `m_ovsStrategy`，註解寫著 "Global/group commands that don't specify DPID go to OVS by default for now"。Ryu 的文件確認 groupentry/meterentry API 需要 dpid。 |
| 5 | `HttpSession.cpp:1018-1022` (processFlowBatch 尾端) | "Kept as HTTP 200 rather than 202 Accepted: 202 would be more accurate, but callers that check for exactly 200 would break" | **無法從程式碼判定。** 要確認外部呼叫者是否真的只檢查 200 需要 grepping 整個生態系（含外部應用、NTG、GUI）。此宣稱是向後相容性的工程判斷，程式碼本身無法證實或證偽。 |
| 6 | `HttpSession.cpp:1429-1432` (handleGetNickname) | "The message names *this* endpoint. It was copy-pasted from handleInformSwitchEntered with the text unedited, so a bad `?dpid=` on /ndt/get_nickname logged 'inform_switch_entered: ...' and sent the reader to the wrong handler. Checked the other forty-odd handlers for the same slip; this was the only one." | **屬實。** 比對 `handleInformSwitchEntered`（line 1083）和 `handleGetNickname`（line 1436）的 WARN log 訊息，前者是 `"inform_switch_entered: dpid '{}'..."`，後者已修正為 `"get_nickname: dpid '{}'..."`。grep 其他 handler 的 WARN log 訊息，每個 endpoint 的名稱都與自身相符，沒有再發現錯植。 |
| 7 | `IRoutingStrategy.hpp:19-23` | "The json parameters were taken by value, copying every match and action object once more per entry on a path that batches 2000 at a time" | **屬實。** `git show 28b8b13:include/ndt_core/routing_management/FlowRoutingManager.hpp` 中 `deleteAnEntry(uint64_t dpid, json match, int priority)` 的 `match` 參數是 by-value。現已改為 `const json&`。 |
| 8 | `HttpSession.hpp:75-78` (HttpSessionTestPeer friend 上方) | "tests/test_HttpSessionRouting.cpp constructs a session over an unconnected socket, sets m_req and calls buildResponse(), which does no I/O" | **屬實。** `tests/test_HttpSessionRouting.cpp:79` 確實呼叫 `m_session->buildResponse()`，且測試用 `HttpSessionTestPeer` 直接設定 `m_req`，不走 socket I/O。`buildResponse()` 函式體內沒有任何 socket 操作。 |
| 9 | `HttpRoutingStrategyBase.hpp:15-16` | "OpenFlowRoutingStrategy and P4RoutingStrategy were byte-for-byte identical apart from their class names" | **屬實（在基類抽出之前）。** `git show 6f32bca -- src/ndt_core/routing_management/` 可看到兩個類別的實作確實完全一樣，只差在 class name 與 `describe()` 回傳字串。現已合併至 `HttpRoutingStrategyBase`，兩個子類只剩建構子與 `describe()`。 |
| 10 | `Controller.cpp:13-21` (sender lambda 內) | "Every one of these returns an OpResult and every one of them used to be discarded here, which quietly undid Phase 2" | **屬實。** `git show 8c25dbc~1:src/ndt_core/routing_management/Controller.cpp`（8c25dbc 之前的版本）顯示 sender lambda 呼叫 `m_flowRoutingManager->installAnEntry(...)` 等但沒有接收回傳值。現在的版本（line 27-63）有接收並檢查 `result.ok`。 |


## 逐類檢查記錄

### 1. 改動與 commit message 宣稱的意圖不符
**檢查了全部 12 個 commit 的 message 與對應 diff。**

- `6f32bca`（Add P4 switch support）：確實新增了 IRoutingStrategy、OpenFlowRoutingStrategy、P4RoutingStrategy、HttpRoutingStrategyBase，與宣稱一致。
- `9910151`（Phase 1: replace stringly-typed switch dispatch with typed SwitchKind）：確實用 `SwitchKind` enum + `getSwitchKind()` 取代了 `brandName == "BMv2"` 字串比對。commit 也引入了 `FlowRoutingManager` 的 group/meter 方法從固定 OVS 改為依 payload dpid 分派——這部分在 message 中未提及，但屬於同一個 dispatch 重構主題，不算夾帶。
- `7856efc`（Phase 2 part 1: make southbound failures visible）：確實引入了 `OpResult` 型別與回傳值，將 `void` 改為 `OpResult`。
- `08746f4`（Phase 2 part 2: honest flow responses, power results, and P4 proxy returns）：確實將 group/meter handler 從丟棄結果改為呼叫 `respondToOpResult`。
- `8c25dbc`（Connect the OpResult chain）：確實在 `processFlowBatch` 加入 dpid 驗證，以及在 Controller sender 中記錄失敗。
- `d5f5bfa`（Fix three lifecycle faults in FlowDispatcher）：確實修正了三個生命週期問題，message 描述的與 diff 完全吻合。
- `ba97ab3`（Test Controller's sender）：確實新增了 `test_Controller.cpp`。
- `832d75c`（Answer 400 for a malformed query parameter instead of 500）：確實將 `handleGetPathSwitchCount` 的 IP 解析從拋異常改為回 400。
- `05353d5`（Answer 400 for a malformed simulation case instead of 202 Accepted）：確實在 `handleReceivedSimulationCase` 加入請求驗證。
- `1404183`（Make handleGetNickname name itself in its own warning）：確實修正了 log 訊息中的端點名稱。
- `71e6414`（Make HttpSession's status codes observable, and kill two of my own fake tests）：確實抽出 `buildResponse`、引入 `HttpSessionTestPeer`、移除無效測試。
- `9d46302`（Refuse a malformed MAC instead of returning a wrong one）：確實修正了 `macToUint64` 的驗證缺陷，並在兩個 HTTP handler 改用 `tryMacToUint64`。
- `78b822a`（Log client errors as warnings）：確實將三處 ERROR 改為 WARN。

**結論：沒有發現 commit message 與實際改動不符的情況。** 每個 commit 做的事與其宣稱一致，沒有夾帶無關改動。唯一可議的是 M1 所指出的——`9d46302` 沒有修 `handleGetNickname` 的 MAC 路徑，但 message 已說明理由（「already had its own try/catch」），屬於設計選擇而非欺瞞。

### 2. 註解宣稱的事實與程式碼不符
**重點檢查，已在上方「註解宣稱查證表」查了 10 條。**

- 10 條中 9 條屬實，1 條無法從程式碼判定（關於外部呼叫者對 HTTP 200 的依賴）。
- 沒有發現註解**說謊**的情況（即註解宣稱的事實與程式碼相反）。
- M5 屬於註解**不完整**（未描述 200-with-error → 502 的對映），但不構成事實錯誤。

**結論：註解品質良好，沒有發現故意或疏忽的事實錯誤。** 註解過長的問題（如 `handleGetNickname` 的 `get_param` lambda 內部有 7 步驟註解）屬於風格偏好，不構成「不合理」。

### 3. 治症狀不治病
**檢查模式：grep 相同錯誤模式的其他出現位置。**

- M1（`macToUint64` 仍用拋異常版）是本類別最接近的案例：DPID 和 IP 的解析都已經統一改用 non-throwing 版本，但 MAC 解析在 `handleGetNickname` 中仍用舊模式。雖有 try-catch 保護所以不會回 500，但保留了「用異常做控制流」的模式。
- 另外，`handleInformAllDestinationPaths:1263` 仍有 `std::stoi(nodeJson[1].get<std::string>())`，可能拋異常。但此 handler 不在本次修改範圍內，且資料來自 Ryu 而非外部客戶端。

**結論：有一個殘留的舊模式（M1），整體來說清理工作做得相當徹底。**

### 4. 不一致
**檢查了：命名風格、錯誤處理模式、log 等級、virtual 方法、參數型別。**

- M1（MAC 處理新舊風格並存於同一函式）
- M3（`get_param` lambda 重複五次）
- M4（virtual 方法集合不一致）
- 另外注意到：`handleGetSwitchesPowerState`（line 632）和 `handleGetPathSwitchCount`（line 1652）回 400 時用 `SPDLOG_LOGGER_WARN`，但 `handleSetHistoricalLoggingState`（line 1774-1778）回 400 時**沒有** log。這是不一致，但太輕微不值得單獨列一條。
- `buildResponse()` 內的 json::exception catch 從 ERROR 改為 WARN（line 329），與 `handleInputTextIntent`（line 1337）和 `processFlowBatch`（line 954）的 WARN 保持一致。**改動方向正確。**

**結論：有幾處不一致（M1, M3, M4），但核心的 HTTP 狀態碼對映和 log 等級策略大體一致。**

### 5. 過度工程
**檢查了：`OpResult` 型別、策略模式層次、`HttpRoutingStrategyBase` 抽取、`HttpSessionTestPeer` friend、`buildResponse` 抽出、`dispatchByPayloadDpid` 的函式指標型別。**

- `OpResult`：需求明確——原先南向失敗無法被觀測。型別設計簡潔，四個 factory method + `operator bool`，沒有過度。
- `IRoutingStrategy` / `HttpRoutingStrategyBase` / 兩個子類：層次合理。`HttpRoutingStrategyBase` 解決了兩個子類逐字重複的問題（commit message 有 `diff` 佐證）。沒有過度抽象。
- `HttpSessionTestPeer`：這是測試接縫，沒有扭曲生產程式碼設計（只是 friend 一個 class）。`buildResponse()` 的抽出本身是合理的重構——把純請求→回應邏輯與 I/O 分離。
- `dispatchByPayloadDpid` 使用 `StrategyCall` 函式指標型別：六個 group/meter 方法的 lambda 完全相同形狀，用這個型別消除重複。沒有過度。
- `FlowRoutingManager` 的 protected accessor（`ovsStrategy()`, `p4Strategy()`）：僅供測試使用，沒有暴露給生產程式碼。

**結論：沒有過度工程。** 新增的抽象都有對應的實際需求（消除重複、啟用測試、讓失敗可被觀測）。

### 6. 新引入的缺陷
**檢查了：鎖的範圍、生命週期、資源釋放、例外安全、邊界條件。**

- `FlowDispatcher::stop()`（`src/ndt_core/routing_management/FlowDispatcher.cpp:31-43`）：修正正確。三個生命週期問題（無鎖迭代、lost wakeup、stop 後 spawn）都被妥善處理。`cv_.notify_all()` 在鎖外呼叫是安全的（因為 predicate 變數 `running_` 已在鎖內寫入）。workers 被移出後在鎖外 join 避免死鎖。**此修正沒有引入新缺陷。**
- `Controller::~Controller()` 呼叫 `dispatcher_.stop()`，後者 join 所有 workers。Controller 透過 `shared_ptr` 持有，不會在 worker 執行期間被釋放。**生命週期正確。**
- `HttpRoutingStrategyBase::post()` 的 shell injection 風險：這是 pre-existing，重構將它集中到一處（降低了未來的修復成本），但**沒有修正它**。若 `json::dump()` 產出的字串包含單引號，shell 命令會斷裂。這是已知的遺留問題（程式碼註解有提及 "tracked as a separate hardening task"），不是新引入的。
- `respondToOpResult` 的狀態碼映射：逐一檢查各種 `OpResult` 組合（success/200, failure/404, failure/500, unreachable/0, unsupported/501, failure/200-with-error），映射邏輯正確。
- `processFlowBatch` 的 dpid 驗證：在 `m_topologyAndFlowMonitor` 為 null 時會 crash。但此 shared_ptr 由建構子傳入，在整個生命週期內不會變空。baseline 已有相同的 null 容忍問題（許多 handler 直接 dereference `m_topologyAndFlowMonitor` 等成員），不是本次引入。

**結論：沒有發現新引入的邏輯錯誤或生命週期缺陷。** FlowDispatcher 的修正反而**修復**了三個嚴重的生命週期 bug。

### 7. 效能退步
**檢查了：迴圈內的昂貴操作、不必要的複製、鎖內 I/O。**

- `getStrategyForDpid` 從 O(V) + graph deep copy 改為 O(1) hash lookup（`getSwitchKind`）。**這是效能改進，不是退步。**
- `IRoutingStrategy` 的參數從 by-value (`json match`) 改為 `const json&`，消除了不必要的複製。**改進。**
- `processFlowBatch` 新增的 dpid 驗證迴圈（line 974-979）：對每個 job 呼叫 `getSwitchKind`（hash lookup），O(n) 且 n 最多 2000，常數很小。不影響 burst 路徑的整體吞吐量。
- `respondToOpResult` 是 O(1) 的 if-else 鏈，無效能顧慮。
- `buildResponse()` 的回傳型別是 `shared_ptr<http::response<...>>`：baseline 也是在 heap 上建 response（`std::make_shared`），沒有改變。

**結論：沒有效能退步。** 反而有兩處明確的效能改進（O(1) dispatch、const& 參數）。

### 8. 半成品與死碼
**檢查了：未使用的函式/型別、`TODO`、只完成一半的功能。**

- `after_write_`：pre-existing dead code（見 L2）。本次未清理。
- 搜尋 `TODO`：找到兩處——
  - `handleGetSwitchesPowerState:620`：`// TODO[OPTIMIZATION] remove try catch part after modifying error handling`（pre-existing）
  - `handleGetTotalInputTrafficLoadPassingASwitch:1824`：`// TODO: Debug`（pre-existing）
  - `processFlowBatch:1005`：`// TODO: Immediately update the table`（pre-existing）
  全部是 pre-existing，本次未新增 TODO。
- `ovsStrategy()` / `p4Strategy()` accessor：用於測試（`test_SwitchKindDispatch.cpp:420,429,439,452,463,464`），不是 dead code。
- `HttpSessionTestPeer`：用於測試，不是 dead code。
- `dispatchByPayloadDpid`：被六個 group/meter 方法呼叫，不是 dead code。
- `OpResult` 的 `noResponse()`、`operator bool()`：都被使用（`respondToOpResult` 用 `result.ok` 和 `result.noResponse()`）。

**結論：本次沒有引入半成品或 dead code。** 所有新增的型別、函式、方法都有實際的呼叫點（含測試）。

### 9. 可回退性
**檢查了：每個 commit 的 diff 內容，判斷是否有兩件無關的事綁在一起。**

- `6f32bca`（Add P4 switch support）：範圍大但主題單一——引入策略模式支援 P4。無法部分回退。
- `9910151`（Phase 1: replace stringly-typed switch dispatch）：把字串比對改為 enum dispatch，同時把 group/meter 從固定 OVS 改為依 dpid 分派。這兩件事相關（都是 dispatch 機制），回退其中一件會導致 P4 group/meter 支援失效。不算無關綁定。
- `8c25dbc`（Connect the OpResult chain）：同時做了 processFlowBatch 的 dpid 驗證和 Controller sender 的結果記錄。兩件事都是把 OpResult 鏈接起來的必要環節，不算無關。
- `78b822a`（Log client errors as warnings, enable counter samples, and record what integration testing found）：這個 commit 同時改了 log 等級、testbed_topo.py 的 sFlow polling 設定、以及新增 HANDOFF.md。三件事確實**不相關**。如果要回退 log 等級修改，就必須一起回退 sFlow 設定變更。但這三件事都在 `src/ndt_core/http/` 和 `src/ndt_core/routing_management/` 的範圍**之外**（testbed_topo.py 和 doc/HANDOFF.md），所以對本次 review 範圍而言不構成可回退性問題。HttpSession.cpp 的修改（三處 ERROR→WARN）是單一主題。
- 其他 commit 的主題都足夠聚焦。

**結論：在本次 review 範圍內，沒有發現兩件無關的事被綁在同一個 commit。** `78b822a` 跨了三個不相關的檔案，但 HTTP 部分的修改（ERROR→WARN）本身是單一主題。


## 無法判定

1. **HTTP 200 vs 202 的向後相容性宣稱**（`HttpSession.cpp:1020-1022`）：「callers that check for exactly 200 would break」。無法從本倉庫程式碼驗證此宣稱——需要 grepping 所有呼叫 `/ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries` 的外部應用程式（NTG、GUI 等）。本倉庫內沒有這些消費者。

2. **`handleGetOpenflowCapacity` 不回應錯誤**（`HttpSession.cpp:1717-1734`）：當 `OpenflowCapacity.json` 無法開啟時，函式只 log ERROR 後 `return`，response 停留在預設的 200 OK + 空 body。這顯然是 bug，但是 pre-existing（baseline 就有），不在本次修改範圍。無法判定是否應該被本次修改順手修復。

3. **`curl` 的 shell injection 風險**（`HttpRoutingStrategyBase.cpp:82-84`）：已知問題，註解標記為 "tracked as a separate hardening task"。無法判定這個風險在實際 deployment 中是否可被觸發——取決於 JSON body 中是否可能出現單引號字元。在正常 OpenFlow 流程中（dpid、priority、match fields、actions）不太可能出現單引號，但不能完全排除（例如 description 欄位）。

4. **P4 proxy 的 200-with-error-body 回應頻率**：`HttpRoutingStrategyBase::post()` 檢查 `{"status":"error"}` 模式（line 122-125）。無法判定 P4 proxy agent 在什麼情況下會回此格式，以及這個檢查是否涵蓋所有 proxy 錯誤回應格式。需要審查 P4 proxy 的程式碼（不在本倉庫內）。

