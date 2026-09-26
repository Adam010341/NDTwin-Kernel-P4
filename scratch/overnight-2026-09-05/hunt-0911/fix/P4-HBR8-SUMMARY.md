# SUMMARY：HB spike round 8（`fix/hb-spike-r8-0926`）— 去相位鎖的偵測輪

- Head `3a724b8751f72d0f11bb3c507b59c858b49369cc`，base trunk `580767a8`；未 push、未 merge；tree 乾淨；無背景程序、無 `.oldcode-*` 殘檔、無 `/tmp/hb-spike-selftest-*` 殘留。**全程離線**：沒動 lab、沒 sudo（`SELFTEST_PROBE_SUDO`／`FAULTS_TC` 皆 unset），沒碰 `ndtwin-lab`／`ndt`／`_common.sh`／`faults.sh`。
- 只動 spike 的三個檔（`git diff --stat 580767a8..HEAD`：+1532 −66，全在這三檔；diff 大是因為新增模擬 daemon 與自測，已逐檔確認沒有別的東西）：
  - `doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh` 2138 行（+514）
  - `doc/audit/2026-09-25_p4-heartbeat/spike/hb_watch.py` 1246 行（+946）
  - `doc/audit/2026-09-25_p4-heartbeat/spike/oldcode_selftest.sh` 807 行（+138）
- Commits：
  - `ccdecd92` 自測先行（**紅**）：模擬 daemon（`hb_watch.py` 的 `Sim`，經 `HB_WATCH_SIM` 接上）＋新檢查，跑在 round-7 的偵測迴圈上。
  - `c6619553` 實作（綠）。
  - `3a724b87` oldcode：R8-1…R8-9，外加兩列被 round 8 移動的 anchor（R4-3/d-i、R5-2）。

## 逐項

**1. 剪線去相位**（`detect`，`hb_watch.py plan|phase-wait|cut-down`）
- 每個 cycle 在剪線前照 `19_phase_plan.tsv` 先等。`PHASE=random`（預設）：從剪前檢查看到兩向 heard 起，等 U[0, period)，用 `random.Random(PHASE_SEED)`；沒給 seed 就從 `/dev/urandom` 抽一個，記在 plan 第一行和 `01_binaries.txt`。`PHASE=sweep`：剪線**開始**的時刻落在報告裡最新一個 `last_heard_mono` 之後的預定偏移，預設 CYCLES 個點，從 0.05 s 到 period−0.15 s；`SWEEP_PHASES` 可覆寫，列表比 CYCLES 短時循環使用。
- 每個 cycle 都記：`cut_delay_s`、`cut_phi_s = t0 − cut_lh_mono`（來源 `cut_phi_src`＝heard）、`cut_phi_grid_s`（排程相位，只作對照）；t0a、t0、那一幀的 CLOCK_MONOTONIC 絕對值都寫進 raw。
- 紅／綠：`spike_selftest.red.hbr8-ccdecd92.log`（rc 1，43 條紅）裡，round-7 迴圈在模擬時間線上是 `10 cuts, all within an arc of 0.08 s (0.78 .. 0.86 s), largest gap 4.92 s -- PHASE-LOCKED`（random 和 sweep 都是這樣）。`spike_selftest.hbr8-3a724b87.log` 綠（rc 0，142 ok／0 紅）。
- oldcode：**R8-1**（過去形：round 7 的「剪前不等」）紅 7 條，理由都是 PHASE-LOCKED／`cut_delay_s '-'`／sweep 沒落在計畫偏移；**R8-4**（變異：相位從排程算）紅 3 條；**R8-9**（變異：phase-wait 錨在 started_mono）紅 6 條。

**2. 復原去相位**：同一套，sweep 的偏移反序。記 `restore_delay_s`、t1a、t1、`restore_anchor_mono`（復原前讀到的最新 heard）、`restore_phi_s = (t1 − anchor) mod period`（來源 heard@plan）。紅 log 裡 round-7 的復原落在一輪送出後 0.07–0.15 s，PHASE-LOCKED。oldcode **R8-2**（過去形）紅 9 條，模擬出來是 0.09–0.17 s。

**3. 兩個層級都記**
- up：`up_s` 維持 daemon 接收時戳；新增 `up_rpt_s`（第一份顯示兩向都 heard 的報告的 written_mono − t1，也就是**報告層級**）、`up_poll_s`（讀者輪詢時刻）、`up_lh_mono`。
- down：`down_rule_s` 是規則變真的瞬間（last heard + 15 − t0）；`down_s` 是讀者輪詢到的時刻；`down_rpt_s` 是被套用規則的那份報告的 written_mono。報告內容本身沒有 down 轉態，規則是讀者的鐘對 last_heard。
- 每次輪詢的 written_mono 與兩向 last_heard 都寫進 `21_polls_<cycle>.tsv`。
- 模擬 daemon 的 lag 設成 0.7 s（不是 helper 的 0.5 s），所以寫死 0.5 會現形：量到 `up_rpt_s − up_s = 0.698`，也就是 0.7 + w − eps。oldcode **R8-3**（變異：rpt = up + 0.5）紅 4 條。

**4. 兩個對照**（`CONTROLS=1` 預設，`=0` 關掉；在 cycles 之前跑；每個對照是 `18_controls.tsv` 一列加一個 verdict）
- (a) 不剪線 `NOCUT_S`（預設 20，必須 ≥ timeout + period，否則 claim 前就 rc 2 拒跑）：任何方向都不准被規則判成 not-heard。
- (b) 只在 s1-eth3 一端上 netem：只有 1:3>3:1 可以 not-heard；down 之後再多看 period + 1 s，確認 3:1>1:3 和另外六向都還 heard。
- 兩個對照都證明**會紅**：deaf 3 輪的時間線讓 (a) BAD、整個 run FAIL；「一端 netem 吃掉整條線」的時間線讓 (b) BAD、整個 run FAIL。oldcode **R8-5**／**R8-6**（對照不會失敗的變異）各紅 2 條；**R8-7**（無視 CONTROLS）紅 4 條。

**5. summary**
- `22_summary.txt` 依表頭讀 TSV，舊檔照樣可讀。
- 舊的 min/median/max 兩行格式不變；新增 down_rule_s、poll lag、up_rpt_s、**實測 report lag**、「復原後下一輪有被聽到」檢查。
- 新增 cut phase 與 restore phase 的逐 1 s 分箱統計、最小 cut φ，以及從 raw 戳記重算 φ 的比對（re-review note 1）。
- 從 8 個 cycle 起判覆蓋：最大圓周間隙 ≥ 0.6 period 就 FAIL（PHASE-LOCKED）。n=10 誤報機率 0.26%，n=20 約 5e-7。sweep 最小 φ > 0.25 s 也 FAIL。
- `20_cycles.tsv`：round 7 的六欄原樣放在最前面，新增 25 欄，意義寫在腳本「PART detect」段的表頭註解。
- 兩次 live 的舊 raw 用新 summary 重跑（離線，跑過）：每個數字與 verdict 行都一致，只有「expected from the constants」那行措辭換了。oldcode **R8-8**（變異：summary 不判覆蓋）紅 1 條。

**6. teardown 與其他照舊**
- round 7/7b 的 teardown 情境全綠，而且 claim 情境現在以 CONTROLS=1（run 的預設）跑。
- detect 的 retract-before-down 沒動。
- 31 列舊 oldcode 全部照舊 discriminates；R4-3/d-i 的 anchor 改指 `report()`／`clock()`，R5-2 改指 `for dev in "$@"`。
- `cut_link` 可以指定要剪哪幾端（預設兩端）。
- 跑之前（claim 前）新增拒跑條件：PHASE／CONTROLS／NOCUT_S／PHASE_SEED／plan 不合法，或 `HB_WATCH_SIM` 有設，都 rc 2。

**7. 閘門**（log 在 `logs/gates-0910/`，第一行是完整 sha，最後一行是真 rc）
- `spike_selftest.red.hbr8-ccdecd92.log`：rc=1（紅先行）
- `spike_selftest.hbr8-3a724b87.log`：`SPIKE SELF-TEST PASS`／`# rc=0`
- `hb_watch_selftest.hbr8-3a724b87.log`：`SELF-TEST PASS`／`# rc=0`
- `hb_sniff_selftest.hbr8-3a724b87.log`：`SELF-TEST PASS`／`# rc=0`
- `oldcode.hbr8-3a724b87.log`：40 列加 control 全 ok，`OLD CODE IS RED IN EXACTLY ITS OWN CHECKS, EVERY REVERT`／`# rc=0`
- `oldcode_selfcheck.hbr8-3a724b87.log`：10/10 `EVERY VERDICT PATH OF THE TOOL ANSWERS AS IT MUST`／`# rc=0`
- `check_gate_anchors.hbr8-3a724b87.log`：`119/119 cells ok`／`# rc=0`
- `check_test_tmpdirs.hbr8-3a724b87.log`：`359 file(s) scanned, 0 fixed temp paths`／`# rc=0`
- 包裝腳本：`logs/gates-0910/gatelog.hbr8.sh`（就是 hbr7 那支，WT 改成本 worktree）

## orchestrator 補充說明（re-review）的處理
1. sweep 錨在報告的 `last_heard_mono`，不看排程；第一個偏移是剪線在那幀 heard **之後 0.05 s 才開始**，兩端 netem 都在該輪送出之後才上，不會量到最好情況（φ≈5 s）。R8-9 證明錨錯會紅。
2. t0a／t0／t1a／t1、`cut_lh_mono`、`restore_anchor_mono`、`up_lh_mono` 的 CLOCK_MONOTONIC 絕對值全進 raw；summary 逐列用 t0 − cut_lh_mono 重算 φ 並比對；自測的獨立檢查器也對每列比對。
3. 每端剪線耗時：`cut_tc_a_s`（開始 → A 端生效）、`cut_tc_b_s`（A → B）。用 bash 的 EPOCHREALTIME 量，不 fork，只當時長用。復原走 faults.sh 的 `revert_link_loss`，不在我擁有的檔案內，所以只記總長 `restore_tc_s`。
4. 每次輪詢的報告 written_mono 都記在 `21_polls_<cycle>.tsv`、`18_polls_{a,b}.tsv`。watchdog 的漂移沒量（spike 是報告層級）。

## 新欄位怎麼讀（`20_cycles.tsv`）
所有 `*_mono` 都是 CLOCK_MONOTONIC 絕對值（daemon 與 proxy 同一個鐘），可以直接拿 raw 重算。

| 欄 | 意義 |
|---|---|
| `down_s`／`up_s`／`cut_tc_s`（舊） | 讀者輪詢到兩向 not-heard 的時間／結束沉默那一幀的 **daemon 接收**時戳（不是報告層級）／t0 − t0a |
| `phase_mode` | random／sweep |
| `cut_plan`、`cut_delay_s` | random：預定等待秒數；sweep：預定「剪線開始」落在最後一幀 heard 之後幾秒／實際等了多久 |
| `cut_t0a_mono`、`cut_t0_mono` | 剪線開始／兩端 tc 都返回（t0） |
| `cut_lh_mono`、`cut_phi_s`、`cut_phi_src` | 剪前這條線最後一幀 heard／**t0 − 它**，也就是規則看到的相位／heard（從未 heard 時才是 grid） |
| `cut_phi_grid_s` | (t0 − started_mono) mod period，排程相位，只作對照 |
| `cut_tc_a_s`、`cut_tc_b_s` | 開始 → A 端生效／A → B 端生效（牆鐘時長） |
| `down_rule_s` | last heard + 15 − t0：規則變真的瞬間；`down_s − down_rule_s` 是輪詢延遲 |
| `down_rpt_s` | 被套用規則的那份報告的 written_mono − t0 |
| `restore_plan`、`restore_delay_s`、`restore_t1a_mono`、`restore_t1_mono`、`restore_tc_s` | 復原的同一套（t1、t1 − t1a） |
| `restore_anchor_mono`、`restore_phi_s`、`restore_phi_src`、`restore_phi_grid_s` | 復原前最新的 heard／(t1 − anchor) mod period／heard@plan／排程相位 |
| `up_lh_mono` | 結束沉默的那一幀（up_s = 它 − t1） |
| `up_rpt_s`、`up_poll_s` | **第一份顯示兩向都 heard 的報告**的 written_mono − t1（報告層級）／讀者看到它的輪詢 − t1；`up_rpt_s − up_s` 就是實測的報告延遲 |

其他新檔：
- `19_phase_plan.tsv`：plan，seed 在第一行。
- `18_controls.tsv`：欄位 control, window_s, cut, expected, observed, verdict。window_s 在 (a) 是視窗長度，在 (b) 是上限。
- `18_polls_{a,b}.tsv`、`21_polls_<cycle>.tsv`：每次輪詢的紀錄。
- `17_report_single_end.json`：對照 (b) 當下的報告。

## orchestrator 該跑的 live 指令
從 merge 後的主 checkout 跑（有 p4_proxy/venv），以操作者身分、**不要 sudo**。`ndtwin-lab` 本輪沒動，已安裝的 helper 仍應 byte-identical；腳本會自己核對，不符就 rc 2。每一支都自己 claim／release、快照並還原旋鈕。
```
setsid env NDT_OWNER=<你> PART=detect PHASE=sweep  CYCLES=10 bash doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh
setsid env NDT_OWNER=<你> PART=detect PHASE=random CYCLES=20 bash doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh
```
- 建議兩支都跑，sweep 先跑。sweep 是確定性覆蓋，含 φ→0 那一端（預期最小 φ ≈ 0.05 + cut_tc_s ≈ 0.12–0.15 s）；random 給無偏的分布，n=20 讓覆蓋判定的誤報近於 0。
- 只能跑一支的話跑 sweep。
- 預估時長（INFERRED）：sweep×10 約 5 分；random×20 約 8.5–9 分。依據是 R2 的 detect 10 cycles 約 3.7 分（13:21:48→13:25:31，含 setup），加上對照約 45 s，每 cycle 平均多等約 2.5 s 剪前、2.5 s 復原前（down 平均變短），每 cycle 約 21 s。
- 讀結果：
  - 最後一行 PASS／FAIL
  - `22_summary.txt`：末行、兩行 coverage、各相位箱的 down_s／down_rule_s 與 up_s／up_rpt_s、「report lag, measured」
  - `18_controls.tsv` 兩列的 verdict

## OBSERVED／INFERRED 分開
- **OBSERVED（跑過，離線）**：
  - 上面列的每個閘門。
  - 模擬時間線上的數字。random seed 20260926：cut φ 0.081–4.607 s（最大間隙 1.16 s），restore φ 0.245–4.537 s（1.30 s），report lag 0.698，poll lag 0.007–0.100。sweep：cut φ 0.120→4.920，|φ − cut_tc − plan| ≤ 0.000 s。
  - round-7 迴圈在同一時間線上被鎖在 0.78–0.86 s／0.07–0.15 s。
  - 新 summary 重跑兩次 live 的舊 raw：數字一致。
  - 🔴 **以上全是模擬 daemon 的數字，不是 lab 量測**。
- **READ（讀過未執行）**：
  - `ndtwin-lab` 的 `_open_socket`「Never PACKET_QDISC_BYPASS」，這是對照 (b) 預期方向的依據之一。
  - run_daemon 的寫報告時序（每輪寫一次、heard 之後再隔 `REPORT_MIN_INTERVAL_S` 才寫），Sim 就是照它建的。
  - R2 的 `21_report_cut_*.json`：heard 在 started + 5k 之後 4.5–7 ms。
- **INFERRED（未經 lab）**：
  - 對照 (b) 裡，進入 s1-eth3 的另一向不受 egress netem 影響。
  - live 的 sweep 精度：模擬不含 python 啟動時間（每次約 20–40 ms），但 φ 是從報告實量的，不靠這個精度。
  - 現行剪法下兩端都生效的最小 φ ≈ cut_tc_s，所以 15 s 是極限值，達不到。
  - 上面的時長估計。
  - random 在 n=10 時有 0.26% 的機率被判 PHASE-LOCKED 而 FAIL。

## 沒做／仍開著
- 模擬 daemon ≠ lab：本輪新碼**沒跑過 lab**。
- 復原沒有逐端時長（要改 faults.sh，不在我擁有的檔案內）。
- watchdog 相位／W 層級沒量（屬段 W）。
- r7b 已知、仍未修：`_common.sh` 讓沒設 `NDT_OWNER` 的 run 以 `live-p1` claim。
- `spike_finish` 的「could NOT remove the netem on …」印出空清單。
- PART=all 且 `CENSUS_EVEN_IF_RED=1` 時，detect 若提早停，fabric 會留在 census 底下。
- 判官 note 12（census 期間沒有 `measuring=`）沒處理，不在本輪範圍。

DELIVERED 3a724b8751f72d0f11bb3c507b59c858b49369cc
