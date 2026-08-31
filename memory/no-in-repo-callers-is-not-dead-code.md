---
name: no-in-repo-callers-is-not-dead-code
description: repo 內零消費者不等於死碼——Adam 的外部工具可能在讀它；先記下來問，不要直接判死
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-12T05:22:06.962Z
---

2026-08-12 Adam 的指示：「以後看到這種沒人用的東西可以先記下來，我猜可能是外部 tool 會用到。」

觸發情境：`HistoricalDataManager` 把每條邊的資料寫成 CSV 到
`/home/of-controller-sflow-collector/LinkData`。我查到它**四層都是壞的**（MININET 直接
skip、目錄 root-owned 所以寫進死 stream、`ControllerAndOtherEventHandler` 收下卻不存、
`m_loggingEnabled` 沒人讀），而且 repo 內 grep 零讀取者，目錄實測是空的——我當時的傾向是
「刪掉」。Adam 的裁決是**留著並修好四層**，因為 repo 外的工具可能在消費那個輸出。

**Why：** 這個 repo 不是封閉世界。Energy-Saving-App、實驗腳本、論文用的分析工具都在
repo 之外，`grep -r src/` 看不到它們。把「repo 內沒有 caller」當成「這是死碼」，會刪掉
別人的輸入。這跟 [[existence-is-not-wiring]] 是同一枚硬幣的兩面：**呼叫點不存在不代表
沒有消費者，就像呼叫點存在不代表有接線**。兩邊都要實際查，不要從 grep 的空結果推論。

**How to apply：**
- 找到零消費者的東西：**記下來、報告、問**。不要在同一輪裡順手刪掉。
- 判「死碼」之前，至少問一句「這個的輸出有沒有 repo 外的讀者？」
- 已知的 repo 外消費者：Energy-Saving-App 讀 `power_consumed` 和平均鏈路使用率
  （見 [[energy-saving-app-power-bug-fix]]）。
- 例外——**帶陷阱的死碼可以刪**，而且這個 repo 有前例：`setAllPath`（單數）被刪掉是因為
  它會寫 `m_allPathMap` 卻不動 `m_switchCountMap`，第一個用它的人就會拿到不一致的狀態。
  差別在「沒人用」vs「沒人用而且會咬第一個用的人」。

## 🔴 08-27：**測試也是依賴方，而且是會把缺陷鎖住的那一種**

`p4_client.py:582` 的 `read_egress_counter` 用 `return 0, 0` 把三種結果
（counter 不存在／RPC 失敗／真的是 0）序列化成同一個值。
先前記的是「零 production 呼叫端 ⇒ 一直沒發作」。**那句只對了一半。**

**測試裡有四個呼叫端，其中兩個在斷言錯誤行為**：

```
test_a_p4info_without_the_counter_reports_zero_rather_than_raising
test_..._a_read_failure_reports_zero...
```

⇒ **兩條都是綠的，而它們釘住的正是缺陷本身。**

🔑 **「零 production 呼叫端」常被用來論證「可以安全地改」。而綠燈測試釘住現行行為 ⇒
一改就紅 ⇒ 下一個人很可能把碼改回去。**
**沒有呼叫端的碼，仍然可以有一個把缺陷鎖住的依賴方。**

⇒ 判斷「這段碼沒人用、可以改」之前，**先看測試在斷言什麼**，不是只看有沒有呼叫點。
相關：[[existence-is-not-wiring]]、[[mutation-gate-for-tests]]

## 🆕 08-27 夜：**零 production 呼叫端 ≠ 可以安全地改**——綠燈測試會把缺陷鎖住

`p4_client.py` 的 `read_egress_counter` 三種結果都回 `0, 0`
（counter 不在 P4Info／RPC 失敗／該埠真的沒封包）。
記憶裡先前寫「**零呼叫端、無 route，所以這個缺陷一直沒發作**」——**那句只對了一半。**

**沒有 production 呼叫端是對的。但測試裡有四個，其中兩個在斷言錯誤行為**：
`test_a_p4info_without_the_counter_reports_zero_rather_than_raising`
與 `test_a_read_failure_reports_zero_rather_than_raising`。**它們是綠的，而它們釘住的正是缺陷。**

🔑 **審查員收緊的形式（比我提的尖）**：
> 「零 production 呼叫端」常被拿來論證「可以安全地改」。
> **但綠燈測試釘住現行行為 ⇒ 一改就紅 ⇒ 下一個人很可能把碼改回去。**
> **沒有呼叫端的碼，仍然可以有一個把缺陷鎖住的依賴方。**

⇒ 驗收問句：**「除了呼叫端，還有誰在斷言這個行為？」** 測試、快照、契約、文件範例都算。

📌 同一輪順手抓到的第二個缺陷：`if not counter_id:` ——**counter id 為 0 是 falsy**，
會把真實存在的 counter 判成不存在。P4Runtime 的 id 是 unsigned ⇒ 構得到。
🔴 **它的表現形式是「某次 pipeline build 之後 counter 就不見了，另一次又好了」**
——**間歇性正是最難歸因的那種。**

## 🆕 08-27 夜:**第二次證實,而且這次生產消費者在另一個 repo**

`/ndt/get_detected_flow_data` 在本 repo 內**只有稽核工具與契約測試**在讀
(`tools/twin_audit/twin_audit.py:91`、`tools/contract_test/*`)⇒ **看起來像沒人在用。**

🔴 **真正的生產消費者是 `~/Energy-Saving-App/src/app/energy_saving_app.cpp:741`**,
它把整包塞進 `json2sim["flowDataList"]` 送給 `energy_saving_simulator`(獨立 ELF),
而**模擬器的裁決決定要不要真的關掉交換機**。

⇒ **可操作:判斷一個端點「有沒有人用」時,`~/` 底下七個兄弟 repo 都要 grep,不是只 grep 本 repo。**
`components.env` 是路徑的真實來源。見 [[cross-repo-component-ecosystem]]。

📌 **而「沒人用」和「沒查」是兩件事** —— 審查員要求我去查,才發現的。
