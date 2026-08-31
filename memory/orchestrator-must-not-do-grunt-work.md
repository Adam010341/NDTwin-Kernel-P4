---
name: orchestrator-must-not-do-grunt-work
description: 多 agent 輪次的用量規則——主導者只做分工與整合，粗活全丟 subagent；而且要假設中途會用完額度，發現一產生就立刻落檔
metadata:
  node_type: memory
  type: feedback
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-13T02:32:20.305Z
---

2026-08-12 Adam 在規劃「榨乾剩餘 token 的一輪測試」時明講的三條。適用於任何一次多 agent 輪次。

## 1. 主導的 agent 不做粗活

Adam 的原話：「**Fable 雖然要負責主導，但它不能做粗活，不然用量很快就燒完了。**」

主導者的工作只有：拆任務、寫 prompt、spawn、收結果、整合、裁決。
**讀檔案、跑測試、grep、跑 mutation、實際動手改——全部丟給 subagent。**

理由是用量結構：主導者的 context 會一路累積到輪次結束，它多讀一個大檔，之後**每一次**
往返都要重付那些 token。subagent 是冷啟動、用完即棄，它的 context 不會回流到主導者身上。
所以同樣一份工作放在主導者身上比放在 subagent 身上貴得多，而且是複利的。

## 2. 要假設中途會用完額度

「**調查到一半用量可能會不夠，要為這件事做準備（譬如隨時紀錄發現）。**」

**發現一產生就落檔，不要留在 context 裡等最後統一整理。** 額度用完是硬中斷，
沒有機會做收尾。具體做法：

- 每個 subagent 的 prompt 都要求它**邊做邊寫**到指定檔案，不是做完才寫。
- 主導者收到每份結果就立刻寫進索引檔，不要攢著。
- 檔案要放在**會活過這個 session 的地方**——記憶目錄或 `~/Documents/…`，
  不要放 session 專屬的 scratchpad。

## 3. 調查完要歸檔

「**調查完記得要歸檔。**」輪次結束時把散落的發現整理進記憶／文件，不要只留在對話裡。
這條跟 `session-close` skill 是同一件事，但在多 agent 輪次裡要**主動做**，
因為那時候的發現分散在好幾個 agent 的輸出檔裡，不會自己進到記憶。

## 4. 邊界條件（2026-08-13，Adam 當面核准的例外）

這條規則優化的是**寬扇出**（多條線並行、每條都要冷讀大量 repo）。當情境反轉——
**佇列窄而明確、每項都有 file:line 級證據、脈絡已經在主導者頭上、額度只剩「一個 Fable」**——
成本結構跟著反轉：subagent 的冷啟動（當晚每個 opus agent 燒 15–25 萬 token 重讀 repo）＋
寫 brief＋驗收整合，比主導者直接動手更貴。當晚修復輪由主導者親手完成 7 個 commit，
Adam 問「要自己修還是叫 subagent」後核准自修。判準不是身分是形狀：**扇出寬就丟出去，
佇列窄且脈絡已載入就自己做**，兩者都維持「發現一產生就落檔」。

相關：[[spawn-subagents-with-opus-and-max-effort]]（怎麼開）、
[[review-prompt-shape-beats-model-choice]]（prompt 形狀比模型重要）、
[[delegate-test-writing-to-subagents]]（哪些該丟、哪些要自己留）。
