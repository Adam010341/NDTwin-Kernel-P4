# 執行報告 — `ecn` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-26T061124Z |
| exercise | `ecn` |
| which | `solution` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution` |
| cwd | `/home/adam/tutorials/exercises/ecn` |
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
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/ecn/build/ecn.p4.p4info.txtpb -o /home/adam/tutorials/exercises/ecn/build/ecn.json /home/adam/tutorials/exercises/ecn/solution/ecn.p4
rc=0  warnings=1
/home/adam/tutorials/exercises/ecn/solution/ecn.p4(7): [--Wwarn=unused] warning: 'TCP_PROTOCOL' is unused
const bit<8> TCP_PROTOCOL = 0x06;
             ^^^^^^^^^^^^
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/ecn/build/ecn.json` | 17729 | `7051f9a0601fbaf6` |
| `/home/adam/tutorials/exercises/ecn/build/ecn.p4.p4info.txtpb` | 1041 | `10f07d0d345361d8` |

來源 `.p4`：`/home/adam/tutorials/exercises/ecn/solution/ecn.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : topology.json
hosts    : h1, h11, h2, h22, h3
switches : s1, s2, s3
links    : 8
```

### 3b. `GET /p4/switch_state`（揭露，不是結果）

```
control_plane.mode    ndtwin
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
s1  ndtwin=False p4info_sha256=10f07d0d345361d8  entries recorded=4 applied=4 failed=0 api_writes=0  (entries_recorded=4)
s2  ndtwin=False p4info_sha256=10f07d0d345361d8  entries recorded=4 applied=4 failed=0 api_writes=0  (entries_recorded=4)
s3  ndtwin=False p4info_sha256=10f07d0d345361d8  entries recorded=3 applied=3 failed=0 api_writes=0  (entries_recorded=3)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/ecn --topology topology.json --p4 solution/ecn.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
```

```
package 'ecn' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
  control plane : ndtwin
  pipelines     : s1=build/ecn.json, s2=build/ecn.json, s3=build/ecn.json
  model         : 3 switches, 5 hosts, 16 edges (8 links, both directions stored)
  files         : 9
                  build/ecn.json
                  build/ecn.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  s1-runtime.json
                  s2-runtime.json
                  s3-runtime.json
                  solution/ecn.p4
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
  PASS  format                            1
  INFO  name                              ecn
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     3 dpids: [1, 2, 3]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  8 present
  PASS  topo_from_json.switches           3 entries
  PASS  topo_from_json.hosts              5 entries
  PASS  topo_from_json.switch_links       3 entries
  PASS  topo_from_json.host_links         5 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3]
  PASS  links agree                       8 links in both
  PASS  hosts named h<last octet>         5 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h11', 'h2', 'h22', 'h3']
  PASS  switches pipeline                 3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  INFO  s2 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  INFO  s3 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              11 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  ecn.json sha256:63bfcd763285227c  ecn.p4.p4info.txtpb sha256:10f07d0d345361d8

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
  PASS  format                            1
  INFO  name                              ecn
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     3 dpids: [1, 2, 3]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  8 present
  PASS  topo_from_json.switches           3 entries
  PASS  topo_from_json.hosts              5 entries
  PASS  topo_from_json.switch_links       3 entries
  PASS  topo_from_json.host_links         5 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3]
  PASS  links agree                       8 links in both
  PASS  hosts named h<last octet>         5 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h11', 'h2', 'h22', 'h3']
  PASS  switches pipeline                 3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  INFO  s2 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  INFO  s3 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              11 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  ecn.json sha256:63bfcd763285227c  ecn.p4.p4info.txtpb sha256:10f07d0d345361d8

PASS -- every check passed

ndt up p4
  hosts        5        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/ecn-solution/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution (mode ndtwin, 3 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 5 (persistent; affects every later run)
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 3 switches and the manifest
  ok  3 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 1134730) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 1134811) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- the package's own program runs on dpid
  !!    1,2,3; the proxy says it sent no LLDP and installed no routes on this
  !!    fabric (control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery)
  ok  table entries: 11/11 applied across 3 switch(es) (they do not all carry the same count), 0 failed
  ok  kernel: 3 switches, 3 up, 16 edges, 5 hosts
  ok  model matches fabric: 5 hosts (kernel graph, topology file and 5 host namespaces all agree)
  ok  telemetry: auto -- 0 cooperative, 3 link, 0 none; the proxy agrees switch by switch
  ok  data plane: h1 -> 10.0.2.2 forwards

up. ready
  proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo
  !!  package pipeline: NDTwin discovered no links and installed no routes on this
  !!    fabric; forwarding is whatever the package's 11 entries on
  !!    3 switch(es) make of it. ndt status quotes no sample rate for it.
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1790403091.495729,
  "boot_id": "e72f0eabfb8548baa6cb2115df1afa12",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution",
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
        "pid": 1134544,
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
    "1:3->2:3": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "1:4->3:2": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "2:3->1:3": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "2:4->3:3": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "3:2->1:4": {
      "down": null,
      "last_beacon_age_s": null,
      "reported_to_kernel": false,
      "source": "declared"
    },
    "3:3->2:4": {
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
      "entries_recorded": 4,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30051",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1790403092.595669,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution/build/ecn.p4.p4info.txtpb",
        "p4info_sha256": "10f07d0d345361d8",
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
      "probe_age_s": 1.956,
      "probe_detail": "answered GetForwardingPipelineConfig",
      "probe_ok": true,
      "rules_timed": 4,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": true,
      "table_entries": {
        "api_writes": 0,
        "applied": 4,
        "failed": 0,
        "journaled": false,
        "recorded": 4
      },
      "table_generation": "1a66870a01594c33a6fed5700e99d09d",
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
      "entries_recorded": 4,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30052",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1790403092.5972438,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution/build/ecn.p4.p4info.txtpb",
        "p4info_sha256": "10f07d0d345361d8",
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
      "probe_age_s": 1.955,
      "probe_detail": "answered GetForwardingPipelineConfig",
      "probe_ok": true,
      "rules_timed": 4,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": true,
      "table_entries": {
        "api_writes": 0,
        "applied": 4,
        "failed": 0,
        "journaled": false,
        "recorded": 4
      },
      "table_generation": "3d877900d78a41cc9a918f13b3a278a6",
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
      "entries_recorded": 3,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30053",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1790403092.5980048,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution/build/ecn.p4.p4info.txtpb",
        "p4info_sha256": "10f07d0d345361d8",
        "skipped": [
          "clone_session",
          "sflow_telemetry"
        ]
      },
      "pi
... [trimmed; 6997 chars total]
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 14:56:25)
  note           in use: ndt up p4 5 at 2026-09-26 14:11:25 by pb5-trial-0926
  prev claim     pb5-trial-0926 (until 14:54:57), superseded 2026-09-26 14:11:24  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-26 14:11:24; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           580767a8  +83 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  5, written by 'ndt up p4 5' at 14:11:25 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          5   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/ecn-solution/ndtwin/topology.json
  p4 host knob   5   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution (mode ndtwin)
                 ecn -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 1134544, 3 switch(es), rate 256
  link shaping   on
                 s1:3<->s2:3 0.5 Mbit/s
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=1134816 alive,kernel.pid=1134811 alive,p4_proxy.child.pid=1134735 alive,p4_proxy.pid=1134730 alive

network health
  switches       3 up, 3 enabled, 0 admin-disabled
  links          16 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  3 switches (3 up, 3 enabled), 5 hosts, 16 edges
proxy
  20 destination paths reported; none expected -- the package's program on dpid 1,2,3, proxy skipped lldp_discovery

up target
  asked for      p4, 5 hosts   (recorded 2026-09-26 14:11:25 by pb5-trial-0926)
  topology       .test_run/packages/ecn-solution/ndtwin/topology.json   (declares 5 hosts / 16 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   5                      == 5   ok
  graph hosts    5                      == 5   ok
  graph edges    16                     == 16   ok
  topology file  sha256 154477b0e258    == recorded   ok
  device names   no overlay file at .test_run/nickname_overlay/topology.names.json
                 that is where this checkout's kernel writes them; not a claim that none are set
```

### 6. BG  h11 -> h22 background UDP (fills the bottleneck queue)

```
$ iperf -s -u on h22; iperf -c 10.0.2.22 -u -b 1M -t 91 on h11
```

```
(background; the numbers it reports are not read)
```

### 7. E1  h2 starts the sniffer

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/ecn/receive.py
```

```
(background; output below)
```

### 8. E2  h1 send.py (one packet per second)

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/ecn/send.py 10.0.2.2 P4 driver probe 60
```

```
............................................................###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:01
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x1
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = udp
     chksum    = 0x63be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'


Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.
```

### 9. E3  h2 sniffer output

```
$ /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/ecn/receive.py
```

```
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x1
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x1
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 
... [trimmed; 17749 chars total]
```

### 10. E4  probes that reached h2 (disclosure, not a verdict)

```
$ counted from E3; E2 asked send.py for 60
```

```
31 of 60 probes reached h2 before the sniffer was stopped (3 s after the sender exited)
tos in arrival order: 0x1 0x1 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3
```

### 11. N8  G1 link usage follows the iperf path

```
$ live-p1/_common.sh link_usage_round /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution (to the model's last host)
```

```
   ecn/solution: slowest declared link = 500000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 500000 bit/s
   ecn/solution: at 8s that is only 1.30 expected samples per primary link
   ecn/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 500000)) = 62s
   ecn/solution: h1 -> h22 (10.0.2.22), iperf -u -b 2M -t 62 -l 1200
   ecn/solution: primary=s1-eth3 s2-eth1   minor=
   ecn/solution: on-path  s1-eth3  6750000.000 bit  (switch)  [primary, 4101784 B]
   ecn/solution: on-path  s2-eth1  38535170.500 bit  (host)  [primary, 4101987 B]
   ecn/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   ecn/solution: off-path s1-eth1  0.000 bit  (host)
   ecn/solution: off-path s1-eth2  0.000 bit  (host)
   ecn/solution: off-path s1-eth4  0.000 bit  (switch)
   ecn/solution: off-path s2-eth2  0.000 bit  (host)
   ecn/solution: off-path s2-eth3  0.000 bit  (switch)
   ecn/solution: off-path s2-eth4  0.000 bit  (switch)
   ecn/solution: off-path s3-eth1  0.000 bit  (host)
   ecn/solution: off-path s3-eth2  0.000 bit  (switch)
   ecn/solution: off-path s3-eth3  0.000 bit  (switch)
   ecn/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE ecn/solution expect=follows primary=2 minor=0 rc=0
```

### 12. N9  ndt down

```
$ ndt down
```

```
ndt down
  this teardown is about:
        3 bmv2 switch(es)
        8 host/switch process(es)
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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution -- this checkout is being put back
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
| PASS | injection: packets reached h2 | 【源碼推導，未執行】 | `>=1` | `31` | send.py:35-41 sends one UDP/4321 datagram per second; receive.py:34 filters 'udp and port 4321'. Every claim below is vacuous without this. |
| PASS | injection: send.py showed the frame it built | 【源碼推導，未執行】 | `1 show2` | `1` | send.py:36 pkt.show2() before the loop; the sender sets tos=1 (:35) |
| PASS | h2 saw a congestion-marked packet | 【README 宣稱】＋【源碼推導，未執行】 | `0x3 among the tos values` | `['0x1', '0x3']` | README step 3: 'tos values change from 1 to 3 as the queue builds up'; solution/ecn.p4:131-139 sets ecn=3 when enq_qdepth >= 10. Needs the 0.5 Mbit/s link of topology.json:65-69 (G2-C). |
| PASS | G1  link usage follows the iperf path | 【源碼推導，未執行】 | `primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger` | `PASS` | TICKET-P3 §2.7's program-independent cell, through live-p1/_common.sh's link_usage_round -- the same function live-p1/05 runs. The floor and every off-path edge's raw integral are in that transcript. |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T061124Z_ecn_solution_ndtwin/driver-bg-iperf-h11-to-h22.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T061124Z_ecn_solution_ndtwin/driver-h2-receive.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T061124Z_ecn_solution_ndtwin/link_usage`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- ecn / solution
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/ecn

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/ecn/build/ecn.p4.p4info.txtpb -o /home/adam/tutorials/exercises/ecn/build/ecn.json /home/adam/tutorials/exercises/ecn/solution/ecn.p4
/home/adam/tutorials/exercises/ecn/solution/ecn.p4(7): [--Wwarn=unused] warning: 'TCP_PROTOCOL' is unused
const bit<8> TCP_PROTOCOL = 0x06;
             ^^^^^^^^^^^^
-> /home/adam/tutorials/exercises/ecn/build/ecn.json  17729 B  sha256[:16]=7051f9a0601fbaf6  warnings=1

== plan ================================================================
topology : topology.json
hosts    : h1, h11, h2, h22, h3
switches : s1, s2, s3
links    : 8
program  : /home/adam/tutorials/exercises/ecn/solution/ecn.p4 -> build/ecn.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : h22 iperf -s; h11 iperf -u -> h22 to fill the 0.5 Mbit/s queue; h1 send.py -> h2 receive.py; assert ipv4.tos
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/ecn --topology topology.json --p4 ecn.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
  NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/ecn --topology topology.json --p4 solution/ecn.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
package 'ecn' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
  control plane : ndtwin
  pipelines     : s1=build/ecn.json, s2=build/ecn.json, s3=build/ecn.json
  model         : 3 switches, 5 hosts, 16 edges (8 links, both directions stored)
  files         : 9
                  build/ecn.json
                  build/ecn.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  s1-runtime.json
                  s2-runtime.json
                  s3-runtime.json
                  solution/ecn.p4
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
  PASS  format                            1
  INFO  name                              ecn
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     3 dpids: [1, 2, 3]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  8 present
  PASS  topo_from_json.switches           3 entries
  PASS  topo_from_json.hosts              5 entries
  PASS  topo_from_json.switch_links       3 entries
  PASS  topo_from_json.host_links         5 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3]
  PASS  links agree                       8 links in both
  PASS  hosts named h<last octet>         5 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h11', 'h2', 'h22', 'h3']
  PASS  switches pipeline                 3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  INFO  s2 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  INFO  s3 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              11 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  ecn.json sha256:63bfcd763285227c  ecn.p4.p4info.txtpb sha256:10f07d0d345361d8

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise ecn/solution on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by pb5-trial-0926 for 45m (drive_exercise ecn/solution on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
  PASS  format                            1
  INFO  name                              ecn
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     3 dpids: [1, 2, 3]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  8 present
  PASS  topo_from_json.switches           3 entries
  PASS  topo_from_json.hosts              5 entries
  PASS  topo_from_json.switch_links       3 entries
  PASS  topo_from_json.host_links         5 entries
  PASS  switches agree                    model and package.json both say [1, 2, 3]
  PASS  links agree                       8 links in both
  PASS  hosts named h<last octet>         5 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h11', 'h2', 'h22', 'h3']
  PASS  switches pipeline                 3 of 3 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  INFO  s2 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  INFO  s3 pipeline                       build/ecn.json  p4info sha256:10f07d0d345361d8  program=/home/adam/tutorials/exercises/ecn/solution/ecn.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              11 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss 
... [trimmed; 5597 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=10f07d0d345361d8  entries recorded=4 applied=4 failed=0 api_writes=0  (entries_recorded=4)
   s2  ndtwin=False p4info_sha256=10f07d0d345361d8  entries recorded=4 applied=4 failed=0 api_writes=0  (entries_recorded=4)
   s3  ndtwin=False p4info_sha256=10f07d0d345361d8  entries recorded=3 applied=3 failed=0 api_writes=0  (entries_recorded=3)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 14:56:25)
  note           in use: ndt up p4 5 at 2026-09-26 14:11:25 by pb5-trial-0926
  prev claim     pb5-trial-0926 (until 14:54:57), superseded 2026-09-26 14:11:24  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-26 14:11:24; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           580767a8  +83 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  5, written by 'ndt up p4 5' at 14:11:25 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          5   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/ecn-solution/ndtwin/topology.json
  p4 host knob   5   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/ecn-solution (mode ndtwin)
                 ecn -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 1134544, 3 switch(es), rate 256
  link shaping   on
                 s1:3<->s2:3 0.5 Mbit/s
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=1134816 alive,kernel.pid=1134811 alive,p4_proxy.child.pid=1134735 alive,p4_proxy.pid=1134730 alive

network health
  switches       3 up, 3 enabled, 0 admin-disabled
  links          16 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  3 swi
... [trimmed; 3797 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3, h11=10.0.1.11, h22=10.0.2.22
$ h22: iperf -s -u   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T061124Z_ecn_solution_ndtwin/driver-bg-iperf-h11-to-h22.log)
$ h11: iperf -c 10.0.2.22 -u -b 1M -t 91
$ h2: /home/adam/p4dev-python-venv/bin/python -u /home/adam/tutorials/exercises/ecn/receive.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T061124Z_ecn_solution_ndtwin/driver-h2-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/ecn/send.py 10.0.2.2 P4 driver probe 60
............................................................###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:01
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x1
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = udp
     chksum    = 0x63be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'


Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

Sent 1 packets.

-- h2 receive.py output (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T061124Z_ecn_solution_ndtwin/driver-h2-receive.log) --
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x1
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x1
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      = 'P4 driver probe'

got a packet
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:02
  src       = 08:00:00:00:02:00
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x3
     len       = 43
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x65bc
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 23
        chksum    = 0xc2ad
###[ Raw ]### 
           load      
... [trimmed; 17749 chars total]
   31 of 60 probes reached h2 before the sniffer was stopped (3 s after the sender exited)
   tos in arrival order: 0x1 0x1 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3 0x3
   PASS injection: packets reached h2                  want=>=1                    got=31
   PASS injection: send.py showed the frame it built   want=1 show2                got=1
   PASS h2 saw a congestion-marked packet              want=0x3 among the tos values got=['0x1', '0x3']

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T061124Z_ecn_solution_ndtwin/driver-bg-iperf-h11-to-h22.log 539 B
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T061124Z_ecn_solution_ndtwin/driver-h2-receive.log 17749 B

== G1  link usage follows the iperf path (program-independent) =========
   ecn/solution: slowest declared link = 500000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 500000 bit/s
   ecn/solution: at 8s that is only 1.30 expected samples per primary link
   ecn/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 500000)) = 62s
   ecn/solution: h1 -> h22 (10.0.2.22), iperf -u -b 2M -t 62 -l 1200
   ecn/solution: primary=s1-eth3 s2-eth1   minor=
   ecn/solution: on-path  s1-eth3  6750000.000 bit  (switch)  [primary, 4101784 B]
   ecn/solution: on-path  s2-eth1  38535170.500 bit  (host)  [primary, 4101987 B]
   ecn/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   ecn/solution: off-path s1-eth1  0.000 bit  (host)
   ecn/solution: off-path s1-eth2  0.000 bit  (host)
   ecn/solution: off-path s1-eth4  0.000 bit  (switch)
   ecn/solution: off-path s2-eth2  0.000 bit  (host)
   ecn/solution: off-path s2-eth3  0.000 bit  (switch)
   ecn/solution: off-path s2-eth4  0.000 bit  (switch)
   ecn/solution: off-path s3-eth1  0.000 bit  (host)
   ecn/solution: off-path s3-eth2  0.000 bit  (switch)
   ecn/solution: off-path s3-eth3  0.000 bit  (switch)
   ecn/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE ecn/solution expect=follows primary=2 minor=0 rc=0

== teardown: ndt down, the two knobs, then ndt release =================
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
  this teardown is about:
        3 bmv2 switch(es)
        8 host/switch process(es)
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
        :9093 is still lis
... [trimmed; 5371 chars total]
   ndt down rc=0
   host_count_override: put back to the 2 bytes this round found
   telemetry_override: unchanged (absent)
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: packets reached h2                  want=>=1                    got=31   【源碼推導，未執行】
   PASS injection: send.py showed the frame it built   want=1 show2                got=1   【源碼推導，未執行】
   PASS h2 saw a congestion-marked packet              want=0x3 among the tos values got=['0x1', '0x3']   【README 宣稱】＋【源碼推導，未執行】
   PASS G1  link usage follows the iperf path          want=primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger got=PASS   【源碼推導，未執行】

>>> PASS (4/4)
```

### stderr（mininet 的 logger 走這裡）

```

```
