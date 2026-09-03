# 每條流的速率沒有分母 —— 工單 Q 的另一半

**寫於 2026-09-02 深夜～09-03 凌晨。碼與行號錨在 `72fdc5b0`（trunk）。**
本輪**沒有動實驗室、沒有起 fabric、沒有量任何新數字**——量測輪整晚佔著 lab，本文引用的週期
數字全部是這個 repo 既有的紀錄。所有結論分成〔讀碼〕（我親自打開那幾行讀過）與〔既有紀錄〕
（引用檔案裡已經存在的數字，附路徑）兩級，不混用。

[Co-developed with claude code -- Adam]

---

## 0. 一句話

**假設成立。** 每條流的 `..._in_the_proceeding_1sec_timeslot` 是「**一個迴圈週期內的位元數**」，
掛著「**每秒位元數**」的名字送出去。高估倍數＝迴圈週期 T（秒），**單向偏樂觀、且隨流數成長**。
排序不受影響（同一輪所有流共用同一個 T），**大象流門檻一定錯**。

---

## 1. 查證：從計數器到 JSON 逐段讀完

### 1.1 缺陷的兩行

`src/ndt_core/collection/FlowLinkUsageCollector.cpp`，`calAvgFlowSendingRatesPeriodically` 內：

```
:1934-1936   stats.avgByteRateInBps =
                 sflow::counterDelta(byte_count_current, byte_count_previous) * 8 *
                 currentSamplingRate;
:1952-1954   stats.avgPacketRate =
                 sflow::counterDelta(packetCountCurrent, packetCountPrevious) *
                 currentSamplingRate;
```
〔讀碼〕行號錨在 `72fdc5b0`，與最初提出假設的分析（`6283ff5e`）相同，這段期間沒有人動過它。

### 1.2 分子確實是「一個週期內的量」

- `ingressByteCountCurrent` / `egressByteCountCurrent` 在 `handlePacket` 內以 `+=` 逐包累加
  （`:1523-1529`；新流路徑 `:1550-1560` 是 `=`，那是流建立的第一包）。
- `...Previous` 只在**這個迴圈的尾巴**被覆寫（`:1969-1972`，`Previous = Current`）。
- ⇒ `counterDelta(current, previous)` ＝**上一輪速率迴圈到這一輪之間**被取樣到的位元組。
  它是一段區間的量，不是一個瞬時率。〔讀碼〕

### 1.3 取樣率乘數不是時間

`currentSamplingRate` 是 sFlow 的 1/N 除數。乘上它是把「取樣到的位元組」放大成「線上估計的
位元組」——**一個計數的縮放，與時間無關**。〔讀碼〕

### 1.4 上下游都沒有除以時間

- 上游：沒有。計數器是裸累加。
- 下游：`sflow::computeEstimatedRates`（`include/common_types/SFlowType.hpp`）只做
  `accumulated / hops`——**除以跳數，不是除以秒數**。
- 發布：`getFlowInfoJson` `:2454` / `:2458` 原封不動塞進
  `estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot` 與
  `estimated_packet_rate_in_the_proceeding_1sec_timeslot`。
- 消費：`getTopKFlowInfoJson` 的 `std::sort` 比較鍵就是後者（`:2527-2531`）；
  `:2020` 拿前者比 `MICE_FLOW_UNDER_THRESHOLD`（`TopologyAndFlowMonitor.hpp:30` ＝ 10 Mbps）。
〔讀碼〕

**⇒ 路徑上任何一處都沒有除以經過時間。分析員沒有看漏。**

### 1.5 沒有被波及的那一半（重要，不要一起改）

`_in_the_last_sec` 兩欄（`calAvgFlowSendingRatesImmediately`）**是對的**：它加總的是
`AutoRefreshQueue`，那個佇列在每次 `push`／`getSum` 都會把超過 `TIME_UNIT_INTERVAL = 1000 ms`
的樣本丟掉（`SFlowType.hpp` 的 `refresh()`）。**它的分母是視窗本身，寫死在資料結構裡**，
不隨迴圈週期漂移。〔讀碼〕
⇒ 引用過 `_in_the_last_sec` 的結論**不受本次修改影響**。

---

## 2. 工單 Q 為什麼漏掉它（對帳義務，不是加分項）

`doc/audit/2026-08-27_hardcoded-denominator/PREREG.md`：

- §Q-0 把標的寫成「`累加器 * 8` 直接當 bps，路徑上沒有任何一處除以實際經過時間」——
  **這句話一字不改地適用於流那條路**。
- §Q-ter 自己修正過一次範圍：「我的 Q-0 只點名了一處，實際上有兩處」，並附上找法：
  `grep -n "MultiplySampingRate" FlowLinkUsageCollector.cpp`。
- **兩處都是連結累加器。** 流那條路的計數器叫 `ingressByteCountCurrent`／
  `egresspacketCountCurrent`，**不含那個字串**，所以那次 grep 看不到它。
- `f5e35561` 的交付說明寫得很清楚：改簽章是為了「讓漏掉的**呼叫端**變成編譯錯誤」。
  🔴 **那保護的是名單上那條路的呼叫端，不是名單本身的完整性。** 這次漏的正是名單。

⇒ 這不是一個孤立 bug，是**預註冊的修法只做了一半而沒有人記錄**。
（PREREG 的延後紀錄由持有 Q 脈絡的另一條線負責，本輪**不動**
`doc/audit/2026-08-27_hardcoded-denominator/` 底下任何檔案。）

---

## 3. 量化：這個數字今天到底是什麼意思

### 3.1 兩種錯，後果不同

| | 是哪一種 | 後果 |
|---|---|---|
| **單位錯** | ✅ 是。發布值＝「**每個迴圈週期**的位元數」，標籤寫 bps | 整批數字要乘一個常數才能讀 |
| **倍數隨負載變** | ✅ 也是。倍數＝T，而 T 隨流數與機器忙碌程度成長 | **不同時刻的兩個讀數彼此也不可比**，且無法事後校正——除非同時知道當下的 T，而 T 只在 `kernel.log` 每 30 輪的 INFO 行裡 |

`發布值 = 真值 × T`，T ＝速率迴圈週期（秒）。**T > 1 恆成立**（`sleep_for(1s)` 在本體之前），
所以偏差**單向偏高**。

### 3.2 用既有紀錄的 T 換算（本輪沒有量新的）

| 負載 | T | 高估 | 出處〔既有紀錄〕 |
|---|---|---|---|
| 安靜臂（1 流量級） | 1.0439 s | **+4.4 %** | PREREG §Q-0「安靜 1043.9 ms」（工單①，n=3、SD 3.4 ms） |
| 16 流 | 1.033–1.040 s | +3.3 – 4.0 % | 協調者轉述之工單 P 量測 |
| 64 流（現行 fabric） | 1.032–1.061 s | +3.2 – 6.1 % | 同上 |
| 64 流（第一代 fabric，08-25） | **1.2487 s** | **+24.9 %** | `FlowLinkUsageCollector.hpp` 中 `kFlowActiveWindowMs` 的理由段：「windowed mean 1248.7 ms」 |

⚠️ **1 流沒有獨立紀錄**。表中「安靜臂」是最接近的既有數字，對 1 流而言是**上界**。
不要把 +4.4 % 當成 1 流的實測值。

### 3.3 排序 vs 門檻 —— 「數字錯」與「決策錯」的分界

**排序不受影響。** `runFlowRatePass` 量**一個**區間，交給同一輪走訪裡的**每一條流**；
修法前也是同一個 `for` 迴圈、同一個快照時刻，所以每條流的膨脹倍數相同。
乘一個共同正常數是單調變換 ⇒ `std::sort`（`:2527-2531`）的次序不變。
⇒ **top-k 的「誰排前面」從來沒有錯過；錯的是那一欄印出來的值。**
（測試 `FlowRateDenominator.OneDivisorForEveryFlowSoTheOrderSurvives` 把這件事釘住，
未來若有人改成「每條流各自的分母」，那會是一次靜默的重新排序，這個測試會先紅。）

**門檻一定錯。** `MICE_FLOW_UNDER_THRESHOLD` 是**絕對值** 10 Mbps。倍數 > 1 且單向
⇒ 只會**多標**大象流、不會漏標。被誤標的區間是真實速率落在 `10/T` 與 `10` Mbps 之間者：

- T = 1.0439 ⇒ **9.58 – 10.0 Mbps** 的流被誤標；
- T = 1.2487 ⇒ **8.01 – 10.0 Mbps** 的流被誤標。

任何 TE 消費者就是吃這個旗標的。

### 3.4 兩個沒有查證、**不要當成已排除**的邊角

1. `m_flowInfoTable` 是 `unordered_map`。一條流真正的差分視窗是「上一輪走到它」到
   「這一輪走到它」，而 rehash（插入／清除）會改變走訪次序 ⇒ **churn 下，兩條真值相近的流
   可能瞬態換位**。這是二階效應，我沒有量。
2. 一條流的**第一個區間**：`Previous` 初值為 0，第一次差分跨的不是一個完整週期
   ⇒ 該流第一筆讀數被**低估**。修法前後都存在，不是本次引入的。

---

## 4. 有沒有第三條路也在做同樣的事（找法可重跑）

🔴 Q 這次漏掉，正是因為名單是**單一字串** grep 生出來的。所以這次用**語意**去找，
兩道 grep，任何人都可以重跑：

```bash
# P1：所有乘上取樣率的地方（不論成員叫什麼名字）
grep -rnE '\*[^;]*[sS]amplingRate|[sS]amplingRate[^;]*\*|samplingScale|SampingRate' \
     src include --include=*.cpp --include=*.hpp

# P2：所有寫入「名字自稱是速率／bps／頻寬用量」的欄位的地方
grep -rnE '\b[A-Za-z_.>]*([Rr]ate|[Bb]ps|Bandwidth(Usage|Utilization))[A-Za-z_]*\s*=[^=]' \
     src include --include=*.cpp --include=*.hpp
```

兩道交集後，全 repo 產生速率的地方**只有四處**：

| # | 位置 | 分母是什麼 | 狀態 |
|---|---|---|---|
| 1 | `sflow::updateFlowRatesForInterval`（每條流，Periodically） | 量到的 drain-to-drain 區間 | **本次修好** |
| 2 | `updateLinkInfoLeftLinkBandwidth`（連結，MININET） | `drainElapsedSeconds` | 已修（`f5e35561`） |
| 3 | `calAvgFlowSendingRatesImmediately`（每條流，_in_the_last_sec） | `AutoRefreshQueue` 的 1000 ms 滑動視窗 | 結構上正確 |
| 4 | `updateLinkInfo`（連結，TESTBED 計數器路徑） | `(now_ms - last_ms) / 1000`，**整數截斷** | 🟠 **有分母但被截斷**，另案 |

**⇒ 沒有第四條「完全沒有分母」的路。** 第 4 項的整數截斷是既有清單上的另一個缺陷
（TESTBED 目前是停用硬體，可達性低），**本輪不碰**，在此登記以免下次又靠 grep 漏掉。

---

## 5. 修法

比照 `f5e35561` 在連結那條路的做法。

**分成兩塊，因為只有這樣測得到。**

1. **算術＋守衛**：`include/common_types/SFlowType.hpp` 新增
   `sflow::updateFlowRatesForInterval(FlowInfo&, double elapsedSeconds, uint64_t elephantThresholdBps)`。
   純函式，每個輸入都是參數 ⇒ 測試可以指定它要的那個區間。
   （這個「抽出來才測得到」的理由不是我發明的：同檔的
   `FlowLinkUsageCollector::classifyTelemetry` 的註解已經寫過一次同樣的話。）
2. **接線**：`FlowLinkUsageCollector::runFlowRatePass()` 量區間、拿到鎖、走訪、記下用掉的除數。
   主迴圈只剩一行 `runFlowRatePass();`。

**與連結那條路對齊的四件事**

| | 連結路（`f5e35561`） | 流路（本次） |
|---|---|---|
| 時鐘 | `std::chrono::steady_clock` | 同 |
| 區間 | drain-to-drain，自己的錨 | drain-to-drain，**自己的另一個錨** `m_lastFlowDrainAt` |
| 非正數間隔 | 拒發、記 ERROR、保留前值 | 同 |
| 首次取樣 | 錨在迴圈前設定，第一個區間是真的區間 | 錨在**建構時**設定；計數器也是那時起算，所以兩者一致 |
| 活的閘門 | `lastRateDivisorSeconds()` ＋ `rate divisor check` INFO | `lastFlowRateDivisorSeconds()`，印進同一行 |

🔴 **兩個錨必須分開**，不能共用連結路的 `lastDrainAt`：流的計數器在迴圈**上半**被快照，
連結的累加器在**下半**被清零，兩段區間差一個走訪的時間。`f5e35561` 自己的 commit message
就警告過這個陷阱（「兩個區間平均值相同，所以用錯的那個能通過肉眼檢查、然後在 1% 閘門失敗」）。

**一處刻意的差異**：非正數間隔時，流路**不推進錨**，位元組留著下一輪一起付。
連結路的呼叫端是無條件把累加器清零的（那些位元組會掉），我沒有把那個瑕疵一起搬過來。

**兩處必須講明的副作用**（不要讓它們無聲）：
1. **少了一行 per-hop TRACE。** 原本走訪裡有一行印出每一跳的 agent IP 與該跳的 ingress／
   egress 計數器。算術搬進 `common_types` 的純函式之後那裡沒有 logger，硬要加會讓型別標頭
   依賴 logger。改成 caller 每條流印一行（含用掉的區間），**per-hop 的細節目前只能從
   `getFlowInfoTable()` 取**。這是 TRACE（預設關閉）等級的損失，但它是損失。
2. **`!hasActiveHops` 的清零註解被搬到純函式裡**，連同它引用的 20.3 Mbps / 10496 pps 出處。
   那段歷史有別的文件在引用 `FlowLinkUsageCollector.cpp` 的行號，所以**整段保留、沒有刪**，
   並在旁邊補了一句：那兩個數字本身就是從這個沒有分母的欄位讀出來的（見 §7.1 T2）。

**順手修掉一段會騙人的註解**：主迴圈開頭那句
「once the accumulator is divided by the measured interval … this line must read ~1000 ms forever」
是**寫下來的當天就不成立**的，而 PREREG §Qb-1 已經記載它騙過一位審查員、害他寫出一條
「正確的修法會失敗」的閘門。刪掉並寫明為什麼。

**本輪未處理（範圍由協調者裁定）**
- PREREG §Q-1 的 **(B) 半**（`sleep_until` 讓穩態週期真的等於 1 秒）：今晚不做。它要重編，
  而重編會換掉四輪測試正在量的那顆 binary。**(A) 補上之後，(B) 沒做只影響週期長短，不再
  影響正確性**——這正是 Q-1 當初主張兩者都做的理由（(B) 單獨做很脆弱，(A) 單獨做是對的）。
- 封包分子與跳數分母母體不一致（`avgPacketSendingRateTemp` 無條件累加，`hopsCounter++` 只在
  位元組率非零時）：另案，本次刻意保持原行為，否則封包率會因為與分母無關的理由變動，
  歸屬就說不清楚。
- 第 4 節表中第 4 項（TESTBED 整數截斷）。

---

## 6. 變異閘（mutation gate）

腳本：`tests/shell/mutate_flow_rate_denominator.sh`，測試：`tests/test_RateDenominator.cpp`
的 `FlowRateDenominator` 套件（10 個測試）。

🔴 **建置目錄是 `build-flowrate/`，不是共用的 `build/`。** 今晚已經有一顆被記錄在案的
`build/bin/ndtwin_kernel` 在量測途中被別人重建而永久遺失；這個閘門每個變異要重編約 60 個
物件檔，絕不能在別人的 kernel 連結出處的樹裡做。建置一律走共用鎖與 `-j2` shim。

**判準**（沿用連結那把閘門的定義）：只有**指名的那個測試**紅掉才算 KILLED。
沒有東西紅、紅錯測試、變異體編不過、錨點不見——**四者都算 SURVIVOR**。

### 結果（2026-09-03 00:23–00:52，`build-flowrate/`）

```
=== baseline: the unmutated tree must be green ===
  ✅ green -- [  PASSED  ] 17 tests.

F1. drop the division on the BIT rate (restores the shipped defect)   include/common_types/SFlowType.hpp
    ✅ red: AnElephantIsDecidedOnTheDividedRate
            ARealisticLoopPeriodOverstatesTheFlowRateByThatPeriod
            FlowSameBytesOverTwoSecondsIsHalfTheRate            ✅ KILLED
F2. drop the division on the PACKET rate                              include/common_types/SFlowType.hpp
    ✅ red: FlowPacketRateIsPerSecondToo                        ✅ KILLED
F3. accept a zero interval (> becomes >=)                             include/common_types/SFlowType.hpp
    ✅ red: ZeroIntervalLeavesTheFlowAlone                      ✅ KILLED
F4. the loop assumes a 1 s period instead of measuring it (WIRING)     src/.../FlowLinkUsageCollector.cpp
    ✅ red: TheFlowDivisorIsMeasuredNotAssumed                  ✅ KILLED
F5. the flow divisor sentinel -1.0 becomes 0.0                        include/.../FlowLinkUsageCollector.hpp
    ✅ red: TheFlowDivisorStartsAtASentinelNotZero              ✅ KILLED

--- after restore: the suite must be green again ---   [  PASSED  ] 17 tests.
--- verdict ---   5 mutations, 0 survived
```

**「先看過紅」是怎麼被滿足的。** 🔴 **F1 不是一個抽象的突變，它把原始碼還原成 kernel 真正
出貨的那個運算式**（`delta * 8 * samplingRate`，沒有除法）。指名的測試對著它紅，就是
「對著未修的碼看過它失敗」——而且這個觀察**可重跑**，不是一次性的手動確認。
F1 同時弄紅了另外兩個測試（週期換算與大象流），那是預期的：它們的前提都是那道除法。
判準是**指名的那一個有紅**，不是「有東西紅了」。

**F4 是這一輪最重要的一格。** 其他四格都只證明算術對；只有它證明**主迴圈真的把量到的區間
交下去**。把 `flowElapsedSeconds` 改成常數 `1.0`（＝f5e35561 之後、今晚之前流那條路的實際
狀態）之後，**除了 `TheFlowDivisorIsMeasuredNotAssumed` 以外每一個測試都還是綠的**。
一套只測算術的測試會給這個錯誤發綠燈。

**兩件關於這次執行的誠實紀錄**：
- 前兩次啟動被我自己中止（一次是為了補回被刪的 A-3 註解，一次是因為
  `AnElephantIsDecidedOnTheDividedRate` 原本的常數選得太小、根本沒有出現過一次誤標）。
  **上表是第三次、也是唯一一次完整跑完的執行**，對應的就是本次提交的原始碼。
- 本輪與另一個 agent 的 `mutate_b5_power_manager_shutdown.sh` 同時在**同一棵工作樹**上做突變，
  兩邊靠同一把 `flock` 串行化。兩者觸碰的檔案沒有交集（power management vs collection），
  基準線與最終還原都是綠的。但這是共用工作樹跑變異閘固有的風險，**記在這裡而不是假裝沒有**。

---

## 7. 對帳：這推翻或更新了哪些既有結論

**我依據的清單有兩份**，本節同時交代來源，因為「誰讀過這個欄位」的完整性正是本案的教訓：

- **清單 A**：本 session 派出的 subagent 對 `doc/`、`tools/`、`tests/python/` 的全面掃描
  （排除 `.claude/worktrees/` 與 `build/`）。找法：四個 JSON 欄位全名、四個 C++ 成員名、
  `isElephantFlowPeriodically`、`MICE_FLOW_UNDER_THRESHOLD`，加上鬆散樣式
  `proceeding_1sec`／`Periodically`／`elephant`／`top_k`／`Mbps`／`pps`；並實讀
  `make_figs.py`、`make_survey_figs.py`、`run_flowcount_arm.sh`、`analyse_p1_3.py`、
  `sample_topk_rank.py`。⚠️ 這一份是**轉述**（我沒有親自打開那些產圖腳本），
  §7.2 的 bmv2 結論就掛在它身上。
- **清單 B**：持有工單 Q 脈絡的那條線做的消費者盤點，由協調者轉述（Tier 1 ＝
  `doc/audit/2026-08-27_flow-table-idle-tail/` 與 KNOWN-ISSUES 引用該輪數字之處）。
  我沒有自己重掃它。
- **§7.1 三筆的引用行我全部親自打開讀過**（T1／T2／T3 皆為〔親自讀過〕），
  因為那三筆是合併裁決的依據，不能建立在轉述上。

### 7.1 受影響、需要回頭重看的宣稱（值相關）

| # | 位置 | 那個數字 | 為什麼受影響 |
|---|---|---|---|
| **T1** | `doc/audit/2026-08-16_concurrent-flow-reconciliation.md:73` | **`..._proceeding_1sec_timeslot` 積分 ＝ 4.49 GB ＝ 3.46×**（對照 offered 1.299 GB） | 這是全 repo 唯一一次把這個欄位**對時間積分**成一個物理量。該行自己把 3.46× 歸因於「無樣本秒數保留前值」（hold-last，**後來已修**），🔴 **少了分母 T 這個第二個貢獻者**。積分本身要重算，歸因句要重寫 |
| **T2** | `doc/audit/2026-08-27_flow-table-idle-tail/`（W 輪）＋ KNOWN-ISSUES A-3 引用該輪之處 | **20.3 Mbps / 10496 pps** | 這兩個絕對值來自受影響的欄位，**不再有效**。但該輪的**載重宣稱**是「iperf3 結束後 5 秒與 10 秒仍回報**逐位元相同**的值」——那是「重複」不是「量值」，**通過均勻縮放後依然成立** ⇒ **結論站得住，兩個數字要撤** |
| **T3** | `doc/audit/2026-09-02_manual-usertest/run-01-sonnet/tester-files/CHECKLIST.md:61`、`JOURNAL.md:389` | **~40 Mbps、~3300 pps**「落在手冊預測的 stock/debug BMv2 區間」 | 讀自 `get_detected_flow_data`，但該次執行**沒有留 raw JSON**（整個 run 目錄 grep `estimated_` 零命中）⇒ **無法回推是哪一個視窗**。列為 at-risk，不可據以確認任何天花板 |

### 7.2 明確**不**受影響（不要順手一起撤）

- **bmv2 效能研究全部八張圖**（`doc/2026-08-29_bmv2-performance-study-figs/`）：
  資料源是 iperf3 的 `sum_sent`／`sum_received`／`lost_percent` 與
  `/proc/net/dev`，四個相關 audit 目錄對 `estimated_*`／`/ndt/` 的引用數為零
  （少數命中是 `waiting for kernel API on :8000` 的啟動日誌）。
  `fig2_perflow_monotone` 的 y 軸是**產生器的 ladder 檔位**，不是 kernel 的讀數。
- **所有連結平面的數字**（`link_bandwidth_usage_bps` 等）：另一條路，已有分母。
- **`_in_the_last_sec` 兩欄**：見 §1.5。
- **只談排序的宣稱**（top-k 降冪、誰排在誰前面）：見 §3.3，均勻縮放不改次序。
- **只談 schema／contract 的宣稱**（欄位存在、型別、`Num(min=0)`）：值無關。

### 7.3 合併判準

**有既存結果依賴這些數字（T1／T2／T3）⇒ 走分支 `fix/flow-rate-denominator`，不進 trunk。**
本文與碼一起放在該分支上。要合併之前，T1 的積分需重算、T2 的兩個絕對值需撤回或重取、
T3 需要一次留 raw 的重測（或標記為永久不可回溯）。

---

## 8. 本節不宣稱

- 不宣稱高估已經在**實機**消失——本輪一行 live 都沒跑，lab 整晚被量測輪佔著。
  修法的證據是單元測試與變異閘，不是 fabric 上的讀數。
- 不宣稱 §3.2 那張表是「1／8／64 流的實測誤差」——那是**把既有的週期紀錄代進
  `發布值 = 真值 × T`** 得到的換算，8 流沒有紀錄、1 流只有上界。
- 不宣稱 §3.4 的兩個邊角已排除。
- 不宣稱 top-k 的既有結論全部安全——只宣稱**次序**類的結論安全（§3.3），值類的見 §7.1。
- 不宣稱這修好了 `doc/audit/2026-08-16_concurrent-flow-reconciliation.md` 的 3.46×：
  那裡至少有兩個機制（hold-last 與分母），本輪只動了一個。

[Co-developed with claude code -- Adam]
