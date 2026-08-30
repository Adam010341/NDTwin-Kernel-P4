# T-3 — User Manual, first installment (OVS operate flow)

**2026-08-30 03:14–03:17.** From the `post-s6-t2` snapshot: a machine built by following the
Installation Manual. Harness `vm/guest_t3_usermanual_ovs.sh`, committed before it ran.
Raw: `raw/t3/` on `audit-raw`.

Page: *User Manual → NDTwin Kernel → Operate an Emulated (Software) Network → Native-Linux*.
T-2 covered this page's **optional P4 section**; this covers **Terminals 1–3**, its main body,
which had never been run.

## Scope correction

The ticket said "User Manual 12 md, Developer Manual 9 md". Of those, **5 and 3 respectively are
`_index.md` section stubs** with no procedure in them. The real surface is **7 + 6 = 13 pages**.

---

# A. EXECUTED — run on a live machine

| check | result |
| :--- | :--- |
| pre-flight ×3 (source in `~/Desktop`, kernel built, `testbed_topo.py`) | ✅ all present |
| **Ryu holds `:6633` before the topology starts** | ✅ pid 1317, `ryu-env` python |
| `:6653` (the port the page warns Mininet falls back to) | ✅ **nobody** — no ambiguity to fall into |
| `"all-destination paths installed"` appears | ✅ but at **~80 s**, see M-5 |
| Mininet reaches its CLI | ✅ |
| **Terminal 3 as printed** | 🔴 **blocks on an undocumented prompt — M-4** |

## 🔴 M-4 — Terminal 3 asks three questions the page never mentions

The page prints this and then a screenshot, with no indication the command is interactive:

```bash
cd ~/Desktop/NDTwin-Kernel/build
export OPENAI_API_KEY="any-random-string-here"
sudo -E bin/ndtwin_kernel --loglevel info
```

What a reader actually gets, verbatim:

```
Select your deployment environment:
  [1] Local Mininet (simulated testbed)
  [2] Remote Testbed (physical or virtual deployment)
Enter environment choice (1-2):

Select your Mininet Topology:
  [1] OVS Environment (128 Hosts)
  [2] P4 / BMv2 Environment (4 Hosts)
Enter topology choice (1-2):

Do you want to enable Intent Translator (requires OpenAI Token)?
  [1] Yes (Enable AI features)
  [2] No  (Disable AI features)
Enter choice (1-2):
```

For this page's flow the answers are **1, 1, 2**. The page supplies none of them, and nothing
on it says a question is coming. The kernel then proceeds correctly — `Topology file:
../setting/StaticNetworkTopologyMininet_10Switches.json`, `Server Listening on port 8000` — so
this is purely a documentation gap, not a defect in the program.

Two things make it worse than a missing sentence:

* **The page's own text implies a non-interactive run.** It tells you to
  `export OPENAI_API_KEY="any-random-string-here"` because that will "bypass the check", which
  reads as *set this and it will not ask you about AI*. In fact **a prompt decides**, and
  answering `[2]` yields `IntentTranslator is disabled by user.` The export line is not what
  disables AI on this path.
* **The sibling page does it differently.** The Installation Manual's P4 section passes
  everything explicitly (`--mode mininet --topology … --no-ai`) *and* documents the prompting
  behaviour. The OVS page, which is the one most readers reach first, does neither.

**Fix:** either add the three answers to the page, or print the flag form
(`--mode mininet --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --no-ai`)
as the P4 page already does.

## ⚠️ M-5 (minor) — "wait ~60 seconds" was measured at ~80

The page says wait **~60 s** for `"all-destination paths installed"`, then warns that starting
NDTwin earlier makes it query Ryu before the topology is detected. Measured: the message
appeared **~80 s** after the topology started (sampled every 5 s; first hit at the 16th sample).

One machine, one run, 4 vCPU, so this is not a claim that 60 is wrong in general — but a reader
who takes 60 as an instruction rather than an estimate will act into the window the page itself
warns about. "Wait for the message" is the safe wording and the page already has it; the number
is what invites the mistake.

## ⚠️ Observation — the topology menu and Installation §6.5 disagree on P4 host count

The kernel's own menu offers `[2] P4 / BMv2 Environment (4 Hosts)`, while Installation §6.5
presents **128 hosts** as the P4 example and 4 as the smaller alternative. Not chased further;
recorded because the two are read minutes apart by the same person.

---

# B. READ, NOT EXECUTED

Strength is strictly lower than section A. Nothing here has been run.

| page | why not executed |
| :--- | :--- |
| `Operate a Physical (Hardware) Network.md` | needs real switch hardware |
| `NDTwin Tools/WebGUI` (274 lines, **0** bash blocks) | GUI-only; nothing headless to execute |
| `NDTwin Tools/TrafficVisualizer` (403 lines, **0** bash blocks) | GUI-only |
| `NDTwin Tools/NetworkTrafficGenerator(NTG)` (8 bash blocks) | NTG is not installed in this VM |
| `NDTwin Tools/Network State Recoder` (6 bash blocks) | **executable — not yet run**, next in line |
| `NDTwin Tools/Simulation Platform` (1 bash block) | not yet run |
| Developer Manual, all 6 content pages | **not started**, incl. `NDTwin Kernel API.md` |

🔴 The Developer Manual's `NDTwin Kernel API.md` — flagged as highest-risk, with three defect
shapes to check against — **has not been opened.** The three shapes remain the auditor's notes,
not observations of mine, and are not repeated here as if they were.

---

## Harness notes

No new harness defects this run. The three guards added after T-2 all did their job:
liveness via `/proc` rather than `kill -0`; ports resolved to the **pid** holding them via `ss`
rather than "something answered"; and the kernel run under a **pty**, which is the only reason
M-4 was visible at all — headless it would have exited with a usage message and I would have
recorded "needs flags" instead of "asks the reader three undocumented questions".

[Co-developed with claude code -- Adam]
