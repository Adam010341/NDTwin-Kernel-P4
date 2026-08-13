# intelligent_router.py 檔案架構與功能深度解析

在我們看完了 NDTwin Kernel 的各種 C++ 模組後，現在我們來看看系統的另一半——**`intelligent_router.py` (Ryu 控制器應用程式)**。

如果說 NDTwin Kernel (C++) 是一個負責大局觀的「大腦」，那麼這個 Python 檔案就是負責實際控制底層網路、佈建規則的**「神經中樞」**。它獨立於 NDTwin Kernel 運行，並透過 REST API 與之互動。

以下為您詳細剖析這份檔案的核心設計：

---

## 1. 核心定位：OpenFlow 網路的直接管理者

這個檔案繼承了 `app_manager.RyuApp`，是一支標準的 Ryu 應用程式。它透過 OpenFlow 1.3 協定直接與 OVS (或實體交換機) 溝通。
它的核心職責包含：
* **下發 Table-Miss 規則** (`switch_features_handler`)：確保未知封包會被送到 Controller 處理 (Packet-In)。
* **下發轉發規則** (`add_flow`)：真正把 Match-Action 寫入硬體的底層 API。
* **封包處理** (`_packet_in_handler`)：過濾掉 LLDP、mDNS 等不需要的封包，並利用 ICMP (Ping) 封包來發現尚未被記錄的 Host (終端主機)。

## 2. 拓撲維護與路由預佈建 (Proactive Routing)

與 NDTwin Kernel 內部維護一張大圖相似，這個檔案也使用 `networkx.DiGraph()` 維護著自己的網路拓撲圖。

### 2.1 拓撲載入與發現
* **靜態拓撲 (`load_static_topology`)**：如果是 Mininet 模式，它會優先讀取與 C++ 端相同的 `StaticNetworkTopologyMininet_10Switches.json`，藉此與 NDTwin Kernel 保持視角一致。
* **動態發現 (`get_topology_data`)**：如果沒有檔案，它會透過 Ryu 內建的 LLDP 機制自動掃描網路中的節點與連線。

### 2.2 路由佈建 (`install_all_pair_paths`)
這是這個檔案最複雜的演算法部分。它不會等到封包進來才去找路徑 (Reactive Routing)，而是**預先 (Proactive)** 替網路上所有的 Host 算好所有的路徑。
它使用了 **BFS (廣度優先搜尋)** 演算法來尋找最短路徑。有趣的是，程式碼中還實作了 `is_all_dst_biased` 功能，這是一種簡易的 ECMP (Equal-Cost Multi-Path) 負載均衡機制，用來打亂相同距離的鄰居順序，避免所有流量擠在同一條路上。

## 3. 與 NDTwin Kernel 的雙向通訊

這個檔案最關鍵的設計在於它與 NDTwin Kernel 之間緊密的雙向 API 綁定：

### 3.1 Ryu 主動通知 NDTwin (Event Webhooks)
當網路發生變化時，Ryu 會主動發送 HTTP Request 到 NDTwin Kernel (Port 8000)：
* **Switch 上線** (`EventSwitchEnter`)：發送 GET `/ndt/inform_switch_entered`
* **Link 斷線** (`EventLinkDelete`)：發送 POST `/ndt/link_failure_detected`
* **Link 恢復** (`EventLinkAdd`)：發送 POST `/ndt/link_recovery_detected`

### 3.2 Ryu 開放 API 供 NDTwin 查詢
透過繼承 `ControllerBase` 與 `wsgi.register`，這支程式在 Ryu 預設的 8080 Port 開啟了一個 Web Server，並提供了一個重要介面：
* **`GET /ryu_server/all_destination_paths`**：這個 API 就是我們在分析 `FlowLinkUsageCollector.cpp` 時看到的。NDTwin 必須呼叫這個 API，才能知道「剛剛算出來的路由路徑到底是怎麼走的」，藉此推算頻寬消耗。

---

> [!WARNING]
> **給 P4 開發者的重點總結：這就是您未來的 `P4-Proxy-Agent` 的藍圖！**
> 
> 在您即將開發的 `P4-Proxy-Agent` 中，您必須「完全取代」這份 `intelligent_router.py` 的角色：
> 
> 1. **南向介面**：您需要引入 `p4runtime_lib` (或是直接使用 grpc)，取代掉這邊的 Ryu API (`add_flow`, `_packet_in_handler`) 來控制 BMv2 交換機。
> 2. **北向 API 相容性 (極為重要)**：為了讓 NDTwin Kernel (C++) 不需要大幅修改就能無縫接軌，您的 P4-Proxy 必須實作**完全一模一樣的 REST API 行為**。例如：
>    - 提供 `GET /ryu_server/all_destination_paths`。
>    - 提供 `POST /stats/flowentry/add` (取代原本在 `FlowRoutingManager` 中寫死的呼叫)。
>    - 在 P4 網路拓撲改變時，主動打 `/ndt/link_failure_detected` 等 webhook 通知 C++ 核心。
