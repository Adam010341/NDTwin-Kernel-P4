# A-4c — P4 proxy 重啟會靜默摧毀規則，而 twin 不會說

指派 ID：A-4c／fix-design subagent／isolated worktree
工作目錄：`/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a11e762acc26b604d`

---

## 1. Base verification

worktree 建立時的 HEAD 是 `f5db629b update sleeping time`（＝ brief 預警的 `origin/main`
上游狀態）。已依指示 detach 到指定 base：

```
$ git checkout --detach 4cbec52d45bd85e0e972110e35f51693d6ce137f
HEAD is now at 4cbec52d Keep the one line that names the restore failure
$ git log --oneline -1
4cbec52d Keep the one line that names the restore failure
```

交叉檢查：

```
$ sed -n '270p' doc/KNOWN-ISSUES.md
### A-4c 🔴 P4 proxy 重啟會靜默摧毀 bring-up 以來安裝的每一條規則
```

✅ 兩項都符合，base 正確。

**測試直譯器**：本 worktree **沒有** `p4_proxy/venv`（只有主 worktree 有）。依
`python-tests-need-the-venv-interpreter` 記憶，用主 worktree 的直譯器、但 `PYTHONPATH`
指向**本 worktree**——這是唯讀使用，不寫入主 worktree：

```
$ cd <worktree>/p4_proxy && PYTHONPATH=. /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python3 -c "..."
grpc 1.82.1 / nx 3.6.1
tm loaded from <worktree>/p4_proxy/proxy_agent/topology_manager.py   ← 確認載到本 worktree
```

⚠️ venv **沒有 pytest**（同一則記憶）。所以本輪新測試一律 `unittest`，
不是 brief 順口提到的 pytest。

---

## 2. 機制

### 2.1 摧毀：`SetForwardingPipelineConfig` 是那把刀

重啟 proxy 之後，`startup()` 對**每一台**有 `json_path` 的交換機無條件重推 pipeline：

- `p4_proxy/proxy_agent/main.py:189-201` — `for i, client in clients.items(): ... client.set_forwarding_pipeline_config()`
- `p4_proxy/proxy_agent/p4_client.py:294-303` — 該呼叫送出
  `SetForwardingPipelineConfigRequest`，`req.action = VERIFY_AND_COMMIT`

而這個 action 的後果，**這個 repo 自己已經寫下來了兩次，其中一次是實測**：

- `p4_proxy/proxy_agent/p4_client.py:64-65`（mastership 註解）：
  > 「…the impostor's `SetForwardingPipelineConfig` is accepted and **wipes every table**.」
- `p4_proxy/proxy_agent/p4_client.py:320-324`（`write_clone_session` docstring，
  實測 2026-08-16 reconciliation round 2）：
  > 「**a proxy restart re-pushes the pipeline**, and after that commit the P4Runtime
  > server's clone-session bookkeeping is empty…」
- 同一段 `p4_proxy/proxy_agent/p4_client.py:346-349`：
  > 「Restarting the fabric together with the proxy remains good hygiene — **it also
  > clears table state** …」

⇒ **proxy 重啟 → pipeline 重新 commit → 每台 bmv2 的每一張表清空。bmv2 行程從頭到尾沒有重啟。**
這條路徑上沒有任何條件判斷：不比對 pipeline 是否已經一樣（`set_forwarding_pipeline_config`
**沒有設 `req.config.cookie`**，見 :294-303 的欄位清單，所以也沒有可比對的 cookie），
也不看交換機是不是剛剛才被同一份 artifact 配置過。

📌 **同一把刀不只在重啟時揮**：`readopt_switch`（`topology_manager.py:1079`）也推 pipeline，
所以**單台 readopt 會清掉那一台的表**，proxy 完全沒重啟。2026-08-13 已經踩過一次
（`p4_client.py:71-75`：「readopt against a healthy switch wiped its tables, installed
nothing, and reported success」）。任何只認「proxy 行程重啟」的偵測都會漏掉這一半。

### 2.2 帳本：proxy 這邊記的東西是純記憶體，而且重建出來的是「另一份」

- `p4_proxy/proxy_agent/topology_manager.py:577` — `self._installed_routes = {}`。
  `__init__` 裡的一個 dict。**沒有檔案、沒有持久化**。行程結束就沒了。
- `p4_proxy/proxy_agent/topology_manager.py:1008-1066` — `install_initial_routes()`
  在 LLDP 探索完成後**依當下的圖重算最短路**並寫回交換機，同時重填 `_installed_routes`。

⇒ 重啟後看起來「有規則」，但那是**重新算出來的 bring-up 形狀**，不是原本那一套。具體差異：

| 重啟前的狀態 | 重啟後 | 有沒有人講 |
|---|---|---|
| app 把某條 LPM 改到非最短路（TE／ESA 繞流） | **被改回最短路** | ❌ 無 |
| app 刪掉的某條 LPM | **被復活** | ❌ 無 |
| **5-tuple 規則**（`flow_5tuple`） | **完全消失，且永不重建** | ❌ 無 |

最後一列是最硬的：`topology_manager.py:864-877` 的註解**明講** 5-tuple 分支
**故意不寫進 `_installed_routes`**（因為那個 map 是 `(dpid, ipv4_dst) -> out_port`，
單值答案裝不下 5-tuple）。所以 5-tuple 規則在整個系統裡**沒有任何一份紀錄**——
不在 proxy 的 map 裡，不在任何 journal 裡（不存在 journal），
`install_initial_routes` 也只寫 LPM。**它們就是沒了，而且沒有東西知道它們曾經存在。**

### 2.3 為什麼 twin 一行警告都不會有

kernel 這邊「哪些規則存在」的視角有兩層，兩層都不構成「意圖」：

1. **輪詢來的真相**
   `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:1880-1893`
   `openflowTablesUpdateWorker` 每 10 秒呼叫 `fetchOpenFlowTablesInternal()`（:1020-1173），
   對每台 switch 打 `GET /stats/flow/{dpid}`，而 `api_routes.py` 的 `get_flow_stats`
   是**現讀交換機**（`client.read_table_entries()`）。
   ⇒ 重啟後讀到的是**清空後又被 `install_initial_routes` 回填的那一套**。
   這份讀數本身是誠實的；問題是**沒有任何東西拿它跟「被要求過什麼」比對**。

2. **樂觀寫進去的「被要求過什麼」**
   `DeviceConfigurationAndPowerManager.cpp:2018` `updateOpenFlowTables()`，由
   `src/ndt_core/http/HttpSession.cpp:1157` 在 `processFlowBatch` **回完 200 之後**呼叫，
   把請求本身寫進 `m_cachedOpenFlowTables`。
   🔴 **但它是一個 cache，不是 intent store**：`openflowTablesUpdateWorker` 每 10 秒
   用 `m_cachedOpenFlowTables = std::move(newTables)`（:1893）**整個換掉**。
   ⇒ 「曾經被要求過」這件事**最多活 10 秒**，而且從來沒有跟輪詢結果比對過。

⇒ **重啟之後，整個系統裡不存在任何一份「規則 X 被要求過」的陳述。**
沒有比對對象，就沒有差異；沒有差異，就沒有警告。twin 回報 40/40 邊、10/10 up、零警告，
**每一個數字都是對的**——它報的是拓撲健康，而規則集被改寫這件事**不在它的詞彙裡**。

📌 額外一筆（順手發現，非本案，但同一個函式）：`fetchOpenFlowTablesInternal` 裡四條
`continue` 路徑的註解都寫「keeping the previous table」，而 `result` 是每輪**重新建立**的
array、被 skip 的 dpid 根本不會進去，接著 :1893 又整個覆寫 `m_cachedOpenFlowTables`。
⇒ 對 **Classifier** 而言「保留舊表」是真的（`updateFromQueriedTables` 只看得到 `result`
裡有的 switch）；對 **`m_cachedOpenFlowTables`** 而言不是——那台 switch 是**整個從表視圖裡消失**，
不是「保留舊值」。註解與程式碼對其中一個讀者說了不一樣的話。

### 2.4 KNOWN-ISSUES 對帳

brief 要我檢查「規則是不是其實還活在 bmv2 裡、只是 proxy 的帳丟了」。**不是。**

| KNOWN-ISSUES :270-281 的說法 | 對帳結果 |
|---|---|
| 「重啟 P4 proxy（bmv2 沒有重啟）之後 …每一條規則都消失」 | ✅ **成立**。機制是 §2.1 的 `VERIFY_AND_COMMIT`，不是 bmv2 重啟。repo 內有 2026-08-16 實測佐證（`p4_client.py:320-349`）|
| 「twin 回報完整健康恢復：40/40 邊、10/10 up、一行警告都沒有」 | ✅ **成立**，且原因比條目寫的更難修：不是警告被吞掉，是 **twin 沒有可以比對的意圖存底**（§2.3）|
| 「不需要注入任何故障，重啟 proxy 是正常運維動作」 | ✅ **成立** |

**需要補進條目的兩點**（條目沒寫、但會影響修法選擇）：

- 🔴 **「每一條都消失」要加一句限定**：bring-up 形狀的 LPM 規則**會被 `install_initial_routes`
  重算回來**，所以事後去數規則條數**看起來不像全滅**。真正永久消失的是
  **「bring-up 以來的 delta」**——app 的改寫、app 的刪除、以及**全部的 5-tuple 規則**。
  這比「全滅」更難發現，因為表不是空的。
- 🔴 **同一個摧毀路徑不需要 proxy 重啟也會走**：`POST /p4/readopt/{dpid}` 會清掉那一台
  （§2.1 📌）。條目的觸發條件寫窄了。

### 2.5 補充：twin「持續回報已消失的規則」的確切路徑

（`Classifier` 的語意由平行的 kernel 調查確認，引用行號皆為本 worktree 的 base）

`Classifier::updateFromQueriedTables`（`src/ndt_core/collection/Classifier.cpp:1332-1370`）
對兩種情況的處理是**不對稱的**：

- **switch 在 array 裡、但 flows 是空陣列** → `updateOneSwitch(dpid, [])`，
  `sw.epoch++` 之後掃掉**每一條**規則（`:1171-1201`）。空表是快照，會被套用。
- **switch 根本不在 array 裡** → `for` 迴圈碰不到它，**不 bump epoch、不掃、不動**。
  舊規則**無限期存活**，而 `SwitchClassifier`（`:450-460`）**沒有 timestamp、只有 epoch**
  ⇒ 讀取時**無法分辨陳舊與新鮮**。

而 `fetchOpenFlowTablesInternal` 的四條失敗路徑（proxy 不通／body 壞掉／proxy 回報讀取失敗／
空但慢）**全部是 `continue` 而不 `push_back`** ⇒ 一律落在「ABSENT」那一側。

⇒ **proxy 重啟造成的整段空窗期，kernel 的 Classifier 對十台交換機一律保留舊規則、
且無法得知那是舊的。** 這就是「twin 持續回報已經不存在的規則」的確切機制，
且它是**刻意設計**的（保守方向：曾經為真的舊資料勝過現在為假的斷言）——
在 Ryu wedge 那個情境下這個選擇是對的，**在 proxy 重啟這個情境下它剛好完全相反**，
因為重啟這件事本身就摧毀了規則。**同一條保守規則，在兩種故障下一對一錯，
而系統沒有辦法分辨自己在哪一種裡面。** 這正是本修法要補的那個位元。

---

## 3. 修法設計

### 3.1 排序理由：誠實必須先落地

recovery 先做是錯的，理由不是偏好而是可稽核性：**偵測不到抹除，就無法稽核回填**。
一個半成功的 replay 會讓 fabric 落在「既不符合 journal、也不符合重啟前」的狀態；
如果沒有 (a)，連「剛剛發生過一次抹除」這個事實都沒有人能陳述，
那麼 replay 之後的任何宣稱都無法被驗證。⇒ **(a) 是 (b) 的前置條件，不只是比較便宜。**

### 3.2 (a) 最便宜的誠實改動 — 已實作

**`boot_id` ＋ per-switch `table_generation`**，掛在 kernel **已經每秒輪詢**的
`GET /p4/switch_state` 上。

| | 決策 | 為什麼不是另一個做法 |
|---|---|---|
| 粒度 | **每台交換機**一個 token，另加一個 process-level `boot_id` | 只有 process-level 會**漏掉 `POST /p4/readopt/{dpid}`**——它推 pipeline、抹掉那一台，而 proxy 沒有重啟 |
| 形狀 | **不透明 token**（`uuid4().hex`），只比相等 | 計數器會被 readopt **歸零**（換了 client 物件）⇒ 讀者看到的是「數字變小」。token 沒有方向可以搞錯 |
| 時機 | **RPC 回來之後**才蓋章 | 蓋在呼叫之前 ⇒ **被拒絕的 push 會回報一次不存在的抹除**。而「十台裡有一台 bmv2 掛掉」是 `startup()` 本來就 per-switch try/except 接住的**日常**情況 ⇒ 這個訊號會在一週內被關掉 |
| 初始值 | `None`，**不是** token | `None` 與 token 是兩句不同的話：「我沒抹過這台」vs「我抹過，這是哪一次」。若初始就給 token，proxy 起來後的第一次輪詢**長得跟一次抹除一模一樣**，讀者會白白丟掉一份正確的視圖 |
| 掛載點 | 塞進 `switch_liveness()` 既有的 payload | 開第二個 endpoint ＝ 第二次輪詢 ＋ 第二個會被忘記的東西 |

**相容性（已查證，非推論）**：kernel 逐名讀取每個 switch entry 的欄位——
`DeviceConfigurationAndPowerManager.cpp:426` 依序找 `probe_ok`、`probe_age_s`、
`last_lldp_age_s` ⇒ **多出來的鍵對現有解析完全惰性**，不需要 kernel 同步改版。

**讀者要怎麼用**（kernel 側，尚未實作，見 §6）：每台 switch 記住上次看到的
`(boot_id, table_generation)`；任一個變了 ⇒ **「我裝在這台上的每一條規則都不在了」**，
於是 (i) 把該 dpid 的 Classifier 規則集標記為 stale、(ii) 出一行有具名原因的警告。
🔑 這一步**不需要新的 intent store**，只需要兩個字串的比較。

### 3.3 (b) 回填：三個選項的成本與失敗模式

#### R1 — proxy 持久化 rule journal 並在啟動時 replay（**本輪已實作記錄端，replay 端刻意未接線**）

| | |
|---|---|
| 成本 | 每次被接受的寫入多一次 append（**預設不 fsync**，見下）；啟動時 N 次 gRPC 往返 |
| 能救什麼 | **5-tuple 規則**——這是唯一一類在系統中**完全沒有其他紀錄**的規則；以及 app 的改寫與刪除 |
| 🔴 會靜默弄錯什麼 | **journal 記的是請求，不是理由。** TE 因為某條鏈路壅塞而裝的繞流，二十分鐘後壅塞已解，replay 仍會把它裝回去。journal **沒有辦法分辨**「現在還要不要」 |
| 🔴 第二個 | **拓撲已經變了**：主機搬了、埠換了，replay 會把規則寫到錯的埠上，而且會回報成功 |
| 半成功怎麼回報 | `ReplayReport.status` **四值**（`nothing-to-replay`／`complete`／`partial`／`failed`），**沒有 success 布林**；`failed` 裡帶**整條 entry**不是計數（半成功唯一的救援途徑是知道**少了哪一條**）；讀不掉的行會讓 replay **不准**宣稱 complete |

#### R2 — kernel 從自己的 intent store 重推

🔴 **前提不成立：kernel 沒有 intent store。**（平行調查逐檔確認）

- `FlowRoutingManager`（`include/ndt_core/routing_management/FlowRoutingManager.hpp:189-197`）
  私有狀態只有五個 shared_ptr／unique_ptr，**沒有任何已裝規則的 map**。
  `Controller.cpp:23` 自己寫著：「FlowJob is fire-and-forget」。
- `IntentTranslator`（`include/ndt_core/intent_translator/IntentTranslator.hpp:84-93`）
  **沒有任何 task／intent 容器**。
- `DispatchOutcomeLog`：**成功時不存規則內容**（`:103-108` 只 ++ 計數）；
  失敗環（capacity 256）存的 `Record` **沒有 actions 欄位**
  ⇒ **連留下來的失敗都無法 replay**。
- 唯一的磁碟持久化是 `HistoricalDataManager` 寫 link 快照，與規則無關。

| | |
|---|---|
| 成本 | **要從零建 C++ 持久化狀態**，且本輪**無法編譯驗證** |
| 優點 | kernel 擁有**理由**（intent），可以**重新推導**而不是重播 ⇒ 不會裝回過期的繞流 |
| 🔴 失敗模式 | app 是事件驅動的，**沒有「現在全部重算一次」的觸發點**。加一個 ⇒ 在 proxy 最冷的那一刻湧入 128 host × 10 switch 的安裝風暴 |
| 半成功怎麼回報 | 逐條可報（kernel 已把 non-2xx 當失敗記錄），但**整體**（「想回填 300 條、失敗 40 條」）**沒有歸屬地** |

#### R3 — 讓 pipeline push 變成有條件的（**未實作，這是 Adam 的裁決**）

「不要摧毀」看起來比「摧毀後回填」便宜一個數量級：啟動時先用
`GetForwardingPipelineConfig(COOKIE_ONLY)`（`probe()` 已經在用這個呼叫）比對 cookie，
一樣就跳過 commit。

🔴 **兩個必須先解決的問題**：
1. **現在根本沒有 cookie 可比**：`set_forwarding_pipeline_config`（`p4_client.py:294-303`）
   只設 `device_id`／`election_id`／`action`／`p4_device_config`／`p4info`，
   **沒有設 `req.config.cookie`** ⇒ COOKIE_ONLY 會拿回 0／未設。要能用，得先讓 cookie
   由 artifact 內容導出（例如 `.json` ＋ p4info 的 sha256）。這是小改動但**是真的改動**。
2. 🔴 **會動到 clone-session 那條已驗證的論證**：`write_clone_session` 的
   settle DELETE+INSERT pair 之所以正確，前提是「pipeline commit 會清空 server 的
   bookkeeping」（`p4_client.py:320-349`，2026-08-16 實測，1→2→3→0 四個 raw phase）。
   **改變 commit 何時發生，就改變了那個論證的前提。**
3. 代價的另一面：pipeline 若曾偷偷 drift 離 artifact，**條件式 push 就再也不會把它糾正回來**。

⇒ **R3 是最有價值也最危險的一個，必須由 Adam 裁決，不由本 session 決定。**（見 §7 Q1）

### 3.4 被否決的替代方案

| 方案 | 否決理由 |
|---|---|
| 讓 kernel 偵測「proxy process 不見了」 | 抓不到 `readopt` 那半——那條路徑抹表而 proxy 沒重啟。而且 kernel 對 proxy 不可達的反應目前只有 edge-triggered logging |
| 拿 `m_cachedOpenFlowTables` 當 intent store | 它是 cache：`openflowTablesUpdateWorker` 每 ~10 s `std::move` 整份覆寫（`:1888-1894`）。`DispatchOutcomeLog.hpp:164-166` 自己也這麼寫 |
| 把 5-tuple 規則塞進 `_installed_routes` | 那個 map 是 `(dpid, ipv4_dst) -> out_port`，**單值**；兩條 5-tuple 規則可以把同一個目的地送去不同的埠。原註解已論證過，塞進去只會讓 `render_destination_paths` 從「沉默」變成「自信地錯」 |
| replay 預設開啟 | §3.3 R1 的兩個 🔴。而且**開了就再也回不去**——replay 過的 fabric 無法還原成 replay 前 |
| `record()` 失敗時讓安裝一起失敗 | journal 是路由的**紀錄**，不是**前提**。磁碟滿了不是 fabric 停止轉發的理由 |

### 3.5 受影響的呼叫端（全部已查證）

| 呼叫端 | 影響 |
|---|---|
| `TopologyManager(...)` 全部既有建構點（`main.py` 模組層的 `topo`、各測試） | **零影響**：`journal=None` 預設，六條路徑全部走 no-op |
| `route_flow`／`unroute_flow`／`modify_flow` | 各有 **2 條**成功路徑（LPM ＋ 5-tuple）＝ **6 個**，全部接線 |
| `switch_liveness()` → `GET /p4/switch_state` | payload 多 4 個鍵（top-level `boot_id`／`boot_at`，per-switch `table_generation`／`pipeline_commits`）。kernel 逐名讀取 ⇒ 惰性 |
| `P4RuntimeClient.__init__` | 多 2 個欄位。⚠️ **`tests/test_five_tuple_match.py` 用 `__new__` 手工建 TopologyManager**，已補 `_journal = None`（否則 red） |
| `set_forwarding_pipeline_config()` 的 3 個呼叫端（`main.startup`、`client.start(push_config=True)`、`readopt_switch`） | 全部自動獲得 token，**不需各自改** |
| kernel C++ | **本輪零改動。** 新欄位目前**沒有讀者**——見 §6，這是必須交給人的事 |

---

## 4. Patch

```
$ git log --oneline -1
05976e27 Let the proxy say it just destroyed every rule on every switch

$ git show --stat HEAD
 p4_proxy/proxy_agent/boot_identity.py    |  64 +++++++
 p4_proxy/proxy_agent/p4_client.py        |  34 +++-
 p4_proxy/proxy_agent/rule_journal.py     | 296 +++++++++++++++++++++++++++++++
 p4_proxy/proxy_agent/topology_manager.py | 100 ++++++++++-
 p4_proxy/tests/test_five_tuple_match.py  |   6 +
 p4_proxy/tests/test_journal_wiring.py    | 239 +++++++++++++++++++++++++
 p4_proxy/tests/test_rule_journal.py      | 283 +++++++++++++++++++++++++++++
 p4_proxy/tests/test_table_generation.py  | 268 ++++++++++++++++++++++++++++
 8 files changed, 1282 insertions(+), 8 deletions(-)
```

分支：`fix/a4c-proxy-restart-honesty`（從 base `4cbec52d` 長出來）。**沒有 push。**
工作樹乾淨；只動列名的 8 個檔案（無目錄 pathspec）。

**C++ 側：本輪沒有任何 C++ 改動 ⇒ 沒有「NOT COMPILED」的 patch 要交。**
kernel 的部分是**閱讀**，結論寫在 §2.3／§2.5／§3.3-R2。

---

## 5. 測試證據（rc 皆未經 pipe）

### 5.1 紅

| 檔案 | 指令 | 結果 |
|---|---|---|
| `test_table_generation.py`（**最終版**，對未改的 production code） | `python3 -m unittest tests.test_table_generation -v > out 2>&1; echo rc=$?` | **rc=1**，`FAILED (errors=11)`，**11/11 紅** |
| `test_rule_journal.py` | 同上 | **rc=1**，`ModuleNotFoundError: No module named 'proxy_agent.rule_journal'` |
| `test_journal_wiring.py` | 同上 | **rc=1**，`Ran 14`／`FAILED (errors=12)`（另 2 條驗**既有**行為，本來就該綠） |

📌 `test_table_generation` 的紅是**兩次**取得的：第一次（`red2.txt`，5 FAIL ＋ 6 ERROR）
用的是初版 fixture；改成呼叫真正 `__init__` 的 fixture 之後，**把 production 改動整個抽掉重跑**
（`git checkout --` 兩個檔 ＋ 把 `boot_identity.py` 移走），得到 **11/11 紅**——
所以紅是對**最終版測試**取得的，不是對中途版本。

### 5.2 綠

```
$ ... -m unittest tests.test_table_generation ; rc=0   Ran 11   OK
$ ... -m unittest tests.test_rule_journal     ; rc=0   Ran 19   OK
$ ... -m unittest tests.test_journal_wiring   ; rc=0   Ran 14   OK
```

**全 p4_proxy 套件（22 個模組，逐模組獨立行程，仿 `l1_unit_tests.sh`）**：
`modules with nonzero rc: 0`，合計 **566 tests**。
skip 只有兩處且**都是既有**：`test_p4_client` 1 skip（要真 bmv2 的 opt-in live test）、
`test_sflow_emitter` 2 skip。⚠️ 依 venv 記憶，`OK` 一定要連 skip 數一起看——已看。

### 5.3 突變（12 個，**全部被殺**）

不是「跑過紅」而已——每個突變都是一個**合理的錯誤**，並記錄是**哪一條**測試抓到的：

| # | 突變 | 抓到的測試 |
|---|---|---|
| M1 | 空 journal 回報成 `complete` | `test_an_empty_journal_is_not_reported_as_recovery` |
| M2 | 有讀不掉的行仍宣稱 `complete` | `test_an_unreadable_line_keeps_a_replay_from_claiming_completeness` |
| M3 | `"0"`／`"false"` 被當成開啟 | `test_replay_turns_on_only_for_an_explicit_value` |
| M4 | entries 被排序（破壞寫入順序） | `test_order_is_write_order_and_not_any_ordering_of_the_entries` |
| M5 | `actions` 沒被記下來（＝重演 DispatchOutcomeLog 的錯） | 3 條 |
| M6 | applier 丟例外就中止整個 replay | `test_an_applier_that_raises_is_a_failure_not_a_crash` |
| M7 | 失敗只記數量、不記是哪一條 | `test_a_partial_replay_says_partial_and_names_what_is_missing` |
| T1 | **token 蓋在 RPC 之前**（被拒絕的 push 也回報抹除） | `test_a_refused_commit_leaves_the_generation_alone` |
| T2 | token 是常數（第二次抹除讀成「沒事發生」） | 2 條 |
| T3 | `boot_id` 不再送出 | `test_the_payload_names_the_proxy_instance` |
| T4 | per-switch token 不再送出 | `test_a_switch_reports_its_table_generation` |
| T5 | 初始值給 token 而非 `None`（新 proxy 看起來像剛抹過） | 2 條 |

🔴 **兩個突變一開始沒被殺，兩個都是測試的問題，都已修**：

1. **M4 存活**（`rc=0 OK`）：`test_order_is_preserved` 的三筆 entry **match 完全相同**，
   所以「照 match 排序」是穩定排序、順序不變 ⇒ 那條測試**對排序完全沒有鑑別力**。
   已新增 `test_order_is_write_order_and_not_any_ordering_of_the_entries`，
   三筆的目的地刻意**遞減**且 delete 夾在中間，任何排序鍵都重現不出來。
2. **T1 存活**（`rc=0 OK`）：查下去發現是**我的突變腳本壞了**——第二個 `replace`
   把第一個剛插入的那份又刪掉了，淨效果是沒改到。用手寫的正確突變重跑 ⇒ **rc=1**，
   被 `test_a_refused_commit_leaves_the_generation_alone` 抓到。
   📌 **教訓**：「突變存活」有兩種可能，第二種是**突變沒真的套用**。
   看到存活要先驗證突變本身，不要直接下結論說測試不夠。

---

## 6. 我沒能驗證的，以及人必須接手的

### 6.1 沒有驗證的（誠實分級）

| 項目 | 我做到哪 | 沒做到哪 |
|---|---|---|
| 「pipeline commit 會清空 bmv2 每一張表」 | **讀過** repo 內三處自述，其中 `p4_client.py:320-349` 引用 2026-08-16 的**實測**（含 raw phase A–E 的 1→2→3→0） | 🔴 **我沒有跑過任何 bmv2。** 這是「讀過未執行」，不是「跑過」 |
| kernel 端各檔行為 | **讀過**（部分經平行 subagent 逐檔查證，行號已列） | 🔴 **沒有編譯、沒有執行任何 C++。** 本輪 zero build |
| 新欄位對 kernel 解析無害 | **讀過** `DeviceConfigurationAndPowerManager.cpp:426` 逐名讀鍵的程式碼 | 沒有跑過真的 kernel 去確認 |
| Python 改動 | **跑過**：566 tests 綠、44 條新測試見過紅、12 個突變全殺 | 沒有跑過 live proxy |
| journal 的磁碟行為 | **跑過**（temp dir、torn line、缺檔） | 沒有測過**真的**行程被砍在 append 中間；沒有量過 append 對安裝延遲的影響 |

### 6.2 🔴 最重要的一件事：新欄位目前**沒有讀者**

`boot_id`／`table_generation` 已經出現在 `GET /p4/switch_state` 的 payload 裡，
**但 kernel 沒有任何一行讀它們**。以這個 repo 自己的分類，這現在是
**「一個沒有讀者的寫者」**——正是它最常犯的那個缺陷形狀。

⇒ **在 kernel 端加上讀者之前，這個修正只完成了一半。** 這件事必須由人做（要編譯）：
在 `p4LivenessFor` 附近記住每個 dpid 上次的 `(boot_id, table_generation)`，
變了就 (i) 讓該 dpid 的 Classifier 規則集失效、(ii) 出一行具名警告。

### 6.3 人必須接手的清單

1. **編譯**——本輪沒有任何 C++ 改動，但 §6.2 的讀者需要。
2. **決定 R3**（見 §7 Q1）——是否改成條件式 pipeline push。
3. **決定 journal 是否預設開啟**（見 §7 Q2）。
4. **跑下面這個 live test。**

### 6.4 能證明這個修正有效的 live test（含**陰性對照**）

前置：claim lab、`NDT_OWNER`、十台 bmv2 起來、kernel 起來。**不要**重啟 fabric。

**A. 建立一個只有 delta 才看得見的狀態**（關鍵：不要只裝 bring-up 形狀的規則）
   1. `POST /stats/flowentry/add` 裝**一條 5-tuple 規則**（match 帶 `nw_src` ＋ `tp_dst`）。
      這是唯一一類「表不會變空、但東西真的不見了」也看得出來的規則。
   2. `POST /stats/flowentry/delete` **刪掉**一條 bring-up 的 LPM 規則。
   3. 🔑 **用 P4Runtime 直接讀真實交換機表**（`p4_proxy/reference/dump_table.py`）記下 before，
      **不要看 kernel 快取**——KNOWN-ISSUES 條目本身就這樣要求。

**B. 記下訊號**：`curl :8081/p4/switch_state`，存下 `boot_id` 與每台的 `table_generation`。

**C. 重啟 proxy**（只重啟 proxy，bmv2 不動）。

**D. 判讀**
   - **陽性**：`boot_id` 變了、每台 `table_generation` 都變了 ⇒ 訊號有發出來。
   - **對真相對帳**：再用 `dump_table.py` 讀真實表 ⇒ 5-tuple 規則**應該不在**、
     被刪掉的 LPM 規則**應該又回來了**。若兩者都成立，就是**訊號與真相一致**。
   - ⚠️ 如果 5-tuple 規則**還在**，那 §2.1 的機制判斷就錯了，**整份分析要重寫**。

**E. 🔴 陰性對照（不做這個，D 什麼都證明不了）**
   把 D 換成「**不重啟 proxy**，只是等同樣長的時間、然後再打一次 `/p4/switch_state`」。
   - **必須**：`boot_id` 與每一台的 `table_generation` **完全不變**。
   - 若在沒有重啟的情況下 token 也會變（例如它被誤寫成每次讀取都重新產生），
     那這個訊號**沒有鑑別力**——它會對每一次輪詢都喊「規則沒了」，
     然後在一週內被關掉。`test_the_generation_survives_being_asked_for_twice`
     在單元層擋的就是這個，但只有這個對照能在 live 上證明。

**F. 第二個陰性對照（針對「被拒絕的 push」）**
   讓一台 bmv2 停掉，再重啟 proxy。那一台的 pipeline push 會失敗
   （`startup()` 會把它放進 `broken`）。
   - **必須**：那一台的 `table_generation` **維持 `None`**（或維持原值），
     其他九台的才變。
   - 若它也變了，代表 token 蓋在 RPC 之前 ⇒ 會把一次沒發生的抹除報成發生了。
     這就是突變 T1，單元層已擋，live 層需要這個對照確認。

---

## 7. 給 Adam 的裁決題（選項＋後果）

### Q1 🔴 要不要讓 pipeline push 變成條件式（R3）？

> **建議：先不要，但把 cookie 補上。**

| 選項 | 後果 |
|---|---|
| **A. 維持現狀（每次啟動都無條件 commit）** | 每次重啟都摧毀規則。但 clone-session 那條 2026-08-16 實測論證的前提**完全不動**；本輪的 (a) 誠實訊號足以讓人知道發生了什麼 |
| **B. 只補 cookie，仍然每次都 commit** | 零行為改變，但**從此有東西可以比對**——之後任何時候要做 A→C 都只是一行判斷。成本極小 |
| **C. 條件式 commit（cookie 相同就跳過）** | 規則**不再被摧毀**，A-4c 從根消失。🔴 但：(i) 改變了 `write_clone_session` settle pair 的前提，那段論證要**重新實測**；(ii) pipeline 若曾偷偷 drift 離 artifact，**再也不會被糾正** |

### Q2 journal 預設開還是關？

> **建議：先開「記錄」、不開 fsync；replay 維持關。**

| 選項 | 後果 |
|---|---|
| **A. 記錄預設關（現況）** | 對量測零影響。但**等到需要的時候，journal 是空的**——而「需要的時候」永遠是事後 |
| **B. 記錄預設開、不 fsync** | 每次安裝多一次 buffered append（微秒級）。A-4c 的觸發情境是**刻意重啟**，buffered 已足夠（page cache 在乾淨重啟中不會掉）。只有**整台機器 crash** 才會丟 |
| **C. 記錄預設開、每次 fsync** | 連機器 crash 都保得住。🔴 但每條規則多一次 fsync，**會改變安裝延遲**——這個專案正在量 pps 天花板，我不建議在量測期引入這個 |

⚠️ 目前程式碼是 **`fsync` 開著**（`rule_journal.record`），而 `TopologyManager` 預設 `journal=None`
⇒ **實際上等於選項 A**。要走 B 需要兩個小改：`main.py` 建 journal、`record` 的 fsync 改可關。

### Q3 replay 要不要接線？

> **建議：不要自動 replay。**

| 選項 | 後果 |
|---|---|
| **A. 不接（現況）** | journal 純粹是**證據**：重啟後人可以讀它，知道少了哪些規則、自己決定補哪些。零新風險 |
| **B. 啟動時自動 replay** | 規則自動回來。🔴 但會**裝回過期的繞流**（journal 記請求不記理由），且拓撲若變了會寫到錯的埠 ⇒ **自信地錯** |
| **C. 提供一個手動 endpoint（`POST /p4/replay_journal`）** | 人看過 `ReplayReport` 再決定。折衷，但需要新的 endpoint ＋ 測試 |

### Q4 KNOWN-ISSUES A-4c 條目要不要照 §2.4 更新？

兩點：①「每一條都消失」加上「bring-up 形狀會被重算回來，真正消失的是 delta 與全部 5-tuple」；
② 觸發條件加上 `POST /p4/readopt/{dpid}`（不需要重啟 proxy）。
**建議更新**——現在的寫法會讓複驗者去數規則總數，然後因為表不是空的而誤判「重現不出來」。

---

## 附：本輪動到的檔案

| 檔案 | 性質 |
|---|---|
| `p4_proxy/proxy_agent/boot_identity.py` | 新增 |
| `p4_proxy/proxy_agent/rule_journal.py` | 新增 |
| `p4_proxy/proxy_agent/p4_client.py` | 改（`__init__` ＋2 欄位；`set_forwarding_pipeline_config` ＋2 行）|
| `p4_proxy/proxy_agent/topology_manager.py` | 改（`__init__` ＋1 參數；`_note_in_journal`；6 個成功路徑；`switch_liveness` ＋4 鍵）|
| `p4_proxy/tests/test_table_generation.py` | 新增（11）|
| `p4_proxy/tests/test_rule_journal.py` | 新增（19）|
| `p4_proxy/tests/test_journal_wiring.py` | 新增（14）|
| `p4_proxy/tests/test_five_tuple_match.py` | 改（fixture ＋1 欄位）|

commit `05976e27`，分支 `fix/a4c-proxy-restart-honesty`，**未 push**。

[Co-developed with claude code -- Adam]
