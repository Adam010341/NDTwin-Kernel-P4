# 交接筆記（最後更新 2026-07-31）

[Co-developed with claude code -- Adam]

這份是「還沒歸檔的東西」＋「目前的判斷與待辦」。已經歸檔的請直接看：

| 內容 | 在哪 |
|---|---|
| 各 Phase 進度、Phase 6 入手點 | [p4_bmv2_support_plan.md](p4_bmv2_support_plan.md) |
| **完整測試流程（執行用 runbook）** | [full_test_runbook.md](full_test_runbook.md) |
| 測試分層定義、實測數據、通過標準 | [p4_status_and_test_guide.md](p4_status_and_test_guide.md) |
| 環境陷阱（sudo、pgrep、清理、順序） | [environment_gotchas.md](environment_gotchas.md) |
| OVS↔P4 的已接受差異＋原因 | [../tools/contract_test/baseline_diff_allowlist.txt](../tools/contract_test/baseline_diff_allowlist.txt) |
| 每個 bug 的完整分析 | git log（commit message 寫得很詳細）|
| 按子系統的程式碼審查（10 階段） | [audit-be3c242/](audit-be3c242/) —— 判定見下面第 1h 節 |
| **`be3c242..576dd2a` 的 scoped review** | [audit/scoped/](audit/scoped/) —— 判定見下面第 1k 節 |

---

## 目前的狀態（一句話）

**測試堆疊在 OVS 和 P4 兩邊都綠**（L0/L1/L2/L3/log/L4），P4 的圖、telemetry、雙向 path、
flow 安裝、link 失效重算、**switch liveness** 都實機驗證過。**`is_up` 不再說謊了。**
剩下的是**測試覆蓋率**、以及一批已查證但未修的 audit 發現。

| 層 | OVS | P4 |
|---|---|---|
| L0 build（含 p4c） | ✅ | ✅ |
| L1 單元（**229** C++ 直接跑 **+ ctest 也綠**、8 Python + 2 kernel-side 套件） | ✅ | ✅ |
| L2 API 契約 | **36/36 錯誤路徑全綠**（`get_graph_data` 見下方 flaky 註）| 待重測 |
| L3 元件契約 | 1 BROKEN + 1 MISSING | 同 |
| log allowlist | ✅ | ✅ |
| L4 差異比對 | — | ✅ PASS（14 條已接受差異）|

⚠️ **L2 的 `get_graph_data` 是時間的函數，不是程式碼的函數** —— 見第 2 節。

---

## 還沒歸檔 / 未解決的事

### 1. ~~kernel 閒置時燒 100% CPU~~ ✅ 已解決（2026-07-30，commit `d79979e`）

原因是 `FlowLinkUsageCollector::run()` 的 `POLL_TIMEOUT_MS = 0`。**0 的意思是「立刻返回」，不是
「不設逾時」**（`-1` 才是阻塞），所以沒流量時迴圈是 `poll` → `ret==0` → `continue` → `poll`，
純忙等。而它上面的註解寫「poll without timeout」，讓這個錯看起來像刻意的。

| | CPU |
|---|---|
| 修正前 | `run` thread 100.9%、process 101% |
| 修正後 | process **1.7%** |

功能無損：灌 7 個 fixture → `rx=7 app_drop=0 addressed=8`、解析出 5 筆 flow。

**過程中值得記的一點**：我原本懷疑的兩個一秒迴圈
（`calAvgFlowSendingRatesPeriodically` 和 `pingWorker`）實測是 **1.9% 和 ~0%** —— 兩個都很合理
（都每秒印 log、`pingWorker` 還每次深拷貝整張圖 + shell 出去跑 `ovs-vsctl`），但**兩個都猜錯**。
是靠 `/proc/PID/task/*/stat` 的 per-thread 取樣定位的，不是靠讀程式碼。

### 1b. ~~Web GUI 全部節點紅色（`is_up: 0`）~~ ✅ 已解決（2026-07-30，commit `6b3dc0c`）

`pingWorker` 裡兩個**互相獨立**的 bug，任何一個單獨存在都還能撐：

1. `ovs-vsctl list-br` **失敗**和**成功但回報沒有 bridge** 分不出來 —— 兩者都是空 vector，
   迴圈讀成「全部 down」，而且 `pclose` 的 exit status 從來沒檢查。所以**掉一次呼叫就把整個
   fabric 標成死的**。實際看到兩個原因：setsid 起的 process 沒有 controlling terminal 導致 sudo
   要密碼、以及 100 Mbps 灌流量時指令變慢。
2. 那個分支**只會呼叫 `setVertexDown`**。查到 bridge 存在時只印 log 不動圖，所以「down」是永久的
   —— 除非 Ryu 剛好重連並重新宣告該 switch，否則沒有任何東西能把它拉回來。

兩個加起來：**一次抖動就讓整張圖在那一輪之後全黑**。

修法是把判斷抽成有測試的三態 policy（`ovsLivenessFor`），`Unknown` **不動圖** ——
「判斷不出來」不能報成「死了」。失敗的 log 改成 edge-triggered（`FailureRun`）：這個查詢
1 Hz 在跑，每次都印就是當初 3596 行 sudo 錯誤把 log 埋掉的原因。

實機驗證（**故意不開 Ryu**，這樣 `pingWorker` 是唯一能動圖的東西）：

| 動作 | 結果 |
|---|---|
| 沒有 bridge | `up=0/10` |
| 建 s1–s10 | 3 秒內 `up=10/10` |
| `del-br s3` | `up=9/10`，只有 s3 掉（不是整片） |
| `add-br s3` | `up=10/10` —— **這個轉換在修好之前不可能發生** |

**過程中值得記的一點**：第一次實機驗證看到 `up=0/10`，我以為修錯了。真正的原因是**根本沒有
data plane 在跑** —— 下面第 5 節當時寫著「Mininet 還開著」，但那是舊資訊。`pgrep -f
"testbed_topo.py"` 還騙了我一次：它匹配到**我自己的 shell**（`-f` 的老問題，
environment_gotchas 裡記過）。教訓：**信任 live 測試之前先確認環境真的存在**，而且這個文件的
環境狀態一過期就會反過來誤導人。

### 1c. 2026-07-30 手動測試回報的 9 項異常 —— 結案狀態

OVS 模式、`iperf -u -b 100M` 灌流量時觀察到的。分類與處置：

| # | 現象 | 判定 | 處置 |
|---|---|---|---|
| 1 | 鍊路使用率為零 | **不是 bug** —— `getAvgLinkUsage`（`TopologyAndFlowMonitor.cpp:2245`）刻意排除所有接到 host 的邊，而 h1/h2 都在 s1 底下 | 已實測釐清（`6996062`）。**我原本歸咎 Ryu 猝死，那個歸因是錯的** |
| 2 | `src_ip: 16777226` 看起來很怪 | **不是 bug** —— 那是 `in_addr::s_addr`，network order，正是 10.0.0.1 | 文件講清楚（`0e84234`）。**我先前說「文件錯了」是我判斷錯誤** |
| 3 | flow table 是空的 | **不是 bug** —— 實測 10 台各 130 條 | 我給的指令多加了 `?dpid=1`，那個端點是精確比對 target，加參數就 404（`6996062`）|
| 4 | `get_num_of_flows_passing_a_switch` → Not Found | **我給錯指令**，那是 POST + JSON body | — |
| 5 | 資源與電源 output 很怪 | **真 bug**：`power_consumed` 是 [0, 2⁶⁰) 的亂數 = 1.9×10¹⁴ 瓦，而且每次輪詢重骰 | 已修（`0e84234`），30–150 W 且穩定 |
| 6 | 鎖是 Not Found | **我給錯指令** + 合法值沒寫在文件裡 | 文件補上 `routing_lock`/`graph_lock`/`power_lock`（`0e84234`） |
| 7 | install entry 後查詢是空的 | 同 #3，同一個錯指令 | 同上 |
| 8 | ping 100% packet loss | **不是 bug** —— 你在灌 100M UDP，s1-eth3 已過 594 萬封包，ICMP 被餓死是預期的 | 重測請用 `-b 10M` |
| 9 | web-gui 全部節點紅色 | **真 bug**（兩個），見第 1b 節 | 已修（`6b3dc0c`） |

**最終結果：真 bug 只有 2 個**（#5、#9），都修了並實機驗證過。**3 個是我給錯指令**
（#4、#6、以及 #3/#7 共用的那個 `?dpid=1`）。其餘是條件沒滿足，不是壞掉。

⚠️ 我一度把 #1/#3/#7 全部歸咎於「Ryu 在 13:57:00 猝死」。**那個歸因是錯的** —— 真正的原因平凡得多
（流量兩端同一台交換機、以及我給錯指令）。Ryu 確實死過一次而且**死因至今未確定**
（log 突然中斷、沒有 traceback、沒有 OOM 紀錄），那件事本身還沒結案，但它不是這三項的原因。
教訓：看到一個顯眼的故障就把手邊所有症狀掛上去，會蓋掉真正的原因。

### 1d. ~~P4 模式：flow 的 path 只有**單一方向**解得出來~~ ✅ 已解決（2026-07-30）

**根因：`StaticNetworkTopologyP4_10Switches_4Hosts.json` 的 host port 寫錯了。**

| | s1 | s2 | s3 | s4 |
|---|---|---|---|---|
| 實機（`p4_testbed_topo.py:180-183`，四行都是 `port2=3`）| 3 | **3** | **3** | **3** |
| JSON 原本寫的 | 3 | 4 | 5 | 6 |

實機 `ip link` 確認 s1–s4 **各只有 3 個介面**（eth1/eth2/eth3），所以 JSON 說的 `s4:6` 根本不存在。

**bug 的來源**：這份 JSON 是照 OVS 那份改的，而 OVS 拓撲是 **32 台 host 掛同一台交換機**，所以
host port 3、4、5…遞增是對的。P4 是**一台 host 掛一台交換機、全部 port 3** —— 遞增的模式被照抄了。

**為什麼只有一個方向壞**：路徑是逐跳走訪建的（`FlowLinkUsageCollector.cpp:2351`），最後一跳要找
host 邊。`10.0.0.4→10.0.0.1` 的最後一跳是 s1:3（JSON 剛好對），所以成功；
`10.0.0.1→10.0.0.4` 的最後一跳是 s4:3，而 JSON 只有 s4:6 → 找不到邊 → `ok=false` → path 清空。

**診斷關鍵**：`edge not found by dpid/port 4:3` 這條 WARN 已經印了 **270,991 次**（log 41 MB），
但它在 allowlist 裡，所以 log 檢查是綠的。**這條 warning 早就在告訴我們答案了。**
allowlist 讓已知的噪音不擋 CI，但也讓這個訊號沉在 41 MB 裡沒人看。

修正後實測（雙向都對）：

```
10.0.0.1->10.0.0.4 type=8 path=7 跳   10.0.0.1 -> 1 -> 6 -> 10 -> 8 -> 4 -> 10.0.0.4
10.0.0.4->10.0.0.1 type=0 path=7 跳   10.0.0.4 -> 4 -> 8 -> 10 -> 6 -> 1 -> 10.0.0.1
edge not found by dpid/port: 0 次（log 從 41M 變 33K）
```

⚠️ 順帶記一個**測試方法**：`ping` 預設 1 pkt/s，2700 個要 45 分鐘。Mininet 是 root 跑的，所以可以
`h1 ping -c 30000 -i 0.01 -q h4 &` —— 10ms 間隔、300 秒窗口、丟背景。**必須邊跑邊查**，
flow 停幾秒就老化。實測 2700 個 × 10ms = 27 秒 → 105 個 sample（符合 2700×10÷256≈105）。

<details><summary>原本的記錄（原因未明時寫的）</summary>

`h1 ping h4` 在 bmv2 上跑，kernel 兩個方向都正確解析出 ICMP flow，但：

| 方向 | ICMP type | path | rate |
|---|---|---|---|
| 10.0.0.1 → 10.0.0.4 | 8（request） | **0 跳** | 正常（~150 kbps）|
| 10.0.0.4 → 10.0.0.1 | 0（reply） | **7 跳** ✓ | 正常 |

**持續 45 秒以上都是這樣**，不是時間差。已排除兩個明顯的解釋：

1. **不是規則缺失** —— `/stats/flow/1` 和 `/stats/flow/4` 各有 4 條，
   s1 有 `nw_dst 10.0.0.4 → OUTPUT:2`，s4 有 `nw_dst 10.0.0.1 → OUTPUT:2`。
2. **不是規則和路徑不一致**（我原本猜是「`install_initial_routes` 只 INSERT 不 MODIFY 導致規則過期」）
   —— proxy 算的 `10.0.0.1→10.0.0.4` 第一跳是 `1(port 2)`，實際裝的就是 `OUTPUT:2`。兩邊對得上。

所以原因**還沒查出來**。下一步要看 kernel 是用 Classifier 走訪還是用 `setAllPaths` 推來的資料填
`path`，以及兩者對「哪一端是起點」的處理差異。

`avg_link_usage` 在 P4 模式**是會動的**（實測 0.00031），只是要等樣本累積。

</details>

### 1e. 2026-07-31 checkpoint：測試堆疊全綠，還剩兩項端到端沒測

**全部測過並通過的：**

| 層 | OVS | P4 |
|---|---|---|
| L0 build（含 p4c pipeline） | ✅ | ✅ |
| L1 單元（141 C++ 直接跑 + ctest、6 個 Python 套件） | ✅ | ✅ |
| L2 API 契約 | ✅ 31/36 | ✅ **31/36，失敗清單完全相同** |
| L3 元件契約 | ✅ 2 BROKEN | ✅ 2 BROKEN |
| log allowlist | ✅ PASS | ✅ PASS |
| L4 差異比對 | — | ✅ **PASS**（14 條已接受差異） |

剩下的 5 個 L2 FAIL 是既有的輸入驗證缺口（`bad_ip`→500、`bad_dpid`→500、爛 JSON→202 ×2、
`install_flow_entry` 的 status 傳遞），**與 P4 無關**，OVS 也一樣。

**2026-07-31 補測了第 5、7 項**，結果見第 1f 節。

**計畫書驗收清單（`p4_bmv2_support_plan.md:257`）原本沒做的兩項** —— 兩者都需要 bmv2 起著：

| # | 項目 | 為什麼重要 |
|---|---|---|
| **5** | `POST /ndt/install_flow_entry` 帶 5-tuple + priority → 表裡要看到，**而且流量真的改走新 port** | 這是 `P4RoutingStrategy` 唯一沒對活的 switch 跑過的路徑。curl → proxy → P4Runtime 每一段都有單元測試，整條沒有 |
| **7** | 殺掉 proxy 再下規則 → kernel 要 WARN、端點要回報失敗**不能回 200** | 驗證 Phase 2 的錯誤傳遞。目前 L2 已知 `install_flow_entry__unknown_dpid` 回 200，所以這一項很可能會抓到同一個缺口 |

第 6 項（電源關機）要等 Phase 7，現在測沒有意義。

**建議**：待辦第 7 項（P4 liveness）的**實機驗證也需要 bmv2**，所以一次 bmv2 session 可以把
第 5、7 項和 liveness 驗證一起收掉。但第 5、7 項和 liveness 的程式改動無關，先測完才不會混在一起。

### 1f. 驗收清單第 5、7 項的實測結果（2026-07-31）

**第 5 項：轉發行為通過，但發現一個靜默成功。** ✅⚠️

`install_flow_entry` → proxy → P4Runtime → bmv2 整條是通的，而且**流量真的改走新 port**：

```
s1 對 10.0.0.4 的規則:  OUTPUT:2 → OUTPUT:1
路徑:  1(p2)→6→9→7→4    變成    1(p1)→5→9→7→4
```

這是 `P4RoutingStrategy` 第一次對活的 switch 驗證成功。

**但 5-tuple 和 priority 被靜默丟掉了。** 送出的是
`{ipv4_src, ipv4_dst, ip_proto, udp_src, udp_dst}` + priority 100，proxy 自己的 log 寫
`Pushing P4 rule to DPID 1: 10.0.0.4/32 -> Port 1` —— `route_flow`
（`topology_manager.py`）只讀 `nw_dst`/`ipv4_dst`，其餘全部無聲丟棄，寫成 `ipv4_lpm` 的 `/32`，
表讀回來 priority 是 0 而不是 100。

**後果**：一條瞄準單一 flow 的規則，實際變成瞄準整個目的地的規則。Traffic-Engineering 下的規則
會影響到它沒有指定的流量。

已修（`route_flow`／`unroute_flow`／`modify_flow` 三處）：不能表達的 match 欄位**一律拒絕**並回
HTTP 400 帶欄位清單。實測：

| 測試 | 結果 |
|---|---|
| 5-tuple 直打 proxy | 400 `["ip_proto","ipv4_src","udp_dst","udp_src"]` |
| 只有目的地 | 200（原本可用的路徑沒被破壞）|
| ARP 的 `eth_type` (2054) | 400 —— 不會被當成 IPv4 服務 |
| 走完整 kernel 路徑 | kernel log 記下 `returned HTTP 400` 加完整欄位清單 |

⚠️ **`priority` 仍然被忽略但不擋安裝** —— 對單一 `/32` LPM key 來說沒有排序意義，而 kernel 每次
都會送 priority，硬擋會讓所有安裝失敗。真正的修法是接上 Phase 4 已經建好的 `flow_5tuple`
ternary 表（有真 priority），那是 Phase 3 的正式工作。

**第 7 項：kernel 端對了，HTTP status 沒對。** ✅❌

殺掉 proxy 後下規則：

```
[warning] HttpRoutingStrategyBase.cpp:96 post]
    install flow entry failed: no response from P4 proxy agent at localhost:8081 within 5s
```

kernel **有**正確偵測 5 秒逾時、記 WARN、指名端點。但端點仍回 **HTTP 200** `{"status":"queued"}`，
原因在回應文字裡就寫著：`per-entry outcomes are reported in the kernel log, not in this response`
—— `FlowDispatcher` 是非同步的（一次可排 2000 筆、每 DPID 一個 worker），HTTP 回應在規則還在隊列
裡時就送出了。這和 L2 的 `install_flow_entry__unknown_dpid` 回 200 是**同一個缺口**，要讓
dispatcher 的結果回流到 HTTP 層才能修，不是小改。

### 1g. ~~link 掛掉之後路徑不會重算~~ ✅ 已修（2026-07-31，commit `2c81b26`）

實測情境：OVS 模式，`h1 iperf -c 10.0.0.97`，先手動在 s1 裝一條 priority 100 的規則把它導向
port 1（往 s5），流量確實跟著走。然後在 Mininet 打 `link s1 s5 down`。

觀察到的：

| # | 現象 | 原因 |
|---|---|---|
| 1 | **流量沒有被重新導向** | 系統裡沒有任何東西會重算路徑，見下 |
| 2 | web-GUI 還是量到流量 | **這是對的** —— h1 一直在送，s1 仍然收到、sFlow 在 **ingress** 就取樣，之後才在死 port 被丟棄。流量真的存在於入口 |
| 3 | 加一條 priority 120 導回 s6 就正常 | 操作者手動做了控制平面該做的事 |

**Twin 這一側是正確的。** `link_failure_detected` 有送到、有生效 —— `get_graph_data` 顯示
`s1:1 -> s5 is_up=False`、`s5:1 -> s1 is_up=False`，兩個方向都標下來了。

**失敗在控制平面。** Ryu **有**偵測到（`/v1.0/topology/links` 從 32 條變 30 條，s1↔s5 已移除），
但 [`on_link_delete`](../intelligent_router.py#L596) 只做兩件事：印 log、POST 給 kernel。之後：

- **整個 `intelligent_router.py` 沒有任何 `remove_edge`** —— 所以 `static_net`（算路徑用的圖）
  永遠留著那條死 link。任何基於它的後續決策都是錯的，而且是無聲的。
- `install_all_pair_paths` **只跑一次**：第 284 行把 `install_initial_openflow_entries_completed`
  設 True，**緊接著**第 285 行才呼叫。所以啟動後約 60 秒裝的那批規則是整個 run 的最終狀態。

**還有第二個獨立的缺口**：`install_all_pair_paths` 用 **priority 10**，而操作者手動裝的是 100。
所以**就算控制平面會重算，也蓋不掉手動規則** —— 那是 priority 的定義，但意味著手動規則沒有
「失效自動撤除」的機制。對一條被釘住的 flow，重新導向必須由操作者收回釘子。

⚠️ **這件事讓待辦第 8 項的價值需要重新評估**：原本計畫是「P4 那側也要送
`link_failure_detected`」，但既然 **OVS 這側收到通知之後也沒有人採取行動**，把 P4 接起來只會讓
P4 達到「和 OVS 一樣不會復原」的水準。

修的話三個層次，範圍差很多：

| 層次 | 內容 | 備註 |
|---|---|---|
| 小 | `on_link_delete` 加 `remove_edge` | 單獨做不會重新導向，但是後兩項的前提。**現在 Ryu 的圖是錯的** |
| 中 | link 變動時重算並重下受影響路徑 | `safe_add_or_modify_flow`（用 `OFPFC_MODIFY_STRICT`）**在同一個檔案裡已經存在**，只是 `install_all_pair_paths` 沒用它 |
| 大 | twin 偵測並回報「黑洞」flow（入口有量、出口沒有） | 這是 twin 該有的能力，目前它只看入口。**未做**，待辦第 11 項 |

**已做的（`2c81b26`）**：`on_link_delete` 移除有向邊、`on_link_add` 更新**實際使用的圖**
（原本只動 `dynamic_net`，所以在手冊記載的 static 模式下 link 恢復從來沒被反映），link 變動時
**3 秒 debounce + greenlet 重算**（一次 `link down` 兩個事件、`install_all_pair_paths` 要走 16256
個 host pair，同步做會卡住 LLDP discovery）。順手補了「switch 已斷線時跳過」的防護。

實機驗證完整 down/up 循環：`h1 → s1(p1) → s5 → s2 → h34`（4.1 Mbps）→ 斷線 → 兩個事件只觸發
一次重算 → 規則 `OUTPUT:1` → `OUTPUT:2` → `h1 → s1(p2) → **s6** → s2 → h34`（10.3 Mbps）→
接回 → 路徑回到 s5。

⚠️ **仍然成立的第二個缺口**：`install_all_pair_paths` 用 priority 10，手動裝的規則若優先度更高，
重算**蓋不掉它**。那是 priority 的定義，但意味著手動規則沒有「失效自動撤除」機制。

### 1h. audit（`doc/audit-be3c242/`）的逐項判定（2026-07-31）

10 份摘要我逐項查證過。**不是每一條都成立**，而錯的那幾條錯得很具體，值得記下來。

**🔴 已修**

| 發現 | 查證結果 | commit |
|---|---|---|
| `setAllPaths` / `m_allPathMap` 完全無鎖 | ✅ **比 audit 說的更廣** —— 六處存取全無鎖，而 `m_allPathMapMutex` **宣告了從來沒用過**。`shared_lock` 只擋得住讀者之間。**而且是我讓它變嚴重的**：`refreshDestinationPathsPeriodically`（我加的）把「啟動時一次」變成「每 5–60 秒一次」 | `0596dd1` |
| `Controller.cpp` 丟掉所有 `OpResult` | ✅ 真的。這才是 `install_flow_entry` 回 200 的根因；我原本歸因「dispatcher 非同步」只對一半 | `8c25dbc` |
| `FlowDispatcher::stop()` data race | ✅ 真的，**外加兩個 audit 沒提到的**：`running_` 在鎖外寫入造成 **lost wakeup 死鎖**；`enqueue()` 不檢查 `running_`，`stop()` 後生出的 worker 沒人 join → `std::terminate` | `d5f5bfa` |
| `HttpSession` 輸入驗證讓例外變 500 | ✅ 真的 | `832d75c` |
| `route_flow` 靜默丟棄 5-tuple | ✅ 真的（我自己實測抓到的） | `c964946` |
| allowlist 沒有次數/時間上限 | ✅ **當天就被印證** —— 我 allowlist 掉的 `switch not found` 在 proxy 掛掉時噴 75,853 次 | `f5281a8` |

**🟠 已查證成立、未修**

| 發現 | 備註 |
|---|---|
| `setSwitchPowerState` **不論 curl 成敗都更新圖** | 比 audit 說的更嚴重：沒 `--fail`／`-w http_code`／`--max-time`，抓 HTML 第 2 個 `>` 到 `<` 之間的字，然後**無條件** `setVertexUp/Down`。TESTBED-only |
| `/ndt/disable_switch` 不存在，Energy-Saving-App 吞掉 404 | 我的 L3 確實印 `MISSING`。若 app 真的吞掉，**節能功能從來沒關掉過任何交換機** |
| `fencePerBurst_` 只有一行註解 | 真的，但恆為 `false` 所以無害 |
| `bytes.fromhex(f"...{dpid:02x}")` dpid ≥ 256 會崩 | 邏輯正確（和 LLDP beacon 待辦同一區） |
| `getAllPathsBetweenTwoHosts` 指數複雜度 DFS 且持鎖 | 未查證 |
| `/etc/exports` 無檔案鎖競爭（`ofstream` vs `sed -i`） | 未查證 |

**⚪ 判定 audit 錯了**

| 發現 | 為什麼錯 |
|---|---|
| 「`inet_ntoa` 造成全域資料競爭甚至 segfault」 | **在這個平台上不成立**。glibc 2.39 的緩衝區是 **thread-local**（我寫 C 程式證明主執行緒和子執行緒指標不同），而我 8 執行緒／16 萬次的併發測試**對 `inet_ntoa` 原版也通過**。也沒有 segfault 風險。我還是換成 `inet_ntop`，但那是**可攜性**不是修 bug（`95c7690`） |
| 「`syntheticPowerMilliwattsFor` 是 AI 幻覺、假裝功能完成」 | 框架不對 —— Mininet/bmv2 沒有 PSU，合成值是唯一選項，header 寫了整段說明，而且**原本**是 [0, 2⁶⁰) 亂數（1.9×10¹⁴ 瓦），是我改成合理的。**但底下有站得住的點**：API 沒告訴消費者這是合成的，Energy-Saving-App 分不出真假 —— 那是真的設計缺口 |
| 「`ryu_topology` / `kernel_notifier` 完全沒測試」 | **事實錯誤** —— 24 + 13 個測試早就在 |
| 「`topology_manager` 完全沒測試」 | ⚠️ **audit 當時是對的，是我判斷錯了。** 我引用的那 9 個測試（`test_unsupported_match.py`）是**我自己在 `c964946` 加的**，不是既有的 —— audit 的基準 `be3c242` 當時確實沒有。**這是我過度更正別人的一個實例**，由第二輪 scoped review 抓出來 |
| 「`Host: 127.0.0.1` 是 SSRF 技巧／繞過 Gateway 權限」 | gateway 設定不在這個 repo 裡，**從程式碼無法判定意圖**。可確定的是寫死且無註解，該解釋或移除；但「後門」的推論證據不足 |

### 1k. scoped review（`doc/audit/scoped/`）的逐項判定（2026-07-31）

範圍是 `be3c242..576dd2a`（24 commit、+4566/−216，其中約 1900 行是新測試）。**這一輪的品質明顯
高於第一輪**：22 條發現裡我查證過的**只有 1 條是錯的**，而第一輪是 4 條。它也做了第一輪沒做的事
—— 主動列出「我檢查過而且認為沒問題的」，所以「沒出現在發現清單裡」可以解讀成「查過了」。

#### 🔴 4 條 high，全部成立，全部已修（commit `e188136`）

| 發現 | 我的獨立查證 |
|---|---|
| **`ctest` 是紅的，而我報告綠的** | ✅ 跑 `ctest` 立刻重現 3 個 SEGFAULT，全是我新加的 `test_OvsPowerStrategy.cpp`。原因：沒有 `Logger::init`，而 `Logger::instance()` 在 init 前是 null shared_ptr。**只有 3 個中招**是因為 `powerOn` 的 port 迴圈裡有 `SPDLOG_LOGGER_DEBUG`，沒有 saved port 的測試不進迴圈。⚠️ **這個要求早就逐字寫在 `test_ClassifierDropRule.cpp` 裡了，我沒照做** |
| **`KeyedFailureLog` 對間歇性故障永遠不報** | ✅ 自己寫探針編譯真 header 驗證：**99% 的 pass 都在失敗、十分鐘 → 報告 0 次**；10 秒 burst → 0 次。hold-off 量的是「連續」不是「累積」，未報告的 key 缺席一個 pass 就被 erase |
| **route-reinstall debounce 丟掉 walk 期間的變更** | ✅ 讀程式碼確認：worker 在 `install_all_pair_paths`（~60 秒）**之前**就離開監看 seq 的迴圈，而 `reinstall_worker_running` 整段都是 True → 早退丟掉 |
| **`wait_for_port` 的守衛是死碼** | ✅ 內層檢查和外層**逐字相同**。它從來沒偵測過註解宣稱的事 |

#### ⚪ 1 條判定它錯了

| 發現 | 為什麼錯 |
|---|---|
| 「`test_unsupported_match.py` 無法 import —— 三個 interpreter 都沒有 networkx」 | **L1 用的那個有。** `l1_unit_tests.sh` 的候選順序是 `$P4_PROXY_PY` 優先，也就是 `p4_proxy/venv/bin/python`，實測 `Ran 9 tests OK`。它測了三個 interpreter 但漏了 L1 實際選的第一個 |

#### ⚠️ 它抓到我一個「過度更正別人」的實例

「HANDOFF 把 `topology_manager` 的 9 個測試記成既有的」—— **成立**。那 9 個是
`test_unsupported_match.py`，**我自己在 `c964946` 加的**，audit 的基準 `be3c242` 當時確實沒有。
而我還用那個數字在第 1h 節宣告第一輪 audit「事實錯誤」。**就 `topology_manager` 而言，第一輪
audit 當時是對的。** 已更正第 1h 和 1i 節。

教訓：**否證別人的發現時，要查證的是「在他的基準上成立嗎」，不是「在我現在的樹上成立嗎」。**

#### 🟠 已查證成立、已修的 medium

| 發現 | 處置 |
|---|---|
| `AFailedPortCommandFailsTheWholeOperation` 檢查的是失敗那個 port **之前**的 port | ✅ 已修（`6731b56`）。改成失敗第一個、斷言後兩個仍然裝上並 up。mutation 確認現在殺得掉 |
| `SomethingTooBigForIntIsRejectedNotWrapped` 斷言的是兩個常數的算術 | ✅ 已修（`6731b56`）—— 刪掉那個斷言而不是改寫措辭，因為那個界限在 handler 裡、這裡碰不到 |
| `endPass()` 「呼叫兩次」的註解描述錯了後果 | ✅ 已修（`e188136`）。它說會重複報同一個 recovery —— 不可能，因為 recovered 的 key 在報告的同一次呼叫裡就被 erase。真正的後果**更糟**：把所有還開著的故障報成已恢復 |

#### 🟠 已查證成立、**未修**（下一批）

| # | 發現 | 為什麼還沒修 |
|---|---|---|
| 1 | **`app_id` 的修正完全沒測到** —— 把 `std::stoi` 放回去，207 個測試照樣綠 | 要能驅動 handler，而 `HttpSession` 沒有接縫（從 live socket + 11 個協作者建構）。**為這一個端點發明捷徑會讓另外 40 個看起來測過了** —— 這是要設計的接縫，見待辦 |
| 2 | **FlowDispatcher 的 lost-wakeup 修正沒有測試抓得到** —— 跑 300 次都存活 | 要真的重現 lost wakeup 需要控制排程時序。它說得對，我的測試只覆蓋了另外兩個 lifecycle 缺陷 |
| 3 | `test_unsupported_match.py` 從來沒呼叫 `route_flow` —— 三個 `raise` 全改 `pass`，9/9 綠 | 同 medium 1 的性質：只測了兩個 module-level helper |
| 4 | static 模式啟動允許第二個並行的 `install_all_pair_paths` | 需要 OVS + Ryu 驗證 |
| 5 | `describeCommandStatus` 把 `curl`／`snmpget` 的 exit 1／127 歸咎給 `ovs-vsctl`／sudo | **我搬到 `utils::` 時造成的** —— 它現在被 13 個 SNMP 呼叫點用到 |
| 6 | `_is_routable_unicast` 讓 `inv_flow_paths_non_empty` 檢查零筆 flow 也算 PASS | tooling 的假 PASS |
| 7 | `kernel_owns_log` 看不到 root 起的 kernel → 對手冊的啟動方式假 FAIL | 和第 5 項同一類：手冊教 `sudo -E` |
| 8 | 兩條 allowlist pattern 比它們寫的理由寬得多 | `field missing in P4: \[\]\.flows` 是未錨定的 `re.search` |
| 9 | `handleGetNickname` 把壞 dpid 記在 `inform_switch_entered` 的名下 | 一行 |
| 10 | `on_link_delete` 把圖的更新 gate 在一個沒有 timeout 的 `requests.post` 上 | 需要 Ryu 驗證 |

### 1i. 測試覆蓋率現況（audit 點名「沒測試」的對象）

我的做法是**「改到哪就測到哪」**（先修會崩的、再補覆蓋率），這是刻意的取捨。以下是實況 ——
⚠️ 用 grep 檢查會騙人：`HttpSession`、`api_routes`、`p4_testbed_topo` 都只是**被別的測試檔在註解裡提到**。

| 對象 | 現況 |
|---|---|
| `FlowDispatcher` | ✅ 6 個（`d5f5bfa`，因為修了它的 bug） |
| `Controller` | ✅ 8 個（`ba97ab3`） |
| 參數解析（`tryIpStringToUint32` / `tryParseUint64`） | ✅ 11 個（`832d75c`） |
| `ipToString` 併發 | ✅ 4 個（`95c7690`） |
| `KeyedFailureLog` | ✅ 12 個 |
| `ryu_topology` / `kernel_notifier` | ✅ 24 / 13（早就存在）|
| `topology_manager` | ✅ 9（`c964946`，**我加的**）+ 20（`a8db425`）—— 上一版誤記為「早就存在」|
| **`HttpSession`（除了參數解析）** | ❌ |
| `OVSPowerStrategy` | ✅ 12 個 + wait-status 8 個（`65aaa38`）。⚠️ 上一版這裡寫「要先修接縫」是**過期資訊** —— 那個洞早就補掉了 |
| **`P4PowerStrategy`** | ❌ |
| **`TopologyAndFlowMonitor`（2500 行）** | ❌ 無獨立測試。要先想清楚接縫（被 `getGraph()` 深拷貝隔開） |
| **`ApplicationManager` / `SimulationRequestManager`** | ❌ |
| **`SSHHelper` / `execCommand`** | ❌ **刻意最後做** —— 它們的核心問題是 shell injection，補測試而不修注入只會把現狀凍結 |
| **`p4_testbed_topo.py`** | ❌ |

### 1j. 工作方法：四個一直在付利息的教訓

這些不是瑣事，是這個 codebase 的失效模式，每一條都在這次會話中至少救了一次。

**1. 測試要用 mutation 驗證有沒有牙齒。** 兩次抓到我自己說大話：

- `test_Controller.cpp` 第一版 5 個測試**全部通過，即使把 bug 放回去**。它斷言了除了「它存在的理由」以外的一切。那個 bug 的本質是**一行 log 的缺席**，所以必須用 capturing sink 把 log 當斷言對象
- `test_IpToString.cpp` 的註解原本寫「這是唯一能抓到它的測試形狀」，一分鐘內就被 mutation 打掉（`inet_ntoa` 也通過）

**綠燈的測試如果不會為了它宣稱的理由而失敗，比沒有測試更糟，因為它說的是反話。**

**2. 信任 live 測試之前先確認環境。** 殘留的 kernel 佔住 `:8000` 咬了**三次**：

| 次 | 後果 |
|---|---|
| 1 | `stack.sh up p4` 假成功 —— 整輪 P4 測到的是殘留的 **OVS** kernel（288 edge、128 host），沒有任何東西提示 |
| 2 | 你得問我「:8000 這樣正常嗎」 |
| 3 | 我量到的 500 是舊 binary 回的 —— 而且那個 kernel 是 `sudo -E` 起的，**我普通身分殺不掉** |

已加的防護：`wait_for_port` 檢查自己起的 process 還活著；`stack.sh down` 檢查殘留埠並回傳非 0；
`run_logcheck` 檢查**有活著的 kernel 正在寫那個 log**（曾經對一個 37 分鐘前、不同模式的舊檔案給出「結論」）。

**3. 過期的文件比沒有文件更糟。** HANDOFF 的環境狀態在同一天內過期兩次，其中一次讓我把
「`up=0/10`」誤判成修正失敗（真相是根本沒有 data plane 在跑）。所以第 5 節現在寫的是**現場確認的指令**，
而不是狀態快照。

**4. log 洪泛會埋掉答案。** `edge not found by dpid/port 4:3` 印了 **270,991 次**（41 MB），
而那一行**就是** P4 拓撲 port 寫錯的答案。它被 allowlist 掉（所以 log 檢查是綠的）又被埋在 41 MB 裡
（所以沒人讀）。重複 27 萬次的訊號和噪音無法區分。

### 2. L2 契約的失敗清單（2026-07-31 更新）

| 項目 | 狀態 |
|---|---|
| `install_flow_entry__unknown_dpid` → 200 | ✅ **已修**（`8c25dbc`）—— 改成請求當下就檢查 dpid，回 404 |
| `get_path_switch_count__bad_ip` → 500 | ✅ **已修**（`832d75c`）—— `tryIpStringToUint32`，回 400 |
| `inform_switch_entered__bad_dpid` → 500 | ✅ **已修**（`832d75c`）—— `tryParseUint64`（比 `stoull` 嚴格），回 400 |
| `received_a_simulation_case` ×2 → 202 | ✅ **已修**（`05353d5`）—— `validateRequestBody`，回 400。**L2 錯誤路徑至此全綠** |
| `get_graph_data`（256 條 host edge down）| ✅ **已修** —— 見下，原本的解釋是錯的 |

✅ **已修（2026-08-03）—— 而且原本的解釋是錯的。**

原本記的是：「Ryu 報告 97 台 host 但 `ipv4` 都是空陣列，因為 host 不發 ARP（static ARP），Ryu 學不到
IP」。**那個因果不成立。** `testbed_topo.py` 設完 static ARP 之後**自己平行 ping 全部 128 台 host**
（64 對 × 雙向），每台都送出 IP 封包 —— 那就是教會 Ryu 的東西。實測：Ryu 現在報 128 台，**128 台
全部有 ipv4**，零台空陣列。所以空 `ipv4` 是**暫態**，不是永久限制。

**真正的原因，而且比原本記的廣得多**：`TopologyAndFlowMonitor::run()` 呼叫
`fetchAndUpdateTopologyData()` **一次就 return**。實測：`run` 在 13:55:55.154 進入、**.242** 離開
——**88 毫秒**——然後整個 process 生命週期內再也沒有重讀。整張圖（switch、host、link **全部**）
就是 Ryu 在那一瞬間知道的東西。

所以「時間的函數」是對的，但變數是**啟動間隔**：

| 啟動方式 | 那一次快照抓到什麼 |
|---|---|
| 手動、比 Mininet 晚 73 秒 | ping burst 早就跑完 → **128/128 host up** |
| `stack.sh up ovs`（背靠背）| 快照落在 burst 中間 → **永久性缺料** |

同一份程式碼、同一個網路、不同判定。host 是最明顯的症狀，因為**它完全沒有 push 路徑** ——
switch 走 `/ndt/inform_switch_entered`、link 失效走 `/ndt/link_failure_detected`，但**沒有任何東西
push host**。

**修法**：`run()` 改成定期輪詢（前 90 秒每 5 秒、之後每 30 秒），只有數字變動時才印一行。

⚠️ **動手前先查證了一件會讓這個修法變危險的事**：定期重拉會不會把「正確地標成 down」的 link 復活？
實測 Ryu 的 `/v1.0/topology/links` **確實會**移除失效的 link（32→30，2 秒內）並在恢復時加回
（→32，8 秒內），而且 `updateLinks` **只設 `isUp = true` 從不設 false**。所以輪詢只能補齊漏掉的，
不能推翻 push 路徑的正確判斷。

**⚠️ 實測抓到我自己的一個嚴重 bug，單元測試抓不到。** 第一版的輪詢迴圈讓圖**不斷增長**：
switch 10→20→30→40→50、host 128→640、edge 288→1440，每 5 秒多一整份拓撲。原因是
`fetchAndUpdateTopologyData()` **開頭就呼叫 `loadStaticTopologyFromFile`**，而那個函式是**新增**
頂點、不是對帳。這在之前不可能被發現，因為它一個 process 只被呼叫一次 —— **重複只在「第二次呼叫」
出現，而第二次從來沒發生過**。已把載入和輪詢拆開，並且讓 `loadStaticTopologyFromFile` 對第二次
載入直接拒絕（守衛放在函式裡而不是只放在呼叫點，因為那個陷阱屬於它自己）。

**決定性驗證**（重現失敗條件，不是只看它現在是綠的）：

| 步驟 | 結果 |
|---|---|
| 先弄斷一條 link，**然後**才啟動 kernel | 286/288 edge（快照正確地漏掉它）|
| 修復 link，Ryu 報回 32 | — |
| **5 秒後** | **288/288** ✅ 舊程式碼下這條邊會永久停在 down |

log 紀律：~50 秒的輪詢只印 2 行（啟動時 286、恢復時 288），靜態拓撲載入 1 次，零 warning。

### 2b. 待辦清單（依建議優先序，2026-07-31）

排序理由：**先修「系統對現實的認知是錯的」，再補覆蓋率，最後做新能力。** 因為前者的失敗是無聲的。

| # | 項目 | 為什麼在這個位置 |
|---|---|---|
| ~~1~~ | ~~`SimulationRequestManager`：爛 JSON／缺欄位回 202 → 400~~ | ✅ **已完成**（`05353d5`）—— 見下面「已完成」段 |
| ~~2~~ | ~~`OVSPowerStrategy` 補測試~~ | ✅ **已完成**（`65aaa38`）—— 前提是錯的（接縫早就補好了），但挖到一個 audit 沒提到的真 bug。見下 |
| 3 | `setSwitchPowerState` 不論成敗都更新圖 | 同一類「靜默成功」，TESTBED-only |
| 4 | `/ndt/disable_switch` 幽靈端點 | 要嘛實作、要嘛讓 app 停止呼叫。**節能功能可能從來沒生效過** |
| 5 | host 發現的 static ARP 問題（定期重拉 host） | 讓 `get_graph_data` 從 flaky 變成穩定 |
| ~~6~~ | ~~**P4 liveness stub**~~ | ✅ **已完成**（`a8db425`）—— 見下方「待辦第 6 項」段。過程中挖到兩個 bug |
| 7 | LLDP beacon：port 從拓撲推導、beacon MAC 不要撞 host 範圍、install 改 insert-or-modify | 第 6 項已建好 last-seen 追蹤，這項現在只剩 beacon 本身的三個缺陷 |
| 8 | **`HttpSession` 的測試接縫** | scoped review 的 medium 1：`app_id` 修正完全沒測到，把 `std::stoi` 放回去 207 個測試照樣綠。要設計接縫，不能為單一端點發明捷徑 |
| 8b | **scoped review 剩下的 10 條 medium/low** | 清單見第 1k 節。第 5、7 條是我搬 `describeCommandStatus` 造成的 |
| 9 | 審查 agy-review 0057 之後的（共 80+ 份） | 和 audit 重疊度高，所以降級 |
| 9 | 修正計畫書 Phase 6 那段錯誤敘述 | 只有狀態章節記了更正，本文還沒改 |
| 10 | `TopologyAndFlowMonitor` 補測試 | 工程量最大，要先想清楚接縫 |
| 11 | twin 偵測黑洞 flow（入口有量、出口沒有） | **新能力，不是修 bug** |
| 12 | 重算路徑只覆蓋走得到的規則 | BFS 走不到的交換機留著舊規則。10 台全連通時不影響 |

**驗收清單還沒做的**（`p4_bmv2_support_plan.md:257`）：第 6 項（電源關機）要等 Phase 7；
第 7 項的 HTTP status 傳遞缺口需要 completion handle，是架構決定不是小改（見 1f）。

#### 待辦第 6 項已完成（2026-07-31，commit `a8db425`）—— P4 liveness

`pingWorker` 對每台 bmv2 **無條件** `setVertexUp`，一秒一次，**沒有任何證據**。被殺掉的 switch
一秒內就回報健康，所以 twin 永遠顯示不出故障。而 `is_up` 是 power／CPU／溫度／`getAvgLinkUsage`
的前置條件 —— **一個造假的欄位讓好幾個其他欄位失去意義**。這是最後一個會說謊的欄位。

**設計：proxy 報事實，kernel 下判決。** 這樣「我問了它不答」和「我問不到」的區別能撐過那一趟。
把這兩者混在一起，就是當初一次 `ovs-vsctl` 失敗把整個 OVS fabric 標成死的原因；而這裡更嚴重
—— **一個 proxy 對應十台**。

| 訊號 | 為什麼選它 |
|---|---|
| `probe()` = `GetForwardingPipelineConfig` + `COOKIE_ONLY` | P4Runtime 裡最便宜的請求。**唯一真正證明 bmv2 process 活著在服務的訊號** |
| LLDP 新鮮度 | 證明它**在轉封包** —— bmv2 不管 pipeline 通不通都會回控制平面 RPC |

**拒絕過的兩個更弱方案**（理由寫在程式碼裡）：gRPC channel 的 connectivity state 在沒人推它時停在
`IDLE`，所以**閒置時被殺掉的 switch 讀起來是健康的**，而且只能透過私有屬性拿；stream receiver
thread 在正常 `stop()` 時也會結束，分不出「死了」和「關掉了」。

**LLDP 新鮮度原本完全不存在** —— `handle_packet_in` 只在「邊是新的」時才動作，而拓撲幾秒內就收斂，
所以**之後每一個 beacon 都被丟掉**：每分鐘上千個 proof-of-life 全部浪費。

**移除了 host force-up。** 它的理由（「proxy 沒有 host feed」）已經不成立：proxy 的
`render_hosts` 會發 MAC + 非空 `ipv4`，正是 `updateHosts` 需要的。留著會**遮住它掩護的那個故障**
—— 如果 proxy 的 MAC 格式哪天不再匹配 `findVertexByMac`，host discovery 會壞掉而每台 host 照樣
顯示 up。實測：host 維持 4/4。

##### 實機驗證（10 台 bmv2）

| 場景 | 結果 |
|---|---|
| 健康 | 10/10 up、4/4 host、**0 個 warning** |
| 殺掉一台 bmv2 | 該台 ~10 秒後變 down **並留在 down**，其他九台不受影響 |
| 殺掉 proxy 60 秒 | **圖完全不動**，總共 **2 行**警告 |
| proxy 復原 | 各一行恢復訊息，附次數（76 和 63）|
| **proxy 在有一台死掉時啟動** | 起得來，回報 9 台可用 |

⚠️ **~10 秒的偵測延遲是「衝突證據」規則在動作，不是巧合**：probe 立刻失敗，但判決維持 `Unknown`
直到最後一個 beacon 老化超過 `kLldpFreshSeconds`。這是從 proxy 自己的回報確認的，不是推測。

##### 過程中挖到兩個 bug，都修了，因為兩個都會架空這個功能

1. **一台 bmv2 死掉，整個 proxy 起不來。** 批次 pipeline push 沒有 try/except，而
   `set_forwarding_pipeline_config` 對沒在聽的 switch 會拋 `_InactiveRpcError`；uvicorn 把 startup
   event 的例外當致命，所以 process 以 **exit 3** 結束 —— 另外九台的 telemetry、拓撲、flow 安裝
   一起沒有。**對 liveness 更致命：如果 proxy 在有 switch 掛掉時根本跑不起來，`Down` 就只在
   「proxy 起來之後才死」的情況下觀察得到。**
2. **一次四分鐘停機噴 216 行沒 allowlist 的 `[error]`。** `/stats/flow/<dpid>` 的空 body 是
   **控制平面不在**，不是 JSON 壞掉，卻被丟進 parser，每台每輪一次。改成 edge-triggered。
   60 秒停機從 ~54 行/分鐘變成**總共 2 行**。

##### mutation 驗證：7 個 C++ mutant 全殺，proxy 端 2 個第一次存活

兩個存活的都記下來，因為它們揭露的是**我的斷言**而不是程式碼：

1. **拿掉 evidence lock，全部測試照樣綠。** 我的註解宣稱「沒有鎖這裡會噴 `dictionary changed size
   during iteration`」—— **假的**。CPython 的 GIL 讓 `d[k]=v` 和 `set(d)` 是不可中斷的 C 呼叫，
   **在這個層級寫不出任何測試能證明那個鎖是承重的**。鎖該留（快照一致性 + free-threaded build 沒有
   GIL 保證），註解改成講這個，並明說測試實際斷言的範圍比名字小。
2. **迭代活的 switches dict 看不見** —— probe 是瞬間的，一輪太短，registration 落不進去。改成
   20 台 × 每次 probe sleep 20ms，把一輪拉長到 ~400ms，mutant 現在會以真正的 `RuntimeError` 失敗。

##### 一個測試逼我改了程式

`{"probe_ok": false, "last_lldp_age_s": "ages"}` 原本回 `Down`。判定**程式該改**：

- `null`／不存在 = proxy 說「沒東西可報」→ 合法，不該阻止判決
- `"ages"` = **schema 違反**，兩個 process 對欄位型別認知不一致 → 這是「讀不出來」

proxy 升級改了欄位型別時回 `Down` 會讓整個 fabric 變黑 —— **正是這個 policy 存在的目的**。
改成 `Value`／`Absent`／`Malformed` 三態。

##### 一個 HANDOFF 之前沒記到的環境細節

`tools/test_workflow/l1_unit_tests.sh` 是**直接執行**每個 Python 測試檔並解析 `Ran N tests`
（unittest 格式），**不是 pytest**。寫成 pytest 風格會被判「NO TESTS RAN」—— 一個綠燈但什麼都
沒驗的狀態。新測試檔請用 `unittest.TestCase`。

#### 待辦第 1 項已完成（2026-07-31，commit `05353d5`）

`received_a_simulation_case` 對**任何**東西都回 202 —— 包含字面上的 `{not json`。body 從來沒被
parse 過，直接進 curl 命令列，simulator server 回什麼（包含拒收所以什麼都沒回）都被包成
`{"status": "..."}`。應用程式沒有任何辦法知道自己送了垃圾。

那五個必填欄位**不是 kernel 自己發明的**：Simulation-Platform-Manager 的
`from_json(SimulationTask)` 對每一個都做 `j.at(f).get_to(std::string)`，所以擋不下來的 body 是在
**那個沒辦法回應呼叫端的 process 裡**炸掉。而 `doc/ndt_api.md` 第 17 節**本來就寫 400** ——
所以是程式碼和契約不符，不是測試訂太嚴。

順手修掉同一類的 `simulation_completed`：`std::stoi` 解 `app_id`。爛 JSON 和缺欄位本來就走
`json::exception` 回 400，但 `std::stoi("abc")` 丟的是 `std::invalid_argument`，**不在那個 catch
裡** → 500。更糟的是 `stoi("1abc")` 是 1、`stoi("-1")` 是 -1，所以打錯字會**把結果轉給另一個
應用程式，還回 200 OK**。

⚠️ **刻意沒動的**：body 依然未經 escape 就進 shell。界線寫在三個地方（header 的 `@warning`、
插值處的 NOTE、以及一個斷言「驗證只看形狀」的測試），**這樣沒有人會把那個 400 誤認成消毒**。
那個測試是寫成「注入修好之後它就該失敗」，並附帶當下該怎麼改。

**mutation 驗證抓到我自己兩個假斷言**（第 1j 條教訓又收了一次利息）：

1. 拿掉 `is_null()` 檢查**什麼都沒發生** —— null 會落到 `is_string()` 分支，照樣被拒。所以那個
   叫 `RejectsNullAsAbsent...` 的測試**從來沒驗到「as absent」**。改成斷言分類，因為分類才是診斷
   本身：`"case_id": null` 意思是呼叫端沒給值，該讀到的是「缺欄位」不是「型別錯誤」。
2. **把 `requiredRequestFields()` 縮短，兩個測試看不到** —— 因為它們的期望值是從同一份清單推導的
   （同義反覆）。補了一個把五個名字**字面寫死**的測試，否則清單可以悄悄停止檢查某個欄位而全部保持綠燈。

#### 待辦第 2 項已完成（2026-07-31，commit `65aaa38`）

⚠️ **這一項的前提是錯的。** 待辦寫「要先修接縫（`OVSPowerStrategy.cpp:49` 直接呼叫
`utils::execCommand`）」—— 那個洞**早就補掉了**，程式碼裡還留著說明它的註解。這是本文件第二次
用過期資訊誤導我自己（第 1j 教訓 3）。**接縫是完好的，這一項單純只是缺測試。**

但寫測試的過程挖出一個 **audit 沒提到、而且比 audit 提到的那項嚴重**的 bug：

`executeListPorts` 對「查詢失敗」和「bridge 真的沒有 port」都回空 vector —— `pclose` 的 status
從來沒檢查。實測 `sudo ovs-vsctl list-ports s99`（不存在的 bridge）是 **exit 1 + 完全沒有輸出**，
所以**退出碼是唯一能區分兩者的東西**。

而 `powerOff` 在**檢查任何東西之前**就把那個空清單寫進圖，然後 `del-br`：

```
list-ports 失敗 → 回空 vector
  → setMininetBridgePorts(node, {})   ← 圖裡存的 port 清單被清空
  → del-br s1                          ← bridge 被刪掉
  → 兩份紀錄同時消失
  → 之後 powerOn 建出一個沒有任何 port 的 bridge，並 setVertexUp
```

**結果是交換機回報健康、但沒有 data plane 接著**，而且沒有任何指令看起來失敗過。跟第 1b 節那個
「`list-br` 失敗把整個 fabric 標成死的」是**同一種混淆**，但這個是永久性的 —— 1b 那個下一輪就會
自己恢復，這個把唯一的紀錄銷毀了。

修法：`executeListPorts` 回 `std::optional`（`nullopt` = 查不出來），`powerOff` 查不出來就**拒絕
執行** —— 不寫圖、不刪 bridge、不標 down，理由放進 `OpResult`。**刪 bridge 是不可逆的，不能在
狀態未知時做。**

順手把 `describeCommandStatus` 移到 `utils::`：`OVSPowerStrategy` 在 log **原始 wait status**，
所以 `add-br` 撞到既有 bridge（實測 exit 1）被印成 `status 256`。那個解碼器早就為 liveness probe
寫好了，只是當時是就地寫死的。`utils::execCommand` 有同樣的問題，一起修。

**還留一個洞，用測試記錄而不是修掉**：`powerOn` 在沒有存過 port 的情況下會建出空 bridge 並回報
成功。vertex 初始是 `isUp=false`，所以剛載入拓撲時就走得到。沒修是因為**修法是個決定**（port 該
從哪來？靜態拓撲？），不是這個 class 的 bug。測試註解第一句就寫「recording, not endorsing」。

**另外學到一課：mutation harness 自己也要驗證。** 我第一次跑回報「四個 mutant 全部存活」，那是
`grep -v "("` 把兩種 FAILED 行都濾掉了 —— **不是測試沒用**。差一點得出完全相反的結論。現在
harness 會先確認 `MUTANT` 標記真的進了檔案才跑。

### 2c. ⚠️ Ryu 卡死：實機重現，這很可能就是第 1c 節那個「死因未定」（2026-08-03）

**狀態：新發現，未修，需要優先處理。** 我在恢復 Ryu 之後意外重現了它，而且這次留下了證據。

#### 量到的事實（不是推測）

| 觀察 | 數據 |
|---|---|
| Ryu 的 WSGI 忙碌程度 | **97%** —— 141.8 秒的請求處理／146 秒的時窗 |
| `/stats/flow/<dpid>` | 150 次，**平均 0.938 秒**，共 140.7 秒 |
| `/v1.0/topology/*` | 9 次，平均 0.001 秒 |
| kernel 的輪詢間隔 | `openflowTablesUpdateWorker` 是 **1 秒一輪，一輪 10 台** |
| 卡死後：接受但從未回應的連線 | **8 個**，全在 `CLOSE-WAIT` |
| 卡死後：OpenFlow socket 的 `Recv-Q` | **每條連線 88 KB 未讀** |
| process 狀態 | 活著、1.3% CPU、單執行緒、停在 `ep_poll`、**沒有 traceback** |
| 客戶端停止後 | **沒有恢復** |

#### 為什麼這很重要

1. **kernel 一台就把 Ryu 的 REST 吃到 97%。** 每秒要 10 台 × 每台 0.94 秒 = 需要 9.4 秒的服務時間，
   而只有 1 秒。任何其他 REST 消費者（Web GUI、契約測試、Network-State-Recorder、手動 curl）都在
   跟它搶，而且會逾時。**這是做整合測試前必須知道的容量問題。**
2. **88 KB 未讀的 OpenFlow 資料表示 hub 已經停止調度** —— 它不只是慢，是不再讀 socket。
   cooperative greenlet 只要有一個卡在不 yield 的地方，全部停擺。
3. **它「接受連線但不回答」** —— 這正是我今天 `timeout=(2, 5)` 那個修正的前提。我原本寫「需要故意
   弄一個卡住的 listener 才能驗」，結果它自己發生了。**那個修正的必要性因此是實測的，不是推論的。**

#### 還不知道的

**哪一個 greenlet 卡住。** CPU 接近 0 且停在 epoll，所以它在等 I/O 而不是在算東西 —— 但沒有 py-spy，
拿不到 Python stack。**不要在這裡猜**：我一度想歸咎 `requests.post`，但這次跑的是已經加了 timeout 的
版本，而且完全沒有 link 事件觸發，所以那條路沒被走到。

#### 下一步建議

1. `pip install py-spy`，下次卡住時 `py-spy dump --pid <ryu>` —— 這會把猜測變成事實。
2. **降低 kernel 的 flow-table 輪詢頻率或改成並行**。1 秒一輪、10 台循序、每台 0.94 秒，本來就
   不可能跟上，等於持續飽和。
3. 查 `ofctl_rest` 的 `/stats/flow/<dpid>` 為什麼固定 0.94 秒 —— 那個數字太整齊，像是在等一個
   固定逾時而不是在等回覆。

### 3. 刻意延後的技術債

- **shell injection**：每條南向指令都是 `popen("curl … -d '" + json.dump() + "'")`，
  `nlohmann::json::dump()` 不會 escape 單引號，而 JSON 來自未認證的 REST body 和 LLM 輸出。
  3 個檔案共 22 處。**你說過要先跟其他人討論再處理。**
  audit 又點出**兩個同性質的地方**：`SimulationRequestManager`（`m_req.body()` 未消毒直接進 bash，
  影響 `/ndt/received_a_simulation_case` 和 `/ndt/simulation_completed`）和 `SSHHelper`
  （`username`／`ip` 未消毒進 `ssh` 指令）。**一併延後，範圍相同。**
  ⚠️ 待辦第 1 項會動到 `SimulationRequestManager` 的 status code —— **只改 status code，
  不動指令組裝**，界線寫在註解裡。
- **P4 parser 沒檢查 IHL**、**分片封包繞過 L4 規則**：Mininet 環境不會觸發，修要動 pipeline。
- **`send_to_cpu` 沒有 rate limiter**：任何 controller-based learning switch 的通病，OVS 那側也一樣。

### 4. 沒驗證成功的東西

- **P4 的 direct counter / per-port counter**：讀不到。`simple_switch_CLI` 需要 `thrift` 的
  Python binding，兩個 interpreter 都沒裝（見 environment_gotchas）。要驗證得先 `pip install thrift`。
- **`P4RoutingStrategy` 實際下規則的完整路徑**：每一段都有單元測試，但 curl → proxy → P4Runtime
  整條沒對活的 switch 跑過。
- **PI 對重複 clone session 回什麼 status code**：`write_clone_session()` 的 `ALREADY_EXISTS` →
  `MODIFY` fallback 從來沒在實機上被觸發驗證過。曾經看到一次失敗但 `details()` 是空字串所以無法判斷
  （已改成連 `code().name` 一起印）。要驗證的話：對活的 switch 連續寫兩次同一個 session。

### 5. 執行環境狀態

> ⚠️ 這一節**很容易過期**，而過期的環境狀態比沒有還糟 —— 它讓 live 測試的結果無法解讀
> （見 1j 的教訓 2 和 3）。**一律用下面的指令現場確認，不要相信這裡寫的快照。**

```bash
pgrep -x ndtwin_kernel; pgrep -x simple_switch_g      # 空 = 沒在跑
#                        ^^^ 只到 15 字元：comm 欄位上限，寫全名永遠匹配不到
pgrep -af "[t]estbed_topo.py"                          # 中括號避免匹配到自己的 shell
sudo ovs-vsctl list-br                                 # 空 = 沒有 OVS bridge
ss -ltnp '( sport = 8000 or sport = 8080 or sport = 8081 )'
```

⚠️ **kernel 可能是 root 起的**（手冊教 `sudo -E bin/ndtwin_kernel`），那樣普通身分 `pkill` 殺不掉，
而它佔住 `:8000` 會讓下一個 kernel 直接 `bind: Address already in use` 而 abort。用
`sudo pkill -x ndtwin_kernel`。

**2026-07-31 收工時的狀態**（會過期）：OVS Mininet + Ryu（帶 link-failure 重算修正）+ 我起的
kernel 都在跑，s1-s5 已接回、32 條 link，我起的 iperf（h1→h34）可能已到期。

**切換模式**：`./stack.sh down`（現在會檢查殘留埠）→ Mininet terminal `exit` → `sudo mn -c`
→ `pkill -x simple_switch_g`。**兩個 Mininet 不能同時開。**

`.test_run/baseline/{ovs,p4}` 兩份基準都是 2026-07-31 在**四項前置檢查都通過**時抓的
（link usage 非零、flow 有 rate、path 非空、有 flow_set 的邊），可以信任。抓基準前一定要做那四項檢查
—— 見 [full_test_runbook.md](full_test_runbook.md) 步驟 1f。
