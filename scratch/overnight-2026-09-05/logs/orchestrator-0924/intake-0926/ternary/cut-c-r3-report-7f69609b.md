# Cut C 第三輪修正報告（feat/p4-ternary-replay-c，f3db4dd1 → 7f69609b）

🔴 內容描述尚未合併的資料遺失缺陷：不要貼進 commit、程式註解或任何公開處。
標記：【ran】＝我實際執行並有 log；【read】＝只讀過、沒執行。
E = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r3/
worktree = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-replay-c

## 1. Commits（只在 branch 上，沒 push；SUMMARY-cut-c.md 保持未 commit，只改了 §3 M1 那一行）
- 03d8dd78  p4_proxy: keep a delete's unknown start through the journal snapshot
  （rule_journal.py、main.py、api_routes.py、兩個測試檔、mutate_table_journal.sh、DESIGN.md）
- 7f69609b  Refresh two references: T8's journaled line and the stray-journal check's cost
  （expected_today.tsv、l1_unit_tests.sh）
- 兩個 commit 都沒有 trailer，訊息裡沒有審查／finding／round 編號。
- 我先 commit 過一次再 reset --soft 重排成這兩個（中間曾有一個只修 mutant anchor 的小 commit，已併入第一個）。

## 2. 逐項
### MAJOR-1【ran】
- rule_journal.py:489 `if unknown:`（原 `if unknown and op == "insert":`）。records_from_net 沒改。fold_records／records_from_net docstring 已更新（約 :429-440、:497-502）。
- 測試
  - (a) test_table_entry_journal.py:304 `test_a_lone_not_found_delete_is_a_net_delete` 斷言翻成 `unknown_before is True`。
  - (b) test_table_entry_journal.py:322 `test_a_snapshot_of_an_unknown_start_delete_then_an_insert_is_an_insert_marked_unknown`。
  - (c) test_table_entry_replay.py:623 `test_an_insert_after_a_restart_that_replayed_the_not_found_delete_still_comes_back`（四步，中間重啟；第二次重啟後 prio 10／20 都在交換機上、report 為 complete 且 failed 為空、live 檔裡兩筆 insert/ok 都在）。
  - (d) test_table_entry_replay.py:640 `test_an_insert_after_a_readopt_that_replayed_the_not_found_delete_still_comes_back`（同樣序列走 readopt）。
  - 類別改名：ANotFoundDeleteMeansAbsentTest → ANotFoundDeleteLeavesTheStartUnknownTest（:605）。
- 看紅：在 f3db4dd1 程式＋新測試上跑，log ＝ E/red_new_tests_on_f3db4dd1.log（rc=1，Ran 207，failures=7 errors=2）。
  - (a) :1629-1635 `AssertionError: None is not True`
  - (b) :1638-1646 `Lists differ: [('modify', None, {'port': 4})] != [('insert', True, {'port': 4})]`
  - (c) :1706-1715 `AssertionError: 0 != 1 : the entry inserted at 20`
  - (d) :1694-1703 同一句 `0 != 1 : the entry inserted at 20`
  - 修正後同一批測試綠。
- Mutants（E/mutate_table_journal.log）
  - M-J91c 重新錨定成活的（把 `if unknown and op == "insert":` 放回去），具名測試＝(c)。同一行 log 之後列出 (a)(b)(d) 也紅：:1065-1069【ran】。
  - 新 M-J91k（`if op == "insert":`），具名測試 `test_an_ordinary_insert_is_not_marked_unknown_before`，:1070 caught。
    - 它紅在自己的 assertNotIn：fold 對 insert 本來就回傳一筆，所以不會走到 IndexError【read：從程式推論，gate 輸出不印失敗訊息】。

### minor-1【ran】
- rule_journal.py:1118 `if entries_changed:` → stale_entries += 1，理由用共用常數 _STALE_ENTRIES（:386，與原文字相同），`"kept": False`，不進 snapshot，不送 modify。
- 測試 test_table_entry_replay.py:1247 `test_an_unknown_start_insert_is_not_a_modify_over_an_entry_of_a_changed_package`。
- 紅（f3db4dd1）：red log :1674-1682 `Lists differ: ['insert', 'insert', 'modify'] != ['insert', 'insert']`。
- Mutant M-J126（丟掉新條件）caught：mutate log :1731。

### minor-2（DESIGN.md）【read，改的是文件】
- 改了 :340、:487（現在有 modify fallback 例外與 stale_entries 例外）。
- 改了步驟 6：失敗不進新檔，但兩個例外——無 per-update 理由的失敗（DEADLINE_EXCEEDED／UNAVAILABLE）留在新檔；起點未知的 net delete 遇 NOT_FOUND 留下，仍是標記過的 delete。
- §10-4「最後是不在（delete）」那一條加了一句 snapshot 怎麼寫這種 delete（「not_found 的 delete＋delete」兩筆）。其他沒動。

### minor-3【ran】
- E/stray_check_timing.log（commit e53ebb40，即最後一個 commit 之前、只差 l1 註解）：/usr/bin/time -v 牆鐘 1:31.50，2075 個測試（單一 process 38.2 s，之後 50 個檔逐一跑）。
- l1_unit_tests.sh :547-548 註解改成「1:31 wall on a 14-core machine (2075 tests …)」。只動這兩行。
- 在最終 head 7f69609b 又跑一次：E/stray_check_timing_at_final_head.log，牆鐘 1:19.92，同樣 2075 個測試。
- 兩次都是在另一個 job 佔著約 2 的 load 下量的（nproc 14）。註解寫的是第一次的 1:31，不是最終 head 的 1:20。
  - 要改成 1:20 就得再改一個 commit、所有 gate 重跑。是否值得由你決定。

### minor-4
- (a)：由 M-J91k 涵蓋。
- (b) test_table_entry_journal.py:1653 起改成有界等待（3 秒）直到 `_pending["1"] == 2`，逾時 self.fail。
  - 紅：M-J123 下單跑該測試，E/red_minor4b_under_MJ123.log:16 `AssertionError: False is not true : the second readopt is still under way`【ran，手動套 M-J123 的替換在拋棄式 clone】。
  - gate 內 M-J123 也 caught（mutate log :1722）。
  - 老實說：舊的 sleep 版在 M-J123 下一般也紅；這項改的是決定性，不是新的覆蓋。
- (c)：由 readopt 測試 (d) 涵蓋。

### nits【ran，測試方面】
- api_routes.py:1040 改成「that boot's own start sets every switch's journal aside」。
- rule_journal.py:612「the write IS on the switch」。
- 備援：retried_as_modify 在送 modify 之前就加（rule_journal.py:1130）。
  - 測試 test_a_modify_fallback_that_fails_is_still_named_in_the_report（replay.py:1271），紅 :1665-1671 `0 != 1 : the retry was made, and failed`。
- stale_pipeline／stale_entries 的 failed 項目加 `"kept": False`（rule_journal.py:1105、:1109）。
  - 既有兩個測試加了斷言，紅是 `KeyError: 'kept'`（red log :1611-1617、:1620-1626）。
- main.py:2260-2264：journal 關著時壞掉的交換機，文字改成 "the pipeline push failed, and the table-entry journal is off"。
  - 新測試 ABrokenSwitchOnAnOffBootTest（replay.py:1327），紅 :1656-1662 `'journal is off' not found in 'the pipeline push failed; a readopt of this switch replays its journal'`。
  - mutant M-J110 的 anchor 因此改成 `elif i in broken:\n # With the journal off`。check_gate_anchors 先抓到壞掉的 anchor（136/137），已修，最終 137/137。
- 舊標籤：journal 測試檔的段落標題、類別名、M-J91b 標籤（改成「folds to an insert, not to a modify」）都改了。
- 審查編號：移除 test_table_entry_journal.py、test_table_entry_replay.py、main.py、mutate_table_journal.sh、rule_journal.py 裡 branch 新增行的 "(round N)"、m-1／m-2／m-5／M-2／m3／m6／n2／n3／m12／m2、"§7-1 (b)"、"§7-2"、"§2-3"、"M1 (ruling …)"、"as amended 2026-10-12"、"r2's"、"Round 2 (2026-10-12)"、"round 2 of Cut C"，以及 mutant 標籤裡的 "(m-1)" 這類尾綴。
  - 沒動 DESIGN 本身的引用：Q1 (a)、Q4 (a)、Q5 (a)、R13-R26、E1。這些是設計文件的編號，不是審查 finding。
  - 沒動 doc/audit 下除指定行之外的文件。
- expected_today.tsv:19：journaled 的行號 1141 → 1220（`return self.record_complete(dpid) and TABLE_JOURNAL_REPLAYS`）。TABLE_JOURNAL_REPLAYS 的 :331 沒變。
- SUMMARY-cut-c.md :65：「從「不在」開始」→「的起點是「未知」」，未 commit。

## 3. Gate（clone 在 7f69609b，直譯器 p4_proxy/venv/bin/python）
- mutate_table_journal.sh：`mutation gate: 178 mutations, 0 survived`，rc=0【ran】
  - E/mutate_table_journal.log（尾端 2 行；:1 commit 7f69609b、tracked-dirty=0）。
  - 175＋M-J91c＋M-J91k＋M-J126＝178。每個新 mutant 都被具名測試 caught。
  - 跑之前：另一個 gate（p4-health-locale r2，mutate_p4_health）在跑；我的等待腳本每 2 秒查一次 ps，確認空了再等 5 秒複查，15:13:34 起跑（E/wait.log）。
  - 它的 driver.log 15:13:34 寫了 `driver end`；我起跑時 ps 只剩我自己的程序。
- check_gate_anchors.py HEAD：`137/137 cells ok`，rc=0【ran】，E/gate_anchors.log。
- 兩個測試檔整份：Ran 207 tests OK，rc=0【ran】，E/two_test_files_whole.log。
- 中間態（03d8dd78 之前的暫時 head）的錨點／測試 log 在 E/at_03d8dd78/，anchors 該次是 136/137（上面說的 M-J110 anchor）。

## 4. 沒能照指定做的／要你知道的
- 沒有 Gate 之外的全 repo 測試：我只跑了指令要求的兩個測試檔、stray-check 的 2075 個測試（含整個 p4_proxy 套件，單一 process）和 anchors。health 那邊的 gate（mutate_p4_health、cells／collect）我沒跑。這一輪只改了 expected_today.tsv 的一個行號，以及 T8 讀的 `journaled` 的計算沒變【read】。
- l1 註解的數字是 e53ebb40 的量測（見 minor-3）。
- 指令說 minor-3「在最終 head 的 clone 跑一次」：我跑了兩次（先一次才能寫數字，最後 head 再一次），兩個 log 都留著。
- M-J91k 的「紅在自己的 assertion 而非 IndexError」是由程式推論，gate 只印測試名，沒印失敗訊息。
- 所有拋棄式 clone（red／m123／final）已刪（沒有程序在用）。
- 沒有 sudo、沒起 lab、沒 build C++、沒 push。
