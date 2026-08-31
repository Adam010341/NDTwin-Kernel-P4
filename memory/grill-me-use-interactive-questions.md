---
name: grill-me-use-interactive-questions
description: Adam 跑 grill me 時要用互動式選擇題（AskUserQuestion 工具）讓他點選，不要純文字列選項
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8633678c-0827-493c-8d55-882f82ee6c9f
  modified: 2026-08-13T04:22:18.398Z
---

2026-08-13：我用 `/grilling` 燒烤 Adam 時，把選項寫成純文字（「選項：(a)…(b)…(c)…」）
讓他打字回答。他說：「你 grill me 的時候沒辦法直接用互動式選擇題的方式讓我點選嗎？
我之前用 grill me 都是這個形式，比較方便。」

**Why**：工具本來就支援（`AskUserQuestion`），純文字回答要他自己打 `Q1 (a)`、
容易漏題、也容易像 Q1/Q3/Q15 那樣「看不懂但懶得說」而卡住。點選式一次呈現完整選項與
每個選項的後果，摩擦低很多。

**How to apply**：
- grill / 任何多選一的裁決題，用 `AskUserQuestion`，一次最多 4 題（frontier 超過 4 題就分批，
  最重要的先問）。
- 推薦選項放**第一個**並在 label 標「(推薦)」——這是工具本身的慣例。
- 每個選項的 `description` 要寫**後果**不是重述選項（「選這個 → 會發生什麼」）。
- 保留 grill 的形狀：一輪問完整個 frontier、等他答完再算下一輪，不要一題一題擠牙膏。
- **他看不懂就是我寫太術語**（Q1/Q3/Q15 各中一次）。重問時換白話、講清楚「這在問什麼、
  兩個選項差在哪」，不要只是把同一句話再說一遍。

相關：[[change-magnitude-send-the-diff]]（同一類：把判斷所需的東西直接遞到他面前，
不要逼他自己重建脈絡）。
