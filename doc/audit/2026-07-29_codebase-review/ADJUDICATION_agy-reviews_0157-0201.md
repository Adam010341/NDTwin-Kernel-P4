# agy-reviews 0157–0201 HIGH 項目裁決

2026-08-11。47 個 HIGH，全部逐條對照**當前**程式碼裁決過（不是相信 review 的說法）。
0157–0196 由四個平行 subagent 處理，0198–0201 由我處理，關鍵項目我另外抽驗過。

| 判定 | 數量 |
|---|---|
| 仍未修復（真問題） | 21 |
| 仍未修復（**刻意的取捨**，非缺陷） | 3 |
| 已被後續 commit 修掉 | 10 |
| 誤判 | 6 |
| 文件錯誤（我今天寫的） | 3 |
| 重複（0201#1 = 0186#1） | 1 |

---

## Tier 1 — 建議優先處理

### 1. 🔴 `/ndt/intent_translator/text` 在 `--no-ai` 下會讓整個 kernel segfault
`src/ndt_core/http/HttpSession.cpp:1306-1308`（來源 0185 #4）

`--no-ai` → `main.cpp:346-360` 讓 `intentTranslator = nullptr`，else 分支只印 log。
`handleInputTextIntent` 沒有 null 檢查就解參考。`catch (const std::exception&)` 接不到 segfault。

**一個格式正確的 POST 就能殺掉整個 kernel process**，連帶所有其他端點。
`stack.sh:606` 正是用 `--no-ai` 啟動——**今天整天跑的 stack 都在這個狀態**。
目前的緩解措施是 `doc/2026-01-02_ndt_api.md:3057-3060` 用一句話請大家不要呼叫它。

修法：三行 null 檢查回 503。

### 2. 🔴 無鎖遍歷 `self.net` 會永久殺掉一條 gRPC 接收執行緒
`p4_proxy/proxy_agent/topology_manager.py:451-466`（來源 0176 #1）

`handle_packet_in` → `add_link()` → `install_initial_routes()` → `calculate_all_paths()` 無鎖讀圖。
每台 switch 一條接收執行緒，A 的 `add_link` 可在 B 遍歷時插入 →
`RuntimeError: dictionary changed size during iteration`。
`p4_client.py:81` 只 catch `grpc.RpcError`，這個例外會逃出去讓該執行緒死掉。
類別註解 `:292-294` 自承「`install_initial_routes` 仍無鎖 — **not fixed here**」。

**症狀正好命中我們的赦免邏輯**：該 switch 不再送 packet-in → 所有入向靜默 →
watchdog 全報 down → 但 gRPC 還活著 → 決定 7/8 的赦免條件成立 → 全部被原諒。
twin 不會崩，只會安靜地報過時狀態。**赦免邏輯現在身兼二職，其中一職是掩蓋這個缺陷。**

### 3. 🔴 `/stats/flow/{dpid}` 讀取失敗回空陣列，kernel 當成權威快照
`p4_proxy/proxy_agent/api_routes.py:178-183` ↔ `src/ndt_core/collection/Classifier.cpp:1310`（來源 0170 #2）

兩端各自寫下**互相矛盾**的刻意政策：
- proxy：「一次暫時性失敗只該損失一次輪詢」→ 回 `{dpid: []}`
- kernel：「**空陣列是快照，必須套用**；只有讀不到才跳過」→ 掃掉該 switch 所有規則

調和機制只有 0.5 秒延遲判斷（`kFlowStatsSuspectSeconds`），但**快速失敗遠在 0.5 秒內**回來。
症狀：GUI 裡所有 flow 的 path 消失一個輪詢週期，**kernel 端不留任何 log**。
和 2026-08-07 的 Ryu wedge 是同一個 bug 形狀。

### 4. 🔴 `_installed_routes` 看不到 `/stats/flowentry/*`，外部改路後 twin 報舊路徑
`p4_proxy/proxy_agent/topology_manager.py:644` 是唯一寫入點（來源 0189 #1）

`route_flow` / `unroute_flow` / `modify_flow`（`:548`, `:569`, `:599`）都不更新這個 map。
Traffic-Engineering 或 Energy-Saving 透過 REST 改路之後，switch 動了但 twin 繼續報舊 hop list；
`delete` 之後 twin 仍宣告一條已不存在的路徑。
**這正是 `installed_routes`（決定 5 / 代號 B）當初要防的那個謊，從 REST 這道門走回來了。**

### 5. 🔴 三個測試從來沒有被執行過
`p4_proxy/tests/test_p4_client_writes.py:806` vs `:809`（來源 0164 #1）

`WriteDeadlineTest` 定義在 `unittest.main(verbosity=2)` **之後**。
`l1_unit_tests.sh:158` 把每個檔案當腳本跑，`main()` 一執行就結束。

**實測（我自己驗過）**：腳本模式 `Ran 55 tests`，`-m unittest` 模式 `Ran 58 tests`。
14 個檔案裡只有這一個有這個問題。

那 3 個測試是為了釘住 gRPC 的 5 秒 deadline。**現在拿掉 `timeout=RPC_TIMEOUT_S`，套件依然全綠。**
修法：把那個 class 移到 `main()` 之前。

### 6. 🔴 `m_ipStrToDpidMap` 的 `operator[]` 在 7 個 handler 裡未加鎖
`src/ndt_core/intent_translator/IntentTranslator.cpp:278, 301, 324, 672, 673, 846, 861`（來源 0181 #2）

`std::map` 無自己的 mutex，唯一合法寫入者 `initializeMappingsFromGraph` 持有 `m_graphMutex`，
這些呼叫點不持有。HTTP 在 `hardware_concurrency()` 條執行緒上跑。

後果：未知 device IP 會**因為讀取而插入 dpid 0**，規則裝到 dpid 0 而不是報錯；
兩個並發請求同時插入 `std::map` 是 UB。
**正確寫法就在 50 行之外**（`:221`, `:240` 用 `.find()`）。

---

## Tier 2 — 真問題但影響有界

| # | 位置 | 問題 |
|---|---|---|
| 0185 #1 | `HttpSession.cpp:1628-1633` | 檔案不存在時回 **200 OK + 空 body**（文件說 500）；且用相對路徑 `../doc/` |
| 0185 #2 | `TopologyAndFlowMonitor.cpp:2434-2438` | 例外被吞，回 200 OK + **截斷的** topology（缺 edges 和真的沒有 edges 分不出來） |
| 0186 #1<br>（= 0201 #1） | `HttpSession.cpp:1731-1742` | 不存在的 dpid 回 `success / 0` —— 讀起來像「這台是閒置的」。**Phase 7 若用它判閒置會踩到** |
| 0196 #2 | `DeviceConfigurationAndPowerManager.cpp:1791` | 部分失敗的抓取**整份取代**快取並以 200 提供，consumer 看到 switch 憑空消失 |
| 0160 #3 | `doc/audit/2026-08-09_numeric-differential-runbook.md:321` | `total_avg` 除以樣本總數而非週期數 → **結果少一半**，−50% 撞上 ±15% 容差 |
| 0160 #2 | 同上 `:321-323` | 全部輪詢失敗時印 `TOTAL_AVG 0`，和實測閒置無法區分 |
| 0158 #1 | `tools/git-hooks/post-commit:24` | linked worktree 下路徑疊成雙重，`mkdir -p` **會成功**所以不報錯，編號從 0001 重來 |
| 0158 #2 | `post-commit:35` 和 `:52` | 「git serialises hook invocations」是假的（實測兩個 hook 完全重疊）；而 `:52` 新註解說「上面那句已移除」——**但它還在**，所以新註解自己也錯 |
| 0158 #3 | `post-commit:44` | `ls 2>/dev/null` 把「列不出來」和「空的」混為一談 |
| 0168 #1 | `HttpSession.cpp:1542, 1592` | 參數只給一半時回傳全部而非報錯——但這是**文件寫明的契約**，屬設計異議 |
| 0169 #2 | `topology_manager.py:212-214` | `load_switch_links` 讀取失敗和真的沒有連結都回 `[]`（已部分緩解，仍會在 host port 上白費 LLDP） |
| 0164 #2 | `test_p4_client_writes.py:838-841` | 測試名稱承諾的慢速寫入情境從未建構（且位於上面 #5 的死區內） |
| 0196 #1 | `Classifier.cpp:1304` | 沒有任何 eviction 路徑，永久移除的 switch 規則會活到 process 結束 |
| 0198 #2 | `DeviceConfigurationAndPowerManager.cpp:1997`（`installOne`） | 只 `push_back`，不查重複——重裝的規則以重複 entry 形式留在 `/ndt/get_switch_openflow_table_entries`，直到最多 10 秒後的下一輪整批輪詢覆蓋 |

---

## Tier 3 — 刻意的取捨，reviews 讀對了但反對的是決策

這三條**不要當成 bug 修掉**，它們有註解、有測試鎖住、且是根據實測證據做的決定：

- **0185 #3** `FlowLinkUsageCollector.cpp:2153-2156` — 空快照不清除既有路徑。
  有 30 行註解說明與 `Classifier::updateFromQueriedTables` 的不對稱是刻意的，
  `tests/test_AllDestinationPaths.cpp:142-155` 鎖住此行為。
- **0189 #2** `ryu_topology.py:257` — `if installed:` 把空 map 當「不知道」。
  docstring `:220-233` 寫明反例：bmv2 的 table entry 跨 proxy 重啟存活。
- **0196 #1** 保留跳過的 switch 的舊表 — 2026-08-07 Ryu wedge 證明相反做法會清空所有路徑。

---

## 誤判（6 條，已排除）

| # | 為什麼是誤判 |
|---|---|
| 0160 #1 | 宣稱 `get_graph_data` 沒序列化三個欄位；`HttpSession.cpp:514, 519, 520` 三個都在，且該 commit 當時就在 |
| 0169 #1 | 宣稱 `send_packet_out` 會拋 `grpc.RpcError`；它根本不做 gRPC 呼叫，只是 `queue.put()`（unbounded，不阻塞不拋） |
| 0177 #1 | 宣稱破壞跨 repo 契約；**實際讀了六個消費端**，全部容忍新增欄位（Jackson `FAIL_ON_UNKNOWN=false`、nlohmann `at()`、`.get(k, default)`） |
| 0181 #1 | 把單次 JSON 字串轉義誤讀成雙重轉義；且回傳 JSON 字串是該檔 ~25 處的既有慣例 |
| 0191 #1 | 宣稱忽略回傳值；`topology_manager.py:641-644` 有 `if client.insert_ipv4_route(...)` |
| 0191 #2 | 前提被實測推翻（`af456ab` 的五筆 log），且所引程式碼已被 `5017614` 改寫 |

---

## 我今天寫錯的文件（需自行修正）

| # | 位置 | 錯在哪 |
|---|---|---|
| 0199 | `doc/2026-08-10_ovs_manual_test_runbook.md` §5i | 我寫「除以取樣窗長度」。**實際除的是 `hopsCounter`**（`SFlowType.hpp:339-350`）。我用算術推導出一個吻合實測的機制，但沒去讀真正的除法在哪 |
| 0200 | 同上 §5k | 我用「單流 100M 的封包率是兩倍」解釋 LLDP 未餓死。但 `s10→s8` 同向承載兩條 50M = 100 Mbps，封包率相同，**這個解釋不成立** |
| 0182 #1 | `doc/2026-08-10_p4_manual_test_runbook.md:363, 364, 433` | 引用 `TopologyAndFlowMonitor.cpp:2429` 為 `getAvgLinkUsage`；實際 `:2429` 是別的函式，真正位置 `:2441`，host 排除在 `:2468`。**寫下當時就錯了** |

順帶：0199 追下去發現一個真 bug ——
`AutoRefreshQueue::size()`（`SFlowType.hpp:134`）是 `const` 不 refresh，
`getSum()`（`:116`）會 refresh。所以 `if (size())` 用**含過期樣本**的數字遞增 `hopsCounter`（分母），
而 `getSum()` 可能已把它們清光回傳 0（分子）。**分母灌水、分子沒有**，低速率下讀數被系統性壓低。

---

## 0198 裁決（Fable 完成，2026-08-11）

| # | 判定 | 摘要 |
|---|---|---|
| 0198 #1 | **誤判** | 整數 IP「破壞契約」——實際讀了 4 個消費端 repo，全部依賴這個編碼（Web-GUI 甚至有專用 little-endian decoder `getIpString()`），改成字串才是真正的破壞 |
| 0198 #2 | 仍未修復 | `updateOpenFlowTables` 的 `installOne` 只 `push_back`，不查重複——併入 Tier 2 |
| 0198 #3 | 仍未修復 | `calFlowPathByQueried` 失敗回空 Path——**已升級為 §6i Window B 的確認機制**，見 runbook 更新 |
| 0198 #4 | 仍未修復 | `link_failure_detected` 找不到反向邊仍回 200 OK——併入 Tier 1，見下 |

0198 #1 的誤判本身值得記一筆：跨 repo 契約問題**必須實際去讀消費端**才能判斷，不能只看格式「看起來」對不對——這和 Group C 判斷 0177 #1 誤判用的是同一個方法論。

## Tier 1 追加

### 7. `/ndt/link_failure_detected` 反向邊查不到仍回 200 OK
`src/ndt_core/http/HttpSession.cpp:432-439`（來源 0198 #4）

`res` 預設建構就是 `http::status::ok`（`:119`），只有 payload 無效（400）或正向邊查不到（404）才會覆寫。反向邊單獨查不到時兩個分支都不觸發，直接落到無條件的 200 成功 body。

後果：呼叫端（含我們自己的故障注入工具）看到 200,但圖已經變成不對稱——一個方向 down、反向仍標 up，且沒有任何 log。任何緊接著查 `get_graph_data` 的人看到的是**kernel 自己都不相信的拓撲**。
