---
name: pypi-mcp-httpx2-supply-chain
description: "PyPI's mcp 2.0.0 depends on httpx2, a typosquat impersonating httpx's real author and org — pin mcp==1.29.0"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 354194c4-0718-4137-b4b9-524e1ee1af6d
  modified: 2026-08-11T11:28:37.189Z
---

On 2026-08-11, installing the MCP Python SDK the documented way — `pip install "mcp[cli]"`, no version pin — pulled `mcp 2.0.0`, whose dependency list replaces the real `httpx` with **`httpx2`**.

`httpx2`'s PyPI metadata impersonates httpx convincingly: `Author: Tom Christie` (httpx's real author) and `Home-page: github.com/pydantic/httpx2`. httpx's actual home is `github.com/encode/httpx` — the **encode** org, not pydantic. `mcp 2.0.0`'s own metadata still carries the genuine `modelcontextprotocol.io` homepage.

Verified this is not a local problem: `pip config list` empty, no `PIP_INDEX_URL`/`PIP_EXTRA_INDEX_URL`, no `pip.conf` anywhere, no `/etc/hosts` override. It resolves from public PyPI.

Version history jumps `…1.28.1, 1.29.0` straight to `2.0.0`. A read-only `pip install --dry-run --report` against `mcp[cli]==1.29.0` resolves the normal `httpx<1.0.0,>=0.27.1` plus `httpcore`, `httpx-sse`, `pydantic-settings`, `certifi` — all normal versions, no `httpx2`.

**How to apply**: always `pip install "mcp==1.29.0"` (verified clean and used by `~/.local/share/mcp-servers/venv`). Never install `mcp[cli]` unpinned. If a future task needs a newer MCP SDK, re-check the dependency list before installing, and prefer `pip install --dry-run --report` to inspect without executing package code.

Also: the `MCPServer` class name that circulates in some MCP docs does not exist. The real high-level API in 1.29.0 is `from mcp.server.fastmcp import FastMCP`. Verified by importing against the installed package, not by reading docs — a prior agent's proposal used `MCPServer` and would have failed with ImportError.

Related: [[api-keys-leak-via-argv]] (the other "verify against the real thing, not the doc" lesson).
