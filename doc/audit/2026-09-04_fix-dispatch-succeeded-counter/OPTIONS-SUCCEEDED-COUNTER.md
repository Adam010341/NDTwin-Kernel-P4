# W4／#54：`counters.succeeded` 要回答哪一個問題——兩個選項，給 Adam 裁

工單：`scratch/overnight-2026-09-04/recon/fixplan.md` §W4。
Adam 交辦明寫：**這一輪只交選項與代價，不動碼。** 本文件沒有改任何 `.cpp`／`.hpp`。
寫的人：夜巡「修法 agent」session。日期：2026-09-04。

[Co-developed with claude code -- Adam]

---

## 0. 一句話

`succeeded` 數的是「**南向接受了幾個 job**」，使用者把它讀成「**交換機上多了幾條規則**」。
同一個 match 裝 20 次＝20 個 `succeeded`、1 條規則（今晚 round4 `12_` 實測，比值 20.00／對照組 1.00）；
刪一條不存在的規則 15 次＝15 個 `succeeded`、0 個變化。
**這個數字沒有壞，是它回答的問題和被問的問題不是同一個。**

## 1. 座標（🟢 我這一輪自己開檔核對過的行號，對 trunk `f943de8f`）

| 位置 | 內容 |
|---|---|
| `include/ndt_core/routing_management/DispatchOutcomeLog.hpp:99` | `void record(const FlowJob&, const OpResult&)` |
| 同上 `:105` | `succeeded_.fetch_add(1, …)`——**唯一的累加點** |
| 同上 `:106-113` | 既有註解「**Counting is deliberately unchanged**」（C-4 的裁決寫在碼裡） |
| 同上 `:114` | `if (result.confirmsProgramming) { noteProgrammed_(job.token); }`——**只 gate 表格視圖，不 gate 計數** |
| 同上 `:145` | `uint64_t succeeded() const` |
| 同上 `:256-258` | `dispatched_`／`succeeded_`／`failed_` 三個 `std::atomic<uint64_t>`（同區另有 `evicted_`／`forgotten_`） |
| `include/ndt_core/routing_management/OpResult.hpp:76` | `bool confirmsProgramming = false` |
| `src/ndt_core/routing_management/Controller.cpp:66` | `outcomes_.record(job, result);`——🟢 **生產碼唯一呼叫端**（`grep -rn 'outcomes_\.record' src/ include/` ⇒ 1 命中） |
| `src/ndt_core/http/HttpSession.cpp:753` | `handleGetFlowDispatchStatus` |
| 同上 `:779-782` | JSON `counters.dispatched／succeeded／failed／dropped_after_stop` |

⚠️ **W1（#87）的六條 group/meter 路徑不經過 `record()`**——只有 flow 走。
#54 與 #87 是兩個獨立的計數／宣稱問題，不要合併處理。

## 2. 🔴 兩件我查出來、會直接改變代價估算的事實

### 事實 1：`succeeded` **今天沒有任何外部消費者**

🟢 我掃了本機八個 repo（`Energy-Saving-App`、`Traffic-Engineering-App`、
`Network-State-Recorder`、`Network-Traffic-Visualizer`、`Simulation-Platform-Manager`、
`Web-GUI`、`NDTwin-Website`、`Network-Traffic-Generator`）：

- `get_flow_dispatch_status` ⇒ **0 命中**（全部八個 repo，不限副檔名）。
- `succeeded` 的命中只有三處，**全部與這個欄位無關**：
  `Energy-Saving-App/src/app/http.cpp:447,483` 與 `Traffic-engineering-App.py:74,87` 是
  log 字串 `"acquire_lock succeeded"`；`Network-Traffic-Visualizer/…/PlaybackPanel.java:801,945`
  是 JavaFX `Task.succeeded()` 覆寫。

⇒ **選項 A 的「改對外契約」代價，在今天等於零**（只讀不改那些 repo，我沒有動它們）。

### 事實 2：這個端點**根本不在 API 文件裡**

🟢 `grep -n 'flow_dispatch_status\|counters' doc/2026-01-02_ndt_api.md` ⇒ **0 命中**。
`doc/2026-01-02_ndt_api.md:2607` 那個 `succeeded` 是 `renew_lock` 章節裡的英文動詞。
這個端點只出現在 `doc/KNOWN-ISSUES.md:554/602/632/656` 與 audit 文件裡。

⇒ **選項 A 的「把理由從碼裡搬到 API 上」其實是「第一次把這個端點寫進 API 文件」**，
   比工單估的**多一點**工（要新增一節），但**少一點風險**（沒有既有措辭要改）。

### 真正的消費者只有契約測試

`tools/contract_test/spec.py:353-357` 的 `DISPATCH_STATUS` schema，與 `:838` 的
`inv_dispatch_counters_close`——**它斷言 `dispatched == succeeded + failed`**。
🔴 **兩個選項都不准打破那條恆等式**：它是「沒有任何路徑只加一個計數器」的最便宜證明。
改 key 名字要同步改 schema；新增計數器**不可以**加進那條加法。

---

## 3. 選項 A：不改語意，改名字＋補文件（擋板）

**做什麼**

1. `counters.succeeded` → `counters.accepted_by_controller`（或保留 `succeeded` 並**並列**新 key 一段時間）。
2. `doc/2026-01-02_ndt_api.md` 新增 `GET /ndt/get_flow_dispatch_status` 一節，明寫：
   *「這是被南向接受的 job 數，不是交換機上的規則數。同一個 match 裝 20 次算 20 次；
   刪一條不存在的規則也算成功。要知道交換機上有幾條規則，這個端點答不出來。」*
3. `tools/contract_test/spec.py:353-357` 與 `:838` 同步。

**代價**

- 對外契約變更 ⇒ 🟢 **今天沒有消費者**（§2 事實 1），所以只有契約測試要跟著改。
- 🔴 **不解決任何量測問題**：外部仍然無從得知交換機上有幾條規則。
  #54 的嚴重性欄（「規則 churn 之下，外部無從得知交換機上到底有幾條規則」）**原封不動**。
- 好處：零執行期風險、不動 hot path 的 atomic、**一小時內做得完**。
- ⚠️ 併排兩個 key 的話要訂一個移除日期，否則就是永遠兩個。

**測試／閘門**：`tests/test_DispatchOutcomeLog.cpp` 加
`TheSameMatchDispatchedTwentyTimesCountsTwentyAcceptances`——**把 #54 的觀測釘成規格**
（現在的行為是對的，只是被誤讀）。閘門：把 key 改回舊名要紅；
加一個對照（重排 JSON key 順序要留綠）。

## 4. 選項 B：讓計數回答「交換機上變了幾條」（結構）

**做什麼**：`record()` 旁新增第二組計數，語意是「**被觀測到生效的**」
（`programmed_`／`no_change_`／`unknown_`），資料來源是 `OpResult::confirmsProgramming`
（`OpResult.hpp:76`，P4 true／OVS false）。`succeeded` 原意不動。

**代價**

- 🔴 **OVS 上這個新數字現在恆為 `unknown`**——`confirmsProgramming` 在 OVS 是 false，
  那是 C-4 的整個重點（`DispatchOutcomeLog.hpp:106-113` 的註解就是在講這件事）。
  ⇒ B **在今天的 OVS 上不會給出答案**，只會誠實地說「不知道」。
  那本身比 20.00 有價值，但**要等 W-OF-BARRIER 才變成真的數字**。
  ⚠️ 這正是這個 codebase 反覆出現的「儀器長得像自己的發現」形狀：
  一個永遠 `unknown` 的欄位，會被下一個人讀成「查過了、沒事」。
- **要先裁「重複裝同一個 match」算什麼**：交換機上是覆蓋（+0 條），
  呼叫端的意圖是「這條規則要在」。`no_change` 與 `failed` 不是同一件事，
  而**這一裁決會決定 `programmed_ + no_change_` 能不能對得上任何東西**。
- 動到 dispatch hot path 的 atomic（多一次 `fetch_add`）——量級可忽略，但要寫進 FIX 文件。
- 🔴 **不可以把新計數器加進 `dispatched == succeeded + failed`**（§2）。
- 工作量 **1–1.5 天**，且**要等 W-OF-BARRIER 才完整**。

**測試／閘門**：`ADispatchTheFarEndCannotConfirmIsNotCountedAsProgrammed`；
閘門必須有「把 `confirmsProgramming` 忽略掉、OVS 也記 programmed」的變異（M1）
與一個對照（改名不改語意要留綠）。

## 5. 我的建議（**是建議，不是決定**）

**A 先做（一小時內），B 併進 W-OF-BARRIER 一起排。**
理由：B 的核心數字在 OVS 上今天算不出來；先做 B 會產出一個「永遠 unknown」的欄位。
而 §2 的兩個事實讓 A 比工單估的更划算：**沒有消費者要改**、
而且順手把一個**從來沒進過 API 文件的端點**寫進去。

⚠️ 但 A **不解決 #54 的嚴重性**。如果 Adam 要的是「外部能知道交換機上有幾條規則」，
**A 不是那個答案**，它只是讓現在這個數字不再被誤讀。

## 6. 可達性口徑

**產線走得到，而且今晚已經量到**（round4 `12_`，比值 20.00／對照組 1.00；
switch 側走 proxy 的 P4Runtime **讀**、不是寫入的那個 API）。
🟠 那是別人跑的（今晚 auditor／round4），我沒有複驗；
本文件裡標 🟢 的是我這一輪自己跑的唯讀 grep 與開檔核對。

## 7. 這一輪沒做的事

- **沒有動任何碼**（Adam 交辦如此）。
- 沒有查 `Web-GUI` 以外的網頁前端有沒有透過別的名字讀這個端點——
  我掃的是端點名與 key 名，**若有人把 URL 組字串拼出來（`"get_flow" + "_dispatch_status"`），
  我的 grep 看不到**。八個 repo 對子字串 `flow_dispatch` 只有一個命中，
  而那一個是 `NDTwin-Website/.github/workflows/hugo.yaml:6` 的 `workflow_dispatch:`
  （GitHub Actions 的觸發器，剛好把 `flow_dispatch` 含在裡面）——**不是消費者**。
  ⇒ 這個漏法的機率低，但不是零。
