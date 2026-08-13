# Phase 6: Event System & Utils (C++ 事件系統與共用元件) 審查總結

## 1. 測試腳本的完整度與覆蓋盲區

### 共用工具類完全缺乏測試
在 `tests/` 中雖然有 `test_EventBus.cpp`，但對於最核心、被全系統引用的共用工具庫（包含 `utils/Utils.hpp`、`utils/Logger.hpp`、`utils/SSHHelper.hpp`）以及事件分派中心 `ControllerAndOtherEventHandler`，**完全沒有任何專屬的單元測試**。
這些基礎建設 (Infrastructure) 程式碼在其他測試（如 `test_SwitchKindDispatch`）中只被當作附屬品呼叫，導致其中的致命錯誤與並發漏洞完全躲過了自動化測試的法眼。

## 2. 嚴重的安全漏洞 (Security Vulnerabilities)

### Command Injection in `SSHHelper.hpp`
在 `getPowerReportViaSsh` 函式中，系統透過字串拼接建構了 `ssh` 登入指令，並直接傳入 `popen` 執行：
```cpp
command_stream << "(echo ... ) | ssh -T ... " << username << "@" << ip;
FILE* pipe = popen(command.c_str(), "r");
```
因為 `username` 和 `ip` 沒有經過任何消毒，攻擊者只需在輸入的 IP 中加入分號 (`;`) 或管線符號 (`|`)，即可再次觸發 Root 權限下的 Remote Code Execution (RCE)。

### Command Injection in `Utils.hpp`
`execCommand` 函式也是直接接收未經過濾的指令字串並使用 `popen(cmd.c_str(), "r")`。由於整個系統（例如前面審查的 Phase 4 與 5）大量依賴 `execCommand` 來執行 `curl`，這進一步證實了這個工具函式是系統安全的最弱一環。

## 3. 毀滅性的並發漏洞 (Concurrency / Race Conditions)

### `inet_ntoa` 引發的記憶體損壞
在 `Utils.hpp` 中的 `ipToString(uint32_t ip)` 函式，使用了 C 語言標準庫中的 `inet_ntoa`：
```cpp
const char* s = inet_ntoa(addr);
```
**`inet_ntoa` 函式回傳的是一個靜態記憶體指標 (Statically allocated buffer)，在多執行緒環境下絕對不安全 (Not thread-safe)！** 
在 NDTwin-Kernel 這種充斥著背景監控與 API 請求的高併發系統中，當多個執行緒同時呼叫 `ipToString`，它們會互相覆寫彼此的 IP 字串緩衝區，導致嚴重的資料錯亂 (Data Race)，甚至引發 Segmentation Fault。

## 4. 錯誤處理架構的缺陷

### `portStringToUint` 吞噬錯誤
在 `Utils.hpp` 中，若輸入無效字串導致 `std::invalid_argument`，程式僅僅輸出到 `std::cerr`（這在背景伺服器中會完全消失），然後預設回傳 `0`，這會讓系統在讀取到壞資料時誤以為是有效的 Port 0，引發後續的邏輯災難。

## 總結
Phase 6 的基礎元件看似簡單，卻埋藏了全系統最致命的兩大地雷：**使用非執行緒安全的 `inet_ntoa` 導致全域資料競爭，以及 `popen` 導致的指令注入**。這些底層工具的缺陷是前面各個子系統出現安全與穩定性問題的根源。
