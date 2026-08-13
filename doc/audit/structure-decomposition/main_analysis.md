# main.cpp 檔案架構與功能深度解析

`src/main.cpp` 是整個 NDTwin Kernel 的**程式進入點 (Entry Point)** 與 **依賴注入的根節點 (Composition Root)**。它就像是交響樂團的指揮家，負責在系統啟動時把所有樂手 (各個 Manager) 就定位，發給他們對應的樂譜，然後宣佈演奏開始。

以下為您詳細剖析這份檔案的核心功能：

---

## 1. 互動式啟動配置 (Interactive Configuration)

在 `main()` 函式一開始，系統並不會立刻啟動，而是呼叫了 `promptDeploymentConfig()` 進行互動式配置：
* **網路模式選擇**：詢問使用者是在 `[1] Local Mininet` 還是 `[2] Remote Testbed` 環境執行。這個 `mode` 變數會被一路傳遞到幾乎所有的 Manager 中，用於決定底層要呼叫哪種 API。
* **AI 意圖翻譯開關**：詢問是否啟用 `IntentTranslator` (基於 OpenAI 的功能)。如果使用者選否，則傳遞 `nullptr` 給後面的系統，避免非必要的 API 呼叫。

## 2. 信號處理與優雅關機 (Signal Handling & Graceful Shutdown)

伺服器程式需要能夠安全地被中斷（例如使用者按下 `Ctrl+C`），這在 `main.cpp` 中處理得非常乾淨：
1. **註冊信號**：`std::signal(SIGINT, handleSigint);` 攔截中斷信號。
2. **原子旗標**：當收到信號時，只將一個全域的原子變數 `gShutdownRequested` 設為 `true`。
3. **主執行緒等待**：`main` 函式在啟動完所有服務後，會進入一個休眠迴圈：
   ```cpp
   while (!gShutdownRequested.load()) {
       std::this_thread::sleep_for(std::chrono::milliseconds(200));
   }
   ```
4. **依序關閉**：一旦跳出迴圈，會非常有秩序地呼叫每個子系統的 `stop()` 函式，確保資料夾清理完畢、Socket 正常關閉後才正式退出 `return 0;`。

## 3. 系統依賴注入根節點 (Composition Root)

這是 `main.cpp` 最重要、也佔最多篇幅的職責。

在一個設計良好的物件導向系統中，業務模組（例如 `FlowRoutingManager`）不應該自己去 `new` 出它所依賴的其他模組（例如 `EventBus`），而是由最外層的系統（也就是 `main.cpp`）將準備好的依賴「注入 (Inject)」給它。

您可以看到在 120 行之後，`main.cpp` 執行了大量的 `std::make_shared`：
1. 先建立最底層、無依賴的物件：`Graph` (拓撲圖)、`EventBus` (事件匯流排)、`Classifier`。
2. 接著建立第一層 Manager：`TopologyAndFlowMonitor`。
3. 然後把建立好的物件，當作參數傳給第二層 Manager 的建構子：`DeviceConfigurationAndPowerManager`、`FlowLinkUsageCollector`。
4. 一層層往上堆疊，直到建立最後一個把所有東西統整起來的網路引擎：`ControllerAndOtherEventHandler`。

> **小提示**：這種設計方式讓模組之間的耦合度降到最低，非常有利於單元測試。

## 4. 啟動背景服務 (Starting Background Services)

在所有的物件都互相「認識」彼此之後，`main.cpp` 會呼叫各個 Manager 的 `start()` 函式：
```cpp
topologyAndFlowMonitor->start();
collector->start(20, 4096);
dataManager->start();
handler->start();
deviceConfigurationAndPowerManager->start();
```
這些 `start()` 函式內部通常會**開啟新的執行緒 (Threads)** 或**註冊定時器 (Timers)** 來開始在背景執行無窮迴圈（例如定期向 Ryu 抓取封包資訊）。主執行緒 (Main Thread) 的工作到此結束，轉入監控 `Ctrl+C` 的休眠迴圈。

---

> [!TIP]
> **給 P4 開發者的重點總結：**
> 
> 未來您在開發 P4 Proxy 時，如果您需要增加一個全新的類別（例如 `P4ProxyCommunicationManager`），您需要做的事情就是：
> 1. 在 `main.cpp` 中使用 `std::make_shared` 將它實例化。
> 2. 將它作為參數，注入給 `ControllerAndOtherEventHandler`，讓它有機會被 `HttpSession` 使用。
> 3. 在迴圈前呼叫它的 `start()` 函式啟動它。
> 4. 在關機邏輯中加上它的 `stop()` 確保安全退出。
