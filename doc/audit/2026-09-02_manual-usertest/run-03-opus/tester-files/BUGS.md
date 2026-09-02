# BUGS.md — NDTwin, run-03, first-contact tester

Format: feature · manual page+section · steps · expected (quoted) · observed (verbatim) ·
reproduced? · severity.

---

## #1  Step 2.6.2 config block does not match the shipped file (2 of 3 knobs are not knobs)
- **feature**: configuring the customized Ryu controller
- **manual**: Installation Manual > Native-Linux Excution Environment > Step 2.6 "Configure
  deployment parameters (`static_topology_file_path`, `is_mininet`, `switch_num`)"
- **steps**:
    cd ~/Desktop/NDTwin-Kernel
    grep -n "static_topology_file_path" intelligent_router.py
    sed -n '50,60p;88,102p' intelligent_router.py
- **expected**: the manual prints a block of three assignments and says "the correct values are",
  implying you set all three:
    static_topology_file_path = Path("/home/<user>/.../StaticNetworkTopologyMininet_10Switches.json")
    is_mininet = True
    switch_num = 10
- **observed**:
    (1) the real line is wrapped in an env override and ships a hard-coded foreign home dir:
        static_topology_file_path = Path(os.environ.get(
            "NDTWIN_RYU_TOPO_FILE",
            "/home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json"))
    (2) `is_mininet` is settable but discarded. The file's own comment at line 44 says:
        "⚠️ EDITING THIS LINE DOES NOTHING. `is_mininet` is unconditionally reassigned to True
         further down in this same module-level block"
        and line 602 is indeed a second `is_mininet = True`.
    (3) there is no `switch_num = 10` to edit. It is derived:
        NDTWIN_RYU_SWITCH_NUM -> count in the topology JSON -> 10.
        The JSON declares 10 switches, so the effective value is 10 anyway.
- **reproduced?**: n/a, static inspection of the file the manual tells you to edit; stable.
- **severity**: low-medium. Nothing broke for me because the defaults land on the values the
  manual wants. But a reader who pastes the manual's three-line block over the real one loses
  the `NDTWIN_RYU_TOPO_FILE` override, and a physical-testbed reader who sets `is_mininet=False`
  gets no change and no warning. The `/home/adam` default is a leaked developer path: on any
  machine whose user is not `adam` the shipped default points at a file that does not exist.

## #2  SIM_SERVER_URL port disagrees between the Simulation Platform page and the shipped header
- **feature**: NDTwin ↔ Simulation Platform Manager integration
- **manual**: Installation Manual > NDTwin Tool > Simulation Platform Manager, "5.4 NDTwin
  Integration Check"
- **steps**:
    cd ~/Desktop/NDTwin-Kernel
    grep -n "SIM_SERVER_URL" setting/AppConfig.hpp
- **expected** (quoted from 5.4): "Update `setting/AppConfig` in the **NDTwin-Kernel** source
  code:  `std::string SIM_SERVER_URL = "http://<YOUR_SIM_IP>:8003/submit";`"
- **observed**: the header `cmake` generates on a fresh clone already contains a *different* port:
    6:    static const std::string SIM_SERVER_URL = "http://localhost:9000/submit";
  and the Demo VM page in the same manual says `simulation_platform_manager` "(serves `:9000`)".
  So two pages of the manual and the code give 9000 and one page gives 8003.
- **reproduced?**: static, stable — it is the shipped default of the tree the manual tells you
  to clone.
- **severity**: medium for anyone following 5.4 literally: it tells you to *change* a working
  default (9000) to a port (8003) that the manager does not appear to serve, and to rebuild the
  kernel to do it. Nothing in 5.4 flags that the shipped value already points somewhere.
- **note**: I did not follow 5.4 (I left AppConfig.hpp untouched), so this is a read discrepancy,
  not an observed runtime failure.

## #3  `ndt` install line fails on a fresh machine: `~/.local/bin` does not exist
- **feature**: the `ndt` launcher ("The short way: `ndt up`")
- **manual**: User Manual > NDTwin Kernel > Operate an Emulated (Software) Network >
  Native-Linux Excution Environment, section "The short way: `ndt up`"
- **steps** (on a fresh Ubuntu 24.04 where `~/.local` has never been created):
    ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt
- **expected**: the manual prints this as the only setup step and immediately goes on to
  `ndt up ovs`, `ndt status`, `ndt down`, `ndt check` as if `ndt` were now runnable.
- **observed**:
    ln: failed to create symbolic link '/home/ndt/.local/bin/ndt': No such file or directory
    LN_EXIT=1
  Evidence the directory really was absent on this machine, not deleted by me: after the very
  first `mkdir -p ~/.local/bin` I ran,
    stat -> /home/ndt/.local  birth=2026-09-02 12:57:45.932345830 +0000
  i.e. `~/.local` itself was born the same second my mkdir ran.
- **reproduced?**: yes — ran the identical line twice after removing the directory again;
  identical error and exit 1 both times.
- **workaround I used** (not in the manual): `mkdir -p ~/.local/bin` first, then the manual's
  line, which then succeeds (LN_EXIT=0).
- **second-order friction**: Ubuntu's stock `~/.profile` has
    if [ -d "$HOME/.local/bin" ] ; then PATH="$HOME/.local/bin:$PATH" ; fi
  which is evaluated **at login**. So even after creating the directory, the shell you are
  sitting in does not have `ndt` on `PATH` until you log out and back in. A new login shell
  does find it (`bash -lc 'command -v ndt'` -> /home/ndt/.local/bin/ndt).
- **severity**: medium. It is the first command of the recommended path, it fails outright, and
  the failure message says nothing about NDTwin, so a new user has no reason to connect it to
  this manual.

## #4  Network State Recorder's start script ignores the virtualenv the manual tells you to make
- **feature**: NSR background start
- **manual**: Installation Manual > NDTwin Tool > Network State Recorder, "Install libraries":
  "Note the interpreter path (`~/nsr-env/bin/python`, or the Conda equivalent) —
  `start_network_state_recorder.sh` launches the recorder with an interpreter path written
  **inside the script**, so open it once and check that path points at the environment you just
  created."
- **steps**:
    python3 -m venv ~/nsr-env ; source ~/nsr-env/bin/activate
    pip install nornir loguru orjson requests
    cat ~/Network-State-Recorder/start_network_state_recorder.sh
- **expected**: a line naming an interpreter path that I can check/repoint.
- **observed**: there is no path to check. The whole launch line is:
    nohup python3 network_state_recorder.py &
  a bare `python3`, i.e. the **system** interpreter — the one that PEP 668 just stopped me
  installing into. The dependencies are in `~/nsr-env`, so the system interpreter does not have
  them.
- **reproduced?**: static content of the shipped script (commit 850f61d); see #7 for the
  runtime consequence, which I measured separately.
- **severity**: medium. The manual's instruction cannot be carried out as written (there is no
  path in the script), and the mismatch it warns about is exactly what the shipped script has.

## #5  NSR's own stop script uses the `kill $(pgrep -f ...)` pattern its user manual warns against
- **feature**: NSR shutdown
- **manual**: User Manual > NDTwin Tools > Network State Recorder, "Stopping NSR":
  "**Do not pipe the search straight into `kill`.** Writing
   `sudo kill -15 $(pgrep -f network_state_recorder.py)` looks shorter, but it fails in three
   ways and all three are silent"
- **steps**: `cat ~/Network-State-Recorder/stop_network_state_recorder.sh`
- **observed**: the shipped script is exactly the forbidden line:
    echo $(pgrep -f network_state_recorder.py)
    sudo kill -15 $(pgrep -f network_state_recorder.py)
  and the same page offers `./stop_network_state_recorder.sh` as "Option 1" without noting that
  Option 1 does the thing the box below it tells you not to do.
- **reproduced?**: static, stable.
- **severity**: low-medium. The advice is good; the tool does not follow it, so a user who
  obeys the warning by hand is safer than one who uses the supplied script.

## #6  `--ai` without OPENAI_API_KEY aborts through an unhandled C++ exception
- **feature**: Intent Translator enable flag
- **manual**: User Manual > ... > Native-Linux Excution Environment, box "If you want the Intent
  Translator": "replace `--no-ai` with `--ai` and export a real key first, remembering `sudo -E`
  so the variable survives."
- **steps**:
    cd ~/Desktop/NDTwin-Kernel/build
    sudo ./bin/ndtwin_kernel --mode mininet \
      --topology ../setting/StaticNetworkTopologyMininet_10Switches.json --ai --loglevel info
- **expected**: the manual does not promise a specific failure, but it treats a missing key as a
  normal user mistake ("export a real key first"), which implies a diagnosable stop.
- **observed** (verbatim, trimmed):
    [info]  Initializing IntentTranslator with model: gpt-5-nano
    [error] [LLMAgent.cpp:37 LLMAgent] OPENAI_API_KEY environment variable is not set.
    terminate called after throwing an instance of 'std::runtime_error'
      what():  OPENAI_API_KEY environment variable is not set.
  i.e. it aborts (SIGABRT) rather than exiting with a status.
- **reproduced?**: yes, twice, identical output both times.
- **severity**: low. The diagnostic line above it is clear and correct, so the user is not
  actually lost; it is the exit path that is wrong. Worth noting because the same manual
  separately warns that a *different* abort message ("terminate called without an active
  exception") on shutdown is harmless — two different aborts, one page apart, is confusing.

## #7  A non-existent `--topology` file is logged as an error and the kernel starts anyway
- **feature**: `--topology` flag
- **manual**: User Manual, Terminal 3: "`--topology <path>` topology JSON to load"; and the
  Installation Manual Step 2.6 warns at length that a topology mismatch is silent and
  confusing ("the controller has no way to notice a mismatch and will simply wait for switches
  that never arrive").
- **steps**:
    sudo ./bin/ndtwin_kernel --mode mininet --topology ../setting/NOPE.json --no-ai < /dev/null
- **expected**: a missing input file is the one topology problem that *can* be detected
  cheaply, so refusing to start would be the safe behaviour.
- **observed** (verbatim, trimmed):
    [info]  Topology file: ../setting/NOPE.json
    [info]  IntentTranslator is disabled by user.
    [info]  Checking for stale NFS entries in /srv/nfs/sim
    [info]  TopologyAndFlowMonitor Run
    [info]  Collector Starts Up
    [error] [TopologyAndFlowMonitor.cpp:207 loadStaticTopologyFromFile] Cannot open topology file:  ../setting/NOPE.json
  The subsystems had already been started before the file was even opened, and the process did
  not exit at that point.
- **reproduced?**: yes.
- **severity**: medium. It produces a running kernel serving an empty model, which is exactly
  the "looks healthy, answers wrong" shape the manual warns about elsewhere. Note the two
  spaces after the colon in the error message, which suggests the path is being printed into a
  message that already ended.

## #8  The "registered" simulator binary is committed to git, so the failure the manual promises cannot happen
- **feature**: simulator registration for the Simulation Platform
- **manual**: Installation Manual > NDTwin Tool > Simulation Platform Manager, Step 5.2, the
  warning box: "⚠️ **Say `make all`, not `make`.** ... So a bare `make` regenerates a `.hpp`,
  prints nothing alarming and exits 0, having built no binary at all — **the next step then
  fails on a missing executable for a reason that looks unrelated.**"
- **steps**:
    git clone https://github.com/ndtwin-lab/Simulation-Platform-Manager.git
    git clone https://github.com/ndtwin-lab/Energy-Saving-App.git
    cd ~/Simulation-Platform-Manager && git ls-files | grep registered/
    cd ~/Energy-Saving-App && git ls-files | grep energy_saving_simulator
- **expected**: after a bare `make`, `Simulation-Platform-Manager/registered/energy_saving_simulator/1.0/executable`
  is missing, and the next step fails.
- **observed**: the first half of the warning is exactly right, the second half is not.
    (a) bare `make` in Energy-Saving-App printed only
          [GEN] include/app/settings.hpp created from include/app/settings.hpp.example
        and produced no binary — I verified this by deleting the binaries first:
          ls: cannot access 'energy_saving_simulator': No such file or directory
          ls: cannot access '../Simulation-Platform-Manager/registered/energy_saving_simulator/1.0/executable': No such file or directory
        So the manual's diagnosis of `make` is correct.
    (b) BUT on a fresh clone the executable is **not missing**, because it is checked in:
          $ git ls-files | grep registered/
          registered/energy_saving_simulator/1.0/executable
          registered/simple_sim/1.0/executable
          registered/simple_sim/1.0/simple_sim.cpp
          $ git ls-files | grep energy_saving_simulator     # in Energy-Saving-App
          energy_saving_simulator
          src/sim/energy_saving_simulator.cpp
    (c) and the committed binary is a **different** build from the one `make all` produces:
          $ git log -1 --format='%h %ci %s' -- registered/energy_saving_simulator/1.0/executable
          83d6e39 2026-01-28 16:18:39 +0800 Add demo registered Apps
          $ git show HEAD:registered/energy_saving_simulator/1.0/executable | sha256sum
          8243d24952c10fbba126dc29250646926bac79d01c53af783ff5a95df09164e5  -
          $ sha256sum registered/energy_saving_simulator/1.0/executable   # after make all
          2ed19b2c746cdac7e7b5c069d728c7f3ce60d0599e82a8c4e8b38f80e55aecd1  ...
- **reproduced?**: yes — deleted both binaries, re-ran bare `make`, both stayed absent; then
  `make all` created both (13:04, 4423240 bytes).
- **severity**: medium-high, and it is the *inverse* of the documented risk. The manual warns
  that the mistake announces itself one step later. It does not: a user who types `make`
  instead of `make all` is left with the January 2026 binary the repository ships, at exactly
  the path the platform loads from, and the platform will run it. The mistake is silent, and
  the difference between the two binaries is invisible without a checksum.
- **also**: Step 5.2's "Command Example" (`cp ./energy_saving_simulator ../Simulation-Platform-Manager/...`)
  overwrites a tracked file, so from then on `git status` in Simulation-Platform-Manager shows
  a modified binary. The manual does not mention this (it does mention the equivalent for
  `bmv2_binary_override` in the kernel repo, Step 6.6).

## #9  🔴 `modify_flow_entry` rewrites EVERY rule with the same match, including the controller's routing rule — traffic stops
- **feature**: `POST /ndt/modify_flow_entry`
- **manual**: Developer Manual > NDTwin Kernel API §11. The documented body carries a
  `"priority": 99` field, and §11 says only "Modifies an existing flow entry by matching
  criteria and applying new actions." §10 (delete) *does* explain strict vs non-strict —
  "If the request body does not include "priority", NDTwin forwards ... (non-strict delete). If
  the request body includes "priority" ... delete_strict" — but §11 has no equivalent note.
- **steps** (verbatim, on the fabric this manual builds; h98 = 10.0.0.98 on s1):
    # control: h98 reachable, one routing rule on s1
    sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.98'
      cookie=0x0, duration=364.877s, ... priority=10,ip,nw_dst=10.0.0.98 actions=output:1
    mininet> h1 ping -c 2 -W 2 10.0.0.98
      2 packets transmitted, 2 received, 0% packet loss ... rtt min/avg/max = 1.684/2.105/2.526 ms

    # install my own entry at a DIFFERENT priority
    curl -X POST -H 'Content-Type: application/json' \
      -d '{"dpid":1,"priority":99,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.98"},"actions":[{"type":"OUTPUT","port":2}]}' \
      http://localhost:8000/ndt/install_flow_entry
    sudo ovs-ofctl dump-flows s1 | grep 'nw_dst=10.0.0.98'
      ... priority=10,ip,nw_dst=10.0.0.98 actions=output:1      <- controller's, untouched. correct.
      ... priority=99,ip,nw_dst=10.0.0.98 actions=output:2      <- mine

    # modify MY entry, naming priority 99 explicitly
    curl -X POST -H 'Content-Type: application/json' \
      -d '{"dpid":1,"priority":99,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.98"},"actions":[{"type":"OUTPUT","port":7}]}' \
      http://localhost:8000/ndt/modify_flow_entry
- **expected**: only the priority-99 entry I named changes.
- **observed** (verbatim):
      ... priority=10,ip,nw_dst=10.0.0.98 actions=output:7      <- CHANGED. was output:1
      ... priority=99,ip,nw_dst=10.0.0.98 actions=output:7
    mininet> h1 ping -c 2 -W 2 10.0.0.98
      2 packets transmitted, 0 received, 100% packet loss, time 1056ms
  The controller's own routing rule was rewritten to my port, and the host became unreachable.
  `priority` in the request body is accepted and then ignored for matching.
- **reproduced?**: yes. I hit it first on 10.0.0.99 by accident, then reproduced it deliberately
  on 10.0.0.98 with a before/after ping and an untouched-neighbour control. Both hosts went from
  0% loss to 100% loss.
- **severity**: high. This is the documented way to change a flow entry, the API answers 200,
  and the visible result is a network that has silently lost a route. The same non-strict
  semantics apply to `delete_flow_entry` when `priority` is omitted — but there the manual
  *tells* you, so a reader can avoid it. For modify there is no such warning and no strict
  variant offered.
- **note**: after this test my fabric had no route to 10.0.0.98 or 10.0.0.99 from s1. Nothing
  restores it; the controller installs paths once at startup and does not re-push.

## #10  🔴 The lock API's documented 2026-08-30 fix is not in this build: a missing `type` still takes `routing_lock`
- **feature**: `POST /ndt/acquire_lock`, `/ndt/renew_lock`, `/ndt/release_lock`
- **manual**: Developer Manual > NDTwin Kernel API §27: "**`type` is required.** There is no
  default. Until 2026-08-30 a missing, malformed or unknown `type` silently acquired
  `routing_lock` — the lock that serialises writes to real switches — and answered
  `200 {"status":"locked","type":"routing_lock"}`, so a caller could hold that lock without ever
  having named it. **All three now return `400` and acquire nothing.**"
  §28 and §29 make the same claim for renew and release.
- **steps**: each request issued from a released state, against the running kernel:
    curl -X POST -H 'Content-Type: application/json' -d '{"ttl":30}'           .../ndt/acquire_lock
    curl -X POST -H 'Content-Type: application/json' -d '{}'                    .../ndt/acquire_lock
    curl -X POST -H 'Content-Type: application/json' -d '{"type":123,"ttl":30}' .../ndt/acquire_lock
    curl -X POST -H 'Content-Type: application/json' -d '{"type":"banana_lock"}' .../ndt/acquire_lock
    curl -X POST -H 'Content-Type: application/json'                             .../ndt/renew_lock
    curl -X POST -H 'Content-Type: application/json' -d '{}'                    .../ndt/release_lock
- **expected**: `400`, and no lock touched, for all of the first three shapes.
- **observed** (verbatim):
    no `type`        -> [HTTP 200]  {"status":"locked","ttl":30,"type":"routing_lock"}
    empty body `{}`  -> [HTTP 200]  {"status":"locked","ttl":5,"type":"routing_lock"}
    `"type":123`     -> [HTTP 200]  {"status":"locked","ttl":5,"type":"routing_lock"}
    `"type":"banana_lock"` -> [HTTP 423] {"error":"Lock acquisition failed","detail":"System busy or invalid lock type: banana_lock"}
    renew, no body   -> [HTTP 200]  {"status":"renewed","ttl":5,"type":"routing_lock"}   (when routing_lock was held)
    release, no type -> [HTTP 200]  {"status":"released","type":"routing_lock"}          (when routing_lock was held)
  So the pre-2026-08-30 behaviour the documentation describes as removed is exactly what this
  build does: absent or non-string `type` silently defaults to `routing_lock`. Only an *unknown
  string* is refused, and with `423`, not the documented `400`.
  Note also that `{"type":123,"ttl":30}` returned `ttl 5`, i.e. my `ttl` was dropped as well.
- **reproduced?**: yes — run twice, once interleaved and once with an explicit release between
  every request so the 200s cannot be explained by lock state.
- **severity**: high. The documentation states the fix as a completed fact with a date, so a
  reader has no reason to re-check it; and the failure mode the doc describes ("a caller could
  hold that lock without ever having named it") is exactly what still happens on the lock that
  serialises writes to real switches.

## #11  install/modify/delete flow entry: documented response body does not match the real one
- **feature**: `POST /ndt/install_flow_entry`, `/ndt/modify_flow_entry`, `/ndt/delete_flow_entry`
- **manual**: Developer Manual > NDTwin Kernel API §9/§10/§11, "#### Success * Status: 200 OK":
    {"status": "Flow installed"} / {"status": "Flow deleted"} / {"status": "Flow modified"}
- **steps**: the three curl calls in bug #9 above.
- **observed**: all three return the same body, and it is not the documented one:
    {"accepted":1,"detail":"entries accepted for programming; per-entry outcomes are reported in the kernel log, not in this response","status":"queued"}
- **reproduced?**: yes, on every one of the six such calls I made.
- **severity**: medium. A client that keys on `status == "Flow installed"` — which is what the
  API page tells you to expect — never matches. The real body is arguably *better* (it is honest
  that the write is asynchronous and that per-entry outcomes are not in the response), which
  makes this a documentation lag rather than a code fault, but a caller cannot discover the real
  contract from the manual.
- **good news worth recording**: the error path is excellent. Posting the manual's own example
  `"dpid": 106225808380928`, which does not exist on this fabric, returned
    [HTTP 404] {"error":"unknown dpid","status":"error","unknown_dpids":[106225808380928],
      "detail":"these dpids are not switches in the loaded topology; check the dpid, or that the topology file matches the running network"}
  and I confirmed it installed nothing on any of the ten switches.

## #12  Convergence check: the manual's "131 per switch" is 130 here, and its own prose says 129
- **feature**: the "How to tell it has finished, without watching the log" convergence check
- **manual**: User Manual > ... > Native-Linux Excution Environment: "each switch should carry
  one forwarding rule per destination host, plus its table-miss entry" ... "On the 128-host
  fabric that number is **131 per switch**".
- **steps**:
    for i in $(seq 1 10); do printf 's%-3s %s\n' "$i" "$(sudo ovs-ofctl dump-flows s$i | grep -c actions=)"; done
- **expected**: 131 on each switch.
- **observed**: 130 on each of the ten switches, stable across two consecutive rounds ten
  seconds apart, and again five minutes later. Composition on s1:
    128  priority=10   (one per destination host, nw_dst=10.0.0.1 .. 10.0.0.128)
      1  priority=65535 dl_dst=01:80:c2:00:00:0e dl_type=0x88cc actions=CONTROLLER:65535   (LLDP)
      1  priority=0                                                                        (table-miss)
  Ryu's own summary agrees with the 128: "install_all_pair_paths done: hosts=128 pairs=16256
  rules=1280 paths=16256" — 1280 rules / 10 switches = 128 each.
- **reproduced?**: yes, every sample.
- **severity**: low, but it is a stopping condition. The manual tells you to wait for a specific
  number; a reader who waits for 131 waits forever. The page is also self-inconsistent: its own
  description ("one per destination host, plus its table-miss entry") gives 129, the figure it
  prints is 131, and the machine says 130.

## #13  `get_cpu_utilization` and `get_memory_utilization` return byte-identical values that never change
- **feature**: `GET /ndt/get_cpu_utilization`, `GET /ndt/get_memory_utilization`
- **manual**: API §12 "Returns the current CPU utilization(%) of all up switches ... In MININET
  mode, dummy values are generated for demonstration purposes." §13 says the same for memory.
- **steps**: called both, twice, three seconds apart.
- **observed**: the two endpoints returned exactly the same object, and it did not change
  between samples:
    cpu: {"192.168.123.11":14,"192.168.123.12":54,"192.168.123.13":36,"192.168.123.14":44,"192.168.123.15":39,"192.168.123.16":56,"192.168.123.17":25,"192.168.123.18":28,"192.168.123.19":52,"192.168.123.20":26}
    mem: {"192.168.123.11":14,"192.168.123.12":54,"192.168.123.13":36,"192.168.123.14":44,"192.168.123.15":39,"192.168.123.16":56,"192.168.123.17":25,"192.168.123.18":28,"192.168.123.19":52,"192.168.123.20":26}
  (identical in sample 1 and sample 2, and identical to each other in both)
- **reproduced?**: yes, four calls.
- **severity**: low-medium. "Dummy" is documented, so the values being fake is not the surprise.
  What is not documented is that CPU and memory are the *same* dummy values, so the two endpoints
  cannot be told apart, and that they are fixed for the life of the process rather than
  "generated" per request. A demo that plots both would show two identical lines.
  The `ndt status` tool does flag half of this on its own: "note  /ndt/get_cpu_utilization is
  fabricated in MININET mode; use cpu_probe.py" — the API page does not carry that pointer.

## #14  🔴 `/ndt/simulation_completed` and `/ndt/received_a_simulation_case` report success after the forward failed
- **feature**: NDTwin -> application / simulation-platform relay
- **manual**: API §18 "Called by the external simulator when a simulation finishes. **The NDTwin
  will forward the result URL to the registered application.**" Documented success:
  `200 {"status": "result forwarded"}`. §17 likewise: `202 {"status": "Request received
  (response from simulation server)"}`.
- **steps**:
    # register an app pointing at a URL where nothing is listening
    curl -X POST -H 'Content-Type: application/json' \
      -d '{"app_name":"MyApp","simulation_completed_url":"http://127.0.0.1:9000/simulation_completed"}' \
      http://localhost:8000/ndt/app_register            ->  {"app_id":1,...}
    ss -lntp | grep ':9000'                             ->  (nothing listening)
    curl -X POST -H 'Content-Type: application/json' \
      -d '{"app_id":"1","case_id":"case_123","outputfile":"/srv/nfs/sim/1/case_123_result.json"}' \
      http://localhost:8000/ndt/simulation_completed
- **expected**: either the documented success *and* a delivered result, or an error saying the
  application could not be reached.
- **observed**: HTTP 200 `{"status":"result forwarded"}` — while the kernel's own log for the
  same request says the forward failed:
    [info] [HttpSession.cpp:1266 handleSimulationCompleted] Handle Simulation Completed
    Command failed (exit code 7): curl -s -X POST "http://127.0.0.1:9000/simulation_completed" -H "Content-Type: application/json" -d '{"app_id":"1","case_id":"case_123","outputfile":"/srv/nfs/sim/1/case_
    [info] [SimulationRequestManager.cpp:154 operator()] Forwarded simulation result, response:
  curl exit 7 is "failed to connect to host". Note the log line still says "Forwarded simulation
  result, response:" with an empty response, and the API still answered "result forwarded".
  §17 behaves the same way:
    Command failed (exit code 7): curl -s -X POST "http://localhost:9000/submit" ...
    [info] [SimulationRequestManager.cpp:128 requestSimulation] Requested simulation on http://localhost:9000/submit - response:
  and returned `202 {"status":""}` — note also that the status string is **empty**, where §17
  documents `{"status": "Request received (response from simulation server)"}`.
- **reproduced?**: yes, both endpoints, and the kernel log records the failure both times.
- **severity**: high for anyone building on this API. The caller is told the result reached the
  application when it did not, and the only way to find out is to read the kernel's stdout. It
  is the exact shape the User Manual warns about elsewhere ("A command that prints success ... is
  not evidence that it did anything").
- **note**: `/ndt/app_register` by contrast is honest and verifiable — it returned
  `{"app_id":1}`, really created `/srv/nfs/sim/1` (drwxrwxrwx), and incremented to `app_id:2`
  on the next call.

## #15  Endpoints that behaved exactly as documented, with the effect confirmed (recorded so "no bug" != "not tried")
- `POST /ndt/link_failure_detected` with a real edge: `200 {"status":"link failure processed"}`
  and `get_graph_data` flipped **both** directed edges s1->s5 and s5->s1 from `is_up=True` to
  `is_up=False`. `link_recovery_detected` flipped them back to `True`. Malformed payload
  `{"src_dpid":1}` -> `400 {"error":"Invalid link-failure payload"}`, the documented string.
- `POST /ndt/install_group_entry` / `modify_group_entry` / `delete_group_entry` on s3: verified
  with `ovs-ofctl -O OpenFlow13 dump-groups s3` —
    after install: `group_id=1,type=all,bucket=actions=output:1,bucket=actions=output:2`
    after modify : `group_id=1,type=all,bucket=actions=output:3`
    after delete : (empty)
  and the response bodies were the documented `{"status":"Group entry installed"}` etc.
- `POST /ndt/install_meter_entry` / `modify_meter_entry` / `delete_meter_entry` on s3: verified
  with `dump-meters` — `meter=1 kbps bands= type=drop rate=1000`, then `rate=2000`, then empty.
- `POST /ndt/delete_flow_entry` **with** `priority` (the strict path §10 documents): removed only
  my `priority=77` rule and left `priority=10,ip,nw_dst=10.0.0.55 actions=output:25` intact.
  This is the direct contrast that makes bug #9 a modify-specific fault.
- `POST /ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries`: installed
  `priority=77,ip,nw_dst=10.0.0.55 actions=output:3` on s2 without disturbing the priority=10 rule.
- `GET /ndt/get_average_link_usage`: returned `0.0` while the only traffic was h1<->h2, which
  share switch s1 — correct, since the doc says host-facing links are excluded. With traffic
  between h1 and h50 (three switches apart) it returned `0.45873436975000004`.
- `GET /ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.50` -> `"switch_count":3`,
  matching the path the flow endpoint reported: h1 -> s1 -> s5 -> s2 -> h50.
- `GET /ndt/get_switches_power_state?ip=9.9.9.9` -> `404 {"error":"Unknown switch IP"}` (documented).
- `GET /ndt/get_nickname` with no parameter -> `400 {"error":"Missing dpid, mac, or name parameter"}`.
- `POST` with malformed JSON -> `400 {"error":"JSON parsing error","details":"[json.exception.parse_error.101] parse error at line 1, column 10: syntax error while parsing value - unexpected end of input; expected '[', '{', or a literal"}` — the documented shape.
- `POST /ndt/historical_logging?state=enable` -> the documented MININET branch verbatim:
  `{"status":"success","recording":false,"message":"Historical data logging is enabled, but this deployment does not record: the recorder is only started outside MININET mode, so no rows will be written."}`
  and `?state=banana` -> `400 {"error":"Invalid or missing 'state' parameter. Use 'enable' or 'disable'."}`
- `POST /ndt/intent_translator/text` with the kernel started `--no-ai` -> `503
  {"error":"Intent translator is disabled; the kernel was started with --no-ai."}` — the exact
  documented string.
- `POST /ndt/modify_device_name` and `/ndt/modify_nickname`: effects confirmed three ways —
  `get_graph_data` showed `"device_name":"HstA"`, `get_nickname?dpid=1` returned
  `{"nickname":"Sinica-Switch-01"}`, and the on-disk
  `setting/StaticNetworkTopologyMininet_10Switches.json` was rewritten (`git status` shows it
  modified, and it now contains both new strings), exactly as §15 says it should.

## #16  A runtime API call dirties the git checkout, and the manual does not warn about it
- **feature**: `POST /ndt/modify_device_name` / `modify_nickname` (also reachable from the Web
  GUI's Device Information panel, which is where a normal user would hit it)
- **manual**: API §15 says it "Updates the name of a switch or host in the NDTwin topology and
  StaticNetworkTopology.json" — so the write is documented. What is not mentioned anywhere is
  that this file is a **tracked file inside the git clone**.
- **steps**:
    curl -X POST ... -d '{"vertex_type":1,"mac":"00:00:00:00:00:01","new_name":"HstA"}' .../ndt/modify_device_name
    cd ~/Desktop/NDTwin-Kernel && git status --short setting/
- **observed**:  M setting/StaticNetworkTopologyMininet_10Switches.json
- **severity**: low, but it is friction of exactly the kind the Installation Manual takes
  trouble over elsewhere: Step 6.6 explicitly warns "Editing this file leaves your working tree
  dirty — it is tracked, and `git status` will show it modified from now on. That is expected;
  do not revert it." The same warning is missing here, and here it is not even the user editing
  a file — renaming a node in the GUI silently modifies the repository.

## #17  🔴 NSR's `start_network_state_recorder.sh` exits 0, edits your config, and starts nothing
- **feature**: Network State Recorder, "Option 1: Background Mode (Recommended)"
- **manual**: User Manual > NDTwin Tools > Network State Recorder: "Use this for long-term data
  collection. It runs NSR in the background using `nohup`. `./start_network_state_recorder.sh`".
  Installation Manual for the same tool tells you to build `~/nsr-env` and `pip install nornir
  loguru orjson requests` into it.
- **steps** (exactly the documented install, then the documented start):
    python3 -m venv ~/nsr-env && source ~/nsr-env/bin/activate
    pip install nornir loguru orjson requests
    cd ~/Network-State-Recorder
    chmod +x start_network_state_recorder.sh stop_network_state_recorder.sh
    ./start_network_state_recorder.sh
- **expected**: NSR running in the background, and per the manual's own status check
  "If a line with a process ID (PID) is returned, NSR is running."
- **observed**:
    START_SCRIPT_EXIT=0
    Traceback (most recent call last):
      File "/home/ndt/Network-State-Recorder/network_state_recorder.py", line 6, in <module>
        from nornir import InitNornir
    ModuleNotFoundError: No module named 'nornir'
    $ pgrep -af network_state_recorder.py
       (NO MATCH -- nothing running)
    $ ls recorded_info/   -> No such file or directory
    $ ls logs/            -> No such file or directory
  and it had already rewritten my config on the way past:
    display_on_console: false
- **cause**: the script's launch line is `nohup python3 network_state_recorder.py &` — the
  *system* interpreter, which by PEP 668 is the one you were just prevented from installing
  into. See BUGS #4: the Installation Manual tells you to "check that path points at the
  environment you just created", but there is no path in the script to check.
- **reproduced?**: yes.
- **workaround I used** (not in the manual for this path): run the documented "Option 2"
  foreground form *inside the venv*:
    source ~/nsr-env/bin/activate && python3 network_state_recorder.py
  With that, NSR works completely — see #19.
- **severity**: high. It is the recommended start path for the tool, it reports success, it
  leaves a config change behind as evidence that "something happened", and the only signal is a
  traceback that scrolls past before the prompt returns.

## #18  NSR's `logs/` directory is never created, so the manual's monitoring command cannot work
- **feature**: NSR logging
- **manual**: User Manual > NDTwin Tools > Network State Recorder §3: "NSR logs are immediately
  written to the `./logs/` folder (not displayed in the terminal during background execution).
  **Log File Format:** `logs/NSR_YYYY-MM-DD.log`" and gives
  "**Real-time Monitoring Background NSR:** `tail -f logs/NSR_$(date +%Y-%m-%d).log`"
- **steps**: ran NSR for ~4 minutes (13:31:16 to 13:35:13) with it actively writing data, and
  listed `logs/` on every 20-second sample.
- **observed**: `logs/` never appeared. Every sample printed an empty listing:
    13:32:33  recorded_info: 2026_09_02_13-31-16_flowinfo.json 2026_09_02_13-31-16_graphinfo.json
                logs dir:
    ... (nine samples, same)
  `ls -la logs/` -> `ls: cannot access 'logs/': No such file or directory`
  So `tail -f logs/NSR_2026-09-02.log` would fail. Log output went to the console instead
  (`display_on_console` was `true` at the time).
- **reproduced?**: observed continuously across nine samples over four minutes.
- **caveat I could not settle**: I only ran the foreground path successfully, because the
  background path is broken (#17). It is possible `logs/` is only written when
  `display_on_console` is `false`. The manual does not say that — it presents file logging as
  unconditional and console display as the extra — and I could not test the combination, since
  the script that sets `display_on_console: false` is the one that fails to start the program.
- **severity**: low-medium, plus it interacts badly with #17: the two documented ways to find
  out whether NSR is running are `pgrep` (which returns nothing) and the log file (which does
  not exist).

## #19  NSR itself works — recorded so the launcher bug is not read as "the tool is broken"
Launched as `source ~/nsr-env/bin/activate && python3 network_state_recorder.py`, everything the
manual promises happened, and I checked each effect:
  - periodic collection at `request_interval: 5`:
      13:31:56 | DEBUG : Writing item with timestamp 1788355911821 to ./recorded_info/2026_09_02_13-31-16_flowinfo.json...
      13:32:00 | DEBUG : Writing item with timestamp 1788355916822 to ...
      13:32:05 | DEBUG : Writing item with timestamp 1788355921822 to ...
  - `pgrep -af network_state_recorder.py` -> `145497 python3 network_state_recorder.py`
  - naming convention exactly as documented (`YYYY_MM_DD_HH-MM-SS_<datatype>.json`):
      2026_09_02_13-31-16_flowinfo.json   2026_09_02_13-31-16_graphinfo.json
  - rotation and compression at `storage_interval: 2` minutes — the 13:31:16 pair was zipped and
    a new pair opened at 13:33:19:
      2026_09_02_13-31-16_flowinfo_json.zip (1355 B)  2026_09_02_13-31-16_graphinfo_json.zip (148852 B)
      2026_09_02_13-33-19_flowinfo.json               2026_09_02_13-33-19_graphinfo.json
  - graphinfo records match the documented shape: {"timestamp":1788355876838,"edges":[...],"nodes":[...]}
  - flowinfo records carry the live flows: {"timestamp":1788355996826,"flowinfo":[{"dst_ip":16777226,...}]}
  - with no traffic it logs `WARNING : No new data from http://127.0.0.1:8000/ndt/get_detected_flow_data.`
    rather than writing empty records — sensible, and it matches the kernel returning `[]`.
  Two small doc mismatches: the manual writes the flow record as `{"timestamp": ..., "flowinfo":{[...]}}`,
  which is not valid JSON — the real value is an array, `"flowinfo":[...]`. And §3 says data is
  "stored in the `./recorded_info/` directory", which is right, but only after the first write;
  the directory does not exist on a fresh clone.

## #20  NSR's stop script fails visibly and still exits 0 when nothing is running
- **feature**: NSR "Option 1: Using the Stop Script"
- **manual**: User Manual > NDTwin Tools > Network State Recorder: "`./stop_network_state_recorder.sh`"
- **steps**: ran it with no recorder running (which is the state the broken start script leaves
  you in — see #17).
- **observed**:
    $ ./stop_network_state_recorder.sh
    (blank line)
    Usage:
     kill [options] <pid> [...]
    ... (the whole kill(1) usage block)
    STOP_EXIT=0
  It did still flip `display_on_console` back to `true`, so the config half worked.
- **reproduced?**: yes.
- **severity**: low. It is cosmetic *here*, but it is the first of the three failure modes the
  same manual page warns about in its own box — "With **no match**, the command substitution is
  empty and the line becomes `sudo kill -15` with no argument" — demonstrated by the tool the
  page recommends. See #5.

## #21  🔴 `ndt up ovs` — the User Manual's recommended "short way" — cannot work from a by-the-manual install
- **feature**: the `ndt` launcher, `ndt up ovs`
- **manual**: User Manual > ... > Native-Linux Excution Environment, "The short way: `ndt up`".
  The entire documented setup is one line:
      ln -sf ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ~/.local/bin/ndt
  followed by a table promising `ndt up ovs` = "Ryu + Open vSwitch fabric + kernel, converged and
  verified", and the surrounding prose: "The repository ships a launcher that does everything the
  three terminals below do, in the right order".
- **steps**: after completing Installation Manual Sections 1-5 exactly, and creating the symlink
  (which itself needs BUGS #3's `mkdir -p` first):
      ndt down          # start from clean
      ndt up ovs
- **expected**: the whole stack up and verified.
- **observed** (verbatim):
      ndt up ovs
        hosts        128
        topology     setting/StaticNetworkTopologyMininet_10Switches.json
      [1/4] control plane (Ryu)
        ok  Ryu up, prompt reached
      [2/4] data plane (OVS fabric)
      sudo: /usr/local/sbin/ndtwin-lab: command not found
        XX  ovs-topo-start failed
      NDT_UP_EXIT=1
  It got one step in, failed, and left Ryu running (`:8080 ryu open` in `ndt status` afterwards).
- **cause, from the machine**:
      $ ls -l /usr/local/sbin/ndtwin-lab
      ls: cannot access '/usr/local/sbin/ndtwin-lab': No such file or directory
      $ find ~/Desktop/NDTwin-Kernel -name '*ndtwin-lab*'
      /home/ndt/Desktop/NDTwin-Kernel/tools/test_workflow/ndtwin-lab      <- it ships in the repo
      $ grep -n "usr/local/sbin/ndtwin-lab" ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt
      55:LAB=/usr/local/sbin/ndtwin-lab
      $ grep -c "ndtwin-lab" ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndt
      11
  The helper exists in the checkout, next to the `ndt` the manual tells you to symlink, but the
  `ndt` script looks for it at a fixed absolute path in `/usr/local/sbin`, and **nothing in the
  documentation installs it there**. Searching the whole docs snapshot for the name returns only
  the GitHub org in the clone URLs:
      grep -rn "ndtwin-lab" ~/ndtwin-docs/  ->  two hits, both `ndtwin-lab/NDTwin-Kernel...`
- **reproduced?**: yes. It also breaks `ndt down`, which prints the same error at steps [2/3] and
  [3/3] and still concludes "clean" (in my case the machine really was clean, because step [1/3]
  — which does not use the helper — had already stopped everything, but the verification and the
  step that failed are different things).
- **severity**: high. It is the first thing the User Manual offers, it is presented as the safe
  alternative to a three-terminal sequence that is "correct but not safe to type from memory",
  and it fails on the second of four steps on a machine built exactly to the Installation Manual.
- **workaround I used** (NOT in the manual — the manual is silent on this file):
      sudo install -m 0755 ~/Desktop/NDTwin-Kernel/tools/test_workflow/ndtwin-lab /usr/local/sbin/ndtwin-lab
  I inferred it only because the missing file sits in the same directory as the `ndt` the manual
  does tell me to link. Recording it as friction, not as resolved: a first-time reader has no
  reason to look there, and the error message names an absolute path with no hint that the file
  is in their checkout.

## #22  🔴 `ndtwin-lab ovs-topo-start` prints "OVS topo session started", exits 0, and starts nothing — this is why `ndt up ovs` fails
- **feature**: the OVS fabric step of `ndt up ovs` ([2/4] "data plane")
- **manual**: User Manual > ... > Native-Linux Excution Environment: "`ndt up ovs` | Ryu + Open
  vSwitch fabric + kernel, converged and verified" and "it **waits until the fabric has actually
  converged before telling you it is up**".
- **steps**: after installing the helper (BUGS #21's workaround), from a fully clean machine
  (`ndt down` reporting "clean", `sudo mn -c`, no bridges, all ports closed):
      ndt up ovs
  and then, to isolate the layer, the helper subcommand on its own:
      cd ~/Desktop/NDTwin-Kernel
      sudo /usr/local/sbin/ndtwin-lab ovs-topo-start
      sudo /usr/local/sbin/ndtwin-lab status
      sudo /usr/local/sbin/ndtwin-lab topo-out 60
      sudo tmux -L ndtwinlab ls
- **expected**: a running 10-switch/128-host OVS fabric.
- **observed**, `ndt up ovs` (two clean attempts, identical):
      [1/4] control plane (Ryu)
        ok  Ryu up, prompt reached
      [2/4] data plane (OVS fabric)
        XX  fabric has 0 hosts, expected 128
      NDT_UP_EXIT=1
      $ sudo ovs-vsctl list-br        ->  (empty)
      $ ps -eo args= | grep -c '[m]ininet:'  ->  0
- **observed**, the helper on its own — this is the interesting part:
      $ sudo /usr/local/sbin/ndtwin-lab ovs-topo-start
      OVS topo session started (attach: sudo tmux -L ndtwinlab attach -t topo)
      HELPER_EXIT=0
      $ sudo tmux -L ndtwinlab ls                     # 2 seconds later
      no server running on /tmp/tmux-0/ndtwinlab
      $ sudo /usr/local/sbin/ndtwin-lab topo-out 60
      ndtwin-lab: no topo session
      $ sudo /usr/local/sbin/ndtwin-lab status
      no lab sessions
      bmv2: 0  mininet: 0
      # and again 15 seconds later: same three answers
  So the helper reports a session it did not create, exits 0, and the one command it offers for
  looking at that session's output ("topo-out") answers "no topo session" — there is no
  diagnostic anywhere. Nothing is written under `.test_run/logs/` for the topology either; only
  `ryu.log` and `kernel.log` appear there.
- **not the cause**: mininet is importable as root —
      $ sudo python3 -c "import mininet; print(mininet.__file__)"
      /usr/lib/python3/dist-packages/mininet/__init__.py
  and the same topology script works perfectly when I run it by hand as the manual's Terminal 2
  (`sudo python3 testbed_topo.py` -> 10 bridges, 128 hosts, converged).
- **reproduced?**: yes — `ndt up ovs` failed 2/2 after the helper was installed (once after a
  by-hand run, once from a fully reset machine), and the helper subcommand failed 3/3.
- **severity**: high, and it compounds #21. `ndt up` does report the failure and exit 1, which is
  good. But it leaves partial state behind: after the failure `ndt status` showed
  `:8080 ryu open` and `:8000 kernel open`, with `kernel graph 10 switches (0 up, 0 enabled),
  128 hosts, 288 edges` and `links 288 total, 288 down` — a kernel serving a model of a fabric
  that does not exist.
- **what I did**: fell back to the manual's three-terminal reference procedure, which the same
  page says is "still the reference". That works end to end. So the product is usable; the
  documented shortcut is not.
