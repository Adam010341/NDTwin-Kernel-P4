[Co-developed with claude code -- Adam]

# Cut B 摘要：P4 table entry journal 的記錄、折疊、快照（不含重放）

**結論**：Cut B 已完成並 commit，分支 `feat/p4-ternary-journal-b`，頭是 `adcb9081`，未推送。前提：Q1–Q5 尚未答覆，照建議答案 Q4 (a)、Q5 (a) 做；V7 沒做；重放（Cut C）沒做。

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
