---
name: deepseek-cli-for-grunt-work
description: deepseek-cli offloads bulk mechanical subtasks; default is deepseek-v4-flash at reasoning_effort=max. It extracts reliably but cannot judge whether output compiles — verify with a real tool
metadata:
  node_type: memory
  type: reference
  originSessionId: 38aedace-4e5c-468c-9fcc-9ca422ec2ec4
  modified: 2026-08-10T06:05:06.259Z
---

`deepseek-cli` is at `~/.local/bin/deepseek-cli` (on PATH), callable via Bash. Wraps DeepSeek's OpenAI-compatible chat-completions API.

- Key at `~/.config/deepseek/api_key` (mode 600), or `$DEEPSEEK_API_KEY`. Never print it or put the raw key in a command string.
- `deepseek-cli "prompt"`, `echo … | deepseek-cli`, `deepseek-cli -f input.txt`, `-m <model>`, `-e <effort>`.
- **`/models` serves exactly `deepseek-v4-flash` and `deepseek-v4-pro`.** Adam's instruction (2026-08-07): use **v4 flash at max effort**, which is now the default. `deepseek-chat` also answers (alias) but naming the model says which one you got.
- The API accepts `reasoning_effort` (`minimal`…`max`). The shipped wrapper had no way to send it, so "flash (max)" was unreachable — I added `-e/--effort`, default `max`, `-e none` to omit the field.
- System-wide tool, usable from any project. Claude Code's Agent tool is Claude-only, so DeepSeek is reachable *only* through Bash, never as a `subagent_type`.

**Why:** Adam asked to route grunt work (粗活) to a non-Claude model to save Claude quota, choosing a plain script over an MCP server since MCP adds overhead without reducing API cost.

**How to apply — measured on a real task** (converting 40 prose mutation records into literal string edits):

- **Reliable at mechanical extraction.** 32/40 produced correct, *unique* substrings; **0 hallucinated**; and it declared **8 `IMPOSSIBLE`** rather than inventing answers. Explicitly offering "output IMPOSSIBLE and say why — an honest refusal is far more useful than a guess" is what produced that, so always give it that escape hatch.
- **Not reliable on anything a tool can check.** 1 of 3 sampled outputs was a valid substring that *did not compile* (unqualified `make_unique`), despite the prompt requiring valid C++. So: **DeepSeek extracts, the compiler/test adjudicates.** Never accept its word on compilability, correctness, or whether a test fails.
- Give it a strict machine-parseable output format (`@@@ n` / `OLD:` / `NEW:`) and validate every field programmatically. Cheap validation first (string match), expensive validation (build + run) on everything you intend to rely on.

Good fits: bulk text transforms, log summarisation, boilerplate, mechanical reformatting — where volume is high and verification is cheap. Bad fits: anything where being subtly wrong is invisible. Related: [[mutation-gate-for-tests]] — same principle, the artifact is only trusted once something mechanical has confirmed it.

## Its mistakes are almost always my prompt (2026-08-10)

**It has zero project visibility.** No filesystem, no tools, no browsing — it sees exactly the bytes
in the prompt file and nothing else. So every "it got X wrong" should first be checked against
"did I give it X". On three calls that day, every error traced back:

| What it got wrong | What I had omitted |
|---|---|
| `sflow::FlowKey.srcIp` (real name `srcIP`); 40 lines of SFINAE probing for a `.nodes`/`.dpids` member | `SFlowType.hpp` — it never saw `FlowKey` or `Path` (`typedef vector<pair<uint64_t,uint32_t>>`) |
| `EdgeProperties.leftIn` / `leftOut` / `interfaceSpeed`, none of which exist | I pasted a **slice** of `GraphTypes.hpp`, not the struct |
| Proxy endpoints on port 8080 (×7); the proxy is 8081 and nothing listens on 8080 in P4 mode | I gave counts but never the ports — and the style model I handed it was the **OVS** runbook, where 8080 is right |
| `len(json.load(...))` on `/ryu_server/all_destination_paths`, which returns a dict → prints 2, not 12 | I never gave the reply shapes |
| "watch `addressed=` climb in kernel.log" | **The model document I gave it says that**, and it is stale — that line is INFO on the first pass only |
| Searching for a bridge edge in a meshed fabric | I never said the topology has no bridge |

**How to apply:** before sending, grep your own task for every type, endpoint and field name the
output must mention, and paste those definitions — whole, not sliced. Give **shapes**, not just
counts ("32 links" → "a bare list of 32; the paths endpoint returns a dict keyed
`all_destination_paths`"). And treat any document you hand it as a style model as *training data
for the output*: if it is stale, say which parts, or it will faithfully reproduce the staleness.

**What it does well, and is worth preserving in the prompt:** demanding pre-conditions made its own
bad premise fail loudly instead of passing vacuously; demanding `SPEC-UNKNOWN` over guessing got two
honest flags; and following a header's declared parameter names surfaced a real production naming
lie (`getLinkBandwidthBetweenSwitches(dpid1, dpid2)` whose body parsed IPs). See
[[test-independence-is-the-spec-not-the-model]].
