---
name: worktree-agents-branch-from-origin-main
description: Agent 的 isolation "worktree" 是從 origin/main 開分支，而這個 repo 的 origin 是上游 lab repo（沒有 tests/、跟我們差 259 個 commit）
metadata:
  node_type: memory
  type: feedback
  originSessionId: 8edf5944-68e6-42ce-835d-3bd907b71753
  modified: 2026-08-13T02:31:44.204Z
---

2026-08-12：我用 `isolation: "worktree"` 開 subagent 修 `FlowLinkUsageCollector`，它回報
worktree **不是**從我的分支開的。查證屬實，而且是**系統性的**——reflog 寫得清清楚楚：

```
worktree-agent-<id>@{2}: branch: Created from origin/main
```

這個 repo 有兩個 remote，而**我們的工作全都在 `p4`**：

| remote | 指向 | 狀態 |
|---|---|---|
| `origin` | `ndtwin-lab/NDTwin-Kernel`（上游 lab） | `8b61cdc` "Add sharding"，**沒有 `tests/` 目錄** |
| `p4` | `Adam010341/NDTwin-Kernel-P4`（Adam 的 fork） | 我們的分支在這 |

`git rev-list --left-right --count origin/main...fix/flow-rate-divide-by-zero` = **1 / 259**。
所以 subagent 預設落地的地方是**另一份程式碼**，而且**整套測試根本不存在**。

**為什麼危險：** 缺陷通常兩邊都在（只是行號不同），所以 agent 會「成功修好」某個東西然後
回報綠燈——但那個綠燈量的是別的樹。這次沒出事只因為那個 agent 自己發現行號對不上、
自行 `reset` 到正確的 base 並在報告裡講明。**別指望下一個也會。**
（本次 HEAD 驗證過：`8b61cdc` 不是我們分支的祖先，之前三個 agent 的合併沒有把上游拖進來。）

**How to apply：**
- spawn worktree agent 時，**在 prompt 裡明寫 base**：「先確認你在 `<branch>` 的 tip
  （`git log --oneline -1` 應該是 `<hash>`），不是的話 reset 過去」。
- 給行號當交叉驗證：行號對不上就是 base 錯了，這是最便宜的偵測手段。
- 給它**預期的測試數**（會變，動筆時查 [[ndtwin-current-state]]；2026-08-13 為
  C++ 547/69、Python 524）。`tests/` 不存在跟「測試全過」在報告裡看起來可以很像。
- 收回來一律 `git merge-base --is-ancestor <mybase> <its-branch>` 驗一次再 merge。

**2026-08-13 整夜輪的命中率：5/5。** 當晚開的五個 worktree agent（B1/B2/B3/B4/S）**全部**
落在 `8b61cdc`（上游、無 tests/），全部靠 prompt 裡的「`git log --oneline -1` 驗證＋
`git reset --hard <hash>`」指令自救。這條 prompt 樣板已證明是**必要品不是保險**，
每次 spawn 都要寫。

相關：[[two-writers-one-worktree]]（同一個主題的另一面：隔離不夠 vs 隔離到錯的地方）、
[[spawn-subagents-with-opus-and-max-effort]]、[[push-commits-to-github]]（分支追 `p4` 不是 `origin`
——同一個 remote 混淆的根源）。

## 🔴 2026-08-30 反例：這條預設讓一個 agent 整輪作廢

Agent-tool 的 worktree 隔離**預設就是從 `origin/main` 分**——而那天 `origin/main`（`f5db629`）
落後真正的工作分支 **765 顆**：worktree 裡沒有 `p4_proxy/`、沒有 `tests/`、
`HttpSession.cpp` 短了兩百多行，brief 引的行號整批對不上。四個平行 agent 一個作廢、
三個中途下令 `git checkout --detach <當前 sha>` 才救回（worktree 與主 repo 共用物件庫，
本地 sha 都構得到，救援是一行）。

🔑 **這條規則的適用域要收窄**：它是給「對外 PR／要乾淨基底」的工作用的。
**repo 狀態相依的派工（讀現行碼、讀最近的 audit 文件、修現行缺陷）必須明令 base**，
派工令裡直接寫 `git checkout --detach <sha>`，不要依賴預設。
