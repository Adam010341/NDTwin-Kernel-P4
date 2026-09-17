# GAP-2 — NDTwin P4 平面「今天做得到什麼」供給側盤點

[Co-developed with claude code -- Adam]

對表對象：`GAP-1-exercise-requirements.md`（需求側，另一支 agent 撰寫）。英文維度鍵兩份共用。

## 0. 怎麼讀這份文件

- **全部是【讀碼推導】**：本輪沒起 fabric、沒跑 bmv2／Mininet／`ndt`、沒編譯。每一條主張後面附
  `檔:行`；要推翻任何一條，去讀那一行。讀的是 trunk `1a284f75` 的 working tree，
  `p4_proxy/mininet/host_count_override` 是未提交修改（內容 `4`），引用時已標明。
- **「做得到／部分／做不到」的判準是「今天不改任何一行碼」**：要改碼才成立的一律記成
  「做不到」或「部分」，並在 §2 指出要改哪裡。
- 本文**只盤點與指出改動位置**。候選改法 A／B 是選項，不是裁決；裁決留給 Adam。

---

## 1. 能力矩陣

| 維度 | 今天 | 一句依據 | 主要寫死處 |
|---|---|---|---|
| `pipeline_load` | 部分 | 推得動 `SetForwardingPipelineConfig`，但 artefact 路徑三處寫死、十台同一份 | `proxy_agent/main.py:185-186`、`mininet/p4_testbed_topo.py:360,624`、`mininet/ntg_bmv2_topo.py:66` |
| `tables` | 部分 | id 由 p4info **按名字**查（不寫死 id），但表名／action 名／參數名／key 位寬全寫死 | `p4_client.py:729,761,846,856,697-704` |
| `pre_multicast` | 做不到 | p4info 無 multicast 實體，proxy 無任何 `MulticastGroupEntry` 寫入 | `p4_src/build/ndtwin_switch.p4info.txt`（無此段） |
| `pre_clone` | 部分 | 只有一個 session：250 → CPU port 255，兩個常數都寫死 | `p4_client.py:31-32`、`ndtwin_switch.p4:45,48` |
| `counters` | 部分 | 兩張 ingress 表的 direct_counter 有讀；indirect 的 `egress_port_counter` 無生產讀者 | `p4_client.py:629,651-652`、`ryu_flow_stats.py:175-176` |
| `meters` | 做不到 | 程式無 meter，北向六個 group/meter 端點一律 `unsupported_on_p4` | `P4RoutingStrategy.cpp:27-33` |
| `registers` | 做不到 | `ndtwin_switch.p4` 無 `register`，proxy 無 `RegisterEntry` RPC | `ndtwin_switch.p4`（grep 無）、`p4_client.py`（無此 RPC） |
| `digest` | 做不到 | 程式無 `digest()`，stream receiver 只認 `packet` 與 `arbitration` | `p4_client.py:158-174` |
| `packet_io` | 部分 | 兩個方向都通，但 metadata id 寫死、packet-out 只有 LLDP 一個生產呼叫者 | `sflow_emitter.py:425-429`、`p4_client.py:217,222` |
| `custom_headers` | 做不到 | parser 只認 IPv4；非 IPv4 樣本被 kernel sFlow 解析器整包丟掉 | `ndtwin_switch.p4:227-231`、`FlowLinkUsageCollector.cpp:1266-1279` |
| `queue_metadata` | 做不到 | P4 程式完全沒讀 `standard_metadata` 的佇列欄位，bmv2 也沒開 `--priority-queues` | `ndtwin_switch.p4`（grep 無 `qdepth`）、`p4_testbed_topo.py:256-273` |
| `checksum` | 部分 | verify 為空、compute 只做 IPv4；L4 checksum 不會被重算 | `ndtwin_switch.p4:272-274,463-481` |
| `ttl_or_hop` | 做得到 | `ipv4_forward` 帶保護的遞減；但沒有 TTL-expired 上送 CPU 的路徑 | `ndtwin_switch.p4:292-301` |
| `topology` | 部分 | schema 表達力夠（任意圖），但選檔只看主機數、proxy 主機表用四等分公式、無鏈路整形 | `p4_testbed_topo.py:86-134`、`main.py:113-120,154`、`p4_testbed_topo.py:662` |
| `control_plane_mode` | 部分 | kernel→proxy→P4Runtime 全通；十台 client 共用同一個 election_id | `p4_client.py:234-235,60-72` |
| `verification` | 部分 | 觀測面五個端點＋合成 sFlow 齊備；但只看得到 IPv4／兩張表 | `api_routes.py:78,110-143,479,502`、`ryu_flow_stats.py:40-48` |

**計數：做得到 1、部分 9、做不到 6。**

---

## 2. 逐維度

### `pipeline_load`
現況：`set_forwarding_pipeline_config()` 用 `VERIFY_AND_COMMIT` 送 p4info＋device config
（`p4_client.py:318-327`）；`main.py` 對 dpid 1..10 各建 client、批次推（`:190-208,267-277`），
推完才程式化 clone session（`:288-316`）。
寫死處：artefact 路徑在 `main.py:185-186`，Mininet 端另有三份獨立抄本
（`p4_testbed_topo.py:360,624`、`ntg_bmv2_topo.py:66`）。**bmv2 在 exec 時載入 json 且不重載**
⇒ 換 pipeline＝重建 fabric（`ndt:720-724` 的 `stale_pipeline` 就是為此存在）。
要改成通用要動：`main.py`（路徑來源）、`p4_testbed_topo.py`（`json_path` 參數已存在，只差來源）、
`ntg_bmv2_topo.py`、`tools/test_workflow/ndt`（`sample_rate`／`stale_pipeline` 讀同一個寫死路徑）。
候選 A：一個 `NDTWIN_P4_PIPELINE_DIR` 環境變數，四處共讀一個 helper。~40 行，不動遙測；
但 `ndt` 的 `sample_rate()` 逆解 `modify_field_rng_uniform`（`ndt:643-661`）對別人的程式回 `unknown`。
候選 B：per-dpid pipeline（manifest 帶 json 路徑）。~150 行，動 `build_p4_client` 簽章與 readopt，
且遙測與契約測試全部假設十台同一份 p4info。

### `tables`
現況：id 一律**用名字向 p4info 查**（`p4_client.py:459-481`），所以 p4info id 不寫死、重編可跟上。
寫死的是**名字**：`MyIngress.flow_5tuple`（`:729,733`）、`MyIngress.ipv4_lpm`
（`:846,850,926,930,975,979`）、action `MyIngress.ipv4_forward` 與參數 `dstAddr`/`port`
（`:761-767,856-866,985-995`）。key 位寬另有一份手寫表 `_FIVE_TUPLE_KEY_BYTES`（`:697-704`），
與 p4info 的 `bitwidth` 是兩份真相。
北向能表達的 match 欄位只有 `FIVE_TUPLE_FIELD_MAP` 十二個拼法（`topology_manager.py:193-207`），
其餘一律 400（`:276-307`）；action 只認 `OUTPUT`（`:884-891`）。
要改成通用要動：`p4_client.py`（表名參數化、位寬改讀 p4info）、`topology_manager.py`（欄位對映）、
`ryu_flow_stats.py:40-54`（回報方向的反向對映）。
候選 A：三個表名提成 class 常數＋位寬改讀 p4info。~60 行，`test_p4_client_writes.py`／
`test_five_tuple_match.py` 要跟著改。
候選 B：由 p4info 驅動 match/action 組裝的 generic writer。~400 行，會把 `ryu_flow_stats` 的
Ryu 形狀契約整個拉進來重談。

### `pre_multicast`
現況：**沒有任何 multicast group 的寫入路徑**。p4info 無 PRE multicast 實體；`proxy_agent/` 全域
grep 只在 `p4_client.py:355,369` 的 docstring 出現 multicast——那是在描述 bmv2 拿 mgid
`0x8000+session` 當 clone session **後端**的實作細節，不是我們程式化的東西。P4 程式也沒有
`mcast_grp` 賦值。⇒ tutorials 的 `multicast` 練習在今天的 NDTwin 上**沒有控制面**。
要改成通用要動：`p4_client.py`（新增 `write_multicast_group()`，形狀與 `write_clone_session()`
對稱：`packet_replication_engine_entry.multicast_group_entry`）、`ndtwin_switch.p4`（一個設
`standard_metadata.mcast_grp` 的 action）。
候選 A：只加 client 方法＋`POST /p4/multicast_group`。~80 行，不動遙測；但 kernel 北向沒有對應
概念，只有測試腳本會用。
候選 B：接上 OpenFlow group 語意（`P4RoutingStrategy.cpp:27-29` 現在是明確拒絕）。~300 行以上，
且 pipeline 要長出 ActionSelector——Phase 4 的未竟工作（`P4RoutingStrategy.hpp` class docstring）。

### `pre_clone`
現況：**遙測用**。pipeline 在 ingress 以 1/256 隨機 clone 到 `SAMPLE_SESSION=250`
（`ndtwin_switch.p4:48,52,405-413`），egress 認出 `instance_type==1` 後補 `packet_in` 標頭並
`truncate(128)`（`:428-448`）。session 由 proxy 建（`write_clone_session()`：
DELETE→INSERT→settle 的 DELETE+INSERT，replica `egress_port=255, instance=1`，`p4_client.py:338-456`），
**必須在 pipeline 推完之後**（`main.py:288-316`、`p4_client.py:252-263`）。CPU port 255 由 bmv2 旗標
`--cpu-port 255` 給（`p4_testbed_topo.py:273-274`），與 `ndtwin_switch.p4:45`、`p4_client.py:32`
是三份抄本。寫死處：session id 250、port 255、truncate 128、rate 256，全是編譯期常數。
候選 A：`write_clone_session(session_id, egress_port)` 本來就是參數（`:338`），只要暴露一個呼叫點
就能建第二個 session。~20 行，**不動遙測**（既有 250 不變）。
候選 B：讓 SAMPLE_RATE 執行期可調——做不到。它是 P4 常數，`ndt:643` 只能**讀**出編譯進 json 的值，
改它一定要重編＋重建 fabric。

### `counters`
現況：兩張 ingress 表各掛 `direct_counter`（`ndtwin_switch.p4:285-286,346,362`）；
`read_table_entries` 要在 ReadRequest 裡 `counter_data.SetInParent()` 才拿得到值
（`p4_client.py:554-561`，缺這行會全回 0 且不報錯），再由 `entry_to_ryu` 填成
`byte_count`/`packet_count`（`ryu_flow_stats.py:175-176`）。
egress 另有 indirect `counter(512)`（`ndtwin_switch.p4:425`），`read_egress_counter()` 三態回傳
（`p4_client.py:631-690`），但 **docstring 自陳「There are no production callers today」**
（`:651-652`）——量測腳本用得到，NDTwin 本身不讀。
限制：`entry_to_ryu` 對 `is_default` 與「沒有可對映 match」的條目回 `None`（`ryu_flow_stats.py:148-154`）
⇒ 那些 entry 的 counter 永遠不會出現在北向。
候選 A：加 `GET /p4/counter/{name}`，重用 `read_egress_counter` 的三態契約。~50 行，不動遙測。
候選 B：把 counter 併進 `/stats/flow/{dpid}`。會改變 kernel `Classifier` 讀到的 body 形狀，
碰契約測試（`tests/test_P4FlowStatsToClassifier.cpp`）。

### `meters`
現況：**完全沒有**。`ndtwin_switch.p4` 無 `meter`/`direct_meter`，p4info 無 meter 實體，
`p4_client.py` 無 `MeterEntry`。北向三個 meter 端點明確回 `unsupported_on_p4`
（`P4RoutingStrategy.cpp:31-33`，共用 `refuse()` `:11-23`）。
⇒ tutorials 的 `qos`／限速類練習**兩層都缺**：pipeline 沒 meter，控制面沒路由。要動的是
`ndtwin_switch.p4`（宣告 meter＋`execute_meter`）、`p4_client.py`（`MeterEntry`）、
`P4RoutingStrategy.cpp`、`api_routes.py`。
候選 A：只做 data plane ＝ 練習能跑但 NDTwin 看不到。~30 行 P4。
候選 B：接到北向 `/ndt/install_meter_entry`。~250 行跨三層，且 `refuse()` 的措辭是 F-13 的裁決結果，
動它要重談。

### `registers`
現況：**完全沒有**。P4 程式無 `register`；proxy 無 `RegisterEntry` 的 read/write。
⇒ tutorials 裡吃 register 的（`link_monitor`、`flowcache`、`load_balance` 的狀態、`mri` 的
部分變體）沒有任何控制面讀寫路徑；資料面若自己用 register，NDTwin 也讀不到它的值。
要改成通用要動：`p4_client.py`（`entity.register_entry`，read 與 write 兩支，形狀跟
`read_egress_counter` 幾乎一樣）、`api_routes.py`（暴露）。
候選 A：唯讀 `GET /p4/register/{name}`。~60 行，不動遙測，可直接餵給練習的驗證腳本。
候選 B：讀寫都做。多 ~40 行，但**寫 register 沒有 journal 記錄**（`rule_journal` 只認
install/delete 的 flow 語意，`topology_manager.py:949-976`），重啟後狀態靜默消失——這是本
repo 最常見的缺陷形狀，要先裁決要不要一起補。

### `digest`
現況：**完全沒有**。P4 程式無 `digest()`；`_stream_receiver` 只處理 `packet` 與 `arbitration`，
其餘一律印 "Received unknown stream message."（`p4_client.py:158-174`）——就算資料面送了 digest，
它會被當未知訊息丟掉且**只有一行 print**。⇒ tutorials 走 digest 做 L2 learning 完全不通。
要改成通用要動：`p4_client.py:158-174`（加 `elif response.HasField("digest")`）、
`ndtwin_switch.p4`（宣告 digest struct）、一個 `DigestEntry` 的訂閱寫入。
候選 A：learning 改走既有 packet-in 路（`l2_forward` 的 default 本來就是 `send_to_cpu`，
`ndtwin_switch.p4:380`）。0 行 pipeline 改動，但要在 proxy 加 learning 邏輯（今天
`handle_packet_in` 只認 LLDP，`topology_manager.py:1421+`）。
候選 B：真的做 digest。~120 行，且要留意 `handle_packet_in` 的分流理由——取樣是 1/256 的全流量，
任何新的 CPU 通道都要先想清楚負載（`p4_client.py:186-194`）。

### `packet_io`
現況：兩個方向都在用。**packet-in**：`packet_in_header_t` 六個欄位（`ndtwin_switch.p4:156-164`），
`reason` 區分「真 packet-in」與「遙測樣本」；`handle_packet_in` 先試 `sample_from_packet_in`，
不是樣本才走 LLDP（`p4_client.py:182-208`、`sflow_emitter.py:446-482`）。
**packet-out**：`send_packet_out` 只被 LLDP beacon 用（`topology_manager.py:1374-1379` 造幀）。
🔴 寫死處：**metadata id 位置相依**——`PKTIN_META_*` 1..5 是常數（`sflow_emitter.py:425-429`，
註解自陳 "They are positional, so reordering the header's fields renumbers them"），
`send_packet_out` 的 `metadata_id = 1 / 2` 是裸字面（`p4_client.py:217,222`）。
對照 p4info 確實是 reason=1、ingress_port=2、egress_port=3、frame_length=4、sampling_rate=5、
_pad=6（`ndtwin_switch.p4info.txt:210-246`）。
⇒ **換一支 P4 程式，只要 packet_in 標頭欄位順序或數量不同，`sample_from_packet_in` 就拿錯欄位當
reason／rate，而 `sampling_rate == 0` 的樣本被靜默丟棄（`sflow_emitter.py:468-470`）——遙測歸零、無錯誤。**
候選 A：開機時由 p4info 的 `controller_packet_metadata` **按名字**解析 id 存進 client。~40 行，
`test_clone_session.py` 有現成的 p4info 依賴可沿用。
候選 B：維持常數，加一個開機自檢（p4info 對不上就拒絕啟動）。~20 行，較保守。

### `custom_headers`
現況：parser 只在 `etherType == 0x0800` 時往下走，其餘一律 `accept`（`ndtwin_switch.p4:227-231`）；
非 IPv4 幀走 `l2_forward`（exact on dst MAC）或 LLDP 上 CPU（`:395-400`）。ARP 靠 topology script
預灌靜態表（`p4_testbed_topo.py:665-681`）。三層都是 IPv4-only：
① **遙測**：kernel sFlow 解析器讀到 `etherType != 0x0800` 就整個樣本跳過
（`FlowLinkUsageCollector.cpp:1266-1279`，HPE 分支 `:1327-1340` 同）。
② **流偵測**：`FlowKey` 只有 IPv4 五元組＋ICMP type/code（`SFlowType.hpp:30-47`）。
③ **流表回報**：`FIELD_TO_RYU` 只認 IPv4 欄位＋`dl_dst`（`ryu_flow_stats.py:40-48`）。
⇒ tutorials 的 `basic_tunnel`（自訂 `myTunnel` 標頭）、`source_routing`、`mri`（INT stack）：
**封包可能會轉，但分身完全看不見**——不是報錯，是報零。
候選 A：只讓自訂標頭「不打斷」既有 IPv4 遙測（外層仍是 IPv4）。0～30 行，但新欄位仍不可見。
候選 B：擴 `FlowKey` 與 C++ 解析器。碰核心＋契約測試（`test_GoldenFixture.cpp`、
`test_SFlowEmitterRoundtrip.cpp`），代價高且會動到已發表的量測口徑。

### `queue_metadata`
現況：**完全沒有**。`ndtwin_switch.p4` 全檔沒讀 `enq_qdepth`／`deq_qdepth`／`deq_timedelta`／`qid`
（grep 無命中）。bmv2 啟動旗標只有 `-i`、`--thrift-port`、`--device-id`、json、
`--grpc-server-addr`、`--cpu-port`（`p4_testbed_topo.py:256-274`）——**沒有 `--priority-queues`**；
`--log-console` 是註解掉的（`:261`），log 走 `> /tmp/{name}_bmv2.log`（`:265,278-280`），無 nanolog。
⇒ tutorials 的 `ecn`（讀 `enq_qdepth`）與 `qos`（優先佇列）：ECN 那半只改 P4 就成立（欄位 v1model
一直都在），**qos 的多佇列那半必須改啟動旗標**。
候選 A：args 加 `--priority-queues N`。~2 行，但**會改變所有既有量測的排隊行為**，bmv2 天花板那
四張工單的數字不能跨過這個改動比較（`doc/KNOWN-ISSUES.md` §F-bmv2）。
候選 B：把佇列深度也送上 CPU（放進 `packet_in_header_t`）。~30 行，但會踩到 `packet_io` 的位置
相依 id 問題，兩件事要一起做。

### `checksum`
現況：`MyVerifyChecksum` 是空的（`ndtwin_switch.p4:272-274`）——**不驗**；`MyComputeChecksum` 只重算
IPv4 header checksum（`:463-481`）。**沒有任何 L4 checksum 更新**。配套：主機端 offload 必須關掉，
否則 bmv2 的 pcap 路徑會原封轉出 checksum 未算完的 TCP 段 ⇒ 握手成功、大流量歸零
（`p4_testbed_topo.py:481-499`，含 2026-08-15 實測）。
⇒ 任何改寫 IP 位址或 L4 port 的練習（NAT、load_balance 的 DNAT 變體）會產生 **L4 checksum 錯誤的
封包**，症狀正是上面那條：小封包通、大流量停。要動的是 `ndtwin_switch.p4:463-481`。
候選 A：只在需要的練習裡加 `update_checksum_with_payload`。~25 行 P4，不動 proxy／遙測。
候選 B：加進 `ndtwin_switch.p4` 主線。同樣 ~25 行，但**改 pipeline 就要重建 fabric**，且 `ndt` 的
`stale_pipeline`／`source_ahead_of_build`（`ndt:720-737`）會擋住重用。

### `ttl_or_hop`
現況：`ipv4_forward` 先判 `ttl > 0` 再減（`ndtwin_switch.p4:292-301`），修掉了「TTL 0 減成 255
會繞圈」的舊行為。
限制：**TTL 歸零沒有任何處置**——不 drop、不上送 CPU，就是照樣轉出去且不再遞減。
所以 traceroute 類練習（靠 TTL exceeded 產生 ICMP）在這條 pipeline 上不會有回應；
ICMP 本身只被 parser 抬進 `meta.l4_src/dst_port`（`:259-266`），沒有產生 ICMP 的能力。
要改成通用要動：`ndtwin_switch.p4:292-301`（加 `if (hdr.ipv4.ttl == 0) { ... }` 分支）。
候選 A：TTL==0 就 `drop()`。~3 行，語意正確且不影響遙測（drop 的封包不進 egress counter）。
候選 B：TTL==0 上送 CPU 讓控制面產生 ICMP。~10 行 P4 ＋ proxy 端一個新的 packet-in reason
——又是 `packet_io` 的位置相依問題，兩件事綁在一起。

### `topology`
schema（實讀 `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`）：`nodes[]` 帶
`vertex_type`(0=switch,1=host)、`dpid`、`ip`(**list**)、`mac`(整數)、`bridge_name`、`brand_name`、
`device_layer`、`smart_plug_ip/outlet`、`ecmp_groups`；`edges[]` 帶 `src_dpid`/`src_interface`/
`src_ip[]`＋對應 `dst_*`＋`link_bandwidth_bps`（雙向各一筆，host 側 dpid=0）；頂層有一個空的 `links: []`。
`topo_from_json` 只要求 dpid 唯一（`:66-72`）、至少一條交換機間鏈路（`:113-114`）、
每台 host 只接一次（`:145-147`）⇒ **三角形、pod 拓樸 schema 完全表達得出來。** 擋住的是三件事：
① **選檔只看主機數**（`p4_testbed_topo.py:120-134`）——同樣 4 host 的三角形會撞上現有 10 交換機檔；
`NDTWIN_P4_TOPO_FILE` 可指定但**仍被 host 數核對**（`:99-118`）。
② **proxy 主機表不讀拓樸檔**：`main.py:113-120` 用四等分公式 `dpid = 1+(i-1)//(N//4)`、
`port = 3+(i-1)%(N//4)`，只讀 `host_count_override`（目前 `4`，未提交）⇒ 非四等分擺法會記錯位置。
③ **交換機清單寫死十台**（`main.py:154`：'deriving them from the topology JSON is Phase 3 work'）。
另外：**`link_bandwidth_bps` 在 P4 fabric 上完全沒被套用**——`p4_testbed_topo.py:662` 的 `Mininet()`
沒有 `link=TCLink`，全檔無 `bw=`/`delay=`；kernel 只把它當宣告值（`GraphTypes.hpp:581,682`）。
候選 A：`main.py` 主機表改讀 `topo_from_json.host_links()`。~25 行，消掉抄本 ②。
候選 B：連交換機清單一起由拓樸檔推導。~60 行，動到 `startup()` 回傳契約與 `test_startup.py`。

### `control_plane_mode`
現況：kernel → REST（Ryu 形狀）→ proxy → P4Runtime。開機灌的是 `install_initial_routes`：
對每台 host 算 BFS 最短路，在每台交換機寫一條 `ipv4_lpm` 的 `/32`（`topology_manager.py:1151-1208`）；
之後**任何鏈路轉換都整批重寫**（`route_flow` docstring `:856-859`）。
北向端點 `/stats/flowentry/{add,delete,delete_strict,modify}`（`api_routes.py:310,379-380,417`）：
match 只有目的地 ⇒ `ipv4_lpm`，多於目的地 ⇒ 三元 `flow_5tuple`（`topology_manager.py:332-342`）；
priority 在前者不可表達，add 回 `priority_honoured: false`（`api_routes.py:367-376`）、
delete/modify 直接 501（`:230-288`）。
🔴 **外部控制器同時寫表**：十個 client 全投同一個寫死的 `election_id (0,1)`（`p4_client.py:234-235`）。
`p4_client.py:60-72` 記錄 2026-08-13 實測——P4Runtime 用訊息裡的三元組（不是連線）辨識送出者，
「冒名者」的 stream 被殺、但它的 `SetForwardingPipelineConfig` 被接受、**清空每一張表**、回報成功。
⇒ **同時掛一個外部 P4Runtime 控制器（tutorials 的 `mycontroller.py` 正是這形狀）是危險操作。**
候選 A：election_id 提成參數，NDTwin 用高值。~15 行，不動遙測；
`p4_proxy/reference/p4runtime_mastership_probe.py` 有現成驗證腳本。
候選 B：加「唯讀模式」讓 proxy 不搶 mastership。~50 行，但 `install_initial_routes`、
clone session、readopt 全部依賴寫入權，要一併裁決該模式下關掉哪些功能。

### `verification`
今天就能用的觀測面：`GET /p4/switch_state`（只報事實不下判決，`api_routes.py:479-499`）、
`GET /stats/flow/{dpid}`（兩張 ingress 表翻成 Ryu 形狀，`api_routes.py:502`、
`ryu_flow_stats.py:187-199`；讀失敗回 503＋`{"error":...}`，**不回空表**）、
`GET /v1.0/topology/{switches,links,hosts}`（dpid/port 是**十六進位字串**，`ryu_topology.py:64-85,455-486`）、
`GET /ryu_server/all_destination_paths`（`{"status":"success",...}` 信封，`api_routes.py:146-166`）、
`GET /sflow/stats`（送端累計，未注入回 503 而非零，`api_routes.py:78-107`）、
合成 sFlow v5 → UDP 6343（佈局逐字對齊 OVS 抓包，`sflow_emitter.py:14-60`）、`ndt verify_p4`
（`ndt:1173-1280`：路徑數**連續兩次**穩定、kernel graph／拓樸檔／`fabric_host_count()` 三方一致、真 ping）。
盲點：只看得到兩張 ingress 表（`l2_forward` 無 counter，`ndtwin_switch.p4:366-381`）、
`egress_port_counter` 無生產讀者、非 IPv4 一律不可見（見 `custom_headers`）。
測試覆蓋（**只讀 docstring，不代表跑過綠**）：clone session、五元組 match、flow-stats 路由、
sFlow 位元組級對照、LLDP beacon／watchdog、readopt、port guard、rule journal 與 wiring、
table generation、path determinism；**沒有** register／meter／digest／multicast／queue 的任何測試。

---

## 3. 架構級觀察（只寫有依據的）

1. **遙測依賴程式合作，換程式＝遙測全滅且無錯誤。** 鏈路：`clone_preserving_field_list(250)`
   →`instance_type==1` 補 `packet_in` →PI 轉 typed metadata →`sample_from_packet_in` 依 id 讀 →合成
   sFlow →UDP 6343（`ndtwin_switch.p4:405-448`、`sflow_emitter.py:446-482`）。任一環對不上都是**靜默
   歸零**：session 沒建 bmv2 直接丟 copy（`p4_client.py:342-344`）、`sampling_rate` 讀成 0 就丟樣本
   （`:468-470`）、agent IP 不在拓樸檔就歸屬於無（`:311-320`）。⇒ **換一支 .p4，NDTwin 每個速率／鏈路使用率都會是 0 且無錯誤訊息。**

2. **p4info id 的位置相依只發生在 controller header，不在 table。** table/action/欄位按名字查
   （`p4_client.py:459-481`），重編會自動跟上；packet-in/out 的 metadata id 卻是硬編的 1..5 與 1/2
   （`sflow_emitter.py:425-429`、`p4_client.py:217,222`）。`packet_in_header_t` 有 6 個欄位，**任何一次增刪或重排都讓 1..5 全錯位**，後果不是例外、是上一條的靜默歸零——改動最小、後果最大的一處。

3. **拓樸 schema 是通用的，綁死的是它周圍的三個推導**：選檔只看 host 數（`p4_testbed_topo.py:120-134`）、
   proxy 用四等分公式而非讀檔（`main.py:113-120`）、交換機清單寫死 1..10（`main.py:154`）。
   ⇒ 換拓樸的成本不在 JSON，在這三處。

4. **同一個常數多處各有抄本，而沒有機制保證一致**：CPU port 255 三份（`ndtwin_switch.p4:45`、
   `p4_client.py:32`、`p4_testbed_topo.py:274`）、compiled json 路徑四份、sample rate 256 是 P4 常數而
   `ndt` 只能從 json 逆解（`ndt:643-661`）。gRPC port base 已收成一份（`grpc_ports.py:48`，理由在
   `main.py:156-167`）——**這問題修過一次**，其餘幾組還沒。

5. **「pipeline 能表達」與「NDTwin 看得見」是兩件事，分歧點在 kernel 不在 proxy。** 前例：`flow_5tuple`
   從 pipeline 寫成第一天就存在，proxy 端卻長期沒有任何東西編譯到它（`topology_manager.py:180-183`）。
   今天的同形版本：非 IPv4 封包 pipeline 轉得動（`l2_forward`），但 `FlowLinkUsageCollector.cpp:1266`
   與 `FlowKey`（`SFlowType.hpp:30-47`）都看不到。⇒ **這一族（資料面做得到、觀測面看不到）才是真 gap。**

6. **P4Runtime mastership 是與外部控制器共存的硬阻擋，失敗模式是「回報成功並清空全部表」**
   （`p4_client.py:60-72`，2026-08-13 實測）。tutorials 普遍自己跑 `mycontroller.py`／
   `simple_switch_CLI`——那與 NDTwin proxy 是同一個 election_id 的競爭者。

---

## 4. 讀了哪些檔（各讀到哪）／沒讀完的

**逐行讀完**：`p4_src/SPEC.md`、`ndtwin_switch.p4`(508)、`ndtwin_switch.p4info.txt`、
`proxy_agent/SPEC.md`、`main.py`(480)、`p4_client.py`(1009)、`sflow_emitter.py`(529)、
`ryu_flow_stats.py`(199)、`api_routes.py`(568)、`mininet/topo_from_json.py`(148)、
`P4RoutingStrategy.{cpp,hpp}`、`setting/AppConfig.hpp`、本目錄的 `COMPILE-MATRIX.txt`。

**只讀相關段落（括號內是未讀的部分）**：
- `topology_manager.py`(2000) — 讀 150-370、396-520、640-700、738-760、821-1010、1151-1230、
  1374-1470（**未讀** unroute/modify 1011-1150、readopt 1222-1373、watchdog 1470-2000）。
- `ryu_topology.py` — 讀 60-130、455-486（**未讀** `render_destination_paths` 191-454）。
- `p4_testbed_topo.py`(737) — 讀 55-160、236-300、360-500、600-681（**未讀** 500-600）。
- `ntg_bmv2_topo.py` 1-101；`grpc_ports.py` 只看常數與簽章。
- `tools/test_workflow/ndt`(229 KB) — 只讀 621-740、1012-1100、1173-1280；`stack.sh` 只讀 820-930；
  `ndtwin-lab`(745) 只 grep。
- kernel 側 — 讀 `GraphTypes.hpp:75-140,581,681-682`、`SFlowType.hpp:30-60,801-813`、
  `FlowLinkUsageCollector.cpp:1225-1350`（**只 grep**：`TopologyAndFlowMonitor.cpp`、
  `HttpSession.cpp`、`DeviceConfigurationAndPowerManager.cpp`、`P4PowerStrategy.cpp`）。
- `doc/KNOWN-ISSUES.md` — 讀 §F 全段(2399-2513)＋目錄；**A-4c/A-4d/B-2c 只看標題**，
  內文靠程式碼註解的轉述（文中已標明出處是註解）。
- `p4_proxy/tests/` — **只讀檔頭 docstring**，沒讀主體、沒執行任何一支。所以文中「有測試覆蓋」
  ＝「有一支同名測試存在且其 docstring 這麼說」，**不是**「跑過且綠」。

**明確沒做的**：沒起 fabric、沒編譯、沒跑任何測試、沒讀 `ndtwin_switch.json`(78 KB 產物) 的內容、
沒讀 `p4_proxy/reference/` 的探針腳本、沒讀 `doc/2026-07-27_p4_bmv2_support_plan.md`
（文中的 Phase 編號都是從程式註解轉述的）。
