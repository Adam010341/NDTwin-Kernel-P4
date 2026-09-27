# SUMMARY：六支唯讀探測 suite 在 lab「看起來是活的」時會做什麼（a），以及四支在閘門環境下紅的 suite（b）

- **分支**：`fix/suites-under-gate-env-0927`，從 trunk `3db3b9a8` 開出。
- **Worktree**：`scratch/overnight-2026-09-05/wt-suites-gate-env-0927`，已建好 `p4_proxy/venv` 與 `p4_proxy/p4_src/build` 兩條連結。
- 沒 push、沒 merge、沒 sudo、沒碰 lab 也沒碰主 checkout。
- 每一次執行都走 guard（`JOBS=1 LOCK_WAIT=10800`），nolab shim 放在 PATH 最前面，driver 一律從唯讀的凍結副本執行，tripwire 放在最後。

> **狀態（09-27 07:0x）**：
> - 這條分支只交付 (b) 的 test_build_guard 修正：**`d271f5b8`**，閘門全綠，見文末。
> - (a) 已依你的裁決，在另一條分支 `fix/probe-suites-stub-0927` 施作，有它自己的 SUMMARY。
> - (b) 的三個真缺陷在 `fix/stale-suites-0927` 處理。

[Co-developed with claude code -- Adam]

## (a) 六支唯讀探測 suite

### 怎麼量的（`probe_report_a` 與 `probe_report_a2`，`logs/gates-0910/*.sgenv-3db3b9a8.log`）

每支 suite 跑三輪：

- **R**：拒絕型的 nolab shim，也就是今天在閘門裡的樣子。
- **L**：會「回答」的 sudo，裝成 lab 是活的：
  - `ndtwin-lab status` 回一行 config、energy／sim／topo 三個 session，以及 `bmv2: 10  mininet: 4`，rc 0；
  - `topo-out` 回一個 `mininet>` 提示；
  - `ovs-vsctl list-br` 回 s1..s4；
  - `mnexec -a 1 true` 回 rc 0；
  - `sudo -l` 視為放行。
  - `ps` 列出假的 Mininet 主機 h1..h4 和十個 `simple_switch_grpc`，pid 都在 pid_max 之上。
- **L2**：同 L，但**沒有 bmv2**，只有 OVS 和主機是活的。這一輪是為了走到 OVS 那條分支。

共通的規則：

- **四種唯讀探測以外的任何 sudo，一律記錄並拒絕。** 那些正是「活的答案會引出來的東西」。
- 沒有任何呼叫到達 root。
- 前後都沒有真的 mininet 主機。
- 唯讀的 raw 在 `scratchpad/tmp/probe_report_a{,2}_3db3b9a8/`。

**第一輪 L 的誤差（照實說）**

- 第一輪 L 裡，我的 `ps` shim 連 `ps -o pgid= -p $$` 這種只問單一行程的查詢也加了假列，結果 test_apps_stop_kills_the_group 有 3 條紅。
- 修正 shim 後重跑（`probe_report_a2`），三輪都綠。
- 那 3 條紅是我的 shim 造成的，不是 suite 的問題。

### 結果（OBSERVED）

| suite | R（今天） | L（bmv2＋OVS 活） | L2（只有 OVS 活） | 活的答案**多引出**的指令 | 判定是否改變 |
|---|---|---|---|---|---|
| test_apps_stop_kills_the_group | `ndtwin-lab status` ×8 | 同 ×8 | 同 ×8 | 無 | 71/71 綠 |
| test_cell_gate_suspect_wiring | `status` ×2、`topo-out 400` ×2 | 同 | 同 | 無 | 12/12 綠 |
| test_lab_handoff | `status` ×52、`ovs-vsctl list-br` ×26、`mnexec -a 1 true` ×13、`tc qdisc show` ×13（不經 sudo） | `list-br` 降到 ×13，其餘相同 | 多了 `sudo -n ovs-vsctl --bare --columns=sampling list sflow` ×13 | 只有 `list sflow`（**唯讀**） | 18/18 綠 |
| test_ndt_app_orphans | `status` ×16 | 同 | 同 | 無 | 103/103 綠 |
| test_ndt_honesty | `list-br` ×2 | 0 次（ndt 看到 bmv2 就判成 P4，不去問 OVS） | `list-br` ×2、`list sflow` ×2 | 只有 `list sflow`（唯讀） | 345/345 綠 |
| test_ndt_sample_rate_reads_both_bounds | `list-br` ×4 | 0 次 | `list-br` ×4、`list sflow` ×4 | 只有 `list sflow`（唯讀） | **L2 紅了 4 條**（下面說明） |

**結論（OBSERVED，限於我試過的兩種「活」的形狀）**

- 六支 suite 在 lab 看起來是活的時候，**都沒有發出任何會改變 lab 狀態的指令**。
- 沒有 topo-stop、cleanup、energy-stop、sim-stop、tc add／del，也沒有 kill，shim 的拒絕紀錄是 0 筆。
- 活的答案唯一多引出的，是 `ovs-vsctl --bare --columns=sampling list sflow`（ndt 的 `ovs_sample_rate`，ndt:2179），它是唯讀查詢。

**test_ndt_sample_rate_reads_both_bounds 的判定受 lab 狀態影響（OBSERVED）**

- 在 L2（OVS 看起來是活的），它有 4 條紅：
  - `production lo=0 hi=255 reads 256`；
  - `lo=1 hi=255 is reported DISABLED`；
  - `lo=0 hi=1023 reads 1024`；
  - `rate_label …`。
- INFERRED：OVS 一旦看起來是活的，ndt 就走 OVS 的取樣率路徑，不再讀這支 suite 餵給它的 P4 fixture。
- 所以：在一台 OVS lab 真的在跑的機器上，這支 suite 會**假紅**。不會造成傷害，但結果不可靠。

**探測是從哪裡發出的**

- INFERRED，讀原始碼，未逐一追到呼叫者：
  - `ndtwin-lab status` 來自 ndt 的 `lab_session`（ndt:1375-1379）；
  - `list-br` 來自 `ovs_bridge_count`（ndt:6003），經 `ndt_sudo_capture`；
  - `list sflow` 來自 `ovs_sample_rate`（ndt:2179）；
  - `mnexec -a 1 true` 是 sudo surface 的探測（`sudo_surface.sh:88`）。
- test_cell_gate_suspect_wiring 的 `status`／`topo-out 400` 來自 `lib_e.sh:133-134`（`preserve_abort_evidence`，`$LAB`＝`sudo -n /usr/local/sbin/ndtwin-lab`，`round.env:30`）。

**這次沒看到的範圍（照實說）**

- 只試了兩種「活」的形狀。
- 用絕對路徑或從 Python 發出的呼叫，shim 看不到；R-N4 的限制仍然存在。
- ndt 裡**有**會改狀態的路徑，例如對 energy／sim 的 `app_stop` 會走 helper 的 `*-stop`。但這六支 suite 在任何一輪都沒有走到。

### 提案：每支 suite 內建一個 sudo stub（等你裁決，我沒改）

共同形狀，照 test_live_p1_common 的守衛做：

- suite 在開頭於 PATH 前面放自己的 `sudo`：
  - 對這支 suite 允許清單裡的唯讀探測，給一個**固定的「沒有 lab」答案**（`status` → `no lab sessions`；`list-br` → 空；`list sflow` → 空；`mnexec -a 1 true` → rc 1）；
  - 其他一律記錄並拒絕。
- suite 結尾加一條檢查：記錄下來的呼叫必須全部在允許清單裡，否則判紅。
- 結果：suite 的判定不再取決於這台機器上的 lab 狀態，也不可能用真的 sudo 去碰 lab。

| suite | 允許清單 | 另外 |
|---|---|---|
| test_apps_stop_kills_the_group | `ndtwin-lab status` | — |
| test_ndt_app_orphans | `ndtwin-lab status` | — |
| test_cell_gate_suspect_wiring | `ndtwin-lab status`、`ndtwin-lab topo-out N` | `$LAB` 是 round.env 的 `sudo -n …`，走 PATH，stub 接得到 |
| test_lab_handoff | `status`、`list-br`、`list sflow`、`mnexec -a 1 true` | 另 stub 不經 sudo 的 `tc qdisc show`（回空），讓 netem 計數固定 |
| test_ndt_honesty | `list-br`、`list sflow` | — |
| test_ndt_sample_rate_reads_both_bounds | `list-br`、`list sflow` | **一定要做**：它是唯一會因 lab 狀態而改判定的一支。另外也 stub 不經 sudo 的 `ovs-vsctl` |

**替代方案（沒做）**

- stub 也可以依格子給「活的」答案，讓每支 suite 固定也跑過 lab 是活的那條分支。
- 那是新的測試範圍，要另外設計，所以只列在這裡。

## (b) 四支在閘門環境下紅的 suite

### 怎麼診斷的（`diag_b.sgenv-3db3b9a8.log`，所有輸出都保留在 `scratchpad/tmp/diag_b_3db3b9a8/`）

每支 suite 在四種環境各跑一次：

- **E1**：閘門原樣，也就是 guard 加上完整的 nolab shim。
- **E2**：guard 加上**強制的**兩個 shim（sudo、curl）。
- **E3**：E2，再把 guard 的變數拿掉：JOBS、SHIM_JOBS、NDTWIN_GUARD_HELD、LOCK、LOCK_WAIT、MEM_*、TIMEOUT、NO_CGROUP。
- **E4**：E3，再換成短而真實的 TMPDIR。

suite 繼承到的 guard 變數：`NDTWIN_GUARD_HELD=/tmp/ndtwin-build.lock JOBS=1 SHIM_JOBS=1 LOCK_WAIT=10800`。

| suite | E1 | E2 | E3 | E4 | 原因 |
|---|---|---|---|---|---|
| test_build_guard | 15 紅 | 15 紅 | **0 紅** | 0 紅 | **環境**：繼承了外層 guard 的 `SHIM_JOBS=1`（與 `JOBS=1`） |
| test_l1_shell_scoring | 12 紅 | 12 紅 | 12 紅 | 12 紅 | **真缺陷**，與環境無關 |
| test_gate_exit_code_not_tee | 2 紅 | 2 紅 | 2 紅 | 2 紅 | **真缺陷**（對 worktree／clone 而言），與 guard 和 shim 無關 |
| test_start_bg_log_rotation | 6 紅 | 6 紅 | 6 紅 | 6 紅 | **真缺陷**，與環境無關 |

### test_build_guard：修了（`d271f5b8`）

- 原因：
  - suite 斷言的是 guard 的**預設值**（`-j2`）。
  - 在 guard 裡跑時，它繼承了外層的 `SHIM_JOBS=1`，15 條都讀到 `-j1`。
  - 其中包括「it puts the shims on PATH for the wrapped command」：巢狀的 guarded_build 會 export `SHIM_JOBS=$JOBS`，而 `JOBS=1` 是繼承來的。
- 修法：
  - suite 開頭 `unset JOBS SHIM_JOBS NDTWIN_GUARD_HELD LOCK LOCK_WAIT MEM_HIGH MEM_MAX TIMEOUT NO_CGROUP`。
  - 每個需要特定值的格子本來就在自己的命令列上設。
- **沒有改任何期望值**，check 數量也沒變（37）。
- red first（`redfirst_sge`）：
  - 在閘門環境下，3db3b9a8 的 suite 紅 15 條，每條的 actual 都是 `-j1`；
  - HEAD 是「Ran 37 checks, 0 failed」。
- 閘門：全綠，見 §(b) 閘門。

### 三支真缺陷：依指示停手，只回報（OBSERVED）

**1. test_start_bg_log_rotation**

- suite 期望的是 `.prev`／`.prev2` 兩代。
- 但 `74c811df`（2026-09-06，「O-4: keep five stamped generations of each component log, not two」）把 `stack.sh` 的 `rotate_log` 改成五代帶時間戳的 `$log.<YYYYmmdd-HHMMSS>`。
- 這支 suite 最後一次修改是 `8e7e3b00`（08-31），沒有跟著改。
- 所以從 09-06 起，它在**任何環境**都是紅的：6 條，全部是 `.prev`／`.prev2` 找不到。
- 應該改 suite 去驗五代帶時間戳的格式，還是 O-4 本身有問題，要你裁決。

**2. test_gate_exit_code_not_tee**

- case 1 期望 rc 0，實際 rc 2；case 4 也跟著紅。
- 保留下來的輸出：`cell=t008_poll mark=NO-DATA why=no twin trace` → `GATE ratio … verdict=UNRUNNABLE (no ratio -- NO-DATA)`，rc 2。
- 原因：
  - `t008_poll_twin.jsonl` 在 `doc/audit/2026-08-20_sampling-rate-and-cpu/raw/` 底下，而那個目錄有自己的 `.gitignore`，**整個被忽略**。
  - 它只存在於主 checkout，worktree、clone、CI 都拿不到。
  - suite 檔頭寫「an archived 08-20 cell that is in version control」，這一點不成立。
- 所以它只有在主 checkout 才會綠。這跟 guard 或 shim 無關。
- 修法二選一，要你裁決：把那個 cell 的最小 fixture 納入版控；或讓 suite 在資料不在時 SKIP，並清楚說明原因。

**3. test_l1_shell_scoring**

- group C「corpus」會讀 `tests/shell/test_*.sh` 的**原始碼**，取每支的最後一個 `echo "…"` 當作它的摘要行來評分。
- 有 12 支的最後一個 echo 不是摘要。例如：
  - test_apps_residue 是 `something was logged`；
  - test_build_guard、test_orphans_verdict、test_stack_log_rotation 找不到可讀的 echo。
- 這支 suite 最後一次修改是 `49801adb`（09-02）。之後 corpus 裡的 suite 陸續改了形狀，它沒有跟上。
- 與環境無關，在任何環境都是 12 紅。
- 是 suite 的啟發式該改，還是那 12 支的收尾格式該統一，要你裁決。

## (b) 閘門

全部經 guard，nolab shim 放在最前面，driver 從唯讀的凍結副本執行。log 在 `logs/gates-0910/<gate>.sgenv-d271f5b8.log`。

| 閘門 | rc | 結果（OBSERVED） |
|---|---|---|
| `redfirst_sge` | 0 | 在閘門環境下（繼承到 `JOBS=1`、`SHIM_JOBS=1`）：3db3b9a8 紅 15 條，每條都讀到 `-j1`；HEAD 是 37 checks、0 failed，check 數量相同 |
| `test_build_guard` | 0 | 37 checks，0 failed |
| `test_guarded_build_reentrant` | 0 | 15 checks，0 failed |
| `mutate_build_guard` | 0 | 14 個 mutation，0 存活 |
| `check_gate_anchors` | 0 | 120/120 |
| `nolab_tripwire` | 0 | 0 次 lab 呼叫 |

- 診斷用的 gate（`probe_report_a`、`probe_report_a2`、`diag_b`）與它們的 tripwire 都在 `*.sgenv-3db3b9a8.log`。
- `git merge-tree 8746c1bc d271f5b8` 沒有衝突，所以照你的指示留在 3db3b9a8 上，沒有 rebase。

DELIVERED d271f5b8589d9d8e0d8ac172080c3cd7db7ed69a
