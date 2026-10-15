# Cut C 第五輪修正報告（feat/p4-ternary-replay-c，7f69609b → 5ace61c7）

🔴 內容描述尚未合併的資料遺失缺陷：不要貼進 commit、程式註解或任何公開處。
標記：【ran】＝我實際執行並有 log；【read】＝只讀過、沒執行。
E = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-ternary-replay-c/r5/
WT = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ternary-replay-c
（log 行號指該檔案的行號；rj = p4_proxy/proxy_agent/rule_journal.py，rp = p4_proxy/tests/test_table_entry_replay.py，sh = tests/shell/mutate_table_journal.sh，均為 5ace61c7。）

## 1. 最終 commit（只在 branch 上，沒 push）
- **5ace61c7**（只有這一個 commit；2621a34a 已不在 branch 上）
- 父 commit 7f69609b。檔案：expected_today.tsv、DESIGN.md、api_routes.py、rule_journal.py、test_table_entry_journal.py、test_table_entry_replay.py、mutate_table_journal.sh（`git diff --name-only 7f69609b HEAD` 共七個）。
- `git status` 只剩 SUMMARY-cut-c.md 為 M（未 stage、未 commit、沒動）【ran】。soft reset 之後、commit 之前，我看過 `git status` 與 `git diff --cached --name-only`，SUMMARY 不在 cached 裡。
- commit 指令：`git commit -m … -- <七個檔案逐一列出>`；之後為了補一處 docstring 又 `git commit --amend --no-edit -- rule_journal.py expected_today.tsv`。沒用目錄、沒用 `-a`。
- 完整訊息（沒有 trailer，沒有 mutant 編號、review／finding／round／nit 字樣）：

```
p4_proxy: replay a modify that finds nothing as an insert

After the startup push only the package's own entries are on the switch, so a
journaled modify of an entry that existed before the journal began meets
NOT_FOUND. The journal's last word for that key is the spec, so the replay now
retries a non-default modify once as an insert, names the key in
retried_as_insert before sending it, and marks a failed retry with retried_as.
A failed ALREADY_EXISTS fallback is marked the same way.

The report, API and design text now say what the fallbacks do, including that an
entry restored by an insert stays a modify in the journal and is dropped as
stale once the entries file changes. The journal gate gets cases for the new
paths, and a few comments are reworded.
```
- 偏離指定：用 1 個 commit 而不是 2 個。理由：rule_journal.py、測試檔、mutate 腳本裡「行為」與「措辭」的 hunk 交錯在同一批檔案，不互動式 `add -p` 拆不乾淨（見 §5 第 1 點）。
- 對新增行掃過一次：沒有 review／finding／round N／ruling／judge／opus／intake／home 路徑字樣（mutate 腳本裡的 M-J 標籤是該 gate 自己的編號，有前例）【ran，grep】。

## 2. 逐項（檔案:行、測試、mutant、紅色那一行）

### minor 1：case 3 的 replay 測試【ran】
- 測試：rp:1472 `test_a_package_entry_that_did_not_go_back_on_leaves_its_modify_to_go_back_as_an_insert`（另有 helper rp:1468 `journal_key_of_k`）。
  - 設定：package 宣告 B 於 K（port 9）；journal `[modify/ok S(port 5)]` 加一筆 `insert 10.0.0.1`；下次開機用舊 hook 拒絕「port 9 的 INSERT」。
  - 斷言：S（port 5）在交換機上、B 不在；`retried_as_insert == [K 的 key]`；`(attempted, succeeded) == (2, 2)`；status complete、failed 空；交換機收到的 op＝`[modify, insert, insert]`；live 檔的 op＝`[modify, insert]`。
  - (2,2) 的理由：`attempted` 是 journal 折疊後的 net 寫入數（K 的 modify、10.0.0.1 的 insert），不含 package 的 boot entry（B 的 insert 被 hook 拒絕、沒到交換機，也不是 journal 的）。
- 措辭：rj:1148（程式註解）「…wiped by it, or the package's own entry did not go back on…」；rj 步驟 5 docstring（約 :1080-1087，同一個前提的第二處，我順手一起改）；DESIGN.md:342「…被 push 清掉了，或是 package 自己的那筆沒有放回去」。
- 紅色：
  - 7f69609b（沒有 fallback）＋最終測試：`E/red_new_tests_on_7f69609b.log:1788` FAIL，`:1794 AssertionError: 0 != 1 : S is on the switch`。
  - 在 2621a34a 程式上＋最終測試：71 個全綠（`E/red_new_tests_on_2621a34a.log`，Ran 71 OK），因為舊程式本來就對。所以改看 mutant：M-J130（移除 fallback）也把它打紅（gate log:2003 的 also red；quickmut：`E/red_r130.log:12`），M-J139 也打紅（`E/red_r139.log:11`）。

### minor 2：只揭露、不改行為【ran 測試；文字 read】
- api_routes.py:1024-1025（在 package entries 檔變動的 bullet 後加：「An entry the replay restored by an insert stays a modify in the journal, so the first start after any change to that switch's entries file drops it as stale」）。
- DESIGN.md:818（「因為 snapshot 裡這筆仍是 modify，package 的 entries 檔一有變動（任何一行），下一次開機就把它當 `stale_entries` 丟掉…」）。
- `_STALE_ENTRIES`：rj:386-387 改為 "…and this write may have been aimed at one of its entries"。全 repo 沒有測試釘舊文字（grep：只有 rp 的 `startswith("stale_entries")`），所以沒有測試要改。
- rj:1072 docstring 也同步「which may have been aimed at a boot entry of the old file」（見 nit 2）。

### nit 1：api_routes.py 的 modify→insert 子句【read】
- api_routes.py:1033-1037：獨立成一句「Separately, a replayed modify that finds nothing there is sent as an insert, unless the entry is a default entry or the package's entries file has changed since (the modify is then stale first).」；NOT_FOUND-delete 那句只剩 delete→modify 的部分。兩個條件都寫了。

### nit 2：四處一個子句【read】
- sh:946 M-J91c 標籤：「…replayed as a modify (which meets NOT_FOUND and is retried as an insert, so only the op assertions see it)」。gate 仍 caught：`E/mutate_table_journal.log:1199`（also red 三項，:1200-1202）。
- rj:1070-1073：「…which may have been aimed at a boot entry of the old file」。
- rj:1277-1282 `report()` docstring：新增 `failed[].retried_as  "modify" or "insert" when the write that failed was the retry of the journal's op (the entry there keeps the journal's op), else absent`。
- DESIGN.md:493：改成「…例如 bmv2 回的 UNKNOWN（…）。非 default entry 的 modify 回 NOT_FOUND 不算失敗的例子：那一筆會改用 insert 重試（見上面第二個例外）。」

### 測試缺口 (a)–(d)【ran】
| # | 測試（rp 行） | mutant（sh 行） | 紅色那一行（quickmut，在 2621a34a 程式＋最終測試上） | gate 內的 caught 行 |
|---|---|---|---|---|
| (a) | rp:1506 `test_a_failure_after_a_failed_insert_retry_does_not_say_it_was_a_retry`：K 的 modify 遇 NOT_FOUND、insert 重試被拒；第二筆是 boot entry 的 modify（port 6）被 INVALID_ARGUMENT 拒絕、不重試。斷言第二筆沒有 `retried_as`。 | M-J136（sh:1604，`mutant2` 兩個 anchor：把 `retried_as = None` 搬到迴圈上方） | `E/red_r136.log:8-10`：named test → RED，`FAIL: test_a_failure_after_a_failed_insert_retry_does_not_say_it_was_a_retry` | gate log:2023 |
| (b) | rp:1537 `test_a_readopt_puts_back_an_entry_whose_modify_finds_nothing_as_an_insert`：`[delete/ok K, insert S]`，K 不在，走 `readopt`；S 在交換機上、`retried_as_insert == [K]`、writes＝`[modify, insert]`、live 檔 `[modify/ok]`。 | M-J137（sh:1611，readopt 的 replay 拿到 `is_not_found=None`：`api_routes._is_not_found if when == "startup" else None`） | `E/red_r137.log:8-10` RED | gate log:2025 |
| (c) | rp:1553 `test_an_insert_retry_whose_answer_is_lost_stays_in_the_journal_for_the_next_start`：insert 重試的答案遺失（DEADLINE_EXCEEDED）→ `kept` True、`retried_as == "insert"`、`entry.op == "modify"`、snapshot 裡有 `[modify/ok]`、下次開機 S 回來且 failed 空。 | M-J138（sh:1618，`unknown_outcome` 加上 `retried_as is None`，把重試的失聯當拒絕） | `E/red_r138.log:8-10` RED | gate log:2027 |
| (d) | 既有測試 rp:1374 `test_a_modify_that_finds_nothing_after_the_push_goes_back_as_an_insert`（兩次開機都斷言 `restored.op == "modify"` 與 `records == [("modify","ok")]`） | M-J139（sh:1629，retry insert 成功後 `item["op"] = "insert"`，即 snapshot 寫成 insert） | `E/red_r139.log:8-12` RED：該測試以及 case 3、readopt 兩個測試都紅 | gate log:2029 |
- (d) 既有測試已經會紅，所以**沒有新增斷言**。
- 舊 7f69609b 上這幾個測試的紅：(a)(c) 是 `KeyError`（欄位不存在：`red_new_tests_on_7f69609b.log:1742`、`:1769`），不是行為；行為層級的紅由上面的 mutant 證明。(b) 在 7f69609b 是行為紅：`:1803 AssertionError: Lists differ: ['modify'] != ['modify', 'insert']`。
- quickmut.py（E/quickmut.py）只是我用來看單一 mutant 的小工具（套在拋棄式複本上，跑兩個測試檔），**不是 gate**；gate 本身的結果見 §3。

### nit 4：bmv2 的 m2 序列【ran】
- E/trial_boot.py 新增 plan `m2`／`m2a`／`m2c` 與常數 `S_AT_K`；E/trial.py 新增 `one_m2`、`judge_m2`、`ternary_s` 與環境變數 `TRIAL_ONLY_M2`（`TRIAL_ONLY_M1` 保留）。只改了 E 裡複製的檔，R4 沒動。
- K＝priority 10 的 ternary entry（action `set_mark v=5`）；S＝同一 key、`v=6`。每個 binary（stock、fast）各跑 `m2` 與 `m2b`，各用自己的交換機與 journal 目錄。
  - m2：(1) 直接經 P4Runtime client insert K（不經 proxy、不進 journal）；(2) POST delete K → 200；(3) POST insert S → 200 且 `journaled: true`；(4) 重啟 proxy；(5) 再重啟。
  - m2b：(1)(2) 之後重啟，(3) 再 POST insert S，然後重啟兩次。
- 每次重啟後的檢查（每項在 stock／fast 各一）：新 proxy 行程、cookie confirmed；replay complete 1/1、failed 空；`retried_as_insert == [K 的 key]` 且 `retried_as_modify == []`；restored op＝`modify`；thrift 看到 S（`set_mark - 06`）一筆、沒有 `set_mark - 05`；P4Runtime 讀回 1 筆 ternary、priority 10、v=6；live journal 檔＝`[modify/ok S]`（spec `v=6`、key＝K）；`journaled` true。
- 最終 head：`E/trial-r5.log`（commit 5ace61c7，tracked-dirty=0）：**ALL CHECKS PASS，rc=0**（:267-268）。192 項 ok，沒有 FAIL 行。
  - m2-stock :174-194、m2b-stock :195-219、m2-fast :220-240、m2b-fast :241-265。重點行（stock／fast）：`m2 step 4 retried_as_insert == [K], retried_as_modify == []` :180／:226；`m2 step 4 P4Runtime read: one ternary entry, priority 10, v 6` :183／:229；`m2 step 5 thrift: S (v 6) is on the switch, once…` :190／:236；`m2b restart after step 2: replay complete 1/1, the delete (NOT_FOUND = done), nothing retried` :199／:245；`m2b step 5 the live journal file ends as [modify/ok S]` :217／:263。
  - 原有六個 boot 系列與 m1 序列也都 ok（同一份 log :66-173）。前後掃描：`trial-r5_prescan.log`、`trial-r5_postscan.log` 沒有殘留的 bmv2。
- 另外在寫最終 trial 之前，我用同一份 trial 在最終 head 先單跑過 m2 系列一次當試跑（`E/trial-r5dry.log`，ALL CHECKS PASS）。
- **紅色對照（7f69609b，改過 trial 的 TRIAL_ONLY_M2=1）**：`E/trial-r5red.log`（commit 7f69609b，tracked-dirty=0）：**NOT ALL CHECKS PASS，rc=1**（:123-124）。四個序列（m2-stock、m2b-stock、m2-fast、m2b-fast）各有 12 項 FAIL，共 48 項；step 1-3 與重啟後的 cookie 檢查仍 ok。引用（stock m2，其餘三個序列同形）：
  - :35 `FAIL m2 step 4 replay complete 1/1, nothing failed`
  - :36 `FAIL m2 step 4 retried_as_insert == [K], retried_as_modify == []`
  - :37 `FAIL m2 step 4 restored op is the journal's modify`
  - :38 `FAIL m2 step 4 thrift: S (v 6) is on the switch, once, and K's old action (v 5) is not`
  - :39 `FAIL m2 step 4 P4Runtime read: one ternary entry, priority 10, v 6`
  - :40 `FAIL m2 step 4 the live journal file ends as [modify/ok S]`
  - step 5 同樣六項 :43-48；m2b-stock :60-73；m2-fast :81-94；m2b-fast :106-119。
  - 前後掃描 `trial-r5red_prescan.log`／`_postscan.log` 乾淨。

### item 8：tsv T8 列【ran，grep】
- `journaled` 的 return 行因 docstring 變長從 1247 移到 **rule_journal.py:1249**（最終 head `grep -n` 確認）。只改該列的 `rule_journal.py:1247` → `:1249`，其餘不動（`git diff` 只有該列一行）；`rule_journal.py:331`（`TABLE_JOURNAL_REPLAYS = True`）沒動。
- tests.python.test_p4_health_cells：187 tests OK（`E/p4_health_cells_tests.log:130-132`，rc=0 在 :209）。

## 3. 最終 head（5ace61c7，全新 clone）的 gate【ran】
全部用 `E/runlog.sh` 包；每步的 rc 取自**該步自己 log 的最後一行 `rc=N`**（不是 `$?`、不是 wait.log）。

| 步驟 | log | 結果 | rc（log 最後一行） |
|---|---|---|---|
| `bash tests/shell/mutate_table_journal.sh` | `E/mutate_table_journal.log` | `mutation gate: 193 mutations, 0 survived`（:2088）；:1 commit 5ace61c7、tracked-dirty=0；baseline Ran 541 OK（:9-10）；`baseline byte-identical: yes`（:2087）。193＝189＋M-J136…139 | rc=0 |
| `check_gate_anchors.py HEAD` | `E/gate_anchors.log` | `137/137 cells ok (0 not ok, of which 0 were NOT CHECKED AT ALL)`（:150）；mutate_table_journal.sh 一列 ok(174)（:141；r4 是 ok(172)） | rc=0（:151） |
| 兩個 journal 測試檔整份（`tests.test_table_entry_replay tests.test_table_entry_journal`） | `E/two_test_files_whole.log` | Ran 218 tests OK（:1935,:1937） | rc=0（:1975） |
| `tests.python.test_p4_health_cells` | `E/p4_health_cells_tests.log` | Ran 187 OK | rc=0（:209） |
| 完整 trial | `E/trial-r5.log` | ALL CHECKS PASS | rc=0（:268） |
| m2 紅色對照 @7f69609b | `E/trial-r5red.log` | NOT ALL CHECKS PASS（48 FAIL） | rc=1（:124，預期） |

- 每個 mutate／trial／紅色步驟啟動前都過 `E/guard.sh`（log 在 `E/<step>.guard.log`）：`ps` 比對 `mutate_|probe\.py|simple_switch` 為 0 個；`SigBlk` 兩種讀法都記了：shell 自己（`grep SigBlk /proc/$$/status`，與 r4 wait.log 同一種）＝`0000000000010000`，子行程自己（`/proc/self/status`）＝`0000000000000000`；`& 0x4003` 皆為 0（例：`E/mutate_table_journal.guard.log:2-4`、`E/trial_final.guard.log`）。
  - 註：若在 `$(…)` 命令替換裡讀 shell 自己的 SigBlk 會得到 `0x2`（bash 在等命令替換時自己的等待遮罩），那是量測假象；我最初的 guard 因此拒絕了一次，改成不經 `$(…)` 讀取（guard.sh 內有註解）。
- 新 mutant 在 gate 裡的 caught 行：M-J136 :2023、M-J137 :2025、M-J138 :2027、M-J139 :2029（`also red` 清單緊接在後）；case 3 測試出現在 M-J130（:1997 起的 also red）與 M-J139 的 also red 裡。

## 4. 紅色 log 一覽（都在 E）【ran】
- `red_new_tests_on_2621a34a.log`：2621a34a 程式＋最終測試檔（clone 由 2621a34a 建、再 cp 最終 rp 與 sh 進去）：Ran 71 OK（舊程式本來就對，符合預期）。
- `red_r130.log`、`red_r136.log`、`red_r137.log`、`red_r138.log`、`red_r139.log`：同一個 clone 上以 quickmut 套 M-J130／136／137／138／139，各自的具名測試 RED（行號見 §2 表）。
- `red_new_tests_on_7f69609b.log`：7f69609b 程式＋最終測試檔：Ran 71，FAILED (failures=5, errors=6)（:1838-1840 附近）。
- 這幾個 clone 的 `tracked-dirty` 因為覆蓋了最終測試檔而不是 0（刻意）。

## 5. 沒照指定做／要你知道的
1. **只有一個 commit**，不是兩個（§1）。
2. 中途有一次被我自己中止的 gate：第一次 driver 在 f0b74c6c 上跑，開跑約 3 分鐘時我發現 rj 步驟 5 docstring 還留著舊前提（「wiped by it」），於是用 pid 停掉自己的 driver／gate（`kill` 各 pid；沒有 pkill），amend 成 5ace61c7 後整組重跑。f0b74c6c 的殘留 log 在 `E/aborted-19h18/`，**不是**證據；所有證據都是 5ace61c7。停掉後沒有殘留的 ndt-tablejournal-mutate-* 暫存目錄。
3. 為了讓 clone 能含 2621a34a（soft reset 之後它不在任何 ref 上），我在 WT 暫建過本地 branch `tmp/r4-2621a34a-keep`，用完已刪（`git branch -D`）。2621a34a 現在只在 reflog。
4. M-J136 用 `mutant2`（兩個 anchor）才能把 `retried_as = None` 真的搬到迴圈上方；`check_gate_anchors.py` 能解析（ok(174)）。
5. 缺口 (a)(c) 在 7f69609b 上紅的原因是欄位不存在（`KeyError`），行為層級的紅只由 mutant 證明（brief 允許）。
6. (d)：既有測試已經會紅，沒新增斷言。
7. nit 1 的 api_routes 改動、minor 2 的揭露、nit 2 的幾處文字都是**文字**，只有「測試全綠」是 ran，措辭本身是 read。
8. 沒做的：沒有跑其他 mutate_*.sh 或全 repo 測試（只跑指定的 gate、anchors、兩個測試檔、p4_health_cells、trial、紅色對照）；沒有為 minor 2 的殘留（restored 項在 entries 檔變動後被丟）改行為（orchestrator 裁定只揭露）。
9. 刪除：三個 clone（old／pre／final）已刪，刪之前用 `/proc/*/cwd` 確認沒有行程在其下；沒有 sudo、沒有 lab、沒有 `ndt`、沒有 ninja／make（p4c-bm2-ss 編 P4 是 mkclone 的一部分，與 r4 相同）；沒有 push；沒有 `pkill -f`／`pgrep -f`。trial 的 bmv2 皆由 trial.py 以 pid 啟停，前後掃描乾淨。
10. R4 目錄沒動；E 內 `trial.py`／`trial_boot.py`／`trial_run.sh`／`proc_scan.py`／`runlog.sh`／`mkclone.sh`／`unit.sh` 是從 R4 複製後只改路徑與 m2 部分。
