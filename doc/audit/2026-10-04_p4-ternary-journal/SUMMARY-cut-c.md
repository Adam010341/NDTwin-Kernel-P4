[Co-developed with claude code -- Adam]

# Cut C 摘要：table-entry journal 的重放（cookie、隔離、startup 與 readopt）

**結論**：Cut C 已實作完成，commit 在分支 `feat/p4-ternary-replay-c`，頭是 `fd208fbd247381b4739bc194830ecd0845ce4fbe`（從 `c7798953` 開出），未推送。要求的每一個 gate 我都在 `fd208fbd` 的拋棄式 clone 裡跑過，全部 rc=0（gate 行見下）。**這是第一輪的結論**：之後又經過四輪審查與修正，branch 的最終頭是 `392a5746`，merged head 的 gate 是 `GATE: 517 mutations, 0 survived`（第 9–14 節）。

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

規模：31 個檔，+3074／−258。最大的幾個：`test_table_entry_replay.py`（新，1108 行）、`mutate_table_journal.sh`（645 行變動）、`test_table_entry_journal.py`（449 行變動）、`rule_journal.py`、`main.py`。（第二輪更正：645、449 是 `git diff --stat` 的變動行數，也就是增加加刪除，不是只算增加。）

### 2. 每個設計點，與決定它的那一行（行號是 M2 `d92bf1a2` 的；第一輪 `fd208fbd` 的舊行號已換掉，內容是第一輪的設計點，後來各輪的改動見第 9–12 節）
- **push 一律帶 cookie G**：
  - `p4_client.py:203` 的 `pipeline_cookie`；`:722` 的 `req.config.cookie.cookie = ...`。
  - startup 在 `main.py` confirm_fabric 裡設 cookie。
  - readopt 由 `_with_generation`（`main.py:1847`）設，用的是本次開機的 G，不是 header 裡的 cookie（M-J28）。
  - G 存在 `main._generation`（`:776`），新鑄用 `mint_fabric_cookie`（`:779`）。
- **步驟 0：push 迴圈之前，對每一台讀 COOKIE_ONLY**：
  - 呼叫點 `main.py:2185`，在 mastership settle 之後、push 迴圈之前；external 不做。
  - 讀取方法 `read_pipeline_cookie`（`p4_client.py:686`），timeout 2 s。
  - 判斷由 `rule_journal.cookie_verdict`（`:817`）做。以下全部算未確認：沒回應或 RPC 錯誤（含 FAILED_PRECONDITION）、`has_cookie` 為 False、沒有 header、header 的 cookie 是 null（Cut B 的檔）、cookie 不同。
  - G 由 `fabric_generation`（`:851`）決定：所有確認的交換機必須同一個值，不一致時全部降為未確認，並新鑄一個。
- **隔離或確認**：`TableJournals.settle`（`:1016`），在每台的鎖裡做。
  - 未確認：`write_snapshot(header_now, [])`，舊檔 hard link 成 `.q<ns>`，live 檔只剩一行 header。
  - 確認：`reheader`（`:665`）只換 header 的 boot_id 與 cookie，其他每一行都留著，連撕裂行也留著。（第二輪更正：不是「byte 不動」——`reheader` 會丟掉空行，並替沒有換行的最後一行補上 `\n`；原始 byte 只在隔離檔裡完整保留。）
- **步驟 1、3–6（startup 與 readopt 共用）**：`TableJournals.replay`（`:1049`）。
  - 每次從檔案重讀。
  - header 的 boot_id 不是本次開機 ⇒ 隔離，報 `unconfirmed_header`。
  - p4info sha 不符或 header 沒有 ⇒ 全部 `stale_pipeline`（`:1112`）。
  - entries sha 不符 ⇒ 淨 insert 照常重放，modify／delete 記 `stale_entries`（`:1118`）。
  - fold 之後依第一次出現的順序寫回，走 writer、source 是 `replay`；淨 delete 遇到 NOT_FOUND 算已達目標（`:1159`）。
  - 最後寫 snapshot：header 加上成功重放的淨紀錄。
- **startup 呼叫點**：`main.py:2275`，在 package entries 之後、PRE 之前，持鎖。broken 與 external 只記 `skipped_reason`。
- **readopt 呼叫點**：`main.py:1972`，在 foreign 分支的 `apply_package_entries` 之後。
  - 整個 readopt 包在 `journals.replaying(dpid)` 裡（`main.py:1842`；`rule_journal.py:979`）：先把 pending 設起來，再拿鎖。
  - `finally` 裡先清 pending 再放鎖，失敗的 readopt 也會清。
- **pending／503**：
  - `ReplayPending`（`rule_journal.py:390`）在 write_and_journal 裡檢查兩次：拿鎖前一次，拿到鎖後再一次（`_refuse_pending`，`:973`）。
  - route 回 503 `replay pending`（`api_routes.py:1141`）。
- **揭露**：
  - `switch_state.table_entries.journal.replay` 是最後一次重放的報告（`rule_journal.py:1251`，`report()`），欄位有 status、attempted、succeeded、unreadable、failed、restored、fresh_fabric、cookie、stale_pipeline、stale_entries、skipped_reason、when。
  - `TABLE_JOURNAL_REPLAYS = True`（`:331`）。
  - POST 回應的 `journal.replay` 改成 `REPLAYED_WHEN` 這句話。
  - `TABLE_ENTRY_RECORDED_NOT_REPLAYED` 已刪；multicast 的常數原文保留（Q5 a）。
- **boot_identity 的契約**：改成「除了 `journal.replay.restored` 列出的那些」，並提醒會自己重送規則的 app 先讀這份報告（`boot_identity.py:33`）。
- **API docstring**：寫進了重放的條件、未確認寫入的契約（§5.3）、§10-4 的 not_found 記錄、modify 沒有對應的安全做法、Q4 (a) 的缺行風險。

**我自己做、設計沒寫到的小決定**（沒有停下來，因為都是錯誤處理或細節；請你判斷要不要改）：
1. snapshot／reheader 寫失敗（OSError）時記一次 failure，這台本次開機的 `journaled` 因此變 false。（第二輪更正：原本說「報告帶 `snapshot_error`」只對重放自己的 snapshot 成立；步驟 0 的 `reheader` 失敗原本沒有出現在報告裡。第二輪加了 `step0_error`，見第 9 節。）裁定：保留。
2. stale 的紀錄算進 `attempted`，也列進 `failed` 並寫明原因。所以「全部都 stale」報出來是 `failed`，不是 `nothing-to-replay`。裁定：保留。
3. COOKIE_ONLY 的 timeout 用 2 s，和 `probe` 一樣。裁定：改成 `RPC_TIMEOUT_S`（第 9 節）。
4. 確認的交換機每次開機會產生兩份隔離檔（步驟 0 一份、步驟 6 一份），keep=10 等於保留大約 5 次開機的歷史。裁定：保留，並在 `QUARANTINE_KEEP` 的註解寫明。

### 3. 已裁定與審查項目怎麼處理
- **M1**：`_was_absent`（`rule_journal.py:413`）＋`:489`。第一筆是 not_found delete 的 key 的起點是「未知」；第一筆是 ok delete 的仍從「在」開始，`test_a_delete_with_nothing_before_it_is_still_a_delete` 保留。
  - 測試兩種順序、boot-entry 的情形、「只看第一筆」，還有 records_from_net 的 round-trip。
  - 每一項配一個 mutant：M-J91／91b／91c／91d。
  - 審查的 route 序列（p10 insert；p20 delete 得到 NOT_FOUND；p20 insert）在 stub 測試與真 bmv2 試驗裡都驗證了：兩筆都會回來。
- **Q3／m3**：owner 檢查留在鎖裡。
  - 新測試 `The503ComesBeforeAnyRefusalTest`：一個 client 本來會回 409 的寫入，排在被佔住的鎖後面 ⇒ SwitchBusy，writer 從沒被叫到；遇到 pending ⇒ 立刻 ReplayPending。
  - mutant M-J111：把 owner 檢查移到鎖之前。
  - 503 那一列 docstring 改成「沒有驗證過，再送一次可能得到任何答案」。
- **m1**：app_package、telemetry_by_name、p4_priority_refusal、p4_probe 四個 gate 都在最終頭跑過，全綠。
- **m2**：M-J92（writer 回傳的 key 丟掉 priority）、M-J92b（`table_entry_key` 丟掉 priority），外加 ternary 版的 key 測試。另外補了 range／optional 經 route 記錄 key 的測試。
- **m4**：屬證據層面。這一輪每份 log 第一行都是 commit、最後一行都是 rc=N（例外見第 8 節）；diff stat 見第 1 節。（第二輪更正：例外還漏列一份——`journal_tests_seen_red.txt` 沒有 rc 行。）
- **m5**：
  - 新增 `p4_proxy/tests/journal_isolation.py`：設定 `NDTWIN_TABLE_JOURNAL_DIR` 指向暫存目錄；如果 main 已經先被 import 就直接 raise。14 個 import main 的測試檔都先 import 它。
  - 新增 `tests/shell/check_no_stray_table_journal.sh`：先在單一 process 裡 discover 整個目錄，再一檔一 process 跑一次，比對 `.run/table_entry_journal` 前後的檔名與 sha。
  - 看紅過兩次：
    - `red_m5_isolation_disabled.log`：isolation 掏空時，C 的 startup 測試會寫進 checkout 的 `.run`。
    - `red_m5_perfile_port_guard.log`：在 `f7160dc1`，per-file 那一段抓到 `test_port_guard.py`。那支測試用子程序起真的 proxy，單獨跑時會寫 s1–s10。這是第一次全套 gate 的 `dot_run_after` 抓到的，已在 `fd208fbd` 修好。
- **m6**：決定是 **snapshot 本身不拿鎖，但要求呼叫者持鎖**：`_replace_with` 在沒人持鎖時 raise RuntimeError（`:690`）。
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

### 4. Gate 行（都在 `fd208fbd`；本節的數字是當時的，最終的在第 10–14 節，兩邊不能直接比；clone 在 `scratchpad/c-replay/gate`，已刪；log 在 `scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/`）
- P4 build：p4c 1.2.5.15 (SHA 5b948b037a)；`ndtwin_switch.json` `f1c6e09684a0ef57bf9df8e34a252c16287f76dc3f3ac51df991f80ff6d3d562`；`ndtwin_switch.p4info.txt` `d54ff55208340f3a6b4cf5434de6c278604a99c4fcab07f2e44b5b75e3f2ab67`（`p4build.log`，每份 log 的 header 都有）。
- `mutate_table_journal.log`：`mutation gate: 158 mutations, 0 survived`。8 個控制組全綠，baseline byte-identical（5 個原始檔、6 個測試檔）。`journal_tests_seen_red.txt`：`tests: 183, seen red: 183, never seen red: 0`。（第二輪更正：「seen red」的意思是「至少紅過一次」，不是「為了它自己的理由紅過」。`seen_red.py` 的算法：一個測試只要它的 id 出現在任何一行 `also red`，或它的名字是某個 mutant 指名的 killer，就算紅過。183 是兩個測試檔的測試數：140＋43。）
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
- **做法**（第一輪；之後的 m1、m2 序列在第 11、12 節）：
  - 拋棄式 `simple_switch_grpc`（throwaway.py：thrift 29500–29599、gRPC 29650–29699，會先確認 port 空著，device id 2），跑 S0 編出來的 hc_main，配 S0 轉出來的 package A。
  - 每一次「proxy 開機」是一個**新的 Python 行程**，所以 BOOT_ID 各不相同。每個行程走真的 `main.build_p4_client` → `main.startup` → `api_routes.table_entry`／`switch_state` → `observe_a.observe_t8` → 真的 cells。journal 目錄放在 log 目錄底下的 trial-work-*。
  - topology 用真的 TopologyManager（不接 kernel notifier）；kernel 與 sFlow 是替身。
- **在 `e8d91655`（`trial-h1.json`，tsv 引的就是這份）與 `fd208fbd`（`trial-final.json`）各跑一次。兩次、兩個 binary（stock `/usr/local/bin/simple_switch_grpc` 與 bmv2-fast `/usr/local/bmv2-fast/bin/simple_switch_grpc`），檢查全部 ok**。（第二輪更正：每個 binary 是 23 項，不是 25 項；`trial-final.log` 一共 46 行 ok。）
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
- **mutant**（`fd208fbd`）：journal gate 158 個；Cut C 新增的有 M-J4、5、6、6b、10、15、16、16b、17、18、18b–e、19、20、20b、22、22b–e、25、25b、26、27、28、28b、91、91b–d、92、92b、93、94、94b、95、95b、97、97b、98、98b、99、100、101、101b、102–113，以及 M-J40c。
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
   - 裁定：採 (b)（第 9、13 節）。
2. **`client.json_path` 為空的 client**：不會被 push，但照字面仍然會重放，可能撞上已存在的 entry。production 不會發生（build_p4_client 一定帶 json_path）。
   - 選項：把「這次有 push」加進步驟 1、3–6 的條件。
   - 裁定：照這個選項改（第 9、13 節）。
3. **default entry 最後一筆是 delete**：fold 照 Cut B 的寫法淨效果是「無」，設計 §5.4 寫的是「一律 modify」。實際上 bmv2 拒絕 delete default，這種紀錄不會出現，所以沒有改。

### 8. 還沒做或還開著的
- 證據放在被 gitignore 的 scratch log 目錄。還沒歸檔到 audit-raw（第 15 節）。
- 兩份 log 的開頭／結尾不完全合規：`p4build-h1.log` 的 commit 行在中間；`red_m5_isolation_disabled.log` 的 rc=1 不在最後一行。
- `test_port_guard.py` 的 PortFreeTest 會起真的 proxy，去連 localhost 上的交換機。這個風險本來就存在，不是 C 造成的；如果這台機器上剛好有 fabric 在跑，它會 push pipeline。~~C 之後它至少不會再碰 journal。~~（第二輪更正，m-7：這句低估了風險。那個 proxy 在 SIGTERM 到之前已經跑完步驟 0；如果本機有 bmv2 在跑、又沒有 proxy，它會把**它自己的** cookie push 上去，真的 proxy 下一次開機就會把每一份 journal 都隔離。`red_m5_perfile_port_guard.log` 顯示它寫了 s1–s10 的 header。這件事另有一張單追蹤。）
- 外部工具（例如 tools/p4_exercise、p4_health 的試驗）自己 push pipeline 時不帶 cookie ⇒ 下一次 proxy 開機會判定未確認、隔離。這是安全的方向，記下來。
- n1、n4、n5 沒有處理。
- ~~新的 stray 檢查沒有接進 CI 的 `l1_unit_tests.sh`（那不在我的檔案範圍）。~~ 第二輪已接上（第 9 節）。
- §10-13 的 liveness 註解照設計不在這一刀處理。

---

## 後續各輪（第 9–15 節）

**範圍**：第 1–8 節是第一輪（`fd208fbd`）的紀錄，數字都是當時的（行號已換成 M2 `d92bf1a2` 的）。第 9–12 節是第二到第五輪與最後一顆文字 commit；第 13 節是 orchestrator 的裁定與理由；第 14 節是 merged head 的 gate；第 15 節是還開著的。

**縮寫**：`E` ＝ `scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/`（第一輪的 log 在 `E/` 本身，之後各輪在 `E/r2/`、`E/r3/`、`E/r4/`、`E/r5/`）；`G` ＝ `scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1015/`；`I` ＝ `scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/ternary/`（各輪報告與審查）。

**這個 branch 的最終範圍**：`c7798953..392a5746`，16 顆非 merge commit，34 個檔，+4489／−308（`git diff --shortstat c7798953 392a5746`；第一輪是 31 個檔、+3074／−258）。

### 9. 第二輪（review r1 的修正，`f3db4dd1`）

- **為什麼**：review r1（`I/judge-cut-c-c24a7d19-r1.md`）的結論是 MERGE AFTER FIXES，沒有 BLOCKER。兩個 MAJOR：M-1，第一輪的 M1 讓「第一筆是 NOT_FOUND 的 delete」的 key 一律算「不在」，結果一個答案遺失的 boot entry delete 會讓該 entry 在重啟後被留著；M-2，journal 寫入失敗的 note 對 delete 與 modify 是錯的（它們會在重啟後回來）。外加 minor／nit 與七個「我自己做的小決定」的裁定。
- **commit**：`5863be4d` p4_proxy: tighten what the table-entry journal replays；`f3db4dd1` tests: say what the stray-journal check costs in the L1 lane（只改 L1 註解）。
- **改了什麼**（報告：`I/cut-c-r2-report-f3db4dd1.PAUSED.md`）：
  - **M1 修訂**：第一筆是 NOT_FOUND 的 delete，它的 key 起點是「未知」。單獨一筆是淨 delete，遇到 NOT_FOUND 算達成；後面接 insert 時是帶 `unknown_before` 的 insert，遇到 ALREADY_EXISTS 改用 modify 重試一次，只限這種 key。測試翻轉了第一輪的 `:303-306`，並加上遺失答案的重放測試。mutant M-J91e／91f／91g–91j。
  - **journal 關著**：步驟 0 一律當未確認、全部隔離（M-J114）。
  - **`not client.json_path`**：跳過重放（M-J115）。
  - **COOKIE_ONLY 的 timeout** 改 `RPC_TIMEOUT_S`（M-J116）。
  - **報告多了 `step0_error`**：步驟 0 的 `reheader` 失敗現在在報告裡（M-J118、119）；`QUARANTINE_KEEP` 的註解寫明一次開機用兩份隔離檔。
  - **journal 檔以 bytes 讀**，每行在 try 裡 decode，一個壞位元組不會讓 proxy 起不來（M-J117）。
  - **失敗訊息**：新增 `TABLE_ENTRY_JOURNAL_WRITE_FAILED`（一句講完三種 op）與 `TABLE_ENTRY_JOURNAL_OFF`；docstring 拿掉 "always"（M-J124、125）。multicast 的 `TABLE_ENTRY_NOT_JOURNALED` 原文不動（Q5 (a)）。
  - **沒有 per-update 原因的重放失敗**（DEADLINE_EXCEEDED、UNAVAILABLE）：紀錄留在 snapshot 裡（M-J120–122）。
  - **`_pending` 改成計數**（兩個重疊的 readopt，M-J123）；`check_no_stray_table_journal.sh` 接進 `l1_unit_tests.sh` section 3，實測多 77 s。
  - M-J91c 在修訂後被當成等效 mutant 退役；`check_gate_anchors` 137/137。
- **證據**：
  - 最終頭 `f3db4dd1` 只有 journal gate 跑完：`mutation gate: 175 mutations, 0 survived`，rc=0（`E/r2/mutate_table_journal.log`，第 1 行 `commit f3db4dd1…`）。
  - 其餘 gate 沒有在這個頭跑：因為用量用完，在 mutate_table_entry 中途停了（`E/r2/STOPPED`：「only mutate_table_journal had finished (175/0)」；`E/r2/mutate_table_entry.log` 是沒有 rc 行的部分 log）。
  - 開發頭 `5863be4d` 的跑（journal gate 175/0，seen red 201/201，延伸試驗兩個 binary 各 35 項）的 log 在 10-14 重開機時遺失（`I/INTAKE.md`），只剩報告裡的文字；它們不是最終頭的證據。
  - 這一輪的 M1 修訂有一個缺口（第 10 節的 MAJOR-1）。

### 10. 第三輪（review r2 的修正，`7f69609b`）

- **為什麼**：review r2（`I/judge-cut-c-f3db4dd1-r2.md`）MERGE AFTER FIXES。唯一的 MAJOR（MAJOR-1，第二輪引進的退步）：起點未知的 net delete 被 snapshot 寫成 `delete/ok`，下次開機它後面的 insert 就折疊成 modify，push 之後交換機上沒有該 entry，modify 回 NOT_FOUND，journal 承諾過的 entry 遺失。BLOCKER 只是流程：只有 journal gate 在 `f3db4dd1` 跑過。
- **commit**：`03d8dd78` p4_proxy: keep a delete's unknown start through the journal snapshot；`7f69609b` Refresh two references: T8's journaled line and the stray-journal check's cost。
- **改了什麼**（報告：`I/cut-c-r3-report-7f69609b.md`）：
  - **MAJOR-1**：`rule_journal.py:489` 的 `if unknown:`（原為 `if unknown and op == "insert":`），net delete 也帶 `unknown_before`，snapshot 因此把它寫成「not_found 的 delete＋delete」兩筆。測試四個（lone not_found delete、snapshot round-trip、跨重啟的 insert、跨 readopt 的 insert），類別改名 `ANotFoundDeleteLeavesTheStartUnknownTest`；M-J91c 重新錨定成活的，新 M-J91k。
  - **minor-1（orchestrator 的裁定，第 13 節）**：起點未知的 insert 在 entries 檔變了時記 `stale_entries`，不送 modify（`rule_journal.py:1128`；M-J126）。
  - minor-2 是 DESIGN 的文字（modify fallback 與 stale_entries 的例外）；minor-3 是 stray 檢查的實測時間（`E/r3/stray_check_timing.log`：1:31.50、2075 個測試；`stray_check_timing_at_final_head.log`：1:19.92；兩次都在別的 job 佔著約 2 的 load 下量）；minor-4 與 nit：有界等待取代 sleep、`kept: False`、`retried_as_modify` 在送出之前記、journal 關著且 push 失敗的文字（M-J110 的錨點）、branch 新增行裡的審查編號全部拿掉。
- **證據**：
  - 紅：`E/r3/red_new_tests_on_f3db4dd1.log`，rc=1，Ran 207，failures=7 errors=2（MAJOR-1 的四個測試在舊碼上紅，例如 `:1706-1715` 的 `0 != 1 : the entry inserted at 20`）。
  - journal gate：`mutation gate: 178 mutations, 0 survived`，rc=0（`E/r3/mutate_table_journal.log`，`commit 7f69609b…`）。
  - `E/r3/gate_anchors.log`：137/137；`E/r3/two_test_files_whole.log`：Ran 207 OK。
  - 沒有跑：其他 mutate_*.sh、全 repo 測試、health 的 gate（r3 審查的 BLOCKER，改由第 14 節的 merged head 一次補上）。

### 11. 第四輪（review r3 的修正，`2621a34a`；已被第五輪的 commit 取代）

- **為什麼**：review r3（`I/judge-cut-c-7f69609b-r3.md`）MERGE AFTER FIXES，沒有程式碼的 BLOCKER／MAJOR。它另外指出一個範圍外的遺失形狀：一個答案遺失的 insert，之後 delete/ok，再 insert S，折疊成 modify，push 之後 NOT_FOUND，S 遺失。orchestrator 裁定在這一刀裡修（第 13 節）。
- **改了什麼**（報告：`I/cut-c-r4-report-2621a34a.md`）：
  - **A**：net modify（非 default entry）遇 NOT_FOUND 時改用 insert 重試一次，key 在送出之前記進 `retried_as_insert`（現在是 `rule_journal.py:1144-1155`）；失敗的重試在 `failed` 裡帶 `"retried_as": "insert"`；snapshot 仍保留 modify。ALREADY_EXISTS → modify 的分支同時要求 op 是 insert。
  - 測試六個（`AModifyThatFindsNothingTest`：成功、重啟中途、modify 存在的 entry、INVALID_ARGUMENT 不重試、default entry 不重試、重試失敗），一個既有測試改成以 INVALID_ARGUMENT 拒絕（因為 NOT_FOUND 現在會重試）。mutant M-J130–135，外加 M-J127、128a–c、129。
  - 其餘是審查的 nit：`retried_as` 標在失敗的 ALREADY_EXISTS 項目上、M-J91k 改成單一缺陷、M-J110／M-J126 的錨點、`finding #71` 之類的字樣拿掉、readopt 的 boot entry 測試。
- **證據**：
  - 紅：`E/r4/red_replay_tests_on_7f69609b.log`，rc=1，Ran 214，failures=3 errors=4。
  - journal gate：`mutation gate: 189 mutations, 0 survived`，rc=0（`E/r4/mutate_table_journal.log`，`commit 2621a34a…`）；anchors 137/137（`E/r4/gate_anchors.log`）；兩個測試檔 Ran 214 OK（`E/r4/two_test_files_whole.log`）。
  - bmv2 試驗：新增 m1 序列（insert p10→重啟→insert p20→重啟，即 MAJOR-1 的順序）。`E/r4/trial-r4.log`：`ALL CHECKS PASS`，rc=0，stock 與 fast 各一組，commit `2621a34a`。
  - **紅色對照**：同一個 m1 序列跑在 `f3db4dd1`（MAJOR-1 修正之前）：`E/r4/trial-r4red.log`，`NOT ALL CHECKS PASS`，rc=1，12 行 FAIL（每個 binary 6 行）。

### 12. 第五輪（review r4 的修正，`5ace61c7`）與最後一顆文字 commit（`392a5746`）

- **為什麼**：review r4（`I/judge-cut-c-2621a34a-r4.md`）MERGE AFTER FIXES，沒有 BLOCKER／MAJOR；A 符合裁定。orchestrator 把剩下的 minor／nit 與測試缺口派下去；`2621a34a` 的訊息列了 mutant 編號，而 branch 還沒公開，所以要求 `reset --soft 7f69609b` 重寫成一顆。
- **commit**：`5ace61c7` p4_proxy: replay a modify that finds nothing as an insert（只有這一顆，`2621a34a` 不在 branch 上）。
- **改了什麼**（報告：`I/cut-c-r5-report-5ace61c7.md`）：
  - minor 1：新測試 `test_a_package_entry_that_did_not_go_back_on_leaves_its_modify_to_go_back_as_an_insert`，以及「modify 遇 NOT_FOUND」的前提措辭加上「package 自己的那筆沒有放回去」。
  - **minor 2（只揭露，不改行為；第 13 節）**：由 insert 重試放回去的 entry，在 journal 裡仍是 modify，一旦該交換機的 entries 檔有任何變動，下一次開機就把它當 `stale_entries` 丟掉；寫進 `api_routes.py` 與 DESIGN。
  - nit 1／2：`api_routes.py` 的 modify → insert 子句獨立成一句、四處一個子句的措辭、`report()` docstring 的 `failed[].retried_as`。
  - 測試缺口四個：(a) 兩筆失敗之後 `retried_as` 不外洩（M-J136）；(b) readopt 也走 insert 重試（M-J137）；(c) insert 重試的答案遺失，紀錄留在 journal（M-J138）；(d) 由 insert 重試放回去的 entry 仍以 modify 寫進 snapshot（M-J139，既有測試就會紅，沒有新增斷言）。
  - **bmv2 的 m2／m2b 序列**：K 是 priority 10 的 ternary entry（`v=5`），經 client 直接 insert（不進 journal），POST delete K，POST insert S（`v=6`）→ 重啟兩次；m2b 在第一次重啟之後才 POST insert S。這是會真正走到 insert 重試的序列。
  - `expected_today.tsv` 的 T8 列：`rule_journal.py:1247` → `:1249`（`journaled` 的 return）。
- **證據**：
  - journal gate：`mutation gate: 193 mutations, 0 survived`，rc=0（`E/r5/mutate_table_journal.log`，`commit 5ace61c7…`；193＝189＋M-J136…139）。
  - `E/r5/gate_anchors.log`：137/137（`mutate_table_journal.sh` 一列 ok(174)）；`E/r5/two_test_files_whole.log`：Ran 218 OK；`E/r5/p4_health_cells_tests.log`：187 OK。
  - bmv2 試驗：`E/r5/trial-r5.log`，`ALL CHECKS PASS`，rc=0，192 項 ok；m2 的 insert 重試出現在 `:180`（stock）與 `:226`（fast）。
  - **紅色對照**：同一份試驗（只跑 m2／m2b）在 `7f69609b`：`E/r5/trial-r5red.log`，`NOT ALL CHECKS PASS`，rc=1，48 行 FAIL（四個序列各 12 行）。
  - 各新測試在舊碼上的紅（或以 mutant 證明的紅）：`E/r5/red_new_tests_on_7f69609b.log`（Ran 71，failures=5 errors=6）、`E/r5/red_r130.log`、`red_r136.log`…`red_r139.log`。(a)(c) 在 `7f69609b` 上紅的原因是欄位不存在（`KeyError`），行為層級的紅只由 mutant 證明。
  - review r5（`I/judge-cut-c-5ace61c7-r5.md`）：MERGE，沒有 BLOCKER／MAJOR。minor 1：揭露的範圍比行為窄（readopt 也會丟、第一次放回去之前就已經是 modify 的也會丟）；nit：M-J139 的標籤、`journal_key_of_k` 的 docstring、docstring 順序、DESIGN 一處前提。
- **`392a5746`**（p4_proxy: say which journaled writes a changed entries file drops）：把 r5 的 minor 1 與 nit 1／3／4／5 以**只動 docstring、註解、一個 mutant 標籤、DESIGN 文字**的方式寫進去（4 個檔，`git show --stat 392a5746`：`DESIGN.md`、`api_routes.py`、`test_table_entry_replay.py`、`mutate_table_journal.sh`，+13／−11）。`api_routes.py` 的 POST docstring 現在寫明：journal 當作 modify 或 delete 持有、且指向「journal 看到之前就在交換機上」的 entry（package entry、沒記到 insert 的 entry、或由 replay 以 insert 放回去的）的寫入，在該交換機的 entries 檔有任何變動之後的第一次開機或 readopt 會被當成 stale 丟掉。
  - 證據：`E/r5/text-commit/two_test_files_whole.log`：Ran 218 OK；`E/r5/text-commit/gate_anchors.log`：137/137（兩份的第 1 行都是 `commit 392a5746…`）。這顆沒有另外重跑 journal gate；它在 merged head 的 gate 裡跑（第 14 節：193/0）。

### 13. orchestrator 的裁定與理由

1. **M1 修訂：第一筆是 NOT_FOUND 的 delete，key 的起點是「未知」，不是「不在」**（review r1 M-1；第二輪）。
   - 理由：這個 delete 的前一次嘗試可能已經落地、答案遺失，重試才拿到 NOT_FOUND；若把起點當「不在」，一個 package 的 boot entry 的這種 delete 在重啟後會被留著，`[not_found, insert]` 的使用者 spec 會因 ALREADY_EXISTS 失敗而被丟掉。
   - 「未知」的處理：單獨一筆是淨 delete（遇到 NOT_FOUND 算達成）；後面接 insert 時是 insert，標 `unknown_before`，遇到 ALREADY_EXISTS 改用 modify 重試一次；第一筆是被接受的 delete 時，起點仍是「在」。
   - 第三輪補上：起點未知的 net delete 在 snapshot 裡也必須保留這個標記（MAJOR-1）。
2. **journal 關著 ⇒ 步驟 0 把所有交換機當未確認並隔離**（§7 項目 1，選項 (b)）。
   - 理由：關著的那次開機什麼都不記；若步驟 0 照舊確認，下一次正常開機會把關著期間被 delete 的 entry 重放回來，也就是 Q1 (a) 要防的「昨天的 entry」。代價：關著之前 POST 的 entry 不會再放回去，只留在隔離檔。
3. **沒有 `json_path` ⇒ 不重放**（§7 項目 2）。理由：這種 client 沒有被 push，交換機上什麼都沒清空；重放的每個 insert 都會遇到 ALREADY_EXISTS，snapshot 隨後把仍在交換機上的 entry 丟掉。條件跟 push 迴圈用的是同一個（`main.py:2267`）。
4. **COOKIE_ONLY 的 timeout 用 `RPC_TIMEOUT_S`（5 s），不用 2 s**（§2 項目 3）。理由：這裡一個誤判的「沒回應」會把 journal 永久隔離，probe 的誤判只是暫時的；`p4_client.py` 已經因為 bmv2 在負載下很慢而選了 5 s。代價是 startup 時每台沒回應的交換機最多多等 3 s。
5. **起點未知的 insert 在 entries 檔變了時是 `stale_entries`，不送 modify**（review r2 minor-1；第三輪）。理由：此時交換機上那一筆是新 entries 檔裡 package 的 entry，不是 journal 歷史所指的那一筆；送 modify 會覆蓋它。
6. **net modify（非 default entry）遇到 NOT_FOUND ⇒ 改用 insert 重試一次，key 記進 `retried_as_insert`**（review r3 範圍外的遺失形狀；第四輪）。
   - 理由：push 之後交換機上只有 boot entry，所以「modify 找不到」代表 push 清掉了 journal 之前就存在的 entry；journal 的最後一句是「在，spec 是 S」，insert 它就是還原承諾過的狀態（`journaled: true`）。和 ALREADY_EXISTS → modify 的 fallback 對稱；Cut B＋C 還沒公開，所以在這一刀裡修，不另開單。
7. **對「modify／delete 指向 journal 看到之前就在交換機上的 entry」的 stale 丟棄，只揭露、不改行為**（review r4 minor 2；第五輪，文字在 `392a5746`）。
   - 理由：要補的話，entries 檔變了之後會把新檔已經移掉的 key 重新 insert 回去，那是取捨而不是修正；而且它不是退步（沒有 insert 重試之前，這個 entry 本來就拿不回來）。
8. **停止規則**：第五輪的審查之後，只有 BLOCKER 或 MAJOR 會重開 Cut C；minor／nit 進紀錄或 gate 之後的文件 commit。因此 r5 審查的「我會跑的測試」沒有補（第 15 節）。
9. **計畫變更**：Cut C 不另跑一次單獨的 gate，全部 gate 只在 merged head（acb3c4b7＋Cut C 最終＋locale 最終）跑一次，也就是會進 trunk 的那個樹。

### 14. merged head 的 gate

- 全文：`G/REPORT-merged-trunk-1015.md`。**M1** ＝ `d83a78d9d71035c1fbb9fb71de11cbea403d9dc8`（`acb3c4b7` ＋ `392a5746`）；**M2** ＝ `d92bf1a258cec2d1524652fcff17526926fbcefa`（M1 ＋ `4a4eb94e`，分支 `merge/trunk-1015`）。唯一的衝突是 `expected_today.tsv` 的 T8 那一列，取 locale 的文字、行號取 `rule_journal.py:1249`；`merge-verify.txt`：0 個 blob 對不上。
- **GATE 行**（`G/GATE.log`）：
  `GATE: 517 mutations, 0 survived, shards 4/4 ok, commit d92bf1a258cec2d1524652fcff17526926fbcefa, tree fd872b3ddb9d6eaa87d264675c8aaabcbabf2c26, subject sha e69a74d976c1a022`
- 每一步開始前先過 guard（沒有別的 mutate_／probe.py／simple_switch 行程、磁碟與記憶體下限），並在執行的行程裡讀 `SigBlk`，要求 `SigBlk & 0x4203 == 0`，全部通過；判定一律取自各 log 自己的最後一行 `rc=`。

| Stage | 內容 | 結果 |
|---|---|---|
| B（20:28–20:39，11 分 36 秒） | locale 分支的預檢：anchors、cells／collect 在 py3.13 與 py3.8（各再跑一次 SIGHUP 被擋住的 parent）、recover、gate_scripts、C2R8-5g 部分跑、ValueSet delivery 測試（含 SIGHUP pending）、S0 | 全綠：anchors 137/137；cells 203、collect 192（8 組都 OK）；recover 163／0 failed；gate_scripts 79／0 failed；C2R8-5g 1 mutation 0 survived；S0 COMPLETE（57 項，0 failed） |
| C（20:39–22:50，2 小時 11 分，Cut C 的 r2 step 清單＋r5 trial） | 見下 | 27 步，0 紅 |
| D（22:50–06:33，7 小時 42 分） | health gate 四個 shard | 130／129／129／129 mutations，0 survived；shards 4/4 ok |

- Stage C 的數字（`G/` 下各 log，rc 全是 0）：

| 步驟 | 結果 |
|---|---|
| mutate_table_journal | 193 mutations, 0 survived |
| mutate_table_entry／_owner／p4_rule_install_time | 79／27／27，0 survived |
| mutate_roles_binding | 194，0 survived |
| mutate_p4_exercise_tools／rule_journal_is_wired | 37／14，0 survived |
| mutate_app_package／telemetry_by_name／p4_priority_refusal／p4_probe | 48／23／9／6，0 survived |
| mutate_l1_shell_scoring／test_l1_shell_scoring | 62 killed, 0 survived／165 checks, 0 failed |
| check_gate_anchors | 137/137 cells ok |
| p4lane／klane | FAILURES=0／FAILURES=0 |
| no_stray_table_journal | 一個 process（2086 個測試）與 50 個檔逐一跑，checkout 的 journal 沒有變；77 s |
| dot_run_after | `p4_proxy/.run does not exist` |
| p4h cells／collect（py3.12 與 py3.8）、recover、gate_scripts | 203／192 OK、163／79 checks，0 failed |
| s0 | S0 verdict COMPLETE；結束後掃描沒有留下 bmv2 |
| trial-final | ALL CHECKS PASS（含 m1、m2／m2b 序列）；結束後掃描沒有留下 bmv2 |
| journal_tests_seen_red | `tests: 218, seen red: 218, never seen red: 0` |

- Stage D 四個 shard 的 interpreter 行一致：`interpreter: /home/adam/miniconda3/envs/ryu-env/bin/python3.8 (3.8.20, prefix /home/adam/miniconda3/envs/ryu-env)`；每個 shard 的 `SigBlk & 0x4203 == 0` 都有記錄。
- **和第一輪的數字不能直接比**：第一輪的 `GATE: 494 mutations … subject sha 7c5479134e91cf55` 是 `fd208fbd`、舊的 locale 相依排序；merged head 多了 locale 分支的測試與 mutant，subject sha 的算法也換了（見 `SUMMARY-cut2-offline.md` §11.9）。
- 還沒做：squash 之後記錄「squash commit 的 `tools/p4_health` tree 等於 `fd872b3d`」。

### 15. 還開著的

- **r5 審查「我會跑的測試」（沒有補，依第 13 節的停止規則；`I/judge-cut-c-5ace61c7-r5.md` 最後一段）**：
  1. 把被揭露的 stale 丟棄固定成測試（startup 與 readopt 各一）。
  2. 在第一次重啟之前就改 entries 檔的情形。
  3. ALREADY_EXISTS → modify 的重試答案遺失（`retried_as != "modify"` 的變體會在 M-J138 的測試下存活）[推論]。
  4. readopt 時 net delete 遇到 NOT_FOUND 回報 complete（既有的缺口）。
  5. bmv2 上 readopt 的 insert 重試。
  6. quickmut 與 gate 都印出失敗的斷言（現在只印測試名，所以「紅在自己的斷言還是別的」只能從程式推論）。
- **r5 審查的小項**：`check_gate_anchors` 只解析 M-J136 的第一個 anchor（第二個漂移時會以 SURVIVED 呈現，是 fail closed，只記錄）。
- **PYTHONDONTWRITEBYTECODE**：merged head 的 gate 裡，除了 Stage B 的 S0 那一步，所有步驟都是在 bytecode 寫入關閉下跑的（`runlog.sh` 設了 `PYTHONDONTWRITEBYTECODE=1`；四個 shard 繼承 session 的環境，`G/REPORT-merged-trunk-1015.md` 的 Deviations 第 6 項）。所以 shard 沒有「bytecode 寫入打開」的證據；要不要補一次由下一個 gate 的人決定。
- **L1 註解的數字**：`l1_unit_tests.sh` 的註解寫「1:31 wall … (2075 tests …)」（第三輪的實測，`E/r3/stray_check_timing.log`）；merged head 量到 77 s、2086 個測試（`G/no_stray_table_journal.log`）。註解是程式碼，gate 之後的文件 commit 不改。
- 第 8 節仍開著的：n1、n4、n5；§10-13 的 liveness 註解；`test_port_guard.py` 的風險（m-7 那一段）。
- 證據的歸檔：各輪與 merged head 的 log 在被 gitignore 的 scratch 目錄，歸檔到 audit-raw 的工作在 push 準備裡（尚未推送）。
