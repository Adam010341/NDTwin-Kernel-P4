---
name: process-liveness-checks-lie-in-two-ways
description: "行程/服務的存活檢查說謊的二十一式(⚠️ 編號有衝突且 08-31 重編過十七/十八→二十/二十一,見檔頭對照表;**不要靠序數引用本檔,用名字指**):comm 15 字元、PermissionError、pgrep -f 匹配到自己、bracket 只保護 pattern、grep -q+pipefail 的 SIGPIPE、整塊字串前綴比對、以及「錯誤被吞掉 + || echo 變成有自信的錯答案」(pty/TERM)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-31T07:11:23.026Z
---

> ## 🔴 序數不穩定——**引用本檔請用名字，不要用「第 N 式」**
>
> | 舊編號 | 新編號 | 用名字指（**建議這樣引用**） |
> |---|---|---|
> | 第十七式（08-31 加） | **二十式** | 「pidfile 說得出何時、說不出是誰」那式 |
> | 第十八式（08-31 加） | **二十一式** | 「還沒開始與剛結束並清乾淨，觀測相同」那式 |
>
> **為什麼會有這張表**：08-31 我發現檔內有兩組撞號（各兩個「第十七式」「第十八式」）並重編，
> **而本檔早就明文寫過「不要靠序號引用本檔，重編會靜靜打斷它」——我漏讀了那句就動手。**
> 事後普查：`destructive-shell-traps.md` 的「前三式」**沒有受影響**（前三式我沒動），
> 但 `nslab-remote-dev-machine.md` **有兩處指向舊的「第十七式」被打斷**，已改成用名字指。
>
> 🔑 **重編號是一種靜默的破壞**：指錯的引用不會報錯，**它會給出一個很合理的錯答案**。
> ⚠️ **另有一組撞號刻意不重編**（兩個「第四式」，見檔內第 195 行附近）——
> **留著比修好更安全**，因為它已經被跨檔引用。

2026-08-12 同一天內我兩次把**活著的 bmv2 判成死的**，兩次機制不同，兩次都差點下錯結論。

**一、`pgrep -c simple_switch_grpc` 永遠回 0。** `/proc/<pid>/comm` 上限 15 字元
（`TASK_COMM_LEN-1`），而 `simple_switch_grpc` 有 18 個字元——`pgrep` 不加 `-f` 是比對 comm，
所以那個 pattern **不可能**匹配。正確的數法：

```
pgrep -cx simple_switch_g     # 截斷形，精確比對
pgrep -cf simple_switch_grpc  # 比對整條 cmdline（會多算 wrapper）
```

這條 `doc/2026-08-10_ovs_manual_test_runbook.md` §80 白紙黑字寫過，我在寫 helper 時踩過一次
（`EXPECTED_COMM` 那個 bug，見 [[smoke-the-accept-path-not-just-refusals]]），**然後在檢查環境
時又踩了一次**。文件記載過不代表已經內化。

**一之二（2026-08-28）🔴 `-f` 的解法配上 `-x` 之後，同一個假陰性回來了。**
我用 `pgrep -axf 'ndtwin_kerne[l]'` 檢查 kernel，拿到空結果，**於是對 Adam 報告「kernel 死了」——
它活著**（pid 1599797）。`8/27 mainDev` 抓到的，我當場複驗：

```
pgrep -axf 'ndtwin_kerne[l]'   # 空 —— 活的 process 被判死
pgrep -af  'ndtwin_kerne[l]'   # 1599797 ./bin/ndtwin_kernel --mode mininet --topology …
pgrep -axf 'ndtwin_kernel.*'   # 仍然空 —— cmdline 開頭是 ./bin/，pattern 沒涵蓋到
```

機制：**`-x` 配 `-f` 時，比對的是「整條命令列完全相等」**，不是「包含」。任何帶參數的
process 都不可能匹配，而 `./bin/` 這種前綴讓 `.*` 也救不回來。

🔑 **這條與上面「一」方向相反，兩條要分開記，因為修法互相矛盾：**

| 症狀 | 成因 | 修法 |
|---|---|---|
| 一 | 沒有 `-f`，比對 comm，15 字元截斷 | **加 `-f`** |
| 一之二 | 有 `-f`，但 `-x` 把它變成整行相等 | **拿掉 `-x`** |

⇒ **不存在「加了 `-f` 就安全」這回事。** `-x` 與 `-f` 的組合語意不是兩個限制相加，
是**換了一個比對對象**（comm 的精確比對 → 整條 cmdline 的精確比對）。

📌 **沒有造成損害的原因值得記，因為它不是我做對了什麼**：`restart_kernel.sh` 用 pid 檔找舊
kernel，並在起新的之前斷言 `:8000` 沒被佔——**兩層都不依賴我那個檢查**。
⇒ 這是 [[failures-that-report-success]] 的驗收版：**壞掉的是儀器，不是機器**，
而擋住它的是別人寫的、與我的儀器獨立的守衛。

**二、`os.kill(pid, 0)` 對別的使用者的程序丟 `PermissionError`。** 那代表「程序存在但不是我的」，
**不是死掉**。bmv2 是 root 起的（Mininet），我用 adam 跑檢查，於是十台全被判成死的。正確寫法：

```python
try:
    os.kill(pid, 0)
except PermissionError:   # 活著，只是不屬於我
    alive = True
except ProcessLookupError:  # 這才是真的死了
    alive = False
```

**Why：** 這兩個都是「否定的證據」——工具回報「找不到」，而找不到有兩種原因：真的不在，或
我的問法看不到。在這個 repo 這特別致命，因為 helper 的 `off` 對「pid 已死」的反應是回報
`already-stopped` 並 **exit 0**；把活的判成死的，就是把「失敗」報成「成功」，正是整個 Phase 7
在消滅的東西。

**How to apply：** 判定「程序不存在」之前，先用第二種方法交叉驗證（port 有沒有在聽、
`ls /proc/<pid>`、換一個比對方式）。

## 第六式(2026-08-19):中括號只保護 pattern,不保護同一行的其他字

`pgrep -fa 'simple_switch_grp[c]'` **還是匹配到了自己** —— 因為我把它跟
`ls -la /usr/local/bmv2-fast/bin/simple_switch_grpc` 串在同一行,
**那一行自己的 argv 就含有完整的目標字串**,中括號完全沒用。

🔑 **`-f` 比對的是整條 argv,而中括號只改寫了 pattern 那一小段。**
把 `pgrep -f` 跟任何會出現目標字串的指令串在同一行,防護就失效。
**解法**:分開跑,或改用不吃 argv 的 `ps -eo comm | grep -c '^simple_switch'`。

相關：[[existence-is-not-wiring]]、
[[no-in-repo-callers-is-not-dead-code]]——三條都是同一句話的變體：**grep/pgrep 的空結果不是事實，
是一次查詢的結果。**

**三（2026-08-16，反方向）：`until ! pgrep -f poll_all.sh; do sleep; done` 永不結束。**
監看 shell 自己的 cmdline 就含 `poll_all.sh` 字串，`pgrep -f` 永遠至少匹配到自己——
兩個背景等待各掛了 8 小時 44 分,被 Adam 的螢幕截圖抓到。這是 `pkill -f` 自殺
（[[destructive-shell-traps]]）的**偵測版**：殺會殺到自己,等會等到自己。解法＝
bracket 技巧讓 pattern 不匹配自身：`pgrep -f "poll_al[l].sh"`（同晚實測有效）。
前兩式把活的報成死的,這式把死的報成永遠活著——方向相反,根因同一句：
**pgrep 看到的世界包含你自己。**

**第四式（2026-08-18，subagent 自己抓到並更正）：bracket trick 會被同一行指令裡的其他字面字串打敗。**

它的收尾對帳報 `simple_switch: 2`、`ryu-manager: 2`，但那兩樣其實都已經收乾淨了。
`pgrep -cf '[s]imple_switch'` 的 bracket 寫法本身沒錯——**問題是同一行指令裡的 `echo` 標籤
含有未加括號的 `simple_switch` 字面字串**，於是 `pgrep -cf` 掃到自己那個 shell 的 cmdline 就命中。

**所以 bracket trick 保護的是 pattern，不是整行指令。** 只要指令裡任何地方（標籤、註解、
變數預設值）出現同一個字串，就前功盡棄。

改法：對帳用 `ps -eo pid,args` 自己過濾，或把標籤與 pattern 拆到不同指令。

**第五式(2026-08-19)= 第三式再犯,而且這次的代價是「看不出來」。**

我用 `until [ "$(pgrep -fc 'measure_failover')" -eq 0 ]; do sleep; done` 等一輪量測結束。
**執行這個指令的 shell,cmdline 裡就含 `measure_failover`**,所以計數永遠 ≥1,
迴圈永不結束。**四個背景等待就這樣掛著**,直到 Adam 問「為什麼還有 4 running tasks」。

比前幾次更難發現的原因:**它的失敗模式是「安靜地繼續等」**,和「工作還在跑」
在畫面上完全一樣。前幾式至少會給出一個錯的數字,這式什麼都不給。

**第七式(2026-08-20)= 完全不同的機制:`| grep -q` 在 `set -o pipefail` 下把活的報成死的。**

```bash
topo_session() { sudo -n "$LAB" status 2>/dev/null | grep -q '^topo:'; }   # ← 錯
```

session 活得好好的,這個函式卻回 false。原因:**`grep -q` 一命中就結束**,
`ndtwin-lab status` 還有一行要印 → SIGPIPE(141)→ `pipefail` 把 141 當成整條管線的狀態。
和 pgrep 無關,但症狀一模一樣(活的報成死的),而且**只在有 pipefail 的腳本裡發作**,
互動式測試看起來完全正常 —— 我就是這樣先在命令列驗證通過、進到腳本才壞掉。

解法:**先 capture 再比對**,不要讓 `grep -q` 提早關掉上游。

```bash
out="$(sudo -n "$LAB" status 2>/dev/null)"; [[ "$out" == topo:* ]]
```

**這是同一條教訓的第三次記錄。** 所以把規則寫成無條件的:
🔑 **任何 `pgrep -f` 一律用 bracket 形式,不要判斷「這次應該不會匹配到自己」。**
`pgrep -fc 'measure_fail[o]ver'` — 加了之後同一個檢查立刻給出正確答案(6 而不是永遠 >0)。
並且注意第四式:bracket 只保護 pattern,同一行的 `echo` 標籤裡有裸字串一樣會中。

**第八式(2026-08-21)= 修好第七式的那一行,自己變成新的謊。同一個函式,一週內兩種說法。**

第七式的修法是「先 capture 再比對」:

```bash
out="$(sudo -n "$LAB" status 2>/dev/null)"; [[ "$out" == topo:* ]]   # ← 修好了 SIGPIPE
```

**但它把「逐行比對」一起丟掉了。** `ndtwin-lab status` 是 `tmux list-sessions`,
**一個 session 一行、按名字排序**,後面再加一行計數。而 session 名有三個:
`topo` / `energy` / `sim` —— **`energy` < `sim` < `topo`**。所以只要 app 開著,
整塊字串就不是以 `topo:` 開頭,**活著的 topo session 又被報成不存在**。

代價不是誤報而已:`ndt up` 的孤兒掃除是 `[[ "$n" -gt 0 ]] && ! topo_session`,
於是它對**健康的 10 台 bmv2** 呼叫 `cleanup`,訊息還寫 `orphan ... sweeping first`。
**「回報成功但做錯事」＋「訊息主動說謊」。**

🔑 **同一個謂詞有兩種說謊方式,修掉一種很容易踩進另一種。**
正確寫法要同時避開兩者 —— 不開 pipeline(免 SIGPIPE)＋逐行錨定(免排序假設):

```bash
[[ $'\n'"$out"$'\n' == *$'\n'"$1":* ]]     # 零子行程,行首錨定
```

**副教訓:兩份實作必然分歧。** 同檔的 `app_running` 用 `grep -q '^energy:'`(逐行、有錨點)
**是對的**,`topo_session` 是錯的 —— 兩個問同一件事的函式,答案不一樣。已合併成一個
`lab_session <name>`。順帶實測澄清:`| grep -q` 的 SIGPIPE 是**競態**
(慢 producer 必 141,真 `ndtwin-lab` 六次全 0),所以 `app_running` 是**潛在**不是已發作 ——
**別把讀碼推論寫成已確認**。

**第九式(2026-08-21)= 錯誤被吞掉,於是查詢變成一句有自信的錯答案。**

`ndtwin-lab status` 是 `tmux list-sessions || echo "no lab sessions"`,而且 **tmux 的 stderr
被送進 `/dev/null`**。tmux 有控制終端時會堅持設定那個終端,需要環境裡有 `TERM`
(**沒 export 等於沒有**);沒有控制終端時它根本不做這件事。

所以在 pty 下、TERM 未 export 時:tmux 失敗 → 錯誤被丟掉 → `||` 把失敗變成
**`no lab sessions`** —— 跟「真的沒有 session」逐字相同。活著的 fabric 被報成不存在,
`topo-stop` 跳過有秩序的關機,`ndt up` 會把健康 fabric 當孤兒掃掉。

實測(活的 session,各 3/3):

| | 結果 |
|---|---|
| pipe / `stdin</dev/null` / `setsid`(無控制終端) | 正確 |
| `script(1)` 或 `forkpty`,TERM **未** export | `no lab sessions` |
| 同上,TERM **已** export(任何值,`dumb` 也行) | 正確 |

🔑 **我為這個現象編了五個機制,全錯**,直到把「同一個指令六種跑法」排成矩陣才看到
pty 是唯一變數。**症狀穩定重現不代表你懂它** —— 見
[[arithmetic-that-fits-is-not-the-mechanism]]。

🔑 **`|| echo "什麼都沒有"` 是這一族的溫床:它把「查不到」和「查不動」寫成同一個答案。**
修法是在 `ndt` 檔頭 `export TERM="${TERM:-dumb}"`(11 個呼叫點共用),
**不是**只修其中一個函式 —— 我第一次只修了 `lab_session`,而 `topo-start`/`topo-stop`/
`cleanup` 各自在 root wrapper 裡跑自己的檢查,所以沒用。**是再測一次發現的,不是讀出來的。**

**第四式（2026-08-20，A/B driver 實踩）**〔⚠️ **編號衝突，未重編**：上面 08-18 那條也叫「第四式」（bracket 被同行字面字串打敗）。**不要靠序號引用本檔**——`destructive-shell-traps.md` 已經用「前三式」指過來，重編會靜靜打斷它。另外「十一」其實是「一」的再發作，不是新機制〕：`( cmd | target ) &` 之後的 `$!` 是 **subshell** 的 pid，不是 target 的。對它 `kill` 殺掉的是包裝、target 變孤兒繼續佔 port（28b8b13 kernel 佔住 :8000，`ndt down` 的「:8000 still listening -- this stack did not start it」抓到的）。**記 pid 要記你要殺的那個行程**：先起、再用 `pgrep -x`／讀 `/proc` 找到真正的 target pid，或不用 subshell 包裝。與「開機手冊」同日的 `app_stop` bug 同形：**殺與驗證要對同一個 pid**。


## 2026-08-25 的具體實例:`pgrep -x simple_switch_grpc` 回零匹配

第一式(comm 15 字元)在真實查證中咬到:`simple_switch_grpc` 是 **18 字元**,
`pgrep -x` 回零匹配並印一行 stderr 警告(`pattern that searches for process name longer than
15 characters will result in zero matches`)。⚠️ **它有印警告,所以不是全靜默** —
但當時我是拿它的**輸出**去組後續指令(`j=$(tr ... < /proc/$p/cmdline)`),
`$p` 空掉之後整串失敗訊息看起來像「檔案不存在」,警告被淹沒在後面的 traceback 裡。

⇒ 可用的替代:`ps -eo pid,args | awk '/simple_switch_grpc/ && !/awk/ {print $1; exit}'`
(`!/awk/` 排除自己那一行,比 bracket 技巧更明確)。

**同一天另一個實例**:`ps ... | grep -c` 連兩次給我錯的計數(一次 bracket 只保護 pattern、
一次 awk 只比對 `$4` 也就是 args 的第一個 token)⇒ **判斷「還有沒有在跑」要列出來看,不要數。**

## 08-25 夜：一晚新增三式，且它們屬於更大的族

| 式 | 機制 |
|---|---|
| 十 | `pgrep -f 'X' \| head -1` ——匹配到了，但 `head -1` 取 **pid 最小**的，不是這一輪起的。我據此宣稱「重建沒發生、控制組壞了」，而 `stack.sh` 的 log 有權威 pid（3234430 / 3256152）⇒ **重建其實發生了**。 |
| 十一 | `pgrep -a simple_switch_grpc`——名字 **18 字元 > `/proc/PID/comm` 的 15 字元上限** ⇒ 零匹配、警告丟 stderr、**指令成功、欄位留白**（mainDev 四輪的 `binaries.txt` 的 `bmv2:` 欄全空）。修法 `-af`。 |
| 十二 | `( cd X && nohup Y & echo $! )`——`&` 綁整個 `&&` 串，`$!` 記到 bash 為它 fork 的**外殼**（沿用父層 argv ⇒ `/proc/exe` = `/usr/bin/bash`，目標在 pid+1），而 **`kill -0` 對外殼是成功的**。 |

🔑 **十與十一是相反機制**：一個「名字被截斷 ⇒ 找不到」，一個「名字對了 ⇒ 找到錯的那個」。
🔑 **三個都只有「雜湊 executable」抓得到**——`sha256sum /proc/<pid>/exe`。
mainDev 的 `run_plane.sh` 因此同時記 `kernel_sha256_ondisk` 與 `kernel_sha256_running`
（他的臂 I 那兩欄**不同**：磁碟 3367d0e9 / 執行中 5b30e448），
`restart_kernel.sh` 的驗收條件也是 `/proc/<newpid>/exe` 的 sha256，不是 pid 也不是 argv。
⇒ 這一族的通論在 [[failures-that-report-success]]。

## 🆕 2026-08-28 夜：兩個「過濾器安靜地沒有過濾／計數器安靜地多吐一行」

**A. `pgrep -c` 沒有匹配時會「印出 0」**而且**同時 exit 1**。
所以慣用的防呆 `$(pgrep -c agy 2>/dev/null || echo 0)` 會得到 **兩行**：

```
n=$(pgrep -c agy 2>/dev/null || echo 0)   # n = "0\n0"
[ "$n" -eq 0 ]                            # bash: [: 0\n0: integer expression expected
```

我拿它當背景等待迴圈的條件（等 `agy` 排空才開臂），**條件每一圈都報錯，`until` 於是永遠繼續**
⇒ **那個 gate 從頭到尾沒有 gate 任何東西**，而畫面上跟「還在等」完全一樣。
🔑 **`|| echo 0` 是為「指令失敗時沒有輸出」設計的，而 `pgrep -c` 失敗時有輸出。**
⇒ 正確寫法就是**不要加那個 `||`**：`n=$(pgrep -c agy 2>/dev/null); n=${n:-0}`。
（與第九式「`|| echo 什麼都沒有` 把查不到和查不動寫成同一個答案」同族，
**但方向相反**：那條是 `||` 太常觸發，這條是 `||` 在不該觸發時觸發。）

**B. `ps -eo … -C <name>` 的 `-e` 會蓋掉 `-C`。**
我要看剩下那個 `agy` 還會跑多久，打 `ps -eo pid,etime,pcpu,args --no-headers -C agy`
⇒ **列出全機器 3000 個行程**（45 KB），過濾條件被安靜忽略。
拿掉 `-e` 就對：`ps -o pid,etime,pcpu,comm --no-headers -C agy`。
🔑 **與本檔其他各式同族**：**過濾器沒有過濾時不會報錯，它會給你一個「更完整」的答案。**

📌 這兩個都出現在同一個 checkpoint 前的小時裡，**而且都是在檢查「機器夠不夠安靜可以開臂」時**
——⇒ **「判斷可不可以開始量測」的那幾行，本身從來沒有被驗證過**，
它們是唯一不會有人拿已知輸入去測的程式碼。相關：[[verify-against-known-good-output]]。

## 🆕 2026-08-30：兩式，都由 `開機手冊` 的 T-2 首跑實測供稿

這兩式合力製造了一個**四項全中、每一項都很有說服力的假發現**（「fabric 不轉發」），
四小時後靠實跑推翻。兩式都不在既有清單上。

### 十三式 🔴 `kill -0` 分不出「不存在」和「不是你的」

topology 跑在 `sudo` 底下 ⇒ 非特權 shell 對它 `kill -0` 回 **EPERM**，
而 **EPERM 和 ESRCH 的 exit status 一樣**。腳本因此把一個**活著的 root 行程判成死的**，
2 秒就跳出等待、在任何交換機開始聽之前啟動 proxy，
製造出 30 個連線失敗、0 條路徑、0 台交換機——**全部是真實測到的數字，全部是自己造成的**。

✅ **正解：讀 `/proc/<pid>`**，它不管擁有者是誰都讀得到。
🔑 判準延伸：**任何「跨權限邊界」的存活檢查都要先問「失敗和沒權限長得一樣嗎」。**

### 十四式 🔴 `( … ) &` 之後的 `$!` 是 subshell，不是裡面那個行程

`kill $PROXY` 殺掉包裝的 subshell，**裡面的 python 活下來並繼續佔著 8081**。
下一輪的 proxy 綁不到 port ⇒ **每一次 API 取樣都是被上一輪的孤兒回答的**，
而那個孤兒誠實地回報「0 條 link」（它真的沒有）。
⇒ 這是那個假發現的**單一成因**。與 [[destructive-shell-traps]] 同族：**清理動作沒有清到東西**。

### 🔑 這一晚真正可重用的判準（`開機手冊` 的措辭，比我原本的清楚）

> **兩個自己的讀數不一致，在你證明之前是「儀器的發現」，不是「系統的發現」。**

當時 log 記錄了 15 行 `Discovered link` 而 API 說 0，
它**替這個矛盾發明了一個機制**（「beacon 到了但沒建成 link」）而不是問「為什麼我的兩個儀器不同意」。
⇒ 與 [[instrument-must-not-mimic-its-own-finding]] 互補：那條講「儀器長得像發現」，
這條講**「矛盾本身就是儀器故障的證據」**。

⚠️ 同輪還有第三個獨立錯誤，形狀不同但同樣安靜：
grep pattern 寫成 `link (add|up|discover)`（要求 "link" 在動詞**之前**），
而 log 寫的是 `Discovered link` ⇒ **零命中被讀成零條 link**。
＝[[grep-endpoints-misses-concatenation]] 的「關鍵詞零命中 ≠ 沒發生」再一次。

### 十五式（08-30）🔴 subagent 的死亡/完成通知會漏發——「沒收到通知」≠「還活著」

Adam 20:50 切網路，同 session 四顆背景 agent：兩顆死了**有**失敗通知、一顆
（C/E/G sweep）**無聲死**——工作其實 20:48 已做完，完成通知從沒送達，harness 也沒發
失敗通知，它就以「running」的狀態掛了 25 分鐘。我還對 Adam 說過「若它死了會有通知」——錯。
判準（當晚實證有效）：
1. **輸出檔 mtime 停滯**（symlink 要 `stat -L` 看目標，別看連結本身）；
2. **SendMessage 探測**：回「had no active task; resumed」＝它已死並被你救活；
   回「delivered」＝還活著，訊息只是排隊。探測訊息要寫成「如果你正常在跑，忽略即可」，
   對活 agent 無害。
⇒ 等通知是被動信任管道；[[verify-against-known-good-output]] 的「通知是管道不是儲存」
的前半段——**管道連「有沒有東西」都可能不告訴你**。

## 🔴 08-30 又一式：`ps -eo args= | grep -qx '.*mininet:h5'` 永遠為真

`ps` 會列出 grep 自己，而它的 argv 結尾就是 `mininet:h5`；`-x` 被 `.*` 吃掉
`grep -qx .*` 之後照樣整行命中 ⇒ **偵測「有沒有 h5」的結果與 h5 存不存在無關**。
後果不是報錯：4-host fabric 上它選了 128-host 的 pair set → `host_pid h65` die →
**流量根本沒起**，而一支 600 秒的取樣器在旁邊安靜地錄了一整輪**閒置** fabric ——
正好複製出這一輪存在的理由（T-4 的安靜網路）。
🔑 同一晚第三次同型（另兩次：等流量結束的 `while ps|grep` 迴圈自我匹配而永不結束；
`sudo -n ovs-ofctl` 需要密碼卻被我讀成「flow count: 0」，而且我印的 `rc=0` 是 `head` 的）。
⇒ 規矩：**不要用 `ps | grep <pattern>` 判斷行程是否存在**。照 `ndt:1141` 的做法——
tag 在執行時組出來、`while read` 逐行比對最後一個欄位，pattern 就不會出現在任何 argv 裡。

🔴 **08-31：「比對最後一個欄位」不是細節，它就是安全性的全部**——我派工時把這條寫成
「照 `ndt:1141` 那個形狀寫」，**限定詞掉了**，agent 忠實地照做並寫出 argv **子字串**比對，
第一版當場自我匹配：`bash -c '<提到 app 名字的腳本>'` 整段腳本文字是**一個 argv 元素**，
掃描器每 fork 一次就命中自己（`$$`／`$PPID` 擋不住，fork 有新 pid），在一台**根本沒有
那個 app 的機器上**回報找到兩隻。正解＝**逐 argv 元素**比對（等於 sig 或以 `/sig` 結尾）。
🔑 一般化：**「照 X 的做法」這種轉述會把 X 的安全條件丟掉**，而丟掉之後看起來仍然像 X。
引用一個安全做法時要連「它為什麼安全」一起寫，否則轉述本身就是缺陷的來源
（同族＝[[verify-against-known-good-output]] 的抄錄一遍找 provenance 洞）。
⇒ 併發推論：`cmd | head` 之後的 `$?` 是 `head` 的（H-21）。要判斷就別放進 pipeline。

## 🆕 十六式（08-30）🔴 `systemctl is-active ssh` 分不出「沒開」與「socket 啟動、閒著」

Ubuntu 22.10+ 起 openssh-server 預設走 **socket activation**：`ssh.socket` 是 `active`、
`ssh.service` 是 `inactive`（沒有連線進來就不起 service），**而 SSH 完全正常在服務**。
實測新機器 `nslab@172.25.197.100`：

```
systemctl is-active ssh         -> inactive     ← 我拿它當「沒開」，錯
systemctl is-active ssh.socket  -> active
ss -tlnH sport = :22            -> LISTEN 0.0.0.0:22 / [::]:22
```

我因此叫使用者去 `apt install openssh-server`（**早就裝好了**）。

🔑 **這一式的形狀與前面十五式相同，但來源不同**：不是我的 pattern 寫錯，是
**單元名字（`ssh`）不是被問的那個東西**。同一個服務有兩個 systemd 單元，
`is-active` 忠實回答了我問的那一個，而我問錯了。
⇒ 規矩：**判斷「服務通不通」要問通不通，不要問單元活不活**——
看 `ss -tlnH sport = :PORT` 有沒有印出行（`ss` 沒命中就完全不印，
不像 `grep -c` 會吐 `0` 又回 rc=1）。
⇒ 同族還有 `systemctl is-enabled`（開機會不會起）、`is-failed`——三個問的是三件事。
⇒ 這是 [[verify-the-purpose-not-the-mechanism]] 在運維指令上的版本：
**`is-active` 驗的是機制（那個 unit 現在有沒有行程），我要的是目的（連得進去嗎）。**

## 🆕 十七式（08-31）🔴 **harness 的「背景工作完成」通知，講的是 wrapper 不是工作**

`setsid nohup qemu-img convert … &` 丟進背景，harness 回報 **`status: completed`（exit code 0）**。
我據此去讀輸出檔——**而 `qemu-img` 還在跑**：`tar` 當場吐 `file changed as we read it`，
兩次 `stat` 相差 776 KB。**completed 指的是那個立刻結束的 `setsid` 外殼。**

三個獨立的讀數同時說謊，而且**方向一致（都說「做完了」）**：

| 讀數 | 為什麼是錯的 |
|---|---|
| harness 的 `completed` ／ `[1]+ Done` | 追蹤的是 wrapper，wrapper 一 fork 就退出 |
| 我記下的 `$!`（寫進 `convert.pid`） | 是 `setsid` 的 pid，**真正的 qemu-img 是它 +1**（876351 vs 876352） |
| `[ -d /proc/$p ]` 回 false | 忠實回答了「那個 wrapper 死了嗎」——是的，而工作還活著 |

✅ **唯一可靠的判準＝誰持有輸出檔的 fd**：

```bash
for p in /proc/[0-9]*; do ls -l "$p/fd" 2>/dev/null | grep -q '<輸出檔名>' && echo "${p#/proc/}"; done
```

再配「檔案大小連續兩次不變」才收工。**這是第四式／十四式（`$!` 是 subshell）的第三次發作，
但載體是新的**：前兩次是我自己的 shell，這次是 **harness 的任務追蹤**——
⇒ **凡是「非同步完成」的訊號，先問它追蹤的是哪個 pid。**
📌 同一輪還有一個對照：另一次 scp 我看到 `[1]+ Done` 就當它傳完，**實際只落地 14 MB／2.59 GB
（0.5%）而且已經死了**——`Done` 是真的，死的也是真的，只是那兩件事講的是不同的行程。

## 🆕 十八式（08-31）🔴 **`wc -l` 數的是輸出行，不是東西**

`VBoxManage list vms 2>/dev/null | wc -l` 回 **5**，我讀成「已經有 5 台 VM」，
於是準備小心地不去刪別人的東西。實際上 **VM 有 0 台**——那 5 行是
`WARNING: The character device /dev/vboxdrv does not exist.` 的多行警告，而它印到 **stdout**。

🔑 與第九式（`|| echo` 把查不到寫成一個答案）同族，但更基本：
**`| wc -l` 把「這個工具說了幾行話」當成「有幾個東西」**，而工具在錯誤／警告時話最多。
⇒ 規矩：**要計數就列出來看**（本檔 08-25 已寫過同一句），或先濾掉已知的雜訊行再數。
📌 沒有造成損害的原因值得記：我在刪任何東西**之前**先 `ls ~/VirtualBox\ VMs/` 看了目錄
（空的），沒有照那個 5 去動手。**「動手前先看目標」擋下了一個錯的計數。**

## 🆕 十九式（08-31）🔴 **在 Bash 工具裡，你的整段腳本就在某個行程的 argv 裡**

為了避開 `ps | grep` 自我匹配，我改用「讀 `/proc/*/cmdline` 再 `case` 比對」——自認安全，
還在同一段程式碼裡寫了註解提醒 `$!` 的坑。**然後它照樣匹配到兩個我自己的 wrapper shell**：

```bash
for p in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$p/cmdline"); case "$c" in *NDTwin-P4-demo.ova*nslab*) …
```

因為 harness 把**整段腳本**當成 `/bin/bash -c '<整段腳本>'` 的參數，
**那條 shell 的 argv 就含有我要找的每一個字串**。

🔑 **換工具沒有用**（本檔開頭那條通則的第四種載體）：從 `pgrep -f` 換到 `ps -eo args` 再換到
直接讀 `/proc`，**只要比對的是「命令列文字」，你自己就在樣本裡**。
⇒ 跳得出去的只有兩條：**比對結構化欄位**（fd 指向哪個檔、socket 屬於哪個 pid——
`sudo ss -lptnH 'sport = :8081'` 就是這樣抓到那個孤兒 proxy 的 pid 2373 的），
或**顯式排除自己**（`$$`／`$PPID`）。

## 🆕 二十式（08-31）：pidfile 的時戳說得出「何時」，說不出「是誰」——而我用錯誤的模型去補那一格

08-31：我在共用機器上看到 `qemu.pid` 的 mtime 是 14:41:41，判定「**我最後一次 `start` 更早，
所以不是我起的**」，並據此向兩條線回報「有第三個寫者」。

**錯的。** 那是我自己下的 `ndtwin-vm.sh snap`——**`snap` 動詞會自動重啟 VM**（stop → 快照 →
若原本在跑就 start）。腳本是我寫的。

🔑 **作者身分不是證據。**「我寫的工具」不等於「我知道它做了什麼」。我做的是**推論**
（消去法＋一個記錯的行為模型），而正確的動作是**去讀那支腳本的 case 分支**。

🔑 **而且光讀腳本也不夠**：讀腳本只能答出「`ssh` 子指令不會 auto-start」，答不出「那是誰」。
答案要的是**腳本 ＋ 我自己的指令紀錄**（session transcript 有逐字的指令與輸出）。
⇒ 歸屬問題的證據是**動作紀錄**，不是**能力推理**。

⇒ 代價是實的：另一條線因此把一個有效的校準結果 G 降級、加了紅頭、規劃重跑。

## 🔴 二十一式（08-31）：**「還沒開始」與「剛結束並清乾淨」，在同一組觀測上長得一模一樣**

要判斷另一條線那筆重負載工作有沒有在跑。我讀到兩件事：

- `/proc/diskstats` 的讀寫磁區數 **3 秒內零變化**（磁碟閒置）
- 它的中間檔（`.ova`／`.vmdk`）**一個都不存在**

我判「**它還沒開跑**」，於是排了自己的 13 GB 工作進去。
**錯的**——它 16:59:59 就開跑，**17:08 剛跑完並把 106 GB 中間檔全刪了**。

🔑 **兩個觀測都對，而它們同樣支持相反的結論**：
「檔案不在」＝還沒建 **或** 已經清掉；「磁碟閒置」＝還沒開始 **或** 已經結束。
**收乾淨做得越徹底，事後看起來就越像從來沒發生過。**

⇒ **判準**：問「這個觀測有沒有**方向**？」——
`diskstats` 的**累計計數器**有方向（跟開機以來的基準比就知道發生過多少 I/O），
而我只取了**兩個相鄰樣本的差**，把一個有方向的量用成了無方向的。
**同一支儀器，讀法決定它答不答得出時間順序。**

⚠️ **這次結論碰巧是對的**（確實沒撞到，因為它真的結束了），**但推論是無效的**。
🔴 **而這是我同一天對別人的資料講了三次的那件事**（`RSYNC_EXIT` 標記缺席、
`snaps` 讀不到印成沒有、`.bash_history` 不存在≠乾淨）。
⇒ **可轉移的是這個對稱性本身**：**我最會在自己趕時間的那一步，犯我剛剛才教會別人的錯。**
判準不是「我知不知道這條規矩」，是「**我有沒有對自己的推論也跑一次**」。

✅ **正確的問法**：不要問「它在不在跑」，要問「**它跑過了嗎**」——
後者有便宜的答案（`ls` 產物、對方的 log、累計計數器的絕對值），前者只有點取樣。


---

🔑 **本檔自己撞過兩次號**（一度有兩個「第十七式」、兩個「第十八式」）：我每次 append 都
**只看上一次自己寫的那條**去取「下一個」，而不是看全檔的最大值。已重編為二十／二十一式。

⇒ 這與 [[two-writers-one-worktree]] 第八式**是同一條**，只是這次兩個寫者都是我、
隔了幾小時。**「下一個」只要是各自算出來的，它就是一個預設值，就會撞**——
連「同一個人、同一個檔」都不例外，因為隔一段時間的我就是另一個寫者。
✅ **便宜的修法**：append 前 `grep -nE "^#+ .*式"` 看全檔最大值，不要憑印象。

**二十二式（其實是「`$!` 是 wrapper」那一式的再犯，08-31）**：
harness 用 `setsid cmd & echo $! > pidfile` 記下 pid，然後 `kill -TERM` 它。
記到的是 **4521**，真正的 `request_manager` 是 **4522**——**殺了 wrapper，本尊活著**，
佔住 `:8002`，於是下一階段跑同一支程式時 `bind: Address already in use` 直接 abort，
而那個 abort 看起來像「這支程式壞了」。

🔑 **本檔早就記著這一式，我還是踩了。** 差別在於前一次是「背景 job 的完成訊號」，
這次是「停止它」——**同一個機制，不同的動詞，我只把它記成前一個動詞的問題。**
⇒ 記這類機制時要寫「**它會影響哪些動詞**」，不要只寫發現它的那個場景。

✅ **收尾的正確查法**（不是 `pgrep -f`）：
```bash
sudo ss -tlnpH "( sport = :8002 )"      # socket → pid → /proc/<pid>/exe
```
由**它佔用的資源**反查 pid，再 `kill` 那個 pid。這條路徑不會自我匹配。
