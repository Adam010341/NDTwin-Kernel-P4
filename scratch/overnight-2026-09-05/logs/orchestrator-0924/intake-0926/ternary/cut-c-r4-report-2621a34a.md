# Cut C 第四輪修正報告（feat/p4-ternary-replay-c，7f69609b → 2621a34a）

🔴 內容描述尚未合併的資料遺失缺陷：不要貼進 commit、程式註解或任何公開處。
標記：【ran】＝我實際執行並有 log；【read】＝只讀過、沒執行。
E = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r4/
WT = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-replay-c

## 1. Commit（只在 branch 上，沒 push；沒有 trailer、沒有審查／finding／round 編號）
- 2621a34a  p4_proxy: replay a modify that finds nothing as an insert
  - 檔案：rule_journal.py、api_routes.py、test_table_entry_replay.py、test_table_entry_journal.py、mutate_table_journal.sh、DESIGN.md、expected_today.tsv。
  - 只有一個 commit，因為這些檔案互相牽連（mutate 腳本的 anchor 跟著 rule_journal.py 的程式碼走）。
- SUMMARY-cut-c.md 保持未 commit，沒動（`git status` 只剩這一個 M）。

## 2. A：net modify 遇 NOT_FOUND 改用 insert 重試一次【ran】
- rule_journal.py:1143-1155（`elif` 分支，緊貼在 ALREADY_EXISTS → modify 的分支旁，:1125）。三個條件缺一不可：op 為 modify、`spec.get("default_action")` 為假、`is_not_found` 有給且 `is_not_found(exc)` 為真。
- `retried_as_insert.append(key)` 在 `apply(spec, "insert")` 之前（:1152）。成功算 restored；失敗走原本的失敗路徑，failed 項目多一個 `"retried_as": "insert"`（:1174-1176）。
- stale 檢查（apply 之前）沒動；records_from_net 沒動，docstring 寫明 snapshot 保留 modify、每次開機重複這個 fallback（:1080-1086）。
- 報告形狀：`_blank_replay`（:1199）、replay docstring、`report()` docstring（:1270）都加了 `retried_as_insert`。
- api_routes.py 沒有任何地方列出 `retried_as_modify`（我 grep 過整個 repo）。所以我沒有「補欄位」，改成在 :1031-1034 那段已有的 fallback 敘述裡加一個子句講 modify → insert（連同 nit 1 的更正）。
- 測試（test_table_entry_replay.py，類別 AModifyThatFindsNothingTest :1326）：
  - (i) :1374 test_a_modify_that_finds_nothing_after_the_push_goes_back_as_an_insert：歷史 [delete/ok K, insert S]（K 是一次答案遺失的 insert 落地的）。重啟後交換機上有 S、writes＝[modify, insert]、retried_as_insert＝[K]、failed 空；再重啟一次又重複。
  - (ii) :1392 test_an_insert_made_after_a_restart_that_replayed_the_delete_comes_back：重啟中途版。
  - (iii) :1409 modify 一個存在的 entry，不送 insert。
  - (iv) :1422 modify 被 INVALID_ARGUMENT 拒絕：不送 insert、failed、沒有 `retried_as`。
  - (v) :1436 default entry 的 modify 遇 NOT_FOUND：不送 insert。
  - (vi) :1452 insert 重試失敗：在 retried_as_insert 裡、也在 failed 裡且 `retried_as == "insert"`、`entry.op == "modify"`。
- 一個既有測試必須改（行為改變的直接後果）：test_a_write_the_switch_refuses_at_replay_is_reported_and_leaves_the_journal（:1063）原本靠「boot entry 沒放回去 → journal 的 modify 遇 NOT_FOUND 而失敗」，現在這種情況會變成 insert 成功。我把它改成交換機以 INVALID_ARGUMENT 拒絕那筆 modify，其餘斷言不變（attempted 2、succeeded 1、partial、failed 的 op 是 modify、live 只剩 insert），並把理由檢查從 NOT_FOUND 改成 INVALID_ARGUMENT。
- 看紅（用最終的測試檔，套在 7f69609b 的程式上）：E/red_replay_tests_on_7f69609b.log（rc=1，Ran 214，failures=3 errors=4，:1873-1875,:1927）
  - (i) :1832 `AssertionError: Lists differ: ['modify'] != ['modify', 'insert']`
  - (ii) :1848 `AssertionError: 0 != 1 : S is on the switch`
  - (vi) :1857 `AssertionError: Lists differ: ['modify'] != ['modify', 'insert'] : the modify, then the retry`
  - nit 3 的新斷言 :1796 `KeyError: 'retried_as'`
  - (iii)(iv)(v) :1805,:1814,:1823：`KeyError: 'retried_as_insert'`。🔴 老實說：這三個是負向對照，7f69609b 的行為本來就對，所以它們在舊程式上紅的原因只是欄位不存在，不是行為。它們的行為層級的紅由下面的 mutant 證明。
- Mutants（全部在 E/mutate_table_journal.log，189 個裡）：
  - M-J130 移除 fallback → (i) 紅，同時紅 (ii)(vi)：:1894-1897
  - M-J131 任何錯誤都重試 → (iv) 紅：:1898-1900
  - M-J132 default entry 也重試 → (v) 紅：:1901-1902
  - M-J133 insert 之後才記 key → (vi) 紅：:1903-1904
  - M-J134 失敗項目不帶 retried_as → nit 3 的測試與 (vi) 紅：:1905-1907
  - M-J135（我加的）每個 modify 後面都送 insert → (iii) 紅：:1908-1910
- 發現：這 6 個 mutant 在做 gate 之前，我另外用一個小腳本（不是 gate）逐個套在拋棄式複本上、只跑具名測試，全數紅【ran，無 log 存檔，腳本在 scratchpad quickmut.py】。

## 3. B：審查項目
- minor-1（DESIGN）【read，文件】：步驟 6 把「每一筆 net delete 回 NOT_FOUND 算 succeeded 且留在新檔，起點未知的寫成兩筆」獨立成一條，移出失敗例外的清單；A 寫進 :340、:487 附近（步驟 5）、步驟 6（snapshot 保留 modify）與 §10-4。§10-4 的 insert 那半補上 entries 檔變了的例外（nit 7）。其他沒動。
- nit 1【ran 的是測試全綠，read 的是文字】：rule_journal.py:1263-1273（retried_as_modify 「可能已失敗，此時也在 failed」、stale_entries 也算起點未知的 insert）、records_from_net docstring（`records` 計數不保留）、api_routes.py:1031-1034（entries 檔變了就不 fallback）。各一個子句。
- nit 2：rule_journal.py:1125 條件加上 `item["op"] == "insert"`。無法由測試到達（review 已推論不可達），所以沒有為它寫 mutant；M-J91g 的錨點改在同一行、行為不變【read】。
- nit 3：失敗的 ALREADY_EXISTS → modify 項目帶 `"retried_as": "modify"`，`entry.op` 仍是 insert（:1140、:1174-1176）。既有測試 test_a_modify_fallback_that_fails_is_still_named_in_the_report（:1290）加兩個斷言；紅：red log :1796。
- nit 4：M-J91k 改成單一缺陷 `if True:`，標籤改為「every net write is marked…」，具名測試 test_an_ordinary_insert_is_not_marked_unknown_before；gate :1147-1150 caught（同時紅 test_a_folded_journal_folds_to_itself）。
- nit 5：新 mutant（gate log 行號）
  - M-J127 retried_as_modify 在 modify 之後才記：:1884
  - M-J128a/b/c stale 的 kept→True，pipeline／entries／fallback 的 entries 三處各一：:1886、:1888、:1890。三處對應的測試都斷言 kept 的值（既有的 `[f["kept"]…]==[False…]` 與 `assertIs(…, False)`），沒有需要改的測試。
  - M-J129 強制 main.py 的 `if journals.enabled` 分支（改成 `if True`）：:1892，具名測試 test_its_report_says_the_journal_is_off_and_promises_no_replay。
- nit 6：新測試 ALostAnswerOnABootEntryTest.test_a_readopt_puts_back_a_boot_entry_deleted_with_a_lost_answer_then_inserted（:1224）：[delete/not_found B, insert S] 在 package boot entry 上做 readopt，writes＝[insert, insert, modify]（package、被撞到的 insert、modify），retried_as_modify 有 1 筆，S 在交換機上。
  - 🔴 它在 7f69609b 上就綠（它補的是既有路徑的覆蓋，不是新行為）。它的紅是由既有 mutant 帶出來的：M-J91f 等在 gate log 的 :56、:90、:1120 等行都列為 also red（共 25 處）。
- nit 8：M-J110 的 anchor 改成 `        elif i in broken:`（main.py:2260，整個檔案只出現一次，我用 count 驗過，而 :2335 的 `if i in broken:` 是不同字串）。gate :1711 caught。M-J126 的 anchor 也順便改成只靠程式碼 `                        if entries_changed:`，不再靠註解；:1882 caught。
- nit 9：
  - test_table_entry_journal.py「finding #71」→「what PRODUCTION built, not what a test builds by hand」；mutate 腳本 M-J54 標籤改成「(a test that builds its own cannot see it)」；「round 2's log」→「the gate's log」。
  - 依指示 grep `git diff 3a47bdb7 HEAD` 的新增行，另外找到兩處並修掉：api_routes.py:127 的「finding #71: fourteen tests green and no caller」→「the rule journal once had fourteen green tests and no caller」；mutate 腳本一個分節標題「review fixes: …」→ 拿掉「review fixes:」。
  - 沒動的：「ruling Q1 (a)」、「R13-R26」、「DESIGN 5.x」（DESIGN 自己的編號，與 r3 的判斷一致，judge 把它們歸為 DESIGN 自我引用）；api_routes.py:1456 的「finding #71」不是這個 branch 加的（git blame 是 base 之前的 commit）。
  - 重新 grep 後新增行沒有其他 review／finding／round 編號（`nit` 只會命中 `unittest`）。
- 順帶：expected_today.tsv:19 的 `journaled` 行號 1220 → 1247（rule_journal.py:1247 `return self.record_complete(dpid) and TABLE_JOURNAL_REPLAYS`；加了程式碼後行號又移動）。tests.python.test_p4_health_cells 187 個 OK【ran，E/p4_health_cells_tests.log:130-132】。

## 4. Gate（全新 clone，在 2621a34a，直譯器 p4_proxy/venv/bin/python）
- mutate_table_journal.sh：`mutation gate: 189 mutations, 0 survived`，rc=0【ran】。E/mutate_table_journal.log:1966-1967；:1 commit 2621a34a、tracked-dirty=0。189＝178＋11（M-J127、128a/b/c、129、130-135）。
- check_gate_anchors.py HEAD：`137/137 cells ok`，rc=0【ran】。E/gate_anchors.log:150-151；mutate_table_journal.sh 一列 ok(172)（r3 是 ok(164)）:141。
- 兩個測試檔整份：Ran 214 tests OK，rc=0【ran】。E/two_test_files_whole.log:1797,:1799,:1864。
- 跑之前的等待：另一個 branch（p4-health-locale）的 mutate_p4_health 一直在跑，我的 E/wait_then_run.sh 每 5 分鐘查一次 `ps`，確認空了再等 5 秒複查；E/wait.log 從 16:17 起記錄「busy」，18:02:58 起 gate、18:36:40 起 trial。每一步起跑前的 `SigBlk: 0000000000010000`（第 1、2、15 位元皆清）與「0 matching processes at launch」都在 E/wait.log。
- 注意：wait.log 裡 `step … rc=` 那幾行的數字不可信（`$(date)` 把 `$?` 洗掉了），請看各自 log 末尾的 `rc=`。

## 5. C：bmv2 trial【ran】
- 我複製了 r2 的 trial.py、trial_run.sh、proc_scan.py、trial_boot.py 到 E，路徑改成 E；為了新序列，trial_boot.py 加了兩個 plan（m1a＝insert p10 再 delete p20；m1b＝insert p20），trial.py 加 `one_m1`／`judge_m1`（stock 與 fast 各一個自己的交換機與 journal），以及環境變數 TRIAL_ONLY_M1（只為下面的紅色對照）。六個 boot 的原系列沒動。
- 最終 head：`bash E/trial_run.sh <clone> r4` → E/trial-r4.log：`ALL CHECKS PASS`，rc=0（:151-152），commit 2621a34a（:1）。前後掃描 E/trial-r4_prescan.log／_postscan.log 沒有殘留的 bmv2。
- 新序列的檢查（stock :115-131，fast :133-149，全部 ok）。重點行：
  - :119／:137 step 3 重啟後 replay complete 2/2：insert p10，與 NOT_FOUND 的 delete p20（算完成）
  - :121／:139 step 4 insert p20 回 200 且 journaled
  - :124／:142 step 5 重啟後 replay complete 2/2、failed 空、沒有 retry
  - :125／:143 restored 的 op 是兩個 insert
  - :126／:144 thrift：p10 與 p20 都在交換機上
  - :127／:145 P4Runtime 讀回：t_ternary 有 priority 10 與 20
  - :129／:147 journal 裡有 priority 20 的 insert/ok
- 紅色對照：同一份 trial（TRIAL_ONLY_M1=1）跑在 f3db4dd1（MAJOR-1 修正之前）→ E/trial-r4red.log：`NOT ALL CHECKS PASS`，rc=1。step 5 replay、restored ops、step 6 thrift／P4Runtime／journal 共 6 項 FAIL（stock :26-32 附近，fast 同樣），step 1-4 都 ok。所以這個新序列在修正前會抓到遺失，修正後不會。
- 沒做的：trial 只跑了最終 head 與 f3db4dd1 的 m1 序列；沒有在 7f69609b 上跑 trial（不需要）。

## 6. 沒照指定做／要你知道的
1. 「列出 retried_as_modify 的 api_routes.py 文字」不存在，見 §2。
2. 一個既有測試被改（§2 的 WhatDoesNotGoBackTest）。
3. nit 2 的 `item["op"] == "insert"` 無法由測試到達，沒有 mutant（read）。
4. (iii)(iv)(v) 與 nit 6 的測試在 7f69609b 上不是因為行為而紅（§2、§3）。
5. 只有一個 commit，不是 2-3 個（檔案互相牽連）。
6. 沒跑其他 mutate_*.sh 與全 repo 測試；只跑指定的 gate、anchors、兩個測試檔、trial，另外加跑 test_p4_health_cells（因為 tsv 又動了）。r3 judge 提的「其他十二個 gate 在 7f69609b 上沒跑」仍然沒有處理，這不在這次的指令內。
7. 已刪除三個拋棄式 clone（red、final、pre），刪之前確認沒有程序的 cwd 在其下。沒有 sudo、沒有 lab、沒有 build、沒有 push；沒有用 pkill／pgrep -f。
