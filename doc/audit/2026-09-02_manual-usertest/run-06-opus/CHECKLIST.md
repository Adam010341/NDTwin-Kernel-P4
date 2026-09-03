# CHECKLIST.md
(built from the User Manual once I have read it; install-phase lines added as I go)

Outcome key: WORKS / WORKS-BUT (doc says X, saw Y) / BROKEN / NOT-TRIED (why)
Every line records the *effect* I looked for, not just the exit status.

## A. Installation Manual - Native-Linux Execution Environment

| # | Item | Effect I checked | Outcome |
|---|---|---|---|
| A1 | Miniconda prerequisite block (4 cmds) | `conda --version` prints | |
| A2 | 2.1 `source conda.sh` (2nd of 2 offered ways) | `conda --version` = 26.7.1 | |
| A3 | 2.1 `conda tos accept` x2 | next `conda create` does not raise CondaToSNonInteractiveError | |
| A4 | 2.1 `conda create -n ryu-env python=3.8` | `python --version` = 3.8.x | |
| A5 | 2.2 apt build deps | apt exit 0 | |
| A6 | 2.3 pip upgrade pip<24/setuptools<68/wheel | versions installed | |
| A7 | 2.3 `pip install ryu` | ryu 4.34 in pip list | |
| A8 | 2.3 pins eventlet/greenlet/dnspython | exact versions | |
| A9 | 2.4 verify block | output matches manual's 4 expected lines | |
| A10 | 2.5 `ryu-manager ryu.app.simple_switch_13` | banner + does not return; Ctrl-C stops it | |
| A11 | 2.6 controller ships in repo (`ls -l intelligent_router.py`) | file present | |
| A12 | 2.6(1) `NDTWIN_RYU_TOPO_FILE` env override | ryu loads named topology | |
| A13 | 2.6(2) `is_mininet` assigned twice, 2nd wins | two assignments present in file | |
| A14 | 2.6(3) `switch_num` derived not assigned | no `switch_num = 10` line | |
| A15 | 2.7 networkx + requests<2.29 + urllib3<2 | versions installed | |
| A16 | 3 preamble `conda deactivate` | `python3 --version` = 3.12.x | |
| A17 | 3.1 build tools + DEBIAN_FRONTEND | no debconf prompt, apt 0 | |
| A18 | 3.2 libs + mininet + ovs | apt 0 | |
| A19 | 3.3 `systemctl is-active openvswitch-switch` | prints `active` | |
| A20 | 3.3 `ovs-vsctl show` | version line, no error | |
| A21 | 3.3 `sudo mn --test pingall` | `*** Results: 0% dropped (2/2 received)` | |
| A22 | 4.1 clone P4-public into NDTwin-Kernel | tree present | |
| A23 | 4.2 cmake -GNinja + ninja clean + ninja -j2 | `build/bin/ndtwin_kernel` exists | |
| A24 | 5 `testbed_topo.py` ships in repo | file present, executable | |
| A25 | 6.0 `ls p4_proxy/p4_src/ndtwin_switch.p4` | prints path | |
| A26 | 6.1 p4-guide install-p4dev-v8.sh | `simple_switch_grpc --version`, `p4c-bm2-ss --version` answer | |
| A27 | 6.1 `ldd build/bin/ndtwin_kernel \| grep /usr/local` prints nothing | verify no shadowing | |
| A28 | 6.1 `which mn` still packaged mininet | path check | |
| A29 | 6.2 compile pipeline with p4c-bm2-ss | ndtwin_switch.json + .p4info.txt exist | |
| A30 | 6.3 `python3 -m venv p4_proxy/venv` + reqs | `venv/bin/python --version` = 3.12.x | |
| A31 | 6.4 AppConfig.hpp P4_PROXY_IP_AND_PORT | file contains the two settings | |
| A32 | 6.5 `echo 128 > host_count_override` | file contains 128 | |
| A33 | 6.6 bmv2_binary_override edit + verify snippet | prints OK: exists and is executable | |
| A34 | 6.6 table: comment out the line -> refuses | error message names "no directive line" | |
| A35 | 6.6 table: delete the file -> refuses | error names "no bmv2 binary override" | |
| A36 | 6.7 (optional) bmv2-fast performance build | NOT-TRIED unless time allows | |

## B. User Manual - Kernel, Open vSwitch path (three terminals)

| # | Item | Effect I checked | Outcome |
|---|---|---|---|
| B1 | Terminal 1 `ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest --ofp-tcp-listen-port 6633 --observe-link` | listening on 6633 | |
| B2 | Terminal 2 `sudo python3 testbed_topo.py` | mininet prompt, 10 switches | |
| B3 | Doc claim: `Bandwidth limit 10000 is outside supported range` appears | message present in output | |
| B4 | Terminal 2 wait for `all-destination paths installed` | line present in Ryu log | |
| B5 | Convergence check loop `ovs-ofctl dump-flows s$i \| grep -c actions=` | manual says **130 per switch** on 128-host fabric | |
| B6 | Ryu `install_all_pair_paths done: ... rules=1280` | line present | |
| B7 | Terminal 3 kernel with 3 flags | kernel starts, binds :8000 | |
| B8 | Kernel interactive prompt when flags omitted (has tty) | 3 questions appear | |
| B9 | Kernel exits with usage message when piped/no tty and flags omitted | usage message | |
| B10 | `--help` full flag list | prints | |
| B11 | Validation: `h1 iperf3 -s &` / `h2 iperf3 -c h1 -t 300 &` | transfer runs | |
| B12 | `curl .../ndt/get_detected_flow_data` while running | **two** records, one per direction, ports 5201 | |
| B13 | Doc claim: addresses are integers; decode 16777226 -> 10.0.0.1 | decoder one-liner output | |
| B14 | Doc claim: flow purged 15 s after last packet -> `[]` | query after transfer ends | |
| B15 | Shutdown: `exit` in mininet, `sudo mn -c` | clean | |
| B16 | Doc claim: `mn -c` also kills ryu-manager | Ryu pane dies | |
| B17 | Doc claim: kernel prints `terminate called without an active exception` after `All subsystems stopped. Exiting.` on Ctrl-C | last lines of pane | |
| B18 | Restart the whole stack a 2nd time (do it twice) | comes up again | |

## C. `ndt` launcher (User Manual "The short way")

| # | Item | Effect I checked | Outcome |
|---|---|---|---|
| C1 | install `ndt` symlink + `mkdir -p ~/.local/bin` | `ndt` on PATH in `bash -l` | |
| C2 | `sudo install ... ndtwin-lab /usr/local/sbin/` | root-owned 755 file | |
| C3 | sudoers.d NOPASSWD line | `sudo -n /usr/local/sbin/ndtwin-lab` runs | |
| C4 | Doc claim: `ndt up` fails on hardcoded /home/adam paths | error `XX fabric has 0 hosts, expected 128` | |
| C5 | `ndt --help` | lists the commands | |
| C6 | `ndt status` | prints what is running + 3 override files | |
| C7 | `ndt status --check` | non-zero on untrustworthy state | |
| C8 | `ndt down` | proves machine clean | |
| C9 | `ndt clean` | exit 1 if anything survived | |
| C10 | `ndt check` | telemetry double-count tripwire | |
| C11 | `ndt claim` / `ndt release` (needs NDT_OWNER) | claim recorded | |
| C12 | `ndt apps` / `ndt apps orphans` | app state | |
| C13 | `ndt up ovs` | converged OVS fabric | |
| C14 | `ndt down --deep` | frees 8000/8080/8081 | |

## D. Kernel REST API (Developer Manual, 41 routes, port 8000)

| # | Endpoint | Effect I checked | Outcome |
|---|---|---|---|
| D1 | POST /ndt/link_failure_detected | 200 + edge marked DOWN in get_graph_data | |
| D2 | POST /ndt/link_recovery_detected | 200 + edge back UP | |
| D3 | GET /ndt/get_graph_data | nodes+edges, vertex_type 0/1 | |
| D4 | GET /ndt/get_detected_flow_data | see B12 | |
| D5 | GET /ndt/get_switch_openflow_table_entries | per-dpid flows, compare with ovs-ofctl | |
| D6 | GET /ndt/get_power_report | watt values (random in mininet) | |
| D7 | GET /ndt/get_switches_power_state (all + ?ip=) | ON/OFF map | |
| D8 | POST /ndt/set_switches_power_state?ip=&action= | doc: removes/adds OVS bridge - check ovs-vsctl | |
| D9 | POST /ndt/install_flow_entry | rule appears in ovs-ofctl dump-flows | |
| D10 | POST /ndt/delete_flow_entry | rule gone from switch | |
| D11 | POST /ndt/modify_flow_entry | rule changed on switch | |
| D12 | GET /ndt/get_cpu_utilization | doc says dummy in mininet | |
| D13 | GET /ndt/get_memory_utilization | doc says dummy in mininet | |
| D14 | GET /ndt/inform_switch_entered?dpid= | 200 + switch up | |
| D15 | POST /ndt/modify_device_name | name changed in get_graph_data | |
| D16 | POST /ndt/app_register | app_id returned; NFS folder created | |
| D17 | POST /ndt/received_a_simulation_case | | |
| D18 | POST /ndt/simulation_completed | | |
| D19 | GET /ndt/get_nickname (dpid/mac/name) | nickname returned | |
| D20 | POST /ndt/modify_nickname | nickname changes, readback | |
| D21 | GET /ndt/get_temperature | | |
| D22 | GET /ndt/get_path_switch_count (with + without IPs) | switch_count | |
| D23 | POST /ndt/install_flow_entries_modify..._and_delete... | combined op on switch | |
| D24 | GET /ndt/get_average_link_usage | avg_link_usage | |
| D25 | POST /ndt/get_total_input_traffic_load_passing_a_switch | bps sum | |
| D26 | POST /ndt/get_num_of_flows_passing_a_switch | flow count | |
| D27 | POST /ndt/acquire_lock (valid type) | 200 locked | |
| D27b | POST /ndt/acquire_lock (missing/bad type) | doc: 400 and NO lock acquired | |
| D28 | POST /ndt/renew_lock | 200 | |
| D29 | POST /ndt/release_lock | 200 | |
| D30 | GET /ndt/get_detected_top_k_flow_data | sorted desc by pkt rate | |
| D31 | POST /ndt/install_group_entry | OVS: works / P4: doc says 501 | |
| D32 | POST /ndt/modify_group_entry | as above | |
| D33 | POST /ndt/delete_group_entry | as above | |
| D34 | POST /ndt/install_meter_entry | as above | |
| D35 | POST /ndt/modify_meter_entry | as above | |
| D36 | POST /ndt/delete_meter_entry | as above | |
| D37 | GET /ndt/get_openflow_capacity | static catalogue, OVS/Brocade/HPE | |
| D38 | GET /ndt/get_static_topology_json | dotted-quad, no live state | |
| D39 | POST /ndt/historical_logging?state=enable/disable | doc: read `recording`, not `status` | |
| D40 | POST /ndt/inform_all_destination_paths | feeds get_path_switch_count | |
| D41 | POST /ndt/intent_translator/text | doc: 503 with --no-ai | |

## E. User Manual - P4 / BMv2 path (reverse startup order)

| # | Item | Effect I checked | Outcome |
|---|---|---|---|
| E1 | Pre-flight 4-item check block | all four pass | |
| E2 | Terminal 1 `sudo python3 p4_proxy/mininet/p4_testbed_topo.py` | `All 10 BMv2 switches verified listening on gRPC 50051 ~ 50060` | |
| E3 | Manifest `/tmp/ndtwin_p4_switches.json` lists 10 | json.tool output | |
| E4 | Terminal 2 proxy agent on :8081 | listening | |
| E5 | `curl :8081/ryu_server/all_destination_paths` count | doc: **16256** for 128 hosts (12 for 4-host) | |
| E6 | Terminal 3 kernel with P4 topology | doc: 10 switches, **288 edges** (4-host = 40) | |
| E7 | Doc claim: one failed request to 8080 at startup, self-healing | log line | |
| E8 | P4 traffic validation via get_detected_flow_data | two records | |
| E9 | Group/meter endpoints return 501 in P4 mode | verbatim body | |
| E10 | Shutdown steps 1-7 incl. `ps -eo args= \| grep -c '[s]imple_switch_grpc'` | counts | |
| E11 | Doc claim: `pgrep -c simple_switch_grpc` reports 0 even with 10 running | compare both | |
| E12 | `ss -ltn \| grep 8081` released | | |
| E13 | `ss -tln \| grep :8000` released | | |
| E14 | Mixed OVS+BMv2 topology refused | kernel logs error naming the mixture | |

## F. NDTwin Tools

| # | Item | Effect I checked | Outcome |
|---|---|---|---|
| F1 | NSR install: clone + venv + pip nornir loguru orjson requests | imports | |
| F2 | NSR `chmod +x` the two scripts | | |
| F3 | NSR `setting/recorder_setting.yaml` defaults | file present | |
| F4 | NSR `./start_network_state_recorder.sh` | doc: flips display_on_console to false; files in ./recorded_info/ | |
| F5 | NSR status `pgrep -af network_state_recorder.py` | pid listed | |
| F6 | NSR data files named `YYYY_MM_DD_HH-MM-SS_<type>.json` (+ _json.zip) | ls recorded_info | |
| F7 | NSR flowinfo/graphinfo NDJSON shape | head of file | |
| F8 | NSR logs `logs/NSR_YYYY-MM-DD.log` | file exists | |
| F9 | NSR `./stop_network_state_recorder.sh` | doc: flips display_on_console back to true; process gone | |
| F10 | NSR foreground mode (`python3 network_state_recorder.py`) | logs on console | |
| F11 | NSR troubleshooting row: unreachable kernel -> "NDTwin kernel is not reachable" | kill kernel, run NSR | |
| F12 | NTG install: venv --system-site-packages + pip libs | `import mininet` works from that venv | |
| F13 | NTG clone | tree matches Files Overview | |
| F14 | NTG `NTG.yaml` host_file -> ./setting/Mininet.yaml | edit | |
| F15 | NTG CLI starts (`~/ntg-env/bin/python network_traffic_generator.py`) | prompt | |
| F16 | NTG `flow --config flow_template.json` | flows generated; visible in get_detected_flow_data | |
| F17 | NTG `dist --config dist_template.json` | needs 3 csv distribution files | |
| F18 | NTG `exit` | returns | |
| F19 | NTG doc claim: bare `sudo ./testbed_topo.py` -> ModuleNotFoundError: loguru | reproduce | |
| F20 | NTG syntax/path completion (tab) | NOT-TRIED-able over ssh? try in tmux | |
| F21 | Simulation Platform: NFS server setup /srv/nfs/sim | exportfs | |
| F22 | Simulation Platform: mount points /mnt/nfs/sim + /mnt/nfs/app | dirs | |
| F23 | Energy-Saving-App `make all` builds + registers simulator | executable in registered/.../1.0/executable | |
| F24 | Doc claim: bare `make` builds no binary but exits 0 | reproduce | |
| F25 | Simulation-Platform-Manager `make all` | binary | |
| F26 | `sudo ./simulation_platform_manager` -> "Server started" on :9000 | port listening | |
| F27 | Web GUI: docker install + `.env` NDT_API_BASE_URL | | |
| F28 | Web GUI `./web_gui_deploy.sh` | frontend :3000, db :5433 | |
| F29 | Web GUI `docker-compose ps` shows 3 services Up | | |
| F30 | Web GUI page loads (curl status + title) | | |
| F31 | Web GUI rendered features (topology drag, panels, Assistant) | NOT-TRIED (needs a real browser) | |
| F32 | Visualizer: `apt install openjdk-21-jdk`, `git checkout b5e039c` | java -version 21 | |
| F33 | Visualizer `./mvnw clean package` | NDTanimation-1.0-SNAPSHOT.jar | |
| F34 | Visualizer doc claim: tip of main fails with `cannot find symbol: WindowStateRestore` | reproduce | |
| F35 | Visualizer `./network_traffic_visualizer.sh` | headless: doc says starts then exits | |
| F36 | Visualizer `java -jar original-...jar` -> `no main manifest attribute` | reproduce | |

---
# OUTCOMES (appended as I completed each line; earlier tables above are the plan)

## A. Installation Manual - outcomes
| # | Outcome | Evidence / what I actually checked |
|---|---|---|
| A1 | WORKS | `conda 26.7.1` (`~/logs/sec21-ryuenv.log`) |
| A2 | WORKS | manual offers two ways; took `source ~/miniconda3/etc/profile.d/conda.sh` |
| A3 | WORKS | both `conda tos accept` succeeded; no `CondaToSNonInteractiveError` after |
| A4 | WORKS | `Python 3.8.20` |
| A5 | WORKS | `STEP22_EXIT=0` (`~/logs/sec22-ryu-install.log`) |
| A6 | WORKS | `Successfully installed pip-23.3.2 setuptools-67.8.0 wheel-0.45.1` |
| A7 | WORKS | `ryu 4.34` |
| A8 | WORKS | eventlet 0.30.2, greenlet 2.0.2, dnspython 1.16.0 |
| A9 | WORKS | output matched the manual's 4 expected lines exactly (`~/logs/sec24-verify.log`) |
| A10 | WORKS | banner printed, process did not return, Ctrl-C returned the prompt (`~/logs/sec25-ryu-test.txt`) |
| A11 | WORKS | `-rw-rw-r-- 1 ndt ndt 114953 ... intelligent_router.py` |
| A12 | WORKS | exported it; Ryu loaded 128 hosts / 16256 pairs from that file |
| A13 | WORKS | two assignments found: lines 56 and 602, exactly as documented (`~/logs/sec26-controller.log`) |
| A14 | WORKS | no `switch_num = 10` line; env var + topology-file fallback found at lines 92-98 |
| A15 | WORKS | networkx 3.1, requests 2.28.2, urllib3 1.26.20 |
| A16 | WORKS | `Python 3.12.3` after `conda deactivate` |
| A17 | WORKS | `STEP31_EXIT=0`, no debconf prompt seen |
| A18 | WORKS | `STEP32_EXIT=0` |
| A19 | WORKS | `active` |
| A20 | WORKS | `ovs_version: "3.3.9"`, no error |
| A21 | WORKS | `*** Results: 0% dropped (2/2 received)` |
| A22 | WORKS | clone ok; `git` was already installed even though Section 3 installs it (see journal) |
| A23 | WORKS | CMAKE_EXIT=0 NINJACLEAN_EXIT=0 NINJA_EXIT=0; `build/bin/ndtwin_kernel` 11839016 bytes |
| A24 | WORKS | `testbed_topo.py` present and executable |
| A25 | WORKS | `p4_proxy/p4_src/ndtwin_switch.p4` printed |
| A27 | WORKS | `ldd build/bin/ndtwin_kernel \| grep /usr/local` printed nothing, as the manual predicts |
| A28 | WORKS | `which mn` -> `/usr/bin/mn` (packaged), checked before the p4 install completed |

## B. User Manual, OVS path - outcomes
| # | Outcome | Evidence |
|---|---|---|
| B1 | WORKS | `LISTEN 0 50 0.0.0.0:6633` and `:8080` (`~/logs/t1-ryu-ports.txt`) |
| B2 | WORKS | `*** Starting CLI: mininet>` (`~/logs/t2-topo-60s.txt`) |
| B3 | WORKS | documented warning appeared **32 times** |
| B4 | WORKS | `Static topology initialized, all-destination paths installed.` |
| B5 | WORKS | **130 on all ten switches, three consecutive samples** (`~/logs/b5-convergence-final.log`); breakdown 128 nw_dst + 1 LLDP + 1 table-miss matches the manual exactly |
| B6 | WORKS | `install_all_pair_paths done: hosts=128 pairs=16256 rules=1280 paths=16256 walk=0.380s install=0.170s report=0.210s` |
| B7 | WORKS | `Server Listening on port 8000`; `topology from the control plane: 10 switches, 128 hosts, 288 edges up` |
| B8 | WORKS | with a real TTY the kernel printed `Select your deployment environment: [1] Local Mininet [2] Remote Testbed`; answering 1/1/2 started it (`~/logs/kernel-interactive-prompt2.txt`) |
| B9 | WORKS | piped: `stdin is not a TTY, so --mode must be given explicitly.` + usage, rc=2 |
| B10 | WORKS | `--help` prints the full flag list |
| B11 | WORKS | iperf3 server+client started from the Mininet CLI |
| B12 | WORKS | exactly **two** records, one per direction, `10.0.0.1:5201 -> 10.0.0.2:43182` and the reverse (`~/logs/b12-flowdata-decoded.txt`) |
| B13 | WORKS | the manual's decoder printed `10.0.0.1` for `16777226` |
| B14 | WORKS | 2 records at +10 s after the last packet, **0 at +15 s** and thereafter (`~/logs/b14-purge-timing.log`) - the documented 15 s exactly |
| B15 | WORKS | `exit` tore the fabric down; `Cleaning up: Removing IP alias 192.168.123.1 from 'lo' interface...` confirms doc step 2 |
| B16 | WORKS | doc claim reproduced: ryu pid 45643 gone after `sudo mn -c`, pane shows `Terminated`, :6633/:8080 closed |
| B17 | WORKS | both documented lines present in order: `All subsystems stopped. Exiting.` (line 1869) then `terminate called without an active exception` (line 1890), then `Aborted` |
| B18 | WORKS | full second bring-up reached 130 on all ten switches; kernel back to 138 nodes / 288 edges |
| B-extra | WORKS-BUT | the manual's validation pair `h1`/`h2` are on the **same switch** (`get_path_switch_count` = 1), so its own example never crosses the fabric and `get_average_link_usage` stays `0.0`. With a pair of my own (`h1`<->`h128`, switch_count 5) the path came back as 7 hops, **different in each direction**, and avg link usage went 0.0 -> 0.223 (`~/logs/distant-pair-test.log`) |

## C. `ndt` launcher - outcomes
| # | Outcome | Evidence |
|---|---|---|
| C1 | WORKS | `bash -lc 'command -v ndt'` -> `/home/ndt/.local/bin/ndt` |
| C2 | WORKS | `-rwxr-xr-x 1 root root 6560 /usr/local/sbin/ndtwin-lab` |
| C3 | NOT-TRIED (deliberate) | the sudoers NOPASSWD grant is a standing privilege change; the manual itself offers the alternative ("skip step 3 and run `ndt` from a shell whose `sudo` credentials are already warm") and I took that |
| C5 | WORKS | `ndt --help` output matches the manual's two tables |
| C6 | WORKS | `ndt status` printed lab/configuration/running/network-health blocks including the three override files (`~/logs/ndt-status.log`) |
| C7 | WORKS | `ndt status --check` -> `check: ok`, exit 0 with nothing running |
| C4 | CONFIRMED-BY-INSPECTION | the manual's known limitation is real on this machine: `/usr/local/sbin/ndtwin-lab` lines 25-29 and 82-83 hardcode `/home/adam/...`, and `ls -d /home/adam` -> `No such file or directory` |

## D. Kernel REST API - outcomes (all against the live OVS fabric)
| # | Outcome | Evidence / effect checked |
|---|---|---|
| D1 | WORKS | edge s1->s5 **and** s5->s1 both went `is_up=True` -> `False` in `get_graph_data`; bad edge -> documented `404 edge not found in topology` |
| D2 | WORKS | both directed edges back to `is_up=True` |
| D3 | WORKS | 138 nodes (10 switches + 128 hosts), 288 edges, vertex_type 0/1 as documented |
| D4 | WORKS | see B12 |
| D5 | WORKS | 10 entries, 130 flows per dpid - **cross-checked against `ovs-ofctl dump-flows`, which also said 130** |
| D6 | WORKS-BUT | 200 + per-dpid values; doc calls the unit watts, values are 33466-147622 "W" in mininet (doc does say random in MININET mode) |
| D7 | WORKS | all ten `"ON"`; `?ip=` form works; unknown IP -> documented `404 Unknown switch IP` |
| D8 | WORKS | **verified effect**: power off removed bridge `s3` from `ovs-vsctl list-br` and set graph `is_up=False`; power on restored the bridge and the rule count went back to 130 (`~/logs/d8-power.log`). See BUG-07 for the 400 wording |
| D9 | WORKS | rule appeared on s1, count 130 -> 131. Body differs from doc: BUG-04 |
| D10 | WORKS | rule gone, count back to 130 |
| D11 | WORKS | `actions=output:1` -> `actions=output:2` on the switch, with `hard_age` reset |
| D12 | WORKS-BUT | returns 200; **identical to D13** - BUG-05 |
| D13 | WORKS-BUT | identical to D12 - BUG-05 |
| D14 | WORKS | `{"status":"Switch set to up"}`; no dpid -> 400; unknown dpid -> documented 404 |
| D15 | WORKS | `s3` -> `sX` visible in `get_graph_data` **and** written into `setting/StaticNetworkTopologyMininet_10Switches.json` (git shows it modified); survived a kernel restart. See BUG-08 |
| D16 | WORKS | `{"app_id":1,...}` and `/srv/nfs/sim/1` was really created |
| D17 | WORKS | empty body -> `400 {"details":"missing required field(s): simulator, version, app_id, case_id, inputfile",...}` - good validation |
| D18 | WORKS | empty body -> 400 naming the missing `app_id` |
| D19 | WORKS-BUT | by `name` and by `dpid` both work; unknown -> documented 404; **no identifier -> 400, documented as 404** (BUG-06) |
| D20 | WORKS | set nickname by dpid, read back `{"nickname":"Sinica-Switch-01"}` |
| D21 | WORKS | 200, per-switch values, and (unlike D12/D13) a genuinely different value set |
| D22 | WORKS | single-path form and all-paths form both as documented; `10.0.0.1->10.0.0.128` = 5 switches |
| D23 | WORKS-BUT | with the **documented** field names (`install_flow_entries` etc.) install and delete both landed on s2, verified by `ovs-ofctl`. With wrong top-level keys it answered `200 {"accepted":0,...,"status":"queued"}` instead of rejecting - BUG-13 |
| D24 | WORKS | 0.0 with no inter-switch traffic; 0.223 with a cross-fabric flow |
| D25 | WORKS | dpid 1/5/10 gave 691180770 / 1247451728 / 1396401189 bps under load |
| D26 | WORKS | 2 / 1 / 1 flows on dpid 1 / 5 / 10, consistent with the path |
| D27 | WORKS | `{"status":"locked","ttl":30,"type":"routing_lock"}` |
| D27b | **BROKEN** | missing / non-string / absent-body `type` all return **200 and acquire `routing_lock`**, which the doc says was fixed on 2026-08-30 - **BUG-03** |
| D28 | WORKS | `{"status":"renewed",...}` |
| D29 | WORKS | `{"status":"released",...}`; releasing a lock not held -> 412 |
| D30 | WORKS | returned the same flows as D4, sorted descending by `estimated_packet_rate_in_the_proceeding_1sec_timeslot` (`[65450, 1962]`) as documented. Note: the doc gives **no way to pass K**; `?k=` / `?top_k=` change nothing |
| D31 | WORKS | `group_id=1,type=all,bucket=actions=output:1` read back with `ovs-ofctl dump-groups s1` |
| D32 | WORKS | changed to `actions=output:2`, verified on the switch |
| D33 | WORKS | group gone from `dump-groups` |
| D34 | WORKS | `meter=1 kbps bands= type=drop rate=1000` read back with `dump-meters s1` |
| D35 | WORKS | rate changed to 2000, verified |
| D36 | WORKS | meter gone from `dump-meters` |
| D37 | WORKS | catalogue with OVS / BrocadeICX7250 / HPE5520 exactly as documented |
| D38 | WORKS | dotted-quad, no live-state fields, as documented |
| D39 | WORKS | **the doc's warning is accurate**: `?state=enable` -> `200 {"...","recording":false,"status":"success"}` with the message "this deployment does not record: the recorder is only started outside MININET mode". Missing state -> 400 |
| D40 | WORKS | empty body -> 400 naming `all_destination_paths` |
| D41 | WORKS | `503 {"error":"Intent translator is disabled; the kernel was started with --no-ai."}` - the documented string, verbatim |
| D-extra | WORKS | unknown route -> `404 {"error":"Not Found"}` |

## F. Tools - outcomes so far
| # | Outcome | Evidence |
|---|---|---|
| F1 | WORKS | `~/nsr-env`, `NSR imports OK` |
| F2 | WORKS | both scripts +x |
| F3 | WORKS | `setting/recorder_setting.yaml` present with the documented defaults |
| F4 | **BROKEN** as documented / WORKS with a workaround | `./start_network_state_recorder.sh` -> `SCRIPT_EXIT=0`, `ModuleNotFoundError: No module named 'nornir'`, nothing running, no output dirs, config already flipped. Reproduced twice. Works after `source ~/nsr-env/bin/activate` - **BUG-09** |
| F5 | WORKS | `144093 python3 network_state_recorder.py`; and the manual's own `pgrep -f` false-positive warning demonstrated itself live - my own `bash -c` wrapper matched too |
| F6 | WORKS | `2026_09_03_11-01-11_flowinfo.json`, `..._graphinfo.json`, then `..._flowinfo_json.zip` after the 2-minute rotation - naming exactly as documented |
| F7 | WORKS-BUT | NDJSON records correct; the doc's `{[...]}` notation is not valid JSON and the real shape is an array - **BUG-12** |
| F8 | WORKS | `logs/NSR_2026-09-03.log`, exactly the documented name |
| F9 | WORKS-BUT | without sudo: exit 0, process still running, config flipped anyway (**BUG-11**). The manual's documented remedy `sudo ./stop_network_state_recorder.sh` **does** work - graceful shutdown took ~6 s (`Zipping Stopped.` / `NSR stopped.`) |
| F10 | WORKS | foreground mode logs to console: `SUCCESS : All components started successfully.` / `NSR is running.` |
| F11 | WORKS | with the kernel down, NSR logs `WARNING : No new data from http://127.0.0.1:8000/ndt/get_detected_flow_data.` (seen when no flows existed) |

## F. NTG - outcomes
| # | Outcome | Evidence |
|---|---|---|
| F12 | WORKS | `~/ntg-env` built with `--system-site-packages`; `import mininet` from it resolves to `/usr/lib/python3/dist-packages/mininet/__init__.py`, which is exactly what the manual says the flag is for |
| F13 | WORKS-BUT | tree matches the Files Overview, **except** the shipped `NTG.yaml` has `host_file: "./setting/Hardware.yaml"` while the Installation Manual prints that same file with `"./setting/Mininet.yaml"`; and the shipped `setting/Mininet.yaml` has `mode: "custom_command"` and **no `hostname:` key**, while the manual prints `mode: "cli"` with `hostname: "mininet_testbed"` - BUG-16 |
| F14 | WORKS | made the documented edit; NTG then loaded the Mininet inventory and reached the kernel |
| F15 | WORKS | `NTG>` prompt appeared once the kernel answered; before that it retried `Failed to get hosts from NDTwin server., retrying...` rather than dying, which is the right behaviour for the documented start order |
| F16 | WORKS | `flow --config flow_template.json` -> `SUCCESS : Experiment completed.` and **the kernel saw the traffic**: 173 -> 206 -> 213 concurrent flow records while it ran, back to 0 after (`~/logs/f16-ntg-flow-live.log`). Also revealed the undocumented K=50 cap (BUG-15) |
| F17 | WORKS | `dist --config dist_template.json` completed; the three CESNET distribution CSVs already ship in `cesnet_2022/` and `dist_template.json` already points at them. Took ~3.5 min, most of it repeating one unchanging progress line - see the journal correction |
| F18 | WORKS | `flow` with no `--config` -> `WARNING : No config file`, as the manual requires |
| F19 | WORKS | doc claim reproduced exactly: `sudo ./testbed_topo.py` -> `ModuleNotFoundError: No module named 'loguru'` |
| F20 | NOT-TRIED (no interactive terminal) | tab/arrow completion is a `prompt_toolkit` interactive feature; I drive the pane with `tmux send-keys` and cannot judge what a completion menu renders |
| F-interrupt | WORKS | doc: "if you want to interrupt one running experiment, it will immediately shut down the NTG". Ctrl-C at the `NTG>` prompt tore down the whole fabric - IP alias removed, 1 controller, 144 links, 10 switches, 128 hosts stopped, `ovs-vsctl list-br` empty afterwards |

## A. Installation Manual Section 6 - outcomes (config steps)
| # | Outcome | Evidence |
|---|---|---|
| A31 | WORKS | `setting/AppConfig.hpp` exists (cmake created it from `.example`, as Step 6.0's note predicts) and contains both documented settings verbatim: `P4_PROXY_IP_AND_PORT = "localhost:8081"` (line 10) and `ALLOW_MIXED_DATAPLANE = false` (line 15) |
| A32 | WORKS | `host_count_override` already contained `128`; re-wrote it with the manual's command |
| A33 | WORKS | the manual's verification snippet correctly reported `PROBLEM: not an executable on this machine` for the shipped `bmv2-fast` path, then I made the documented edit to `/usr/local/bin/simple_switch_grpc` |

## E. User Manual - P4 / BMv2 path - outcomes
| # | Outcome | Evidence |
|---|---|---|
| E1 | WORKS | all four pre-flight checks passed; the manual's own override snippet printed `OK: /usr/local/bin/simple_switch_grpc` |
| E2 | WORKS | `All 10 BMv2 switches verified listening on gRPC 50051 ~ 50060` then `mininet>`, ~2 min after launch; each switch line named the binary my override selected (`bin: /usr/local/bin/simple_switch_grpc`) |
| E3 | WORKS | `/tmp/ndtwin_p4_switches.json` is a dict of **10** entries s1..s10, each with pid, device_id, grpc_port, thrift_port, log_file and full argv |
| E4 | WORKS | proxy came up on `LISTEN 0 2048 0.0.0.0:8081`; before the kernel existed it logged `[Kernel] switch N entered: FAILED ConnectionError ... port=8000 ... Connection refused` for each switch, which is correct for the documented start order (kernel last) |
| E5 | WORKS | **16256**, exactly the documented figure (128x127); two consecutive samples agreed (`~/logs/e5-pathcount.log`) |
| E6 | WORKS | `Data plane: bmv2 (10 switch(es))`; `get_graph_data` -> 138 nodes (10 switches + 128 hosts), **288 edges**, 10 up, 10 enabled, `brand_name` `BMv2` |
| E7 | WORKS-BUT | doc: "One failed request to port 8080 at startup is expected and self-healing." Observed **zero** references to `localhost:8080` in the kernel log; it went straight to the proxy (`All-bmv2 topology: polling http://localhost:8081/v1.0/topology`, `Destination paths loaded from localhost:8081 (16256 pairs)`). Better than documented, so the doc is stale rather than wrong-in-a-harmful-way |
| E8 | WORKS | with `h1 iperf3 -s &` / `h2 iperf3 -c h1 -t 300 &` the kernel returned **two** records, one per direction, on the BMv2 fabric (`~/logs/e8-p4-flowdata.json`). Reverse direction ~43-49 Mbit/s, consistent with the manual's warning that the debug build is packets-per-second limited |
| E9 | WORKS | **all six** group/meter endpoints returned `501` with a full explanation naming the reason ("OpenFlow groups and meters have no direct equivalent, the P4 proxy agent implements no such route, and the pipeline has no ActionSelector yet"). Exactly the documented deliberate refusal |
| E10 | WORKS | documented 7-step shutdown ran clean: `ps -eo args= \| grep -c '[s]imple_switch_grpc'` -> **0** survivors |
| E11 | WORKS | doc claim reproduced precisely: `ps -eo args= \| grep -c` -> **10**, `pgrep -c simple_switch_grpc` -> **0** (and pgrep itself warned "pattern that searches for process name longer than 15 characters will result in zero matches"), `pgrep -c simple_switch_g` -> **10** |
| E12 | WORKS | `ss -ltn \| grep 8081` -> released; proxy pane showed `[Proxy Agent] Shutting down...` / `Application shutdown complete.` |
| E13 | WORKS | `ss -tln \| grep :8000` -> released |
| E14 | WORKS-BUT | the kernel **detects and names** the mixture perfectly (`Topology mixes data planes (ovs=[1]; bmv2=[2,3,4,5,6,7,8,9,10])`) but **keeps running and serving** the mixed model (`:8000` open, 14 nodes / 40 edges returned). `architecture.md` says it "refuses to load"; it does not - **BUG-17** |
| E-extra | WORKS | endpoints the doc says behave identically in both modes did: `get_openflow_capacity`, `historical_logging` (same honest `recording:false` message), `get_path_switch_count` (5 switches for 10.0.0.1->10.0.0.128) |

## A. Installation Manual Section 6 - remaining outcomes
| # | Outcome | Evidence |
|---|---|---|
| A26 | WORKS | `simple_switch_grpc --version` -> `1.15.6-1c8c9a4f`; `p4c-bm2-ss --version` -> `Version 1.2.5.17 (SHA: d46d824202 BUILD: Release)`; both in `/usr/local/bin`. This is the exact pair the manual predicts for a 2026-09-02-vintage clone |
| A29 | WORKS | pipeline compiled in 0.37 s; both `ndtwin_switch.json` (75852 B) and `ndtwin_switch.p4info.txt` (4051 B) produced. Two warnings the manual does not mention: `'TYPE_ARP' is unused` and `.txt format is being deprecated; use .txtpb instead` - harmless |
| A30 | WORKS | `p4_proxy/venv/bin/python --version` -> `Python 3.12.3`; `protobuf 3.20.3`, `p4runtime 1.4.1`, `grpcio 1.83.1` |
| A33 | WORKS | all four rows of the manual's Step 6.6 table reproduce **verbatim**, including the un-built `bmv2-fast` path: `Error: bmv2 binary override names no executable: '/usr/local/bmv2-fast/bin/simple_switch_grpc'` |
| A34 | WORKS | commenting the line out: `Error: ... has no directive line (every line is blank or a #-comment). Commenting the line out used to re-select the stock build silently; it now refuses, because which binary produced a number must be something a human wrote down.` |
| A35 | WORKS | deleting the file: `Error: no bmv2 binary override at ... there is no default to fall back to on purpose.` Exit status **1** (measured cleanly without a pipe, `~/logs/a35-exitcode.log`) |
| A36 | NOT-TRIED (time) | Step 6.7's optional `bmv2-fast` performance build is a second full behavioral-model compile; the debug build was sufficient for every functional check and the manual marks the step optional |
