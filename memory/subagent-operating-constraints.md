---
name: subagent-operating-constraints
description: DeepSeek 結構上不能操作 stack（無 shell、sudo/mnexec 一律拒）；只有 Claude Agent 有手。背景 agent 被停掉時，留在 context 裡的發現全部消失
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 56cc1a30-fc20-4847-97f3-176033806b7e
  modified: 2026-08-19T09:28:44.181Z
---

## DeepSeek 不能操作，只能讀與推理

`deepseek_agent_task` 就算開 `allow_run: true`，工具描述明寫：
**read-only allowlist、no shell、`sudo` 與 `mnexec` 在任何 argv 位置都被拒絕**。

而操作 NDTwin 的 lab 需要的正好是這三樣（`sudo -n ndtwin-lab topo-start`、
`sudo -n mnexec -a 1 ovs-ofctl`、pipe/重導向）。**所以「讓 DeepSeek 操作 stack」字面上做不到。**

Adam 2026-08-18 的裁定因此是兩階段：① 只開 Claude subagent 自己測；
② DeepSeek 盲寫測試計畫、Claude 當苦力執行。**階段 ② 尚未開始。**

⚠️ `Agent` 工具的 `model` 只吃 `sonnet|opus|haiku|fable`，**沒有 4.8/5 的選擇器，
也沒有 `effort` 參數**——effort 來自 agent 定義檔的 frontmatter。所以「opus 4.8 跟 5 各跑一次」
要 Adam 自己在 `.claude/agents/` 建兩個定義檔。這點與
[[spawn-subagents-with-opus-and-max-effort]] 併讀：`model: "opus"` 仍要每次明寫。

## 背景 agent 被停掉 = 留在 context 的發現全部歸零

2026-08-18 第一輪 subagent 跑了 35 分鐘、做了真工作（單向斷鏈注入含前後置斷言、
twin_audit、自己寫的 ground-truth 腳本），然後被停掉——**`FINDINGS.md` 從未建立，
所有結論消失**，只剩過程日誌可撈。

**所以 brief 的第一段就要寫「先建發現檔、邊做邊寫」，而不是寫在報告章節裡。**
第二輪照此改寫，它在最初幾分鐘就建了檔，904 行全數保住。

判斷它是否還活著的方法（**不要讀 output_file，會爆 context**）：
看它自己產出的檔案 mtime，以及 `pgrep` 有沒有測試行程在跑。**stack 還開著不代表它還活著**
——第一輪停掉後 stack 孤兒運行了 40 分鐘。

## 交棒紀律

一次只有一個 actor。交棒前把 stack 收乾淨並對帳到零，並且**把自己的發現移出 repo**
——第一輪我把 findings 放在 `scratch/`，就在要交給它的 `scratch/lab/` 隔壁，
等於直接送給它看。

## 2026-08-19：Muse Spark 現在有 repo 存取權（我改的）

`~/.local/bin/deepseek-agent` 加了 `PROVIDERS` 表與 `--provider {deepseek,muse}`，
MCP server 加了 `muse_spark_agent_task`。**共用同一個工具迴圈**——兩邊都是 OpenAI-compatible 的
`chat/completions`，只差端點／金鑰／預設 model。備份 `.bak-2026-08-19`。實測跑通。

三個踩過的細節：`--model` 預設必須是 `None` 再依 provider 解析（共用預設值會把 DeepSeek 的
model 名字送去 Meta，而 API 的錯誤訊息不會說是哪個給錯）；`reasoning_effort` 只能對
DeepSeek 送（Muse 對未知欄位 400）；順手修掉「步數用完而報告檔沒建立時的
`FileNotFoundError` traceback」——**那個 traceback 把「被截斷」偽裝成「崩潰」，害我去查 API 層**。

⚠️ **`deepseek-agent` 本來就有 `-e/--effort` 且預設 `max`**，只是 MCP wrapper 沒暴露。
別再說「effort 開不了」。

**contributor 變體無限制**（Adam 2026-08-19）：程式碼與 audit 材料都開源且已在 GitHub 上
（`origin = github.com/ndtwin-lab/NDTwin-Kernel`，`doc/audit/` 有 137 個 tracked 檔）。
🔑 **這條線上已經有兩次憑假設加守衛的紀錄**（08-18 的「專有程式碼」、我 08-19 的
「audit 是 lab-internal」），**兩次都錯**。**看 `git remote` 再推論什麼是私有的。**

## 🔴 Gemini 3.1 Pro（agy）不要用——Adam 2026-08-19 裁定

兩次都是**做完全部工作才在最後一步失敗**，69 分鐘零產出：

1. **42 分鐘**：`agy` 的 write-file 工具**只接受 `~/.gemini/antigravity-cli/brain/<uuid>/` 底下的路徑**，
   而那個 uuid 是每次 run 才產生的——**所以「叫它寫到 repo 路徑」注定失敗且無法事先指定**。
2. **27 分鐘**：`permission check failed for command "echo \"Ready\""`——agy 會問人要權限，
   無人應答就當拒絕。

可用的呼叫方式在 repo 裡：`tools/git-hooks/post-commit:187` 用
`--dangerously-skip-permissions`（刻意的，理由是「讓 agy 自己查東西」），
**但 `agy_start` 這個 MCP 工具沒暴露那個旗標**，而直接用 Bash 跑會被 Claude Code 的
分類器攔下。要修得再動一次 MCP server 加重連。

**以後只開 DeepSeek 和 Muse Spark。**

相關：[[orchestrator-must-not-do-grunt-work]]、[[delegate-test-writing-to-subagents]]、
[[deepseek-agent-tool-loop]]、[[live-round-2026-08-18-two-passes]]、
[[model-hypotheses-saturated]]。
