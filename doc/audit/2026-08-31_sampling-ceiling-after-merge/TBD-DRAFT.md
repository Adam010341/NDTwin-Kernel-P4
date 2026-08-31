# E 輪 TBD 草案＋預註冊缺陷清單（**草案，未蓋章**）

[Co-developed with claude code -- Adam]

**狀態**：**草案**。作者＝本 session（腳本作者），**不自蓋章**——設計者不自審，v1.0 的章要第二
雙眼。本檔交 auditor 送複驗。
**時點**：2026-08-31，**接觸任何量測資料之前**（`raw/` 只有 dry-run 與閘門自測產物，
無任何 fabric 讀數）。照 `prereg-amendment-before-data` 三條件，每一條都寫明
**改了什麼／為什麼／誰在什麼時候**。

---

## 第一部分：預註冊本身的缺陷（比補上的腳本更重要）

以下每條都在寫腳本時撞到，全部可在窗外驗證，**不需要 fabric**。

### 🔴 D1. `MP` 不是「現行生產組態」——**生產的 batching 是關的**

- **證據**：`p4_proxy/proxy_agent/main.py:82`
  `sflow = SFlowEmitter(batch_size=int(os.environ.get("NDTWIN_SFLOW_BATCH", "1")))`
  全 repo（排除 audit 腳本與 worktree）**沒有任何地方設定 `NDTWIN_SFLOW_BATCH`**；
  `tools/test_workflow/stack.sh:742-744` 起 proxy 時不帶它。
  `doc/KNOWN-ISSUES.md:1018` 白紙黑字：「旗標是 `NDTWIN_SFLOW_BATCH`，
  **生產預設 1 ＝ batching 關閉 ⇒ 目前不咬人**」。
- **後果一**：PREREG §3 表格把 `MP` 標成「＝**現行生產組態**」是錯的。
  真正的生產組態是 **`P`**（batching off、1 Hz）。
- **後果二**：`M` 那格寫「on（**生產值**）」——**沒有生產值可寫**，因為生產是關的。
  這個值必須被選，而不是被引用（見 D6）。
- **後果三**：§0 的理由句「batching（`a3bb761`）與 path recompute（`2f57ba5`）都在 08-27 落地、
  **已在生產線上跑了一週**」對 batching 是**假的**。碼進了版控，行為從未開啟。
- **建議修法**：§3 表格把「現行生產組態」的標記從 `MP` 移到 `P`；§3 的 `M`/`MP` 改寫成
  「batching on（值見 §3c）」；§0 改成「recompute 已在生產跑了一週；batching 的碼在版控裡
  但**旗標從未設過**，本輪問的是『若開啟會不會抬高天花板』」。
- **這個選擇會讓哪一種結論失效**：不改的話，**任何以「生產組態」為主詞的句子都會指錯格**。
  最危險的形狀是報告寫「生產組態的天花板是 X」而 X 來自 `MP`——那是一個從未上線的組態。

### 🔴 D2. §3a(a) 的第五格控制組 `BL-true` **建不起來**（已驗證，非推論）

- **證據**（`git show`，不是讀碼推測）：
  - `a3bb761^:p4_proxy/proxy_agent/main.py:80`
    `sflow = SFlowEmitter(batch_size=int(os.environ.get("NDTWIN_SFLOW_BATCH", "1")))`
  - `a3bb761^:p4_proxy/proxy_agent/sflow_emitter.py:257`
    `def __init__(self, collector=..., max_header_bytes=..., sock=None, started_at=None)`
    ——**沒有 `batch_size` 參數**。
  - 原因在 `a3bb761` 自己的 commit message：batching 實作「written by 8/25 mainDev and
    **never committed**」，而**接線** commit `9487643`（08-26）比它早，且是 `a3bb761^` 的祖先
    （`git merge-base --is-ancestor 9487643 a3bb761^` ⇒ YES）。
    ⇒ `a3bb761^` 是一棵**內部不一致**的樹：接線在、實作不在，proxy 一啟動就 `TypeError`。
- **§3a(c) 因此已經觸發**（「等價性否證，**或 `a3bb761^` 建不起來**」）。這是預註冊自己寫好的
  fallback，不是新規則。
- **建議**：**採 (c)**。`BL` 一律記為「batching 碼在 `batch_size=1`」，
  **不得寫「舊行為」「pre-batching」**；R-E1 的結論語言綁成「開關 batching **參數**」。
- **若仍要一格活的控制組**，兩個候選都不是 `a3bb761^`，且各有代價：
  | 候選 | 差異範圍 | 代價 |
  |---|---|---|
  | (i) `9487643^` 的整棵 `proxy_agent/` | 真實 commit 狀態、無合成 | 夾帶 08-26→今的所有 proxy 改動；**`/sflow/stats` 那時還不存在** ⇒ §2 的 batching 接線斷言（G1）在這格無法執行 |
  | (ii) 生產樹＋把 `sflow_emitter.py`／`main.py` 退回 `9487643^` | 差異剛好是 batching 本身 | 合成樹；且 `/sflow/stats` 會讀不到 `batch_size`（`AttributeError`），要第三處改動 |
- **我的建議**：**先不跑活的控制組，走 (c)**。理由：`a3bb761` 已經附帶一個**逐位元組**釘住
  「default 1 ＝ 舊行為 byte for byte」的 committed 測試
  （`tests/python/test_sflow_emitter_batching.py`），那是比 (i)/(ii) 任何一個都乾淨的等價性證據，
  而 (i)/(ii) 都會把「等價性」這個問題換成「另一棵樹的差異有多大」這個新問題。
- **這個選擇會讓哪一種結論失效**：走 (c) 之後，**「有沒有 batching」這個對比就不存在了**，
  只剩「batching 參數 1 vs 8」。R-E1 若寫成「batching 抬高天花板」＝越權。
- 🔒 腳本已把這條寫死：`run_e.sh bltrue` 在沒有 `BLTRUE_TREE` 時**拒絕執行並印出上述理由**，
  且**不會自己挑一棵替代樹**（挑樹是修訂，修訂是複驗者的事）。

### 🔴 D3. 【TBD-1】沒有「旗標」那一支——**只有「哪一顆第二 binary」**

- **證據**：`include/ndt_core/collection/FlowLinkUsageCollector.hpp:51`
  `constexpr auto kFlowPathRecomputeInterval = std::chrono::seconds(1);`
  唯一使用點 `src/ndt_core/collection/FlowLinkUsageCollector.cpp:2969`；
  kernel 的 collection 樹裡唯一的 `getenv` 是 `NDTWIN_TOPO_FILE`。
  且 `tools/test_workflow/stack.sh:766` 把 `$KERNEL_DIR/build/bin/ndtwin_kernel` 寫死。
- **建議值**：**還原 patch，且兩臂都從同一棵凍結樹現建**
  （`build_1khz_binary.sh`，已交付）。
- **為什麼不用現成的 `.test_run/binaries/ndtwin_kernel.ab2d7ed1`**：它自己的 `.provenance`
  記著 `commit=UNKNOWN`、`dirty_worktree=UNKNOWN`。它與 `a40e04ce` 的差異**沒有被確立**是那一行，
  只是「兩棵沒記錄的樹之間的全部差異」。現建把差異縮成一行，並附 patch 的 sha256。
- **🔴 連帶的排程後果**：build 必須在**窗外**。PREREG §4 與 `LOCAL-FABRIC-QUEUE` 都禁止窗內 build，
  而本輪判準是 CPU 平台 ⇒ 窗內編譯是處理效應不是雜訊。
  `build_1khz_binary.sh` 因此**偵測到活的 claim 就拒跑**（先 build 再 claim）。
- **🔴 鑑別力警告（腳本已修正）**：`.provenance` 用
  `nm -C | grep -c kFlowPathRecomputeInterval`（5 vs 0）分辨舊 binary，那是因為 `ab2d7ed1`
  **早於這個常數存在**。本輪兩臂同一棵樹、只差常數的**值**，符號兩邊都在 ⇒ 這個判準會回 5 vs 5，
  **是一個沒有鑑別力卻長得像檢查的檢查**。
  改用：①臂的身分＝staged 檔的 sha256（`swap_kernel` 對 `.provenance` 逐字核）；
  ②值的證明＝build 時跑 `2f57ba5` 自己附的
  `FlowPathRecomputeInterval.IsOneSecondNotOneMillisecond`，
  **1 Hz 臂必須綠、1 kHz 臂必須紅**，兩向都要出來才算數。

### 🔴 D4. §7 修訂記錄第 140–142 行的**連帶條款指錯了一對格**

- 原文：「若 1 kHz 走還原 patch，則 **`BL`/`P` 與 `M`/`MP`** 是兩顆不同 binary」。
- 照 §3 的表格直接讀：`BL` 與 `M` 同為 **1 kHz**，`P` 與 `MP` 同為 **1 Hz**。
  ⇒ 依 binary 分開的是 **`BL`/`M` vs `P`/`MP`**。原文那一對（`BL`/`P` vs `M`/`MP`）是
  **batching 軸**，而 batching 是 proxy 的環境變數，**不換 binary**。
- **建議修法**：把該句的兩對對調。
- **這個選擇會讓哪一種結論失效**：照原文寫的揭露句會告訴讀者「batching 的兩臂是不同 binary」
  ——那是假的；同時**真正的 binary 差異（recompute 軸）會沒有被揭露**。
  也就是說這個筆誤同時製造一個假警告和一個真漏報。
- 🔑 **附帶好消息**：修正之後，binary 差異剛好**與 recompute 因子重合**（它就是那個因子的
  操作化），不是額外的干擾軸。真正要揭露的是「兩臂差一行、patch hash 為 X」，
  而不是「2×2 不成立」。

### 🟡 D5. **每格時長 `DUR` 沒有凍結**

- D 輪 ladder 用 300 s；`gate_e.sh`／`wall_f.sh` 用 120 s。PREREG 凍了梯、rep、交錯序、
  健康判準，**沒凍時長**——而 `ratio`／`lost_pct`／`distinct` 的雜訊都隨它變。
- **建議值：300 s**。理由：§6 要求逐格對帳 08-25 D 輪的 `t008`/`t004`，那些格是 300 s。
- **代價（必須一起裁）**：見 D8——300 s ⇒ **約 10 小時**獨占；120 s ⇒ 約 4 小時。
- **這個選擇會讓哪一種結論失效**：選 120 s 則 §6 的「同 fabric、同 binary 才逐格比」
  就**不能逐格比 D 輪**（時長不同），只能比方向。

### 🟡 D6. 「batching on」的 `batch_size` 值沒有凍結

- **建議值：8**。理由：`gate_e`（1/256）與 `wall_f`（1/16）兩輪都用 8，選 8 才能對帳
  （見 D7）。選別的值＝把唯一的舊資料丟掉。
- **這個選擇會讓哪一種結論失效**：任何非 8 的值都讓 §6 的對帳欄變成空的。

### 🔴 D7. §6 對帳表**漏掉了直接量過 batching 的那兩輪**

- `doc/audit/2026-08-25_sampling-rounds/gate_e.out`（1/256，batch 1 vs 8）與
  `wall_f.out`（1/16，三對交錯，DUR=120）都是**同一個因子**的實測，且
  §6 只列了「08-25 D 輪四格」。Adam 的規矩是「每次實驗對帳舊結果」。
- 那兩輪的可對帳事實（逐字取自 `.out`，皆 kernel `3367d0e9`＝**baseline binary，1 kHz 側**）：
  - 1/16：`ratio` 0.9968／1.003／1.001／1.004／1.003／0.9955，**batch 1 與 8 都健康**；
    proxy CPU 71.0/72.3/73.8（b1）vs 62.8/62.9/62.3（b8）；
    datagram 3346/3325/3331 /s（b1）vs 446.9/450.0/444.2 /s（b8）。
  - 1/256：`ratio` 1.016（b1）vs 1.008（b8）；datagram 209.8 vs 30.6 /s。
- 🔑 **E-P4 已經有前測**：兩個工作點上 batching 都**沒有**動 `ratio`。本輪若看到 `ratio` 掉，
  是**與舊結果衝突**，要當 bug 報（§3b 已如此規定），不是新發現的天花板。
- 🔑 而且那兩輪跑在 **1 kHz 側的 binary** 上 ⇒ 它們其實是 `BL` vs `M` 在兩個梯階上的**部分格**。
  建議 §6 增列一列並在 R-E1 判定時明確對帳。

### 🟡 D8. 凍結後的設計是**約 10 小時獨占 fabric**（不是「一個窗」）

- 8 梯 × 4 格 × 3 rep ＝ 96 格，加 BL-true 9 格 ＝ **105 格**。
  依 `wall_f.out` 實測的每格 overhead（arm 起始→kernel sha 約 40 s），
  DUR=300 ⇒ **約 10 h 3 m**；DUR=120 ⇒ 約 4 h 0 m。（`run_e.sh plan` 會印。）
- PREREG §4 已寫「不疊 9/03 準備窗」，而 10 h 在 9/03 之前**擠不進去**。
- **建議**：由 Adam 在「DUR=120＋放棄逐格對帳 D 輪」與「DUR=300＋排到 9/03 之後」之間裁。
  🔴 **不建議**的第三條路＝砍 rep 或砍梯階——那是 C5 禁止的。

### 🟡 D9. `measure.sh` 用 `pkill -f iperf3`，而本輪要重用它

- `doc/audit/2026-08-20_sampling-rate-and-cpu/measure.sh:45-46,96`，其自己的註解寫明
  mininet host 共用 root PID namespace「which is why a plain pkill reaches them at all」
  ⇒ 它會打到**別的 session 的 iperf3**。這是 CLAUDE.md 的絕對禁令。
- **本輪的處置（已落在腳本裡，不改 `measure.sh`）**：把 `measure.sh` 保持逐位元組不動
  （§6 的可比性靠它），改成**在交棒給它之前先確認沒有外來 iperf3**，有就中止該格。
  列舉用 `ps -eo pid=,comm=` 精確比對 `comm`，**不用 `pgrep -f`**。
- **要 Adam 裁的**：要不要另開一張單去修 `measure.sh`。修了就與 D 輪不再逐位元組同儀器。

### 🔴 D10. CPU 閘門的門檻沒有定義，而且**本機的 exclusive 前提現在不成立**

- PREREG §4 要求 `NDT_EXCLUSIVE_CPU=1`，但**沒有給任何門檻**，§2.4 卻要求對它做雙向 force。
- **實測（今天，本機，無 fabric）**：外來負載 **0.84 核**，
  主要來源＝`claude-desktop` ≈0.37、CLI session ≈0.25、`gnome-shell` ≈0.09。
  ⇒ 任何**絕對** 0.5 核的門檻在開跑前就是紅的，而且**跑這輪的 session 自己就是紅的一部分**
  （`vm-on-this-machine-is-invisible-to-ndt-status` 早就記著「第三源＝claude session 自己」）。
- **建議**：門檻改成**對已量基線的超出量**。基線用 `gates_e.sh baseline` 在**fabric 關著**時量進
  檔案，閘門判 `excess >= 0.50 核`，並**兩個數字都報**（基線漂移才看得見）。
  基線檔不存在時閘門回 **UNRUNNABLE（exit 2），不回綠**。
  已實作並三向驗過：idle→GREEN、awk burner（excess 1.004 核）→RED、缺基線→UNRUNNABLE。
- **這個選擇會讓哪一種結論失效**：若堅持絕對門檻，§2.4 的 force-green 永遠出不來 ⇒ 依 §2
  「任一次結果不如預期 ⇒ 停輪修 gate」，這一輪根本開不了跑。
- **另一個要 Adam 裁的**：要不要在窗內關掉桌面（把基線壓到 ~0.1 核）。關掉的話閘門的鑑別力
  從「>0.5 核的干擾」細到「>0.5 核**且**桌面不在」，兩者能抓的東西不同。

### 🟢 D11. 「四次 force」與 E3b 的段數不一致

§2 第 44 行寫「四次 force 的逐字輸出全存 raw」，v0.2-stamped 的 E3b 又把 CPU force-green
拆成兩段 ⇒ 實際是**五次**。腳本跑五次並逐項標號（G4/G5a/G5b/G6/G7）。建議 §2 改成「五次」。

### 🟢 D12. raw 落點沒寫，而儀器把路徑寫死在**別的輪**

`measure.sh` 的 `OUT` 與 `cell_verdict.py` 的 `RAW` 都指向
`doc/audit/2026-08-20_sampling-rate-and-cpu/raw`。兩者都不改（改了就分叉 §6 依賴的儀器），
改為量完**複製**進本輪 `raw/cells/` 並兩側各記 sha256（`lib_e.sh:archive_cell`）。
建議 §4 補一句落點。

---

## 第二部分：兩處 TBD 的草案

### 【TBD-1】1 kHz 臂的取得方式（＋第 140 行的連帶條款）

- **建議值**：**還原 patch**；兩臂皆由 `build_1khz_binary.sh` 從同一個 `FREEZE` commit 現建，
  只差 `FlowLinkUsageCollector.hpp:51` 的 `seconds(1)` → `microseconds(1000)` 一行；
  patch 存檔並記 sha256；每顆 binary 在 build 時寫 `.provenance`
  （sha256／commit／dirty／source 行／`ldd`／`readelf -d` RUNPATH／gtest 結果）。
- **為什麼**：見 D3。沒有旗標；現成 binary 的 provenance 是 UNKNOWN。
- **值的證明**：`ctest -R FlowPathRecomputeInterval` 對 1 Hz 臂**必須綠**、對 1 kHz 臂
  **必須紅**。任一方向不如預期 ⇒ 該臂沒有帶到那一行，停手。
- **連帶條款（改正版，取代第 140–142 行）**：
  > 1 kHz 走還原 patch ⇒ **`BL`/`M`（1 kHz）與 `P`/`MP`（1 Hz）是兩顆不同 binary**。
  > 兩顆由同一 commit `<FREEZE>` 建出，差異＝patch `revert-2f57ba5.patch`
  > （sha256 `<...>`）的一行。逐格記錄兩顆的 sha256，並在結論語言中揭露
  > 「recompute 軸＝換 binary，差異已知且限於該行」。
  > batching 軸（`BL`/`P` vs `M`/`MP`）**不換 binary**，只換 `NDTWIN_SFLOW_BATCH`。
- **這個選擇會讓哪一種結論失效**：若改用現成的 `ab2d7ed1`／`a40e04ce` 這一對，
  **Q3（歸屬）就不能寫**——差異不是一行，任何「這一格是 recompute 買到的」都無法排除
  兩棵未記錄的樹之間的其他差異。

### 【TBD-3】py-spy 附掛的 claim 內申報文字

- **建議值**（`ndt claim` 的 note 欄，逐字）：

  ```
  E-round sampling ceiling; EXCLUSIVE CPU (registered term, not a memo).
  Covariates declared: (1) the 4 Hz twin poller inside measure.sh; (2) cpu_probe.py at 2 Hz;
  (3) py-spy dump against the live proxy at the gate cell only, via `mnexec -a <pid>`
  (ptrace_scope=1 blocks a same-uid attach), one dump per gate cell, never during a ladder cell.
  py-spy PAUSES its target, so its dumps are an intervention, not an observation: they are
  confined to the gate cell and the GIL rider (PREREG §5), and no ladder cell's numbers are
  taken while a dump is outstanding.  The rider's result may NOT be used to explain the main
  question's result (§5).
  No build, no VM, no container, no commit in this window (PREREG §4).
  ```
- **為什麼這樣寫**：①`ndt` 的 note 是宣告誰在用、用來做什麼的唯一欄位，而 §4 要求把
  py-spy 與取樣器都登記成共變量；②F-5 §4 的格式先例說「條款照 note 格式進 claim，
  **係註冊條款不是備忘**」；③py-spy **會暫停目標行程**
  （`doc/2026-07-29_environment_gotchas.md:284-286`；`h_probe.sh:11-14` 因此在 dump 前後各讀
  一次 `/proc` 且丟掉狀態變動的執行緒）——所以申報文字必須寫明它是**介入**而非觀測，
  並把它關進閘門格。
- **這個選擇會讓哪一種結論失效**：若不把 py-spy 限制在閘門格，梯子上任何一格只要撞到
  一次 dump，那格的 CPU 與 `ratio` 都被一個**未登記的暫停**污染 ⇒ 該格不能進 R-E1/R-E2。
  又：§5 已明文「不得用它解釋主問結果」，note 裡重述一次是為了讓交接的人看得到。
- 🔴 **附帶提醒**：`py-spy dump` 是**單一取樣**，本專案已被它誤導過一次；
  任何與時間有關的宣稱要用 `top`／`record`，不能用 `dump`。

---

## 第三部分：交付的腳本與驗收方式（未跑任何量測）

| 檔案 | 作用 | 驗收（已做） |
|---|---|---|
| `round.env` | 全部凍結值＋**未凍結值集中一處** | — |
| `lib_e.sh` | preflight／身分／fabric 生命週期／archive／abort | dry-run 走完 |
| `gates_e.sh` | §2 七個閘門，逐項對號 G1–G7 | 接受路徑＋四種拒絕路徑 |
| `cpu_gate.py` | 外來 CPU 閘門＋基線 | **真跑**：idle→GREEN、burner→RED（excess 1.004 核）、缺基線→UNRUNNABLE |
| `ratio_gate.py` | `ratio` 閘門＋force-red 資料合成 | 語法＋控制流（需 plot venv 才能對真資料跑） |
| `run_e.sh` | 梯子驅動、右截斷、E-P4 中止、resume | `plan`／`ladder` dry-run／`bltrue` 正確拒絕 |
| `build_1khz_binary.sh` | **窗外**建兩臂＋雙向 gtest 證明 | dry-run 走完 |

🔴 **未驗的部分（誠實列出）**：`ratio_gate.py` 對真資料的兩個斷言、`cell_verdict --selftest`、
以及所有需要 fabric 的路徑，都只走過 dry-run。`PY_PLOT`（`.plotvenv`）在這台機器上**不存在**，
`gates_e.sh` 會據此明確拒絕並印出理由，不會退回系統 python3。
