# P4-C — 第三階段遙測 CPU 分析的「逐階視窗」儀器錯誤，離線重驗

**worker C，2026-09-24 11:0x–11:4x UTC。** worktree `scratch/overnight-2026-09-05/wt-p4-cpuwin-0924`，分支 `analysis/cpu-window-recheck-0924`，base `30aa500c`。
**最終 head：`93033c44`**（`50563d38` 只加測試＋fixture，7 格在它上面紅；`93033c44` 修法＋M-E49..M-E53＋控制 C-E3）。
沒 sudo、沒 lab、沒 push、沒 merge、沒編 C++；raw 唯讀（`wt-audit-raw` 的 `git status` 全程空）；`FINDINGS.md`／`PREREG.md`／圖一個字沒動。
輸出在 `scratch/overnight-2026-09-05/logs/orchestrator-0924/cpu-window-recheck/`（下稱 `OUT/`），閘門 log 在 `logs/gates-0910/*.p4c-93033c44.log`。

**[Co-developed with claude code -- Adam]**

---

## 0. 一句話

嫌疑**成立**：`rung_windows` 把同 kpps 的確認 rep 與爬梯 rep 聯集成一個跨越更高階的視窗，CPU 與 S 兩個消費者都錯在「被確認的那一階」（第五次 1024 B：coop 12／30、link 12／20、none 30）。
修正後 **FINDINGS §4 的四個異常全部消失**，但 **沒有任何一個 H-C 判決或對帳 (b) 判定改變**（兩種讀法都一樣）；**變的是數字**：F 降約 3 倍、share 降約 3 倍、m 微升（coop 122.9→126.2、link 79.0→82.4）、bmv2 落外的階從 {12, 45} 換成 {30, 45}（個數仍 2）。
PREREG **沒有說**確認 rep 算不算該階的 CPU ⇒ 兩種讀法都算、並排、**沒有選**；primary keys 用 `climb` 只是佔位（§3）。

---

## 1. 逐條查證（OBSERVED＝我自己讀碼／讀 raw／跑出來的；INFERRED 另標）

| # | 說法（來源） | 結果 | 證據 |
|---|---|---|---|
| 1 | 確認 rep 以 `rep = c1,c2,c3`、kpps＝最高乾淨階記錄，時間在更高階之後；G4/link_f64_b：20 kpps rep1–3 在 …710–…736，然後 30/45/70/110，然後 20 c1–c3 在 …794–…820（orchestrator 已驗） | **成立**。細節更正：walk-down 時**失敗的確認也留列**——G3/link_f64_a 有 30、20、12 三組 c 列（`130352Z_G2` 的 cooperative_f64_a 有 12、20 兩組），所以「c 列只在最高乾淨階」不精確 | `OUT/scan_row_shape.log`；link_f64_b 20 kpps rep1 t_start `1789821710.16`、rep3 t_end `…736.31`、c1 t_start `…794.04`、c3 t_end `…820.19`；聯集寬 110.0 s |
| 2 | `analyse.py` `rung_windows`（~693）把同 kpps 的列聯集成一段 (min t_start, max t_end)；`cpu_for_window`（~645）用在那段（~739-740）；`rung_samples_per_second`（~708）也用 | **成立**，行號在 `30aa500c` 上逐一吻合（`:693-703`、`:645-690`、`:739-740`、`:708`） | 讀碼；`OUT/crosscheck-independent.log` 的 UNION 讀法用另一套算術重建出 base summary 的每一格（差 0） |
| 3 | `sflow_rung<k>_{before,after}` 只框住爬梯 rep（`run_group_arm.sh:378`、`:393`）（未經 orchestrator 驗） | **成立，碼與 raw 雙證**。碼：`:378` 在 rep 1 之前、`:393` 在最後一個爬梯 rep 之後；確認迴圈 `:420-440` 沒有任何 `get_json`。raw：5 支被確認臂（G2/coop_f1024_a、G3/link_f1024_a、G4/link_f1024_b、G5/coop_f1024_b、G4/link_f64_b）全部 `rung<k>_after.addressed_total == 下一階 before`（逐位元相等），確認期間的樣本（5,522／6,670／11,351／14,195／11,256）只出現在整臂的 `sflow_after.json` | 讀碼；`OUT/sflow-pair-bracket.log`（`sflow_pair_bracket.py`）：五支都 `monotone in climb order: True`、`equal: True` |
| 4 | INFERRED：12/20/30 kpps 的逐階 kernel／bmv2 CPU 被灌高 | **大致成立，有一格例外**。1024 B 受影響的 6 個（臂, 階）：bmv2 **6/6 灌高**（+22% 到 +101%）；kernel **5/6 灌高**，`none_f1024_b` @30 **沒有**（聯集 0.646 vs 爬梯 0.654——none 的 kernel 跨階是平的） | `OUT/crosscheck-independent.log` 第一段 |
| 5 | INFERRED：S 失真 | **成立，方向是壓低**（分子只有爬梯的樣本、分母是整段聯集）。coop S(12) 132.0→215.7、S(30) 367.0→550.6；link S(12) 161.4→264.6、S(20) 274.6→425.3 | `OUT/compare-tables-115737Z.log` (1)；獨立儀器同值 |
| 6 | INFERRED：FINDINGS §4 的異常吻合——S(12)=132 < S(8)=153；S(30)=367 ≈ S(20)=359；coop 散佈 2.612 @12；bmv2 比值 1.513 @12 | **四個都吻合、修後都消失**：S(12)=215.7 > S(8)=153.2；S(30)=550.6；coop 散佈 @12＝0.157；bmv2 @12＝1.006（帶內）。**但修後出現新的**：coop 散佈 @30 0.895→2.422、bmv2 @30 1.099→**1.206（落外）** | 同上 (1)(3) |
| 7 | INFERRED：coop 的 m＝122.9 貼著下緣 103，H-C 判決可能變 | **結局不成立**：m 往**遠離**下緣的方向走（126.19／126.18），兩組、兩種讀法、H-C0／H-C1／H-C2 判決**全部不變** | (2) |
| 8 | 更早的 campaign 同形狀？ | **是**。`105759Z_full`（第四次）12 臂全有 c 列、聯集全吞更高階（其中 1024 B 量測臂 6 支）；`093122Z_full` 只有 G1 兩臂，兩臂都吞（1024 B 1 支）；`130352Z_G2`（判別實驗）兩臂都吞；`062206Z_full`、`105437Z_full` **沒有梯子臂**（只有 bring-up／C1／C2）。C3 控制臂的 c 列在 12＝梯頂，吞不到東西。全 raw：34 臂、28 臂吞、其中 1024 B 量測臂 14 | `OUT/scan_row_shape.log` |

**逐階視窗的所有消費者**（讀碼＋葉值對帳）：`rung_windows` → ①`rung_samples_per_second`（S）②`cpu_by_rung` → `cpu_comparison`（kernel 與 bmv2 兩次）→ `per_group` 的 `cpu`／`spread`／`samples_per_s`／`_proxy_plus_emitter`／`softirq_frac` → `rows`（Δ、散佈、resolved、S）→ `fits`（F、m、判決、H-C2 區塊）→ `bmv2_ratio` → `reconcile` (b) → `render`；以及 `plot.py` `figure3_data`（三個面板全讀 `per_group`）。**不是**消費者：負載閘 `external`、§1.2 softirq、§4 的 softirq 逐組陳述（都讀 `arm.meta` 的整臂值）、§1.1 `addressed_total` 增量（整臂 `sflow_before/after`）、天花板、取樣誤差。
**葉值對帳**（`OUT/leafdiff-base-vs-fix.log`）：base 與修後 summary **1560 個葉值相同、99 個變**，變的只在 `cpu_kernel`（45）、`cpu_bmv2`（41）、`cpu_bmv2_ratio`（7）、`reconciliation` 的 **(b) 兩列**（6）；新增的只有 `cpu_window` 區塊與兩個 `rung_window_reading` 鍵。**§1–§3 沒有任何數字依賴這個視窗。**
**base 自己先對帳**：`30aa500c` 在第五次 raw 上重跑，與 audit-raw 存檔的 `summary.json`（`1872be70`）**1644 葉值相同**，差的 15 個全是路徑字串（`OUT/reconcile-base-vs-archived.log`）。

---

## 2. PREREG 註冊了什麼（逐字、行號＝本分支 `PREREG.md`，未改）

- `:161-162`（§4.1）：「`STEP_S=8`；乾淨階＝loss ≤ 0.5%；讀到 0 < loss ≤ 2.0% ⇒ 三 rep 取中位數；截斷＝連續兩階 loss > 25%；**梯頂三 rep 再確認＋walk-down**（全部照 08-28／③ AMENDMENT-2 §11.1）。」——確認是梯子程序的一部分；它的來源 ③ AMENDMENT-2 §11.1(b)（`doc/audit/2026-08-28_flow-count-capacity/PREREG.md:241-258`，讀過）講的是 **loss 的再確認**（「re-confirmed with three reps and scored on the median」），沒有提 CPU。
- `:262-264`（§5.3）：「主軸＝1024 B 梯子上三組共同有的**每一階**……量 `Δkernel(g, k) = kernel_CPU(g, k) − kernel_CPU(none, k)`……橫軸 `S(k)` ＝**該階量到的 samples/s**（`addressed_total` 增量 ÷ 秒）。」
- `:273`（H-C0）：「同一格三個視窗（或三個 rep）的 `Δkernel` 散佈」。
- `:505-507`（AMENDMENT-1 A1.5）：「`run_group_arm.sh` 每一**階**（不是每個 rep）讀一次 `get_sflow_stats`，存成 `sflow_rung<k>_{before,after}.json`；`S(k) = Δaddressed_total ÷ 該階的秒數`。」

**我的讀法**
1. **S(k) 沒有歧義**：分子是那一對快照的差，那一對只框住爬梯（§1 第 3 條，碼＋raw）；「該階的秒數」只能是那對快照涵蓋的秒數＝爬梯。聯集把分母撐到 3.1–5.3 倍（80.7／117.4／137.5／91.7 s 對 ~26 s），**任何讀法都不是 PREREG 說的**。⇒ 修。
2. **「rung k 的 CPU 不含其他階」沒有歧義**：§5.3 的 `kernel_CPU(g, k)` 是「該階」；把 30–110 kpps 算進 20 kpps 不是任何一種讀法。⇒ 修。
3. **「確認 rep 算不算 rung k 的 CPU」PREREG 沒說**：`:162` 只說確認是梯子程序的一部分，§5.3 沒定 CPU 取哪些秒，A1.5 只定了 S 的秒數。⇒ **照工單停在這裡：兩種讀法都算、並排、旗標，不選。**
   - `climb`：只取爬梯 rep（與 S(k) 同一段秒數）。
   - `climb+confirmation`：爬梯段與確認段**各自**算、以秒數加權合併（不是一個跨越中間階的長視窗）；S(k) 仍是爬梯的（確認段沒有快照對，分子分母都無從談起）。

---

## 3. 修法（`93033c44`）

- `rung_windows(arm)` → `{kpps: {"climb": (t0,t1)|None, "confirmation": (t0,t1)|None}}`，以 `rungs.tsv` 的 **rep 標籤**（`run_group_arm.sh` 自己的歸檔：`1/2/3` 爬梯、`c1/c2/c3` 確認）分段；每段內保留舊語意（首 rep 起點到末 rep 終點、含 rep 間 ~1 s 的 server 啟動）。沒被確認的階，視窗與以前**逐位元相同**。
- `rung_samples_per_second`：分母只用爬梯段。
- `cpu_for_windows(rows, clk_tck, spans)`：多段各自 `cpu_for_window`、以 elapsed 加權合併，任一段無讀數⇒整格 None。**`cpu_for_window` 一字未動**（M-E9 錨點與 `tests/red/*.json` 兩個紅跑錨點都在裡面）。machine busy／softirq 分數以 elapsed 加權（非以各段 jiffies 總數），差別只在取樣器抖動——已寫進 docstring。
- `cpu_by_rung(arm, reading=None)`、`cpu_comparison(..., reading=None)`：`None`＝`CPU_WINDOW_PRIMARY`；結果帶 `rung_window_reading`。
- `CPU_WINDOW_READINGS = ("climb", "climb+confirmation")`，`CPU_WINDOW_PRIMARY = "climb"`——**佔位，不是裁決**：primary keys（`cpu_kernel`、`cpu_bmv2`、`cpu_bmv2_ratio`、對帳 (b)）要有值給 `plot.py`／FINDINGS 讀。常數在 `93033c44`（commit 時間 11:15:35Z）設定，**在兩種讀法第一次跑在任何 campaign 上（11:15:4xZ，`OUT/analyse-115737Z.fix-93033c44.log` 檔頭）之前**。選 `climb` 當佔位的理由寫在常數旁：它是唯一讓一階的 CPU 與 S 來自同一段秒數（A1.5 那對快照）的讀法——**這是佔位的理由，不是 PREREG 的讀法**。
- `summary["cpu_window"]`：`primary`、`decided_by_prereg: false`、`question`、`why_not_decided`（引 `:161-162`／`:262-264`／`:503-509`）、`both_readings_agree_on`、`readings.{climb, climb+confirmation}.{cpu_kernel, cpu_bmv2, cpu_bmv2_ratio, reconciliation_b}`。`render()` 多一節 `(3c) 🔴 the rung window is NOT decided by PREREG`，兩種讀法的判決、F、m、share、bmv2 落外階並列。
- 模組 docstring「WHAT IT REFUSES TO DO」加一條。

**測試與 fixture（`50563d38`，最終 head 上 `test_analyse.py` 的一格改過，見下）**
- `tests/fixtures/rungs.115737Z.{G4.link_f64_b, G3.link_f64_a, G2.cooperative_f1024_a}.tsv`：**真 raw 逐字複製**（sha256 前 16 碼與 raw 相同：`9ccf52ab67fd24dc`／`b7d1cbeaf18d13fe`／`ede7c88c3886051d`）。
- `synthetic.write_cpu_following_real_rungs()`：在真的 rungs.tsv 下造 2 Hz CPU 軌跡，kernel 在「k 階的 rep 開始到下一個 rep 開始」之間跑 `2×k`% ⇒ 留在自己階上的視窗讀到恰好 `2k`。
- `synthetic.build(confirm=...)`：照真形狀在爬梯之後補 c1..c3 列；**預設樹逐位元不變**（`diff -r` 新舊 `synthetic.py` 建出的樹：無差異）。
- `RungWindowTest` 7 格（名稱見 §4）。

---

## 4. 紅、變異、閘門

**紅**：`red-cpuwin.p4c-50563d38.log`——測試那顆（`analyse.py` 與 `30aa500c` 相同，log 檔頭 `identical to 30aa500c: yes`），`Ran 108 tests` ／ `FAILED (failures=7, skipped=1)`，**7 個全是 FAIL、沒有 ERROR**，其餘 101 格綠（其中 RenderTest 1 格在無 matplotlib 的 venv 下 skip）。關鍵行（逐字）：
```
AssertionError: 73.75342465753425 != 40.0 within 0.1 delta (33.753424657534254 difference) : rungs.115737Z.G4.link_f64_b.tsv: rung 20 kpps
AssertionError: 26.375 != 158.25 within 6 places (131.875 difference)
AssertionError: 16.020833333333332 != 18.25995 within 0.2 delta (2.2391166666666678 difference)
AssertionError: False is not true : the summary does not say which rung window its CPU was taken over
```
（另三格是 `'reading' not found in mappingproxy(...)`——舊碼沒有第二種讀法。）
**最終 head 重現**：`red-cpuwin-reproduced.p4c-93033c44.log`（`red_against.py --rev 30aa500c --file analyse.py`）——`Ran 108 tests` ／ `FAILED (failures=7, skipped=1)`，同 7 格、全 FAIL；檔頭 `swapped: analyse.py <- 30aa500c (sha256 3d95ba4fa035)`、`as run: tests/test_analyse.py sha256 69b60710ac63`（＝最終 head 的測試檔；紅跑那顆的是 `68d80ebd1d45`）。
🔴 **測試檔在紅跑那顆之後改過一格**：`test_the_confirmed_rungs_climb_window_does_not_reach_the_rungs_climbed_after_it` 在 `93033c44` 改成「有 `reading` 參數就指名要 `climb`」，理由是加控制 C-E3 時發現它會釘住佔位的 primary（`_elapsed_s == 8.0` 只在 primary＝climb 時成立）。上面的重現 log 跑的就是最終測試檔。

| 變異（`mutate_analyse.sh`） | 綁的格 | 閘門怎麼說（`mutate.p4c-93033c44.log`） |
|---|---|---|
| **M-E49** 聯集視窗放回去（確認 rep 當爬梯 rep 歸檔：`part = "climb"`） | `test_on_the_real_rows_every_rungs_cpu_is_that_rungs_own` | caught（`:161`）；also red：其餘 5 格 RungWindowTest（real rows 的 climb+conf、S、pooled、climb、side-by-side） |
| M-E50 S 的分母伸到確認段結尾 | `test_samples_per_second_at_the_confirmed_rung_is_over_its_own_pairs_seconds` | caught（`:163`）；no other case went red |
| M-E51 climb+confirmation 用一個跨越中間階的長視窗算 | `test_the_climb_plus_confirmation_reading_pools_the_reps_own_seconds_only` | caught（`:165`）；also red：side-by-side、real rows 的 climb+conf |
| M-E52 兩種讀法塌成同一種（確認段從未計入） | `test_both_readings_are_in_the_summary_side_by_side_and_neither_is_called_registered` | caught（`:167`）；also red：pooled |
| M-E53 summary 說 PREREG 已決定 | 同上 | caught（`:169`）；no other case went red |
| **控制 C-E3** 佔位 primary 翻成 `climb+confirmation`——**必須綠**（沒有任何一格可以替 PREREG 決定） | —— | stayed green（`:173`） |

（提交前我先用拋棄式腳本在暫存目錄逐一試過這五個變異與控制：M-E49 讓 6 格紅、M-E50 1 格、M-E51 3 格、M-E52 2 格、M-E53 1 格、C-E3 全綠；正式判決以閘門 log 為準。）

**閘門（全部在最終 head `93033c44`，log 在 `logs/gates-0910/`，檔頭有 tree／head／0 uncommitted／時間／直譯器／指令，末行 `### rc=N`）**

| 跑什麼 | rc | 判決行／關鍵行（逐字） | log |
|---|---|---|---|
| **變異閘 M-E1..M-E53 ＋ 3 控制** | **0** | **`mutations: 53   survivors: 0   drifted: 0`**（基線 `Ran 108 tests`） | `mutate.p4c-93033c44.log` |
| 閘門 self-test | 0 | `passed: 14   failed: 0` | `test_mutate_gate.p4c-93033c44.log` |
| 離線整輪（`E_DRIVER` 未設） | 0 | `passed: 78   failed: 0` | `offline-round.p4c-93033c44.log` |
| 單元（`p4_proxy/venv/bin/python` 3.13.13，無 matplotlib） | 0 | `Ran 108 tests in 1.915s` ／ `OK (skipped=1)` | `unit-venv.p4c-93033c44.log` |
| 單元（`/home/adam/miniconda3/bin/python3`，有 matplotlib；RenderTest 用新 summary 形狀真的畫三張圖到暫存目錄） | 0 | `Ran 108 tests in 2.961s` ／ `OK` | `unit-py3.p4c-93033c44.log` |
| `hazard_scan.py` ×4 | 0 | `# hazard_scan: 4 file(s) given, 4 scanned, 0 unreadable, 0 finding(s)` | `hazard-scan.p4c-93033c44.log` |
| 錨點自掃（兩節） | 0 | `--> 56 anchors, 0 that do not resolve exactly once` ／ `--> 13 entries, 0 that do not resolve as declared` | `anchor-sweep.p4c-93033c44.log` |
| `tests/shell/check_gate_anchors.py HEAD` | 0 | `115/115 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` | `check_gate_anchors.p4c-93033c44.log` |
| 紅跑（測試那顆） | 1 | `FAILED (failures=7, skipped=1)` | `red-cpuwin.p4c-50563d38.log` |
| 紅跑在最終 head 重現 | 1 | `FAILED (failures=7, skipped=1)` | `red-cpuwin-reproduced.p4c-93033c44.log` |

舊變異順帶也讓新格紅的（閘門的 also red 行，正常）：M-E9、M-E10、M-E40（M-E40 讓 primary 的 bmv2 帶 H-C 標籤，於是與並排區塊的 bmv2 不相等）。
**沒跑的**：錨點自掃的「故意漂移」自檢（`anchor_sweep.py` 本身沒改，前幾輪的自檢仍對它有效——這是推論，沒重跑）；`postcheck_real_render.py`（沒重畫真圖，工單不准動圖）。

---

## 5. 舊 vs 新（第五次 campaign `2026-09-19T115737Z_full`）

來源：`OUT/summary.115737Z.base-30aa500c.json`（舊）、`OUT/summary.115737Z.fix-93033c44.json`（新，兩種讀法在 `cpu_window.readings`）；表由 `OUT/compare_tables.py` 從兩檔讀出（`OUT/compare-tables-115737Z.log`），**沒有一格是轉抄或重算**。另有**不 import `analyse.py`** 的第二套儀器（每 pid 首末差、`statistics.linear_regression`）重建三種視窗的每一格：與兩份 summary **最大差 0.00e+00**，F／m 差 ≤ 4.3e-14（`OUT/crosscheck-independent.log`）。

### 5.1 FINDINGS §4 逐階表（格內：舊 / climb / climb+conf）

| kpps | 量到的 samples/s（coop） | Δkernel(coop−none) | Δkernel(link−none) | 散佈 coop | 散佈 link | 解析得出 |
|---|---|---|---|---|---|---|
| 1–8 | 不變 | 不變 | 不變 | 不變 | 不變 | 是 |
| **12** | **132.0 / 215.7 / 215.7** | **4.149 / 2.921 / 2.932** | **3.131 / 2.286 / 2.276** | **2.612 / 0.157 / 0.180** | **1.157 / 0.533 / 0.553** | 是 |
| **20** | 359.2（不變） | 4.444（不變） | **4.538 / 3.481 / 3.530** | 0.485（不變） | **3.164 / 1.050 / 1.148** | 是 |
| **30** | **367.0 / 550.6 / 550.6** | **7.836 / 7.119 / 7.125** | **5.281 / 5.327 / 5.314** | **0.895 / 2.422 / 2.383** | 1.741（不變） | 是 |
| 45–110 | 不變 | 不變 | 不變 | 不變 | 不變 | 是 |

link 的 S（不在 FINDINGS 表內，但進 link 的擬合）：12 kpps 161.4 → 264.6、20 kpps 274.6 → 425.3（兩讀法同）。**11 階在三種視窗下全部 resolved ⇒ 兩組都沒有 H-C0。**

### 5.2 分解與判決（PREREG 5.3）

| 組 | 視窗 | F（% of one core） | m（µs/sample） | share | 判決 | H-C2 條件一 | Δ比 / S比（1..110） |
|---|---|---|---|---|---|---|---|
| cooperative | 舊 | 0.9234 | 122.89 | 0.0722 | H-C1（只靠 m 落帶） | True | 20.297 / 51.802 |
| cooperative | climb | **0.3212** | **126.19** | **0.0257** | **H-C1（不變）** | True | 20.297 / 51.802 |
| cooperative | climb+conf | **0.3231** | **126.18** | **0.0258** | **H-C1（不變）** | True | 20.297 / 51.802 |
| link | 舊 | 0.7692 | 79.00 | 0.0623 | not decided（H-C2 條件一成立、條件二無容差） | True | 31.505 / 58.680 |
| link | climb | **0.2492** | **82.41** | **0.0202** | **not decided（不變）** | True | 31.505 / 58.680 |
| link | climb+conf | **0.2521** | **82.40** | **0.0204** | **not decided（不變）** | True | 31.505 / 58.680 |

H-C0／H-C1／H-C2（每組）：**舊、climb、climb+conf 三者判決字串完全相同**。H-C2 區塊的 Δ 比與 S 比取 1 與 110 kpps，兩端都不受影響，所以不變。

### 5.3 bmv2 coop/none（區間 [0.90, 1.15]）

| kpps | 舊 | climb | climb+conf |
|---|---|---|---|
| 1–8、20、45–110 | 不變（0.991、0.988、1.105、1.038、0.943、1.084、1.164 OUT、1.067、1.022） | 同 | 同 |
| **12** | **1.513 OUT** | **1.006 in** | **1.001 in** |
| **30** | **1.099 in** | **1.206 OUT** | **1.235 OUT** |

落外的階：舊 {12, 45} ⇒ 新 {30, 45}（兩種讀法相同）。「9 階一致、2 階不一致」的**計數不變、成員變了**。

### 5.4 對帳 (b)（PREREG 8(b)）

| 組 | 視窗 | m | 固定份額 | 一致？ |
|---|---|---|---|---|
| cooperative | 舊 / climb / climb+conf | 122.89 / 126.19 / 126.18 | 0.0722 / 0.0257 / 0.0258 | 一致（m 落帶）／同／同 |
| link | 舊 / climb / climb+conf | 79.00 / 82.41 / 82.40 | 0.0623 / 0.0202 / 0.0204 | 落外／同／同 |

### 5.5 fig3 會動的格（% of one core；舊 / climb / climb+conf）

kernel：none@30 0.648/0.601/0.614；coop@12 4.795/3.568/3.579；coop@30 8.483/7.720/7.739；link@12 3.778/2.933/2.923；link@20 5.120/4.063/4.112。
bmv2：none@30 376.8/306.1/302.1；coop@12 210.0/139.6/138.9；coop@30 414.2/369.3/373.2；link@12 204.9/138.6/137.4；link@20 267.7/214.7/216.6。
proxy+emitter：none@30 2.318/2.292/2.224；coop@12 16.765/12.233/12.160；coop@30 26.975/24.383/24.500；link@12 7.305/6.062/5.885；link@20 8.416/6.855/7.188。
（圖沒有重畫——工單不准動圖；`plot.py` 在最終 head 能吃新 summary，`unit-py3` 的 RenderTest 畫過。）

### 5.6 第四次 campaign（`105759Z_full`，補充，FINDINGS 沒有引用它的 CPU）

`OUT/fourth-campaign-105759Z.log`：同一個缺陷、同方向——coop F 0.9098→0.2038／0.2099、m 110.95→116.46／116.56；link F 0.9809→0.3670／0.3789、m 83.91→86.91／86.90；判決不變（coop H-C1、link not decided）；bmv2 三種視窗都沒有落外的階；coop S(30) 173.2→534.9；沒有 unresolved 列。

---

## 6. FINDINGS 會變的句子（**只列，不改**；行號＝本分支 `FINDINGS.md`）

| 行 | 現在寫的 | 會變成（climb；climb+conf 若不同另註） |
|---|---|---|
| `:153` | `\| 12 \| 132 \| +4.149 \| +3.131 \| coop 2.612／link 1.157 \| 是 \|` | `216`、`+2.921`（+2.932）、`+2.286`（+2.276）、`coop 0.157／link 0.533`（0.180／0.553）、是 |
| `:154` | `\| 20 \| 359 \| +4.444 \| +4.538 \| coop 0.485／link 3.164 \| 是 \|` | Δlink `+3.481`（+3.530）、link 散佈 `1.050`（1.148）；其餘不變 |
| `:155` | `\| 30 \| 367 \| +7.836 \| +5.281 \| coop 0.895／link 1.741 \| 是 \|` | `551`、`+7.119`（+7.125）、`+5.327`（+5.314）、coop 散佈 `2.422`（2.383） |
| `:164` | coop `0.9234 \| 122.89 \| 0.0722`、「share 0.072」 | `0.3212 \| 126.19 \| 0.0257`、「share 0.026」（0.3231／126.18／0.0258）；判決字串、Δ比 20.297、S比 51.802 不變 |
| `:165` | link `0.7692 \| 79.00 \| 0.0623`、「share 0.062」 | `0.2492 \| 82.41 \| 0.0202`、「share 0.020」（0.2521／82.40／0.0204）；判決字串、31.505／58.680 不變 |
| `:167` | 「122.89 ∈ [103, 618]；固定份額 0.0722 < 0.5」「m 79.00 落帶外、固定份額 0.0623」 | 126.19、0.0257；82.41、0.0202。**句子的結論不變** |
| `:169` | 「12 kpps 1.513 … 30 kpps 1.099 … 9 階一致、2 階不一致（落外的階：12 kpps 1.513、45 kpps 1.164）」 | 12 kpps **1.006**、30 kpps **1.206**（1.001／1.235）；「落外的階：**30 kpps 1.206**、45 kpps 1.164」 |
| `:196-199` | m 122.9／份額 0.072／m 79.0／份額 0.062 | 126.2／0.026／82.4／0.020；四個判定（一致／不成立／落外／不成立）不變 |
| `:202` | 「會把 m 壓低（本輪 79.0 < 103）」「固定份額（0.062）自然變小」 | 82.4、0.020（這兩個候選本身是 INFERRED，不受影響） |
| `:263` | 支持欄「`cooperative` 的 m＝122.9」；不支持欄「`link` 的 m＝79.0 落外且固定份額 0.062」 | 126.2；82.4、0.020 |
| `:146` 表頭 | 「本輪 11 階全解析、差異未改判決」 | **不變**（三種視窗都 11 階全解析） |
| 新增（建議） | —— | §4 或 §6 需要一句說明逐階視窗的讀法未由 PREREG 決定、兩讀法並列、primary 是佔位；以及 fig3 在 12/20/30 會變 |

§0–§3、§1.1、§1.2、§4 的 softirq 陳述、§5(a)、§5(c)：**不變**（葉值對帳證明）。

---

## 7. OBSERVED vs INFERRED

**OBSERVED**（我讀的碼、我跑的指令、log 在 `OUT/` 與 `logs/gates-0910/`）
- 表 §1 的 1、2、3、5、8 全部；第 4 條的逐臂數字；第 6 條的四個數字修前修後；第 7 條的判決字串。
- base 重現存檔 summary（1644 葉值同）；修後只有 CPU 四個 key 變（99 葉值）；獨立儀器與兩份 summary 差 0。
- 7 格在 `50563d38` 紅（FAIL、無 ERROR）；閘門結果見 §4。
- 第四次 campaign 同形狀、同方向、判決不變。
- coop @30 的兩臂（`OUT/coop-30kpps-per-arm.log`）：coop_f1024_a 在 30 kpps 只有一個爬梯 rep、loss 7.74%（它自己的天花板是 12），kernel 8.931／bmv2 438.28；coop_f1024_b 三個乾淨 rep，6.509／300.23（climb+conf 6.548／308.14）；舊聯集下 b 臂是 8.036／390.08。這就是散佈 @30 0.895→2.422 與 bmv2 @30 1.099→1.206 的來源：舊視窗把 b 臂灌高、把兩臂拉近。

**INFERRED**（沒有量、只是推）
- coop @30 的機制：a 臂那一 rep 已過它自己的拐點、飽和的 bmv2 多燒 CPU ⇒ 30 kpps 這一格其實是「一臂過載、一臂乾淨」的中位數（兩臂＝平均）。數字見 OBSERVED，機制沒有另外量。
- 「那句話在天花板附近不成立」（PREREG `:277`）在 30／45 比在 12 更貼切——這是對結果的詮釋，PREREG 沒有註冊哪一階算「天花板附近」。
- F 降到三分之一左右代表「固定成本」在本 fabric 更小——PREREG 的 (b) 判準是比 m 不比 F（`PREREG.md:361`），所以這只影響敘述，不影響判定。

---

## 8. Dissent（我不同意或沒把握的地方）

1. **有一個預設值就是一種選擇。** 工單說兩種讀法並排、不選；但 `plot.py` 與 FINDINGS 讀的是 primary keys，它們必須有值，所以我放了 `climb` 當佔位、`decided_by_prereg: false` 旗標、控制 C-E3 保證沒有一格釘住它。如果 orchestrator 認為連佔位都不該有，替代方案是 primary keys 改成 None 並讓 `plot.py`／render 顯示「未決」——那要動 `plot.py`，超出本工單的檔案範圍。**在本輪數據上兩種讀法的判決完全相同；m 差 ≤ 0.01 µs/sample（126.19 vs 126.18、82.41 vs 82.40），最大的差是 bmv2 比值 @30（1.206 vs 1.235）與 link 散佈 @20（1.050 vs 1.148）**，所以這個選擇目前不改任何結論；它會在「確認段與爬梯段的 CPU 差很多」的未來 campaign 上有差。
2. **H-C0 的散佈量仍是兩臂全距**，不是 PREREG `:273` 的「三窗／三 rep 的 Δkernel 散佈」（裁決 40⑤ 定為本輪不改）。有意思的是：確認段正好提供了被確認那一階的第二組三 rep——如果將來要照 `:273` 算，`climb+confirmation` 讀法才有「三個 rep」可用。這是觀察，不是建議現在改。
3. **預設 fixture 仍然沒有確認列。** 每一支真的梯子臂都有，而這正是 ruling 27／32／35 那一族（fixture 沒照 raw 的形狀）第四次出現。我沒有改預設樹，因為 101 格舊測試釘在它的算術上，改它是另一張工單的範圍；新 7 格用 `confirm=` 參數與三份逐字真 rows 補上。**結構對帳（`inventory.py`／`test_real_shape.py`）只比 TSV 的表頭欄位，不比列的內容**——rep 標籤 `c1..c3` 永遠不會被那支對帳看到。建議另開工單：讓預設樹帶確認列，並讓 inventory 記錄 rungs.tsv 的 rep 標籤集合。
4. **`climb+confirmation` 把「確認失敗」的那一組也併進去**（walk-down 的 30、20 在 link_f64_a）。這在 64 B 臂上、不進 CPU 擬合，但如果裁決選這個讀法，要不要只併「確認成功」的那一組，也是 PREREG 沒說的。
5. `cpu_for_windows` 的 machine 分數以 elapsed 加權而非以各段 jiffies 總數加權；兩者只差取樣器抖動，只影響 `per_group.softirq_frac`（FINDINGS 沒有引用逐階 softirq）。

---

## 9. 檔案

- 分支 commit：`50563d38`（tests only）、`93033c44`（fix）。動到的檔：`analyse.py`、`tests/test_analyse.py`、`tests/synthetic.py`、`tests/mutate_analyse.sh`、`tests/fixtures/rungs.115737Z.{G2.cooperative_f1024_a,G3.link_f64_a,G4.link_f64_b}.tsv`（新）。
- `OUT/`：`scan_row_shape.{py,log}`、`analyse-115737Z.{base-30aa500c,fix-93033c44}.log`、`summary.115737Z.{base-30aa500c,fix-93033c44}.json`、`reconcile-base-vs-archived.log`、`leafdiff.py`、`leafdiff-base-vs-fix.log`、`crosscheck_independent.py`、`crosscheck-independent.log`、`compare_tables.py`、`compare-tables-115737Z.log`、`fourth-campaign-105759Z.log`、`sflow_pair_bracket.py`、`sflow-pair-bracket.log`、`coop-30kpps-per-arm.log`、`run_gates.sh`、`run_gates.93033c44.out`。
- 本 SUMMARY 不在 repo（worktree 外），沒有 commit。

**[Co-developed with claude code -- Adam]**


---

# Round 2（判官 HOLDS WITH CORRECTIONS＋Adam 裁決 4，2026-09-24 12:0x–12:4x UTC）

**最終 head：`611a08d3`**。本輪 commit：`088c82a0`（只加／改測試；5 格在它上面對 `93033c44` 的碼紅）→ `68735150`（`analyse.py`／`plot.py`／閘門）→ `611a08d3`（`FINDINGS.md`、`fig3_cpu.png`／`.pdf`）。
檔案範圍＝工單給的：`analyse.py`、`plot.py`、`tests/**`、`FINDINGS.md`、`fig3_cpu.{png,pdf}`；`PREREG.md`、fig1／fig2、目錄外一個字沒動。沒 push、沒 merge、沒 sudo、沒 lab。
輸出仍在 `OUT/`＝`scratch/overnight-2026-09-05/logs/orchestrator-0924/cpu-window-recheck/`；閘門 log 在 `logs/gates-0910/*.p4c-611a08d3.log`。

**[Co-developed with claude code -- Adam]**

## R2.0 一句話

照裁決 4：主讀法＝**climb**，**Adam 2026-09-24 裁定（TICKET-P4 §7 ruling 4）、非 PREREG 註冊**，每一個帶 CPU 數字的輸出（`cpu_kernel`、`cpu_bmv2`、`cpu_bmv2_ratio`、對帳 (b) 每一列、render 的 (3)/(3b)/(3c)/(b)、fig3 標題）都寫明讀法；climb+confirmation 照算、並列。
**更正第一輪的框定**：H-C（兩組）與對帳 (b) 不變；**註冊的 bmv2 逐階判決有 2／11 翻轉**（12 kpps 帶外→帶內、30 kpps 帶內→帶外，帶外仍 2／11）。第一輪最終訊息的「It does not change any registered verdict」是錯的（見 R2.6）。
FINDINGS §4 已用腳本重生並加 §4.0 勘誤表（舊值保留）；fig3 重生。兩種讀法在第五次 campaign 的判決逐項相同（腳本算的，`OUT/fill-findings-erratum.log`：`the two readings agree: H-C True, (b) True, bmv2 per rung True`）。

🔴 **一個沒照字面做到的地方，先講**：工單要 fig1／fig2「byte-identical」。**PNG 逐位元相同；PDF 不是**——只差 `/CreationDate` 裡的 6 個位元組（matplotlib 的 PDF 後端把當下時間寫進去）。`OUT/figures-68735150.log`：兩個 PDF 各 6 個差異位元組、**全部落在 `/CreationDate` 值內**（`committed D:20260920001544+08'00', regenerated D:20260924200932+08'00'`），長度相同。控制組：用**勘誤前的** `plot.py`（`30aa500c`）畫**存檔的** summary.json，得到一模一樣的樣子（fig1/fig2/fig3 的 PNG 全相同、三個 PDF 只差日期）⇒ 這是任何重畫都會有的時間戳，不是本輪的改動。**我沒有停**，理由：fig1／fig2 我沒有重新提交（repo 裡的檔案一個位元組沒動，`git diff --stat 93033c44 611a08d3` 只列 fig3），而內容相同已逐位元證明到只剩時間戳。**如果 orchestrator 的意思是字面的位元組相同，這一條算 BLOCKED，請裁**；要讓 PDF 可重現得改 `plot.py` 的 `savefig(metadata=...)`，那會改變 fig1／fig2 的位元組，不在本輪範圍。

## R2.1 裁決 4 的實作（`68735150`）

- `analyse.py`：`CPU_WINDOW_PRIMARY = "climb"`（不再是佔位）、`CPU_WINDOW_DECIDED_BY = "Adam 2026-09-24, TICKET-P4 §7 ruling 4"`、`CPU_WINDOW_RATIONALE`（判官第 6 條：§5.3 `:263-266` 把 CPU(k) 與 S(k) 配成一個擬合、S(k) 只涵蓋爬升 `:505-507` ⇒ 同窗；08-28 規則 `2026-08-28_flow-count-capacity/PREREG.md:254-255` 把首讀與再確認分開記，"so a disagreement between them is visible rather than overwritten"——兩處引文我逐行讀過）。`summary["cpu_window"]` 帶 `primary`、`secondary`、`decided_by`、`decided_by_prereg: false`、`rationale`、`why_prereg_does_not_decide`；climb+confirmation 照算。
- `cpu_bmv2_ratio` 與每一列對帳 (b) 帶 `rung_window_reading`；render 的 (3)、(3b) 標題、(3c) 與每一行 (b) 印出讀法（`rung_window_label()` 從 summary 讀，不從模組常數讀；(a) 不印——那不是 CPU）。
- `plot.py`：`rung_window_of()` 從 summary 讀讀法，fig3 標題寫 `rung window: climb`；kernel 與 bmv2 兩塊讀法不同 ⇒ `ValueError`（拒畫混合圖）；勘誤前的 summary ⇒ `rung window: not recorded`。圖上只多四個字的讀法名，誰裁定、為什麼寫在 FINDINGS（CLAUDE.md 圖上少字）。
- docstring 更正（判官第 6 條）：climb 段**不是**「剛好」那對快照的秒數——`:378` 的讀取在第一個 rep 的 iperf3 server 啟動與 `sleep 1`（`:331-332`）之前，所以快照對至少比 climb 段多 ~1 s。這是勘誤前就有的、未改；那一秒沒有流量（依 `run_group_arm.sh` 的程序推論，未量）。

## R2.2 判官的七條，逐條

| # | 判官要的 | 做了什麼 | 證據 |
|---|---|---|---|
| 1 | 框定：註冊的 bmv2 逐階判決有翻 | 本段、FINDINGS §4.0／§4 bmv2 句、R2.6 的更正表都寫「H-C 與 (b) 不變；2／11 註冊的 bmv2 逐階判決翻轉」 | `OUT/compare-tables-115737Z.68735150.log` (3) |
| 2 | 下游標讀法；`primary="climb"`、`decided_by`、`decided_by_prereg=false`；翻 primary 要在單元測試之外變紅 | R2.1。C-E3（佔位翻轉必須綠）**退役**，改成 **M-E54**（翻轉必須紅），綁 `test_plot.Figure3RungWindowTest.test_figure3_names_its_rung_window_and_draws_the_climb_reading`——它從合成 raw 走 `analyse.analyse` → `plot.figure3_data` 與 `analyse.render`，在確認段比爬梯熱 4 點的樹上同時斷言標題、kernel 面板 coop 在 8 kpps 的點、render 的整句讀法 | 閘門 log 的 M-E54 行（R2.4） |
| 3 | 揭露 `50563d38`→`93033c44` 的 `synthetic.py` 變動 | 只改了模組 docstring 的表（+5 行）；去掉所有 docstring 後 AST 相同 | `OUT/judge3-synthetic-diff.log`（`a05b9f81c935` vs `9d18a2d3b239`；`CODE IDENTICAL WITH DOCSTRINGS REMOVED: True`） |
| 4 | leafdiff 存成逐路徑清單 | 三份：base→`93033c44`、base→`68735150`、`93033c44`→`68735150`，各附組成表 | `OUT/leafdiff-base-vs-fix-93033c44.full.log`＋`.composition.log`（CHANGED：cpu_kernel 45／cpu_bmv2 41／cpu_bmv2_ratio 7／reconciliation 6；ONLY-B：cpu_window 1653、cpu_kernel 1、cpu_bmv2 1）；`OUT/leafdiff-base-vs-68735150.full.log`＋`.composition.log`（同 99 個 CHANGED；ONLY-B：cpu_window 1662、reconciliation 2、cpu_bmv2_ratio 1、cpu_kernel 1、cpu_bmv2 1）；`OUT/leafdiff-93033c44-vs-68735150.full.log`（**0 個值變**，只多 13 個讀法／裁定鍵、少 1 個改名鍵） |
| 5 | 綁一個行為變異到 `test_the_default_tree_has_no_confirmation_rows_so_both_readings_agree_there` | **M-E55**：第二讀法只留「有被再確認」的階——沒有 c 列的梯子上它什麼都不讀，兩讀法不再一致。第一輪那格在舊碼上紅**只因為**舊碼沒有 `reading` 參數，不是因為它的性質；已寫進那格的註解 | 閘門 log 的 M-E55 行 |
| 6 | SUMMARY 更正 | 見 R2.6 的逐條更正表；需要成品的都補了成品，補不了的標 INFERRED | R2.6 |
| 7 | 再確認段自己的 CPU（不合併）當資料 | 第五次 12 支梯子臂的 14 個再確認階（link_f64_a 走降 30／20／12 三組），爬梯段與再確認段各自的 kernel／bmv2／proxy+emitter 與每個 rep 的 loss。**只描述、不下判決**。判官點名的 `G3/link_f64_a` 12 kpps：爬梯 loss 0.1042／0.1198／0.0031，再確認 1.0064／0.0000／0.4240（中位數 0.424，仍過 0.5）——再確認段比爬梯 lossier，確認成立；CPU 兩段 2.588 vs 2.653（kernel）、131.67 vs 138.63（bmv2） | `OUT/confirmation-only-cpu-115737Z.log`（`confirmation_only_cpu.py`，用 `analyse.cpu_for_window` 與 `rung_windows`） |

## R2.3 FINDINGS 與 fig3（`611a08d3`）

- **腳本**：`OUT/fill_findings_erratum.py`，輸出與完整 unified diff：`OUT/fill-findings-erratum.log`。每一句引用被改動鍵的句子寫成模板：先用**勘誤前**的 summary 填、斷言它在 FINDINGS 裡**恰好出現一次**（＝證明公開的句子就是舊 summary 說的），再用**勘誤後**的 summary 填同一個模板取代。新加的文字（§4.0、H-C1 註、讀法標籤、§6 第 11 條）也是模板，數字全從兩份 summary 取；兩個不在 summary 裡的事實（例子臂的聯集寬 110.0 s、1024 B 受影響格）由腳本讀 raw 算。腳本斷言兩讀法判決逐項相同，否則拒寫。
- 🔴 **我的一個錯，照實記**：第一次改腳本時我用了**沒加引號的 heredoc**，bash 把 Python 字串裡的反引號當成指令替換展開。沒有任何指令真的執行（全是 `command not found`／`Is a directory`／`Permission denied`——後者是 bash 想把 `P4-C-SUMMARY.md` 當指令執行、因為沒有執行權限而失敗，該檔 mtime 未變），Python 的修改在第一個 assert 就中止、腳本沒被改；但同一行後半用**舊版腳本**寫了 FINDINGS。我用 `git checkout -- FINDINGS.md` 還原（那是我自己剛寫的輸出）、改用 `<<'PYEOF'` 重做，log 檔頭記著這件事。主 checkout 的已追蹤修改與開工時的快照相同（`OUT/main-checkout-status.log`：同樣 11 個 `M` 路徑，都不是我的）。
- **內容**：§4.0 勘誤（錯在哪＋行號、誰何時發現與驗證、讀法與誰裁定＋理由、兩讀法判決相同、判決變動、舊→新表 29 列、指向 `OUT/` 與本檔）；§4 表 12／20／30 三列、分解兩列、「判定欄怎麼讀」、bmv2 逐階句、§5(b) 表四列與兩個候選數字、§8 兩處——全部由腳本重生；分解與 (b) 標題下加「逐階視窗＝climb（Adam 裁定、非 PREREG 註冊）」；§6 加第 11 條（讀法不是註冊的，並給兩個讀法數字不同的例子）。
- **H-C1 的字面**：cooperative 那一列標籤旁明寫「標籤名說『固定成分主導』，但固定份額只有 0.0257——H-C1 在這裡成立的依據**只有** m＝126.19 落在 [103, 618]（裁決 40④）；固定份額那一條（≥ 0.5）不成立」。
- **fig3**：`plot.py` @ `68735150`、miniconda python3（matplotlib 3.10.8）、輸入 `OUT/summary.115737Z.fix-68735150.json`，標題 `CPU by telemetry source and offered rate (1024 B frames, rung window: climb)`；提交的兩檔與 `OUT/figs-68735150/` 的逐位元相同（sha256 前 16 碼 `8438249645cc3030`／`b2f362868de5235a`）。真字框檢查：`OUT/postcheck-real-render.68735150.log`——`EVERY LABEL'S REAL TEXT BOX INSIDE ITS OWN AXES: True`、`EVERY AXES BOX UNMOVED BY set_ylim: True`。

## R2.4 紅、變異、閘門（最終 head `611a08d3`）

**紅（本輪新增／改動的測試，對第一輪的碼）**：`red-r2-ruling4.p4c-088c82a0.log`——`088c82a0` 的測試對 `93033c44` 的 `analyse.py`（`68c7dea1e7f3`）＋`plot.py`（`8326a3b3174e`）：`Ran 112 tests` ／ `FAILED (failures=5, skipped=1)`，5 個全是 FAIL、0 ERROR：
```
AssertionError: None != 'Adam 2026-09-24, TICKET-P4 §7 ruling 4'
AssertionError: None != 'climb' : cpu_bmv2_ratio
AssertionError: 'rung window: not recorded' not found in 'CPU by telemetry source and offered rate (1024 B frames)'
AssertionError: 'rung window: climb' not found in 'CPU by telemetry source and offered rate (1024 B frames)'
AssertionError: ValueError not raised
```
（這份 log 的 wrapper 第一次寫錯了 rc——`echo` 之後才取 `$?`——已重跑覆寫，末行 `### rc=1`。）

**紅在最終 head 重現**（最終測試檔 `test_analyse.py 31c4b526dd90`、`test_plot.py d67638620084`、`synthetic.py 9d18a2d3b239`）：
- 對第一輪的碼 `93033c44`（`analyse.py`＋`plot.py` 都換）：`red-r2-vs-93033c44.p4c-611a08d3.log`——`FAILED (failures=5, skipped=1)`，同 5 格、0 ERROR。
- 對勘誤前的碼 `30aa500c`（兩檔都換）：`red-cpuwin-vs-base.p4c-611a08d3.log`——`FAILED (failures=9, errors=2, skipped=1)`；第一輪 7 格＋本輪 4 格。**那 2 個 ERROR** 是本輪的 `test_every_downstream_cpu_output_names_the_rung_window_it_was_taken_over` 與 `test_figure3_refuses_panels_from_two_different_rung_windows`：勘誤前的 summary 根本沒有 `cpu_window`，所以是查鍵失敗、不是性質失敗；它們的性質紅看上一行（對 `93033c44` 是 FAIL）。

| 變異 | 綁的格 | 閘門怎麼說（`mutate.p4c-611a08d3.log`） |
|---|---|---|
| M-E53（錨點隨行移動，變異不變） | side-by-side 那格 | caught（`:169`）；no other case went red |
| **M-E54** primary 翻成 climb+confirmation（C-E3 退役後的變異） | `test_figure3_names_its_rung_window_and_draws_the_climb_reading` | caught（`:171`）；also red：`test_figure3_refuses_panels_from_two_different_rung_windows` |
| **M-E55** 第二讀法只留被再確認的階 | `test_the_default_tree_has_no_confirmation_rows_so_both_readings_agree_there` | caught（`:173`）；no other case went red |
| M-E56 render 不再寫讀法 | `test_every_downstream_cpu_output_names_the_rung_window_it_was_taken_over` | caught（`:175`）；also red：fig3 那格（它也斷言 render 的整句） |
| M-E57 fig3 標題不再寫讀法 | `test_figure3_names_its_rung_window_and_draws_the_climb_reading` | caught（`:177`）；also red：pre-recheck summary 那格 |

**閘門（全部在 `611a08d3`，每份 log 檔頭 `head: 611a08d3 (0 uncommitted path(s) under the round directory)`，末行 `### rc=N`）**

| 跑什麼 | rc | 判決行（逐字） | log |
|---|---|---|---|
| **變異閘 M-E1..M-E57 ＋ 2 控制** | **0** | **`mutations: 57   survivors: 0   drifted: 0`**（基線 `Ran 112 tests`） | `mutate.p4c-611a08d3.log` |
| 閘門 self-test | 0 | `passed: 14   failed: 0` | `test_mutate_gate.p4c-611a08d3.log` |
| 離線整輪 | 0 | `passed: 78   failed: 0` | `offline-round.p4c-611a08d3.log` |
| 單元（venv，無 matplotlib） | 0 | `Ran 112 tests in 3.510s` ／ `OK (skipped=1)` | `unit-venv.p4c-611a08d3.log` |
| 單元（miniconda，matplotlib 3.10.8；RenderTest 畫過三張圖） | 0 | `Ran 112 tests in 6.151s` ／ `OK` | `unit-py3.p4c-611a08d3.log` |
| `hazard_scan.py` ×4 | 0 | `# hazard_scan: 4 file(s) given, 4 scanned, 0 unreadable, 0 finding(s)` | `hazard-scan.p4c-611a08d3.log` |
| 錨點自掃（兩節） | 0 | `--> 59 anchors, 0 that do not resolve exactly once` ／ `--> 13 entries, 0 that do not resolve as declared` | `anchor-sweep.p4c-611a08d3.log` |
| `tests/shell/check_gate_anchors.py HEAD` | 0 | `115/115 cells ok  (0 not ok, of which 0 were NOT CHECKED AT ALL)` | `check_gate_anchors.p4c-611a08d3.log` |
| 紅，對 `93033c44` | 1 | `FAILED (failures=5, skipped=1)` | `red-r2-vs-93033c44.p4c-611a08d3.log` |
| 紅，對 `30aa500c` | 1 | `FAILED (failures=9, errors=2, skipped=1)` | `red-cpuwin-vs-base.p4c-611a08d3.log` |

錨點自掃在本輪真的抓到一次漂移：加 `decided_by` 時 M-E53 的錨點行被我改掉（`hits=0  BAD`），移錨點後才跑閘門。本輪也先用拋棄式腳本試過 M-E53..M-E57（不是證據，證據是上表）。
閘門腳本：`OUT/run_gates_r2.sh`（第一輪那支加兩個紅跑、改 why 行），總表 `OUT/run_gates.611a08d3.out`。

## R2.5 第一輪的分析結果：本輪有沒有動？

**沒有一個數字動**。`OUT/leafdiff-93033c44-vs-68735150.full.log`：3313 個葉值相同、0 個變；差別只有新增的讀法／裁定鍵與 `why_not_decided` 改名成 `why_prereg_does_not_decide`。`OUT/compare-tables-115737Z.68735150.log` 與第一輪的表逐字相同（`OUT/compare-tables-r1-vs-r2.log`：`TABLES IDENTICAL TO ROUND 1`），獨立儀器對新 summary 仍差 0（`OUT/crosscheck-independent.68735150.log`，檔頭寫明範圍）。

## R2.6 第一輪說過、本輪更正或撤回的話（第一輪的文字留在上面不改，以這張表為準）

| 第一輪的位置 | 原話（摘） | 更正 | 成品 |
|---|---|---|---|
| 最終訊息 | "It does not change any registered verdict." | **錯**。H-C 與 (b) 不變；**2／11 註冊的 bmv2 逐階判決翻轉**（PREREG `:276-277` 是逐階註冊的） | `OUT/compare-tables-115737Z.68735150.log` (3) |
| §0、§3、§8-1 | primary＝climb「只是佔位、不是裁決」 | **被裁決 4 取代**：climb 由 Adam 裁定、非 PREREG 註冊 | `analyse.py` `CPU_WINDOW_DECIDED_BY` |
| §1 第 3 條 | 「5 支被確認臂」全部相等 | 第五次**12 支梯子臂全有 c 列**，第一輪只查了 5 支。本輪查**全部 4 個 campaign 的 28 支梯子臂、31 個被再確認的階：全部 EQUAL、全部單調**；其中 `none` 臂計數器恆為 0，相等沒有鑑別力，有鑑別力的是 18 支處理組臂（其餘 10 支是 `none`） | `OUT/sflow-pair-bracket-all.log`（`sflow_pair_bracket_all.py`） |
| §1 第 3 條 | 確認期間的樣本（5,522…）「只出現在整臂的 sflow_after」 | 那段區間是「最後一個爬梯快照之後到整臂最後一次讀」——再確認 rep **加上**那段時間裡其他任何事；**沒有分開歸屬**，改標 INFERRED | 同上（log 的欄名已改成 "after last climb pair -> arm sflow_after"） |
| §1 第 8 條 | 各 campaign 的 1024 B 臂數（6／1…）| 那是我從清單數的；v2 掃描直接印出：093122Z 1、105759Z 6、115737Z 6、130352Z_G2 1（與第一輪說的相同） | `OUT/scan_row_shape_v2.log` |
| §3、`analyse.py` docstring | climb 段「exactly」那對快照的秒數 | **不精確**：快照對至少多 ~1 s（`:378` 在 server 啟動與 `sleep 1` 之前）；勘誤前就如此，不影響判決 | `analyse.py` `rung_windows` docstring（`68735150`） |
| §3 | 預設樹 `diff -r` 無差異 | 第一輪沒存成品；本輪補：30aa500c 與 93033c44 的 `synthetic.py` 各建一棵，186 vs 186 檔，`DIFF -r: NO DIFFERENCE` | `OUT/judge6-default-tree-diff.log` |
| §3 | fixture 的 sha256 與 raw 相同 | 補成品（全長 sha256，從 `50563d38` 用 `git show` 讀） | `OUT/judge6-fixture-sha256.log` |
| 開頭 | `wt-audit-raw` 的 `git status`「全程空」 | 第一輪是主控台檢查、沒存成品；「全程」是推論。本輪 12:03Z 存了一次：`--ignored` 也空、raw 下沒有 mtime 晚於 11:00Z 的檔 | `OUT/judge6-audit-raw-untouched.log` |
| §3 | 常數「在兩種讀法第一次跑在 campaign 上之前」設定 | commit `93033c44` 11:15:35Z、第一份有 log 的修後分析 11:15:44Z——有成品；「之前沒有**未記錄**的執行」**無法用成品證明**（第一輪 commit 前唯一碰到真資料的是單元測試：三份逐字 rungs.tsv 配**合成**的 cpu.jsonl） | `OUT/judge6-primary-timing.log` |
| §4 | 「提交前用拋棄式腳本試過五個變異」 | 沒有成品，**撤回當證據**；證據是閘門 log。本輪同樣先用拋棄式腳本試過四個新變異——同樣不是證據 | `mutate.p4c-*.log` |
| §5 開頭 | 獨立儀器「重建每一格」 | 範圍更正：它重建的是**逐組 kernel／bmv2 CPU 格、S、kernel 擬合的 F／m**；用**同一條切段規則與同一個中位數**——它證明的是算術，不是視窗語意 | `OUT/crosscheck-independent.68735150.log` 檔頭的 SCOPE 行 |
| Dissent 1 | 「m 差 ≤ 0.01」 | link 是 **0.0124**（82.4147 vs 82.4023），coop 0.0062；且漏了 bmv2 的描述性擬合：**link 的 bmv2 擬合 climb F 20.77／m 213.6 vs climb+conf F 29.27／m 144.3**（勘誤前 F −131.24／m 1454.26；coop 三者皆 F 322.14／m −2964.84——只有少數階 resolved）；也漏了 bmv2 散佈：none@30 5.815／1.463／4.767、coop@12 138.709／1.994／3.381、coop@30 48.206／138.056／130.141、link@12 135.506／2.875／0.463、link@20 101.041／5.026／1.149（勘誤前／climb／climb+conf）。這些都不帶註冊判決 | 本輪用 summary 算的；數字與判官一致 |
| Dissent 2 | 「只有 climb+confirmation 才有 `:273` 要的三個 rep」 | **與 raw 矛盾，撤回**：六個被再確認的 1024 B 階（none 30×2、coop 12／30、link 12／20）的爬梯段**本來就各有三個 rep**（爬梯時 loss 非零就補到三個） | `OUT/confirmation-only-cpu-115737Z.log` 的 climb losses 欄（每列三個值） |

## R2.7 OBSERVED vs INFERRED（本輪）

**OBSERVED**：R2.2 表中每一條的成品；fig1／fig2 PNG 逐位元相同、PDF 只差 `/CreationDate`（含控制組）；FINDINGS 的每個舊句都被腳本從舊 summary 逐字重建出來（31 處取代／插入，全部 count==1）；兩讀法判決逐項相同；5 格紅（`088c82a0`）；閘門結果（R2.4）。
**INFERRED**：快照對多出的 ~1 s 沒有流量（依程序）；「最後一個爬梯快照之後」的樣本主要來自再確認 rep（未分開歸屬）；PDF 的差異是 matplotlib 寫入的時間戳（由位置與控制組推得，沒讀 matplotlib 原始碼）。

## R2.8 Dissent（本輪）

1. **fig1／fig2 的 PDF 不是字面上的 byte-identical**（R2.0）。我判斷那是工單意圖之外的時間戳、沒有停；若 orchestrator 要字面相同，本項 BLOCKED 待裁。
2. **FINDINGS 引用的新 summary 在 `scratch/` 裡**（`summary.115737Z.fix-68735150.json`），不在 audit-raw；公開的 FINDINGS 指向一個 repo 外的路徑。建議 orchestrator 把它（與 `OUT/` 其餘成品）收進 audit-raw，再把 §4.0 的指標改成那個位置——那需要動 audit-raw，不是我的範圍。
3. **預設 fixture 仍沒有確認列**（第一輪 Dissent 3 照舊）；M-E55 讓那格有了行為變異，但 101 格舊測試仍跑在沒有 c 列的樹上。
4. 圖上多了 `rung window: climb` 四個字。CLAUDE.md 要圖上少字；我認為讀法名是讀圖必需（沒有它，圖與 FINDINGS 的哪個讀法對不上），但「誰裁定」沒放上去。

**[Co-developed with claude code -- Adam]**
