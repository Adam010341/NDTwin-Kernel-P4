# 執行報告 — `basic` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-24T160820Z |
| exercise | `basic` |
| which | `solution` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution` |
| cwd | `/home/adam/tutorials/exercises/basic` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 1000 |
| 判定 | **PASS (6/6)** (exit 0) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `the bmv2 `ndt status` names` | `3ff54b5c1901c9d3` | 1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc) |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/basic/build/basic.p4.p4info.txtpb -o /home/adam/tutorials/exercises/basic/build/basic.json /home/adam/tutorials/exercises/basic/solution/basic.p4
rc=0  warnings=0

```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/basic/build/basic.json` | 14000 | `f967b39849a220b0` |
| `/home/adam/tutorials/exercises/basic/build/basic.p4.p4info.txtpb` | 943 | `9213871cee36bd93` |

來源 `.p4`：`/home/adam/tutorials/exercises/basic/solution/basic.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

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
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
s1  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
s2  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
s3  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
s4  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/basic --topology pod-topo/topology.json --p4 solution/basic.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
```

```
package 'basic' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
  control plane : ndtwin
  pipelines     : s1=build/basic.json, s2=build/basic.json, s3=build/basic.json, s4=build/basic.json
  model         : 4 switches, 4 hosts, 16 edges (8 links, both directions stored)
  files         : 10
                  build/basic.json
                  build/basic.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  pod-topo/s1-runtime.json
                  pod-topo/s2-runtime.json
                  pod-topo/s3-runtime.json
                  pod-topo/s4-runtime.json
                  pod-topo/topology.json
                  solution/basic.p4
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
  PASS  format                            1
  INFO  name                              basic
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
  INFO  s1 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              20 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:10760e38e7f044f6  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
  PASS  format                            1
  INFO  name                              basic
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
  INFO  s1 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              20 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:10760e38e7f044f6  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/basic-solution/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution (mode ndtwin, 4 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 4 switches and the manifest
  ok  4 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 2245334) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 2245426) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- the package's own program runs on dpid
  !!    1,2,3,4; the proxy says it sent no LLDP and installed no routes on this
  !!    fabric (control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery)
  ok  table entries: 5/5 applied on 4 switch(es), 0 failed
  ok  kernel: 4 switches, 4 up, 16 edges, 4 hosts
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces all agree)
  ok  telemetry: auto -- 0 cooperative, 4 link, 0 none; the proxy agrees switch by switch
  ok  data plane: h1 -> 10.0.2.2 forwards

up. ready
  proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo
  !!  package pipeline: NDTwin discovered no links and installed no routes on this
  !!    fabric; forwarding is whatever the package's 20 entries on
  !!    4 switch(es) make of it. ndt status quotes no sample rate for it.
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1790266107.490792,
  "boot_id": "091f3472dd0e4654b0e8725b6c1a0953",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution",
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
        "pid": 2245213,
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
  "declared_links": {
    "directions": 8,
    "error": null
  },
  "external_link_reports": {
    "last": null,
    "received": 0,
    "recorded_only": 0,
    "routed_through_watchdog": 0
  },
  "links": {
    "1:3->3:1": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "1:4->4:2": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "2:3->4:1": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "2:4->3:2": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "3:1->1:3": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "3:2->2:4": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "4:1->2:3": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "4:2->1:4": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    }
  },
  "probe_interval_s": 2.0,
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
      "entries_recorded": 5,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30051",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1790266108.6051831,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution/build/basic.p4.p4info.txtpb",
        "p4info_sha256": "9213871cee36bd93",
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
      "probe_age_s": 0.03,
      "probe_detail": "answered GetForwardingPipelineConfig",
      "probe_ok": true,
      "rules_timed": 5,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": true,
      "table_entries": {
        "api_writes": 0,
        "applied": 5,
        "failed": 0,
        "journaled": false,
        "recorded": 5
      },
      "table_generation": "716aed94196b4612886fc655a58d31c0",
      "telemetry": {
        "clone_session": false,
        "packet_in_ids": null,
        "reason": "this switch runs the app package's own pipeline, which does not clone to the CPU port; its samples come from 'link'",
        "sflow_registered": false,
        "source": "link"
      }
    },
    "2": {
      "capabilities": {
        "binding_source": null,
        "five_tuple": false,
        "ipv4_route": "unbound",
        "link_discovery": "declared",
        "reroute": false
      },
      "entries_recorded": 5,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30052",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1790266108.6071427,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution/build/basic.p4.p4info.txtpb",
        "p4info_sha256": "9213871cee36bd93",
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
      "probe_age_s": 0.029,
      "probe_detail": "answered GetForwardingPipelineConfig",
      "probe_ok": true,
      "rules_timed": 5,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": true,
      "table_entries": {
        "api_writes": 0,
        "applied": 5,
        "failed": 0,
        "journaled": false,
        "recorded": 5
      },
      "table_generation": "196c98ed34a44af69ac3a2828e62acfb",
      "telemetry": {
        "clone_session": false,
        "packet_in_ids": null,
        "reason": "this switch runs the app package's own pipeline, which does not clone to the CPU port; its samples come from 'link'",
        "sflow_registered": false,
        "source": "link"
      }
    },
    "3": {
      "capabilities": {
        "binding_source": null,
        "five_tuple": false,
        "ipv4_route": "unbound",
        "link_discovery": "declared",
        "reroute": false
      },
      "entries_recorded": 5,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30053",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1790266108.6087897,
   
... [trimmed; 9062 chars total]
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 00:53:20)
  note           in use: ndt up p4 4 at 2026-09-25 00:08:21 by orch-0924
  prev claim     orch-0924 (until 00:51:38), superseded 2026-09-25 00:08:20  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 00:08:20; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           67b64869  +64 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 00:08:20)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/basic-solution/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution (mode ndtwin)
                 basic -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2245213, 4 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2245432 alive,kernel.pid=2245426 alive,p4_proxy.child.pid=2245339 alive,p4_proxy.pid=2245334 alive

network health
  switches       4 up, 4 enabled, 0 admin-disabled
  links          16 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  4 switches (4 up, 4 enabled), 4 hosts, 16 edges
proxy
  12 destination paths reported; none expected -- the package's program on dpid 1,2,3,4, proxy skipped lldp_discovery

up target
  asked for      p4, 4 hosts   (recorded 2026-09-25 00:08:21 by orch-0924)
  topology       .test_run/packages/basic-solution/ndtwin/topology.json   (declares 4 hosts / 16 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   4                      == 4   ok
  graph hosts    4                      == 4   ok
  graph edges    16                     == 16   ok
  topology file  sha256 d9dc6f1e7729    == recorded   ok
  device names   no overlay file at .test_run/nickname_overlay/topology.names.json
                 that is where this checkout's kernel writes them; not a claim that none are set
```

### 6. pingall -- every ordered pair, ping -c 5 -W 2

```
$ ping -c 5 -W 2 <each ordered pair>
```

```
0% (12/12 pairs at 0%, 0 lossy)
```

### 7. B2  h1 ping -c3 h2

```
$ ping -c 3 -W 1 10.0.2.2
```

```
PING 10.0.2.2 (10.0.2.2) 56(84) bytes of data.
64 bytes from 10.0.2.2: icmp_seq=1 ttl=63 time=1.15 ms
64 bytes from 10.0.2.2: icmp_seq=2 ttl=63 time=1.21 ms
64 bytes from 10.0.2.2: icmp_seq=3 ttl=63 time=1.13 ms

--- 10.0.2.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 1.130/1.163/1.208/0.032 ms
```

### 8. B3  h2 starts the sniffer

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic/receive.py
```

```
(background; output below)
```

### 9. B4  h1 send.py -> h2

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic/send.py 10.0.2.2 P4 driver probe
```

```
sending on interface eth0 to 10.0.2.2
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 55
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = tcp
     chksum    = 0x63be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ TCP ]### 
        sport     = 61914
        dport     = 1234
        seq       = 0
        ack       = 0
        dataofs   = 5
        reserved  = 0
        flags     = S
        window    = 8192
        chksum    = 0x71c7
        urgptr    = 0
        options   = []
###[ Raw ]### 
           load      = 'P4 driver probe'
```

### 10. B5  h2 sniffer output

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic/receive.py
```

```
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:22
  src       = ff:ff:ff:ff:ff:ff
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 55
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 63
     proto     = tcp
     chksum    = 0x64be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ TCP ]### 
        sport     = 61914
        dport     = 1234
        seq       = 0
        ack       = 0
        dataofs   = 5
        reserved  = 0
        flags     = S
        window    = 8192
        chksum    = 0x71c7
        urgptr    = 0
        options   = []
###[ Raw ]### 
           load      = 'P4 driver probe'
```

### 11. N8  G1 link usage follows the iperf path

```
$ live-p1/_common.sh link_usage_round /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution (to the model's last host)
```

```
   basic/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   basic/solution: at 8s that is only 5.21 expected samples per primary link
   basic/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   basic/solution: h1 -> h4 (10.0.4.4), iperf -u -b 2M -t 16 -l 1200
   basic/solution: primary=s1-eth4 s2-eth2 s4-eth1   minor=
   basic/solution: on-path  s1-eth4  15894361.000 bit  (switch)  [primary, 4345758 B]
   basic/solution: on-path  s2-eth2  29245281.750 bit  (host)  [primary, 4345828 B]
   basic/solution: on-path  s4-eth1  32423314.000 bit  (switch)  [primary, 4345758 B]
   basic/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   basic/solution: off-path s1-eth1  0.000 bit  (host)
   basic/solution: off-path s1-eth2  0.000 bit  (host)
   basic/solution: off-path s1-eth3  0.000 bit  (switch)
   basic/solution: off-path s2-eth1  0.000 bit  (host)
   basic/solution: off-path s2-eth3  0.000 bit  (switch)
   basic/solution: off-path s2-eth4  0.000 bit  (switch)
   basic/solution: off-path s3-eth1  0.000 bit  (switch)
   basic/solution: off-path s3-eth2  0.000 bit  (switch)
   basic/solution: off-path s4-eth2  0.000 bit  (switch)
   basic/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE basic/solution expect=follows primary=3 minor=0 rc=0
```

### 12. N9  ndt down

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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution -- this checkout is being put back
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000

clean
  ok  the 8 port(s) [1/3] called 'still listening' were closed by [3/3]: 9091 9
... [trimmed; 6280 chars total]
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
| PASS | injection: send.py emitted 1 TCP frame | 【源碼推導，未執行】 | `1` | `1` | basic/send.py:34 prints before sendp(); dport 1234 is what receive.py filters on |
| PASS | pingall loss (ping -c 5, every ordered pair) | 【README 宣稱】＋【源碼推導，未執行】 | `0.0%` | `0% (12/12 pairs at 0%, 0 lossy)` | solution/basic.p4 parses+forwards; pod-topo sX-runtime.json has /32 entries for all 4 hosts |
| PASS | h1 ping -c3 h2 received | 【源碼推導，未執行】 | `3` | `3` | - |
| PASS | h2 got the send.py packet | 【源碼推導，未執行】 | `>=1` | `1` | - |
| PASS | ttl at h2 (h1-s1-h2 is one hop) | 【源碼推導，未執行】 | `[63]` | `[63]` | solution ipv4_forward does ttl = ttl - 1 once; h1 and h2 share s1 (pod-topo links) |
| PASS | G1  link usage follows the iperf path | 【源碼推導，未執行】 | `primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger` | `PASS` | TICKET-P3 §2.7's program-independent cell, through live-p1/_common.sh's link_usage_round -- the same function live-p1/05 runs. The floor and every off-path edge's raw integral are in that transcript. |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T160820Z_basic_solution_ndtwin/driver-h2-receive.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T160820Z_basic_solution_ndtwin/link_usage`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- basic / solution
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/basic

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/basic/build/basic.p4.p4info.txtpb -o /home/adam/tutorials/exercises/basic/build/basic.json /home/adam/tutorials/exercises/basic/solution/basic.p4
-> /home/adam/tutorials/exercises/basic/build/basic.json  14000 B  sha256[:16]=f967b39849a220b0  warnings=0

== plan ================================================================
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
program  : /home/adam/tutorials/exercises/basic/solution/basic.p4 -> build/basic.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : net.pingAll; h1 ping -c3 h2; h1 send.py -> h2 receive.py; assert loss
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/basic --topology pod-topo/topology.json --p4 basic.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
  NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/basic --topology pod-topo/topology.json --p4 solution/basic.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
package 'basic' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
  control plane : ndtwin
  pipelines     : s1=build/basic.json, s2=build/basic.json, s3=build/basic.json, s4=build/basic.json
  model         : 4 switches, 4 hosts, 16 edges (8 links, both directions stored)
  files         : 10
                  build/basic.json
                  build/basic.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  pod-topo/s1-runtime.json
                  pod-topo/s2-runtime.json
                  pod-topo/s3-runtime.json
                  pod-topo/s4-runtime.json
                  pod-topo/topology.json
                  solution/basic.p4
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
  PASS  format                            1
  INFO  name                              basic
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
  INFO  s1 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              20 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:10760e38e7f044f6  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise basic/solution on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by orch-0924 for 45m (drive_exercise basic/solution on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
  PASS  format                            1
  INFO  name                              basic
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
  INFO  s1 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/basic/solution/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              20 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE 
... [trimmed; 5669 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
   s2  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
   s3  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
   s4  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 00:53:20)
  note           in use: ndt up p4 4 at 2026-09-25 00:08:21 by orch-0924
  prev claim     orch-0924 (until 00:51:38), superseded 2026-09-25 00:08:20  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 00:08:20; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           67b64869  +64 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 00:08:20)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/basic-solution/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic-solution (mode ndtwin)
                 basic -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2245213, 4 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2245432 alive,kernel.pid=2245426 alive,p4_proxy.child.pid=2245339 alive,p4_proxy.pid=2245334 alive

network health
  switches       4 up, 4 enabled, 0 admin-disabled
  links          16 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  4 switches (4 up, 4 enabled), 4 hosts, 16 edges
proxy
  12 destination paths reported; none expected -- the package's program on dpid 1,2,3,4, proxy skipped lldp_discovery

up target
  asked for      p4, 4 hosts   (recorded 2026-09-25 00:08:21 by orch-0924)
  topology       .test_run/packages/ba
... [trimmed; 3505 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3, h4=10.0.4.4
$ every ordered host pair: ping -c 5 -W 2, loss parsed from ping's summary
-> pingall 0% (12/12 pairs at 0%, 0 lossy)
$ h1: ping -c 3 -W 1 10.0.2.2
PING 10.0.2.2 (10.0.2.2) 56(84) bytes of data.
64 bytes from 10.0.2.2: icmp_seq=1 ttl=63 time=1.15 ms
64 bytes from 10.0.2.2: icmp_seq=2 ttl=63 time=1.21 ms
64 bytes from 10.0.2.2: icmp_seq=3 ttl=63 time=1.13 ms

--- 10.0.2.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 1.130/1.163/1.208/0.032 ms
$ h2: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic/receive.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T160820Z_basic_solution_ndtwin/driver-h2-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic/send.py 10.0.2.2 P4 driver probe
sending on interface eth0 to 10.0.2.2
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 55
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = tcp
     chksum    = 0x63be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ TCP ]### 
        sport     = 61914
        dport     = 1234
        seq       = 0
        ack       = 0
        dataofs   = 5
        reserved  = 0
        flags     = S
        window    = 8192
        chksum    = 0x71c7
        urgptr    = 0
        options   = []
###[ Raw ]### 
           load      = 'P4 driver probe'


-- h2 receive.py output (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T160820Z_basic_solution_ndtwin/driver-h2-receive.log) --
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:22
  src       = ff:ff:ff:ff:ff:ff
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 55
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 63
     proto     = tcp
     chksum    = 0x64be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ TCP ]### 
        sport     = 61914
        dport     = 1234
        seq       = 0
        ack       = 0
        dataofs   = 5
        reserved  = 0
        flags     = S
        window    = 8192
        chksum    = 0x71c7
        urgptr    = 0
        options   = []
###[ Raw ]### 
           load      = 'P4 driver probe'


   PASS injection: send.py emitted 1 TCP frame         want=1                      got=1
   PASS pingall loss (ping -c 5, every ordered pair)   want=0.0%                   got=0% (12/12 pairs at 0%, 0 lossy)
   PASS h1 ping -c3 h2 received                        want=3                      got=3
   PASS h2 got the send.py packet                      want=>=1                    got=1
   PASS ttl at h2 (h1-s1-h2 is one hop)                want=[63]                   got=[63]

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T160820Z_basic_solution_ndtwin/driver-h2-receive.log 747 B

== G1  link usage follows the iperf path (program-independent) =========
   basic/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   basic/solution: at 8s that is only 5.21 expected samples per primary link
   basic/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   basic/solution: h1 -> h4 (10.0.4.4), iperf -u -b 2M -t 16 -l 1200
   basic/solution: primary=s1-eth4 s2-eth2 s4-eth1   minor=
   basic/solution: on-path  s1-eth4  15894361.000 bit  (switch)  [primary, 4345758 B]
   basic/solution: on-path  s2-eth2  29245281.750 bit  (host)  [primary, 4345828 B]
   basic/solution: on-path  s4-eth1  32423314.000 bit  (switch)  [primary, 4345758 B]
   basic/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   basic/solution: off-path s1-eth1  0.000 bit  (host)
   basic/solution: off-path s1-eth2  0.000 bit  (host)
   basic/solution: off-path s1-eth3  0.000 bit  (switch)
   basic/solution: off-path s2-eth1  0.000 bit  (host)
   basic/solution: off-path s2-eth3  0.000 bit  (switch)
   basic/solution: off-path s2-eth4  0.000 bit  (switch)
   basic/solution: off-path s3-eth1  0.000 bit  (switch)
   basic/solution: off-path s3-eth2  0.000 bit  (switch)
   basic/solution: off-path s4-eth2  0.000 bit  (switch)
   basic/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE basic/solution expect=follows primary=3 minor=0 rc=0

== teardown: ndt down, the two knobs, then ndt release =================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
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
... [trimmed; 6280 chars total]
   ndt down rc=0
   host_count_override: unchanged (2 bytes)
   telemetry_override: unchanged (absent)
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: send.py emitted 1 TCP frame         want=1                      got=1   【源碼推導，未執行】
   PASS pingall loss (ping -c 5, every ordered pair)   want=0.0%                   got=0% (12/12 pairs at 0%, 0 lossy)   【README 宣稱】＋【源碼推導，未執行】
   PASS h1 ping -c3 h2 received                        want=3                      got=3   【源碼推導，未執行】
   PASS h2 got the send.py packet                      want=>=1                    got=1   【源碼推導，未執行】
   PASS ttl at h2 (h1-s1-h2 is one hop)                want=[63]                   got=[63]   【源碼推導，未執行】
   PASS G1  link usage follows the iperf path          want=primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger got=PASS   【源碼推導，未執行】

>>> PASS (6/6)
```

### stderr（mininet 的 logger 走這裡）

```

```
