---
name: doc-naming-and-credibility-conventions
description: doc/ 的檔名日期慣例（用建立日、刻意不開例外）與「三種可信度不要混用」的分級法——這兩樣 doc/README.md 沒寫，其餘索引功能已由它接手
metadata: 
  node_type: memory
  type: reference
  originSessionId: eb665942-c34e-4ce9-bc42-2307c10c8a8a
  modified: 2026-08-27T14:21:02.525Z
---

🔴 **`doc/README.md` 是文件索引的權威**（現役／參照／歷史／草稿四種地位，逐檔標記，
repo 內、跟著程式碼一起版本控制）。本檔**不是索引**，只保留 `doc/README.md` 沒有寫、
而且遺失了會重複踩坑的兩樣東西。

（2026-08-27 合併自 `ndtwin-doc-index-2026-08-11` 與 `ndtwin-audit-doc-index`，兩檔已退休。
它們的索引內容全部被 `doc/README.md` 覆蓋。）

## 一、三種可信度不要混用

引用任何文件之前，先分清楚你對它的認識是哪一種：

1. **我親自讀過**——能描述內容、能指出它哪裡沒講。
2. **subagent／別人轉述過**——內容可能對，但轉述是快照，而且轉述者的盲點你看不到。
3. **我只知道檔名**——這一種最危險，因為講起來跟第 1 種一樣流利。

**寫進任何報告或記憶時要標明是哪一種。** 這條與 [[investigation-briefs-separate-observation-from-inference]]
同源：把「單向推讀」標成「實測事實」是同一個錯的另一個面。
相關反例見 [[cited-line-numbers-are-not-evidence]]（一個誤讀的行號散進四份文件）。

## 二、`doc/` 的檔名日期慣例（2026-08-13 起，commit `9e3874c`）——不要「修回去」

**`doc/` 底下每個檔名與資料夾名都以建立日期開頭**（`YYYY-MM-DD_`），所以 `ls` 就是時間序。
Adam 的原話：「他們名字很像但又不知道先後順序」。

- **用建立日，不是最後更新日。** 後者每次編輯都要改名，而**每次改名都會打斷所有引用**。
  代價是 `2026-01-02_ndt_api.md` 排在最前面（它確實是那天建立的，雖然一路更新到 08-12）
  ——**新鮮度看 git，不看檔名**。
- **刻意不開例外**：規則一有例外就失去「看檔名知順序」的意義。
- **原本日期在結尾的一律搬到開頭**（`overnight-review-2026-08-12` → `2026-08-12_overnight-review`），
  因為結尾的日期排序效果等於沒有。
- **容器與入口不加日期**（它們不是某一輪工作）。2026-08-27 實測 `doc/` 底下 24/28 以日期開頭，
  不加的四個是 `audit/`、`debug-log/`、`KNOWN-ISSUES.md`、`README.md`——**全部符合這條例外**。

⚠️ **批次改名的坑（實際踩過）**：那次一口氣改了 105 個名字、532 處引用。
`overnight-review-2026-08-12` 這個模式**同時命中記憶目錄裡的檔名**
`overnight-review-2026-08-12.md`（那個沒跟著改），結果把 `MEMORY.md` 的連結指到不存在的地方。
⇒ **跨目錄批次取代時，記憶目錄要排除在「資料夾名」的取代之外。**
（後遺症到 2026-08-27 還在：該檔的 frontmatter `name:` 與檔名至今不一致。）

## 三、🔑 檔名是位址，不是宣稱

**過時的檔名用 `description` 與索引標題補償，不要改名。**
改名會斷掉所有指向它的 `[[wikilink]]`，而**斷引用比檔名過時貴**——檔名過時只是讀起來怪，
斷引用是下一個 session 手上點不開，而且**不會報錯**。

現行的兩個實例，都刻意留著：

| 檔名 | 實際狀態 | 補償方式 |
|---|---|---|
| `ntg-bmv2-support-pending-feature` | 早已交付（2026-08-15） | 索引標題寫「NTG×bmv2——已交付」 |
| `agent-can-do-live-tests-except-start-mininet` | 已能自己起 fabric | `description` 明寫「檔名的 except 早已過時，留著護 wikilink」；索引標題寫「含起 fabric」 |

🔑 **退休一個記憶檔之前，先 `grep -l "\[\[<slug>\]\]" *.md`。**
每一條 inbound 連結都要改成指向繼承者或 repo 正文，**不能只刪 `MEMORY.md` 那一行**。
2026-08-27 實測：退休 5 個檔會產生 **7 條斷鏈**，其中 5 條散在毫不相干的檔案裡。

相關：[[ndtwin-current-state]]、[[two-writers-one-worktree]]。
