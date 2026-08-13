# 為 NDTwin-Kernel 加上 P4/bmv2 支援 — 開發計畫

---

## 目前進度（最後更新 2026-08-12，branch `fix/flow-rate-divide-by-zero`）

測試流程與實測數據見 [2026-07-29_p4_status_and_test_guide.md](2026-07-29_p4_status_and_test_guide.md)。

⚠️ **2026-08-07 校正了兩格**，兩格都是逐項對過程式碼而不是照著上一版抄：Phase 5 只做了一半，
Phase 6 比原本標的完成得多。
⚠️ **2026-08-12 校正第三格**：Phase 7 標成 🟨 一半、備註寫「`P4PowerStrategy` 還沒用它」，
在 `1978292` 落地之後就不成立了。下面「已知缺陷」表第 6 條說 `powerOn`
「是個什麼都沒做就回傳 true 的空殼」，同樣已經過期，一併更正。

| Phase | 狀態 | 備註 |
|---|---|---|
| **0** 止血 | ✅ 完成 | SIGFPE 守衛、測試真的會跑、ifIndex map 加鎖 |
| **1** typed SwitchKind | ✅ 完成 | `9910151`。O(1) 分派、同質性驗證、headless CLI |
| **2** 失敗看得見 | ✅ 完成 | `7856efc`、`08746f4`。`OpResult` + 真實 HTTP status |
| **4** P4 pipeline | ✅ 完成 | `4577983`。5-tuple ternary、ARP、TTL、取樣、counter |
| **5** telemetry | 🟨 **一半**（原本標 ✅，錯了）| flow sample（type 1）✅ 完成並實機驗證；**counter sample（type 2）完全沒實作** —— 見下一節 |
| **6** 拓撲／liveness／flow table | ✅ **完成**（2026-08-10 實機驗證，10 台 bmv2）| `inform_switch_entered`（`main.py:142`，pipeline 推完後對 usable 的 switch 發）、真存活偵測（`a8db425`）、LLDP beacon、`/stats/flow` 真實實作、destination paths、**link failure/recovery 通知**。⚠️ 08-08 這一格寫「link failure/recovery 根本不存在」—— 那在當時成立，之後補上了 `check_link_beacons` + `start_link_watchdog`，今天實測跑通：斷線 11 秒後三筆 `link_failure_detected` 抵達、圖維持 37/40 達 238 秒（約 7–8 個 poll），恢復後 14 秒回到 40/40。兩件實機驗證（`seed_expected_links` port 假設、失效鏈路維持 down）都通過，見下方 Phase 6 章節 |
| **3** proxy 端點補完 | ⬜ 未做 | `/stats/flowentry/delete`、prefix 解析、idle_timeout、加鎖、**host 清單從拓撲 JSON 推導**（見下方「⚠️ 拓撲來源分裂」）|
| **7** 電源管理 | ✅ **完成**（2026-08-11／08-12，機制與測試齊備；尚待 helper 安裝後的 live 驗證）| PID manifest（`22ada58`）＋ root helper `ndtwin-p4-power`（`624946d`）＋ `P4PowerStrategy` 真的呼叫它並在 `on` 之後要求 proxy readopt（`1978292`）＋ mutation 驗證過的測試（`9afd647`、`09a7a81`）＋ `on` 逾時的 orphan 修掉（`8eaa133`）＋ 失敗訊息改成講真正有效的復原路徑（`2abf1e3`）。文件：`b0c82df`、`doc/2026-08-11_phase7_power_mechanism_design.md` |
| **8** 收尾 | ⬜ 未做 | |

**為什麼這張表會過期**：它是手寫的，而 phase 的推進是靠 commit。只要沒有人回來逐項對，
它就會停在最後一次有人想起要改的時間點。下一個人如果要相信這張表，先花十分鐘對一遍 ——
2026-08-07 那次對出兩格是錯的。

### Phase 5 實機驗證結果（2026-07-29，10 台真實 bmv2）

整條鏈通了：**bmv2 取樣 → clone 到 CPU → packet-in → proxy → emitter → kernel 解析出正確 flow**。

- `rx=126, app_drop=0, addressed=126` —— `rx` 等於 `addressed` 表示**每個 datagram 都成功歸戶到 agent**
- 取樣數符合模型：2700 封包 × 10 跳 ÷ 256 ≈ 105，實測 107
- 雙向 ICMP flow 都正確解析（type 8 code 0 / type 0 code 0，放在 port 欄位）
- bmv2 fabric 本身也證實可轉發：`ping` 0% loss、`ttl=59`（5 跳 + TTL 遞減有效）
- L4 差異比對 `PASS`：170 個已登記差異、**0 個未預期**

### ⚠️ Phase 5 只做了一半：counter sample 從來沒有實作（2026-08-07 發現）

Phase 5 的規格寫了**兩種** sample：

1. **flow sample（type 1）**，從 clone-to-CPU 的封包來 —— ✅ **做好了、而且驗過**
   （golden fixture、2863 個樣本、100% 一致）。
2. **counter sample（type 2）**，定期輪詢 P4 的 per-port counter，帶 `ifIndex` / `ifSpeed` /
   `ifInOctets` / `ifOutOctets` —— ❌ **完全不存在**。

證據（實測，不是讀計畫書推的）：

| 查什麼 | 結果 |
|---|---|
| `sflow_emitter.py` 定義的 sample 型別 | 只有 `SAMPLE_TYPE_FLOW = 1`，沒有 type 2、沒有 `build_counter_sample` |
| emitter 有沒有輪詢 counter | 檔案裡沒有任何 counter 相關的程式碼 |
| proxy 裡誰呼叫 `read_egress_counter` | **沒有人**（只有測試呼叫它） |
| kernel 那邊 type 2 餵給什麼 | `FlowLinkUsageCollector.cpp:953` 起處理 `sampleType == 2`，取 `ifIndex` / `ifSpeed` / `inOctets` / `outOctets` |

**後果 —— 這段 2026-08-07 當天就修正過一次，原本寫錯了**：

原本寫「P4 側會因此缺料，鏈路使用率少了它在 OVS 模式下的主要輸入」。**那句話是錯的。**
實測查證：MININET 模式**根本不讀 counter sample** —— `sampleType == 2` 那個分支開頭就是
`if (m_mode == utils::MININET) continue;`，鏈路使用率是從 **flow sample** 經 `m_counterReports`
算出來的，而且**實測是好的**（跨 fabric 的 iperf 讓 `avg_link_usage` 到 0.278）。

所以 counter sample 在 MININET／P4 這條路上**本來就沒有被使用**，emitter 沒實作它是**與 OVS 對等**，
不是缺料。真正的影響範圍是 **TESTBED 模式**，而那條路的偏移量是為 Brocade／HPE 校準的。

這一格仍然標「一半」，因為計畫書的 Phase 5 規格確實寫了兩種 sample 而只做了一種 —— 但它**不影響
目前任何一個實際跑得到的指標**，優先度應該調低。

**順帶一個要等的修法**：`read_egress_counter`（`p4_client.py:414`）在兩條路上都靜默回 `(0, 0)`
—— p4info 裡找不到 counter，以及 `except Exception: pass`。持續失敗的 gRPC 和「這條 link 閒置」
在下游無法區分，就是這個專案最常見的那種無聲錯答。**現在不修**，因為它還沒有任何生產呼叫點，
而正確的失敗訊號長什麼樣取決於將來輪詢它的那個 caller 需要什麼。counter sample 實作的時候
一起處理，不要沿用現在這個回 `(0,0)` 的形狀。

---

### Phase 6 的具體入手點（含 2026-07-29 新發現）

計畫本體見下面的 Phase 6 章節，這裡補上實測才發現、會影響實作的細節：

1. ~~**`updateHosts` 的 `ipv4` 前置條件擋掉了 127/128 台 host**~~
   ✅ **已修（2026-08-03，commit `71d27c1`）—— 而且這一條原本寫的成因是錯的。**

   原本寫的是：「`testbed_topo.py` 設了 static ARP（`arp -s`），host 因此永不發 ARP，Ryu 的 host
   tracker 學不到 IP，所以 254/256 條 host edge **永遠**是 down」。**那個因果不成立。**
   `testbed_topo.py` 設完 static ARP 之後**自己平行 ping 全部 128 台 host**（64 對 × 雙向），每台都
   送出 IP 封包 —— 那就是教會 Ryu 的東西。空 `ipv4` 是**暫態**，不是永久限制。

   兩次實測：

   | 日期 | Ryu `/v1.0/topology/hosts` | kernel `get_graph_data` |
   |---|---|---|
   | 2026-07-29（本條原本的依據）| 128 台，**1 台**有 ipv4 | 254/256 host edge down |
   | 2026-08-07（連續運轉 3.6 天後）| 128 台，**128 台全部**有 ipv4 | **288/288 edge、138/138 node up** |

   **真正的成因，而且比原本寫的廣得多**：`TopologyAndFlowMonitor::run()` 呼叫
   `fetchAndUpdateTopologyData()` **一次就 return**（實測進出相隔 88 毫秒），整個 process 生命週期內
   再也沒有重讀。整張圖 —— switch、host、link **全部** —— 就是 Ryu 在那一瞬間知道的東西。所以決定
   成敗的變數是**啟動間隔**：手動啟動比 Mininet 晚 73 秒 → ping burst 早跑完 → 128/128 up；
   `stack.sh up ovs` 背靠背 → 快照落在 burst 中間 → 永久性缺料。同一份程式碼、同一個網路、不同判定。

   host 是最明顯的症狀，因為**它完全沒有 push 路徑**：switch 走 `/ndt/inform_switch_entered`、
   link 失效走 `/ndt/link_failure_detected`，但**沒有任何東西 push host**。

   已改成定期輪詢（前 90 秒每 5 秒、之後每 30 秒）。詳細的驗證過程、以及第一版輪詢讓圖不斷增長的
   那個 bug，見 `doc/2026-07-29_HANDOFF.md` §2 的 `get_graph_data` 條目。

   仍然成立的一點：**vertex 是用 MAC 比對的**（`findVertexByMac`，沒有 IP 也能成功），只有 **edge 用
   IP**（`findEdgeByHostIp`），所以那個 early `continue` 比它下面的程式碼實際需要的更嚴格。這一點沒有
   被上面的修正推翻，只是不再是 blocker。

2. **`/stats/flow/{dpid}` 的回傳形狀要對齊**。kernel 文件（和 OVS 模式）是
   `flows` = `{table_id: [entries]}` 的 map；P4 proxy 目前的 stub 回傳裸 list。實作時要用 map，
   否則 L2 契約會報型別錯誤。`Classifier::parseActionsArrayIntoEffect` 也**只認字串形式的 action**
   （`"OUTPUT:1"`），不認 `{"type":"OUTPUT","port":N}`。

3. **`get_path_switch_count` 目前回 `{"status":"error","message":"Path not found..."}`** 是正確行為，
   不要改成回假的數字。Phase 6 做完之後它自然會回真實的 `switch_count`。

4. ~~**kernel 的 pull 只做一次、沒有重試**~~ ✅ **已完成（`71d27c1`）。**
   `run()` 現在定期輪詢：前 90 秒每 5 秒、之後每 30 秒（`TopologyAndFlowMonitor.cpp` 的 `run()`，常數 `kWhileConverging` / `kOnceConverged` / `kConvergingFor`）。
   「kernel 最後開並等收斂」這條操作規則保留，但理由換了 —— 現在只是為了圖早點完整，不再是
   「錯過就永遠不知道」。第一版輪詢曾讓圖不斷增長（`loadStaticTopologyFromFile` 是新增不是對帳），
   已拆開並讓它拒絕第二次載入，詳見 `2026-07-29_HANDOFF.md` §2。

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

> ⚠️ **這張表是 `6f32bca` 時期的快照，行號與連結已經漂移**（2026-08-12 B2 首次指出，2026-08-13
> 機械掃描複驗）。**每一條的判斷仍然成立，錯的只有定位**。已知失效的兩個：
> `P4RoutingStrategy.cpp#L29-L33`（該檔現在只有 29 行）、`tests/test_P4RoutingStrategy.cpp`
> （這個測試從未被寫出來）。**要照這張表找程式碼請用符號名 grep，不要用行號。**

| # | 問題 | 位置 |
|---|---|---|
| 1 | **程式會被 SIGFPE 殺掉。** `6f32bca` 把 `if (hopsCounter == 0) continue;` 刪掉了，但 `hopsCounter` 還是被當除數用。只要有一條 flow 停了一個 1 秒週期，就會整數除以 0。同一個檔案第 1424 行的姊妹函式還留著這個保護，可見是不小心刪的。 | [FlowLinkUsageCollector.cpp:1309](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L1309), [:1322](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L1322) |
| 2 | **`P4RoutingStrategy.cpp` 是 `OpenFlowRoutingStrategy.cpp` 的複製品**（用 `diff` 把類別名字換掉後比對，完全一樣）。它只是把 OpenFlow 格式的 JSON 丟到 port 8081 而已。它的 `deleteAnEntry` 預設 `priority == -1`，會打到 `/stats/flowentry/delete`，但 proxy 沒有實作這個端點；group/meter 那幾個方法打的端點也不存在。 | [P4RoutingStrategy.cpp:29-33](../src/ndt_core/routing_management/P4RoutingStrategy.cpp#L29-L33) |
| 3 | **完全沒有流量資料。** bmv2 不會產生 sFlow，P4 的拓撲檔也沒設定 sFlow。所以 P4 模式下所有速率、鏈路使用率、流量路徑都是 0 或空的。 | `p4_proxy/mininet/p4_testbed_topo.py`（沒有 sflow 設定），對照 [testbed_topo.py:105-119](../testbed_topo.py#L105-L119) |
| 4 | **整張拓撲圖都停在 `isEnabled=false`。** node 和 edge 初始都是 false，只有 Ryu 的 REST 回應或 `/ndt/inform_switch_entered` 會把它翻成 true，但 P4 這邊沒有任何元件會去呼叫。結果 BFS 找路徑、flow table 輪詢、鏈路使用率、還有一半的 `/ndt/` API 全部變成空的，而且不會報錯。 | [TopologyAndFlowMonitor.cpp:116-117](../src/ndt_core/collection/TopologyAndFlowMonitor.cpp#L116-L117), [HttpSession.cpp:933](../src/ndt_core/http/HttpSession.cpp#L933) |
| 5 | **P4 的存活偵測是假的。** 只要拓撲檔名裡有 `"P4"` 這幾個字，`pingWorker` 就無條件把每台 switch **和每台 host** 標成 up。所以你把一台 switch 關掉，1 秒內它又會顯示 UP，數位孿生永遠反映不出故障。 | [DeviceConfigurationAndPowerManager.cpp:364-369](../src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp#L364-L369), [:385-389](../src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp#L385-L389) |
| 6 | ~~**P4 關機功能有兩個錯。** `sudo mnexec -a s1 …` 裡的 `mnexec -a` 要的是 **PID**，不是名字，所以這行指令根本不會執行；而且就算能執行，`pkill -f simple_switch_grpc` 會把**十台 switch 全部殺掉**（Mininet 的 node 共用 PID namespace）。至於 `powerOn`，它是個什麼都沒做就回傳 `true` 的空殼。~~ **✅ 已於 Phase 7 修掉（`624946d`／`1978292`）**：`powerOff` 走 root helper，只對 manifest 記載的那一個 PID 送 SIGTERM（送之前再對 `/proc` 驗一次），`powerOn` 重新啟動同一台並要求 proxy readopt，兩者都回誠實的 `OpResult`。`pkill` 是整條路徑的禁字，理由寫在 `P4PowerStrategy.cpp` 檔頭的匿名 namespace 註解裡。 | `P4PowerStrategy::powerOn` / `powerOff` |
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

  ### ⚠️ 拓撲來源分裂：一半讀檔案，一半寫死

  這一條目前是**已知、已推遲、但還沒解**的缺陷，記在這裡是因為它會靜靜地產生錯誤的圖。

  proxy 對「拓撲是什麼」有兩個互不知情的來源：

  | 資料 | 來源 | 換拓撲檔會跟著動嗎 |
  |---|---|---|
  | switch 之間的連結 | `load_switch_links`（`topology_manager.py`），讀 `NDTWIN_TOPO_FILE` | ✅ 會 |
  | 每台 switch 的 sFlow agent IP | `load_switch_agent_ips`（`sflow_emitter.py`），同樣讀 `NDTWIN_TOPO_FILE` | ✅ 會 |
  | **4 台 host 的 IP／MAC／掛在哪台 switch／掛哪個 port** | **`main.py` 裡四行 `topo.add_host(...)` 寫死** | ❌ **不會** |

  所以只要把 proxy 指到另一份拓撲檔，它會**照新檔案 seed 並 beacon 新的連結**，
  但 `/v1.0/topology/hosts`（`render_hosts`）、destination path 的算繪（`render_destination_paths`）
  和 `install_initial_routes` 仍然對著那 4 台可能根本不存在的 host 計算，
  attach port 也是舊的。結果是一張**左右腦分裂的圖**：連結來自新拓撲，host 來自舊常數。
  兩邊都不會驗證對方，也沒有任何一行 log 會提到這件事。

  ⚠️ **`main.py` 裡既有的那句自白不涵蓋這一塊。** `DEFAULT_SWITCH_DPIDS` 上面寫的
  「Still hardcoded -- deriving them from the topology JSON is Phase 3 work」
  講的只有 switch dpid 清單和 gRPC port 編號，**沒有提到 host 那四行**，
  而那四行在檔案更上面、離自白很遠。這正是它被漏掉的原因之一：
  讀的人看到自白，以為寫死的部分都已經被記錄了。

  **處置：** 正確的解法（從拓撲 JSON 推導 host）屬於 Phase 3，跟著上面那條 `dpid → grpc_addr`
  一起做。在那之前，另一個變更會加上**啟動時的一致性檢查**——發現寫死的 host 和拓撲檔對不起來
  就大聲失敗，而不是安靜地跑出一張分裂的圖。那個檢查是止血，不是修好；這一條不會因此從 Phase 3 移除。
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
  - ~~拿到 P4Runtime mastership 時~~呼叫 `GET /ndt/inform_switch_entered?dpid=N` — 這是**唯一會把
    switch 頂點的 `isEnabled` 設成 true 的路徑**，光做這一件事就能解開 BFS 找路徑、flow table
    輪詢和鏈路使用率。

    ⚠️ **它只打開頂點，不打開邊。** `handleInformSwitchEntered` 呼叫的是 `setVertexUp` ＋
    `setVertexEnable`（HttpSession.cpp:1080-1081），僅此而已。switch↔switch 的**邊**是
    `updateLinks` 在 topology poll 裡用 `(src dpid, src port)` 打開的（poll 間隔：前 90 秒每 5 秒，
    之後每 30 秒，常數 `kWhileConverging` / `kOnceConverged` / `kConvergingFor`，見 `TopologyAndFlowMonitor.cpp` 的 `run()`；**不是 1 秒**，那個 1 秒是同一個迴圈裡的 sleep 切片，存在的理由是讓 `stop()` 不必等完整個間隔），資料來源是
    proxy 提供的 Ryu 形狀 `/v1.0/topology/links`；host 邊在 `updateHosts` 裡打開。
    `enableSwitchAndEdges` 確實會一併打開相鄰邊，但**唯一的呼叫點是 `IntentTranslator.cpp:227`**。
    我曾把這件事寫反過，而那個錯誤的理由掩蓋了一個真正的缺陷 —— 見下面 link watchdog 那條。
    ✅ **已完成**（`KernelNotifier.switch_entered`，由 `main.startup()` 呼叫）。

    ⚠️ **計畫書這裡原本寫錯了觸發時機。** 不是拿到 mastership 時，而是**pipeline 推完之後**。
    `isEnabled` 的語意是「控制平面能驅動這台 switch」，而一台**握有 mastership 但沒有載入 pipeline 的
    switch 什麼都轉送不了** —— 照原本寫的做，會把 vertex 打開在一台死掉的 switch 上，然後 twin 會為
    它報出路徑和速率。實際上 `set_forwarding_pipeline_config` 才是第一次真正的 gRPC 往返（grpc 是
    lazy connect，所以 `start()` 對著死掉的 switch 也會成功），所以那裡同時是「能不能驅動」的第一個
    真實證據。pipeline 推失敗的 switch 被排除在 `inform_switch_entered` 之外，但**保留**它的
    `P4RuntimeClient`，這樣存活輪詢仍會探測它、`/p4/switch_state` 回報 `probe_ok=false`，kernel 才能
    把它顯示成 down 而不只是「不存在」。
  - LLDP beacon 逾時／恢復時呼叫 `POST /ndt/link_failure_detected`／`link_recovery_detected`（可以參考
    `intelligent_router.py:597,624`）。✅ **已完成**（`TopologyManager.check_link_beacons` +
    `start_link_watchdog`，34 個測試）。

    實作上有幾件計畫書沒寫到、但決定了設計的事：**回報放在 watchdog 執行緒，不是 gRPC 接收執行緒**
    —— 在接收執行緒上做一個 3 秒 timeout 的 HTTP POST，會卡住它後面每一台 switch 的 packet-in，而
    20 條鏈路同時失效會卡住一分鐘，足以讓**更多**鏈路看起來像失效。逾時定為 3 個 beacon 週期（15 s），
    容忍連續兩次漏掉；1 個週期會在掃描剛好落在 beacon 之前時誤報，而**震盪的回報比慢的回報更糟**
    （每一次都讓 kernel 拆掉邊、重算路徑）。狀態是「信念 ＋ kernel 是否已被告知」兩個欄位而不是一個
    旗標：回報會重試到被接受為止，否則一個正在重啟的 kernel 會讓通知永久遺失，而症狀正好就是這個功能
    要修的那個 bug。
    ⚠️ **回報失效本身不夠 —— 這是後來才發現的，而且是我自己 ship 的缺陷。** kernel 的
    `updateLinks` **只會**把 `isUp`/`isEnabled` 設成 true，**沒有任何路徑會設成 false**，而它
    每個 poll 週期跑一次（5 秒／30 秒，見上）；proxy 這邊 `add_link` 也沒有對應的移除，探索到的
    link 會永遠上報。所以順序是：watchdog 回報失效 → kernel 把邊設 down → **下一個 poll 又把它設回
    enabled**。回報是真的，效果撐不過一個 poll 週期，而且沒有任何地方會講。
    （⚠️ 本段原先寫「1 秒」「不到一秒」，是把 `run()` 迴圈裡的 1 秒 sleep 切片誤讀成 poll 間隔。缺陷本身不變，
    但存活窗口是 5–30 秒而非 1 秒。）修法是 `down_link_endpoints()`：proxy **停止上報**它認為
    已經斷掉的方向 —— 在現行 kernel 下這是唯一辦得到的，因為那個回覆裡沒有辦法表達「down」，而
    poll 從不提及的邊會保留它上次被設定的狀態。
    連帶一個更細的洞：`add_link` 從**一個** beacon 就建出**兩個**方向，所以反向邊通常是推論而非觀測，
    永遠不會有 tuple 去逾時 —— 遠端 switch 自己死掉時，它的 beacon 從來沒抵達過任何地方可以被漏掉。
    所以反向也一併停報，**除非它自己還在收 beacon**（那是真正的單向失效，少報反而是另一種錯）。
    這是本專案「應該取代卻只能新增」的**第 5 例**：兩半各自只會新增，合起來就永遠拿不掉東西。

    ~~⚠️ 已知限制：**啟動時就已經斷掉的鏈路偵測不到**~~ ✅ **已補上**（2026-08-10）：
    `seed_expected_links()` 從拓撲檔預先種入 32 條宣告的鏈路，`main.py` 現在以
    `seed_expected=True` 呼叫。開啟前先驗證了它唯一的假設 —— 拓撲檔的 `src_interface`／
    `dst_interface` 就是 bmv2 用的 port 編號：靜態 32/32 相符，實機 16/16 相符，零矛盾。
    （若這個假設在別的拓撲上不成立，每條 seed 進去的鏈路都會逾時、真實 beacon 另外建立條目，
    twin 會把整個 fabric 報成失效。所以換拓撲要重驗，沒有任何機制會替你檢查。）
    seed 到 0 條時 `start_link_watchdog` 會印 WARNING，因為那等於這個能力又被關掉了。
  - ~~用 `POST /ndt/inform_all_destination_paths` 主動推路徑~~ ✅ **已完成**，但**理由已經和計劃書寫的
    不一樣了，這裡更正**：計劃書說「這比修 pull 那條路好，因為 `fetchAllDestinationPaths` 只在啟動時
    被呼叫一次，時間點比 LLDP 收斂還早，而 `if (output.empty()) return;` 讓它變成永久的空操作」。
    那個前提**已經不成立** —— pull 那條路早先就修好了：`refreshDestinationPathsPeriodically`
    （[FlowLinkUsageCollector.cpp:517](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L517)）
    在還沒拿到路徑時每 5 秒重試、拿到之後每 60 秒刷新，`setAllPaths` 也改成整批取代並拒絕空快照。

    所以推送**不是正確性的必要條件，而是延遲**：鏈路失效後 pull 最久要 60 秒才會更新，這段時間
    `get_path_switch_count` 會用死掉的路線回答。改成在 watchdog 偵測到 down／up 轉換時推一次
    （`TopologyManager.run_watchdog_pass` → `push_destination_paths`），窗口縮成一次 HTTP。

    ⚠️ 推送與 pull **都**必須把 watchdog 認定失效的鏈路排除在最短路徑搜尋之外。原本沒有，
    `render_destination_paths` 是在完整圖上算的 —— 那等於一邊回報鏈路失效、一邊把經過它的路徑推給
    kernel。`m_switchCountMap` 就是從這裡填的，所以後果是 `/ndt/get_path_switch_count` 拿到一條流量
    走不通的路線。**這是「應該取代卻只能新增」第 5 例的同一個洞的第二半**：把鏈路從
    `/v1.0/topology/links` 抽掉並不會影響這個端點，兩邊要各自處理。

    ⚠️ 已知取捨：圖完全斷開時算不出任何路徑，而 `setAllPaths` 刻意拒絕空快照（收斂前的「沒有路徑」
    是暫態），所以 kernel 會繼續持有舊快照。shipped 拓撲有 32 條 switch↔switch 有向邊，單一鏈路失效
    不會清空快照，整批取代就足夠；測試
    `test_a_total_partition_pushes_nothing_and_leaves_the_kernel_holding_stale_paths` 把這個行為釘住。
  - 如果 pull 那條也要保留：P4 模式下把它指到 `P4_PROXY_IP_AND_PORT`，並把 proxy 回傳的裸陣列包成 kernel 會解析的 `{"status":"success","all_destination_paths":[…]}` 格式。
- ~~把 `GET /stats/flow/{dpid}` 真正實作出來 — 它現在回傳寫死的 `[]`。~~ ✅ **已完成**
  （`ryu_flow_stats.py` ＋ `p4_client.read_table_entries()`，22 個測試）。以下敘述保留，因為它記錄了
  為什麼 action 一定要是字串形式：`p4_proxy/reference/dump_table.py`（寫作當時在專案根目錄，2026-08-12 `3fc42ed` 搬入 reference/）已經有 P4Runtime 讀表的邏輯，把它併進 `p4_client` 變成 `read_table_entries()`。**輸出要用 Ryu 的格式，而且 action 要用字串（`"OUTPUT:1"`）** — `Classifier::parseActionsArrayIntoEffect`（[Classifier.cpp:824-896](../src/ndt_core/collection/Classifier.cpp#L824-L896)）**只**認字串格式，`{"type":"OUTPUT","port":N}` 這種物件格式會被安靜忽略。少了這一步，Classifier 永遠是空的，每條 flow 的 `"path"` 都會是 `[]`。
### ⚠️ sFlow 取樣那段程式碼，自動測試生成原理上碰不到（2026-08-13 實測）

`p4testgen`（隨 p4c 出貨，`/usr/local/bin/p4testgen`）對 `ndtwin_switch.p4` 收斂後的語句覆蓋是
**85.2%（46/54）**，未覆蓋的 8 個節點**不是隨機分佈**，是連續的一整塊 `:414-421`——egress 裡
處理 `BMV2_INSTANCE_TYPE_INGRESS_CLONE`、替取樣封包組裝 `packet_in` 標頭那一段。

原因是機制性的，而且**比「有 clone」更精確**——2026-08-13 拿 p4lang/tutorials 做跨程式對照驗證過：

| 程式 | clone？ | egress 分支的條件 | 語句覆蓋 |
|---|---|---|---|
| `tutorials/exercises/basic/basic.p4` | 無 | — | **100%**（3/3） |
| `tutorials/exercises/flowcache/solution/flowcache.p4` | **有** | `standard_metadata.egress_port == CPU_PORT` | **100%**（35/35） |
| `ndtwin_switch.p4`（我們） | 有 | `standard_metadata.instance_type == BMV2_INSTANCE_TYPE_INGRESS_CLONE`（:406） | **85.2%**（46/54） |

**所以不可達的原因不是「程式裡有 clone」**——flowcache 有 clone 卻 100%，連
`clone_preserving_field_list` 那一行本身都被覆蓋到了。真正的原因是**分支條件讀的是只有在
clone 真的發生後才會被設定的 `instance_type`**：符號執行對單一封包求解一條路徑，
它能自由選擇 `egress_port` 這種一般 metadata（flowcache 因此可解），但不會去模型化
「clone 產生了第二個封包、而那個封包的 `instance_type` 被 bmv2 設成 1」這件事。

我們**不能**改用 flowcache 那種 `egress_port == CPU_PORT` 的寫法來換取覆蓋率：我們的
clone 取樣封包與主動 `send_to_cpu` 的封包 egress_port 都是 CPU_PORT，兩者必須區分
（見 :406 附近的註解），`instance_type` 是唯一能區分的依據。這是有意識的取捨，不是疏忽。

**後果**：改動 `.p4` 的取樣區塊時，**不能指望自動生成的迴歸網接住**。那 8 行現在的唯一守護者是
live 流量驗證（runbook §5）與 `tests/test_SFlowEmitterRoundtrip.cpp` 的跨語言 round-trip。
`tools/test_workflow/p4_coverage_gate.sh` 會盯著這個未覆蓋清單的**形狀**：清單變長＝新增了
自動測試永遠碰不到的程式碼，閘門會擋下來要求明確裁決。

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

**測試：** ✅ 用 pytest 搭配一個假的 kernel HTTP server，確認~~拿到 mastership 時~~ pipeline 推完後會發
`inform_switch_entered`、beacon 逾時會發 `link_failure_detected`；`/stats/flow/{dpid}` 的輸出要能通過
`Classifier` 解析（用 gtest 搭配抓下來的 proxy 回應），並產生非空的路徑。

實作後的狀態：`test_kernel_notifier.py`（13）跑的是**真的 HTTP server 而不是 mock**，因為最容易寫錯的
就是 URL、method 和 JSON 欄位名 —— kernel 讀的是 `src_interface` 而不是 `src_port`，改錯名字會拿到 200
然後被忽略，而 mock 會照樣接受。`test_startup.py`（13）釘住「哪些 switch 被宣稱」，
`test_link_watchdog.py`（34）用**注入的時鐘**測 15 秒逾時——真的等 15 秒的測試，第一次有人趕時間就會被
刪掉；整個檔案跑 7 ms。

**Phase 6 ✅ 完成（2026-08-10 實機驗證通過，10 台 bmv2）。** 原本剩的兩件都做了：

| 驗證項目 | 結果 |
|---|---|
| `seed_expected_links` 接收側 port 編號 | ✅ **假設成立。** 靜態：32/32 條有向邊與 `p4_testbed_topo.py` 的接線 ＋ bmv2 自己的 `-i <port>@<iface>`（十台都是恆等 `port N == sX-ethN`）完全吻合。實機：proxy 記錄的 16 條 `Discovered link` 的 ingress port 全部等於拓撲檔的 `dst_interface`，零矛盾 |
| 失效鏈路在 kernel 圖裡維持 down | ✅ **維持住了。** 斷 s1-eth1 → 11 秒後三筆 `link_failure_detected` 抵達 → 圖 37/40。取樣 40 次／119 秒**只出現 `up=37/40` 一種狀態**；連同斷線起算共 238 秒、約 7–8 個 poll 週期。決定性證據是 13:34:40 那次 poll 自己就回報 `37 edges up` —— proxy 的 `down_link_endpoints` 把它們從 `/v1.0/topology/links` 抽掉了，poll 根本沒有東西可以拿來復活 |
| （順帶）推送的路徑避開死鏈路 | ✅ 9 條路徑**零條**從 s1 的 port 1 出去，h1 全改走 `1(p2) -> 6`；push 在斷線後 11 秒送達，0 次失敗 |
| （順帶）恢復 | ✅ `ifconfig up` 後 14 秒內回到 40/40、12 條路徑 |

⚠️ **實測時挖到一個測試方法上的陷阱**：`ifconfig <iface> down` 會讓那台 bmv2 的**整條 packet-in
路徑停擺**（`last_packet_in_age_s` 73 s，而 `probe_ok` 仍是 true），於是同一台 switch 另一個埠上的
健康鏈路被誤報成失效，連帶讓 h1 在 twin 裡變成不可達。詳見
[2026-07-29_environment_gotchas.md](2026-07-29_environment_gotchas.md)。**watchdog 的判斷是對的，錯的是我模擬失效的方式。**

程式碼部分 Phase 6 已完成：
`inform_switch_entered`（pipeline 推完後）、beacon 逾時的 link_failure／recovery、失效鏈路從
`/v1.0/topology/links` 與路徑搜尋雙邊排除、路徑在轉換時主動推送、`/stats/flow/{dpid}`、
`/p4/switch_state` 三態存活判定、LLDP beacon 的 port 推導與 MAC 修正。

### ⚠️ 明確**不在** Phase 6 範圍內：failover（鏈路失效後重裝路由）

Phase 6 做的是**偵測**。「偵測到之後把流量繞開」從來沒有被實作，也沒有被宣稱過，
2026-08-10 實機確認了這一點：斷一條中段鏈路，**ping 完全停住、38% 掉包**，因為
`install_initial_routes()` 全專案只有一個呼叫點（`topology_manager.py`，`if not edge_exists`
底下），只在**發現新鏈路**時觸發，鏈路**消失**時沒有任何東西呼叫它。

當時更危險的是 twin 還在宣稱一切正常：`all_destination_paths` 維持 12 條，其中 h1→h4 那條是
proxy 用 networkx 重算出來、**沒有裝進任何一台 switch** 的路。**這一半已經修掉了**（見下），
所以現在斷線後 twin 會誠實地少報路徑；但流量還是不會自己繞路。

**已修（2026-08-10）**：`render_destination_paths` 多收一份 `installed`（`(dpid, dst_ip) → out_port`，
`TopologyManager` 在寫入成功時記錄），只宣告「規則真的存在且每一跳都還活著」的路徑。
空的 `installed` 視為「不知道」而沿用舊行為 —— 因為 bmv2 的 table entry 會跨 proxy 重啟存活，
把「沒有紀錄」當成「什麼都沒裝」會製造反方向的假警報。

**已做並完整驗證（2026-08-10）**：failover 已實作——`calculate_all_paths` 接受要避開的 endpoint、`install_initial_routes` 帶著 down 集合重算、watchdog 轉換時先重裝再推送。**規則層與端到端都已實測通過**：用 `tc netem loss 100%` 雙向斷掉 `s5↔s10`，ping 停約 15 秒後**自己恢復**（整趟 9.67% 掉包），路徑從 `1 5 10 8 4` 繞成 `1 5 9 8 4`，s5 的規則從 `OUTPUT:4` 改成 `OUTPUT:3`（從 switch 讀回確認），邊數 38/40、路徑數維持 12，移除 netem 後 25 秒內完全恢復。

    ⚠️ **不能用 `ifconfig down` 驗這件事**：它會讓整台 switch 停止轉發，任何繞路都救不了，而且會產生假的 link down 回報（實測 5 筆裡 3 筆是假的）。`tc netem` 只有 2 筆、零假報。見 `doc/2026-08-10_p4_manual_test_runbook.md` §6h 的對照表。

**原本的未做說明（保留作為改動紀錄）**：真正的 failover。改動落點是
`calculate_all_paths()` 目前對 `self.net` 做最短路，**沒有扣掉 watchdog 認為 down 的邊**，
所以現在直接呼叫 `install_initial_routes()` 會算出一模一樣的路；扣掉之後，在
`run_watchdog_pass()` 既有的轉換掛勾（已經在那裡呼叫 `push_destination_paths()`）加上安裝即可。
寫入端不必動 —— `insert_ipv4_route` 遇到 `ALREADY_EXISTS`／`UNKNOWN` 已經會退回 `MODIFY`。

開工前要先決定的兩件事：

1. **抖動**。`ifconfig` 那個 packet-in 陷阱會讓一條斷線看起來像整台 switch 的入向都斷，
   據此重新導流可能把流量從健康鏈路搬走，而且會反覆搬。需要遲滯或別的證據來源。
2. **算不出替代路徑時要做什麼**：保留舊規則（繼續黑洞、恢復時自動好），還是刪掉
   （明確丟棄、可觀測）？這會改變故障期間的行為。

---

## Phase 7 — 讓電源管理真的能用 ✅ 已完成

> **2026-08-12 狀態：機制與測試都做完了**，`624946d`／`1978292`／`9afd647`／`09a7a81`／`8eaa133`／`2abf1e3`。
> 以下維持成當初的規格原文（未來式的語氣是原文的），逐條對照結果：
>
> | 規格條目 | 結果 |
> |---|---|
> | manifest 檔 | ✅ `22ada58`，`/tmp/ndtwin_p4_switches.json` |
> | `powerOff` 只殺那一個 PID | ✅ 由 root helper `ndtwin-p4-power` 做，送信號前對 `/proc` 再驗一次 |
> | `powerOn` 照記錄重啟並等 gRPC port | ✅ 並且多做一步：要求 proxy `POST /p4/readopt/{dpid}` 重新掛上 mastership／pipeline／clone session／routes，否則重啟後的 switch 一個封包都轉不動 |
> | 誠實的 `OpResult` | ✅ 兩個操作都是；`powerOn` 的 502 訊息會講出真正有效的復原路徑——**直接打 `POST /p4/readopt/{dpid}`**（`3a312e3`）。⚠️ 這一欄先前寫「off 再 on」，**實跑證明那個也回 500**（`2abf1e3` 拿行不通的建議換了沒驗證過的建議） |
> | 依賴 Phase 6 的真實存活偵測 | ✅ Phase 6 已完成 |
> | 測試：mock 攔住 `executeSystemCommand`，確認只針對一個 PID 且不含 `pkill -f` | ✅ `tests/test_P4PowerStrategy.cpp`，mutation 驗證過 |
> | 順手修好 `OVSPowerStrategy` 繞過自己虛擬函式的接口 | ✅ 已修，見 `2026-07-29_HANDOFF.md` 的覆蓋率表 |
>
> **Live 驗證已於 2026-08-12 完成**（helper 已安裝、sudoers 已設）。核心要求通過：關掉一台、
> 其他九台 **9000/9000 封包零遺失**，關掉的那台在 helper 回報 stopped 前 0.3 秒就停止轉送。
> 完整結果在 `doc/2026-08-11_phase7_power_mechanism_design.md` 的「Live 驗收結果」。
>
> **但 live 跑出三個測試抓不到的缺陷**，兩個已修：
> - `curl -sS -f` 把 readopt 的失敗步驟丟掉，兩邊 log 都查不到 → `eace67c`（`--fail-with-body`）
> - gRPC 全域 subchannel pool 讓新 channel 繼承死掉 peer 的重連 backoff，導致關機夠久之後
>   powerOn 必失敗 → `949fcba`（`grpc.use_local_subchannel_pool`），修後同情境實跑 200
> - **未修**：拓樸輪詢對死掉的 switch 週期性寫回 `is_up=true`（`updateSwitches` 無條件標 up，
>   而 proxy 的 `/v1.0/topology/switches` 會列出已死的 switch）。機制已釘死，修法待裁決。

- 讓 `p4_testbed_topo.py` 在啟動每個 bmv2 process 時，寫一份清單檔（`/tmp/ndtwin_p4_switches.json`：名稱 → pid、grpc_port、device_id、啟動指令）。
- `P4PowerStrategy::powerOff` 讀這份清單，只殺**那一個** PID；`powerOn` 照記錄的指令重新啟動，並等 gRPC port 開起來。這樣就取代了 `sudo mnexec -a s1 pkill -f simple_switch_grpc` — 那行指令把名字傳給了需要 PID 的參數，而且就算能跑也會把十台 switch 全殺掉。
- 回傳誠實的 `OpResult`；不要再讓 `powerOn` 什麼都沒做卻回傳 `true`。
- 這個階段要依賴 Phase 6 的真實存活偵測，不然 `pingWorker` 會在 1 秒內把 switch「救活」。

**測試：** 用 mock 攔住 `executeSystemCommand`，確認指令只針對一個 PID，而且絕對不含 `pkill -f`。另外注意 [OVSPowerStrategy.cpp:49](../src/ndt_core/power_management/OVSPowerStrategy.cpp#L49) 是直接呼叫 `utils::execCommand`，沒有走自己的虛擬函式，所以就算你 mock 了子類別，它還是會真的去執行 `sudo ovs-vsctl add-br` — 順手把這個接口修好。

---

## Phase 8 — 收尾整理

- ~~把 `check_env.py`、`dump_table.py`、`test_modify.py`、`test_modify_error.py` 從專案根目錄移走。`test_10_routes.py` 打的是 port 8080，但 agent 綁的是 8081~~ — **✅ 已解**（2026-08-12）：五個檔案（含 `test_10_routes.py`）都搬到 **`p4_proxy/reference/`**，port 已修成 8081，`test_modify_error.py` 的兩處根目錄相對路徑改成以 `__file__` 解析，另附 README 說明每個腳本要什麼前置條件。
  - ⚠️ **原本寫的「放到 `p4_proxy/tests/`」會弄壞測試套件。** 那三個叫 `test_*.py` 的檔案**一個測試案例都沒有**，而 `l1_unit_tests.sh:176` 會 glob `p4_proxy/tests/test_*.py`、逐檔直接執行並解析 `Ran N tests`，跑不出測試的檔案會被報成 `NO TESTS RAN`，**那在這個 runner 裡算失敗不算 skip**。檔名維持原樣是因為多份 audit 文件引用它們，那些是歷史紀錄；更正寫在 `p4_proxy/reference/README.md`。
  - ⚠️ **`intelligent_router.py` 已從這份清單移除**（2026-08-12 複查）。它不是散落腳本，是 **OVS 模式活的控制平面**：`tools/test_workflow/stack.sh` 拿它當 Ryu app 跑、`tests/python/test_route_install_gate.py:35` 用相對路徑讀它、`.env` 指到它，另有 16 份文件提及。搬它是一次真正的重構，不是整理，要另外評估。
- ~~`requirements.txt`：protobuf 版本自相矛盾；`requests` 有用到卻沒列~~ — **✅ 已解**（protobuf 釘 3.20.3 並寫明理由，`requests` 已補）。
  - `pytest.ini` / `__init__.py` 那半條**已作廢**（2026-08-12 複查）：原本的理由是「任何 Python 測試都收集不到」，但現在 385 條 Python 測試跑得好好的——`tools/test_workflow/l1_unit_tests.sh` 走 unittest + `PYTHONPATH`，不走 pytest。除非要改用 pytest，否則這裡沒有東西要修。
- ~~`CHANGELOG.md` 完全沒有 P4 的紀錄；補上。~~ — **✅ 已解**：已有 `Unreleased — P4/bmv2 support` 段落。
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
