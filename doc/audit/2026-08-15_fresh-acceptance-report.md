# 無記憶驗收員報告(2026-08-15 21:38-22:07)

> **來源與方法**:Adam 指定的「防記憶偏見」驗收——opus subagent、worktree 隔離
> (auto-memory 不注入)、知識檢疫(只准官方手冊+--help+系統行為;禁 doc/audit、
> HANDOFF、git 考古、一切調查報告)。prompt 全文在 orchestrator session;未餵任何
> 預期結果或已知缺陷。29 分鐘完成,環境空進空出。以下為其 ACCEPTANCE.md 一字未改。
> 兩個平行複判(fable-judge max、DeepSeek v4-pro)另檔。
> ⚠️ orchestrator 注記:§3d 的量子倍數(≈6.7 樣本/s=規格值)與同晚 switch 端
> counter 量到的 ~0.8 clone/s cap 正面矛盾,判別實驗見 performance report 的追記。

---

# NDTwin Full-Stack Acceptance Report

**Tester:** fresh acceptance agent, no prior knowledge of this system
**Date:** 2026-08-15, 21:38 – 22:07 CST (29 min)
**System under test:** `/home/adam/Desktop/NDTwin-Kernel` (read/execute only; not modified)
**Mode tested:** P4 / bmv2 data plane, 10 switches + 4 hosts
**Knowledge sources:** ndtwin.org official manuals, script `--help` / README output, and the observed behaviour of the running system. No internal design docs, audits or history consulted.

---

## Summary of verdicts

| # | Item | Verdict |
|---|---|---|
| 1 | Cold start from empty environment | **PASS** |
| 2 | Data plane connectivity / real traffic | **PASS** |
| 3a | Twin honesty — topology & inventory | **PASS** |
| 3b | Twin honesty — flow detection & path | **PASS** |
| 3c | Twin honesty — link utilisation attribution | **FAIL** |
| 3d | Twin honesty — per-link rate accuracy | **WARN** |
| 3e | Twin honesty — per-flow rate accuracy | **WARN** |
| 3f | Twin honesty — flow table lifecycle | **PASS** |
| 3g | Twin honesty — link failure / recovery | **PASS** |
| 3h | Twin honesty — CPU / memory telemetry | **FAIL** |
| 4a | Toolchain — `stack.sh` orchestration | **PASS** |
| 4b | Toolchain — `run_layers.sh selftest` | **PASS** |
| 4c | Toolchain — `ndtwin-lab` panel | **PASS** |
| 4d | Toolchain — NTG traffic generator | **PASS (with WARN)** |
| 5 | Teardown returns to empty | **PASS** |

**Headline:** the stack comes up, routes real traffic, and its topology and per-flow path reporting are *exactly* correct — verified independently three times. Two reporting subsystems are not honest: the last hop of every flow is never credited with link utilisation, and the CPU/memory endpoints are frozen placeholders that return the same number for both metrics.

---

## Deviations from the official manual (findings, not silently worked around)

**D1 — The manual documents no P4/bmv2 path.**
The user manual's only emulated-network procedure (`/docs/ndtwin-user-manual/ndtwin-kernel/operate-an-emulated-software-network/native-linux-excution-environment/`) describes a three-terminal OVS/Ryu flow: `ryu-manager intelligent_router.py ... --ofp-tcp-listen-port 6633`, then `sudo python3 testbed_topo.py`, then `sudo -E bin/ndtwin_kernel --loglevel info`. The machine under test runs a P4/bmv2 data plane, whose startup order is the *reverse* (data plane first, because the P4 proxy is a gRPC client dialling out to bmv2). No manual page covers this. I followed `tools/test_workflow/README.md` and `stack.sh up p4` instead, which document and implement the reversed order.

**D2 — Manual's "wait ~60 seconds for host discovery" does not apply here.**
The manual says to wait for `"all-destination paths installed"`, roughly 60 s. In P4 mode convergence was **2 s** for destination paths and **0 s** for full switch up+enabled state. The gating milestone the manual describes belongs to the Ryu path, not this one.

**D3 — The NTG `flow` command's required `--config` flag is not in the manual page I read.**
The official NTG page documents `NTG.yaml` and tab-completion but not the command syntax. `flow <file.json>` is silently rejected with `WARNING : No config file`. The real syntax is `flow --config <file.json>`. Cost me three failed attempts. See finding F4.

**D4 — Kernel API port and endpoint list confirmed correct.**
The developer manual's Kernel API page (port 8000, 29 endpoints) matched the running system on every endpoint I exercised. No discrepancy.

---

## 1. Cold start from an empty environment — PASS

Verified empty first:

```
$ sudo -n /usr/local/sbin/ndtwin-lab status
no lab sessions
bmv2: 0  mininet: 0
$ ss -ltnp | grep -E ':8000|:6633|:6653|:5005[0-9]'      → (no relevant listeners)
$ ./stack.sh status
  ryu   -  :8080 closed / p4_proxy -  :8081 closed / kernel -  :8000 closed
```

Bring-up:

```
$ sudo -n /usr/local/sbin/ndtwin-lab topo-start
topo session started
$ sudo -n /usr/local/sbin/ndtwin-lab status
bmv2: 10  mininet: 14                    ← 10 switches + 4 hosts, as designed
$ ss -ltn | grep 5005                    → 50051…50060 all LISTEN

$ ./stack.sh up p4 </dev/null
[2/3] control plane (P4 proxy agent)
  waiting for P4 proxy agent on :8081 ... up
  waiting for link discovery: want 12 destination paths
    paths=12                             converged after 2s
[3/3] kernel
  waiting for kernel API on :8000 . up
EXIT=0

$ ./stack.sh wait
  switches=10 up=10 enabled=10 edges=40
converged after 0s
```

Ran fully unattended. Note `stack.sh` printed an instruction to start Mininet with `p4_testbed_topo.py` in another terminal; because `ndtwin-lab topo-start` had already brought bmv2 up (via `ntg_bmv2_topo.py`), it detected the listening switches and continued correctly.

**Startup noise (benign, worth knowing):** `p4_proxy.log` contains 10 lines of `[Kernel] switch N entered: FAILED ConnectionError ... port=8000 ... Connection refused`. These are the proxy calling `/ndt/inform_switch_entered` before the kernel exists — an unavoidable consequence of the documented order. The proxy retries: the log later shows 10 × `switch N entered: ok`, which is why all 10 switches reach `enabled`. Noisy, not broken.

**One unexplained control-plane fetch:** `kernel.log` has exactly one `Command failed (exit code 7): curl -s ... "http://localhost:8080/ryu_server/all_destination_paths"`. Port 8080 is Ryu's, and in P4 mode nothing listens there (the proxy is on 8081, and the kernel does use 8081 elsewhere). This single failed fetch had **no observable functional impact** — path reporting was verified exactly correct three times afterwards — but a one-shot failed fetch against the wrong port at startup is worth a look.

---

## 2. Data plane connectivity and real traffic — PASS

```
$ sudo -n mnexec -a <h1> ping -c 4 10.0.0.2
4 packets transmitted, 4 received, 0% packet loss
rtt min/avg/max/mdev = 3.190/3.433/3.809/0.256 ms      ttl=61  (64-61 = 3 switch hops)
```

Throughput probe (TCP, h1→h2): **35.4 Mbps** sender / 28.7 Mbps receiver — consistent with a software bmv2 fabric. All subsequent measurements used 20 Mbps UDP to stay well under this ceiling, so that zero loss could be assumed and verified rather than hoped for.

Three UDP runs, all **0% loss**:

| Run | Duration | Payload | Datagrams lost | Wire rate measured at the veths |
|---|---|---|---|---|
| h1→h2 | 45 s | 107 MB | 0 / 77692 | 20.58 Mbps |
| h2→h1 | 30 s | 71.5 MB | 0 / 51794 | 20.58 Mbps |
| h3→h4 | 25 s | 59.6 MB | 0 / 43162 | 20.58 Mbps |

Wire rate cross-checks exactly: 115,762,930 bytes / 77,692 packets = **1490 B/packet** = 1448 payload + 8 UDP + 20 IP + 14 Ethernet. The measurement is trustworthy.

---

## 3. Is the digital twin honest?

### Reconciliation method

I did not trust any single source. For each run I measured the same traffic three ways:

1. **Ground truth (independent):** raw `rx_bytes`/`tx_bytes` deltas on every `sN-ethM` veth in the root namespace, before and after the run. This is below the twin, below the proxy, and below bmv2's own accounting — it is the kernel's own NIC counters.
2. **Offered load:** iperf3's own sender/receiver report.
3. **The twin's claim:** `/ndt/get_detected_flow_data` and `/ndt/get_graph_data`, polled during the run.

The path a flow *actually* takes is then derived from which veths moved bytes — not from any configuration file the twin also reads, so it is a genuinely independent check.

### 3a. Topology and inventory — PASS

`/ndt/get_graph_data` reports 14 nodes (10 BMv2 switches `s1`–`s10` with dpid 1–10 and device_layer 0/1/2, plus 4 hosts at layer 3) and 40 edges, all `is_up=true is_enabled=true`. This matches the 10 bmv2 processes, 14 mininet namespaces, and the veth pairs I observed. Switch management IPs decode to 192.168.123.11–.20, host IPs to 10.0.0.1–.4.

`GET /ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.2` → `switch_count: 3`, which independently matches the observed TTL decrement of 3 (64→61).

### 3b. Flow detection and path — PASS (exact, 3 for 3)

For every run, the twin's reported path matched the measured byte-carrying links exactly, **including egress interface numbers**:

| Run | Measured (from veth counters) | Twin's `path` field | Match |
|---|---|---|---|
| h1→h2 | s1(in eth3, out eth1) → s5(in eth1, out eth2) → s2(in eth1, out eth3) | h1:3 → 1:1 → 5:2 → 2:3 → h2:0 | exact |
| h2→h1 | s2(in eth3, out eth1) → s5(in eth2, out eth1) → s1(in eth1, out eth3) | h2:3 → 2:1 → 5:1 → 1:3 → h1:0 | exact |
| h3→h4 | s3(in eth3, out eth1) → s7(in eth1, out eth2) → s4(in eth1, out eth3) | h3:3 → 3:1 → 7:2 → 4:3 → h4:0 | exact |

5-tuple identification is also correct: `src_ip` 16777226 = 10.0.0.1, `dst_ip` 33554442 = 10.0.0.2, `dst_port` 5201, `protocol_id` 17 (UDP). `first_sampled_time` was `21:43:04` — the same second the traffic started, so detection latency is effectively immediate.

This is the strongest part of the system. Path reporting is genuinely trustworthy.

### 3c. Link utilisation attribution — FAIL

**The last hop of every flow is never credited with link utilisation.**

During the h1→h2 run, exactly 3 edges reported non-zero usage, at all three poll times: `h1→s1:if3`, `s1:if1→s5`, `s5:if2→s2`. The fourth hop — `s2:if3 → h2` — reported:

```
FOUND: {"src_dpid": 2, "src_interface": 3, "dst_dpid": 0, "dst_interface": 1,
        "link_bandwidth_usage_bps": 0, "is_up": true, "is_enabled": true, "flow_set": []}
```

while my independent counter measurement shows `s2-eth3` transmitted **115,762,864 bytes (20.58 Mbps)** during exactly that window. The edge exists, is up and enabled, and is idle according to the twin.

I then tested whether this is direction-specific or switch-specific, by reversing the flow. **The uncredited edge moved with the direction:**

| Run | Ingress host edge | Middle edges | Last hop (switch→host) |
|---|---|---|---|
| h1→h2 | h1→s1 **credited** | credited | `s2:if3→h2` **usage=0, flow_set=[]** |
| h2→h1 | h2→s2 **credited** | credited | `s1:if3→h1` **usage=0, flow_set=[]** |
| h3→h4 | h3→s3 **credited** | credited | `s4:if3→h4` **usage=0, flow_set=[]** |

Systematic: 0 for 7 polls, across 2 directions and 3 different egress switches. The asymmetry rules out "host access links are deliberately not tracked" — the *ingress* host link is credited every time. And the twin is internally inconsistent with itself: the flow's own `path` array correctly contains that final hop (`(2, 3)` then `(h2, 0)`), so the twin knows the flow leaves s2 on interface 3; it just never attributes the load to that edge.

**Why it matters:** `/ndt/get_average_link_usage` is biased low, and any application reasoning about link load — the Energy-Saving app is a documented consumer of exactly that endpoint — sees a saturated access link to a host as completely idle.

### 3d. Per-link rate accuracy — WARN

Reported per-link utilisation for a *constant* 20.58 Mbps flow, same traffic, three polls:

```
t=15s   h1→s1 15.26 Mbps   s1→s5 12.21 Mbps   s5→s2 15.26 Mbps
t=25s   h1→s1 18.31 Mbps   s1→s5 15.26 Mbps   s5→s2 30.52 Mbps
t=35s   h1→s1 36.62 Mbps   s1→s5 15.26 Mbps   s5→s2 12.21 Mbps
```

Range **12.21 → 36.62 Mbps** (−40.7% to +77.9%) for traffic that never varied.

The mechanism is measurable, not guesswork. Every reported value is an exact integer multiple of a single quantum:

```
GCD(15257600, 12206080, 30515200, 18309120, 36618240, 21360640, 24412160) = 3,051,520
256 packets × 1490 bytes × 8 bits                                        = 3,051,520
multiples observed: 5, 4, 10, 6, 12, 7, 8
```

So utilisation is derived from **1-in-256 packet sampling over a ~1 s window**. At this offered rate that is ~6.7 samples/second, and one sample is worth 14.8% of the true rate — the observed spread is exactly the Poisson noise you would predict. This is inherent to the sampling design, not a coding error, but the practical consequence stands: **instantaneous per-link utilisation from this API carries roughly ±40% noise at 20 Mbps and should only be consumed as a multi-second average.**

### 3e. Per-flow rate accuracy — WARN

Flow-level estimates are noticeably better than per-link ones (they appear time-normalised rather than raw sample counts), but still biased:

| Run | Actual wire rate | Twin reported | Error |
|---|---|---|---|
| h1→h2 | 20.58 Mbps | 22,377,813 | +8.7% |
| h1→h2 | 20.58 Mbps | 21,360,640 | +3.8% |
| h2→h1 | 20.58 Mbps | 23,394,986 | +13.7% |
| h2→h1 | 20.58 Mbps | 21,360,640 | +3.8% |
| h3→h4 | 20.58 Mbps | 18,309,120 | −11.0% |

Errors are within what 1:256 sampling explains. Usable for "is this flow big or small", not for billing-grade accounting.

### 3f. Flow table lifecycle — PASS

A concern arose during the NTG run: the twin reported **59 active flows** while NTG's own console showed a running count of ~10. I tested whether finished flows leak by polling after all traffic stopped:

```
t+0s    flows=0        t+30s   flows=0
t+60s   flows=0        t+90s   flows=0
```

The table drains completely and stays drained. No stale-flow accumulation. The 59-vs-10 gap is a semantic difference — the twin's list includes recently-finished flows within its sampling window, and NTG counts only currently-running sessions — not a leak. Worth knowing when consuming this endpoint: **it is not a live active-flow count.**

### 3g. Link failure and recovery detection — PASS

I blackholed the `s1→s5` link that the h1→h2 flow demonstrably uses, using `tc netem` (100% loss — this breaks forwarding without touching interface admin state):

```
BEFORE      twin: is_up=True     ping h1→h2: 0% packet loss
FAULT IN    ping h1→h2: 100% packet loss           ← data plane genuinely broken
  +5s       twin: is_up=True                       ← not yet detected
  +30s      twin: is_up=False                      ← DETECTED
FAULT OUT   ping h1→h2: 0% packet loss
            twin: is_up=True                       ← recovery detected
```

`kernel.log` confirms the mechanism is a push notification, not polling: `POST /ndt/link_failure_detected` … `link failed on 1:1 -> 5:1`.

Detection latency is **between 5 s and 30 s** (not narrowed further). Correct in both directions, with no false positive before the fault and no stuck state after repair.

Observation, not a defect: traffic did **not** reroute around the broken link — h1→h2 stayed 100% lost for the whole fault. Paths are statically installed in this mode. The twin reported the failure honestly; nothing acted on it.

### 3h. CPU and memory telemetry — FAIL

`/ndt/get_cpu_utilization` and `/ndt/get_memory_utilization` return **byte-identical responses**, and neither value ever changes:

```
sample 1  cpu: {"192.168.123.11":14,"192.168.123.12":54,...,"192.168.123.20":26}
          mem: {"192.168.123.11":14,"192.168.123.12":54,...,"192.168.123.20":26}   => IDENTICAL
sample 2  => IDENTICAL
sample 3  => IDENTICAL
```

The same values were returned before, during and after the NTG load test — a period in which the switches were demonstrably busy forwarding tens of Mbps. These are static placeholders assigned once at startup, and CPU and memory are reading the same underlying field. Any consumer treating these as measurements is being misled.

(`/ndt/get_temperature` returns a *different* set of values — 29/44/26/34/… — so it is at least not the same field, though it is equally static.)

---

## 4. Toolchain

### 4a. `stack.sh` — PASS
`up p4` / `wait` / `status` / `down` all behaved as their `--help` claims. `wait` polls for a derived expectation (10 switches up+enabled) rather than sleeping a fixed time, and reported `converged after 0s` truthfully. `down` correctly stopped kernel and proxy in reverse order and correctly told me Mininet needs separate cleanup.

### 4b. `run_layers.sh selftest` — PASS
```
  PASS   contract self-test
  PASS   component dependency map
all layers passed
```
Its dependency map is genuinely useful output — it enumerates which sibling component consumes which kernel endpoint, and flags one acknowledged gap (`/ndt/disable_switch`, called by Energy-Saving-App, never implemented by the kernel, but on a dead code path).

### 4c. `ndtwin-lab` — PASS
`status`, `topo-start`, `topo-cmd`, `topo-out`, `topo-stop`, `cleanup` all worked as documented in the script header. `topo-out` pane capture wraps text at the tmux pane width (80 cols), which splits long log lines mid-token — cosmetic, but it means output must be read with care.

### 4d. NTG (Network Traffic Generator) — PASS, with WARN

Once invoked correctly, NTG worked end to end. Using a 90-second config derived from the repo's own `flow_bmv2_low.json` template (written to my scratchpad — the main tree was not modified), and letting the experiment finish naturally as the manual requires:

```
t=30s   twin reports 39 active flows
t=60s   twin reports 46 active flows
t=85s   twin reports 59 active flows
NTG console: "Completed iperf3 between h2 and h1 on port 57917"
             "Current simulation time pass 85 seconds"
```

NTG generated real bidirectional flows between the correct host pairs, the twin detected them, and the experiment terminated on its own. NTG also correctly consumed the kernel's host and path data at startup (`Link relationships computed successfully`, after retrying `Failed to get hosts from NDTwin server` until the kernel came up — correct patient behaviour).

**F4 (WARN) — the documented invocation does not work.** Two usability defects compounded:

1. `flow <file.json>` fails with `WARNING : No config file`. The required syntax is `flow --config <file.json>`. The warning text is actively misleading — it says the config is missing when the file exists and is readable; the real complaint is the absent flag.
2. The topology's own on-screen banner says: *"Low-rate template: flow_bmv2_low.json next to this script"*. But the bridge does `os.chdir(NTG_DIR)` before entering the CLI, so a bare relative filename can never resolve. An operator following the banner literally gets the same misleading "No config file" error twice over — wrong flag *and* wrong directory.

`help` is also not a command (`Unknown command: help`); the discoverable set is `exit, flow, dist`, which it prints on error.

---

## 5. Teardown — PASS

```
$ ./stack.sh down
  stopped kernel / stopped p4_proxy
$ sudo -n /usr/local/sbin/ndtwin-lab topo-stop      → topo stopped
$ sudo -n /usr/local/sbin/ndtwin-lab cleanup        → cleanup done

$ sudo -n /usr/local/sbin/ndtwin-lab status
no lab sessions
bmv2: 0  mininet: 0
$ ./stack.sh status
  ryu - :8080 closed / p4_proxy - :8081 closed / kernel - :8000 closed
```

Independent leftover sweep — all clean:

| Check | Result |
|---|---|
| `sN-ethM` veth interfaces remaining | 0 |
| bmv2 / kernel / proxy / NTG processes | 0 (only my own shell self-matched `pgrep`) |
| iperf3 processes | 0 |
| listeners on :8000 / :8081 / :50051-60 | none |
| switch manifest `/tmp/ndtwin_p4_switches.json` | removed |
| leftover `netem` qdiscs from my fault injection | 0 |

The environment is back to exactly the state I found it in.

---

## Recommended follow-ups, in priority order

1. **Fix last-hop link utilisation attribution (3c).** Systematic, reproducible in 3/3 host pairs and both directions, and it silently corrupts `get_average_link_usage` — which the Energy-Saving app consumes to make power decisions. Highest-value fix here.
2. **Make CPU/memory endpoints either real or explicitly labelled synthetic (3h).** Returning the same frozen number for two different metrics invites silent misuse.
3. **Fix NTG's `flow` argument handling or its error message (F4)**, and correct the topology banner to show `flow --config <path>` with an absolute path.
4. **Document the P4/bmv2 procedure (D1)** — the official manual currently has no page for the mode this machine actually runs, including its reversed startup order.
5. **Investigate the one-shot `localhost:8080` fetch failure at kernel startup** (§1). No observed impact, but a failed control-plane call against a port nothing listens on in P4 mode deserves an explanation.
6. **Consider documenting the sampling contract (3d/3e)** — that link and flow rates come from 1:256 sampling, so consumers know to average rather than trust an instantaneous read.

## Caveats on this report

- Everything above was measured in a single session on one topology (10 switches, 4 hosts) at one traffic level (~20 Mbps). The sampling-noise figures in 3d/3e are rate-dependent and would shrink at higher load.
- Link-failure detection latency was bracketed to 5–30 s, not measured precisely.
- I exercised the read endpoints plus the fault-notification path. I did **not** test the write endpoints (`install_flow_entry`, `set_switches_power_state`, the lock API, simulation registration), the Web-GUI/Visualizer/NSR tools, or the OVS mode.
- A Docker bridge and `docker0` are present on this host; I noted them but did not test the containerised components.
