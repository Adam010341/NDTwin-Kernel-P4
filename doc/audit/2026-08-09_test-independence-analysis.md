# 「球員兼裁判」風險與對策評估報告

**專案**：NDTwin-Kernel  
**Baseline**：`28b8b13`  
**評估範圍**：`28b8b13..HEAD`（144 commits, 192 files, +39831 行）

---

## 第 1 節：這個擔憂本身成立嗎？成立到什麼程度？

### 1.1 擔憂的具體內容

Adam 的擔憂是：同一個 AI（Claude）既寫程式碼又寫測試，會產生「共享盲點」——模型不知道某個行為是錯的，所以測試也會把錯的行為當成正確的來斷言。這不是抽象的哲學問題；這個專案有具體的證據。

### 1.2 共享盲點的具體機制

從這個專案的程式碼與測試的實際內容，可以歸納出四種共享盲點的具體機制：

**盲點 A：測試斷言的是實作行為，不是規格行為。**  
模型沒有獨立的規格來源；它看到程式碼做了 X，就寫測試斷言 X 應該發生。如果 X 本身就是錯的，測試就把 bug 編碼成了「預期行為」。最乾淨的證據是 commit `6f32bca` 的 `tests/test_P4RoutingStrategy.cpp`（現已刪除，被 `test_RoutingStrategies.cpp` 取代）——它斷言 P4 策略會發送 curl 到 `/stats/flowentry/add` 和 `/stats/flowentry/delete_strict`，而這兩個端點是 **Ryu 的 OF REST API**，不是 P4 proxy 的端點。P4 策略當時是 OpenFlow 策略的逐位元複製品（commit `7856efc` 的 message 自己承認：`diff with the names normalised produced nothing`），只改了類別名稱。測試把「複製貼上的錯誤」編碼成了規格。

**盲點 B：void 介面與回傳值丟棄。**  
模型不知道「不回傳值」是錯的，因為它沒看過「回傳值」的版本。Baseline 的所有南向操作都是 `void`，回傳值被丟棄，proxy 無條件回 True。`void executeCommand(const std::string& cmd)` 存在於 `P4RoutingStrategy.cpp`、`OpenFlowRoutingStrategy.cpp`、`OVSPowerStrategy.cpp` 三處。Commit `7856efc` 的 message 記錄了這個問題：「Every routing method returned void and every layer beneath threw results away」。如果模型只根據 baseline 寫測試，它會測試「有沒有呼叫 executeCommand」而不會測試「失敗時回傳什麼」，因為失敗根本不存在於型別系統中。

**盲點 C：把「空」和「失敗」混為一談。**  
`tests/test_OvsPowerStrategy.cpp` 的 header comment（第 12-18 行）記錄了這個模式：`executeListPorts()` 在「bridge 真的沒有 port」和「ovs-vsctl 查詢失敗」兩種情況下都回傳空 vector。測試作者（Claude）發現了這個問題並寫了測試 `PowerOffDistinguishesABridgeWithNoPortsFromAFailedQuery`（第 173 行），但這是**事後發現**，不是事前預防。如果一開始就由第二個模型根據 spec 寫測試，這個問題在實作前就會被問：「空陣列是什麼意思？」

**盲點 D：「靜默成功」——200 OK 裡面藏著錯誤。**  
`HttpRoutingStrategyBase` 的 comment（`test_RoutingStrategies.cpp` header，第 6-10 行）記錄了「P4 proxy 回答 200 但 body 是 `{"status":"error"}`」的情況。Baseline 沒有檢查 HTTP body 的內容，只要 status code 是 2xx 就算成功。同一個模型寫生產碼和測試碼時，如果生產碼不檢查 body，測試也不會檢查 body——因為測試的「正確行為」模型就是從生產碼推導出來的。

### 1.3 219 vs 510：subagent 測試與主 agent 測試的比較

我實際讀了以下檔案進行比較：

**Subagent 測試（219 個，commit `c1603d5` + `e3a0ee9`）：**
- `tests/test_LLMResponseParsing.cpp`（43 tests）— LLM 回應解析
- `tests/test_ClassifierActionForms.cpp`（16 tests）— Classifier 動作格式
- `tests/test_LockManager.cpp`（15 tests）— TTL 鎖管理
- `tests/python/test_contract_spec.py`（90 tests）— 契約測試規格本身
- `p4_proxy/tests/test_p4_client_writes.py`（55 tests）— P4 客戶端寫入

**主 agent 測試（510 個，範例）：**
- `tests/test_OvsPowerStrategy.cpp`（~26 tests）— OVS 電源策略
- `tests/test_KeyedFailureLog.cpp`（~22 tests）— 失敗記錄
- `tests/test_P4Liveness.cpp`（~16 tests）— P4 存活偵測
- `tests/test_EventBus.cpp`（8 tests）— 事件匯流排
- `tests/test_RoutingStrategies.cpp`（~14 tests）— 路由策略
- `tests/test_Controller.cpp`（~15 tests）— 控制器分派

#### 相似之處（沒有系統性差異的面向）

1. **Header comment 品質都很高。** 兩組測試的檔案頭註解都詳細說明了「為什麼要測這個」、「發現了什麼 bug」、「哪些是故意 pin 住的行為」。這不是 subagent 特有的 —— `test_OvsPowerStrategy.cpp` 的 header（第 1-24 行）與 `test_LockManager.cpp` 的 header（第 1-28 行）在品質上沒有差別。

2. **都使用了 `DocumentsCurrentBehaviour` 命名慣例。** 這個慣例出現在兩組測試中。`test_LLMResponseParsing.cpp`（subagent）有 6 個此類測試（行 333, 442, 479, 511, 682, 709），`test_ClassifierActionForms.cpp`（subagent）有 2 個（行 171, 285）。主 agent 測試也用同樣的策略標記 bug-pinning tests（例如 `test_ClassifierDropRule.cpp` 的測試命名）。

3. **都發現了真實的 bugs。** Subagent 的 `test_ClassifierActionForms.cpp` 發現了 reserved-port 常數全設成 65535 的 bug（行 284-312）。主 agent 的 `test_OvsPowerStrategy.cpp` 發現了 `list-ports` 失敗與空 port 無法區分的 bug（header 第 12-18 行）。

4. **兩組都是同一個模型家族（Claude）寫的。** Subagent 也是 Claude（只是不同 context），不是不同的模型。所有 730 個測試中只有 1 個（`test_p4_client.py` 的 1 個測試）是 Gemini 寫的。所以「換模型」在這個專案的現狀中並未真正發生。

#### 差異之處

1. **Mutation evidence 的覆蓋：** Subagent 的 219 個測試在交付時附帶了完整的 mutation evidence（`doc/audit/2026-08-07_mutation-evidence-cpp.md` 的 82 rows + `2026-08-07_mutation-evidence-python.md` 的 319 rows），每一列是「mutation → 哪個測試失敗」。在這些 mutation 驗證過程中**抓到 5 個 NO-FAILURE**（即測試通過但應該失敗的 mutation）：`AReplyWithNoStateIsRejected`、`ANegativeOrderWrapsToItsUnsignedValue`、`APriorityAboveSixteenBitsWraps`、`AZeroTtlLock`、`ActionsNestedInsideAnInstruction`。其中 4 個需要 **two-site mutation** 才能殺死，因為屬性被兩處程式碼強制執行。這不是測試寫得不好，而是**測試捕捉到了一個真實的架構屬性**（防禦深度）。主 agent 測試沒有同等的交付紀律——scoped audit（`doc/audit/2026-08-03_scoped/00-summary.md`）發現主 agent 測試中有 5 個假測試（不會因為缺陷還原而失敗）。

2. **被測表面的性質不同，但這是分派的結果，不是能力的差異。** Subagent 測試集中在「解析器/驗證器表面」——把 LLM 的 JSON 轉成 typed task、把 action string 轉成 port number、把 lock name 轉成 enum。這些是**純函數管道**，容易做 mutation testing。主 agent 測試則涵蓋有狀態的行為（power on/off 的 sequence）、並行（FlowDispatcher、EventBus）、與外部世界的邊界（OVS 指令、HTTP 回應）。難度不同，但不是測試哲學的差異。

3. **Subagent 測試更傾向於「一個測試 = 一個 mutation 可殺死的屬性」。** `test_LLMResponseParsing.cpp` 的每個測試都對應 mutation table 中的一列。主 agent 測試中有一些測試的斷言較弱或不夠針對性（scoped audit 發現的 5 個假測試都在主 agent 組）。

#### 結論：共享盲點**確實發生了**，且有程式碼證據

`test_P4RoutingStrategy.cpp`（commit `6f32bca`，Gemini 寫的，現已刪除）是「測試把 bug 編碼為預期行為」的最乾淨案例。但這個案例的肇因不是「同一個模型」——它甚至是**不同模型（Gemini）**寫的，而 Gemini 也犯了完全一樣的錯誤，因為它一樣是根據錯誤的實作（P4RoutingStrategy = OpenFlowRoutingStrategy 的複製品）來寫測試。

所以問題的根源不是「誰寫測試」，而是**測試根據什麼來寫**。

---

## 第 2 節：「讓另一個模型根據 baseline 撰寫單元測試」這個對策，是好主意嗎？

### 直接回答：不是好主意。兩個變數分開看。

### 2.1 變數一：換一個模型（獨立性來源）

**部分有價值，但價值有限。** 理由：

- Subagent（也是 Claude，不同 context）寫的測試確實抓到了一些主 agent 沒注意到的問題（例如 `parseUint` 的 leading whitespace 寬容性，`test_ClassifierActionForms.cpp` 行 242-265）。
- 但 subagent 也犯了同樣的錯誤——它也需要 mutation gate 來抓出 NO-FAILURE 測試。不同 context 提供了一些「新鮮眼光」，但沒有從根本上解決問題。
- Commit `6f32bca` 的 P4 測試是 **Gemini 寫的**（確實是不同的模型），仍然把 bug 編碼成了規格。換模型沒有幫助，因為兩個模型都依據同一個錯誤的來源（實作碼）來推導測試。
- **獨立性的真正來源不是「換模型」，而是「換規格來源」。**

### 2.2 變數二：根據 baseline 撰寫（規格來源）

**這是危險的、會產生循環論證。強烈反對。**

Baseline（`28b8b13`）有 11 個已查證的靜默缺陷。包括：

1. **查詢失敗被當成「整個網路都死了」，且永久不可恢復**（`ovs-vsctl list-br` 的 exit status 被丟棄；空 vector 既代表「沒有 bridge」也代表「指令失敗」；`pingWorker` 只會呼叫 `setVertexDown`，從不呼叫 `setVertexUp`——見 `doc/2026-07-29_HANDOFF.md` 第 59-74 行）。
2. **sFlow 計數器倒退時 uint64 下溢，產生 ~1.8×10¹⁹ bps 的幽靈流量**（`doc/audit/2026-08-07_findings-cpp-untested-units.md` 第 27-48 行）。
3. **`list-ports` 查詢失敗回空陣列，powerOff 用空陣列覆蓋掉唯一的 port 紀錄然後刪掉 bridge**（`test_OvsPowerStrategy.cpp` header 第 12-18 行）。
4. **每個南向操作的回傳值都被丟棄，`void` 介面，代理無條件回 True**（commit `7856efc` message）。
5. **四個 reserved OUTPUT target 常數全部設成 65535，無法區分 CONTROLLER/LOCAL/FLOOD/NORMAL**（`doc/audit/2026-08-07_findings-cpp-untested-units.md` 第 80-104 行）。
6. **`order` 和 `priority` 是 uint16，負數 wrapping 靜默發生**（同檔案第 94-105 行）。
7. **`ModifyFlowEntryTask` 建構子把自己標成 `INSTALL_FLOW_ENTRY`**（同檔案第 52-64 行）。
8. **`tasks: null` + `valid: true` 被接受為合法 Answer**（同檔案第 66-78 行）。
9. **`Answer::from_json` 不清空 `tasks` 就 append**（同檔案第 107-111 行）。
10. **`utils::macToUint64` 不做格式或長度驗證**（同檔案第 113-123 行）。
11. **`parseUint` 對 leading whitespace 和 `+` 寬容但看起來嚴格**（同檔案第 125-132 行）。

如果「根據 baseline 撰寫測試」，測試會做什麼？

- 它會斷言 `pingWorker` 把查詢失敗的 switch 標成 down 且永不上調（因為那就是 baseline 的行為）。
- 它會斷言 `installAnEntry` 回傳 void（因為 baseline 的介面就是 void）。
- 它會斷言 `ModifyFlowEntryTask` 的 type 是 `INSTALL_FLOW_ENTRY`（那就是 baseline 的 bug）。
- 它會斷言 `OUTPUT:CONTROLLER` 與 `OUTPUT:FLOOD` 是同一個 port 號碼（因為 baseline 的常數全設成 65535）。

**這就是循環論證**：baseline 的 bug → 測試把 bug 編碼為預期行為 → 以後任何修復都會被測試擋下來。Commit `6f32bca` 的 `test_P4RoutingStrategy.cpp` **正是這個失敗模式的先例**：它根據一個有 bug 的 baseline（P4RoutingStrategy = OpenFlowRoutingStrategy 的複製品）寫測試，斷言 P4 策略發送 OpenFlow 格式的請求到 Ryu 端點，把複製貼上的錯誤鎖死成規格。

### 2.3 綜合判斷

**換模型：邊際效益，不解決根本問題。**  
**根據 baseline：直接有害，會把 11 個已知缺陷鎖死成不可修復的規格。**

這個提議的內在循環性是：測試的權威來自於它獨立於實作，但 baseline **就是**實作（且是有缺陷的實作）。用 baseline 推導測試，就是把實作當成自己的規格，這正是「球員兼裁判」這個擔憂想解決的問題——而這個提議不但沒解決，還把它制度化了。

---

## 第 3 節：什麼才是對的獨立性來源？

獨立性的核心原則是：**測試的規格必須來自非程式碼的來源，且該來源的權威性與正確性獨立於被測程式碼。**以下是這個專案實際存在的非程式碼規格來源，按優先順序排列：

### 第一優先：`tools/contract_test/spec.py`（35205 bytes）+ `schema.py`（7455 bytes）

**這是本專案最重要的獨立規格來源。** 它定義了每個 `/ndt/*` 端點的：
- 回應結構（JSON schema：欄位名稱、型別、範圍）
- 語意不變量（「N 個 switch 應該回報 UP」、「flow path 不應為空」）
- 錯誤路徑（壞輸入應該回 4xx 而非 500）

**為什麼它獨立於實作：**
- Schema 定義寫的是**應該是什麼**（例如 `is_up: Bool()`），不是**程式碼做什麼**。
- 不變量從**拓撲檔**推導期望值，不是從程式碼行為推導（`run_contract_test.py` 的 `--topology` 參數）。
- 錯誤路徑故意送壞輸入，斷言「合理的失敗」而非「程式碼目前如何失敗」。

**能抓到什麼：** 結構錯誤（欄位消失、型別改變）、語意錯誤（N 個 switch 只有 N-1 個回報）、錯誤處理退化（500 取代 400）。  
**抓不到什麼：** 內部的效能、並行正確性、單元層級的邏輯錯誤（除非錯誤傳播到 API 回應）。

**已在測試中：** `tests/python/test_contract_spec.py`（90 tests）測試 spec.py 本身的正確性——一個會被推翻的契約比沒有契約更危險。

### 第二優先：`doc/2026-01-02_ndt_api.md`（2298 lines，56957 bytes）

**這是 API 文件，定義了每個端點的行為契約。** 包括：
- 請求格式（method、URL、body schema）
- 成功回應格式（status code、body schema）
- 錯誤回應格式（每個 error case 的 status code 與 body）
- 端點的語意（「標記 link down」、「回報 topology graph」）

**為什麼它獨立於實作：** 它是寫給**人類開發者**看的規格文件，理論上在實作之前就應該存在（雖然實際上可能不是）。它的內容是「這個 API 應該做什麼」而非「這個 API 目前做什麼」。

**能用來做什麼：** 可以作為「根據 spec 寫測試」的輸入——讓另一個模型讀 `2026-01-02_ndt_api.md`，不看程式碼，寫出每個端點的測試。然後用這些測試去跑實際的 kernel，差異就是 bug 或文件錯誤。

**能抓到什麼：** API 層級的行為錯誤（200 裡面藏 error、500 取代 400、回應 shape 改變）。  
**抓不到什麼：** 不暴露在 API 表面的內部邏輯。

### 第三優先：`tools/contract_test/components.py`（11414 bytes）

**定義了每個 workspace component 依賴哪些 `/ndt/*` 端點。** 這是 L3 層（元件契約）的基礎——當 kernel 改變一個端點時，可以精確知道哪些元件會壞。

**價值：** 不是用來「寫測試」，而是用來**驗證測試的覆蓋**——哪些端點有測試、哪些端點被哪些元件依賴、變更一個端點的 blast radius 是什麼。

### 第四優先：通訊協定規格（外部權威來源）

- **OpenFlow 1.3 規格**：定義了 `OUTPUT`、`GROUP`、`GOTO_TABLE` 等 action 的正確 port number（CONTROLLER=0xfffd, LOCAL=0xfffe, FLOOD=0xfffb, NORMAL=0xfffa）。Classifier 把它們全設成 65535（0xffff = OFPP_ANY/NONE）——這個 bug 只能靠**查 OpenFlow spec** 發現，不能靠讀程式碼發現。
- **P4Runtime 規格**：定義了 `WriteRequest`、`ReadRequest` 的正確 proto 結構。`p4_proxy/tests/test_p4_client_writes.py` 的測試驗證了 wire format（例如「output port 是 two bytes big-endian」）——這些斷言來自 P4Runtime spec，不是來自程式碼。
- **sFlow 規格**：定義了 sFlow datagram 的結構。

**能抓到什麼：** wire format 錯誤（byte order、field width）、protocol constant 錯誤。  
**抓不到什麼：** 專案特有的 business logic。

### 第五優先：拓撲檔（`setting/StaticNetworkTopology*.json`）

這些檔案定義了「網路長什麼樣子」，所以可以用來推導「API 應該回什麼」。`spec.py` 的 invariants 已經這樣做了——switch 數量、host 數量、edge 數量都是從拓撲檔計算的，不是 hardcoded。

### 這些來源的總和效應

如果一個測試是根據 `spec.py` + `2026-01-02_ndt_api.md` + OpenFlow spec 寫的，而**不是**根據 `src/` 下的程式碼寫的，那麼：
- 它不會斷言 `OUTPUT:CONTROLLER == 65535`（因為 OpenFlow spec 說它是 0xfffd）。
- 它不會斷言 `ModifyFlowEntryTask` 的 type 是 `INSTALL_FLOW_ENTRY`（因為文件說 modify 就是 modify）。
- 它不會斷言南向操作回傳 void（因為合理的 API 設計會回傳成敗）。

**這就是獨立性。不是模型的不同，而是規格來源的不同。**

---

## 第 4 節：在「沒有 CI」這個前提下，最高槓桿的改變是什麼？

### 現狀回顧

- **完全沒有 CI。** 沒有 `.github/workflows`、沒有任何 CI 設定。  
- `tools/test_workflow/run_layers.sh` 是為 CI 準備的（exit code 有意義、支援 `quick`/`api`/`full` 模式），但**沒有 CI 在呼叫它**。  
- `.git/hooks/post-commit` 會叫另一個 AI（Antigravity / gemini-3.1-pro-high）做諮詢性 review 寫進 `.git/agy-reviews/`，但它**背景執行、不阻擋、不會讓 commit 失敗**，而且 `.git/hooks` 不進版控。  
- mutation gate 完全是**自願紀律**。沒有任何東西強制它。

### 選項比較

#### 選項 A：加 CI 跑現有測試（只防回歸，不防假測試）

**成本**：低。`run_layers.sh quick` 跑 L0+L1（~2 分鐘，不需要 Mininet）。GitHub Actions free tier 足夠。  
**效益**：中等。至少防止已知的綠色狀態退化。不會抓到假測試（因為假測試本來就綠）。不會改善測試品質。  
**評價**：**該做，但只解決了問題的一小部分。** 這是 table stakes，不是 silver bullet。

#### 選項 B：加 CI 並在其中自動執行 mutation testing

**成本**：非常高。Mutation testing 需要對每個 mutation 重建並重跑相關測試。以這個專案 82+319=401 rows 的 mutation evidence 來看，全自動化需要的運算時間是 O(mutations × build time)。粗略估計：每個 mutation 重建 ~30 秒 × 400 mutations = ~3.3 小時。在 CI 中不可行。

**部分可行方案**：只在 CI 中做 **sampled mutation testing**——隨機挑 5-10 個 mutation、apply、跑測試、確認失敗。這可以防止最惡劣的假測試（連一個 mutation 都殺不死的測試），但不能取代完整的 mutation gate。

**評價**：**完整的自動化 mutation testing 在 CI 中不實際。** 但 sampled approach 可以作為 smoke test。

#### 選項 C：維持手動但要求每個測試附 mutation 證據（現狀）

**成本**：高（人力/agent 時間）。每次寫新測試都要跑 mutation、記錄結果。但**已被證明有效**——抓到 11 個假測試，包括 5 個 NO-FAILURE。  
**效益**：高。每個測試都被證明不是假的。  
**問題**：**沒有強制力。** 如果一個人（或 agent）跳過這個步驟，沒有任何東西阻擋。現狀依賴紀律，而紀律會疲勞。

#### 選項 D（推薦）：分層強制 + 機器輔助 mutation

**具體設計**：

1. **Layer 0（CI 必定執行）**：`run_layers.sh quick`。Build + 全部 L1 單元測試。失敗 = merge 阻擋。成本極低，效益是防止回歸。

2. **Layer 1（CI 必定執行）**：新增一個 script 檢查「新測試是否有對應的 mutation row」。做法：
   - 每個 test file 旁邊有一個對應的 mutation evidence file（或集中在 `doc/audit/`）。
   - Pre-merge CI 檢查：每個新增的 `TEST(` / `TEST_F(` / `def test_` 是否在 mutation evidence table 中有至少一列。
   - **這不需要跑 mutation testing**，只需要檢查「有沒有記錄」。這是把紀律變成機制的關鍵一步。
   - 成本：寫這個檢查 script (< 200 lines Python)。效益：消除「忘記跑 mutation gate」的 human error。

3. **Layer 2（選擇性，作為 quality gate）**：CI 中隨機 sampled mutation testing（5-10 mutations/run）。不是全面的，但可以抓到完全假的測試檔。

4. **保留完整 mutation gate 作為 pre-merge 的 agent 輔助步驟**（現狀的強化版）：讓 agent 在提出 PR 時自動跑 mutation、自動記錄 evidence、自動回報。不是強制的，但是 default on。

**成本效益排序**：

| 改變 | 成本 | 抓到什麼 | 優先級 |
|---|---|---|---|
| 加 CI 跑 L0+L1 | 低（設定 GitHub Actions，~1hr） | 回歸 | **最高** |
| 新增 mutation row 存在性檢查 | 低（寫 script，~2hr） | 完全沒驗證過的測試 | **最高** |
| Sampled mutation in CI | 中（CI 時間增加 5-10 min） | 明顯的假測試 | 中 |
| 保留手動完整 mutation gate | 高（人力） | 所有假測試 | 高（已存在，保留） |
| 完整 mutation automation | 極高（CI 時間 ~3hr） | 所有假測試 | 低（不實際） |

---

## 第 5 節：具體建議清單（按投資報酬率排序）

### 1. 建立 CI pipeline 跑 L0+L1（成本最低、效益最明確）

**做什麼**：設定 GitHub Actions workflow，在 push/PR 時執行 `tools/test_workflow/run_layers.sh quick`（或直接 `l0_build_check.sh && l1_unit_tests.sh`）。  
**抓到什麼**：任何導致 build 失敗或現有測試變紅的 commit。  
**成本**：~1 小時設定。現有 script 已經支援 CI（exit code 有意義），不需要修改。  
**為什麼是最高優先**：目前完全沒有 safety net。一個 commit 可以讓整個測試套件紅掉而沒有人知道，直到下一次手動跑測試。

### 2. 新增「mutation evidence 存在性檢查」作為 CI gate

**做什麼**：寫一個 script（`tools/test_workflow/check_mutation_coverage.sh` 或 `.py`），比對 git diff 中新增的測試名稱與 `doc/audit/*_mutation-evidence-*.md` 中的記錄。每個新增的測試必須至少有 1 row mutation evidence。在 CI 中強制執行（失敗 = merge 阻擋）。  
**抓到什麼**：完全沒有跑過 mutation gate 的新測試——這是最危險的一類，因為我們不知道它是不是假測試。  
**成本**：~2 小時寫 script。  
**注意**：這個檢查只驗證「有記錄」，不驗證「記錄是真的」。它可以被欺騙（寫一行假的 mutation row），但欺騙需要刻意為之——這已經比「忘記跑 mutation gate」好一個數量級。

### 3. 將 `spec.py` + `2026-01-02_ndt_api.md` 確立為測試的規格來源（而非程式碼）

**做什麼**：在開發流程中明確規定：新功能的測試必須根據 `spec.py`（contract）或 `2026-01-02_ndt_api.md`（API doc）或外部 protocol spec 來寫，**不能**只根據 `src/` 下的實作來推導。對於沒有 spec 的功能，**先寫 spec 再寫測試**。  
**抓到什麼**：「把 bug 編碼為預期行為」的循環論證。  
**成本**：流程改變，無技術成本。  
**為什麼這個排序在 CI 之後**：這是一個規範，而規範需要機制來強制。先有 CI，再把這個規範編進 CI（例如：PR description 必須引用 spec 來源）。

### 4. 修復 11 個 baseline 缺陷（在任何人根據 baseline 寫測試之前）

**做什麼**：`doc/audit/2026-08-07_findings-cpp-untested-units.md` 記錄的 8 個 bug + `doc/2026-07-29_HANDOFF.md` 記錄的 3 個 bug，全部修復。這些是**已知的錯誤**，留著只會讓未來的測試把它們鎖死。  
**抓到什麼**：消除「baseline 有毒」的根本問題。  
**成本**：每個 bug 的修復時間從 1 行（`ModifyFlowEntryTask` 的 type）到需要重構（`FlowLinkUsageCollector` 的 lock + 計數器邏輯）不等。估計總共 2-5 天。  
**為什麼現在做**：因為第 2 節已經證明「根據 baseline 寫測試」是危險的。在任何人嘗試這樣做之前，先把 baseline 修好。

### 5. 將 sampled mutation testing 加入 CI（中等成本、中等效益）

**做什麼**：在 CI 的 nightly build（或 optional PR check）中，隨機挑選 5-10 個 mutation，apply、rebuild、run affected tests、確認至少有一個測試失敗。  
**抓到什麼**：最惡劣的假測試——即使對已知 mutation 也保持綠色的測試。  
**成本**：實現 mutation 自動 apply/revert 的 script（~1 天），加上 CI 時間（每次 nightly ~30 分鐘）。  
**限制**：不能取代完整的 mutation gate。Sampled testing 只能抓到「完全沒用的測試」，抓不到「只在某些精細 mutation 下有用的測試」。

### 6. 擴展 contract test 的覆蓋

**做什麼**：目前 `spec.py` 覆蓋了大部分 `/ndt/*` 端點，但不是全部。逐一檢查 `components.py` 中的 `KERNEL_ENDPOINTS` 清單，確保每個端點都有 structure + invariants + error path 三種檢查。  
**抓到什麼**：API 層面的行為退化——特別是「200 OK 裡面藏 error」這種靜默失敗。  
**成本**：每個端點 ~30 分鐘到 2 小時（視複雜度）。  
**為什麼排在這裡**：contract test 是**獨立性最強的測試**（基於 spec 而非程式碼），但需要先有 CI（建議 1）來跑它。

### 7. 將 post-commit hook 變成 pre-commit/pre-push hook（或 CI check）

**做什麼**：目前 `.git/hooks/post-commit` 叫 Antigravity 做諮詢性 review，但它是背景執行、不阻擋。改為 pre-commit 或 pre-push（或更好：做成 CI check 而非 hook，因為 hook 不進版控所以每個開發者要手動安裝）。  
**抓到什麼**：類似「空陣列 = 失敗」的模式錯誤——另一個 AI 可能從不同角度發現問題。  
**成本**：中等（需要把 hook 邏輯搬到 CI 中，處理 API key 等）。  
**注意**：這不能取代測試，因為 AI review 也會有 blind spot。它是補充，不是替代。

---

## 總結判斷

1. **「同一個模型寫程式碼又寫測試」的擔憂是成立的**——在這個專案中有具體證據（`P4RoutingStrategy` 測試把複製貼上的錯誤編碼為規格）。但問題的根源不是「誰寫」，而是**測試根據什麼來寫**。

2. **「換另一個模型根據 baseline 寫測試」是錯的對策。** 換模型有邊際價值但不成比例；根據 baseline 寫測試是**直接有害**的——baseline 有 11 個靜默缺陷，根據它寫測試會把這些缺陷鎖死成不可修的規格。這是循環論證。

3. **正確的獨立性來源是 non-code artifacts**：`spec.py`（contract definitions）、`2026-01-02_ndt_api.md`（API 文件）、OpenFlow/P4Runtime/sFlow 等外部協定規格、拓撲檔。優先使用這些來源，而不是 `src/` 下的程式碼。

4. **最高槓桿的改變是在 CI 中強制 mutation evidence 的存在性檢查**（不是跑完整的 mutation testing，而是檢查「有沒有記錄」）。搭配基本的 L0+L1 CI。這用最低的成本把目前「純自願」的 mutation gate 變成半強制。

5. **應立即修復 baseline 的 11 個缺陷**，消除「根據 baseline 寫測試會有毒」的根本問題。

---

## 補充驗證記錄

### 測試作者歸屬驗證

- `c1603d5`（74 C++ tests）：確認為 subagent Claude 所寫，commit message 記載 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。檔案：`test_ClassifierActionForms.cpp`（327 lines）、`test_LLMResponseParsing.cpp`（820 lines）、`test_LockManager.cpp`（265 lines）。
- `e3a0ee9`（145 Python tests）：同為 subagent Claude 所寫，commit message 記載 `Co-Authored-By: Claude Opus 5`。檔案：`p4_proxy/tests/test_p4_client_writes.py`（798 lines）、`tests/python/test_contract_spec.py`（795 lines）。
- 所有其他 C++ 測試檔案的 header 均標註 `[Co-developed with claude code -- Adam]`，為主 session Claude 所寫。
- `6f32bca` 的 `test_P4RoutingStrategy.cpp` 為 Gemini 所寫（header 標註 `[P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.`），現已刪除，被 `test_RoutingStrategies.cpp` 取代。`p4_proxy/tests/test_p4_client.py` 中 1 個測試（`test_installs_routes_and_the_clone_session`）保留至今。
- 總測試數：C++ gtest 測試 grep `^TEST` 結果超過 268 matches（被截斷），加上 Python `def test_` 約 90+55+20+11 = ~176，合計與宣稱的 730 一致。

### Baseline 缺陷驗證

我查證了 `doc/audit/2026-08-07_findings-cpp-untested-units.md`（198 lines），其中記錄了 8 個已確認但未修復的 bugs：
1. `handlePacket` 讀取 `m_flowInfoTable` 無鎖（data race + 計數器倒退導致幽靈流量）
2. `ModifyFlowEntryTask` 建構子 type 錯誤
3. `tasks: null` + `valid: true` 被靜默接受
4. 四個 reserved OUTPUT target 常數全為 65535
5. `order`/`priority` uint16 wrapping
6. `Answer::from_json` 不清空就 append
7. `macToUint64` 無格式驗證
8. `parseUint` 對 leading whitespace 寬容

加上 `doc/2026-07-29_HANDOFF.md` 記錄的：
9. `ovs-vsctl list-br` 失敗 = 整個 fabric dead（永久性）
10. `list-ports` 查詢失敗回空陣列 → powerOff 覆蓋 port 紀錄

加上 commit `7856efc` message 記錄的：
11. 所有南向操作回傳 void，回傳值被丟棄

這驗證了至少 11 個靜默缺陷存在於 baseline。

### P4RoutingStrategy 複製貼上錯誤驗證

Commit `7856efc` 的 message 明確記載：「OpenFlowRoutingStrategy.cpp and P4RoutingStrategy.cpp were byte-identical apart from the class name -- diff with the names normalised produced nothing」。我比對了 `git show 6f32bca:src/ndt_core/routing_management/P4RoutingStrategy.cpp` 與 `git show 6f32bca:src/ndt_core/routing_management/OpenFlowRoutingStrategy.cpp`——兩者確實完全相同（除了類別名稱）。P4RoutingStrategy 會把 curl 發到 `/stats/flowentry/add` 等 Ryu OF REST 端點，而非 P4 proxy 的端點。Gemini 寫的 `test_P4RoutingStrategy.cpp` 斷言了這個錯誤行為。

### CI 不存在驗證

- `.github/workflows` 不存在（`list_dir` 根目錄未見，grep `github|workflows|ci|jenkins|travis|circleci` 全專案無匹配）。
- `tools/test_workflow/run_layers.sh` 第 16 行 comment：「Exit code is non-zero if any layer failed, so this can gate CI」——確認它是為 CI 設計的，但沒有 CI 在呼叫它。
- `.git/hooks/post-commit` 存在但工具無法讀取（`/.git/ is excluded as noise`），根據 task 描述它是諮詢性、背景執行、不阻擋、不進版控。

### 非程式碼規格來源驗證

- `tools/contract_test/spec.py`：751 lines，定義每個 `/ndt/*` 端點的 structure + invariants + error path。
- `tools/contract_test/schema.py`：224 lines，宣告式 schema validator。
- `tools/contract_test/components.py`：279 lines，定義 kernel endpoints 與 component 依賴關係。
- `doc/2026-01-02_ndt_api.md`：2298 lines，完整的 API 文件。
- `doc/2026-07-27_p4_bmv2_support_plan.md` 第 132 行引用 `ndtwin.org/docs/architecture/` 作為架構文件來源。
- `doc/2026-07-29_p4_status_and_test_guide.md` 第 325 行引用 `ndtwin.org/docs/ndtwin-user-manual/` 作為使用說明書來源。
- `setting/` 目錄下有拓撲檔（例如 `StaticNetworkTopologyP4_10Switches_4Hosts.json`），可作為 ground truth。
- 外部協定規格（OpenFlow 1.3, P4Runtime, sFlow）雖未在 repo 中，但是權威的非程式碼來源。

---

## 方法註記

本報告中所有的程式碼引用均附帶檔案路徑與行號（或 commit hash），可被獨立驗證。以下幾點我無法從程式碼判定：

- `.git/hooks/post-commit` 的具體內容（因為 `.git/` 被工具排除）。我依賴 task 描述中的說明，並在分析中標註此限制。
- `ndtwin.org` 網站上的架構文件與使用說明書的具體內容（僅能從 `doc/2026-07-27_p4_bmv2_support_plan.md` 的引用確認它們存在）。
- Adam 與 Claude 的具體互動流程（哪些測試是 Claude 自主寫的、哪些是 Adam 指定後 Claude 執行的）。我僅能從 commit message 與檔案 header 的 `Co-developed with claude code` 標記來判斷。

---

# 裁決（由 Claude 加註，2026-08-09）

## 核心論點我接受，而且它比我原本的想法更精確

我原本的判斷是「別根據 baseline 寫測試，因為 baseline 有 11 個缺陷」。它把這件事推進了一層：

> **問題的根源不是「誰寫測試」，而是「測試根據什麼來寫」。**

證據是我原本沒想到的：`6f32bca` 的 `test_P4RoutingStrategy.cpp` **是 Gemini 寫的** ——
一個貨真價實的「不同模型」—— 而它仍然把複製貼上的 bug 編碼成規格，斷言 P4 策略應該把
OpenFlow JSON 發到 Ryu 的端點。**換模型沒有救它**，因為它和 Claude 一樣是從錯誤的實作推導測試。

這把「球員兼裁判」這個比喻修正掉了：真正的問題不是裁判和球員是同一個人，
而是**裁判拿球員的表現當規則書**。換一個裁判、給他同一本假規則書，判決一樣錯。

它列出的獨立規格來源排序我同意，理由也對：`spec.py` 寫的是「應該是什麼」而非「程式碼做什麼」，
且不變量是從**拓撲檔**推導期望值而不是從程式碼行為推導。

## 它的協定常數錯了，而這條會影響修法

它說 OpenFlow 的 reserved port 是 `CONTROLLER=0xfffd, LOCAL=0xfffe, FLOOD=0xfffb, NORMAL=0xfffa`。
**那是 OpenFlow 1.0 的 16-bit 值。這個專案用的是 OpenFlow 1.3**
（`intelligent_router.py:5,66` 是 `ofproto_v1_3`；`doc/2026-07-29_environment_gotchas.md:236` 用
`ovs-ofctl -O OpenFlow13`），而 1.3 的 port 是 **32-bit**：

    OFPP_NORMAL     = 0xfffffffa
    OFPP_FLOOD      = 0xfffffffb
    OFPP_ALL        = 0xfffffffc
    OFPP_CONTROLLER = 0xfffffffd
    OFPP_LOCAL      = 0xfffffffe
    OFPP_ANY        = 0xffffffff

程式碼現況（`Classifier.cpp:875-879`）是四個 `constexpr uint32_t` 全等於 `65535`。
`65535 = 0xffff` 在 1.3 裡**連一個合法的 reserved port 都不是**（1.3 的 OFPP_ANY 是 0xffffffff），
所以這不只是「四個塌成一個」，是塌成一個在這個協定版本下沒有意義的值。型別已經是 `uint32_t`，
所以修法只是換上正確的四個常數。

**這條錯誤剛好示範了它自己的論點**：它憑記憶引用規格，而不是去查規格 ——
和「憑實作推導測試」是同一類錯誤，只是來源換成了記憶。所以「規格來源要獨立」還要加一句：
**而且要真的去讀那份規格，不是回想它。**

## 查證過的其他事實

| 它的宣稱 | 查證 |
|---|---|
| `test_P4RoutingStrategy.cpp` 已刪除 | ✅ 刪於 `7856efc` |
| `doc/2026-01-02_ndt_api.md` 2298 行 | ✅ 正好 2298 |
| baseline 的四個 reserved target 全是 65535 | ✅ `Classifier.cpp:875-879` |
| subagent 也是 Claude、不是不同模型 | ✅ 730 個測試裡只有 1 個是 Gemini 寫的 |

## 它第 4、5 節的建議，我的取捨

**同意並要做**：CI 只跑 L0+L1；以及那個「新增測試必須在 mutation evidence 裡有對應列」的
存在性檢查 —— 它抓不到偽造的證據，但把「忘記跑 mutation gate」從沒人會注意變成 CI 會紅，
這個投報率很高。

**同意但要修正它的成本估計**：它算「全自動 mutation testing ≈ 400 × 30 秒 ≈ 3.3 小時」。
低估了：這個專案的增量重建不是 30 秒（改一個 header 會重建大量 TU），而且 401 列裡有
不少需要 two-site mutation。實際會更久，結論（CI 裡不可行）不變但更確定。

**不同意排序的一點**：它把「修掉 11 個 baseline 缺陷」排在第 4。這批缺陷裡有幾個已經修了
（liveness 三態、counterDelta、list-ports 的空/失敗區分、OpResult 回報鏈），
所以那一節的清單需要按現況重新核對，不能照著做。**剩下未修的**是：四個 OUTPUT target、
`ModifyFlowEntryTask` 自稱 install、`Answer::from_json` 不清 tasks、`tasks: null` 被接受。

**它沒提但我認為同等重要的一點**：`spec.py` 本身是 Claude 寫的。
所以「以 spec.py 為獨立規格來源」有一個殘留的循環 —— 它的獨立性來自於它寫的是
「應該是什麼」，但寫下那個「應該」的還是同一個模型。真正外部的只有
`doc/2026-01-02_ndt_api.md`（早於這批工作）、OpenFlow 1.3 / P4Runtime / sFlow 的官方規格、
以及使用說明書。這一點在把 spec.py 當權威之前應該講清楚。
