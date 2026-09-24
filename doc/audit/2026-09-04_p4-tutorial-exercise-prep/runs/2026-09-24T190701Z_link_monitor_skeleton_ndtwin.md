# 執行報告 — `link_monitor` / skeleton

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-24T190701Z |
| exercise | `link_monitor` |
| which | `skeleton` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton` |
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
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/link_monitor/build/link_monitor.p4.p4info.txtpb -o /home/adam/tutorials/exercises/link_monitor/build/link_monitor.json /home/adam/tutorials/exercises/link_monitor/link_monitor.p4
rc=0  warnings=3
/home/adam/tutorials/exercises/link_monitor/link_monitor.p4(202): [--Wwarn=unused] warning: 'last_time_reg' is unused
    register<time_t>(8) last_time_reg;
                        ^^^^^^^^^^^^^
/home/adam/tutorials/exercises/link_monitor/link_monitor.p4(219): [--Wwarn=unused] warning: 'last_time' is unused
        time_t last_time;
               ^^^^^^^^^
/home/adam/tutorials/exercises/link_monitor/link_monitor.p4(220): [--Wwarn=unused] warning: 'cur_time' is unused
        time_t cur_time = standard_metadata.egress_global_timestamp;
               ^^^^^^^^
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/link_monitor/build/link_monitor.json` | 48079 | `4ae9020e75a9d24c` |
| `/home/adam/tutorials/exercises/link_monitor/build/link_monitor.p4.p4info.txtpb` | 1732 | `7303ccb1dc2c61bf` |

來源 `.p4`：`/home/adam/tutorials/exercises/link_monitor/link_monitor.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

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
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
s1  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
s2  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
s3  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
s4  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/link_monitor --topology pod-topo/topology.json --p4 link_monitor.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
```

```
package 'link_monitor' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
  control plane : ndtwin
  pipelines     : s1=build/link_monitor.json, s2=build/link_monitor.json, s3=build/link_monitor.json, s4=build/link_monitor.json
  model         : 4 switches, 4 hosts, 16 edges (8 links, both directions stored)
  files         : 10
                  build/link_monitor.json
                  build/link_monitor.p4.p4info.txtpb
                  link_monitor.p4
                  ndtwin/topology.json
                  package.json
                  pod-topo/s1-runtime.json
                  pod-topo/s2-runtime.json
                  pod-topo/s3-runtime.json
                  pod-topo/s4-runtime.json
                  pod-topo/topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
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
  INFO  s1 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s2 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s3 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s4 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              24 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  link_monitor.json sha256:8fd92e95118faad6  link_monitor.p4.p4info.txtpb sha256:7303ccb1dc2c61bf

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
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
  INFO  s1 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s2 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s3 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s4 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              24 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  link_monitor.json sha256:8fd92e95118faad6  link_monitor.p4.p4info.txtpb sha256:7303ccb1dc2c61bf

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/link_monitor-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton (mode ndtwin, 4 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 4 switches and the manifest
  ok  4 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 2496844) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 2496935) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
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
  "boot_at": 1790276828.3875864,
  "boot_id": "ebb65022d5054421a9f0566533ce8b58",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton",
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
        "pid": 2496761,
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
      "entries_recorded": 6,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30051",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1790276829.516661,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton/build/link_monitor.p4.p4info.txtpb",
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
      "probe_age_s": 0.01,
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
      "table_generation": "0b6958477dc3416489312fd6f2edb732",
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
      "entries_recorded": 6,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30052",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1790276829.51874,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton/build/link_monitor.p4.p4info.txtpb",
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
      "probe_age_s": 0.009,
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
      "table_generation": "dbe1b34f4d214924a5a913f6a6336c88",
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
      "entries_recorded": 6,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30053",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_insta
... [trimmed; 9123 chars total]
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 03:52:01)
  note           in use: ndt up p4 4 at 2026-09-25 03:07:02 by orch-0924
  prev claim     orch-0924 (until 03:51:01), superseded 2026-09-25 03:07:00  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 03:07:00; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           0c96c1d0  +79 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 03:07:01)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/link_monitor-skeleton/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton (mode ndtwin)
                 link_monitor -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2496761, 4 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2496940 alive,kernel.pid=2496935 alive,p4_proxy.child.pid=2496848 alive,p4_proxy.pid=2496844 alive

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
  asked for      p4, 4 hosts   (recorded 2026-09-25 03:07:02 by orch-0924)
  topology       .test_run/packages/link_monitor-skeleton/ndtwin/topology.json   (declares 4 hosts / 16 edges)
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

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
```

### 9. N8  G1 link usage follows the iperf path -- NOT RUN

```
$ live-p1/_common.sh link_usage_round (not called)
```

```
NOT RUN: the skeleton arm is a fabric the exercise says should not forward; there is no path for a program-independent cell to follow
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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton -- this checkout is being put back
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
| PASS | switch ids seen | 【源碼推導，未執行】 | `[1, 2, 3, 4]` | `[1, 2, 3, 4]` | swid.apply() is in the skeleton too (link_monitor.p4:235); sX-runtime.json sets the DEFAULT action, so the ids are filled in on both arms |
| PASS | every reported port is 0 | 【README 宣稱】＋【源碼推導，未執行】 | `[0]` | `[0]` | README step 1.4; link_monitor.p4:240-243 leave .port unwritten |
| PASS | every reported utilization is 0 | 【README 宣稱】＋【源碼推導，未執行】 | `['0']` | `['0']` | cur_time == last_time == 0 -> receive.py:21 yields the integer 0 |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190701Z_link_monitor_skeleton_ndtwin/driver-h1-receive.log`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- link_monitor / skeleton
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
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/link_monitor/build/link_monitor.p4.p4info.txtpb -o /home/adam/tutorials/exercises/link_monitor/build/link_monitor.json /home/adam/tutorials/exercises/link_monitor/link_monitor.p4
/home/adam/tutorials/exercises/link_monitor/link_monitor.p4(202): [--Wwarn=unused] warning: 'last_time_reg' is unused
    register<time_t>(8) last_time_reg;
                        ^^^^^^^^^^^^^
/home/adam/tutorials/exercises/link_monitor/link_monitor.p4(219): [--Wwarn=unused] warning: 'last_time' is unused
        time_t last_time;
               ^^^^^^^^^
/home/adam/tutorials/exercises/link_monitor/link_monitor.p4(220): [--Wwarn=unused] warning: 'cur_time' is unused
        time_t cur_time = standard_metadata.egress_global_timestamp;
               ^^^^^^^^
-> /home/adam/tutorials/exercises/link_monitor/build/link_monitor.json  48079 B  sha256[:16]=4ae9020e75a9d24c  warnings=3

== plan ================================================================
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
program  : /home/adam/tutorials/exercises/link_monitor/link_monitor.p4 -> build/link_monitor.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : h1 receive.py + h1 send.py probes; assert swid and port fields
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/link_monitor --topology pod-topo/topology.json --p4 link_monitor.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
  NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/link_monitor --topology pod-topo/topology.json --p4 link_monitor.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
package 'link_monitor' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
  control plane : ndtwin
  pipelines     : s1=build/link_monitor.json, s2=build/link_monitor.json, s3=build/link_monitor.json, s4=build/link_monitor.json
  model         : 4 switches, 4 hosts, 16 edges (8 links, both directions stored)
  files         : 10
                  build/link_monitor.json
                  build/link_monitor.p4.p4info.txtpb
                  link_monitor.p4
                  ndtwin/topology.json
                  package.json
                  pod-topo/s1-runtime.json
                  pod-topo/s2-runtime.json
                  pod-topo/s3-runtime.json
                  pod-topo/s4-runtime.json
                  pod-topo/topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
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
  INFO  s1 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s2 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s3 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s4 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              24 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  link_monitor.json sha256:8fd92e95118faad6  link_monitor.p4.p4info.txtpb sha256:7303ccb1dc2c61bf

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise link_monitor/skeleton on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by orch-0924 for 45m (drive_exercise link_monitor/skeleton on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
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
  INFO  s1 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s2 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s3 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  INFO  s4 pipeline                       build/link_monitor.json  p4info sha256:7303ccb1dc2c61bf  program=/home/adam/tutorials/exercises/link_monitor/link_monitor.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              24 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets t
... [trimmed; 5773 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s2  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s3  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s4  ndtwin=False p4info_sha256=7303ccb1dc2c61bf  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 03:52:01)
  note           in use: ndt up p4 4 at 2026-09-25 03:07:02 by orch-0924
  prev claim     orch-0924 (until 03:51:01), superseded 2026-09-25 03:07:00  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 03:07:00; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           0c96c1d0  +79 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 03:07:01)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/link_monitor-skeleton/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/link_monitor-skeleton (mode ndtwin)
                 link_monitor -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2496761, 4 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2496940 alive,kernel.pid=2496935 alive,p4_proxy.child.pid=2496848 alive,p4_proxy.pid=2496844 alive

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
  asked for      p4, 4 hosts   (recorded 2026-09-25 03:07:02 by orch-0924)
  topology       
... [trimmed; 3533 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3, h4=10.0.4.4
$ h1: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/link_monitor/receive.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190701Z_link_monitor_skeleton_ndtwin/driver-h1-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/link_monitor/send.py   (one probe per second, for 8s)
-- h1 receive.py output (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190701Z_link_monitor_skeleton_ndtwin/driver-h1-receive.log) --
sniffing on eth0

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

Switch 1 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps
Switch 3 - Port 0: 0 Mbps
Switch 2 - Port 0: 0 Mbps
Switch 4 - Port 0: 0 Mbps
Switch 1 - Port 0: 0 Mbps

   PASS injection: probes reached h1                   want=>=1 report row         got=72 rows
   PASS switch ids seen                                want=[1, 2, 3, 4]           got=[1, 2, 3, 4]
   PASS every reported port is 0                       want=[0]                    got=[0]
   PASS every reported utilization is 0                want=['0']                  got=['0']

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190701Z_link_monitor_skeleton_ndtwin/driver-h1-receive.log 1897 B

== G1  link usage follows the iperf path (program-independent) =========
   NOT RUN: the skeleton arm is a fabric the exercise says should not forward; there is no path for a program-independent cell to follow
   (a cell with no flow to follow is recorded as not run, never as a pass)

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
... [trimmed; 6287 chars total]
   ndt down rc=0
   host_count_override: unchanged (2 bytes)
   telemetry_override: unchanged (absent)
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: probes reached h1                   want=>=1 report row         got=72 rows   【README 宣稱】
   PASS switch ids seen                                want=[1, 2, 3, 4]           got=[1, 2, 3, 4]   【源碼推導，未執行】
   PASS every reported port is 0                       want=[0]                    got=[0]   【README 宣稱】＋【源碼推導，未執行】
   PASS every reported utilization is 0                want=['0']                  got=['0']   【README 宣稱】＋【源碼推導，未執行】

>>> PASS (4/4)
```

### stderr（mininet 的 logger 走這裡）

```

```
