[Co-developed with claude code -- Adam]

# Cut B 摘要：P4 table entry journal 的記錄、折疊、快照（不含重放）

**結論**：Cut B 已完成並 commit，分支 `feat/p4-ternary-journal-b`，頭在第二輪之後見最下面「第二輪」；第一輪的頭是 `adcb9081`，未推送。前提：Q1–Q5 尚未答覆，照建議答案 Q4 (a)、Q5 (a) 做；V7 沒做；重放（Cut C）沒做。

🔴 **最重要的一條：重放不存在，所以 `journaled` 一律是 false。**
- 沒有重放，proxy 重啟或 readopt 之後，journal 裡的 entry 還是不會回來。
- 所以 POST 回應與 switch_state 的 `journaled` 全部維持 false，T8 不會在只有 Cut B 的時候變綠。
- 真正為真的事（這筆寫入有沒有記進檔案）放在另一個欄位：回應多 `journal: {recorded, enabled, replay: "not implemented"}`，switch_state.table_entries 多 `journal: {enabled, recorded, failures, record_complete, replay: "not implemented"}`。
- 所有 `journaled` 都經過同一個常數 `rule_journal.TABLE_JOURNAL_REPLAYS`（現在是 False）。**Cut C 把它改成 True 就翻**：回應的 journaled 等於「有記下」、note 消失、switch_state 的 journaled 等於 record_complete、T8 轉綠；`journal.replay` 那時要換成真正的重放報告（型別會從字串變物件）。翻轉後的值已經有測試先釘住（TheClaimFlipsInOnePlace、TheResponseFlipsToo，常數用補丁設成 True 跑）。
- 設計 §6.4 寫「T8 綠，需要 Cut B」是錯的，要到 Cut C 才綠；健檢線的 T8 RED 訊息（cells/table.py:378）與 expected_today.tsv 裡「constant false」的字樣需要健檢線改。

**做了什麼**
- `TableEntryJournal`：每台一個檔 `.run/table_entry_journal/s<dpid>.jsonl`，第一行 header，之後一筆一行；撕裂行容忍；`record` 不丟例外、回 bool。
- `fold_records`：依 entry 身分折疊成淨寫入（不在→在＝insert、在→在＝modify、在→不在＝delete、不在→不在＝無）；default entry 一律 modify；`records_from_net` 讓快照折疊後與原淨結果相同（有測試）。
- `write_snapshot`：tempfile、fsync、hard link 舊檔、`os.replace`、fsync 目錄，只保留最近 10 份隔離檔；crash 在 replace 前舊檔完整（fault injection 測試）。
- `TableJournals.write_and_journal`：先寫交換機、再記 journal、最後才回應；每台一把 `threading.Lock` 同時蓋住寫與記；client 在鎖內才查；journal 寫失敗仍回 200（Q4 a），`failures`+1，這一次開機剩下的時間 `record_complete` 都是 false；delete 被交換機回 NOT_FOUND 時記成 `outcome: not_found` 並照回 502（設計 10-4）。
- default entry 有自己的 key `(dpid, table, "default")`，與「全部欄位省略」的 catch-all 分開（影響 install-time 紀錄與 journal 的 key）。
- 常數拆開：multicast 的 `TABLE_ENTRY_NOT_JOURNALED` 原文不動，table entry 另有兩個。

**驗證**
- p4_proxy 測試 1805 → 1908（+103），含 p4_src/build 時 skipped 1，全綠；tools/p4_exercise 210 → 210。
- 新 gate `mutate_table_journal.sh`：85 個 mutation、0 survivor、6 個控制組全綠、baseline byte-identical；103 個新測試每一個都被至少一個 mutant 弄紅過。
- `mutate_table_entry.sh` 78/0（M-B14、M-B20 重新錨定）；install_time 27/0；rule_journal_is_wired 14/0（它的 baseline 在 526dd41c 本來就紅，缺 setting/ 連結，已修）；app_package 48/0、roles_binding 190/0（要有 p4_src/build）；check_gate_anchors 134/134；check_test_tmpdirs、test_l1_shell_scoring 全綠。
- 與 Cut A 無關、且在 526dd41c 就紅的：p4_heartbeat_w 的 `08_heartbeat.sh --self-test`；a7_dispatch_status 需要 C++ build（依規定沒建）。
- 紅燈證據：舊碼上新測試檔連匯入都失敗（功能不存在）；兩個被改的既有斷言為了「沒有 journal 區塊」而 KeyError；R10 的情境探針在舊樹上沒有 journal 欄位也沒有檔案、在新樹上有。R11、R12、R12b、R13 依設計只靠 mutant 看紅（M-J1、M-J12、M-J13a–c、M-J14、M-J3 等，行號在上面的報告）。

**設計上錯的或沒講清楚的**（細節在報告）
- §6.4 的 T8 預測；§5.3 的 key 來源與 NOT_FOUND delete 的 key；default insert 要記 wire 上的 op；snapshot 要有 records_from_net；Cut B 沒有 startup 的隔離步驟，journal 檔會跨開機累積，Cut C 的步驟 0 要把 `fabric_cookie: null` 當未確認；`fold`／`write_snapshot` 在 Cut C 之前沒有 production 呼叫點；鎖跨 gRPC 寫入，交換機卡住時會佔住 threadpool；任何 import 過 main 的測試之後，route 測試的 POST 會寫進 checkout 的 .run/（已在 TableEntryRouteTestBase 隔離）。

**還沒做**：V7、Q5(b)、重放、cookie／sha 檢查、readopt 的 pending／503、M-J4–10、M-J15–22、M-J24–29。


---

## 第二輪（審查後）的修正

審查結論 MERGE AFTER FIXES（到分支的 hold）。處理如下，每項都有先在 `166b11ac` 的碼上為自己的理由紅過的測試，和一個 mutant。

- **m1**：switch_state 對「報告沒列的交換機」的 fallback 原本寫死 `journaled: false`；改成走 `table_journals.journaled(dpid)`（沒有 journal 就 false）。測試用 dpid 77（別的測試不會給它 counts 項）、常數補丁成 True。
- **m2**：route 現在把 op 正規化一次（`str(op or "insert").strip().lower()`，與 writer 相同），所以 `" DELETE"` 被交換機回 NOT_FOUND 也記成 `not_found`。
- **m3**：新測試用 `main.build_table_journals`（env 指到暫存目錄）寫一筆，讀 header，斷言 `boot_id == BOOT_ID` 與 p4info／entries 的 sha；兩個 mutant：main 不傳 `header_for=`、`TableJournals.journal_for` 丟掉 provider。
- **m4**：選「分開算」：`journal.recorded` 只算被接受的寫入（與 `api_writes` 對得上）；新欄位 `journal.not_found` 算 NOT_FOUND delete 的記錄；記不進去的仍算 `failures`。docstring 與測試同步改。
- **m5**（裁定）：每台的鎖改成帶 timeout 取得，上限 `TABLE_ENTRY_LOCK_TIMEOUT_S = RPC_TIMEOUT_S`；逾時回 503 `switch busy`，什麼都不寫。測試用一個會卡住的 stub Write；mutant：沒有 timeout、route 不傳、常數不是一個 gRPC deadline、503 變 500、逾時還是照寫、帶 timeout 就拒絕。
- 便宜的措辭項：m11 的測試／mutant 名稱、m15 multicast 的過時註解已改；報告標籤的筆誤改在 r2 的 INDEX。

## 給 Cut C 的清單（審查的可以等項目，加上我自己記下的）

1. **fold／write_snapshot／records_from_net／read 沒有 production 呼叫點**（Cut C 才是呼叫端）：驗收要有測試證明 startup 與 readopt 各自呼叫它們，並各有一個刪掉那個呼叫的 mutant。這個分支不可在沒有 Cut C 的情況下進 trunk。
2. **write_snapshot 的缺口（m6）**：(a) 沒有取鎖也沒寫明，設計 §5.2 說鎖要蓋住 append 與 snapshot，否則 record 會落在舊 inode；(b) 兩種 header 格式（snapshot 只留呼叫者給的鍵，`_header_line` 補 null）；(c) link 之後、replace 之前當機，隔離名會與 live 檔同一個 inode 而持續增長；(d) 當機留下的 temp 檔沒人掃；(e) snapshot 之後 live 檔是 mkstemp 的 0600；(f) 預設 keep=10 沒有測試。
3. **fold 丟掉 unreadable 計數（m7）**：「有讀不出來的行就不能報 complete」要靠 Cut C 記得另外呼叫 read()。
4. **fold 對 default 的處理與設計 §5.4 不同（m8）**：最後一筆是 delete 的 default 淨效果記為「無」，設計寫「一律 modify」；理由「交換機會拒絕 delete default」沒驗證，writer 其實會送出那個 DELETE。
5. **孤立的 not_found delete 淨效果是 delete（m9）**：Cut C 的重放要把「淨 delete 遇到 NOT_FOUND」當成已達目標狀態。
6. **install-time 的副作用（m10）**：`switch_state.rules_timed` 現在把 default 與 priority 0 的 catch-all 算成兩筆；default 的 stamp 沒人讀（ryu_flow_stats 不傳 default 旗標）；`entry_key` docstring 的例子不對（ternary 的 catch-all 需要 priority ≥ 1，真正的撞 key 發生在沒有 priority 欄的表）。
7. **測試釘住了佔位字串（m12）**：TheClaimFlipsInOnePlace 釘 `replay == "implemented"`；Cut C 要改成「不是 Cut B 的字串」並換成真正的重放報告。
8. **`.run/` 隔離只靠慣例（m13）**：Cut C 之前加防護（測試啟動時設 `NDTWIN_TABLE_JOURNAL_DIR`，或套件前後比對 `.run/table_entry_journal`）。
9. **gate 的 `mutant()` 吞掉失敗的 anchor assert（m14）**：目前靠 check_gate_anchors 擋住；控制組的 anchor 消失時仍會印 green。
10. **T8**：沒有任何 observer 產生 `a:journaled`，現在跑一輪會是 NOT RUN 而不是 RED；T8 的 RED 文字（cells/table.py:379）過時，屬健檢線。
11. 其他：`record_complete` 對沒有任何寫入的交換機是空洞的 true，也不代表檔案本身；header 的 sha 是檔案第一次建立時的；readopt 還沒取這把表鎖（Cut C 的 pending／503 要接上）；步驟 0 的隔離檔名要沿用 `.q<ns>`，否則 prune 掃不到；被刪掉的 REFUSE 記錄原始檔沒有保留。


---

## 第三輪：搬到 Cut A 之上

**結論**：分支 `feat/p4-ternary-journal-b-on-a`，從公開 trunk `3a47bdb7`（未認證 `ls-remote` 確認）開出，`git merge --no-ff feat/p4-ternary-journal-b`（`70995061`）＝ merge commit `cda9fea3`，再加一顆 gate 的 commit `143fb7b0`。兩邊的行為都保留；程式碼的行為沒有改，只改了測試的綁定、測試的隔離和一行註解。全部 gate 都在 `143fb7b0` 跑、全綠（下面）。未推送。逐條記錄在 gate log 目錄的 `CONFLICTS.md`。

**文字衝突（三個）**
1. `mutate_rule_journal_is_wired.sh`：兩邊加了同樣七行（`setting/` 連結），只有註解裡量紅的 sha 不同 ⇒ 用 trunk 的，檔案與 `3a47bdb7` 逐 byte 相同。
2. `p4_client.py` 的 `write_table_entry`：Cut B 在 `record(...)` 加 `entry.is_default_action`，trunk 改了 log 的 `print`（空 match 標成 "(no match fields)"）⇒ 兩個都留。
3. `api_routes.py` 的 import：Cut B 加 `RPC_TIMEOUT_S`，V7 加 `TableOwnedByNDTwin` ⇒ 取聯集。
- 另外逐檔比對：Cut B 碰過的 13 個檔，merge 後對 trunk 的增刪行＝Cut B 自己的增刪行，對 Cut B 的增刪行＝trunk 自己的增刪行（只差上面 1、3 兩處）⇒ 自動合併的檔沒有掉任何一邊的行。

**語意衝突（合得進去、跑起來才壞）**
4. **Cut B 的 journal 測試寫進了 NDTwin 自己的表**：`a_client` 用 `__new__` 建、沒綁，繼承 `BASELINE`；V7 之下每張表都是 NDTwin 的 ⇒ 116 個測試裡 26 個紅（7 FAIL、19 ERROR），全部是 409 `owned_by_ndtwin`（`red_R1_*.log`）。照 trunk `42c22297` 處理 Cut A 測試的方式、也和 `test_table_entry_route.py` 的 double 一樣：`client.bind_routes(None)`（使用者 pipeline）。
5. **沒有測試說「owner 拒絕不進 journal」**（DESIGN §5.7「owner ndtwin 的表除了 default，都會在 V7 被擋，journal 裡不會出現」）⇒ 新測試 `test_a_write_into_a_table_ndtwin_owns_is_a_409_and_leaves_no_record`（insert 與 delete；stub 先設成回 NOT_FOUND，所以沒有 owner 檢查時 delete 會被記成 `not_found`）＋ gate 的 M-J90（把 owner 檢查換成 `pass`）。看紅：502 != 409（兩個 op）與 `['s1.jsonl'] != []`（`red_R2_*.log`）。
6. **trunk 的 owner 測試會寫進 checkout 的 journal**：`test_table_entry_owner.py`（`ThePostAnswers409Test`）與 `test_table_entry_owner_package.py` 會 import `main`，merge 之後 route 拿到的是真的 `table_journals`，被接受的 POST 寫出 `p4_proxy/.run/table_entry_journal/s1.jsonl`；在共用 checkout 裡那就是 live 的 journal 目錄。看紅：trunk 版會留下檔案、修過的版本不留 `.run`（`red_R3_*.log`）。修法同 Cut B 的 `TableEntryRouteTestBase`（setUp 存起來、設 None、cleanup 還原），斷言不動。
7. `p4_client.py` 的 `ENTRY_SOURCE_REPLAY` 註解「a POSTed entry is not journaled」merge 後不對了 ⇒ 改成「記下了、但還沒有東西重放」。只改註解。

**兩個設計交會的地方，以及由哪一行決定**
- **entry 的身分**：journal 的 key 是從**建好的 entry** 算的 `entry_key(dpid, table, entry.priority, normalise_match(...), default)` ⇒ 就是 Cut A 的身分規則（DESIGN §3.1「身分＝`(dpid, table, priority, 正規化後的 match)`」、「default entry 的 key 要另外造」）；ternary／range／optional 的分支在 merge base 上已經有。不用改；`test_a_ternary_entry_is_recorded_under_its_priority` 釘住 priority。
- **owner 檢查與鎖的先後**：V7 在 `write_table_entry` 裡（DESIGN §4「V7 現在在 `write_table_entry` 裡」），而 §5.3 的 `_write_and_journal` 在每台的鎖裡才呼叫它 ⇒ 409 和其他拒絕一樣在鎖裡決定；排在一個佔住鎖超過 `TABLE_ENTRY_LOCK_TIMEOUT_S` 的寫入後面的 POST，會先拿到 503 而不是 409。V7 自己的「owner 在 build 之前」順序不變。照 §5.3 寫的做；沒有測試釘住 503 與 409 的先後。
- **開機 entry**：`apply_package_entries` 在 `entry_source("boot")` 裡直接呼叫 writer、不經 `write_and_journal` ⇒ 不進 journal（§4），V7 的 boot default 例外不受影響。
- **E1**：`_is_not_found` 讀的就是 502 body 用的 `_p4rt_error`，兩邊都沒改。
- **沒有遇到兩份文件都沒決定的衝突**，所以沒有停下來。

**Gate（全部在 `143fb7b0`、拋棄式 clone 裡、一次一個；p4c 1.2.5.15 (SHA 5b948b037a)；`ndtwin_switch.json` sha256 `f1c6e09684a0ef57bf9df8e34a252c16287f76dc3f3ac51df991f80ff6d3d562`、`ndtwin_switch.p4info.txt` `d54ff55208340f3a6b4cf5434de6c278604a99c4fcab07f2e44b5b75e3f2ab67`；log 在 `scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-journal-b-on-a/`）**
- `mutate_table_journal.sh`：`mutation gate: 99 mutations, 0 survived`（98 個沿用＋M-J90），6 個控制組全綠，baseline byte-identical；`test_table_entry_journal` 的 117 個測試**117 個**都被至少一個 mutant 弄紅過（`journal_tests_seen_red.txt`）。
- `mutate_table_entry.sh` 81/0；`mutate_table_entry_owner.sh` 27/0；`mutate_p4_rule_install_time.sh` 27/0；`mutate_roles_binding.sh` 194/0；`mutate_p4_exercise_tools.sh` 37/0；`mutate_rule_journal_is_wired.sh` 14/0。
- `check_gate_anchors.py HEAD`：`137/137 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)`。
- CI 形狀的兩條 lane（`ci-r2.sh` ＋ `p4lane.sh`／`klane.sh`）：兩條都 `FAILURES=0`。p4lane 裡 journal 117、owner 46、owner_package 5、route 36 全過；跑完 clone 的 `p4_proxy/` 底下沒有 `.run`。
- p4_health 套件沒跑：merge 沒有碰 `mutate_p4_health.sh` 的 WATCHED 清單（`tools/p4_health`、`tools/p4_exercise`、`match_shape.py`、`grpc_ports.py` 與健檢的測試和 gate 腳本）裡的任何一個檔；`tools/p4_health` 唯一 import proxy 的是 `openapi_probe.py`（`api_routes`），這次沒有加或改任何 route 的路徑。

**還開著的**
- 第一、二輪列給 Cut C 的清單全部照舊（重放、cookie、pending／503、m6–m14）；`journaled` 仍然一律 false。
- m13（`.run/` 隔離只靠慣例）這次又多了兩個實例（上面第 6 條），說明它不是假設的風險；防護仍留給 Cut C 之前。
- 503 先於 409 是照 §5.3 推出來的，沒有測試釘住。
- 這一輪的 /proc 掃描有一次抓到「其他行程」：其實是我自己等 gate 結束的 shell（指令字串裡含 gate 名），不在 driver 的祖先鏈上；driver 等了 60 秒、它們結束後才開跑下一個 gate（`driver.log`）。
