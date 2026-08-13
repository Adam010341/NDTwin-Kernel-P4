# NDTwin-Kernel 模組詳細分析：Intent Translator (自然語言意圖翻譯)

## 1. 模組概述
**路徑**：`include/ndt_core/intent_translator/`, `src/ndt_core/intent_translator/`
**主要類別**：`IntentTranslator`, `LLMAgent`, `LLMResponseTypes`

`IntentTranslator` 模組是 NDTwin 中最具實驗性與前瞻性的功能。它允許使用者透過**自然語言文字** (Natural Language Text) 下達網路管理指令，並透過背後整合的 LLM (大語言模型，預設使用 gpt-5-nano API)，將自然語言意圖解析並轉譯為 NDTwin 系統內部可以直接執行的結構化任務 (Tasks)，如修改路由、查詢流量、斷開設備電源等。

## 2. 核心架構與工作流程

### 2.1 雙 Agent 協商機制 (Agent Negotiation)
系統設計了兩個獨立的 LLMAgent：
1. **Answer Agent (解答代理)**：負責接收使用者的自然語言輸入，並根據 Prompt 產生對應的 NDTwin 任務陣列 (JSON 格式)。
2. **Validation Agent (驗證代理)**：負責檢核 Answer Agent 輸出的任務結構是否合法、邏輯是否正確。
當使用者下達指令 (`inputTextIntent`) 時，Answer Agent 產生任務，若設定了協商機制 (`performAgentsNegotiation`)，這兩個 Agent 會進入一個最多 10 回合的對話修正迴圈。Validation Agent 會指出錯誤，Answer Agent 則依據錯誤訊息重新生成，直到 Validation Agent 回報 `valid: 1` 為止。這大幅提升了 LLM 呼叫內部 API 的準確度與穩定性。

### 2.2 Task 定義與執行引擎
意圖被轉譯後，會對應到 `LLMResponseTypes.hpp` 定義的列舉 `TaskType`，這就是 NDTwin-Kernel 提供給 LLM 的「API 集合」。包含但不限於：
- `DISABLE_SWITCH` / `ENABLE_SWITCH` (隔離/恢復交換機網路)
- `POWEROFF_SWITCH` / `POWERON_SWITCH` (實體斷電/復電)
- `INSTALL_FLOW_ENTRY` / `MODIFY_FLOW_ENTRY` / `DELETE_FLOW_ENTRY` (流表操作)
- `GET_TOP_K_FLOWS` / `GET_SWITCH_CPU_UTILIZATION` / `GET_NETWORK_TOPOLOGY` (各種遙測與狀態查詢)
- `BLOCK_HOST` (主機隔離封鎖)

`performTask` 函式就是這個執行引擎，它根據 `TaskType` 扮演路由器的角色，呼叫 `TopologyAndFlowMonitor`、`FlowRoutingManager` 或 `DeviceConfigurationAndPowerManager` 的對應函數完成操作。

### 2.3 網路實體尋址解析
LLM 通常只知道網路節點的「邏輯名稱」 (Device Name, 比如 "s1")，但在系統底層，流量控制需要 `DPID`，電源控制需要實體 `IP`。`IntentTranslator` 在執行任務前，會呼叫 `getSwitchIpByName` 查詢拓樸模組，完成字串名稱到 IP/DPID 的轉換。

## 3. 程式碼品質與安全性分析
- **優點**：
  - 將自然語言操作無縫接入底層系統，大幅降低了網路維運的門檻。
  - 任務類別 (`TaskType`) 的封裝設計很好，每一種任務在 `performTask` 中都有明確的邊界，避免了 LLM 直接生成程式碼執行的安全性問題 (Sandbox)。
- **安全性風險與技術債**：
  - **強依賴 JSON 轉換正確性**：在 `INSTALL_FLOW_ENTRY` 等任務中，LLM 提供的 JSON (`match` 欄位) 被直接傳入 `FlowRoutingManager`。雖然做了一些手動欄位替換 (`dl_type` 取代 `eth_type`)，但如果 LLM 隨意產生錯誤的 JSON 欄位型別，可能導致下遊的 JSON 函式庫拋出未捕捉的例外而使系統崩潰。需要更強健的 Schema Validation 機制（例如引入 JSON Schema 驗證）。
  - **LLM 協商迴圈的潛在延遲**：`performAgentsNegotiation` 若觸發多次 (最多 10 次) 網路呼叫，將導致 API 嚴重阻塞逾時 (Timeout)。
  - `gpt-5-nano` 模型在程式碼中被硬編碼。
  - 對於 `BLOCK_HOST` 任務中，`priority` 被寫死為 50000，這在複雜的 SDN 流表中可能會與其他規則發生非預期的碰撞，應設計為動態分配。
