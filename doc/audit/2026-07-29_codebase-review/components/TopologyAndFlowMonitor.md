# NDTwin-Kernel 模組詳細分析：TopologyAndFlowMonitor

## 1. 模組概述
**路徑**：`include/ndt_core/collection/TopologyAndFlowMonitor.hpp`
**主要類別**：`TopologyAndFlowMonitor`

`TopologyAndFlowMonitor` 負責維護全域的網路拓樸結構 (Network Topology)，並管理設備 (Switches, Hosts) 與鏈路 (Links) 的狀態與屬性。它採用 Boost Graph Library (BGL) 將網路抽象化為圖形結構。

## 2. 依賴關係
- **Boost Graph Library (BGL)**：用於維護網路拓樸 (`Graph`, `vertex_descriptor`, `edge_descriptor`)。
- **內部模組**：`EventBus`, `AppConfig`。
- **外部函式庫**：`nlohmann/json`。

## 3. 執行緒模型
本模組具有高度的併發性，並維護多個背景執行緒：
- **`m_thread` (監控執行緒)**：負責定期從控制器 (如 Ryu 或 P4 Proxy) 拉取並更新拓樸狀態。
- **`m_flushEdgeFlowLoop` (清理執行緒)**：定期清理失效或過期的流 (Stale flows)。
- **同步機制**：大量的公開方法皆分為 `...NoLock` 與一般版本。一般版本內部會使用 `std::shared_mutex` 進行讀寫鎖定，確保在背景執行緒更新拓樸時，其他模組 (如 REST API) 能夠安全地進行唯讀查詢。`m_dpidToSwitchKind` 等關鍵資料結構亦有專屬的鎖 (`m_switchKindMutex`) 保護。

## 4. API 方法清單與公開方法說明

### API 方法清單
- `void start()`
- `void stop()`
- `void logGraph()`
- `void updateLinkInfo(...)`
- 節點與邊查詢：`findVertexByIp`, `findEdgeBySrcAndDstDpid`, `findSwitchByDpid`, `getSwitchKind`, etc. (皆具備 `NoLock` 版本)
- 狀態修改：`setEdgeDown`, `setEdgeUp`, `setVertexEnable`, etc.
- 路由演算：`getAllPathsBetweenTwoHosts`, `bfsAllPathsToDst`
- 遙測資料取得：`getStaticTopologyJson`, `getTopKCongestedLinksJson`

### 公開方法說明
*   **`start() / stop()`**
    啟動與停止拓樸監控與流表清理的背景執行緒。
*   **`findSwitchByDpid(uint64_t dpid)` / `getSwitchKind(uint64_t dpid)`**
    根據 DPID 查詢交換機節點，或以 O(1) 複雜度獲取交換機的底層協議種類 (如 OVS 或 BMv2)。後者在熱路徑 (Hot Path) 上的效能至關重要。
*   **`getAllPathsBetweenTwoHosts(...)` / `bfsAllPathsToDst(...)`**
    利用圖論演算法 (如 BFS) 尋找兩個端點之間的所有可能路徑，為多重路徑路由與備援切換提供計算基礎。
*   **`setEdgeDown(Graph::edge_descriptor e)` / `setEdgeUp(...)`**
    手動或透過事件觸發更改特定網路邊 (Edge) 的連線狀態，這通常會連帶觸發 `EventBus` 進行全域廣播。
