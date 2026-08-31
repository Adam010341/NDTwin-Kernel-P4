---
name: twin-usage-clamped-to-declared-capacity
description: "🔑 08-27 機制已指認：`linkBandwidthUsage` 結構上不可能超過該邊宣告容量（四個寫入點全夾），`linkBandwidthUtilization` 一起夾在 100% ⇒「資料面跑得到 X」與「分身量得到 X」是兩個不同宣稱"
metadata: 
  node_type: memory
  type: project
  originSessionId: bfb90c75-a7ee-41b9-91e0-48f870a0ed59
  modified: 2026-08-27T08:56:29.687Z
---

**全文在 repo**：`doc/audit/2026-08-27_capacity-clamp/FINDING.md`（逐行推導、實測、對帳、
不宣稱清單都在那裡）。這裡只放**難以重新推導的部分**與**引用限制**。

## 結論一句話

**`linkBandwidthUsage` 在結構上永遠不可能超過該邊的 `linkBandwidth`。**
流量超過模型宣告容量之後，分身回報的是**宣告值**，而 `linkBandwidthUtilization` 夾在 **100%**。

## 🔴 引用限制（最容易被誤用的地方）

| 宣稱 | 狀態 |
|---|---|
| **資料面**跑得到 53–61 Gbit/s | ✅ 成立（介面計數器 ＋ iperf3 換算同母體後差 0.3%） |
| **分身量得到** 53–61 Gbit/s | 🔴 **false** |

**deck 上這兩句必須分開講。**

🔴 **這不是「遙測失明」（工單①）的重現**：①是**容量以下的精度流失**（34%），
這是**容量以上的表示天花板**（99.5%）。**兩個不同現象，合併會同時誇大兩者。**
⇒ 「①是不是 bmv2 特有」**仍未答**。

## 四個寫入點（行號會漂，逐行推導看 FINDING）

| # | 寫入點 | 夾制在哪 | 夾在 |
|---|---|---|---|
| 1 | `TAFM:1095` flow-sample | 同一行三元 | `linkBandwidth`（拓樸 JSON，`TAFM:320`） |
| 2 | `TAFM:1057` 計數器正向 | **上游** `FLUC:1163` | `interfaceSpeed`（sFlow 自述） |
| 3 | `TAFM:1063` 計數器反向 | **上游** `FLUC:1162` | 同上 |
| 4 | `TAFM:1093/1056/1062` utilization | 同上 | **100%** |

**MININET 下只有第 1 條會執行**（`FLUC:1101-1105` 的 `if (m_mode == MININET) continue;`）
⇒ 我們量到的都走 flow-sample 路徑；計數器路徑**今天一次都沒跑過**。

## 🔑 三個耐久的教訓（狀態會過期，這些不會）

1. **看寫入點不等於看到約束。** `usage = interfaceSpeed - leftOut` 看起來完全乾淨，
   夾制在**呼叫者**裡。**驗收問句：「這個值是在這裡算出來的，還是傳進來的？」**
   ⇒ 已併入 [[existence-is-not-wiring]] 的鏡像面。
2. **同一個模型值有三種污染量測的方式**：當**初始值**（F-8）、當**上限**（夾制）、
   當**被覆寫的對象**（`TAFM:1058/1064` 把 `linkBandwidth` 覆寫成 `interfaceSpeed`）。
   🔴 而 `TAFM:2702` **以同一個名字 `link_bandwidth_bps` 送出** ⇒
   **API 讀者分不出這筆是宣告值還是交換機自述。同名、兩來源、零標記。**
3. **「前提改變讓正確的碼給出錯的答案」**：那兩行在寫下的當天是對的
   （「剩餘頻寬不能為負」是合理約束，而流量超過宣告容量在當時不可能發生）。
   **打破前提的是我們自己在工單 N 拿掉 `bw=`。** ⇒ **沒有人寫錯任何一行。**
   這也是為什麼**裁決不該由我做**——它其實是「要不要繼續讓流量超過宣告容量」這個上層問題。

## 建議（已寫進 FINDING，**Adam 未裁**）

**若保留夾制，至少讓它在觸發時說一聲。** 現在**沒有 log、沒有旗標**
⇒ 下游分不出「剛好滿載」與「超載二十倍」。
🔑 **這個建議在兩種裁決下都不白做**：夾制若是對的設計，旗標不改變語意只增加可觀測性；
若是缺陷，旗標正好是驗證修法的鉤子。

## ⚠️ 未經量測的部分

**TESTBED 模式下的行為全部是靜態分析**（計數器路徑今天零執行）。
`interfaceSpeed` 若錯誤或為 0，整條邊的天花板會被一個沒人檢查的值取代，
**而拓樸檔看起來還是對的**——**未驗證，不要當結論。**

相關：[[ovs-bandwidth-ceiling-measured]]、[[existence-is-not-wiring]]、
[[arithmetic-that-fits-is-not-the-mechanism]]
