# NDTwin-Kernel 模組詳細分析：Event System (事件系統)

## 1. 模組概述
**路徑**：`include/event_system/`, `src/event_system/`
**主要類別**：`EventBus`
**設計模式**：發佈-訂閱模式 (Publish-Subscribe Pattern)

`EventBus` 模組是 NDTwin-Kernel 內部元件之間解耦通訊的核心樞紐。各個系統模組（例如 Topology Monitor, Routing Manager, Controller）不需要互相持有對方的深度參考，而是透過向 `EventBus` 註冊特定事件類型的回呼函數 (Callback / Handler)，並在事件發生時非同步或同步地觸發這些處理邏輯。

## 2. 核心資料結構與事件類型
在 `EventBus.hpp` 中，定義了 `EventType` 列舉，標示了系統目前支援的關鍵事件：
- `FlowAdded`：當（由外部請求，如 Ryu）新增一條 Flow 時觸發。
- `LinkFailureDetected`：拓樸中偵測到鏈路失效時觸發。
- `IdleFlowPurged`：閒置的 Flow 被清除時觸發。
- `LinkRecoveryDetected`：拓樸中偵測到鏈路恢復時觸發。
- `SwitchEntered`：新交換機加入網路時觸發。
- `SwitchExited`：交換機離開網路時觸發。

事件本體由 `Event` 結構體封裝：
```cpp
struct Event
{
    EventType type;
    std::any payload; // 泛型負載，可夾帶各種類型的上下文資料
};
```

## 3. `EventBus` 類別解析

### 3.1 Handler 註冊 (`registerHandler`)
- **機制**：使用 `std::function<void(const Event&)>` 定義 Handler 型別。
- **並行控制**：透過 `std::unique_lock` 對 `m_mutex` (型別為 `std::shared_mutex`) 上寫入鎖，將 Handler 加入至對應 `EventType` 的 `std::vector` 中。

### 3.2 事件發佈 (`emit`)
這段程式碼包含了一個重要的防呆/防死結 (Deadlock) 設計（標記為與 Claude co-developed）：
- **機制**：
  1. 使用 `std::shared_lock` 取得讀取鎖。
  2. 從 `m_handlers` 中找到對應事件的 `std::vector<Handler>`。
  3. **深拷貝**或直接在鎖定範圍外執行？實作中，直接在鎖定範圍內遞迴呼叫 handler。但等一下，註解提到 "Handlers are copied out under the lock and invoked after releasing it"，但在實際程式碼中是：
     ```cpp
     void emit(const Event& event) const
     {
         std::shared_lock lock(m_mutex);
         auto it = m_handlers.find(event.type);
         if (it != m_handlers.end())
         {
             for (const auto& handler : it->second) { handler(event); }
         }
     }
     ```
     *注意：這裡的實作實際上是在 `shared_lock` 仍然持有的情況下呼叫 `handler(event)`。這表示註解與實際實作可能存在落差，或者開發者原本預期複製，但後來改了寫法。這是一個潛在的技術債與死結風險。如果 handler 內又呼叫 `registerHandler`（需要 unique_lock）或再次呼叫 `emit`（重入 shared_lock，C++ 標準未保證），將會導致 Deadlock。*

## 4. 模組關聯與影響
- **上游 (Publishers)**：如 `TopologyAndFlowMonitor` 在偵測到拓樸變更時呼叫 `emit()`。
- **下游 (Subscribers)**：如 `FlowRoutingManager` 監聽 `LinkFailureDetected` 來觸發重新路由。

## 5. 技術債與改進建議
- **Deadlock 風險**：`emit()` 的實作並未如註解所述「在鎖外執行 (invoked after releasing it)」。建議修改 `emit()`：在 `shared_lock` 保護下，將符合的 handlers 拷貝到一個區域的 `std::vector` 中，釋放鎖後，再對這個拷貝的 vector 進行疊代呼叫，確保絕對避免 handler 重入造成的 Deadlock。
