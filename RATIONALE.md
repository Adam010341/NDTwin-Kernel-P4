# G-6 — `ndt apps` liveness is a claim, not a measurement

分支 `fix/g6-ndt-apps-liveness`，base `6283ff5e19e6c6cee71ba6d04019bda936c90729`（trunk，2026-09-02 23:20）。

[Co-developed with claude code -- Adam]

---

## 1. 問題

兩個病灶，證據都是今晚 live round 的 raw：

**① start 讀的是「請求被接受」，不是「程式活著」**
（`doc/audit/2026-09-02_live-round/raw/C26_apps_stop_falseok.log`）

```
energy) sudo -n "$LAB" energy-start >/dev/null && ok "energy started (tmux: energy)" ;;
sim)    sudo -n "$LAB" sim-start    >/dev/null && ok "sim started (tmux: sim)" ;;
```

`&&` 讀的是 `ndtwin-lab <name>-start` 的 rc，而那個子命令是
`tmux new-session -d ... ; echo` —— tmux 對「我建好一個 session 了」回 0，對「那個程式一秒後
還在不在」什麼都沒說。C26 把兩條路徑並排跑出來的對照就是這件事：

```
te  (app_spawn) -> 'XX te exited immediately', rc=1   <- honest
sim (tmux)      -> 'ok sim started (tmux: sim)', rc=0  <- true here ONLY because the
                    binary exists on this machine; the check itself cannot tell.
```

`app_spawn`（nsr/viz/te）從 08-20 起就有 `sleep 1; kill -0`。兩個 lab app 沒有。

**② stop 對從來沒啟動過的東西回報成功**
（同上，加 `D1_teardown.log`）

```
energy) sudo -n "$LAB" energy-stop >/dev/null 2>&1; ok "energy stopped" ;;
sim)    sudo -n "$LAB" sim-stop    >/dev/null 2>&1; ok "sim stopped" ;;
```

注意是 `;` 不是 `&&`：rc 不是沒檢查，是被丟掉了，`ok` 無條件印。
nsr/viz/te 那條路徑的**話**從 08-31 起就誠實了（`te not running (no live instance found...)`），
**退出碼**沒有——仍然是 0。所以 D1 的 teardown 五個 app 停了三個、兩個從來沒起來過，
`APPS_STOP_ALL_RC=0`，跟五個全停的 teardown 給出同一個碼。

**③（修的時候才看見的第三件事）** 舊 `app_probe` 對 energy/sim 的註解寫著
「lab_session is the witness and there is nothing for a /proc scan to add」。兩半都不成立，
而且錯的方向相反：session 存在不代表程式活著（①），程式活著也不代表有 session——
**手動在 lab socket 外面起的 energy 會把交換機關掉**，而舊碼對它回答「not running」。
這是 pidfile 那批 app 曾經有過的同一種盲點，只是換了個witness。

---

## 2. 修法

`tools/test_workflow/ndt`，六處：

| 位置 | 改動 |
|---|---|
| `app_sig` | energy/sim 有了 signature（`energy_saving_app`／`simulation_platform_manager`），/proc 掃描才問得出「它在不在」 |
| `app_probe` | energy/sim 改成**兩個 witness**：session 說「lab 有沒有起過它」，掃描說「它在不在」，兩個合起來才決定狀態 |
| `app_wait_started`（新） | 起完輪詢最多 5s，直到掃描真的看見它；看不見就說為什麼（含「session 在、裡面沒東西」） |
| `app_wait_stopped`（新） | 停完輪詢，直到沒有東西帶著那個 signature；還在就列 pid、說 lab 停的是 session、交給人 |
| `app_start` / `app_stop` energy\|sim | 走上面兩個 helper；`ok` 只在驗過之後印 |
| `app_stop` / `cmd_apps stop` | 退出碼從兩種變三種 |

狀態機（energy/sim）：

| lab session | /proc 掃描 | 狀態 | 舊碼 |
|---|---|---|---|
| 有 | 有 | `running` | `running` ✅ |
| 有 | 無 | `not-running` + `APP_SESSION_WITHOUT_PROCESS=1` | `running` ❌ ←C26 |
| 無 | 有 | `pidfile-lost-but-alive`（orphan） | `not-running` ❌ |
| 無 | 無 | `not-running` | `not-running` ✅ |

`APP_SESSION_WITHOUT_PROCESS` 是掛在 `not-running` 上的**理由**，不是第四種狀態：
只問「起來了沒」的呼叫端繼續讀 `APP_STATE`，不必學新字。

---

## 3. 行為變更前後對照（🔴 這是要 Adam 早上看的部分）

| 情境 | 修法前 | 修法後 |
|---|---|---|
| `ndt apps sim`，binary 不存在／秒死 | `ok sim started (tmux: sim)`，rc 0 | `XX sim did not start` ＋「session 在、裡面沒東西」＋指向 `sim-out`，**rc 1** |
| `ndt apps stop sim`，從沒起過 | `ok sim stopped`，rc 0 | `sim not running (no live process carries its signature)`，**rc 2** |
| `ndt apps stop te`，沒在跑 | `te not running`，**rc 0** | 同樣的話，**rc 2** |
| `ndt apps stop all`，整台機器閒置 | rc 0 | **rc 2**＋`nothing to stop (5 app(s) were already not running)` |
| `ndt apps stop all`，五個裡有一個在跑 | rc 0 | rc 0＋`stopped 1; 4 were already not running` |
| energy 在 lab session 外面跑著 | `ndt apps` 顯示 `-`；`stop` 回 `ok energy stopped` rc 0 | `apps_status` 顯示 `ORPHAN`；`stop` 印 STILL RUNNING、列 pid、**rc 1** |
| `ndt down` | 同上的假 ok | rc 2 認成 `$a had already exited`，不是失敗 |

**退出碼契約**（寫進 `app_stop` 檔頭）：

```
0  它在跑，現在不跑了
2  沒有東西可停 —— 由掃描證實，不是從「沒有 pidfile」推論的
1  停不掉／pidfile 被下毒／不認識這個 app
```

🔴 **對既有 script 的影響**：把「非 0 就是失敗」的呼叫端會把 rc 2 看成失敗。
repo 內只有 `ndt down` 是這種寫法，已改成只把 rc 1 當失敗（見表末列）。
repo 外的 driver script（例如產生 `APPS_STOP_ALL_RC` 的那支）**要 Adam 決定**是改讀
`rc != 1`，還是就讓它看見 rc 2——後者其實是這次修法的重點：那個 0 本來就不該是 0。

---

## 4. 變異閘門紅→綠

`tests/shell/mutate_g6_apps_liveness.sh`，五個變異各自把**修法前的原文**放回去，
跑套件，記錄**是哪一個具名檢查**變紅（不是「有東西紅了」）：

```
=== baseline (the fix, unmutated) ===
  rc=0  red=

=== mutations ===
  start-reads-request-rc     caught by: start of an app that never came up -> rc 1
  stop-unconditional-ok      caught by: stop of a never-started lab app -> rc 2
  probe-session-only         caught by: session up + NO process     -> not-running
  notrunning-rc-zero         caught by: stop of a never-started pidfile app -> rc 2
  aggregate-or-rc1           caught by: nothing was running -> rc 2
  control-comment-only       SURVIVED (control, as required)

restore: tools/test_workflow/ndt is byte-identical to the pre-gate snapshot

VERDICT: every mutation was caught by the check named for it; the control survived
```

只註解的對照組**存活**，所以這個閘門量的是行為不是「檔案變了」。
`cp -p` 快照＋EXIT trap＋結束時 `cmp` 對帳，baseline 是**工作樹**不是 HEAD。

測試本身：`tests/shell/test_ndt_apps_liveness.sh`，44 checks 全綠。
既有的 `tests/shell/test_ndt_app_orphans.sh` 52 checks 全綠——**其中兩條被我改了**：

```
- check "nothing running -> rc 0"                   0 "$rc"
+ check "nothing running -> rc 2 (was 0 before G-6)" 2 "$rc"
- check "stale pidfile naming a stranger -> rc 0"   0 "$rc"
+ check "stale pidfile naming a stranger -> rc 2"   2 "$rc"
```

這兩條是**舊契約寫在哪裡**的證據，不是被我弄鬆的測試：它們在修法前是綠的、修法後轉紅，
我把契約改過來它們才回綠。上面「行為變更對照」表的第三列就是它們在講的事。

---

## 5. 風險與回退

**風險**

1. **`sim` 的 signature 會 match 兩個 pid**：`script -qfa <log> -c ./simulation_platform_manager`
   和它 exec 出來的 `./simulation_platform_manager` 都帶那個字串。所以每個呼叫端問的都是
   「至少有一個嗎」，沒有任何地方問「剛好一個嗎」。已寫進 `app_sig` 的註解。
2. **`start` 現在最多多花 5 秒**才判失敗（成功就立刻回）。這是拿延遲換「ok 是真的」。
3. **`pidfile-lost-but-alive` 這個狀態名對 energy/sim 是誤稱**（它們沒有 pidfile）。
   沒有改名：那個字串被 `apps_orphans` 的輸出和既有測試綁著，改名是另一個 diff。
   訊息本身講的是對的事（"running OUTSIDE the lab session"）。
4. **rc 2 會讓「非 0 即失敗」的外部 script 變紅**。見 §3 的紅字。

**沒有做的事**

- 沒有碰 lab：整套測試把 `sudo` 和 `lab_session` 換成 shell function，跑不到 ndtwin-lab、
  不要 root、動不到別人 claim 的 testbed。
- 沒有碰 `tools/test_workflow/ndtwin-lab`（那是 G-7／G-9 的檔案）。

### 🔴 這支分支**沒有**修什麼，以及它為什麼**碰巧**沒有被同一個形狀咬到（2026-09-03 03:50 自查）

套用當晚談出來的判準——**鑑別力測試只證明它對你注入的輸入有鑑別力；若那些輸入抽自已涵蓋的
集合，測試在結構上照不出未涵蓋的部分**——回頭檢視 G-6，用的是一個**實測到的**輸入而不是我發明的。

**那個輸入**（`doc/audit/2026-09-02_live-round/ADDENDUM-01-viz-orphan-contamination.md`，
已提交於 `b4ee69bf`；不在本分支 base `6283ff5e` 上，我在主工作樹讀的）：

```
pid 893609  ppid 2859     elapsed 01:54:08   1.2% cpu    9.5 MB   java   (wrapper)
pid 893799  ppid 893609   elapsed 01:54:07   111% cpu   247 MB    java   (the viz JVM)
```

`ndt apps stop viz` 對**單一 pid**（bash wrapper）送 TERM，而 `app_spawn` **沒有 `setsid`、
沒有自己的 process group** ⇒ JVM 活下來並被 reparent。之後 `ndt status`、`ndt apps orphans`、
teardown log **三個通道全部**回報 viz 沒在跑（原文：`viz not running (no live instance found by
pid or by scan)`）。它跑了 1h54m、111% CPU、寫了 875 MB log。

#### 🔴 G-6 沒有修這個，而且不要把「兩個 witness」讀成修了它

我親自查證的鏈路（`/home/adam/Network-Traffic-Visualizer/network_traffic_visualizer.sh`，362 bytes）：

```
network_traffic_visualizer.sh   (bash)      ← app_spawn 記到的就是這個 pid
  └─ ./mvnw javafx:run          (maven wrapper，又是一支 shell script)
       └─ java (maven)          ← 觀測到的 893609
            └─ java (JavaFX app) ← 觀測到的 893799，111% CPU
```

**三層，不是兩層。** 而 `app_sig viz` 是 `network_traffic_visualizer.sh` ——
**存活下來的那兩個 java 的 cmdline 裡不會有這個字串**，所以 `app_scan_pids viz`
在結構上找不到它們。這條路徑（nsr/viz/te 的掃描邏輯）**早於本次修法且未被本次修法改動**。

📌 通則（auditor 2026-09-03，我確認）：**任何靠名字比對的 witness，在「存活者不帶那個名字」
的形狀下都會失效。** `comm` 是 `java`，cmdline 是 maven／JVM 的——沒有一個帶得上 app 的身分。
**修法方向應該是路徑式而不是名字式的 signature**（存活的 JVM 的 argv 很可能帶
`/home/adam/Network-Traffic-Visualizer/`），**外加 `app_spawn` 用 `setsid`／process group
讓 stop 停得掉整棵樹**。🔴 **「JVM 的 argv 帶專案路徑」是我的推測，沒有實測**——
現在沒有 viz 在跑，argv 我拿不到。**要 L6 驗過才能當成修法依據。**

#### 我改的那半（energy／sim）**沒有**被這個形狀咬到，而且理由是可查證的

- `/home/adam/Energy-Saving-App/energy_saving_app` 與
  `/home/adam/Simulation-Platform-Manager/simulation_platform_manager`
  **兩個都是 ELF 執行檔**（`file` 查的，2026-09-03），不是會 exec 出 JVM 的 shell wrapper。
- 所以**存活的那個行程自己的 argv 就帶著 signature**：sim 在 `script -qfa LOG -c
  ./simulation_platform_manager` 底下時，wrapper 與 child **兩個都** match（已寫進 `app_sig` 註解）；
  wrapper 死了，child 仍然 match。

⇒ **這是結構上的安全，不是我測出來的安全**——我的 fixture 一樣是自己發明的。
差別在於這一次我能指出「為什麼它不可能長成那個形狀」，而 viz 那條我指不出來。

**待 live 驗證**（要真 fabric／真 app，我沒做）

- L1 真的 `ndt apps sim` 一次，確認 5s 內看得到 pid、`ok` 印得出來。
- L2 把 `SIM_DIR` 的 binary 暫時改名，再 `ndt apps sim`，確認 rc 1 且訊息指向 `sim-out`。
- L3 手動在 lab 外面起一個 energy，確認 `ndt apps` 顯示 ORPHAN、`stop` 回 rc 1。
- L4 整輪 teardown 跑一次，確認 `APPS_STOP_ALL_RC` 是 0 還是 2，並對帳 D1。
- 🔴 **L5（合併前必要條件，與 G-9 的 L2 同性質）** 起一個真的 energy 與 sim，
  **先把完整 argv 印出來存進 audit-raw**（`tr '\0' ' ' < /proc/<pid>/cmdline`，
  sim 的 wrapper 與 child 各做一次），確認 `app_sig`／`app_scan_pids` 真的判得中，**再**接受本閘門。
  理由：本支所有測試輸入都是**我發明的命令列**，沒有一個抽自真的 app。
- 🔴 **L6（不是本支的驗收，是下一支的前置）** 起一個真的 viz，把
  `network_traffic_visualizer.sh` → `mvnw` → maven JVM → app JVM 四層的 argv 與 ppid 鏈全部存證，
  然後**殺掉最外層**，確認 `app_probe viz` 在「wrapper 已死、JVM 被 reparent」下說什麼。
  預期它會說 `not-running`（＝ ADDENDUM 那個缺陷），**那正是要拿去設計下一支修法的輸入**。

**回退**

單一 commit，`git revert` 即可；沒有資料遷移、沒有狀態檔格式改變。
若只想退掉退出碼那半（保留 start 驗活），revert 後重新 apply `app_start`／`app_wait_started`
兩個 hunk 即可——它們與 rc 契約沒有相依。
