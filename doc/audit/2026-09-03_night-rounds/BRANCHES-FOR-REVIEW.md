# 待審分支一覽（每支一頁，約十分鐘可裁決）

2026-09-03 夜巡整理。基準：`trunk` = `128bfc6b`。
[Co-developed with claude code -- Adam]

---

## 讀之前先知道的六件事

**1. 是 6 支，不是 8 支。** `git branch --list 'fix/*' --no-merged trunk` 回的就是這六支：

```
fix/b5-kernel-shutdown          fix/g6-ndt-apps-liveness      fix/g9-cleanup-no-pkill-f
fix/flow-rate-denominator       fix/g7-ndtwin-lab-config      fix/l9-make-topology-stdout-json
```

交辦單預期的 `fix/flow-rate-divide-by-zero` **已經併進 trunk**（它出現在 `--list 'fix/*'`
但不在 `--no-merged` 裡），所以不在本文件。其餘 17 支 `fix/*` 也都已併入。

**這六支全部寫完了，沒有「未整理」的分支。** 若下面看不到某支，那是它不存在，
不是我沒看——這兩件事不可以混為一談。

**2. 排序規則。** 提權面 ⇒ 關機語意 ⇒ 退出碼契約 ⇒ 數值。不是按完成度排。

**3. 「至少三支動 `tools/test_workflow/ndtwin-lab`」——實際上是兩支**（G-7、G-9）。
真正的三方碰撞在別的地方：**G-6／G-7／G-9 三支各自在 repo 根目錄新增一份自己的
`RATIONALE.md` 與 `NEXT.md`**，trunk 上這兩個檔不存在。三份內容完全不同。實測：

```
$ git merge-tree --write-tree --messages fix/g9-cleanup-no-pkill-f fix/g7-ndtwin-lab-config
CONFLICT (add/add): Merge conflict in NEXT.md
CONFLICT (add/add): Merge conflict in RATIONALE.md
CONFLICT (content): Merge conflict in tools/test_workflow/ndtwin-lab
```

G-6×G-7 與 G-6×G-9 也各有 `RATIONALE.md`／`NEXT.md` 兩個 add/add 衝突。
🔴 **這種衝突最危險的解法是「留一份」**——那會靜默丟掉另一支的全部裁決依據。
合併前要決定這兩個檔要不要改名進 `doc/`。

**4. 「未重裝前不改變任何行為」這句話今天是真的，我查過。**

```
$ sha256sum /usr/local/sbin/ndtwin-lab
288b71cb8ccc7c9472f4229d46c5fe1408592ede091be180536ed65676b0ce4c
$ git show trunk:tools/test_workflow/ndtwin-lab | sha256sum
288b71cb8ccc7c9472f4229d46c5fe1408592ede091be180536ed65676b0ce4c
```

兩份**現在**逐位元相同。G-7 與 G-9 任一支併入，這個等式就破了，而 root 跑的是安裝的那份。

**5. 🔴 六支裡只有 B-5 把閘門原始輸出 commit 進 repo**
（`doc/audit/2026-09-02_live-round/raw/b5-fix/mutation_gate.log` 等九個檔）。
**其餘五支的 `N mutations, M survived` 只以散文形式抄在 RATIONALE／commit message 裡，
分支上沒有可對帳的原始輸出**。閘門**腳本**都有 commit、可重跑，但「它跑出過那個結果」
在這五支上是**作者宣稱**，我無法從分支本身驗證。下面每一頁的第 3 節都重述這一點。

**6. 每一頁的「行為變更」引文都是我從 diff 本身抄的**，不是從 RATIONALE 轉抄。
RATIONALE 與 diff 不一致的地方，我在該頁標成 🟠。

---
---

# 1／6 — `fix/g9-cleanup-no-pkill-f`

6 commits｜base `6283ff5e`｜動 `tools/test_workflow/ndtwin-lab`、`tools/test_workflow/faults.sh`

## 1. 一句話

把 `ndtwin-lab cleanup` 裡四個全機器範圍的 `pkill -f`（以 root 執行）換成
「ps 當索引、`/proc/<pid>/cmdline` 當權威、argv **元素**要**是**那支程式」的掃除，
並讓掃不乾淨時**回非零**。

## 2. 🔴 行為變更前後對照

**🔴 最該先看的一條：`cleanup` 從「結構上不可能失敗」變成「會失敗」。**
舊版每個 kill 都 `|| true`、最後一行無條件 `echo "cleanup done"`。diff 自己寫著
（`tools/test_workflow/ndtwin-lab`，cleanup 區塊）：

```
-        pkill -f ntg_bmv2_topo.py 2>/dev/null || true
-        pkill -f p4_testbed_topo.py 2>/dev/null || true
-        pkill -f "Network-Traffic-Generator/testbed_topo.py" 2>/dev/null || true
+        # G-9: four `pkill -f ... 2>/dev/null || true` became four verified sweeps. The
+        # `|| true` was load-bearing in the old form and is gone on purpose: "nothing matched"
+        # and "I could not kill what matched" were the same rc, so `cleanup` could not fail.
+        rc=0
+        sweep_kill "ntg_bmv2_topo"  ntg_bmv2_topo.py  || rc=1
...
-        echo "cleanup done"
+        if (( rc == 0 )); then
+            echo "cleanup done"
+        else
+            echo "cleanup INCOMPLETE -- something above survived TERM and KILL" >&2
+            exit 1
+        fi
```

其餘明天看得到的差異（RATIONALE §3 的表，我逐條對過 diff，全部成立）：

| 情境 | 修法前 | 修法後 |
|---|---|---|
| `cleanup`，機器乾淨 | 靜默，印 `cleanup done` | 印四行 `none <label>`，再 `cleanup done` |
| `cleanup`，有一座 orphan 交換機 | 靜默 | `stopped        simple_switch_grpc pid 12345` |
| 有東西扛過 TERM＋KILL | `cleanup done`，**rc 0** | `STILL RUNNING …` ＋ `cleanup INCOMPLETE`（stderr），**rc 1** |
| 操作者的 shell argv 含 pattern | **那個 shell 被殺** | 不受影響 |
| 旁邊有 `tail -f xxx.py.log` | **被殺** | 不受影響 |
| `ndtwin-lab status`，空機器 | `bmv2: 1`（`pgrep -c -f` 算到自己） | `bmv2: 0` |

`faults.sh`（本分支第二個 commit）：新增 `--topo-pid` 子命令；usage 字串多一項
（`{list\|run <ID>\|run-all\|--topo-pid [script]}`）；`:60` 註解與 `:318` 附近的 `err` 建議
從 `$(pgrep -f '[t]estbed_topo.py'|head -1)` 改成 `$(bash $0 --topo-pid)`。
找到兩個候選時**拒絕並說出兩個 pid**，rc 1。

**🔴 提權面的一個實際改動**（RATIONALE 只把它列成「測試用的縫」，我認為它應該被當成
安全項讀）：root guard 現在可以被繞過——

```
-if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
+if (( NDTWIN_LAB_SOURCED == 0 )) && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
```

`NDTWIN_LAB_SOURCED` 由 `(return 0 2>/dev/null) && NDTWIN_LAB_SOURCED=1` 決定。
作者的論證是「sudo 一律 exec、不 source，所以已安裝的 root 路徑走的分支沒變」——
**這個論證我讀了 diff 認為成立**，但它把「這個檔在非 root 下不執行任何動詞」從
一道 `die` 降級成一個變數的正確性。

**🔴 廣度沒有縮小。** `cleanup` 仍然掃全機器；別輪的 bmv2 仍然是它要收的目標。

## 3. 閘門證據

作者記錄兩把閘門，**兩把的輸出都只以散文抄在 RATIONALE §4 與附錄，分支上沒有 raw log**：

- `tests/shell/mutate_g9_cleanup_no_pkill_f.sh` — **6 mutations, 0 survived**
  （`control-comment-only SURVIVED (control, as required)`）
- `tests/shell/mutate_g9_faults_topo_pid.sh` — **4 mutations, 0 survived**（同樣有 control）

**有沒有對著未修的碼看過紅？** 有，而且是設計上的：六個變異各自「把一種 `pkill -f` 的
失敗模式放回去」（`match-anywhere-in-line`、`no-self-exclusion`、`count-includes-the-counter`…）。
**閘門形狀是這六支裡最好的一把**：只註解的對照組存活，且每個變異記錄的是**哪一個具名檢查**
變紅，不是「有東西紅了」。作者還記下閘門抓到自己兩個假綠（`no-self-exclusion` 與
`self-is-only-this-pid` 一開始都存活）。

🔴 **但它斷言的是作者發明的命令列，不是真的 bmv2。** 作者自己在 §「這支分支還沒被真實資料
驗過什麼」寫：

> `sweep_matches` 的每一個測試輸入都是我自己發明的命令列（fixture 的 argv0、手寫的假 ps 行），
> **沒有一個抽自真的 bmv2／topology**。

⇒ 若真的 `simple_switch_grpc` 的 argv 形狀與假設不同，`sweep_find` 會**安靜地找不到它**，
而 cleanup 會回報 `none simple_switch_grpc`。作者把 **L2（起一座真 bmv2、先印 argv 再 cleanup）
列為合併的必要條件，不是加分項**。我同意這個定位。

## 4. 合併順序與衝突

- **與 G-7 硬衝突**，同檔 `tools/test_workflow/ndtwin-lab`，且兩支都：在 `set -euo pipefail`
  之後加同名的 `NDTWIN_LAB_SOURCED`、改同一行 root guard、在 `case` 之前加 sourced-return、
  改 `status` 分支、改 usage 字串。實測 `merge-tree` 三個衝突（含 `RATIONALE.md`／`NEXT.md`）。
- **auditor 已裁 G-9 → G-7 → `fix/ndt-sudo-surface`**（記在 G-7 的 `NEXT.md`），G-7 rebase。
- 🟠 **兩支對 `status` 那一行的意見不同**：G-9 把 `pgrep -c -f simple_switch_grpc` 換成
  `sweep_count`；**G-7 原樣留著 `pgrep -c -f`** 並在它上面多插一行 config 資訊。
  先併 G-9 再 rebase G-7，這個衝突要人工判：**留 G-9 的 `sweep_count`**，否則
  「空機器報 bmv2: 1」會被 G-7 帶回來。
- 與 B-5／G-6／flow-rate／L-9 **無檔案交集**（只有根目錄兩份 md 與 G-6 撞）。

## 5. 回退方式

兩個獨立 commit：`82df654f`（sweep）與 `586e56b4`（faults.sh），**各自 `git revert` 即可，
可單獨退**。沒有資料格式改變。已安裝的 `/usr/local/sbin/ndtwin-lab` 沒被動過 ⇒ 回退不需要重裝。
`99349aa5` + `81519ad8`（`NEXT.md`）是**刻意可單獨 drop 的一組**，NEXT.md 開頭就寫著
「這個 commit 可以單獨 drop，不影響 G-9 的修法」。`e245ccf6`／`6136c3bc` 只動 RATIONALE。

## 6. 未處理（作者原話）

> 🔴 **這一族裡最危險的兩個，都不在這支分支裡**（auditor 2026-09-02 裁決）：
> `p4_proxy/mininet/p4_testbed_topo.py:658` — `os.system('sudo pkill -f simple_switch_grpc …')`、
> `p4_proxy/mininet/ntg_bmv2_topo.py:98` — 同一行。
> **為什麼是最危險的**：這兩個在**拓樸啟動路徑**上，而 `pkill -f simple_switch_grpc` 是
> **全機器範圍**的——所以**一輪的拓樸啟動會殺掉另一輪正在用的 fabric**。
> **為什麼今晚不能改**：這兩個檔在**共用工作樹**裡，而整晚的測試輪一輪接一輪在執行它們。

> **這支分支沒有修的那一半**：`doc/KNOWN-ISSUES.md:2164`「`ndtwin-lab cleanup` 可能殺掉
> 呼叫它的 shell（內部跑 `mn -c`）」那是 `mn -c` **自己內部**的 `pkill -9 -f`，
> 我把 `mn -c` 原樣留著 ⇒ **所有腳本的 `setsid` 紀律仍然必要**。

> **沒有動任何一個呼叫端**——這是清單，不是修法。（RATIONALE 附錄二盤點：產品碼兩處
> `ndt:638`（rc **完全丟棄**）、`ndt:1083`；audit 腳本六處以上，全是 `|| true`。）
> `ndt:638` 與 `ndt:1083` 的原文我逐行對過 trunk，**引用正確**。

---
---

# 2／6 — `fix/b5-kernel-shutdown`

7 commits｜base `72fdc5b0`｜C++ 兩檔 ＋ `stack.sh`、`supervise.sh`(新)、`check_logs.py`

## 1. 一句話

`DeviceConfigurationAndPowerManager::stop()` 漏 join 第三個 worker，導致 kernel **每一次
乾淨關機都 SIGABRT**（134）；補上 join 與解構子，並順帶讓 stack 記錄／回報每個 component 的死法。

## 2. 🔴 行為變更前後對照

**這支分支有 7 個 commit，行為變更集中在其中一個，其餘是修正與證據。**

**(a) C++ 修法本身：低風險，但慢。**
`src/.../DeviceConfigurationAndPowerManager.cpp` 新增 `~DeviceConfigurationAndPowerManager()
{ stop(); }` 與 `if (m_openflowTablesUpdateThread.joinable()) { m_openflowTablesUpdateThread.join(); }`。
`main.cpp:314` 我親自查了 trunk：**整支 `main.cpp` 只有 `std::signal(SIGINT, handleSigint);`
一行 signal 註冊，沒有 SIGTERM**，所以作者「`ndt down` 走不到這段碼」的前提成立。

作者原話：

> **Risk: LOW.** No caller's behaviour changes. `ndt down` still produces 143, every log line is
> what it was, and the only observable difference is that a process which used to abort now exits 0.

🔴 **但它引入的成本被作者自己量到並寫下來了**：

> Six of seven are seconds. The seventh is the answer, and it is the unwelcome one.
> … **post_int_busy_1 / requests in flight / 81.09 s**
> Every one of those 79 seconds is spent **inside the join this fix added** …
> **Ctrl-C, the operator's path: up to ~80 s**, where it used to be an instant abort.

**(b) 🔴 `commit cb639254` 是唯一會讓一個原本不會失敗的命令開始失敗的一個。**
`tools/test_workflow/stack.sh`，`cmd_down` 末尾新增：

```bash
+    if [[ -n "$STACK_FATAL_ENDINGS" ]]; then
+        err "  teardown itself worked, but something crashed rather than stopped:"
+        err "    $STACK_FATAL_ENDINGS"
+        err "  Reported once -- the durable record is $PID_DIR/<component>.exit.log."
+        return 1
+    fi
```

判準寫死在 `fatal_exit_status()`：

```bash
+    case "$1" in
+        132|134|135|136|137|139) return 0 ;;
+        *) return 1 ;;
+    esac
```

**143（SIGTERM，今天每一次健康 teardown 的正常碼）與 130（Ctrl-C）刻意不在裡面。**
137（systemd-oomd）刻意在裡面。作者自己標：

> **This is the piece to review before merge**, because it is the only change here that can make
> a command fail that did not fail before.

**(c) 另外兩個會被看見的：**

- `start_bg` 現在透過新的 `tools/test_workflow/supervise.sh` 啟動每個 component。
  記錄的 pid 仍是 process-group leader（`stop_one` 的 `kill -TERM -$pid` 與
  `port_owner_verdict` 的 pgid 比對照舊）；實際幹活的 pid 另寫到 `<name>.child.pid`。
  supervise.sh 不存在或不可執行時**只 warn 不拒絕**。
- 🔴 **kernel 改成 `exec ./bin/ndtwin_kernel …`**，diff 自己標了副作用：
  「This changes the recorded command string, so the first `up` after this change **restarts a
  kernel that is already running**」。

**(d) `check_logs.py` 的 `CRASH_PATTERNS` 加了 12 個 fatal 訊息**，其中包含 shell 的
`<pid> Killed`（SIGKILL／systemd-oomd）與 B-5 自己的 `terminate called without an active exception`。
這是**放寬偵測**，方向是讓原本會綠的 log 變紅——對既有 audit log 重跑會有新的紅。

## 3. 閘門證據

**六支裡唯一把 raw 輸出 commit 進 repo 的一支**，我打開對過：

`doc/audit/2026-09-02_live-round/raw/b5-fix/mutation_gate.log` 末行：

```
mutations: 3   survivors: 0
✅ every mutation was caught.
```

**它斷言的是 shape，不是那一行。** 第 3 個變異是「加一個**第四個** worker、start 但不 join」，
gate log 記著它被 `AStoppedManagerIsDestroyedWithoutAborting` 抓到。作者：

> Under a test that asserted "the openflow thread is joined", mutation 3 would have passed —
> a new worker, a new hole, a green suite. That is the exact sequence that produced B-5.

**對著未修的碼看過紅？** 有，三種：
1. 變異 1 就是「B-5 as it shipped」；
2. `check_logs.py`：同一個測試指向兩個版本，`HEAD` 32 checks **12 failed**，本分支 0 failed，
   紅跑存在 `raw/b5-fix/test_crash_patterns_vs_HEAD.red.txt`；
3. `stop_one`：`HEAD` 5 checks **4 failed**（我打開讀了 `test_stop_one_vs_HEAD.red.txt`，
   末行確為 `Ran 5 checks, 4 failed`）。

🔴 **兩個閘門缺口，要當成風險讀：**
- **變異閘門只涵蓋 C++ 那半。** 唯一的 `mutate_*.sh` 是
  `mutate_b5_power_manager_shutdown.sh`，target `test_routing_strategy`、filter
  `PowerManagerShutdownDeathTest.*`。**(b) 那個「讓 `down` 失敗」的行為變更沒有變異閘門**，
  只有 `tests/shell/test_supervise_exit_status.sh`。
- **這把閘門沒有 control 變異**（G-6／G-7／G-9 三支都有 `control-comment-only SURVIVED`）。
  它有一個測試層級的 instrument control（`DestroyingAJoinableThreadIsVisibleToThisHarness`），
  但閘門本身沒有示範過「它會報 SURVIVOR」。
- 🟠 **報告自己前後矛盾**：§7 先寫
  「asserted in `tests/shell/test_supervise_exit_status.sh` (**39 checks**)」，
  同節結尾又寫「Covered by `tests/shell/test_supervise_exit_status.sh` (**22 checks**)」。
  我數了該檔的 check 呼叫點是 24 個（實際跑出的數字視迴圈而定）。**兩個數字至少有一個錯。**

## 4. 合併順序與衝突

- **與其餘五支零檔案交集**（連根目錄的 `RATIONALE.md`／`NEXT.md` 都沒用到——它把文件寫在
  `doc/audit/2026-09-02_live-round/` 底下，這是六支裡最不會撞的一支）。
- 內部順序：`0502eff9`（記錄死法）必須在 `cb639254`（依死法讓 `down` 失敗）之前。
- 與 G-6 **語意上**相關而非檔案上：G-9 的 `NEXT.md` 已裁「`ndt down` 的退出碼要跟
  `ndt apps stop` 同一套三態語意（0／1／2），**兩支不一致比兩支都錯更糟**」。
  B-5 只做 0／1，G-6 做 0／1／2 ⇒ **兩支都併之後，`ndt down` 與 `ndt apps stop` 的碼不同套。**

## 5. 回退方式

commit 1、2、3、5 是修正與證據；**`cb639254` 是唯一需要 Adam 點頭的那一個，且可單獨
`git revert`**——它只動 `stack.sh` 與 `test_supervise_exit_status.sh`。
作者自己列在 §10「Still open」：

> **Merge order.** Commits 1, 2, 3 and 5 are corrections and evidence; commit 6 (the exit-code
> behaviour change) is the only one that needs a policy decision from Adam before it lands.

⚠️ `0502eff9`（supervise.sh + `exec`）與 `cb639254` 有相依：先退 `cb639254` 保留記錄是可以的，
反過來不行。C++ 那兩檔的修法（`4203d857`）獨立，可單獨保留或單獨退。
**C++ 改動要重編才生效**——未重編前 `build/bin/ndtwin_kernel` 行為不變。

## 6. 未處理（作者原話）

> **What was deliberately NOT done here**: Registering a SIGTERM handler would make `ndt down`
> run the clean shutdown for the first time. That is a change of shutdown *semantics*, not a
> correctness fix … including `ApplicationManager::cleanupNFS`, which unmounts NFS paths and can
> block. … The handler belongs on its own branch (`fix/b5-sigterm-clean-shutdown`), **behind a
> bounded poll**, with Adam's decision — not inside a correctness fix.

> **`tests/shell/check_gate_anchors.py`** does not yet know this gate's `edit <file> <anchor>
> <repl>` helper shape, so the new gate's anchors are not covered by the anchor-rot checker.

> **The bounded poll** … as the first commit of the SIGTERM branch.（理由：`stop_one` 等 10 s
> 就 SIGKILL，而乾淨路徑實測要 79 s ⇒ 只加 handler 會把「一定瞬間死」變成「等 10 秒後照樣死」。）

---
---

# 3／6 — `fix/g7-ndtwin-lab-config`

3 commits｜base `6283ff5e`｜動 `tools/test_workflow/ndtwin-lab`、`test_ndt_lab_session.sh`

## 1. 一句話

讓 `ndtwin-lab` 的 `KERNEL_DIR` 可以由一份**只有 root 能寫**的 `/etc/ndtwin-lab.conf` 決定
（不是 env），並新增 `config` 子命令回答「我現在要跑哪棵樹」。

## 2. 🔴 行為變更前後對照

**🔴 未重裝前，這支不改變機器上的任何行為**（見開頭第 4 點：兩份現在逐位元相同）。
**這是它被放上分支而不是 trunk 的理由之一，但不是全部**——即使重裝了，沒有
`/etc/ndtwin-lab.conf` 的機器行為也**逐位元不變**，因為四個預設值原樣搬進 `LAB_DEFAULT_*`：

```
+LAB_DEFAULT_KERNEL_DIR=/home/adam/Desktop/NDTwin-Kernel
+LAB_DEFAULT_NTG_PY=/home/adam/miniconda3/envs/ntg-env/bin/python
+LAB_DEFAULT_ENERGY_DIR=/home/adam/Energy-Saving-App
+LAB_DEFAULT_SIM_DIR=/home/adam/Simulation-Platform-Manager
```

**重裝之後看得到的（我從 diff 抄的，不是從 RATIONALE）：**

| 情境 | 修法前 | 修法後 |
|---|---|---|
| `ndtwin-lab status` | 直接 `$TMUX list-sessions` | 第一行多印 `config: %s (KERNEL_DIR=%s)` |
| `ndtwin-lab topo-start` | `topo session started (attach: …)` | `topo session started from $KERNEL_DIR (attach: …)` |
| `ndtwin-lab config` | 不存在（`die usage:`） | 新子命令，印 6 行：`config:`／`KERNEL_DIR:`／`BRIDGE:`／`NTG_PY:`／`ENERGY_DIR:`／`SIM_DIR:` |
| usage 字串 | `…\|status}` | `…\|status\|config}` |
| 設定檔存在但不可信、跑 `status`／`config` | — | **照跑**（唯讀），先把理由與 `sudo rm` 指令印到 stderr |
| 設定檔存在但不可信、跑其他動詞 | — | **`die`**：`refusing to run '$1' with a config file that cannot be trusted.` |
| `export KERNEL_DIR=…` | 無效 | **仍然無效**（有測試釘住） |

**🔴 這是提權面的改動，即使作者論證它沒有新增提權類別。** 作者的論證我讀完認為成立，
而且他自己把界線寫得很清楚（新檔頭）：

> 🔑 Stated plainly so nobody reads more safety into this than it has: the DEFAULT KERNEL_DIR is
> /home/adam/Desktop/NDTwin-Kernel, which is adam-writable. Root has therefore been executing
> an adam-writable .py since this script was written. That is the status quo, not something
> introduced here … Making the executed tree itself root-owned is a separate decision and is
> **NOT made here**.

信任檢查是三個述詞：`lab_conf_dir_trusted`（目錄 owner==0、非 group/other-writable）→
`lab_conf_file_trusted`（拒 symlink、須 regular file、owner==0、非 group/other-writable）→
`lab_config_parse`（**parse 不 source**、只認四個鍵、絕對路徑、禁 `..`、`KERNEL_DIR` 必須存在
且含 `p4_proxy/mininet/ntg_bmv2_topo.py`）。**目錄先於檔案**，理由寫在碼裡。

**🔴 一個既有測試被本分支改了**：`tools/test_workflow/test_ndt_lab_session.sh` 新增 4 條
（含一條 near-miss：`KERNEL_DIR=/home/adam/topo:2`）。作者的理由是那個檔宣稱涵蓋
「`ndtwin-lab status` 能產生的每一種形狀」，不加那句宣稱就變成假的。**這是補強不是放寬。**

**🟠 一個 diff 層級的缺陷（RATIONALE 沒提，我從 diff 讀到）**：新檔頭裡有兩段註解
**各被貼了兩次**——「Three predicates, not one, and the reason is the mutation gate: …」與
「🔑 THE DIRECTORY IS JUDGED BEFORE THE FILE, …」在 `lab_conf_dir_trusted` 之前重複出現。
不影響行為，但這是一個安全相關檔案的檔頭，合併時應該清掉。

## 3. 閘門證據

`tests/shell/mutate_g7_ndtwin_lab_config.sh` — **14 mutations, 0 survived**，
`control-comment-only SURVIVED (control, as required)`。測試
`tests/shell/test_ndtwin_lab_config.sh` 59 checks。
**輸出只以散文抄在 RATIONALE §5，分支上沒有 raw log**（見開頭第 5 點）。

**「對著未修的碼看過紅」在這支上要小心讀。** 這支的「未修的碼」**根本沒有 config 概念**，
所以閘門不可能對著它紅——它證明的是「每一道**新加的**檢查各自拔掉會紅」，加上一個
`default-tree-changed` 變異釘住「沒有設定檔時的 `KERNEL_DIR` 仍是 G-7 之前的那個」。
**這是這支能做到的最強形狀，但它不同於 G-9／B-5／L-9 那種「還原出貨缺陷」。**

**閘門的品質證據很強**（作者記下四件讀碼看不出來的事）：

> 1. `no-owner-check`、`symlink-allowed` 兩個變異**存活**——被目錄檢查擋在前面，
>    檔案層的斷言其實一條都沒被執行到。→ 拆成三個述詞。
> 2. 刪掉 symlink 拒絕，symlink 還是會被拒（`stat` 不解參考、link 是 mode 777）⇒
>    明確的 symlink 檢查**不改變 rc**，它買到的是「說出理由」。**斷言因此寫在訊息上。**
> 4. `source ndtwin-lab` 會把 `set -e` 帶進測試 ⇒ 套件會中途離開卻仍把已跑過的每一條印成 `ok`。

## 4. 合併順序與衝突

- 🔴 **與 G-9 硬衝突**（同檔、同區塊）。auditor 已裁 **G-9 → G-7**，G-7 rebase。
- 🟠 **兩支對 `status` 的 `pgrep -c -f simple_switch_grpc` 意見相反**（見 G-9 那頁第 4 節）。
- 根目錄 `RATIONALE.md`／`NEXT.md` 與 G-6、G-9 三方 add/add 衝突。
- G-7 的 `NEXT.md` 宣告下一支 `fix/ndt-sudo-surface` **從本支的頭長出去**：
  「合併順序 auditor 已裁：**G-9 → G-7 → 這一支**」。

## 5. 回退方式

🟠 **RATIONALE §6 說「單一 commit，`git revert`」——這句話已經過期。**
分支實際有三個 commit：`19eccb91`（修法）、`ce4d5b02`（`NEXT.md`）、
`739121fb`（09-03 依 auditor 裁決把 `status`／`config` 從「一起鎖掉」改成「放行並喊」）。
§5 的內文有更新到 `739121fb`（第 3 條寫著「2026-09-03 依 auditor 裁決改掉一半」），
**但 §6 的回退句沒有跟著更新**。實際上：`739121fb` 可單獨 revert（回到「不可信就整支失敗」），
`ce4d5b02` 可單獨 drop。已安裝的 `/usr/local/sbin/ndtwin-lab` 沒被動過 ⇒ 回退不需要重裝、
不需要碰 sudoers。

## 6. 未處理（作者原話）

> 讓被執行的樹本身變 root-owned 是另一個決定，這次沒做。

> **待 live 驗證**（需要 root／真 lab，claim 在 auditor 手上）
> L1 `sudo ndtwin-lab config` 在**沒有**設定檔時印出四個預設值。
> L2 裝一份指向 worktree 的設定檔，`config` 與 `topo-start` 都要顯示那棵樹。
> L3 故意裝一份 adam-owned 的，確認被拒絕且訊息說得出理由。
> L4 重現 FINDING-01 的情境：worktree 128／主樹 4，確認現在**看得見**是哪棵樹。

> **合併時要把「重裝並重新確認兩份 byte-identical」寫成一個步驟**——那個「兩份逐位元相同」
> 原本是個安全性質：它讓「我讀的是不是 root 會執行的那份」有一個一秒鐘的答案。

---
---

# 4／6 — `fix/g6-ndt-apps-liveness`

5 commits｜base `6283ff5e`｜動 `tools/test_workflow/ndt`（單一 commit）

## 1. 一句話

`ndt apps <name>` 的 start 讀的是 tmux「session 建好了沒」而不是「程式活著沒」、
stop 對從沒啟動過的東西無條件回報成功；改成用 `/proc` 掃描驗活，並把退出碼從兩態改成三態。

## 2. 🔴 行為變更前後對照

**🔴 最該先看：`ndt apps stop` 的退出碼從 0／1 變成 0／2／1。** 契約寫進 `app_stop` 檔頭：

```
+# 🔴 EXIT CODES (G-6, 2026-09-02). Three outcomes, three codes …
+#     0  it was running, and it is not now
+#     2  there was nothing to stop -- earned by a scan, not inferred from a missing pidfile
+#     1  it could not be stopped, or the pidfile was poisoned, or the app is unknown
+#
+# 2 rather than 0 for the no-op is the user-visible behaviour change here: `ndt apps stop <app>`
+# on an app that is not running used to exit 0. Scripts that treat any non-zero as failure will
+# now see a failure where they saw success; scripts that only ever asked "did this work" want
+# `rc != 1`.
```

`cmd_apps stop` 的聚合也改了，diff 自己寫：

```
+            # `ndt apps stop all` on an idle machine therefore exits 2 rather than 0. That is the
+            # point: D1 (2026-09-02) recorded APPS_STOP_ALL_RC=0 from a teardown that stopped
+            # three of five and reported the same code it would have reported for zero of five.
```

明天打同樣指令看得到的（RATIONALE §3，我逐條對過 diff）：

| 情境 | 修法前 | 修法後 |
|---|---|---|
| `ndt apps sim`，binary 不存在／秒死 | `ok sim started (tmux: sim)`，**rc 0** | `XX sim did not start …`＋指向 `sim-out`，**rc 1** |
| `ndt apps stop sim`，從沒起過 | `ok sim stopped`，rc 0 | `sim not running (no live process carries its signature)`，**rc 2** |
| `ndt apps stop te`，沒在跑 | `te not running`，**rc 0** | 同樣的話，**rc 2** |
| `ndt apps stop all`，機器閒置 | rc 0 | **rc 2** ＋ `nothing to stop (5 app(s) were already not running)` |
| `ndt apps stop all`，五個裡一個在跑 | rc 0 | rc 0 ＋ `stopped 1; 4 were already not running` |
| energy 在 lab session 外面跑著 | `ndt apps` 顯示 `-`；`stop` 回 `ok energy stopped` rc 0 | 顯示 `ORPHAN`；`stop` 印 STILL RUNNING、列 pid、**rc 1** |
| `ndt apps sim` 成功時 | 立刻回 | **最多多花 5 秒**才判定（成功就立刻回） |

`ndt down` 內部也改了，只把 rc 1 當失敗、rc 2 印成 `"$a had already exited"`。

🔴 **repo 內只有 `ndt down` 是「非 0 即失敗」的呼叫端，已改。repo 外的 driver script
（產生 `APPS_STOP_ALL_RC` 的那支）沒改**——作者明寫要 Adam 決定。

**🔴 兩條既有測試被本分支改動**（作者主動列出，我逐字對過 diff）：

```
-check "nothing running -> rc 0"                   0 "$rc"
+check "nothing running -> rc 2 (was 0 before G-6)" 2 "$rc"
-check "stale pidfile naming a stranger -> rc 0"   0 "$rc"
+check "stale pidfile naming a stranger -> rc 2"   2 "$rc"
```

作者的定位是「它們是**舊契約寫在哪裡**的證據，不是被弄鬆的測試」。
**我讀了 diff 同意**：兩條的其餘斷言（訊息內容、pidfile 是否被丟棄、陌生行程是否還活著）
一條都沒動，只有 rc 那一格改了，而且加了註解說明。

## 3. 閘門證據

`tests/shell/mutate_g6_apps_liveness.sh` — **5 mutations, 0 survived**，
`control-comment-only SURVIVED (control, as required)`。
測試 `tests/shell/test_ndt_apps_liveness.sh` 44 checks、既有
`tests/shell/test_ndt_app_orphans.sh` 52 checks。
**輸出只以散文抄在 RATIONALE §4，分支上沒有 raw log。**

**對著未修的碼看過紅？** 有：「五個變異各自把**修法前的原文**放回去」，且每個變異記錄的是
**哪一個具名檢查**變紅（`start-reads-request-rc` → `start of an app that never came up -> rc 1`，
`aggregate-or-rc1` → `nothing was running -> rc 2` …）。這是好形狀。

**它斷言 shape 還是那一行？** 兩者之間：狀態機四格（session×掃描）都有變異守著，
但 `probe-session-only` 這個變異守的是舊行為的還原，不是「未來新增第五種 witness」。

🔴 **這支的最大限制由作者自己寫出來，而且說得比閘門結果重要：**

> **這是結構上的安全，不是我測出來的安全**——我的 fixture 一樣是自己發明的。

他能指出 energy／sim **為什麼不可能**長成 viz 那個形狀（兩者都是 ELF 執行檔，存活者自己帶
signature），但同時把那個論證的邊界劃出來：

> `file` 說它是 ELF，**只排除掉 shell wrapper 那一種形狀**……它**不排除**一個 ELF 自己
> fork 出真正幹活的行程然後退場。我能排除前者是因為那是**具體機制**；後者我**只是沒有證據
> 說它會發生**——那不是論證，是沒看過。

⇒ **L5（起真的 energy／sim、印出完整 argv 與子行程存進 audit-raw）被列為合併前必要條件。**

## 4. 合併順序與衝突

- **與 B-5、G-7、G-9、flow-rate、L-9 在程式碼檔案上零交集**（只動 `tools/test_workflow/ndt`）。
- 根目錄 `RATIONALE.md`／`NEXT.md` 與 G-7、G-9 三方 add/add 衝突。
- 🔴 **語意順序**：G-9 的 `NEXT.md` 已裁「`ndt down` 的退出碼要跟 `ndt apps stop` 同一套
  三態語意，**兩支不一致比兩支都錯更糟**」。B-5 給 `ndt down` 的是 0／1，G-6 給
  `ndt apps stop` 的是 0／2／1 ⇒ **兩支都併之後兩個命令不同套**，這是要一起裁的一題。
- 無硬性先後，但若 G-6 先併，B-5 的 `cmd_down` 應該一起補第三態。

## 5. 回退方式

🟠 **RATIONALE §5 寫「單一 commit，`git revert` 即可」——嚴格說分支有 5 個 commit**，
但**碼的改動確實只在 `bc064f10` 一個**（其餘：`84b99012` 只動閘門腳本、
`81b97284`／`212c2cef` 只動 RATIONALE、`e83ef1d1` 只加 `NEXT.md`）。所以那句話對「修法」成立、
對「分支」不成立。`e83ef1d1`（NEXT.md）開頭自己寫「**這個 commit 可以單獨 drop，
不影響 G-6 的修法**」。

作者另外給了一條**部分回退**路徑：

> 若只想退掉退出碼那半（保留 start 驗活），revert 後重新 apply `app_start`／`app_wait_started`
> 兩個 hunk 即可——它們與 rc 契約沒有相依。

## 6. 未處理（作者原話）

> 🔴 **G-6 沒有修這個，而且不要把「兩個 witness」讀成修了它**（viz 的 orphan JVM）。
> `app_sig viz` 是 `network_traffic_visualizer.sh` ——**存活下來的那兩個 java 的 cmdline 裡
> 不會有這個字串**，所以 `app_scan_pids viz` 在結構上找不到它們。

> 📌 通則：**任何靠名字比對的 witness，在「存活者不帶那個名字」的形狀下都會失效。**

> 🔴 **在 argv 到手之前不要動手寫 viz 的修法**——那會是「用想像中的形狀寫修法」的第二次機會。
> （`NEXT.md` 記錄 argv 已於第三輪取得：`round3-restart-concurrency/14_viz_process_chain.log`，
> 並**更正了作者自己「四層」的推測為實測三個 process**。）

> **`pidfile-lost-but-alive` 這個狀態名對 energy/sim 是誤稱**（它們沒有 pidfile）。沒有改名。

> **`sim` 的 signature 會 match 兩個 pid** … 所以每個呼叫端問的都是「至少有一個嗎」。

`NEXT.md` 另記一個順帶發現、**不屬於本支**的缺陷：`ndt:1687`／`:1999`／`:2034` 的
`2>/dev/null` 寫在 `<` 之後 ⇒ 開檔失敗的訊息照樣漏到 stderr（G-9 的 `ndtwin-lab` 已寫對）。

---
---

# 5／6 — `fix/flow-rate-denominator`

1 commit（`6088c0b5`）｜base `72fdc5b0`｜C++ 三檔 ＋ 測試 ＋ 一份 340 行的 audit 文件

## 1. 一句話

每條流的 `estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot` 是
「**一個迴圈週期內的位元數**」掛著「**每秒位元數**」的名字送出去；補上它從來沒有過的分母
（實測的 drain-to-drain 區間）。

## 2. 🔴 行為變更前後對照

**這支不改任何命令的輸出格式、不改任何 rc；它改的是一個 API 欄位的「值」。**
未重編 `build/bin/ndtwin_kernel` 之前，機器上什麼都不會變。

修法前（`src/ndt_core/collection/FlowLinkUsageCollector.cpp`，trunk `:1934-1936`／`:1952-1954`）：

```cpp
stats.avgByteRateInBps =
    sflow::counterDelta(byte_count_current, byte_count_previous) * 8 * currentSamplingRate;
stats.avgPacketRate =
    sflow::counterDelta(packetCountCurrent, packetCountPrevious) * currentSamplingRate;
```

修法後（`include/common_types/SFlowType.hpp`，新純函式 `sflow::updateFlowRatesForInterval`）：

```cpp
stats.avgByteRateInBps = static_cast<uint64_t>(
    static_cast<double>(byteDelta) * 8.0 * samplingScale / elapsedSeconds);
stats.avgPacketRate = static_cast<uint64_t>(
    static_cast<double>(packetDelta) * samplingScale / elapsedSeconds);
```

**🔴 明天同一個 API 呼叫回來的數字會變小，欄位名稱一個字都沒改。**
`發布值 = 真值 × T`，T ＝速率迴圈週期（秒），`T > 1` 恆成立（`sleep_for(1s)` 在本體之前）。
作者用既有紀錄換算的高估幅度：安靜臂 T=1.0439 ⇒ **+4.4 %**；
64 流第一代 fabric T=1.2487 ⇒ **+24.9 %**。

**兩個影響方向要分開讀（作者的分界，我認為正確）：**

- **排序不受影響。** 同一輪所有流共用同一個 T ⇒ 乘一個共同正常數是單調變換 ⇒
  `getTopKFlowInfoJson` 的 `std::sort` 次序不變。有一個測試
  （`FlowRateDenominator.OneDivisorForEveryFlowSoTheOrderSurvives`）把這件事釘住。
- **🔴 大象流門檻一定錯。** `MICE_FLOW_UNDER_THRESHOLD` 是絕對值 10 Mbps ⇒ 只會**多標**、
  不會漏標。T=1.0439 時被誤標的區間是 **9.58–10.0 Mbps**；T=1.2487 時是 **8.01–10.0 Mbps**。

**新增的行為：非正數間隔時拒發、記 ERROR、保留前值、且刻意不推進錨**
（位元組留著下一輪一起付；作者說明這是與連結路的一處刻意差異）。

**作者主動列的兩處副作用：**
1. **少了一行 per-hop TRACE**（原本印每一跳的 agent IP 與計數器）。改成 caller 每條流印一行。
2. `!hasActiveHops` 的清零註解被搬進純函式，**整段保留沒刪**（有別的文件引用它的行號）。

**🔴 合併判準是作者自己下的，而且比修法本身更值得看**（§7.3）：

> **有既存結果依賴這些數字（T1／T2／T3）⇒ 走分支，不進 trunk。**
> 要合併之前，T1 的積分需重算、T2 的兩個絕對值需撤回或重取、T3 需要一次留 raw 的重測
> （或標記為永久不可回溯）。

三筆是：**T1** `doc/audit/2026-08-16_concurrent-flow-reconciliation.md:73` 的 4.49 GB／3.46×；
**T2** W 輪 ＋ KNOWN-ISSUES A-3 的 **20.3 Mbps / 10496 pps**（作者判：**結論站得住，兩個數字要撤**）；
**T3** `doc/audit/2026-09-02_manual-usertest/run-01-sonnet/` 的 ~40 Mbps／~3300 pps（列為 at-risk）。

## 3. 閘門證據

`tests/shell/mutate_flow_rate_denominator.sh` — **5 mutations, 0 survived**
（F1–F5），測試 `tests/test_RateDenominator.cpp` 的 `FlowRateDenominator` 套件。
baseline `[ PASSED ] 17 tests.`。
**輸出只以散文抄在文件 §6，分支上沒有 raw log。**

**對著未修的碼看過紅？** 有，而且作者把這件事講得最清楚：

> 🔴 **F1 不是一個抽象的突變，它把原始碼還原成 kernel 真正出貨的那個運算式**
> （`delta * 8 * samplingRate`，沒有除法）。指名的測試對著它紅，就是「對著未修的碼看過它失敗」
> ——而且這個觀察**可重跑**，不是一次性的手動確認。

**它斷言 shape 還是那一行？** 四格斷言算術，**只有 F4 斷言接線**：

> **F4 是這一輪最重要的一格。** … 把 `flowElapsedSeconds` 改成常數 `1.0` … 之後，
> **除了 `TheFlowDivisorIsMeasuredNotAssumed` 以外每一個測試都還是綠的**。
> 一套只測算術的測試會給這個錯誤發綠燈。

🔴 **這把閘門沒有 control 變異**（不像 G-6／G-7／G-9 的 `control-comment-only`），
所以「閘門會不會把不改行為的東西也判成 KILLED」沒有被示範過。

**作者兩件誠實紀錄**：前兩次啟動被自己中止（其中一次是因為
`AnElephantIsDecidedOnTheDividedRate` 的常數選得太小、根本沒出現過一次誤標）；
本輪與 B-5 的閘門**同時在同一棵工作樹上做突變**，靠同一把 `flock` 串行化。

## 4. 合併順序與衝突

- **與其餘五支零檔案交集。** 唯一可能撞的是 `tests/CMakeLists.txt`——B-5 動了它、
  flow-rate 沒動（`tests/test_RateDenominator.cpp` 是既有檔、已註冊）。
- 沒有先後相依。
- 🔴 **真正的「順序」不在 git 上，在對帳上**：T1／T2／T3 三筆處理完才該併（作者自己的判準）。

## 5. 回退方式

**單一 commit `6088c0b5`，`git revert` 即可**（我確認分支只有這一個 commit，所以這句話成立）。
沒有資料遷移、沒有狀態檔格式改變。**未重編前不生效** ⇒ 回退也不需要做任何機器上的動作。

## 6. 未處理（作者原話）

> **本輪未處理（範圍由協調者裁定）**
> - PREREG §Q-1 的 **(B) 半**（`sleep_until` 讓穩態週期真的等於 1 秒）：今晚不做。它要重編，
>   而重編會換掉四輪測試正在量的那顆 binary。
> - 封包分子與跳數分母母體不一致（`avgPacketSendingRateTemp` 無條件累加，`hopsCounter++` 只在
>   位元組率非零時）：另案，本次刻意保持原行為，否則封包率會因為與分母無關的理由變動。
> - 第 4 節表中第 4 項（`updateLinkInfo` TESTBED 路徑的**整數截斷**分母）。

> **§8 本節不宣稱**：不宣稱高估已經在**實機**消失——本輪一行 live 都沒跑。
> 修法的證據是單元測試與變異閘，不是 fabric 上的讀數。

> §3.4 兩個**沒有查證、不要當成已排除**的邊角：`unordered_map` rehash 造成的走訪次序漂移；
> 一條流的第一個區間被低估（修法前後都存在）。

⚠️ 文件的 §7 自己標了兩份清單的可信度：**清單 A 是 subagent 轉述**（作者沒親自打開那些產圖
腳本），§7.2「bmv2 效能研究八張圖不受影響」的結論掛在那份轉述上；**清單 B 由協調者轉述**。
只有 §7.1 的 T1／T2／T3 三筆引用行是作者親自讀過的。

---
---

# 6／6 — `fix/l9-make-topology-stdout-json`

1 commit（`4f1e09b9`）｜base `0cdd1cf1`（比其他五支早）｜動 `tools/make_topology.py`

## 1. 一句話

`tools/make_topology.py --hosts N --stdout > f` 把 round-trip 報告和 JSON 印到同一個 stdout，
導致產出的檔案第一行是 `round-trip against the shipped models:`、任何 JSON parser 都不收；
`--stdout` 時把報告改送 stderr。

## 2. 🔴 行為變更前後對照

commit message 自己就是對照（我對過 diff，逐字成立）：

> `tools/make_topology.py --hosts N --stdout > f` is the flag's documented use -- the script's own
> usage block says so -- and it could not work. … the redirect produced a file starting with
> "round-trip against the shipped models:". Observed 2026-09-02,
> `doc/audit/2026-09-02_live-round/raw/B6_make_topology.log`: JSONDecodeError at line 1 column 1,
> and the same bytes with the report stripped by hand parsed to nodes 22, edges 56.

碼上就是一行：

```python
+    report = sys.stderr if args.stdout else sys.stdout
```

之後 8 處 `print(...)` 加上 `file=report`，`check()` 多一個 `out=` 參數。

| 情境 | 修法前 | 修法後 |
|---|---|---|
| `--stdout`，報告去哪 | **stdout**（污染 JSON） | **stderr**（互動時仍看得到） |
| `--stdout`，JSON 尾巴 | `print(text)` ⇒ **多一個換行** | `print(text, end="")` ⇒ 一個換行 |
| **沒有** `--stdout` | 報告在 stdout | **完全不變**（作者刻意） |
| `REFUSING TO GENERATE` 拒絕訊息 | stdout | 跟著 `report` 走 |
| 退出碼 | 不變 | 不變 |

作者自己標了為什麼不能無條件改：

> Without --stdout nothing moves: there the report IS the output, and sending it to stderr
> unconditionally would silently empty the stdout of every existing invocation.

**🟠 一個 commit message 沒說滿的地方（我從 diff 讀到）**：`args.hosts` 是**清單**，
`for hosts in args.hosts` 逐個印。所以 `--hosts 4 16 --stdout` 仍然會在 stdout 上串接
**兩份** JSON 文件——「stdout carries one JSON document」只在**單一 `--hosts` 值**時成立。
本分支沒有改這一點，也沒有宣稱改了。

**呼叫端風險**：作者說「Nothing in the repo invokes this script except
`tests/python/test_make_topology.py`, which imports it and does not use the CLI.」
**這一條我沒有獨立複驗**（本輪只讀分支自己的 diff），列為作者宣稱。

## 3. 閘門證據

`tests/shell/mutate_make_topology_stdout.sh` — **3 mutations, 0 survived**。
`tests/python/test_make_topology.py` 24/24 不變。
**輸出只在 commit message 裡，分支上沒有 raw log。**

**對著未修的碼看過紅？** 有：`M1` 就是把 `report = sys.stdout` 放回去（原始缺陷），
指名 `case 2` 變紅。作者還說明了為什麼要三個方向：

> two of the three obvious wrong fixes pass a single-case test: M1 restores the defect (case 2
> red), M2 moves the report unconditionally (case 5 red), M3 suppresses the report rather than
> moving it (case 4 red -- and that one would take the "REFUSING TO GENERATE" refusal down with it).

🔴 **它斷言的是那一行，不是 shape。** 我打開閘門腳本讀了：**三個變異全部錨在同一個字串**
`report = sys.stderr if args.stdout else sys.stdout`。加一個新的 `print()` 忘記帶 `file=report`
——也就是這個缺陷最可能的復發形狀——**三個變異都不會抓到**。
**沒有 control 變異。** 另外 `SURVIVORS -eq 0` 時腳本印的是寫死的字串
`echo "mutation gate: 3 mutations, 0 survived"`，那個 `3` 不是算出來的（不影響結論，
但重跑時不要把它當成計數）。

腳本有 baseline byte-identity 檢查（`sha256sum` 對帳），且變異跑在 temp tree 上、
`setting/` 只放兩個 shipped model 的 symlink ⇒ **不會寫到 `setting/`**。

## 4. 合併順序與衝突

- **與其餘五支零交集**，沒有先後相依，隨時可併。
- base 比其他五支早（`0cdd1cf1`），但 `trunk...` 三點 diff 只有這三個檔，不會帶進別的東西。

## 5. 回退方式

**單一 commit `4f1e09b9`，`git revert` 即可。** 純 Python，無資料格式、無狀態檔、無重編需求。
六支裡回退成本最低的一支。

## 6. 未處理（作者原話）

這支**沒有 `RATIONALE.md` 也沒有 `NEXT.md`**，唯一的紀錄是 commit message。它明寫的兩件：

> **ON A BRANCH, not trunk**: this changes which stream a user-visible tool writes its report to,
> and tonight's rule is that behaviour changes do not go on trunk.

> No lab, no fabric, no writes to `setting/`: only `--stdout` and `--check` are exercised, and the
> gate runs its mutants against a temp tree whose `setting/` holds symlinks to the two shipped models.

**沒有記錄的**（我的觀察，不是作者的話）：多個 `--hosts` 值時 stdout 仍是多份 JSON 串接；
以及沒有任何機制阻止未來新增的 `print()` 漏掉 `file=report`。

---
---

## 附錄：一頁摘要

| # | 分支 | commits | 最該擔心的一件事 | 閘門 | 可單獨 drop 的 commit | 硬衝突 |
|---|---|---|---|---|---|---|
| 1 | `g9-cleanup-no-pkill-f` | 6 | `cleanup` 從不可能失敗 → 會回 rc 1；root guard 多一個 sourced 旁路 | 6+4，0 存活，有 control | `NEXT.md` ×2 | **G-7** |
| 2 | `b5-kernel-shutdown` | 7 | `cb639254` 讓 `ndt down` 對 134/137 等回非零；乾淨關機實測 81 s | 3，0 存活，**無 control**；**唯一有 raw log** | `cb639254` | 無 |
| 3 | `g7-ndtwin-lab-config` | 3 | 新增一份決定 root 跑哪棵樹的 `/etc/ndtwin-lab.conf` | 14，0 存活，有 control | `ce4d5b02`、`739121fb` | **G-9** |
| 4 | `g6-ndt-apps-liveness` | 5 | `ndt apps stop` 加了 rc 2；repo 外 driver script 未處理 | 5，0 存活，有 control | `e83ef1d1` | 無（碼） |
| 5 | `flow-rate-denominator` | 1 | 同名 API 欄位的值變小；T1/T2/T3 三筆既有結論待對帳 | 5，0 存活，**無 control** | — | 無 |
| 6 | `l9-make-topology-stdout-json` | 1 | 報告改走 stderr（無 `--stdout` 時完全不變） | 3，0 存活，**無 control、全錨在同一行** | — | 無 |

**跨分支要一起裁的三題：**

1. **根目錄 `RATIONALE.md`／`NEXT.md` 三方 add/add**（G-6／G-7／G-9）。解法不能是「留一份」。
2. **`ndt down` 與 `ndt apps stop` 的退出碼要不要同一套。** B-5 給 0／1，G-6 給 0／2／1。
   G-9 的 `NEXT.md` 已有裁決：「**兩支不一致比兩支都錯更糟**」。
3. **重裝 `/usr/local/sbin/ndtwin-lab` 這一步要不要寫進合併程序。** 今天兩份 sha256 相同
   （已驗）；併入 G-7 或 G-9 任一支之後就不同了，而 root 跑的是安裝的那份。

[Co-developed with claude code -- Adam]
