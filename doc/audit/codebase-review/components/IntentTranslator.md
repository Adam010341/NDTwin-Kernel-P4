# NDTwin-Kernel 模組詳細分析：IntentTranslator

## 1. 模組概述
**路徑**：`include/ndt_core/intent_translator/IntentTranslator.hpp`
**主要類別**：`IntentTranslator`

`IntentTranslator` 是 NDTwin 的自然語言意圖翻譯模組，將使用者的對話文字（例如：「幫我把 s1 斷電」）轉化為系統內部可執行的結構化任務。它透過呼叫大語言模型 (LLM)，實作了一個 Answer Agent 與 Validation Agent 互相協商的自訂 Agent 迴圈。

## 2. 依賴關係
- **內部模組**：`DeviceConfigurationAndPowerManager`, `TopologyAndFlowMonitor`, `FlowRoutingManager`, `sflow::FlowLinkUsageCollector`。
- **意圖解析機制**：`LLMAgent` (負責與外部 LLM 溝通)，`LLMResponseTypes` (定義了對應系統內部 API 的 TaskType)。
- **外部函式庫**：`nlohmann/json`。

## 3. 執行緒模型
本模組**沒有自己的背景執行緒**。當 HTTP API 收到文字指令時，會在當前執行緒 (HTTP Worker) 中**同步阻擋 (Synchronous Blocking)** 執行。
- `performAgentsNegotiation` 包含了一個與 LLM API 通訊的多次迴圈，延遲可能高達數秒甚至十數秒，這段期間該 API 執行緒會被完全佔用。

## 4. API 方法清單與公開方法說明

### API 方法清單
- `std::unique_ptr<llmResponse::LLMResponse> inputTextIntent(std::string inputText, const std::string &sessionId)`
- `void cleanSession(const std::string &sessionId)`

### 公開方法說明
*   **`inputTextIntent(std::string inputText, const std::string &sessionId)`**
    主要的進入點。接收自然語言輸入，並利用傳入的 `sessionId` 來維護對話歷史。它會啟動 Answer Agent 產生方案，再由 Validation Agent 進行邏輯檢核，最後呼叫 `performTask` 實際執行。
*   **`cleanSession(const std::string &sessionId)`**
    刪除特定 `sessionId` 的對話紀錄 (Context Memory)，當一段除錯工作完成，或是需要重置 LLM 記憶時使用。
