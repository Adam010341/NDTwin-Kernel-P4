# 執行報告 — `source_routing` / skeleton

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-18T102328Z |
| exercise | `source_routing` |
| which | `skeleton` |
| fabric | `ndtwin` |
| package | `/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton` |
| cwd | `/home/adam/tutorials/exercises/source_routing` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 1000 |
| 判定 | **ERROR** (exit 1) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `/usr/local/bin/simple_switch_grpc` | `-` | n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/source_routing/build/source_routing.p4.p4info.txtpb -o /home/adam/tutorials/exercises/source_routing/build/source_routing.json /home/adam/tutorials/exercises/source_routing/source_routing.p4
rc=0  warnings=4
/home/adam/tutorials/exercises/source_routing/source_routing.p4(8): [--Wwarn=unused] warning: 'TYPE_SRCROUTING' is unused
const bit<16> TYPE_SRCROUTING = 0x1234;
              ^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/source_routing/source_routing.p4(16): [--Wwarn=unused] warning: 'egressSpec_t' is unused
typedef bit<9> egressSpec_t;
               ^^^^^^^^^^^^
/home/adam/tutorials/exercises/source_routing/source_routing.p4(118): [--Wwarn=unused] warning: 'srcRoute_nhop' is unused
    action srcRoute_nhop() {
           ^^^^^^^^^^^^^
/home/adam/tutorials/exercises/source_routing/source_routing.p4(126): [--Wwarn=unused] warning: 'srcRoute_finish' is unused
    action srcRoute_finish() {
           ^^^^^^^^^^^^^^^
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/source_routing/build/source_routing.json` | 12410 | `e6816123c89b51a8` |
| `/home/adam/tutorials/exercises/source_routing/build/source_routing.p4.p4info.txtpb` | 317 | `f2e2ebfd5cc0651c` |

來源 `.p4`：`/home/adam/tutorials/exercises/source_routing/source_routing.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
```

## 4. 每一步的指令與原始輸出

### 1. N1  convert.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/source_routing --topology topology.json --p4 source_routing.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
```

```
package 'source_routing' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
  control plane : ndtwin
  pipelines     : s1=build/source_routing.json, s2=build/source_routing.json, s3=build/source_routing.json
  model         : 3 switches, 3 hosts, 12 edges (6 links, both directions stored)
  files         : 9
                  build/source_routing.json
                  build/source_routing.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  s1-runtime.json
                  s2-runtime.json
                  s3-runtime.json
                  source_routing.p4
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
```

### 2. N2  preflight.py

```
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
```

```
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
  PASS  format                            1
  INFO  name                              source_routing
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
  INFO  s1 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  INFO  s2 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  INFO  s3 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              0 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  source_routing.json sha256:71c3603e6e2e97c0  source_routing.p4.p4info.txtpb sha256:f2e2ebfd5cc0651c

PASS -- every check passed
```

### 3. N3  ndt up p4 --app

```
$ ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
```

```
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
  PASS  format                            1
  INFO  name                              source_routing
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
  INFO  s1 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  INFO  s2 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  INFO  s3 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              0 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  source_routing.json sha256:71c3603e6e2e97c0  source_routing.p4.p4info.txtpb sha256:f2e2ebfd5cc0651c

PASS -- every check passed

ndt up p4
  hosts        3        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/source_routing-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton (mode ndtwin, 3 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 3 (persistent; affects every later run)
  app package set: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton   (p4_proxy/mininet/app_package_override)
  claim note now says the lab is in use (owner and expiry unchanged)
[1/3] bmv2 fabric
      topo session started from /home/adam/Desktop/NDTwin-Kernel (attach: sudo tmux -L ndtwinlab attach -t topo)
  waiting for 3 switches and the manifest
  ok  3 switches up after 4s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 1205852) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 .. up
        waiting for link discovery: want 6 destination paths
        started kernel (pid 1207253) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  XX  proxy: 0/6 destination paths, never settled
  ok  kernel: 3 switches, 3 up, 12 edges, 3 hosts
  ok  model matches fabric: 3 hosts (kernel graph, topology file and 3 host namespaces all agree)
  XX  data plane: h1 cannot reach 10.0.2.2 -- fabric is up but not forwarding
  XX     the proxy reports its paths installed; that is not the same as bmv2 forwarding them

up, but not verified -- do not measure on this
```

### 4. N9  ndt down

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
  app package cleared: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton -- this checkout is being put back
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

### 5. N10 ndt release

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
| — | （沒有跑到任何一步） | — | — | — | — |

## 6. 交換機 log / pcap


## 8. 完整 transcript

### stdout

```
drive_exercise.py -- source_routing / skeleton
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/source_routing

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/source_routing/build/source_routing.p4.p4info.txtpb -o /home/adam/tutorials/exercises/source_routing/build/source_routing.json /home/adam/tutorials/exercises/source_routing/source_routing.p4
/home/adam/tutorials/exercises/source_routing/source_routing.p4(8): [--Wwarn=unused] warning: 'TYPE_SRCROUTING' is unused
const bit<16> TYPE_SRCROUTING = 0x1234;
              ^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/source_routing/source_routing.p4(16): [--Wwarn=unused] warning: 'egressSpec_t' is unused
typedef bit<9> egressSpec_t;
               ^^^^^^^^^^^^
/home/adam/tutorials/exercises/source_routing/source_routing.p4(118): [--Wwarn=unused] warning: 'srcRoute_nhop' is unused
    action srcRoute_nhop() {
           ^^^^^^^^^^^^^
/home/adam/tutorials/exercises/source_routing/source_routing.p4(126): [--Wwarn=unused] warning: 'srcRoute_finish' is unused
    action srcRoute_finish() {
           ^^^^^^^^^^^^^^^
-> /home/adam/tutorials/exercises/source_routing/build/source_routing.json  12410 B  sha256[:16]=e6816123c89b51a8  warnings=4

== plan ================================================================
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
program  : /home/adam/tutorials/exercises/source_routing/source_routing.p4 -> build/source_routing.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : h2 receive.py; h1 send.py 10.0.2.2 with '2 3 2 2 1' then '2 1'; assert packet count + ttl
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/source_routing --topology topology.json --p4 source_routing.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
  NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
  ... the scripted steps above, then `ndt down` and `ndt release`.

== convert the exercise into an app package ============================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/source_routing --topology topology.json --p4 source_routing.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
package 'source_routing' -> /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
  control plane : ndtwin
  pipelines     : s1=build/source_routing.json, s2=build/source_routing.json, s3=build/source_routing.json
  model         : 3 switches, 3 hosts, 12 edges (6 links, both directions stored)
  files         : 9
                  build/source_routing.json
                  build/source_routing.p4.p4info.txtpb
                  ndtwin/topology.json
                  package.json
                  s1-runtime.json
                  s2-runtime.json
                  s3-runtime.json
                  source_routing.p4
                  topology.json
  read back through p4_proxy/mininet/topo_from_json.py: ok
  next: tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton

== pre-flight the package ==============================================
$ /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
  PASS  format                            1
  INFO  name                              source_routing
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
  INFO  s1 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  INFO  s2 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  INFO  s3 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              0 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  source_routing.json sha256:71c3603e6e2e97c0  source_routing.p4.p4info.txtpb sha256:f2e2ebfd5cc0651c

PASS -- every check passed
host_count_override snapshot: 2 bytes (b'4\n')

== claim the lab =======================================================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 drive_exercise source_routing/skeleton on the ndtwin fabric
  recorded this round's starting point in .test_run/round.baseline -- 'ndt status' compares against it
  ok  lab claimed by 9-18-orchestrator for 45m (drive_exercise source_routing/skeleton on the ndtwin fabric)

== ndt up p4 --app =====================================================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
app package pre-flight
  package      /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
pre-flight: /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton
  PASS  format                            1
  INFO  name                              source_routing
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
  INFO  s1 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  INFO  s2 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  INFO  s3 pipeline                       build/source_routing.json  p4info sha256:f2e2ebfd5cc0651c  program=/home/adam/tutorials/exercises/source_routing/source_routing.p4
  PASS  p4info parses                     google.protobuf.text_format into p4.config.v1.P4Info
  PASS  entries match p4info              0 entries across 3 switch(es); recorded, NOT applied in stage one
  PASS  entries p4info is the pipeline's  3 switch(es); entries and pipeline name the same p4info
  PASS  gRPC port block                   30051-30053 safe on this machine
  PASS  p4c-bm2-ss                        rc=0  source_routing.json sha256:71c3603e6e2e97c0  source_routing.p4.p4info.txtpb sha256:f2e2ebfd5cc0651c

PASS -- every check passed

ndt up p4
  hosts        3        (p4_proxy/mininet/host_count_override)
  topology     .test_run/packages/source_routing-skeleton/ndtwin/topology.json
  app package  /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/source_routing-skeleton (mode ndtwin, 3 switch(es))
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

  recorded this target in .test_run/up.target -- 'ndt status --check' compares against it
  !!  host_count_override: 4 -> 3 (persistent; affects every later run)
  app package set: /home/
... [trimmed; 4344 chars total]
!! 'ndt up p4 --app' exited 1

== teardown: ndt down, the host knob, then ndt release =================
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
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
... [trimmed; 5436 chars total]
   ndt down rc=0
   host_count_override: put back to the 2 bytes this round found
$ NDT_OWNER=9-18-orchestrator /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  the claim you held is kept as .test_run/lab.claim.prev -- 'ndt status' reads it back
  this round's starting point is now .test_run/round.baseline.prev -- 'ndt status' will say no round baseline is recorded
  ok  lab released
   ndt release rc=0

== verdict =============================================================

>>> ERROR
```

### stderr（mininet 的 logger 走這裡）

```

```
