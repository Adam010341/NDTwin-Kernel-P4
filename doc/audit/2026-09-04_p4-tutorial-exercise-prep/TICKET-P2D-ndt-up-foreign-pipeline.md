# TICKET-P2-D — `ndt up p4 --app` 對「package 自己的 pipeline」的 verify：不等 LLDP、entries 是閘、forwarding 是讀數

orchestrator「9/18 ochestrator」2026-09-18 18:5x 寫；base trunk **`365c60e1`**（P2-A/B/C 全併）。worktree `scratch/overnight-2026-09-05/wt-p2-ndtup-0918`，分支 `feat/p4-app-package-p2-ndtup-0918`。
上位工單 `TICKET-P2-exercise-dataplane.md`（§2.2 fabric 級 skipped、§7 第 7–8 條）；本工單是 **live 驗收找到、離線測試找不到**的洞（P2 §0-2 規定 worker 不 `ndt up`，所以沒人跑過這條路）。

[Co-developed with claude code -- Adam]

## 0. 🔴 紅線（同 TICKET-P2 §0；逐條有效）

1. **永不 `pkill -f`／`pgrep -f`／`killall`**。閘門掃你新增的每一行。
2. **不 sudo、不 `ndt up`、不 `mn`、不碰 lab、不起 bmv2、不 curl :8081／:8000**（主 checkout 的 lab 正在跑 live）。你的測試全部離線：`ndt` 用 `source` 進 subshell 取函式（`tests/shell/test_ndt_app_package.sh` §10 的 `drive_v`＋`VSTUB` 是範本），`curl`／`json_len`／`dataplane_ok` 全 stub。
3. **不建 C++**。
4. shell 測試直接 `bash tests/shell/<x>.sh`；閘門腳本用 `/usr/bin/grep`；Python 一律 `p4_proxy/venv/bin/python`（worktree 已 symlink venv 與 `p4_src/build`）。
5. 只在自己的 worktree、自己的分支 commit：`git commit -F <msgfile> -- <明列到檔案>`。AI 參與的檔案標 `[Co-developed with claude code -- Adam]`；訊息結尾 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。**不推、不併 trunk、不動主 checkout。**
6. **沒看過紅不算交付**：每個新分支都要有一個變異讓它紅；SUMMARY 列「哪個變異被哪顆測試殺」；**每個閘門與套件的 stdout 存 `scratch/overnight-2026-09-05/logs/gates-0910/<gate>.p2d-<sha>.log`**——沒有 log 的數字只是轉述。
7. **檔案所有權**：`tools/test_workflow/ndt`、`tools/test_workflow/stack.sh`、`doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/{_common.sh,02_app_basic.sh}`、`tests/shell/{test_ndt_app_package,mutate_ndt_app_package}.sh`；stack.sh 若要新測試＋閘門，新檔 `tests/shell/{test_stack_await_convergence,mutate_stack_await_convergence}.sh`。既有 `test_ndt_{honesty,up_down_robust,status_check_baseline,round_baseline}.sh` 若因你的改動紅了，改**測試裡對舊行為的斷言**可以，但 SUMMARY 逐條說；不動 `drive_exercise.py`（rc 0 就往下走，它自己有 pingall）、不動 proxy。
8. 行號以實際為準（本工單行號＝`365c60e1`），不符時 SUMMARY 註明。

## 1. 現況：live 於 `365c60e1` 的證據（orchestrator 親自跑；log 在 `scratch/overnight-2026-09-05/logs/orchestrator-0918/live/`）

- `live-p1/02_app_basic`（basic 解答、`--p4` 每台跑 basic.p4、mode ndtwin）**FAIL**：`ndt up p4 --app` exit 1。`20_up.txt`（`live-p1/runs/2026-09-18T095025Z_02_app_basic/`）：
  ```
  waiting for link discovery: want 12 destination paths      ← stack.sh 等滿 CONVERGE_WAIT=300s
  [3/3] verify
    XX  proxy: 4/12 destination paths, never settled
    ok  kernel: 4 switches, 4 up, 16 edges, 4 hosts
    ok  model matches fabric: 4 hosts (...)
    ok  data plane: h1 -> 10.0.2.2 forwards
  up, but not verified -- do not measure on this
  ```
  同一個 fabric：`GET /p4/switch_state` `control_plane.skipped = [install_initial_routes, link_watchdog, lldp_discovery]`、每台 `pipeline.ndtwin False`、`pipeline.skipped [clone_session, sflow_telemetry]`、`table_entries {recorded 5, applied 5, failed 0}`；02 自己的 pingall **12 對全 0% loss**（`43_ping_raw.txt`）。**資料面對，錯在 verify 對「proxy 照 §2.2 不送 LLDP」這件事沒有預期。**
- `drive_exercise.py {basic,source_routing} --which {skeleton,solution} --fabric ndtwin` 四次全 **ERROR**，同一行：`!! 'ndt up p4 --app' exited 1`（`drive-<ex>-<which>-ndtwin.log`）；每次燒 7.5 分鐘（300 s 等 LLDP）。firewall／link_monitor 四次同因（19:10 前跑完，raw 會在同目錄）。
- `02b_app_basic_ndtwin_pipeline`（同 package、NDTwin 自己的 pipeline）**PASS**：`12/12 destination paths (stable)`、`control_plane.skipped []`——對照組，證明差別只在 pipeline。
- `03_app_p4runtime`（mode external）PASS，但 `20_up.txt` 顯示 stack.sh 在 external 下也等滿 300 s 才印 `destination paths NOT CHECKED`——同一個洞的既有版本。

## 2. 碼的現況（`365c60e1`）

- `tools/test_workflow/ndt:2973` `verify_p4 "$topo" "$want_paths" "$app_mode"`——只傳 mode（`app_package_mode`，:2683）。`verify_p4()` :3014-3110：`mode == external` ⇒ 路徑 NOT CHECKED＋forwarding NOT TESTED＋`ready`＋EMPTY 但書；否則等 `all_destination_paths == want` 兩次（:3041-3062）、`verify_p4_graph`、`verify_dataplane`（:2xxx；失敗 ⇒ err＋rc 1）。**verdict 區塊一份、`lab_entry_points p4` 在 `ready` 下一行**（`test_ndt_up_down_robust.sh:1857-1860` 數這個）。
- `app_pipeline_kind [dir]` :1579（C 寫的）：`none | ndtwin | foreign:<d>,<d> | unreadable`，答案來自 `Package.pipeline_is_ndtwin`。`cmd_status` :5297 已算 `pkgpipe` 給 rate rows；**:5443-5451 的「N destination paths (want 12)」與 `problems+=` 沒看 pkgpipe** ⇒ 外來 pipeline 跑著的時候 `ndt status --check` 會紅。
- `tools/test_workflow/stack.sh` `await_convergence` :~165-230：p4 分支只看 `expected_counts`（hosts×(hosts−1)）與 `paths_installed`（>0），不知道 proxy 有沒有在做 LLDP；`components.env` 有 `P4_PROXY_URL`。stack.sh **今天沒有直接的測試**。
- `live-p1/_common.sh:270 run_verify_p4()` 把 `verify_p4` 從 source 進來的 `ndt` 叫出來，三個參數；`02_app_basic.sh:216` 傳 `12 ndtwin`、:221 對 rc 斷言。
- proxy 那邊（不動）：`main.py:911-920` 一台外來 ⇒ `FOREIGN_PIPELINE_FABRIC_SKIPS` 全 fabric、`read_only=True`；訊息「will not send LLDP beacons, watch links or install routes on ANY switch」。

## 3. 契約（裁定＝TICKET-P2 §7 第 10 條；理由寫在那裡）

### 3.1 `verify_p4 <topo> <want_paths> <mode> [<pipeline_kind>]`
第 4 參數＝`app_pipeline_kind "$app_dir"` 的輸出；`up_p4` 在有 `app_dir` 時傳它，沒有 package 時傳空（＝今天的路徑）。**`mode == external` 分支一字不改**（judge 會 diff）。`pipeline_kind` 為空、`none`、`ndtwin` ⇒ 今天的行為。

### 3.2 `pipeline_kind == foreign:<dpids>`（mode ndtwin）——三段，每段各自具名
1. **路徑數：NOT CHECKED，但「proxy 說了它沒做」要親自讀到。** `GET /p4/switch_state` 的 `control_plane.skipped` **含 `lldp_discovery`** ⇒
   `warn "proxy: destination paths NOT CHECKED -- the package's own program runs on dpid <dpids>; the proxy says it sent no LLDP and installed no routes on this fabric (control_plane.skipped: <list>)"`。
   讀不到、或 skipped 裡**沒有** `lldp_discovery` ⇒ `err`＋rc 1（「this script expected the proxy to skip discovery for a package pipeline and the proxy does not say so」——預期與 proxy 不一致是紅，不是綠）。不再等 `all_destination_paths`。
2. **entries 是閘（NDTwin 自己負責的那件事）。** 每台 `switch_state[dpid].table_entries`：`failed != 0` 或 `applied != recorded` ⇒ `err "table entries: the proxy could not apply <failed> of <recorded> on dpid <d> -- see table_entries on GET /p4/switch_state"`，rc 1；全綠 ⇒ `ok "table entries: <applied>/<recorded> applied on <n> switch(es), 0 failed"`。package 沒 entries（recorded 全 0）⇒ `warn` 一行說「the package carries no entries; nothing forwards until something writes some (POST /p4/table_entry)」，不紅。
3. **forwarding 是讀數不是閘。** 照跑 `verify_dataplane`（ping 的權限問題照舊 NOT tested）；通 ⇒ `ok` 同今天；不通 ⇒ **`warn`**：
   `"data plane: <src> cannot reach <dst> -- a READING, not a verdict: under the package's own program (<p4info sha>) whether plain IPv4 forwards is the package's claim, not NDTwin's (a skeleton does not forward; source_routing needs its header). The exercise's driver judges it."`，rc 不變。
   **這是本工單唯一改 verdict 語意的地方，理由：** source_routing 的**解答**對 plain ping 也不通（audit-raw `7af2f352`：靠 send/receive 量 ttl），骨架本來就要紅——閘在這裡等於 driver 永遠拿不到 red／green，只有 ERROR。
4. verdict：`up. ready`（同一個字、同一行、`lab_entry_points p4` 緊接其後，**不加第二個 verdict 區塊**）；之後但書一段（同 external 的 EMPTY 段形狀）：
   `warn "package pipeline: NDTwin discovered no links and installed no routes on this fabric; forwarding is whatever the package's <applied> entries on <n> switch(es) make of it. ndt status quotes no sample rate for it."`

### 3.3 `cmd_status` :5443-5451
`pkgpipe` 是 `foreign:` ⇒ 印 `"  <paths> destination paths reported; none expected -- the package's program on dpid <dpids>, proxy skipped lldp_discovery"`，**不加 problem**；其他 kind 照今天。

### 3.4 `stack.sh await_convergence`（p4 分支）
進迴圈前讀 `$P4_PROXY_URL/p4/switch_state` 的 `control_plane.skipped`；含 `lldp_discovery` ⇒ `info "  link discovery: NOT WAITED -- the proxy says it sends no LLDP on this fabric (control_plane.skipped: <list>)"`，return 0。讀不到、無 `control_plane`、不含 ⇒ 今天的迴圈一字不改。**external 也因此不再等 300 s**（03 今天等滿）。proxy 的 `startup()` 在 uvicorn 開 :8081 之前就印了 skip 訊息（02 的 proxy log :73 在第一個 GET :75 之前），但你要在 SUMMARY 引 `main.py` 的順序證明「切到 :8081 開時 skipped 已定」，或者退而求其次：讀不到 `control_plane` 就 sleep 1 重讀最多 5 次再走舊迴圈。

### 3.5 live-p1
`_common.sh run_verify_p4` 收第 4 參數；新 `run_app_pipeline_kind <pkg>`（同樣 source 進 subshell）。`02_app_basic.sh`：`ndt up` 前不變；:216 改成 `run_verify_p4 "$PKG/ndtwin/topology.json" 12 ndtwin "$(run_app_pipeline_kind "$PKG")"`，先斷言那個值 `== foreign:1,2,3,4`（寫進 raw）；再斷言 `20_up.txt` 含 `destination paths NOT CHECKED` 與 `table entries: 5/5 applied on 4 switch(es), 0 failed`（**數字從 switch_state 算，不寫死 5**）。02b 不動（kind ndtwin）。`bash -n` 兩個檔。

### 3.6 `all_destination_paths == 4` 是什麼
離線（`p4_proxy/tests` 既有 fixture／`ryu_topology.render_destination_paths` 直接呼叫）弄清楚沒有 LLDP 時那 4 條是什麼、kernel 因此收到什麼；**只寫進 SUMMARY，不修**（階段三候選）。

## 4. 測試與閘門

- `tests/shell/test_ndt_app_package.sh` §10 用 `VSTUB` 形式加一節「verify_p4 under a package pipeline」：curl stub 回帶 `control_plane.skipped` 與 `table_entries` 的 JSON（含 lldp／不含 lldp／failed 1／applied≠recorded／recorded 0），`dataplane_ok` stub 回 0 與 1；每個 §3.2 條款一顆紅得了的測試；`cmd_status` 那行、`run_verify_p4` 傳參各一顆。
- `tests/shell/mutate_ndt_app_package.sh` 每個新分支至少一個變異（不讀 skipped 就 warn；failed 不紅；ping 失敗仍 rc 1；foreign 掉進 external 的 NOT TESTED；status 仍加 problem；stack.sh 不看 skipped 就等）；**控制組照舊**（comment-only 綠）。`tests/shell/check_gate_anchors.py <你的 sha>` 全 ok。
- stack.sh：新 `test_stack_await_convergence.sh`（stub `curl`、`expected_counts`、`countdown`）＋ `mutate_stack_await_convergence.sh`；若你找到既有 harness 能覆蓋就用它，SUMMARY 說。
- 跑並存 log：`test_ndt_app_package`、`test_ndt_honesty`、`test_ndt_up_down_robust`、`test_ndt_status_check_baseline`、`test_ndt_round_baseline`、`test_ndt_status_residue_row`、`mutate_ndt_app_package`、`mutate_ndt_check_sample_rate`、新的兩個、driver tests（`p4_proxy/venv/bin/python -m unittest discover -s doc/audit/2026-09-04_p4-tutorial-exercise-prep -p 'test_drive_exercise.py'`）。

## 5. 交付
SUMMARY 在 `scratch/overnight-2026-09-05/hunt-0911/fix/P2-D-SUMMARY.md`：改了什麼（file:line）、每條契約對應哪顆紅測與哪個變異、閘門數字＋log 路徑、§3.6 的答案、異議。分支上 commit 完就停；live 由 orchestrator 跑。
