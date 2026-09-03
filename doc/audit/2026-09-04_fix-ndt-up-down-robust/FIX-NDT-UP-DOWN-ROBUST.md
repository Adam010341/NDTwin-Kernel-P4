# FIX-NDT-UP-DOWN-ROBUST — `ndt up` 先拒絕再動手、失敗會回滾，`ndt down` 讀掃除的 rc 也等它做完

分支 `fix/ndt-up-down-robust`（從 `trunk` `47c6cb1a` 開出）。對應缺陷 **#3**、**#21**、**#49**，
以及 **#83 的碼那一半**。

> 本文引用的 `raw/<檔名>` 全部在 **`audit-raw` 分支**的
> `doc/audit/2026-09-04_fix-ndt-up-down-robust/raw/` 底下（這個目錄本身只放這一份 .md）。
> 讀法：`git show audit-raw:doc/audit/2026-09-04_fix-ndt-up-down-robust/raw/<檔名>`

---

## 0. 一句話

四條 finding 都長在同兩個指令上，而且是同一個形狀的四個實例：**知道的事情發生在來不及的地方**——
會擋住啟動的檢查放在 fabric 建好之後、掃除失敗的 rc 被丟掉、驗證在被驗的動作還沒做完時就下判決、
真正在跑的 helper 跟樹裡的那份差了五個 commit 而沒有任何管道會說。

---

## 1. 四條缺陷

### #3 失敗的 `ndt up ovs4` 不回滾

09-02 23:36 實測（`round1-ovs/02_ndt_up_failure_leaves_fabric_running.log`）：兄弟 session 的 kernel
在 `ndt up ovs4` 開跑前 4 秒佔住 `:8000`；`up` 照樣建了 Ryu（`:8080`／`:6653`／`:6633`）、tmux topo
session 與 15 個行程／36 條 veth 的資料平面，**然後**才由 `stack.sh` 的 `[3/3]` 拒絕：

```
[1/4] control plane (Ryu)      ok  Ryu up, prompt reached
[2/4] data plane (OVS fabric)  ok  15 host/switch processes after 2s
[3/4] proxy-less convergence + kernel
  XX  stack.sh up ovs exited 1
```

三分鐘後同一批行程還在。**兩個缺陷疊在一起**：那道拒絕跑在機器已經被改過之後，而且沒有任何東西
把改過的部分收回去。留下來的是一張沒有大腦的網路——下一個人接上的是這個 Ryu（ports.sh 的 `:6653`
那一列），或量到的是這座 fabric。

`preflight` 其實**已經**在動手前把每個被佔的 port 連同代價一起印出來了，然後就繼續往下走。
它是刻意做成勸告的，理由寫在原始註解裡：`ndt up` 在一座跑著的 stack 上會發現 `:8000`／`:6343`
被**自己的** kernel 佔著，硬失敗會讓重用路徑不能用；而「分辨自己的與別人的需要 pidfile 的
所有權判定，那個判定在 `stack.sh`」。⇒ 缺的從來不是拒絕，是**把那個判定搬到還不用付代價的位置**。

### #21 `cleanup` 的 rc 被丟掉，錯誤偽裝成 P4 的問題

`up_p4` 在「有 orphan bmv2、沒有 topo session」時呼叫 `sudo -n "$LAB" cleanup >/dev/null 2>&1`——
**輸出丟掉、rc 丟掉**——然後在活下來的東西上面建 fabric。orphan 佔住 `:3005x`（ports.sh 的
`30051-30060` 那一列），新 fabric 綁不上，使用者看到的是一個讀起來像 P4 pipeline 壞掉的錯誤。
`cmd_down` 的 `[3/3] sweep` 同型：走管線，`pipefail` 會把 rc 傳出來，而沒有人讀。

G-9 之前這是**看不見**而不是錯：舊 cleanup 每個 kill 都 `|| true`，結構上不可能回非 0，也沒有東西
可講。G-9 讓它會失敗、而且會指名活下來的那一個之後，兩半都變成真的損失。

### #49 `ndt down` 的 verify 與它要驗的 sweep 沒有同步

round3 `15_`：印 `XX bmv2 switches: 5 still running` 與 `not clean`，**20 秒後** `ps -eo comm=` 數到
**0**。teardown 沒有任何問題，是判決在機器還沒跟上的時候就下了。kill 是一個對核心的請求，不是一件
已經發生的事；而移掉 host namespace 的 `mn -c` 還會 fork 自己的小孩去做。

### #83 這台機器上跑的 helper 不是這棵樹裡的那份

`ndt:55` 寫死 `LAB=/usr/local/sbin/ndtwin-lab`——一份 root 擁有的**副本**。實測（本輪親自比對，
`raw/A_preflight_foreign_8000.log` 檔頭）：

```
/usr/local/sbin/ndtwin-lab        sha256 288b71cb…   (08-30, 0b6db9e3)
tools/test_workflow/ndtwin-lab    sha256 6685d3a9…   (trunk，已前進五個 commit)
```

⇒ G-9 的 `/proc` 掃除、G-7 的設定檔、ports 表、#77 的拓樸檔，**在這台機器上一次都沒有執行過**，
而 `status`／preflight／閘門**沒有一個**會比對這兩個檔或出聲。任何一份「走 `ndt up` 的 live 臂」
的報告，描述的都是當時裝著的那份 helper，而沒有一份指認過它的 sha。

---

## 2. 修法

### 2.1 #3 上半：所有權判定搬到 preflight，而且只對一種答案拒絕

新函式 `port_owner_local <port> [proto]`（`ndt:204`），三個答案：

| 答案 | 意思 | 動作 |
|---|---|---|
| `ours` | listener 的 pid **或它的行程群組**在**這個 checkout** 的 `.test_run/pids` 帳本裡 | 不拒絕（這就是重用路徑） |
| `foreign` | 我們**看得見**的 listener，而我們的帳本沒有一筆能解釋它 | **拒絕**，這就是 #3 |
| `unknown` | 完全看不到 listener 的 pid：socket 屬於別的使用者（bmv2 在 root 下跑，所以 `:3005x`／`:909x` 對我們永遠是這個），或機器沒有 `ss` | 不拒絕，但**明講看不到** |

🔴 `unknown` 不准折進另外兩個裡任何一個。折進 `foreign` 會拒絕掉**每一座活著的 P4 fabric**——
又是重用路徑，只是換一條路進來；折進 `ours` 就等於沒有這個檢查。這是 finding #7 的形狀（把
「沒權限問」翻成一個具體答案）在新碼裡的版本，變異閘的 M3 就是它。

「是不是我們的」的規則——pid 本身，或它的行程群組首——是 `stack.sh` 的 `port_owner_verdict`
已經在用的規則（`start_bg` 會 setsid、`stop_one` 送 `-$pid`）。**兩者刻意不共用同一個函式**：
`stack.sh` 自己定義了形狀不同的 `err`／`ok`／`warn`／`info`，在這裡 source 它會把整個腳本的輸出
悄悄改掉。取 pgid 用 `ndt` 自己的 `proc_pgid`（讀 `/proc/<pid>/stat`）而不是 `ps -o pgid=`，
理由是檔頭的 trap note 2。

🔴 **範圍，講明白免得有人被嚇到**：帳本是**每個 checkout 一份**（#79）。從主 checkout 起的 kernel
對 worktree 的 `ndt up` 就是 `foreign`。這不是新意見——`stack.sh` 會對同一個 socket 說 "not ours"
然後在 `[3/3]` 拒絕。**判決一樣，只是提早到 fabric 之前**。訊息本身就把這句話寫出來。

### 2.2 #3 下半：`rollback_up`，只收回**這一次**動過的東西

`UP_STARTED` 記錄本次 bring-up 走過的機器變更階段（`fabric`＝topo session 與資料平面；
`stack`＝`stack.sh` 起的 Ryu／proxy／kernel），失敗時**由新到舊**收回去，然後斷言。

🔴 **階段記在動手的呼叫之前，不是之後。** 一個做到一半才失敗的 verb 已經改過機器了，而這整件事
存在的理由正是「不知道它做到哪裡」。`topo-stop` 與 `cleanup` 都是冪等的，所以多回滾一個沒發生過的
步驟只花一行輸出；另一個方向的錯誤是一座沒有主人的活 fabric。

🔴 **三個「不要」，每一個都有測試釘住：**

1. **本次重用的 fabric 不掃。** `up_p4` 走重用路徑時不記 `fabric`；把它掃掉等於拿自己的失敗去拆
   別人的實驗室。（M8）
2. **已經起來、只是沒通過 verify 的 stack 不回滾。** `up` 對那個狀態已經有話講——
   `up, but not verified -- do not measure on this`——而那正是操作者最需要打開來看的狀態：
   kernel 在、graph 在、失敗的理由讀得出來。拆掉它是在回答沒有人問的問題。#3 講的是**做不完**的
   bring-up，不是做完了沒通過的。（M9）
3. **回滾不許假裝乾淨。** 收完之後 `wait_reaped` 有界地等一下，再斷言 topo session／bmv2／
   host-switch 三個計數；有剩就印 `rollback INCOMPLETE` 並指到 `ndt down --deep`。（M-fixture
   `an incomplete rollback says so`）

`.test_run/up.target` **刻意留著**（Adam 還沒裁 N15 Q3，照今天的行為走），並且明講留了：這一次
確實要求過一座 fabric，所以 `ndt status --check` 應該還有一個基準可以把剩下的東西判紅，而不是
回「could not check」。

### 2.3 #21：三個呼叫端都讀 rc，並指名活下來的那一個

`up_p4` 的 orphan 掃除、`cmd_down` 的 `[3/3] sweep`、以及新的 `rollback_up` 裡的掃除，
全部改成先收輸出、讀 rc、把輸出印出來，非 0 就出聲。`up_p4` 那個**拒絕往下建**並把仍被佔的 port
一起印出來；`cmd_down` 那個把 `down_rc` 設成 1。

`cmd_down` 的回傳值現在是**兩半的聯集**：`cmd_clean` 的判決，加上「掃除自己有沒有做完」。
兩者不是同一件事——`cleanup` 也掃 `cmd_clean` 不查的樣式（NTG 的拓樸就是一個），
所以「乾淨」與「掃除成功了」是兩個答案。

### 2.4 #49：`wait_reaped`，有界地等，然後照樣斷言

`ndt:1554`。先讀一次；兩個計數都 0 就直接回來（乾淨的機器不會被拖 20 秒）。否則每 0.5 秒重讀，
上限預設 20 秒（`NDT_REAP_WAIT`）。

🔴 **這是「等」，不是「等到綠為止」。** 上限到了就讓斷言照跑，對著真的還在那裡的東西下判決。
一個「等到機器看起來乾淨才停」的迴圈是 #49 反過來——把真的殘留報成乾淨的 teardown，**比它取代的
那個假紅嚴格更糟**。（M13 就是這個方向。）

🔴 **而且它會說它等了。** `waited 6.0s for 5 bmv2 + 14 host/switch process(es) to be reaped` 跟
`clean` 是兩句不同的話：第一句說了「掃除很慢」，而那正是原本看不見的那個事實。

🔴 **`cmd_clean` 自己不等。** `ndt clean` 是**可單獨呼叫的 teardown 斷言**，回答的是「這台機器
**現在**乾不乾淨」；給它 20 秒的等待就是在回答另一個問題。（M14）

🔴 **為什麼修在 `ndt` 這一側**（這不是偏好）：`ndt` 從 repo 跑，改完立刻生效；sweep 從
`/usr/local/sbin/ndtwin-lab` 跑，而這台機器上那份是 08-30 的副本，它的 cleanup 是四個
`pkill -f … || true` 加 `mn -c`，**完全不等**、而且結尾是無條件的 `echo "cleanup done"`
（見 §7.4）。修在 helper 裡要等有人 `sudo install` 才會執行。修在這裡兩種 helper 都有效。

### 2.5 #83：比對兩份 helper 的 sha256，三個地方出聲

`lab_version_verdict`（`ndt:774`）回 `same｜differs｜not-installed｜no-repo-copy` 加兩個 sha；
`lab_version_report` 負責怎麼講，`lab_version_problem` 給 `--check` 的問題清單一行。

出聲的三個地方：`ndt status` 的 `lab` 區塊（**兩份一樣時也印**，因為「它們一樣」正是讀 live 數字
的人需要、而且別處拿不到的事實）、`ndt status --check` 的問題清單（rc 1）、`ndt up` 的 preflight。

🔴 **preflight 只警告不拒絕**：要不要安裝是 Adam 的決定，一個「非得有人先打一行 sudo 才肯跑」的
bring-up 是比「跑舊 helper 但講清楚跑的是哪一份」更糟的失敗。（M17）

🔴 **這支腳本不安裝任何東西**，也**不讓 `LAB` 從環境覆寫**——理由是 `ndtwin-lab` 自己檔頭裡那一段：
它是 root 擁有、透過 NOPASSWD sudoers 呼叫的，讓呼叫端選 root 要跑什麼就是提權。

🔴 **「比不出來」不等於「一樣」。** 四個 verdict 裡只有 `same` 是綠的；缺檔與讀不到都會回報
（M16）。

---

## 3. 前後對照（逐字，同一台機器、同一個佔用者）

`raw/A_preflight_foreign_8000.log`。一個由本 session 起的 python 佔住 `:8000`（pid 2281646，
`ss` 看得見），兩份 `ndt` 各跑一次 `preflight ovs`：

**CONTROL（trunk `47c6cb1a` 的 ndt）**

```
  !!  ports already held before bring-up ...
  residue: python3 pid 2281646 holding :8000 (tcp)
           -> owner: the kernel's northbound API (ndtwin_kernel)
           -> if something else holds it: the next 'up' measures the stray kernel ...
RC=0                      <- 印完就往下建
```

**FIXED（本分支）**

```
  ... 同樣的 residue 段落 ...
  XX  refusing to build: a port this bring-up needs is held by a process that is
  XX  not part of this checkout's stack (nothing in .test_run/pids/ accounts for it).
  XX    :8000 (tcp) is held by python3 pid 2281646
  XX    refused HERE, before anything is built. stack.sh would refuse at its [3/3]
  XX    kernel step instead, and on 2026-09-02 that cost a whole Ryu, a topo session and
  XX    a 15-process data plane, left running with no kernel (finding #3).
RC=1
```

**另一個方向，同一台機器、同一個佔用者**：把那個 pid 寫進
`.test_run/pids/kernel.pid`（`start_bg` 本來就會寫的東西）之後重跑 ⇒ **`RC=0`**。
重用路徑沒有被打斷，而這正是舊註解在保護的東西。

---

## 4. 紅 → 綠

套件 `tests/shell/test_ndt_up_down_robust.sh`，**89 個 check**，全離線、fixture 驅動：
`ndt` 走它自己的 source seam 被 source 進來，`REPO`／`LAB`／`STACK` 指到暫存目錄，
`sudo` 與 `sleep` 是**這個 shell 裡的函式**（函式會遮蔽指令，所以兩者都不需要在產品裡開 seam），
`stack.sh` 換成一支會錄音、會照劇本回 exit code、而且會演 FIFO 協定的假腳本。
沒有實驗室、沒有 root、沒有 port、沒有網路。

**對 trunk 的 `ndt` 先看過紅**（`raw/red_trunk_ndt.log`，**39 passed, 50 failed**）。逐字節錄，
每組各取要害那幾條：

```
1. #3(a): the cheap refusals are decided BEFORE the machine is touched
  FAILED   🔴 a foreign holder of :8000 refuses the bring-up
             expected: [1]  actual: [0]
  FAILED     and says it is not this checkout's
             no match for 'not part of this checkout'

2. #3(b): a bring-up that fails after changing the machine takes it back down
  FAILED     and rolls back
             no match for 'rollback'
  FAILED     stops the topo session
             no match for 'topo-stop'
  FAILED   🔴 keeps .test_run/up.target on purpose
             no match for 'kept .test_run/up.target'

3. #21: cleanup's exit status is read, not thrown away
  FAILED   🔴 a failed orphan sweep refuses the bring-up
             expected: [1]  actual: [0]
  FAILED   🔴 and no fabric is started on top of it
             unexpected 'topo-start' in the output
  FAILED   🔴 'ndt down' is red when its sweep did not finish
             expected: [1]  actual: [0]

4. #49: the teardown verify waits for the sweep it is verifying
  FAILED   🔴 processes reaped just after the sweep are not a failure
             expected: [0]  actual: [1]
  FAILED     no false 'still running'
             unexpected 'bmv2 switches: 5 still running' in the output
  FAILED     and the bound is stated
             no match for 'not waiting further'

5. #83: the installed helper is compared with this tree's, and named
  FAILED   a differing helper is reported
             expected: [1]  actual: [127]        <- lab_version_report 在 trunk 上不存在
  FAILED   🔴 'ndt status --check' counts it as a problem
             expected: [1]  actual: [3]
```

**對本分支：89 passed, 0 failed**（`raw/green_branch_ndt.log`）。

那 39 條在 trunk 上就是綠的，是刻意留的**另一個方向**：重用路徑不被拒絕、看不見的佔用者不被
拒絕、P4 專用 port 不擋 OVS、verify 失敗不回滾、重用的 fabric 不被掃、`ndt clean` 不等。
它們在 trunk 上綠是對的——trunk 沒有做錯這些事，它只是什麼都沒做。

---

## 5. 變異閘門

`tests/shell/mutate_ndt_up_down_robust.sh`。**25 個變異，0 個活下來**
（`raw/mutation_gate.log`）。`check_gate_anchors.py HEAD --gates mutate_ndt_up_down_robust.sh`
回 **`ok(25)`**（`raw/gate_anchors.log`）。baseline byte-identical。

三種變異，因為「多檢查一點、多清理一點」有兩個看起來像修法的錯答案：

**M1–M17：把缺陷放回去，必須被抓到。**

| | 放回去的是什麼 | 必須變紅的 case |
|---|---|---|
| M1 | 所有權判定算完、印出來、不採取行動（trunk 的狀態，再往前一個 print） | 🔴 a foreign holder of :8000 refuses the bring-up |
| M2 | 判定塌成「看得見的都是我們的」 | 同上 |
| M3 | **看不見的佔用者當成 stray** ⇒ 拒絕每一座活的 P4 fabric | 🔴 a holder we cannot see is NOT refused |
| M4 | pid 帳本認不出自己的 listener ⇒ `ndt up` 拒絕自己 | 🔴 :8000 held by OUR OWN kernel is not a refusal |
| M5 | 忽略 plane 欄，OVS 開始因為 P4 的殘留而拒絕 | a P4-only port does not block an OVS bring-up |
| M6 | `stack.sh` kernel 步驟失敗後直接 return（09-02 那一晚） | and rolls back |
| M7 | **刪掉接線而不是碼**：`up_ovs` 不再記 `fabric` | stops the topo session |
| M8 | 🔴 反方向：`fabric` 記在重用分支之前 ⇒ **掃掉本次重用的 fabric** | 🔴 but does NOT sweep the fabric it reused |
| M9 | 🔴 另一個反方向：**verify 失敗也拆掉** | 🔴 and is NOT rolled back |
| M10 | `up_p4` 又把 orphan 掃除的 rc 丟掉 | 🔴 a failed orphan sweep refuses the bring-up |
| M11 | `ndt down` 不理沒做完的掃除 | 🔴 'ndt down' is red when its sweep did not finish |
| M12 | 判決又回到掃除的那一瞬間 | 🔴 processes reaped just after the sweep are not a failure |
| M13 | 🔴 **#49 反過來**：等待逾時就跳過斷言、回報乾淨 | 🔴 a process that never leaves is still RED |
| M14 | `ndt clean` 也開始等 | 🔴 'ndt clean' alone does not wait |
| M15 | helper 不一致印出來但不進 `--check` | 🔴 'ndt status --check' counts it as a problem |
| M16 | 「比不出來」被講成「一樣」 | 🔴 'could not compare' is not green |
| M17 | 🔴 preflight 因為 helper 不一致而**拒絕** | 🔴 preflight WARNS and does not refuse |

**N1–N4：widening——產品不再有鑑別力、對什麼都變綠**（preflight 什麼都不拒絕、回滾只印字、
`ndt down` 永遠 exit 0、helper 永遠說一樣）。每一個都能通過「在壞 fixture 上有沒有變紅」這種
只驗觸發的閘門，而每一個放回去的正是這四條 finding 講的那個性質：**一個沒有鑑別力、但長得像檢查
的檢查**。四個都被抓到。

**W1–W4：行為不變的改寫——套件必須維持綠。** 條件式換另一種寫法、`echo` 改 `printf`、
沒有任何斷言依賴的一句建議換句話說。這一類由第二個回報器 `report_green()` 記帳，期望相反：
在這裡變紅的套件是在讀實作的**字面**而不是它做的事，之後每一次改寫都會被它擋住而什麼也沒證明。
四個都維持綠。

---

## 6. 鄰居閘門與套件（都讀同一批檔案，循序跑）

`raw/neighbour_*.log`、`raw/neighbour_PROGRESS.txt`。

| | 結果 |
|---|---|
| `mutate_ndt_status_check.sh` | 12 mutations, 0 survived |
| `mutate_ndt_up_target.sh` | 8 mutations, 0 survived |
| `mutate_ports_that_block_restart.sh` | 9 mutations, 0 survived |
| `mutate_ndt_sudo_surface.sh` | 14 mutations, 0 survived |
| `mutate_redirection_order.sh` | 20 mutations, 0 survived |
| `mutate_ovs4_has_sflow.sh` | 24 mutations, 0 survived |
| `mutate_ndt_ovs_topo_script.sh` | 12 mutations, 9 caught, 3 widenings green, 0 survived |
| `mutate_apps_stop_kills_the_group.sh` | 13 mutations, 0 survived（跑了 20m17s，01:24:13→01:44:30） |
| `test_ndt_status_check_baseline.sh` | Ran 61 checks, 0 failed |
| `test_ndtwin_lab_sweep.sh` | Ran 29 checks, all passed |
| `test_ndtwin_lab_config.sh` | Ran 59 checks, all passed |

🔴 **我改了一個鄰居的測試檔，講清楚改了什麼**：`test_ndt_status_check_baseline.sh` 的 STUBS 加了
一行 `lab_version_verdict() { echo "same fixture-sha fixture-sha"; }`。#83 讓 `--check` 多比一件事，
而這台機器上兩份 helper**真的**不一樣 ⇒ 不釘住的話那支套件每一個「exits 0」的 case 都會因為 helper
變紅——那是一句真話，但**不是那支套件在講的那句**。helper 比對本身的雙向測試在本輪的新套件裡。

---

## 7. Live 證據

🔴 **先講邊界，因為它決定每一個 live 數字的意思：**

- 我改的 `ndt` 與 `stack.sh` 從 **repo** 跑，所以立刻生效。
- **走 `ndt up`／`ndt down` 的每一個 verb 跑的是安裝副本** `/usr/local/sbin/ndtwin-lab`，
  也就是 08-30 的 `288b71cb`。本輪**沒有安裝任何東西**。
- 安裝副本寫死 `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel`，所以 `ovs-topo-4host` 跑的是
  **主 checkout** 的 `ovs_4host_topo.py`，不是這個 worktree 的。

實驗室視窗：`ndt claim` **01:23:56** → `ndt release` **01:32:17**（約 8.5 分鐘，
`NDT_OWNER=ndtupdown`，claim 檔同步複製到主 checkout 並在 release 時移除）。
claim 前 `ndt status` 是 `claim none`／`measuring nothing`／所有 port closed。

### 7.1 Arm A — preflight 的成對對照（`raw/A_preflight_foreign_8000.log`）

見 §3。同一台機器、同一個佔用者，trunk `RC=0`、本分支 `RC=1`；把 pid 放進帳本後本分支 `RC=0`。
**這一組是 #3 上半唯一需要的 live 判定，而且不需要動實驗室。**

### 7.2 Arm B — 真的 `ndt up ovs4`（`raw/B_up_ovs4.log`）

從 worktree 跑，全綠：

```
[4/4] verify
  ok  kernel: 10 switches up+enabled
  ok  kernel graph matches the model file: 4 hosts, 40 edges
  ok  data plane: h1 -> 10.0.0.2 forwards
  ok  sFlow: 10/10 bridges sampling to :6343, 10 records
up. ready
```

意義：**新的 preflight 拒絕與回滾接線沒有把正常的 bring-up 弄壞**。

### 7.3 Arm C — 活 fabric 上的 `ndt status --check`（`raw/C_status_check_live.log`）

```
  !!  helper: /usr/local/sbin/ndtwin-lab is sha256 288b71cb, tools/test_workflow/ndtwin-lab is 6685d3a9
  !!    'ndt up' and 'ndt down' run the INSTALLED copy, so nothing merged into this
  !!    tree since it was installed has executed on this machine (finding #83).
  ...
check: 1 problem(s)
  - the installed /usr/local/sbin/ndtwin-lab (288b71cb) is not tools/test_workflow/ndtwin-lab (6685d3a9) -- 'ndt up'/'ndt down' run the installed copy
CHECK_RC=1
```

🔴 **一座健康的 fabric 上，`--check` 唯一報的問題就是 helper**——其他每一項都綠。這是 #83
最乾淨的 live 判定：一個真的、可行動的問題，而不是一堆雜訊。

（同一個 log 裡的 trunk 對照回 `COULD NOT CHECK`，但**那不是 #83 的對照**：trunk 的那份 `ndt`
放在 checkout 外面，`$REPO` 推導到別的地方所以找不到 up.target。#83 的對照是 Arm A——
trunk 的輸出裡**一個字都沒有提到 helper**。）

### 7.4 Arm D — `ndt down`（`raw/D_down.log`）：#49 的 live 是**陰性**，說清楚

teardown 全綠、`clean`，而 **`wait_reaped` 一行都沒有印**——代表它讀第一次時兩個計數就已經是 0，
等待沒有被觸發。這一臂**沒有重現 #49**，理由是結構性的，不是運氣：

- #49 量到的是 **5 個 bmv2**；`ovs4` 這座 fabric **一個 bmv2 都沒有**，慢的那一種行程不在場。
- 安裝副本（08-30）的 cleanup 是 `pkill -f … || true` × 4 加 `mn -c`，**不等**；本輪它把 15 個
  mininet 行程在 sweep 之內就收完了。

⇒ **#49 的鑑別力證據是離線套件**（`5 5 5 0` 這種讀數序列，trunk 紅、本分支綠，M12／M13 兩個方向
都被抓到）。這一臂只證明「加了等待沒有把乾淨的 teardown 弄壞」。

**#21 在這台機器上 live 不可判定**，而且理由要寫下來：安裝副本的 cleanup 每個 kill 都 `|| true`、
結尾無條件 `echo "cleanup done"`，**結構上只能回 0**。所以 #21 的修法在這台機器上直到有人
`sudo install` 之前**只能永遠說「掃除成功」**。這不是修法的問題，這是 #83。

### 7.5 Arm E — 回滾的 live 沒拿到（`raw/E_rollback_race.log`）

計畫是重現 09-02 那個競態：`ndt up ovs4` 開跑、等 22 秒（過了 preflight、在 `[1/4]`／`[2/4]` 之間）
再去搶 `:8000`，讓它走到 `stack.sh` 的 `[3/3]` 才失敗，看回滾。

**實際發生的事更有說服力，但不是我要的那件**：在那 22 秒裡，**一個兄弟 session** 起了
`fake_control_plane.py --port 8081 --port 8080 --wedge-all`（pid 2344945，01:28:44）與一個
`:6343/udp` 的 squatter（pid 2344979，同一秒），於是我的 `ndt up ovs4` **在 preflight 就拒絕了**——
對著一次**真實、非我安排**的碰撞：

```
  XX    :8080 (tcp) is held by python3 pid 2344945
  XX       should be: Ryu's REST API (ryu-manager)
  XX    :6343 (udp) is held by python3 pid 2344979
  XX       should be: the kernel's sFlow collector (FlowLinkUsageCollector, SFLOW_PORT)
```

機器**完全沒被動過**（`mininet-tagged: 0`、`:8080`／`:6653` 上沒有我的東西）。
兩位佔用者是兄弟的實驗器材，我**沒有碰它們**；我自己那個 `:8000` 佔用者按 pid 收掉了。
`:6343` 是 ports.sh 裡 `both` 的一列 ⇒ 在它被佔著的時候 OVS 與 P4 都起不來，
所以這個視窗裡**沒有辦法再取得回滾的 live 證據**。回滾的鑑別力證據是離線套件（M6／M7／M8／M9）。

### 7.6 沒有做的 live：P4 臂

沒跑，理由兩條，第二條本身值得記下來：

1. 慢的那支鄰居閘門（`mutate_apps_stop_kills_the_group.sh`）當時正在跑，在它底下起一座 bmv2
   fabric 會同時汙染兩邊。
2. 🔴 安裝副本寫死 `KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel` ⇒ 從 worktree 下 `ndt up p4`，
   **fabric 的主機數來自主 checkout 的 `host_count_override`，而模型來自 worktree 的那一份**。
   本輪實測兩邊分別是 `4` 與 `128`——**今天剛好可以跑，是因為 `ndt up p4 4` 會把 worktree 那份
   改成 4，於是兩個檔湊巧一致**，而沒有任何東西維持它們一致。這正是 FINDING-01 的形狀，
   而 #83 的寫死路徑是它在多 worktree 下的入口。

---

## 8. 合併

```
# base = 47c6cb1a；分支開出後 trunk 已前進到 1cf1556f
#   1cf1556f  A-12b: the OVS path forwards within a switch, not between switches
#   0581268e  Night rounds: dispatch fix/ndt-up-down-robust (...)
$ git merge-tree --write-tree trunk HEAD
cdd0a8166e54e2bd7c02e76335b37198914dca23
$ echo $?
0
```

**rc 0，輸出只有一個 tree oid ⇒ 對 `1cf1556f` 乾淨合併**（有衝突時 `merge-tree` 會回非 0
並在 oid 後面列出衝突檔）。

🔴 `git diff --stat trunk HEAD` 現在會顯示一堆**刪除**（`2026-09-04_a12-virtualbox-manual-run/`、
`NSLAB-USAGE-RULES.md`、`FINDINGS-COVERAGE.md`）——**那不是我刪的**，那是 trunk 在我開分支之後
前進了，所以 `trunk..HEAD` 的方向把新增看成刪除。要看我真的改了什麼請用 base：
`git diff --stat 47c6cb1a HEAD`。

我的 diff（對 base）只有四個檔：

```
 tests/shell/mutate_ndt_up_down_robust.sh      | 382 ++++
 tests/shell/test_ndt_status_check_baseline.sh |   7 +
 tests/shell/test_ndt_up_down_robust.sh        | 481 ++++
 tools/test_workflow/ndt                       | 443 +++-
 4 files changed, 1302 insertions(+), 11 deletions(-)
```

---

## 9. 我沒有做的事

1. **沒有安裝 helper。** `sudo install …` 是 Adam 的動作（N14 Q1）。本輪只是讓機器會說話。
2. **沒有讓 `LAB` 可以從環境覆寫**，理由是 `ndtwin-lab` 檔頭那一段（提權）。
3. **沒有碰 #79。** claim／pid 帳本仍然是 per-checkout；新的所有權判定**建立在**這個限制上，
   而且把它寫進拒絕訊息裡，這不是修它。
4. **沒有改 `ndtwin-lab`。** #49 修在 `ndt` 側，理由見 §2.4。
5. **沒有給 `ndt up` 加 `--force`。** 現在被 foreign 佔用擋住時，出路是訊息裡指的
   `ndt down`／`ndt down --deep`。要不要一個覆寫旗標是 Adam 的決定（見 §10 Q1）。
6. **`up_ovs` 那條「Ryu 90 秒沒到 prompt」的分支沒有離線覆蓋**：接線與其他兩條失敗分支一模一樣，
   但要跑滿 90 秒才會到，所以套件驗的是同一函式的另外兩條可達分支（`stack.sh exited early`
   與 `ovs-topo-4host failed`）。
7. **`app_stop` 失敗仍然不影響 `ndt down` 的 rc**（`err` 但不計入）。那是既有行為，不在本工單裡。

---

## 10. 給 Adam 的問題

1. **`ndt up` 被 foreign 佔用擋住時要不要一個覆寫旗標？** 現在沒有：訊息指到
   `ndt down`／`ndt down --deep`。加一個 `--force`（比照 `ndt down --force`）會讓「我知道那是誰的、
   我確定可以拆」變成一步；不加則保證沒有人能一鍵越過這道拒絕。**建議：先不加**，等有人真的被擋到
   而且那個擋是錯的，再談。
2. **`.test_run/up.target` 在失敗的 `ndt up` 之後要留還是清？**（N15 Q3）本輪照今天的行為**留著**
   並明講留了，理由是 `--check` 需要一個基準才能把殘留判紅。要改成清掉的話，`rollback_up` 裡
   加一行 `clear_up_target` 就好。
3. **helper 不一致要不要升級成 `ndt up` 的拒絕？** 現在只警告。**建議：維持警告**——但請注意，
   在你 `sudo install` 之前，**每一個走 `ndt up` 的 live 臂量的都是 08-30 的 helper**，
   而 `ndt status --check` 從現在起會因為這件事回 rc 1（其他都健康時，那會是唯一的問題）。
4. **`mutate_apps_stop_kills_the_group.sh` 之外，要不要把新閘門加進哪個彙總跑批？** 我沒有動任何
   彙總腳本（`local_ci.sh`／`l1_unit_tests.sh`）。

---

[Co-developed with claude code -- Adam]
