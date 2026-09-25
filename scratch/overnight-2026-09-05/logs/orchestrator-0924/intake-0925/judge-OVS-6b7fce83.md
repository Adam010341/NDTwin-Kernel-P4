# opus-judge report on fix/ndt-ovs-claim-0925 @ 6b7fce83

**判決：MERGE AFTER FIXES**

裁決的主幹都成立，我逐條讀碼核過：兩個平面共用同一個守衛；守衛在 `up_ovs` 所有副作用之前；拒絕回 rc 5；`--force` 只能從 argv 進來，建之前先寫紀錄，寫不進去就 rc 5；stale 判定成立，`down` 會清掉並回 rc 3。gate log 的數字全部對得上。

擋住合併的是本次改動自己引入的一個回歸（F1）：`down` 清 stale app pidfile 時寫下零長度的 window 紀錄，之後的 residue 報告就不再印 G-12 的「NO extent」警語，而手冊 :508-511 明文承諾會印。另外有幾個 should-fix，都是小改。

範圍：全程唯讀，沒有執行任何東西，沒用 git。依指示讀了工單和 P4-HB §3，其他 audit 文件都沒讀。下文「已核」指我讀到的 code 或 log 原文；「推論」指我讀碼推出的執行期行為，沒有跑過。分支檔路徑是 `/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-ovs-claim-0925/`，下文簡寫為 `ndt:`、`test:`（指 `tests/shell/test_ndt_ovs_claim.sh`）。

## A. 正確性

- **守衛真的共用，位置也對（已核）**
  - `guard_up_lab_free` 在 ndt:996-1041。P4 在 ndt:3207 呼叫，OVS 在 ndt:4248 呼叫。兩個 up 函式裡都已經沒有 `foreign_claim`，舊的內嵌檢查拿掉了。
  - `up_ovs` 在守衛之前只有：local 變數、尺寸檢查（rc 2）、`topo_for_hosts`（唯讀的 python glob，ndt:2257-2294）、H4 檢查和缺模型檢查。`mktemp`／`mkfifo` 在 4256／4258，之後才是 preflight、`record_up_target`、knob、`claim_note_up`、stack.sh。
  - ndt 全檔沒有頂層副作用。建 fabric 的也只有這兩個 up 函式。

- **P4 行為與之前相同（已核）**
  - 守衛位置沒變（topo 之後、banner 之前），rc 5 的觸發條件也一樣。
  - 改變的只有三點：訊息改成多行並加上 `refusing to build:`；兩個原因同時成立時兩個都印；有別人的 claim 時也會先跑一次 `in_flight`（以前直接 short-circuit），rc 不受影響。
  - 主 checkout 的 ndt:3057-3063 確認了舊的內嵌版本，舊 `up_ovs` 裡沒有 claim 檢查。

- **環境變數打不開守衛（已核）**
  - `NDT_UP_FORCE` 在載入時（ndt:10332）和每次進 `up_take_app_flag`（10338）都會清空，只有 argv 裡的 `--force` 能設它（10350）。
  - `CLAIM` 是由 `REPO` 推出來的，不吃環境變數（341）。
  - ndt serve 的 `argv_up`（verbs.py:64-85）送不出 `--force`。

- **紀錄先寫、寫不進去就拒絕（已核）**
  - `claim_override_record` 在守衛裡、任何建置之前執行，寫完用 `grep -qxF` 整行讀回（1077-1080）。寫不進去就回 rc 5，並測到什麼都沒動（test §4、M10）。

- **stale 判定（部分已核，部分推論）**
  - app pidfile 用 pid 加逐個 argv 元素比對（`pid_is_app`，ndt:7332）；stack pidfile 只看號碼活不活（conservative）。
  - `down` 不會跳過任何一步：`DOWN_SUBJECT` 只影響 rc。`registry_clear_stale` 在 stack.sh `down` 之後才跑（5109）。
  - 問題見 F2、F8、F9。

## Findings

1. **[blocking] 零長度 window 讓 residue 報告失去 G-12 警語。**
   - 位置：ndt:4802-4805、9147-9163、7444、9730-9734（對比 9745-9753）。
   - 機制：`registry_clear_stale` 用 `app_window_seal` 算出右端。energy 沒有 log 管道，所以 window 一定是 [mtime, mtime]。SUMMARY §4.4 自己也看到 `viz.window` 的 `start=end`。
   - 推論：pidfile 刪掉之後，下一次 `status --check` 或 `apps orphans` 會走 `app_window_read` 那條路，`wwhy` 是空的，進 F3 分支。這條分支沒有 `(( wend == started ))` 警語，只印「window closed … from energy.window」，接著印 `ok no flow entry arrived during that window`。這正是 ndt:9722-9729 明文禁止的形狀。
   - ndt:4785 的註解說「報告讀到的 window 和讀檔時一樣」，數字上一樣，但呈現不一樣。rc 不變。
   - 修法：F3 分支加上同一段警語（或把 seal 的理由寫成 window 檔的 `why=` 欄再印出來）。加一格測試：死 pid 的 energy pidfile → `down` → residue 輸出必須含「NO extent」和「NOT 'this app left nothing'」；再加一個拿掉警語的變異。

2. **[should-fix] 被回收的號碼會被判成 `group`，不是 stale。**
   - 位置：ndt:4745-4769。`app_spawn` 只在 pgid==pid 時寫 `.pgid`（8602-8603），app 自己死掉時 `.pgid` 會留著。
   - 推論：Linux／POSIX 不會重新分配一個還被當 pgid 使用的號碼。所以 pid「活著但不是這個 app」時，原本的 group 早就結束了。如果回收這個號碼的程序本身是 group leader（互動 shell 的 job、daemon、setsid 起的程式都是），group 查得到成員，程式就判 `group`。
   - 後果：`status` 會用紅字印出自相矛盾的「is NOT stale -- … a recycled number, but its process group P still has live member(s): P」；`down` 保留這個檔，而且算 subject，已 down 的 lab 回 rc 0，也就是 09-14 的症狀又回來。
   - 方向是安全的（不殺東西、不刪活的紀錄），但裁決要求的 pid＋cmdline 身分比對在 group 這一步被繞過了。
   - test:506 的「陌生程序」沒用 setsid、也沒有 `.pgid`，所以測不到真實的形狀。
   - 修法：在「活著但不是 app」分支比較程序啟動時間和 pidfile 的 mtime（stack.sh 的 `stop_one` 已經用這個方法）。啟動得比 pidfile 晚 ⇒ 號碼被回收 ⇒ 直接判 stale。測試：用 setsid spawn 一個程序，`app_viz.pgid` 寫它的 pid，pidfile mtime 設在過去 ⇒ 必須 STALE；對照組：先 spawn 再寫 pidfile ⇒ 不是 stale。

3. **[should-fix] window 的右端沒有任何測試。**
   - test:529 只斷言 `start=`，變異閘門也沒有動 `end` 的變異。一個 `end=""`（等於寫成 now）的變異會存活。ndt:7391-7396 的註解說寫 `now` 會重新打開 RESIDUE-1 那個 12 小時的 window。
   - 修法：斷言 `end=1789365600`；加一個 app log 比 pidfile 新的變體（end 應等於 log 的 mtime）；加變異 M21。

4. **[should-fix] window 寫不進去照樣刪 pidfile。**
   - 位置：ndt:4804-4807，失敗只 `warn`，接著照樣 `rm`。這和它自己檔頭的理由（4780-4785：那個檔是 app 何時跑過的唯一紀錄）矛盾，也和 `--force`「寫不進去就不做」的原則不一致。
   - 修法：寫不進去就保留 pidfile，設 `rc=1` 並記 `not_verified`。

5. **[should-fix] help 有幾句不實（工單第 2 點要求 help 講實話）。**
   - ndt:10557「every use of it is one line」：沒東西可覆寫時 `--force` 不寫紀錄（1000）。
   - ndt:10604「Identity is pid plus argv」：只對 app pidfile 成立。
   - down 的 rc 1 清單（10585-10587）少了新的原因：stale pidfile 刪不掉（5109）。
   - clean 的 rc 3 help 仍寫「nothing in .test_run/pids/」，執行期的訊息已改成「nothing live in」（5389）。

6. **[note] 覆寫紀錄寫在後面那些拒絕之前。** 守衛（1031）先於 preflight（4266／3226）。teardown-in-flight、`mn_count`、H4 在紀錄寫完之後仍可能拒絕，所以紀錄的意思是「用過 `--force`」，不是「建成了」。應該寫進說明，或在紀錄裡加上結果。

7. **[note] app 啟動時的 race。** `app_spawn` 先刪 `.pgid`（8538），fork 後立刻寫 pidfile（8591），sleep 1 之後才寫 `.pgid`（8603）。exec 之前子程序的 argv 還是 ndt 的，這時同一個 owner 並行跑 `down` 會判它 stale 並刪掉。窗口不到 1 ms，影響低。

8. **[note] stack pidfile 的號碼被回收時**，程式一律當 live（4753），它算 subject，已 down 的 lab 回 rc 0 而不是 3。F2 的啟動時間檢查可以一併處理。

9. **[note] 閘門涵蓋範圍。**
   - 「26 支 suite」只涵蓋 `tests/shell`。`tools/test_workflow/test_teardown_guards.sh` 和 `test_ndt_lab_session.sh` 沒跑（推論：它們不碰改動到的程式）。
   - 這次改到的 `up_take_app_flag` 迴圈、`up_ovs`、claim note 各有既有變異閘門，但 `mutate_ndt_app_package.sh`、`mutate_ovs4_has_sflow.sh`、`mutate_lab_claim_on_writes.sh` 沒在 head 重跑。對應的測試 suite 是綠的，錨點也都 ok。

10. **[note] 證據本身的小瑕疵。**
    - f5b68399 的紅燈 log 寫著「dirty tracked at start: 1」，沒說是哪個檔，所以無法證明當時跑的是已 commit 的測試檔。
    - `touched()` 的 `tmp=` 欄從來沒有被證明量得到非零值。

11. **[note] live 步驟清單（SUMMARY §6）。**
    - 備份的 `viz.window` 沒有還原步驟。一旦跑完，會留下一筆合成的零長度 viz window，碰上 F1 就會印出沒有警語的報告。
    - 缺少事先檢查 `app_viz.pgid` 的步驟。
    - 建議加兩格：OVS 在 `in_flight` 下的拒絕；從 THEM 的角度看 `status` 的 override 列。

## B. robust 第 21 節改種 `$$`：合法，不是弱化

- 原格種的 992261 是 stale 條目。裁決把 stale 條目從 subject 移除，原格的前提正是被反轉的行為；維持原樣就是要求程式違反裁決。
- 格名和斷言都沒變，仍然釘住「活的 registry 條目是 subject」。變異 M76 在 head 仍由這一格抓到（robust log:106）。
- 反向（stale ⇒ rc 3）移到新 suite：§10（test:583，用 app_viz.pid）和 §9（dead kernel.pid 的 `down`）。原本「dead kernel.pid＋`clean`」的形狀沒有逐字保留，但判定函式是兩邊共用的，風險低。
- 992261 本來就不保證是死的號碼（pid_max 是 4194304），改用 `$$` 更穩。建議改用 spawn 出來的 sleep，這樣將來若有回歸開始對 registry 送訊號，打到的是 fixture 而不是 harness 本身。
- robust 的 :274、:282、:1241-1282 仍種死 pid 來測 port 歸屬。它們之所以還綠，是因為 `port_owner_local` 仍讀 stale 檔（SUMMARY §5.6）；日後修那裡時這幾格要一起改。

## C. 證據核對

| SUMMARY 的宣稱 | 分類 |
|---|---|
| 紅燈先行 70/107 → 73/109，ndt 未改（blob 3273df8b 與 diff 的 base 一致） | SUPPORTED。差 3 格＝新增 2 格＋128-host 模型補上後「reached nothing」轉紅 |
| 109/0；20 個變異 0 存活（含 M1-M3）；2 個對照組 | SUPPORTED。每個變異都紅在點名那格，紅的格數 1–36 不等，不是全紅 |
| 26 支 suite | SUPPORTED（是 25 支既有＋新 suite；orchestrator 說的「26 existing」多算一支） |
| anchors 117/117；新閘門 ok(23)（22 個變異，M12 有兩個錨點） | SUPPORTED |
| 7 個既有變異閘門；M68、M76 都被抓到（robust log:97、:106） | SUPPORTED |
| 12 份 6b7fce83 log 的第 1 行都是 `6b7fce837d9445e711faeb1c1a98438cdf8815ef`，都 `rc=0`，ndt blob 3a0e66c6 | SUPPORTED |
| serve 錨點的新行號 | SUPPORTED。19 行我都讀了，都含 needle 而且是同一個 return；舊行號與 verbs.py:263-270 一致 |
| 手動套 M68 得 421/424；§4.1 base 全綠；§4.4 show.sh 的輸出；merge-tree 乾淨 | UNDER-EVIDENCED（都沒有 log） |
| 「回收的號碼 ⇒ stale」 | 對真實形狀 CONTRADICTED（F2） |
| 「end 是 seal 的右端」 | 程式 SUPPORTED；測試 UNTESTED（F3） |
| ndt:4785「報告讀到的 window 一樣」 | 零長度時 CONTRADICTED（F1） |
| `--check` 的 rc 在任何情境都不變 | SUPPORTED（沒有新增 `problems+=`；10D 仍綠） |

## D. 兩個待裁決點

- **覆寫紀錄的位置：建議維持獨立檔 `.test_run/lab.claim.overrides`。**
  - 寫進 `lab.claim` 等於非持有者改寫別人的 claim，違反 `set_claim_note` 的規則，也會和持有者自己的 lock＋讀回協定搶同一個檔。
  - `ndt claim` 會重寫 claim、`release` 會把它改名（ndt:796-799、940），欄位活不過那個 claim，但「誰蓋過誰」是事後才問的。
  - 只因量測在跑而覆寫時，根本沒有 claim 可寫。
  - `ndt status` 對所有人無條件印 override 列（6501），被蓋的一方看得到；`claim_expires` 已經能唯一定位被蓋的那個 claim。
  - 只需補上手冊的說明。

- **stale 的 app pidfile 讓 `--check` 變紅：建議不要。**
  - seal 之後，死掉的 app pidfile 已經不會框住 fabric 的規則。
  - app 自己跑完退出是正常結局；stack 元件死掉才代表 lab 半壞，兩者語意不同。
  - 下一次 `down` 就清掉，是會自癒的狀態；讓 `--check` 在那之前一直紅，就是「一直紅的動詞沒人讀」。
  - 真的算 residue 的是 `group` 狀態（孤兒 JVM）。要讓它算 problem，得先修 F2，否則回收的號碼會把 `--check` 弄紅。

## E. rc／輸出變更表少了什麼

- `down` 之後 residue 報告的呈現改變（F1）。
- 已 down 的 lab 上跑 `down` 也會寫 `.test_run/apps/<app>.window`，而且會覆寫這個 app 舊的 window 紀錄。
- `down` 的「this teardown is about:」不再列出 stale 條目（4831-4834）。
- OVS 的 `up` 現在也會被 `in_flight` 的 argv 子字串比對擋下：任何 argv 含 `matrix.sh`／`measure.sh`／`cpu_probe.py` 的程序（例如編輯器或 `tail`），或當祖父程序的 driver。P4 本來就這樣，但 OVS 的呼叫者是第一次碰到。
- 「之前」欄不精確：舊版 `ndt up ovs --force` 和 `ndt up p4 --force` 都是 rc 2（4215-4221），不是「被忽略」。
- verbs.py:207 的註解引用的 ndt 行號（6493-6495、6128 等）合併後會過期。它們不是錨點，只是註解。
- 手冊：那句話在 :512，不是 :513；:513-516 要補「直到下一次 `ndt down`」；claim 段（:1059-1064）沒有提到 `ndt up … --force`、overrides 檔和 status 的 override 列。

## 報告沒跑、我會跑的測試

1. F2 的真實形狀：用 setsid 起的陌生程序＋`.pgid`＝它的 pid。
2. window 的右端，以及 app log 比 pidfile 新的變體。
3. `down` 之後對 energy 跑 residue 報告，確認警語還在。
4. window 寫不進去時，pidfile 必須保留。
5. symlink 和「自己的 group」這兩種 `unjudged` 情況，`down` 都不能刪。
6. 自己的 claim 帶 `measuring=` 時 `ndt up` 不被擋：SUMMARY 宣稱這個語意，但沒有測試也沒有變異。
7. 從 dispatch 一路跑到底的 `ndt up 4 --force`：目前重試行用的 `NDT_UP_WORDS` 從來沒被斷言過。
8. 拿掉讀回檢查的變異；claim note 裡含 TAB／換行時，紀錄仍然是 10 個欄位。
9. 在 head 重跑 F9 點名的三個閘門和那兩支不在 `tests/shell` 裡的測試。

## 報告內部不一致

- 表上「最後一行（原文）」其實是 gate 輸出的最後一行；每份 log 真正的最後一行都是 `# dirty tracked at end: 0`。
- §1.1 說 P4 傳入 `"p4 $hosts"`，程式實際傳 `"$up_what"`（3205-3207，含 `--app` 變體）。
- 手冊行號寫 :513，實際在 :512。
- §4.5 說手冊 rc 表引用「三句」，手冊 :163-167 實際引用五句。
- help 說「every use … is one line」，SUMMARY §1.2 說沒東西可覆寫時不寫紀錄。
- §2 表的「之前」欄對 `--force` 的描述不完整（見 E）。