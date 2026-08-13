# TopologyAndFlowMonitor.cpp 檔案架構與功能深度解析

`src/ndt_core/collection/TopologyAndFlowMonitor.cpp` 是整個 NDTwin (網路數位孿生) 系統的**「核心記憶體」**與**「地理資訊系統 (GIS)」**。

如果說 NDTwin 的目的是建立一個虛擬的網路分身，那麼這個檔案就是用來儲存並動態更新這個分身的最關鍵元件。所有的路由演算法、流量監控、耗電量計算，全部都必須依賴它所提供的地圖資訊。

以下為您詳細剖析這份破兩千行檔案的核心設計：

---

## 1. 核心資料結構：Boost.Graph (網路拓撲圖)

這份檔案的核心靈魂是一個名為 `m_graph` 的變數。
NDTwin 採用了 C++ 知名的高效能函式庫 **Boost.Graph (BGL)** 中的 `adjacency_list` 來實作網路拓撲。
* **頂點 (Vertices)**：代表網路中的設備。可能是 `VertexType::SWITCH` (交換機) 或 `VertexType::HOST` (終端主機)。記錄了設備的 DPID、MAC 位址、IP 位址、名稱 (Device Name/Nickname)、當前的耗電量等。
* **邊 (Edges)**：代表實體網路線 (Links)。記錄了連接的兩個 Port、鏈路的最大頻寬、目前剩餘頻寬 (leftBandwidth)、以及這條線上目前有哪些資料流 (`flowSet`)。

## 2. 併發與執行緒安全 (Concurrency & Thread Safety)

由於 NDTwin 是一個高度非同步的系統：
- `HttpSession` 可能隨時來讀取整張圖以繪製 Web-GUI。
- `FlowLinkUsageCollector` 可能每毫秒都在更新某條邊的剩餘頻寬。
- 網路卡斷線時需要立刻刪除某條邊。

因此，整個檔案充滿了 `std::shared_mutex m_graphMutex`。
它大量使用了 **讀寫鎖 (Read-Write Lock)** 的機制：
* **讀取時**：使用 `std::shared_lock`，允許無數個執行緒同時讀取地圖資訊（例如 `findSwitchByDpid`），不會互相阻塞。
* **寫入時**：使用 `std::unique_lock`，當拓撲發生改變或更新頻寬時，會短暫鎖住整張圖，確保資料一致性。

## 3. 拓撲發現機制 (Topology Discovery)

檔案中的 `run()` 函式會啟動一個背景執行緒，不斷執行 `fetchAndUpdateTopologyData()`。這裡實作了兩種截然不同的拓撲獲取策略，由 `m_mode` 決定：

### 3.1 遠端實體環境 (Remote Testbed Mode)
系統會將 Ryu Controller 當作拓撲的來源 (Source of Truth)。
它會定期透過 `curl` 發送 HTTP GET 到 Ryu 的 REST API：
- `/v1.0/topology/switches`
- `/v1.0/topology/links`
- `/v1.0/topology/hosts`
然後比對 Ryu 回傳的 JSON 與目前記憶體中的 `m_graph`，如果發現有新的交換機加入或鏈路斷線，就會在圖中進行新增或刪除，並透過 `EventBus` 發布 `LinkDownEvent` 或 `LinkUpEvent` 讓其他模組知道。

### 3.2 本地模擬環境 (Local Mininet Mode)
在 Mininet 模式下，為了加速模擬與穩定性，系統會直接讀取一個靜態的 JSON 拓撲設定檔（例如 `setting/StaticNetworkTopologyMininet_10Switches.json`），以此為基準來建構整張圖，而不再完全依賴 Controller 的動態發現。

## 4. 圖論演算法 (Graph Algorithms)

除了儲存資料，它還提供了一些基於圖的演算法，例如：
* **`getAllPathsBetweenTwoHosts()`**：這是一個經典的 **DFS (深度優先搜尋)** 演算法實作。當上層應用（如 QoS 路由）想要知道 A 節點到 B 節點有幾條實體路徑可走時，這個函式會遍歷所有 `isUp` 且 `isEnabled` 的邊，並回傳所有可能到達目的地的路徑組合。

---

> [!WARNING]
> **給 P4 開發者的重點總結：**
> 
> 在您將南向介面遷移到 P4 / BMv2 的過程中，**`fetchAndUpdateTopologyData()`** 是您「必須大改」的重點區域。
> 
> 1. **在 P4 環境下，您不能再呼叫 Ryu 的 `/v1.0/topology/*` API。**
> 2. P4Runtime 預設並沒有類似 OpenFlow 的 LLDP 拓撲發現機制。
> 3. **解決方案建議**：您必須在您的 Python `P4-Proxy-Agent` 中，自己實作一套基於 LLDP 或靜態設定檔的拓撲維護機制，並開放對等的 REST API 給 NDTwin Kernel 查詢。然後修改這個 C++ 檔案中的 `RYU_BASE_URL` 與相關的 JSON 解析邏輯，讓 NDTwin 改向您的 Proxy 詢問目前的 P4 網路長什麼樣子！
