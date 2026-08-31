---
name: ovs-bandwidth-ceiling-measured
description: "🔑 08-27 工單 N 實測：拿掉接取層 `bw=` 之後單一核心鏈路 **53.1 Gbit/s**（10 G 超標五倍），瓶頸從 tc 整形換成 CPU；並推翻我自己「10 G 拓樸上構不到」那條"
metadata: 
  node_type: memory
  type: project
  originSessionId: bfb90c75-a7ee-41b9-91e0-48f870a0ed59
  modified: 2026-08-28T12:29:56.806Z
---

2026-08-27 工單 N（教授指定）。全文＝`PREREG.md` 的「預註冊：工單 N」與增補 N-1…N-4，
commit `cc39bd4`／`7260093`／`b2c5808`。

## 結果

| | N-0（未改） | **N-1（拿掉接取層 `bw=`）** |
|---|---|---|
| 最大單一核心鏈路 | 1.015 Gbit/s | **53.142 Gbit/s**（52×） |
| 八條合計 | 3.628 | **121.934** |
| aggregate busy | 35.1%（0/14 核 ≥95%） | **98.7%（14/14）** |

✅ **10 Gbps 打得到，超出五倍**，且 N-1 跑在 VM 離場之後。
🔴 **推翻 [[ovs-testbed-bandwidth-reality]] 的「10 G 拓樸算術上構不到、換機器也一樣」**
——那條的前提是接取層 `bw=1000` 還在；拿掉之後前提消失。**束縛是接取整形，不是接線。**
🔑 **瓶頸換人了**：tc 整形 → **CPU**。53.1 是「這台機器 14 核跑滿」的數字。

## 🔴 08-28 晚讀原始檔（`n0.out`／`n1.out`）：**那八個數字是實測吞吐，不是容量**

檔案自己逐字寫著，而我們把它畫成一張叫 *ceiling* 的圖用了一整天：

```
--- per-core-link rate over 54.5s (interface counters, not iperf3) ---
MAX 53.142 Gbit/s   TOTAL 121.934 (all eight core links together)
ECMP split across the top four: 53.14, 27.77, 24.24, 16.74
```

- 🔴 **八條同類鏈路差約 9000×（53.1 → 0.006）不是容量差，是 ECMP 分流。**
  低的那四條**不是天花板，是那一輪幾乎沒有流量經過**。畫成 bar 放在 ceiling 圖上會被讀成
  「這些鏈路差 9000 倍」，**而那是假的**。
- **53.1 這個讀數站得住**（`n1` 標 SATURATED、14/14 核 ≥95%，不是「剛好只跑這麼多」），
  🔑 **但它是「主機 CPU 的天花板經 ECMP 分給最大那條的份額」，不是那條鏈路的天花板。**
  （對照：`n0` 明寫 NOT SATURATED，所以 1.015 是 shaper 的限制值，那個才是真的限制。）
- **109×（vs bmv2 486 Mbit）兩邊聚合單位不同**：OVS 側＝**32 條流、單一鏈路**；
  bmv2 側＝**單一條流**。原 footer 誠實揭露了 bmv2 那半、沒揭露 OVS 那半，已補對稱揭露。
- 📌 **而 109× 是所有可得框架裡最保守的**：同單位比（全 fabric 121.9 G ÷ bmv2 16 流 0.048 G）
  約 **2540×**。**作者挑了小的講，不是灌水**——指出這個缺陷時要一起講，
  否則讀起來像抓人灌水。**「數字沒問題、框架有問題」這兩件事要分開。**

⇒ 9/03 那張圖的標題已改成 **`A working point from one plane means nothing on the other`**，
**109× 整個移出標題與徽章**（Adam 裁）：任何比值都會把兩個聚合單位不同的量放在一起，
而**不可轉移性這個結論不需要比值就成立**。相關：[[ratio-sides-must-share-a-population]]。

## 🔴 我的預測錯 7×，而錯法有機制

事前寫死 N-1 ∈ **3–8 Gbps**，實測 **53.1** ⇒ 落在預註冊的「第四種結果」格。
**我把 veth 當成有硬體級成本的東西，它其實是記憶體複製，沒有線速可言。**
方向那半（瓶頸會變 CPU）成立。

## 🔑 三個可重用的方法

1. **兩個儀器對帳前先問分母**：iperf3 自述 220.96 G（分母＝各流的 30 s）對介面計數器
   121.93 G（分母＝視窗 54.5 s）。`220.96×30/54.5 = 121.6` ⇒ 差 **0.3%**。
   換成同母體才發現它們其實吻合，而且順帶證明視窗裡只有 ~30 s 在傳輸
   ⇒ **53.1 是保守的視窗平均**。相關：[[ratio-sides-must-share-a-population]]
2. **要量「單一鏈路」就讀每介面計數器**：ECMP 實際分成 1.01/0.99/0.81/0.81 四條
   ⇒ **單一鏈路 ≠ 總量 ÷ 任何我選的數**。
3. **注入自證＝跑著的具名介面上 qdisc 真的變了**（`htb`→`noqueue`）。
   ⚠️ 裸 `sudo -n tc qdisc show` **會被 sudoers 拒絕，而拒絕的輸出讀起來就像「沒整形」**（實測）。

## 🔴 這輪最貴的坑：改到不會被執行的那份檔

`ndtwin-lab:78-84` 跑的是 **`~/Network-Traffic-Generator/testbed_topo.py`**，
**不是** repo 根目錄那份 `./testbed_topo.py`（兩份內容不同、但 `bw=` 行相同）。

⇒ **若改 repo 那份**：`git status` 會顯示我改了、還原紀律滿分、**而 fabric 一個位元組都不會變**
⇒ N-1 會等於 N-0，最自然的讀法是「接取整形不是瓶頸」
⇒ **一個漂亮、可發表、完全錯誤的結論，而所有紀律檢查都是綠的。**
🔑 **紀律本身變成偽裝。** 同族第三例（前兩例：`ndt up` 不重編 `.p4`、bmv2 握舊 JSON）。

## 🔴 還原的判準是 **sha256，不是 `git status` 乾淨**

| 版本 | sha256 |
|---|---|
| **動手前的磁碟狀態（＝還原目標）** | **`ead4d84a…`** |
| `git HEAD` | `50f9bb17…` |

磁碟上有一份 **7/8 的環境修補**（`sys.path.append` ×2 等），**不在 HEAD、也不是我的**
⇒ `git checkout` 會還原到「七月以來沒有任何量測用過的狀態」。
⇒ **在這裡 `git status` 乾淨代表弄錯了**（應仍顯示 ` M testbed_topo.py`）。
**還原用 `cp` + sha256，並另外確認別人的三個未提交改動還在。**

## 未完成

**診斷 A（twin/veth 每格）註冊了但我沒採集**——`n_cell.sh` 沒接上
`poll_twin.sh`/`poll_veth.sh`。⚠️ 之後補做時，`ratio` 與 `per-edge min` **是相鄰欄**，
照增補 N-1-1 的三步防呆（自算→斷言→對不上就停）。

相關：[[ovs-testbed-bandwidth-reality]]、[[injections-must-assert-their-own-success]]、
[[failures-that-report-success]]、[[verify-against-known-good-output]]

---

## 🆕 診斷 A 補做（08-27 16:15–16:19）：**分身被自己宣告的鏈路容量夾住**

| | veth（地面真值） | twin（自述） | 比值 |
|---|---|---|---|
| 176 條負載邊合計 | **1138.4 GB** | **5.5 GB** | **0.0049**（少報 99.5%） |

**荒謬值 ⇒ 先當警報去查機制**，查出來的是：

| 量 | 值 |
|---|---|
| twin 最大單邊回報 | **1.000 Gbit/s** |
| 該邊 `link_bandwidth_bps`（宣告容量） | **1.000 Gbit/s** |
| 同時線上實測 | **22.0 Gbit/s** |

🔑 **最大值不多不少正好落在宣告容量上＝夾制的簽名。**
⚠️ **我沒讀到做這件事的那行碼** ⇒ 記成「與夾制高度一致的觀察」，**不是已證實的機制**。
**決定性下一步**：找 kernel 裡寫 `link_bandwidth_usage_bps` 的地方，
看有沒有對 `link_bandwidth_bps` 取 min。

🔴 **這不是①的重現，不可混談**：①（P4、1/256）少報 34%，工作點**遠低於**容量＝**精度流失**；
這裡少報 99.5%，只在**超過**宣告容量之後發生＝**表示能力的天花板**。**兩個不同現象。**

## 🔴 儀器會被它要量的東西餓死

飽和格（32 流、14/14 核滿）**採集不到**診斷 A：`poll_veth.sh` 每 2 s 掃 160 個介面，
排不到 CPU ⇒ sweep 間隔實測 `2.3, 2.8, **24.7**, 8.4, 2.3…`，空洞正好落在流量開始的當下。
`analyze.py` **正確拒絕**：「one of the two streams is empty. Absence of a discrepancy in an
empty comparison is not evidence.」
⇒ **在這台機器上，twin/veth 對帳與「把資料面推到飽和」不能同時做**（用現有 poller）。

## 🔴 又一次：有 selftest 的工具贏過我臨時寫的 parser

我的一次性檢查讀 `usage_bps`／`usage` ⇒ 回報「0 條邊有 usage」，
而 `analyze.py` 同時說 twin 有 5.5 GB。**矛盾 ⇒ 錯的是我**，真正欄位是
**`link_bandwidth_usage_bps`**。⇒ **兩個工具打架時，預設自己錯。**
相關：[[verify-against-known-good-output]]

## 吞吐的變異

同條件重跑：**53.142 → 61.377 Gbit/s（+15.5%）**。**兩次都記，不挑。**
⚠️ 8 條 TCP 流（`-P 4` ⇒ 32 stream）**仍然把 14 核打滿** ⇒「流數少」不等於「負載低」。

---

## 🔴 08-27 同一組實驗的第二個發現：**分身看不到那 53 Gbit/s**（機制已指認，兩條路徑）

「資料面跑得到 53–61 Gbit/s」與「**分身量得到** 53–61 Gbit/s」是兩句不同的話，**第二句是 false。**

實測（診斷 A，OVS 飽和）：176 條負載邊 veth **1138.4 GB** vs twin **5.5 GB**（少報 **99.5%**）；
**twin 最大單邊回報 1.000 Gbit/s ＝ 該邊 `link_bandwidth_bps`**，而線上實測 **22.0 Gbit/s**。

### 機制：**沒有任何路徑不夾**（不是「某條路徑會夾」）

| 路徑 | 夾在哪一行 |
|---|---|
| flow-sample | `TopologyAndFlowMonitor.cpp:1089-1095`：`estimatedIn > linkBandwidth ⇒ leftIn = 0 ⇒ usage = linkBandwidth` |
| counter | `:1057` 本身無夾制，但 `leftOut` 是參數 ⇒ 唯一呼叫者 `FlowLinkUsageCollector.cpp:1184` ⇒ 該檔 **`:1163`** `leftOut = (avgOut > interfaceSpeed) ? 0 : …` ⇒ **夾在上游** |

⇒ **`linkBandwidthUsage` 在結構上永遠不可能超過該邊的宣告容量。**

### 🔴 更容易在台上被誤讀的那一條
同兩行把 **`linkBandwidthUtilization` 一起夾在 100%**（`leftIn = 0 ⇒ (1−0)×100`）
⇒ **「使用率 100%」不代表滿載，只代表「≥ 宣告容量」**——可能是滿載，也可能是 20 倍。
**一個所有人都以為自己懂的數字，實際上是被截斷的訊號。** 要與 usage 那條分開講。

### 明確未定 / 未答
- **是 bug 還是設計未裁**：「剩餘頻寬不能為負」是合理的模型約束，只是**沒人想過流量會超過宣告容量**
  ——而在拿掉接取層 `bw=` 之前那確實不可能發生。**該不該改留給 Adam。**
- **哪條路徑在什麼模式下被呼叫**：未追（降級為 refinement，因為兩條都夾 ⇒ 頭條不受影響）。
- ⚠️ **同一個欄位兩個寫入者**：若兩條路徑同時活著，對同一條邊可能給出不同答案
  ——[[replace-vs-add-bug-shape]] 的近親，**記下風險，未證明發生過**。
- **完全閒置的邊讀什麼沒量**（不排除真正閒置⇒0，那本來就正確）。

### 🔴 這**不是** [[large-scale-concurrent-never-measured]] 那個 34% 的重現
- ① ＝ **容量以下**的精度流失（34%）
- 這裡 ＝ **容量以上**的表示天花板（99.5%）
**兩個不同現象，不得合併。** 兩個 session 各自獨立守住了這條線（`23daa45` / `739d9f7`）。

### 附帶：飽和時 twin/veth 對帳**取不到**
`poll_veth.sh` 每 2 s 掃 160 介面，14/14 核滿載時排不到 CPU ⇒ sweep 間隔出現 **24.7 秒空洞**
且正好落在流量開始當下；`analyze.py` 的守衛**正確拒絕**出數字
（"Absence of a discrepancy in an empty comparison is not evidence."）。
⇒ **儀器被它要量的東西餓死**。要取得需換 poller 形式（一次 read 全部 / `nice -n -20`）。

---

## 🆕 08-27 尾聲：poller 修好了（工單 S 前置），**但飽和自證未做**

**診斷：問題不是「讀取」，是「行程生成」。** `poll_veth.sh` 對每介面開**兩個 `cat`**
⇒ 160 介面 ＝ **每 sweep ~320 次 fork+exec**；滿載時那些 spawn 排在負載後面。

| | 每 sweep 耗時（閒置實測） | 每 sweep 行程生成 |
|---|---|---|
| 舊 `poll_veth.sh` | **0.221 s** | **320** |
| 新 `poll_veth2.sh`（讀 `/proc/net/dev`，一個 `awk`） | **0.0012 s** | **1** |

🔑 **這個量測順帶解釋了那個 24.7 s 空洞**：舊的**閒置時**就要 0.221 s，
滿載慢 ~110× 就超過 24 s ⇒ **與實測吻合**。新的即使慢 100× 也只有 0.12 s。

- **正確性已驗**：160 介面、與 `/sys/class/net/*/statistics` 對得上；
  **輸出格式與舊 poller 逐欄相同 ⇒ `analyze.py` 不必改。**
- 🔴 **寫成新檔不是改舊的**：`poll_veth.sh` 當時**正被 mainDev 的工單 P 佔用**
  （pid 737004、cell `P_B14`、380 s）⇒ **改別人正在跑的腳本 ＝ 汙染他那一輪。**
- 🔴 **`nice -n -20` 走不通**：負 priority 需 `CAP_SYS_NICE`，
  本機 sudoers 只授權固定清單（`ndtwin-lab`／`ovs-vsctl`／`ifconfig`／`mnexec`／
  具名 `tc`／`ndtwin-p4-power`）⇒ **`renice`／`chrt` 都不在**。
  **行程生成那個修法單獨就夠，所以沒申請。** 記下來免得下一個人重推。
- ✅ **飽和自證已完成（08-27 夜，21:25–21:41）**，先前停在這裡的理由
  （[[lab-claim-handoff-protocol]] 的「不佔實驗室 ≠ 不佔機器」）**在審查員把機器讓給我之後消失**
  ——**是理由消失，不是判斷錯了。**

  **三臂共用一份負載**（28 個純 CPU 自旋 / 14 核）：新 poller → **舊 poller（控制組）** → 新 poller。
  | 臂 | sweeps | p95 | max | ≥3 s |
  |---|---|---|---|---|
  | 新 | 57 | **2.195** | 2.22 | **0/56** |
  | **舊（控制）** | 15 | **11.531** | 11.53 | 14/14 |
  | 新（重跑） | 57 | **2.189** | 2.21 | **0/56** |

  三臂環境皆 **99.9% 聚合、14/14 核 ≥95%**；順序效應 0.006 s。

  🔴 **第一輪 FAIL，而否證的是我自己註冊的推理**（v1 時間戳 `awk systime()` ＝整秒
  ⇒ p95 正好 3.000 對門檻「< 3.0」）⇒ **修儀器不動門檻**，
  ts 改 `date +%s.%N`（每 sweep 2 次行程生成 vs 舊的 ~320）。詳見
  [[instrument-must-not-mimic-its-own-finding]] 第七形式。

- 🔴 **自證沒有證明間隔精準到 2.000 s**：實測**系統性偏高 0.10–0.13 s**（週期約 2.10 s，偏差 5%）
  ⇒ **開窗口不要用「sweep 數 × 2」算秒數，要用實際時間戳的頭尾差**（120 s 的窗會少算約 6 秒）。

## 🆕 工單 S（在途，未開跑）——為什麼它存在

Adam 兩則指示（「測 bmv2 上限」＋「大規模測試包含數 Gbps」）併成一題。
🔑 **理由**：**所有既有的大規模準確度數據都量在遠低於宣告容量的區間**（每流 0.1M–20M）
⇒ **夾制從沒被觸發過** ⇒ **「分身在規模下高報 3–24%」只在低速率成立**，
容量以上翻成**少報 99.5%**（見 [[twin-usage-clamped-to-declared-capacity]]）。
**同一個系統、兩個相反結論，差別只在工作點。**

階梯（固定 16 流、只變速率）：S1 20M（錨 `p4_T16nt`）→ S2 100M → S3 300M → S4 600M → S5 上限探測。
**P4 平面不需改任何檔**（`p4_testbed_topo.py`／`ntg_bmv2_topo.py` 零 `bw=`、無 `TCLink`）。

🔴 **我提出而尚未獲答的兩點**：
1. S1 會用**新 poller** ⇒ 與錨點 `p4_T16nt` 之間隔了一個**儀器變更**。
   建議 S1 **同時跑新舊兩個 poller**（互不干擾、都只讀 `/proc`），
   讓「對不上」當場分成「儀器造成」與「世代造成」。
2. 🔴 **P4 拓樸沒有 `bw=` 不代表模型檔宣告的容量也大**——
   **夾制看的是拓樸 JSON 的 `link_bandwidth_bps`，不是 mininet 整形**。
   開跑前應先讀 `setting/StaticNetworkTopologyP4_10Switches_128Hosts.json`，
   **那才決定夾制門檻在哪。未查。**

## 🔴 2026-08-28 範圍待證：**53.1 G 可能只對單一鏈路成立，不對跨核心的路徑**

`8/27 mainDev` 在準備拿掉 shaping 時指出：**核心鏈路（`s1-s5` 等）也是 `bw=1000`。**
⇒ **原始那次量測拿掉的是「接取層」的 `bw=`，而 53.1 G 是在單一鏈路上量到的。**
⇒ **一條跨核心的路徑（例如 h1→h65）仍然會撞到核心層的 1 G**，那條路徑從來沒有量過。

**08-28 實測佐證這個懷疑**：接取層 `bw=` 仍在的狀態下，
- h1→h65（跨核心）offered 1600 M ⇒ 送出 **967.1 M**
- h1→h2（同一台 s1、只走接取層）offered 4000 M ⇒ 送出 **965.7 M**

**兩者幾乎一樣** ⇒ 在有 shaping 時瓶頸就是那個 1 G，跨不跨核心沒差。
**拿掉之後會不會有差，未測。**

⇒ ⚠️ **不要再把這條引用成「整座 fabric 可以到 53 G」。**
成立的是：**「拿掉接取層 `bw=` 之後，單一鏈路量到 53.1 Gbit/s」**——
**要主張任何路徑層級的容量，接取層與核心層都要處理，而那是更大的改動且未做。**

🔑 一般化：**一個在「單一元件」上量到的天花板，不能當成「一條路徑」的天花板**——
路徑的容量是它最窄的那一段，而那一段可能不是你動過的那一段。
（同型：[[benchmark-must-name-the-binary-it-measured]] 的「容量是流數的函數」——
**容量從來不是一個數字，它是一組條件下的讀數。**）

## 🔴 2026-08-28 晚：**那八個數字是實測吞吐，不是容量**——原始檔自己寫著

9/03 簡報頭條 `page_bandwidth-ceiling.png` 寫「The two forwarding planes' **ceilings** differ by 109x」。
去讀它引用的 `doc/audit/2026-08-25_sampling-rounds/n1.out`：

```
--- per-core-link rate over 54.5s (interface counters, not iperf3) ---
      MAX         53.142 Gbit/s
      TOTAL      121.934 Gbit/s   (all eight core links together)
      ECMP split across the top four: 53.14, 27.77, 24.24, 16.74
ENV N1_changeA: aggregate busy 98.7% ... cores >=95%: 14/14   -> SATURATED
```

**三件事：**

1. 🔑 **圖上「同類鏈路差約 9000 倍」（53.1 對 0.006）不是容量差，是 ECMP 分流。**
   低的那四條**不是天花板，是那一輪幾乎沒流量經過**。畫成 bar 放在 ceiling 圖上會被讀成容量。
2. ✅ **53.1 本身站得住**：`n1` 明寫 **SATURATED**（98.7%、14/14 核）。
   🔑 **但那是「主機 CPU 的天花板」不是「那條鏈路的天花板」**——全 fabric 總量 121.9 G，
   53.1 是 ECMP 分給最大那條的份額。（對照：`n0` 明寫 **NOT SATURATED**。）
3. ⚠️ **109× 兩邊聚合單位不同**：OVS ＝ 32 流下單一鏈路；bmv2 ＝ **單一條流** 486 Mbit。
   footer 誠實揭露了 bmv2 那半，**沒揭露 OVS 那半**。
   📌 **而 109× 是所有可得框架裡最保守的**（同單位比：121.9 G ÷ 16 流的 0.048 G ≈ **2540×**）
   ⇒ **作者挑了小的講，不是灌水**，指出問題時要一起講。

⇒ 建議改**措辭**不改數字：`ceilings` → `measured peak`／`delivered ceiling`；
低的四根加註或不畫；footer 補上「32 流、ECMP 份額、主機 98.7% 飽和、總量 121.9 G」。

🔑 **這正是本檔上面那條但書要防的形狀**：「53.1 是單一鏈路的讀數，不要引用成整座 fabric 到 53 G」——
用 *the two forwarding planes' ceilings* 講，**距離讀者腦補成「這個平面可以到 53 G」只差一步**。

🪞 **方法論**：我沒有從圖去推，是去讀圖自己標的來源檔——**而答案就寫在檔案的字面上**
（`interface counters, not iperf3`／`ECMP split`／`SATURATED`）。
⇒ **圖上的量詞（ceiling／capacity／throughput）要回原始檔對，那三個詞在原始檔裡通常是分開的。**
