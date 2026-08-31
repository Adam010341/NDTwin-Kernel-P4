---
name: fresh-grep-before-confirmed-quote
description: 審計時我「記得」Read 輸出裡有一行不存在的程式碼，差點寫成 CONFIRMED；寫入報告前必須對引文重新 grep，能跑的測試勝過我對先前工具輸出的記憶
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 56605751-5f88-48b4-a50c-2d7516f6f13d
  modified: 2026-08-29T05:13:02.723Z
---

2026-08-11 深夜審計 Phase 7 時：我確信先前的 Read 輸出顯示 `P4PowerStrategy.cpp` powerOff
失敗分支裡有 `topoMonitor->setVertexDown(node)`（「註解說 left up、程式碼卻設 down」——
一個完美的 Theme-A 發現）。實際：`grep -n setVertexDown` 只有 :115（成功路徑）、
`git show HEAD` 相同、mtime 證明檔案在我讀之前就沒變過、編好的測試 8/8 綠
（`PowerOffFailureLeavesTheVertexUp` 直接反證）。是我對自己 context 裡工具輸出的
**重建**出錯，不是檔案變了。

**Why:** 這正是審計要獵的失誤型態（把未驗證寫成 CONFIRMED），差點由審計者自己犯下。
[[cited-line-numbers-are-not-evidence]] 講的是別人的引文；這次證明**我自己十分鐘前的
閱讀記憶同樣不是證據**。救回來的不是重讀，是跑了真測試。

**2026-08-12 的變體：不是記錯，是憑空編出來的。** 修上面那條行號腐爛時，我在同一段註解裡
**連續編了兩個不存在的函式名**——先寫 `calculatePathsForFlows`（真的是
`calFlowPathByQueried`），改完又寫 `serialiseKey`（真的是 `packKey`）。兩個都是「聽起來
很合理的名字」，兩個都是在寫進去之前 grep 才抓到的。同一次還對 subagent 斷言
「已經有好幾個測試在 patch `grpc.insecure_channel`」——**一個都沒有**，它查完回報糾正我。

所以這條記憶的範圍要放大：**不只引文要 grep，任何我「順手寫出來」的符號名、檔名、
以及對現況的斷言，都要 grep。** 流暢地生出一個合理的名字，跟知道那個名字存在，是兩件事。

**How to apply:** 每一條 CONFIRMED 引文，寫入報告前對現行檔案 fresh `grep -n` 精確字串
（LLMAgent 三條就是這樣二次驗證的）。有測試存在就跑它——一次真實執行勝過任何閱讀。
兩個獨立來源矛盾時（我的記憶 vs grep），先懷疑記憶。相關：[[mutation-gate-for-tests]]、
[[reproducible-is-not-mechanism]]。

**2026-08-29 第三式：拼裝引文＋掛錯出處＋標上 CONFIRMED，還活過兩層交付。**
我把 `docs/performance.md` 的原句 "this can have a massive impact." 流暢改寫成
"Build flags can have a massive impact on performance"、**加上引號**、出處寫成 README——
先在檢索檔標「README 原文確認 ✅」、再進研究報告、再進投稿 tex，**三層沒有一層真的
grep 過**；外部審查逐字查兩份檔案才抓到（一篇主張引用紀律的稿子捏造官方引文＝
道德權威歸零級的錯）。⇒ **引號＝逐字的承諾**：意譯不准帶引號；引文入檔的動作＝
對原始檔逐字 grep＋記下檔名與版本（這次連檔案都指錯）。與 08-15 姊妹案同構：
**流暢的改寫在複製鏈裡會自動升格成「原文」**。修復＝三處同日更正，
正句對 main 與 `f0b7d201` 雙版驗證。

**2026-08-15 姊妹案:文獻值經記憶轉述變「本機實測」。** 記憶檔寫著「simple_switch_grpc
只有 ~170 Mbps」(出處=SIGSIM-PADS '23 論文),被我讀成本機量測,寫進報告/簡報素材三處
才發現本機從未做過飽和實測。規則:**引用數字前回記憶原檔查出處欄**,描述句≠量測值。
