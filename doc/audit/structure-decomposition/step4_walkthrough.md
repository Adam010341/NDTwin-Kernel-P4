# Step 4: NDTwin Kernel 重構與整合 (C++ Strategy Pattern)

在本次開發中，我們成功將 NDTwin Kernel 進行了深度重構，透過導入 **Strategy Pattern (策略模式)** 來解除原先寫死的 `curl` 邏輯，讓 NDTwin 具備同時管理傳統 OVS (Ryu) 與 P4 BMv2 交換機的混合網路能力。

## 1. 路由控制重構 (Routing Strategy)

原先的 `FlowRoutingManager` 是將 Ryu 的 API 呼叫寫死在程式碼內，這會導致未來難以維護與擴展。

- **`IRoutingStrategy` 介面**：我們抽出了一個標準的路由介面，規範了新增、刪除、修改 Flow Entry/Group/Meter 的必要方法。
- **`OpenFlowRoutingStrategy`**：將原本針對 Ryu (`localhost:8080`) 的 API 邏輯封裝在此策略中，保持與舊系統的 100% 相容。
- **`P4RoutingStrategy`**：新建了針對 P4 Proxy Agent (`localhost:8081`) 的策略，由於 API 規格已經對齊，這個策略完美地將 P4 指令派送至 Python Proxy Agent 進行 P4Runtime 轉換。
- **智慧分流 (Dispatcher)**：在 `FlowRoutingManager` 內，我們透過查詢 `TopologyAndFlowMonitor` 中 Graph 的 `VertexProperties::brandName`。若為 `BMv2`，即動態調用 `P4RoutingStrategy`；否則走傳統 OVS 路線。

> [!TIP]
> 我們同時引入了 Google Test (gtest) 單元測試框架，將 `utils::execCommand` 抽象化為 `virtual executeCommand()`，從而成功攔截並驗證了所有 `curl` 字串與 JSON 的正確性（測試 100% 通過 ✅）。

## 2. 電源管理重構 (Power Strategy)

在 Mininet 環境下，NDTwin 有一套獨特的設備開關機 (Link Failure) 模擬機制。

- **`IPowerStrategy` 介面**：統一了 `powerOn()` 與 `powerOff()` 介面。
- **`OVSPowerStrategy`**：封裝了針對 Open vSwitch 的 `sudo ovs-vsctl del-br` 與 `add-br` 指令邏輯。
- **`P4PowerStrategy`**：實作了針對 BMv2 的關機邏輯，利用 `sudo mnexec -a [swName] pkill -f simple_switch_grpc` 來終止位於對應 Mininet 命名空間內的 P4 交換機進程。
- 在 `DeviceConfigurationAndPowerManager` 內部同樣加入了基於設備品牌的動態策略分派。

> [!NOTE]
> P4 (BMv2) 的重啟 (Power On) 在 Mininet 外部處理較為複雜（需要帶入大量 gRPC、Thrift Port、JSON 檔案路徑與 `--no-p4` 參數），因此目前 C++ 核心內實作了 Stub 與 Log 警告，待未來若有頻繁的 BMv2 韌體重啟需求時再行擴充。

## 3. 測試環境設定

我們已經修正了 `setting/AppConfig.hpp`，現在系統可以正確區分以下兩種代理服務：
- `AppConfig::RYU_IP_AND_PORT = "localhost:8080"`
- `AppConfig::P4_PROXY_IP_AND_PORT = "localhost:8081"`

目前 Mininet 背景中已運行包含 **10 台 BMv2 Switch 與 4 台 Host** 的 `p4_testbed_topo.py` 腳本，而 `main.py` (Proxy Agent) 也在 8081 Port 穩定提供服務中。

## 下一步：端到端整合驗證

隨著 C++ Kernel 內部的重構完成與成功編譯，我們已經完成了 Step 4 的前三階段。接下來我們就可以進行整套 NDTwin 的啟動與實機測試，真正地在 P4 Testbed 上下發路由並觀看 Web 介面的變化！
