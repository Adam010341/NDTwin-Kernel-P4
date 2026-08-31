---
name: deepseek-agent-tool-loop
description: "~/.local/bin/deepseek-agent gives DeepSeek read-only tools (list_dir/read_file/grep/git) plus write_report, so it browses the code itself. It cannot write files or run commands — run_command needs Adam's authorisation"
metadata: 
  node_type: memory
  type: reference
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-10T06:56:37.140Z
---

`~/.local/bin/deepseek-agent` is a tool-calling loop over DeepSeek's chat-completions API (function calling verified working, `finish_reason: tool_calls`). It exists because judging a change's magnitude, or reviewing 144 commits, from a hand-picked excerpt asks the model to evaluate what it cannot see.

## Which of the two to reach for

**If the output must state any project fact — a port, a JSON shape, a field name, a command — use
`deepseek-agent`, not `deepseek-cli`.** On 2026-08-10 I used the cli for a test-runbook and a test
file, pasting hand-picked excerpts, and every error it made was a fact it could not see: the proxy's
port wrong seven times, `len()` on an object expecting a list, pytest for a unittest suite, field
names invented because I pasted a slice of the header and not `SFlowType.hpp` at all. Adam's
correction was blunt and right — *"把 deepseek 的視野打開來，它需要有整個專案的視野，不然它會被你影響"*.
With the cli, its view is literally my file selection, so its mistakes are mine.

Use `deepseek-cli` only for transforms that carry their own input: reformatting text I supply,
summarising a log I paste, mechanical edits to a file already in the prompt.

Two frictions when running the agent, both cosmetic: it repeatedly calls `read_file` with `file:`
instead of `path:`, gets an error, and retries correctly — budget roughly double the steps you would
expect. And a large task is slow: ~60 tool calls in the first few minutes.

```
deepseek-agent -f task.md --report doc/audit/foo.md --max-steps 140 --budget 3000000 \
               -m deepseek-v4-pro -e max --transcript /tmp/t.json
```

**Tools**: `list_dir`, `read_file` (line-numbered, paged, ≤600 lines), `grep`, `git` (read-only subcommands only), `write_report`. Read roots are the eight project repos; paths containing `.env`, `api_key`, `secret`, `credential`, `id_rsa`, `.pem`, `.netrc` are **refused** — `Web-GUI/.env` holds database credentials and browsing a repo freely while shipping contents to a third-party API would be a leak, not a review. `node_modules`, `.git`, `build`, `venv` excluded as noise.

**Findings go to the report file, not the response.** That is what removes the length ceiling, and the model is told to write incrementally so an interrupted run loses nothing. Reports of 20–50 KB across 5–10 `write_report` calls are normal.

**`run_command` was authorised by Adam on 2026-08-10 and is built — behind `--allow-run`, off by default.** Four conditions, all enforced: no shell (`shell=False`, so `;` `|` `$(…)` are inert filenames — verified, `ls ; rm -rf src` just makes `ls` complain about a missing file named `;`); an allowlist keyed on argv[0]'s basename with a per-program rule; `DENY_SUBSTRINGS` scanned across the whole argv, so `cat ~/.config/deepseek/api_key` is refused for the same reason reading that path is; and cwd inside the repos. `sudo` and `mnexec` are refused in **any** position — the allowlist alone is not a boundary while NOPASSWD `mnexec` runs arbitrary programs as root. `stack.sh` is limited to `status|wait|logs` so it cannot take away Adam's live stack, `curl` to localhost only (`-o /dev/null` excepted), `python` only as `-m unittest|pytest`, `git` reusing `GIT_ALLOWED`. Output is scanned for the API key before returning, because `ps`/`pgrep -a` print other processes' argv.

33 adversarial cases in `test_run_command.py` (scratchpad); re-run it after touching the rules. First real use: 57 calls, 1 refusal, and the report cited live `curl` evidence for claims it would otherwise have guessed at.

**It still cannot write source files.** So:

- **Writing code**: it emits complete files in the report; I apply, build, and run the mutation gate. This keeps the adjudication step, which caught a real error in every single delegation.
- **Integration testing**: manual mode — it writes a runbook of exact commands, I execute and feed the raw output back. Worked well; its "what I need reported first" section asked for exactly the four values it could not know. Prefer this to autonomy while the live stack matters, because **restarting Ryu alone wedges it permanently** ([[ryu-flow-stats-wedge]]).

- **Integration testing is now cheaper**: with `--allow-run` it checks its own claims (`curl` the live kernel on `:8000` and proxy on `:8081`, `jq` field applied in-process since there are no pipes). Still prefer manual mode for anything that *changes* live state — **restarting Ryu alone wedges it permanently** ([[ryu-flow-stats-wedge]]).

Stateless, which is a feature: every answer is reproducible from the saved prompt. But every round resends the whole corpus, so if a second round is needed, resend everything — **sending a summary instead is the failure mode from [[change-magnitude-send-the-diff]]**. Related: [[deepseek-cli-for-grunt-work]], [[deepseek-large-prompt-fix]], [[api-keys-leak-via-argv]].
