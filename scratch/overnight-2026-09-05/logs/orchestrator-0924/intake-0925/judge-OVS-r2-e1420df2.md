**判決：MERGE AFTER FIXES（只剩一個小修正，約 5 行）**

第一輪的 blocking（F1）已修好。F1–F11、B、tests 5–8 共 15 項，14 項 CLOSED；F7 NOT CLOSED，但是有揭露、刻意不做的 note。擋住合併的只剩新引入 rc 變更的揭露（見「本輪新引入的問題」第 1 點）：`status --check` 有了一個新的 rc 1 原因，`ndt help` 的 status 段、手冊都沒寫，也沒有任何測試斷言這個 rc。

證據核對：19 份 `*.ndtovs-e1420df2.log` 第 1 行都是 `e1420df26d9d7a3703b814e40ea575402efd4f2e`，全部 `# rc=0`、`dirty tracked at start: 0`、`test/gate files under test are HEAD's: yes`。紅燈先行 log（146e1024）跑在已 commit 的舊 ndt（blob 3a0e66c6）上，結果 `Ran 156 checks, 18 failed`，並列出當時 dirty 的兩個檔。全程唯讀、沒執行任何東西。下文「推論」指讀碼推出、沒實跑。

## 逐項結果

| 項目 | 結果 | 證據（一行） |
|---|---|---|
| F1 零寬 window 失去 G-12 警語 | CLOSED | residue_report 讀紀錄的分支在 `wend == started` 時印同一段 NO-extent 警語（diff +9814-9829）；§11 紅 2 格轉綠；M24 抓到 |
| F2 回收號碼被判成 `group` | CLOSED | `pidfile_judge` 在問 group 之前先比啟動時間（ndt:4784-4788）；§12 用 setsid 起的陌生程序＋`.pgid` 測，對照組維持 NOT stale；M25、M28 抓到 |
| F3 window 右端沒測 | CLOSED | §9 斷言 `end=1789365600`；§13 有 log 比 pidfile 新的情況，end＝log mtime；M21 抓到（紅 5 格） |
| F4 window 寫不進去照樣刪 | CLOSED | ndt:4861-4867 保留檔案、rc 1、寫 `not_verified`；§13 驗過；M22 抓到 |
| F5 help 幾句不實 | CLOSED | 上輪點名的四句都改了（up、down 的 rc 1、身分分兩種檔講、clean 的 rc 3）；§16；M35 抓到。另見新問題第 1 點 |
| F6 紀錄寫在後續拒絕之前 | CLOSED（改成寫明） | help 加 `THE LINE MEANS "--force WAS USED"`、status 的 override 列、手冊 claim 段都寫了；M34 抓到 |
| F7 app_spawn 的 race | NOT CLOSED | 沒處理，SUMMARY §5.2 有揭露；原本就是 note，可接受 |
| F8 回收號碼的 stack pidfile | CLOSED | `pidfile_judge`（ndt:4794-4800）和 status 的 pidfiles 列都加了啟動時間檢查；§12；M26、M27 抓到。代價見 (a)、(b) |
| F9 閘門範圍 | CLOSED（一個有理由的例外） | 在 head 跑了 app_package 75/0、ovs4_has_sflow 24/0、test_teardown_guards 14/0、test_ndt_lab_session 18/0；`mutate_lab_claim_on_writes` 沒跑，理由成立，見 (c) |
| F10 證據瑕疵 | CLOSED | log 逐行列出 dirty 檔並寫明測試檔是否為 HEAD 的；`touched()` 的 tmp 欄在 suite 開頭自我驗證一次（test diff +214-222）。第一輪 f5b68399 那次 dirty 的是哪個檔，只能靠 worker 回憶，已揭露 |
| F11 live 步驟 | CLOSED | SUMMARY §6：先 claim、事先檢查 `.pgid`、加量測在跑的拒絕格（用 pid 收掉探針）、加 THEM 視角、最後還原 `viz.window` |
| B robust 第 21 節 | CLOSED | test_ndt_up_down_robust.sh:1681-1688：sleep 先 spawn 再寫 pidfile，用完先確認 comm 再依 pid 砍；M76 仍抓到（robust log:107） |
| test 5（symlink、自己 shell 的 group） | CLOSED | §14 兩種都不刪，symlink 指向的檔也不刪；M31、M32 抓到 |
| test 6（自己 claim 的 `measuring=`） | CLOSED | §15 確認不擋 `up`；M23 抓到 |
| test 7（dispatch 端到端） | CLOSED | §15 從受測 ndt 用 sed 取出 dispatch 區塊原樣執行，重試行和紀錄的 `command` 都是使用者打的字；M33 抓到 |
| test 8（讀回；TAB／換行） | CLOSED | `/dev/null` symlink ⇒ 讀不回 ⇒ 5；TAB 和換行仍是 1 行、10 欄；M29、M30 抓到 |

## (a) rc 變更（`status --check` 0 → 1）列到哪些地方了

- **程式行為屬實（已核）。** 回收號碼的 stack pidfile 會進 `bad` → `STACK_PIDFILE_PROBLEMS`（ndt:5567）→ `problems`（6750）。但只有在有 baseline（`.test_run/up.target` 存在）時才是 1；沒有 baseline 時照舊回 3（6919-6926）。SUMMARY §2 那一列少了這個限定。
- **`ndt help`：沒列。** status 段（ndt:10769-10773）還是只寫「a pidfile naming a process that is gone … a --check problem」。回收規則只寫在 down 段（10703-10706），沒提到 `--check`。手冊 :153 說 rc 的正本是 help。
- **手冊：沒列。** :512-522 只講 app pidfile，而且說它不讓 `--check` 變紅。P4 的驗收條件「`status --check` 回 rc=0 才算過」（:494）正是這個變更可能翻掉的東西。
- **測試：沒有測試斷言這個 rc。** §12 只驗 pidfiles 列的文字和 `down`，沒跑 `cmd_status check`。rc 靠的是既有、有測試的接線（10A/10B 對死 pid 釘住了 rc 1），所以是靠構造成立。既有的 test_ndt_* 都沒有依賴舊 rc 0：10C 用的是 `$$`，比它的 pidfile 早啟動；26 支 suite 全綠。唯一跑 `--check` 的 live cell 刻意不判 rc（stale_app_pidfile_does_not_frame_the_fabric.sh:280-293）。
- **ndt serve：表不用改。**
  - `RC_TABLE["status.check"][1]` 本來就是泛稱（「…and more; the output names each one」，verbs.py:210-212）。
  - `test_status_check_rc1_names_any_problem` 只要求出現 problem、claim、measurement、output 這幾個字（test_ndt_serve.py:1059-1063）。
  - 要改的只有已知的 19 個行號錨點。我在 head 抽查了其中 11 個新行號（6926／6931／6935／6937、8758／8762／8835、10209、10276／10279／10282），都含 needle，和 serve_evidence log 一致。
  - verbs.py:206-209 和 248-249 的註解會過期。

## (b) 2 秒容許的啟動時間規則會不會誤判

- **活著的正常 app：不會（已核）。** `pid_is_app` 先比 argv（ndt:4781），比中就是 live，時間檢查根本不會跑。只有 argv 對不上的 app 才會走到時間檢查。
- **stack pidfile：會（推論，沒實測）。** 每個活著的 stack pid 都要過時間檢查。算法是 `btime + starttime/HZ` 對 pidfile 的 mtime。
  - 單純 suspend/resume 不會觸發：在目前的 kernel 上，starttime 以 boottime 計（含 suspend），`/proc/stat` 的 btime＝realtime − boottime，suspend 前後不變。
  - 會觸發的是 resume 之後（或開機後第一次）NTP 往前調時鐘、或手動 `date -s`：每往前調 Δ，btime 就加 Δ，程序算出來的啟動時間跟著晚 Δ，pidfile 的 mtime 卻不變。
  - 累積往前調超過約 2 s 之後，健康 lab 的 `kernel.pid`／`ryu.pid`／`p4_proxy.pid` 會被判成回收：
    - 有 baseline 時 `--check` 變 rc 1；
    - `clean`／`down` 不再把它當 subject；
    - `down` 會刪掉它。在那之前 stack.sh 的 `stop_one` 用同一條規則已經拒絕停這個程序，所以 kernel 繼續跑、但沒有任何紀錄，下一次 teardown 會把它當外人並建議 `--deep`。
- **pidfile 事後被 touch 成較新：** 只會讓檢查答「不是回收」，可能漏掉真的回收，但不會捏造一個。
- **pidfile 被倒填成較舊**（用保留時間戳的方式還原 `.test_run`、`touch -d`）：會捏造。ndt、stack.sh、supervise.sh、ndtwin-lab 裡都沒有 touch 或倒填 pidfile 的程式（grep 過）。
- **修法：**
  - stack 的 `<name>.pid` 記的是 supervise.sh，它的 argv 裡有 `$PID_DIR/<name>` 這個元素（stack.sh:579；supervise.sh:3、48），而且它不 exec、會一直活著。先比這個，跟時鐘無關。
  - `.child.pid` 可以對 stack.sh 寫下的 `<name>.cmd`（stack.sh:587-588）。
  - `stop_one` 應該一起改。
  - 可以先查證有沒有發生過：grep 過去 teardown log 裡 `stop_one` 的「refusing to stop … started Ns AFTER」。

## (c) 沒跑 `mutate_lab_claim_on_writes.sh`：理由成立

- kernel 只讀 `NDT_LAB_CLAIM_FILE`＝`$KERNEL_DIR/.test_run/lab.claim`（stack.sh:1119），解析 `owner`／`note`／`expires`，不認得的 key 一律忽略（HttpSession.cpp:175-225）。
- 這個分支沒動 stack.sh、HttpSession.cpp、spec.py、C++ 測試，也沒動 `tests/python/test_contract_spec.py`，這些正是那支閘門的全部輸入（mutate_lab_claim_on_writes.sh:58-68）。
- `lab.claim` 的路徑和格式都沒變。新增的只有兩樣：
  - `note=` 裡多了新的自由文字（F4 的 `not_verified` 經既有的 `claim_note_down` 寫進去，仍是一行）；
  - 旁邊多了一個 kernel 從來不開的 `lab.claim.overrides`。
- anchor checker 對這支閘門是 ok。閘門結果不可能和 base 不同。端到端的讀取仍由 live cell `northbound_write_reply_names_the_lab_claim.sh` 負責。

## (d) F4：`down` 回 1 並保留檔案之後的狀態

- **下一次 `up`：不會處理錯。** `up` 不讀 claim note，全檔只有 `cmd_status` 讀 note（ndt:6565），也不會因為上次 down 沒驗乾淨就拒絕。preflight 的 `port_owner_local`（ndt:204-219）會讀 `.test_run/pids/` 下每個檔，包括被保留的那個，所以既有的「ours」引信在這個失敗情況下仍然在；它只是 advisory，和 base 一樣。
- **`release`：** 只看 claim 和 knob baseline（ndt:865-900），不受影響。
- **`ndt apps start <app>`：** 會覆寫被保留的 pidfile，所以該 app 下次啟動時這個狀態就自己清掉。
- **真正的效果是 rc 1 會一直重複。** 原因（例如 `.test_run/apps` 不能寫）沒排除之前，每一次 `down` 都回 1。run_cells.sh 把 `down` 回 1 當成 RESTORE-FAIL 並停掉整個 grid（run_cells.sh:151-165、173-186）。錯誤訊息講了原因，但沒講怎麼救。同一台機器上 `clean` 會回 3（stale 不算 subject）。
- **這條規則只套用在一處。** `app_stop` 自己的路徑在 window 寫不進去時仍然會刪 pidfile（ndt:8916-8917、9050），這是既有程式，這次沒改。

## 本輪新引入的問題

1. **[blocking，小] 新的 `--check` rc 1 原因沒有寫進正本、也沒有測試。** 修法：
   - ndt:10769 補一句：「a stack pidfile whose live pid started after the file was written (a recycled number) is stale too, and a --check problem while a baseline exists」；
   - 手冊 :512-522 附近補同義的一句；
   - 加一格：有 baseline 的 fixture 上放一個回收號碼的 `kernel.pid` ⇒ `status --check` rc 1，對照組 ⇒ rc 0；
   - SUMMARY §2 那一列補上「只在有 baseline 時；否則仍是 3」。
2. **[should-fix] 時鐘往前調造成的誤判，見 (b)。** 這是從 `stop_one` 繼承來的規則，但這輪讓它多影響了 `status --check` 和 `down` 刪檔。建議另開一張單，stack.sh 和 ndt 一起改。
3. **[note] 同一次 `down` 的輸出互相矛盾。** `stop_one` 說「Leaving it alone and keeping the pidfile … rm <pidfile>」，接著 ndt 把它刪掉。stack.sh 的 `cmd_down` 不看 `stop_one` 的回傳碼（stack.sh:1171），所以 SUMMARY 說的「rc 3」在真 stack.sh 上仍然成立。建議在 ndt 的刪除訊息裡說一句「stack.sh kept it above because the number is somebody else's」。
4. **[note] (d) 的持續 rc 1 會停掉 grid，錯誤訊息少了救法；app_stop 的路徑沒套用同一條規則。**
5. **[note] 手冊 :514 和程式不一致。** 手冊寫回收號碼要「而且」group 也沒程序才算 stale；程式在問 group 之前就直接判 stale（ndt:4784-4787、4795-4798）。
6. **[note] F1 的警語也會出現在 `app_stop` 正常停止時寫下的零寬 window**（啟動和停止在同一秒）。訊息說「nothing can date when X stopped」，不精確，但無害。
7. **[note] 變異閘門 log 的標頭仍寫「20 named mutants, 2 controls」**，worker 已經說明。

**合併判決：** 修完第 1 點（help 一句、手冊一句、一格測試，加 SUMMARY 一個限定詞）就可以合併。第 2 點建議另開工單，不擋這次合併；其餘是 note。
