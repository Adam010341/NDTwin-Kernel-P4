（opus-judge 最後回覆，orchestrator 2026-09-27 存檔）

# JUDGE NOTES-16069d1a

**範圍與方法**
- 全程唯讀：沒有執行任何東西、沒有下 git 指令、沒有碰任何行程。
- 讀過的東西：
  - SUMMARY、diff patch
  - WT 裡改動的六個檔，加上 07／08／_common.sh／tools/build_guard 的原始碼
  - G 底下全部 `*.notes{,2,3,4}-16069d1a.log`、`.kept/`，以及四組 scripts
  - 兩份早先的 judge 檔，只讀了 NOTE 原文，當作缺陷的定義（依協調者指示）
- HEAD 的確認：`.git/worktrees/wt-followup-notes-0927/HEAD` 指向 `refs/heads/fix/followup-notes-0927`，內容是 `16069d1ac025…`【讀】。
  - WT 的檔案是 working tree 觀測，與 patch 的 hunk 一致。
  - driver 每跑一格前都會檢查 HEAD 沒動、tracked 檔乾淨（S3/gates_notes.sh:39）。
- 標記方式：【讀】＝我在原始碼或 log 裡讀到的；【推】＝推論；【跑】＝需要實際執行才能確認。

**路徑縮寫**（全部是絕對路徑）
- WT = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-followup-notes-0927
- 07 / 08 / CM = WT/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/{07_roles_basic.sh, 08_heartbeat.sh, _common.sh}
- MW / MR / MBG / TBG / TRE = WT/tests/shell/{mutate_p4_heartbeat_w, mutate_roles_binding, mutate_build_guard, test_build_guard, test_guarded_build_reentrant}.sh
- GB = WT/tools/build_guard/guarded_build.sh；RS = WT/tools/build_guard/shims/_resolve.sh
- G = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
- S3 / S4 = G/scripts-notes3-16069d1a、G/scripts-notes4-16069d1a
- `X.notes3` = G/X.notes3-16069d1a.log，其餘 tag 同理
- SUM = /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/FOLLOWUP-NOTES-SUMMARY.md

---

## 判決：**MERGE**

## BLOCKERS：無

- diff 只動測試，一共六個檔。
- 每個會改變行為的 NOTE，在已交付的 log 裡都看得到：base 紅（或那一格是空洞的），HEAD 綠。
- 新的 mutant 都殺在點名的那一格。
- 沒有任何一條路徑能碰到 lab。
- SUMMARY 有一個問題：好幾處把「作廢輪次」的 log 當作 OBSERVED 證據引用（N-N1）。同樣的結果都在已交付的 notes3 裡，而且是同一支儀器跑的，所以不擋 merge。

---

## 各 NOTE 裁定表

| NOTE | 缺陷在 HEAD 是否消失 | red-first（OBSERVED 的 log 行） | mutant／對照 | 分類 |
|---|---|---|---|---|
| R3-N1 | 已消失（scratch 儀器，不進 repo）：`_rf_lines` 改用 `awk 'END { print NR }'`（S3/redfirst_lib.sh:19）【讀】 | 舊 r3 lib 在沒有換行的 fixture 上紅：`got '0 no', want '1 yes'`（redfirst_lib_old_red.notes3:14）；新 lib 綠（redfirst_lib_check.notes3:14-15）【讀】 | M1（改回 `wc -l`）只紅在那一條（mutate_redfirst_lib.notes3:10-12）【讀】 | SUPPORTED；SUM 引的是作廢的 notes 輪（N-N1） |
| R3-N2 | lib 的預設位置改到 G 底下（S3/redfirst_lib.sh:17-18）；r3 driver 也改了（/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad/r3/redfirst_r3.sh:16-18，對照凍結副本 scripts-p4hbr3-c22d1300-c/redfirst_r3.sh:16）【讀】 | 舊 lib：`got 'no: …/scratchpad/tmp/redfirst-kept', want 'yes'`（redfirst_lib_old_red.notes3:9）；新 lib 通過（redfirst_lib_check.notes3:9）【讀】 | 沒有 mutant；這個檢查只問變數，不看實際寫到哪裡（S3/redfirst_lib_check.sh:11-14）【讀】 | lib 層 SUPPORTED；driver 層只讀過、沒跑過，UNDER-EVIDENCED（N-N9） |
| R3-N3 | 已消失：`st_l6_default` 全部在前景跑，沒有 `&` 也沒有 kill（07:618-632）；07 裡剩下唯一的背景工作是 `st_l6` 的 `( sleep 2.5 … ) &`，後面有 `wait`（07:575-578）【讀】 | base：`left in its session after it exited: 2 process(es): 1101875 bash …07_roles_basic.sh --se;1101921 sleep 2`、`(it was gone 25 s later)`（redfirst_notes.notes3:12-14；.kept/r3n3_base_left.txt:1-2）；HEAD：`at HEAD nothing of its session is left when the self-test exits`（:16）【讀】 | base 剩下的那 2 個行程就是儀器的正對照 | SUPPORTED；SUM 引的是 notes2（作廢） |
| R3-N4 | 已消失：三格都用**不帶參數**的 `l6_roles`／`l6_plain` 跑到結束，逐字比對 `judged 3 reads 16 after 30 s`（07:633-650）【讀】 | base 三個副本都 PASS（redfirst_notes.notes3:21,26,31）。HEAD 只紅在點名的格子：`…(unbound) -- judged 3 reads 2 after 2 s`（:22-25）、`reads 21 after 40 s`（:27-30）、roles 8 s 兩格 `reads 5 after 8 s`（:32-37）【讀】 | L7-30／31／32 各殺在點名的格子（mutate_roles_binding.notes3:609-611）【讀】 | SUPPORTED；殘留問題見 N-N4 |
| R3-N5 | 已消失：`ltree_control` 用 `grep -qxF` 逐行要兩行（MW:125-134），缺哪一行就點名哪個分支（MW:137-141）【讀】 | base：knob 分支關掉、link 分支關掉，都是 `rc 0 -- (passed)`（redfirst_notes.notes3:41-44）；HEAD：各自 `rc 2`，只點名被關掉的分支（:47-50）【讀】 | 同左 | SUPPORTED；殘留問題見 N-N5 |
| R3-N6 | 未處理（SUM §6 自承） | — | — | 不在本次範圍 |
| R3-N7 | `lrun` 加了 `PYTHONDONTWRITEBYTECODE=1`（MW:1141）【讀】 | NO RED：儀器對照組 `writes 25 .pyc`（:52）；base 0 個、HEAD 0 個（:56-57）【讀】 | 無 | 「防禦性、沒有紅」這個結論 SUPPORTED，而且誠實；但理由只對一半（見 Q5／N-N2） |
| NOTE-1 | 已消失：`NO_CGROUP=1 LOCK="$TMP/l0" LOCK_WAIT=1 "$GB"`（TBG:124）；兩支 suite 裡其他每個 guard 呼叫都帶自己的鎖（TBG:111-142；TRE:98-158）【讀】 | base suite＋M15：`rc 124 after 60s`（redfirst_notes.notes3:61-62）；HEAD suite＋M15：`rc 1, Ran 37 checks, 1 failed; red: no command at all is refused`（:63-64），而且 driver 斷言 FAILED 數等於 1（S3/redfirst_notes.sh:178）【讀】。「gate 會記成 SURVIVED」「單獨跑 3600 s 後判綠」是從原始碼推的（MBG:95-97；GB:128-130）【推】 | M15 caught（mutate_build_guard.notes3:27）【讀】 | SUPPORTED |
| NOTE-2 | 已消失：TRE:58 和 TBG:22 是同一組九個變數【讀】；清單完整（見 Q6） | base：繼承 `NO_CGROUP=1` 時 `1 failed [… systemd-run was called ONCE …]`；繼承 `TIMEOUT=1` 時 `2 failed`（redfirst_notes.notes3:66,70）。HEAD 兩種情況都是 `Ran 15 checks, 0 failed`（:67,71）【讀】 | — | SUPPORTED |
| NOTE-3 | 已消失（scratch 儀器）：逐字比對「-j2 換成 -j1、其餘相同」（S3/redfirst_sge2.sh:18-29）；actual 行數等於 FAILED 數（:60）；base.out／head.out 寫進 .kept（:54-55），檔案確實存在【讀】 | 第一版 rc 1：`only 9 of 15 actual lines end in exactly -j1`（redfirst_sge2.notes:16）。重跑：`[failed 15 actual 15 j1 15]`、HEAD `Ran 37 checks, 0 failed`（redfirst_sge2.notes3:12-20）【讀】 | S1、S2 caught（mutate_sge2.notes3:10-12）；self-check 5 格通過（redfirst_sge2_selfcheck.notes3:9-14）【讀】 | SUPPORTED。早先 judge 說「15 條都以 -j1 結尾」，這句被 .kept/base.out:28-47 推翻：ninja／make 把 -j 放在 target 前面（shims/ninja:24、shims/make:29） |
| NOTE-4 | 未處理（自承）；NOTE-2 的 red-first 順帶碰到了 reentrant suite 的 NO_CGROUP 和 TIMEOUT，test_build_guard 還是沒碰 | — | — | 不在本次範圍 |
| NOTE-5 | 已消失：新增 M16、M17（MBG:274-287）【讀】 | mutant 被殺本身就是證據 | M16 殺在 `it puts the shims on PATH for the wrapped command`，M17 殺在 `-j14 glued becomes -j2`，總計 `17 mutations, 0 survived`（mutate_build_guard.notes3:28-29,32）【讀】 | SUPPORTED；M16 的鑑別力見 Q3；SUM 引的是作廢的 notes 輪 |
| NOTE-6 | 未處理（自承） | — | — | 不在本次範圍 |

---

## Q3. 新 mutant 有沒有殺在點名的 check

### M16（GB:60 的 `JOBS:-2` 改成 3）

**機制**【讀】
- TBG:22 先 unset JOBS。
- TBG:111 是兩支 suite 裡**唯一**不帶 JOBS 呼叫 guard 的格子；TBG:113 帶 `JOBS=3`，TRE:155 帶 `JOBS=3`，TRE:70 的 inner 帶 `JOBS=5`。
- 所以值會這樣傳：GB:60 的預設 → GB:87 `export SHIM_JOBS="$JOBS"` → shims/cmake:32 的 `-j"$(guard_jobs)"`。
- 期望值是 `FAKE-cmake --build d -j2`（TBG:112）；在 M16 下會是 `-j3`。
- 3 通過 GB:72 的 regex，所以不會因為「JOBS 不合法」這種無關的理由變紅。
- anchor 唯一性由 MBG:59-62 的 count==1 保證。

**旁證**【讀】
- .kept/base.out:72-74：在繼承 JOBS=1 的 3db3b9a8 上，同一格的 actual 是 `FAKE-cmake --build d -j1`。
- 這說明這一格讀到的 -j 確實跟著 guard 的 JOBS 走。

**限制**
- gate log 對被抓到的 mutant 不印 actual。
- 所以「M16 下讀到的是 -j3，而且只有這一格紅」是推論【推】；要實證得手跑一次【跑】。

**是不是該由這一格抓**
- 是，而且它是唯一抓得到的格子。
- 但它的名字講的是 PATH，不是預設值（N-N3）。

### M17（RS:58 的 `SHIM_JOBS:-2` 改成 3）
- TBG:54 沒帶 SHIM_JOBS（TBG:22 已 unset）→ 讀到 `-j3` → 紅。
- TBG:111 那一格不受影響，因為 guard 一定會 export SHIM_JOBS（GB:87）【讀】。
- M17 下還會一起紅的：cmake／ninja／make、自我解析那幾格，以及 TBG:82 `SHIM_JOBS empty falls back to 2`，大約 15 格；點名的那格在其中【推】。

### M15
- red-first 觀測到 HEAD 下恰好只紅一條，就是點名的那條（見上表）【讀】。

### L7-30／31
- red-first 顯示 HEAD 下恰好只紅一條（redfirst_notes.notes3:23,28）【讀】。

### L7-32（roles 預設 40 s）
- 沒有 40 s 的 red-first。
- roles 8 s 的 red-first 顯示兩個 roles 格子都紅（:34）；gate 裡殺在點名的格子（mutate_roles_binding.notes3:611）【讀】。
- base 的 6.5 s 那一格看不到 40 s，這和 8 s 的情況同理【推】。

---

## Q4. 07 self-test 的虛擬時鐘（`st_l6_default`）

### (a) 是否攔到所有時間來源【讀】

**state_until 裡的時間相關呼叫**
- `date +%s`（07:357、:364）：被攔。
- `sleep 2`（07:365）：被攔。
- `date -u +%H:%M:%SZ`（07:362）：走真的 date，但只用來寫 `.polls` 的時間戳，不影響流程。

**其他函式**
- `get_json` 只有 `curl -s --max-time 10` 和 python json（CM:312-325）。
- verdict 函式 `caps_are`、`skipped_is`→`jqp`、`links_heard` 都是 python，而且不讀時間（07:151-226；CM:328-331）。

**其他可能的時間來源**
- 07 和 CM 裡沒有 `$SECONDS`、`EPOCH*`、`read -t`（grep 0 筆）。
- `timeout` 只出現在外層：MR:1429 的 120 s、at07 的 600 s。

**攔截機制本身**
- PATH 在 subshell 裡重設（07:628），bash 重設 PATH 時會清掉 hash。
- `$( )` 繼承這個新的 PATH。
- `realdate` 在改 PATH 之前就解析好了（07:621）。
- nolab shim 裡沒有 date 或 sleep（S3/make_shims.sh:15-86）。

### (b)「judged 3 reads 16 after 30 s」可以從原始碼推導，不是調出來的【讀＋推】
- deadline＝t0＋30（07:357）。
- 每一圈的順序是：先讀 → 判斷 `now >= deadline` → 才 sleep（07:359-366）。
- 所以讀取發生在 t＝0、2、…、30，一共 16 次。
- 最後一圈在 sleep 之前就 break，時鐘停在 15×2＝30。
- `$out` 不是空的，所以會有三個 judge（07:380-383）。
- 三個 mutant 的觀測值落在同一條公式「讀 D/2+1 次、after D」上：2→2/2、8→5/8、40→21/40（redfirst_notes.notes3:22,27,32）。

### (c) runaway 會不會留下東西
- **行程**：不會。這一格沒有任何背景工作（07:627-630）。長 deadline 會被 fake date 的 600 虛擬秒上限收掉（07:623）【讀】。
- **檔案**：
  - 只寫在 `$t/px-*` 底下（07:620-626），正常返回時由 RETURN trap 刪掉（07:402）。
  - 被 SIGTERM 砍掉時 `$t` 會留下，但在 gate 裡那是呼叫端自己的 temp root，之後會被刪（MR:1439；S3/redfirst_notes.sh:25）【讀】。
- **缺口：時鐘不前進的情況** — sleep 被刪掉，或變成小於 1 的小數。
  - 600 秒上限管不到這種情況，迴圈會在真實時間裡無限跑下去。
  - selftest_07 這個 gate 沒有外層 timeout（S3/gates_notes.sh:58；GB:70 的 TIMEOUT 沒設）。
  - 今天的程式碼走不到這條路【推】（N-N4）。

### (d) `${1%%.*}` 的截斷【讀＋推】
- 這條路徑上唯一的 sleep 是整數 `sleep 2`（07:365），所以不會截斷，讀取次數不受影響。
- 但它的一般行為是取 floor：
  - 2.5→2：次數不變，是盲點。
  - 1.5→1：31 次，會紅。
  - 0.5→0：時鐘不前進，無界。
- 所以它不會讓今天的檢查假綠，但對「間隔改成非整數」這類改動是盲的。

---

## Q5. R3-N7：「防禦性、沒有紅」是否誠實、`-I` 的讀法是否正確

**誠實**：是【讀】
- driver 有正對照（redfirst_notes.notes3:52），base 和 HEAD 都是 0（:56），也明說是防禦性修改（:57）。
- 附帶一點：第一輪 driver 原本期望 base 會寫出 byte-code，看到 0 時判成 `BAD at c34a643a no byte-code was written`（redfirst_notes.notes:93）。之後改成 NO RED 的分支（S3/redfirst_notes.sh:151-152），是看到結果之後才改判準，但有揭露。

**`-I` 的讀法：只對一半**
- 對的部分：
  - `"$VPY" -I` 在 08 裡確實出現 16 次（08:176,753,856,857,858,861,877,894,1001,1186,1544,1556,1566,1573,1675,1732）【讀】。
  - `-I` 隱含 `-E`，會忽略所有 PYTHON* 變數。
- 漏掉的部分【讀】：
  - self-test 會呼叫 `consts`（08:1419；.kept/r3n7_08_selftest_base.out:62 `consts: … imported (5 15 5)`）。
  - `consts` 用的是 venv 的 `$PY`，**沒有 `-I`**，並以 `PYTHONPATH=.` import `proxy_agent.topology_manager`（08:139-141）。
  - 這正好是經由 ltree 的 symlink 連回 checkout 的那一條，也就是 R3-N7 擔心的路徑。
  - 它不寫 .pyc，是因為自己在命令列上就帶了 `PYTHONDONTWRITEBYTECODE=1`（08:140），不是因為 `-I`。
- 另外，16 是原始碼裡出現的次數，不是 self-test 實際啟動的次數。

**結論**
- 結論成立：lrun 的改動今天沒有可觀測的效果。
- 理由不完整。
- SUM 說「讓任何 byte-code 都寫到那裡」過度概括：`-I` 直譯器也不讀 PYTHONPYCACHEPREFIX。不過 PYTHONDONTWRITEBYTECODE 本來就只能影響非 `-I` 的那一群，所以不傷結論【推】。

**紅其實做得到【跑】**
- 在 ltree 的 08 副本裡把 08:140 的 inline `PYTHONDONTWRITEBYTECODE=1` 拿掉。
- 分別經過 base 的 lrun 和 HEAD 的 lrun 跑，並設好 PYTHONPYCACHEPREFIX。
- 預期 base 會出現 proxy_agent 的 .pyc，HEAD 是 0。

---

## Q6. NOTE-2：九個變數是否完整【讀】

**guard 與 shim 實際讀的變數**
- GB 讀八個：JOBS(:60)、MEM_HIGH(:67)、MEM_MAX(:68)、LOCK(:69)、TIMEOUT(:70)、NDTWIN_GUARD_HELD(:80)、NO_CGROUP(:93)、LOCK_WAIT(:128-129)。
- shim 只讀 SHIM_JOBS（RS:58）；cmake／ninja／make 只用 BASH_SOURCE（shims/cmake:15 等）。
- 剩下的只有：
  - PATH（GB:86；RS:27）
  - IFS（RS:26，用完會存回；bash 本來就不從環境匯入 IFS）
- TRE:58 的九個和上面一一對上，**沒有缺**。

**PATH 是刻意保留的，不會影響判定**
- 只有 (g) 會走到 `command -v systemd-run`（GB:98），而 (g) 把 FAKE 放在 PATH 最前面（TRE:148）。
- 其他格子都在自己的命令列上帶 `NO_CGROUP=1`。
- nolab shim 裡沒有 flock、timeout、systemd-run。
- fake systemd-run 讀的 SCOPE_LOG 由 suite 自己設（TRE:147,152）。

---

## Q7. 範圍外的改動、風險、會不會碰到 lab

**diff 本身**【讀】
- 沒有 sudo、mnexec，也沒有 curl 打 :8000／:8081／:8080。
- **07 的新格子**：只讀 `file://$px`（07:628），寫入都在 `$t` 底下；PATH／RUN／PROXY_URL 的改動只在 subshell 裡。
- **MW**：
  - `ltree_control` 在 `$BK` 底下建一條 symlink，之後只做 find 和 readlink（MW:128-133）。
  - `rm -rf "$lctl"` 刪的是 link，不是它指向的目標（MW:147）。
- **MBG**：M15-17 都是在 `$BK` 的副本上改。
- **TBG／TRE**：只接 fake 工具。TRE 做了 unset 之後，(g) 一定走 fake systemd-run，不會建出真的 scope。

**tripwire**【讀】
- notes4 的 gate：`0 lab call(s)`、`122 line(s)`（nolab_tripwire.notes4:20-21）；我 grep 過，122 行全部是 `file://`。
- notes3 沒有跑 tripwire gate。我 grep 了 S3/tripwire.log：2114 行，全部含 `file://`，符合 tripwire pattern 的是 0 行。
- 限制和 R3-N6 一樣：只看得到 PATH 上找到的指令。

**既有的小風險，不是這個 diff 引入的**
- MW:128 的 `ln -s` 沒有帶 `-n`。
- 如果同一個目錄被呼叫兩次，第二次會在 checkout 裡建出 `p4_proxy/p4_proxy`。
- 今天的呼叫都用新的 mktemp 目錄【推】（N-N6）。

---

## Q8. 報告裡的數字，逐一對到 log【讀】

| 宣稱 | log 行 |
|---|---|
| 17/0 | mutate_build_guard.notes3:32（baseline 37/0＋15/0 在 :10-11；byte-identical 在 :31） |
| 177/0 | mutate_roles_binding.notes3:618；196/196 在 :615；07 baseline 在 :579 |
| 195/0 | mutate_p4_heartbeat_w.notes4:230；103/103 在 :227；byte-identical 在 :229；leak control 在 :10 |
| 120/120 | check_gate_anchors.notes4:135（mutate_build_guard ok(17) 在 :23） |
| 37/0 | test_build_guard.notes3:61；redfirst_sge2.notes3:13 |
| 15/0 | test_guarded_build_reentrant.notes3:41；redfirst_notes.notes3:67,71 |
| 96/0 | crosscheck_trunk.notes4:15（tree 4feceb1a 在 :10、blob 1e04ba18 在 :12、63/63 在 :18） |
| 16 reads | redfirst_notes.notes3:18；selftest_07.notes3:44-46（59 個 ok，PASS 在 :70） |

**作廢檔的核對**【讀】
- **notes 輪**：12 份。
  - redfirst_notes rc=1（:112）
  - redfirst_sge2 rc=1（:26）
  - mutate_roles_binding 沒有 rc 行
  - 其餘 9 份 rc=0，但整輪作廢
- **notes2 輪**：2 份。
  - redfirst_notes 是完整的，rc=0（:76）
  - redfirst_sge2_selfcheck 停在 :8
- **notes3 輪**：
  - 12 份交付，都是 `# rc=0`。
  - mutate_p4_heartbeat_w 停在 :200，沒有 rc 行。
  - 三份是 `# NOT RUN` 佔位檔（:1-3，04:41:30Z）。
  - 所以 **notes3 不算數的是四份**：三份佔位檔加一份截斷的。SUM §4 寫對了，協調者的描述少了截斷的那一份。
- **notes4 輪**：4 份，都是 rc=0。
- **儀器是同一支**：redfirst_notes.sh 在 notes2／3／4 的 SHA256SUMS 都是 `3f2d2b69…`（S3/SHA256SUMS:10；S4/SHA256SUMS:11）。

---

## 報告的其他判定與內部不一致

**其他判定的分類**
- 「已交付」：SUPPORTED。
- 「沒 sudo、沒碰 lab」：在 PATH 看得到的範圍內 SUPPORTED。
- 「沒 push、沒 merge」：UNDER-EVIDENCED，只有宣稱。
- 「沒碰主 checkout」：UNDER-EVIDENCED。
  - 閘門會執行 WT 裡經 symlink 連到主 checkout 的 venv 直譯器（SUM:4）。
  - MW:73-77 的探測在 import 時沒帶 DONTWRITE。
  - 沒有前後快照可以佐證。
- 「每一次執行都走 guard、nolab 在最前面」：SUPPORTED（每份 log 的 :5-7）。
- 「從唯讀的凍結副本執行」：UNDER-EVIDENCED。
  - 子腳本確實是從 scripts-notesN 跑的（每份 log 的 `# cmd` 行），也有 SHA256SUMS。
  - 但唯讀權限和 driver 本身從哪裡啟動，都沒有證據。
- 「沒有共用的檔案」：UNDER-EVIDENCED。merge 乾淨不等於沒有共用檔。
- 「trunk 上是 121」：UNTESTED。本次沒有在 merge 後的樹上跑 anchors。
- 「9/15 以 -j1 結尾」：SUPPORTED（redfirst_sge2.notes:16）。

**內部不一致**
1. SUM §1 的 R3-N3／N4 引 `notes2`，§1 的 R3-N1／N2 引 `notes`，§2 的 NOTE-5 引 `notes`。但 §4 宣告這兩輪整輪作廢。
2. S2／S3／S4 的 driver 標頭註解寫 `<gate>.notes-<sha8>.log`，實際的 TAG 是 notes2／3／4（S3/gates_notes.sh:8-9 對照 :16）。
3. NOTE-1 的兩句推論放在 OBSERVED 標題下，log 也把它寫進 ok 行（redfirst_notes.notes3:62）。
4. R3-N7 那段「任何 byte-code」的說法（見 Q5）。

---

## 我會跑、但報告沒跑的測試【跑】

1. R3-N7 的注入式紅：做法見 Q5。
2. 手跑 M16 和 M17，印出全部 FAILED 行：預期 M16 恰好一條、actual 是 `-j3`；M17 列出整個紅的集合。
3. 虛擬時鐘的邊界：
   - 把 `sleep 2` 改成 `sleep 2.5`：預期存活，也就是盲點。
   - 把 `sleep 2` 刪掉：預期卡住，直到外層 timeout。
   - 3000 s 的預設值在 MR:1429 的 `timeout 120` 底下：看 600 虛擬秒的上限能不能及時收掉。
4. 從 MW:115 的清單裡拿掉 `telemetry_override`：確認 control 仍然會過，把這個缺口記錄下來。
5. 在 merge 樹 4feceb1a 上跑 check_gate_anchors、mutate_build_guard、mutate_roles_binding。目前只在上面跑過 L1 suite。
6. 用同樣的 session 掃描檢查 08 的 self-test：08:753-754、:1001、:1386、:1410 都有背景行程或 kill。
7. 把 S3/tripwire.log 正式跑成一個 gate，而不是手讀。
8. 對主 checkout 的 venv 和 proxy_agent 做 `.pyc` 的前後快照，用來支撐「沒碰主 checkout」。

---

## NOTEs（都不擋 merge）

- **N-N1** SUM 的 OBSERVED 引證要改指向已交付的 notes3：
  - R3-N3／N4 → redfirst_notes.notes3:10-37
  - R3-N1／N2 → redfirst_lib_old_red／redfirst_lib_check／mutate_redfirst_lib 的 `.notes3`
  - NOTE-5 → mutate_build_guard.notes3:27-32
- **N-N2** R3-N7 的理由要補上 `consts`（08:139-141／1419）；再加一個會紅的 mutant，把「防禦性」升級成「看過紅」。
- **N-N3** M16 的殺手叫 `it puts the shims on PATH…`（TBG:111-112），名字把它真正釘住的東西蓋掉了：它是唯一釘住 guard 預設 JOBS 的格子。
  - 建議加一個專屬的 check，或改名。
  - 否則之後有人給 :111 加上顯式的 JOBS，預設值就又沒人釘了。
  - M17 的殺手可以改用 TBG:82，比較對題。
- **N-N4** 虛擬時鐘（07:623-625）的兩個改法：
  - fake sleep 收到非整數時要大聲失敗。
  - fake date 加一個呼叫次數上限，讓「時鐘不前進」也能終止並判紅。這樣連「sleep 被刪掉」都抓得到；舊的 6.5 s 格子原本也抓不到這種情況。
  - 另外要確認 600 虛擬秒的上限，在 MR:1429 的 120 s 內跑得完【推】。
- **N-N5** `ltree_control` 只要求三個 knob 裡的 `host_count_override`（MW:130）。如果 MW:115 的清單少了另外兩個名字，control 看不出來。
- **N-N6** MW:128 的 `ln -s` 改成 `ln -sn`，或先確認目標不存在，避免在 checkout 裡建 link。
- **N-N7** MW:73-77 的直譯器探測和 R3-N7 是同一類問題（既有的）。建議加上 `PYTHONDONTWRITEBYTECODE=1`，和 lrun、run_against 一致。
- **N-N8** 停車時，tripwire 也應該在新的 tag 下照樣跑成 gate。這次 notes3 的那 2114 行是 worker 手讀的；我 grep 過，結果一致。
- **N-N9** R3-N2 的檢查問的是變數，不是實際寫入的位置：一個忽略 `RF_KEEP_DEFAULT` 的 `_rf_keep` 也會通過。scratchpad 那支改過的 redfirst_r3.sh 也從來沒跑過。
- **N-N10** driver 標頭的註解過時了（見上面第 2 點）。
- **N-N11** 07 self-test 的 `file://` URL 遇到含空白的 TMPDIR 會全紅。這是 notes 輪觀測到的（redfirst_notes.notes:21-75），S3/redfirst_notes.sh:81-84 也自己寫了。它會大聲失敗，不會假綠；可以在 self-test 開頭拒絕這種 TMPDIR。
- **N-N12**（範圍外）R3-N6、NOTE-4、NOTE-6 仍然開著。NOTE-4 在 test_build_guard 這邊的中性對照（export LOCK／MEM_*）還沒有人跑。

---

## 相關檔案（絕對路徑）
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/hunt-0911/fix/FOLLOWUP-NOTES-SUMMARY.md
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/notes/diff-c34a643a..16069d1a.patch
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-followup-notes-0927/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/07_roles_basic.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-followup-notes-0927/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/08_heartbeat.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-followup-notes-0927/tests/shell/{mutate_p4_heartbeat_w,mutate_roles_binding,mutate_build_guard,test_build_guard,test_guarded_build_reentrant}.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-followup-notes-0927/tools/build_guard/guarded_build.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-followup-notes-0927/tools/build_guard/shims/_resolve.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/redfirst_notes.notes3-16069d1a.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/mutate_build_guard.notes3-16069d1a.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/mutate_roles_binding.notes3-16069d1a.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/mutate_p4_heartbeat_w.notes4-16069d1a.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/crosscheck_trunk.notes4-16069d1a.log
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/redfirst_sge2.notes3-16069d1a.kept/base.out
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-notes3-16069d1a/redfirst_notes.sh
- /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-notes3-16069d1a/tripwire.log
