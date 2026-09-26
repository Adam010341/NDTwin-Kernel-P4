# 執行報告 — `flowcache` / skeleton

由 `drive_exercise.py` 自動產生，**非互動**（沒有進 mininet CLI、沒有開 xterm）。
每一條期望的來源等級沿用 `M7-source_routing.md` 的三級標記。

[Co-developed with claude code -- Adam]

| 欄位 | 值 |
|---|---|
| UTC | 2026-09-26T175515Z |
| exercise | `flowcache` |
| which | `skeleton` |
| fabric | `ndtwin` |
| package | — (tutorials harness) |
| cwd | `/home/adam/tutorials/exercises/flowcache` |
| 直譯器 | `/home/adam/p4dev-python-venv/bin/python` (3.12.3) |
| euid | 1000 |
| 判定 | **RED ARM (1/1): skeleton does not compile, by design** (exit 1) |

## 1. 工具鏈身分

| 執行檔 | sha256[:16] | --version |
|---|---|---|
| `/usr/local/bin/simple_switch_grpc` | `-` | n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture |
| `/usr/local/bin/p4c-bm2-ss` | `226f3f66df515c9e` | Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release) |

> 版本字串分不出這台機器上的兩顆 `simple_switch_grpc`；只有 sha 分得出。此處用的是 `/usr/local/bin` 那顆，**不是** `bmv2-fast`。

## 2. 編譯

```
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/flowcache/build/flowcache.p4.p4info.txtpb -o /home/adam/tutorials/exercises/flowcache/build/flowcache.json /home/adam/tutorials/exercises/flowcache/flowcache.p4
rc=1  warnings=1
/home/adam/tutorials/exercises/flowcache/flowcache.p4(9): [--Wwarn=unused] warning: 'egressSpec_t' is unused
typedef bit<9> egressSpec_t;
               ^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(232): [--Werror=type-error] error: Field opcode is not a member of header packet_out_header_h
            switch (hdr.packet_out.opcode) {
                                   ^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(84)
header packet_out_header_h {
       ^^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(234): [--Werror=type-error] error: Field operand0 is not a member of header packet_out_header_h
                    standard_metadata.egress_spec = (PortId_t) hdr.packet_out.operand0;
                                                                              ^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(84)
header packet_out_header_h {
       ^^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(240): [--Werror=type-error] error: Field opcode is not a member of header packet_out_header_h
                        hdr.packet_out.opcode);
                                       ^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(84)
header packet_out_header_h {
       ^^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(269): [--Werror=type-error] error: Field input_port is not a member of header packet_in_header_h
        hdr.packet_in.input_port = (PortIdToController_t) ingress_port;
                      ^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(89)
header packet_in_header_h {
       ^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(270): [--Werror=type-error] error: Field punt_reason is not a member of header packet_in_header_h
        hdr.packet_in.punt_reason = punt_reason;
                      ^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(89)
header packet_in_header_h {
       ^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(271): [--Werror=type-error] error: Field opcode is not a member of header packet_in_header_h
        hdr.packet_in.opcode = ControllerOpcode_t.NO_OP;
                      ^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(89)
header packet_in_header_h {
       ^^^^^^^^^^^^^^^^^^
```


## 3. 拓樸

```
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
```

## 4. 每一步的指令與原始輸出

## 5. 判定表

| 結果 | 期望 | 來源等級 | want | got | 依據 |
|---|---|---|---|---|---|
| PASS | RED ARM: the skeleton must NOT compile | 【README 宣稱】＋【源碼推導，未執行】 | `p4c refuses it` | `p4c rc=1` | README:29 'you need to define the fields in the packet_in and packet_out headers; otherwise, you'll get compilation errors'; flowcache.p4:83-91 declares both with no fields and :232/:269-271 read them |

## 6. 交換機 log / pcap


## 8. 完整 transcript

### stdout

```
drive_exercise.py -- flowcache / skeleton
(non-interactive: no mininet CLI, no xterm; kills nothing)
fabric   : ndtwin -- the package fabric `ndt up p4 --app` builds; no root needed

== pre-flight (read-only) ==============================================
OK   lab is free (claim: owner=- expires=- measuring=nothing)
OK   host scripts will run under /home/adam/p4dev-python-venv/bin/python
OK   ndt /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt, converter /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py, pre-flight /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py
--   switch  n/a: `ndt up p4` chooses the bmv2 binary -- see the `ndt status` capture
OK   p4c     /usr/local/bin/p4c-bm2-ss  sha256[:16]=226f3f66df515c9e  --version=Version 1.2.5.15 (SHA: 5b948b037a BUILD: Release)
OK   exercise dir /home/adam/tutorials/exercises/flowcache

== compile =============================================================
$ /usr/local/bin/p4c-bm2-ss --p4v 16 --p4runtime-files /home/adam/tutorials/exercises/flowcache/build/flowcache.p4.p4info.txtpb -o /home/adam/tutorials/exercises/flowcache/build/flowcache.json /home/adam/tutorials/exercises/flowcache/flowcache.p4
/home/adam/tutorials/exercises/flowcache/flowcache.p4(9): [--Wwarn=unused] warning: 'egressSpec_t' is unused
typedef bit<9> egressSpec_t;
               ^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(232): [--Werror=type-error] error: Field opcode is not a member of header packet_out_header_h
            switch (hdr.packet_out.opcode) {
                                   ^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(84)
header packet_out_header_h {
       ^^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(234): [--Werror=type-error] error: Field operand0 is not a member of header packet_out_header_h
                    standard_metadata.egress_spec = (PortId_t) hdr.packet_out.operand0;
                                                                              ^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(84)
header packet_out_header_h {
       ^^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(240): [--Werror=type-error] error: Field opcode is not a member of header packet_out_header_h
                        hdr.packet_out.opcode);
                                       ^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(84)
header packet_out_header_h {
       ^^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(269): [--Werror=type-error] error: Field input_port is not a member of header packet_in_header_h
        hdr.packet_in.input_port = (PortIdToController_t) ingress_port;
                      ^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(89)
header packet_in_header_h {
       ^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(270): [--Werror=type-error] error: Field punt_reason is not a member of header packet_in_header_h
        hdr.packet_in.punt_reason = punt_reason;
                      ^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(89)
header packet_in_header_h {
       ^^^^^^^^^^^^^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(271): [--Werror=type-error] error: Field opcode is not a member of header packet_in_header_h
        hdr.packet_in.opcode = ControllerOpcode_t.NO_OP;
                      ^^^^^^
/home/adam/tutorials/exercises/flowcache/flowcache.p4(89)
header packet_in_header_h {
       ^^^^^^^^^^^^^^^^^^
!! compile FAILED rc=1

== red arm =============================================================
   PASS RED ARM: the skeleton must NOT compile         want=p4c refuses it         got=p4c rc=1

== plan ================================================================
topology : topology.json
hosts    : h1, h2, h3
switches : s1, s2, s3
links    : 6
program  : /home/adam/tutorials/exercises/flowcache/flowcache.p4 -> build/flowcache.json
switch   : /usr/local/bin/simple_switch_grpc
steps    : run the exercise's controller; h1 ping h2/h3; assert ICMP replies
package  : /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-skeleton
equivalent to (from the repo root, as the operator -- no sudo):
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/convert.py /home/adam/tutorials/exercises/flowcache --topology topology.json --p4 flowcache.p4 --out /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-skeleton
  /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python /home/adam/Desktop/NDTwin-Kernel/tools/p4_exercise/preflight.py /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-skeleton
  NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt claim 45 '...' && NDT_OWNER=orch-0926 /home/adam/Desktop/NDTwin-Kernel/tools/test_workflow/ndt up p4 --app /home/adam/Desktop/NDTwin-Kernel/.test_run/packages/flowcache-skeleton
  ... the scripted steps above, then `ndt down` and `ndt release`.
telemetry: whatever the package declares (no --telemetry given)

== verdict =============================================================
   PASS RED ARM: the skeleton must NOT compile         want=p4c refuses it         got=p4c rc=1   【README 宣稱】＋【源碼推導，未執行】

>>> RED ARM (1/1): skeleton does not compile, by design
```

### stderr（mininet 的 logger 走這裡）

```

```
