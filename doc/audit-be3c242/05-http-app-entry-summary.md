# Phase 5: HTTP, App & Core Entry Point (C++ 核心通訊與進入點) 審查總結

## 1. 測試腳本的完整度與覆蓋盲區

### 零單元測試覆蓋 (Zero Test Coverage)
在 `tests/` 目錄中，**完全沒有**針對 `HttpSession`、`ApplicationManager` 或 `SimulationRequestManager` 的單元測試。
這代表整個 NDTwin-Kernel 的對外 API 介面、應用程式註冊生命週期、以及外部系統呼叫，全部處於「裸奔」狀態。雖然有 E2E 測試 (`run_layers.sh` / `stack.sh`) 去測試 API 功能，但 E2E 測試只會輸入「正確的」資料。對於惡意字元、空輸入、極端高頻發送、或特殊符號等邊界情況，完全沒有任何自動化測試在把關。這直接導致了以下災難性的漏洞。

## 2. 嚴重的安全漏洞 (Security Vulnerabilities)

### 遠端程式碼執行漏洞 (RCE / Command Injection)
在 `SimulationRequestManager.cpp` 的 `requestSimulation` 與 `onSimulationResult` 函式中，系統將接收到的 HTTP Body (`m_req.body()`) **完全沒有經過任何消毒 (Sanitization)**，直接透過字串拼接塞進 Bash 執行：
```cpp
std::ostringstream cmd;
cmd << "curl -s -X POST "" << SIM_SERVER_URL << "" "
    << "-H "Content-Type: application/json" " << "-d '" << body << "'";
std::string resp = utils::execCommand(cmd.str());
```
因為這套系統以 Root 權限運行，攻擊者只需發送帶有單引號 `'` 的惡意 JSON，例如：
`'} ; rm -rf / ; echo '`
就能跳出 `curl` 的 `-d` 參數，直接以 Root 權限在伺服器上執行任何指令。`/ndt/received_a_simulation_case` 與 `/ndt/simulation_completed` 皆受此漏洞影響。

## 3. 並發與資源競爭問題 (Concurrency / Race Conditions)

### OS 層級設定檔的無鎖競爭 (Race Condition on `/etc/exports`)
在 `ApplicationManager.cpp` 中，`updateNFSConfig` 透過 `std::ofstream` 以 append 模式直接寫入作業系統的 `/etc/exports`：
```cpp
std::ofstream exportsFile("/etc/exports", std::ios::app);
exportsFile << appDir << " *(rw,sync,no_subtree_check,root_squash,all_squash)\n";
```
這看似有被 `registerApplication` 的 `std::mutex` 保護，但是！`cleanupAppFolder` 會使用外部系統呼叫：
```cpp
std::string sedCmd = "sudo sed -i '/" + escapedFolder + "/d' /etc/exports";
system(sedCmd.c_str());
```
這代表同一個應用程式的不同執行緒（例如同時註冊新 App 與清理過期 App）可能會發生 **`ofstream` 的寫入與 `sed` 的刪除同時進行**的情況，因為它們沒有對 `/etc/exports` 使用檔案鎖 (File Lock, e.g., `flock`)。這極易導致系統的全域 NFS 設定檔損毀。

## 4. 錯誤處理架構的缺陷

### 例外濫用與錯誤分類不清
`HttpSession.cpp` 在最外層的 `processRequest` 透過一個巨大的 `try-catch` 包覆所有的 `handleXXX` 呼叫：
```cpp
catch (const json::exception& e) { return 400; }
catch (const std::exception& e) { return 500; }
```
在各個處理函式中，程式大量使用了 `std::stoi` / `std::stoull`，或是對 JSON 物件直接使用 `.at()` 而不檢查鍵值是否存在。一旦客戶端忘記傳某個欄位或傳了不是數字的字串（空字串），程式就會拋出 `std::invalid_argument` 或 `std::out_of_range`，然後被最外層捕獲並一律回傳 `500 Internal Server Error`。這把本該是 `400 Bad Request`（客戶端錯誤）的狀況全部混淆成伺服器內部錯誤，使未來的維運與除錯極度困難。

## 總結
Phase 5 暴露了 HTTP API 介面在缺乏邊界單元測試下的脆弱性。尤其是直接將未過濾的 HTTP Body 丟進 Bash 執行，這是一個非常典型且嚴重的 Command Injection 漏洞。加上對 OS 設定檔的無鎖競爭，整個入口層面的安全性與穩定性亟需重構。
