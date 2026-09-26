# P4-HB-SPIKE — 段 S：外來 P4 fabric 的 veth 心跳，第一次 live

[Co-developed with claude code -- Adam]

- 工單：`doc/audit/2026-09-25_p4-heartbeat/TICKET-P4-heartbeat.md` §1 段 S。本文件是段 S 的報告，也是段 W 與 Adam 日後決定對外怎麼講的輸入。**內部稽核文件，不是對外宣稱。**
- 撰寫：opus worker，分支 `docs/p4-hb-spike-0926`（base trunk `580767a8`），2026-09-26。本文件作者沒有碰 lab，只讀 raw。
- 標記：
  - **OBSERVED**＝兩次 live run 的 raw 裡讀得到的數字或字句，附路徑。
  - **INFERRED**＝由常數、讀碼或對 OBSERVED 數字做算術推得，**沒有執行過**。
  - **READ**＝讀程式或先前文件得知、這兩次 run 沒有驗證的東西。
  - 跑過的與讀過未執行的分表，不混。
- 路徑縮寫（全部 repo-relative；raw 已公開於 `audit-raw` 分支 commit `1fafa3a0`，352 個 run 檔與下列 log 我逐檔比過 sha256，與工作副本相同）：
  - `R1/`＝`doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T023021Z_S_heartbeat/`
  - `R2/`＝`doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T052148Z_S_heartbeat/`
  - `log1`／`log1c`／`log2`＝`scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/` 底下的 `spike-S-detect-20260926T023021Z.log`／`spike-S-detect-cleanup.log`／`spike-S-all-20260926T052148Z.log`
  - `spike/`＝`doc/audit/2026-09-25_p4-heartbeat/spike/`

## 0. 兩次 live run

| | run 1 | run 2 |
|---|---|---|
| 時間（+08） | 2026-09-26 10:30:21–10:34:00（`log1:2`、`:115`） | 2026-09-26 13:21:48–13:38:41（`log2:2`、`:223`） |
| trunk | `4bc1201b`（`R1/01_binaries.txt`） | `580767a8`（`R2/01_binaries.txt`） |
| 參數 | `PART=detect CYCLES=10`，`NDT_OWNER=orch-0926` | `PART=all`（detect 10 cycles＋census 26 臂），`NDT_OWNER=orch-0926`，`env -u CLAIM_MINUTES -u CENSUS_EVEN_IF_RED -u FAULTS_TC -u NDT_MEASURING` |
| 偵測 | 10/10 剪斷、10/10 復原都判到（`R1/22_summary.txt`） | 10/10、10/10（`R2/22_summary.txt`） |
| 結果 | **FAIL**：`'ndt down' after the detection part exited 5`（`log1:114`）——量測過了，teardown 失敗（§4.1） | **PASS**（`log2:222`） |

## 1. 結論

1. **偵測延遲（報告層級，OBSERVED）**：兩次共 20 次剪線、20 次復原全部判到。「tc 返回 → 兩向都判為不通」min／median／max＝**13.275／14.293／14.382 s**；「拿掉 netem → 兩向都重新聽到」**4.813／4.864／4.910 s**。每一次都在 proxy 的 `LINK_BEACON_TIMEOUT_S=15` 以內。
2. **對工單 ≤20 s（INFERRED）**：段 W 還要加最多一次 watchdog pass（`LINK_WATCHDOG_INTERVAL_S=5`）。OBSERVED 最大值 14.382＋5＝**19.382 s**；只看常數是 ≤15＋5＝**20 s**，另加讀檔與 kernel 反應，兩者都沒量。最壞相位下沒有餘裕。自家 fabric 用同一條規則、同一組常數（`topology_manager.py:411` 自述「15 to 20 s」），所以是「同級」，不是「比較快」。
3. **這組數字不是隨機剪線時刻的分布（INFERRED，依 raw 時戳）**：spike 每個 cycle 都在「剛聽到」之後才剪，剪線相位被鎖住，所以量到的是常數推得區間的**上緣附近**（§2.3）。
4. **副作用普查（OBSERVED）**：26 臂裡有 20 臂真的送了心跳，一共 78 次主機 sniff、每次 20 s，**沒有任何主機收到心跳幀**（依 ethertype 或 payload 都沒有）。daemon 計數 `forwarded_to_hosts`／`forwarded_between_switches`／`misdelivered`／`foreign_frames` 在 20 臂全部是 0。**沒有觸發裁決 4 的停止條件。**
   - 另外 4 臂（calc、multicast 各兩臂）是單交換機，沒有交換機間鏈路，一幀都沒送。
   - 另外 2 臂（basic_tunnel/skeleton、flowcache/skeleton）沒建成，是設計上的紅。
5. **沒涵蓋到的（§3.3）**：
   - proxy 和 kernel 不在量測迴路裡。
   - 幀進了哪張表、哪個計數器，沒觀測。
   - p4runtime／flowcache 的 fabric 是空的（controller 沒起）。
   - 普查期間沒有流量。
   - 兩個偵測器（主機 sniff、daemon 計數）都沒有 live 陽性對照。
   - 06 各臂判定會不會變，留給 H5。
6. **spike 本身的缺陷**：run 1 的 teardown 被 ndt 自己的 measuring 守衛拒絕，spike 仍然 release，fabric 在無人 claim 下至少 34 s。第 7／7b 輪已修，run 2 在 live 上走過修好的路（§4）。

## 2. 偵測延遲

### 2.1 量法（READ：`spike/S_heartbeat_spike.sh` `detect()` :520-579、`spike/hb_watch.py`）

- **fabric 與心跳**
  - pod-topo `--app basic`（basic/solution，照 06 的方式轉包）。package 在 4 台交換機上有 20 條 entries；NDTwin 自己「discovered no links and installed no routes」（`log2:46-48`）。
  - 心跳：4 條鏈路 → 8 個方向，4 個 host-facing 介面只聽不送（`R2/11_hb_start.txt`）。
- **剪線**：out-of-band `tc qdisc add … netem loss 100%`，走 `sudo -n mnexec -a 1 tc`（`R*/00_tc_grant.txt`），同時下在 spine 線的兩端 `s1-eth3`、`s3-eth1`。沒有走 kernel 的 `inject_link_failure`。
- **每個 cycle 的六步**
  1. 先確認這條線兩向在最近 period＋1 s 內都聽得到（:547）。
  2. `t0a`→剪兩端→`t0`＝tc 返回的時刻（:550、:555）。`cut_tc_s = t0 − t0a`，包含找掛點與兩次 tc。
  3. `down_s`：每 0.1 s 讀一次 `/run/ndtwin-lab/heartbeat.json`（`hb_watch.py:199-212`），取兩向都滿足 proxy 規則 `now − last_heard_mono > LINK_BEACON_TIMEOUT_S` 的第一次輪詢，減去 `t0`（`hb_watch.py:78`）。這是**輪詢時刻**，解析度約 0.1 s 加 process 啟動時間。
  4. `collateral`：同一時刻另外 6 個方向仍在 15 s 內被聽到（:557、`hb_watch.py:99`）。
  5. 拿掉 netem，`t1`＝返回時刻。`up_s = max(兩向在 t1 之後的 last_heard_mono) − t1`（:561、`hb_watch.py:185-196`）。這用的是 **daemon 的接收時戳**，不是輪詢時刻。
  6. `netem_left`：兩端還有沒有 netem。
- **時鐘**：全部是 CLOCK_MONOTONIC（`hb_watch.py now` 與 daemon 的 `*_mono`）。
- **常數**：執行期從 `p4_proxy/proxy_agent/topology_manager.py` import，並 `env -u NDTWIN_P4_BEACON_S`。兩次 run 都是 `beacon=5 timeout=15 watchdog=5`（`R*/01_binaries.txt`、`log*:9`）。daemon 報告的 `period_s` 也是 5。
- **量的是報告層級**：意思是「proxy 若在這一刻讀報告，就判得出來」。proxy 本身沒有讀報告（段 W 還沒實作），kernel 也不在路徑上。
- **兩次 run 可以直接比**（跑過：我在 worktree 對兩個 commit 做 `git show`＋diff）：
  - `detect()`、`cut_link()` 在 `4bc1201b` 與 `580767a8` 逐字相同。
  - `hb_watch.py`、`hb_sniff.py`、`census_prepare.py` 的 sha256 相同（`R*/01_binaries.txt`）。
  - `nd_down()` 只多了一行 `retract_measuring`，在所有 cycles 之後才執行。

### 2.2 OBSERVED — 每個 cycle（`R1/20_cycles.tsv`、`R2/20_cycles.tsv`；兩次 run 的 `collateral` 全是 `OK`，`netem_left` 全是 `no`）

| cycle | run 1 down_s | run 1 up_s | run 1 cut_tc_s | run 2 down_s | run 2 up_s | run 2 cut_tc_s |
|---|---|---|---|---|---|---|
| 1 | 13.275 | 4.873 | 0.088 | 13.298 | 4.855 | 0.077 |
| 2 | 14.282 | 4.843 | 0.077 | 14.302 | 4.883 | 0.080 |
| 3 | 14.382 | 4.819 | 0.071 | 14.311 | 4.827 | 0.071 |
| 4 | 14.281 | 4.910 | 0.071 | 14.306 | 4.881 | 0.071 |
| 5 | 14.290 | 4.878 | 0.070 | 14.294 | 4.870 | 0.063 |
| 6 | 14.291 | 4.832 | 0.082 | 14.305 | 4.813 | 0.078 |
| 7 | 14.375 | 4.820 | 0.072 | 14.299 | 4.858 | 0.067 |
| 8 | 14.292 | 4.887 | 0.071 | 14.303 | 4.909 | 0.075 |
| 9 | 14.197 | 4.862 | 0.104 | 14.310 | 4.865 | 0.067 |
| 10 | 14.293 | 4.826 | 0.071 | 14.219 | 4.907 | 0.076 |

min／median／max 是我用 python `statistics` 從上面兩個 tsv 重算的，兩位小數與 `R*/22_summary.txt` 一致：

| | run 1（n=10） | run 2（n=10） | 合併（n=20） |
|---|---|---|---|
| down_s | 13.275／14.290／14.382 | 13.298／14.303／14.311 | 13.275／14.293／14.382 |
| down_s，只看 cycle 2–10 | 14.197／14.291／14.382 | 14.219／14.303／14.311 | — |
| up_s | 4.819／4.853／4.910 | 4.813／4.867／4.909 | 4.813／4.864／4.910 |
| cut_tc_s | 0.070／0.071／0.104 | 0.063／0.073／0.080 | 0.063／0.071／0.104 |

同一批 raw 的其他 OBSERVED：
- **qdisc 全樹**：兩次 run 都是 `qdisc state unchanged (32 lines)`（`R*/23_qdisc.diff`）。
- **起跑時**：心跳一起來 8/8 方向都聽得到（`log*:58`、`R*/12_report_first.json`）。
- **detect 結束時的報告**（`R*/24_report_last.json`，兩次 run 相同）：
  - 8 個方向各送 42 幀，`send_errors` 0。
  - 被剪的兩向各聽到 12，其他 6 向各聽到 42。
  - `side_effects` 四項全 0。
- **run 1 daemon 的最終報告**（pid 244126，stopped by SIGTERM）：留在 `R2/00_heartbeat_status_before.txt`，送 42／聽 12 與 42，side effects 全 0，和上一條一致。
- **每次剪線的快照**（`R*/21_report_cut_<i>.json`）：
  - 被剪那條線最後一次被聽到，都落在 daemon 啟動後 **5.00x＋20(i−1) s**（兩次 run 的 20 份快照都是如此）。
  - 快照的寫入時刻在它之後 14.997–15.004 s。

### 2.3 INFERRED

| 項目 | 值 | 怎麼來的 |
|---|---|---|
| 報告層級、剪線後判不通，只看常數 | (10, 15] s，外加 ≤0.1 s 輪詢 | 最後一次被聽到的時刻落在剪線前一個 period（5 s）之內；再過 15 s 規則成立。`R*/22_summary.txt` 自己也把這行標成 INFERRED |
| 報告層級、復原後重新聽到，只看常數 | (0, 5] s | 下一輪送出就會被聽到 |
| 相位被鎖住 | cycle 2–10 大約在最後一次被聽到之後 0.7 s 剪（15−14.3），cycle 1 大約 1.7 s（15−13.3）；復原則落在某次送出之後約 0.1–0.2 s（5−4.85） | 見下方說明 |
| 從第一次呼叫 tc 起算的上界 | 每個 cycle `down_s＋cut_tc_s` ≤ **14.453 s**（run 1 cycle 3） | 第一端的 netem 生效時刻落在 `(t0a, t0)` 之間，所以真延遲介於 `down_s` 與 `down_s＋cut_tc_s` |
| 段 W：剪線到 proxy 判定 | OBSERVED 最大值＋一次 watchdog pass＝14.382＋5＝**19.382 s**（從 `t0a` 起算 19.453 s）；只看常數 ≤ 15＋5＝**20 s** | watchdog 每 `LINK_WATCHDOG_INTERVAL_S=5` 跑一次，和心跳的相位無關 ⇒ 多等 (0, 5] s。**不含** proxy 讀檔、`_notify_link` 的 HTTP、kernel 更新圖（都沒量） |
| 段 W：若 H1 也用「聽到之後才剪」的迴圈 | 約 14.3＋(0, 5] ⇒ ≤ 19.3 s＋kernel | 同一個相位鎖 |
| 段 W：復原到 proxy 判定 | ≤ 5＋5＝10 s＋kernel；OBSERVED 最大 4.910＋5＝9.910 s | 同理 |
| 心跳證明的是什麼 | 那條 veth，不是交換機 | daemon 在對端 veth 上、在交換機之前就讀到幀（READ：`tools/test_workflow/ndtwin-lab` 心跳程式 docstring :657-693；`P4-HB-SUMMARY.md` §H.7 第 9 點） |

**相位鎖怎麼發生的：**
- 每個 cycle 從「剛聽到」開始：前一輪復原後的 `wait-heard` 一返回，下一輪就接著剪。
- 所以每個 cycle 都剛好跨 4 次送出（20.0 s），剪線總是落在同一個送出間隔的同一位置。
- raw 對得上：
  - 被剪兩向在 10 個 cycle 裡丟了 42−12＝30 幀，正好 10×3。
  - 第 i 份剪線快照都寫在 daemon 啟動後第 20·i s（20.004–200.006 s）。
- 所以表裡的 min／median／max 描述的是**這個迴圈的相位**。隨機時刻剪線時，`down` 應該分散在 (10, 15]；上界不受影響。

**run 1 對 run 2 的對帳**：量測碼相同（§2.1），兩次的 min／median／max 相差都不到 0.08 s（down 最大 14.382 對 14.311；up 最大 4.910 對 4.909）。逐 cycle 比，down 最多差 0.113 s（cycle 9：14.197 對 14.310），up 最多差 0.081 s（cycle 10）。可以比對，互不推翻。

## 3. 副作用普查（run 2）

### 3.1 量法（READ：`spike/S_heartbeat_spike.sh` `census()` :611-699、`spike/hb_sniff.py`、`spike/census_prepare.py`、helper 心跳程式）

- **每一臂的流程**
  1. 照 06 的方式建（`census_prepare.py` import `drive_exercise.py`）。
  2. `ndt up p4 --app`。
  3. `heartbeat start`。
  4. 所有主機**同時** sniff `SNIFF_S=20 s`（`R2/01_binaries.txt` 的 `sniff=20`，也就是 3×5＋5）。
  5. 讀 daemon 報告快照 `30_report.json`。
  6. `ndt down`。
- **主機 sniff**（`hb_sniff.py`，經 `sudo -n mnexec -a <host pid>`）
  - 一個 `ETH_P_ALL` socket，看得到 lo 以外的所有介面。
  - 兩個條件任一成立就算心跳幀：ethertype `0x88B5`，**或** payload 裡有 magic `NDHB`、且 magic 後第 6 byte 起是本 session 的 8 bytes。所以被改寫或包進隧道的幀也抓得到。
  - 看到第一幀就停。
- **daemon 計數**（READ：`tools/test_workflow/ndtwin-lab` :1095-1161）
  - `forwarded`：心跳幀以 OUTGOING 離開某介面，而且那個介面不是它自己的送出端。落在 host-facing 介面算 `forwarded_to_hosts`，否則算 `forwarded_between_switches`。
  - `misdelivered`：INCOMING 到了不對的介面。
  - `foreign`：別的 session 的幀。
- **停止條件（裁決 4）**：任一主機看到心跳幀，或 `forwarded_to_hosts>0`，就停。

### 3.2 OBSERVED — 26 臂（`R2/40_census.tsv`；各欄由 `R2/census_<練習>_<臂>/` 的 `10_up.txt`、`11_hb_start.txt`、`30_report.json`、`sniff_*.json`、`90_down.txt` 讀出）

欄位說明：
- up：package entries／交換機數，出自 `10_up.txt`。
- 送／聽：快照裡 8 或 6 個方向的合計。
- 主機幀：該臂所有主機 sniff 到的幀總數，括號是其中的心跳幀。
- 計數：`→主機／交換機間／誤投／外來`。
- down：`90_down.txt` 的結尾。

| 練習 | 臂 | up | 心跳 | 程式 | 方向 | 送／聽 | 主機 | 主機幀（心跳） | 計數 | down |
|---|---|---|---|---|---|---|---|---|---|---|
| basic | solution | 20／4 | running | basic | 8 | 40／32 | 4 | 20（0） | 0／0／0／0 | clean |
| basic | skeleton | 20／4 | running | basic | 8 | 40／32 | 4 | 13（0） | 0／0／0／0 | clean |
| source_routing | solution | 0／3 | running | source_routing | 6 | 30／30 | 3 | 11（0） | 0／0／0／0 | clean |
| source_routing | skeleton | 0／3 | running | source_routing | 6 | 30／30 | 3 | 11（0） | 0／0／0／0 | clean |
| calc | solution | 0／1 | no link (rc 3) | — | 0 | — | — | 沒送 | — | clean |
| calc | skeleton | 0／1 | no link (rc 3) | — | 0 | — | — | 沒送 | — | clean |
| multicast | solution | 4／1 | no link (rc 3) | — | 0 | — | — | 沒送 | — | clean |
| multicast | skeleton | 4／1 | no link (rc 3) | — | 0 | — | — | 沒送 | — | clean |
| basic_tunnel | solution | 18／3 | running | basic_tunnel | 6 | 30／30 | 3 | 15（0） | 0／0／0／0 | clean |
| basic_tunnel | skeleton | NOT-BUILT preflight rc=1 | — | — | — | — | — | — | — | — |
| load_balance | solution | 14／3 | running | load_balance | 6 | 30／30 | 3 | 10（0） | 0／0／0／0 | clean |
| load_balance | skeleton | 14／3 | running | load_balance | 6 | 30／30 | 3 | 12（0） | 0／0／0／0 | clean |
| qos | solution | 11／3 | running | qos | 6 | 30／30 | 5 | 25（0） | 0／0／0／0 | clean |
| qos | skeleton | 11／3 | running | qos | 6 | 30／30 | 5 | 25（0） | 0／0／0／0 | clean |
| link_monitor | solution | 24／4 | running | link_monitor | 8 | 40／40 | 4 | 20（0） | 0／0／0／0 | clean |
| link_monitor | skeleton | 24／4 | running | link_monitor | 8 | 40／40 | 4 | 21（0） | 0／0／0／0 | clean |
| firewall | solution | 28／4 | running | basic＋firewall | 8 | 40／40 | 4 | 20（0） | 0／0／0／0 | clean |
| firewall | skeleton | 28／4 | running | basic＋firewall | 8 | 40／40 | 4 | 20（0） | 0／0／0／0 | clean |
| ecn | solution | 11／3 | running | ecn | 6 | 30／30 | 5 | 25（0） | 0／0／0／0 | clean |
| ecn | skeleton | 11／3 | running | ecn | 6 | 30／30 | 5 | 25（0） | 0／0／0／0 | clean |
| mri | solution | 14／3 | running | mri | 6 | 30／30 | 5 | 25（0） | 0／0／0／0 | clean |
| mri | skeleton | 14／3 | running | mri | 6 | 30／30 | 5 | 25（0） | 0／0／0／0 | clean |
| p4runtime | solution | **EMPTY**／3 | running | advanced_tunnel | 6 | 30／30 | 3 | 17（0） | 0／0／0／0 | clean |
| p4runtime | skeleton | **EMPTY**／3 | running | advanced_tunnel | 6 | 30／30 | 3 | 16（0） | 0／0／0／0 | clean |
| flowcache | solution | **EMPTY**／3 | running | flowcache | 6 | 30／30 | 3 | 16（0） | 0／0／0／0 | clean |
| flowcache | skeleton | NOT-BUILT compile rc=1 | — | — | — | — | — | — | — | — |

**合計**：20 臂、78 次主機 sniff、主機一共收到 372 幀，其中心跳幀 **0**（`by_ethertype` 與 `by_payload` 都是 0）。快照裡送進 pipeline 的心跳幀至少 660 幀。另外 run 1 的 detect 階段對 basic/solution 送了 336 幀，side effects 也全 0（§2.2）。

逐列說明：
- **sniffer 本身**：78 份 `sniff_*.json` 都是 `"seconds": 20.0`、`"stopped": "time"`，`error` 欄都沒有，78 份 `.err` 都是 0 bytes。每台主機只有 `eth0` 一個介面，收到 3–6 幀非心跳幀。sniffer 只記數量不記內容，所以這些幀是什麼不知道。
- **4 臂 no link**（calc、multicast 各 solution／skeleton）
  - `11_hb_start.txt` 寫「the running fabric has no switch-to-switch link; nothing to send」：1 台交換機、0 條鏈路，calc 2 個、multicast 4 個 host-facing 介面只聽。
  - `ndt up` 是 ready（calc 0 條、multicast 4 條 entries，都在 1 台交換機上）。
  - `40_census.tsv` 記為 `no frame sent`。**這 4 支 pipeline 沒有收到任何心跳幀，普查對它們什麼也沒說。**
- **2 臂 NOT-BUILT**，都標「(the arm's designed red)」，沒有 fabric：
  - basic_tunnel/skeleton：preflight rc=1，9 個 problem，第一個是「table 'MyIngress.myTunnel_exact' is not in the p4info」（`R2/prep_basic_tunnel_skeleton.txt`）。
  - flowcache/skeleton：p4c 編譯 rc=1：`packet_in`／`packet_out` header 缺欄位（`Field … is not a member of header …`，`--Werror=type-error`；`R2/prep_flowcache_skeleton.txt`）。
- **p4runtime 兩臂、flowcache/solution 是空的**：`10_up.txt` 寫「external control plane: this fabric is up and EMPTY. NDTwin has programmed nothing and will not」。所以這三支 pipeline 遇到心跳幀時，表是空的，只有 default action。
- **basic 兩臂的 40／32 不是掉幀**
  - OBSERVED：快照寫在最後一次被聽到之後 5.000–5.001 s；每個方向 `sent` 5、`last_seq` 4。
  - OBSERVED：其他 18 臂的快照寫在最後一次被聽到之後 0.500–0.501 s，送＝聽。
  - INFERRED：basic 兩臂的快照是第 5 輪送出當下那次例行寫入，第 5 輪還沒被聽到。所以它們快照裡的計數只涵蓋前 4 輪。
- **每臂的 `ndt down`**：
  - 24 臂的 `90_down.txt` 都以「claim note now says the lab is down and verified clean」結尾。
  - `log2` 裡沒有任何一行「census …: 'ndt down' exited」。
  - `40_census.tsv` 沒有 `skipped` 列。

### 3.3 READ／INFERRED（沒有在這兩次 run 執行或驗證）

**ethertype 碰撞表**（READ，轉引 `scratch/overnight-2026-09-05/hunt-0911/fix/P4-HB-SUMMARY.md` §H.5，06 的 13 練習 × 2 臂＋`ndtwin_switch.p4`）：

| 練習 | 用到的 16-bit 常數 | 對 etherType 的 select |
|---|---|---|
| basic | 0x800 | solution：0x800→ipv4、default accept；skeleton：沒有 select |
| source_routing | 0x800、0x1234 | solution：0x1234→srcRouting；skeleton：沒有 select |
| calc | 0x1234 | 0x1234→check_p4calc |
| multicast | — | 只有 default accept |
| basic_tunnel | 0x1212、0x800 | solution 兩者；skeleton 只有 0x800 |
| load_balance、qos、ecn、mri、firewall、flowcache | 0x800 | 0x800→ipv4 |
| link_monitor | 0x800、0x812 | 0x800→ipv4、0x812→probe |
| p4runtime（advanced_tunnel） | 0x1212、0x800 | 兩者 |
| ndtwin_switch.p4 | 0x0800、0x0806、0x88CC | — |

- 已被用掉的值：{0x0800, 0x0806, 0x0812, 0x1212, 0x1234, 0x88CC}。
- 選 **0x88B5**（`R2/census_*/30_report.json` 的 `"ethertype": "0x88b5"`＝OBSERVED）。
- 依 §H.5，所有 parser 遇到未知 ethertype 都是 `default: accept`，沒有 reject。

**§H.6 的讀碼預測 vs 本次觀測（對帳）**：

| 預測（READ） | 本次 | 判讀 |
|---|---|---|
| 沒有一支會把幀送到主機 | 20 臂主機 0 幀、`forwarded_to_hosts` 0（OBSERVED） | **符合**（20 臂，solution 與 skeleton 都有） |
| calc、multicast 在 06 的包裝裡是單交換機，start 回 3 | 4 臂都回 rc 3（OBSERVED） | **符合** |
| 被 `drop()` 丟，或 `egress_spec` 維持 0 後被 bmv2 丟 | 沒有任何介面出現 OUTGOING 的心跳幀、也沒有誤投（OBSERVED） | **不矛盾，但沒有驗證是哪一種**。「進了哪張表／哪個計數器」這次沒觀測：`simple_switch_CLI` 缺 `thrift`，見 `P4-HB-SUMMARY.md:212` |
| 唯一的結構性風險：multicast 做成多交換機時 `default_action=multicast` | 06 的包裝是單交換機，這個風險沒被碰到 | **未涵蓋** |

**普查沒有涵蓋的**：
1. **controller 沒起**：p4runtime、flowcache 的 fabric 是空的（§3.2）。有 controller、有 entries 時會怎樣，是 H5 的事。
2. **沒有流量**：spike 不產生流量，pipeline 是在閒置狀態下遇到心跳。有狀態的 pipeline（flowcache、link_monitor、mri、load_balance）在有流量時的反應沒量。06 各臂判定會不會因心跳改變（裁決 4 的後半）是 H5 的事。
3. **視窗長度**（INFERRED，依本機 raw 檔 mtime；git 不保存 mtime）
   - 各臂 sniffer 在 daemon 啟動後 0.25–0.53 s 才開，到 20.38–20.53 s 結束；第 1 輪（t≈0）送出時還沒開。
   - 所以主機端涵蓋每臂 5 輪中的第 2–5 輪，daemon 計數涵蓋快照內的輪次（basic 兩臂是第 1–4 輪）。
4. **沒有 live 陽性對照**：兩個偵測器在 live 上都只讀到 0。
   - 它們的 socket 在 live 上是活的：daemon 在正確介面上的 INCOMING「heard」會隨剪線／復原變化（§2.2）；每台主機 sniffer 都收到 3–6 幀非心跳幀。
   - 但「真的心跳幀到了主機會被認出來」和「OUTGOING 轉送會被記成 `forwarded`」只在離線證過：spike 自測用 daemon 自己的 `encode` 產幀，原樣與重新包裝都認得；helper 測試 §H.3 第 6、8 點（`P4-HB-SUMMARY.md`）。
   - 零的鑑別力建立在這些離線證明上。
5. **daemon 計數看不到改過 ethertype 的幀**（READ：helper 的 BPF 只收 0x88B5，`tools/test_workflow/ndtwin-lab:1047-1048`）。
   - 某支 pipeline 若把幀重新包裝、改了 ethertype 再轉到別的交換機，四個計數都會是 0。只有它到了主機時，才會被 sniffer 用 payload 抓到。
   - 送到 CPU port（packet-in）的幀，兩個偵測器都看不到。這次沒有 controller，送上去也沒人收。
6. **沒建成的 2 臂沒有 pipeline 可測**。它們在 06 裡同樣停在 fabric 之前（`census_prepare.py` docstring），所以 H5 也不會碰到（INFERRED）。
7. **link 遙測取樣到心跳幀**（`P4-HB-SUMMARY.md` §H.7 第 10 點）：沒量。

## 4. 第一次 live 發現的 spike 缺陷與修正

### 4.1 run 1 的 teardown：自己的 `measuring=` 讓 ndt 拒絕 down，spike 仍然 release

**發生了什麼（OBSERVED）：**
- detect 階段 export 了 `NDT_MEASURING`（READ：現行 spike :1654）。兩份拒絕訊息引的正是它：「measuring=heartbeat spike S: detection latency, out-of-band netem on s1-eth3/s3-eth1」（OBSERVED）。
- 之後兩次 `ndt down` 都回 rc 5，訊息是「refusing to tear down: this claim DECLARES a measurement in progress」（`R1/26_down.txt`、`R1/90_down.txt`；`log1:96`、`:101-105`）。
- `finish()` 照樣 release：`app_package_override SURVIVED`、`ok lab released`（`log1:106-111`）。
- 在這之前，心跳已經停了（`R1/25_hb_stop.txt`），netem 已經拿掉、qdisc 與快照相同（`log1:95`）。
- fabric 在無人 claim 的狀態下，從 release（不晚於 10:34:00，`log1:115`）到 orchestrator 10:34:34 claim 收尾（`log1c:1`、`:8`），**至少 34 s**。
- 收尾：`ndt down` rc 0、verify clean；release rc 0；之後 `ndt status` 是 bmv2 0、tc netem none、heartbeat not running（`log1c:10-61`）。

**修正**（第 7 輪，`P4-HBR7-SUMMARY.md:6-9`）：
- `5c34da71`：每次 `ndt down` 之前先 `retract_measuring`，也就是 `env -u NDT_MEASURING ndt claim`，並讀回確認；down 回 0 或 3 才 release，其他一律保留 claim、印出指令。
- 紅燈先行：`dba92d4e`。
- oldcode 列 L1、L2：`e20fd477`。
- 判官：`a77b8fe2` MERGE AFTER FIXES（`judge-HBR7-a77b8fe2.md:5`）。

**run 2 在 live 上走過修好的路（OBSERVED）：**
- detect 之後重宣告：「re-claiming WITHOUT measuring= … ok lab claimed by orch-0926 for 177m」（`log2:96-98`、`R2/26_down.reclaim.txt`）。接著的 `ndt down` 走完，以 verify clean 收尾（`R2/26_down.txt`）。
- 收尾的 `ndt down` 回 3，被當成預期（`log2:208-211`、`R2/90_down.txt`「nothing was up to tear down」）。
- 在還原好的旋鈕上再 claim 一次（`log2:214-216`、`R2/95_release.reclaim.txt`「for 164m」），然後 release（`log2:219`）。
- **`keep_claim`（down 被拒時保留 claim）這條路沒有在 live 上走過**：這次沒有任何 down 被拒。

### 4.2 `CLAIM_MINUTES=180` 是死碼（判官在 run 2 之前找到）

- **問題**：run 1 實際 claim「for 45m」（`log1:39`）。原因是 `_common.sh:37` 的 `: "${CLAIM_MINUTES:=45}"` 先被 source，spike 自己的 180 預設永遠不生效。
- **誰找到的**：判官在 `a77b8fe2` 的 finding 1，blocking（`judge-HBR7-a77b8fe2.md:5`、`:10`）。PART=all 依檔頭估算要 56–82 分鐘，claim 會在 census 中途過期。
- **修正**：`f1e1be2b` 把預設移到 source 之前；紅燈 `11734586`；oldcode 列 R7-1 `20870ce0`；判官 `96abb9b0` MERGE（`judge-HBR7b-96abb9b0.md:6`）。
- **live**：run 2 claim「for 180m」（`log2:39`）。
- **附記（OBSERVED）**：run 2 整體只跑了 16 分 53 秒，比估算短很多。

### 4.3 census 在某臂 down 被拒之後仍往下建

- **問題**：下一臂的 `ndt up p4 --app` 碰到同尺寸的完好 fabric，只會回「already up … reusing」，於是量錯 pipeline。
- **誰找到的**：判官 `a77b8fe2` 的 finding 2，note，強烈建議修（`judge-HBR7-a77b8fe2.md:11`）。
- **修正**：`f1e1be2b` 的 `census_down`：停下、其餘臂記 `skipped`、判 FAIL。紅燈 `11734586`；oldcode 列 R7-2、R7-2/stop、R7-2/always `20870ce0`。
- **live**：沒有觸發。run 2 的 24 臂 down 都是 clean（§3.2）。

**仍然開著、這兩次沒觸發：**
- 沒給 `NDT_OWNER` 時會以 `live-p1` 取 claim（`judge-HBR7b-96abb9b0.md:9`；run 2 有明給，`log2:2`）。
- `spike_finish` 拆 netem 失敗時的訊息列不出介面名（`judge-HBR7-a77b8fe2.md:16`）。
- `CENSUS_EVEN_IF_RED=1` 加上 detect 提早停時，fabric 會留著給 census 用（`P4-HBR7-SUMMARY.md:16`；run 2 用 `env -u` 拿掉了）。

## 5. 給段 W 的輸入

### 5.1 W 可以依賴的（O＝OBSERVED，I＝INFERRED）

- **（O）daemon 報告在真 veth、真 netem 上的語意是對的**
  - 剪線之後，被剪兩向不再被聽到，其他 6 向照常；復原後一個 period 內重新聽到。
  - `send_errors` 0。
  - 報告的 `period_s` 是 5，等於 proxy 的 `LLDP_BEACON_INTERVAL_S`（§2.2）。
- **（O）報告層級的延遲**：down 13.275–14.382 s，up 4.813–4.910 s，n=20。**（I）** W 層級剪線 ≤ 20 s、復原 ≤ 10 s，都另加 kernel 反應（§2.3）。
- **（O）報告的寫入節奏**：每輪寫一次；聽到東西後 0.500–0.501 s 內再寫一次（18 臂的快照）。
  - **（I）** daemon 活著時，H.7 提案的新鮮度判準（`written_mono` 距今 ≤ 2×`period_s`）應該會一直成立。
- **（O）副作用**：心跳幀在這 20 臂（06 的包裝、沒有流量、沒有 controller）裡從沒到過主機；四個計數全 0。W 要揭露在 `switch_state` 的 `side_effects`，這兩次 run 裡的值就是全 0。
- **（READ）link key**：報告方向的 `(tx.dpid, tx.port, rx.dpid, rx.port)` 就是 H.7 提案的 key（`P4-HB-SUMMARY.md` §H.7 第 4 點）。
- **（READ）常數**：daemon 的 `PERIOD_S=5` 寫死（`ndtwin-lab:734`）；proxy 的可以被 `NDTWIN_P4_BEACON_S` 改。兩者不一致時怎麼處理見 H.7 第 6 點；這兩次 run 都是一致的。

### 5.2 W 仍須在 live 上證明的（工單 §2）

- **H1**：外來 fabric 剪一條 spine 線 ⇒ ≤20 s kernel 圖兩向 `is_up:false` ⇒ 路由改寫 ⇒ 12 對主機 ping 全恢復；拿掉 netem ⇒ ≤20 s 恢復 `is_up:true`；沒有殘留 netem。
  - 本 spike 只到報告層級。H1 的 ≤20 s 在最壞相位只剩 kernel 反應時間的餘裕，這與自家 fabric 同一性質（§2.3，INFERRED）。**算數的是 H1 實際量到的數字。**
- **H2**：陰性對照，心跳不跑 ⇒ `is_up` 保持 true。本 spike 沒有這個對照：proxy 沒有讀報告，也沒有記錄 kernel 的 `is_up`。
- **H3**：unbound package ⇒ 只偵測、不改路，`reroute:false` 附原因，寫入回 501。
- **H4**：`/stats/flowentry/*` 在外部控制平面回 409。
- **H5**：06 完整跑一次、心跳開著 ⇒ 26/26，且逐臂與 `2026-09-24T185505Z` 相同；01 PASS。本 spike 普查沒涵蓋的 §3.3 第 1、2 點（controller、流量、判定是否改變）由這一項補上。
- **H5 也不會涵蓋的**（INFERRED）：
  - 多交換機的 multicast。
  - 兩個沒建成的 skeleton 臂。
  - 兩個偵測器的 live 陽性對照。

## 6. 證據索引

### 6.1 binary 識別（OBSERVED，`R*/00_helper_sha.txt`、`R*/01_binaries.txt`）

| | run 1 | run 2 |
|---|---|---|
| trunk | `4bc1201b091ae692119a7c76ac17dd7b5c42e0be` | `580767a83dea12e42755687d174af891b69deb97` |
| 已裝 `/usr/local/sbin/ndtwin-lab` sha256 | `6a558fe452955de358fd1a3b4e730fe2be55368a6c90b93675c5442c036fd4fb` | 同左 |
| checkout 的 `tools/test_workflow/ndtwin-lab` sha256 | 同上（已裝＝checkout） | 同上 |
| `hb_watch.py`／`hb_sniff.py`／`census_prepare.py`（sha256 前 16） | `326b76ecc6d85c73`／`9a14d80b3f9c11e4`／`4c5c507219bc924c` | 同左 |
| `S_heartbeat_spike.sh`（sha256 前 16） | `db20f12e8191d2bd` | `6b4e98316d20b95a` |
| proxy 常數（執行期 import） | beacon=5 timeout=15 watchdog=5 sniff=20 | 同左 |

- 我在 worktree 對兩個 commit 的 blob 重新雜湊過（跑過）：spike 四支檔與 helper 的 sha256 和上表相同。
- 兩次 run 都在主 checkout 上跑。當時有 79 個未提交檔，其中 2 個會影響行為：`p4_proxy/mininet/host_count_override`（快照為 4、已還原）與 `tools/remote-lab/dorm_lab/`（`log*:25-28`）。
- tutorials 的 `.p4` 在 repo 外（`/home/adam/tutorials`），執行期才編譯。各臂的 p4c／preflight 輸出與 p4info sha 在 `R2/prep_*.txt`。
- kernel／proxy 雖然有起，但不在量測路徑上，所以本文件不指認它們的 binary。

### 6.2 引用過的 raw 與文件

| 路徑 | 內容 | 用在 |
|---|---|---|
| `R1/20_cycles.tsv`、`R2/20_cycles.tsv` | 每 cycle 的 down／up／cut_tc／collateral／netem_left | §2.2 |
| `R1/22_summary.txt`、`R2/22_summary.txt` | spike 自己的 min/median/max 與判定 | §0、§2.2 |
| `R*/21_report_cut_{1..10}.json`、`R*/12_report_first.json`、`R*/24_report_last.json` | 剪線當下、起跑、結束時的心跳報告 | §2.2、§2.3 |
| `R*/23_qdisc.diff`、`R*/13_qdisc.before` | qdisc 全樹比對 | §2.2 |
| `R*/11_hb_start.txt`、`R*/10_up_basic.txt`、`R*/00_tc_grant.txt` | 心跳計畫、fabric、tc 路徑 | §2.1 |
| `R2/00_heartbeat_status_before.txt` | run 1 daemon 的最終報告 | §2.2 |
| `R2/40_census.tsv` | 普查表 | §3.2 |
| `R2/census_<練習>_<臂>/{10_up.txt,11_hb_start.txt,30_report.json,31_hb_stop.txt,sniff_*.json,sniff_*.err,90_down.txt}` | 每臂的 raw | §3.2 |
| `R2/prep_basic_tunnel_skeleton.txt`、`R2/prep_flowcache_skeleton.txt` | 沒建成的原因 | §3.2 |
| `R1/26_down.txt`、`R1/90_down.txt`、`R1/25_hb_stop.txt` | run 1 的 teardown 被拒 | §4.1 |
| `R2/26_down.reclaim.txt`、`R2/26_down.txt`、`R2/90_down.txt`、`R2/95_release.reclaim.txt` | run 2 走過重宣告與 release 的路 | §4.1 |
| `log1`、`log1c`、`log2` | 兩次 run 與收尾的終端輸出 | §0、§4 |
| `scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/judge-HBR7-a77b8fe2.md`、`judge-HBR7b-96abb9b0.md` | 第 7／7b 輪裁決 | §4 |
| `scratch/overnight-2026-09-05/hunt-0911/fix/P4-HBR7-SUMMARY.md` | 第 7／7b 輪 worker 交件 | §4 |
| `scratch/overnight-2026-09-05/hunt-0911/fix/P4-HB-SUMMARY.md` §H.5–H.7、:212 | 碰撞表、預測、proxy 端契約、表／計數器觀測不到的原因 | §3.3、§5 |
| `spike/S_heartbeat_spike.sh`、`spike/hb_watch.py`、`spike/hb_sniff.py`、`spike/census_prepare.py` | 量法（READ） | §2.1、§3.1 |
| `tools/test_workflow/ndtwin-lab` :657-693、:734、:764-765、:1047-1048、:1095-1161 | 心跳 daemon 的語意、週期、寫入節奏、BPF、計數 | §2.3、§3.1、§3.3 |
| `p4_proxy/proxy_agent/topology_manager.py` :369、:411-418、:1951-1953 | `LLDP_BEACON_INTERVAL_S`、`LINK_BEACON_TIMEOUT_S`、`LINK_WATCHDOG_INTERVAL_S`、`_link_timeout` | §1、§2.3 |
| `doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh:35`、`:37` | `NDT_OWNER`／`CLAIM_MINUTES` 的預設 | §4.2 |
