# 預註冊：128 台 × 並發流 × 兩平面 —— 規模下的遙測還準不準

寫於**開跑之前**、任何數字存在之前。作者 `8/25 mainDev`。
Adam 2026-08-25 直接授權（「開始跑大規模量測，p4 就直接開 fast」）。

## 0. 題目（只有這一個）

> **把 host 數放大 32 倍、把並發流放大 3–5 倍之後，twin 的 per-edge 遙測還對得上 ground truth 嗎？**

**不是**壓力測試（不找吞吐天花板）、**不是** TE 決策品質、**不是**找新缺陷。
是把 08-16 那份對帳表在規模下重跑一次，並讓**十台交換機全部有負載**。

## 1. 為什麼這一格是空的（對帳既有實驗）

照 [[check-against-prior-experiments]]，開跑前先寫清楚本輪與哪些舊結果的關係：

| 舊實驗 | 它做了什麼 | 本輪的關係 |
|---|---|---|
| `2026-08-16_concurrent-flow-reconciliation.md` | 並發 13–21 流、三路獨立取數 | **方法沿用**（量測側逐項照抄），但只有 **4 台 host** |
| `2026-08-20_sampling-rate-and-cpu` | 128 host、兩平面 | **單一 iperf3 流 h1→h33** ⇒ 同檔 §4：**十台 bmv2 只有三台有負載** |
| `2026-08-17_p4-vs-ovs-matched-topology` | 兩平面 matched | 規模與並發都不是它的題目 |
| `api-concurrency-envelope` | 16× 併發 | **北向 API，與資料面無關**（不要拿來當並發證據） |
| `bmv2-scale-ceiling-and-sflow-sample-math` | 誤差地板 196√(1/c) | **本輪的讀判準**（見 §5） |

⇒ **「大規模」與「並發」各做過一半，交集是空的。** 這是 9/03 報告「量測實驗」類最大的空白。

**為什麼舊的單流量測只碰到三台**：拓撲是 4 access（s1–s4，各 32 host）+ 4 agg（s5–s8）
+ 2 spine（s9、s10）。h1→h33 是 s1→{s5|s6}→s2，正好三台。
**跨 pod**（s1/s2 ↔ s3/s4）才會走 spine，一條流經過五台。

## 2. 拓撲（兩平面 matched，逐項查證過）

| | P4 | OVS |
|---|---|---|
| 模型 | `setting/StaticNetworkTopologyP4_10Switches_128Hosts.json` | `setting/StaticNetworkTopologyMininet_10Switches.json` |
| hosts / switches / edges | 128 / 10 / 288 | 128 / 10 / 288 |
| 起法 | `ndt up p4 128` | `ndt up ovs` |

- access：s1=h1–32、s2=h33–64、s3=h65–96、s4=h97–128，host link **1 Gbps ×128**
- core：**16 條 1 Gbps + 16 條宣告 10 Gbps**（有向計）
- 🔴 **那 16 條 10 Gbps 從來沒有被整形**：Mininet 靜默忽略 `bw>1000`
  （[[ovs-testbed-bandwidth-reality]]）。本輪**不修它**，但 §6-3 會量它。

## 3. 方法（量測側逐項沿用 08-16）

三路獨立取數，每 **2 s** 一次、跨全程：

1. **Ground truth**：root ns 全部 `sN-ethM` veth 的 rx/tx bytes（kernel NIC 計數器，
   在 twin/proxy/bmv2 記帳之下）。128 host port + 32 core port。
2. **Twin per-edge**：`/ndt/get_graph_data` 的 `link_bandwidth_usage_bps`，對時間積分成 bytes。
3. **Twin per-flow**：`/ndt/get_detected_flow_data` 全文。

對映：twin 邊 `sN:ifM→X` ↔ `sN-ethM` 的 tx delta；`X→sN:ifM` ↔ rx delta。
**取樣量測走 kernel 量子法/veth，不碰 `Δ[255]/Δ[1]` 比率法**（撤回案白名單）。

### 3-bis. 與 08-16 的一處**故意偏離**，以及它的代價

08-16 用 **NTG** `flow --config` 產流；本輪用**腳本化的 iperf3 fan-out**。理由：
兩平面要 matched，而 NTG 在 OVS 平面沒有驗證過，且 iperf3 能精確指定並發數、
每流速率與時長——那正是本輪的自變數。

🔴 **代價要寫明**：08-16 的**絕對比值**（1.033／1.028／+28.8%）與本輪**不可逐位互比**，
產流器不同。可比的是**形狀**：聚合比值是否仍近 1、per-edge 散佈是否仍與 Poisson 一致。

## 4. 負載設計（讓十台全部有負載）

64 條並發 iperf3 流，128 台 host 全員參與（64 client + 64 server）。配對：

- **32 條跨 pod**（s1/s2 的 host ↔ s3/s4 的 host）⇒ 每條經過 **5 台**，強制走 s9/s10；
- **32 條同 pod 跨 access**（s1↔s2、s3↔s4）⇒ 每條經過 3 台，只走 agg。

速率階梯（**故意**設計成能讓 F-9 現形）：

| 條數 | 每流速率 | 目的 |
|---|---|---|
| 48 | 5 Mbps | 主體 |
| 8 | **1 Mbps** | **低於 F-9 的 ~3 Mbit/s 量化門檻** |
| 8 | 20 Mbps | 重流 |

總 offered ≈ **408 Mbps**，跨 pod 約半數 ⇒ 每台 spine 約 100 Mbps。

**為什麼這個數字**：P4 fast build 實測 460–530 Mbps／switch（stock 只有 ~40，
所以 Adam 裁定用 fast——不然量到的是 binary 的天花板不是系統的）。
100 Mbps／spine 留了 4–5 倍餘裕。⇒ **本輪不應該撞到任何天花板；撞到就是 §7 的中止條件。**

窗長 **300 s**（150 個取樣點）。

## 5. 判讀規則（跑之前定死）

### 先驗條件（不滿足就不是證據）

0. **twin 已收斂**：`edges_down == 0 && hosts_ipv4 == 128`。開機環的教訓
   （[[punt-window-host-learning]]）：settle 窗外 host 邊不會自己好。**不滿足＝重開，不是照跑**。
1. **binary 指認**：記下 `simple_switch_grpc` 的實際路徑與 pid
   （[[benchmark-must-name-the-binary-it-measured]]——同一個 A/B 連兩次量錯 binary）。
2. **注入自證**：iperf3 每條流的 client 端結果必須回報實際 bitrate；
   任何一條回 0 或 error ⇒ 該流不計入母體，且要**在報告裡列出來**，不得靜默丟棄。

### 誤差地板（先算好才不會把噪聲讀成缺陷）

`error_floor = 196 · √(1/c)`，c ＝該邊的取樣數。1/256 取樣、300 s：

| 邊 | 預估流量 | 封包數 | 取樣數 c | 地板 |
|---|---|---|---|---|
| 20 Mbps host 邊 | 750 MB | ~500k | ~1950 | **4.4%** |
| 5 Mbps host 邊 | 187 MB | ~125k | ~488 | **8.9%** |
| 1 Mbps host 邊 | 37 MB | ~25k | ~98 | **19.8%** |
| spine 邊 ~100 Mbps | 3.75 GB | ~2.5M | ~9700 | **2.0%** |

🔑 **低於地板＝在平滑，不是「特別準」**（[[bmv2-scale-ceiling-and-sflow-sample-math]]）。

### 主判準

- **PASS**：有取樣的邊，聚合 twin/veth ∈ **[0.90, 1.10]**，且 per-edge 散佈與各自的地板一致。
- **PARTIAL**：聚合過但某一**類**邊系統性偏移（例如所有 spine 邊同方向偏）⇒ 新缺陷，要指認。
- **FAIL**：聚合超出 [0.90, 1.10]，或某類邊整組讀 0。
- **INCONCLUSIVE**：先驗條件任一不滿足、或撞到 §7 的天花板。**不得讀成 PASS。**

## 6. 預先寫下的預測（跑完不得修改本節，只能在報告裡對照）

| # | 預測 | 依據 | 這是觀察還是推論 |
|---|---|---|---|
| P1 | 聚合 twin/veth 落在 **1.00–1.10**（正偏） | 08-16 在 4 台上是 1.028–1.033 | **推論**（外推 32×） |
| P2 | **switch→host 邊不再是 0** | 3c 已於 `e86cb4d` 修好，Round 3 驗到 1.068 | **推論**（未在規模下驗過） |
| P3 | per-flow 守恆**正偏**，幅度未知 | 08-16 是 +28.8%，且該偏差在小流上放大 | **推論** |
| P4 | **F-8 會現形**：首次取樣前的邊報 **1 Gbit/s** | 未在規模下量過；128 台放大了「還沒被取樣」的邊數 | **推論** |
| P5 | **F-9 會現形**：8 條 1 Mbps 流的 host 邊**量化成 0** | 門檻 ~3 Mbit/s；速率階梯是為此設計的 | **推論** |
| P6 | **F-17 會現形**：twin 報的「平均使用率」明顯高於「所有邊的真平均」 | 只平均非零邊、排除 host 邊（`TopologyAndFlowMonitor.cpp:2703-2753`） | **推論** |
| P7 | **兩平面的比值差異 < 兩者各自的地板** | 兩邊 sFlow 取樣數學相同 | **推論** |
| P8 | 宣告 10 Gbps 的 16 條 core 邊，**twin 的使用率百分比會被低估 10 倍** | 分母用宣告容量、而該容量從未被套用 | **推論**——這是 `bw>1000` 待辦的直接證據 |

🔴 **八條全部是推論。本輪之前沒有任何一條在 128 台 × 並發下被觀察過。**

## 7. 中止條件（達到就停，不要硬產數字）

1. **撞到天花板**：任一 switch 的 veth 總吞吐持平在 460–530 Mbps 帶（P4）或 access 邊貼 1 Gbps
   ⇒ 量到的是天花板不是遙測，降載重跑。
2. **收斂先驗條件失敗兩次** ⇒ 停，先處理開機，不要在壞 fabric 上量。
3. **iperf3 失敗流 > 10%** ⇒ 母體不可信，停。
4. **kernel 或 proxy 在窗內重啟** ⇒ 該窗作廢（[[proxy-restart-warm-fabric-multiplies-telemetry]]：
   proxy 重啟 × warm fabric = 遙測 ×N）。

## 8. 本輪明確**不**宣稱

- 不宣稱吞吐量／效能數字（那是天花板量測，不是本輪題目）。
- 不宣稱 TE 的決策品質。
- 不宣稱任何 F-17／F-8／F-9 的**修復**——本輪只讓它們現形並量出幅度。
- 不宣稱 OVS 的 `bw>1000` 被修好。P8 是**證據**，不是修法。
- 不宣稱兩平面孰優。matched 是為了讓遙測的結論不依賴平面，不是為了排名。

## 9. 產物

`REPORT.md`、`raw/`（走 `audit-raw` orphan branch 的規矩：檔名一實驗一前綴、不得共用）、
`poll_veth.sh`／`poll_twin.sh`／`run_flows.sh`／`analyze.py`（分析器要先用**已知非空輸入**自測）。

[Co-developed with claude code -- Adam]
