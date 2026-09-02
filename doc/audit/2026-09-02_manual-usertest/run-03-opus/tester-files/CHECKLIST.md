# CHECKLIST.md — every feature/command/promise the manuals show, run-03

Outcomes: WORKS / WORKS-BUT (doc says X, saw Y) / BROKEN / NOT-TRIED (why) / PENDING
Each line records the *effect I looked for*, not just the exit status.

## A. Installation Manual — Kernel, Native Linux  (source: Native-Linux Excution Environment.md)
A01 | 1. requirements: Ubuntu 24.04 / x86_64 / sudo / Desktop-or-Server | WORKS (24.04.4, no ~/Desktop, mkdir -p handled it)
A02 | 2. Miniconda prerequisite curl+bash block | WORKS (conda 25.x installed, `conda --version` answered)
A03 | 2.1 `source ~/miniconda3/etc/profile.d/conda.sh` (this-shell-only option) | WORKS
A04 | 2.1 `conda tos accept` x2 before create | WORKS (no CondaToSNonInteractiveError followed)
A05 | 2.1 `conda create -n ryu-env python=3.8 -y` + activate | WORKS (`python --version` -> Python 3.8.20)
A06 | 2.2 apt build deps | WORKS
A07 | 2.3 pip upgrade "pip<24" "setuptools<68" wheel | WORKS
A08 | 2.3 `pip install ryu` | WORKS (ryu 4.34)
A09 | 2.3 three pins eventlet/greenlet/dnspython | WORKS
A10 | 2.4 verify: 4 expected lines | WORKS (exact match with the manual's block)
A11 | 2.5 `ryu-manager ryu.app.simple_switch_13` "does not return = success" | WORKS (effect checked: LISTEN :6653)
A12 | 2.5 Ctrl-C stops it | WORKS (port released)
A13 | 2.6.1 `ls -l intelligent_router.py` ships in repo | WORKS
A14 | 2.6.2 set static_topology_file_path | WORKS-BUT (real line is an os.environ wrapper defaulting to /home/adam) -> BUGS #1
A15 | 2.6.2 set is_mininet | BROKEN as documented (file says editing does nothing; 2nd assignment wins) -> BUGS #1
A16 | 2.6.2 set switch_num = 10 | WORKS-BUT (no such knob; derived from topology JSON -> 10) -> BUGS #1
A17 | 2.7 networkx / requests<2.29 / urllib3<2 | WORKS (3.1 / 2.28.2 / 1.26.20)
A18 | 3 preamble `conda deactivate` + python3 3.12 check | WORKS
A19 | 3.1 build tools incl. DEBIAN_FRONTEND note | WORKS (no debconf stall)
A20 | 3.2 libs + mininet + openvswitch-switch | WORKS
A21 | 3.3 `systemctl is-active openvswitch-switch` | WORKS (active)
A22 | 3.3 `ovs-vsctl show` answers, near-empty | WORKS
A23 | 3.3 `sudo mn --test pingall` -> 0% dropped (2/2) | WORKS (exact line found)
A24 | 4.1 clone choice OVS-only vs P4-public | WORKS (chose P4-public per "if unsure")
A25 | 4.1 `mkdir -p ~/Desktop` needed on Server | WORKS (dir really was absent)
A26 | 4.2 cmake -GNinja / ninja clean / ninja -j nproc/2 | WORKS (0 errors, 0 warnings, 13 min)
A27 | 4.2 build/bin/ndtwin_kernel produced | WORKS
A28 | 5 `ls -l testbed_topo.py` ships in repo | WORKS
A29 | 6.0 `ls p4_proxy/p4_src/ndtwin_switch.p4` right-repo check | WORKS
A30 | 6.1 install-p4dev-v8.sh from ~ | PENDING
A31 | 6.1 verify `simple_switch_grpc --version` | PENDING
A32 | 6.1 verify `p4c-bm2-ss --version` | PENDING
A33 | 6.1 claim: `which mn` stays packaged 2.3.0 | PENDING
A34 | 6.1 claim: `ldd build/bin/ndtwin_kernel | grep /usr/local` prints nothing | PENDING
A35 | 6.2 p4c-bm2-ss compiles ndtwin_switch.p4 -> json + p4info | PENDING
A36 | 6.3 `python3 -m venv p4_proxy/venv` + requirements | PENDING
A37 | 6.4 AppConfig.hpp has P4_PROXY_IP_AND_PORT / ALLOW_MIXED_DATAPLANE | WORKS (already correct on fresh clone; no edit needed)
A38 | 6.5 `echo 128 > p4_proxy/mininet/host_count_override` | PENDING
A39 | 6.5 claim: p4_testbed_topo.py refuses to start if sizes disagree | PENDING (deliberate mismatch test)
A40 | 6.6 bmv2_binary_override: 4-row behaviour table (fast path / commented / deleted / stock) | PENDING (try all four)
A41 | 6.6 the grep+[-x] verification snippet | PENDING
A42 | 6.7 optional bmv2-fast performance build | NOT-TRIED (optional; ~1h more build, out of time budget)

## B. User Manual — Kernel, OVS path  (source: UM Native-Linux Excution Environment.md)
B01 | `ln -sf .../tools/test_workflow/ndt ~/.local/bin/ndt` | PENDING
B02 | `ndt up ovs` -> converged and verified | PENDING
B03 | `ndt status` -> what runs + "three settings that silently decide every number" | PENDING
B04 | `ndt down` -> stack, session, mn -c, "proves the machine is clean" | PENDING
B05 | `ndt check` -> telemetry double-count + fake-CPU reminder | PENDING
B06 | `ndt claim` / NDT_OWNER | PENDING
B07 | `ndt up` (no arg) = P4 fabric | PENDING
B08 | Terminal 1: ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link | PENDING
B09 | Terminal 2: `sudo python3 testbed_topo.py` builds 10sw/128host fabric | PENDING
B10 | claim: expect "Bandwidth limit 10000 is outside supported range" spam | PENDING
B11 | claim: wait for "all-destination paths installed", ~80-85 s | PENDING
B12 | convergence check: per-switch `ovs-ofctl dump-flows sN | grep -c actions=` == 131 | PENDING
B13 | Terminal 3: kernel `--mode mininet --topology ...Mininet_10Switches.json --no-ai --loglevel info` | PENDING
B14 | claim: omitting flags -> 3 interactive prompts on a TTY | PENDING
B15 | claim: no TTY + missing flags -> usage message, not block | PENDING
B16 | `--ai` without OPENAI_API_KEY | PENDING (curiosity variation)
B17 | traffic: `h1 iperf3 -s &` / `h2 iperf3 -c h1 -t 300 &` in mininet CLI | PENDING
B18 | `curl -X GET http://localhost:8000/ndt/get_detected_flow_data` -> 2 records, one per direction | PENDING
B19 | claim: IPs are integers; the struct.pack decoder prints 10.0.0.1 | PENDING
B20 | claim: flow purged 15 s after last packet -> [] | PENDING (time it)
B21 | shutdown: mininet `exit`, then `sudo mn -c` | PENDING
B22 | claim: `mn -c` also kills ryu-manager | PENDING
B23 | claim: kernel prints "terminate called without an active exception" after "All subsystems stopped." | PENDING

## C. User Manual — Kernel, P4/BMv2 path
C01 | pre-flight 4 checks incl. the `[ -x "$p" ]` snippet | PENDING
C02 | Terminal 1 `sudo python3 p4_proxy/mininet/p4_testbed_topo.py` | PENDING
C03 | claim: "All 10 BMv2 switches verified listening on gRPC 50051 ~ 50060" | PENDING
C04 | claim: /tmp/ndtwin_p4_switches.json manifest lists only verified switches | PENDING
C05 | Terminal 2 proxy: `PYTHONPATH="$PWD" venv/bin/python proxy_agent/main.py`, listens 8081 | PENDING
C06 | claim: proxy must run with p4_proxy as cwd | PENDING (run it from elsewhere on purpose)
C07 | `curl .../ryu_server/all_destination_paths` count -> 16256 (128*127) | PENDING
C08 | claim: 4-host fabric settles at 12 | PENDING
C09 | Terminal 3 kernel with P4 topology -> 10 switches, 288 edges | PENDING
C10 | claim: 4-host model reports 40 edges | PENDING
C11 | claim: one failed request to 8080 at startup is expected | PENDING
C12 | P4 traffic validation + get_detected_flow_data | PENDING
C13 | shutdown: `ps -eo args= | grep -c '[s]imple_switch_grpc'` | PENDING
C14 | claim: `pgrep -c simple_switch_grpc` reports 0 even with 10 running | PENDING
C15 | claim: `ss -ltn | grep 8081` released only if Ctrl-C in own terminal | PENDING

## D. NDTwin Kernel REST API (Developer Manual, 41 endpoints) — all against :8000
D01 | POST /ndt/link_failure_detected | PENDING
D02 | POST /ndt/link_recovery_detected | PENDING
D03 | GET /ndt/get_graph_data | PENDING
D04 | GET /ndt/get_detected_flow_data | PENDING
D05 | GET /ndt/get_switch_openflow_table_entries | PENDING
D06 | GET /ndt/get_power_report | PENDING
D07 | GET /ndt/get_switches_power_state | PENDING
D08 | POST /ndt/set_switches_power_state | PENDING
D09 | POST /ndt/install_flow_entry | PENDING
D10 | POST /ndt/delete_flow_entry | PENDING
D11 | POST /ndt/modify_flow_entry | PENDING
D12 | GET /ndt/get_cpu_utilization | PENDING
D13 | GET /ndt/get_memory_utilization | PENDING
D14 | GET /ndt/inform_switch_entered | PENDING
D15 | POST /ndt/modify_device_name | PENDING
D16 | POST /ndt/app_register | PENDING
D17 | POST /ndt/received_a_simulation_case | PENDING
D18 | POST /ndt/simulation_completed | PENDING
D19 | GET /ndt/get_nickname | PENDING
D20 | POST /ndt/modify_nickname | PENDING
D21 | GET /ndt/get_temperature | PENDING
D22 | GET /ndt/get_path_switch_count | PENDING
D23 | POST /ndt/install_flow_entries_modify_flow_entries_and_delete_flow_entries | PENDING
D24 | GET /ndt/get_average_link_usage | PENDING
D25 | POST /ndt/get_total_input_traffic_load_passing_a_switch | PENDING
D26 | POST /ndt/get_num_of_flows_passing_a_switch | PENDING
D27 | POST /ndt/acquire_lock | PENDING
D28 | POST /ndt/renew_lock | PENDING
D29 | POST /ndt/release_lock | PENDING
D30 | GET /ndt/get_detected_top_k_flow_data | PENDING
D31 | POST /ndt/install_group_entry | PENDING
D32 | POST /ndt/modify_group_entry | PENDING
D33 | POST /ndt/delete_group_entry | PENDING
D34 | POST /ndt/install_meter_entry | PENDING
D35 | POST /ndt/modify_meter_entry | PENDING
D36 | POST /ndt/delete_meter_entry | PENDING
D37 | GET /ndt/get_openflow_capacity | PENDING
D38 | GET /ndt/get_static_topology_json | PENDING
D39 | POST /ndt/historical_logging | PENDING
D40 | POST /ndt/inform_all_destination_paths | PENDING
D41 | POST /ndt/intent_translator/text | PENDING
D42 | error paths: malformed JSON -> documented 400; unknown edge -> 404 | PENDING

## E. Tool — Network State Recorder (install + user manual)
E01 | clone Network-State-Recorder, cd into it | PENDING
E02 | venv ~/nsr-env + pip nornir loguru orjson requests | PENDING
E03 | claim: bare pip on 24.04 fails with externally-managed-environment | PENDING
E04 | claim: start script has an interpreter path written inside it — check it | PENDING
E05 | chmod +x the two scripts | PENDING
E06 | setting/recorder_setting.yaml fields | PENDING
E07 | `./start_network_state_recorder.sh` background mode | PENDING
E08 | claim: start script flips display_on_console to false | PENDING
E09 | `python3 network_state_recorder.py` foreground mode | PENDING
E10 | `pgrep -af network_state_recorder.py` status check | PENDING
E11 | `./stop_network_state_recorder.sh` | PENDING
E12 | claim: stop script flips display_on_console back to true | PENDING
E13 | effect: ./recorded_info/ files named YYYY_MM_DD_HH-MM-SS_<datatype>.json | PENDING
E14 | effect: _json.zip compressed archives appear per storage_interval | PENDING
E15 | effect: logs/NSR_YYYY-MM-DD.log exists and grows | PENDING
E16 | JSON structure: flowinfo / graphinfo records with timestamp | PENDING
E17 | troubleshooting row: "NDTwin kernel is not reachable" when kernel down | PENDING

## F. Tool — Network Traffic Generator
F01 | venv ~/ntg-env + the 9 pip packages | PENDING
F02 | clone Network-Traffic-Generator | PENDING
F03 | NTG.yaml host_file -> ./setting/Mininet.yaml | PENDING
F04 | setting/Mininet.yaml fields (mode cli/custom_command) | PENDING
F05 | run `~/ntg-env/bin/python network_traffic_generator.py` | PENDING
F06 | claim: `python ...` -> "python: command not found" on clean 24.04 | PENDING
F07 | claim: `sudo ./testbed_topo.py` -> ModuleNotFoundError: loguru | PENDING
F08 | flow_template.json / dist_template.json used with `flow --config` | PENDING
F09 | tab/arrow syntax+path completion in the CLI | PENDING
F10 | claim: interrupt shuts NTG down entirely | PENDING

## G. Tool — Web GUI (Docker)
G01 | install docker-ce + compose plugin per the manual's steps | PENDING
G02 | claim: `sudo chmod a+r /etc/apt/keyrings/docker.asc` (manual writes .gpg then chmods .asc) | PENDING
G03 | clone Web-GUI; cp .env.example .env; set NDT_API_BASE_URL | PENDING
G04 | `./web_gui_deploy.sh` | PENDING
G05 | effect: frontend answers on :3000, db on :5433 | PENDING
G06 | `docker-compose ps` shows postgres, node-positions-api, frontend Up | PENDING
G07 | `docker-compose logs -f`, restart, down, down -v | PENDING
G08 | GUI features (topology, flow table, availability status, assistant) | NOT-TRIED (needs a real browser)
G09 | db backup/restore via pg_dump | PENDING

## H. Tool — Network Traffic Visualizer
H01 | clone + `git checkout b5e039c` | PENDING
H02 | claim: tip of main fails with "cannot find symbol: variable WindowStateRestore" | PENDING
H03 | JDK 21 present / `./mvnw -version` | PENDING
H04 | `./mvnw clean package` -> two jars in target/ | PENDING
H05 | claim: `java -jar original-...jar` -> "no main manifest attribute" | PENDING
H06 | claim: `java -jar NDTanimation-...jar` -> "JavaFX runtime components are missing" | PENDING
H07 | `./network_traffic_visualizer.sh` | NOT-TRIED (needs a display; manual says it exits headless)
H08 | GUI features (fat-tree layout, flow animation, top-K, playback) | NOT-TRIED (needs a real display)

## I. Tool — Simulation Platform Manager + Energy-Saving-App
I01 | clone both repos as siblings | PENDING
I02 | apt deps (already satisfied by Section 3) | PENDING
I03 | NFS server: nfs-kernel-server, /srv/nfs/sim, /etc/exports, restart | PENDING
I04 | NFS client mount points /mnt/nfs/sim and /mnt/nfs/app | PENDING
I05 | settings.hpp.example -> settings.hpp for both repos | PENDING
I06 | `make all` in Energy-Saving-App -> binary + registered/.../1.0/executable | PENDING
I07 | claim: bare `make` builds no binary and exits 0 | PENDING
I08 | `make all` in Simulation-Platform-Manager | PENDING
I09 | `sudo ./simulation_platform_manager` -> "Server started" | PENDING
I10 | claim: needs /mnt/nfs/sim to already exist | PENDING

## J. Cross-cutting / curiosity variations
J01 | run the whole OVS bring-up twice (stop and start again) | PENDING
J02 | start things in the WRONG order (topology before Ryu) and look for the documented symptom | PENDING
J03 | use a topology JSON of a different size than the fabric | PENDING
J04 | kernel against a P4 topology while an OVS fabric is up (mixed-dataplane error claim) | PENDING
J05 | two kernels at once / port 8000 already bound | PENDING
J06 | API calls while the kernel is NOT running | PENDING
