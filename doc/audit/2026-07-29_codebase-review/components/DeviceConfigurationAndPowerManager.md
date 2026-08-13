# NDTwin-Kernel 模組詳細分析：DeviceConfigurationAndPowerManager

## 1. 模組概述
**路徑**：`include/ndt_core/power_management/DeviceConfigurationAndPowerManager.hpp`
**主要類別**：`DeviceConfigurationAndPowerManager`

`DeviceConfigurationAndPowerManager` 是整個 NDTwin 系統管理實體硬體狀態的核心。它提供統一的介面來查詢與切換交換機的電源狀態，並定期收集設備的健康遙測數據（電源、CPU、記憶體、溫度），以及快取交換機的 OpenFlow 流表快照。

## 2. 依賴關係
- **內部模組**：`TopologyAndFlowMonitor`, `ndtClassifier::Classifier`。
- **策略模式介面**：`IPowerStrategy` (支援實體環境 TESTBED 透過 Smart Plug，以及模擬環境 MININET)。
- **外部函式庫**：`nlohmann/json`。

## 3. 執行緒模型
本模組利用背景執行緒維護了全域的設備狀態快取，將前端查詢與後端耗時操作解耦：
- **`m_statusUpdateThread`**：負責定期輪詢各設備的 CPU、記憶體、溫度與電源狀態，並更新至記憶體快取。
- **`m_openflowTablesUpdateThread`**：定期取得 OpenFlow 流表的快照。
- **`m_pingThread`**：作為基礎的連通性/存活狀態 (Liveness) 檢測。
- **同步機制**：採用 `std::shared_mutex` (`m_statusMutex`, `m_openflowTablesMutex`) 保護快取資料。前端 HTTP API 查詢時僅需取得 Read Lock，極大化了系統在高併發查詢下的效能。

## 4. API 方法清單與公開方法說明

### API 方法清單
- `void start()` / `void stop()`
- `json getSwitchesPowerState(const std::string& target)`
- `bool setSwitchPowerState(std::string ip, std::string action, SwitchInfo si)` / `(const std::string& ip, const std::string& action)`
- 遙測狀態查詢：`getPowerReport`, `getMemoryUtilization`, `getCpuUtilization`, `getTemperature`, `getOpenFlowTables`
- `void updateOpenFlowTables(const json& j)`

### 公開方法說明
*   **`start()` / `stop()`**
    啟動與優雅關閉所有的背景遙測輪詢與快取更新執行緒。
*   **`setSwitchPowerState(...)`**
    開關特定交換機的電源。會透過 `getPowerStrategyForDpid` 選擇合適的南向策略，例如呼叫物聯網 API (Smart Plug/Gateway) 來切斷實體電源，或是呼叫 Mininet 腳本。
*   **`getPowerReport()` / `getCpuUtilization()` 等等**
    這些方法直接從內部快取的 `m_cachedPowerReport` 或 `m_cachedCpuReport` 中讀取資料，並以 JSON 回傳。這保證了前端 API 回應延遲保持在微秒級別，而不用等待緩慢的網路硬體回應。
