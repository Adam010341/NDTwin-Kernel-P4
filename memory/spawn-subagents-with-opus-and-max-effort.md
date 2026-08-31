---
name: spawn-subagents-with-opus-and-max-effort
description: Adam 要求 spawn subagent 一律 opus 5 + effort max；不要依賴繼承，model 明寫在 Agent 呼叫裡
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-12T06:48:17.507Z
---

2026-08-12 Adam：「以後指定用 opus 5，effort max。」

**怎麼做：每次 `Agent` 呼叫都明寫 `model: "opus"`。** 不要靠繼承——這台機器上繼承鏈是不確定的：

- `/home/adam/.claude/settings.json` 裡有 `"model": "sonnet"` 和 `"effortLevel": "high"`。
- 但 session 執行時是 Opus 5（Adam 用 `/model` 切的），`CLAUDE_EFFORT=max`。
- `CLAUDE_CODE_SUBAGENT_MODEL` 未設定，`.claude/agents/` 不存在。

所以「沒指定就繼承 parent」到底繼承的是**執行時的 Opus** 還是 **settings 裡的 sonnet**，
我從外面**觀察不到**，文件也沒有給可以驗證的方法。明寫 `model` 就沒有這個問題。

Effort 沒有 per-call 參數，只能靠繼承（`CLAUDE_EFFORT=max` 時 subagent 跟著 max）或
`.claude/agents/<name>.md` 的 frontmatter：

```markdown
---
name: <slug>
description: <一行>
model: opus
effort: max
---
```

`name` 和 `description` 是必填，`model`／`effort` 選填。**這個 frontmatter 的
`effort` 鍵是 claude-code-guide agent 從文件查來的，我沒有實測驗證過**——寫錯的話會被
忽略而不是報錯，所以不要假設它生效了。

## Fork 不能用，要手動補脈絡

`subagent_type: "fork"`（會繼承 parent 對話的那種）**在這個部署沒有註冊**——實測回
`Agent type 'fork' not found`，可用的只有 `claude` / `claude-code-guide` / `Explore` /
`general-purpose` / `Plan` / `statusline-setup`。沒有 rewind 之類的替代路徑。

所以 subagent 一律冷啟動，**它們有沒有拿到這個 memory 目錄我從外面驗證不了**。替代做法：

1. 把當輪的決定和教訓**直接寫進 prompt**（今天三個 agent 都是這樣，成果可用）。
2. **在 prompt 裡明寫記憶目錄的絕對路徑**，叫它先讀：
   `/home/adam/.claude/projects/-home-adam-Desktop-NDTwin-Kernel/memory/MEMORY.md`
   ——這是最便宜的「給它脈絡」，比丟 transcript 好（transcript 太大會撐爆它的 context）。
3. 指向已經寫好的裁決文件，而不是要它自己重新推導。

順帶：fork 就算能用也不全是好事——它會連我的錯誤轉折一起繼承。prompt 這條路強迫我把
「什麼才重要」講清楚，這正是 [[review-prompt-shape-beats-model-choice]] 說的事。

相關：[[delegate-test-writing-to-subagents]]、[[review-prompt-shape-beats-model-choice]]
（prompt 形狀比模型選擇重要，這條不會因為改用 opus 而失效）。
