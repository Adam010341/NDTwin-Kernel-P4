---
name: ryu-startup-costs-measured
description: "✅ OVS failover 的帳已平:偵測佔 87%(44.86 s),修法 `NDTWIN_RYU_LLDP_GUARD` 已量到 3.9×;walk 現在是 0.25 s(⚠️ 2.166 已過期兩代,957a646 的索引曾更慢)。🔴 settle 60→10 的代價**已實測複驗**:Ryu 學不到 host IPv4 ⇒ kernel 圖 256 條 host 邊 down"
metadata:
  node_type: memory
  type: project
  originSessionId: 50445b3c-51cd-4c3b-9364-d120dd6a72ff
  modified: 2026-08-25T12:01:15.766Z
---

2026-08-21。開機那半:另一個 session 量、開機手冊修。failover 那半(下面兩節):本 session 量。全文
`doc/audit/2026-08-21_ryu-topology-scaling/WALK_SWEEP.md`。

## 被推翻的數字

**`install_all_pair_paths` 在 128 台是 2.166 s,不是文件寫的 ~60 s(差 28×)。**
而且 **95% 不是裝規則**(1280 條 OpenFlow 只花 0.103 s),是建 `all_destination_paths`
那個迴圈。**簡報不可以再帶 13 s 或 60 s 這個項目。**

> 🔴 **08-21 晚,2.166 也過期了,而且中間那一代更慢**:`957a646` 的索引把 cache token
> 寫成每次查詢都呼叫 `net.number_of_edges()`——networkx 那是 `size()`,對每個節點加總
> degree,**O(V) 每次呼叫**——「索引版」實測比它取代的線性掃描**慢 1.69×**
> (live 3.634 vs 2.166;離線四變體賽跑三個尺度全部 1.69×,`walk_variants.txt`)。
> 修成 O(1) token(`4810e8f`)後 **live n=3 = 0.25 s 中位數**。
> 🔑 教訓:**「相信某 API 是 O(1)」也要開原始碼驗**——同一個 helper 兩度成為瓶頸,
> 兩次都「看起來顯然沒問題」。現在有 counting-graph 測試釘住(查詢期間零次
> number_of_edges/size/degree 呼叫)。下面的 13.7× 表仍然成立(它量的是裸 dict)。

## 三次方就是一行

`find_host_by_ip`(`intelligent_router.py`)線性掃 `net.nodes`,被最內層迴圈呼叫。

| hosts | 線性掃描 | dict | 比值 |
|---:|---:|---:|---:|
| 32 | 0.0080 | 0.0020 | 4.0× |
| 64 | 0.0590 | 0.0080 | 7.4× |
| 128 | 0.3960 | 0.0290 | **13.7×** |

log-log 斜率 2.75 → 1.86。🔑 **他們是用介入實驗證實的**(同一個 fabric 跑兩次,
只換那個 helper),不是拿算式吻合就當機制 —— 見 [[arithmetic-that-fits-is-not-the-mechanism]]。
索引那一代的失敗見上面的引文方塊,教訓 [[speedups-pass-the-wrong-test]]。

## 那個 60 秒 settle

`load_static_topology` 裡一行裸的 `hub.sleep(60)`,**沒有任何記錄的理由**,而且掛在一個
改不動的旗標上(`is_mininet` 在 module 層被無條件重設為 True)。它**支配整個 OVS 開機**。

實測 settle=3:

| | 之前 | settle=3 |
|---|---|---|
| 128-host OVS | 73 s | **19 s**,3/3 都通 |
| 4-host | 62 s | **10 s** |

連通性不是只 ping 鄰居:**h1→h64、h64→h128、h128→h1 全過**(跨核心、跨四象限)。

🔴 **「預設 10 s」是錯的 —— 那 60 s 有理由,只是沒寫下來。**
(此條 08-21 傍晚先以轉述進檔並標「未複驗」;**當晚已由介入實驗複驗,升級為實測**。)

| `NDTWIN_RYU_SETTLE_S` | Ryu 有 ipv4 的 host | kernel 的圖 |
|---|---|---|
| 60(舊預設) | **128/128** | 288 up / 0 down |
| **10**(`957a646`) | **0/128** | 32 up / **256 down** |

它保護的是 **Ryu 學 host IPv4 的時間窗**。Ryu 只從 **packet-in** 學
(`ryu/topology/switches.py:877-885`,在 packet-in handler 內);testbed 建完 host 會平行
ping 128 台。規則裝在那個 burst **之前**,ICMP 就在資料面被轉走、**永不上送 controller**
⇒ Ryu 學不到 ⇒ kernel 在「沒有 IPv4 就跳過」那道門(`TopologyAndFlowMonitor.cpp:618`)
丟掉全部 128 台 ⇒ 256 條 host 邊維持出廠的 down。
IPv6 沒有規則、照樣 table-miss,所以 `ipv6` 有值而 `ipv4` 空 —— 就是那個不對稱。

**影響面**:資料面正常,LLDP／walk 的量測**不受影響**(兩者走 `static_net`,由 JSON 建);
**任何讀 kernel host/edge 計數的輪次都會踩到**。

🔑 **教訓比修法重要**:上面那組連通性驗證(h1→h64 等)**只證明資料面通**,
沒有檢查**孿生的圖對不對** —— 而「圖對不對」正是這個產品的賣點。
**縮短任何 settle／timeout 之後,要同時驗資料面與模型,不是只驗前者。**
完整證據 `doc/audit/2026-08-21_bringup-manual-verification/`;
教訓 [[speedups-pass-the-wrong-test]],同一族
[[ratio-sides-must-share-a-population]]、[[existence-is-not-wiring]]。

**正解不是在 10 和 60 之間選**,是把固定 sleep 換成**等真正的事件**(等 Ryu 學到所有 host,
逾時 fail-open)。patch 在 `scratch/pending/host-discovery-gate.patch`,待實驗室釋出後驗證。

## ✅ 那 46 秒找到了(2026-08-21 傍晚,`52cba51`,量於 `07ae07c`)

**是鏈路故障偵測,佔 51.75 s 的 87%。** 全文
`doc/audit/2026-08-21_ryu-topology-scaling/DETECTION.md`。

| | ports | 偵測 | ＋去抖＋walk | 上週的中斷 | 偵測佔比 |
|---|---:|---:|---:|---:|---:|
| 4 台 | 36 | **13.11 s** | 16.11 s | 15.70 s | 84% |
| 128 台 | 160 | **44.86 s** | 51.30 s | 51.75 s | **87%** |

**帳平了**:44.86 ＋ 3.00 ＋ 2.17 ＝ 50.0 對 51.75,殘差 1.7 s(n 不同、輪次不同,別解釋)。

**機制**(讀 `ryu/topology/switches.py`,**跑之前先寫下預測 48.0 s**,實測 44.86):
`lldp_loop` 對**每個 port** 依序探測、每次 `hub.sleep(LLDP_SEND_GUARD=0.05)`,
而 `link_loop` 要 `LINK_LLDP_DROP=5` **連續六次沒回應**才判死。
所以同一個 port 兩次探測的間隔 ＝ **port 數 × 0.05 s**,而 **host port 從不回 LLDP**。
🔑 **加主機會拖慢自己的故障偵測,交換機拓撲根本沒動。** 這正是 P4 不跟著漲的原因
(proxy 用固定間隔 beacon),也就是 8/20 那張圖上的 3.30× 對 1.21×。

**兩個沒去瞄準卻自己對上的檢查**:每格「偵測＋去抖＋walk」都剛好比偵測多 **3.00 s**
(＝`reinstall_quiet_period`);port 數剛好 36 和 160。

## ✅ 修法已量(不是提議)

新旗標 `NDTWIN_RYU_LLDP_GUARD` 設 `Switches.LLDP_SEND_GUARD`,**預設不動**,
override 會在 Ryu log 印一行自證生效。

| 128 台 | 偵測 | ＋去抖＋walk |
|---|---:|---:|
| 0.05(Ryu 預設) | 44.86 s | 51.30 s |
| **0.01** | **11.51 s** | **17.91 s** |

**3.9×**,整個中斷落進 P4(16.59 s)同一區間。差預測 5× 是因為 `TIMEOUT_CHECK_PERIOD=5 s`
是地板。🔑 **刻意不動 `LINK_LLDP_DROP`** —— 那個能到同樣數字但**降低判死所需的證據**,
而 `topology_manager.py:147-150` 已論證「會抖動的鏈路報告比慢的更糟」。
**guard 只縮短間隔,門檻仍是連續六次。**

🔴 **誤判率完全沒量**(n=3、五分鐘、零誤刪),而那是 B2 ② 的判準。
**投影片可以說「槓桿存在、移動多少已知」,不可以說「偵測問題解決了」。**

## 🆕 2026-08-25:還能再快嗎?——地板已指認,建議是**不要追**

Adam 問三題(還能再快/商用多快/NDTwin 要不要追)。答案全部由**既有量測**組出,本輪沒進實驗室。

**地板 = `switches.py:510 LLDP_SEND_PERIOD_PER_PORT = 0.9`。**(讀庫源碼,08-25 PM4 為了
guard 題查的,見 [[review-round-2026-08-21]] ㉑。)`lldp_loop` 每輪只挑「距上次探測 >0.9 s」
的 port,`LLDP_SEND_GUARD` 只節流**同一輪內**。⇒ guard 再往下調也買不到多少:
同 port 的探測間隔被 0.9 s 夾住,乘上 `LINK_LLDP_DROP=5`(連續六次)⇒ **偵測的硬地板約 5 s**。
要突破只能改庫常數、或換一種偵測機制。**未實測 —— 這是讀碼推得的上限,不是量到的。**

**沒走的兩條路(刻意)**:降 `LINK_LLDP_DROP`(更快但降低判死證據,`topology_manager.py:147-150`
自己論證過「會抖動的鏈路報告比慢的更糟」);縮 3.00 s 去抖(是我們自己的參數,可調,只值 3 s)。

**商用比較的正確框法**:我們量的 51.75 s **不是拔線**。實體斷線走 `OFPT_PORT_STATUS`,
是即時的;51.75 s 量的是**黑洞型故障**(線在、狀態正常、封包不見),而 LLDP 逾時是**唯一**
抓得到它的機制。商用數字給區間即可(硬體 ms 級/電信保護切換目標 50 ms/BFD 典型 150 ms、
激進 ~10 ms/沒有 BFD 的路由協定預設計時器數十秒 ⇒ 我們現在落在最後這類)。
**這些商用數字是通識量級,不是我們量的,上台不要給精確值。**

**建議(我的判斷,Adam 尚未裁)**:不追。NDTwin 不在轉發路徑上,「failover 時間」的意思是
**模型多久之後恢復說實話**;下游(節能 App、TE)的決策週期是秒到分鐘,16 s→50 ms 沒有消費者。
真正該投資的是**誠實**:F-14 host 永遠不會被標 down、F-16 交換機死掉時 host 邊仍顯示連著、
F-4 死鏈路每輪被復活、閒置時平均使用率回 0(而 0 正好觸發節能 App 關機)。
**那些是正確性缺陷,比慢危險。** 一句話版:*孿生的目標不是追上硬體切換速度,是把「模型可能
是錯的」那段時間框住,並在不確定時說「我不知道」。*

⚠️ **我自己引數的一個不精確(當場已向 Adam 更正)**:回答時把 recompute 講成 **0.25 s**,
但 51.75 s 那筆帳裡的 walk 是 **2.17 s**(量於 `07ae07c`)。0.25 s 是 `4810e8f` 之後的
**開機路徑** live n=3,而本檔下面那個 ⚠️ 早就寫著 **failover 的 walk 是不同呼叫點、從沒量過**。
結論(recompute ≤4%)兩個數字都成立,但**投影片要用 2.17 或標「未量」,不要用 0.25**。

## 對報告的影響

recompute 這一項是 **51.75 s failover 裡的 ~2 s,約 4%**。加上已排除的拓樸讀取路徑
(<1.3 ms),**兩個最被懷疑的機制加起來不到 5%** —— 而真正的答案是**等待**。

⚠️ **這些都是開機路徑的量測。** failover 的 walk 是**不同的呼叫點**
(`_route_reinstall_worker` 對 `load_static_topology`),雖然函式和圖的大小相同,
但那個數字還沒量過。

相關:[[ndt-one-command-lab-lifecycle]]、[[ovs-testbed-bandwidth-reality]]、
[[check-against-prior-experiments]]、[[arithmetic-that-fits-is-not-the-mechanism]]、
[[injections-must-assert-their-own-success]]。
