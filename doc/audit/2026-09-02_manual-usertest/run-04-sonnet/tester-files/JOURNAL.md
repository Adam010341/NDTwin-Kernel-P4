# NDTwin install/use journal — run-04 (tester model: sonnet)

Tester persona: grad student, fresh Ubuntu 24.04 VM, first time seeing NDTwin.
Docs snapshot: website commit 2612b0a. Started 2026-09-02.


## Install Manual choice points (before Section 1)   noted 15:39
what I did: Installation Manual root page offers Emulated (Mininet) vs Physical Hardware --
chose Emulated, no physical switches available. Its sub-page then offers "Use the Demo VM"
(download a .ova, import into VMware) vs "Native-Linux Execution Environment" (install
directly onto the machine you have). My machine is a fresh Ubuntu 24.04 VM already reachable
over ssh, not a VMware host, and I was told not to re-image it -- so Native-Linux is the only
path that fits. Also chose to clone `NDtwin-Kernel-P4-public` (the superset repo) rather than
plain `NDTwin-Kernel`, per the manual's own "If you are not sure, clone the P4 one" -- this
keeps the optional P4/BMv2 section (Installation Section 6) open to me later without recloning.
verdict: 1 confusing but worked -- two nested either/or choices before Section 1 even starts,
neither one signposted as "pick based on what machine you already have"; I had to read the
Demo VM page's prerequisites (VMware) to realize it did not apply to me.

## Section 1: System Requirements   started 15:39   ended 15:39   friction: 0
what I did: checked `lsb_release -d` (Ubuntu 24.04.4 LTS, manual verifies on 24.04.3 -- close
enough), `uname -m` (x86_64), confirmed no ~/Desktop (this is Server-shaped, not Desktop --
manual's own Step 4.1 note about `mkdir -p ~/Desktop` being needed is exactly this case),
confirmed passwordless sudo.
verdict: 0 smooth -- pure verification, nothing to install yet.

## Section 2: Python Environment Setup for Ryu   started 15:39   ended 15:45   friction: 0
what I did: installed Miniconda (2.1) via the exact curl/bash/rm commands -- conda 26.7.1 in
under a minute. Sourced conda.sh, ran the two `conda tos accept` commands, `conda create -n
ryu-env python=3.8 -y`, activated it -- `python --version` printed exactly `Python 3.8.20` as
promised. Step 2.2 apt build deps installed cleanly (gcc 13.3.0 present after). Step 2.3: pip
install ryu, pinned eventlet/greenlet/dnspython -- Step 2.4's verification block matched the
manual's expected output *exactly*: dnspython 1.16.0, eventlet 0.30.2, greenlet 2.0.2, ryu
4.34. Step 2.5: `ryu-manager ryu.app.simple_switch_13` in a tmux session -- it loaded
SimpleSwitch13 and OFPHandler and hung, as the manual says is the success case; Ctrl-C
stopped it (and closed the tmux session/server since the pane's only process was ryu-manager
itself, not a shell -- expected tmux behaviour, not an NDTwin issue). Step 2.7: networkx 3.1,
requests 2.28.2, urllib3 1.26.20 installed as pinned. Deferred Step 2.6 (customized Ryu
controller app) because the manual itself says "Do Step 4.1 first, then come back" -- will
close this out right after Section 4's clone.
surprised by: nothing -- this section is the one place so far where every single verification
command printed exactly what the manual said it would.
verdict: 0 smooth.

## Section 3: System Dependencies Installation   started 15:45   ended 15:49   friction: 0
what I did: `conda deactivate` first (manual's own red warning to leave ryu-env before this
section). Step 3.1: build-essential, cmake, g++, make, git, ninja-build, xterm, curl,
wireshark, iperf3 with DEBIAN_FRONTEND=noninteractive -- no debconf hang (the manual's own
warning about the iperf3 daemon-autostart dialog was correctly avoided by following its
instruction). Step 3.2: libboost-all-dev (pulled in a large Fortran/MPI/coarray dependency
chain -- openmpi, gfortran, libcoarrays -- this is apt resolving Boost's optional MPI
components, not anything NDTwin-specific, but it made this the single biggest download of the
whole section), libfmt-dev, libspdlog-dev, libssh-dev, nlohmann-json3-dev, python3-venv,
mininet, openvswitch-switch. Step 3.3 verification block matched the manual's expected output
on every line: `systemctl is-active openvswitch-switch` -> active, `ovs-vsctl show` -> version
line only (no bridges yet, as the manual says is correct pre-Section-5), `sudo mn --test
pingall` -> "*** Results: 0% dropped (2/2 received)".
verdict: 0 smooth.

## Tooling note: a stop in my own harness, not the project   15:51 -> caught ~15:57
what happened: I launched the Section 4.2 `ninja` build inside the VM (detached via
setsid/nohup, PID 12329) at 15:51, then incorrectly assumed my own tooling would push me a
notification when a *VM-side* detached process finished, the way it does for a background
task started directly by my own shell tool. It does not: the build kept compiling on the VM
the whole time (confirmed via `ps aux` still showing live `cc1plus` processes and a growing
ninja log at 15:56), but nothing was watching it from my side, and I stopped acting. An
external check caught this and told me to resume. This is friction in my own tooling/process,
not anything NDTwin did -- recorded here only so it is not mistaken for the project hanging.
Corrected going forward: actively re-check VM-side background work myself on a timer instead
of assuming a push notification will arrive for it.

## Section 2.6 (completed after Section 4.1, as instructed)   15:51   friction: 0
what I did: manual explicitly says "Do Step 4.1 first, then come back" for this step, so I
did it out of numeric order, right after cloning. `intelligent_router.py` and `testbed_topo.py`
both exist at the repo root as promised (no paste-your-own-controller step needed -- the
manual's own note explains this used to be a paste-in step and was removed as a source of
drift, which checks out: the file is 114953 bytes / a few thousand lines, not something you'd
paste by hand). Verified the three "configure" claims by reading the file rather than editing
it: `static_topology_file_path` is a `Path(os.environ.get("NDTWIN_RYU_TOPO_FILE", ...)))` at
line 36 as described; `is_mininet` is set at line 56 and unconditionally reassigned `True`
again at line 602 (manual said "about 545 lines further down" from its own line 56 -- actual
gap is 546, so the manual's own approximate figure is accurate); `switch_num` follows exactly
the 3-tier fallback (env var -> topology file's declared count -> hardcoded 10) the manual
describes, at lines 92-101. Chose the non-destructive option for `static_topology_file_path`:
export `NDTWIN_RYU_TOPO_FILE` in the shell that starts Ryu, rather than editing the source.
verdict: 0 smooth -- this is a "trust but verify" step and everything I checked matched.

## Section 4: Download & Compile NDTwin Kernel   started 15:51   ended 15:57   friction: 2
what I did: Step 4.1 -- per the manual's own guidance ("If you are not sure, clone the P4
one"), cloned `NDTwin-Kernel-P4-public` (not the plain `NDTwin-Kernel`) into
`~/Desktop/NDTwin-Kernel`, so the optional P4 section stays available without re-cloning. Got
commit `936f8c6` (2026-09-01), which matches the commit the Web GUI user-manual page names as
"the kernel snapshot the Installation Manual names" -- a small but real cross-check that the
docs and the repo agree on what "current" means. `mkdir -p ~/Desktop` was necessary (this
machine has no ~/Desktop by default, confirming the Server-shaped read from Section 1). Step
4.2: `cmake -GNinja ..` then `ninja clean` then `ninja -j 2` (this VM has 4 vCPUs, so
nproc/2=2) -- built cleanly: `CMAKE_EXIT=0`, `NINJA_EXIT=0`, zero lines matching "warning:" in
the full build log even though the project compiles with `-Wall -Wextra -Wpedantic -Werror`
(so a warning would have been a hard failure, and there were none), `build/bin/ndtwin_kernel`
(11.8 MB) exists and `--help` prints a flag summary that matches what the User Manual's
"why the flags" boxes describe (`--mode`, `--topology`, `--ai`/`--no-ai`). Whole build took
about 6 minutes wall clock, far under what I budgeted for a C++23 project this size.
surprised by: not the build itself (clean, fast) -- the friction here was mine, not the
project's: I started this in the background and then genuinely stopped acting on the belief
that a detached VM-side process would page me automatically when it finished. See the
"Tooling note" entry above; it cost about 6 minutes of wall time where nothing progressed
after the build had, in fact, already finished (build done 15:57, caught ~15:57 per the
external check, so the real cost was small this time, but the *pattern* -- assuming
notification instead of re-checking -- is what's being flagged for next time, e.g. the much
longer Section 6 P4 build).
verdict: 2 needed a workaround: none from the manual's side (it built clean on the first
try) -- the friction was entirely in how I was watching a background build, corrected now to
active re-checks.

## Section 5: Prepare Network Topology Script   started 15:58   ended 15:58   friction: 0
what I did: `testbed_topo.py` ships in the repo root (10575 bytes, executable bit already
set) -- nothing to create, matching the manual. Have not yet run it (that happens under the
User Manual's Terminal 2, later); this section is only the pre-flight existence check per the
Installation Manual's own scope. Reached the "Installation Complete" banner for the
Open-vSwitch path at this point.
verdict: 0 smooth.

## User Manual: Kernel usage, OVS path (the short way + the 3-terminal way)   started 15:59   ended ~16:23   friction: 3
what I did: installed the `ndt` launcher exactly per the manual (symlink, root-owned
`ndtwin-lab`, sudoers NOPASSWD entry) -- all three steps WORKED. Tried `ndt up ovs` first,
since it is literally the first code block on the page and a curious reader tries the
shortcut before the reference procedure. It reproduced the manual's own pre-documented "G-7"
known limitation exactly: phase 1/4 (Ryu) came up, phase 2/4 (OVS fabric) never started a real
topology (confirmed nothing running underneath it -- no topology process, no root tmux
session, zero OVS bridges), and it gave up after 5m08s with "XX fabric has 0 hosts, expected
128". Read (did not edit) `/usr/local/sbin/ndtwin-lab` to confirm the hardcoded `/home/adam/...`
paths the manual's box names are real -- they are. `ndt down` afterward correctly reported a
clean machine. Full detail in BUGS.md BUG-1.
Fell back to the documented 3-terminal procedure, as the manual itself instructs for this
known case. This is where the run got interesting: Terminal 2 (`testbed_topo.py`) runs its own
built-in all-pairs ping self-test before showing the CLI prompt, and on *two independent full
restarts* that self-test reported 100% packet loss on all 128 pairs it tried -- while
`ovs-ofctl dump-flows` already showed the documented "converged" figure (130 rules/switch) at
the time. Manually re-pinging the *exact same* failing pair (`h1 -> 10.0.0.65`) seconds later
at the `mininet>` prompt got 0% loss, and so did a same-switch pair. So the fabric itself was
fine both times; the script's own health check was not, and its final banner
("Host internet: OK | sFlow reachability: OK | Switch identification: OK") did not reflect
that at all. Full detail in BUGS.md BUG-2. Separately, my first attempt at Terminal 2 (piped
through `tee` for logging, my own choice, not the manual's) had its Mininet CLI crash with an
I/O error a few seconds after reaching the prompt; a second attempt without the pipe (logged
via `tmux capture-pane` instead, as my own instructions actually specify) did not crash, so I
am treating that crash as my own tooling mistake and not a project defect -- noted in BUGS.md
under BUG-2 so it isn't confused with the actual finding.
Terminal 3 (kernel) then refused to start the *first* time I tried it, with a very legible
error: `bind() to sFlow port 6343 failed: Address already in use. Another NDTwin kernel is
almost certainly still running and holding it.` It was right -- a kernel process I never
started (PID 59174, running since 16:08:38) was already up, already looked completely healthy
under `ndt status` (10 switches, 128 hosts, 288 edges, no owner claimed), and neither that
status output nor the earlier `ndt down` had said anything about it, because `ndt down` only
checks ports 8000/8080/8081, not 6343. I could not pin down for certain whether it came from
the failed `ndt up ovs` run polling on in the background after reporting failure, or from
`testbed_topo.py` itself starting a kernel as a side effect -- both are plausible from the
timing and I deliberately did not open either script's source to settle it. Killed it by its
exact PID (not a pattern match) and moved on. Full detail in BUGS.md BUG-3.
With that out of the way, my *own*, properly-started Terminal 3 came up cleanly and
immediately reported "topology from the control plane: 10 switches, 128 hosts, 288 edges up".
Ran the manual's traffic-validation recipe against it: `h1 iperf3 -s &` / `h2 iperf3 -c h1 -t
300 &` in the Mininet CLI, then `curl :8000/ndt/get_detected_flow_data` while it ran --
**exactly 2 records**, one per direction, and the integers decoded to `10.0.0.1`/`10.0.0.2`
(h1/h2) via the manual's own one-liner -- matching the manual's own worked example down to the
literal integer values it uses (`16777226`/`33554442`). iperf3 itself sustained ~955-956
Mbit/s, close to the declared 1000Mbit `TCLink` cap. Stopped the flows (`pkill iperf3` on each
host, not `-f`) and re-queried after ~20s idle: `[]`, matching the documented 15s
`FLOW_IDLE_TIMEOUT`.
Also tried the kernel with **no flags**: got the exact 3-question interactive prompt the
manual quotes, answered 1/1/2 by hand, and it started identically to the flagged form.
Safe shutdown, first full cycle: Ctrl-C on the kernel released `:8000` (process gone, `ss`
confirms) but I did not see the "terminate called without an active exception" line the manual
quotes in what I captured -- noted as a partial match rather than chasing it further, since the
signal path here is `tmux send-keys C-c` into a `sudo ... | tee` pipeline rather than a human's
raw keypress, which is a difference in my own method, not necessarily the project's behaviour.
`exit` in the Mininet CLI worked cleanly (no crash this time -- consistent with the tee theory
above). `sudo mn -c` killed Ryu's tmux session exactly as the manual warns it will -- confirmed
by tmux session listing before/after.
Restarted the **entire stack a second time** from a genuinely clean state (this is restart
attempt #3 counting the `ndt up ovs` false start) -- see the next journal entry for its result.
surprised by: the self-test false-failure (BUG-2) and the invisible leftover kernel (BUG-3) --
both are the "prints success/looks fine but did not do what it claims" pattern this run was
specifically briefed to catch, and neither would have been visible from exit codes alone.
verdict: 3 blocked, worked around: `ndt up ovs` itself is broken on this machine (manual's own
known issue, worked around by using the documented 3-terminal fallback, which works); getting
a truthful read on Terminal 2/3 required not trusting either script's own summary line and
checking the effect directly, exactly as this test was briefed to do.

## Network State Recorder: install + use   started 16:04   ended 16:31   friction: 2
what I did: Installation Manual steps (clone to `~`, `python3 -m venv ~/nsr-env`, pip install
nornir/loguru/orjson/requests, chmod +x the two scripts) all worked cleanly. User Manual's
"Option 1: Background Mode (Recommended)" -- literally `./start_network_state_recorder.sh`,
no environment activation mentioned on that page -- crashed immediately with
`ModuleNotFoundError: No module named 'nornir'`, because the script runs bare `python3`, not
an interpreter path pointing at `~/nsr-env` the way the Installation Manual's own warning box
implies it does. Workaround: `source ~/nsr-env/bin/activate` first, then it started cleanly,
logged correctly, and (confirmed by generating iperf3 traffic on the live OVS fabric and
checking the rotated `.zip`, not just the open `.json`, which reads 0 bytes until rotation)
recorded real flow and graph data in the documented newline-delimited JSON format. Then tested
the stop script and it did something worse than the failed start: `stop_network_state_recorder.sh`
runs `sudo kill -15 $(pgrep -f network_state_recorder.py)` -- exactly the pattern the User
Manual's own NSR page, a few lines further down the same document, explicitly warns not to
use. It reproduced live: `pgrep -f` matched both the real NSR process *and* the unrelated
shell that had run my previous command (because that shell's own command-line text happened
to contain the string "network_state_recorder.py"), and the stop script killed both --
terminating that earlier SSH connection as a side effect. Full detail: BUGS.md BUG-4.
surprised by: a shipped script contradicting a warning on the very same page of the manual it
ships with.
verdict: 2 needed a workaround -- for the start-script gap (activate the venv first); the
stop-script issue has no workaround I am willing to invent (that would mean rewriting the
project's own script), so I just stopped NSR by hand afterward via a single confirmed PID.

## Web GUI: install (Docker) + deploy attempt   started 16:26   ended 16:32   friction: 3
what I did: Docker/Compose install per the manual -- `sudo apt install ... docker-ce ...`
etc. -- worked (`docker --version` 29.7.2, `docker compose version` v5.5.0). Two harmless doc
slips noticed and recorded (a `chmod` on `docker.asc`, a file the preceding line never creates
-- it creates `docker.gpg`; and a redundant `groupadd docker` that always reports "already
exists" in this step order on 24.04). Cloned `Web-GUI`, `cp .env.example .env`, set
`NDT_API_BASE_URL=http://127.0.0.1:8000` (this session's own live kernel), ran
`./web_gui_deploy.sh`. The frontend Docker image failed to build: `pnpm install
--frozen-lockfile` inside the Dockerfile hit `ERR_PNPM_IGNORED_BUILDS` on `esbuild@0.25.5`,
because the Dockerfile installs pnpm with a bare, unpinned `npm install -g pnpm` and today
that resolves to pnpm v12.3.0, whose newer default policy refuses to run a dependency's
install/build script without interactive approval -- which a `docker build` cannot give. The
whole `docker compose`/bake run then aborts: zero containers ever start (`docker compose ps -a`
is empty), so `localhost:3000` was never reachable and none of the GUI-feature checklist items
under this tool could be attempted even in principle. Did not patch the Dockerfile to pin an
older pnpm -- that would be fixing the project, not testing it. Full detail: BUGS.md BUG-5.
verdict: 3 blocked: the documented one-command deploy path cannot produce a running Web GUI on
a from-scratch Ubuntu 24.04 install today; no alternative deploy path is documented on this
page, so this tool's GUI features are recorded as NOT-TRIED (blocked), not BROKEN individually
-- I never got far enough to try them.

## Network Traffic Generator: install + use   started 16:04   ended 16:37   friction: 1
what I did: Installation Manual steps all worked (`python3 -m venv --system-site-packages
~/ntg-env`, pip deps, clone). Confirmed the manual's own claim that `--system-site-packages`
is load-bearing: `python3 -c "import mininet"` inside `ntg-env` resolved to the apt-installed
copy. User Manual step "modify NTG.yaml's host_file into ./setting/Mininet.yaml" turned out to
be non-optional, not just a suggestion -- the shipped `NTG.yaml` defaults to
`./setting/Hardware.yaml`. Editing it and running the documented 3-terminal sequence (Ryu,
then NTG's own `testbed_topo.py` via `sudo ~/ntg-env/bin/python`, then the Kernel) worked:
reached NTG's own "NTG>" prompt in `custom_command` mode. Its own copy of the topology
self-test showed the same false 100%-packet-loss pattern already logged as BUG-2 (see BUGS.md
note) -- but the fabric underneath was fine, confirmed by what came next.
`flow --config flow_template.json` ran a full mixed varied/fixed traffic experiment to
completion ("SUCCESS : Experiment completed."), and I cross-checked it against the kernel's
own API rather than trusting NTG's own log: `curl :8000/ndt/get_detected_flow_data` during the
run showed 29 real detected-flow records. `dist --config dist_template.json` (using the
shipped `cesnet_2022/*.csv` distribution files) also ran real iperf3 flows with
distribution-derived parameters. That config included unlimited-duration flows, so the CLI got
stuck (correctly) waiting for them to finish -- a natural opportunity to test the manual's
"Notice" that Ctrl-C does not cancel just the one experiment. It did exactly what the manual
says: "Keyboard interrupt received. Stopping ongoing tasks and exiting..." then tore down the
whole Mininet topology, not just the flow generation. Confirmed verbatim, not inferred.
surprised by: nothing about NTG itself broke; genuinely smooth once the one required YAML edit
was made. The self-test false-failure carried over from the Kernel's own copy of the script,
which was expected once BUG-2 was already known.
verdict: 1 confusing but worked -- the Hardware.yaml-vs-Mininet.yaml default and the implicit
"Terminal 3 kernel must already be running or NTG spins forever retrying" dependency are both
things the page could state more directly, but neither actually blocked anything once
followed.

## Simulation Platform Manager + Energy-Saving-App: install + partial use   started 16:38   ended 16:44   friction: 1
what I did: cloned both repos, apt deps were already satisfied from the Kernel section, NFS
server+client installed and configured (`/srv/nfs/sim` exported to `localhost`, mount points
`/mnt/nfs/sim` and `/mnt/nfs/app` created). The two `settings.hpp.example` templates already
default to the same-machine-demo values the manual describes (`localhost` everywhere), so I
just copied them to `settings.hpp` rather than hand-editing anything. `make all` (not bare
`make`, per the manual's own warning) built Energy-Saving-App cleanly and correctly copied
`energy_saving_simulator` into `Simulation-Platform-Manager/registered/.../executable`; `make
all` on Simulation-Platform-Manager also succeeded. Checked `NDTwin-Kernel/setting/
AppConfig.hpp`'s `SIM_SERVER_URL` before touching anything: it already read
`http://localhost:9000/submit`, which is correct -- but the manual's own worked example for
this exact setting shows port **8003**, not 9000. Recorded as a doc bug rather than acted on,
since the shipped default was already right.
Tried `sudo ./simulation_platform_manager` standalone, out of curiosity, without first
bringing up Ryu/Mininet/Kernel (the manual's documented order puts it fourth in the sequence,
but nothing on this page says it *requires* the earlier three to already be running just to
start). It came up cleanly: real `mount -t nfs localhost:/srv/nfs/sim /mnt/nfs/sim` (verified
independently with `mount | grep nfs`, not just trusting its own log line), "Server started at
http://localhost:9000" (verified with `ss -tlnp`, genuinely listening). Then tried `sudo
./energy_saving_app` the same way, also standalone: it failed at its own NFS mount step
(`mount.nfs: ... /srv/nfs/sim/power ... No such file or directory`) after a connection-refused
error trying to reach the (not-yet-running) kernel first. My guess -- not confirmed by reading
source -- is that the app-specific NFS subdirectory only gets created once a kernel
registration succeeds, which this isolated test never triggered.
Stopped both cleanly (Ctrl-C) and confirmed the NFS mount released.
verdict: 1 confusing but worked -- the install steps themselves were friction-free; the one
real gap is the SIM_SERVER_URL port in the manual's own example, and the undocumented
dependency the application layer (as opposed to the manager) has on a kernel already having
registered it. Did not pursue the full four-terminal-plus-app end-to-end run given remaining
time in this session; recorded as NOT-TRIED rather than BROKEN since I did not actually
attempt it in the documented order.

## Network Traffic Visualizer: install + headless smoke test   started 16:46   ended 16:47   friction: 0
what I did: `sudo apt install openjdk-21-jdk xvfb` (xvfb added on my own initiative, since the
manual's own troubleshooting section for this exact tool recommends it for a headless
machine, which is what I have -- no GUI, connecting over ssh only, per this test's own rules).
Cloned, `git checkout b5e039c` (the manual's own pinned commit, with a documented reason: tip
of `main` does not compile), `./mvnw clean package` -- BUILD SUCCESS in 26s. Ran
`./network_traffic_visualizer.sh` with no display: failed exactly as the manual predicts (a
Maven/JavaFX launch error, no window, process exits). Then ran the same command through
`xvfb-run -a`, which is the manual's own suggested way to check a headless build without a
real display -- this time it genuinely started: `ps aux` showed real `Xvfb` and `java
javafx:run` processes alive and consuming CPU, and the app's own debug log showed a live
render loop ("TopologyCanvas.draw() - nodes: 0, links: 0, flows: 0", repeating), matching the
manual's note that an empty canvas is what "API unreachable" looks like (no kernel was running
in this isolated check). Stopped it with Ctrl-C.
verdict: 0 smooth -- every step matched what the manual said would happen, including both of
its documented failure/success shapes (crashes with no display, runs empty-but-alive under
xvfb). Did not and could not evaluate any of the actual visual features (layout, flow
animation, playback, dark mode) -- this VM has no display, and I was instructed not to use
browser/GUI automation tools for this test, so those checklist lines are NOT-TRIED (needs a
real display), not WORKS or BROKEN.

## Tooling note: a second stop in my own harness, not the project   caught again ~16:52-16:53
what happened: same mistake as the 15:51 note, repeated -- I treated a locally-launched
polling loop as something that would page me when the VM-side `p4-guide` build finished, and
ended my turn to "wait" for it. It does not work that way here: every one of those processes
is on the far side of an `ssh` call that already returned, and nothing pushes a notification
back for it. Corrected (again, this time for good): from here on, never end a turn while
`grep -c SCRIPT_EXIT ~/log.txt` is 0 -- interleave real checklist work with periodic checks
of that file instead of stopping. Recorded here only so two stalls in my own process do not
read as the P4 build hanging -- it was not; `~/log.txt` was growing the whole time.

## P4 toolchain build: milestone check while still running   17:43
what I did: with the overall `install-p4dev-v8.sh` script still running (started 16:02:57,
now past 90 minutes), checked whether the two binaries NDTwin actually needs were usable yet,
per the manual's own advice ("the two binaries NDTwin uses are built before the components
that fail late"). `simple_switch_grpc` is already installed and answers
`--version` -> `1.15.6-1c8c9a4f`. `p4c-bm2-ss` is not yet installed to `/usr/local/bin`, but
the freshly-linked binary in the build tree already answers
(`~/p4c/build/backends/bmv2/p4c-bm2-ss --version` -> `Version 1.2.5.17 (SHA: d46d824202 BUILD:
Release)`).
Both version strings are an exact match for the manual's own worked example for **this
specific date** -- the Installation Manual's Section 6.1 box says, verbatim: "1.15.6-1c8c9a4f
with p4c-bm2-ss 1.2.5.17 on 2026-09-02 ... The 2026-09-02 toolchain compiled this project's
ndtwin_switch.p4 cleanly, so a newer p4c is not by itself a problem." That is precisely what
I am seeing, on the day the manual names. A concrete, satisfying cross-check that the manual's
own "measured on" claims are not decorative -- they reproduce.

## P4 toolchain build: both required binaries confirmed installed and working   18:11
what I did: `which p4c-bm2-ss` -> `/usr/local/bin/p4c-bm2-ss`, `p4c-bm2-ss --version` ->
`Version 1.2.5.17 (SHA: d46d824202 BUILD: Release)`; `which simple_switch_grpc` ->
`/usr/local/bin/simple_switch_grpc`, `--version` -> `1.15.6-1c8c9a4f`. Both answer for real,
not just "found on disk". Total elapsed for `install-p4dev-v8.sh` to build and install grpc,
PI, behavioral-model and p4c (the four components that matter for these two binaries): from
16:02:57 to ~18:11, about 2h08m on this VM's 4 vCPUs -- close to the manual's own "about two
hours on 4 vCPUs" reference figure. The script itself is still running in its tmux session
`p4` (now installing packages for the next component, mininet, going by the apt output in the
log -- tk8.6-blt2.5, libxss1, etc.), and per the manual's own guidance ("the check that
decides whether it worked is not its exit status but whether the two binaries exist
afterwards... check whether you need the full redo first") I am proceeding directly to Step
6.2 rather than waiting for the whole script (mininet/ptf/p4runtime-shell/tutorials) to finish
-- none of those remaining components are things NDTwin itself needs, and the manual's own
Section 3.2 already installed the apt-packaged Mininet this project actually uses.

## Section 6: P4 / BMv2 Data Plane (Installation)   started 16:02   ended 18:12   friction: 2
what I did: Step 6.0 confirmed `p4_proxy/p4_src/ndtwin_switch.p4` exists (already true since
Section 4.1 cloned the P4-public repo). Step 6.1: checked `python3 --version` was 3.12.x (not
ryu-env's 3.8) before starting, cloned `p4-guide`, launched
`./p4-guide/bin/install-p4dev-v8.sh` inside a detached tmux session exactly as the manual's own
"run it detached" box shows. This is the long step the manual warns about -- total time from
launch to both required binaries answering `--version` was **about 2h08m** on this VM's 4
vCPUs, close to the manual's own "about two hours on 4 vCPUs" figure. Versions:
`simple_switch_grpc 1.15.6-1c8c9a4f`, `p4c-bm2-ss 1.2.5.17 (SHA: d46d824202)` -- both an exact
match for the manual's own worked example for 2026-09-02, a satisfying confirmation the
manual's dated claims are not decorative. Followed the manual's own advice to judge readiness
by the two binaries rather than the script's exit status, and moved on to Step 6.2 while the
script's remaining components (mininet, ptf, p4runtime-shell, tutorials) kept running in the
background -- none of those are things NDTwin itself needs.
Steps 6.2-6.6 all went smoothly: `p4c-bm2-ss` compiled `ndtwin_switch.p4` cleanly (two benign
warnings only: an unused constant, a deprecated output-format notice); the proxy's Python 3.12
venv built and every pinned requirement (`protobuf==3.20.3` included) installed without
conflict; `AppConfig.hpp` already had the correct proxy port and mixed-dataplane flag from the
original Section 4.2 build, so no edit/rebuild was needed; `host_count_override` set to 128;
and `bmv2_binary_override` -- which shipped pointed at the not-yet-built `bmv2-fast` path, with
an unusually detailed comment already in the file explaining a specific prior finding about
why (a debug build's throughput ceiling masking a downstream app's traffic-sensitivity) -- was
switched to the stock `/usr/local/bin/simple_switch_grpc` per the manual's own instruction for
readers who skip Step 6.7, which I did (optional-of-optional, cut for time). Confirmed the
selected path is a real, executable binary before moving on.
Skipped Step 6.7 (the `-O3` "bmv2-fast" performance rebuild) entirely -- the manual itself
frames it as optional on top of an already-optional section, and building BMv2 a second time
from a fresh clone was not worth the extra time against the 90-minute floor this run owes the
use-and-break phase.
verdict: 2 needed a workaround -- none from the manual's own steps (every one of 6.0-6.6
matched exactly), the friction was entirely mine: the two "second stop" incidents recorded
earlier in this journal happened during this section's long wait, not because of anything the
build did.

## P4 toolchain: install-p4dev-v8.sh reached SCRIPT_EXIT=0   18:16
what I did: the full `install-p4dev-v8.sh` run (grpc, PI, behavioral-model, p4c, mininet, ptf,
p4runtime-shell, tutorials) finished on its own, `grep -c SCRIPT_EXIT ~/log.txt` -> 1,
`SCRIPT_EXIT=0`. Total wall time 16:02:57 -> ~18:16, about **2h13m** on this VM's 4 vCPUs --
consistent with the manual's own "about two hours on 4 vCPUs" reference. Per the manual's own
framing, exit 0 says the script ended, not that it succeeded -- the acceptance check is the two
binaries, which I had already confirmed answering `--version` about 5 minutes earlier and had
already used to finish Installation Section 6.2-6.6 while this tail end (mininet/ptf/etc, none
of which NDTwin itself needs) kept running in the background.

## User Manual: P4/BMv2 data-plane walkthrough   started 18:17   ended 18:21   friction: 1
what I did: with Section 6 installed for real (both binaries confirmed working, pipeline
compiled, proxy venv built, `host_count_override`=128, `bmv2_binary_override` pointed at the
stock build), first tried the shortcut `ndt up` (bare, P4 is its default) out of the same
curiosity that tried `ndt up ovs` earlier. Reproduced the identical G-7 root cause: "XX fabric
did not come up: 0/10 switches, manifest missing" after 3m06s -- faster to give up than the
OVS path's 5m08s, and with a better message (names a diagnostic command,
`sudo -n /usr/local/sbin/ndtwin-lab topo-out 40`, which itself just says "no topo session").
`ndt down` afterward reported clean. Full detail in BUGS.md's addendum to BUG-1.
Fell back to the documented 3-terminal procedure, in the **reverse** order the manual
specifically calls out (Mininet/BMv2 first, since BMv2 listens and the proxy dials in, unlike
OVS where Ryu listens and switches dial in). Terminal 1
(`sudo python3 p4_proxy/mininet/p4_testbed_topo.py`): all 10 BMv2 switches came up and were
verified listening on gRPC 50051-50060 in under a minute, with a real `/tmp/ndtwin_p4_switches.json`
manifest (10 entries, real PIDs, each `argv` naming the exact `ndtwin_switch.json` pipeline
compiled in Installation Step 6.2). Terminal 2 (the proxy agent, in its own venv, `PYTHONPATH`
set to `p4_proxy`): came up on :8081; its first 10 attempts to tell the kernel about switches
entering all failed with `Connection refused` (kernel not started yet) -- its own log names
this as expected and retries in the background, then went on to LLDP discovery, link
discovery and proactive route install without getting stuck. `curl
:8081/ryu_server/all_destination_paths` reached exactly **16256** (128x127, the manual's own
documented figure) in under 30s and stayed stable across two more samples 5s apart. Terminal 3
(kernel, `--topology ...StaticNetworkTopologyP4_10Switches_128Hosts.json`): immediately logged
`Data plane: bmv2 (10 switch(es))`, correctly switched to polling the proxy's :8081 instead of
Ryu, and converged to exactly **10 switches, 128 hosts, 288 edges** -- the manual's own
documented figure, matched exactly.
Traffic validation (`h1 iperf3 -s &` / `h2 iperf3 -c h1 -t 300 &` in the Mininet CLI, then
`curl :8000/ndt/get_detected_flow_data`): exactly 2 records, same h1/h2 integer-IP encoding as
the OVS test, each with a real switch-level `path`. Measured throughput on the *stock* (debug)
`simple_switch_grpc` I deliberately kept (skipped the optional Step 6.7 fast rebuild): roughly
34-37 Mbit/s one direction -- squarely inside the manual's own documented debug-build ceiling
("about 40 Mbps of delivered UDP... adding parallel streams did not help"), a nice real
confirmation of a claim I did not have to take on faith.
Safe shutdown, in reverse order (kernel, then proxy, then Mininet): the kernel's Ctrl-C output
this time *did* show "terminate called without an active exception" (captured via plain `>`
file redirection rather than the `tee` pipe used earlier for the OVS test) -- this resolves
the open question from checklist item B14 in favour of "the manual is right, my earlier
capture method was the variable." The proxy released :8081 immediately. Mininet's own `exit`
had already killed all 10 `simple_switch_grpc` processes on its own -- `ps -eo args= | grep -c
"[s]imple_switch_grpc"` (the exact non-truncating form the manual insists on, not `pgrep -c`)
read **0** even before `mn -c` ran. `ndt status` independently confirmed a fully clean machine
afterward.
Skipped Step 6.7 / checklist item C17 (the `-O3` bmv2-fast performance build) -- explicitly
optional-on-top-of-optional per the manual's own framing, and not needed to exercise any
checklist item above.
surprised by: nothing broke. Every documented number in this section (16256 paths, 10
switches/288 edges, 2 flow records, the debug-build throughput ceiling) matched exactly on the
first real attempt, once the two known-and-already-documented G-7 shortcuts were worked around
by falling back to the 3-terminal procedure the manual itself recommends for exactly this case.
verdict: 1 confusing but worked -- the `ndt up` shortcut failing was expected (same as OVS),
and the manual's own reverse-order instruction for P4 was the one thing worth double-checking
against the actual startup logs, which it matched.

## Tooling note: journal had an accidental duplicate block, removed   caught 18:25
what happened: the "Install Manual choice points" + Section 1 + Section 2 entries had been
appended twice, verbatim, back to back (lines 45-82 of the file as it stood at 18:25). This
is a mechanical duplication from my own scripting early in the run, not a second real
observation -- both copies were byte-for-byte identical. Removed the second copy (kept a
`~/JOURNAL.md.bak-dedup` backup of the pre-edit file in this same home directory) rather than
leave a misleading double entry; checked the rest of the file (`CHECKLIST.md`, `BUGS.md`, and
every other JOURNAL.md section header) for the same pattern and found none elsewhere. Noting
this rather than silently fixing it, per the same standard applied to the two "stop" incidents
earlier in this file.

## SUMMARY

**Installed and running?** Yes. NDTwin Kernel built clean from source (Sections 1-5 of the
Installation Manual, Native-Linux path), and both the OVS/Ryu path and the optional P4/BMv2
path (Section 6) were brought up end-to-end more than once, with traffic flowing and detected
by the kernel's own API each time. Evidence: `~/Desktop/NDTwin-Kernel/build/bin/ndtwin_kernel`
built 2026-09-02 15:53 (OVS) and still working through the P4 walkthrough that ended 18:21;
kernel log line `topology from the control plane: 10 switches, 128 hosts, 288 edges up` on
both the OVS fabric (twice) and the P4/BMv2 fabric; `curl :8000/ndt/get_detected_flow_data`
returning real flow records with real switch paths on both fabrics, cross-checked against
independently-run iperf3 transfers.

**Per-section timings** (from JOURNAL.md's own `started`/`ended` timestamps, all VM-local
`date` output):
- Section 1 (System Requirements): 15:39-15:39, friction 0
- Section 2 (Python/Ryu): 15:39-15:45, friction 0
- Section 3 (System Dependencies): 15:45-15:49, friction 0
- Section 4 (Clone + Compile Kernel): 15:51-15:57, friction 2 (friction was my own tooling, not the build)
- Section 5 (Topology Script): 15:58-15:58, friction 0
- Kernel User Manual, OVS path (short way + 3-terminal): 15:59-~16:23, friction 3
- Network State Recorder: 16:04-16:31, friction 2
- Web GUI: 16:26-16:32, friction 3
- Network Traffic Generator: 16:04-16:37, friction 1
- Simulation Platform Manager + Energy-Saving-App: 16:38-16:44, friction 1
- Network Traffic Visualizer: 16:46-16:47, friction 0
- Section 6 (P4/BMv2 Installation, dominated by the ~2h13m toolchain build): 16:02-18:12, friction 2
- Kernel User Manual, P4/BMv2 path: 18:17-18:21, friction 1
- Total elapsed, first VM command to last: 15:37 -> 18:25, about **6h48m of wall-clock**, of
  which roughly 2h13m was the unattended P4 toolchain build running in the background while
  other sections were tested, and two further stretches were my own tooling stalling rather
  than any wait the project itself required (recorded in JOURNAL.md as the two "Tooling note"
  entries, 15:51-15:57 and centered on 16:52-17:00 respectively -- both were me incorrectly
  assuming a detached VM-side process would page me, not anything NDTwin did).

**What was skipped and why:**
- Step 6.7 (optional bmv2-fast `-O3` performance rebuild of BMv2): explicitly
  optional-on-top-of-optional per the manual's own framing; not needed for any checklist item.
- NTG/NSR "hardware/worker-node" modes, Operate a Physical (Hardware) Network: no physical
  testbed available in this run.
- WebGUI's GUI feature pages, TrafficVisualizer's GUI features, NTG's tab-completion: this
  test's own ground rules (no browser automation; this VM has no real display or interactive
  TTY) -- marked NOT-TRIED rather than guessed at.
- Full Simulation Platform end-to-end (kernel submits a task, simulator runs): would need
  WebGUI (blocked by BUG-5) or another documented trigger path I did not have.

**Moment I felt most lost:** discovering the orphaned `ndtwin_kernel` process (BUG-3) blocking
my own Terminal-3 launch with a sFlow-port bind failure. `ndt down` had reported the machine
fully clean minutes earlier, and I could not initially tell whether the leftover process was
something I had caused, a race in `ndt up ovs`'s own internal retry logic, or something else
entirely -- it took `ps`/`ss` cross-checks and re-reading the one file the manual named
(`ndtwin-lab`) to get confident enough to write it up rather than guess.
