# ndt serve：探測與自動更新的實際成本（2026-10-01）

[Co-developed with claude code -- Adam]

## 量測條件

- **授權**：Adam 2026-10-01 在對話裡明確授權這一次 lab 使用（`NDT_OWNER=ndt-serve-gui`，claim 45 分鐘，設 `NDT_MEASURING`），依 10/2 orchestrator 的 brief。
- **ndt**：主 checkout `d452d111` 的 `tools/test_workflow/ndt`，沒有未 commit 的改動，sha256 `81c1326a…`，11,078 行。分支 head `59e3ba1f`。
- **探測實際跑的指令**：plain `ndt status`。`serve.py` 的 `r_lab` 呼叫 `verbs.argv_status(False)`，也就是 `["status"]`。

| | 閒置（lab 關著） | 量測中（探測真正會跑到的狀態） |
|---|---|---|
| fabric | 無；kernel :8000 沒開 | `ndt up p4 4`，10 台 bmv2；kernel :8000 回應 |
| claim／declared | 無（第一段量測）／無 | `ndt-serve-gui` 45 分鐘；declared「ndt serve probe-cost measurement」 |
| measuring 欄位 | `nothing` | `iperf3 -c 10.0.0.2 -p 5201 -t 480 -i 30`（h1 到 h2） |
| log | `10-idle-forks.log`、`11-idle-sudo-*.log` | `40`–`44-*.log`，每段前後都印了 `state` 行 |

**方法**：
- **程序數**：不經 ptrace。讀 `/proc/stat` 的 `processes`（自開機起的 fork 數，全機計數，連 thread 也算），取跑一次前後的差；接著馬上量一段等長的閒置窗口，相減得到淨增量。每項重複 7 次，取中位數，括號內是最小到最大。背景裡有 Adam 自己的 Chrome，沒有測試在跑。
- **sudo 次數**：PATH 最前面放一個 shim，每次記下 argv，再 `exec /usr/bin/sudo`。真正的 setuid sudo 照樣執行，root 那一側的程序都有跑到。
- **kernel 那次讀取**：照 ndt 的 `http_get_graph` 用 curl 打 `/ndt/get_graph_data`，記下 `time_total`；單打 7 次，兩個同時打 7 次。

## 結果

| | 閒置 | 量測中 | 標記 |
|---|---|---|---|
| **一次探測**（plain `ndt status`）：淨增 task 數 | 448（445–450） | **564（524–595）** | OBSERVED |
| 一次探測：牆鐘 | 1.07 s | 1.58 s | OBSERVED |
| 一次探測：sudo 呼叫 | 8 次：`ovs-vsctl list-br` ×3、`ndtwin-lab status` ×4、`mnexec -a 1 true` ×1 | **6 次**：`ovs-vsctl list-br` ×1、`ndtwin-lab status` ×4、`mnexec -a 1 true` ×1（3 次都一樣） | OBSERVED |
| 一次探測：對 kernel 的請求 | 無（:8000 沒開） | **1 次 `GET /ndt/get_graph_data`**：約 25 KB；單打中位數約 6.4 ms（4.7–6.7 ms） | OBSERVED |
| 兩個 `get_graph_data` 同時打 | — | 先完成的那個約 6.2 ms，後完成的那個 7.6–12.0 ms | OBSERVED |
| **完整一輪**（`ndt status` 和 `ndt apps status` 並行）：淨增 task 數 | 596（582–603） | **719（696–736）** | OBSERVED |
| 完整一輪：牆鐘 | 1.03 s | 1.87 s | OBSERVED |
| 完整一輪：sudo 呼叫 | 10 次（8＋2） | **8 次**（6＋2；`apps status` 是 `ndtwin-lab status` ×2） | OBSERVED |
| 完整一輪：對 kernel 的請求 | 無 | 1 次 `get_graph_data` | OBSERVED |

**換算成每分鐘**（算出來的，INFERRED）：

| | 每分鐘的 task | sudo | kernel 請求 |
|---|---|---|---|
| 量測中暫停時：每 60 s 探測一次 | 約 564 | 6 | 1 |
| 不暫停、在量測中的狀態下每 10 s 一輪（上一輪讀完才排下一輪，約 60／11.87 ≈ 5.1 輪） | 約 3,630 | 約 40 | 約 5 |
| lab 閒置時每 10 s 一輪（約 60／11.03 ≈ 5.4 輪） | 約 3,240 | 約 54 | 0 |
| 探測剛好落在兩段沒有 declared 的量測之間：恢復後到某次讀取看到下一段量測之前，最多一輪完整讀取 | 719、8 次 sudo、1 次 kernel 請求、1.87 s | | |

## 推翻或更正之前的說法

- **舊的 strace 數字（221 個程序、7 次 sudo）不成立。** 舊的 `strace/status.strace` 裡，7 個 sudo 都 `si_status=1` 立刻退出：ptrace 底下 setuid 失效，所以 `ovs-vsctl`、`ndtwin-lab`、`mnexec` 一次都沒有被 exec。ndt 也因此走了不同的分支，少呼叫一次 `ovs-vsctl list-br`。
- **兩個計數的口徑不同。** 這裡的計數連 thread 也算，舊的 strace 把 process 和 thread 分開數；不過低估的主因是 sudo 那一側根本沒跑。
- **兩個並行的 `get_graph_data`**：後完成的那個慢了約 2–6 ms。推測 kernel 是依序服務 northbound 請求，這也和記憶裡「北向 API 序列化」一致（INFERRED：只看了 curl 的耗時，沒看 kernel 內部）。所以一次探測，最多讓同一時間的另一個 northbound 讀取多等一次 graph 序列化的時間，約 6 ms。

## 還原：RESTORE-OK

1. iperf3 在 17:11:08 自己結束：480 s，603 Mbit/s。之後沒有任何 iperf3 程序（`33-iperf-client.log`）。
2. 第一次 `ndt down` 回 **rc 5**（`50-restore-down.log`）：claim 的 `measuring=` 還在，ndt 看不出量測是否還在跑，所以拒拆。
   - 照 ndt 自己的建議，不設 `NDT_MEASURING` 重新 claim 一次，清掉那個 declaration，不用 `--force`。之後 `ndt down` 回 **rc 0**，並驗證乾淨（`53-restore-down-2.log`）。
3. `ndt clean` 回 **rc 3**，也就是沒有東西可判：沒有 fabric、`.test_run/pids/` 沒有活的程序、ports 沒被占（`54-restore-clean.log`）。
4. `ndt apps orphans` 回 **rc 5**：沒有未追蹤的 app 程序，但 kernel 已關，查不了 rule（ndt help：5＝程序乾淨、rule 查不了）。結果在 `55-restore-orphans.log`。
5. release 回 rc 0。之後 `ndt status` 和量測前逐行比，差 21 行（`57-pre-vs-after.diff`），分三類：
   - **prev claim**：現在是 `ndt-serve-gui`，這是預期的。
   - **`.test_run/up.target`**：被 `ndt down` 清掉了。量測前那份是 2026-09-30 13:39 留下的舊紀錄（owner 未設），和當時已關著的 lab 對不上（`dataplane none != p4 MISMATCH`）。`up` 接著 `down` 本來就會清掉它，所以沒有放回去。
   - **`hosts`／`topology` 兩行**：因為上面這份紀錄消失，改顯示 unknown，同一件事的兩面。
6. 其他：
   - `p4_proxy/mininet/host_count_override` 還是 `4`，mtime 還是 2026-09-27，沒被改寫。它相對 HEAD 的未 commit 差異（128→4）在量測前就有了。
   - `.test_run/lab.claim` 和 `round.baseline` 已不在。
   - 沒有殘留的 `simple_switch`（`ps` 裡唯一含這個字串的，是另一個 session 的 shell 指令文字）。
