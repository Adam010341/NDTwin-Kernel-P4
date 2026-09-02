# B-x — `/ndt/get_detected_flow_data` 回傳已經結束的流

工作目錄：`/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-aeac636943db8b2a8`
分支：`fix/bx-flow-liveness`（未 push）

---

## 1. Base 驗證

worktree 開出來時是 `f5db629b update sleeping time`（origin/main，落後且**沒有** `tests/`），
已依 brief 第 0 節 detach：

```
$ git checkout --detach 4cbec52d45bd85e0e972110e35f51693d6ce137f
HEAD is now at 4cbec52d Keep the one line that names the restore failure
$ git log --oneline -1
4cbec52d Keep the one line that names the restore failure
$ sed -n '776p' doc/KNOWN-ISSUES.md
## B-x. `/ndt/get_detected_flow_data` 包含已經結束的流（churn 下約 92%）
```

兩項檢查皆通過（`ls tests/` 亦確認 `test_FlowStatsTimeout.cpp` 等存在）。

---

## 2. 機制（附 file:line）

### 2.1 流怎麼進來

`src/ndt_core/collection/FlowLinkUsageCollector.cpp`

| 位置 | 動作 |
|---|---|
| `:1486` | `unique_lock flowTableLock(m_flowInfoTableMutex)` |
| `:1488-1489` | `m_flowInfoTable.find(key)` |
| `:1520` | **既有流**：`info.endTime = utils::getCurrentTimeMillisSystemClock();` |
| `:1524` | **新流**：`auto& info = m_flowInfoTable[key];`（`operator[]` 直接插入） |
| `:1526-1527` | `info.startTime = info.endTime = getCurrentTimeMillisSystemClock();` |

⇒ **只要有一個 sFlow 樣本被抽到，就進表**；`endTime` 是「最後一次被抽到的牆鐘時刻」。

### 2.2 什麼會把它拿掉 — 只有一個地方

`purgeIdleFlows()`（`:2229-2280`），`m_purgeThread` 由 `:511` 起。

```
:2237  shared_lock lock(m_flowInfoTableMutex);
:2238  int64_t now = utils::getCurrentTimeMillisSystemClock();
:2242  if (now <= info.endTime) { continue; }      ← 時鐘倒退就永遠跳過（另一張工單）
:2246  int64_t idle_time = now - info.endTime;
:2247  if (idle_time >= FLOW_IDLE_TIMEOUT) { toRemove.push_back(flowKey); }
:2272-2273  unique_lock → m_flowInfoTable.erase(key);
:2276  sleep_for(1000ms)                            ← 所以實際清除落在 15–16 s
```

`FLOW_IDLE_TIMEOUT = 15000`：`include/ndt_core/collection/FlowLinkUsageCollector.hpp:35`
（📌 memory 檔舊記 `:34`，已在 08-29 更正過，本輪重讀確認是 **35**）。

🔴 **沒有 FLOW_REMOVED 那條路**。清除完全不依賴交換機端事件，純粹是 kernel 自己的 1 Hz timer。
所以「P4 模式收不到 FLOW_REMOVED」不是成因——成因就是「**15 秒之內不清，而端點不過濾**」。

### 2.3 為什麼結束的流還會被列出來 — 缺的是 predicate

`getFlowInfoJson()`（**修補前** `:2290-2329`）：

```
:2293  shared_lock lock(m_flowInfoTableMutex);
:2296  for (const auto& [flowKey, flowInfo] : m_flowInfoTable)   ← 走訪整張表
                                                                    沒有任何 if / predicate
:2298-2323  建 12 個 key：src_ip dst_ip src_port dst_port protocol_id
            ＋四個速率 ＋ first_sampled_time ＋ latest_sampled_time ＋ path
```

`getTopKFlowInfoJson(int k)`（`:2332-2380`）→ `:2364` 呼叫 `getFlowInfoJson()`、
`:2366-2372` 依 `estimated_packet_rate_in_the_proceeding_1sec_timeslot` 排序、
`:2375` `min(k, size)` 截斷。**兩層都沒有存活性條件。**
預設 `k = 50` 在 `src/ndt_core/http/HttpSession.cpp:589`（修補前行號）。

路由：`HttpSession.cpp:158`（修補前）是 **`target == "/ndt/get_detected_flow_data"`**，
**精確比對** ⇒ 這個端點在今天的碼上**根本不能帶 query string**，帶了就 404。
（top-k 那條 `:162` 是 `starts_with`，反而太寬。）

### 2.4 「死」在碼裡到底是什麼意思 — 修補前**沒有任何定義**

這是這條工單的核心，值得講清楚：

- **不是**「連續 N 次輪詢速率 0」——碼裡沒有任何連續計數。
- **不是**「last-seen 超過 T」——碼裡唯一有這個判準的是 `purgeIdleFlows`，
  而它的閾值 `T = FLOW_IDLE_TIMEOUT = 15000`，**且它只用來刪除，不用來標記**。
- 修補前，一條停了 14.9 秒的流，與一條正在送 1 Gbps 的流，
  **在 response body 上唯一的差別是 `latest_sampled_time` 這個字串**（`:2314`，
  `"%Y-%m-%d %H:%M:%S"` 格式化過）。消費端要用它必須：① 自己 parse 顯示字串做減法、
  ② **事先知道 `FLOW_IDLE_TIMEOUT = 15000`——而 API 文件沒有給這個常數**。

另外，kernel 其實**每秒都算出一個更好的訊號卻丟掉**：
`computeEstimatedRates` 在 `hopsCounter <= 0` 時回 `hasActiveHops == false`
（`include/common_types/SFlowType.hpp:445-453`），rate loop 在該分支把週期速率歸零
（`FlowLinkUsageCollector.cpp:1889-1914`）。**「這一秒沒有任何 hop 看到流量」這件事被算出來、
用來歸零、然後就沒了**，從來沒有變成一個消費端看得到的狀態。

### 2.5 對帳：92% 這個數字的出處 — **實測，但是單一工作點**

**是實測，不是估算。** 出處鏈：

| 層級 | 位置 |
|---|---|
| 預註冊 | `doc/audit/2026-08-27_flow-table-idle-tail/PREREG.md`（commit `59d58fb`） |
| 原始讀出 | `doc/audit/2026-08-27_1khz-path-recompute/preflight_*`（commit `8c9e841`） |
| 揭露查核 | `doc/audit/2026-08-27_flow-table-idle-tail/03_spec-disclosure-check.md`（`07408c6`） |
| 條目 | `doc/KNOWN-ISSUES.md:776-853` |

讀數：churn 工作點 **1.6 條新流/秒**下，`mean expected_alive 4.7` vs `mean api_flows 63.0`
⇒ **13.3×** ⇒ 92.5% 已結束；**最低比值 2.25，39 個樣本裡沒有一個低於 1**
（膨脹出現在每一個樣本裡，不是尾巴效應）。

🔑 **但 92% 不是常數，引用時必須帶條件。** 可轉移的形式是模型不是數字：

> 膨脹倍率 ≈ `1 + FLOW_IDLE_TIMEOUT(秒) × 新流速率 / 平均併發`

長流下趨近 1、短流／高 churn 下發散。我在 code 註解、commit message、API 文件三處
都寫的是這個公式加上「這是一個工作點的讀數」，沒有把 92% 寫成普遍值。

📌 **我讀碼重驗過 2026-08-30 那份「整條照舊」的對帳**（KNOWN-ISSUES `:826-838`）：
本輪（base `4cbec52d`）逐項重查，**四項全部仍然成立**——
`FLOW_IDLE_TIMEOUT 15000` 在 `hpp:35`、`getFlowInfoJson` 無 predicate（迴圈 `:2296`）、
`getTopKFlowInfoJson` `min(k,size)` 不過濾（`:2375`）、預設 `k = 50`（`HttpSession.cpp:589`）。
行號較 08-30 那份再漂移約 −1 到 +30 行。

### 2.6 對帳：`:821` 那個**被提出、實測不成立**的加乘效應

KNOWN-ISSUES `:821-853` 記的是：有人提出「top-k 依
`estimated_packet_rate_in_the_proceeding_1sec_timeslot` 排序，死流保留舊速率 ⇒ **死流搶贏活流**」。

🔴 **這個加乘不成立，我沒有重新主張它。** 理由與證據：

- 前提已被修掉：`FlowLinkUsageCollector.cpp:1911-1913` 在 `!rates.hasActiveHops` 分支
  明文把兩個 periodic 速率歸零（`aabe605`，本輪確認仍在）；`origin/main` 一直都清除。
- 實測 3040 次觀察，**兩臂的 dead-AND-nonzero 都是 0**（2026-08-28，`W_base 3367d0e9` ↔
  `W_branch a40e04ce`，每臂 170 次輪詢）。

✅ **實測成立的是另一件事，而且更糟**：死流的排序鍵是 0，**照樣占住前 10 名**——
median **4/10**（base）與 **2/10**（branch）——因為**同時活著的流不到 10 條**。
不是「贏過」是「**填滿**」。成因是 `零存活性過濾 ＋ min(k, size)`，**修速率欄位修不掉**。

⇒ 我在 code 註解（`FlowLinkUsageCollector.cpp` 的 top-k 段）、測試檔頭、commit message
三處都明寫「**deliberately NOT re-asserted**」，並寫出反證的觀察數。

### 2.7 對帳：`:195` 的殘留

KNOWN-ISSUES `:195` 附近（A-3 條目）寫：A-3 修好後**死流的速率是 0，但那條流還是會被列出來 15 秒**，
「還在名單上」屬於 B-x。**這與本輪設計一致，也是本輪處理的那一半**：
本 patch **完全不動速率欄位**，只加母體的分類與過濾。

---

## 3. 修法設計

### 3.1 兩類消費者必須分開對待（brief 第 2 點）

| 類別 | 消費者（file:line） | 死流對它的影響 | 這次改了什麼 |
|---|---|---|---|
| **A. 列清單／示範 UI** | 🔴 `~/Energy-Saving-App/src/app/energy_saving_app.cpp:741` → `json2sim["flowDataList"]`（**repo 外**，逐流消費：`strings` 有 `flow ip:{}->{} oldband/newband/diff`） | 難看；**且清單長度被高估 13×** | 端點預設改成只回 active；`?liveness=all` 可完整還原 |
| A | `tools/twin_audit/twin_audit.py:91` | 幾乎無影響：它的 `twin_claims_active()`（`:106-115`）本來就用 `..._in_the_last_sec > 0` 過濾 | 無需改；多出的欄位它看不到（Obj 非 strict） |
| A | `tools/contract_test/*`（`spec.py:385`、`components.py:27/147/168/175/187/194`、`selftest_fixtures.py:42/75`、`compare_baseline.py:186`） | `inv_flow_paths_non_empty` 這個指標**被稀釋約 13 倍**（工單 M 的 6-2） | 三個新欄位加成 **optional**（見 3.4） |
| **B. 速率／路由／數量** | `src/ndt_core/intent_translator/IntentTranslator.cpp:556`（`GET_ACTIVE_FLOW_COUNT`）→ `result["active_flow_count"] = flowTable.size()` | 🔴 **最糟的一個**：欄位名字就叫 active，值卻是整張表（工作點上 63 vs 4.7） | 改成 active／retained 兩個數字，**單次上鎖單趟計數** |
| B | `IntentTranslator.cpp:427`（`GET_TOP_K_FLOWS`）、`:530`（`GET_TOP_K_BANDWIDTH_USERS`） | 前 10 名混入約 6 具屍體 | **刻意不改**（見 §7 開放問題 Q2） |
| B | `HttpSession.cpp:613`（top-k 端點） | 同上，預設 k=50 ⇒ 約 45 筆屍體 | 端點預設改成 active only |
| B | `getFlowInfoTable()` 的 5 個測試消費者（`test_GoldenFixture.cpp:254/271/306/341`、`test_SFlowEmitterRoundtrip.cpp:128/219/247/338/347`、`test_SFlowParsing.cpp:273/295/297`、`test_LastHopAttribution.cpp:362`、`test_FlowTableConcurrency.cpp:149`） | — | **完全不動**（`getFlowInfoTable()` 語意不變＝整張表） |

🔑 **設計的核心取捨就在這張表**：`getFlowInfoJson()` / `getTopKFlowInfoJson(k)` 的
**單參數形式維持「全部」**，**API 的預設放在 `HttpSession`**。
⇒ 沒有任何 repo 內的非 HTTP 呼叫端會在「沒人動它的 call site」的情況下改變行為。
這正是「不能為了討好第一類而弄壞第二類」的具體落法。

### 3.2 三個狀態（不是布林）

`include/common_types/SFlowType.hpp`（放在 `computeEstimatedRates` 旁邊，同一種風格）：

```cpp
enum class FlowLiveness { Active, Idle, Ended };
enum class FlowLivenessFilter { ActiveOnly, ActiveAndIdle, All };
FlowLiveness classifyFlowLiveness(nowMs, lastSeenMs, activeWindowMs, idleTimeoutMs);
int64_t      flowEndedAtMs(lastSeenMs, idleTimeoutMs);
bool         passesLivenessFilter(FlowLiveness, FlowLivenessFilter);
bool         parseLivenessFilter(std::string_view, FlowLivenessFilter& out);
struct FlowLivenessCounts { active; idle; ended; retained(); };
```

🔴 **為什麼一定要三個狀態，這是最容易做錯的一步**：

> `Ended`（age ≥ 15 s）**幾乎不存在**——purge 每秒掃一次，這種列在表裡最多活 1 秒。
> **那 92% 全部都是 `Idle`。**
> 所以一個寫成「排除 ended」的布林過濾器**會通過 code review 而幾乎什麼都不移除**。

我把這件事寫進 `tests/test_FlowLiveness.cpp` 的
`RetainedKeepsIdleAndIsThereforeNotTheDefault`，就是為了讓後人不能悄悄退回布林版。

判準（全部半開區間，與 purge 用同一個 `endTime` 欄位、同一個時鐘）：

| 狀態 | 條件 |
|---|---|
| `Active` | `now - endTime < kFlowActiveWindowMs`（3000 ms） |
| `Idle` | `3000 ≤ age < 15000` |
| `Ended` | `age ≥ 15000` ＝ **與 `purgeIdleFlows:2247` 逐字同一個比較** |

### 3.3 `kFlowActiveWindowMs = 3000` 的界怎麼來的（brief 要求 justify）

放在 `FlowLinkUsageCollector.hpp`，緊鄰 `FLOW_IDLE_TIMEOUT`（理由與該檔既有的
`kFlowPathRecomputeInterval` 註解同一句：**成對才有意義**）。

- 這個界必須**蓋過一個完整的 rate-loop 週期再加餘裕**，因為活流的新鮮度上界由「樣本多久到一次」決定。
- rate loop 自己會印週期：**64 條流時 windowed mean 1248.7 ms**（2026-08-25；
  cumulative mean 印 1106.3 ms，是那個被 grep 走、系統性偏低的數字——見 `.cpp:1901` 的註解）。
- ⇒ **1000 ms 會抖**：一條從沒停過的流會在表一大就被反覆標成 `idle`。
  一個在 active/idle 之間跳動的示範，比一個高報的示範更糟。
- **3000 ms ≈ 2.4 個實測週期的餘裕，同時把 15 秒尾巴收回 12 秒。**

⚠️ **這個界是關於「觀測」不是關於「世界」的宣稱**：`active` 的意思是「3 秒內有樣本到達」。
低取樣率下，一條真的在送的流可能錯過這個窗 ⇒ **失效方向是悲觀（活流被說成 idle），不是樂觀**。
對一個以抓故障為存在理由的 twin，這是該選的方向；但它是真實成本，
也就是 `?liveness=retained` 存在的理由（給寧可高報的呼叫端）。

### 3.4 API 形狀

- **每一筆紀錄**（不分 filter）多三個欄位：
  `liveness`（`"active"|"idle"|"ended"`）、`last_seen_ms`、`ended_at_ms`。
  都是 **epoch 毫秒整數**，不是顯示字串——重點就是讓消費端可以直接減。
  `latest_sampled_time` 原樣保留（給人看）。
- `ended_at_ms` = `last_seen_ms + 15000`，**推導不儲存**。存起來會變成同一個事實的第二份真相，
  兩個界一動就會不一致。
- 端點：`?liveness=active|retained|all`；**不帶＝`active` only**。
  `all` **逐 byte 還原修補前的母體**。
- **打錯的值回 400，不是靜默 fallback**：`?liveness=alive` 若被當成預設，
  呼叫端會拿到一份被過濾過、卻以為是完整的清單——**與本 bug 同一種形狀**。
- 路由必須動：`HttpSession.cpp:158` 原本是 `==` 精確比對，帶 query 就 404。
  新增 `utils::pathIs()`（`include/utils/Utils.hpp`），
  **順手收緊了 top-k 那條 `starts_with`**（原本 `/ndt/get_detected_top_k_flow_dataZZZ` 也會被服務）。
- 契約：三個欄位加進 `spec.FLOW_RECORD` 的 **`optional=`**（不是必要欄位）。
  理由：contract test 是打**活的 kernel**，修補前的 binary 只吐 12 個欄位；
  設成必要會把契約測試變成版本檢查，對一顆「照它被 build 出來的樣子運作」的舊 binary 報「契約壞了」。
  列出來的作用是**擋住日後 refactor 悄悄拿掉**（`Obj` 預設 `strict=False`，
  `tools/contract_test/schema.py:129-138`，沒列的欄位在這裡是隱形的）。

### 3.5 被否決的替代方案

| 方案 | 為什麼不採 |
|---|---|
| **① 縮短 `FLOW_IDLE_TIMEOUT`** | KNOWN-ISSUES 明講「**保留可能是刻意的，缺陷在端點沒有表達出來，不在保留本身**」。縮短會讓「一閃即逝的短流」完全看不到，用一個沉默換另一個沉默 |
| **② 用 `hasActiveHops` 當存活訊號**（rate loop 每秒已經算出來） | 語意上更漂亮（`liveness == active` ⟺ 這一秒有非零 periodic rate，API 內部自洽），但要在 rate loop 熱路徑新增一個寫入點，且會讓存活性依賴「rate loop 有沒有跑到」。`endTime` 每個封包都更新、purge 也用它 ⇒ **一個欄位、一個時鐘、兩個讀者**，不可能不一致。改用 `endTime` |
| **③ 儲存 `endedAt` 欄位** | 同一個事實的第二份真相；`FLOW_IDLE_TIMEOUT` 一改就會與 `liveness` 不一致。改成推導 |
| **④ 布林 `include_ended`** | 見 §3.2：`Ended` 幾乎不存在，這個旗標**會通過 review 而幾乎什麼都不移除** |
| **⑤ 直接把 `getFlowInfoJson()` 的預設改成 ActiveOnly** | 會讓**五個既有測試檔**（`getFlowInfoTable`／`getFlowInfoJson` 的消費者）變成時間相依：fixture replay 的 `endTime` 是 replay 當下，3 秒後行為就變。而且會把第二類消費者一起拖下水 |
| **⑥ 過濾 top-k 的輸出（min(k,size) 之後）** | 會回傳少於 k 筆、而活流就排在切點下面。必須**排序前、截斷前**過濾 |
| **⑦ 測試用 `sleep(3)` 製造舊資料** | 整個測試套件今天**沒有任何多秒 sleep**；且會留下一個永遠要維護的時間相依測試。改用 seam（見 §5.2） |

---

## 4. Patch

```
$ git log --oneline -1
58aa5569 Give a flow a lifecycle, so the endpoint that says "active" can mean it

$ git show --stat HEAD
 doc/2026-01-02_ndt_api.md                          |  52 +++
 include/common_types/SFlowType.hpp                 | 189 +++++++++
 include/ndt_core/collection/FlowLinkUsageCollector.hpp |  76 +++-
 include/ndt_core/http/HttpSession.hpp              |  16 +
 include/utils/Utils.hpp                            |  29 ++
 src/ndt_core/collection/FlowLinkUsageCollector.cpp |  75 +++-
 src/ndt_core/http/HttpSession.cpp                  |  68 +++-
 src/ndt_core/intent_translator/IntentTranslator.cpp |  21 +-
 tests/CMakeLists.txt                               |   2 +
 tests/test_FlowLiveness.cpp                        | 437 +++++++++++++++++++++
 tests/test_HttpSessionRouting.cpp                  |  67 ++++
 tools/contract_test/spec.py                        |  11 +
 12 files changed, 1030 insertions(+), 13 deletions(-)
```

分支 `fix/bx-flow-liveness`，**未 push**。所有 AI 參與的碼都帶
`[Co-developed with claude code -- Adam]`。commit 用列到檔案的 pathspec（12 個檔全部列出）。

📌 1030 行插入裡，**註解與測試占絕大多數**：`test_FlowLiveness.cpp` 437 行、
`test_HttpSessionRouting.cpp` +67、`SFlowType.hpp` 的 189 行有約 120 行是說明性註解。
實際邏輯約 90 行。

---

## 5. 測試證據 — 🔴 **UNVERIFIED（從未看過紅，也從未看過綠）**

### 5.1 為什麼沒有跑

brief 第 2 節硬性限制：**不准 build**（cmake/ninja/make），因為有 CPU 敏感的量測在跑。
所以：**沒有編譯、沒有執行、變異閘沒有跑。** 這不是「跑了但失敗」，是「沒跑」。
依專案守則（`測試沒看過紅就不算交付`），**本交付在有人跑過之前不算完成**。

我唯一實際執行過的檢查是 `python3 -c "ast.parse(...)"` 對 `tools/contract_test/spec.py`
做語法解析（**通過**）——那是 Python 語法檢查，不是 build，也不是測試。

### 5.2 每一個 case 的「今天哪一行讓它紅」

`tests/test_FlowLiveness.cpp`（新增，18 個 case）：

| case | 修補前為什麼紅 |
|---|---|
| `AFlowSampledJustNowIsActive`、`TheActiveWindowIsHalfOpen…`、`TheWholeRetentionTailIsIdle…`、`EndedBeginsExactlyWherePurgeIdleFlowsWouldRemoveTheRow`、`ASampleStampedInTheFutureIsActive…` | `sflow::classifyFlowLiveness` **不存在** ⇒ 編譯失敗。這正是缺陷的一句話版本：**kernel 裡沒有任何函式回答「這條流停了沒有」** |
| `ActiveOnlyAdmitsNothingButActive`、`RetainedKeepsIdle…`、`AllAdmitsEveryClass`、`EndedAtIsExactlyOneTimeoutAfterTheLastSample` | 同上，函式不存在 |
| `TheThreeAcceptedValuesParseToTheirFilters`、`AnAbsentValueLeavesTheCallersDefaultAlone`、`AnUnrecognisedValueIsRejected…` | `sflow::parseLivenessFilter` 不存在 |
| `PathIsAcceptsTheBarePathAndTheSamePathWithAQuery`、`PathIsRejectsASuffixThatIsNotAQuery` | `utils::pathIs` 不存在 |
| 🔴 `EveryRowCarriesTheThreeFieldsThatSayWhetherItIsStillSending` | **行為紅**：`FlowLinkUsageCollector.cpp:2298-2323`（修補前）只建 12 個 key，`row.contains("liveness")` 對**每一列**都失敗 |
| `RowsJustReplayedAreActiveAndSurviveTheDefaultFilter` | 過度過濾的防護（保護第二類消費者）。修補前無 `FlowLivenessFilter` 型別 ⇒ 編譯失敗 |
| 🔴 `AStoppedFlowIsGoneFromTheDefaultViewAndStillThereUnderAll` | **工單本體**。修補前 `getFlowInfoJson` 在 `:2296` 直接 `for … : m_flowInfoTable` 進入 emit，**沒有任何 predicate** ⇒ 比較的兩邊是同一個陣列，`EXPECT_TRUE(active.empty())` 永遠不可能成立 |
| `TopKFiltersBeforeItTruncatesRatherThanAfter` | 修補前 `getTopKFlowInfoJson` 只有 1 個參數 ⇒ 編譯失敗；語意上防的是「先截斷後過濾」 |
| `TheCountsAddUpToTheWholeTableAndMoveTogether` | `countFlowsByLiveness` 不存在；語意上對應 `IntentTranslator.cpp:556-559` 的 `active_flow_count = flowTable.size()` |

`tests/test_HttpSessionRouting.cpp`（追加 4 個 case，放這裡的理由是該檔檔頭那句：
**狀態碼由 HttpSession 決定，所以只能問 HttpSession**）：

| case | 修補前為什麼紅 |
|---|---|
| `AQueryStringOnGetDetectedFlowDataStillReachesItsRoute` | 修補前回 **404**（`:158` 是 `==` 精確比對，帶 query 就落到 not-found 尾巴）。修補後應為 400 |
| `AnUnrecognisedLivenessValueIsRefusedRatherThanQuietlyDefaulted` | 同上，四個值全部 404 |
| ⚠️ `TopKRefusesAnUnrecognisedLivenessValueBeforeTouchingTheCollector` | **修補前會 SEGFAULT**：top-k 的路由本來就是 `starts_with`，請求會進到 handler，而 peer 的 collector 是 `nullptr` ⇒ 空指標解參考。**這會殺掉整個 gtest 行程，連帶其他測試的報告一起消失**。這是失敗，但很難看的失敗——與該檔檔頭描述的同一個危險。跑閘的人要預期這件事 |
| `AMistypedFlowDataEndpointIsNotFoundRatherThanServed` | `/ndt/get_detected_top_k_flow_dataZZZ` 修補前被當成正牌端點服務（`starts_with`）⇒ 同樣 segfault；修補後 404 |

> 🔑 這四個 case 全部只斷言 4xx，且都在**碰到任何 collaborator 之前**就返回
> （`readLivenessFilter` 在解參考 null collector 之前執行完），
> 符合該檔「null 依賴只能見證被提早拒絕的請求」這條自我約束。

### 5.3 為了讓「流停了會被丟掉」變成可決定性測試，我加了一個 seam

`FlowLinkUsageCollector.hpp` protected：`int64_t m_flowActiveWindowMs = kFlowActiveWindowMs;`
production 從不寫它；測試子類 `LivenessCollector::collapseActiveWindow()` 把它壓成 0，
讓每一列瞬間變 `Idle`。

替代方案是 sleep 3 秒（見 §3.5 ⑦）或開放 `FlowInfo::endTime` 給測試寫（等於開放整張表給 mutate）。
**這是我在這個 patch 裡最可能被質疑的一個決定**，寫在 §7 Q3 給 Adam 裁。

---

## 6. 沒有驗證的部分 / 人要做的下一步

**按重要性排序：**

1. 🔴 **編譯。** 我一行都沒編。可能的編譯風險點（我逐一自查過但沒有編譯器背書）：
   - `HttpSession.hpp` 新增 `#include "common_types/SFlowType.hpp"`（原本只前置宣告
     `sflow::FlowLinkUsageCollector`）——`readLivenessFilter` 的參數需要完整型別。
     這會讓 SFlowType.hpp 進到每個 include HttpSession.hpp 的 TU。
   - `getFlowInfoJson` / `getTopKFlowInfoJson` 的預設引數**只寫在標頭**、定義不重複（正確做法，但值得覆核）。
   - `test_FlowLiveness.cpp` 的 `LivenessCollector` 建構子參數順序抄自
     `test_TopKFlowInfoLocking.cpp:92-101`，並已對照 `hpp:107-111` 覆核過（見第 3 點）。
2. 🔴 **變異閘。** 至少要看到 §5.2 表裡標紅的三個 case 真的紅：
   `EveryRowCarriesTheThreeFields…`、`AStoppedFlowIsGoneFromTheDefaultView…`、
   `AQueryStringOnGetDetectedFlowDataStillReachesItsRoute`。
   跑法：先 stash 掉 `src/` 與 `include/` 的改動只留 `tests/`，或反向套用。
   ⚠️ 注意 §5.2 那個 **segfault** case 會中斷整個 binary 的報告。
3. ⚠️ **既有測試會不會被我弄紅，我沒有跑。** 特別是：
   - `test_TopKFlowInfoLocking.cpp:191` 呼叫 `getFlowInfoJson()`（無參數）——
     預設是 `All`，行為應完全不變。但 `m_full` 的每一列現在多三個欄位，
     而 `rowsOf()` 是拿 `row.dump()` 當字串比對（`:172-180`）⇒ **兩邊都多同樣的欄位，應該仍相等**，
     但這是我推的、沒跑過。
   - `test_HttpSessionRouting.cpp:301` 的 `AnUnknownEndpointIsNotFound`：`pathIs` 之後仍應 404。
   - ✅ **`test_GoldenFixture.cpp` 已查（讀碼）：它只用 `getFlowInfoTable()`（`:254 :271 :306 :341`），
     從不呼叫 `getFlowInfoJson()`，全檔沒有 flow record 的欄位集合比對** ⇒ 三個新欄位碰不到它。
   - ✅ **collector 建構子簽章已查**：`hpp:107-111`
     `(monitor, deviceManager, bus, int mode, classifier)`，與我在
     `LivenessCollector` 用的完全一致（deviceManager 傳 `nullptr`），與 `TopKCollector` 相同。
4. **live 驗證（要 lab，我沒有也不能碰）**：
   在 churn 工作點重跑一次 ticket W 的量測，確認
   `len(GET /ndt/get_detected_flow_data)` 從 ~63 降到 ~4.7，
   而 `?liveness=all` 仍回 ~63。**這是唯一能證明 92% 真的被移除的證據**——
   §5.2 那個 seam 測試證明的是「filter 會丟掉沒有近期樣本的列」，
   不是「真實工作點上被丟掉的比例是 92%」。
5. 🔴 **補一個帶真 collector 的 `HttpSessionTestPeer`。** 目前沒有任何測試用真的
   collector 服務一個請求（peer 傳 `nullptr`），所以**沒有東西觀察得到端點的預設行為**——
   API 預設只由一個常數釘住。這是變異閘找出來的最大缺口，也是它之後最有價值的後續。
6. **repo 外的消費者**：`~/Energy-Saving-App` 沒有被我讀、沒有被我動
   （memory 記著那個 repo 有**未 push** 的修改 ⇒ 只讀不動；我連讀都沒讀）。
   **仍然未答的那一問**：`flowDataList` 的**長度**有沒有被當成負載指標。
   如果有，這個預設是修好而不是回歸；如果沒有，這個預設只是讓清單變短。
   **在有人去讀那一段之前，不要宣稱這個 patch 對省電模擬是安全的。**
7. **`doc/KNOWN-ISSUES.md` 我沒有動。** B-x 條目仍標開著——**這是對的**：
   依 A-1／A-3 的前例，變異閘跑綠之前不得改標 RESOLVED。

---

## 7. 給 Adam 的裁決（選項 ＋ 後果）

### Q1 🔴 端點的預設要不要真的改成「只回 active」？（最重要）

| 選項 | 後果 |
|---|---|
| **A（我實作的，建議）** 預設＝active only，`?liveness=all` 還原 | 端點與文件 `:358` 的 “all **active** flows” 終於一致；示範清單乾淨。**但這改變了 repo 外 Energy-Saving-App 收到的東西**，而它是否用清單長度當負載指標**未讀未知**。實作上這是**一行**：`HttpSession.cpp` 的 `kFlowDataApiDefault` |
| B 預設維持 all，`?liveness=active` 由呼叫端自己選 | 零回歸風險；三個新欄位仍然讓消費端第一次能分辨死活。**但示範照樣難看**，且文件那句 “active” 仍是假的（只能改文件不改行為） |
| C 先 B 後 A：這一版只加欄位，等有人讀完 Energy-Saving-App 再翻預設 | 最保守，代價是要跑兩次驗證 |

### Q2 IntentTranslator 的兩條 top-k 路徑（`:427` `GET_TOP_K_FLOWS`、`:530` `GET_TOP_K_BANDWIDTH_USERS`）要不要一起過濾？

| 選項 | 後果 |
|---|---|
| **A（我做的）不改** | 理由：這兩個名字沒有宣稱 active，而我已經改了 `active_flow_count`（那個**名字本身就是假宣稱**）。保持 diff 有界 |
| B 一起改成 ActiveOnly | LLM 被問「前 K 大的流」時不會拿到約 6 具屍體。但這兩條路徑**沒有任何測試釘住**，改了沒人會發現壞掉 |

### Q3 為了測試而加的 seam（`m_flowActiveWindowMs` 這個 protected 成員）可以嗎？

| 選項 | 後果 |
|---|---|
| **A（我做的）保留** | 「停掉的流會被丟掉」這條斷言變成**可決定、零 sleep** 的單元測試。代價是 production class 多一個只有測試會寫的成員 |
| B 拿掉，改成 sleep 3 秒 | 沒有 production 表面。代價：整個套件今天沒有任何多秒 sleep，且會留下永久的時間相依測試 |
| C 拿掉，那條斷言只在 live 輪次驗 | class 最乾淨。代價：**這條工單最核心的斷言沒有任何自動化測試** |

### Q4 `kFlowActiveWindowMs = 3000` 這個數字

| 選項 | 後果 |
|---|---|
| **A（我做的）3000 ms** | ≈2.4 個實測 rate-loop 週期（64 流時 1248.7 ms）的餘裕；收回 15 秒尾巴中的 12 秒 |
| B 更小（如 2000） | 尾巴收得更乾淨，但流數一多就會在 active/idle 之間抖 |
| C 讓它可由設定檔調 | 可依部署調校，代價是多一個沒有測試的設定面 |

### Q5 三個新欄位在契約裡是 optional 還是 required？

| 選項 | 後果 |
|---|---|
| **A（我做的）optional** | contract test 對**修補前的 binary** 仍然通過（它是打活 kernel 的）。缺點：日後有人拿掉欄位不會變紅 |
| B required | 欄位受保護。代價：契約測試變成版本檢查，對舊 binary 報「契約壞了」——那是假陽性 |

---

## 8. 順手發現、但不屬於本工單的東西（只記錄，沒有動）

1. `purgeIdleFlows:2242` 的 `if (now <= info.endTime) continue;` 用**系統時鐘不是 steady clock**
   ⇒ 時鐘倒退會產生**沒有上界的殭屍紀錄**（2026-08-13 那筆 291 秒、超過 15 秒天花板 19 倍的觀察）。
   **我的 classifier 刻意與 purge 站同一邊**（未來時間戳 ⇒ `Active`），
   這樣新的 filter **不會把殭屍藏起來**——它會留在預設檢視裡，很吵。修時鐘的人要來改我那個 test case。
2. `getFlowInfoJson:2300` 的 `src_ip` 是**裸 uint32**，而同檔 `:2726` 與 `HttpSession.cpp:1732`
   用 `utils::ipToString`；`purgeIdleFlows` 自己 log 也用 dotted quad。同一個 struct、同一個檔、兩種序列化慣例。
3. `path[].node` 是超載欄位：host 用 uint32 IP、switch 用 dpid，同一個 key、兩個命名空間、無型別標記。
4. `getFlowInfoJson:2316-2319` 有一段被註解掉的 `m_allPathMap` 迴圈留在原地。

---

# 附錄 A — 變異閘腳本（2026-09-02 追加，coordinator 要求）

commit `7d678ed0`，檔案 `tests/shell/mutate_bx_flow_liveness.sh`（438 行）。

## A.1 執行方式

```
BUILD_DIR=build JOBS=4 TEST_TIMEOUT=300 tests/shell/mutate_bx_flow_liveness.sh
```

離開碼：`0` 全數捕獲、`1` 有存活者、`2` 無法下判決
（baseline 在範圍內就紅／anchor 漂移／hang／restore 失敗／對照組變紅）。

## A.2 七個變異 ＋ 一個對照組

| # | 變異 | 必須變紅的具名測試 |
|---|---|---|
| 1 | `classifyFlowLiveness` 永遠回 active（`if (true \|\| …)`） | `TheActiveWindowIsHalfOpen…`、`TheWholeRetentionTailIsIdle…`、`EndedBeginsExactlyWherePurge…`、`AStoppedFlowIsGone…` |
| 2 | 🔑 三態塌成布林「排除 ended」 | `ActiveOnlyAdmitsNothingButActive`、**`AStoppedFlowIsGone…`（92% 全 idle 的 fixture，coordinator 指名要它抓到）**、`TopKFiltersBeforeItTruncates…` |
| 3 | `kFlowActiveWindowMs = 0` | `TheActiveWindowSitsBetween…`、`RowsJustReplayedAreActive…`、`TheCountsAddUp…` |
| 4 | `kFlowActiveWindowMs = 1000000000` | `TheActiveWindowSitsBetween…` |
| 5 | API 預設翻回 `All` | `TheEndpointDefaultIsActiveOnly…` |
| 6 | `utils::pathIs` 還原成 `==` | `AQueryStringOnGetDetectedFlowDataStillReachesItsRoute`、`AnUnrecognisedLivenessValueIsRefused…`、`TopKRefusesAnUnrecognisedLivenessValue…` |
| 7 | 🔴 `utils::pathIs` 還原成 `starts_with`（**預期 signal 死亡**） | `AMistypedFlowDataEndpointIsNotFoundRatherThanServed` |
| C | 只加一行註解 | **必須存活**；變紅⇒閘門沒有鑑別力⇒exit 2 |

## A.3 🔴 寫這個閘門，找出了兩個測試漏洞（這才是重點）

coordinator 指名的兩個變異**原本會存活**，我補了兩個測試：

1. **`kFlowActiveWindowMs = 10^9` 會存活** —— 所有 collector 層的 case 都透過 test seam
   把窗壓成 0，**沒有任何一個會去讀那個常數**。
   ⇒ 新增 `TheActiveWindowSitsBetweenARateLoopPeriodAndTheIdleTimeout`：
   斷言的是**關係不是數值**——窗必須嚴格小於 `FLOW_IDLE_TIMEOUT`（否則 `idle` 不可達，
   三態悄悄塌回本工單要修的那兩態），且至少一個實測 rate-loop 週期（否則沒停過的流會抖）。
   **這一個 case 同時從兩邊抓住 `=0` 與 `=10^9`。**
2. **「API 預設翻回 all」會存活** —— repo 裡**沒有任何測試用真的 collector 服務一個請求**
   （peer 的 collector 是 `nullptr`，走到 handler 就空指標）⇒ 沒有東西觀察得到那個預設。
   ⇒ `kFlowDataApiDefault` 移到 `HttpSession.hpp` 當 public 常數並釘住。
   ⚠️ **這釘的是「值」不是「行為」**——與 `FlowPathRecomputeInterval.IsOneSecondNotOneMillisecond`
   同一種取捨，我在碼裡與閘門裡都明寫了。**補一個帶真 collector 的 `HttpSessionTestPeer`
   是這個閘門之後最有價值的後續**（見 §6 新增第 7 點）。

🔑 **閘門在跑之前就已經生效了。**

## A.4 三個第一次寫錯、修掉的地方

1. 🔴 **`grep -cF` 數不了多行 anchor，而且錯的方向會藏問題。**
   grep 把 `-F` pattern 用換行拆成 alternatives，然後數**符合任一段的行數**
   ⇒ 五行的 `pathIs` anchor **數出 121**（Utils.hpp 裡每一個 `{`、`}`、`return false;`）。
   「必須是 1」會誤殺好 anchor；「必須 ≥1」會放行一個已經不存在的 anchor。
   ⇒ 精確次數改用 python 的 `str.count`，grep 的數字保留在旁邊當**只針對第一行**的交叉檢查。
2. 🔴 **signal 死亡既不是 hang 也不是存活者。** 變異 7 讓 `/ndt/…top_k_flow_dataZZZ`
   被服務、進到 handler、解參考 null collector ⇒ SIGSEGV。那是**合法的紅**
   （該被拒絕的請求被服務了），但 gtest 印不出 FAILED 行，因為行程沒了。
   ⇒ 全部走 `timeout`，rc 分三類：`124` = hang（停止整個閘門）、`>128` = red reason=crash
   （兇手＝最後一行 `[ RUN      ]`）、其他非 0 = 一般斷言失敗。
3. 🔴 **restore 後的檔案 mtime 必須比 mutant 的 .o 新。** `cp -p` 會把舊 mtime 放回去，
   ninja 判定沒事做，**下一個變異其實是在上一個 mutant 的 binary 上量的**，而磁碟上的原始碼看起來乾淨。
   ⇒ 每次 restore 後 `touch`；最後 restore 之後**再 build 一次並檢查結果**
   （`build || true` 會把「用最後一個 mutant 建出來的 binary」交給批次裡的下一個閘門）。

## A.5 其他硬性要求的落法

- **anchor 對不上／mutant 編不過 ⇒ 都計為 SURVIVOR**（腳本 :259、:263）。
  兩者都沒有真的跑到測試，而「套不上去」永遠不可以被記成「被抓到」。
- **byte-identity**：4 個檔案 `cp -p` 快照 ＋ sha256 ＋ `cmp -s` 雙重比對；
  EXIT trap 保證 Ctrl-C 也會還原。
- **`N mutations, M survived`**，`M>0` ⇒ exit 1。
- **不用 `pkill`／`pgrep`**：全檔只有第 36 行的註解提到它們（就是在說不用）。
- **rc 不經過 pipe**：`OUT=$(timeout … "$BIN" … 2>&1); RC=$?`。
- **baseline 範圍分流**：紅在 `FlowLivenessTest.*`／`FlowLivenessTableTest.*`／
  `HttpSessionRoutingTest.*` **之外**⇒ 大聲印出來但繼續（不影響任何判決）；
  紅在**範圍之內**⇒ exit 2（expected-red 名單失去意義）。

## A.6 我實際跑過什麼（與沒跑過什麼）

✅ **跑過**（都不是 build）：
- `bash -n tests/shell/mutate_bx_flow_liveness.sh` ⇒ **通過**
- anchor 唯一性（把腳本的 anchor 區塊抽出來單獨執行）⇒ **五個全部 `exact=1`**
- **八個取代全部對 in-memory 副本 dry-run 過**，印出 unified diff 逐一確認落點與產物是合法 C++
  （腳本在 `scratchpad/dryrun_mutations.py`，**沒有寫進 repo 任何檔案**）
- `grep -cE 'pkill|pgrep'` ⇒ 只有註解那 1 行

🔴 **沒跑過**：**閘門本身沒有執行過。** 沒有 build、沒有跑測試、
**22 個（現在 24 個）case 仍然沒有一個被看過紅或看過綠。**
量測窗還開著，這條限制沒有變。
