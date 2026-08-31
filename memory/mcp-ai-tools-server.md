---
name: mcp-ai-tools-server
description: "An MCP server at ~/.local/share/mcp-servers/ai_tools_server.py exposes DeepSeek, Muse Spark and the agy CLI as tools"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 354194c4-0718-4137-b4b9-524e1ee1af6d
  modified: 2026-08-11T11:37:13.161Z
---

Built 2026-08-11. Registered with Claude Code as `ai-tools` at **user** scope (the server lives outside any repo, so project scope would have pointed a committed `.mcp.json` at an external path).

- File: `~/.local/share/mcp-servers/ai_tools_server.py`
- Interpreter: `~/.local/share/mcp-servers/venv/bin/python3` (has `mcp==1.29.0` pinned — see [[pypi-mcp-httpx2-supply-chain]], do not upgrade blindly)

**Tools:**

| Tool | Notes |
|---|---|
| `deepseek_query` | Shells out to `deepseek-cli` with the prompt in a **file**, reusing its ARG_MAX and key-not-in-argv hardening rather than reimplementing the HTTP call. See [[deepseek-large-prompt-fix]], [[api-keys-leak-via-argv]]. |
| `deepseek_agent_task` | Wraps `deepseek-agent`; `allow_run` is off by default. See [[deepseek-agent-tool-loop]]. |
| `muse_spark_query` | Meta Model API, OpenAI-compatible, `https://api.meta.ai/v1/chat/completions`, token at `~/.config/muse_spark/token` (0600). **Refuses `-contributor` model variants** — Meta uses their traffic for training and this is proprietary code. |
| `agy_start` / `agy_result` / `agy_list` | Backgrounded because agy runs to a 900 s timeout. |

**Two design points worth not relearning:**

1. **`agy` reports its own failures on stdout and still exits 0.** So the wrapper deliberately returns raw output and makes no success/failure judgement — the `VERDICT:` convention the commit hook relies on belongs to its review prompt, not to agy, and would be wrong to impose on arbitrary prompts.
2. **Completion is recorded by the run itself in a `.done` file holding the exit status, never inferred from the pid.** `os.kill(pid, 0)` succeeds on a *zombie* — a child that exited but has not been reaped — so a pid check reported RUNNING forever for a run that had already failed in under a second (measured: still "RUNNING" at 300 s). A pid is also reusable after a server restart.

**Known blockers as of 2026-08-11**: DeepSeek needs Adam's VPN on (intermittent TLS reset at the SNI layer — just tell him, do not re-investigate; see [[check-env-state-dont-ask]] for the general habit). ~~Muse Spark `billing_not_configured`~~ → ✅ **2026-08-15 深夜復活**:Adam 給新 token(`~/.config/muse_spark/token`,0600),chat 正常。

**2026-08-15 深夜新事實**:
- `deepseek_query` 有 `effort` 參數(minimal..max,預設 max);判官用 v4-pro。
- Muse 的 effort 欄位=OpenAI 相容 `reasoning_effort`,檔位 **`xhigh` 不是 max**(打錯回 400 列合法值)。它是 reasoning 模型:`max_tokens` 太小會被 reasoning token 吃光、content=null——wrapper 因此回 None,別誤判成壞掉。
- **contributor 模式:Adam 2026-08-15 裁決可用**(「本來就是開源專案」)——wrapper 拒絕仍在,要用直接 curl `api.meta.ai/v1/chat/completions`(key 走 curl --config,見 [[api-keys-leak-via-argv]]),模型 id `muse-spark-1.2-contributor`。

**2026-08-30**：`*_agent_task` 走 MCP 有 **1800 s 靜默逾時**（per-server `timeout` 或
`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` 可調）——`max_steps=90` 在機器有載時**塞不進去**，
兩次 round-2 呼叫死時**零位元組**（首次落盤前就沒了，「增量寫」保護對早夭無效）⇒
**用 `max_steps≤45` 或拆軸多次呼叫**。同日教訓：**agent 艦隊與飽和實驗不要同窗跑**——
串流會被 softirq 餓死（3 隻斷線集中在實驗高峰），艦隊自己又是量測共變量（雙向都量到了）。

## 🆕 08-30 晚：CLI 與 MCP 是兩套憑證、兩條網路路徑

- **muse CLI（`muse exec`）＝402 Billing verification failed（重試 10 次）**，同時刻
  **MCP `muse_spark_query` 正常**——兩邊憑證獨立（CLI 走 provider login、MCP server 自帶）。
  muse CLI 修好前，muse 一律走 MCP。
- **deepseek-cli 在院內網路／VPN 下 curl SSL connection timeout**（兩發全滅、exit 28）；
  Adam 離開院內網路後同指令即通。歸因＝Adam 自述「剛剛連到院內網路所以不能用」＋
  off-VPN 成功佐證（機制未抓包，合理推定=VPN full-tunnel 路由）。外部模型呼叫失敗先問
  「現在掛著 VPN 嗎」。
- deepseek-cli 用法（讀過 --help）：`-m deepseek-v4-pro|deepseek-v4-flash`、`-f 檔案`、
  `-e minimal..max`；預設 flash@max。
