# NDTwin Kernel 其他核心元件概覽

在先前的分析中，我們已經詳細拆解了 NDTwin Kernel 中與「網路拓撲、流量監控、硬體狀態、路由控制」最為相關的核心檔案。
但在 `src/ndt_core/` 資料夾中，其實還隱藏了幾塊拼圖，負責系統的「非同步任務分發」、「AI 意圖翻譯」以及「應用程式與歷史資料管理」。

以下為您簡要介紹這些尚未被詳細提及的模組：

---

## 1. 非同步任務分發 (Routing Management)
除了我們先前看到的 `FlowRoutingManager.cpp` (純粹發送 curl 指令) 之外，這個資料夾下還有兩個負責排程的檔案：

### `Controller.cpp` & `FlowDispatcher.cpp`
* **功能**：這兩者的存在是為了解決「效能瓶頸」。如果系統同時需要下發 1000 條 OpenFlow 規則，連續呼叫 1000 次 `curl` 會讓主執行緒嚴重卡死。
* **架構**：`FlowDispatcher` 實作了一個**背景非同步佇列 (Job Queue)**。`Controller` 負責將上層的路由意圖打包成 `FlowJob` 丟進佇列中，然後 `FlowDispatcher` 會依照 DPID (交換機 ID) 開啟獨立的 Worker Thread，在背景默默地呼叫 `FlowRoutingManager` 批次發送指令。

## 2. AI 意圖翻譯 (Intent Translator)
NDTwin 主打的特色之一是支援自然語言操作網路 (NLP to SDN)。

### `LLMAgent.cpp`
* **功能**：封裝了與大型語言模型 (如 OpenAI GPT) 溝通的底層邏輯，包含讀取 Prompt 範本 (`systemPromptFilePath`)，以及負責 HTTP 請求的收發。

### `IntentTranslator.cpp`
* **架構**：它是系統的「AI 翻譯官」。在建構子中，它實例化了兩個 Agent：`m_answerAgent` (負責翻譯使用者的意圖為網路指令) 與 `m_validationAgent` (負責驗證前者的輸出是否安全合理)。它會將 `TopologyAndFlowMonitor` 的當前狀態餵給 LLM，讓 AI 知道現在的網路長什麼樣子。

## 3. 封包分類器 (Collection)

### `Classifier.cpp`
* **功能**：實作了一個類似 OpenFlow / OVS 的軟體分類器 (Software Classifier)。
* **用途**：在數位孿生中，我們有時候不需要真的把封包送到硬體，而是想在軟體中模擬「如果封包這樣走，會 Match 到哪條規則」。這個檔案用 C++ 實作了封包標頭的位元比對邏輯 (Bitmask Matching)，可以用來輔助分析或是做為 AI 的預測引擎。

## 4. 歷史資料與外部應用 (Data & App Management)

### `HistoricalDataManager.cpp`
* **功能**：這是一個背景定時任務 (Background Timer Task)。它會定期將 `TopologyAndFlowMonitor` 的當前頻寬、狀態，寫入本地硬碟的資料夾中（可能是 CSV 或 JSON），用來做長時間的數據回測或是機器學習訓練資料。

### `ApplicationManager.cpp`
* **功能**：管理掛載的網路硬碟 (NFS) 或應用程式產生的檔案，負責清理過期 (Stale) 的檔案與目錄。

### `SimulationRequestManager.cpp`
* **功能**：當 NDTwin Kernel 需要外部強大的模擬器（如特定的網路模擬伺服器）協助時，它會透過這個 Manager 向 `SIM_SERVER_URL` 發送 HTTP POST 請求。

---

> [!TIP]
> **P4 遷移注意事項**
> 在這些額外的元件中，**`Controller.cpp` 與 `FlowDispatcher.cpp` 的重要性極高**！
> 未來您的 `P4-Proxy-Agent` 也會面臨「一次要寫入大量 P4Runtime 規則」的效能問題。您可以沿用這個 C++ 端的 Dispatcher 機制，讓它非同步地呼叫您的 Python Proxy；或是反過來，在您的 Python Proxy 中實作非同步的 gRPC 呼叫佇列。
