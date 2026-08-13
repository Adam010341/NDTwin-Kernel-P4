# NDTwin-Kernel 模組詳細分析：ApplicationManager

## 1. 模組概述
**路徑**：`include/ndt_core/application_management/ApplicationManager.hpp`
**主要類別**：`ApplicationManager`

`ApplicationManager` 負責管理外部網路應用程式 (Network Applications) 或模擬腳本在 NDTwin-Kernel 上的註冊，並為它們動態配置與掛載獨立的 NFS (Network File System) 工作目錄，以便與 NDTwin 安全地交換檔案或進行狀態同步。

## 2. 依賴關係
- **標準函式庫**：`<filesystem>`, `<mutex>`, `<unordered_map>`, `common_types/AppTypes.hpp`。
- **外部相依性**：強烈依賴作業系統的 NFS Server 服務 (例如 `exportfs`、`systemctl`) 與 Bash shell 指令 (`sudo`, `sed`)。

## 3. 執行緒模型
模組並未啟動背景執行緒，但由於可能同時有多個應用程式同時註冊，內部使用了單一互斥鎖 (`std::mutex m_mutex`) 來保護所有的公開操作與內部 Map。這確保了應用程式 ID 的遞增分配 (`m_nextAppId`) 以及針對 `/etc/exports` 的寫入不會產生 Race Condition。

## 4. API 方法清單與公開方法說明

### API 方法清單
- `int registerApplication(const std::string& appName, const std::string& simulationCompletedUrl)`
- `bool setupNFSForApp(int appId)`
- `std::optional<std::string> getSimulationCompletedUrl(int appId) const`

### 公開方法說明
*   **`registerApplication(...)`**
    註冊新的應用程式，分配一個單調遞增的 App ID，並記錄該應用程式提供的回呼 (Callback) URL，當 NDTwin 核心完成指定模擬或配置時，會透過該 URL 通知應用程式。
*   **`setupNFSForApp(int appId)`**
    核心配置方法。為指定的應用程式在伺服器上建立專屬的資料夾 (例如 `/srv/nfs/sim/<appId>`)，更改其擁有者為 `nobody:nogroup`，動態將設定寫入 `/etc/exports`，最後重新載入 NFS Server 服務。
*   **`getSimulationCompletedUrl(int appId) const`**
    查詢該應用程式註冊時所留下的回呼 URL。
