# NDTwin-Kernel 模組詳細分析：HTTP Session (REST API 核心邏輯)

## 1. 模組概述
**路徑**：`include/ndt_core/http/`, `src/ndt_core/http/`
**主要類別**：`HttpSession`
**依賴函式庫**：Boost.Beast, Boost.Asio

`HttpSession` 是整個 NDTwin-Kernel 的業務邏輯路由器 (Business Logic Router)。它由 `ControllerAndOtherEventHandler` 在接收到 HTTP TCP 連線時被實例化，並持有整個系統所有核心 Manager 的指標。它負責解析 HTTP Request、配對 API 路由，並呼叫對應的後端模組執行操作，最後回傳 HTTP Response。

## 2. 核心機制

### 2.1 非同步 I/O 與生命週期
- 使用 Boost.Beast 的 `http::async_read` 與 `http::async_write` 進行全非同步 (Asynchronous) 的網路收發。
- 支援 HTTP Keep-Alive，允許同一個 TCP 連線連續送出多個 Request，降低建立連線的延遲開銷。

### 2.2 龐大的 API 路由表
在 `handleRequest()` 方法中，透過連續的 `if-else` 字串匹配 (String Matching) 實作了幾十個 RESTful API 端點。功能涵蓋：
- **拓樸與流量遙測**：`/ndt/get_graph_data`, `/ndt/get_detected_flow_data`, `/ndt/get_detected_top_k_flow_data` 等。
- **流表操作 (SDN)**：`/ndt/install_flow_entry`, `/ndt/delete_flow_entry`, `/ndt/modify_group_entry` 等。這些操作會轉拋給 `FlowRoutingManager` 處理，並透過 `respondToOpResult` 將南向控制器 (Southbound Controller) 的執行結果精準對應到 HTTP 狀態碼 (如 501 Not Implemented, 502 Bad Gateway)。
- **實體硬體狀態**：`/ndt/get_power_report`, `/ndt/get_cpu_utilization`, `/ndt/set_switches_power_state` 等。
- **意圖與擴充功能**：`/ndt/intent_translator/text` (對接大語言模型翻譯自然語言意圖)。
- **鎖機制 (Distributed Lock)**：`/ndt/acquire_lock`, `/ndt/renew_lock`, `/ndt/release_lock`。

### 2.3 延遲執行 (Offloaded Hooks)
透過 `after_write_` 機制，`HttpSession` 可以將一些較為耗時的後置處理，留待「回覆 HTTP 封包給客戶端之後」再透過 `std::thread(std::move(fn)).detach()` 以獨立執行緒非同步執行。這對於需要立即回傳 200 OK 以免客戶端 Timeout，但後台仍需處理繁重邏輯的場景非常有用。

## 3. 程式碼品質與技術債分析
- **優點**：
  - 完整擁抱 C++14/17 標準與 Boost Asio/Beast，提供了極高的效能天花板。
  - `respondToOpResult` 實作精良，不僅處理成功與失敗，甚至細分了 501 與 502 等狀態碼，使除錯更容易。
- **技術債與潛在風險**：
  - **God Class (上帝類別) 傾向**：`HttpSession` 在建構時傳入了多達 11 個不同子系統的 Manager 指標，且 `handleRequest` 包含了近 40 個 `if-else if` 判斷分支。這嚴重違反了單一職責原則 (SRP) 與開閉原則 (OCP)。建議引入路由註冊表 (Router Registry) 的設計，將各個 API 端點的實作打散到對應的 Controller 類別中。
  - **URL 參數解析脆弱**：程式碼中大量使用了自製的 `get_param` Lambda 函數去手動切割字串來解析 Query String (`?ip=...&action=...`)。這類手寫解析器極易產生邊界條件錯誤或被惡意構造的 URL 造成無限迴圈，建議改用標準庫或 Beast 內建的 URL 解析工具。
