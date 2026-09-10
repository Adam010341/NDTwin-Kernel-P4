# G-9 — cleanup 用 `pkill -f`

> 🔴 **未重裝前，這支分支不改變任何實際行為。**
> `ndtwin-lab` 的 repo 副本與已安裝的 `/usr/local/sbin/ndtwin-lab` 原本 byte-identical，
> 改完之後不再相同，而**機器上跑的是已安裝的那份**。閘門全綠 ≠ 缺陷在這台機器上修好了。
> 重裝指令在 `doc/2026-09-02_ndtwin-lab-config.md`（G-7 分支）；
> **合併時要把「重裝並重新確認兩份 byte-identical」寫成一個步驟**——
> 那個「兩份逐位元相同」原本是個安全性質：它讓「我讀的是不是 root 會執行的那份」
> 有一個一秒鐘的答案。現在它破了，補回去之前它一直是破的。

分支 `fix/g9-cleanup-no-pkill-f`，base `6283ff5e19e6c6cee71ba6d04019bda936c90729`（trunk，2026-09-02 23:20）。

[Co-developed with claude code -- Adam]

---

## 1. 問題

`tools/test_workflow/ndtwin-lab` 的 `cleanup`：

```bash
pkill -f ntg_bmv2_topo.py 2>/dev/null || true
pkill -f p4_testbed_topo.py 2>/dev/null || true
pkill -f "Network-Traffic-Generator/testbed_topo.py" 2>/dev/null || true
mn -c >/dev/null 2>&1 || true
pkill -f simple_switch_grpc 2>/dev/null || true
```

`pkill -f` 拿 pattern 去比對**整台機器上每個行程的完整命令列**，然後對比中的通通送訊號。
三種失敗模式，這個 repo 三種都被咬過：

1. **它會打到搜尋者本身**，以及那個 shell、以及那個 shell 的祖先。
   一個會找到自己的守衛分不出「X 在跑」和「我正在找 X」。同樣的教訓寫在
   `lib_e.sh` 的 `foreign_iperf3_guard`、`ndt` 檔頭 trap note 1-2、`tools/p4_power_helper.py`。
   `sudo ndtwin-lab cleanup` 只要是在一個 argv 裡有那個字串的 shell 裡打的，那個 shell 就會被殺。
2. **它會打到「提到」的行程**：`echo restarting simple_switch_grpc`、
   `tail -f ntg_bmv2_topo.py.log`、開著那個檔的編輯器。
3. **送完訊號不驗證**：沒有人檢查比中的是不是本來要找的、有沒有真的死、
   那個 pid 在中間有沒有被回收成別人。

第 5 處同族：`ndtwin-lab:220` 的 `status` 用 `pgrep -c -f simple_switch_grpc`，
除上面三項外還多一個**計數專屬**的錯：`pgrep -c -f` 會把 pgrep 自己算進去，空機器報 1。
（auditor 已裁：同檔案同族，跟四個 `pkill -f` 同一個 commit。）

---

## 2. 修法

**`ps` 是索引，`/proc` 是權威，而且順序不能反。**
ps 的 `args` 欄是空白接起來的一整串，它分不出「一個 argv 元素」和「兩個」——
而修法的判準正好落在那個分別上。所以 ps 只用來產生候選清單，
清單建好之後才去讀 `/proc/<pid>/cmdline`（NUL 分隔，argv 元素可定址）。
中途已經結束的行程沒有 `/proc` 條目，自動掉出；pid 被回收成別人的，比對不過。

**身分的定義**（`sweep_matches`，這是與 `pkill -f` 的全部差別）：
某個 argv 元素的 basename **等於** pattern，或該元素以 `/pattern` **結尾**。

| 命令列 | `pkill -f` | 本修法 |
|---|---|---|
| `/usr/local/bin/simple_switch_grpc --name s1` | 殺 | 殺 ✅ |
| `python3 /home/adam/.../ntg_bmv2_topo.py` | 殺 | 殺 ✅ |
| `bash -c 'echo restarting simple_switch_grpc'` | **殺** ❌ | 不殺 ✅ |
| `tail -f /var/log/ntg_bmv2_topo.py.log` | **殺** ❌ | 不殺 ✅ |
| `vim notes-p4_testbed_topo.py.bak` | **殺** ❌ | 不殺 ✅ |
| `sudo ndtwin-lab cleanup`（打在有那個字的 shell 裡） | **殺掉那個 shell** ❌ | 不殺 ✅ |
| `python .../p4_proxy/mininet/testbed_topo.py`（另一支同名檔） | 殺 | 不殺 ✅（路徑後綴式） |

**自我排除的集合是「祖先鏈」，不是「行程群組」。**
`$$` 和 `$PPID` 不夠——pattern 在操作者往上好幾層的那個 shell 的 argv 裡。
但**不能用 pgid**：從同一個終端機起的 bmv2 交換機跟 cleanup 同群組，而它**是**要被收掉的目標；
排除整個群組會讓 cleanup 安靜地跳過它本來就是來收的那個 orphan。祖先永遠不是合法目標，
所以走 `/proc/<pid>/status` 的 `PPid` 往上走（有 64 層護欄）。

**送完訊號要回頭讀 `/proc`。** TERM → 等 → KILL → 再讀一次，然後逐 pid 印出
`stopped` 或 `STILL RUNNING`。

---

## 3. 行為變更前後對照（🔴 早上要看的部分）

| 情境 | 修法前 | 修法後 |
|---|---|---|
| `cleanup`，機器乾淨 | 靜默，印 `cleanup done` | 印四行 `none <label>`，再 `cleanup done` |
| `cleanup`，有一座 orphan 交換機 | 靜默，`cleanup done` | `stopped simple_switch_grpc pid 12345`，`cleanup done` |
| `cleanup`，有東西扛過 TERM＋KILL | **`cleanup done`，rc 0** | `STILL RUNNING ... `＋`cleanup INCOMPLETE`（stderr），**rc 1** |
| `cleanup`，操作者的 shell argv 含 pattern | **那個 shell 被殺** | 不受影響 |
| `cleanup`，旁邊有 `tail -f xxx.py.log` | **被殺** | 不受影響 |
| `ndtwin-lab status`，空機器 | `bmv2: 1`（算到 pgrep 自己） | `bmv2: 0` |
| 非 root 執行 | `die`（不變） | `die`（不變） |
| 被 `source` | 執行到 root guard 就 `die` | 定義完函式就 return（測試用的縫） |

🔴 **`cleanup` 現在會失敗。** 舊版每個 kill 都 `|| true`、最後一行無條件印，
所以它**不可能**回非 0。任何把 `ndtwin-lab cleanup` 當「一定成功」的呼叫端會第一次看到 rc 1——
那正是重點：扛過 TERM＋KILL 的 orphan 是唯一必須讓人知道的事。

🔴 **`cleanup` 仍然是全機器範圍的掃除。** 沒有縮小廣度：`cleanup` 的語意就是「把 lab 重置」，
別輪留下的 bmv2 交換機**就是**它該收的。改掉的是它不再能殺掉掃除者、殺掉一個「提及」、
或報告一台它從沒檢查過的乾淨機器。

🔴 **repo 內副本與已安裝的 `/usr/local/sbin/ndtwin-lab` 從此不同。**
兩者原本 byte-identical。**我沒有碰已安裝的那份**（那是提權路徑，且 auditor 明令不動）。
要生效必須有人**刻意**重新安裝：
```
sudo install -o root -g root -m 755 tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
```
在那之前，機器上跑的還是舊行為。**這個決定要 Adam 早上點頭。**
sudoers 規則不需要改（檔名、路徑、子命令集合都沒變；只多了 `cleanup` 的輸出與 rc）。

---

## 4. 變異閘門紅→綠

`tests/shell/mutate_g9_cleanup_no_pkill_f.sh`，六個變異各自把一種 `pkill -f` 的失敗模式放回去：

```
=== baseline (the fix, unmutated) ===
  rc=0  red=

=== mutations ===
  match-anywhere-in-line     caught by: an echo that MENTIONS a switch
  no-self-exclusion          caught by: and it does not find ITSELF
  self-is-only-this-pid      caught by: a matching ANCESTOR is not a candidate
  ps-is-the-authority        caught by: the real scan does not find the decoy
  count-includes-the-counter caught by: no switches, and we are looking -> 0
  kill-without-verifying     caught by: it names the pid it stopped
  control-comment-only       SURVIVED (control, as required)

restore: tools/test_workflow/ndtwin-lab is byte-identical to the pre-gate snapshot

VERDICT: every mutation was caught by the check named for it; the control survived
```

測試 `tests/shell/test_ndtwin_lab_sweep.sh`，29 checks 全綠。

**閘門抓到我自己兩個假綠**（寫在這裡，因為這是它有沒有在做事的證據）：

1. `no-self-exclusion` 一開始**存活**。原因：我注入的假 ps 行 args 欄沒帶 pattern，
   候選在 ps 預篩就被丟掉，根本沒走到自我排除那一行 ⇒ 拿掉那行也不會改變答案。
2. `self-is-only-this-pid` 一開始**存活**。原因：`bash -c '<單一簡單命令>'` 會**exec** 而不 fork，
   所以我那個「argv0 偽裝成交換機」的外層 shell 被內層取代，根本不存在一個「符合條件的祖先」。
   加 `; exit $?` 才擋掉那個最佳化。

兩個都是「檢查通過但不是因為程式對」。沒有閘門的話這兩條會以綠色交付。

---

## 5. 未處理（已辨識，今晚刻意不做）

🔴 **這一族裡最危險的兩個，都不在這支分支裡**（auditor 2026-09-02 裁決）：

- `p4_proxy/mininet/p4_testbed_topo.py:658` — `os.system('sudo pkill -f simple_switch_grpc > /dev/null 2>&1')`
- `p4_proxy/mininet/ntg_bmv2_topo.py:98` — 同一行

**為什麼是最危險的**：這兩個在**拓樸啟動路徑**上，而 `pkill -f simple_switch_grpc` 是
**全機器範圍**的——所以**一輪的拓樸啟動會殺掉另一輪正在用的 fabric**。
它們不是「可能誤殺」，是「設計上就會跨輪誤殺」。

**為什麼今晚不能改**：這兩個檔在**共用工作樹**裡，而整晚的測試輪一輪接一輪在執行它們。
改磁碟上那份＝在執行中換零件。字面上如此，不是比喻。→ 排明天。

**其他同族**：`tools/test_workflow/faults.sh:60`（註解）與 `:278`（印給使用者的建議指令）
在**本分支的另一個 commit**，可單獨回退。

**auditor 提到的「檔頭那兩行註解要更新」**：查過了，`ndt:44-45` 講的是 `ndt` **自己**的
計數器為什麼不用 pgrep（`bmv2_count` 用 `ps -eo comm=`），它描述的行為沒有消失，**不需要改**。
真正描述被移除行為的註解是 `cleanup` 區塊自己的那段，已隨修法改寫。

**待 live 驗證**（需要真 fabric）

🔴 **L2 是必要條件，不是加分項——先讀下面「這支分支還沒被真實資料驗過什麼」。**

- L1 真的跑一次 `sudo ndtwin-lab cleanup`，確認四行逐項輸出與 `cleanup done`。
- 🔴 **L2 起一座真的 bmv2，先 `tr '\0' ' ' < /proc/<pid>/cmdline` 印出它的完整 argv**，
  確認 `sweep_matches` 判得中（basename 或 `/pattern` 結尾），**再** cleanup，
  確認 `stopped simple_switch_grpc pid N` 且真的沒了。
  argv 要存進 audit-raw——它是這條修法唯一沒有被真實資料驗過的輸入。
- L3 `ndtwin-lab status` 對照 `ndt status` 的 `bmv2_count`，兩個數要一致。
- L4 旁邊開一個 `tail -f` 指到含 pattern 的檔名，cleanup 後確認它還活著。
- L5 同樣對 `ntg_bmv2_topo.py` 與 `p4_testbed_topo.py` 各做一次 L2。

### 🔴 這支分支還沒被真實資料驗過什麼（2026-09-03 03:30 自查）

套用今晚剛談出來的那條判準——**鑑別力測試只證明它對你測過的輸入有鑑別力；
若那些輸入抽自已涵蓋的集合，測試就照不出未涵蓋的部分**——回頭檢視我自己的測試：

**`sweep_matches` 的每一個測試輸入都是我自己發明的命令列**（fixture 的 argv0、
手寫的假 ps 行），**沒有一個抽自真的 bmv2／topology**。29 個 check 全綠證明的是
「它對我想像中的命令列有鑑別力」。

我在 03:25 對這台機器查了一次（唯讀），結果是 **bmv2 現在有 0 座**
（`ps -eo pid=,comm=` 數 `simple_switch_g` ＝ 0，`ndt` 的 `bmv2_count` ＝ 0，
我的 `sweep_count simple_switch_grpc` 也 ＝ 0，三者一致）——
**空機器上三個方法都回 0，這對「它認不認得真的 bmv2」零鑑別力。**

⇒ **風險具體化**：若真實的 `simple_switch_grpc` argv 形狀與我假設的不同
（例如被包在某個 wrapper 底下、或執行檔名帶版本後綴），`sweep_find` 會**安靜地找不到它**，
而 cleanup 會回報 `none simple_switch_grpc` ——
**一個報告乾淨的掃除，正是這支分支存在的理由所反對的那種輸出。**
L2 是唯一能關掉這個風險的檢查。

### 附帶：一個當場撞到的自我比中實例（03:25，唯讀）

查證的時候我自己寫了 `ps -eo args= | grep -c 'simple_switch_grpc'`，它回 **3**。
真實數量是 **0**——那 3 全部是**自我比中**（grep 自己的 argv、`bash -c` 包裝、管線）。
同一分鐘內，走 `comm` 的兩個方法都回 0。

這是 `pgrep -f`／`ps | grep` 那條的一個現場實例，而且是我**在寫這條修法的同時**踩到的。
`ndt` 檔頭 trap note 2 量到的是「10 座交換機報 11」；這次是「**0 座報 3**」——
比例上更糟，因為分母是零時，自我比中就是全部的答案。

## 6. 回退

兩個獨立 commit（sweep／faults.sh），各自 `git revert` 即可。
沒有資料格式改變。**已安裝的 `/usr/local/sbin/ndtwin-lab` 完全沒被動過，所以回退不需要重裝。**

---

## 附錄：`faults.sh` 的 `pgrep -f`（本分支第二個 commit，可單獨回退）

auditor 2026-09-02 裁決批准，理由是**紅線的重點不是 repo 裡有幾個字串，是這個做法會被傳出去**——
一行印在錯誤訊息裡的 `pgrep -f` 比程式碼裡的更會擴散。

原本兩處都在教使用者這樣組 `FAULTS_TC`（`:60` 註解、`:278` `err` 印出來的建議）：

```
FAULTS_TC="sudo -n mnexec -a $(pgrep -f '[t]estbed_topo.py'|head -1) tc"
```

`[t]` 括號技巧只擋掉「搜尋者比中自己」，擋不掉**執行它的那個 shell**（它的 argv 通常同時
帶著沒括號的形式——`ndt` 檔頭 trap note 2，量到 10 座交換機報 11）；`-f` 仍然會比中 log 路徑
或開著檔的編輯器；`| head -1` 在 `pipefail` 下是 2026-08-20 那個 SIGPIPE 陷阱。
而這個值是要交給 `mnexec -a` 的——**錯的 pid 不是錯的答案，是 root 跑進別人的 namespace**。

改成 `faults.sh --topo-pid`（新 `topo_pid()`）：ps 索引、/proc 權威、argv 元素要**是**那支
腳本；找到兩個就**拒絕並說出兩個 pid**，不猜。

行為變更：`--topo-pid` 是新子命令；`faults.sh` 的 usage 多一行。舊的兩個字串不再出現在
任何會被印出來的地方（測試直接斷言這件事）。

變異閘門 `tests/shell/mutate_g9_faults_topo_pid.sh`：

```
  match-anywhere-in-line     caught by: a log file named after it is not it
  head-1-picks-a-winner      caught by: two topologies -> refuses, rc 1
  empty-on-success           caught by: and it is the right pid
  advice-teaches-pgrep-again caught by: no pgrep -f inside anything it prints
  control-comment-only       SURVIVED (control, as required)
VERDICT: every mutation was caught by the check named for it; the control survived
```

測試 `tests/shell/test_faults_topo_pid.sh` 12 checks 全綠。
檔案裡還留著兩個 `pgrep -f` **字串**，都在解釋這條規則的註解裡——測試斷言的是
「沒有可執行行含它」與「沒有任何會被印出來的東西含它」，不是字元不准出現
（CLAUDE.md 自己就寫著這個字串）。

---

## 附錄二：`cleanup` 從「不可能失敗」變成「可能失敗」，呼叫端盤點

auditor 2026-09-03 要求：**一個從不失敗的東西開始會失敗，它的呼叫端就是新的風險面。**
下面是 repo 內全部呼叫點（`grep`，排除 `.git` 與其他 agent 的 worktree）。
**沒有動任何一個呼叫端**——這是清單，不是修法。

### 產品碼（`tools/`），兩處

| 位置 | 現況 | 新 rc 的影響 |
|---|---|---|
| `ndt:638` | `sudo -n "$LAB" cleanup >/dev/null 2>&1` | rc **完全丟棄**。這是 `up_p4` 在「有 orphan bmv2、沒有 topo session」時的先掃除。掃不乾淨（有東西扛過 TERM+KILL）現在**回 rc 1 而這裡看不到**，接著就在那個 orphan 上面建 fabric——而註解自己寫著 orphan 會佔住 `:3005x`、讓下一個 fabric 綁不上、錯誤訊息看起來像 P4 問題。**這是清單裡最值得修的一個**，但它是別人的碼，我只列。 |
| `ndt:1083` | `sudo -n "$LAB" cleanup 2>&1 \| sed 's/^/      /'` | `ndt` 是 `set -uo pipefail`（`:51`），所以管線的 rc 會變成 cleanup 的非零。但 `cmd_down` **沒有讀它**，下一行就繼續。行為上等同丟棄，只是丟棄的路徑不同。 |

### 測試輪／audit 腳本（`doc/`），六處以上

`matrix.sh:38`、`gate_d.sh:50`、`gate_e.sh:34`、`h_probe.sh:50`、`cal_c.sh:28`、`ladder_ext.sh:49`
以及兩份 `lib_e.sh` —— **全部是 `setsid $LAB cleanup ... || true`**。
`|| true` 是明示的忽略，所以不會壞掉；但它們現在會**明示地忽略一個真的失敗**。
要不要讓其中某些輪次對 rc 1 中止，是測試輪那邊的決定，不是這支分支的。

### 🔴 這支分支**沒有**修的那一半

KNOWN-ISSUES §G：「**`ndtwin-lab cleanup` 可能殺掉呼叫它的 shell**（內部跑 `mn -c`）。單獨一行跑。」
那是 `mn -c` **自己內部**的 `pkill -9 -f`（KNOWN-ISSUES §G 同一則），**不是** cleanup 的那四行。
我把 `mn -c` 原樣留著，所以：

- 上面那些腳本的 `setsid` 紀律**仍然必要**；
- 「cleanup 可能殺掉呼叫它的 shell」這條**沒有因為這支分支而解除**。

寫在這裡是因為兩者很容易被混為一談——今晚的 LEDGER 與 RECONCILIATION 都特別註明過它們是兩條不同的事。



---
---

<!-- merged 2026-09-03: the G-7 branch wrote its own RATIONALE.md; both kept, G-9 first -->

# G-7 — `ndtwin-lab` 寫死 Adam 的路徑

> 🔴 **未重裝前，這支分支不改變任何實際行為。**
> `ndtwin-lab` 的 repo 副本與已安裝的 `/usr/local/sbin/ndtwin-lab` 原本 byte-identical，
> 改完之後不再相同，而**機器上跑的是已安裝的那份**。閘門全綠 ≠ 缺陷在這台機器上修好了。
> 重裝指令在 `doc/2026-09-02_ndtwin-lab-config.md`；
> **合併時要把「重裝並重新確認兩份 byte-identical」寫成一個步驟**——
> 那個「兩份逐位元相同」原本是個安全性質：它讓「我讀的是不是 root 會執行的那份」
> 有一個一秒鐘的答案。現在它破了，補回去之前它一直是破的。

分支 `fix/g7-ndtwin-lab-config`，base `6283ff5e19e6c6cee71ba6d04019bda936c90729`（trunk，2026-09-02 23:20）。

[Co-developed with claude code -- Adam]

---

## 1. 問題（這不是 bug，是可攜性缺陷）

`KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel` 寫死，而且檔頭明講「**刻意**不可覆寫」。
代價已量測（2026-08-30，FINDING-01）：一輪把 kernel 釘在獨立 worktree 並 export `KERNEL_DIR`，
`ndt`／`stack.sh`／`components.env` 都讀到了，**這支腳本讀不到**——
於是 `topo-start` 起的是**主樹**的 `ntg_bmv2_topo.py` 與它的 128 台 host override，
而 `ndt up p4 4` 把 4 寫進 worktree 的副本、交給 kernel 一個 4-host 模型。
**Fabric 128、model 4、每一項結構檢查都綠，而且沒有任何一行輸出說了這件事。**

## 2. 修法與那 20 行檔頭的關係（🔴 這段要先讀，否則會以為我違反了它）

檔頭反對的是 **env override**，論證是：這支腳本 root-owned＋NOPASSWD sudoers，
`BRIDGE` 以 root 執行，所以讓環境選 `KERNEL_DIR` ＝ 讓任何以 adam 身分執行的東西
指定 root 要跑哪支 `.py`。**那個論證是對的，而且對設定檔一樣成立——只要那個設定檔誰都能寫。**

差別不在檔案格式，在**誰選、什麼時候選**：

| | 誰選 | 什麼時候 | 誰能做到 |
|---|---|---|---|
| env var | 呼叫者 | 每次呼叫 | 任何以 adam 身分跑的東西 |
| root-only 設定檔 | 機器管理者 | 安裝時一次 | 已經是 root 的人 |

所以本修法**不是**檔頭反對的那件事，而是它自己列的兩個出路
（「(a) 位置參數＋root-owned／allowlist 檢查」「(b) 每棵樹裝一份」）的第三種形狀。
檔頭已改寫，把這個區分寫進去。

🔑 **不要把它讀成比實際更安全。** 預設的 `/home/adam/Desktop/NDTwin-Kernel` **本來就是 adam 可寫**，
所以「root 執行 adam 可寫的 `.py`」今天已經成立。這次把**選哪棵樹**關進 root-only 的檔，
**沒有新增提權類別**；讓被執行的樹本身變 root-owned 是另一個決定，這次沒做。
（auditor 2026-09-02 同意此論證。）

## 3. 實作

三個述詞，不是一個——**因為變異閘門逼出來的**：

```
lab_conf_dir_trusted    目錄可不可信（先問）
lab_conf_file_trusted   檔案可不可信
lab_config_parse        內容說了什麼、可不可用
```

合成一個的話，**非 root 測試永遠碰不到檔案層的檢查**：目錄先判，而
「非 root 使用者可寫、同時又是 root 所有」的目錄**不存在**，所以
「受信任目錄裡的 adam-owned 檔」這個 fixture 造不出來。拆開才測得到，
閘門才能證明每一條各自會紅。（`no-owner-check` 與 `symlink-allowed` 兩個變異
一開始都**存活**，原因正是被目錄檢查擋在前面。）

**目錄先於檔案，這個順序本身就是檢查**（auditor 補的一條，正確）：
對目錄有寫權限＝可以把檔案整個換掉，那樣檔案層的檢查全部白做。
測試用「不存在的檔＋不可信目錄」把順序斷言起來，並有一個 `directory-checked-second` 變異守著它。

其餘：symlink 拒絕、**解析不 source**、只認四個鍵（未知鍵是錯誤）、絕對路徑、禁 `..`、
`KERNEL_DIR` 必須存在且含 bridge 腳本（**載入時**失敗，不是 root 建 fabric 建到一半才失敗）。

## 4. 行為變更前後對照（🔴 早上要看的）

| 情境 | 修法前 | 修法後 |
|---|---|---|
| 沒有 `/etc/ndtwin-lab.conf` | 用寫死的路徑 | **完全相同**（四個預設值逐字未動，測試逐一釘住） |
| 有一份 root-owned 0644 的設定檔 | 無此概念 | 生效 |
| 設定檔是 adam 所有／可寫 | — | **拒絕採用**，用內建預設，理由印在最顯眼處 |
| 設定檔所在目錄可被他人寫 | — | **拒絕採用**（先於檔案檢查） |
| 設定檔被拒時跑 `status`／`config` | — | **照跑**（唯讀），先印 🔴 拒絕理由＋`sudo rm` 的救援指令 |
| 設定檔被拒時跑任何會動東西的子命令 | — | **失敗關閉**，同樣印出理由與救援指令 |
| 設定檔是 symlink | — | 拒絕（rc 本來就會拒，見 §5；新增的是「說出理由」） |
| 設定檔有未知鍵／相對路徑／`..` | — | 拒絕，並指出行號 |
| `KERNEL_DIR` 底下沒有 bridge 腳本 | — | **載入時**拒絕 |
| `export KERNEL_DIR=...` | 無效（sudo env_reset） | **仍然無效**，且有測試釘住 |
| `ndtwin-lab status` | 只列 tmux sessions | 第一行多印來源與 `KERNEL_DIR` |
| `ndtwin-lab topo-start` | `topo session started` | 多印它是從哪棵樹起的 |
| `ndtwin-lab config` | 不存在 | 新子命令，印出五個實際生效的值 |
| 被 `source` | 執行到 root guard 就 `die` | 定義完函式就 return（測試用的縫） |

🔴 **repo 內副本與已安裝的 `/usr/local/sbin/ndtwin-lab` 從此不同。**
兩者原本 byte-identical。**我沒有碰已安裝的那份**（auditor 明令，且那是提權路徑）。
要生效必須有人刻意重裝（指令在 `doc/2026-09-02_ndtwin-lab-config.md`）。
**sudoers 不用改**：檔名、路徑不變，只多一個 `config` 子命令。

🔴 **與 G-9 衝突**：兩支都改 `tools/test_workflow/ndtwin-lab`，且本支從 trunk 長出去。
建議合併順序 **G-9 → G-7**（auditor 已同意），G-7 rebase。

## 5. 變異閘門紅→綠

`tests/shell/mutate_g7_ndtwin_lab_config.sh`：

```
=== baseline (the fix, unmutated) ===
  rc=0  red=

=== mutations ===
  no-directory-check         caught by:   but world-writable, so it is refused
  directory-checked-second   caught by: a bad directory refuses before the file
  no-owner-check             caught by: a file owned by this user is refused
  symlink-allowed            caught by:   and says it will not read the target
  source-instead-of-parse    caught by:   and was NOT executed
  unknown-key-ignored        caught by: unknown-key is refused
  no-bridge-validation       caught by: a KERNEL_DIR with no bridge script
  environment-gets-a-vote    caught by: an exported KERNEL_DIR is ignored
  default-tree-changed       caught by: KERNEL_DIR is the pre-G-7 default
  gate-locks-out-status      caught by: status still runs
  gate-lets-everything-run   caught by: topo-start does NOT
  no-restore-on-refusal      caught by:   a half-applied file leaves no residue
  refusal-is-silent          caught by: the refusal is announced
  no-removal-instructions    caught by:   and says how to remove the file
  control-comment-only       SURVIVED (control, as required)

restore: tools/test_workflow/ndtwin-lab is byte-identical to the pre-gate snapshot

VERDICT: every mutation was caught by the check named for it; the control survived
```

測試 `tests/shell/test_ndtwin_lab_config.sh`，59 checks 全綠。

**閘門在這一支抓到的四件事**（都是讀碼看不出來的）：

1. `no-owner-check`、`symlink-allowed` 兩個變異**存活**——被目錄檢查擋在前面，
   檔案層的斷言其實一條都沒被執行到。→ 拆成三個述詞。
2. `symlink-allowed` 改成拆分後仍然「紅在別的檢查」：**刪掉 symlink 拒絕，symlink 還是會被拒**，
   因為 `stat` 不解參考、報的是 link 本身，而 link 是 mode 777、被 group/other-writable 那條擋下。
   所以明確的 symlink 檢查**不改變 rc**，它買到的是「說出理由」＋擋住未來有人改成 `stat -L`。
   **斷言因此寫在訊息上，而且測試裡寫明了為什麼**——不是因為 rc 剛好不方便。
3. **09-03 改完之後**：`no-restore-on-refusal`（把還原那四行刪掉）**存活**。
   原因是我這個測試造得出來的檔**一定先被信任檢查擋下**，`lab_config_parse` 根本沒跑到，
   所以沒有東西需要還原 ⇒ 那條斷言不必還原存在也會過。
   改成先直接呼叫 `parse` 製造半套用、再讓 `load` 去收拾，才碰得到那段碼。
   （而那不是造作的形狀：它就是「load 執行時值已經不是預設」，
   也正是還原要讀 `LAB_DEFAULT_*` 而不是進入時快照的理由。）
4. 測試套件本身：`source ndtwin-lab` 會把 `set -e` 帶進測試，而一個題材就是「故意觸發失敗」的套件
   在 errexit 下**會中途離開卻仍然把已跑過的每一條印成 `ok`**——看起來像通過，只是提早結束。
   （實測：停在「and it says what is missing」，連結尾的 `Ran N checks` 都沒有。）已 `set +e`。

## 6. 風險與回退

**風險**

1. `status` 與 `topo-start` 的輸出多了一行／一段。有 script 在 parse 這兩個輸出的話會受影響。
   repo 內盤點過兩個消費者，**都親自跑過**：
   - `ndt` 的 `lab_session`（`tools/test_workflow/ndt:411`）比對 `*$'\n'"$1":*`。
     `tools/test_workflow/test_ndt_lab_session.sh` 宣稱涵蓋「`ndtwin-lab status` 能產生的每一種
     形狀」，我加了新形狀進去（4 條，18 passed）——**不加的話那句宣稱就變成假的**。
     其中一條是這條修法新造出來的 near-miss：`KERNEL_DIR` 裡剛好含 `topo:` 的路徑。
   - `lib_e.sh:749` 輪詢 `'bmv2: 10'`（子字串比對，不受首行影響）。
2. `config` 是新子命令，舊的 usage 字串改了。
3. ~~設定檔一旦不可信就整支失敗（連 `status` 都不能用）。~~
   **2026-09-03 依 auditor 裁決改掉一半。** 方向保留——**會動東西的子命令一律失敗關閉**，
   因為不可信的檔不該決定 root 跑哪棵樹。但 `status` 與 `config` 是**唯讀**的，而且正是
   打錯一個字之後你會用來搞清楚發生什麼事的那兩個命令；把它們一起鎖掉，
   等於讓救援路徑只剩「已經知道要 `sudo rm /etc/ndtwin-lab.conf`」，
   不知道的人會以為 lab 壞了。

   現在：拒絕的是**採用那個設定檔**，不是執行。內建預設留在原位，
   `LAB_CONF_ERROR` 記下理由，`lab_conf_gate` 在任何子命令之前把理由（含檔案路徑與
   `sudo rm` 指令）印到 stderr，然後唯讀的放行、其餘的 `die`。
   這不弱化安全性：`status` 不碰任何東西，而「拒絕採用」比「不能執行」提供更多資訊。

   🔑 **還原不是整潔問題**：`lab_config_parse` 是邊讀邊賦值的，所以第三行壞掉的檔
   已經套用了前兩行——**半套用的設定比檔案或預設都糟，因為它對不上任何人寫下來的東西**。
   還原讀的是 `LAB_DEFAULT_*` 而不是「進入 load 時的值」，因為後者只在 load 只被呼叫一次時
   才等價，而那正是這個 repo 一直在付錢的那種假設。
4. 新的 sourced-guard 讓這個檔可以被 `source`。sudo 一律 exec 不 source，所以已安裝路徑不受影響。

**待 live 驗證**（需要 root／真 lab，claim 在 auditor 手上）

- L1 `sudo ndtwin-lab config` 在**沒有**設定檔時印出四個預設值。
- L2 裝一份指向 worktree 的設定檔，`config` 與 `topo-start` 都要顯示那棵樹。
- L3 故意裝一份 adam-owned 的，確認被拒絕且訊息說得出理由。
- L4 重現 FINDING-01 的情境：worktree 128／主樹 4，確認現在**看得見**是哪棵樹。

**回退**：單一 commit，`git revert`。已安裝的 `/usr/local/sbin/ndtwin-lab` 沒被動過，
所以回退不需要重裝、也不需要碰 sudoers。


---
---

<!-- merged 2026-09-03: the G-6 branch wrote its own RATIONALE.md; appended -->

# G-6 — `ndt apps` liveness is a claim, not a measurement

分支 `fix/g6-ndt-apps-liveness`，base `6283ff5e19e6c6cee71ba6d04019bda936c90729`（trunk，2026-09-02 23:20）。

[Co-developed with claude code -- Adam]

---

## 1. 問題

兩個病灶，證據都是今晚 live round 的 raw：

**① start 讀的是「請求被接受」，不是「程式活著」**
（`doc/audit/2026-09-02_live-round/raw/C26_apps_stop_falseok.log`）

```
energy) sudo -n "$LAB" energy-start >/dev/null && ok "energy started (tmux: energy)" ;;
sim)    sudo -n "$LAB" sim-start    >/dev/null && ok "sim started (tmux: sim)" ;;
```

`&&` 讀的是 `ndtwin-lab <name>-start` 的 rc，而那個子命令是
`tmux new-session -d ... ; echo` —— tmux 對「我建好一個 session 了」回 0，對「那個程式一秒後
還在不在」什麼都沒說。C26 把兩條路徑並排跑出來的對照就是這件事：

```
te  (app_spawn) -> 'XX te exited immediately', rc=1   <- honest
sim (tmux)      -> 'ok sim started (tmux: sim)', rc=0  <- true here ONLY because the
                    binary exists on this machine; the check itself cannot tell.
```

`app_spawn`（nsr/viz/te）從 08-20 起就有 `sleep 1; kill -0`。兩個 lab app 沒有。

**② stop 對從來沒啟動過的東西回報成功**
（同上，加 `D1_teardown.log`）

```
energy) sudo -n "$LAB" energy-stop >/dev/null 2>&1; ok "energy stopped" ;;
sim)    sudo -n "$LAB" sim-stop    >/dev/null 2>&1; ok "sim stopped" ;;
```

注意是 `;` 不是 `&&`：rc 不是沒檢查，是被丟掉了，`ok` 無條件印。
nsr/viz/te 那條路徑的**話**從 08-31 起就誠實了（`te not running (no live instance found...)`），
**退出碼**沒有——仍然是 0。所以 D1 的 teardown 五個 app 停了三個、兩個從來沒起來過，
`APPS_STOP_ALL_RC=0`，跟五個全停的 teardown 給出同一個碼。

**③（修的時候才看見的第三件事）** 舊 `app_probe` 對 energy/sim 的註解寫著
「lab_session is the witness and there is nothing for a /proc scan to add」。兩半都不成立，
而且錯的方向相反：session 存在不代表程式活著（①），程式活著也不代表有 session——
**手動在 lab socket 外面起的 energy 會把交換機關掉**，而舊碼對它回答「not running」。
這是 pidfile 那批 app 曾經有過的同一種盲點，只是換了個witness。

---

## 2. 修法

`tools/test_workflow/ndt`，六處：

| 位置 | 改動 |
|---|---|
| `app_sig` | energy/sim 有了 signature（`energy_saving_app`／`simulation_platform_manager`），/proc 掃描才問得出「它在不在」 |
| `app_probe` | energy/sim 改成**兩個 witness**：session 說「lab 有沒有起過它」，掃描說「它在不在」，兩個合起來才決定狀態 |
| `app_wait_started`（新） | 起完輪詢最多 5s，直到掃描真的看見它；看不見就說為什麼（含「session 在、裡面沒東西」） |
| `app_wait_stopped`（新） | 停完輪詢，直到沒有東西帶著那個 signature；還在就列 pid、說 lab 停的是 session、交給人 |
| `app_start` / `app_stop` energy\|sim | 走上面兩個 helper；`ok` 只在驗過之後印 |
| `app_stop` / `cmd_apps stop` | 退出碼從兩種變三種 |

狀態機（energy/sim）：

| lab session | /proc 掃描 | 狀態 | 舊碼 |
|---|---|---|---|
| 有 | 有 | `running` | `running` ✅ |
| 有 | 無 | `not-running` + `APP_SESSION_WITHOUT_PROCESS=1` | `running` ❌ ←C26 |
| 無 | 有 | `pidfile-lost-but-alive`（orphan） | `not-running` ❌ |
| 無 | 無 | `not-running` | `not-running` ✅ |

`APP_SESSION_WITHOUT_PROCESS` 是掛在 `not-running` 上的**理由**，不是第四種狀態：
只問「起來了沒」的呼叫端繼續讀 `APP_STATE`，不必學新字。

---

## 3. 行為變更前後對照（🔴 這是要 Adam 早上看的部分）

| 情境 | 修法前 | 修法後 |
|---|---|---|
| `ndt apps sim`，binary 不存在／秒死 | `ok sim started (tmux: sim)`，rc 0 | `XX sim did not start` ＋「session 在、裡面沒東西」＋指向 `sim-out`，**rc 1** |
| `ndt apps stop sim`，從沒起過 | `ok sim stopped`，rc 0 | `sim not running (no live process carries its signature)`，**rc 2** |
| `ndt apps stop te`，沒在跑 | `te not running`，**rc 0** | 同樣的話，**rc 2** |
| `ndt apps stop all`，整台機器閒置 | rc 0 | **rc 2**＋`nothing to stop (5 app(s) were already not running)` |
| `ndt apps stop all`，五個裡有一個在跑 | rc 0 | rc 0＋`stopped 1; 4 were already not running` |
| energy 在 lab session 外面跑著 | `ndt apps` 顯示 `-`；`stop` 回 `ok energy stopped` rc 0 | `apps_status` 顯示 `ORPHAN`；`stop` 印 STILL RUNNING、列 pid、**rc 1** |
| `ndt down` | 同上的假 ok | rc 2 認成 `$a had already exited`，不是失敗 |

**退出碼契約**（寫進 `app_stop` 檔頭）：

```
0  它在跑，現在不跑了
2  沒有東西可停 —— 由掃描證實，不是從「沒有 pidfile」推論的
1  停不掉／pidfile 被下毒／不認識這個 app
```

🔴 **對既有 script 的影響**：把「非 0 就是失敗」的呼叫端會把 rc 2 看成失敗。
repo 內只有 `ndt down` 是這種寫法，已改成只把 rc 1 當失敗（見表末列）。
repo 外的 driver script（例如產生 `APPS_STOP_ALL_RC` 的那支）**要 Adam 決定**是改讀
`rc != 1`，還是就讓它看見 rc 2——後者其實是這次修法的重點：那個 0 本來就不該是 0。

---

## 4. 變異閘門紅→綠

`tests/shell/mutate_g6_apps_liveness.sh`，五個變異各自把**修法前的原文**放回去，
跑套件，記錄**是哪一個具名檢查**變紅（不是「有東西紅了」）：

```
=== baseline (the fix, unmutated) ===
  rc=0  red=

=== mutations ===
  start-reads-request-rc     caught by: start of an app that never came up -> rc 1
  stop-unconditional-ok      caught by: stop of a never-started lab app -> rc 2
  probe-session-only         caught by: session up + NO process     -> not-running
  notrunning-rc-zero         caught by: stop of a never-started pidfile app -> rc 2
  aggregate-or-rc1           caught by: nothing was running -> rc 2
  control-comment-only       SURVIVED (control, as required)

restore: tools/test_workflow/ndt is byte-identical to the pre-gate snapshot

VERDICT: every mutation was caught by the check named for it; the control survived
```

只註解的對照組**存活**，所以這個閘門量的是行為不是「檔案變了」。
`cp -p` 快照＋EXIT trap＋結束時 `cmp` 對帳，baseline 是**工作樹**不是 HEAD。

測試本身：`tests/shell/test_ndt_apps_liveness.sh`，44 checks 全綠。
既有的 `tests/shell/test_ndt_app_orphans.sh` 52 checks 全綠——**其中兩條被我改了**：

```
- check "nothing running -> rc 0"                   0 "$rc"
+ check "nothing running -> rc 2 (was 0 before G-6)" 2 "$rc"
- check "stale pidfile naming a stranger -> rc 0"   0 "$rc"
+ check "stale pidfile naming a stranger -> rc 2"   2 "$rc"
```

這兩條是**舊契約寫在哪裡**的證據，不是被我弄鬆的測試：它們在修法前是綠的、修法後轉紅，
我把契約改過來它們才回綠。上面「行為變更對照」表的第三列就是它們在講的事。

---

## 5. 風險與回退

**風險**

1. **`sim` 的 signature 會 match 兩個 pid**：`script -qfa <log> -c ./simulation_platform_manager`
   和它 exec 出來的 `./simulation_platform_manager` 都帶那個字串。所以每個呼叫端問的都是
   「至少有一個嗎」，沒有任何地方問「剛好一個嗎」。已寫進 `app_sig` 的註解。
2. **`start` 現在最多多花 5 秒**才判失敗（成功就立刻回）。這是拿延遲換「ok 是真的」。
3. **`pidfile-lost-but-alive` 這個狀態名對 energy/sim 是誤稱**（它們沒有 pidfile）。
   沒有改名：那個字串被 `apps_orphans` 的輸出和既有測試綁著，改名是另一個 diff。
   訊息本身講的是對的事（"running OUTSIDE the lab session"）。
4. **rc 2 會讓「非 0 即失敗」的外部 script 變紅**。見 §3 的紅字。

**沒有做的事**

- 沒有碰 lab：整套測試把 `sudo` 和 `lab_session` 換成 shell function，跑不到 ndtwin-lab、
  不要 root、動不到別人 claim 的 testbed。
- 沒有碰 `tools/test_workflow/ndtwin-lab`（那是 G-7／G-9 的檔案）。

### 🔴 這支分支**沒有**修什麼，以及它為什麼**碰巧**沒有被同一個形狀咬到（2026-09-03 03:50 自查）

套用當晚談出來的判準——**鑑別力測試只證明它對你注入的輸入有鑑別力；若那些輸入抽自已涵蓋的
集合，測試在結構上照不出未涵蓋的部分**——回頭檢視 G-6，用的是一個**實測到的**輸入而不是我發明的。

**那個輸入**（`doc/audit/2026-09-02_live-round/ADDENDUM-01-viz-orphan-contamination.md`，
已提交於 `b4ee69bf`；不在本分支 base `6283ff5e` 上，我在主工作樹讀的）：

```
pid 893609  ppid 2859     elapsed 01:54:08   1.2% cpu    9.5 MB   java   (wrapper)
pid 893799  ppid 893609   elapsed 01:54:07   111% cpu   247 MB    java   (the viz JVM)
```

`ndt apps stop viz` 對**單一 pid**（bash wrapper）送 TERM，而 `app_spawn` **沒有 `setsid`、
沒有自己的 process group** ⇒ JVM 活下來並被 reparent。之後 `ndt status`、`ndt apps orphans`、
teardown log **三個通道全部**回報 viz 沒在跑（原文：`viz not running (no live instance found by
pid or by scan)`）。它跑了 1h54m、111% CPU、寫了 875 MB log。

#### 🔴 G-6 沒有修這個，而且不要把「兩個 witness」讀成修了它

我親自查證的鏈路（`/home/adam/Network-Traffic-Visualizer/network_traffic_visualizer.sh`，362 bytes）：

```
network_traffic_visualizer.sh   (bash)      ← app_spawn 記到的就是這個 pid
  └─ ./mvnw javafx:run          (maven wrapper，又是一支 shell script)
       └─ java (maven)          ← 觀測到的 893609
            └─ java (JavaFX app) ← 觀測到的 893799，111% CPU
```

**三層，不是兩層。** 而 `app_sig viz` 是 `network_traffic_visualizer.sh` ——
**存活下來的那兩個 java 的 cmdline 裡不會有這個字串**，所以 `app_scan_pids viz`
在結構上找不到它們。這條路徑（nsr/viz/te 的掃描邏輯）**早於本次修法且未被本次修法改動**。

📌 通則（auditor 2026-09-03，我確認）：**任何靠名字比對的 witness，在「存活者不帶那個名字」
的形狀下都會失效。** `comm` 是 `java`，cmdline 是 maven／JVM 的——沒有一個帶得上 app 的身分。
**修法方向應該是路徑式而不是名字式的 signature**（存活的 JVM 的 argv 很可能帶
`/home/adam/Network-Traffic-Visualizer/`），**外加 `app_spawn` 用 `setsid`／process group
讓 stop 停得掉整棵樹**。🔴 **「JVM 的 argv 帶專案路徑」是我的推測，沒有實測。**
**而且它已經確定不可能從今晚的紀錄補回來**：auditor 2026-09-03 回報，23:38 收掉那兩個 JVM 時
只抓了 `pid/ppid/etime/pcpu/rss/comm`，**沒有抓 args**；他把整輪 raw 掃過一遍，
只找得到 launcher 的路徑，**沒有任何一份 log 存了存活 JVM 的完整 argv**。

⇒ **L6 是唯一的取得路徑。** auditor 已把「啟動 viz 的輪次必須存四層 argv 與 ppid 鏈」
加進測試輪的共同 brief，所以那個輸入會在下一輪自然產生，不必為它搶機器。
🔴 **在 argv 到手之前不要動手寫 viz 的修法**——那會是「用想像中的形狀寫修法」的第二次機會。

#### 我改的那半（energy／sim）**沒有**被這個形狀咬到，而且理由是可查證的

- `/home/adam/Energy-Saving-App/energy_saving_app` 與
  `/home/adam/Simulation-Platform-Manager/simulation_platform_manager`
  **兩個都是 ELF 執行檔**（`file` 查的，2026-09-03），不是會 exec 出 JVM 的 shell wrapper。
- 所以**存活的那個行程自己的 argv 就帶著 signature**：sim 在 `script -qfa LOG -c
  ./simulation_platform_manager` 底下時，wrapper 與 child **兩個都** match（已寫進 `app_sig` 註解）；
  wrapper 死了，child 仍然 match。

⇒ **這是結構上的安全，不是我測出來的安全**——我的 fixture 一樣是自己發明的。
差別在於這一次我能指出「為什麼它不可能長成那個形狀」，而 viz 那條我指不出來。

🔴 **但那個論證擋掉的東西比它看起來少，寫清楚免得它被當成比實際更強的保證。**
`file` 說它是 ELF，**只排除掉 shell wrapper 那一種形狀**——沒有 `#!` 交棒、
沒有「launcher 執行完就退場、只剩子孫」的結構。它**不排除**一個 ELF 自己 fork 出
真正幹活的行程然後退場（那樣 app 就是那個子行程，而子行程可能不帶 signature）。

我能排除前者是因為那是**具體機制**（ELF 沒有 `#!` 交棒這一步）；
後者我**只是沒有證據說它會發生**——那不是論證，是沒看過。
**L5 要關掉的就是這個殘差**：把真的 energy／sim 的 argv **與子行程**印出來，
確認「lab 起的那個 pid」就是「一直在跑的那個 pid」。

**待 live 驗證**（要真 fabric／真 app，我沒做）

- L1 真的 `ndt apps sim` 一次，確認 5s 內看得到 pid、`ok` 印得出來。
- L2 把 `SIM_DIR` 的 binary 暫時改名，再 `ndt apps sim`，確認 rc 1 且訊息指向 `sim-out`。
- L3 手動在 lab 外面起一個 energy，確認 `ndt apps` 顯示 ORPHAN、`stop` 回 rc 1。
- L4 整輪 teardown 跑一次，確認 `APPS_STOP_ALL_RC` 是 0 還是 2，並對帳 D1。
- 🔴 **L5（合併前必要條件，與 G-9 的 L2 同性質）** 起一個真的 energy 與 sim，
  **先把完整 argv 印出來存進 audit-raw**（`tr '\0' ' ' < /proc/<pid>/cmdline`，
  sim 的 wrapper 與 child 各做一次），確認 `app_sig`／`app_scan_pids` 真的判得中，**再**接受本閘門。
  理由：本支所有測試輸入都是**我發明的命令列**，沒有一個抽自真的 app。
- 🔴 **L6（不是本支的驗收，是下一支的前置）** 起一個真的 viz，把
  `network_traffic_visualizer.sh` → `mvnw` → maven JVM → app JVM 四層的 argv 與 ppid 鏈全部存證，
  然後**殺掉最外層**，確認 `app_probe viz` 在「wrapper 已死、JVM 被 reparent」下說什麼。
  預期它會說 `not-running`（＝ ADDENDUM 那個缺陷），**那正是要拿去設計下一支修法的輸入**。

**回退**

單一 commit，`git revert` 即可；沒有資料遷移、沒有狀態檔格式改變。
若只想退掉退出碼那半（保留 start 驗活），revert 後重新 apply `app_start`／`app_wait_started`
兩個 hunk 即可——它們與 rc 契約沒有相依。
