# FlowLinkUsageCollector.cpp 檔案架構與功能深度解析

`src/ndt_core/collection/FlowLinkUsageCollector.cpp` 是一份極具份量（超過 2000 行）且充滿底層網路細節的原始碼。
如果說 NDTwin Kernel 是一個數位孿生大腦，那麼這個檔案就是它的**「視覺與觸覺神經元」**。它的核心任務是透過 **sFlow 協定**，無時無刻地監聽底層交換機傳來的封包採樣，藉此感知網路中正在流動的流量大小、誰在跟誰通訊，以及哪條網路線快要塞爆了。

以下為您詳細剖析這份檔案的核心功能與架構：

---

## 1. 核心定位：自製的高效能 sFlow Collector

市面上有許多現成的 sFlow Collector (如 sFlow-RT)，但 NDTwin 選擇了自己實作一個。
這個類別在啟動時（`start()`）會建立一個 UDP Socket（預設監聽 Port 6343），專門用來接收來自 Mininet (OVS) 或是實體交換機的 sFlow Datagrams。

為了應付極高頻率的封包湧入，系統在 `receiveDatagrams()` 中使用了 Linux 底層非常高效能的系統呼叫：`recvmmsg()` (Receive Multiple Messages)。這允許 Kernel 一次從網卡讀取多個 UDP 封包交給 User-space 處理，大幅降低了 CPU 的 Context Switch 負擔。

## 2. 封包解析引擎 (Packet Parsing)

檔案中最長、也最複雜的函式是 `processSFlowSample()`。它的工作是將收到的二進位 byte array 暴力解碼（透過位移 `>>` 和 `ntohl`）。

sFlow 封包主要分為兩種，這份檔案都實作了解析邏輯：
* **Counter Sample (計數器採樣)**：
  - 交換機定期回報每個 Port 的總傳送/接收位元組 (Bytes)。
  - 系統藉此算出 `leftIn` 與 `leftOut` (該條鏈路還剩下多少可用頻寬)，並立刻呼叫 `m_topologyAndFlowMonitor->updateLinkInfo()` 來更新數位分身的 Graph 狀態。
* **Flow Sample (流採樣)**：
  - 交換機會依照 1/N 的機率，將流經的封包表頭 (Header) 直接複製一份送過來。
  - 系統會解析出 Ethernet (IPv4, MAC)、TCP/UDP Ports、甚至判斷是否為純 ACK 封包 (Pure ACK)。
  - 解析出的五元組 (5-tuple) 會被當作一把鑰匙 (`FlowKey`)，存入 `m_flowInfoTable` 進行統計。

## 3. 流量估算與狀態機維護 (Flow Statistics & State)

在背景執行緒中，有幾個極為重要的週期性任務正在運行：

### 3.1 `calAvgFlowSendingRatesPeriodically()`
每秒鐘執行一次。它會走訪目前系統中記錄的所有 Active Flows，利用剛剛收集到的採樣封包大小乘以「採樣率 (Sampling Rate)」，來推算這條 Flow 實際的頻寬 (bps) 和封包率 (pps)。
- **大象流 (Elephant Flow) 判斷**：系統定義了一個 `MICE_FLOW_UNDER_THRESHOLD`。只要這條 Flow 的頻寬超過門檻，就會被打上 `isElephantFlowPeriodically = true` 的標記。這對於後續的 QoS 或是 AI 節能路由非常關鍵。

### 3.2 `purgeIdleFlows()`
這是一個垃圾回收 (Garbage Collection) 機制。如果某條 Flow (例如兩台電腦之間的短暫對話) 已經好幾秒沒有新的 sFlow 採樣進來，系統就會判定這條連線已經結束，並將其從 `m_flowInfoTable` 中剔除，避免記憶體洩漏 (Memory Leak)。

## 4. 與其他模組的連動 (Integration)

* **更新拓撲 (Topology Monitor)**：收集到的鏈路頻寬與 Flow 資訊會被即時寫入 `TopologyAndFlowMonitor` 維護的 Boost.Graph 中。
* **路由映射 (Ryu 依賴)**：在先前的分析中我們提到，這份檔案的第 1692 行呼叫了 `AppConfig::RYU_IP_AND_PORT + "/ryu_server/all_destination_paths"`。這是因為 sFlow 只告訴 NDTwin 哪個交換機收到了什麼封包，但 NDTwin 需要向 Controller 詢問「目前這些封包是走哪一條路徑 (Path)」，才能正確計算整條路徑上的消耗。

---

> [!WARNING]
> **給 P4 開發者的重點總結：**
> 
> 在 P4/BMv2 環境中，原生的 BMv2 **不一定會主動發送標準的 sFlow**。
> 您未來可能會面臨兩種選擇：
> 1. **在 P4 程式碼中實作 Telemetry / INT (In-band Network Telemetry)**：將統計資訊透過特製的封包或 gRPC 送回 P4 Proxy Agent，然後再由 Agent 偽裝成 sFlow 格式丟給 `FlowLinkUsageCollector` 或是修改本檔案的解析邏輯。
> 2. **直接查詢計數器 (Counters)**：在 P4 中宣告 Counters，並在 P4 Proxy Agent 中定期去 Read Counters，然後直接呼叫 `TopologyAndFlowMonitor` 的 API 來更新鏈路頻寬，跳過 sFlow 解析的過程。
> 
> 無論哪種做法，這個檔案都向您展示了 NDTwin 是多麼依賴「即時流量數據」來建構它的數位孿生世界！
