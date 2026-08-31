---
name: put-measurement-commands-in-script-files
description: "量測／teardown 指令一律寫進 script 檔，不要用 `bash -c`。`pkill -f`（含 `mn -c` 內部那三行）掃的是整條 argv，bracket 只保護 pattern 本身；script 檔的 argv 只有路徑，天然免疫"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 38b035fc-b098-4e53-9db6-78561882a7f2
  modified: 2026-08-27T15:22:17.718Z
---

**2026-08-20 一天之內我踩了三次同一族的坑，而三次的解法都已經寫在
[[process-liveness-checks-lie-in-two-ways]] 裡。** 所以「記得加 bracket」這個對策是失敗的 ——
它需要每次都想起來，而且**它只保護 pattern 本身，保護不了同一條命令列的其他部分**。

| 次數 | 指令 | 為什麼中 |
|---|---|---|
| 1 | `pgrep -c "simple_switch_gr[p]c"` | comm 15 字元截斷（`simple_switch_g`），要 `-f` |
| 2 | `pgrep -f "ndtwin_kerne[l]" … ; stat build/bin/ndtwin_kernel` | bracket 對了，**但同一條命令列後半有字面字串** |
| 3 | `pkill -f iperf3` | 沒加 bracket，**殺掉我自己的 shell**（exit 144） |

**Why:** `pkill -f` / `pgrep -f` 比對的是**每個行程的完整 argv**，包含發出這個指令的那個
`bash -c '…'` 自己。只要命令列裡任何地方出現目標字串就會自我匹配。

**How to apply:** **量測、teardown、任何會 kill 東西的指令，寫進 `.sh` 檔再執行。**
script 檔的 argv 只有 `/bin/bash /path/to/run.sh`，不含被搜尋的字串，天然免疫。
今天的證據：`measure.sh`（script 檔）裡有一模一樣的 `pkill -f iperf3`，跑了 17 格量測從沒
出事；出事的全是我寫在 `bash -c` 裡的那些。Adam 已核准把這條立為常規。

## `mn -c` 的殺法（開機手冊 session 2026-08-20 用 canary 對照實測）

`mininet/clean.py` 只有三行 pkill：`pkill -9 -f 'mininet:'`、`pkill -9 -f "sudo mnexec"`、
`pkill -9 -f 'Tunnel=Ethernet'`。兩個除了 argv 完全相同的 detached sleep：

| canary | argv | teardown 後 |
|---|---|---|
| TEST | `sh -c 'sleep 600' mininet:canary` | **被殺** |
| CONTROL | `sh -c 'sleep 600' ndtcontrolcanary` | **活著** |

🔑 正確說法是「**殺 argv 裡提到那些字串的任何行程**」，不是「殺 mininet 的行程」。
而 **script 檔免疫**（`/bin/bash /path/ndt down` 三個 pattern 都不含）。

## 第四種形式：串接兩個實驗的「等待者」（2026-08-22）

上面三次都是 kill/量測。這次是**排隊**：實驗 B 要等實驗 A 放開 lab，我寫了

```
setsid nohup bash -c 'while pgrep -f graph_settle.sh; do sleep 5; done; …run B…'
```

`bash -c` 那條命令列裡**字面寫著 `graph_settle.sh`**，所以 A 結束後 `pgrep` 仍然匹配到
**等待者自己**，迴圈永遠不退出，B 永遠不會跑。安靜掛住，沒有錯誤訊息 —— 我是因為 B 的輸出檔
一直不存在才發現的。

🔑 **這條規則的適用面比「量測指令」大：任何命令列裡出現行程名的東西都算**，包括 `pgrep` 當
條件用的迴圈。守衛條件也是命令。
解法一樣：寫進 `.sh` 檔；或用**檔案存在／PID 檔**當條件，不要用 argv 比對。

相關：[[process-liveness-checks-lie-in-two-ways]]、[[destructive-shell-traps]]

## 第七式（2026-08-25，mainDev 踩、審查記錄）：**glob 前綴撞名，錯誤方向是「假失敗」**

同一個 `raw/` 目錄裡放了兩代實驗：Phase 0 的 `boot1/boot2` 與 Phase 3 的 `b1/b2/b3`。
重驗 B 時用 `raw/b*_greenlets.txt`——**glob 把 `boot1`/`boot2` 一起吃進去**，於是 B 臂看到
「4 個違反」，差點把**修法成功讀成修法失敗**。改 `b[123]_` 才對。

🔑 **與前六式的差別：這次的錯誤方向是假失敗（false alarm），不是假通過。** 兩個方向都會
浪費一整輪：假通過讓錯的東西上台，假失敗讓對的東西被丟掉。
🔑 **可操作規則：同目錄放兩代 raw 時，前綴必須互斥**（`b1` 與 `boot1` **不**互斥）。
命名時就想「未來的 glob 會不會撞」，或直接用顯式清單（`for b in b1 b2 b3`）——
審查員的 `accept_phase3.sh` 正是因為用了顯式清單才躲掉，那是運氣不是設計。
相關：[[verify-against-known-good-output]]（第 12 例＝同日的相反方向）、[[grep-endpoints-misses-concatenation]]

## 🔴 第八式（2026-08-25，寫完第七式的**同一輪**踩到）：**清理與重啟寫在同一條命令列**

我用 `pkill -f 'watch_lab.sh' ; sleep 0.5 ; bash …/watch_lab.sh` 一行做「殺舊的、起新的」。
harness 把整條命令列交給 shell ⇒ **`pkill -f` 的比對字串在自己的 argv 裡命中兩次**
（pattern 本身＋後半段的重啟指令），新起的 watcher 當場被自己殺掉（exit 144）。

🔑 **這是本檔母規則最純的實例，而我在寫完第七式的十分鐘內踩到它**——知道規則不等於
在寫下一條指令時想起它。
🔑 **可操作**：`pkill`／`pgrep` 永遠**單獨成一次呼叫**，不要與被清理對象的重啟同列；
或先用不會自我匹配的方式列出來確認（`ps -eo pid,args | awk '$0 ~ /pat/ && $0 !~ /awk/'`）。
「殺完再起」要拆成兩步，中間看一眼結果。

## 🪞 08-27：**我讀過這條記憶，然後照樣踩進去**——擋住它的不是記憶，是自檢

補掛一個 proxy CPU 採樣器，用 `python3 -c '...'` 內嵌，裡面寫著
`subprocess.run(["pgrep","-af","proxy_agent"])`。⇒ **整段程式碼都在它自己的 argv 裡**，
所以 `pgrep -af proxy_agent` **匹配到採樣器自己**，外加它 spawn 的 `pgrep`
（pgrep 的自我排除救不了子行程）。輸出裡憑空多出兩個「proxy」。

🔑 **這條記憶當天稍早才被我引用過**（我還在別處寫了「script 檔的 argv 天然免疫」）。
它沒有阻止我。**抓到它的是「新工具第一次 live 跑就驗它自己」這個動作**，
而那是審查員要求的驗收項，不是我主動做的。

⇒ **知道一個陷阱 ≠ 避開它。只有程序會，記憶不會。**
可操作的那條程序：**任何新採樣器第一次跑完，先問它三個問題**——
① 取樣間隔對不對（我的漂到 7.58 s：`sleep(5)` 放在工作**之後**，
週期＝5 s＋工作耗時，**與我當時正在量的 rate loop 缺陷同一個形狀**）；
② 累計值是不是單調；③ **它認出來的對象是不是只有它該認的那些**。
第三問就是這次抓到的那一問，而我以前從沒問過。

修法：寫成 script 檔（argv 只剩路徑），用 `/proc/*/cmdline` 比對
**更長的、不可能出現在自己 argv 裡的字串**（`proxy_agent/main.py` 而非 `proxy_agent`），
並**顯式排除 `os.getpid()`**。

### 同一天的第三個自我匹配：`ps -eo pid,pcpu --sort=-pcpu` **把自己排進第一名**

`sample_load.py` 記 top-10 用了 `ps --sort=-pcpu`。**`ps` 自己出現在結果的第一列，`%CPU` 讀 200–400%**
——因為 `pcpu` 是生命期平均，而它才剛啟動（極小 CPU ÷ 極小壽命）。
⇒ 十個名額被自己吃掉一到兩個。

**後果比看起來嚴重**：後來要回答「那台 QEMU VM 在不在我的臂裡」，
我先查「它有沒有出現在 top-10」，**五臂 323 筆零命中**——看起來像答案。
但它是**弱證據**：名額被 `ps` 吃掉，加上臂進行中有 10 台 bmv2＋kernel＋proxy＋iperf3，
**輕易八個以上高於 38%** ⇒ 一個 38.6% 的行程被擠出前十完全正常。

🔑 **真正結案的是行程啟動時間**（VM 起於 12:41:45、最後一臂 12:32 結束）**＋pid 單調**。
**兩個檢查同方向、強度差一個數量級，而我差點拿弱的那個結案。**
⇒ 與「一個檢查在你跑它之前就要知道它的陰性結果代表什麼」同一課：
**「不在 top-10」的陰性結果本來就什麼都不代表。**

⚠️ 這個缺陷**沒有污染結論**（實際用的是 `/proc/stat` 原始計數器，不是 `top` 欄位），
但 `load.jsonl` 的 `top` 欄位品質要打折，引用時要說。
**三個缺陷同一天、同一支採樣器家族：`pgrep` 抓到自己、`sleep` 放在工作之後、`ps` 排進自己。**

## 🔑 08-27 夜：**這條規則不是關於 `pgrep`**——兩個 session 在四分鐘內各犯一次

`開機手冊` 查「我有沒有東西在跑」：

```bash
pgrep -a -u "$(id -un)" -f 'install-p4dev|run_p4guide|ninja' | grep -v "$$"
```

唯一的匹配是它自己。`grep -v "$$"` 擋不掉——**`$$` 是子 shell 的 pid，不是被匹配到的那個**。

**我在讀完他們這段之後的第一個指令裡犯了同一個**，而且**我的版本連 `pgrep` 都沒有**：

```bash
for p in /proc/[0-9]*/cmdline; do c=$(tr '\0' ' ' < "$p"); case "$c" in *qemu-system*) … ;; esac; done
```

輸出多出一個 pid，是**我自己那條 shell 的子行程**——整段 script 文字在它的 argv 裡，
`case` 的 glob 命中了它自己。**純 shell、零個行程搜尋工具，照樣自證。**

🔑 **所以母規則要重寫成**：
> **任何把目標字串寫進自己命令列的檢查都會自證**，與用什麼工具無關
> （`pgrep` / `grep` / `case` / `awk` / 內嵌的 python 一視同仁）。
> 而「寫進 script 檔」之所以有效，**不是因為它是 script，是因為它的 argv 只剩路徑**。

⇒ 判準從「我有沒有加 bracket」換成 **「目標字串出現在我這條命令列裡嗎？」**——
這一問對上面所有形式都成立，而 bracket 只對其中一種成立。

**方向也要記**：`開機手冊` 那次會回報「有東西在跑」而其實沒有 ⇒ **誤警**（代價＝排程空轉），
跟我當天稍早那個幽靈 QEMU 同方向。

**同晚第三次（`/before-sleep` 第一步）**：`pgrep -a -u "$(id -un)" -f 'ndtwin_kernel|proxy_agent|…'`
匹配到自己那條 bash（pid 1115399）。機制沒有新的，新的是**位置**：
🔑 **它發生在一個專門用來檢查背景行程的步驟裡**——儀器與它要找的東西同形，
見 [[instrument-must-not-mimic-its-own-finding]]。

✅ **母規則（含「這條不是關於 `pgrep`」那句）已由 `交接摘要 Skill` 寫進
`~/.claude/skills/before-sleep/SKILL.md` 的第一步。** 他刻意寫母規則而不是 `pgrep` 特例，
理由是「特例會被讀成換個工具就沒事」。⇒ **這條現在有程序在擋，不是只有記憶在擋**——
而本檔 08-27 那節的結論正是「知道一個陷阱 ≠ 避開它，只有程序會」。

## 🔴 08-27 深夜更正：**「這一族偏向假陽性、而且便宜」是錯的**

我在上面原本寫「這一族偏向假陽性……便宜，但會安靜地吃掉整晚的排程」。
**當晚稍後我自己走了相反的方向，而它一點都不便宜。**

我查 fabric 在不在，用了 **`pgrep -c simple_switch_gr`（不加 `-f`）**。
`comm` 上限 **15 字元**、而 `simple_switch_gr` 是 **16** ⇒ **回 0** ⇒
**我一度以為 fabric 倒了，並且據此對另一個 session 宣告「lab 空著」**——而 lab 是活的、claim 也還在。

🔑 **mainDev 給的分析比我原本的準，取代上面那句：**

> **回報「不在」⇒ 你會採取行動**（重建、告訴別人、改排程）。
> **回報「在」⇒ 你只會等待。**
> ⇒ **同一個工具的同一個缺陷，偽陰性比偽陽性貴得多，因為偽陰性驅動動作。**

⇒ **可操作的排序**：同樣是不可靠的檢查，**回報「不存在」的那一個要先修**。
而 **`pgrep` 不加 `-f` 的預設行為正是產生偽陰性**（截斷 → 匹配失敗 → 回 0 → 讀起來像「沒有這個 process」）。

⚠️ **`pgrep` 的兩個方向要分開記**：
- 加了 `-f` 但字串在自己的命令列裡 ⇒ **偽陽性**（自我匹配），本檔前面那一整串
- **不加 `-f` 且名字 > 15 字元** ⇒ **偽陰性**（截斷），而這個方向會讓你動手

📌 同一晚我還犯了配套的那一半：**拿轉述取代直接查證**。
`lab.claim` 是唯一真實來源；`開機手冊` 查了 claim、發現與我的轉述不符、**沒有照我的話行動**，那是對的。
mainDev 補上另一半：**轉述會過期，是因為持有者沒有把狀態寫在唯一真實來源上**
⇒ 修法是 **release 之後立刻寫 handoff 並直接通知等待的人**，把「轉述」這個環節整個拿掉。

相關：[[failures-that-report-success]]（第 11 條 `cmd | filter` 後接 `&&`）、[[verify-the-purpose-not-the-mechanism]]

## 08-30：datapath 記帳的兩個除數陷阱（兩個都自己踩過）

寫了 `traffic_mesh.sh`（namespace 內 netdev 計數器記 offered/delivered，不信 iperf3 自報）：
1. 🔴 **除以「ledger 窗」而不是「每條流自己的在空時間」**：base 跑 840 s、churn 各只跑 90 s，
   用同一個除數 ⇒ 每條 churn 報 0.45 Mbit/s 而實際 5.15，**11 倍低估，而且看起來很合理**
   （目標是 5）。兩個 ledger 快照界定的是**窗**，不是每條流在窗裡待多久——那要另外記。
2. 🔴 **4 hosts 時 per-pair 歸因根本不可能**：每台 host 同時是好幾對的來源／去向，
   host 層的 tx/rx 是總和 ⇒ 會算出 -533% 的 loss。**只有 aggregate 那一列有效**（也正是 PREREG 要的）。
   128 hosts 時每台只在一對裡，per-pair 才成立。**同一支腳本在不同規模下有效性不同。**
🔑 分析從存下來的快照重算＝免費（不必再碰 fabric），所以除數寫錯是可以事後修的——前提是
**原始計數器讀數有存下來**，不是只存算完的速率。
