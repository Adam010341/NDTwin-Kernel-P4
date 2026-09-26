# 執行報告 — `p4runtime` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-26T062438Z |
| exercise | `p4runtime` |
| which | `solution` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution` |
| cwd | `/home/adam/tutorials/exercises/p4runtime` |
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
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/p4runtime/build/advanced_tunnel.p4.p4info.txtpb -o /home/adam/tutorials/exercises/p4runtime/build/advanced_tunnel.json /home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
rc=0  warnings=1
/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4(140): [--Wwarn=invalid-header] warning: accessing a field of an invalid header hdr.myTunnel
        egressTunnelCounter.count((bit<32>) hdr.myTunnel.dst_id);
                                            ^^^^^^^^^^^^
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/p4runtime/build/advanced_tunnel.json` | 27957 | `ef1adeee9e769f26` |
| `/home/adam/tutorials/exercises/p4runtime/build/advanced_tunnel.p4.p4info.txtpb` | 2285 | `4d986039017abeef` |

來源 `.p4`：`/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

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
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
control_plane.skipped ['clone_session', 'install_initial_routes', 'link_watchdog', 'lldp_discovery', 'pipeline_push', 'sflow_telemetry']
s1  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
s2  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
s3  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/p4runtime --topology topology.json --p4 advanced_tunnel.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
```

```
package 'p4runtime' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
  control plane : external
  pipelines     : s1=build/advanced_tunnel.json, s2=build/advanced_tunnel.json, s3=build/advanced_tunnel.json
  model         : 3 switches, 3 hosts, 12 edges (6 links, both directions stored)
  files         : 6
                  advanced_tunnel.p4
                  build/advanced_tunnel.json
                  build/advanced_tunnel.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
  PASS  format                       1
  INFO  name                         p4runtime
  PASS  control_plane.mode           external
  PASS  control_plane.grpc_base      30050
  PASS  control_plane.device_id      dpid
  PASS  control_plane.election_id    [0, 65535]
  PASS  bmv2.cpu_port                255
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
  INFO  s1 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  s2 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  s3 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  entries                      none (control plane 'external' brings its own)
  PASS  p4info parses                build/advanced_tunnel.p4.p4info.txtpb: 2 table(s)
  INFO  roles suggestion             no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source             not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                  none declared (no multicast group, no clone session)
  PASS  gRPC port block              30051-30053 safe on this machine
  PASS  p4c-bm2-ss                   rc=0  advanced_tunnel.json sha256:4780831062523f04  advanced_tunnel.p4.p4info.txtpb sha256:4d986039017abeef

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
  PASS  format                       1
  INFO  name                         p4runtime
  PASS  control_plane.mode           external
  PASS  control_plane.grpc_base      30050
  PASS  control_plane.device_id      dpid
  PASS  control_plane.election_id    [0, 65535]
  PASS  bmv2.cpu_port                255
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
  INFO  s1 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  s2 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  s3 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  entries                      none (control plane 'external' brings its own)
  PASS  p4info parses                build/advanced_tunnel.p4.p4info.txtpb: 2 table(s)
  INFO  roles suggestion             no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source             not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                  none declared (no multicast group, no clone session)
  PASS  gRPC port block              30051-30053 safe on this machine
  PASS  p4c-bm2-ss                   rc=0  advanced_tunnel.json sha256:4780831062523f04  advanced_tunnel.p4.p4info.txtpb sha256:4d986039017abeef

PASS -- every check passed

ndt up p4
  hosts        3        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/p4runtime-solution/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution (mode external, 3 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 3 (persistent; affects every later run)
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 3 switches and the manifest
  ok  3 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 1277359) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 1278018) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
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
  !!    forward. Until it runs, every ping between 
... [trimmed; 6019 chars total]
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1790403885.1199994,
  "boot_id": "cc34b2b673a5499895d588404aa6a690",
  "control_plane": {
    "mode": "external",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution",
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
        "pid": 1275725,
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
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution/build/advanced_tunnel.p4.p4info.txtpb",
        "p4info_sha256": "4d986039017abeef",
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
      "probe_age_s": 0.844,
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
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution/build/advanced_tunnel.p4.p4info.txtpb",
        "p4info_sha256": "4d986039017abeef",
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
      "probe_age_s": 0.843,
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
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution/build/advanced_tunnel.p4.p4info.txtpb",
        "p4info_sha256": "4d986039017abeef",
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
      "probe_age_s": 0.841,
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
... [trimmed; 6313 chars total]
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 15:09:38)
  note           in use: ndt up p4 3 at 2026-09-26 14:24:39 by pb5-trial-0926
  prev claim     pb5-trial-0926 (until 15:09:04), superseded 2026-09-26 14:24:37  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-26 14:24:37; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           580767a8  +84 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  3, written by 'ndt up p4 3' at 14:24:39 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          3   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/p4runtime-solution/ndtwin/topology.json
  p4 host knob   3   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution (mode external)
                 p4runtime -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 1275725, 3 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    6       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=1278023 alive,kernel.pid=1278018 alive,p4_proxy.child.pid=1277370 alive,p4_proxy.pid=1277359 alive

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
  asked for      p4, 3 hosts   (recorded 2026-09-26 14:24:39 by pb5-trial-0926)
  topology       .test_run/packages/p4runtime-solution/ndtwin/topology.json   (declares 3 hosts / 12 edges)
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
$ /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/run_external_controller.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution solution/mycontroller.py
```

```
[adapter] tutorials utils : /home/adam/tutorials/utils
[adapter] grpc base       : 30050 (device id = dpid)
[adapter] running          /home/adam/tutorials/exercises/p4runtime/solution/mycontroller.py  (cwd /home/adam/tutorials/exercises/p4runtime)
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
[adapter] s2: 127.0.0.1:50052 device_id=1  ->  localhost:30052 device_id=2
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed ingress tunnel rule on s1
Installed transit tunnel rule on s1
Installed egress tunnel rule on s2
Installed ingress tunnel rule on s2
Installed transit tunnel rule on s2
Installed egress tunnel rule on s1

----- Reading tables rules for s1 -----
MyIngress.ipv4_lpm:  hdr.ipv4.dstAddr (b'\n\x00\x02\x02', 32) -> MyIngress.myTunnel_ingress dst_id b'd' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'd' -> MyIngress.myTunnel_forward port b'\x02' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'\xc8' -> MyIngress.myTunnel_egress dstAddr b'\x08\x00\x00\x00\x01\x11' port b'\x01' 

----- Reading tables rules for s2 -----
MyIngress.ipv4_lpm:  hdr.ipv4.dstAddr (b'\n\x00\x01\x01', 32) -> MyIngress.myTunnel_ingress dst_id b'\xc8' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'd' -> MyIngress.myTunnel_egress dstAddr b'\x08\x00\x00\x00\x02"' port b'\x01' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'\xc8' -> MyIngress.myTunnel_forward port b'\x02' 

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)
```

### 7. P1  h1 ping h2 with the controller running

```
$ ping -c 5 -W 2 10.0.2.2
```

```
PING 10.0.2.2 (10.0.2.2) 56(84) bytes of data.
64 bytes from 10.0.2.2: icmp_seq=1 ttl=64 time=0.768 ms
64 bytes from 10.0.2.2: icmp_seq=2 ttl=64 time=1.37 ms
64 bytes from 10.0.2.2: icmp_seq=3 ttl=64 time=1.56 ms
64 bytes from 10.0.2.2: icmp_seq=4 ttl=64 time=1.46 ms
64 bytes from 10.0.2.2: icmp_seq=5 ttl=64 time=1.25 ms

--- 10.0.2.2 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4025ms
rtt min/avg/max/mdev = 0.768/1.280/1.556/0.275 ms
```

### 8. N8  G1 link usage follows the iperf path

```
$ live-p1/_common.sh link_usage_round /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution (to h2)
```

```
   p4runtime/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   p4runtime/solution: at 8s that is only 5.21 expected samples per primary link
   p4runtime/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   p4runtime/solution: h1 -> h2 (10.0.2.2), iperf -u -b 2M -t 16 -l 1200
   p4runtime/solution: primary=s1-eth2 s2-eth1   minor=
   p4runtime/solution: on-path  s1-eth2  27427792.000 bit  (switch)  [primary, 4359824 B]
   p4runtime/solution: on-path  s2-eth1  27975993.000 bit  (host)  [primary, 4346031 B]
   p4runtime/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   p4runtime/solution: off-path s1-eth1  0.000 bit  (host)
   p4runtime/solution: off-path s1-eth3  0.000 bit  (switch)
   p4runtime/solution: off-path s2-eth2  0.000 bit  (switch)
   p4runtime/solution: off-path s2-eth3  0.000 bit  (switch)
   p4runtime/solution: off-path s3-eth1  0.000 bit  (host)
   p4runtime/solution: off-path s3-eth2  0.000 bit  (switch)
   p4runtime/solution: off-path s3-eth3  0.000 bit  (switch)
   p4runtime/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE p4runtime/solution expect=follows primary=2 minor=0 rc=0
```

### 9. P9  controller log after the round

```
$ /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T062438Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log
```

```
[adapter] tutorials utils : /home/adam/tutorials/utils
[adapter] grpc base       : 30050 (device id = dpid)
[adapter] running          /home/adam/tutorials/exercises/p4runtime/solution/mycontroller.py  (cwd /home/adam/tutorials/exercises/p4runtime)
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
[adapter] s2: 127.0.0.1:50052 device_id=1  ->  localhost:30052 device_id=2
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed ingress tunnel rule on s1
Installed transit tunnel rule on s1
Installed egress tunnel rule on s2
Installed ingress tunnel rule on s2
Installed transit tunnel rule on s2
Installed egress tunnel rule on s1

----- Reading tables rules for s1 -----
MyIngress.ipv4_lpm:  hdr.ipv4.dstAddr (b'\n\x00\x02\x02', 32) -> MyIngress.myTunnel_ingress dst_id b'd' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'd' -> MyIngress.myTunnel_forward port b'\x02' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'\xc8' -> MyIngress.myTunnel_egress dstAddr b'\x08\x00\x00\x00\x01\x11' port b'\x01' 

----- Reading tables rules for s2 -----
MyIngress.ipv4_lpm:  hdr.ipv4.dstAddr (b'\n\x00\x01\x01', 32) -> MyIngress.myTunnel_ingress dst_id b'\xc8' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'd' -> MyIngress.myTunnel_egress dstAddr b'\x08\x00\x00\x00\x02"' port b'\x01' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'\xc8' -> MyIngress.myTunnel_forward port b'\x02' 

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 1 packets (98 bytes)
s2 MyIngress.egressTunnelCounter 100: 1 packets (102 bytes)
s2 MyIngress.ingressTunnelCounter 200: 1 packets (98 bytes)
s1 MyIngress.egressTunnelCounter 200: 1 packets (102 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 3 packets (294 bytes)
s2 MyIngress.egressTunnelCounter 100: 3 packets (306 bytes)
s2 MyIngress.ingressTunnelCounter 200: 3 packets (294 bytes)
s1 MyIngress.egressTunnelCounter 200: 3 packets (306 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 5 packets (490 bytes)
s2 MyIngress.egressTunnelCounter 100: 5 packets (510 bytes)
s2 MyIngress.ingressTunnelCounter 200: 5 packets (490 bytes)
s1 MyIngress.egressTunnelCounter 200: 5 packets (510 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 195 packets (236470 bytes)
s2 MyIngress.egressTunnelCounter 100: 195 packets (237250 bytes)
s2 MyIngress.ingressTunnelCounter 200: 5 packets (490 bytes)
s1 MyIngress.egressTunnelCounter 200: 5 packets (510 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 632 packets (779224 bytes)
s2 MyIngress.egressTunnelCounter 100: 632 packets (781752 bytes)
s2 MyIngress.ingressTunnelCounter 200: 5 packets (490 bytes)
s1 MyIngress.egressTunnelCounter 200: 5 packets (510 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 1070 packets (1323220 bytes)
s2 MyIngress.egressTunnelCounter 100: 1070 packets (1327500 bytes)
s2 MyIngress.ingressTunnelCounter 200: 5 packets (490 bytes)
s1 MyIngress.egressTunnelCounter 200: 5 packets (510 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 1507 packets (1865974 bytes)
s2 MyIngress.egressTunnelCounter 100: 1508 packets (1873248 bytes)
s2 MyIngress.ingressTunnelCounter 200: 5 packets (490 bytes)
s1 MyIngress.egressTunnelCounter 200: 5 packets (510 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 1945 packets (2409970 bytes)
s2 MyIngress.egressTunnelCounter 100: 1945 packets (2417750 bytes)
s2 MyIngress.ingressTunnelCounter 200: 5 packets (490 bytes)
s1 MyIngress.egressTunnelCounter 200: 5 packets (510 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 2383 packets (2953966 bytes)
s2 MyIngress.egressTunnelCounter 100: 2383 packets (2963498 bytes)
s2 MyIngress.ingressTunnelCounter 200: 5 packets (490 bytes)
s1 MyIngress.egressTunnelCounter 200: 5 packets (510 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 2820 packets (3496720 bytes)
s2 MyIngress.egressTunnelCounter 100: 2821 packets (3509246 bytes)
s2 MyIngress.ingressTunnelCounter 200: 5 packets (490 bytes)
s1 MyIngress.egressTunnelCounter 200: 5 packets (510 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 3258 packets (4040716 bytes)
s2 MyIngress.egressTunnelCounter 100: 3258 packets (4053748 bytes)
s2 MyIngress.ingressTunnelCounter 200: 5 packets (490 bytes)
s1 MyIngress.egressTunnelCounter 200: 5 packets
... [trimmed; 6306 chars total]
```

### 10. N9  ndt down

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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution -- this checkout is being put back
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
| PASS | injection: the controller stayed up | 【源碼推導，未執行】 | `alive after 12s` | `alive` | mycontroller.py:205-212 exits 1 when build/ is missing; a dead controller makes every claim below vacuous |
| PASS | switches the controller programmed | 【源碼推導，未執行】 | `[1, 2]` | `[1, 2]` | mycontroller.py:142-152 connects to s1 and s2 only; s3 is never contacted, which live-p1/03 asserts on the twin's side too |
| PASS | the transit rule went in | 【源碼推導，未執行】 | `Installed transit tunnel rule` | `installed` | solution/mycontroller.py:85 |
| PASS | h1 -> h2 forwards through the tunnel | 【README 宣稱】＋【源碼推導，未執行】 | `0.0%` | `0% loss, 5/5 received` | README step 3: 'You should start to see ICMP replies' |
| PASS | G1  link usage follows the iperf path | 【源碼推導，未執行】 | `primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger` | `PASS` | TICKET-P3 §2.7's program-independent cell, through live-p1/_common.sh's link_usage_round -- the same function live-p1/05 runs. The floor and every off-path edge's raw integral are in that transcript. |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T062438Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T062438Z_p4runtime_solution_ndtwin/link_usage`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- p4runtime / solution
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/p4runtime

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/p4runtime/build/advanced_tunnel.p4.p4info.txtpb -o /home/adam/tutorials/exercises/p4runtime/build/advanced_tunnel.json /home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4(140): [--Wwarn=invalid-header] warning: accessing a field of an invalid header hdr.myTunnel
        egressTunnelCounter.count((bit<32>) hdr.myTunnel.dst_id);
                                            ^^^^^^^^^^^^
-> /home/adam/tutorials/exercises/p4runtime/build/advanced_tunnel.json  27957 B  sha256[:16]=ef1adeee9e769f26  warnings=1

== plan ================================================================
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
program  : /home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4 -> build/advanced_tunnel.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : run the exercise's controller; h1 ping h2; assert the transit rule and the ping
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/p4runtime --topology topology.json --p4 advanced_tunnel.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
  NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/p4runtime --topology topology.json --p4 advanced_tunnel.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
package 'p4runtime' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
  control plane : external
  pipelines     : s1=build/advanced_tunnel.json, s2=build/advanced_tunnel.json, s3=build/advanced_tunnel.json
  model         : 3 switches, 3 hosts, 12 edges (6 links, both directions stored)
  files         : 6
                  advanced_tunnel.p4
                  build/advanced_tunnel.json
                  build/advanced_tunnel.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
  PASS  format                       1
  INFO  name                         p4runtime
  PASS  control_plane.mode           external
  PASS  control_plane.grpc_base      30050
  PASS  control_plane.device_id      dpid
  PASS  control_plane.election_id    [0, 65535]
  PASS  bmv2.cpu_port                255
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
  INFO  s1 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  s2 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  s3 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  entries                      none (control plane 'external' brings its own)
  PASS  p4info parses                build/advanced_tunnel.p4.p4info.txtpb: 2 table(s)
  INFO  roles suggestion             no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source             not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                  none declared (no multicast group, no clone session)
  PASS  gRPC port block              30051-30053 safe on this machine
  PASS  p4c-bm2-ss                   rc=0  advanced_tunnel.json sha256:4780831062523f04  advanced_tunnel.p4.p4info.txtpb sha256:4d986039017abeef

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise p4runtime/solution on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by pb5-trial-0926 for 45m (drive_exercise p4runtime/solution on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
  PASS  format                       1
  INFO  name                         p4runtime
  PASS  control_plane.mode           external
  PASS  control_plane.grpc_base      30050
  PASS  control_plane.device_id      dpid
  PASS  control_plane.election_id    [0, 65535]
  PASS  bmv2.cpu_port                255
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
  INFO  s1 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  s2 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  s3 pipeline                  build/advanced_tunnel.json  p4info sha256:4d986039017abeef  program=/home/adam/tutorials/exercises/p4runtime/advanced_tunnel.p4
  INFO  entries                      none (control plane 'external' brings its own)
  PASS  p4info parses                build/advanced_tunnel.p4.p4info.txtpb: 2 table(s)
  INFO  roles suggestion             no roles declared, so NDTwin writes none of this program's tables. Its p4info has a destination-route-shaped table on every switch; to let NDTwin route here, add to package.json: "roles": {"ipv4_route": {"owner": "ndtwin", "table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr", "action": "MyIngress.ipv4_forward", "params": {"dst_mac": "dstAddr", "port": "port"}}} (owner ndtwin: NDTwin writes that table and the package's own entries for it must go -- convert.py --role-ipv4-route takes them out; owner package: NDTwin only reads it)
  INFO  telemetry.source             not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  INFO  PRE entries                  none declared (no multicast group, no clone session)
  PASS  gRPC port block              30051-30053 safe on this machine
  PASS  p4c-bm2-ss                   rc=0  advanced_tunnel.json sha256:4780831062523f04  advanced_tunnel.p4.p4info.txtpb sha256:4d986039017abeef

PASS -- every check passed

ndt up p4
  hosts        3        (p4
... [trimmed; 6019 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    external
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution
   control_plane.skipped ['clone_session', 'install_initial_routes', 'link_watchdog', 'lldp_discovery', 'pipeline_push', 'sflow_telemetry']
   s1  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
   s2  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
   s3  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 15:09:38)
  note           in use: ndt up p4 3 at 2026-09-26 14:24:39 by pb5-trial-0926
  prev claim     pb5-trial-0926 (until 15:09:04), superseded 2026-09-26 14:24:37  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-26 14:24:37; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           580767a8  +84 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  3, written by 'ndt up p4 3' at 14:24:39 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          3   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/p4runtime-solution/ndtwin/topology.json
  p4 host knob   3   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution (mode external)
                 p4runtime -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 1275725, 3 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    6       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=1278023 alive,kernel.pid=1278018 alive,p4_proxy.child.pid=1277370 alive,p4_proxy.pid=1277359 alive

network health
  switches       0 up, 0 enabled, 0 admin-disabled
  links          12 total, 6 down, 0 admin-disabled
                 up/enabled above is a READING, not a verdict: an external package loads no 
... [trimmed; 3984 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3
$ /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/run_external_controller.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-solution solution/mycontroller.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T062438Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log)
   controller pid 1278782 (handed to the generic cell; stopped after it)
-- controller log (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T062438Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log) --
[adapter] tutorials utils : /home/adam/tutorials/utils
[adapter] grpc base       : 30050 (device id = dpid)
[adapter] running          /home/adam/tutorials/exercises/p4runtime/solution/mycontroller.py  (cwd /home/adam/tutorials/exercises/p4runtime)
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
[adapter] s2: 127.0.0.1:50052 device_id=1  ->  localhost:30052 device_id=2
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed ingress tunnel rule on s1
Installed transit tunnel rule on s1
Installed egress tunnel rule on s2
Installed ingress tunnel rule on s2
Installed transit tunnel rule on s2
Installed egress tunnel rule on s1

----- Reading tables rules for s1 -----
MyIngress.ipv4_lpm:  hdr.ipv4.dstAddr (b'\n\x00\x02\x02', 32) -> MyIngress.myTunnel_ingress dst_id b'd' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'd' -> MyIngress.myTunnel_forward port b'\x02' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'\xc8' -> MyIngress.myTunnel_egress dstAddr b'\x08\x00\x00\x00\x01\x11' port b'\x01' 

----- Reading tables rules for s2 -----
MyIngress.ipv4_lpm:  hdr.ipv4.dstAddr (b'\n\x00\x01\x01', 32) -> MyIngress.myTunnel_ingress dst_id b'\xc8' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'd' -> MyIngress.myTunnel_egress dstAddr b'\x08\x00\x00\x00\x02"' port b'\x01' 
MyIngress.myTunnel_exact:  hdr.myTunnel.dst_id b'\xc8' -> MyIngress.myTunnel_forward port b'\x02' 

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

   PASS injection: the controller stayed up            want=alive after 12s        got=alive
   PASS switches the controller programmed             want=[1, 2]                 got=[1, 2]
$ h1: ping -c5 10.0.2.2 -> 0% loss, 5/5 received
   PASS the transit rule went in                       want=Installed transit tunnel rule got=installed
   PASS h1 -> h2 forwards through the tunnel           want=0.0%                   got=0% loss, 5/5 received

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-26T062438Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log 3398 B

== G1  link usage follows the iperf path (program-independent) =========
   p4runtime/solution: slowest declared link = 1000000000 bit/s; iperf offers 2000000 bit/s; a link therefore carries at most 2000000 bit/s
   p4runtime/solution: at 8s that is only 5.21 expected samples per primary link
   p4runtime/solution: window = max(8, ceil(10 x 256 x 1500 x 8 / 2000000)) = 16s
   p4runtime/solution: h1 -> h2 (10.0.2.2), iperf -u -b 2M -t 16 -l 1200
   p4runtime/solution: primary=s1-eth2 s2-eth1   minor=
   p4runtime/solution: on-path  s1-eth2  27427792.000 bit  (switch)  [primary, 4359824 B]
   p4runtime/solution: on-path  s2-eth1  27975993.000 bit  (host)  [primary, 4346031 B]
   p4runtime/solution: off-path floor 3072000.000 bit   = max(ONE SAMPLE = 256 x 1500 x 8 = 3072000 bit, 0.02 x the smallest PRIMARY on-path integral)
   p4runtime/solution: off-path s1-eth1  0.000 bit  (host)
   p4runtime/solution: off-path s1-eth3  0.000 bit  (switch)
   p4runtime/solution: off-path s2-eth2  0.000 bit  (switch)
   p4runtime/solution: off-path s2-eth3  0.000 bit  (switch)
   p4runtime/solution: off-path s3-eth1  0.000 bit  (host)
   p4runtime/solution: off-path s3-eth2  0.000 bit  (switch)
   p4runtime/solution: off-path s3-eth3  0.000 bit  (switch)
   p4runtime/solution: link usage follows the iperf path (off-path under 3072000.000 bit)
LINK_USAGE p4runtime/solution expect=follows primary=2 minor=0 rc=0

== teardown: ndt down, the two knobs, then ndt release =================
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
  this teardown is about:
        3 bmv2 switch(es)
        6 host/switch process(es)
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
... [trimmed; 5377 chars total]
   ndt down rc=0
   host_count_override: put back to the 2 bytes this round found
   telemetry_override: unchanged (absent)
$ NDT_OWNER=pb5-trial-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: the controller stayed up            want=alive after 12s        got=alive   【源碼推導，未執行】
   PASS switches the controller programmed             want=[1, 2]                 got=[1, 2]   【源碼推導，未執行】
   PASS the transit rule went in                       want=Installed transit tunnel rule got=installed   【源碼推導，未執行】
   PASS h1 -> h2 forwards through the tunnel           want=0.0%                   got=0% loss, 5/5 received   【README 宣稱】＋【源碼推導，未執行】
   PASS G1  link usage follows the iperf path          want=primary on-path > 0; minor rows printed, not asserted; off-path under one sample's worth (256 x MTU x 8 bit) or 2% of the smallest PRIMARY on-path, whichever is larger got=PASS   【源碼推導，未執行】

>>> PASS (5/5)
```

### stderr（mininet 的 logger 走這裡）

```

```
