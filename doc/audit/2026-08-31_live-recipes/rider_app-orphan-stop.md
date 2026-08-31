# Rider：真的養一隻孤兒 TE-App，再用 `ndt apps stop te` 停掉

[Co-developed with claude code -- Adam]

**狀態：2026-08-31 15:25–15:30 已執行，全步驟通過。** 見檔尾「實測紀錄」。
修法 commit ＝ **`6045cab`**（不是 `a0b0e0f`——那個物件在本 repo 不存在）。

🔴 **執行時抓到本配方自己的三個缺陷，已在下面就地更正**（步驟 2 的 stdin、步驟 3 的 `Threads:`
期望值、步驟 5 的控制組放置位置）。第三個是最嚴重的：照原文放 `/tmp` 會讓控制組
**在修法有沒有效的情況下都印出一樣的話**。

## 為什麼單元測試不夠

`tests/shell/test_ndt_app_orphans.sh` 的 52 個 check 全部通過，七個變異也全部看過紅，
但它的孤兒是 `( exec -a "python3 …/Traffic-engineering-App.py" sleep 90 )` ——
一個把 argv 換掉的 `sleep`。它對 `/proc/<pid>/cmdline` 而言與真貨無法分辨，
**但它不是真貨**，以下四件事單元測試結構上構不到：

1. 真的 TE-App 是 `python3` 起的**多執行緒**行程，SIGTERM 之後可能不會馬上死
   （`app_kill_pid` 的 5 秒 TERM 窗與 KILL 回退從來沒對真的 Python 行程走過）。
2. 真的 TE-App 起來時會有 **child**（`app_spawn` 的 `nohup` 鏈）。掃描找到的是不是同一顆？
3. 崩潰迴圈那隻是**自己重啟自己**還是單一長命行程？停掉之後會不會又長出來？
   （08-31 那隻的迴圈跑了 **20h07m02s**、穩定 3600 次／小時——見
   `app_te_log_evidence.txt`——但**「為什麼沒有人停掉它」與「它會不會自己重啟」都沒有被歸因過**。）
4. 孤兒的 pidfile 是**怎麼消失的**沒有被重現過——單元測試是 `rm` 掉的。

## 前置

- 需要 fabric 窗；先 claim：`NDT_OWNER=<you> ndt claim 60 "orphan stop rider"`
- 需要 `ndt status` 的 `measuring` 欄是 `nothing`。
- 這份配方**會啟動一個會改網路的 app（TE 裝流表規則）**，所以不要跟任何量測輪重疊。

## 步驟

全部指令從 repo 根目錄執行，`NDT_OWNER` 每一條都帶。

### 0. 記下被量的碼

```bash
git -C ~/Desktop/NDTwin-Kernel rev-parse HEAD
sha256sum tools/test_workflow/ndt
```
**預期**：兩行雜湊，記進本檔「實測紀錄」。（一次正確的量測會無聲過期——標了實測就要記 commit。）

### 1. 起 fabric 與 kernel

```bash
setsid env NDT_OWNER=$NDT_OWNER ndt up 4 < /dev/null > /tmp/rider-up.log 2>&1
grep -c 'up. ready' /tmp/rider-up.log
```
**預期**：`1`。（驗 `up. ready` 不驗 rc——`up`/`down` 會殺掉呼叫它的 shell，所以包 `setsid`。）

### 2. 起一隻真的 TE-App，確認它被追蹤

```bash
# 🔴 更正 2026-08-31（實跑抓到）：原文是裸 `ndt apps te`，起不出會工作的 TE。
# app_spawn 用「呼叫者的 stdin」跑 app（`( cd "$dir" && exec nohup "$@" ... ) &`），
# 而 Traffic-engineering-App.py 開頭就 input("Enter 1 or 2 [default 1]: ")（:599）。
#   - 從 driver 跑（stdin=/dev/null）⇒ 1 秒內 EOFError 死掉（實測，
#     raw/rider_orphan_attempt1_stdin_eof.log）。`ndt apps te` 有正確回 rc=1 並說
#     "te exited immediately"，所以是配方錯不是工具錯。
#   - 從終端機跑 ⇒ 卡在 prompt 不動，步驟 3「log 還在長」換一種方式失敗。
# mode 2 是唯一會週期性做事、而且之後不再讀 stdin 的模式。
printf '2\n5\n' | NDT_OWNER=$NDT_OWNER ndt apps te
NDT_OWNER=$NDT_OWNER ndt apps status
cat .test_run/pids/app_te.pid
```
**預期**：
- `apps te` 印 `ok  te started (pid NNNN) -> .test_run/logs/app_te.log`
- `apps status` 的 te 那列是 `te       running   Traffic-Engineering-App …`
- pidfile 內容 == 上面那個 `NNNN`

把 `NNNN` 記成 `$TEPID`。

### 3. 確認它真的在動（否則後面停的是一具屍體）

```bash
TEPID=$(cat .test_run/pids/app_te.pid)
tr '\0' ' ' < /proc/$TEPID/cmdline; echo
awk '/^Threads:/{print}' /proc/$TEPID/status
wc -l .test_run/logs/app_te.log
sleep 20
wc -l .test_run/logs/app_te.log
```
**預期**：cmdline 含 `Traffic-engineering-App.py`；
兩次 `wc -l` **不相等**（log 還在長 ⇒ 行程還在工作）。
若相等，記下來——那代表這隻 TE 是靜止的，後面「停得掉」的證據強度要跟著降。

🔴 **更正 2026-08-31：原文寫 `Threads:` > 1，這個期望值是錯的，而且不該用補的。**
mode 2 **不會**起 `enter_listener` 執行緒（`Traffic-engineering-App.py:622-624` 明寫
"kick off Enter listener only in mode 1"），實測 `Threads: 1`。
更重要的是**上面「為什麼單元測試不夠」的第 1 點前提是錯的**：這支 app
**一個 signal handler 都沒裝**——`signal` 只出現在 `:29` 的 import，全檔零使用。
SIGTERM 走 Python 預設處置＝整個行程立刻結束，**與執行緒數無關**。
所以 `app_kill_pid` 的「5 秒 TERM 窗 ＋ KILL 回退」**用這支 app 永遠構不到**，
加執行緒也構不到。要驗那段回退，需要一個**會忽略或延遲 SIGTERM** 的 fixture，不是這一支。

### 4. 製造孤兒：把 pidfile 拿走（**不要動行程**）

```bash
cp .test_run/pids/app_te.pid /tmp/rider-te-pid.bak
rm .test_run/pids/app_te.pid
ls -la .test_run/pids/
test -d /proc/$TEPID && echo "PROCESS STILL ALIVE"
```
**預期**：`pids/` 裡沒有 `app_te.pid`；印出 `PROCESS STILL ALIVE`。
**這一步的斷言是必要的**——如果 `rm` 順手殺死了行程，後面整段實驗量的是空氣。

### 5. 舊行為的對照（用備份的 pristine 版本跑，只讀不改工作區）

🔴 **更正 2026-08-31：原文的 `/tmp/ndt-before.sh` 會讓這個控制組完全沒有鑑別力。**
`ndt` 用 `REPO="$(cd "$HERE/../.." && pwd)"`（`ndt:53-54`）推自己的 repo。放在 `/tmp`
⇒ `HERE=/tmp`、**`REPO=/`**，舊版 `app_stop` 於是去看 `/.test_run/pids/app_te.pid`，
當然不存在，於是印出 `te not running` 並 `return 0`——**但那是「路徑錯」印的，不是
「pidfile 與行程脫鉤」印的**。舊碼就算是好的，這一步也照樣「通過」。
⇒ 控制組必須放在 `$HERE/../..` 解得回本 repo 的位置，**並且要先證明它真的接對了**。

```bash
# c10ac7c ＝修法落地前的最後一顆；sha256 856cfb9b5a9d448aa3e14f0878c80ba84038374b339893488787c1598c1c5e34
BEFORE=tools/test_workflow/ndt_before_c10ac7c.sh   # 必須在 tools/test_workflow/ 底下
git show c10ac7c:tools/test_workflow/ndt > "$BEFORE"
sha256sum "$BEFORE"                   # 對上上面那串才往下走
grep -c apps_orphans "$BEFORE"        # 必須是 0，否則抓錯版本
chmod +x "$BEFORE"

# 5a. 控制組的接線檢查（原文缺這一步）：pidfile 還在的時候，舊版必須「看得見」這隻 app。
#     看不見 ⇒ 它根本沒指著這個 repo，5b 的 "te not running" 一文不值，停手。
NDT_OWNER=$NDT_OWNER "$BEFORE" apps status     # te 那列必須是 running

# 5b. 拿掉 pidfile 之後，才是真正的控制組
NDT_OWNER=$NDT_OWNER "$BEFORE" apps stop te; echo "rc=$?"
test -d /proc/$TEPID && echo "STILL ALIVE AFTER OLD STOP"
```

⚠️ **這是共用 worktree，`$BEFORE` 是未追蹤檔，任何人一次 `git add -A` 就會把它送進版控。**
用完立刻刪，並且**驗狀態不驗 rc**：`test -e "$BEFORE" && echo STILL-PRESENT || echo GONE`。
（本輪就是這樣處理的：跑完 → `ndt down` 驗清 → 才刪 → `test -e` 驗掉。）
**預期**（這是 08-31 記錄的壞行為，要在同一台機器上再看一次）：
```
  te not running
rc=0
STILL ALIVE AFTER OLD STOP
```
如果舊版**沒有**印 `te not running`，停手——代表歸因錯了，整張工單的前提要重查。

### 6. 新行為

```bash
NDT_OWNER=$NDT_OWNER ndt apps orphans; echo "rc=$?"
```
**預期**：
```
  XX  te: pidfile-lost-but-alive -- Traffic-Engineering-App    (CHANGES the network: installs flow rules)
  XX      pid <TEPID>  python3 …/Traffic-engineering-App.py
  XX      stop it with:  ndt apps stop te
  XX  1 app(s) are running without a pidfile that names them
rc=1
```

```bash
NDT_OWNER=$NDT_OWNER ndt apps status
```
**預期**：te 那列是 `ORPHAN`，下一行帶 `^ pid(s) <TEPID>`。

```bash
NDT_OWNER=$NDT_OWNER ndt status --check; echo "rc=$?"
```
**預期**：`running` 區塊有 `untracked  te(<TEPID>) -- running, and no pidfile names them`，
結尾 `check: N problem(s)` 其中一條是
`untracked app process(es) with no pidfile: te(<TEPID>)`，`rc=1`。

```bash
NDT_OWNER=$NDT_OWNER ndt apps stop te; echo "rc=$?"
```
**預期**：
```
  !!  te is RUNNING as pid(s) <TEPID> and the pidfile does not name it
  !!    this is the state that used to answer 'not running' with rc 0
      pid <TEPID>: python3 …/Traffic-engineering-App.py
  ok  te stopped (was: pidfile-lost-but-alive)
rc=0
```

### 7. 驗它真的停了（三個獨立證據，不要只看訊息）

```bash
test -d /proc/$TEPID && echo "STILL THERE" || echo "GONE"
NDT_OWNER=$NDT_OWNER ndt apps orphans; echo "rc=$?"
sleep 30; NDT_OWNER=$NDT_OWNER ndt apps orphans; echo "rc=$?"
```
**預期**：`GONE`；兩次 orphans 都是 `ok  no untracked app processes` 與 `rc=0`。
第二次隔 30 秒是為了排除「它自己會重啟」——08-31 那隻迴圈跑了 20h07m02s 而沒有人停掉它，
機制沒有被歸因，**如果第二次 rc=1，那是新發現，不是這個修法失敗**。

### 8. 收乾淨

```bash
setsid env NDT_OWNER=$NDT_OWNER ndt down < /dev/null > /tmp/rider-down.log 2>&1
NDT_OWNER=$NDT_OWNER ndt release
```

## 額外一輪（可選但便宜）：`ndt down` 會不會把孤兒帶走

重複步驟 1–4，然後**不要**跑 `apps stop`，直接：

```bash
setsid env NDT_OWNER=$NDT_OWNER ndt down < /dev/null > /tmp/rider-down2.log 2>&1
grep -E 'running untracked|stopped te|could NOT stop te' /tmp/rider-down2.log
test -d /proc/$TEPID && echo "SURVIVED DOWN" || echo "REAPED BY DOWN"
```
**預期**：log 裡有 `te is running untracked (pid <TEPID>) -- stopping it by pid` 與 `stopped te`；
印出 `REAPED BY DOWN`。（舊碼會印不出前者、而且 `SURVIVED DOWN`。）

## 實測紀錄

| 欄位 | 值 |
|---|---|
| 執行日期 | **2026-08-31 15:25–15:30**（driver＝`raw/drive_rider_orphan.sh`，log＝`raw/rider_orphan.log`） |
| commit | 樹在跑的當下是 `fca3a03`，但**被量的是檔案不是樹**：`tools/test_workflow/ndt` 最後一次被寫是 **`b50cb5f`**；本輪期間另外四個 session 推了 commit，該檔未被動 |
| `sha256sum tools/test_workflow/ndt` | `67412ba47f9d4d337536e886ffaded7fe05f72ad7992067956cbe3c5fbe32c75`（**開跑 15:13:54 與收工 15:30:15 兩次相同**） |
| 控制組 sha256 | `856cfb9b…c1e34`，`grep -c apps_orphans` ＝ 0 ✅ 與本檔宣告一致 |
| fabric | `ndt up ovs4`（**不是配方寫的 `ndt up 4`**——見下方「平面」註） |
| 步驟 2 | 🔴 裸 `ndt apps te` 起不來（EOFError）；改 `printf '2\n5\n' \|` 後 `ok te started (pid 1185971)`、`apps status` ＝ `running`、pidfile ＝ 1185971 ✅ |
| 步驟 3 log 是否在長 | ✅ **有**，20 秒 5 → 53 行。`Threads: 1`（配方期望值已更正，見步驟 3） |
| 步驟 3b 控制組接線 | ✅ 舊版看得見（`te running`）⇒ 步驟 5 有鑑別力 |
| 步驟 4 | pidfile 移除後 `PROCESS STILL ALIVE (1185971)` ✅ |
| 步驟 5 舊行為是否重現 | ✅ **完全重現**：`te not running` ／ `rc=0` ／ `STILL ALIVE AFTER OLD STOP` |
| 步驟 6 三個介面輸出 | ✅ 四個都對：`apps orphans` rc=1＋指名 pid；`apps status` ＝ `ORPHAN` ＋ `^ pid(s) 1185971`；`status --check` ＝ `untracked te(1185971) -- running, and no pidfile names them`、rc=1；`apps stop te` ＝ `!! te is RUNNING as pid(s) …`＋`ok te stopped (was: pidfile-lost-but-alive)`、rc=0 |
| 步驟 7 兩次 orphans rc | ✅ **0 與 0**（t+0、t+30s），`/proc/1185971` 不存在，獨立 `/proc` 全掃 leftover TE ＝ 0 |
| 額外輪 `down` 結果 | ✅ `!! te is running untracked (pid 1210239) -- stopping it by pid` ＋ `stopped te` ＋ `REAPED BY DOWN`；`ndt down` 收尾五項全 ok |
| raw 落在 | `doc/audit/2026-08-31_live-recipes/raw/`（`drive_rider_orphan.sh`、`rider_orphan.log`、`rider_orphan_attempt1_stdin_eof.log`、`rider_app_te.log`、`w2_down.log`） |

### 平面：本輪跑在 ovs4，不是配方寫的 p4

配方步驟 1 寫 `ndt up 4`（＝p4）。本輪與 A-2 §5.3 共用同一個 fabric 窗，而 **A-2 只在 OVS
平面成立**（機制是 kernel 對 Ryu `:8080` 的 topology poll），所以整窗跑 `ndt up ovs4`。
對本配方而言這個代換**不影響任何一格的鑑別力**：TE-App 唯一的外部相依是
`http://localhost:8000/ndt/`（`Traffic-engineering-App.py:32`），兩個平面都提供；
而受測機制（`app_probe` 的三態、`app_kill_pid`、`apps orphans`、`down` 的 app 迴圈）
全部在 shell 層，與資料平面無關。

### 本配方「單元測試構不到」四點的實際覆蓋

1. **多執行緒 Python 的 TERM 窗／KILL 回退** — ❌ **構不到，而且不是這一輪的問題**：
   TE-App 沒裝任何 signal handler ⇒ SIGTERM 立即結束，回退路徑不可達。見步驟 3 的更正。
2. **`app_spawn` 的 `nohup` 鏈會有 child** — ✅ **前提被推翻**：`app_spawn` 用的是
   `exec nohup`，行程只有一顆、沒有 wrapper 父行程；pidfile 記的 `$!` 就是 python 本身
   （實測 `children` 欄為空，掃描到的與 pidfile 是同一顆）。
3. **停掉之後會不會又長出來** — ✅ 兩次 `orphans`（t+0、t+30s）都 rc=0，`/proc` 全掃 0。
   ⚠️ 但本輪那隻是**健康的 mode-2 迴圈，不是 08-31 那隻崩潰迴圈**，
   「崩潰迴圈會不會自我重啟」仍未歸因。
4. **孤兒的 pidfile 是怎麼消失的** — ❌ **仍未重現**：本輪與單元測試一樣是 `rm` 掉的。
