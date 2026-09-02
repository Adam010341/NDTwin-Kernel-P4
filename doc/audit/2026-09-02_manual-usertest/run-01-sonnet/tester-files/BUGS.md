# NDTwin bugs / discrepancies log — run-01

## BUG-001: `is_mininet` knob in Step 2.6 is dead — a second, later assignment always wins
- **Feature:** Installation Manual Step 2.6, "Configure deployment parameters"
  (Native-Linux Execution Environment)
- **Manual page/section:** `NDTwin Installation Manual / NDTwin Kernel / Operate an
  Emulated (Software) Network / Install All Required Components on a Linux Server`,
  Step 2.6, item (2) "Deployment mode": `is_mininet: set true for Mininet, false for
  physical testbed.`
- **Exact steps:**
  1. `cd ~/Desktop/NDTwin-Kernel` (after cloning per Step 4.1)
  2. Open `intelligent_router.py`, find the module-level `is_mininet = True` near the top
     (the one the manual's example block shows you how to set).
- **Expected (quoting the manual):** "`is_mininet`: set `true` for Mininet, `false` for
  physical testbed." — presented as a plain configuration value with real effect on
  which mode the controller runs in.
- **Observed (verbatim, from the file itself, reached by following the manual's own
  instruction to open and edit this line):**
  - Immediately above the line the manual points at:
    `# ⚠️ EDITING THIS LINE DOES NOTHING. is_mininet is unconditionally reassigned to
    True further down in this same module-level block (search for the second is_mininet
    = True), so whatever you set here is overwritten before anything reads it. It reads
    as configuration and behaves as a constant.`
  - A second assignment, plain `is_mininet = True`, exists ~545 lines later, with its own
    comment: `# THIS is the assignment that wins -- it silently overrides the documented
    "(2) Deployment mode" knob above.`
  - What the dead knob would have controlled (per the same comment block): a single
    `if is_mininet: hub.sleep(60)` settle delay at the end of `load_static_topology`
    before the initial route walk.
- **Did it reproduce a second time?** Not applicable in the reproduce-twice sense — this
  isn't a flaky failure, it's a static fact about the file (two assignments, second wins,
  confirmed by reading both). I did **not** execute the physical-testbed path (`is_mininet
  = False`) myself to watch the 60s delay happen anyway — I'm on the Mininet path, where
  the dead override (`True`) happens to match what I wanted, so I have no user-visible
  symptom to show. This finding is read-not-executed: I saw it while performing the exact
  edit Step 2.6 tells every reader to make, not by going looking for it.
- **Severity (my guess):** Medium. Harmless for the Mininet path this manual builds
  (override and documented default agree), but a real trap for anyone following the
  Physical Network manual page, who would set `is_mininet = False` expecting to skip a
  60s startup delay and silently not get that. The manual never mentions the knob is
  overridden, and nothing at runtime flags that the value you set was ignored.

## BUG-002: Step 2.6's `switch_num = 10` instruction has no matching line to edit
- **Feature:** Installation Manual Step 2.6, item (3) "Number of switches"
- **Manual page/section:** same page as BUG-001, Step 2.6 item (3): `switch_num: the
  controller waits until this many switches are connected... switch_num = 10  # 10, to
  match testbed_topo.py`
- **Exact steps:** `grep -n "switch_num\s*=" intelligent_router.py` after cloning.
- **Expected:** A single assignable line `switch_num = <N>` to edit, per the manual's
  code block.
- **Observed:** No such line exists. `switch_num` is computed: `NDTWIN_RYU_SWITCH_NUM` env
  var if set, else the switch count auto-parsed out of the static topology JSON's `nodes`
  list, else a fallback literal `10`. For this manual's own 10-switch topology file the
  auto-detected value is 10 either way, so there is no functional impact for the tutorial
  fabric — but a reader cannot actually carry out the literal instruction ("set switch_num
  = 10") because there is nothing with that shape left in the file.
- **Reproduced:** Yes, on first read — `grep` simply finds no such assignment (checked
  once, this is not a flaky condition).
- **Severity (my guess):** Low for this manual's own tutorial fabric (values happen to
  agree by construction). Would matter more for a reader on a custom topology who took the
  manual literally and went looking for a number to change.

## BUG-003: `ndt up ovs` fails outright on a fresh clone — companion script `ndtwin-lab` is
never installed by either manual
- **Feature:** the User Manual's "short way", `ndt up ovs` (Native-Linux Kernel, OVS path)
- **Manual page/section:** `NDTwin User Manual / NDTwin Kernel / Operate an Emulated
  (Software) Network / Native-Linux Execution Environment`, "The short way: `ndt up`" —
  the only setup step given is
  `ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt`.
- **Exact steps:** ran exactly that `ln -sf`, then `ndt up ovs` (via
  `~/.local/bin/ndt up ovs`, since `~/.local/bin` is not on `PATH` in a fresh non-interactive
  shell — a separate, minor point, see JOURNAL.md).
- **Expected (quoting the manual):** "Ryu + Open vSwitch fabric + kernel, converged and
  verified."
- **Observed (verbatim):**
  ```
  ndt up ovs
    hosts        128
    topology     setting/StaticNetworkTopologyMininet_10Switches.json
  [1/4] control plane (Ryu)
    ok  Ryu up, prompt reached
  [2/4] data plane (OVS fabric)
  sudo: /usr/local/sbin/ndtwin-lab: command not found
    XX  ovs-topo-start failed
  ```
  `tools/test_workflow/ndtwin-lab` exists in the repository — right next to `ndt` itself —
  but is not executable (`-rw-rw-r--`, `ndt` is `-rwxrwxr-x`) and is never placed anywhere
  `sudo` can find it. Neither manual mentions `ndtwin-lab` at all; the only companion setup
  step either one documents is the one `ln -sf` for `ndt`.
- **Workaround applied** (within the "reasonably findable from the manual and its links"
  allowance — really just applying the *same* pattern the manual already used for `ndt`
  itself, to a second script sitting in the same directory):
  ```
  chmod +x ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndtwin-lab
  sudo ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
  ```
  After this, `sudo ndtwin-lab --help` (or any subcommand) resolves and runs.
- **Reproduced?** Deterministic on a fresh clone — this is a missing-install-step, not a
  flaky failure. Once fixed, it stayed fixed for the rest of the session.
- **Severity:** High for a first-time reader — this is the manual's own recommended "short
  way" (presented before the manual 3-terminal path) and it cannot work at all, on a clean
  install, until you notice an unrelated file sitting next to the one the manual told you
  to symlink and apply the same fix to it yourself.

## BUG-004: `ndt up` (both the OVS and the P4 default path), even after BUG-003 is fixed,
reliably fails to bring the fabric up — but the same fabrics build fine when driven by the
manual's own raw multi-terminal commands
- **Feature:** `ndt up ovs` end-to-end orchestration
- **Manual page/section:** same as BUG-003.
- **Exact steps:** `~/.local/bin/ndt up ovs` (second attempt, after the BUG-003 workaround
  and a clean `ndt down`).
- **Expected:** fabric converges, `ndt up` reports done.
- **Observed (verbatim):**
  ```
  [1/4] control plane (Ryu)
    ok  Ryu up, prompt reached
  [2/4] data plane (OVS fabric)
    XX  fabric has 0 hosts, expected 128
  ```
  This took about 5 minutes to fail (started 06:54, failed ~06:59). Investigating by hand:
  running the *exact same* topology script the manual documents directly —
  `sudo python3 testbed_topo.py` from the project root, given a real pty (I used a plain
  `tmux` session so the Mininet CLI's `input()` loop has something other than a closed or
  redirected stdin) — built the full 128-host/10-switch fabric correctly, reached
  `--- Final Configuration Active --- / Host internet: OK | sFlow reachability: OK |
  Switch identification: OK`, and converged normally (Ryu logged
  "Static topology initialized, all-destination paths installed.", and
  `ovs-ofctl dump-flows` showed a stable non-zero count on all 10 switches — see the
  Journal for the full run). So the topology script itself is not broken; whatever `ndt up
  ovs` does differently (its own timeout, or how it feeds/redirects the Mininet CLI process
  it manages) is the more likely location of the problem.
- **A related, unexplained observation, reported with appropriate uncertainty:** shortly
  after this failure, and separately after one direct `sudo ndtwin-lab ovs-topo-start`
  call, I found a live `ndtwin_kernel` process already running and bound to port 8000 —
  matched by fresh `.test_run/pids/kernel.cmd` / `kernel.pid` bookkeeping — that I had not
  started myself via any Terminal-3-equivalent command. I could not reproduce this a third
  time from a clean `tmux`-driven run of the raw `testbed_topo.py` alone (no kernel
  appeared there), so **I cannot say with confidence which specific command starts it** —
  only that it happened twice, both times in the vicinity of `ndt up ovs` / `ndtwin-lab`
  activity, and that if a user followed the User Manual's literal "Terminal 3" step while
  something had already bound port 8000 this way, they would hit a port conflict the manual
  never anticipates (the manual presents kernel-launching as a step entirely under the
  user's own control). Flagging this for a developer to check rather than asserting a
  mechanism I did not verify from source.
- **A second, later data point that generalizes this beyond the OVS path:** after finishing
  the P4/BMv2 section (Section D — where the manual's own raw multi-terminal P4 commands
  all worked correctly, on the first try, once I had the toolchain in hand), I tried plain
  `ndt up` (the P4 default) from a fully clean state (`ndt down --deep` confirmed
  clean first). It failed the same way, with the same signature:
  ```
  ndt up p4
    hosts        128        (p4_proxy/mininet/host_count_override)
    topology     setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
  [1/3] bmv2 fabric
    waiting for 10 switches and the manifest
    XX  fabric did not come up: 0/10 switches, manifest missing
    XX  look at the pane:  sudo -n /usr/local/sbin/ndtwin-lab topo-out 40
  ```
  Following its own suggested diagnostic immediately after failure:
  `sudo ndtwin-lab topo-out 40` -> `ndtwin-lab: no topo session`, and
  `sudo ndtwin-lab status` -> `no lab sessions, bmv2: 0 mininet: 0` — the internal tmux
  session `ndt up`/`ndtwin-lab` manages had already ended, exactly as it did for the OVS
  case. Both the P4 and OVS fabrics build correctly and reproducibly when I drive
  `testbed_topo.py`/`p4_proxy/mininet/p4_testbed_topo.py` myself in a plain `tmux` session
  (Sections A and D of this checklist) — so this looks like a property of `ndt up`'s own
  orchestration (how long it waits, or how it manages the tmux session under the hood)
  rather than of either topology script or data plane.
- **Reproduced?** The "fabric doesn't come up" failure: **three times** across this
  session — `ndt up ovs` twice, plain `ndt up` (P4) once — always with the same shape
  (the wrapper's own internal topology session ends before the fabric can converge). I did
  not attempt a bare `ndtwin-lab ovs-topo-start`/`topo-start` a third time to pin down
  *why* the session ends early (that would need reading the tool's source, which I avoided
  throughout), but the failure itself is now well-replicated, not a one-off.
  The separate "mystery kernel process" observation below is a single-session detail from
  the first two attempts; not re-observed during the P4 retry.
- **Severity:** High if `ndt up` is meant to be the primary supported path — it failed
  every post-BUG-003-fix attempt I made (3 for 3, across both data planes) and never once
  brought a fabric up successfully for me. I moved to the manual multi-terminal path for
  all of my actual OVS and P4 testing after the first couple of failures, which is why the
  rest of Sections A and D's results come from the raw documented commands, not from
  `ndt up` — and every one of those manual-path attempts converged correctly on the first
  try, every time.

## WORKS-BUT: per-switch flow count is 130, not the documented 131
- **Feature:** the flow-count convergence check the manual recommends in place of watching
  for the "all-destination paths installed" log line.
- **Manual page/section:** same Native-Linux User Manual page, "How to tell it has
  finished, without watching the log."
- **Expected (quoting the manual):** "Every switch reporting the same non-trivial count,
  twice in a row, is convergence. On the 128-host fabric that number is **131 per switch**."
  (Note the manual's own prose one paragraph earlier already gives a second, different
  formula — "one forwarding rule per destination host, plus its table-miss entry," i.e.
  128 + 1 = 129 — so the manual's two own numbers for this already disagree with each
  other by 2, before my own measurement enters the picture.)
- **Observed:** `sudo ovs-ofctl dump-flows sN | grep -c actions=` for `s1`..`s10` read
  **130** on every switch, stable across two consecutive samples taken seconds apart (the
  manual's own convergence criterion, which this satisfies regardless of the exact number).
- **Reproduced?** Checked twice in the same run (both samples agreed at 130); did not
  re-run the whole fabric from scratch a second time to see if 130 is itself stable
  run-to-run, for time reasons.
- **Severity:** Low — does not block using the convergence check as directed (stability
  across two samples is what actually matters, and that held), but none of the manual's
  three numbers (129 from the prose formula, 131 from the stated fact, 130 observed) agree
  with each other, so anyone who counts on the specific figure to sanity-check their own
  fabric will be confused.

## WORKS-BUT: `ndt --help` reveals a much larger tool than either manual documents
- **Feature:** the `ndt` launcher's own interface.
- **Manual page/section:** Native-Linux User Manual, "The short way: `ndt up`" — documents
  exactly 5 commands: `ndt up ovs`, `ndt up` (P4), `ndt status`, `ndt down`, `ndt check`.
- **Exact steps:** `~/.local/bin/ndt --help`, prompted purely by curiosity after `ndt up
  ovs` failed and I wanted to see what else the tool could tell me.
- **Observed:** the tool's own `--help` documents at least 9 commands and several flags the
  manual never mentions: `ndt up [4 | p4 128 | ovs4]` and `NDT_TOPO=<file>` (numeric/variant
  forms beyond the two the manual shows); `ndt down --deep`; `ndt status --check`; a bare
  `ndt clean`; and — most notably — **`ndt apps [names]`**, described as starting
  "readers/apps" (`energy sim nsr viz te`) with an interactive picker when run with no
  arguments on a terminal, plus `ndt apps stop [names|all]`. Also `ndt ntg [cli|prompt]`
  and `ndt release` (the counterpart to the documented `ndt claim`).
- **Why this matters:** Sections E through I of this session's checklist (Web GUI, NTG,
  NSR, Traffic Visualizer, Simulation Platform) are each a multi-step manual install from a
  separate GitHub repository. If `ndt apps energy sim nsr viz te` (or similar) actually
  starts working instances of some or all of those tools, it would have saved substantial
  setup — and a first-time reader has no way to discover this exists unless they run
  `--help` on their own initiative, which nothing in either manual prompts them to do.
- **Did I test `ndt apps` itself?** No — found this too late in the session to rework the
  Tool-installation sections around it; recorded as a documentation-completeness finding
  rather than a verified-working feature. Severity is about discoverability, not
  correctness (I have no evidence any of these undocumented commands are broken — only
  that they exist and are unmentioned).
- **Severity (my guess):** Medium — nothing here is unsafe or misleading, but it is a
  substantial amount of the tool's actual surface area, including what looks like it could
  be the fastest path through half this manual, sitting entirely outside both manuals.

## BUG-005: `ndt apps sim` / `ndt apps energy` report "ok ... started" while starting
nothing at all — false-positive success
- **Feature:** `ndt apps [names]`, the undocumented subcommand found via `ndt --help`
  (see the WORKS-BUT entry above). Not covered by either manual, but directly in scope of
  this exercise's "a command printing success is not evidence it did anything" instruction.
- **Manual page/section:** none — `ndt apps` is undocumented in both manuals; discovered
  via the tool's own `--help`.
- **Exact steps:**
  ```
  ~/.local/bin/ndt apps sim    < /dev/null
  ~/.local/bin/ndt apps energy < /dev/null
  ```
  run with neither `Simulation-Platform-Manager` nor `Energy-Saving-App` cloned anywhere on
  the machine (confirmed: `ls ~/Desktop/` showed only `NDTwin-Kernel` both before and after).
- **Expected:** per the tool's own help text ("start readers/apps") and its own message
  format, `(tmux: sim)` implies a tmux session named `sim` was created and something is
  running inside it — the same pattern `ndtwin-lab ovs-topo-start` uses successfully for
  the topology (see BUG-004), where the promised tmux session genuinely exists afterward
  and can be attached to.
- **Observed (verbatim):**
  ```
  $ ~/.local/bin/ndt apps sim < /dev/null
    ok  sim started (tmux: sim)
  $ ~/.local/bin/ndt apps energy < /dev/null
    ok  energy started (tmux: energy)
  ```
  Exit code 0 both times. Immediately after, and again on a second, independent retry of
  `sim`:
  ```
  $ tmux list-sessions
  no server running on /tmp/tmux-1000/default
  $ sudo tmux -L ndtwinlab list-sessions
  no server running on /tmp/tmux-0/ndtwinlab
  $ ps aux | grep -iE "sim|energy" | grep -v grep
  (only unrelated kernel `[psimon]` threads and my own p4c build's compiler invocations —
  nothing named sim/energy, no Simulation-Platform-Manager or Energy-Saving-App binary)
  ```
  No tmux session exists under either the default socket or the `ndtwinlab`-named socket
  `ndtwin-lab`'s own topology command uses. No process. No source directory for either app
  anywhere on the machine. `viz` (Traffic Visualizer) and `te` (Traffic-Engineering-App),
  asked the same way in the same batch, behaved correctly by contrast — `viz` refused with
  `XX  viz is a JavaFX GUI and there is no display; not starting it` and `te` refused with
  `XX  TE app not found` — so the tool is clearly *capable* of detecting a missing
  prerequisite and reporting `XX`; it simply does not do so for `sim` or `energy`.
- **Reproduced?** Yes — `sim` was run twice (both times "ok started", both times nothing
  exists to show for it); `energy` once. Consistent both times.
- **Severity:** High. This is precisely the failure shape the task briefing calls out by
  name — a friendly success message that is not evidence anything happened — and it comes
  from the project's own tooling, on the undocumented command most likely to be a
  time-saving shortcut through the Simulation Platform section (Section I of this
  checklist), which is itself the most involved of the remaining Tool installs (NFS
  server/client, two extra repos, hand-edited settings headers, a kernel rebuild). Anyone
  who found `ndt apps` the way I did and trusted its "ok" would believe their simulation
  stack was running when it was not, with nothing in the output to suggest otherwise.

## BUG-006: NSR's shipped `stop_network_state_recorder.sh` uses exactly the `kill
$(pgrep -f ...)` pattern the User Manual explicitly warns against
- **Feature:** Network State Recorder, "Stopping NSR / Option 1: Using the Stop Script"
- **Manual page/section:** `NDTwin User Manual / NDTwin Tools / Network State Recorder`,
  which — two subsections earlier, under "Checking Status" and again under "Stopping NSR /
  Option 2" — explicitly warns: *"Do not pipe the search straight into `kill`. Writing
  `sudo kill -15 $(pgrep -f network_state_recorder.py)` looks shorter, but it fails in
  three ways and all three are silent... Listing first and naming one PID costs one extra
  line and removes all three."* The manual's own recommended Option 2 does exactly that —
  list with `pgrep -af`, then `sudo kill -15 <PID>` on the one confirmed PID.
- **Exact steps:** with NSR genuinely running (PID 263432, confirmed via `ps`), ran the
  manual's documented "Option 1" command: `./stop_network_state_recorder.sh`.
- **Expected:** NSR stops cleanly (this part worked — see below); nothing about *how* it
  stops should be able to affect anything else.
- **Observed:** the script itself (`cat stop_network_state_recorder.sh`) is:
  ```bash
  echo $(pgrep -f network_state_recorder.py)
  sudo kill -15 $(pgrep -f network_state_recorder.py)
  ```
  — the literal anti-pattern the manual names by name, not the safer form the manual
  itself recommends two sections earlier. Running it printed **two** PIDs, not one:
  `263432 264738` (263432 was the genuine NSR process). My SSH command then ended early
  with exit code 255 and truncated output, consistent with `264738` having been my own
  driving shell (its command line, like the manual's own troubleshooting example predicts,
  incidentally contained the text "network_state_recorder.py" — e.g. in a later `pgrep -af`
  I had chained after the stop script — and so matched `pgrep -f`'s whole-command-line
  search). A follow-up check in a fresh connection confirmed the end state was actually
  fine (NSR was stopped, `display_on_console` correctly reverted to `true`), so this
  particular run caused no lasting damage — but it is a direct, reproduced-by-accident
  demonstration of the exact multi-match failure the manual describes as "silent," using
  the project's own shipped script, contradicting the project's own written advice one
  page away.
- **Reproduced?** The two-PID match and early-exit happened on the one run I made (I did
  not intentionally repeat it, since NSR was already stopped and re-triggering it would
  need a fresh NSR instance and a differently-shaped surrounding command — time-boxed this
  rather than chasing a second reproduction).
- **Severity:** Medium-High. Functionally the stop still succeeded here, but the manual
  itself frames this exact pattern as unsafe under `sudo`, and the shipped tool ships the
  unsafe form as its primary, recommended ("Option 1") stop path while the safe form is
  buried in "Option 2: Manual Termination." A less lucky coincidental match than mine
  could `sudo kill -15` an unrelated privileged process with no indication anything but
  the recorder was signaled.

## BUG-007: NTG's documented launch command names a Python environment that does not
exist, in two places
- **Feature:** "How to use NTG in Mininet", step 3 (starting the topology with NTG's
  dependencies available)
- **Manual page/section:** appears identically in two places — `NDTwin User Manual /
  NDTwin Kernel / Native-Linux Execution Environment`'s NTG walkthrough, and the standalone
  `NDTwin User Manual / NDTwin Tools / Network Traffic Generator` page — both give:
  `sudo ~/miniconda3/envs/ntg-env/bin/python testbed_topo.py`, with the surrounding prose
  explaining *why* naming the interpreter matters (`sudo` does not carry an activated venv
  across, so the interpreter must be named explicitly).
- **Exact steps:** followed the Installation Manual's NTG page exactly:
  `python3 -m venv ~/ntg-env` (a **plain venv** in the home directory), then installed
  packages into it with `pip install ... ` after `source ~/ntg-env/bin/activate`.
- **Expected:** the User Manual's launch command should point at the interpreter the
  Installation Manual just created.
- **Observed:**
  ```
  $ ls -l ~/miniconda3/envs/ntg-env/bin/python
  ls: cannot access '/home/ndt/miniconda3/envs/ntg-env/bin/python': No such file or directory
  $ ls -l ~/ntg-env/bin/python
  lrwxrwxrwx 1 ndt ndt 7 Sep  2 07:23 /home/ndt/ntg-env/bin/python -> python3
  ```
  The path the User Manual tells you to run is a **conda environment path**
  (`~/miniconda3/envs/ntg-env/...`); the Installation Manual builds a **venv**
  (`~/ntg-env/...`) — two different tools, two different locations, same environment name
  coincidentally reused. Run literally, the documented command fails immediately with
  `sudo: ~/miniconda3/envs/ntg-env/bin/python: No such file or directory` (tilde is not
  expanded under `sudo` either, compounding it, but the path is absent regardless of that).
  This is the same *shape* of bug as Section 2.6 in the Installation Manual
  (`static_topology_file_path` defaulting to a different user's `/home/adam/...`) and the
  same shape as BUG-004's `ndt`/manual disagreement: a worked example whose concrete
  path was written against a different setup than the steps that precede it.
- **Workaround applied:** substituted the venv path the Installation Manual actually
  created, `sudo ~/ntg-env/bin/python testbed_topo.py` — same justification the manual
  itself gives (name the interpreter explicitly because `sudo` drops the active venv),
  just the correct path for what Section-by-section literal reading actually produces.
- **Reproduced?** Deterministic — the path simply does not exist after following the
  Installation Manual exactly once; not a flaky condition.
- **Severity:** Medium-High. This is the exact command the manual tells a first-time
  reader to type to bring up NTG's Mininet topology, in both places NTG is documented, and
  it cannot work as written on a machine that followed the Installation Manual's own NTG
  setup instructions.

## BUG-008: NTG's own venv can't run NTG's own bundled topology script — `mininet` is
system-installed, the venv the manual builds is isolated from it
- **Feature:** "How to use NTG in Mininet" — running NTG's bundled `testbed_topo.py` (which
  ships already wired to NTG's CLI, `command_line(net, "NTG.yaml")` in place of the plain
  Mininet `CLI(net)` — no manual edit needed there, contrary to what the "Start Up Process"
  section implies you must do).
- **Manual page/section:** NTG Installation Manual ("Required environment and libraries for
  NTG") builds the venv with plain `python3 -m venv ~/ntg-env`. The NDTwin Kernel
  Installation Manual, Section 3.2, installs `mininet` with `sudo apt install ... mininet`
  — a system (apt) package, not a pip package.
- **Exact steps:** after fixing BUG-007's wrong path, ran
  `sudo ~/ntg-env/bin/python testbed_topo.py` from `~/Desktop/Network-Traffic-Generator`.
- **Expected:** the topology builds (NTG's own script, using its own documented launch
  method, run through the interpreter the Installation Manual actually created).
- **Observed (verbatim):**
  ```
  Traceback (most recent call last):
    File "/home/ndt/Desktop/Network-Traffic-Generator/testbed_topo.py", line 4, in <module>
      from mininet.topo import Topo
  ModuleNotFoundError: No module named 'mininet'
  ```
  Confirmed the cause directly: `python3 -c "import mininet"` (system interpreter) finds it
  at `/usr/lib/python3/dist-packages/mininet/__init__.py`; `~/ntg-env/bin/python -c "import
  mininet"` cannot find it at all. `~/ntg-env/pyvenv.cfg` reads
  `include-system-site-packages = false` — the default for a plain `python3 -m venv`, and
  what the Installation Manual's command produces. Mininet, installed only into the system
  interpreter's `dist-packages` by `apt`, is invisible from inside that venv by
  construction. This isn't specific to `mininet` — no apt-installed Python package would be
  visible from this venv — but `mininet` is the one NTG's own bundled topology script
  needs, and NTG's own Installation Manual is the one that builds the incompatible venv.
- **Workaround applied** (standard, well-known venv practice, not manual-derived — flagging
  that explicitly): recreated the environment with
  `python3 -m venv --system-site-packages ~/ntg-env`, then reinstalled the same pip
  packages. `~/ntg-env/bin/python -c "import mininet, loguru"` then succeeded.
- **Reproduced?** Deterministic — plain `python3 -m venv` never includes system
  site-packages; this is not a flaky condition.
- **Severity:** High for anyone testing NTG's own bundled Mininet example the way the
  manual walks through it: the exact venv the Installation Manual tells you to build cannot
  run the exact topology script the manual tells you to run it with, for a reason neither
  manual mentions, and the fix is outside-the-manual Python packaging knowledge rather than
  anything discoverable from these docs or their linked pages.

## BUG-009: Web GUI's own Dockerfile fails to build out of the box — unpinned `pnpm`
picked up a version that refuses the build by default
- **Feature:** Web GUI Installation Manual, Step 3 "Execute Deployment Script"
  (`./web_gui_deploy.sh`)
- **Manual page/section:** `NDTwin Installation Manual / NDTwin Tool / Web GUI`
- **Exact steps:** followed the page exactly — Docker install, `git clone
  .../Web-GUI.git`, `.env` from `.env.example` with `NDT_API_BASE_URL` pointed at the
  local kernel, `chmod +x web_gui_deploy.sh`, `./web_gui_deploy.sh`.
- **Expected:** "Frontend: http://localhost:3000" comes up.
- **Observed (verbatim):**
  ```
  #16 4.576 Error: ERR_PNPM_IGNORED_BUILDS
  #16 4.579   × installing dependencies
  #16 4.579   ╰─▶ Ignored build scripts: esbuild@0.25.5
  #16 4.579   help: Run "pnpm approve-builds" to pick which dependencies should be allowed
  ...
  target frontend: failed to solve: process "/bin/sh -c pnpm install --frozen-lockfile"
  did not complete successfully: exit code: 1
  Failed to start containers.
  ```
  Root cause, visible directly in the Dockerfile: `RUN npm install -g pnpm` installs
  whatever the *latest* pnpm is at build time — unpinned. Recent pnpm major versions
  refuse, by default and non-interactively, to run a dependency's install scripts
  (`esbuild` here) unless the project has explicitly approved them, and this repository's
  `package.json`/`pnpm-lock.yaml` predates that default. The Dockerfile pins Node
  (`node:18-alpine`) but not pnpm, so the same Dockerfile that presumably worked when it
  was written now fails on a fresh `docker build` the day pnpm's own default changed —
  the same *shape* of problem the P4 toolchain section warns about for unpinned
  `behavioral-model`/`p4c` clones, just here in an npm-ecosystem Dockerfile instead.
- **Workaround applied:** pinned the Dockerfile to an older pnpm major that predates the
  stricter default: `RUN npm install -g pnpm` -> `RUN npm install -g pnpm@9`. Rebuilt;
  all three containers (`ndt-postgres`, `ndt-node-positions-api`, `ndt-frontend`) then
  built and started successfully. This is a real edit to a file the manual told me to run
  as-is, not something either manual suggests — flagging it as exactly that.
- **Reproduced?** Deterministic on the first attempt; did not attempt a third build to
  double-confirm since the mechanism (an unpinned global install picking up whatever is
  newest today) is well understood from the error message itself, not a flaky condition.
- **Severity:** High — this is the manual's documented one-command deployment step, and it
  cannot complete on a fresh clone without an edit to the project's own Dockerfile that
  the manual never anticipates or mentions.

## BUG-010: a kernel that logs a complete shutdown after Ctrl-C can still be alive and
serving, many minutes later
- **Feature:** kernel shutdown (both OVS and P4 User Manual pages document
  `terminate called without an active exception` as the expected last line after a clean
  Ctrl-C, and say "The shutdown sequence itself completes... It is not a sign that cleanup
  failed.")
- **Manual page/section:** Native-Linux User Manual, "Safe Shutdown Procedure" (OVS
  section) and its P4-section counterpart; both carry the same callout about this line.
- **Exact steps:** during the P4/BMv2 test (Section D of my checklist), I stopped the
  kernel with `sudo kill -INT <pid>` where `<pid>` was the PID recorded from
  `setsid nohup sudo ./bin/ndtwin_kernel ... &; echo $!` — i.e. the immediate child of
  `nohup`, which on this machine's `sudo` is a wrapper process, not the `ndtwin_kernel`
  binary itself (`sudo` here forks rather than exec-replacing). The target log
  (`~/logs/kernel_p4.log`) showed the complete, expected shutdown sequence at the time —
  every subsystem logging its own stop, ending in `All subsystems stopped. Exiting.` then
  `terminate called without an active exception` — and I recorded D13 as fully clean based
  on that log plus a same-minute process/port check.
- **Observed, discovered ~14 minutes later while starting an unrelated (OVS) kernel
  instance for the Simulation Platform test:** the new kernel aborted immediately —
  `terminate called after throwing an instance of
  'boost::wrapexcept<boost::system::system_error>' / what(): bind: Address already in
  use`. `sudo ss -ltnp | grep 8000` showed **the P4 kernel from 14 minutes earlier still
  listening**: `LISTEN ... users:(("ndtwin_kernel",pid=398314,fd=8))`, and
  `ps -p 398314 -o pid,ppid,etime,cmd` confirmed it had been running continuously the
  whole time (`ELAPSED 14:22`, `PPID 398312` — the `sudo` wrapper I had sent `SIGINT` to,
  not this PID directly), still passing the exact `--topology
  .../StaticNetworkTopologyP4_10Switches_128Hosts.json` I'd launched it with. It was not a
  zombie or defunct entry — it was a live, working process still holding the listening
  socket. Had to `sudo kill -9` it before the replacement kernel could bind port 8000.
- **What I can and can't say about the mechanism:** I did not trace this at the
  signal-handling level (would need source reading beyond what a first-time user does).
  What I can say from direct observation: (a) the log for that process shows a complete,
  correctly-sequenced shutdown, matching the manual's own documented "expected" output
  exactly; (b) despite that, the process itself did not exit and kept serving for at least
  14 minutes; (c) I signalled the PID `setsid`/`nohup` reported as `$!`, which on this
  machine is `sudo`'s own PID, not the eventual `ndtwin_kernel` PID — a distinction the
  manual's shutdown instructions never surface (they just say "press Ctrl-C" against a
  foreground terminal, where this fork/exec distinction is invisible to begin with).
- **Reproduced?** This is a single observed instance — I noticed it only because a second,
  unrelated kernel launch collided with it. I did not deliberately try to reproduce the
  "log says done, process isn't" gap a second time, for time reasons; flagging it with that
  caveat rather than asserting it always happens.
- **Severity:** High. The practical consequence is exactly what happened to me: trusting
  the documented "this is fine, cleanup completed" framing and moving on, only to hit a
  silent port conflict later that looks unrelated to its actual cause. A user who checks
  only the log (which is what the manual's own shutdown section tells you to expect and
  accept) has no reason to also check `ps`/`ss` — and the manual actively discourages
  double-checking by reassuring the reader the scary-looking abort line is normal.

## BUG-011: CPU utilization shown in the Web GUI (and returned by the API) is a fabricated
constant in Mininet mode, not a real measurement — and neither manual says so
- **Feature:** `/ndt/get_cpu_utilization`, surfaced in the Web GUI's Device Information
  panel as "CPU Utilization: NN%" (see Section E of this checklist — I saw `s1` reporting
  "CPU Utilization: 14%", "Memory Utilization: 14%" while testing the Web GUI, and took it
  at face value at the time).
- **Manual page/section:** the Web GUI User Manual's Device Information panel description
  just lists "CPU and memory utilization (if available)" as a displayed field, with no
  caveat. Same for the Traffic Visualizer's Node Information Panel. Neither manual
  mentions this value can be synthetic.
- **Exact steps:** `~/.local/bin/ndt check`, the undocumented diagnostic subcommand (see
  the `ndt --help` WORKS-BUT entry above), run against the live fabric.
- **Observed (verbatim, from the tool's own diagnostic output — not from reading source):**
  ```
  CPU: /ndt/get_cpu_utilization returns 10 + hash(ip) % 50 in MININET mode -- a
       constant unrelated to load, which the Web-GUI displays as if it were real.
       measure with:  python3 tools/test_workflow/cpu_probe.py <secs> <hz> <out.jsonl>
  ```
  In other words: in Mininet mode (the mode this entire manual's Kernel section walks a
  reader through), the number is a deterministic function of the switch's IP address, with
  no relationship whatsoever to actual CPU load — and the tool's own author-facing
  diagnostic says outright that the Web GUI displays it "as if it were real."
- **Why I'm confident this isn't just `ndt check` being overly cautious:** the switch
  utilization values I actually saw earlier in the Web GUI (`s1`: 14%) are exactly the
  right shape for `10 + hash(ip) % 50` (a value between 10 and 59) and never changed
  across repeated views regardless of the switch's actual load at the time — consistent
  with the formula, though I did not independently recompute the hash myself (that would
  need reading source, which I avoided).
- **Reproduced?** The `ndt check` message itself is static tool documentation, not a
  flaky runtime condition — it says this unconditionally in MININET mode. The one Web GUI
  observation I have (s1 at 14%) is a single sample, not independently reproduced across
  multiple loads.
- **Severity:** High as a trust issue even though nothing is "broken" in the sense of
  crashing or refusing to work: a user watching the Network Topology page's device panels
  under Mininet — which is the only mode this Installation/User Manual pair actually walks
  a reader through building — is looking at a number with the visual authority of live
  telemetry that is provably unrelated to load. Nothing on the Web GUI page or the Kernel
  pages warns of this; the only place it's disclosed is an undocumented CLI tool's
  diagnostic output that a reader would have no particular reason to run.

## Working-as-documented, logged for contrast (not a bug)
- Miniconda install, `ryu-env` creation, Ryu install + version pins (Step 2.1-2.4): every
  command matched the manual's expected output exactly, including the literal
  `pip list | grep` block (`dnspython 1.16.0 / eventlet 0.30.2 / greenlet 2.0.2 / ryu
  4.34`).
- `ryu-manager ryu.app.simple_switch_13` (Step 2.5): banner and hang-until-Ctrl-C behavior
  matched the manual exactly.
- `static_topology_file_path` (Step 2.6 item 1): the manual's "replace `<user>` with your
  own login name" instruction works fine once you find where to apply it (the fallback
  string inside `Path(os.environ.get(...))`, not a bare `Path(...)` the way the manual's
  own example shows it) — see JOURNAL.md Section 2 for the exact line. Not filing this one
  as a bug: the outcome the manual promises is achievable, the shown code snippet is just
  stale relative to the file.
- Manual 3-terminal OVS path (Ryu -> `testbed_topo.py` under `tmux` -> kernel with
  `--mode mininet --topology ... --no-ai --loglevel info`): full 128-host/10-switch fabric
  converged; Ryu logged `Static topology initialized, all-destination paths installed.`;
  kernel logged `topology from the control plane: 10 switches, 128 hosts, 288 edges up`
  and `Pulled 16256 paths from controller` (= 128×127, exactly as documented for all
  ordered host pairs).
- Traffic validation (`h1 iperf3 -s &`, `h2 iperf3 -c h1 -t 300 &` in the Mininet CLI, then
  `curl localhost:8000/ndt/get_detected_flow_data`): returned exactly two records, one per
  direction, `src_port`/`dst_port` 5201 on the correct sides. Integer IPs decoded with the
  manual's own one-liner to `10.0.0.1` and `10.0.0.2` — exactly h1 and h2. Measured
  throughput 949 Mbit/s average (healthy — OVS has none of the debug-BMv2 throughput
  ceiling the P4 section warns about).
- Idle-purge (query 18s after killing both iperf3 processes): `[]`, exactly as documented
  ("purged 15 seconds after its last packet... `[]` while traffic is flowing means
  something is wrong; `[]` after it stopped just means you waited too long").
- Shutdown sequence: `sudo kill -INT` on the kernel produced the full documented
  subsystem-by-subsystem stop log ending in `All subsystems stopped. Exiting.` followed by
  `terminate called without an active exception` as the literal last line — matches the
  manual's own callout of this quirk exactly. `sudo mn -c` killed the still-running Ryu
  controller as a side effect, exactly as the manual's shutdown-procedure warning says it
  will (verified deliberately, after having first hit it by surprise while cleaning up
  between attempts — see JOURNAL.md).
