---
name: api-keys-leak-via-argv
description: "I exposed Adam's DeepSeek API key by running `ps` to check on a curl call — argv is world-readable. deepseek-cli now passes the key via curl --config; never inspect a running curl with ps"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-08T14:23:29.321Z
---

I ran `ps -o pid,etime,cmd -C curl` to see whether a long DeepSeek call was still running. `deepseek-cli` passed the key as `-H "Authorization: Bearer $API_KEY"`, so **the full key appeared in my output and therefore in the session transcript.** Adam had to rotate it.

**Why:** argv is world-readable via `/proc/<pid>/cmdline` — any user on the box can read it for as long as the process runs, and a max-effort call on a 164 KB prompt runs for minutes. The standing instruction was "never print the key or put the raw key in a command string"; I obeyed the letter (I never typed it) and broke it anyway, because a *command that prints other commands* is a way of printing it.

**How to apply:**
- To check on a running command, use `pgrep -c curl`, the output file's size (`wc -c`), or the background task's own status. **Never `ps` with a command-line column** on a process that carries a secret.
- `~/.local/bin/deepseek-cli` now writes `url` and both `header` lines into a `mktemp` file (0600, removed by the EXIT trap) and calls `curl --config "$CURL_CONFIG"`. Verified: `Bearer` appears 0 times in `/proc/<pid>/cmdline`. Any new tool that talks to an authenticated API should do the same — `--config`, `--netrc`, or an env var read inside the process, never `-H` on the command line.
- Generalise past curl: the same exposure applies to any CLI taking a token as a flag (`--token`, `-p password`, `?api_key=` in a URL argument).

Related: [[deepseek-large-prompt-fix]] and [[deepseek-cli-for-grunt-work]] for the wrapper's other behaviour, [[destructive-shell-traps]] for the other family of shell mistakes on this box.
