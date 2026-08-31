---
name: jitter-is-the-receiver-not-the-network
description: "🔑 Adam 的「大流量時 iperf 顯示的流量會抖」已結案（08-28，OVS 平面）：抖動不在資料面、不在 iperf 的時鐘，在**收端 socket**——CPU 競爭餓死接收行程，`RcvbufErrors` 406k ≈ 觀察到的 401k 丟包，而路徑上每個 htb 都 `dropped 0`。決定性的是「單一接收行程的速率」不是總流量：18 GB 分散在 16 流上 CV 0.64%，單流 800 M CV 6–13.5%"
metadata: 
  node_type: memory
  type: project
  originSessionId: c48fe872-0048-4e7a-82ca-922de398cf3b
  modified: 2026-08-28T07:21:56.963Z
---

# 「大流量下 iperf 顯示的流量會抖」——是收端，不是網路

**2026-08-28 實測結案。** 平面由 Adam 指定（他的原話是「**OVS，或很可能是 OVS**」——**那個但書要留著**）。
正本 `doc/audit/2026-08-28_jitter-working-point/`（`03_ovs_PREREG.md` 零資料時 commit、
`04_ovs_result.md`、`05_layer_attribution.md`）。

## 🔑 答案

```
CPU 競爭 → iperf3 收端行程搶不到 CPU → socket 接收佇列排不空
        → kernel 在 socket 層丟包 → 每秒回報的吞吐上下跳
```

**不是 NDTwin 的缺陷、不是 OVS 的缺陷、不是 iperf 的時鐘，是量測主機的資源問題。**
**同樣的流量、機器不忙時完全不抖（CV 0.01%）。**

## 逐層計數（單流 800 Mbit ＋ 10 個 CPU burner）

| 層 | 讀數 | 判定 |
|---|---|---|
| iperf 回報 | loss **9.769%**（401,103 / 4,105,852），名目 CV **13.54%** | 現象在 |
| 送端 htb `h1-eth1` | 4,105,869 pkt、**dropped 0**、overlimits 2,520,381 | ❌ 不是我們的整形器 |
| 收端側 htb `s3-eth3` | 4,969,683 pkt、**dropped 0**、overlimits 3,374,751 | ❌ 同上 |
| h65 介面 `/proc/net/dev` | rx errs **0**、rx drop **261**（0.005%） | ❌ 不是 datapath／NIC |
| 🔴 **h65 UDP socket** | **`RcvbufErrors` 406,299 ＝ `InErrors`** | ✅ **100% 的輸入錯誤都是接收緩衝區滿** |

⚠️ `RcvbufErrors` 是 **cumulative**，406,299 含少量先前的跑
⇒ **與 401,103 的吻合是量級吻合，不是逐位。**

## 🔑 決定性的是「單一接收行程的速率」，不是總流量

| 工作點 | loss | 名目 CV |
|---|---|---|
| 16 流 × 30 M（480 M 合計、**18.0 GB**）、10 burner | 0.037% | **0.64%** |
| 單流 800 M、**無 burner** | 0.459% | **0.01%** |
| 單流 800 M、10 burner（三次） | 10.1 / 10.7 / 11.2% | **8.30 / 5.99 / 8.10%** |

⇒ **速率本身不造成**（800 M 無 burner ＝ 0.01%）；**量本身也不造成**（18 GB 分散 ⇒ 0.64%）。
**「數十 GB」是 Adam 描述時的伴隨條件，不是成因。**
16 流那格沒事，是因為**每個收端只要處理 30 Mbit，即使被搶 CPU 也排得空**。

## ✅ 可行動

> **看到 iperf 數字在抖 ⇒ 先查收端主機忙不忙，不要先懷疑轉發平面或分身。**
> **`RcvbufErrors` 一條指令就分得出來**（`mnexec -a <pid> cat /proc/net/snmp | grep -A1 '^Udp:'`）。

## 🔑 方法上的兩件事

1. **審查員提議讀 `tc -s qdisc` 的計數器，取代「拿掉 shaper 的第二臂」。**
   理由：**拿掉 htb 同時也拿掉一個 CPU 消費者**，而本輪結論正是「CPU 競爭決定一切」
   ⇒ 那個混淆特別致命。**計數器直接指認層，第二臂只能推論。**
   ⚠️ `tc -s qdisc` 是 cumulative ⇒ **跑前讀基線**。
2. **他的二分法（htb drop ≈ loss ⇒ 是整形器；≈ 0 ⇒ 是 datapath）在第一格就走完，
   而答案是它沒列的第三格。** ⇒ **判準要留「以上皆非」的實例**，
   而且這次是**判準本身把人推過去的**，不是事後補的。

## ⚠️ 未決（具名、可測）

| # | 問題 | 怎麼測 |
|---|---|---|
| **R-1** | OVS datapath 在更高負載下會不會變成主要丟包層？（本輪僅 0.005%） | **先解收端瓶頸**（`SO_RCVBUF`／`net.core.rmem_max`），再加負載，看 rx drop 對 `RcvbufErrors` 的比例 |
| **R-2** | htb 的**時間結構**會不會在收端不是瓶頸時造成抖動？（它 `dropped 0`，但**不丟 ≠ 不改變到達分佈**） | 同上前置後，shaped vs unshaped，**offered rate 釘死相同** |
| **R-3** | Adam 當時機器在做什麼？ | 審查員去問。**本輪顯示那是決定性變數** |

🔑 **R-1／R-2 共用前置：先移除收端瓶頸。**
**在收端會滿的情況下量任何上游層，量到的都是收端**——**最下游的瓶頸遮住它上游的一切。**

## ⚠️ 不宣稱

- **不**宣稱這是缺陷：**收端來不及是量測配置的性質**，要定成缺陷得先有規格，而我們沒有。
- **不**宣稱這就是 Adam 看到的：他有「或很可能是 OVS」的但書，**而且從未說當時機器在做什麼**。
- **不**宣稱 OVS datapath 高負載下永遠不丟：**只證明它在這個工作點不是主因**。

相關：[[bmv2-and-ovs-capacity-do-not-compose]]、[[instrument-must-not-mimic-its-own-finding]]
