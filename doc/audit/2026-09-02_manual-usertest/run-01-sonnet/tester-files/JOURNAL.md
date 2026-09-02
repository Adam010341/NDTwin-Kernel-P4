# NDTwin install/use journal — run-01

Tester: grad student, first time seeing this project. Fresh Ubuntu 24.04 VM.
Docs snapshot: website commit bcf98f5.

## Front matter / navigation   started 06:09   ended 06:10   friction: 0
what I did: Read `~/ndtwin-docs/_index.md`, `NDTwin Installation Manual/_index.md`,
`NDTwin Installation Manual/NDTwin Kernel/_index.md`, and
`.../Operate an Emulated (Software) Network/_index.md`. All of the `_index.md` files
are near-empty (frontmatter only) — they're just Hugo section markers; the real content
is one level down. The Kernel index says: two primary environments, "a purely emulated
software network (Mininet) or a real physical hardware network." I'm doing the emulated
one (I have a plain VM, not a physical switch lab). Under "Operate an Emulated (Software)
Network" there are two pages: "Use the Demo VM for a Quick Start" (weight 1) and
"Install All Required Components on a Linux Server" / Native-Linux (weight 2).
decision point: I opened the Demo VM page to check it. It requires downloading a
`.ova` (two variants — standard, and P4/BMv2 — the P4 one "not yet published") and
VMware Workstation/Fusion to import it. I already have a fresh Ubuntu 24.04 machine,
not a VM image to import, so that page doesn't fit my situation — I'm following
"Install All Required Components on a Linux Server" (Native-Linux Execution
Environment) instead. Noting this as the first real choice point: a first-time reader
who was handed a bare machine (rather than told to download a VM image) would make the
same call, but the manual's index doesn't say "if you already have a plain Ubuntu
machine, use this one" — I had to open the other page and read its prerequisites to
rule it out.
verdict: 0 smooth (navigation itself was easy, files are short)

## Section 1: System Requirements   started 06:10   ended 06:11   friction: 0
what I did: Checked `lsb_release -a` (Ubuntu 24.04.4 LTS — manual verified on 24.04.3,
close enough), `uname -a` (generic x86_64 kernel), confirmed passwordless sudo. Checked
edition: `dpkg -l | grep ubuntu-server` shows this is **Server** edition, and `~/Desktop`
does not exist yet, exactly the case the manual calls out in Step 4.1's aside ("Ubuntu
Server has no ~/Desktop... the mkdir -p costs nothing on Desktop and removes that failure
mode on Server"). Good — the manual anticipated my exact situation.
verdict: 0 smooth

## Section 2: Python Environment Setup (for Ryu)   started 06:11   ended 06:20   friction: 1
what I did: Installed Miniconda with the literal commands given. Step 2.1 offers two ways
to make `conda` usable: `conda init bash` + new terminal, or `source
~/miniconda3/etc/profile.d/conda.sh` for the current shell only. I tried the first option
first since it's listed first ("Either").
surprised by: `~/miniconda3/bin/conda init bash` (then, in what I'd call "a new terminal" —
a fresh SSH connection) -> `conda --version` -> `bash: line 1: conda: command not found`
(exit 127). `conda init` itself even says "For changes to take effect, close and re-open
your current shell" — I did the equivalent (new connection) and it still didn't pick it up.
Switched to the `source .../conda.sh` option, which worked immediately (`conda 26.7.1`).
I'm noting this as ambiguous/environment-dependent rather than a manual bug: I'm driving
this machine over non-interactive SSH, and non-interactive shells don't source `~/.bashrc`
the way a real interactive terminal does, so a desktop user opening an actual new terminal
window would probably not hit this. Recording it because the manual's own suggested check
("if this prints nothing, nothing below will work") is exactly what I hit, and the fix
wasn't "open a newer terminal" — it was "use the other of the two given options instead."
Rest of Section 2 went as documented: `conda tos accept` x2 (needed — the manual says the
create fails without it, I did not test skipping it since the manual is explicit and
confident here), `conda create -n ryu-env python=3.8 -y` succeeded, `python --version`
inside the env printed `Python 3.8.20` (matches). Step 2.2 apt installs: exit 0. Step 2.3
pip upgrade + `pip install ryu` + pins: all succeeded. Step 2.4 verify — output matched the
manual's expected block exactly:
`dnspython 1.16.0 / eventlet 0.30.2 / greenlet 2.0.2 / ryu 4.34`. Step 2.5 `ryu-manager
ryu.app.simple_switch_13`: ran it under `setsid nohup ... &`, recorded the PID (5136),
confirmed the log showed the two expected "loading app" / "instantiating app" lines and the
process was still alive 6s later (the manual's documented success shape — it does not
return), then killed it by that PID directly and confirmed `/proc/<pid>` was gone.

Step 2.6 sent me to do Step 4.1 first (clone the repo — see below), then back here to set
three deployment parameters in `intelligent_router.py`. This is where it got interesting:
the file no longer looks like the manual's pasted example of three plain variable
assignments.
- `static_topology_file_path`: real code is
  `Path(os.environ.get("NDTWIN_RYU_TOPO_FILE", "/home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json"))`
  — an env-var override with a hardcoded fallback baked in for a **different user's**
  home directory (`/home/adam/...`, not mine — I'm `ndt`). The manual's instruction
  ("replace `<user>` with your own login name") still works if applied to that fallback
  string, so I edited it in place to `/home/ndt/Desktop/NDTwin-Kernel/setting/...`. Net
  effect matches what the manual intended, just via a different-looking line than the one
  it shows.
- `is_mininet`: the line the manual points at (`is_mininet = True # True: Mininet...`) has
  its own in-code warning directly above it: "⚠️ EDITING THIS LINE DOES NOTHING. `is_mininet`
  is unconditionally reassigned to True further down in this same module-level block... so
  whatever you set here is overwritten before anything reads it." I checked: there is a
  second `is_mininet = True` about 545 lines later (its own comment: "THIS is the assignment
  that wins"). For me this is harmless — I want `True` (Mininet) and that's what the
  hardcoded override forces regardless — but the manual presents this as a real switch
  ("`false` for physical testbed") and never mentions it's dead. Filed to BUGS.md; I could
  not personally reproduce the broken-False-path since I'm not doing the physical-network
  install, so the finding rests on the two matching in-code comments I read while making the
  edit the manual told me to make, not on running the physical-testbed path myself.
- `switch_num`: manual says "set `switch_num = 10`" as a literal edit. I grepped the file
  for `switch_num\s*=` and found no such assignable line at all — it's computed from
  `NDTWIN_RYU_SWITCH_NUM` env var, else auto-counted from the topology JSON's declared
  switches, else a fallback of 10. For the 10-switch tutorial fabric the auto-detected value
  is 10 either way, so no functional difference for me, but the manual's instruction doesn't
  correspond to any editable line in the current file.
Step 2.7: `pip install -U networkx` and pinned `requests`/`urllib3` — both succeeded.
verdict: 1 confusing but worked — the conda-init two-option ambiguity was a minor own-goal
of my SSH-driven setup; the Step 2.6 drift (dead `is_mininet` knob, vanished `switch_num`
line, foreign-user hardcoded path) is a real doc/reality gap, written up in BUGS.md.

> **Operational note, not a manual finding:** between here and Section 3 my driving
> session (the agent process typing these commands) crashed and restarted; this VM was
> untouched throughout (verified: `ryu-env` still present, the repo and my Step 2.6 edit
> still in place, no stray processes, `~/JOURNAL.md`/`~/BUGS.md` exactly as I'd left them).
> The gap between the 06:22 timestamp below and actually resuming work at 06:36 is that
> restart, not time spent on anything in this manual — flagging it so the Section 3 timing
> isn't misread as 14 minutes of friction.

## Section 3: System Dependencies Installation   started 06:22 (see note above; work
resumed 06:36)   ended 06:38   friction: 0
what I did: Confirmed I was out of `ryu-env` — moot for me since every command is its own
fresh SSH invocation and conda's activation never persists across them (system
`python3 --version` is always 3.12.3 unless I explicitly source+activate in that same
command), so the warning box here ("Leave ryu-env first, Section 2 never told you to turn
it off") never had a chance to bite me the way it would someone in one continuous
terminal. Step 3.1 (`build-essential cmake g++ make git ninja-build xterm curl wireshark
iperf3`): `apt install` reported all ten packages "already the newest version," 0 newly
installed. `g++`/`make`/`git` make sense (pulled in transitively by Step 2.2's
`build-essential`), but `cmake`, `ninja-build`, `xterm`, `wireshark` and `iperf3` were
apparently already on this VM image before I touched anything — I don't have a manual
explanation for that (this looks like a property of the lab's base VM image, not
something Step 2 caused), so I did not get to observe the iperf3-debconf-dialog behavior
the manual warns `DEBIAN_FRONTEND=noninteractive` guards against; that footgun is
documented but untested by my run. Step 3.2 (`libboost-all-dev libfmt-dev libspdlog-dev
libssh-dev nlohmann-json3-dev python3-venv mininet openvswitch-switch`): pulled in Boost
1.83.0 (matches the manual's ">= 1.83" requirement) plus a large dependency tree (mpi,
gfortran, etc., pulled in by `libboost-all-dev`) — apt exited 0. A few harmless `debconf:
unable to initialize frontend` fallback lines appeared (no TTY over non-interactive SSH)
but nothing blocked and nothing needed an answer. Step 3.3 verification, both checks
matched the manual's documented expected output exactly:
- `sudo systemctl is-active openvswitch-switch` -> `active`
- `sudo ovs-vsctl show` -> a UUID + `ovs_version: "3.3.9"`, no error, no bridges (as
  expected pre-Section-5)
- `sudo mn --test pingall` -> ends with `*** Results: 0% dropped (2/2 received)` exactly
  as the manual says to look for (not the last line of output — teardown logging follows
  it, matching the manual's own warning about that).
verdict: 0 smooth (once past the restart) — every check passed on the documented first
try, no retries needed.

## Section 4: Download & Compile NDTwin Kernel   started 06:17 (clone, done early for
Step 2.6) / 06:39 (compile)   ended 06:44   friction: 0
what I did: Step 4.1 (clone) was already done earlier, out of order, because Step 2.6
sends you here first — see the Section 2 entry. Choice made there: cloned
`ndtwin-lab/NDTwin-Kernel-P4-public` (not the OVS-only `NDTwin-Kernel` repo), per the
manual's own "if you are not sure, clone the P4 one" — I plan to attempt the optional P4
section too, and the P4 repo is a documented superset. Step 4.2: `rm -rf build; mkdir
build && cd build; cmake -GNinja ..; ninja clean; ninja -j2` (nproc=4, so nproc/2=2), run
under `setsid nohup` in the background, polled by PID. `cmake` configure took ~1.5s, one
CMake dev-warning about `DOWNLOAD_EXTRACT_TIMESTAMP` from a `FetchContent_Declare` at
`CMakeLists.txt:126` (explicitly labeled "for project developers," suppressible with
`-Wno-dev` — cosmetic, not something the manual mentions but also not something it needed
to). `ninja` then built all 90 targets with no errors (`grep -iE "FAILED|error:"` over the
full log: no matches) in about 5 minutes wall-clock, producing
`build/bin/ndtwin_kernel` (11.8 MB) and `build/bin/test_routing_strategy` (19.2 MB, a test
binary — the Installation Manual never tells you to run it, so I didn't; not part of any
checklist item from this manual). Returned to project root per the manual's step 4 (`cd
~/Desktop/NDTwin-Kernel`) before continuing.
verdict: 0 smooth — the only friction on this whole page was Section 2's Step 2.6, not
this step.

## Section 5: Prepare Network Topology Script   started 06:45   ended 06:45   friction: 0
what I did: `cd ~/Desktop/NDTwin-Kernel && ls -l testbed_topo.py` — present, executable,
10575 bytes, dated from the clone. The manual is explicit that this section only has you
confirm the file exists; actually launching it ("The User Manual launches this script")
is deferred to the User Manual, so I did not run it here. Noted for later: the manual
warns to expect repeated `Bandwidth limit 10000 is outside supported range 0..1000 -
ignoring` when it does run (backbone links declared at 10 Gbps, Mininet's `TCLink` caps at
1000 Mbit/s) — checking for that verbatim when I get to the User Manual's launch step.
verdict: 0 smooth

## Installation Complete (Open vSwitch path)   06:45
The manual declares the OVS-path install done here and points to the User Manual to
launch the kernel. Total elapsed for Sections 1-5, excluding the ~14-minute driving-session
restart gap noted in Section 2/3: about 34 minutes (06:11 start of Section 2 to 06:45),
most of it unattended apt/pip/ninja time. I'm continuing into the optional Section 6
(P4/BMv2) next, starting the long toolchain build in the background, then switching to the
User Manual to launch and test the OVS-path kernel while that build runs — the manual
itself says Section 6 is independent ("Everything above is complete on its own"), and the
task budget explicitly expects the P4 toolchain step to be a long background wait rather
than something to sit through.

## Use phase: OVS fabric + kernel (User Manual, Native-Linux)   started 06:51   ended 07:13
friction: 3
what I did: Symlinked `ndt` per the manual ("The short way"). Immediately hit a `PATH`
issue identical in shape to the conda one — `~/.local/bin` isn't on `PATH` in a fresh
non-interactive shell — worked around the same way, by calling it via its full path.
`ndt --help`, run out of curiosity, turned out to document a much bigger tool than either
manual does — see BUGS.md's "`ndt --help` reveals a much larger tool" entry (`ndt apps`,
`ndt down --deep`, `ndt status --check`, `ndt clean`, `ndt ntg`, `ndt release`, numeric
`ndt up` variants — none of it in either manual).
`ndt up ovs` (first try) failed immediately: `sudo: /usr/local/sbin/ndtwin-lab: command not
found`. Found `tools/test_workflow/ndtwin-lab` sitting right next to `ndt` in the repo,
not executable, never installed anywhere `sudo` looks — neither manual mentions it.
Applied the obvious fix (chmod +x, symlink into `/usr/local/sbin`, same pattern the manual
already used for `ndt` itself) — see BUG-003. `ndt down` cleaned up correctly afterward
(and I used it several more times this session; always accurate).
`ndt up ovs` (second try, post-fix) got past Ryu but failed at "fabric has 0 hosts,
expected 128" after about 5 minutes — see BUG-004. Rather than keep fighting the wrapper, I
switched to the manual's own literal 3-terminal commands, which is squarely what my
checklist needed testing anyway.
surprised by: driving an interactive `mininet>` CLI over non-interactive SSH is genuinely
awkward and cost real time — my first attempt redirected stdin from `/dev/null` (my normal
practice for backgrounded commands), which let the topology build the *entire* 128-host
fabric correctly (all the way to "Final Configuration Active") and then made the Mininet
CLI's `input()` hit immediate EOF and tear the whole thing straight back down. This is a
fact about my own tooling, not a manual bug — a human at a real terminal never hits it —
but worth recording because it looks exactly like a hang/crash until you notice the
teardown log underneath it. Switched to a bare `tmux` session (no `| tee`, which produced
a *different* `OSError: [Errno 5] Input/output error` from Mininet's `cmdloop` — also my
own harness, dropped it) and drove the CLI with `tmux send-keys` / `capture-pane` from
then on — this worked cleanly for the rest of the session.
Also noticed, investigating BUG-004: twice (once after the failed `ndt up ovs`, once after
a direct `sudo ndtwin-lab ovs-topo-start`) a live `ndtwin_kernel` process turned up bound
to port 8000 that I had not started myself, tracked by the same `.test_run/pids/kernel.*`
bookkeeping `ndt`/`ndtwin-lab` use. Did **not** reproduce this on the clean `tmux`-driven
run of raw `testbed_topo.py` I eventually used for real testing. I don't have enough
evidence to say which command causes it, so BUGS.md reports it with that uncertainty
attached rather than guessing.
Ran the full manual 3-terminal path clean, twice total (once by necessity after `mn -c`
killed my first Terminal-1 Ryu as a side effect — which is *itself* documented behavior I
therefore verified by accident before verifying it on purpose). Results, all against the
10-switch/128-host OVS fabric: Ryu up (A7) -> topology built, converged, "all-destination
paths installed" (A8, A10) -> flow-count check stable at **130** per switch, not the
manual's documented 131 (A11 — see WORKS-BUT in BUGS.md; the manual's own two figures for
this already disagree with each other by 2, before my measurement) -> kernel up against the
128-host topology, reporting `10 switches, 128 hosts, 288 edges up` and `Pulled 16256 paths
from controller` (=128×127, exactly right) (A13) -> `h1 iperf3 -s &` / `h2 iperf3 -c h1 -t
300 &` in the Mininet CLI, 949 Mbit/s measured (A17) -> `curl .../get_detected_flow_data`
returned exactly 2 records, correct `src_port`/`dst_port` placement, integer IPs decoding
via the manual's own one-liner to 10.0.0.1/10.0.0.2 (A18) -> after killing both iperf3
processes and waiting 18s, same query returned `[]` (A19) -> `sudo kill -INT` on the kernel
produced the full documented subsystem-shutdown log, ending in the exact documented
`terminate called without an active exception` last line (A21) -> Mininet `exit`, `sudo mn
-c`, which killed the still-running Ryu controller as a side effect, exactly as the
shutdown-procedure warning says (A20).
verdict: 3 blocked-then-worked-around — the documented "short way" (`ndt up ovs`) does not
work out of the box and needed a real fix (BUG-003) plus a second, only-partially-explained
failure (BUG-004) before I gave up on it for this session; the manual's own literal
3-terminal path, once I had a working pty to drive it with, matched the manual closely and
correctly on every point I could check.

## Discovering `ndt apps` and its reliability problem   07:13-07:17   friction: 2
Ran `ndt --help` out of curiosity after `ndt up ovs` failed — revealed a much larger CLI
than either manual documents (`ndt apps`, `--deep`, `--check`, `clean`, `ntg`, `release`,
numeric `up` variants). Tried `ndt apps` with no args (lists 5 managed apps: energy, sim,
nsr, viz, te — none of which is WebGUI or NTG, so those two still need their own manual
install regardless). Tried each with nothing installed: `nsr` and `te` gave clean, honest
`XX ... not found` errors; `viz` correctly detected no display and refused; **`sim` and
`energy` both printed `ok ... started (tmux: sim/energy)` with exit 0 — while genuinely
starting nothing** (no tmux session on any socket, no process, source repo not even
cloned). Reproduced twice for `sim`. Filed as BUG-005 — this is squarely the
"success-message-is-not-evidence" trap the task briefing warns about, coming from the
project's own tooling.
verdict: 2 needed a workaround: went back to each tool's own documented manual-install path
for Sections E-I rather than trusting `ndt apps`, since 2 of 5 apps it claims to manage
gave false positives.

## NDTwin Tool — Network State Recorder   started 07:16   ended 07:23   friction: 2
what I did: Installation Manual steps first — clone into `~/Desktop/Network-State-Recorder`
(matches the path `ndt apps nsr` itself reported expecting — a nice cross-check), venv at
`~/nsr-env`, pip installs, chmod the two scripts. Manual explicitly says to check the
launcher's "interpreter path... written inside the script" — opened it and found there
isn't one: it's a bare `python3`, correctness depending on ambient shell state, not a
fixed path (see checklist G4). Confirmed by testing both ways: fails with
`ModuleNotFoundError: No module named 'nornir'` without the venv active, works with it
active. Brought the OVS fabric back up (Ryu -> topology in `tmux` -> kernel — same recipe
as before, converged in about a minute) to give NSR something real to record against.
First launch attempt (before the fabric was up) exited cleanly and correctly on
"NDTwin server is not reachable, exiting..." — exactly the manual's documented
troubleshooting entry, not a bug. With the fabric up: NSR ran cleanly, wrote
`flowinfo`/`graphinfo` JSON with the right naming convention, correctly logged `[]`-shaped
flowinfo records with no traffic and populated ones once I started `iperf3` on h1/h2 through
the tmux Mininet session.
surprised by: `./stop_network_state_recorder.sh` -> matched **two** PIDs via its internal
`pgrep -f network_state_recorder.py` (`263432 264738`) and `sudo kill -15`'d both; my own
driving SSH command was cut off with exit 255 right after. End state was still correct on
a fresh check (NSR stopped, config reverted) but this is the shipped script using the
*exact* pattern the User Manual — two sections earlier — explicitly says not to use, and I
have direct (if partly circumstantial) evidence it caught something beyond the recorder.
Filed as BUG-006.
verdict: 2 needed a workaround (G4's ambient-venv issue) and turned up a real, separate bug
in the shipped stop script (BUG-006) along the way.

## NDTwin Tool — Network Traffic Generator   started 07:23   ended 07:30   friction: 3
what I did: Installation Manual steps — venv at `~/ntg-env`, deps, clone. Two real bugs
back to back before I got traffic flowing:
- BUG-007: the User Manual's documented launch command,
  `sudo ~/miniconda3/envs/ntg-env/bin/python testbed_topo.py`, names a **conda** path;
  the Installation Manual built a **venv** at `~/ntg-env` instead. Confirmed by `ls`:
  the conda path doesn't exist, the venv path does. Same shape of bug as Section 2.6's
  hardcoded `/home/adam/...` default — a worked example that doesn't match the setup
  steps immediately before it.
- BUG-008: fixing the path to the real venv, NTG's own bundled `testbed_topo.py` then
  failed with `ModuleNotFoundError: No module named 'mininet'` — a plain `python3 -m venv`
  is isolated from system site-packages by default, and `mininet` is an apt package (per
  the *Kernel* Installation Manual), invisible from inside NTG's venv. Fixed by recreating
  the venv with `--system-site-packages` (standard Python knowledge, not from either
  manual) and reinstalling.
Once both were fixed: brought Ryu + NTG's bundled topology (already pre-wired to NTG's own
CLI — the manual's "edit your topology to import our CLI" step turned out to be for a
*custom* topology, not needed for the shipped example, which the manual doesn't say) + the
kernel up in sequence, same recipe as before. `NTG>` prompt reached at the 128-host scale
(`h1`->`h69`+ sampled in its near/middle/far connection debug output).
`flow --config flow_template.json`: real iperf3 traffic between random host pairs;
cross-checked against `curl .../get_detected_flow_data` mid-run, which showed 189
concurrently-detected records — good independent confirmation NTG and the kernel agree on
what's happening on the wire.
`dist --config dist_template.json`: the three CESNET-2022 distribution CSVs it needs
**ship in the repo** (`cesnet_2022/`) — I had expected to have to generate them myself
from the manual's phrasing ("you need to generate 3 kinds of distribution files"), which
turned out not to be true for the example. Flows came out with realistic
distribution-shaped values (`0.0110676191107272M`, a 307.56s duration).
`Ctrl-C` mid-`dist`: immediately tore down the *entire* session, not just the running
command — exactly the documented "Notice" behavior, confirmed directly.
verdict: 3 blocked-then-worked-around — two real, back-to-back environment bugs before
anything ran, but once past them NTG itself performed exactly as documented on every
feature I tried.

## NDTwin Tool — Web GUI   started 07:30   ended ~07:41 (browser part), resumed 10:03
friction: 3
what I did: Docker install per the manual — one small, harmless doc slip along the way:
`sudo chmod a+r /etc/apt/keyrings/docker.asc` errors `No such file or directory` because
the line above it wrote `docker.gpg`, not `.asc` (the repo config correctly references
`docker.gpg`, so this cost nothing but a red error line). `sudo groupadd docker` also
errored "already exists" — `docker-ce`'s own postinstall creates it, so the manual's
separate step is redundant on a stock install, not wrong. Docker itself: clean install,
`docker --version`/`docker compose version` both printed versions, `docker ps` worked
without needing a fresh login (every one of my SSH calls is already a fresh session, so I
can't tell whether a real persistent-terminal user would need to reopen theirs the way the
manual says — noting this as untested-by-me rather than claiming the manual is wrong here).
Cloned Web-GUI, `.env` from `.env.example` with `NDT_API_BASE_URL` pointed at the local
kernel, `chmod +x web_gui_deploy.sh`, ran it.
surprised by: it failed the Docker **build** outright — `ERR_PNPM_IGNORED_BUILDS` on
`esbuild`. The shipped `Dockerfile` does `RUN npm install -g pnpm` with no version pin, so
it always installs whatever pnpm is newest *today*, and a recent pnpm major now refuses
non-interactively to run a dependency's install scripts unless the project has approved
them — this repo's lockfile predates that default. Filed as BUG-009. Fixed by pinning
`pnpm@9` in the Dockerfile (a real edit to a file the manual says to run as-is); rebuild
then succeeded, all three containers up (`ndt-postgres`, `ndt-node-positions-api`,
`ndt-frontend`).
Set up an SSH port-forward from my own side (`-L` to the VM's :3000 and :8000 — needed
:8000 specifically because Vite bakes `NDT_API_BASE_URL` into the client bundle at *build*
time, so whatever loads the page has to reach that exact address itself, not just the
Docker host) and opened it in the Browser tool. Confirmed, by eye, before losing browser
access (see below): the frontend loads at `:3000` with no errors once the tunnel covered
both ports; the Network Topology page renders the real 10-switch/128-host graph
(congestion-colored links); clicking a switch node opens the documented Device Information
panel with live-looking CPU/Memory/Temperature/Status fields; "Show Ports" opens a Switch
Ports panel listing 34 active ports on `s1` with per-port connected-device and bandwidth
data; the bottom-left Flow Information panel showed live flows (2 records for one
iperf3 pair, matching the "one per direction" shape from the Kernel section) with all five
documented toolbar buttons present (`Stop`, `Top-K Flow`, `Update Interval (1000ms)`,
`Port Reference`, `Show Filters`) and the Top-K dialog opening to the documented default
state ("Current mode: Show All", K defaulting to 50).
🔴 **My own run was cut off here** — a harness watchdog stopped the session after the
Browser tool stalled for 600s with no progress (I had just set a K-value input via a raw
DOM script and had not yet clicked Apply or captured the result — so Top-K *filtering
itself* is not confirmed, only that the dialog opens correctly). About 2 hours of wall
clock passed before I could resume. The VM itself was untouched throughout — Ryu, the
kernel, and all three WebGUI containers were still up and serving when I checked back in.
**Instruction change from the coordinator on resume: no more Browser-tool use for the rest
of this run.** Remaining WebGUI checks (Switch Flow Table's add/modify/delete forms,
Availability Status, the rest of the Flow Information toolbar, node-position Save,
NDTwin Assistant) move to curl-only verification where an API exists, and NOT-TRIED
("needs a real browser") where the manual only promises a visual/interactive effect I have
no remaining way to observe.
verdict: 3 blocked-then-worked-around for the Docker build (BUG-009); once past that,
everything I could actually see in the running app matched the manual, up to the point my
own tooling cut me off mid-session — a fact about my environment, not NDTwin.

## Kernel — P4/BMv2 data plane (Installation Manual Section 6 + User Manual P4 path)
started 10:03 (config)/10:08 (launch)   ended 10:12   friction: 0
what I did: toolchain (Step 6.1) finished successfully while I was cut off — see the
harness note above; confirmed on resume with `simple_switch_grpc --version` ->
`1.15.6-1c8c9a4f` and `p4c-bm2-ss --version` -> `Version 1.2.5.17`, 0 FAILED/fatal lines in
the 14675-line build log. From there the whole optional P4 section went smoothly, no bugs:
compiled the pipeline (Step 6.2, two harmless warnings), built the proxy venv pinned to
`protobuf==3.20.3` (Step 6.3), found `AppConfig.hpp` already correct out of the box so no
edit/rebuild was needed (Step 6.4), set `host_count_override` to 128 (Step 6.5), and — the
one real decision point — Step 6.6/6.7: skipped the optional performance BMv2 build and
pointed `bmv2_binary_override` at the stock `/usr/local/bin/simple_switch_grpc` instead, a
call I think most first-time readers would make the same way (6.7 is explicitly about
throughput, not correctness).
Launch, same 3-terminal shape as OVS but reversed order (Mininet -> Proxy -> Kernel):
`p4_testbed_topo.py` in `tmux` -> "All 10 BMv2 switches verified listening on gRPC 50051 ~
50060", manifest at `/tmp/ndtwin_p4_switches.json` confirmed with real PIDs and gRPC ports
for all 10. Proxy agent up on :8081 (two harmless FastAPI deprecation warnings, framework
noise not NDTwin's). `all_destination_paths` polling: stable at 16256 (=128×127) across 6
samples. Kernel: `Data plane: bmv2 (10 switch(es))`, `10 switches, 128 hosts, 288 edges up`
— matches the OVS path's graph shape exactly, as it should (same topology, different data
plane). Traffic test: 2 flow records, correct shape; measured throughput (~40 Mbps, ~3300
pps) landed exactly in the manual's own documented ceiling for a stock/debug BMv2 build —
nice independent confirmation of a specific, checkable claim. Idle-purge: same `[]` after
traffic stopped. Shutdown: kernel and proxy both exited cleanly, 0 surviving
`simple_switch_grpc` processes, port 8081 released.
verdict: 0 smooth — genuinely the smoothest section of the whole session once the (already
green-lit) toolchain was in hand. No bugs filed here; every documented check passed on the
first try with real, verifiable numbers.

## NDTwin Tool — Network Traffic Visualizer   started 10:13   ended 10:18   friction: 1
what I did: no `java` on the machine at all, and unlike every other dependency page in
this manual, this one names a JDK 21 requirement but never gives an install command for
it — installed `openjdk-21-jdk` myself (ordinary Ubuntu knowledge, not manual-derived).
Clone, `git checkout b5e039c` (the manual's documented workaround for tip-of-main not
building — took this on faith rather than re-proving the negative), `./mvnw clean package`
-> `BUILD SUCCESS` in 25.8s, both documented jars produced.
Bare `./network_traffic_visualizer.sh` failed exactly as the Troubleshooting section
predicts for a headless machine: `UnsupportedOperationException: Unable to open DISPLAY`.
Installed `xvfb` (again, not from the manual) and reran under `xvfb-run -a` — the manual's
own suggested workaround — and the app came up for real, connecting to the kernel API and
logging live draw calls (`138 nodes, 288 links` — 10 switches + 128 hosts, consistent with
every other count taken off this fabric all session).
Then went one step further than "just confirm it starts": grabbed a screenshot of the
Xvfb virtual framebuffer with `xwd` + ImageMagick `convert` (terminal tools, no browser
involved — this was still under the no-Browser-tools constraint), pulled the PNG down and
viewed it directly. It's a real, working render: the documented Fat-Tree layout
(Core/Aggregation/Edge/Host layers, visually distinct), the full sidebar UI matching the
manual's feature list. Good, concrete visual evidence gathered without needing the
Browser tool at all.
verdict: 1 confusing but worked — the missing JDK-install step is a small, easy-to-clear
gap (any competent Linux user solves it in under a minute), and the headless-display
failure is *exactly* what the manual itself warns to expect, with a workaround that
worked on the first try.

## NDTwin Tool — Simulation Platform Manager + Energy-Saving-App   started 10:19
ended 10:27   friction: 0
what I did: cloned both repos into `~` (matching the only concrete path the User Manual
gives — `cd ~/Simulation-Platform-Manager`). Package deps already satisfied from the
Kernel install. NFS server (`nfs-kernel-server`, `/srv/nfs/sim`, `/etc/exports`) and client
(`nfs-common`, `/mnt/nfs/sim`, `/mnt/nfs/app`) set up per the manual. Opened both
`settings.hpp.example` files before editing anything, out of habit from every other
section's surprises — and found both **already default to exactly what the same-machine
demo needs** (`localhost` everywhere, matching ports/paths on both sides, and the kernel's
own `setting/AppConfig.hpp` SIM_SERVER_URL already `http://localhost:9000/submit` too) —
so every "hand-edit this file" step in Section 4 of the manual was a `cp`, not an edit.
`make all` (not bare `make`, exactly per the manual's warning) in Energy-Saving-App: clean
build, binary landed at the documented registered path automatically. `make all` in
Simulation-Platform-Manager: clean build (also produced a `request_manager`, `app` and
example `simple_sim` binary the manual doesn't mention — not chased further).
Brought up Ryu + OVS fabric + kernel (routine by now), then `sudo
./simulation_platform_manager`: `Server started at http://localhost:9000`, and — checked
the actual effect, not just the log — `mount | grep /mnt/nfs/sim` showed a genuine NFS4
mount, not a claim.
surprised by (good surprise): starting `sudo ./energy_saving_app` didn't just come up —
it immediately ran a **complete, automatic end-to-end cycle** with zero manual triggering
on my part: mounted `/mnt/nfs/app` (verified via `mount`, correctly at the per-app NFS
subdirectory), queried the kernel's graph data, compared simulated "cases," chose one, and
issued a real power-off command for switch s9 through the kernel's own REST API
(`POST /ndt/set_switches_power_state?ip=192.168.123.19&action=off` -> `200,
{"192.168.123.19":"Success"}`). Didn't take the log's word for it: queried
`get_graph_data` myself afterward and found `s9` reporting `"is_up": false` while every
other switch (s1-s8, s10) reported `true` — the claimed action really happened, visible
through a completely independent API call.
verdict: 0 smooth — the section I expected to be the most fragile (multi-repo, NFS,
hand-edited C++ settings headers, a kernel rebuild) turned out to need none of the manual
editing it describes, because the shipped defaults already matched the demo, and the
whole pipeline worked end-to-end on the first try with real, independently-checked
evidence. The only mild note: the manual's Section 4 reads as if editing is required even
in the same-machine case, when a `cp` was actually sufficient.

## SUMMARY

**Installed and running:** yes, on the Native-Linux (Open vSwitch) path, the optional P4/BMv2
path, and every one of the five separately-documented Tools (Web GUI, Network Traffic
Generator, Network State Recorder, Network Traffic Visualizer, Simulation Platform Manager +
Energy-Saving-App). Best single piece of evidence: the Simulation Platform end-to-end test
— `curl http://localhost:8000/ndt/get_graph_data` showing switch `s9` with `"is_up": false`
after `Energy-Saving-App` autonomously decided to power it off through the kernel's own
REST API, independently re-confirmed by a second, unrelated query rather than trusting the
app's own log.

**Total wall-clock:** roughly 4.5 hours of active work, spread across two driving-session
segments (the coordinator's messages mid-transcript explain the gaps — this VM itself ran
continuously and unattended the whole time, including the ~2-3 hour P4 toolchain build).

**Shape of the session:** Sections 1-5 of the Installation Manual (native-Linux, OVS) went
almost entirely smoothly — the one real snag, Step 2.6's three deployment-parameter
instructions no longer matching the file they describe, was itself informative rather than
blocking. The optional P4/BMv2 section (Installation Manual Section 6 + its User Manual
counterpart) was the single smoothest stretch of the whole exercise: every documented
command worked on the first try, with real numbers matching the manual's own predictions
exactly (16256 paths, 288 edges, and a measured throughput landing precisely in the
documented stock-BMv2 ceiling). The five Tools were where almost every bug in this report
turned up: a documentation-drift path (NTG), a venv/system-package isolation gap (NTG
again), an unpinned dependency that broke a shipped Dockerfile outright (Web GUI), a shipped
script using the exact unsafe pattern the manual itself warns against (NSR), and — the two
findings I'd flag as most important for a maintainer — an undocumented `ndt`/`ndt apps`
launcher whose "ok, started" message is sometimes simply false (BUG-005), and a kernel whose
documented clean-shutdown log can print in full while the process keeps running and serving
(BUG-010). Simulation Platform, the section I expected to be the most fragile going in
(multi-repo, NFS, hand-edited C++ settings headers), needed none of its own documented
editing — the shipped defaults already matched the same-machine demo — and worked
end-to-end without me touching a single line.

**Reproducibility discipline:** every WORKS verdict in the checklist rests on an
independently-checked effect (an API response, a mounted filesystem, a process's actual
listening state, a rendered screenshot), not a command's exit code or a friendly log line —
per instructions, "it said OK" is never treated as proof by itself. Every BROKEN or BUG-*
finding states plainly how many times it was reproduced, and where it was only observed
once, says so rather than implying more confidence than the evidence supports.
