# 執行報告 — `p4runtime` / skeleton

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-10-02T123948Z |
| exercise | `p4runtime` |
| which | `skeleton` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton` |
| cwd | `/home/adam/tutorials/exercises/p4runtime` |
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
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
control_plane.skipped ['clone_session', 'install_initial_routes', 'lldp_discovery', 'pipeline_push', 'sflow_telemetry']
s1  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
s2  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
s3  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/p4runtime --topology topology.json --p4 advanced_tunnel.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
```

```
package 'p4runtime' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
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
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
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
  PASS  p4c-bm2-ss                   rc=0  advanced_tunnel.json sha256:ae78ff95657b571e  advanced_tunnel.p4.p4info.txtpb sha256:4d986039017abeef

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
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
  PASS  p4c-bm2-ss                   rc=0  advanced_tunnel.json sha256:ae78ff95657b571e  advanced_tunnel.p4.p4info.txtpb sha256:4d986039017abeef

PASS -- every check passed

  ok  heartbeat drop check: every program drops its frame (advanced_tunnel.json checked) -- the declared program's default actions only; entries, a pipeline or a default action its controller sets later are not covered (.test_run/logs/heartbeat_drop_check.20261002T123949Z.943817.log)
ndt up p4
  hosts        3        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/p4runtime-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton (mode external, 3 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 3 (persistent; affects every later run)
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 3 switches and the manifest
  ok  3 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
      heartbeat plan: /tmp/ndtwin_p4_switches.json (sha256 ee1d51639a4a), 3 switch(es), every one a live bmv2
        link s1-eth2 (dpid 1 port 2) <-> s2-eth2 (dpid 2 port 2)
        link s1-eth3 (dpid 1 port 3) <-> s3-eth2 (dpid 3 port 2)
        link s2-eth3 (dpid 2 port 3) <-> s3-eth3 (dpid 3 port 3)
        3 link(s) -> 6 direction(s); 3 host-facing interface(s) listened on, never sent on
      heartbeat started (pid 944535; report: /run/ndtwin-lab/heartbeat.json, log: /run/ndtwin-lab/heartbeat.log)
  ok  heartbeat running on the inter-switch veths, detect only: a cut link is told to the twin and nothing is rerouted -- this fabric's own controller owns every table (switch_state: reroute external_control_plane, heartbeat)
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 944576) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 944632) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- this package declares an external control
  !!    plane, so the proxy installs no routes and 0 is the designed answer, not a
  !!    reading: the forwarding is the exercise's controller's, and the proxy reports no
  !!    path rather than guess one over the declared links. The exercise's own controller
  !!    is what puts rules on these switches:
  !!    tools/p4_exercise/run_external_controller.py <pkg> <controller.py>
  ok  proxy: 3/3 switches
... [trimmed; 7177 chars total]
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1790944796.2485633,
  "boot_id": "6603f4d15ff4449babe707f83e246fa8",
  "control_plane": {
    "mode": "external",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton",
    "skipped": [
      "clone_session",
      "install_initial_routes",
      "lldp_discovery",
      "pipeline_push",
      "sflow_telemetry"
    ],
    "telemetry": {
      "knob": "absent",
      "link_emitter": {
        "alive": true,
        "manifest": "/tmp/ndtwin_link_telemetry.json",
        "pid": 944438,
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
  "heartbeat": {
    "census": {
      "arms": 26,
      "arms_where_a_host_saw_a_frame": 0,
      "heartbeat_ran": 20,
      "measured": "2026-09-26, TICKET-P4-heartbeat segment S (census part)",
      "no_inter_switch_link": 4,
      "not_built": 2,
      "raw": "doc/audit/2026-09-25_p4-heartbeat/spike/runs/2026-09-26T052148Z_S_heartbeat/40_census.tsv",
      "summary": "13 tutorials exercises x skeleton/solution. On the 20 arms where the heartbeat ran, no host received a heartbeat frame, and the daemon counted none leaving a host-facing port and none forwarded to another switch. calc and multicast are one switch (no inter-switch link, nothing sent); basic_tunnel and flowcache skeletons do not build. Segment S's census started the heartbeat by hand (the helper, not ndt) on all 20. Since 2026-09-27 `ndt up p4 --app` is EXPECTED to start it on all 20 too -- on the 3 external control planes among them (p4runtime skeleton and solution, flowcache solution) detect only, and since 2026-09-28 only after ndt's offline drop check proves the program drops the frame -- which is inferred from ndt's rule and not yet measured under ndt (live-p1/08 PART=h5 checks it per arm). On an external control plane a frame the program punts to ITS OWN controller is seen neither by this proxy (it has no stream there) nor by the daemon (it counts frames leaving switch ports); the drop check (tools/test_workflow/heartbeat_drop_check.py) is what keeps the heartbeat off a program that does that. The P4 SOURCE of these 3 programs drops it (flowcache drops every non-IPv4 frame at ingress; advanced_tunnel applies no table to it, so egress_spec stays 0 -- that no port 0 exists is inferred from bmv2), and the drop check agrees on a throwaway bmv2 with each program loaded and no controller (flowcache drops it at ingress; advanced_tunnel sends it to port 0, which no switch of the fabric has). Segment S's census ran them with no controller: each switch ran the package's compiled program (the daemon's report names advanced_tunnel.json or flowcache.json for every switch) with no table entry, every direction heard all 5 frames sent and no host saw one -- the programs' default actions, the drop check's question. P4Runtime had no pipeline config pushed (the FAILED_PRECONDITION ndt's verify reports as 'no pipeline loaded'); live-p1/08 PART=h5 is the first measurement with these programs loaded by their controllers, entries and all. Any other external program is checked the same way before the heartbeat starts on it; what its controller does later -- entries it installs, a pipeline it pushes itself, a default action it changes -- is not covered."
    },
    "detail": "running, written 0.9 s ago, 6 declared direction(s)",
    "directions": 6,
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
    "pid": 944535,
    "report": "/run/ndtwin-lab/heartbeat.json",
    "report_age_s": 0.911,
    "session": "171886cfb30201b1",
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
  "reroute": {
    "available": false,
    "detail": "the package declares an external control plane: its own controller owns every table and this proxy writes nothing. A cut link is detected by the heartbeat and told to the kernel, and no route is rewritten.",
    "reason": "external_control_plane"
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
      "entries_recorded": 0,
      "flow_stats": {
        "unrendered_entries": null
      },
      "grpc_addr": "localhost:30051",
... [trimmed; 11064 chars total]
```

### 5. N5  ndt status

```
$ ndt status (rc=0)
```

```
lab
  claim          yours -- 45m left (until 21:24:49)
  note           in use: ndt up p4 3 at 2026-10-02 20:39:50 by extb-live
  prev claim     extb-live (until 21:23:09), superseded 2026-10-02 20:39:48  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-10-02 20:39:48; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           acd84fdc  +98 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  3, written by 'ndt up p4 3' at 20:39:50 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          3   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/p4runtime-skeleton/ndtwin/topology.json
  p4 host knob   3   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton (mode external)
                 p4runtime -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 944438, 3 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    6       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  heartbeat      running (pid 944535, session 171886cfb30201b1) -- 6 direction(s), report 2.5 s old
  pidfiles       kernel.child.pid=944637 alive,kernel.pid=944632 alive,p4_proxy.child.pid=944581 alive,p4_proxy.pid=944576 alive

network health
  switches       0 up, 0 enabled, 0 admin-disabled
  links          12 total, 0 down, 0 admin-disabled
                 up/enabled above is a READING, not a verdict: an external package loads no pipeline until its own controller runs, and the twin calls such a switch Down
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  3 switches (0 up, 0 enabled), 3 hosts, 12 edges
proxy
  0 destination paths reported; none expected -- an external control plane on dpid 1,2,3: its forwarding is its own controller's, and the proxy reports no path rather than guess one over the declared links

up target
  asked for      p4, 3 hosts   (recorded 2026-10-02 20:39:50 by extb-live)
  topology       .test_run/packages/p4runtime-skeleton/ndtwin/topology.json   (declares 3 hosts / 12 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   3                      == 3   ok
  graph hosts    3                      == 3   ok
  graph edges    12                     == 12   ok
  topology file  sha256 f635d32a0dd3    == recorded   ok
  device names   no overlay file at .test_run/nickname_overlay/topology.names.json
                 that is where this checkout's kernel writes them; not a claim that none are set
```

### 6. C1  mycontroller.py under its own interpreter

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/run_external_controller.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton mycontroller.py
```

```
[adapter] tutorials utils : /home/adam/tutorials/utils
[adapter] grpc base       : 30050 (device id = dpid)
[adapter] running          /home/adam/tutorials/exercises/p4runtime/mycontroller.py  (cwd /home/adam/tutorials/exercises/p4runtime)
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
[adapter] s2: 127.0.0.1:50052 device_id=1  ->  localhost:30052 device_id=2
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed ingress tunnel rule on s1
TODO Install transit tunnel rule
Installed egress tunnel rule on s2
Installed ingress tunnel rule on s2
TODO Install transit tunnel rule
Installed egress tunnel rule on s1

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

--- 10.0.2.2 ping statistics ---
5 packets transmitted, 0 received, 100% packet loss, time 4116ms
```

### 8. N8  G1 link usage follows the iperf path -- NOT RUN

```
$ live-p1/_common.sh link_usage_round (not called)
```

```
NOT RUN: the skeleton arm is a fabric the exercise says should not forward; there is no path for a program-independent cell to follow
```

### 9. P9  controller log after the round

```
$ /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-10-02T123948Z_p4runtime_skeleton_ndtwin/driver-controller-p4runtime.log
```

```
[adapter] tutorials utils : /home/adam/tutorials/utils
[adapter] grpc base       : 30050 (device id = dpid)
[adapter] running          /home/adam/tutorials/exercises/p4runtime/mycontroller.py  (cwd /home/adam/tutorials/exercises/p4runtime)
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
[adapter] s2: 127.0.0.1:50052 device_id=1  ->  localhost:30052 device_id=2
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed ingress tunnel rule on s1
TODO Install transit tunnel rule
Installed egress tunnel rule on s2
Installed ingress tunnel rule on s2
TODO Install transit tunnel rule
Installed egress tunnel rule on s1

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
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 3 packets (294 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)

----- Reading tunnel counters -----
s1 MyIngress.ingressTunnelCounter 100: 5 packets (490 bytes)
s2 MyIngress.egressTunnelCounter 100: 0 packets (0 bytes)
s2 MyIngress.ingressTunnelCounter 200: 0 packets (0 bytes)
s1 MyIngress.egressTunnelCounter 200: 0 packets (0 bytes)
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
  stopping the heartbeat (before the topology it watches is taken down)
      heartbeat stopped (pid 944535)
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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton -- this checkout is being put back
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
| PASS | RED ARM: the transit rule is still the student's TODO | 【源碼推導，未執行】 | `TODO Install transit tunnel rule` | `still a TODO` | mycontroller.py:76. If the skeleton installed it, the solution's green says nothing about the transit rule. |
| PASS | RED ARM: h1 -> h2 does not forward | 【README 宣稱】＋【源碼推導，未執行】 | `100% loss` | `100% loss, 0/5 received` | README step 1.3: only s1's ingress counter moves; the packets die inside s1 for want of the transit rule |

## 6. 交換機 log / pcap

- `/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-10-02T123948Z_p4runtime_skeleton_ndtwin/driver-controller-p4runtime.log`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- p4runtime / skeleton
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
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/p4runtime --topology topology.json --p4 advanced_tunnel.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
  NDT_OWNER=extb-live /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=extb-live /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/p4runtime --topology topology.json --p4 advanced_tunnel.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
package 'p4runtime' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
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
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
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
  PASS  p4c-bm2-ss                   rc=0  advanced_tunnel.json sha256:ae78ff95657b571e  advanced_tunnel.p4.p4info.txtpb sha256:4d986039017abeef

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=extb-live /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise p4runtime/skeleton on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by extb-live for 45m (drive_exercise p4runtime/skeleton on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=extb-live /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
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
  PASS  p4c-bm2-ss                   rc=0  advanced_tunnel.json sha256:ae78ff95657b571e  advanced_tunnel.p4.p4info.txtpb sha256:4d986039017abeef

PASS -- every check passed

  ok  heartbeat drop check: every pro
... [trimmed; 7177 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    external
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton
   control_plane.skipped ['clone_session', 'install_initial_routes', 'lldp_discovery', 'pipeline_push', 'sflow_telemetry']
   s1  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
   s2  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)
   s3  ndtwin=False p4info_sha256=4d986039017abeef  entries recorded=0 applied=0 failed=0 api_writes=0  (entries_recorded=0)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=extb-live /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 21:24:49)
  note           in use: ndt up p4 3 at 2026-10-02 20:39:50 by extb-live
  prev claim     extb-live (until 21:23:09), superseded 2026-10-02 20:39:48  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-10-02 20:39:48; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           acd84fdc  +98 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  3, written by 'ndt up p4 3' at 20:39:50 this round; the round started at 4 -- write 4 back before 'ndt release'
                   echo 4 > p4_proxy/mininet/host_count_override      # write it back; 'git checkout --' would give you HEAD
                 'ndt release' refuses while these differ; 'ndt release --force' releases anyway
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6a558fe4)

configuration
  hosts          3   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/p4runtime-skeleton/ndtwin/topology.json
  p4 host knob   3   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton (mode external)
                 p4runtime -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 944438, 3 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1,2,3 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  3       topo session   present
  host/switch    6       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  heartbeat      running (pid 944535, session 171886cfb30201b1) -- 6 direction(s), report 2.5 s old
  pidfiles       kernel.child.pid=944637 alive,kernel.pid=944632 alive,p4_proxy.child.pid=944581 alive,p4_proxy.pid=944576 alive

network health
  switches       0 up, 0 enabled, 0 admin-disabled
  links          12 total, 0 down, 0 admin-disabled
       
... [trimmed; 4155 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.1.1, h2=10.0.2.2, h3=10.0.3.3
$ /home/adam/p4dev-python-venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/run_external_controller.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/p4runtime-skeleton mycontroller.py   (> /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-10-02T123948Z_p4runtime_skeleton_ndtwin/driver-controller-p4runtime.log)
   controller pid 945338 (handed to the generic cell; stopped after it)
-- controller log (/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-10-02T123948Z_p4runtime_skeleton_ndtwin/driver-controller-p4runtime.log) --
[adapter] tutorials utils : /home/adam/tutorials/utils
[adapter] grpc base       : 30050 (device id = dpid)
[adapter] running          /home/adam/tutorials/exercises/p4runtime/mycontroller.py  (cwd /home/adam/tutorials/exercises/p4runtime)
[adapter] s1: 127.0.0.1:50051 device_id=0  ->  localhost:30051 device_id=1
[adapter] s2: 127.0.0.1:50052 device_id=1  ->  localhost:30052 device_id=2
Installed P4 Program using SetForwardingPipelineConfig on s1
Installed P4 Program using SetForwardingPipelineConfig on s2
Installed ingress tunnel rule on s1
TODO Install transit tunnel rule
Installed egress tunnel rule on s2
Installed ingress tunnel rule on s2
TODO Install transit tunnel rule
Installed egress tunnel rule on s1

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
$ h1: ping -c5 10.0.2.2 -> 100% loss, 0/5 received
   PASS RED ARM: the transit rule is still the student's TODO want=TODO Install transit tunnel rule got=still a TODO
   PASS RED ARM: h1 -> h2 does not forward             want=100% loss              got=100% loss, 0/5 received

-- switch logs --
   /home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/2026-10-02T123948Z_p4runtime_skeleton_ndtwin/driver-controller-p4runtime.log 2893 B

== G1  link usage follows the iperf path (program-independent) =========
   NOT RUN: the skeleton arm is a fabric the exercise says should not forward; there is no path for a program-independent cell to follow
   (a cell with no flow to follow is recorded as not run, never as a pass)

== teardown: ndt down, the two knobs, then ndt release =================
$ NDT_OWNER=extb-live /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
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
... [trimmed; 5486 chars total]
   ndt down rc=0
   host_count_override: put back to the 2 bytes this round found
   telemetry_override: unchanged (absent)
$ NDT_OWNER=extb-live /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: the controller stayed up            want=alive after 12s        got=alive   【源碼推導，未執行】
   PASS switches the controller programmed             want=[1, 2]                 got=[1, 2]   【源碼推導，未執行】
   PASS RED ARM: the transit rule is still the student's TODO want=TODO Install transit tunnel rule got=still a TODO   【源碼推導，未執行】
   PASS RED ARM: h1 -> h2 does not forward             want=100% loss              got=100% loss, 0/5 received   【README 宣稱】＋【源碼推導，未執行】

>>> PASS (4/4)
```

### stderr（mininet 的 logger 走這裡）

```

```
