# NDT-HARNESS — 實驗 harness 的兩個儀器缺陷（KNOWN-ISSUES row 02 / row 05）

指派 ID：**NDT-HARNESS**
工作樹：`/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a6027dd08134f9eb2`（隔離）

---

## 1. Base 驗證與 harness 身分

```
$ git checkout --detach 4cbec52d45bd85e0e972110e35f51693d6ce137f
HEAD is now at 4cbec52d Keep the one line that names the restore failure
$ git log --oneline -1
4cbec52d Keep the one line that names the restore failure
$ sed -n '1520p' doc/KNOWN-ISSUES.md
| **02** | R-3 收斂表四個數字有三個量的是 **harness 自己的時間**；`port_holder` 看不到 root 擁有的 listener | 已開工單 **T-9／T-10** |
$ sed -n '1523p' doc/KNOWN-ISSUES.md
| **05** | 一個註冊為 240 秒的窗口實際跑了 **474 秒**；一面**永遠亮著**的 banner | 已開工單 **T-10** |
```

Base 正確。

### 目標檔案不是 `ndt`，是 T-4 輪的 harness

工單講的四個數字與 240 秒窗口**都不在 `ndt` 裡**，而在 T-4 輪自己的 harness。三者路徑與 sha256：

| 檔 | 路徑（皆相對 repo 根） | sha256 |
|---|---|---|
| harness 共用庫 | `doc/audit/2026-08-30_live-full-stack-round/harness/lib.sh` | `06227b31e4559c13fb7251b7e1daeb16404603ef5b8309978858f7562c4841fc` |
| R-3 收斂表 | `doc/audit/2026-08-30_live-full-stack-round/harness/20_apps_lifecycle.sh` | `5575c068b716db39c6f2356035c0e5141a0f84e476dd3554e162141ebc60bd82` |
| 240 秒窗口＋banner | `doc/audit/2026-08-30_live-full-stack-round/harness/25_apps_energy.sh` | `58aea82319cb9290c41fad70b31109694b3bb25092236b0245302aa032627819` |

順帶記下工單提到的兩支 lab 工具（本輪**沒有執行過任何一支**）：

| 檔 | 路徑 | sha256 |
|---|---|---|
| `ndt` | `tools/test_workflow/ndt`（`~/.local/bin/ndt` 是指向**主樹**的 symlink） | `67412ba47f9d4d337536e886ffaded7fe05f72ad7992067956cbe3c5fbe32c75` |
| `ndtwin-lab` | `tools/test_workflow/ndtwin-lab`＝已安裝的 `/usr/local/sbin/ndtwin-lab`（兩側 hash 相同） | `288b71cb8ccc7c9472f4229d46c5fe1408592ede091be180536ed65676b0ce4c` |

🔴 **`~/.local/bin/ndt` 指的是主樹**（`/home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt`），
不是我的工作樹 ⇒ 就算要跑也不會跑到我改的碼。本輪一次都沒跑（見 §5 邊界）。

---

## 2. 機制：兩列各自的四個／兩個數字，以及與 T 工單的對帳

### 🔴 對帳的第一個結果：**KNOWN-ISSUES 這兩列已經過期**

`git merge-base --is-ancestor cd440488 HEAD` → **rc=0**。
`cd440488`（"T-10/FINDING-02: the convergence table measured the harness, and a blind port probe"）
**是 base 的祖先**，也就是說 row 02 的兩個缺陷、row 05 的兩個缺陷，**碼層面都已經在 base 裡修好了**，
而 KNOWN-ISSUES G-2 的 row 02／row 05 當時仍寫「已開工單」。

⚠️ 注意有一對**同內容但不同 hash** 的 commit（`e2098033` / `cd440488`、`842cab2e` / `a824b230`），
只有後者在 HEAD 的祖先鏈上（`e2098033` → rc=1）。這是 rebase／cherry-pick 留下的雙胞胎，
**引用 commit hash 時要先確認是哪一顆在你的分支上**。

⇒ 所以本輪的工作**不是重修一次**，而是：
① 逐條驗證修法真的成立；② 找出修法留下的殘餘缺口；③ 補上**永久回歸測試**（見下，這是最大的洞）；
④ 把 KNOWN-ISSUES 改成事實。

---

### Row 02 — R-3 收斂表的四個數字

**修前的碼**在 `a824b230`（＝`cd440488^`）。以下 file:line 皆為**修前**版本，
可用 `git show a824b230:doc/audit/2026-08-30_live-full-stack-round/harness/20_apps_lifecycle.sh` 取得。

修前那張表（`FINDING-02...md:16-23` 逐字保存）：

```
T0 (ndt up invoked)   1788073422
sim    DID NOT SERVE         -        -
nsr    first served at   1788073646   (+224 s)
viz    first served at   1788073427   (+5 s)
te     first served at   1788073423   (+1 s)
apps serving: 3 of 4
```

| # | 數字 | 修前 file:line | **產生它的時間戳對** | **量到的是誰** | 量系統要用的對 |
|---|---|---|---|---|---|
| 1 | sim `DID NOT SERVE` | `20_apps_lifecycle.sh:141-152`；賦值在 `:147` `T_APP[sim]=$(( T0 + SIM_WAIT ))` | 不是時間戳對——`:146` 的 `if [[ -n "$SIM_PID" ]]` 拿 `port_holder 9000` 的**空字串**當「沒人在聽」，走 `:151` 的 `bad`。**這一格是 Defect B 造成的，不是 Defect A** | 量的是 `port_holder` 的**可見度**，不是 sim | `t_bind(sim) − t_start(sim)`，兩端都是 wall clock；而 `t_bind` 要能在 owner 不可見時仍然成立 |
| 2 | nsr `+224 s` | `:165` `NSR_T="$(first_serve_epoch "$NSR_DIR/recorded_info" "$T0")"` | `mtime(nsr 第一個新檔) − T0`。**唯一一個真的讀了時鐘的** | 仍然是 harness 的排程：腳本要到 ≈`T0+220 s` 才輪到 nsr ⇒ 224 裡有 ~220 是**等 harness**，nsr 自己只花 ~4 s | `mtime(第一個新檔) − t_start(nsr)` |
| 3 | viz `+5 s` | `:197-200`；賦值在 `:199` `VIZ_T=$(( T0 + i ))` | `T0`（`ndt up` 被呼叫的 epoch）**＋ 迴圈第幾圈**。兩個量**沒有共同原點**：`i` 的原點是腳本執行到 `:198` 的那一刻 | 量的是「配對成功發生在這個迴圈的第 5 圈」，被寫成「距 `ndt up` 5 秒」。真值 ≈**+229 s**（誤差 ~46×） | `date +%s`（配對當下）− `t_start(viz)` |
| 4 | te `+1 s` | `:249-252`；賦值在 `:251` `TE_T=$(( T0 + i ))` | 同上 | 同上。真值 ≈**+231 s**（誤差 ~231×） | 同上 |

🔑 **兩個誤差方向一致，而且都讓結果好看**：Defect A 讓收斂看起來更快，Defect B 讓失敗看起來
是 app 的錯而不是儀器的錯。（`memory: the-clean-version-is-the-one-to-recheck`）

🔑 **修好算術還不夠**——這是 FINDING-02 底下的第二層發現，也是修法真正的重點：
三個真值全部叢集在 ≈+224…231 s，因為 `20_apps_lifecycle.sh` 是**序列**啟動 app 的，
到 ≈`T0+220 s` 才輪到 nsr/viz/te。**這張表量的是「harness 什麼時候輪到它」**，
把 `T0+i` 換成正確的 `date +%s` 之後，`since_T0` 那一欄**照樣**量的是 harness。

#### 修後（base 現況，已驗證）

- `20_apps_lifecycle.sh:151` `mark_start() { T_START[$1]="$(date +%s)"; }`——記下**這支腳本**啟動每個 app 的時刻。
- `:261`（viz）／`:315`（te）：`VIZ_T="$(date +%s)"` / `TE_T="$(date +%s)"`，在配對當下讀時鐘，`T0 + i` 已消失。
- `:341` 表頭改成 `#app state served_epoch since_T0 started_epoch own`，
  `:346` 的 `own` ＝ `T_APP[a] − T_START[a]`，**那一欄才是 app 自己的收斂**。
- `:357` 印一行指示讀 `own` 不要讀 `since_T0`。

⚠️ **殘餘（設計上的，不是 bug）**：PREREG §3 的 R-3 原文是「convergence time from `ndt up` to
all five apps serving」。**這支 harness 序列啟動 app，所以那個問題它答不了**，
能答的只有 break condition（有沒有收斂）。`since_T0` 那一欄留在 TSV 裡是為了可追溯，
但它**永遠**是 harness 的排程。修法自己在 `:332-337` 的註解裡講清楚了。

---

### Row 02 — `port_holder` 看不到 root 的 listener

**修前**：`git show a824b230:.../lib.sh` 的 `:383-388`：

```bash
port_holder() {
    local port="$1" out
    out="$(ss -lptnH "sport = :$port" 2>/dev/null || true)"
    [[ -n "$out" ]] || { printf ''; return 0; }
    printf '%s' "$out" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true
}
```

**確切的失效機制**（不是讀 `/proc/<pid>/`，是 `ss` 少印一個欄位）：
非 root 跑 `ss -lptnH`，對**別人擁有**的 socket 仍然會印出 LISTEN 那一行，
但**省略 `users:(("…",pid=N,…))` 欄位**（那需要讀 `/proc/<pid>/fd/` 才對得起來 inode，
非 owner 沒有權限）。於是：

1. `out` **非空**（LISTEN 行在）⇒ `:386` 的提早返回**不會**觸發；
2. `grep -oE 'pid=[0-9]+'` **抓不到東西** ⇒ 整個 function 回**空字串**；
3. 空字串在每一個呼叫端都被讀成「**沒有人在聽**」。

⇒ **「讀不到」被印得跟「沒東西」一模一樣**，這正是 sentinel-value 家族的典型失效。

代價：`20_apps_lifecycle.sh:142` 的 `[[ -n "$(port_holder 9000)" ]]` 是 sim 的等待條件，
而 sim 是透過 `ndtwin-lab` 的 NOPASSWD verb 起在 **root 的 tmux session** 裡 ⇒
**這個檢查在碼裡就自相矛盾，把 60 秒窗口放寬到一小時也不會改變結果。**
`sim DID NOT SERVE` 因此**一個 bit 的資訊都沒有**：既不是 sim 失敗的證據，也不是它成功的證據。

FINDING-02 當時的實測（含**陽性對照**，那是讓它成為觀測而非猜測的那一半）：

```
ss -ltnH 'sport = :9000'  -> LISTEN 0 4096 0.0.0.0:9000     （有 listener）
port_holder 9000          -> []                              （harness 看不到）
port_holder 8000          -> [284117]                        （對照：自己 uid 的 socket，正常）
```

#### 誠實的輸出長什麼樣（修後，base 現況 `lib.sh:383-451`）

```bash
PORT_HOLDER_HIDDEN='LISTENER-OWNER-HIDDEN'      # :412 — 非數字字串，是刻意的
port_holder() {                                  # :414
    ...
    [[ -n "$out" ]] || { printf ''; return 0; }  # :419 只有「沒有 LISTEN 行」＝FREE
    pid="$(...)"                                 # :420
    if [[ -n "$pid" ]]; then printf '%s' "$pid"  # :422 有 pid
    else printf '%s' "$PORT_HOLDER_HIDDEN"; fi   # :424 有人在聽，看不到是誰
}
port_is_bound() { [[ -n "$(port_holder "$1")" ]]; }   # :430
```

三態：`""`＝FREE／`<pid>`＝那個 pid 佔著／`LISTENER-OWNER-HIDDEN`＝**有人在聽但看不到是誰**。
`assert_port_is`（`:433-451`）對第三態走 **`skip`（N/A＝UNTESTABLE）**，不是 pass 也不是 mismatch——
「我們搆不到」永遠不會被記成「它沒問題」。
sentinel 選**非數字**字串是設計：忘記處理第三態而去做算術或 `/proc` 查表的呼叫端會**明顯壞掉**，
不會安靜地變成別的意思。

✅ **本輪逐一檢查了全部 12 個呼叫端**（`00_preflight.sh:156`、`10_r1:178`、`20_apps:185/188/199`、
`40_r5_p4.sh:71/72/176/271`、`50_r5_ovs.sh:61/62`、`90_restore.sh:162/222`），**沒有一個被三態打壞**：
`-n` 形式問的是「有沒有人在聽」（hidden 算有，正確）；`-z` 形式問的是「port 是不是空的」
（hidden 算不空，**這正是修法要的方向**——修前它會把 root 佔用的 port 報成空的）。
兩個 `-z` 站點（`10_r1:178`、`90_restore:162`）修前是**沉默錯誤**，修後正確。

---

### Row 05 — 註冊 240 秒、實跑 474 秒

**修前** `25_apps_energy.sh`（逐字保存在 `FINDING-05...md:64-70`）：

```bash
WATCH_S=240
for i in $(seq 0 $(( WATCH_S / 10 ))); do
    ... graph_counts ...        # OVS 上每次 query ~10 s，P4 上 ~0 s
    sleep 10
done
```

**機制**：迴圈數的是**圈數**（25 圈），不是秒數。
每圈的實際成本 ＝ `sleep 10` ＋ **query 時間**，而 query 時間**沒有被算進去**。
⇒ 窗長 ＝ 25 ×（10 ＋ query）。OVS 上 query ≈ 10 s ⇒ **25 個樣本橫跨 474 s，平均間隔 19.8 s**，
而報告寫「in 240s」。

🔑 **240 這個數字註冊在哪裡**：`25_apps_energy.sh:204` 的 `WATCH_S=240` 字面量。
**PREREG.md 裡沒有它**（`grep '240' PREREG.md` 無命中）——
它的理由只寫在腳本註解 `:184-186`：Energy-App 的迴圈是 60 s（`settings.hpp:8`），
240 s ＝四個 cycle，「久到『什麼都沒發生』是關於 app 的陳述而不是關於我們的耐心」。
⇒ **這個窗口是腳本的字面量，不是預註冊參數**（給 Adam 的裁決題，見 §7）。

🔑 **它剛好往長的方向跑，所以無害**——app 有更多機會動作，報告低估了自己的耐心。
**但同一個構造在較快的路徑上會安靜地把窗口縮短**，那時「什麼都沒發生」就真的變成關於我們耐心的
陳述了，而那正是 240 s 要排除的東西。

#### 修後（base 現況 `25_apps_energy.sh:204-227`）—— 已改成 deadline 驅動

```bash
WATCH_S=240
WATCH_T0="$(date +%s)"; WATCH_END=$(( WATCH_T0 + WATCH_S ))
while :; do
    ... sample ...
    WATCH_N=$(( WATCH_N + 1 ))
    (( $(date +%s) >= WATCH_END )) && break
    sleep 10
done
WATCH_ACTUAL=$(( $(date +%s) - WATCH_T0 ))
info "watch window: requested ${WATCH_S}s, ACHIEVED ${WATCH_ACTUAL}s over $WATCH_N samples ..."
```

deadline 驅動 ⇒ **不可能再縮短**（危險方向已封死），overrun 上界收斂成「一個 sleep ＋ 一次 query」。

#### 🔴 殘餘缺陷（本輪要修的）：**註冊窗口與實跑窗口從來沒有被比較過**

工單原話：*「a run must report `registered=240 actual=474 overrun=234` and mark itself,
not just proceed」*。現況做不到：

- `:224` 是 **`info`**。`info()`（`lib.sh:107`）**不計入 `CHECKS`、不計入 `FAILS`、不寫 `verdicts.jsonl`**
  ⇒ 兩個數字被印出來，但**沒有任何判決**，跑完照樣 `exit 0`。
- `:227` 只把 `WATCH_ACTUAL` 寫進 `energy_watch_actual_seconds.txt`。
  **`WATCH_S` 沒有進任何 artefact**，overrun 沒有被算出來過 ⇒
  事後讀 raw 的人**無法從檔案判斷這一輪的窗口有沒有守住**。
- 迴圈若哪天被改回 iteration-counting（**已經在這個 harness 裡發生過三次**，見下），
  `WATCH_ACTUAL` 會安靜地變短，而**沒有任何東西會轉紅**。

🔑 **這是同一族缺陷的第三次**：`FINDING-05` 的窗口、`FINDING-02` Defect A 的 viz 與 te——
**用迭代次數冒充時間**在這個 harness 裡是**房子的風格，不是一次手滑**。
一個只會 `info` 的自我量測，擋不住風格。

---

### Row 05 — 永遠亮著的 banner

**修前**：degraded banner **無條件印出**，包括緊接在同一支腳本剛剛判定
「switches powered off by the app: **0**」之後，而 `ndt status` 當時讀出 10 up／0 admin-disabled／
40 links／0 down。**什麼都沒有被降級。**

它宣稱顯示的條件：「fabric 現在被降級了，量測前先還原」。
為什麼永遠為真：**那個條件根本沒有被求值**——banner 不在任何 `if` 裡。

🔑 **單看無害，組合起來不無害**：它指示操作員去跑的那條還原路徑，正是 FINDING-04 證明
「會把 fabric 拆掉然後停住」的那一條。在一個**沒有降級**的 OVS fabric 上照做，
**會為了修一個不存在的問題而毀掉一個健康的 fabric**。
⇒ 兩個各自可存活的缺陷組合成一個不可存活的。

**修後**（base 現況 `25_apps_energy.sh:311-320`）：gate 在腳本**已經算出來**的 `POWERED_OFF` 上，
不另外量任何東西；`else` 分支明講「**不要**跑 `./90_restore.sh`，沒有東西要還原，
它的 rebuild 路徑會為了修零個問題而拆掉一個健康的 fabric」。✅ 已驗證，本輪不需再動。

---

### 🔴 對帳的第二個結果：**修法沒有留下任何永久回歸測試**

```
$ grep -rln 'port_holder|PORT_HOLDER_HIDDEN|r3_convergence|WATCH_ACTUAL|mark_start' tests/ tools/
（無命中）
```

`09_t8-t10-evidence.md` 的驗收品質很高（每條都逼過紅與綠、預測寫在前面、還記錄了
「修法自己的 bug 被驗收跑出來、不是被 review 看出來」），**但那些都是拋棄式的
extracted-logic harness，跑在一個獨立 worktree 裡，一行都沒有進 `tests/`。**

⇒ 現在的狀態是：**碼是對的，而沒有任何東西守著它。**
下一個編輯 `lib.sh` 的人可以把 `port_holder` 改回兩態、把 `while` 改回 `for i in $(seq ...)`，
`bash -n` 全綠、`tests/` 全綠、**沒有一條紅線**。
`memory: mutation gate＝沒看過紅不算交付` 對**修法本身**同樣適用。

---

## 3. 修法設計

### 採用

**F1（row 05 的實體缺口）— `lib.sh` 新增 `assert_window_span`，並在 `25_apps_energy.sh` 呼叫它。**

一個判決型 gate（不是 `info`），把註冊窗口與實跑窗口變成**可比較、會轉紅、進 artefact** 的東西：

```
assert_window_span <label> <registered_s> <actual_s> [<overrun_tol_s>]

  actual < registered              -> bad   UNDERRUN
  registered <= actual <= +tol     -> ok
  actual > registered + tol        -> bad   OVERRUN
```

三個設計決定，各有理由：

1. **underrun 容忍度＝0。** deadline 驅動的迴圈**在物理上不可能**在 deadline 前結束
   ⇒ 任何短缺都代表迴圈已經不是 deadline 驅動的了（＝回歸），不是雜訊。
   而這正是註解點名的危險方向。
2. **overrun 有容忍度**（預設 30 s，可用 `WINDOW_OVERRUN_TOL_S` 覆寫）。
   deadline 迴圈的結構性 overrun 上界＝一個 `sleep` ＋ 一次 query；OVS 上 ≈10+10=20 s ⇒ 30 s 夠。
   超過它就不是結構性 overrun，而是迴圈沒在看時鐘。08-30 的真實數字：
   `registered=240 actual=474 overrun=234` ⇒ **紅**，工單要求的那一行逐字出現。
3. **一律寫 artefact**（`<label>_span.tsv`：`registered/actual/overrun/tolerance/verdict`），
   **無論判決是什麼**。事後讀 raw 的人不必重跑就能知道窗口守住沒有——
   這是修掉「`WATCH_S` 從來沒進過任何檔案」的那一半。

**F2 — 補永久回歸測試 `tests/shell/test_harness_instruments.sh`。**
四組，全部用假的 `ss` / 假時鐘 / 暫存目錄，**不碰 lab、不碰 `ndt`、不碰網路**。
配一支 `tests/shell/mutate_harness_instruments.sh`：把每個缺陷重新種回一份**複本**裡，
斷言測試轉紅——把突變閘門本身變成可重跑的資產，而不是一次性的驗收敘述。

### 駁回的替代方案

| 方案 | 為什麼駁回 |
|---|---|
| **重新實作 row 02／row 05 的修法** | `cd440488` 已在 base 的祖先鏈上，碼已經對了。重寫＝製造分歧，而且會蓋掉一份寫得比我好的驗收紀錄 |
| **overrun 也判 `ok`，只印警告** | 那就是現況（`info`），也就是這一列缺陷本身。工單明寫要 mark itself |
| **overrun 判 `skip`（N/A）** | `skip` 的語意是「搆不到、無法判定」。窗口跑超過是**判定得出來**的事實，不是搆不到 |
| **underrun／overrun 用同一個對稱容忍度** | 兩個方向的意義不對稱：短了讓結論失去支撐（致命），長了只讓報告的數字說謊（要修但不致命）。同一個門檻會抹掉這個區別 |
| **把 `since_T0` 欄從 TSV 拿掉** | 它是可追溯性的一部分，而且修法已在 `:332-337`＋`:357` 講明怎麼讀。拿掉會讓「為什麼有兩欄」這件事失去現場 |
| **用 extracted-logic fixture 測 viz／te 迴圈**（＝T-10 驗收當時的做法） | **測的是複本不是出貨的腳本**。這個 repo 已經為「patch 打在副本上＝no-op」付過代價（08-30 OvS 對照輪整輪）。改用**原始碼形狀守衛**並在測試裡明講它是形狀守衛不是行為測試 |
| **把測試寫成 Python** | harness 是 shell，`lib.sh` 可以直接 source。Python 會需要重新實作被測物 ＝ 又一個複本 |

### 受影響的呼叫端

- `25_apps_energy.sh` 是 `assert_window_span` 目前唯一的呼叫端。
- `lib.sh` 新增的是**純新增**，沒有既有 function 的簽名被改 ⇒ 其餘 8 支腳本不受影響
  （已用 `bash -n` 全部複驗，見 §5）。
- `port_holder` 的 12 個呼叫端本輪**未改動**（已驗證三態不打壞它們，見 §2）。

### 受影響的過去宣稱（**列出，不編輯**）

工單要求列出所有引用過收斂表數字的 audit round。
`grep -rn 'r3_convergence|since_T0|first served at|DID NOT SERVE|apps serving|474 s' doc/`：

| 檔 | 引用了什麼 | 需要的註腳 |
|---|---|---|
| `doc/audit/2026-08-30_live-full-stack-round/FINDING-02_r3-convergence-table-measures-the-harness.md:16-23, 57-63` | 整張修前的表（`+5 s`／`+1 s`／`+224 s`／`DID NOT SERVE`） | **不需要**。這份文件的主題**就是**這些數字是錯的，它已經自己標好了 |
| `doc/audit/2026-08-30_live-full-stack-round/FINDING-05_...md:15, 60, 72, 117` | `watch duration 250 s → 474 s`、`25 samples`、`mean 19.8 s` | **不需要**，同上：它是揭露方 |
| `doc/audit/2026-08-30_live-full-stack-round/CONTAMINATION-agy-runs-i-started-myself.md:93` | 「OVS watch (**474 s**)」當**時間軸**用，去對 `agy` 的污染次數 | 🔴 **需要**。474 s 是**修前那個會漂移的窗口**測出來的跨度。作為 agy 污染的時間軸它**仍然有效**（那是實際經過的 wall-clock，不是被 `WATCH_S` 宣稱的 240），但**不可以**被讀成「這一輪的窗口設定是 474 s」 |
| `doc/audit/2026-08-30_live-full-stack-round/PREREG.md:109` | R-3 的登記口徑：「from `ndt up` to all five apps serving. 08-18 reference: 69 s (OVS) / 2 s (P4)」 | 🔴 **需要**。① 那兩個參考值是 `T_stack`，**母體不同**，從來不能跟這一欄比（AMENDMENT-1 已記）；② 這支 harness **序列**啟動 app ⇒ 登記的那個問題**這個設計答不了**，只有 break condition 答得了 |
| `doc/audit/2026-08-30_live-full-stack-round/harness/README.md` | 表的欄名 | 隨修法更新即可，非宣稱 |
| `doc/audit/2026-08-30_live-full-stack-round/09_t8-t10-evidence.md:466-494, 601-604` | 修後的 `+229s`／`+9s`、`ACHIEVED` | **不需要**，那是修法的驗收 |

🟢 **重要的負面結果：沒有任何「後續輪次」引用過這張表的數字。** 污染是**被封在 T-4 輪內**的。

⚠️ **編號撞車警告**：`grep -rn 'R-3' doc/` 會大量命中 **`TR-3`**
（`doc/audit/2026-08-30_live-traffic-round` 的「窗口在競爭下會不會變長」）。
**那是另一個題目，跟收斂表無關。** 這正是 KNOWN-ISSUES 已經記過的「兩套 F-n 編號撞號」同一種病。

---

## 4. Patch

分支 `ndt-harness-t9-t10-instruments`（從 detached `4cbec52d` 開出）。**未 push。**

```
$ git log --oneline -1
b4059384 The window that was registered and the window that ran were never compared

$ git show --stat HEAD
 doc/KNOWN-ISSUES.md                                |   4 +-
 .../harness/25_apps_energy.sh                      |   7 +
 .../harness/lib.sh                                 |  80 ++++++
 tests/shell/mutate_harness_instruments.sh          | 141 +++++++++++
 tests/shell/test_harness_instruments.sh            | 279 +++++++++++++++++++++
 5 files changed, 509 insertions(+), 2 deletions(-)

$ git status --short
（空）
```

commit 用**逐檔列出的 pathspec**（不是目錄），新檔先 `git add -N`；
`git diff` 已**逐 hunk 讀過**，只有這五個檔、沒有夾帶。

四個改動：

1. **`lib.sh` 新增 `assert_window_span`**（純新增，沒有既有簽名被改）。
2. **`25_apps_energy.sh:227` 之後加一行呼叫**——兩行 `info` 保留當細節，gate 是新的那一行。
3. **`tests/shell/test_harness_instruments.sh`**（34 條，6 組）。
4. **`tests/shell/mutate_harness_instruments.sh`**（12 個突變）。
5. **`doc/KNOWN-ISSUES.md` 的 G-2 row 02／row 05**（寫下時寫的是「第 1520／1523 行」，而那兩個行號已經漂進別的條目）：row 02 改 🟢、row 05 改 🟢＋寫出 09-02 找到的那一半。
   **只動這兩行的「現況」欄**，row 04（別人的）與其餘各列一個字都沒碰。

---

## 5. 測試證據（紅／綠，rc 逐一記錄，**沒有經過 pipe**）

### 5.1 紅：**最終版**測試打在**未修**的碼上

在 sandbox 裡放 `4cbec52d` 版的 `lib.sh` / `25_apps_energy.sh` / `20_apps_lifecycle.sh`，
配上**最終版**的測試檔（不是早期版本）：

```
$ bash $SB/tests/shell/test_harness_instruments.sh > $SB/red.log 2>&1; echo "RED RC=$?"
RED RC=1
$ grep -c '^  FAILED' $SB/red.log
13
$ tail -1 $SB/red.log
===== 34 check(s): 21 ok, 13 FAILED =====
```

🔑 **紅的是哪 13 條，本身就是本輪的結論**：group 4（窗口比較，9 條）、group 5（span artefact，4 條）
全紅——那是**真的還沒修的那一半**；
而 group 1／2／3（`port_holder` 三態，14 條）與 group 6 大部分**在未修的 base 上就是綠的**，
那是**獨立的第二個證據**證明 `cd440488` 的修法確實在 base 裡、KNOWN-ISSUES 的狀態是過期的。

### 5.2 綠：同一份測試打在修好的碼上

```
$ bash tests/shell/test_harness_instruments.sh; echo "SUITE RC=$?"
===== 34 check(s): 34 ok, 0 FAILED =====
SUITE RC=0
```

### 5.3 突變閘門

```
$ bash tests/shell/mutate_harness_instruments.sh; echo "MUTATE RC=$?"
===== 12 mutation(s): 12 killed, 0 survived =====
MUTATE RC=0
```

12 個突變逐一把**原始缺陷本身**種回一份 sandbox 複本（不寫工作樹的檔）：

| 突變 | 殺掉幾條 |
|---|---|
| `port_holder` 對 hidden owner 回空字串（08-30 缺陷逐字重現） | 5 |
| sentinel 改成數字（讓忘記處理的呼叫端安靜地錯） | 2 |
| `assert_port_is` 把 hidden 判成 pass 而不是 N/A | 1 |
| 拿掉 phase 裡的 span gate（回到只有 `info`） | 1 |
| OVERRUN 從判決降級成印一行 | 2 |
| UNDERRUN 給了容忍度，縮短的窗口就通過 | 3 |
| span artefact 只在 OK 時才寫 | 3 |
| artefact 裡拿掉 registered 欄 | 1 |
| viz 又用迴圈計數當時鐘（`T0 + i`） | 1 |
| watch 迴圈又改回數圈數 | 1 |
| `mark_start` 不再讀時鐘（`own` 欄塌回 `since_T0`） | 1 |
| degraded banner 失去 gate、變回永遠亮 | 1 |

### 5.4 兩個邊界路徑

```
$ ... assert_window_span w 240 abc ; echo rc=$?
  ABORT assert_window_span w: 'abc' is not a whole number of seconds. ...
rc=3
$ ... WINDOW_OVERRUN_TOL_S=300 assert_window_span w 240 474 ; echo rc=$?
  PASS  w window honoured: registered=240s actual=474s overrun=234s (tolerance 300s)
rc=0
```

### 5.5 語法

`bash -n` 對全部 9 支 harness 腳本＋兩支新測試：**全部 rc=0**。

### 5.6 🔴 **測試自己的三個 bug 是「跑出來」而不是「讀出來」的**——寫進紀錄，因為方向一致

| bug | 沒被抓到的話會怎樣 |
|---|---|
| `SS_MODE` 沒有 `export` | `ss` 是另一個行程，讀不到未 export 的變數 ⇒ shim **每次都答 `free`**。group 1／2／3 會對著**從來沒產生過它們輸入**的 shim 全綠。第一次跑就露餡（14 條紅） |
| `ASSERT_OUT="$(assert_port_is ...)"` 用了 command substitution | `FAILS` 在子 shell 裡加、然後被丟掉 ⇒「hidden 不計 FAILS」這條**無論函式做什麼都會綠**。第一次跑時它綠了，而旁邊該綠的卻紅——那個不一致才是線索 |
| group 6 grep 裸字串 `assert_window_span` | 呼叫被刪掉之後，**上面兩行的說明註解裡還有這個字** ⇒ 守衛照樣綠。**是突變閘門抓到的，review 沒抓到**（第一次 12 個突變裡有 1 個 SURVIVED） |

🔑 三個都是**讓測試看起來比實際更有效**的方向，跟 FINDING-02 兩個缺陷的方向一模一樣
（`memory: 儀器不能長得像自己的發現`）。**突變閘門是唯一抓到第三個的東西。**

---

## 6. 沒有驗證的 / 需要人做的下一步

- 🔴 **本輪一次都沒有碰 lab。** 沒跑 `ndt`（任何 subcommand，含 `--help`）、沒跑 `ndtwin-lab`、
  沒有 Mininet、沒有 fabric、沒有 claim、沒有 sudo、沒有網路。
  測試裡的 `ss` 是 PATH 上的 shim，時鐘是傳進去的參數，artefact 全在 `mktemp -d` 裡、離開時刪除。
- 🔴 **`assert_window_span` 從未在真實的一輪裡被執行過。** 它被 34 條測試與 12 個突變驅動過，
  但 `25_apps_energy.sh` 這一支**整支沒跑**（要跑就要 fabric、要 Energy-App、要 claim）。
  ⇒ 「跑過」與「讀過未執行」不混表：**這一行是讀過並被單元驅動過，不是在一輪裡跑過。**
- ⚠️ **overrun 容忍度 30 s 是從結構推出來的，不是量出來的**：一個 `sleep 10` ＋ OVS 上一次
  `graph_counts` ≈10 s。**只有 08-30 那一輪的 25 個樣本可以佐證**（平均間隔 19.8 s，但那是**修前**的迴圈）。
  下一輪 energy phase 跑完應該回頭看 `energy_watch_span.tsv` 的 `overrun_s`，如果穩定貼近 30 就把它調大。
- ⚠️ **group 6 是原始碼形狀守衛，不是行為測試**，測試檔裡自己標了。
  它擋得住「缺陷長回原來的形狀」，擋不住「用新的形狀犯同一個錯」。
- ⚠️ **`tests/shell/` 沒有集中的 runner**（每支都是手跑，既有那 20 支也一樣）。
  ⇒ 我的兩支跟著房子的命名慣例（`test_*.sh` / `mutate_*.sh`），但**沒有任何 CI 會自動跑它們**。
  要接進 CI 是人要做的決定。
- ⚠️ **`~/.local/bin/ndt` 指向主樹**，我的工作樹裡的任何改動對它無效。本輪沒改 `ndt`，
  但下一個人若在 worktree 裡改 `ndt` 要記得這件事（並讀 `NSLAB-USAGE-RULES` 與 `KERNEL_DIR` 那條）。
- ⚠️ **row 04（還原路徑）依指示沒碰。** 但兩列是耦合的：row 05 的 banner 修法**指向**
  row 04 的還原路徑，`else` 分支現在明講「不要跑」。**若 row 04 的負責人改了 `90_restore.sh` 的
  介面，`25_apps_energy.sh:313-320` 那四行指示要跟著改。**
- ⚠️ **`first_serve_epoch` 的註解說「newest file」，碼是 `sort -n | head -1`＝最舊的。**
  對 `first_serve_epoch` 來說**碼是對的、註解是錯的**（要的就是 T0 之後第一個檔）。
  一行註解的事，本輪沒改（不在指派範圍，且改它要動 `20_apps_lifecycle.sh:123`）。

---

## 7. 給 Adam 的裁決題（每題附後果）

**Q1. `WATCH_S=240` 要不要從腳本字面量升格成預註冊參數？**
現況：240 只寫在 `25_apps_energy.sh:204`，**PREREG.md 裡沒有它**，理由只在註解裡。
- **(a)〔建議〕寫進 PREREG，腳本從 `round.env` 讀。**
  後果：窗長變成可被預註冊審查的東西；`assert_window_span` 比對的「registered」有了外部來源，
  而不是跟自己比。代價：多一個設定檔欄位。
- (b) 維持現狀。後果：gate 仍然有效（它比的是同一輪內的登記值與實跑值），
  但**「登記」這件事只發生在腳本裡**，改字面量就等於改登記，沒有痕跡。

**Q2. overrun 超標要判 `bad`（紅）還是 `skip`（N/A）？**
我選了 `bad`。
- **(a)〔建議〕`bad`。** 後果：一輪會因為「比登記的更有耐心」而變紅。
  這是刻意的——紅的不是那個發現，是**報告裡的數字**，而 08-30 正是報告說了 240。
- (b) `skip`。後果：不會有假警報，但「N/A」的語意是「搆不到」，
  而窗口跑超過是**判定得出來**的事實 ⇒ 會弄壞 `skip` 這個字在這個 harness 裡的意思。
- (c) 只有 underrun 判紅、overrun 只 `info`。後果：**回到現況的一半**，報告仍可能寫錯數字。

**Q3. KNOWN-ISSUES row 02／05 我已經改成 🟢，這個改動要不要留？**
- **(a)〔建議〕留。** 後果：ledger 說實話。代價：若 row 04 的負責人同時在改同一個表，
  會有一次單行 merge conflict（兩列不同行，衝突面很小）。
- (b) 回退，只在本文件記錄。後果：ledger 繼續對兩個已修的缺陷說「已開工單」，
  下一個讀它的人會重做一次我這一輪前半段的考古。

**Q4. group 6 的原始碼形狀守衛要不要保留？**
- **(a)〔建議〕保留並維持「這是形狀守衛」的標籤。**
  後果：擋得住 12 個突變裡的 4 個，而且是唯一能對「出貨的那個檔」發言的方式。
- (b) 換成 extracted-logic fixture（T-10 驗收當時的做法）。
  後果：變成行為測試，**但測的是複本**——這個 repo 已經為此付過一整輪的代價。

**Q5. 這一輪要不要順手把 `first_serve_epoch` 那行說謊的註解修掉？**（§6 最後一條）
- (a) 修。後果：多動一個檔，跨出指派範圍。
- **(b)〔建議〕不修，登記成一張小票。** 後果：註解繼續說謊一陣子，但它不影響任何數字。

