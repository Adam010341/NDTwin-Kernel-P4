# FlowRoutingManager.cpp 檔案架構與功能深度解析

相比於前面動輒上千行的 `TopologyAndFlowMonitor` 或 `FlowLinkUsageCollector`，這份 `src/ndt_core/routing_management/FlowRoutingManager.cpp` 非常簡潔，只有不到 200 行。

但它在 NDTwin 系統中卻是**「發號施令的總指揮官」**。上層任何的網路意圖（包含 AI 節能路由、QoS 保障、基本連線建立），最終都會轉換成對這個檔案的函式呼叫，藉此真正改變底層網路的行為。

以下為您詳細剖析這份檔案的核心設計與您的未來修改方向：

---

## 1. 核心定位：純粹的南向介面封裝 (Southbound API Wrapper)

這份檔案沒有任何複雜的演算法，也沒有維護任何背景狀態機。它就是一個純粹的 API Wrapper。
它將上層傳遞下來的參數（DPID、Priority、Match Rules、Actions 等 JSON 物件）打包，然後透過系統呼叫 `utils::execCommand`，執行一長串的 `curl` 指令，將這些意圖發送給 Ryu Controller 的 REST API。

## 2. 支援的 OpenFlow 功能

從程式碼中可以看出，NDTwin Kernel 深度使用了 OpenFlow 協定的幾項進階功能來達成流量工程 (Traffic Engineering)：

* **Flow Entry (流表項)**：`installAnEntry`, `deleteAnEntry`, `modifyAnEntry`
  用來設定基本的轉發規則（如果 Match 到特定 IP/Port，就從哪個 Output Port 出去）。
* **Group Entry (群組表項)**：`installAGroupEntry`, `deleteAGroupEntry`
  這是 OpenFlow 1.3 的進階功能。通常用於「多路徑負載均衡 (ECMP)」或是「快速容錯備援 (Fast Failover)」。上層可以設定一個 Group ID，然後把 Flow Entry 的 Action 指向這個 Group。
* **Meter Entry (計量表項)**：`installAMeterEntry`, `deleteAMeterEntry`
  這同樣是 OpenFlow 1.3 的功能。Meter Table 用來執行「流量限速 (Rate Limiting / QoS)」。當某些流量超過我們設定的頻寬門檻時，Meter 可以直接將多出來的封包 Drop 掉，以此保障網路的服務品質。

---

> [!WARNING]
> **給 P4 開發者的重點總結：這是您未來工作的最核心戰場！**
> 
> 在您接下來要進行的 P4/BMv2 整合任務中，這個檔案是您**第一個，也是最重要需要修改的目標**。
> 
> 1. **指令寫死 (Hardcoded `curl`)**：目前這份程式碼每一行都寫死了 `AppConfig::RYU_IP_AND_PORT`。在 P4 模式下（由 `main.cpp` 傳入的 `m_mode`），您不能再將指令發給 Ryu。
> 2. **協定不相容**：P4Runtime 沒有所謂的 "Group Table" 或是 "Meter Table" 的標準 REST API。您在編寫 Python `P4-Proxy-Agent` 時，必須自己定義一套對應的 REST API。
> 3. **實作建議 (Strategy Pattern)**：
>    強烈建議您不要在這個檔案裡塞滿 `if (m_mode == P4) { ... } else { curl ... }`。
>    比較優雅的作法是：定義一個南向通訊介面類別 (`ISouthboundClient`)，然後實作兩個版本：
>    - `RyuSouthboundClient` (保留目前的 curl 邏輯)
>    - `P4ProxySouthboundClient` (負責向您的 Python Proxy 發送 HTTP 或 gRPC 請求)
>    最後在建構子中，根據 `m_mode` 注入對應的 Client 來發送指令。
