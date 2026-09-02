# CHECKLIST.md — run-04

Populated from User Manual pages (Kernel Native-Linux OVS + P4, Tool pages: NTG, NSR,
WebGUI, TrafficVisualizer, Simulation Platform Manager) before testing began.
Outcome: WORKS / WORKS-BUT / BROKEN / NOT-TRIED (why). Updated in place as each line is tried.

## A. `ndt` launcher (Kernel Native-Linux, "The short way")
A1. install ndt symlink (~/.local/bin/ndt) -- WORKS (needs `bash -l` / new login shell for PATH -- see BUGS.md friction note)
A2. install ndtwin-lab root-side script (/usr/local/sbin) -- WORKS (installed, root:root 755)
A3. sudoers.d NOPASSWD entry for ndtwin-lab -- WORKS (sudo -n ndtwin-lab did not prompt)
A4. `ndt up ovs` -- BROKEN, reproduces manual's own documented G-7 limitation: hardcoded /home/adam paths in ndtwin-lab -> "XX fabric has 0 hosts, expected 128" after 5m08s. See BUGS.md BUG-1.
A5. `ndt status` -- WORKS (clean baseline before start, and after `ndt down`; shows hosts/topology/bmv2-binary config + running state)
A6. `ndt down` -- WORKS (cleaned up after the failed `ndt up ovs`, all verify-clean checks passed)
A7. `ndt check` -- WORKS (telemetry double-count tripwire; also independently confirms the WebGUI/Visualizer docs' warning that MININET-mode CPU util is `10 + hash(ip) % 50`, a fake constant, not a measurement)
A8. `ndt claim` / `ndt release` (with NDT_OWNER) -- WORKS (claim shows owner+expiry+note in `ndt status`, release clears it)
A9. `ndt apps` interactive picker -- BROKEN in two distinct ways: (1) `nsr` needs a clone location and conda env this project's own Installation Manual pages do not build (see BUGS.md addendum to BUG-1); (2) `energy` and `sim` both print "ok ... started" while the tmux session is already gone, reproduced twice including once with a fully converged OVS fabric+kernel already up -- see BUGS.md BUG-6. `viz` correctly and honestly refuses ("is a JavaFX GUI and there is no display; not starting it") -- so the tool CAN detect problems, it just does not for energy/sim. `te` correctly reports "TE app not found" (Traffic-Engineering-App was never cloned in this run). Did not try the bare interactive-picker form (no args).
A10. `ndt ntg` -- BROKEN, same /home/adam hardcoded-path family as BUG-1: "not found: /home/adam/Network-Traffic-Generator/setting/Mininet.yaml". Exits non-zero, error is legible.
A11. `ndt --help` -- WORKS (matches the User Manual's command table exactly)
A12. `ndt up` (P4 default) -- BROKEN, same root cause as A4/BUG-1: "XX fabric did not come up: 0/10 switches, manifest missing" after 3m06s. Better diagnostics than the OVS path (suggests `sudo -n /usr/local/sbin/ndtwin-lab topo-out 40`, which confirms "no topo session"). See BUGS.md addendum to BUG-1.
A13. `ndt clean` -- WORKS (teardown assertion alone, prints the same 5 ok-checks and "clean")
A14. `ndt down --deep` -- WORKS (adds a "[4/4] deep sweep" phase; reported "nothing left holding the ports" since the machine was already clean at the time)

## B. Kernel manual 3-terminal procedure, OVS/Ryu
B1. Terminal 1: ryu-manager intelligent_router.py + rest_topology + ofctl_rest on 6633 -- WORKS (loaded cleanly both times; note: app self-polls its own REST API every ~2s continuously, e.g. /v1.0/topology/switches, /ryu_server/all_destination_paths -- not documented, not a problem, just noted)
B2. Terminal 2: sudo python3 testbed_topo.py -- WORKS-BUT: brings up the fabric correctly (confirmed via manual ping + iperf3) but its OWN internal all-pairs self-test falsely reports 100% packet loss and its final banner says OK anyway regardless. See BUGS.md BUG-2. Piping its output through `tee` at launch (my own methodology, not the manual's) crashed the CLI once; running it unpiped (as the manual shows) did not reproduce that crash across 2 tries.
B3. Convergence check via ovs-ofctl dump-flows count (expect 130/switch, 10 switches) -- WORKS, matched exactly (130 on all 10 switches), reached in under 20s from topology-script start in the fastest of 2 runs -- much faster than the manual's 80-90s reference, not a problem, just a faster machine/run
B4. "all-destination paths installed" message timing (manual: ~80-85s) -- WORKS-BUT: did not time this message directly (used the flow-count method instead, as the manual itself recommends over eyeballing the log) -- Ryu's log did show `install_all_pair_paths done: hosts=128 pairs=16256 rules=128 paths=3968` confirming the same underlying event
B5. Terminal 3: sudo bin/ndtwin_kernel --mode mininet --topology ... --no-ai --loglevel info -- WORKS (once a stale prior kernel process holding the sFlow port was cleared -- see BUGS.md BUG-3); immediately reported "topology from the control plane: 10 switches, 128 hosts, 288 edges up", matching the OVS/128-host fabric exactly
B6. Kernel with NO flags -> interactive 3-question prompt -- WORKS, prompt text matches manual verbatim ("Select your deployment environment... [1] Local Mininet... [2] Remote Testbed", etc.), answered 1/1/2 by hand via tmux send-keys, kernel started identically to the flagged form
B7. iperf3 server on h1 (background) -- WORKS
B8. iperf3 client h2->h1 (background, -t 300) -- WORKS, sustained ~955-956 Mbit/s (near the 1000Mbit TCLink cap) in one run
B9. curl :8000/ndt/get_detected_flow_data while flow active (expect 2 records) -- WORKS, exactly 2 records, one per direction, matching the manual's own worked example numbers exactly (src_ip 16777226 / dst_ip 33554442)
B10. decode src_ip/dst_ip integer -> dotted quad -- WORKS, 16777226 -> 10.0.0.1 (h1), 33554442 -> 10.0.0.2 (h2), matches manual's own example value verbatim
B11. query API after flow idle >15s (expect []) -- WORKS, got [] after ~20s idle
B12. Safe shutdown: mininet exit, sudo mn -c -- WORKS, reproduced across 2 full cycles
B13. Confirm mn -c also kills Ryu (Terminal 1 dies) -- WORKS (confirmed via tmux session list before/after, both cycles)
B14. Kernel Ctrl-C -> "terminate called without an active exception" line -- WORKS-BUT: process did stop and :8000 was released within seconds (matches the functional claim), but the specific log line the manual quotes did not appear in what I captured -- plausibly an artifact of sending the signal via `tmux send-keys C-c` into a `sudo ... | tee` pipeline rather than a real keypress; not chased further.
B15. Restart whole stack a second time after clean shutdown -- WORKS, full 2nd (3rd overall) restart converged (130 flows/switch on all 10 within ~30s) and the kernel reported the same "10 switches, 128 hosts, 288 edges" again
B16. Operate a Physical (Hardware) Network section -- NOT-TRIED end-to-end (no physical switches available). Partial: tried `sudo bin/ndtwin_kernel --mode testbed --no-ai --loglevel info` anyway out of curiosity, with nothing real behind it. It starts cleanly, loads its own built-in default hardware topology file (StaticNetworkTopology_ipAlias4_9Switches_all_1g_cable.json, 9 switches, hardcoded smart-plug IPs on a 10.10.10.x/172.25.166.121 lab network I do not have), then fails informatively and immediately (`curl: (7) Failed to connect` against Ryu's :8080) rather than hanging or crashing -- a legible failure when the dependencies genuinely are not present.

## C. P4 / BMv2 optional data plane (Install Section 6 + User Manual P4 section)
C1. clone NDTwin-Kernel-P4-public (superset repo) -- WORKS (done in Section 4.1, commit 936f8c6; p4_proxy/p4_src/ndtwin_switch.p4 confirmed present, Step 6.0's own check)
C2. p4-guide install-p4dev-v8.sh (long build, ~1-2h) -- WORKS, kicked off 16:02:57, SCRIPT_EXIT=0 at 18:16 (~2h13m on 4 vCPUs, close to the manual's own reference), both required binaries confirmed working ~5 min before the full script itself finished
C3. simple_switch_grpc --version -- WORKS, `1.15.6-1c8c9a4f`, exact match for the manual's own worked example dated 2026-09-02
C4. p4c-bm2-ss --version -- WORKS, `Version 1.2.5.17 (SHA: d46d824202 BUILD: Release)`, exact match for the manual's own worked example dated 2026-09-02
C5. compile ndtwin_switch.p4 -> ndtwin_switch.json + p4info -- WORKS, compiled cleanly (2 benign warnings: unused TYPE_ARP constant, deprecated .txt p4info format), produced ndtwin_switch.json (75852 B) and ndtwin_switch.p4info.txt (4051 B)
C6. p4_proxy/venv Python 3.12 env + requirements.txt -- WORKS, venv built from Python 3.12.3 (ryu-env correctly not active), all pinned requirements installed cleanly including protobuf==3.20.3 as the manual insists on
C7. AppConfig.hpp P4_PROXY_IP_AND_PORT check + kernel rebuild -- NOT-NEEDED: already correct (localhost:8081, ALLOW_MIXED_DATAPLANE=false) from the original build in Section 4.2, no edit or rebuild required
C8. host_count_override = 128 -- WORKS
C9. bmv2_binary_override points at real executable -- WORKS-BUT: shipped default pointed at the not-yet-built /usr/local/bmv2-fast path (with an unusually detailed embedded comment explaining why, including a prior finding about the debug build's throughput ceiling masking a downstream app's traffic-sensitivity -- read but not acted on further, out of scope for this test); switched it to the stock /usr/local/bin/simple_switch_grpc per the manual's own Step 6.6 instructions since Step 6.7 (the fast build) was skipped as optional-of-optional. Confirmed selected path exists and is executable.
C10. Terminal 1: sudo python3 p4_proxy/mininet/p4_testbed_topo.py, "10 BMv2 switches verified" -- WORKS, exact message match, all 10 switches started with the stock (non-fast) simple_switch_grpc binary as configured, converged in well under a minute
C11. /tmp/ndtwin_p4_switches.json manifest -- WORKS, valid JSON, 10 entries with real PIDs/gRPC ports/log files, argv confirms each uses p4_src/build/ndtwin_switch.json (the pipeline compiled in Step 6.2)
C12. Terminal 2: p4_proxy venv proxy_agent/main.py, listens :8081 -- WORKS. Its first 10 attempts to inform the kernel of switches entering all failed with Connection refused (kernel not started yet, Terminal 3 comes last) -- the proxy's own log names this as expected ("normal when the kernel starts after the proxy... retrying in the background for up to 5 minutes") and moved on to LLDP discovery, link discovery and proactive route install without getting stuck. Confirms Uvicorn on 0.0.0.0:8081.
C13. curl :8081/ryu_server/all_destination_paths (expect 16256, stable across samples) -- WORKS, exactly 16256 reached in well under a minute, confirmed stable across 2 more samples 5s apart
C14. Terminal 3: kernel against StaticNetworkTopologyP4_10Switches_128Hosts.json (expect 10 switches/288 edges) -- WORKS, exact match: "topology from the control plane: 10 switches, 128 hosts, 288 edges up", correctly detected "Data plane: bmv2" and switched to polling the proxy at :8081 instead of Ryu's :8080
C15. traffic validation iperf3 + curl :8000 on P4 fabric -- WORKS, exactly 2 records (h1/h2, same IP encoding as the OVS test: 16777226/33554442), each with a real `path` (switch interfaces + node IDs). Measured throughput on this STOCK (non-fast) simple_switch_grpc build: ~34-37 Mbit/s one direction, ~0.8-1.1 Mbit/s the other -- well below the 1000Mbit link declaration, consistent with the manual's own documented debug-build ceiling ("roughly 3.6 kpps... about 40 Mbps of delivered UDP") for the binary I deliberately selected in Step 6.6 (skipped the optional bmv2-fast rebuild, Step 6.7).
C16. P4 safe shutdown: kernel, proxy, mininet exit, mn -c, simple_switch_grpc survivor check, port 8081/8000 released -- WORKS, cleanly, and better than the manual implies: kernel Ctrl-C showed "terminate called without an active exception" as documented (resolving the ambiguity noted in B14 -- that message DOES appear under normal capture, so the earlier non-appearance was likely an artifact of my own tee-piped capture method there); proxy Ctrl-C released :8081 immediately; Mininet's own `exit` already left ZERO simple_switch_grpc survivors (`ps -eo args= | grep -c "[s]imple_switch_grpc"` -> 0) even before `mn -c` ran; `ndt status` independently confirmed fully clean afterward.
C17. (Optional) Step 6.7 bmv2-fast performance build -- NOT-TRIED (explicitly optional-of-optional)

## D. Web GUI
D1. Docker + docker compose install -- WORKS (Docker 29.7.2, Compose v5.5.0); minor doc slip noted separately (chmod docker.asc typo, harmless here)
D2. clone Web-GUI, cp .env.example .env, set NDT_API_BASE_URL -- WORKS
D3. ./web_gui_deploy.sh -- BROKEN: frontend Docker image fails to build (`pnpm install --frozen-lockfile` -> ERR_PNPM_IGNORED_BUILDS on an unpinned, freshly-pulled pnpm v12.3.0). See BUGS.md BUG-5. Whole deploy aborts, 0 containers start.
D4. curl localhost:3000 (frontend reachable) -- NOT-TRIED (blocked by D3; nothing listens on 3000)
D5. docker-compose ps (3 services up) -- BROKEN for the full 3-service stack (frontend never builds, see BUG-5) but WORKS-BUT for the 2 non-frontend services in isolation: `docker compose up -d postgres node-positions-api` (bypassing the broken frontend target) brought both up cleanly -- postgres reports "ready to accept connections", node-positions-api listens on :3001 and answers HTTP (curl -> 404 "Cannot GET /", i.e. a live Express server, not a dead port). node-positions-api's startup log shows one ECONNREFUSED against postgres:5432 (a startup-order race, postgres was not ready yet), not retried/resolved by the time I checked. Narrows BUG-5 to the frontend image specifically -- the backend half of this tool is not affected by the pnpm problem.
D6. docker-compose logs -- WORKS for the 2 running services (see D5); NOT-TRIED for frontend (never built)
D7. docker-compose down / up -d / restart -- WORKS for the 2-service subset: `docker compose up -d postgres node-positions-api` and `docker compose down` both completed cleanly (containers+network created/removed correctly); frontend remains blocked regardless (BUG-5)
D8. Network Topology page visual features -- NOT-TRIED (needs real browser; also blocked by D3 regardless)
D9. Device Information panel, CPU/mem placeholder values -- NOT-TRIED (needs real browser; also blocked by D3)
D10. Switch Flow Table add/modify/delete flow entry -- NOT-TRIED (needs real browser; also blocked by D3)
D11. NDTwin Assistant (LLM prompt) features -- NOT-TRIED (needs real browser and an API key; also blocked by D3)
D12. Availability Status historical trace playback -- NOT-TRIED (needs real browser; also blocked by D3)

## E. Network Traffic Generator (NTG)
E1. ntg-env venv (--system-site-packages) + pip deps -- WORKS, mininet importable from venv confirmed via python3 -c import test
E2. clone Network-Traffic-Generator -- WORKS
E3. configure NTG.yaml host_file -> setting/Mininet.yaml -- confirms manual is correct that this edit is REQUIRED: shipped default is Hardware.yaml, not Mininet.yaml. WORKS once edited.
E4. sudo ~/ntg-env/bin/python testbed_topo.py -- WORKS (reaches its own "NTG>" prompt in custom_command mode; needs Terminal 3 kernel running too, to get past "Failed to get hosts/paths from NDTwin server" retries -- undocumented dependency on this page but easy to infer). Same self-test false-100%-failure as BUG-2 also seen here -- see BUGS.md note.
E5. NTG CLI tab-complete / path-complete -- NOT-TRIED (tmux send-keys does not exercise readline tab completion meaningfully; would need a real interactive terminal)
E6. `flow --config <file>` command -- WORKS, ran flow_template.json end-to-end ("SUCCESS : Experiment completed."), independently cross-checked: kernel API reported 29 real detected-flow records during the run
E7. `dist --config <file>` command -- WORKS, ran dist_template.json against the shipped cesnet_2022/*.csv distribution files, generated real iperf3 flows with distribution-derived parameters
E8. `exit` command -- WORKS, typed at the "NTG>" prompt, terminated the whole NTG process/tmux pane cleanly (no crash, no traceback) -- the documented clean way to leave, distinct from the Ctrl-C interrupt path in E9
E9. interrupting a running experiment (Ctrl-C) shuts down NTG entirely -- WORKS, confirmed verbatim: "Keyboard interrupt received. Stopping ongoing tasks and exiting..." / "Exiting CLI and cleaning up...", then the whole Mininet topology tore down -- matches the manual's own "Notice" exactly. Tested naturally on a config with unlimited-duration flows, which is the realistic case where a user would want to interrupt.
E10. Hardware/worker-node mode -- NOT-TRIED (no second machine available)

## F. Network State Recorder (NSR)
F1. nsr-env venv + pip deps -- WORKS
F2. clone Network-State-Recorder, chmod +x scripts -- WORKS-BUT: `ndt apps nsr` (Kernel's own tooling) expects the clone at ~/Desktop/<name>, not ~ as this page's own `cd ~ && git clone` puts it -- see BUGS.md addendum to BUG-1
F3. ./start_network_state_recorder.sh (background mode) -- BROKEN as documented (bare `python3`, ModuleNotFoundError for nornir); WORKS once `~/nsr-env` is activated first in the same shell (undocumented on the User Manual page for Option 1). See BUGS.md BUG-4.
F4. pgrep -af network_state_recorder.py -- WORKS as a status check by itself
F5. recorded_info/*.json + *_json.zip files produced -- WORKS-BUT: the *.json file for the currently-open storage_interval reads as 0 bytes (misleading if checked mid-interval); real content confirmed once rotated into the *_json.zip (826 B, valid newline-delimited JSON matching the documented flowinfo/graphinfo format, real flow data present after generating iperf3 traffic)
F6. logs/NSR_<date>.log content -- WORKS, matches documented format (loguru INFO/SUCCESS/WARNING/DEBUG lines)
F7. python3 network_state_recorder.py (foreground mode) -- WORKS, output streamed live to the terminal as documented once `display_on_console` was set to `true` in setting/recorder_setting.yaml (the stop script normally flips this automatically; set by hand here since I was not using the stop script this time)
F8. ./stop_network_state_recorder.sh -- BROKEN: reproduced live, killed an unrelated process (my own shell) via `pgrep -f` collateral match in addition to correctly stopping NSR. See BUGS.md BUG-4 update.
F9. manual stop via kill -15 <PID> -- WORKS: `pgrep -af network_state_recorder.py` to list, confirmed the one real PID, `sudo kill -15 <that PID>` -- log shows a clean graceful shutdown ("Zipping Stopped." / "NSR stopped."), no collateral damage, unlike BUG-4's stop script.

## G. Network Traffic Visualizer (JavaFX desktop app)
G1. openjdk-21-jdk install -- WORKS (java 21 confirmed)
G2. clone Network-Traffic-Visualizer, checkout b5e039c -- WORKS
G3. ./mvnw clean package -- WORKS, BUILD SUCCESS in 26s, both jars produced (shaded 61MB, original 238KB)
G4. ./network_traffic_visualizer.sh (headless: expect exit, no display) -- WORKS-AS-DOCUMENTED: exits with a Maven/JavaFX launch failure (exit 1) with no X server, exactly as the manual's own troubleshooting section predicts
G5. run under xvfb-run to confirm it starts -- WORKS: `xvfb-run -a ./network_traffic_visualizer.sh` starts for real (confirmed via `ps aux`: genuine Xvfb + java/javafx processes alive, not just a log claim), and the app's own debug log shows a live render loop drawing an empty canvas -- matching the manual's own note that an empty canvas is the expected look when NDT_API_URL (default localhost:8000) is unreachable, which it was in this isolated test (no kernel running)
G6. GUI features (fat-tree layout, flow animation, playback, dark mode, etc.) -- NOT-TRIED (needs a real display, per this test's own ground rules; xvfb only confirms the process starts and renders internally, not that any feature looks/behaves correctly)

## H. Simulation Platform Manager + Energy-Saving-App
H1. clone Simulation-Platform-Manager + Energy-Saving-App -- WORKS
H2. apt deps (nlohmann-json3-dev, boost, spdlog, fmt, ssl) -- WORKS (all already satisfied from earlier Kernel install)
H3. NFS server install + /srv/nfs/sim export -- WORKS
H4. NFS client install + /mnt/nfs/sim, /mnt/nfs/app mount points -- WORKS
H5. configure settings.hpp for both apps (localhost, same-machine demo) -- WORKS (shipped .hpp.example defaults are already the same-machine-demo values; just copied, no edits needed)
H6. Energy-Saving-App `make all` (builds + registers simulator) -- WORKS, built energy_saving_app + energy_saving_simulator, and copied the simulator into Simulation-Platform-Manager/registered/energy_saving_simulator/1.0/executable as documented
H7. Simulation-Platform-Manager `make all` -- WORKS, built simulation_platform_manager (+ request_manager, app, simple_sim -- extra targets not mentioned on this manual page)
H8. AppConfig SIM_SERVER_URL + kernel rebuild -- NOT-NEEDED: shipped default already correct (localhost:9000); manual's own worked example uses the wrong port (8003) -- see BUGS.md
H9. sudo ./simulation_platform_manager, "Server started", NFS mount -- WORKS, verified with real evidence (not just the log line): `mount | grep nfs` showed a genuine nfs4 mount of localhost:/srv/nfs/sim at /mnt/nfs/sim, and `ss -tlnp` showed it listening on :9000. Started standalone, cleanly, without Ryu/Mininet/Kernel running first.
H10. end-to-end: kernel submits task, simulator runs -- NOT-TRIED (would need the full Ryu+Mininet+Kernel+WebGUI stack up simultaneously to trigger a real simulation case; WebGUI is currently blocked by BUG-5). Standalone `sudo ./energy_saving_app` (tried out of curiosity) failed at its NFS mount because the app-specific NFS subdirectory `/srv/nfs/sim/power` does not exist without a prior successful kernel registration -- see BUGS.md dependency note.
