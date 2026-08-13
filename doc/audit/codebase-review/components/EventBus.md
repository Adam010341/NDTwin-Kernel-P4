# NDTwin-Kernel 模組詳細分析：EventBus

## 1. 模組概述
**路徑**：`include/event_system/EventBus.hpp`
**主要類別**：`EventBus`

`EventBus` 是一個輕量級的發佈/訂閱 (Pub/Sub) 系統，負責在 NDTwin-Kernel 的各個模組之間進行非同步或解耦的事件傳遞，如：新增流表、鏈路斷線、鏈路恢復、交換機上下線等。

## 2. 依賴關係
- **標準函式庫**：`<any>`, `<functional>`, `<shared_mutex>`, `<vector>`, `<unordered_map>`
- **外部依賴**：無。完全獨立於其他核心模組，作為最底層的通訊基底。

## 3. 執行緒模型
`EventBus` 提供多執行緒安全的事件註冊與分派：
- **註冊 (Register)**：使用獨佔鎖 `std::unique_lock` 保護內部 Map。
- **發佈 (Emit)**：為了避免**死結 (Deadlock)**，`emit` 函數在獲取讀寫鎖 (`std::shared_lock`) 後，會先將目標 Event 的所有 Handler **複製 (Copy)** 出來，然後**釋放鎖**，最後才逐一執行這些 Handler。這確保了 Handler 內部再次觸發事件（或註冊新事件）時，不會引發 `shared_mutex` 不支援可重入 (Reentrant) 的死結問題。這是一個極為精妙且健壯的併發設計。

## 4. API 方法清單與公開方法說明

### API 方法清單
- `void registerHandler(EventType type, Handler handler)`
- `void emit(const Event& event) const`

### 公開方法說明
*   **`registerHandler(EventType type, Handler handler)`**
    註冊特定事件類型的回呼函式 (Callback)。當該事件發生時，所有註冊的 Handler 會被依序觸發。
*   **`emit(const Event& event) const`**
    同步發佈一個事件，帶有 `EventType` 與使用 `std::any` 封裝的 `payload`。所有訂閱該事件的 Handler 都會在當前執行緒中被同步呼叫。
