# 執行報告 — `link_monitor` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-18T111128Z |
| exercise | `link_monitor` |
| which | `solution` |
| fabric | `tutorials` |
| package | — (tutorials harness) |
| cwd | `/home/adam/tutorials/exercises/link_monitor` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 0 |
| 判定 | **FAIL (3/3)** (exit 1) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `/usr/local/bin/simple_switch_grpc` | `327fa7d172217397` | 1.15.3-f0b7d201 |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/link_monitor/build/link_monitor.p4.p4info.txtpb -o /home/adam/tutorials/exercises/link_monitor/build/link_monitor.json /home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
rc=0  warnings=0

```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/link_monitor/build/link_monitor.json` | 56155 | `b4a2d84b5e5c547b` |
| `/home/adam/tutorials/exercises/link_monitor/build/link_monitor.p4.p4info.txtpb` | 1732 | `7303ccb1dc2c61bf` |

來源 `.p4`：`/home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
```

## 4. 每一步的指令與原始輸出

### 1. L1  h1 starts receive.py

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/link_monitor/receive.py
```

```
(background; output below)
```

### 2. L2  h1 send.py (probes)

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/link_monitor/send.py
```

```
........
```

### 3. L3  h1 receive.py output

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/link_monitor/receive.py
```

```

```

## 5. 判定表

| 結果 | 期望 | 來源等級 | want | got | 依據 |
|---|---|---|---|---|---|
| **FAIL** | injection: probes reached h1 | 【README 宣稱】 | `>=1 report row` | `0 rows` | receive.py:22 prints one 'Switch X - Port Y: Z Mbps' line per probe_data layer |
| **FAIL** | switch ids seen | 【源碼推導，未執行】 | `[1, 2, 3, 4]` | `[]` | send.py's 9 ProbeFwd hops walk s1-s4-s2-s3-s1-s3-s2-s4-s1 over pod-topo |
| **FAIL** | every reported port is non-zero | 【源碼推導，未執行】 | `no 0 port` | `[]` | solution:240 hdr.probe_data[0].port = standard_metadata.egress_port |

## 6. 交換機 log / pcap

- `/home/adam/tutorials/exercises/link_monitor/logs/driver-h1-receive.log`
- `/home/adam/tutorials/exercises/link_monitor/logs/s1-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/link_monitor/logs/s1.log`
- `/home/adam/tutorials/exercises/link_monitor/logs/s2-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/link_monitor/logs/s2.log`
- `/home/adam/tutorials/exercises/link_monitor/logs/s3-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/link_monitor/logs/s3.log`
- `/home/adam/tutorials/exercises/link_monitor/logs/s4-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/link_monitor/logs/s4.log`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s1-eth1_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s1-eth1_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s1-eth2_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s1-eth2_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s1-eth3_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s1-eth3_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s1-eth4_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s1-eth4_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s2-eth1_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s2-eth1_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s2-eth2_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s2-eth2_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s2-eth3_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s2-eth3_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s2-eth4_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s2-eth4_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s3-eth1_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s3-eth1_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s3-eth2_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s3-eth2_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s4-eth1_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s4-eth1_out.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s4-eth2_in.pcap`
- `/home/adam/tutorials/exercises/link_monitor/pcaps/s4-eth2_out.pcap`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- link_monitor / solution
(non-interactive: no mininet CLI, no xterm; kills nothing)

== pre-flight (read-only) ==============================================
OK   ports 9090-9099 free
OK   interpreter /home/adam/p4dev-python-venv/bin/python (3.12.3)
OK   switch  /usr/local/bin/simple_switch_grpc  sha256[:16]=327fa7d172217397  --version=1.15.3-f0b7d201
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/link_monitor

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/link_monitor/build/link_monitor.p4.p4info.txtpb -o /home/adam/tutorials/exercises/link_monitor/build/link_monitor.json /home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4
-> /home/adam/tutorials/exercises/link_monitor/build/link_monitor.json  56155 B  sha256[:16]=b4a2d84b5e5c547b  warnings=0

== plan ================================================================
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
program  : /home/adam/tutorials/exercises/link_monitor/solution/link_monitor.p4 -> build/link_monitor.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : h1 receive.py + h1 send.py probes; assert swid and port fields
equivalent to (cwd must be the exercise dir):
  cd /home/adam/tutorials/exercises/link_monitor && \
  sudo /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/utils/run_exercise.py -t pod-topo/topology.json -j build/link_monitor.json -b /usr/local/bin/simple_switch_grpc
  ... except do_net_cli() is replaced by the scripted steps above.
Reading topology file.
Building mininet topology.
/usr/local/bin/simple_switch_grpc -i 1@s1-eth1 -i 2@s1-eth2 -i 3@s1-eth3 -i 4@s1-eth4 --pcap /home/adam/tutorials/exercises/link_monitor/pcaps --nanolog ipc:///tmp/bm-0-log.ipc --device-id 0 build/link_monitor.json --log-console --thrift-port 9090 -- --grpc-server-addr 0.0.0.0:50051

/usr/local/bin/simple_switch_grpc -i 1@s2-eth1 -i 2@s2-eth2 -i 4@s2-eth4 -i 3@s2-eth3 --pcap /home/adam/tutorials/exercises/link_monitor/pcaps --nanolog ipc:///tmp/bm-1-log.ipc --device-id 1 build/link_monitor.json --log-console --thrift-port 9091 -- --grpc-server-addr 0.0.0.0:50052

/usr/local/bin/simple_switch_grpc -i 1@s3-eth1 -i 2@s3-eth2 --pcap /home/adam/tutorials/exercises/link_monitor/pcaps --nanolog ipc:///tmp/bm-2-log.ipc --device-id 2 build/link_monitor.json --log-console --thrift-port 9092 -- --grpc-server-addr 0.0.0.0:50053

/usr/local/bin/simple_switch_grpc -i 2@s4-eth2 -i 1@s4-eth1 --pcap /home/adam/tutorials/exercises/link_monitor/pcaps --nanolog ipc:///tmp/bm-3-log.ipc --device-id 3 build/link_monitor.json --log-console --thrift-port 9093 -- --grpc-server-addr 0.0.0.0:50054

Configuring switch s1 using P4Runtime with file pod-topo/s1-runtime.json
 - Using P4Info file build/link_monitor.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50051 (bmv2)...
 - Setting pipeline config (build/link_monitor.json)...
 - Inserting 6 table entries...
 - MyEgress.swid: (default action) => MyEgress.set_swid(swid=1)
 - MyIngress.ipv4_lpm: (default action) => MyIngress.drop()
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.1.1', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:01:11, port=1)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.2.2', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:02:22, port=2)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.3.3', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:03:00, port=3)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.4.4', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:04:00, port=4)
Configuring switch s2 using P4Runtime with file pod-topo/s2-runtime.json
 - Using P4Info file build/link_monitor.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50052 (bmv2)...
 - Setting pipeline config (build/link_monitor.json)...
 - Inserting 6 table entries...
 - MyEgress.swid: (default action) => MyEgress.set_swid(swid=2)
 - MyIngress.ipv4_lpm: (default action) => MyIngress.drop()
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.1.1', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:03:00, port=4)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.2.2', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:04:00, port=3)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.3.3', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:03:33, port=1)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.4.4', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:04:44, port=2)
Configuring switch s3 using P4Runtime with file pod-topo/s3-runtime.json
 - Using P4Info file build/link_monitor.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50053 (bmv2)...
 - Setting pipeline config (build/link_monitor.json)...
 - Inserting 6 table entries...
 - MyEgress.swid: (default action) => MyEgress.set_swid(swid=3)
 - MyIngress.ipv4_lpm: (default action) => MyIngress.drop()
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.1.1', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:01:00, port=1)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.2.2', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:01:00, port=1)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.3.3', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:02:00, port=2)
 - MyIngress.ipv4_lpm: hdr.ipv4.dstAddr=['10.0.4.4', 32] => MyIngress.ipv4_forward(dstAddr=08:00:00:00:02:00, port=2)
Configuring switch s4 using P4Runtime with file pod-topo/s4-runtime.json
 - Using P4Info file build/link_monitor.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50054 (bmv2)...
 - Setting pipeline config (build/link_monitor.json)...
 - Inserting 6 table entries...
 - MyEgress.swid: (default action) => MyEgress.set_swid(swid=4)
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
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/link_monitor/receive.py   (> /home/adam/tutorials/exercises/link_monitor/logs/driver-h1-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/link_monitor/send.py   (one probe per second, for 8s)
-- h1 receive.py output (/home/adam/tutorials/exercises/link_monitor/logs/driver-h1-receive.log) --

   FAIL injection: probes reached h1                   want=>=1 report row         got=0 rows
   FAIL switch ids seen                                want=[1, 2, 3, 4]           got=[]
   FAIL every reported port is non-zero                want=no 0 port              got=[]

-- switch logs --
   /home/adam/tutorials/exercises/link_monitor/logs/driver-h1-receive.log 0 B
   /home/adam/tutorials/exercises/link_monitor/logs/s1-p4runtime-requests.txt 3035 B
   /home/adam/tutorials/exercises/link_monitor/logs/s1.log 917139 B
   /home/adam/tutorials/exercises/link_monitor/logs/s2-p4runtime-requests.txt 3109 B
   /home/adam/tutorials/exercises/link_monitor/logs/s2.log 761915 B
   /home/adam/tutorials/exercises/link_monitor/logs/s3-p4runtime-requests.txt 3115 B
   /home/adam/tutorials/exercises/link_monitor/logs/s3.log 562836 B
   /home/adam/tutorials/exercises/link_monitor/logs/s4-p4runtime-requests.txt 3115 B
   /home/adam/tutorials/exercises/link_monitor/logs/s4.log 483846 B

== net.stop() ==========================================================
net.stop() returned cleanly

== verdict =============================================================
   FAIL injection: probes reached h1                   want=>=1 report row         got=0 rows   【README 宣稱】
   FAIL switch ids seen                                want=[1, 2, 3, 4]           got=[]   【源碼推導，未執行】
   FAIL every reported port is non-zero                want=no 0 port              got=[]   【源碼推導，未執行】

>>> FAIL (3/3)
```

### stderr（mininet 的 logger 走這裡）

```

```
