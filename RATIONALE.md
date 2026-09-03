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

`doc/KNOWN-ISSUES.md:2164`：「**`ndtwin-lab cleanup` 可能殺掉呼叫它的 shell**（內部跑 `mn -c`）。單獨一行跑。」
那是 `mn -c` **自己內部**的 `pkill -9 -f`（KNOWN-ISSUES 1488），**不是** cleanup 的那四行。
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
