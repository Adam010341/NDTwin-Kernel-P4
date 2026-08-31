---
name: check-against-prior-experiments
description: 每次做實驗都要先問「這會不會推翻／更新／可以對比哪個舊結果」——Adam 2026-08-21 明確要求，而且當天就有兩個實例
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4b8ef0e6-15bd-4a96-b632-ce4e8b60796e
  modified: 2026-08-21T08:40:50.721Z
---

Adam 2026-08-21 明確指示：**「我以後叫你做實驗的時候，記得要看一下有沒有哪些實驗是可以推翻／更新以前的實驗結果，或是與以前的實驗結果對比的。」**

**Why**：這個 repo 的數字會擴散。一個沒人量過的估計值可以活三個星期、散進四個檔案，然後被當成系統的性質引用（`~60 s` 的 walk；更早的 `291 秒` 散進 11 個檔案）。新實驗如果只回報自己的數字、不去對帳，舊的錯誤數字**不會被撤回**，兩個互相矛盾的值會並存，而讀的人分不出哪個是現況。

**How to apply**：跑實驗前後各做一次，兩個方向都要查——

1. **推翻／更新**：這輪量到的東西，有沒有哪個舊結論是靠「沒量過的估計」撐著的？
   查法：`git grep` 那個數字、`grep -rn` 程式註解與 commit message。
   找到就**在報告裡明寫哪個作廢、差幾倍、原始來源是什麼**，並回頭改 template。
2. **對比**：有沒有舊圖／舊表在講同一件事，新資料應該**放在它旁邊**而不是另起爐灶？
   對比圖要**import 舊圖的資料載入函式**（例如 `failover_cells()`），不要重打數字——
   兩張圖共用一個來源就不可能漂移。

**2026-08-21 的兩個實例**（同一輪）：
- walk 計時推翻了 `~60 s`（差 28×）與 `≤13 s`（鬆六倍），兩個都作廢；
  順帶把「重算是 failover 最大項」整個推翻——它只佔 51.75 s 的 4%。
- 新的 `page_failover-budget.png` 是 `page36_failover-decomposition.png` 的續篇：
  舊圖答「什麼讓中斷變長」，新圖答「中斷是由什麼組成的」。51.75 s 從舊圖的
  `failover_cells()` import 進來。

相關：[[benchmark-must-name-the-binary-it-measured]]、[[cited-line-numbers-are-not-evidence]]、
[[verify-against-known-good-output]]、[[arithmetic-that-fits-is-not-the-mechanism]]。

## 🆕 08-30 Adam 加的姊妹規則：外部工具壞掉→先對 baseline 跑一次分歸屬

原話：「如果發現一些外部工具在整機測試的時候壞掉，可以先拿 baseline 的 code 來測試看看是誰的問題。」
＝歸屬兩可（「我們的窗弄壞的」vs「它本來就這樣」）時，對參考基線 build 跑同一個最小重現。
注意兩個邊界：失效發生在碰到受測系統**之前**的（如 te 死在 `input()`）不需要 baseline 就已有歸屬；
baseline 編譯是重負載，**不得撞量測窗**——窗內裝不下就寫成該工單的已註冊下一步。
