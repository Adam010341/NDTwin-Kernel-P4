# GAP-1 — 13 支 p4lang/tutorials exercise 對「數位分身」的需求側盤點

本檔只寫**需求**：每支 exercise 要一個 twin 具備什麼能力，才能載入它的資料面、鏡射它的控制面、
觀測它、驗證它。NDTwin 那一側的現況在 `GAP-2-ndtwin-p4-capabilities.md`（另一支 agent 負責），本檔不碰。

[Co-developed with claude code -- Adam]

---

## 0. 怎麼讀

**本輪一個封包都沒送、一支 exercise 都沒跑**，我只讀原始碼與設定檔。每條主張附 `檔:行`；
`tutorials` 樹的根是 `/home/adam/tutorials`，路徑相對它寫。

- 【讀碼推導】＝讀 `.p4`／`topology.json`／`sX-runtime.json`／`mycontroller.py`／`utils/*.py` 推出來的。**本檔除了明講的例外，全部是這一級。**
- 【實測】＝只出現在轉引 `M7-source_routing.md` 與 `COMPILE-MATRIX.txt` 之處，照抄其原標記。
- 【README 宣稱】＝ exercise 自己的 README 這樣寫；**它本身也在受測**，衝突時先查我的推導。

---

## 1. 能力維度定義（與 GAP-2 對表用，英文鍵固定）

| 鍵 | 定義（要能做到什麼才算「有」） | 這批 exercise 的上界證據 |
|---|---|---|
| `pipeline_load` | 載入任意 `p4info + bmv2 json` 到指定交換機；**同一個網路裡不同交換機可以是不同程式** | `run_exercise.py:76-81` 每台交換機可帶 `program`；`firewall/pod-topo/topology.json:39` 就是這樣用 |
| `tables` | 依表名寫 entry；match kind 至少 exact／lpm；action 參數依 p4info 型寬編碼；`default_action` 可改 | `helper.py:85-108`（exact/lpm/ternary/range）、`simple_controller.py:174-185` |
| `pre_multicast` | 建 multicast group（group_id ＋ replica 清單），資料面 `standard_metadata.mcast_grp` 生效 | `simple_controller.py:244-246`、`helper.py:187-195` |
| `pre_clone` | 建 clone session（session_id ＋ replica ＋ 截斷長度），支援 `clone_preserving_field_list` | `simple_controller.py:248-251`、`helper.py:197-207` |
| `counters` | 讀 indexed counter（packets ＋ bytes），可指定 index 或全讀 | `switch.py:150-165` |
| `meters` | 讀／寫 meter | **`p4runtime_lib` 完全沒有這個 API**；13 支也一支都沒用 |
| `registers` | 讀／寫 P4 register | **`p4runtime_lib` 完全沒有這個 API**（只能走 thrift `simple_switch_CLI`） |
| `digest` | 收 Digest 訊息 | 13 支都沒用；`switch.py` 也沒有 Digest API |
| `packet_io` | packet-in／packet-out（`@controller_header`）＋ CPU port 開機參數 | `switch.py:179-202`、`p4runtime_switch.py:81-83,122-123` |
| `custom_headers` | 非 IPv4 etherType、自訂 header、header stack（`push_front`／`pop_front`／`.next`／`.last`）、`@controller_header`、serializable enum | 六種形狀：tunnel(0x1212)、calc(0x1234＋`lookahead`)、srcRoute(0x1234＋stack)、probe(0x812＋兩個 stack)、MRI(IPv4 option＋stack)、controller header(flowcache) |
| `queue_metadata` | `enq_qdepth`／`deq_qdepth`／`deq_timedelta`／`priority`；以及 bmv2 的 `--priority-queues` 旗標 | `run_exercise.py:91`、`p4runtime_switch.py:85-87,124-125` |
| `checksum` | `verify_checksum`／`update_checksum`（csum16）在改過 IPv4 欄位後仍算對 | 10 支有 `update_checksum`，1 支有 `verify_checksum` |
| `ttl_or_hop` | 每跳遞減 TTL／hop 計數，且**收端量得到**（這是唯一分得出路徑的斷言） | M7 §5「`ttl` 是這支 exercise 最好的斷言」【實測依據見該檔】 |
| `topology` | 主機／交換機數、每台埠號對應、連結 bw/delay、靜態 ARP、default gw、host 介面改名 `eth0` | `run_exercise.py:97-112`、`p4_mininet.py:160-169` |
| `control_plane_mode` | ①開機灌 runtime json ②跑時外部控制器走 P4Runtime ③兩者皆無（entry 寫死在 P4 裡） | `run_exercise.py:300-312` |
| `verification` | 判 pass 的手段：`pingall`／`send.py`+`receive.py` 內容比對／`iperf`／PTF／讀 `logs/sX.log` | 見 §2c |

**維度清單外、但必須另立一條的**：`idle_timeout` —— table entry 帶 `idle_timeout_ns`（`helper.py:157,165-166`）、P4 表宣告
`support_timeout = true`、控制器收 `IdleTimeoutNotification`（`switch.py:204-209`）。**只有 `flowcache` 用，但它整支的核心就是它。**

---

## 2. 需求矩陣
### 2a. 資料面（載入與轉發）

| exercise | `pipeline_load` | `tables`（kind／表名） | `custom_headers` | `checksum` | `ttl_or_hop` | `queue_metadata` |
|---|---|---|---|---|---|---|
| basic | 單一程式 | **關鍵** `lpm ipv4_lpm` | — | update | 用到 `ttl-1` | — |
| basic_tunnel | 單一程式 | **關鍵** `lpm ipv4_lpm` ＋ `exact myTunnel_exact` | **關鍵** 0x1212 tunnel hdr | update | 用到 | — |
| calc | 單一程式 | `exact calculate`（**const entries，控制面改不了**） | **關鍵** 0x1234 ＋ `lookahead` | — | — | — |
| ecn | 單一程式 | `lpm ipv4_lpm`（/32 ＋ /24） | — | update | 用到 | **關鍵** `enq_qdepth` |
| firewall | **關鍵：s1 與 s2-s4 不同程式** | `lpm ipv4_lpm` ＋ `exact check_ports`(2 欄 std_meta) | tcp hdr | update | 用到 | — |
| flowcache | 單一程式（控制器推） | **關鍵** `exact flow_cache`(3 欄) ＋ `support_timeout` | **關鍵** packet_in/out ＋ enum | verify ＋ update | 飽和減 `\|-\|` | — |
| link_monitor | 單一程式 | `lpm ipv4_lpm` ＋ `MyEgress.swid`(僅 default) | **關鍵** 0x812 ＋ 兩個 stack | update | probe `hop_cnt` | — |
| load_balance | 單一程式 | `lpm ecmp_group` ＋ `exact ecmp_nhop` ＋ `exact send_frame`(egress_port) | tcp hdr | update | 用到 | — |
| mri | 單一程式 | `lpm ipv4_lpm` ＋ `MyEgress.swtrace`(僅 default) | **關鍵** IPv4 option ＋ stack | update | 用到 | **關鍵** `deq_qdepth` |
| multicast | 單一程式 | **關鍵** `exact mac_lookup`(MAC) ＋ default→multicast | — | — | — | — |
| p4runtime | **關鍵：跑時才推 pipeline** | `lpm ipv4_lpm` ＋ `exact myTunnel_exact` | **關鍵** 0x1212 tunnel hdr | update | 用到 | — |
| qos | 單一程式 | `lpm ipv4_lpm`（default＝`NoAction`） | — | update | 用到 | — |
| source_routing | 單一程式 | **一條 entry 都沒有** | **關鍵** 0x1234 ＋ stack `pop_front` | — | **關鍵** `ttl` 判路徑 |— |

### 2b. 控制面

| exercise | `control_plane_mode` | 灌幾筆／什麼 | `pre_multicast` | `pre_clone` | `counters` | `registers` | `packet_io` | `idle_timeout` |
|---|---|---|---|---|---|---|---|---|
| basic | 開機 runtime json | 4 台×5（1 default drop ＋ 4 lpm/32） | — | — | — | — | — | — |
| basic_tunnel | 開機 runtime json | 3 台×6（3 lpm ＋ 3 exact） | — | — | — | — | — | — |
| calc | **無**（entry 在 P4 裡） | 0 | — | — | — | — | — | — |
| ecn | 開機 runtime json | 4／4／3 | — | — | — | — | — | — |
| firewall | 開機 runtime json | s1 **13**（8 check_ports ＋ 5 lpm）、s2-s4 各 5 | — | — | — | **用到但不讀**（bloom filter） | — | — |
| flowcache | **跑時控制器** | 0 開機；控制器逐流動態插 | — | **關鍵** session 57→CPU_PORT | **關鍵** 兩個 | — | **關鍵** | **關鍵** 3 s |
| link_monitor | 開機 runtime json | 4 台×6（含 `MyEgress.swid` default） | — | — | — | **用到但不讀**（byte_cnt／last_time） | — | — |
| load_balance | 開機 runtime json | s1 6、s2/s3 各 4 | — | — | — | — | — | — |
| mri | 開機 runtime json | 5／5／4（含 `MyEgress.swtrace` default） | — | — | — | — | — | — |
| multicast | 開機 runtime json | s1 4 entry ＋ **1 個 group** | **關鍵** grp 1 = {1,2,3} | — | — | — | — | — |
| p4runtime | **跑時控制器** | 0 開機；控制器 6 筆（雙向各 3） | — | — | **關鍵** 兩個 tunnel counter | — | — | — |
| qos | 開機 runtime json | 4／4／3 | — | — | — | — | — | — |
| source_routing | 開機 runtime json（**空**） | **0**【實測：三個檔都是空陣列，M7 §0】 | — | — | — | — | — | — |

### 2c. 拓樸與驗證

| exercise | `topology`（h/s、埠、連結參數、ARP/gw） | `verification` |
|---|---|---|
| basic | 4h/4s pod-topo（另有 3h/3s triangle）；無 bw；gw＋靜態 ARP | `pingall`；另有 PTF（`ptf/basic_fwd.py`，veth，**不經 Mininet**） |
| basic_tunnel | 3h/3s 三角；無 bw；gw＋ARP | `send.py --dst_id` → `receive.py` 讀 `show2()` 有無 tunnel 層；另有 PTF |
| calc | **2h/1s**；無 bw；**無 gw、無 ARP** | `h1 python3 calc.py` REPL：輸入 `1+1` 要回 `2`（`srp1` 請求／回應） |
| ecn | 5h/3s；**s1-p3↔s2-p3 bw 0.5 Mbps** | h1 `send.py` 1 pps ＋ h11 `iperf -u` 灌爆 → h2 看 `tos` 由 `0x1` 變 `0x3` |
| firewall | 4h/4s pod-topo；無 bw；gw＋ARP | `iperf h1 h2` 通、`iperf h1 h3` 通、**`iperf h3 h1` 要被擋** |
| flowcache | 3h/3s 三角；無 bw；gw＋ARP；**三台都要 `cpu_port 510`** | `h1 ping h2` 在控制器起來前無回應、起來後有；counter 要增加 |
| link_monitor | 4h/4s pod-topo；無 bw；gw＋ARP | h1 跑 `send.py`(probe 迴圈)＋`receive.py`；印出的 Mbps 要與 `iperf h1 h4` 對得上 |
| load_balance | 3h/3s 三角；無 bw；gw＋ARP | h2/h3 各跑 `receive.py`；h1 反覆 `send.py 10.0.0.1`，**兩邊都要收到**（雜湊分流） |
| mri | 5h/3s；**s1-p3↔s2-p3 bw 0.5 Mbps** | h2 `receive.py` 要看到 swtrace 序列（swid ＋ qdepth）；iperf 製造佇列 |
| multicast | **4h/1s**；無 bw；**只有 `ip route add`，無 gw、無靜態 ARP** | `pingall`：h1/h2/h3 互通、**h4 不通** |
| p4runtime | 3h/3s 三角；無 bw；gw＋ARP | `h1 ping h2` 起初無回應、跑 `mycontroller.py` 後有；counter 每 2 s 遞增 |
| qos | 5h/3s；**無任何 bw 參數**（與 ecn/mri 同形但不同設定） | `send.py --p=UDP/--des/--m/--dur`；h2 看 `tos` 由 `0x1` 變 `0xb9`(UDP)／`0xb1`(TCP) |
| source_routing | 3h/3s 三角；無 bw；gw＋ARP | h2 收到、**`ttl == 59`**（`2 3 2 2 1`）vs `62`（`2 1`）；無 SourceRoute 層 |

---

## 3. 逐支說明
（拓樸與驗證手段已在 §2c 不重複；每支只寫「教什麼／關鍵構件（行號）／控制面怎麼灌／twin 最低要求」。）

### 3.1 basic
教 IPv4 L3 轉發。`solution/basic.p4:62` etherType 選 parse、`:96-99` `ipv4_forward(dstAddr, port)` 設
`egress_spec`＋換兩個 MAC＋`ttl-1`、`:138` 重算 checksum。控制面 4 台各 5 筆＝1 筆 `ipv4_lpm` default
`MyIngress.drop` ＋ 4 筆 `/32` lpm（`pod-topo/s1-runtime.json`）。⚠️ **兩套拓樸**（`Makefile:5` 預設 pod-topo；
另有 triangle-topo）⇒「basic 跑過了」要指明哪一套。⚠️ 驗證有**兩條互不相干的路徑**：`pingall`，以及
`runptf.sh`——後者用 8 對 veth ＋ 獨立 `simple_switch_grpc --no-p4`，**繞過 Mininet 與 topology.json**，由測試
自己推 pipeline 與 entry（`ptf/basic_fwd.py:61-63,74-80`）。twin：`pipeline_load`、`tables`(lpm＋
default_action)、`topology`、`control_plane_mode`(開機灌)、`verification`(ping)、`checksum`、`ttl_or_hop`。

### 3.2 basic_tunnel
教在 Ethernet 與 IP 之間插一層自訂 tunnel header。`solution/basic_tunnel.p4:7` `TYPE_MYTUNNEL = 0x1212`；
`:118-129` `ipv4_lpm`(lpm)、`:135-145` `myTunnel_exact`(exact 16-bit `dst_id`)、`:147-157` 用 `isValid()`
分流兩張表。控制面 3 台各 6 筆。驗證的判別力在**目的地被 tunnel 蓋過**：`send.py 10.0.3.3 --dst_id 2` 要送到
**h2 不是 h3**（`send.py:37-44`）。twin：`pipeline_load`、`tables`(exact＋lpm)、**`custom_headers`（非 IPv4 etherType 要能 parse／deparse）**、`verification`(封包內容比對)。

### 3.3 calc
教自訂協定與 `lookahead`。`solution/calc.p4:62` `P4CALC_ETYPE = 0x1234`；`:119-126` 用
`packet.lookahead<p4calc_t>()` 三欄同時 select 做魔數檢查；`:161` `egress_spec = ingress_port`（原路
反射）。**控制面是零**：`calculate` 的 entry 寫死在 P4 裡（`:200-207` `const default_action` ＋ `const
entries`），`s1-runtime.json` 的 `table_entries` 是空的；host 也沒有 `commands`（`topology.json:3-10`），
無 gw、無靜態 ARP——也不需要，全走 L2 自訂 etherType。twin：`pipeline_load`、`custom_headers`、
`topology`(最小)、`control_plane_mode`=**無**、`verification`(REPL 往返)。🔑 **這支是「表存在但控制面
永遠改不了」的樣本**——p4info 會標成 const table，twin 若假設「表＝可寫」會在這支翻車。

### 3.4 ecn
教用佇列深度標 ECN。ipv4 把 TOS 拆成 `diffserv:6 + ecn:2`；egress `solution/ecn.p4:134-139`：`ecn == 1 或 2`
且 `standard_metadata.enq_qdepth >= ECN_THRESHOLD` 才 `ecn = 3`。控制面 3 台 4／4／3 筆，**混用 `/32` 與
`/24` 兩種前綴**。關鍵在 `topology.json:65-69` 那條 `["s1-p3","s2-p3","0",0.5]`——**0.5 Mbps 瓶頸，整支的
觀測全靠它**。twin：`queue_metadata`(`enq_qdepth` 要是真的、不能是常數)、**`topology` 要能施加逐連結頻寬**、
`verification`(同時跑兩條流並在收端比對欄位)。🔴 這支的判定**天生不穩定**（`README.md:193-199` 自己承認
時序要對）⇒ twin 要自動判 pass 必須自己定義穩定的斷言。

### 3.5 firewall
教 bloom filter 狀態防火牆。**最特別的不是 P4 而是拓樸**：`pod-topo/topology.json:39` 只給 s1 指定
`"program": "build/firewall.json"`，s2-s4 沒指定 ⇒ 吃 `Makefile:6` 的 `DEFAULT_PROG = basic.p4`；而
`s1-runtime.json` 的 p4info 是 `build/firewall.p4.p4info.txtpb`、s2-s4 是 `build/basic.p4.p4info.txtpb`
⇒ **同一個網路裡兩種 pipeline、兩份 p4info。** 資料面：`solution/firewall.p4:126-127` 兩個 register 當
bloom filter、`:138,145` crc16／crc32 兩個 hash、`:177-188` `check_ports` 用
**`standard_metadata.ingress_port` ＋ `egress_spec`** 兩欄 exact 判方向、`:204-220` 內往外看到 SYN 寫 1、
外往內兩格都是 1 才放行。控制面 s1 13 筆（8 `check_ports` ＋ 5 lpm），其餘各 5 筆。twin：
**`pipeline_load` 必須是 per-switch 的**、`tables`(exact on standard_metadata)、`registers`(存在且跨封包
保持狀態，但不需控制面讀)、`verification`(iperf 的方向性)。

### 3.6 flowcache
教把 miss 打到控制器、由控制器逐流插規則、規則閒置就自己過期。**13 支裡最重的一支。**
資料面 `solution/flowcache.p4`：`:73-81` 兩個 `enum bit<8>`（p4info 帶 `type_info.serializable_enums`，
控制器真的去讀，`mycontroller.py:498-501`）；`:83-97` `@controller_header` 的 packet_in／packet_out；
`:100-105` `@field_list(FL_PACKET_IN)` 標記要跨 clone 保留的 metadata；`:194`
`clone_preserving_field_list(CloneType.I2E, 57, FL_PACKET_IN)`；`:218-233` `flow_cache` 三欄 exact ＋
**`support_timeout = true`** ＋ default `flow_unknown`；`:179,269` 兩個 counter；`:127-135` parser 用
`ingress_port == CPU_PORT` 判是不是控制器下來的。拓樸 `topology.json:30,33,36` 三台都要 `cpu_port 510`
⇒ bmv2 帶 `--cpu-port 510`（`p4runtime_switch.py:122-123`）；**沒有 `runtime_json`** ⇒
`run_exercise.py:307` 印「No control plane file provided」。控制面全在 `solution/mycontroller.py`：
`SetForwardingPipelineConfig`×3（`:483-491`）、`WritePREEntry` 建 clone session（`:167-170,504-507`）、非同步收
`PacketIn`（`:414-421`）與 `IdleTimeoutNotification`（`:436-442`）、`PacketOut`（`:272-274`）、帶
`idle_timeout_ns = 3 s` 的 `WriteTableEntry`（`:191-208`）、`DeleteTableEntry`（`:224-225`）、`ReadCounters`
（`:304`）。twin：`pipeline_load`、`tables`(3 欄 exact)、`pre_clone`、`counters`、`packet_io`(＋CPU port
**開機**參數)、`custom_headers`(controller header ＋ enum)、`idle_timeout`(entry TTL ＋**主動送通知給
控制器**)、`control_plane_mode`=跑時控制器。

### 3.7 link_monitor
教用 probe 封包在資料面量鏈路使用率。`solution/link_monitor.p4:8` `TYPE_PROBE = 0x812`；`:75-81` 一個
`probe_t` ＋ **兩個 header stack**（`probe_data_t[MAX_HOPS]`、`probe_fwd_t[MAX_HOPS]`）；`:110-136` parser 用
`.next`／`.last` 迴圈解可變長度堆疊；egress `:200-202` 兩個 register（每埠累積 byte 數、上次時間），
`:220-246` 用 `egress_global_timestamp` 與 `packet_length` 算區間塞進 probe。控制面 4 台各 6 筆，含
`MyEgress.swid` 的 **default action `set_swid(swid=N)`**（每台不同）。twin：`custom_headers`（**兩個 stack ＋
parser 迴圈**）、`registers`(跨封包狀態)、`tables`(default-only 表要能設 default action)、**時間戳與
`packet_length` 要是真的**、`verification`(**數值要與 iperf 對得上——13 支裡唯一的量化對帳**)。

### 3.8 load_balance
教 ECMP。`solution/load_balance.p4:106-116` `hash(crc16, base, 5-tuple, count)` 寫進 `meta.ecmp_select`；
`:123-142` `ecmp_group`(lpm) → `ecmp_nhop`(exact on metadata)；egress `:166-178` `send_frame` 用
`standard_metadata.egress_port` exact 改 src MAC。控制面 s1 6 筆——其中 `ecmp_group` 匹配的是 **`10.0.0.1/32`，
那不是任何一台 host 的 IP**（hosts 是 10.0.1.1／10.0.2.2／10.0.3.3）⇒ 虛擬目的地，`set_nhop` 才把
`hdr.ipv4.dstAddr` 改寫成真實 host。每次 `send.py` 用隨機 sport（`send.py:36`）⇒ **h2 與 h3 兩邊都要收到
才算對**。twin：`tables`(lpm ＋ 兩種 exact，一種 key 是使用者 metadata、一種是 `egress_port`)、
`verification`(**分佈型**斷言，不是單顆封包到不到)。

### 3.9 mri
教把每跳的 swid＋佇列深度串進 IPv4 option。`solution/mri.p4:44-58` `ipv4_option_t` ＋ `mri_t` ＋
`switch_t[MAX_HOPS]`；`:104-137` parser 依 `ihl` 決定要不要解 option，
`verify(hdr.ipv4.ihl >= 5, error.IPHeaderTooShort)`（`:106`）是 13 支裡唯一的 parser error；egress `:195-209`
`push_front(1)` ＋ `setValid()` ＋ 寫 `deq_qdepth`，**還要自己修 `ihl`／`optionLength`／`totalLen`**。控制面
3 台 5／5／4 筆，含 `MyEgress.swtrace` 的 default action `add_swtrace(swid=N)`；`topology.json:65-69` 同樣有
0.5 Mbps 瓶頸。twin：`custom_headers`(IPv4 option ＋ stack ＋ 長度欄位自維護)、`queue_metadata`(`deq_qdepth`)、
`tables`(default-only)、`topology`。🔑 對 `checksum` 是個陷阱：`update_checksum` 的欄位清單（`:232-246`）
**不含 option**，加了 option 之後 IPv4 checksum 依然只算固定 20 bytes——**twin 不能「幫它算對」**。

### 3.10 multicast
教 PRE。`solution/multicast.p4:74-76` `multicast()` 只做一件事——`standard_metadata.mcast_grp = 1`；
`:82-93` `mac_lookup` 用 MAC exact、**`default_action = multicast`**（查不到就氾濫）；egress `:112-115`
把回到 ingress port 的那份剪掉防迴圈。控制面：`sig-topo/s1-runtime.json` 4 筆 MAC entry ＋ **1 個
`multicast_group_entries`：group 1 = replicas {port 1, 2, 3}**。拓樸最特別：host 的 `commands` 只有
`ip route add 10.0.0.0/24 dev eth0`（`sig-topo/topology.json:6-8`）——**沒有 default gw、沒有靜態 ARP** ⇒
**ARP 是真的要跑的**，而 ARP 是廣播、走 default action 進 group；h4 不在 group 裡所以永遠收不到 ARP
request。⚠️ `solution/s1-runtime.json` 的 group 是 {1,2,3,**4**}——那是 Step 2 第 6 項作業的答案
（`README.md:124`），**跟預設載入的那份不同**；拿錯會讓「h4 不通」這個判定失效。twin：**`pre_multicast`
（沒有它一步都跑不了）**、`tables`(MAC exact ＋ default 導向 action)、`topology`(要能讓 ARP 真的發生)、
`verification`(**部分連通**：通與不通同時斷言)。

### 3.11 p4runtime
教用外部控制器在跑時操作 P4Runtime。程式是 `advanced_tunnel.p4`（**`solution/` 裡只有 `mycontroller.py`，
沒有 `.p4`**）。`:109-110` 兩個 `counter(MAX_TUNNEL_ID, packets_and_bytes)`，在 `myTunnel_ingress`／
`myTunnel_egress` 裡以 tunnel id 當 index 計數（`:128,140`）。`topology.json:29-31` 三台交換機都是 **`{}`**
——沒有 `runtime_json`、沒有 `program` ⇒ 開機控制面全空（`run_exercise.py:307` 警告），bmv2 仍載入
`Makefile` 預設的 `-j build/advanced_tunnel.json`，之後控制器再 `SetForwardingPipelineConfig` 推一次
（`solution/mycontroller.py:184-189`）。控制面：`writeTunnelRules` 每方向 3 筆（封裝／轉發／解封裝，
`:46-104`）雙向共 6 筆；`readTableRules` 用 `ReadTableEntries` ＋ p4info 反查名字（`:115-131`）；
`printCounter` 每 2 秒 `ReadCounters`（`:144-150,203-210`）。gRPC 位址與 device_id **寫死**
`127.0.0.1:50051/dev 0`、`:50052/dev 1`（`:167-176`）。twin：`pipeline_load`(**跑時可換**)、`tables`(讀得
回來、名字對得上)、`counters`(indexed)、`custom_headers`、`control_plane_mode`=外部控制器、
**gRPC port 與 device_id 要可預測**（s1→50051/0、s2→50052/1）。

### 3.12 qos
教 DiffServ 標記。ipv4 拆 `diffserv:6 + ecn:2`（`solution/qos.p4:43-44`）；`:120-193` 一堆只改
`hdr.ipv4.diffserv` 的 action；`:208-217` apply 依 `hdr.ipv4.protocol` 是 UDP 或 TCP 分別呼叫
`expedited_forwarding()`(46) 或 `voice_admit()`(44)，再 `ipv4_lpm.apply()`。控制面 3 台 4／4／3 筆，
`ipv4_lpm` 的 `default_action = NoAction()`（`:205`，與 basic 的 `drop` 不同）。twin：`pipeline_load`、
`tables`(lpm)、`topology`、`verification`(欄位比對)。🔴 **更正一個容易犯的預期**：這支叫 qos 但
**完全沒有佇列、沒有 priority、沒有 meter**——`standard_metadata.priority` 在 13 支裡一次都沒出現，
`priority_queues` 這個拓樸鍵（`run_exercise.py:91`、`p4runtime_switch.py:124-125`）**一支都沒用**，
它的拓樸也**沒有任何 bw 參數**（`topology.json:64-67`）。把 qos 當成「要 priority queue」會做出一個
沒人要的能力。

### 3.13 source_routing
教由來源指定整條路徑。逐步表在 `M7-source_routing.md`，這裡只補需求。`solution/source_routing.p4:8`
`TYPE_SRCROUTING = 0x1234`；`srcRoutes` 是 `srcRoute_t[MAX_HOPS]`，每跳 `pop_front(1)`、`bos == 1` 時把
etherType 改回 `0x0800`（`:114-134`）。控制面：**三台的 `table_entries` 都是空陣列**【實測，M7 §0】⇒
「控制面完全不參與，任何失敗都只能是資料面或環境」。twin：`pipeline_load`、`custom_headers`(stack ＋
`pop_front`)、`topology`、`control_plane_mode`=空、`ttl_or_hop`(**收端量得到的逐跳遞減，是唯一分得出走
哪條路的證據**)。

---

## 4. 跨支彙整
### 4a. 13 支的共同底線（少一樣就有支跑不了）

| 維度 | 幾支要 | 說明 |
|---|---|---|
| `pipeline_load` | **13/13** | 每支都要載入自己那份 `p4info + bmv2 json`。**最低標不是「載入一份」而是「載入任意一份，且可以每台不同」**（firewall）。 |
| `topology` | **13/13** | 形狀分四類：4h/4s pod-topo（basic／firewall／link_monitor）、3h/3s 三角（basic_tunnel／flowcache／load_balance／p4runtime／source_routing／basic-triangle）、5h/3s（ecn／mri／qos）、極小（calc 2h/1s、multicast 4h/1s）。**11 支要 default gw ＋ 靜態 ARP**；calc 兩者皆無、multicast 只有一條 `ip route add`。host 介面一律被改名 `eth0`（`p4_mininet.py:160`），**測試腳本寫死這個名字**（`link_monitor/send.py:28`）。 |
| `verification` | **13/13** | 但**沒有一支能只靠「ping 通不通」判定**（見 4c）。 |
| `tables` | 12/13 | 只有 source_routing 一條 entry 都沒有。**只需要 exact 與 lpm 兩種 match kind——ternary／range／optional 在 13 支裡一次都沒出現。** |
| `checksum` | 10/13 | `update_checksum`：basic、basic_tunnel、ecn、firewall、flowcache、link_monitor、load_balance、mri、p4runtime、qos。`verify_checksum` **只有 flowcache**（`:155`）。calc／multicast／source_routing 的 checksum block 是空的。 |
| `ttl_or_hop` | 11/13 | calc 與 multicast 不動 TTL。 |

### 4b. 只有少數支要的（做了只服務 1-2 支，但那 1-2 支沒它就是零分）

| 維度 | 誰要 | 沒有它的後果 |
|---|---|---|
| `pre_multicast` | **multicast（1 支）** | 整支跑不起來——`mcast_grp = 1` 沒有對應的 group 就是丟掉，`pingall` 全掛。 |
| `pre_clone` | **flowcache（1 支）** | `clone_preserving_field_list(…, 57, …)` 無效 ⇒ 控制器永遠收不到 packet-in。 |
| `packet_io` ＋ CPU port | **flowcache（1 支）** | 同上；而且 CPU port 是**開機參數**（`--cpu-port 510`），不是跑時設得起來的。 |
| `idle_timeout` | **flowcache（1 支）** | entry 永不過期、`IdleTimeoutNotification` 永遠不來 ⇒ 這支一半的作業內容失效。 |
| `counters` | flowcache、p4runtime（2 支） | 兩支「怎麼看出它在動」就是讀 counter；沒有它只剩 ping 通不通。 |
| `registers` | firewall、link_monitor（2 支） | **兩支都只在資料面用、控制面不讀** ⇒ twin 需要的是「register 跨封包保持狀態」，**不是** P4Runtime 的 register 讀寫 API（`p4runtime_lib` 根本沒有那個 API）。 |
| `queue_metadata` | ecn(`enq_qdepth`)、mri(`deq_qdepth`)（2 支） | 兩支的觀測對象就是它。**要的只有這兩個欄位**：`deq_timedelta` 與 `priority` 全沒用到。 |
| 逐連結頻寬 | ecn、mri（2 支） | `topology.json` 的 `0.5`（Mbps）是唯一製造佇列的手段；沒有它 qdepth 永遠是 0，兩支的判定都變成假通過。 |
| `meters`／`digest` | **0 支** | 這批 exercise 完全不需要。**做了不會有任何一支用到。** |

### 4c. 只靠 IPv4 lpm 就能跑的有哪些（這對 NDTwin 最關鍵）

NDTwin 自己的 P4 程式有 `MyIngress.ipv4_lpm` 與 `ipv4_forward(dstAddr, port)`。**若 twin 的能力只有
「載入一支固定的 IPv4 lpm 程式 ＋ 灌 lpm entry」，能跑的是：**

- ✅ **`basic`（1 支）** —— 表名、action 名、參數名、match kind 全部逐字相同（`basic/pod-topo/s1-runtime.json`
  的 `MyIngress.ipv4_lpm`／`MyIngress.ipv4_forward{dstAddr, port}`）。**唯一真正「零改動」的一支。**
- ⚠️ **`qos`（准 1 支）** —— 表名／action 名／參數名相同，但 TOS 被拆成 `diffserv:6 + ecn:2`、
  `default_action` 是 `NoAction` 而非 `drop`，且**要載入 qos 自己的 pipeline** 才有 diffserv 邏輯。
  載 NDTwin 的程式只會得到「封包會通、但 tos 永遠 0x1」——那是 **Step 1 預期，不是 Step 3**。
- ⚠️ **`ecn`／`mri`（准 2 支）** —— 轉發那一半同構，但判定對象是 `enq_qdepth` 與 swtrace 堆疊。
- ⚠️ **`firewall`（半支）** —— s2/s3/s4 就是 `basic.p4`（`Makefile:6`），**但 s1 必須是另一支程式**；
  做不到 per-switch pipeline 就只能跑到「防火牆沒生效」的 Step 1。
- ❌ **其餘 8 支全部不行**：basic_tunnel／calc／source_routing／link_monitor（自訂 header）、
  multicast（PRE）、load_balance（ECMP 兩張表 ＋ egress 表）、p4runtime（跑時控制器 ＋ counter）、
  flowcache（packet-in/out ＋ clone ＋ idle timeout）。

🔑 **結論的形狀**：13 支裡**只有 1 支**（basic）是「現有 IPv4 lpm 能力的直接使用者」，**4 支**
（qos／ecn／mri／firewall）是「轉發同構、但判定需要別的能力」，**8 支**要的是**載入任意 P4 程式**
這件事本身，而不是某一個新功能。⇒ 需求側第一順位不是「多做幾個 P4 feature」，是 **`pipeline_load`
的任意性（任意 p4info + json、每台可不同、可在跑時換）**；第二順位是 `tables` 的通用性（依 p4info
用表名／欄位名寫 entry，而不是寫死 `ipv4_lpm`）。`pre_multicast`／`pre_clone`／`packet_io`／
`idle_timeout` 各自只服務 1 支，但**那 1 支沒它就是 0 分，沒有中間狀態**。

---

## 5. 附：讀了哪些檔、哪些沒讀完

**讀完（整檔）**：`utils/` 的 `run_exercise.py`(391)、`p4runtime_switch.py`(139)、`p4_mininet.py`(152)、`Makefile`(53)、
`p4runtime_lib/simple_controller.py`(255)、`p4runtime_lib/switch.py`(246)；13 支的 `Makefile`、全部 15 個
`topology.json`（含 `basic/triangle-topo`）、全部 33 個 `sX-runtime.json`（腳本逐檔解析 `table_entries`／
`multicast_group_entries`／`clone_session_entries`／`p4info`／`bmv2_json`）；兩支 `mycontroller.py`（p4runtime
237 行、flowcache 556 行）；`calc/solution/calc.p4`、`multicast/solution/multicast.p4`、
`link_monitor/{probe_hdrs,send,receive}.py`、`mri/send.py`、`load_balance/send.py`、兩支 `runptf.sh`；本 repo 的 `README.md`、`M7-source_routing.md`、`COMPILE-MATRIX.txt`。

**只讀關鍵區段**：11 支 solution `.p4` 讀了 header／parser／ingress／egress／deparser 主體，**沒逐行讀
checksum block 的每個欄位與 `V1Switch(...)` 收尾**（13 支幾乎逐字相同）；另跑了針對 register／counter／
meter／digest／clone／multicast／queue metadata／priority 的全樹 grep，用來確認「沒用到」的那些格子。
各 `README.md` 讀了 Step 1／Step 3／驗證／Troubleshooting，**沒逐行讀 Step 2 的作業說明**（那是
「怎麼填 TODO」不是需求）；例外是 `qos`／`ecn` 整份讀完，為了確認 qos 到底有沒有 priority queue。

**沒讀（誠實列出）**：

- 🔴 **13 支的骨架 `.p4`（未填 TODO 那版）我沒逐支讀**，需求全部推自 `solution/` ⇒ Step 1 的預期行為不在
  本檔範圍（那是 M7 系列的事）。唯一例外是 `firewall/basic.p4`，因為 firewall 的 s2-s4 載入的就是它。
- 兩支 PTF 測試（`basic/ptf/basic_fwd.py`、`basic_tunnel/ptf/basic_tunnel.py`）**只讀前 60-80 行**（setUp／建
  entry），**沒讀完各 test case 的斷言** ⇒ 本檔對 PTF 只講「它繞過 Mininet、用 veth ＋ `--no-p4` 的獨立交換機、
  由測試自己推 pipeline」，**PTF 究竟斷言什麼我沒讀到**。
- `p4runtime_lib/helper.py` 只讀 85-208 行；`convert.py`(150) **完全沒讀** ⇒ 沒查證位元編碼細節。六支
  `receive.py` 與 `calc/calc.py` 的全文（`calc.py` 只讀到第 20 行）靠 M7 與 README 的描述，**沒有逐支查證
  它們印什麼**。`multicast/disable_ipv6.sh` 沒讀；拓樸圖沒看。
- 我**沒有執行任何東西**：沒編譯、沒起 Mininet／bmv2、沒碰 `ndt`、沒 sudo、沒殺行程，也沒改 `~/tutorials`
  樹裡的任何一個檔。§1 的「`p4runtime_lib` 沒有 meter／register／digest API」是讀 `switch.py` 全檔（246 行）
  得到的，**不是跑出來的**。
