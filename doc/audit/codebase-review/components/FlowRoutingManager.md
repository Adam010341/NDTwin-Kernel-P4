# NDTwin-Kernel 模組詳細分析：FlowRoutingManager

## 1. 模組概述
**路徑**：`include/ndt_core/routing_management/FlowRoutingManager.hpp`
**主要類別**：`FlowRoutingManager`

`FlowRoutingManager` 負責控制平面 (Control Plane) 的路由演算與流表下發。它會將高階的 JSON 路由與政策指令 (如建立路徑、群播)，根據交換機的資料平面類型，轉換為對應南向 API (Southbound API) 控制器能懂的操作指令，並發送 HTTP Request。

## 2. 依賴關係
- **內部模組**：`TopologyAndFlowMonitor`, `sflow::FlowLinkUsageCollector`, `EventBus`。
- **策略模式介面**：`IRoutingStrategy` (實作包含 `m_ovsStrategy` 與 `m_p4Strategy`)。
- **外部函式庫**：`nlohmann/json` 用於封裝流表匹配與動作 (Match/Action)。

## 3. 執行緒模型
`FlowRoutingManager` 本身是**無狀態 (Stateless)** 或唯讀狀態的模組，並**未直接啟動任何背景執行緒**。
它的所有操作都是在呼叫者 (如 `HttpSession` 的 API Handler 執行緒) 的當前執行緒中同步執行的。依賴的底層資料結構 (如 `TopologyAndFlowMonitor`) 則透過它們自己的互斥鎖提供執行緒安全的查詢。

## 4. API 方法清單與公開方法說明

### API 方法清單
- `OpResult installAnEntry(uint64_t dpid, int priority, const json& match, const json& action, int idleTimeout)`
- `OpResult modifyAnEntry(...)`
- `OpResult deleteAnEntry(uint64_t dpid, const json& match, int priority)`
- 群組操作：`installAGroupEntry`, `deleteAGroupEntry`, `modifyAGroupEntry`
- Meter 操作：`installAMeterEntry`, `deleteAMeterEntry`, `modifyAMeterEntry`

### 公開方法說明
*   **`installAnEntry(...) / modifyAnEntry(...) / deleteAnEntry(...)`**
    針對指定的 `dpid` 進行 OpenFlow (或 P4) 的流表規則安裝、修改與刪除。該方法內部會呼叫 `getStrategyForDpid` 來動態決定該使用 OVS 還是 BMv2 P4 的南向介面策略。
*   **`installAGroupEntry(...)` 及相關 Group/Meter 操作**
    針對進階功能 (群播、流量監管) 進行設定。這些方法內部使用 `dispatchByPayloadDpid`，能夠從 JSON 負載中解析出目標 DPID，並進行正確的策略路由 (Strategy Routing)。
*   **`getStrategyForDpid(uint64_t dpid)` (Protected)**
    這是一個關鍵的 O(1) 工廠方法。它向 `TopologyAndFlowMonitor` 詢問該 DPID 屬於何種資料平面，並傳回對應的 `IRoutingStrategy`。這避免了在混和網路環境中錯誤地下發 OVS 指令給 P4 設備。
