# NDTwin-Kernel 模組詳細分析：FlowLinkUsageCollector

## 1. 模組概述
**路徑**：`include/ndt_core/collection/FlowLinkUsageCollector.hpp`
**主要類別**：`FlowLinkUsageCollector` (位於 `sflow` 命名空間)

`FlowLinkUsageCollector` 是網路效能監測的心臟。它專門負責接收並解析透過 UDP (Port 6343) 傳送過來的 sFlow 封包 (Data Samples 與 Counter Samples)，並基於這些資料計算出即時的鏈路頻寬使用率 (Link Usage) 以及還原網路流 (Flows) 經過的確切路徑。

## 2. 依賴關係
- **內部模組**：`TopologyAndFlowMonitor`, `FlowRoutingManager`, `DeviceConfigurationAndPowerManager`, `EventBus`, `ndtClassifier::Classifier`。
- **通訊與結構**：`SPSCQueue` (Lock-free Queue 用於高吞吐量封包傳遞)。

## 3. 執行緒模型
該模組是一個極高強度的多執行緒 (Multi-threaded) 系統，其內部啟動了多種 Worker 執行緒：
1.  **`m_pktRcvThread`** (RX Thread)：專注於以 `recvmmsg` 從 UDP Socket 批次接收 sFlow 封包，並以 Round-Robin 方式將封包塞入 Lock-free 的 `SPSCQueue` 佇列。
2.  **`m_workers`** (Worker Threads)：根據 CPU 核心數 (`numWorkers`) 建立。每個 Worker 從自己的 Queue 中取出封包進行深度解析與流量累積。
3.  **週期性排程**：`m_calAvgFlowSendingRateThreadPeriodically` 負責定時結算平均速率；`m_purgeThread` 負責清除逾期空閒的 Flow (Idle Flows)。
4.  **同步機制**：`m_flowInfoTable` 與 `m_counterReports` 等全域快取表被 `std::shared_mutex` 高度保護，確保背景收集與前端 API 查詢的安全。

## 4. API 方法清單與公開方法說明

### API 方法清單
- `void start(size_t numWorkers, size_t queueCapacity)`
- `void stop()`
- `std::unordered_map<FlowKey, FlowInfo, FlowKeyHash> getFlowInfoTable()`
- `nlohmann::json getFlowInfoJson()` / `getTopKFlowInfoJson(int k)`
- `void setAllPaths(std::vector<sflow::Path> allPathsVector)`
- `std::optional<size_t> getSwitchCount(std::pair<uint32_t, uint32_t> ipPair)`
- 輔助操作：`getAllSwitchCounts`, `getPathBetweenHostsJson`

### 公開方法說明
*   **`start(size_t numWorkers, size_t queueCapacity)`**
    初始化 UDP Socket (非阻塞)，並啟動上述所有接收、分析與清理的背景執行緒。佇列設有容量限制 (`queueCapacity`) 以防止背壓 (Backpressure) 導致記憶體耗盡。
*   **`getFlowInfoJson()` / `getTopKFlowInfoJson(int k)`**
    將記憶體中龐大的 Flow 資訊轉換為 JSON 格式，供外部儀表板 (Dashboard) 呼叫。`getTopKFlowInfoJson` 在大流量場景下能大幅降低 JSON 序列化的開銷，只回傳頻寬佔用前 K 大的象流 (Elephant Flows)。
*   **`setAllPaths(...)` / `getAllPaths(...)`**
    提供給控制器更新或查詢已知端到端 (End-to-End) 路徑的介面。當控制器更改了路由流表，會同步更新這裡的資訊，使流量監控能準確對應實體路徑。
