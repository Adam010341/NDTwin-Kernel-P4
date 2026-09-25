# NDT-OVS SUMMARY — OVS 的 `ndt up` 像 P4 一樣尊重別人的 claim；`--force` 留紀錄；過期 pidfile 被認出來

[Co-developed with claude code -- Adam]

- 工單：`doc/audit/2026-09-25_ndt-ovs-claim/TICKET-ndt-ovs-claim.md`（Adam 09-25 裁決）；紀律照 `doc/audit/2026-09-25_p4-heartbeat/TICKET-P4-heartbeat.md` §3
- 第二輪依據：判官報告 `logs/orchestrator-0924/intake-0925/judge-OVS-6b7fce83.md`（MERGE AFTER FIXES），以及 orchestrator 第二輪指示。
- 第三輪依據：判官 r2 報告 `logs/orchestrator-0924/intake-0925/judge-OVS-r2-e1420df2.md`（MERGE AFTER FIXES；15 項中 14 項 CLOSED，F7 是有揭露的 note），以及 orchestrator 第三輪指示。已裁定的兩點：
  - 覆寫紀錄維持獨立檔 `.test_run/lab.claim.overrides`
  - stale 的 app pidfile **不讓** `status --check` 變紅，10D 維持
- 分支 `fix/ndt-ovs-claim-0925`（worktree `scratch/overnight-2026-09-05/wt-ndt-ovs-claim-0925`），base trunk `62f76cf5`
- commit（依序）：

| sha | 內容 |
|---|---|
| `01cb5017` | 第一輪測試，紅燈先行 |
| `f5b68399` | 第一輪 harness 修正（仍紅） |
| `e684990f` | 第一輪修正＋變異閘門 |
| `6b7fce83` | M68 錨點原字放回（第一輪交付 head，判官審的版本） |
| `146e1024` | **第二輪測試，紅燈先行**（在已 commit 的 ndt 上紅 18/156） |
| `8b6f51f2` | **第二輪修正**：F1／F2／F3／F4／F5／F6／F8＋手冊＋M21–M35、C3 |
| `54d2518a` | 手冊 RESIDUE-1 來源註解不再說「待 Adam」 |
| `e1420df2` | tmp= 探針檔名加 `$$`（`check_test_tmpdirs` 在 54d2518a 報 2 筆）——第二輪交付 head |
| `c6868f7e` | **第三輪測試，紅燈先行**（在 e1420df2 的 ndt／手冊上紅 5/166） |
| **`98442add`** | **第三輪修正**：status help 與手冊寫明新的 `--check` rc 1、手冊改對回收號碼的判定順序、`down` 兩句訊息、M36–M39——**交付 head** |

- 動到的檔案：
  - `tools/test_workflow/ndt`
  - `doc/2026-08-17_testing-manual.md`（第二輪起在範圍內）
  - `tests/shell/test_ndt_ovs_claim.sh`（新）
  - `tests/shell/mutate_ndt_ovs_claim.sh`（新）
  - `tests/shell/test_ndt_up_down_robust.sh`（第 21 節一格）
- 沒有 lab、沒有對真 lab 跑 `ndt up/down`、沒有 sudo、沒有 C++、沒有 push／merge；主 checkout 沒有 `cd` 進去。寫進主 checkout 的只有指定的 gate log、`logs/gates-0910/scripts-ndtovs/serve_evidence.sh`（唯讀取證腳本）和本檔。

---

## 00. 第三輪：判官 r2 的處理

| 判官 r2 | 改了什麼 | 測試 | 變異 |
|---|---|---|---|
| **#1**（blocking） | `ndt help` status 段加一句：stack pidfile 的活 pid 比檔案晚啟動（回收的號碼）也是 stale，而且是 `--check` problem——**有 baseline 時 rc 1，沒有時仍是 3**。手冊 stale pidfile 那段加同義的一句，並提醒上面 P4 那條「`ndt status --check` 回 rc=0 才算過」碰到它會翻成 1。§2 那一列補上限定詞 | §17（新）：有 baseline 的 fixture 上，回收號碼的 `kernel.pid` ⇒ `status --check` rc 1，而且 problem 清單點名它；對照組（同一個活 pid、檔案在它啟動之後才寫）⇒ rc 0；沒有 baseline ⇒ 3，那一行列在「everything else」底下。§16 加 help 與手冊句子的斷言 | **M36**（印出來但不算 problem ⇒ rc 0）、M37（help 拿掉 baseline 限定） |
| **#5** | 手冊改成程式實際的做法：pid 不在或不是 app，**而且** group 空 ⇒ stale；**號碼被回收則直接判 stale，不問 group**，app 與 stack 的檔都一樣 | §16 斷言手冊這句（讀 repo 的手冊） | —（手冊不在變異範圍） |
| **#3** | `down` 刪掉 kernel／p4_proxy／ryu 的回收號碼 pidfile 時，訊息多一句 `; stack.sh kept it above because the number is somebody else's` | §12 | M38 |
| **#4** | F4 錯誤多一行救法：`to recover: make .test_run/apps a directory this user can write, then run 'ndt down' again` | §13 | M39 |
| **#7** | 變異閘門 log 標頭的描述改成跑的時候從 gate 腳本數出來（`grep -c '^check_fires '`／`'^check_control '`），不再是寫死的常數：`mutation gate for the suite (39 named mutants, 3 controls -- counted from the script at run time)` | — | — |
| **#2**（不在這輪） | 沒動，stack.sh 也沒碰。已記在 §5 已知限制 | — | — |

**紅燈先行**：`c6868f7e` 只 commit 測試。在 e1420df2 的 ndt／手冊上紅 5 格：#3、#4、help、手冊 ×2。§17 在 e1420df2 上是綠的，因為 rc 靠既有接線就已成立；它在 base `62f76cf5` 上是紅的（`expected: [1] actual: [0]`），證明這格釘住的就是 rc 變更本身；M36 證明它在 head 上也紅得起來。

## 0. 第二輪：判官每一條的處理

| 判官 | 改了什麼 | 測試（test_ndt_ovs_claim.sh） | 變異 |
|---|---|---|---|
| **F1**（blocking）| `residue_report` 讀 window 紀錄的那個分支，遇到零寬 window 時印出和 seal 分支同樣的 `has NO extent … NOT 'this app left nothing'`（放在 window 行之上，理由同 seal 分支） | §11：死 pid 的 energy pidfile → 報告（對照：pidfile 在時就有警語）→ `down`（rc 3、檔刪、`energy.window` start=end）→ 報告必須還有警語 | M24 |
| **F2** | 新增 `proc_start_epoch`、`pidfile_outlived_by`（照 stack.sh `stop_one` 的做法：啟動時間對 pidfile mtime，容許 2 s）。app pidfile 的號碼活著但不是 app，而且那個程序比檔案晚啟動 ⇒ 回收的號碼 ⇒ **直接判 stale**，不再去問 group | §12：setsid 起的陌生程序，`.pgid`＝它自己，pidfile mtime 設在 600 s 前 ⇒ STALE、`down` 刪掉並回 3、陌生程序沒被送訊號。**對照**：同一個陌生程序、檔案在它啟動之後才寫 ⇒ 不是 stale（`is NOT stale`） | M25、M28（加寬：任何活 pid 都算「比檔晚」） |
| **F8** | 同樣的啟動時間檢查套到 stack pidfile：`pidfile_judge` 和 status 的 pidfiles 列都加。回收的 stack pid ⇒ stale，不再印成 `alive` | §12：`kernel.pid`＝比檔晚啟動的陌生程序 ⇒ 列上顯示 stale、`down` 不當 subject（rc 3）並刪掉。**對照**：檔在程序之後才寫 ⇒ `alive`，`down` 回 0 並保留 | M26、M27 |
| **F3** | （程式本來就對）| §9 斷言 `end=1789365600`（沒有 log ⇒ 零寬）；§13 放一個比 pidfile 新的 app log ⇒ `end=` 等於 log 的 mtime | **M21**（end 寫成 now） |
| **F4** | `registry_clear_stale`：window 寫不進去就**保留** pidfile，印出原因、rc 1、`not_verified`（claim note 會點名）。另一種失敗（刪不掉）也改成自己寫 `not_verified` | §13：`.test_run/apps` 做成一般檔案 ⇒ pidfile 還在、`down` 回 1、claim note 含 `app_viz.pid kept` | M22（M16 重新錨定在同一行） |
| **F5** | help 四處改成實話：① 只有「真的越過了東西」的 `--force` 才寫一行，沒東西可越過就不寫；② 身分比對分兩種檔講清楚（app＝pid＋argv；stack＝只看 pid；兩種都加啟動時間）；③ `down` 的 rc 1 清單補上新原因；④ `clean` 的 rc 3 改成 `nothing in .test_run/pids/ naming a live process`（第一行 `3 THERE WAS NOTHING TO JUDGE: no fabric, nothing in` 原字保留，因為 honesty／manual_rc_table 兩個閘門錨在它上面） | §16 五句 | M35 |
| **F6** | 採「寫明」：help 加 `THE LINE MEANS "--force WAS USED", NOT "IT CAME UP"`；status 的 override 列最後一行也這樣說；手冊同。**沒有**把結果寫進紀錄 | §16 | M34 |
| F7 | 未處理（判官列為 note：`app_spawn` 在 exec 之前約 1 ms 的 race）。見 §5 | — | — |
| **F9** | 在 head 重跑 `mutate_ndt_app_package.sh`、`mutate_ovs4_has_sflow.sh`、`tools/test_workflow/test_teardown_guards.sh`、`test_ndt_lab_session.sh`。**`mutate_lab_claim_on_writes.sh` 沒跑**：它會改 `HttpSession.cpp` 並用 ninja 編 C++ 測試 binary，本 worker 規則禁止編 C++（見 §5）。它的錨點在 C++／spec.py，這個分支沒碰；`check_gate_anchors` 對它是 ok | — | — |
| **F10** | ① gate log 開頭與結尾逐行列出哪個 tracked 檔是 dirty，並加一行「測試檔是否就是 HEAD 的」。② 第一輪 f5b68399 紅燈 log 的「dirty 1」：當時 dirty 的是 `tools/test_workflow/ndt`（未 commit 的修正）；那次是用 `NDT_UNDER_TEST` 指向 HEAD blob 的副本跑的，log 也有記。這是我在 session 裡看到的 `git status`，當時沒寫進 log。③ `touched()` 的 `tmp=` 欄現在開頭就自我驗證一次能讀到非零 | 開頭自我驗證 | — |
| **F11** | live 步驟改寫：還原 `viz.window`、事先檢查 `app_viz.pgid`、加 in_flight 拒絕格、加 THEM 視角的 status 格，見 §6 | — | — |
| **B** | robust 第 21 節改種一個 spawn 出來的 `sleep`（在寫 pidfile 之前起，所以也不算回收的號碼），用完依 pid 砍掉 | — | M76 仍抓到（見 §3） |
| **tests 5–8** | 見下 | §14：symlink 與「自己 shell 的 group」`down` 都不刪（連 symlink 指向的檔也不刪）。§15：自己 claim 的 `measuring=` 不擋 `up`；**原封不動跑 ndt 尾端的 dispatch `case` 區塊**跑 `ndt up 4`／`ndt up 4 --force`，斷言重試行與紀錄的 `command` 就是使用者打的；紀錄讀不回（`lab.claim.overrides` → `/dev/null`）⇒ 5；note 與 owner 裡的 TAB、FX_BUSY 裡的換行 ⇒ 仍是一行、10 個欄位 | M31、M32、M23、M33、M29、M30 |

---

## 1. 設計（第一輪＋第二輪的現況）

### 1.1 一個守衛，兩個平面都呼叫

- `guard_up_lab_free <what>`，語意照 P4 原樣：
  - 別人的有效 claim（`foreign_claim`；`NDT_OWNER` 沒設時任何有效 claim 都算）⇒ **5**
  - `in_flight` 非空 ⇒ **5**
  - 自己 claim 上的 `measuring=` **不擋**（§15 有測試、M23）
- `up_p4` 呼叫方式是 `guard_up_lab_free "$up_what"`：`up_what` 平常是 `"p4 $hosts"`，帶 `--app` 時是 `"p4 --app <dir>"`。只有在沒有經過 dispatch、`NDT_UP_WORDS` 為空時，才用它來拼重試行。
- `up_ovs` 呼叫方式是 `guard_up_lab_free "ovs $ovs_hosts"`，位置在 topo 檢查之後、**`mktemp`／`mkfifo` 之前**。
- 拒絕訊息：`refusing to build: …`，接著是可以直接貼上的兩行 `NDT_OWNER=<只有 owner，%q 過> ndt up <原本打的>` 與 `… --force`。
- `up_p4` 原本的 `# 🔴 rc 5: refused. (Adam, 2026-09-12)` 加 `return 5` 兩行原字保留在守衛裡，因為 robust 閘門的 M68 錨在它上面。

### 1.2 `--force` 與 `.test_run/lab.claim.overrides`

- 在 `up_take_app_flag` 解析，兩個平面共用，argv 任何位置都可以。環境變數 `NDT_UP_FORCE` 在載入時和每次解析時都會清空，export 沒有作用。
- 只有**真的越過了什麼**才 append 一行，10 個 tab 分隔欄位：`at` `by` `user` `pid` `command` `over` `claim_expires` `claim_note` `measuring` `running`。寫完用整行比對讀回；寫不進去或讀不回 ⇒ 5。
- **這一行的意思是「用了 `--force`」，不是「建起來了」**：守衛之後的 preflight、`mn_count`、H4 照樣可能拒絕。建起來沒有，看那一次的 rc。
- `status` 的 `override` 列會印這一行的內容，屬於歷史，不算 `--check` problem。

### 1.3 過期 pidfile（`pidfile_judge`，一個判定供 status、subject、`down` 三處共用）

- **`live`**：pid 存在，而且
  - app 的 pidfile：argv 帶該 app 的簽名；
  - 兩種 pidfile 都要：程序**不是**在檔案寫下 2 s 之後才啟動。
- **`stale`**：符合下列任一：
  - pid 不存在，且記錄的 group 沒有成員（或根本沒記錄 group）；
  - app 的 pid 活著但不是該 app，且 group 沒有成員；
  - **任何** pid 活著，但比檔案晚啟動（號碼被回收）。這一條直接判定，不再問 group。
- **`group`**：pid 不在，但 group 還有成員 ⇒ 不是 stale，檔案保留。
- **`unusable`**：內容不是合法 pid。
- **`unjudged`**：symlink，或要問的 group 是本 shell 自己的。兩種情況都不刪。
- 三處的用法：
  - `pid_registry_entries` 跳過 stale，所以 stale 檔不算 `down`／`clean` 的 subject。
  - `down` 在 `[3/3]` 之後呼叫 `registry_clear_stale`：app 的檔先把 window 寫進 `.test_run/apps/<app>.window`（右端＝seal 的那一端），**寫不進去就保留檔案、rc 1**。
  - `status`：app 的檔在 apps 區塊標 `STALE`，只是標記；stack 的檔在 pidfiles 列標出，算 problem（R7 I-3 以來就是這樣）。
- `residue_report` 不管 window 來自 pidfile 還是紀錄，遇到零寬 window 都印 G-12 的警語（F1）。

---

## 2. rc／輸出變更表（ndt serve 包著 `ndt`，請轉告）；「之前」＝`62f76cf5`

| 指令 | 情境 | 之前 | 之後（`e1420df2`） |
|---|---|---|---|
| `ndt up`／`up ovs [128]`／`up 4`／`up ovs4` | 別人的有效 claim（`NDT_OWNER` 沒設時任何有效 claim） | 照建，rc 0／1，只有一行「claim note was NOT updated」警告 | **rc 5**，stderr `refusing to build: the lab is claimed by …`；什麼都沒建、沒寫 |
| 同上 | `in_flight`：iperf3 client；或**任何** argv 含 `matrix.sh`／`measure.sh`／`cpu_probe.py` 的程序（例如開著那個檔的編輯器、`tail`，或當祖父程序的 driver；只排除 `$$` 與 `$PPID`） | 照建 | **rc 5** `refusing to build: a measurement is running; …`＋程序列表。P4 本來就這樣；**OVS 的呼叫者是第一次碰到** |
| `ndt up p4 …` | 別人的 claim | rc 5，一行 `XX the lab is claimed by X; 'ndt up' may restart the stack under them.` | rc 5；多行：`refusing to build: the lab is claimed by X`／`'ndt up' may restart …`／nothing-built／兩行重試 |
| `ndt up p4 …` | `in_flight` | rc 5 `a measurement is running; …` | rc 5；前面加 `refusing to build: ` |
| `ndt up --force`、`ndt up --force ovs 4` | 任何情境 | **rc 2**（`resolve_up_target` 拿到 `--force`） | 照常解析 |
| `ndt up ovs --force`、`ndt up p4 --force` | 任何情境 | **rc 2**（`--force` 被當成大小：`OVS can only build 4 or 128 hosts`／p4 的 usage） | 照常解析 |
| `ndt up 4 --force`、`ndt up ovs4 --force`、`ndt up ovs 4 --force` | 別人的 claim | `--force` 被忽略，OVS 沒有守衛 ⇒ 照建 | 照建，stdout `!! --force: building over the claim of …`，並記一行 |
| `ndt up p4 4 --force` | 別人的 claim | `--force` 被忽略 ⇒ **rc 5** | 照建（rc 0／1），記一行 |
| `ndt up … --force` | 紀錄寫不進去或讀不回 | — | **rc 5**，`--force was given, but the override could not be recorded` |
| `ndt up … --force` | 沒東西要越過 | — | 照建，**不寫紀錄** |
| `ndt up` usage 錯誤 | — | `usage: ndt up [...]` | 句尾多了 ` [--force]`（rc 2 不變） |
| `ndt down` | lab 已 down，只剩 stale 檔 | **rc 0**，檔永遠留著 | **rc 3**；`verify clean` 之前多一個 `stale registry entries` 區塊；rc 3 說明多一行 `N STALE registry entr(y/ies) … did not count` |
| `ndt down` | 任何情境裡有 stale app 檔 | 檔留著 | 檔被刪；寫入（**覆寫**）`.test_run/apps/<app>.window`，**已 down 的 lab 也會寫** |
| `ndt down` | stale app 檔的 window 寫不進去 | — | **rc 1**；檔**保留**；`XX kept stale … window could not be written`＋`XX   to recover: make .test_run/apps a directory this user can write, then run 'ndt down' again`；claim note `did NOT verify clean -- … kept: …` |
| `ndt down` | stale 檔刪不掉 | — | **rc 1**；claim note 點名 |
| `ndt down` | stale 條目 | 會列在 `this teardown is about:` 底下 | **不再列出** |
| `ndt down` | rc 3 說明文字 | `no fabric, no registry entry in .test_run/pids/, and no port in ports.sh's table` | `no fabric, no registry entry in .test_run/pids/ naming a live process, and no port in` 換行接續（3 行） |
| `ndt down` | pid 死了但 group 還活；symlink；group 是自己 shell 的；unusable | rc 0 | rc 0 不變，檔保留 |
| `ndt down` | 回收的號碼（活著、比檔晚啟動）：app 或 stack 的檔 | 算 subject ⇒ 已 down 的 lab 回 rc 0，檔保留 | **不是** subject ⇒ rc 3，檔刪掉（stack 的：stack.sh `stop_one` 本來就拒絕送訊號給它）；kernel／p4_proxy／ryu 的刪除訊息多一句 `; stack.sh kept it above because the number is somebody else's` |
| `ndt clean` | 只剩 stale 檔 | **rc 0** `clean` | **rc 3** `nothing to judge`，下面列出 STALE 檔（不刪） |
| `ndt clean` | rc 3 說明文字 | `nothing in .test_run/pids/` | `nothing live in .test_run/pids/` |
| `ndt status` | `.test_run/lab.claim.overrides` 存在 | — | 新增 `override` 列（3 行，在 `prev claim` 之後，最後一行說明「was USED, not that the bring-up came up」）；不算 problem |
| `ndt status` | stale 的 app 檔 | 沒提示 | apps 區塊新增 `app pidfile  STALE -- …` 兩行；**不算 problem，`--check` rc 不變** |
| `ndt status` | app 檔 pid 死了但 pgid group 還活 | 沒提示 | `app pidfile  … is NOT stale -- …`（不算 problem） |
| `ndt status` pidfiles 列 | stack 檔號碼死了，那個號碼的 group 還活 | `stale pidfile (…)`，算 problem | `<f>: NOT stale -- … still has live member(s)`，仍算 problem＋多一行註腳（rc 1 不變） |
| `ndt status` pidfiles 列 | **stack 檔號碼活著，但比檔晚啟動** | `<f>=<pid> alive`，**不算 problem** | `<f>: stale pidfile (pid N is alive, but that process started Ns after …)`，**算 problem ⇒ `status --check` 從 rc 0 變 1，只在有 baseline（`.test_run/up.target`）時；否則仍是 3**（那一行列在「everything else this report could still check」底下）。help status 段與手冊都寫了（第三輪） |
| 讀 window 的 residue 報告（`status --check` 的 rules-in-window、`apps orphans`、`apps stop`） | window 來自 `.test_run/apps/<app>.window` 且寬度為零（包括 `down` 替 energy 寫的那種） | 印 window 行＋`no flow entry arrived during that window`，沒有警語 | window 行**上方**多三行 `the window below has NO extent … NOT 'this app left nothing'. (G-12; this window is a record)`；rc／計數不變 |
| `ndt help` | — | — | up／down／status／clean 各段與 claim 說明都有新文字；ndt serve 的 `RC_SOURCE["help"]` 11 句和手冊 rc 表 5 句全部原句保留（見 §4 serve_evidence log） |

**ndt serve 行號錨點（在最終 head `98442add` 重算；第三輪改了 `registry_clear_stale`，status／apps 的錨點又移了 13 行）**

算法：difflib 對 base `62f76cf5` 的相等區塊做對應，每一個新行號都驗過含 needle，舊行號在新檔裡全都不含 needle。證據在 `serve_evidence.ndtovs-98442add.log`（e1420df2 那份是上一版的表）。這張表對應 `verbs.RC_SOURCE` 的 8 行（verbs.py:263–270）：

| verbs.py 行 | kind | 舊行號 → **新行號** | needle |
|---|---|---|---|
| 263 | `status.check` | 6486→**6939**、6491→**6944**、6495→**6948** | `return 3`／`return 0`／`return 1` |
| 264 | `status` | 6497→**6950** | `return 0` |
| 265–266 | `claim` | 748→**753**、757→**762**、782→**787**、855→**860**、857→**862** | `return 2`／`return 2`／`return 1`／`return 1`／`ok "lab claimed by` |
| 267 | `release` | 861→**866**、866→**871**、894→**899** | `return 0`／`return 1`／`return 1` |
| 268 | `apps.start` | 8311→**8771**、8315→**8775**、8388→**8848** | `return 0`／`return 1`／`return 1` |
| 269 | `apps.stop` | 9814→**10289**、9817→**10292**、9820→**10295** | `return 1`／`return 2`／`return 0` |
| 270 | `apps.status` | 9747→**10222** | `return 0` |

- serve 在 `ntg)` 之後插入的內容，比上面所有錨點都後面，所以併入之後行號不變。
- `git merge-tree --write-tree HEAD feat/ndt-serve-0924` 沒有衝突，有 log。
- verbs.py:207 附近的**註解**引用 ndt 的行號（6493–6495、6128 等），以及 verbs.py:248–249 的「lines below 10097 are identical to trunk fd7382a3」，併入後都會過期。它們不是錨點，只是會說錯。

---

## 3. 測試與閘門

- 全部經 `tools/build_guard/guarded_build.sh`（`JOBS=1 LOCK_WAIT=10800`）。log 在 `scratch/overnight-2026-09-05/logs/gates-0910/`，每個 log 第 1 行都是完整 HEAD sha。
- 下表的「結果」是 **gate 輸出的最後一行**。每份 log 真正的最後幾行是 `# rc=…`、`# end …`、`# dirty tracked at end: N`，最終這批的 N 都是 0，沒有 `#   dirty:` 行。
- `mutate_ndt_ovs_claim.ndtovs-e1420df2.log` 的 `# gate :` 標頭文字還寫著舊的「20 named mutants, 2 controls」，那是 driver 的描述字串沒改；實際跑的是 35＋3，看最後一行。

**紅燈先行（第二輪）**

| log | 條件 | 結果 |
|---|---|---|
| `test_ndt_ovs_claim.red-first.ndtovs-146e1024.log` | 測試已 commit；ndt＝HEAD 已 commit 的 blob `3a0e66c6`（＝6b7fce83 的）；log 列出當時 dirty 的是 ndt 和手冊（未 commit 的修正），並寫明「test/gate files under test are HEAD's: yes」 | `Ran 156 checks, 18 failed` |

紅的 18 格：F1 ×2、F2 ×4、F8 ×3、F4 ×4、help ×5。F3 的右端、tests 5–8 的各格在舊碼上是綠的，它們是守門格，由 M21、M23、M29–M33 證明看得到紅。

**第三輪（交付 head `98442add`）——只重跑這輪 diff 碰到的**

| log | 結果 |
|---|---|
| `test_ndt_ovs_claim.red-first.ndtovs-c6868f7e.log`（測試已 commit，ndt／手冊＝e1420df2 的） | `Ran 166 checks, 5 failed` |
| `test_ndt_ovs_claim.base-62f76cf5.ndtovs-c6868f7e.log`（同一份測試，ndt＝base blob `3273df8b`：證明 §17 釘住 rc 變更本身） | §17：`expected: [1]  actual: [0]`；全檔 `Ran 166 checks, 112 failed`（其餘紅的是第一、二輪的行為） |
| `test_ndt_ovs_claim.ndtovs-98442add.log` | `Ran 166 checks, 0 failed` |
| `mutate_ndt_ovs_claim.ndtovs-98442add.log`（標頭現在寫「39 named mutants, 3 controls -- counted from the script at run time」） | `mutation gate: 39 mutations, 0 survived; 3 control(s), 0 went red`（M36[2] M37[1] M38[1] M39[1]） |
| `mutate_manual_rc_table.ndtovs-98442add.log` | `mutation gate: 10 mutations, 0 survived; 1 control(s), 0 went red` |
| `mutate_manual_no_stale_in_progress.ndtovs-98442add.log` | `mutation gate: 16 mutations, 0 survived; 1 control(s), 0 went red` |
| `check_gate_anchors.ndtovs-98442add.log` | `117/117 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` |
| `static_checks.ndtovs-98442add.log` | `check_test_tmpdirs: 354 file(s) scanned, 0 fixed temp paths`（process_by_name 0 site） |
| `serve_evidence.ndtovs-98442add.log` | `== verdict: merge-tree rc=0 conflicted-paths=0 anchors-bad=0 phrases-missing=0` |
| **`ndt_lab_suite.ndtovs-98442add.log`** | **`suite: 1 file(s) red`**——`test_ndt_helper_apps_window.sh` 150 格紅 1 格，**是機器環境造成的，不是這輪的 diff**，見下 |
| `helper_env_evidence.ndtovs-98442add.log`（唯讀取證） | 見下 |

**`ndt_lab_suite` 那 1 格紅（OBSERVED）**
- 紅的是 `🔴 the installed helper is the copy this suite read`：這格拿機器上**已安裝的** `/usr/local/sbin/ndtwin-lab` 跟這棵樹的 `tools/test_workflow/ndtwin-lab` 比 sha256。
- 已安裝的那份在 **2026-09-25 19:34:12** 被換掉，不是我換的；我沒有 sudo，也沒碰那個檔。它的 sha256 `6a558fe4…` 等於 **trunk** 現在的版本（trunk 最後一次改它是 `f139c800` heartbeat round 2，17:39）。
- 這個分支的那份仍是 base 的 `6685d3a9…`，自 `62f76cf5` 起 diff 0 行。
- 同一支 suite 在 `ndt_lab_suite.ndtovs-e1420df2.log`（18:20–18:24，換檔之前）是綠的。現在把 e1420df2 的樹用 `git archive` 匯出來跑，**同一格照樣紅**，head 上也一樣，兩者都在 `helper_env_evidence.ndtovs-98442add.log` 裡。
- 推論：併進 trunk 之後，兩份會一樣，這格就綠了。不影響這個分支的判定。

**最終 head `e1420df2`（第二輪）**

| log | 結果 |
|---|---|
| `test_ndt_ovs_claim.ndtovs-e1420df2.log` | `Ran 156 checks, 0 failed` |
| `mutate_ndt_ovs_claim.ndtovs-e1420df2.log` | `mutation gate: 35 mutations, 0 survived; 3 control(s), 0 went red` |
| `ndt_lab_suite.ndtovs-e1420df2.log`（26 支會碰 ndt 的 `tests/shell/test_*.sh`＝25 支既有＋新的） | `suite: 0 file(s) red` |
| `check_gate_anchors.ndtovs-e1420df2.log` | `117/117 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` |
| `static_checks.ndtovs-e1420df2.log` | `check_process_by_name: 321 file(s) scanned, 0 site(s), …`／`check_test_tmpdirs: 354 file(s) scanned, 0 fixed temp paths` |
| `test_teardown_guards.ndtovs-e1420df2.log`（F9） | `14 passed, 0 failed` |
| `test_ndt_lab_session.ndtovs-e1420df2.log`（F9） | `18 passed, 0 failed` |
| `mutate_ndt_down_claim_guard.ndtovs-e1420df2.log` | `mutation gate: 7 mutations, 0 survived; 1 control(s), 0 went red` |
| `mutate_ndt_up_down_robust.ndtovs-e1420df2.log` | `mutation gate: 106 mutations, 0 survived, 0 dead`（M68 在 log:98、M76 在 log:107 都 caught） |
| `mutate_ndt_status_check.ndtovs-e1420df2.log` | `mutation gate: 20 mutations, 0 survived` |
| `mutate_ndt_honesty.ndtovs-e1420df2.log` | `mutation gate: 67 mutations, 0 survived` |
| `mutate_ndt_helper_apps_window.ndtovs-e1420df2.log` | `mutation gate: 38 mutations, 0 survived` |
| `mutate_manual_rc_table.ndtovs-e1420df2.log` | `mutation gate: 10 mutations, 0 survived; 1 control(s), 0 went red` |
| `mutate_manual_no_stale_in_progress.ndtovs-e1420df2.log`（手冊有改） | `mutation gate: 16 mutations, 0 survived; 1 control(s), 0 went red` |
| `mutate_ndt_up_target.ndtovs-e1420df2.log` | `mutation gate: 8 mutations, 0 survived` |
| `mutate_ndt_app_package.ndtovs-e1420df2.log`（F9） | `mutation gate: 75 mutations, 0 survived; 4 control(s), 0 went red` |
| `mutate_ovs4_has_sflow.ndtovs-e1420df2.log`（F9） | `mutation gate: 24 mutations, 0 survived` |
| `serve_evidence.ndtovs-e1420df2.log`（唯讀取證，§2、§4） | `== verdict: merge-tree rc=0 conflicted-paths=0 anchors-bad=0 phrases-missing=0` |

`serve_evidence.first-run-rc2.ndtovs-e1420df2.log` 是同一支腳本的第一次執行，**rc 2 是我腳本本身的缺陷**：`ndt help` 一定回 2，而腳本最後一個指令就是那條 pipeline，又開了 pipefail。內容和重跑的那份一樣。已改名保留，尾巴附註說明。

新閘門 35 個變異，括號內是各自紅的格數（都紅在點名那一格，不是全紅）：
M1[46] M2[24] M3[33] M4[7] M5[6] M6[9] M7[10] M8[27] M9[10] M10[5] M11[2] M12[7] M13[6] M14[15] M15[8] M16[10] M17[1] M18[6] M19[2] M20[1] M21[5] M22[4] M23[3] M24[2] M25[4] M26[1] M27[2] M28[5] M29[2] M30[3] M31[1] M32[1] M33[4] M34[1] M35[1]（取自 `mutate_ndt_ovs_claim.ndtovs-e1420df2.log`）。

**中止與作廢的 log（照實記錄）**

- `mutate_ndt_ovs_claim.ndtovs-8b6f51f2.log`：中止，尾巴有 `# ABORTED` 註記。原因是發現手冊的來源註解要改。
- `54d2518a` 那批：
  - `static_checks` 是 **rc 1**：`check_test_tmpdirs` 把 `$FIX/tmp/instrument-probe` 讀成固定的 `/tmp` 路徑。
  - `mutate_ndt_up_down_robust` 被中止，有 `# ABORTED` 註記。
  - 其餘 7 份綠的仍留在原處。
- 兩次都是我用 `kill -TERM -<自己 setsid 那個 driver 的 pgid>` 停掉的，事先確認過 pgid 的 leader 的 cmdline 是我的 `all_gates.sh`。
- 第一輪：`check_gate_anchors.ndtovs-e684990f.log` 是 rc 1（M68 錨點不見），`6b7fce83` 修好。

---

## 4. OBSERVED（本 session 親自執行過的）

1. §3 表上的每一份 log。紅燈先行那份與最終 head 那一批，都經過 guard。
2. `serve_evidence.ndtovs-e1420df2.log`（腳本 `logs/gates-0910/scripts-ndtovs/serve_evidence.sh`，唯讀）：
   - `git merge-tree` 對 `feat/ndt-serve-0924` 沒有衝突；
   - `RC_SOURCE` 19 個 code 錨點新舊對照（`anchors not mapped/holding: 0`）；
   - `RC_SOURCE` help 11 句加上手冊 rc 表 5 句，全都在 `ndt help` 裡（`help phrases missing: 0`）。
3. 第一輪的「base 全綠」「手套 M68 得 421/424」「show.sh 的輸出」當時**沒有 log**，判官評為 UNDER-EVIDENCED，維持這個評價。M68 在第二輪 robust 閘門的 log 裡被抓到，那是有 log 的證據。
4. 手冊：
   - :512 起那段（原 :512–516，現在 :512–522）改成「09-25 起 `ndt down` 會清」，並說明怎麼判 stale、window 寫不進去就不刪、零寬照樣印 NO extent、`status` 標 STALE 但不紅；「在下一次 `ndt down` 之前」那句也補上。
   - 來源註解（原 :533，現在 :533–534）不再寫「待 Adam」。
   - claim 段（`NDT_OWNER` 段之後，現在從 :1070 起）新增 `ndt up` 在兩個平面都擋、`ndt up … --force`、overrides 檔的欄位、「那一行的意思是用了 --force，不是建起來了」、status 的 override 列、為什麼放獨立檔。
   - 手冊 rc 表（:156 起）引用的是 **5 句**，第一輪 §4.5 寫成三句是錯的。

## 5. INFERRED 與沒做的事

1. **`mutate_lab_claim_on_writes.sh` 沒跑。** 它會改 `src/ndt_core/http/HttpSession.cpp`，並用 ninja 編 C++ 測試 binary；本 worker 的規則是「永不 build C++，需要就停下來說」。它的錨點不在這個分支動到的檔案裡，`check_gate_anchors` 對它是 ok。它對應的 suite 是 C++／python contract，沒有在 `tests/shell` 裡。**要跑的話，需要 orchestrator 另外安排一個可以編 C++ 的 session。**
2. **F7（不處理）。** `app_spawn` 在 exec 之前約 1 ms 內，pidfile 已經寫了但 argv 還是 ndt 的。這時同一個 owner 並行跑 `down`，會把它判成 stale 並刪掉。影響低，判官也列為 note。
3. **F2 的邊界**：
   - 啟動時間讀不到時（例如 `/proc/<pid>/stat` 讀不了），不宣稱回收，照舊往下判。
   - 容許 2 s，照 stop_one。pidfile 寫下之後 2 s 內就被回收的號碼，會被當成原本那個程序。
4. 真機上 stack 的 stale pidfile（kernel／p4_proxy／ryu）在 `[1/3]` 仍由 stack.sh 清掉。ndt 自己的清理實際只會碰到 `app_*.pid`、其他不認得的名字，以及 stop_one 拒絕處理的回收號碼。
5. stack.sh 既有的缺口（不在範圍）：leader 死了但 group 還活時，`stop_one` 不送訊號就刪 pidfile。
6. `port_owner_local` 仍然把 stale 檔裡的號碼當成「ours」。robust 的 :274、:282、:1241–1282 仍種死 pid 來測 port 歸屬；日後修 `port_owner_local` 時，這幾格要一起改（判官 B）。
7. `ndt down --force` 仍然不寫紀錄，工單只要求 `up`。
8. live cells：`run_cells.sh` 會 export `NDT_OWNER` 並持有 claim，所以 OVS 格在自己的 claim 下不受影響。若有腳本在沒設 `NDT_OWNER` 的情況下跑 `ndt up ovs`，或是從帶有 `matrix.sh` 名字的 driver 底下跑，現在會拿到 5。
9. **已知限制：時鐘往前調超過 2 s，會讓啟動時間規則誤判健康的 stack pidfile（判官 r2 #2）。** btime 跟著往前跳，但 pidfile 的 mtime 不會動；結果是健康的 kernel／ryu／p4_proxy.pid 被判成回收的號碼：有 baseline 時 `--check` 回 1，`down` 會刪掉它（stop_one 同一條規則，本來就會拒絕停它）。修法是 supervise.sh 與 child 改用 argv 身分（stack.sh 的 stop_one 和 ndt 一起改）。**這一條由 orchestrator 另開工單處理（ticket to be opened by the orchestrator）；本分支沒動 stack.sh。**
10. 判官 r2 的 note 6：F1 的警語也會出現在 `app_stop` 正常停止時寫下的零寬 window（啟動與停止在同一秒），那時「nothing can date when X stopped」不精確，但無害。沒改。
11. 判官 r2 的 note 4 的後半：`app_stop` 自己的路徑在 window 寫不進去時仍會刪 pidfile（既有程式，這次沒改）。

---

## 6. 給 orchestrator 的 live 驗證步驟（併進 trunk 之後、在給定的 lab 時段內）

在 helper 所在的那棵樹（主 checkout）跑。每一步後面寫了預期結果，判讀方式在最後。

```bash
cd /home/adam/Desktop/NDTwin-Kernel
T=tools/test_workflow/ndt; ME=ovs-claim-live-0925; THEM=ovs-claim-foreign-0925
# 0. 基線與事先檢查；先 claim（動 lab 前 claim）
NDT_OWNER=$ME $T status | sed -n '/^lab/,/^$/p'          # claim none、measuring nothing
NDT_OWNER=$ME $T claim 15 'live: ovs claim check'
N0=$(grep -c . .test_run/lab.claim.overrides 2>/dev/null || echo 0)
ls -l .test_run/pids/                                     # 記下原本有什麼
test -e .test_run/pids/app_viz.pid  && echo 'STOP: a real app_viz.pid is there'
test -e .test_run/pids/app_viz.pgid && echo 'STOP: a real app_viz.pgid is there'   # 步驟 5 會一起刪掉它
test -e .test_run/apps/viz.window && cp -p .test_run/apps/viz.window /tmp/viz.window.ovs-live.bak
# 1. 量測在跑 ⇒ rc 5（用一個 argv 帶 matrix.sh 的無害 sleep，依 pid 收掉）
( exec -a matrix.sh-live-probe sleep 60 ) & MP=$!
NDT_OWNER=$ME $T up 4; echo "rc=$?"                       # 預期 rc=5，XX refusing to build: a measurement is running; … matrix.sh-live-probe 60
kill $MP; wait $MP 2>/dev/null
NDT_OWNER=$ME $T release                                  # 讓出來，步驟 2 要由 THEM 持有
# 2. 別人的 claim ⇒ rc 5，沒有 fabric
NDT_OWNER=$THEM $T claim 15 'live: foreign claim'
NDT_OWNER=$ME $T up 4; echo "rc=$?"                       # 預期 rc=5，XX refusing to build: the lab is claimed by ovs-claim-foreign-0925 …
NDT_OWNER=$ME $T status | grep -E 'bmv2 switches|host/switch|topo session|:8000 kernel'   # 0／0／absent／closed
ls .test_run/up.target                                    # No such file
grep -c . .test_run/lab.claim.overrides 2>/dev/null       # 仍是 N0
# 3. 覆寫 ⇒ 建起來，而且有紀錄
NDT_OWNER=$ME $T up 4 --force; echo "rc=$?"               # 預期不是 5（正常 0）；!! --force: building over the claim of ovs-claim-foreign-0925
tail -n1 .test_run/lab.claim.overrides | tr '\t' '\n'     # by=ME、over=THEM、command=ndt up 4 --force、at=…；共 10 行
# 4. 被蓋過的一方看得到
NDT_OWNER=$THEM $T status | grep -A2 '^  override'        # last --force: … -- ovs-claim-live-0925 over ovs-claim-foreign-0925 / ndt up 4 --force / N override(s) … USED …
# 5. 交還、自己 claim、down 兩次
NDT_OWNER=$THEM $T release
NDT_OWNER=$ME $T claim 15 'live: down twice'
NDT_OWNER=$ME $T down; echo "rc=$?"                       # 預期 0
NDT_OWNER=$ME $T down; echo "rc=$?"                       # 預期 3，'nothing was up to tear down'
# 6. 人工放一個死 pid 的 pidfile
( exit 0 ) & p=$!; wait $p; test -d /proc/$p && echo "pid $p reused -- pick again"
echo $p > .test_run/pids/app_viz.pid
NDT_OWNER=$ME $T status | grep -A1 'app pidfile'          # STALE -- .test_run/pids/app_viz.pid: pid $p gone
NDT_OWNER=$ME $T down; echo "rc=$?"                       # 預期 3；ok removed stale .test_run/pids/app_viz.pid -- pid $p gone
ls .test_run/pids/app_viz.pid                             # No such file
cat .test_run/apps/viz.window                             # start=end=<pidfile mtime>（沒有新的 viz log）、by=ME
# 7. 收尾：還原 viz.window（步驟 6 寫了一筆合成的零寬 window）
if [ -e /tmp/viz.window.ovs-live.bak ]; then cp -p /tmp/viz.window.ovs-live.bak .test_run/apps/viz.window; else rm -f .test_run/apps/viz.window; fi
NDT_OWNER=$ME $T release
# （選做）P4 迴歸：在別人的 claim 下 `ndt up p4 4` ⇒ rc 5，句子與 OVS 相同，knob 的 diff 不變
```

判讀方式：
- 1、2 任一步不是 5，或 `status` 顯示有任何 fabric ⇒ 守衛沒生效。
- 3 回 5，或 overrides 沒多一行 ⇒ 紀錄有問題。
- 4 看不到 override 列 ⇒ status 的列沒接上。
- 5 的第二次不是 3，或 6 的 `down` 不是 3、檔案沒被刪 ⇒ stale 判定有問題。
- 7 不做的話，會留下一筆合成的 viz window。

---

## 7. head

**`98442add`**（完整 `98442add6ed344a4e60c4346147f35c120a31e06`）
