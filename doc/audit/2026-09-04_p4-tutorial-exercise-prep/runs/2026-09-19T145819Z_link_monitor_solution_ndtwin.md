# 執行報告 — `link_monitor` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-19T145819Z |
| exercise | `link_monitor` |
| which | `solution` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution` |
| cwd | `/home/adam/tutorials/exercises/link_monitor` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 1000 |
| 判定 | **PASS (4/4)** (exit 0) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `the bmv2 `ndt status` names` | `3ff54b5c1901c9d3` | 1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc) |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/link_monitor/build/link_monitor.p4.p4info.txtpb -o /home/adam/tutorials/exercises/link_monitor/build/link_monitor.json /home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
rc=0  warnings=0

```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/link_monitor/build/link_monitor.json` | 56155 | `b4a2d84b5e5c547b` |
| `/home/adam/tutorials/exercises/link_monitor/build/link_monitor.p4.p4info.txtpb` | 1732 | `7303ccb1dc2c61bf` |

來源 `.p4`：`/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
```

### 3b. `GET /p4/switch_state`（揭露，不是結果）

```
control_plane.mode    ndtwin
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
s1  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
s2  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
s3  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
s4  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/link_monitor --topology pod-topo/topology.json --p4 solution/link_monitor.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
```

```
package 'link_monitor' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  control plane : ndtwin
  pipelines     : s1=build/link_monitor.json, s2=build/link_monitor.json, s3=build/link_monitor.json, s4=build/link_monitor.json
  model         : 4 switches, 4 hosts, 16 edges (8 links, both directions stored)
  files         : 10
                  build/link_monitor.json
                  build/link_monitor.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  pod-topo/s1-runtime.json
                  pod-topo/s2-runtime.json
                  pod-topo/s3-runtime.json
                  pod-topo/s4-runtime.json
                  pod-topo/topology.json
                  solution/link_monitor.p4
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  PASS  format                            1
  INFO  name                              link_monitor
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     4 dpids: [1, 2, 3, 4]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  9 present
  PASS  topo_from_json.switches           4 entries
  PASS  topo_from_json.hosts              4 entries
  PASS  topo_from_json.switch_links       4 entries
  PASS  topo_from_json.host_links         4 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3, 4]
  PASS  links agree                       8 links in both
  PASS  hosts named h<last octet>         4 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3', 'h4']
  PASS  switches pipeline                 4 of 4 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s2 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s3 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s4 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              24 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  link_monitor.json sha256:6cf0c5e39ed18161  link_monitor.p4.p4info.txtpb sha256:7303ccb1dc2c61bf

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  PASS  format                            1
  INFO  name                              link_monitor
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     4 dpids: [1, 2, 3, 4]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  9 present
  PASS  topo_from_json.switches           4 entries
  PASS  topo_from_json.hosts              4 entries
  PASS  topo_from_json.switch_links       4 entries
  PASS  topo_from_json.host_links         4 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3, 4]
  PASS  links agree                       8 links in both
  PASS  hosts named h<last octet>         4 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3', 'h4']
  PASS  switches pipeline                 4 of 4 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s2 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s3 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s4 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              24 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  link_monitor.json sha256:6cf0c5e39ed18161  link_monitor.p4.p4info.txtpb sha256:7303ccb1dc2c61bf

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/link_monitor-solution/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution (mode ndtwin, 4 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 4 switches and the manifest
  ok  4 switches up after 7s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 2916864) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 .. up
        started kernel (pid 2916968) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- the package's own program runs on dpid
  !!    1,2,3,4; the proxy says it sent no LLDP and installed no routes on this
  !!    fabric (control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery)
  ok  table entries: 6/6 applied on 4 switch(es), 0 failed
  ok  kernel: 4 switches, 4 up, 16 edges, 4 hosts
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces all agree)
  ok  telemetry: auto -- 0 cooperative, 4 link, 0 none; the proxy agrees switch by switch
  ok  data plane: h1 -> 10.0.2.2 forwards

up. ready
  proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo
  !!  package pipeline: NDTwin discovered no links and installed no routes on this
  !!    fabric; forwarding is whatever the package's 24 entries on
  !!    4 switch(es) make of it. ndt status quotes no sample rate for it.
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1789829909.4977653,
  "boot_id": "6e41cabaa2164cd3b7770cd567127ca0",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution",
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
        "pid": 2916769,
        "rate": 256,
        "switches": [
          1,
          2,
          3,
          4
        ]
      },
      "package": "auto"
    }
  },
  "links": {},
  "probe_interval_s": 2.0,
  "status": "success",
  "switches": {
    "1": {
      "entries_recorded": 6,
      "grpc_addr": "localhost:30051",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789829910.6954663,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution/build/link_monitor.p4.p4info.txtpb",
        "p4info_sha256": "7303ccb1dc2c61bf",
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
      "probe_age_s": 0.583,
      "probe_detail": "answered GetForwardingPipelineConfig",
      "probe_ok": true,
      "rules_timed": 6,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": true,
      "table_entries": {
        "api_writes": 0,
        "applied": 6,
        "failed": 0,
        "journaled": false,
        "recorded": 6
      },
      "table_generation": "ce8457d99d3349ba819fd57cbcd48f37",
      "telemetry": {
        "clone_session": false,
        "packet_in_ids": null,
        "reason": "this switch runs the app package's own pipeline, which does not clone to the CPU port; its samples come from 'link'",
        "sflow_registered": false,
        "source": "link"
      }
    },
    "2": {
      "entries_recorded": 6,
      "grpc_addr": "localhost:30052",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789829910.705987,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution/build/link_monitor.p4.p4info.txtpb",
        "p4info_sha256": "7303ccb1dc2c61bf",
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
      "probe_age_s": 0.582,
      "probe_detail": "answered GetForwardingPipelineConfig",
      "probe_ok": true,
      "rules_timed": 6,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": true,
      "table_entries": {
        "api_writes": 0,
        "applied": 6,
        "failed": 0,
        "journaled": false,
        "recorded": 6
      },
      "table_generation": "94f58f6aa08b456eb6954560e78802e2",
      "telemetry": {
        "clone_session": false,
        "packet_in_ids": null,
        "reason": "this switch runs the app package's own pipeline, which does not clone to the CPU port; its samples come from 'link'",
        "sflow_registered": false,
        "source": "link"
      }
    },
    "3": {
      "entries_recorded": 6,
      "grpc_addr": "localhost:30053",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789829910.7147214,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution/build/link_monitor.p4.p4info.txtpb",
        "p4info_sha256": "7303ccb1dc2c61bf",
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
      "probe_age_s": 0.581,
      "probe_detail": "answered GetForwardingPipelineConfig",
      "probe_ok": true,
      "rules_timed": 6,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": true,
      "table_entries": {
        "api_writes": 0,
        "applied": 6,
        "failed": 0,
        "journaled": false,
        "recorded": 6
      },
      "table_generation": "e7388126be494af4a96a729ba24db7ce",
      "telemetry": {
        "clone_session": false,
        "packet_in_ids": null,
        "reason": "this switch runs the app package's own pipeline, which does not clone to the CPU port; its samples come from 'link'",
        "sflow_registered": false,
        "source": "link"
      }
    },
    "4": {
      "entries_recorded": 6,
      "grpc_addr": "localhost:30054",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789829910.7242553,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution/build/link_monitor.p4.p4info.txtpb",
        "p4info_sha256": "7303ccb1dc2c61bf",
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
          "failed": 
... [trimmed; 6785 chars total]
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 23:43:19)
  note           in use: ndt up p4 4 at 2026-09-19 22:58:21 by p3-live-06
  prev claim     p3-live-06 (until 23:42:39), superseded 2026-09-19 22:58:18  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-19 22:58:17; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           f3b6d09c  +61 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 22:58:19)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/link_monitor-solution/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution (mode ndtwin)
                 link_monitor -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2916769, 4 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2916973 alive,kernel.pid=2916968 alive,p4_proxy.child.pid=2916869 alive,p4_proxy.pid=2916864 alive

network health
  switches       4 up, 4 enabled, 0 admin-disabled
  links          16 total, 8 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  4 switches (4 up, 4 enabled), 4 hosts, 16 edges
proxy
  4 destination paths reported; none expected -- the package's program on dpid 1,2,3,4, proxy skipped lldp_discovery

up target
  asked for      p4, 4 hosts   (recorded 2026-09-19 22:58:21 by p3-live-06)
  topology       .test_run/packages/link_monitor-solution/ndtwin/topology.json   (declares 4 hosts / 16 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   4                      == 4   ok
  graph hosts    4                      == 4   ok
  graph edges    16                     == 16   ok
  topology file  sha256 d9dc6f1e7729    == recorded   ok
  device names   no overlay file at .test_run/nickname_overlay/topology.names.json
                 that is where this checkout's kernel writes them; not a claim that none are set
```

### 6. L1  h1 starts receive.py

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/link_monitor/receive.py
```

```
(background; output below)
```

### 7. L2  h1 send.py (probes)

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/link_monitor/send.py
```

```
........
```

### 8. L3  h1 receive.py output

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/link_monitor/receive.py
```

```
sniffing on eth0

Switch 1 - Port 1: 0.00019533743233372488 Mbps
Switch 4 - Port 2: 8.04914053960365e-05 Mbps
Switch 2 - Port 3: 7.084487273986574e-05 Mbps
Switch 3 - Port 2: 6.118684362098642e-05 Mbps
Switch 1 - Port 3: 5.152861169775973e-05 Mbps
Switch 3 - Port 1: 4.1868955001877396e-05 Mbps
Switch 2 - Port 4: 3.220871894047809e-05 Mbps
Switch 4 - Port 1: 2.2544508798430687e-05 Mbps
Switch 1 - Port 4: 1.2884717879035853e-05 Mbps

Switch 1 - Port 1: 0.0013175669714193842 Mbps
Switch 4 - Port 2: 0.0011762134356900402 Mbps
Switch 2 - Port 3: 0.0010349744931712264 Mbps
Switch 3 - Port 2: 0.0008940037054100948 Mbps
Switch 1 - Port 3: 0.0007528016867462794 Mbps
Switch 3 - Port 1: 0.0006116909431509729 Mbps
Switch 2 - Port 4: 0.0004704826073361961 Mbps
Switch 4 - Port 1: 0.00032932620446648667 Mbps
Switch 1 - Port 4: 0.00018817478301095335 Mbps

Switch 1 - Port 1: 0.0013162469334090697 Mbps
Switch 4 - Port 2: 0.0011752020613044155 Mbps
Switch 2 - Port 3: 0.0010342081990380688 Mbps
Switch 3 - Port 2: 0.0008929192094140315 Mbps
Switch 1 - Port 3: 0.0007519275486476564 Mbps
Switch 3 - Port 1: 0.0006109465167236818 Mbps
Switch 2 - Port 4: 0.000470088650884746 Mbps
Switch 4 - Port 1: 0.00032902467685076383 Mbps
Switch 1 - Port 4: 0.00018801815158571767 Mbps

Switch 1 - Port 1: 0.0013100372834271511 Mbps
Switch 4 - Port 2: 0.0011699680891203693 Mbps
Switch 2 - Port 3: 0.0010296492172325838 Mbps
Switch 3 - Port 2: 0.000889139338468633 Mbps
Switch 1 - Port 3: 0.0007488138904976687 Mbps
Switch 3 - Port 1: 0.0006084842598578839 Mbps
Switch 2 - Port 4: 0.000467981760410888 Mbps
Switch 4 - Port 1: 0.00032762268787113507 Mbps
Switch 1 - Port 4: 0.00018721497251742708 Mbps

Switch 1 - Port 1: 0.0013279713853784818 Mbps
Switch 4 - Port 2: 0.0011855387977451053 Mbps
Switch 2 - Port 3: 0.0010431257420911114 Mbps
Switch 3 - Port 2: 0.0009009792221546048 Mbps
Switch 1 - Port 3: 0.0007587193449722988 Mbps
Switch 3 - Port 1: 0.0006162889921304636 Mbps
Switch 2 - Port 4: 0.00047401134072132673 Mbps
Switch 4 - Port 1: 0.00033175420962521646 Mbps
Switch 1 - Port 4: 0.00018954594860343138 Mbps

Switch 1 - Port 1: 0.0013170789071380972 Mbps
Switch 4 - Port 2: 0.001175929891059895 Mbps
Switch 2 - Port 3: 0.0010349369629304398 Mbps
Switch 3 - Port 2: 0.0008935981336340735 Mbps
Switch 1 - Port 3: 0.0007525051661243338 Mbps
Switch 3 - Port 1: 0.0006115320838739773 Mbps
Switch 2 - Port 4: 0.0004705047437660572 Mbps
Switch 4 - Port 1: 0.00032938173284200557 Mbps
Switch 1 - Port 4: 0.00018823750867657266 Mbps

Switch 1 - Port 1: 0.0013159518032652053 Mbps
Switch 4 - Port 2: 0.0011749673212213786 Mbps
Switch 2 - Port 3: 0.001033984404068572 Mbps
Switch 3 - Port 2: 0.000893090592877015 Mbps
Switch 1 - Port 3: 0.0007520549313456104 Mbps
Switch 3 - Port 1: 0.0006110506153593056 Mbps
Switch 2 - Port 4: 0.0004700145410748645 Mbps
Switch 4 - Port 1: 0.00032903466517295374 Mbps
Switch 1 - Port 4: 0.0001880260690310292 Mbps

Switch 1 - Port 1: 0.0013174791448148765 Mbps
Switch 4 - Port 2: 0.0011760774094150878 Mbps
Switch 2 - Port 3: 0.0010345830953432983 Mbps
Switch 3 - Port 2: 0.0008934641918753539 Mbps
Switch 1 - Port 3: 0.0007521646770539825 Mbps
Switch 3 - Port 1: 0.00061113499717448 Mbps
Switch 2 - Port 4: 0.00047005596603845646 Mbps
Switch 4 - Port 1: 0.00032906141108584387 Mbps
Switch 1 - Port 4: 0.00018802330705577046 Mbps
```

### 9. N8  G1 link usage follows the iperf path

```
$ live-p1/_common.sh link_usage_round /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution (to the model's last host)
```

```
   link_monitor/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   link_monitor/solution: at 8s that is only 5.21 expected samples per primary link
   link_monitor/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   link_monitor/solution: h1 -> h4 (10.0.4.4), iperf -u -b 2M -t 16 -l 1200
   link_monitor/solution: primary=s1-eth4 s2-eth2 s4-eth1   minor=
   link_monitor/solution: on-path  s1-eth4  15891937.250 bit  (switch)  [primary, 4345828 B]
   link_monitor/solution: on-path  s2-eth2  41954560.500 bit  (host)  [primary, 4346031 B]
   link_monitor/solution: on-path  s4-eth1  38777040.750 bit  (switch)  [primary, 4345828 B]
   link_monitor/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   link_monitor/solution: off-path s1-eth1  0.000 bit  (host)
   link_monitor/solution: off-path s1-eth2  0.000 bit  (host)
   link_monitor/solution: off-path s1-eth3  0.000 bit  (switch)
   link_monitor/solution: off-path s2-eth1  0.000 bit  (host)
   link_monitor/solution: off-path s2-eth3  0.000 bit  (switch)
   link_monitor/solution: off-path s2-eth4  0.000 bit  (switch)
   link_monitor/solution: off-path s3-eth1  0.000 bit  (switch)
   link_monitor/solution: off-path s3-eth2  0.000 bit  (switch)
   link_monitor/solution: off-path s4-eth2  0.000 bit  (switch)
   link_monitor/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE link_monitor/solution expect=follows primary=3 minor=0 rc=0
```

### 10. N9  ndt down

```
$ ndt down
```

```
ndt down
  this teardown is about:
        4 bmv2 switch(es)
        8 host/switch process(es)
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
        -> an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
        :30054 is still listening, held by a process this user cannot see (probably root-owned)
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
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9094 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        ryu exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        find and stop it, or the next 'up' will report on it:
          ss -ltnp   # tcp rows;  ss -lunp   # the udp one (:6343) -- see ports.sh
          cat /home/adam/Desktop/NDTwin-Kernel/.test_run/pids/*.pid   # what this stack started; check each against /proc/<pid>
  !!  stack.sh down exited 1, and the only thing behind that status is port(s)
  !!    still listening at [1/3], held by processes it did not start:
  !!      9091 9092 9093 9094 30051 30052 30053 30054 
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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution -- this checkout is being put back
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000

clean
  ok  the 8 port(s) [1/3] called 'still listening' were closed by [3/3]:
... [trimmed; 6287 chars total]
```

### 11. N10 ndt release

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
| PASS | injection: probes reached h1 | 【README 宣稱】 | `>=1 report row` | `72 rows` | receive.py:22 prints one 'Switch X - Port Y: Z Mbps' line per probe_data layer |
| PASS | switch ids seen | 【源碼推導，未執行】 | `[1, 2, 3, 4]` | `[1, 2, 3, 4]` | send.py's 9 ProbeFwd hops walk s1-s4-s2-s3-s1-s3-s2-s4-s1 over pod-topo |
| PASS | every reported port is non-zero | 【源碼推導，未執行】 | `no 0 port` | `[1, 2, 3, 4]` | solution:240 hdr.probe_data[0].port = standard_metadata.egress_port |
| PASS | G1  link usage follows the iperf path | 【源碼推導，未執行】 | `primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger` | `PASS` | TICKET-P3 §2.7's program-independent cell, through live-p1/_common.sh's link_usage_round -- the same function live-p1/05 runs. The floor and every off-path edge's raw integral are in that transcript. |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-19T145819Z_link_monitor_solution_ndtwin/driver-h1-receive.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-19T145819Z_link_monitor_solution_ndtwin/link_usage`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- link_monitor / solution
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/link_monitor

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/link_monitor/build/link_monitor.p4.p4info.txtpb -o /home/adam/tutorials/exercises/link_monitor/build/link_monitor.json /home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
-> /home/adam/tutorials/exercises/link_monitor/build/link_monitor.json  56155 B  sha256[:16]=b4a2d84b5e5c547b  warnings=0

== plan ================================================================
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
program  : /home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4 -> build/link_monitor.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : h1 receive.py + h1 send.py probes; assert swid and port fields
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/link_monitor --topology pod-topo/topology.json --p4 link_monitor.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  NDT_OWNER=p3-live-06 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=p3-live-06 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/link_monitor --topology pod-topo/topology.json --p4 solution/link_monitor.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
package 'link_monitor' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  control plane : ndtwin
  pipelines     : s1=build/link_monitor.json, s2=build/link_monitor.json, s3=build/link_monitor.json, s4=build/link_monitor.json
  model         : 4 switches, 4 hosts, 16 edges (8 links, both directions stored)
  files         : 10
                  build/link_monitor.json
                  build/link_monitor.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  pod-topo/s1-runtime.json
                  pod-topo/s2-runtime.json
                  pod-topo/s3-runtime.json
                  pod-topo/s4-runtime.json
                  pod-topo/topology.json
                  solution/link_monitor.p4
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  PASS  format                            1
  INFO  name                              link_monitor
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     4 dpids: [1, 2, 3, 4]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  9 present
  PASS  topo_from_json.switches           4 entries
  PASS  topo_from_json.hosts              4 entries
  PASS  topo_from_json.switch_links       4 entries
  PASS  topo_from_json.host_links         4 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3, 4]
  PASS  links agree                       8 links in both
  PASS  hosts named h<last octet>         4 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3', 'h4']
  PASS  switches pipeline                 4 of 4 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s2 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s3 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s4 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              24 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  link_monitor.json sha256:6cf0c5e39ed18161  link_monitor.p4.p4info.txtpb sha256:7303ccb1dc2c61bf

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=p3-live-06 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise link_monitor/solution on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by p3-live-06 for 45m (drive_exercise link_monitor/solution on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=p3-live-06 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  PASS  format                            1
  INFO  name                              link_monitor
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     4 dpids: [1, 2, 3, 4]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  9 present
  PASS  topo_from_json.switches           4 entries
  PASS  topo_from_json.hosts              4 entries
  PASS  topo_from_json.switch_links       4 entries
  PASS  topo_from_json.host_links         4 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3, 4]
  PASS  links agree                       8 links in both
  PASS  hosts named h<last octet>         4 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3', 'h4']
  PASS  switches pipeline                 4 of 4 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s2 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s3 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  INFO  s4 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              24 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  link_monitor.json sha256:6cf0c5e39ed18161  link_monitor.p4.p4info.txtpb sha256:7303ccb1dc2c61bf

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/link_monitor-solution/ndtwin/topology.json
  
... [trimmed; 5222 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s2  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s3  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s4  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=p3-live-06 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 23:43:19)
  note           in use: ndt up p4 4 at 2026-09-19 22:58:21 by p3-live-06
  prev claim     p3-live-06 (until 23:42:39), superseded 2026-09-19 22:58:18  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-19 22:58:17; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           f3b6d09c  +61 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 22:58:19)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/link_monitor-solution/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution (mode ndtwin)
                 link_monitor -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2916769, 4 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2916973 alive,kernel.pid=2916968 alive,p4_proxy.child.pid=2916869 alive,p4_proxy.pid=2916864 alive

network health
  switches       4 up, 4 enabled, 0 admin-disabled
  links          16 total, 8 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  4 switches (4 up, 4 enabled), 4 hosts, 16 edges
proxy
  4 destination paths reported; none expected -- the package's program on dpid 1,2,3,4, proxy skipped lldp_discovery

up target
  asked for      p4, 4 hosts   (recorded 2026-09-19 22:58:21 by p3-live-06)
  topology     
... [trimmed; 3535 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3, h4=10.0.4.4
$ h1: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/link_monitor/receive.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-19T145819Z_link_monitor_solution_ndtwin/driver-h1-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/link_monitor/send.py   (one probe per second, for 8s)
-- h1 receive.py output (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-19T145819Z_link_monitor_solution_ndtwin/driver-h1-receive.log) --
sniffing on eth0

Switch 1 - Port 1: 0.00019533743233372488 Mbps
Switch 4 - Port 2: 8.04914053960365e-05 Mbps
Switch 2 - Port 3: 7.084487273986574e-05 Mbps
Switch 3 - Port 2: 6.118684362098642e-05 Mbps
Switch 1 - Port 3: 5.152861169775973e-05 Mbps
Switch 3 - Port 1: 4.1868955001877396e-05 Mbps
Switch 2 - Port 4: 3.220871894047809e-05 Mbps
Switch 4 - Port 1: 2.2544508798430687e-05 Mbps
Switch 1 - Port 4: 1.2884717879035853e-05 Mbps

Switch 1 - Port 1: 0.0013175669714193842 Mbps
Switch 4 - Port 2: 0.0011762134356900402 Mbps
Switch 2 - Port 3: 0.0010349744931712264 Mbps
Switch 3 - Port 2: 0.0008940037054100948 Mbps
Switch 1 - Port 3: 0.0007528016867462794 Mbps
Switch 3 - Port 1: 0.0006116909431509729 Mbps
Switch 2 - Port 4: 0.0004704826073361961 Mbps
Switch 4 - Port 1: 0.00032932620446648667 Mbps
Switch 1 - Port 4: 0.00018817478301095335 Mbps

Switch 1 - Port 1: 0.0013162469334090697 Mbps
Switch 4 - Port 2: 0.0011752020613044155 Mbps
Switch 2 - Port 3: 0.0010342081990380688 Mbps
Switch 3 - Port 2: 0.0008929192094140315 Mbps
Switch 1 - Port 3: 0.0007519275486476564 Mbps
Switch 3 - Port 1: 0.0006109465167236818 Mbps
Switch 2 - Port 4: 0.000470088650884746 Mbps
Switch 4 - Port 1: 0.00032902467685076383 Mbps
Switch 1 - Port 4: 0.00018801815158571767 Mbps

Switch 1 - Port 1: 0.0013100372834271511 Mbps
Switch 4 - Port 2: 0.0011699680891203693 Mbps
Switch 2 - Port 3: 0.0010296492172325838 Mbps
Switch 3 - Port 2: 0.000889139338468633 Mbps
Switch 1 - Port 3: 0.0007488138904976687 Mbps
Switch 3 - Port 1: 0.0006084842598578839 Mbps
Switch 2 - Port 4: 0.000467981760410888 Mbps
Switch 4 - Port 1: 0.00032762268787113507 Mbps
Switch 1 - Port 4: 0.00018721497251742708 Mbps

Switch 1 - Port 1: 0.0013279713853784818 Mbps
Switch 4 - Port 2: 0.0011855387977451053 Mbps
Switch 2 - Port 3: 0.0010431257420911114 Mbps
Switch 3 - Port 2: 0.0009009792221546048 Mbps
Switch 1 - Port 3: 0.0007587193449722988 Mbps
Switch 3 - Port 1: 0.0006162889921304636 Mbps
Switch 2 - Port 4: 0.00047401134072132673 Mbps
Switch 4 - Port 1: 0.00033175420962521646 Mbps
Switch 1 - Port 4: 0.00018954594860343138 Mbps

Switch 1 - Port 1: 0.0013170789071380972 Mbps
Switch 4 - Port 2: 0.001175929891059895 Mbps
Switch 2 - Port 3: 0.0010349369629304398 Mbps
Switch 3 - Port 2: 0.0008935981336340735 Mbps
Switch 1 - Port 3: 0.0007525051661243338 Mbps
Switch 3 - Port 1: 0.0006115320838739773 Mbps
Switch 2 - Port 4: 0.0004705047437660572 Mbps
Switch 4 - Port 1: 0.00032938173284200557 Mbps
Switch 1 - Port 4: 0.00018823750867657266 Mbps

Switch 1 - Port 1: 0.0013159518032652053 Mbps
Switch 4 - Port 2: 0.0011749673212213786 Mbps
Switch 2 - Port 3: 0.001033984404068572 Mbps
Switch 3 - Port 2: 0.000893090592877015 Mbps
Switch 1 - Port 3: 0.0007520549313456104 Mbps
Switch 3 - Port 1: 0.0006110506153593056 Mbps
Switch 2 - Port 4: 0.0004700145410748645 Mbps
Switch 4 - Port 1: 0.00032903466517295374 Mbps
Switch 1 - Port 4: 0.0001880260690310292 Mbps

Switch 1 - Port 1: 0.0013174791448148765 Mbps
Switch 4 - Port 2: 0.0011760774094150878 Mbps
Switch 2 - Port 3: 0.0010345830953432983 Mbps
Switch 3 - Port 2: 0.0008934641918753539 Mbps
Switch 1 - Port 3: 0.0007521646770539825 Mbps
Switch 3 - Port 1: 0.00061113499717448 Mbps
Switch 2 - Port 4: 0.00047005596603845646 Mbps
Switch 4 - Port 1: 0.00032906141108584387 Mbps
Switch 1 - Port 4: 0.00018802330705577046 Mbps

   PASS injection: probes reached h1                   want=>=1 report row         got=72 rows
   PASS switch ids seen                                want=[1, 2, 3, 4]           got=[1, 2, 3, 4]
   PASS every reported port is non-zero                want=no 0 port              got=[1, 2, 3, 4]

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-19T145819Z_link_monitor_solution_ndtwin/driver-h1-receive.log 3347 B

== G1  link usage follows the iperf path (program-independent) =========
   link_monitor/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   link_monitor/solution: at 8s that is only 5.21 expected samples per primary link
   link_monitor/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   link_monitor/solution: h1 -> h4 (10.0.4.4), iperf -u -b 2M -t 16 -l 1200
   link_monitor/solution: primary=s1-eth4 s2-eth2 s4-eth1   minor=
   link_monitor/solution: on-path  s1-eth4  15891937.250 bit  (switch)  [primary, 4345828 B]
   link_monitor/solution: on-path  s2-eth2  41954560.500 bit  (host)  [primary, 4346031 B]
   link_monitor/solution: on-path  s4-eth1  38777040.750 bit  (switch)  [primary, 4345828 B]
   link_monitor/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   link_monitor/solution: off-path s1-eth1  0.000 bit  (host)
   link_monitor/solution: off-path s1-eth2  0.000 bit  (host)
   link_monitor/solution: off-path s1-eth3  0.000 bit  (switch)
   link_monitor/solution: off-path s2-eth1  0.000 bit  (host)
   link_monitor/solution: off-path s2-eth3  0.000 bit  (switch)
   link_monitor/solution: off-path s2-eth4  0.000 bit  (switch)
   link_monitor/solution: off-path s3-eth1  0.000 bit  (switch)
   link_monitor/solution: off-path s3-eth2  0.000 bit  (switch)
   link_monitor/solution: off-path s4-eth2  0.000 bit  (switch)
   link_monitor/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE link_monitor/solution expect=follows primary=3 minor=0 rc=0

== teardown: ndt down, the two knobs, then ndt release =================
$ NDT_OWNER=p3-live-06 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
  this teardown is about:
        4 bmv2 switch(es)
        8 host/switch process(es)
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
        -> an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
        :30054 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9091 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them i
... [trimmed; 6287 chars total]
   ndt down rc=0
   host_count_override: unchanged (2 bytes)
   telemetry_override: unchanged (absent)
$ NDT_OWNER=p3-live-06 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: probes reached h1                   want=>=1 report row         got=72 rows   【README 宣稱】
   PASS switch ids seen                                want=[1, 2, 3, 4]           got=[1, 2, 3, 4]   【源碼推導，未執行】
   PASS every reported port is non-zero                want=no 0 port              got=[1, 2, 3, 4]   【源碼推導，未執行】
   PASS G1  link usage follows the iperf path          want=primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger got=PASS   【源碼推導，未執行】

>>> PASS (4/4)
```

### stderr（mininet 的 logger 走這裡）

```

```
