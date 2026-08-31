---
name: a-fix-changes-reachability
description: "291 秒的歸屬被推翻——會爆的那行是繼承的,但在我們自己的修復落地前它是死碼。「這缺陷是誰的」取決於誰讓它構得到"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 38b035fc-b098-4e53-9db6-78561882a7f2
  modified: 2026-08-19T13:50:33.923Z
---

2026-08-19。Adam 主動懷疑:「291 秒搞不好是我們自己的問題,我記得是改 code 改到一半量的。」
**他是對的,而且比他想的更細緻。** 查證後的三段結論:

| | 屬於誰 |
|---|---|
| 會爆的那行 ＋「圖是對稱的」這個假設 | **繼承的**(`6f32bca` 原封不動,`net[current][prev]["port"]`) |
| 讓它構得到的條件(`remove_edge` ＋ 週期性重算) | **Adam 自己的 `2c81b26`** |
| 291 秒這個數字 | 量在中間版本上(`034da18^`,距 `2c81b26` 已 192 個 commit) |

繼承版之所以不爆,是因為它**根本不刪邊也不重算**:`on_link_delete` 全部內容只是
記一行 log ＋ POST 通知孿生,全檔 **0 個 `remove_edge`**;`install_all_pair_paths`
被 `install_initial_openflow_entries_completed` 擋著,**一個 process 只跑一次**
(兩個呼叫點都在啟動路徑,而且整支檔案沒有任何週期性觸發)。

## 這條的一般性教訓

🔑 **修復會改變可達性。「這個缺陷是誰的」這個問題,答案取決於誰讓它構得到。**

依 A1.5(bug 頁只講繼承缺陷),`034da18` 因此**不算 baseline 缺陷**,照
`a72a168`/`8c25dbc` 先例移到穩健性頁。而且這是**更好的故事**:
「修好一個繼承缺陷,曝光了它底下的第二個,而我在實跑裡抓到了。」

## 順帶推翻的一個錯誤機制

Adam 後來提了一個機制:「watchdog 觸發重算,但 BFS 在沒刪邊的舊圖上跑,算出同一條死路
再下發回去,重算變成假動作。」**那個失敗模式是真的,但需要「只加重算、沒加刪邊」的版本
才會發生**——`2c81b26` 兩件事一起加,所以跳過了它。實際的舊碼是更簡單的失敗:
**規則裝好之後永遠不動。**
(另外 `calculate_all_paths` 是 **P4 proxy** 的函式,`intelligent_router.py` 裡 0 次。)

## 實測的 baseline 行為(取代 291 秒)

還原 `intelligent_router.py` 到 `2c81b26^`(**純 Python,零編譯**——這是關鍵,不必建
baseline kernel),同一支 `measure_failover.sh`、OVS 128-host、故障持續 180 秒:
**180.75 / 180.75 / 180.75 s,三次都只在故障解除後才恢復。**
三次到小數點第二位相同,因為**中斷長度由故障持續時間決定**,不是控制平面做了什麼。
對照現行碼 47.0–56.4 s(n=10)且在故障仍在時自癒——**類別差異不是程度差異,所以 n=3 就夠。**

控制條件(不做就沒意義):注入前 `h1→10.0.0.33` 0% 遺失、bridge 是 `fail-mode=secure`
(沒規則就丟包,排除別的機制在撐)、netem 三輪全程驗證在位。

**Adam 裁定:291 秒不進簡報。** 證據全文 `doc/audit/2026-08-19_failover-provenance/REPORT.md`。
相關:[[cited-line-numbers-are-not-evidence]]、[[reproducible-is-not-mechanism]]。
