# P3-E — 三組遙測量測（無遙測／合作式 A／鏈路式 B）：交件

**worker**：TICKET-P3 工單 E（opus）。**worktree**：`scratch/overnight-2026-09-05/wt-p3-measure-0919`，
分支 `feat/p3-three-groups-0919`，base `25b45cf8`。**沒有推、沒有併、沒有動主 checkout。**
**一臂都沒跑**：不 sudo、不 `ndt up`、不碰 lab、不起 fabric——實跑由 orchestrator。

**[Co-developed with claude code -- Adam]**

---

## 1. commit

| sha | 內容 |
|---|---|
| `eebf9054` | `PREREG.md`——三組的假設與區間、臂清單、停止規則、負載閘、對帳三條的可比條件，全部在任何封包之前註冊 |
| `0a3107a9` | `PREREG.md` AMENDMENT-1——samples/s 的軸（worker A 改過語意的 `addressed_total`）、梯子臂的遙測在／不在改用哪個計數器、driver 的四項、emitter log 收進 raw、samples/s 逐階量 |
| `ce1b2207` | 儀器與測試：`drive_e.sh`、`run_group_arm.sh`、`sample_error.sh`、`cpu_arm_probe.py`、`analyse.py`、`plot.py`、`FINDINGS.md` 骨架、`tests/{synthetic,test_analyse,test_plot}.py`、`tests/mutate_analyse.sh` |

工作樹乾淨，沒有夾帶任何別人的檔案（每個 commit 都是逐檔 pathspec）。

---

## 2. 每一條跑過的指令（rc ＋ 最後一行）

```
bash -n drive_e.sh
rc=0 | last: 

bash -n run_group_arm.sh
rc=0 | last: 

bash -n sample_error.sh
rc=0 | last: 

bash -n tests/mutate_analyse.sh
rc=0 | last: 

/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python -m py_compile analyse.py plot.py cpu_arm_probe.py tests/*.py
rc=0 | last: 

venv: unittest discover -s tests -t tests
rc=0 | last: OK (skipped=1)

python3 (matplotlib): unittest discover -s tests -t tests
rc=0 | last: OK

tests/mutate_analyse.sh
rc=0 | last: mutations: 16   survivors: 0

analyse.py on synthetic raw
rc=0 | last: summary -> /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad/synthraw/summary.json

plot.py --check (venv, no matplotlib)
rc=0 | last:       link   1:20.0 8:20.0 20:20.0

plot.py render (python3)
rc=0 | last: wrote /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad/figs/fig3_cpu.pdf

grep -nE 'pkill|pgrep|killall' in executable lines
rc=0 | last: /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/doc/audit/2026-09-19_telemetry-three-groups/cpu_arm_probe.py:128:    its own instrument (cpu_probe.py's note says the same thing about pgrep).

```

補充：

```
NDT_OWNER=p3-E drive_e.sh --only G3 --dry-run      rc=0   selection G3
NDT_OWNER=p3-E drive_e.sh --only C1 --dry-run      rc=0   selection C1
NDT_OWNER=p3-E drive_e.sh --only G9 --dry-run      rc=2   "--only takes G1..G6 or C1|C2|C3, got 'G9'"
NDT_OWNER=dryrun run_group_arm.sh --group link --frame 64 --arm f64_a --dry-run   rc=0
NDT_OWNER=dryrun sample_error.sh  --group none --rate 20 --window 1 --dry-run     rc=0
grep -nE '\b(pkill|pgrep|killall)\b' 全部檔案                  ⇒ 3 筆，**全部是註解／docstring 裡在說「不要用它」**，沒有任何一次呼叫
```

### 變異閘（16 顆變異、2 顆控制、0 survivor）

| 變異 | 被哪顆測試殺 |
|---|---|
| M-E1 天花板區間退回名目 1.5× 階距 | `test_the_interval_boundaries_are_the_realised_step_not_the_nominal_one` |
| M-E2 兩臂差多遠都算 resolved | `test_a_cell_whose_arms_are_six_rungs_apart_is_NOT_resolved` |
| M-E3 不可分辨的格照樣算比值 | `test_an_unresolved_cell_produces_NO_ratio_at_all` |
| M-E4 `none` 的取樣誤差報成 0.0 | `test_the_none_group_is_n_a_and_is_NOT_zero` |
| M-E5 圖二把 `none` 畫成零高度的 bar | `test_the_none_group_is_drawn_as_n_a_and_NOT_as_a_zero_bar` |
| M-E6 圖一用沒有任何一臂讀到的平均當標籤 | `test_an_unresolved_cell_is_marked_and_shows_BOTH_arm_values` |
| M-E7 shot-noise 預測用 sd 不用 median\|X\| | `test_the_shot_noise_prediction_is_the_registered_formula` |
| M-E8 計數器全零也宣稱「樣本掉了」 | `test_sample_loss_is_NOT_attributed_when_every_drop_counter_is_zero` |
| M-E9 視窗前就活著的行程被算進整段生命期 CPU | `test_a_process_alive_before_the_window_is_not_charged_its_lifetime` |
| M-E10 samples/s 用 offered rate 推不用讀計數器 | `test_samples_per_second_comes_from_the_rung_pair_not_from_the_offered_rate` |
| M-E11 散佈大於效應照樣擬合（拿掉 H-C0） | `test_a_delta_smaller_than_its_spread_is_H_C0_and_no_line_is_fitted` |
| M-E12 混合分解沒有自己的分支 | `test_the_cpu_verdict_names_a_mixed_decomposition_as_a_result` |
| M-E13 負載閘改成跨組比全域中位數 | `test_the_gate_is_within_group_so_the_link_treatment_does_not_fire_it` |
| M-E14 對帳 (a) 砍掉條件對齊的 cooperative 配對 | `test_a_is_reported_for_BOTH_the_none_and_the_cooperative_cell` |
| M-E15 產生器控制的 5× 改成 1× | `test_a_sender_control_below_five_times_FAILS` |
| M-E16 對帳 (b) 對錯 08-20 的數字 | `test_b_compares_the_marginal_slope_against_08_20s_206_microseconds` |
| C-E1 加一行註解（控制） | 必須全綠——是 |
| C-E2 改一個 comprehension 變數名（控制） | 必須全綠——是 |

🔴 **閘門第一次跑就抓到一件真的事**：M-E10 **SURVIVED**——fixture 給兩組同樣的取樣率、又沒有背景流量，
於是「讀計數器」與「用 5 × pps / 256 推」在那份資料上是同一個函式，變異等價。
fixture 已改成給 `link` 它真的多出來的那一個 host-facing egress 濾器、外加 LLDP／ARP 的背景樣本，
變異就死了。**與受測碼一致的 fixture 什麼都沒證明**，這是那條教訓的後半段。

---

## 3. `drive_e.sh --dry-run` 的輸出（逐字）

```
### DRY RUN -- drive_e.sh   (nothing is started, no fabric is built, nothing is written)

owner               p3-E
repo                /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919
raw                 /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/doc/audit/2026-09-19_telemetry-three-groups/raw/2026-09-18T220221Z_full
hosts               4   (ndt up p4 4 --telemetry <group>)
selection           everything: C1 C2 C3 then G1..G6
settle              60s after bring-up, 20s between arms

controls (run once, inside G1, BEFORE any measurement arm -- PREREG 4.3):
  C1  generator ceiling at 64 B frames    h1 -> h1 loopback, not through bmv2, 3 reps
      requirement: >= 5x the highest 64 B pps this round measures through bmv2
  C2  generator ceiling at 1024 B frames  same, -l 982, 3 reps
  C3  the external gate has a positive control: two throwaway ladders (1 2 3 5 8 12 kpps),
      one clean and one with 4 CPU burners from rung 4. external must step up, and
      the gate must reject the burner arm. If it does not fire, the round does not start.

generations:
  G1  none         pass a   arms: none_f64_a  none_f1024_a  
      + sampling-error block: 3 passes over the rates, middle one reversed
        2 20 100 | 100 20 2 | 2 20 100  Mbit/s, 8s each
  G2  cooperative  pass a   arms: cooperative_f64_a  cooperative_f1024_a  
      + sampling-error block: 3 passes over the rates, middle one reversed
        2 20 100 | 100 20 2 | 2 20 100  Mbit/s, 8s each
  G3  link         pass a   arms: link_f64_a  link_f1024_a  
      + sampling-error block: 3 passes over the rates, middle one reversed
        2 20 100 | 100 20 2 | 2 20 100  Mbit/s, 8s each
  G4  link         pass b   arms: link_f1024_b  link_f64_b  
  G5  cooperative  pass b   arms: cooperative_f1024_b  cooperative_f64_b  
  G6  none         pass b   arms: none_f1024_b  none_f64_b  

teardown on EVERY path (including abort):
  ndt down  ->  rm /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/p4_proxy/mininet/telemetry_override (absent = auto)  ->  restore /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/p4_proxy/mininet/host_count_override bytes  ->  ndt release

the exact commands, per generation:
  NDT_OWNER=p3-E /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/tools/test_workflow/ndt claim 600 "P3-E three-group telemetry round"
  NDT_OWNER=p3-E /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/tools/test_workflow/ndt up p4 4 --telemetry <group>
  NDT_OWNER=p3-E /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/doc/audit/2026-09-19_telemetry-three-groups/sample_error.sh --group <group> --rate <R> --window p<pass> --out <run>/<gen>/se_<group>_<R>M_p<pass>
  NDT_OWNER=p3-E /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/doc/audit/2026-09-19_telemetry-three-groups/run_group_arm.sh --group <group> --frame <F> --arm <group>_f<F>_<pass> --out <run>/<gen>/<arm>
  NDT_OWNER=p3-E /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/tools/test_workflow/ndt down
  rm -f /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/p4_proxy/mininet/telemetry_override ; restore /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/p4_proxy/mininet/host_count_override ; NDT_OWNER=p3-E /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/tools/test_workflow/ndt release

and then, offline:
  /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/doc/audit/2026-09-19_telemetry-three-groups/analyse.py --raw <run> --out <run>/summary.json
  /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/doc/audit/2026-09-19_telemetry-three-groups/plot.py --summary <run>/summary.json --out /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/doc/audit/2026-09-19_telemetry-three-groups

refusals checked before anything starts:
  /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/p4_proxy/mininet/telemetry_override absent, good
  /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919/p4_proxy/mininet/app_package_override absent, good
  /tmp/ndtwin_link_telemetry.json                                        absent, good
  lab.claim owner/measuring, and root reachable without a prompt
```

---

## 4. orchestrator 要跑的 live 清單（逐行）

### 4.0 開跑前必須成立（任一不成立就別跑）

```bash
# A 已併回且 kernel 已用 guard 重建；B、C 已併回；D 的 `--telemetry` 已在 trunk
test -x tools/test_workflow/ndt
/usr/bin/grep -q -- '--telemetry' tools/test_workflow/ndt        # D 的旗標在不在
test ! -e p4_proxy/mininet/telemetry_override                    # 三個都必須不存在
test ! -e p4_proxy/mininet/app_package_override
test ! -e /tmp/ndtwin_link_telemetry.json
sha256sum build/bin/ndtwin_kernel                                # 記下來；每一臂會自己再記一次
```

`drive_e.sh` 自己會再檢一次這三個檔並拒跑；上面是給人看的。

### 4.1 先看計畫（不動任何東西）

```bash
NDT_OWNER=p3-E doc/audit/2026-09-19_telemetry-three-groups/drive_e.sh --dry-run
```

### 4.2 整輪（長跑，包 setsid；估 3–5 小時，6 次 bring-up）

```bash
cd /home/adam/Desktop/NDTwin-Kernel
setsid env NDT_OWNER=p3-E doc/audit/2026-09-19_telemetry-three-groups/drive_e.sh \
  > scratch/overnight-2026-09-05/logs/gates-0910/p3E-drive.log 2>&1 &
```

它自己 `ndt claim`（預設 600 分鐘、帶 `NDT_MEASURING`），六個世代跑完後
`ndt down` → 移除 `telemetry_override` → 還原 `host_count_override` → `ndt release`；
**每一條 abort 路徑都走同一段**。最後一行是 `PASS P3-E ...` 或 `FAIL P3-E -- <n> problem(s)`。

### 4.3 重跑單一世代或單一控制（PREREG §7 的重跑規則要用）

```bash
NDT_OWNER=p3-E doc/audit/2026-09-19_telemetry-three-groups/drive_e.sh --only G4
NDT_OWNER=p3-E doc/audit/2026-09-19_telemetry-three-groups/drive_e.sh --only C3
```

🔴 **重跑只在 PREREG §7 列的作廢條件下做**，而且兩次的值都要留著、寫進 FINDINGS 的重跑表。
「數字不討喜」不是重跑理由（①b §1.3）。

### 4.4 分析與圖（離線，不需要 fabric）

```bash
RUN=doc/audit/2026-09-19_telemetry-three-groups/raw/<那次的 UTC 目錄>
p4_proxy/venv/bin/python doc/audit/2026-09-19_telemetry-three-groups/analyse.py --raw "$RUN" --out "$RUN/summary.json"
# 圖需要 matplotlib，venv 沒有；用 /home/adam/miniconda3 的 python3：
python3 doc/audit/2026-09-19_telemetry-three-groups/plot.py --summary "$RUN/summary.json" \
        --out doc/audit/2026-09-19_telemetry-three-groups
# 想先看圖上會有什麼、不畫：
p4_proxy/venv/bin/python doc/audit/2026-09-19_telemetry-three-groups/plot.py --summary "$RUN/summary.json" --check
```

### 4.5 填 FINDINGS 與收 raw

1. `FINDINGS.md` 的每一格**只從 `summary.json` 抄**。
2. raw（`raw/<UTC>_full/**`）進 `audit-raw`；`.gitignore` 的 `doc/audit/**/raw*/*` 已經擋著工作分支。
3. 三張圖 `.png`＋`.pdf` 進 `doc/audit/2026-09-19_telemetry-three-groups/`。

### 4.6 離線閘門（併回前跑，不需要 fabric）

```bash
p4_proxy/venv/bin/python -m unittest discover \
  -s doc/audit/2026-09-19_telemetry-three-groups/tests -t doc/audit/2026-09-19_telemetry-three-groups/tests
doc/audit/2026-09-19_telemetry-three-groups/tests/mutate_analyse.sh
```

---

## 5. 沒做／沒驗的（明列）

1. **一臂都沒跑。** 本檔所有數字都是離線的（語法、單元測試、變異閘、合成 raw 的端到端）。
   `run_group_arm.sh`／`sample_error.sh` 的 live 路徑（`sudo -n mnexec`、iperf3、真的 `switch_state`）
   **從未執行過**——dry-run 印的是指令，不是執行結果。
2. **`--telemetry` 旗標沒看過。** D 還沒併回 trunk；我照 §2.1／§2.7 的契約寫，
   `drive_e.sh` 呼叫 `ndt up p4 4 --telemetry <word>`。D 併回後若旗標拼法不同，改一行。
3. **`get_sflow_stats` 的 `samples_by_family`／`malformed_ipv4_ihl` 我沒看過碼**（worker A 未併）。
   分析器在頂層與 `telemetry_health` 兩層都找、並記下在哪一層找到，找不到寫 `absent` 不寫 0。
4. **emitter 統計行的欄位名**取自 B 已併入的 `psample_sflow_emitter.py:342-361`（讀過碼），
   但那一行**沒有在 live 看過**。
5. **C3 的門檻是自己跟自己比**（同一輪兩支短梯子，一支帶 burner），不是跟後面才會存在的組中位數比；
   註冊的組內判準由 `analyse.py` 在收工後再算一次。
6. **圖的視覺只在合成資料上看過**（三張都畫出來、讀過），真資料的刻度密度沒看過。
7. **沒有跑 `merged_checks.sh`**——它是併回時的閘門，而我這一輪沒有動任何被它涵蓋的檔案
   （全部新增在 `doc/audit/2026-09-19_telemetry-three-groups/**`）。要不要跑由 orchestrator 決定。

---

## 6. 異議與要注意的事

1. 🔴 **磁碟只剩 1.4 G（整顆 `/dev/nvme0n1p5` 98 G 用掉 92 G、99%）。** 我寫檔時撞到一次 ENOSPC
   （`/tmp/claude-1000` 與 `/home` 同一個檔案系統）。本輪要 6 次 `ndt up`＋12 臂的 iperf3 JSON
   ＋12 份 cpu.jsonl ＋ bmv2 的 log，**跑之前先確認空間**，不然會在半夜某一臂靜靜寫失敗。
   我沒有刪任何不屬於我的東西。
2. **`cpu_probe.py` 我沒有動**（工單允許「在需要時」動）。理由寫在 PREREG §3.5 的方框：
   它的 `TARGETS` 用 cmdline 子字串配對，而 emitter 的 cmdline 不含它任何一個 needle
   ⇒ `link` 組的處理成本會讀成零；proxy 與 emitter 都是 `python3`，comm 分不開，而兩者的 pid
   都有權威來源。改用本目錄的 `cpu_arm_probe.py`。
3. **`sample_error.sh` 沒有呼叫 `ndt check`**，而是抄它的式子（`ndt:6150-6240`，逐行對照過）。
   理由三條寫在腳本檔頭與 PREREG §3.4：它的輸出是散文、它在 `measuring=` 有值時拒跑、
   它只吐一個比值。**若日後 `ndt check` 的積分改了，這支要跟著改**——這是一個已知的雙實作，
   明寫在這裡而不是留著。
4. **對帳 (a) 報兩格**（`none` 與 `cooperative`），orchestrator 已核准並補充了確認：
   08-28 跑的是標準 `ndt up p4` stack，proxy 一定寫 clone session，沒有關掉取樣的路徑
   ⇒ 那六臂是合作式取樣的臂。**條件對齊的配對是 `cooperative`**，工單指名的 `none` 照報。
5. **每組只有兩個 fabric 世代**（6 次 bring-up 而不是 12 次）是成本取捨不是控制，
   PREREG §4.1 用同樣的字寫了它控制不到什麼。要更乾淨就改成一臂一世代，只需改 `drive_e.sh` 的迴圈。
6. **task list**：subagent 沒有 `TaskCreate`／`TaskUpdate` 工具，E 的進度要由 orchestrator 掛上去。

**[Co-developed with claude code -- Adam]**

---

# Live-fix round（ruling 21，2026-09-19 14:4x）

**head**：`8d04e130`（`feat/p3-three-groups-0919`，已 `git merge trunk`＝`cbc968d8`，我的檔案無衝突）。
一樣沒 sudo、沒 `ndt up`、沒碰 lab、沒 Mininet。

```
 .../2026-09-19_telemetry-three-groups/drive_e.sh   | 157 +++++++++-
 .../tests/hazard_scan.py                           | 116 +++++++
 .../tests/mutate_analyse.sh                        |  53 ++++
 .../tests/test_drive_e_offline.sh                  | 337 +++++++++++++++++++++
 4 files changed, 651 insertions(+), 12 deletions(-)
```

## 修了三個，兩個是 ruling 21 點名的，第三個是同一份 raw 自己說的

### ① `ndt verify_p4` 不是 subcommand（ruling 21①）

`ndt` 的 dispatch 是 up／down／status／check／clean／apps／ntg／claim／release（`ndt:10035-10077`）；
不認得的字就印 usage、exit 2——`G1/11_verify.txt` 整份就是那段 usage。**rc 2 沒人讀**，
所以每個世代中間坐著一個不會過也不會不過的檢查。

換成**兩個讀數，而且故意不給同樣的權威**：

- **硬閘 ＝ `ndt up` 自己印的 [3/3]**，從 `10_up.txt` 解出來。它是這台機器上唯一在 bring-up
  **逐台交換機**斷言遙測來源的東西（`ok  telemetry: none -- 0 cooperative, 0 link, 10 none;
  the proxy agrees switch by switch`），而「組」是本輪每一個數字的索引。**字樣不是猜的**，
  是從真的跑過那一代的 `raw/2026-09-19T062206Z_full/G1/10_up.txt:26-29` 抄的。
  再加 `data plane: ... forwards` 一行。
- **記錄但不當閘 ＝ `ndt status --check`**（真的存在的那個獨立複檢：拿 live lab 比
  `.test_run/up.target` 的 plane／host count／kernel graph／model sha256；rc 0 相符、1 不符、
  **3 ＝什麼都沒比**）。rc 與整份報告寫進 `11_verify.txt`，**rc 3 寫成「什麼都沒比」，絕不寫成通過**——
  但**不**讓它擋世代，因為我從沒看過它對著 `--telemetry` fabric 的輸出，而「把沒驗證過的期望變成硬閘」
  正是 ruling 21① 這件事本身。組在每一臂、每一個視窗還會再從 `/p4/switch_state` 證一次（PREREG §2）。

### ② `set -u` 的 `local` 陷阱（ruling 21②）

`local id="$1" frame="$2" payload=$((frame - 42)) out=...`——bash **先展開整行所有右手邊、再做任何賦值**，
所以 `frame` 還沒被指定就被 `$((frame - 42))` 讀 ⇒ `unbound variable`、shell 當場死。拆成一行一個名字。
和 D 在 live-p1/05、06 找到的同一個形狀（ruling 9 / 12d），第三次出現。

🔴 **D 的掃描器抓不到這一個**：它找 `$name`，而 `$(( ))` 裡的名字**前面沒有 `$`**。
`tests/hazard_scan.py` 兩種形狀都抓，兩種都有陽性對照，拆開寫的是陰性對照。

### ③ ruling 21 沒點名，但 `90_down.txt` 就是證據：`ndt down` 在 `measuring=` 還掛著時拒絕（rc 5）

而宣告 `measuring=` 的就是這支 driver。**本來要把 lab 留乾淨的那一輪，把 fabric 留在上面。**

修法**不是 `--force`**：`--force` 連 `in_flight` 的行程檢查也一起跳過，而那是唯一還能說真話的讀數；
一支在每條路徑上都硬闖 guard 的腳本＝把 guard 拆了。改成 driver **自己收回自己的宣告**
（照 `ndt` 自己建議的 `ndt claim <mins>` 重宣告、不帶 `NDT_MEASURING`），然後跑一般的 `down`——
它**仍然**會在真的有行程在跑時拒絕。收回之後還被拒的 `down` 會被記成 failure 並印出要手跑的指令，**不代跑**。

## 每一格怎麼被看到紅的

`tests/test_drive_e_offline.sh`：用 stub `ndt`（答 claim／up／status --check／down／release，
其餘一律印 usage ＋ rc 2，跟真的一樣）、stub 兩支臂腳本、`sudo`／`ps` 的 PATH shim，
把**真的 drive_e.sh**（cell 1 比 sha256 證明是同一份）跑**完整一輪**。**33 格。**

**紅跑：拿 `ce1b2207` 的 drive_e.sh（sha256 `9f93eca2…`）跑同一份測試**——
`E_DRIVER=<old> tests/test_drive_e_offline.sh`，log：`scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-livefix/offline-RED-prefix-ce1b2207.log`

```
  FAIL  🔴 verify_p4 is never invoked
        must NOT contain: verify_p4
  FAIL  🔴 C1 ran (the set -u local hazard would have killed the shell here)
        expected to contain: C1: generator ceiling at 64B frames
        got: 
  FAIL  🔴 every teardown is preceded by a claim that retracts measuring=
        want: 7
        got:  0
passed: 13   failed: 13
```

同樣兩格也常駐在測試裡（§7：把每個缺陷放回副本、斷言對應的格變紅），所以「綠」不可能是
「測試看不見它」。變異閘再加三顆：M-E17（把 `ndt verify_p4` 放回）、M-E18（把四個 `local` 併回一行）、
M-E19（拿掉收回宣告）——**全部被殺**。

## 閘門（head `8d04e130`）

| 閘 | rc | 最後一行 | log |
|---|---|---|---|
| 單元測試（venv 直譯器） | 0 | `OK (skipped=1)` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-livefix/unit-venv.log` |
| 單元測試（python3，有 matplotlib） | 0 | `OK` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-livefix/unit-py3.log` |
| `test_drive_e_offline.sh` | 0 | `passed: 33   failed: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-livefix/offline-green.log` |
| 同上，對 `ce1b2207` 的 driver | **1** | `passed: 13   failed: 13` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-livefix/offline-RED-prefix-ce1b2207.log` |
| `mutate_analyse.sh` | 0 | `mutations: 19   survivors: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-livefix/mutate.log` |
| `check_gate_anchors.py HEAD` | 0 | `115/115 cells ok` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-livefix/check_gate_anchors.log` |
| `hazard_scan.py` × 三支腳本 | 0 | 零行（乾淨） | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-livefix/hazard-scan.log` |
| 三支 `--dry-run` | 0 / 0 / 0 | — | — |

⚠️ `check_gate_anchors.py` **看不到我這個閘**：它只掃 `tests/shell/`（該檔 `:1222`），
而我的閘在 `doc/audit/.../tests/`。上面那個 115/115 證的是**我這支分支沒有弄壞 repo 既有的閘**，
不是「我的閘被它檢查過」。

## 兩件閘門在我自己身上抓到的（同一條教訓）

1. 🔴 **M-E19 第一次跑就 SURVIVED。** 我的收回檢查只問「`down` 前一個呼叫有沒有 `measuring=<unset>`」——
   而 `up` 也是 `<unset>`（`NDT_MEASURING` 是只掛在 claim 那一個呼叫上的前綴賦值），
   **那一格在兩個世界都是綠的**。現在要求前一行必須是 `^claim`。這是 M-E10 在第二個地方：
   **分不出兩個世界的斷言不是斷言。**
2. **離線測試真的因為 `/tmp/ndtwin_link_telemetry.json` 失敗一次**——那是拒跑規則正確觸發，
   但那個檔是這台機器上別的東西在我寫測試中途建的（14:32、root、7484 B）。測試不該依賴機器狀態 ⇒
   `LT_MANIFEST` 指進 sandbox，而那條拒跑規則自己拿到一格（§7b：rc 2、什麼都沒 claim）。

另外記一筆：**EXIT trap 在 shell 死掉時照樣跑**，所以壞掉的 driver **仍然印了 verdict 行**。
「有沒有印 verdict」這種檢查在那一輪會是綠的——所以格子問的是**有沒有 PASS**、**有沒有任何控制跑過**。

## 這一輪仍然沒做的

- **還是一臂都沒跑。** stub 之下走過的是 driver 的控制流，**不是** `sudo -n mnexec`／iperf3／
  真的 `switch_state`；那些路徑仍然從未執行過。
- `ndt status --check` 對 `--telemetry` fabric 的實際 rc **沒看過**——所以它是記錄不是閘（見 ①）。
- commit message 的署名用系統指示的 `Co-Authored-By: Claude Opus 5 (1M context)`，
  與你訊息裡的 `Claude Opus 5` 不同；前三個 commit 用的是後者。要統一我可以 rebase 改寫。

**[Co-developed with claude code -- Adam]**

---

# Round 2（ruling 22，2026-09-19 15:1x）

**head**：`6e67431a`（已 merge trunk `324286ba`）。一樣沒 sudo、沒 `ndt up`、沒碰 lab、沒 Mininet。
diffstat：`drive_e.sh` +47／`hazard_scan.py` +14／`mutate_analyse.sh` +20／`test_drive_e_offline.sh` +213。

## 22① `ndt status --check` rc 1 是判決，不能和 `PASS P3-E` 並存

rc 1 是 `ndt` 自己文件化的話：「compared against the last 'ndt up': dataplane, fabric hosts,
kernel graph, topology file」，不符就印 `check: N problem(s)` 與清單（`ndt:6468-6475`）。
它能點名的問題包含 **data plane 不通、host count 不是本輪要的那個、kernel graph 變了、
model sha256 變了、link telemetry emitter DEAD、pipeline 過期**——每一個都讓該世代的數字
不是它的組標籤說的那個東西。⇒ **rc 1 進 `FAILURES`、點名世代。**

🔴 **但不跳世代**：臂照跑、raw 照寫，因為「在一個被點名的問題底下量到的格」是關於那個問題的證據；
不准的是**整輪在它上面自稱 pass**。rc 3 維持記成「什麼都沒比」、不進判決；其它 rc 同理。

## 22② 每世代的 re-claim 改寫了 release 要比的那個 baseline（**本輪引入、本輪修掉**）

每一次 `ndt claim` 都跑 `record_round_baseline`，記的是**當下**的 knob（`ndt:844` → `:442-455`）。
`declare_measuring` 每世代 re-claim 一次來宣告／收回 `measuring=`，而那些 claim 發生在
`ndt up p4 4` 把 knob 改寫成 4 **之後** ⇒ 本輪「起始點」被悄悄記成 4。
`finish()` 還原 entry bytes 再 release，`cmd_release` 拿 baseline 比它看到的 knob（`ndt:885-894`）：
entry 不是 4 就**拒絕 rc 1 並把 claim 留在 lab 上**。今天 dormant 只因為這個 checkout 的 entry 也是 4，
主 checkout 一個 `git checkout -- p4_proxy/mininet/host_count_override` 就點燃。

修兩半：**(a)** 還原 knob 之後、release 之前再 `ndt claim` 一次，baseline 對上磁碟上真正的位元組；
**(b)** **release 被拒時真的進判決**。~~原本那個 `||` 測的是 sed 的狀態~~ ⚠️ **這句是錯的，
第三輪更正（ruling 24①）**：三個版本都 `set -uo pipefail`，所以那條 pipeline 的狀態**就是**
release 的，`||` **有**觸發、`bad` **有**印出 `!! 'ndt release' did not take`。真正的洞在下一行——
`bad()` 只寫 stderr（`bad() { printf '   !! %s\n' "$*" >&2; }`）、**不碰 `FAILURES`**，
而判決是 `FAILURES` 決定的：整輪把拒絕印出來、同一口氣自稱 PASS、claim 留在 lab 上。
現在 release 失敗進 `FAILURES`；第三輪並加了一格對舊 driver 釘住這個機制（見 Round 3）。

## 22③ 記錄

`hazard_scan.py`：找到東西 **exit 1**、沒東西可掃 **exit 2**、掃過且乾淨才 **0**——
原本無條件 exit 0，所以存下來的 `rc=0` 一點資訊都沒有。所有 log 都有檔頭（tree／head／時間／
掃了哪些檔／rc 的意思）＋結尾 `### rc=`；紅跑的檔頭寫了**舊 driver 的 sha256**；三種 `--dry-run` 各一份 log。

## stub `ndt` 改成有狀態（因為這些 bug 就是狀態的事）

`claim` 記 baseline（當下的 knob）與 `NDT_MEASURING`；`up p4 N` **像真的一樣改寫 knob**；
`down` 在 measuring 非空回 5、成功時清掉它；`release` 在 knob≠baseline 回 1。
**M-E19 因此從「用呼叫紀錄的斷言殺」變成「用行為殺」。**

## 離線測試 51 格（原 33）

新增：rc 1 不 pass 但**臂真的跑了（12 支、六個世代都起來）**；rc 3 記錄且仍可 pass；
entry knob ＝128 的一輪結束時 knob 回 128、baseline 重記成 128、lab 真的還回去；
強制 release 拒絕時整輪 **FAIL** 並說「THE LAB IS STILL CLAIMED」。

**紅跑（檔頭都寫了舊 driver 的 sha256）**

```
vs 8d04e130 (drive_e.sh sha256 cd151af61ef942d0…)   passed: 36   failed: 8
  FAIL  🔴 a generation whose status --check said rc 1 does NOT end in PASS
        must NOT contain: PASS P3-E
  FAIL    the failure names the generation and the rc
        expected to contain: G1: 'ndt status --check' rc=1
        got: none_f64_b                   none         20         ok
--
  FAIL    and it says the arms of that generation ran under it
        expected to contain: the arms of this generation ran under it
        got: none_f64_b                   none         20         ok
--
  FAIL  🔴 the release is not refused, so the lab is actually given back
        expected to contain: ok  released
        got: none_f64_b                   none         20         ok
--
  FAIL    the final claim re-recorded the baseline from the RESTORED value
        want: 128
        got:  4
  FAIL  🔴 a refused release means the round does NOT pass
        must NOT contain: PASS P3-E
  FAIL    and it says the lab is still claimed
vs ce1b2207 (drive_e.sh sha256 9f93eca253780…)      passed: 22   failed: 22
```

## 閘門（head `6e67431a`）

| 閘 | rc | 最後一行 | log |
|---|---|---|---|
| 單元測試（venv） | 0 | `OK (skipped=1)` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round2/unit-venv.log` |
| 單元測試（python3） | 0 | `OK` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round2/unit-py3.log` |
| 離線整輪（本 head） | 0 | `passed: 51   failed: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round2/offline-green.log` |
| 離線整輪（vs `8d04e130`） | **1** | `passed: 36   failed: 8` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round2/offline-RED-8d04e130.log` |
| 離線整輪（vs `ce1b2207`） | **1** | `passed: 22   failed: 22` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round2/offline-RED-ce1b2207.log` |
| 變異閘 | 0 | `mutations: 22   survivors: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round2/mutate.log` |
| `hazard_scan.py` | 0 | `3 file(s) scanned, 0 finding(s)` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round2/hazard-scan.log` |
| `check_gate_anchors.py HEAD` | 0 | `115/115 cells ok` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round2/check_gate_anchors.log` |
| `--dry-run` full／G3／C1／arm／window | 0×5 | — | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round2/dryrun-*.log` |

新變異 M-E20（rc 1 變回 note）、M-E21（拿掉最後那次 re-claim）、M-E22（release 被拒只印不進判決）——**全殺**。

## 路上抓到的一個測試 bug

兩個新格子一開始被插進 `E_DRIVER` guard 的 **`else` 分支**裡，所以第一次紅跑跳過它們、回報 29/0——
**那個綠的意思是「沒跑」。** 已移到 guard 之前。這和 M-E10、M-E19 是同一條：
**分不出兩個世界的斷言不是斷言，而沒跑到的格子連斷言都不是。**

## 22④ 候選（記錄，本輪未做）

閘失敗後斷言臂沒跑；`--only C*` 在 `fabric_up` 失敗後仍跑控制臂（`drive_e.sh:577`）；
`mutant()` anchor 漂移應該 rc 2 拒絕而不是算成 SURVIVED；[3/3] 的計數對帳；
rc 5 的訊息不該對「別人的 claim」建議 `--force`。

## 仍然沒做的

**還是一臂都沒跑。** stub 之下走過的是 driver 的控制流與它對 `ndt` 契約的使用，
**不是** `sudo -n mnexec`／iperf3／真的 `switch_state`／真的 `ndt`。
`ndt status --check` 對 `--telemetry` fabric 的實際 rc 仍然沒看過——所以 rc 1 進判決、
rc 3 與其它只記錄，這個不對稱是刻意的。

**[Co-developed with claude code -- Adam]**

---

# Round 3（ruling 24，2026-09-19 16:0x）

**head**：`e1fa63ea`。沒 sudo、沒 `ndt up`、沒碰 lab、沒 Mininet。離線測試 **63 格**（原 51）。

## 24① 我對舊 release 缺陷的說明是錯的——更正寫進碼、測試與本檔

三個版本都 `set -uo pipefail`（`drive_e.sh:49`）⇒ 那條 pipeline 的狀態**就是** release 的，
`||` **有**觸發、`bad` **有**印出 `!! 'ndt release' did not take`。
洞在下一行：`bad() { printf '   !! %s\n' "$*" >&2; }`——**只寫 stderr、不碰 `FAILURES`**，
而判決由 `FAILURES` 決定。整輪把拒絕印出來、同一口氣自稱 PASS。
**Round 2 那段敘述已在本檔 §Round 2 就地更正（劃掉並標註）。**
新增一格對舊 shape 釘機制：強制 release 拒絕 ⇒ **訊息有印** 且 **仍然 PASS**，兩件事同時斷言。

## 24③（BLOCKING）knob 沒放回去就不准 PASS

Round 2 那個「還原後再 claim 一次」讓 `cmd_release` 的 knob 檢查**恆真**：
`restore_host_knob` 的 `cp` 失敗（這台今天撞過 ENOSPC）⇒ knob 還是 4 ⇒ 再 claim 把 baseline 記成 4
⇒ release 比 4==4 放行 ⇒ **整輪 PASS，而 knob 留在 `ndt up p4 4` 寫的值**，那正是下一輪
`ndt up p4` 唯一會讀的東西。修：**還原失敗進 `FAILURES`**，而且**還原失敗就不再 claim**。
⚠️ **後半句的理由在第四輪被更正（ruling 25②）**：`finish()` 先跑 `teardown_fabric "final"`，
那裡面的 `declare_measuring off` 已經 `ndt claim` 過一次、把 baseline 記成**還原前**的 knob（4），
**在 `restore_host_knob` 之前**。所以還原失敗時 baseline 本來就是 4、release 比 4==4 照樣放行——
`cmd_release` **保護不了這一輪**，唯一讓判決誠實的是那個 `FAILURES+=`。
不再 claim 是**衛生**（不要再宣告一個自己知道是錯的起點），**不是保護**。
測試用 PATH 上的 `cp` shim 只讓那一個目的地失敗（不是 mock 回傳值，也不是跟執行中的 round 搶 chmod）。

## 24④ 打不開的檔不是乾淨的檔

`except OSError: continue` 把它算成 scanned、rc 0——違反這支腳本自己檔頭寫的「0＝掃過且乾淨」。
現在：計為 unreadable、印檔名、**rc 2**，而且 **2 蓋過 1**（掃不完就不能宣稱「沒找到」，
同一條規則等同「缺的計數器不是 0」）。

## 24② M-E19 改由行為殺

`report_shell` 改成吃**多格**、**全部**都要紅：行為格（整輪不再 PASS）＋呼叫紀錄格（哪一個呼叫變了）。

## 24⑤ 記錄＋一個本來是「候選」的東西變成必須

`mutate.log` 補上其它 log 都有的檔頭與結尾 `### rc=`。commit 訊息裡的數字更正：
**紅跑是 22/22 不是 13/13、紅的是 8 格不是 2 格**（已填的 commit 不改寫，這裡更正）。

🔴 **M-E21 在本輪第一次跑閘門時 SURVIVED——而那是假的。** 它的 anchor 正是我這一輪剛改寫的
release 區塊，apply 步驟的 assert 失敗、副本**完全沒被變異**、測試當然全綠，而閘門把這個印成
「SURVIVED」＝一個關於測試的證據。**恰恰相反：沒有做出任何變異，就沒有判決可給。**
⇒ `mutant()`／`mutant_tests()` 回 `DRIFT`、兩個 reporter 拒絕給分、閘門
**`REFUSING A VERDICT` 並 exit 2**（不是 0 也不是 1）。
在丟棄用的副本上把 M-E7 的 anchor 故意打壞驗過：`mutations: 24  survivors: 0  drifted: 1`、`rc=2`。

另外採用 24⑤ 的一個候選：最後那次收回改用 **`FINAL_CLAIM_MINUTES`＝10 分鐘**，
不再用 `CLAIM_MINUTES`＝600——release 被拒時不會再把 lab 多鎖十小時。

## 閘門（head `e1fa63ea`；log 都有檔頭與 `### rc=`）

| 閘 | rc | 最後一行 | log |
|---|---|---|---|
| 單元測試（venv／python3） | 0／0 | `OK (skipped=1)`／`OK` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round3/unit-venv.log`、`unit-py3.log` |
| 離線整輪（本 head） | 0 | `passed: 63   failed: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round3/offline-green.log` |
| 離線整輪 vs `8d04e130` | **1** | ~~`passed: 40 failed: 11`~~ ⚠️ 見下 | 第四輪更正 |
| 離線整輪 vs `ce1b2207` | **1** | ~~`passed: 26 failed: 25`~~ ⚠️ 見下 | 第四輪更正 |

⚠️ **上面兩格的 failed 數是錯的（ruling 25①，第四輪更正）**：7c 那一格當時落在 `E_DRIVER` guard
的 `fi` **之後**，對舊 driver 它的重建 anchor 找不到、`driver.sh` 根本沒產生 ⇒ **有 3 格是 harness
錯誤、不是缺陷紅**。真正的數字是 **40 ok / 8 缺陷紅 / 3 harness**、**26 / 22 / 3**。
第四輪把 7c 移進 else 分支後重跑，harness 錯誤歸零（見 Round 4 表）。
| 變異閘 | 0 | `mutations: 25   survivors: 0   drifted: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round3/mutate.log` |
| `hazard_scan.py` | 0 | `3 given, 3 scanned, 0 unreadable, 0 finding(s)` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round3/hazard-scan.log` |
| `check_gate_anchors.py HEAD` | 0 | `115/115 cells ok` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round3/check_gate_anchors.log` |
| `--dry-run` ×5 | 0×5 | — | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round3/dryrun-*.log` |

新變異 M-E23（還原失敗又被 `|| true` 吞掉）、M-E24（knob 沒回去還是再 claim）、
M-E25（打不開的檔算成乾淨）——**全殺**。

## 記錄但沒做（24⑤ 候選餘下）

只讓**一個**世代回 rc 1 的格（把 `$gen` 寫死的變異要死）；`die` 在 trap 裝好之後經 `finish`
變成 exit 1，與檔頭寫的「2＝refused」不符；[3/3] 的計數對帳；rc 5 訊息不該對「別人的 claim」
建議 `--force`。

## 仍然沒做的

**還是一臂都沒跑。** stub 走過的是 driver 的控制流與它對 `ndt` 契約的使用，
不是 `sudo -n mnexec`／iperf3／真的 `switch_state`／真的 `ndt`。
`ndt status --check` 對 `--telemetry` fabric 的實際 rc 仍沒看過——所以 rc 1 進判決、
rc 3 與其它只記錄，這個不對稱是刻意的。

**[Co-developed with claude code -- Adam]**

---

# Round 4（ruling 25，2026-09-19 17:0x）

**head**：`a3a51548`。沒 sudo、沒 `ndt up`、沒碰 lab、沒 Mininet。離線 **65 格**，新增姊妹檔 **14 格**。

## 25① 紅跑的數字裡混了 harness 錯誤

7c（重建舊 release 形狀那一格）當時落在 `E_DRIVER` guard 的 `fi` **之後** ⇒ 對舊 driver，
它的重建 anchor（`# Only re-claim when the knob really went back.`）找不到、`driver.sh` 沒產生、
**3 格是 harness 錯誤不是缺陷紅**。已移進 else 分支（和其它 pre-fix 控制同一處）並重跑：
**harness 錯誤歸零**，兩個紅跑現在是純缺陷紅 **8** 與 **22**。Round 3 表已就地更正。

## 25② `cmd_release` 保護不了這一輪——我第三輪的理由是錯的

`finish()` 先跑 `teardown_fabric "final"`，裡面的 `declare_measuring off` 已經 `ndt claim` 一次，
`record_round_baseline` 把 host_count 記成**當下**的 knob（4）——**在 `restore_host_knob` 之前**。
所以還原失敗時 baseline 早就是 4、release 比 4==4 照樣放行。**唯一讓判決誠實的是 `FAILURES+=`。**
不再 claim 是**衛生不是保護**。碼裡的註解、測試那一格的措辭、本檔 Round 3 那句都改了。

**M-E24 退役**：`if (( knob_restored ))` → `if true` **行為完全相同**（baseline 早就寫好了），
只被一條訊息字串殺，而它的標籤「release guard vacuous」正是同一個錯推理。
**同號換成有真實效果的變異**：最後那次收回改回用 `CLAIM_MINUTES`（600）而不是 `FINAL_CLAIM_MINUTES`（10）
——release 被拒時把 lab 多鎖十小時的就是它——由新格子殺（從 stub 的呼叫紀錄讀最後一個 `claim`，要求 `claim 10 `）。

## 25③ 閘門的兩條「拒絕」路徑現在有測試也有 log

`mutate_analyse.sh --self-test` 用**閘門自己的** `mutant()`／`report()`／`report_shell()` 跑
(a) 一個配不到的 anchor、(b) 一個真的套用但被對兩格回報、其中一格永遠不會紅的變異，然後斷言哪些路徑觸發了。
`tests/test_mutate_gate.sh` 是**姊妹檔不是 cell**（閘門每個 shell 變異都會跑 `test_drive_e_offline.sh`，
放在那裡會遞迴），斷言閘門**說了什麼**：rc 2、`REFUSING A VERDICT`、`DRIFT` 行、
partial-red 回報 `SURVIVED`、**整份只有一個 `### rc=`**、**沒有任何 `### rc=0`**。**14 格全綠。**

## 25④ 記錄面

`mutate.log` 只留**一個** `### rc=`（閘門自己寫的，wrapper 不再補第二個）；
`hazard-scan.log` 的 rc 圖例改成 2 的新意思（**掃不完**）；
閘門收工的 sha 對帳擴到 `drive_e.sh`、`hazard_scan.py`、`test_drive_e_offline.sh`。

## 閘門（head `a3a51548`；每份 log 都有檔頭與 rc）

| 閘 | rc | 最後一行 | log |
|---|---|---|---|
| 單元測試（venv／python3） | 0／0 | `OK (skipped=1)`／`OK` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/unit-venv.log`、`unit-py3.log` |
| 離線整輪（本 head） | 0 | `passed: 65   failed: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/offline-green.log` |
| 離線整輪 vs `8d04e130` | **1** | `passed: 40   failed: 8`（**8 全是缺陷紅、harness 0**） | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/offline-RED-8d04e130.log` |
| 離線整輪 vs `ce1b2207` | **1** | `passed: 26   failed: 22`（**22 全是缺陷紅、harness 0**） | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/offline-RED-ce1b2207.log` |
| 變異閘 | 0 | `mutations: 25   survivors: 0   drifted: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/mutate.log`（rc 標記恰好 1 個） |
| 閘門 self-test（拒絕路徑） | **2** | `drifted: 1`＋`REFUSING A VERDICT`＋`### rc=2`、**無 `rc=0`** | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/mutate-drift-selftest.log` |
| `test_mutate_gate.sh` | 0 | `passed: 14   failed: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/test_mutate_gate.log` |
| `hazard_scan.py` | 0 | `3 given, 3 scanned, 0 unreadable, 0 finding(s)` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/hazard-scan.log` |
| `check_gate_anchors.py HEAD` | 0 | `115/115 cells ok` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/check_gate_anchors.log` |
| `--dry-run` ×5 | 0×5 | — | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round4/dryrun-*.log` |

## 仍然沒做的

**一臂都沒跑。** stub 走過的是 driver 的控制流與它對 `ndt` 契約的使用，
不是 `sudo -n mnexec`／iperf3／真的 `switch_state`／真的 `ndt`。
`ndt status --check` 對 `--telemetry` fabric 的實際 rc 仍沒看過（所以 rc 1 進判決、rc 3 只記錄）。
24⑤ 剩下的候選也還在：只有一個世代回 rc 1 的格、`die` 經 `finish` 變 exit 1 與檔頭「2＝refused」不符、
[3/3] 計數對帳、rc 5 訊息不該對別人的 claim 建議 `--force`。

**[Co-developed with claude code -- Adam]**

---

# Round 5＋6（ruling 27／29，2026-09-19 17:4x–18:2x）

**head**：`e0549840`（round 5 ＝ `5e624599`）。沒 sudo、沒 `ndt up`、沒碰 lab、沒 Mininet。

## Round 5（ruling 27）：manifest 的 `argv` 是**一個字串**，逐項迭代拿到的是**字元**

campaign 17:31 真的開跑，第一臂 `none_f64_a` 量到**確認過的 30 kpps 天花板**，然後被標成
`invalid=no simple_switch binary in /tmp/ndtwin_p4_switches.json -- this arm cannot name what it measured`。
每一臂都會這樣。原因：`run_group_arm.sh` 對 `argv` 做 `for token in ... argv`，而

```
"argv": "LD_LIBRARY_PATH=/usr/local/bmv2-fast/lib /usr/local/bmv2-fast/bin/simple_switch_grpc -i 3@s1-eth3 ..."
```

是**一個字串** ⇒ 迭代出字元、永遠配不到。

🔴 **`raw/2026-09-19T093122Z_full` 的 `none_f64_a` 是「修前的參考值」，不是結果**——
那一臂自己把自己標成 invalid，PREREG §7 下它不能進任何格。

修：讀取搬進 **`manifest.py`**（字串 ⇒ `shlex.split`，list ⇒ 照收），**做成模組就是為了能測**。
fixture ＝ campaign 自己那份 `/tmp/ndtwin_p4_switches.json`，**逐位元組複製**（`cmp` 乾淨、十台）。
舊 stub 的 `argv` 是 **list**——正是程式假設的形狀——所以測試全綠而真跑必死：
**與程式假設一致的 fixture 什麼都沒證明**（M-E10／M-E19 的同一條，這次代價是一次 campaign 起跑）。

寫測試時又先抓到一個：`--log-file /tmp/simple_switch.log` 的 basename 也以 `simple_switch` 開頭。
規則補成「跟在選項後面的 token 是那個選項的**值**」＋「binary 的 basename 沒有點」。
另一個讀取（`pid`／`device_id`）**對著真檔查過**不是再假設一次，並把六個 key 全釘進測試。

## Round 6（ruling 29）：閘門打不開自己的 fixture；M-E27 是等價變異

**(1)** `5e624599` 的閘門 **baseline 是紅的、拒給判決**，所以 **M-E26 根本沒跑過**。
`copy_tree` 把 `tests/*.py` 複製進 mutant，但**沒複製 `tests/fixtures/`**。
**閘門拒絕是對的**（紅 baseline 上的變異什麼都不證明）。當時修法在我工作樹裡**沒 commit**——
所以同一個 sha 後來再跑看起來是綠的：**樹在 sha 底下變了**。已隨本輪 commit（`e0549840`）。

**(2)** **M-E27 是等價變異，沒有任何東西殺得了它**。它拿掉「跟在選項後面的是值」那條規則，
而它綁的格子用 `--log-file /tmp/simple_switch.log`——**另一條規則（basename 沒有點）早就擋掉了**。
量過不是推論：拿掉規則後 `switch_binary` 仍回 `/opt/x/simple_switch_grpc`。
不退役，改成**把那條規則真的測起來**：`test_a_DOT_LESS_option_value_is_still_not_the_binary`
用 `--log-dir /var/log/simple_switch_grpc`（**沒有點**），這時只剩那條規則擋著；
套上 M-E27 後回的是 `/var/log/simple_switch_grpc` ⇒ 格子變紅。
綁 `report`（unit）不是 `report_shell`——離線套件讀的是真 manifest，它的 `--log-file` 是
`/tmp/s1_bmv2.log`，**任何 shell 格子都看不到這件事**。
**這個變異綁錯了兩次才綁對，兩次都是同一個錯：把變異綁到一個不可能為它變紅的格子。**

**(3)** 措辭：離線 sandbox 註解說「one switch's object」⇒ 改成**十台、逐位元組**；
`manifest.py`／`test_manifest.py` 說 "verbatim" 但 fixture 曾被重新序列化（sort_keys）⇒
**改成逐位元組複製**，那個字現在是真的。

## 閘門（head `e0549840`）

| 閘 | rc | 最後一行 | log |
|---|---|---|---|
| 單元測試（venv／python3） | 0／0 | `OK (skipped=1)`／`OK` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round6/unit-venv.log`、`unit-py3.log` |
| 離線整輪 | 0 | `passed: 69   failed: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round6/offline-green.log` |
| 離線 vs `8d04e130`／`ce1b2207` | 1／1 | `40/8`、`26/22`（harness 0） | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round6/offline-RED-*.log` |
| 變異閘 | 0 | `mutations: 27   survivors: 0   drifted: 0`（**`caught M-E26`**、`caught M-E27`、rc 標記恰 1 個） | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round6/mutate.log` |
| 閘門 self-test | **2** | `drifted: 1`＋`REFUSING A VERDICT`、無 `rc=0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round6/mutate-drift-selftest.log` |
| `test_mutate_gate.sh` | 0 | `passed: 14   failed: 0` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round6/test_mutate_gate.log` |
| `hazard_scan.py` | 0 | `3 given, 3 scanned, 0 unreadable, 0 finding(s)` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round6/hazard-scan.log` |
| `check_gate_anchors.py HEAD` | 0 | `115/115 cells ok` | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round6/check_gate_anchors.log` |
| `--dry-run` ×5 | 0×5 | — | `scratch/overnight-2026-09-05/logs/orchestrator-0919/p3E-round6/dryrun-*.log` |

## 仍然沒做的

**一臂都沒跑完成過。** 17:31 那次是修前的、自我作廢的。
`ndt status --check` 對 `--telemetry` fabric 的實際 rc 仍沒看過（rc 1 進判決、rc 3 只記錄）。
24⑤ 剩下的候選仍在：只有一個世代回 rc 1 的格、`die` 經 `finish` 變 exit 1 與檔頭不符、
[3/3] 計數對帳、rc 5 訊息不該對別人的 claim 建議 `--force`。

**[Co-developed with claude code -- Adam]**

---

# Round 7（ruling 32，2026-09-19 20:0x–2x:xx）

**head**：`f51ee88f`（碼 `fc617c77` → harness 修 `5a6a9d80` → slice 斷言 `f51ee88f`）。
沒 sudo、沒 `ndt`、沒碰 lab、沒 Mininet、沒編譯任何 C++。
**閘門與紅跑全部在 orchestrator 說 GO 之後才跑**（GO 前這一輪只有編輯、`bash -n`、`py_compile`、
錨點計數——全部是毫秒級，campaign 在量 CPU 的那段時間本機沒有被我佔用）。

## 改了什麼

**① `analyse.py` 把 C3 的兩條丟棄式梯子當成量測臂。**
`controls/C3/{c3a_noburn,c3b_burn}` 由 `gate_control()` 寫出（`drive_e.sh:660-665`），
`group=none frame_bytes=1024`、`highest_clean_kpps=12`——**12 是六階梯子的頂，不是天花板**。
第四次 campaign 因此讀成 `none|1024 = 21.0* (12/12/30/30)`：格 unresolved（rung gap 2）、
兩個 1024 B 比值全成 H-A0、對帳 (a) 拿 21.0 去對 08-28 的 16.0；同一對臂還進了負載閘的
`none` 中位數（0.03665，**陽性對照把自己要驗證的門檻抬高了**）、CPU 擬合與 families／emitter 加總。

修法：`load_arm`／`walk_raw` 以**目錄**（`controls/` 底下）標 `control`，
`cell_table`、`external_gate`、`cpu_comparison`、加總一律排除，`summary.json` 另列 `control_arms`，
`render()` 印在自己的區塊。**為什麼選目錄不選 `ladder_kpps`**：目錄是這一輪**自己對這條臂的歸檔**
（`--out $RUN/controls/C3/<arm>`，而 driver 裡沒有別的東西寫進 `controls/`）；
用梯子判等於用「控制組剛好設了 `RATES_KPPS`」這個副作用去推論它的身分，
**一筆讀數的身分不是從它的數值推出來的**。理由寫在 `is_control_arm` 的 docstring。

**根因是 fixture**：`tests/synthetic.py::build` 從來沒寫那兩個目錄，所以沒有任何一格看得到這件事。
現在照 `gate_control()` 的形狀寫（burners 0／4、external 0.0538／0.2262、梯子 `1 2 3 5 8 12`、
clean 12），數值全部抄自 `raw/2026-09-19T105759Z_full/controls/C3/*/arm.meta`。
**舊 fixture 寫 12 個 `arm.meta`，這份寫 14 個**——與真 raw 一致。

**② `plot.py` 的 fig3 線尾標籤用「尾值散佈的 3%」判碰撞。**
那個量與圖無關：bmv2 面板三個尾值是 725.92／725.92／764.86，而軸是 −9.97..801.75，
`coop` 高出另兩條 38.9 個單位＝**約一個標籤高**，舊規則卻判「離很遠」給位移 0，
而 `none` 已經被往上推了 9 pt 進到那個位置。改成把尾值換算成**軸上的點數**，
相鄰標籤之間至少留一個標籤高；`_line_panels` 先 `tight_layout()` 再放標籤，
量的是**真的軸高與真的 ylim**（`axes.get_position()`／`get_ylim()`）。

**③ `drive_e.sh` 只要 `FAILURES` 空就印 `PASS P3-E`。**
一個從沒跑起來的 round 的 `FAILURES` 也是空的：第三次啟動被 SIGTERM 砍掉、零臂，
末行是 `PASS P3-E -- every selected arm produced a reading`
（`scratch/overnight-2026-09-05/logs/orchestrator-0919/drive_e-1854.log:67`）。
`finish()` 現在有兩個守衛：INT／TERM 各自的 trap 記下**是哪個訊號**，
以及**有讀數的 arm 目錄數 vs 選定臂數**（依 `--only` 算，而且是從 `GENERATIONS` 表算出來的，
不是寫死的 14——寫死就變成第二份「一輪包含什麼」的聲明）。

## 每一格怎麼被看到紅的（紅跑三份，全部在 `f51ee88f`）

**① `red-1-analyse-prefix.p3e-f51ee88f.log`**（pre-fix `analyse.py`＝`e0549840`＝`e2f4a7a3`，
本輪 fixture 與測試）⇒ `FAILED (failures=8, skipped=1)`。三顆被點名的格，逐字：

```
FAIL: test_the_none_1024_cell_is_the_two_ladder_arms_only
AssertionError: Lists differ: ['c3a_noburn', 'c3b_burn', 'none_f1024_a', 'none_f1024_b'] != ['none_f1024_a', 'none_f1024_b']

FAIL: test_the_none_group_gate_median_counts_the_ladder_arms_only
AssertionError: Lists differ: ['c3a_noburn', 'c3b_burn', 'none_f1024_a', [38 chars]4_b'] != ['none_f1024_a', 'none_f1024_b', 'none_f64_a', 'none_f64_b']

FAIL: test_a_for_none_is_the_ladder_cell_and_not_C3s_throwaway_ladders
AssertionError: Lists differ: ['c3a_noburn', 'c3b_burn', 'none_f1024_a', 'none_f1024_b'] != ['none_f1024_a', 'none_f1024_b']
```

另外五格同時紅，**這是污染的真實半徑、不是附帶損害**：
`test_the_two_C3_throwaway_ladders_are_found_and_tagged_as_controls`（`[] != ['c3a_noburn', 'c3b_burn']`：
舊碼根本沒有這個欄位）、`test_a_ratio_inside_one_realised_rung_is_H_A1` 與
`test_a_ratio_below_the_registered_interval_is_H_A2`（`none|1024` 被拉到 16.0 ⇒ 兩個 1024 B 比值都變了）、
`test_the_gate_is_within_group_so_the_link_treatment_does_not_fire_it`（`c3b_burn` 在舊碼下 **fires**）、
`test_a_uses_the_registered_interval_and_says_outside_is_not_a_refutation`。

**①b `red-1b-fixture-12-vs-14.p3e-f51ee88f.log`**：舊 fixture（`e0549840`）寫 **12** 個 `arm.meta`、
本輪 fixture 寫 **14** 個（多的兩個是 `controls/C3/c3a_noburn`、`controls/C3/c3b_burn`）；
本輪的 `test_every_arm_was_found_and_none_of_them_is_invalid`（斷言 14）對舊 fixture ⇒
`AssertionError: 12 != 14`。

> ~~這份 log 裡第一次嘗試是 harness 錯誤……已就地標示並用套件同款的 `discover` 重跑。~~
> 🔴 **round 8 更正（ruling 35④，判官點名）**：那次 harness 錯誤（`python -m unittest
> test_analyse....` 少了 `tests/` 在 `sys.path` 上 ⇒ `ModuleNotFoundError`）發生在 **`fc617c77`**
> 那一份，標示也只在那一份的末行（`red-1b-fixture-12-vs-14.p3e-fc617c77.log:72`）。
> **`f51ee88f` 的重跑只跑了正確的呼叫，整份 52 行裡沒有任何標示**——原句說「這份 log 裡」是錯的。
> 記在這裡是因為規則就是這條：**編不過／找不到／錯的測試紅一律算 harness 失效，不算結果。**

**② `red-2-plot-prefix.p3e-f51ee88f.log`**，兩半：
- (2a) `plot.py` 逐字退回 `e0549840`：舊規則**內嵌在 `_line_panels` 裡**，沒有函式可呼叫 ⇒
  `AttributeError: module 'plot' has no attribute 'end_label_offsets'`（`FAILED (errors=2)`）。
  這只證明函式是新的。
- (2b) 把**同一條舊規則**（3% of spread、±9 pt）移植進新函式（＝ M-E30 的替換逐字相同）⇒
  ```
  FAIL: test_three_ends_within_a_label_height_get_three_different_offsets
  AssertionError: 2 != 3 : height 160 pt: offsets {0.0, 9.0}
  ```
  三個標籤只拿到兩種位移：`link` 與 `coop` 都是 0，而它們在顯示上相差不到一個標籤高。
  **這才是行為紅**；遠離的那格（proxy+emitter 的三個尾值）在 (2b) 仍然綠，
  所以這個變異不是「什麼都染紅」。

**③ `red-3-driver-prefix.p3e-f51ee88f.log`**（`E_DRIVER` 指向 `e0549840` 的 `drive_e.sh`；
設了 `E_DRIVER` 時 §7 的 pre-fix 控制組依設計跳過）⇒ `passed: 50   failed: 7`，七格全在 6g／6h：

```
  FAIL  🔴 an interrupted round does NOT print PASS
        must NOT contain: PASS P3-E
  FAIL  🔴 an interrupted round says it was interrupted, and by which signal
        expected to contain: INTERRUPTED (SIGTERM)
  FAIL    and it exits 1, not 0
        want: 1   got:  0
  FAIL  🔴 a round that measured fewer arms than it selected does NOT pass
        must NOT contain: PASS P3-E
  FAIL  🔴 and the verdict says how many of how many
        expected to contain: 13 of 14 arms produced a reading
```

6h 的 `the round really is one arm short (13 readings on disk, not 14)` 在舊碼下**是綠的**——
樹上真的只有 13 個讀數，舊碼照樣印 PASS。那正是這個守衛要擋的東西。

## 🔴 一次 harness 失效，照實分類

`offline-round.p3e-fc617c77.log` 末行 `passed: 75   failed: 3`、rc 1。
**三格全是 harness 錯誤，不是被測碼的行為，也不是 survivor。**
根因（traceback 逐字：`File "<stdin>", line 6, in <module>` / `ValueError: substring not found`）：
§7(c) 的 pre-fix 控制組用文字切片把舊的 release 形狀種回去，而它的結束地標是
`'        fi\n    fi\n    printf '`——**block 自己的兩個 `fi` 加上剛好接在後面的那一行**。
ruling 32③ 的兩個守衛正好插在那個 `    fi` 與那個 `printf` 中間 ⇒ 切片找不到、`str.index` 丟例外、
`driver.sh` 沒被造出來，接著的 `grep`／`cp`／`chmod` 全噴 `No such file or directory`。

> orchestrator 讀 diff 時判的根因是「`trap finish EXIT INT TERM` 換成三行 trap 讓替換錨點消失」。
> **碼不是這樣**：§7 完全沒有指名 trap 那一行（指名它的只有 M-E31，錨點仍唯一）。
> traceback 指的是 heredoc 第 6 行，也就是 `tail_end = s.index(...)` 那一行。修的是那個地標。

修法（`5a6a9d80`，**重綁、沒刪、沒放寬**）：地標改成 block 自己的兩個 `fi`，
後面接什麼不是這格的事。**等效性是量出來的不是說出來的**（`anchor-equivalence-7c.p3e-f51ee88f.log`）：
舊控制組（`e0549840` 的 test 檔）對舊 driver（`e0549840`）、與本輪控制組對本輪 driver，
種出來的 release 處理**逐字相同、diff 空**：

```
        "$NDT" release 2>&1 | sed 's/^/   /' || bad "'ndt release' did not take -- run it by hand"
```

接著 `f51ee88f` 再補一刀：那個兩行 `fi` 的地標在檔案裡其實出現**兩次**（~~`gate_control` 的巢狀也以它結尾~~
🔴 **round 8 更正（ruling 35④）**：第二處在 **`run_generation`**（`drive_e.sh:701-706`，
`if ! gate_control; then … fi` 收尾再加外層 `if [[ "$id" == "G1" … ]]` 的 `fi`），不是 `gate_control` 自己），
只是搜尋從唯一的 `if (( release_rc != 0 )); then` 起算才對。**「因為搜尋起點的關係所以沒事」正是上一次錯的那種推理**，
所以現在切出來的東西被**斷言**：必須包含這格要拿掉的 `FAILURES+=("final: 'ndt release' refused`，
且必須**不**包含後面的 `arms_seen != arms_expected`。以後誰再移動其中之一，會指名失敗而不是默默切錯。

## 錨點全掃（產生任何判決之前跑）

`anchor-sweep.p3e-f51ee88f.log`，rc 0：

- **`tests/mutate_analyse.sh` 的 34 個錨點（M-E1..M-E32 ＋ 兩個控制）全部 hits=1。**
  抽錨點的方法是**讓 bash 自己解析**（把 mutation 區段 source 進一個把 `mutant`／`report`
  換成只印東西的 harness），不是我重打一次字串——重打本身就是一種漂移。
- 另外九處以文字指名這些行的地方：閘門 `--self-test` 的兩個（ST-1 依設計必須 0 次、ST-2 必須 1 次）、
  `test_drive_e_offline.sh` §7 的三段替換（(a) sed、(b) 四個 `local`、(c) 切片的頭／中／尾）、
  (c) 的 grep 用**它自己的 anchored regex** 對真 driver 是 0 次（唯一的字面出現在註解裡，
  `^[space]*"$NDT"` 擋掉它——我第一次用子字串檢查誤報了一次，那是我的檢查寫錯，不是漂移）、
  以及我自己紅跑 (2b) 的還原錨點（與 M-E30 相同）。
- **`tests/shell/check_gate_anchors.py HEAD` 是 115/115 ok、rc 0，但它掃不到本輪這支閘門**
  （它只認 `tests/shell/mutate_*.sh`）——所以上面那份自製的掃描不是多餘的，
  它是這支閘門唯一的錨點檢查。

## 閘門與紅跑（**每一列都標自己的 sha**；log 在 `scratch/overnight-2026-09-05/logs/gates-0910/`）

| 跑什麼 | sha | rc | 判決行／關鍵行（逐字） | log |
|---|---|---|---|---|
| 單元測試（venv，無 matplotlib） | `f51ee88f` | 0 | `Ran 63 tests` ／ `OK (skipped=1)` | `unit-venv.p3e-f51ee88f.log` |
| 單元測試（miniconda py3，matplotlib 3.10.8） | `f51ee88f` | 0 | `Ran 63 tests` ／ `OK` | `unit-py3.p3e-f51ee88f.log` |
| 離線整輪 | `f51ee88f` | 0 | `passed: 78   failed: 0` | `offline-round.p3e-f51ee88f.log` |
| **變異閘 M-E1..M-E32 ＋ 2 控制** | `f51ee88f` | **0** | **`mutations: 32   survivors: 0   drifted: 0`** | `mutate.p3e-f51ee88f.log` |
| 閘門 self-test | `f51ee88f` | 0 | `passed: 14   failed: 0` | `test_mutate_gate.p3e-f51ee88f.log` |
| `hazard_scan.py` ×3 腳本 | `f51ee88f` | 0 | `3 file(s) given, 3 scanned, 0 unreadable, 0 finding(s)` | `hazard-scan.p3e-f51ee88f.log` |
| 錨點自掃（本閘門 34 ＋ 外部 9） | `f51ee88f` | 0 | `34 anchors, 0 that do not resolve exactly once` ／ `0 that do not resolve as declared` | `anchor-sweep.p3e-f51ee88f.log` |
| `check_gate_anchors.py HEAD` | `f51ee88f` | 0 | `115/115 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)`（**掃不到本閘門**；round 10 補全截斷，裁決 39④d） | `check_gate_anchors.p3e-f51ee88f.log` |
| 紅跑 ①（pre-fix `analyse.py`） | `f51ee88f` | 1 | `FAILED (failures=8, skipped=1)` | `red-1-analyse-prefix.p3e-f51ee88f.log` |
| 紅跑 ①b（舊 fixture 12／新 14） | `f51ee88f` | 1 | `AssertionError: 12 != 14` | `red-1b-fixture-12-vs-14.p3e-f51ee88f.log` |
| 紅跑 ②a（逐字 pre-fix `plot.py`） | `f51ee88f` | 1 | `FAILED (errors=2)`（`AttributeError`） | `red-2-plot-prefix.p3e-f51ee88f.log` |
| 紅跑 ②b（舊規則移植＝M-E30） | `f51ee88f` | 1 | `AssertionError: 2 != 3 : height 160 pt: offsets {0.0, 9.0}` | 同上 |
| 紅跑 ③（pre-fix `drive_e.sh`） | `f51ee88f` | 1 | `passed: 50   failed: 7`（七格全在 6g／6h） | `red-3-driver-prefix.p3e-f51ee88f.log` |
| §7c 等效性對帳（舊控制組×舊 driver vs 本輪×本輪） | `f51ee88f` | — | `(no differences)` | `anchor-equivalence-7c.p3e-f51ee88f.log` |
| (a) 標籤出框量測 | `f51ee88f` | 0 | bmv2 面板 `coop` 字上緣 **高出軸頂 8.2 pt** | `question-a-label-headroom.p3e-f51ee88f.log` |
| ⚠️ **harness 失效**（非結果） | `fc617c77` | 1 | `passed: 75   failed: 3` | `offline-round.p3e-fc617c77.log` |

`5a6a9d80` 與 `fc617c77` 的紅跑 log 留著沒刪（它們是 harness 那一段的實物證據），
但**判決只引用 `f51ee88f` 那一組**——上表每一列都自己標了 sha，就是為了不再出現引用舊 head 的事。

### 五個新變異，各自綁哪一格（閘門 log 逐字）

| 變異 | 綁的格 | 閘門怎麼說 |
|---|---|---|
| M-E28 拿掉 `cell_table` 的 control 排除 | `test_the_none_1024_cell_is_the_two_ladder_arms_only` | `caught ... (… went red)` |
| M-E29 負載閘中位數重新納入 control 臂 | `test_the_none_group_gate_median_counts_the_ladder_arms_only` | `caught ... (… went red)` |
| M-E30 fig3 回到「尾值散佈的 3%」 | `test_three_ends_within_a_label_height_get_three_different_offsets` | `caught ... (… went red)` |
| M-E31 trap 不再記是哪個訊號 | `🔴 an interrupted round says it was interrupted, and by which signal` | `caught ... (1 cell(s) went red)` |
| M-E32 臂數不再與選定數比對 | `🔴 a round that measured fewer arms than it selected does NOT pass` ＋ `🔴 and the verdict says how many of how many` | `caught ... (2 cell(s) went red)` |

**M-E31／M-E32 是分得開的**（這是刻意設計的，不是運氣）：M-E31 下臂數守衛仍然讓 round 紅，
所以只有「說出是哪個訊號」那一格會變紅；M-E32 下訊號守衛仍在，6g 全綠、只有 6h 兩格紅。
一個變異綁到一個**只能為它變紅**的格子——這是 M-E10／M-E19／M-E27 三次學費的同一條。

### 用到的直譯器（「跑過」與「讀過未執行」不混表）

- `p4_proxy/venv/bin/python`（Python 3.13.13，**無 matplotlib**）：所有 `analyse.py` 測試、紅跑 ①①b②、變異閘。
- `/home/adam/miniconda3/bin/python3`（Python 3.13.13，**matplotlib 3.10.8**）：`unit-py3`，
  也是唯一真的跑 `RenderTest`（畫出三張圖）與 (a) 量測的那一個。
  ⚠️ 第一次我用 `/usr/bin/python3`（3.12.3，**沒有 matplotlib**）⇒ `OK (skipped=1)`，
  **`_line_panels`（本輪改的那段）根本沒被執行過**。已改用有 matplotlib 的那支重跑。
  🔴 **round 8 更正（ruling 35④）**：原句說「log 檔頭寫明原因」——`unit-py3.p3e-f51ee88f.log`
  的檔頭只有版本號，沒有原因。**檔頭寫明原因是從 `unit-py3.p3e-e222176d.log` 才成立的**。
- `bash`（`/usr/bin/grep` 照 §0-4）：`test_drive_e_offline.sh`、`test_mutate_gate.sh`、`mutate_analyse.sh`。

## orchestrator 讀 diff 的三個問題（先讀碼回答，沒有改碼）

**(a) `end_label_offsets` 只會往上推，最上面那條線的標籤被推 11 pt 之後還在軸內嗎？**
**不在——而且不是理論上的，是量到的。** 讀碼先說清楚形狀：`natural = (y - low) * scale`
是「從軸底往上數的點數」，而軸自己的高度就是 `height_points`，
所以 `display_points > height_points` 就是出框；標籤 `va="center"`，字的上緣再高半個標籤。
`annotate` 預設 `clip_on=False`，**所以它不會消失，它會壓到面板標題那一帶**。
沒有任何一格斷言它在軸內——`test_three_ends_...` 斷言的是**間距**，另一格只涵蓋不推的情形。

量測（`question-a-label-headroom.p3e-f51ee88f.log`；作法是把 `plot.end_label_offsets` 包一層
記錄器，再讓 `plot.render()` 用第四次 campaign 的 `summary.json` 真的畫 fig3，
所以讀到的是**真的軸高與真的 ylim**，不是我複製一份幾何）：

| 面板 | 軸高 | 最上面的標籤 | 結果 |
|---|---|---|---|
| bmv2 | 206.5 pt | `coop` 畫在 209.2 pt（位移 +12.1），字上緣 214.7 pt | 🔴 **高出軸頂 8.2 pt** |
| kernel | 206.5 pt | 三個位移都 0 | 在軸內（3.9 pt 餘裕） |
| proxy + emitter | 206.5 pt | 三個位移都 0 | 在軸內（3.9 pt 餘裕） |

關鍵數字：**每個面板最高那條線與軸頂之間只有 9.4 pt**（matplotlib 預設 5% margin），
**比一個標籤高（11 pt）還小** ⇒ 只要最上面那個標籤被推，它就出框。今天只有 bmv2 面板會推。
修法方向（**本輪範圍鎖定，沒做**）：把整疊往下夾（`display_points` 夾在 `[0, height - label/2]`，
必要時整組以質心對齊）、或放標籤前先把 `ylim` 頂端撐開一個標籤高、
最低限度也要有一格斷言 `display_points + label/2 <= height_points`。**候選，等裁定。**

**(b) `is_control_arm(directory, raw_dir=None)` 省略 `raw_dir` 時用絕對路徑判——還有誰呼叫 `load_arm`？**
**全 repo 只有一個呼叫點**：`analyse.py:199` 的 `walk_raw`，而它**一定**傳 `raw_dir`
（`doc/audit/2026-08-28_flow-count-capacity/analyse_p1_3.py:72` 也有一個 `load_arm`，
是同名不同函式，與這裡無關）。所以那條預設路徑今天是**死的**，危險是潛伏的不是活的：
若將來有人直接 `load_arm(dir)`，而 run 目錄的**絕對路徑**裡剛好有一段叫 `controls`
（例如把 raw 放在 `.../controls/...` 底下），每一條臂都會被標成 control ——
而那個誤判的方向最糟：整張表會安靜地變空，不是報錯。
今天 `relpath` 把 `raw_dir` 以上的路徑全部剝掉，所以 raw 放在哪裡都不影響。
**沒有任何一格涵蓋 `raw_dir=None` 這條路徑。** 候選（本輪沒做）：讓 `raw_dir` 變必填，
或在無 `raw_dir` 時拒絕回答而不是猜。

**(c) C1／C2 確定不寫 `arm.meta` 嗎？**
**確定，而且是從碼確認的，不是看一次跑的樹。** `arm.meta` 的唯一寫者是
`run_group_arm.sh:155`（`META="$OUT/arm.meta"`）；`drive_e.sh` 只在兩處叫它：
`ladder_arm`（`:566`）與 `gate_control`（`:661`、`:664`）。
`sender_control`（C1／C2）整個函式只寫 `$out/rep<N>.json`、`$out/pps.txt`、`$out/control.meta`，
沒有一行呼叫 `run_group_arm.sh`。~~`sample_error.sh` 只寫 `window.json`。~~
🔴 **round 8 更正（ruling 35④）**：`sample_error.sh` 寫**五個檔**——`sflow_before.json`、
`iperf3.json`、`switch_state.json`、`sflow_after.json`、`window.json`（真樹逐一對過）。
**結論不變**（它不寫 `arm.meta`），但原句是錯的。
⇒ `--only C1`／`--only C2` 的期望值 0 與實際的 0 一致；
`--only C3` 是 2（gate_control 的兩條）；`--only G<n>` 是該世代的臂數；整輪是 12 ＋ 2 ＝ 14。
`expected_arm_count` 正是這樣從 `GENERATIONS` 表算出來的。

## 記錄：coop 兩格 unresolved 是對的（orchestrator 的實測，我沒有據此改碼）

第五次 campaign 十二臂：none 30/30/30/30、coop 12/12 然後 30/30、link 12/12 然後 20/20；
機器安靜時單獨重跑 `--only G2` 得 coop_f64=12、coop_f1024=30，且 f1024 的梯子非單調
（20 kpps 掉 0.5626% 不乾淨、30 kpps 掉 0.2242% 乾淨）⇒ **估計量在 20–30 kpps 這個工作點沒有解析度**
（同一階跨跑 0.25%–4.46%），不是組效應。
`cell_table` 的 rung-gap ≤ 1 規則把 coop 兩格判 unresolved **是正確行為，本輪沒有為了讓它 resolved 動規則**，
以後也不該動：那條規則存在的理由就是「相差超過一階的兩臂平均出來的數字沒有任何一臂量到過」。
這條實測是**轉述**（我沒跑那些臂），標籤照 §6 的三級可信度規則。

## 仍然沒做的

- **一臂都沒跑**（這一輪全是離線）；第五次 campaign 的 raw 由 orchestrator 產生，
  `FINDINGS.md` 是 ruling 32⑤ 的第二段任務，還沒開始。
- **(a) 的出框問題沒修**（範圍鎖定），也沒有任何一格斷言標籤在軸內。
- **(b) 的 `raw_dir=None` 路徑沒有測試**。
- `ndt status --check` 對 `--telemetry` fabric 的實際 rc 仍沒看過（rc 1 進判決、rc 3 只記錄）。
- 24⑤ 剩下的候選仍在：只有一個世代回 rc 1 的格、`die` 經 `finish` 變 exit 1 與檔頭不符、
  [3/3] 計數對帳、rc 5 訊息不該對別人的 claim 建議 `--force`。

**[Co-developed with claude code -- Adam]**

---

# Round 8（ruling 35，2026-09-19 22:3x–2x:xx）

**head**：`e222176d`（一顆 commit）。沒 sudo、沒 `ndt`、沒碰 lab、沒 Mininet、沒編譯。
ruling 32 的三項判官已核可，本輪**沒有回頭動它們**。

## ① 🔴 取樣誤差的 N 數錯了集合——**五格**判決翻面（不是四格）

`shot_noise_prediction(..., links=len(sample.get("keys") or []))`。
`keys` 是 `sample_error.sh:189` 的 `twin ∩ netdev`＝**十台交換機的每一個 inter-switch 埠，32 條**；
PREREG §5.2 註冊的是**流量經過的 4 條**與 `N = 4 × pps × duration / 256`。
用 32 ⇒ N 大 8 倍、預測緊 √8＝2.83 倍。

**那四條邊不必用猜的，同一份 `window.json` 就寫著**：`per_edge_peak_bps` 只收「twin 曾經讀到非零」的邊，
真資料裡恰好 `s1-eth2`／`s6-eth4`／`s8-eth2`／`s10-eth4` 四條。
改成 `links_for_prediction(window)` 數那些邊；`summary.json` 同時記 `links_used` 與 `keys_total`
（兩個數字都在，讀者看得見它們不一樣）；**量到的數 ≠ PREREG 的 4 時印紅字註記**，不安靜改口徑。
`none` 組沒有任何 twin 讀數 ⇒ `per_edge_peak_bps` 是空的 ⇒ 無從量 ⇒ 退回註冊的 4，**而且把這件事印出來**。

**真資料上的效果（`raw/2026-09-19T105759Z_full`，我用修好的 `analyse.py` 跑過，summary 寫進 scratchpad
沒有碰 raw/）**：六格 treated 有 **5 格翻面**，全部同方向（「超出區間」→ 落在註冊區間內）：

| group | Mbit | median\|e\| | 修前（links=32） | 修後（links=4） |
|---|---|---|---|---|
| cooperative | 2 | 0.1718 | above the shot-noise band, signs mixed | **H-B1 shot-noise limited** |
| cooperative | 20 | 0.0262 | H-B1 shot-noise limited | H-B1（不變） |
| cooperative | 100 | 0.0183 | above the shot-noise band, signs mixed | **H-B1** |
| link | 2 | 0.1941 | H-B2 systematic bias | **H-B1** |
| link | 20 | 0.0476 | above the shot-noise band, signs mixed | **H-B1** |
| link | 100 | 0.0293 | H-B2 systematic bias | **H-B1** |

⚠️ **裁決 35① 說四格，實際是五格**：`link 20M` 也翻（它修前是「above the band, signs mixed」，
不在裁決點名的四格裡）。🔴 **round 9 追記**：裁決 37⓪ 已更正為五格，並記下機制是
**把一個速率的結論從一組推廣到另一組**（coop 20M 本來就 H-B1，於是整列被當成結案）。
📌 **分析單位是「(組,速率)」那一格**，清點「幾格變了」必須逐格比前後兩值。
🔴 **口徑（裁決 37⓪b）**：這五格是**第四次** campaign（修法證據，有修前 summary.json 可對照）；
最終 FINDINGS 與三張圖要用**第五次** `2026-09-19T115737Z_full`，而**第五次的六格判決一次都還沒算過**
⇒ 「五格翻」只能講缺陷嚴重性，不可當最終結果引用。預測值本身：2 M 0.0504→**0.1427**、20 M 0.0159→**0.0451**、100 M 0.0071→**0.0202**，
`n_samples` 178.57→**22.32**——🔴 **round 9 更正（裁決 37⑦c）：那是 2 Mbit/s 那一格的數字，不是全域**；
20 M 是 1785.71→223.21、100 M 是 8928.57→1116.07（都是 ×1/8，因為 N ∝ links）。
跨組比較（H-B4 三格）不吃預測，沒有變。
🔴 **FINDINGS 目前仍然一格 H-B 都沒抄**（裁決 35⑥）。

## ② fig3 的頂端標籤被推出軸外——本輪規則自己造成的

我在 round 7 量到的 8.2 pt 出框是真的缺陷：面板軸高 206.5 pt、頂端只有 9.4 pt 餘裕（matplotlib 5% margin）、
`coop` 被推到 209.2 pt ⇒ 字上緣 214.7 pt，而 `annotate` 不剪裁 ⇒ 壓在面板標題上。
**不能把標籤推回去**（重疊會回來），所以改成**把軸讓出來**：`place_end_labels` 解出「能容下整疊」的上緣。
用解的不是逼近的：堆疊後第 i 個標籤在 `max_{j≤i}(natural_j + (i-j)×label)`，
每個 j 給一條 span 下界，取最大即為答案；先前那種「每輪加 overflow」的迴圈跑八次仍差 1e-6 pt，
那不是碼宣稱在做的事。只有需要空間的面板會被抬（kernel 與 proxy+emitter 兩面板位移全 0、軸不動）。

## ③ fixture 與真 raw 的結構對帳（常駐測試）——一跑就再抓到**四**件事

`tests/inventory.py` 抽形狀：每類目錄有哪些檔案類別、被分析讀的每個檔的**鍵集合**、
以及每個 list／dict 值的**基數**。
🔴 **基數那一半是必要的**：ruling 35① 的缺陷裡 `keys` 與 `per_edge_peak_bps` **名字兩邊都有**，
差的只是 32 與 4——只比名字的對帳會說這份 fixture 很忠實。
`tests/fixtures/real_run_inventory.json` 是第四次 campaign 的真 run 目錄的那份 inventory（已 commit），
`tests/test_real_shape.py` 兩邊比對，**差集必須恰好等於宣告的清單**（兩個方向都比）。

~~第一次跑就抓到三件 fixture 與真 raw 不一致（都已修）：~~
🔴 **round 9 更正（裁決 37②）：是四件，不是三件**，而且「六列基數差」要講清楚是**一件缺陷生出多列**。
~~`red-35-3-fixture-shape.p3e-e222176d.log` 的差集共 10 列~~ 🔴 **round 10 更正（裁決 39⑤）：共 14 列**（4 列鍵集合＋10 列基數，log `:72-85`；逐列分類用一支腳本做，`recount-39-5-red-35-3-rows.p3e-bc1db4c0.log`），拆開是：
**(1) 家族鍵被巢在 `telemetry_health` 裡**——一件缺陷、~~**六列**~~ **八列**（基數六列：`non_ipv4_flows`／`samples_by_family`／
`telemetry_health` 各一列 × `_before`/`_after` 兩個檔；**再加鍵集合兩列**：兩個檔各缺 `malformed_ipv4_ihl`/`non_ipv4_flows`/`samples_by_family`）；**(2) `window.json excluded_host_facing`
real [4,4] fixture [2,2]**（我上一輪整篇沒提到這件）；**(3) C1/C2 的 `control.meta` 缺鍵**；
**(4) 十個 bmv2**。另外兩列（`keys` [32,32]/[4,4]、`per_edge_peak_bps` [0,4]/[4,4]）是裁決 35① 本身
要修的那個缺陷，不算「額外找到」。🔴 **round 10 補（裁決 39⑤）**：第 14 列是 `arm.meta` 缺的 12 把鍵——那是宣告過的 `NOT_WRITTEN_KEYS`，不是缺陷；**8＋1＋1＋1＋2＋1＝14**。另外 (3) `control.meta` 那列是**鍵集合**列，不屬於基數列。下面原本寫的三件是其中的 (1)(3)(4)：

1. 真的 `get_sflow_stats` 文件把 `samples_by_family`／`malformed_ipv4_ihl`／`non_ipv4_flows`
   放在**頂層**，fixture 塞在 `telemetry_health` 裡（真檔頂層 5 鍵、`telemetry_health` 12 鍵；
   fixture 曾是 2 鍵／14 鍵）。今天沒有碼讀它，但下一個讀 fixture 的人會相信它。
2. ~~真的 C1／C2 `control.meta` 有 `requirement` 與 `verdict`，fixture 沒寫。~~
   🔴 **round 9 更正（裁決 37①）**：log 證明的只有 **`requirement`**
   （`red-35-3-…-e222176d.log:36-43`／`:73` 都只列 `['requirement']`）。
   `verdict` 那半**這支儀器結構上看不到**：`inventory.py` 把 C1/C2/C3 的 `control.meta`
   union 成一個檔案類別，而 C3 本來就寫 `verdict` ⇒「只有 C1/C2 少某鍵」永遠不會浮出來。
   ⇒ round 9 把 `control.meta` 改成**逐控制**比對，並重新看紅。
3. 🔴 真的 `cpu.jsonl` 有**十個 bmv2 行程**（`static` 12 鍵，link 臂 13），fixture 只有一個 ⇒
   **`label_of` 把十個 pid 摺成一類**——每個 bmv2 數字都靠它——~~從來沒被執行過~~
   🔴 **round 9 更正（裁決 37③）：對生產路徑是假的。** 真 `cpu.jsonl` 一直有十個 bmv2 pid
   （`raw/…/G3/link_f1024_a/cpu.jsonl:1` 的 `static` 13 個），第四次 campaign 的每個 bmv2 數字
   都走過那條摺疊。真話是「**從來沒有被測試執行過**」。
   ~~已改成十個行程各 `BMV2_BASE/10`，總量不變。~~ 🔴 **round 10 註記（裁決 39①）**：那是 round 8 的狀態；round 9 已改成十個**不相等**的權重（和仍為 `BMV2_BASE`）——而 `synthetic.py:186-191` 的碼註解到 round 10 才跟著改。

`synthetic.py:9-10` 的「written here EXACTLY as the scripts write them」是過度宣稱，改成真話：
「被分析讀的每個檔案，鍵與真 raw 相同」＋**列出刻意不寫的**（12 個沒人讀的 `arm.meta` 鍵、
以及分析從不打開的那些檔案類別），而且那份清單**被測試釘住**，不是寫在註解裡就算。

## ④ 四句與證據對不上的話，已就地更正（見 Round 7 段落裡的紅字）

| 判官點名的句子 | 事實 | 怎麼處理 |
|---|---|---|
| red-1b「這份 log 裡…已就地標示」 | 標示只在 `fc617c77` 那份的末行；`f51ee88f` 那份 52 行全無 | 就地劃掉，改寫成哪一份有 |
| unit-py3「log 檔頭寫明原因」 | `f51ee88f` 的檔頭只有版本號 | 就地更正；**`e222176d` 的檔頭現在真的寫了原因** |
| 「`sample_error.sh` 只寫 `window.json`」 | 它寫五個檔 | 就地更正（結論「不寫 `arm.meta`」不變） |
| 「`gate_control` 的巢狀也以它結尾」 | 第二處在 `run_generation`（`drive_e.sh:701-706`） | 就地更正 |

## 閘門與紅跑（全部在 `e222176d`，**每一列標自己的 sha**；log 在 `scratch/overnight-2026-09-05/logs/gates-0910/`）

🔴 **全部在 orchestrator 22:44 下「停止一切執行」之前就跑完了。**
**證據是檔案 mtime，不是我的記憶**（裁決 37⑦d）：`ls --time-style=+%H:%M:%S` 在
`logs/gates-0910/*.p3e-e222176d.log` 上顯示最後一支 `test_mutate_gate` 的 log 是 **22:43:51**，
`mutate` 是 22:42:07；**log 檔頭只記起跑時間，不記結束時間**，所以那一刻的唯一存檔證據就是 mtime。
停止令之後**我動過的檔案只有兩類：這份 `P3-E-SUMMARY.md`（在 worktree 之外）與 scratchpad 的草稿**
（裁決 37⑦e）——**worktree 一個字都沒改**，所以上面那張閘門表確實是關於 `e222176d` 那棵樹的。
並已確認機器上沒有我留下的行程、沒有殘留的 mutant 暫存目錄（`ps` 查的，不是 `pgrep`）。

| 跑什麼 | sha | rc | 判決行／關鍵行（逐字） | log |
|---|---|---|---|---|
| **變異閘 M-E1..M-E34 ＋ 2 控制** | `e222176d` | **0** | **`mutations: 34   survivors: 0   drifted: 0`** | `mutate.p3e-e222176d.log` |
| 閘門 self-test | `e222176d` | 0 | `passed: 14   failed: 0` | `test_mutate_gate.p3e-e222176d.log` |
| 離線整輪 | `e222176d` | 0 | `passed: 78   failed: 0` | `offline-round.p3e-e222176d.log` |
| 單元（venv，無 matplotlib） | `e222176d` | 0 | `Ran 76 tests` ／ `OK (skipped=1)` | `unit-venv.p3e-e222176d.log` |
| 單元（miniconda py3，mpl 3.10.8） | `e222176d` | 0 | `Ran 76 tests` ／ `OK` | `unit-py3.p3e-e222176d.log` |
| `hazard_scan.py` ×3 腳本 | `e222176d` | 0 | `3 file(s) given, 3 scanned, 0 unreadable, 0 finding(s)` | `hazard-scan.p3e-e222176d.log` |
| 錨點自掃（36 ＋ 外部 10） | `e222176d` | 0 | `36 anchors, 0 that do not resolve exactly once` ／ `0 that do not resolve as declared` | `anchor-sweep.p3e-e222176d.log` |
| `check_gate_anchors.py HEAD` | `e222176d` | 0 | `115/115 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)`（掃不到本閘門；round 10 補全截斷，裁決 39④d） | `check_gate_anchors.p3e-e222176d.log` |
| 紅跑 35①（pre-fix `analyse.py`） | `e222176d` | 1 | `FAILED (failures=2, errors=2, skipped=1)` | `red-35-1-links-prefix.p3e-e222176d.log` |
| 紅跑 35②a（逐字 pre-fix `plot.py`） | `e222176d` | 1 | `AttributeError: module 'plot' has no attribute 'place_end_labels'` | `red-35-2-label-outside.p3e-e222176d.log` |
| 紅跑 35②b（拿掉抬升＝M-E34） | `e222176d` | 1 | `AssertionError: 214.70828732771142 not less than or equal to 206.500001 : bmv2: coop's label top is 214.7 pt on a 206.5 pt axes` | 同上 |
| 紅跑 35③（舊 fixture 對結構對帳） | `e222176d` | 1 | `FAILED (failures=2, errors=1)` ＋ 全差集列表 | `red-35-3-fixture-shape.p3e-e222176d.log` |

> 🔴 **欄位更名（裁決 37⑦a）**：這一欄原本叫「末行（逐字）」，但 11 列裡有 4 列引的不是檔案最後一行
> （`red-35-2` 兩列引的是檔中的失敗行、且兩列共用同一份 log；`anchor-sweep` 引的是小節結尾；
> `red-35-3` 的 rc 行後面還接了差集附錄）。**每一份 log 真正的最後一行都是 `### rc=N`**
> （`red-35-3` 除外，它最後是差集附錄）。欄位現在叫「判決行／關鍵行」，那才是它一直是的東西。

### 三份紅跑的逐字要點

**35①**（`links=len(keys)` 的舊碼，配本輪真形狀 fixture）：
```
FAIL: test_N_counts_the_edges_that_carried_the_flow_not_every_edge_in_the_fabric
AssertionError: 178.57142857142858 != 22.32 within 2 places (156.2514285714286 difference)
```
另外 `test_an_error_at_the_prediction_is_H_B1` 一起紅（fixture 的 coop@20M 在錯的 N 下不再落在預測上）；
兩個 ERROR 是呼叫 `links_for_prediction`／讀 `links_used` 的兩格——**舊碼沒有那個函式，所以只能 ERROR 不能 FAIL**，
照規則標成 harness 層級的限制而不是行為紅。

**35②b**：`214.7 pt on a 206.5 pt axes` ——**與 round 7 在真圖上量到的 214.7 pt 是同一個數**，
單元格把那次量測重現到小數點。②a 只證明函式是新的（`AttributeError`）。

**35③**（`f51ee88f` 的舊 fixture 對真 inventory）——斷言停在第一個差異，所以 log 另附完整差集
（🔴 **下面是節錄不是逐字全文**，裁決 37②：~~省掉了 `_after` 那半、`non_ipv4_flows` 兩列與
`excluded_host_facing` 那列；全文 10 列在 log 的 `:78-90`~~ 🔴 **round 10 更正（裁決 39④b／⑤）**：全文 **14 列在 log 的 `:72-85`**（該檔 85 行，`wc -l` 與末行 `:85` 都是量的）；下面 7 列是其中 7 列（`arm.meta` 那列還把 12 把鍵縮寫成「[12 個鍵]」），省掉的 7 列是 `:74`（`_after` 缺鍵）、`:77-81`（`_after` 三列基數、`_before` 的 `non_ipv4_flows` 與 `samples_by_family`——上一版的省略清單漏了 `_before samples_by_family`）與 `:83`（`excluded_host_facing`））：
```
  keys missing from arm.meta                   [12 個鍵]
  keys missing from control.meta               ['requirement']
  keys missing from sflow_rung<N>_before.json  ['malformed_ipv4_ihl', 'non_ipv4_flows', 'samples_by_family']
  cardinality  cpu.jsonl    static             real [12, 13]  fixture [2, 2]
  cardinality  window.json  keys               real [32, 32]  fixture [4, 4]
  cardinality  window.json  per_edge_peak_bps  real [0, 4]    fixture [4, 4]
  cardinality  sflow_rung<N>_before.json telemetry_health  real [12, 12]  fixture [14, 14]
```
最後那三列就是 ruling 35① 的缺陷、`none` 組空 peaks、以及家族計數被塞錯層——**名字對帳全都看不到**。

### 兩個新變異，各自綁哪一格

| 變異 | 綁的格 | 閘門怎麼說 |
|---|---|---|
| M-E33 `links` 改回 `len(keys)` | `test_N_counts_the_edges_that_carried_the_flow_not_every_edge_in_the_fabric` | `caught ... (… went red)` |
| M-E34 拿掉軸的抬升 | `test_no_label_is_drawn_above_the_top_of_its_own_axes` | `caught ... (… went red)` |

③ 沒有變異：它守的是 **fixture**，而閘門的規則是「變異只改生產碼、永不改測試」。
它的紅是用**上一版 fixture** 看到的（上表 35③），那才是這格該有的紅。

### 用到的直譯器

- `p4_proxy/venv/bin/python`（3.13.13，無 matplotlib）：`analyse.py` 全部測試、三份紅跑、變異閘。
- `/home/adam/miniconda3/bin/python3`（3.13.13，matplotlib 3.10.8）：`unit-py3`，唯一真的畫圖那支；
  **檔頭這次寫明了為什麼不是 `/usr/bin/python3`**（3.12.3、無 matplotlib ⇒ `RenderTest` 會跳過，
  而 `_line_panels` 正是 ruling 32② 與 35② 兩次落點）。
- `bash`＋`/usr/bin/grep`：離線套件、閘門 self-test、變異閘。

## ⑤ 候選（本輪不做，記錄）

- `load_arm` 的 `raw_dir` 改必填（今天是死路徑，失效方向是「每條臂被標成 control、表安靜變空」）。
- 變異閘的 **shell 半邊沒有 baseline**（python 半邊有；shell 那半只比「指名的格子紅不紅」）。
- anchor sweep 收進 `tests/`（今天是我在 scratchpad 裡組的 harness，只有 log 留下）。
- `--only G1|C3|C1` 三條分支只有讀碼驗證、沒有測試；SIGINT 路徑從未被跑過（跑過的是 TERM）。
- `cpu_comparison` 的控制臂過濾今天是**等價變異**（fixture 的控制臂 CPU 與 none 臂相同）。
- `inventory.py` 的 `control.meta` 是**一個類別**，C1／C2／C3 的鍵集合被 union 起來比——
  所以只抓得到「三份都沒有」的缺鍵（`requirement` 就是這樣抓到的），抓不到「只有 C1 少」。

## 仍然沒做的

- **一臂都沒跑**；第五次 campaign 的 raw 由 orchestrator 產生，`FINDINGS.md` 仍未開始
  （裁決 35⑥：**① 修好之前任何 H-B 判決不得進 FINDINGS**——現在 ① 修好了，但 FINDINGS 還沒寫）。
- `ndt status --check` 對 `--telemetry` fabric 的實際 rc 仍沒看過。
- 24⑤ 的四條舊候選仍在。

**[Co-developed with claude code -- Adam]**

---

# Round 9（ruling 37，2026-09-19 23:2x–2x:xx）

**head**：`9204e3e3`（`9b574c24` 碼 → `9204e3e3` 補 M-E35 說到而沒做的 M-E36）。
沒 sudo、沒 `ndt`、沒碰 lab、沒編譯。orchestrator 已在 `e222176d` 重現過上一輪全部閘門
（`rerun-E1-2313-e222176d.log`），本輪不回頭動已核可的部分。

## ⓪ 勘誤與口徑（裁決 37⓪／⓪b，已就地寫進 Round 8 段）

五格不是四格，漏的是 `link 20M`；機制是**把一個速率的結論從一組推廣到另一組**。
📌 **分析單位是「(組,速率)」那一格**。
🔴 五格講的是**第四次** campaign；**第五次 `115737Z` 的六格判決一次都還沒算過**，
所以「五格翻」只能講缺陷嚴重性，**不可當最終結果**，FINDINGS 也還沒抄任何 H-B。

## ① `control.meta` 從 union 改成逐控制——union 讓「只有兩份少一把鍵」永遠看不見

`inventory.py` 把 C1/C2/C3 的 `control.meta` 併成一個檔案類別。C3 本來就寫 `verdict`，
於是 union 永遠有 `verdict` ⇒ **「只有 C1/C2 少 `verdict`」在結構上不可能浮出來**，
儀器只報得出 `requirement`。這正是我 Round 8 那句「C1/C2 少 requirement 與 verdict」
被自己的 log 否證的原因：句子講對了事實，**但證據只支持一半**，而另一半這支儀器根本看不到。

改：`file_class(name, directory)` 對 `PER_INSTANCE = ("control.meta",)` 把**擁有它的目錄名**
併進類別（`control.meta (C1)`／`(C2)`／`(C3)`），`consumed()` 比對時剝掉括號那段。
**同一份舊 fixture、同一份真 raw、兩支儀器**（`red-37-1-…log`）：

```
OLD instrument (control.meta unioned)
   control.meta         missing from the fixture: ['requirement']
NEW instrument (control.meta per control)
   control.meta (C1)    missing from the fixture: ['requirement', 'verdict']
   control.meta (C2)    missing from the fixture: ['requirement', 'verdict']
   control.meta (C3)    missing from the fixture: []
```
結構測試本身在舊 fixture 上也紅：`AssertionError: Lists differ: ['requirement', 'verdict'] != []`。
**差別就是發現本身**——不是我換了一份會紅的資料，是儀器從看不見變成看得見。
另：`synthetic.py` 引 `drive_e.sh:576-582` 當那兩個鍵的出處是錯的（那是 `sampling_block` 開頭），
正身是 `sender_control` 的 `:645-646`（寫進 ~~`:648`~~ **`:647`** 的 `control.meta`——🔴 round 10 更正（裁決 39④a）：`:647` 才是 `} > "$out/control.meta"`，`:648` 是其後的 `note`；`synthetic.py` 的碼註解同改），已改。

## ② bmv2 十路摺疊：有跑沒斷言 → 斷言 ＋ 變異

上一輪十個行程各 `BMV2_BASE/10`，**刻意讓總量不變**——而十個相等的值讓
「加總十個」與「拿一個乘十」**變成同一個函數**，那正是本套件自己對 `samples_per_second`
寫下的規則（M-E10 的教訓）沒有套用到的地方；而且 `test_analyse.py` 從來沒斷言過任何 bmv2 量值、
閘門也從來沒有一個變異打 `label_of` ⇒ **sum 換成 max／first，34 個變異全綠**（🔴 **round 10（裁決 39③）：這句寫下時是推論，現在是量測**——`e222176d` 那棵樹貼上 max 與 first 兩種摺疊（`tests/red/sum_to_{max,first}.json`），各跑一次那棵樹自己的閘門：基線 `Ran 76 tests` ／ `OK (skipped=1)`，`mutations: 34   survivors: 0   drifted: 0`、兩個控制照綠；log `measure-39-3-gate-sum-to-{max,first}-at-e222176d.p3e-0fd507c8.log`）。

改：權重改成 `42,30,20,16,12,10,8,6,4,2`（互不相等、**每個都是偶數** ⇒ 0.5 s 步長下都是整數 jiffy；
和 150 ＝ `BMV2_BASE`，而且 `BMV2_BASE = float(sum(BMV2_WEIGHTS))` **由權重導出**，兩者不可能漂）。
十個行程的起始 jiffy 也改成不相等（`900000 + 1000×n`），免得有人依賴「十個同時開始」。
新增一格斷言**摺疊後的合計**（比照 kernel 那格），M-E35 讓 `bmv2-3` 脫離類別 ⇒ 合計 130。

`red-37-4-bmv2-fold.p3e-9204e3e3.log` 三段：
```
(a) round 8 (ten equal shares)    'sum the ten' 與 'take one x ten' 一致： True
    round 9 (ten unequal shares)  一致： False
(b) rung 1.0/8.0/20.0  folded bmv2 = 150.000000  (expected 150.0)  error +0.000000
(c) AssertionError: 130.0 != 150.0 within 3 places (20.0 difference) : rung 1.0
```

🔴 **(b) 是我自己要更正的一件事，而且是量的不是推的。** Round 8 我複述了「總量不變 ⇒ 分析數字沒變」
的理想化抵消；我在本輪動手前先量，**擔心 15.0% × 0.5 s ＝ 7.5 jiffy 不是整數、而 fixture 每列寫 `int()`**。
量出來是**恰好 150.000000**——原因是 `7.5 × 16 = 120` 也是整數，
~~**`cpu_for_window` 只相減視窗首末兩筆**，而那兩筆剛好都落在整數上，奇數步的截斷碰不到它們。~~
🔴 **round 10 更正（裁決 39⓪b）：機制寫錯了。** `cpu_for_window` **逐列累加** `value − seen[key]`；中間那些 `.5`
**確實被 fixture 的 `int()` 截過**（逐列增量是 7,8,7,8,…），是**每鍵增量的加總 telescoping 相消**才回到端點差 120
（`measure-39-0b-telescoping.p3e-bc1db4c0.log`，量的）。結果（恰好 150.000000）是量到的、對；機制敘述錯。
**機制我擔心對了，結果不是**；兩邊都寫下來，因為「複述一個沒自己算過的抵消」正是這次要修的毛病。

## ③ `headroom <= 0`：我選 (a) 加測試，並且把那句沒根據的註解改掉

`plot.py` 那個分支只有 `continue`，而註解說「containment test will say so」。
containment 只跑三個 206.5 pt／三標籤的真面板，**那裡最緊的 headroom 是 179 pt**；
三個標籤要軸高 < 27.5 pt 才踩得到 ⇒ **那個分支從來沒有被執行過**（`red-37-5-…log` 逐行印了這個算術）。

**選 (a)**：新增一格「20 個標籤塞 50 pt」。它釘住三件事——
(i) 交錯仍然誠實（相鄰標籤仍差一個標籤高）；
(ii) 它**不假裝裝得下**：頂端標籤被放在軸頂之上，而且**那個溢出在回傳值裡看得見**；
(iii) 🔴 **而呼叫端拿到的就只有這些**：沒有旗標、沒有例外、沒有第三個回傳值——
想知道的人必須自己做那個減法，而 `_line_panels` 沒有做。
**這是關於介面的發現，不只是關於測試的**，所以它被寫成斷言（回傳仍是 2-tuple、欄位就那六個），
將來要加訊號必須先從這格走一遍。註解改成**只講這個函數自己做什麼**，不再宣稱別的測試會說話。
M-E36（把整疊夾進軸內）綁這一格；紅跑：`AssertionError: 0.5 not greater than or equal to 10.999999999`
——夾完之後連「相鄰差一個標籤高」都不成立了，溢出從回傳值裡消失，正是「安靜地裝得下」的樣子。

## ④ 兩支判官會跑而上一輪沒跑的（裁決 37⑨）

**(a) 真的畫一次，量它**（`postcheck-9a-real-render.p3e-9204e3e3.log`）：
把 `place_end_labels` 包起來放進**真的 `_line_panels` 流程**、用第四次 campaign 的 `summary.json`
畫 fig3，並在 `set_ylim` **前後各讀一次** `axes.get_position().height`：

```
panel bmv2             axes height BEFORE set_ylim 206.4880 pt   AFTER 206.4880 pt   UNCHANGED
panel kernel           206.4880 -> 206.4880 UNCHANGED
panel proxy + emitter  206.4880 -> 206.4880 UNCHANGED
EVERY LABEL INSIDE ITS OWN AXES, AND EVERY AXES BOX UNMOVED: True
```
⇒ ② 從「模型內自洽」升級成「**畫出來的圖真的裝得下**」（🔴 **round 10 更正（裁決 39⑥）：過度了**——上面的 `glyph top`
＝ `display_points + 11/2`，是**模型**；這一輪**軸框是量的、字高仍是 11 pt 模型**。round 10 改讀
`Annotation.get_window_extent()`：真字框高 **9.36 pt**、最緊的 `coop` 上緣距軸頂 **+0.82 pt**，九個標籤全在框內——
兩半都是量的，見 Round 10 段 ⑥），
「`height_points` 在 `set_ylim` 之後仍然有效」從推理升級成**量測**。

🔴 **這支腳本的第一版是錯的，log 檔頭寫著。** 我用 `plt.Axes.annotate` 去找 axes，
但圖一、圖二的數值標籤**也走 annotate** ⇒ 三個面板的紀錄被配到長條圖的 axes，
印出「height MOVED 206.49 → 243.50」。那是 **harness 錯誤不是發現**；
改成從 `_line_panels` 自己那次 `subplots` 取 axes 之後才是上面的結果。

**(b) 真相那一側有沒有漂**（`postcheck-9b-inventory-redrawn.p3e-9204e3e3.log`）：
現場從 `raw/2026-09-19T105759Z_full` 重抽一次 inventory，與 commit 進去的那份逐鍵比：
`directory_classes 6 / file_keys 10 / file_sizes 4` 全部相等，**差異 0**。
（這正是候選 ⑤ 的那條：那份 JSON 是死檔、沒有閘門重抽，今天是**手動**驗的。）

## 閘門與紅跑（全部在 `9204e3e3`；log 在 `scratch/overnight-2026-09-05/logs/gates-0910/`）

> 這一欄叫**判決行／關鍵行**，不是「末行」——每份 log 真正的最後一行都是 `### rc=N`
> （`red-37-*` 三份與 `postcheck-*` 兩份也是）。Round 8 那張表的欄名已就地更正。

| 跑什麼 | sha | rc | 判決行／關鍵行（逐字） | log |
|---|---|---|---|---|
| **變異閘 M-E1..M-E36 ＋ 2 控制** | `9204e3e3` | **0** | **`mutations: 36   survivors: 0   drifted: 0`** | `mutate.p3e-9204e3e3.log` |
| 閘門 self-test | `9204e3e3` | 0 | `passed: 14   failed: 0` | `test_mutate_gate.p3e-9204e3e3.log` |
| 離線整輪 | `9204e3e3` | 0 | `passed: 78   failed: 0` | `offline-round.p3e-9204e3e3.log` |
| 單元（venv，無 matplotlib） | `9204e3e3` | 0 | `Ran 78 tests` ／ `OK (skipped=1)` | `unit-venv.p3e-9204e3e3.log` |
| 單元（miniconda py3，mpl 3.10.8） | `9204e3e3` | 0 | `Ran 78 tests` ／ `OK` | `unit-py3.p3e-9204e3e3.log` |
| `hazard_scan.py` ×3 腳本 | `9204e3e3` | 0 | `3 file(s) given, 3 scanned, 0 unreadable, 0 finding(s)` | `hazard-scan.p3e-9204e3e3.log` |
| 錨點自掃（36 變異＋2 控制；🔴 **缺外部那一節**，round 10 ② 揭露並補掃） | `9204e3e3` | 0 | `38 anchors, 0 that do not resolve exactly once` | `anchor-sweep.p3e-9204e3e3.log` |
| `check_gate_anchors.py HEAD` | `9204e3e3` | 0 | `115/115 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)`（掃不到本閘門；round 10 補全截斷，裁決 39④d） | `check_gate_anchors.p3e-9204e3e3.log` |
| 紅跑 37①（union vs 逐控制） | `9204e3e3` | 1 | `AssertionError: Lists differ: ['requirement', 'verdict'] != []` | `red-37-1-control-meta-per-control.p3e-9204e3e3.log` |
| 紅跑 37④（M-E35） | `9204e3e3` | 1 | `AssertionError: 130.0 != 150.0 within 3 places (20.0 difference) : rung 1.0` | `red-37-4-bmv2-fold.p3e-9204e3e3.log` |
| 紅跑 37⑤（M-E36） | `9204e3e3` | 1 | `AssertionError: 0.5 not greater than or equal to 10.999999999` | `red-37-5-headroom-branch.p3e-9204e3e3.log` |
| 後測 ⑨(a) 真圖插樁 | `9204e3e3` | 0 | `EVERY LABEL INSIDE ITS OWN AXES, AND EVERY AXES BOX UNMOVED: True` | `postcheck-9a-real-render.p3e-9204e3e3.log` |
| 後測 ⑨(b) inventory 重抽 | `9204e3e3` | 0 | `DIFFERENCES BETWEEN THE COMMITTED INVENTORY AND A FRESH EXTRACTION: 0` | `postcheck-9b-inventory-redrawn.p3e-9204e3e3.log` |

### 兩個新變異，各自綁哪一格（閘門逐字）

| 變異 | 綁的格 | 閘門怎麼說 |
|---|---|---|
| M-E35 `bmv2-3` 脫離 `label_of` 的類別 | `test_the_ten_bmv2_processes_are_folded_into_one_class_and_SUMMED` | `caught ... (… went red)` |
| M-E36 把整疊夾進軸內（溢出從回傳值消失） | `test_a_stack_taller_than_its_axes_is_not_reported_as_fitting` | `caught ... (… went red)` |

M-E30 與 M-E36 **共用同一個錨點、換成不同的替換**：閘門各自套到自己的副本，
而「錨點在檔案裡唯一」這個前提兩者都成立（anchor sweep 的 38 顆逐一 `hits=1`）。

### 兩顆 commit，以及為什麼是兩顆

`9b574c24` 的 message 寫了「M-E36 clamps the stack to fit and the case reds」——**當下並沒有做**，
我照計畫寫了訊息卻只加了 M-E35。M-E36 補在 `9204e3e3`，**沒有 amend**：
記錄應該看得出「訊息跑到工作前面、然後補上」，而不是被整理成從未發生。

## ⑤ 儀器盲區與候選（裁決 37⑥；本輪登記不修）

- 🔴 **`inventory.py` 的 `cardinalities()` 對 `.jsonl` 只讀第一行**（~~`:88-96`~~ 🔴 round 10 更正（裁決 39④c）：`:133`，`cardinalities()` 裡那個 `fh.readline()`；`keys_of` 的 jsonl 分支 `:102-105` 同樣只讀第一行）。所以 `cpu.jsonl`
  的**樣本列**、以及每一列 `proc` 裡的**十個 bmv2 條目**，**完全不在對帳範圍內**——
  十個行程是靠 header 的 `static` 區塊被看到的，不是靠列。
  **擋不到什麼**：一份 header 宣告十台、每一列卻只寫一台的 fixture，會**完整通過**這支結構對帳；
  而 `label_of` 的摺疊讀的正是列裡的 `proc`。今天有 ② 那格斷言合計擋著，
  但結構對帳這一層對它是瞎的。
- **`tests/fixtures/real_run_inventory.json` 是 commit 進去的死檔**，沒有任何閘門重抽比對 ⇒
  有人改它來讓結構測試變綠，不會有人知道。本輪 ④(b) 手動驗過一次（差異 0），
  但那是**一次性的**，不是閘門。
- `load_arm` 的 `raw_dir` 改必填（今天是死路徑，失效方向是「每條臂被標成 control、表安靜變空」）。
- 變異閘的 **shell 半邊沒有 baseline**（python 半邊有）。
- anchor sweep 收進 `tests/`（今天仍是我在 scratchpad 組的 harness，只有 log 留下）。
- `--only G1|C3|C1` 三條分支只有讀碼驗證、沒有測試；SIGINT 路徑從未被跑過（跑過的是 TERM）。
- `cpu_comparison` 的控制臂過濾今天是**等價變異**（fixture 的控制臂 CPU 與 none 臂相同）。
- 🔴 **`place_end_labels` 裝不下時沒有任何訊號**（本輪 ③ 的第三件）：回傳與「裝得下」時一模一樣，
  呼叫端必須自己做減法，而 `_line_panels` 不做。已寫成斷言，但**介面沒改**。
- `analyse.py:406,410` 只取 `members[0]` 算 `links_used`：三個視窗的承載邊集合不一致時會**安靜**用第一個，
  沒有任何斷言。

## ⑥ FINDINGS 的威脅效度，現在登記（裁決 37⑧）

- 🔴 **(a) `links_for_prediction` 數的是「twin 讀到非零」的邊，而 twin 正是被評量的那支儀器。**
  少看一條邊 ⇒ N 變小 ⇒ 區間變寬 ⇒ **更容易判 H-B1**。
  **失效方向對我們自己的結論有利**——這是威脅效度裡最該寫的那一種。
  第四次 campaign 的 27 個視窗裡，**18 個 treated 視窗全部讀到 4 條**，
  **9 個 `none` 視窗讀到 0 條**（沒有 twin 讀數 ⇒ 走註冊的 4 並印紅字註記）——
  所以**沒有影響任何數字**（「27 個全是 4」會是另一句沒查過的話；🔴 round 10（裁決 39⑧）：這個 18/9 現在有一支會留 log 的掃描作證，
  `scan-39-8-onpath-edges-105759Z.p3e-bc1db4c0.log` 的 `{0: 9, 4: 18}`；**第五次 campaign 不同**，`{0: 9, 4: 16, 5: 2}`，見 Round 10 ⑧），
  但 FINDINGS 必須寫這條，並且寫「若某次視窗只讀到 3 條，H-B1 會變得更容易成立而不是更難」。
- **(b) 註冊的判準是「組級」，貼的標籤是「逐格」——而且不只 H-B1。** 我自己讀了 PREREG 的那張表
  （`PREREG.md:249-254`），三條都帶「三個速率」：
  **H-B1**「三個速率的 median|ratio−1| 都落在 [0.5,2.0]×預測」、
  **H-B4**「`E(link,r)/E(coop,r) ∈ [0.5,2.0]`，三個速率都是」，而
  **H-B2** 更窄——「**100 Mbit/s 那格** > 2.0× 預測，**且** 三個視窗的 `ratio−1` 同號」。
  `analyse.py:431-436` 則是**每一格**各自貼 H-B1／H-B2／「帶外、符號混雜」。
  本輪兩組三速率全部在內，所以組級結論也成立；但 **FINDINGS 不可把逐格標籤當成註冊的那個判準**。
  📌 附帶一件因此浮出來的事：第四次 campaign 修法前的 `link 2M: H-B2 systematic bias`，
  按註冊判準**在那個速率上根本不是一個註冊過的結論**（H-B2 只註冊在 100 M 那格）——
  修法後它是 H-B1，所以不影響結果，但那個標籤當時就不該那樣印。

## ⑦ 仍然沒做的

- **一臂都沒跑**（本輪全離線）。第五次 campaign `2026-09-19T115737Z_full` 的 `summary.json`
  **還沒產生**，六格 H-B 判決**一次都還沒算過**；`FINDINGS.md` 未開始。
- `ndt status --check` 對 `--telemetry` fabric 的實際 rc 仍沒看過。
- 24⑤ 的四條舊候選仍在。

**[Co-developed with claude code -- Adam]**

---

# Round 10（裁決 38＋39＋任務 C「H-C 註冊層級」，2026-09-24 06:58–07:5x UTC）

**head**：`bc1db4c0`。commit 依序：`56d83ee8`（`git merge --no-edit trunk`，25 顆，無衝突）→
`106a06bf`（**只加測試、不動生產碼**；16 格在這顆上是紅的，紅跑在這顆上取）→
`308cc6a5`（裁決 38＋H-C 的修法、M-E37..M-E43、閘門印「還有誰紅」）→ `ddcef442`（六支儀器成檔；🔴 round 11 更正（裁決 40(e)）：本輪成檔的儀器共**七支**——這顆的六支，加上 `106a06bf` 的 `red_against.py`）→
`0fd507c8`、`06e47cae`（`red_against.py` 兩個 harness 錯）→ `bc1db4c0`（`scan_onpath_edges.py` 的「used」改成分析自己的答案）。
沒 sudo、沒 `ndt`、沒碰 lab、沒 live run、沒編譯、沒 `pkill -f`／`pgrep -f`／`killall`。
**只動** `doc/audit/2026-09-19_telemetry-three-groups/` 底下（`FINDINGS.md`／圖／`summary.json` 一個字沒動、沒 commit）與這份 SUMMARY。

- 🔴 **這份 SUMMARY 不能 commit**：它在 worktree 之外、被主 checkout 的 `.gitignore:46`（`scratch/`）擋著（`git check-ignore -v` 量的）。交付訊息給的是它的行數與 sha256。
- Commit trailer 是 `Co-Authored-By: Claude Opus 5.5 (1M context)`，**不是**派工訊息寫的 `Claude Fable 5.1`：本 session 是 Opus 5.5，寫別的模型名是錯的署名；系統的署名規則也是這一行。
- 口徑：**觀測**＝我讀到或跑出來、有 log 或行號的；**推論**＝由觀測推出、沒有另外量的。下面每段分開寫。
- 行號：引用 **round 9 以前的 SUMMARY** 時用的是本輪就地更正**之前**的原行號（與裁決 39 的引用一致）。

## ① 裁決 38：註冊過的 H-B 標籤只在 PREREG 註冊它的那一層貼

**觀測（PREREG）**：`PREREG.md:251` H-B1「三個速率的 median|ratio−1| **都**落在 [0.5, 2.0] × 0.674/√N」；
`:252` H-B2「100 Mbit/s 那格 > 2.0× 預測，**且**三個視窗的 `ratio−1` 同號」；`:254` H-B4「`E(link,r)/E(coop,r) ∈ [0.5, 2.0]`，三個速率都是」。
**觀測（修前碼 `56d83ee8`）**：`analyse.py:432` 逐格 `row["verdict"] = "H-B1 shot-noise limited"`；`:435` 逐格
`"H-B2 systematic bias" if same_sign`（**任何速率**）；`:459` 逐速率 `"H-B4 the two paths are equally accurate"`。組級彙總不存在。

**改了什麼（`308cc6a5`）**
- 逐格：`verdict` 鍵**拿掉**，換成 `description`（`inside the shot-noise band`／`above the shot-noise band, every window the same sign`／
  `above …, signs mixed`／`below …`／`no reading`）＋`position`／`same_sign`／`band`。拿掉而不是留著改名，是因為它的值「H-B1 …」
  離被抄進 FINDINGS 只差一次複製；`test_no_cell_or_rate_row_carries_a_label_registered_at_the_group_level` 釘住。
- 組級：`registered_sampling()`（`analyse.py:494`）每個處理組判一次 H-B1（`REGISTERED_RATES_MBIT = (2, 20, 100)` 三格都在帶內）
  與 H-B2（只看 `H_B2_RATE_MBIT = 100`：帶上方且每窗同號）；`registered_cross_group()`（`:579`）判一次 H-B4。
  註冊速率缺一格＝`None`（不判），不當成在帶內。`label` 只有在假設成立時才以假設名開頭。
- `summary.json` 兩層都留：`sampling_error`／`sampling_error_cross_group`（逐格**描述**）與
  `sampling_error_by_group`／`sampling_error_cross_group_registered`（**註冊判決**）。`render()` 另印「registered … the only lines FINDINGS may quote」。
- H-B3 的歸因**沒動**：PREREG `:253` 本來就把它註冊在逐速率。

**紅（在 `106a06bf`＝測試已 commit、生產碼未動，逐字）**——`red-38-hb-group-level.p3e-106a06bf.log`，`Ran 16 tests` ／ `FAILED (failures=11)`：
```
:123  FAIL: test_two_rates_inside_and_one_outside_is_NOT_H_B1_for_the_group (test_analyse.RegisteredLevelTest.…)
:135  AssertionError: 'cooperative' not found in {} : no registered H-B label at the group level at all -- PREREG 5.2 registers H-B1 over the three rates together
:79   AssertionError: 'H-B1' unexpectedly found in 'H-B1 shot-noise limited' : verdict='H-B1 shot-noise limited' in {'group': 'cooperative', 'offered_mbit': 20, …
```
裁決指定的那格（兩個速率在帶內、一個在帶外）在舊碼上紅，是因為**組級不存在**；`:79` 那格紅，是因為**逐格字串本身就是註冊標籤**——正是裁決 38 的兩半。
（六格一開始是 `KeyError` 的 ERROR；照本回合規則改成 `.get()`／`assertIn` 讓它 FAIL 在發現本身上，再 commit、再取紅。）
最終 head 以 `red_against.py --rev 56d83ee8 --file analyse.py` 重現，同 11 格：`red-38-hb-group-level-reproduced.p3e-bc1db4c0.log`。
🔴 **round 11 補（裁決 40(d)）：`tests/test_analyse.py` 在 tests-only 那顆之後改過，上面沒說。** 紅跑在 `106a06bf` 上跑的是 sha256 `939afc84323f`（兩份 log 的 `# as run:` 行），`bc1db4c0` 的是 `a232540c77d2`。`git diff 106a06bf bc1db4c0 -- tests/test_analyse.py` 只有兩行、兩行都是**註解**，在 `308cc6a5`：PREREG 行號 `PREREG.md:262-268` → `:262-266`、`:275-276` → `:276-277`（我自己的引用差一行，⑥ 那條）；沒有任何斷言或測試碼變。最終 head 重現的兩份紅（`red-38-hb-group-level-reproduced`／`red-C-hc-level-reproduced.p3e-bc1db4c0.log`）檔頭都是 `a232540c77d2`，所以**最終的測試檔就是看過紅的那一份**。（`106a06bf` 只動 `tests/`：`git show --stat` 六個檔都在 `tests/` 底下，我查過。）

**格子的設計**：帶外那格放在 **100 M、不是第一格**——放第一格的話，「退回取第一格」的變異會剛好答對。另一格放在 2 M
（第五次 campaign 的真形狀 `-0.3508, -0.2953, +0.1865`），擋「退回取最後一格」。兩個正對照（三格都在內＝H-B1、100 M 帶上方且同號＝H-B2）：
一個永遠說「不是 H-B1」的彙總會通過每一個負的格子。

**變異**：M-E37（裁決 38 指名）`all_registered_rates` 只看第一個註冊速率 → 綁 `test_two_rates_inside_and_one_outside_is_NOT_H_B1_for_the_group`；
M-E38 `H_B2_RATE_MBIT = 2`（第四次 campaign 修前 `link 2M: H-B2` 的形狀）→ 綁 `test_a_same_sign_excess_at_2_Mbit_is_NOT_H_B2`。閘門結果見 ⑤。

## ② 任務 C：H-C 在 PREREG 註冊在哪一層、碼貼在哪一層（第一次查）

### 觀測：PREREG 5.3（逐行）
- `:262` 主軸＝「**1024 B 梯子上三組共同有的每一階**」；`:263` `Δkernel(g, k) = kernel_CPU(g, k) − kernel_CPU(none, k)`；
  `:264` 橫軸 `S(k)`＝該階量到的 samples/s；`:266`「擬合 `Δkernel = F + m · S`」。
- `:270` H-C1「`m ∈ [103, 618] µs/sample` **或** 固定份額 `F / (F + m·S_top) ≥ 0.5`」；
  `:271` H-C2「`F / (F + m·S_top) ≤ 0.2` **且** `Δ(高階)/Δ(低階) ≈ S(高)/S(低)`」；`:272` H-C3「介於兩者」；
  `:273` H-C0「**同一格**三個視窗（或三個 rep）的 `Δkernel` 散佈 **大於** `Δkernel` 本身」→「不擬合、不報數字」。
- `:276-277` 附帶註冊：「`bmv2_total(cooperative)/bmv2_total(none)` **在相同階** ∈ [0.90, 1.15]」。`:278-279` softirq「逐組報」＋預測，沒有判準區間。
- `:357`（8(b)）：報的數含「最低階與最高階的 `Δkernel` 兩個點」。

### 觀測：修前碼（`56d83ee8` 行號）
- `:694` `out["fits"][group] = {"fit": fit, "verdict": cpu_verdict(fit)}`——**每個處理組一個判決**；逐階列只有 `resolved` 布林。
- `:675` `for kpps in sorted(set(treated) & set(base))`——階＝**該組 ∩ none**，不是三組共有。
- `:852` `bmv2 = cpu_comparison(arms, frame=1024, label="bmv2")`——同一支擬合＋`cpu_verdict` 套在 bmv2 上，
  `summary.json` 的 `cpu_bmv2.fits.*.verdict` 印 H-C 標籤；[0.90, 1.15] 這個比值**整支碼沒有**（grep `0.90`／`1.15`／`bmv2_total`：0 行）。
- `:707-710` `cpu_verdict`：H-C1＝`share ≥ 0.5 or within_band`，**先判**；H-C2＝`share ≤ 0.2`（**只這一個條件**）；其餘 H-C3。
- `:679`／`:682` H-C0 的散佈＝兩組各自「兩臂之間原始 CPU 的全距」取大者；`:687` 只有**每一階**都解析不出來才判 H-C0，其餘把解析不出的階剔出擬合。
- `:634` `S_top`＝擬合點中最大的 S。

### 對照與處置
| 項目 | PREREG | 碼（修前） | 一致？ | 本輪 |
|---|---|---|---|---|
| H-C1/2/3 的判決層級 | 每個處理組一次擬合 | 每組一次（`:694`） | ✅ | 釘住：`test_the_H_C_verdict_is_made_once_per_treated_group_over_every_common_rung`，M-E42（擬合退回前兩階）綁它 |
| 擬合用哪些階 | 三組共同的每一階（`:262`） | 該組 ∩ none（`:675`） | ❌ | **改**成三組交集（`analyse.py:801-814`），紅先、M-E39；沒有共同階時說「no rung is common to all three groups」，不冒充 H-C0 |
| bmv2 | 只有 coop/none 逐階比值 ∈ [0.90, 1.15]（`:276`） | 套 H-C 標籤、比值沒算 | ❌ | **改**：bmv2 擬合留作描述、`verdict: null`＋註記（M-E40）；新增 `cpu_bmv2_ratio` 逐階比值（`analyse.py:848`，M-E43）；不做跨階彙總（沒註冊） |
| H-C2 的第二個條件 | 「且 Δ(高)/Δ(低) ≈ S(高)/S(低)」 | 沒算 | ❌ | **未改**：「≈」沒有註冊容差，挑一個＝替 PREREG 決定 H-C2。碼註解寫明（`analyse.py:871-879`），數據另列（③） |
| H-C1、H-C2 同時成立時 | 沒註冊先後 | 先判 H-C1 | ⚠️ | **未改**，揭露（第五次 coop 正是這個情形，③） |
| H-C0 的散佈量 | 同一格三窗／三 rep 的 **Δkernel** 散佈 | 兩臂之間**原始 CPU** 全距取大者 | ❌ | **未改**：梯子臂每格兩臂（兩個世代）、每階 1–3 rep，「三個視窗（或三個 rep）」對到哪裡需要裁決。碼註解寫明（`analyse.py:818-823`） |
| H-C0 的後果 | 該格「不擬合、不報數字」 | 剔除該階、其餘照擬合；全不可解才 H-C0 | ⚠️ | **未改**：PREREG 沒說部分格不可解時整組擬不擬合 |
| `S_top` | 未定義（推論：最高階的 S） | 擬合點中最大的 S | ⚠️ | 未改；第五次兩者相同（最高階 110 kpps 就是最大 S） |

**紅（`106a06bf`，逐字）**——`red-C-hc-level.p3e-106a06bf.log`，`Ran 13 tests` ／ `FAILED (failures=5)`：
```
:43  AssertionError: Lists differ: [1.0, 8.0, 20.0] != [1.0, 8.0]      (… : the cooperative fit used rungs the link group never measured)
:61  AssertionError: 'H-C' unexpectedly found in 'H-C3 mixed -- the decomposition IS the result (PREREG 5.3)' : cooperative
:70  AssertionError: None != [0.9, 1.15] : {}
:32  AssertionError: [] is not true : no registered bmv2 comparison at all
:79  AssertionError: {'fixed_percent': 4.934…, …, 'points': 3, …} is not None : H-C1 cost is dominated by a fixed component (08-20 reproduces)
```
（`:79`：拿掉 link 1024 B 臂之後，舊碼照樣替 coop 擬合並判 H-C1——沒有三組共同的階，註冊的軸根本不存在。）
釘層級那格在舊碼上是**綠的**——它守的是本來就對的東西，它的紅在 M-E42 之下看（⑤）。最終 head 重現：`red-C-hc-level-reproduced.p3e-bc1db4c0.log`，同 5 格。

**推論**：bmv2 與階集合兩件和裁決 38 同一類（註冊標籤貼在沒註冊的地方；比較的母體不是註冊的那一個）。
H-C2／H-C0／先後那幾條不同類：不是碼貼錯層，是 PREREG 沒把判準寫到可以機械執行的程度——要裁決，不是要改碼。

### 範圍外、同一類的兩個觀測（登記，沒動）
- **H-A2**（`PREREG.md:220`）「**< 0.60，且兩個 frame 尺寸與兩遍都同向**」；碼 `ratio_verdict` 逐 (組, frame) 只看 `< 0.60`。
  第五次 `link/none` 在 64 B、1024 B 都是 0.533，兩遍 link 12／20 對 none 30／30 都在下方（summary 的 `cells` 讀的）——**推論**：條件大概成立，
  但碼沒驗；FINDINGS §2 目前逐 frame 引 H-A2。
- **H-B3**（`:253`）「emitter 的 `dropped_*`／`enobufs` **在該視窗** > 0」；碼加總的是**梯子臂**的 `emitter.log`（`analyse()` 只走 `arms`），
  視窗自己的 `emitter.log` 在 `test_real_shape.py` 的 `NOT_WRITTEN` 裡明寫「the analysis reads the ARM's copy」。第五次沒有任何 ratio > 2.0，沒觸發。

## ③ 第五次 campaign 的判決（`raw/2026-09-19T115737Z_full`，存在，唯讀）

`analyse-115737Z.p3e-bc1db4c0.log`；summary.json 在 `wt-p3-measure-0919/scratch/p3e-round10/summary.115737Z.bc1db4c0.json`
（gitignored，sha256 `d48fa3ca6beefbe5…`）。**主 checkout 一個檔都沒寫**；`wt-audit-raw` 的後備路徑沒用到。

### H-B——組級是唯一可以進 FINDINGS 的那一層
| 組 | 2 M median\|e\|／帶 | 20 M | 100 M | **組級註冊判決** | 修前逐格標籤 | 和逐格不同？ |
|---|---|---|---|---|---|---|
| cooperative | 0.2953／[0.0713, 0.2853] **帶上方**，符號混（−0.351, −0.295, +0.187） | 0.0274／[0.0226, 0.0902] 內 | 0.0154／[0.0101, 0.0404] 內 | **neither H-B1 nor H-B2 holds as registered**（H-B1 否：2 M 在外；H-B2 否：100 M 在內） | 2 M「above…mixed」；20 M、100 M「**H-B1**」 | **是**：兩個逐格 H-B1 在組級不成立 |
| link | 0.0746／[0.0713, 0.2853] 內 | 0.0344／[0.0202, 0.0807] 內（N 用 5 條邊） | 0.0229／[0.0090, 0.0361] 內（N 用 5 條邊） | **H-B1 shot-noise limited** | 三格都「H-B1」 | 否 |
| link vs coop | 0.253 **外** | 1.255 內 | 1.489 內 | **not H-B4**（2 M 在 [0.5, 2.0] 外） | 20 M、100 M「**H-B4**」；2 M「NOT equally accurate」 | **是**：兩個逐速率 H-B4 在組級不成立 |

- H-B3：沒有任何速率 link/coop > 2.0，不觸發；emitter 的 `dropped_*`＝0、`enobufs`＝0。
- **觀測**：link 2 M 的 0.0746 距帶下緣 0.0713 只差 0.0033；coop 2 M 的 0.2953 超出上緣 0.2853 只差 0.0100。**推論**：兩個組級結論都落在帶邊，對 N 的計法敏感。
- **觀測**：link 20 M、100 M 的帶是用 **5 條邊**算的（`members[0]`＝p1 讀到 5 條，p2、p3 讀到 4，⑧）。改用 PREREG 的數字帶
  （4 條邊：[0.023, 0.090]、[0.010, 0.040]）這兩格一樣在內——**判決不受影響，但裁決 37⑧ 的 `members[0]` 候選在第五次 campaign 真的發作了**。

### H-C
| | 修前 summary 的標籤 | 本輪 | 數字 |
|---|---|---|---|
| kernel，cooperative | H-C1 | **H-C1**（碼：m 在帶內） | F 0.9234 %、m 122.89 µs/sample、share 0.0722 |
| kernel，link | H-C2 | **碼印 H-C2，但只滿足兩個註冊條件的第一個** | F 0.7692 %、m 79.00、share 0.0623 |
| bmv2，cooperative | H-C1 | 無標籤（描述） | —— |
| bmv2，link | H-C2 | 無標籤（描述） | —— |

`hc2-second-condition-data.p3e-bc1db4c0.log`（腳本算，**不下判決**），最低階 1 kpps／最高階 110 kpps：
coop `Δ(高)/Δ(低) = 20.297`、`S(高)/S(低) = 51.802`（兩者之比 0.392）；link `31.505` 對 `58.680`（0.537）。
🔴 **推論，需要裁決**：(1) link 的「H-C2」不能照抄進 FINDINGS——第二個條件沒判，也沒有註冊容差可判；
(2) coop 同時滿足 H-C1（m 在帶內）與 H-C2 的第一個條件（share 0.0722 ≤ 0.2），PREREG 沒註冊先後，「先 H-C1」是碼自己的選擇。**這兩件我沒有替 PREREG 決定。**

**bmv2 註冊比值**（coop/none 逐階，[0.90, 1.15]）：11 階中 **9 階在內**；**12 kpps 1.513、45 kpps 1.164 在外**。沒做跨階彙總（沒註冊）。
**推論，不是判決**：`:277`「落外＝那句話在天花板附近不成立」要看落外的是不是天花板附近——coop 兩臂的天花板是 12 與 30，45 在兩臂之上。

**對帳舊結果**（`reconcile-summary-115737Z.p3e-bc1db4c0.log`，逐葉比 orchestrator 那份 summary.json）：**1424 個葉值相同**；
改的 2 個（`cpu_bmv2.fits.{cooperative,link}.verdict`：H-C1／H-C2 → `null`）；修前獨有 12 個（9 個逐格 `verdict`＋3 個逐速率 `verdict`）；
本輪獨有 49 個（描述、帶、組級判決、`common_rungs`、`cpu_bmv2_ratio`）。**沒有任何數字變**：三組在第五次共有全部 11 階，
所以「三組共同階」的修正在這一輪沒有移動任何一個數；FINDINGS §2、§5 已填的數（天花板、m、固定份額）不受本輪影響。

## ④ 裁決 39 九項，逐項（前後原文）

**①** `tests/synthetic.py:186-191`（修前，現 `:198-208`）：
> 前：「…so `label_of`'s folding of ten pids into one class … was never exercised. … The total is unchanged: ten processes at BMV2_BASE/10 each.」
> 後：「…was never exercised BY A TEST. (In production it always was: every real cpu.jsonl has carried ten bmv2 pids … Ruling 37(3).) …
> Each switch runs at its own BMV2_WEIGHTS share -- ten UNEQUAL weights whose sum is BMV2_BASE … (Ruling 39(1): this comment used to say "the total is unchanged: ten processes at BMV2_BASE/10 each", which stopped being true when round 9 made the shares unequal.)」

同一宣稱的其他出現處（grep `never exercised|BMV2_BASE/10|total is unchanged|總量不變`，回合目錄＋SUMMARY）：碼裡只剩 `:108` 的歷史敘述（「used to be given BMV2_BASE/10」，正確）；
SUMMARY 原 `:1103`（round 8 的「已改成十個行程各 `BMV2_BASE/10`，總量不變」）就地劃掉並加註。

**②** 錨點自掃覆蓋度回退——**觀測**：`anchor-sweep.p3e-e222176d.log` 60 行、兩節（36＋10）；`anchor-sweep.p3e-9204e3e3.log` 49 行、一節（38），外部 10 顆沒掃、表上沒說。
處置：自掃成為 `tests/anchor_sweep.py`（兩節都是碼；第一節讓 bash 自己解析閘門；最後一行印兩節各幾筆，縮水會看得見）。
- 本 head：`45 anchors, 0 that do not resolve exactly once` ／ `13 entries, 0 that do not resolve as declared`（`anchor-sweep.p3e-bc1db4c0.log`）。
  外部 13＝`e222176d` 的 10 ＋ round 7 有、round 8 掉的 7(c) grep ＋ 本輪兩個紅跑 patch。
- **回頭補掃 `9204e3e3`**（git archive）：`38 anchors, 0 …` ／ `11 entries, 0 …`（`anchor-sweep-retro-9204e3e3.p3e-bc1db4c0.log`）——
  round 9 沒掃的外部錨點，在它自己的 head 上**確實都解析得到**；這是量的，不是推的。
- 🔴 **這支掃描第一版是錯的**：7(c) 那條 grep 的正規式，我把 bash 雙引號裡的 `\\\$` 解成 `\\$`（字面反斜線＋行尾），`hits=0 want=0` 是**無論如何都 0** 的假綠。
  修正後加了陽性對照（正規式必須命中離線套件種回去的那行舊碼，否則拒判）。
- 自檢：複本上故意改掉 M-E1 的目標行與 7(c) 的切片起點 → 兩個 `BAD`、rc 1（`anchor-sweep-selfcheck.p3e-bc1db4c0.log`）。

**③**「sum→max ⇒ 34 顆全綠」由推論變量測。`tests/red/sum_to_{max,first}.json` 貼到 **`e222176d` 那棵樹**（`red_against.py --tree-rev e222176d`，
檔頭記下 `test_analyse.py 05740e18ac9e`／`synthetic.py 747e9edfa69e`，與 round 8 red-35-1 記的 `e222176d` 雜湊相同）：
- 單元：兩種都 `Ran 76 tests` ／ `OK (skipped=1)`（`measure-39-3-unit-sum-to-{max,first}-at-e222176d.p3e-06e47cae.log`）。
- 閘門：兩種都基線綠、`mutations: 34   survivors: 0   drifted: 0`、兩控制綠（`measure-39-3-gate-sum-to-{max,first}-at-e222176d.p3e-0fd507c8.log`）。
- 對照（本 head）：兩種都只被 `test_the_ten_bmv2_processes_are_folded_into_one_class_and_SUMMED` 抓到，
  `AssertionError: 42.0 != 150.0 within 3 places (108.0 difference) : rung 1.0`（`measure-39-3-unit-sum-to-{max,first}-at-head.p3e-06e47cae.log`）。
- 🔴 **附帶觀測**：本 head 的 fixture 上 max 與 first **給同一個數 42**——`bmv2-1` 剛好是權重最大的那台。那格斷言的是「和」，兩者都錯所以都被抓；
  但它分不出 max 與 first 彼此。這是「兩個函數在 fixture 上重合」的形狀，這次重合的是兩個**錯的**函數，不影響判決，記下。

**④** 四處引用：
- (a) `synthetic.py`（原 `:392`）「redirects to $out/control.meta at :648」→「at :647 -- `} > "$out/control.meta"`; :648 is the `note` after it」（`drive_e.sh:647`／`:648` 讀過）；SUMMARY 原 `:1250` 同改。
- (b) SUMMARY 原 `:1164`「全文 10 列在 log 的 `:78-90`」→「14 列在 `:72-85`」。該檔換行數 85、末行 `:85`（量的；裁決寫 86 行，我量到 85）。
- (c) SUMMARY 原 `:1358`「`inventory.py:88-96`」→「`:133`（`cardinalities()` 的 `fh.readline()`）；`keys_of` 的 jsonl 分支 `:102-105`」。
- (d) 三列 `115/115 cells ok` 補成整行 `115/115 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)`（原 `:909`、`:1137`、`:1333`；三份 log 的那一行都讀過）。
- 🔴 **多查一步**（`verbatim-cells-check.p3e-bc1db4c0.log`）：round 7–9 三張表每個反引號格拿去它那列指名的 log 找——39 列、**沒有一格在 log 裡找不到**；
  但有 **19 格是子字串不是整行**：3 格是上面那三列（掉的是「NOT CHECKED AT ALL」，有意義，已補）；14 格只掉了時間尾巴（`in 1.732s`）或前綴（`--> `、`# hazard_scan: `）；
  2 格（原 `:912` 的 `AttributeError`、`:916` 的 `coop`）本來就是敘述裡夾的片段。那一欄的「逐字」＝**字元完全相符的節錄**，不保證是整行；只補了有意義的那 3 格。

**⑤** 列數：腳本逐列分類（`recount-39-5-red-35-3-rows.p3e-bc1db4c0.log`，一條缺陷一條規則、不逐列挑）——**14 列**＝4 鍵集合＋10 基數，`:72-85`：
(1) 家族鍵巢錯 **8 列**（不是 6：另有兩列鍵集合）、(2) `excluded_host_facing` 1、(3) `control.meta` 1（鍵集合列，不是基數列）、(4) 十個 bmv2 1、
裁決 35① 本身 2、宣告過的 `arm.meta` 12 鍵 1；**8+1+1+1+2+1＝14**。原 `:1082` 與 `:1163` 就地更正，省略的 7 列逐行號列出（`:74`、`:77-81`、`:83`），補上漏的 `_before samples_by_family`（`:81`）。

**⑥** 字高改用量的。`tests/postcheck_real_render.py` 在**真的** `_line_panels` 之後讀每個 annotation 的 `get_window_extent(renderer)`：
- 第四次（`postcheck-9a-real-render-105759Z.p3e-bc1db4c0.log`）：三個面板軸高 set_ylim 前後都是 206.4880 pt；**真字框高 9.36 pt**（模型 11 pt）；
  最緊的是 bmv2 面板的 `coop`，真字框頂 205.67 pt、軸頂 206.49 pt，**餘 +0.82 pt**；9 個標籤全在框內。
- 第五次（`postcheck-9a-real-render-115737Z.p3e-bc1db4c0.log`）：9 個全在框內，最緊同為 +0.82 pt。
- **推論**：11 pt 模型比真字高多 1.64 pt，用模型解出的上緣對真字是保守的。round 9 那句（原 `:1305`）就地更正：當時「軸框是量的、字高是模型」，現在兩半都是量的。

**⑦** FINDINGS §6——**觀測**：合進來的 trunk（`c1f4174f`）已把兩條威脅效度寫進 ~~`FINDINGS.md:209-217`~~ `FINDINGS.md:209-216`（第 6、7 條；round 11 更正，裁決 40(e)：第 7 條止於 `:216`），佔位符 `<跑完補：實際遇到的>` 已不在（grep 0 行）。
**我沒有動 FINDINGS**（派工明令）。🔴 請 orchestrator 看：第 6 條寫的是**第四次** campaign 的 18/9，而 FINDINGS 報的是**第五次**，第五次是 `{0: 9, 4: 16, 5: 2}`（⑧）；
第 7 條說「本文件只引用組級判決（見 §3）」——組級判決現在在 summary.json 裡了（③）。

**⑧** `tests/scan_onpath_edges.py`（每次留 log）：
- 第四次：`{0: 9, 4: 18}`（coop {4:9}、link {4:9}、none {0:9}）——裁決 39⑧ 那個 18/9 **現在有掃描作證**（`scan-39-8-onpath-edges-105759Z.p3e-bc1db4c0.log`）。
- **第五次：`{0: 9, 4: 16, 5: 2}`**——link 20 M 的 p1 多了 `s5-eth4`、link 100 M 的 p1 多了 `s6-eth1`；兩格 `members[0]` 都是 p1，**整格用 N＝5**，
  另兩窗讀到 4（`cells whose windows disagree on the edge count: 2 of 9`，`scan-39-8-onpath-edges-115737Z.p3e-bc1db4c0.log`）。
- 🔴 這支掃描第一版把 `none` 格印成「used 0」——分析其實退回註冊的 4。改成直接呼叫 `analyse.links_for_prediction`（`bc1db4c0`），錯的那兩份 log（`…p3e-06e47cae`）刪了。

**⑨** 三件候選都做了：
- (a) 閘門 `report()`／`report_shell()` 在每個 `caught` 下印「also red: …」或「(no other case went red)」——「0 survivors」不再被讀成「只殺該殺的」。
  M-E35 的整套結果：`caught   M-E35: … (test_the_ten_bmv2_processes_are_folded_into_one_class_and_SUMMED went red)` ／ `(no other case went red)`（`mutate.p3e-bc1db4c0.log:125-126`）——**只有綁的那一格**。
  同一個輸出也照出一件 round 9 沒看到的事：**M-E36 另外還讓兩格紅**（`also red: test_ends_that_are_far_apart_on_the_display_are_not_moved_at_all test_three_ends_within_a_label_height_get_three_different_offsets`，`:127-128`）。round 9 的「其餘三格照綠」（`red-37-5-…log:16-19`）沒有錯，但那份紅跑只跑了 `Figure3LabelsStayInsideTest` 的 4 格（`Ran 4 tests`），說的是**那一類**的另三格；整套裡 `Figure3EndLabelTest` 的兩格也紅——夾住的是 `end_label_offsets` 本身，那兩格正是測它。不是缺陷，是「只殺該殺的」這個讀法本來就沒被量過的例子。全閘 43 個 caught 中 16 個「沒有其他格紅」，其餘的都列了還有誰（`also red` 共 73 行）。
- (b) 三件儀器成檔：`tests/compare_inventory_instruments.py`（red-37-1；本 head 重跑**逐字重現** round 9 的四行，`red-37-1-reproduced.p3e-bc1db4c0.log`）、
  `tests/postcheck_real_render.py`（9a＋⑥）、`tests/check_inventory_fresh.py`（9b；第四次 raw：差異 0；**第五次 raw：差異 1**——`window.json per_edge_peak_bps` [0,5] 對提交的 [0,4]，
  那份真相取自第四次，第五次多了 5 條邊的視窗；`postcheck-9b-inventory-fresh-{105759Z,115737Z}.p3e-bc1db4c0.log`）。
  另成檔：`tests/red_against.py`（本輪所有紅跑）、`tests/anchor_sweep.py`、`tests/scan_onpath_edges.py`、`tests/postcheck_guard_equivalence.py`、`tests/red/*.json`。
  全部**不是** `test_*.py`：閘門把 `tests/` 複製進每個變異體，錨點掃描若進了單元套件，會讓每個變異體與兩個控制都紅。
- (c) `headroom == 0`：`test_a_label_with_EXACTLY_zero_headroom_is_handled_not_divided_by`（三個標籤、27.5 pt、最低那顆在軸底，解出的上緣剛好裝滿），M-E41（`<= 0` → `< 0`）綁它。
  另把「0 以下守衛是等價變異」**跑了**而不是複述（`postcheck-guard-equivalence.p3e-bc1db4c0.log`）：三個真面板、20 標籤塞 50 pt（其中 15 顆 headroom < 0）、剛好 0 的一格——
  三種守衛（原樣／`< 0`／拿掉）只在剛好 0 時不同，後兩者 `ZeroDivisionError: float division by zero`。`plot.py` 的註解據此改寫。

**⓪(b) 那句機制**（原 `:1275`）就地更正。`measure-39-0b-telescoping.p3e-bc1db4c0.log`：round 8 fixture 的 `bmv2-1` 在一個梯階內逐列增量
`[7, 8, 7, 8, …]`（`.5` 確實被 `int()` 截掉）、加總 120＝末−首——逐列累加、每鍵 telescoping，量的。

## ⑤ 閘門與紅跑（最終 head `bc1db4c0` 除非另標；log 在 `scratch/overnight-2026-09-05/logs/gates-0910/`）

> 「判決行／關鍵行」一欄＝**字元完全相符的節錄**（見 ④(d)）；每份 log 真正的最後一行都是 `### rc=N`。

| 跑什麼 | sha | rc | 判決行／關鍵行 | log |
|---|---|---|---|---|
| **變異閘 M-E1..M-E43 ＋ 2 控制** | `bc1db4c0` | **0** | **`mutations: 43   survivors: 0   drifted: 0`** | `mutate.p3e-bc1db4c0.log` |
| 變異閘（同上，前一顆 head；兩棵樹只差 `scan_onpath_edges.py`，閘門不讀它） | `06e47cae` | 0 | `mutations: 43   survivors: 0   drifted: 0` | `mutate.p3e-06e47cae.log` |
| 閘門 self-test | `bc1db4c0` | 0 | `passed: 14   failed: 0` | `test_mutate_gate.p3e-bc1db4c0.log` |
| 離線整輪（`E_DRIVER` 未設） | `bc1db4c0` | 0 | `passed: 78   failed: 0` | `offline-round.p3e-bc1db4c0.log` |
| 單元（`p4_proxy/venv/bin/python` 3.13.13，無 matplotlib） | `bc1db4c0` | 0 | `Ran 94 tests in 1.284s` ／ `OK (skipped=1)` | `unit-venv.p3e-bc1db4c0.log` |
| 單元（`/home/adam/miniconda3/bin/python3` 3.13.13，mpl 3.10.8） | `bc1db4c0` | 0 | `Ran 94 tests in 2.294s` ／ `OK` | `unit-py3.p3e-bc1db4c0.log` |
| `hazard_scan.py` ×4（三支回合腳本＋閘門，檔名在 log 的 command 行） | `bc1db4c0` | 0 | `# hazard_scan: 4 file(s) given, 4 scanned, 0 unreadable, 0 finding(s)` | `hazard-scan.p3e-bc1db4c0.log` |
| 錨點自掃（兩節） | `bc1db4c0` | 0 | `--> 45 anchors, 0 that do not resolve exactly once` ／ `--> 13 entries, 0 that do not resolve as declared` | `anchor-sweep.p3e-bc1db4c0.log` |
| 錨點自掃，回頭掃 round 9 的樹 | `9204e3e3`（樹）／`bc1db4c0`（工具） | 0 | `--> 38 anchors, 0 …` ／ `--> 11 entries, 0 that do not resolve as declared` | `anchor-sweep-retro-9204e3e3.p3e-bc1db4c0.log` |
| 錨點自掃的自檢（兩處故意漂移） | `bc1db4c0` | **1**（應為 1） | `m1 … hits=0  BAD` ／ `offline 7(c) slice start … hits=0 want=1 BAD` | `anchor-sweep-selfcheck.p3e-bc1db4c0.log` |
| `tests/shell/check_gate_anchors.py HEAD` | `bc1db4c0` | 0 | `115/115 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)`（掃不到本閘門；本閘門由上面的自掃負責） | `check_gate_anchors.p3e-bc1db4c0.log` |
| 紅跑 38（測試已 commit、生產碼未動） | `106a06bf` | 1 | `AssertionError: 'cooperative' not found in {} : no registered H-B label at the group level at all -- …`；`FAILED (failures=11)` | `red-38-hb-group-level.p3e-106a06bf.log` |
| 紅跑 38 在最終 head 重現（`--rev 56d83ee8 --file analyse.py`） | `bc1db4c0` | 1 | `FAILED (failures=11)` | `red-38-hb-group-level-reproduced.p3e-bc1db4c0.log` |
| 紅跑 C | `106a06bf` | 1 | `AssertionError: Lists differ: [1.0, 8.0, 20.0] != [1.0, 8.0]` 等 5 格；`FAILED (failures=5)` | `red-C-hc-level.p3e-106a06bf.log` |
| 紅跑 C 在最終 head 重現 | `bc1db4c0` | 1 | `FAILED (failures=5)` | `red-C-hc-level-reproduced.p3e-bc1db4c0.log` |
| 量測 39③，`e222176d`＋sum→max／first，單元 | `06e47cae`（工具） | 0 | `Ran 76 tests` ／ `OK (skipped=1)`（兩份） | `measure-39-3-unit-sum-to-{max,first}-at-e222176d.p3e-06e47cae.log` |
| 量測 39③，`e222176d`＋sum→max／first，那棵樹自己的閘門 | `0fd507c8`（工具） | 0 | `mutations: 34   survivors: 0   drifted: 0`（兩份） | `measure-39-3-gate-sum-to-{max,first}-at-e222176d.p3e-0fd507c8.log` |
| 量測 39③ 對照，本 head＋同兩個 patch | `06e47cae` | 1 | `AssertionError: 42.0 != 150.0 within 3 places (108.0 difference) : rung 1.0` | `measure-39-3-unit-sum-to-{max,first}-at-head.p3e-06e47cae.log` |
| 39⑤ 列數重數 | `bc1db4c0` | 0 | `rows: 14  (4 keys missing, 10 cardinality)` | `recount-39-5-red-35-3-rows.p3e-bc1db4c0.log` |
| 39④(d) 逐字格檢查 | `bc1db4c0` | 0 | `table rows with a log checked: 39` | `verbatim-cells-check.p3e-bc1db4c0.log` |
| 39⑥ 真圖、真字框（第四次／第五次） | `bc1db4c0` | 0 | `EVERY LABEL'S REAL TEXT BOX INSIDE ITS OWN AXES: True` ／ `EVERY AXES BOX UNMOVED BY set_ylim: True` | `postcheck-9a-real-render-{105759Z,115737Z}.p3e-bc1db4c0.log` |
| 39⑧ 邊數掃描（第四次／第五次） | `bc1db4c0` | 0 | `{"0": 9, "4": 18}` ／ `{"0": 9, "4": 16, "5": 2}` | `scan-39-8-onpath-edges-{105759Z,115737Z}.p3e-bc1db4c0.log` |
| 37(9b) inventory 重抽（第四次＝它的來源） | `bc1db4c0` | 0 | `DIFFERENCES BETWEEN THE COMMITTED INVENTORY AND A FRESH EXTRACTION: 0` | `postcheck-9b-inventory-fresh-105759Z.p3e-bc1db4c0.log` |
| 同上對第五次（不是漂移檢查，是形狀差） | `bc1db4c0` | 1 | `DIFFERENCES BETWEEN THE COMMITTED INVENTORY AND A FRESH EXTRACTION: 1` | `postcheck-9b-inventory-fresh-115737Z.p3e-bc1db4c0.log` |
| 37(1) 雙儀器比較（成檔後重跑） | `bc1db4c0` | 0 | `control.meta (C1)    missing from the fixture: ['requirement', 'verdict']` | `red-37-1-reproduced.p3e-bc1db4c0.log` |
| 39⑨(c) 守衛等價量測 | `bc1db4c0` | 0 | `THE GUARD IS EQUIVALENT AWAY FROM ZERO AND NOT AT ZERO: True` | `postcheck-guard-equivalence.p3e-bc1db4c0.log` |
| 39⓪(b) telescoping 量測 | `bc1db4c0` | 0 | `per-row increments cpu_for_window ADDS: [7, 8, 7, 8, …]` | `measure-39-0b-telescoping.p3e-bc1db4c0.log` |
| `analyse.py` 第五次 campaign | `bc1db4c0` | 0 | `summary -> …/scratch/p3e-round10/summary.115737Z.bc1db4c0.json` | `analyse-115737Z.p3e-bc1db4c0.log` |
| 對帳 orchestrator 的 summary.json | `bc1db4c0` | 0 | `leaf values identical in both: 1424` | `reconcile-summary-115737Z.p3e-bc1db4c0.log` |
| H-C2 第二條件的輸入（不下判決） | `bc1db4c0` | 0 | `delta(high)/delta(low) = 31.505    S(high)/S(low) = 58.680`（link） | `hc2-second-condition-data.p3e-bc1db4c0.log` |

### 新變異各綁哪一格、以及還有誰跟著紅（閘門逐字）
| 變異 | 綁的格 | 閘門怎麼說（`mutate.p3e-bc1db4c0.log`） |
|---|---|---|
| M-E37 組級退回取第一格（裁決 38 指名） | `test_two_rates_inside_and_one_outside_is_NOT_H_B1_for_the_group` | caught；also red: `test_H_B4_needs_all_three_rates_…`、`test_one_signed_excess_at_100_Mbit_IS_H_B2`（H-B4 共用同一個輔助函式；H-B2 那格看到的是 H-B1 成立） |
| M-E38 `H_B2_RATE_MBIT = 2` | `test_a_same_sign_excess_at_2_Mbit_is_NOT_H_B2` | caught；also red: `test_one_signed_excess_at_100_Mbit_IS_H_B2` |
| M-E39 階＝該組 ∩ none | `test_a_rung_one_group_does_not_have_is_in_NO_groups_fit` | caught；no other case |
| M-E40 bmv2 又有 H-C 標籤 | `test_bmv2_carries_NO_H_C_label` | caught；no other case |
| M-E41 守衛 `<= 0` → `< 0` | `test_a_label_with_EXACTLY_zero_headroom_is_handled_not_divided_by` | caught（`ZeroDivisionError`）；no other case |
| M-E42 擬合退回前兩階 | `test_the_H_C_verdict_is_made_once_per_treated_group_over_every_common_rung` | caught；no other case |
| M-E43 bmv2 區間放寬成 [0.5, 2.0] | `test_a_bmv2_ratio_outside_090_115_is_reported_outside` | caught；also red: `test_the_registered_bmv2_comparison_is_coop_over_none_at_each_rung` |

兩個控制 `C-E1`／`C-E2` 照綠（`:143-144`）。

## ⑥ 本輪我自己的錯（交付前抓到，照實列）
- `red_against.py` 第一次 `--tree-rev`：在回合目錄下跑 `git archive`，repo 相對路徑不存在 ⇒ git 128，**一格都沒跑**。修在 `0fd507c8`；那兩份 log 刪掉，重跑的 log 檔頭寫明。
- `red_against.py` 整套模式寫成 `unittest -v discover`，unittest 拒收（rc 2、沒跑）。修在 `06e47cae`，重跑。
- 錨點掃描 7(c) grep 的反斜線解錯（④②）——沒補陽性對照的話它會一直假綠。
- 邊數掃描把 `none` 印成「used 0」（⑧）。
- 自己的 PREREG 行號引用差一行（bmv2 陳述是 `:276-277`，我先寫 `:275-276`），commit 前改掉。
- 等價量測的格名先寫「16 顆 headroom < 0」，公式算是 15；改成由程式算。
- H-B4 不成立的標籤先寫成「H-B4 does not hold: …」——以假設名開頭；自己的測試抓到，改成「not H-B4: …」。

## ⑦ 候選／仍然沒做的
- 🔴 **需要裁決（任務 C 查出，我沒有替 PREREG 決定）**：H-C2 第二條件「≈」的容差；H-C1 與 H-C2 同時成立時的先後（第五次 coop 正是）；
  H-C0 的散佈量（兩臂全距 vs 三窗／三 rep 的 Δ 散佈）與「部分格不可解」時整組擬不擬合。**推論**：在裁決之前，FINDINGS §4 引用數字可以，引用 link 的「H-C2」不行。
- `members[0]`：第五次 campaign 已發作（link 20 M、100 M 用 N＝5，另兩窗是 4），判決沒變。
- H-A2 的跨 frame／跨遍條件、H-B3 的「該視窗」計數來源：同一類的層級問題，不在本輪範圍，登記。
- `external_gate` 的 `external < 0` 過濾把真的負殘差與哨兵 `-1` 一起丟掉：第五次 `none_f64_b` 是 `external=-0.0096`（`arm.meta` 讀的），
  於是 `none` 組中位數用 3 臂（0.0560）而不是 4 臂（0.0355）；兩種算法都沒有臂觸發（推論：本輪判決不變）。FINDINGS §1.2 從 summary.json 抄時只會看到 11 列。
- 結構對帳的真相取自第四次；第五次多了 5 條邊的視窗（⑨b）。`check_inventory_fresh.py` 還不是閘門（raw 不在 repo 裡）。
- round 9 的舊候選照舊：`load_arm` 的 `raw_dir` 必填、閘門 shell 半邊沒 baseline、`--only` 分支只讀碼、`cpu_comparison` 控制臂過濾是等價變異、`inventory.py` 對 `.jsonl` 只讀第一行、`place_end_labels` 裝不下時沒有訊號。
- 本 SUMMARY 不能 commit（gitignored、在 worktree 外）。

**[Co-developed with claude code -- Adam]**

---

# Round 11（裁決 40＋判官項，2026-09-24 07:5x–08:3x UTC）

**head**：`a7fb0789`。commit：`fac4a96c`（只加測試＋fixture 參數；7 格在這顆上紅，紅跑在這顆上取）→
`a7fb0789`（修法＋M-E44..M-E48＋閘門用詞）。範圍與 round 10 同：沒 sudo／`ndt`／live／編譯；只動回合目錄與這份 SUMMARY；
`FINDINGS.md`／圖／`summary.json` 一個字沒動、沒 commit。本段之前的兩處就地更正（40(d)、40(e)）都標「round 11」。

## (a) H-C2 本輪不可判定——不再印「H-C2 …」

**觀測（修前 `bc1db4c0`）**：`cpu_verdict` 在 `share ≤ 0.2` 時回傳 `"H-C2 cost is per sample (08-20's fixed component does not reproduce here)"`，
只看 PREREG `:271` 兩個條件中的第一個。
**改（`a7fb0789`）**：H-C1 不成立且 `share ≤ 0.2` 時，逐字回傳
`not decided: H-C2 condition 1 holds (share <= 0.2); condition 2 (delta ratio ~ S ratio) has no registered tolerance`（常數 `HC2_NOT_DECIDED`）。
每個註冊的 kernel 擬合都帶 `H-C2` 區塊：`condition_1`、`share`、`condition_2: null`＋`condition_2_why_null`、
`low_kpps`／`high_kpps`、`delta_ratio`、`s_ratio`——**H-C1 成立時也帶**（cooperative 的情形）。對帳 (b) 那列帶同一個區塊與同一個判決；
`render()` 在擬合那行下印兩個條件，(b) 那行印判決。H-C1、H-C3 的邏輯沒動。
**我替這個區塊做的選擇（揭露）**：兩個比值取「擬合用到的階（resolved）中最低與最高 kpps」，依據是 PREREG 8(b) `:357`「最低階與最高階」；
它是資料、`condition_2` 永遠是 null，**沒有任何碼拿兩個比值互比**。

## (b) bmv2 連 H-C0 也不貼

**觀測**：round 10 的 `cpu_comparison` 裡 H-C0 分支在 `registered` 判斷之前（判官指的 `:832-837` 先於 `:839`）。
**改**：`registered=False` 先判——有點就留擬合當描述，沒點就 `{"fit": null, "verdict": null, "note": …}`。

## (c) H-B2 要**三個**視窗同號

**觀測**：round 10 的 H-B2 只要 `position == "above"` 且 `same_sign`，兩個有效視窗同號也算。PREREG `:252`「三個視窗的 `ratio−1` 同號」。
**改**：`H_B2_WINDOWS = 3`；格子記 `signed_windows`（有效的帶號誤差個數），H-B2 需要 `signed_windows == 3`；H-B2 區塊記 `signed_windows` 與 `windows_registered`。
少於三個＝**不能滿足**（`holds: false`），照裁決字面。

## 紅（`fac4a96c`，生產碼＝`bc1db4c0` 的 `analyse.py`，sha256 `ee7d0f6421d2`；逐字）

`red-40-abc.p3e-fac4a96c.log`：`Ran 29 tests` ／ `FAILED (failures=7)`，全是 FAIL、沒有 ERROR：
```
:48  AssertionError: "H-C2 cost is per sample (08-20's fixed c[29 chars]ere)" != 'not decided: H-C2 condition 1 holds (sha[71 chars]ance'   (also :78, :90)
:102 AssertionError: unexpectedly None : no machine-readable H-C2 block in the fit
:60  AssertionError: 'H-C' unexpectedly found in 'H-C0 not resolved -- the window-to-window spread is larger than the effect at every rung' : cooperative
:111 AssertionError: True is not False : {'holds': True, 'offered_mbit': 100, 'position': 'above', 'same_sign': True, 'windows': 2}
:69  AssertionError: False is not true
```
（前兩行各代表幾格：「H-C2 cost is per sample」那個不等式出現在三格——專門那格、fit 區塊那格、對帳／render 那格；
「no machine-readable H-C2 block」是 H-C1 成立那格；第 7 格是舊的 `test_the_cpu_verdict_names_a_mixed_decomposition_as_a_result`，
它原本斷言 per_sample「是 H-C2」，正是一條件標籤，本輪改成斷言「not decided: H-C2」，`False is not true`。）
最終 head 以 `--rev bc1db4c0 --file analyse.py` 重現，同 7 格：`red-40-abc-reproduced.p3e-a7fb0789.log`。
**這次測試檔在紅跑那顆與最終 head 是同一份**（兩份 log 的 `# as run:` 都是 `c9658a77b6e8`）——(d) 那種事這輪沒有。

建議項的「缺一個註冊速率 ⇒ not decided」那格在舊碼上是**綠的**（那條路 round 10 就有，只是沒測），它的紅在 M-E47 之下看。

## 變異（`mutate.p3e-a7fb0789.log`）

| 變異 | 綁的格 | 閘門怎麼說 |
|---|---|---|
| M-E12（錨點隨 40(a) 改名的那行移過去，變異本身不變：混合帶失去自己的分支） | `test_the_cpu_verdict_names_a_mixed_decomposition_as_a_result` | caught；no other case（`:33-34`） |
| M-E44 一條件的「H-C2 …」標籤放回去 | `test_H_C2_is_NOT_DECIDED_while_its_second_condition_has_no_tolerance` | caught；also red: 混合那格、fit 區塊那格、對帳／render 那格（`:143-144`） |
| M-E45 bmv2 沒點時又貼 H-C0（判官的 40(b)） | `test_bmv2_gets_no_H_C0_either_when_no_rung_resolves` | caught；no other case（`:145-146`） |
| M-E46 H-B2 拿掉「三個視窗」 | `test_a_100_Mbit_cell_with_only_two_valid_windows_cannot_be_H_B2` | caught；no other case（`:147-148`） |
| M-E47 缺讀數的註冊速率當成在帶內（建議項） | `test_a_registered_rate_with_no_reading_leaves_the_group_not_decided` | caught；no other case（`:149-150`） |
| M-E48 組級改取**最後**一格（建議項；與 M-E37 共用錨點、換成不同替換） | `test_the_fifth_campaigns_shape_outside_at_the_FIRST_rate_is_not_H_B1_either`——帶外那格在**第一**個速率，取最後一格（100 M，帶內）就會判 H-B1 | caught；also red: `test_a_registered_rate_with_no_reading_leaves_the_group_not_decided`（最後一格是有讀數的 100 M，缺的 20 M 被跳過）（`:151-152`） |

基線 `Ran 101 tests` ／ `OK (skipped=1)`；48 個 caught、兩個控制照綠。

## (e) 文字修正
- SUMMARY `:1419`「六支儀器成檔」：`ddcef442` 那顆確實是六支；本輪儀器共七支（加 `106a06bf` 的 `red_against.py`）。**就地加註，沒改成「七」**——改成七會讓那顆 commit 的描述變錯。
- `FINDINGS.md:209-217` → `:209-216`（第 7 條止於 `:216`，讀過）。
- 測試註解 `0.2854` → `0.285318`（`2 × 0.674/√22.3214 = 0.28531782…`，算的；也等於第五次 summary 的帶上緣 `0.28531782138520545`）。
- 閘門 `report_shell` 的 `(N cell(s) went red)`：**改用詞，不改數**。那個數一直是**綁定的格數**（`$#`），而不是紅了幾格；現在印
  `(N bound cell(s) went red)`，其餘紅的在下面的 `also red` 行。

## 第五次 campaign（唯讀，`raw/2026-09-19T115737Z_full`）

`analyse-115737Z.p3e-a7fb0789.log`；summary 在 `wt-p3-measure-0919/scratch/p3e-round10/summary.115737Z.a7fb0789.json`（gitignored，sha256 `814f487aa86b0bda…`）。

| | 判決 | F（% of one core） | m（µs/sample） | H-C2 區塊 |
|---|---|---|---|---|
| kernel，cooperative | `H-C1 cost is dominated by a fixed component (08-20 reproduces)` | 0.9234 | 122.89 | condition_1 **true**（share 0.0722）、condition_2 null、Δ 比 20.297、S 比 51.802（1..110 kpps） |
| kernel，link | `not decided: H-C2 condition 1 holds (share <= 0.2); condition 2 (delta ratio ~ S ratio) has no registered tolerance` | 0.7692 | 79.00 | condition_1 **true**（share 0.0623）、condition_2 null、Δ 比 31.505、S 比 58.680（1..110 kpps） |
| bmv2（兩組） | `null`＋註記（有點，描述性擬合） | | | —— |

H-B 組級：cooperative `neither H-B1 nor H-B2 holds as registered`、link `H-B1 shot-noise limited (all three rates inside the band)`、
`not H-B4: link/cooperative is outside [0.5, 2.0] at 2 Mbit/s`；兩組 100 M 的 `signed_windows` 都是 3，所以 (c) 不改任何判決。

**對帳 round 10 的 summary**（`reconcile-summary-115737Z-r10-r11.p3e-a7fb0789.log`，逐葉）：**1612 個葉值相同**；
**改了 2 個**——`cpu_kernel.fits.link.verdict` 與 `reconciliation[3].verdict`，都是「H-C2 cost is per sample …」→ `not decided: …`；
round 10 獨有 **0**；本輪獨有 17（兩個擬合與兩列對帳的 `H-C2` 區塊、9 格 `signed_windows`、兩個 H-B2 區塊的 `signed_windows`／`windows_registered`）。
**觀測**：除了 H-C2 那句用詞與新欄位，沒有任何值變——H-C 區塊的數與 H-B 組級標籤都與 round 10 相同。區塊裡的兩組比值也等於 round 10 用腳本另算的
`hc2-second-condition-data.p3e-bc1db4c0.log`（20.297／51.802、31.505／58.680）。真圖字框照舊全在框內（`postcheck-9a-real-render-115737Z.p3e-a7fb0789.log`）。

## 閘門（全部在 `a7fb0789`）

| 跑什麼 | rc | 判決行／關鍵行 | log |
|---|---|---|---|
| **變異閘 M-E1..M-E48 ＋ 2 控制** | **0** | **`mutations: 48   survivors: 0   drifted: 0`** | `mutate.p3e-a7fb0789.log` |
| 閘門 self-test | 0 | `passed: 14   failed: 0` | `test_mutate_gate.p3e-a7fb0789.log` |
| 離線整輪 | 0 | `passed: 78   failed: 0` | `offline-round.p3e-a7fb0789.log` |
| 單元（venv） | 0 | `Ran 101 tests in 1.421s` ／ `OK (skipped=1)` | `unit-venv.p3e-a7fb0789.log` |
| 單元（conda，mpl 3.10.8） | 0 | `Ran 101 tests in 2.503s` ／ `OK` | `unit-py3.p3e-a7fb0789.log` |
| `hazard_scan.py` ×4 | 0 | `# hazard_scan: 4 file(s) given, 4 scanned, 0 unreadable, 0 finding(s)` | `hazard-scan.p3e-a7fb0789.log` |
| 錨點自掃（兩節） | 0 | `--> 50 anchors, 0 that do not resolve exactly once` ／ `--> 13 entries, 0 that do not resolve as declared` | `anchor-sweep.p3e-a7fb0789.log` |
| 錨點自掃自檢（兩處故意漂移） | **1**（應為 1） | 兩個 `BAD`：`m1` 與 `offline 7(c) slice start` | `anchor-sweep-selfcheck.p3e-a7fb0789.log` |
| `check_gate_anchors.py HEAD` | 0 | `115/115 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` | `check_gate_anchors.p3e-a7fb0789.log` |
| 紅跑 40 | 1 | `FAILED (failures=7)` | `red-40-abc.p3e-fac4a96c.log`（重現：`red-40-abc-reproduced.p3e-a7fb0789.log`） |

## 本輪我自己的錯
- 第一次寫測試用 `%` 格式化，撞上字串裡字面的「150%」，丟例外、**檔案沒被寫**（事後確認過）；改用佔位符取代。
- 為 (d) 查 log 雜湊時，一次 grep 四個檔的輸出順序和參數順序不同，我差點把四個雜湊配錯檔；逐檔、帶檔名重查才對上。上面引的都是逐檔查的。

## 仍然沒做的（照舊）
round 10 ⑦ 那張候選清單原樣有效；本輪沒有新增候選。SUMMARY 仍不能 commit（gitignored、在 worktree 外）。

**[Co-developed with claude code -- Adam]**
