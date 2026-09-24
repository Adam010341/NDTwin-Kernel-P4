# 執行報告 — `multicast` / skeleton

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-24T185950Z |
| exercise | `multicast` |
| which | `skeleton` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton` |
| cwd | `/home/adam/tutorials/exercises/multicast` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 1000 |
| 判定 | **PASS (2/2)** (exit 0) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `the bmv2 `ndt status` names` | `3ff54b5c1901c9d3` | 1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc) |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/multicast/build/multicast.p4.p4info.txtpb -o /home/adam/tutorials/exercises/multicast/build/multicast.json /home/adam/tutorials/exercises/multicast/multicast.p4
rc=0  warnings=1
/home/adam/tutorials/exercises/multicast/multicast.p4(13): [--Wwarn=unused] warning: 'ip4Addr_t' is unused
typedef bit<32> ip4Addr_t;
                ^^^^^^^^^
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/multicast/build/multicast.json` | 10446 | `f04fc49f882921bc` |
| `/home/adam/tutorials/exercises/multicast/build/multicast.p4.p4info.txtpb` | 833 | `54ec81d7c604860a` |

來源 `.p4`：`/home/adam/tutorials/exercises/multicast/multicast.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : sig-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1
links    : 4
```

### 3b. `GET /p4/switch_state`（揭露，不是結果）

```
control_plane.mode    ndtwin
control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
s1  ndtwin=False p4info_sha256=54ec81d7c604860a  entries recorded=4 applied=4 failed=0 api_writes=0  (entries_recorded=4)
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/multicast --topology sig-topo/topology.json --p4 multicast.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
```

```
package 'multicast' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
  control plane : ndtwin
  pipelines     : s1=build/multicast.json
  model         : 1 switches, 4 hosts, 8 edges (4 links, both directions stored)
  files         : 7
                  build/multicast.json
                  build/multicast.p4.p4info.txtpb
                  multicast.p4
                  ndtwin/topology.json
                  package.json
                  sig-topo/s1-runtime.json
                  sig-topo/topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
  PASS  format                            1
  INFO  name                              multicast
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     1 dpids: [1]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  6 present
  PASS  topo_from_json.switches           1 entries
  PASS  topo_from_json.hosts              4 entries
  PASS  topo_from_json.switch_links       0 entries
  PASS  topo_from_json.host_links         4 entries
  PASS  switches agree                    model and package.json both say [1]
  PASS  links agree                       4 links in both
  PASS  hosts named h<last octet>         4 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3', 'h4']
  PASS  switches pipeline                 1 of 1 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/multicast.json  p4info sha256:54ec81d7c604860a  program=/home/adam/tutorials/exercises/multicast/multicast.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              4 entries across 1 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  1 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  PASS  PRE entries                       1 multicast group(s) and 0 clone session(s); every replica names a port the model builds
  PASS  gRPC port block                   30051-30051 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  multicast.json sha256:26315023b154ac31  multicast.p4.p4info.txtpb sha256:54ec81d7c604860a

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
  PASS  format                            1
  INFO  name                              multicast
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     1 dpids: [1]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  6 present
  PASS  topo_from_json.switches           1 entries
  PASS  topo_from_json.hosts              4 entries
  PASS  topo_from_json.switch_links       0 entries
  PASS  topo_from_json.host_links         4 entries
  PASS  switches agree                    model and package.json both say [1]
  PASS  links agree                       4 links in both
  PASS  hosts named h<last octet>         4 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3', 'h4']
  PASS  switches pipeline                 1 of 1 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/multicast.json  p4info sha256:54ec81d7c604860a  program=/home/adam/tutorials/exercises/multicast/multicast.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              4 entries across 1 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  1 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  PASS  PRE entries                       1 multicast group(s) and 0 clone session(s); every replica names a port the model builds
  PASS  gRPC port block                   30051-30051 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  multicast.json sha256:26315023b154ac31  multicast.p4.p4info.txtpb sha256:54ec81d7c604860a

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/multicast-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton (mode ndtwin, 1 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 1 switches and the manifest
  ok  1 switches up after 6s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 2476080) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 . up
        started kernel (pid 2476141) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  !!  proxy: destination paths NOT CHECKED -- the package's own program runs on dpid
  !!    1; the proxy says it sent no LLDP and installed no routes on this
  !!    fabric (control_plane.skipped: install_initial_routes, link_watchdog, lldp_discovery)
  ok  table entries: 4/4 applied on 1 switch(es), 0 failed
  ok  kernel: 1 switches, 1 up, 8 edges, 4 hosts
  ok  model matches fabric: 4 hosts (kernel graph, topology file and 4 host namespaces all agree)
  ok  telemetry: auto -- 0 cooperative, 1 link, 0 none; the proxy agrees switch by switch
  !!  data plane: h1 cannot reach 10.0.0.2 -- a READING, not a verdict: under the package's
  !!    own program (54ec81d7c604860a) whether plain IPv4 forwards is the package's claim, not
  !!    NDTwin's (a skeleton does not forward; source_routing needs its header).
  !!    The exercise's driver judges it.

up. ready
  proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo
  !!  package pipeline: NDTwin discovered no links and installed no routes on this
  !!    fabric; forwarding is whatever the package's 4 entries on
  !!    1 switch(es) make of it. ndt status quotes no sample rate for it.
```

### 4. N4  GET /p4/switch_state

```
$ http://localhost:8081/p4/switch_state
```

```
{
  "boot_at": 1790276397.1259701,
  "boot_id": "a844423ecbd641f68db4bfda873afe34",
  "control_plane": {
    "mode": "ndtwin",
    "package": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton",
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
        "pid": 2475964,
        "rate": 256,
        "switches": [
          1
        ]
      },
      "package": "auto"
    }
  },
  "declared_links": {
    "directions": 0,
    "error": null
  },
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
      "oldest_rule_installed_at": 1790276398.227271,
      "pipeline": {
        "ndtwin": false,
        "p4info": "/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton/build/multicast.p4.p4info.txtpb",
        "p4info_sha256": "54ec81d7c604860a",
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
          "applied": 1,
          "failed": 0,
          "recorded": 1
        }
      },
      "probe_age_s": 0.013,
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
      "table_generation": "f9812aae30cf4f1fb56dcb76c4073e83",
      "telemetry": {
        "clone_session": false,
        "packet_in_ids": null,
        "reason": "this switch runs the app package's own pipeline, which does not clone to the CPU port; its samples come from 'link'",
        "sflow_registered": false,
        "source": "link"
      }
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
  claim          yours -- 45m left (until 03:44:50)
  note           in use: ndt up p4 4 at 2026-09-25 02:59:51 by orch-0924
  prev claim     orch-0924 (until 03:44:31), superseded 2026-09-25 02:59:49  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 02:59:49; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           0c96c1d0  +79 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 02:59:50)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/multicast-skeleton/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton (mode ndtwin)
                 multicast -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2475964, 1 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  1       topo session   present
  host/switch    5       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2476146 alive,kernel.pid=2476141 alive,p4_proxy.child.pid=2476086 alive,p4_proxy.pid=2476080 alive

network health
  switches       1 up, 1 enabled, 0 admin-disabled
  links          8 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  1 switches (1 up, 1 enabled), 4 hosts, 8 edges
proxy
  12 destination paths reported; none expected -- the package's program on dpid 1, proxy skipped lldp_discovery

up target
  asked for      p4, 4 hosts   (recorded 2026-09-25 02:59:51 by orch-0924)
  topology       .test_run/packages/multicast-skeleton/ndtwin/topology.json   (declares 4 hosts / 8 edges)
  dataplane      p4                     == p4   ok
  fabric hosts   4                      == 4   ok
  graph hosts    4                      == 4   ok
  graph edges    8                      == 8   ok
  topology file  sha256 4699c79d955a    == recorded   ok
  device names   no overlay file at .test_run/nickname_overlay/topology.names.json
                 that is where this checkout's kernel writes them; not a claim that none are set
```

### 6. U1  IPv6 off in every host namespace

```
$ sysctl -w net.ipv6.conf.{all,default}.disable_ipv6=1 in each host
```

```
exercises/multicast/disable_ipv6.sh's two lines, per namespace
```

### 7. ARP caches emptied before the measurement

```
$ ip neigh flush all (each host)
```

```
h1, h2, h3, h4
```

### 8. pingall -- every ordered pair, ping -c 5 -W 2

```
$ ping -c 5 -W 2 <each ordered pair>
```

```
100% (0/12 pairs at 0%, 12 lossy)
h1 -> h2 (10.0.0.2): 100% loss, 0/5 received
h1 -> h3 (10.0.0.3): 100% loss, 0/5 received
h1 -> h4 (10.0.0.4): 100% loss, 0/5 received
h2 -> h1 (10.0.0.1): 100% loss, 0/5 received
h2 -> h3 (10.0.0.3): 100% loss, 0/5 received
h2 -> h4 (10.0.0.4): 100% loss, 0/5 received
h3 -> h1 (10.0.0.1): 100% loss, 0/5 received
h3 -> h2 (10.0.0.2): 100% loss, 0/5 received
h3 -> h4 (10.0.0.4): 100% loss, 0/5 received
h4 -> h1 (10.0.0.1): 100% loss, 0/5 received
h4 -> h2 (10.0.0.2): 100% loss, 0/5 received
h4 -> h3 (10.0.0.3): 100% loss, 0/5 received
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
        1 bmv2 switch(es)
        5 host/switch process(es)
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
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9091 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        ryu exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        find and stop it, or the next 'up' will report on it:
          ss -ltnp   # tcp rows;  ss -lunp   # the udp one (:6343) -- see ports.sh
          cat /home/adam/Desktop/NDTwin-Kernel/.test_run/pids/*.pid   # what this stack started; check each against /proc/<pid>
  !!  stack.sh down exited 1, and the only thing behind that status is port(s)
  !!    still listening at [1/3], held by processes it did not start:
  !!      9091 30051 
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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton -- this checkout is being put back
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports closed: 8000/8080/8081/6653/6633/6343/30051-30060/9091-9100/9000

clean
  ok  the 2 port(s) [1/3] called 'still listening' were closed by [3/3]: 9091 30051 
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
| PASS | injection: every ordered pair was tested | 【源碼推導，未執行】 | `0 untested` | `0 untested of 12` | an untested pair is not a blocked one; without this 'h4 is unreachable' would also describe a host whose namespace could not be entered |
| PASS | RED ARM: nothing pings at all | 【README 宣稱】＋【源碼推導，未執行】 | `100.0%` | `100% (0/12 pairs at 0%, 12 lossy)` | README:78-80 'multicast.p4 ... drops all packets on arrival'; multicast.p4:91 default_action = drop, so even ARP dies and no host ever learns a MAC. If this is red the solution's reachability proves nothing. |

## 6. 交換機 log / pcap


## 8. 完整 transcript

### stdout

```
drive_exercise.py -- multicast / skeleton
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/multicast

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/multicast/build/multicast.p4.p4info.txtpb -o /home/adam/tutorials/exercises/multicast/build/multicast.json /home/adam/tutorials/exercises/multicast/multicast.p4
/home/adam/tutorials/exercises/multicast/multicast.p4(13): [--Wwarn=unused] warning: 'ip4Addr_t' is unused
typedef bit<32> ip4Addr_t;
                ^^^^^^^^^
-> /home/adam/tutorials/exercises/multicast/build/multicast.json  10446 B  sha256[:16]=f04fc49f882921bc  warnings=1

== plan ================================================================
topology : sig-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1
links    : 4
program  : /home/adam/tutorials/exercises/multicast/multicast.p4 -> build/multicast.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : disable IPv6 in each host; pingall; assert h1/h2/h3 reach each other and nobody reaches h4 (sig-topo's group is ports 1,2,3)
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/multicast --topology sig-topo/topology.json --p4 multicast.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
  NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/multicast --topology sig-topo/topology.json --p4 multicast.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
package 'multicast' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
  control plane : ndtwin
  pipelines     : s1=build/multicast.json
  model         : 1 switches, 4 hosts, 8 edges (4 links, both directions stored)
  files         : 7
                  build/multicast.json
                  build/multicast.p4.p4info.txtpb
                  multicast.p4
                  ndtwin/topology.json
                  package.json
                  sig-topo/s1-runtime.json
                  sig-topo/topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
  PASS  format                            1
  INFO  name                              multicast
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     1 dpids: [1]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  6 present
  PASS  topo_from_json.switches           1 entries
  PASS  topo_from_json.hosts              4 entries
  PASS  topo_from_json.switch_links       0 entries
  PASS  topo_from_json.host_links         4 entries
  PASS  switches agree                    model and package.json both say [1]
  PASS  links agree                       4 links in both
  PASS  hosts named h<last octet>         4 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3', 'h4']
  PASS  switches pipeline                 1 of 1 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/multicast.json  p4info sha256:54ec81d7c604860a  program=/home/adam/tutorials/exercises/multicast/multicast.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              4 entries across 1 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  1 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  PASS  PRE entries                       1 multicast group(s) and 0 clone session(s); every replica names a port the model builds
  PASS  gRPC port block                   30051-30051 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  multicast.json sha256:26315023b154ac31  multicast.p4.p4info.txtpb sha256:54ec81d7c604860a

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')
telemetry_override snapshot: absent

== claim the lab =======================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise multicast/skeleton on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by orch-0924 for 45m (drive_exercise multicast/skeleton on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
  PASS  format                            1
  INFO  name                              multicast
  PASS  control_plane.mode                ndtwin
  PASS  control_plane.grpc_base           30050
  PASS  control_plane.device_id           dpid
  PASS  control_plane.election_id         [0, 65535]
  PASS  bmv2.cpu_port                     255
  PASS  switches keys                     1 dpids: [1]
  PASS  switches name                     every sN has dpid N
  PASS  referenced files                  6 present
  PASS  topo_from_json.switches           1 entries
  PASS  topo_from_json.hosts              4 entries
  PASS  topo_from_json.switch_links       0 entries
  PASS  topo_from_json.host_links         4 entries
  PASS  switches agree                    model and package.json both say [1]
  PASS  links agree                       4 links in both
  PASS  hosts named h<last octet>         4 hosts
  PASS  hosts agree                       model and package.json both say ['h1', 'h2', 'h3', 'h4']
  PASS  switches pipeline                 1 of 1 switch(es) carry their own program; p4info tables and actions are all in the bmv2 json
  INFO  s1 pipeline                       build/multicast.json  p4info sha256:54ec81d7c604860a  program=/home/adam/tutorials/exercises/multicast/multicast.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              4 entries across 1 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  1 switch(es); entries and pipeline name the same p4info
  INFO  telemetry.source                  not declared (auto: NDTwin's pipeline gets the cooperative path, anybody else's gets link telemetry)
  PASS  PRE entries                       1 multicast group(s) and 0 clone session(s); every replica names a port the model builds
  PASS  gRPC port block                   30051-30051 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  multicast.json sha256:26315023b154ac31  multicast.p4.p4info.txtpb sha256:54ec81d7c604860a

PASS -- every check passed

ndt up p4
  hosts        4        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/multicast-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton (mode ndtwin, 1 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton   (p4_proxy/mininet/app_package_override)
  telemetry    auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)

... [trimmed; 4927 chars total]

== GET /p4/switch_state ================================================
   control_plane.mode    ndtwin
   control_plane.package /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton
   control_plane.skipped ['install_initial_routes', 'link_watchdog', 'lldp_discovery']
   s1  ndtwin=False p4info_sha256=54ec81d7c604860a  entries recorded=4 applied=4 failed=0 api_writes=0  (entries_recorded=4)

== ndt status (raw; and the bmv2 binary it names) ======================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 03:44:50)
  note           in use: ndt up p4 4 at 2026-09-25 02:59:51 by orch-0924
  prev claim     orch-0924 (until 03:44:31), superseded 2026-09-25 02:59:49  (.test_run/lab.claim.prev)
                 the same owner re-claimed it -- a rewrite, not a handover
                 it said: down at 2026-09-25 02:59:49; verified clean; claim kept
  exclusive cpu  no (heavy local jobs may overlap this claim)
  measuring      nothing
  code           0c96c1d0  +79 file(s) with uncommitted changes
                 3 of them can change behaviour:
                 p4_proxy/mininet/host_count_override
                 p4_proxy/mininet/app_package_override
                 tools/remote-lab/dorm_lab/
  knob baseline  4 == the value this round started with (at 02:59:50)
  tree vs round  0 file(s) LEFT the uncommitted set, 1 joined it
                 + p4_proxy/mininet/app_package_override
  ok  helper: /usr/local/sbin/ndtwin-lab is tools/test_workflow/ndtwin-lab (sha256 6685d3a9)

configuration
  hosts          4   (what the last 'ndt up' asked for: p4)
  topology       .test_run/packages/multicast-skeleton/ndtwin/topology.json
  p4 host knob   4   (p4_proxy/mininet/host_count_override -- P4 only; decides the next 'ndt up p4')
  app package    /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/multicast-skeleton (mode ndtwin)
                 multicast -- p4_proxy/mininet/app_package_override; it decides the next 'ndt up p4' and the next proxy
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  telemetry      auto   (p4_proxy/mininet/telemetry_override absent -- auto, then the package)
                 every switch: link
                 link emitter: alive pid 2475964, 1 switch(es), rate 256
  link shaping   off (no package link asks for one)
  sample rate    n/a (package pipeline)
  rate source    the app package runs a foreign pipeline on dpid 1 -- p4_proxy/p4_src/build/ndtwin_switch.json is NOT what those switches loaded, and stale_pipeline is not judged
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  1       topo session   present
  host/switch    5       manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc
  pidfiles       kernel.child.pid=2476146 alive,kernel.pid=2476141 alive,p4_proxy.child.pid=2476086 alive,p4_proxy.pid=2476080 alive

network health
  switches       1 up, 1 enabled, 0 admin-disabled
  links          8 total, 0 down, 0 admin-disabled
  tc netem       none
  sudo grants    all 3 granted
  apps           none running

kernel graph
  1 switches (1 up, 1 enabled), 4 hosts, 8 edges
proxy
  12 destination paths reported; none expected -- the package's program on dpid 1, proxy skipped lldp_discovery

up target
  asked for      p4, 4 hosts   (recorded 2026-09-25 02:59:51 by orch-0924)
  topology       .test_run/packages/mult
... [trimmed; 3505 chars total]
   bmv2 sha256[:16]=3ff54b5c1901c9d3  1.15.3-f0b7d201   (ndt status: /usr/local/bmv2-fast/bin/simple_switch_grpc)

== scripted steps (no CLI, no xterm) ===================================
   hosts: h1=10.0.0.1, h2=10.0.0.2, h3=10.0.0.3, h4=10.0.0.4
$ h1: disable_ipv6 -> net.ipv6.conf.all.disable_ipv6 = 1 | net.ipv6.conf.default.disable_ipv6 = 1
$ h2: disable_ipv6 -> net.ipv6.conf.all.disable_ipv6 = 1 | net.ipv6.conf.default.disable_ipv6 = 1
$ h3: disable_ipv6 -> net.ipv6.conf.all.disable_ipv6 = 1 | net.ipv6.conf.default.disable_ipv6 = 1
$ h4: disable_ipv6 -> net.ipv6.conf.all.disable_ipv6 = 1 | net.ipv6.conf.default.disable_ipv6 = 1
$ ip neigh flush all, in each host namespace -> h1, h2, h3, h4
$ every ordered host pair: ping -c 5 -W 2, loss parsed from ping's summary
   h1 -> h2 (10.0.0.2): 100% loss, 0/5 received
   h1 -> h3 (10.0.0.3): 100% loss, 0/5 received
   h1 -> h4 (10.0.0.4): 100% loss, 0/5 received
   h2 -> h1 (10.0.0.1): 100% loss, 0/5 received
   h2 -> h3 (10.0.0.3): 100% loss, 0/5 received
   h2 -> h4 (10.0.0.4): 100% loss, 0/5 received
   h3 -> h1 (10.0.0.1): 100% loss, 0/5 received
   h3 -> h2 (10.0.0.2): 100% loss, 0/5 received
   h3 -> h4 (10.0.0.4): 100% loss, 0/5 received
   h4 -> h1 (10.0.0.1): 100% loss, 0/5 received
   h4 -> h2 (10.0.0.2): 100% loss, 0/5 received
   h4 -> h3 (10.0.0.3): 100% loss, 0/5 received
-> pingall 100% (0/12 pairs at 0%, 12 lossy)
   PASS injection: every ordered pair was tested       want=0 untested             got=0 untested of 12
   PASS RED ARM: nothing pings at all                  want=100.0%                 got=100% (0/12 pairs at 0%, 12 lossy)

-- switch logs --

== G1  link usage follows the iperf path (program-independent) =========
   NOT RUN: the skeleton arm is a fabric the exercise says should not forward; there is no path for a program-independent cell to follow
   (a cell with no flow to follow is recorded as not run, never as a pass)

== teardown: ndt down, the two knobs, then ndt release =================
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
  this teardown is about:
        1 bmv2 switch(es)
        5 host/switch process(es)
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
        -> the same leftover switch that holds a gRPC port holds this one; the same line of code assigns both, so a check that names only one of them is half a check
        :9091 is still listening, held by a process this user cannot see (probably root-owned)
          This script did not start it. The next 'up' would find the port open and
          measure the wrong process, so this is reported rather than ignored.
        ryu exit status 143 (terminated by SIGTERM (15) -- or exit(143), which bash cannot distinguish)
        find and stop it, or the next 'up' will report on it:
          ss -ltnp   # tcp rows;  ss -lunp   # the udp one (:6343) -- see ports.sh
          cat /home/adam/Desktop/NDTwin-Kernel/.test_run/pids/*.pid   # what this stack started; check each against /proc/<pid>
  !!  stack.sh down exited 1, and the only thing behind that status is port(s)
  !!    still listening at [1/3], held by processes it did not start:
  !!      9091 30051 
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
    [1/3] filt
... [trimmed; 3725 chars total]
   ndt down rc=0
   host_count_override: unchanged (2 bytes)
   telemetry_override: unchanged (absent)
$ NDT_OWNER=orch-0924 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================
   PASS injection: every ordered pair was tested       want=0 untested             got=0 untested of 12   【源碼推導，未執行】
   PASS RED ARM: nothing pings at all                  want=100.0%                 got=100% (0/12 pairs at 0%, 12 lossy)   【README 宣稱】＋【源碼推導，未執行】

>>> PASS (2/2)
```

### stderr（mininet 的 logger 走這裡）

```

```
