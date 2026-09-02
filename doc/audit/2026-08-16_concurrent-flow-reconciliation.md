# 並發流對帳補測(2026-08-16 凌晨)

> 🔴 **2026-09-03 更正（auditor）：本文件中所有取自
> `estimated_..._proceeding_1sec_timeslot` 的絕對數值作廢，包括 `:73` 的
> 「積分 = 4.49 GB = 3.46×」。** 原因與本輪的分析無關：該欄位在
> `FlowLinkUsageCollector.cpp:1934/1952` **從未除以經過時間**，所以回報值 ＝ 真值 × 迴圈週期 T，
> 而 T > 1 且隨負載變長（實測 1.04–1.25 s）。**這不是可事後換算的固定倍數**——每個讀數要用它
> 當下的 T，而 T 只出現在 `kernel.log`、每 30 次迴圈才印一次。修法在分支
> `fix/flow-rate-denominator`，說明見 `doc/audit/2026-09-02_live-round/FLOW-RATE-DENOMINATOR.md`。
> **本文件其餘不依賴該欄位絕對值的結論不受影響**；要沿用 `:73` 那個積分必須重新推導。

> 三判官一致排序的頭號補測缺口(`2026-08-15_acceptance-judgments.md` 可行動輸出 #6:
> 「並發對帳 > 寫入路徑 > 多速率 > 故障矩陣」),外加同檔 #1(3c 修復)與
> 3f 的 59-vs-10 double-counting 反核。全程 agent 自駕(wrapper + stack.sh + NTG bridge),
> Adam 不在場。原始數據:兩輪 poller JSONL + NTG console 快照(session scratchpad,
> 關鍵數字全數載入本檔);分析器 `analyze_run.py` 同在 scratchpad,方法見 §0。

## 0. 方法

`ndtwin-lab topo-start`(10 bmv2 + NTG CLI)→ `stack.sh up p4` → NTG
`flow --config`(varied 1 flow/s far-only:50% TCP 1MB@4M、50% UDP 2M×10s;
fixed 3×8M TCP)→ 三路獨立取數,每 2s 一次、跨全程:

1. **Ground truth**:root ns 全部 36 支 `sN-ethM` veth 的 rx/tx bytes(kernel NIC 計數器,
   在 twin/proxy/bmv2 記帳之下)。
2. **Twin per-edge**:`/ndt/get_graph_data` 的 `link_bandwidth_usage_bps`,對時間積分成 bytes。
3. **Twin per-flow**:`/ndt/get_detected_flow_data` 全文(含 5-tuple、兩個 rate 欄位、path)。

另每 15s 抓 NTG console(對齊牆鐘,重建 NTG 側的 running count 與完成事件)。
對映:twin 邊 `sN:ifM→X` ↔ `sN-ethM` 的 tx delta;`X→sN:ifM` ↔ rx delta。
方法紀律:取樣量測走 kernel 量子法/veth,不碰 `Δ[255]/Δ[1]` 比率法(撤回案白名單)。

**Round 1**(02:36:41–02:45:47,head `fe07ed5`,修復前 baseline):預設
`flow_bmv2_low.json`(fixed duration 270s)。305 秒 interval、~300 條 varied +
fixed 兩代 6 條,twin 瞬時清單峰值 63 條、NTG 同時運行 ~16-21。
**Round 2**(03:07:12 起,head `e86cb4d`,修復後):同構 config、fixed duration 縮為
60s(讓重啟尾巴短到可完整觀測排水)。

## 1. Round 1:per-edge 對帳(修復前 baseline)

430s 全窗積分,單位 bytes(idle 邊 <200kB 不列)。`twin/veth` 為比值:

| 邊類 | veth 總計 | twin 總計 | 比值 | per-edge 範圍 |
|---|---|---|---|---|
| host→switch(4 條) | 1,298,774,347 | 1,341,695,366 | **1.033** | 0.936–1.083 |
| switch→switch(14 條) | 4,846,603,620 | 4,980,542,156 | **1.028** | 0.929–1.182 |
| switch→host(4 條) | 1,279,734,185 | **0** | **0.000** | 全 0 |

**結論**:並發 13-21 條流之下,**凡有取樣者的邊,twin 記帳與 ground truth 的總量誤差
只有 +2.8%~+3.3%**,per-edge 散佈 ±7%~±18% 與 1/256 取樣的 Poisson 噪聲一致
——三判官擔心的「並發下對帳崩壞」沒有發生,單流窄走廊的結論撐得住並發。
唯一系統性缺口就是已知的 3c:四條 switch→host 邊對 1.28 GB 實際流量記 0,
與驗收輪的單流觀察完全同構,受害面確為 `get_graph_data` 的 per-edge 消費者。

## 2. 3f 反核:59-vs-10 解體,double-counting 排除

Fable 判官的質疑:「滯留窗」解釋與報告自己的 t+0 flows=0 矛盾,double-counting 未排除。
實測答案——**不是 double-counting,是三個因素疊加**:

- **零重複 5-tuple**:188 次 poll、620 個不同 5-tuple,**沒有任何一次**同一 5-tuple
  在清單出現兩次。per-switch/per-direction 重複計數直接排除。
- **TCP 反向 ACK 流各算一條**:每條 TCP session 貢獻 data + ACK 兩個真實 5-tuple。
  NTG 數的是 session(~18),twin 數的是方向性流——光這項就 ~2×。
- **滯留窗實測 p50=4s / p90=13s / max=17s**(poll 時刻 − `latest_sampled_time`):
  已結束的流在清單裡最多留 ~17s。churn 1 flow/s 下,「近期結束」份額再加一截。

Little 算術對上:NTG ~18 session × 2 方向 + ~15s 窗 × ~1 流/s 的近期結束 ≈ 50+,
與 twin 實測 44-56 吻合。**與 t+0=0 的「矛盾」不存在**:滯留 ≤17s,流量真正全停後
清單十幾秒內就空——驗收輪 polls 較晚、其流已全終,兩份觀察同時為真。
消費警語不變:**這個端點不是即時 active-flow 數**,是「近 ~15s 內被取樣過的方向性流」。

Round 1 的 tail 曾出現「+429s 仍有 6 條」——那 6 條(3 data + 3 ACK)staleness ≤1s、
veth 同窗有 8-9.7 Mbps 實流,**是 NTG fixed 流的重啟尾巴在真實傳輸,twin 誠實**
(見 §4)。

## 3. per-flow(並發下的 WARN 續篇)

- **守恆檢查**:Σ(`..._in_the_last_sec` 積分) = 1.672 GB vs 實際 offered(host→sw veth)
  1.299 GB = **+28.8% 正偏**。單流驗收 ±14% 的誤差在並發小流(大量 2M/4M)下放大且
  單向偏正。機制假說(未證):估計式為 Σ跨hop速率/活躍hop數,小流每秒常只有單 hop
  被取樣,活躍 hop 數波動 + Jensen 效應給出正偏。列 WARN,billing 級用途不可。
- **`..._proceeding_1sec_timeslot` 積分 = 4.49 GB = 3.46×**:此欄位在無樣本的秒數
  **保留前值**(SIGFPE 守衛的 hold-last 語意,`:1746` continue),對時間積分會嚴重
  高估。**消費警語:此欄位是「最近一次有樣本時的估計」,不是當下速率**,不可積分。
- **定速對照**(fixed 3×8M TCP):與 varied 混流的第一代讀 3.2-4.5M(TCP 在壅塞下
  讓速——同窗 per-edge 對帳與 veth 一致,壅塞是真的);interval 結束後單獨跑的
  第二代讀 **7.3-8.2M ≈ 8M 標稱**。並發本身沒有破壞 per-flow 追蹤,誤差來自取樣噪聲
  與真實壅塞,不是記帳錯亂。

## 4. 副產物:NTG「計數器洩漏」全案改判(撤回性更正)

Round 1 完整觀測到 08-15 結案輪「排水卡 3 永久洩漏」的真機制:
**fixed_traffic 會在流結束時重啟以維持數量**,最後一代在 interval 結束前起跑、
跑滿自己完整的 duration(270s 設定 → 300s interval 實際 ~570s 收尾;實測
02:41:41 interval 結束 → 02:45:47 `Experiment completed`,差 4:06 ≈ 270s 尾巴到秒級)。
兩輪皆自我善終、計數器歸 0、prompt 回歸,零失蹤。重啟產生新 5-tuple
(52307 的 src port 39786→41544)再次佐證。
**「成功輪也漏 ~1%」「實驗不會自我善終」作廢**;錯誤路徑回呼與 SIGINT 兩個子主張
經 12:20 的針對性重測(Adam 裁決後執行)**也全數無法重現**:45 秒 kill 風暴
(process-death+connection-refused)下 183/183 流全走完成路徑、counter 排空、實驗
善終;對等待中的 NTG 送 SIGINT,12 秒內乾淨退場(訊號落點可能在運行期,誠實保留)。
NTG 稿第 1 條已定稿為 docs/UX 回報(重啟尾巴無文件+等待訊息不透明),
詳見 `doc/2026-08-15_ntg-upstream-report-draft.md`。

## 5. 3c 修復(`e86cb4d`)與 Round 2 驗證

**兩層機制,缺一不可**(第二層是本輪新發現,判官機制敘述的更深一層):

1. **Type-1 flow sample 的 parser 從未讀 output interface**——
   `FlowLinkUsageCollector.cpp` 對 sampleType==1 硬寫 `outputPort = 0`(wire 上有這個
   欄位:P4 emitter 與 OVS 都有填,word index+8),所以 egress 側歸因對標準 sFlow
   **結構上不可能**。HPE type 3 反而有讀。已補一行 parse。
2. **歸因是 ingress-owned**:樣本 credit 給抵達邊,每條邊的記帳屬於它下游的取樣者
   ——最後一跳下游是 host、沒有取樣者(判官定位的機制)。修法:ingest 把每個
   ingress 樣本的 egress 側記入 `(agentIp, outputPort)` 的獨立帳本,
   `creditHostBoundEgressEdges()` 每秒**只對「對側是 host」的邊**(edge dstDpid==0)
   付帳;對側是 switch 的條目丟棄(下游取樣者擁有那條邊,第二個寫者會打架)。
   flow_set 同法(ingest 時 `findEdgeToHostByAgentIpAndPort` + touch)。

受害面照判官更正的敘事:`get_graph_data` 的 per-edge 消費者;**不是** Energy app
(`getAvgLinkUsage` 排除 host 邊)。測試 7 條(`tests/test_LastHopAttribution.cpp`,
用 emitter 的 committed fixtures 打真 parser + loader 建的拓撲),**mutation 7/7 實殺**
(guard 移除/host 檢查移除/×8/清零移除/累加改覆寫/parse 回退/dstDpid 判準移除,
各由指名測試殺)。C++ 套件 579/579。

**Round 2(修復後 live,03:07-03:16)**:四條 sw→host 邊全部非零、flow_set 有流
(baseline 是永遠 0/空)。且 **egress 帳本與下游 ingress 帳本互相咬合**:每條 sw→host
邊的 twin/veth 比值與其上游 sw→sw 邊一致到小數點第三位(s2:3→h 2.043 vs 餵它的
s5:2→s2 2.044;s4:3→h 1.984 vs s7:2→s4 1.992)——兩個獨立估計器對同一條樣本流
給出相同答案,**最後一跳歸因與其他邊已無統計上可分的差別**。

……比值為什麼是 ~2.0 而不是 ~1.0?這是 Round 2 撞出的**第二隻 bug**,見 §5b。

### 5b. 意外收穫:proxy 重啟 × warm fabric = 遙測全域 ×2(clone replica 疊加)

> **⚠️ 2026-08-16 下午更新(raw-client 重現輪,`doc/audit/2026-08-16_clone-stacking-raw-repro.md`)**:
> 疊加機制以第三方 raw client 完整重現(我方 proxy 排除),但本節兩個結論已更正:
> ①「DELETE 被空簿記回 **NOT_FOUND**」是推論非實錄(best-effort swallow 沒 log 過
> 狀態碼)——raw 實錄為 **UNKNOWN 空 details**;②「孤兒一旦形成,clone-session API
> 清不掉」被重現輪 phase E 推翻:**簿記持有 session 時的 DELETE 會銷毀整個群組含
> 孤兒 replica**。據此 `write_clone_session` 已加 settle pair(註冊成功後再
> DELETE+INSERT,`79e4f69`),live 驗證 probe 疊到 2 的群組被 plain stack start 收斂
> 回 1;「proxy 重啟必須連 fabric 重啟」自此降級為防禦縱深,非必要條件。

Round 2 **所有** 22 條活躍邊 twin/veth 均勻落在 1.96-2.39(總比 2.04-2.09),
flow 積分同步 ×2——不是任何單邊的記帳錯,是**每個取樣封包被克隆兩份**。PRE dump 實錘:

```
mirroring_get 250 → mgid=33018 (= 0x8000+250)
mgrp(33018) -> (L1h=0, rid=1) -> (ports=[255])
             -> (L1h=1, rid=1) -> (ports=[255])   ← 第二份,全部 10 台一致
```

**機制鏈**(三代 proxy 的行為差對出來的):
1. proxy 重啟會重推 pipeline;`SetForwardingPipelineConfig` 之後 P4Runtime server 的
   clone-session 簿記被清空,但 target 的 PRE mgroup(上一代建的)存活。
2. 新一代的 INSERT 因此「成功」(C9 量到的 UNKNOWN-on-duplicate 根本不會發生——
   server 已不記得這個 session),並對存活的 mgroup **append** 第二個 CPU replica。
3. 判別實驗:第三次重啟(已帶 DELETE-first 修復)讓 node 數 2→**3**——DELETE 被空簿記
   回 NOT_FOUND、碰不到孤兒 mgroup。**孤兒一旦形成,clone-session API 清不掉。**

**處置**(`f5a7688`):`write_clone_session` 改 DELETE→INSERT(API 可及的路徑上是
正確衛生;20 unit tests、mutation 3/3);docstring 載明**操作規則:proxy 重啟必須
連 fabric 一起重啟**,warm-fabric 重啟一次遙測就 ×2。fresh fabric 實測回到單 replica。
bmv2/PI 的「pipeline commit 使 clone 簿記與 PRE 脫鉤+mc 建群容忍重複」屬上游材料,
**依「上游回報前先以第三方 client 排除我方」的紀律(C8 假回報那課),回報前需先用
raw client 重現並排除我方 proxy**——列入待辦,今晚不投。

**方法論註腳**:這隻 bug 只有對帳才抓得到——絕對值看起來只是「流量比較大」,
沒有 ground truth 就是無聲的全域 ×2。08-15 之前的歷輪數據不受影響(當時每輪都是
fresh fabric + 首代 proxy);Round 2 的絕對值作廢、比值結構仍是修復驗證的有效證據。

### 5c. Round 3(fresh fabric + 兩修復,乾淨絕對值;12:03-12:08,2m interval)

| 邊類 | veth 總計 | twin 總計 | 比值 |
|---|---|---|---|
| host→switch(4) | 401,729,570 | 436,782,251 | **1.087** |
| **switch→host(4)** | 389,838,268 | 416,436,946 | **1.068** |
| switch→switch(16) | 1,320,255,633 | 1,330,516,462 | **1.008** |

**最後一跳邊與其他邊類已無差別**(baseline:永遠 0.000)。per-edge 散佈 0.74-1.23,
比 Round 1 寬——2 分鐘窗每邊位元組少 ~3×,Poisson 誤差 196√(1/c) 相應放大,量級吻合。

**機制級互證(比總量更強的證據)**:transit switch 的流量守恆讓同一批樣本同時餵
兩本帳——s2 的每個樣本以 input port 記給 s5→s2、以 output port 記給 s2→h2。實測
**s2:3→h 0.986 ≡ s5:2→s2 0.986、s3:3→h 1.061 ≡ s7:1→s3 1.061、s4:3→h 0.910 ≡
s7:2→s4 0.910,逐位一致**——egress 帳本不是「另一個大概對的估計」,是同一樣本流
的數學等值讀數。Round 2 的 2.043≡2.044 在乾淨環境下重現為 1.0 級。

×2 全域消失(sw→sw 總比 1.008);3f 三度複證:249 個 5-tuple 零重複、
滯留 p90=14s/max=16s、`Experiment completed` 後十幾秒清單排空到 0(2m interval +
60s fixed 尾巴的時序也再次吻合 §4 的重啟尾巴機制)。per-flow:last_sec 積分 +38%
正偏(小流佔比更高,與 §3 假說方向一致)、timeslot 欄位 4.4×(hold-last 語意再證)。

## 6. 對驗收報告各節的回寫

| 驗收節 | 本輪結果 |
|---|---|
| 3b path 精確 | 並發下間接複證(per-edge 全對 ⇒ path 歸邊正確) |
| 3c FAIL | **已修**(`e86cb4d`),Round 3 乾淨驗證:sw→host 總比 1.068、與鄰邊逐位互證(§5c) |
| 3d per-link ±40% | 並發下 per-edge 時間積分收斂到 ±3%(全窗);瞬時噪聲照舊,積分可信 |
| 3e per-flow WARN | 並發下 +29~38% 正偏(last_sec)、timeslot 欄位不可積分——WARN 加重,附消費警語 |
| 3f PASS | PASS 維持,但機制敘述更正:ACK 方向流 + ~15s 滯留窗;double-counting 排除(三輪 0 重複) |
| (新) | **proxy 重啟 × warm fabric = 遙測 ×N**(§5b,`f5a7688`+操作規則;上游材料待 raw-client 重現) |
