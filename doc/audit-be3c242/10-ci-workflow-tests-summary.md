# Phase 10: CI, Workflow & Contract Tests (整合與契約測試腳本) 審查總結

## 1. 測試腳本的真實覆蓋率與虛假測試

### 寬鬆白名單導致的「虛假 PASS」(False Positives in Log Checks)
在 `tools/contract_test/warning_allowlist.txt` 中，設定了以下白名單來忽略啟動時的警告：
```text
WARNING | ^switch not found dpid [0-9]+$ | Classifier::lookup during the startup window... bounded (~100ms)
WARNING | ^Link \(dpid .* port .*\) not found in static network topology file$ | ... transient during discovery
```
這是一個非常嚴重的測試漏洞。註解聲稱這些錯誤是「啟動時的暫態 (transient)」，但白名單的 Regex **沒有任何時間戳記或次數的限制**！這意味著，如果在系統穩態運行 3 小時後，因為某個 Bug 導致拓樸圖破裂而噴出 `switch not found`，`check_logs.py` 依然會無條件把它當作「啟動暫態」過濾掉，然後回報 PASS。這使得 L2/L3 測試失去了對核心拓樸一致性的把關能力。

### 靜默失敗的等待邏輯 (Silently Skipped Waits)
在 `tools/test_workflow/stack.sh` 的 `countdown` 函式中，開發者（或 AI）留下了註解說明 Bash 的 `(( left > 0 ))` 遇到非整數（例如 `0.5` 或 `60s`）時會直接失敗，導致迴圈被跳過，直接印出 `done` 並回傳 `0` (成功)。雖然腳本裡加了 `if [[ ! "$left" =~ ^[0-9]+$ ]]` 防禦，但這揭露了整個測試工作流對 Bash 算術脆弱性的依賴。如果其他腳本（如 NTG 啟動腳本）傳入了浮點數，就會導致「還沒等系統收斂完，就開始跑測試」，引發海量的隨機測試失敗 (Flaky tests)。

## 2. AI 幻覺 (AI Hallucinations)

### 呼叫不存在的幽靈 Endpoint
在 `tools/contract_test/l3_component_check.py` 中，清楚記錄了一段 AI 幻覺產生的災難：
```python
# A 404 means the component is calling something the kernel does not implement.
# This is how Energy-Saving-App's call to /ndt/disable_switch shows up: 
# it has always 404'd and the app swallows it.
```
`Energy-Saving-App` (節能應用程式) 的核心邏輯是關閉閒置的交換機以節省電量。然而，它呼叫的 `/ndt/disable_switch` API **在 NDTwin-Kernel 中根本不存在**。
更糟的是，該應用程式在收到 404 Not Found 後，直接把錯誤吞掉 (swallow) 並且繼續執行。所以這個節能應用程式在測試中看起來跑得很完美，但實際上**它從來沒有成功關閉過任何一台交換機**！這是一個典型的 AI 幻覺：它假設了一個「聽起來很合理」的 API，並且自己完成了閉環，導致這個功能一直是個空殼。

## 總結
Phase 10 的整合與契約測試框架本身寫得相當用心（甚至包含了對齊 C++ 原始碼與 Python 定義的 L3 Check），但白名單機制的過度寬鬆，以及下游應用程式呼叫「幽靈 API」並隱藏錯誤的行為，讓整個 CI 系統在某些關鍵路徑上形同虛設。這強烈建議我們需要把 L3 Contract Test 真正整合到 CI pipeline 中，並且修正 Energy-Saving-App 的幻覺呼叫。
