# GAP-2b — NDTwin P4 供給側盤點，2026-09-27（路線 2 之後）

[Co-developed with claude code -- Adam]

對表對象：`GAP-1-exercise-requirements.md`（需求側，**沒有變**，本文不碰）。前一版供給側是
`GAP-2-ndtwin-p4-capabilities.md`（09-08，trunk `1a284f75`，全部【讀碼】）。英文維度鍵三份共用。
本文**沒有執行任何東西**：沒起 fabric、沒跑 bmv2／Mininet／`ndt`、沒跑測試、沒編譯。
【跑過】的格子全部是**讀既有的 live raw**。

## 0. 判準（先寫定，再評任何一格）

### 0.1 問題換了

- **GAP-2 的問題**：「今天、不改任何一行碼，**NDTwin 自己那支 P4 程式**（`ndtwin_switch.p4`）提供得了這一維嗎？」
- **路線 2 之後的問題**（PLAN-0917 §2、§8.1）：exercise 帶**它自己的 `.p4`** 進來，跑在 NDTwin 的 bmv2 fabric 上。
  「NDTwin 自己的程式有沒有 meter／register／自訂標頭」不再是問題；程式是 exercise 的。
- **本文的問題（逐格都照這句評）**：
  > **需要這一維的每一支 exercise，今天都在 NDTwin fabric 上跑得起來；而且這一維裡歸 NDTwin 負責的那一半**
  > **（載入、灌表、拓樸、控制面、存活／觀測、驗證）是 NDTwin 的碼做的。**
- ⚠️ 所以 **09-16 那一列與 09-27 這一列回答的是兩個不同的問題**。等級變好，一部分是 NDTwin 多做了事，
  一部分是題目本身把責任移給了 exercise 的程式。§2 逐維說是哪一種。

### 0.2 每一維「歸 NDTwin 負責的那一半」

| 鍵 | 路線 2 下歸 NDTwin 的部分 | 不歸 NDTwin（exercise 的程式或控制器負責） |
|---|---|---|
| `pipeline_load` | 把每台自己的 p4info＋json 推上該台，可以每台不同；external 模式下不推、讓控制器推 | 程式本身 |
| `tables` | 依 p4info 的表名／欄位名／action 名寫 package 的 runtime entries（含只有 default 的表） | 控制器模式下控制器自己寫的表 |
| `pre_multicast` | 寫 package 宣告的 multicast group | — |
| `pre_clone` | 寫 package 宣告的 clone session | 程式裡的 `clone` 呼叫 |
| `counters` | 北向讀得到程式的 counter | 程式怎麼數 |
| `meters` | 讀／寫 meter（GAP-1 §1 的定義） | — |
| `registers` | 讀／寫 register（GAP-1 §1 的定義）；register 跨封包保持狀態是 bmv2 的事 | 程式怎麼用 register |
| `digest` | 收 digest | — |
| `packet_io` | 開機帶對 CPU port；packet-in／out 通到 app 的控制面 | 控制器怎麼處理 packet-in |
| `custom_headers` | twin 看得到這些幀：鏈路位元組＋流身份 | parse／deparse |
| `queue_metadata` | 讓佇列形成（逐鏈路整形）；`--priority-queues` 旗標 | 讀 `enq_qdepth`／`deq_qdepth` |
| `checksum` | 主機端 offload 關掉，線上的 checksum 才是程式算的 | 算 checksum |
| `ttl_or_hop` | 無（把封包交到收端即可） | 遞減、收端讀 |
| `topology` | 照 exercise 起 fabric（主機、交換機、埠、整形、ARP／gw、`eth0`），twin 的圖與它一致，鏈路存活判得出來 | — |
| `control_plane_mode` | ①套 runtime json ②external：不搶仲裁、不寫，控制器連得上 ③無：什麼都不做 | 控制器本身 |
| `verification` | twin 自己的觀測（鏈路使用率、`switch_state`、存活）與 `ndt up` 的驗證 | exercise 自己的 send／receive 判定（由 `drive_exercise.py` 跑，本文把它當「跑得起來」的證據） |

### 0.3 三個等級

- **做得到**：需要此維的每一支 exercise，在 T06 那一輪（§0.4）**兩臂都照預期**（解答臂綠、骨架臂紅如預期）；
  **而且** 0.2 表裡歸 NDTwin 的那一半，在 live raw 裡看得到是 NDTwin 的碼做的。
- **部分**：跑得起來，但下列至少一條成立（格子裡會寫是哪一條）：
  - **(a) twin 看不到**：歸 NDTwin 的是觀測，而 twin 看不到這一維產生的東西。只算 NDTwin 有模型或 P4Runtime 讀得到的東西：
    鏈路上的幀、流身份、counter／register／meter。逐包 metadata（qdepth、TTL、checksum）不算。
  - **(b) 只經 tutorials 自己的控制器**：live 證據裡，歸 NDTwin 的那一半全是 exercise 的控制器做的；NDTwin 的對應碼沒有被任何一支走過。
  - **(c) 只有讀碼**：NDTwin 的對應碼存在，但沒有【跑過】證據。
  - **(d) 只有一部分跑得起來**：需要它的 exercise 裡，有的跑得起來、有的跑不起來。
- **做不到**：有一支需要它的 exercise 在 NDTwin fabric 上跑不起來；或（13 支都不需要的維度）NDTwin 沒有對應碼。
- **13 支都不需要的維度**（GAP-1 §4b：`meters`、`digest`）：「每一支需要它的都跑得起來」這句空成立，
  所以只看 NDTwin 有沒有碼：有 ⇒ 最多「部分」（必然只有讀碼）；沒有 ⇒「做不到」。
- 真的是判斷的格子，依據欄寫 **(judgement)**。

### 0.4 證據等級（不可混用）

- **【跑過】**：引 live raw 的路徑＋行號。**主證據是 T06**：
  `L/2026-09-27T074635Z_06_thirteen/00_table.tsv`（13 支 × 兩臂 26 列，每臂一份 arm report）。
  - T06 跑在 trunk `5dc7fc9a`，工作樹 +95 個未提交檔（arm report 內 `ndt status` 的 `code` 欄）。
  - bmv2 是 `/usr/local/bmv2-fast/bin/simple_switch_grpc`（sha256[:16] `3ff54b5c1901c9d3`）。
  - p4c 是 `/usr/local/bin/p4c-bm2-ss`（`226f3f66df515c9e`）。見各 arm report §1。
  - 其他 live 證據：`L/2026-09-26T152605Z_08_heartbeat`（心跳 H1–H4）、`L/2026-09-26T172912Z_08_heartbeat`（H5）、
    `L/2026-09-26T202055Z_07_roles_basic`（roles）。
- **【讀碼】**：引 `檔:行`，行號＝trunk **`7746832e`**。
  - `7746832e` 與 `5dc7fc9a` 只差 `p4_proxy/requirements.txt` 兩行（`git diff --stat 5dc7fc9a 7746832e`）。
  - 下列引到的碼，工作樹與 `7746832e` 相同（`git status` 無修改）。
- 一格只有讀碼，就在格子裡寫「只有讀碼」。
- 🔴 **未提交的觀測**：`R/`、`L/` 底下的 raw 在這個 checkout 裡**全部未進版控**（`git ls-files` 0 筆）。
  它們是 audit-raw 的材料，本文引的是工作樹上的檔。
- 路徑縮寫：
  - `R/` ＝ `doc/audit/2026-09-04_p4-tutorial-exercise-prep/runs/`
  - `L/` ＝ `doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs/`
  - `T06` ＝ `L/2026-09-27T074635Z_06_thirteen/00_table.tsv`
  - **`<exercise>/sk`、`<exercise>/sol`** ＝ T06 那一列第 5 欄指的 arm report。例：`firewall/sol`
    ＝ `R/2026-09-27T080128Z_firewall_solution_ndtwin.md`。26 份的時間戳列在 §3。
  - 程式碼路徑一律相對 repo 根目錄。

---

## 1. 能力矩陣（09-27）

| 維度 | 今天 | 一句依據 | 依據位置 |
|---|---|---|---|
| `pipeline_load` | 做得到 | 【跑過】13 支解答臂都在 NDTwin fabric 上跑自己的程式且綠。firewall 同一網路兩份程式（s1 p4info `ef7561c073ee3b7f`、s2–s4 `9213871cee36bd93`）。p4runtime／flowcache 由自己的控制器在跑時推，proxy 標 `pipeline_push` 跳過 | 【跑過】`T06:2-27`、`firewall/sol:58-64`、`p4runtime/sol:58-60`、`R/2026-09-27T081205Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log:6-7`；【讀碼】`p4_proxy/proxy_agent/main.py:247,1905,1813` |
| `tables` | 做得到 | 【跑過】9 支開機灌表的 exercise，entries 都由 NDTwin 依 p4info 名字寫入，0 failed：firewall 28/28、load_balance 14/14、link_monitor 每台 6（含只有 default 的 `MyEgress.swid`）。p4runtime／flowcache 的表由它們自己的控制器寫（控制面模式 ②） | 【跑過】`firewall/sol:218`、`load_balance/sol:208`、`link_monitor/sol:214`；【讀碼】`p4_proxy/proxy_agent/main.py:618-665,1940`、`p4_proxy/proxy_agent/p4_client.py:1318` |
| `pre_multicast` | 做得到 | 【跑過】multicast 的 group 由 NDTwin 從 package 的 `multicast_group_entries` 寫入（applied 1、failed 0）。解答臂 h1/h2/h3 互通、h4 收不到 | 【跑過】`multicast/sol:332-336,590-593`；【讀碼】`p4_proxy/proxy_agent/main.py:1006,1963`、`p4_proxy/proxy_agent/p4_client.py:912` |
| `pre_clone` | 部分 | (b)(c) 【跑過】flowcache 綠，控制器收得到 PacketIn；NDTwin 寫的 clone session 是 0（`pre_entries.clone.applied 0`，`clone_session` 在 skipped），所以 session 是它自己的控制器寫的（推論）。NDTwin 從 package 套 `clone_session_entries` 的路沒有任何一支走過，只有讀碼 | 【跑過】`flowcache/sol:60,299-303,761`、`R/2026-09-27T081256Z_flowcache_solution_ndtwin/driver-controller-flowcache.log:12`；【讀碼】`p4_proxy/proxy_agent/main.py:1006,1963`、`p4_proxy/proxy_agent/p4_client.py:764` |
| `counters` | 部分 | (b)(c) 【跑過】counter 在 NDTwin fabric 上會動：p4runtime s1 `ingressTunnelCounter 100` 到 3505 packets，flowcache 也有讀數。但讀它們的都是 exercise 自己的控制器。NDTwin 的 `GET /p4/counter/{name}` 沒被任何 arm 或 live 腳本呼叫過，只有讀碼 | 【跑過】`R/2026-09-27T081205Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log:110-122`、`R/2026-09-27T081256Z_flowcache_solution_ndtwin/driver-controller-flowcache.log:15-16`；【讀碼】`p4_proxy/proxy_agent/api_routes.py:958`、`p4_proxy/proxy_agent/p4_client.py:1573` |
| `meters` | 做不到 | 13 支都不需要（GAP-1 §4b）。NDTwin 仍沒有 MeterEntry，北向三個 meter 端點回 `unsupported_on_p4`。只有讀碼 | 【讀碼】`src/ndt_core/routing_management/P4RoutingStrategy.cpp:31-33`、`p4_proxy/proxy_agent/p4_client.py`（`git grep MeterEntry` 無命中） |
| `registers` | 部分 | (a) firewall（bloom filter）與 link_monitor 的 register 在資料面跨封包保持狀態：firewall 擋下 h3→h1，link_monitor 回報非零埠【跑過】。但 NDTwin 沒有任何 RegisterEntry 讀寫路徑，twin 看不到 register 值（讀碼）。（Adam 2026-09-28 裁定）：GAP-1 §4b 說這兩支只需要資料面狀態，照那個讀法是「做得到」 | 【跑過】`firewall/sol:707`、`link_monitor/sol:754`；【讀碼】`p4_proxy/proxy_agent/p4_client.py`（`git grep RegisterEntry` 無命中） |
| `digest` | 做不到 | 13 支都不需要（GAP-1 §4b）。stream receiver 只認 `packet`／`arbitration`，其餘印一行 unknown 就丟。只有讀碼 | 【讀碼】`p4_proxy/proxy_agent/p4_client.py:526-545` |
| `packet_io` | 部分 | (b) 【跑過】flowcache 綠。它要的 CPU port 510 由 NDTwin 從 package 帶進 bmv2 `--cpu-port`（pre-flight PASS 510）。但 packet-in／out 全走它自己的控制器；external 模式下 proxy 不開 stream，NDTwin 對外來程式沒有 packet-io 路徑 | 【跑過】`flowcache/sol:104,60`、`R/2026-09-27T081256Z_flowcache_solution_ndtwin/driver-controller-flowcache.log:12-16`；【讀碼】`p4_proxy/mininet/p4_testbed_topo.py:225-226`、`tools/p4_exercise/convert.py:195-232`、`p4_proxy/proxy_agent/main.py:1813` |
| `custom_headers` | 部分 | (a) 7 支自訂標頭 exercise 的解答臂全綠【跑過】。但 twin 端只有 p4runtime 的 0x1212 tunnel 流量有鏈路使用率的活證據（見 §3）；其餘自訂標頭流量都沒量過。讀碼上 kernel 先記鏈路位元組再看幀是什麼，而非 IPv4 的流身份只進上限 1024 筆的側表、不進流表 | 【跑過】`T06:2-27`、`p4runtime/sol:611-613`；【讀碼】`src/ndt_core/collection/FlowLinkUsageCollector.cpp:1572-1631,1635,1642`、`include/ndt_core/collection/FlowLinkUsageCollector.hpp:747` |
| `queue_metadata` | 做得到 | 【跑過】佇列靠 NDTwin 把 s1:3↔s2:3 整形成 0.5 Mbit/s 來形成：ecn 解答臂 h2 看到 tos `0x3`；mri 的 raw 裡有 `qdepth = 63`（未斷言）。（Adam 2026-09-28 裁定）：twin 不讀 qdepth，但那是逐包 metadata，不算 (a)；`--priority-queues` 沒有，13 支也都沒用 | 【跑過】`ecn/sol:468-469,1122`、`mri/sol:699`；【讀碼】`p4_proxy/mininet/p4_testbed_topo.py:378,933-955` |
| `checksum` | 做得到 | 【跑過】10 支用 `update_checksum`、flowcache 另用 `verify_checksum`，解答臂全綠。firewall 的 TCP iperf h1→h3 3 s 傳了 262 MBytes，大流量沒有被 L4 checksum 擋掉。歸 NDTwin 的那一半（關主機 offload）只有讀碼 | 【跑過】`T06:2-27`、`firewall/sol:529,706`、`flowcache/sol:761`；【讀碼】`p4_proxy/mininet/p4_testbed_topo.py:474,1219` |
| `ttl_or_hop` | 做得到 | 【跑過】TTL／hop 由 exercise 的程式做、收端量得到：basic ttl 63、source_routing ttl {59, 62}、mri hop count 2 且 swid [1, 2]。這一維在路線 2 下沒有歸 NDTwin 的部分 | 【跑過】`basic/sol:770`、`source_routing/sol:779`、`mri/sol:845-846` |
| `topology` | 做得到 | 【跑過】四類拓樸都由 convert 出的 package 起，kernel 圖、拓樸檔、主機 namespace 三方一致：pod 4h/4s、三角 3h/3s、5h/3s、單交換機 calc 2h/1s 與 multicast 4h/1s。ecn／mri 的整形由 NDTwin 做；外來 fabric 的斷線由 veth 心跳判（H1 6/6 次都在 20 s 內） | 【跑過】`basic/sol:216`、`calc/sol:199`、`multicast/sol:200`、`ecn/sol:214,468-469`、`L/2026-09-26T152605Z_08_heartbeat/30_cycles.tsv:2-7`；【讀碼】`tools/p4_exercise/convert.py:317`、`p4_proxy/mininet/p4_testbed_topo.py:933-955,994-1068` |
| `control_plane_mode` | 做得到 | 【跑過】三種模式都在 NDTwin fabric 上跑過。①開機 runtime json：9 支由 NDTwin 套、0 failed。②external：proxy 不仲裁、不寫，控制器經 NDTwin 的 adapter 連上 fabric 的埠（p4runtime、flowcache）。③無：calc 0 entry 仍答 1+1=2。另外 roles 讓 NDTwin 寫外來程式的 `ipv4_lpm`，pingall 12/12 | 【跑過】`basic/sol:56-62`、`p4runtime/sol:58-60,860-862`、`calc/sol:556`、`L/2026-09-26T202055Z_07_roles_basic/32_pingall.txt:1`；【讀碼】`p4_proxy/proxy_agent/main.py:1813`、`tools/p4_exercise/run_external_controller.py:70-97` |
| `verification` | 部分 | (a) 【跑過】twin 的鏈路使用率格（G1）只在 10/13 支解答臂 PASS；source_routing／calc／load_balance 是 NOT RUN（它們的程式丟掉一般 iperf）。06 沒有逐支的陽性對照（只有 live-p1/05 在 basic 上做）。自訂標頭的流身份只進側表（讀碼）。存活偵測有：心跳 H1–H5 PASS | 【跑過】`basic/sol:771`、`source_routing/sol:668`、`L/2026-09-26T172912Z_08_heartbeat/51_06.txt:145`；【讀碼】`doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/_common.sh:958-1027,1078`、`src/ndt_core/collection/FlowLinkUsageCollector.cpp:1642` |

**計數：做得到 8、部分 6、做不到 2。**

---

## 2. 等級變了的維度（GAP-2 09-08 → 本文 09-27）

每段寫三件事：舊→新、改變它的是什麼（commit／工單）、有多少是**題目換了**（§0.1）而不是 NDTwin 多做了事。

- **`pipeline_load`　部分 → 做得到。**
  - 舊：三處寫死一份 artefact，十台同一份。
  - 改變它的：P2-A 讓每台跑 package 指定的程式（`b392f111`，TICKET-P2 §2.1；`main.py:247`）；
    P1-A 的 external 模式（`f282b895`，TICKET-P1 §2.3）讓控制器在跑時自己推。
  - 這是 NDTwin 真的多做的事。T06 裡 firewall 兩份程式同時在線，是 GAP-1 §4a 點名的最低標。
- **`tables`　部分 → 做得到。**
  - 舊：表名、action 名寫死 `ipv4_lpm`／`flow_5tuple`。
  - 改變它的：P2-B 的 generic writer 依 p4info 名字編碼（`78067633`，TICKET-P2 §2.3、§4；`p4_client.py:1318`），
    開機時套 package 的 entries（`main.py:618-665,1940`）。
  - T06 的 9 支開機灌表 exercise 全部 applied、0 failed。仍然只有 exact／lpm（13 支只要這兩種，GAP-1 §4a）；
    `journaled: false`，proxy 重啟後表項會消失（PLAN §6 選項 a，`switch_state` 有揭露）。
- **`pre_multicast`　做不到 → 做得到。**
  - 改變它的：P3-C 的 G8（`5ce3bf74`，TICKET-P3 §2.6）：`write_multicast_group`，開機套 package 的 `multicast_group_entries`。
  - multicast 解答臂的 h4 收不到，正是 group 只複製到 1、2、3 埠的結果。NDTwin 真的多做的事。
- **`registers`　做不到 → 部分（Adam 2026-09-28 裁定）。**
  - 改變它的是**題目**：register 在 exercise 自己的程式裡，bmv2 本來就保持它的狀態。
  - NDTwin 這一側**沒有新增任何碼**：沒有 RegisterEntry，twin 看不到 register 值。
  - 選「部分」而不是「做得到」的理由：GAP-1 §1 的定義是「讀／寫 P4 register」，那一半 NDTwin 仍然沒有。
- **`custom_headers`　做不到 → 部分。**
  - 兩件事一起改變它：
    - 題目換了：parser 是 exercise 自己的，7 支自訂標頭 exercise 全部轉得動。
    - P3-A 的 kernel 改動（`2a551df7`，TICKET-P3 §2.2、§2.3、§9 裁決 8①）：先記鏈路位元組、再看幀是什麼，
      非 IPv4 不再整包丟掉（`FlowLinkUsageCollector.cpp:1572-1631`）。
  - 還差兩件，所以停在「部分」：
    - 流身份：非 IPv4 只進上限 1024 筆的側表，不進流表（裁決 8① 取代了工單原本的「三家族進流表」）。
    - 活證據：只有 p4runtime 的 tunnel 流量證明 twin 算得到 0x1212 鏈路位元組（§3）。
- **`queue_metadata`　做不到 → 做得到（Adam 2026-09-28 裁定）。**
  - 題目換了：讀 qdepth 的是 exercise 的程式。
  - NDTwin 真的多做的一半：P3-B 的 G2-C（`f5ad6890`，TICKET-P3 §2.4），TCLink 只在 package 宣告整形時開
    （`p4_testbed_topo.py:933-955`）。沒有整形，qdepth 恆為 0、判定是假綠（GAP-1 §4b）。
  - 這是 judgement，理由兩條：
    - twin 不讀佇列深度；
    - mri 的 qdepth 在 raw 裡有非零值（`mri/sol:699`），但 driver 沒斷言它。
- **`checksum`　部分 → 做得到。**
  - 主要是題目換了：checksum 由 exercise 的程式算，不再受 `ndtwin_switch.p4` 只算 IPv4 header 的限制。
  - NDTwin 那一半（關主機 offload，`p4_testbed_topo.py:474`）09-08 就有，本文只有讀碼。
  - 活證據是結果面的：firewall 的 TCP 大流量真的傳過去（`firewall/sol:529`）。
- **`topology`　部分 → 做得到。**
  - 改變它的：
    - P1-A 的 G2：拓樸、主機表改讀檔（`f282b895`）。
    - P1-B 的 `convert.py`（`386eb20c`）。
    - P2-A：單交換機 package 合法（`b392f111`，TICKET-P2 §2.4）。
    - P1-D：主機介面改名 `eth0`（`8e62b423`）。
    - P3-B：整形（`f5ad6890`）。
    - 心跳段 H／W：外來 fabric 的斷線偵測（`377a1271`、`cafd518a`）。
  - 全是 NDTwin 真的多做的事。
  - 一個缺口：external 模式（p4runtime、flowcache）下 `ndt up` 不啟動心跳
    （`p4runtime/sol` 的 `switch_state` 裡 `"heartbeat": null`，:265）；那兩支的鏈路存活只有宣告值。
- **`control_plane_mode`　部分 → 做得到。**
  - 舊的阻擋是十台共用 election_id、外部控制器會被清表。
  - 改變它的：
    - P1-A 的 G3：election_id 參數化，external 模式不開仲裁 stream、不寫（`f282b895`，TICKET-P1 §2.3）。
    - P1-B 的 `run_external_controller.py`：把 tutorials 寫死的 `127.0.0.1:5005N`／device N-1 改寫到 fabric 的埠。
    - P2-B：套 runtime json。
    - TICKET-P4-roles（`572d9462`）：NDTwin 可以綁定外來程式的路由表。
    - 心跳段 W（`cafd518a`）：綁定時自動改路。
  - H1 的 6 次剪線，偵測延遲 12.2–16.8 s；剪線期間 pingall 12/12 0%
    （`L/2026-09-26T152605Z_08_heartbeat/30_cycles.tsv:2-7`、`34_pingall_cut.txt:1`）。

**等級沒變、理由變了**（不算 §2 的正文，列出來免得讀者以為沒動）：

- `pre_clone`、`counters`、`packet_io`：舊的「部分」是 NDTwin 自己的程式只有一個 session、只讀兩張表、metadata id 寫死。
  新的「部分」是 flowcache／p4runtime 跑得起來，但那一半都是 tutorials 自己的控制器做的。
  NDTwin 的新碼（P3-C 的 G7／G9a、`5ce3bf74`）沒被任何 exercise 走過。
- `verification`：從「只看得到 IPv4／兩張表」變成「G1 在 10/13 PASS、自訂標頭的流身份只進側表」。
- `ttl_or_hop`：舊的「做得到」講 `ndtwin_switch.p4` 會遞減；新的講 exercise 的程式遞減、收端量得到。
- `meters`、`digest`：13 支都不需要，NDTwin 仍無對應碼。

---

## 3. 逐支：13 支 × 兩臂（T06）

- 「紅如預期」的意思，依 `live-p1/06_thirteen.sh:107-115` 與 `live-p1/README.md` ⑥：
  - 骨架臂斷言的就是紅的那些事，所以照 exercise 說的方式表現時是 `PASS`、rc 0。
  - 例外是 basic_tunnel 與 flowcache 的骨架：它們的紅是拒絕，印 `RED ARM (1/1)`、rc 1。
- 「解答臂斷言了什麼」抄自各 arm report §5 判定表。
- 最後一欄只講**鏈路使用率**這一層，也就是 G1「link usage follows the iperf path」，見 §3.1。
  流身份沒有任何一臂斷言過。

| exercise | 骨架臂 | 解答臂 | 解答臂斷言了什麼 | twin 看得到這支的流量嗎（證據等級） |
|---|---|---|---|---|
| basic | 紅如預期 `PASS (4/4)` rc 0（`074636Z`）：pingall 100%、h1→h2 0/3、h2 收 0（`basic/sk:737-739`） | 綠 `PASS (6/6)` rc 0（`074826Z`） | pingall 12/12 0%、h1→h2 3/3、send.py 的包到 h2、ttl 63、G1 PASS（`basic/sol:767-771`） | **看得到**：G1 h1→h4，主路徑 3 條（2 條交換機間）積分 > 0，9 條非路徑 0.000 bit【跑過】`basic/sol:632-651` |
| source_routing | 紅如預期 `PASS (2/2)` rc 0（`075000Z`）：h2 收 0（`source_routing/sk:738`） | 綠 `PASS (5/5)` rc 0（`075027Z`） | h2 收 2、ttl {59, 62}、h2 沒有 SourceRoute 層、ethertype IPv4（`source_routing/sol:778-781`） | **無證據**：G1 NOT RUN，解答程式丟掉沒有 0x1234 堆疊的幀，一般 iperf 過不去【跑過】`source_routing/sol:668`；0x1234 幀本身沒被量過 |
| calc | 紅如預期 `PASS (2/2)` rc 0（`075053Z`）：骨架不回答（`calc/sk:574`） | 綠 `PASS (3/3)` rc 0（`075113Z`） | 交換機回答 1+1＝2、沒逾時（`calc/sol:556-557`） | **無證據**：G1 NOT RUN（calc.p4 丟掉非 0x1234 的一切）【跑過】`calc/sol:464`；單交換機，只有 host 邊 |
| multicast | 紅如預期 `PASS (2/2)` rc 0（`075133Z`）：pingall 全不通（`multicast/sk:581`） | 綠 `PASS (6/6)` rc 0（`075305Z`） | h1/h2/h3 互通、h4 收不到、h4 發得出、冷快取下 h4 仍收不到、G1 PASS（`multicast/sol:590-594`） | **看得到**（Adam 2026-09-28 裁定）：G1 h1→h3 主路徑 s1-eth3 積分 > 0、其餘 3 條 0【跑過】`multicast/sol:487-498`。單交換機只有 host 邊；G1 的單播 iperf 沒有走到 group 複製 |
| basic_tunnel | 紅如預期 `RED ARM (1/1)` rc 1（`075454Z`）：骨架的 runtime entries 被 pre-flight 拒絕，by design（`basic_tunnel/sk:134`） | 綠 `PASS (4/4)` rc 0（`075455Z`） | `--dst_id 2` 落 h2、`--dst_id 3` 落 h3（同一 IP）、G1 PASS（`basic_tunnel/sol:833-835`） | **只看過 IPv4**：G1 PASS 用的是一般 IPv4 iperf h1→h3【跑過】`basic_tunnel/sol:707-723`；`send.py --dst_id` 的 0x1212 tunnel 包沒被量過 |
| load_balance | 紅如預期 `PASS (2/2)` rc 0（`075555Z`）：只有 h2 收到（`load_balance/sk:953`） | 綠 `PASS (2/2)` rc 0（`075630Z`） | h2 收 4、h3 收 6，兩台 server 都用到（`load_balance/sol:1000`） | **無證據**：G1 NOT RUN（s1 只轉 10.0.0.1/32，兩台真主機之間的 iperf 過不去）【跑過】`load_balance/sol:890` |
| qos | 紅如預期 `PASS (3/3)` rc 0（`075704Z`）：UDP／TCP 的 tos 都停在 0x1（`qos/sk:1300-1301`） | 綠 `PASS (4/4)` rc 0（`075747Z`） | UDP tos 0xb9、TCP tos 0xb1、G1 PASS（`qos/sol:1349-1351`） | **看得到**：G1 h1→h22 主路徑 2 條積分 > 0、9 條非路徑 0【跑過】`qos/sol:1221-1239` |
| link_monitor | 紅如預期 `PASS (4/4)` rc 0（`075848Z`）：回報的埠與使用率都是 0（`link_monitor/sk:743-744`） | 綠 `PASS (4/4)` rc 0（`075920Z`） | probe 回到 h1、四台 swid 都在、回報的埠非零、G1 PASS（`link_monitor/sol:752-755`） | **只看過 IPv4**：G1 PASS 用的是一般 IPv4 iperf h1→h4【跑過】`link_monitor/sol:618-637`；0x812 probe 幀沒被量過 |
| firewall | 紅如預期 `PASS (3/3)` rc 0（`080011Z`）：骨架下 h3→h1 連得上（`firewall/sk:701`） | 綠 `PASS (4/4)` rc 0（`080128Z`） | h1→h3 連得上、h3→h1 被擋、pingall 仍通、G1 PASS（`firewall/sol:706-709`） | **看得到**：G1 h1→h4 主路徑 3 條積分 > 0、9 條非路徑 0【跑過】`firewall/sol:572-591` |
| ecn | 紅如預期 `PASS (3/3)` rc 0（`080513Z`）：tos 一直是 0x1（`ecn/sk:1107`） | 綠 `PASS (4/4)` rc 0（`080642Z`） | 包到 h2、h2 看到 0x3（壅塞標記）、G1 PASS（`ecn/sol:1120-1123`） | **看得到**：G1 h1→h22 走 0.5 Mbit/s 瓶頸，窗口 62 s，主路徑 2 條積分 > 0、9 條非路徑 0【跑過】`ecn/sol:993-1011` |
| mri | 紅如預期 `PASS (4/4)` rc 0（`080917Z`）：hop count 0、沒有 swid（`mri/sk:818-819`） | 綠 `PASS (5/5)` rc 0（`080951Z`） | MRI option 到 h2、hop count 2、swid [1, 2]、G1 PASS（`mri/sol:843-847`） | **只看過 IPv4**：G1 PASS 用的是一般 IPv4 iperf（ihl 5、不帶 MRI option）【跑過】`mri/sol:716-734`；帶 option 的包沒被量過。非路徑 s2-eth4 讀到 143,328 bit，在一個樣本的底限之下 |
| p4runtime | 紅如預期 `PASS (4/4)` rc 0（`081131Z`）：transit rule 仍是 TODO、h1→h2 不通（`p4runtime/sk:770-771`） | 綠 `PASS (5/5)` rc 0（`081205Z`） | 控制器活著、寫了 s1/s2、transit rule 進去、h1→h2 經 tunnel 通、G1 PASS（`p4runtime/sol:859-863`） | **看得到**：G1 h1→h2，s1-eth2（交換機間）tx 4,361,273 B，比 s2-eth1（host）多 14,000 B＝3,500 datagram × 4 B（myTunnel 標頭）；同一窗口 s1 `ingressTunnelCounter 100` 到 3505 packets。所以 twin 在 s1-eth2 積分到的 29.3 Mbit 是 0x1212 幀【跑過】`p4runtime/sol:611-613`、`R/2026-09-27T081205Z_p4runtime_solution_ndtwin/driver-controller-p4runtime.log:122` |
| flowcache | 紅如預期 `RED ARM (1/1)` rc 1（`081255Z`）：骨架 p4c 拒編，by design（`flowcache/sk:91`） | 綠 `PASS (5/5)` rc 0（`081256Z`） | 控制器活著、寫了 s1–s3、快取了被 punt 的流、快取熱了之後 h1→h2 5/5、G1 PASS（`flowcache/sol:758-762`） | **只看過 IPv4**（Adam 2026-09-28 裁定）：本輪 G1 PASS，但 iperf 在 s3 被丟、只有 s1→s3 那一段有流量（見 §4-1；09-19T151139Z 同一樣子）；twin 對那一段 > 0、其餘 0【跑過】`flowcache/sol:588-604`。同一臂 09-26 那輪 h1→h3 兩條主路徑都 > 0【跑過】`R/2026-09-26T175515Z_flowcache_solution_ndtwin.md:593-594,604`（trunk `3f8c2abf`；它與 `5dc7fc9a` 在 `src/`、`p4_proxy/proxy_agent/`、`p4_proxy/mininet/` 無 diff） |

**彙總：跑得起來 13／13；twin 看得到 6、只看過 IPv4 4、無證據 3。**

### 3.1 最後一欄怎麼判的，以及它不能說什麼

- **G1 斷言什麼**（【讀碼】`live-p1/_common.sh:1078-1171`、`:958-1027`）：
  - 地面真相：iperf 窗口前後各讀一次 `/proc/net/dev`，每個 `sN-ethP` 的 tx 增量分三類：
    - 主路徑：≥ max(10 kB, 5% × 最大增量)；
    - 次要；
    - 非路徑：≤ 10 kB。
  - twin 的讀數：4 Hz 輪詢 `/ndt/get_graph_data` 的 `link_bandwidth_usage_bps`，對時間積分。
  - 斷言三條：主路徑積分 > 0；非路徑積分 < 一個樣本的量（256 × 1500 × 8 = 3,072,000 bit）；主路徑集合不能是空的。
- **它不斷言封包送達**：
  - 主路徑是「真的搬了位元組的介面」，不是「從 h1 到終點的那條路」。
  - 流在半路被丟，G1 照樣可以 PASS，而且那不算錯，twin 確實跟著位元組走。§4-1 就是這種情況。
- **它用的是一般 IPv4 UDP iperf**（`-u -b 2M -l 1200`，`_common.sh:677,692,695`），不是 exercise 自己的流量。
  - 所以對自訂標頭 exercise，G1 PASS 只證明 twin 看得到**那個 fabric 上的 IPv4**。
  - 唯一的例外是 p4runtime：它的控制器把 h1→h2 的 IPv4 包進 0x1212 tunnel。
- **05 沒有補上自訂標頭**：
  - `live-p1/05_link_usage_generic.sh:43-45,57-70` 三組全用 `exercises/basic`。
  - 它的陽性對照（telemetry `none` ⇒ 主路徑必須恰為 0）只在 basic 上做。
  - T06 的 13 支沒有逐支的陽性對照。
- **骨架臂一律不跑 G1**（`drive_exercise.py:2590-2592`）。
- **流身份**：
  - 沒有任何 arm report 抓 `/ndt/get_sflow_stats`，所以 raw 裡沒有任何 tutorials 自訂標頭的 `non_ipv4_flows` 項。
  - 側表在 live 裡確實記過東西，但那是 NDTwin 自己 pipeline 上的 LLDP（`0x88cc`），不是 exercise 的流量
    （`doc/audit/2026-09-19_telemetry-three-groups/raw/2026-09-19T115737Z_full/G3/se_link_20M_p1/sflow_after.json:1`）。

---

## 4. raw 與 PLAN／TICKET 說法對不上的地方

1. **flowcache／solution 的 G1 在 T06 PASS，但 iperf 一個 datagram 都沒到 h3。**
   - 【跑過】觀測：
     - `R/2026-09-27T081256Z_flowcache_solution_ndtwin/link_usage/iperf_client.txt:9-10`：
       `Sent 3500 datagrams` 後是 `WARNING: did not receive ack of last datagram after 10 tries.`
     - `iperf_server.txt` 沒有任何報告列。
     - `onpath.txt` 只有 `s1-eth3 P 4593189`；s3-eth1 在 `netdev.before`／`after` 只動了 273 B。
     - 控制器 log（`driver-controller-flowcache.log:34-44`）：s1 為 h1→h3 流裝了項（:34），
       接著又收到同一流的 PacketIn，然後是 `gRPC error ... StatusCode.UNKNOWN`（:39-44），此後沒有 s3 的項。
     - 這不是第一次。`R/` 底下 7 份有 G1 iperf 資料的 flowcache 解答臂裡，2 份是這個樣子：
       - `R/2026-09-19T151139Z_flowcache_solution_ndtwin/`：只有 `s1-eth3` 是主路徑；控制器 log 同樣在 :34 裝 s1、:39 gRPC error。
       - 本輪 T06。
     - 另外 5 份（09-24 兩次、09-26 三次）送到了：s3-eth1 是主路徑，iperf 2/3499 lost。
       那 5 份的控制器 log 也以 gRPC error 結尾，只是在 s3 的項裝好之後才發生。
   - 對照的說法：
     - TICKET-P3 §9 裁決 28①／31① 的用意是「控制器死了，G1 不得 PASS」；
     - `live-p1/_common.sh:1096-1101` 的註解寫「NOT RUN is the honest answer; PASS is never one of the options」。
   - 但存活只在窗口開始前查一次（`_common.sh:1102`），窗口中途停擺查不到。
   - 【推論，未驗】tutorials 控制器對同一流的第二個 PacketIn 再寫一次表，拿到 gRPC UNKNOWN 就不再處理 PacketIn。
     s3 的第一個 PacketIn 若排在那之後，s3 永遠學不到這條流。這是 exercise 控制器的競賽，不是 twin 的錯；
     行程當時是否還活著，raw 沒記。
   - arm 本身的判定仍是對的：h1→h2 5/5 是在 G1 之前量的。問題在於 G1 的 PASS 不含「流量送達」，讀者不能拿它當送達的證據。
2. **PLAN §8.3 第一條（「鏈路使用率…B 模式下 13/13 與任何 app 都 100% 可觀測」）與 §8.5 階段三
   （「通用格：任一 app 下 iperf h1→hN …」）比 raw 說得多。**
   - raw：G1 只在 10/13 支解答臂跑了；source_routing／calc／load_balance 是 NOT RUN。
   - 這三支的程式本來就丟掉一般 iperf，NOT RUN 有照實記，不是隱瞞。
   - 但「與程式無關、13/13」在這三支上沒有活證據，只有讀碼（`FlowLinkUsageCollector.cpp:1572-1631`）。
3. **PLAN §1 的 L3（Adam 09-17 選的檔位）說要讓 6 支自訂標頭 exercise「也可觀測」；
   TICKET-P3 §2.3 寫的是 `FlowKey` 三家族進流表。**
   - 實作依裁決 8① 改成非 IPv4 只進側表（上限 1024，`FlowLinkUsageCollector.hpp:747`），
     `getFlowInfoJson` 的 `family` 恆為 `ipv4`。這是被接受的裁決，不是違規。
   - 但 raw 裡沒有任何一份證明 tutorials 的自訂標頭流量出現在側表（§3.1）。
   - 鏈路位元組這一層，只有 p4runtime 的 0x1212 有活證據。
   - ⇒ 對外說「L3 達成」目前沒有 raw 撐。
4. **骨架臂的 G1 NOT RUN 理由句比 raw 說得多。**
   - `drive_exercise.py:2591-2592` 對**每一個**骨架臂印「the skeleton arm is a fabric the exercise says should not forward」。
   - 但 firewall 骨架 pingall 12/12 0%（`firewall/sk:702`），qos 骨架 UDP／TCP 各 6 包到 h2（`qos/sk:1299`），
     ecn、mri、link_monitor 骨架也都轉發。
   - 同一函式的 docstring 寫的是「for most of these exercises」，句子沒跟上。
   - 不影響任何判定（骨架臂本來就不該有 G1）。
5. **`live-p1/README.md:80-82`（② 的「entries_recorded: 5 是記錄了五筆、一筆都沒裝的揭露」）是階段一的文字。**
   T06 的 basic 是 `recorded=5 applied=5`（`basic/sol:59-62`），README 沒有改。
6. **不是矛盾，是缺一件 raw**：
   - T06 的 run 目錄只有 `00_table.tsv` 與每臂 log，沒有 `06_thirteen.sh` 的 stdout，
     所以「PASS 06_thirteen -- 26 arm(s)」那一行沒有被存下來。
   - 對照：H5 那輪有存，`L/2026-09-26T172912Z_08_heartbeat/51_06.txt:145`。
   - 本文「26 臂都照預期」是我拿 `T06` 的 rc 與 verdict 對 `06_thirteen.sh:107-115,142-155` 的規則讀出來的，不是一行被記下的判決。
   - 同樣，08 的 H1–H4 那輪（`L/2026-09-26T152605Z_08_heartbeat`）也沒有存下 stdout 的 PASS 行。
     本文只引它的逐檔 raw：`30_cycles.tsv` 的 `strict_20s` 全是 yes、`34_pingall_cut.txt:1`、`82_flowentry_*.code` 全是 409。

---

## 5. 讀了什麼／沒讀什麼

- **逐行讀完**：
  - `GAP-2-ndtwin-p4-capabilities.md`、`PLAN-0917-exercise-support.md`、`TICKET-P3-observation.md` §0–§8 與 §9 裁決 1–39；
  - `live-p1/README.md`、`live-p1/06_thirteen.sh`；
  - `live-p1/_common.sh:600-1180`（G1 全部）；
  - `doc/audit/2026-09-25_p4-heartbeat/TICKET-P4-heartbeat.md`；
  - `T06` 與 26 份 arm report 的表頭、§3b、§5；
  - `basic/sol` 全文。
- **只讀相關段落**：
  - GAP-1 §1、§2、§4；TICKET-P2 §2–§6；
  - 各 arm report 的 G1 段、`ndt status` 段、`switch_state` 的 `pre_entries`；
  - flowcache 與 p4runtime 的控制器 log；
  - `drive_exercise.py:2570-2660`；
  - `p4_proxy/proxy_agent/main.py`（230-268、337-362、610-665、1006、1810-1970）、`p4_client.py:520-548`；
  - `p4_testbed_topo.py`（215-232、474-480、933-955）；
  - `FlowLinkUsageCollector.cpp`（1040-1060、1430-1660）。
- **只看標題**：TICKET-P1／P1C／P1D／P2D／P2E／P2F（本文要的事實都在 TICKET-P2／P3 與 raw 裡找得到）。
- **tutorials 原始碼**（不在 trunk，不算【讀碼】，只拿來解釋 raw）：
  - `~/tutorials/exercises/p4runtime/advanced_tunnel.p4:7,123-127`（0x1212、`myTunnel_ingress`）；
  - `~/tutorials/exercises/p4runtime/solution/mycontroller.py:192-193`（tunnel 100 ＝ s1→s2，目的地 10.0.2.2）；
  - `~/tutorials/exercises/flowcache/solution/mycontroller.py:36,167-170`（控制器自己寫 clone session 57）。
- **明確沒做的**：
  - 沒跑任何東西；
  - 沒讀 P1–P2 的 SUMMARY／judge 檔；
  - 沒核對 audit-raw 的 commit 是否已收 T06；
  - 沒讀 `08_heartbeat.sh` 除了 34／37 那幾行以外的判定碼；
  - H2（心跳不跑時 `is_up` 保持 true）的 raw 沒逐檔讀，只憑工單描述與檔名存在。
