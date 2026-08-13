# NDTwin-Kernel 模組詳細分析：Power Management (電源與設備狀態管理)

## 1. 模組概述
**路徑**：`include/ndt_core/power_management/`, `src/ndt_core/power_management/`
**主要類別**：`DeviceConfigurationAndPowerManager`, `IPowerStrategy`, `OVSPowerStrategy`, `P4PowerStrategy`
**設計模式**：策略模式 (Strategy Pattern)、Worker Thread (定時任務)

`DeviceConfigurationAndPowerManager` 模組負責網路交換機（Switch）的狀態監控與電源控制。它不僅處理實體層級的開關機操作（如透過 Smart Plug 智慧插座），還定時採集設備的硬體健康指標（CPU、記憶體、溫度）與 OpenFlow 表格快取。

## 2. 核心架構與機制

### 2.1 雙軌部署模式 (Deployment Mode)
根據啟動時的參數 `m_mode`：
- **TESTBED 模式**：針對實體硬體。透過 `pingWorker` 每秒進行 ICMP Ping 測試設備存活；電源控制則是發送 HTTP 請求給配置的 Smart Plug Gateway (`/relay`) 進行實體斷電/復電。硬體遙測資料會透過 SNMP 協定 (如 HPE 或 Brocade 交換機) 或 SSH 進行收集。
- **MININET 模式**：針對虛擬環境。主要與本機的 Mininet 與 OVS 互動，透過 `sudo ovs-vsctl list-br` 來檢查 OVS 虛擬交換機是否存在，電源管理則是虛擬狀態操作，硬體指標則採用假資料 (Dummy data) 或隨機生成。

### 2.2 非同步背景更新與快取機制
此模組啟動了多個背景 Worker Threads：
1. **`pingWorker`**：負責網路存活性 (Liveness) 偵測。若設備未回應，會通知拓樸模組將節點設為 Down。
2. **`statusUpdateWorker`**：定時執行 `fetchPowerReportInternal`, `fetchMemoryReportInternal` 等，將採集到的龐大資料轉為 JSON 快取，寫入 `m_cachedPowerReport`, `m_cachedCpuReport` 等，過程中由 `std::shared_mutex` 的寫入鎖保護。
3. **`openflowTablesUpdateWorker`**：定期向控制器 (Ryu / P4 Proxy) 查詢 OpenFlow 流表狀態並快取。

外部 HTTP API 呼叫讀取狀態時，只會回傳快取的 JSON 資料（受讀取鎖保護），極大地降低了 API 延遲並避免重複觸發耗時的 SNMP/SSH 查詢。

### 2.3 電源策略模式
與 RoutingManager 類似，實作了 `IPowerStrategy` 來區分 OVS 與 P4 的電源控制方式，並提供 `getPowerStrategyForDpid` 進行分派。

## 3. 模組職責
1. **硬體電源控制**：結合 Smart Plug 表格，精準切換指定實體 IP 交換機的電源。
2. **硬體遙測收集**：透過 SNMP (`snmpget`, `snmpwalk`) 與 SSH 指令，擷取 CPU、記憶體、溫度以及即時功耗 (Power Consumed, mW)。
3. **Liveness 監控**：持續探測設備，若異常則即時更新 Topology 中的節點狀態，觸發系統網路重路由機制。

## 4. 程式碼品質與技術債分析
- **優點**：
  - 快取機制設計精良，完美隔離了「慢速的硬體 I/O (SNMP/SSH)」與「快速的 API 查詢」。
  - 在 `pingWorker` 中，對不同廠牌/類型的處理邏輯區分得很清楚，並有詳細註解說明 P4 BMv2 虛擬交換機 Liveness 未實作的歷史背景（Phase 6）。
- **安全性風險**：
  - `snmpget` 指令字串直接以字串拼接方式產生 (`fmt::format("... {} ...", ip_str)`)。雖然 `ip_str` 大多來自系統內部，若不慎混入惡意字元，可能導致 **Command Injection**。
  - 對於 Brocade 交換機的 `getPowerReportViaSsh`，若 SSH 私鑰或憑證管理不當，可能成為被攻破的跳板。
- **技術債 (Technical Debt)**：
  - **BMv2 Liveness 寫死**：`pingWorker` 在 Mininet 模式下若遇到 BMv2 交換機，目前只能「無腦判定為 UP」。這是因為 P4 Proxy 尚未實作 gRPC Channel 狀態或 LLDP 探測。這會導致虛擬 P4 節點的 Failover 機制無法正常運作。
  - **Magic Strings 與 OID**：程式碼中散落著硬編碼 (Hardcoded) 的 SNMP OIDs（如 `1.3.6.1.4.1.25506.8...`）。這些應被提取到獨立的設定檔中。
