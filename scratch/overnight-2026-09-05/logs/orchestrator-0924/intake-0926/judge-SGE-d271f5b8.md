# judge-SGE-d271f5b8 (fix/suites-under-gate-env-0927 @d271f5b8, test_build_guard env fix)

## 裁決：MERGE

沒有 BLOCKING 項。這個裁決只根據 worker 在 3db3b9a8／d271f5b8 上的證據和我自己讀的原始碼。協調者在 17fbdd7f 的 rerun 我讀的時候還沒有結果（見 §5），合併後的狀態我沒有拿到實跑證據。

我全程唯讀：沒執行任何東西、沒用 git、沒碰任何行程。

路徑縮寫（完整絕對路徑列在文末）：
- WT＝wt-suites-gate-env-0927
- L＝logs/gates-0910
- D＝scratchpad/tmp/diag_b_3db3b9a8
- S＝intake-0926/sge

---

## BLOCKING

無。

---

## 1. unset 清單是否完整

- 【讀】guard 讀的環境變數恰好九個：
  - guarded_build.sh 讀八個：JOBS(:60)、MEM_HIGH(:67)、MEM_MAX(:68)、LOCK(:69)、TIMEOUT(:70)、NDTWIN_GUARD_HELD(:80)、NO_CGROUP(:93)、LOCK_WAIT(:128-129)。
  - shim 只讀 SHIM_JOBS（shims/_resolve.sh:58）。
  - 其餘只有 PATH 和 IFS。
  - 我對整個 tools/build_guard 做了 `$VAR` 的 grep，沒有第十個。test_build_guard.sh:22 的九個一一對上，**清單完整**。
- 【讀】測試合併的 worktree（wt-hbw-intake-0926）情況相同：guard 的讀取點行號一致，test_build_guard.sh:22 是同一行。這是 working tree 觀測，不是 git 驗證。
- 【讀】沒有「該繼承卻被清掉」的東西：
  - 每個真的走進 guard 本體的呼叫，都在自己的命令列上帶 `NO_CGROUP=1` 和 `LOCK="$TMP/lN"`（:111、:113、:115、:117、:123、:127、:132、:134、:137）。
  - 需要特定值的也都自己帶：JOBS=3（:113）、JOBS=zero（:117）、LOCK_WAIT=30／1（:127／:137）、SHIM_JOBS=…（:78-82）。
  - mutation gate 依賴的 GUARD_UNDER_TEST（:24；mutate_build_guard.sh:72-73）、PATH、TMPDIR 都沒被動。
- 唯一的例外是 :119（`"$GB"` 不帶參數）。它什麼都沒帶，但今天在 guarded_build.sh:58 就 exit 2 了，碰不到鎖（見 NOTE-1）。
- 【推】PATH 裡還留著外層 guard 的 shim 目錄和 nolab 目錄，但不會漏進判定：
  - 所有讀假工具 argv 的格子，都把 `$FAKE` 放在繼承來的 PATH 前面（:51、:85、:88、:111、:113）。
  - ONLYSHIM 那兩組整個換掉 PATH（:92、:105）。
  - POINTER 那組在查到後段 PATH 之前就被拒絕（:100；_resolve.sh:50-51）。

## 2. 安全性

- **會不會卡在外層的 /tmp/ndtwin-build.lock？**【讀】不會。沒有任何格子用預設鎖。唯一沒帶 LOCK 的 :119 在 guarded_build.sh:58 就離開，早於 :127-128 的 flock。M1–M14 也沒有一個動到 :58 或 LOCK 的預設值（mutate_build_guard.sh:114-258），所以 mutant 下同樣碰不到。
- **會不會在外層 cgroup 之外跑真的 -j2 build？**【讀】不會，沒有任何格子叫到真的 cmake／ninja／make：
  - 假工具是 printf 腳本（:29-33），而且排在 PATH 前面。
  - ONLYSHIM 目錄裡只有 dirname、timeout、env、bash（:91）。
  - POINTER 那組會被拒絕。
  - 閘門環境另外有 nolab 版的 cmake／ninja／make，會記錄並拒絕（make_shims.sh:24-31）；tripwire 是 0 行（L/nolab_tripwire.sgenv-d271f5b8.log:20-21）。
  - 所以 -j2 這個預設值只會流到假工具。
- **會不會產生沒被回收的 scope？**【讀】不會。所有 run_it 都走 NO_CGROUP=1 分支（guarded_build.sh:93-97），不會呼叫 systemd-run，程序也不會離開外層 scope。reentrant suite 的 (g) 用的是假的 systemd-run（test_guarded_build_reentrant.sh:69-78、:144）。
- 【推】清掉 NDTWIN_GUARD_HELD 對今天的格子沒有效果：它們用的本來就不是外層那把鎖，被包起來的命令（假 cmake、`bash -c 'exit 42'`、sleep、true）也不會再呼叫 guard。

## 3. red-first 與 mutation gate

- 【讀】red-first log（L/redfirst_sge…log:10-17）：
  - 繼承到的四個變數：`NDTWIN_GUARD_HELD=/tmp/ndtwin-build.lock JOBS=1 SHIM_JOBS=1 LOCK_WAIT=10800`。
  - base：rc 1，`Ran 37 checks, 15 failed`。
  - head：rc 0，`Ran 37 checks, 0 failed`。
  - 兩邊 check 數相同。
- 【讀】「15 條、每條都是 -j1」的逐條 raw 在 D/E1/test_build_guard.sh.out:3-74：
  - cmake 6 條、ninja 3 條、make 3 條、自我解析 2 條、"it puts the shims on PATH" 1 條。
  - 15 條的 actual 全部以 `-j1` 結尾。
  - E3 拿掉 guard 變數後是 0 failed（E3 輸出 :53）。
- 【推】這和原始碼一致：前 14 條是 shim 直接讀 SHIM_JOBS（_resolve.sh:58）；:111 那條是巢狀 guard 把繼承來的 JOBS=1 export 成 SHIM_JOBS（guarded_build.sh:60、:87）。
- 【讀】red-first 有效：base 版被複製到 HEAD worktree 裡跑（redfirst_sge.sh:16-17），用的是 HEAD 的 guard；而 patch 只動測試檔（patch:1-14），兩邊 guard 相同。
- 【讀】mutation gate（L/mutate_build_guard…log:9-29）：
  - baseline 是 37/0 加 15/0。
  - 14 個 mutant 全部被「點名的那一條」抓到。
  - baseline 前後 byte-identical。
- 【推】逐一對照後，沒有任何殺手因為 unset 變空洞：
  - M1–M5、M7 的殺手比對完整字串，mutant 造成的是 -j 多出、缺少或整行空白，不只是數字變了。
  - M6 在命令列上自帶 SHIM_JOBS=0（:79）。
  - M8 看的是 rc 127 還是 124。
  - M9／M10 比對不含 -j 的字串。
  - M11–M14 的殺手都在 reentrant suite。
- 【推】反過來說，這個修正是 gate 能在閘門環境跑起來的前提：在 3db3b9a8 的閘門環境下，baseline 會有 15 紅，mutate_build_guard.sh:80-83 會 refused（rc 2）。這一格 worker 沒實跑，是我推的。
- 【推】M12 的觀察面有一個無害的變化：
  - 修正前，繼承來的 HELD 非空，M12 會連 test_build_guard 的 flock 格子一起弄紅。
  - 修正後只剩 reentrant 的 (d) 會紅，而 (d) 正好就是點名的那條，所以裁定不變。

## 4. test_guarded_build_reentrant

- 【讀】不受影響：
  - patch 只動 test_build_guard.sh。
  - 兩支 suite 都是各自獨立的 bash 行程（mutate_build_guard.sh:72-73；gates_sge_b.sh:44-45），所以 :22 的 unset 傳不過去。
  - 它自己在 :54 已經 unset 了 NDTWIN_GUARD_HELD。
  - 結果 15/0（L/…reentrant…log:41）。
- 它仍有這次修的同類問題，見 NOTE-2。

## 5. 協調者在 17fbdd7f 的 rerun

- 【讀】目前狀態：
  - S/rerun-test_build_guard_TRUNK_expect_red.17fbdd7f.log 只有 4 行：sha、cmd、guard 的兩行 banner。沒有 suite 輸出，也沒有 `# rc` 行。
  - rerun-summary.17fbdd7f.txt 是空的。
  - 另外三份 log 還沒出現。
  - 所以我**沒有讀到 rerun 的結果**。
- 【推】它可能還在等鎖：banner 在 guarded_build.sh:113-114 印出，早於 :127-128 的 flock，而 suite 一啟動就會印第一個標題。所以比較可能是 guard 正在等別人握著的預設鎖（rerun-sge.frozen.sh:16，LOCK_WAIT=10800），或者我剛好在它開跑的瞬間讀到。我沒有查任何行程。

---

## NOTE（不擋 merge）

**NOTE-1：:119 是唯一沒有自己鎖的格子。**【推】
- 今天沒問題。但如果 guarded_build.sh:58 的「無參數拒絕」退化了，修正後在閘門裡它會走到 :127-128，去等外層握著的共用鎖。
- LOCK_WAIT 已經被 unset，所以預設等 3600 秒；時間到回 rc 2，而 :120 期望的正好是 2，退化就會被判成綠。
- 修正前，繼承來的 HELD 會讓它直接巢狀跑空命令，rc 0，當場紅。
- 在 gate 裡有 timeout 300 擋著，會記成 SURVIVED（mutate_build_guard.sh:72、:95-97）；但單獨跑這支 suite 時，就是卡一小時之後判綠。
- 建議改一行：`NO_CGROUP=1 LOCK="$TMP/l0" LOCK_WAIT=1 "$GB"`。

**NOTE-2：reentrant suite 只清掉 NDTWIN_GUARD_HELD（:54）。**【推】
- (g)（:144）沒帶 NO_CGROUP。呼叫端如果 export 了 NO_CGROUP=1，就不會呼叫假 systemd-run，記錄是 0 行，結果變紅；M13 的殺手和 gate baseline 也會跟著紅。
- TIMEOUT 如果被繼承而且小於 4，(b)（:103）和 (d)（:119）的 holder 會被砍掉，計時的格子會紅。
- 今天的閘門環境兩者都沒設：banner 沒有 timeout 前綴，也沒有 NO_CGROUP 的警告（redfirst log:7-8，對照 guarded_build.sh:90、:94）。
- 建議把同一條 unset 補過去。

**NOTE-3：red-first 的儀器比它的宣稱弱。**【讀】
- redfirst_sge.sh:22 用 `grep -vc -- '-j1'` 做子字串比對，`-j14` 也會算過；它也不核對 actual 行數是否等於 FAILED 數。
- 它自己的 base.out／head.out 在 :9 的 trap 裡被刪了。
- 能撐起「每條都是 -j1」的只剩 D 裡那份，而它放在會消失的 /tmp scratchpad。
- 建議複製到 L 旁邊。rerun 跑完後會把 trunk 的逐條輸出留在 log 裡，可以替代。

**NOTE-4：九個變數裡只有四個真的被繼承過**（redfirst log:10；diag log:11）。
- 【推】另外五個（LOCK、MEM_HIGH、MEM_MAX、TIMEOUT、NO_CGROUP）沒被任何 red-first 碰過。
- 其中只有 TIMEOUT 會改判定：holder（:123／:134）被砍掉後，:127 等不到 2 秒。其他四個對今天的格子是中性的。

**NOTE-5：兩個預設值沒有 mutant。**【推】
- 這個修正的前提是「suite 驗的是預設值」，但 gate 裡沒有 mutant 打在兩個預設值上：guarded_build.sh:60 的 `:-2` 和 _resolve.sh:58 的 `:-2`。
- 修正前在閘門裡根本驗不到預設值，現在驗得到了，值得補一個 mutant 來證明。

**NOTE-6（範圍外，既有問題，不是這次引入的）：ONLYSHIM 兩組（:90-94、:105-107）是用錯的路徑拿到對的 rc。**【推】
- ONLYSHIM 只放了 dirname、timeout、env、bash（:91），但 shim 要用到 readlink（shims/cmake:15）。
- readlink 找不到之後的連鎖：SHIM_DIR 變成 cwd → source _resolve.sh 失敗 → guard_real_tool 未定義 → 印出「no real cmake」、exit 127。這正是 shims/cmake:12-14 註解裡警告的情況。
- 所以這四條不管解析器對不對都會綠。

---

## 其他三支 suite 的診斷

**test_start_bg_log_rotation**
- 成立的部分：
  - 【讀】4 種環境各 6 紅（diag log:31-35）。
  - 【讀】rotate_log 已改成時間戳命名、保留 5 代（stack.sh:482-510），suite 仍寫著兩代（test_start_bg_log_rotation.sh:3）。
- 證據不足：「從 09-06 起任何環境都紅」是從 git 歷史推出來的（diag log:56-58），沒有在 74c811df 前後實跑，卻放在 OBSERVED 標題下。
- 漏掉的：【讀】test_stack_log_rotation.sh 已經在測時間戳、五代和 NDT_LOG_KEEP（:84-122）。
  - 【推】那 6 條紅已經被新 suite 取代。
  - 舊 suite 真正獨有的，是 start_bg 整合那幾條：首次啟動、空 log 不輪替（stack.sh:559-560）。
  - 所以要裁決的是「保留哪些整合格子」，不只是「改 suite 還是 O-4 錯了」。

**test_gate_exit_code_not_tee**
- 成立的部分：
  - 【讀】worktree 裡沒有 t008_poll_twin.jsonl，主 checkout 有（我用 Glob 查的）。
  - 【讀】raw/.gitignore 的內容是 `*` 加 `!.gitignore`（:13-14），所以檔頭 :26-27「在版控裡」不成立。
  - 【讀】case 4 grep 的是 `GATE ratio force-test OK`（:112-113），所以「case 4 跟著紅」成立。
- 證據不足：「clone／CI 都拿不到」。同一份 .gitignore 寫明 raw 放在 audit-raw orphan branch（:1-4），那裡有沒有這個檔沒有查。如果有，就多一個修法：從 audit-raw 取。
- 漏掉的：【推】case 2（檔內自稱 load-bearing，:80-83）期望 rc 2，而 NO-DATA 的 UNRUNNABLE 本身就回 rc 2（diag log:41-46）。
  - 那份輸出是 `--expect green` 的；`--expect red` 我推論結果相同，沒讀 ratio_gate.py。
  - 所以在沒有 fixture 的 checkout 裡，最關鍵的那條是「理由錯、數字對」的綠。這讓「資料不在就 SKIP」更站得住。

**test_l1_shell_scoring**
- 【讀】成立：12 紅（D/E1/test_l1_shell_scoring.sh.out:48-128），SUMMARY 舉的例子逐一對得上。
- 【讀】附帶一點：test_build_guard 本身就是這 12 條之一（:52-54）。d271f5b8 沒有新增 echo，合併後這條照樣紅，不是這次造成的回歸。
- 「corpus 之後陸續改了形狀」是推論。

---

## 報告裡各判定的分類

| 判定 | 分類 | 依據／缺什麼 |
|---|---|---|
| 原因是環境（繼承 SHIM_JOBS／JOBS） | SUPPORTED | |
| 15 條都是 -j1 | SUPPORTED | 靠 diag 的 raw，不是靠 red-first 的儀器 |
| 期望值沒改、仍 37 條 | SUPPORTED | |
| 「每格自己設值」 | SUPPORTED | :119 例外，但今天走不到 |
| red-first 15 紅 → 37/0 | SUPPORTED | |
| 37/0、15/0、14/0、120/120、tripwire 0 | SUPPORTED | |
| merge-tree 沒有衝突 | UNDER-EVIDENCED | 報告沒引輸出；17fbdd7f 裡確實有 :22 可以佐證 |
| 對其餘五個變數免疫 | UNTESTED | |
| 診斷的 E 表 | SUPPORTED | |
| start_bg「09-06 起」 | UNDER-EVIDENCED | 推論卻標成 OBSERVED |
| not_tee「clone／CI 拿不到」 | UNDER-EVIDENCED | audit-raw 沒查 |

沒有 CONTRADICTED。

## 我會跑、但報告沒跑的測試

1. 逐一拿掉單一變數，釘住機制：只拿掉 SHIM_JOBS 應該 14 紅；只拿掉 JOBS 應該只有 :111 紅。
2. TIMEOUT 的 red-first：base 在 `TIMEOUT=2` 下，:127 應該紅；HEAD 應該綠。
3. 中性對照：export LOCK、MEM_*、NO_CGROUP=0 時，兩邊都應該綠。
4. 在副本上移除 :58，同時讓外層握鎖，看 :119 會不會卡住（NOTE-1）。
5. 補兩個預設值的 mutant（NOTE-5）。
6. 17fbdd7f 的 rerun。

## 數字一致性

- 【讀】SUMMARY 的閘門表和六份 log 完全一致，fix 註解裡的「15 checks read -j1」和 raw 也一致，沒有內部矛盾。
- 只有一個小地方：gates_sge_b.sh:4-6 的註解寫的是 p4hbr3 的命名，實際 TAG 是 sgenv（:13），是舊註解沒改。

## 相關檔案（絕對路徑）

- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-suites-gate-env-0927/tests/shell/test_build_guard.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-suites-gate-env-0927/tests/shell/test_guarded_build_reentrant.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-suites-gate-env-0927/tests/shell/mutate_build_guard.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-suites-gate-env-0927/tools/build_guard/guarded_build.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-suites-gate-env-0927/tools/build_guard/shims/_resolve.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/redfirst_sge.sgenv-d271f5b8.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/mutate_build_guard.sgenv-d271f5b8.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/diag_b.sgenv-3db3b9a8.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-sgenv-d271f5b8-b/redfirst_sge.sh
- /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/tmp/diag_b_3db3b9a8/E1/test_build_guard.sh.out
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/sge/rerun-test_build_guard_TRUNK_expect_red.17fbdd7f.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-suites-gate-env-0927/tests/shell/test_stack_log_rotation.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-suites-gate-env-0927/doc/audit/2026-08-20_sampling-rate-and-cpu/raw/.gitignore
