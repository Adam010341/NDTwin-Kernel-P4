# NDTwin-Kernel 模組詳細分析：ControllerAndOtherEventHandler

## 1. 模組概述
**路徑**：`include/ndt_core/event_handling/ControllerAndOtherEventHandler.hpp`
**主要類別**：`ControllerAndOtherEventHandler`

`ControllerAndOtherEventHandler` 是 NDTwin-Kernel 的 API 閘道 (API Gateway)。它封裝了一個基於 Boost.Asio 與 Boost.Beast 的輕量級非同步 HTTP 伺服器，負責監聽 NDT_PORT (預設 8000)，並將傳入的 RESTful 請求分派給對應的 Manager (例如 Topology Monitor、Routing Manager 等等)。

## 2. 依賴關係
- **Boost 函式庫**：Boost.Asio (`io_context`, `tcp`), Boost.Beast (HTTP 解析與封裝)。
- **內部模組**：依賴**幾乎所有的**核心模組 (包含 `TopologyAndFlowMonitor`, `FlowRoutingManager`, `EventBus`, `IntentTranslator`, `DeviceConfigurationAndPowerManager`, `ApplicationManager`, 等等)。它是系統整合的最高層級類別。

## 3. 執行緒模型
採用了標準的 Boost Asio 非同步事件迴圈模型：
- **`m_serverThread`**：這是一條獨立的執行緒，執行 `m_ioContext.run()`。所有的 HTTP 連線接受 (`doAccept`)、請求讀取與回覆寫入，都是在這條執行緒中以非同步回调 (Callback) 方式執行。
- **連線管理同步**：由於伺服器允許隨時優雅關閉 (`stop`)，它維護了一個啟用的 Socket 集合 (`m_activeSockets`)。這個集合由互斥鎖 (`m_socketsMutex`) 保護，避免 Socket 被併發存取時發生崩潰。

## 4. API 方法清單與公開方法說明

### API 方法清單
- `void runServer()`
- `void start()`
- `void stop()`
- `json parseFlowStatsText(const std::string& responseText)`

### 公開方法說明
*   **`start()`**
    啟動 HTTP 伺服器的背景執行緒 (`m_serverThread`) 並開始監聽埠口。這是系統初始化的最後一步。
*   **`runServer()`**
    繫結 TCP Acceptor 並開始非同步等待第一筆連線 (`doAccept`)。通常由 `start()` 內部呼叫。
*   **`stop()`**
    優雅地關閉伺服器。會關閉 Acceptor，中斷所有記錄在 `m_activeSockets` 內的活躍連線，並等待 `m_serverThread` 結束 (Join)，確保資源徹底釋放。
