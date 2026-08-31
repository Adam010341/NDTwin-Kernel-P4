---
name: test-conclusions-by-using-them
description: 🔑 同日三例三中（08-25）：結論「重讀」零命中、「拿去設計下一步」三連中——寫進報告前先問「這個結論會讓下一個實驗長什麼樣」
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 2adce14d-dbbd-405c-a9c2-59294a270681
  modified: 2026-08-25T04:28:46.588Z
---

**規則：每個結論寫進報告前，先拿它去設計下一個實驗（或下一步動作）。** 設計過程會強迫
結論的每個操作性含義現形——複查是被動讀、使用是主動推導，抓錯率天差地別。

三個實例（2026-08-25 同一天，mainDev 命名並三度示範；三條都已先通過作者重讀＋審查驗收）：

1. **settle 歸因**：為 settle sweep 設計「怎麼斷言 settle 值送進 Ryu」→ 發現 gate 在
   16/16（含全部健康 boot）逾時 0/128 ⇒ 歸因撤回（`3dcb8ec`）。已進 commit＋兩邊記憶
   才被抓到。
2. **197-vs-93「學得更多」**：審查要 provenance → 重導出取數指令 → 行數≠distinct key
   ⇒ 核心標籤反轉（`dd2ea62`）。也已進 commit。
3. **combo「未試」**：照裁決寫 combo 探針 → 第一步「combo 到底是什麼組態」→ 發現
   fix-verify 的 async 臂**從來就是 combo**（timeout 自 `d1d973d` 起預設開）⇒
   「72fbae6 單獨不足」措辭作廢、已知修法組合其實已用盡（`8ab0132`）。

**Why:** 重讀驗證的是「句子自洽嗎」；使用驗證的是「世界照這句話運作嗎」。三例的錯全在
後者——語意通順、操作性含義錯。

**How to apply:** 驗收 checklist 在「數字重算」「歸因對撞舊輪次」之外加第三問：
「**如果照這個結論做下一步，第一步是什麼？**」——就地做那一步的紙上推演（查組態、寫斷言、
列指令），常常十分鐘內見血。相關：[[check-against-prior-experiments]]、
[[arithmetic-that-fits-is-not-the-mechanism]]、[[review-round-2026-08-21]] ⑭。
