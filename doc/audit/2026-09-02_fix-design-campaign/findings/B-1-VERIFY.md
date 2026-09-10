# B-1-VERIFY — 被交換機拒絕的規則，twin 當成存在的來服務（幽靈規則）

指派 ID：**B-1-VERIFY**　工作樹：`/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a678d74f17815d0a6`
（隔離 worktree，未動主 worktree、未 build、未跑 lab、未 push）

---

## 1. Base 驗證 ＋ 08-31 那次改動的指認

### 1.1 Base

worktree 建立時停在 `f5db629b update sleeping time`（即 brief 預告的 `origin/main` 上游狀態），已依指示修正：

```
$ git checkout --detach 4cbec52d45bd85e0e972110e35f51693d6ce137f
HEAD is now at 4cbec52d Keep the one line that names the restore failure
$ git log --oneline -1
4cbec52d Keep the one line that names the restore failure
$ sed -n '453p' doc/KNOWN-ISSUES.md
### B-1 被交換機拒絕的規則，twin 當成存在的來服務（幽靈規則）
```

兩項都對上 ⇒ base 正確。

### 1.2 改動的 commit

```
$ git log --since=2026-08-30 --until=2026-09-02 --oneline -S phantom -- src/ include/ p4_proxy/
91e77430 Serve only the flow entries that were actually programmed
```

`-S ghost` 在 `src/`／`include/`／`p4_proxy/` **零命中**（這個 codebase 用 "phantom" 不用 "ghost"）。

**碼的改動只有一個 commit：`91e77430`**（Author date 2026-08-30 22:33:17 +0800，08-31 併入；
KNOWN-ISSUES 稱它 **T-11-A**）。動到 11 個檔、+649/−6。

同一條線上另有五個**只動文件／證據**的 commit，對判斷很重要，因為它們補上了原 commit 自己說沒做的事：

| sha | 內容 | 對本裁決的作用 |
|---|---|---|
| `2016d4c0` | A-7 `DispatchOutcomeLog`（前置） | 拒絕的**可觀測性**其實是這一個給的，不是 T-11-A |
| `91e77430` | **碼的改動本體** | 視圖過濾 |
| `44d586f6` | 08-31 live acceptance 八個 raw 檔 | **補上原 commit 自稱「NOT run」的 live 驗收** |
| `73dd2926` | T-11 工單補兩節誠實聲明 | 承認 acceptance 跑在別人的量測窗內；補 7.4 s 量測 |
| `179adae0` | mutation harness 移出 scratchpad | 讓 T1–T5 verdict 事後可重跑 |
| `6fab3e0b` | KNOWN-ISSUES B-1 移除過期文字 | 就是 brief 說的「08-31 夜 auditor 移除」 |

🔑 **原 commit 的 "Not covered" 有一項已經被 `44d586f6` 關掉了**，而 KNOWN-ISSUES 引用的是關掉後的狀態。
只讀 `91e7743` 的 commit message 會低估這個修（它自己說 live 沒跑）；只讀 KNOWN-ISSUES 會不知道
它曾經沒跑。**兩份都要讀。**

---

## 2. 機制：改動前 vs 改動後

### 2.1 改動前（`91e7743^`）

**寫入點**——`src/ndt_core/http/HttpSession.cpp:1119-1120`（at `91e7743^`）：

```cpp
    // TODO: Immediately update the table
    m_deviceConfigurationAndPowerManager->updateOpenFlowTables(j);
```

`processFlowBatch` 先 `dispatcher().enqueue(...)`（非同步，worker 之後才送南向），
**接著在同一條 HTTP 執行緒上同步**把**原始請求 body `j`** 寫進表格快取。
南向連送都還沒送出去，快取裡就有這一列了。

**讀出點**——`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:1941-1945`（at `91e7743^`）：

```cpp
DeviceConfigurationAndPowerManager::getOpenFlowTables()
{
    std::shared_lock<std::shared_mutex> lock(m_openflowTablesMutex);
    return m_cachedOpenFlowTables;
}
```

**原封不動回傳快取。** 沒有任何來源判別。

**「服務出去」＝三個消費者，而且不只是顯示：**

| 消費者 | file:line（HEAD 行號，改動前後同位置） | 是不是決策輸入 |
|---|---|---|
| `GET /ndt/get_switch_openflow_table_entries` | `src/ndt_core/http/HttpSession.cpp:622` | 顯示／對外 API |
| `LLMAgent::getCurrentFlowEntries()` | `src/ndt_core/intent_translator/LLMAgent.cpp:275` | 🔴 **是**——組成餵給 LLM 的 prompt 字串 |
| `IntentTranslator`（取某台 switch 的 flow entries） | `src/ndt_core/intent_translator/IntentTranslator.cpp:1069` | 🔴 **是**——intent 轉譯的輸入 |

⇒ **「routing 有沒有用到它」的答案：轉送平面（FlowDispatcher／Controller 的南向寫入）沒有用到這份快取；
但 intent／LLM 這條決策鏈用到了。** 幽靈規則會進到 LLM 的世界模型與 intent 轉譯的輸入，
所以改動前它不是純顯示缺陷。

**存活時間**：直到週期性 poll 覆寫整份快取為止。
`DeviceConfigurationAndPowerManager.cpp:1893` 做 `m_cachedOpenFlowTables = std::move(newTables)`，
worker 固定 sleep 10 s ＋ 一次南向 poll ⇒ 上界 ~10.7 s（FINDING-06 更正後的口徑：
**是「看不見／看錯」的窗，不是「還沒裝」的窗**）。

### 2.2 改動後（HEAD `4cbec52d`）

**寫入照舊發生。** `HttpSession.cpp:1157` 仍然同步寫快取，只是改成傳 tokened 版本：

```cpp
    json annotated = j;
    if (!annotatedInstalls.empty())
    {
        annotated["install_flow_entries"] = annotatedInstalls;
    }
    m_deviceConfigurationAndPowerManager->updateOpenFlowTables(annotated);
```

token 在 `HttpSession.cpp:1166-1173` 鑄造（`static std::atomic<uint64_t> s_nextPendingToken{1}`，
process-wide monotonic，**只蓋在 install 上**），同時掛在 `FlowJob` 與快取列上。

`updateOpenFlowTables` 的 `installOne`（`DeviceConfigurationAndPowerManager.cpp:2119-2126`）
把 token 蓋進新列：`newFlow[kPendingTokenField] = e.at(kPendingTokenField);`
⇒ **幽靈列照樣被 push 進 `m_cachedOpenFlowTables`。**

**過濾發生在讀出點**——`DeviceConfigurationAndPowerManager.cpp:1970-1976`：

```cpp
DeviceConfigurationAndPowerManager::getOpenFlowTables()
{
    std::shared_lock<std::shared_mutex> lock(m_openflowTablesMutex);

    json out = m_cachedOpenFlowTables;
    stripUnprogrammedEntries(out, m_isProgrammed);
    return out;
}
```

規則在 `include/ndt_core/routing_management/PendingEntryFilter.hpp`（header-only、純函式）：
**帶 token 且該 token 未被南向確認 ⇒ 扣住**；token 為 0（poll 回來的真列）⇒ 一律不動；
輸出前把 token 欄位 erase 掉。確認索引是 `DispatchOutcomeLog::isProgrammed(token)`
（`include/ndt_core/routing_management/DispatchOutcomeLog.hpp`），只有
`result.ok` 的南向結果才會 `noteProgrammed_(job.token)`。

### 2.3 🔴 判定：**視圖，不是狀態**

**改的是 VIEW，不是 STATE。** twin 內部仍然相信那條規則存在——被拒絕的列留在
`m_cachedOpenFlowTables` 裡，直到 poll 覆寫（上界 ~10.7 s）為止。

但這件事要講得比「只是藏起來」精確，因為**兩個具體事實把它往兩個方向拉**：

**① 往「比單純隱藏好」的方向**：過濾點選在**唯一的共同讀出口**，不是在 endpoint。
三個消費者全部經過 `getOpenFlowTables()`；grep 全 repo，`m_cachedOpenFlowTables`
只在五處出現，除了 poll 覆寫與 `updateOpenFlowTables` 自己之外，**沒有任何繞過過濾器的讀取路徑**：

```
$ grep -rn "m_cachedOpenFlowTables" src/ include/
src/.../DeviceConfigurationAndPowerManager.cpp:1893   ← poll 覆寫（寫）
src/.../DeviceConfigurationAndPowerManager.cpp:1974   ← getOpenFlowTables 的複製（唯一讀出口）
src/.../DeviceConfigurationAndPowerManager.cpp:2041   ← updateOpenFlowTables 內部
src/.../DeviceConfigurationAndPowerManager.cpp:2063   ← updateOpenFlowTables 內部
src/.../DeviceConfigurationAndPowerManager.cpp:2065   ← updateOpenFlowTables 內部
include/.../DeviceConfigurationAndPowerManager.hpp:693 ← 宣告
```

⇒ 對**今天存在的**每一個消費者，幽靈都真的不見了。這比 §D「揭露≠下修」那一族的典型
（把缺陷寫進報告卻不改結論）**強一級**：這裡不是只加了註記，是真的把輸出改掉了。

**② 往「還沒到 formally fixed」的方向**：污染的狀態**不是惰性的，它還會被拿來比對**。
`updateOpenFlowTables` 的 `modifyOne`（`:2134-2155`）與 `deleteOne`（`:2158-2170`）
**直接走原始陣列 `*flowsPtr`**，沒有經過任何 token 判別：

```cpp
        for (auto& f : *flowsPtr)
        {
            auto fKey = extractKey(f);
            if (fKey == key)
            {
                f["priority"] = e.value("priority", 0);
                ...
                break;              // ← 命中幽靈就停，真列不會再被走訪
            }
        }
```

⇒ 在那 ~10.7 s 內進來的 `modify_flow_entry`／`delete_flow_entry`
**可以命中一條從來沒有被編程過的幽靈列**：modify 會就地改它（`break` 之後不再找別人），
delete 會把它移除。這是「內部狀態仍被當真」的**可指認後果**，不是理論疑慮。

⚠️ **但實際觸及範圍要誠實標註**：`extractKey`（`:2071-2098`）只讀**呼叫端字彙**
（`eth_type`／`ipv4_dst`／`tcp_dst`…）。poll 回來的真列用的是**交換機字彙**（`dl_type`／`nw_dst`），
所以真列在 `extractKey` 下全部退化成近乎相同的鍵。⇒ 這條快取的 modify/delete 比對**本來就不可靠**
（正是 KNOWN-ISSUES B-1「副作用：混用兩套 match key 詞彙」那一行的下游），
幽靈只是讓它多錯一種方式。**我沒有實跑證明這條路徑會造成使用者可見的損害**——
它是讀碼認定的狀態污染後果，嚴重度未量。

### 2.4 拒絕本身，現在看得見嗎？

**看得見，而且相當完整——但那是 A-7（`2016d4c0`）給的，不是 T-11-A 給的。**

| 管道 | 位置 | 內容 |
|---|---|---|
| **API** | `GET /ndt/get_flow_dispatch_status`（`HttpSession.cpp:170` 路由、`:638` handler） | `counters{dispatched,succeeded,failed,dropped_after_stop}`＋`recent_failures[]`（每筆帶 `seq`／`at_unix_ms`／`op`／`dpid`／`requested_priority`／`match`／`controller_status`／`message`）＋`recent_failures_capacity`／`recent_failures_evicted` |
| **結構** | `DispatchOutcomeLog`（ring，預設 cap 256，只存失敗；成功只計數） | 逐出有計數並公布（`failuresEvicted()`），所以清單被截斷時說得出來 |
| **log** | `Controller.cpp:55` `dispatched install failed for dpid ...` | P4 上有；**OVS 上沒有**（Ryu 的 fire-and-forget 200，那個檢查永遠沒東西可找）——B-1 原始的 OVS 靜默**沒有被這次改動碰到** |

⇒ 拒絕**是**可觀測的（(b) 大致滿足），但要注意兩件事：
- 那是 A-7 的功勞，T-11-A 只是**用**了它留下的 seam（`isProgrammed`）。
- **OVS 平面的靜默沒修**：`Controller.cpp:55` 靠「200 body 裡有沒有 error」判失敗，
  Ryu 不放 error ⇒ OVS 上被拒的規則**根本不會進 `DispatchOutcomeLog` 的 failed 計數**，
  它會被記成 **succeeded**，於是 `isProgrammed(token)` 回 true，**幽靈照樣被服務出去**。
  🔴 **這是本次驗證最重要的單一發現，見 §4(b)。**

**一個小缺口**：`stripUnprogrammedEntries` 的 docstring 明寫
「@return How many rows were withheld, so a caller can log or assert on it」，
而 `getOpenFlowTables()`（`:1975`）**把回傳值丟掉**。⇒ 沒有任何地方看得出「視圖正在扣住東西」。
predicate 沒接上時的預設是「扣住每一列」，那個狀態從外面**完全看不出來**。

---

## 3. 變異式驗證（mutation-style verification）

### 3.1 08-31 隨改動附上的測試

`tests/test_PendingEntryFilter.cpp`（新檔，218 行，8 個 TEST）：

```
PendingEntryFilterTest.APendingEntryIsWithheldUntilConfirmed
PendingEntryFilterTest.AConfirmedEntryIsServedAndLosesItsStamp
PendingEntryFilterTest.PolledEntriesAreNeverTouchedEvenWhenNothingIsConfirmed
PendingEntryFilterTest.TheFilterIsKeyedOnProvenanceNotOnLookingLikeARequest
PendingEntryFilterTest.AnUnwiredPredicateWithholdsRatherThanRestoresThePhantom
PendingEntryFilterTest.MalformedShapesAreLeftAloneRatherThanThrowing
ProgrammedTokenTest.OnlyASouthboundSuccessConfirmsAToken
ProgrammedTokenTest.ForgettingATokenHidesARealEntryRatherThanShowingAPhantom
```

雙向都斷言（力紅：未確認要被扣住；力綠：已確認要出現、poll 來的列一根寒毛都不能動）。

### 3.2 我能不能實跑它 ⇒ **不能。UNVERIFIED（未執行）**

C++ 測試需要 build，而 brief 的硬限制是 **NO builds**（可能有 CPU 敏感量測在跑）。
我**沒有**執行 `cmake --build`／`ninja`／`make`，也沒有用 `g++` 單檔編譯繞過去。
⇒ **本節對 C++ 測試的判斷全部是讀碼，不是執行。**

### 3.3 🔴 讀碼發現的真正問題：**這 8 個測試，對「把修拆掉」是瞎的**

這比「我跑不了」重要得多。看測試檔的 include（`tests/test_PendingEntryFilter.cpp:23-26`）：

```cpp
#include <gtest/gtest.h>

#include "ndt_core/routing_management/DispatchOutcomeLog.hpp"
#include "ndt_core/routing_management/PendingEntryFilter.hpp"
```

**就這兩個。** 測試從頭到尾**沒有構造 `DeviceConfigurationAndPowerManager`、沒有呼叫
`getOpenFlowTables()`、沒有碰 `HttpSession`**——它直接呼叫純函式 `stripUnprogrammedEntries(tables, pred)`。

⇒ 這個修有**三個接線點**，而**三個全都沒有測試**：

| # | 接線點 | file:line | 拆掉它會怎樣 |
|---|---|---|---|
| W1 | `getOpenFlowTables()` 呼叫過濾器 | `src/.../DeviceConfigurationAndPowerManager.cpp:1975` | 幽靈**立刻全面回來** |
| W2 | `main.cpp` 接上 predicate | `src/main.cpp:389` | predicate 空 ⇒ 保守預設「扣住每一列」⇒ 視圖少報（不是幽靈回來，但是 outage） |
| W3 | `HttpSession` 把 token 蓋到快取列上 | `src/ndt_core/http/HttpSession.cpp:1155-1162` | 列沒有 token ⇒ 被當成 poll 來的真列 ⇒ **幽靈完整回來** |

**把 W1 或 W3 刪掉，`tests/test_PendingEntryFilter.cpp` 的 8 個測試全部照樣綠。**
（因為它們測的是那顆純函式，而純函式沒被改。）

🔑 這正是本專案記憶 `existence-is-not-wiring` 的形狀：**東西存在 ≠ 東西接上了。**
單元測試證明的是「這條規則寫對了」，**不是**「這條規則有在跑」。

### 3.4 那「T1–T5 全紅」是假的嗎？——不是，但它們量的是別的東西

`91e7743` 的 commit message 寫 `T1-T5 red, C1 green, full suite 655/655`，
工單 `T-11_programmed-only-table-view.md` 有 verdict 表。變異的錨點是**過濾器內部**
（「filter never withholds」「untokened rows withheld too」「internal stamp not stripped」
「isProgrammed always true」「a refused rule confirms its own token」）。
⇒ 這五個變異**都改在被測的那顆純函式裡**，所以會紅是合理的、我沒有理由懷疑那張表。

**但它們證明的範圍就到那顆函式為止。** 三個接線點不在任何一個變異的射程內。

📌 工單自己也記了一個誠實的細節，值得肯定：**T5 第一次跑回來是 `SKIP — pattern matched 0 times`**
（錨點縮排 12 空格、碼是 8），重跑才 RED。「SKIP 不等於 PASS」被明講。

harness 已於 `179adae0` 移出 scratchpad（`doc/audit/2026-08-30_a7-dispatch-visibility/mutation-harness/`），
所以那些 verdict **事後可重跑**——但重跑要 build，本輪不做。

### 3.5 live 驗收：**這一半是真的跑了，而且控制組放對位置**

`44d586f6` 的 raw 檔是本次驗證裡**最有份量的證據**，因為它有**同配方、兩顆 binary**的對照：

| 檔 | binary | 配方 | 結果 |
|---|---|---|---|
| `forcered_port999.log` | **pre-T-11 `a40e04ce`** | port 999（會被拒） | 🔴 **t=0.005 幽靈現**（request-shape、41 列），t=1.274 消失 |
| `p5_port999.log` | **T-11 binary** | **同一個** port 999 配方 | ✅ **全程 25.0 s 不現**（`first_sighting=never`） |
| `green_baseline.log` | T-11 binary | 合法規則 port 2 | ✅ t=0.272 現（request-shape）、t=7.630 轉成 polled-shape ⇒ 沒有把真列一起殺掉 |

⇒ **儀器有鑑別力**（同一個配方在舊 binary 上會抓到幽靈），
**修在活系統上確實把幽靈移出視圖**（同配方、新 binary、25 秒不現），
**而且沒有變成 outage**（合法規則照常出現）。

兩顆 binary 的身分可以從 log 裡的回應字串自我佐證：`forcered` 的 `detail` 是舊版
（「not in this response」），另兩個是 T-11 版（「readable afterwards from
GET /ndt/get_flow_dispatch_status」）——**不是只靠檔名宣稱**。

⚠️ **兩個必須跟著一起講的但書**（工單 `73dd2926` 自己補的，我核對過原文）：
1. **這批 acceptance 跑在 `tr5-energy` 的量測窗內**（22:24–00:24，窗規定 `NO git commit repo-wide`／
   `do not start a compile`）。污染的是**別人的能耗資料**，不是本修的功能結論——但這件事本身
   已被記進 `WINDOW-VIOLATION_evidence.md`，引用本修時不該省略。
2. **`green_baseline.log` 顯示合法規則仍以 request-shape 顯示 7.4 s**（t=0.272→t=7.630）。
   ⇒ 本修移除的是**從未被編程的幽靈**，**不是**「會被編程的規則以請求形狀顯示」那個窗（FINDING-07 地盤）。
   工單原文：「The force-red run alone would support a stronger claim than the evidence does.」

### 3.6 我實跑的變異閘：把「接線」這個缺口補成可執行的紅／綠

既然 C++ 那半跑不了，我把**接線缺口**本身做成一個 `tests/python/` 底下的守衛
（純標準庫、`python3` 直跑、`l1_unit_tests.sh:291` 會自動收），**然後對它跑真的變異閘**。

驅動腳本：`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/254e6209-ad64-4371-9042-829d52c1575f/scratchpad/b1_mutation_gate.sh`
（每個變異都斷言自己的錨點**恰好命中一次**——命中 0 次會讓碼原封不動、然後報 GREEN，
那讀起來跟「變異存活」一模一樣，正是 T-11 工單自己的 T5 踩過的坑。）

> 🔴 **更正（本輪稍後，coordinator 實跑退件）：這一版的變異表不足，結論不要引用這一節。**
> 只有 3 個變異（刪掉／拔線／換參數），**漏了「把呼叫註解掉」**——而那一版守衛用字串比對，
> **註解掉會存活（rc=0，5/5 綠）**。我已重現該存活並改寫守衛成剖析敘述。
> **完整且現行的變異表在 §5.4，共 9 個變異＋3 個控制組**；本節保留只為留下「第一版長什麼樣」的紀錄。
> （保留原文＋標更正，不用 append 覆蓋——讀者要看得出這裡曾經說過比較弱的話。）

~~以下為第一版（已被 §5.4 取代）：~~

```
$ bash b1_mutation_gate.sh        # ← 第一版，已被取代

baseline (unmutated HEAD)                      rc=0   GREEN (survived)
M1 filter call removed                         rc=1   RED (killed)
M2 predicate wire cut                          rc=1   RED (killed)
M3 raw body passed to the cache                rc=1   RED (killed)
C1 unrelated comment reworded                  rc=0   GREEN (survived)
after restore                                  rc=0   GREEN (survived)
```

rc 全部**沒有經過 pipe**（`python3 "$TEST" >file 2>&1; rc=$?`）。
`C1` 是控制組：改一句無關的註解，守衛**必須**維持綠——否則它就不是釘在三個接線點上，
而是會被日常編輯誤殺。

⇒ **M1 與 M3 就是「把 08-31 的修還原掉」**（M1 還原讀出點、M3 還原成 pre-fix 的
`updateOpenFlowTables(j)`）。brief 要求的「還原碼、留著測試、看它變紅」——
**對這個新守衛成立（RED）；對原本那 8 個 gtest 不成立（它們會維持綠，因為構不到接線點）。**

---

## 4. (a)–(d) 檢查表

| | 要求 | 08-31 的改動達成了嗎 | 證據 |
|---|---|---|---|
| **(a)** | twin 的**內部狀態**不得含有被拒絕的規則 | ❌ **沒有** | 幽靈列仍被 push 進 `m_cachedOpenFlowTables`（`installOne`, `DeviceConfigurationAndPowerManager.cpp:2119-2126`），存活到 poll 覆寫（~10.7 s）。且**不是惰性的**：`modifyOne`(:2134)／`deleteOne`(:2158) 走原始陣列，可命中幽靈列 |
| **(b)** | 拒絕必須可觀測（API 欄位＋log） | 🟡 **部分，且不是這個 commit 的功勞** | API：`GET /ndt/get_flow_dispatch_status`（`HttpSession.cpp:638`）有計數器＋`recent_failures[]`。log：`Controller.cpp:55`。**但兩者都由 A-7 `2016d4c0` 提供**。🔴 **OVS 平面上拒絕根本偵測不到**（見下），所以在 OVS 上 (b) 是 ❌ |
| **(c)** | 送出規則的呼叫端要收到 non-2xx 或明確的 `rejected` 結果 | ❌ **沒有** | `HttpSession.cpp:1183-1188` 一律 `200 {"status":"queued","accepted":N,...}`。`body["rejected"]`（`:1195-1202`）**只涵蓋「dpid 不在拓樸裡」這種本地丟棄**，不涵蓋交換機的拒絕。碼裡明寫保留 200 而非 202「因為檢查 exactly 200 的呼叫端會壞」，且逐筆結果要回給原呼叫端需要同步路徑或 completion handle ⇒ 架構決定 |
| **(d)** | 每一項都要有測試 | 🟡 **有測試，但測不到接線** | `tests/test_PendingEntryFilter.cpp` 8 個測試只涵蓋純函式；W1/W2/W3 三個接線點**零覆蓋**（§3.3）。live acceptance 涵蓋了接線，但**需要 fabric、不可能進 CI** |

### 🔴 (b) 底下那個會吃掉整個修的洞：OVS

這是我在本輪找到、而 T-11 工單與 KNOWN-ISSUES 的 🟢 那一列**都沒有講**的一件事。

過濾器的判準是 `DispatchOutcomeLog::isProgrammed(token)`，而 token 只在
`record(job, result)`（`src/ndt_core/routing_management/Controller.cpp:59`）中
`result.ok == true` 時才走 `noteProgrammed_(job.token)`。

`result.ok` 從哪來？從 `HttpRoutingStrategyBase::post()`
（`src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:73-146`）。
🔑 **這個檔自己的註解就把答案寫死在那裡了**（`:116-117`）：

```cpp
    // Some proxies answer 200 with {"status":"error"} in the body. Ryu does not, but the P4
    // proxy agent does, so a 2xx alone is not proof of success.
```

⇒ 走完 `status==0`（unreachable）與 `status<200||>=300`（failure）兩個閘之後，
剩下的只有「body 裡有沒有 `"status":"error"`」這一個判別；Ryu 不放，
所以 OVS 一路落到 `:144` 的 `return OpResult::success(status);`。

- **P4**：proxy 做同步 P4Runtime 寫入，被拒時會在 body 裡放 error ⇒ `ok=false` ⇒ token 不確認 ⇒ **幽靈被扣住** ✅
- **OVS**：Ryu 的 `/stats/flowentry/add` 是 **fire-and-forget**，在交換機裁決之前就回 200、body 裡沒有 error
  ⇒ `ok=true` ⇒ `noteProgrammed_(token)` ⇒ **`isProgrammed` 回 true ⇒ 幽靈被當成已確認、照樣服務出去**

⇒ **在 OVS 上，T-11-A 的過濾器對「被交換機拒絕的規則」沒有作用。**
它擋得住的是「還沒送到」與「南向明確回報失敗」，擋不住「南向謊報成功」。

📌 這**不是**推翻這個修——工單自己已經寫了 **「OVS untested」**，範圍聲明是誠實的。
但 KNOWN-ISSUES 的 🟢 那一列寫「kernel 視圖那一半已修」時沒有帶這個平面限定，
而 B-1 條目上方明寫本缺陷「**平面：兩者**」。
⇒ **讀者會把一個 P4-only 的修讀成兩個平面都修了。**
🔑 這正是記憶 `disclosure-is-not-downgrading` 的形狀：**限制寫在工單裡（揭露），
但引用它的那一行沒有跟著下修（沒有下修）**，而讀者先讀到的是 KNOWN-ISSUES 那一行。

⚠️ **可信度標註**：以上是**讀碼推論**，鏈路是
`PendingEntryFilter.hpp` → `DispatchOutcomeLog::isProgrammed/record` → `OpResult::ok` → `Controller.cpp:55`。
**我沒有在 OVS 上實跑驗證**（無 fabric、且本輪禁止跑 lab）。
B-1 條目的四格表與 `rejected-requests-can-still-act` 記憶都獨立記載了「OVS 上 kernel log 零錯誤行」，
與此推論一致，但**那是 08-18 的觀測，不是對 T-11-A 的觀測**。

---

## 5. 這一輪落的 patch

### 5.1 commit

```
$ git log --oneline -3
b19045b0 Parse statements, not substrings: the guard could not see a commented-out call
7fc77907 Guard the three joints T-11-A's own tests cannot see
4cbec52d Keep the one line that names the restore failure

$ git diff --stat 4cbec52d HEAD
 tests/python/test_t11_filter_is_wired.py | 468 +++++++++++++++++++++++++++++++
 1 file changed, 468 insertions(+)
```

分支 `agent/b-1-verify`（從 `4cbec52d` 長出來）。**沒有 push。**
只動一個新檔，`git commit -- <檔案路徑>`（不是目錄），工作樹提交後乾淨。

### 5.2 🔴 第一版被 coordinator 用一個我沒試過的變異打穿——而且是同一族的洞

第一版的守衛用**原始檔字串比對**。coordinator 實跑了一個我的變異表裡沒有的形狀：

```
$ sed -i '1975s|^|//MUTANT |' src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
$ python3 tests/python/test_t11_filter_is_wired.py ; echo rc=$?
rc=0        ← 5/5 GREEN，變異存活
```

我已在本 worktree **重現過這個存活**（rc=0），再修。

**為什麼會漏**：我的 M1 是**整行刪掉**，所以會紅；而`"stripUnprogrammedEntries(" in text`
**分不出「敘述」與「註解」**。⇒ **M1 紅了，把 M4 的洞擋在後面。**

🔑 **這正是我在 §3.3 用來指控那 8 個 gtest 的同一族缺陷，長在指控它的儀器裡。**
而且**註解掉比刪掉更接近真實的失效方式**——那是有人要「暫時」關掉某個東西時會做的事。
（同族記憶：`instrument-must-not-mimic-its-own-finding`。）

### 5.3 修法：改成剖析敘述，不是比對子字串

比對之前先預處理原始碼：

- 空白化 `//` 行註解、`/* */` 區塊註解、字串／字元／**raw string** 字面量
  （**保長度、保換行**，所以行號與偏移量仍對得上磁碟上的檔）；
- 空白化 `#if 0 … #endif`（處理巢狀，且 `#else`／`#elif` 會重新啟用——那一支是編譯器留下的）；
- `if (false) { … }` **不是用文字擋，是用結構擋**：過濾呼叫必須位於函式本體的
  **brace depth 1**（頂層），包進任何條件區塊就會變成 depth 2。

⚠️ **raw string 在這裡是實際危害不是理論危害**：
`HttpSession.cpp` 有 **31 個** `R"({"error":...})"`（**字面量裡有大括號**，會毀掉深度計算），
`DeviceConfigurationAndPowerManager.cpp` 有 **9 個** regex raw string；
而**兩個檔都在組 curl 指令、字串裡有 `http://`**——**一個不是註解的 `//`**。
天真的 stripper 會把後面整段碼吃掉。

⇒ **預處理器本身變成了承重元件，所以它自己也要有測試**：
`SourcePreprocessorTest`（10 個案例）就打這些實際存在的危害。
在三個真檔上的煙霧測試：長度與行數皆保持，且**大括號完全配平**（50/50、417/417、286/286）
——若 raw string 沒處理好，這個數字就會歪。

### 5.4 重跑後的完整變異閘

```
=== 0. baseline ===
baseline (unmutated HEAD)                        rc=0   GREEN  as expected

=== A. the filter call in getOpenFlowTables() (W1) ===
M1  call deleted outright                        rc=1   RED    as expected
M4  call commented out with //                   rc=1   RED    as expected   ← 逃掉的那隻
M5  call wrapped in if (false)                   rc=1   RED    as expected
M6  call disabled with #if 0                     rc=1   RED    as expected
C2  call replaced by a comment CONTAINING it     rc=1   RED    as expected

=== B. the predicate injection in main.cpp (W2) ===
M2  predicate wire deleted                       rc=1   RED    as expected
M7  predicate wire commented out with //         rc=1   RED    as expected

=== C. the token stamp in HttpSession.cpp (W3) ===
M3  raw body passed to the cache                 rc=1   RED    as expected
M8  raw body + decoy comment naming annotated    rc=1   RED    as expected

=== D. controls: changes that must NOT kill the guard ===
C1  unrelated comment reworded                   rc=0   GREEN  as expected
C3  decoy comment added, real call INTACT        rc=0   GREEN  as expected

=== E. honest limits ===
M9  predicate always true (gtest T4's job)       rc=0   GREEN  as expected

=== F. restored ===
after restore                                    rc=0   GREEN  as expected
(no output above == all three sources are back to HEAD)
```

rc 全部**未經 pipe**；每個變異都斷言錨點**恰好命中一次**。
守衛本身 **16 tests、0 skips**（`l1_unit_tests.sh` 對 skip 是硬 FAIL，所以這點要顧）。
驅動腳本：`…/scratchpad/b1_mutation_gate.sh`。

**兩個控制組的分工**（coordinator 指定的那個是 C2）：
- **C2**＝真呼叫被換成**內含該呼叫文字的註解** ⇒ **必須紅**。證明守衛不是被註解餵飽的。
- **C3**＝真呼叫**完整保留**、另外加一句含該文字的註解 ⇒ **必須綠**。
  證明守衛也不會因為有人寫了說明註解就誤殺。
  兩個方向都要有，只有 C2 的話守衛可能是「看到註解就紅」。

### 5.5 仍然存活的變異：**M9，而且是刻意的**

`M9`＝把 `main.cpp` 的 predicate 改成 `return true;`（永遠說已編程）⇒ **守衛維持綠**。

**誠實的理由**：那是**語意**不是**接線**。`setProgrammedPredicate(` 仍然被呼叫、線仍然接著，
壞掉的是線那頭送過去的東西。**這正好是 `tests/test_PendingEntryFilter.cpp` 的 T4
（"`isProgrammed` always true"）已經殺掉的變異**，工單記著它是 RED。

⇒ **兩層是互補的：gtest 守規則，本檔守接點。**
若我讓守衛去宣稱它也涵蓋語意，那就是往反方向的同一種誇大。
這一點寫進 docstring 的 "What this file is NOT"，連同另外兩個它看不到的形狀
（`stripUnprogrammedEntries` 被改寫成 no-op、確認索引本身錯誤）。

### 5.6 這個 patch 做什麼、不做什麼

**做**：把 §3.3 指出的三個接線點釘住，讓「過濾器被悄悄拔線／註解掉／用 `if (false)` 或
`#if 0` 關掉」在 CI 裡會紅。`l1_unit_tests.sh:291` 已經用 glob 收 `tests/python/test_*.py`，
**不需要改任何 harness**。

**不做**：它讀的是**原始碼文字**，證明「呼叫寫著而且可達」，**不證明「它算得對」**。
要行為級地測這三個接點，得讓 C++ 測試去構造 `DeviceConfigurationAndPowerManager`
（背景執行緒＋topology monitor＋classifier）——**那正是當初把過濾器抽成純函式要避開的東西**，
所以這是個真的取捨，不是偷懶。

### 5.3 為什麼 (a)(b)(c) 我只設計、沒有實作

brief 說「(a)–(c) 若小就實作」。三個都**不小**，而且**在本輪的限制下不可驗證**：

| | 為什麼不做 | 要做的話該怎麼做 |
|---|---|---|
| **(a) 狀態不得含被拒規則** | 需要**南向 worker 執行緒**在 `record()` 判定 `!ok` 之後**回頭去改快取**。那是新的跨執行緒相依（`Controller`／`FlowDispatcher` → `DeviceConfigurationAndPowerManager`），要動 `m_openflowTablesMutex` 的取用順序，而目前 `DispatchOutcomeLog` 是刻意不認識 power manager 的。**改完我 build 不了、測不了。** | 兩個選項：①**驅逐**——失敗時以 token 為鍵把該列從快取移除（要新的 evict API＋鎖序分析）；②**惰化**——保留列但讓 `updateOpenFlowTables` 的 `modifyOne`／`deleteOne` 跳過未確認的 tokened 列（小得多，且不碰執行緒，**這是我建議的第一步**）。②可以用跟 `stripUnprogrammedEntries` 一樣的手法抽成純函式，於是可單元測試。 |
| **(b) 拒絕可觀測** | P4 上**已經有了**（A-7）。缺的是 **OVS 偵測不到拒絕**，而那要嘛在 Ryu 之後補一次 read-back 對帳、要嘛用 OpenFlow barrier ⇒ **跨 repo、跨平面**，且非跑 fabric 不能驗。 | 最小可行：install 後排一次「讀回來確認」的非同步核對，只對 OVS 開；或在 `OpenFlowRoutingStrategy` 明確標示「本平面的 `ok` 不代表交換機接受」，讓 `isProgrammed` 對 OVS 一律回 false（保守方向，代價是 OVS 視圖延遲 ~10.7 s 才顯示新規則）。**這是裁決題，不是實作題。** |
| **(c) 呼叫端收到拒絕** | 碼裡已明寫需要 synchronous path 或 completion handle，且 200→202 會弄壞「檢查 exactly 200」的呼叫端。**架構決定。** | 不要動狀態碼；加一個 `request_id` 回給呼叫端，讓它拿去查 `GET /ndt/get_flow_dispatch_status`。目前 `DispatchOutcomeLog::Record` 有 `seq` 但**沒有暴露 token**，所以呼叫端無法把自己的請求對上某一筆失敗——補這個關聯是小改動，但仍需 build。 |

📌 另有一個**真的很小**的缺口，我也沒動，因為同樣需要 build：
`getOpenFlowTables()`（`:1975`）把 `stripUnprogrammedEntries` 的回傳值（扣住了幾列）丟掉。
把它記進 log 或加進 dispatch-status 的 counters，就能讓「視圖正在扣住東西」變成可觀測，
也讓 (b) 的 W2 失效模式（predicate 沒接上 ⇒ 全部扣住）不再是靜默的。

---

## 6. 我沒有驗證的 ＋ 下一個人要做什麼

### 6.1 明確沒有做的事（照 brief 的硬限制）

- **沒有 build**（沒跑 `cmake --build`／`ninja`／`make`，也沒有用 `g++` 單檔編譯繞過去）。
- **沒有跑 Mininet／fabric／bmv2／`ndt`／lab claim／sudo**，沒有用 `pkill -f`／`pgrep -f`。
- **沒有動主 worktree** `/home/adam/Desktop/NDTwin-Kernel`，**沒有 push**。
- 沒有讀任何 `.jsonl`。

### 6.2 因此以下**全部是讀碼，不是實測**

1. 🔴 **OVS 上過濾器失效**（§4 (b)）——鏈路四段全部讀過並引了行號，且 `HttpRoutingStrategyBase.cpp:116-117`
   的註解直接佐證，但**沒有在 OVS 上實跑**。
   **這是本輪最需要人去實測的一件事。**
2. **狀態污染的下游後果**（§2.3 ②，`modifyOne`／`deleteOne` 會命中幽靈列）——讀碼認定，
   **嚴重度未量**，且被既有的 match-key 字彙錯配壓低。
3. **T1–T5 的 verdict 表**——我沒有重跑（要 build）。harness 在
   `doc/audit/2026-08-30_a7-dispatch-visibility/mutation-harness/`，可重跑。

### 6.3 建議人類接手的順序

1. **（最高）在 OVS 上跑 08-31 那個 force-red 配方。**
   配方現成：`doc/audit/2026-08-31_live-acceptance-batch/probe.py`，把 `KERNEL` 指向 OVS 那套，
   送一條 OVS 會拒的規則（B-1 四格表：**不帶 `ip_proto` 的 `tcp_dst`**）。
   **預期（依我的讀碼）：幽靈仍然出現。** 若真如此，KNOWN-ISSUES 的 🟢 那一列要加平面限定。
   若沒出現，那我的推論錯了，該回頭查 `OpenFlowRoutingStrategy` 有沒有別的判別。
2. **跑一次 `l1_unit_tests.sh`**（需要 build）確認新守衛在完整 harness 下被收到、且不影響既有計數。
3. 決定 (a) 走「驅逐」還是「惰化」（我建議惰化，理由見 §5.3）。

---

## 7. 給 Adam 的裁決：兩個選項與各自的後果

**先把事實壓縮成一句**：08-31 的改動**把幽靈移出了視圖，而且在 P4 上是真的移出去了、
live 雙向驗過、控制組放對位置**；但它**沒有清掉內部狀態**，**沒有改變呼叫端收到的答案**，
**而且（讀碼）在 OVS 上根本不會生效**。

### 選項一：**把 08-31 認定為 B-1 的修**

- ✅ **站得住的部分**：P4 平面上，三個消費者（API／LLMAgent／IntentTranslator）都不再看到幽靈；
  同配方兩顆 binary 的 live 對照（`forcered_port999.log` vs `p5_port999.log`）是這個 repo 少見的
  乾淨證據；範圍聲明（"Not covered"）誠實且事後被補上。
- ⚠️ **代價**：
  - KNOWN-ISSUES B-1 標著「**平面：兩者**」，而這個修（依讀碼）**只在 P4 生效**。
    認定為修 ⇒ **一個 P4-only 的修被記成兩平面的修**，這正是 `disclosure-is-not-downgrading`
    那一族：限制寫在工單裡，但引用它的那一行沒下修。**至少要把 🟢 那一列加上平面限定。**
  - 內部狀態仍相信被拒的規則 ⇒ 未來任何**新的**快取消費者只要不經過 `getOpenFlowTables()`
    就會再看到幽靈，而**現有測試抓不到**（本輪新增的守衛只釘現有三個接點）。
  - **(c) 完全沒動**：呼叫端仍然一律收 `200 {"status":"queued"}`。B-1 標題說的是
    「twin 當成存在的來服務」，若把「服務」理解成也包含**回給呼叫端的答案**，那這一半沒修。

### 選項二：**(a)–(d) 齊了才算修**

- ✅ 得到的是一個口徑乾淨、兩平面都成立的關閉。
- ⚠️ **代價**：(c) 已被碼與工單兩次認定為**架構決定**（同步南向路徑或 completion handle，
  且牽動「檢查 exactly 200」的既有呼叫端）；(b) 的 OVS 半要跨 repo 碰 Ryu 的確認語意。
  ⇒ **這不是一兩天的事，而 B-1 會在清單上繼續掛著 OPEN**，
  而它「示範時會不會踩到」的實際機率**低**（08-18 實測 30 分鐘真實負載 0 次自然發作，
  雖然 F-5 已指出那個取樣格太粗、證據基礎鬆動）。

### 🔑 我的建議：**選項三——拆成兩條，不要整條開也不要整條關**

B-2 已經有先例（「①已修、②原封不動，兩條要分開讀」）。B-1 建議同樣拆：

- **B-1a「kernel 表視圖服務未編程的列」＝ P4 上 RESOLVED**，證據就是 08-31 那三個 log。
  條目上**必須帶平面限定**，並註明 OVS 未驗。
- **B-1b「被拒的規則在 OVS 上仍被當成成功」＋「呼叫端收不到拒絕」＝ OPEN**，
  失效方向仍是**樂觀＋OVS 靜默**。

這樣做的好處是：**它讓「已經做了」這句話停在它真正成立的範圍內**，
而 MEMORY 裡 08-31 那條剛記過——**過期的「已經做了」會主動關掉補救動作**，
比漏寫更貴。

### 這對 F-5 重裁與「要不要解鎖併發控制」的意義

- KNOWN-ISSUES §D 的 F-5 那列寫著「**重裁材料齊備**」，理由是 ①TR-3 已證「窗是時鐘不是負載」
  ②T-11-A 已把幻影移出視圖。**①不受本輪影響。②要打折**：只在 P4 成立。
- 而 F-5 當年「不修」的理由是**發作率低**（30 分鐘 0 次），那個理由已被 F-5 自己
  以「10 秒取樣格對 2–3 秒窗沒有靈敏度」推翻一半。
  ⇒ **如果採選項三**：F-5 的重裁可以在 **P4 這一格**上直接收斂（幻影不再出現 ⇒ 發作率問題消失），
  **OVS 那一格則維持懸而未決**——而 B-1 原本四格表裡，**OVS 正是完全靜默的那一格**。
- **對「要不要解鎖併發控制」**：本輪沒有找到任何把 B-1 與併發控制綁在一起的技術相依。
  T-11-A 的 token 走的是既有的 `m_openflowTablesMutex`（shared_mutex）與 `DispatchOutcomeLog`
  自己的 `mutex_`，**沒有引入新的鎖，也沒有要求解鎖任何東西**。
  ⇒ **如果解鎖併發控制的前置條件是「F-5 已重裁」，那本輪的結論是：
  P4 那一格可以裁，OVS 那一格不行——所以前置條件是否成立，取決於重裁要不要涵蓋兩個平面。**
  🔴 **這一句是我能給的最精確的形式；「要不要涵蓋兩個平面」是 Adam 的裁決，不是我的。**

---

## 附：本輪碰過的檔案（絕對路徑）

- 新增：`/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a678d74f17815d0a6/tests/python/test_t11_filter_is_wired.py`
- 變異驅動（scratchpad，非 repo）：`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/254e6209-ad64-4371-9042-829d52c1575f/scratchpad/b1_mutation_gate.sh`
- 讀過的關鍵碼：
  - `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`（`:1893` poll 覆寫、`:1944` setter、`:1970-1976` 讀出口、`:2018-2186` 寫入路徑）
  - `src/ndt_core/http/HttpSession.cpp`（`:170` 路由、`:622` 表格端點、`:638` dispatch-status handler、`:1155-1162` token 蓋章、`:1157` 寫快取、`:1183-1202` 回應）
  - `src/main.cpp:389`（predicate 接線）
  - `src/ndt_core/routing_management/Controller.cpp:59`（`outcomes_.record`）
  - `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:73-146`（🔴 OVS 判別的根）
  - `include/ndt_core/routing_management/PendingEntryFilter.hpp`、`DispatchOutcomeLog.hpp`、`OpResult.hpp`
  - `tests/test_PendingEntryFilter.cpp`（8 個 TEST，`:23-26` 的 include 是關鍵）
- 讀過的證據：`doc/audit/2026-08-31_live-acceptance-batch/{forcered_port999,green_baseline,p5_port999}.log`、`probe.py`；
  `doc/audit/2026-08-30_a7-dispatch-visibility/T-11_programmed-only-table-view.md`；KNOWN-ISSUES B-1 與 §D 的 F-5 那列
