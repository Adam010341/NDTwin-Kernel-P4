# NDTwin Kernel 架構對應表

根據您提供的 NDTwin 系統架構圖，NDTwin Kernel 內部包含了 9 個核心組件 (Components)。為了幫助您快速在程式碼庫中定位這些模組，以下是這 9 個組件與 `src/ndt_core/` 目錄下對應 Folder 與檔案的對照表：

| 架構圖中的 Component 名稱 | 對應的 `ndt_core` Folder | 對應的 C++ 核心檔案 | 核心職責簡述 |
| :--- | :--- | :--- | :--- |
| **Device configuration and power manager** | `power_management` | `DeviceConfigurationAndPowerManager.cpp` | 負責設備電源控制（如 Smart Plug 喚醒）與查詢交換機 OpenFlow Tables 等狀態。 |
| **Flow routing manager** | `routing_management` | `FlowRoutingManager.cpp` | 負責將網路路由變更下發到 SDN Controller（新增、刪除、修改 Flow/Group/Meter Rules）。 |
| **Data cache manager**<br>*(原始碼中命名為歷史資料管理)* | `data_management` | `HistoricalDataManager.cpp` | 負責快取網路狀態或流量紀錄，供歷史資料查詢或機器學習/訓練使用。 |
| **Application registration and coordination manager** | `application_management` | `ApplicationManager.cpp` | 負責接收上層 App 的註冊，並協調多個 App 之間的資源與優先權。 |
| **Simulation request and reply manager** | `application_management` | `SimulationRequestManager.cpp` | 處理上層應用發起的模擬請求 (Simulation Cases)，並回傳模擬後的網路狀態結果。 |
| **Controller and other events handler** | `event_handling` | `ControllerAndOtherEventHandler.cpp` | 作為 Event Bus 的訂閱者，處理各種非同步事件（如鏈路斷線），並觸發對應的邏輯。 |
| **Intent to tasks translator** | `intent_translator` | `IntentTranslator.cpp` | 整合大型語言模型 (LLM)，負責將人類的自然語言意圖翻譯為具體的 NDTwin 網路指令 (Task)。 |
| **Topology and flow monitor** | `collection` | `TopologyAndFlowMonitor.cpp` | 向 SDN Controller 定期抓取最新的 Switches、Hosts、Links，以在記憶體中建構並維護網路拓撲圖 (Graph)。 |
| **Flow information and link bandwidth usage collector** | `collection` | `FlowLinkUsageCollector.cpp` | 透過 sFlow (或直接向 Controller 查詢) 收集鏈路的即時封包與頻寬使用率。 |

> [!TIP]
> **補充說明**：
> NDTwin Kernel 採用了高度模組化的設計。還有一個圖上沒有畫在 9 個方塊中，但極為關鍵的模組是位於 **`src/ndt_core/http/HttpSession.cpp`** 的 Dispatcher。它是 Kernel 對外暴露 REST API 的大門，負責接收所有北向 (Northbound) 來自上層應用的請求，然後將請求分派給上述對應的 Manager。如果您未來要進行 P4 整合，這個 `HttpSession.cpp` 會是您切換南北向協議的關鍵攔截點。
