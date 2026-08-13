# NDTwin 系統全圖景：從模組解析到實戰情境

恭喜您來到任務 4.1！我們前面像拆解手錶零件一樣，把 NDTwin Kernel (C++) 與 `intelligent_router.py` (Python) 的內部構造逐一放大檢視過了。

現在，我們要把這些零件全部組裝起來。
這份文件將透過 **三個真實的網路運作情境**，為您詳細推演一個封包、一個使用者指令，是如何在這些龐大複雜的模組之間流竄與運作的。

---

## 🎬 情境一：系統開機與宇宙大爆炸 (System Startup & Discovery)

當您在 Terminal 敲下 `sudo -E bin/ndtwin_kernel` 並啟動 Ryu 的那一刻，系統內部發生了什麼事？

1. **總指揮上陣 (`main.cpp`)**：
   - 詢問您目前的模式（Mininet 還是 Testbed）。
   - 瘋狂地執行 `std::make_shared`，把所有的 Manager (`FlowRoutingManager`, `TopologyMonitor`, `DeviceManager`...) 建立出來，並把它們像俄羅斯娃娃一樣互相注入，最後餵給網路引擎 `ControllerAndOtherEventHandler`。
   - 大喊一聲 `start()`，所有模組的背景執行緒開始狂奔！

2. **拓撲建立與探勘 (`intelligent_router.py` & `TopologyAndFlowMonitor.cpp`)**：
   - Ryu 控制器 (`intelligent_router.py`) 啟動，透過 OpenFlow 連接所有的 OVS 交換機。
   - Ryu 利用 **BFS (廣度優先搜尋)** 演算法，瞬間算好網路上所有主機之間的路由，並下發給硬體 (`install_all_pair_paths`)。
   - 同時，Ryu 大喊：「有新交換機加入了！」並透過 HTTP GET 打向 NDTwin Kernel 的 `/ndt/inform_switch_entered`。
   - NDTwin Kernel 收到通知後，`TopologyAndFlowMonitor` 開始向 Ryu 發送 `curl` 請求，把最新的拓撲結構抓回來，並使用 `Boost.Graph` 畫出虛擬地圖。

3. **生理監測啟動 (`DeviceConfigurationAndPowerManager.cpp`)**：
   - 背景迴圈啟動，開始使用 `snmpget` 或是假資料產生器，每幾秒鐘就偷偷去問交換機：「你現在 CPU 多燙？吃了多少電？」然後存進快取中。

---

## 🎬 情境二：大象流來襲與流量感知 (Traffic Spike & Bandwidth Monitoring)

現在網路平靜地運作中，突然，主機 H1 開始對 H2 傳送 4K 串流影片，頻寬瞬間飆高。NDTwin 是怎麼「感覺」到的？

1. **硬體的抽樣調查 (OVS sFlow)**：
   - 底層的 OVS 交換機被設定了 sFlow，每經過 1000 個封包，就會隨機挑 1 個封包的 Header，打包成 UDP 封包，丟向 NDTwin 所在的 Server (Port 6343)。

2. **高吞吐量神經元接收 (`FlowLinkUsageCollector.cpp`)**：
   - 這裡的 `receiveDatagrams()` 使用 Linux 極速 API `recvmmsg` 一口氣吞下成千上萬的 UDP 封包。
   - 進入 `processSFlowSample()` 進行暴力二進位解碼，發現是 H1 到 H2 的 TCP 封包。
   - 背景的 `calAvgFlowSendingRatesPeriodically()` 計算出這個封包流的吞吐量已經突破了 `MICE_FLOW_UNDER_THRESHOLD`，將它標記為**「大象流 (Elephant Flow)」**。

3. **路徑對齊 (`intelligent_router.py` & `TopologyAndFlowMonitor.cpp`)**：
   - 神經元雖然知道 H1 在傳大檔案給 H2，但它不知道封包是走哪條路！
   - 因此，它向 Ryu 發送 HTTP GET 呼叫 `/ryu_server/all_destination_paths` 詢問路徑。
   - 拿到路徑後，呼叫 `m_topologyAndFlowMonitor->updateLinkInfo()`，把 `Boost.Graph` 地圖上這幾條連線的 `leftBandwidth` (剩餘頻寬) 大幅扣除。

---

## 🎬 情境三：AI 節能指令與網路重構 (AI-Driven Energy Saving)

老闆走進機房，對著 NDTwin 的麥克風說：「*目前流量不大，幫我關掉 3 號交換機來省電，並把流量繞開。*」

1. **意圖接收與翻譯 (`HttpSession.cpp` & `IntentTranslator.cpp`)**：
   - 網頁前端將這段語音轉成文字，打向 NDTwin 的 HTTP API。
   - `HttpSession` 收到這段自然語言，將它丟給 `IntentTranslator`。
   - `LLMAgent` 讀取了地圖現狀與系統 Prompt，把這段話連同環境變數送給 OpenAI GPT 模型。AI 回傳了一組 JSON 指令：「目標：關閉 DPID 3，重路由流量。」

2. **拔插頭 (`DeviceConfigurationAndPowerManager.cpp`)**：
   - 收到 AI 指令後，`DeviceManager` 啟動殺手模式。
   - 如果是 Mininet，它執行 `sudo ovs-vsctl del-br s3` 來消滅交換機。
   - 如果是 Testbed，它打 API 給智慧插座 (Smart Plug)，實體切斷 3 號交換機的電源！

3. **災難發生與緊急繞道 (`intelligent_router.py` & `TopologyAndFlowMonitor.cpp`)**：
   - Ryu 發現 3 號交換機失聯了 (`DEAD_DISPATCHER`)，鏈路斷開 (`EventLinkDelete`)！
   - Ryu 驚恐地向 NDTwin 發送 `/ndt/link_failure_detected` 的 Webhook。
   - `TopologyAndFlowMonitor` 收到 Webhook，緊急將 `Boost.Graph` 上的 3 號節點與相連的邊標記為 `isUp = false`。
   - NDTwin 的路由模組發現大象流的舊路徑斷了，於是呼叫 `getAllPathsBetweenTwoHosts`，利用 **DFS (深度優先搜尋)** 在斷線的地圖上找到了一條新的備援路徑。

4. **非同步下發新規則 (`FlowDispatcher.cpp` & `FlowRoutingManager.cpp`)**：
   - 為了不讓主系統卡住，新算出的 10 條 OpenFlow 規則被丟進了 `FlowDispatcher` 的佇列中。
   - 背景 Worker Thread 默默地把這些規則一條條透過 `FlowRoutingManager` 打包成 `curl`，送給 Ryu 的 `/stats/flowentry/add`。
   - Ryu 最終將規則寫入硬體，影片串流在瞬間的卡頓後，成功繞過 3 號交換機繼續播放，完美達成了老闆的節能指令！

---

> [!IMPORTANT]
> **您的下一步：P4-Proxy-Agent (Task 5 預告)**
> 
> 看完這三個情境，您應該已經發現，**`intelligent_router.py` 以及所有發往 Ryu 的 API** 貫穿了整個系統的心臟。
> 在您的 P4 專案中，您的 Python `P4-Proxy-Agent` 必須完美地「扮演 Ryu 的角色」，接管上述情境中所有 Ryu 該做的事情（包含接收 P4 封包、主動打 Webhook 給 C++、提供路徑給神經元），這樣才能在最小幅度修改 C++ 核心的情況下，讓 NDTwin 平滑升級到 P4 時代！
