---
name: code-attribution-mark
description: "Mark AI-generated or AI-assisted code in this project with the line `[Co-developed with claude code -- Adam]`"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: c4cd7671-eebc-4b70-9d68-a07476ac03ae
  modified: 2026-07-29T12:07:49.065Z
---

Code I write or substantially modify in NDTwin-Kernel carries the marker line:

```
[Co-developed with claude code -- Adam]
```

Placed as a comment near the change — at the top of a new file, or on the specific function/block in an existing one. Commit messages do not need it; the code does.

**Why:** the user needs to be able to tell which parts of the codebase were AI-assisted, and this repository already had a precedent before I arrived — several P4 files carry `// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.` Keep those existing lines intact and add ours alongside rather than replacing them, so the provenance of each contribution stays distinguishable.

**How to apply:** add it to new files and to non-trivial edits of existing ones. Use the comment syntax of the language (`//` in C++, `#` in Python and shell, HTML comments or plain text in Markdown). For a doc or a test whose *reasoning* is the AI contribution, putting it in the file header is enough. Don't sprinkle it on every line — once per file, or once per substantial function, is the convention in the repo now.
