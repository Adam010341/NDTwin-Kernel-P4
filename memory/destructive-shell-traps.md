---
name: destructive-shell-traps
description: "Two commands that have destroyed work or killed my own shell repeatedly on this machine: pkill -f matching my own bash, and git checkout reverting uncommitted work during mutation testing"
metadata:
  node_type: memory
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-31T06:16:30.619Z
---

Two specific commands, both of which I have already documented in `doc/2026-07-29_HANDOFF.md` and then repeated anyway — which is why they belong here instead, where they load every session.

**1. `pkill -f <pattern>` matches my own shell.** The Bash tool's process command line contains the script text, so `pkill -f ryu_sampler` kills the bash running it. Exit code **144**, mid-task, three times in one session. Kill by PID, or find the PID first with a self-excluding pattern (`ps -eo pid,cmd | awk '/ryu_sample[r]/ {print $1}'`) — the bracket trick keeps the pattern from matching itself.

**2. `git checkout -- <file>` is only a safe mutation revert once the work is committed.** Mutation testing means "apply a bad edit, build, watch a test fail, revert". If the feature under test is still uncommitted, the first revert discards **the feature itself**, not just the mutation. This destroyed a completed change (a header, a source file and its wiring) that had to be rebuilt from scratch. I had handled it correctly two hours earlier with a scratchpad `cp` and did not carry the lesson across.

**Why:** both failures are silent in the moment. `pkill` looks like the command simply ended; `git checkout` reports success and leaves a clean tree, so `git status` actively reassures you while the work is gone. Neither produces an error to notice.

**How to apply:** **commit the feature first, then mutate** — that ordering makes `git checkout` correct and is now the documented workflow in `doc/audit/2026-08-07_mutation-evidence-cpp.md`. If committing first is not possible, `cp` the file to the scratchpad and restore from that copy, verifying with `cmp`. And after any mutation run, check `git diff HEAD -- src/ include/` is empty *and* that the feature's own identifiers still exist (`grep` for the constant or function you added) — a clean tree is not evidence the work survived. Related: [[mutation-gate-for-tests]].

## The pattern matches the *whole command line*, including your own start command (4th time, 2026-08-09)

`kill $(pgrep -f "[n]dtwin_kernel --mode mininet")` killed my own shell — exit 144 — **despite the
bracket trick**. The bracket trick only stops the pattern matching its own literal text. It cannot
help when the same command line *also* contains the thing the pattern is looking for: two lines
below the `pgrep`, the same command restarted the process with `./bin/ndtwin_kernel --mode mininet`,
and `pgrep -f` matched that.

So the rule is sharper than "use the bracket trick": **never put a `pgrep -f`/`pkill -f` in the same
command as anything containing the text it searches for.** Get the PID in one call, kill by PID in
the next. `pgrep -c` (count only) and reading a PID from `ss -ltnp` or `/proc` are safe.

## Trap 1, 5th time, with this memory loaded and its rule quoted (2026-08-13)

`ryu=$(pgrep -f 'ryu-manager --observe' | head -1); kill "$ryu"` — exit 144 again. The rule
below was already written, already loaded, and I had *cited* the pgrep-self-match hazard twice
earlier the same day (once catching a false `proxy_agent: 1` in my own sweep). Writing the
pattern as a literal in the same command line is the whole failure, every time.

**The habit that actually works, because it removes the judgement call**: never use `pgrep -f`
to find something you are about to kill. Use `ps -eo pid,args | grep '[r]yu-manager'` — the
bracket makes the command line unable to match its own pattern — read the pid, then kill in a
*separate* tool call. Two calls, always, no exceptions for "this one is obviously safe".

## Trap 2, hit again with this memory loaded (2026-08-13)

Improved the curl-flag helpers in `test_P4PowerStrategy.cpp` (uncommitted), ran the mutation
check by `sed`-ing the old logic back in, then "restored" with `git checkout -- <file>` — which
discarded the improvement itself; it had to be rewritten. Two sharpenings the old text lacked:
**an inline `sed`/Edit flip counts as a mutation** (the trap is not limited to formal mutation
runs), and the safe order is mechanical: **green → commit → mutate → red → `git checkout` →
green again**. The `pgrep -f` self-match also recurred benignly the same night (a sweep counted
its own command line as a running proxy; the `ss -ltn` cross-check caught it).

**2026-08-16 新變體:Mininet 的 pkill 沒有「這台 host」這回事。** Mininet 預設只隔離
**網路** namespace,PID 空間全 host 共用——`mnexec -a <h2pid> pkill -f "iperf[3]"`
殺的是**全場**所有 host 的 iperf3,不是 h2 的。要精準殺單一 host 的程序,得從該 host
bash 的子行程樹找 PID。當晚是故意要全殺所以無害,但設計時差點以為它是 per-host 的。
同晚 `pgrep -0/-f` 自匹配又中兩次(偵測版,見 [[process-liveness-checks-lie-in-two-ways]]
第三式:等待迴圈等到自己,掛 8h44m)。

## 2026-08-20:`mn -c` 的實際殺法,以及「script 檔免疫」這個建設性推論

`ndtwin-lab cleanup` 會殺掉呼叫它的 shell —— 這條警告到處都在寫,但**沒寫機制**。
機制在 `mininet/clean.py`,只有三行:

```
pkill -9 -f 'mininet:'       pkill -9 -f "sudo mnexec"       pkill -9 -f 'Tunnel=Ethernet'
```

🔑 **殺的不是「呼叫者」,是「argv 裡提到這些字串的任何行程」。** 所以
`bash -c '... mininet: ...'` 這種 wrapper 會死,是因為 Claude Code 把整段指令文字放進 argv。

**建設性的另一面(實測驗證,不是推論):script 檔免疫。** `/bin/bash /path/ndt down`
兩個 pattern 都沒有,所以 teardown **可以**被包成一個指令 —— 這是 `ndt down` 敢把
`stack.sh down` → `topo-stop` → `cleanup` 三步包在一起的全部理由。

實驗(planted canary,兩個除了 argv 完全相同的 detached sleep):

| canary | argv | teardown 後 |
|---|---|---|
| TEST | `sh -c 'sleep 600' mininet:canary` | **被殺** |
| CONTROL | `sh -c 'sleep 600' ndtcontrolcanary` | **活著** |

呼叫端的 shell 也活著。**條件是子行程的 argv 也不能帶 pattern** —— 所以 `ndt` 數行程一律用
`ps -eo comm=` / `ps -eo args=` 讀進 bash 內部比對,絕不用 `awk '$NF ~ /^mininet:/'`
(那個 awk 的 argv 就帶著 pattern)。同理計數的 tag 要在 runtime 組合(`tag="mininet"; tag="${tag}:"`)。

同日同一族又中一次:`sudo -n mnexec -a $H33 pkill -f iperf3` 寫在 `bash -c` 裡,
wrapper 的 argv 含 `iperf3` → **自殺,exit 144**(正是本檔最上面那條)。改寫成 script 檔就好了。

**2026-08-15 兩個變體(同日連踩):**
- `pkill -f PATTERN` 的括號 trick(`[r]yu`)只保護 pattern 自己——**同一條複合指令的其他段落
  含有字面量一樣會自殺**(kill 段與 relaunch 段寫在同一呼叫,relaunch 段的 `ryu-manager`
  路徑被 pkill 匹配)。規則升級:**kill 與 relaunch 必須拆成兩個 Bash 呼叫**。
- mutation gate 的還原 `git checkout -- <file>` 會**洗掉同檔未提交的真修復**——「mutation 前
  先 commit」的破壞者就是還原步本身。當日實踩:stack.sh 的輪替修復被自己的 mutant 還原吃掉。

## 🔴 2026-08-26:**commit 訊息會被 shell 執行**,而 commit 回報成功

`git commit -m "…"` 的訊息裡若有反引號或 `$(...)`,**雙引號內 shell 就先跑掉了**。
mainDev 實踩:訊息裡逐字引用一個有 bug 的 launcher(內含 `$(cat pid.txt)` 那類),
結果 commit 訊息寫著 **「same 3588430」——那個 pid 是 shell 當場執行生出來的**,
不是原文。**唯一徵兆是 stderr 一行,`git commit` 本身回報成功。**
(補在 `ea79d2e`;報告引用程式碼時最容易中,因為那正是會塞反引號的場合。)

✅ **解法,已實測驗證**:用**引號版 heredoc**,`<<'EOF'`(delimiter 加單引號),
不要用 `git commit -m "$(...)"` 直接塞。

```
git commit -F - <<'EOF'
…訊息裡可以安全寫 `gt` 或 $(anything)…
EOF
```

**我自己查過**:同一晚我下的六個 commit 全用 `<<'EOF'`,其中 `e1ecf5c` 訊息含 `` `gt` ``,
**事後 `git log` 讀回來仍是逐字的 `` `gt` ``**(若被執行會變成空字串、留下 `-- --`)⇒ 引號版
heredoc 確實擋住展開。**這是驗過的,不是推論的。**

🔑 **它與同晚另外三式屬於同一族,而那一族的共同點是「全部回報成功」**:
`comm` 15 字元截斷回空、`head -1` 取到最小 pid 而非目標、`$!` 記到 bash 外殼、
以及本條。四式全部 exit 0。⇒ **「指令成功」對這一族零保護力,要驗的是「它做的是不是我要的那件事」**
(前三式見 [[process-liveness-checks-lie-in-two-ways]])。

---

## 🆕 第三式（08-27）：**`pkill -f` 寫在「啟動迴圈」裡，會殺掉前面剛啟動的每一個**

工單 N 第一格：32 條流只有 1 條連上，而報告的數字（**0.902 Gbit/s**）
對一條 1 Gbit 接取鏈路**完全合理**，差點被當成 32 流的天花板發表。

```bash
for i in $(seq 0 31); do
    sudo -n mnexec -a "$SP" pkill -f iperf3   # ← 在迴圈裡
    sudo -n mnexec -a "$SP" iperf3 -s -1 --daemon ...
done
```

🔴 **mininet host 共用 root PID namespace** ⇒ `mnexec -a` 進去跑的 `pkill`
**打得到整台機器的 iperf3**，不是只有那台 host 的
⇒ **每一輪都殺掉前面所有剛起好的伺服器，只有最後一台活著。**

🔑 **可證偽預測驗了機制**：若是這個原因，活下來的必須是**最後一對**——
實測唯一成功的是 `cli_h48 → h112`，正是 i=31。✅

🔴 **而我的守衛通過了而且沒說謊**：`32/32 servers started` 是真的，
**它們是之後才被殺的** ⇒ **「啟動成功」≠「還活著」。**

**兩條修法**：
1. `pkill` 移到迴圈**之前**，只做一次。
2. 迴圈**之後**斷言**還活著**：`pgrep -c -x iperf3` ≥ 預期數（實測 32，通過）。

⚠️ **儀器是無辜的**：介面計數器讀到的 0.902 G 對那一條流是**正確的**。
**壞掉的是實驗不是量測**——這正是它難抓的原因。
相關：[[failures-that-report-success]]、[[injections-must-assert-their-own-success]]

## 🔴 第六、七次（2026-08-28 夜，同一個 session 內兩次，本記憶全程載入）

新的觸發情境：**收掉自己開的背景工作**。兩次都是 exit 144（殺到自己那個 bash）。

```bash
pkill -f "deadline="     # 我自己的指令列裡就有 deadline=（那正是我要殺的迴圈的程式碼）
pkill -f "btanfteus"     # 背景工作的 ID，而我把它寫在同一條指令列上
```

🔑 **這個情境特別容易中，因為要殺的東西的「識別字串」必然出現在你寫的指令裡**
——背景工作的 id、剛才那段 script 的內容，**你不可能不提到它**。

✅ **兩次都沒造成損害，但那是因為我每次都去複驗 fabric**
（`pgrep -cf 'simple_switch_g[r]pc'` = 10、kernel = 1、兩個 host namespace、claim 完好）。
**exit 144 之後一定要複驗**——它殺掉的是那一整條指令，
**後面還沒跑到的每一行都被跳過了**，而畫面上只有一個非零 rc。

⇒ **規則收到不留判斷空間**：**在這個 repo 裡不要用 `pkill -f`／`pgrep -f` 去殺東西，一次都不要。**
背景工作用工具自己的停止機制（`TaskStop`），或**先在一個呼叫裡拿到 pid、再在另一個呼叫裡 `kill <pid>`**。
本檔從 2026-07-29 起已經記了七次，**bracket 技巧、拆行、「這次很明顯安全」三種判斷全部失敗過**
——所以剩下唯一有效的形式是「不要用」。
- 🆕 08-30（開機手冊自報）：`git commit -m "…$(ndt_down)…"`——訊息裡的 `$(…)` 被 shell 展開
  （這次函式不在該 shell、空替換、只缺字；若在，就是 teardown）。**含 shell 特殊字元的
  commit 訊息一律 `git commit -F <file>`**。amend 修訊息前先驗 index 是空的。

## 🔴 08-30：**官方使用手冊在教讀者用 `sudo kill -15 $(pgrep -f …)`**

本檔的規矩是「**不要用 `pkill -f`／`pgrep -f` 殺東西，一次都不要**」，用七次事故換來的。而 NDTwin 的 **User Manual / NDTwin Tools / Network State Recoder** 頁把它印成停止程序：

```bash
pgrep -f network_state_recorder.py                       # 狀態查詢
sudo kill -15 $(pgrep -f network_state_recorder.py)      # 停止
```

`pgrep -f` 比對的是**命令列**，所以任何 argv 帶著那個字串的 shell 都會中（`bash -c '…'`、編輯器、另一個 grep）。在狀態查詢是**錯答案**；在停止是**用 sudo 殺錯行程**。另外兩個邊：**零命中 ⇒ 變成沒有參數的 `sudo kill -15`**；**多命中 ⇒ 全殺**。

⇒ 已入 doc 修復波（auditor 標高優先），修法是 **PID file 或 systemd**。
🔑 值得記的是這條規矩的**適用面比我以為的大**：它不只約束我自己怎麼下指令，也是**審查別人文件時的判準**——我們用血換來的規矩，外部讀者會照著手冊踩。
正本：`doc/audit/2026-08-28_manual-verification-coverage/FINDINGS-tools-pages-desk-check.md` N-5。

---

## 🆕 2026-08-31：磁碟被 docker build 塞爆（100%），連工具輸出都寫不進去

C4 的 period-container 偵察連跑兩次 bmv2＋thrift 編譯，把 `/` 從吃緊推到 **0 可用**——
症狀是**所有指令的 stdout 捕獲失敗**（`ENOSPC`），連 `df` 都印不出來、`head` 也 write error。

- **安全的第一刀＝`docker builder prune -af`**：只清 build 快取（可再生），**不動執行中的
  容器、不動 tagged image**。實測 0 → **5.2 G**。🔴 Adam 的 dev stack（web-gui ×2、
  postgres）是跑著的容器 ⇒ `docker system prune` 那種大掃把**不要用**。
- 🔑 **`du -shx /home/adam/*` 會漏掉隱藏目錄**（glob 不含 dotfile）——我因此看到
  「/home 42 G 而可見檔案只有 14 G」的假象。要補 `du -shx /home/adam/.[!.]*`。
- 本機空間現況（08-31）：`/` 98 G、用 88 G。最大單一項＝**`~/.config/Claude/vm_bundles`
  12 G**（Claude Desktop 的 VM bundle，Adam 的資料、我不碰）；次為 `.cache` 2.3 G、
  `.gemini` 2.2 G。deleted-but-open ＝ 0（查過，不是那個形狀）。
- ⇒ **教訓**：跑容器編譯前先看 `df`。長時間 image build 是這台機器上少數會**沉默地把整台
  弄到不能用**的動作，而且失敗訊息會偽裝成工具壞掉。

## 🔴 08-31 續：磁碟一天三次見底，以及 **docker 清理只准 `builder prune`**

同一天 `/` 被推到 **0 可用三次**（一次連 `df` 都印不出來）。造成的傷全部是**沉默的**：
`cp` 產出 **0 byte 備份卻回報成功**、`cp` 把 tracked 的 topology JSON 截成 0（**偽裝成契約
套件的 `FAIL [400]`**——照 exit code 寫就會對 `modify_device_name` 立一個假缺陷）。
兩個 agent 都靠 pristine sha256 全數復原，靠的是**內容驗證不是 rc**。
- **可用的紓解（實測）**：刪殭屍 build tree、`gzip` 舊 `scratch/lab/logs/viz*.log`（3.4 G→壓縮
  ＝可逆、不是刪除）、`docker builder prune -af`（救回 5.2 G）。
- 🔴 **禁用 `docker system prune` 與 `docker rmi`**——**Adam 的 web-gui ×2＋postgres 是跑著的**
  （Adam 08-31 明令）。清理只准 `docker builder prune`。
- 🔴 **本機不再跑 C4 的 container build**（Adam 裁，改 nslab）；本機容器編譯前一律先 `df -h /`，
  **低於 3 G 不開工**。
- harness 硬化配方（兩個 agent 實作過）：寫入走 temp＋`fsync`＋size 檢查＋`os.replace`；
  復原走 temp＋`cmp`＋`mv`（短寫永遠碰不到正本）；每步前檢查 `/` ≥ 512 MB。
