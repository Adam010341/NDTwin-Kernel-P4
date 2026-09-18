# TICKET-P2-F — external 控制面下 `ndt up` 的「N up」是量到一場競賽，不是 fabric：改成讀數＋一個真的閘，03 在 pipeline 載入後才斷言 up

orchestrator「9/18 ochestrator」2026-09-18 22:5x 寫；base trunk **`fa83c170`**（P2-D 第一、二輪已併）。
**給 P2-D 的同一個 worker、同一個 worktree `scratch/overnight-2026-09-05/wt-p2-ndtup-0918`、同一條分支 `feat/p4-app-package-p2-ndtup-0918`，接在 round 3 `86effe96` 之後當第四輪**；round 3 **不併**，理由在 §3。
上位工單 `TICKET-P2-exercise-dataplane.md` §7 第 12 條（裁定與理由）；前置 `TICKET-P2D-ndt-up-foreign-pipeline.md`（§0 紅線逐條有效）。

[Co-developed with claude code -- Adam]

## 0. 🔴 紅線（同 TICKET-P2D §0，逐條有效；這裡只列有變動的）

1. 不 sudo、不 `ndt up`、不 `mn`、不碰 lab、不起 bmv2、不 curl :8081／:8000、不建 C++、不推、不併 trunk、不動主 checkout；`git commit -F <msgfile> -- <明列到檔案>`；訊息尾 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`；AI 參與的檔案標 `[Co-developed with claude code -- Adam]`。
2. **沒看過紅不算交付**：每個新分支都要有一個變異讓它紅；每個閘門與套件的 stdout 存 `scratch/overnight-2026-09-05/logs/gates-0910/<gate>.p2f-<sha>.log`。
3. **檔案所有權（本輪）**：`tools/test_workflow/stack.sh`（只做 §4.1 的 revert）、`tests/shell/{test,mutate}_stack_await_convergence.sh`（跟著 revert）、`tools/test_workflow/ndt`（只動 `verify_p4` 的 external 分支與它叫的 graph 檢查；§4.2）、`tests/shell/{test,mutate}_ndt_app_package.sh`、`doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/{_common.sh,03_app_p4runtime.sh}`、新檔 `tests/shell/{test,mutate}_live_p1_common.sh`（§5.3）。**不動 `p4_proxy/**`、不動 `src/**`、不動 `live-p1/02*`、不動 driver。**
4. 行號以實際為準（本工單行號＝`fa83c170`，stack.sh 的行號＝`86effe96`），不符時 SUMMARY 註明。

## 1. 證據（orchestrator 親自跑；log 在 `scratch/overnight-2026-09-05/logs/orchestrator-0918/{live,live-r2}/live-p1-03_app_p4runtime.log`，run 目錄在 `live-p1/runs/`）

| | round 1（`365c60e1`，**PASS**） | round 2（`fa83c170`，**FAIL**） |
|---|---|---|
| run 目錄 | `2026-09-18T100220Z_03_app_p4runtime/` | `2026-09-18T132821Z_03_app_p4runtime/` |
| stack.sh `[2/3]` | `waiting for link discovery: want 6 destination paths`（等滿 300 s 才起 kernel） | 沒有那一行（NOT WAITED；kernel 在 proxy 之後 ~2 s 起） |
| `ndt` `[3/3]`（`20_up.txt`） | `ok  kernel: 3 switches, 3 up, 12 edges, 3 hosts`（沒印 `is_enabled=`，即 3 enabled） | `XX  kernel: 3 switches, 0 up (want 3/3)`＋`is_enabled=0/3` |
| **一秒後**的 `ndt status`（`31_status.txt` :40） | **`switches 0 up, 3 enabled, 0 admin-disabled`** | `switches 0 up, 0 enabled, 0 admin-disabled` |
| `30_switch_state_before.json` 三台 | `probe_ok: false`，`probe_detail: "FAILED_PRECONDITION: No forwarding pipeline config set for this device"`，`probe_age_s` 0.05 | 同左（`probe_age_s` 0.88） |
| `37_skeleton_controller.log` / `40_controller.log` :6-7 | `Installed P4 Program using SetForwardingPipelineConfig on s1`、`… on s2`（**沒有 s3**） | 同左 |

🔴 第三列是關鍵：round 1 的 `3 up` **一秒後就變 `0 up`**，而 `3 enabled` 留著。這不是 fabric 的狀態，是 verify 的 curl 恰好落在一個 ≤1 s 的窗口裡。

## 2. 機制（全部是 09-18 讀的碼；行號＝`fa83c170`）

1. `mode: external` ⇒ `read_only=True` ⇒ proxy **不推 pipeline**（`p4_proxy/proxy_agent/main.py:747` `if read_only or not client.json_path: continue`）。
2. liveness 探針 `p4_client.py:551-581 probe()`＝`GetForwardingPipelineConfig(COOKIE_ONLY)`；沒載 pipeline 的 bmv2 回 gRPC `FAILED_PRECONDITION` ⇒ `{"ok": False, "detail": "FAILED_PRECONDITION: …"}`（:576-579 把**任何** `RpcError` 都算 `ok: False`）。探針執行緒 `topology_manager.py:1562-1590`，每 2 s（`LIVENESS_PROBE_INTERVAL_S`），在 `startup()` 尾端 `main.py:973` **無條件**啟動 ⇒ external 下 proxy 起來 ≤1 s 內三台都是 `ok: False`，而且**一直是**，直到有人載 pipeline。
3. `GET /v1.0/topology/switches`（`api_routes.py:173-182`）只服務 `connected_switch_dpids()`（`topology_manager.py:1608-1637`）：**上一次探針明確 False 就排除** ⇒ external 下這個清單在第一次探針之後就是 `[]`，並且一直是。
4. kernel 的拓樸輪詢 `TopologyAndFlowMonitor.cpp:4854-4890 runLoop`：**不是拉一次**——90 s 內每 5 s、之後每 30 s（`kWhileConverging`／`kOnceConverged`）；`updateSwitches`（:2268-2367）對清單裡的 dpid 設 `isUp=true`、`isEnabled=true`，不在清單裡的不動（單向棘輪）。清單是 `[]` ⇒ 什麼都不設。
5. 🔴 **`inform_switch_entered` 不看 `read_only`**：`main.py:863-865` `usable = [i for i in clients if i not in broken]`（external 下 `broken` 為空，因為根本沒推）⇒ 對三台各打一次 `GET /ndt/inform_switch_entered?dpid=N`；kernel 還沒起 ⇒ 全失敗 ⇒ `:882` 開背景執行緒 `kernel_notifier.renotify_until_acknowledged`（`kernel_notifier.py:153-184`：**先睡 10 s 再試，最多 30 次＝5 分鐘**）。
6. kernel 端 `HttpSession.cpp:2485-2545 handleInformSwitchEntered` ⇒ **`setVertexUp` ＋ `setVertexEnable`**（:2542-2543）——這是 external 下**唯一**會把 isUp／isEnabled 寫成 true 的路徑（第 3、4 點的清單是空的；第 7 點只會寫 false）。
7. kernel 的 `pingWorker`（`DeviceConfigurationAndPowerManager.cpp:860`，**每 1 s**）對 bmv2 走 `p4VerdictFor` → `p4LivenessFor`（:612-717）：`probe_ok: false` 且 `probe_age_s` 新鮮、`last_lldp_age_s` 為 null（external 沒 LLDP）⇒ **Down** ⇒ `setVertexDown`（:5058-5062，只清 isUp，不動 isEnabled）。
8. `ndt` 的 `[3/3]` 只讀一次（`verify_p4_graph`，`ndt:3343-3386`）：`up == want_sw` 才 ok。

⇒ **round 1**：proxy T+0；探針 T+1 起全 False；stack.sh 等 300 s；kernel API 約 T+303；背景重試第 k 次在 T+1+10k，第 30 次 ≈ T+301～304 ——**剛好**落在 kernel API 開了之後 ⇒ 三台 isUp=isEnabled=true；`ndt` verify 在下一秒 pingWorker 判 Down 之前讀到 `3 up`；一秒後 `31_status` 已是 `0 up, 3 enabled`。兩個競賽疊起來的綠。
⇒ **round 2**：kernel API 約 T+4；verify 約 T+5；第一次重試在 T+11 ⇒ `0 up, 0 enabled`，一秒後也是。**這是 kernel 自己的政策說的真話**：一台沒有 pipeline 的 bmv2，這個 twin 叫它 Down。

## 3. 由此得出的三件事（決定本輪做什麼）

1. **`ndt up` 在 external 下把「N up」當閘，是在量一場競賽。** 修法不是把 300 s 還回去讓競賽再賭一次（round 3 的效果就是這個），而是：`up`／`is_enabled` 在 external 下、控制器還沒跑之前是**讀數**，並用一個**機制上為真**的閘取代它——三台都在 `switch_state` 裡、而且探針**被回答了**（`probe_ok: true`，或 `probe_detail` 以 `FAILED_PRECONDITION` 開頭＝bmv2 行程活著、只是沒程式）。`UNAVAILABLE`／`DEADLINE_EXCEEDED`／`probe raised …`／`probe_ok: null` 到底／缺 dpid ⇒ 紅，指名 dpid 與 detail。
2. **round 3 的 `await_switch_list`（`86effe96`）不併。** 它等的清單（§2-3）在 external 下**永遠**填不滿——只會把 300 s 燒回去、換回 round 1 那個競賽；在 foreign package 下 proxy 的 `startup()` 是 `await startup(...)`（`main.py:1001-1003`）——uvicorn 在 startup 完成前不服務，所以 stack.sh 問得到 :8081 的時候三台早就在清單裡 ⇒ 那個等待一次 poll 就回、是空操作。round 3 commit message 與註解裡的「the kernel pulls once and never retries」是錯的（§2-4）；一次性的是 `ndt` 的 verify。**round 3 的測試在自己碼裡抓到的兩個 bug（`local … got last="" probed=0`、`$want`／`$got`）是真的收穫，寫進 SUMMARY 留著，碼 revert。**
3. **03 真正能斷言的是「twin 的 liveness 跟著練習的 pipeline 推送走」**：練習的兩個控制器都只對 s1、s2 做 `SetForwardingPipelineConfig`（`~/tutorials/exercises/p4runtime/mycontroller.py:159-164`、`solution/mycontroller.py:184-189`；§1 的 log 證實）⇒ 控制器起來之後 ≤ 探針 2 s＋pingWorker 1 s，kernel 圖應該是 **s1、s2 up、s3 down**，而且穩定（s1、s2 的探針從此 True；s3 一直 False）。這是 goal ③「練習的控制器與 NDTwin 的 proxy 共存」的一條真的性質，而且它的期望值來自控制器自己的 log，不是寫死的。

## 4. 契約

### 4.1 `stack.sh`：revert round 3

`git revert --no-edit 86effe96`（保留歷史；revert 訊息前面加一段說為什麼：§3-2 的兩句）。結果＝round 2 的 `stack.sh`（NOT WAITED 之後 `return 0`）、`test_stack_await_convergence.sh` 35 格、`mutate_stack_await_convergence.sh` 9 顆＋2 控制。三支重跑、存 log。

### 4.2 `ndt` `verify_p4` 的 external 分支（`ndt:3167` 起；`:3201-3205` 是現在的 NOT CHECKED 段、`:3253`（`verify_p4_graph "$topo" || rc=1`）是要分岔的呼叫點）

external 下 `[3/3]` 印的順序與語意：

1. `proxy: destination paths NOT CHECKED -- …`（現有四行，不動）。
2. 🔴 **新閘**：`proxy: 3/3 switches answered the liveness probe (no pipeline loaded on any of them, by design)`——讀 `GET /p4/switch_state`（用 P2-D 的 `proxy_switch_state`；`probe_ok` 為 null 時最多再讀 5 次、每次隔 1 s，照 `proxy_skipped_steps` 的上界），對模型宣告的每個 dpid（`topo_model_switch_dpids` 若沒有這個 helper就從 `vertex_type==0` 的 `dpid` 讀）：
   - `probe_ok == true` ⇒ 算「answered」，訊息改成 `… (N of them already carry a pipeline)`；
   - `probe_ok == false` 且 `probe_detail` 以 `FAILED_PRECONDITION` 開頭 ⇒ 算「answered, no pipeline」；
   - 其他 ⇒ `XX  proxy: switch <dpid> did not answer the liveness probe: <probe_detail 或 'no probe yet'>`，rc 1；缺 dpid ⇒ `XX  proxy: switch <dpid> is not in /p4/switch_state at all`，rc 1；讀不到 switch_state ⇒ 紅（同 P2-D 的形狀）。
3. graph：`ok  kernel: 3 switches in the graph, 12 edges, 3 hosts`（**switch 總數與模型相等仍是閘**：`total != want_sw` ⇒ `XX  kernel: 2 switches in the graph (model declares 3)`，rc 1）。
4. 🔴 **讀數，永不紅**：`!!  kernel liveness: 0/3 up, 0/3 enabled -- a READING, not a verdict. No pipeline is loaded on an external fabric until its own controller runs, and the twin's liveness policy (p4LivenessFor: probe FAILED_PRECONDITION, no LLDP) calls such a switch Down. Expect this to change to N/3 up within ~3 s of the controller loading a program on N switches.`（兩到四行，字自己排；**`up` 與 `enabled` 兩個數字都要印**，因為 §1 那個 `3 enabled` 就是靠這兩個數字對照才看得出來的）。
5. `model matches fabric: 3 hosts …`（現有 hosts 閘，不動）。
6. `data plane: forwarding NOT TESTED …`（不動）；verdict `up. ready`＋現有 EMPTY 但書（不動；`lab_entry_points p4` 仍在 `ready` 下一行——`test_ndt_up_down_robust.sh:1857-1860` 數這個）。

**baseline 與 foreign 分支逐格不變**：`verify_p4_graph "$topo"` 對非 external 的呼叫路徑與輸出一個位元組都不動（§10 既有格子與 M 錨點都靠它）。實作上是加參數還是拆一支 `verify_p4_graph_external`，你決定；SUMMARY 寫清楚。

`cmd_status`（`ndt:5297` 起）：external 下 `switches 0 up, 3 enabled` 那一列與 `--check` 的 `problems+=`——**先查它現在會不會因 `0 up` 記一個 problem**；會 ⇒ 改成同一句讀數（不記 problem），加格；不會 ⇒ SUMMARY 說「查過，不會，行號」。

### 4.3 `live-p1/03_app_p4runtime.sh`

- `ndt up` 之後（現在的 `20_up.txt`／`30_switch_state_before.json` 之後）：寫 `32_kernel_graph_before.txt`——每台 `dpid is_up is_enabled` 一列＋合計，**只記不斷言**。
- 🔴 骨架控制器起來之後（`:172` 之後、`:205` 的 ping 對照之前）：**有界等待 ≤ 20 s（每 1 s 讀一次 `/ndt/get_graph_data`）直到「kernel 圖裡 up 的 dpid 集合 == 控制器 log 說它裝了程式的集合」而且不在那個集合裡的 dpid 都 `is_up == false`**；期望集合**從 `37_skeleton_controller.log` 解析** `Installed P4 Program using SetForwardingPipelineConfig on s<N>`（sN → dpid N，照 preflight 的 `every sN has dpid N`）。到達 ⇒ `36_kernel_up_after_pipeline.txt`（每台一列、期望集合、花了幾秒）；20 s 沒到 ⇒ `fail`，訊息列出哪些 up 哪些 down、期望是誰。**期望集合為空 ⇒ `fail`**（控制器 log 沒說它裝了任何程式，一個空集合對空集合的「相等」什麼都沒證明——這是這格的控制）。同時存 `35_switch_state_after_pipeline.json`，斷言 s1、s2 `probe_ok == true`、s3 `probe_ok == false`（同一個期望集合推出來的）。
- 解答控制器起來之後（`:216` 之後、`41_dataplane_ok_before` 之前）：同一個檢查再做一次（`46_kernel_up_after_solution.txt`／`45_switch_state_after_solution.json`），期望集合從 `40_controller.log` 解析。
- 這兩段用同一個 helper（放 `_common.sh`）：`kernel_up_set`（印 up 的 dpid，排序、逗號分隔）、`controller_program_set <log>`（印 log 裡裝了程式的 dpid 集合）、`await_kernel_up_set <expected> <timeout> <outfile>`（rc 0／1，輸出寫檔）。curl 用 `_common.sh` 現有的方式。

### 4.4 文件

`TICKET-P2D-…md` 不回頭改；本檔 §6 之後由你補一節「實作對照」（行號、與契約不同之處）。`doc/audit/2026-09-04_p4-tutorial-exercise-prep/PLAN-0917-exercise-support.md` 若有一句可加就加「external 下 up 是讀數；03 在 pipeline 後才斷言」，沒有就不動。

## 5. 測試與變異（沒紅不算）

### 5.1 `tests/shell/test_ndt_app_package.sh`（§10 的 `drive_v`＋`VSTUB` 範本；switch_state 用 fixture 檔、`curl` stub）

- external、graph 3 台 0 up 0 enabled、switch_state 三台 `FAILED_PRECONDITION` ⇒ **rc 0**、印 `3/3 switches answered`、印 `kernel liveness: 0/3 up, 0/3 enabled -- a READING`、**沒有** `XX  kernel:`、verdict `up. ready`。
- 同上但 graph 只有 2 台 ⇒ rc 1、`2 switches in the graph (model declares 3)`。
- 同上但 dpid 3 不在 switch_state ⇒ rc 1、訊息指名 `3`。
- 同上但 dpid 2 `probe_detail: "UNAVAILABLE: failed to connect"` ⇒ rc 1、訊息指名 `2` 與 `UNAVAILABLE`。
- 同上但三台 `probe_ok: null`、五次都 null ⇒ rc 1、`no probe yet`；null 兩次後變 `false`＋FAILED_PRECONDITION ⇒ rc 0（**有界重讀真的重讀了**：curl 次數 3）。
- 三台 `probe_ok: true` ⇒ rc 0、`already carry a pipeline`。
- 🔴 **控制**：mode ndtwin（baseline）graph 0 up ⇒ 仍 rc 1、仍 `XX  kernel: … 0 up (want …)`（讀數只在 external 下）。既有 §10／§16 格子逐格不變。
- `cmd_status --check` external 下 `0 up` 不記 problem（若 §4.2 末段查出來要改）。

### 5.2 `tests/shell/mutate_ndt_app_package.sh`（接在 M35 之後；2 控制保留）

- M36：external 下 `up` 仍當閘（讀數那段改回 `err`＋rc 1）⇒ 被「external 0 up 是 rc 0」殺。
- M37：探針閘拿掉（永遠印 answered）⇒ 被 UNAVAILABLE 格殺。
- M38：`FAILED_PRECONDITION` 當紅 ⇒ 被第一格殺。
- M39：external 下 switch 總數閘拿掉 ⇒ 被「2 台」格殺。
- M40：有界重讀拿掉（只讀一次）⇒ 被「null 兩次後變 false」格殺。
- M41（廣化）：`probe_ok` 為 null 算 answered ⇒ 被「五次都 null」格殺。
- 每顆寫「被哪一格殺」；`check_gate_anchors.py HEAD` 全 ok。

### 5.3 新檔 `tests/shell/test_live_p1_common.sh`＋`mutate_live_p1_common.sh`（§4.3 的三個 helper；`source _common.sh` 進 subshell、`curl` stub 回 fixture 圖）

- `controller_program_set`：log 裡 s1、s2 ⇒ `1,2`；沒有那一行 ⇒ 空；`s10` ⇒ `10`（不是 `1`）。
- `kernel_up_set`：圖裡 s1、s2 up、s3 down ⇒ `1,2`；全 down ⇒ 空。
- `await_kernel_up_set`：期望 `1,2`，圖序列「全 down、全 down、s1 s2 up」⇒ rc 0、輸出檔說第 3 次到；期望 `1,2` 但圖是 `1,2,3` up ⇒ 到逾時 rc 1、訊息列出 3 多了；**期望為空 ⇒ rc 1 立刻**（控制）；圖裡 s3 up 而期望 `1,2` ⇒ 不算到達。
- 變異至少 4 顆：期望為空放行、「不在集合裡要 down」拿掉、逾時改成 rc 0、`s10` 解析成 `1`。0 存活，2 控制。
- `bash -n` 八支 live 腳本；03 沒有 dry-run，SUMMARY 明說 03 本身沒跑過。

### 5.4 其餘

`test_ndt_{honesty,up_down_robust,status_check_baseline,round_baseline,status_residue_row,check_sample_rate,up_target}.sh` 全綠（P2-D 的 `rerun-D` 清單）；`mutate_ndt_check_sample_rate.sh` 0 存活。

## 6. 交件

- 同分支新 commit（revert 一顆＋實作若干顆；訊息第一行說清楚是哪一段契約）；不推、不併。
- `scratch/overnight-2026-09-05/hunt-0911/fix/P2-F-SUMMARY.md`：§1 改了什麼（含行號）、§2 閘門數字（每一個都有 `*.p2f-<sha>.log`）、§3 變異表（哪顆被哪格殺）、§4 round 3 的收穫（那兩個 bug）與為什麼 revert、§5 沒做／沒驗的（明列；至少：03 沒跑過、`switch_state` 在 external＋pipeline 已載時的 `probe_ok: true` 是推論不是量測——orchestrator 的 live 會量）、§6 對 orchestrator 的 live 要看什麼（03 的 `36_`／`46_` 兩檔、`32_` 的讀數、`20_up.txt` 的 `answered` 行與 READING 段）。
- 交件時回一段 ≤ 30 行的摘要：head sha、閘門表、變異表、§5 清單。

## 7. 不在本輪、記為階段三候選（orchestrator 會列給 Adam）

- proxy 的 `probe()` 把 `FAILED_PRECONDITION` 算 `ok: False`：對 liveness 這個問題它是**回答了**（行程活著）；要不要拆成 `alive`／`programmed` 兩個欄位、kernel 的 `p4LivenessFor` 要不要跟著改——動到電源管理的契約（FINDINGS #80、`P4PowerStrategy.cpp:53,161`），Adam 裁。
- `inform_switch_entered` 在 external 下照打（`main.py:863`）——proxy 對一台它沒推 pipeline、不會驅動的交換機說「entered」，與 `kernel_notifier.py:90-94` 自己寫的語意（「pipeline pushed 之後才送」）矛盾；round 1 的假綠就是它給的。
- `stack.sh` 逾時段的舊字「the kernel pulls once and never retries」不對（§2-4）。
- `renotify_until_acknowledged` 30×10 s 的上界與 `CONVERGE_WAIT=300` 同長度，差 1～4 s——不是設計，是巧合。
