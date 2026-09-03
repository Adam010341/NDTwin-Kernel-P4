# FIX：flow 可見度的界線改用 pps 陳述（FINDING #52 的文件半邊）

分支 `docs/flow-visibility-in-pps`（自 `trunk@b57736cd` 開出）。
**只動文字，沒有行為改變，沒有編譯，沒有進 lab。**
**#52 的碼半邊是另一個工作項目，本輪不碰。**

---

## 1. 要修的是什麼

FINDINGS-ALL 第 52 條（`doc/audit/2026-09-03_night-rounds/FINDINGS-ALL.md:86`）：
**一條完全送達的 flow 會從 API 預設窗口消失，而界線的單位是 pps 不是 bit/s。**

原始資料在 `doc/audit/2026-09-03_night-rounds/round4-traffic-measurement/`：
`06_lead4_rate_sweep.log`（十個檔位的速率掃描）、`07b_sweepB_analysis.log`（鎖死頻寬只縮封包）。
量測條件：一條流、每格 30 次每秒查詢、**線上逐位元組零丟失**（iperf3 自報 `0/N (0%)`）、
1400 B frame、路徑 3 跳、sFlow 取樣 1/256。

| 送出 @1400 B | pps | 預設（無參數） | `?liveness=all` | `get_num_of_flows_passing_a_switch` |
|---|---:|---:|---:|---:|
| 20 Mbit/s | 1786 | 30/30 | 30/30 | 30/30 |
| 5 Mbit/s | 446 | 30/30 | 30/30 | 30/30 |
| 2 Mbit/s | 179 | 30/30 | 30/30 | 21/30 |
| 1 Mbit/s | 89 | 26/30 | 30/30 | 17/30 |
| 500 kbit/s | 45 | 21/30 | 30/30 | 11/30 |
| 250 kbit/s | 22 | **16/30** | 30/30 | 6/30 |
| 125 kbit/s | 11 | 12/30 | 30/30 | 4/30 |
| 60 kbit/s | 5 | 9/30 | 28/30 | 2/30 |
| 30 kbit/s | 3 | 3/30 | 13/30 | 0/30 |
| 15 kbit/s | 1 | 3/30 | 20/30 | 2/30 |

- **~89 pps** 預設窗口開始漏；**~22 pps 預設窗口跨過一半**（此時 `?liveness=all` 仍 30/30）；
  **~5 pps** 連 15 秒保留表也開始漏；**~3 pps 以下**三個窗口一起說「不在」。
- 最下兩列（3 pps／1 pps）在 `all` 欄的方向相反——那個取樣密度下 30 次查詢是 Poisson 雜訊，
  **不要讀出趨勢**。1 Mbit/s 那格跑過兩次（相隔 15 分鐘，預設 26/30 與 29/30、
  2 秒欄 17/30 與 21/30），**N=2，每個數字都是有誤差的比率，不是常數**。
- 鎖死 1 Mbit/s、payload 1400→100 B（封包數 14×），2 秒欄 **0.70→1.00**
  ⇒ 界線整體會隨 frame size 位移最多 **14 倍**。

### 三個窗口是從碼上讀的，不是從探針推的〔親自讀過〕

| 窗口 | 端點／參數 | 長度 | 出處 |
|---|---|---|---|
| 預設 | `GET /ndt/get_detected_flow_data`（無參數）＝ `ActiveOnly` | 距最後樣本 **3 s** | `HttpSession.hpp:63-64` 的 `kFlowDataApiDefault`；`FlowLinkUsageCollector.hpp` 的 `kFlowActiveWindowMs = 3000`；`classifyFlowLiveness`（`SFlowType.hpp`） |
| 全部 | `?liveness=all` | 整張保留表，**15 s** | `parseLivenessFilter`／`passesLivenessFilter`（`SFlowType.hpp`）；`FLOW_IDLE_TIMEOUT 15000`（`FlowLinkUsageCollector.hpp:35`） |
| 邊 | `POST /ndt/get_num_of_flows_passing_a_switch` | 每條邊 flow set，**2 s** | `HttpSession.cpp:2280-2296`（累加 `dstDpid == dpid` 的邊）；`TopologyAndFlowMonitor::flushEdgeFlowLoop`（`> seconds(2)` 才刪，每 1000 ms 掃一次） |

參數合法值只有三個：`active`（＝預設的顯式寫法）、`retained`（active + idle）、`all`；
**其他值回 400 不是靜默退回預設**（`readLivenessFilter`，`HttpSession.cpp:657-673`）。
🔴 **`?liveness=retained` 這一輪沒有量**——文件裡照實寫「未量測」，依定義夾在另外兩者中間。

---

## 2. 位置表：每一處、改了什麼、或為什麼不改

行號：`trunk` 那一欄是 `b57736cd`；`新` 那一欄是本分支 `ff091079` 之後。

### 2.1 改了的

| # | 檔案:行（trunk → 新） | 原句 | 改成 | 理由 |
|---|---|---|---|---|
| 1 | `doc/2026-01-02_ndt_api.md:416 → §4 新增 418-468` | 只有「⚠️ `liveness` is a statement about **observation**… At a low sFlow sampling rate a genuinely sending flow can miss it」——**沒有任何數字，也沒說哪個窗口** | 保留原段，其後新增小節〈How much traffic a flow needs before the default view sees it〉：十格表、三個窗口的長度與出處、~89／~22／~5／~3 pps 四個轉折、frame size 14× 的但書、`retained` 未量測、對照組與 raw 路徑 | **這份文件是七個兄弟元件與 kernel 之間唯一的介面**（`doc/README.md:29`）。界線要寫在讀 API 的人看得到的地方 |
| 2 | `doc/2026-01-02_ndt_api.md:2249 → 2305`（§26 描述段後） | 只說「summing the number of flows over all edges whose destination DPID equals the provided dpid」——**沒講 flow set 有 2 秒 TTL** | 加 ⚠️：這是三個視圖裡**最窄**的，2 s TTL 出自 `flushEdgeFlowLoop`；並列它自己的實測（446 pps 30/30、**179 pps 21/30**、89 pps 17/30、22 pps 6/30） | 它比預設窗口更早漏，而 179 pps 那格是**只有它在漏**的檔位——不寫，讀的人會以為三個端點一致 |
| 3 | `doc/2026-01-02_ndt_api.md:2615 → 2693`（§30） | §30 已有 B-x 的 note，**沒提低封包率盲區** | 加一句：預設母體相同 ⇒ **§4 的盲區原封不動適用於 top-k**，界線是 pps 不是 bit/s | 同一個 `kFlowDataApiDefault` 與同一個 `readLivenessFilter`〔親自讀過〕；不寫會讓人以為 top-k 免疫 |
| 4 | `doc/2026-08-10_ovs_manual_test_runbook.md:872 → 872 + 新增 874-919`（§5j） | 「**低於約 10 pkt/s 的流量會被系統性地誤判為不存在**」 | 句中「低於約 10 pkt/s」改成「封包率夠低」，其後新增〈2026-09-03 補測〉：十格表＋三窗口＋frame size＋對照組＋raw 路徑 | 原句**是 pps 沒錯，但那個 10 是從單一次 5 pkt/s 的觀察外推的、沒有掃過，也沒有分辨是哪個窗口**。實測的 50% 點在 **22 pps**，而 `?liveness=all` 要到 5 pps 才開始漏——原句把三個窗口併成一個 |
| 5 | `doc/2026-08-10_ovs_manual_test_runbook.md:1351 → 1395`（總表列） | 「✅ 5 pkt/s ICMP，取樣機率算得出來（見 §5j）」 | 追加「**2026-09-03 掃出界線：預設窗口 ~22 pps 跨過一半、`?liveness=all` 到 ~5 pps 才開始漏**」 | 總表是很多人唯一會讀的一頁 |
| 6 | `doc/2026-08-10_ovs_manual_test_runbook.md:1268 → 1312`（疑難排解列） | 「`get_detected_flow_data` 回 0 筆 \| iperf 還在跑嗎 \| **不是 ingest 壞掉——是流量停了**」 | 「先看」欄加②封包率夠嗎＋先用 `?liveness=all` 再查一次；「別誤判成」欄改為**也不必然是流量停了** | 這是**錯的診斷指引**：低封包率下「送得好好的」和「停了」在預設窗口上長得一樣 |
| 7 | `doc/2026-08-10_p4_manual_test_runbook.md:399 → 新增 401-408` | 只有「⚠️ P4 的 sFlow 是 1/256 取樣…用 `-i 0.002`（~500 pps）才能穩定產生 sample」 | 其後加補註：四個轉折點；並指出**本節的 ~500 pps 有餘裕**，但**降到 `-i 0.02`（~50 pps）就會踩進預設窗口的漏檢區** | 這是操作者實際會改的那個參數 |
| 8 | `doc/2026-08-10_p4_manual_test_runbook.md:991 → 999`（疑難排解列） | 同 #6 的 P4 版（「ping 還在跑嗎…是流量停了」） | 同 #6 | 同 #6 |
| 9 | `doc/2026-07-29_p4_status_and_test_guide.md:450 → 451` | 「**只有 iperf 這種能打滿頻寬的流量才夠**」 | 標【2026-09-03 更正】：**那個口徑是錯的單位**；同樣 1 Mbit/s，1400 B＝89 pps、100 B＝1250 pps；**打滿頻寬不是條件，~幾百 pps 才是**——`ping -i 0.002` 就夠，不必 iperf | 這份文件 `doc/README.md:55` 標「歷史」，但這句是**明確用頻寬陳述可見度門檻**的原型，而且它會教人做錯的事（以為非 iperf 不可）。**改成加註而不是改寫原句**，歷史狀態不變 |
| 10 | `doc/2026-07-30_full_test_runbook.md:324 → 324-334` | 「⚠️ `get_detected_flow_data` **偶發 FAIL 有兩個原因，都不是 bug**：1. 流量停了 2. ~~多播~~」 | 標題句撤掉「兩個原因，都不是 bug」，新增第 3 條：**封包率太低，而這一條是 bug**（~89／~22 pps），並教人加 `?liveness=all` 重查分辨 | 「都不是 bug」現在是錯的。此文 `doc/README.md:54` 標「歷史」，同樣**只加註不改寫**其餘內容 |
| 11 | `doc/KNOWN-ISSUES.md:1429 前新增 1429-1465` | §B-x 只有「端點包含**已經結束**的流」那個方向 | 新增小節〈B-x 的反向〉，狀態 🔴 **OPEN**、失效方向**悲觀**（但對「用不存在判斷閒置」的消費端是**樂觀**）；六列表＋三窗口＋frame size＋**與 §A-4 的消歧**＋對照組 | KNOWN-ISSUES 是常設清單。**碼沒修 ⇒ 條目要開著**；小節明寫「本次只改文件口徑，修法是另一個工作項目」 |
| 12 | `include/ndt_core/collection/FlowLinkUsageCollector.hpp:75 → 77 後新增` | `kFlowActiveWindowMs` 的註解只寫「⚠️ Under a low sampling rate a genuinely sending flow can miss that window」——**代價沒有數字** | 加一段：**IT IS A PACKET RATE, NOT A BIT RATE**，30/30@179、26/30@89、16/30@22 pps，`all` 到 ~5 pps 才漏，frame 1400→100 B 讓 2 秒欄 0.70→1.00，raw 路徑；並明寫**不因此改值**（放寬窗口＝把 B-x 剛移掉的 idle 尾巴放回來） | 定義這個常數的地方就該寫它的代價。**純註解，值沒動** |
| 13 | `include/ndt_core/http/HttpSession.hpp:212 → 214 後新增` | `handleGetDetectedFlowData` 的 `@note` 只寫「Intended for clients such as a dashboard/GUI to query live flow visibility」 | 加 `@note`：**預設視圖的缺席不是流停了的證據**，界線是封包率；26/30@89、16/30@22 pps 而 `?liveness=all` 兩格都 30/30；要據此判斷閒置的呼叫端請讀 `?liveness=all` ＋ `last_seen_ms` | 這是 API 欄位／handler 的說明文字，寫給 GUI 與兄弟元件看的。**純註解** |
| 14 | `include/ndt_core/http/HttpSession.hpp:740 → 752 後新增` | `handleGetNumOfFlowsPassingASwitch` 的 `@note` 只講重複計數，**沒提 flow set 有 TTL** | 加 `@note`：2 s TTL 出自 `flushEdgeFlowLoop`，是三個視圖裡最窄的；30/30@446、**21/30@179**、17/30@89、6/30@22、0/30@3 pps | 同 #2。**純註解** |

### 2.2 刻意不改的

| # | 檔案:行 | 句子 | 為什麼不改 |
|---|---|---|---|
| A | `doc/KNOWN-ISSUES.md:1475`／`1707-1720`（**F-9**） | 「鏈路使用量量化到取樣粒度（1/256 × frame length × 8），所以**低於約 3 Mbit/s** 的鏈路讀成一個量子的整數倍」 | **量的不是同一件事**：F-9 是**鏈路使用率的解析度**，本輪是**flow 存在與否**。而且它已經把門檻寫成 `1/256 × frame length × 8` ——**本身就是 frame-size 導出的**，不是一個裸的 Mbit 常數。把 pps 硬塞進去只會讓兩個不同的缺陷看起來是同一個 |
| B | `doc/2026-08-10_ovs_manual_test_runbook.md:831`／`833`（§5i） | 「`estimated_flow_sending_rate_bps_in_the_last_sec` 在**低於約 10 Mbps 的 flow** 上單次讀數可能有數倍誤差」／「3.01 Mbps 是 1470-byte datagram 算出來的…**不要把 3 Mbps 當成通用常數**，它是 `取樣率 × 封包大小 × 8`」 | §5i 講的是**速率讀數準不準**，不是**存在與否**；而且第二句**已經明講它隨封包大小變動**。緊接在它下面的 §5j（＝本輪 #4）已經帶進 pps 的界線，兩節相鄰、指向清楚 |
| C | `doc/KNOWN-ISSUES.md:275`（**A-4**） | 「實測 **50.00 Mbps** 負載下，`get_detected_flow_data` 回 `[]`」 | **機制不同**：那是 `ovs_4host_topo.py` 完全沒設 sFlow（零參照），而 50 Mbps @1400 B ≈ **4460 pps**，遠在本輪界線之上，不可能是取樣不足。**不改 A-4 本身**，改在新小節裡加一行消歧（見 #11），免得日後有人把兩者互相引用 |
| D | `include/common_types/SFlowType.hpp:394` | `MICE_FLOW_UNDER_THRESHOLD`（**10 Mbps**） | 那是一個**真的以 bit/s 設定的常數**（大象／老鼠分類），不是可見度門檻。把它的註解改成 pps 會**誤述碼在做什麼** |
| E | `tools/test_workflow/ndt:1989` | 「`-- under 1 Mbit/s crossing the fabric; the ratio is not meaningful yet.`」 | 那是 twin 積分 bit/s 對 `/proc/net/dev` bit/s 的**比值**守衛，兩邊同單位，bit/s 就是對的單位 |
| F | `doc/2026-08-15_bmv2-performance-*`／`2026-08-28_bmv2-throughput-*`／delivery package | 一整批 Mbps 天花板數字 | 那是 **bmv2 轉發容量**不是 flow 可見度，而且那批文件**已經自己寫著「天花板是 pps 不是 bps」**（`2026-08-15_bmv2-performance-report.md:75`） |
| G | `doc/audit/**` 底下所有相關敘述 | — | **audit 是紀錄不是文件**，依指示不動。#52 的原始 log 與 FINDINGS 保持原樣 |

---

## 3. 測試

**沒有任何測試釘住被我改掉的字句。** 逐句 grep 過 `tests/`、`p4_proxy/tests/`、`tools/`：

```
只有 iperf / 低於約 10 pkt/s / 是流量停了 / liveness is a statement about /
query live flow visibility / no global deduplication / reason to exist is catching faults /
would rather over-report
```

八個字串在那三棵樹裡**都是零命中**。另外查過**沒有任何測試在執行期讀取這些文件**：
`tools/contract_test/selftest_fixtures.py` 是**手抄**的 JSON 範例（檔頭自述 “copied from”），
不是即時解析 markdown；`run_contract_test.py --self-test` 驗的是那份 fixtures 不是文件本體。
`tests/python/test_l3_dispatch_drift.py`、`test_contract_spec.py` 比對的是端點清單與 schema，
與本輪動到的散文無關。

⇒ **沒有 red→green 可秀，因為沒有東西變紅過。**
本輪沒有新增測試：改的全是散文與註解，**加一個釘住散文的測試只會製造一個假的閘門**
（下一個修字的人被它擋住，而它並沒有保護任何行為）。
**碼半邊要修的時候，紅綠與變異閘由那個工作項目負責。**

---

## 4. 我**沒有**做的事

1. 🔴 **#52 的碼半邊完全沒碰。** 預設窗口仍是 3000 ms、flow set TTL 仍是 2 s、
   `kFlowDataApiDefault` 仍是 `ActiveOnly`。**沒有任何行為改變。**
   要不要改（例如預設改成 `retained`、或在紀錄裡加一個「這是取樣稀疏」的旗標）
   **是另一個工作項目，也需要 Adam 裁**——因為放寬窗口等於把 B-x 剛移掉的 idle 尾巴放一部分回來。
2. **沒有編譯、沒有跑測試、沒有進 lab。** 兩個 header 只動註解，但**本輪不宣稱它們仍然編得過**
   （純註解、無 `/* */` 巢狀、無 `\` 續行；讀過但沒編）。
3. **`?liveness=retained` 沒有量。** 文件三處都照實寫「未量測」，只寫依定義的夾擠關係。
   要補就是再跑一輪同樣的十格。
4. **沒有跨平面驗證。** round 4 的數字是**那一組 fabric、3 跳、1/256** 量到的。
   跳數與取樣率一變，`samples/s = pps × hops / 256` 整條線就位移——文件裡每一處都帶著這三個條件。
5. **沒有動 `doc/audit/` 的任何既有內容**（#52 的原始 log、FINDINGS-ALL、round4 的 SUMMARY 都原樣）。
6. **沒有 push。**
7. **順手看到、但不在本輪範圍的**：`doc/2026-08-10_p4_manual_test_runbook.md:533` 引用
   `TopologyAndFlowMonitor.cpp:2680-2692` 說 flow_set 由 flush loop 老化——**那個行號已經漂到
   `:4005-4045` 左右**。是行號腐爛不是內容錯，**沒有改**（不是 bit/s 口徑問題，且會和別的分支撞行）。

---

## 5. 合併檢查

```
$ git merge-tree --write-tree trunk docs/flow-visibility-in-pps
570b9f0b548e507542f3f96f552acc0977ed12e6
RC=0
```

對 `trunk@92a79392`（我開分支之後 trunk 有前進，這是**對前進後的 trunk** 跑的）。
**rc 0、沒有任何 conflict 輸出 ⇒ 乾淨可併。**

⚠️ 上面那顆 tree 是**跑在兩顆內容 commit（到 `ff091079`）上的**，不含本文件——
本文件是自我指涉的，把它自己的 sha 寫進自己裡面每存一次就會作廢一次。
**本文件只新增 `doc/audit/2026-09-03_fix-flow-visibility-units/` 這個 trunk 上不存在的目錄**，
不可能改變合併結果；含本文件的完整分支也**當場重跑過一次，同樣 rc 0、無 conflict**
（tree sha 隨本檔內容而變，故不寫死在這裡——要對就自己重跑一次上面那行）。

分支：`docs/flow-visibility-in-pps`
- `e0857524` — 主要那一輪（API 文件 §4／§26／§30、KNOWN-ISSUES 新小節、
  OVS runbook §5j＋總表、P4 runbook §5a、P4 status guide、兩個 header）
- `ff091079` — 第二輪補漏（OVS runbook 的疑難排解列、`2026-07-30_full_test_runbook.md` 的
  「兩個原因，都不是 bug」）
- 本文件另計一顆（sha 見 `git log`）。

[Co-developed with claude code -- Adam]
