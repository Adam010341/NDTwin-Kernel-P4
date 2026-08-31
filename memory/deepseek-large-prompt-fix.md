---
name: deepseek-large-prompt-fix
description: "deepseek-cli now handles large prompts (300KB+ diffs): jq reads via --rawfile and curl via --data-binary @file. Before the fix it died locally with 'Argument list too long', which reads like an API error"
metadata:
  node_type: reference
  type: reference
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-08-08T13:07:50.245Z
---

`~/.local/bin/deepseek-cli` originally built its request with `jq -n --arg content "$CONTENT"` and posted it with `curl -d "$BODY"`. Both pass the whole prompt as an argv entry, so anything past `ARG_MAX` fails with:

```
/usr/bin/jq: Argument list too long
```

That is a **local** failure — nothing reaches the API — but the one-line output looks exactly like a rejected request, so it is easy to misread as a token limit or a model refusal. Hit it with a 321 KB prompt (a 7237-line diff).

Fixed: the prompt is written to a temp file and read with `jq --rawfile content <file>`, the assembled body goes to another temp file, and curl sends it with `--data-binary @<file>`. Both temp files are removed by an `EXIT` trap. Small prompts still work; verified after the change.

**How to apply:** sending a large diff to DeepSeek for review is now viable, and it is worth doing — asking it to judge a change's *magnitude* from a hand-written summary rather than the diff is asking it to evaluate something it cannot see, which is the mistake that prompted this. For that kind of judgement task use `-m deepseek-v4-pro -e max` rather than the flash default. Related: [[deepseek-cli-for-grunt-work]] for the general division of labour — the model extracts or assesses, the toolchain adjudicates.
