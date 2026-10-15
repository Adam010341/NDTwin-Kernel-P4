[Co-developed with claude code -- Adam]

# Cut C 摘要：table-entry journal 的重放（cookie、隔離、startup 與 readopt）

**結論**：Cut C 已實作完成，commit 在分支 `feat/p4-ternary-replay-c`，頭是 `fd208fbd247381b4739bc194830ecd0845ce4fbe`（從 `c7798953` 開出），未推送。要求的每一個 gate 我都在 `fd208fbd` 的拋棄式 clone 裡跑過，全部 rc=0（gate 行見下）。

---

### 1. 分支與 commit（`c7798953..fd208fbd`，共 9 顆，訊息已掃過禁用字與 trailer：0 筆）
- `623a6e4d` p4_proxy: replay the table-entry journal at startup and readopt
- `5025bb57` p4_health: say why T8 can be red once the journal is replayed
- `06a3f55b` tests: gate the table-entry journal replay
- `e8d91655` doc: correct what the Cut B summary said about T8（m7）
- `b3ac9fa2` p4_health: expect T8 GREEN now that the journal is replayed
- `7b1a67bc` tests: do not pin another test's replay in the app-package disclosure test
- `e34fc894` tests: mutate the generation in main's journal headers
- `f7160dc1` tests: name the T8 observer mutant's file the way the anchor checker reads it
- `fd208fbd` tests: keep the port-guard test's proxy out of the checkout's journal

規模：31 個檔，+3074／−258。最大的幾個：`test_table_entry_replay.py`（新，1108 行）、`mutate_table_journal.sh`（+645）、`test_table_entry_journal.py`（+449）、`rule_journal.py`、`main.py`。

### 2. 每個設計點，與決定它的那一行（行號都是 `fd208fbd` 的）
- **push 一律帶 cookie G**：
  - `p4_client.py:203` 的 `pipeline_cookie`；`:720` 的 `req.config.cookie.cookie = ...`。
  - startup 在 `main.py` confirm_fabric 裡設 cookie。
  - readopt 由 `_with_generation`（`main.py:1824`）設，用的是本次開機的 G，不是 header 裡的 cookie（M-J28）。
  - G 存在 `main._generation`（`:776`），新鑄用 `mint_fabric_cookie`（`:779`）。
- **步驟 0：push 迴圈之前，對每一台讀 COOKIE_ONLY**：
  - 呼叫點 `main.py:2162`，在 mastership settle 之後、push 迴圈之前；external 不做。
  - 讀取方法 `read_pipeline_cookie`（`p4_client.py:686`），timeout 2 s。
  - 判斷由 `rule_journal.cookie_verdict`（`:783`）做。以下全部算未確認：沒回應或 RPC 錯誤（含 FAILED_PRECONDITION）、`has_cookie` 為 False、沒有 header、header 的 cookie 是 null（Cut B 的檔）、cookie 不同。
  - G 由 `fabric_generation`（`:817`）決定：所有確認的交換機必須同一個值，不一致時全部降為未確認，並新鑄一個。
- **隔離或確認**：`TableJournals.settle`（`:970`），在每台的鎖裡做。
  - 未確認：`write_snapshot(header_now, [])`，舊檔 hard link 成 `.q<ns>`，live 檔只剩一行 header。
  - 確認：`reheader`（`:633`）只換 header 的 boot_id 與 cookie，其他每一行 byte 不動，連撕裂行也留著。
- **步驟 1、3–6（startup 與 readopt 共用）**：`TableJournals.replay`（`:1003`）。
  - 每次從檔案重讀。
  - header 的 boot_id 不是本次開機 ⇒ 隔離，報 `unconfirmed_header`。
  - p4info sha 不符或 header 沒有 ⇒ 全部 `stale_pipeline`（`:1040`）。
  - entries sha 不符 ⇒ 淨 insert 照常重放，modify／delete 記 `stale_entries`（`:1042`）。
  - fold 之後依第一次出現的順序寫回，走 writer、source 是 `replay`；淨 delete 遇到 NOT_FOUND 算已達目標（`:1062`）。
  - 最後寫 snapshot：header 加上成功重放的淨紀錄。
- **startup 呼叫點**：`main.py:2242`，在 package entries 之後、PRE 之前，持鎖。broken 與 external 只記 `skipped_reason`。
- **readopt 呼叫點**：`main.py:1949`，在 foreign 分支的 `apply_package_entries` 之後。
  - 整個 readopt 包在 `journals.replaying(dpid)` 裡（`main.py:1819`；`rule_journal.py:943`）：先把 pending 設起來，再拿鎖。
  - `finally` 裡先清 pending 再放鎖，失敗的 readopt 也會清。
- **pending／503**：
  - `ReplayPending`（`rule_journal.py:382`）在 write_and_journal 裡檢查兩次：拿鎖前一次，拿到鎖後再一次（`_refuse_pending`，`:937`）。
  - route 回 503 `replay pending`（`api_routes.py:1121`）。
- **揭露**：
  - `switch_state.table_entries.journal.replay` 是最後一次重放的報告（`rule_journal.py:1173`），欄位有 status、attempted、succeeded、unreadable、failed、restored、fresh_fabric、cookie、stale_pipeline、stale_entries、skipped_reason、when。
  - `TABLE_JOURNAL_REPLAYS = True`（`:331`）。
  - POST 回應的 `journal.replay` 改成 `REPLAYED_WHEN` 這句話。
  - `TABLE_ENTRY_RECORDED_NOT_REPLAYED` 已刪；multicast 的常數原文保留（Q5 a）。
- **boot_identity 的契約**：改成「除了 `journal.replay.restored` 列出的那些」，並提醒會自己重送規則的 app 先讀這份報告（`boot_identity.py:33`）。
- **API docstring**：寫進了重放的條件、未確認寫入的契約（§5.3）、§10-4 的 not_found 記錄、modify 沒有對應的安全做法、Q4 (a) 的缺行風險。

**我自己做、設計沒寫到的小決定**（沒有停下來，因為都是錯誤處理或細節；請你判斷要不要改）：
1. snapshot／reheader 寫失敗（OSError）時記一次 failure，這台本次開機的 `journaled` 因此變 false，報告帶 `snapshot_error`。另一個選項是只記錄、不撤回 `journaled`。
2. stale 的紀錄算進 `attempted`，也列進 `failed` 並寫明原因。所以「全部都 stale」報出來是 `failed`，不是 `nothing-to-replay`。
3. COOKIE_ONLY 的 timeout 用 2 s，和 `probe` 一樣。
4. 確認的交換機每次開機會產生兩份隔離檔（步驟 0 一份、步驟 6 一份），keep=10 等於保留大約 5 次開機的歷史。

### 3. 已裁定與審查項目怎麼處理
- **M1**：`_was_absent`（`rule_journal.py:405`）＋`:459`。第一筆是 not_found delete 的 key 從「不在」開始；第一筆是 ok delete 的仍從「在」開始，`test_a_delete_with_nothing_before_it_is_still_a_delete` 保留。
  - 測試兩種順序、boot-entry 的情形、「只看第一筆」，還有 records_from_net 的 round-trip。
  - 每一項配一個 mutant：M-J91／91b／91c／91d。
  - 審查的 route 序列（p10 insert；p20 delete 得到 NOT_FOUND；p20 insert）在 stub 測試與真 bmv2 試驗裡都驗證了：兩筆都會回來。
- **Q3／m3**：owner 檢查留在鎖裡。
  - 新測試 `The503ComesBeforeAnyRefusalTest`：一個 client 本來會回 409 的寫入，排在被佔住的鎖後面 ⇒ SwitchBusy，writer 從沒被叫到；遇到 pending ⇒ 立刻 ReplayPending。
  - mutant M-J111：把 owner 檢查移到鎖之前。
  - 503 那一列 docstring 改成「沒有驗證過，再送一次可能得到任何答案」。
- **m1**：app_package、telemetry_by_name、p4_priority_refusal、p4_probe 四個 gate 都在最終頭跑過，全綠。
- **m2**：M-J92（writer 回傳的 key 丟掉 priority）、M-J92b（`table_entry_key` 丟掉 priority），外加 ternary 版的 key 測試。另外補了 range／optional 經 route 記錄 key 的測試。
- **m4**：屬證據層面。這一輪每份 log 第一行都是 commit、最後一行都是 rc=N（例外見第 8 節）；diff stat 見第 1 節。
- **m5**：
  - 新增 `p4_proxy/tests/journal_isolation.py`：設定 `NDTWIN_TABLE_JOURNAL_DIR` 指向暫存目錄；如果 main 已經先被 import 就直接 raise。14 個 import main 的測試檔都先 import 它。
  - 新增 `tests/shell/check_no_stray_table_journal.sh`：先在單一 process 裡 discover 整個目錄，再一檔一 process 跑一次，比對 `.run/table_entry_journal` 前後的檔名與 sha。
  - 看紅過兩次：
    - `red_m5_isolation_disabled.log`：isolation 掏空時，C 的 startup 測試會寫進 checkout 的 `.run`。
    - `red_m5_perfile_port_guard.log`：在 `f7160dc1`，per-file 那一段抓到 `test_port_guard.py`。那支測試用子程序起真的 proxy，單獨跑時會寫 s1–s10。這是第一次全套 gate 的 `dot_run_after` 抓到的，已在 `fd208fbd` 修好。
- **m6**：決定是 **snapshot 本身不拿鎖，但要求呼叫者持鎖**：`_replace_with` 在沒人持鎖時 raise RuntimeError（`:657`）。
  - 為什麼：§5.2 要求同一把鎖涵蓋 append 與 snapshot；readopt 必須從 push 之前一直握到 snapshot 之後（§5.5），而 `threading.Lock` 同一個 thread 拿兩次會死鎖。
  - startup 沒有並行寫入，但也照樣持鎖，規則因此一致。
  - mutant：M-J103（拿掉檢查）、M-J94b（startup 不持鎖）、M-J104（步驟 0 不持鎖）、M-J20b（readopt 不持鎖）。
  - Cut B 清單 m6 的其他子項：(b) header 統一成一種形狀（`_header_bytes`，M-J107）；(d) 清掉死掉的 snapshot 留下的 temp 檔（M-J105／105b）；(e) snapshot 保留 live 檔的 mode（M-J106）；(f) keep=10 補了測試（M-J40c）。(c) 不算問題：步驟 0 永遠在任何 append 之前。
- **m7**：`SUMMARY-cut-b.md` 第 10 項已更正（`e8d91655`）：`observe_a.py:306-311` 會產生 `a:journaled`，所以只有 B 時 T8 是 RED，不是 NOT RUN。
- **Cut C 清單其他項**：
  - item 1：startup 與 readopt 的呼叫點都有了，刪掉呼叫的 mutant 是 M-J94 與 M-J93。
  - item 3：unreadable 一路帶進報告，torn line 經過 reheader 保留下來（M-J101）。
  - item 5：靠 M1 加上「淨 delete 遇到 NOT_FOUND 算達成」解決（M-J98／98b）。
  - item 7：佔位字串已拿掉。
  - B-shaped 檔（header 的 fabric_cookie 是 null）會被隔離、不重放：`test_a_cut_b_file_with_no_cookie_in_its_header_is_set_aside_and_not_replayed`，mutant M-J22c。
- **n2、n3**：n2 改了 a_p4info 的註解。n3 新增「頂層 NOT_FOUND、沒有 per-update 原因 ⇒ 不記」的測試，mutant M-J112。
- **n1、n4、n5**：沒有改（n1 要動舊 merge 的訊息，不划算；n5 是很多註解引 DESIGN 章節），列在未完成。
- **T8**：
  - `cells/table.py` 的 `t8_cannot` 文字改成三個真正的理由（`5025bb57`），mutant C-T8。
  - `expected_today.tsv` 的 T8 改成 GREEN，依據寫「Cut C: observed offline, at commit e8d91655 ... (trial-h1.json) ...; no live health.json yet」（`b3ac9fa2`）。
  - collector 測試的假 fabric 加了 `journal_replays` 旗標，並新增 T8 綠／紅測試（mutant C-T8b）。
  - full-scope rollup 從 6/7/3/0 變成 7/6/3/0：T8 是 `tables` 最後一個沒綠的格，現在 tables 在 full 是 CAN。
  - `test_the_prediction_comes_from_the_file...` 改用 C2 當例子。

### 4. Gate 行（都在 `fd208fbd`；clone 在 `scratchpad/c-replay/gate`，已刪；log 在 `scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/`）
- P4 build：p4c 1.2.5.15 (SHA 5b948b037a)；`ndtwin_switch.json` `f1c6e09684a0ef57bf9df8e34a252c16287f76dc3f3ac51df991f80ff6d3d562`；`ndtwin_switch.p4info.txt` `d54ff55208340f3a6b4cf5434de6c278604a99c4fcab07f2e44b5b75e3f2ab67`（`p4build.log`，每份 log 的 header 都有）。
- `mutate_table_journal.log`：`mutation gate: 158 mutations, 0 survived`。8 個控制組全綠，baseline byte-identical（5 個原始檔、6 個測試檔）。`journal_tests_seen_red.txt`：`tests: 183, seen red: 183, never seen red: 0`。
- `mutate_table_entry.log`：`79 mutations, 0 survived`（原 81，退役了 M-B14／M-B20，它們的工作改由 journal gate 的 M-B14b／M-B20b 做）。
- `mutate_table_entry_owner.log`：27/0。`mutate_p4_rule_install_time.log`：27/0。`mutate_roles_binding.log`：194/0。`mutate_p4_exercise_tools.log`：`37 mutations, 0 survived`。`mutate_rule_journal_is_wired.log`：14/0。
- `mutate_app_package.log`：48/0。`mutate_telemetry_by_name.log`：23/0。`mutate_p4_priority_refusal.log`：`9 mutations, 0 survived`。`mutate_p4_probe.log`：6/0。
- `check_gate_anchors.log`：`137/137 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)`。
- `GATE.log`：`GATE: 494 mutations, 0 survived, shards 4/4 ok, commit fd208fbd..., tree 65566a34df66fbd087cae389930ae04071926c71, subject sha 7c5479134e91cf55`。
  - 四個 shard 依序跑，同一個 locale（LANG=en_US.UTF-8），各 rc=0。
  - 時間在 `mut_driver.log`：08:36 → 15:19，約 6 小時 43 分。
- `p4lane.log`：`FAILURES=0`；`klane.log`：`FAILURES=0`（都經 `ci-r2.sh`）。
- `no_stray_table_journal.log`：`ok: one process (2051 tests) and 50 files one by one, and the checkout's table-entry journal is as it was`。`dot_run_after.log`：`p4_proxy/.run does not exist`。
- 健檢套件：
  - `p4h.cells.log` 與 `p4h.cells.py38.log`：各 `Ran 187 tests ... OK`。
  - `p4h.collect.log` 與 `p4h.collect.py38.log`：各 `Ran 188 tests ... OK`。
  - `p4h.recover.log`：`Ran 163 checks, 0 failed`；`p4h.gate_scripts.log`：`Ran 69 checks, 0 failed`。
  - 後兩個是 shell 套件，本身不指定 interpreter（recover 是 bash；gate_scripts 內部用 `PYTHON=/bin/true`），所以各跑一次。
- `s0.log`：`S0 verdict (s0-run/s0.json): COMPLETE`，rc=0。在 `setsid --wait` 底下跑；`s0_procs.log` 記到 17 個行程，`s0_postscan.log` 顯示結束後沒有留下 bmv2。
- `trial-final.log`：`ALL CHECKS PASS`，rc=0。

### 5. 離線試驗（`trial.py`／`trial_boot.py`，在 log 目錄裡）
- **做法**：
  - 拋棄式 `simple_switch_grpc`（throwaway.py：thrift 29500–29599、gRPC 29650–29699，會先確認 port 空著，device id 2），跑 S0 編出來的 hc_main，配 S0 轉出來的 package A。
  - 每一次「proxy 開機」是一個**新的 Python 行程**，所以 BOOT_ID 各不相同。每個行程走真的 `main.build_p4_client` → `main.startup` → `api_routes.table_entry`／`switch_state` → `observe_a.observe_t8` → 真的 cells。journal 目錄放在 log 目錄底下的 trial-work-*。
  - topology 用真的 TopologyManager（不接 kernel notifier）；kernel 與 sFlow 是替身。
- **在 `e8d91655`（`trial-h1.json`，tsv 引的就是這份）與 `fd208fbd`（`trial-final.json`）各跑一次。兩次、兩個 binary（stock `/usr/local/bin/simple_switch_grpc` 與 bmv2-fast `/usr/local/bmv2-fast/bin/simple_switch_grpc`），25 項檢查全部 ok**：
  - **boot 1（新的 bmv2）**：
    - startup 報 fresh_fabric，原因是 FAILED_PRECONDITION。
    - 依序 POST exact、lpm、ternary p10、delete p20、insert p20，答案是 200、200、200、502（NOT_FOUND）、200。
    - 每個 200 都是 `journaled: true`；紀錄的 outcome 是 ok、ok、ok、not_found、ok。
    - T8 GREEN。
  - **boot 2（新行程，同一台 warm 的 bmv2）**：
    - cookie confirmed，G 和 boot 1 相同。
    - replay `complete 4/4`，四筆都是 insert（M1 讓 p20 是 insert，不是 modify）。
    - thrift 讀回 exact、lpm 各 1 筆，t_ternary 2 筆（priority 2147483637 與 2147483627，就是 2³¹−1−p），和 boot 1 結束時一樣。
    - header 寫的是 boot 2 的 BOOT_ID；`journaled: true`；T8 GREEN。
  - **boot 3（停掉 bmv2、起一台新的）**：
    - fresh_fabric（FAILED_PRECONDITION），attempted 0，thrift 上沒有任何一筆 API 的 entry。
    - live 檔只剩 header；warm 時期的 journal 以原 byte 留在隔離檔裡；新鑄了一個 G。
- **行程衛生**：記下每一個 pid（`trial-*.json` 的 started：每輪 4 個 bmv2、6 個 boot 行程）。/proc 前後掃描都乾淨；只停自己起的、而且用 pid 停。

### 6. 看紅過的
- **mutant**：journal gate 158 個；Cut C 新增的有 M-J4、5、6、6b、10、15、16、16b、17、18、18b–e、19、20、20b、22、22b–e、25、25b、26、27、28、28b、91、91b–d、92、92b、93、94、94b、95、95b、97、97b、98、98b、99、100、101、101b、102–113，以及 M-J40c。
  - Cut B 的 M-J30a、30c、30e 在常數改成 True 之後等於原碼，所以重寫或刪掉；M-J30 反過來改成「常數 False」。
  - 開發時第一輪 gate 有一個 survivor（M-J91d），我改強測試之後，正式跑時被殺。
- **健檢 gate**：新增 C-T8、C-T8b，兩個都在 shard 裡被抓到。
- **m5**：兩份 red log（見第 3 節）。
- **跑 gate 時看到並修掉的三個問題**（三次放棄的跑法都封存在 `aborted-b3ac9fa2/`、`aborted-7b1a67bc/`、`aborted-e34fc894/`、`aborted-f7160dc1/`）：
  1. app_package 的一個測試釘了跨測試共用的 replay 狀態（`7b1a67bc`）。
  2. check_gate_anchors 讀不懂 `"$PKG/observe_a.py"` 這種寫法（`f7160dc1`）。
  3. test_port_guard 的子程序寫進了 `.run`（`fd208fbd`）。

### 7. 我在設計沒寫到的地方，照字面做的（列出選項，沒有自己改）
1. **`NDTWIN_TABLE_JOURNAL=off` 時**：照 §5.4，步驟 0 仍然要跑（只要求 not read_only）。風險是：off 期間的 API 寫入不會記；如果中間有 API delete 刪掉舊紀錄裡的 entry，下一次以 on 開機時，確認過的舊紀錄會把它重放回來。
   - 選項 (a) 照字面（現狀）。
   - 選項 (b) off 時步驟 0 一律當未確認、隔離。
2. **`client.json_path` 為空的 client**：不會被 push，但照字面仍然會重放，可能撞上已存在的 entry。production 不會發生（build_p4_client 一定帶 json_path）。
   - 選項：把「這次有 push」加進步驟 1、3–6 的條件。
3. **default entry 最後一筆是 delete**：fold 照 Cut B 的寫法淨效果是「無」，設計 §5.4 寫的是「一律 modify」。實際上 bmv2 拒絕 delete default，這種紀錄不會出現，所以沒有改。

### 8. 還沒做或還開著的
- 證據放在被 gitignore 的 scratch log 目錄。還沒歸檔到 audit-raw。
- 兩份 log 的開頭／結尾不完全合規：`p4build-h1.log` 的 commit 行在中間；`red_m5_isolation_disabled.log` 的 rc=1 不在最後一行。
- `test_port_guard.py` 的 PortFreeTest 會起真的 proxy，去連 localhost 上的交換機。這個風險本來就存在，不是 C 造成的；如果這台機器上剛好有 fabric 在跑，它會 push pipeline。C 之後它至少不會再碰 journal。建議另外開一張單。
- 外部工具（例如 tools/p4_exercise、p4_health 的試驗）自己 push pipeline 時不帶 cookie ⇒ 下一次 proxy 開機會判定未確認、隔離。這是安全的方向，記下來。
- n1、n4、n5 沒有處理。
- 新的 stray 檢查沒有接進 CI 的 `l1_unit_tests.sh`（那不在我的檔案範圍）。
- §10-13 的 liveness 註解照設計不在這一刀處理。
