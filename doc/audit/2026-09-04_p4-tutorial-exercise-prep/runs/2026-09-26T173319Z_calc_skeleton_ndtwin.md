# 執行報告 — `calc` / skeleton

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-26T173319Z |
| exercise | `calc` |
| which | `skeleton` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton` |
| cwd | `/home/adam/tutorials/exercises/calc` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 1000 |
| 判定 | **PASS (2/2)** (exit 0) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `the bmv2 `ndt status` names` | `3ff54b5c1901c9d3` | 1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc) |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/calc/build/calc.p4.p4info.txtpb -o /home/adam/tutorials/exercises/calc/build/calc.json /home/adam/tutorials/exercises/calc/calc.p4
rc=0  warnings=7
/home/adam/tutorials/exercises/calc/calc.p4(116): [--Wwarn=parser-transition] warning: check_p4calc: implicit transition to `reject'
    state check_p4calc {
          ^^^^^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(63): [--Wwarn=unused] warning: 'P4CALC_P' is unused
const bit<8> P4CALC_P = 0x50; // 'P'
             ^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(64): [--Wwarn=unused] warning: 'P4CALC_4' is unused
const bit<8> P4CALC_4 = 0x34; // '4'
             ^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(65): [--Wwarn=unused] warning: 'P4CALC_VER' is unused
const bit<8> P4CALC_VER = 0x01; // v0.1
             ^^^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(148): [--Wwarn=unused] warning: 'send_back' is unused
    action send_back(bit<32> result) {
           ^^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(148): [--Wwarn=unused] warning: 'result' is unused
    action send_back(bit<32> result) {
                             ^^^^^^
[--Wwarn=unsupported] warning: Explicit transition to reject not supported on this target
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/calc/build/calc.json` | 13480 | `b70e4ffd6c14d9b2` |
| `/home/adam/tutorials/exercises/calc/build/calc.p4.p4info.txtpb` | 1349 | `728f02730b0a09b3` |

來源 `.p4`：`/home/adam/tutorials/exercises/calc/calc.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : topology.json
hosts    : h1, h2
switches : s1
links    : 2
```

### 3b. `GET /p4/switch_state`（揭露，不是結果）

```
control_plane.mode    ndtwin
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
s1  ndtwin=False p4info_sha256=728f02730b0a09b3  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/calc --topology topology.json --p4 calc.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
```

```
package 'calc' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
  control plane : ndtwin
  pipelines     : s1=build/calc.json
  model         : 1 switches, 2 hosts, 4 edges (2 links, both directions stored)
  files         : 7
                  build/calc.json
                  build/calc.p4.p4info.txtpb
                  calc.p4
                  ndtwin/topology.json
                  package.json
                  s1-runtime.json
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
  PASS  format                            1
  INFO  name                              calc
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     1 dpids: [1]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  6 present
  PASS  topo_from_json.switches           1 entries
  PASS  topo_from_json.hosts              2 entries
  PASS  topo_from_json.switch_links       0 entries
  PASS  topo_from_json.host_links         2 entries
  PASS  switches agree                    model and package.json both say [1]
  PASS  links agree                       2 links in both
  PASS  hosts named h<last octet>         2 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2']
  PASS  switches pipeline                 1 of 1 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/calc.json  p4info sha256:728f02730b0a09b3  program=/home/adam/tutorials/exercises/calc/calc.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              0 entries across 1 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  1 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30051 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  calc.json sha256:e5a7b8b9da37f950  calc.p4.p4info.txtpb sha256:728f02730b0a09b3

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
  PASS  format                            1
  INFO  name                              calc
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     1 dpids: [1]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  6 present
  PASS  topo_from_json.switches           1 entries
  PASS  topo_from_json.hosts              2 entries
  PASS  topo_from_json.switch_links       0 entries
  PASS  topo_from_json.host_links         2 entries
  PASS  switches agree                    model and package.json both say [1]
  PASS  links agree                       2 links in both
  PASS  hosts named h<last octet>         2 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2']
  PASS  switches pipeline                 1 of 1 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/calc.json  p4info sha256:728f02730b0a09b3  program=/home/adam/tutorials/exercises/calc/calc.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              0 entries across 1 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  1 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30051 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  calc.json sha256:e5a7b8b9da37f950  calc.p4.p4info.txtpb sha256:728f02730b0a09b3

PASS -- every check passed

ndt up p4
  hosts        2        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/calc-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton (mode ndtwin, 1 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 2 (persistent; affects every later run)
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 1 switches and the manifest
  ok  1 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
      heartbeat: the running fabric has no switch-to-switch link; nothing to send
      heartbeat plan: /tmp/ndtwin_p4_switches.json (sha256 0bb5bc7e4803), 1 switch(es), every one a live bmv2
        0 link(s) -> 0 direction(s); 2 host-facing interface(s) listened on, never sent on
  heartbeat: nothing to watch -- this fabric has no inter-switch link (rc 3)
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 28814) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 28875) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- the package's own program runs on dpid
  !!    1; the proxy says it sent no LLDP and installed no routes on this
  !!    fabric (control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery)
  !!  table entries: the package carries no entries; nothing forwards until something writes some (POST /p4/table_entry)
  ok  kernel: 1 switches, 1 up, 4 edges, 2 hosts
  ok  model matches fabric: 2 hosts (kernel graph, topology file and 2 host namespaces all agree)
  ok  telemetry: auto -- 0 cooperative, 1 link, 0 none; the proxy agrees switch by switch
  !!  data plane: h1 cannot reach 10.0.1.2 -- a READING, not a verdict: under the package's
  !!    own program (728f02730b0a09b3) whether plain IPv4 forwards is the package's claim, not
  !!    NDTwin's (a skeleton does not forward; source_routing needs its header).
  !!    The exercise's driver judges it.

up. ready
  proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo
  !!  package pipeline: NDTwin discovered no links and installed no routes on this
  !!    fabric; forwarding is whatever the package's 0 entries on
  !!    1 switch(es) make of it. ndt status quotes no sample rate for it.
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1790444006.7889948,
  "boot_id": "1a627a74ab3d4b7e98f42589120e729b",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton",
    "skipped": [
      "install_initial_routes",
      "link_watchdog",
      "lldp_discovery"
    ],
    "telemetry": {
      "knob": "absent",
      "link_emitter": {
        "alive": true,
        "manifest": "/tmp/ndtwin_link_telemetry.json",
        "pid": 28690,
        "rate": 256,
        "switches": [
          1
        ]
      },
      "package": "auto"
    }
  },
  "declared_links": {
    "directions": 0,
    "error": null
  },
  "external_link_reports": {
    "last": null,
    "received": 0,
    "recorded_only": 0,
    "routed_through_watchdog": 0
  },
  "heartbeat": {
    "census": {
      "arms": 26,
      "arms_where_a_host_saw_a_frame": 0,
      "heartbeat_ran": 20,
      "measured": "2026-09-26, TICKET-P4-heartbeat segment S (census part)",
      "no_inter_switch_link": 4,
      "not_built": 2,
      "raw": "doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T052148Z_S_heartbeat/40_census.tsv",
      "summary": "13 tutorials exercises x skeleton/solution. On the 20 arms where the heartbeat ran, no host received a heartbeat frame, and the daemon counted none leaving a host-facing port and none forwarded to another switch. calc and multicast are one switch (no inter-switch link, nothing sent); basic_tunnel and flowcache skeletons do not build. Segment S's census started the heartbeat by hand (the helper, not ndt) on all 20; `ndt up p4 --app` starts it on 17 of them -- the other 3 (p4runtime skeleton and solution, flowcache solution) are external control planes, where `ndt up` does not start it."
    },
    "detail": "the report says status 'stopped' (stopped by SIGTERM)",
    "directions": 0,
    "error": null,
    "frame": {
      "bytes": 60,
      "ethertype": "0x88B5",
      "one_per_direction_every_s": null
    },
    "frames_reached_hosts": false,
    "missing_directions": [],
    "note": "the heartbeat proves a veth carries frames, not that a switch is alive (a switch powered off by P4PowerStrategy is still heard); its frames are also what link telemetry samples, 1 in 256, on those veths",
    "period_s": null,
    "pid": 25754,
    "report": "/run/ndtwin-lab/heartbeat.json",
    "report_age_s": null,
    "session": "0bc442505d18eda6",
    "side_effects": {
      "foreign_frames": 0,
      "forwarded_between_switches": 0,
      "forwarded_to_hosts": 0,
      "misdelivered": 0
    },
    "state": "heartbeat_not_running",
    "undeclared_directions": [],
    "watchdog": "running",
    "watchdog_passes": []
  },
  "links": {},
  "probe_interval_s": 2.0,
  "reroute": {
    "available": false,
    "detail": "a foreign switch's route table is not NDTwin's (unbound): a cut link is detected and told to the kernel, and no route is rewritten",
    "reason": "unbound"
  },
  "status": "success",
  "switches": {
    "1": {
      "capabilities": {
        "binding_source": null,
        "five_tuple": false,
        "ipv4_route": "unbound",
        "link_discovery": "declared",
        "reroute": false
      },
      "entries_recorded": 0,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30051",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": null,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton/build/calc.p4.p4info.txtpb",
        "p4info_sha256": "728f02730b0a09b3",
        "skipped": [
          "clone_session",
          "sflow_telemetry"
        ]
      },
      "pipeline_commits": 1,
      "pre_entries": {
        "clone": {
          "applied": 0,
          "failed": 0,
          "recorded": 0
        },
        "multicast": {
          "applied": 0,
          "failed": 0,
          "recorded": 0
        }
      },
      "probe_age_s": 0.013,
      "probe_detail": "answered GetForwardingPipelineConfig",
      "probe_ok": true,
      "rules_timed": 0,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": true,
      "table_entries": {
        "api_writes": 0,
        "applied": 0,
        "failed": 0,
        "journaled": false,
        "recorded": 0
      },
      "table_generation": "5cc2338ca47a498095abc394e1871d01",
      "telemetry": {
        "clone_session": false,
        "packet_in_ids": null,
        "reason": "this switch runs the app package's own pipeline, which does not clone to the CPU port; its samples come from 'link'",
        "sflow_registered": false,
        "source": "link"
      }
    }
  }
}
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 02:18:20)
  note           in use: ndt up p4 2 at 2026-09-27 01:33:20 by orch-0926
  prev claim     orch-0926 (until 02:17:54), superseded 2026-09-27 01:33:19  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-27 01:33:19; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           3f8c2abf  +91 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  2, written by 'ndt up p4 2' at 01:33:20 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          2   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/calc-skeleton/ndtwin/topology.json
  p4 host knob   2   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton (mode ndtwin)
                 calc -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 28690, 1 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  1       topo session   present
  host/switch    3       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  heartbeat      stopped (stopped by SIGTERM), 16 s ago
  pidfiles       kernel.child.pid=28880 alive,kernel.pid=28875 alive,p4_proxy.child.pid=28819 alive,p4_proxy.pid=28814 alive

network health
  switches       1 up, 1 enabled, 0 admin-disabled
  links          4 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  1 switches (1 up, 1 enabled), 2 hosts, 4 edges
proxy
  2 destination paths reported; none expected -- the package's program on dpid 1, proxy skipped lldp_discovery

up target
  asked for      p4, 2 hosts   (recorded 2026-09-27 01:33:20 by orch-0926)
  topology       .test_run/packages/calc-skeleton/ndtwin/topology.json   (declares 2 hosts / 4 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   2                      == 2   ok
  graph hosts    2                      == 2   ok
  graph edges    4                      == 4   ok
  topology file  sha256 815e31bb4d98    == recorded   ok
  device names   no overlay file at .test_run/nickname_overlay/topology.names.json
                 that is where this checkout's kernel writes them; not a claim that none are set
```

### 6. K1  h1 calc.py <<< 1+1

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/calc/calc.py   <<< b'1+1\nquit\n'
```

```
/home/adam/tutorials/exercises/calc/calc.py:50: SyntaxWarning: invalid escape sequence '\s'
  pattern = "^\s*([0-9]+)\s*"
/home/adam/tutorials/exercises/calc/calc.py:59: SyntaxWarning: invalid escape sequence '\s'
  pattern = "^\s*([-+&|^])\s*"
> 1+1
Didn't receive response
>
```

### 7. N8  G1 link usage follows the iperf path -- NOT RUN

```
$ live-p1/_common.sh link_usage_round (not called)
```

```
NOT RUN: the skeleton arm is a fabric the exercise says should not forward; there is no path for a program-independent cell to follow
```

### 8. N9  ndt down

```
$ ndt down
```

```
ndt down
  this teardown is about:
        1 bmv2 switch(es)
        3 host/switch process(es)
        a topo tmux session
        the switch manifest /tmp/ndtwin_p4_switches.json
        the registry entry .test_run/pids/kernel.child.pid
        the registry entry .test_run/pids/kernel.pid
        the registry entry .test_run/pids/p4_proxy.child.pid
        the registry entry .test_run/pids/p4_proxy.pid
        a held port in ports.sh's table
[1/3] kernel + proxy/Ryu
        stopped kernel
        kernel exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        stopped p4_proxy
        p4_proxy exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        -> an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
        :30051 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9091 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        ryu exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        find and stop it, or the next 'up' will report on it:
          ss -ltnp   # tcp rows;  ss -lunp   # the udp one (:6343) -- see ports.sh
          cat /home/adam/Desktop/NDTwin-Kernel/.test_run/pids/*.pid   # what this stack started; check each against /proc/<pid>
  !!  stack.sh down exited 1, and the only thing behind that status is port(s)
  !!    still listening at [1/3], held by processes it did not start:
  !!      9091 30051 
  !!    [1/3] runs BEFORE the data-plane sweep in [3/3], so on a live P4 fabric this
  !!    is the fabric this teardown is about to remove, accusing itself. The verdict
  !!    on these ports is taken AFTER 'verify clean' below, not here. (ROLE-12)
[2/3] topology session
      topo stopped
[3/3] sweep
        none           ntg_bmv2_topo
        none           p4_testbed_topo
        none           OVS testbed_topo
        none           NTG testbed_topo
        none           simple_switch_grpc
      cleanup done
  ok  this step ran the Mininet sweep (mn -c) for you
    [3/3] is 'ndtwin-lab cleanup' and its sweep runs 'mn -c' before it sweeps
    simple_switch_grpc, so the advice stack.sh prints at [1/3] about running that
    command by hand is advice this teardown has already acted on -- which is why
    [1/3] filters it out.
  cleared the 'ndt up' target record (.test_run/up.target)

verify clean
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton -- this checkout is being put back
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000

clean
  ok  the 2 port(s) [1/3] called 'still listening' were closed by [3/3]: 9091 30051 
    so stack.sh's exit 1 was a reading from the MIDDLE of this teardown, not
    its ending, and it is not carried to the exit code. (ROLE-12, 2026-09-12)
  claim note now says the lab is down and verified clean (owner and expiry unchanged)
```

### 9. N10 ndt release

```
$ ndt release
```

```
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
```

## 5. 判定表

| 結果 | 期望 | 來源等級 | want | got | 依據 |
|---|---|---|---|---|---|
| PASS | injection: calc.py read the expression | 【README 宣稱】＋【源碼推導，未執行】 | `> 1+1` | `yes` | calc.py:80-84 prints the prompt and echoes the line it read; without this 'no answer' would also describe a client that never sent anything |
| PASS | RED ARM: the skeleton must not answer | 【README 宣稱】＋【源碼推導，未執行】 | `Didn't receive response` | `Didn't receive response` | README step 1.3's own transcript; calc.p4:116-126 leaves check_p4calc with no transition, so hdr.p4calc is never valid and :205-210 drops. If this is green the solution's answer proves nothing. |

## 6. 交換機 log / pcap


## 8. 完整 transcript

### stdout

```
drive_exercise.py -- calc / skeleton
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/calc

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/calc/build/calc.p4.p4info.txtpb -o /home/adam/tutorials/exercises/calc/build/calc.json /home/adam/tutorials/exercises/calc/calc.p4
/home/adam/tutorials/exercises/calc/calc.p4(116): [--Wwarn=parser-transition] warning: check_p4calc: implicit transition to `reject'
    state check_p4calc {
          ^^^^^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(63): [--Wwarn=unused] warning: 'P4CALC_P' is unused
const bit<8> P4CALC_P = 0x50; // 'P'
             ^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(64): [--Wwarn=unused] warning: 'P4CALC_4' is unused
const bit<8> P4CALC_4 = 0x34; // '4'
             ^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(65): [--Wwarn=unused] warning: 'P4CALC_VER' is unused
const bit<8> P4CALC_VER = 0x01; // v0.1
             ^^^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(148): [--Wwarn=unused] warning: 'send_back' is unused
    action send_back(bit<32> result) {
           ^^^^^^^^^
/home/adam/tutorials/exercises/calc/calc.p4(148): [--Wwarn=unused] warning: 'result' is unused
    action send_back(bit<32> result) {
                             ^^^^^^
[--Wwarn=unsupported] warning: Explicit transition to reject not supported on this target
-> /home/adam/tutorials/exercises/calc/build/calc.json  13480 B  sha256[:16]=b70e4ffd6c14d9b2  warnings=7

== plan ================================================================
topology : topology.json
hosts    : h1, h2
switches : s1
links    : 2
program  : /home/adam/tutorials/exercises/calc/calc.p4 -> build/calc.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : h1 calc.py <<< '1+1'; assert the answer line (solution 2, skeleton no response)
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/calc --topology topology.json --p4 calc.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
  NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/calc --topology topology.json --p4 calc.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
package 'calc' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
  control plane : ndtwin
  pipelines     : s1=build/calc.json
  model         : 1 switches, 2 hosts, 4 edges (2 links, both directions stored)
  files         : 7
                  build/calc.json
                  build/calc.p4.p4info.txtpb
                  calc.p4
                  ndtwin/topology.json
                  package.json
                  s1-runtime.json
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
  PASS  format                            1
  INFO  name                              calc
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     1 dpids: [1]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  6 present
  PASS  topo_from_json.switches           1 entries
  PASS  topo_from_json.hosts              2 entries
  PASS  topo_from_json.switch_links       0 entries
  PASS  topo_from_json.host_links         2 entries
  PASS  switches agree                    model and package.json both say [1]
  PASS  links agree                       2 links in both
  PASS  hosts named h<last octet>         2 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2']
  PASS  switches pipeline                 1 of 1 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/calc.json  p4info sha256:728f02730b0a09b3  program=/home/adam/tutorials/exercises/calc/calc.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              0 entries across 1 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  1 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30051 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  calc.json sha256:e5a7b8b9da37f950  calc.p4.p4info.txtpb sha256:728f02730b0a09b3

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise calc/skeleton on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by orch-0926 for 45m (drive_exercise calc/skeleton on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
  PASS  format                            1
  INFO  name                              calc
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     1 dpids: [1]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  6 present
  PASS  topo_from_json.switches           1 entries
  PASS  topo_from_json.hosts              2 entries
  PASS  topo_from_json.switch_links       0 entries
  PASS  topo_from_json.host_links         2 entries
  PASS  switches agree                    model and package.json both say [1]
  PASS  links agree                       2 links in both
  PASS  hosts named h<last octet>         2 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2']
  PASS  switches pipeline                 1 of 1 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/calc.json  p4info sha256:728f02730b0a09b3  program=/home/adam/tutorials/exercises/calc/calc.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              0 entries across 1 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  1 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30051 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  calc.json sha256:e5a7b8b9da37f950  calc.p4.p4info.txtpb sha256:728f02730b0a09b3

PASS -- every check passed

ndt up p4
  hosts        2        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/calc-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton (mode ndtwin, 1 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 2 (persistent; affects every later run)
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab i
... [trimmed; 5314 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=728f02730b0a09b3  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 02:18:20)
  note           in use: ndt up p4 2 at 2026-09-27 01:33:20 by orch-0926
  prev claim     orch-0926 (until 02:17:54), superseded 2026-09-27 01:33:19  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-27 01:33:19; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           3f8c2abf  +91 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  2, written by 'ndt up p4 2' at 01:33:20 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          2   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/calc-skeleton/ndtwin/topology.json
  p4 host knob   2   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/calc-skeleton (mode ndtwin)
                 calc -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 28690, 1 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  1       topo session   present
  host/switch    3       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  heartbeat      stopped (stopped by SIGTERM), 16 s ago
  pidfiles       kernel.child.pid=28880 alive,kernel.pid=28875 alive,p4_proxy.child.pid=28819 alive,p4_proxy.pid=28814 alive

network health
  switches       1 up, 1 enabled, 0 admin-disabled
  links          4 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none run
... [trimmed; 3811 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.1.2
$ h1: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/calc/calc.py   <<< b'1+1\nquit\n'
/home/adam/tutorials/exercises/calc/calc.py:50: SyntaxWarning: invalid escape sequence '\s'
  pattern = "^\s*([0-9]+)\s*"
/home/adam/tutorials/exercises/calc/calc.py:59: SyntaxWarning: invalid escape sequence '\s'
  pattern = "^\s*([-+&|^])\s*"
> 1+1
Didn't receive response
> 
   PASS injection: calc.py read the expression         want=> 1+1                  got=yes
   PASS RED ARM: the skeleton must not answer          want=Didn't receive response got=Didn't receive response

-- switch logs --

== G1  link usage follows the iperf path (program-independent) =========
   NOT RUN: the skeleton arm is a fabric the exercise says should not forward; there is no path for a program-independent cell to follow
   (a cell with no flow to follow is recorded as not run, never as a pass)

== teardown: ndt down, the two knobs, then ndt release =================
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
  this teardown is about:
        1 bmv2 switch(es)
        3 host/switch process(es)
        a topo tmux session
        the switch manifest /tmp/ndtwin_p4_switches.json
        the registry entry .test_run/pids/kernel.child.pid
        the registry entry .test_run/pids/kernel.pid
        the registry entry .test_run/pids/p4_proxy.child.pid
        the registry entry .test_run/pids/p4_proxy.pid
        a held port in ports.sh's table
[1/3] kernel + proxy/Ryu
        stopped kernel
        kernel exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        stopped p4_proxy
        p4_proxy exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        -> an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
        :30051 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9091 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        ryu exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        find and stop it, or the next 'up' will report on it:
          ss -ltnp   # tcp rows;  ss -lunp   # the udp one (:6343) -- see ports.sh
          cat /home/adam/Desktop/NDTwin-Kernel/.test_run/pids/*.pid   # what this stack started; check each against /proc/<pid>
  !!  stack.sh down exited 1, and the only thing behind that status is port(s)
  !!    still listening at [1/3], held by processes it did not start:
  !!      9091 30051 
  !!    [1/3] runs BEFORE the data-plane sweep in [3/3], so on a live P4 fabric this
  !!    is the fabric this teardown is about to remove, accusing itself. The verdict
  !!    on these ports is taken AFTER 'verify clean' below, not here. (ROLE-12)
[2/3] topology session
      topo stopped
[3/3] sweep
        none           ntg_bmv2_topo
        none           p4_testbed_topo
        none           OVS testbed_topo
        none           NTG testbed_topo
        none           simple_switch_grpc
      cleanup done
  ok  this step ran the Mininet sweep (mn -c) for you
    [3/3] is 'ndtwin-lab cleanup' and its sweep runs 'mn -c' before it sweeps
    simple_switch_grpc, so the advice stack.sh prints at [1/3] about running that
    command by hand is advice this teardown has already acted on -- which is why
    [1/3] filters it out.
  cleared the 'ndt up' target record (.tes
... [trimmed; 3666 chars total]
   ndt down rc=0
   host_count_override: put back to the 2 bytes this round found
   telemetry_override: unchanged (absent)
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: calc.py read the expression         want=> 1+1                  got=yes   【README 宣稱】＋【源碼推導，未執行】
   PASS RED ARM: the skeleton must not answer          want=Didn't receive response got=Didn't receive response   【README 宣稱】＋【源碼推導，未執行】

>>> PASS (2/2)
```

### stderr（mininet 的 logger 走這裡）

```

```
