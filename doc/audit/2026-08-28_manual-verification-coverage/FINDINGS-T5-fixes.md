# T-5 — the three documentation fixes, verified before and after

**2026-08-30 03:41–03:52.** Harness `vm/guest_t5_verify_fixes.sh`, committed before it ran.
Website commit `cd684ba` on `docs/p4-bmv2-environment`, **not pushed**.

Acceptance was "re-run the reader flow, not read the diff", with the question applied to each
fix: *if this change had no effect, would this step go red?*

## M-4 — flag form on the OVS path ✅

The evidence for the flag form came from the **P4** page. Same binary, different arguments,
different topology model, so it was tested here rather than assumed. Run **headless on purpose**:
a kernel that still wanted to prompt exits with a usage message when stdin is not a terminal,
so the run succeeding *is* the proof, rather than me reading output and asserting it.

| | |
| :--- | :--- |
| prompt / usage lines | **0** |
| topology loaded | `StaticNetworkTopologyMininet_10Switches.json` — the one the flag names |
| `--no-ai` | `IntentTranslator is disabled by user.` |
| `GET /ndt/get_graph_data` | **HTTP 200**, twin **nodes=138 edges=288** (the documented OVS figure) |

🔑 **Then I caught myself documenting an untested variant.** I verified
`sudo -E ./bin/ndtwin_kernel …` with an `export`, and wrote
`sudo bin/ndtwin_kernel …` — no `-E`, no `./`, no export — into the page. Three differences.
The exact block as printed was re-run: **0 prompts, HTTP 200, nodes=138 edges=288.** It holds,
but it held by luck, not because I had tested it.

## M-3 — `ECONNREFUSED` → `Connection refused` ✅ (both sides)

Two-sided on purpose: the old wording's entire failure mode was matching nothing, and a string
that never matches passes the healthy case perfectly.

| against | `ECONNREFUSED` | `Connection refused` |
| :--- | ---: | ---: |
| **dead fabric** (no BMv2 running) | **0** | **27** |
| **live fabric** (T-2 investigation run, `proxy2.log`) | 0 | **0** |

The live-fabric row is **cited from the T-2 run, not re-derived here**, and the harness says so
in its own output.

## M-5 — "~60 seconds" → "wait for the message" ✅

Three independent measurements of `"all-destination paths installed"`: **80 s, 85 s, 80 s**.
One minute would have been short every time, on the same machine, and the page itself warns
that starting early makes NDTwin query Ryu before the topology is detected.

## Site still builds ✅

`hugo` initially exited 1 — **not my edit**: `binary with name "go" not found in PATH`, then
`node` for PostCSS. With the local toolchain the build is clean **including this commit**:

```bash
PATH="$HOME/.local/go/bin:$HOME/.local/node/bin:$PATH" hugo    # exit 0
```

## New harness defect

**H-25 — a case-insensitive grep for `usage` matched `FlowLinkUsageCollector`**, so the M-4
check reported *"still prompts or prints usage — DO NOT document it"* on a run that had neither.
Anchored patterns (`^Usage:`) give 0, which is the true answer. Same family as H-23's backwards
pattern: the grep was the observation, and it was wrong.

## Correction carried in from review

P-1's "the process keeps going" is **withdrawn** — all five workers are daemon threads and
`main.py:356` is the last statement, so the interpreter exits and takes them with it. Verified
line by line rather than accepted. The finding survives and is worse: uvicorn 0.51.0 runs
`lifespan.startup()` at `server.py:103-104` **before** binding, and that is where this proxy
connects to switches and installs rules — so a guard belongs **before `uvicorn.run()`**, and the
bind-failure path cannot help.

## Read, not executed

Website repo has **26 unpushed commits**, not the 10 quoted in the ticket (counted on
`docs/p4-bmv2-environment`; `git log --oneline HEAD --not --remotes`). `f17d2c5` is among them.
Nothing pushed.

[Co-developed with claude code -- Adam]
