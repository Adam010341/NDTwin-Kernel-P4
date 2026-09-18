# PREREG — 三組遙測同 fabric 量測（無遙測／合作式 A／鏈路式 B）

**2026-09-19 由 TICKET-P3 工單 E 的 worker 註冊，在任何一個封包被送出之前。**
設計正本＝`TICKET-P3-observation.md` §2.8、§7；前例＝`2026-08-28_packet-size-sweep/PREREG.md`（梯子、frame 口徑、外部 CPU 閘）、
`2026-08-28_single-switch-build-ratio/`（量化區間跨界要有 indistinguishable 分支）、`2026-08-20_sampling-rate-and-cpu/`（遙測成本固定）。
base＝`25b45cf8`（trunk＋工單 B、C 併回）。

**[Co-developed with claude code -- Adam]**

---

## 0. 註冊時的狀態（零封包）

| 條件 | 狀態 |
|---|---|
| 本輪跑過任何一臂 | ❌ **沒有**；`raw/` 不存在 |
| 本文引用的數字來源 | 只有 08-20／08-28 兩輪的既有結果與碼；**沒有一個數字來自本輪** |
| 寫腳本 | **還沒開始**——工單 §7 規定 PREREG 先給 orchestrator 看過 |

08-28 AMENDMENT-1 的三條修訂資格（零封包、理由只引既有資料、只收緊）是本檔日後若要修訂的同一組門檻。

---

## 1. 問題

同一個 fabric、同一顆 binary、同一條路徑上，把遙測來源換成三種：

| 組 | 機制 | 樣本從哪裡來 |
|---|---|---|
| `none` | 不取樣 | 沒有樣本 |
| `cooperative`（A 路） | pipeline 在交換機內 clone 到 CPU port（`SAMPLE_RATE` 編進 `ndtwin_switch.json`＝1/256），proxy 合成 sFlow | bmv2 內 |
| `link`（B 路） | 交換機側 veth 上 `tc … action sample rate 256`，root 的 emitter 合成 sFlow | Linux tc／psample |

量三件事：**① pps 天花板、② 取樣誤差、③ CPU**，並對帳三條舊結果。

🔴 **這一輪的意義不在於「遙測貴不貴」，而在於它是在天花板附近問的。** 08-20 在 200 Mbit/s、
遠離天花板處量到「關掉取樣不買到任何吞吐量、bmv2 CPU 不動」。天花板是**每封包邊際成本**定的，
所以「遙測不佔資料面」這句話正好在天花板那裡最有可能失效——本輪就是去那裡問。

---

## 2. 組別是**證明**的，不是假設的

每一臂開跑前與收工後各讀一次，全部進 `arm.meta`／`state_{before,after}.json`：

1. `GET :8081/p4/switch_state` ⇒ 每台的 `telemetry.source`、`telemetry.clone_session`、
   `telemetry.sflow_registered`；`control_plane.telemetry` 的 `knob`、`package`、
   `link_emitter{pid, alive, switches, rate}`。
2. **組別不符＝該臂作廢**：任何一台的 `telemetry.source` ≠ 本臂要求的字 ⇒ 作廢，不分析。
3. `link` 組另外要：`link_emitter.alive == true`（開跑前與收工後各一次）、
   `/tmp/ndtwin_link_telemetry.json` 存在、emitter log 的統計行在視窗內 `samples=` 有增加。

### 2.1 🔴 遙測「在」與「不在」都要有正對照——這是 08-20 被撤回的那一格

08-20 的 `noclone`／`mnone` 兩格**標著零、實際還在取樣**（`write_clone_session` 的
DELETE-對-空帳本是 no-op，孤兒 multicast group 繼續 clone），整段結論因此撤回。
本輪把那個教訓寫成兩條會讓臂作廢的斷言：

| 組 | 註冊的斷言（違反＝該臂作廢） |
|---|---|
| `none` | 視窗內 `/ndt/get_graph_data` 每一條邊的 `link_bandwidth_usage_bps` **全為 0**；`get_sflow_stats` 的 `addressed_total` 增量＝0 |
| `cooperative`／`link` | on-path 邊至少有一個非零讀數；`addressed_total` 增量 > 0 |

第二條防的是 08-20 的另一格：`packet_length_bytes=128` 的截斷會**靜默毀掉全部遙測**，
CPU 特徵與「完全沒有 clone」無法區分。一個讀零的 `cooperative` 臂長得跟 `none` 一模一樣。

---

## 3. 儀器與口徑

### 3.1 fabric

`NDT_OWNER=… ndt up p4 4 --telemetry <word>`：10 台 bmv2（`bmv2-fast`）、4 台主機、
NDTwin 自己的 pipeline、模型 `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`。
路徑 h1(s1:3) → h4(s4:3)，途中 s1 → {s5|s6} → {s9|s10} → {s7|s8} → s4
＝**5 台交換機、4 條 switch–switch 邊**。實際走哪一條由量到的 on-path 介面集合決定，**不預設**。

### 3.2 🔴 frame，不是 payload

軸是 Ethernet frame size（RFC 2544 慣例），iperf3 的 `-l` 是 UDP payload。
`frame = payload + 42`（14 Ethernet + 20 IPv4 + 8 UDP）。

| 軸點（frame） | iperf3 `-l`（payload） |
|---|---|
| 64 B | **22** |
| 1024 B | **982** |

兩個數字都寫進每一臂的 `arm.meta`。（08-28 PREREG §2 同一條；那一輪還多一個 256 B 點，
本輪不取——工單指定兩個尺寸，而 256 B 對三組比較沒有新的鑑別力。）

### 3.3 pps 從交付資料包數算

`pps = sum_received.packets / sum_received.seconds`（iperf3 `--json`），
**絕不** 由 bps ÷ 標稱尺寸反推——那會把結論算進假設裡。
要求速率 `-b = pps × payload × 8`（iperf3 的 `-b` 是應用層位元率）；
**要求的 pps 不是量到的 pps，永不當成量到的報**。

### 3.4 取樣誤差的量法＝`ndt check` 的 twin/veth 對帳（同一式子，不同外殼）

`tools/test_workflow/ndt` `cmd_check`（`:6013` 起）的方法逐條照抄：

- twin 側：4 Hz 取 `GET :8000/ndt/get_graph_data`，對 `link_bandwidth_usage_bps`
  做**時間加權積分**（`值 × dt`，不是每變化一次算一次）；鍵＝`s<src_dpid>-eth<src_interface>`，
  只取兩端都是交換機的邊。
- 地面真相：同一組鍵在 `/proc/net/dev` 的 `tx_bytes` 視窗前後差。
- 兩側取**同一個鍵集合** `KEYS = twin_keys ∩ netdev_keys`（`ndt check` 的註解說明為什麼：
  兩個集合真的會不同，母體不齊會被讀成 double-counting）。被排除的 host-facing 介面逐一列出。
- 指標 `ratio = twin_bps / truth_bps`，登記量＝**`|ratio − 1|`**，並**另外**登記帶號的
  `ratio − 1`（見 §5.2：R4-5 量到十二次全低，只報絕對值會把系統性偏差藏起來）。

**為什麼不直接呼叫 `ndt check`**：(a) 它的輸出是整頁散文，driver 讀不動（它自己的註解也這麼說）；
(b) 它在 `lab.claim` 有 `measuring=` 時**拒跑**，而本輪照實驗室規矩一定要宣告 measuring；
(c) 它只吐一個比值，本輪每個視窗要 twin 積分、truth、每條邊、非零讀數計數、`get_sflow_stats` 增量。
⇒ 用同一支式子，寫成會吐 JSON 的 `sample_error.sh`，並在 FINDINGS 裡標明「方法＝`ndt check`
`:6150-6240`，逐行對照過」。

### 3.5 CPU：逐行程，用 exact comm 或記下來的 pid，**永不用 argv pattern**

| 行程 | 怎麼指認 | 為什麼 |
|---|---|---|
| bmv2 ×10 | `ps -eo pid,comm=` 的 comm（＝`simple_switch_g`，15 字截斷）**並**與 `/tmp/ndtwin_p4_switches.json` 的 pid／device_id 交叉比對 | manifest 另外給每台的 device_id ⇒ 可以逐台歸屬 |
| kernel | comm `ndtwin_kernel`，與 `.test_run/pids/kernel.child.pid` 交叉比對 | |
| proxy | **pid 取自 `.test_run/pids/p4_proxy.child.pid`** | comm 是 python 直譯器，comm 分不出來 |
| emitter（`link` 組） | **pid 取自 `/tmp/ndtwin_link_telemetry.json` 的 `pid`** | 同上；且工單指定按 manifest 的 pid 歸屬 |
| iperf3 | comm `iperf3`，**逐 pid 累加器** | 每個 rung 都重生 iperf3，「對現在活著的加總」會在 rep 之間掉回 0（08-28 §4 的那個 bug） |

🔴 `pgrep -f`／`pkill -f`／`killall` 一次都不用；08-28 的 `run_size_arm.sh:71` 用了
`pgrep -af 'simple_switch_g[r]pc'` 取 binary 路徑，本輪改成讀 manifest 的 `argv`。

**取樣器**：`cpu_arm_probe.py`（本目錄新檔，2 Hz），寫 JSONL：每列＝時間戳、
`/proc/stat` 完整八欄（**softirq 單獨留著**，見 §6.2）、每個 pid 的 `utime+stime`。
第一列是 header（`clk_tck`、`nproc`、`hz`、pid→label 對映），跟 `cpu_probe.py` 同一條紀律：
分析時要用的常數寫進資料裡，不要留在分析者的腦袋裡。

> **為什麼不直接用 `tools/test_workflow/cpu_probe.py`**（工單允許在需要時動它，本輪選擇不動）：
> 它的 `TARGETS` 用 cmdline 子字串配對，而 (1) emitter 的 cmdline 不含它任何一個 needle
> ⇒ **`link` 組的處理成本會讀成零**；(2) proxy 與 emitter 都是 `python3`，comm 分不開，
> 而兩者的 pid 都有權威來源（pidfile／manifest）——用 pid 比任何 pattern 都強；
> (3) 紅線要求「不要用 argv 上的 pattern」。加一個 needle 會把工單指名要用 pid 的那一個行程
> 留在 pattern 規則裡。⇒ 在 E 自己的目錄寫一支只做這件事的取樣器，`cpu_probe.py` 一個字不動。
> `cpu_probe.py` 獨有的 kernel per-thread 明細本輪用不到（那是找 idle spin 用的）。

### 3.6 binary 指認（每一臂）

| 對象 | 識別碼 |
|---|---|
| kernel | `build/bin/ndtwin_kernel` 的 **sha256（全長＋前 8 碼）**，開跑前與收工後各一次；不相等＝該臂作廢 |
| bmv2 | manifest `argv` 裡的絕對路徑；與 `p4_proxy/mininet/bmv2_binary_override` 第一行**必須相同**（不同＝拒跑，照 `run_build_arm.sh:78`）；該檔 sha256；`nm -DC <bin> \| /usr/bin/grep -c EventLogger` ⇒ **fast=0**（①b 的雙向簽章，stock=24） |
| pipeline | `p4_proxy/p4_src/build/ndtwin_switch.json` 的 sha256（`SAMPLE_RATE=256` 編在裡面） |
| 遙測組 | `switch_state` 每台的 `telemetry.source`（§2） |

「跑過」與「讀過未執行」永不混表：`arm.meta` 每一行都是這一臂當下讀到的。

---

## 4. 臂清單與順序

### 4.1 ① pps 天花板：12 臂，6 個 fabric 世代

梯子（08-28 §7.5 原值，不改）：**`1 2 3 5 8 12 20 30 45 70 110 160 240` kpps（offered）**。
`STEP_S=8`；乾淨階＝loss ≤ 0.5%；讀到 0 < loss ≤ 2.0% ⇒ 三 rep 取中位數；
截斷＝連續兩階 loss > 25%；梯頂三 rep 再確認＋walk-down（全部照 08-28／③ AMENDMENT-2 §11.1）。

**換組必須重建 fabric**（`--telemetry` 是 bring-up 決定的），所以世代與組綁在一起。
安排成 **6 個世代、每個世代兩臂（兩個 frame 尺寸）**，組序與尺寸序**都**鏡像：

| 世代 | 組 | 臂 1 | 臂 2 |
|---|---|---|---|
| G1 | none | f64_a | f1024_a |
| G2 | cooperative | f64_a | f1024_a |
| G3 | link | f64_a | f1024_a |
| G4 | link | f1024_b | f64_b |
| G5 | cooperative | f1024_b | f64_b |
| G6 | none | f1024_b | f64_b |

每個（組, 尺寸）格有一臂早、一臂晚；每一組有一個早世代與一個晚世代。
**線性漂移（機器狀態、熱、快取）與組別對不齊**，這是鏡像的全部目的。

🔴 **這個安排控制不了的事，先寫下來**：同一世代內第一臂永遠在第二臂之前（尺寸序鏡像後在格層級抵銷，
在世代內沒有抵銷）；每一組只有兩個 fabric 世代，所以「世代效應」與「組效應」只分離到兩個樣本的程度。
一個世代一臂（12 個世代）會更乾淨，代價是 12 次 bring-up；**選了 6 次，理由是 bring-up 時間，
這是一個成本取捨不是一個控制**，照實揭露。

### 4.2 ② 取樣誤差：27 個視窗

每組 3 個速率 × 3 個視窗；速率 2 / 20 / 100 Mbit/s（UDP、`-l 1400` ⇒ frame 1442 B，
與 08-20 同一個尺寸），每個視窗 8 s（＝`ndt check` 的 `NDT_CHECK_SECS` 預設）。

視窗順序在每組內鏡像：**`2 20 100 | 100 20 2 | 2 20 100`**——每個速率一次早、一次中、一次晚。

**跑在哪裡**：每組的**早世代**（G1／G2／G3）內，**在兩個梯子臂之前**。
理由：梯子會把 fabric 推到飽和，留下佇列與流表狀態（idle timeout 灌爆流表是本 codebase 的既知形狀）；
取樣誤差要的是乾淨低載狀態。⇒ 世代內順序固定為 `sample_error block → ladder f? → ladder f?`。

🔴 **後果**：取樣誤差只在一個 fabric 世代量，**世代效應與組效應不可分離**。登記為限制，不是缺陷。

### 4.3 控制臂（在任何量測臂之前跑，結果不論好壞都記）

| 控制 | 內容 | 判準 |
|---|---|---|
| **C1 產生器上限（64 B）** | h1→h1 loopback、64 B frame（`-l 22`）、不經 bmv2、3 rep | 必須 ≥ **5×** 本輪 64 B 經 bmv2 量到的最高 pps |
| **C2 產生器上限（1024 B）** | 同上，`-l 982`、3 rep | 必須 ≥ **5×** 本輪 1024 B 的最高 pps |
| **C3 外部 CPU 閘的陽性對照** | 丟棄臂，第 4 階起點火 4 個 CPU burner | `external` 必須明顯上升且**閘門必須拒絕那一臂** |

C1／C2 分開跑而不沿用 08-28 的 770.7 kpps：①b §3 立的規矩——產生器上限是**每個 frame 尺寸各自**的量，
小封包受每封包成本限制、大封包受頻寬限制，一個不能代另一個；而且那是三週前另一個 fabric 狀態的數字。
C3 不跑成功就**不開跑**（08-28 §7.3：換掉一個會誤觸的閘、換上一個從沒觸發過的閘，不是改善）。

---

## 5. 註冊的假設與區間

### 5.1 ① pps 天花板

令 `C(g, s)` ＝組 g 在 frame 尺寸 s 的兩臂**最高乾淨 kpps 的平均**。

| 假設 | `C(cooperative,s)/C(none,s)` 與 `C(link,s)/C(none,s)` | 意義 |
|---|---|---|
| **H-A1 遙測不佔資料面** | **[0.60, 1.67]** | 08-20 的結論延伸到天花板也成立；兩條路都「白吃」 |
| **H-A2 遙測要用資料面的 pps** | **< 0.60**，且兩個 frame 尺寸與兩遍都同向 | 天花板要分「有遙測的」與「沒遙測的」兩個數字報 |
| **H-A3 遙測讓天花板變高** | **> 1.67** | 🔴 先當**儀器嫌疑**不當發現（最可能：`none` 臂其實不是 none，或 loss 口徑不同） |
| **H-A0 無法分辨** | 同一格兩臂差超過一階 | 該格**不算出比值**，報「一階內不可分辨」＋兩臂值 |

區間寬度的來源：梯子在本輪關切區的**實現步距**是 12→20 kpps ＝ **1.667×**
（不是名目的 1.5×——08-28 FINDINGS 的 08-30 更正）。兩臂平均的量化不確定度在比值兩邊各一階，
所以 [0.60, 1.67] ＝「一階內不可分辨」的字面翻譯。
**H-A0 這個分支是 ①b §4 的裁定**：任何比值輪都必須先註冊「區間跨界＝不可分辨」的分支，
不然落在界上只能事後編。

**方向性預期（不是區間，先寫下來以免事後說成預測）**：若有任何一組低於 `none`，
**更可能是 `link`**——`tc … matchall action sample` 對交換機每個埠的**每一個**封包做分類，
那是 Linux tc 路徑上的每封包工作；合作式的每封包工作在 bmv2 pipeline 內。

### 5.2 ② 取樣誤差

視窗 8 s、frame 1442 B、取樣率 1/256、on-path switch–switch 邊 4 條。
每視窗貢獻積分的樣本數 `N = 4 × pps × 8 / 256`：

| 速率 | pps | N | 1/√N | 預測 median\|ratio−1\| ＝ 0.674/√N |
|---|---|---|---|---|
| 2 Mbit/s | 178.6 | 22.3 | 0.212 | **0.143** |
| 20 Mbit/s | 1785.7 | 223.2 | 0.067 | **0.045** |
| 100 Mbit/s | 8928.6 | 1116.1 | 0.030 | **0.020** |

（0.674＝零均值常態的 median|X| / sd。`N` 是**預測**；實際樣本數由
`get_sflow_stats` 的 `addressed_total` 增量量到，不是假設的——`link` 組多一個
host-facing egress 濾器，樣本數本來就會比 `cooperative` 多約 1.2 倍。）

| 假設 | 判準 | 意義 |
|---|---|---|
| **H-B1 shot-noise 主導** | 三個速率的 median\|ratio−1\| 都落在 **[0.5, 2.0] × 0.674/√N**（⇒ [0.071,0.285] / [0.023,0.090] / [0.010,0.040]） | 估計量無偏、誤差只有計數雜訊；「取樣越密越準」在 8 s 視窗上也成立 |
| **H-B2 系統性偏差主導** | 100 Mbit/s 那格 **> 2.0×** 預測，**且** 三個視窗的 `ratio−1` 同號 | 報**帶號的偏差**；twin 的準確度敘述改成「偏 b」而不是「有雜訊」。先驗支持這一支：`ndt check` 的 R4-5 註記量到十二次 0.85–0.97，**每一次都低** |
| **H-B3 樣本掉了（只對 `link`）** | `E(link,r) > 2 × E(coop,r)` **且** emitter 的 `dropped_*`／`enobufs` 在該視窗 **> 0** | 歸因於樣本遺失，並列出計數 |
| **H-B4 兩條路一樣準** | `E(link,r)/E(coop,r) ∈ [0.5, 2.0]`，三個速率都是 | A 路與 B 路的觀測品質可互換 |
| `none` | **n/a**，不是 0 | twin 沒有讀數 ≠ 誤差為零。表上寫 n/a，旁邊寫「非零讀數＝0（§2.1 的作廢斷言）」 |

🔴 **H-B3 的反面同樣註冊**：計數器是 0 的時候**不准**寫「樣本掉了」。
這是 ROLE-5 的教訓（`ndt check` 的 `cause_lines` 整段）：把一個沒觀測到的機制寫進判決字串。

### 5.3 ③ CPU

主軸＝**1024 B 梯子上三組共同有的每一階**（那裡沒有 twin poll，見下方紅字），
量 `Δkernel(g, k) = kernel_CPU(g, k) − kernel_CPU(none, k)`（% of one core），
橫軸 `S(k)` ＝該階量到的 samples/s（`addressed_total` 增量 ÷ 秒）。

擬合 `Δkernel = F + m · S`。

| 假設 | 判準 | 意義 |
|---|---|---|
| **H-C1 成本固定、不是每樣本**（08-20 的結論） | `m ∈ [103, 618] µs/sample`（＝08-20 的 206 的 0.5–3.0 倍）**或** 固定份額 `F / (F + m·S_top) ≥ 0.5` | 08-20 在 10 台 fabric 上重現 |
| **H-C2 成本按樣本走** | `F / (F + m·S_top) ≤ 0.2` 且 `Δ(高階)/Δ(低階) ≈ S(高)/S(低)` | 08-20 的固定成本是 128 台 fabric 的產物，不是遙測路徑的性質 |
| **H-C3 混合** | 介於兩者 | 🔴 **這是結果不是「沒有結論」**——08-28 §4 的 H3 教訓：先註冊，落在中間才不會被寫成 inconclusive。此時報分解出來的 (F, m) 本身 |
| **H-C0 解析不出來** | 同一格三個視窗（或三個 rep）的 `Δkernel` 散佈 **大於** `Δkernel` 本身 | 不擬合、不報數字，報「在儀器解析度以下」＋量到的散佈 |

附帶註冊：
- **bmv2 CPU**：`bmv2_total(cooperative)/bmv2_total(none)` 在相同階 **∈ [0.90, 1.15]**
  ⇒ 與「sFlow 不是 bmv2 的瓶頸」(08-20) 一致。落外＝那句話在天花板附近不成立，是本輪的發現。
- **`link` 組的資料面成本不落在我們任何一個 pid 上**：`tc action sample` 在 softirq 脈絡執行。
  ⇒ `/proc/stat` 的 **softirq 欄單獨記錄並逐組報**；預測 `link` 抬高 softirq、`cooperative` 不會。

🔴 **CPU 的數字只取梯子臂，不取取樣誤差視窗。** 取樣誤差視窗有一個 4 Hz 的
`/ndt/get_graph_data` poll，而那個 HTTP 工作正是被量 CPU 的那個 kernel 行程在服務
（08-20 的 `POLL=off` 就是為這件事存在的）。視窗的 CPU 照記照存，但**明文排除在 §5.3 的比較之外**。

---

## 6. 負載閘：外部 CPU 殘差

### 6.1 定義

```
external = ( Δbusy − Δbmv2 − Δiperf3 − Δkernel − Δproxy − Δemitter ) / Δtotal
```

`Δbusy`、`Δtotal` 取自 `/proc/stat` 的彙總列（`busy = total − idle − iowait`），
其餘取自 §3.5 指認出來的 pid，1 Hz 之外每 0.5 s 一列（2 Hz）。

🔴 **與 08-28 AMENDMENT-1 §7.2 的差別，以及為什麼**：那一輪的殘差只扣 bmv2 與 iperf3。
本輪 kernel／proxy／emitter **就是處理本身**——把它們留在殘差裡，閘門會要求重跑
**正好是扛著結論的那幾臂**，而且每次重跑都會再觸發。那正是 §7.1 為 bmv2 在 64 B 修掉的病，
換一個位置復發。⇒ 全部進到被歸屬的一側，閘門只看剩下的。

### 6.2 門檻，以及一個必須先講清楚的陷阱

> 一臂的平均 `external` 若超過 **它自己那一組** 的中位數臂 **0.15 絕對值** ⇒ 重跑該臂。

**組內比，不是全域比。** 理由：`link` 組的 tc 取樣成本在 softirq 脈絡，**歸屬不到任何 pid**，
會整組抬高 `external`。用全域中位數當基準，閘門就會對 `link` 組整組開火——又是「把處理效應
當成污染」。⇒ 組間的 `external` 差**當成量測報**（§5.3 的 softirq 那條），**不當閘門用**。

### 6.3 閘門沒看過它會觸發，就不算交付

C3（§4.3）在任何量測臂之前跑，raw 與判決不論結果都存。**C3 不觸發 ⇒ 本輪不開跑**，
且閘門在 FINDINGS 裡標成 unvalidated。（08-28 §7.3 原條。）

---

## 7. 停止規則、作廢規則、重跑規則

**臂作廢（重跑一次；兩次都壞 ⇒ 該格報 FAILED，不補值）**
1. 組別不符（§2）。
2. 遙測在／不在的斷言違反（§2.1）。
3. kernel sha 在臂的頭尾不同；bmv2 路徑與 override 不符；EventLogger 簽章不是 fast。
4. `external` 觸發組內門檻（§6.2）。
5. 梯子上出現 `NO_MEASUREMENT`（iperf3 沒有結果）——**「沒有量到」不是一個低 loss 讀數**。

**整輪停**
- C1／C2 任一失敗 ⇒ **該 frame 尺寸只報「產生器受限」**，不得對該尺寸的 bmv2 pps 說任何話。
- C3 不觸發 ⇒ 不開跑（§6.3）。

**不重跑的情況（明文）**
- **數字不討喜不是重跑理由。** ①b §1.3 的裁定：儀器構得到問題卻落在界上，就照實報解析度極限。
  本輪任何重跑都要寫進 FINDINGS 的重跑表：哪一臂、觸發哪一條、兩次的值都留著。

**量測視窗內不 commit。** 每個 commit 會拉起一輪背景 review（量到超過兩顆核），
把它記進實驗就是污染實驗（08-28 §6 原條）。

---

## 8. 對帳三條（現在註冊，不事後補）

### (a) pps 天花板 vs 08-28 的 1024 B ＝ 16.0 kpps

| | |
|---|---|
| **本輪拿哪個數** | 主：`C(none, 1024)`（工單 §2.8 指定）；**並列**：`C(cooperative, 1024)` |
| **舊的那個數** | 16.0 kpps＝兩臂 {12, 20} 的平均（**沒有任何一臂讀到 16.0**，08-30 更正原文）；128 台 P4 fabric、h1→h65（s1→s3）、`/usr/local/bmv2-fast/`、kernel `a40e04ce`、frame 1024 B／`-l 982`、同一梯子同一乾淨規則 |
| **已知的條件差異（四項）** | ①fabric 大小 4 vs 128 台主機（改變 kernel 維護的圖、proxy 的工作、twin 的邊數；**不改 bmv2 的每封包路徑**）②路徑 h1→h4（4 條 switch–switch 邊、5 台交換機）vs h1→h65（3 跳）——天花板由**最慢的單執行緒 bmv2** 決定，跳數只在後面某台比第一台慢時才改變它 ③kernel binary 不同（本輪每臂記 sha）④**08-28 的臂是開著生產取樣（合作式 1/256）的**——它的 `drive_p2.sh`／`run_size_arm.sh` 沒有任何關閉 clone 的路徑 |
| **⇒ 條件對齊的那一格是 `cooperative`，不是 `none`** | 所以兩個都報。工單指定的是 `none` 對 16.0，照報；**`cooperative` 對 16.0 是條件較齊的那一組**，同時報。🔴 **可推翻條件**：若 08-28 的 raw（audit-raw）顯示那一輪其實沒有在取樣，配對反轉為 `none`——由 orchestrator 從 raw 認定，本檔不猜 |
| **「一致」的區間** | 比值 ∈ **[0.60, 1.67]**（一個實現階距，同 §5.1） |
| **落在區間外代表什麼** | **不是推翻。** FINDINGS 必須點名上表四項差異中哪一項能扛這個差，並寫下什麼才能判定——**只有同規格 fabric 的一臂能判定，而本輪沒有它** |

### (b) CPU vs 08-20 的「遙測成本固定、不是每樣本」

| | |
|---|---|
| **本輪拿哪個數** | §5.3 擬合出來的 `m`（µs/sample）與固定份額 `F/(F+m·S_top)`；外加最低階與最高階的 `Δkernel` 兩個點 |
| **舊的那個數** | 556 samples/s 時 57.2 點的 ingest 成本裡，**46.3 點在 34.7 samples/s 就已經付掉**（＝81% 固定）；邊際 **206 µs/sample**（34.7→556.1 之間）；零點＝`mzero` 冷 fabric 對，poll-off 臂 2.8%；128 台 fabric、300 s 視窗、200 Mbit/s／1442 B |
| **已知的條件差異（三項）** | ①fabric 大小：`F` 跟 kernel 維護的圖走（288 條邊 vs 本輪 16 條 switch–switch 邊）⇒ **本輪的 `F` 預期會小，那不是矛盾**；②視窗 8 s vs 300 s；③本輪的零點是**真的 `none` fabric**（`ndt up --telemetry none`）且由 twin 讀零驗證過，比 08-20 那個被撤回過一次的控制強 |
| **「一致」的判準** | `m ∈ [0.5, 3.0] × 206 µs/sample` ＝ **[103, 618]**（**或**）固定份額 ≥ 0.5。**任一成立＝與「成本固定」一致**；兩個都不成立＝「固定成本的結論在 10 台 fabric／8 s 視窗上沒有重現」——**這是一個結果**，FINDINGS 要指出上表三項差異中的候選與什麼能判定 |
| **為什麼比 `m` 而不比 `F`** | `m` 是邊際斜率，跨 fabric 大小該轉移；`F` 跟圖的大小走，本來就不該轉移。比一個註定不同的量會製造假的不一致 |
| **不可分辨分支** | H-C0（§5.3）：散佈大於效應 ⇒ 不擬合，(b) 報「本輪解析不出來」＋散佈值 |

### (c) 12× / bmv2 build ratio — **本輪不宣稱任何新的比值**

工單明文：本輪不重量 stock，只把 fast 的 `none` 天花板與舊的 fast 數字**並列**、標明條件差異。

FINDINGS 的表格逐列帶上：hops、主機數、frame 尺寸、遙測組、binary 識別碼。

| 來源 | 數字 | 條件 |
|---|---|---|
| 08-15 | fast 300 Mbit/s | 三跳、1400 B |
| ①b（08-28） | fast 360 Mbit/s | **單跳**、1400 B、control plane live |
| ②（08-28） | fast 16.0 kpps ＝ 131.1 Mbit/s（frame） | 三跳、1024 B frame、128 台、合作式取樣開著 |
| 本輪 | `C(none, 1024)`（kpps 與 frame Mbit/s 兩種寫法） | 4 跳、1024 B frame、4 台主機、**無遙測** |

🔴 **註冊的禁句**：這張表**任何一格不得除以另一格**；本輪不得出現任何含 stock 的比值
（本輪沒有 stock 臂）。(c) 除了並列之外不提供新資訊——(a) 已經是那個定量比較。

---

## 9. 每個結局代表什麼（先寫，免得事後挑）

| 結局 | 意義 | 動作 |
|---|---|---|
| H-A1 ×2（兩條路都在 [0.60,1.67]） | 遙測在天花板附近**也**不佔資料面；08-20 的結論延伸成立 | 論文可寫「兩條遙測路徑都不改變 pps 天花板（一階內）」 |
| H-A2 只對 `link` | tc 取樣在資料面收費 | B 路要標一個吞吐量代價；與 softirq 的量測互證 |
| H-A2 對 `cooperative` | 08-20 的「零成本」在飽和點失效 | 🔴 更新 08-20：那句話的適用域是遠離天花板 |
| H-A3 任一 | 儀器嫌疑 | 先查 `none` 是不是真的 none、loss 口徑、產生器上限；查不出來才當發現 |
| H-A0 任一格 | 一階內不可分辨 | 報兩臂值，不報比值；更細的梯子是**另一輪**的事 |
| H-B1 | twin 在 8 s 視窗上是 shot-noise 限制的無偏估計 | 準確度可以用 1/√λ 講 |
| H-B2 | twin 有系統性偏差 | 🔴 報帶號偏差；`ndt check` 的 ok 帶（0.5–1.5）**不是**準確度陳述這件事要在 FINDINGS 再說一次 |
| H-B3 | `link` 的誤差來自樣本遺失 | emitter 的 drop 計數是機制證據；tune `trunc`／buffer 是另一輪 |
| H-B4 落外 | 兩條路的觀測品質不可互換 | 哪一條當 BYO 預設要看這一格（Adam 裁） |
| H-C1 | 08-20 重現 | 「遙測成本固定」升級成跨 fabric 的敘述 |
| H-C2 | 08-20 的固定成本是大 fabric 的產物 | 🔴 08-20 的結論要加適用域 |
| H-C3 | 拿到 (F, m) 的分解 | **最有資訊的結局**；直接報分解 |
| H-C0 | 解析度不足 | 報散佈；更長的視窗是另一輪 |

---

## 10. 這一輪**不能**宣稱的東西（先寫）

1. **任何關於「外來 pipeline ＋ include `ndtwin_telemetry.p4`」的成本或準確度。**
   本輪的 `cooperative` 組是 NDTwin 自己的 pipeline。§9 裁定 7 新增的那一格
   （`--app <含 include 的 package> --telemetry cooperative`）是 live 清單的事，不在本輪。
2. **任何 stock build 的比值**（§8(c)）。
3. **任何其他 fabric 大小、其他主機數、其他路徑長度、其他取樣率的推論。** 本輪掃的是遙測來源這一軸。
4. **「遙測完全不要錢」**：`external`／softirq 那一塊只在門檻之上被看見，不是「沒有其他負載」。
5. **一個精確的 pps 數字**：格值解析度是 ±1 階（實現步距 1.667×）。
6. **`none` 組的取樣誤差是 0**：它沒有讀數（§5.2）。

---

## 11. 交件、raw 與圖

- 目錄 `doc/audit/2026-09-19_telemetry-three-groups/`：
  `PREREG.md`、`drive_e.sh`、`run_group_arm.sh`、`sample_error.sh`、`cpu_arm_probe.py`、
  `analyse.py`、`plot.py`、`FINDINGS.md`、`tests/`、`raw/`。
- **raw 進 `audit-raw` orphan branch**（`.gitignore` 已擋 `doc/audit/**/raw*`）；
  宣稱口徑與 raw 存檔不可協商。
- **圖三張**（`.png`＋`.pdf`）：`fig1_pps_ceiling`、`fig2_sampling_error`、`fig3_cpu`。
  🔴 圖上**只有標題、軸標、刻度標籤、數值標籤**。方法、但書、對帳、條件差異一律在 FINDINGS.md。
  系列身分放在刻度標籤或線末標籤，**不放圖例文字塊**。
- **實跑由 orchestrator。** 本 worker 不 sudo、不 `ndt up`、不碰 lab、不跑任何一臂；
  腳本只需要 `ndt` 既有的 sudoers 授權（`/usr/bin/mnexec`、`/usr/local/sbin/ndtwin-lab`）。
  腳本全部有 `--dry-run`：印出計畫與**逐字的指令**，不執行。

---

## 12. 與工單 §2.8 的差異（加法，逐條說明；請 orchestrator 過目）

1. **(a) 多報一格**：工單指定 `none` 對 16.0 kpps；本檔照辦，**並列**加報
   `cooperative` 對 16.0——因為 08-28 的臂是開著合作式取樣的，條件對齊的是那一組（§8(a)）。
   兩個都報，不取代。
2. **6 個 fabric 世代而不是 12 個**：換組要重建 fabric，兩個 frame 尺寸放同一世代（§4.1），
   控制不到的部分已列出。
3. **外部 CPU 閘改成組內比、且殘差多扣 kernel／proxy／emitter**（§6）——不改會對 `link` 組整組開火。
4. **CPU 只取梯子臂**（§5.3 紅字）——取樣誤差視窗自帶 4 Hz poll，會把 kernel 服務我自己的儀器算進處理成本。
5. **不改 `tools/test_workflow/cpu_probe.py`**，改在本目錄寫 `cpu_arm_probe.py`（§3.5 的方框）。
6. **每一臂加兩條會讓臂作廢的遙測在／不在斷言**（§2.1）——08-20 的撤回那一格。
7. **softirq 單獨記錄並逐組報**（§5.3）——`link` 的資料面成本歸屬不到任何 pid。

**[Co-developed with claude code -- Adam]**

---

## AMENDMENT-1 — samples/s 的軸、ladder 臂的遙測在／不在怎麼證、driver 的四項要求

**2026-09-19 由 orchestrator 核准 PREREG（`eebf9054`）後、寫腳本之前註冊。附加，上文一字未改。**

**修訂資格（08-28 AMENDMENT-1 的三條，逐條）**

| | 狀態 |
|---|---|
| 本輪零封包 | ✅ `raw/` 仍不存在，沒有任何一臂跑過 |
| 理由只引既有資料 | ✅ 引工單 A 的計數器語意變更、08-20 的 `POLL=off`、B 的 emitter log 形狀；**沒有一個來自本輪** |
| 只收緊 | ✅ 指定一個原本沒指定的軸、把一條原本靠 twin 的斷言換成成本更低且在梯子臂上真的做得到的來源、加四項 driver 的拒絕與清理條件 |

### A1.1 samples/s 的軸＝`addressed_total` 增量，且 `samples_by_family` 並列

§5.3 的橫軸 `S(k)` 與 §5.2 的 `N` 校核都用 **`GET /ndt/get_sflow_stats` 的 `addressed_total` 增量 ÷ 秒**。

🔴 **這個計數器的語意在工單 A 併回後會變**：A 之前它只數 IPv4 TCP/UDP/ICMP 的樣本，
A 之後它數**每一個**格式正確的 flow sample（ARP、LLDP、IPv6、非首片段都算進去）。
本輪跑在 A 之後，所以軸就是「所有樣本」——這正是要的口徑（遙測成本跟著樣本走，不跟著能不能解出五元組走）。

⇒ 每一臂、每一個視窗的前後各存**整份 `get_sflow_stats` 文件**（`sflow_before.json`／`sflow_after.json`），
`analyse.py` 從中取增量：`addressed_total`、`rx_total`、`sock_ovfl_total`、`app_drop_total`，
**以及 A 新增的 `samples_by_family {ipv4, ipv6, l2, undecodable}` 與 `malformed_ipv4_ihl`**。
`samples_by_family` 的增量**逐組印在 CPU 表旁邊**——ARP／LLDP 的貢獻要**看得見**，不是被假設掉。
（分析器在頂層與 `telemetry_health` 兩層都找這些鍵，並記下在哪一層找到：A 的放置位置本 worker 沒看過碼，
不猜；找不到就寫 `absent`，不寫 0。）

### A1.2 梯子臂的遙測在／不在，改用 `get_sflow_stats`，不用 twin

§2.1 的兩條作廢斷言原本都寫成 twin 讀數。**在梯子臂上那會跟 §5.3 打架**：twin 的
4 Hz poll 由被量 CPU 的那個 kernel 行程服務（08-20 的 `POLL=off`）。改成：

| 臂種類 | 遙測「不在」（`none`） | 遙測「在」（`cooperative`／`link`） |
|---|---|---|
| **梯子臂** | `addressed_total` 增量 **== 0**（`rx_total` 增量也記） | `addressed_total` 增量 **> 0** |
| **取樣誤差視窗** | 上列 **＋** 視窗內 twin 非零讀數計數 **== 0** | 上列 **＋** on-path 邊至少一個非零讀數 |

kernel 自己數到的樣本數是比 twin 更直接的證據（twin 是它的下游），而且梯子臂上一臂只要兩個 HTTP 請求。

### A1.3 driver 的四項（orchestrator 指定）

1. **`--only G<n>` / `--only C<n>`**：重跑單一世代或單一控制臂——§7 的重跑規則需要它。
2. **raw 目錄以 UTC 命名**：`raw/<YYYY-MM-DDTHHMMSSZ>_<label>/`。
3. **開跑前拒絕**：`p4_proxy/mininet/telemetry_override`、`p4_proxy/mininet/app_package_override`
   或 `/tmp/ndtwin_link_telemetry.json` **任一存在 ⇒ 拒跑，什麼都不起**。
   三個都是「上一輪沒收乾淨」的證據，而它們每一個都會無聲決定本輪跑的是什麼。
4. **收工與每一條 abort 路徑**都要：knob 回到**不存在（＝auto）**、`ndt down`、lab `release`，順序同
   `live-p1/_common.sh` 的 `finish()`（`ndt release` 在 knob 還沒回位時會拒絕，所以還原不是選配）。

### A1.4 `link` 組把 emitter 的 log 收進 raw

`/tmp/ndtwin_link_telemetry.log` 會被下一次 bring-up 蓋掉 ⇒ **每一臂結束時複製進該臂的 raw**
（`emitter.log`），並取它 `k=v` 統計行的 `samples=`／`dropped_*`／`enobufs=` 增量：
那是 **H-B3（樣本掉了）唯一的機制證據**，計數器為 0 時不准做那個歸因（§5.2 紅字）。

### A1.5 samples/s 逐階量（不是逐 rep、不是算出來的）

§5.3 的擬合橫軸是 samples/s，那個量**必須量到**——用「offered pps × 假設的 1/256」會把模型
放進擬合的兩邊。⇒ `run_group_arm.sh` 每一**階**（不是每個 rep）讀一次 `get_sflow_stats`，
存成 `sflow_rung<k>_{before,after}.json`；`S(k) = Δaddressed_total ÷ 該階的秒數`。
一階一個 HTTP 請求 ≈ 0.04 req/s，比 08-20 的 `POLL=off` 要拿掉的 4 Hz poll 低兩個數量級；
仍然是被量的那個行程在服務，所以是逐階不是逐 rep。

**[Co-developed with claude code -- Adam]**
