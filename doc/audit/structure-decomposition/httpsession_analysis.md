# HttpSession.cpp 檔案架構與功能深度解析

`src/ndt_core/http/HttpSession.cpp` 是 NDTwin Kernel 中極為關鍵的一個檔案。如果您把 NDTwin 視為一個伺服器大腦，那這個檔案就是**「大腦對外的聽覺與視覺中樞」 (北向介面 API Gateway)**。

以下為您詳細剖析這份檔案的功能與架構設計：

---

## 1. 核心定位與職責 (Core Responsibilities)

`HttpSession` 扮演的是 **Dispatcher (分發器)** 與 **HTTP Server** 的角色。
它負責接收來自上層應用程式 (App, Web-GUI 等) 的所有 HTTP REST API 請求，將其解碼，然後像交通警察一樣，把請求精準地派發給 Kernel 內部對應的具體 Manager 進行處理，最後將處理結果封裝成 HTTP Response 回傳給客戶端。

## 2. 架構設計：依賴注入 (Dependency Injection)

從檔案最上方的建構子 (Constructor) 可以看出其架構設計：
```cpp
HttpSession::HttpSession(
    tcp::socket socket,
    std::shared_ptr<TopologyAndFlowMonitor> topologyAndFlowMonitor,
    std::shared_ptr<EventBus> eventBus,
    // ... 以及大量其他的 Manager 指標 ...
    std::shared_ptr<FlowRoutingManager> flowRoutingManager,
    std::shared_ptr<DeviceConfigurationAndPowerManager> deviceConfigurationAndPowermanager,
    // ...
)
```
這是一種典型的**依賴注入 (Dependency Injection) 設計模式**。`HttpSession` 本身並不實作任何網路路由計算或拓撲更新的業務邏輯，它只是持有所有 Manager 的指標 (Pointer)。這樣做的好處是將「網路通訊處理」與「業務邏輯」完美解耦 (Decoupling)。

## 3. 非同步 HTTP 處理生命週期 (Async Pipeline)

NDTwin 底層採用了 `Boost.Beast` 與 `Boost.Asio` 來實作非同步高效能網路。一個請求的生命週期如下：

1. **`start()` / `readRequest()`**：啟動非同步讀取。
2. **`onRead()`**：當封包接收完畢後觸發。如果是合法的請求，轉交給 `handleRequest()`。
3. **`handleRequest()`**：**這是整份檔案最核心的函式**。
   - 自動補上 **CORS Headers** (如 `access_control_allow_origin: *`)，確保 Web 前端可以直接呼叫不被瀏覽器擋下。
   - 透過一系列的 `if-else if` 判斷 HTTP Method (GET/POST) 與 URL `target()`。
   - 將請求導向對應的私有函式（如 `handleGetGraphData()`）。
4. **`writeResponse()` / `onWrite()`**：將準備好的 Response 轉成位元流寫回 Socket，並根據 Keep-Alive 決定是否關閉連線或繼續聽取下一個請求。

## 4. API 路由與分發邏輯 (API Routing)

在 `handleRequest()` 中定義了龐大的 API 路由表。我們可以將這些 API 分類，這也直接對應了 NDTwin Kernel 支援的豐富功能：

* **拓撲與流量監控 (Topology & Traffic)**
  - `/ndt/get_graph_data`：取得全網節點與鏈路的圖結構。
  - `/ndt/get_detected_flow_data`：取得 sFlow 偵測到的即時流量。
* **路由與規則控制 (Routing Control / 南向介面觸發點)**
  - `/ndt/install_flow_entry`, `/ndt/delete_flow_entry`, `/ndt/modify_group_entry` 等。
  - **這正是您在開發 P4 Proxy 時需要特別關注的地方**。目前的實作會呼叫 `m_flowRoutingManager` 轉為 OpenFlow。
* **設備與電源管理 (Device & Power)**
  - `/ndt/get_power_report`：取得設備耗電量。
  - `/ndt/set_switches_power_state`：喚醒或關閉實體 Switch 的 Smart Plug。
* **意圖翻譯與 AI 整合 (Intent Translation)**
  - `/ndt/intent_translator/text`：將使用者的自然語言提示 (Prompt) 轉發給 `m_intentTranslator` 進行 LLM 轉換。
* **鎖與並行控制 (Concurrency Control)**
  - `/ndt/acquire_lock`, `/ndt/release_lock`：在分散式或多 App 環境中協調資源互斥。

## 5. 資料解析與例外處理 (Parsing & Error Handling)

幾乎所有的 `handleXxx` 函式都有標準的處理樣板：
1. **日誌記錄**：使用 `SPDLOG_LOGGER_INFO` 記錄 API 觸發。
2. **JSON 解析**：使用 `nlohmann::json::parse(m_req.body())` 嘗試解析 Body。如果前端傳來錯誤的格式，會由最外層的 `try-catch` 捕捉，並統一回傳 `400 Bad Request`。
3. **參數提取**：有時也會解析 URL 中的 Query Parameters（例如在 `handleGetNickname` 中自己手寫了 `get_param` lambda 函式來解析 `?dpid=123`）。
4. **例外防護 (Catch-all)**：
```cpp
catch (const json::exception& e) { /* 處理 400 Bad Request */ }
catch (const std::exception& e)  { /* 處理 500 Internal Server Error */ }
catch (...)                      { /* 處理未知錯誤 */ }
```
這確保了即使某個 Manager 內部發生了崩潰或丟出錯誤 (Exception)，Kernel 的 HTTP 伺服器也不會輕易掛掉，而是優雅地回傳錯誤給 Client。

---

> [!WARNING]
> **P4 整合建議：**
> 作為 NDTwin 系統對外的「守門員」，`HttpSession.cpp` 非常適合用來作全局的攔截。如果您要導入 P4 模式，您可以在 `handleInstallFlowEntry` 這些路由控制 API 的入口處，加入判斷：
> 
> ```cpp
> if (m_mode == utils::DeploymentMode::P4_MODE) {
>     // 轉發給您的 P4 Proxy Agent
> } else {
>     // 原有的 OpenFlow 邏輯
>     m_flowRoutingManager->installAnEntry(...);
> }
> ```
> 這樣可以最大程度地保留原有系統的穩定性，並優雅地擴充 P4 功能。
