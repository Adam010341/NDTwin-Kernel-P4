# NDTwin 系統架構學習工作流 (P4 擴充前置準備)

在開發 P4 Proxy Agent 之前，深入了解 NDTwin Kernel 的整體運作方式是非常重要的。為此，我為您擬定了一份「理解系統架構」的學習工作流。這份工作流將龐大的系統拆解為數個循序漸進的子任務 (Sub-tasks)，幫助您有系統地掌握核心邏輯，並確保在整合 P4 時不會遺漏關鍵環節。

---

## 階段一：掌握核心資料流與分發機制 (北向介面)
**目標**：理解上層 App (如 Web-GUI, Energy-Saving App) 的請求是如何進入 NDTwin，並被派發給對應的處理模組。

- [ ] **任務 1.1：追蹤 HTTP Dispatcher**
  - **目標檔案**：`src/ndt_core/http/HttpSession.cpp`
  - **觀察重點**：
    - 尋找 `handleRequest()` 中的 API 路由邏輯 (`if / else if (target == "...")`)。
    - 觀察 NDTwin 提供了哪些對外的 REST API。
    - 挑選 1-2 個 API（例如 `/ndt/install_meter_entry` 或 `/ndt/get_graph_data`），追蹤它們最後呼叫了哪個 Manager 類別的函式。
- [ ] **任務 1.2：理解 Event Bus 事件驅動模型**
  - **目標目錄**：`src/event_system/` 與 `src/ndt_core/event_handling/`
  - **觀察重點**：
    - 系統中有哪些核心事件（例如：鏈路斷線、發現新拓撲等）。
    - NDTwin 使用了發布/訂閱 (Pub/Sub) 模式來解耦各個模組。觀察 `EventBus.hpp` 是如何實作的，以及有哪些模組會監聽這些事件。

## 階段二：掌握資料收集與狀態維護 (狀態機)
**目標**：理解 NDTwin 如何建立並維持其「數位分身 (Digital Twin)」的網路狀態圖 (Graph)。

- [ ] **任務 2.1：剖析拓撲監控器 (Topology & Flow Monitor)**
  - **目標檔案**：`src/ndt_core/collection/TopologyAndFlowMonitor.cpp`
  - **觀察重點**：
    - 觀察 NDTwin 如何使用 `Boost.Graph` 函式庫來儲存節點 (Switch/Host) 與邊 (Link)。
    - 理解靜態拓撲的載入方式 (`loadStaticTopologyFromFile`) 以及與 Ryu 同步的動態更新機制 (`fetchAndUpdateTopologyData`)。
- [ ] **任務 2.2：理解流量收集機制 (sFlow / REST)**
  - **目標檔案**：`src/ndt_core/collection/FlowLinkUsageCollector.cpp`
  - **觀察重點**：
    - NDTwin 如何接收封包或詢問控制器來計算鏈路的即時頻寬使用率 (`linkBandwidthUsage`)。
    - 未來在 P4 環境中，您需要思考 BMv2 的 Telemetry 資訊要如何對接到這個收集器中。
- [ ] **任務 2.3：設備與電源管理**
  - **目標檔案**：`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`
  - **觀察重點**：
    - 觀察它如何定期向 Ryu 或硬體交換機發起狀態查詢（例如：讀取 OpenFlow Tables）。

## 階段三：掌握南向控制介面 (意圖下發)
**目標**：這是您未來修改的重頭戲。理解 NDTwin 目前如何透過 Ryu 控制底層 OpenFlow 網路。

- [ ] **任務 3.1：拆解路由與規則管理器**
  - **目標檔案**：`src/ndt_core/routing_management/FlowRoutingManager.cpp`
  - **觀察重點**：
    - 閱讀 `installAnEntry`, `deleteAnEntry` 等函式，理解 NDTwin 是如何將 C++ 的函式呼叫轉換成對 Ryu 的 REST API (透過 `curl` / `HTTP POST`) 請求。
    - 思考：您的 P4 Proxy Agent 將需要提供一組類似的 REST API 或 gRPC 介面來承接這些呼叫，並將其轉換為 P4Runtime 訊息。
- [ ] **任務 3.2：剖析現有的 Ryu Controller 邏輯**
  - **目標檔案**：根目錄的 `intelligent_router.py`
  - **觀察重點**：
    - 這個 Python 腳本是 NDTwin 的好夥伴（負責實作 OpenFlow 邏輯）。
    - 瀏覽裡面定義的 REST 路由 (`@route(...)`)，這正是 `FlowRoutingManager` 和 `TopologyAndFlowMonitor` 在呼叫的端點。
    - **P4 啟發**：您的 `P4-Proxy-Agent` 基本上就是在 P4 環境下取代 `intelligent_router.py` 的角色！

## 階段四：綜合演練與 P4 擴充準備
**目標**：將前面的知識串聯起來，為 P4 開發進行設計。

- [ ] **任務 4.1：走查完整的生命週期**
  - 挑選一個情境：**「當某條鏈路發生故障時，系統會發生什麼事？」**
  - 試著在程式碼中追蹤：
    1. 誰發現了故障？(TopologyMonitor)
    2. 發出了什麼 Event？(EventBus)
    3. 誰接收了 Event？(EventHandler)
    4. 誰呼叫南向介面刪除/新增規則？(FlowRoutingManager)
- [ ] **任務 4.2：定義 P4 Proxy Agent 介面規格 (API Spec)**
  - 根據在 `FlowRoutingManager` 與 `TopologyAndFlowMonitor` 中整理出來的 Ryu REST API，列出一份清單。
  - 設計您的 `P4-Proxy-Agent` 應該提供哪些相同的端點（或是新的端點），以讓 NDTwin 在最小幅度的修改下，能夠無縫切換到 P4 環境。

---
> [!NOTE]
> 建議您可以從 **階段一** 開始，在程式碼中用關鍵字搜尋或實際點擊追蹤。如果您在追蹤特定模組（例如 Boost.Graph 結構或是 HTTP 解析）時遇到困難，隨時可以請我為您講解特定的段落！
