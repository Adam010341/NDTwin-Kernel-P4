# W11 — `get_flow_dispatch_status` 的兩組計數與 per-request id（#54／R6 K-4）

分支：`fix/w11-dispatch-status-accepted-counters`（base＝trunk `1536ff17`）。日期：2026-09-06。
工單：`scratch/overnight-2026-09-05/fix/TICKETS-0906/W11-dispatch-status-two-counters.md`。
裁決：DECISIONS 18:1x「W4／#54 **A＋B 都做**」＋第五輪「per-request id 進 W11 ✓」
＋第五輪誠實度第四件「`recent_failures` 環改跟批次同大或可設」。

🔴 **這份文件描述的是分支，不是 `trunk`。** 未併、未推。

[Co-developed with claude code -- Adam]

---

## 0. 一句話

`succeeded` 是一個**正確的數字配一個錯誤的名字**——它數「我發出去了」，而每一個讀它的人
都把名字補成「交換機收下了」。W11 把名字改誠實（A）、加一組**真的在回答那個問題**的計數（B），
並讓呼叫端問得出「**我這一次的** POST 怎麼了」（request id）。
🔴 **B 在今天的 OVS 上永遠回 `unknown`，而那就是正確答案**；修法的一半工作是讓那個 `unknown`
不會被讀成「查過了、沒事」。

## 1. 修了什麼（機制一句話＋檔:行）

| # | 機制 | 檔案 |
|---|---|---|
| A | JSON 鍵 `counters.succeeded`／`failed` → `dispatched_ok`／`dispatch_failed`；舊鍵**移除**，body 留一版 `renamed_keys` 麵包屑 | `src/ndt_core/http/HttpSession.cpp`（`dispatchCountersJson`／`handleGetFlowDispatchStatus`） |
| B1 | `OpResult` 多一個 bit `confirmsNotProgrammed`＋`withProgrammingRefused()`：「這個回答是『交換機沒有這條規則』的證據」 | `include/ndt_core/routing_management/OpResult.hpp` |
| B2 | `post()` 在**兩條「對方答了、但答的是拒絕」**的路徑上掛上那個 bit，值來自既有的 `successConfirmsProgramming()` | `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp` |
| B3 | `DispatchOutcomeLog` 新增 `SwitchOutcome` 三態＋三個 atomic，`record()` 對**每一筆** dispatch 分類一次 | `include/ndt_core/routing_management/DispatchOutcomeLog.hpp` |
| B4 | body 新增 `switch_outcome{accepted_by_switch, rejected_by_switch, unknown, why_unknown}` | `HttpSession.cpp`（`switchOutcomeJson`） |
| C1 | `FlowJob` 多一個 `requestId`；`processFlowBatch` 每一批鑄一個 id、蓋在每個被接受的 job 上、**enqueue 之前**先登記，並在 200 body 回 `request_id` | `include/ndt_core/routing_management/FlowJob.hpp`、`HttpSession.cpp` |
| C2 | `DispatchOutcomeLog` 有界的 per-request tally（`noteRequestEnqueued`／`tallyFor`／`requestsForgotten`），`Controller::noteRequestEnqueued` 是唯一的窄寫入口 | `DispatchOutcomeLog.hpp`、`include/ndt_core/routing_management/Controller.hpp` |
| C3 | 路由改用 `utils::pathIs`，`?request_id=<id>` 走 `respondToDispatchStatusRequestId`（400／404／200） | `HttpSession.cpp`、`include/ndt_core/http/HttpSession.hpp` |
| D | `recent_failures` 環 256 → **2000**（＝`FlowDispatcher` 的 `burstSize`），仍可由建構子覆寫 | `DispatchOutcomeLog.hpp`（`kDefaultCapacity`） |
| E | 契約：schema 兩種拼法都收、`inv_dispatch_counters_close` 兩種都讀、新增 `inv_switch_outcome_closes` | `tools/contract_test/spec.py`、`selftest_fixtures.py` |

### 兩個各自閉合的加法，刻意不合併

```
counters.dispatched == counters.dispatched_ok + counters.dispatch_failed      （對方收了嗎）
counters.dispatched == accepted + rejected + unknown                          （交換機那邊呢）
```

第二組**不是**第一組的細分：一筆 dispatch **成功**而在交換機那邊**未知**是常態，不是矛盾。
把新計數加進第一條加法會毀掉「沒有任何路徑只加一個計數器」這個最便宜的證明
（09-04 選項文件 §2 已經先劃過這條紅線）。`dropped_after_stop` 兩邊都不在——那些 job 從未被嘗試。

### 為什麼是「兩個 bool」而不是一個三態

`confirmsProgramming`（C-4 既有）與 `confirmsNotProgrammed`（本次新增）在**不同的程式路徑**上
由**不同的事實**設定，而 `(false, false)` 正是 OVS 上的答案、必須表示得出來。
一個三態 enum 會逼呼叫端在兩個桶之間選一個，而對一個什麼都不裁決的平面，兩個都是錯的。
兩個 bit 永遠不會同時為真（一個在 `post()` 的成功 return、一個在它的兩條拒絕 return），
這件事是**斷言**出來的不是假設的：`DispatchOutcomeLogTest.TheTwoSwitchSideBitsAreNeverBothSet`。

### 為什麼舊鍵直接移除

七個 app repo（ESA／Web-GUI／TE-App／Visualizer／NSR／SPM／NTG）對
`get_flow_dispatch_status`、`flow_dispatch`、`recent_failures`、`dispatcher_running`、
`counters_cover` **全部 0 命中**（🟢 2026-09-06 自己跑的唯讀 grep；09-04 另一輪掃過含官網的
八個 repo，結論相同）。唯一的 in-repo 消費者是 `tools/contract_test`，而它現在兩種拼法都收。
⇒ **沒有東西要相容**；而一個把錯誤宣稱寫在名字裡的鍵，只要還在發就還在宣稱。

⚠️ **這個 grep 的漏法**（09-04 那份文件自己記過，仍然成立）：若有人把 URL 用字串拼出來
（`"get_flow" + "_dispatch_status"`），grep 看不到。機率低，不是零。`renamed_keys` 就是為那一格留的。

---

## 2. 🔴 這個修法**不會**做到的事

1. **不會告訴你交換機上有幾條規則。** 第二組計數數的是「幾次 dispatch 被裁決過」，
   不是「表上有幾列」。#54 嚴重性欄那句「外部無從得知交換機上到底有幾條規則」**原封不動**。
2. **在 OVS 上不會給出任何非 `unknown` 的答案，而且不是暫時的。** OpenFlow 不 ack FLOW_MOD
   ⇒ 要等 W-OF-BARRIER（barrier／read-back）才會變成真的數字。
3. **沒有動 `POST /ndt/delete_flow_entry` 的回應。** no-op delete 仍然回 200、逐字相同
   （手冊 §10）。W11 只讓**事後的計數**在 P4 上分得出來。
4. **request id 不跨 kernel 重啟。** 行程內單調遞增，重啟後從 1 開始
   ⇒ 跨重啟的 id 要麼 unknown、要麼指到別的 batch。手冊寫了「不要持久化」。
5. **被 unknown dpid 丟掉的 entry 不在任何計數裡**，因為它們從未成為 job。
   `request_id` 的 `enqueued` 只算被接受的那些；400/404 的 body 才會點名被丟的 dpid。
6. **group／meter 六條路徑不經過 `record()`**（只有 flow 走）⇒ 這一切對它們都不適用。
   那是 W1／#87，另一張單。

---

## 3. 一個永遠 `unknown` 的欄位為什麼不是「儀器長得像自己的發現」

這正是 09-04 選項文件對 B 的警告：「一個永遠 `unknown` 的欄位，會被下一個人讀成
『查過了、沒事』」。這一輪的處理是**把理由和數字綁在同一個 body 裡**，三層：

1. `switch_outcome.why_unknown` — 一句話，永遠在 body 裡，明寫「OVS 上這是每一筆、而且會一直是」
   以及「**這個桶不是從 `dispatched_ok` 推出來的**」。
2. 契約不變量 `inv_switch_outcome_closes` 會在 `why_unknown` 是空字串時**變紅**——
   那句話是欄位，不是裝飾。
3. 閘門的第 1 號變異就是「把 `accepted_by_switch` 從 dispatch 推出來」，
   而契約的第 16 號變異是同一件事在 wire 上的形狀（`accepted > dispatched_ok` ⇒ 不可能）。

**它仍然不是一個答案。** 它是一個誠實的「不知道」，而分辨這兩者是讀者的工作——
所以那句話必須跟著數字走，而不是只留在手冊裡。

---

## 4. 沒有跑過的：live 驗證配方（🔴 這一輪沒有跑）

沒有起過任何 kernel、沒有碰 lab。手冊 §42 的 🆕 欄位是**從原始碼與單元測試**（`DispatchStatusEndpointTest`，
它驅動真的路由表與真的 handler）取得的，**不是從 fabric 上抄的**。欠的那一輪是：

```bash
# 1) A：舊鍵消失、新鍵在
curl -s localhost:8000/ndt/get_flow_dispatch_status | python3 -m json.tool

# 2) C：request id 能歸屬（這是閘門第 17／18 號宣告未覆蓋的那一段）
RID=$(curl -s -X POST localhost:8000/ndt/install_flow_entry \
        -H 'Content-Type: application/json' \
        -d '{"dpid":1,"priority":95,"match":{"eth_type":2048,"ipv4_dst":"10.9.9.8"},
             "actions":[{"type":"OUTPUT","port":2}]}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["request_id"])')
curl -s "localhost:8000/ndt/get_flow_dispatch_status?request_id=$RID" | python3 -m json.tool
#    期望：enqueued=1；complete 由 false → true；counters.dispatched 收斂到 1
curl -s "localhost:8000/ndt/get_flow_dispatch_status?request_id=999999" -o /dev/null -w '%{http_code}\n'   # 期望 404
curl -s "localhost:8000/ndt/get_flow_dispatch_status?request_id=abc"    -o /dev/null -w '%{http_code}\n'   # 期望 400

# 3) B：OVS 上 switch_outcome.unknown == counters.dispatched（恆真）
#    P4 上重跑 R6 K-4：刪一條不存在的規則 ⇒ rejected_by_switch +1（不是 dispatched_ok +1 而已）
curl -s -X POST localhost:8000/ndt/delete_flow_entry -H 'Content-Type: application/json' \
  -d '{"dpid":1,"match":{"eth_type":2048,"ipv4_dst":"10.9.9.9"}}'

# 4) 契約
cd tools/contract_test && ./run_contract_test.py --url http://localhost:8000 \
  --topology <topo.json> --only get_flow_dispatch_status
```

**對帳**：R0 的 W4 探針（`scratch/overnight-2026-09-05/logs/r0-40-w4.log` 那一支）
**讀的是 `succeeded`，在這個分支上會讀到 `null`**。重跑前要改成 `dispatched_ok`——
那是預期中的破壞，也是這個修法唯一已知的下游影響。

---

## 5. 與別的單／文件的交界

- **手冊員今晚的 trunk 提交會衝突**：`doc/2026-01-02_ndt_api.md` §42 是他今天新增的，
  我在同一節裡改。衝突點在 §42 的 body 範例、欄位表、Limits 三段，以及 §9／§10 的兩處 🆕 註記。
  **併的時候以我的分支為準**（它描述的是分支的 wire），但要保留他寫的 🟠 grade 段落與
  `4c9e0be1` 的量測出處——我沒有動那些量測，只在旁邊標了「W11 之後 detail 字串變了」。
- **`tests/shell/mutate_a7_dispatch_status.sh` 沒有動，而且是刻意的**：它的兩個 spec.py anchor
  逐字錨在 `inv_dispatch_counters_close` 的前兩行上，所以那兩行**保持 byte-identical**，
  新的拼法用後面的 fallback 讀。它的第 9 號變異（拿掉 `dispatcher_running`）也還是
  declared-uncovered——我的端點測試**刻意不斷言 `dispatcher_running`**，否則那個變異會
  紅在別的測試名字上，被 A-7 閘門記成 survivor。
- **`tests/shell/mutate_phantom_filter_covers_ovs.sh` 沒有動**：它錨在
  `succeeded_.fetch_add(1, ...)`、`return OpResult::success(status).withProgrammingConfirmed(...)`
  與 `if (result.confirmsProgramming) { noteProgrammed_(job.token); }` 上。
  ⇒ **atomic 的成員名 `succeeded_`／`failed_` 沒有改**（只有 wire 上的鍵名改了），
  **`post()` 的成功 return 一個字都沒動**（新 bit 掛在兩條失敗 return 上），
  `classifySwitchOutcome` 裡新出現的 `if (result.confirmsProgramming)` 是**單行**、
  與那個四行 anchor 不衝突。三個 anchor 的唯一性都用 `str.count()` 逐一驗過。
- **`tools/contract_test/spec.py`**：schema 兩種拼法都收＝故意，因為契約要能描述**部署中**的
  kernel 而不是只有剛建好的那顆。新增 `DISPATCH_STATUS_FOR_REQUEST`，**沒有**註冊成 probe——
  runner 得先 POST 一批 flow 才拿得到 id，那是 mutation，而這個端點的價值就在於 live 上可讀。
- **`doc/KNOWN-ISSUES.md`**：新增 **A-7b**（#54／K-4），並在 **C-4**／**C-4b** 各補一句
  指向它，講清楚 W11 買到的是「可觀測」不是「可判別」。
- **W16（`ndt apps stop/orphans` 列出該 app 的規則）**：如果那張單想「按 app 列規則」，
  `request_id` 是現成的鉤子（一個 batch 一個 id），但**現在沒有任何東西把 app 身分綁到 id 上**。
  沒做，登記在這裡。

---

## 6. 檔案清單

改：
```
include/ndt_core/routing_management/OpResult.hpp
include/ndt_core/routing_management/FlowJob.hpp
include/ndt_core/routing_management/DispatchOutcomeLog.hpp
include/ndt_core/routing_management/Controller.hpp
include/ndt_core/http/HttpSession.hpp
src/ndt_core/http/HttpSession.cpp
src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp
tools/contract_test/spec.py
tools/contract_test/selftest_fixtures.py
tests/test_DispatchOutcomeLog.cpp
tests/test_RoutingStrategies.cpp
tests/test_HttpSessionRouting.cpp
doc/2026-01-02_ndt_api.md
doc/KNOWN-ISSUES.md
```
新增：
```
tests/shell/mutate_dispatch_status_honest.sh
doc/audit/2026-09-06_fix-dispatch-status-honest/FIX-DISPATCH-STATUS-HONEST.md
```
