---
name: bmv2-scale-ceiling-and-sflow-sample-math
description: bmv2 的規模天花板（>64 台 fidelity 崩壞、simple_switch_grpc ~170 Mbps）與 sFlow 取樣誤差公式，決定我們能測到什麼精度
metadata: 
  node_type: memory
  type: reference
  originSessionId: e3afba73-abd2-47e7-a371-fe86741876c3
  modified: 2026-08-16T14:00:36.336Z
---

兩組數字決定了 NDTwin 測試的物理上限，規劃規模化或 drift 門檻前先看這裡。

**bmv2 天花板**（來源：[bmv2 官方 performance.md](https://github.com/p4lang/behavioral-model/blob/main/docs/performance.md)
＋ Chen/Hu/Jin, SIGSIM-PADS '23, [DOI 10.1145/3573900.3591120](https://dl.acm.org/doi/10.1145/3573900.3591120)）：
- 單台 simple_switch 中位數 ~1047 Mbps ≈ **80,000 pps**；**`simple_switch_grpc`（我們用的）只有 ~170 Mbps**
  ⚠️ **2026-08-15 兩補**：①這 170 是**文獻值不是本機量測**——當天差點以「本機實測」寫進
  簡報，引用時務必標論文；②本機裝的 bmv2 是 **-O0+全 logging 的 debug build**（p4-guide
  預設，config.log 實錘），官方建議組態文獻可到 ~917M——所以 170 也不是 bmv2 的架構極限；
  重建配方在 `tools/test_workflow/build_bmv2_fast.sh`、分析在
  `doc/2026-08-15_bmv2-performance-report.md`。✅ **本機飽和點已量(2026-08-15 A/B 實測,3-hop fabric path、全 stack 在跑)**:
  stock(-O0)delivered **~40 Mbps/~3.6k pps**(TCP 24M、平行不加分、零損區 ≤25M);
  fast(-O3,`/usr/local/bmv2-fast`,topo 的 `bmv2_binary_override` 檔選用)
  **~460-530 Mbps/~50.8k pps**(TCP 431M、零損區 ≤300M)=**12-18×**。
  **170 文獻值兩顆 build 都不描述**(stock 低 4×、fast 高 3×)。天花板是 pps 不分包長;
  超額丟包發生在第一台 on-path switch 的 input buffer、介面計數器看不見。
  數字與方法全在 `doc/2026-08-15_bmv2-performance-report.md`。
- linear 拓撲 500 Mbps 鏈路：4 台 = 99.12% 達標；**超過 64 台顯著劣化**；256 台只剩 17.5%
- 根因是 container 共享系統時鐘與 CPU → temporal fidelity 崩壞，不是頻寬不足
- 我們的 10 台在安全區；**fat-tree k=4（20 台）仍安全，k=8（80 台）已進崩壞區**

**sFlow 取樣誤差**（來源：[sflow.org packetSamplingBasics](https://sflow.org/packetSamplingBasics/index.htm)）：
95% 信賴下 **誤差% ≈ 196 × √(1/c)**，c = 樣本數，**與總流量無關**。
我們 1/256 ＋ 1470-byte：一個樣本 = 3.01 Mbit。所以 `c = R×T / 3.01 Mbit`。

| 目標誤差 | 需要 c | 1 秒窗需要 | 10 秒窗需要 |
|---|---|---|---|
| ±20% | ~96 | ~290 Mbps | ~29 Mbps |
| ±10% | ~384 | **超過 bmv2 天花板** | ~116 Mbps |
| ±5% | ~1537 | 不可能 | ~463 Mbps（超過多台 bmv2 飽和點） |

**Why**：這解釋了 `d7bf52f` 為什麼 <10 Mbps 單讀會錯數倍而中位數準——不是 bug，
是取樣理論。也說明**在 bmv2 上「加大流量」永遠買不到 ±5%@1s**，生成器不是瓶頸。

✅ **出處已驗證(2026-08-16,讀原文 PDF)**:170 Mbps=該文 p.4、`simple_switch_grpc`
於 16-switch linear 拓撲(Fig.3);>64 台崩壞=Fig.4(256 台 17.5%);`simple_switch`
可到 ~1 Gbps。投遞包的手冊條目引用即此。

**How to apply**：
- drift 回歸門檻要有理論地板：`門檻(R,T) = max(1.5 × 196√(1/c), 2%)`，否則測試天生 flaky
- ⚠️ **c 要再乘 poll coverage(2026-08-16 多速率輪教訓)**:twin 的 usage 欄位是
  「last-1s 樣本數×256」無平滑;用 2s 輪詢積分時只觀測到一半的秒數,有效樣本
  `c_eff = c × coverage`(實測 coverage=0.51)。不修正會把噪聲尾巴誤判成缺陷
  (12M 窗 +26% 那格;150s 重測 0.940 收斂)。長窗(≥430s 或多流)修正無感。
- 要更高統計品質，改 emitter 的取樣分母（1/64、1/16）比加流量便宜——我們自己控制合成器
- TRex 這類 DPDK 產生器對我們毫無意義（差三個數量級），iperf3 就夠
- 規模化 soak 前先量 **emulator noise floor**（twin 不動、同場景跑 3 輪），
  否則 bmv2 自己的 fidelity 劣化會被算到 twin 頭上

2026-08-15 無記憶驗收員實測錨點:20.58M 恆定流的 per-link 瞬時讀值 -40%/+78% 極值、
per-flow ±14%——與本公式預測一致,取樣數學經驗上成立;量子=256×1490×8=3,051,520 bit。
⚠️ 同晚教訓:`egress_port_counter[255]` **不數 clone**(P4 egress 明文 return 不計),
量取樣到達率要用 kernel 量子法或 tcpdump :6343,別用該 counter([[reproducible-is-not-mechanism]])。

完整推導見 `doc/audit/2026-08-13_advanced-testing-research/REPORT.md` §2.1–2.3。

---

## 2026-08-19:兩個「文獻說 / 註解說」的上限被本機實測推翻或補上

**① P4 側的取樣精度第一次量了,而且與 OVS 一樣好。**
兩個平面**都是 1/256**(`ndtwin_switch.p4:52` 的 `SAMPLE_RATE = 256` 對
`testbed_topo.py:136` 的 `sampling=256`,P4 的註解明寫是為了對齊),所以
`196√(1/c)` 兩邊共用,是**同一把尺量兩個平面**。實測(P4 stock 20M / fast 200M,
各 2400 / 3599 樣本、0 掉樣):**中位數比值 0.97–1.02,散布在每個窗長都 ≤ 理論地板。**

🔑 **這回答了「合成的遙測和原生的一樣準嗎」**——P4 的 sFlow 是 proxy 從 clone 捏出來的,
kernel 分不出來,而數值上也**確實一樣**。這是「上層一行都不用改」那個主張的數值面驗證。

⚠️ **一個未解點**:P4 的散布**一致地低於**理論地板(1 秒窗 54.6% 對理論 75.5%),
OVS 則正好坐在線上。**機制沒查明,不要猜。**

**負載對齊的硬約束(規劃同類實驗時先看這條)**:stock bmv2 天花板 ~40 Mbps,
**物理上到不了 200 Mbit/s**。要對齊 OVS 的 200M 那輪就**必須換 fast build**
(`bmv2_binary_override`),而換 build 本身是一個變因要交代。20 Mbit/s 那點 stock 可以。

**量子是 per-flow,現在有四個實測值**:1490(P4 兩輪)、1494(OVS)、1506、1490。
`analyse.py` 把 QUANTUM 寫死成 1494,重用時**必須換成該輪的 GCD**——
`doc/audit/2026-08-19_p4-sflow-accuracy/analyse_q.py` 是把它變成參數的版本。

**② 「>64 台崩壞」是關於交換機數,不是 host 數。**
`p4_testbed_topo.py` 那句 `128 hosts in BMv2 might be too heavy` **實測是錯的**——
10 台交換機 / 128 hosts 完全跑得動。見 [[p4-128-hosts-four-hardcoded-lists]]。
**引用文獻的規模上限時要分清楚它限制的是哪個維度。**

---

## 🔑 2026-08-20 實測：那個地板是「繼承的」，而且是回答教授問題的關鍵

**教授問的**：twin 的 sFlow jitter 是本來就有的，還是我們造成的？

**答案：繼承的，而且它不是任何一版程式碼的性質——它就是 1/256 取樣統計本身。**
三條互相獨立的證據：

1. **同 fabric A/B**（OVS 128-host、200 Mbit/s、同一條邊 `s1-eth2`、同樣 294 s，只換 kernel binary）：

   | | sd/mean | 地板 `100/√λ` | 比值 |
   |---|---|---|---|
   | 簡報那張（08-18） | 13.5% | 12.2% | 1.11× |
   | 今天的 kernel | 12.7% | 11.9% | 1.06× |
   | **28b8b13 fork point** | 11.8% | 12.0% | **0.98×** |

2. **換算 rate 的程式碼跨 fork 逐字元相同**（`interval = (now - lastReportTimestampInMilliseconds)/1000` 配 1 秒迴圈）——**平均窗口沒被動過**，而拉長窗口正是「讓 jitter 看起來變小」最容易的作弊法。
3. **拓樸模型 `StaticNetworkTopologyMininet_10Switches.json` 兩樹逐位元組相同**，所以兩臂模擬的是同一組 288 條邊。

**判讀規則（比數字本身耐用）**：比的不是「誰的 sd 小」，是**每一版離地板多遠**。
- 兩邊都貼地板 ⇒ 取樣統計，不是任何人的錯
- 某版**明顯高於**地板 ⇒ 那版加了可避免的雜訊
- 某版**明顯低於**地板 ⇒ **那版在平滑**，用延遲換好看（這是最該抓的一種，因為它看起來像「比較好」）

⚠️ **λ≈70 時不要畫每一格量子的格線**。簡報那張 20 Mbit/s 的 ladder 能看是因為 λ≈7；
200 Mbit/s 下同樣畫法是一百條灰線蓋住要比的東西。改成一根「1 sample」比例尺 + ±1 sd 色帶。
圖：`doc/audit/2026-08-20_sampling-rate-and-cpu/plot_figures.py::fig_ladder_inherited`
→ `page_ladder-inherited.png`；分析 `analyse_jitter_ab.py`。

**順帶（同樣用 git grep 在 28b8b13 直接確認的繼承項）**：F-1 假 CPU/memory
（`10 + hash % 50`，三處）、北向 API 序列化（`io_context{1}`，`main.cpp:119`）。
歸屬要寫對：這些不是我們發明的，但也還沒修。
