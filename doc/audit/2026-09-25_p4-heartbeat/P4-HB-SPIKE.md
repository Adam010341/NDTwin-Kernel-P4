# P4-HB-SPIKE — 段 S：外來 P4 fabric 的 veth 心跳，四次 live run

[Co-developed with claude code -- Adam]

- 工單：`doc/audit/2026-09-25_p4-heartbeat/TICKET-P4-heartbeat.md` §1 段 S。本文件是段 S 的報告，也是段 W 與 Adam 日後決定對外怎麼講的輸入。**內部稽核文件，不是對外宣稱。**
- 撰寫：opus worker，2026-09-26。本文件作者沒有碰 lab，只讀 raw。
  - 第一、二版（分支 `docs/p4-hb-spike-0926`，最後 `005dc698`，併入 trunk `318e6391`）報告 run 1–2，第二版依 opus 判官對 `4820862b` 的裁決修訂（`judge/judge-HBSPIKEDOC-4820862b.md`）。
  - **第三版（本版，分支 `docs/p4-hb-spike-dephase-0926`，base trunk `094f417f`）加入去相位鎖的 run 3–4**：§2.4、§2.5 是新的；§1、§5 依它們改寫。run 1–2 的數字一個都沒改，留作相位鎖住的歷史紀錄。
- 標記：
  - **OBSERVED**＝四次 live run 的 raw 裡讀得到的值與字句，附路徑；也包括我直接從 raw 算出的彙總（min／median／max、合計、差值），算法寫在旁邊。
  - **CHECKED**＝本文件作者在 worktree 離線跑過的核對（sha256 比對、`git diff`、重算）。是「跑過」，但不是 lab 上的量測。
  - **INFERRED**＝由常數、讀碼或對 OBSERVED 數字做算術推得，**沒有執行過**。
  - **READ**＝讀程式或先前文件所得，這四次 run 沒有驗證。
  - 跑過的與讀過未執行的分表，不混。
  - 數字精度：min／max 照 raw 寫三位小數；median 一律寫精確值（四位小數）。
- **行號**：`spike/S_heartbeat_spike.sh` 與 `spike/hb_watch.py` 在 run 2 與 run 3 之間改過。§2.1–2.3、§3、§4 的行號指 `580767a8`（run 1–2 跑的版本）；§2.4 的行號指 `094f417f`（run 3–4 跑的版本）。其他被引用的檔在兩個 commit 之間沒變（CHECKED：`git diff 580767a8 094f417f` 只動 spike 的三支檔與本文件）。
- **raw 的存檔**：
  - run 1–2 的 raw 已提交到 `audit-raw` 分支 commit `1fafa3a0`，而且是公開的：orchestrator 做過未認證的 https 檢查（`judge/public-verify-20260926T063944Z.log`：兩個 P4 repo 以不帶憑證的 `git ls-remote` 都讀回 `audit-raw` `1fafa3a0`，不帶憑證的 `curl` `/tree/audit-raw` 都回 HTTP 200）。CHECKED：352 個 run 檔與下列 log 的 sha256 與工作副本相同。
  - run 3–4 的 raw 目前只在主 checkout。CHECKED：本機看得到的 `audit-raw` ref（`1fafa3a0`）還沒有這兩個目錄與它們的 log。歸檔由 orchestrator 做。
- 路徑縮寫（全部 repo-relative）：
  - `R1/`＝`doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T023021Z_S_heartbeat/`
  - `R2/`＝`doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T052148Z_S_heartbeat/`
  - `R3/`＝`doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T085020Z_S_heartbeat/`（sweep）
  - `R4/`＝`doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T085506Z_S_heartbeat/`（random）
  - `judge/`＝`scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/`
  - `log1`／`log1c`／`log2`／`log3`／`log4`＝`judge/` 底下的 `spike-S-detect-20260926T023021Z.log`／`spike-S-detect-cleanup.log`／`spike-S-all-20260926T052148Z.log`／`spike-S-dephase-sweep-20260926T085020Z.log`／`spike-S-dephase-random-20260926T085020Z.log`（run 4 的 log 檔名是 orchestrator 取的，沿用 run 3 的時戳；它的 raw 目錄是 `085506Z`）
  - `spike/`＝`doc/audit/2026-09-25_p4-heartbeat/spike/`
  - `HBR8`＝`scratch/overnight-2026-09-05/hunt-0911/fix/P4-HBR8-SUMMARY.md`（第 8 輪 worker 交件）

## 0. 四次 live run

| | run 1 | run 2 | run 3 | run 4 |
|---|---|---|---|---|
| 時間（+08，09-26） | 10:30:21–10:34:00（`log1:2`、`:115`） | 13:21:48–13:38:41（`log2:2`、`:223`） | 16:50:20–16:55:05（`log3:2`、`:149`） | 16:55:06–17:03:16（`log4:2`、`:178`） |
| trunk | `4bc1201b` | `580767a8` | `094f417f` | `094f417f` |
| 參數 | `PART=detect CYCLES=10` | `PART=all`（detect 10＋census 26 臂） | `PART=detect PHASE=sweep CYCLES=10`，controls on | `PART=detect PHASE=random CYCLES=20`，seed 1968294680，controls on |
| 剪線相位 | 被迴圈鎖在 φ≈0.6–0.8 s | 同左 | sweep：剪線在最後一幀之後 0.050–4.850 s 開始 | random：剪前等 U[0, 5) |
| 偵測 | 10/10、10/10 | 10/10、10/10 | 10/10、10/10，相位覆蓋 | 20/20、20/20，相位覆蓋 |
| 結果 | **FAIL**：teardown（§4.1），量測本身過了（`log1:114`） | **PASS**（`log2:222`） | **PASS**（`log3:148`） | **PASS**（`log4:177`） |

- 四次都是 `NDT_OWNER=orch-0926`（`log*:2`）。run 2–4 帶 `env -u CLAIM_MINUTES -u CENSUS_EVEN_IF_RED -u FAULTS_TC -u NDT_MEASURING`，run 3–4 另帶 `-u HB_WATCH_SIM -u PHASE_SEED`；run 1 沒有 `env -u`。
- run 3 記下的 seed 是 2772311660，但 sweep 用預設偏移（`sweep=default`），沒有用到 seed（`R3/01_binaries.txt`、`R3/19_phase_plan.tsv`；READ：`094f417f` 的 `hb_watch.py:557-580`）。
- run 3–4 的參數：`controls=1 nocut=20 margin=0.05`（`R3/01_binaries.txt`、`R4/01_binaries.txt`）。

## 1. 結論

1. **偵測延遲，相位覆蓋整個 period（OBSERVED，run 3–4，共 30 cycles）**
   - **覆蓋**：30 次剪線、30 次復原全部判到。
     - 剪線相位 φ（t0 − 這條線最後一幀被聽到）：run 3 是 0.131–4.934 s，run 4 是 0.220–4.384 s。圓周上最大間隙 0.551／1.170 s。
     - 復原相位：0.135–4.924／0.012–4.930 s，最大間隙 0.548／1.241 s。
     - 兩次 run 的覆蓋判定都是 covers。
   - **報告層級判不通**：規則成立的瞬間 `down_rule_s` 是 10.066–14.869 s。spike 的讀者輪詢再加 0.009–0.099 s（`down_s` 10.077–14.904 s）。
   - **最壞相位實測**：φ＝0.131 s（run 3 cycle 1）→ `down_rule_s` 14.869 s、`down_s` 14.904 s。現行剪法兩端依序下 tc，`cut_tc_s` 0.078–0.108 s，所以 φ 再小就不是「兩端都斷」；15 s 只是極限（INFERRED）。
   - **復原**：daemon 接收層級 `up_s` 0.070–4.988 s；報告層級 `up_rpt_s` 0.571–5.488 s。
   - **報告延遲實測**：`up_rpt_s − up_s` 在 30 個 cycle 裡都是 0.500–0.501 s，取代第二版推得的「約 0.5 s」。
2. **對工單 ≤20 s（INFERRED）：仍然不是保證。**
   - W 層級＝報告層級＋最多一次 watchdog 等待（≤5 s）＋pass 耗時＋讀檔、`_notify_link` 的 HTTP、kernel 更新圖。
   - 實測最壞相位下，前兩項是 14.869＋5＝**19.869 s**，只剩 0.131 s 給後面那些沒量過的時間。這個餘裕恰好等於 φ（因為 `down_rule_s`＝15−φ），所以 φ 能小到多少，就決定最壞情況。φ→0 的極限是 20 s。
   - 復原：5.488＋5＝10.488 s，再加 pass 耗時與 kernel；只看常數 ≤10.5 s。
   - 自家 fabric 用同一條規則、同一組常數（`topology_manager.py:411` 只寫「15 to 20 s」；「從最後一次 beacon 起算」是我的讀法），所以**剪線方向**兩邊是同一性質。復原方向不同：心跳的「聽到」要經過報告，晚 0.500–0.501 s（OBSERVED）才讓 proxy 看得到。
3. **兩個對照（OBSERVED，run 3–4 各一次）**
   - (a) 不剪線 20.1 s：201 次讀取裡沒有任何方向判不通；讀者看到的最長沉默 5.494／5.490 s，規則要 >15 s。
   - (b) 只在 s1-eth3 一端下 netem：只有 `1:3>3:1`（從 s1-eth3 送出的方向）判不通，13.085／13.081 s；反方向 `3:1>1:3` 一直被聽到，最長沉默 5.470／5.458 s。
   - 所以**單端 egress netem 只斷一個方向**。第 8 輪把這點列為 INFERRED（`HBR8:117`；`judge/judge-HBR8-3a724b87.md:12`），現在是 OBSERVED。
4. **run 1–2 是相位鎖住的歷史紀錄**（§2.2–2.3）：它們只量到 φ≈0.6–0.8 s 這一點。run 3–4 在同一相位的值與它們一致（run 3 cycle 2，φ 0.666 s → `down_s` 14.383 s；run 4 cycle 15，φ 0.578 s → 14.477 s；run 1–2 的 cycle 2–10 是 14.197–14.382 s）。所以 run 1–2 沒有被推翻，而是被涵蓋。
5. **副作用普查（OBSERVED，run 2）**：26 臂裡有 20 臂真的送了心跳，一共 78 次主機 sniff、每次 20 s。
   - **沒有任何主機收到心跳幀**（依 ethertype 或 payload 都沒有）。daemon 計數 `forwarded_to_hosts`／`forwarded_between_switches`／`misdelivered`／`foreign_frames` 在 20 臂全部是 0。
   - 所以**沒有觸發段 S 對裁決 4 的操作化停止條件**（心跳幀到了主機，或 `forwarded_to_hosts>0`）。
   - 裁決 4 原文更寬：「任何封包因心跳而到達主機、任何 06 臂判定改變」。前半要把主機收到的 372 幀非心跳幀定性，並有心跳關閉的對照窗，這次都沒有；後半留給 H5。
   - 另外 4 臂（calc、multicast 各兩臂）是單交換機，一幀都沒送。2 臂（basic_tunnel/skeleton、flowcache/skeleton）沒建成，是設計上的紅。
   - run 3–4 的 detect 也各有 side effects 全 0 的紀錄（§2.4.6）。
6. **沒涵蓋到的（§2.5、§3.3）**：
   - proxy、watchdog、kernel 不在量測迴路裡。W 層級的數字全是推得的。
   - 幀進了哪張表、哪個計數器，沒觀測。
   - 3 個 external 臂的 fabric 表是空的，練習自己的 controller 沒起。
   - 普查期間沒有流量。
   - 兩個副作用偵測器（主機 sniff、daemon 計數）都沒有 live 陽性對照。
   - 06 各臂判定會不會變，留給 H5。
7. **spike 本身的缺陷**：run 1 的 teardown 被 ndt 自己的 measuring 守衛拒絕，spike 仍然 release，fabric 在無人 claim 下約 34 s（至少 33 s）。第 7／7b 輪已修，run 2–4 在 live 上走過修好的路（§4）。

## 2. 偵測延遲

### 2.1 run 1–2 的量法（READ：`580767a8` 的 `spike/S_heartbeat_spike.sh` `detect()` :520-579、`spike/hb_watch.py`）

run 3–4 沿用同一個 fabric、同一條線、同一條規則，改動見 §2.4.1。§2.1–2.3 裡的 `R*/` 只指 `R1/`、`R2/`。

- **fabric 與心跳**
  - pod-topo `--app basic`（basic/solution，照 06 的方式轉包）。package 在 4 台交換機上有 20 條 entries；NDTwin 自己「discovered no links and installed no routes」（`log2:46-48`）。
  - 心跳：4 條鏈路 → 8 個方向，4 個 host-facing 介面只聽不送（`R2/11_hb_start.txt`）。
- **剪線**：out-of-band `tc qdisc add … netem loss 100%`，走 `sudo -n mnexec -a 1 tc`（`R*/00_tc_grant.txt`），同時下在 spine 線的兩端 `s1-eth3`、`s3-eth1`。沒有走 kernel 的 `inject_link_failure`。
- **每個 cycle 的六步**
  1. 先確認這條線兩向在最近 period＋1 s 內都聽得到（:547）。
  2. `t0a`→剪兩端→`t0`＝tc 返回的時刻（:550、:555）。`cut_tc_s = t0 − t0a`，包含找掛點與兩次 tc。
  3. `down_s`（**報告層級**）：每 0.1 s 讀一次 `/run/ndtwin-lab/heartbeat.json`（`hb_watch.py:199-212`），取兩向都滿足 proxy 規則 `now − last_heard_mono > LINK_BEACON_TIMEOUT_S` 的第一次輪詢，減去 `t0`（`hb_watch.py:78`）。這是**輪詢時刻**，解析度約 0.1 s 加 process 啟動時間。
  4. `collateral`：同一時刻另外 6 個方向仍在 15 s 內被聽到（:557、`hb_watch.py:99`）。
  5. 拿掉 netem，`t1`＝返回時刻。`up_s`（**daemon 接收層級**）＝`max(兩向在 t1 之後的 last_heard_mono) − t1`（:561、`hb_watch.py:185-196`）。它用的是 daemon 的接收時戳，不是 spike 讀到報告的時刻，也不是報告寫出的時刻。
  6. `netem_left`：兩端還有沒有 netem。
- **報告寫出的時刻**（READ：`tools/test_workflow/ndtwin-lab:764-765` `REPORT_MIN_INTERVAL_S = 0.5`、:1335-1344）：每輪送出時寫一次；聽到東西之後，距上次寫入滿 0.5 s 才再寫。因為送出與聽到幾乎同時，報告要到聽到之後約 0.5 s 才反映它。
  - OBSERVED：兩次 run 的 `R*/12_report_first.json` 都寫在最後一次被聽到之後 0.5006 s；普查 18 臂的快照是 0.500–0.501 s（§3.2）。run 3–4 逐 cycle 實測是 0.500–0.501 s（§2.4.2）。
  - 這只影響「聽到了」何時出現在報告上，所以 `up_s` 要加上它才是報告層級。`down_s` 不受影響：剪線之後沒有新的聽到，規則只看既有時戳與輪詢時刻。
- **時鐘**：全部是 CLOCK_MONOTONIC（`hb_watch.py now` 與 daemon 的 `*_mono`）。
- **常數**：執行期從 `p4_proxy/proxy_agent/topology_manager.py` import，並 `env -u NDTWIN_P4_BEACON_S`。兩次 run 都是 `beacon=5 timeout=15 watchdog=5`（`R*/01_binaries.txt`、`log*:9`）。daemon 報告的 `period_s` 也是 5。
- **量的是報告層級（down）與 daemon 接收層級（up）**：proxy 本身沒有讀報告（段 W 還沒實作），kernel 也不在路徑上。
- **兩次 run 可以直接比**（CHECKED：我在 worktree 對兩個 commit 做 `git show`＋diff）：
  - `detect()`、`cut_link()` 在 `4bc1201b` 與 `580767a8` 逐字相同。
  - `hb_watch.py`、`hb_sniff.py`、`census_prepare.py` 的 sha256 相同（`R*/01_binaries.txt`）。
  - `nd_down()` 只多了一行 `retract_measuring`，在所有 cycles 之後才執行。

### 2.2 run 1–2 OBSERVED：相位鎖住的歷史紀錄（`R1/20_cycles.tsv`、`R2/20_cycles.tsv`；兩次 run 的 `collateral` 全是 `OK`，`netem_left` 全是 `no`）

`up_s` 是 daemon 接收層級（§2.1 第 5 步）。

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

min／median／max 是我用 python `statistics` 從上面兩個 tsv 重算的，兩位小數與 `R*/22_summary.txt` 一致。min／max 是 raw 值（三位小數）；median 一律寫精確值（四位小數）。**全部是同一個相位鎖下的值（§2.3），不是分布。**

| | run 1（n=10） | run 2（n=10） | 合併（n=20） |
|---|---|---|---|
| down_s（報告層級） | 13.275／14.2905／14.382 | 13.298／14.3025／14.311 | 13.275／14.2935／14.382 |
| down_s，只看 cycle 2–10 | 14.197／14.2910／14.382 | 14.219／14.3030／14.311 | 14.197／14.2965／14.382（n=18） |
| up_s（daemon 接收層級） | 4.819／4.8525／4.910 | 4.813／4.8675／4.909 | 4.813／4.8635／4.910 |
| cut_tc_s | 0.070／0.0715／0.104 | 0.063／0.0730／0.080 | 0.063／0.0715／0.104 |

同一批 raw 的其他 OBSERVED：
- **qdisc 全樹**：兩次 run 都是 `qdisc state unchanged (32 lines)`（`R*/23_qdisc.diff`）。
- **起跑時**：心跳一起來 8/8 方向都聽得到（`log*:58`、`R*/12_report_first.json`）。那份報告寫在最後一次被聽到之後 0.5006 s。
- **detect 結束時的報告**（`R*/24_report_last.json`，兩次 run 相同）：
  - 8 個方向各送 42 幀，每次 run 共 336 幀，`send_errors` 0。
  - 被剪兩向各聽到 12，也就是各丟 30、兩向共 60 幀被 netem 丟；其他 6 向各聽到 42。一共 276 幀被對端 veth 收到。
  - `side_effects` 四項全 0。
  - INFERRED：這 276 幀都進了對端交換機的 pipeline，因為 bmv2 在同一條 veth 上收包。
- **run 1 daemon 的最終報告**（pid 244126，stopped by SIGTERM）：留在 `R2/00_heartbeat_status_before.txt`，送 42／聽 12 與 42，side effects 全 0，和上一條一致。
- **每次剪線的快照**（`R*/21_report_cut_<i>.json`）：
  - 被剪那條線最後一次被聽到，都落在 daemon 啟動後 5.00x＋20(i−1) s。
  - 快照的寫入時刻在它之後 14.997–15.004 s。

### 2.3 run 1–2 的相位鎖（INFERRED，除非另標）

**相位鎖成立的證據：**
- **OBSERVED 的集中度**：兩次 run 的 cycle 2–10，18 個 `down_s` 都落在 14.197–14.382 s，寬 0.185 s。如果剪線相位是自由的，`down_s` 應散在 (10, 15]，寬 5 s。run 3–4 證實了這一點：相位自由時 `down_s` 是 10.077–14.904 s（§2.4）。
- **READ 的迴圈碼**（`580767a8`）：
  - cycle 2–10 的剪線，緊跟在前一個 cycle 復原後的 `wait-heard` 返回之後（:561 → :547-555，中間是一串固定的指令）。而 `wait-heard` 返回的時刻，綁在「送出後約 0.5 s 報告重寫」再加 ≤0.1 s 輪詢。所以 φ≈0.5＋輪詢＋指令耗時，對上 15−`down_s`＝0.62–0.80 s（另加 ≤0.1 s 輪詢）。
  - cycle 1 前面多一個 `sleep 1`（:536），φ≈15−13.3≈1.7 s。
  - 復原也被鎖住：15 s 正好是 3 個 period，所以判不通的那一刻，緊接在一次被剪掉的送出之後；復原立刻跟上（:558-560），所以復原總在某次送出之後約 0.1–0.2 s（5−`up_s`），`up_s` 總是接近 5 s。
- **兩項沒有鑑別力、不拿來當證據**：每個 cycle 丟 3 幀（42−12＝30＝10×3）、第 i 份快照寫在第 20·i s。φ 在 (0, 5) 之間任何值都會得到一樣的結果。

**run 1–2 的相位（由 raw 倒推）：**

| 項目 | 值 | 怎麼來的 |
|---|---|---|
| 剪線相位 φ | cycle 2–10：0.62–0.80 s；cycle 1：約 1.7 s | 15−`down_s`，另加 ≤0.1 s 輪詢。run 1–2 的 tsv 只有差值，沒有絕對時戳，所以只能倒推 |
| 復原相位 | 送出後約 0.1–0.2 s | 5−`up_s` |
| 從第一次呼叫 tc 起算的上界 | 每個 cycle `down_s＋cut_tc_s` ≤ 14.453 s（run 1 cycle 3） | 第一端的 netem 生效時刻落在 `(t0a, t0)` 之間 |

第二版在這一節的 W 層級推論表，已由 §2.5 以 run 3–4 的實量取代。

**run 1 對 run 2 的對帳（OBSERVED 差值）**：
- 量測碼相同（§2.1）。
- 兩次的 min／median／max 相差都不到 0.08 s（`down_s` 最大 14.382 對 14.311；`up_s` 最大 4.910 對 4.909）。
- 逐 cycle 比，`down_s` 最多差 0.113 s（cycle 9：14.197 對 14.310），`up_s` 最多差 0.081 s（cycle 10）。
- 兩次落在同一個相位，所以可以比對、互不推翻。但它們是**同一個相位的重複**，不是兩個獨立的分布樣本。

### 2.4 run 3–4：去相位鎖（OBSERVED，除非另標）

orchestrator 在第二版的裁決之後決定補這一輪（`judge/judge-HBSPIKEDOC-4820862b.md` :28-29、:33-40）。spike 第 8 輪（`fix/hb-spike-r8-0926`，併入 trunk `094f417f`）實作，判官 MERGE（`judge/judge-HBR8-3a724b87.md:6`），orchestrator 在 09-26 16:50 起跑兩次 live。

#### 2.4.1 量法的改變（READ：`094f417f` 的 `spike/S_heartbeat_spike.sh` :568-624、:638-666、:668-769；`spike/hb_watch.py`）

- **fabric、線、規則、常數都與 run 1–2 相同**：pod-topo `--app basic`、剪 `s1-eth3`／`s3-eth1` 兩端、proxy 規則 `now − last_heard_mono > 15`、常數由 proxy import（`R3/01_binaries.txt`、`R4/01_binaries.txt` 都是 `beacon=5 timeout=15 watchdog=5`）。起跑時另確認心跳的 `period_s` 等於 proxy 的 `LLDP_BEACON_INTERVAL_S`（`log3:60`、`log4:60`）。
- **剪線與復原前都先等**（`hb_watch.py:704` `phase_wait`），照 `19_phase_plan.tsv`：
  - `PHASE=sweep`：剪線**開始**的時刻落在報告裡最新一幀 heard 之後的預定偏移；預設 10 個點，0.050、0.583、…、4.850 s；復原的偏移反序（`R3/19_phase_plan.tsv`）。
  - `PHASE=random`：從剪前檢查看到兩向 heard 起，等 U[0, 5)；復原前也一樣（`R4/19_phase_plan.tsv`，seed 1968294680）。
- **相位從報告實量**：`cut_phi_s = t0 − cut_lh_mono`，也就是規則看到的相位；`restore_phi_s = (t1 − 復原前最新的 heard) mod 5`。t0a、t0、t1a、t1、`cut_lh_mono` 等都以 CLOCK_MONOTONIC 絕對值寫進 `20_cycles.tsv`。這就是第二版 §2.4 要求的做法。
- **兩個層級都記**：
  - 剪線：`down_rule_s`＝最後一幀 heard＋15 − t0，規則成立的瞬間；`down_s` 是 spike 輪詢到的時刻。
  - 復原：`up_s` 是 daemon 接收層級；`up_rpt_s` 是**第一份顯示兩向都 heard 的報告**的 `written_mono` − t1，也就是報告層級。
  - 每次輪詢都寫進 `21_polls_<cycle>.tsv`。
- **兩個對照**在 cycles 之前跑（`detect_controls`，:638-666）：(a) 不剪線 `NOCUT_S`＝20 s；(b) 只在 `s1-eth3` 一端下 netem。
- **覆蓋判定**（`hb_watch.py:273-281`、:326）：從 8 個 cycle 起，相位在圓周上的最大間隙 ≥ 0.6×period（3.00 s）就 FAIL；sweep 最小 φ > 0.25 s 也 FAIL。
- 第 8 輪的自測用模擬 daemon（`hb_watch.py` 的 `Sim`）；live 時 `HB_WATCH_SIM` 在 claim 前就被拒（`HBR8:47`），兩次 run 的起跑指令也把它 `env -u` 掉（`log3:2`、`log4:2`）。

#### 2.4.2 每 run 的彙總（`R3/20_cycles.tsv`、`R4/20_cycles.tsv`，我重算）

兩次 run 的 `collateral` 全是 `OK`、`netem_left` 全是 `no`；`cut_phi_src` 全是 `heard`、`restore_phi_src` 全是 `heard@plan`。

CHECKED：每一列都用 raw 的絕對時戳重算 `cut_phi_s`（t0 − `cut_lh_mono`）、`down_rule_s`（`cut_lh_mono`＋15 − t0）、`cut_tc_s`（t0 − t0a）、`up_s`（`up_lh_mono` − t1）、`restore_phi_s`、`restore_tc_s`，30 列全部在 0.0015 s 內吻合。

| 量（min／median／max，s） | run 3 sweep（n=10） | run 4 random（n=20） |
|---|---|---|
| 剪線相位 `cut_phi_s` | 0.131／2.5390／4.934 | 0.220／1.1525／4.384 |
| 規則成立 `down_rule_s`（報告層級） | 10.066／12.4610／14.869 | 10.616／13.8475／14.780 |
| spike 輪詢到 `down_s` | 10.077／12.5260／14.904 | 10.668／13.9300／14.791 |
| 輪詢延遲 `down_s − down_rule_s` | 0.009／0.0420／0.084 | 0.009／0.0545／0.099 |
| 復原相位 `restore_phi_s` | 0.135／2.5275／4.924 | 0.012／3.1440／4.930 |
| daemon 接收 `up_s` | 0.075／2.4725／4.864 | 0.070／1.8565／4.988 |
| 報告層級 `up_rpt_s` | 0.575／2.9730／5.364 | 0.571／2.3565／5.488 |
| **報告延遲實測** `up_rpt_s − up_s` | 0.500／0.5000／0.501 | 0.500／0.5000／0.501 |
| 讀者看到那份報告 `up_poll_s − up_rpt_s` | 0.002／0.0415／0.100 | 0.017／0.0540／0.099 |
| 復原後下一輪有被聽到 `up_s＋restore_phi_s−5` | −0.001／0.0000／0.001 | −0.005／0.0000／0.002 |
| 剪線耗時 `cut_tc_s` | 0.082／0.0870／0.108 | 0.078／0.0860／0.096 |
| 其中 A 端／B 端（範圍） | 0.022–0.027／0.021–0.028 | 0.022–0.029／0.019–0.028 |
| 復原耗時 `restore_tc_s` | 0.074／0.0840／0.092 | 0.072／0.0790／0.092 |

說明：
- 每個 cycle 的 φ 都 <5 s，而且判不通的那份報告裡，兩向的最後一幀就是剪線前那一幀：剪線之後沒有任何一幀被聽到。所以 `down_rule_s`＝15−φ 在 30 列都成立。這是定義上的恆等式，前提是剪線有效，**不是另一個發現**。
- `up_s＋restore_phi_s−5` 接近 0 表示復原之後的下一輪就被聽到了：復原在下一次送出前生效，30 列都是。
- 輪詢延遲只屬於 spike 的讀法（每 0.1 s 讀一次）。proxy 的 watchdog 有自己的節奏（§2.5）。

#### 2.4.3 分箱（1 s 一箱；min／median／max，s；我重算，兩位小數與 `R*/22_summary.txt` 一致）

剪線，依 `cut_phi_s`：

| run | 箱 | n | φ 範圍 | `down_rule_s` | `down_s` |
|---|---|---|---|---|---|
| 3 | [0, 1) | 2 | 0.131–0.666 | 14.334／14.6015／14.869 | 14.383／14.6435／14.904 |
| 3 | [1, 2) | 2 | 1.206–1.738 | 13.262／13.5280／13.794 | 13.293／13.5485／13.804 |
| 3 | [2, 3) | 2 | 2.277–2.801 | 12.199／12.4610／12.723 | 12.277／12.5260／12.775 |
| 3 | [3, 4) | 2 | 3.340–3.891 | 11.109／11.3845／11.660 | 11.172／11.4205／11.669 |
| 3 | [4, 5) | 2 | 4.403–4.934 | 10.066／10.3315／10.597 | 10.077／10.3790／10.681 |
| 4 | [0, 1) | 6 | 0.220–0.982 | 14.018／14.2520／14.780 | 14.079／14.3290／14.791 |
| 4 | [1, 2) | 6 | 1.028–1.405 | 13.595／13.9185／13.972 | 13.683／13.9815／13.989 |
| 4 | [2, 3) | 2 | 2.575–2.832 | 12.168／12.2965／12.425 | 12.180／12.3335／12.487 |
| 4 | [3, 4) | 4 | 3.214–3.997 | 11.003／11.2895／11.786 | 11.069／11.3215／11.872 |
| 4 | [4, 5) | 2 | 4.288–4.384 | 10.616／10.6640／10.712 | 10.668／10.7200／10.772 |

復原，依 `restore_phi_s`：

| run | 箱 | n | `up_s`（daemon 接收） | `up_rpt_s`（報告層級） |
|---|---|---|---|---|
| 3 | [0, 1) | 2 | 4.339／4.6015／4.864 | 4.840／5.1020／5.364 |
| 3 | [1, 2) | 2 | 3.259／3.5250／3.791 | 3.759／4.0250／4.291 |
| 3 | [2, 3) | 2 | 2.203／2.4725／2.742 | 2.703／2.9730／3.243 |
| 3 | [3, 4) | 2 | 1.130／1.3965／1.663 | 1.630／1.8965／2.163 |
| 3 | [4, 5) | 2 | 0.075／0.3375／0.600 | 0.575／0.8375／1.100 |
| 4 | [0, 1) | 6 | 4.002／4.4945／4.988 | 4.502／4.9950／5.488 |
| 4 | [1, 2) | 3 | 3.163／3.6830／3.892 | 3.663／4.1830／4.393 |
| 4 | [2, 3) | 0 | — | — |
| 4 | [3, 4) | 4 | 1.040／1.4920／1.923 | 1.540／1.9920／2.423 |
| 4 | [4, 5) | 7 | 0.070／0.2060／0.958 | 0.571／0.7060／1.458 |

run 4 的復原在 [2, 3) 箱沒有樣本；它的覆蓋判定看的是最大間隙（1.241 s），不是每箱都要有。

#### 2.4.4 最壞相位、覆蓋判定、sweep 精度

- **最小剪線相位**：run 3 是 0.131 s（cycle 1）→ `down_rule_s` 14.869 s、`down_s` 14.904 s。run 4 是 0.220 s（cycle 7）→ 14.780／14.789 s。run 4 的 `down_s` 最大值是 cycle 8（φ 0.238 s，14.791 s），比 cycle 7 大，差在輪詢延遲。
- **報告層級復原最大值**：5.488 s（run 4 cycle 8，復原相位 0.012 s，`up_s` 4.988 s）。
- **覆蓋**（`R*/22_summary.txt`；CHECKED：我從 tsv 重算最大圓周間隙，數字相同）：
  - run 3：剪線 0.551 s、復原 0.548 s。
  - run 4：剪線 1.170 s、復原 1.241 s。
  - 都小於 3.00 s ⇒ covers。
- **sweep 精度**：`cut_phi_s − cut_tc_s − cut_plan` 在 −0.001 到 0.000 s 之間（CHECKED）。第一個偏移 0.050 s 加上 `cut_tc_s` 0.082 s，就是 φ 0.131 s。第 8 輪判官原本預期 live 會有 0.02–0.06 s 的系統性偏差（`judge/judge-HBR8-3a724b87.md:11`），實際沒有。
- **為什麼到不了 φ→0（INFERRED）**：兩端依序下 tc，第二端最晚在 `cut_tc_s` 之後才生效。φ 比 `cut_tc_s` 小時，剪線開始時的那一輪可能已經送出、或還有一端沒斷。run 3 的 sweep 從 0.050 s 開始，所以量到的最小 φ 是 0.131 s。

#### 2.4.5 兩個對照（`R3/18_controls.tsv`、`R4/18_controls.tsv`；CHECKED：我從 `18_polls_{a,b}.tsv` 重算沉默長度，數字相同）

| 對照 | run 3 | run 4 | 判定 |
|---|---|---|---|
| (a) 不剪線 | 視窗 20.1 s、201/201 次讀取、沒有方向判不通；8 個方向的最長沉默都是 5.494 s | 20.1 s、201/201、5.490 s | 兩次都 OK |
| (b) 只剪 `s1-eth3` | 只有 `1:3>3:1` 判不通，13.085 s；`3:1>1:3` 最長沉默 5.470 s（19.1 s 視窗、判不通後再看 6 s）；`cut_tc_s` 0.023 s；復原後 3.865 s 重新聽到 | 13.081 s；5.458 s；0.025 s；3.883 s | 兩次都 OK |

- (b) 當下的報告（`R*/17_report_single_end.json`）：`1:3>3:1` 送 10 聽 6，`3:1>1:3` 送 10 聽 10。視窗結束時，`1:3>3:1` 的沉默已到 20.973／20.959 s（`18_polls_b.tsv`）。
- **這兩個對照補上了什麼**：
  - (a) 是偵測的陰性對照：不剪線時，讀者看到的最長沉默是 period＋報告延遲（約 5.5 s），離 15 s 很遠。
  - (b) 把「egress netem 只擋從該介面送出的幀，進入該介面的幀照樣被聽到」從 INFERRED 變成 OBSERVED（第 8 輪 `HBR8:117`；判官 note 4）。READ 的依據是 daemon 從不設 `PACKET_QDISC_BYPASS`（`tools/test_workflow/ndtwin-lab:1229`；`HBR8:113`）。
- 這些對照都是**報告層級**的。kernel 層級的陰性對照是 H2（§5.2）。

#### 2.4.6 其他 OBSERVED

- **qdisc 全樹**：兩次 run 都是 `qdisc state unchanged (32 lines)`（`R*/23_qdisc.diff`）。
- **起跑時**：8/8 方向都聽得到（`log3:59`、`log4:59`）。`R3/12_report_first.json`、`R4/12_report_first.json` 寫在最後一次被聽到之後 0.50033／0.50057 s。
- **detect 結束時的報告**（`R*/24_report_last.json`）：
  - run 3：8 個方向各送 54 幀，共 432 幀，聽到 366；`send_errors` 0。
  - run 4：各送 95 幀，共 760 幀，聽到 636。
  - 被剪那條線兩向聽到的數量差 4（run 3 是 19 對 23，run 4 是 31 對 35），正好是對照 (b) 只斷 `1:3>3:1` 時丟的 4 幀（`17_report_single_end.json`：送 10 聽 6）。
  - `side_effects` 四項全 0。
  - run 3 daemon 的最終報告也留在 `R4/00_heartbeat_status_before.txt`（送 54、聽 19 與 23、side effects 全 0），與上面一致。
- **teardown**：兩次 run 都在 detect 收尾時撤回 `measuring=` 再 down（`log3:128-130`、`log4:157-159`），`26_down.txt` 以 verify clean 收尾；收尾的 down 回 3 並被當成預期，然後 release（`log3:135-145`、`log4:164-174`）。

#### 2.4.7 與 run 1–2 對帳

- **可比對、不推翻**：run 1–2 只量到 φ≈0.6–0.8 s。run 3–4 在同一相位的值落在同一處（run 3 cycle 2，φ 0.666 s → `down_s` 14.383 s；run 4 cycle 15，φ 0.578 s → 14.477 s）。run 1–2 的復原在送出後約 0.1–0.2 s，`up_s` 4.813–4.910 s；run 3 cycle 10（復原相位 0.135 s）是 4.864 s。
- **更新**：
  - 第二版推得的報告延遲「約 0.5 s」，現在逐 cycle 實測是 0.500–0.501 s。
  - 第二版的「最壞相位報告層級趨近 15 s」，現在實測到 φ＝0.131 s 時 14.869 s（規則）／14.904 s（spike 輪詢）。
  - 第二版的「≤20 s 不是保證」維持不變（§2.5）。

### 2.5 推得的 W 層級（INFERRED；報告層級數字取自 §2.4）

| 項目 | 值 | 怎麼來的 |
|---|---|---|
| 剪線 → proxy 判定，實測最壞相位 | ≤ 14.869＋5＝**19.869 s**，另加 pass 耗時、讀檔、`_notify_link` 的 HTTP、kernel 更新圖（都沒量） | proxy 的 watchdog 自己讀報告，不經 spike 的 0.1 s 輪詢，所以用 `down_rule_s`；watchdog 最多再等一整個間隔 5 s |
| 同上，φ→0 的極限 | 20 s＋同上 | 現行兩步剪法達不到（§2.4.4） |
| 同上，run 4 的均勻相位 | 報告層級 10.616–14.780 s，再加 (0, 5] 的 watchdog 等待與同上各項 | 分布見 §2.4.3 |
| 復原 → proxy 判定 | ≤ 5.488＋5＝**10.488 s**，另加 pass 耗時、讀檔、kernel；只看常數 ≤ 5.5＋5＝10.5 s | 報告層級 `up_rpt_s`＋一次 watchdog |
| 單端故障 | 只有一個方向判不通（對照 (b)，OBSERVED）⇒ W 會收到單向的 down | H1 要求的「兩向 `is_up:false`」只在兩端都斷時成立 |
| 心跳證明的是什麼 | 那條 veth，不是交換機 | daemon 在對端 veth 上、在交換機之前就讀到幀（READ：`tools/test_workflow/ndtwin-lab` :657-693；`P4-HB-SUMMARY.md` §H.7 第 9 點） |

**watchdog 的附加量可能不均勻（前兩點 READ，結論 INFERRED）：**
- proxy 的 watchdog 是先 `wait(5)` 再跑一次 pass（`topology_manager.py:2050-2053`），所以它的週期是 5 s 加上 pass 耗時。
- daemon 的送出排程是 `next_round += PERIOD_S`，從啟動時刻起算、不漂移（`ndtwin-lab:1313`、:1331）；只有某輪遲到時才從當下重設（:1332-1333）。
- 所以兩者的相對相位每次 pass 漂移一個 pass 耗時，累積漂移就是各次 pass 耗時的總和。pass 耗時沒有量過；有轉態的 pass 還要跑 `_notify_link` 的 HTTP（在 `check_link_beacons` 裡）、`install_initial_routes` 與 `push_destination_paths`（READ：`topology_manager.py:2065-2102`）。
- **如果** pass 耗時很小，同一個 run 裡的 n 個 cycle 看到的 watchdog 附加量就大致固定，不會均勻取樣 (0, 5]；如果轉態 pass 很慢，漂移就會變大。兩種情況都要靠記錄 watchdog 相位才看得出來。
- 所以最壞組合是：剪線 φ 很小，**而且** watchdog pass 剛好在規則成立前一刻跑過。這時只剩約 0.13 s（20 − 19.869）給 pass 耗時、HTTP 與 kernel。它們夠不夠，只有 H1 量得出來。

## 3. 副作用普查（run 2）

### 3.1 量法（READ：`spike/S_heartbeat_spike.sh` `census()` :611-699、`spike/hb_sniff.py`、`spike/census_prepare.py`、helper 心跳程式）

- **每一臂的流程**
  1. 照 06 的方式建（`census_prepare.py` import `drive_exercise.py`）。
  2. `ndt up p4 --app`。
  3. `heartbeat start`（:633）。
  4. 等報告出現「running 且 pid 是這次 start 的」時取得 session（`wait_session`，:651）。
  5. 所有主機**同時** sniff `SNIFF_S=20 s`（:674；`R2/01_binaries.txt` 的 `sniff=20`，也就是 3×5＋5）。
  6. 讀 daemon 報告快照 `30_report.json`。
  7. `ndt down`。
- **主機 sniff**（`hb_sniff.py`，經 `sudo -n mnexec -a <host pid>`）
  - 一個 `ETH_P_ALL` socket，看得到 lo 以外的所有介面。
  - 兩個條件任一成立就算心跳幀：ethertype `0x88B5`，**或** payload 裡有 magic `NDHB`、且 magic 後第 6 byte 起是這次傳進來的 session 的 8 bytes。所以被改寫或包進隧道的幀也抓得到。
  - 看到第一幀就停。
  - sniff 的 JSON **沒有記錄**它用哪個 session 比對 payload。session 從 `wait_session` 傳進去（READ）；raw 裡只有報告的 `session`。
- **daemon 計數**（READ：`tools/test_workflow/ndtwin-lab` :1095-1161）
  - `forwarded`：心跳幀以 OUTGOING 離開某介面，而且那個介面不是它自己的送出端。落在 host-facing 介面算 `forwarded_to_hosts`，否則算 `forwarded_between_switches`。
  - `misdelivered`：INCOMING 到了不對的介面。
  - `foreign`：別的 session 的幀。
- **段 S 對裁決 4 的操作化**：任一主機看到心跳幀，或 `forwarded_to_hosts>0`，就停。這比裁決 4 原文窄（§1 第 4 點）。

### 3.2 OBSERVED — 26 臂（`R2/40_census.tsv`；各欄由 `R2/census_<練習>_<臂>/` 的 `10_up.txt`、`11_hb_start.txt`、`30_report.json`、`sniff_*.json`、`90_down.txt` 讀出）

欄位說明：
- up：package entries／交換機數，出自 `10_up.txt`；**EMPTY** 見下方逐列說明。
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

**合計**：
- 20 臂、78 次主機 sniff。主機一共收到 372 幀，其中心跳幀 **0**（`by_ethertype` 與 `by_payload` 都是 0）。
- 快照裡送出的心跳幀是 660，快照當下已被對端 veth 聽到 644（差的 16 幀是 basic 兩臂第 5 輪，見下方）。
- 另外 run 1–2 的 detect 階段各對 basic/solution 送了 336 幀：60 幀在 netem 被丟，276 幀被對端收到；side effects 全 0（§2.2）。run 3–4 的 detect 也全 0（§2.4.6）。

逐列說明：
- **sniffer 本身**：
  - 78 份 `sniff_*.json` 都是 `"seconds": 20.0`、`"stopped": "time"`，都沒有 `error` 欄，78 份 `.err` 都是 0 bytes。
  - 每台主機在 20 s 裡收到 3–6 幀，全部是非心跳幀、全部在 `eth0` 上收到。sniffer 只列出收到過幀的介面，所以這不證明主機只有 `eth0`。
  - sniffer 只記數量不記內容，這 372 幀是什麼不知道。
- **4 臂 no link**（calc、multicast 各 solution／skeleton）
  - `11_hb_start.txt` 寫「the running fabric has no switch-to-switch link; nothing to send」：1 台交換機、0 條鏈路，calc 2 個、multicast 4 個 host-facing 介面只聽。
  - `ndt up` 是 ready（calc 0 條、multicast 4 條 entries，都在 1 台交換機上）。
  - `40_census.tsv` 記為 `no frame sent`。**這 4 支 pipeline 沒有收到任何心跳幀，普查對它們什麼也沒說。**
- **2 臂 NOT-BUILT**，都標「(the arm's designed red)」，沒有 fabric：
  - basic_tunnel/skeleton：preflight rc=1，9 個 problem，第一個是「table 'MyIngress.myTunnel_exact' is not in the p4info」（`R2/prep_basic_tunnel_skeleton.txt`）。
  - flowcache/skeleton：p4c 編譯 rc=1。`packet_in`／`packet_out` header 缺欄位（`Field … is not a member of header …`，`--Werror=type-error`；`R2/prep_flowcache_skeleton.txt`）。
- **EMPTY 的 3 臂**（p4runtime 兩臂、flowcache/solution；這 3 臂是 `mode external`，其餘 21 個有 fabric 的臂都是 `mode ndtwin`，見各 `10_up.txt` 的 `app package … (mode …)`）
  - OBSERVED：`10_up.txt` 有四句話：
    - 「external control plane: this fabric is up and EMPTY. NDTwin has programmed nothing and will not」
    - 「no pipeline loaded on any of them, by design」（proxy 的 liveness probe）
    - kernel liveness 0/3 up（「probe FAILED_PRECONDITION」）
    - preflight 的「entries none (control plane 'external' brings its own)」
  - OBSERVED：同一臂的心跳報告 `fabric.switches.*.program` 是 `advanced_tunnel.json`／`flowcache.json`。
  - READ：這個欄位取自 manifest 記下的 bmv2 啟動指令（`p4_testbed_topo.py:229` 存下 `launch_argv`、:511 寫進 manifest 的 `argv`；`ndtwin-lab:877-884` 取第一個 `.json` token）。
  - READ：`p4_proxy/mininet/p4_testbed_topo.py:217-220` 有 JSON 就把它放上 bmv2 的 argv，沒有才用 `--no-p4`。
  - INFERRED（沒驗證）：
    - bmv2 啟動時已把那支 JSON 載進 data plane。「no pipeline loaded」是 P4Runtime 那一側的說法：沒有經 `SetForwardingPipelineConfig` 設過 P4Info，所以 probe 回 FAILED_PRECONDITION。
    - 因此心跳幀遇到的是那支程式、表全空、只有 default action。
    - 這條推論鏈沒有 bmv2 log，也沒有讀表來證實。
- **basic 兩臂的 40／32 不是掉幀**
  - OBSERVED：快照寫在最後一次被聽到之後 5.000–5.001 s；每個方向 `sent` 5、`last_seq` 4。
  - OBSERVED：其他 18 臂的快照寫在最後一次被聽到之後 0.500–0.501 s，送＝聽。
  - INFERRED：basic 兩臂的快照是第 5 輪送出當下那次例行寫入，第 5 輪還沒被聽到。所以它們快照裡的計數只涵蓋前 4 輪。
- **每臂的 `ndt down`**：
  - 24 臂的 `90_down.txt` 都以「claim note now says the lab is down and verified clean」結尾。
  - `log2` 裡沒有任何一行「census …: 'ndt down' exited」。
  - `40_census.tsv` 沒有 `skipped` 列。

### 3.3 READ／INFERRED（沒有在 live 上執行或驗證）

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
1. **controller**：
   - 3 個 external 臂**完全沒有 controller**：練習自己的 controller 沒起；proxy 對 external 不開 arbitration stream、不起接收執行緒（READ：`p4_proxy/proxy_agent/p4_client.py:318`、:634）。
   - 其餘 17 個 `mode ndtwin` 臂，**proxy 就是 controller**：它開 `StreamChannel` 並起接收執行緒（READ：`p4_client.py:645-650`）。
   - 有 controller、有 entries 的 external 臂會怎樣，是 H5 的事。
2. **沒有流量**：spike 不產生流量，pipeline 是在閒置狀態下遇到心跳。有狀態的 pipeline（flowcache、link_monitor、mri、load_balance）在有流量時的反應沒量。
3. **裁決 4 的原文沒有全測**：
   - 「任何封包因心跳而到達主機」要把主機收到的 372 幀非心跳幀定性，並有每臂心跳關閉的對照窗，這次都沒有。
   - 「任何 06 臂判定改變」是 H5 的事。
4. **視窗對齊**（READ，程式順序）：sniffer 要等 `heartbeat start` 返回、而且報告出現這次 pid 的 running（:633 → :651 → :674）才開，所以第一輪送出時可能還沒有任何 sniffer 在聽。每臂視窗與送出輪次的實際對齊，raw 沒有記錄。
5. **沒有 live 陽性對照**：兩個偵測器在 live 上都只讀到 0。
   - 它們的 socket 在 live 上是活的：daemon 在正確介面上的 INCOMING「heard」會隨剪線／復原變化（§2.2）；每台主機 sniffer 都收到 3–6 幀非心跳幀。
   - 但「真的心跳幀到了主機會被認出來」和「OUTGOING 轉送會被記成 `forwarded`」只在離線證過：spike 自測用 daemon 自己的 `encode` 產幀，原樣與重新包裝都認得；helper 測試 §H.3 第 6、8 點（`P4-HB-SUMMARY.md`）。
   - 零的鑑別力建立在這些離線證明上。
6. **daemon 計數看不到改過 ethertype 的幀**（READ：helper 的 BPF 只收 0x88B5，`tools/test_workflow/ndtwin-lab:1047-1048`）。
   - 某支 pipeline 若把幀重新包裝、改了 ethertype 再轉到別的交換機，四個計數都會是 0。只有它到了主機時，才會被 sniffer 用 payload 抓到。
   - 送到 CPU port（packet-in）的幀，兩個偵測器都看不到。在 3 個 external 臂，送上去沒人收；在 17 個 `mode ndtwin` 臂，會送到 proxy 的 stream。有沒有發生，raw 裡沒有：proxy 的 log 沒有存檔。
7. **沒建成的 2 臂沒有 pipeline 可測**。它們在 06 裡同樣停在 fabric 之前（`census_prepare.py` docstring），所以 H5 也不會碰到（INFERRED）。
8. **link 遙測取樣到心跳幀**（`P4-HB-SUMMARY.md` §H.7 第 10 點）：沒量。

## 4. 第一次 live 發現的 spike 缺陷與修正

### 4.1 run 1 的 teardown：自己的 `measuring=` 讓 ndt 拒絕 down，spike 仍然 release

**發生了什麼（OBSERVED，除非另標）：**
- detect 階段 export 了 `NDT_MEASURING`（READ：現行 spike :1654）。兩份拒絕訊息引的正是它：「measuring=heartbeat spike S: detection latency, out-of-band netem on s1-eth3/s3-eth1」。
- 之後兩次 `ndt down` 都回 rc 5，訊息是「refusing to tear down: this claim DECLARES a measurement in progress」（`R1/26_down.txt`、`R1/90_down.txt`；`log1:96`、`:101-105`）。
- `finish()` 照樣 release：`app_package_override SURVIVED`、`ok lab released`（`log1:106-111`）。
- 在這之前，心跳已經停了（`R1/25_hb_stop.txt`），netem 已經拿掉、qdisc 與快照相同（`log1:95`）。
- fabric 在無人 claim 的狀態下，從 release（不晚於 10:34:00，`log1:115`）到 orchestrator 10:34:34 claim 收尾（`log1c:1`、`:8`），**約 34 s**。兩端時戳都只到秒，所以至少 33 s。
- 收尾：`ndt down` rc 0、verify clean；release rc 0；之後 `ndt status` 是 bmv2 0、tc netem none、heartbeat not running（`log1c:10-61`）。

**修正**（第 7 輪，`P4-HBR7-SUMMARY.md:6-9`）：
- `5c34da71`：每次 `ndt down` 之前先 `retract_measuring`，也就是 `env -u NDT_MEASURING ndt claim`，並讀回確認；down 回 0 或 3 才 release，其他一律保留 claim、印出指令。
- 紅燈先行：`dba92d4e`。
- oldcode 列 L1、L2：`e20fd477`。
- 判官：`a77b8fe2` MERGE AFTER FIXES（`judge/judge-HBR7-a77b8fe2.md:5`）。

**run 2 在 live 上走過修好的路（OBSERVED）：**
- detect 之後重宣告：「re-claiming WITHOUT measuring= … ok lab claimed by orch-0926 for 177m」（`log2:96-98`、`R2/26_down.reclaim.txt`）。接著的 `ndt down` 走完，以 verify clean 收尾（`R2/26_down.txt`）。
- 收尾的 `ndt down` 回 3，被當成預期（`log2:208-211`、`R2/90_down.txt`「nothing was up to tear down」）。
- 在還原好的旋鈕上再 claim 一次（`log2:214-216`、`R2/95_release.reclaim.txt`「for 164m」），然後 release（`log2:219`）。
- run 3–4 也各走過一次同一條路（`log3:128-145`、`log4:157-174`）。
- **`keep_claim`（down 被拒時保留 claim）這條路沒有在 live 上走過**：run 2–4 都沒有任何 down 被拒。

### 4.2 `CLAIM_MINUTES=180` 是死碼（判官在 run 2 之前找到）

- **問題**：run 1 實際 claim「for 45m」（`log1:39`）。原因是 `_common.sh:37` 的 `: "${CLAIM_MINUTES:=45}"` 先被 source，spike 自己的 180 預設永遠不生效。
- **誰找到的**：判官在 `a77b8fe2` 的 finding 1，blocking（`judge/judge-HBR7-a77b8fe2.md:5`、`:10`）。
  - 判官估 PART=all 要 56–82 分鐘，claim 會在 census 中途過期。
  - 依現行檔頭（detect ≈15 min、census 每臂 2–3 min × 26，spike :24、:39）算是 67–93 分鐘。兩者都遠超過 45 分鐘。
- **修正**：`f1e1be2b` 把預設移到 source 之前；紅燈 `11734586`；oldcode 列 R7-1 `20870ce0`；判官 `96abb9b0` MERGE（`judge/judge-HBR7b-96abb9b0.md:6`）。
- **live**：run 2 claim「for 180m」（`log2:39`）。
- **附記（OBSERVED）**：run 2 整體只跑了 16 分 53 秒，比兩個估算都短很多。

### 4.3 census 在某臂 down 被拒之後仍往下建

- **問題**：下一臂的 `ndt up p4 --app` 碰到同尺寸的完好 fabric，只會回「already up … reusing」，於是量錯 pipeline。
- **誰找到的**：判官 `a77b8fe2` 的 finding 2，note，強烈建議修（`judge/judge-HBR7-a77b8fe2.md:11`）。
- **修正**：`f1e1be2b` 的 `census_down`：停下、其餘臂記 `skipped`、判 FAIL。紅燈 `11734586`；oldcode 列 R7-2、R7-2/stop、R7-2/always `20870ce0`。
- **live**：沒有觸發。run 2 的 24 臂 down 都是 clean（§3.2）。

### 4.4 仍然開著（run 1–4 都沒觸發，除非另標）

- **census 期間 claim 沒有宣告 `measuring=`（這次 live 就是如此）**
  - OBSERVED：detect 收尾時已撤回（`log2:96-98`，claim note 變成「in use: ndt up p4 4 …」）。
  - READ：`NDT_MEASURING` 只在 take_claim 之前 export 一次（spike :1653-1655），撤回後 `unset`（:261），census 不會再宣告。
  - INFERRED：13:25–13:38 普查在量的時候，`ndt status` 的 measuring 欄會說沒有量測。claim 本身仍由 orch-0926 持有。
- **第 7b 輪判官的 notes**（`judge/judge-HBR7b-96abb9b0.md:9-12`）：
  - 沒給 `NDT_OWNER` 時會以 `live-p1` 取 claim（run 2–4 都有明給，`log2:2`、`log3:2`、`log4:2`；第 8 輪判官仍列為未修，`judge/judge-HBR8-3a724b87.md:15`）。
  - rc 3 在五個站點的記帳不一致。
  - STOP 加上 down 被拒時，其餘臂沒有 `skipped` 列。
  - 讀回檢查只涵蓋 `: "${VAR:=…}"` 這種寫法。
- **第 7 輪判官 note 7**（`judge/judge-HBR7-a77b8fe2.md:16`）：`spike_finish` 拆 netem 失敗時的訊息列不出介面名。
- **第 5 輪 finding 6／7**（第 6 輪判官記為仍開，`judge/judge-HBR6-3d297c34.md:18`）：
  - r3 有三條 reason 是空的。
  - detect 對「already running」的處理不對稱。
- **`CENSUS_EVEN_IF_RED=1`**：加上 detect 提早停時，fabric 會留著給 census 用（`P4-HBR7-SUMMARY.md:16`；run 2 用 `env -u` 拿掉了）。

## 5. 給段 W 的輸入

### 5.1 W 可以依賴的（O＝OBSERVED，I＝INFERRED，R＝READ）

- **（O）daemon 報告在真 veth、真 netem 上的語意是對的**
  - 兩端都剪：被剪兩向不再被聽到，其他 6 向照常（50 個 cycle 都是如此：run 1–2 各 10、run 3–4 共 30；另加 run 3–4 各兩個對照）。
  - 只剪一端：只有從那一端送出的方向不再被聽到（對照 (b)）。
  - 復原後的下一輪一定被聽到（run 3–4 的 30 列）。
  - `send_errors` 0。
  - 報告的 `period_s` 是 5，等於 proxy 的 `LLDP_BEACON_INTERVAL_S`；run 3–4 起跑時也核對過（`log3:60`、`log4:60`）。
- **（O）報告層級延遲，相位覆蓋整個 period（run 3–4，§2.4）**：
  - 剪線 → 規則成立：10.066–14.869 s；最壞實測在 φ＝0.131 s。
  - 復原 → 報告顯示：0.571–5.488 s。
  - 報告延遲：0.500–0.501 s，30 個 cycle 每一個都是。
  - 不剪線的 20.1 s 裡，讀者看到的最長沉默是 5.494 s。
- **（I）W 層級**（§2.5）：
  - 剪線：≤ 19.869 s，另加 pass 耗時、讀檔、HTTP、kernel；φ→0 的極限是 20 s。
  - 復原：≤ 10.488 s，另加 pass 耗時、讀檔、kernel。
- **（O）報告的寫入節奏**：
  - 每輪送出時寫一次：run 1–2 的剪線快照寫在第 20·i s；basic 兩臂的普查快照寫在最後一次聽到之後 5.000–5.001 s。
  - 聽到東西之後再寫一次：0.500–0.501 s（run 3–4 逐 cycle 實測；run 1–4 的 `12_report_first.json` 是 0.50033–0.50057 s）。
  - **（I）** daemon 活著時，H.7 提案的新鮮度判準（`written_mono` 距今 ≤ 2×`period_s`）應該會一直成立。
- **（O）副作用**：心跳幀在 run 2 普查的 20 臂（06 的包裝、沒有流量、3 臂完全沒有 controller）裡從沒到過主機；四個計數全 0。run 3–4 的 detect 也全 0。W 要揭露在 `switch_state` 的 `side_effects`，這四次 run 裡的值就是全 0。
- **（R）link key**：報告方向的 `(tx.dpid, tx.port, rx.dpid, rx.port)` 就是 H.7 提案的 key（`P4-HB-SUMMARY.md` §H.7 第 4 點）。
- **（R）常數與送出排程**：
  - daemon 的 `PERIOD_S=5` 寫死（`ndtwin-lab:734`），送出排程從 `started_mono` 起每 5 s 一次、不漂移（:1313、:1331；某輪遲到時才重設，:1332-1333）。
  - proxy 的 period 可以被 `NDTWIN_P4_BEACON_S` 改。兩者不一致時怎麼處理見 H.7 第 6 點；這四次 run 都是一致的。
- **（R）去相位的工具已經有了**：spike 的 `phase_wait`（`094f417f` 的 `hb_watch.py:704`）與 `19_phase_plan.tsv` 的 sweep／random。H1 可以沿用；是否沿用由 W 決定。

### 5.2 W 仍須在 live 上證明的（工單 §2）

- **H1**：外來 fabric 剪一條 spine 線 ⇒ ≤20 s kernel 圖兩向 `is_up:false` ⇒ 路由改寫 ⇒ 12 對主機 ping 全恢復；拿掉 netem ⇒ ≤20 s 恢復 `is_up:true`；沒有殘留 netem。
  - **剪線方向的 ≤20 s 不是保證（INFERRED，§2.5）**：實測最壞剪線相位下，常數本身已用到 19.869 s，只剩約 0.13 s 給 watchdog pass、`_notify_link` 的 HTTP、kernel 更新圖。這與自家 fabric 同一性質。**算數的是 H1 實際量到的數字。**
  - H1 要量出 kernel 層級的時間，而且至少要做到：
    - 剪線相位涵蓋整個 period，包括 φ≈0.13 s 這一端（用 sweep，或 n 夠大的 random），並記錄每個 cycle 的 t0a／t0／`cut_lh_mono` 絕對值。
    - 記錄 watchdog 每次 pass 的時刻，才知道每個 cycle 多等了多久。同一 run 裡它漂多少，取決於沒量過的 pass 耗時（§2.5）。
    - 記錄 `_notify_link` 送出與 kernel `is_up` 轉態的時刻，把 pass、HTTP、kernel 各自的耗時分開。
  - 只用相位鎖迴圈（聽到之後才剪）量出來的 H1，結果只能寫成「φ≈0.7 s 時」（§2.3）。
  - **復原方向**：W 層級 ≤ 10.488 s＋pass＋kernel，離 20 s 有約 9.5 s 的餘裕（INFERRED）。
- **H2**：陰性對照，心跳不跑 ⇒ `is_up` 保持 true。
  - spike 的對照 (a) 只證明了報告層級：不剪線時規則不會誤判（OBSERVED）。
  - H2 要的是另一件事：kernel 層級，而且心跳關掉時不會有別的路把 `is_up` 改掉。這仍須在 live 上做。
- **H3**：unbound package ⇒ 只偵測、不改路，`reroute:false` 附原因，寫入回 501。
- **H4**：`/stats/flowentry/*` 在外部控制平面回 409。
- **H5**：06 完整跑一次、心跳開著 ⇒ 26/26，且逐臂與 `2026-09-24T185505Z` 相同；01 PASS。本 spike 普查沒涵蓋的 §3.3 第 1–3 點（controller、流量、判定是否改變）由這一項補上一部分。
- **單端故障**（INFERRED）：只斷一端時 proxy 只會看到單向的 down（對照 (b)）。W 怎麼把單向 down 交給 kernel、kernel 怎麼處理，是 W 的設計；工單的 H1 只要求兩端都斷的情況。
- **H5 也不會涵蓋的**（INFERRED）：
  - 多交換機的 multicast。
  - 兩個沒建成的 skeleton 臂。
  - 兩個副作用偵測器的 live 陽性對照。
  - 主機收到的非心跳幀有沒有因心跳而多出來（需要心跳關閉的對照窗）。

## 6. 證據索引

### 6.1 binary 識別（OBSERVED，`R*/00_helper_sha.txt`、`R*/01_binaries.txt`、`R*/10_up_basic.txt`）

| | run 1 | run 2 | run 3 | run 4 |
|---|---|---|---|---|
| trunk | `4bc1201b091ae692119a7c76ac17dd7b5c42e0be` | `580767a83dea12e42755687d174af891b69deb97` | `094f417fd35be9b1a01f2772c84c0b9a9e10b360` | 同 run 3 |
| 已裝 `/usr/local/sbin/ndtwin-lab` sha256 | `6a558fe452955de358fd1a3b4e730fe2be55368a6c90b93675c5442c036fd4fb` | 同左 | 同左 | 同左 |
| checkout 的 `tools/test_workflow/ndtwin-lab` sha256 | 同上（已裝＝checkout） | 同上 | 同上 | 同上 |
| `hb_watch.py`（sha256 前 16） | `326b76ecc6d85c73` | 同左 | `e5aa1a5d4d1bb5d9` | 同 run 3 |
| `hb_sniff.py`／`census_prepare.py`（sha256 前 16） | `9a14d80b3f9c11e4`／`4c5c507219bc924c` | 同左 | 同左 | 同左 |
| `S_heartbeat_spike.sh`（sha256 前 16） | `db20f12e8191d2bd` | `6b4e98316d20b95a` | `14b0fe0587dc73a1` | 同 run 3 |
| proxy 常數（執行期 import） | beacon=5 timeout=15 watchdog=5 sniff=20 | 同左 | 同左 | 同左 |
| 相位參數 | — | — | `PHASE=sweep seed=2772311660 sweep=default controls=1 nocut=20 margin=0.05` | `PHASE=random seed=1968294680`，其餘同 run 3 |
| bmv2 | 路徑 `/usr/local/bmv2-fast/bin/simple_switch_grpc`（`10_up_basic.txt:42`、`:53`「running binary」）；**sha256／版本未記錄** | 同左；普查 24 臂的 `10_up.txt` 也是同一路徑 | 同左 | 同左 |
| p4c | `/usr/local/bin/p4c-bm2-ss`（`R2/prep_*.txt` 的指令行）；**版本未記錄**，只記了輸出 JSON／p4info 的 sha256 前 16 | 同左 | 同左（`R3/prep_basic_solution.txt`） | 同左 |
| tutorials | `/home/adam/tutorials`，在 repo 外、執行期才編譯；**checkout 的 commit 未記錄** | 同左 | 同左 | 同左 |

- CHECKED：我在 worktree 對 `4bc1201b`、`580767a8`、`094f417f` 的 blob 重新雜湊過，spike 四支檔與 helper 的 sha256 和上表相同。
- 四次 run 都在主 checkout 上跑，都有未提交檔，其中 2 個會影響行為：`p4_proxy/mininet/host_count_override`（快照為 4、已還原）與 `tools/remote-lab/dorm_lab/`。
  - run 1–2：79 個未提交檔（`log1:25-28`、`log2:25-28`）。
  - run 3–4：84 個（`log3:26-29`、`log4:26-29`）。
- kernel／proxy 雖然有起，但不在量測路徑上，所以本文件不指認它們的 binary。

### 6.2 引用過的 raw 與文件

| 路徑 | 內容 | 用在 |
|---|---|---|
| `R1/20_cycles.tsv`、`R2/20_cycles.tsv` | 每 cycle 的 down／up／cut_tc／collateral／netem_left | §2.2 |
| `R1/22_summary.txt`、`R2/22_summary.txt` | spike 自己的 min/median/max 與判定 | §0、§2.2 |
| `R1/`、`R2/` 的 `21_report_cut_{1..10}.json`、`12_report_first.json`、`24_report_last.json` | 剪線當下、起跑、結束時的心跳報告 | §2.1、§2.2、§2.3 |
| `R*/23_qdisc.diff`、`R*/13_qdisc.before` | qdisc 全樹比對 | §2.2、§2.4.6 |
| `R*/11_hb_start.txt`、`R*/10_up_basic.txt`、`R*/00_tc_grant.txt` | 心跳計畫、fabric、bmv2 路徑、tc 路徑 | §2.1、§6.1 |
| `R2/00_heartbeat_status_before.txt` | run 1 daemon 的最終報告 | §2.2 |
| `R3/20_cycles.tsv`、`R4/20_cycles.tsv` | 每 cycle 31 欄，含 CLOCK_MONOTONIC 絕對時戳 | §2.4.2–2.4.4 |
| `R3/22_summary.txt`、`R4/22_summary.txt` | spike 的彙總、分箱、覆蓋判定 | §2.4.3、§2.4.4 |
| `R3/19_phase_plan.tsv`、`R4/19_phase_plan.tsv` | 相位計畫與 seed | §0、§2.4.1 |
| `R3/18_controls.tsv`、`R4/18_controls.tsv`、`R*/18_polls_{a,b}.tsv`、`R*/17_report_single_end.json` | 兩個對照 | §2.4.5 |
| `R3/`、`R4/` 的 `21_polls_<cycle>.tsv`、`21_report_cut_<cycle>.json`、`12_report_first.json`、`24_report_last.json` | 每次輪詢、剪線當下、起跑、結束時的報告 | §2.4 |
| `R4/00_heartbeat_status_before.txt` | run 3 daemon 的最終報告 | §2.4.6 |
| `R2/40_census.tsv` | 普查表 | §3.2 |
| `R2/census_<練習>_<臂>/{10_up.txt,11_hb_start.txt,30_report.json,31_hb_stop.txt,sniff_*.json,sniff_*.err,90_down.txt}` | 每臂的 raw | §3.2 |
| `R2/prep_*.txt` | 各臂的建置輸出（p4c 指令與輸出 sha）；沒建成的原因 | §3.2、§6.1 |
| `R1/26_down.txt`、`R1/90_down.txt`、`R1/25_hb_stop.txt` | run 1 的 teardown 被拒 | §4.1 |
| `R2`–`R4` 的 `26_down.reclaim.txt`、`26_down.txt`、`90_down.txt`、`95_release.reclaim.txt` | 走過重宣告與 release 的路 | §2.4.6、§4.1 |
| `log1`–`log4`、`log1c` | 四次 run 與收尾的終端輸出 | §0、§2.4、§4 |
| `judge/judge-HBR7-a77b8fe2.md`、`judge/judge-HBR7b-96abb9b0.md`、`judge/judge-HBR6-3d297c34.md` | 第 7／7b／6 輪裁決 | §4 |
| `judge/judge-HBR8-3a724b87.md` | 第 8 輪（去相位）裁決 | §1、§2.4 |
| `judge/judge-HBSPIKEDOC-4820862b.md` | 本文件第一版的裁決、補跑建議（:28-29）、複審附錄（:33-40） | 標頭、§2.4 |
| `judge/public-verify-20260926T063944Z.log` | orchestrator 的未認證公開性檢查 | 標頭 |
| `scratch/overnight-2026-09-05/hunt-0911/fix/P4-HBR7-SUMMARY.md` | 第 7／7b 輪 worker 交件 | §4 |
| `HBR8`（`scratch/overnight-2026-09-05/hunt-0911/fix/P4-HBR8-SUMMARY.md`）:47、:113、:117 | 第 8 輪 worker 交件：拒跑條件、`PACKET_QDISC_BYPASS`、對照 (b) 當時是 INFERRED | §1、§2.4 |
| `scratch/overnight-2026-09-05/hunt-0911/fix/P4-HB-SUMMARY.md` §H.3、§H.5–H.7、:212 | 測試、碰撞表、預測、proxy 端契約、表／計數器觀測不到的原因 | §3.3、§5 |
| `580767a8` 的 `spike/S_heartbeat_spike.sh`（:24、:39、:261、:520-579、:536、:547-561、:611-699、:633、:651、:674、:1653-1655）、`spike/hb_watch.py`、`spike/hb_sniff.py`、`spike/census_prepare.py` | run 1–2 的量法與迴圈結構（READ） | §2.1–2.3、§3.1、§3.3、§4 |
| `094f417f` 的 `spike/S_heartbeat_spike.sh`（:568-624、:638-666、:668-769）、`spike/hb_watch.py`（:273-281、:326、:704） | run 3–4 的量法、對照、覆蓋判定、`phase_wait`（READ） | §2.4.1、§5.1 |
| `tools/test_workflow/ndtwin-lab` :657-693、:734、:764-765、:877-884、:1047-1048、:1095-1161、:1229、:1313、:1331-1333、:1335-1344 | 心跳 daemon 的語意、週期、送出排程、寫入節奏、BPF、`PACKET_QDISC_BYPASS`、計數 | §2、§3、§5 |
| `p4_proxy/proxy_agent/topology_manager.py` :369、:411-418、:1951-1953、:2050-2053、:2065-2102 | 常數、`_link_timeout`、watchdog 迴圈 | §1、§2.5 |
| `p4_proxy/proxy_agent/p4_client.py` :318、:634、:645-650 | external 不開 stream；ndtwin 開 `StreamChannel` | §3.3 |
| `p4_proxy/mininet/p4_testbed_topo.py` :217-220、:229、:511（READ） | bmv2 argv 放 JSON 或 `--no-p4`；`launch_argv` 寫進 manifest | §3.2 |
| `doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh:35`、`:37` | `NDT_OWNER`／`CLAIM_MINUTES` 的預設 | §4.2、§4.4 |
