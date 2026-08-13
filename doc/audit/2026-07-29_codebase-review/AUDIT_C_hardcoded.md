# AUDIT C — Hard-coded assumptions that break

VERDICT: 9 CONFIRMED, 0 SUSPECTED

Note on p4_proxy citations: a concurrent session's mutation gate transiently dirties `p4_proxy/proxy_agent/*` and `tools/p4_power_helper.py`; every proxy-file quote below was verified against HEAD (9afd647).

### sFlow telemetry pinned to 127.0.0.1:6343 while every other kernel-bound channel follows NDT_URL
GRADE: CONFIRMED
WHERE: p4_proxy/proxy_agent/sflow_emitter.py:93 (`DEFAULT_COLLECTOR = ("127.0.0.1", 6343)`, constructor default at :258) and p4_proxy/proxy_agent/main.py:38 (`sflow = SFlowEmitter()` — the only production construction; no collector argument, no env override)
WHAT: kernel_notifier.py:47 resolves the kernel via `os.environ.get("NDT_URL")` (matching components.env), and both topology loaders honor `NDTWIN_TOPO_FILE` — the sFlow emitter alone has no override path. The kernel side hard-defines the port (`#define SFLOW_PORT 6343`, include/ndt_core/collection/FlowLinkUsageCollector.hpp:33), so the port halves agree; it is the host that silently diverges.
BITES: Deploy the kernel on another host with NDT_URL set: notifications and REST follow it, while every sFlow datagram still goes to 127.0.0.1:6343. The socket is unconnected UDP, so `sendto` keeps succeeding — `datagrams_sent` climbs, `send_errors` stays 0, nothing logs, and every rate/link-utilization reads zero while everything looks healthy.

### main.py hardcodes the four hosts while links and agent IPs follow NDTWIN_TOPO_FILE
GRADE: CONFIRMED
WHERE: p4_proxy/proxy_agent/main.py:24-27
WHAT:
```python
topo.add_host(ip="10.0.0.1", mac="00:00:00:00:00:01", switch_dpid=1, port=3)
```
…and three siblings through 10.0.0.4/dpid 4. `load_switch_links` (topology_manager.py:208) and `load_switch_agent_ips` (sflow_emitter.py:429) both read `os.environ.get("NDTWIN_TOPO_FILE")`; the hosts never do. The nearby admission "Still hardcoded -- deriving them from the topology JSON is Phase 3 work" (main.py:44-46) covers only `DEFAULT_SWITCH_DPIDS`/gRPC ports, not this block.
BITES: Point NDTWIN_TOPO_FILE at any other topology: the proxy seeds and beacons the new links while `/v1.0/topology/hosts`, destination-path rendering and `install_initial_routes` keep computing for four hosts that may not exist there, with wrong attach ports — no validation, no log. Split-brain graph, silently.

### intelligent_router.py hard-wires the deployment: absolute /home/adam path, a fixed switch count gating all route install, four literal localhost:8000 URLs
GRADE: CONFIRMED
WHERE: intelligent_router.py:25, :31 + :297, :283/:311/:788/:846
WHAT: `static_topology_file_path = Path("/home/adam/Desktop/NDTwin-Kernel/setting/StaticNetworkTopologyMininet_10Switches.json")` (:25); `switch_num = 10` (:31) gating `if len(self.switches) >= switch_num:` (:297); `api_url = f"http://localhost:8000/ndt/inform_switch_entered?dpid={dpid}"` and three more literals (:283, :311, :788, :846).
BITES: On any other checkout path, the topology file silently misses and the controller drops into dynamic-detection mode (one info line, then materially different behaviour). Sharper: `load_static_topology` — the only trigger for the initial route install — runs only once ≥10 switches connect, so a 9-switch deployment never installs a route and never says why. The four localhost:8000 literals contrast with the P4-side KernelNotifier, which honors NDT_URL precisely so the two sides cannot disagree — the OVS controller can. Nothing is broken on this machine today; all three bite on redeployment.

### OPENAI_API_KEY logged in plaintext at INFO level
GRADE: CONFIRMED
WHERE: src/ndt_core/intent_translator/LLMAgent.cpp:29
WHAT:
```cpp
char* apiKey = std::getenv("OPENAI_API_KEY");

SPDLOG_LOGGER_INFO(Logger::instance(), "api_key={}",apiKey);
```
The full secret goes into the kernel log at INFO — the default-on level — every time the kernel starts with AI enabled. (Secondary: the log call runs before the null check at :30, and fmt formatting a null `char*` is not a printable "(null)" path.)
BITES: `.test_run/` is gitignored, so the key does not reach git directly — but this project routinely pastes log excerpts into `doc/debug-log/` and handoff documents, and any such excerpt from an AI-enabled run carries the key. Today's stack runs `--no-ai`, so current logs are clean (verified: no `api_key=` under `.test_run/logs/` or `doc/`).

### /ndt/get_static_topology_json fabricates one identical smart plug for every switch
GRADE: CONFIRMED
WHERE: src/ndt_core/collection/TopologyAndFlowMonitor.cpp:2387-2388 (TESTBED branch) and :2401-2402 (else branch)
WHAT:
```cpp
{"smart_plug_ip", "172.25.166.135"},
{"smart_plug_outlet", 3}});
```
Every switch node in the response gets this constant pair. The topology files carry genuine per-switch assignments (setting/StaticNetworkTopology_ipAlias4_10Switches_all_1g_cable.json alone has .135 and .136 across switches, with distinct outlets), and the kernel's own power path reads the real fields from the file — this endpoint invents constants instead of echoing data.
BITES: Any consumer that trusts the endpoint's plug fields power-cycles one wrong outlet for all ten switches on real hardware. Blast radius today is zero — grep across all six sibling repos finds no reader of get_static_topology_json or smart_plug — it is served fiction waiting for its first consumer.

### The OVS topology poll hard-codes localhost:8080, bypassing the AppConfig knob everything else uses
GRADE: CONFIRMED
WHERE: src/ndt_core/collection/TopologyAndFlowMonitor.cpp:47-48
WHAT:
```cpp
// ---Please change to your own RYU base url---
static const std::string RYU_BASE_URL = "http://localhost:8080/v1.0/topology";
```
setting/AppConfig.hpp:8 (`RYU_IP_AND_PORT = "localhost:8080"`) is the intended config surface and is what the flow-stats poll and the P4-proxy re-point use; only this file-local constant remains, its remedy being "edit the source".
BITES: Redeploy with Ryu on another host and update AppConfig: switch/host/link liveness silently polls a dead localhost:8080 — `execCommand` returns an empty body and all three update functions early-return on empty (`if (topologyData.empty()) return;` at :468, :531, :622) with no log line. The graph just stops tracking the control plane.

### Kernel configuration paths are cwd-relative — the binary is only correct when launched from build/
GRADE: CONFIRMED
WHERE: setting/AppConfig.hpp:5, :16, :18 and include/ndt_core/intent_translator/IntentTranslator.hpp:324-326
WHAT: `static const std::string TOPOLOGY_FILE_MININET = "../setting/StaticNetworkTopologyMininet_10Switches.json";` (and the TESTBED/P4 siblings), plus both LLM prompt paths (`"../src/ndt_core/intent_translator/answer_agent_prompt.txt"`, …).
BITES: Launched from any cwd but build/, the topology load fails (logged, then the kernel runs against an empty graph) and `--ai` throws "system prompt file not exist" at startup. Distinct instances of the shape already adjudicated once for `../doc/2026-01-02_OpenflowCapacity.json`; these are the topology and prompt halves, mitigated today only by scripted launches and NDTWIN_TOPO_FILE.

### HistoricalDataManager writes into another user's hardcoded home directory and never checks a single write
GRADE: CONFIRMED
WHERE: src/ndt_core/data_management/HistoricalDataManager.cpp:27 (`std::filesystem::create_directories("/home/of-controller-sflow-collector/LinkData");`), :61 (outDir), :116-124 (unchecked `std::ofstream` appends)
WHAT: An absolute path into a foreign home, created with the throwing overload in a constructor main.cpp runs unconditionally in both modes (:339, :368), then per-edge CSV appends with no `is_open()`/state check anywhere.
BITES: Two ways. If the directory cannot be created, the constructor throws and the kernel dies at startup — from a data-logging nicety. If it exists but is not writable by the kernel's user (on this machine it is root-owned), every TESTBED run appends into dead streams: months of "historical data" written to nowhere, no log line ever. MININET escapes only because start() skips the thread. Cross-ref: the silent dead-stream half is Theme-D shaped; filed here because the root cause is the baked path.

### OVS port-mapping shells out to `sudo ovs-vsctl`; without passwordless sudo every ofport silently resolves to 0
GRADE: CONFIRMED
WHERE: src/ndt_core/collection/FlowLinkUsageCollector.cpp:273 (`FILE* pipe = popen("sudo ovs-vsctl list interface", "r");`), fallback at :262-263 (`? it->second : 0`)
WHAT: OVS-mode ifIndex→ofport translation assumes NOPASSWD sudo and ovs-vsctl on PATH. When sudo cannot prompt, the pipe yields nothing; the only trace is an INFO "Size: 0" line, and thereafter every lookup returns ofport 0 — ingress detection always false, agent keys {ip, 0}, edge lookups miss.
BITES: OVS link usage and per-edge flow sets go quietly empty on any unprivileged redeploy while the process looks healthy. Works on this machine (ovs-vsctl is in the NOPASSWD list); partially acknowledged in the header — reported because the degradation is silent where it could be loud.

---

Checked and clean (Theme C secrets/dependency sweep):
- Git history scan for key-shaped strings (`sk-proj`, `OPENAI_API_KEY=`, `ghp_`, `BEGIN RSA`) via `git log --all -S`: no hits.
- `p4_proxy/requirements.txt`: all dependency names canonical (grpcio, protobuf, p4runtime, fastapi, uvicorn, networkx, requests) — no typosquats.
- `CMakeLists.txt:126-128` FetchContent: googletest pinned to a commit-hash zip from github.com/google/googletest — canonical source.
- Working-tree grep for `api_key|bearer|password|secret|sk-` and 48+-char base64 runs: only the LLMAgent finding above; base64 hits are vendored libs.

Read: every cited line re-opened by the orchestrator at adjudication time (grep/sed against the current tree, or `git show HEAD:` for files inside the concurrent mutation window); full end-to-end file coverage per area by the five audit passes — their complete file lists are consolidated at the end of AUDIT_A_hallucinations.md.
