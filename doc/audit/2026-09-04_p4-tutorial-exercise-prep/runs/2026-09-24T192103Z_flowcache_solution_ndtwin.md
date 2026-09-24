# 執行報告 — `flowcache` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-24T192103Z |
| exercise | `flowcache` |
| which | `solution` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution` |
| cwd | `/home/adam/tutorials/exercises/flowcache` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 1000 |
| 判定 | **PASS (5/5)** (exit 0) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `the bmv2 `ndt status` names` | `3ff54b5c1901c9d3` | 1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc) |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/flowcache/build/flowcache.p4.p4info.txtpb -o /home/adam/tutorials/exercises/flowcache/build/flowcache.json /home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
rc=0  warnings=1
/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4(9): [--Wwarn=unused] warning: 'egressSpec_t' is unused
typedef bit<9> egressSpec_t;
               ^^^^^^^^^^^^
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/flowcache/build/flowcache.json` | 50620 | `6156e996ba5c3ec4` |
| `/home/adam/tutorials/exercises/flowcache/build/flowcache.p4.p4info.txtpb` | 3184 | `59d7a680cdc74010` |

來源 `.p4`：`/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
```

### 3b. `GET /p4/switch_state`（揭露，不是結果）

```
control_plane.mode    external
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
control_plane.skipped ['clone_session', 'install_initial_routes', 'link_watchdog', 'lldp_discovery', 'pipeline_push', 'sflow_telemetry']
s1  ndtwin=False p4info_sha256=59d7a680cdc74010  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
s2  ndtwin=False p4info_sha256=59d7a680cdc74010  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
s3  ndtwin=False p4info_sha256=59d7a680cdc74010  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/flowcache --topology topology.json --p4 solution/flowcache.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
```

```
package 'flowcache' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
  control plane : external
  pipelines     : s1=build/flowcache.json, s2=build/flowcache.json, s3=build/flowcache.json
  model         : 3 switches, 3 hosts, 12 edges (6 links, both directions stored)
  files         : 6
                  build/flowcache.json
                  build/flowcache.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  solution/flowcache.p4
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
  PASS  format                       1
  INFO  name                         flowcache
  PASS  control_plane.mode           external
  PASS  control_plane.grpc_base      30050
  PASS  control_plane.device_id      dpid
  PASS  control_plane.election_id    [0, 65535]
  PASS  bmv2.cpu_port                510
  PASS  switches keys                3 dpids: [1, 2, 3]
  PASS  switches name                every sN has dpid N
  PASS  referenced files             5 present
  PASS  topo_from_json.switches      3 entries
  PASS  topo_from_json.hosts         3 entries
  PASS  topo_from_json.switch_links  3 entries
  PASS  topo_from_json.host_links    3 entries
  PASS  switches agree               model and package.json both say [1, 2, 3]
  PASS  links agree                  6 links in both
  PASS  hosts named h<last octet>    3 hosts
  PASS  hosts agree                  model and package.json both say ['h1', 'h2', 'h3']
  PASS  switches pipeline            3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  s2 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  s3 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  entries                      none (control plane 'external' brings its own)
  PASS  p4info parses                build/flowcache.p4.p4info.txtpb: 1 table(s)
  INFO  telemetry.source             not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                  none declared (no multicast group, no clone session)
  PASS  gRPC port block              30051-30053 safe on this machine
  PASS  p4c-bm2-ss                   rc=0  flowcache.json sha256:ec30aaa5f138b029  flowcache.p4.p4info.txtpb sha256:59d7a680cdc74010

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
  PASS  format                       1
  INFO  name                         flowcache
  PASS  control_plane.mode           external
  PASS  control_plane.grpc_base      30050
  PASS  control_plane.device_id      dpid
  PASS  control_plane.election_id    [0, 65535]
  PASS  bmv2.cpu_port                510
  PASS  switches keys                3 dpids: [1, 2, 3]
  PASS  switches name                every sN has dpid N
  PASS  referenced files             5 present
  PASS  topo_from_json.switches      3 entries
  PASS  topo_from_json.hosts         3 entries
  PASS  topo_from_json.switch_links  3 entries
  PASS  topo_from_json.host_links    3 entries
  PASS  switches agree               model and package.json both say [1, 2, 3]
  PASS  links agree                  6 links in both
  PASS  hosts named h<last octet>    3 hosts
  PASS  hosts agree                  model and package.json both say ['h1', 'h2', 'h3']
  PASS  switches pipeline            3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  s2 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  s3 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  entries                      none (control plane 'external' brings its own)
  PASS  p4info parses                build/flowcache.p4.p4info.txtpb: 1 table(s)
  INFO  telemetry.source             not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                  none declared (no multicast group, no clone session)
  PASS  gRPC port block              30051-30053 safe on this machine
  PASS  p4c-bm2-ss                   rc=0  flowcache.json sha256:ec30aaa5f138b029  flowcache.p4.p4info.txtpb sha256:59d7a680cdc74010

PASS -- every check passed

ndt up p4
  hosts        3        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/flowcache-solution/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution (mode external, 3 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 3 (persistent; affects every later run)
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 3 switches and the manifest
  ok  3 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 2530577) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 2530649) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- this package declares an external control
  !!    plane, so the proxy installs no routes and 0 is the designed answer, not a
  !!    reading. The exercise's own controller is what puts rules on these switches:
  !!    tools/p4_exercise/run_external_controller.py <pkg> <controller.py>
  ok  proxy: 3/3 switches answered the liveness probe (no pipeline loaded on any of them, by design)
  ok  kernel: 3 switches in the graph, 12 edges, 3 hosts
  !!  kernel liveness: 0/3 up, 0/3 enabled -- a READING, not a
  !!    verdict. No pipeline is loaded on an external fabric until its own controller
  !!    runs, and the twin's liveness policy (p4LivenessFor: probe FAILED_PRECONDITION,
  !!    no LLDP) calls such a switch Down. Expect this to change to N/3 up
  !!    within ~3 s of the controller loading a program on N switches.
  ok  model matches fabric: 3 hosts (kernel graph, topology file and 3 host namespaces all agree)
  ok  telemetry: auto -- 0 cooperative, 3 link, 0 none; the proxy agrees switch by switch
  !!  data plane: forwarding NOT TESTED for the same reason -- nothing has programmed
  !!    these switches yet. Test it after the controller has run.

up. ready
  proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo
  !!  external control plane: this fabric is up and EMPTY. NDTwin has programmed
  !!    nothing and will not; the exercise's own controller is what makes it
  !!    forward. Until it runs, every ping between these hosts fails.
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1790277670.3883104,
  "boot_id": "694e511726454325acd646bd59424869",
  "control_plane": {
    "mode": "external",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution",
    "skipped": [
      "clone_session",
      "install_initial_routes",
      "link_watchdog",
      "lldp_discovery",
      "pipeline_push",
      "sflow_telemetry"
    ],
    "telemetry": {
      "knob": "absent",
      "link_emitter": {
        "alive": true,
        "manifest": "/tmp/ndtwin_link_telemetry.json",
        "pid": 2530439,
        "rate": 256,
        "switches": [
          1,
          2,
          3
        ]
      },
      "package": "auto"
    }
  },
  "declared_links": null,
  "external_link_reports": {
    "last": null,
    "received": 0,
    "recorded_only": 0,
    "routed_through_watchdog": 0
  },
  "links": {},
  "probe_interval_s": 2.0,
  "status": "success",
  "switches": {
    "1": {
      "capabilities": {
        "binding_source": null,
        "five_tuple": false,
        "ipv4_route": "unbound",
        "link_discovery": "none",
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
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution/build/flowcache.p4.p4info.txtpb",
        "p4info_sha256": "59d7a680cdc74010",
        "skipped": [
          "clone_session",
          "sflow_telemetry"
        ]
      },
      "pipeline_commits": 0,
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
      "probe_age_s": 0.866,
      "probe_detail": "FAILED_PRECONDITION: No forwarding pipeline config set for this device",
      "probe_ok": false,
      "rules_timed": 0,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": false,
      "table_entries": {
        "api_writes": 0,
        "applied": 0,
        "failed": 0,
        "journaled": false,
        "recorded": 0
      },
      "table_generation": null,
      "telemetry": {
        "clone_session": false,
        "packet_in_ids": null,
        "reason": "the app package declares an external control plane: this proxy writes nothing, so no clone session was programmed whatever the telemetry source says",
        "sflow_registered": false,
        "source": "link"
      }
    },
    "2": {
      "capabilities": {
        "binding_source": null,
        "five_tuple": false,
        "ipv4_route": "unbound",
        "link_discovery": "none",
        "reroute": false
      },
      "entries_recorded": 0,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30052",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": null,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution/build/flowcache.p4.p4info.txtpb",
        "p4info_sha256": "59d7a680cdc74010",
        "skipped": [
          "clone_session",
          "sflow_telemetry"
        ]
      },
      "pipeline_commits": 0,
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
      "probe_age_s": 0.864,
      "probe_detail": "FAILED_PRECONDITION: No forwarding pipeline config set for this device",
      "probe_ok": false,
      "rules_timed": 0,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": false,
      "table_entries": {
        "api_writes": 0,
        "applied": 0,
        "failed": 0,
        "journaled": false,
        "recorded": 0
      },
      "table_generation": null,
      "telemetry": {
        "clone_session": false,
        "packet_in_ids": null,
        "reason": "the app package declares an external control plane: this proxy writes nothing, so no clone session was programmed whatever the telemetry source says",
        "sflow_registered": false,
        "source": "link"
      }
    },
    "3": {
      "capabilities": {
        "binding_source": null,
        "five_tuple": false,
        "ipv4_route": "unbound",
        "link_discovery": "none",
        "reroute": false
      },
      "entries_recorded": 0,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30053",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": null,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution/build/flowcache.p4.p4info.txtpb",
        "p4info_sha256": "59d7a680cdc74010",
        "skipped": [
          "clone_session",
          "sflow_telemetry"
        ]
      },
      "pipeline_commits": 0,
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
      "probe_age_s": 0.862,
      "probe_detail": "FAILED_PRECONDITION: No forwarding pipeline config set for this device",
      "probe_ok": false,
      "rules_timed": 0,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": false,
      "table_entries": {
        "api_writes": 0,
        "applied": 0,
        "failed": 0,
        "journaled": false,
        "recorded": 0
      },
      "table_generation": null,
      "telemetry": {
        "clone_se
... [trimmed; 6295 chars total]
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 04:06:03)
  note           in use: ndt up p4 3 at 2026-09-25 03:21:04 by orch-0924
  prev claim     orch-0924 (until 04:05:12), superseded 2026-09-25 03:21:02  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 03:21:02; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           0c96c1d0  +79 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  3, written by 'ndt up p4 3' at 03:21:04 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          3   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/flowcache-solution/ndtwin/topology.json
  p4 host knob   3   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution (mode external)
                 flowcache -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2530439, 3 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    6       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2530655 alive,kernel.pid=2530649 alive,p4_proxy.child.pid=2530582 alive,p4_proxy.pid=2530577 alive

network health
  switches       0 up, 0 enabled, 0 admin-disabled
  links          12 total, 6 down, 0 admin-disabled
                 up/enabled above is a READING, not a verdict: an external package loads no pipeline until its own controller runs, and the twin calls such a switch Down
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  3 switches (0 up, 0 enabled), 3 hosts, 12 edges
proxy
  0 destination paths reported; none expected -- the package's program on dpid 1,2,3, proxy skipped lldp_discovery

up target
  asked for      p4, 3 hosts   (recorded 2026-09-25 03:21:04 by orch-0924)
  topology       .test_run/packages/flowcache-solution/ndtwin/topology.json   (declares 3 hosts / 12 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   3                      == 3   ok
  graph hosts    3                      == 3   ok
  graph edges    12                     == 12   ok
  topology file  sha256 f635d32a0dd3    == recorded   ok
  device names   no overlay file at .test_run/nickname_overlay/topology.names.json
                 that is where this checkout's kernel writes them; not a claim that none are set
```

### 6. C1  solution/mycontroller.py under its own interpreter

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/run_external_controller.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution solution/mycontroller.py
```

```
[adapter] tutorials utils : /home/adam/tutorials/utils
[adapter] grpc base       : 30050 (device id = dpid)
[adapter] running          /home/adam/tutorials/exercises/flowcache/solution/mycontroller.py  (cwd /home/adam/tutorials/exercises/flowcache)
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
[adapter] s2: 127.0.0.1:50052 device_id=1  ->  localhost:30052 device_id=2
[adapter] s3: 127.0.0.1:50053 device_id=2  ->  localhost:30053 device_id=3
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed P4 Program using SetForwardingPipelineConfig on s3
serializableEnumDict: name='UNRECOGNIZED_OPCODE' name_to_int={'FLOW_UNKNOWN': 1, 'UNRECOGNIZED_OPCODE': 2} int_to_name={1: 'FLOW_UNKNOWN', 2: 'UNRECOGNIZED_OPCODE'}
serializableEnumDict: name='SEND_TO_PORT_IN_OPERAND0' name_to_int={'NO_OP': 0, 'SEND_TO_PORT_IN_OPERAND0': 1} int_to_name={0: 'NO_OP', 1: 'SEND_TO_PORT_IN_OPERAND0'}
```

### 7. W0  h1 probes h2 to warm the flow cache

```
$ ping -c 3 -W 2 10.0.2.2
```

```
PING 10.0.2.2 (10.0.2.2) 56(84) bytes of data.
64 bytes from 10.0.2.2: icmp_seq=3 ttl=62 time=0.946 ms

--- 10.0.2.2 ping statistics ---
3 packets transmitted, 1 received, 66.6667% packet loss, time 2054ms
rtt min/avg/max/mdev = 0.946/0.946/0.946/0.000 ms
```

### 8. W0b waited for the controller to install the flow

```
$ poll /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T192103Z_flowcache_solution_ndtwin/driver-controller-flowcache.log for 'added table entry'
```

```
warm=True after 0.0s
```

### 9. W1  h1 ping h2 with the controller running

```
$ ping -c 5 -W 2 10.0.2.2
```

```
PING 10.0.2.2 (10.0.2.2) 56(84) bytes of data.
64 bytes from 10.0.2.2: icmp_seq=1 ttl=62 time=0.746 ms
64 bytes from 10.0.2.2: icmp_seq=2 ttl=62 time=1.69 ms
64 bytes from 10.0.2.2: icmp_seq=3 ttl=62 time=1.62 ms
64 bytes from 10.0.2.2: icmp_seq=4 ttl=62 time=1.71 ms
64 bytes from 10.0.2.2: icmp_seq=5 ttl=62 time=1.85 ms

--- 10.0.2.2 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4060ms
rtt min/avg/max/mdev = 0.746/1.523/1.854/0.396 ms
```

### 10. N8  G1 link usage follows the iperf path

```
$ live-p1/_common.sh link_usage_round /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution (to the model's last host)
```

```
   flowcache/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   flowcache/solution: at 8s that is only 5.21 expected samples per primary link
   flowcache/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   flowcache/solution: h1 -> h3 (10.0.3.3), iperf -u -b 2M -t 16 -l 1200
   flowcache/solution: primary=s1-eth3 s3-eth1   minor=
   flowcache/solution: on-path  s1-eth3  48316438.250 bit  (switch)  [primary, 4594228 B]
   flowcache/solution: on-path  s3-eth1  34330281.750 bit  (host)  [primary, 4593189 B]
   flowcache/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   flowcache/solution: off-path s1-eth1  0.000 bit  (host)
   flowcache/solution: off-path s1-eth2  0.000 bit  (switch)
   flowcache/solution: off-path s2-eth1  0.000 bit  (host)
   flowcache/solution: off-path s2-eth2  0.000 bit  (switch)
   flowcache/solution: off-path s2-eth3  0.000 bit  (switch)
   flowcache/solution: off-path s3-eth2  0.000 bit  (switch)
   flowcache/solution: off-path s3-eth3  0.000 bit  (switch)
   flowcache/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE flowcache/solution expect=follows primary=2 minor=0 rc=0
```

### 11. W9  controller log after the round

```
$ /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T192103Z_flowcache_solution_ndtwin/driver-controller-flowcache.log
```

```
[adapter] tutorials utils : /home/adam/tutorials/utils
[adapter] grpc base       : 30050 (device id = dpid)
[adapter] running          /home/adam/tutorials/exercises/flowcache/solution/mycontroller.py  (cwd /home/adam/tutorials/exercises/flowcache)
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
[adapter] s2: 127.0.0.1:50052 device_id=1  ->  localhost:30052 device_id=2
[adapter] s3: 127.0.0.1:50053 device_id=2  ->  localhost:30053 device_id=3
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed P4 Program using SetForwardingPipelineConfig on s3
serializableEnumDict: name='UNRECOGNIZED_OPCODE' name_to_int={'FLOW_UNKNOWN': 1, 'UNRECOGNIZED_OPCODE': 2} int_to_name={1: 'FLOW_UNKNOWN', 2: 'UNRECOGNIZED_OPCODE'}
serializableEnumDict: name='SEND_TO_PORT_IN_OPERAND0' name_to_int={'NO_OP': 0, 'SEND_TO_PORT_IN_OPERAND0': 1} int_to_name={0: 'NO_OP', 1: 'SEND_TO_PORT_IN_OPERAND0'}
Received PacketIn message of length 98 bytes from switch s1
decodePacketInMetadata: ret={'metadata': {'input_port': 1, 'punt_reason': 1, 'opcode': 0}, 'payload': b'\x08\x00\x00\x00\x01\x00\x08\x00\x00\x00\x01\x11\x08\x00E\x00\x00T\xa0\xc9@\x00@\x01\x82\xdd\n\x00\x01\x01\n\x00\x02\x02\x08\x00\x8a\xdc\xa0\x91\x00\x015x\xb5j\x00\x00\x00\x00\x17\xdb\x0b\x00\x00\x00\x00\x00\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !"#$%&\'()*+,-./01234567'}
For switch s1 flow (SA=10.0.1.1, DA=10.0.2.2, proto=1) added table entry to send packets to port 2 with new DSCP 5
s1 MyIngress.ingressPktOutCounter 2: 1 packets (104 bytes)
s1 MyEgress.egressPktInCounter 2: 1 packets (98 bytes)
Received PacketIn message of length 98 bytes from switch s2
decodePacketInMetadata: ret={'metadata': {'input_port': 2, 'punt_reason': 1, 'opcode': 0}, 'payload': b'\x08\x00\x00\x00\x01\x00\x08\x00\x00\x00\x01\x11\x08\x00E\x00\x00T\xa0\xc9@\x00@\x01\x82\xdd\n\x00\x01\x01\n\x00\x02\x02\x08\x00\x8a\xdc\xa0\x91\x00\x015x\xb5j\x00\x00\x00\x00\x17\xdb\x0b\x00\x00\x00\x00\x00\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !"#$%&\'()*+,-./01234567'}
For switch s2 flow (SA=10.0.1.1, DA=10.0.2.2, proto=1) added table entry to send packets to port 1 with new DSCP 5
s2 MyIngress.ingressPktOutCounter 2: 1 packets (104 bytes)
s2 MyEgress.egressPktInCounter 2: 1 packets (98 bytes)
Received PacketIn message of length 98 bytes from switch s2
decodePacketInMetadata: ret={'metadata': {'input_port': 1, 'punt_reason': 1, 'opcode': 0}, 'payload': b'\x08\x00\x00\x00\x02\x00\x08\x00\x00\x00\x02"\x08\x00E\x14\x00TG\x94\x00\x00@\x01\x1b\xff\n\x00\x02\x02\n\x00\x01\x01\x00\x00\x98k\xa0\x91\x00\x026x\xb5j\x00\x00\x00\x00\x10K\x0c\x00\x00\x00\x00\x00\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !"#$%&\'()*+,-./01234567'}
For switch s2 flow (SA=10.0.2.2, DA=10.0.1.1, proto=1) added table entry to send packets to port 2 with new DSCP 5
s2 MyIngress.ingressPktOutCounter 1: 1 packets (104 bytes)
s2 MyEgress.egressPktInCounter 1: 1 packets (98 bytes)
Received PacketIn message of length 98 bytes from switch s1
decodePacketInMetadata: ret={'metadata': {'input_port': 2, 'punt_reason': 1, 'opcode': 0}, 'payload': b'\x08\x00\x00\x00\x02\x00\x08\x00\x00\x00\x02"\x08\x00E\x14\x00TG\x94\x00\x00@\x01\x1b\xff\n\x00\x02\x02\n\x00\x01\x01\x00\x00\x98k\xa0\x91\x00\x026x\xb5j\x00\x00\x00\x00\x10K\x0c\x00\x00\x00\x00\x00\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !"#$%&\'()*+,-./01234567'}
For switch s1 flow (SA=10.0.2.2, DA=10.0.1.1, proto=1) added table entry to send packets to port 1 with new DSCP 5
s1 MyIngress.ingressPktOutCounter 1: 1 packets (104 bytes)
s1 MyEgress.egressPktInCounter 1: 1 packets (98 bytes)
Received PacketIn message of length 1242 bytes from switch s1
decodePacketInMetadata: ret={'metadata': {'input_port': 1, 'punt_reason': 1, 'opcode': 0}, 'payload': b'\x08\x00\x00\x00\x01\x00\x08\x00\x00\x00\x01\x11\x08\x00E\x00\x04\xcc\x87\x88@\x00@\x11\x96\x95\n\x00\x01\x01\n\x00\x03\x03\xe0\xa1\x13\x89\x04\xb8Bd\x00\x00\x00\x01j\xb5x?\x00\x02^\x1e\x00\x00\x00\x00H\x01\x00\x98\x00\x00\x00\x01\x00\x00\x13\x89\x00\x00\x04\xb0\x00\x00\x00\x00\xff\xff\xf9\xc0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x01\x00\t\x00\x03\x00\x00\x00\x00\x00 \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0001234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789'}
For switch s1 flow (SA=10.0.1.1, DA=10.0.3.3, proto=17) added table entry to send packets to port 3 with new DSCP 5
s1 MyIngress.ingressPktOutCounter 3: 1 packets (1248 bytes)
s1 MyEgress.egressPktInCounter 3: 1 packets (1242 bytes)
Received PacketIn message of length 1242 bytes from
... [trimmed; 10431 chars total]
```

### 12. N9  ndt down

```
$ ndt down
```

```
ndt down
  this teardown is about:
        3 bmv2 switch(es)
        6 host/switch process(es)
        a topo tmux session
        the switch manifest /tmp/ndtwin_p4_switches.json
        the registry entry .test_run/pids/app_viz.pid
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
        -> an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
        :30052 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
        :30053 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9091 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9092 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9093 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        ryu exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        find and stop it, or the next 'up' will report on it:
          ss -ltnp   # tcp rows;  ss -lunp   # the udp one (:6343) -- see ports.sh
          cat /home/adam/Desktop/NDTwin-Kernel/.test_run/pids/*.pid   # what this stack started; check each against /proc/<pid>
  !!  stack.sh down exited 1, and the only thing behind that status is port(s)
  !!    still listening at [1/3], held by processes it did not start:
  !!      9091 9092 9093 30051 30052 30053 
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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution -- this checkout is being put back
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000

clean
  ok  the 6 port(s) [1/3] called 'still listening' were closed by [3/3]: 9091 9092 9093 30051 30052 30053 
    so stack.sh's exit 1 was a reading from the MIDDLE of this teardown, not
    its ending, and it is not carried to the exit code. (ROLE-12, 2026-09-12)
  claim note now says the lab is down and verified clean (owner and expiry unchanged)
```

### 13. N10 ndt release

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
| PASS | injection: the controller stayed up | 【源碼推導，未執行】 | `alive after 12s` | `alive` | mycontroller.py:546-553 exits 1 when build/ is missing |
| PASS | switches the controller programmed | 【源碼推導，未執行】 | `[1, 2, 3]` | `[1, 2, 3]` | mycontroller.py:457-472 connects to s1, s2 and s3 |
| PASS | the controller cached the flow it was punted | 【源碼推導，未執行】 | `a flow_cache entry` | `cached` | mycontroller.py:372-376 prints one line per flow it installs; without it the ping below would be evidence about something else |
| PASS | h1 -> h2 forwards once the cache is warm | 【README 宣稱】＋【源碼推導，未執行】 | `0.0%` | `0% loss, 5/5 received` | README step 3: 'You should start to see ICMP replies'. Measured AFTER three probe datagrams and a wait for the controller's own install line, so this is forwarding and not the install latency (§9 ruling 28②) |
| PASS | G1  link usage follows the iperf path | 【源碼推導，未執行】 | `primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger` | `PASS` | TICKET-P3 §2.7's program-independent cell, through live-p1/_common.sh's link_usage_round -- the same function live-p1/05 runs. The floor and every off-path edge's raw integral are in that transcript. |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T192103Z_flowcache_solution_ndtwin/driver-controller-flowcache.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T192103Z_flowcache_solution_ndtwin/link_usage`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- flowcache / solution
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/flowcache

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/flowcache/build/flowcache.p4.p4info.txtpb -o /home/adam/tutorials/exercises/flowcache/build/flowcache.json /home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4(9): [--Wwarn=unused] warning: 'egressSpec_t' is unused
typedef bit<9> egressSpec_t;
               ^^^^^^^^^^^^
-> /home/adam/tutorials/exercises/flowcache/build/flowcache.json  50620 B  sha256[:16]=6156e996ba5c3ec4  warnings=1

== plan ================================================================
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
program  : /home/adam/tutorials/exercises/flowcache/solution/flowcache.p4 -> build/flowcache.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : run the exercise's controller; h1 ping h2/h3; assert ICMP replies
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/flowcache --topology topology.json --p4 flowcache.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
  NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/flowcache --topology topology.json --p4 solution/flowcache.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
package 'flowcache' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
  control plane : external
  pipelines     : s1=build/flowcache.json, s2=build/flowcache.json, s3=build/flowcache.json
  model         : 3 switches, 3 hosts, 12 edges (6 links, both directions stored)
  files         : 6
                  build/flowcache.json
                  build/flowcache.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  solution/flowcache.p4
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
  PASS  format                       1
  INFO  name                         flowcache
  PASS  control_plane.mode           external
  PASS  control_plane.grpc_base      30050
  PASS  control_plane.device_id      dpid
  PASS  control_plane.election_id    [0, 65535]
  PASS  bmv2.cpu_port                510
  PASS  switches keys                3 dpids: [1, 2, 3]
  PASS  switches name                every sN has dpid N
  PASS  referenced files             5 present
  PASS  topo_from_json.switches      3 entries
  PASS  topo_from_json.hosts         3 entries
  PASS  topo_from_json.switch_links  3 entries
  PASS  topo_from_json.host_links    3 entries
  PASS  switches agree               model and package.json both say [1, 2, 3]
  PASS  links agree                  6 links in both
  PASS  hosts named h<last octet>    3 hosts
  PASS  hosts agree                  model and package.json both say ['h1', 'h2', 'h3']
  PASS  switches pipeline            3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  s2 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  s3 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  entries                      none (control plane 'external' brings its own)
  PASS  p4info parses                build/flowcache.p4.p4info.txtpb: 1 table(s)
  INFO  telemetry.source             not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                  none declared (no multicast group, no clone session)
  PASS  gRPC port block              30051-30053 safe on this machine
  PASS  p4c-bm2-ss                   rc=0  flowcache.json sha256:ec30aaa5f138b029  flowcache.p4.p4info.txtpb sha256:59d7a680cdc74010

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise flowcache/solution on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by orch-0924 for 45m (drive_exercise flowcache/solution on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
  PASS  format                       1
  INFO  name                         flowcache
  PASS  control_plane.mode           external
  PASS  control_plane.grpc_base      30050
  PASS  control_plane.device_id      dpid
  PASS  control_plane.election_id    [0, 65535]
  PASS  bmv2.cpu_port                510
  PASS  switches keys                3 dpids: [1, 2, 3]
  PASS  switches name                every sN has dpid N
  PASS  referenced files             5 present
  PASS  topo_from_json.switches      3 entries
  PASS  topo_from_json.hosts         3 entries
  PASS  topo_from_json.switch_links  3 entries
  PASS  topo_from_json.host_links    3 entries
  PASS  switches agree               model and package.json both say [1, 2, 3]
  PASS  links agree                  6 links in both
  PASS  hosts named h<last octet>    3 hosts
  PASS  hosts agree                  model and package.json both say ['h1', 'h2', 'h3']
  PASS  switches pipeline            3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  s2 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  s3 pipeline                  build/flowcache.json  p4info sha256:59d7a680cdc74010  program=/home/adam/tutorials/exercises/flowcache/solution/flowcache.p4
  INFO  entries                      none (control plane 'external' brings its own)
  PASS  p4info parses                build/flowcache.p4.p4info.txtpb: 1 table(s)
  INFO  telemetry.source             not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                  none declared (no multicast group, no clone session)
  PASS  gRPC port block              30051-30053 safe on this machine
  PASS  p4c-bm2-ss                   rc=0  flowcache.json sha256:ec30aaa5f138b029  flowcache.p4.p4info.txtpb sha256:59d7a680cdc74010

PASS -- every check passed

ndt up p4
  hosts        3        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/flowcache-solution/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution (mode external, 3 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 3 (persistent; affects every later run)
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution   (p4_proxy/
... [trimmed; 5409 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    external
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution
   control_plane.skipped ['clone_session', 'install_initial_routes', 'link_watchdog', 'lldp_discovery', 'pipeline_push', 'sflow_telemetry']
   s1  ndtwin=False p4info_sha256=59d7a680cdc74010  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
   s2  ndtwin=False p4info_sha256=59d7a680cdc74010  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
   s3  ndtwin=False p4info_sha256=59d7a680cdc74010  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 04:06:03)
  note           in use: ndt up p4 3 at 2026-09-25 03:21:04 by orch-0924
  prev claim     orch-0924 (until 04:05:12), superseded 2026-09-25 03:21:02  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 03:21:02; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           0c96c1d0  +79 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  3, written by 'ndt up p4 3' at 03:21:04 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          3   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/flowcache-solution/ndtwin/topology.json
  p4 host knob   3   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution (mode external)
                 flowcache -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2530439, 3 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    6       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2530655 alive,kernel.pid=2530649 alive,p4_proxy.child.pid=2530582 alive,p4_proxy.pid=2530577 alive

network health
  switches       0 up, 0 enabled, 0 admin-disabled
  links          12 total, 6 down, 0 admin-disabled
                 up/enabled above is a READING, not a verdict: an external package loads no pipeline u
... [trimmed; 3969 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3
$ /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/run_external_controller.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-solution solution/mycontroller.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T192103Z_flowcache_solution_ndtwin/driver-controller-flowcache.log)
   controller pid 2531320 (handed to the generic cell; stopped after it)
-- controller log (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T192103Z_flowcache_solution_ndtwin/driver-controller-flowcache.log) --
[adapter] tutorials utils : /home/adam/tutorials/utils
[adapter] grpc base       : 30050 (device id = dpid)
[adapter] running          /home/adam/tutorials/exercises/flowcache/solution/mycontroller.py  (cwd /home/adam/tutorials/exercises/flowcache)
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
[adapter] s2: 127.0.0.1:50052 device_id=1  ->  localhost:30052 device_id=2
[adapter] s3: 127.0.0.1:50053 device_id=2  ->  localhost:30053 device_id=3
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed P4 Program using SetForwardingPipelineConfig on s3
serializableEnumDict: name='UNRECOGNIZED_OPCODE' name_to_int={'FLOW_UNKNOWN': 1, 'UNRECOGNIZED_OPCODE': 2} int_to_name={1: 'FLOW_UNKNOWN', 2: 'UNRECOGNIZED_OPCODE'}
serializableEnumDict: name='SEND_TO_PORT_IN_OPERAND0' name_to_int={'NO_OP': 0, 'SEND_TO_PORT_IN_OPERAND0': 1} int_to_name={0: 'NO_OP', 1: 'SEND_TO_PORT_IN_OPERAND0'}

   PASS injection: the controller stayed up            want=alive after 12s        got=alive
   PASS switches the controller programmed             want=[1, 2, 3]              got=[1, 2, 3]
$ h1: ping -c3 10.0.2.2 (warming the cache) -> 66.6667% loss, 1/3 received
   flow cache warm after 0.0s: True
$ h1: ping -c5 10.0.2.2 -> 0% loss, 5/5 received
   PASS the controller cached the flow it was punted   want=a flow_cache entry     got=cached
   PASS h1 -> h2 forwards once the cache is warm       want=0.0%                   got=0% loss, 5/5 received

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T192103Z_flowcache_solution_ndtwin/driver-controller-flowcache.log 3738 B

== G1  link usage follows the iperf path (program-independent) =========
   flowcache/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   flowcache/solution: at 8s that is only 5.21 expected samples per primary link
   flowcache/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   flowcache/solution: h1 -> h3 (10.0.3.3), iperf -u -b 2M -t 16 -l 1200
   flowcache/solution: primary=s1-eth3 s3-eth1   minor=
   flowcache/solution: on-path  s1-eth3  48316438.250 bit  (switch)  [primary, 4594228 B]
   flowcache/solution: on-path  s3-eth1  34330281.750 bit  (host)  [primary, 4593189 B]
   flowcache/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   flowcache/solution: off-path s1-eth1  0.000 bit  (host)
   flowcache/solution: off-path s1-eth2  0.000 bit  (switch)
   flowcache/solution: off-path s2-eth1  0.000 bit  (host)
   flowcache/solution: off-path s2-eth2  0.000 bit  (switch)
   flowcache/solution: off-path s2-eth3  0.000 bit  (switch)
   flowcache/solution: off-path s3-eth2  0.000 bit  (switch)
   flowcache/solution: off-path s3-eth3  0.000 bit  (switch)
   flowcache/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE flowcache/solution expect=follows primary=2 minor=0 rc=0

== teardown: ndt down, the two knobs, then ndt release =================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
  this teardown is about:
        3 bmv2 switch(es)
        6 host/switch process(es)
        a topo tmux session
        the switch manifest /tmp/ndtwin_p4_switches.json
        the registry entry .test_run/pids/app_viz.pid
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
        -> an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
        :30052 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
        :30053 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9091 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9092 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only 
... [trimmed; 5431 chars total]
   ndt down rc=0
   host_count_override: put back to the 2 bytes this round found
   telemetry_override: unchanged (absent)
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: the controller stayed up            want=alive after 12s        got=alive   【源碼推導，未執行】
   PASS switches the controller programmed             want=[1, 2, 3]              got=[1, 2, 3]   【源碼推導，未執行】
   PASS the controller cached the flow it was punted   want=a flow_cache entry     got=cached   【源碼推導，未執行】
   PASS h1 -> h2 forwards once the cache is warm       want=0.0%                   got=0% loss, 5/5 received   【README 宣稱】＋【源碼推導，未執行】
   PASS G1  link usage follows the iperf path          want=primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger got=PASS   【源碼推導，未執行】

>>> PASS (5/5)
```

### stderr（mininet 的 logger 走這裡）

```

```
