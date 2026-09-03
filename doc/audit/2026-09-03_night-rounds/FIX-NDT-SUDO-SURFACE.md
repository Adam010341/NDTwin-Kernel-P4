# FIX — finding #7：`ndt` 的 `sudo -n` 呼叫不在手冊教的 sudoers 規則裡

分支 `fix/ndt-sudo-surface`，base `ed23a3b3`。**純離線完成**：沒有 `ndt up`、沒有 Mininet／bmv2／OVS、
沒有綁 port、沒有碰實體 testbed。唯一對真 `sudo` 的接觸是三次唯讀查詢（`sudo -n -l`、
`sudo -n ovs-vsctl --version`、`sudo -n ovs-ofctl --version`），用來量沖突訊息的字面樣子。

[Co-developed with claude code -- Adam]

---

## 1. 一句話

`sudo -n` 被拒與「真的量到那個值」在程式裡本來不可分辨，現在**由 exit status 分辨**，
而「我不知道」不再等同於「沒有」——`ndt up p4` 的 OVS 守衛因此在測不到的時候會停下來，
而不是靜靜拆掉別人的 fabric。

---

## 2. 行為變更前後對照

### 2.1 完整的 sudo 呼叫盤點（範圍先找完整）

用了七種搜法，逐一列在 §2.2；下表是結論。「手冊」＝**網站的 Installation Manual 與 User Manual**
（`/home/adam/NDTwin-Website/content/en/docs/`，rev `174beca`），因為那正是四輪 usertest 的
受測對象（`doc/audit/2026-09-02_manual-usertest/README.md`：「following **only** the new
website's Installation Manual and User Manual」）。

**全站只有一條 sudoers 指令**，在
`content/en/docs/NDTwin User Manual/NDTwin Kernel/Operate an Emulated (Software) Network/Native-Linux Excution Environment.md:47`：

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/local/sbin/ndtwin-lab" | sudo tee /etc/sudoers.d/ndtwin-lab
```

`grep -rn 'sudoers\|NOPASSWD' content/` 在整個網站只有這兩行。**沒有任何一頁提到 `ovs-vsctl`、
`mnexec`、`ifconfig` 或 `tc`。**

| # | 位置（修法前行號） | 呼叫 | 需要的規則 | 在手冊裡？ |
|---|---|---|---|---|
| 1 | `ndt:411` | `sudo -n "$LAB" status` | `/usr/local/sbin/ndtwin-lab` | ✅ |
| 2 | `ndt:638` | `sudo -n "$LAB" cleanup` | 同上 | ✅ |
| 3 | `ndt:653` | `sudo -n "$LAB" topo-stop` | 同上 | ✅ |
| 4 | `ndt:654` | `sudo -n "$LAB" topo-start` | 同上 | ✅ |
| 5 | `ndt:910` | `sudo -n "$LAB" "$ovs_verb"` | 同上 | ✅ |
| 6 | `ndt:1078` | `sudo -n "$LAB" topo-stop` | 同上 | ✅ |
| 7 | `ndt:1083` | `sudo -n "$LAB" cleanup` | 同上 | ✅ |
| 8 | `ndt:1928` | `sudo -n "$LAB" energy-start` | 同上 | ✅ |
| 9 | `ndt:1929` | `sudo -n "$LAB" sim-start` | 同上 | ✅ |
| 10 | `ndt:1958` | `sudo -n "$LAB" energy-stop` | 同上 | ✅ |
| 11 | `ndt:1959` | `sudo -n "$LAB" sim-stop` | 同上 | ✅ |
| 12 | **`ndt:1177`** | `sudo -n ovs-vsctl list-br` | `/usr/bin/ovs-vsctl` | 🔴 **否** |
| 13 | **`ndt:1206`** | `sudo -n mnexec -a <pid> ping` | `/usr/bin/mnexec` | 🔴 **否** |

**同族腳本**（同目錄，`ndt` 之外）：

| 位置 | 呼叫 | 需要的規則 | 在手冊裡？ |
|---|---|---|---|
| `faults.sh:88` | `FAULTS_TC="${FAULTS_TC:-sudo -n tc}"` | 四條 `tc qdisc …` 規則 | 🔴 否（`doc/2026-08-10_p4_manual_test_runbook.md:846-848` 有，網站沒有） |
| `faults.sh:89` | `FAULTS_KILL="${FAULTS_KILL:-sudo -n kill}"` | 裸 `kill` | 🔴 **本機也沒有**——`faults.sh` 自己的 header 與 `doc/2026-08-17_testing-manual.md:708` 都記著它會無聲降級 |
| `build_bmv2_fast.sh:171,176` | `sudo make install` / `sudo tee` | 互動式 sudo（**不帶 `-n`**） | 不適用：建置腳本，會問密碼，不會靜默 |
| `ndtwin-lab`（全檔） | 無 sudo 呼叫 | — | 它**是**被 sudo 執行的那一端；`:87` 不是 root 就 die |
| `stack.sh`、`run_layers.sh`、`ovs_4host_topo.py`、`manifest_backfill.sh`、`l0_build_check.sh`、`qdisc_snapshot.sh`、`supervise.sh` | 只有註解／訊息字串／安裝說明 | — | 不執行 |

統計：**`ndt` 有 13 個會執行的 `sudo -n` 呼叫，11 個在規則裡、2 個不在**；同族腳本另有 2 個
不在（`faults.sh` 的 `tc` 與 `kill`），其中 `kill` 連本機都沒有。

**其他權限升級管道：0 個。** `pkexec` / `doas` / `runuser` / `setpriv` / `su -c` 在整個
`tools/test_workflow/` 出現 0 次。

### 2.2 我用了哪些搜法，以及為什麼相信這份清單是完整的

`grep 'sudo'` 會漏，所以用了七種互相補洞的搜法。腳本存於
`/tmp/.../scratchpad/survey.sh`（非版控，指令逐條列在下面，可原樣重跑）：

| | 搜法 | 抓什麼 | 結果 |
|---|---|---|---|
| S1 | `grep -rniE 'sudo' tools/test_workflow/*` | 字面（含註解） | 172 行 |
| S2 | `grep -rniE '\b(pkexec\|doas\|runuser\|setpriv\|su -c\|su -)\b'` | **別的**升級管道 | **0** |
| S3 | awk 去掉整行註解後再找 `sudo` | 把「會執行的」與「只是寫著的」分開 | 見上表 |
| S4 | `grep -rnE '^\s*(local\s+)?[A-Za-z_]\w*=.*(sudo\|pkexec\|doas)'` ＋ 追每個展開 | **變數保存的命令**（`FAULTS_TC="sudo -n tc"`、`LAB=/usr/local/sbin/…`） | 找到 `FAULTS_TC`／`FAULTS_KILL`／`LAB`，`$LAB` 共 19 處展開 |
| S5 | python 正則掃每個 heredoc body | **heredoc 裡**的 sudo | 只有 `stack.sh:65` 的操作說明（`echo`，不執行） |
| S6 | 找 `ovs-vsctl\|ovs-ofctl\|mnexec\|ip netns\|ifconfig\|mn -c` **沒有** sudo 的呼叫 | 需要 root 卻**沒走 sudo**的（會用另一種方式失敗） | `ndtwin-lab:134` 的 `mn -c`——**正確**，該檔本身以 root 執行 |
| S7 | `grep -rnE '\beval\b\|bash -c\|sh -c'` | **字串拼接／動態構造**的命令 | `ndt` 裡 0 個構造特權命令；`stack.sh` 的 `bash -c` 起的是非 root 元件 |

**為什麼相信完整**：三個獨立的理由，而不是「grep 過了」。
(a) S2 把「不是 sudo 的升級管道」這一整類清空到 0；
(b) S4＋S6 從**兩個方向**夾——變數持有的命令（grep `sudo` 找得到字串但找不到呼叫點）與
沒有 sudo 的特權命令（grep `sudo` 完全看不見）都各自列了出來；
(c) 清單被**寫成測試**：`test_ndt_sudo_surface.sh` 的
「every privileged command ndt names has a row」直接從 `ndt` 原始碼抽出每一個
`sudo -n <x>` 與 `ndt_sudo_capture <x>`，要求每一個都對得到表裡的 row。
下一個新增的 sudo 呼叫**沒有 row 就是紅的**，這比我這次搜得完不完整更耐久。
（限制：該檢查也會抓到註解裡的 `sudo -n <x>`；那是偏保守的方向——寫在註解裡的特權命令也該進表。）

### 2.3 行為變更

🔴 **＝改變對外行為。**

| 位置 | 之前 | 之後 |
|---|---|---|
| 🔴 `ovs_bridge_count()` | `sudo -n ovs-vsctl list-br 2>/dev/null \| grep -c . \|\| true`：訊息、sudo 的 rc、grep 的 rc **三次擦掉證據**，被拒回 `0` | 得到答案才回數字（rc 0）；**問不到就 rc 2 且不印任何數字** |
| 🔴 `ndt up p4` 的 OVS 守衛 | `topo_session && [[ "$(ovs_bridge_count)" -gt 0 ]]`：被拒＝0＝「底下沒有 OVS」⇒ 守衛不觸發，下兩行 `topo-stop`／`topo-start` 拆掉別人的 fabric | 抽成 `guard_no_live_ovs()`；**三種輸入兩種結局**：有 bridge → 停；問不到 → **也停**，並印出缺的 sudoers 那一行；問得到且是 0 → 照常放行 |
| 🔴 `dataplane_ok()` | `sudo -n mnexec … ping … \|\| return 1`：sudo 被拒（rc 1）與封包掉了（ping rc 1）**同一個 rc** | 先用 `mnexec -a <pid> true`（**不送封包**）單獨問權限，再問轉送。被拒 → rc **2**（未測試），不是 1 |
| 🔴 `verify_dataplane()` 的訊息 | 被拒印 `XX data plane: h1 cannot reach 10.0.0.2 -- fabric is up but not forwarding` | 印 `!! data plane: forwarding NOT tested -- sudo refused mnexec`＋要加的 sudoers 行。**rc 仍是 0**（「沒測到」本來就不算 fabric 失敗，與原本的 no-namespace 分支同待遇） |
| 🔴 `ndt status --check` | 沒有這一項 | 多一個 `sudo grants` 區塊；有 grant 被拒 → 列進 `problems` ⇒ **`--check` 會 exit 1** |
| `tools/test_workflow/sudo_surface.sh` | 不存在 | 新檔：`key\|probe\|target\|taught_by\|consequence` 一張表＋`ndt_sudo_capture`／`ndt_sudo_refused`／`ndt_sudo_explain`／`ndt_sudo_probe`／`ndt_sudo_report` |
| `ndt` 的 `NDT_LIB_ONLY` 縫 | 沒有 | dispatch 前一行 `[[ -n "${NDT_LIB_ONLY:-}" ]] && return 0`，讓測試能單獨呼叫述詞。**執行時永遠到不了**（該變數只有測試會設） |
| `ndt:1201` 的註解 | 「mnexec is the form this machine's sudoers allows」 | 加上「**that clause is not true of a machine installed from the manual**」 |

### 2.4 為什麼「rc 決定、訊息只負責解釋」

第一版我寫成用 `sudo -n -l -- <cmd>` 問「這條命令會不會被放行」。**它在這台機器上鑑別力是零**，
實測（2026-09-03，sudo 1.9.15p5）：

```
$ sudo -n -l -- ovs-ofctl dump-flows s1      rc=0   印出 /usr/bin/ovs-ofctl dump-flows s1
$ sudo -n    ovs-ofctl --version             rc=1   sudo: a password is required
```

`-l` 回答的是「**這個 user 可不可以跑**」，而 Adam 的帳號除了那幾條窄的 NOPASSWD 之外還帶著
`(ALL : ALL) ALL`，所以 `-l` 對每一條命令都說「可以」——包括需要密碼、而這個腳本問不到密碼的那些。
**用它做的儀器，會在它被寫來偵測的那台機器上完全失效**，形狀跟它要修的缺陷一模一樣。

最後採用的是：**`sudo -n` 的 exit status 就是全部的答案**（被拒非 0；跑起來就是被包命令的 rc），
它與 locale、sudo 版本都無關。`ndt_sudo_refused()` 那個對 stderr 的字串分類**只決定訊息的措辭**
（「加這行 sudoers」還是「命令自己失敗了」），猜錯只會措辭錯，不會判斷錯——判斷早就從 rc 拿到了。
第一個 pattern（`a password is required`）是上面那次實測的字面；其餘來自 sudo 的訊息目錄，
檔頭有標。

### 2.5 為什麼「不能什麼都拒絕」

如果 `ovs_bridge_count` 對每一種情況都回「問不到」，`ndt up p4` 在**任何**機器上都起不來。
所以「這台機器上沒有 OVS」是**不需要 sudo 就能確定的**，並且被明確地答成 0：

* `command -v ovs-vsctl` 不存在 → 確定 0；
* `ovs_daemon_running`（`ps -eo comm=` 找 `ovs-vswitchd`，不是 `pgrep -f`）沒跑 → 確定 0。

沒有 ovs-vswitchd 就沒有 bridge 可以被 `ovs-vsctl` 列出來，這個推論不需要權限也不會回「也許」。

---

## 3. 閘門證據

以下輸出是**我自己在這個 worktree 裡跑的**（`/tmp/.../scratchpad/wt-sudo`，2026-09-03），
不是轉述，也不是預期輸出。

### 3.1 驗收測試（33 checks）

```
$ bash tests/shell/test_ndt_sudo_surface.sh
...
Ran 33 checks, 0 failed
```

### 3.2 變異閘門（14 mutations，兩個方向）

```
$ bash tests/shell/mutate_ndt_sudo_surface.sh
baseline (must be green before any mutation):
Ran 33 checks, 0 failed

  caught   M1: ovs_bridge_count discards sudo's exit status again     (refused: ovs_bridge_count returns 2 and prints no number went red)
  caught   M2: ndt_sudo_capture throws sudo's exit status away        (refused: ovs_bridge_count returns 2 and prints no number went red)
  caught   M3: the guard reads 'could not tell' as 'nothing there'    (refused: the guard stops the bring-up went red)
  caught   M4: a refusal is reported as 'does not forward' again      (refused: dataplane_ok returns 2 (not tested), and says why went red)
  caught   M5: the classifier stops recognising sudo's measured wording (refused: dataplane_ok returns 2 (not tested), and says why went red)
  caught   M6: the exit status is kept but the message is dropped     (refused: dataplane_ok returns 2 (not tested), and says why went red)
  caught   M7: the mnexec row leaves the table (a call with no row again) (every privileged command ndt names has a row (nothing new can go unlisted) went red)
  caught   M8: explain() names the problem but not the line that fixes it (explain() prints the sudoers line that fixes it went red)
  caught   M9: up_p4 stops asking the guard                           (up_p4 asks guard_no_live_ovs went red)
  caught   M10: cmd_status --check stops reading the sudo table       (cmd_status --check reads ndt_sudo_report went red)
  caught   N1 (control): ovs_bridge_count always says 'cannot tell'   (control, permitted: ovs_bridge_count returns 0 and the real count went red)
  caught   N2 (control): the guard refuses whenever a topo session exists (control, permitted and no bridges: the guard PASSES and the bring-up proceeds went red)
  caught   N3 (control): no unprivileged early-out, so a P4-only machine cannot start (control, no ovs-vswitchd: a definite 0, answered without sudo went red)
  caught   N4 (control): dataplane_ok never tests, so a real outage is never seen (control, permitted and the ping really fails: 'not forwarding' is still said went red)

baseline byte-identical: yes (sudo_surface.sh and ndt)
mutation gate: 14 mutations, 0 survived
```

**兩個方向都在**：M1–M10 是把缺陷放回去（把拒絕讀成 0、拿掉可分辨性、守衛不再擋、
呼叫端不再讀表）；**N1–N4 是「什麼都拒絕」的四種寫法**——它們通得過上面每一條 M，
只有 control 案例抓得到。少了 N1–N4，這個閘門會替一個**永遠起不了 fabric** 的 `ndt` 背書。

### 3.3 對修法前的碼跑過（看過紅）

```
$ NDT_UNDER_TEST=<ed23a3b3 的 ndt> bash tests/shell/test_ndt_sudo_surface.sh
test rc=1
Ran 33 checks, 17 failed
```

紅掉的 17 條包含全部三個核心斷言（`refused: ovs_bridge_count returns 2 and prints no number`、
`same three bridges: permitted reads 3, refused does NOT read 0`、
`refused: dataplane_ok returns 2 (not tested), and says why`）。

⚠️ **這一項的鑑別力要打折，我要講清楚**：修法前的 `ndt` 沒有 `NDT_LIB_ONLY` 那個縫，
被 source 時會走到 dispatch 的 `*)` 分支並 `exit 2`，所以多數 `in_ndt` 案例是**因為結構
而不是因為行為**變紅；反過來，少數案例是**因為 source 中止而假綠**
（例如 `a live OVS fabric stops the bring-up`：`in_ndt_rc` 拿到非 0 就當成「守衛擋住了」）。
**真正逐條可信的紅是變異閘門的 M1**——它把修法前的 `ovs_bridge_count` 語意原樣放回**修好之後的
結構**裡，其他一切不變，該案例照樣紅。3.3 只當旁證，M1 才是主證。

### 3.4 這個閘門自己被檢查得到（finding #28）

新出廠的閘門預設是**未被檢查**的，所以先驗了再說。第一版寫成之後：

```
$ python3 tests/shell/check_gate_anchors.py fix/ndt-sudo-surface --gates mutate_ndt_sudo_surface.sh
mutate_ndt_sudo_surface.sh  NO-ANCHORS
0/1 cells ok  (1 not ok, of which 1 were NOT CHECKED AT ALL)      exit 2
```

原因：檢查器是從變異函式**自己的 `local … file="$2" old="$3"` 那一行**認出哪個參數是 anchor、
哪個是檔案，而我的 `mutant()` 用位置參數、檔案只給 basename。改成具名參數、呼叫點傳
`"$NDT"`／`"$SURFACE"`（檢查器本來就解得開的變數）之後：

```
$ python3 tests/shell/check_gate_anchors.py fix/ndt-sudo-surface --gates mutate_ndt_sudo_surface.sh
mutate_ndt_sudo_surface.sh  ok(13)
1/1 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)
```

13 而不是 14，因為 M1 與 N1 用同一段 anchor（同一行、兩種改法），檢查器會去重。
變異、anchor、案例一個都沒改，改完重跑仍是 **14 mutations, 0 survived**。

### 3.5 沒有弄壞鄰居

同樣在這個 worktree 裡跑過，全綠：

```
test_ndt_lab_session.sh                     rc=0  14 passed, 0 failed
test_teardown_guards.sh                     rc=0  14 passed, 0 failed
test_ndt_app_orphans.sh                     rc=0  Ran 52 checks, all passed
test_up_ovs_wedge_guard.sh                  rc=0  Ran 10 checks, all passed
test_ndt_sample_rate_reads_both_bounds.sh   rc=0  Ran 6 checks, 0 failed
```

---

## 4. 合併順序與衝突

base 是 `ed23a3b3`。目前另有三支分支也改 `tools/test_workflow/ndt`：

| 分支 | 改到 `ndt` 的哪裡 | 與本支的關係 |
|---|---|---|
| `fix/ports-that-block-restart`（`fa40fc63` / `2fe70075`） | `cmd_clean`、`deep_sweep`、`preflight`、**`up_p4` 的 orphan 分支**、檔頭新增 `source ports.sh` | 🔴 **兩處貼著**：①檔頭都要加一行 `source`；②它改的 orphan 分支就在我改的守衛**上面兩行**。建議**它先合、我後合**，我這邊只需把 `SUDO_SURFACE` 的 source 併到它的 source 區塊旁 |
| `fix/g6-ndt-apps-liveness` | `cmd_apps` 一帶（app 存活） | 無重疊 |
| `t8-t10-fixes` | 未逐段比對 | 合併前請 auditor 確認 |

**建議順序**：`fix/ports-that-block-restart` → `fix/ndt-sudo-surface` → 其餘。
兩支的表（`ports.sh`／`sudo_surface.sh`）與兩個閘門互不相干，可以並存；
`sudo_surface.sh` 刻意照 `ports.sh` 的形狀寫（表在最前、函式無副作用、可被測試 source）。

**測試檔無衝突**：`tests/shell/{test,mutate}_ndt_sudo_surface.sh` 都是新檔。

---

## 5. 回退方式

整支回退：

```bash
git revert --no-commit <本支的 commit sha>
```

或只退掉行為、留下表與測試（若只想拿掉 `--check` 那個新的紅）：

* `ndt` 的 `cmd_status` 裡刪掉 `sudo grants` 那個 `case` 區塊 —— 只影響 `ndt status --check` 的 exit code。
* 守衛要退回舊語意：把 `guard_no_live_ovs` 裡的 `if (( brc != 0 )); then … return 1` 改成 `return 0`
  （**這等於把缺陷放回去**，變異 M3 就是這一手，測試會紅）。

`sudo_surface.sh` 是新檔，刪掉即可，但 `ndt` 檔頭的 `source` 會讓它在缺檔時 `exit 2` 並印出原因
——刻意不做無聲 fallback，理由與本修法相同。

---

## 6. 未處理

1. 🔴 **這支沒有在真的需要密碼的機器上實跑過。** 本機 Adam 的帳號有
   `(ALL : ALL) ALL` ＋ `/usr/bin/ovs-vsctl`、`/usr/bin/mnexec` 的 NOPASSWD，所以
   `ovs-vsctl` 與 `mnexec` **在這裡是通的**。閘門與測試裡的「被拒」全部由 PATH 上的**假 `sudo`**
   產生，它印的是實測到的字面（`sudo: a password is required`，rc 1）。因此仍是 desk check 的宣稱：
   * 「一台照手冊裝的機器上，`ovs_bridge_count` 會被拒」——推論自「網站手冊只教 ndtwin-lab 一條規則」，
     **沒有在那樣的機器上實跑**。
   * 「`sudo -n` 在其他 sudo 版本／其他 locale 下也是這幾種措辭」——只有第一條 pattern 是實測的，
     其餘來自訊息目錄。**判斷不靠它們**（rc 決定），但訊息可能不夠好。
   * `ndt status --check` 的新區塊、`guard_no_live_ovs` 的錯誤訊息、`verify_dataplane` 的新訊息，
     **都只在假 sudo 下看過**，沒有在真的被拒的機器上看過。
   * **建議的實測**：在一台 tester VM 上把 `/etc/sudoers.d/` 收成只有 ndtwin-lab 那一條
     （usertest 的 VM 是 `(ALL) NOPASSWD: ALL`，見 `run-01-sonnet/auditor-verification/a0_env.txt`，
     這正是四輪都看不見它的原因），然後跑 `ndt status --check` 與 `ndt up p4`。
2. **`lab_session()` 是同型的第三例，未修。** `sudo -n "$LAB" status 2>/dev/null` 被拒 → 空字串 →
   `topo_session` 回 false。連鎖後果比想像的輕：`ndtwin-lab` 被拒時 `topo-start`（`:654`）也會失敗，
   `up_p4` 直接 `return 1`，**fabric 不會被拆**。真正危險的組合恰好是**手冊自己造出來的那一種**
   ——ndtwin-lab 有、ovs-vsctl 沒有。修它要動 11 個呼叫點的三態化，範圍超出本輪。
3. **`faults.sh` 的 `FAULTS_TC`／`FAULTS_KILL` 沒有接上這張表。** 它們是第二個同形表面，
   而且 `FAULTS_KILL` 的裸 `kill` **連本機都沒有 NOPASSWD**（`faults.sh:63-68`、
   `doc/2026-08-17_testing-manual.md:708` 都記著它會無聲降級成 not-injected）。
   接上去要把 `faults.sh` 的 seam 改成走 `ndt_sudo_capture`，本輪未做。
4. **`cmd_status --check` 的新紅可能吵到既有 harness。** 任何在缺 grant 的機器上呼叫
   `ndt status --check` 的腳本會開始拿到 exit 1。本機三個 grant 都在，所以這裡量不到；
   合併前值得 auditor 決定要不要先降成 warning。
5. **`command -v ovs-vsctl` 那半個 early-out 沒有專屬測試。** N3 變異同時拿掉兩個 early-out，
   由 `ovs_daemon_running` 那一半判紅；要單獨測「機器上沒有 ovs-vsctl」得把它從 PATH 拿掉，
   本輪沒做。
6. **`ndt_sudo_probe` 對 `lab` row 的 probe 會真的執行 `sudo -n /usr/local/sbin/ndtwin-lab status`。**
   那是唯讀的 tmux list（`ndt` 本來每次 `lab_session` 就跑一次），但它現在也會在
   `ndt status --check` 裡多跑一次。沒有量過它的成本。
7. **沒有動網站手冊。** 正確的長期修法是把 `ovs-vsctl`／`mnexec` 兩條規則寫進 Installation Manual，
   那是另一個 repo（`/home/adam/NDTwin-Website`，rev `174beca`），本輪照指示沒有碰。
   表裡的 `taught_by` 欄現在寫著 `NOWHERE in the Installation or User Manual`——手冊補上之後
   **要順手改那一欄**，否則它會變成下一個說謊的註解。
