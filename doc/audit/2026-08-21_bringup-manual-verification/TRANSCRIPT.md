# 開機手冊 §2 實跑逐字輸出（2026-08-21）

產生方式見同目錄 `README.md`。原始腳本：`verify_bringup_manual.sh`（已複製到本目錄）。

```

================================================================
== 0. GUARD -- refuse to touch a lab someone else holds
================================================================
no claim file -- lab is free

---- claim the lab for this run ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 verifying the bring-up manual (section 2)
  ok  lab claimed by manual-verify-0821 for 45m (verifying the bring-up manual (section 2))
[rc=0  0.0s]
[claim taken as manual-verify-0821]

================================================================
== 1. STARTING STATE  (manual 2.0 / 2.11)
================================================================

---- ndt status ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          yours -- 45m left (until 18:31:41)
  note           verifying the bring-up manual (section 2)
  measuring      nothing
  code           52cba51  +6 file(s) with uncommitted changes

configuration
  hosts          128
  topology       setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate    1/256
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  0       topo session   absent
  host/switch    0       manifest       absent
  :8000 kernel   closed  :8081 proxy    closed  :8080 ryu closed

network health
  switches       kernel not answering; no graph
  tc netem       none
  apps           none running

[rc=0  0.3s]

================================================================
== 2. CLEAR THE ENVIRONMENT  (manual 2.1)
================================================================
manual claims: down ~13s; clean checks bmv2 / mn procs / topo session / manifest / 3 ports

---- ndt down ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
[1/3] kernel + proxy/Ryu
[2/3] topology session
      no topo session
[3/3] sweep
      cleanup done

verify clean
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports 8000/8080/8081 closed

clean
[rc=0  1.6s]

---- ndt clean  (expect rc=0) ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt clean
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports 8000/8080/8081 closed

clean
[rc=0  0.1s]
[clean rc above must be 0]

---- manual 2.1 says clean does NOT assert these -- record them so we know the truth ----
$ tc qdisc show | grep -c netem
0
$ sudo -n ovs-vsctl list-br | grep -c .
0
0
$ ip -o link show type veth | wc -l
4

================================================================
== 3. REFUSALS THE MANUAL PROMISES  (manual 2.2 / 2.4)
================================================================

---- ndt up ovs 16   (manual 2.2: must refuse, rc=2) ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up ovs 16
  XX  OVS can only build 4 or 128 hosts, not 16.
  XX    128 comes from NTG's testbed_topo.py, 4 from tools/test_workflow/ovs_4host_topo.py;
  XX    neither takes a host count, so 'ndt up ovs 16' would build 128 and a model
  XX    of 16 would be loaded beside it.
  XX    use:  ndt up ovs   (128)   |   ndt up ovs4   (4)   |   ndt up p4 16
[rc=2  0.0s]
[expected rc=2 and a message naming ovs / ovs4 / p4 16]

---- ndt ntg   (manual 2.6: reports cli or prompt) ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt ntg
NTG mode: cli
  cli    -> the topology drops into Mininet's CLI
  prompt -> the topology hands control to NTG's own prompt
  change it with:  ndt ntg cli|prompt     (takes effect on the next 'ndt up')
[rc=0  0.0s]

================================================================
== 4. P4 / bmv2 BRING-UP  (manual 2.2: ~35-40s)
================================================================

---- ndt up p4 128 ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 128
ndt up p4
  hosts        128        (p4_proxy/mininet/host_count_override)
  topology     setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
  bmv2         /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate  1/256     (compiled into ndtwin_switch.json)

[1/3] bmv2 fabric
  waiting for 10 switches and the manifest
  ok  10 switches up after 18s, manifest written
  ok  running binary: /usr/local/bmv2-fast/bin/simple_switch_grpc
[2/3] proxy + kernel
  stack.sh prompt is answered immediately: the fabric is already up
        started p4_proxy (pid 1181376) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/p4_proxy.log
        waiting for P4 proxy agent on :8081 .... up
        waiting for link discovery: want 16256 destination paths
          paths=16256                                                        converged after 4s
        started kernel (pid 1181591) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[3/3] verify
  ok  proxy: 16256/16256 destination paths (stable)
  ok  kernel: 10 switches, 10 up, 288 edges, 128 hosts
  ok  model matches fabric: 128 hosts
  ok  data plane: h1 -> 10.0.0.2 forwards

up. ready
  proxy :8081   kernel :8000   Mininet CLI: sudo tmux -L ndtwinlab attach -t topo
[rc=0  33.6s]

================================================================
== 5. P4 ACCEPTANCE  (manual 2.3)
================================================================

---- ndt status --check   (expect rc=0) ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status --check
lab
  claim          yours -- 45m left (until 18:31:41)
  note           verifying the bring-up manual (section 2)
  measuring      nothing
  code           52cba51  +6 file(s) with uncommitted changes

configuration
  hosts          128
  topology       setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate    1/256
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  10      topo session   present
  host/switch    138     manifest       present
  :8000 kernel   open    :8081 proxy    open    :8080 ryu closed
  binary         /usr/local/bmv2-fast/bin/simple_switch_grpc

network health
  switches       10 up, 10 enabled, 0 admin-disabled
  links          288 total, 0 down, 0 admin-disabled
  tc netem       none
  apps           none running

kernel graph
  10 switches (10 up, 10 enabled), 128 hosts, 288 edges
proxy
  16256 destination paths (want 16256 for 128 hosts)

check: ok
[rc=0  0.7s]
[--check rc above must be 0]

---- cross-quadrant reachability -- the manual's claim that the view can be green while the network is dead ----
$ sudo -n mnexec -a 1162988 ping -c 2 -W 2 -q 10.0.0.64
--- 10.0.0.64 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 2.022/2.299/2.577/0.277 ms
$ sudo -n mnexec -a 1163114 ping -c 2 -W 2 -q 10.0.0.128
--- 10.0.0.128 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 2.972/3.095/3.218/0.123 ms
$ sudo -n mnexec -a 1163245 ping -c 2 -W 2 -q 10.0.0.1
--- 10.0.0.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 1.840/2.060/2.280/0.220 ms

---- manual 2.5: is the running fabric the fast build? ----
$ ps -eo args= | grep -o '/[^ ]*simple_switch_grpc' | sort -u
/usr/local/bmv2-fast/bin/simple_switch_grpc

================================================================
== 6. TEAR DOWN P4  (manual 2.8)
================================================================

---- ndt down ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
[1/3] kernel + proxy/Ryu
        stopped kernel
        stopped p4_proxy
[2/3] topology session
      topo stopped
[3/3] sweep
      cleanup done

verify clean
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports 8000/8080/8081 closed

clean
[rc=0  13.3s]

---- ndt clean  (expect rc=0) ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt clean
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports 8000/8080/8081 closed

clean
[rc=0  0.1s]

================================================================
== 7. OVS / Ryu BRING-UP  (manual 2.2: ~25s)
================================================================

---- ndt up ovs ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up ovs
ndt up ovs
  hosts        128
  topology     setting/StaticNetworkTopologyMininet_10Switches.json
[1/4] control plane (Ryu)
  ok  Ryu up, prompt reached
[2/4] data plane (OVS fabric)
  ok  139 host/switch processes after 2s
[3/4] proxy-less convergence + kernel
  the Ryu app sleeps a hard-coded 60s before installing paths, so this takes >60s
        started ryu (pid 1182380) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/ryu.log
        waiting for Ryu REST on :8080 . up
          switches=0 links=0 paths=pending              switches=10 links=32 paths=pending              switches=10 links=32 paths=installed                                                        converged after 20s
        started kernel (pid 1203121) -> /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/kernel.log
        waiting for kernel API on :8000 . up
[4/4] verify
  ok  kernel: 10 switches up+enabled
  ok  kernel graph matches the model file: 128 hosts, 288 edges
  ok  data plane: h1 -> 10.0.0.2 forwards

up. ready
[rc=0  24.1s]

================================================================
== 8. OVS ACCEPTANCE  (manual 2.3)
================================================================

---- ndt status --check   (expect rc=0) ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status --check
lab
  claim          yours -- 44m left (until 18:31:41)
  note           verifying the bring-up manual (section 2)
  measuring      nothing
  code           52cba51  +6 file(s) with uncommitted changes

configuration
  hosts          128
  topology       setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate    1/256
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  0       topo session   present
  host/switch    139     manifest       absent
  :8000 kernel   open    :8081 proxy    closed  :8080 ryu open

network health
  switches       10 up, 10 enabled, 0 admin-disabled
  links          288 total, 256 down, 0 admin-disabled
  tc netem       none
  apps           none running

kernel graph
  10 switches (10 up, 10 enabled), 128 hosts, 288 edges

check: 1 problem(s)
  - 256 link(s) are down
[rc=1  0.4s]

---- cross-quadrant reachability on OVS ----
$ sudo -n mnexec -a 1182432 ping -c 2 -W 2 -q 10.0.0.64
--- 10.0.0.64 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1016ms
rtt min/avg/max/mdev = 0.058/0.223/0.389/0.165 ms
$ sudo -n mnexec -a 1182558 ping -c 2 -W 2 -q 10.0.0.128
--- 10.0.0.128 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1058ms
rtt min/avg/max/mdev = 0.074/0.076/0.078/0.002 ms
$ sudo -n mnexec -a 1182686 ping -c 2 -W 2 -q 10.0.0.1
--- 10.0.0.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1001ms
rtt min/avg/max/mdev = 0.132/0.562/0.993/0.430 ms

---- manual 2.2 fold: which OpenFlow port did the switches actually dial? ----
$ sudo -n ovs-vsctl get-controller s1 s5 s10
ovs-vsctl: 'get-controller' command takes at most 1 arguments
$ ss -ltn | grep -E ':(6653|6633|8080)'
LISTEN 0      50           0.0.0.0:6653       0.0.0.0:*          
LISTEN 0      50           0.0.0.0:6633       0.0.0.0:*          
LISTEN 0      50           0.0.0.0:8080       0.0.0.0:*          

================================================================
== 9. TEAR DOWN OVS  (manual 2.8)
================================================================

---- ndt down ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt down
ndt down
[1/3] kernel + proxy/Ryu
        stopped kernel
        stopped ryu
[2/3] topology session
      topo stopped
[3/3] sweep
      cleanup done

verify clean
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports 8000/8080/8081 closed

clean
[rc=0  13.8s]

---- ndt clean  (expect rc=0) ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt clean
  ok  bmv2 switches: 0
  ok  host/switch processes: 0
  ok  no topo session
  ok  no switch manifest
  ok  ports 8000/8080/8081 closed

clean
[rc=0  0.1s]

================================================================
== 10. RELEASE
================================================================

---- ndt release ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt release
  ok  lab released
[rc=0  0.0s]

---- ndt status ----
$ /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt status
lab
  claim          none
  measuring      nothing
  code           52cba51  +6 file(s) with uncommitted changes

configuration
  hosts          128
  topology       setting/StaticNetworkTopologyP4_10Switches_128Hosts.json
  bmv2           /usr/local/bmv2-fast/bin/simple_switch_grpc
  sample rate    1/256
  note           /ndt/get_cpu_utilization is fabricated in MININET mode; use cpu_probe.py

running
  bmv2 switches  0       topo session   absent
  host/switch    0       manifest       absent
  :8000 kernel   closed  :8081 proxy    closed  :8080 ryu closed

network health
  switches       kernel not answering; no graph
  tc netem       none
  apps           none running

[rc=0  0.3s]

================================================================
== DONE -- transcript at /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/50445b3c-51cd-4c3b-9364-d120dd6a72ff/scratchpad/bringup_verify.log
================================================================
```
