# 執行報告 — `firewall` / skeleton

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-18T111149Z |
| exercise | `firewall` |
| which | `skeleton` |
| fabric | `tutorials` |
| package | — (tutorials harness) |
| cwd | `/home/adam/tutorials/exercises/firewall` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 0 |
| 判定 | **PASS (3/3)** (exit 0) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `/usr/local/bin/simple_switch_grpc` | `327fa7d172217397` | 1.15.3-f0b7d201 |
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

## 4. 每一步的指令與原始輸出

### 1. pingall -- every ordered pair, ping -c 5 -W 2

```
$ ping -c 5 -W 2 <each ordered pair>
```

```
0% (12/12 pairs at 0%, 0 lossy)
```

### 2. F1  iperf h1 -> h3 (internal to external)

```
$ iperf -s on h3; iperf -c 10.0.3.3 -t 3 on h1
```

```
client:
------------------------------------------------------------
Client connecting to 10.0.3.3, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.1.1 port 54316 connected with 10.0.3.3 port 5001 (icwnd/mss/irtt=14/1448/9533)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.4757 sec  7.25 MBytes  17.5 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.3.3 port 5001 connected with 10.0.1.1 port 54316 (icwnd/mss/irtt=14/1448/8167)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.4560 sec  7.25 MBytes  17.6 Mbits/sec
```

### 3. F2  iperf h3 -> h1 (external to internal)

```
$ iperf -s on h1; iperf -c 10.0.1.1 -t 3 on h3
```

```
client:
------------------------------------------------------------
Client connecting to 10.0.1.1, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.3.3 port 48216 connected with 10.0.1.1 port 5001 (icwnd/mss/irtt=14/1448/8837)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.5980 sec  4.75 MBytes  11.1 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.1.1 port 5001 connected with 10.0.3.3 port 48216 (icwnd/mss/irtt=14/1448/7969)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.5650 sec  4.75 MBytes  11.2 Mbits/sec
```

## 5. 判定表

| 結果 | 期望 | 來源等級 | want | got | 依據 |
|---|---|---|---|---|---|
| PASS | iperf h1 -> h3 (internal -> external) | 【README 宣稱】＋【源碼推導，未執行】 | `connects` | `connects` | README step 1.2; firewall.p4 ipv4_lpm forwards in both arms |
| PASS | RED ARM: iperf h3 -> h1 must connect | 【README 宣稱】＋【源碼推導，未執行】 | `connects` | `connects` | README step 1.2: with the firewall unimplemented h3 -> h1 works. If this is red the solution's block proves nothing -- the red arm is not red. |
| PASS | the fabric forwards (pingall) | 【源碼推導，未執行】 | `0.0%` | `0% (12/12 pairs at 0%, 0 lossy)` | the skeleton is basic.p4 plus unfilled TODOs; nothing in it drops ICMP |

## 6. 交換機 log / pcap

- `/home/adam/tutorials/exercises/firewall/logs/driver-iperf-h1-to-h3.log`
- `/home/adam/tutorials/exercises/firewall/logs/driver-iperf-h3-to-h1.log`
- `/home/adam/tutorials/exercises/firewall/logs/s1-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/firewall/logs/s1.log`
- `/home/adam/tutorials/exercises/firewall/logs/s2-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/firewall/logs/s2.log`
- `/home/adam/tutorials/exercises/firewall/logs/s3-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/firewall/logs/s3.log`
- `/home/adam/tutorials/exercises/firewall/logs/s4-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/firewall/logs/s4.log`
- `/home/adam/tutorials/exercises/firewall/pcaps/s1-eth1_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s1-eth1_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s1-eth2_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s1-eth2_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s1-eth3_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s1-eth3_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s1-eth4_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s1-eth4_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s2-eth1_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s2-eth1_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s2-eth2_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s2-eth2_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s2-eth3_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s2-eth3_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s2-eth4_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s2-eth4_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s3-eth1_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s3-eth1_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s3-eth2_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s3-eth2_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s4-eth1_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s4-eth1_out.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s4-eth2_in.pcap`
- `/home/adam/tutorials/exercises/firewall/pcaps/s4-eth2_out.pcap`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- firewall / skeleton
(non-interactive: no mininet CLI, no xterm; kills nothing)

== pre-flight (read-only) ==============================================
OK   ports 9090-9099 free
OK   interpreter /home/adam/p4dev-python-venv/bin/python (3.12.3)
OK   switch  /usr/local/bin/simple_switch_grpc  sha256[:16]=327fa7d172217397  --version=1.15.3-f0b7d201
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
equivalent to (cwd must be the exercise dir):
  cd /home/adam/tutorials/exercises/firewall && \
  sudo /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/utils/run_exercise.py -t pod-topo/topology.json -j build/basic.json -b /usr/local/bin/simple_switch_grpc
  ... except do_net_cli() is replaced by the scripted steps above.
Reading topology file.
Building mininet topology.
/usr/local/bin/simple_switch_grpc -i 1@s1-eth1 -i 2@s1-eth2 -i 3@s1-eth3 -i 4@s1-eth4 --pcap /home/adam/tutorials/exercises/firewall/pcaps --nanolog ipc:///tmp/bm-0-log.ipc --device-id 0 build/firewall.json --log-console --thrift-port 9090 -- --grpc-server-addr 0.0.0.0:50051

/usr/local/bin/simple_switch_grpc -i 1@s2-eth1 -i 2@s2-eth2 -i 4@s2-eth4 -i 3@s2-eth3 --pcap /home/adam/tutorials/exercises/firewall/pcaps --nanolog ipc:///tmp/bm-1-log.ipc --device-id 1 build/basic.json --log-console --thrift-port 9091 -- --grpc-server-addr 0.0.0.0:50052

/usr/local/bin/simple_switch_grpc -i 1@s3-eth1 -i 2@s3-eth2 --pcap /home/adam/tutorials/exercises/firewall/pcaps --nanolog ipc:///tmp/bm-2-log.ipc --device-id 2 build/basic.json --log-console --thrift-port 9092 -- --grpc-server-addr 0.0.0.0:50053

/usr/local/bin/simple_switch_grpc -i 2@s4-eth2 -i 1@s4-eth1 --pcap /home/adam/tutorials/exercises/firewall/pcaps --nanolog ipc:///tmp/bm-3-log.ipc --device-id 3 build/basic.json --log-console --thrift-port 9093 -- --grpc-server-addr 0.0.0.0:50054

Configuring switch s1 using P4Runtime with file pod-topo/s1-runtime.json
 - Using P4Info file build/firewall.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50051 (bmv2)...
 - Setting pipeline config (build/firewall.json)...
 - Inserting 13 table entries...
 - MyIngress.check_ports: standard_metadata.ingress_port=1, standard_metadata.egress_spec=3 => MyIngress.set_direction(dir=0)
 - MyIngress.check_ports: standard_metadata.ingress_port=1, standard_metadata.egress_spec=4 => MyIngress.set_direction(dir=0)
 - MyIngress.check_ports: standard_metadata.ingress_port=2, standard_metadata.egress_spec=3 => MyIngress.set_direction(dir=0)
 - MyIngress.check_ports: standard_metadata.ingress_port=2, standard_metadata.egress_spec=4 => MyIngress.set_direction(dir=0)
 - MyIngress.check_ports: standard_metadata.ingress_port=3, standard_metadata.egress_spec=1 => MyIngress.set_direction(dir=1)
 - MyIngress.check_ports: standard_metadata.ingress_port=3, standard_metadata.egress_spec=2 => MyIngress.set_direction(dir=1)
 - MyIngress.check_ports: standard_metadata.ingress_port=4, standard_metadata.egress_spec=1 => MyIngress.set_direction(dir=1)
 - MyIngress.check_ports: standard_metadata.ingress_port=4, standard_metadata.egress_spec=2 => MyIngress.set_direction(dir=1)
 - MyIngress.ipv4_lpm: (default action) => MyIngress.drop()
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.1.1', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:01:11, port=1)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.2.2', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:02:22, port=2)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.3.3', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:03:00, port=3)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.4.4', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:04:00, port=4)
Configuring switch s2 using P4Runtime with file pod-topo/s2-runtime.json
 - Using P4Info file build/basic.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50052 (bmv2)...
 - Setting pipeline config (build/basic.json)...
 - Inserting 5 table entries...
 - MyIngress.ipv4_lpm: (default action) => MyIngress.drop()
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.1.1', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:03:00, port=4)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.2.2', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:04:00, port=3)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.3.3', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:03:33, port=1)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.4.4', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:04:44, port=2)
Configuring switch s3 using P4Runtime with file pod-topo/s3-runtime.json
 - Using P4Info file build/basic.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50053 (bmv2)...
 - Setting pipeline config (build/basic.json)...
 - Inserting 5 table entries...
 - MyIngress.ipv4_lpm: (default action) => MyIngress.drop()
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.1.1', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:01:00, port=1)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.2.2', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:01:00, port=1)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.3.3', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:02:00, port=2)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.4.4', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:02:00, port=2)
Configuring switch s4 using P4Runtime with file pod-topo/s4-runtime.json
 - Using P4Info file build/basic.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50054 (bmv2)...
 - Setting pipeline config (build/basic.json)...
 - Inserting 5 table entries...
 - MyIngress.ipv4_lpm: (default action) => MyIngress.drop()
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.1.1', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:01:00, port=2)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.2.2', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:01:00, port=2)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.3.3', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:02:00, port=1)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.4.4', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:02:00, port=1)

== topology as brought up ==============================================
s1 -> gRPC port: 50051
s2 -> gRPC port: 50052
s3 -> gRPC port: 50053
s4 -> gRPC port: 50054
**********
h1
default interface: eth0	10.0.1.1	08:00:00:00:01:11
**********
**********
h2
default interface: eth0	10.0.2.2	08:00:00:00:02:22
**********
**********
h3
default interface: eth0	10.0.3.3	08:00:00:00:03:33
**********
**********
h4
default interface: eth0	10.0.4.4	08:00:00:00:04:44
**********

== scripted steps (no CLI, no xterm) ===================================
$ every ordered host pair: ping -c 5 -W 2, loss parsed from ping's summary
-> pingall 0% (12/12 pairs at 0%, 0 lossy)
$ h3: iperf -s   (> /home/adam/tutorials/exercises/firewall/logs/driver-iperf-h1-to-h3.log)
$ h1: iperf -c 10.0.3.3 -t 3
client:
------------------------------------------------------------
Client connecting to 10.0.3.3, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.1.1 port 54316 connected with 10.0.3.3 port 5001 (icwnd/mss/irtt=14/1448/9533)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.4757 sec  7.25 MBytes  17.5 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.3.3 port 5001 connected with 10.0.1.1 port 54316 (icwnd/mss/irtt=14/1448/8167)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.4560 sec  7.25 MBytes  17.6 Mbits/sec


   PASS iperf h1 -> h3 (internal -> external)          want=connects               got=connects
$ h1: iperf -s   (> /home/adam/tutorials/exercises/firewall/logs/driver-iperf-h3-to-h1.log)
$ h3: iperf -c 10.0.1.1 -t 3
client:
------------------------------------------------------------
Client connecting to 10.0.1.1, TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.3.3 port 48216 connected with 10.0.1.1 port 5001 (icwnd/mss/irtt=14/1448/8837)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.5980 sec  4.75 MBytes  11.1 Mbits/sec

server:
------------------------------------------------------------
Server listening on TCP port 5001
TCP window size: 85.3 KByte (default)
------------------------------------------------------------
[  1] local 10.0.1.1 port 5001 connected with 10.0.3.3 port 48216 (icwnd/mss/irtt=14/1448/7969)
[ ID] Interval       Transfer     Bandwidth
[  1] 0.0000-3.5650 sec  4.75 MBytes  11.2 Mbits/sec


   PASS RED ARM: iperf h3 -> h1 must connect           want=connects               got=connects
   PASS the fabric forwards (pingall)                  want=0.0%                   got=0% (12/12 pairs at 0%, 0 lossy)

-- switch logs --
   /home/adam/tutorials/exercises/firewall/logs/driver-iperf-h1-to-h3.log 387 B
   /home/adam/tutorials/exercises/firewall/logs/driver-iperf-h3-to-h1.log 387 B
   /home/adam/tutorials/exercises/firewall/logs/s1-p4runtime-requests.txt 6886 B
   /home/adam/tutorials/exercises/firewall/logs/s1.log  106978778 B
   /home/adam/tutorials/exercises/firewall/logs/s2-p4runtime-requests.txt 2731 B
   /home/adam/tutorials/exercises/firewall/logs/s2.log  45939568 B
   /home/adam/tutorials/exercises/firewall/logs/s3-p4runtime-requests.txt 2737 B
   /home/adam/tutorials/exercises/firewall/logs/s3.log  45642349 B
   /home/adam/tutorials/exercises/firewall/logs/s4-p4runtime-requests.txt 2737 B
   /home/adam/tutorials/exercises/firewall/logs/s4.log  243432 B

== net.stop() ==========================================================
net.stop() returned cleanly

== verdict =============================================================
   PASS iperf h1 -> h3 (internal -> external)          want=connects               got=connects   【README 宣稱】＋【源碼推導，未執行】
   PASS RED ARM: iperf h3 -> h1 must connect           want=connects               got=connects   【README 宣稱】＋【源碼推導，未執行】
   PASS the fabric forwards (pingall)                  want=0.0%                   got=0% (12/12 pairs at 0%, 0 lossy)   【源碼推導，未執行】

>>> PASS (3/3)
```

### stderr（mininet 的 logger 走這裡）

```

```
