# 執行報告 — `link_monitor` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-18T134040Z |
| exercise | `link_monitor` |
| which | `solution` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution` |
| cwd | `/home/adam/tutorials/exercises/link_monitor` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 1000 |
| 判定 | **PASS (3/3)** (exit 0) |

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
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 4 switches and the manifest
  ok  4 switches up after 4s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 2668975) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 .. up
        started kernel (pid 2669069) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- the package's own program runs on dpid
  !!    1,2,3,4; the proxy says it sent no LLDP and installed no routes on this
  !!    fabric (control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery)
  ok  table entries: 6/6 applied on 4 switch(es), 0 failed
  ok  kernel: 4 switches, 4 up, 16 edges, 4 hosts
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces all agree)
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
  "boot_at": 1789738847.9288805,
  "boot_id": "7ae5fe1541de4a6bbccd5f009445dbbd",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution",
    "skipped": [
      "install_initial_routes",
      "link_watchdog",
      "lldp_discovery"
    ]
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
      "oldest_rule_installed_at": 1789738849.1735044,
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
      "probe_age_s": 0.244,
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
      "table_generation": "c96f107516b348f08708ca491186a2a4"
    },
    "2": {
      "entries_recorded": 6,
      "grpc_addr": "localhost:30052",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789738849.1824005,
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
      "probe_age_s": 0.243,
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
      "table_generation": "4b54a9c662864a9f9cb05eee7efac52b"
    },
    "3": {
      "entries_recorded": 6,
      "grpc_addr": "localhost:30053",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789738849.19256,
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
      "probe_age_s": 0.242,
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
      "table_generation": "803f7a2cbd8b4276a021993307dc2bca"
    },
    "4": {
      "entries_recorded": 6,
      "grpc_addr": "localhost:30054",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789738849.2014132,
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
      "probe_age_s": 0.241,
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
      "table_generation": "674e6aa6606c43a18b5ab45298d5901c"
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
  claim          yours -- 45m left (until 22:25:41)
  note           in use: ndt up p4 4 at 2026-09-18 21:40:43 by 9-18-orchestrator
  prev claim     9-18-orchestrator (until 22:24:54), superseded 2026-09-18 21:40:37  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-18 21:40:37; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           fa83c170  +37 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 21:40:41)
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
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2669074 alive,kernel.pid=2669069 alive,p4_proxy.child.pid=2668980 alive,p4_proxy.pid=2668975 alive

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
  asked for      p4, 4 hosts   (recorded 2026-09-18 21:40:43 by 9-18-orchestrator)
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

Switch 1 - Port 1: 0.0002684040915770427 Mbps
Switch 4 - Port 2: 0.00011060999661809935 Mbps
Switch 2 - Port 3: 9.73425125356139e-05 Mbps
Switch 3 - Port 2: 8.406623202335346e-05 Mbps
Switch 1 - Port 3: 7.080179902946221e-05 Mbps
Switch 3 - Port 1: 5.7525645006294634e-05 Mbps
Switch 2 - Port 4: 4.425579999918864e-05 Mbps
Switch 4 - Port 1: 3.0980399641623164e-05 Mbps
Switch 1 - Port 4: 1.770401269746544e-05 Mbps

Switch 1 - Port 1: 0.0013212546020261204 Mbps
Switch 4 - Port 2: 0.0011797611966711072 Mbps
Switch 2 - Port 3: 0.0010379867774638915 Mbps
Switch 3 - Port 2: 0.0008964739673593042 Mbps
Switch 1 - Port 3: 0.0007547221728136888 Mbps
Switch 3 - Port 1: 0.0006131954953715532 Mbps
Switch 2 - Port 4: 0.0004716540810360668 Mbps
Switch 4 - Port 1: 0.0003301481244933553 Mbps
Switch 1 - Port 4: 0.0001886338293158585 Mbps

Switch 1 - Port 1: 0.001314136253636119 Mbps
Switch 4 - Port 2: 0.0011732028731738363 Mbps
Switch 2 - Port 3: 0.0010324306408989186 Mbps
Switch 3 - Port 2: 0.0008914729439916483 Mbps
Switch 1 - Port 3: 0.0007506634281273977 Mbps
Switch 3 - Port 1: 0.0006098472743051993 Mbps
Switch 2 - Port 4: 0.00046906377801556704 Mbps
Switch 4 - Port 1: 0.00032835619611073813 Mbps
Switch 1 - Port 4: 0.00018767484551036805 Mbps

Switch 1 - Port 1: 0.0013145539906103286 Mbps
Switch 4 - Port 2: 0.0011737204002386565 Mbps
Switch 2 - Port 3: 0.0010328729419566487 Mbps
Switch 3 - Port 2: 0.0008922334599287387 Mbps
Switch 1 - Port 3: 0.0007514382998708466 Mbps
Switch 3 - Port 1: 0.0006106087397290032 Mbps
Switch 2 - Port 4: 0.0004697302867409819 Mbps
Switch 4 - Port 1: 0.00032880444355719437 Mbps
Switch 1 - Port 4: 0.00018787078795161154 Mbps

Switch 1 - Port 1: 0.0013137431808029278 Mbps
Switch 4 - Port 2: 0.001173101945491818 Mbps
Switch 2 - Port 3: 0.0010322651279138762 Mbps
Switch 3 - Port 2: 0.0008914712011792444 Mbps
Switch 1 - Port 3: 0.000750679570275044 Mbps
Switch 3 - Port 1: 0.0006099492099984751 Mbps
Switch 2 - Port 4: 0.0004692297691096267 Mbps
Switch 4 - Port 1: 0.00032849969496456897 Mbps
Switch 1 - Port 4: 0.00018770438514593526 Mbps

Switch 1 - Port 1: 0.001321740567109312 Mbps
Switch 4 - Port 2: 0.0011801382728676376 Mbps
Switch 2 - Port 3: 0.0010385982857227158 Mbps
Switch 3 - Port 2: 0.0008968953848241761 Mbps
Switch 1 - Port 3: 0.0007552862662797135 Mbps
Switch 3 - Port 1: 0.0006136326759399938 Mbps
Switch 2 - Port 4: 0.00047193556506418326 Mbps
Switch 4 - Port 1: 0.0003303747098159636 Mbps
Switch 1 - Port 4: 0.0001887768244985124 Mbps

Switch 1 - Port 1: 0.001313077035806751 Mbps
Switch 4 - Port 2: 0.0011724119738434889 Mbps
Switch 2 - Port 3: 0.0010317295930530206 Mbps
Switch 3 - Port 2: 0.000891057476138321 Mbps
Switch 1 - Port 3: 0.0007503671229771598 Mbps
Switch 3 - Port 1: 0.0006096816269901366 Mbps
Switch 2 - Port 4: 0.00046920729382738253 Mbps
Switch 4 - Port 1: 0.0003284415740562437 Mbps
Switch 1 - Port 4: 0.00018768511911162377 Mbps

Switch 1 - Port 1: 0.0013151933206967785 Mbps
Switch 4 - Port 2: 0.0011739799092904857 Mbps
Switch 2 - Port 3: 0.001033078063917792 Mbps
Switch 3 - Port 2: 0.0008920702583580234 Mbps
Switch 1 - Port 3: 0.0007510892260749231 Mbps
Switch 3 - Port 1: 0.0006102737234129949 Mbps
Switch 2 - Port 4: 0.0004692531640372196 Mbps
Switch 4 - Port 1: 0.0003284605172862123 Mbps
Switch 1 - Port 4: 0.0001876610879847056 Mbps
```

### 9. N9  ndt down

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

### 10. N10 ndt release

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

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T134040Z_link_monitor_solution_ndtwin/driver-h1-receive.log`

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
  NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
  ... the scripted steps above, then `ndt down` and `ndt release`.

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
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  link_monitor.json sha256:6cf0c5e39ed18161  link_monitor.p4.p4info.txtpb sha256:7303ccb1dc2c61bf

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')

== claim the lab =======================================================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise link_monitor/solution on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by 9-18-orchestrator for 45m (drive_exercise link_monitor/solution on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
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
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  link_monitor.json sha256:6cf0c5e39ed18161  link_monitor.p4.p4info.txtpb sha256:7303ccb1dc2c61bf

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/link_monitor-solution/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution (mode ndtwin, 4 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  r
... [trimmed; 4801 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-solution
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s2  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s3  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s4  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 22:25:41)
  note           in use: ndt up p4 4 at 2026-09-18 21:40:43 by 9-18-orchestrator
  prev claim     9-18-orchestrator (until 22:24:54), superseded 2026-09-18 21:40:37  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-18 21:40:37; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           fa83c170  +37 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 21:40:41)
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
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2669074 alive,kernel.pid=2669069 alive,p4_proxy.child.pid=2668980 alive,p4_proxy.pid=2668975 alive

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
  asked for      p4, 4 hosts   (recorded 2026-09-18 21:40:43 by 9-18-orchestrator)
  topology       .test_run/packages/link_monitor-solution/ndtwin/topology.json   (declares 4 hosts / 16 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   4                      == 4   ok
  graph hosts    4                    
... [trimmed; 3300 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3, h4=10.0.4.4
$ h1: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/link_monitor/receive.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T134040Z_link_monitor_solution_ndtwin/driver-h1-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/link_monitor/send.py   (one probe per second, for 8s)
-- h1 receive.py output (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T134040Z_link_monitor_solution_ndtwin/driver-h1-receive.log) --
sniffing on eth0

Switch 1 - Port 1: 0.0002684040915770427 Mbps
Switch 4 - Port 2: 0.00011060999661809935 Mbps
Switch 2 - Port 3: 9.73425125356139e-05 Mbps
Switch 3 - Port 2: 8.406623202335346e-05 Mbps
Switch 1 - Port 3: 7.080179902946221e-05 Mbps
Switch 3 - Port 1: 5.7525645006294634e-05 Mbps
Switch 2 - Port 4: 4.425579999918864e-05 Mbps
Switch 4 - Port 1: 3.0980399641623164e-05 Mbps
Switch 1 - Port 4: 1.770401269746544e-05 Mbps

Switch 1 - Port 1: 0.0013212546020261204 Mbps
Switch 4 - Port 2: 0.0011797611966711072 Mbps
Switch 2 - Port 3: 0.0010379867774638915 Mbps
Switch 3 - Port 2: 0.0008964739673593042 Mbps
Switch 1 - Port 3: 0.0007547221728136888 Mbps
Switch 3 - Port 1: 0.0006131954953715532 Mbps
Switch 2 - Port 4: 0.0004716540810360668 Mbps
Switch 4 - Port 1: 0.0003301481244933553 Mbps
Switch 1 - Port 4: 0.0001886338293158585 Mbps

Switch 1 - Port 1: 0.001314136253636119 Mbps
Switch 4 - Port 2: 0.0011732028731738363 Mbps
Switch 2 - Port 3: 0.0010324306408989186 Mbps
Switch 3 - Port 2: 0.0008914729439916483 Mbps
Switch 1 - Port 3: 0.0007506634281273977 Mbps
Switch 3 - Port 1: 0.0006098472743051993 Mbps
Switch 2 - Port 4: 0.00046906377801556704 Mbps
Switch 4 - Port 1: 0.00032835619611073813 Mbps
Switch 1 - Port 4: 0.00018767484551036805 Mbps

Switch 1 - Port 1: 0.0013145539906103286 Mbps
Switch 4 - Port 2: 0.0011737204002386565 Mbps
Switch 2 - Port 3: 0.0010328729419566487 Mbps
Switch 3 - Port 2: 0.0008922334599287387 Mbps
Switch 1 - Port 3: 0.0007514382998708466 Mbps
Switch 3 - Port 1: 0.0006106087397290032 Mbps
Switch 2 - Port 4: 0.0004697302867409819 Mbps
Switch 4 - Port 1: 0.00032880444355719437 Mbps
Switch 1 - Port 4: 0.00018787078795161154 Mbps

Switch 1 - Port 1: 0.0013137431808029278 Mbps
Switch 4 - Port 2: 0.001173101945491818 Mbps
Switch 2 - Port 3: 0.0010322651279138762 Mbps
Switch 3 - Port 2: 0.0008914712011792444 Mbps
Switch 1 - Port 3: 0.000750679570275044 Mbps
Switch 3 - Port 1: 0.0006099492099984751 Mbps
Switch 2 - Port 4: 0.0004692297691096267 Mbps
Switch 4 - Port 1: 0.00032849969496456897 Mbps
Switch 1 - Port 4: 0.00018770438514593526 Mbps

Switch 1 - Port 1: 0.001321740567109312 Mbps
Switch 4 - Port 2: 0.0011801382728676376 Mbps
Switch 2 - Port 3: 0.0010385982857227158 Mbps
Switch 3 - Port 2: 0.0008968953848241761 Mbps
Switch 1 - Port 3: 0.0007552862662797135 Mbps
Switch 3 - Port 1: 0.0006136326759399938 Mbps
Switch 2 - Port 4: 0.00047193556506418326 Mbps
Switch 4 - Port 1: 0.0003303747098159636 Mbps
Switch 1 - Port 4: 0.0001887768244985124 Mbps

Switch 1 - Port 1: 0.001313077035806751 Mbps
Switch 4 - Port 2: 0.0011724119738434889 Mbps
Switch 2 - Port 3: 0.0010317295930530206 Mbps
Switch 3 - Port 2: 0.000891057476138321 Mbps
Switch 1 - Port 3: 0.0007503671229771598 Mbps
Switch 3 - Port 1: 0.0006096816269901366 Mbps
Switch 2 - Port 4: 0.00046920729382738253 Mbps
Switch 4 - Port 1: 0.0003284415740562437 Mbps
Switch 1 - Port 4: 0.00018768511911162377 Mbps

Switch 1 - Port 1: 0.0013151933206967785 Mbps
Switch 4 - Port 2: 0.0011739799092904857 Mbps
Switch 2 - Port 3: 0.001033078063917792 Mbps
Switch 3 - Port 2: 0.0008920702583580234 Mbps
Switch 1 - Port 3: 0.0007510892260749231 Mbps
Switch 3 - Port 1: 0.0006102737234129949 Mbps
Switch 2 - Port 4: 0.0004692531640372196 Mbps
Switch 4 - Port 1: 0.0003284605172862123 Mbps
Switch 1 - Port 4: 0.0001876610879847056 Mbps

   PASS injection: probes reached h1                   want=>=1 report row         got=72 rows
   PASS switch ids seen                                want=[1, 2, 3, 4]           got=[1, 2, 3, 4]
   PASS every reported port is non-zero                want=no 0 port              got=[1, 2, 3, 4]

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T134040Z_link_monitor_solution_ndtwin/driver-h1-receive.log 3342 B

== teardown: ndt down, the host knob, then ndt release =================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
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
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: probes reached h1                   want=>=1 report row         got=72 rows   【README 宣稱】
   PASS switch ids seen                                want=[1, 2, 3, 4]           got=[1, 2, 3, 4]   【源碼推導，未執行】
   PASS every reported port is non-zero                want=no 0 port              got=[1, 2, 3, 4]   【源碼推導，未執行】

>>> PASS (3/3)
```

### stderr（mininet 的 logger 走這裡）

```

```
