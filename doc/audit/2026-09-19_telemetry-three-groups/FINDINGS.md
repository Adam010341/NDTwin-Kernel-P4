# FINDINGS — 三組遙測同 fabric 量測（無遙測／合作式 A／鏈路式 B）

> 數字由腳本從 `raw/2026-09-19T115737Z_full/summary.json` 抽出（不是轉抄）。**§3 取樣誤差與 §4 CPU 的假設標籤刻意留空**——等 E 第十輪把 PREREG 註冊層級的判決做出來（裁決 38）；其餘空格都在 §3／§4，同一個原因。
> 設計正本＝`PREREG.md`（＋AMENDMENT-1），**區間與判準在資料之前就註冊完了，這裡只填數字與敘述**。
> 填表的人：先跑 `analyse.py --raw <run>` 拿 `summary.json`，**每一格都從它抄，不要從別的地方抄**。
> 儀器：`drive_e.sh`（driver）、`run_group_arm.sh`（梯子臂）、`sample_error.sh`（取樣誤差視窗）、
> `cpu_arm_probe.py`（CPU）、`analyse.py`（分析）、`plot.py`（圖）。raw → `audit-raw`。

**[Co-developed with claude code -- Adam]**

---

## 0. 這一輪跑了什麼（填：日期、時刻、誰跑的、binary）

| | |
|---|---|
| 日期／時間 | 2026-09-19 11:57:37Z 起（run id `2026-09-19T115737Z_full`），六世代連續跑完 |
| 誰跑的 | orchestrator（本 session），機器全空、無閘門並行 |
| fabric | `ndt up p4 4 --telemetry {none|cooperative|link}`，10 台 bmv2、4 主機、NDTwin pipeline |
| 路徑 | h1(s1:3) → h4(s4:3)；**實際量到的 on-path 介面集合**＝`s1-eth2`／`s6-eth4`／`s8-eth2`／`s10-eth4`（4 條，等於 PREREG 5.2 註冊的數目；fabric 共 32 條 inter-switch 埠） |
| kernel binary | sha256 `be70b5dd3235684786dc074b79ec43ad285757af4661459e993b204d1833cb49`（`be70b5dd3235`），12 臂同一顆（`binaries` 只有一個值） |
| bmv2 binary | `/usr/local/bmv2-fast/bin/simple_switch_grpc`、sha256 前綴 `be70b5dd3235`、`EventLogger=0`（fast 簽章，雙向斷言過） |
| pipeline | `ndtwin_switch.json` sha256 `0b19d789d74fc9963861a20ea168e72d99390841bc592a04c4b2881fddb29743`，12 臂同一份（`SAMPLE_RATE=256` 編在裡面） |
| 世代／臂 | 6 世代、12 梯子臂、27 個取樣誤差視窗、3 個控制 |
| 作廢／重跑 | 無（本輪 12 臂全部產出讀數；`invalid_arms` 為空） |

---

## 1. 控制（先報，因為它們決定上面那些數字能不能說）

| 控制 | 量到 | 判準 | 結果 |
|---|---|---|---|
| C1 產生器上限（64 B frame，h1→h1 loopback，不經 bmv2，3 rep） | 733469.6 pps（3 rep：733469.6 690606.7 731634.2） | ≥ 5× 本輪 64 B 經 bmv2 的最高 pps（＝150000 pps） | **PASS** |
| C2 產生器上限（1024 B frame） | 727636.4 pps（3 rep：727636.4 669448.4 612424.2） | ≥ 5× 本輪 1024 B 的最高 pps（＝150000 pps） | **PASS** |
| C3 外部 CPU 閘的陽性對照 | `external` 0.1066 → 0.2805 | 差 > 0.15 絕對值 | **FIRES** |

🔴 C1／C2 任一 FAIL ⇒ **該 frame 尺寸只報「產生器受限」**，不得對該尺寸的 bmv2 pps 說任何話（PREREG 7）。
🔴 C3 不觸發 ⇒ 閘門 unvalidated，本輪不開跑（PREREG 6.3）。

### 1.1 遙測在／不在，逐臂證明過（PREREG 2.1、AMENDMENT-1 A1.2）

| 組 | 每臂 `addressed_total` 增量 | twin 非零讀數（取樣誤差視窗） | 斷言 |
|---|---|---|---|
| `none` | 0（4 臂全 0） | 0（三個速率都 0） | **PASS**（`invalid_arms` 空） |
| `cooperative` | 41,208–69,674／臂（4 臂合計 226,267） | 168／384／384（2／20／100 Mbit/s） | **PASS**（`invalid_arms` 空） |
| `link` | 66,215–104,214／臂（4 臂合計 329,003） | 198／388／385（2／20／100 Mbit/s） | **PASS**（`invalid_arms` 空） |

`samples_by_family` 增量（ARP／LLDP 的貢獻**看得見**，不是被假設掉）：
`none` ipv4 0／ipv6 0／l2 0／undecodable 0；`cooperative` ipv4 226,267／ipv6 0／l2 0／undecodable 0；`link` ipv4 328,998／ipv6 0／l2 5／undecodable 0（4 臂合計）；`malformed_ipv4_ihl`＝**0**（本 run 397 份 sflow 快照全為 0）。

### 1.2 負載閘（組內比，PREREG 6.2）

| 臂 | 組 | `external` | 該組中位數 | softirq | 觸發？ |
|---|---|---|---|---|---|
| `cooperative_f1024_a` | `cooperative` | 0.0532 | 0.0417 | 0.0075 | 否 |
| `cooperative_f64_a` | `cooperative` | 0.1249 | 0.0417 | 0.0075 | 否 |
| `cooperative_f1024_b` | `cooperative` | 0.0207 | 0.0417 | 0.0099 | 否 |
| `cooperative_f64_b` | `cooperative` | 0.0302 | 0.0417 | 0.0088 | 否 |
| `link_f1024_a` | `link` | 0.1070 | 0.0793 | 0.0129 | 否 |
| `link_f64_a` | `link` | 0.0797 | 0.0793 | 0.0091 | 否 |
| `link_f1024_b` | `link` | 0.0789 | 0.0793 | 0.0113 | 否 |
| `link_f64_b` | `link` | 0.0415 | 0.0793 | 0.0085 | 否 |
| `none_f1024_a` | `none` | 0.0560 | 0.0560 | 0.0106 | 否 |
| `none_f64_a` | `none` | 0.0149 | 0.0560 | 0.0083 | 否 |
| `none_f1024_b` | `none` | 0.0707 | 0.0560 | 0.0105 | 否 |

🔴 **組間的 `external` 與 softirq 差是量測，不是閘門**——`tc action sample` 的成本在 softirq 脈絡、
歸屬不到任何 pid。逐組（4 臂各自的 `softirq_share`，中位數）：`none` 0.0105、`cooperative` 0.0082、`link` 0.0102。

---

## 2. 一、pps 天花板

**圖：`fig1_pps_ceiling.png` / `.pdf`。**

| 組 | 64 B 臂 a／b | 64 B 格值 | 1024 B 臂 a／b | 1024 B 格值 |
|---|---|---|---|---|
| `none` | 30.0 / 30.0 | 30.0 | 30.0 / 30.0 | 30.0 |
| `cooperative` | 12.0 / 30.0 | 21.0* | 12.0 / 30.0 | 21.0* |
| `link` | 12.0 / 20.0 | 16.0 | 12.0 / 20.0 | 16.0 |

⚠️ 格值＝兩臂平均；**引用格值時要帶臂值**（08-30 對 08-28 的更正：16.0/20.0/16.0 那三個格值
沒有任何一臂讀到）。兩臂差超過一階 ⇒ 該格**不算比值**（H-A0）。

### 註冊的比較（PREREG 5.1，區間在資料之前）

| 比較 | 量到 | H-A1 [0.60, 1.67] | 判定 |
|---|---|---|---|
| `cooperative`/`none` @64 B | **不算**（兩臂差 2 階） | 落在區間內＝H-A1 | **H-A0 unresolved** |
| `cooperative`/`none` @1024 B | **不算**（兩臂差 2 階） | 落在區間內＝H-A1 | **H-A0 unresolved** |
| `link`/`none` @64 B | 0.533 | 落在區間內＝H-A1 | **H-A2 telemetry costs data-plane pps** |
| `link`/`none` @1024 B | 0.533 | 落在區間內＝H-A1 | **H-A2 telemetry costs data-plane pps** |

**這代表什麼**（PREREG 9 的表）：`link` 兩格 H-A2 ⇒ **tc 取樣在資料面收費**，B 路要標一個吞吐量代價（本 fabric：30.0 → 16.0 kpps，比值 0.533），並與 §4 的 softirq 量測互證；`cooperative` 兩格 H-A0 ⇒ **一階內不可分辨**，只報兩臂值 12.0／30.0、不報比值，更細的梯子是另一輪的事。沒有任何一格落到 H-A3，所以「儀器嫌疑」那條這輪用不到。

**方向性預期有沒有成真**（PREREG 5.1 末：若有任何一組低於 `none`，更可能是 `link`）：**與觀測一致但只驗到一半**——低於 `none` 的是 `link`（16.0 vs 30.0，64 B 與 1024 B 兩格都是）；`cooperative` 兩格因臂差 2 階判不出是否低於 `none`，所以「更可能是 link 而不是 cooperative」這句本輪只能說前半。

---

## 3. 二、取樣誤差

本節的 H-B 判決是**組級**的（裁決 38／40）：H-B1／H-B4 對一組的三個速率判一次、H-B2 只在 100 Mbit/s 判且要三個視窗同號；逐格只留「在帶內／帶上／帶下」的描述當資料。數字由腳本從 `summary.json` 的 `sampling_error` 與 `sampling_error_by_group`／`sampling_error_cross_group_registered` 抽出。

**圖：`fig2_sampling_error.png` / `.pdf`。**

| 組 | 2 Mbit/s | 20 Mbit/s | 100 Mbit/s |
|---|---|---|---|
| `none` | **n/a** | **n/a** | **n/a** |
| `cooperative` median abs err | 0.2953 | 0.0274 | 0.0154 |
| `cooperative` 帶號中位數 | -0.2953 | +0.0274 | +0.0154 |
| `link` median abs err | 0.0746 | 0.0344 | 0.0229 |
| `link` 帶號中位數 | +0.0746 | +0.0119 | -0.0131 |
| shot-noise 預測 0.674/sqrt(N) | 0.143 | 0.045 | 0.020 |
| 量到的 N（每視窗樣本數 4×pps×8/256，邊數＝twin 讀到非零的邊） | 22.3（4 條邊） | coop 223.2（4 條邊）／link 279.0（5 條邊） | coop 1116.1（4 條邊）／link 1395.1（5 條邊） |

🔴 **`none` 是 n/a 不是 0**：它沒有 twin 讀數，寫 0 會把「沒有讀數」變成「誤差為零」。

| 假設 | 判定 |
|---|---|
| H-B1 shot-noise 主導（三個速率都落在 [0.5, 2.0]×預測） | `cooperative` **不成立**：2 M 上（0.2953，帶 [0.0713, 0.2853]）、20 M 內（0.0274，帶 [0.0226, 0.0902]）、100 M 內（0.0154，帶 [0.0101, 0.0404]）；`link` **成立**：2 M 內（0.0746，帶 [0.0713, 0.2853]）、20 M 內（0.0344，帶 [0.0202, 0.0807]）、100 M 內（0.0229，帶 [0.0090, 0.0361]） |
| H-B2 系統性偏差（100 Mbit/s 那格大於 2×預測且三個視窗同號） | `cooperative` **不成立**（100 M 在帶內，3 個視窗同號）；`link` **不成立**（100 M 在帶內，3 個視窗不同號） |
| H-B3 `link` 的樣本掉了（E(link)/E(coop) > 2 且 emitter 計數 > 0） | **不可寫**：沒有任何速率 link/coop > 2（2 M 0.253、20 M 1.255、100 M 1.489）；emitter `dropped_*`＋`enobufs`＝0 |
| H-B4 兩條路一樣準（三個速率的 link/coop 都落在 [0.5, 2.0]） | **不成立**：2 M 0.253（外）、20 M 1.255（內）、100 M 1.489（內） |


🔴 **`cooperative` 的結局「neither H-B1 nor H-B2 holds as registered」是 PREREG 沒有註冊的分支**（裁決 40②）：H-B1 不成立、H-B2 不成立，PREREG 5.2 與 §9 的結局表都沒有這一支 ⇒ 報數字、不貼標籤、不套用結局表的任何動作；登記為 PREREG 缺口（§6）。
🔴 **`link` 20 M／100 M 的帶用 N＝5 條邊算**（第一個視窗讀到 5 條、另兩個 4 條，`sampling_summary` 取 `members[0]`；裁決 40⑧）：改用註冊的 4 條邊算帶，兩格同樣在帶內，判決不變。

🔴 **計數器是 0 就不准寫「樣本掉了」**——那是 ROLE-5 的錯誤形狀（把沒觀測到的機制寫進判決）。
emitter 統計行（梯子臂 `emitter.log` 加總）：`samples=510829 emitted=510829 dropped_*=0 enobufs=0`。

⚠️ `ndt check` 的 `ok` 帶是 0.5–1.5，**那不是準確度陳述**（它是 double-count 的絆線）。
本節報的是準確度，兩者不可混用。

---

## 4. 三、CPU

### 4.0 🔴 勘誤（2026-09-24）：逐階 CPU 視窗吞進了更高階

**錯在哪。** `analyse.py` 的 `rung_windows`（`:693-703`；本段行號皆為勘誤前的 `30aa500c`）把 `rungs.tsv` 裡同一個 kpps 的所有列聯集成**一個** (min t_start, max t_end) 視窗。梯頂再確認的三個 rep（`c1`–`c3`，`run_group_arm.sh:420-440`）以同一個 kpps 記在**整個爬梯之後**，所以被確認那一階的視窗從爬梯第一個 rep 一路包到確認最後一個 rep、中間更高的階全在裡面（例：`G4/link_f64_b` 的 20 kpps 視窗 110.0 s，包住 30–110 kpps）。兩個消費者都錯在那一階：逐階 CPU（`cpu_by_rung`，`:739-740`）與 S(k)（`rung_samples_per_second`，`:708`——分子只有爬梯的樣本、分母是整段）。本節 1024 B 受影響的格：coop 12／30、link 12／20、none 30 kpps。第四次 campaign 的 raw 同形狀。

**誰、何時。** 2026-09-24 由 P4 worker P 發現；orchestrator、worker C（離線重驗）與判官（opus，HOLDS WITH CORRECTIONS）各自驗證。修正後每一階的視窗＝它自己的 rep，S(k) 只用爬梯（PREREG A1.5 `:505-507`）。

**讀法——Adam 裁定，不是 PREREG 註冊的。** 梯頂再確認的 rep 算不算該階的 CPU，PREREG 沒有決定（§4.1 `:161-162` 只說再確認是梯子程序的一部分）。本文的主讀法＝**climb（只算爬升的 rep）**，由 **Adam 2026-09-24, TICKET-P4 §7 ruling 4** 裁定、**非 PREREG 註冊**。記錄的理由：§5.3（`:263-266`）把 CPU(k) 與 S(k) 配成同一個擬合，而 S(k) 只涵蓋爬升（`:505-507`）⇒ 兩邊同一個窗；本輪沿用的 08-28 規則（`2026-08-28_flow-count-capacity/PREREG.md:254-255`）把首讀與再確認分開記，“so a disagreement between them is visible rather than overwritten”。另一讀法（climb＋再確認 rep）照算、並列在 `summary.json` 的 `cpu_window`；**兩種讀法在第五次 campaign 的判決逐項相同**（H-C ×2、對帳 (b) ×2、bmv2 逐階 ×11），但數字不全同（例：bmv2 30 kpps 比值 1.206 vs 1.235）。

**判決。** H-C（兩組）與對帳 (b) **不變**；**註冊的 bmv2 逐階判決有 2／11 翻轉**（12 kpps 由帶外翻帶內（1.513→1.006）、30 kpps 由帶內翻帶外（1.099→1.206）），帶外總數仍 2／11。`cooperative` 仍是 H-C1，但它的固定份額現在是 0.0257——H-C1 成立的依據**只有** m 落帶（裁決 40④）。

**舊值不刪。** 下表每一列＝一個被這次勘誤改動的數（舊＝勘誤前公開的值，新＝climb 讀法）；本節其餘的數字與 §1–§3、§5(a)(c) 都沒有變（summary.json 逐葉對帳：1560 個葉值相同、99 個變，全在 `cpu_kernel`／`cpu_bmv2`／`cpu_bmv2_ratio`／對帳 (b)）。

| 出處 | 量 | 舊（勘誤前） | 新（climb） |
|---|---|---|---|
| §4 表 12 kpps | 量到的 samples/s（coop） | 132.0 | 215.7 |
| §4 表 12 kpps | Δkernel(coop−none) | +4.149 | +2.921 |
| §4 表 12 kpps | Δkernel(link−none) | +3.131 | +2.286 |
| §4 表 12 kpps | 散佈 coop | 2.612 | 0.157 |
| §4 表 12 kpps | 散佈 link | 1.157 | 0.533 |
| §4 表 20 kpps | Δkernel(link−none) | +4.538 | +3.481 |
| §4 表 20 kpps | 散佈 link | 3.164 | 1.050 |
| §4 表 30 kpps | 量到的 samples/s（coop） | 367.0 | 550.6 |
| §4 表 30 kpps | Δkernel(coop−none) | +7.836 | +7.119 |
| §4 表 30 kpps | Δkernel(link−none) | +5.281 | +5.327 |
| §4 表 30 kpps | 散佈 coop | 0.895 | 2.422 |
| §4 分解 `cooperative` | F（% of one core） | 0.9234 | 0.3212 |
| §4 分解 `cooperative` | m（µs/sample） | 122.89 | 126.19 |
| §4 分解 `cooperative` | 固定份額（＝H-C2 條件一的 share） | 0.0722 | 0.0257 |
| §4 分解 `cooperative` | 判定 | H-C1 cost is dominated by a fixed component (08-20 reproduces) | **不變** |
| §4 分解 `cooperative` | Δ比 / S比（1 與 110 kpps） | 20.297 / 51.802 | **不變** |
| §4 分解 `link` | F（% of one core） | 0.7692 | 0.2492 |
| §4 分解 `link` | m（µs/sample） | 79.00 | 82.41 |
| §4 分解 `link` | 固定份額（＝H-C2 條件一的 share） | 0.0623 | 0.0202 |
| §4 分解 `link` | 判定 | not decided: H-C2 condition 1 holds (share <= 0.2); condition 2 (delta ratio ~ S ratio) has no registered tolerance | **不變** |
| §4 分解 `link` | Δ比 / S比（1 與 110 kpps） | 31.505 / 58.680 | **不變** |
| §4 bmv2 coop/none | 12 kpps | 1.513（帶外） | 1.006（帶內）——**註冊的逐階判決翻轉** |
| §4 bmv2 coop/none | 30 kpps | 1.099（帶內） | 1.206（帶外）——**註冊的逐階判決翻轉** |
| §4 bmv2 coop/none | 帶外的階 | 12、45（2／11） | 30、45（2／11） |
| §5 (b) `cooperative` | m / 固定份額 | 122.9 / 0.072 | 126.2 / 0.026 |
| §5 (b) `cooperative` | 判定 | 一致 | **不變** |
| §5 (b) `link` | m / 固定份額 | 79.0 / 0.062 | 82.4 / 0.020 |
| §5 (b) `link` | 判定 | 落外 | **不變** |
| fig3 | 三個面板在 12／20／30 kpps 的點 | `c1f4174f` 的圖 | 重生，標題寫明 `rung window: climb` |

勘誤後的數字取自 `summary.115737Z.fix-68735150.json`（勘誤前的取自 `summary.115737Z.base-30aa500c.json`）。重驗的全部輸出（兩份 summary.json、逐葉對帳、不 import `analyse.py` 的第二套儀器、逐臂的再確認段 CPU）：`scratch/overnight-2026-09-05/logs/orchestrator-0924/cpu-window-recheck/`；報告 `scratch/overnight-2026-09-05/hunt-0911/fix/P4-C-SUMMARY.md`。

本節的 H-C 判決是**每個處理組一次**（PREREG 5.3 為 kernel 的擬合註冊 H-C1／H-C2／H-C3／H-C0，擬合用三組共同的每一階；bmv2 只註冊逐階比值 ∈ [0.90, 1.15]、不帶 H-C 標籤——第十輪任務 C 查證、裁決 40）。H-C2 的第二條件沒有註冊容差 ⇒ 本輪**不可判**（裁決 40③），不准事後挑容差。數字由腳本從 `cpu_kernel`／`cpu_bmv2_ratio`／`external_gate` 抽出（2026-09-24 起取自勘誤後的 summary.json；逐階視窗＝climb，Adam 裁定、非 PREREG 註冊；勘誤前的值在 §4.0）。

**圖：`fig3_cpu.png` / `.pdf`（bmv2／kernel／proxy+emitter 三個面板）。** 2026-09-24 以 climb 讀法重生（標題寫明 `rung window: climb`）；勘誤前的圖在 git 歷史 `c1f4174f`。

🔴 數字只取**梯子臂**：取樣誤差視窗自帶 4 Hz 的 `/ndt/get_graph_data` poll，而那個 HTTP 工作
就是被量 CPU 的 kernel 行程在服務（08-20 的 `POLL=off` 為此存在）。

| 階（offered kpps） | 量到的 samples/s | Δkernel(coop−none) | Δkernel(link−none) | 臂間散佈（兩世代原始 CPU 的全距；PREREG `:273` 註冊的是三窗 Δkernel 散佈——裁決 40⑤，本輪 11 階全解析、差異未改判決） | 解析得出？ |
|---|---|---|---|---|---|
| 1 | 19 | +0.667 | +0.400 | coop 0.133／link 0.400 | 是 |
| 2 | 39 | +1.067 | +0.704 | coop 0.133／link 0.375 | 是 |
| 3 | 59 | +1.333 | +1.133 | coop 0.133／link 0.800 | 是 |
| 5 | 97 | +1.400 | +1.333 | coop 0.133／link 0.133 | 是 |
| 8 | 153 | +2.251 | +1.831 | coop 0.164／link 0.706 | 是 |
| 12 | 216 | +2.921 | +2.286 | coop 0.157／link 0.533 | 是 |
| 20 | 359 | +4.444 | +3.481 | coop 0.485／link 1.050 | 是 |
| 30 | 551 | +7.119 | +5.327 | coop 2.422／link 1.741 | 是 |
| 45 | 824 | +10.398 | +8.132 | coop 0.268／link 1.334 | 是 |
| 70 | 948 | +11.764 | +10.331 | coop 0.868／link 3.066 | 是 |
| 110 | 965 | +13.530 | +12.598 | coop 0.133／link 4.668 | 是 |

### 分解（PREREG 5.3）

逐階視窗＝**climb**（Adam 2026-09-24 裁定、非 PREREG 註冊，§4.0）。

| 組 | F（% of one core） | m（us/sample） | 固定份額 F/(F+m·S_top) | 判定 |
|---|---|---|---|---|
| `cooperative` | 0.3212 | 126.19 | 0.0257 | H-C1 cost is dominated by a fixed component (08-20 reproduces)【🔴 標籤名說「固定成分主導」，但固定份額只有 0.0257——H-C1 在這裡成立的依據**只有** m＝126.19 落在 [103, 618]（裁決 40④）；固定份額那一條（≥ 0.5）不成立】（H-C2 條件一成立：share 0.026；條件二 Δ(高)/Δ(低) 20.297 vs S(高)/S(低) 51.802，PREREG 無註冊容差 ⇒ 不可判，裁決 40③） |
| `link` | 0.2492 | 82.41 | 0.0202 | not decided: H-C2 condition 1 holds (share <= 0.2); condition 2 (delta ratio ~ S ratio) has no registered tolerance（H-C2 條件一成立：share 0.020；條件二 Δ(高)/Δ(低) 31.505 vs S(高)/S(低) 58.680，PREREG 無註冊容差 ⇒ 不可判，裁決 40③） |

🔴 **判定欄怎麼讀**（裁決 40③④）：`cooperative` 的 H-C1 **只靠 m 落帶**（126.19 ∈ [103, 618]）；固定份額 0.0257 < 0.5 那一條不成立，而 H-C2 的條件一（≤ 0.2）反而成立。`link` 的註冊結局是**不可判**：m 82.41 落帶外、固定份額 0.0202 ⇒ 不是 H-C1；H-C2 的第二條件沒有註冊容差；不是 H-C3（H-C3＝介於兩者，link 的份額落在 H-C2 那一側）。兩組的 Δ 比與 S 比只當資料列出，沒有任何東西拿它們下判決。

**bmv2 CPU**（08-20 預測不動；PREREG 5.3 逐階註冊、沒有跨階彙總）：`bmv2(cooperative)/bmv2(none)` 逐階＝1 kpps 0.991、2 kpps 0.988、3 kpps 1.105、5 kpps 1.038、8 kpps 0.943、12 kpps 1.006、20 kpps 1.084、30 kpps 1.206、45 kpps 1.164、70 kpps 1.067、110 kpps 1.022；區間 [0.90, 1.15] ⇒ **9 階一致、2 階不一致**（落外的階：30 kpps 1.206、45 kpps 1.164）。逐階視窗＝climb（Adam 2026-09-24 裁定、非 PREREG 註冊）；勘誤翻了 2 個註冊的逐階判決：12 kpps 由帶外翻帶內（1.513→1.006）、30 kpps 由帶內翻帶外（1.099→1.206），見 §4.0。

**softirq**（`link` 的資料面成本歸屬不到任何 pid；各組臂的 `softirq_share` 中位數）：`none` 0.0105／`cooperative` 0.0082／`link` 0.0102 ⇒ **沒有成真**（PREREG 5.3 只註冊「逐組報」與方向，沒有區間）。

---

## 5. 對帳（三條，條件與區間在 PREREG 8 註冊，**這裡只填數字與判定**）

### (a) pps 天花板 vs 08-28 的 1024 B ＝ 16.0 kpps

| 配對 | 本輪 | 舊的 | 比值 | 區間 [0.60, 1.67] | 判定 |
|---|---|---|---|---|---|
| `none`（工單指定的配對） | 30.0 kpps | 16.0 kpps | 1.875 | | **落外** |
| `cooperative`（**條件對齊**的配對） | 21.0 kpps | 16.0 kpps | 1.312 | | **一致** |

已知條件差異（四項，PREREG 8(a) 註冊）：①4 vs 128 台主機 ②4 條 switch–switch 邊／5 台交換機
vs 3 跳 ③kernel binary 不同 ④**08-28 的臂開著合作式取樣**。

落在區間外 ⇒ **不是推翻**：能扛的是 **④**——08-28 的 16.0 是**開著合作式取樣的臂**量的，所以它對得上的配對是本輪的 `cooperative`（1.312，區間內），
對不上 `none`（1.875）；①（4 vs 128 台主機，容量是流數的函數）與 ②（拓樸）方向不明、單獨扛不起 1.875，③（kernel binary）無法分離。
**只有同規格 fabric（128 台主機、3 跳、同一顆或指認過的 kernel）上各跑一臂 `none` 與一臂 `cooperative` 才能判定 `none` 的落外是遙測差還是規格差，而本輪沒有它。**
（`cooperative` 的 21.0 本身是 unresolved 格的兩臂平均——12.0／30.0，臂差 2 階——所以「一致」這一格的可信度受 §2 的 H-A0 限制。）

### (b) CPU vs 08-20「遙測成本固定、不是每樣本」

逐階視窗＝**climb**（Adam 2026-09-24 裁定、非 PREREG 註冊；勘誤前的值在 §4.0）。

| | 本輪 | 08-20 | 判準 | 判定 |
|---|---|---|---|---|
| m（us/sample）（cooperative） | 126.2 | 206 | 落在 [103, 618] | **一致** |
| 固定份額（cooperative） | 0.026 | 0.81 | 大於等於 0.5 | **不成立** |
| m（us/sample）（link） | 82.4 | 206 | 落在 [103, 618] | **落外** |
| 固定份額（link） | 0.020 | 0.81 | 大於等於 0.5 | **不成立** |

任一成立＝與「成本固定」一致。兩個都不成立 ⇒ **「固定成本的結論在 10 台 fabric／8 s 視窗上沒有重現」
是一個結果**——本輪它只落在 `link`（`cooperative` 的 m 落在區間內，所以 cooperative 與「成本固定」一致）。候選（INFERRED，未量）：① **視窗長度**（8 s vs 08-20 的長視窗）——短視窗把 emitter 的啟動成本攤進斜率，會把 m 壓低（本輪 82.4 < 103）；② **fabric 大小**（10 台、32 條交換機間埠）——`link` 的 psample 成本分散在多個 softirq 脈絡，「集中在單一執行緒」的固定份額（0.020）自然變小；③ **零點**——08-20 的零點是「零取樣但機制開著」，本輪的 `none` 是「機制關掉」，兩者對「固定成本」的定義不同。能判定的：同 fabric 把視窗拉到 30 s（若 m 進區間＝①）；同視窗換 4 台 fabric（若固定份額回到 ≥0.5＝②）；加一個「取樣率趨近 0 但 emitter 開著」的臂（釘住 ③）。三者都是另一輪。

比 `m` 不比 `F` 的理由（註冊過）：`m` 是邊際斜率該跨 fabric 轉移；`F` 跟圖的大小走，本來就不該轉移。

### (c) 12x / bmv2 build ratio — **本輪不宣稱任何新的比值**

| 來源 | 數字 | 條件 |
|---|---|---|
| 08-15 | fast 300 Mbit/s | 三跳、1400 B |
| 1b（08-28） | fast 360 Mbit/s | 單跳、1400 B、control plane live |
| 2（08-28） | fast 16.0 kpps ＝ 131.1 Mbit/s（frame） | 三跳、1024 B frame、128 台、合作式取樣開著 |
| 本輪 | 30.0 kpps ＝ 245.8 Mbit/s（frame） | 4 條 switch–switch 邊、1024 B frame、4 台主機、**無遙測** |

🔴 **這張表任何一格不得除以另一格**；本輪沒有 stock 臂，不得出現任何含 stock 的比值。

---

## 6. 威脅到有效性的東西（先列已知的，跑完再補真的）

1. **每組只有兩個 fabric 世代**，取樣誤差只在一個世代量 ⇒ 世代效應與組效應分離到兩個樣本的程度（PREREG 4.1／4.2）。
2. **格值解析度是 ±1 階**（實現步距 1.667x），比一個不到一階的真實效應，本輪排除不了。
3. **單機、單流、單路徑類別、單一 pipeline、單一取樣率**。掃的是遙測來源這一軸，其它都沒有。
4. `external` 的殘差含取樣器自己的成本（每臂同一個 2 Hz 迴圈，是常數位移，而閘門是相對的）。
5. **`link` 的資料面成本歸屬不到 pid**（softirq），所以組間 `external` 只當量測不當閘門。
6. 🔴 **取樣誤差的 N 數來自「twin 自己讀到非零的邊」,而 twin 正是被評量的儀器**(裁決 35①／37⑧a)。
   少看一條邊 ⇒ N 變小 ⇒ 預測區間變寬 ⇒ **更容易判成 H-B1**,**失效方向對我們的結論有利**。
   第五次 campaign（本輪）的實際分佈（`scan-39-8-onpath-edges-115737Z.p3e-bc1db4c0.log`）：27 個視窗中 **16 個讀到 4 條、2 個讀到 5 條、9 個 `none` 讀到 0 條**；讀到 5 條的是 `link` 20 M 與 100 M 各自的第一個視窗（三窗 [5, 4, 4]），而 `sampling_summary` 取 `members[0]` 的 N ⇒ 這兩格的預測帶用 N=5 算（裁決 37⑧a 的候選在本輪真的發作）；改用註冊的 4 條邊算帶，兩格同樣在帶內，判決不變。第四次 campaign 是 **18 個 treated 讀到 4 條、9 個 `none` 讀到 0 條**
   (退回 PREREG 5.2 註冊的 4)。本輪沒有一格因此改變,但這個方向性必須寫著。
7. 🔴 **H-B1／H-B2／H-B4 是「組級」註冊的判準，分析在第十輪之前逐格貼標籤**（裁決 38；第十輪 `bc1db4c0` 起逐格只留描述、組級判決另算）。
   PREREG `:251` 的 H-B1 與 `:254` 的 H-B4 註冊的是「三個速率**都**落在區間」，`:252` 的 H-B2 只註冊在 **100 Mbit/s 那一格**且要三視窗同號。
   ⇒ 本文件只引用組級判決（§3）。在第五次 campaign 上這不是形式差異：兩個逐格 H-B1（coop 20 M、100 M）與兩個逐速率 H-B4（20 M、100 M）在組級都不成立（裁決 40①）。
   `cooperative` 的「H-B1、H-B2 皆不成立」是 PREREG **沒有註冊的結局**——報數字、不貼標籤（裁決 40②）；H-C2 的第二條件沒有註冊容差，本輪不可判（裁決 40③）；
   H-C0 的散佈量、`S_top`、H-A2 的跨 frame／跨遍條件、H-B3 的「該視窗」計數來源，碼與 PREREG 的措辭都有落差，本輪判決都不受影響（裁決 40⑤⑥⑧）。
8. **pps 天花板的估計量在 20–30 kpps 沒有解析度**(裁決 34)。
   判準是「3 rep 的 loss 中位數 ≤ 0.5%」,而系統在 30 kpps 的 loss 中位數落在 0.1–0.9%,
   **門檻穿過那條帶子**:同一臂同一階 20 kpps 獨立量兩次得到 0.2532%(過)與 0.5276%(不過)。
   ⇒ 可說「遙測在拐點附近增加變異」,**不可說**「遙測把天花板壓低 N 倍」,
   也不可把 `link` 的 16.0 當成組效應報出去——同一個 `link` 臂在參考跑(105759Z)是 30。
9. **負載閘(組內中位數 +0.15)對「整組一起被抬高」零鑑別力**,它只看得見組內異常值。
10. **`cpu.jsonl` 的樣本列不在結構對帳範圍內**(裁決 37⑥a):`inventory.py` 的基數比對
    只讀 `.jsonl` 第一行,所以每列 `proc` 裡的十個 bmv2 沒有被守住——
    一份「header 宣告十台、每列只寫一台」的 fixture 會完整通過那支對帳。
11. 🔴 **逐階 CPU 視窗的讀法不是 PREREG 註冊的**（§4.0）：PREREG 沒說梯頂再確認的 rep 算不算該階；本文用 climb（Adam 2026-09-24 裁定）。另一讀法的數字在 `summary.json` 的 `cpu_window`——第五次兩讀法判決逐項相同，但數字不全同（bmv2 30 kpps 比值 1.206 vs 1.235、link 20 kpps 散佈 1.050 vs 1.148）。

---

## 7. 這一輪**不能**宣稱的東西（PREREG 10，原樣重列）

1. 任何關於「外來 pipeline ＋ include `ndtwin_telemetry.p4`」的成本或準確度——本輪的 `cooperative`
   是 NDTwin 自己的 pipeline；TICKET-P3 9 裁定 7 新增的那一格是 live 清單的事。
2. 任何 stock build 的比值。
3. 其它 fabric 大小／主機數／路徑長度／取樣率的推論。
4. 「遙測完全不要錢」——殘差只在門檻之上被看見。
5. 一個精確的 pps 數字。
6. `none` 組的取樣誤差是 0。

---

## 8. 支持什麼／不支持什麼

| 支持 | 不支持 |
|---|---|
| C1／C2 產生器天花板 733,469.6／727,636.4 pps ≥ 5×150,000 ⇒ 天花板數字不是產生器的；C3 陽性對照 FIRES ⇒ 外部 CPU 閘會動；`link` 在 64 B 與 1024 B 都把 pps 天花板從 30.0 壓到 16.0 kpps（H-A2）；對帳 (b) `cooperative` 的 m＝126.2 µs/sample 落在 [103,618]（climb 讀法）；對帳 (c) 四列並排、無一格除以另一格 | `cooperative` 的天花板比值（H-A0，臂差 2 階，不報比值）；六格 H-B 取樣誤差判決與 H-C 標籤（**等第十輪的 PREREG 註冊層級判決，此處不引用逐格標籤**）；對帳 (a) `none` 30.0 vs 舊 16.0 落外 ⇒ 舊的 pps 天花板數字不能直接沿用到本 fabric；對帳 (b) `link` 的 m＝82.4 落外且固定份額 0.020（climb 讀法） ⇒「成本固定」在 link 路沒有重現（§5 候選） |

**[Co-developed with claude code -- Adam]**
