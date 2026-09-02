# 工單 Q 增補（2026-09-02，`9/1 mainDev`）：延後的那一半，與掃描漏掉的那條路

PREREG 是 append-only，所以這是增補，不改本文。兩件事：**(B) 被裁定延後**，
以及**當初界定範圍的方式漏掉了每條流那條路**。

[Co-developed with claude code -- Adam]

---

## 1. `sleep_until` 延後（auditor 2026-09-02 夜裁）

PREREG §Q-1 註冊的是 **(A)+(B) 兩者都做**：

- **(A)** 除以實測經過時間 → **已落地**，`f5e35561`。
- **(B)** `sleep_until` 讓穩態週期真的等於 1 s → **沒有落地**。
  `FlowLinkUsageCollector.cpp:1851` 至今仍是 `this_thread::sleep_for(chrono::seconds(1))`，
  而且在本體之前，所以週期 ＝ 1 s ＋ 本體耗時。

**裁決**：今晚不做，排到測試輪結束之後。理由三條，第三條是硬的：

1. 正確性不欠——分母用的是實測間隔，週期多長都除得對，延後的代價有界且已知。
2. 它要重編，而重編會換掉 `build/bin/ndtwin_kernel`，那正是 09-02 夜間四輪測試正在量的那顆。
   半夜換掉它，已跑完的輪次會變成量了一個不存在的組態。
3. 它要 live 驗週期行，而 lab 到 07:34 被測試輪佔滿。

### 🔴 延後期間必須揭露的兩件事

**不寫出來，這兩件會被當成結果讀。**

1. **分身發布的是 1.03–1.25 s 的平均，不是 1 s 的平均**，而且**視窗隨負載變長**
   （08-27 量到 16 流 1.033–1.040 s、64 流 1.032–1.061 s，第一代 fabric 64 流 1.249 s；
   那是當時那顆 binary 的讀數，今天沒有重量）。
   ⇒ **最忙的時候數字最舊。** 任何引用「每秒」速率的頁面都要講成「約一秒」。
2. **兩條臂本體成本不同時，平均視窗也不同。**
   ⇒ 那是**系統性的臂間差異，不是處理效果**。配對比較若一臂的本體較重，
   它的視窗較長，兩臂就不是在同一個時間尺度上被量。不揭露會被當成結果。

⚠️ 單獨做 (B) 而不做 (A) 是危險的：本體一旦超過 1 s，週期又會溢出，
而那時候碼裡沒有除法保護它。現在落地的剛好是安全的那一半——**值永遠對，節奏不準**。

---

## 2. 🔴 範圍是用一個 grep 界定的，而每條流那條路不叫那個名字

PREREG 的增補（§「兩處都要修」那張表）是這樣界定範圍的：

```
grep -n "MultiplySampingRate" FlowLinkUsageCollector.cpp
```

表裡兩列都是 `累加器 * 8` 送進 `updateLinkInfoLeftLinkBandwidth`，兩處都修了。
**但每條流的速率用的是另一個變數，所以那個 grep 從來沒看到它**：

`FlowLinkUsageCollector.cpp:1934`（唯讀查證，2026-09-02）

```cpp
stats.avgByteRateInBps =
    sflow::counterDelta(byte_count_current, byte_count_previous) * 8 * currentSamplingRate;
```

`:1952` 的封包速率同形，`counterDelta(...) * currentSamplingRate`，同樣沒有除法。

**兩件事使它與鏈路那條路等價地脆弱**：

- 它與鏈路的 drain **在同一個迴圈裡**（`while` 在 `:1849`、`sleep_for` 在 `:1851`、
  流速率 `:1934`、鏈路 drain `:2050`、迴圈結束 `:2195`）⇒ **同一個週期**。
- 差分取的是**這個迴圈相鄰兩輪**的計數器（`:1968-1972` 在底部更新 `Previous`）
  ⇒ 真實間隔就是迴圈週期，不是 1 s。

⇒ **高估倍數 ＝ 週期 / 1 s，與鏈路修好之前完全相同，而且同樣隨流數成長。**

**它會被使用者看到**：`info.estimatedFlowSendingRatePeriodically`（`:2008`）；
大象流分類（`:2020` 拿它跟 `MICE_FLOW_UNDER_THRESHOLD` 比）；
以及 top-k 的排序（同檔 `:1993` 的註解自述 `getTopKFlowInfoJson` 用這個欄位排序）。

### 這不是延後，是漏掉

Q 的 commit message 界定的標的是 `updateLinkInfoLeftLinkBandwidth` 的兩個呼叫端；
PREREG §Q-10「本節不宣稱」四條裡也沒有一條把流那條路排除在外。
⇒ **它不在範圍裡，是因為界定範圍的 grep 用了一個它不叫的名字**，
不是因為有人評估過然後決定不修。

📌 **教訓**：用單一識別字的 grep 界定修法範圍，會漏掉「同一個缺陷、不同變數名」的實例。
Q 自己就示範過一次正確的做法——改簽章讓漏掉的呼叫端變成編譯錯誤——
但那只保護得到已經在名單上的那條路。

### 本增補**不**宣稱

- 不宣稱今天的高估幅度是多少：1.03–1.25 s 是 08-27 那顆 binary 的讀數，本次沒有重量。
- 不宣稱 `:2206-2236` 的 Immediately 路徑有同樣的缺陷：它讀的是 `AutoRefreshQueue`
  的滑動視窗（`getSum()`／`size()`），時間語意不同，**沒有讀過那個類別就不下判斷**。
- 不宣稱修法形狀：那是 auditor 派出的查證交付
  （`doc/audit/2026-09-02_live-round/FLOW-RATE-DENOMINATOR.md`）要回答的。

---

## 3. 後果分開看：**排序幾乎不受影響，門檻一定受影響**

⚠️ 本節行號錨定在**已提交的 HEAD**。撰寫當下 `FlowLinkUsageCollector.cpp` 與 `SFlowType.hpp`
在共用工作樹裡**有別人未提交的修改**（c4 的 subagent 正在套修法），
那些是未提交的觀測，不作為本節依據。

### 3-1. 排序：**同一輪的每條流共用同一個倍數 ⇒ 次序保住**

`getTopKFlowInfoJson`（HEAD `:2527`）用 `std::sort` 排 `estimated_packet_rate_in_the_proceeding_1sec_timeslot`，
那個欄位來自 `avgPacketRate`，走的是同一條沒有除法的路。

但**一輪之內，所有流都在同一個 `for` 迴圈裡算完**，每條流的差分視窗都是「這一輪讀到它」
減「上一輪讀到它」＝同一個迴圈週期。⇒ 回報值 ＝ 真值 × (週期 / 1 s)，**倍數對每條流相同**。
乘以正的常數是單調變換 ⇒ **排序不變**。

⇒ 08-28 QM 那輪的 `sample_topk_rank.py` 明講「severity claim is about ORDER」，
**它的結論不受這個缺陷影響**。

**兩個會擾動次序的邊角**（🔴 兩個都**未查證**，列出來是為了不讓「排序沒事」被讀成無條件成立）：

1. `m_flowInfoTable` 是 `std::unordered_map`（`FlowLinkUsageCollector.hpp:530`）。
   traversal 次序在 rehash 之前穩定，rehash 之後會變。一條流若在兩輪之間換了位置，
   它的視窗變成「週期 ± 位移 × 每條流成本」，而**流表在 churn 下不斷增刪**。
   這是**暫態擾動，不是系統性偏差**，但真值相近的兩條流可能因此換位。
2. 一條流的**第一個區間**：`Previous` 的初值若是 0，第一次差分跨的不是一個週期。
   沒讀初始化，不下判斷。

### 3-2. 門檻：**一定錯，而且是單向錯**

`:2020` 拿 `estimatedFlowSendingRatePeriodically >= MICE_FLOW_UNDER_THRESHOLD` 比，
而那個門檻是**寫死的常數 10 Mbps**（`TopologyAndFlowMonitor.hpp:30`，`10000000`）。
被膨脹的絕對值拿去跟沒被膨脹的常數比 ⇒ **比較本身失真**。

**單向**：倍數 > 1 ⇒ 只會**多**標大象流，不會漏標。
用 08-27 量到的週期（1.03–1.25 s）換算，**真實速率落在約 8.0–9.7 Mbps 的流會被誤標成大象流**。
（那是當時那顆 binary 的週期，今天沒重量；區間隨週期走。）

⇒ **排序與門檻的嚴重性不同**：前者要靠邊角條件才會出錯，後者每一輪都在錯。

## 4. 對帳：既有結果裡誰讀過這兩個欄位

**查法**：對 `doc/`、`tools/`、`tests/`、`p4_proxy/` 全域 grep 兩個 JSON 欄位名與 top-k／大象流的字樣，
再逐檔判斷它依賴的是**值**、**次序**還是**結構**。⚠️ 這是**消費者盤點**，不是逐輪重審結論；
Tier 1 的每一筆仍要各自回頭看它的宣稱句。

| Tier | 依賴什麼 | 受影響？ | 檔 |
|---|---|---|---|
| **1** | **Periodically 的值** | 🔴 **是** | `doc/audit/2026-08-27_flow-table-idle-tail/`（W 輪，top-k 被結束的流灌爆，引用過 20.3 Mbps／10496 pps）；`doc/KNOWN-ISSUES.md` 引用該輪數字之處 |
| **2** | **只依賴次序** | 🟢 否（見 3-1） | `doc/audit/2026-08-28_QM-mirrored-block/`（`sample_topk_rank.py`、`drive_topk.sh`、REPORT 的 severity 宣稱） |
| **3** | **只依賴結構／存在性** | 🟢 否 | `tools/contract_test/spec.py`（`Num(min=0)` 與零值檢查）、`tests/python/test_contract_spec.py`、`tests/shell/mutate_topk_recursive_lock.sh`、各 runbook 與 `doc/2026-01-02_ndt_api.md` |
| **4** | **Immediately 那條路** | ⚠️ **未判斷** | `tools/twin_audit/twin_audit.py`（`RATE_FIELD = "…_in_the_last_sec"`）、`doc/audit/2026-08-28_chaos-harness/harness/invariants.py` |

🔴 **Tier 4 不是「沒事」，是「我沒讀那條路」**：`_in_the_last_sec` 來自
`:2206-2236` 的 `AutoRefreshQueue`（`getSum()`／`size()`），時間語意與 Periodically 不同。
要判斷它得先讀那個類別，本次沒讀。

[Co-developed with claude code -- Adam]

---

## 5. Tier 4 收掉：Immediately 那條路是**另一個**缺陷，不是同一個

讀了 `AutoRefreshQueue`（`include/common_types/SFlowType.hpp:193-266`）。

`m_interval` 預設 `TIME_UNIT_INTERVAL = 1000`（ms，`:19`）。`refresh()`（`:251`）拿
`steady_clock` 的現在時刻，把 `now - sample.timestampInMilliseconds > m_interval` 的樣本
從佇列前端丟掉並同步扣掉 `m_sum`；`getSum()` **先 refresh 再回傳**。

⇒ **它的分母是真的一秒，由時間戳修剪強制執行，不是假設出來的。**
迴圈跑多久都不影響窗寬。**Immediately 那條路沒有「週期 / 1 s」那個倍數。**

### 但它有自己的毛病，而且**同一個成因、相反的症狀**

迴圈每 **1.03–1.25 s** 讀它一次，而每次只涵蓋**最近 1.0 s**。
⇒ 兩次讀數之間有一段時間**不在任何一個回報視窗裡**，
而那段空隙**隨負載變寬**（週期越長，漏掉越多）。

| | Periodically | Immediately |
|---|---|---|
| 分母 | **假設**的 1 s（實際是週期） | **實測**的 1 s（時間戳修剪） |
| 症狀 | **高估** × (週期/1 s) | 值正確，但**覆蓋有空隙** |
| 隨負載 | 高估幅度變大 | 空隙變寬 |

⇒ **兩個欄位量的不是同一個東西，而它們的分歧隨負載成長。**
落在空隙裡的突發流量，Immediately 完全看不到；Periodically 看得到但把它記成偏高的值。

**對兩個 Tier 4 消費者的判定**：

- `tools/twin_audit/twin_audit.py`（`RATE_FIELD = "…_in_the_last_sec"`）：
  **不受本增補的偏差影響**。它用這個欄位抓「陳舊樣本被當成活流」，
  而時間戳修剪正是會讓陳舊樣本歸零的機制 ⇒ 對它的用途而言這條路是**對的選擇**。
  ⚠️ 但它會漏掉落在空隙裡的短突發，那是**偵測靈敏度**問題，不是數值偏差。
- `doc/audit/2026-08-28_chaos-harness/harness/invariants.py`：同上，讀 Immediately ⇒ 同一個判定。

🔴 **邊界的 off-by-one**：`> m_interval` 保留了年齡剛好等於 1000 ms 的樣本，
所以窗寬是 (0, 1000] 而不是 [0, 1000)。影響量級可忽略，記著是因為它會讓
「窗寬剛好 1000 ms」這句話在嚴格意義上不成立。

## 6. 第二類對帳：讀過 **OVS 平面**鏈路使用率的既有結果

**起因**：09-03 夜間測試輪回報 `ndt up ovs4` 沒有在任何 bridge 上配置 sFlow，
所以那座 fabric 上的遙測**結構性為零**，而 `/ndt/get_average_link_usage`
回 `{"avg_link_usage":0.0,"status":"success"}`——**「沒問到」與「很閒」無法分辨**。

### 6-1. 🔴 **範圍要收窄：這是 `ovs4` 的缺陷，不是「OVS 平面」的缺陷**

獨立查證（唯讀）：

| 指令 | 起的拓樸 | sFlow |
|---|---|---|
| `ndt up ovs4` | `tools/test_workflow/ovs_4host_topo.py` | **0 個參照** 🔴 |
| `ndt up ovs`（128） | NTG repo 的 `testbed_topo.py`（`ndt:818` 明載） | `enable_sflow()` 定義在 `:110`、**`:190` 有呼叫** 🟢 |

⇒ **128 台那條路有配 sFlow。** 把結論寫成「OVS 平面全零」會把 128 台那條路的結果
一起誤判掉。**受影響的母體是「在 ovs4 fabric 上讀過分身遙測」的輪次。**

### 6-2. 查過而清白（**不是沒查**）

| 結果 | 為什麼不受影響 |
|---|---|
| **兩平面天花板圖**（`plot_deck_903_round2.py` 的 `fig_bandwidth_ceiling`，53.1 Gbit/s 那半） | OVS 那半由 `core_links()` 解析 **qdisc 讀出**（`s5-eth4 53.1 Gbit/s` 與 MAX/TOTAL 行）＝**介面計數器，不經過分身** |
| **bmv2 效能研究 fig8 的 OVS 三點**（540/960/720） | 來源是 `doc/audit/2026-08-30_ovs-flowcount-control/FINDINGS.md`，該輪 ①跑 **NTG 的 `testbed_topo.py`**（128 那條路，有 sFlow）②數字是 **iperf3 吞吐**（`receiver-socket-bounded`／`htb-capped`），不是分身遙測 ⇒ **兩重都不受影響** |
| **OVS 單鏈路 53.1 G／頻寬天花板那條線** | 同第一列，介面計數器 |

### 6-3. 需要各自回頭看的（同時提到 `ovs4` 與分身的鏈路使用率端點）

`doc/KNOWN-ISSUES.md`、`doc/audit/2026-08-28_chaos-harness/02_oracle_muse.md`、
`doc/audit/2026-09-03_night-rounds/round1-ovs/FINDINGS.md`（就是回報這件事的那一輪）、
`doc/audit/2026-08-18_three-model-questioner-round/questions/deepseek-agent-CONTAMINATED.md`。

⚠️ 「同時提到」**不等於**「在 ovs4 上讀了那個端點並據以下結論」——
這一格是**待查名單**，不是受影響清單。逐筆判定要看該輪實際跑的是哪座 fabric。

📌 **這件事的形狀與本增補主題相同**：一個回 `success` 的零，
與一個把週期當成 1 秒的除法，都是**輸出看起來正常、而它從來沒有量到它宣稱的東西**。

[Co-developed with claude code -- Adam]
