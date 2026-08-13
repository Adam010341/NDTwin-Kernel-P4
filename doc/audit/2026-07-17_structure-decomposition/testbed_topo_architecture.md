# NDTwin-Kernel `testbed_topo.py` 檔案功能與架構文件

## 1. 檔案總覽 (Overview)
`testbed_topo.py` 是一個基於 Mininet 的 Python 腳本，主要負責建構用於 NDTwin-Kernel 的自定義網路拓撲環境。它不僅僅是建立節點和連線，還包含了許多進階的網路模擬設定，包含：
- **自定義階層式拓撲** (10台交換機，128台主機)
- **支援外部 SDN 控制器** (如 Ryu 或 P4 控制器)
- **內建 sFlow 流量監控機制** 
- **自動化網路組態設定** (MAC/IP 指定、ARP 表預先載入)
- **並行背景流量生成** (多執行緒 Ping 測試)

## 2. 網路架構設計 (Topology Architecture)
此腳本實作了一個類似 **Fat-Tree (胖樹)** 或 **Leaf-Spine** 的三層式高可用性架構。

### 硬體節點配置：
*   **Core Switches (核心交換機)**: `s9`, `s10`
*   **Aggregation Switches (聚合交換機)**: `s5`, `s6`, `s7`, `s8`
*   **Edge/Access Switches (邊緣交換機)**: `s1`, `s2`, `s3`, `s4`
*   **Hosts (終端主機)**: 128 台 (`h1` 到 `h128`)

### 連線與頻寬規劃：
1.  **Core 到 Aggregation (10Gbps)**:
    *   `s5`, `s6` 連接到 `s9`, `s10`
    *   `s7`, `s8` 連接到 `s9`, `s10`
2.  **Aggregation 到 Edge (1Gbps)**:
    *   `s1`, `s2` 連接到 `s5`, `s6`
    *   `s3`, `s4` 連接到 `s7`, `s8`
3.  **Edge 到 Hosts (1Gbps)**:
    *   `s1` 連接 `h1`~`h32` (第 1 區塊)
    *   `s2` 連接 `h33`~`h64` (第 2 區塊)
    *   `s3` 連接 `h65`~`h96` (第 3 區塊)
    *   `s4` 連接 `h97`~`h128` (第 4 區塊)

這種設計允許網路由下往上有良好的冗餘機制與頻寬收斂，適合用來測試資料中心 (Data Center) 的流量特性與 SDN 控制器的路由能力。

## 3. 核心功能與函式解析
*   `MyTopo` 類別：繼承自 Mininet 的 `Topo`，在 `build()` 方法中實作上述的網路節點和連線創建。
*   `find_ovs_agent_iface(switch)`：找出 OVS 交換機對應的網路介面名稱，用作 sFlow 的 Agent IP 來源，這對於區分來自不同交換機的 sFlow 封包至關重要。
*   `enable_sflow(switch, agent_iface, collector_ip, collector_port)`：透過呼叫底層的 `ovs-vsctl` 命令，將指定的 OVS 交換機開啟 sFlow 功能，並將採樣資料 (採樣率 256) 導向到 Collector IP。
*   `ping_test(src, dst_ip)`：提供給多執行緒使用的簡單 Ping 測試函式，用於確認節點間的連通性並產生初始網路流量。

## 4. 系統執行流程 (Execution Flow)
當直接執行此腳本 (`python3 testbed_topo.py`) 時，將經歷以下初始化階段：

### 階段一：Mininet 初始化與控制器連接
腳本啟動後，建立 `MyTopo` 實例，並使用 `RemoteController` 建立 Mininet 網路，這意味著它會將網路控制權交給外部運行在預設 Port (通常為 6653) 的 SDN 控制器。

### 階段二：建構 sFlow 帶外管理網路 (Out-of-band Management)
為了能在主機端接收交換機的監控資料，腳本實作了巧妙的網路設定：
1.  **綁定本機 Alias IP**：在實體主機的 `lo` (Loopback) 介面新增一個 IP `192.168.123.1/24` 作為 Collector 接收端。
2.  **配置交換機 Management IP**：將 `s1`~`s10` 的管理介面分別指派 `192.168.123.11`~`192.168.123.20` 的 IP 地址。
3.  **啟動 OVS sFlow**：逐一對這 10 台交換機下達指令，將 sFlow 目標指向 `192.168.123.1:6343`。

### 階段三：主機網路與 ARP 表預載入
1.  **IP & MAC 設定**：為 `h1`~`h128` 依序設定可預測的 IP (`10.0.0.1`~`10.0.0.128`) 和 MAC 地址。
2.  **靜態 ARP 表 (Static ARP)**：這是一個非常關鍵的優化。腳本透過雙層迴圈，為每一台主機寫入其他 127 台主機的靜態 ARP 記錄 (`arp -s`)。這避免了在模擬開始時產生龐大的 ARP 廣播風暴 (Broadcast Storm) 以及控制器處理 ARP 封包的負擔。

### 階段四：背景流量生成
使用 Python 的 `threading` 模組，發起多對多的並行 Ping 測試：
*   前半部的主機 (`h1`~`h64`) Ping 後半部的主機 (`h65`~`h128`)。
*   同時後半部的主機也 Ping 回前半部。
這會在網路剛啟動時製造一波基礎流量，有助於觸發控制器下發 Flow Rules，並讓 sFlow 收集器一開始就有資料可以捕捉。

### 階段五：CLI 與優雅退出 (Graceful Cleanup)
流量測試完成後，進入 `CLI(net)` 讓開發者可以手動在終端機內與 Mininet 互動。
當使用者退出 CLI 後，`finally` 區塊會自動清理之前綁定在主機 `lo` 介面上的 `192.168.123.1`，並停止 Mininet 網路，確保不會在實體主機上留下殘留的網路設定。

---
**總結**：
`testbed_topo.py` 是一個設計完善的網路測試平台，專門用於驗證 SDN 控制器的路由演算法與拓撲發現能力。它透過靜態 ARP 和自動 sFlow 配置，解決了大型 Mininet 網路初始化時常見的效能瓶頸與監控難題。
