# NDTwin 測試工具的涵蓋範圍與已知缺口

> 📍 **入口不是這裡（2026-08-17）**：「我現在該跑什麼」看
> [2026-08-17_testing-manual.md](2026-08-17_testing-manual.md)。這一份的角色是**參照**——
> 判斷某個東西有沒有被測到時用它。缺口清單寫於 2026-07-28，引用前先對現況查證。

配套文件：[2026-07-27_testing_workflow.md](2026-07-27_testing_workflow.md)（五層架構的設計）、
[tools/test_workflow/README.md](../tools/test_workflow/README.md)、
[tools/contract_test/README.md](../tools/contract_test/README.md)。

這份文件回答一個問題：**當這些工具全部亮綠燈時，哪些事情已經被證明，哪些事情還沒有。**

---

## 0. 現況盤點（實測數字）

> ## ⚠️ 2026-08-10 更新：§0 的數字與 §4／§5 的多數缺口都已過期
>
> **實跑數字**：C++ **414**（31 個 `.cpp`、一個 binary、ctest 與直接執行一致）、
> `p4_proxy/tests/` Python **312**（12 個模組全綠）、kernel 側 `tests/python/` **101**
> （⚠️ **沒有**被 ctest 註冊，要另外跑）。合計約 **827**，不是 153。
>
> **§4 點名「0 測試」的模組，現在大多有了**：
>
> | §4 說 0 測試 | 現況 |
> |---|---|
> | `LockManager`（§4.1） | `LockManagerTest` **15** |
> | `FlowDispatcher`（§4.2） | `FlowDispatcherTest` **7** |
> | `TopologyAndFlowMonitor`（§4.4） | `TopologyAndFlowMonitorTest` 5 ＋ `MininetTopologyTest` 11 = **16** |
> | `Classifier`（§4.4） | `ClassifierActionFormsTest` 16 ＋ `ClassifierDropRule` 7 = **23** |
> | `Utils.hpp` 轉換（§4.5） | `IpToStringTest` 4、`TryIpStringToUint32Test` 5、`TryParseUint64Test` 6、`TryMacToUint64Test` 7、`QueryParamTest` 9 |
> | **sFlow 輸入面（§5.1，本文稱「最大的空白」）** | `SFlowParsingFixture` 17 ＋ `BoundedWordsTest` 4，且 bounds check 已補（ASan 驗證過） |
> | **p4_proxy Python 沒有任何一層在跑（§5.2）** | L1 現在會跑，且「全 skip」會被判 `NO TESTS RAN` |
> | `HttpSession`（§4 以外，HANDOFF §1i 記為 ❌） | `HttpSessionRoutingTest` **18**（路由層；handler 內部仍缺接縫） |
>
> **§8 待辦**第 1（sFlow bounds check ＋ 畸形封包工具）、第 2（`LockManager`）、
> 第 5（`FlowDispatcher` 生命週期）**都已完成**。仍然成立的是第 3（RSS／thread 洩漏無工具）、
> 第 4（殺掉控制器後下規則）、第 6（`release_lock` 未持有仍回 200）。
>
> **§1〜§3 大致仍然成立**（工具誤判已修，但不變量太寬鬆、HTTP 協定層沒驗、併發沒驗都還在）。
>
> 下面保留原文，因為每一條的**理由**仍然有價值 —— 過期的是狀態，不是分析。

> ⚠️ **2026-07-29 更新**：下表的 L1 數字已過期。實際現況是 **95 個 gtest + 63 個 Python 測試**
> （`./run_layers.sh quick` 共 153 個），不是 12 個。Phase 4／5 期間新增的：
>
> | 檔案 | 個數 | 涵蓋 |
> |---|---|---|
> | `test_SwitchKindDispatch.cpp` | 24 | SwitchKind 分派、同質性驗證、`OpResult` 錯誤傳遞 |
> | `test_SFlowParsing.cpp` | 21 | sFlow parser 邊界檢查（ASan 證明過） |
> | `test_SFlowEmitterRoundtrip.cpp` | 17 | 跨語言 round-trip、identity port mapping、late-topology 迴歸 |
> | `test_RoutingStrategies.cpp` | 14 | P4/OVS strategy 的 endpoint 與 body |
> | `test_EstimatedRates.cpp` | 8 | `hopsCounter == 0` 的 SIGFPE 迴歸 |
> | `test_GoldenFixture.cpp` | 6 | 真實 OVS 抓包 fixture |
> | `test_ClassifierDropRule.cpp` | 5 | 無 output port 的規則（見 §4.4） |
> | Python（`p4_proxy/tests/`） | 63 | sFlow emitter 48、clone session 16（含順序契約）、live switch 1（自我 skip） |
>
> **但下面列的缺口大部分仍然成立** —— 新增的測試集中在 P4 路徑和 sFlow，
> `LockManager`／`FlowDispatcher`／`TopologyAndFlowMonitor` 仍然沒有單元測試。
>
> 另外 §1「工具本身會誤判」在 2026-07-29 又發現兩個新的，已修：
> `compare_baseline.py` 在它該比對的形狀上崩掉（`facts_of_tables` 對 list 呼叫 `.values()`），
> 以及 `stack.sh` 的 `countdown` 在非整數輸入時**靜默跳過等待並回報成功**。

> 數字為 2026-07-28 §1 修復後的狀態。

| 層 | 工具 | 實際涵蓋 | 沒涵蓋 |
|---|---|---|---|
| L0 | `l0_build_check.sh` | 10 個建置目標；Python 只做 `ast.parse`（語法） | 執行期 import、型別、連結相依 |
| L1 | `l1_unit_tests.sh` | **12 個 gtest**，涵蓋 3 個函式 | 三大模組共 5,693 行程式碼 **0 測試** |
| L2 | `run_contract_test.py` | 45 個 check，**涵蓋 41 個 endpoint 中的 30 個** | 11 個無 contract：6 個 group/meter + 4 個無 consumer + `intent_translator`（刻意） |
| L3 | `l3_component_check.py` | 7 個元件的相依存在性 + dispatch 表漂移檢查 | 沒有 contract 的端點仍只驗「不是 404 也不是 5xx」 |
| L4 | `compare_baseline.py` | OVS/P4 的 shape + 行為布林值差異 | 4-A 場景表第 5–10 步全部未腳本化 |
| log | `check_logs.py` | allowlist 判定 + **崩潰偵測** | 記憶體／thread 洩漏 |

L1 的 12 個測試分佈：`computeEstimatedRates` 8 個、`OpenFlowRoutingStrategy` 2 個、
`P4RoutingStrategy` 2 個。以下模組**完全沒有單元測試**：

```
TopologyAndFlowMonitor.cpp    2,292 行
FlowLinkUsageCollector.cpp    2,091 行
Classifier.cpp                1,310 行
LockManager.hpp                 120 行
FlowDispatcher.cpp               72 行
Utils.hpp（IP/MAC/port 轉換）
DeviceConfigurationAndPowerManager.cpp
ApplicationManager.cpp / SimulationRequestManager.cpp
IntentTranslator.cpp / LLMAgent.cpp
HistoricalDataManager.cpp
```

---

## 1. 工具本身會誤判 — ✅ 已於 2026-07-28 全部修復

> **狀態更新**：本節列出的五個問題都已修好並經反向驗證（不只驗「會通過」，也驗
> 「該失敗時真的會失敗」）。原始診斷保留在下面，因為修法的理由需要它；每一小節
> 開頭標註了實際採用的解法。
>
> | 問題 | 解法 |
> |---|---|
> | §1.1 鎖型別不存在 | 改用 `graph_lock`（kernel 認得、但沒有 app 在用） |
> | §1.1 `release_lock` 一律 200 | 標為 `known_gap`，顯示黃色不計失敗；修好會提示移除標記 |
> | §1.2 log 被 L2 自己污染 | `check_logs.py --to-line`，只檢查 L2 之前的區間 |
> | §1.3 `--save-json` 重複請求 | 改為重用第一次驗證時的回應 |
> | §1.4 L3 把 5xx 當「存在」 | 5xx 現在判定為問題 |
> | §1.5 手抄表無同步檢查 | `--check-drift` 直接讀 `HttpSession.cpp` 比對 |
>
> 額外補上：**崩潰偵測**（`terminate` / SIGSEGV / SIGFPE / assertion 等，掃每一行，
> 不受 `--ignore-unparsed` 與 allowlist 影響），以及 §5.3 提到的
> 「log 檔不存在時靜默通過」現在會回報失敗。

這些不是「涵蓋不足」，是**測試寫錯了**。在補齊之前，你會看到失敗但 kernel 是好的，
或看到通過但其實什麼都沒驗。

### 1.1 L2 的 5 個鎖檢查：3 個必定失敗、1 個假通過

`LockManager::stringToLockType()`（[LockManager.hpp:38](../include/ndt_core/lock_management/LockManager.hpp#L38)）
只認得三個字串：`routing_lock`、`graph_lock`、`power_lock`，其他一律回 `LockType::Unknown`。

但 [spec.py:379](../tools/contract_test/spec.py#L379) 用的是 `"type": "ndt_contract_test_lock"`
（註解寫「uses its own lock type so it cannot disturb a running app」——立意良好，但這個型別不存在）。

實際會發生的事：

| check | 期望 | 實際 | 結果 |
|---|---|---|---|
| `acquire_lock` | 200 | **423**（Unknown type → `acquireLock` 回 false） | **FAIL** |
| `acquire_lock_conflict` | 423 | 423（但原因是型別無效，不是鎖被持有） | 假通過 |
| `renew_lock` | 200 | **412**（`renew` 對 Unknown 回 false） | **FAIL** |
| `release_lock` | 200 | 200 | pass |
| `release_lock_not_held` | 412/400/404 | **200**（`handleReleaseLock` 無條件回 200） | **FAIL** |

兩個獨立問題：

1. **測試端**：型別不存在，所以互斥語意從來沒被驗過。
2. **kernel 端**：`HttpSession::handleReleaseLock` **無論鎖是否持有、型別是否有效，一律回 200**
   （`LockManager::unlock` 回傳 `void`，handler 沒有東西可以分支）。
   `2026-07-27_testing_workflow.md` 舊版錯誤路徑清單裡的「release_lock 用過期的 lock → 412」不成立，
   `2026-01-02_ndt_api.md` 舊版寫的 **423** 同樣不成立。**兩處都已於 2026-08-12 移除**，
   所以這裡不再是「兩份來源文件還在教」的狀態。缺口本身還在：`LockManager` 沒有 owner token，
   任何人都能釋放別人的鎖並被告知成功。

~~**還沒解的兩難**：要真正驗互斥，就得用 `routing_lock`，而那正是 Energy-Saving-App 和
Traffic-Engineering-App 在用的鎖。~~

**已解**：這個兩難的前提不成立。`stringToLockType` 認得**三個**型別，而全 workspace
掃過只有 `routing_lock` 被 app 使用（4 處，Energy-Saving-App 與 Traffic-Engineering-App）。
`graph_lock` 和 `power_lock` 是 kernel 真的認得、但**沒有任何 app 在用**的型別。

所以測試改用 `graph_lock`：跑的是真正的互斥語意，又不可能干擾正在跑的 app。現在驗的是
一條完整生命週期 —— `acquire` → 第二次必須 423 → `renew` → `release` → **再 acquire
必須成功**（這步會抓到「release 回報成功但其實沒放開」）→ cleanup。

`LockManager` 沒有 owner token（任何人都能 `unlock()` 別人的鎖）仍然是**設計缺口**，
只是不再阻擋測試。

### 1.2 ~~`run_layers.sh api` 的 log 檢查必定失敗~~ — ✅ 已解，本節原本的描述是錯的

🔴 **2026-08-12 更正：這一節從頭到尾不成立，而且在它自己 2026-08-10 那次更正 pass 之前就已經不成立了。**
原文的三項斷言逐條核過，三項都假：

| 原文斷言 | 實際 |
|---|---|
| malformed input 會寫 `[error] Standard exception in request handler`，因為 `std::stoull` 沒防護 | `inform_switch_entered` 和 `get_nickname` 都改用 `utils::tryParseUint64`，回 400 並記 **WARN**；`stoull` 已經不在這兩個 handler 裡（`832d75c`） |
| malformed JSON 會寫 `[error] JSON exception in request handler` | 那個 catch 就是 400 路徑，記的是 **WARN** 不是 ERROR，並且原地留了註解說明為什麼（`78b822a`） |
| `warning_allowlist.txt` 沒有任何一條涵蓋這些 | 涵蓋得很完整，而且每一條都標了是哪個 L2 check 觸發的——正是本節原本開的第三個藥方 |

`run_layers.sh` 另外還實作了第一個藥方：`mark_log` 在跑 L2 之前記下 log 行數，
log 檢查只看標記之後的區間，並且會偵測「同一個 kernel process 被連跑兩輪」這個
會讓標記失效的情況，偵測到就降級成警告而不是假裝通過。

**所以第三層不是永遠紅的。** 原文的結論「這會訓練你忽略 log 檢查的結果」方向是對的——
只是該被訓練忽略的是這一節，不是 log 檢查。整節保留成紀錄而不刪除，因為它示範了一個
反覆出現的失效模式：**這一節在 2026-08-10 被「更正」過，更正的人沒有重跑它的斷言，
所以錯誤原封不動地活過了自己的校對。** 引文寫進文件之前要重新 grep，不能靠記憶。

### 1.3 `--save-json` 會把每個 endpoint 打第二次

[run_contract_test.py:321-324](../tools/contract_test/run_contract_test.py#L321-L324)：
驗證完之後，為了存 JSON **又發了一次請求**。

後果：

- `acquire_lock` 被呼叫兩次 → 存下來的 `acquire_lock.json` 是第二次的**衝突回應**，不是成功回應。
  L4 比對時，OVS 與 P4 兩邊存到哪一種取決於時序。
- `run_layers.sh full <mode> --mutations`（[第 220 行](../tools/test_workflow/run_layers.sh#L220)
  把 `--allow-mutations` 傳給 `run_capture`）會讓 `install_flow_entry` / `modify_flow_entry` /
  `delete_flow_entry` / 批次端點**各執行兩次**，實際對網路下了兩輪規則。
- 對時間敏感的欄位（速率、計數器）存下的值和驗證時用的值不是同一份。

### 1.4 L3 的存在性探測把 500 當成「存在」

[l3_component_check.py:76-77](../tools/contract_test/l3_component_check.py#L76-L77)：
只要狀態碼不是 404 就回 True。一個 POST 空 body 就 500 的 endpoint，在 L3 眼中是健康的。

同時，L3 對每個元件的 endpoint 只做 existence 檢查，只有出現在 `spec.py` 的才做 contract 檢查。
以下 **6 個有真實 consumer 的 endpoint 因此只被驗了「不是 404」**：

```
app_register               ← Energy-Saving-App, Simulation-Platform-Manager
received_a_simulation_case ← Energy-Saving-App, Simulation-Platform-Manager
simulation_completed       ← Simulation-Platform-Manager
set_switches_power_state   ← Energy-Saving-App（會改動實體電源）
modify_device_name         ← Web-GUI
intent_translator/text     ← Web-GUI
```

### 1.5 `KERNEL_ENDPOINTS` 是手抄的，沒有同步檢查

[components.py:21](../tools/contract_test/components.py#L21) 的 41 筆是從 `HttpSession.cpp`
的 if/else 鏈**人工轉錄**的。新增 endpoint 而忘記更新這張表時，沒有任何一層會發現——
L3 反而會把新 endpoint 報成「不在 dispatch table」。（目前實測兩邊一致，但這是靠人維持的。）

---

## 2. API 表面沒被涵蓋的部分

### 2.1 16 個 endpoint 沒有 contract spec

`2026-07-27_testing_workflow.md` 說「把 40 個 endpoint 全部打一遍」，實際 `spec.py` 涵蓋 **25/41**。
未涵蓋清單（後綴是 consumer）：

```
set_switches_power_state          Energy-Saving-App     ← 會改動電源，風險最高
app_register                      Energy app + Sim mgr
received_a_simulation_case        Energy app + Sim mgr
simulation_completed              Sim mgr
modify_device_name                Web-GUI
intent_translator/text            Web-GUI
link_failure_detected             （無）
link_recovery_detected            （無）
inform_all_destination_paths      （無）
historical_logging                （無）
install/delete/modify_group_entry （無）
install/delete/modify_meter_entry （無）
```

另外 `get_openflow_capacity` 雖然有 spec，但 schema 是 `Any_()`，等於不驗。

group/meter 這 6 個在 P4 模式下**無條件走 OVS strategy**
（[FlowRoutingManager.cpp:92-133](../src/ndt_core/routing_management/FlowRoutingManager.cpp#L92-L133)
直接用 `m_ovsStrategy`，完全不看 dpid），也就是 P4 模式下對 bmv2 下 group/meter 規則會被送到 Ryu。
沒有任何測試會抓到。

### 2.2 HTTP 協定層完全沒驗

- **方法錯誤**：kernel 用 `(method, target)` 配對；GET 打 POST-only endpoint 會落到 404。
  沒有測試確認這是刻意的，也沒有測試會抓到「某個 endpoint 的方法被改掉」。
- **`OPTIONS` / CORS**：[HttpSession.cpp:103-125](../src/ndt_core/http/HttpSession.cpp#L103-L125)
  有完整的 CORS 標頭與 204 處理，Web-GUI 直接依賴它。零測試。
- **請求體大小**：沒有 body limit 檢查，也沒有測試送過大 body。
- **keep-alive / pipelining**：`response->keep_alive(m_req.keep_alive())` 有實作，沒測試。
- **`get_detected_top_k_flow_data?k=` 的邊界**：`k=0`、`k=-1`、`k` 非數字、`k` 極大值都沒測。
  現有的 `inv_topk_bounded` 只檢查「回傳數量 ≤ k」。

### 2.3 併發與 head-of-line blocking

[main.cpp:140](../src/main.cpp#L140) 是 `net::io_context ioc{1}` ——**HTTP 伺服器是單執行緒的**。
任何一個慢的 handler（SNMP 取 CPU/記憶體、SSH 取溫度、對 Ryu 的同步 curl）
會阻塞**所有**其他請求。

而 L2/L3 是**序列**發請求的，永遠不會遇到這個情況。實際跑起來時：
Web-GUI 每秒輪詢、Visualizer 同時輪詢、NSR 同時輪詢、Energy app 同時下規則——
這個組合沒有任何一層測試會重現。

沒被涵蓋的具體情境：

- 多個 client 同時打 `get_graph_data`（graph 有 `shared_mutex`，讀寫競爭未驗證）
- 一邊 `install_flow_entry` 一邊 `get_switch_openflow_table_entries`
- 兩個 app 同時 `acquire_lock`（真正的競爭，不是序列的兩次呼叫）
- 慢端點（溫度/SNMP）進行中時，其他請求的延遲

---

## 3. 不變量本身太寬鬆

即使 L2 全綠，下面這些狀況也不會被抓到：

| 不變量 | 現在檢查什麼 | 漏掉什麼 |
|---|---|---|
| `inv_graph_matches_topology` | node/edge **數量**、dpid 集合 | edge 的**接線對不對**（數量對但接錯不會被抓） |
| `inv_flow_paths_non_empty` | path 陣列非空 | path 是否連通、是否與 edge 一致、有無迴圈 |
| `inv_flow_rates_nonzero` | **全部**為 0 才失敗 | 99% 的 flow 速率為 0 會通過 |
| `inv_topk_bounded` | 數量 ≤ k | 回傳的是否真的是**前 k 大**、是否已排序 |
| `inv_util_map_covers_switches` | map 大小 ≥ switch 數 | key 是否對應到真實的 switch IP |
| `inv_power_covers_switches` | 每台 switch 都有讀數 | `power_consumed` 允許負值（schema 是 `Num()` 無 `min`） |
| `FLOW_RECORD` 的時間欄位 | 非空字串 | 格式、`first_sampled_time <= latest_sampled_time` |
| `get_path_switch_count` | `OneOf` 第二分支是 `Obj({"status"}, strict=False)` | **任何含 `status` 的物件都通過**，`switch_count` 消失也不會失敗 |
| IP 欄位 | `Int(min=0)` | 無 `max=0xFFFFFFFF`，超出 uint32 的值會通過 |

`Obj` 預設 `strict=False` 是刻意的（新增欄位不該算破壞），但代價是
**欄位被改名時只會報「缺少必要欄位」，不會指出新名字**——訊息品質下降，不影響判定。

---

## 4. Kernel 內部邏輯（L1 層）的缺口

### 4.1 `LockManager`：0 個單元測試

這是最該補的一個——它很小（120 行）、純邏輯、沒有外部相依，而且是多 app 協作的正確性基礎。
未涵蓋的邊界條件：

- **TTL 過期後自動可取得**：`acquireLock` 的 `now < state.expiryTime` 分支
- `ttl = 0` / 負數 / 極大值
- **沒有 owner 概念**：A 取得的鎖，B 可以 `unlock()`。這是設計缺口，不只是測試缺口
- `renew` 一個已過期但 `isLocked` 仍為 true 的鎖 → 目前會**成功續期**
  （`renew` 只檢查 `isLocked`，不檢查 `expiryTime`），等於過期的鎖可以無限復活
- 三種鎖型別之間的獨立性

### 4.2 `FlowDispatcher`：worker 退出後永遠不會重生

[FlowDispatcher.cpp:24-27](../src/ndt_core/routing_management/FlowDispatcher.cpp#L24-L27)：
worker 是 per-DPID 懶生成，條件是 `!workers_.count(job.dpid)`。
但 `workerLoop_` 在 `!running_ && queue 空` 時會 `break` 離開執行緒，
**而 `workers_` 裡的項目不會被移除**。

後果：一旦某個 dpid 的 worker 因為任何原因退出（例如 `stop()` 之後又有 job 進來），
`workers_.count(dpid)` 仍是 1，新 worker 不會生成，**該 dpid 的所有 job 從此靜靜卡在佇列裡**，
沒有錯誤、沒有 log。

`running_` 初始為 `false`（`FlowDispatcher.hpp:102`），所以 `start()` 之前 enqueue 也會踩到。
零測試。

### 4.3 `FlowRoutingManager::getStrategyForDpid`：兩個問題

```cpp
Graph g = m_topologyAndFlowMonitor->getGraph();   // FlowRoutingManager.cpp:55
```

1. **每下一條 flow entry 就複製整張 graph**。批次端點下 1000 條規則 = 1000 次全圖複製。
   沒有任何效能或負載測試。
2. **未知 dpid 靜默 fallback 到 OVS strategy**（[第 63-64 行](../src/ndt_core/routing_management/FlowRoutingManager.cpp#L63-L64)
   的註解就這麼寫）。`spec.py` 的 `install_flow_entry__unknown_dpid` 期望 4xx——
   這個檢查**會正確地失敗**，是設計如此。記在這裡是為了讓你知道那個紅燈是真的 kernel 問題，不是測試錯。

### 4.4 `Classifier` / `TopologyAndFlowMonitor`：3,600 行，幾乎沒測試

> **2026-07-29 更新**：`Classifier` 現在有 5 個測試（`test_ClassifierDropRule.cpp`），
> 但那是**被一個實機 crash 逼出來的**，不是主動補的涵蓋率。下面列的缺口除了「action 的字串
> vs 物件形式」之外全部仍然成立，`TopologyAndFlowMonitor` 仍是 0 測試。
>
> 那個 crash 值得記在這裡，因為它正好命中本節指出的兩個弱點：
>
> `upsertRule` 對沒有 output action 的規則呼叫 `outputPorts.front()` → `segfault at 0`。
> 觸發條件是 Ryu 把 table-miss 的 drop 規則回報成 `"actions": []`（1300 條裡剛好 1 條）。
> 兩個讓它藏住的原因：
>
> 1. 三個呼叫點都在 `SPDLOG_LOGGER_TRACE` 裡。**spdlog 把參數當普通函式引數傳進 `log()`，
>    等級過濾發生在函式內部** —— 所以「看起來關掉的」trace log 裡的運算式照樣執行。
>    這個 build 還帶著 `-DSPDLOG_ACTIVE_LEVEL=SPDLOG_LEVEL_TRACE`。
> 2. **從來沒有東西走到那裡。** 測試環境的 Ryu 少載 `ryu.app.ofctl_rest`，
>    `/stats/flow/<dpid>` 一直回 404 HTML，JSON 解析失敗，規則根本進不到 Classifier。
>    補上那個 app 之後才第一次有真實規則流進來，crash 立刻浮現。
>
> 教訓對本文件的意義：**「0 測試」不是唯一的風險，「0 執行」更隱蔽** ——
> 那段程式碼在這個 harness 裡從來沒被執行過，所以連手動測試都不可能發現。

這兩支決定了 `get_graph_data` 和每個 flow 的 `path`——也就是 7 個元件全部依賴的東西。
明顯的邊界條件都沒被驗：

- 拓樸檔缺欄位、dpid 重複、edge 指向不存在的 node
- 空拓樸、單節點拓樸
- BFS 找不到路徑 / 路徑有迴圈（只有 `FORBID | Exceed 100 hop` 這條 log 規則當安全網）
- flow table 的 priority 平手、重疊的 match、萬用字元遮罩
- OpenFlow action 的字串形式 vs 物件形式（`Classifier.cpp` 只解析字串形式 `"OUTPUT:1"`，
  `{"type":"OUTPUT","port":N}` 會被**靜默忽略**）。**這是 P4 proxy 的硬性契約**，Phase 6 實作
  `/stats/flow/<dpid>` 時必須遵守，否則 Classifier 會是空的、每個 flow 的 `path` 都是 `[]`。
  已寫進 [2026-07-27_p4_bmv2_support_plan.md](2026-07-27_p4_bmv2_support_plan.md) 的 Phase 6 入手點第 2 條
  （同時那裡也記了 `flows` 必須是 map 而不是 list）。
- **沒有 output action 的規則** —— 2026-07-29 已補測試，見本節開頭

### 4.5 `Utils.hpp` 的轉換函式

`ipStringToUint32` / `portStringToUint` / `hexStringToUint64` / `macToUint64` 都是純函式、
零相依、極易測試，但一個測試都沒有。典型邊界：空字串、超長、非法字元、溢位、
大小端（`ipToString` 有網路序假設，topology JSON 也用網路序，兩者是否一致沒被驗）。

### 4.6 ~~初始化順序（潛在，目前無害）~~ — ✅ 已解，2026-08-12 參數與成員一起移除

原本的描述：`main.cpp` 建構 `collector` 時傳進去的 `flowRoutingManager` **還是 null**
（要等 collector 建好之後才賦值），collector 存的是那份 null 的複本。

實際查證後，情況比原本寫的還要再前面一步：建構子的初始化列表**根本沒有初始化**
`m_flowRoutingManager`，那個成員從頭到尾是預設建構出來的 null；而且整個 repo 裡
沒有任何一處讀過它（`FlowLinkUsageCollector` 內就只有宣告那一行，其餘同名成員分別
屬於 `Controller`／`IntentTranslator`／`HttpSession`／`ControllerAndOtherEventHandler`）。

因此選擇把建構子參數與成員一起移除，而不是補上初始化：`FlowRoutingManager` 已經持有
`shared_ptr<sflow::FlowLinkUsageCollector>`（`FlowRoutingManager::m_flowLinkUsageCollector`），
collector 再反向持有一條 `shared_ptr` 就會形成循環參照，兩邊都不會被解構。要正確接起來
得改用 `weak_ptr` 再加一個建構後的 setter — 為了一個沒人讀的成員，不值得。

---

## 5. 完全沒有被任何一層碰到的東西

### 5.1 sFlow UDP 輸入面 ← 最大的空白

kernel 有**兩個**外部輸入面：北向的 `/ndt/*` HTTP，以及 **:6343 的 sFlow UDP**。
所有五層測試都只碰前者。

而 sFlow 解析器（[FlowLinkUsageCollector.cpp:683](../src/ndt_core/collection/FlowLinkUsageCollector.cpp#L683) 起）
只做兩項驗證：

```cpp
if (len < 7 * 4)    return;   // 至少要有標頭
if ((len % 4) != 0) return;   // 32-bit 對齊
```

之後 `sampleCount` 直接取自封包內容（第 709 行），迴圈用固定偏移量索引：

```cpp
interfaceSpeed = (ntohl(data[index + baseOffset + 15 + 5]) << 32) | ...
```

**沒有任何一處檢查 `index + offset` 是否還在 `len/4` 之內**。
一個被截斷或格式錯誤的 sFlow datagram 會造成越界讀取——症狀是隨機的錯誤數值或偶發 crash，
而且極難從 GUI 或 log 追出來。

沒被涵蓋的情境（全部只需要一支送 UDP 封包的小工具就能測）：

- 截斷的 datagram、`sampleCount` 灌大值、`sampleLen` 與實際不符
- 未知的 sample type、未知的 vendor（`baseOffset` 只處理 Brocade=2 / HPE=4）
- 非 IPv4 的 etherType、IP 分片、非 TCP/UDP 協定
- 封包佇列滿載時的丟棄行為（`FlowLinkUsageCollector.cpp:380` 的 `m_q.size() >= m_capacity`）
- 取樣率為 0（速率計算的除數）

`FORBID | Unsupported SFlow Version` 這條 log 規則是目前唯一的安全網，
但它只在版本欄位剛好不是 5 的時候才會響。

### 5.2 `p4_proxy` 自己的 Python 測試沒有任何一層在跑

`p4_proxy/tests/test_p4_client.py` 和 `p4_proxy/reference/test_10_routes.py`（2026-08-12 `3fc42ed` 自 `p4_proxy/` 搬入）存在，
但 L0 只用 `p4c-bm2-ss` 編譯 P4 pipeline，L1 只跑 C++ gtest binary。
P4 proxy agent（FastAPI，是 P4 模式下 kernel 唯一的南向對口）的邏輯完全在測試範圍外。

### 5.3 行程健康度：文件寫了，工具沒做

`2026-07-27_testing_workflow.md` 第 204-213 行列出四項判定標準：

```
✓ 全程沒有 crash（特別注意 SIGFPE / std::terminate）
✓ 記憶體用量在 10 分鐘內穩定（RSS 成長 < 10%）
✓ thread 數量穩定
✓ 關閉時 exit code == 0
```

**這四項一項都沒有實作。** `tools/` 底下沒有任何量測 RSS 或 thread 數的東西；
`stack.sh` 的 `stop_one()` 送 TERM 之後只確認行程消失，從不擷取 exit code。

諷刺的是，文件自己指出「我們剛修的兩個 bug 就是這類」
（`m_ifIndexToOfportMap` 無上限成長、`m_flushEdgeFlowLoop` 沒 join 導致 `std::terminate`）——
也就是說，這兩個 bug 如果再次出現，現在的工具一樣抓不到。

而且 `run_logcheck` 傳了 `--ignore-unparsed`（[run_layers.sh:86](../tools/test_workflow/run_layers.sh#L86)），
所以**任何不符合 spdlog 格式的輸出都被忽略**，包括：

- `terminate called after throwing an instance of ...`
- segfault 的核心訊息
- 子行程（curl / ssh）的 stderr

換句話說，**crash 訊息剛好落在 log 檢查的盲區裡**。

另外 `run_logcheck` 在 log 檔不存在時**回傳 0（通過）**，理由是「stack 可能是手動起的」——
而手動起 stack 正是文件建議的常態流程（Mininet 需要 root）。所以這一層很容易在無聲中什麼都沒檢查。

### 5.4 L4 4-A 場景表：10 步只實作了差異比對

`2026-07-27_testing_workflow.md` 的 4-A 表列了 10 個步驟，實際被腳本化的只有第 2 步（收斂，由 `stack.sh wait` 做）
和 4-B 的差異比對。以下**全部需要人工**：

- 第 5 步：下規則後**流量真的改走新 port**（只驗規則出現在表裡是不夠的）
- 第 6 步：關掉 switch 後**維持** down、其餘 9 台仍能轉送
- 第 7 步：Visualizer / Web-GUI 的 node 數 = API 的 node 數
- 第 8 步：NSR 錄 60 秒的 zip 內容筆數、能否被 playback 載入
- 第 9 步：Energy-Saving-App 完整一輪
- 第 10 步：**殺掉 Ryu/proxy 後下規則，kernel 要回報失敗而不是回 200**
  ← 這一步最有價值也最容易做（路由策略是 `curl` 的 fire-and-forget，很可能真的回 200）

---

## 6. 環境與可重現性

- **`components.env` 綁死本機路徑**（`/home/adam/...`、`miniconda3` 的三個 env）。
  換機器就整套失效，而且失敗形式是 SKIP 而非 FAIL——**涵蓋範圍靜靜地縮小**。
  L0 的 SKIP 不計失敗是刻意的設計，但這代表「L0 全綠」可能只驗了 8 個目標中的 2 個。
- **`stack.sh` 用 `printf '1\n%s\n2\n'` 餵 kernel 的 stdin**
  （[stack.sh:236](../tools/test_workflow/stack.sh#L236)）。
  `main.cpp` 的互動式提問只要順序或數量一變，餵進去的答案就對錯位，
  而且**症狀是 kernel 載入錯的拓樸**，不是明顯的失敗。（已知，Phase 1 的 CLI 參數會解掉。）
- **Mininet 手動**：無法完全自動化，`up` 會停下來等 Enter。CI 化的最大障礙。
- **L4 baseline 沒有時效性檢查**：`compare_baseline.py` 不看擷取時間，
  拿三個月前的 OVS baseline 比對今天的 P4 結果，工具不會提醒。
- **兩邊拓樸不同**（OVS 10 switches/128 hosts vs P4 10 switches/4 hosts）。
  `shape()` 用 `[]` 收斂 list 索引來處理這件事，但也因此
  **任何「數量」層級的差異都不在 L4 的比對範圍內**。

---

## 7. 所以現在可以信到什麼程度

| 你想確認的事 | 跑什麼 | 綠燈可信嗎 |
|---|---|---|
| 沒把別人的 build 弄壞 | `run_layers.sh quick` | ✅ 可信（但注意 SKIP 數量） |
| `computeEstimatedRates` 沒退化 | L1 | ✅ 可信 |
| 路由策略產生的 curl 字串正確 | L1 | ✅ 可信（只驗字串，不驗對方收到後的行為） |
| 拓樸有正確載入、switch 都 up | L2 `get_graph_data` | ✅ 可信 |
| API 的欄位/型別沒被改壞 | L2 | ⚠️ 只涵蓋 25/41 個 endpoint |
| 錯誤輸入不會 500 | L2 錯誤路徑 | ⚠️ 只有 7 個案例，且會污染 log 檢查 |
| 鎖的互斥正確 | L2 | ✅ 可信（完整生命週期，用 `graph_lock`） |
| 某個元件會不會壞 | L3 | ⚠️ 涵蓋 30/41；有 consumer 的只剩 `intent_translator` 未驗（刻意） |
| P4 與 OVS 行為一致 | L4 | ⚠️ 只比 shape 與布林事實，不比數量與數值 |
| 沒有新的 error/warning | log 檢查 | ✅ 可信（`--to-line` 排除 L2 自己造成的） |
| **有沒有 crash** | log 檢查 | ✅ 可信（terminate/SIGSEGV/SIGFPE 等，不可 allowlist） |
| 記憶體 / thread 洩漏 | — | ❌ **沒有工具** |
| sFlow 解析穩健 | — | ❌ **沒有工具**（最大空白，見 §5.1） |
| 高負載/併發下正常 | — | ❌ **沒有工具** |

**一句話的使用建議**（2026-07-28 更新）：
§1 修完之後，`run_layers.sh quick`、L2（含鎖）、log 檢查與崩潰偵測都可以當守門員了。
剩下不要相信的是：**記憶體/thread 洩漏**、**sFlow 輸入面的穩健性**、**併發行為** —— 這三項
目前沒有任何工具涵蓋。

---

## 8. 建議的補強順序

按「投入 ÷ 抓到真問題的機率」排序：

### 已完成（2026-07-28）

| # | 項目 | 結果 |
|---|---|---|
| ~~1~~ | 修 `spec.py` 的 lock type | ✅ 改用 `graph_lock`，互斥現在真的有被驗 |
| ~~2~~ | log 檢查不被 L2 錯誤路徑污染 | ✅ `--to-line`，並補上崩潰偵測 |
| ~~3~~ | 拿掉 `--save-json` 的第二次請求 | ✅ 改為重用第一次的回應 |
| ~~6~~ | 幫有 consumer 的端點寫 contract | ✅ 涵蓋 25→30；有 consumer 的只剩 `intent_translator`（刻意排除，已記錄理由） |
| ~~8~~ | 自動比對 `KERNEL_ENDPOINTS` 與 `HttpSession.cpp` | ✅ `--check-drift`（漏列／方法錯／多列都抓得到） |

### 待辦

| # | 項目 | 為什麼排這裡 |
|---|---|---|
| 1 | 補 sFlow 解析的 bounds check + 一支送畸形封包的測試工具 | **唯一沒被碰過的輸入面，且目前有越界讀取風險**。這是現在最該做的 |
| 2 | 補 `LockManager` 單元測試（TTL 過期、renew 過期鎖、型別獨立） | 120 行純邏輯、零相依，CP 值最高，且已知 `renew` 有邏輯漏洞 |
| 3 | 行程健康度腳本（RSS / thread / exit code） | 崩潰已經抓得到，但洩漏還不行 |
| 4 | L4 4-A 的第 10 步（殺掉控制器後下規則要回報失敗） | 單步、高價值，很可能立刻抓到 bug |
| 5 | `FlowDispatcher` 的 worker 生命週期測試 | 已知有「worker 退出後 job 永久卡住」的路徑 |
| 6 | 幫 kernel 的 `release_lock` 加上「鎖未持有」的判斷 | 目前是 `known_gap`；修好後 L2 會自動提示移除標記 |

前五項是**補涵蓋**，第 6 項是**修 kernel**。第 1 項（sFlow）值得優先，因為它同時是
測試缺口和潛在的記憶體安全問題。

---

## 附錄：如何重新驗證這份文件的數字

這份文件的數字都是實測的，改動程式碼之後可以用下面的指令重新確認：

```bash
# §0 / §2.1 的 endpoint 涵蓋率
cd tools/contract_test && python3 -c "
import sys; sys.path.insert(0,'.')
import spec, components
covered = {e['path'].removeprefix('/ndt/') for e in spec.ENDPOINTS}
kernel  = set(components.KERNEL_ENDPOINTS)
print('registered:', len(kernel), ' covered:', len(covered & kernel))
for e in sorted(kernel - covered):
    print('  UNCOVERED', e, components.blast_radius(e) or '-')"

# components.py 的手抄表是否還跟 HttpSession.cpp 一致
grep -oE '/ndt/[a-zA-Z0-9_/]+' src/ndt_core/http/HttpSession.cpp | sort -u | wc -l

# L1 的測試數
cmake --build build -j"$(nproc)" && ./build/bin/test_routing_strategy --gtest_list_tests

# 離線自我測試的基準（目前應為 47 checks）
python3 tools/contract_test/run_contract_test.py --self-test | tail -2
```

---

*[Co-developed with claude code -- Adam]*
