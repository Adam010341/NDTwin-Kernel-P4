# NDTwin-Kernel 模組詳細分析：Collection (拓樸與流量遙測收集)

## 1. 模組概述
**路徑**：`include/ndt_core/collection/`, `src/ndt_core/collection/`
**主要類別**：`TopologyAndFlowMonitor`, `FlowLinkUsageCollector`, `Classifier`
**關鍵字**：Boost Graph Library (BGL), sFlow, Multithreading, Lock-free Queue

Collection 模組是整個數位孿生系統中「感知」網路狀態的核心。它負責兩大任務：一是動態維護網路拓樸（包含設備與鏈路狀態），二是收集並分析從各交換機回傳的 sFlow 封包，計算即時的流量 (Flows) 與頻寬使用率 (Link Usage)。

## 2. TopologyAndFlowMonitor (拓樸監控)
### 2.1 核心資料結構
系統使用 **Boost Graph Library (BGL)** 的 `adjacency_list` 來構建網路拓樸：
- **Vertex (節點)**：對應交換機 (Switch) 或主機 (Host)。
- **Edge (邊)**：對應節點之間的鏈路 (Link)。
- **鎖機制**：使用 `std::shared_mutex` 保護 Graph，允許高併發讀取（如路由計算、Flow 匹配），但在更新節點/邊狀態時使用獨佔鎖 (Write Lock)。

### 2.2 運作機制
- **靜態載入與動態更新**：
  啟動時先從 `NDTWIN_TOPO_FILE` 載入初始設定檔（建立基礎節點與連線），接著定期透過 HTTP GET 請求向南向控制器 (Ryu 的 REST API 或 P4 Proxy 的 `/v1.0/topology`) 抓取即時的設備與鏈路狀態 (`switches`, `hosts`, `links`)，動態更新 Graph 屬性。
- **O(1) 快取設計**：
  過去頻繁掃描 Graph 找尋 Switch 屬性造成效能瓶頸，後來實作了 `getSwitchKind` 與 `m_dpidToSwitchKind`，允許 $O(1)$ 時間複雜度判斷 DPID 屬於 OVS 還是 BMv2。

## 3. FlowLinkUsageCollector (sFlow 流量收集)
### 3.1 接收機制與多執行緒架構
`FlowLinkUsageCollector` 開啟了一個 UDP Socket (Port 6343) 接收 sFlow 封包：
- **高效接收 (RX Thread)**：使用 Linux 的 `recvmmsg` 系統呼叫，一次批次接收多個 UDP 封包，減少 Context Switch 開銷。
- **非阻塞式分發**：採用自行實作的 Lock-free `SPSCQueue` (Single-Producer Single-Consumer Queue)，將封包以 Round-Robin 方式派發給多條 Worker Threads。若 Queue 滿載，則選擇丟包 (`sockOvflDrops`) 而不阻塞 RX，確保最高吞吐量。
- **解碼防護 (Bounds Checking)**：實作了 `sflow::BoundedWords`，確保在解碼由不受信任網路傳來的 sFlow 負載時不會發生越界讀取 (Out-of-bounds Read) 導致系統崩潰。

### 3.2 鏈路與流量分析
- 收到 sFlow Sample 後，更新內部的 `m_flowInfoTable`。
- **連接埠對映 (Port Mapping)**：由於 OVS 與 sFlow 在 `ifIndex` 的認知上有落差，系統實作了 `populateIfIndexToOfportMap` 透過 `ovs-vsctl` 命令進行 `ifIndex` 到 OpenFlow Port 的轉換。在 BMv2 環境下則無需轉換。

## 4. 程式碼品質與安全性分析
- **優點**：
  - 高併發設計極佳：使用 `recvmmsg`, `SPSCQueue`，以及多 Thread Pool，非常適合高流量的 sFlow 分析場景。
  - 對第三方外部輸入 (UDP) 做了邊界檢查 (`BoundedWords`)，大幅提升程式穩定性，防止特製的惡意封包引發 Segment Fault。
- **潛在問題與技術債**：
  - **Graph 操作的效能**：儘管實作了 $O(1)$ 快取，但某些需要掃描所有節點或連線的操作在節點數量極大（數千）時，配合 `shared_mutex` 寫入鎖，可能仍會引發 Lock Contention。
  - **`ovs-vsctl` 的依賴**：`FlowLinkUsageCollector` 依賴呼叫系統命令 `ovs-vsctl` 來對齊 Port。如果系統環境未正確設定 sudo 權限或 ovs-vsctl，將會導致 OVS 流量統計失效。
