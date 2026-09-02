# NDTwin install + use journal (run-03)

Tester: graduate student, first contact with NDTwin.
Machine: fresh Ubuntu 24.04 VM, user `ndt`, passwordless sudo.
Docs: ~/ndtwin-docs (website commit bcf98f5).
Working over ssh, no desktop, no browser.

## Choice point 0 — which install path   12:34   friction: 1
what I did: Installation Manual `_index` pages are frontmatter only; on the rendered site
they are section landing pages listing children. Kernel/_index says "select the installation
path that matches your requirements". Two choices had to be made before any command:
  (a) Emulated (Software) Network vs Operate a Physical (Hardware) Network
      -> Emulated. I have one VM and no switches.
  (b) "Use the Demo VM for a Quick Start" vs "Native-Linux Excution Environment"
      -> Native-Linux. The Demo VM page requires VMware on a host machine and a .ova
      download; I am on a plain Ubuntu 24.04 box over ssh. Also the page says the
      P4/BMv2 image is "*(not yet published)*", and the standard image is explicitly
      "Not included: the P4/BMv2 data plane."
verdict: 1 confusing but worked — the choice is real and the manual does signpost it,
but neither _index page lists its children in the markdown, so on the file copy you have
to guess the menu. On the real website this is a non-issue.

## Install 1. System Requirements   started 12:35   ended 12:35   friction: 0
what I did: checked each bullet.
  lsb_release -d          -> Description:	Ubuntu 24.04.4 LTS      (manual: verified on 24.04.3)
  uname -m                -> x86_64
  sudo -n true            -> works, passwordless
  ls -ld ~/Desktop        -> No such file or directory   (manual predicts this for Server)
  df -h /                 -> 114G avail  (manual later wants >=25 GB for Section 6)
verdict: 0 smooth

## Install 2. Python Environment Setup (Ryu)   started 12:35   ended 12:40   friction: 1
what I did: Miniconda prerequisite block verbatim; `source ~/miniconda3/etc/profile.d/conda.sh`
(the "this shell only" option, since I have no new terminal to open); both `conda tos accept`
lines; `conda create -n ryu-env python=3.8 -y`; `conda activate`; python --version -> Python
3.8.20. Then 2.2 apt build deps, 2.3 pip upgrade + `pip install ryu` + the three pins, 2.4
verify, 2.5 ryu-manager test, 2.6 config, 2.7 networkx/requests/urllib3.
Step 2.4 printed exactly the four lines the manual predicts:
  dnspython 1.16.0 / eventlet 0.30.2 / greenlet 2.0.2 / ryu 4.34
Step 2.5: ran it under tmux (I have no terminal). Pane showed
  "loading app ryu.app.simple_switch_13" / "instantiating app ... of SimpleSwitch13"
and `ss -lntp` showed  LISTEN 0 50 0.0.0.0:6653 users:(("ryu-manager",pid=4212,fd=5))
so it really was serving, not just printing. Ctrl-C -> port gone. Matches the manual.
Step 2.6 sends you to Step 4.1 first, so I cloned there and came back. (git 2.43.0 was
already on the box; note Step 3.1 is the step that installs git, so a machine without it
would fail here — mine did not.)
surprised by: sed -n '36,39p' intelligent_router.py  ->
  static_topology_file_path = Path(os.environ.get(
      "NDTWIN_RYU_TOPO_FILE",
      "/home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json"))
  i.e. the file does not look like the manual's block, and it ships someone's real home
  directory as the default. See BUGS.md #1.
verdict: 1 confusing but worked — Step 2.6 asks for three values, only one of which exists
as an editable knob in the shipped file.

## Install 4.1 Download Source Code (done early, on Step 2.6's instruction)   12:38   friction: 0
what I did: the manual says "If you are not sure, clone the P4 one", so:
  mkdir -p ~/Desktop; cd ~/Desktop
  git clone https://github.com/ndtwin-lab/NDTwin-Kernel-P4-public.git NDTwin-Kernel
  -> 936f8c6c9d050f32c0ee22be58e48a7e98905ee0 2026-09-01 "Snapshot of the P4/BMv2 kernel tree..."
Step 6.0's check `ls p4_proxy/p4_src/ndtwin_switch.p4` printed the path => right repo.
verdict: 0 smooth

## Install 3. System Dependencies   started 12:40   ended 12:46   friction: 0
what I did: 3.1 and 3.2 verbatim (with the manual's `DEBIAN_FRONTEND=noninteractive`), then 3.3.
  sudo systemctl is-active openvswitch-switch  -> active
  sudo ovs-vsctl show  -> 086b5187-1834-4019-a770-b52c331a5084 / ovs_version: "3.3.9"
     (nearly empty, which the manual says is the pass here)
  sudo mn --test pingall -> `*** Results: 0% dropped (2/2 received)`  -- the exact line the
     manual tells you to read for, and it is indeed not the last line.
Versions landed: mn 2.3.0, ovs 3.3.9, cmake 3.28.3, ninja 1.11.1, libboost-dev 1.83.0.1ubuntu2
(>= the 1.83 Section 1 requires).
verdict: 0 smooth. The `DEBIAN_FRONTEND` warning was worth having; I did not hit the iperf3
debconf prompt.

## Install 4.2 Compile with Ninja   started 12:46   ended 12:51   friction: 0
what I did: rm -rf build; mkdir build && cd build; cmake -GNinja ..; ninja clean;
ninja -j 2  (nproc=4, so `$(( $(nproc) / 2 ))` = 2); then the final `cd ~/Desktop/NDTwin-Kernel`.
  CMAKE_EXIT=0  NINJACLEAN_EXIT=0  NINJA_EXIT=0
  grep -ic "error:" build log -> 0 ;  grep -ic "warning:" -> 0
  90 targets, about 13 minutes on 4 vCPUs at -j2.
  build/bin/ndtwin_kernel  (11839016 bytes)  and build/bin/test_routing_strategy
  ./build/bin/ndtwin_kernel --help -> prints usage, exit 0
Also confirmed the Step 6.0 side-claim: `cmake` did create setting/AppConfig.hpp from the
.example, and it already contains
  static const std::string P4_PROXY_IP_AND_PORT = "localhost:8081";
  static constexpr bool ALLOW_MIXED_DATAPLANE = false;
so Step 6.4 turns out to need no edit at all on a fresh clone.
verdict: 0 smooth

## Install 5. Prepare Network Topology Script   started 12:52   ended 12:52   friction: 0
what I did: `cd ~/Desktop/NDTwin-Kernel; ls -l testbed_topo.py`
  -rwxrwxr-x 1 ndt ndt 10575 Sep  2 12:38 testbed_topo.py
Nothing to create; the section is a presence check plus two warnings (run from the project
root, and expect the `Bandwidth limit 10000 is outside supported range` spam). Held onto both
for Section 5's actual use in the User Manual.
verdict: 0 smooth

## Install 6.0/6.1 P4 / BMv2 Data Plane (optional section)   started 12:52   friction: TBD
what I did: took the optional section, because Step 4.1 told me to clone the P4 repo "if you
are not sure" and I did. 6.0 check passed at clone time.
6.1: ran the red pre-check first --
  python3 --version -> Python 3.12.3 ;  CONDA_DEFAULT_ENV=[]   (no leftover ryu-env)
then, from ~ exactly as printed:
  git clone https://github.com/jafingerhut/p4-guide
  ./p4-guide/bin/install-p4dev-v8.sh |& tee log.txt
Ran it inside tmux so it has a pty (I am on ssh with no terminal). Script self-check said
  "Found supported ID ubuntu and VERSION_ID 24.04" / "Passed all sanity checks"
Started 12:53:05. The manual budgets about two hours on 4 vCPUs.
verdict: (in progress)

## Waiting on 6.1 — what I did with the two hours   12:56 - onwards   friction: n/a
Deliberate choice: I did **not** start the Open vSwitch fabric while `install-p4dev-v8.sh` was
running. It runs `sudo apt` repeatedly and clones/builds Mininet, and it saturates 4 vCPUs, so
any convergence timing or pingall result I took during it would have been unreliable — I would
have risked filing a false BROKEN. Instead I restricted myself to work that touches neither apt
nor the network stack: git clones, pip-into-venv, static file inspection, and kernel CLI
behaviour that needs no fabric. I am recording this as a deviation from strict
one-section-at-a-time because it is one.

what I did:
 - read the rest of the User Manual and the 41-endpoint Kernel API page, and wrote
   ~/CHECKLIST.md (206 lines) from them
 - NSR: cloned, made ~/nsr-env, installed the four libraries, chmod +x the scripts
 - NTG: cloned, made ~/ntg-env, installed the nine libraries
 - kernel CLI checks that need no fabric
 - staged /tmp/api_test.sh, an endpoint-by-endpoint sweep using the manual's own example bodies

surprised by: cat ~/Network-State-Recorder/start_network_state_recorder.sh  ->
  nohup python3 network_state_recorder.py &
  The Installation Manual told me to open this file and check "an interpreter path written
  inside the script". There is no path in it — it is a bare `python3`. See BUGS #4.

surprised by: ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt  ->
  ln: failed to create symbolic link '/home/ndt/.local/bin/ndt': No such file or directory
  This is the first command of the User Manual's recommended path. See BUGS #3.

surprised by: sudo ./bin/ndtwin_kernel --mode mininet --topology <valid> --ai --loglevel info  ->
  [error] [LLMAgent.cpp:37 LLMAgent] OPENAI_API_KEY environment variable is not set.
  terminate called after throwing an instance of 'std::runtime_error'
    what():  OPENAI_API_KEY environment variable is not set.
  It detects the missing key correctly and then dies through an unhandled exception rather than
  exiting cleanly. See BUGS #6.

surprised by: sudo ./bin/ndtwin_kernel --mode mininet --topology ../setting/NOPE.json --no-ai ->
  [error] ... loadStaticTopologyFromFile] Cannot open topology file:  ../setting/NOPE.json
  ...but it had already started TopologyAndFlowMonitor and FlowLinkUsageCollector and kept
  going rather than refusing. See BUGS #7.

things that behaved exactly as documented (logging these so "no bug" is distinguishable from
"never tried"):
  - `sudo ./bin/ndtwin_kernel` with no flags and stdin not a TTY ->
      "stdin is not a TTY, so --mode must be given explicitly." + usage, exit 2   (B15 WORKS)
  - `--mode banana` -> "--mode expects 'mininet' or 'testbed', got 'banana'"      (clean)
  - curl to :8000 with no kernel -> "curl: (7) Failed to connect to localhost port 8000"  (J06)
  - bare `pip install loguru` on 24.04 -> externally-managed-environment          (E03 WORKS)
  - `python network_traffic_generator.py` -> "python: command not found"          (F06 WORKS)
  - `sudo ./testbed_topo.py` in NTG -> traceback ending "from loguru import logger" (F07 WORKS)
verdict: n/a (waiting phase)

## User Manual, OVS path — Terminals 1-3   started 13:16   ended 13:21   friction: 0
what I did: the three-terminal reference procedure, in order, each in its own tmux session
(I am on ssh with no terminal; a human at a desk would use three windows).
  T1 13:16:44  ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest \
                 --ofp-tcp-listen-port 6633 --observe-link
     -> "instantiating app intelligent_router.py of IntelligentRyu", and
        LISTEN 0.0.0.0:6633 and 0.0.0.0:8080 both held by ryu-manager pid 101133
  T2 13:18:43  sudo python3 testbed_topo.py     -> `mininet>` at 13:19:28 (45 s)
     The manual's predicted noise appeared exactly: 32 occurrences of
       "Bandwidth limit 10000 is outside supported range 0..1000 - ignoring"
     and the script's own summary line
       "Host internet: OK | sFlow reachability: OK | Switch identification: OK"
  convergence: Ryu printed "Static topology initialized, all-destination paths installed." and
       "install_all_pair_paths done: hosts=128 pairs=16256 rules=1280 paths=16256 walk=0.347s"
     Switch-side check stable at 13:19:49, ~66 s after topology start.
  T3 13:20:48  sudo bin/ndtwin_kernel --mode mininet --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --no-ai --loglevel info
     -> "Data plane: ovs (10 switch(es))"
        "topology from the control plane: 10 switches, 128 hosts, 288 edges up"
        "Pulled 16256 paths from controller"
        "Server Listening on port 8000"   and ss shows 0.0.0.0:8000 LISTEN
surprised by: the manual's convergence number.
  for i in $(seq 1 10); do ... ovs-ofctl dump-flows s$i | grep -c actions=; done
    -> 130 on every switch, twice in a row (manual says 131). See BUGS #12.
verdict: 0 smooth — the reference procedure worked first time, exactly as written.

## User Manual, OVS path — Generating Traffic (Validation)   13:21   friction: 0
what I did: `h1 iperf3 -s &` then `h2 iperf3 -c h1 -t 300 &` in the Mininet CLI, then curl'd
/ndt/get_detected_flow_data from a normal shell while the transfer was running.
  -> exactly 2 records, one per direction:
       10.0.0.1:5201  -> 10.0.0.2:54764  rate_bps_last_sec=716800
       10.0.0.2:54764 -> 10.0.0.1:5201   rate_bps_last_sec=982401024
     one carries src_port 5201, the other dst_port 5201, as the manual says.
  The manual's decoder one-liner on its own example prints 10.0.0.1 from 16777226. Correct.
  Purge: I later timed it with a controlled 10 s burst — records went 2,2,2,2,2,2 then 0,
  i.e. gone between t+10 s and t+12 s after the transfer ended (manual says 15 s; my "last
  packet" instant is only good to a couple of seconds, so I read this as consistent).
verdict: 0 smooth — this is the manual's own success criterion and it passed.

## Use-and-break: the Kernel REST API (41 endpoints)   13:22 - 13:59   friction: 2
what I did: called every documented endpoint with the manual's own example bodies, then with
values of my own, and for each one looked for the effect rather than the status code —
ovs-ofctl dumps for flow/group/meter writes, get_graph_data for topology writes, the filesystem
for app_register, ping for reachability.
Most of it is genuinely good: link failure/recovery flips both directed edges and back; group
and meter install/modify/delete all land on the switch and read back correctly; strict delete
spares the routing rule; the unknown-dpid error is one of the best I have seen; malformed JSON
returns exactly the documented parse error.
Four things are not right, and two of them are serious:
surprised by: modify_flow_entry naming priority=99 changed the controller's priority=10 rule too
  sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.98'
    before: priority=10 ... actions=output:1   /  priority=99 ... actions=output:2
    after : priority=10 ... actions=output:7   /  priority=99 ... actions=output:7
  mininet> h1 ping -c 2 -W 2 10.0.0.98  ->  0% loss before, 100% loss after.  BUGS #9.
surprised by: the lock API. The API page says a missing `type` has returned 400 since 2026-08-30.
  curl -X POST -d '{"ttl":30}' .../ndt/acquire_lock
    -> [HTTP 200] {"status":"locked","ttl":30,"type":"routing_lock"}    BUGS #10.
surprised by: /ndt/simulation_completed answering "result forwarded" while its own log said
  Command failed (exit code 7): curl -s -X POST "http://127.0.0.1:9000/simulation_completed" ...
  BUGS #14.
surprised by: get_cpu_utilization and get_memory_utilization returning the identical object,
  unchanged between samples. `ndt check` independently says why:
  "/ndt/get_cpu_utilization returns 10 + hash(ip) % 50 in MININET mode -- a constant unrelated
  to load, which the Web-GUI displays as if it were real."   BUGS #13.
verdict: 2 needed a workaround — not to make the API work, but I had to stop trusting
`{"status":"..."}` bodies and check every effect on the switch or the filesystem instead.

## Use-and-break: `ndt` launcher   13:36 - 13:55   friction: 3
what I did: `ndt status`, `ndt status --check`, `ndt check`, `ndt down`, `ndt up ovs` x3.
`status`, `check` and `down` are good and honest tools — `check` refused to give a
twin-vs-/proc ratio because under 1 Mbit/s was crossing the fabric, and told me so.
`ndt up ovs` never worked:
surprised by: ndt up ovs  ->  sudo: /usr/local/sbin/ndtwin-lab: command not found / XX ovs-topo-start failed
surprised by: after installing that helper by hand from the repo, ndt up ovs ->  XX fabric has 0 hosts, expected 128
surprised by: sudo /usr/local/sbin/ndtwin-lab ovs-topo-start  ->  "OVS topo session started", exit 0
             sudo tmux -L ndtwinlab ls                        ->  no server running on /tmp/tmux-0/ndtwinlab
verdict: 3 blocked on the shortcut, then worked around by using the manual's three-terminal
reference procedure, which the same page says is "still the reference". BUGS #21, #22.

## Use-and-break: second full bring-up (do it twice)   13:56 - 13:58   friction: 0
what I did: tore everything down (`ndt down` -> "clean", `sudo mn -c`) and brought the OVS stack
up by hand a second time.
  convergence stable at t+63 s after topology start; 130 flows on every switch again.
  The host I renamed through the API in run 1 came back as "HstA" in run 2 — so
  /ndt/modify_device_name's write to StaticNetworkTopologyMininet_10Switches.json really is
  durable across restarts, as §15 says.
Then /ndt/set_switches_power_state, whose documented MININET effect is adding/removing the OVS
bridge:
  before: s1 s10 s2 s3 s4 s5 s6 s7 s8 s9
  after ?ip=192.168.123.20&action=off: s1 s2 s3 s4 s5 s6 s7 s8 s9   (s10 really gone)
  graph: s10 node is_up=False ; after action=on the bridge and ON state both come back.
verdict: 0 smooth
