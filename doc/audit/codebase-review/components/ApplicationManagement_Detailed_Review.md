# NDTwin-Kernel 模組詳細分析：Application Management (應用程式管理)

## 1. 模組概述
**路徑**：`include/ndt_core/application_management/`, `src/ndt_core/application_management/`
**主要類別**：`ApplicationManager`

`ApplicationManager` 負責管理建構於 NDTwin-Kernel 之上的「網路應用程式」 (Network Applications)。它提供了一個機制，為外部應用程式（如測試腳本、Mininet 拓樸模擬、自定義分析工具）動態配置並掛載專屬的工作目錄 (基於 NFS)，以便 NDTwin 核心與外部應用之間能夠安全、獨立地交換檔案或狀態。

## 2. 核心機制
### 2.1 應用程式註冊與 ID 分配
- 每次呼叫 `registerApplication` 時，系統會分配一個單調遞增的 `appId`，並將該 ID 對應到 App 名稱以及回呼 (Callback) 的 URL (`simulationCompletedUrl`)，存入內部 Map (`m_registeredApps`)。
- 在取得 `appId` 後，系統會透過 `setupNFSForApp` 為該應用動態配置一個 NFS 目錄 (Network File System)。

### 2.2 動態 NFS 目錄配置
`setupNFSForApp` 實作了自動化的儲存空間配置：
1. **目錄建立**：在指定的 `m_nfsExportDir` 下建立以 `appId` 命名的子目錄 (例如 `/mnt/nfs/1`)。
2. **權限調整**：呼叫自訂的 `chownRecursive` 函式，將該目錄的所有權設定為 `nobody:nogroup`，以符合 NFS 的預設權限要求。
3. **匯出設定更新**：將新建立的目錄動態附加寫入機器的 `/etc/exports` 檔案，設定 `*(rw,sync,no_subtree_check,root_squash,all_squash)`，允許客戶端無密碼掛載。
4. **NFS 服務重載**：呼叫 `system("exportfs -ra && systemctl reload nfs-server")` 讓變更立即生效。

### 2.3 資源清理機制
系統非常重視資源回收：
- **建構時** (`cleanupStaleEntries`)：掃描 NFS 目錄，若發現僅有數字命名的目錄，視為前次執行殘留的無效目錄並主動刪除。
- **解構時** (`cleanupNFS` / `cleanupAppFolder`)：會將 `m_registeredFolders` 中的所有目錄解除 NFS Export (`exportfs -u`)、使用 `sed` 從 `/etc/exports` 中刪除該行記錄，並實體刪除資料夾。

## 3. 程式碼品質與技術債分析
- **優點**：
  - 資源回收邏輯相當完整，解決了伺服器異常關閉時 `/etc/exports` 殘留的問題，有助於保持開發環境乾淨。
  - 對目錄權限操作 (`chownRecursive`) 使用了標準 POSIX API 而非呼叫系統指令 `system("chown -R")`，這是一個很好的安全與效能實作。
- **安全性風險 (重大技術債)**：
  - **命令注入 (Command Injection)**：在 `cleanupAppFolder` 中，使用了 `std::regex_replace` 取代 `/`，隨即將 `folder` 變數字串串接至 `sed` 指令並交由 `system()` 執行 (`std::string sedCmd = "sudo sed -i '/" + escapedFolder + "/d' /etc/exports";`)。若外部註冊時的 `nfsExportDir` 可以被控制（包含單引號或 bash 控制字元），將導致嚴重的 Root 權限命令注入漏洞。
  - **硬編碼與 Root 權限依賴**：頻繁依賴 `system("sudo ...")`，要求執行 NDTwin-Kernel 的使用者必須具備無密碼 sudo 權限。在正式上線的生產環境 (Production) 中，這是極度不安全的架構設計。建議改用更乾淨的掛載機制，例如 Docker Volume 動態掛載，或是 FUSE。
