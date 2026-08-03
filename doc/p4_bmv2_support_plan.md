# 為 NDTwin-Kernel 加上 P4/bmv2 支援 — 開發計畫

---

## 目前進度（最後更新 2026-07-29，branch `fix/flow-rate-divide-by-zero`）

測試流程與實測數據見 [p4_status_and_test_guide.md](p4_status_and_test_guide.md)。

| Phase | 狀態 | 備註 |
|---|---|---|
| **0** 止血 | ✅ 完成 | SIGFPE 守衛、測試真的會跑、ifIndex map 加鎖 |
| **1** typed SwitchKind | ✅ 完成 | `9910151`。O(1) 分派、同質性驗證、headless CLI |
| **2** 失敗看得見 | ✅ 完成 | `7856efc`、`08746f4`。`OpResult` + 真實 HTTP status |
| **4** P4 pipeline | ✅ 完成 | `4577983`。5-tuple ternary、ARP、TTL、取樣、counter |
| **5** telemetry | ✅ **完成並實機驗證** | `c3a1317`、`9a46b4b`、`6bc98d4`。見下方 |
| **6** 拓撲／liveness／flow table | ⬜ **下一步** | 最大的缺口。入手點見下方 |
| **3** proxy 端點補完 | ⬜ 未做 | `/stats/flowentry/delete`、prefix 解析、idle_timeout、加鎖 |
| **7** 電源管理 | 🟨 一半 | PID manifest 已做（`22ada58`，`/tmp/ndtwin_p4_switches.json`）；`P4PowerStrategy` 還沒用它 |
| **8** 收尾 | ⬜ 未做 | |

### Phase 5 實機驗證結果（2026-07-29，10 台真實 bmv2）

整條鏈通了：**bmv2 取樣 → clone 到 CPU → packet-in → proxy → emitter → kernel 解析出正確 flow**。

- `rx=126, app_drop=0, addressed=126` —— `rx` 等於 `addressed` 表示**每個 datagram 都成功歸戶到 agent**
- 取樣數符合模型：2700 封包 × 10 跳 ÷ 256 ≈ 105，實測 107
- 雙向 ICMP flow 都正確解析（type 8 code 0 / type 0 code 0，放在 port 欄位）
- bmv2 fabric 本身也證實可轉發：`ping` 0% loss、`ttl=59`（5 跳 + TTL 遞減有效）
- L4 差異比對 `PASS`：170 個已登記差異、**0 個未預期**

### Phase 6 的具體入手點（含 2026-07-29 新發現）

計畫本體見下面的 Phase 6 章節，這裡補上實測才發現、會影響實作的細節：

1. **`updateHosts` 的 `ipv4` 前置條件擋掉了 127/128 台 host**（連 OVS 模式都是）。
   [TopologyAndFlowMonitor.cpp](../src/ndt_core/collection/TopologyAndFlowMonitor.cpp) 的 `updateHosts`
   開頭有 `if (host["ipv4"].empty()) continue;`。但 `testbed_topo.py` 幫每台 host 設了 static ARP
   （`arp -s`），host 因此永不發 ARP，而 Ryu 的 host tracker 是從 ARP 學 IP —— 所以 Ryu 回報 128 台
   host 卻只有 1 台有 IPv4。結果 **254/256 條 host edge 永遠是 down**，`get_graph_data` 的 L2 契約
   因此過不了。
   值得注意的是：**vertex 是用 MAC 比對的**（`findVertexByMac`，沒有 IP 也能成功），只有 **edge 用 IP**
   （`findEdgeByHostIp`）。所以那個 early `continue` 比實際需要的更嚴格。要改的話得先決定 edge 能不能
   改用 MAC 對應 —— 這動到共用的 OVS 路徑，不能只為 P4 改。

2. **`/stats/flow/{dpid}` 的回傳形狀要對齊**。kernel 文件（和 OVS 模式）是
   `flows` = `{table_id: [entries]}` 的 map；P4 proxy 目前的 stub 回傳裸 list。實作時要用 map，
   否則 L2 契約會報型別錯誤。`Classifier::parseActionsArrayIntoEffect` 也**只認字串形式的 action**
   （`"OUTPUT:1"`），不認 `{"type":"OUTPUT","port":N}`。

3. **`get_path_switch_count` 目前回 `{"status":"error","message":"Path not found..."}`** 是正確行為，
   不要改成回假的數字。Phase 6 做完之後它自然會回真實的 `switch_count`。

4. **kernel 的 pull 只做一次、沒有重試**（`TopologyAndFlowMonitor::run()` 呼叫
   `fetchAndUpdateTopologyData()` 一次就結束）。這是為什麼 kernel 一定要最後開、而且要等收斂。
   Phase 6 應該加 refresh loop，這樣就不再依賴啟動時序。

5. **OVS 模式需要 Ryu 多載兩個 stock app**（已修進 `stack.sh`）：`ryu.app.rest_topology` 提供
   `/v1.0/topology/*`，`ryu.app.ofctl_rest` 提供 `/stats/flow/<dpid>` 和 `/stats/flowentry/*`。
   `intelligent_router.py` 只提供 `/ryu_server/all_destination_paths`。

---

## 背景

NDTwin-Kernel 是 NDTwin 數位孿生系統的 C++ 核心（架構說明見 `ndtwin.org/docs/architecture/`）。它做三件事：收集 sFlow 流量資料、在記憶體裡維護一張網路拓撲圖、透過 Ryu OpenFlow 1.3 controller 去控制 Open vSwitch 的流量規則和電源。

這次的目標是讓它也能控制 **Mininet 上的 P4/bmv2 交換器**，而且功能要一樣完整 — 也就是現有的 NDTwin 應用程式（Traffic-Engineering、Energy-Saving）和 Intent Translator 都不用改，就能直接在 P4 環境上跑。

Commit `6f32bca` 已經把基礎打好了：`IRoutingStrategy`/`IPowerStrategy` 兩個策略介面、一個假扮 Ryu 北向 API 的 FastAPI P4 proxy agent、`ndtwin_switch.p4` pipeline，還有 10 台 switch／4 台 host 的 bmv2 Mininet 拓撲。方向是對的，但 P4 這條路目前還沒辦法完整跑通，而且那個 commit 順手帶進了一個會讓程式當掉的錯誤。

**已經決定的事（2026-07-27）：**
- 由 proxy 自己組出 sFlow v5 封包，送進 kernel 現有的 UDP:6343 收集器
- P4 pipeline 要擴充成有真正 priority 的 5-tuple ternary table
- 每次執行只跑全 P4 或全 OVS，但底層用 per-DPID 分派來做，以後要支援混合拓撲只要改設定
- 要修掉當機、錯誤傳遞、每次操作複製整張圖這三個問題
- shell injection 的修補留到之後獨立處理

### 目前實際壞掉的地方（每一項都已經驗證過，不是猜的）

| # | 問題 | 位置 |
|---|---|---|
| 1 | **程式會被 SIGFPE 殺掉。** `6f32bca` 把 `if (hopsCounter == 0) continue;` 刪掉了，但 `hopsCounter` 還是被當除數用。只要有一條 flow 停了一個 1 秒週期，就會整數除以 0。同一個檔案第 1424 行的姊妹函式還留著這個保護，可見是不小心刪的。 | [FlowLinkUsageCollector.cpp:1309](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L1309), [:1322](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L1322) |
| 2 | **`P4RoutingStrategy.cpp` 是 `OpenFlowRoutingStrategy.cpp` 的複製品**（用 `diff` 把類別名字換掉後比對，完全一樣）。它只是把 OpenFlow 格式的 JSON 丟到 port 8081 而已。它的 `deleteAnEntry` 預設 `priority == -1`，會打到 `/stats/flowentry/delete`，但 proxy 沒有實作這個端點；group/meter 那幾個方法打的端點也不存在。 | [P4RoutingStrategy.cpp:29-33](../src/ndt_core/routing_management/P4RoutingStrategy.cpp#L29-L33) |
| 3 | **完全沒有流量資料。** bmv2 不會產生 sFlow，P4 的拓撲檔也沒設定 sFlow。所以 P4 模式下所有速率、鏈路使用率、流量路徑都是 0 或空的。 | `p4_proxy/mininet/p4_testbed_topo.py`（沒有 sflow 設定），對照 [testbed_topo.py:105-119](../testbed_topo.py#L105-L119) |
| 4 | **整張拓撲圖都停在 `isEnabled=false`。** node 和 edge 初始都是 false，只有 Ryu 的 REST 回應或 `/ndt/inform_switch_entered` 會把它翻成 true，但 P4 這邊沒有任何元件會去呼叫。結果 BFS 找路徑、flow table 輪詢、鏈路使用率、還有一半的 `/ndt/` API 全部變成空的，而且不會報錯。 | [TopologyAndFlowMonitor.cpp:116-117](../src/ndt_core/collection/TopologyAndFlowMonitor.cpp#L116-L117), [HttpSession.cpp:933](../src/ndt_core/http/HttpSession.cpp#L933) |
| 5 | **P4 的存活偵測是假的。** 只要拓撲檔名裡有 `"P4"` 這幾個字，`pingWorker` 就無條件把每台 switch **和每台 host** 標成 up。所以你把一台 switch 關掉，1 秒內它又會顯示 UP，數位孿生永遠反映不出故障。 | [DeviceConfigurationAndPowerManager.cpp:364-369](../src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp#L364-L369), [:385-389](../src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp#L385-L389) |
| 6 | **P4 關機功能有兩個錯。** `sudo mnexec -a s1 …` 裡的 `mnexec -a` 要的是 **PID**，不是名字，所以這行指令根本不會執行；而且就算能執行，`pkill -f simple_switch_grpc` 會把**十台 switch 全部殺掉**（Mininet 的 node 共用 PID namespace）。至於 `powerOn`，它是個什麼都沒做就回傳 `true` 的空殼。 | [P4PowerStrategy.cpp:35](../src/ndt_core/power_management/P4PowerStrategy.cpp#L35) |
| 7 | **所有南向的失敗都看不見。** `curl -s` 沒加 `--fail`、回傳值被丟掉、介面回傳型別是 `void`、proxy 無條件回 `True`、`p4_client` 把所有 gRPC `UNKNOWN` 都吞掉。結果 proxy 掛掉和安裝成功，從 kernel 的角度看起來一模一樣。 | [P4RoutingStrategy.cpp:17](../src/ndt_core/routing_management/P4RoutingStrategy.cpp#L17), `topology_manager.py:108`, `p4_client.py:216-217` |
| 8 | **每下一條規則就完整複製一份整張 BGL 圖，再做一次 O(V) 線性搜尋。** 而且每個 DPID 各有一條 worker thread，全部搶同一把 shared mutex。重構前這個成本是 0；現在一批 2000 筆規則就會複製整張圖 2000 次。 | [FlowRoutingManager.cpp:52-56](../src/ndt_core/routing_management/FlowRoutingManager.cpp#L52-L56) |
| 9 | **兩個 test fixture 會互相干擾，而且測試內容就是在確認那個 bug。** 兩個 fixture 都在 `SetUpTestSuite` 裡呼叫 `Logger::init`，所以當它們跑在同一個 process 時，第二次會丟出 `logger with name 'netdt' already exists`，該 suite 的測試被 SKIPPED（整個 binary exit 1）。`ctest` 讓每個測試跑在獨立 process 且各帶 `--gtest_filter`，於是這個條件從未成立 —— 那些測試在 ctest 下是真的有跑也真的通過，只是「多 suite 共用 process」這個情境永遠沒被驗到。而測試裡的斷言，是把問題 #2（複製品的行為）當成正確行為寫死。 | [test_P4RoutingStrategy.cpp:27-32](../tests/test_P4RoutingStrategy.cpp#L27-L32), [Logger.cpp:68](../src/utils/Logger.cpp#L68) |
| 10 | 設定錯了不會有任何提示：未知的 DPID 或拼錯的 `brand_name`，都會**安靜地**退回用 Ryu，連一行 log 都沒有。`"BMv2"` 這個字串散在 3 個地方。而判斷是 P4 還是 OVS 的方式，竟然是對*檔名*做大小寫敏感的子字串比對。 | [FlowRoutingManager.cpp:57-64](../src/ndt_core/routing_management/FlowRoutingManager.cpp#L57-L64) |
| 11 | `P4_PROXY_IP_AND_PORT` 只寫在被 gitignore 的 `setting/AppConfig.hpp`，**沒有**寫進 `AppConfig.hpp.example`。所以別人重新 clone 下來會編譯失敗。 | `setting/AppConfig.hpp.example` |
| 12 | `NDTWIN_TOPO_FILE` 這個環境變數，4 個該用的地方只有 1 個真的用了。`setVertexDeviceName`／`setVertexNickname` 會去讀 `TOPOLOGY_FILE_MININET`，*然後用 rename 覆寫它*。所以你在 P4 環境下改一個裝置名稱，會**把 OVS 的拓撲 JSON 弄壞**。 | [TopologyAndFlowMonitor.cpp:1284-1291](../src/ndt_core/collection/TopologyAndFlowMonitor.cpp#L1284-L1291), [:1372-1379](../src/ndt_core/collection/TopologyAndFlowMonitor.cpp#L1372-L1379) |

**按你的決定先不修，但要記錄下來：** 所有南向指令都長這樣 `popen("curl … -d '" + json.dump() + "'")`。`nlohmann::json::dump()` 不會轉義單引號 `'`，而這些 JSON 來自沒有驗證的 REST 請求內容和 LLM 的輸出。所以只要 match 欄位裡放 `'; …; #`，就能用 kernel 的身分執行任意 shell 指令 — 而這個身分平常還會執行 `sudo`。`6f32bca` 還把這段複製到第二個檔案去了。這件事應該在任何非實驗室環境上線之前，獨立處理掉。

---

## 幾個開發原則

- **Proxy 要維持 Ryu 的樣子。** 它的工作就是假扮 Ryu，讓 NDTwin 的應用程式完全不用改。如果 P4 真的做不到某件事，proxy 要回傳明確的錯誤讓 kernel 記錄下來 — **絕對不可以安靜地裝作成功**。
- **所有新寫或 AI 協作的程式碼都要標 `[Co-developed with claude code -- Adam]`。** 現有的 P4 檔案用的是 Gemini 的標記，保留它們的，我們自己寫的部分加上我們的。
- **per-DPID 分派是「機制」，同質性檢查是「政策」。** 所有東西都用 DPID 當 key，這樣以後要開放混合拓撲，只是把一個檢查拿掉，不用重新設計。
- 用小而好審的 commit 進版：Phase 0 走 `fix/flow-rate-divide-by-zero`，之後走 `feat/p4-support`。

---

## Phase 0 — 先止血，讓測試真的會跑

當機沒修掉、測試框架沒真的在跑之前，後面做什麼都無法相信。這個階段純粹是修東西，不碰任何 P4 邏輯。

1. **把除以 0 的保護加回來**（[FlowLinkUsageCollector.cpp:1303](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L1303)），並把 `:1317,:1321` 那兩處從 `SPDLOG_LOGGER_TRACE` 改成 `INFO` 的動作改回去（它們在每條 flow、每秒都會跑的迴圈裡，而且搭配 `flush_on(info)` 會造成每寫一行就同步 flush 一次）。
2. **讓速率計算變得可以測試。** 把 `calAvgFlowSendingRatesPeriodically` 這個 300 行函式裡的算術抽成一個獨立的小函式（`computeEstimatedRates(accumulatedBytes, hopsCounter, …) -> {flowRate, packetRate}`），然後讓 `:1398` 的姊妹函式也用它。這樣 `hopsCounter == 0` 這個情況就能寫單元測試了。
3. **修掉測試框架重複初始化的問題。** 把 `Logger::init` 移到 gtest 的全域環境（`::testing::AddGlobalTestEnvironment`），或是用 `spdlog::get("netdt")` 先檢查。一定要確認**直接執行**測試執行檔時 exit code 是 0，不能只看 `ctest`。
4. **修好測試的連結設定**（[tests/CMakeLists.txt](../tests/CMakeLists.txt)）— 補上 `NdtCore_CollectionLib`、`EventSystemLib`、`ssh`。現在能連結成功，只是因為沒有任何測試碰到 `FlowRoutingManager`；Phase 1 的分派測試會需要這些。
5. **別讓 `-Werror` 跑到 googletest 上。** [CMakeLists.txt:50](../CMakeLists.txt#L50) 的 `add_compile_options(… -Werror)` 在 `:126` 的 `FetchContent_MakeAvailable(googletest)` 之前執行，所以會影響到抓下來的第三方程式碼。把這些旗標移到 `src/` 各個子目錄裡。
6. **保護 ifIndex 對照表。** [FlowLinkUsageCollector.cpp:1051-1052](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L1051-L1052) 在**沒有拿 `m_ifIndexMapMutex`** 的情況下對 `m_ifIndexToOfportMap` 用 `operator[]`。這是 data race，而且會讓表無上限地長大，還會把每個查不到的 port 都安靜地變成 0。改成在 `shared_lock` 下用 `find()`。
7. 把 `P4_PROXY_IP_AND_PORT` 加到 `setting/AppConfig.hpp.example`（問題 #11）。
8. 在 `TopologyAndFlowMonitor::stop()` 裡 join `m_flushEdgeFlowLoop` — 現在只 join 了 `m_thread`，所以 `std::thread` 解構時還是 joinable 狀態，關閉程式時會 `std::terminate`。

**測試：** `computeEstimatedRates` 在 `hopsCounter == 0`（防止 SIGFPE 再發生）和正常數值下的行為。確認 `./build/tests/test_routing_strategy` exit 0，而且 4 個測試真的都執行了。

---

## Phase 1 — 用型別取代字串，讓分派變成 O(1)

把字串比對的 `brand_name` 和檔名猜測，換成編譯器會幫你檢查的型別，同時把每次操作都複製整張圖的問題解決掉。

- 在 [GraphTypes.hpp](../include/common_types/GraphTypes.hpp) 加上 `enum class SwitchKind { OVS, BMV2, HARDWARE }`，放進 `VertexProperties`。在 [TopologyAndFlowMonitor.cpp:120](../src/ndt_core/collection/TopologyAndFlowMonitor.cpp#L120) 解析一個選填的 `"switch_kind"` JSON 欄位，**沒有這個欄位時就退回去對照現有的 `brand_name`**（`"BMv2"`→BMV2、`"OVS"`→OVS、其他→HARDWARE）。這樣兩份現有的拓撲 JSON 都不用改就能繼續用。
- 在 `FlowRoutingManager` 和 `DeviceConfigurationAndPowerManager` 裡，載入拓撲時**一次**建好 `std::unordered_map<uint64_t, IRoutingStrategy*>`（node 只在 `loadStaticTopologyFromFile` 裡新增，所以這樣做是安全的）。`getStrategyForDpid` 就變成單純的 hash 查表 — 整張圖的深拷貝和 O(V) 搜尋都不見了（問題 #8）。
- **遇到未知的 DPID → 寫 `SPDLOG_WARN` 並回傳錯誤**，不要安靜退回 Ryu（問題 #10）。
- 把 `DeviceConfigurationAndPowerManager` 裡那兩處 `getenv("NDTWIN_TOPO_FILE").find("P4")` 換成用 `SwitchKind` 判斷。要注意 `:383-389` 那段處理 host 的分支，位置在 TESTBED／else 判斷之外，所以現在只要環境變數殘留著，連 **TESTBED** 模式下的 host 都會被強制標成 up。
- **載入拓撲時檢查同質性**：如果各台 switch 的 `SwitchKind` 不一致，就直接以致命錯誤中止，並印出是哪些 DPID 有問題 — 除非設了 `AppConfig::ALLOW_MIXED_DATAPLANE`。這個開關就是以後要支援混合拓撲時唯一要動的地方。
- 把 `main.cpp` 裡互動式的 `std::cin` 問答改成命令列參數（`--mode`、`--topology`、`--no-ai`），只有在 TTY 下才退回互動模式。現在 headless CI 根本沒辦法啟動 kernel。同時修掉依賴當前目錄的 `../setting/…` 路徑，並且不要再用 `setenv(…, 1)` 去覆蓋使用者自己設好的 `NDTWIN_TOPO_FILE`。
- 修問題 #12：讓 `setVertexDeviceName`／`setVertexNickname` 去讀寫*當前實際在用*的拓撲檔，而不是寫死的 `TOPOLOGY_FILE_MININET`。

**測試：** `getStrategyForDpid` 對 BMV2 的 DPID 要回 P4 策略、對 OVS 的要回 OVS 策略、對未知 DPID 要回錯誤並發警告；只有 `brand_name` 的 JSON 還是要能正確分類（向後相容）；混合拓撲在預設下要驗證失敗，設了旗標後要通過。

---

## Phase 2 — 讓失敗看得見

這是後面所有工作的前提。沒有這個，我們根本分不出 P4 那條路是正常還是壞掉。

- 把 `IRoutingStrategy`／`IPowerStrategy` 的方法改成回傳一個小結構 `OpResult { bool ok; int httpStatus; std::string message; }`。參數從傳值改成 `const nlohmann::json&`（省掉每次操作第二次的 JSON 深拷貝）。把 [IRoutingStrategy.hpp:19-20](../include/ndt_core/routing_management/IRoutingStrategy.hpp#L19-L20) 純虛擬函式上的預設參數移掉 — 虛擬函式的預設參數是看指標的靜態型別決定的，很容易踩到坑；這些預設值應該放在 `FlowRoutingManager` 的公開 API（那裡本來就有）。
- 讓策略拿到真正的 HTTP 狀態碼：`curl -s -o - -w '\n%{http_code}' --max-time 5`（保留 `-s`，解析結尾的狀態碼）。不是 2xx 就用 WARN 記下來，附上 dpid 和端點。
- 一路往上傳：`FlowRoutingManager` → `Controller`／`FlowDispatcher` → `HttpSession`，讓 `/ndt/install_flow_entry` 和批次端點能回報部分失敗，而不是一律回 200。
- 別再在 `setPowerStateMininet`（[DeviceConfigurationAndPowerManager.cpp:798-807](../src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp#L798-L807)）把 `bool` 丟掉，而且遇到看不懂的 `action` 要回報錯誤，不要記成成功。
- Python 端：`p4_client` 每個方法都回傳明確結果；不要再對 gRPC `UNKNOWN` 直接 `pass`（bmv2 也用這個代碼表示真的失敗 — 改成先 `INSERT`，遇到 `ALREADY_EXISTS` 再改用 `MODIFY`）；`topology_manager.route_flow` 要回傳真實結果，不要寫死 `True`；補上 `modify_ipv4_route` 漏掉的 `return True`，現在這個漏洞讓**每次成功的 modify 都回傳 HTTP 400**。

**測試：** 用 mock 讓 `executeCommand` 回 `404`／`500`／timeout，確認 `OpResult.ok == false` 而且訊息正確；確認參數是 `const json&`（編譯期就能檢查）；Python 端用 `pytest` 搭配 mock 的 gRPC stub，確認 insert／modify／delete 的結果真的有傳上來。

---

## Phase 3 — 真正屬於 P4 的南向實作

- 把共用的 curl／JSON 組裝抽出來變成 `HttpRoutingStrategyBase`（提供 protected 的 `post(path, json) -> OpResult`，保留現有的 `executeCommand` 虛擬函式當測試用的接口）。`OpenFlowRoutingStrategy` 和 `P4RoutingStrategy` 就變成上面很薄的一層路由表 — 那 140 行的複製品就消失了（問題 #2）。
- `P4RoutingStrategy` 只覆寫真正不一樣的部分，並且**明確講出自己的限制**：group／meter 回傳 `OpResult{ok:false, "unsupported on P4"}`，而不是像現在安靜地轉給 Ryu。在 `FlowRoutingManager` 裡讓 group／meter 也走 per-DPID 分派（它們**確實**帶了 dpid — [FlowRoutingManager.cpp:96](../src/ndt_core/routing_management/FlowRoutingManager.cpp#L96) 那句「沒有指定 DPID」的註解跟事實不符）。
- Proxy：把缺的 **`POST /stats/flowentry/delete`**（非 strict）實作出來。所有 `priority == -1` 的刪除都走這條，包括 Intent Translator 發出的。
- Proxy：`route_flow`／`unroute_flow` 裡寫死的 `/32` 要改成真正解析 prefix（`"10.0.0.0/24"` 和 masked-pair 兩種寫法），這樣聚合路由才能用。
- Proxy：用 asyncio timer 幫每筆規則模擬 `idle_timeout`，時間到就刪掉（kernel 的表格模型假設 flow 會自己過期）。
- 加一個 `dpid → grpc_addr` 對照，**從 kernel 讀的同一份拓撲 JSON** 載入，取代 `main.py` 裡寫死的 `range(1, 11)`／`50050+i`／手工列出的 4 台 host。
- 幫 `TopologyManager.net`／`switches`／`dest_paths` 加鎖 — 它們會被 LLDP thread 和 gRPC receiver thread 修改，同時又被 HTTP handler 讀取。把會阻塞的 gRPC 呼叫和 all-pairs BFS 移出 event loop（`run_in_executor`）。

**測試：** 用 gtest 確認 `P4RoutingStrategy` 每個操作發出的路徑和內容都正確（要重寫現有的測試，它們現在確認的是複製品的行為）；非 strict 刪除要真的打到 `/stats/flowentry/delete`；group／meter 要回 unsupported。用 pytest 測 prefix 解析（`/24`、`/32`、masked pair）和 idle-timeout 到期。

---

## Phase 4 — 擴充 P4 pipeline

現在的 `ndtwin_switch.p4` 完全不解析 L4，只有一張以目的 IP 為 key 的 LPM table。它沒辦法表達 NDTwin 應用程式和 Intent Translator 發出的 5-tuple 規則，而 LPM table 本身也沒有 priority 這個概念。

- 解析 ARP、TCP、UDP、ICMP（現在只有 Ethernet 和 IPv4；ARP 和所有非 IPv4 的封包因為沒設 `egress_spec`，都被安靜丟掉了）。
- 新增 `table flow_5tuple` — 用 **ternary**，key 是來源／目的 IP、proto、來源／目的 port、in_port，有真正的 `priority`；`ipv4_lpm` 留著當後備。兩張表都掛 direct counter。
- 加 `ActionSelector` 來做 ECMP，這樣 group entry 在 P4 上才有對應的東西（`VertexProperties::ecmpGroups` 已經存在，而 OVS 那邊的 `intelligent_router.py:365` 已經有做 hash-biased ECMP）。
- **為流量資料做取樣（給 Phase 5 用）：** 用 `clone3`／`clone_preserving_field_list` 把 1/256 的封包複製到 CPU port，並帶上 ingress port、egress port 和原本的 frame 長度 — 跟 OVS 的 `sampling=256` 一致，這樣速率計算完全不用改。
- 加 per-port 的 byte／packet counter 來算鏈路使用率。
- 修 `ipv4_forward`：現在沒有檢查 TTL 是否為 0，所以 TTL 會從 0 繞回 255。
- 重新產生 p4info；**把過期的 `p4_src/build/ndtwin_switch.p4.p4info.txt` 刪掉** — 它跟新檔案一模一樣，只差少了 `counters` 那一段，一旦被載入，counter 讀取就會安靜地回傳 `(0,0)`。
- 在 `p4_testbed_topo.py` 把 `TCLink` 的頻寬設定加回來（OVS 拓撲用的是 1000／10000 Mbps；P4 這份把它拿掉了，但 `GraphTypes.hpp` 和兩份拓撲 JSON 都假設鏈路是 1 Gbps）。

**測試：** 編譯把關（CI 裡跑 `p4c-bm2-ss`）。用 scapy 對 2 台 switch 的 bmv2 Mininet 做行為測試：5-tuple 要命中正確的 port、兩筆重疊的 ternary 規則要按 priority 排序、ARP 要能轉送、TTL 要遞減而且 TTL 剩 1 的封包要被丟掉、clone-to-CPU 的觸發頻率要符合預期。

---

## Phase 5 — 流量資料：讓 proxy 變成 sFlow agent

這是價值最高的一個階段，也是讓「數位孿生」真的名副其實的關鍵。因為 proxy 會發出真正的 sFlow v5 到 `127.0.0.1:6343`，所以 **`FlowLinkUsageCollector`、`Classifier` 和所有 `/ndt/` 指標都不用改就能運作** — kernel 完全分不出來是 OVS 還是 P4。

風險在於 kernel 的解碼器不是通用的 sFlow 函式庫，而是手寫的、用固定 word offset 去讀的解析器 — 分成 `sampleType 1/2`（標準 flow／counter）和 `3/4`（expanded），而且 index 前進的方式在 MININET 模式下還有特例：

```
data[0] version(5)   data[2] agentIp   data[6] sampleCount   index=7
sampleType==1 (flow):    +4 samplingRate  +7 inputPort  +11 flowDataLen
                         +13 frameLength  +19 etherType  +21 proto  +22.. ip/ports
sampleType==2 (counter): +4+15+3 ifIndex  +5..6 ifSpeed  +9..10 inOctets  +17..18 outOctets
```
[FlowLinkUsageCollector.cpp:691-760](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L691-L760), `:886-1010`

所以我們發出的封包必須**連 byte 排列都一樣**。而證明的方式是用 golden fixture 去比對，不是把 offset 再讀一遍去對照。

- 新增 `proxy_agent/sflow_emitter.py`：
  - **flow sample（type 1）** 來自 clone-to-CPU 的封包：用 `sampled_header` record 裝原始 frame，`ifIndex` 填 P4 的 port，`sampling_rate` 填 256，input／output port 從 clone 帶來的 metadata 取。
  - **counter sample（type 2）** 來自定期輪詢的 P4 per-port counter，帶上 `ifIndex`／`ifSpeed`／`ifInOctets`／`ifOutOctets`。
  - 每台 switch 的 `agent_address` 要用拓撲 JSON 裡那台 switch 的 IP（`192.168.123.11+`），因為 kernel 就是靠 `AgentKey{agentIP, port}` 把 sample 對應到圖上的 edge。
- Kernel：P4 模式下跳過 `populateIfIndexToOfportMap`（它會呼叫 `ovs-vsctl`，在 bmv2 下什麼都不會回傳），改用 **identity** 的 ifIndex→port 對應，因為我們發出去的本來就是 P4 的 port 編號。

**最關鍵的測試 — golden datagram 往返比對。** 從目前能正常運作的 OVS testbed 抓一份真實的 sFlow 封包（在 :6343 上 `tcpdump -w`），存成 fixture 進版控。然後：
1. 用 gtest 把抓到的 OVS bytes 餵給 `handlePacket`，確認解析出來的 `FlowKey`／port／frameLength／samplingRate 都正確。
2. 讓 Python emitter 針對*同一筆邏輯上的 sample* 產生一份封包寫成 fixture；同一個 gtest 餵進去，確認解析結果**完全相同**。

這樣就把 byte 相容性鎖在 CI 裡，「offset 有沒有寫對」變成一個紅燈綠燈的問題。`handlePacket` 現在是 private — 改成 `protected`（或把測試設成 friend）當作測試入口。

---

## Phase 6 — 拓撲、存活偵測、flow table 要跟 Ryu 一致

這裡修的是問題 #4 和 #5 — 也就是 P4 模式下拓撲圖像死掉一樣的原因。Ryu 會主動**推**資料給 kernel，但 proxy 現在什麼都不推。

- 讓 proxy 照著 `intelligent_router.py` 的做法去呼叫 kernel 的北向 API：
  - 拿到 P4Runtime mastership 時呼叫 `GET /ndt/inform_switch_entered?dpid=N` — 這是**唯一會把 `isEnabled` 設成 true 的路徑**，光做這一件事就能解開 BFS 找路徑、flow table 輪詢和鏈路使用率。
  - LLDP beacon 逾時／恢復時呼叫 `POST /ndt/link_failure_detected`／`link_recovery_detected`（可以參考 `intelligent_router.py:597,624`）。
  - 用 `POST /ndt/inform_all_destination_paths` 主動推路徑。這比修 pull 那條路好，因為 `fetchAllDestinationPaths` 只在啟動時被呼叫**一次**（[FlowLinkUsageCollector.cpp:300](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L300)），時間點比 LLDP 探索收斂還早，而它那句 `if (output.empty()) return;` 會讓這件事變成永久而且沒有任何提示的空操作。不管是哪種 switch，都應該加上重試／定期刷新。
  - 如果 pull 那條也要保留：P4 模式下把它指到 `P4_PROXY_IP_AND_PORT`，並把 proxy 回傳的裸陣列包成 kernel 會解析的 `{"status":"success","all_destination_paths":[…]}` 格式。
- 把 `GET /stats/flow/{dpid}` 真正實作出來 — 它現在回傳寫死的 `[]`。專案根目錄的 `dump_table.py` 已經有 P4Runtime 讀表的邏輯，把它併進 `p4_client` 變成 `read_table_entries()`。**輸出要用 Ryu 的格式，而且 action 要用字串（`"OUTPUT:1"`）** — `Classifier::parseActionsArrayIntoEffect`（[Classifier.cpp:824-896](../src/ndt_core/collection/Classifier.cpp#L824-L896)）**只**認字串格式，`{"type":"OUTPUT","port":N}` 這種物件格式會被安靜忽略。少了這一步，Classifier 永遠是空的，每條 flow 的 `"path"` 都會是 `[]`。
- ~~把 `pingWorker` 裡那個無條件 `setVertexUp` 換成真的存活偵測~~ ✅ **已完成**（`a8db425`）：
  `GET /p4/switch_state` 回報事實（round-trip 一個真的 P4Runtime RPC + LLDP 新鮮度），kernel 端用
  `p4LivenessFor` 三態判決，**`Unknown` 不動圖**。host 的強制標記已完全移除 —— proxy 的
  `render_hosts` 有發 `ipv4`，`updateHosts` 據此標 up，實機確認 host 維持 4/4。
  ⚠️ 註：不是「gRPC channel 狀態」—— 那個訊號在閒置時停在 `IDLE`，**被殺掉的 switch 讀起來是健康
  的**，而且只能透過私有屬性拿。改用 `GetForwardingPipelineConfig` + `COOKIE_ONLY` 實際往返。
- ~~修 LLDP beacon~~ ✅ **已完成**（`a8db425` 的 last-seen 追蹤 + 本次的 beacon 修正）：port 現在從
  kernel 讀的同一份拓撲檔推導（s1-s4 得到 `(1,2)`、s5-s10 得到 `(1,2,3,4)`，host-facing 的 port 3
  排除掉了）；beacon 源 MAC 改成 `0e:00:00:00:xx:xx`（locally-administered unicast），實機 tcpdump
  確認線上不再出現任何 host MAC 的 beacon。

  ⚠️ **這一段原本還寫「`install_initial_routes` 一律用 `INSERT`，所以路徑變好了也不會覆蓋掉舊的
  規則」—— 那已經過期了。** `insert_ipv4_route` 在 ALREADY_EXISTS／UNKNOWN 時會 fallback 成
  `MODIFY`，程式碼註解裡明確寫著它同時修掉了「舊的規則不會被更好的路徑覆蓋」這個 bug。
  順帶也修掉一個沒人碰到的崩潰：`bytes.fromhex(f"...{dpid:02x}")` 對 dpid ≥ 256 會丟
  ValueError（三個十六進位字元是奇數長度）。

**測試：** 用 pytest 搭配一個假的 kernel HTTP server，確認拿到 mastership 時會發 `inform_switch_entered`、beacon 逾時會發 `link_failure_detected`；`/stats/flow/{dpid}` 的輸出要能通過 `Classifier` 解析（用 gtest 搭配抓下來的 proxy 回應），並產生非空的路徑。

---

## Phase 7 — 讓電源管理真的能用

- 讓 `p4_testbed_topo.py` 在啟動每個 bmv2 process 時，寫一份清單檔（`/tmp/ndtwin_p4_switches.json`：名稱 → pid、grpc_port、device_id、啟動指令）。
- `P4PowerStrategy::powerOff` 讀這份清單，只殺**那一個** PID；`powerOn` 照記錄的指令重新啟動，並等 gRPC port 開起來。這樣就取代了 `sudo mnexec -a s1 pkill -f simple_switch_grpc` — 那行指令把名字傳給了需要 PID 的參數，而且就算能跑也會把十台 switch 全殺掉。
- 回傳誠實的 `OpResult`；不要再讓 `powerOn` 什麼都沒做卻回傳 `true`。
- 這個階段要依賴 Phase 6 的真實存活偵測，不然 `pingWorker` 會在 1 秒內把 switch「救活」。

**測試：** 用 mock 攔住 `executeSystemCommand`，確認指令只針對一個 PID，而且絕對不含 `pkill -f`。另外注意 [OVSPowerStrategy.cpp:49](../src/ndt_core/power_management/OVSPowerStrategy.cpp#L49) 是直接呼叫 `utils::execCommand`，沒有走自己的虛擬函式，所以就算你 mock 了子類別，它還是會真的去執行 `sudo ovs-vsctl add-br` — 順手把這個接口修好。

---

## Phase 8 — 收尾整理

- 把 `check_env.py`、`dump_table.py`、`test_modify.py`、`test_modify_error.py`、`intelligent_router.py` 從專案根目錄移走（放到 `p4_proxy/tests/`、`p4_proxy/reference/`）。`test_10_routes.py` 打的是 port **8080**，但 agent 綁的是 **8081** — 它從來沒真的通過過。
- `requirements.txt`：實際裝的 `protobuf 3.20.3` 違反了它自己寫的 `protobuf>=4.21.0`（被 `p4runtime 1.5.0` 反向鎖住）；`requests` 有用到卻沒列；`pytest` 根本沒有，所以任何 Python 測試都收集不到。補上 `pytest.ini` 和 `__init__.py`（現在一個都沒有 — 這就是為什麼一定要設 `PYTHONPATH=.`）。
- `CHANGELOG.md` 完全沒有 P4 的紀錄；補上。
- 把暫緩的 shell injection 另外開一個 issue 追蹤。

---

## 驗證方式

**每個階段都要做：** `cmake --build build && ctest --test-dir build --output-on-failure`，等 Phase 0／8 把環境弄好之後再加上 `pytest p4_proxy/`。而且一定要**另外直接執行** `./build/tests/test_routing_strategy` — `ctest` 會把每個測試放在獨立 process，所以看不到 suite 層級的失敗（問題 #9 就是這樣藏起來的）。

**端到端，P4 模式：**
1. 用 `p4c-bm2-ss` 編譯 pipeline；`sudo python3 p4_proxy/mininet/p4_testbed_topo.py`。
2. 啟動 proxy；用 `--mode mininet --topology setting/StaticNetworkTopologyP4_10Switches_4Hosts.json` 啟動 kernel。
3. `GET /ndt/get_graph_data` → 10 台 switch 全部 `is_up: true`，edge 都是 enabled（驗證 Phase 6）。
4. 在 Mininet CLI 跑 `h1 ping h4` 和 `iperf h1 h4` → `GET /ndt/get_detected_flow_data` 要看到這條 flow，`path` **不是空的**，速率不是 0；`GET /ndt/get_average_link_usage` 不是 0（驗證 Phase 5 和 Classifier 的修正）。
5. `POST /ndt/install_flow_entry` 帶 5-tuple match 和 priority → `GET /ndt/get_switch_openflow_table_entries` 要看到這筆規則，而且流量真的改走新的 port（驗證 Phase 3-4）。
6. `POST /ndt/set_switches_power_state?ip=…&action=off` → 那一台要關掉而且**保持**關掉，其他九台還能正常轉送（驗證 Phase 7 和存活偵測）。
7. 把 proxy 殺掉，再試著下規則 → kernel 要寫 WARN，端點要回報失敗，不能回 200（驗證 Phase 2）。

**OVS 不能退化：** 用 `testbed_topo.py` 加 Ryu 加 OVS 拓撲，把步驟 3-7 再跑一次。Phase 0-2 動到的是共用程式碼，所以這是這三個階段每一個都必須過的關卡。

---

## 建議的順序

Phase 0 → 1 → 2 要嚴格照順序（先修當機、再修分派、再讓錯誤看得見），做完才能往下。接著 **4 和 5 一起做**（pipeline 的取樣要餵給 emitter，所以當成一個垂直切片一次做完，用 golden-datagram 測試當驗收標準），而 **3 和 6** 可以跟它們並行，因為它們動的是 proxy 的控制路徑，不是資料路徑。7 要等 6 做完。8 最後。

如果想早一點看到可以 demo 的東西：0 → 1 → 2 → 6 就能得到一個活著、資料正確的拓撲，flow 安裝能用、錯誤會誠實回報 — 看起來已經是個能跑的 P4 數位孿生，只是在 4-5 做完之前還沒有流量數據。
