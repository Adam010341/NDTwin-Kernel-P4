# 執行報告 — `firewall` / skeleton

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-18T162142Z |
| exercise | `firewall` |
| which | `skeleton` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton` |
| cwd | `/home/adam/tutorials/exercises/firewall` |
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
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/firewall/build/firewall.p4.p4info.txtpb -o /home/adam/tutorials/exercises/firewall/build/firewall.json /home/adam/tutorials/exercises/firewall/firewall.p4
rc=0  warnings=4
/home/adam/tutorials/exercises/firewall/firewall.p4(126): [--Wwarn=unused] warning: 'bloom_filter_1' is unused
    register<bit<1>>(4096) bloom_filter_1;
                           ^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/firewall/firewall.p4(127): [--Wwarn=unused] warning: 'bloom_filter_2' is unused
    register<bit<1>>(4096) bloom_filter_2;
                           ^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/firewall/firewall.p4(129): [--Wwarn=unused] warning: 'reg_val_one' is unused
    bit<1> reg_val_one; bit<1> reg_val_two;
           ^^^^^^^^^^^
/home/adam/tutorials/exercises/firewall/firewall.p4(129): [--Wwarn=unused] warning: 'reg_val_two' is unused
    bit<1> reg_val_one; bit<1> reg_val_two;
                               ^^^^^^^^^^^
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/firewall/build/firewall.json` | 40000 | `08afd28735ada9af` |
| `/home/adam/tutorials/exercises/firewall/build/firewall.p4.p4info.txtpb` | 2103 | `ef7561c073ee3b7f` |

來源 `.p4`：`/home/adam/tutorials/exercises/firewall/firewall.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

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
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
s1  ndtwin=False p4info_sha256=ef7561c073ee3b7f  entries recorded=13 applied=13 failed=0 api_writes=0  (entries_recorded=13)
s2  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
s3  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
s4  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/firewall --topology pod-topo/topology.json --p4 basic.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
```

```
package 'firewall' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
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
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
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
  INFO  s1 pipeline                       build/firewall.json  p4info sha256:ef7561c073ee3b7f  program=/home/adam/tutorials/exercises/firewall/firewall.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              28 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:bdb6a91af5c43db7  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
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
  INFO  s1 pipeline                       build/firewall.json  p4info sha256:ef7561c073ee3b7f  program=/home/adam/tutorials/exercises/firewall/firewall.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              28 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:bdb6a91af5c43db7  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/firewall-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton (mode ndtwin, 4 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton   (p4_proxy/mininet/app_package_override)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 4 switches and the manifest
  ok  4 switches up after 4s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 740421) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 741085) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- the package's own program runs on dpid
  !!    1,2,3,4; the proxy says it sent no LLDP and installed no routes on this
  !!    fabric (control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery)
  ok  table entries: 28/28 applied across 4 switch(es) (they do not all carry the same count), 0 failed
  ok  kernel: 4 switches, 4 up, 16 edges, 4 hosts
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces all agree)
  ok  data plane: h1 -> 10.0.2.2 forwards

up. ready
  proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo
  !!  package pipeline: NDTwin discovered no links and installed no routes on this
  !!    fabric; forwarding is whatever the package's 28 entries on
  !!    4 switch(es) make of it. ndt status quotes no sample rate for it.
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1789748507.6612897,
  "boot_id": "6148f61468124051a8a5e91b76c27bca",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton",
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
      "entries_recorded": 13,
      "grpc_addr": "localhost:30051",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789748508.773458,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton/build/firewall.p4.p4info.txtpb",
        "p4info_sha256": "ef7561c073ee3b7f",
        "skipped": [
          "clone_session",
          "sflow_telemetry"
        ]
      },
      "pipeline_commits": 1,
      "probe_age_s": 1.834,
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
      "table_generation": "347f7ce2183e4d6e97716150ab19f7fa"
    },
    "2": {
      "entries_recorded": 5,
      "grpc_addr": "localhost:30052",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789748508.7799392,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton/build/basic.p4.p4info.txtpb",
        "p4info_sha256": "9213871cee36bd93",
        "skipped": [
          "clone_session",
          "sflow_telemetry"
        ]
      },
      "pipeline_commits": 1,
      "probe_age_s": 1.833,
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
      "table_generation": "61764bb7ce5841a8833bb8b8a800da75"
    },
    "3": {
      "entries_recorded": 5,
      "grpc_addr": "localhost:30053",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789748508.7830398,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton/build/basic.p4.p4info.txtpb",
        "p4info_sha256": "9213871cee36bd93",
        "skipped": [
          "clone_session",
          "sflow_telemetry"
        ]
      },
      "pipeline_commits": 1,
      "probe_age_s": 1.833,
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
      "table_generation": "febaabf77619445f9d3628922454cb93"
    },
    "4": {
      "entries_recorded": 5,
      "grpc_addr": "localhost:30054",
      "last_lldp_age_s": null,
      "last_packet_in_age_s": null,
      "oldest_rule_installed_at": 1789748508.7861018,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton/build/basic.p4.p4info.txtpb",
        "p4info_sha256": "9213871cee36bd93",
        "skipped": [
          "clone_session",
          "sflow_telemetry"
        ]
      },
      "pipeline_commits": 1,
      "probe_age_s": 1.829,
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
      "table_generation": "43ea75140b6e40ceb0402144fcbecb80"
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
  claim          yours -- 45m left (until 01:06:43)
  note           in use: ndt up p4 4 at 2026-09-19 00:21:43 by 9-18-orchestrator
  prev claim     9-18-orchestrator (until 01:06:10), superseded 2026-09-19 00:21:41  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-19 00:21:41; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           8eddb0e8  +41 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 00:21:43)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/firewall-skeleton/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton (mode ndtwin)
                 firewall -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=741090 alive,kernel.pid=741085 alive,p4_proxy.child.pid=740426 alive,p4_proxy.pid=740421 alive

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
  asked for      p4, 4 hosts   (recorded 2026-09-19 00:21:43 by 9-18-orchestrator)
  topology       .test_run/packages/firewall-skeleton/ndtwin/topology.json   (declares 4 hosts / 16 edges)
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
[  1] local 10.0.1.1 port 37580 connected with 10.0.3.3 port 5001 (icwnd/mss/irtt=14/1448/709)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0088 sec   291 MBytes   812 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.3.3 port 5001 connected with 10.0.1.1 port 37580 (icwnd/mss/irtt=14/1448/441)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0087 sec   291 MBytes   812 Mbits/sec
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
[  1] local 10.0.3.3 port 47104 connected with 10.0.1.1 port 5001 (icwnd/mss/irtt=14/1448/646)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0091 sec   281 MBytes   784 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.1.1 port 5001 connected with 10.0.3.3 port 47104 (icwnd/mss/irtt=14/1448/405)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0073 sec   281 MBytes   784 Mbits/sec
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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton -- this checkout is being put back
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000

clean
  ok  the 8 port(s) [1/3] called 'still listening' were closed by [3/3]: 909
... [trimmed; 6283 chars total]
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
| PASS | iperf h1 -> h3 (internal -> external) | 【README 宣稱】＋【源碼推導，未執行】 | `connects` | `connects` | README step 1.2; firewall.p4 ipv4_lpm forwards in both arms |
| PASS | RED ARM: iperf h3 -> h1 must connect | 【README 宣稱】＋【源碼推導，未執行】 | `connects` | `connects` | README step 1.2: with the firewall unimplemented h3 -> h1 works. If this is red the solution's block proves nothing -- the red arm is not red. |
| PASS | the fabric forwards (pingall) | 【源碼推導，未執行】 | `0.0%` | `0% (12/12 pairs at 0%, 0 lossy)` | the skeleton is basic.p4 plus unfilled TODOs; nothing in it drops ICMP |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T162142Z_firewall_skeleton_ndtwin/driver-iperf-h1-to-h3.log`
- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T162142Z_firewall_skeleton_ndtwin/driver-iperf-h3-to-h1.log`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- firewall / skeleton
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
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/firewall/build/firewall.p4.p4info.txtpb -o /home/adam/tutorials/exercises/firewall/build/firewall.json /home/adam/tutorials/exercises/firewall/firewall.p4
/home/adam/tutorials/exercises/firewall/firewall.p4(126): [--Wwarn=unused] warning: 'bloom_filter_1' is unused
    register<bit<1>>(4096) bloom_filter_1;
                           ^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/firewall/firewall.p4(127): [--Wwarn=unused] warning: 'bloom_filter_2' is unused
    register<bit<1>>(4096) bloom_filter_2;
                           ^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/firewall/firewall.p4(129): [--Wwarn=unused] warning: 'reg_val_one' is unused
    bit<1> reg_val_one; bit<1> reg_val_two;
           ^^^^^^^^^^^
/home/adam/tutorials/exercises/firewall/firewall.p4(129): [--Wwarn=unused] warning: 'reg_val_two' is unused
    bit<1> reg_val_one; bit<1> reg_val_two;
                               ^^^^^^^^^^^
-> /home/adam/tutorials/exercises/firewall/build/firewall.json  40000 B  sha256[:16]=08afd28735ada9af  warnings=4

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/firewall/build/basic.p4.p4info.txtpb -o /home/adam/tutorials/exercises/firewall/build/basic.json /home/adam/tutorials/exercises/firewall/basic.p4
-> /home/adam/tutorials/exercises/firewall/build/basic.json  13922 B  sha256[:16]=2e2eaaa92bbc95f7  warnings=0

== plan ================================================================
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
program  : /home/adam/tutorials/exercises/firewall/firewall.p4 -> build/firewall.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : iperf h1->h3 (both arms); iperf h3->h1 (skeleton connects, solution does not)
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/firewall --topology pod-topo/topology.json --p4 basic.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
  NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
  ... the scripted steps above, then `ndt down` and `ndt release`.

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/firewall --topology pod-topo/topology.json --p4 basic.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
package 'firewall' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
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
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
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
  INFO  s1 pipeline                       build/firewall.json  p4info sha256:ef7561c073ee3b7f  program=/home/adam/tutorials/exercises/firewall/firewall.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              28 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:bdb6a91af5c43db7  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')

== claim the lab =======================================================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise firewall/skeleton on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by 9-18-orchestrator for 45m (drive_exercise firewall/skeleton on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
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
  INFO  s1 pipeline                       build/firewall.json  p4info sha256:ef7561c073ee3b7f  program=/home/adam/tutorials/exercises/firewall/firewall.p4
  INFO  s2 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s3 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  INFO  s4 pipeline                       build/basic.json  p4info sha256:9213871cee36bd93  program=/home/adam/tutorials/exercises/firewall/basic.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              28 entries across 4 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  4 switch(es); entries and pipeline name the same p4info
  PASS  gRPC port block                   30051-30054 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  basic.json sha256:bdb6a91af5c43db7  basic.p4.p4info.txtpb sha256:9213871cee36bd93

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/firewall-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton (mode ndtwin, 4 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  app package set: /home/adam/Desktop/NDTwin-Kern
... [trimmed; 4703 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=ef7561c073ee3b7f  entries recorded=13 applied=13 failed=0 api_writes=0  (entries_recorded=13)
   s2  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
   s3  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)
   s4  ndtwin=False p4info_sha256=9213871cee36bd93  entries recorded=5 applied=5 failed=0 api_writes=0  (entries_recorded=5)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 01:06:43)
  note           in use: ndt up p4 4 at 2026-09-19 00:21:43 by 9-18-orchestrator
  prev claim     9-18-orchestrator (until 01:06:10), superseded 2026-09-19 00:21:41  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-19 00:21:41; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           8eddb0e8  +41 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 00:21:43)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/firewall-skeleton/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/firewall-skeleton (mode ndtwin)
                 firewall -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3,4 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  4       topo session   present
  host/switch    8       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=741090 alive,kernel.pid=741085 alive,p4_proxy.child.pid=740426 alive,p4_proxy.pid=740421 alive

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
  asked for      p4, 4 hosts   (recorded 2026-09-19 00:21:43 by 9-18-orchestrator)
  topology       .test_run/packages/firewall-skeleton/ndtwin/topology.json   (declares 4 hosts / 16 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   4                      == 4   ok
  graph hosts    4                      == 4   ok
  graph 
... [trimmed; 3280 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3, h4=10.0.4.4
$ every ordered host pair: ping -c 5 -W 2, loss parsed from ping's summary
-> pingall 0% (12/12 pairs at 0%, 0 lossy)
$ h3: iperf -s   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T162142Z_firewall_skeleton_ndtwin/driver-iperf-h1-to-h3.log)
$ h1: iperf -c 10.0.3.3 -t 3
client:
------------------------------------------------------------
Client connecting to 10.0.3.3, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.1.1 port 37580 connected with 10.0.3.3 port 5001 (icwnd/mss/irtt=14/1448/709)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0088 sec   291 MBytes   812 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.3.3 port 5001 connected with 10.0.1.1 port 37580 (icwnd/mss/irtt=14/1448/441)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0087 sec   291 MBytes   812 Mbits/sec


   PASS iperf h1 -> h3 (internal -> external)          want=connects               got=connects
$ h1: iperf -s   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T162142Z_firewall_skeleton_ndtwin/driver-iperf-h3-to-h1.log)
$ h3: iperf -c 10.0.1.1 -t 3
client:
------------------------------------------------------------
Client connecting to 10.0.1.1, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.3.3 port 47104 connected with 10.0.1.1 port 5001 (icwnd/mss/irtt=14/1448/646)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0091 sec   281 MBytes   784 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.1.1 port 5001 connected with 10.0.3.3 port 47104 (icwnd/mss/irtt=14/1448/405)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.0073 sec   281 MBytes   784 Mbits/sec


   PASS RED ARM: iperf h3 -> h1 must connect           want=connects               got=connects
   PASS the fabric forwards (pingall)                  want=0.0%                   got=0% (12/12 pairs at 0%, 0 lossy)

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T162142Z_firewall_skeleton_ndtwin/driver-iperf-h1-to-h3.log 386 B
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-09-18T162142Z_firewall_skeleton_ndtwin/driver-iperf-h3-to-h1.log 386 B

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
... [trimmed; 6283 chars total]
   ndt down rc=0
   host_count_override: unchanged (2 bytes)
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS iperf h1 -> h3 (internal -> external)          want=connects               got=connects   【README 宣稱】＋【源碼推導，未執行】
   PASS RED ARM: iperf h3 -> h1 must connect           want=connects               got=connects   【README 宣稱】＋【源碼推導，未執行】
   PASS the fabric forwards (pingall)                  want=0.0%                   got=0% (12/12 pairs at 0%, 0 lossy)   【源碼推導，未執行】

>>> PASS (3/3)
```

### stderr（mininet 的 logger 走這裡）

```

```
