## Cut C 第二輪：依要求停在儲存點

第二輪的程式與測試都做完並 commit 了（`5863be4d`、`f3db4dd1`）。最終頭 `f3db4dd1` 的 gate 只跑完 mutate_table_journal 一項，其餘全部還要重跑。

### 已停止的東西
- gate driver（`r2/driver.sh`）跑到 mutate_table_entry 時，我用 pgid 停了自己的行程群組：driver 1710911、runlog 2016602，以及 setsid 1710910。2018523 在 kill 時已經不存在。
- 之後用 `ps -o pid,pgid,sid,cmd` 查過，沒有任何屬於我的行程留下。
- `r2/STOPPED` 已寫：「STOPPED by request (usage running out) during mutate_table_entry; only mutate_table_journal had finished (175/0) at f3db4dd1」。
- 刪掉的拋棄式 clone：`scratchpad/c-replay/gate`（`f3db4dd1` 的 gate clone），和 `scratchpad/c-replay/tmp`。
  - 先前已刪：`dev2`（`5863be4d` 的開發 clone）、`devtrial2/`。
  - `scratchpad/c-replay/` 只剩小的 dev log 與腳本。

### 第二輪各項

**已完成（`5863be4d`，以及 `f3db4dd1`：只是 L1 註解寫上實測的 77 s）**
- **A，M1 修訂**：第一筆 not_found 的 delete 現在算「未知」。
  - 單獨一筆是淨 delete，遇到 NOT_FOUND 算達成。
  - 後面跟著 insert 時，是帶 `unknown_before` 的 insert；遇到 ALREADY_EXISTS 改用 modify 重試一次，只限這種 key。
  - snapshot 寫成兩筆（not_found delete＋insert），下次開機會折疊回同樣的結果。
  - 測試：
    - 翻轉了 `:303-306` 和 key C；
    - 審查要的遺失答案重放測試：stub 先套用 DELETE，再回 DEADLINE_EXCEEDED；重試得到 NOT_FOUND；重啟後 B 不在；
    - boot entry 上 `[not_found, insert S]` 的測試：S 在交換機上、也在 snapshot 裡；
    - 另外兩個：一般 insert 不會被重試；非 ALREADY_EXISTS 的拒絕不會被重試。
  - mutant：M-J91e（前半）、M-J91f（後半），外加 91g–91j。
  - DESIGN.md 的 §5.4 與 §10-4 已改寫。
- **B，§7-1 (b)**：journal 關著時，步驟 0 一律當未確認、全部隔離。DESIGN.md 那一行已補。測試：關著期間刪掉的 entry，下次開機仍然是刪掉的。mutant M-J114。
- **C，§7-2**：`not client.json_path` 時跳過重放。測試加 mutant M-J115。
- **D**：COOKIE_ONLY 的 timeout 改成 `RPC_TIMEOUT_S`。測試（stub 記下收到的 timeout）加 mutant M-J116。
- **E**：
  - §2-1 加上 m-2：報告新增 `step0_error`。測試讓 `reheader` 丟 OSError；mutant M-J118（拿掉 settle 的 failure 計數）與 M-J119。
  - §2-4：在 `QUARANTINE_KEEP` 的註解補一行，寫明一次開機用掉兩份隔離檔。
- **M-2**：
  - 新增 `TABLE_ENTRY_JOURNAL_WRITE_FAILED` 的句子，一句講完三種 op；新增 `TABLE_ENTRY_JOURNAL_OFF`。
  - multicast 的 `TABLE_ENTRY_NOT_JOURNALED` 原文不動（Q5 (a)），table-entry route 不再用它。
  - docstring 拿掉 "always"，"the rule IS" 改成 "the write IS"。
  - 測試加 mutant M-J124、M-J125。
- **m-1**：journal 檔以 bytes 讀，每行在 try 裡 decode。單元測試與 startup 層級測試各一，mutant M-J117。
- **m-3**：`main.py` 與 `test_app_package_proxy.py` 的過時註解已改。
- **m-5**：沒有 per-update 原因的重放失敗（gRPC status 但沒有 per-update error），紀錄留在 snapshot 裡；per-update 拒絕照舊丟掉。測試各一，mutant M-J120–122。
- **m-6**：`check_no_stray_table_journal.sh` 接進 `l1_unit_tests.sh` section 3（p4_proxy lane 的結尾），實測多 77 s。
- **nits**：
  - REPLAYED_WHEN 與 boot_identity 的措辭：readopt 不讀 cookie；`restored` 包含淨 delete。
  - 503 先後順序的 docstring。
  - `_pending` 改成計數，加了兩個重疊 readopt 的測試（mutant M-J123）。
  - `mutate_table_journal.sh:15` 的 M-J30c 註解。
  - check 腳本 per-file 與單一行程兩種 stray 的訊息分開。
- **gate 錨點**：
  - M-J91c 在修訂後變成等效 mutant，已退役並註明。
  - 其餘全部重新錨定；`check_gate_anchors` 137/137。
- **開發跑（`5863be4d` 的 dev clone）**：
  - journal gate 175 mutations, 0 survived；seen_red 201/201。
  - 延伸試驗兩個 binary 都 `ALL CHECKS PASS`，每個 binary 35 項（readopt：POST 拿到 503 replay pending、push 帶 G、entries 回來；遺失答案的 boot-entry 情況端到端通過；比對了 action params）。
  - 這些是開發跑，不是最終頭的 gate。
- **最終頭 `f3db4dd1`**：`r2/mutate_table_journal.log` 是 175 mutations, 0 survived，rc=0。

**做了一半**
- `doc/audit/2026-10-04_p4-ternary-journal/SUMMARY-cut-c.md`：沒有 commit，留在 worktree 裡。
  - 已用 Edit 改完：23 項／46 ok、seen_red 的算法、+645／+449 是增加加刪除、`journal_tests_seen_red.txt` 沒有 rc 行、reheader 會丟空行並替最後一行補換行、m-7、snapshot_error 的更正、§2／§7 各項的裁定、CI 已接上。
  - 還缺：最後的「第二輪」段落，要等 gate 行出來才能寫。

**沒開始**：無。

### 最終頭 `f3db4dd1` 還要跑的（用 `r2/driver.sh`）
- mutate_table_entry、table_entry_owner、p4_rule_install_time、roles_binding、p4_exercise_tools、rule_journal_is_wired、app_package、telemetry_by_name、p4_priority_refusal、p4_probe
- mutate_l1_shell_scoring、test_l1_shell_scoring、check_test_tmpdirs（l1_unit_tests.sh 改過，所以加了這三項）
- check_gate_anchors、p4lane、klane、stray check、dot_run_after
- p4h：cells 與 collect 在 3.12（`/usr/bin/python3.12`）和 3.8 各跑一次，recover、gate_scripts
- S0
- 延伸試驗（trial-final）
- journal_tests_seen_red（這次會有 commit 行與 rc 行）

全部跑完、都綠之後才寫 `driver.done`，接著寫 SUMMARY 的第二輪段落並 commit。

另外：17:02 時有**別的 session**（`gates-0910/p4-health-locale/r2/`）正在跑 mutate_p4_health。我的 driver 為此等了大約 10 分鐘。恢復時如果它還在跑，driver 會再等，最多 3 小時。

### 不准動的路徑
`git diff --stat fd208fbd HEAD -- tools/p4_health 'tests/python/test_p4_health_*.py' tests/shell/mutate_p4_health.sh tests/shell/sum_p4_health_gate_shards.sh doc/audit/2026-10-03_p4-health-check` 的輸出是空的。

### 健檢會 import 的 p4_proxy 模組，以及這一輪有沒有改
- `proxy_agent.api_routes`：`tools/p4_health/openapi_probe.py` 會 import，S0 會執行它。它連帶 import `p4_client`、`rule_journal`、`topology_manager`、`route_binding` 等。`main.py` 只被 openapi_probe 用 ast 讀 `FastAPI(...)` 那一行。
  - **這一輪改了 `api_routes.py`、`p4_client.py`、`rule_journal.py`、`main.py`。** 沒有新增或刪除任何 route，`FastAPI(...)` 那一行也沒動。
- `p4_proxy/proxy_agent/match_shape.py`：`test_p4_health_collect.py` 以 spec_from_file_location 載入；`tools/p4_exercise/preflight.py` 經 common 也會載入。這一輪**沒改**。
- `p4_proxy/mininet/grpc_ports.py`：`throwaway.py` 用。**沒改**。
- `p4_proxy/mininet/bmv2_binary_override`：`vs_trial.py` 讀。**沒改**。

### Log 位置
- 第二輪：`/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r2/`
  - 已有：`driver.log`、`p4build.log`、`mutate_table_journal.log`、`STOPPED`。
  - 腳本：`driver.sh`、`runlog.sh`、`trial.py`、`trial_boot.py`、`seen_red.py`、`s0_run.sh`、`trial_run.sh`、`procscan.py`、`proc_scan.py`。
- 第一輪的 log 原樣留在上一層目錄。
- 開發跑的 log 在 `scratchpad/c-replay/`：`dev2_gate.log`、`devtrial2.log`、`devtrial2.json`。

### 恢復時的步驟
1. 刪掉 `r2/STOPPED`，重新 clone `f3db4dd1`。
2. 編譯 P4，並只在 clone 裡 symlink venv。
3. `setsid --wait bash r2/driver.sh <clone>`。
4. 看完 log，全綠就寫 `driver.done`。
5. 補 SUMMARY 的第二輪段落並 commit。