DELIVERED e1420df26d9d7a3703b814e40ea575402efd4f2e

第二輪做完了：新 head 是 `e1420df2`，每一支閘門都在這個 head 上經 guard 跑過並寫了 log，全部綠。只有一個例外：`mutate_lab_claim_on_writes.sh` 我沒跑，因為它要編 C++。SUMMARY 已改寫，路徑是 `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/NDT-OVS-SUMMARY.md`。

**判官各條的處理（先 commit 測試、看到紅，再修；每項都有具名變異）**
- **F1（blocking）**：`down` 清掉 energy 的 stale pidfile 時會寫一筆零寬的 window 紀錄。之後的 residue 報告從那筆紀錄讀，以前不印警語，現在會印 G-12 的「NO extent … NOT 'this app left nothing'」。變異 M24。
- **F2／F8**：比照 stack.sh `stop_one`，拿程序啟動時間對 pidfile 的 mtime（容許 2 s）。號碼活著、但比檔案晚啟動，就是被回收的號碼，app 和 stack 兩種 pidfile 都直接判 stale，不再去問 group。
  - 用 setsid 起的陌生程序＋`.pgid` 測過實際形狀；對照組（程序比檔案早啟動）不算 stale。變異 M25–M28。
  - 會改一個 rc：被回收號碼的 stack pidfile 現在算 problem，`status --check` 從 0 變成 1。已列進變更表。
- **F3**：斷言 window 右端的 `end=`，並加一個 app log 比 pidfile 新的情況。變異 M21（右端寫成現在時間）。
- **F4**：window 寫不進去就保留 pidfile，`down` 回 1，claim note 會點名。變異 M22。
- **F5／F6**：help 四處改成實話。紀錄的意思在 help、status 的 override 列和手冊都寫成「用了 `--force`」，不是「建起來了」；沒有把結果寫進紀錄本身。變異 M34、M35。
- **手冊**：清 pidfile 那段改寫，來源註解不再寫「待 Adam」；claim 段新增 `ndt up … --force`、overrides 檔的欄位、status 的 override 列。
- **B**：robust 第 21 節改種一個 spawn 出來的 sleep，不再用測試自己的 shell。
- **判官建議的 tests 5–8**：symlink 和「自己 shell 的 group」這兩種 pidfile，`down` 都不刪；自己 claim 帶 `measuring=` 不擋 `up`；原封不動跑 ndt 尾端的 dispatch 區塊，斷言 `ndt up 4 --force` 的重試行和紀錄就是使用者打的；紀錄讀不回就回 5；TAB 或換行不會讓紀錄多出欄位或行。變異 M23、M29–M33。
- **F10**：gate log 現在逐行列出 dirty 的檔案，並寫明跑的測試檔是否就是 HEAD 的。`touched()` 的 `tmp=` 欄開頭就自我驗證一次能讀到非零。

**閘門結果（`e1420df2`，OBSERVED）**

| 閘門 | 結果 |
|---|---|
| 紅燈先行（`146e1024`，測試跑在已 commit 的舊 ndt 上） | 156 格紅 18 |
| 新測試 | 156/0 |
| 新變異閘門 | 35 個變異 0 存活，3 個對照都綠 |
| 26 支會碰 ndt 的 shell 測試 | 全綠 |
| gate-anchor checker | 117/117 |
| 靜態檢查 | 0 |
| `test_teardown_guards`（F9） | 14/0 |
| `test_ndt_lab_session`（F9） | 18/0 |
| 10 個既有變異閘門（含 F9 要的 app_package 75、ovs4_has_sflow 24） | 全部 0 存活 |
| 取證腳本 `serve_evidence`（合併檢查、錨點行號、help 原句） | 合併無衝突、錨點全對、原句全在 |

**要你知道的中途狀況**
- 有兩批閘門是我自己中止的：一批因為要改手冊的一句註解，一批因為 `check_test_tmpdirs` 在 `54d2518a` 報了 rc 1（測試裡一個探針檔名被當成固定的 /tmp 路徑，已在 `e1420df2` 修掉）。中止的 log 都留著，尾巴有註記。
- `serve_evidence` 第一次跑回 rc 2，是我腳本自己的問題：`ndt help` 一定回 2，腳本又開了 pipefail。那份 log 改名保留並附註，修好的重跑 rc 0。

**轉告 ndt serve**：`verbs.RC_SOURCE` 的 8 行（verbs.py:263–270）新舊行號對照表在 SUMMARY §2。那張表是在最終 head 產生的，並由 `serve_evidence.ndtovs-e1420df2.log` 逐一驗過。另外 verbs.py:207 和 248–249 的註解引用了 ndt 行號，併入後也會過期，但它們不是錨點。

**需要你安排**：`mutate_lab_claim_on_writes.sh` 會改 `HttpSession.cpp` 並編 C++ binary，我的規則不准做，所以沒跑。它的錨點不在這個分支動到的檔案裡，anchor checker 對它是 ok。要跑的話需要另一個可以編 C++ 的 session。

`live` 驗證步驟在 SUMMARY §6，已照 F11 改：先 claim、還原 `viz.window`、事先檢查 `app_viz.pgid`、加一格量測在跑時的拒絕、加一格從被覆寫那一方看 status 的 override 列。

Log 都在 `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/*.ndtovs-e1420df2.log`（紅燈先行那份是 `*.ndtovs-146e1024.log`）。
