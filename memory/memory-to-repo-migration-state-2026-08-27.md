---
name: memory-to-repo-migration-state-2026-08-27
description: 🔴 在途：把記憶裡屬於專案的東西搬進 repo。CLAUDE.md 草稿已完成未 commit（等 auditor 讀＋這輪實驗收完）；repo 內 79 處指向記憶的壞引用已掃出未處理；C 層差集未查故不動
metadata: 
  node_type: memory
  type: project
  originSessionId: eb665942-c34e-4ce9-bc42-2307c10c8a8a
  modified: 2026-08-30T05:14:34.322Z
---

2026-08-27 深夜寫。**這條工作的裁決者是 `8/27 auditor`，不是我。**

🛑 **2026-08-27 23:25 依 Adam 指示停工**（經 auditor 轉達）：**用量要留給半夜長跑的 session**
（`開機手冊` 的 v8 安裝測試 2–4 小時、整夜 chaos 差異跑）。
**這是主動停，不是卡住** —— A/B/C 三層都沒有進行到一半的動作，`CLAUDE.md` 與
`KNOWN-ISSUES` 的修正 auditor 明確裁定**不急、明天做**。

## 1. 目前狀態

**記憶目錄清理：已完成。** 收工時 `memory-lint.sh` 七項全過。
⚠️ **不要拿檔數當基準。** 同一次收工我自己就寫出兩個數字（本節原本寫 118、最終回報 120），
**四分鐘後再跑已經是 122 檔／索引 121 條**——因為 23:20–23:22 之間有**別的 session**
在同一個目錄寫了六個檔。**基準是「七項有沒有過」，不是任何數字。**
5 個檔已退休（Adam 親自 `rm`）、2 個新增、格式瑕疵三條全修、7 條斷鏈全部改指 repo 正文。
備份在 `/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/eb665942-…/scratchpad/memory-backup-215458/`
（121 檔）——⚠️ **那是 session 範圍的暫存目錄，會被清掉。被刪那 5 個檔的唯一副本在裡面。**
它們是刻意退休的，所以清掉沒關係，但**「還原得回來」這個安全網是暫時的**。

**搬進 repo 這件事：三層，只有 A 層做出草稿，B/C 兩層都還沒動。**

| 層 | 目標 | 狀態 |
|---|---|---|
| A | `CLAUDE.md`（repo 從未有過，`git log --all` 證實） | 🔴 **草稿已遺失**（見下方 08-30 更新）。原為 `scratchpad/CLAUDE.md.draft`，245 行 / ~11.9 KB，未 commit |
| B | `doc/KNOWN-ISSUES.md` 補差集 | ⏸ 未動 |
| C | 兩個帳本的「發現」搬 `doc/audit/` | 🔴 **刻意不動**（差集未查） |

## 2. 已定案的決定（連理由）

- **`CLAUDE.md` 我不自己 commit。** auditor 要先讀過，而且要排在這輪實驗收完之後——
  它一放進去會**立刻影響三個正在跑實驗的 session**。
- **草稿只放規則不放故事。** 例：寫「`pkill`／`pgrep` 永遠單獨一次呼叫」，
  那八次踩坑的編年史留在記憶。auditor 核可了這個切法。
- **B 層是「補差集」不是「建立」。** 因為 `doc/KNOWN-ISSUES.md` **已存在** 650 行 / 42 KB，
  而且已有「示範會不會踩到」的排序軸與失效方向標籤。
  七個候選裡 **`power-on-reports-success-without-acting` 已完整在 A-1、
  `rejected-requests-can-still-act` 已完整在 B-1** ⇒ 真差集是 5 條不是 7 條。

  **那 5 條裡我只記下 3 條的名字**（逐條查過、`KNOWN-ISSUES.md` 裡**完全沒有**）：
  `bmv2-unknown-status-vocabulary`、`destination-paths-not-monotonic`、`shell-outs-need-timeouts`。
  ⚠️ **另外 2 條是「部分涵蓋」，而我沒有把名字寫下來** —— 不要猜，
  明天**重跑一次差集**（成本＝拿候選清單對 `doc/KNOWN-ISSUES.md` grep 一次）。
  🔑 這裡刻意不補名字：候選清單我現在手上沒有，用不同的候選集重推會得到不同答案，
  而它讀起來會像是同一次調查的延續。見 [[doc-naming-and-credibility-conventions]] 第一節。
- **C 層在查完差集前不動。** 證據：`ndtwin-current-state` 的 §14-8 自己就寫著
  「P 的結果（commit `f43b21a` 報告、`185fabd` 資料、`34bbea7` 更正①）」
  ⇒ **那些發現已經在 repo 裡了**，記憶裡的是指標不是正本。先搬會搬第二次。
- **「檔名是位址，不要改名」立為通則**（寫進 [[doc-naming-and-credibility-conventions]]）：
  過時檔名用 `description` 與索引標題補償。`ntg-bmv2-support-pending-feature`（已交付）與
  `agent-can-do-live-tests-except-start-mininet`（已能起 fabric）都照這樣留著。
- **退休檔案前必須查 inbound wikilink。** 實測退休 5 個檔會產生 **7 條斷鏈**，
  而 **5/7 根本沒有「繼承者」**——正本在 repo 不在記憶。已寫進 `memory-checkpoint` Phase 1。

## 3. 尚未解決 / 討論到一半

- 🔴 **repo 內 79 處指向記憶的引用**（排除 handoff-log 歸檔後）。
  auditor 把它排在 **B 層其他工作之前**，理由：那不是不方便，是
  **repo 裡一個對所有貢獻者都壞掉的引用**——他們沒有這個記憶目錄。
  最密集：`doc/audit/2026-08-25_large-scale-concurrent/PREREG.md`（11 處）、
  `sampling-rounds/PREREG.md`（8）、`doc/KNOWN-ISSUES.md`（7）。
  **清單已掃出，處理順序未定，一處都還沒改。**
- **C 層的差集**：完全沒查。（B 層是逐條查過的，兩者可信度不同，不要混用。）
- **`doc/KNOWN-ISSUES.md` L486-487 的寫法**：「（7 個實例）→ memory `replace-vs-add-bug-shape`」
  ——這是 repo 指向記憶的**典型**，也是 79 處裡最該優先換成內容的一處。
- **auditor 交代的四個判斷題**我已回報，**它的裁決我只收到前兩題**
  （`verify-against-known-good-output` 的 description 改成寫規則不寫計數；
  `slide-deck-generator` 改 description 寫清楚範圍＝現況是 JS）。
  後兩題（兩個「檔名過時但不改名」）它裁定照我的建議＋立為通則，已執行。
- **`before-sleep` 的第一步在真實情況下會不會空轉**：`交接摘要 Skill` 在等這個結果。
  本次實跑的答案見下方「本次實跑的觀察」。

## 4. 立即下一步

**問 `8/27 auditor` 兩件事，不要自己決定：**
1. 79 處壞引用要不要現在開始改、從哪幾個檔開始。
2. `CLAUDE.md` 它讀過了沒、這輪實驗收完了沒。

草稿在 `scratchpad/CLAUDE.md.draft`——⚠️ **那是暫存目錄，動手前先確認它還在**；
不在的話內容要從本檔第 2 節與 auditor 的裁決重建。

## 5. 建議明天先驗證（開哪個檔、看什麼）

1. **`bash ~/.claude/skills/shared/memory-lint.sh <記憶目錄>`** — 十秒。
   看的是**七項有沒有過**，不是檔數（檔數每天都在變，別的 session 也在寫）。
   🔴 **已知有一項未過、刻意留給明天**：`verify-the-purpose-not-the-mechanism.md` 是**孤兒檔**
   （在磁碟、不在 `MEMORY.md` ⇒ 永遠載不到）。它 23:20 由**別的 session** 建立，
   而它 23:21 才剛寫過 `MEMORY.md` ⇒ 我刻意沒替它補索引，**搶著改會互相覆蓋**。
   明早若還是孤兒，補一行索引就好（內容是 `pgrep` 偽陰性那條的延伸）。
2. **`ls scratchpad/CLAUDE.md.draft`** — 暫存目錄可能已清，這決定要不要重建。
3. **`git log --all --oneline -- CLAUDE.md`** — 確認仍然是空的。
   若非空，代表 auditor 或 Adam 已經 commit 了，本檔第 1 節要更新。
4. **`grep -rn 'memory \`\|→ memory\|\[\[[a-z0-9-]\{8,\}\]\]' doc/ | wc -l`** — 昨晚是 79。
   數字變了代表有人動過，先查是誰再繼續。
5. **`ndt status`** — 昨晚 claim 是 `none`、fabric up、handoff 由 `8/27 mainDev` 留下。

## 本次實跑的觀察（`before-sleep` 第一次被使用）

- **第一步沒有空轉，但抓到的不是背景工作。** 這個 session 零背景工作；
  抓到的是**別人的**（`proxy_agent/main.py`、`ndtwin_kernel`，屬 `8/27 mainDev`）。
- 🔑 **那個檢查自己示範了它記錄過的陷阱**：我的 `pgrep -a -u ... -f 'ndtwin_kernel|proxy_agent|…'`
  **匹配到自己的命令列**（pid 1115399 就是那條 bash）。
  ⇒ [[put-measurement-commands-in-script-files]] 的母規則又中一次，而且是在一個**專門檢查背景工作**的步驟裡。
- **`lastActivityAt` 的分界又不乾淨**：五個在 0~19 分鐘，`Context` 在 **104 分鐘**，
  其餘 10 小時以上。跟 08-27 稍早那次（78 分鐘）同型 ⇒ **「中間有一筆」看來是常態不是例外。**

## 2026-08-30 更新（Adam 問「這專案是不是沒有 CLAUDE.md」時實測）

- 🔴 **A 層草稿已不存在。** `/tmp/claude-1000/…/eb665942-…/scratchpad/CLAUDE.md.draft` 已被清掉，
  `find /tmp/claude-1000 -iname 'CLAUDE.md*'` 全域零命中 ⇒ **245 行草稿沒有任何副本**。
  要做只能照本檔第 2 節的四條決定重建（或跑 `/init` 產一份再用那四條改寫）。
  🔑 這正是本檔自己第 5 節第 2 步預期的分支，**不是意外**——但也證實了
  「暫存目錄不能存放要跨天用的產出」，見 [[evidence-must-outlive-the-handoff]]。
- ✅ **`git log --all --oneline -- CLAUDE.md` 仍然是空的**（第 5 節第 3 步）⇒ auditor／Adam 都沒 commit。
  同時確認 `~/.claude/CLAUDE.md`、`~/Desktop/CLAUDE.md`、`/CLAUDE.md` 全都不存在
  ⇒ **這個 repo 目前完全沒有任何層級的 CLAUDE.md 在載入**，規則全靠記憶目錄撐著。
- ⚠️ **第 5 節第 4 步的 79 現在是 140**，但**不要當成「有人動過」**：08-28/08-29 之間
  `doc/` 新增了數個 audit 目錄，增量很可能是新文件帶進來的新引用。
  要用這個數字前得先按目錄分群，不要直接比總數。

相關：[[checkpoint-skills-and-session-cost]]、[[doc-naming-and-credibility-conventions]]、
[[the-clean-version-is-the-one-to-recheck]]、[[lab-claim-handoff-protocol]]、
[[evidence-must-outlive-the-handoff]]。

## 🆕 08-30：CLAUDE.md 偏好清單種子（auditor 彙整、Adam 尚未裁落檔——落檔前這裡是唯一正本）

⚠️ 彙整自既有記憶檔、未經 Adam 逐條核可。他 08-30 看過整份、說「還不要編輯 claude.md」。

**溝通與裁決**：對 Adam 回報一律中文（code/commit 英文）／四段式：要裁的·推翻更正·交付·細節（格式固定字數自由；要裁的一律 park）／多題裁決用互動表單（建議放第一、寫後果、末留自由輸入）／評估改動大小送 diff 不送形容詞。
**授權邊界**：對外產出先本機草稿等點頭（GitHub 沒有「只有我看得到」）／commit 時機自主含 push，**但公開與否只能打公開 URL 驗**（push URL 可能一私一公）／下「不要做 X」前先確認 X 沒發生；收回命令後確認對方沒執行前不做損害評估／破壞性操作前先 commit。
**工程紀律**：AI 產碼標 `[Co-developed with claude code -- Adam]`／永不 `pkill -f`/`pgrep -f` 殺程序；斷鏈路 `tc netem`；長跑 `setsid`／共用 worktree：`git commit -m … -- <paths>`、新檔 `git add -N`（⚠️ untrack 等 index 操作**不可用 pathspec**）／`ndt` 都帶 `NDT_OWNER`、動 lab 前 claim、問「在跑嗎」看 `measuring`／環境狀態自己查。
**量測與宣稱**：benchmark 指認 binary（sha＋識別碼種類）／「跑過」與「讀過未執行」永不混表／raw 進 audit-raw；口徑與 raw 不可協商／每次實驗對帳舊結果／測試沒看過紅不算交付。
**委派**：subagent 明寫 opus／機械活 deepseek-cli／orchestrator 不做 grunt work／派工附驗收方式（怎麼強迫它紅）／worktree agent 的 base 明令 `checkout <sha>`（預設 origin/main 會過期）。
