# 執行報告 — `basic_tunnel` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-24T190311Z |
| exercise | `basic_tunnel` |
| which | `solution` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution` |
| cwd | `/home/adam/tutorials/exercises/basic_tunnel` |
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
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/basic_tunnel/build/basic_tunnel.p4.p4info.txtpb -o /home/adam/tutorials/exercises/basic_tunnel/build/basic_tunnel.json /home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
rc=0  warnings=0

```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/basic_tunnel/build/basic_tunnel.json` | 19548 | `bcb4ff532f309154` |
| `/home/adam/tutorials/exercises/basic_tunnel/build/basic_tunnel.p4.p4info.txtpb` | 1470 | `e08bce0024fc7df2` |

來源 `.p4`：`/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
```

### 3b. `GET /p4/switch_state`（揭露，不是結果）

```
control_plane.mode    ndtwin
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
s1  ndtwin=False p4info_sha256=e08bce0024fc7df2  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
s2  ndtwin=False p4info_sha256=e08bce0024fc7df2  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
s3  ndtwin=False p4info_sha256=e08bce0024fc7df2  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/basic_tunnel --topology topology.json --p4 solution/basic_tunnel.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
```

```
package 'basic_tunnel' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
  control plane : ndtwin
  pipelines     : s1=build/basic_tunnel.json, s2=build/basic_tunnel.json, s3=build/basic_tunnel.json
  model         : 3 switches, 3 hosts, 12 edges (6 links, both directions stored)
  files         : 9
                  build/basic_tunnel.json
                  build/basic_tunnel.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  s1-runtime.json
                  s2-runtime.json
                  s3-runtime.json
                  solution/basic_tunnel.p4
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
  PASS  format                            1
  INFO  name                              basic_tunnel
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     3 dpids: [1, 2, 3]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  8 present
  PASS  topo_from_json.switches           3 entries
  PASS  topo_from_json.hosts              3 entries
  PASS  topo_from_json.switch_links       3 entries
  PASS  topo_from_json.host_links         3 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3]
  PASS  links agree                       6 links in both
  PASS  hosts named h<last octet>         3 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3']
  PASS  switches pipeline                 3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  INFO  s2 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  INFO  s3 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              18 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic_tunnel.json sha256:f10a88e35e2f6ba3  basic_tunnel.p4.p4info.txtpb sha256:e08bce0024fc7df2

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
  PASS  format                            1
  INFO  name                              basic_tunnel
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     3 dpids: [1, 2, 3]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  8 present
  PASS  topo_from_json.switches           3 entries
  PASS  topo_from_json.hosts              3 entries
  PASS  topo_from_json.switch_links       3 entries
  PASS  topo_from_json.host_links         3 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3]
  PASS  links agree                       6 links in both
  PASS  hosts named h<last octet>         3 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3']
  PASS  switches pipeline                 3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  INFO  s2 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  INFO  s3 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              18 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic_tunnel.json sha256:f10a88e35e2f6ba3  basic_tunnel.p4.p4info.txtpb sha256:e08bce0024fc7df2

PASS -- every check passed

ndt up p4
  hosts        3        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/basic_tunnel-solution/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution (mode ndtwin, 3 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 3 (persistent; affects every later run)
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 3 switches and the manifest
  ok  3 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 2482558) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 2482646) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- the package's own program runs on dpid
  !!    1,2,3; the proxy says it sent no LLDP and installed no routes on this
  !!    fabric (control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery)
  ok  table entries: 6/6 applied on 3 switch(es), 0 failed
  ok  kernel: 3 switches, 3 up, 12 edges, 3 hosts
  ok  model matches fabric: 3 hosts (kernel graph, topology file and 3 host namespaces all agree)
  ok  telemetry: auto -- 0 cooperative, 3 link, 0 none; the proxy agrees switch by switch
  ok  data plane: h1 -> 10.0.2.2 forwards

up. ready
  proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo
  !!  package pipeline: NDTwin discovered no links and installed no routes on this
  !!    fabric; forwarding is whatever the package's 18 entries on
  !!    3 switch(es) make of it. ndt status quotes no sample rate for it.
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1790276598.8544946,
  "boot_id": "69ddfde38d9b48ffaf2d2c48f77ae9f9",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution",
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
        "pid": 2482392,
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
  "declared_links": {
    "directions": 6,
    "error": null
  },
  "external_link_reports": {
    "last": null,
    "received": 0,
    "recorded_only": 0,
    "routed_through_watchdog": 0
  },
  "links": {
    "1:2->2:2": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "1:3->3:2": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "2:2->1:2": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "2:3->3:3": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "3:2->1:3": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "3:3->2:3": {
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
      "oldest_rule_installed_at": 1790276599.965617,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution/build/basic_tunnel.p4.p4info.txtpb",
        "p4info_sha256": "e08bce0024fc7df2",
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
      "probe_age_s": 0.061,
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
      "table_generation": "66f4b2f44d59433dacb343868fff4182",
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
      "oldest_rule_installed_at": 1790276599.9706318,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution/build/basic_tunnel.p4.p4info.txtpb",
        "p4info_sha256": "e08bce0024fc7df2",
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
      "probe_age_s": 0.06,
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
      "table_generation": "729d04e5135247f5adc07547a5b6bc08",
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
      "oldest_rule_installed_at": 1790276599.974095,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution/build/basic_tunnel.p4.p4info.txtpb",
        "p4info_sha256": "e08bce0024fc7df2",
        "skipped": [
          "clone_sess
... [trimmed; 7059 chars total]
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 03:48:12)
  note           in use: ndt up p4 3 at 2026-09-25 03:03:12 by orch-0924
  prev claim     orch-0924 (until 03:46:22), superseded 2026-09-25 03:03:10  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 03:03:10; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           0c96c1d0  +79 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  3, written by 'ndt up p4 3' at 03:03:12 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          3   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/basic_tunnel-solution/ndtwin/topology.json
  p4 host knob   3   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution (mode ndtwin)
                 basic_tunnel -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2482392, 3 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    6       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2482652 alive,kernel.pid=2482646 alive,p4_proxy.child.pid=2482564 alive,p4_proxy.pid=2482558 alive

network health
  switches       3 up, 3 enabled, 0 admin-disabled
  links          12 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  3 switches (3 up, 3 enabled), 3 hosts, 12 edges
proxy
  6 destination paths reported; none expected -- the package's program on dpid 1,2,3, proxy skipped lldp_discovery

up target
  asked for      p4, 3 hosts   (recorded 2026-09-25 03:03:12 by orch-0924)
  topology       .test_run/packages/basic_tunnel-solution/ndtwin/topology.json   (declares 3 hosts / 12 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   3                      == 3   ok
  graph hosts    3                      == 3   ok
  graph edges    12                     == 12   ok
  topology file  sha256 f635d32a0dd3    == recorded   ok
  device names   no overlay file at .test_run/nickname_overlay/topology.names.json
                 that is where this checkout's kernel writes them; not a claim that none are set
```

### 6. T1  h1 send.py --dst_id 2

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic_tunnel/send.py 10.0.2.2 P4 driver probe --dst_id 2
```

```
sending on interface eth0 to dst_id 2
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1212
###[ MyTunnel ]### 
     pid       = 2048
     dst_id    = 2
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
           sport     = 60610
           dport     = 1234
           seq       = 0
           ack       = 0
           dataofs   = 5
           reserved  = 0
           flags     = S
           window    = 8192
           chksum    = 0x76df
           urgptr    = 0
           options   = []
###[ Raw ]### 
              load      = 'P4 driver probe'
```

### 7. T1  h2 sniffer

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic_tunnel/receive.py
```

```
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1212
###[ MyTunnel ]### 
     pid       = 2048
     dst_id    = 2
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
           sport     = 60610
           dport     = 1234
           seq       = 0
           ack       = 0
           dataofs   = 5
           reserved  = 0
           flags     = S
           window    = 8192
           chksum    = 0x76df
           urgptr    = 0
           options   = []
###[ Raw ]### 
              load      = 'P4 driver probe'
```

### 8. T1  h3 sniffer

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic_tunnel/receive.py
```

```
sniffing on eth0
```

### 9. T2  h1 send.py --dst_id 3

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic_tunnel/send.py 10.0.2.2 P4 driver probe --dst_id 3
```

```
sending on interface eth0 to dst_id 3
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1212
###[ MyTunnel ]### 
     pid       = 2048
     dst_id    = 3
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
           sport     = 50915
           dport     = 1234
           seq       = 0
           ack       = 0
           dataofs   = 5
           reserved  = 0
           flags     = S
           window    = 8192
           chksum    = 0x9cbe
           urgptr    = 0
           options   = []
###[ Raw ]### 
              load      = 'P4 driver probe'
```

### 10. T2  h2 sniffer

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic_tunnel/receive.py
```

```
sniffing on eth0
```

### 11. T2  h3 sniffer

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic_tunnel/receive.py
```

```
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1212
###[ MyTunnel ]### 
     pid       = 2048
     dst_id    = 3
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
           sport     = 50915
           dport     = 1234
           seq       = 0
           ack       = 0
           dataofs   = 5
           reserved  = 0
           flags     = S
           window    = 8192
           chksum    = 0x9cbe
           urgptr    = 0
           options   = []
###[ Raw ]### 
              load      = 'P4 driver probe'
```

### 12. N8  G1 link usage follows the iperf path

```
$ live-p1/_common.sh link_usage_round /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution (to the model's last host)
```

```
   basic_tunnel/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   basic_tunnel/solution: at 8s that is only 5.21 expected samples per primary link
   basic_tunnel/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   basic_tunnel/solution: h1 -> h3 (10.0.3.3), iperf -u -b 2M -t 16 -l 1200
   basic_tunnel/solution: primary=s1-eth3 s3-eth1   minor=
   basic_tunnel/solution: on-path  s1-eth3  36240272.000 bit  (switch)  [primary, 4345828 B]
   basic_tunnel/solution: on-path  s3-eth1  36875798.750 bit  (host)  [primary, 4345758 B]
   basic_tunnel/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   basic_tunnel/solution: off-path s1-eth1  0.000 bit  (host)
   basic_tunnel/solution: off-path s1-eth2  0.000 bit  (switch)
   basic_tunnel/solution: off-path s2-eth1  0.000 bit  (host)
   basic_tunnel/solution: off-path s2-eth2  0.000 bit  (switch)
   basic_tunnel/solution: off-path s2-eth3  0.000 bit  (switch)
   basic_tunnel/solution: off-path s3-eth2  0.000 bit  (switch)
   basic_tunnel/solution: off-path s3-eth3  0.000 bit  (switch)
   basic_tunnel/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE basic_tunnel/solution expect=follows primary=2 minor=0 rc=0
```

### 13. N9  ndt down

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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution -- this checkout is being put back
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

### 14. N10 ndt release

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
| PASS | injection: send.py built 2 tunnel frames | 【源碼推導，未執行】 | `2` | `2` | send.py:38 prints 'sending on interface <i> to dst_id <n>' before sendp() |
| PASS | --dst_id 2 lands on h2 | 【README 宣稱】＋【源碼推導，未執行】 | `h2=1 h3=0` | `h2=1 h3=0` | README step 2.4: the packet should be received at h2 |
| PASS | --dst_id 3 lands on h3, same IP | 【README 宣稱】＋【源碼推導，未執行】 | `h2=0 h3>=1` | `h2=0 h3=1` | README step 2.4: 'try to send to 10.0.3.3 ... will instead be received by h3'; here the IP is h2's and only dst_id moved, which is the whole tunnel |
| PASS | G1  link usage follows the iperf path | 【源碼推導，未執行】 | `primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger` | `PASS` | TICKET-P3 §2.7's program-independent cell, through live-p1/_common.sh's link_usage_round -- the same function live-p1/05 runs. The floor and every off-path edge's raw integral are in that transcript. |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h2-1-receive.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h2-2-receive.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h3-1-receive.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h3-2-receive.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/link_usage`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- basic_tunnel / solution
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/basic_tunnel

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/basic_tunnel/build/basic_tunnel.p4.p4info.txtpb -o /home/adam/tutorials/exercises/basic_tunnel/build/basic_tunnel.json /home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
-> /home/adam/tutorials/exercises/basic_tunnel/build/basic_tunnel.json  19548 B  sha256[:16]=bcb4ff532f309154  warnings=0

== plan ================================================================
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
program  : /home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4 -> build/basic_tunnel.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : h2/h3 receive.py; h1 send.py 10.0.2.2 --dst_id 2 then --dst_id 3; assert which host the tunnel delivered to
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/basic_tunnel --topology topology.json --p4 basic_tunnel.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
  NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/basic_tunnel --topology topology.json --p4 solution/basic_tunnel.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
package 'basic_tunnel' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
  control plane : ndtwin
  pipelines     : s1=build/basic_tunnel.json, s2=build/basic_tunnel.json, s3=build/basic_tunnel.json
  model         : 3 switches, 3 hosts, 12 edges (6 links, both directions stored)
  files         : 9
                  build/basic_tunnel.json
                  build/basic_tunnel.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  s1-runtime.json
                  s2-runtime.json
                  s3-runtime.json
                  solution/basic_tunnel.p4
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
  PASS  format                            1
  INFO  name                              basic_tunnel
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     3 dpids: [1, 2, 3]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  8 present
  PASS  topo_from_json.switches           3 entries
  PASS  topo_from_json.hosts              3 entries
  PASS  topo_from_json.switch_links       3 entries
  PASS  topo_from_json.host_links         3 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3]
  PASS  links agree                       6 links in both
  PASS  hosts named h<last octet>         3 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3']
  PASS  switches pipeline                 3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  INFO  s2 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  INFO  s3 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              18 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic_tunnel.json sha256:f10a88e35e2f6ba3  basic_tunnel.p4.p4info.txtpb sha256:e08bce0024fc7df2

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise basic_tunnel/solution on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by orch-0924 for 45m (drive_exercise basic_tunnel/solution on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
  PASS  format                            1
  INFO  name                              basic_tunnel
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     3 dpids: [1, 2, 3]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  8 present
  PASS  topo_from_json.switches           3 entries
  PASS  topo_from_json.hosts              3 entries
  PASS  topo_from_json.switch_links       3 entries
  PASS  topo_from_json.host_links         3 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3]
  PASS  links agree                       6 links in both
  PASS  hosts named h<last octet>         3 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3']
  PASS  switches pipeline                 3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  INFO  s2 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  INFO  s3 pipeline                       build/basic_tunnel.json  p4info sha256:e08bce0024fc7df2  program=/home/adam/tutorials/exercises/basic_tunnel/solution/basic_tunnel.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              18 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)

... [trimmed; 5691 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=e08bce0024fc7df2  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s2  ndtwin=False p4info_sha256=e08bce0024fc7df2  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)
   s3  ndtwin=False p4info_sha256=e08bce0024fc7df2  entries recorded=6 applied=6 failed=0 api_writes=0  (entries_recorded=6)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 03:48:12)
  note           in use: ndt up p4 3 at 2026-09-25 03:03:12 by orch-0924
  prev claim     orch-0924 (until 03:46:22), superseded 2026-09-25 03:03:10  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 03:03:10; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           0c96c1d0  +79 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  3, written by 'ndt up p4 3' at 03:03:12 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          3   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/basic_tunnel-solution/ndtwin/topology.json
  p4 host knob   3   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic_tunnel-solution (mode ndtwin)
                 basic_tunnel -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2482392, 3 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    6       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2482652 alive,kernel.pid=2482646 alive,p4_proxy.child.pid=2482564 alive,p4_proxy.pid=2482558 alive

network health
  switches       3 up, 3 enabled, 0 admin-disabled
  links          12 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel grap
... [trimmed; 3809 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3
$ h2: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic_tunnel/receive.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h2-1-receive.log)
$ h3: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic_tunnel/receive.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h3-1-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic_tunnel/send.py 10.0.2.2 P4 driver probe --dst_id 2
sending on interface eth0 to dst_id 2
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1212
###[ MyTunnel ]### 
     pid       = 2048
     dst_id    = 2
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
           sport     = 60610
           dport     = 1234
           seq       = 0
           ack       = 0
           dataofs   = 5
           reserved  = 0
           flags     = S
           window    = 8192
           chksum    = 0x76df
           urgptr    = 0
           options   = []
###[ Raw ]### 
              load      = 'P4 driver probe'


-- h2 (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h2-1-receive.log) --
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1212
###[ MyTunnel ]### 
     pid       = 2048
     dst_id    = 2
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
           sport     = 60610
           dport     = 1234
           seq       = 0
           ack       = 0
           dataofs   = 5
           reserved  = 0
           flags     = S
           window    = 8192
           chksum    = 0x76df
           urgptr    = 0
           options   = []
###[ Raw ]### 
              load      = 'P4 driver probe'


-- h3 (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h3-1-receive.log) --
sniffing on eth0

$ h2: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic_tunnel/receive.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h2-2-receive.log)
$ h3: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/basic_tunnel/receive.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h3-2-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic_tunnel/send.py 10.0.2.2 P4 driver probe --dst_id 3
sending on interface eth0 to dst_id 3
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1212
###[ MyTunnel ]### 
     pid       = 2048
     dst_id    = 3
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
           sport     = 50915
           dport     = 1234
           seq       = 0
           ack       = 0
           dataofs   = 5
           reserved  = 0
           flags     = S
           window    = 8192
           chksum    = 0x9cbe
           urgptr    = 0
           options   = []
###[ Raw ]### 
              load      = 'P4 driver probe'


-- h2 (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h2-2-receive.log) --
sniffing on eth0

-- h3 (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h3-2-receive.log) --
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1212
###[ MyTunnel ]### 
     pid       = 2048
     dst_id    = 3
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
           sport     = 50915
           dport     = 1234
           seq       = 0
           ack       = 0
           dataofs   = 5
           reserved  = 0
           flags     = S
           window    = 8192
           chksum    = 0x9cbe
           urgptr    = 0
           options   = []
###[ Raw ]### 
              load      = 'P4 driver probe'


   PASS injection: send.py built 2 tunnel frames       want=2                      got=2
   PASS --dst_id 2 lands on h2                         want=h2=1 h3=0              got=h2=1 h3=0
   PASS --dst_id 3 lands on h3, same IP                want=h2=0 h3>=1             got=h2=0 h3=1

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h2-1-receive.log 885 B
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h2-2-receive.log 17 B
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h3-1-receive.log 17 B
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-24T190311Z_basic_tunnel_solution_ndtwin/driver-h3-2-receive.log 885 B

== G1  link usage follows the iperf path (program-independent) =========
   basic_tunnel/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   basic_tunnel/solution: at 8s that is only 5.21 expected samples per primary link
   basic_tunnel/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   basic_tunnel/solution: h1 -> h3 (10.0.3.3), iperf -u -b 2M -t 16 -l 1200
   basic_tunnel/solution: primary=s1-eth3 s3-eth1   minor=
   basic_tunnel/solution: on-path  s1-eth3  36240272.000 bit  (switch)  [primary, 4345828 B]
   basic_tunnel/solution: on-path  s3-eth1  36875798.750 bit  (host)  [primary, 4345758 B]
   basic_tunnel/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   basic_tunnel/solution: off-path s1-eth1  0.000 bit  (host)
   basic_tunnel/solution: off-path s1-eth2  0.000 bit  (switch)
   basic_tunnel/solution: off-path s2-eth1  0.000 bit  (host)
   basic_tunnel/solution: off-path s2-eth2  0.000 bit  (switch)
   basic_tunnel/solution: off-path s2-eth3  0.000 bit  (switch)
   basic_tunnel/solution: off-path s3-eth2  0.000 bit  (switch)
   basic_tunnel/solution: off-path s3-eth3  0.000 bit  (switch)
   basic_tunnel/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE basic_tunnel/solution expect=follows primary=2 minor=0 rc=0

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
... [trimmed; 5434 chars total]
   ndt down rc=0
   host_count_override: put back to the 2 bytes this round found
   telemetry_override: unchanged (absent)
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: send.py built 2 tunnel frames       want=2                      got=2   【源碼推導，未執行】
   PASS --dst_id 2 lands on h2                         want=h2=1 h3=0              got=h2=1 h3=0   【README 宣稱】＋【源碼推導，未執行】
   PASS --dst_id 3 lands on h3, same IP                want=h2=0 h3>=1             got=h2=0 h3=1   【README 宣稱】＋【源碼推導，未執行】
   PASS G1  link usage follows the iperf path          want=primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger got=PASS   【源碼推導，未執行】

>>> PASS (4/4)
```

### stderr（mininet 的 logger 走這裡）

```

```
