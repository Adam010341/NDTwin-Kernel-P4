# NDTwin install + use journal

Tester: graduate student, first contact with NDTwin. Fresh Ubuntu 24.04.4 VM, 4 vCPU, 5 GB RAM,
116 GB disk. Working over ssh with no terminal, so anything the manual says to "leave running in
a terminal" is run in its own tmux session inside the VM.

Docs snapshot: website commit c5262c3 (`~/ndtwin-docs/DOCS-SNAPSHOT.txt`).

## Section 0 - orientation and the choices the manual made me make   started 10:12   ended __   friction: 1
what I did: read the docs root, Overview, System Architecture, and the Installation Manual index
pages. The index pages are frontmatter only, so on the rendered site they are just link lists;
I followed the tree.

Three choices were forced before any command ran:

1. **Physical (hardware) network vs Emulated (software) network.** I have no hardware switches,
   so: Emulated.
2. **"Use the Demo VM for a Quick Start" vs "Native-Linux Excution Environment".** The Demo VM
   page requires VMware Workstation/Fusion and a downloaded `.ova`. I am *on* a plain Ubuntu
   24.04 machine, so the Demo VM route is not available to me: Native-Linux.
   - Worth noting for the manual: the P4/BMv2 demo image, which is the one the page says you
     need "if you are following any page of this manual that mentions P4, BMv2, p4c or
     simple_switch_grpc", is listed as *(not yet published)*. So the only way to get P4 today is
     the Native-Linux Section 6 source build.
3. **Which repository to clone** (Step 4.1). Manual: "If you are not sure, clone the P4 one."
   I am not sure, so I will clone `NDTwin-Kernel-P4-public` into `~/Desktop/NDTwin-Kernel`.

Ambiguity noted: the top-level install page never states the order of the two manuals
("NDTwin Kernel" then "NDTwin Tool") or whether the Tool pages are prerequisites of the Kernel
pages. I assumed Kernel first because the User Manual link at the end of the Kernel page points
at the Kernel User Manual.

verdict: 1 confusing but worked - the choice tree is only discoverable by opening every page.

## Section 2 - Python Environment Setup (for Ryu)   started 10:14   ended 10:21   friction: 1
what I did: installed Miniconda with the manual's exact four commands; used the second of the
two offered ways to make conda usable (`source ~/miniconda3/etc/profile.d/conda.sh`, "no new
terminal needed") because I am on ssh; accepted both channel ToS; created `ryu-env` with
Python 3.8; installed Ryu and the three pinned libraries; verified; ran `ryu-manager
ryu.app.simple_switch_13` in a tmux pane and stopped it with Ctrl-C; then, as Step 2.6 orders,
jumped forward to Step 4.1 and cloned the repository; then came back for Steps 2.6 and 2.7.

Step 2.4 matched the manual's stated expected output exactly (~/logs/sec24-verify.log):
  dnspython          1.16.0
  eventlet           0.30.2
  greenlet           2.0.2
  ryu                4.34

Step 2.5 behaved as documented -- it "hung", which the manual says is the success case
(~/logs/sec25-ryu-test.txt):
  loading app ryu.app.simple_switch_13
  loading app ryu.controller.ofp_handler
  instantiating app ryu.app.simple_switch_13 of SimpleSwitch13
  instantiating app ryu.controller.ofp_handler of OFPHandler

friction: the 🔴 forward jump in Step 2.6 ("Do Step 4.1 first, then come back"). Step 4.1 is two
sections away and Section 3 -- which installs `git` -- sits between them. On my machine git was
already present (`/usr/bin/git`, ~/logs/sec41-clone.log) so the clone worked, but the manual is
relying on that. On a truly minimal install the reader is sent to a step whose tool the manual
has not installed yet.

verdict: 1 confusing but worked

## Section 3 - System Dependencies Installation   started 10:21   ended 10:23   friction: 0
what I did: `conda deactivate`, confirmed `Python 3.12.3`; Step 3.1 build tools with
`DEBIAN_FRONTEND=noninteractive`; Step 3.2 libraries + mininet + openvswitch-switch; Step 3.3
all three verifications.

All three Step 3.3 checks passed, including the specific line the manual told me to read for
by name rather than by position (~/logs/sec33-verify.log):
  *** Results: 0% dropped (2/2 received)
and:
  active
  68da78e5-07d4-4189-b8aa-3f7e0b7921ef
      ovs_version: "3.3.9"

Nothing surprised me. The `DEBIAN_FRONTEND` warning was accurate in the sense that I never saw
an iperf3 debconf prompt; I cannot say whether it would have appeared without the variable
because I did not try it without.

verdict: 0 smooth

## Section 4 - Download & Compile NDTwin Kernel   started 10:19 (clone) / 10:23 (build)   ended 10:29   friction: 0
what I did: the clone was already done at 10:19 because Step 2.6 sent me forward to Step 4.1.
Step 4.2: `rm -rf build`, `mkdir build && cd build`, `cmake -GNinja ..`, `ninja clean`,
`ninja -j $(( $(nproc) / 2 ))` (= -j2 on this 4-vCPU machine), then `cd ~/Desktop/NDTwin-Kernel`.

Result (~/logs/sec42-build.log): CMAKE_EXIT=0, NINJACLEAN_EXIT=0, NINJA_EXIT=0, 90 ninja edges,
10:23 -> 10:29, six minutes. Produced:
  -rwxrwxr-x 1 ndt ndt 11839016 Sep  3 10:25 ndtwin_kernel
  -rwxrwxr-x 1 ndt ndt 19200112 Sep  3 10:29 test_routing_strategy

Nice touch: the manual's own cross-check from Step 6.1 passes -- `ldd build/bin/ndtwin_kernel |
grep /usr/local` printed nothing (~/logs/sec5-check.log).

verdict: 0 smooth

## Section 5 - Prepare Network Topology Script   started 10:30   ended 10:30   friction: 0
what I did: `ls -l testbed_topo.py` at the project root. It ships in the repository as the
manual says (`-rwxrwxr-x 1 ndt ndt 10575 Sep 3 10:19 testbed_topo.py`). Nothing to create.
I did not run it yet -- the User Manual is what launches it, and Step 6.1 is the long build I
want started first.

verdict: 0 smooth

## Section 6.1 - Install BMv2 and p4c (the long one)   started 10:30   ended see below   friction: ?
what I did: ran the manual's pre-flight gate first --
  python3 --version   ->  Python 3.12.3
  PATH has no conda entry  (checked: `echo $PATH | tr ':' '\n' | grep -i conda` matched nothing)
  df -h ~  ->  110G available (manual asks for >= 25 GB)
then cloned p4-guide and launched the manual's **detached** form verbatim:

  cd ~
  git clone https://github.com/jafingerhut/p4-guide
  tmux new-session -d -s p4 \
    'cd ~ && ./p4-guide/bin/install-p4dev-v8.sh 2>&1 | tee log.txt; \
     echo "SCRIPT_EXIT=${PIPESTATUS[0]}" >> log.txt'

Launched at **2026-09-03 10:30:52** (`~/logs/sec61-launch.log`). I will come back for it and
record the time I did. Deliberate decision while it runs: I am **not** starting the 128-host
Mininet fabric concurrently. This machine has 5.9 GB of RAM and 4 vCPUs, the install script
runs one build job per 2 GB of RAM, and the manual is explicit that the script is not resumable
-- an OOM kill would cost the whole run. I will do only work that touches neither `apt` (one
lock, and the script uses it) nor much CPU until it finishes.

## User Manual, OVS path - bring-up (Terminals 1-3)   started 10:38   ended 10:48   friction: 1
NOTE ON CONDITIONS: the Step 6.1 P4 toolchain build was compiling throughout this section.
5.9 GB RAM / 4 vCPU shared between them. I therefore treat **timings** from this section as
unusable and rely on the manual's own count-based checks, which do not depend on the clock.
I re-check anything timing-sensitive after the toolchain build finishes.

what I did:
- Terminal 1 (tmux `ryu`): `conda activate ryu-env`, then Step 2.6's option 1
  `export NDTWIN_RYU_TOPO_FILE=~/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json`,
  then the manual's ryu-manager line. Confirmed `LISTEN 0 50 0.0.0.0:6633` and `:8080` before
  starting the topology, as the manual insists (~/logs/t1-ryu-ports.txt).
- Terminal 2 (tmux `mn`): `sudo python3 testbed_topo.py` from the project root. Reached
  `*** Starting CLI: mininet>` at 10:40:04, about 65 s after launch.
- Terminal 3 (tmux `kernel`): the manual's three-flag kernel line. Up at 10:47:56.

surprised by: my own tooling, not the product. My first convergence poll used
  `sudo ovs-ofctl dump-flows s$i 2>/dev/null | grep -c actions=`
and reported `0` for all ten switches for four straight minutes. That was **my** bug: over a
non-interactive ssh there is no tty, sudo asked for a password, and my `2>/dev/null` threw the
error away, so `grep -c` counted zero lines. Nothing was wrong with NDTwin. Recorded here
because a zero that comes from your own instrumentation looks exactly like a product failure,
and I nearly filed it as one. Evidence of the mistake: ~/logs/b5-convergence.log (all zeros)
vs ~/logs/diag-no-flows.log (`sudo: a password is required` ten times).

Once fixed (password piped to each sudo), the manual's own check passed exactly
(~/logs/b5-convergence-final.log):
  --- sample 1 at 10:46:42 ---
  s1=130 s2=130 s3=130 s4=130 s5=130 s6=130 s7=130 s8=130 s9=130 s10=130
  --- sample 2 at 10:46:59 ---   (same)
  --- sample 3 at 10:47:15 ---   (same)
and the decomposition the manual gives is exactly right on s1:
  total actions= lines : 130 / nw_dst rules : 128 / LLDP rules : 1 / priority=0 (miss) : 1

The manual's other two convergence signals also appeared verbatim:
  Static topology initialized, all-destination paths installed.
  install_all_pair_paths done: hosts=128 pairs=16256 rules=1280 paths=16256 walk=0.380s install=0.170s report=0.210s
and the documented `Bandwidth limit 10000 is outside supported range 0..1000 - ignoring`
warning appeared **32 times** (~/logs/t2-topo-60s.txt), exactly as the manual says to expect.

Kernel startup agreed with the topology (~/logs/t3-kernel-start.txt):
  Data plane: ovs (10 switch(es))
  topology from the control plane: 10 switches, 128 hosts, 288 edges up
  Pulled 16256 paths from controller
  Destination paths loaded from localhost:8080 (16256 pairs)
  Server Listening on port 8000
and `/ndt/get_graph_data` agrees: 138 nodes (10 switches + 128 hosts), 288 edges, 10 up, 10 enabled.

friction 1, and it is a real one: **the manual never says how to run any of the three terminals
without a graphical desktop.** All three are "leave it running" processes, and the manual's only
concession to that is the `ndt` wrapper, which it then tells you not to use. tmux is my
workaround, not the manual's.

## User Manual, OVS path - use and break (API surface + tools)   started 10:49   ended 11:17   friction: 1
what I did: worked the checklist by hand against the live fabric. Highlights, all with the
effect checked rather than the status code:

- **Traffic validation (B11-B14)** exactly as documented: two flow records one per direction,
  integer addresses, and the flow purged between +10 s and +15 s after the last packet.
- **Flow entry install / modify / delete (D9-D11)** - I did not trust the `200`; I read the
  switch back with `ovs-ofctl dump-flows` each time. Rule count 130 -> 131 -> (port changed
  1 -> 2) -> 130. All three genuinely worked.
- **Group and meter entries (D31-D36)** likewise verified with `dump-groups` / `dump-meters`.
- **Power control (D8)** verified by watching the OVS bridge disappear from `ovs-vsctl list-br`
  and come back, and the switch's 130 rules being reinstalled after power-on.
- **Locks (D27)** is where the one serious product bug turned up - see BUGS.md BUG-03.
- Ran the manual's own validation twice, then with **my own** host pair (`h1`<->`h128`, five
  switches) because the manual's `h1`/`h2` sit on the same switch. That is where the twin
  actually showed its value: the two directions took **different** paths
  (1->6->9->7->4 forward, 4->8->10->5->1 back) and average link usage moved off zero.
- Shut the whole stack down by the documented procedure and brought it up a second time; both
  documented shutdown surprises (mn -c killing Ryu; the kernel's `terminate called without an
  active exception`) reproduced exactly.

surprised by: `curl -s -X POST -d '{"ttl":30}' http://localhost:8000/ndt/acquire_lock`
  ->  `HTTP 200  {"status":"locked","ttl":30,"type":"routing_lock"}`
which is the exact response the API page describes as the pre-2026-08-30 bug it says was fixed.

verdict: 1 confusing but worked - the product is in much better shape than the tool scripts.
Of 41 API routes I exercised 40; one is broken (acquire_lock validation), the rest either
matched the documentation or differed only in wording.

## NDTwin Tools - Network State Recorder and Network Traffic Generator   started 11:00   ended 11:34   friction: 2
what I did: installed and ran both tools against the live OVS stack, following their own
Installation and User Manual pages.

**NSR** produced the biggest install-phase defect of the run (BUGS.md BUG-09): the recommended
start script exits 0 while starting nothing, because it contains a bare `python3` and the
install page told me to check an interpreter path that is not in the file. Once I activated
`~/nsr-env` by hand it worked properly and everything else on its page was accurate - file
naming, zip rotation, log name, NDJSON framing. Its stop script contains verbatim the command
the same manual page tells you never to write (BUG-10).

**NTG** worked well. Its own `testbed_topo.py` already has the NTG CLI wired in
(`command_line(net,"NTG.yaml")` at line 239, `CLI(net)` commented at 236), so step 1 of the
User Manual - "Modify the topology python code" - is already done for you; the page does not
say so. The documented failure mode is exactly right:

surprised by: `sudo ./testbed_topo.py`  ->  `ModuleNotFoundError: No module named 'loguru'`
  - which is precisely what the manual said would happen, and why it tells you to name the
  interpreter instead. Nice to see a warning pay off.

The best moment of the whole run was watching NTG and the kernel agree
(`~/logs/f16-ntg-flow-live.log`): I ran `flow --config flow_template.json` and polled
`/ndt/get_detected_flow_data` while it ran -

  t+3s  : flow_data=173  top_k=50  avg_link_usage=0.08157330780000001
  t+6s  : flow_data=206  top_k=50  avg_link_usage=0.01853196542
  t+15s : flow_data=213  top_k=50  avg_link_usage=0.010310383341666668
  t+18s : flow_data=44   top_k=44  avg_link_usage=0.0013147112
  t+33s : flow_data=0    top_k=0   avg_link_usage=0.0

213 concurrent flows detected by the digital twin from traffic a separate tool generated, then
purged after the experiment. That is the product's central claim, and it held.
It also revealed an undocumented constant - see BUG-15.

**A correction to my own reading, recorded because it nearly became a bug report.** I ran
`dist --config dist_template.json` and watched it print
`Waiting for all connections to be restored, currently running host pairs: 3 with 2 unlimited
duration flows` once a second for three and a half minutes while the kernel reported zero
flows. I was about to file it as a hang. It was not: it completed on its own before 11:30:59
(`grep -c "Experiment completed"` went 2 -> 3, `~/logs/f17-dist-final.txt`) and returned to the
`NTG>` prompt. `dist` works; it is just slow to drain the unlimited-duration flows, and the
message it repeats while doing so names a count that never changes, which reads exactly like a
stall.

verdict: 2 needed a workaround - NSR does not start by its documented command; I had to
activate the venv myself.

## ---- INTERRUPTION (not the project, not the VM) ----   resumed 13:05
There is a gap in the timestamps between roughly 12:28 and 13:05. It was **an infrastructure
error on the harness side that runs me** - an API request timed out - and it was not caused by
NDTwin, by anything I ran, or by the VM. Recording it so the gap is explainable rather than
mysterious.

Nothing was lost: JOURNAL.md, BUGS.md, CHECKLIST.md, DOCS-READ.md and ~/logs/ were all intact,
and the VM kept running. State found on resume at 13:05:04:
  - the Step 6.1 toolchain build had **finished on its own during the gap**: `SCRIPT_EXIT=0`
    is now in ~/log.txt, and the `p4` tmux session has exited.
  - `tmux list-sessions` -> kernel, ntgtopo, ryu still alive
  - `ss -tln` -> :6633, :8080, :8000 all still listening
  - note that the kernel and Ryu are running against a fabric that no longer exists: I tore the
    NTG topology down with Ctrl-C at 11:34 and never restarted it. That is my own doing from
    before the interruption, not a consequence of it. I clean it up below before Section 6.2.
On resuming I re-read JOURNAL.md and CHECKLIST.md rather than working from recollection, and
re-ran the two Step 6.1 acceptance checks rather than reporting them from memory.

## Section 6.1 - Install BMv2 and p4c: RESULT   started 10:30:52   ended (unattended, during the gap)   friction: 2
The `tmux new-session` form from the manual was launched at **2026-09-03 10:30:52** and the run
ended with `SCRIPT_EXIT=0` in `~/log.txt`. It was still compiling p4c at 12:26 (98%), so it
finished between 12:26 and 13:05.

Acceptance re-run at 13:05:41 (`/tmp/.../p4done.txt`), using the manual's own rule that the
check is the two binaries answering, not the exit status:
  simple_switch_grpc --version  ->  1.15.6-1c8c9a4f
  p4c-bm2-ss --version          ->  p4c-bm2-ss
                                    Version 1.2.5.17 (SHA: d46d824202 BUILD: Release)
  which                         ->  /usr/local/bin/simple_switch_grpc, /usr/local/bin/p4c-bm2-ss

That pair is **exactly** the drift the manual predicts: "the same install-p4dev-v8.sh produced
1.15.5-fdd3b893 on 2026-08-28, 1.15.5-8be95de0 on 2026-09-01, and 1.15.6-1c8c9a4f with
p4c-bm2-ss 1.2.5.17 on 2026-09-02". I got the 2026-09-02 pair. The manual's advice to judge by
the binaries rather than by matching version strings was the right advice.

Its other Step 6.1 claims also held:
  - "Check your own machine with `which mn`"  ->  /usr/bin/mn, Mininet 2.3.0 (the apt package
    from Step 3.2 survived; the script's own mininet clone did not replace it)
  - "Disk used by the whole toolchain ~12 GB"  ->  `df -h ~` went from 1.7G used at 10:12 to
    12G, and `du -sh ~/p4c` alone is 2.7G
  - `ldd build/bin/ndtwin_kernel | grep /usr/local` still prints nothing

friction 2, entirely for the reason in BUG-02: the manual's detached form stops on a sudo
password prompt that neither of the manual's two suggested checks can see. Once past that it
ran unattended for about two hours exactly as advertised.

## Sections 6.2-6.6 + User Manual P4 path   started 13:06   ended 13:20   friction: 0
what I did: compiled the pipeline (0.37 s), built the proxy venv, then ran the P4 side of the
User Manual end to end - and it is the smoothest part of the whole product. The startup order
really is reversed (Mininet -> Proxy -> wait -> Kernel) and the manual says so clearly.

Everything numeric the manual promises was exactly right: **16256** destination paths,
**288** edges, **10** switches verified on gRPC 50051-50060, **0** surviving BMv2 processes
after shutdown, and both ports released.

surprised by: `pgrep -c simple_switch_grpc`  ->  `0`  while ten switches were running
  - the manual warned about this exact trap, and modern pgrep even explains itself:
  `pgrep: pattern that searches for process name longer than 15 characters will result in
  zero matches`. `ps -eo args= | grep -c '[s]imple_switch_grpc'` gave 10, as the manual says.

surprised by (the other direction): the kernel did **not** make the one failed request to
:8080 that the manual says to expect at startup. Zero. It went straight to :8081.

I also built my own mixed OVS+BMv2 topology in /tmp to test the documented refusal. The kernel
names the mixture beautifully and then serves from it anyway (BUG-17).

**A correction to my own instrumentation:** when I first tested the Step 6.6 refusal modes I
printed `(exit 0)` for all three, because I read `${PIPESTATUS[0]}` after an intervening
command. Re-measured without a pipe, the refusal exits **1**, which is correct. I nearly filed
"refuses but reports success" as a bug on the strength of my own broken measurement - the
second time in this run that my instrumentation, not the product, produced the anomaly.

verdict: 0 smooth
