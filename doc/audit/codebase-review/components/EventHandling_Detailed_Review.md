# NDTwin-Kernel 模組詳細分析：Event Handling (事件處理與 API 閘道)

## 1. 模組概述
**路徑**：`include/ndt_core/event_handling/`, `src/ndt_core/event_handling/`
**主要類別**：`ControllerAndOtherEventHandler`
**設計模式**：API Gateway / Embedded Web Server (Boost.Asio/Beast)

`ControllerAndOtherEventHandler` 是 NDTwin-Kernel 與外部系統（如 Mininet 腳本、Web UI、測試腳本）溝通的主要介面。它在內部啟動一個 HTTP Server 監聽 Port 8000，接收外部的 REST API 請求，並將這些請求分派給系統內部的各個核心 Manager。

## 2. 核心架構與生命週期

### 2.1 伺服器啟動與執行緒模型
- **啟動 (`start`)**：
  呼叫 `start()` 時，會建立一個 `tcp::acceptor` 綁定至 `NDT_PORT (8000)`，並生成一個獨立的背景執行緒 `m_serverThread` 來執行 `runServer()`。
- **接受連線 (`runServer` & `doAccept`)**：
  - `runServer()` 會啟動一個基於硬體執行緒數量 (`std::thread::hardware_concurrency()`) 的 Thread Pool，讓 `m_ioContext.run()` 在多個執行緒中並行執行，提供高併發處理能力。
  - `doAccept()` 使用非同步接受 (`async_accept`)，當有新連線時，實例化一個 `HttpSession` 物件並呼叫 `start()` 處理 HTTP 請求，隨後遞迴呼叫 `doAccept()` 繼續監聽。
- **優雅停機 (`stop`)**：
  - 先呼叫 `m_ioContext.stop()`，關閉 acceptor，並對所有活動中的 Socket (`m_activeSockets`) 發送 shutdown 與 close。
  - 為了喚醒可能卡在 accept 系統呼叫中的執行緒，採用了 "poke" 機制：主動向 `127.0.0.1:8000` 發起一次連線。
  - 最後 `join()` 伺服器執行緒，確保資源完全釋放。

### 2.2 HttpSession (HTTP 請求處理)
雖然 `ControllerAndOtherEventHandler` 負責連線的接收與生命週期管理，但實際的 HTTP Request 路由與處理是由 `HttpSession` (位於 `ndt_core/http/HttpSession.hpp`，依賴注入) 來完成。
`ControllerAndOtherEventHandler` 在建構時接收了系統所有核心 Manager 的 `shared_ptr`（如 Topology, FlowCollector, RoutingManager, IntentTranslator, ApplicationManager 等），並在接受連線時將這些指標傳遞給 `HttpSession`，使其具備調用系統功能的能力。

## 3. 模組職責
1. **API Gateway**：作為 NDTwin-Kernel 的單一外部入口點。
2. **生命週期與執行緒管理**：負責 Boost.Asio `io_context` 的維護、Thread Pool 的建立與優雅關閉。
3. **依賴注入容器 (DI Container)**：集中持有各子系統的參考，並傳遞給每次的新連線 (Session)，確保業務邏輯元件能被正確呼叫。

## 4. 程式碼品質與安全性分析
- **優點**：
  - 使用 Boost.Asio 提供的高效非同步 I/O 搭配 Thread Pool，理論效能極高。
  - 關機流程 (`stop()`) 非常嚴謹，考慮到了中止 Acceptor、清理 Active Sockets 以及針對舊版/特定系統的 Poke 機制，防止 Zombie 執行緒。
- **安全性與技術債**：
  - HTTP Server 未見任何 TLS/SSL 加密 (HTTPS) 的設定，資料以明文傳輸。
  - 沒有 Auth (Authentication/Authorization) 機制，內部所有的 Manager 功能（包含關閉交換機電源、修改路由）皆向任何能連到 Port 8000 的客戶端開放。對於一個具備實際硬體控制能力（如 Smart Plug 斷電）的系統而言，這是極高的資安風險。
  - `parseFlowStatsText` 會攔截並處理 JSON 解析異常，這有助於防止 Crash，但該函數似乎與 API Server 生命週期無直接相關，放在這裡有點違反單一職責原則 (Single Responsibility Principle)。
