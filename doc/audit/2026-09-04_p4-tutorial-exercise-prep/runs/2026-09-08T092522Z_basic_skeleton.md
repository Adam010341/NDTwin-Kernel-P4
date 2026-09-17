# 執行報告 — `basic` / skeleton

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-08T092522Z |
| exercise | `basic` |
| which | `skeleton` |
| cwd | `/home/adam/tutorials/exercises/basic` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 0 |
| 判定 | **PASS (4/4)** (exit 0) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `/usr/local/bin/simple_switch_grpc` | `327fa7d172217397` | 1.15.3-f0b7d201 |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/basic/build/basic.p4.p4info.txtpb -o /home/adam/tutorials/exercises/basic/build/basic.json /home/adam/tutorials/exercises/basic/basic.p4
rc=0  warnings=5
/home/adam/tutorials/exercises/basic/basic.p4(7): [--Wwarn=unused] warning: 'TYPE_IPV4' is unused
const bit<16> TYPE_IPV4 = 0x800;
              ^^^^^^^^^
/home/adam/tutorials/exercises/basic/basic.p4(119): [--Wwarn=unused] warning: 'dstAddr' is unused
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
                                  ^^^^^^^
/home/adam/tutorials/exercises/basic/basic.p4(119): [--Wwarn=unused] warning: 'port' is unused
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
                                                        ^^^^
/home/adam/tutorials/exercises/basic/basic.p4(119): [--Wwarn=unused] warning: Unused action parameter dstAddr
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
                                  ^^^^^^^
/home/adam/tutorials/exercises/basic/basic.p4(119): [--Wwarn=unused] warning: Unused action parameter port
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
                                                        ^^^^
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/basic/build/basic.json` | 9282 | `7fefd0e1e6ae734d` |
| `/home/adam/tutorials/exercises/basic/build/basic.p4.p4info.txtpb` | 943 | `f71c1fb75f39c62d` |

來源 `.p4`：`/home/adam/tutorials/exercises/basic/basic.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
```

## 4. 每一步的指令與原始輸出

### 1. B1  net.pingAll(timeout=1)

```
$ net.pingAll(timeout=1)
```

```
loss = 100.0%
```

### 2. B2  h1 ping -c3 h2

```
$ ping -c 3 -W 1 10.0.2.2
```

```
PING 10.0.2.2 (10.0.2.2) 56(84) bytes of data.

--- 10.0.2.2 ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2067ms
```

### 3. B3  h2 starts the sniffer

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic/receive.py
```

```
(background; output below)
```

### 4. B4  h1 send.py -> h2

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic/send.py 10.0.2.2 P4 driver probe
```

```
sending on interface eth0 to 10.0.2.2
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 55
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = tcp
     chksum    = 0x63be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ TCP ]### 
        sport     = 59768
        dport     = 1234
        seq       = 0
        ack       = 0
        dataofs   = 5
        reserved  = 0
        flags     = S
        window    = 8192
        chksum    = 0x7a29
        urgptr    = 0
        options   = []
###[ Raw ]### 
           load      = 'P4 driver probe'
```

### 5. B5  h2 sniffer output

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic/receive.py
```

```
sniffing on eth0
```

## 5. 判定表

| 結果 | 期望 | 來源等級 | want | got | 依據 |
|---|---|---|---|---|---|
| PASS | injection: send.py emitted 1 TCP frame | 【源碼推導，未執行】 | `1` | `1` | basic/send.py:34 prints before sendp(); dport 1234 is what receive.py filters on |
| PASS | pingAll packet loss | 【README 宣稱】＋【源碼推導，未執行】 | `100.0%` | `100.0%` | see the derivation in DRIVER.md: basic.p4:66-74 / :119-129 / :147 / :202-211 |
| PASS | h1 ping -c3 h2 received | 【源碼推導，未執行】 | `0` | `0` | - |
| PASS | h2 got the send.py packet | 【源碼推導，未執行】 | `0` | `0` | - |

## 6. 交換機 log / pcap

- `/home/adam/tutorials/exercises/basic/logs/driver-h2-receive.log`
- `/home/adam/tutorials/exercises/basic/logs/s1-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/basic/logs/s1.log`
- `/home/adam/tutorials/exercises/basic/logs/s2-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/basic/logs/s2.log`
- `/home/adam/tutorials/exercises/basic/logs/s3-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/basic/logs/s3.log`
- `/home/adam/tutorials/exercises/basic/logs/s4-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/basic/logs/s4.log`
- `/home/adam/tutorials/exercises/basic/pcaps/s1-eth1_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s1-eth1_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s1-eth2_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s1-eth2_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s1-eth3_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s1-eth3_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s1-eth4_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s1-eth4_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s2-eth1_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s2-eth1_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s2-eth2_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s2-eth2_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s2-eth3_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s2-eth3_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s2-eth4_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s2-eth4_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s3-eth1_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s3-eth1_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s3-eth2_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s3-eth2_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s4-eth1_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s4-eth1_out.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s4-eth2_in.pcap`
- `/home/adam/tutorials/exercises/basic/pcaps/s4-eth2_out.pcap`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- basic / skeleton
(non-interactive: no mininet CLI, no xterm; kills nothing)

== pre-flight (read-only) ==============================================
OK   ports 9090-9099 free
OK   interpreter /home/adam/p4dev-python-venv/bin/python (3.12.3)
OK   switch  /usr/local/bin/simple_switch_grpc  sha256[:16]=327fa7d172217397  --version=1.15.3-f0b7d201
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/basic

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/basic/build/basic.p4.p4info.txtpb -o /home/adam/tutorials/exercises/basic/build/basic.json /home/adam/tutorials/exercises/basic/basic.p4
/home/adam/tutorials/exercises/basic/basic.p4(7): [--Wwarn=unused] warning: 'TYPE_IPV4' is unused
const bit<16> TYPE_IPV4 = 0x800;
              ^^^^^^^^^
/home/adam/tutorials/exercises/basic/basic.p4(119): [--Wwarn=unused] warning: 'dstAddr' is unused
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
                                  ^^^^^^^
/home/adam/tutorials/exercises/basic/basic.p4(119): [--Wwarn=unused] warning: 'port' is unused
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
                                                        ^^^^
/home/adam/tutorials/exercises/basic/basic.p4(119): [--Wwarn=unused] warning: Unused action parameter dstAddr
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
                                  ^^^^^^^
/home/adam/tutorials/exercises/basic/basic.p4(119): [--Wwarn=unused] warning: Unused action parameter port
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
                                                        ^^^^
-> /home/adam/tutorials/exercises/basic/build/basic.json  9282 B  sha256[:16]=7fefd0e1e6ae734d  warnings=5

== plan ================================================================
topology : pod-topo/topology.json
hosts    : h1, h2, h3, h4
switches : s1, s2, s3, s4
links    : 8
program  : /home/adam/tutorials/exercises/basic/basic.p4 -> build/basic.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : net.pingAll; h1 ping -c3 h2; h1 send.py -> h2 receive.py; assert loss
equivalent to (cwd must be the exercise dir):
  cd /home/adam/tutorials/exercises/basic && \
  sudo /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/utils/run_exercise.py -t pod-topo/topology.json -j build/basic.json -b /usr/local/bin/simple_switch_grpc
  ... except do_net_cli() is replaced by the scripted steps above.
Reading topology file.
Building mininet topology.
/usr/local/bin/simple_switch_grpc -i 1@s1-eth1 -i 2@s1-eth2 -i 3@s1-eth3 -i 4@s1-eth4 --pcap /home/adam/tutorials/exercises/basic/pcaps --nanolog ipc:///tmp/bm-0-log.ipc --device-id 0 build/basic.json --log-console --thrift-port 9090 -- --grpc-server-addr 0.0.0.0:50051

/usr/local/bin/simple_switch_grpc -i 1@s2-eth1 -i 2@s2-eth2 -i 4@s2-eth4 -i 3@s2-eth3 --pcap /home/adam/tutorials/exercises/basic/pcaps --nanolog ipc:///tmp/bm-1-log.ipc --device-id 1 build/basic.json --log-console --thrift-port 9091 -- --grpc-server-addr 0.0.0.0:50052

/usr/local/bin/simple_switch_grpc -i 1@s3-eth1 -i 2@s3-eth2 --pcap /home/adam/tutorials/exercises/basic/pcaps --nanolog ipc:///tmp/bm-2-log.ipc --device-id 2 build/basic.json --log-console --thrift-port 9092 -- --grpc-server-addr 0.0.0.0:50053

/usr/local/bin/simple_switch_grpc -i 2@s4-eth2 -i 1@s4-eth1 --pcap /home/adam/tutorials/exercises/basic/pcaps --nanolog ipc:///tmp/bm-3-log.ipc --device-id 3 build/basic.json --log-console --thrift-port 9093 -- --grpc-server-addr 0.0.0.0:50054

Configuring switch s1 using P4Runtime with file pod-topo/s1-runtime.json
 - Using P4Info file build/basic.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50051 (bmv2)...
 - Setting pipeline config (build/basic.json)...
 - Inserting 5 table entries...
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
$ mininet: net.pingAll(timeout=1)
-> pingAll loss = 100.0%
$ h1: ping -c 3 -W 1 10.0.2.2
PING 10.0.2.2 (10.0.2.2) 56(84) bytes of data.

--- 10.0.2.2 ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2067ms
$ h2: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic/receive.py   (> /home/adam/tutorials/exercises/basic/logs/driver-h2-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/basic/send.py 10.0.2.2 P4 driver probe
sending on interface eth0 to 10.0.2.2
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 55
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = tcp
     chksum    = 0x63be
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ TCP ]### 
        sport     = 59768
        dport     = 1234
        seq       = 0
        ack       = 0
        dataofs   = 5
        reserved  = 0
        flags     = S
        window    = 8192
        chksum    = 0x7a29
        urgptr    = 0
        options   = []
###[ Raw ]### 
           load      = 'P4 driver probe'


-- h2 receive.py output (/home/adam/tutorials/exercises/basic/logs/driver-h2-receive.log) --
sniffing on eth0

   PASS injection: send.py emitted 1 TCP frame         want=1                      got=1
   PASS pingAll packet loss                            want=100.0%                 got=100.0%
   PASS h1 ping -c3 h2 received                        want=0                      got=0
   PASS h2 got the send.py packet                      want=0                      got=0

-- switch logs --
   /home/adam/tutorials/exercises/basic/logs/driver-h2-receive.log 17 B
   /home/adam/tutorials/exercises/basic/logs/s1-p4runtime-requests.txt 2670 B
   /home/adam/tutorials/exercises/basic/logs/s1.log     206162 B
   /home/adam/tutorials/exercises/basic/logs/s2-p4runtime-requests.txt 2731 B
   /home/adam/tutorials/exercises/basic/logs/s2.log     191968 B
   /home/adam/tutorials/exercises/basic/logs/s3-p4runtime-requests.txt 2737 B
   /home/adam/tutorials/exercises/basic/logs/s3.log     118681 B
   /home/adam/tutorials/exercises/basic/logs/s4-p4runtime-requests.txt 2737 B
   /home/adam/tutorials/exercises/basic/logs/s4.log     116551 B

== net.stop() ==========================================================
net.stop() returned cleanly

== verdict =============================================================
   PASS injection: send.py emitted 1 TCP frame         want=1                      got=1   【源碼推導，未執行】
   PASS pingAll packet loss                            want=100.0%                 got=100.0%   【README 宣稱】＋【源碼推導，未執行】
   PASS h1 ping -c3 h2 received                        want=0                      got=0   【源碼推導，未執行】
   PASS h2 got the send.py packet                      want=0                      got=0   【源碼推導，未執行】

>>> PASS (4/4)
```

### stderr（mininet 的 logger 走這裡）

```
*** Ping: testing ping reachability
h1 -> X X X 
h2 -> X X X 
h3 -> X X X 
h4 -> X X X 
*** Results: 100% dropped (0/12 received)
```
