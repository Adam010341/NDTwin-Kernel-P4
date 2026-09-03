# 修法：`ndt apps stop` 殺整個 process group，停止之後由獨立管道證實

[Co-developed with claude code -- Adam]

分支 `fix/apps-stop-kills-the-group`，基底 **`integrate/2026-09-03-auditor-merge @ 5c64d432`**
（含 g6／ports／sudo-surface／up-defaults）。**未 push。**

處理的缺陷：`FINDINGS-ALL.md` #6、#48；`WORK-ITEMS.md` W-2；
`doc/audit/2026-09-02_live-round/ADDENDUM-01-viz-orphan-contamination.md`；
`round3-restart-concurrency/14_viz_process_chain.log`。

---

## 1. 一句話

`app_spawn` 現在用 `setsid` 讓每個 app 成為自己的 session／process group，`app_stop` 殺**整個
group**，而「停掉了」這句話要先通過**兩個不看 pidfile、也不看 argv 的管道**（誰在那個 group 裡、
誰握著這個 app 的 log 的可寫 fd）才准印出來——那兩個管道正是 09-02 那兩顆 JVM 唯一逃不掉的。

---

## 2. 前後對照

### 2.1 機制

| | 前（base `5c64d432`） | 後 |
|---|---|---|
| `app_spawn` | `( cd D && exec nohup CMD ) &`：app 落在 **`ndt` 自己的 process group** | `( cd D && exec setsid nohup CMD ) &`，**啟動後讀 `/proc` 驗證** pgid==sid==pid，寫 `.test_run/pids/app_<name>.pgid` |
| `app_stop` 的訊號 | 對 pidfile 那**一個** pid 送 TERM | **先 `kill -TERM -<pgid>` 整個 group**、等、`KILL`；再補個別 pid；再補其他管道找到的殘存 |
| 「停掉了」的根據 | `pid_is_app` 對**同一個** pid 回 false | `app_verify_stopped`：group 掃描 ＋ log 的可寫 fd 持有者 ＋（有 port 的 app）`ss` 監聽者，三者皆空才印 |
| 「沒在跑」的根據 | pidfile ＋ argv 掃描 | 同上再加三個管道；**任何一個管道看不到，明說「不是沒有，是沒看到」** |
| `apps orphans` | 只認 `pidfile-lost-but-alive` | 再加「沒有 pidfile、argv 也沒有簽名，但還有子行程」 |
| app log | `>` 覆寫、一代 `.prev`、無上限、沒人報大小 | `>>` 附加、兩代（`.prev`／`.prev2`）、`status` 印大小、超過 256 MB 轉黃、`ndt apps trim` 就地截斷並留最後 1 MB |

### 2.2 實測（假 app，走真的 `app_spawn`／`app_stop`）

假 app 的形狀＝ 09-03 量到的形狀：一支帶簽名的 wrapper（`ndt` 記下來的就是它），
底下兩層 argv 不帶任何簽名的子孫，全部繼承同一個 log fd。
驅動腳本：`scratchpad/lab/run_case.sh`、`run_orphan_case.sh`（不進版控；閘門那份 fixture
另外還會關掉最深那層的 stdout，理由見第 3 節）。

**(a) 正常 stop**

| | 前 | 後 |
|---|---|---|
| app 的 pgid | `2329254` ＝ **`ndt` 自己的 pgid** | `2346273` ＝ app 自己（`ndt` 的是 `2346241`） |
| stop 的輸出 | `ok te stopped (was: running)` | `process group 2346273: empty` ＋ `ok te stopped (was: running) -- no process group, log writer or listener left` |
| `STOP_RC` | 0 | 0 |
| **stop 後殘留行程** | **2** | **0** |
| stop 後 log 還在長嗎 | **是**（4836 → 6864 bytes） | 否 |

**(b) #48 的狀態：wrapper 已死、pidfile 已失、子孫還在**

| | 前 | 後 |
|---|---|---|
| `ndt apps orphans` | `ok no untracked app processes`，**rc 0** | 指名 `te`、指名每個 pid、**指名是哪個管道找到的**，**rc 1** |
| `ndt apps stop te` | `te not running (no live instance found by pid or by scan)`，**rc 2** | `te has NO pidfile and NO process carrying its signature -- and these are still alive`，殺掉，**rc 0** |
| 殘留行程 | **2** | **0** |

**(c) 在這台機器現在的狀態上跑一次（唯讀，只 source 函式再指 `REPO` 到主工作樹）**

```
viz  -   log 363 MB -- over 256 MB; 'ndt apps trim viz'
sim  -   log 86 kB      te  -  log 16 kB      nsr  -  log 0 B
apps orphans -> ok no untracked app processes   (rc 0)
```

那個 363 MB 就是 W-2 記的 09-03 那一份 `app_viz.log`（現在還躺在
`/home/adam/Desktop/NDTwin-Kernel/.test_run/logs/`，旁邊還有 09-02 壓過的 `.gz` 23 MB）。
**這是對共用工作樹的唯讀觀測，沒有動它。** 修法前的 `ndt` 對這件事一個字都不會說。

### 2.3 🔴 對外行為改變（會被腳本或使用者看到）

1. **`ndt apps orphans` 對 09-02 那個狀態從 rc 0 變 rc 1。** 這正是修法的目的，但把它當閘門的
   腳本（`ndt apps orphans || exit 1`）在有孤兒的機器上會**開始擋**——以前不會。
2. **`ndt apps orphans` 多了 rc 2 ＝「找不到，但有管道看不到」**（例：機器沒有 `find`；或
   app 與呼叫端同一個 group ⇒ group 管道不可用）。非 0 ⇒ 既有的 `||` 閘門會擋，這是刻意的。
3. **`ndt apps stop` 在「訊號送了但東西還在」時回 1 並印出殘存者**；以前這種情況回 0。
4. **成功訊息換句話**：`ok <name> started (pid N, process group N)`、
   `ok <name> stopped (was: X) -- no process group, log writer or listener left`。
   有在 grep 這兩行的 harness 要對一下（`grep -qF "ok viz stopped"` 仍然命中；
   `grep -x` 或帶結尾錨點的比對會失效）。
5. **新檔案 `.test_run/pids/app_<name>.pgid`**。共用目錄裡多一種檔名，`app_*.pid` 的 glob 不會
   碰到它，但掃 `.test_run/pids/*` 的東西會看到。
6. **新子命令 `ndt apps trim [names|all]`**：就地 `truncate -s 0`，先把最後 1 MB 存成
   `app_<name>.log.tail`。**不是輪替**：app 握著那個 fd，`mv` 只會讓它繼續寫進被改名的檔案。
7. **`ndt apps status` 每個 app 多印一行 log 大小**（超過門檻轉黃）。門檻預設 256 MB，
   `NDT_APP_LOG_MAX_BYTES` 可蓋。
8. **app log 改用 `>>` 開，並保留兩代**（`.prev`、`.prev2`，理由同 `stack.sh` 的 `start_bg`）。

### 2.4 這個修法**不會**做的兩件事（刻意）

- **不對 `ndt` 自己的 group 送訊號。** app 若沒有自己的 session（舊版起的、或機器沒有 `setsid`），
  `app_kill_group` **拒絕**並說明理由，改走「能指名的 pid」＋ log fd 管道。
  一個會把呼叫它的 shell 一起殺掉的 stop 比原本的缺陷更糟。
- **不憑一個只存在於 `.pgid` 檔案的 group id 就送訊號**：空 group 的 id 會被系統回收，
  要有另一個管道也指到它的成員（例如它握著我們的 log）才動手。

---

## 3. 閘門證據

| 項目 | 值 |
|---|---|
| 測試 | `tests/shell/test_apps_stop_kills_the_group.sh` — **Ran 71 checks, 0 failed** |
| 🔴 對修法前的 `ndt`（base `5c64d432`）跑同一支測試 | **Ran 70 checks, 45 failed** |
| 變異閘 | `tests/shell/mutate_apps_stop_kills_the_group.sh` — **13 mutations, 0 survived** |
| baseline byte-identical | yes（閘門只寫 temp 目錄裡的副本） |
| `check_gate_anchors.py HEAD` 對這支閘門 | **`ok(12)`**（13 個變異、12 個相異錨點——M3 與 N4 同一行反向；工具數的是相異錨點。新閘門預設是「沒被檢查」，見 finding #28） |
| 鄰居套件（改動後重跑） | `test_ndt_app_orphans.sh` 52/52、`test_ndt_apps_liveness.sh` 44/44、`test_redirection_order.sh` **29 checks 0 failed**（原本 26）、`test_stop_one_targets_its_argument.sh` 5/5 |
| 鄰居閘門 | `mutate_redirection_order.sh` **20 mutations, 0 survived**（原本 17，新增三個對應我新增的三個 argv 站點） |

**這個修法一開始把兩支鄰居套件弄紅了，兩個都是真的**（不是測試太嚴）：

1. `test_ndt_app_orphans.sh` 釘住 `app_stop` 「沒在跑」那句話的**字面**。我把它從兩個證人
   改成四個 ⇒ 那個 check 紅。**它釘的是契約**：那句話要說出它看過哪些管道，而 09-02 印的
   正是舊那句（「pid 或 scan 都找不到」）——句子沒說謊，是**清單比 app 活下來的方式短**。
   已更新該 check 並把理由寫進測試裡。
2. `test_redirection_order.sh` 用 `cut -c1-80` 當唯一錨點來抽出 `apps_orphans` 那行 argv，
   而我新增的三個站點讓它變成**多重命中** ⇒ 那支測試**照設計拒絕**（它的註解裡就記著
   g6 上次做過同一件事）。已照它自己立的規矩處理：每個站點各自有唯一錨點、**三個新站點
   一併納入覆蓋**（26 → 29 checks），並在 `mutate_redirection_order.sh` 各補一個變異
   （17 → 20），因為「有測到但沒人變異」的站點等於沒被證明。

**兩面**。八個「把缺陷放回去」的變異：拿掉 `setsid`、stop 不殺 group、驗證永遠回 clean、
log 的 fd 不看可寫性、`orphans` 不看新管道、log 改回 `>` 開、「不見了」改用 `pid_is_app` 判
（那正是對 JVM 永遠回 true 的那個假成功）、拿掉「一個管道指到 199 個行程就是壞掉的管道」的護欄。
五個 (control) 是**放寬型**：對自己的 group 送訊號、對只有檔案為證的 group 送訊號、
一律不送訊號、驗證永遠說還在、每個 app 都報成孤兒。每一個都對到一個具名的 case。

**「殺掉整個 session 連 `ndt` 自己也殺」怎麼會被抓到**：那個 case 跑在自己的 session 裡
（`setsid bash helper`），由它去要求 `ndt` 殺自己的 group，然後回報「我還活著」。
放寬型變異會殺掉**那個 helper**，於是主測試看不到回報 ⇒ 該 case 變紅；
測試本身不會跟著死。（寫這支測試的過程中真的先自殺過一次：驅動腳本用 group 去列子孫，
而修法前的 app 就在驅動腳本自己的 group 裡，清理迴圈把測試自己殺了，exit 137。
那正是 `app_kill_group` 在產品裡拒絕的同一件事。）

**測試自己有兩道反向護欄，兩道都是被實測逼出來的**：

- 假 app 最深那一層會把繼承來的 stdout 關掉。沒有這一手，每個子孫都握著 log 的 fd，
  **光靠 log 管道就能全殺**，group 這條管道就沒有任何 case 在證明它。
- 假 app 的 depth-0 worker **收到 TERM 時會先交棒給一個新的子行程再死**。沒有這一手，
  「stop 不殺 group」這個變異**第一次跑就活下來了**（實測）：因為殘存者掃描已經把整棵樹列出來，
  逐 pid 殺也能把列出來的全殺掉。group 訊號真正多做的事，是覆蓋**清單拉出來之後才出生**的行程
  ——監督者重啟 worker、maven fork 下一顆 JVM 就是這個形狀。所以 M2 對到的 case 是
  **「app 的 process group 是空的」**，不是「那棵樹沒有殘存」：後者在變異下仍然是綠的。

**`check_gate_anchors.py` 當場抓到這支閘門自己的一個洞**：N3 的錨點原本橫跨兩行
（`kill -TERM "-$pgid"` ＋ 下一行的迴圈標頭），而我在那兩行中間補了一段註解之後，
那個錨點就變成 0 命中 ⇒ `mutant` 會**照樣交出一份沒有被變異的副本**、測試照樣綠、
閘門把 N3 記成「活下來」——一支安靜地什麼都沒在檢查的閘門，正是 finding #19 的形狀。
改成單行錨點後可讀。**錨點要小。**

**同一支工具對鄰居閘門的判讀，也試過改善但沒改成**：`mutate_redirection_order.sh` 有兩個
g6 時代的錨點寫成變數（`$A2`／`$A2b`），工具讀不到（`NOT checked`）。我新增的四個一律寫成
它讀得懂的 `$(printf …)` 形式；接著把那兩個舊的也一起轉過去——**結果工具對整支閘門抽出
零個錨點**（比原本的「兩個讀不到」更糟）。已把那兩個轉回變數形式，並在檔案裡記下為什麼
不要再轉。**這一格的狀態＝我來之前的樣子，沒有變好也沒有變壞；我加的四個是可讀的。**

**N4 第一版活了下來，而那是變異寫錯不是測試有洞**：它把 `app_verify_stopped` 迴圈裡的
`&& break` 拿掉，結果**只是讓驗證慢五秒**——迴圈下面那個判斷會重讀一次殘存者名單，答案照樣對。
**一個不改變任何可觀測行為的變異，本來就該活下來**；誠實的修法是去變異那個**判斷**本身
（`if (( ${#APP_SURVIVORS[@]} > 0 ))` → `if true`，與 M3 同一行、方向相反），
改完之後 `stop returns 0` 如預期變紅。

**閘門的 baseline 紅過一次，原因在測試自己身上**：假 app 的名字原本是固定字串，
而 `app_stop` 的 argv 掃描**照設計是全機器的** ⇒ **同一支測試的第二份**（閘門的下一個 mutant、
或有人手動再跑一次）本身就是一個帶著那個簽名的行程，兩邊會互相把對方的 fixture 停掉。
09-03 實測撞到：我在閘門跑的時候手動跑了一次，閘門的第二次 baseline 就紅了，
而且**紅的樣子跟被測缺陷一模一樣**（`the pidfile holds a live pid` FAILED）。
已改成 `ndt-groupfix-$$-launcher.sh`（帶本次 pid）。**在全機器的掃描裡用共用名字，
正是被修的那個碼犯的同一個錯，只是搬到儀器上。**

**寫這支修法時發現並修掉的兩個自造缺陷**（留在碼裡的註解有記）：
1. `app_recorded_pgid` 原本用全域旗標回報「這個 pgid 是從檔案來的」，而每個呼叫端都是
   `$(...)` ⇒ 旗標設在 subshell 裡、母 shell 永遠讀到初始值 ⇒ **那個 corroboration 護欄
   在所有情況下都是通過的**，等於沒有。改成把來源印在 stdout 上。
   形狀與 `test_ndt_app_orphans.sh` §3 記的 snapshot 計數器一模一樣。
2. `app_kill_group` 等待 group 清空的兩處重讀原本寫成 `|| break`／`|| return 0`——
   而那個函式的 rc 2 是「看不了」不是「空的」⇒ **「掃不到」會直接升級成對整個 group 送 KILL，
   然後回報成功**。那正是這支修法要拿掉的那個動作，被我寫進了拿掉它的那個函式裡。
   改成 `|| return 2`。

---

## 4. 合併順序與衝突（`git merge-tree` 實測）

- 對 **`integrate/2026-09-03-auditor-merge`（實測時已前進到 `eeda3cba`）**：
  `git merge-tree --write-tree --messages` **rc 0，無衝突**（`Auto-merging tools/test_workflow/ndt`）。
  🔴 **而且不只是「文字上不衝突」**：把 merge-tree 產生的那棵樹裡的 `ndt` 取出來
  （`git show <tree>:tools/test_workflow/ndt`），對**那一份**跑套件——
  **`test_apps_stop_kills_the_group.sh` 71/71、`test_redirection_order.sh` 29/29**，
  另外檢查了合併後沒有重複的函式定義（`grep -oE '^\w+\(\)' | uniq -d` 為空）。
  這是必要的：整合分支在我開工之後併進了 `fix/ovs4-has-sflow`，**它也改了 `ndt`**
  （新增 `verify_sflow`／`SFLOW_PORT`／`iface_ipv4`／`local_ipv4s`，位置與我的改動不重疊）。
- 對 **`fix/g6-ndt-apps-liveness`（`e83ef1d1`）**：rc 0，**且它已經整個併進整合分支**
  （`git merge-base --is-ancestor` 為真，`integrate..g6` 沒有任何 commit）。本修法就長在它上面：
  `app_probe`／三態／`app_wait_stopped`／rc 契約全部沿用，沒有重做；
  改動落在 g6 **沒有動的**那一段（`app_spawn` 的啟動鏈、`app_stop` 的訊號、以及驗證）。
- 對 `fix/ovs4-has-sflow`：rc 0，無衝突。
- 對 `t8-t10-fixes`：**有衝突，但不是這個修法造成的**。同樣六個檔案
  （`tools/test_workflow/ndt`、`ndtwin-lab`、四個 `2026-08-30_live-full-stack-round/harness/*`）
  在**整合分支對 `t8-t10-fixes`** 也一樣衝突；`ndt` 裡的衝突塊數量兩邊都是 **6**
  ⇒ 本分支沒有新增任何一塊。

**建議順序**：直接併進整合分支（快轉或一般 merge 皆可）。`t8-t10-fixes` 不論先後都要人處理它
自己那六塊。

---

## 5. 回退

- 單一 commit、六個檔案：`tools/test_workflow/ndt`、
  `tests/shell/test_apps_stop_kills_the_group.sh`（新）、
  `tests/shell/mutate_apps_stop_kills_the_group.sh`（新）、這份文件，
  加上兩支因為新增 argv 站點而要一起更新的鄰居：`tests/shell/test_redirection_order.sh`、
  `tests/shell/mutate_redirection_order.sh`（另加 `tests/shell/test_ndt_app_orphans.sh` 的一句話）。
  **六個一起 revert**——只回退 `ndt` 會讓那兩支鄰居紅（它們現在釘著新的站點）。
  `git revert -m 1 <merge>` 即可，沒有資料遷移、沒有格式變更需要回收。
- **不用整支回退的三個旋鈕**：
  - `NDT_APP_LOG_MAX_BYTES=<很大的數>` 讓 log 警告與 `trim` 閉嘴。
  - `NDT_APP_SURVIVOR_MAX=<很大的數>` 放寬「管道指到太多行程就當它壞掉」的護欄。
  - 機器上沒有 `setsid` 時，`app_spawn` 會**警告並照常啟動**，`app_stop` 自動退回舊的
    per-pid 行為（差別是它會說出來）。
- 殘留檔案：`app_<name>.pgid` 與 `app_<name>.log.tail`／`.prev2`。回退後沒有人讀它們，
  `rm` 掉即可，不影響舊碼。

---

## 6. 未處理

1. **log 沒有硬上限。** 交付的是：啟動時輪替兩代、`status` 印大小並在 256 MB 以上警告、
   `ndt apps trim` 就地截斷（留最後 1 MB）。**沒有做**的是「把 stdout 接到一個有上限的東西」
   （`rotatelogs`／`systemd-run` 的 journal）。理由是那會在 app 與它的 log 之間插進第二個行程：
   (a) 這個修法所倚賴的「誰握著 log 的可寫 fd」管道會改成指向那個中介，孤兒的 JVM 就只剩
   group 管道找得到；(b) 中介一死，app 會拿到 SIGPIPE。**代價**：無人看顧地跑兩小時，
   log 仍然可以長到幾百 MB——只是現在 `ndt status` 一問就看得到，而且 stop 真的會停。
2. **`energy`／`sim` 兩支走 `ndtwin-lab` 的 tmux，沒有 `.pgid`。** 它們的停止仍由 lab 的
   `<name>-stop` 負責，本修法只加了停止之後的獨立驗證（含 sim 的 `:9000`）。
   要讓它們也有自己的 group 得改 `ndtwin-lab`（root 端），不在這張工單裡。
3. **沒有在真 app 上跑過。** 全部證據來自假 app（形狀比照 09-03 量到的鏈）。
   viz 需要顯示器，不在 Adam 的桌面起它；真 app 的驗證留給下一次有實驗室的時段
   （`ndt apps start sim` 是最便宜的一個，它還能順便驗 `:9000` 那條管道）。
4. **`/proc/<pid>/cwd` 管道沒有做。** 工單允許「cwd 落在 app 目錄」或「log 的 fd 持有者」二選一，
   選了後者：cwd 會把「另一個終端機剛好 cd 在那個目錄」報成孤兒，而 fd 管道還能用
   `fdinfo` 的 flags 把唯讀的 `tail -f` 排除掉。**代價**：一個既不在 group 裡、又不握著
   log fd、argv 也沒有簽名的殘存行程，沒有任何管道找得到它（測試裡就有這一格：
   app 與呼叫端同一個 group 時，關掉 stdout 的那層子孫是找不到的）。
5. **`ndt down` 的 app 迴圈沒有改。** 它讀 `app_stop` 的 rc（0／1／2），語意沒變，
   自動吃到新的驗證；但它把 `app_stop` 的輸出丟到 `/dev/null`，所以**殘存者的名單只會出現在
   直接跑 `ndt apps stop` 的時候**。要在 teardown log 裡看到那份名單需要另外改（未做）。
6. **`ndt apps orphans` 的 rc 2 是新的**，`FINDINGS-ALL.md` #21／#22 那一族「呼叫端不讀 rc」
   的盤點沒有重做。誰在讀這個 rc、讀到 2 會怎樣，沒有查。
