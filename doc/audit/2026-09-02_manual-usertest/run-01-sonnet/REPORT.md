# run-01 (sonnet) — tester's final report, verbatim

Received 2026-09-02 18:44 CST from the tester subagent (model: sonnet). Nothing below was edited by the
orchestrator; the orchestrator's own re-verification is in `VERIFICATION.md` and disagrees with this
report in two places (BUG-010's log claim; "stacks still live").

---

## Final Report — NDTwin Installation & Use-and-Break, run-01

### 1. Did you get NDTwin installed and running?

**Yes** — on the Native-Linux (Open vSwitch) path, the optional P4/BMv2 path, and all five separately-documented Tools (Web GUI, Network Traffic Generator, Network State Recorder, Network Traffic Visualizer, Simulation Platform Manager + Energy-Saving-App).

Strongest evidence — an end-to-end, independently-verified effect, not a success message: starting `Energy-Saving-App` autonomously ran a real simulation decision and powered off switch `s9` through the kernel's own API (`POST /ndt/set_switches_power_state?ip=192.168.123.19&action=off` → `200, {"192.168.123.19":"Success"}`), and a **separate** query afterward confirmed it actually happened:
```
$ curl http://localhost:8000/ndt/get_graph_data | ...
s9  is_up: false      (all other switches s1-s8, s10: is_up: true)
```
Also verified, each with its own independent check rather than a log's word for it: 128-host/10-switch OVS fabric converged (`Pulled 16256 paths from controller` = 128×127); the same fabric rebuilt on real BMv2 P4 switches (`Data plane: bmv2 (10 switch(es))`, all 10 in the switch manifest with real PIDs); real iperf3 traffic detected via the flow API on both data planes; NTG generating and the kernel independently corroborating 189 concurrent flows; NSR writing and rotating real `flowinfo`/`graphinfo` JSON+zip files; the Web GUI rendering the live topology (confirmed by eye before I lost browser access, and by `curl` after); the Traffic Visualizer rendering the documented Fat-Tree layout (confirmed via an `xwd` screenshot of its virtual framebuffer). The VM is left running with the Web GUI stack and Simulation Platform stack still live as of this report.

### 2. Friction points, in order

| Section | Friction | What happened (verbatim evidence) | What the manual would have needed to say |
|---|---|---|---|
| Front matter/navigation | 0 | Root index pages are empty frontmatter; had to open the Demo-VM page to rule it out before choosing the native-Linux path | "If you already have a bare Ubuntu machine rather than downloading a VM image, use this page instead" |
| §2 Python/Ryu env | 1 | `conda init bash` → new SSH session → `conda: command not found`; the "Or: source .../conda.sh" alternative worked immediately | Nothing wrong for a real desktop terminal — my own SSH-driving artifact |
| Use phase, OVS (Kernel User Manual) | 3 | `ndt up ovs` → `sudo: /usr/local/sbin/ndtwin-lab: command not found` (BUG-003); fixed, retried → `fabric has 0 hosts, expected 128` (BUG-004); moved to the manual 3-terminal path, which worked first try | The one setup step given (`ln -sf ... ndt`) needs a second one for `ndtwin-lab`; `ndt up ovs` needs to actually work |
| Discovering `ndt apps` | 2 | `ndt --help`, run out of curiosity, revealed `apps`, `--deep`, `--check`, `clean`, `ntg`, `release` — none in either manual; `ndt apps sim`/`energy` printed `ok ... started` while starting nothing (BUG-005) | Document `ndt --help`'s actual surface; fix the false positive |
| NSR | 2 | Launcher script is a bare `python3` with no fixed interpreter path to "check" as the manual says; shipped `stop_...sh` uses the exact `kill $(pgrep -f ...)` pattern the manual (2 sections earlier) says not to use — caught 2 PIDs, cut my own SSH command short (BUG-006) | Fix the stop script to match the manual's own advice |
| NTG | 3 | Documented launch command names a conda path that doesn't exist (BUG-007); fixed path still failed — venv can't see the system `mininet` package (BUG-008) | Match the User Manual's example path to what the Installation Manual actually builds; note the `--system-site-packages` requirement |
| Web GUI | 3 | `./web_gui_deploy.sh` → Docker build fails outright, `ERR_PNPM_IGNORED_BUILDS` (BUG-009, unpinned `pnpm`); fixed by pinning `pnpm@9` in the Dockerfile | Pin the pnpm version in the Dockerfile |
| P4/BMv2 | 0 | Every documented command worked first try with numbers matching the manual's own predictions exactly | — |
| Traffic Visualizer | 1 | JDK 21 required but no install command given anywhere on the page; headless-display failure matched the manual's own Troubleshooting entry exactly, and its suggested `xvfb-run` fix worked first try | Add `sudo apt install openjdk-21-jdk` |
| Simulation Platform | 0 | Every settings file the manual says to hand-edit was already correct out of the box for the same-machine demo; everything worked end-to-end untouched | — |

### 3. Per-section timings

| Section | Start | End | Duration |
|---|---|---|---|
| Front matter / navigation | 06:09 | 06:10 | 1 min |
| §1 System Requirements | 06:10 | 06:11 | 1 min |
| §2 Python/Ryu env | 06:11 | 06:20 | 9 min |
| *(driving-session crash — VM untouched)* | 06:22 | 06:36 | *14 min, excluded* |
| §3 System Dependencies | 06:36 | 06:38 | 2 min (active) |
| §4 Compile Kernel | 06:39 | 06:44 | 5 min |
| §5 Topology Script check | 06:45 | 06:45 | <1 min |
| Use phase: OVS fabric+kernel | 06:51 | 07:13 | 22 min |
| `ndt apps` discovery | 07:13 | 07:17 | 4 min |
| Tool: Network State Recorder | 07:16 | 07:23 | 7 min |
| Tool: Traffic Generator (NTG) | 07:23 | 07:30 | 7 min |
| Tool: Web GUI (through browser loss) | 07:30 | ~07:41 | ~11 min |
| *(harness watchdog stall + recovery — VM untouched, background P4 build ran unattended)* | ~07:41 | 10:03 | *~2h22m, excluded* |
| Web GUI curl closeout + `ndt status`/`check` findings | 10:03 | 10:18 | 15 min |
| P4/BMv2 setup + full test | 10:03 | 10:12 | 9 min *(overlaps above; toolchain itself built unattended 06:46→before 10:03)* |
| Tool: Traffic Visualizer | 10:13 | 10:18 | 5 min |
| Tool: Simulation Platform + Energy-Saving-App | 10:19 | 10:27 | 8 min |
| Curiosity pass (J-list, BUG-010, BUG-011, `ndt up` P4 retest) | 10:27 | 10:42 | 15 min |

**Total active work:** ~2 hours across two segments (~1h35m before the crash/stall, ~55 min after), plus the P4 toolchain compiling unattended in the background for roughly 2–3 hours in between (exact duration unknown — I could only bound it by when I started it, 06:46, and when I next checked, after 10:03, because a harness interruption on my end, not the VM, prevented me from watching it finish). **Wall-clock elapsed on the VM: ~4h35m** (`uptime` at report time), all of it either active testing or the VM legitimately working.

### 4. What was skipped, and why

- **Physical (Hardware) Network page** — no physical switch hardware attached to this VM; genuinely out of scope, not a time-budget skip.
- **VM-Linux (Demo VM) page** — superseded at the very first decision point: I have a bare machine, not a VM image to import.
- **Step 6.7 (performance BMv2 build)** — explicitly optional in the manual, about throughput not correctness; building a second full BMv2 from source would have cost real time for a claim ("is it faster") outside this exercise's "does it work" scope.
- **A14/A15 (kernel's interactive prompt / no-TTY usage message)** — no allocated TTY over my SSH-driving method; the flag-based invocation the manual's examples actually use was tested thoroughly instead.
- **Several Web GUI interactive checks** (drag-to-reposition, Bandwidth/Compare/Stacked views, Node-Position Save, NDTwin Assistant, Switch Flow Table's add/modify/delete forms, Availability Status playback) — lost Browser-tool access mid-session to a harness watchdog stall; finished the rest via `curl` where an API existed and marked the rest `NOT-TRIED ("needs a real browser")` per the coordinator's instruction, rather than guessing.
- **A real OpenAI-backed LLM request** — no budget for a real key; tested the documented placeholder-key bypass instead, which starts cleanly.
- **NTG's hardware worker-node path** — needs a second physical machine.
- A handful of low-value repeats (`ndt up` a 4th/5th time, `ndt apps stop`, foreground-mode NSR) were skipped once the underlying mechanism was already confirmed working or broken, in favor of breadth.

### 5. The moment I felt most lost

Investigating **BUG-004** (`ndt up ovs` failing with "fabric has 0 hosts, expected 128"). I had just fixed one real bug (missing `ndtwin-lab`), the fix looked right, and then a *different* failure appeared with no obvious cause. I tried the wrapper's own suggested diagnostic (`ndtwin-lab status`, `topo-out`), found a tmux session that had already died, then found a live `ndtwin_kernel` process bound to port 8000 that I hadn't started myself — and couldn't pin down which of several recent commands had produced it. I eventually diagnosed it by falling back to the manual's own literal, low-level commands (driving `testbed_topo.py` myself in a plain `tmux` session) and watching them succeed cleanly — which told me the underlying pieces all worked and the wrapper itself was the problem, but I never got full certainty on the *exact* mechanism inside `ndt up`/`ndtwin-lab`, since chasing that further would have meant reading source code, which was off-limits. What I was looking for at that moment was simply: *is this fabric-building mechanism broken, or is it just me?* — and the manual gave no way to tell short of falling back to the raw commands myself.

### 6. Bug table and coverage table

**11 bugs filed**, full verbatim detail (repro steps, exact output, severity reasoning) in `~/BUGS.md` on the VM (582 lines). Condensed:

| ID | Feature | Summary | Severity |
|---|---|---|---|
| BUG-001 | Installation §2.6, `is_mininet` | Editing the documented knob does nothing — a second, later assignment always overrides it (confirmed via two matching in-code comments) | Medium |
| BUG-002 | Installation §2.6, `switch_num` | The instructed "set switch_num = 10" line no longer exists in the file; value is now auto-derived | Low |
| BUG-003 | `ndt up ovs` | Fails outright on a fresh clone: companion script `ndtwin-lab` never installed by either manual | High |
| BUG-004 | `ndt up` (OVS and P4) | Fabric never came up in 3/3 post-fix attempts across both data planes; manual's own raw multi-terminal commands worked every time | High |
| BUG-005 | `ndt apps sim`/`energy` | Prints "ok ... started" with exit 0 while starting nothing at all — reproduced twice | High |
| BUG-006 | NSR `stop_network_state_recorder.sh` | Shipped script uses the exact unsafe `kill $(pgrep -f ...)` pattern the manual warns against two sections earlier; caught an extra PID on the one run | Medium-High |
| BUG-007 | NTG launch command | Documented command names a conda path that doesn't exist; Installation Manual builds a venv instead, in two places | Medium-High |
| BUG-008 | NTG's own venv | Plain venv can't import the system-installed `mininet` package NTG's bundled topology needs | High |
| BUG-009 | Web GUI Dockerfile | Unpinned `pnpm` breaks the build outright (`ERR_PNPM_IGNORED_BUILDS`) | High |
| BUG-010 | Kernel shutdown | A kernel that logs a complete, documented-as-normal shutdown can still be alive and serving 14+ minutes later | High |
| BUG-011 | `/ndt/get_cpu_utilization` | Fabricated constant (`10 + hash(ip) % 50`) in Mininet mode, displayed in the Web GUI as if real; disclosed only in an undocumented CLI tool's diagnostic, not either manual | High (trust issue) |

**Coverage: 107 checklist lines** across 10 sections (A–J), full detail in `~/CHECKLIST.md` on the VM: **69 WORKS/WORKS-BUT-passing, 4 BROKEN, 1 deliberately SKIPPED, ~33 NOT-TRIED** (each with a stated reason — hardware, display, time, or budget, never silent). Every WORKS verdict rests on an independently-checked effect, not an exit code or log line, per the task's own "success message is not evidence" instruction.

**Files on the VM** (all pushed and byte-identical to my working copies, verified by checksum): `~/JOURNAL.md` (498 lines, per-section narrative + SUMMARY), `~/BUGS.md` (582 lines), `~/CHECKLIST.md` (134 lines), `~/logs/*` (every long-running command's raw output). VM left running, not shut down, per instructions.
