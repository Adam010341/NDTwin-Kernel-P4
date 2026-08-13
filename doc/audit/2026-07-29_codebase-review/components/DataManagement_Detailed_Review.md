# NDTwin-Kernel 模組詳細分析：Data Management (資料管理與歷史紀錄)

## 1. 模組概述
**路徑**：`include/ndt_core/data_management/`, `src/ndt_core/data_management/`
**主要類別**：`HistoricalDataManager`

`HistoricalDataManager` 是負責網路遙測歷史資料持久化 (Persistence) 的背景模組。它會定時將記憶體中瞬時的網路狀態（如鏈路頻寬使用率、拓樸變化）快照並寫入至本地檔案系統的 CSV 檔案中，供後續的資料分析、AI 訓練或報表生成使用。

## 2. 核心機制

### 2.1 儲存路徑與初始化
建構時，該模組會確保輸出目錄 `/home/of-controller-sflow-collector/LinkData` 存在。如果不存在，則會呼叫 `std::filesystem::create_directories` 建立該資料夾。

### 2.2 定時快照執行緒 (Snapshot Worker)
模組透過 `start()` 啟動獨立背景執行緒執行 `run()` 方法：
- **拓樸快照**：透過呼叫 `m_topologyAndFlowMonitor->getGraph()`，它會**複製 (Clone)** 一份當下瞬間的 Boost Graph Library 拓樸圖，確保在讀取屬性時不會因持鎖過久而影響網路控制平面的效能。
- **資料格式化與寫入**：
  遍歷 Graph 中所有的邊 (Edges/Links)。根據兩端點是 Switch 還是 Host，動態抓取 DPID 或是 MAC 位址。
  輸出格式為每個連線一組 CSV 檔案，檔名規則：`YYYYMMDD_srcId_dstId.csv`。
  寫入欄位包含：
  - `date-time`: 記錄當下時間 (`YYYY-MM-DD HH:MM:SS`)。
  - `srcType`, `srcId`, `dstType`, `dstId`: 記錄連線雙方身分。
  - `link_bw`: 實體鏈路最大頻寬。
  - `link_bw_usage`: 該鏈路當下的頻寬使用率。
- **排程機制**：
  完成一輪寫入後，會透過 `std::this_thread::sleep_for` 進行休眠，休眠時間為 `m_interval.count() * 60` 秒。為了能夠迅速響應 `stop()` 關閉訊號，休眠邏輯以 1 秒為單位進行迴圈檢測 `m_running.load()`。

## 3. 程式碼品質與技術債分析
- **優點**：
  - 使用複製的 Graph 來取代長時間 Read Lock 是確保控制平面效能的好做法。
  - 響應式中斷睡眠的實作 (`for` 迴圈 1 秒 sleep) 相當實用。
- **技術債與潛在風險**：
  - **路徑硬編碼 (Hardcoded Paths)**：目錄 `/home/of-controller-sflow-collector/LinkData` 被寫死在程式碼中。這嚴重降低了模組的可攜性 (Portability)，如果專案部署在不同的使用者目錄下，將會因為權限問題無法建立資料夾而失敗。應將該路徑移入 `AppConfig` 或配置檔中。
  - **效能問題**：每一次 Interval，都會對每一個連線執行 `std::ofstream ofs(fullPath, std::ios::app);` 開啟與關閉檔案。若網路圖極大（數千條鏈路），這種極高頻率的 I/O 開檔/關檔操作會對系統硬碟效能造成災難性負擔，應考慮實作 File Stream Cache 或是整合成單一時間序列資料庫 (如 InfluxDB/Prometheus)。
  - **Condition Variable 建議**：如原始碼中的 `TODO[OPTIMIZW]` 所述，使用 `std::condition_variable` 來取代迴圈 1 秒休眠將能進一步降低不必要的 CPU 喚醒開銷。
