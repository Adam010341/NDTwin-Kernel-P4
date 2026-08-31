# Rider：A-2 的 `--max-time 5` 那一支——不需要 sudo，也不需要 iptables

[Co-developed with claude code -- Adam]

**狀態：未執行。** 這份是配方，不是結果。

## 為什麼要另外一支

`687de6c` 在三個 curl 上加了**兩個**期限，因為它們對應**兩種實測過的故障**：

| 旗標 | 對應的故障 | live 驗過了嗎 |
|---|---|---|
| `--connect-timeout 2` | SYN 被丟掉（131 秒 IPv6 黑洞那一類） | 🟢 **2026-08-31 已驗**，見 `11_behavior-evidence.md` §5.3 |
| `--max-time 5` | controller **accept 之後不回**（Ryu wedge 本身的形狀） | 🔴 **未驗**，只有單元變異閘 M10 |

08-31 那一輪用的注入是 `iptables -I INPUT -p tcp --dport 8080 -j DROP`。
**那條規則丟的是 SYN，所以每個請求都死在 `--connect-timeout`，`--max-time` 永遠碰不到**
（實測 elapsed 6.024s ＝ 3×2s，而不是配方原本寫的 ~15s ＝ 3×5s）。
⇒ **換一種注入才能打到另一支。判準要跟著注入手法走。**

🔑 **這一支不需要 sudo。** sudoers 只授權 `-I`／`-D INPUT -p tcp --dport 8080 -j DROP`
兩道逐字命令，做不出 accept-then-stall；但「accept 了不回答」用一個**使用者權限的 listener**
就做得到——`:8080` 是 8000 以上的非特權埠。

## 前置

- 需要 fabric 窗；`ndt up ovs4`（**OVS 平面**，A-2 在 P4 上不存在）。
- 🔴 **這一支會停掉 Ryu，把它排在窗的最後、teardown 之前。**
  停掉 Ryu 之後控制平面就沒了，要復原只能 `ndt down` ＋ `ndt up ovs4`。
  所以：**先跑完所有其他項目，再跑這一支，然後直接 `ndt down`。**
- `NDT_OWNER` 每一條都帶；先 claim，`measuring` 要是 `nothing`。

## 步驟

### 0. 記下被量的 binary（不是 mtime，要 commit ＋字串）

```bash
sha256sum build/bin/ndtwin_kernel
strings -a build/bin/ndtwin_kernel | grep -c 'topology poll got no answer'   # 要 1
readelf -d build/bin/ndtwin_kernel | grep -E 'RUNPATH|RPATH'                 # 記下（08-31 是「沒有」）
```

### 1. 正對照：Ryu 現在是會回答的

```bash
curl -s -o /dev/null --max-time 3 -w '%{http_code}\n' http://localhost:8080/v1.0/topology/switches
grep -c 'topology poll got no answer' .test_run/logs/kernel.log   # 要 0
```
**預期**：`200` 與 `0`。**先證明它本來是好的，才有資格說它壞了。**

### 2. 停掉 Ryu——讀 pidfile、驗身分、按 PID 停

```bash
RYUPID=$(cat .test_run/pids/ryu.pid)
tr '\0' ' ' < /proc/$RYUPID/cmdline; echo      # 必須看到 ryu-manager / intelligent_router
kill -TERM $RYUPID
for i in $(seq 1 20); do [ -d /proc/$RYUPID ] || break; sleep 0.5; done
test -d /proc/$RYUPID && echo "STILL ALIVE" || echo "RYU STOPPED"
```
🔴 **永不 `pkill -f`／`pgrep -f`。** 先斷言「它曾經存在」（cmdline 對得上），再斷言它停了。

### 3. 用一個接了不回的 listener 佔住 `:8080`

**分兩道命令**：先寫檔，再執行。（同一道命令裡用 heredoc 產生又執行，
父 shell 的 cmdline 會帶著整段內容——這對後面那個 `/proc` 掃描器是會出錯的。）

```bash
mkdir -p .test_run/ctl        # .gitignore:21 已忽略；共用 worktree 不要留未追蹤檔
cat > .test_run/ctl/stall_8080.py <<'PY'
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 8080)); s.listen(64)
held = []                      # accept 之後把連線留著、一個位元組都不寫
while True:
    c, _ = s.accept(); held.append(c)
PY
setsid python3 .test_run/ctl/stall_8080.py </dev/null >.test_run/logs/stall_8080.log 2>&1 &
echo $! > .test_run/ctl/stall.pid          # 記在起的當下；之後不必再去「找」它
sleep 1
tr '\0' ' ' < /proc/$(cat .test_run/ctl/stall.pid)/cmdline; echo   # 驗身分：要看到 stall_8080.py
```

### 4. 🔴 注入斷言：確認是「接了不回」，不是「連不上」

**這一步不能省。** 「port 關著」與「accept 之後不回」都給 `%{http_code}` ＝ `000`，
但它們打到的是**不同的旗標**——連不上走 `--connect-timeout`，那就退化成已經驗過的那一支了。

```bash
time curl -sS -o /dev/null --max-time 3 -w '%{http_code}\n' http://localhost:8080/v1.0/topology/switches
```
**預期**：`000`，curl 說 **`(28) Operation timed out`**，而且 `real` **≈3.0 秒**。
**失敗的樣子**：立刻回來（<0.1s）且 curl 說 `(7) Failed to connect` ／ `Connection refused`
⇒ listener 沒起來，**停手**，這樣跑下去量到的是 `--connect-timeout`。

### 5. 等兩個 poll 週期，同時獨立見證 poll 還在跑

poll 週期＝monitor 起來後前 90 秒 5 秒一次，之後 30 秒一次
（`TopologyAndFlowMonitor.cpp` `run()`：`kWhileConverging`／`kOnceConverged`）。
⇒ 至少等 **115 秒**。

用 08-31 那支取樣器（`audit-raw 243e7e7` 的 `w2_drive_a2_wedge.sh`，`curl_children()`），
**pattern 放腳本裡的變數、腳本單獨一道命令執行**。

**預期**：每一輪 poll 的 curl 子行程**活約 15 秒**（3×5s），不是 6 秒。
🔑 **這就是本輪與 08-31 那輪的判別點。**

### 6. 讀 log

```bash
grep -c 'topology poll got no answer' .test_run/logs/kernel.log
grep -n  'topology poll got no answer' .test_run/logs/kernel.log
grep -n  'curl: (28)' .test_run/logs/kernel.log | tail -5
```
**預期**：
- **恰好 1 行** WARN（邊沿觸發），不管跑過幾輪 poll；
- 該行的 `after {:.3f}s` **≈15 秒**（08-31 那輪是 6.024s）；
- curl 自己的診斷是 **`(28) Operation timed out after 5000-ish ms`**，
  而不是 08-31 那輪的 `Failed to connect ... after 2001 ms`。**這兩句話分辨兩支旗標。**

⚠️ **「恰好 1 行」單獨看沒有鑑別力**：執行緒如果死在第一輪也是一行。
必須配步驟 5 的獨立見證（≥2 輪 poll 各自起過 curl），或步驟 7 恢復行的 `N silent pass(es)`。

### 7. 恢復

```bash
SPID=$(cat .test_run/ctl/stall.pid)                 # 步驟 3 起的當下就記下來了
tr '\0' ' ' < /proc/$SPID/cmdline; echo             # 先斷言它曾經存在、而且是那一顆
kill -TERM $SPID
for i in $(seq 1 10); do [ -d /proc/$SPID ] || break; sleep 0.5; done
test -d /proc/$SPID && echo "STALL LISTENER STILL ALIVE" || echo "STALL LISTENER STOPPED"
```
🔴 **不要 `pgrep -f python3` 去「找」它**——那既會自我匹配，也會掃到別的 session 的 python。
Ryu 已經停了，所以 poll **不會**恢復成 200——這一支**不驗恢復 INFO**（那條 08-31 驗過了）。
直接收乾淨：

```bash
rm -f .test_run/ctl/stall_8080.py .test_run/ctl/stall.pid
test -e .test_run/ctl/stall_8080.py && echo STILL-PRESENT || echo GONE
setsid env NDT_OWNER=$NDT_OWNER ndt down < /dev/null > /tmp/a2mt-down.log 2>&1
NDT_OWNER=$NDT_OWNER ndt release "..."
```

## 每一格的鑑別力（修法完全沒效的話，哪一格會紅）

| 格 | 修法無效時 |
|---|---|
| WARN 出現 | **紅**：沒有 `--max-time` ⇒ curl 永遠等下去 ⇒ poll 執行緒卡死 ⇒ 一行都不會有 |
| elapsed ≈15s | **紅**：無界就沒有 elapsed 可讀；若讀到 ~6s 代表注入退化成 connect 失敗（步驟 4 沒守住） |
| curl 診斷是 `(28) ... 5000 ms` | **紅**：`-s` 會吞掉；`2001 ms` 代表打到的是另一支旗標 |
| ≥2 輪 poll 各起過 curl | **紅**：無界的話第一輪就再也不回來 |

## 實測紀錄

| 欄位 | 值 |
|---|---|
| 執行日期 | **未執行** |
| kernel binary sha256 ／ RUNPATH | |
| 步驟 4 注入斷言（`real` 秒數＋curl 錯誤碼） | |
| 步驟 5 每輪 curl 存活秒數 | |
| WARN 行數／`after` 秒數 | |
| curl 診斷字串 | |
| raw 落在 | `audit-raw` |
