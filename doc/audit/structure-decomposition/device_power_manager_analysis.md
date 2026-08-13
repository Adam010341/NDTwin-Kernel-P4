# DeviceConfigurationAndPowerManager.cpp 檔案架構與功能深度解析

`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp` 在 NDTwin 系統中扮演著**「硬體抽象層 (Hardware Abstraction Layer) 與設備管家」**的角色。

在 SDN 和數位孿生的架構中，控制器 (如 Ryu) 通常只在乎「封包怎麼走」，而不在乎設備的「硬體健康狀態」。這個檔案補足了這個缺口，專門負責監控實體交換機的 CPU、記憶體、溫度、耗電量，甚至實作了遙控實體插座來開關交換機的功能。

以下為您詳細剖析這份檔案的核心設計與特色：

---

## 1. 核心職責：多維度的設備狀態監控

這個 Manager 透過一個背景執行緒定期抓取 (Polling) 網路中所有交換機的狀態。它支援了以下幾種關鍵報表的收集：
* **Power Report (耗電量)**：收集交換機當前的耗電瓦數。
* **CPU / Memory Report (資源使用率)**：監控控制平面的資源負載。
* **Temperature Report (溫度)**：監控機房或設備過熱狀況。
* **OpenFlow Tables**：定時向 Ryu 抓取交換機內部的規則表，並交給 `m_classifier` 進行後續的 AI 分析。

為了避免上層 App 頻繁打 API 導致底層硬體被 DDoS（例如大量發送 SNMP 查詢癱瘓交換機），這份檔案實作了**快取機制 (Caching)**。背景執行緒定時把抓到的資料存入 `m_cachedPowerReport` 等 JSON 變數中，當 HTTP API 收到請求時，直接回傳快取資料即可。

## 2. 異質硬體相容性 (Heterogeneous Hardware Support)

這個檔案最特別的地方，在於它必須處理不同廠牌、甚至虛擬與實體設備的差異。在程式碼中，您可以一直看到 `if-else` 分支來處理這些情況：

### 2.1 實體設備 (Testbed Mode)
針對不同廠牌的交換機，NDTwin 寫死了不同的獲取方式：
* **HPE (如 HPE5520)**：使用 `snmpget` 或 `snmpwalk` 透過特定的 OID (例如 `1.3.6.1.4.1.25506...`) 來取得 CPU 或溫度資訊。
* **Brocade (如 ICX 7250)**：除了 SNMP 之外，耗電量部分甚至實作了透過 SSH 登入交換機 (`getPowerReportViaSsh`)，輸入 `show inline power` 指令後，再暴力解析純文字輸出的邏輯。

### 2.2 模擬環境 (Mininet Mode)
由於 Mininet 中的虛擬交換機 (OVS) 並沒有真實的硬體溫度或耗電量，這份檔案在這裡非常聰明地實作了**「偽造資料產生器」**。
它會使用交換機的 IP 作為 Seed 去 Hash，或是使用亂數產生器 (`std::mt19937_64`) 來產生擬真的 CPU 或耗電量假數據。這確保了上層的 Web-GUI 或 AI 演算法在沒有實體設備的開發階段也能正常運作！

## 3. 實體電源控制 (Smart Plug vs OVS)

這個檔案也負責接收 `/ndt/set_switches_power_state` 的意圖，對設備進行「開機/關機」：

* **Testbed Mode (`setPowerStateTestbed`)**：
  它會呼叫 `http://<GW_IP>:8000/relay`。這是因為實驗室環境中，交換機的電源通常接在一個有網路控制功能的智慧延長線 (Smart PDU/Plug) 上。NDTwin 會透過這個中繼 API 真的把實體插座的電給切斷，達到真正的「節能」。
* **Mininet Mode (`setPowerStateMininet`)**：
  在虛擬環境中沒有實體插座，因此它的實作方式是透過 `sudo ovs-vsctl del-br` (刪除網橋) 搭配 `ifconfig down` 來模擬「關機」；「開機」時則重新建立網橋並掛載 Controllers。

---

> [!WARNING]
> **給 P4 開發者的重點總結：**
> 
> 當您將系統轉換為 P4 / BMv2 架構時，這個檔案有兩個您需要留意的修改點：
> 
> 1. **`fetchOpenFlowTablesInternal()`**：如您所料，這裡寫死了呼叫 `curl http://<RYU>/stats/flow/<DPID>`。在 P4 模式下，您必須攔截這個呼叫，改為向您的 `P4-Proxy-Agent` 發送 API 來取得 BMv2 內部的 Match-Action Table 狀態。
> 2. **模擬 BMv2 的開關機**：目前的 Mininet 關機邏輯 `setPowerStateMininet` 完全是針對 `ovs-vsctl` 寫的。如果您的 P4 環境使用的是 `simple_switch_grpc` 或 `stratum_bvm2`，您將無法使用 OVS 的指令，您必須修改這裡的邏輯，例如改呼叫 docker stop，或是向 Mininet 的 Python Daemon 傳送關閉節點的指令。
