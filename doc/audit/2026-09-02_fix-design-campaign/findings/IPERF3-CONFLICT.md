# IPERF3-CONFLICT — 一個字串 `iperf3`，一支殺、一支赦免

**指派 ID**：IPERF3-CONFLICT　**性質**：唯讀設計（read-only design）
**一切都是「讀過」，沒有任何一項是「跑過」。** 沒有執行任何 audit script、沒有 build、
沒有 Mininet、沒有 `ndt`、沒有 claim、沒有 sudo、沒有 `pkill -f`／`pgrep -f`。
repo 未被修改；所有產出都在 repo 外的 scratchpad。

---

## 1. Base + status 快照

**Base commit —— 🔴 本任務進行中 HEAD 動了兩次，而且動到的正是本題的一側**

```
開工   67297376  Register A-6, whose real risk is Adam's own running VM rather than the queue
        ↓  fc447daf  Record the seed decision in the campaign protocol, not only on the ledger
        ↓  94e3c4b6  Charge the CPU of processes that lived and died inside the gate's window   <- 🔴
rebase 基準 1d57602f  Register the contamination gate's lifetime fix as landed, gated, and not yet run live
        ↓
交付時 f2836fc3  ndt: report a pipeline that samples nothing as DISABLED, not as 1/256
```

⚠️ 交付當下 HEAD 又動到 `f2836fc3`，但**本題的四個目標檔在 `1d57602f..f2836fc3` 之間沒有改動**，
四份 patch 對 `f2836fc3` 重驗仍然 rc=0。**這棵樹在動，套用前務必再 `--dry-run` 一次。**

⚠️ 交辦時預期 `4cbec52d …` 或更新；開工時已是 `67297376`。
🔴 **`94e3c4b6` 就是交辦裡說的「另一個 session 的 lifetime rewrite」——它在我做這題的期間
從未提交變成已提交**（`cpu_gate.py` +271/−39，557 行）。
⇒ **我的 `cpu_gate.py` diff 已 rebase 到 `1d57602f`**，四份 patch 全部
`patch --dry-run` rc=0 對 `1d57602f` 驗過（§4）。
⇒ **而它同時改掉了本題的一半機制**，§2.4／§2.5 因此分「修法前／修法後」兩欄寫——
**E 輪已存檔的 72 格是舊閘門量的**，那些格適用的是「修法前」那一欄。

本文所有 `file:line`：`cpu_gate.py`／`lib_e.sh` 取自 **`1d57602f`**（另註明舊行號處除外）；
`measure.sh` 三份在 `67297376..1d57602f` 之間**未改動**，行號 `:45`／`:46`／`:99` 不變。

**`git status --short`（＝別人未提交的工作，不是我的）**

```
 M doc/2026-08-29_bmv2-performance-study-figs/fig5_reporting_matrix.pdf
 M doc/2026-08-29_bmv2-performance-study-figs/fig6_twelve_numbers_one_axis.pdf
 M doc/2026-08-29_bmv2-performance-study-figs/fig7_aggregate_two_planes.pdf
 M doc/2026-08-29_bmv2-performance-study-figs/fig7_aggregate_two_planes.png
 M doc/2026-08-29_bmv2-performance-study-figs/fig8_known_but_never_reported.pdf
 M doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py        <- 大量未提交 diff
 M doc/audit/2026-08-31_sampling-ceiling-after-merge/gates_e.dryrun.log
 M doc/audit/2026-08-31_sampling-ceiling-after-merge/run_e.dryrun.log
?? .claude/launch.json
?? doc/audit/2026-08-31_f5-fine-grid-round/run_f5.dryrun.restore.log
?? doc/audit/2026-08-31_f5-fine-grid-round/run_f5.dryrun.selftest.log
?? doc/audit/2026-08-31_f5-fine-grid-round/run_f5.plan.log
?? doc/audit/2026-08-31_f5-fine-grid-round/run_f5.selftest.log
?? doc/audit/2026-08-31_sampling-ceiling-after-merge/acceptance.sh
?? doc/audit/2026-08-31_sampling-ceiling-after-merge/churn.sh
?? doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.lifetime-acceptance.log
?? doc/audit/2026-09-02_recompute-paired-ab/run_ab.log       <- 快照後新增，交辦清單裡沒有
?? doc/audit/2026-09-02_recompute-paired-ab/run_ab.stdout    <- 同上
?? tests/python/test_cpu_gate_lifetime.py
```

🔴 **另一個 session 正在改 `cpu_gate.py`（lifetime rewrite）並帶著一支未提交的測試
`tests/python/test_cpu_gate_lifetime.py`。** 我的 `cpu_gate.py` diff 對 committed 版設計，
**必然與它衝突**；衝突面與緩解寫在 §4.3。

**三份 `measure.sh` — 交辦說「byte-identical except one output-dir line」，實際不是**

| 檔 | md5（committed） | 行數 |
|---|---|---|
| `doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh` | `d67523839b41b8c5d3cded418e6e9421` | 101 |
| `doc/audit/2026-09-01_cpu-matrix-1hz/measure.sh` | `592bcee67b7d66498d721ce6777f96b6` | 101 |
| `doc/audit/2026-09-02_recompute-paired-ab/measure.sh` | `55f7f89036e7c6535f9709ba56c0b984` | 101 |

`diff` 結果（rc 直接取，未經 pipe）：

- **08-20 vs 09-01**：差 **三行**，`:25`（`OUT=`）、`:59`（`netdev_only.py` 路徑）、
  `:86`（`slim_client_json.sh` 路徑）。
- **09-01 vs 09-02**：差 **一行**，只有 `:25`。

⇒ ✅ **更正交辦的前提**：不是「只差一行輸出目錄」。
09-02 那份的 `:59`／`:86` 指向 **09-01 的目錄**，也就是
**09-02 輪的 `measure.sh` 執行的是 09-01 輪的 `netdev_only.py` 與 `slim_client_json.sh`**。
（不是缺陷，但「三份是同一支儀器」這句話要加註：**三份的殺法逐位元組相同，
輔助腳本的來源不同**。）

**三份的 `pkill` 行號完全一致**：`:45`、`:46`、`:99`。

🔴 **文件引用是舊的**：`doc/KNOWN-ISSUES.md:1614` 與 `:1638` 都寫
`measure.sh:45-46,96`，**實際收尾那行在 `:99`**（差 3 行）。
另外交辦給的 KNOWN-ISSUES 行號也要修正——實際標題行是：

| 交辦寫的 | 實際 |
|---|---|
| `:1565` pkill ban | `:1610` `### measure.sh 內含專案硬規矩禁用的 pkill -f …`（通用禁令在 `:1480`／`:1490`／`:1502`） |
| `:1616` gate holes | `:1661` `### 🔴 CPU 汙染閘門有三個洞 …`；**本題的專屬條目在 `:1634`** |

---

## 2. 機制：兩側各自到底比對什麼

### 2.1 殺的那側 —— `pkill -f iperf3`

**位置**（committed，三份皆同）：

```
doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh:45   sudo -n mnexec -a "$H33" pkill -f iperf3 2>/dev/null || true
doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh:46   sudo -n mnexec -a "$H1"  pkill -f iperf3 2>/dev/null || true
doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh:99   sudo -n mnexec -a "$H33" pkill -f iperf3 2>/dev/null || true
```

比對的東西：**`-f` ⇒ 拿 pattern 去比 `/proc/<pid>/cmdline`（整串 argv，空白接起來），
且是「不錨定的子字串／regex」**。不是 comm、不是 argv[0]、沒有邊界。

三個放大因子：

1. **`sudo -n` ⇒ pkill 以 root 執行**。作用域不限於 `adam`，**任何使用者、任何 root 行程**都殺得到。
2. **`mnexec -a "$H33"` 沒有縮小範圍**。`measure.sh:42-44` 自己的註解寫明
   「Hosts share the root PID namespace, **which is why a plain pkill reaches them at all**」
   ⇒ 附身進去的就是 **root PID namespace**，等於整台機器。
3. **`2>/dev/null || true`** ⇒ 殺了幾個、殺了誰，**一個位元組都不留**。
   沒有任何存檔可以事後回答「這一格有沒有殺到人」。

**`pkill -f iperf3` 在這台機器上可能打到的行程類別**（列舉，非窮舉但涵蓋已知形狀）：

| # | 類別 | 例 | 是本輪目標嗎 |
|---|---|---|---|
| A | 本輪自己的 iperf3 server | `iperf3 -s -1 --daemon --logfile …_server.log`（`measure.sh:49`） | ✅ 是（唯一設計意圖） |
| B | 本輪自己的 iperf3 client | `iperf3 -c 10.0.0.33 -u -b 200M …`（`:82-83`） | ⚠️ `:99` 收尾時是（此時已 `wait` 過） |
| C | **別的 session 的 iperf3** | 任何一支 | 🔴 **否**——已登記的災害 |
| D | **路徑含該字串的 shell／腳本** | `bash …/run_iperf3_sweep.sh` | 🔴 否 |
| E | **開著該檔的編輯器／pager／tail** | `vim …/iperf3_notes.md`、`less X_iperf3.log`、`tail -F …iperf3.log` | 🔴 否 |
| F | **正在「搜尋」這個字串的行程** | `grep iperf3 …`、`awk '$2=="iperf3"…'` | 🔴 否 — 見下面 F' |
| G | **argv 含該字串的 python／工具** | `python3 cpu_gate.py --label cell_iperf3_x`（**閘門自己**） | 🔴 否 |
| H | 包裝行程 | `ssh h33 'iperf3 -s'` 的本地 ssh、`watch`／`timeout` 包起來的那層 | 🔴 否 |
| I | **另一支併發的 `pkill -f iperf3`** | pkill 不殺自己，但殺得到「別人的 pkill」 | 🔴 否 |

🔴 **F' —— 最尖的一個實例：這個 kill 殺得到「為了防它而寫的守衛」。**
`doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh:435`：

```bash
pids=$(ps -eo pid=,comm= | awk '$2=="iperf3"{printf "%s ", $1}')
```

那支 `awk` 的 **argv 裡就有字串 `iperf3`**（`$2=="iperf3"…` 是 argv[1]）
⇒ 它本身是 `pkill -f iperf3` 的合法目標。
而失效方向是**開的**：`lib_e.sh:35` 只有 `set -u`，**沒有 `set -e`、沒有 `pipefail`**；
`awk` 被 SIGTERM ⇒ 輸出空 ⇒ `pids` 空 ⇒ `:436` 的 `[[ -n "${pids// /}" ]]` 為假
⇒ **`return 0` ＝「沒有外來 iperf3，可以繼續」**。
**守衛被殺掉時說的是「乾淨」。** （同 index/02 的「行程存活檢查會用兩種方式說謊」與
「兩個守衛在最需要它們的時候失效」`KNOWN-ISSUES:1684` 同族。）
⚠️ 在**單一 session** 的正常流程裡守衛與 kill 不同時跑（`run_e.sh:135` 先跑完才到 `:137`）；
這條在**兩個 session 併發**時才可達——而兩個 session 併發正是這整題的前提。

### 2.2 赦免的那側 —— `cpu_gate.py` 的前綴豁免

**位置**（`doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py`）：

| | `1d57602f`（現在） | `67297376`（E 輪 72 格量測時） |
|---|---|---|
| `FABRIC_PREFIXES = (` | `:99` | `:66` |
| `"iperf3",  # the offered load, started by measure.sh` | **`:104`** | `:71` |
| `def _is_fabric(comm):` | `:231` | `:142` |
| `return comm.startswith(FABRIC_PREFIXES)` | **`:252`** | `:163` |
| 分類點 `if _is_fabric(comm) or pid in proxy …: -> mine` | `:328` | `:185` |
| `def _read(pid):` | `:136` | `:81` |

🔴 **`94e3c4b6` 沒有動這個豁免。** 它關掉的是壽命盲、截切、身分三個洞；
`"iperf3"` 這一行與 `startswith` 這個比對方式**原封不動**。⇒ 本題完全未被那顆 commit 解決。

比對的東西，逐項確認（兩版一致）：

- **比的是 `comm`，不是 argv、不是 argv[0]。** 來源在 `_read()`：
  讀 `/proc/<pid>/stat`，取第一個 `(` 與**最後一個** `)` 之間 ⇒ 這是 kernel 的 `comm`，
  **執行檔 basename 截斷到 15 bytes**，且行程可用 `prctl(PR_SET_NAME)` 自行改寫。
- **比對方式是「前綴」，不是精確、不是子字串**（`str.startswith` 吃 tuple）。
- **大小寫敏感**。`Iperf3` 不匹配。
- ⇒ 匹配集合＝`{comm | comm 以 "iperf3" 開頭}`：包含 `iperf3`、`iperf3x`、`iperf3_burn`、
  `iperf32`；**不含** `my-iperf3`（非前綴）、`Iperf3`（大小寫）。

檔案自己已經記下這是**不安全的那一邊**（`1d57602f` 的 `:89-97`；`67297376` 的 `:55-64`，原文）：

> `exact, too narrow : ours -> foreign => FALSE ALARM (safe side)` /
> `prefix : foreign -> ours => CONTAMINATION MISSED (unsafe side)`
> 並且已寫出未做的收緊：`require the comm prefix AND the pid to appear in the fabric manifest`。

### 2.3 兩個集合既不相等也不互相包含 —— 這才是問題的形狀

| 行程 | argv 含 `iperf3`？ | comm 前綴 `iperf3`？ | 結果 |
|---|---|---|---|
| `grep iperf3 f` | ✅ 被殺 | ❌（comm=`grep`）| **既被殺、又被算成汙染** |
| `./iperf3_burn` | ✅ 被殺 | ✅ 被赦免 | 被殺前不算汙染 |
| `./burner` + `prctl(PR_SET_NAME,"iperf3")` | ❌ 活著 | ✅ **被赦免** | 🔴 **最壞格：活著且被記成「我們的」** |
| 別人的 `iperf3 -s` | ✅ 被殺 | ✅ 被赦免 | 🔴 **無聲**：不算汙染、被殺、無存檔 |

### 2.4 呼叫順序 —— 🔑 本輪最關鍵、且尚未被任何文件寫下的事實

兩個 call site 的順序**相反**：

**順序 A（ladder cell，`run_e.sh:135-138`）— 閘門先，measure 後**

```
:135  foreign_iperf3_guard || abort …          <- 點取樣，只看「之前」
:136  cell_cpu_gate_start "$cell"              <- 閘門背景啟動，立刻取 snapshot A
:137  POLL=on "$PRIOR/measure.sh" …            <- pkill；1s；起 server；1s；…；起 client
:138  cell_cpu_gate_finish "$cell"             <- snapshot B
```

閘門 `measure()` **一進去就取 `a = _snapshot()` 再 `sleep(window)`**（`1d57602f:263-270`），
window ＝ `DUR-30`（`lib_e.sh:1088`）。
⇒ **本輪自己的 iperf3（server 與 client）都是在 snapshot A 之後才誕生的。**

**這一點在 `94e3c4b6` 前後的結果完全相反：**

- **修法前（`67297376:176-177`，＝ E 輪 72 格量測時的版本）**

  ```python
  if pid not in a:
      continue                       # started mid-window: no baseline, cannot attribute
  ```

  🔴 **⇒ 在 ladder cell 這條路上，`FABRIC_PREFIXES` 裡的 `"iperf3"` 是死碼。**
  本輪自己的 iperf3 既不進 `mine` 也不進 `foreign`，**根本沒被走到**。
  豁免從來沒有生效過，而閘門之所以 GREEN 是因為**壽命盲**，不是因為 allow list 對了。

- **修法後（`1d57602f:286-296`）**

  ```python
  if prev is None:
      if start_b / CLK >= up_a:      # 從 /proc/<pid>/stat 第 22 欄回推：窗內誕生
          midwindow = True
          delta = ticks_b            # 全額計入
  ```

  ⇒ 窗內起的行程**全額計入**，接著在 `:328` 走同一個分類點
  ⇒ 🔴 **`"iperf3"` 豁免在 ladder cell 上「復活」了：從死碼變成承重。**
  本輪自己的 iperf3 現在正確地進 `mine`（這是對的），
  **但同一條路上，任何窗內出現的外來 iperf3 也一起進 `mine`。**
  ⇒ 那一格從「無聲丟棄」變成「**主動歸戶成自己人並印在 `ours` 欄**」。
  兩者都錯，但後者**看起來更像證據**。

🔑 **一句話**：`94e3c4b6` 把壽命這個軸修好了，
**副作用是讓本題的名字豁免第一次在 ladder 路徑上真正生效**——
洞的位置沒變，但它的**可達性變高了**。這不是那顆 commit 的錯（它修的是別的洞），
但它讓本題從「兩條路徑其中一條」變成「兩條路徑都會」。

**順序 B（G5b force-green (ii)，`gates_e.sh:429-433`）— measure 先，閘門後**

```
:429  foreign_iperf3_guard || abort …
:430  POLL=on "$PRIOR/measure.sh" g_gate_load 90 "$RATE_MBIT" >>"$LOG" 2>&1 &
:431  local load_pid=$!
:432  sleep 20
:433  if cpu_gate forcegreen_ownload green --window 40 --exempt-pid "$load_pid"; then
```

⇒ 負載先跑滿 20 秒，**snapshot A 裡有本輪自己的 iperf3**
⇒ `_is_fabric("iperf3")` 生效 ⇒ 進 `mine` ⇒ 閘門 GREEN、G5b PASS。

🔴 **而 `--exempt-pid "$load_pid"` 豁免的是 `measure.sh` 那層 shell，不是 iperf3。**
（`$!` 取的是被 `&` 背景化的 `measure.sh` 行程；iperf3 是它的孫輩，
server 還因 `--daemon` 雙 fork 脫離。）
⇒ **G5b 之所以綠，唯一支撐就是 `"iperf3"` 這個名字豁免。**

🔑 **操作結論（已按 `1d57602f` 更新）**：
把 `"iperf3"` 從 `FABRIC_PREFIXES` 拿掉——

- 在 `67297376` 上：ladder cell **一格都不會變**（那裡是死碼），但 G5b 翻紅、依
  `gates_e.sh:438-440` **中止整輪**。
- 在 `1d57602f` 上：**ladder cell 也會翻紅**——本輪自己的 iperf3 client 現在全額計入，
  200 Mbit 的 UDP 送端不是小數目，它會直接被算成 foreign。

⇒ **兩個版本上，「乾脆刪掉那一行」都會停掉整輪，而在新版上停得更徹底。**
⇒ **本設計不動 `FABRIC_PREFIXES`，一個字元都不動。**
任何「刪掉那一行就好」的提案都必須先讀這一段。
🔑 **正確的順序是：先有「哪些 pid 是我們的」這個事實（manifest），才談得上拿掉名字豁免。**
名字豁免不是多餘的保護，它是**目前唯一**讓閘門認得自己負載的東西。

### 2.5 互動矩陣

縱軸＝呼叫順序；橫軸＝外來 iperf3 的有無與出現時機。
「今天各自回報什麼」取自 committed 碼；「真嗎」是對照實際發生的事。

| # | 順序 | 外來 iperf3 | `measure.sh` 回報 | 閘門回報（**舊 `67297376`** ＝ E 輪 72 格） | 閘門回報（**新 `1d57602f`** ＝ 下一輪起） | 真嗎 |
|---|---|---|---|---|---|---|
| 1 | A（閘門先） | 無 | 正常完成，**無 kill 紀錄** | GREEN；自己的 iperf3 **完全沒出現**在 `mine` 也沒在 `foreign`（`:176-177` 丟棄） | GREEN；自己的 iperf3 **進 `mine`**，帶 `[started mid-window]` | ⚠️ 舊：**結論真、理由假**（綠來自壽命盲，不是 allow list）。新：真且理由對 |
| 2a | A | 守衛**之前**就在 | — | — | — | ✅ **唯一今天正確的路徑**：`run_e.sh:135` REFUSE + abort，不殺、不誤判 |
| 2b | A | 守衛後、snapshot A 前（ms 級競態） | `:45-46` **殺掉它**，`2>/dev/null \|\| true` 吞掉 | 在 `a`→`_is_fabric`→`mine`；snapshot B 已無→**迴圈只跑 `b`，連看都看不到** | 同左，但其 CPU 落進 `unattributed_cores`，且 `excluded_vanished` **加一** | 🔴 **假**。別人的行程被殺、CPU 未入帳。新版**有一個 +1 的計數**，但那個計數**不指名、也不分辨「shell 正常結束」與「被殺」** |
| 2c | A | snapshot A 之後（**常見**，守衛只是點取樣） | 撐過 `:45-46`，在 `:99` 收尾被殺 | 不在 `a`→丟棄，貢獻 0 | 🔴 **全額計入 → `_is_fabric` → `mine`**，印在 `ours` 欄 | 🔴 **假**。舊版無聲；**新版更糟：逐字把別人的行程列印成「我們的」** |
| 3 | B（measure 先） | 無 | 正常 | GREEN；自己的 iperf3 靠名字豁免進 `mine`（此處豁免承重） | 同左 | ✅ 真 |
| 4a | B | 守衛之前就在 | — | — | — | ✅ `gates_e.sh:429` REFUSE + abort |
| 4b | B | 守衛後、`:45-46` 前（ms 級） | 殺掉，無紀錄 | 已死於 snapshot A 之前，兩邊都沒有它 | 同左 | 🔴 **假**，且**兩版都完全無聲**（連計數都沒有） |
| 4c | B | `:45-46` 之後、snapshot A 之前（**`gates_e.sh:432` 的 `sleep 20`，整整 20 秒的窗，不是競態**） | 撐過前置清場；90 秒後在 `:99` 被殺 | 在 `a` 也在 `b` ⇒ `_is_fabric` ⇒ **進 `mine`**，被 `ours` 那幾行**印出來** | 同左（`:328` / `:519-520`） | 🔴🔴 **最壞且兩版皆然**。閘門 GREEN、G5b 記 PASS，**把別人的行程列印成「我們的」**，然後殺掉它。「儀器長得像自己的發現」的完整形狀 |

**橫讀一次**：8 條路徑只有 **2a／4a** 是對的，而它們對的原因是 `lib_e.sh` 的守衛
**擋下整格**，不是兩支腳本互相知道。第 1 條在舊版是「對的結論、錯的理由」。
其餘四條全部假；`94e3c4b6` 之後 **2b 多了一個不指名的計數，2c 反而從無聲變成主動誤標**。

⇒ 🔑 **「誰先跑」今天決定的不只是結果，還決定了「有沒有人知道結果被決定過」。**
⇒ 🔴 **沒有任何一條路徑會在存檔裡留下「發生過一次 kill」這件事。**
`excluded_vanished`（新版 `:348`）是最接近的東西，但它是
`len(a.keys() - b.keys())`——**每一個正常結束的 shell 都會讓它 +1**，
所以它**不可能**把 kill 從雜訊裡分出來。這正是 §3.3 (c′) 要補的那一項。

---

## 3. 設計選項、建議、逐位元組可比性

### 3.0 裁決邊界的複述

Adam 今日裁定（binding）：**凍結殺法**（`:45`／`:46`／`:99` 三行不准動，
四輪存檔錨在這支儀器上，逐位元組可比性此刻優先於合規）＋
**讓兩支互相知道對方存在**，使「誰先跑」不再無聲決定結果。

### 3.1 (a) 共用 manifest／lock：本輪起的 iperf3 PID 清單

**機制**：`measure.sh` 在起完 server／client 後把 PID 寫進
`$OUT/${LABEL}_iperf3.manifest`；閘門讀它，`mine` 的判準改成 **pid 在 manifest 裡**，
`comm` 只當交叉檢查；閘門輸出 `foreign_iperf3=N` 取代「按名字赦免」。

**成本**

- 🔴 **`measure.sh` 根本不知道自己的 iperf3 PID。**
  - server 是 `--daemon`（`:49`）⇒ **雙 fork 脫離，shell 從來沒拿到那個 PID**。
  - client 在 `run_iperf` 裡以 `sudo -n mnexec -a "$H1" iperf3 …`（`:82-83`）跑，
    而 `IPERF_PID=$!`（`:95`）取的是 **`run_iperf` 那層 subshell**，不是 iperf3。
  ⇒ 要拿到真 PID，只能**啟動後回頭掃 `/proc`**——而「掃到的那些是不是我的」
  正是 manifest 本來要消除的那個歧義。**這個選項自帶循環。**
- 需要 round id／時間戳，否則上一格的 stale manifest 會豁免一個被重用的 PID。
- 改動 `measure.sh` 位元組（新增掃描與寫檔），且改動點在 `:49` 之後——**行號一定位移**。

**會無聲弄錯什麼**
🔴 **若掃描時競態抓到一個外來 PID 寫進 manifest，閘門接下來就是「按 PID 赦免」它——
比原本的名字赦免更像證據、更難懷疑。** 把一個弱的錯誤換成一個強的錯誤。

**唯一沒有循環的變體**：讓 iperf3 自己報 PID（`iperf3 -I/--pidfile`）——
但那要改 `measure.sh:49` 的 iperf3 啟動參數，**改的是「被啟動的東西」本身**，
凍結上最難辯護。列為 Adam 的裁決題（§6 Q3）。

### 3.2 (b) 殺之前先斷言：所有匹配 PID 都是我起的，否則**拒絕**（不殺）

**機制**：在 `:45` 之前列舉 `comm` 精確等於 `iperf3` 的 PID（**絕不用 `pgrep -f`**），
逐一驗 parent／session 是不是自己，有一個不是就 `exit` 而不是 kill。

**成本**

- 🔴 **`ppid` 這個判準對「我們自己的 server」不成立**：`--daemon` 雙 fork 後 `ppid=1`，
  `sudo` 也可能開新 session ⇒ **「是不是我的」對本輪自己起的 server 無法回答**
  ⇒ 這個斷言有**誤拒方向**，會在自己漏了一支 server 的第二格把整格打掉。
  ⇒ **交辦裡寫的 (b) 原型（`pgrep` by exact comm + parent pid）在這支腳本上不可行。**
- 行號位移：`:45` → `:55` 左右，**KNOWN-ISSUES:1614／:1638、TBD-DRAFT:146、
  FINDINGS、HANDOFF 全部的 `measure.sh:45-46,96` 引用一次作廢**
  （那些引用**現在就已經是錯的**——`:96` vs 實際 `:99`——但這會讓錯得更多）。

**可行的變體 (b′)**：不驗 parent，只斷言**匹配集合為空**（＝把 `foreign_iperf3_guard`
的判斷搬進 `measure.sh`，讓直接執行 `measure.sh` 的人也受保護）。可判定、fail-closed。
代價：今天 `:45-46` 對「自己上一格漏掉的 server」是**無聲回收**，(b′) 之後變成**中止**。

**🔑 (b″) —— 本文建議的形狀：把斷言放進 wrapper，`measure.sh` 一個位元組都不動。**
新增 `measure_guarded.sh`：做完 census（純 bash 比較，連 `awk` 都不用，
避免 §2.1 F' 那個「自己的 argv 就是靶」的問題）→ 寫下 census 存檔 →
`exec` 那支被凍結的 `measure.sh`，argv 與 env 原封不動。

- ✅ `measure.sh` **md5 不變、行號不變、所有既有引用仍然有效**。
- ✅ 「機器在 T0 是乾淨的」從**假設**變成**存檔**（今天連這個都沒有）。
- ⚠️ **它是「提供」不是「強制」**：直接打 `measure.sh` 的人仍不受保護。
  但那**正是今天的狀態**，所以不是退步；而要強制就得改名，改名等於動到所有引用，更糟。
- ⚠️ `exec` 之後 wrapper 就不存在了 ⇒ **wrapper 沒辦法做「啟動後回頭寫 manifest」**。
  (a) 因此不能塞進 wrapper，要另外安置。這是誠實的限制。

### 3.3 (c) 閘門把「被豁免的 PID ＋ 它們的 start time」記下來

**機制**：對每個被名字豁免的行程讀 `/proc/<pid>/stat` 第 22 欄（starttime，
自 boot 起的 clock ticks），寫進 JSON 紀錄，事後可判斷它是不是這一格才誕生的。

**成本**：極小，純閘門側，**`measure.sh` 零位元組**。

⚠️ **`94e3c4b6` 已經做掉了 (c) 的一部分**，必須先扣掉再談剩下的：

| (c) 原本想要的 | `1d57602f` 已有嗎 | 還缺什麼 |
|---|---|---|
| 讀 starttime | ✅ `_read` 已回傳 start，身分改成 `(pid, starttime)` | — |
| 窗內誕生看得見 | ✅ `midwindow` 全額計入 + 印 `[started mid-window]` | — |
| 窗內消失看得見 | 🟡 **只有一個數**：`excluded_vanished = len(a.keys() - b.keys())`（`:348`） | **不指名、不過濾** |
| 短命行程的上界 | ✅ `unattributed_cores`（`:357`）＋ `suspect` | — |
| **「被赦免的是誰」** | ❌ **完全沒有** | 名字豁免仍然無聲 |

**會無聲弄錯什麼**：🔴 **(c) 單獨無法看見 kill。**
`excluded_vanished` **每一個正常結束的 shell 都會 +1** ⇒ kill 埋在雜訊裡，
在一台跑著桌面的機器上這個數字本來就是幾十。
starttime 本身也不證明歸屬（外來的舊 iperf3 與自己漏掉的舊 server 長得一樣）。

**🔑 (c′) —— 剩下的、也是唯一看得見 kill 的那兩項**（就是本設計的 `cpu_gate.py` diff）：

1. **`vanished_fabric_named`**：把 `a - b` **過濾成「comm 被 allow list 涵蓋的那些」並列出 pid/comm**。
   一個在窗內消失、而且名字剛好被赦免的行程，**就是一次 kill 的指紋**；
   一個結束的 `bash` 不是。成本＝一次已經算過的集合差再加一個 `if`。
2. **`name_exempt`**：列出**只靠名字**離開 foreign 統計的那些（沒有任何我方 pid 為它背書），
   附 `pre-window`／`mid-window`。這讓檔頭那句「ACCEPTED risk, not an absent one」
   **從一句話變成一份可讀的清單**。

⇒ 兩項都是 **report-only**，不進 verdict、不進 `foreign_cores_attributable`。

### 3.4 建議的組合

> **建議：(b″) wrapper ＋ (c′) 閘門 report-only。(a) 延後，等 §6 Q3 裁完再做。**

理由，三句：

1. **(b″) 是唯一在凍結上零爭議的預防**：`measure.sh` md5 不變，所以「凍結是否被違反」
   這個問題根本不會被提出（見 §3.5 與 §6 Q1）。
2. **(c′) 是唯一能讓「誰先跑」留下痕跡的偵測**，而且 report-only ⇒ **不改任何 verdict**
   ⇒ 存檔的 gate 結論仍可重現。預防與偵測分屬兩側，任一側失效另一側仍在。
3. **(a) 現在做會把弱錯誤升級成強錯誤**（§3.1），而且它的前置條件——
   「能不靠競態地知道自己的 PID」——今天不存在。**先有 (b″) 建立的 T0 乾淨存檔，
   (a) 才有可辯護的歸屬論證。**

⚠️ **三者都不修「殺法本身」，也都不修 `FABRIC_PREFIXES`。** 依 §2.4，動後者會打掉 G5b。

### 3.5 逐位元組可比性 —— 逐個 diff 講清楚

**(A) `measure_guarded.sh`（新檔）**

- **`measure.sh` 改動的位元組：0。** md5 三份全部不變，行號不變。
- **量測行為（取樣什麼、何時取樣）改變：無。** wrapper 走 `exec`，
  同一支檔案、同一組 argv、同一份環境變數（`POLL` 等）、同一個 PID、
  同樣的 stdout/stderr 繼承。**成功跑完的那一格，逐位元組是同一支儀器產生的。**
- 🔴 **但拒絕的那一格會改變「已完成格」的母體**，這點必須明講：
  - 今天：外來 iperf3 存在時，那一格**照樣完成**（而且順手殺掉對方）。
  - 之後：那一格**不存在**。
  - ⇒ 缺格**不是隨機缺**，是**「機器髒的時候才缺」**（missing not at random）。
    對「天花板／plateau」這種讀數，方向上是有利的（丟掉髒格），
    **但方向有利不等於沒有改變**。⇒ **必須把「被拒絕的格數與原因」當成結果的一部分回報**，
    不能只回報完成的那些。（同 index/02「比值兩邊要同一母體」。）
  - ⚠️ 另一個誠實的但書：**今天不裝這個 wrapper，同一格也可能因為別人的 iperf3 被殺而
    產生一格「看起來完成、其實對方資料少一段」的結果。** 兩邊都不是零成本，
    差別是**一邊的成本記在自己的存檔裡（缺格），一邊記在別人的存檔裡（無聲少一段）**。
- ⚠️ **既有輪次（08-20／08-25 D 輪）不受影響**：它們已經跑完，wrapper 只影響未來的呼叫。
  ⇒ 「同 fabric、同 binary 才逐格比」的前提（E 輪 §6）**仍然成立**。

**(B) `cpu_gate.py`（report-only）**

- **`measure.sh` 改動的位元組：0。**
- **verdict 計算路徑：零改動。** `total = m["foreign_cores_attributable"]`（`:432`）、
  `excess`／`verdict`（`:495-496`）、`suspect`（`:436`）一行未動
  ⇒ 既有的 gate 判定完全可重現，`cpu_gate.lifetime-acceptance.log` 那組驗收數字不受影響。
  新增的兩個 list **沒有進入任何加總**：`named_ticks`、`foreign_total`、`unattributed` 都未觸碰。
- **JSONL schema 是「加欄位」**，不是改欄位。下游 `lib_e.sh:cell_cpu_gate_finish`
  （`1d57602f:1092-1130`）以 `r['verdict']`／`r['excess_cores']`／`r.get('covariates',{})`／
  `'suspect' not in r` **按 key 取值** ⇒ 加欄位安全。
  ⚠️ 但任何做**嚴格 schema 驗證**的讀者會被加欄位打到——沒找到這樣的讀者，但我無法證明沒有（§5）。
  ⚠️ **`tests/python/test_cpu_gate_lifetime.py` 已隨 `94e3c4b6` 提交**；我沒有讀它
  （它不在交辦的閱讀清單內，且我不執行測試）⇒ **無法保證它不會因為
  `measure()` 回傳 dict 多了四個 key 而失敗**。若它做的是「key 集合完全相等」的斷言就會紅。
  ⇒ 這是**套用前必須先跑一次那支測試**的理由（§6 Q5）。
- ⚠️ `cpu_gate.py` **不屬於被凍結的儀器**：它是 08-31 輪自己的檔，
  08-31 當天因 14-vs-15 那個 bug 改過，09-01 又整支重寫過（`94e3c4b6`，+271/−39）。
  **凍結令針對的是 `measure.sh`，不是它。**

**(C) `lib_e.sh`（可選，修守衛的自射 `awk`）**

- **`measure.sh` 改動的位元組：0。**
- 改的是守衛的**列舉手法**（`awk` → 純 bash），**判準與輸出訊息不變**
  ⇒ 對「守衛通過」的那些格，行為完全相同；只有「守衛自己被殺」那條路徑會從
  fail-open 變成 fail-closed。

---

## 4. Diff（**未套用**，全部在 repo 外）

目錄：`/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/4e0e8cb4-1c72-4731-b5fe-2989d7af1d65/scratchpad/fix-designs/IPERF3-CONFLICT.patches/`

**四份，全部對 `1d57602f` 以 `patch -p1 --dry-run` 驗過 rc=0**（在 scratchpad 的複本上跑，
repo 未被觸碰）。`.py` 另過 `python3 -m py_compile`，`.sh` 另過 `bash -n`。
🔴 **全部未套用。沒有執行過任何一支。**

| 檔 | 目標路徑（若套用） | +/− | 建議 |
|---|---|---|---|
| `measure_guarded.sh.diff` | `doc/audit/2026-08-31_sampling-ceiling-after-merge/measure_guarded.sh`（**新檔**） | +111 / −0 | ✅ **建議**（(b″) 預防） |
| `cpu_gate.py.diff` | `doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py` | +53 / −2，6 hunks | ✅ **建議**（(c′) 偵測） |
| `lib_e.sh.diff` | `doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh` | +16 / −2，1 hunk | 🟡 可選但便宜（修守衛自射） |
| `measure.sh.NOT-RECOMMENDED.diff` | `doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh` | +25 / −0，1 hunk | 🔴 **僅供比較，不建議套用** |

另有 `committed/`（我對照的 `1d57602f` 原檔）與 `work/`（套用後的完整檔），供逐 hunk 對讀。

### 4.1 `measure_guarded.sh.diff` — 建議的預防（新檔）

- **`measure.sh` 動 0 位元組**；三份 md5 全部維持
  `d675238…`／`592bcee…`／`55f7f89…`，`:45`／`:46`／`:99` 行號不變。
- 做三件事：**(1)** 以**純 bash**（不用 `awk`／`grep`／`pgrep`）按 **精確 `comm`** 做 census；
  **(2)** 不論結果如何都印出一行 `IPERF3-CENSUS …`（被呼叫端的 `>>"$LOG"` 收走），
  可選 `MEASURE_GUARD_OUT` 另存一份 ⇒ 「T0 機器是乾淨的」從**假設**變成**存檔**；
  **(3)** 乾淨才 `exec` 那支凍結的 `measure.sh`，argv／env／pid／stdio 全部不變。
- **`MEASURE_SH` 沒有預設值**，故意的：三份 copy 不可互換（`:25`／`:59`／`:86` 不同），
  猜錯會把一格寫進別輪的 `raw/`。
- 呼叫端改法（**未含在 diff 裡**，因為那是 Adam 的排程決定）：
  `run_e.sh:137` 與 `gates_e.sh:430` 的 `"$PRIOR/measure.sh"` 改成
  `MEASURE_SH="$PRIOR/measure.sh" "$HERE_LIB/measure_guarded.sh"`。

### 4.2 `cpu_gate.py.diff` — 建議的偵測（report-only）

六個 hunk，`@@ -276 / -328 / -347 / -362 / -503 / -518 @@`：

1. `name_exempt = []` 宣告。
2. 分類點旁收集「**只靠名字**被赦免」的行程（`pre-window`／`mid-window`）。
3. `excluded_vanished` 之後加 **`vanished_fabric_named`**（`a - b` 過濾成 allow-list 涵蓋的），
   附一段講清楚兩支腳本對同一字串的相反處置。
4. 兩個 list 進 `measure()` 的回傳 dict。
5. 兩個 list 進 `rec`（JSONL）。
6. `main()` 印兩段：`🔴 KILL-SHAPED: …`（有 vanished 且被 allow list 涵蓋時）與
   `note  N process(es) left the foreign accounting by NAME alone …`。

🔴 **與另一 session 的衝突狀態（更新）**：交辦時說的 lifetime rewrite **已於任務期間提交**
（`94e3c4b6`）。**本 diff 已 rebase 到它之上**，所以**目前無衝突**。
仍然存在的兩個風險：
- 該 session 若還有**未提交的後續**（`git status` 目前顯示 `cpu_gate.py` **已乾淨**，
  但那是一個時間點的取樣），會再度衝突。**套用前重驗一次 `patch --dry-run`。**
- **`tests/python/test_cpu_gate_lifetime.py` 我沒有讀、沒有跑**；
  `measure()` 的回傳 dict 多了四個 key，若該測試對 key 集合做完全相等斷言就會紅（§6 Q5）。

### 4.3 `lib_e.sh.diff` — 可選：讓守衛不再是自己防的那把刀的靶

把 `:435` 的 `ps … | awk '$2=="iperf3"{…}'` 換成在**本 shell 內**比較的 `while read` 迴圈。
**判準與所有輸出訊息一字不改** ⇒ 守衛通過的那些格行為完全相同；
只有「守衛自己被殺」那條路徑從 **fail-open** 變成不可達。

### 4.4 `measure.sh.NOT-RECOMMENDED.diff` — 只為了讓成本可見

把 refuse-only 斷言直接插進凍結檔（交辦裡的選項 (b)）。
兩行 kill **一個位元組沒動**，但：
🔴 **`:45`／`:46`／`:99` 位移到 `:69`／`:70`／`:123`**，md5 改變，
`KNOWN-ISSUES:1614`、`:1638`、`TBD-DRAFT:146`、FINDINGS、HANDOFF 的引用一次全部作廢，
而且 08-20／08-25 的存檔格不再由逐位元組相同的儀器產生。
**`measure_guarded.sh` 用零位元組達成同樣的拒絕。** 附上只是為了讓 §6 Q1 有東西可比。

---

## 4.5 KNOWN-ISSUES：既有條目已經寫了什麼、還缺什麼

**先更正交辦給的行號**（實測於 `1d57602f`）：

| 交辦 | 實際 |
|---|---|
| `:1565` pkill ban | `:1610`（通用禁令另在 `:1480`／`:1490`／`:1502`） |
| `:1616` gate holes | `:1661`（`94e3c4b6` 之後已改為「🏁 碼落地、變異閘過、live 待驗」） |
| —— | **本題專屬條目在 `:1634`**，`94e3c4b6` **沒有動它** |

**`:1634` 已經寫對的**（不需要重寫）：兩側位置、`-f` 比整條 argv、
`comm.startswith` 的前綴語意、`foreign_iperf3_guard` 存在但只看窗前、
「一個字串兩個相反失效模式」、以及修法形狀
（`/proc/<pid>/exe`、錨定比對、**pid 是否在本輪 fabric manifest**）。

**四件它還沒寫、而且是決策相關的**——建議在 `:1634` 那則末尾、
「**關聯**」那一行之前插入下面這段（原文照抄即可）：

> - 🔴 **`94e3c4b6`（09-01 壽命修法）沒有碰這個豁免，但改變了它的可達性。**
>   兩個 call site 的順序是**相反的**：ladder cell 是**閘門先、`measure.sh` 後**
>   （`run_e.sh:136` → `:137`），G5b 是 **`measure.sh` 先、閘門後**（`gates_e.sh:430` → `:433`）。
>   ⇒ **修法前**，ladder 的自家 iperf3 在 snapshot A 之後才誕生，被 `:176` 的
>   `if pid not in a: continue` 丟掉，**`FABRIC_PREFIXES` 裡的 `"iperf3"` 在 ladder 路徑上是死碼**，
>   豁免只在 G5b 承重。**修法後**窗內誕生的行程全額計入，
>   ⇒ **豁免在 ladder 路徑上第一次真正生效**：自家的 iperf3 正確歸戶，
>   **而任何窗中途冒出來的外來 iperf3 也一起被歸成 `mine` 並印在 `ours` 欄**——
>   從「無聲丟棄」變成「主動誤標」。🔑 **洞沒有變大，但變得容易走到，而且留下的痕跡更像證據。**
> - 🔴 **`gates_e.sh:433` 的 `--exempt-pid "$load_pid"` 豁免的是 `measure.sh` 那層 shell，不是 iperf3。**
>   `$!` 取的是被 `&` 背景化的 `measure.sh`；client 是它的孫輩，server 還因 `--daemon`
>   雙 fork 脫離。⇒ **既有的 pid 豁免機制沒有在做讀者以為它在做的事**，
>   G5b 之所以綠，唯一支撐仍是名字豁免。⚠️ **因此「把 `"iperf3"` 從 `FABRIC_PREFIXES` 拿掉」
>   在兩個版本上都會停掉整輪**（舊版停 G5b，新版連 ladder 一起停）。順序是：**先有 manifest，才談拿掉名字。**
> - 🔴 **`gates_e.sh:432` 的 `sleep 20` 是一個 20 秒的窗，不是競態**：
>   在這 20 秒內出現的外來 iperf3 **撐過了 `measure.sh:45-46` 的前置清場**，
>   進 snapshot A、被名字赦免、被印成 `ours`，然後在 90 秒後被 `:99` 的收尾 kill 殺掉。
>   **閘門 GREEN、G5b 記 PASS、對方資料無聲少一段，而三份存檔都說一切正常。**
> - 🔴 **守衛自己是那把刀的靶。** `lib_e.sh:435` 是
>   `ps -eo pid=,comm= | awk '$2=="iperf3"{…}'`——**那支 `awk` 的 argv 裡就有 `iperf3`**，
>   所以 `pkill -f iperf3` 殺得到它。而 `lib_e.sh` 只有 `set -u`，**沒有 `set -e`、沒有 `pipefail`**
>   ⇒ awk 被殺 ⇒ `pids` 空 ⇒ `:436` 為假 ⇒ **`return 0`，回報「乾淨」**。
>   **守衛被摧毀的瞬間說的是可以繼續。** 兩個 session 併發時可達，而那正是本則的前提。
>   修法：把比較留在 shell 內（`while read` + `[[ "$_comm" == iperf3 ]]`），不要交給 argv 帶著字串的子行程。
> - ⚠️ **本則與上一則的行號引用是舊的**：兩處寫的 `measure.sh:45-46,96`，
>   **收尾那行實際在 `:99`**（三份 copy 皆同）。另：三份 copy **不是只差輸出目錄一行**——
>   08-20 與 09-01／09-02 差 `:25`／`:59`／`:86` 三行，09-02 的 `:59`／`:86` 指向 **09-01 的**
>   `netdev_only.py` 與 `slim_client_json.sh`。

---

## 5. 我無法判定的事

1. 🔴 **`tests/python/test_cpu_gate_lifetime.py` 的內容與通過與否。**
   它已隨 `94e3c4b6` 提交，但**不在交辦允許的閱讀清單內，我也不執行測試**。
   ⇒ 我**不能**宣稱我的 `cpu_gate.py` diff 不會弄紅它。回傳 dict 多四個 key 是唯一的風險面。
2. 🔴 **`mnexec -a` 到底 setns 了哪些 namespace，我沒有讀 `mnexec.c`。**
   我引用的是 `measure.sh:42-44` **自己的註解**與 `KNOWN-ISSUES:1617` 的既有判定
   （「作用域是整台機器」）。⚠️ 這是**轉述，不是我親自驗證的**。
   即使 `-a` 有加入 pid namespace，mininet host 共用的就是 root pid ns，結論不變——
   但那一步推論也是讀來的，不是我測的。
3. ⚠️ **沒有任何一格是我跑出來的。** §2.5 的矩陣是**讀碼推導**，不是實測。
   要把它變成證據，需要一次刻意的雙 session 實驗（§6 Q4），而那要開量測窗、要 claim。
4. ⚠️ **我不能證明沒有下游在對 gate 的 JSONL 做嚴格 schema 驗證。**
   我查過 `lib_e.sh` 的讀法（按 key）與 `cell_verdict.py` 的引用路徑，
   但**沒有對整個 repo 做窮舉**——`grep` 給不完整答案的方式有九種（memory/05）。
5. ⚠️ **`FABRIC_PREFIXES` 其他六個前綴有沒有同樣的雙語意問題，我只查了 `iperf3`。**
   `mnexec` 看起來高度可疑（`measure.sh` 自己每一行都在跑 `mnexec`，
   而 `pkill -f mnexec` 不在任何腳本裡——但 `_is_fabric` 會赦免任何 comm 以它開頭的東西）。
   **沒查。**
6. ⚠️ **另一個 session 現在在做什麼、會不會再動 `cpu_gate.py`**，我只有一個時間點的
   `git status` 取樣。⇒ 套用前重跑 `patch --dry-run`。

---

## 6. 給 Adam 的裁決題（選項＋後果）

### Q1 🔴 **「在 kill 之前加行」算不算違反凍結？**（交辦指定必問）

**兩邊都論一次，決定權在 Adam：**

- **算違反**：凍結保護的是**這支檔案作為一個可引用的物件**。四輪存檔的可比性建立在
  「同一支儀器」上，而**識別儀器的方式是 sha／md5**（PREREG §4／§C3 的
  `record_identity` 就是這樣做的：sha256 ＋ `/proc/<pid>/exe`，**不是「行為等價」**）。
  md5 一變，「同一支」這句話就要改口徑成「行為等價的兩支」，
  而**行為等價是推論，sha 是量測**——本專案的紀律是不拿推論冒充量測。
  加上 `:45/:46/:99 → :69/:70/:123` 會讓五份文件的引用同時作廢。
- **不算違反**：裁決文字保護的是**量測**（取樣什麼、何時取樣）。一個
  **只會拒絕、永不改變成功路徑**的前置斷言，對「跑完的那一格」而言是恆等變換——
  同樣的 `iperf3`、同樣的 `cpu_probe.py 2 Hz`、同樣的 4 Hz twin poll、同樣的 `/proc/net/dev`。
  ⇒ 成功的格逐位元組可比性**在資料層面**不變，只有**檔案的 sha** 變。
  🔴 **但誠實的但書**：它**會**改變「哪些格跑得完」——外來 iperf3 存在時那格從
  「完成（並殺掉別人）」變成「不存在」。**缺格不是隨機缺，是機器髒的時候才缺。**
  ⇒ 拒絕次數與原因必須跟結果一起回報，否則母體悄悄變了（memory/02「比值兩邊要同一母體」）。

**我的建議**：**這題可以不用裁。** `measure_guarded.sh`（§4.1）用
**零位元組**達成同一個拒絕 ⇒ 「算不算違反」根本不會被問到。
只有在 Adam 要求「保護必須是強制的、不能被繞過」時，Q1 才變成必答題（見 Q2）。

| 選項 | 後果 |
|---|---|
| **(a) 走 wrapper，不裁 Q1**（建議） | md5／行號／所有引用全保住；代價是直接打 `measure.sh` 的人不受保護（**＝今天的狀態，非退步**） |
| (b) 裁定「加行不違反」，改凍結檔 | 保護變強制；五份文件的引用同時作廢，存檔格不再由同 sha 的儀器產生 |
| (c) 裁定「加行違反」，且不要 wrapper | 現狀維持：§2.5 的六條假路徑全部留著 |

### Q2 保護要「提供」還是「強制」？

| 選項 | 後果 |
|---|---|
| **提供（wrapper，建議）** | 零位元組。**但繞得過**：任何人直接執行 `measure.sh` 就沒有保護 |
| 強制（改凍結檔或改名） | 繞不過。改名等於動到所有引用，比改內容更糟；改內容＝Q1(b) |
| 強制但用權限（`chmod -x measure.sh`） | 🔴 **不建議**：那是改**檔案系統狀態**而不是內容，`git` 追不到、clone 拿不到，而且會讓別輪的腳本無預警壞掉 |

### Q3 🔴 manifest 要不要做，要用哪一種歸屬論證？

| 選項 | 後果 |
|---|---|
| **(a) 現在不做**（建議） | 保住現狀；名字豁免仍然是唯一的歸屬依據，但 §4.2 讓它**有清單可讀** |
| (b) 用「排除法」建 manifest（T0 空 ⇒ 之後出現的都是我的） | 🔴 **把弱錯誤升級成強錯誤**：競態抓到的外來 pid 會被**按 pid 赦免**，比按名字更像證據、更難懷疑 |
| (c) 用 `iperf3 -I/--pidfile` 讓 server 自報 pid | 唯一沒有循環的版本。🔴 **但要改 `measure.sh:49` 的 iperf3 啟動參數 ⇒ 改的是「被啟動的東西」本身**，凍結上最難辯護（比 Q1 的「加行」更難） |

🔑 **(a) → 先觀察一輪 `name_exempt` 的實際內容 → 再決定 (b)/(c)**，
是唯一不需要現在就賭的路。

### Q4 要不要用一次刻意的雙 session 實驗把 §2.5 從推導變成證據？

| 選項 | 後果 |
|---|---|
| 要 | 4c 那一格（20 秒窗）可以被**看見**：一支自己起的、標記清楚的 iperf3，看它是否被印進 `ours` 再被殺。需要量測窗與 claim；**這正是 mutation gate 要的那個「紅」** |
| **不要**（可接受） | §2.5 停留在「讀碼推導」，報告裡必須這樣寫，不得寫成實測 |

### Q5 `cpu_gate.py` 的 diff 要不要現在套？

| 選項 | 後果 |
|---|---|
| **先跑 `tests/python/test_cpu_gate_lifetime.py` 再決定**（建議） | 唯一能回答「多四個 key 會不會弄紅它」的做法。我沒讀也沒跑 |
| 直接套 | 若該測試斷言 key 集合相等就會紅，而且會紅在**別人剛用變異閘驗收完的檔案上** |
| 不套 | `vanished_fabric_named` 缺席 ⇒ **kill 仍然是整條管線裡唯一不留痕跡的事件** |

### Q6 `lib_e.sh` 守衛的自射 `awk` 要不要一起修？

| 選項 | 後果 |
|---|---|
| **修**（建議，§4.3） | 16 行、判準與訊息不變，把一個 **fail-open 的守衛**變成不可達。便宜 |
| 不修 | 守衛在**兩 session 併發**——也就是它唯一有用的場合——會回報「乾淨」 |

---

**產出清單**
- 本檔：`…/scratchpad/fix-designs/IPERF3-CONFLICT.md`
- diff：`…/scratchpad/fix-designs/IPERF3-CONFLICT.patches/{measure_guarded.sh,cpu_gate.py,lib_e.sh,measure.sh.NOT-RECOMMENDED}.diff`
- 對照原檔：`…/IPERF3-CONFLICT.patches/committed/`（`1d57602f`）、套用後：`…/work/`

🔴 **repo 未被修改，未執行任何 audit script，未 commit／add／checkout／stash／reset。**

[Co-developed with claude code -- Adam]
