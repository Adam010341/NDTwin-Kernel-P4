---
name: ovs-testbed-bandwidth-reality
description: "Mininet 靜靜忽略 bw>1000，所以 16 條核心鏈路從未被整形（仍成立）；🔴 但「10 Gbps 算術上構不到」那半已被 08-27 工單 N 推翻，見 [[ovs-bandwidth-ceiling-measured]]"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 56cc1a30-fc20-4847-97f3-176033806b7e
  modified: 2026-08-30T07:11:48.240Z
---

全部量於 2026-08-18、kernel `04b8933`、NTG 的 128-host OVS 拓撲。原始資料在
`doc/audit/2026-08-18_live-full-stack-round/`。

## Mininet 對 `bw>1000` 是靜靜忽略，不是降級

`/usr/lib/python3/dist-packages/mininet/link.py:238`：

```python
bwParamMax = 1000        # 註解：「The parameters we use seem to work reasonably up to 1 Gb/sec」
if bw and (bw < 0 or bw > self.bwParamMax):
    error('Bandwidth limit', bw, 'is outside supported range 0..%d' % ..., '- ignoring\n')
```

`testbed_topo.py` 的 8 條核心鏈路是 `bw=10000` → **完全沒有整形**，那行 error 在
128 台主機的啟動洪流裡滾過去。實測：全新拓撲 **htb 144/160 介面**，沒有的那 16 個
**逐字就是宣告 10 Gbps 的那 16 個**。

⚠️ **`bwParamMax` 是 Mininet 自己的保守守衛，不是 tc 的極限**——tc htb 吃 `rate 10gbit`
沒問題。而 `netem` 也有 `rate`（man page 稱它是 TBF 的替代），且 `root netem *` 已在
sudoers 授權內，**所以要測 10 Gbps 整形不需要改 sudoers**。在核心介面上下 `root netem`
是安全的，正因為它們是 `noqueue`——沒有 htb 可以被取代（這是少數 `root` 形式反而正確的場合）。

## 🔴 這一整節已被推翻（2026-08-27 工單 N），保留原文只為了對照

**下面的推理錯在一個字：它把 `bw=` 這個「宣告」當成了物理上限。**
實測拿掉接取層的 `bw=` 之後，單一核心鏈路 **1.015 → 53.142 Gbit/s**（八條合計 121.9），
**超過 10 G 五倍**，瓶頸從 tc 整形換成 CPU。全文見 [[ovs-bandwidth-ceiling-measured]]。

⇒ **「2×1G 上行」不是拓樸算術，是我們自己在拓樸腳本裡設的參數。**
引用本節之前先確認你要講的是「目前組態下」還是「這台機器做得到嗎」——兩者差 50 倍。

## ~~10 Gbps 在這個拓撲裡構不到，跟硬體無關~~（已推翻，原文如下）

每台接取交換機（s1–s4）只有 **2 條 1 Gbps 上行**。所以聚合交換機 s5 朝下最多收 2 Gbps，
再分給 s5→s9 / s5→s10 兩條核心鏈路 → **單條核心鏈路上限 ~2 Gbps，離 10 Gbps 差 5 倍**。
換多快的機器都一樣；要撞到得改拓撲（s5 底下掛更多接取交換機）。

實測（每輪 15s、iperf3）：

| 配置 | 聚合 |
|---|---|
| s1→s3（4 對，受 s1 的 2 Gbps 上行限制） | 1.91 Gbps |
| s1→s3 + s2→s4（8 對，**過核心**） | 3.39 Gbps |
| s1→s2 + s3→s4（8 對，**不過核心**） | 3.81 Gbps |
| s1→s3，核心先套 `netem rate 10gbit` | 1.88（未套時 1.75）＝雜訊內 |

⚠️ **第一版量測被混淆過**：兩輪都從 s1 出發，撞到 s1 自己的 2 Gbps 上行，
所以「核心沒差」其實是「根本沒量到核心」。加第二個來源（s2）才分得開。

## 🔴 2026-08-19：電源循環還會掉 **sFlow 紀錄**，那比掉整形嚴重得多

A/B 實測（round 6，n=2）：電源循環後 **s3→s8 鏈路在實際承載 103 Mbps 時讀值恰好 0 bps**；
手動補回 bridge 的 sFlow 紀錄後讀到 106–148 Mbps。
⚠️ 機制比預測的窄：**去樣本化的那台交換機是「進來的邊」變暗，不是出去的邊。**

**0 bps 與「閒置」無法區分**，而這個值會進到 graph，Energy-App 的關機決策從 graph 上算
⇒ **「電源循環過的交換機會讓自己更容易再被關掉」，這個結論成立。**

🔴 **2026-08-29 更正機制歸屬（結論不變）**：原文寫「配上 F-17 那條『閒置時回 0.0 會觸發關機』」
——**掛錯函式了**。關機決策讀的是 app 自己的 `group_avg_link_utilization`（走 graph，＝ A-4b 的路徑），
**不是** F-17 的 `get_average_link_usage` 端點（那個端點的 client 在 ESA 裡零呼叫端）。
⇒ **要疊的是 A-4b，不是 F-17。** 細節見 [[live-round-2026-08-18-two-passes]] 的二次更正
與 [[existence-is-not-wiring]]。**機制被否證 ≠ 結論被否證**，這條就是活例。

## 電源循環會掉整形，但只有 4 個介面（⚠️ 128-host 拓撲；4-host cell 是 2 個）

關再開 s5/s7/s9 之後 htb 從 144 → **140**。掉的正是 `s5-eth1/2`、`s7-eth1/2`
（那些是 1 Gbps 鏈路；s9 四個埠全是核心，本來就沒有）。**對端不受影響**
（`s1-eth1` 兩次量都是 `htb 5: root`），所以效果是**單向的**。
`OVSPowerStrategy::powerOff` 存了 port 清單但沒存 qdisc，`powerOn` 加回 port 沒補整形。

## TE 正常運作——不要重犯這個推論錯誤

我曾據此推論「核心不會壅塞 → TE 對核心是瞎的 → TE 是裝飾」。**錯。**
TE 工作在 1 Gbps 層，而那裡真的會爆：實測 `congested link 8 -> 3`、
單一 elephant flow **749 Mbps / 1 Gbps = 74.9%** 越過 `congested_threshold = 70`，
同一輪 **15 輪實際裝了規則**。TE 只是從不重排「核心」的 ECMP 群組。

`Traffic-engineering-App.py` 的閘門：壅塞是外層 `if`，ECMP 不平衡偵測在裡面；
下行鏈路查不到 ECMP 候選是**正確行為**（139 次裡 67 次有候選，空的都是下行）。

相關：[[bmv2-scale-ceiling-and-sflow-sample-math]]（bmv2 側的對應限制）、
[[live-round-2026-08-18-two-passes]]、[[arithmetic-that-fits-is-not-the-mechanism]]。

---

## 🔴 08-27 更新：「10 Gbps 拓樸算術上構不到、換機器也一樣」**已被實測推翻**

那句話的**前提是接取層的 `bw=1000` 還在**（每台 Agg 只被兩條 1 G 邊緣鏈路餵 ⇒ 硬上限 2 G）。
工單 N 把接取層的 `bw=` 拿掉之後，**單一核心鏈路實測 53.1 Gbit/s**（10 G 超標五倍），
瓶頸換成 CPU（14/14 核跑滿）。

⇒ **束縛從來是「接取層的整形設定」，不是「接線」。** 完整內容與方法
→ [[ovs-bandwidth-ceiling-measured]]。

**本檔其餘部分仍然成立**：Mininet 靜靜忽略 `bw>1000`（實測 32 行
`Bandwidth limit ... ignoring`）、16 條核心鏈路從未整形（`noqueue`）、
「OVS 只跑得到 ~40 Mbps」是**設定不是天花板**（`ovs_condA` 的 `target_bitrate` 逐檔＝0.1/0.5/2 M）。

## 🆕 08-30：OvS 同梯對照輪量到的四個測試床事實（正本 `doc/audit/2026-08-30_ovs-flowcount-control/FINDINGS.md`——**讀更正版**，`71e482e` 初版的歸因已被 08-30 傍晚驗收更正）

1. **`ndt up ovs` 只能建 128（或 `ovs4`＝4）**——`setting/` 的 `OVS_*Hosts.json`（≤64）是
   **kernel 靜態模型不是 fabric 尺寸**；我照它們推「OVS 最大 64」被 ndt 當場拒絕（AMENDMENT-1，
   零資料前修正）。🔴 更正：fabric 建造器＝**NTG repo 的** `/home/adam/Network-Traffic-Generator/testbed_topo.py`
   （`ndtwin-lab:83` 指名執行；HOST_NUM=128）——**kernel repo 的同名副本不參與 fabric**，
   我 patch 它＝no-op（教訓入 [[benchmark-must-name-the-binary-it-measured]]）。
2. 🔴 已推翻「有機天花板」：**OVS fabric 是 as-configured 1 G-shaped**（NTG 檔 access＋leaf-mid
   `bw=1000` htb、spine `bw=10000` 被 Mininet 忽略）⇒ ~0.96 Gbit 送達天花板＝**htb 1 G 帽的
   goodput 上限（1000×1400/1442≈971 Mbit）**，不是 datapath/veth 有機極限（無 shaping 的
   OVS fabric 天花板**從未量過**）。位置在 fabric 側不是 socket 這半句仍真（n≥4 RcvbufErrors
   僅 199–3.6k）；**單流收端 socket ~540–810 M 極限**（RcvbufErrors 44–48k）仍真。
   對照組 bmv2 的 fabric（`ntg_bmv2_topo.py`）**無 bw=＝unshaped**——兩 builder 的 shaping 不對稱。
3. 🔴 **發送端假象改名：htb 帽壓制（原記「veth 回壓」＝錯歸因）**：offered＞帽時（n≤4）
   iperf3 UDP 發送端被 h1 access htb 壓到 ~960 合計、**offered≠sent 而 loss 讀 clean**——
   名目「810 M/流 clean」實為 240。**validity 判準必備：`agg_sent ≥ 0.95×n×offered` 逐階逐臂**
   （此判準是 auditor 於跑完後要求補的＝事後）；n=16 反而推得滿（同帽下兩種發送端行為、機制未定位）。
   loopback gate 抓不到這個（不經 datapath）——下輪 gate 要量「經 datapath 的可施加率」。
   另records：driver 的 `tc | grep -c htb` 兩次讀 0＝**假陰性**（08-28 jitter 輪同 fabric 讀得到 htb；
   機制待 live 釘死）——不要拿這行當 shaping 狀態的斷言。
4. **port 區分的 n 流 h1→h65 全走同一條 5-switch 路徑**（全 switch 計數器：s1/s6/s9/s7/s3
   各 7.26 GB、其餘靜默＝零 ECMP 散佈；「Ryu 等效 dst-based」是由此的推論、未讀 Ryu 碼）。
