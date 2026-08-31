# PREREG E — 取樣率天花板在 batching 與 1 kHz→1 Hz 之後有沒有抬高（v0.2）

[Co-developed with claude code -- Adam]

**狀態**：**v0.3（2026-08-31，資料接觸前的修訂；仍未達 v1.0，章未蓋）**。
v0.2-stamped 的 reviewer 章仍有效，v0.3 只更正 v0.2 之後被證否的事實與一處軸標筆誤，
**不新增判定規則**。升 v1.0 閘＝【TBD-3】（py-spy 申報文字）落定＋**§3 的臂設計待 Adam 排窗裁決**
（三個方案與各自答不出什麼＝`COST-TABLE.md`）。【TBD-1】已於 v0.3 關閉。
**凍結（v1.0）前不得接觸任何量測資料。**
**裁決鏈**：`BRIEF-E-merge.md`（08-26 設計，未跑）→ 兩個改動 08-27 落地 →
Adam 08-31 提問「這兩個改動後天花板有沒有抬高，量了嗎」＝**沒有** → 本註冊。

## 0. 這輪存在的理由（一句話）

**帳上的「取樣天花板 ≈1/16」是改動前那顆 binary 的數字**，而 path recompute 1 kHz→1 Hz
（`2f57ba5`）在 08-27 落地、已在生產線上跑了一週。天花板可能已經抬高、也可能沒有——
**兩種答案都要能發表，而現在我們一種都沒有。**

🔴 **v0.3 更正（v0.2 的這一句是錯的）**：原文寫「batching（`a3bb761`）與 path recompute 都在
08-27 落地、已在生產線上跑了一週」。**對 batching 是假的。**
`p4_proxy/proxy_agent/main.py:82` 的 `NDTWIN_SFLOW_BATCH` 預設 1（＝關閉），
而全 repo（排除 audit 腳本）**沒有任何地方設定它**——`doc/KNOWN-ISSUES.md:1018` 早已寫著
「**生產預設 1 ＝ batching 關閉 ⇒ 目前不咬人**」。**碼進了版控，行為從未開啟。**
⇒ 本輪的**主要問題是 recompute period**（生產行為真的變了的那一個，且它正好動到佔 46 點的
那條執行緒）；batching 從「已經變了、要量」降為「**要不要打開**、要決策支援」。
兩者的證據需求不同，臂的設計因此重開，見 `COST-TABLE.md`。
（撰稿人 auditor 自陳：反面記載就在 `KNOWN-ISSUES.md:1018`，起草時未查即寫。
同族＝[[existence-is-not-wiring]]「碼在版控 ≠ 那條路徑在跑」。）

## 1. 問題（三問，兩個改動要分得開）

- **Q1（合併效應）**：batching 開／關，天花板（最高健康取樣率格）動不動？
- **Q2（週期效應）**：1 kHz→1 Hz 的 path recompute 是否讓天花板再動一格？
  （🔄 auditor-review E4：原句「讓出多少 CPU」是未註冊的量化宣稱——**primary 一律是
  天花板格語言**；kernel 側 CPU 佔用列為 **secondary 觀測**、與天花板分開報，
  不得用來解釋或補強 primary 的判定。）
- **Q3（歸屬）**：若天花板真的動了，**是哪一個改動買到的**——這是兩個改動同時落地
  留下的糾纏，本輪用 2×2 拆開（見 §3），拆不開就如實報「不可歸屬」。

## 2. 儀器與前置閘門（沿 BRIEF-E §E-2，逐項要有腳本呼叫）

1. **先證明計數器在 `batch_size=1` 讀得到東西**（同一個坑不踩第二次）。
2. **證明沒有無聲全滅**：`ratio` ≥0.95、樣本非零、λ 與對照臂同量級、`distinct` 非零。
3. **`cell_verdict.py --selftest` PASS，且閘門腳本裡有實際呼叫**
   （🔴 D 輪這項只寫在預註冊、`gate_d.sh` 沒呼叫，是審查 grep 出來的——
   **預註冊寫幾項檢查，腳本就要有幾個對應呼叫**，本輪凍結時逐項對照）。
4. 🔴 **陽性對照雙向 force，各寫實作（auditor-review E3——沒寫實作＝事後不可稽核）**：
   - CPU gate：**force-red**＝跑一支已知吃滿一核的 burner，gate 必須紅；
     **force-green 兩段（reviewer-review E3b）**：(i) 閒置 fabric（無流量）必須綠
     ——只證明「它能綠」；(ii) 🔴 **一個正常臂、只有 fabric 自身負載時也必須綠**
     ——證明**它不會對實驗自己的負載誤報**。
     理由：只做 (i) 正是 08-30 記的第二種壞閘門（「因為沒東西所以通過」）；③ 輪的閘門
     就死在這個鏡像上（`23_` §4：它會要求重跑正好帶著頭條的那些臂＝對自身負載誤報）。
     **(ii) 不綠 ⇒ gate 的門檻是錯的，停輪修 gate，不得調整臂去遷就它。**
   - `ratio` gate：**force-red**＝餵一份人工截去尾巴 20% 樣本的資料，gate 必須紅；
     **force-green**＝餵已知良品（08-25 D 輪存檔的一格 raw），gate 必須綠。
   - 四次 force 的逐字輸出全存 raw；**任一次結果不如預期 ⇒ gate 本身有問題，停輪修 gate**。
   （🔴 v0.3 更正：本節上方寫「四次 force」，而 v0.2-stamped 的 E3b 把 CPU force-green
   拆成兩段 ⇒ 實際是**五次**。腳本 `gates_e.sh` 跑五次並逐項標號 G4/G5a/G5b/G6/G7。）
   （🔴 v0.3 補：CPU gate 的門檻 v0.2 沒有給。本機**閒置無 fabric** 實測外來負載 **0.84 核**，
   主要來源是 `claude-desktop`＋跑這輪的 session 自己。⇒ 門檻改判**對已量基線的超出量**，
   基線以 `gates_e.sh baseline` 在 fabric 關著時量進檔案；基線缺席時 gate 回
   **UNRUNNABLE（不回綠）**。關不關桌面＝Adam 裁，兩種鑑別力的差別見 `COST-TABLE.md` §4。）
- 任一項不過 ⇒ **停輪、回報、不調門檻**（BRIEF-E 原條款，保留）。

## 3. 臂與判定規則（規則先凍、值後算——C1）

**2×2（batching × recompute-period），每格走同一取樣梯**：

| 格 | batching | path recompute |
|---|---|---|
| **BL** | off（`batch_size=1`；**等價性見下方 §3a，不假設**） | 1 kHz（舊值，取得方式見【TBD-1】） |
| **M** | on（`NDTWIN_SFLOW_BATCH=8`，v0.3 凍結；見下） | 1 kHz |
| **P** | off | 1 Hz ＝**現行生產組態**（v0.3 更正：生產的 batching 是關的） |
| **MP** | on | 1 Hz |

- 🔴 **v0.3 凍結 v0.2 漏凍的三個值**（都會動判定，所以不能留給執行者）：
  **每格時長 `DUR`**、**batching on 的值**、**raw 落點**。
  `DUR` 的取值連帶整輪時數，是 Adam 的排窗決定 ⇒ 選項與代價見 `COST-TABLE.md`；
  batching on ＝ **8**（`gate_e`／`wall_f` 兩輪都用 8，選別的值會讓 §6 的對帳欄變空）；
  raw ＝ 量在 `2026-08-20_.../raw`（儀器寫死）後**複製**進本輪 `raw/cells/`，兩側各記 sha256。
- 取樣梯（先凍）：1/1024, 1/256, 1/64, 1/32, 1/16, 1/8, 1/4, 1/1；
  **每格三 rep、交錯序 BL,M,P,MP,BL,M,P,MP**；每格 fabric 重啟。
- 🔴 **梯頂紀律（auditor-review E1；①b 那個坑的鏡像——梯子只對著慢臂檢查過，
  快臂的分子被右截斷）**：
  - (a) **梯頂 1/1 的可用性對 `MP`（生產組態、預期最高的那格）驗，不對 `BL` 驗**；
    `MP` 在 1/1 跑得動 ⇒ 1/1 對四格全部保留。**不因 BL 在 1/1 爆掉而砍梯頂**——
    那正好砍在效應上。
  - (b) **任一格在梯頂讀到健康 ⇒ 該格記為右截斷 `≥1/1`**，不得寫成「天花板等於 1/1」；
    判定規則裡的嚴格序若涉及兩個右截斷格 ⇒ 該對比記為**不可分辨（皆截斷）**。
  - (c) 照 C5，**事後不得加梯階**解截斷——要更高的梯只能在凍結前加。
- 健康判準（沿 08-25 D 輪）：`ratio` ≥0.95 且 λ 與對照同量級且 `distinct` 非零；
  **天花板讀出＝最高健康取樣率格**。

### 3a. BL 的等價性：驗法與驗不過的後果（auditor-review E2；控制組位置問題）

`batch_size=1` 若不等同 pre-batching 碼，四格量的就不是「有無 batching」，BL 就從基線
變成第三個條件。🔴 **v0.3：(a) 案已證實不可執行，(c) 就此生效**（2026-08-31，資料接觸前，`git show` 實證）：
- `a3bb761^:p4_proxy/proxy_agent/main.py:80` 傳 `batch_size=` 給
  `a3bb761^:p4_proxy/proxy_agent/sflow_emitter.py:257` 的 `__init__`，而該簽章
  **沒有 `batch_size` 參數** ⇒ proxy 一啟動就 `TypeError`。
- 成因見 `a3bb761` 自己的 commit message：batching 實作「never committed」到 `a3bb761` 才進版控，
  而**接線** commit `9487643`（08-26）已是 `a3bb761^` 的祖先
  （`git merge-base --is-ancestor 9487643 a3bb761^` ⇒ YES）⇒ 那棵樹**內部不一致**。
- **裁決（auditor，08-31）：走 (c)，不另建替代樹。** 替代樹（`9487643^` 整棵，或合成退版）
  都會夾帶 08-26 之後的 proxy 改動（含 `/sflow/stats` 當時尚不存在）
  ⇒ **為了補一個控制格而引入新的混淆，划不來**。
  等價性的證據改採 `a3bb761` 自附的逐位元組 committed 測試
  （`tests/python/test_sflow_emitter_batching.py`，釘住「default 1 ＝ 舊行為 byte for byte」）。
- ⇒ **第五格 `BL-true` 不跑。** 以下 (a) 保留為歷史記錄，不再是本輪程序。

**原 (a) 案（v0.2；已失效）**：

- **(a) 第五格 `BL-true`＝`a3bb761^` 的真 pre-batching binary**，跑**牆邊三格**
  （1/16, 1/8, 1/4——天花板由這裡決定，等價性只在這裡有意義；不跑全梯是刻意的，
  理由寫在此處而非事後）。判定：`BL-true` 與 `BL` 三格讀值**逐格相同** ⇒ 等價性成立、
  BL 可稱「舊行為」；**任一格不同 ⇒ 等價性否證**，走 (c)。
- **(c) fallback（等價性否證，或 `a3bb761^` 建不起來）**：**改寫宣稱範圍**——BL 一律
  記為「batching 碼在 `batch_size=1`」，**不得寫成「舊行為」「pre-batching」**，
  且 R-E1 的結論語言跟著綁（「開關 batching 參數」而非「有無 batching」）。
- 🔑 這格是**控制組**不是額外臂：它不進 R-E1/R-E2 的嚴格序比較，只回答「BL 是不是基線」。

### 3b. 判定規則（全部先凍）

  - R-E1（Q1）：`M` 與 `MP` 的天花板皆嚴格高於 `BL`／`P` 的對應格 ⇒ batching 抬高天花板
    ≥1 格；皆嚴格低 ⇒ batching 反而降低（**兩向都登記、都可發表**）；其餘 ⇒ 梯解析度內
    不可分辨。
  - R-E2（Q2）：同構規則比 `P`／`MP` vs `BL`／`M`。
  - R-E3（Q3 歸屬）：僅當 R-E1 與 R-E2 至少一項可分辨時談歸屬；**若只有 MP 動而單改動
    都不動 ⇒ 報「交互作用，單一改動不可歸屬」**，不挑一個當功臣。
  - **E-P4 保留（BRIEF-E 原文）**：merge 不應改變 `ratio`。🔴 若 `ratio` 掉了 ⇒
    **batching 實作有 bug，不是 merge「有效」**；最可能形狀＝結束時 `_pending` 未 flush。
    此時停輪報 bug，不得把它讀成天花板變化。
  - 🔴 凍結後**不加 rep、不加格、不加梯階救結果**（C5）；n 只能凍結前改。

## 4. 環境與身分（C3／C4）

- 本機 lab：`NDT_OWNER` claim＋`NDT_EXCLUSIVE_CPU=1`（本輪判準是 CPU 平台，
  併行負載直接污染）＋窗內全 repo 禁 commit／build／VM；**不疊 9/03 準備窗**；
  與 F-5 輪、B3 本機補臂**分開 claim**（三者都要獨占，不得共窗）。
- **雙 binary／雙組態身分**：四格各記 kernel 與 proxy 的 sha256＋`ldd`＋`readelf -d`
  RUNPATH＋identifying strings；1 kHz 臂如何取得
  ——🔴 **【TBD-1】v0.3 關閉：只能是還原 patch。** `kFlowPathRecomputeInterval` 是
  `include/ndt_core/collection/FlowLinkUsageCollector.hpp:51` 的 `constexpr`，唯一使用點
  `src/ndt_core/collection/FlowLinkUsageCollector.cpp:2969`，kernel collection 樹裡唯一的
  `getenv` 是 `NDTWIN_TOPO_FILE` ⇒ **沒有旗標那一支**。
  兩臂皆由 `build_1khz_binary.sh` 從同一凍結 commit 現建，只差
  `seconds(1)` → `microseconds(1000)` 一行，patch 存檔並記 sha256。
  **不用現成的 `.test_run/binaries/ndtwin_kernel.ab2d7ed1`**：它的 `.provenance` 自記
  `commit=UNKNOWN`／`dirty_worktree=UNKNOWN`，與 `a40e04ce` 的差異未被確立為那一行。
  🔴 **臂的判準不得用 `nm -C | grep kFlowPathRecomputeInterval`**：`.provenance` 用它分辨舊
  binary 是因為 `ab2d7ed1` **早於這個常數存在**；本輪兩臂同樹只差常數的**值**，符號兩邊都在
  ⇒ 會回 5 vs 5，是**一個沒有鑑別力卻看起來驗過了的 PASS**。
  改用：①身分＝staged 檔 sha256 逐字核 `.provenance`；②值＝build 時跑 `2f57ba5` 自附的
  `FlowPathRecomputeInterval.IsOneSecondNotOneMillisecond`，**1 Hz 臂必須綠、1 kHz 臂必須紅**。
- 🔴 **v0.3 補（reviewer 線在 PREREG-B 掃到的同族缺陷；並排 diff 見
  `2026-08-31_completeness-experiments/INSTRUMENT-DIFF-E-vs-F5.md`）**：
  - **臂的指定機制入註冊**（v0.2 只活在腳本裡，換人跑就沒了）：kernel 臂＝以 staged binary
    覆蓋 `build/bin/ndtwin_kernel`，`stack.sh:766` 以**相對路徑** `./bin/ndtwin_kernel` exec 它
    ⇒ 不經 PATH，PREREG-B 的裸名變體在此不會發生。
  - 🔴 **身分取自跑著那顆，不是編出來那顆**：每格 bring-up 之後、量測之前，比對
    `/proc/<pid>/exe` 的 sha256 與該臂 staged 檔 `.provenance` 的 sha256，不符即中止；
    **首尾各取一次**，不符即該格作廢。
    **讀不到 `/proc/<pid>/exe` 算中止，不算通過**——兩個哨兵值彼此相等，用哨兵做首尾對帳會
    空洞地通過。（v0.2 的「四格各記 sha256」沒說取自何處；八格全跑同一顆也會記出一份看起來
    完全正確的身分檔。）
  - 🔴 **bmv2 的身分**（v0.2 只寫「kernel 與 proxy」，而取樣就發生在 bmv2 的 pipeline 裡，
    且 D 輪的 `ladder_ext.sh:82` 本來就記它——這是跨輪的退步）：每格記
    `p4_proxy/mininet/bmv2_binary_override` 的 directive 行與該檔 sha256，**並從 `/proc` 取每一台
    執行中 `simple_switch_grpc` 的 exe sha256；十台必須同一顆，否則該格作廢**。
    （先例：`2026-08-22_stock-control-ladder` 兩臂即「verifying from /proc which binary the live
    switches actually run」。）
  - **這三條自己要先見過紅**：`gates_e.sh` 的 **G8** 對身分檢查三向 force——
    `MATCH`（正確臂）／`MISMATCH`（指到另一臂）／`UNREADABLE`（`/proc` 讀不到）皆須可達，
    且**通過的判準是輸出含 `verdict=MATCH`，不是 exit code 0**（否則「檢查沒跑到」會長得像通過）。
- `truncate=128` 是現行生產組態（`f64897b`）——**四格一致並在每格斷言它**（BRIEF-E 原條款）。
- 取樣器與 py-spy 自身＝已註冊共變量；py-spy **要透過 `mnexec` 跑**（`ptrace_scope=1`）。

## 5. 附掛（獨立判定，不影響主問）

- **GIL 假說**（BRIEF-E §E-5）：閘門格負載下對活 proxy `py-spy dump`。若證實 GIL 是瓶頸，
  E-P2 指向的修法從「猜的」變成「量過的」。**不得用它解釋主問結果**。

## 6. 對帳舊結果（Adam 的規矩）

| 問題 | 答案 |
|---|---|
| 推翻／更新誰 | 天花板若動 ⇒ 更新「取樣天花板 ≈1/16」與 [[telemetry-cost-is-fixed-not-per-sample]]（成本固定不隨取樣率＝**改動前**的性質，本輪重測它是否仍成立） |
| 可對比誰 | 08-25 D 輪四格（`t008`/`t004`…）——**同 fabric、同 binary 才逐格比**，跨 binary 只比方向與格距 |
| 可對比誰（🔴 v0.3 補，v0.2 漏列） | **`gate_e.out`（1/256，batch 1 vs 8）與 `wall_f.out`（1/16，三對交錯，DUR=120）**——同一個 batching 因子的實測，且皆跑在 kernel `3367d0e9`＝**1 kHz 側** ⇒ 它們就是 `BL` vs `M` 在兩個梯階上的部分格。事實：1/16 的 `ratio` 六格皆 0.9955–1.004（batch 1 與 8 都健康）、proxy CPU 71.0/72.3/73.8 → 62.8/62.9/62.3、datagram 3346→447/s；1/256 的 `ratio` 1.016 → 1.008、datagram 209.8→30.6/s。⇒ **E-P4 已有前測：兩個工作點上 batching 都沒有動 `ratio`**，本輪若看到 `ratio` 掉是與舊結果衝突，按 §3b 當 bug 報 |
| 已作廢不得引用 | 206 µs/樣本外推的「~4,900 樣本/秒天花板」（`ab-control-deleted-nothing`） |

## 7. 措辭紅線

- 「天花板抬高」只在 R-E1/R-E2 的嚴格序成立時可寫；不可分辨就寫不可分辨。
- 不與任何 build-ratio（8.0×/12×）數字並列換算；跨輪比較一律標事後探索。
- 歸屬語言受 R-E3 約束：交互作用不得寫成單一改動的功勞。

## 8. 修訂記錄

- v0.1（08-31）：auditor 起草，骨架承 `BRIEF-E-merge.md`（08-26，reviewer 線設計、未跑），
  升級處＝五條件自套（C1 規則先凍／C2 不登記跨輪換算／C3 雙 binary 身分含 RUNPATH／
  C4 獨占與不共窗／C5 凍結後不加）＋2×2 拆糾纏＋陽性對照雙向 force。
  【TBD】×3：①1 kHz 臂的取得方式（旗標 vs patch）②取樣梯是否含 1/1 ③py-spy 附掛的
  claim 內申報文字。
- v0.2（08-31，**資料接觸前**；reviewer 代審四點 E1–E4 全落）：
  E1＝梯頂紀律（對 MP 驗、右截斷記 `≥`、不得事後加梯）；E2＝§3a BL 等價性（(a) 第五格
  `BL-true` 跑牆邊三格，否證或建不起來 ⇒ (c) 改寫宣稱範圍為「batching 參數」）；
  E3＝四次 force 的實作逐字寫死；E4＝Q2 改為天花板語言、CPU 降為 secondary。
  **【TBD-2】就此關閉**（梯頂由 E1 規則決定，不再是待定項）⇒ 實剩兩處。
  ⚠️ **【TBD-1】的連帶條款**：若 1 kHz 走**還原 patch**，則 `BL`/`P` 與 `M`/`MP` 是
  **兩顆不同 binary** ⇒ 2×2 的「只有兩個因子在動」不再成立，須在此處補記
  「binary 差異已知且逐格記錄」並在結論語言中揭露；走**旗標**則無此問題。
  決策一落即補寫（auditor-review E4 附帶）。
- v0.2-stamped（08-31，reviewer 章）：落點逐項親驗通過。並補 **E3b**——CPU gate 的
  force-green 拆兩段（閒置綠＝能綠；**正常臂自身負載下也綠＝不對自己誤報**），
  理由＝「因為沒東西所以通過」是 08-30 記的第二種壞閘門，且 ③ 輪閘門正死在其鏡像。
- **v0.3（08-31，資料接觸前；auditor 裁決，撰稿＝腳本作者，章未蓋）**——五條更正，
  照 [[prereg-amendment-before-data]] 三條件記錄：
  **改了什麼**：①§0 的「batching 已在生產跑了一週」＝假，生產 batching 是關的，
  主要因子改為 recompute，batching 降為「要不要打開」的決策問題；
  ②§3 表格「現行生產組態」由 `MP` 移到 `P`，並凍結 batching on＝8、raw 落點；
  ③§3a 的 (a) 案證實不可執行（`a3bb761^` 內部不一致），**(c) 生效、第五格不跑**；
  ④§8 原第 140 行的連帶條款指錯軸，改為 `BL`/`M`（1 kHz）vs `P`/`MP`（1 Hz）；
  ⑤§4 補三條身分條款（指定機制入註冊／身分取自 `/proc/<pid>/exe` 且讀不到＝中止／bmv2 身分），
  §2 的「四次 force」更正為五次並補 CPU 門檻的基線機制。
  **為什麼**：①②③④是**被證否的事實與一處軸標筆誤**，全部可在窗外以 `git show`／`grep` 複驗；
  ⑤是 reviewer 線在 PREREG-B 掃到的同族缺陷，經 E 與 F-5 儀器節並排 diff 確認 E 有同樣暴露面。
  **誰在什麼時候**：auditor 裁決、腳本作者撰稿，2026-08-31，**兩輪皆未接觸任何量測資料**
  （`raw/` 只有 dry-run 與閘門自測產物）。
  🔴 **未決**：§3 的臂設計（三方案與各自答不出什麼＝`COST-TABLE.md`）待 Adam 排窗裁；
  【TBD-3】py-spy 申報文字待複驗；**v1.0 的章不是本輪撰稿人蓋的**。
