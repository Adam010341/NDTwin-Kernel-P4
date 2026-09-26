# 執行報告 — `firewall` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-26T154737Z |
| exercise | `firewall` |
| which | `solution` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution` |
| cwd | `/home/adam/tutorials/exercises/firewall` |
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
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/firewall/build/firewall.p4.p4info.txtpb -o /home/adam/tutorials/exercises/firewall/build/firewall.json /home/adam/tutorials/exercises/firewall/solution/firewall.p4
rc=0  warnings=0

```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/firewall/build/firewall.json` | 50458 | `e21dcdca38471ff9` |
| `/home/adam/tutorials/exercises/firewall/build/firewall.p4.p4info.txtpb` | 2103 | `ef7561c073ee3b7f` |

來源 `.p4`：`/home/adam/tutorials/exercises/firewall/solution/firewall.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

同時編譯（Makefile 的 `DEFAULT_PROG` / 其他 `*.p4`）：`/home/adam/tutorials/exercises/firewall/basic.p4` -> `/home/adam/tutorials/exercises/firewall/build/basic.json`  sha256[:16]=`2e2eaaa92bbc95f7`

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
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
s1  ndtwin=False p4info_sha256=ef7561c073ee3b7f  entries recorded=13 applied=13 failed=0 api_writes=0  (entries_recorded=13)
s2  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
s3  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
s4  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/firewall --topology pod-topo/topology.json --p4 basic.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
```

```
package 'firewall' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
  control plane : ndtwin
  pipelines     : s1=build/firewall.json, s2=build/basic.json, s3=build/basic.json, s4=build/basic.json
  model         : 4 switches, 4 hosts, 16 edges (8 links, both directions stored)
  files         : 12
                  basic.p4
                  build/basic.json
                  build/basic.p4.p4info.txtpb
                  build/firewall.json
                  build/firewall.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  pod-topo/s1-runtime.json
                  pod-topo/s2-runtime.json
                  pod-topo/s3-runtime.json
                  pod-topo/s4-runtime.json
                  pod-topo/topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
  PASS  format                            1
  INFO  name                              firewall
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
  INFO  s1 pipeline                       build/firewall.json  p4info sha256:ef7561c073ee3b7f  program=/home/adam/tutorials/exercises/firewall/solution/firewall.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              28 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:fb533999024a5580  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
  PASS  format                            1
  INFO  name                              firewall
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
  INFO  s1 pipeline                       build/firewall.json  p4info sha256:ef7561c073ee3b7f  program=/home/adam/tutorials/exercises/firewall/solution/firewall.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              28 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:fb533999024a5580  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/firewall-solution/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution (mode ndtwin, 4 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 4 switches and the manifest
  ok  4 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
      heartbeat plan: /tmp/ndtwin_p4_switches.json (sha256 2df44128c0d8), 4 switch(es), every one a live bmv2
        link s1-eth3 (dpid 1 port 3) <-> s3-eth1 (dpid 3 port 1)
        link s1-eth4 (dpid 1 port 4) <-> s4-eth2 (dpid 4 port 2)
        link s2-eth3 (dpid 2 port 3) <-> s4-eth1 (dpid 4 port 1)
        link s2-eth4 (dpid 2 port 4) <-> s3-eth2 (dpid 3 port 2)
        4 link(s) -> 8 direction(s); 4 host-facing interface(s) listened on, never sent on
      heartbeat started (pid 3884766; report: /run/ndtwin-lab/heartbeat.json, log: /run/ndtwin-lab/heartbeat.log)
  ok  heartbeat running on the inter-switch veths: a cut link is detected, and routed around where NDTwin owns the route tables (switch_state: reroute, heartbeat)
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 3884806) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 3884899) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- the package's own program runs on dpid
  !!    1,2,3,4; the proxy says it sent no LLDP and installed no routes on this
  !!    fabric (control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery)
  ok  table entries: 28/28 applied across 4 switch(es) (they do not all carry the same count), 0 failed
  ok  kernel: 4 switches, 4 up, 16 edges, 4 hosts
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces
... [trimmed; 6461 chars total]
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1790437664.9273224,
  "boot_id": "41d411c452014825a71aaddb33dad3bc",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution",
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
        "pid": 3884641,
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
    "detail": "running, written 1.0 s ago, 8 declared direction(s)",
    "directions": 8,
    "error": null,
    "frame": {
      "bytes": 60,
      "ethertype": "0x88B5",
      "one_per_direction_every_s": 5.0
    },
    "frames_reached_hosts": false,
    "missing_directions": [],
    "note": "the heartbeat proves a veth carries frames, not that a switch is alive (a switch powered off by P4PowerStrategy is still heard); its frames are also what link telemetry samples, 1 in 256, on those veths",
    "period_s": 5.0,
    "pid": 3884766,
    "report": "/run/ndtwin-lab/heartbeat.json",
    "report_age_s": 1.002,
    "session": "732bb1a56f923c48",
    "side_effects": {
      "foreign_frames": 0,
      "forwarded_between_switches": 0,
      "forwarded_to_hosts": 0,
      "misdelivered": 0
    },
    "state": "usable",
    "undeclared_directions": [],
    "watchdog": "running",
    "watchdog_passes": []
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
        "link_discovery": "heartbeat",
        "reroute": false
      },
      "entries_recorded": 13,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30051",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1790437666.0558052,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution/build/firewall.p4.p4info.txtpb",
        "p4info_sha256": "ef7561c073ee3b7f",
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
      "probe_age_s": 0.071,
      "probe_detail": "answered GetForwardingPipelineConfig",
      "probe_ok": true,
      "rules_timed": 13,
      "rules_total": null,
      "rules_total_age_s": null,
      "stream_alive": true,
      "table_entries": {
        "api_writes": 0,
        "applied": 13,
        "failed": 0,
        "journaled": false,
        "recorded": 13
      },
      "table_generation": "d8f4b854119d4ecf95471f5e64ba1f6c",
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
        "five_tuple": fal
... [trimmed; 11193 chars total]
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 00:32:38)
  note           in use: ndt up p4 4 at 2026-09-26 23:47:38 by orch-0926
  prev claim     orch-0926 (until 00:31:21), superseded 2026-09-26 23:47:37  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-26 23:47:37; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           cafd518a  +88 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 23:47:38)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/firewall-solution/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution (mode ndtwin)
                 firewall -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 3884641, 4 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  heartbeat      running (pid 3884766, session 732bb1a56f923c48) -- 8 direction(s), report 3.7 s old
  pidfiles       kernel.child.pid=3884904 alive,kernel.pid=3884899 alive,p4_proxy.child.pid=3884811 alive,p4_proxy.pid=3884806 alive

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
  asked for      p4, 4 hosts   (recorded 2026-09-26 23:47:38 by orch-0926)
  topology       .test_run/packages/firewall-solution/ndtwin/topology.json   (declares 4 hosts / 16 edges)
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

### 7. F1  iperf h1 -> h3 (internal to external)

```
$ iperf -s on h3; iperf -c 10.0.3.3 -t 3 on h1
```

```
client:
------------------------------------------------------------
Client connecting to 10.0.3.3, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.1.1 port 56398 connected with 10.0.3.3 port 5001 (icwnd/mss/irtt=14/1448/842)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0258 sec   290 MBytes   803 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.3.3 port 5001 connected with 10.0.1.1 port 56398 (icwnd/mss/irtt=14/1448/556)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0133 sec   290 MBytes   806 Mbits/sec
```

### 8. F2  iperf h3 -> h1 (external to internal)

```
$ iperf -s on h1; iperf -c 10.0.1.1 -t 3 on h3
```

```
client:
------------------------------------------------------------
Client connecting to 10.0.1.1, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
tcp connect failed: Connection timed out
[  1] local 0.0.0.0 port 0 connected with 10.0.1.1 port 5001

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------

(client killed after 25s)
```

### 9. N8  G1 link usage follows the iperf path

```
$ live-p1/_common.sh link_usage_round /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution (to the model's last host)
```

```
   firewall/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   firewall/solution: at 8s that is only 5.21 expected samples per primary link
   firewall/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   firewall/solution: h1 -> h4 (10.0.4.4), iperf -u -b 2M -t 16 -l 1200
   firewall/solution: primary=s1-eth4 s2-eth2 s4-eth1   minor=
   firewall/solution: on-path  s1-eth4  31145074.250 bit  (switch)  [primary, 4345938 B]
   firewall/solution: on-path  s2-eth2  52123753.750 bit  (host)  [primary, 4345758 B]
   firewall/solution: on-path  s4-eth1  30511195.500 bit  (switch)  [primary, 4345938 B]
   firewall/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   firewall/solution: off-path s1-eth1  0.000 bit  (host)
   firewall/solution: off-path s1-eth2  0.000 bit  (host)
   firewall/solution: off-path s1-eth3  0.000 bit  (switch)
   firewall/solution: off-path s2-eth1  0.000 bit  (host)
   firewall/solution: off-path s2-eth3  0.000 bit  (switch)
   firewall/solution: off-path s2-eth4  0.000 bit  (switch)
   firewall/solution: off-path s3-eth1  0.000 bit  (switch)
   firewall/solution: off-path s3-eth2  0.000 bit  (switch)
   firewall/solution: off-path s4-eth2  0.000 bit  (switch)
   firewall/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE firewall/solution expect=follows primary=3 minor=0 rc=0
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
  stopping the heartbeat (before the topology it watches is taken down)
      heartbeat stopped (pid 3884766)
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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution -- this checkout is being put back
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000

clean
  ok  the 8 port(s) 
... [trimmed; 6339 chars total]
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
| PASS | iperf h1 -> h3 (internal -> external) | 【README 宣稱】＋【源碼推導，未執行】 | `connects` | `connects` | README step 1.2; firewall.p4 ipv4_lpm forwards in both arms |
| PASS | iperf h3 -> h1 is blocked | 【README 宣稱】＋【源碼推導，未執行】 | `no transfer` | `no transfer` | solution/firewall.p4:212-219 drop()s direction-1 packets whose bloom cells are unset |
| PASS | the fabric still forwards (pingall) | 【源碼推導，未執行】 | `0.0%` | `0% (12/12 pairs at 0%, 0 lossy)` | ICMP has no TCP header, so check_ports never fires: the firewall drops TCP, not the fabric |
| PASS | G1  link usage follows the iperf path | 【源碼推導，未執行】 | `primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger` | `PASS` | TICKET-P3 §2.7's program-independent cell, through live-p1/_common.sh's link_usage_round -- the same function live-p1/05 runs. The floor and every off-path edge's raw integral are in that transcript. |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T154737Z_firewall_solution_ndtwin/driver-iperf-h1-to-h3.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T154737Z_firewall_solution_ndtwin/driver-iperf-h3-to-h1.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T154737Z_firewall_solution_ndtwin/link_usage`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- firewall / solution
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/firewall

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/firewall/build/firewall.p4.p4info.txtpb -o /home/adam/tutorials/exercises/firewall/build/firewall.json /home/adam/tutorials/exercises/firewall/solution/firewall.p4
-> /home/adam/tutorials/exercises/firewall/build/firewall.json  50458 B  sha256[:16]=e21dcdca38471ff9  warnings=0

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/firewall/build/basic.p4.p4info.txtpb -o /home/adam/tutorials/exercises/firewall/build/basic.json /home/adam/tutorials/exercises/firewall/basic.p4
-> /home/adam/tutorials/exercises/firewall/build/basic.json  13922 B  sha256[:16]=2e2eaaa92bbc95f7  warnings=0

== plan ================================================================
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
program  : /home/adam/tutorials/exercises/firewall/solution/firewall.p4 -> build/firewall.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : iperf h1->h3 (both arms); iperf h3->h1 (skeleton connects, solution does not)
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/firewall --topology pod-topo/topology.json --p4 basic.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
  NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/firewall --topology pod-topo/topology.json --p4 basic.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
package 'firewall' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
  control plane : ndtwin
  pipelines     : s1=build/firewall.json, s2=build/basic.json, s3=build/basic.json, s4=build/basic.json
  model         : 4 switches, 4 hosts, 16 edges (8 links, both directions stored)
  files         : 12
                  basic.p4
                  build/basic.json
                  build/basic.p4.p4info.txtpb
                  build/firewall.json
                  build/firewall.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  pod-topo/s1-runtime.json
                  pod-topo/s2-runtime.json
                  pod-topo/s3-runtime.json
                  pod-topo/s4-runtime.json
                  pod-topo/topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
  PASS  format                            1
  INFO  name                              firewall
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
  INFO  s1 pipeline                       build/firewall.json  p4info sha256:ef7561c073ee3b7f  program=/home/adam/tutorials/exercises/firewall/solution/firewall.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              28 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                       none declared (no multicast group, no clone session)
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:fb533999024a5580  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise firewall/solution on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by orch-0926 for 45m (drive_exercise firewall/solution on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
  PASS  format                            1
  INFO  name                              firewall
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
  INFO  s1 pipeline                       build/firewall.json  p4info sha256:ef7561c073ee3b7f  program=/home/adam/tutorials/exercises/firewall/solution/firewall.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              28 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  INFO  roles suggestion                  no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE 
... [trimmed; 6461 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=ef7561c073ee3b7f  entries recorded=13 applied=13 failed=0 api_writes=0  (entries_recorded=13)
   s2  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
   s3  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
   s4  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 00:32:38)
  note           in use: ndt up p4 4 at 2026-09-26 23:47:38 by orch-0926
  prev claim     orch-0926 (until 00:31:21), superseded 2026-09-26 23:47:37  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-26 23:47:37; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           cafd518a  +88 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 23:47:38)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/firewall-solution/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-solution (mode ndtwin)
                 firewall -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 3884641, 4 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  heartbeat      running (pid 3884766, session 732bb1a56f923c48) -- 8 direction(s), report 3.7 s old
  pidfiles       kernel.child.pid=3884904 alive,kernel.pid=3884899 alive,p4_proxy.child.pid=3884811 alive,p4_proxy.pid=3884806 alive

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
  a
... [trimmed; 3618 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3, h4=10.0.4.4
$ every ordered host pair: ping -c 5 -W 2, loss parsed from ping's summary
-> pingall 0% (12/12 pairs at 0%, 0 lossy)
$ h3: iperf -s   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T154737Z_firewall_solution_ndtwin/driver-iperf-h1-to-h3.log)
$ h1: iperf -c 10.0.3.3 -t 3
client:
------------------------------------------------------------
Client connecting to 10.0.3.3, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.1.1 port 56398 connected with 10.0.3.3 port 5001 (icwnd/mss/irtt=14/1448/842)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0258 sec   290 MBytes   803 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.3.3 port 5001 connected with 10.0.1.1 port 56398 (icwnd/mss/irtt=14/1448/556)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0133 sec   290 MBytes   806 Mbits/sec


   PASS iperf h1 -> h3 (internal -> external)          want=connects               got=connects
$ h1: iperf -s   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T154737Z_firewall_solution_ndtwin/driver-iperf-h3-to-h1.log)
$ h3: iperf -c 10.0.1.1 -t 3
client:
------------------------------------------------------------
Client connecting to 10.0.1.1, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
tcp connect failed: Connection timed out
[  1] local 0.0.0.0 port 0 connected with 10.0.1.1 port 5001

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------

(client killed after 25s)
   PASS iperf h3 -> h1 is blocked                      want=no transfer            got=no transfer
   PASS the fabric still forwards (pingall)            want=0.0%                   got=0% (12/12 pairs at 0%, 0 lossy)

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T154737Z_firewall_solution_ndtwin/driver-iperf-h1-to-h3.log 386 B
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T154737Z_firewall_solution_ndtwin/driver-iperf-h3-to-h1.log 194 B

== G1  link usage follows the iperf path (program-independent) =========
   firewall/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   firewall/solution: at 8s that is only 5.21 expected samples per primary link
   firewall/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   firewall/solution: h1 -> h4 (10.0.4.4), iperf -u -b 2M -t 16 -l 1200
   firewall/solution: primary=s1-eth4 s2-eth2 s4-eth1   minor=
   firewall/solution: on-path  s1-eth4  31145074.250 bit  (switch)  [primary, 4345938 B]
   firewall/solution: on-path  s2-eth2  52123753.750 bit  (host)  [primary, 4345758 B]
   firewall/solution: on-path  s4-eth1  30511195.500 bit  (switch)  [primary, 4345938 B]
   firewall/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   firewall/solution: off-path s1-eth1  0.000 bit  (host)
   firewall/solution: off-path s1-eth2  0.000 bit  (host)
   firewall/solution: off-path s1-eth3  0.000 bit  (switch)
   firewall/solution: off-path s2-eth1  0.000 bit  (host)
   firewall/solution: off-path s2-eth3  0.000 bit  (switch)
   firewall/solution: off-path s2-eth4  0.000 bit  (switch)
   firewall/solution: off-path s3-eth1  0.000 bit  (switch)
   firewall/solution: off-path s3-eth2  0.000 bit  (switch)
   firewall/solution: off-path s4-eth2  0.000 bit  (switch)
   firewall/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE firewall/solution expect=follows primary=3 minor=0 rc=0

== teardown: ndt down, the two knobs, then ndt release =================
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
  this teardown is about:
        4 bmv2 switch(es)
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
        -> an orphan holding one makes the next fabric fail to bind, with an error that reads like a P4 pipeline problem rather than a leftover process
        :30054 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9091 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9092 is still listening, held 
... [trimmed; 6339 chars total]
   ndt down rc=0
   host_count_override: unchanged (2 bytes)
   telemetry_override: unchanged (absent)
$ NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS iperf h1 -> h3 (internal -> external)          want=connects               got=connects   【README 宣稱】＋【源碼推導，未執行】
   PASS iperf h3 -> h1 is blocked                      want=no transfer            got=no transfer   【README 宣稱】＋【源碼推導，未執行】
   PASS the fabric still forwards (pingall)            want=0.0%                   got=0% (12/12 pairs at 0%, 0 lossy)   【源碼推導，未執行】
   PASS G1  link usage follows the iperf path          want=primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger got=PASS   【源碼推導，未執行】

>>> PASS (4/4)
```

### stderr（mininet 的 logger 走這裡）

```

```
