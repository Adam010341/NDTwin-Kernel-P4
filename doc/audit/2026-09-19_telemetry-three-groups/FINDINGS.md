# FINDINGS — 三組遙測同 fabric 量測（無遙測／合作式 A／鏈路式 B）

> 🔴 **骨架，尚未有任何數字。** 本輪還沒跑過一臂；所有 `<>` 是待填。
> 設計正本＝`PREREG.md`（＋AMENDMENT-1），**區間與判準在資料之前就註冊完了，這裡只填數字與敘述**。
> 填表的人：先跑 `analyse.py --raw <run>` 拿 `summary.json`，**每一格都從它抄，不要從別的地方抄**。
> 儀器：`drive_e.sh`（driver）、`run_group_arm.sh`（梯子臂）、`sample_error.sh`（取樣誤差視窗）、
> `cpu_arm_probe.py`（CPU）、`analyse.py`（分析）、`plot.py`（圖）。raw → `audit-raw`。

**[Co-developed with claude code -- Adam]**

---

## 0. 這一輪跑了什麼（填：日期、時刻、誰跑的、binary）

| | |
|---|---|
| 日期／時間 | `<UTC 起迄>` |
| 誰跑的 | `<orchestrator>` |
| fabric | `ndt up p4 4 --telemetry {none|cooperative|link}`，10 台 bmv2、4 主機、NDTwin pipeline |
| 路徑 | h1(s1:3) → h4(s4:3)；**實際量到的 on-path 介面集合**＝`<列出來>` |
| kernel binary | sha256 `<full>`（`<前 8 碼>`），每一臂頭尾相同 |
| bmv2 binary | `<路徑>`、sha256 `<...>`、`EventLogger=0`（fast 簽章，雙向斷言過） |
| pipeline | `ndtwin_switch.json` sha256 `<...>`（`SAMPLE_RATE=256` 編在裡面） |
| 世代／臂 | 6 世代、12 梯子臂、27 個取樣誤差視窗、3 個控制 |
| 作廢／重跑 | `<哪一臂、觸發 PREREG 7 哪一條、兩次的值都留著>`；沒有就寫「無」 |

---

## 1. 控制（先報，因為它們決定上面那些數字能不能說）

| 控制 | 量到 | 判準 | 結果 |
|---|---|---|---|
| C1 產生器上限（64 B frame，h1→h1 loopback，不經 bmv2，3 rep） | `<pps>` | ≥ 5× 本輪 64 B 經 bmv2 的最高 pps（＝`<pps>`） | `<PASS / FAIL>` |
| C2 產生器上限（1024 B frame） | `<pps>` | ≥ 5× 本輪 1024 B 的最高 pps（＝`<pps>`） | `<PASS / FAIL>` |
| C3 外部 CPU 閘的陽性對照 | `external` `<無 burner>` → `<有 burner>` | 差 > 0.15 絕對值 | `<FIRES / DID NOT FIRE>` |

🔴 C1／C2 任一 FAIL ⇒ **該 frame 尺寸只報「產生器受限」**，不得對該尺寸的 bmv2 pps 說任何話（PREREG 7）。
🔴 C3 不觸發 ⇒ 閘門 unvalidated，本輪不開跑（PREREG 6.3）。

### 1.1 遙測在／不在，逐臂證明過（PREREG 2.1、AMENDMENT-1 A1.2）

| 組 | 每臂 `addressed_total` 增量 | twin 非零讀數（取樣誤差視窗） | 斷言 |
|---|---|---|---|
| `none` | `<必須 0>` | `<必須 0>` | `<PASS / 作廢>` |
| `cooperative` | `<大於 0>` | `<大於 0>` | `<PASS / 作廢>` |
| `link` | `<大於 0>` | `<大於 0>` | `<PASS / 作廢>` |

`samples_by_family` 增量（ARP／LLDP 的貢獻**看得見**，不是被假設掉）：
`<ipv4 / ipv6 / l2 / undecodable 逐組>`；`malformed_ipv4_ihl`＝`<>`。

### 1.2 負載閘（組內比，PREREG 6.2）

| 臂 | 組 | `external` | 該組中位數 | softirq | 觸發？ |
|---|---|---|---|---|---|
| `<...>` | | | | | |

🔴 **組間的 `external` 與 softirq 差是量測，不是閘門**——`tc action sample` 的成本在 softirq 脈絡、
歸屬不到任何 pid。逐組：`<none / cooperative / link 的 softirq 份額>`。

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

**這代表什麼**：`<照 PREREG 9 的表填；H-A3 先當儀器嫌疑不當發現>`

**方向性預期有沒有成真**（PREREG 5.1 末：若有任何一組低於 `none`，更可能是 `link`）：`<>`

---

## 3. 二、取樣誤差

🔴 **本節的 H-B 判決暫不填寫,依裁決 35⑥ 與 38。** 數字(圖 `fig2_sampling_error.png`)與
逐格描述可以看,但**註冊過的 H-B 標籤要在 PREREG 註冊它的層級才算數**:
H-B1／H-B4 對「一組的三個速率」判一次、H-B2 只在 100 Mbit/s 那格判且帶同號條件,
而 `analyse.py` 目前是逐格貼(`:432`／`:435`／`:459`,整支碼沒有組級彙總)。
⇒ 組級判決做出來之前,這一節填任何 H-B 標籤都會是「PREREG 沒有註冊過的結論」。
**擋住的是標籤,不是數字**:圖、`median|err|`、預測值與 `links_used`/`keys_total` 都已就緒。


**圖：`fig2_sampling_error.png` / `.pdf`。**

| 組 | 2 Mbit/s | 20 Mbit/s | 100 Mbit/s |
|---|---|---|---|
| `none` | **n/a** | **n/a** | **n/a** |
| `cooperative` median abs err | `<>` | `<>` | `<>` |
| `cooperative` 帶號中位數 | `<>` | `<>` | `<>` |
| `link` median abs err | `<>` | `<>` | `<>` |
| `link` 帶號中位數 | `<>` | `<>` | `<>` |
| shot-noise 預測 0.674/sqrt(N) | 0.143 | 0.045 | 0.020 |
| 量到的 N（`addressed_total` 增量） | `<>` | `<>` | `<>` |

🔴 **`none` 是 n/a 不是 0**：它沒有 twin 讀數，寫 0 會把「沒有讀數」變成「誤差為零」。

| 假設 | 判定 |
|---|---|
| H-B1 shot-noise 主導（落在 [0.5, 2.0]×預測） | `<>` |
| H-B2 系統性偏差（大於 2×預測且三個視窗同號） | `<>` |
| H-B3 `link` 的樣本掉了 | `<只有在 emitter 的 dropped_*／enobufs 大於 0 時才能寫；計數值：<>>` |
| H-B4 兩條路一樣準（link/coop 落在 [0.5, 2.0]） | `<>` |

🔴 **計數器是 0 就不准寫「樣本掉了」**——那是 ROLE-5 的錯誤形狀（把沒觀測到的機制寫進判決）。
emitter 統計行（每臂的 `emitter.log`）：`samples=<> emitted=<> dropped_*=<> enobufs=<>`。

⚠️ `ndt check` 的 `ok` 帶是 0.5–1.5，**那不是準確度陳述**（它是 double-count 的絆線）。
本節報的是準確度，兩者不可混用。

---

## 4. 三、CPU

**圖：`fig3_cpu.png` / `.pdf`（bmv2／kernel／proxy+emitter 三個面板）。**

🔴 數字只取**梯子臂**：取樣誤差視窗自帶 4 Hz 的 `/ndt/get_graph_data` poll，而那個 HTTP 工作
就是被量 CPU 的 kernel 行程在服務（08-20 的 `POLL=off` 為此存在）。

| 階（offered kpps） | 量到的 samples/s | Δkernel(coop−none) | Δkernel(link−none) | 視窗間散佈 | 解析得出？ |
|---|---|---|---|---|---|
| `<>` | `<>` | `<>` | `<>` | `<>` | `<>` |

### 分解（PREREG 5.3）

| 組 | F（% of one core） | m（us/sample） | 固定份額 F/(F+m·S_top) | 判定 |
|---|---|---|---|---|
| `cooperative` | `<>` | `<>` | `<>` | `<H-C1 / H-C2 / H-C3 / H-C0>` |
| `link` | `<>` | `<>` | `<>` | `<>` |

**bmv2 CPU**（08-20 預測不動）：`bmv2(cooperative)/bmv2(none)` ＝ `<>`，區間 [0.90, 1.15] ⇒ `<一致／不一致>`。

**softirq**（`link` 的資料面成本歸屬不到任何 pid）：`<none / cooperative / link 的份額>` ⇒ `<預測成真／沒有>`。

---

## 5. 對帳（三條，條件與區間在 PREREG 8 註冊，**這裡只填數字與判定**）

### (a) pps 天花板 vs 08-28 的 1024 B ＝ 16.0 kpps

| 配對 | 本輪 | 舊的 | 比值 | 區間 [0.60, 1.67] | 判定 |
|---|---|---|---|---|---|
| `none`（工單指定的配對） | 30.0 kpps | 16.0 kpps | 1.875 | | **落外** |
| `cooperative`（**條件對齊**的配對） | 21.0 kpps | 16.0 kpps | 1.312 | | **一致** |

已知條件差異（四項，PREREG 8(a) 註冊）：①4 vs 128 台主機 ②4 條 switch–switch 邊／5 台交換機
vs 3 跳 ③kernel binary 不同 ④**08-28 的臂開著合作式取樣**。

落在區間外 ⇒ **不是推翻**：`<點名四項差異中哪一項能扛，並寫「只有同規格 fabric 的一臂能判定，
而本輪沒有它」>`

### (b) CPU vs 08-20「遙測成本固定、不是每樣本」

| | 本輪 | 08-20 | 判準 | 判定 |
|---|---|---|---|---|
| m（us/sample）（cooperative） | 122.9 | 206 | 落在 [103, 618] | **一致** |
| 固定份額（cooperative） | 0.072 | 0.81 | 大於等於 0.5 | **不成立** |
| m（us/sample）（link） | 79.0 | 206 | 落在 [103, 618] | **落外** |
| 固定份額（link） | 0.062 | 0.81 | 大於等於 0.5 | **不成立** |

任一成立＝與「成本固定」一致。兩個都不成立 ⇒ **「固定成本的結論在 10 台 fabric／8 s 視窗上沒有重現」
是一個結果**：`<點名三項差異（fabric 大小／視窗長度／零點）中的候選，以及什麼能判定>`。

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
   第四次 campaign 的實際分佈:27 個視窗中 **18 個 treated 讀到 4 條、9 個 `none` 讀到 0 條**
   (退回 PREREG 5.2 註冊的 4)。本輪沒有一格因此改變,但這個方向性必須寫著。
7. 🔴 **H-B1／H-B2／H-B4 是「組級」註冊的判準,而分析目前逐格貼標籤**(裁決 38)。
   PREREG `:251` 的 H-B1 與 `:254` 的 H-B4 註冊的是「三個速率**都**落在區間」,
   `:252` 的 H-B2 只註冊在 **100 Mbit/s 那一格**且要三視窗同號。
   ⇒ 逐格標籤**不是註冊過的結論**,本文件只引用組級判決(見 §3)。
8. **pps 天花板的估計量在 20–30 kpps 沒有解析度**(裁決 34)。
   判準是「3 rep 的 loss 中位數 ≤ 0.5%」,而系統在 30 kpps 的 loss 中位數落在 0.1–0.9%,
   **門檻穿過那條帶子**:同一臂同一階 20 kpps 獨立量兩次得到 0.2532%(過)與 0.5276%(不過)。
   ⇒ 可說「遙測在拐點附近增加變異」,**不可說**「遙測把天花板壓低 N 倍」,
   也不可把 `link` 的 16.0 當成組效應報出去——同一個 `link` 臂在參考跑(105759Z)是 30。
9. **負載閘(組內中位數 +0.15)對「整組一起被抬高」零鑑別力**,它只看得見組內異常值。
10. **`cpu.jsonl` 的樣本列不在結構對帳範圍內**(裁決 37⑥a):`inventory.py` 的基數比對
    只讀 `.jsonl` 第一行,所以每列 `proc` 裡的十個 bmv2 沒有被守住——
    一份「header 宣告十台、每列只寫一台」的 fixture 會完整通過那支對帳。

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
| `<>` | `<>` |

**[Co-developed with claude code -- Adam]**
