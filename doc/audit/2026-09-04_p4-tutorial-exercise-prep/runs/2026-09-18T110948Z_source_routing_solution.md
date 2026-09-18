# 執行報告 — `source_routing` / solution

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-18T110948Z |
| exercise | `source_routing` |
| which | `solution` |
| fabric | `tutorials` |
| package | — (tutorials harness) |
| cwd | `/home/adam/tutorials/exercises/source_routing` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 0 |
| 判定 | **PASS (5/5)** (exit 0) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `/usr/local/bin/simple_switch_grpc` | `327fa7d172217397` | 1.15.3-f0b7d201 |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/source_routing/build/source_routing.p4.p4info.txtpb -o /home/adam/tutorials/exercises/source_routing/build/source_routing.json /home/adam/tutorials/exercises/source_routing/solution/source_routing.p4
rc=0  warnings=1
/home/adam/tutorials/exercises/source_routing/solution/source_routing.p4(16): [--Wwarn=unused] warning: 'egressSpec_t' is unused
typedef bit<9> egressSpec_t;
               ^^^^^^^^^^^^
```

| 產物 | bytes | sha256[:16] |
|---|---|---|
| `/home/adam/tutorials/exercises/source_routing/build/source_routing.json` | 19572 | `58f74ed1d535c77e` |
| `/home/adam/tutorials/exercises/source_routing/build/source_routing.p4.p4info.txtpb` | 539 | `5c22f4d5b3ff87b1` |

來源 `.p4`：`/home/adam/tutorials/exercises/source_routing/solution/source_routing.p4`（編到骨架的輸出檔名，`.p4` 原始檔一個字沒動）

## 3. 拓樸

```
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
```

## 4. 每一步的指令與原始輸出

### 1. S1  h2 starts the sniffer

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/source_routing/receive.py
```

```
(background; output below)
```

### 2. S2  h1 sends 2 packets

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/source_routing/send.py 10.0.2.2   <<< b'2 3 2 2 1\n2 1\nq\n'
```

```
sending on interface eth0 to 10.0.2.2

Type space separated port nums (example: "2 3 2 2 1") or "q" to quit: 
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1234
###[ SourceRoute ]### 
     bos       = 0
     port      = 2
###[ SourceRoute ]### 
        bos       = 0
        port      = 3
###[ SourceRoute ]### 
           bos       = 0
           port      = 2
###[ SourceRoute ]### 
              bos       = 0
              port      = 2
###[ SourceRoute ]### 
                 bos       = 1
                 port      = 1
###[ IP ]### 
                    version   = 4
                    ihl       = 5
                    tos       = 0x0
                    len       = 28
                    id        = 1
                    flags     = 
                    frag      = 0
                    ttl       = 64
                    proto     = udp
                    chksum    = 0x63ce
                    src       = 10.0.1.1
                    dst       = 10.0.2.2
                    \options   \
###[ UDP ]### 
                       sport     = 1234
                       dport     = 4321
                       len       = 8
                       chksum    = 0xd328


Type space separated port nums (example: "2 3 2 2 1") or "q" to quit: 
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1234
###[ SourceRoute ]### 
     bos       = 0
     port      = 2
###[ SourceRoute ]### 
        bos       = 1
        port      = 1
###[ IP ]### 
           version   = 4
           ihl       = 5
           tos       = 0x0
           len       = 28
           id        = 1
           flags     = 
           frag      = 0
           ttl       = 64
           proto     = udp
           chksum    = 0x63ce
           src       = 10.0.1.1
           dst       = 10.0.2.2
           \options   \
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 8
              chksum    = 0xd328


Type space separated port nums (example: "2 3 2 2 1") or "q" to quit:
```

### 3. S3  h2 sniffer output

```
$ /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/source_routing/receive.py
```

```
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 28
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 59
     proto     = udp
     chksum    = 0x63ce
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 8
        chksum    = 0xd328

got a packet
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 28
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x63ce
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 8
        chksum    = 0xd328
```

## 5. 判定表

| 結果 | 期望 | 來源等級 | want | got | 依據 |
|---|---|---|---|---|---|
| PASS | injection: send.py built 2 srcroute frames | 【源碼推導，未執行】 | `2` | `2` | send.py:72 pkt.show2() before sendp(); type 0x1234 = SourceRoute stack present |
| PASS | h2 received packet count | 【README 宣稱】＋【源碼推導，未執行】 | `2` | `2` | README step 3: the message should be delivered |
| PASS | ttl multiset {2 3 2 2 1 ; 2 1} | 【README 宣稱】＋【源碼推導，未執行】 | `[59, 62]` | `[59, 62]` | M7 section 2: 5 hops -> 64-5=59; shortest path 2 hops -> 62 |
| PASS | no SourceRoute layer left at h2 | 【源碼推導，未執行】 | `0 blocks` | `0 blocks` | solution:116 pop_front(1) per hop, :120 srcRoute_finish restores 0x800 |
| PASS | ethertype seen by h2 | 【源碼推導，未執行】 | `IPv4 (0x800)` | `['IPv4', 'IPv4']` | scapy show2() renders 0x800 as the name 'IPv4', not the number |

## 6. 交換機 log / pcap

- `/home/adam/tutorials/exercises/source_routing/logs/driver-h2-receive.log`
- `/home/adam/tutorials/exercises/source_routing/logs/s1-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/source_routing/logs/s1.log`
- `/home/adam/tutorials/exercises/source_routing/logs/s2-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/source_routing/logs/s2.log`
- `/home/adam/tutorials/exercises/source_routing/logs/s3-p4runtime-requests.txt`
- `/home/adam/tutorials/exercises/source_routing/logs/s3.log`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s1-eth1_in.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s1-eth1_out.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s1-eth2_in.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s1-eth2_out.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s1-eth3_in.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s1-eth3_out.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s2-eth1_in.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s2-eth1_out.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s2-eth2_in.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s2-eth2_out.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s2-eth3_in.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s2-eth3_out.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s3-eth1_in.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s3-eth1_out.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s3-eth2_in.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s3-eth2_out.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s3-eth3_in.pcap`
- `/home/adam/tutorials/exercises/source_routing/pcaps/s3-eth3_out.pcap`

## 8. 完整 transcript

### stdout

```
drive_exercise.py -- source_routing / solution
(non-interactive: no mininet CLI, no xterm; kills nothing)

== pre-flight (read-only) ==============================================
OK   ports 9090-9099 free
OK   interpreter /home/adam/p4dev-python-venv/bin/python (3.12.3)
OK   switch  /usr/local/bin/simple_switch_grpc  sha256[:16]=327fa7d172217397  --version=1.15.3-f0b7d201
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/source_routing

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/source_routing/build/source_routing.p4.p4info.txtpb -o /home/adam/tutorials/exercises/source_routing/build/source_routing.json /home/adam/tutorials/exercises/source_routing/solution/source_routing.p4
/home/adam/tutorials/exercises/source_routing/solution/source_routing.p4(16): [--Wwarn=unused] warning: 'egressSpec_t' is unused
typedef bit<9> egressSpec_t;
               ^^^^^^^^^^^^
-> /home/adam/tutorials/exercises/source_routing/build/source_routing.json  19572 B  sha256[:16]=58f74ed1d535c77e  warnings=1

== plan ================================================================
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
program  : /home/adam/tutorials/exercises/source_routing/solution/source_routing.p4 -> build/source_routing.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : h2 receive.py; h1 send.py 10.0.2.2 with '2 3 2 2 1' then '2 1'; assert packet count + ttl
equivalent to (cwd must be the exercise dir):
  cd /home/adam/tutorials/exercises/source_routing && \
  sudo /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/utils/run_exercise.py -t topology.json -j build/source_routing.json -b /usr/local/bin/simple_switch_grpc
  ... except do_net_cli() is replaced by the scripted steps above.
Reading topology file.
Building mininet topology.
/usr/local/bin/simple_switch_grpc -i 1@s1-eth1 -i 2@s1-eth2 -i 3@s1-eth3 --pcap /home/adam/tutorials/exercises/source_routing/pcaps --nanolog ipc:///tmp/bm-0-log.ipc --device-id 0 build/source_routing.json --log-console --thrift-port 9090 -- --grpc-server-addr 0.0.0.0:50051

/usr/local/bin/simple_switch_grpc -i 1@s2-eth1 -i 2@s2-eth2 -i 3@s2-eth3 --pcap /home/adam/tutorials/exercises/source_routing/pcaps --nanolog ipc:///tmp/bm-1-log.ipc --device-id 1 build/source_routing.json --log-console --thrift-port 9091 -- --grpc-server-addr 0.0.0.0:50052

/usr/local/bin/simple_switch_grpc -i 1@s3-eth1 -i 2@s3-eth2 -i 3@s3-eth3 --pcap /home/adam/tutorials/exercises/source_routing/pcaps --nanolog ipc:///tmp/bm-2-log.ipc --device-id 2 build/source_routing.json --log-console --thrift-port 9092 -- --grpc-server-addr 0.0.0.0:50053

Configuring switch s1 using P4Runtime with file s1-runtime.json
 - Using P4Info file build/source_routing.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50051 (bmv2)...
 - Setting pipeline config (build/source_routing.json)...
 - Inserting 0 table entries...
Configuring switch s2 using P4Runtime with file s2-runtime.json
 - Using P4Info file build/source_routing.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50052 (bmv2)...
 - Setting pipeline config (build/source_routing.json)...
 - Inserting 0 table entries...
Configuring switch s3 using P4Runtime with file s3-runtime.json
 - Using P4Info file build/source_routing.p4.p4info.txtpb...
 - Connecting to P4Runtime server on 127.0.0.1:50053 (bmv2)...
 - Setting pipeline config (build/source_routing.json)...
 - Inserting 0 table entries...

== topology as brought up ==============================================
s1 -> gRPC port: 50051
s2 -> gRPC port: 50052
s3 -> gRPC port: 50053
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

== scripted steps (no CLI, no xterm) ===================================
$ h2: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/source_routing/receive.py   (> /home/adam/tutorials/exercises/source_routing/logs/driver-h2-receive.log)
$ h1: /home/adam/p4dev-python-venv/bin/python /home/adam/tutorials/exercises/source_routing/send.py 10.0.2.2   <<< b'2 3 2 2 1\n2 1\nq\n'
sending on interface eth0 to 10.0.2.2

Type space separated port nums (example: "2 3 2 2 1") or "q" to quit: 
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1234
###[ SourceRoute ]### 
     bos       = 0
     port      = 2
###[ SourceRoute ]### 
        bos       = 0
        port      = 3
###[ SourceRoute ]### 
           bos       = 0
           port      = 2
###[ SourceRoute ]### 
              bos       = 0
              port      = 2
###[ SourceRoute ]### 
                 bos       = 1
                 port      = 1
###[ IP ]### 
                    version   = 4
                    ihl       = 5
                    tos       = 0x0
                    len       = 28
                    id        = 1
                    flags     = 
                    frag      = 0
                    ttl       = 64
                    proto     = udp
                    chksum    = 0x63ce
                    src       = 10.0.1.1
                    dst       = 10.0.2.2
                    \options   \
###[ UDP ]### 
                       sport     = 1234
                       dport     = 4321
                       len       = 8
                       chksum    = 0xd328


Type space separated port nums (example: "2 3 2 2 1") or "q" to quit: 
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = 0x1234
###[ SourceRoute ]### 
     bos       = 0
     port      = 2
###[ SourceRoute ]### 
        bos       = 1
        port      = 1
###[ IP ]### 
           version   = 4
           ihl       = 5
           tos       = 0x0
           len       = 28
           id        = 1
           flags     = 
           frag      = 0
           ttl       = 64
           proto     = udp
           chksum    = 0x63ce
           src       = 10.0.1.1
           dst       = 10.0.2.2
           \options   \
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 8
              chksum    = 0xd328


Type space separated port nums (example: "2 3 2 2 1") or "q" to quit: 
-- h2 receive.py output (/home/adam/tutorials/exercises/source_routing/logs/driver-h2-receive.log) --
sniffing on eth0
got a packet
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 28
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 59
     proto     = udp
     chksum    = 0x63ce
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 8
        chksum    = 0xd328

got a packet
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 28
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 62
     proto     = udp
     chksum    = 0x63ce
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ UDP ]### 
        sport     = 1234
        dport     = 4321
        len       = 8
        chksum    = 0xd328


   PASS injection: send.py built 2 srcroute frames     want=2                      got=2
   PASS h2 received packet count                       want=2                      got=2
   PASS ttl multiset {2 3 2 2 1 ; 2 1}                 want=[59, 62]               got=[59, 62]
   PASS no SourceRoute layer left at h2                want=0 blocks               got=0 blocks
   PASS ethertype seen by h2                           want=IPv4 (0x800)           got=['IPv4', 'IPv4']

-- switch logs --
   /home/adam/tutorials/exercises/source_routing/logs/driver-h2-receive.log 1047 B
   /home/adam/tutorials/exercises/source_routing/logs/s1-p4runtime-requests.txt 128 B
   /home/adam/tutorials/exercises/source_routing/logs/s1.log 169196 B
   /home/adam/tutorials/exercises/source_routing/logs/s2-p4runtime-requests.txt 128 B
   /home/adam/tutorials/exercises/source_routing/logs/s2.log 158611 B
   /home/adam/tutorials/exercises/source_routing/logs/s3-p4runtime-requests.txt 128 B
   /home/adam/tutorials/exercises/source_routing/logs/s3.log 112150 B

== net.stop() ==========================================================
net.stop() returned cleanly

== verdict =============================================================
   PASS injection: send.py built 2 srcroute frames     want=2                      got=2   【源碼推導，未執行】
   PASS h2 received packet count                       want=2                      got=2   【README 宣稱】＋【源碼推導，未執行】
   PASS ttl multiset {2 3 2 2 1 ; 2 1}                 want=[59, 62]               got=[59, 62]   【README 宣稱】＋【源碼推導，未執行】
   PASS no SourceRoute layer left at h2                want=0 blocks               got=0 blocks   【源碼推導，未執行】
   PASS ethertype seen by h2                           want=IPv4 (0x800)           got=['IPv4', 'IPv4']   【源碼推導，未執行】

>>> PASS (5/5)
```

### stderr（mininet 的 logger 走這裡）

```

```
