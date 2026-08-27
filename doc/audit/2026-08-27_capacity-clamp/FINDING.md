# 分身回報的鏈路使用量，被夾在模型宣告的鏈路容量上

**日期**：2026-08-27　**平面**：兩者（機制在 kernel）　**狀態**：行為已指認，**是否為缺陷未裁**
**證據等級**：讀碼（逐行）＋ live 實測，兩者互相對上

---

## 摘要（一句話）

**`linkBandwidthUsage` 在結構上永遠不可能超過該邊的 `linkBandwidth`。**
一旦線上實際流量超過模型宣告的容量，分身回報的就是**宣告值**，不是實際值——
而且 `linkBandwidthUtilization` 同時被夾在 **100%**。

⇒ **「資料面跑得到 X」與「分身量得到 X」是兩個不同的宣稱**，
而第二個在宣告容量以上目前是 **false**。

---

## 1. 實測證據（工單 N 診斷 A，OVS 128-host）

拿掉接取層的 `bw=` 之後，單一核心鏈路實測 22.0 Gbit/s（同格），而分身這樣看：

| | veth（地面真值，`/sys` 計數器） | twin（`link_bandwidth_usage_bps`） | 比值 |
|---|---|---|---|
| host→switch（128 邊） | 137.744 GB | 0.888 GB | 0.0064 |
| switch→host（128 邊） | 198.425 GB | 0.865 GB | 0.0044 |
| switch→switch（32 邊） | 802.187 GB | 3.773 GB | 0.0047 |
| **合計（176 條負載邊）** | **1138.356 GB** | **5.525 GB** | **0.0049** |

**分身少報 99.5%。**

🔑 **指認機制的那一刀**：

| 量 | 值 |
|---|---|
| twin **最大**單邊回報 | **1.000 Gbit/s** |
| 該邊宣告的 `link_bandwidth_bps` | **1.000 Gbit/s** |
| 同一格線上實測 | **22.032 Gbit/s** |

**最大值不多不少正好落在宣告容量上。** 那不是誤差分佈的形狀，是**夾制的簽名**。

原始資料：`doc/audit/2026-08-25_sampling-rounds/raw_n.tar.gz`（`N1d_moderate/rows.json`）。
分析工具：`doc/audit/2026-08-25_large-scale-concurrent/analyze.py`（有 selftest）。

---

## 2. 讀碼：**四個寫入點，全部夾**

### 2.1 Flow-sample 路徑（自帶三元夾制）

`src/ndt_core/collection/TopologyAndFlowMonitor.cpp:1089-1095`

```cpp
uint64_t leftIn =
    estimatedIn > edgeProps.linkBandwidth ? 0 : edgeProps.linkBandwidth - estimatedIn;
edgeProps.leftBandwidthFromFlowSample = leftIn;
edgeProps.linkBandwidthUtilization = (1.0 - (double)leftIn / edgeProps.linkBandwidth) * 100;
edgeProps.linkBandwidthUsage =
    leftIn > edgeProps.linkBandwidth ? 0 : edgeProps.linkBandwidth - leftIn;
```

逐行推：

| 條件 | `leftIn` | `linkBandwidthUsage` |
|---|---|---|
| `estimatedIn ≤ linkBandwidth` | `linkBandwidth − estimatedIn` | **`estimatedIn`** ✅ 正確 |
| **`estimatedIn > linkBandwidth`** | **`0`** | **`linkBandwidth`** 🔴 **夾住** |

### 2.2 計數器路徑（夾制在**上游**，所以單看寫入點看不出來）

寫入點本身沒有三元運算：

`TopologyAndFlowMonitor.cpp:1057`（正向）與 `:1063`（反向）
```cpp
edgeProps.linkBandwidthUsage    = interfaceSpeed - leftOut;
revEdgeProps.linkBandwidthUsage = interfaceSpeed - leftIn;
```

但 `leftIn` / `leftOut` 是**傳入參數**（`updateLinkInfo`，`:1023-1027`）。
唯一呼叫者是 `FlowLinkUsageCollector.cpp:1184`，而它在 **`:1162-1163`** 算：

```cpp
leftIn  = (avgIn  > interfaceSpeed) ? 0 : (interfaceSpeed - avgIn);
leftOut = (avgOut > interfaceSpeed) ? 0 : (interfaceSpeed - avgOut);
```

⇒ `avgOut > interfaceSpeed` ⇒ `leftOut = 0` ⇒ `usage = interfaceSpeed − 0 = interfaceSpeed`
⇒ **同樣夾在宣告容量上，只是夾的動作發生在上游。**

🔑 **這條值得單獨講**：**只讀寫入點會得出「這條路徑不夾」的錯誤結論。**
必須追到參數的來源。

### 2.3 匯總

| # | 寫入點 | 夾制發生在 | 夾在 |
|---|---|---|---|
| 1 | `TAFM:1095`（flow-sample） | 同一行 | `linkBandwidth` |
| 2 | `TAFM:1057`（計數器，正向） | `FLUC:1163` | `interfaceSpeed` |
| 3 | `TAFM:1063`（計數器，反向） | `FLUC:1162` | `interfaceSpeed` |
| 4 | `TAFM:1093 / 1056 / 1062`（utilization） | 同上 | **100%** |

**沒有任何一條路徑不夾。**

---

## 3. 🔴 `linkBandwidthUtilization` 被夾在 100%——這條可能比 usage 更危險

`leftIn = 0` ⇒ `(1.0 − 0/linkBandwidth) × 100` = **100%**。

⇒ **「使用率 100%」在這個實作裡不代表「滿載」，代表「≥ 宣告容量」——可能是 1.0 倍，也可能是 22 倍。**

**為什麼它比 usage 那條危險**：`usage_bps` 是一個要換算才有感覺的數字，
而**「使用率 100%」是一個所有人都以為自己懂的數字**。
一個看起來正常的儀表板讀數，實際上是一個**被截斷的訊號**，
而截斷發生在**最需要知道超載多嚴重的時候**。

---

## 4. 這對工單 N 的結論做了什麼：**把一句話切成兩句**

| 宣稱 | 狀態 | 依據 |
|---|---|---|
| **資料面**跑得到 53–61 Gbit/s | ✅ **成立** | 介面計數器；iperf3 自述換算成同母體後差 0.3% |
| **分身量得到** 53–61 Gbit/s | 🔴 **false** | 超過宣告容量之後回報的是宣告值 |

⇒ **deck 上這兩句必須分開講。** 分身的可觀測範圍**上限就是模型裡寫的容量**。

---

## 5. 🔴 這**不是**「遙測失明」那個發現的重現，兩者不可合併

**工單①（P4、1/256）**：CPU 競爭下分身少報 **34%**，而資料面只掉 5%。
工作點**遠低於**鏈路容量 ⇒ 那是**精度流失**：分身看得到這條鏈路，只是數字不準。

**本文（OVS、拿掉接取整形）**：少報 **99.5%**，而且**只在流量超過宣告容量之後**發生。
⇒ 那是**表示能力的天花板**：分身**在結構上沒有能力**表達那個數字。

**兩個不同現象。** 合併會同時誇大兩者，並讓「①是不是 bmv2 特有」這題看起來被答了——
**它沒有。** 本輪沒有在**容量以下**的 OVS 工作點取得可比數字。

---

## 6. 明確**不**宣稱

1. 🔴 **不裁定這是缺陷還是設計。** 那兩行**可能是刻意的**——
   「剩餘頻寬不能為負」是合理的模型約束，而在拿掉 `bw=` 之前，
   **流量超過宣告容量本來就不可能發生**。
   ⇒ 本文只寫**行為、後果、以及它在什麼前提下是合理的**。
   **「該不該改」留給 Adam。**
2. **沒有討論修法。**
3. **完全閒置的邊讀什麼，本次沒有量**（所有觀察都取自有流量的邊）。
4. ~~未答：哪一條路徑在什麼情況下被使用~~ ⇒ **已答，見第 6-bis 節。**

---

## 6-bis. 哪一條路徑在跑？**MININET 模式下只有 flow-sample 那條**

`src/ndt_core/collection/FlowLinkUsageCollector.cpp:1101-1106`，
在**計數器樣本**的分支（`sampleType == 2 || 4`）裡：

```cpp
if (m_mode == utils::MININET)
{
    SPDLOG_LOGGER_TRACE(...);
    continue;
}
```

`continue` **跳過該分支底下的全部程式碼**——包括 `:1162-1163` 的 `leftIn`/`leftOut` 計算
與 `:1184` 的 `updateLinkInfo()` 呼叫。

⇒ **MININET 模式下計數器路徑（寫入點 2、3）從不執行。**
⇒ 今天所有量測都跑在 `--mode mininet`（`pgrep -ax ndtwin_kernel` 可查），
   所以**第 1 節量到的 1.000 Gbit/s 走的是 flow-sample 路徑（`TAFM:1095`）**。
⇒ 計數器路徑只在 **TESTBED** 模式下有機會執行（真實 Brocade / HPE 硬體）。

### 🔴 一個尚未發生但形狀已知的風險：**同一個欄位有兩個寫入者**

`linkBandwidthUsage` 被兩條路徑寫。**在 MININET 下只有一個寫入者活著，所以今天不咬人**，
但在 TESTBED 下兩條都可能活 ⇒ **對同一條邊給出不同的答案**：
一條用 `edgeProps.linkBandwidth`（模型宣告值）當上限，
另一條用 `interfaceSpeed`（sFlow 回報的介面速率）當上限——**兩個來源不保證相等**。

⚠️ **本文不宣稱這曾經發生過**，只記下形狀：
這是本 repo「**應該取代、卻只會新增**」那一族的近親——
**每次看到一個欄位有多個寫入者，就要問「舊值什麼時候消失、誰贏」**。
**TESTBED 模式下沒有人驗證過這一點。**

---

## 7. 它在什麼前提下是合理的（給裁決用）

- **前提成立時**：若每條鏈路的實際吞吐**不可能超過模型宣告的容量**
  （例如接取層被 tc 整形在 1 Gbit/s、或真實硬體確實是 1 GbE），
  那麼夾制**永遠不會觸發**，這兩行只是防止負值的守衛，**完全正確**。
- **前提被打破時**：本輪拿掉接取層 `bw=` 之後，veth 是**記憶體複製、沒有線速**，
  實際吞吐輕易超過模型宣告值 ⇒ **守衛從「不會觸發」變成「一直觸發」**，
  而它**沒有任何 log 或旗標**說自己觸發了。

🔑 **這是一個「前提改變讓正確的碼變成錯的答案」的例子**，
不是「有人寫錯了」。**這也是為什麼裁決不該由我做。**

---

## 8. 對帳

| 問題 | 答案 |
|---|---|
| 推翻誰？ | 不推翻既有結論；**限縮**工單 N 的措辭（第 4 節） |
| 更新誰？ | `KNOWN-ISSUES.md` 的 **F-8**（`left_link_bandwidth_bps` 首次取樣前寫死 1 Gbit/s）是**相鄰但不同**的缺陷——F-8 講初始值，本文講**上限**。建議並列不合併 |
| 可對比誰？ | 工單①（見第 5 節，**不可合併**） |
| 已知的坑 | 讀碼結論**不可只讀寫入點**（第 2.2 節） |

---

**證據檔**：`doc/audit/2026-08-25_sampling-rounds/PREREG.md` 增補 N-5、N-7、N-8
**commit**：`8d937ec`（實測）、`2ef1fac`（第二條路徑）、`5ccba55`（方向排除）

[Co-developed with claude code -- Adam]
