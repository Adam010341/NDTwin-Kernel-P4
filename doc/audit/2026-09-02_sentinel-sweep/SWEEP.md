# 哨兵值 sweep —— 第一步：清單，不改任何檔

2026-09-02，`9/1 mainDev`。auditor 派的（Adam 09-02 改序後的第三張）：
**先列出哪些函式回哨兵、哪些呼叫端拿它做相等比較；清單本身就是交付，本輪目錄以外的檔一個都不動。**
[Co-developed with claude code -- Adam]

形狀（`doc/KNOWN-ISSUES.md` 「哨兵值會製造空洞的通過」）：一個讀值函式失敗時回哨兵
（`UNREADABLE`／`NO-KERNEL-PROCESS`／`unknown`／空字串），呼叫端拿**兩個這樣的讀值**做 `==`／`!=`
⇒ **兩邊都讀不到時相等 ⇒ 通過**。失效方向是最壞的：完全沒有資料與資料完全一致產生同一個結論。

## 範圍

| 掃了 | 兩個方向 |
|---|---|
| `lib_e.sh`、`run_e.sh`、`gates_e.sh`（E 輪）；`run_f5.sh`（F5）；`ndt`、`stack.sh`（共用工具）；`cpu_gate.py`、`cpu_probe.py`、`analyse_matrix.py`、`ratio_gate.py` | ① 產生端：`echo`／`printf`／`print`／`return`／`${x:-…}` 帶 `UNKNOWN`／`UNREADABLE`／`unset`／`n/a`／`none`／`missing`／`absent`／`?` 的行 ② 消費端：`[[ $a == $b ]]`／`!=`／`-eq`／`-ne` **兩邊都是變數**的行，逐條讀上下文 |

**沒掃**：08-20 `matrix.sh`、09-01 `matrix_1hz.sh`／`zero_cell.sh`、本人 09-02 的 `run_ab.sh`（自查：所有比較一邊都是常數 sha 或常數 ratio，見表 D）、`p4_proxy/`、`src/`。

## 表 A：已修好的實例（形狀檢查在比較之前，讀不到＝中止）

| 位置 | 比的是什麼 | 守衛 |
|---|---|---|
| `run_e.sh:145-150` | 每格首尾 `running_kernel_sha` | 兩端各驗 `^[0-9a-f]{64}$`，不合即 abort（08-31 登記的那個實例，已修） |
| `run_f5.sh:591-596` | 每臂首尾 `running_kernel_sha` | 同上（F5 的複本，已修） |
| `lib_e.sh:971-974` | 邊數 vs `EDGE_BASELINE` | `n == -1 || -z n` ⇒ abort「Unreadable is not equal」 |
| `lib_e.sh:1001` | `boot_id` vs `BOOT_BASELINE` | `-n "$b"` ⇒ abort「unreadable is not equal」 |
| `lib_e.sh:616-621` | 部署的 binary sha vs 登記 sha | 先印 `IDENTITY verdict=UNREADABLE` 並 `return 2`，判準看輸出不看 exit code |
| `run_f5.sh:455-461` | 腳本內 force matrix 標籤 vs 預註冊裡的 | `na == 0` 與 `nb == 0` 各自 REFUSE，「An unparseable side is unreadable, and unreadable is not green」 |

## 表 B：🔴 還開著的——兩邊都可能是哨兵，相等就通過

| # | 位置 | 兩邊各是什麼 | 怎麼通過 | 嚴重度 |
|---|---|---|---|---|
| **B-1** | `lib_e.sh:909-910`（`restore_production` 的收尾驗證） | `a=$(sha256sum "$KBIN_BACKUP" \| cut …)`、`b=$(sha256sum "$KBIN" \| cut …)`，然後 `[[ "$a" == "$b" ]]` | 守衛只有 `-f "$KBIN_BACKUP"`；**`$KBIN` 沒有存在檢查、兩邊都沒有 `-n`／形狀檢查**。兩個 `sha256sum` 都失敗（權限、或 `$KBIN` 被拿走）⇒ `"" == ""` ⇒ **「production kernel restored」**。這是決定「機器有沒有清乾淨」的那一行 | **中**——觸發條件窄（要兩邊都讀不到），但一旦發生就是把「沒還原」記成「已還原」，而且是在 E 輪每一次 `restore_production` 都走的路上 |
| **B-2** | `run_f5.sh:333-340`（`kernel.log` 首尾 inode 括號） | `ino=$(stat -c%i "$klog" 2>/dev/null)`，open 存進 `KLOG_OPEN_INODE`，close 比 `"$ino" != "$KLOG_OPEN_INODE"` | 前面 `cp -f` 失敗會提早 return 並打 INCOMPLETE 標記（好），但 `cp` 成功後 `stat` 仍可能失敗（race）⇒ `ino` 空；close 端同樣失敗 ⇒ `"" != ""` 為假、`(( 0 < 0 ))` 為假 ⇒ **「沒有 rotate」** | **低**——窗很窄；列出來是因為形狀完全一樣，而且 F5 還沒開跑，改一行最便宜 |

## 表 C：同族但不是「兩個哨兵相等」——「讀不到」塌成其中一個合法答案

| # | 位置 | 形狀 | 後果 |
|---|---|---|---|
| **C-1** 🔴 | `run_f5.sh:128-134`（`assert_arm_binary`） | `hits=$(sudo -n nm -C "$exe" 2>/dev/null \| grep -c setProgrammedPredicate \|\| true)`；`side=$([[ hits -gt 0 ]] && echo post \|\| echo pre)` | **`nm` 失敗（sudo 被拒、exe 讀不到）與「符號真的不存在」都是 `hits=0` ⇒ `pre`**。ARM 是 `*-pre` 的臂會**通過**一顆根本沒讀到的 binary。這是 F5 的 §4 臂身分檢查 |
| C-2 | `stack.sh:838-848`（`down` 的殘留 port 判定） | 三個 `port_owner_verdict` 串接後 `case *ours*` / `*` | 三個都 `unknown`（pidfile 不見）落到 `*` 分支 ⇒ 仍然報錯、`return 1`（**方向安全**），但措辭是「This script did not start it」——pidfile 丟失的孤兒（§G 那條）**正是**這個腳本起的。**不是空洞通過，是錯誤歸屬** |
| C-3 | `analyse_matrix.py:total_sample_rate()` | gcd 塌成 1 時回傳原始總和 | 已在 09-01 REPORT 與 memory 登記；同族（失敗回一個長得像答案的數），不重複開票 |

## 表 D：檢查過、方向安全（一邊是常數，或空值必然 mismatch）——列出來免得下一個人重掃

| 位置 | 為什麼安全 |
|---|---|
| `lib_e.sh:284` owner vs `NDT_OWNER` | `NDT_OWNER` 在 `:265` 先驗非空；owner 空 ⇒ mismatch ⇒ REFUSE |
| `lib_e.sh:781` `batch_size` got vs want | want 是參數；got 空 ⇒ mismatch ⇒ abort |
| `lib_e.sh:859-868` `swap_kernel` | want 驗 `-n`；got 空 ⇒ mismatch；另有「兩臂不得 byte-identical」的陰性對照 |
| `gates_e.sh:488-489` | `$2` 是登記的常數；`${wt:-ABSENT}` 空值變 ABSENT ⇒ mismatch |
| `ndt:501`、`ndt:680`、`ndt:759`、`ndt:2088` | 一邊是參數／算出的目標值 |
| `ndt:887-892` `live_hosts` vs `ovs_hosts` | `fabric_host_count` 讀失敗回 0，而 G-2 #01 的修法把 0 判紅；`ovs_hosts` 是設定值 > 0 |
| `stack.sh:232` got vs want | want 是目標常數 |
| `stack.sh:488` pid vs ours | ours 驗 `-n`；listeners 驗非空 |
| `stack.sh:610` state vs last | 只決定要不要印進度行，不是判決 |
| `ndt:445-460` `sample_rate` 的 `unknown`、`stack.sh:782` `mode` 的 `unknown` | 只被印出或與常數比較，沒有拿兩個讀值互比 |
| `cpu_probe.py`／`cpu_gate.py` 的 `return None` | 消費端 `continue`／跳過，沒有相等比較；cpu_gate 的 lifetime 版把跳過的量收進 residual |
| 本人 `run_ab.sh`（09-02） | `deploy`／`restore_all` 比的是常數 `*_SHA`／常數 ratio 字串 |

## 建議的修法順序（**沒有做**，交 auditor 路由；F5 開跑前最便宜）

1. **B-1**（`lib_e.sh:909`）：`a`、`b` 各驗 `^[0-9a-f]{64}$`，不合即 `fail=1` 並印 `restore: sha UNREADABLE`。三行。
2. **C-1**（`run_f5.sh:131`）：把 `nm` 的 rc 與 `grep -c` 分開——`nm` 非零 ⇒ abort「binary unreadable, side unknown」，不是 `pre`。
3. **B-2**（`run_f5.sh:333`）：`[[ -n "$ino" ]] ||` 打 INCOMPLETE 標記並 return。一行。
4. C-2 措辭：三個 `unknown` 時改印「pidfile 不存在，無法判定是不是本腳本起的」。

⚠️ 這四處都在 auditor 說「先不要動 F5／E 的腳本」的範圍內（它派的唯讀 agent 在掃同型還原缺陷）。**本清單不含任何 diff。**
