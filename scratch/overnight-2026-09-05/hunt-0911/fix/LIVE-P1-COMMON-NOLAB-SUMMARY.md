# SUMMARY：test_live_p1_common 5e 不再能碰到 live fabric，以及全部 shell suite 的 nolab 掃描

- **分支**：`fix/live-p1-common-5e-nolab-0927`，從 trunk `3f8c2abf` 開出（直接讀 ref，沒先問你）。
  - 你說過它可以乾淨地 merge 到 `b2eeb71d`，沒有檔案重疊。
- **Worktree**：`scratch/overnight-2026-09-05/wt-live-p1-common-nolab-0927`。
- **Head**：`be2ad2d2acb4021a2649cbd502cc8dba69e40c09`，共 5 個 commit。judge 審 `c03130fe` 的結論是 MERGE AFTER FIXES，修正在 §8。只動了 `tests/shell/test_live_p1_common.sh` 與 `tests/shell/mutate_live_p1_common.sh`。
- 沒 push、沒 merge、沒 sudo、沒碰 lab 也沒碰主 checkout，每一次執行都走 guard 並帶 nolab shim。

[Co-developed with claude code -- Adam]

## 1. 缺陷（背景是 09-26 17:55Z 的事故，細節見 `P4-HB-FOLLOWUPS-R2-SUMMARY.md` §0）

- 5e 的 `to-h2`／`default` 兩格，以及 13 的 `noctrl` 那格，把 `$PKG3` 交給 `link_usage_round`。`$PKG3` 的主機名是 h1..h3，和真 fabric 同名。
- `drive()` 只 stub 了 curl 和 sleep，沒有 stub sudo、mnexec、iperf。
- 所以只要有 fabric 在跑，`host_pid` 就會找到真主機，接著執行真的 `sudo -n mnexec -a <pid> iperf …`。
- `noctrl` 另有一條路徑：它的「死掉的 controller」pid 是 999999，這個 pid 有可能是活著的行程；那樣它也會往下走到 `host_pid`。

## 2. 修正

**red first：`124a7f3c`，suite 自己的守衛**
- 這個 suite 現在**永遠當成有 fabric 在跑**，而且永遠碰不到 fabric。做法是在 PATH 前面放幾個檔案：
  - `ps`：先印真的行程表，後面再多列 4 個假的 Mininet host shell（h1..h4）。它們的 pid、ppid、pgid 都設在 pid_max 4194304 之上：不可能有行程用這些 pid，signal 打過去也打不到任何行程。
  - 帶有 host 標記的那幾行由 bash builtin 印出，不會出現在任何行程的 argv 裡，所以 `mn -c` 的 `pkill -f` 看不到它們。
  - `sudo`、`mnexec`、`iperf`、`iperf3`：記錄呼叫後拒絕（rc 1）。
- 新增 section 14：任何呼叫只要沒被格子自己的 stub 接住，而進到了上面這些檔案，就判紅。
- 附兩個對照，證明守衛本身有在運作：
  - guard 的 sudo 確實是 PATH 上找到的那一支；
  - `host_pid h2` 看到的是假的 h2（4194392）。

**修正：`b2e656e5`**
- 5e 的兩格與 `noctrl` 改用 `PKGZ`：主機 zz1..zz3，IP 10.9.9.N，沒有任何 fabric 會用這些名字。這跟 no-ns 那格原本的做法一樣。
- 兩格都加上斷言：必須停在 namespace 拒絕（rc 2）。
- `noctrl` 的假 controller pid 改成 4194399，高於 pid_max。
- 共用的 STUBS 加上 sudo、mnexec、iperf、iperf3：記錄呼叫、回 rc 1。section 14 另加一條檢查：沒有任何一格碰到這些 stub，也就是沒有任何一格嘗試打流量。

**閘門：`c03130fe`，`mutate_live_p1_common` 加兩個 mutant**
- M42：`link_usage_round` 在沒有 namespace 時也繼續往下走。killer 是 rc-2 那格，以及 stub 檢查。
- M43：再加上用 `command sudo` 繞過所有 stub。killer 是 section 14 的 PATH 檢查（只有 PATH 守衛看得到這一種）。

## 3. red first，全程沒有任何真 fabric（OBSERVED，`redfirst_lp1c_b.lp1cnolab-c03130fe.log`）

1. **trunk `3f8c2abf` 的 suite**，在外部 shim 下並給它一個假 fabric：
   - 它**確實**呼叫了下面 4 條，被外部 shim 記錄下來：
     - `sudo -n mnexec -a 4194392 iperf -s -u`
     - `sudo -n mnexec -a 4194391 iperf -c 10.0.2.2 -u -b 2M -t 16 -l 1200`
     - `… -a 4194393 iperf -s -u`
     - `… -a 4194391 iperf -c 10.0.3.3 …`
   - 但它自己回報的是「Ran 163 checks, 0 failed」：這個 suite 本身沒有任何辦法看見這件事。
2. **`124a7f3c`**（加了守衛、還沒修）：
   - rc 1，「Ran 166 checks, 1 failed」。
   - 唯一紅的就是 section 14，而且逐條列出上面那幾個呼叫。
   - 兩個對照都 ok。
   - 沒有任何呼叫漏到外部 shim。
3. **HEAD**：
   - 169 個 check，0 失敗；section 14 的兩條、rc-2 的兩條都是 ok。
   - 在外部假 fabric 下，什麼都沒記錄到。

**第一版 `redfirst_lp1c`（rc 1）是我的 harness 寫錯，不是 suite 的問題**
- 兩個對照的標籤前面有兩個空格，我的 grep 沒算進去。
- 同一份 log 裡的 suite 輸出本身就顯示對照是 ok 的，而且只有 section 14 紅。
- 修好後的版本就是上面的 `redfirst_lp1c_b`。

## 4. 掃描 `tests/shell` 全部 63 個 `test_*.sh`（OBSERVED，`nolab_sweep_all.lp1cnolab-c03130fe.log`）

**掃描方式**
- 每個 suite 跑兩輪：A 輪沒有 fabric；B 輪有假 fabric，也就是 `host_pid` 會看到的東西。
- 會碰 lab 的東西一律記錄並拒絕：
  - sudo、mnexec、iperf、iperf3、ping；
  - tc、ip、ovs-* 中會改變狀態的用法；
  - 打 :8000／:8081／:8080 的 curl；
  - C++ 建置。
- 跑的是 HEAD（除了這個 suite，其餘 suite 都跟 trunk 相同）。
- 掃描前後都沒有任何真的 mininet 主機。

**結果**
- **B 輪沒有任何 suite 比 A 輪多出呼叫**：沒有其他 suite 會因為「有 fabric 在跑」而去驅動它的主機。
- `test_live_p1_common` 在 HEAD 上兩輪都是 `-`。
- 有 6 個 suite 兩輪呼叫數相同，而且**全部都是唯讀的 lab 探測**：

| suite | 呼叫（A＝B） |
|---|---|
| test_apps_stop_kills_the_group | `sudo -n ndtwin-lab status` ×8 |
| test_cell_gate_suspect_wiring | `ndtwin-lab status` ×2、`ndtwin-lab topo-out N` ×2 |
| test_lab_handoff | `ndtwin-lab status` ×52、`ovs-vsctl list-br` ×26、`mnexec -a 1 true` ×13；另有**不經 sudo 的 `tc qdisc show` ×13**（唯讀，shim 直接放行給真的 tc；原表漏列，09-27 補上） |
| test_ndt_app_orphans | `ndtwin-lab status` ×16 |
| test_ndt_honesty | `ovs-vsctl list-br` ×2 |
| test_ndt_sample_rate_reads_both_bounds | `ovs-vsctl list-br` ×4 |

**這 6 個 suite 我沒有修**
- 讀過 root helper 的原始碼：`ndtwin-lab status` 只列 tmux session 並數 bmv2／mininet 行程（1825-1831）；`topo-out` 是 `tmux capture-pane`（1678-1681）。`ovs-vsctl list-br` 只列 bridge。`mnexec -a 1 true` 是 sudo 權限的探測。都不改 lab 狀態，也不打流量。
- 除了下面這一處，它們都是經由 `ndt` 的 status 或存活檢查路徑發出的。**（09-27 更正）** `test_cell_gate_suspect_wiring` 的 `topo-out 400` 與 `status` 來自 `lib_e.sh:133-134`（`preserve_abort_evidence`），不是 `ndt`。
- 有兩個會發 signal 的 suite（apps orphans／stop），依它們自己檔頭的設計說明：候選清單只有它們自己起的 fixture，REPO 也導向暫存目錄，所以不會打到真的 app。
  - 這點我**只讀過 test_ndt_app_orphans 的說明（:73-110）**；test_apps_stop_kills_the_group 的同等說明沒有逐條查證。INFERRED。
- `test_cell_gate_suspect_wiring` 的每一次 `cell_cpu_gate_finish` 呼叫都帶 `FORCED_ABORT=1`，**共 6 處**（:83、93、102、112、119、125；09-27 更正，原本只列了 4 處），所以 `abort()` 不會跑 `restore_production`（`lib_e.sh:199-204`）。
- 如果你認為唯讀探測也不該碰真 lab，這 6 個 suite 可以照這一輪的做法，改用 PATH 上的 `sudo` stub。這要你裁決。

**另有 4 個 suite 在掃描環境下兩輪都 rc 1**
- 分別是 test_build_guard、test_gate_exit_code_not_tee、test_l1_shell_scoring、test_start_bg_log_rotation。
- 它們沒有任何 lab 呼叫。
- 失敗原因我沒查。INFERRED：可能是 shim（例如 make 被拒絕）或巢狀 guard 的環境造成。
- 它們的紅不能當成「會不會碰 lab」的證據。

**這次沒掃到的範圍（照實說）**
- 120 個 `mutate_*.sh` 沒有做動態掃描：它們是拿 mutant 版本的 production code 重跑同一批 suite。
- 靜態 grep 沒找到會拿掉 `FORCED_ABORT`／`DRY_RUN` 這類安全閘的 mutant。唯一沾邊的是 ep4 那個 mutant，只影響 evidence。
- 但「某個 mutant 拿掉 stub 之後可能碰到 lab」這件事沒有逐一驗證。你已規定 nolab shim 是強制的，這一條在執行層面能擋住走 PATH 的呼叫。

## 5. 你問的兩件事

**R-N4：tripwire 只看得到經由 PATH 找到的指令。那這個 suite 還有沒有用絕對路徑或從 Python 去碰 sudo、curl、iperf？（靜態 grep，OBSERVED）**
- `test_live_p1_common.sh`，以及它驅動的 `live-p1/_common.sh`：
  - 沒有用絕對路徑的 sudo、curl、iperf、mnexec、ping；
  - 唯一的 `/usr/bin/mnexec` 出現在 `_common.sh:97`，只是 `sudo -n -l` 的參數，而那個 sudo 走 PATH，會被 shim 接住；
  - 沒有任何 Python 網路呼叫（urllib、http.client、requests、socket 都沒有）。
- 這個 suite 讀的 ndt 函數只有 `host_pid`，它讀的是 `ps`，而 `ps` 已被 shim 接管。
- 放寬到全部 suite 和它們呼叫的 production code：
  - 唯一的 Python HTTP 是 `ndt` 的 `cmd_check` 取樣器（:7147-7336，對 :8000 做 urllib GET）。
  - 會走到 `cmd_check` 的兩個 suite：test_ndt_honesty 把 `python3` stub 成函數（:450、:659）；test_ndt_check_sample_rate 只讀 `cmd_check` 的原始碼（:166），不執行它。
  - 用絕對路徑呼叫 sudo 的只有 spike 那個 opt-in 探測（`SELFTEST_PROBE_SUDO=1`），不在任何 `test_*.sh` 裡。
- 所以結論是：目前沒有繞過 tripwire 的路徑。但 tripwire 本身確實看不到絕對路徑與 Python。**這兩類只有靜態 grep 擋著，沒有執行期的守衛。**

**nolab 守衛有沒有涵蓋 mnexec？有，而且是兩層：**
- suite 自己的 PATH 守衛有 `mnexec` shim（記錄後拒絕），共用 STUBS 也有 `mnexec()`。
- `sudo -n mnexec …` 會先碰到 sudo 那一層。
- 掃描用的外部 shim 也涵蓋 mnexec。
- 例外：用絕對路徑的 `/usr/bin/mnexec` 會繞過。在這個 suite 以及它驅動的程式碼裡，這種呼叫是 0 處。

## 6. 閘門（全部經 `env JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh`，PATH 最前面是 nolab shim）

- log 在 `logs/gates-0910/<gate>.lp1cnolab-c03130fe.log`：第一行是完整 sha，最後一行是 `# rc=`。
- 執行的腳本是 `scripts-lp1cnolab-c03130fe-{final,b}/` 裡的副本，附 SHA256SUMS。

| 閘門 | rc | 結果 |
|---|---|---|
| `redfirst_lp1c` | 1 | 我的 harness 比對錯誤（§3）；suite 本身的證據是對的 |
| `test_live_p1_common` | 0 | 169 個 check，0 失敗 |
| `mutate_live_p1_common` | 0 | 42 個 mutation，0 存活；4 個控制組都沒紅。M42 抓到（指名的 2 條紅），M43 抓到（section 14 紅） |
| `check_gate_anchors` | 0 | 120/120。**（C1 更正，09-27）** 原本說「讀不到檔案存放的 anchor、格數沒變」是錯的：log 裡是 `mutate_live_p1_common.sh ok(46)`，也就是 42 個 mutation 加 4 個控制組；pass 1.6 會讀 `.old`／`.new` 的 heredoc anchor |
| `redfirst_lp1c_b` | 0 | trunk 會去碰 sudo；red-first 版會紅並列出呼叫；HEAD 兩者都沒有 |
| `nolab_sweep_all` | 0 | 63 個 suite × 2 輪（§4） |
| `nolab_tripwire_b` | 0 | 0 次 lab 呼叫。**範圍（09-27 註明）**：只涵蓋 driver 自己的 `NOLAB_LOG`，也就是 `redfirst_lp1c_b` 與 sweep 的外層。sweep 裡每個 suite 的呼叫記在各自的 `.calls`，已經列在 §4 的表裡 |

**我犯的錯**
- 第一個 driver（`MODE=final`）在執行中被我改了檔案，bash 在第 49 行讀歪，所以 sweep 和 tripwire 都沒跑。那次的 shim log 是 0 行。
- 之後的 driver 都是從 `nolab2/frozen/` 裡的**唯讀副本**執行。
- 那一次的 `nolab_tripwire` 沒跑，由 `nolab_tripwire_b` 補上。前三個 gate 的外部 shim log 我直接讀過，是 0 行，沒有任何 lab 呼叫。

## 7. 沒做的，以及待決事項

- 那 6 個唯讀探測的 suite 沒有內建 sudo stub（§4）。**要你裁決**。
- **judge 的 N1（09-27 記下，這一輪不修）**：`mutate_live_p1_common` 的 mutant 放在一個 TMPDIR 深度，在那裡 `source "$NDT"` 會無聲失敗。
  - 結果是那些 mutant 的 `host_pid` 什麼都找不到。依賴 host_pid 的格子在 mutant 下走的是「沒有 namespace」那條路。
  - 我沒量這對哪些 mutant 的鑑別力有影響。
- `mutate_*.sh` 沒做動態掃描。
- 那 4 個在 shim 下紅的 suite，原因沒查。
- R-N1、R-N2、Q2 在另一條分支 `fix/hb-followups-r3-0927`。

## 8. judge 對 c03130fe 的 MERGE AFTER FIXES（09-27，commit `12fc0683`、`be2ad2d2`）

**F1（必修）：假 `ps` 把真的行程表印在前面**

- 缺陷：`host_pid`（ndt:6055-6061）取的是**第一個** argv 以 `mininet:hN` 結尾的列。
  - 只要真的 fabric 在跑，`host_pid h2` 拿到的就是真的 h2，section 14 的對照（應該是 4194392）會假紅，`mutate_live_p1_common` 會以「baseline 不綠」refuse。
  - 更糟的情況：如果某棵樹的格子還在用 h 名，守衛的 sudo 會被交到活主機的 pid。
- 修正 `12fc0683`：
  - 不帶 header 的列表（也就是 `host_pid` 用的 `x=` 欄位格式）先印假列，再 `exec /usr/bin/ps "$@"`；
  - 帶 header 的列表維持 header 在最上面，接著假列，再接其餘的列。
- **red first（OBSERVED，`redfirst_f1_f1.lp1cnolab-be2ad2d2.log`）用一個誘餌行程，不是 fabric**
  - 誘餌是一個非特權行程：`exec -a "bash --norc -is" python3 -I -c 'time.sleep(120)' mininet:h2`。它由腳本自己起，跑完後用它自己的 pid kill＋wait 收掉。
  - 我沒有照你寫的 `sleep 120`：那樣 argv 的最後一個字是 `120`，`host_pid` 根本對不上。
  - 每一輪都先用真的 `host_pid h2` 確認它找到的就是誘餌。
  - 結果：
    1. **c03130fe** 在誘餌存在時：**只紅一條**，就是 section 14 的對照，expected [4194392]，actual 是誘餌的 pid。
    2. **HEAD** 在誘餌存在時：169 個 check、0 失敗，對照是 ok。
    3. **124a7f3c**（5e 還在用 h1..h3），原樣執行：守衛的 sudo 收到的 h2 server 是**誘餌的 pid**。
    4. 124a7f3c 換上 HEAD 的 ps 之後：收到的是**假的** 4194392／4194391／4194393，從來不是誘餌。
  - 用過的副本都已刪掉，誘餌也都收掉了。前後都沒有任何真的 mininet 主機。

**M44：證明 PATH 守衛有自己獨有的價值**

- 做法：保留 rc 2，但在 `return 2` 前面加一行 `command sudo -n true`。
- 新的 `check_fires_only` 要求**只有**指名的那條紅。結果是 **caught**：只紅「NOTHING reached for sudo, mnexec or iperf past a stub」。
- M43 做不到這件事，因為它同時改了 rc。

**T1／T2：測試端的 mutant**

- 做法：把 5e 的 `to-zz2`（T1）或 `default`（T2）放回 `$PKG3`。
- 結果：兩個都 **caught**。
  - rc-2 那格紅；
  - section 14 的 stub 檢查（沒有任何格碰到共用 stub）紅；
  - 另外 destination 文字那格也紅。
- 它們的 anchor 用 `.told`／`.tnew` 存，**不在** `check_gate_anchors` 的 pass 1.6 範圍內，因為 pass 1.6 會把 `.old`／`.new` 當成 `_common.sh` 的 anchor。唯一性由這支 gate 自己的 applier 在執行時強制。
- `mutate_live_p1_common`：45 個 mutation，0 存活；4 個控制組都沒紅。
- `check_gate_anchors`：`mutate_live_p1_common.sh ok(47)`，也就是 43 個 `_common` mutation 加 4 個控制組。

**N6**

- sweep 的 raw 已經複製到 `logs/gates-0910/nolab_sweep_all.lp1cnolab-c03130fe.raw/`，包含 A／B 的 `.calls`、`.out`、`.rc` 和 shims，附 SHA256SUMS（284 個檔）。

**本輪閘門**（`logs/gates-0910/<gate>.lp1cnolab-be2ad2d2.log`，driver 從凍結的唯讀副本執行）

| 閘門 | rc | 結果 |
|---|---|---|
| `redfirst_f1_f1` | 0 | 舊的 ps 讓真的 h2 勝出；新的 ps 永遠不會 |
| `redfirst_lp1c_f1` | 0 | trunk 會去碰 sudo；red-first 版會點名；HEAD 兩者都沒有 |
| `test_live_p1_common_f1` | 0 | 169 個 check，0 失敗 |
| `mutate_live_p1_common_f1` | 0 | 45 個 mutation，0 存活；4 個控制組都沒紅（M44、T1、T2 都抓到） |
| `check_gate_anchors_f1` | 0 | 120/120（`mutate_live_p1_common.sh ok(47)`） |
| `nolab_tripwire_f1` | 0 | 0 次 lab 呼叫（只涵蓋 driver 自己的 `NOLAB_LOG`） |

DELIVERED be2ad2d2acb4021a2649cbd502cc8dba69e40c09
