# P4 程式驅動的 API 形狀：可行性與設計選項

> 來源：opus-worker（唯讀調查）2026-09-24 交回的全文，由 orchestrator 原樣落檔（harness 不讓 subagent 直接寫檔）。
> orchestrator 抽驗過的引用列在檔尾「抽驗」一節；判官審查結果另記在同目錄。
> [Co-developed with claude code -- Adam]

- 日期 2026-09-24。base 是 trunk `057a01f0`。作者是唯讀 worker（opus）。
- 題目（Adam 09-24）：使用者載入自己的 `.p4` 時，kernel 能不能依這支程式動態調整 API 的形狀，並做到三件事：
  (a) web-gui 等外部 app 不改碼照樣能用；(b) 交換機停用／啟用、推路由規則照樣能做；(c) 斷鏈時自動重算路徑。
- **方法：全文都是讀碼、讀檔（讀過，沒有執行）。** 執行過的只有純讀檔的解析：python one-liner 讀 `package.json` 和 live run 的 JSON，以及一支 p4info 解析腳本（p4_proxy 的 venv python，
  腳本在 session scratchpad，沒進 repo）。它的輸入是 `.test_run/packages/*-solution/build/*.p4info.txtpb`，這批檔案被
  `.gitignore:21` 排除，是本機的 build 輸出。表名另外用 grep 對過 12 支練習題 `~/tutorials/exercises/*/solution/*.p4` 的 `table` 宣告，兩邊一致；
  p4runtime 的 `solution/` 只有 `mycontroller.py`，程式在練習根目錄的 `~/tutorials/exercises/p4runtime/advanced_tunnel.p4`（`table ipv4_lpm` 在 `:143`、`table myTunnel_exact` 在 `:157`），另外單獨對過。
  沒有起 stack，沒有 build，沒有打任何 HTTP。
- **標記：** OBSERVED＝讀到的碼或檔，附 `file:line`。INFERRED＝推論或設計判斷，沒有量過。「未提交」＝共用 worktree 裡沒進版控的檔。
- **題目用詞更正：** `package.py` 實際檔名是 `p4_proxy/mininet/app_package.py`（`Package.pipeline_for` 在 `:245`）。

## 0. 結論

1. **做得到，但該動態調整的不是 kernel 北向 API 的形狀，是 proxy 裡「意圖對到哪張表」的那層綁定。**
   kernel 本身不認得 pipeline（§1.1）；web-gui 講的是 OpenFlow 形狀、內容固定的意圖（§1.2）。
   要讓這些 app 不改碼，只能把形狀固定在意圖層，由 pipeline 決定「哪些意圖可用」和「每個意圖綁到哪張表」。
2. **外來 pipeline 下 (b)(c) 做不到，主因不是表名。** 13 支 solution 裡有 8 支宣告了與 `ndtwin_switch.p4` 同名同形的
   `MyIngress.ipv4_lpm`／`ipv4_forward(dstAddr,port)`（§3）。真正擋住的是兩件事：
   ① 鏈路發現和存活偵測都靠 packet_in/out；② 沒有任何地方宣告「這張表歸誰管」。
   同名反而危險：今天沒有防護的寫入路徑會把 NDTwin 的路由寫進作者的表，同一個 /32 已存在時 INSERT 失敗、改用 MODIFY 悄悄蓋掉
   （INFERRED，沒量過；證據見 §2.1 INFERRED ①：`p4_client.py:1825-1827`、`main.py:1312-1313`、作者宣告的 /32）。
3. **建議選項 (v)，混合式（§5）。** 由 package 宣告 roles（同時表示同意和語意），用 p4info 驗證；
   啟發式只拿來在 preflight 給建議；鏈路改由拓樸檔宣告，存活偵測改用與 pipeline 無關的訊號；raw table API 保留作逃生口；
   kernel 北向端點不變，另外加能力旗標。
4. **第一刀：** `roles.ipv4_route` 加上「把宣告的鏈路放進 proxy 的圖」。這樣 (a)(b) 在 7 支同形 pipeline 上就能成立。
   (c) 要先做半天的 veth 心跳 spike（§5）。

## 1. 今天的 API 面與消費者

### 1.1 三層結構

OBSERVED
- **kernel 北向：** 45 條路由，是一條編進 C++ 的 if/else 鏈（`src/ndt_core/http/HttpSession.cpp:326-531`），不是資料驅動。全表見附錄 A。
- **kernel 到 proxy 的南向是 Ryu 形狀：**
  - 規則類 POST 到 `/stats/flowentry/{delete,delete_strict,add}`（`HttpRoutingStrategyBase.cpp:318,322,344`）；modify 走 `:386` 的 `strictModifyPath()`，
    P4 覆寫成 `/stats/flowentry/modify`（`P4RoutingStrategy.hpp:66`；`:382` 的非嚴格分支依 `:371-373` 的註解沒有呼叫會走到）。
  - `P4RoutingStrategy.hpp:12` 寫明「deliberately impersonates Ryu's northbound API」。
  - 群組和 meter 的六條在 P4 上一律以 `OpResult::unsupported` 拒絕（`P4RoutingStrategy.cpp:11-33`），kernel 把它回成 501（`OpResult.hpp:167-169`、`HttpSession.cpp:2009-2011`）。
  - 拓樸輪詢 proxy 的 `/v1.0/topology/*`（`TopologyAndFlowMonitor.cpp:1037-1057`）。
- **proxy：** 15 條路由（`p4_proxy/proxy_agent/api_routes.py`，附錄 B）。只有 5 條是 P4 形狀
  （`/p4/readopt`、`switch_state`、`table_entry`、`counter`、`multicast_group`），9 條冒充 Ryu 的形狀，`/sflow/stats` 是自有形狀（`api_routes.py:161-190`）。
- **kernel 不讀 proxy 的 pipeline 揭露。** `src/`、`include/` 裡沒有讀 `"pipeline"`、`p4info`、`"table_entries"` 鍵的地方；
  `p4LivenessFor` 只按名稱讀 `switches`、`probe_ok` 等鍵（`DeviceConfigurationAndPowerManager.cpp:612-670`；
  proxy 那邊的說明在 `api_routes.py:614-616`）。
  **唯一的例外**是 `get_openflow_capacity`：寫死 `MyIngress.ipv4_lpm`／`flow_5tuple`（`OpenflowCapacityReport.cpp:23-24`），
  找不到時回 `max_entries: null`（`:279`）。
- **p4info 由每台 client 在建立時自己解析**（`p4_client.py:249`），並在 SetForwardingPipelineConfig 時送上交換機（`:654-667`）。

INFERRED
- 在這個架構裡，「API 形狀隨 `.p4` 變」只能落在 proxy，因為它是唯一持有 p4info 的元件。
  kernel 最多只需要多讀一份「能力」，再轉述給上層。

### 1.2 web-gui 與其他消費者

OBSERVED
- **前端在 `~/Web-GUI`**（HEAD `f63a55c`，2026-04-20；worktree 有未追蹤的 `.env`）。
  打 kernel 的 12 條呼叫全在 `src/api/index.ts:34-164` 和 `src/components/llm/LLM.ts:21`：
  - 讀：`get_graph_data`、`get_detected_flow_data`、`get_detected_top_k_flow_data`、`get_switch_openflow_table_entries`、
    `get_cpu_utilization`、`get_memory_utilization`、`get_temperature`、`get_nickname`。
  - 寫：`modify_device_name`、`modify_nickname`、`install_flow_entries_modify_flow_entries_and_delete_flow_entries`、`intent_translator/text`。
  - 不打 proxy，不打 `set_switches_power_state`，也不打斷鏈注入。
- **GUI 用 OpenFlow 詞彙：** 表單 match 欄位固定 10 個（`src/pages/SwitchFlowTable.tsx:44-60`），action 只有 `OUTPUT`（帶 port）和 `DROP` 兩種（`:569-570`；送出在 `:222-228`）。
- **GUI 的旗標用法：** 節點顏色看 `is_up`（`src/components/Topology.tsx:331-334`）；**邊的顏色只看用量**（`:366-381`，0% 為藍、約 33% 才綠，
  `src/utils/colorUtils.ts:8-15`），邊一律畫出、不看 `is_enabled`／`is_up`；埠面板只列 `is_enabled` 的邊（`SwitchPortPanel.tsx:80`）；
  鏈路資訊依 `is_up` 顯示 Up／Down（`LinkInformation.tsx:430`）。
- **其他消費者**（逐 repo grep `/ndt/`，repo 都在 `~/` 底下）：
  - Energy-Saving-App（`9facb78`）用 14 條，包括 `set_switches_power_state` 和 **`POST /ndt/disable_switch`**
    （`src/app/http.cpp:263-276`；期待回 FlowDiff 陣列，也就是「新的規則表」）。
  - TE app 用 `install_flow_entry`（`Traffic-engineering-App.py:32,345`）。
  - Visualizer、NSR、NTG 只讀；SPM 做 app 註冊與模擬案例往返（`app_register`、`received_a_simulation_case`、`simulation_completed`）。

INFERRED
- kernel 路由表沒有 `/ndt/disable_switch`，所以 Energy-Saving-App 那一呼叫今天回 404。
  它是唯一一個期待「停用交換機之後 kernel 替我重算規則」的消費者，那正是 (c) 要的機制。

### 1.3 每類端點服務哪一項（詳表見附錄 A）

| 類別 | 代表端點 | 服務 | 今天對 pipeline 的依賴 |
|---|---|---|---|
| 狀態讀取 | `get_graph_data`、`get_detected_*`、`get_*_utilization` | (a) | 間接：邊要靠 `/v1.0/topology/links` 啟用；流的 `path` 靠讀回的表 |
| 規則讀取 | `get_switch_openflow_table_entries` | (a)(b) | **直接**：`ryu_flow_stats.py` 只認 NDTwin 的欄位名和 action 名 |
| 規則寫入 | `install_*`、batch、`intent_translator` | (b) | **直接**：寫死 `ipv4_lpm`／`flow_5tuple`（附錄 C） |
| 開關機、停用 | `set_switches_power_state`、`DisableSwitch` | (b) | 行程層或模型層；只有 readopt 補路由那一步看 pipeline |
| 鏈路事件 | `link_failure_detected`、`inject_link_failure` | (c) | kernel 端無關；偵測和重算在 proxy，靠 LLDP |

## 2. 意圖今天怎麼到資料面

### 2.1 推一條路由

OBSERVED（依呼叫順序）
1. GUI 的 batch（`index.ts:154-160`）進 kernel `HttpSession.cpp:427-431`，交給 `processFlowBatch`（`:2171`）。
   **kernel 在送往南向之前就回 `{"status":"queued"}`**（`:2430`），結果要之後查 `get_flow_dispatch_status`。
2. 經 dispatcher 交給 `P4RoutingStrategy`，由 `HttpRoutingStrategyBase.cpp:344` 發出 `POST /stats/flowentry/add`。
3. proxy `api_routes.py:405` 的 `add_flow_entry` 呼叫 `topology.route_flow`（`:434`），**只 catch `UnsupportedMatchError`**。
4. `topology_manager.py:821` 用 `needs_five_tuple`（`:332`）分流：五元組走 `insert_5tuple_rule`（`:916`），
   否則走 `insert_ipv4_route(dst, 32, host_mac, out_port)`（`:935`）。
5. `p4_client.py:1770-1800` 用字面常數組 entry：`"MyIngress.ipv4_lpm"`（`:1781`）、`"hdr.ipv4.dstAddr"`（`:1785`）、
   `"MyIngress.ipv4_forward"`（`:1791`）、參數 `"dstAddr"`／`"port"`（`:1795,:1800`）。
   名字查不到丟 `KeyError`（`:980-983`）；寫入回 `ALREADY_EXISTS`／`UNKNOWN` 時改用 MODIFY 重試（`:1825`）。

**有查 p4info 的地方（OBSERVED）：**
- `build_table_entry`（`p4_client.py:1076`）對這台的 p4info 解析每個名字，match 形狀由 p4info 宣告的 match type 決定，只支援 exact 和 lpm（`:131`）。
- `/p4/table_entry`（`api_routes.py:690`）呼叫 `write_table_entry`（`p4_client.py:1247`），錯誤對應成 409/501/400/404/502（`api_routes.py:769-800`）。
- 其他按名字查 p4info 的：packet_in／packet_out metadata id（client 建立時解析，`p4_client.py:267,273`）、`/p4/counter`（`api_routes.py:812` → `p4_client.py:1527`）。
  `/p4/multicast_group`（`api_routes.py:884`）**不查** p4info：PRE 群組與表無關（`p4_client.py:841-977`）。

**讀回方向也寫死（OBSERVED）：** `/stats/flow/{dpid}`（`api_routes.py:982`）交給 `ryu_flow_stats`。
欄位對照只有 NDTwin 的 7 個鍵（`ryu_flow_stats.py:47-55`）；轉發 action 只認 `ipv4_forward` 和 `forward_l2`（`:58-61`）；`send_to_cpu` 渲染成 `OUTPUT:CONTROLLER`（`:144-145`）；其他 action 一律回 `[]`（`:149`）。

**外來 pipeline 下今天的行為（OBSERVED）：**
- 開機先算出 `foreign` 集合（`main.py:1206`）。外來交換機跳過 clone 和 sFlow（`main.py:1386-1414`；external 在 `:1369-1378` 更早就跳過），**除非**遙測來源是
  `cooperative`，而這要求程式帶 NDTwin 的 `packet_in` 標頭（揭露端同一規則在 `:504-521`）。13 支未修改的練習題裡，11 支 ndtwin 模式的 cpm 都是 0（§3），所以全部跳過。
- **只要有一台是外來的，整個 fabric** 就跳過 LLDP、watchdog 和 `install_initial_routes`（`:298`、`:1535-1545`）。
- package 的 entries 在開機時（`:1312-1313`，外來且非 read_only 的交換機）和每次 readopt 之後（`:1123-1124`）各套用一次。
- `/stats/flowentry/*` 路徑上**沒有外來 pipeline 的防護**（在 `topology_manager.py`／`api_routes.py` 搜 `foreign`，只找到 readopt 的註解）。
  唯一的擋板是 `_refuse_write`：每個寫入方法第一行就呼叫它（`p4_client.py:1676,1714,1752,1772,1870,1923`），external 模式的 client 在任何名字查找之前
  就丟 `ControlPlaneReadOnly`（`:431-435`）。**ndtwin 模式的 11 支外來 pipeline 沒有任何擋板。**
- readopt 帶 `install_routes=ndtwin`（`main.py:1076`）。它的 docstring（`:1030-1034`）記下：在 `basic.p4` 上補路由「SUCCEEDS」，
  proxy 的路由疊到練習題自己的轉發上，雙方都回報成功。

INFERRED
- **目的地型規則推到外來交換機，有三種結果：**
  - ① 7 支 ndtwin 模式、同形的 pipeline：寫進作者的表。如果作者已經宣告了同一個 /32
    （本機 `basic-solution/pod-topo/s1-runtime.json:12-55` 就有，檔案未提交；開機時外來交換機會套用這些 entries，`main.py:1312-1313`；live run 每台 `applied: 5`，
    `30_switch_state.json`，未提交），INSERT 失敗後 MODIFY 退路（`p4_client.py:1825-1827`）會悄悄蓋掉它。
  - ② 其他 4 支 ndtwin 模式的外來 pipeline（calc、load_balance、multicast、source_routing）丟 `KeyError`（`p4_client.py:980-983`）；
    2 支 external（flowcache、p4runtime）在名字查找之前丟 `ControlPlaneReadOnly`（`:431-435`）。`add_flow_entry` 兩者都不 catch（`api_routes.py:436`），
    proxy 也沒有全域 exception handler，所以都是 500；kernel 記失敗，但 GUI 早已拿到 200 `queued`。
  - ③ GUI 表單預設那一列 `protocol` 是空值，空值不送出（`SwitchFlowTable.tsx:192`）；使用者填了 protocol，或加了 L4 埠（會自動補 `protocol=6`，
    `:1180-1188`、`:74`）才走 5-tuple。13 支都沒有 `flow_5tuple`，結果同 ②。
- **讀回方向，不認得的轉發 action 渲染成 `actions: []`**（`ryu_flow_stats.py:149`；依 `:129-131` 的註解，這在 Ryu 慣例裡代表 drop）。kernel 走流路徑時，
  遇到沒有出埠的規則就放棄，該流的 `path` 留空（`FlowLinkUsageCollector.cpp:3346-3373`），和「這台沒有規則」的結果相同。
  所以經過 load_balance 的 `set_ecmp_select`、multicast 的 `mac_forward` 的流會沒有 path；GUI 規則表會把這些 entry 列成沒有 action 的規則（GUI 上的樣子沒有驗證）。

### 2.2 停用交換機或埠

OBSERVED
- **Intent Translator 的 `DisableSwitch`／`EnableSwitch`**（`IntentTranslator.cpp:308-350`）呼叫 `disableSwitchAndEdges`
  （`TopologyAndFlowMonitor.cpp:5173-5205`），只改節點和邊的 `isEnabled`／`adminDisabled` 旗標，沒有南向呼叫。
- **`POST /ndt/set_switches_power_state`**（`HttpSession.cpp:387,1885-1930`）走 `P4PowerStrategy`：
  以 `sudo -n /usr/local/sbin/ndtwin-p4-power` 開關（`P4PowerStrategy.cpp:21,100`），再 `curl POST /p4/readopt/<dpid>`（`:148-150`）；
  `main.readopt_switch`（`main.py:1010-1130`）在外來交換機上不補路由，改成重套 package 的 entries（`:1112-1125`）。
- **kernel 沒有停用埠的端點。** 斷鏈注入只在 MININET 模式下動 tc（`HttpSession.cpp:1153-1164`），在 veth 兩端加 netem 100% 丟包（`:1179-1182`）。

INFERRED
- **「停用」本身已經和 pipeline 無關：** 開關機在行程層，admin disable 在模型層，斷鏈在 veth 層。
  和 pipeline 有關的只剩「停用之後流量要不要繞開它」，也就是 §2.3 的重算和下發。
- 今天 admin disable 在任何 pipeline 上都**不**繞路；外來 pipeline 下開機後也不補路由。

### 2.3 斷鏈、重算、下發

OBSERVED
- **偵測：** 靠 LLDP。送 packet-out（`p4_client.py:517`，要 `packet_out` metadata id）；對端 packet-in 後呼叫 `add_link` 和
  `install_initial_routes`（`topology_manager.py:1543-1547`）；watchdog `check_link_beacons`（`:1852-1908`）經 `_notify_link`
  通知 kernel `/ndt/link_failure_detected`（`kernel_notifier.py:99-104`）。
- **重算與下發：** `run_watchdog_pass`（`topology_manager.py:1962-2000`）呼叫 `install_initial_routes()`（`:1994`），
  接著 `calculate_all_paths(self.reroutable_down_endpoints())` 做 BFS（`:1172`），
  再對每個（交換機, 主機）呼叫 `insert_ipv4_route(dst,32,host_mac,out_port)`（`:1204`），
  最後 `push_destination_paths` 推到 `/ndt/inform_all_destination_paths`（`:1999`；`kernel_notifier.py:129-148`）。
- **kernel 端：** `handleLinkFailure` 把兩個方向標成 down 並發出 `LinkFailureDetected`（`HttpSession.cpp:800-878`）。
  **EventBus 在正式碼裡沒有訂閱者**（`registerHandler` 只出現在 `tests/test_EventBus.cpp`）。
  所以 kernel 不重算路由；算路徑和下發是控制器的事（P4 是 proxy；OVS 是 `intelligent_router.py`，它在 `on_link_delete` 裡排程重裝路由，`:1929`）。
- **鏈路只能經由 LLDP 進 proxy 的圖**（`add_link` 唯一的正式呼叫點是 `topology_manager.py:1546`）。
  `render_links` 只輸出圖上的邊（`ryu_topology.py:87-127`）。kernel 的交換機間邊主要由這個輪詢的 `updateLinks` 啟用並設為 up（`TopologyAndFlowMonitor.cpp:2877-2883`；
  proxy 端說明在 `api_routes.py:156-158`）；另一條路是 Intent Translator 的 `EnableSwitch`（`TopologyAndFlowMonitor.cpp:5245-5249`，由 `IntentTranslator.cpp:345` 觸發），
  它只設 `isEnabled`、不設 `isUp`。
- **未提交的觀測**（`doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs/2026-09-19T062604Z_02_app_basic/`，`--app basic`）：
  `32_get_graph_data.json` 裡 8 個交換機間方向全部 `is_enabled:false, is_up:false`，8 個主機邊為 true；
  `30_switch_state.json` 顯示 `"links": {}`，`skipped` 等於 `[install_initial_routes, link_watchdog, lldp_discovery]`。

INFERRED
- **這條路徑對 pipeline 有 4 個假設：** ① 有控制器封包標頭（packet_in/out）；② 有 `ipv4_lpm`／`ipv4_forward` 這些名字；
  ③ 每台主機一條、只看目的地的 /32；④ 由單一一張表決定出埠。
  外來 pipeline 違反 ①，於是在 `main.py:1535` 整條鏈被關掉，交換機間邊停在 `is_enabled/is_up: false`。GUI 上的後果**不是變紅**（邊只按用量上色、
  節點仍是 up，§1.2）：埠面板看不到交換機間的埠（`SwitchPortPanel.tsx:80`），點開鏈路資訊顯示 Down（`LinkInformation.tsx:430`）。
  **這不是 API 形狀的問題，是鏈路發現的問題。**

## 3. 13 支 pipeline 的事實

OBSERVED：表來自 p4info 解析（solution 版，本機 `.test_run` 未提交）；控制模式和交換機數讀自各 package 的 `package.json`。

| exercise | 模式 | 轉發相關的表（key → action(params)） | cpm | 交換機/交換機間鏈路 | 與 NDTwin `ipv4_lpm` 同形 |
|---|---|---|---|---|---|
| basic | ndtwin | `ipv4_lpm`(dstAddr lpm/32) → `ipv4_forward`(dstAddr/48, port/9) | 0 | 4/4 | 是 |
| basic_tunnel | ndtwin | 同上；`myTunnel_exact`(dst_id exact/16) → `myTunnel_forward`(port/9) | 0 | 3/3 | 是（IP 部分） |
| calc | ndtwin | `calculate`(op exact/8) → `operation_*()`；沒有轉發表 | 0 | 1/0 | 否 |
| ecn、qos | ndtwin | `ipv4_lpm` 同上 | 0 | 3/3 | 是 |
| firewall | ndtwin | `ipv4_lpm`＋`check_ports`(ingress_port, egress_spec exact) → `set_direction`(dir/1)＋bloom registers | 0 | 4/4 | 是 |
| flowcache | external | `flow_cache`(proto, src, dst exact) → `cached_action`(port/9, …, dst_eth_addr/48) \| `flow_unknown` | 2 | 3/3 | 否 |
| link_monitor、mri | ndtwin | `ipv4_lpm`；另有只設預設 action 的 egress 表（`swid`／`swtrace`） | 0 | 4/4、3/3 | 是 |
| load_balance | ndtwin | `ecmp_group`(dst lpm) → `set_ecmp_select`(base/16, count/32)；`ecmp_nhop`(exact/14) → `set_nhop`(dmac/48, ipv4/32, port/9)；`send_frame` | 0 | 3/3 | 否 |
| multicast | ndtwin | `mac_lookup`(dstAddr exact/48) → `mac_forward`(port/9) \| `multicast()`（PRE 群組） | 0 | 1/0 | 否 |
| p4runtime | external | `ipv4_lpm`（多一個 `myTunnel_ingress`）；`myTunnel_exact` | 0 | 3/3 | 是（但 409 唯讀） |
| source_routing | ndtwin | **沒有表**：路徑在封包標頭裡，由送端決定 | 0 | 3/3 | 否 |

- 對照 `ndtwin_switch.p4info.txt`：`flow_5tuple`（6 個 ternary 欄位）、`ipv4_lpm`、`l2_forward`，cpm 為 2。
- **與舊結論對帳：** `PLAN-0917-exercise-support.md:72` 說「12/13 支沒有這張表」，**以 solution 來看被推翻**：
  8/13 有同名同形的表，扣掉 external 的 p4runtime 還有 7 支。這和 readopt docstring（`main.py:1027-1036`）在 basic 上記下的事一致。
  skeleton 版（12 支；flowcache 的骨架編不過，沒有 package）逐檔 grep 表名，同樣 8 支宣告 `MyIngress.ipv4_lpm`；action 形狀未核。

## 4. 設計選項

**先例（ONOS，憑記憶描述；本機沒有 ONOS 原始碼，沒有核對）：**
- **pipeconf 的組成：** P4Info、target 設定，加上一組 Java 寫的 behaviour。其中兩個關鍵：
  - `PiPipelineInterpreter`：把標準 criterion／treatment 對到這支 pipeline 的 match field、table、action，並負責 packet-in/out 和控制器標頭之間的轉換。
  - `Pipeliner`：把 app 的 FlowObjective（forwarding／filtering／next，next 可以是 ECMP 群組）翻成多表規則。
- **對應關係是有人一支一支 pipeline 手寫的程式碼，不是從 p4info 推出來的。** 對不上就丟 translation exception、規則被拒，這就是它的「能力」語意。
- pipeline-aware 的 app 可以直接寫 PI 原生的 criterion／action 繞過 interpreter，相當於下面的 (i)。
- Intent 框架在拓樸事件後重新編譯 objective 交給 pipeliner，這就是它的 (c)。
- LLDP 探索要靠 interpreter 能轉 packet-out，所以沒有 CPU 埠標頭的程式在 ONOS 裡也探索不到鏈路。
- **啟示：ONOS 也沒解決「任意 .p4 零宣告」，它的答案是由 pipeline 作者提供翻譯層。**

每個選項依序交代：① 需要使用者給什麼；② 能服務哪幾支；③ web-gui 會怎樣；④ 工時；⑤ 主要風險。
工時是估計（INFERRED），單位工程師人日，含 mutation gate 和測試，不含 live 驗收。

**(i) 只用 p4info 驅動的通用表 API**（把階段二做完再延伸）
- ① 不需要。
- ② 補 ternary／range／optional，加 `GET /p4/pipeline/{dpid}` 回傳目錄，加讀表，必要時加 kernel 轉送。
  raw 寫入能用在 10 支（flowcache、p4runtime 回 409；source_routing 沒有表可寫），**但沒有 (b)(c) 的「意圖」**：沒有人知道哪張表代表路由，斷鏈後也沒人重寫。
- ③ web-gui 用不了；表單是 OpenFlow 詞彙。
- ④ 3–5 天，加 kernel 轉送 2 天。
- ⑤ 把 pipeline 知識推給每個 app，違反 (a)。

**(ii) package 宣告「意圖 → 表」的 roles manifest**（ONOS interpreter 的宣告式版本）
- ① `package.json`（format 1，只加不改，比照 `telemetry`）加一段：
  `"roles": {"ipv4_route": {"table": "MyIngress.ipv4_lpm", "key": {"hdr.ipv4.dstAddr": "$dst_ip/32"},
  "action": "MyIngress.ipv4_forward", "params": {"dstAddr": "$dst_mac", "port": "$out_port"}, "owner": "ndtwin"}}`，
  再加 `l2_route`（以 MAC 為 key），以及選配的 `tunnel_route`（需要主機屬性 `$dst_tunnel_id`）。
- ② 可服務：7 支同形的直接可用（firewall 有危險，見 ⑤）；basic_tunnel 的 tunnel 部分用 `tunnel_route`；multicast 的 `mac_lookup` 用 `l2_route`，
  但只有 (b)：它只有 1 台交換機，沒有路可繞，(c) 無意義；
  load_balance 要兩表的間接範本（`ecmp_group` 設 count=1，加 `ecmp_nhop`）。
  **不能服務：** calc（沒有轉發表）、source_routing（路徑在送端）、flowcache／p4runtime（外部控制器擁有表）。
- ③ 只看目的地的規則不用改；五元組規則在外來 pipeline 上照舊不支援，但改回 501 `unsupported_on_p4` 而不是 500。讀回用同一份綁定反查。
- ④ 單表版 8–12 天＝第一刀的 `ipv4_route`（5–7 天，§5）＋`l2_route`／`tunnel_route` 與主機屬性（2–3 天）＋kernel 的 `capabilities` 欄位（1–2 天，要 build）；
  多表範本另加 3–5 天。
- ⑤ **所有權衝突**：作者的 entries 和 NDTwin 的路由寫同一張表。**manifest 寫錯**：p4info 只能驗型別和位寬，驗不出「這個參數是不是出埠」，只有 live ping 能驗。
  **firewall**：`check_ports` 以（入埠, 出埠）為 key，繞路後會產生沒有 entry 的組合，方向判斷失效。

**(iii) 從 p4info 的 match 欄位和 action 參數做啟發式推斷**
- ① 不需要。
- ② 嚴格的規則範例：「單一 32 位元 `dstAddr` 的 lpm key，action 帶一個 48 位元和一個 9 位元參數」判定為 `ipv4_route`。
  它命中 8 支：那 7 支加 p4runtime（external，寫了也是 409）。multicast 要另一條 l2 規則（48 位元 exact 的 `dstAddr` key，action 帶 9 位元參數）。
  **放寬就會誤判：** 若只看 action（「9 位元 port＋48 位元 MAC 參數」），flowcache 的 `flow_cache`（三個 exact key）→ `cached_action`(port/9, …, dst_eth_addr/48)
  也會被當成路由表（假陽性）；今天只因為那個 package 是 external 模式才沒出事。
  **推不出：** load_balance 的間接、basic_tunnel 的 id 對應、firewall 的語意。
- ③ 同 (ii)，但行為會隨推斷變動。
- ④ 2–4 天。
- ⑤ 名字不等於語意：同名的表寫得進去（readopt docstring `main.py:1027-1036` 記過 basic 上的舊行為），今天沒有防護的寫入路徑還會用 MODIFY 蓋掉作者同一個 /32
  （§2.1 INFERRED ①）；推斷只會讓這種事變多。

**(iv) 要求把 NDTwin 控制 shim 併進使用者的 pipeline**（比照 `ndtwin_telemetry.p4`）
- ① 使用者改 P4 原始碼並重編。遙測 include 已經要 5 處編輯、2 處 apply 和 3 行實例化（`ndtwin_telemetry.p4:28-65`）；新 shim 還要多一張 `ndtwin_route` 表和 packet_in/out。
- ② 作者願意 include、轉發也能和 shim 組合的程式，(a)(b)(c) 全部可用：LLDP、watchdog、名字固定的補路由照舊。
  但套用順序要逐支看（load_balance 要先改寫 VIP 再查路由；source_routing、calc 沒有插入點）。
  判斷條件要從 `pipeline_is_ndtwin` 改成比照 `pipeline_carries_telemetry`（`p4_client.py:218`）的「帶控制 shim」。
- ③ 不用改。
- ④ shim 3–5 天，接線 2 天，每支練習題 fixture 各 1 天。
- ⑤ 違反「使用者自己的 pipeline」這個前提；兩份控制邏輯在同一個 ingress 裡搶出埠，組合語意要逐支定義。

**(v) 混合式（建議）：** (ii) 當唯一會「啟用 NDTwin 寫入」的契約；(i) 當逃生口；(iii) 只在 `preflight.py`／`convert.py` 提出 roles 草稿，要作者接受才生效；
(iv) 保留給想用 LLDP 的作者；另外把鏈路和存活偵測從 pipeline 拆開（§5）。

**各選項能服務哪些練習題（(b) 推規則／(c) 斷鏈重算；INFERRED，由 §3 推出）：**

| 練習題 | (i) | (ii) | (iii) | (iv) | (v) |
|---|---|---|---|---|---|
| basic、ecn、qos、mri、link_monitor | raw/— | ✔/✔* | ✔/✔* | ✔/✔ | ✔/✔* |
| basic_tunnel | raw/— | ✔（IP＋tunnel role）/✔* | 只有 IP | ✔/✔ | 同 (ii) |
| firewall | raw/— | ✔/⚠ 要 `check_ports` role | ✔/⚠ 悄悄出錯 | 視組合 | ✔/⚠ |
| load_balance | raw/— | 要多表範本 | ✘ | 要先改寫 VIP | 要多表範本 |
| multicast | raw/沒路可繞 | `l2_route`/—（1 台） | l2 規則/— | 視組合/— | 同 (ii) |
| calc | raw/— | ✘（沒有轉發表） | ✘ | ✘（沒有插入點） | ✘ |
| source_routing | —/— | ✘ | ✘ | ✘ | ✘ |
| flowcache、p4runtime | 409 | 409 | 409 | 要改成 ndtwin 模式 | 409 |

\* (c) 另外要一個與 pipeline 無關的存活訊號（§5）。(i) 的 raw 只代表「可以寫」，不代表「有意圖」。

## 5. 建議與第一刀

**建議選 (v)，理由有三。**
1. **只有它同時保住 (a) 和同意權。** 形狀固定在意圖層，pipeline 只決定綁定和能力；「NDTwin 可以寫這張表」必須由作者說出口，不能由名字暗示（`main.py:1030-1034`）。
2. **(c) 的瓶頸是鏈路，不是表。** 把鏈路和存活偵測從 packet_in 拆開後，7 支同形的 pipeline 馬上能沿用 `install_initial_routes` 的 BFS。
3. **它延續既有慣例，對 baseline 零位元組影響：** baseline 綁定等於今天的字面常數，沿用 `app_package` 可逐值斷言的契約；
   不支援就回 501 `unsupported_on_p4`（`P4RoutingStrategy.cpp:11-23`）；揭露沿用「跳過不是沉默」。

**鏈路與存活偵測（INFERRED，未量）：**
- **鏈路改用宣告的。** manifest 本來就必填拓樸檔（`app_package.py:873`），proxy 也已有 `load_switch_links`（`topology_manager.py:452`），
  目前拿來 seed watchdog（`:1811-1846`），也經 `load_switch_link_ports`（`:491-501`）決定 LLDP 從哪些埠送（`:650`）；`--app` 下它讀的 `NDTWIN_TOPO_FILE` 就是
  package 的模型（`tools/test_workflow/stack.sh:1086`）。外來 fabric 直接用它把鏈路放進 `net`，kernel 的交換機間邊就會啟用。
- **存活偵測，第一層是 veth 心跳：** 由 root helper 跑，放在 psample emitter 旁邊（`link_telemetry.py:1-40`，已經知道 veth 對到哪個（dpid, port））。
  在 `sX-ethN` 用 AF_PACKET 送本地實驗用 ethertype 的幀，從對端 veth 收；netem 掛在 egress qdisc，所以斷鏈時心跳一起被丟。
  **代價：這些幀一定會進使用者的 pipeline**（bmv2 也是用 pcap tap 讀介面），副作用要量。
- **第二層：** 作者 include 了 shim，就用 LLDP，和今天一樣。
- **為什麼不去讀 tc 設定：** 那是驗機制，不是驗目的。

**第一刀（估計 5–7 天，不需 build kernel）：** 它是 (ii) 單表版的子集，只做 `ipv4_route`；不含 `l2_route`／`tunnel_route`、kernel 的 `capabilities` 欄位
（第三刀）、心跳（第二刀）和多表範本，所以比 (ii) 的 8–12 天少。
1. `app_package` 加 `roles.ipv4_route`（format 1，只加不改）。loader 驗形狀；`preflight.py` 對每台 p4info 驗表、欄位、action、位寬；`owner` 只允許 `ndtwin` 或 `package`。
2. proxy 加 `RouteBinding`，在每個 client 建立時解析。`insert/modify/delete_ipv4_route` 和 `install_initial_routes` 改從綁定讀名字，預設值等於今天的字面常數。
   沒有綁定的外來交換機，寫入回 501 `unsupported_on_p4`，取代今天的 500 或悄悄蓋掉；5-tuple 同樣處理。
3. 外來 fabric 用宣告的鏈路 seed `net`。**每台外來交換機都有 `owner: ndtwin` 的綁定時**，不再跳過 `install_initial_routes`
   （從 `FOREIGN_PIPELINE_FABRIC_SKIPS` 拿掉）；LLDP 和 watchdog 照舊跳過。
4. `ryu_flow_stats` 用綁定反查；不認得的 action **不再渲染成 drop**，改成不列出，並在揭露裡算一個數字。
5. `GET /p4/switch_state` 每台加 `capabilities: {ipv4_route: bound|unbound, five_tuple: false, reroute: false, …}`，只加不改。
6. **驗收：** pod-topo（兩個 spine，兩條不相交路徑）上跑 `--app basic` 加 `owner: ndtwin`（依 §8-1，這個 package 不再宣告 `ipv4_lpm` 的 entries）：
   `GET /ndt/get_graph_data` 的 8 個交換機間方向全部 `is_enabled:true, is_up:true`（今天全是 false，§2.3）；GUI 的埠面板列出交換機間埠
   （`SwitchPortPanel.tsx:80`），鏈路資訊顯示 Up（`LinkInformation.tsx:430`）；batch 規則寫得進去（`get_flow_dispatch_status` 沒有失敗，`/stats/flow/{dpid}` 讀得回）。
   陰性對照：不寫 roles 時必須回 501，而且作者的 entries 一個都沒被動。
- **第二刀**（3–4 天，要 Adam 的 sudo）：先做心跳 spike（純 veth pair 加 netem，量偵測延遲和幀進 pipeline 的副作用），再接 watchdog，讓外來 fabric 的 (c) 生效。
- **第三刀**（kernel build，要走 guard）：`get_graph_data` 的節點帶 `capabilities`，讓 GUI 可以（但不必）把不支援的操作變灰。

## 6. 「動態」能做到什麼、做不到什麼

OBSERVED
- **proxy 讀 p4info 檔的地方：** client 建立時解析（`p4_client.py:249` → `:437-441`）、遙測自檢 `pipeline_carries_telemetry`（`p4_client.py:218-240`，
  呼叫點 `main.py:473,515,1072`）、揭露用的 sha（`main.py:447-457,542`）；`:667` 是把已解析的 p4info 隨 SetForwardingPipelineConfig 送出。
  **全部發生在開機或 readopt；pipeline 也只在這兩個時點推送。**
  15 條 proxy 路由裡**沒有任何一條能在執行中換 pipeline**（附錄 B）。package 由 proxy 在啟動時讀一次並快取（`p4_proxy/proxy_agent/profile.py:37-63`），
  所以換程式要重新 `ndt up p4 --app`（說明文字 `tools/test_workflow/ndt:10121-10136`），把 fabric 重建一次。
- **kernel 的靜態拓樸只載入一次**（`TopologyAndFlowMonitor.cpp:1090-1096`），而且 kernel 不讀 pipeline（§1.1）。`--app` 下 kernel 以 `--topology <package 的模型>` 啟動
  （`tools/test_workflow/stack.sh:1119`；live run 的 kernel 載的是 `.test_run/packages/basic/ndtwin/topology.json`，`32_get_graph_data.json:566`）。
  INFERRED：只換程式、不換拓樸的話，原理上不必重啟 kernel；但每個 package 自帶拓樸（`app_package.py:873`），所以在 `--app` 流程下換 package 實際上等於連拓樸一起換。

INFERRED
- **pipeline 載入時、不重啟 kernel 就能變的：** ① 每台支援哪些意圖（能力旗標）；② 意圖綁到哪張表（client 建立或 readopt 時重新解析）；
  ③ raw 表目錄（`/p4/table_entry`、`GET /p4/pipeline`）；④ 讀回方向的翻譯。
  以後如果加一條「執行中推新 pipeline」的 API，這四樣都能即時跟著換，因為它們本來就是每個 client 各自持有的狀態。
- **不能動態改的：** ① kernel 的路由表（編譯進去的 if/else）；② app 送出的 OpenFlow 形狀請求；③ GUI 表單（10 個 match 欄位加 `OUTPUT`／`DROP`，寫死在 TSX）。
  如果這三樣也要跟著 pipeline 變，GUI 就得改成「讀目錄再產生表單」，那等於 (a) 不成立。
- **GUI 契約建議採「意圖固定，每台加能力旗標」，不採「GUI 直接用表層 API」。**
  不改的 GUI 仍能用，但今天的失敗模式**不是 501**：7 支同形的 ndtwin 模式 pipeline 寫得進作者的表（同一個 /32 會被 MODIFY 悄悄蓋掉，§2.1 INFERRED ①）；
  其他 4 支 ndtwin 模式外來 pipeline 和 2 支 external 回 500（§2.1 ②）；kernel 都先回 `queued`，失敗記進 `recent_failures`。今天 501 只出現在 delete／modify
  帶了 priority 的情況（`api_routes.py:361-383`）；第一刀之後，沒有綁定的寫入才統一成 501 `unsupported_on_p4`。
  表層 API 留給會寫 P4 的使用者和 `sX-runtime.json`，不進 GUI 契約。

## 7. 要 Adam 裁的（只列答案會改變設計的）

1. **所有權：** 作者的 entries 和 `roles` 指到同一張表時，以誰為準？
   - 建議：`owner: ndtwin` 時 NDTwin 獨佔這張表，package 對這張表的 entries 在 preflight 就拒絕。
   - 另外兩種：「entries 當初始種子，重算時蓋掉」或「NDTwin 只寫作者沒宣告的目的地」。兩者都會讓繞路後的狀態無法從宣告推算出來。
2. **(c) 能不能要求使用者改 `.p4`？** 可以的話，(iv) 的 shim 讓 LLDP 原樣運作，第二刀可省；
   不行的話，一定要走 root 的 veth 心跳，要 sudo，而且心跳幀會進使用者的 pipeline。
3. **「web-gui 不改」要嚴格到什麼程度？** 一行都不能改：能力旗標 GUI 看不到，不支援的寫入只會變成 `queued` 之後的失敗。
   允許 GUI 讀一次能力旗標：可以把不支援的操作變灰，但要動 `~/Web-GUI`，那是另一個 repo。
4. **範圍：** (b)(c) 只做 7 支同形的，還是也做 load_balance（多表範本）和 basic_tunnel（主機屬性）？
   論文 app 4/5 需要 ternary 加 priority（`PAPER-APPS-CANDIDATES.md` §6），要不要一起納入？這會決定 roles 的 schema 是單表還是多表。

## 附錄 A　kernel 北向路由（`HttpSession.cpp:326-531`，共 45 條）

| 端點 | 用的人（grep） | 服務 | 對 pipeline 的依賴 |
|---|---|---|---|
| `GET get_graph_data` | 7 個元件 | (a) | 邊要靠 `/v1.0/topology/links`（§2.3） |
| `GET get_detected_flow_data`、`get_detected_top_k_flow_data` | GUI、Viz、NSR、TE、ESA | (a) | 流的 path 靠讀回的表（§2.1） |
| `GET get_switch_openflow_table_entries` | GUI、ESA | (a)(b) | `ryu_flow_stats` 寫死名字 |
| `POST install/delete/modify_flow_entry`、batch | GUI、TE、ESA | (b) | 寫死 `ipv4_lpm`／`flow_5tuple` |
| group／meter 的 install/delete/modify（6 條） | — | (b) | P4 上一律 501 |
| `GET get_flow_dispatch_status` | ndt | (b) | 無 |
| `POST intent_translator/text` | GUI | (b) | Disable/Enable 只改模型；FlowEntry 直接呼叫 `FlowRoutingManager`（`IntentTranslator.cpp:400,430,453`），不經上面的 HTTP 路由，南向同一條 |
| `get_switches_power_state`、`set_switches_power_state`、`get_power_report` | ESA | (b) | 只有 readopt 看 pipeline |
| `POST link_failure_detected`、`link_recovery_detected` | proxy、Ryu | (c) | 無（偵測在 proxy） |
| `POST inject_link_failure`、`inject_link_recovery` | ndt、測試 | (c) | 無（tc netem） |
| `POST inform_all_destination_paths`、`GET get_path_switch_count` | proxy；NTG | (c)(a) | 路徑由 proxy 算 |
| `GET get_openflow_capacity` | ndt | (a) | 寫死兩個表名（`OpenflowCapacityReport.cpp:23-24`） |
| `get_cpu/memory_utilization`、`get_temperature`、`get_average_link_usage`、`get_sflow_stats` | GUI、Viz、ESA | (a) | 無（link 遙測與程式無關） |
| `get_total_input_traffic_load_passing_a_switch`、`get_num_of_flows_passing_a_switch` | — | (a) | 間接（流的 path） |
| `inform_switch_entered`、`get_static_topology_json`、`get/modify_nickname`、`modify_device_name` | proxy；GUI | (a) | 無 |
| `app_register`、`received_a_simulation_case`、`simulation_completed`、`historical_logging` | SPM、ESA | — | 無 |
| `acquire/renew/release_lock` | TE、ESA | (b) | 無 |
| （不存在）`POST disable_switch` | ESA `http.cpp:263-276` | (b)(c) | 回 404（INFERRED） |

## 附錄 B　proxy 路由（`api_routes.py`，共 15 條）

| 路由（行號） | 形狀 | 用途 | 對 pipeline 的依賴 |
|---|---|---|---|
| `GET /sflow/stats`（:161） | 自有 | 遙測送端計數 | 無 |
| `GET /v1.0/topology/{switches,links,hosts}`（:193, :205, :222） | Ryu | kernel 拓樸輪詢 | links 只來自 LLDP |
| `GET /ryu_server/all_destination_paths`（:229） | Ryu | kernel 路徑表 | 繼承 links |
| `POST /stats/flowentry/{add,delete,delete_strict,modify}`（:405, :474-475, :512） | Ryu | kernel 規則寫入 | 寫死 |
| `GET /stats/flow/{dpid}`（:982） | Ryu | kernel 讀回 | 寫死 |
| `POST /p4/readopt/{dpid}`（:538） | P4 | 開機後重新接管 | 外來 pipeline 跳過路由 |
| `GET /p4/switch_state`（:579） | P4 | 存活與揭露 | 報告 pipeline 和 skipped |
| `POST /p4/table_entry`（:690） | P4 | raw 寫表 | 查 p4info（exact/lpm） |
| `GET /p4/counter/{name}`（:812） | P4 | 讀 counter | 查 p4info |
| `POST /p4/multicast_group`（:884） | P4 | PRE 群組 | 與表無關 |

## 附錄 C　寫死 NDTwin 名字的位置（第一刀要改成讀綁定）

- `p4_client.py`：`IPV4_LPM_TABLE`／`FIVE_TUPLE_TABLE`（:1624-1625）；`insert_ipv4_route`（:1770-1800）；
  `delete_ipv4_route`（:1868，寫死 2 個名字：`MyIngress.ipv4_lpm`、`hdr.ipv4.dstAddr`）；`modify_ipv4_route`（:1921，和 insert 一樣 5 個）；
  delete 的 UNKNOWN 退路用的 `_ipv4_route_present`（:1832-1847，同樣寫死那 2 個）；5-tuple 系列（:1653-1760）；
  `flow_5tuple` 的固定寬度（:1569）。
- `topology_manager.py`：`route_flow`、`unroute_flow`、`modify_flow`、`install_initial_routes`（:821-1208）透過上面那些方法間接寫死，另外假設 `/32`。
- `ryu_flow_stats.py:46-60`（讀回）；`api_routes.py:370,401,462`（回應裡的 `"table"`）；`OpenflowCapacityReport.cpp:23-24`（kernel 端）。

## 8. Adam 的裁決（2026-09-24 07:3x UTC，互動表單，四題全按建議）

1. **所有權：** `owner: ndtwin` 時 NDTwin 獨佔該表；package 對這張表的 entries 在 preflight 就拒絕。繞路後的表必須能從宣告推算出來。
2. **(c) 不要求使用者改 `.p4`：** 存活偵測以 root 的 veth 心跳為主（先做 spike，量偵測延遲與心跳幀進使用者 pipeline 的副作用），控制 shim 選配——作者自願 include 才走 LLDP。
3. **GUI 允許讀一次能力旗標：** `get_graph_data` 的節點帶 `capabilities`，GUI 把不支援的操作變灰；要動 `~/Web-GUI`（一個 PR）與 kernel build（走 guard）。
4. **第一刀範圍：** 7 支同形（basic／ecn／qos／mri／link_monitor／firewall／basic_tunnel 的 IP 部分）、單表 `roles`；load_balance 多表範本、tunnel 主機屬性、論文 app 的 ternary＋priority 都之後。

⇒ 這四條是階段四工單的契約；工單另立，等 Adam 設 goal。

## 抽驗（orchestrator，2026-09-24，trunk `057a01f0` 的工作樹）

建議所倚的三個 OBSERVED 事實與另外七條引用，逐條開檔對過（`sed -n`／`grep`，非轉述）：

| 引用 | 結果 |
|---|---|
| `HttpRoutingStrategyBase.cpp:344` 發 `/stats/flowentry/add` | 成立（`return post("/stats/flowentry/add", …)`） |
| `OpenflowCapacityReport.cpp:23-24` 寫死兩個表名 | 成立 |
| `p4_client.py:1781,1791` 字面常數 `MyIngress.ipv4_lpm`／`ipv4_forward` | 成立 |
| `main.py:1030-1034` readopt docstring「against basic.p4 SUCCEEDS … both sides reporting success」 | 成立 |
| `main.py:1535-1545` 一台外來 ⇒ 整個 fabric 跳過 LLDP／watchdog／routes | 成立 |
| `topology_manager.py:1546` 是 `add_link` 唯一的正式呼叫點 | 成立（另一處是 `ryu_topology.py:122` 的註解） |
| `registerHandler` 正式碼無訂閱者 | 成立（只在 `include/event_system/EventBus.hpp` 的宣告與 `tests/test_EventBus.cpp`） |
| `~/Web-GUI/src/api/index.ts` 存在、ESA `http.cpp:263` 有 `disable_switch`、kernel `HttpSession.cpp` 沒有 | 成立 |
| `PLAN-0917-exercise-support.md:72`「12/13 支沒有這張表」 | 原文如此 |
| 「8/13 有 `ipv4_lpm`」 | `grep -l 'table ipv4_lpm'` 對 `~/tutorials/exercises/*/solution/*.p4` 得 **7**（firewall mri ecn basic_tunnel qos link_monitor basic）；p4runtime 不在我的 glob 範圍內，第 8 支未由我核對 |

沒核的：附錄 A／B 的逐條行號、13 支表格的 p4info 細節、工時估計（INFERRED）。判官結果另存同目錄 `JUDGE.md`。

### 判官更正輪（2026-09-24 08:5x，orchestrator）

`JUDGE.md` 的 19 條更正＋4 條小幅偏移，由原分析 worker 逐條開檔核過後產出 45 條精確替換，orchestrator 以腳本套用
（每條 old 字串在正文恰出現一次；檔頭、§8、抽驗節未動；392 → 427 行）。判官最要緊的三處已改：GUI 邊的顏色只看用量
（§1.2、§2.3、§5 驗收條件改成 `get_graph_data` 的 `is_enabled/is_up` 與埠面板／鏈路資訊）、§6 今天的失敗模式是 500 或
MODIFY 悄悄蓋掉而不是 501、external 模式有 `_refuse_write` 擋板而 ndtwin 模式的 11 支沒有。
**worker 不同意判官一處、orchestrator 核過採 worker**：判官要 L124 改引 `Classifier.cpp:859-873`，那只是 log 輔助函式的註解；
kernel 真正處理空 action 的是 `FlowLinkUsageCollector.cpp:3346-3373`（`if (!effect || effect->outputPorts.empty()) { ok = false; … break; }`，
orchestrator 開檔核過）——結果是該流的 `path` 留空，不是「顯示成被丟」，原文那句也一併改掉。
工時對帳：第一刀 5–7 天是 (ii) 單表版 8–12 天的子集（不含 `l2_route`／`tunnel_route`、kernel `capabilities`、心跳、多表範本）。
