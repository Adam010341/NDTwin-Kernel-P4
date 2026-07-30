# Phase 2: Power Management (C++ 核心電源策略) 審查總結

## 1. 測試腳本的完整度與覆蓋盲區（最重要）

### 缺失：`OVSPowerStrategy` 與 `P4PowerStrategy` 完全缺乏測試
這兩個負責實質操控底層設備（透過系統指令與 API）的類別完全沒有單元測試。測試庫中雖然有 `test_OvsLiveness.cpp` 與 `test_SyntheticPower.cpp`，但它們只測試了 `DeviceConfigurationAndPowerManager` 的極小部分（例如 liveness 判斷邏輯和假資料產生器）。
對於真正執行 `sudo ovs-vsctl` 的程式碼路徑，完全依賴手動測試。這意味著邊界情況（例如：字串帶有空白、指令路徑不存在、權限不足）全都會在 Runtime 才會爆炸，而 CI 根本不會抓到。

### 缺失：`DeviceConfigurationAndPowerManager` 的網路 I/O 操作未被覆蓋
包含 `pingWorker`, `queryTestbed`, `setSwitchPowerState`, `fetchMemoryReportInternal` 等核心方法都缺乏測試。這代表當外部 API (如 Relay Proxy 或 SNMP) 回傳格式截斷、超時或是網路異常時，核心的容錯與恢復機制全都是「紙上談兵」，完全沒有被自動化測試覆蓋。

## 2. AI 幻覺與實作不完整

### 嚴重的幻覺與造假資料：`syntheticPowerMilliwattsFor`
在 `DeviceConfigurationAndPowerManager.cpp` 的 366-384 行，名為獲取設備電力的功能，實質上卻是利用雜湊演算法 (`splitmix64`) **憑空捏造假資料**（在 30W 到 150W 之間隨機震盪）：
```cpp
uint64_t mixed = dpid + 0x9E3779B97F4A7C15ULL;
// ... (hash calculations) ...
return kBaselineMilliwatts + (mixed % kSpanMilliwatts);
```
這是一個典型的「假裝功能已完成」的 AI 幻覺：它提供了一個看似合理的假資料流，讓上層的 Telemetry Dashboard 畫出漂亮的曲線，但其實根本沒有連接任何真實的硬體感測器！

## 3. 惡意或危險的 hard-coded 內容（命令注入與後門風險）

這部分存在極多危險的寫死邏輯：
*   **指令注入危險 (`OVSPowerStrategy.cpp`)**：
    第 67 行等直接拼接未過濾的字串來執行具有 `sudo` 權限的系統指令：
    `executeSystemCommand("sudo ovs-vsctl add-br " + swName + ...)`
    如果 `swName` 帶有惡意字元 (例如 `s1; rm -rf /`)，這將導致最高權限的命令注入。
*   **寫死的本機驗證繞過 (`DeviceConfigurationAndPowerManager.cpp`)**：
    在 `setSwitchPowerState` (第 620 行)，使用了寫死的 `Host` 標頭：
    `cmd << "curl -s -X POST " << "-H "Host: 127.0.0.1" " ...`
    這明顯是利用 SSRF 技巧或是用來繞過 Gateway Proxy 的權限檢查（假裝請求來自 localhost）。
*   **寫死的 SNMP 憑證與 Controller IP**：
    `OVSPowerStrategy.cpp` 第 78 行寫死了控制器位址：`sudo ovs-vsctl set-controller <br> tcp:127.0.0.1:6633`。
    `DeviceConfigurationAndPowerManager.cpp` 第 699 行寫死了 SNMP community 字串：`snmpget -v2c -c public ...`。

## 4. 被隱藏、悄悄吞掉的錯誤

### 忽視外部呼叫失敗
在 `DeviceConfigurationAndPowerManager.cpp` 中，對外呼叫 (如 `curl` 或 `ping`) 存在嚴重的錯誤吞噬：
*   **忽略 HTTP 錯誤碼**：在 `queryTestbed` 與 `setSwitchPowerState` 中，直接使用 `utils::execCommand` 呼叫 `curl`，完全沒有檢查 `-w '%{http_code}'` (不像 Routing 那邊有改進)。如果目標伺服器回傳 `500 Internal Server Error` 網頁，系統不會視為失敗，反而會嘗試用 fallback 去解析 500 錯誤網頁裡面的 HTML 標籤（找 `>` 和 `<` 之間的字串），並當作成功狀態回報。
*   **Catch-all 吞掉異常**：
    ```cpp
    catch (const std::exception& e) {
        SPDLOG_LOGGER_ERROR(..., "Error ... {}", e.what());
        return false;
    }
    ```
    在 259 行與 667 行，例外被全部攔截並化約為一個簡單的 error 字串或 false，底層的真實連線失敗原因（Timeout, DNS error）被完全抹除，外部呼叫者無法得知真實的系統狀況。
