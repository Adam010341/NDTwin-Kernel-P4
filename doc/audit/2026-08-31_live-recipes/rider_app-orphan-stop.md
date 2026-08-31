# Rider：真的養一隻孤兒 TE-App，再用 `ndt apps stop te` 停掉

[Co-developed with claude code -- Adam]

**狀態：未執行。** 這份是配方，不是結果。任何人讀到這裡，在下面的「實測紀錄」欄被填上之前，
`ndt apps stop` 的三態修法只成立到「單元變異閘」為止。

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
NDT_OWNER=$NDT_OWNER ndt apps te
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
**預期**：cmdline 含 `Traffic-engineering-App.py`；`Threads:` > 1；
兩次 `wc -l` **不相等**（log 還在長 ⇒ 行程還在工作）。
若相等，記下來——那代表這隻 TE 是靜止的，後面「停得掉」的證據強度要跟著降。

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

```bash
# c10ac7c ＝修法落地前的最後一顆；sha256 856cfb9b5a9d448aa3e14f0878c80ba84038374b339893488787c1598c1c5e34
git show c10ac7c:tools/test_workflow/ndt > /tmp/ndt-before.sh
sha256sum /tmp/ndt-before.sh          # 對上上面那串才往下走
chmod +x /tmp/ndt-before.sh
NDT_OWNER=$NDT_OWNER /tmp/ndt-before.sh apps stop te; echo "rc=$?"
test -d /proc/$TEPID && echo "STILL ALIVE AFTER OLD STOP"
```
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
| 執行日期 | **未執行** |
| commit | |
| `sha256sum tools/test_workflow/ndt` | |
| 步驟 3 log 是否在長 | |
| 步驟 5 舊行為是否重現 | |
| 步驟 6 三個介面輸出 | |
| 步驟 7 兩次 orphans rc | |
| 額外輪 `down` 結果 | |
| raw 落在 | `doc/audit/…/raw/` |
