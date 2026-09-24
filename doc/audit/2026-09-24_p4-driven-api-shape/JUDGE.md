# 判官審查：`ANALYSIS.md`（2026-09-24，判官＝`fable-judge` 定義以 Opus 5.5 執行，唯讀；orchestrator 原樣落檔）

> 判官只有 Read／Grep／Glob。下面每一條 orchestrator 都還沒逐條核，核過的標在檔尾「orchestrator 核對」。
> [Co-developed with claude code -- Adam]

**裁定：HOLDS WITH CORRECTIONS（成立，但需更正）。** §0 的主要結論有證據撐住：
- kernel 不認得 pipeline；
- 13 支裡 8 支有同名同形的 `ipv4_lpm`（其中 7 支是 ndtwin 模式）；
- 真正擋路的是鏈路發現。一台外來交換機就讓整個 fabric 跳過 LLDP／watchdog／routes。

錯誤集中在 GUI、proxy 的防護、p4info 讀取點，以及幾處計數。其中三處會連到設計段：
- GUI 邊的顏色 → 第一刀的驗收條件；
- L305 的狀態碼 → §6「GUI 不改照樣能用」的論證；
- L113 與 L134 互相矛盾。

## 範圍與方法

- 報告裡每一條附了 `file:line` 的 OBSERVED 引用，都開檔對過原文。
- 13 支 solution 的 p4info、`package.json`、兩份 live-run 原始 JSON、`~/Web-GUI`、`~/Energy-Saving-App`、`~/Traffic-Engineering-App`、`~/Network-*`、`~/Simulation-Platform-Manager`、`~/tutorials` 都逐一讀過。
- 沒有執行任何東西。
- 依指示沒看的：ONOS 段、`JUDGE.md`、hand-off 筆記、git 歷史。
- 為了驗證 L186 的引文，只讀了 `PLAN-0917-exercise-support.md` 的第 70–73 行。
- 為了驗證 L59／L68 的 sha，讀了兩個現行 ref 檔（沒讀 log）。L59 的日期 2026-04-20 因此無法驗證。
- §7 引的 `PAPER-APPS-CANDIDATES.md` 是審計文件，且不在 OBSERVED 段，沒核。

## (1) 引用撐不住宣稱（CONTRADICTED）

1. **L65**：「action 只有 `OUTPUT port`（`:62-69`）」。
   - 被引的 `/home/adam/Web-GUI/src/pages/SwitchFlowTable.tsx:68` 只是預設值：`actions: [{ type: 'OUTPUT', port: '' }],`。
   - 同檔 :569-570 有 `<option value="OUTPUT">OUTPUT</option>` 和 `<option value="DROP">DROP</option>`，:222/:228 會把 DROP 送出。
   - L302 的「10 個欄位加 OUTPUT」同樣要改。

2. **L66「鏈路看 `is_up`（`Topology.tsx:334`）」與 L164「連帶讓 GUI 的交換機間鏈路整片變紅（`Topology.tsx:334`）」**
   - `/home/adam/Web-GUI/src/components/Topology.tsx:331-334` 是 `selector: 'node'` 底下的 `'background-color': (ele) => ele.data('is_up') ? '#4CAF50' : '#F44336'`，這是**節點**的顏色。
   - 邊的樣式在 :366-381：`'line-color': ... getEdgeColorByUsage(usage)`，只看用量。
   - 邊不論 `is_enabled` 都會畫出來（:687-765）。用量 0% 時是藍色（`/home/adam/Web-GUI/src/utils/colorUtils.ts:8-15`）。
   - 所以外來 fabric 上交換機間的邊不會變紅。會看到的是：
     - `SwitchPortPanel.tsx:80` 把沒 enable 的邊從埠面板濾掉；
     - `LinkInformation.tsx:430` 的文字顯示 "Down"。
   - 連帶影響：L285 的驗收條件「GUI 的邊變綠」在這份碼上觀測不到。邊要到約 33% 用量才會變綠。

3. **L105**：把「PRE（`:884`）」列在「按名字查 p4info 的」。
   - `/home/adam/Desktop/NDTwin-Kernel/p4_proxy/proxy_agent/p4_client.py:936-937` 是 `group = update.entity.packet_replication_engine_entry.multicast_group_entry` 和 `group.multicast_group_id = gid`。
   - `write_multicast_group`（841-977）完全沒查 p4info。報告自己的附錄 B（L356）也寫「與表無關」。

4. **L111**：「每台外來交換機跳過 clone 和 sFlow（`:292`）」。
   - :292 只是一個常數宣告。
   - 實際行為在 `/home/adam/Desktop/NDTwin-Kernel/p4_proxy/proxy_agent/main.py:496`：`foreign, cooperative, header present-> []`，以及 :521：`return [] if cooperative else sorted(FOREIGN_PIPELINE_SWITCH_SKIPS)`。
   - 對 13 支未修改的練習題成立，但「每台」這個說法不成立。§4 (iv) L235-238 正是依賴這個例外。

5. **L113**：「package 的 entries 只在開機時套用一次（`:1313`）」。
   - `main.py:1123-1124` 在 `readopt_switch` 裡又套一次：`counts = apply_package_entries(topology.switches.get(dpid), package_entries_path(package, dpid))`。
   - 報告自己在 L134 也寫「改成重套 package 的 entries」。

6. **L114**：「`/stats/flowentry/*` 路徑上**沒有外來 pipeline 的防護**」。
   - grep `foreign` 的結果回報得正確：`topology_manager.py:1249、:1415`，`api_routes.py:35、:565`，全是 readopt 的註解。
   - 但 `p4_client.py:1772` 有 `self._refuse_write("an ipv4_lpm route insert")`（另見 :1676、:1714、:1752、:1870、:1923）。它在 external fabric 上丟 `ControlPlaneReadOnly`（:431-435），請求在上線路前就被擋下。
   - `add_flow_entry` 只 catch `UnsupportedMatchError`（`api_routes.py:436`），所以這個例外最後呈現為 500。
   - 正確說法：ndtwin 模式的外來 pipeline（11 支）沒有防護；external（flowcache、p4runtime）會被擋。

7. **L156**：「kernel 的邊只由這個輪詢啟用（`api_routes.py:156-158`）」。
   - 被引的是 proxy 端的註解：「Edges are enabled by updateLinks(), which only runs off this poll.」
   - kernel 碼 `/home/adam/Desktop/NDTwin-Kernel/src/ndt_core/collection/TopologyAndFlowMonitor.cpp:5245-5249` 的 `enableSwitchAndEdges` 裡有 `(*m_graph)[*ei].isEnabled = true;`，由 `IntentTranslator.cpp:345`（ENABLE_SWITCH）觸發。
   - `topology_manager.py:1510-1512` 自己也點名了這第二條路徑。

8. **L269-270**：「`load_switch_links` 目前只拿來 seed watchdog（`:1811-1846`）」。
   - `topology_manager.py:501` 的 `load_switch_link_ports` 也用它，:650 的 `self._link_ports = load_switch_link_ports()` 決定 beacon 從哪些埠送出。

9. **L293**：「p4info 只在 client 建立時（`:249`）和 SetForwardingPipelineConfig 時（`:667`）讀」。
   - `main.py:455-457` 的 `_p4info_fingerprint` 會開檔算 hash。
   - `p4_client.py:233-236` 的 `pipeline_carries_telemetry` 會解析檔案，呼叫點在 `main.py:473/:515/:1072`。
   - `:667` 是 `req.config.p4info.CopyFrom(self.p4info)`，這是送出，不是讀取。
   - 實質論點（沒有任何路由能在執行中換 pipeline）不受影響。

10. **L361（附錄 C）**：「`delete_ipv4_route` 和 `modify_ipv4_route` 用同樣的 4 個字面常數」。
    - `p4_client.py:1879/1883` 的 delete 只寫死兩個名字：`"MyIngress.ipv4_lpm"` 和 `"hdr.ipv4.dstAddr"`。
    - modify（1932-1951）用的是跟 insert 一樣的 5 個名字。
    - §2.1 的 L98-99 列的也是 5 個。

11. **L43-44**：「其餘都冒充 Ryu 的形狀」。
    - `api_routes.py:161-190` 的 `/sflow/stats` 回的是自家欄位（`datagrams_sent`／`samples_sent`／`send_errors`）。報告自己的附錄 B（L347）也標成「自有」。
    - 正確說法：5 條 P4 形狀、9 條 Ryu 形狀、1 條自有。

12. **L25（以及 L232）**：「NDTwin 的路由會蓋掉作者自己的 entry，雙方都回報成功（`main.py:1030-1034`）」。
    - 被引的是 docstring（`main.py:1027-1036`），描述的是加入旗標**之前**的 readopt 補路由行為，而且發生在「the push that just happened emptied every table」之後。當時表是空的，不存在「蓋掉作者 entry」。那條路徑對外來交換機現在也不跑了（:1076 `install_routes=ndtwin`）。
    - 現在式的宣稱可以由另一組證據撐住：
      - `p4_client.py:1825-1827`（INSERT 失敗改 MODIFY）；
      - `main.py:1312-1313`（外來 fabric 開機時套用 package entries）；
      - `.test_run/packages/basic-solution/pod-topo/s1-runtime.json:12-55`（作者宣告了同一批 /32）；
      - live run `30_switch_state.json` 的 `"applied": 5`。
    - 這組證據報告在 L120-121 已經列出，但標的是 INFERRED。L115-116 把 docstring 當 docstring 引用是對的；L25 和 L232 沒有這樣處理。

## (2) 沒附引用，或拿註解／docstring 撐行為宣稱（UNDER-EVIDENCED）

- **L156**：見 1-7。
- **L124**：「kernel 會讀成 drop」引的是 proxy 的 docstring（`ryu_flow_stats.py:129-131`）。真正能撐這句的 kernel 碼是 `/home/adam/Desktop/NDTwin-Kernel/src/ndt_core/collection/Classifier.cpp:859-873`，報告沒引。L125 說的 GUI 後果沒有驗證。
- **L135**：被引的 1166-1173 是介面查找加註解。真正的呼叫 `cutLinkEnds(..., "100%", ...)` 在 1179-1182，而且只在 MININET 模式下執行（1153-1164）。
- **L41**：cited 範圍裡看不到 501。501 來自 `include/ndt_core/routing_management/OpResult.hpp:169` 加 `HttpSession.cpp:2009-2011`。
- **L39**：modify 引到 :382，但那個分支自己的註解（371-373）說沒有任何呼叫會走到。P4 上實際走的是 :386，經 `P4RoutingStrategy.hpp:66` 回傳 `/stats/flowentry/modify`。
- **L111**：只引了常數，見 1-4。
- **完全沒附引用的 OBSERVED**：
  - L64、L68「14 條」：我核過，成立。
  - L71：SPM 另外還 POST `received_a_simulation_case`／`simulation_completed`，不只是「做 app 註冊」。
  - L154 的 OVS 部分。
  - L294「換程式要重新 `ndt up p4 --app`」：未驗證。
  - L59 的日期。

## (3) INFERRED 寫得像量過的

- **L25**：見 1-12。
- **L164**：標了 INFERRED，卻附上一個反駁它的引用（見 1-2）。
- **L296**：「所以換 pipeline 不必重啟 kernel」是推論，卻放在 OBSERVED 段。每個 `package.json` 都帶自己的 `"topology": "ndtwin/topology.json"`，live run 的 kernel 載入的是 `.test_run/packages/basic/ndtwin/topology.json`（`32_get_graph_data.json:566`）。所以在 `--app` 流程下，換程式等於連拓樸一起換。
- **L123 ③**：沒附引用，而且被 GUI 碼削弱。
  - `SwitchFlowTable.tsx:192` 是 `if (field.value.trim() === '') return;`，預設那一列 `protocol` 是空值，不會送出 `ip_proto`。
  - 只有使用者填了值（或加了 L4 埠，:1187-1188 會自動補 6）才會走到 5-tuple。
- **L122 ②**：flowcache／p4runtime 丟的是 `ControlPlaneReadOnly`（在 `:1772`，發生在任何名字查找之前），不是 `KeyError`。結果同樣是 500。

## (4) 章節之間互相矛盾

- **C1**：L207 說「raw 寫入能用在 11 支」，但 L248-256 表格的 (i) 欄只有 10 支。source_routing 標「—」，§3 L183 也寫它沒有表。
- **C2**：L254 把 multicast 和 calc 合成一列，於是 (ii)／(v) 給了 calc「l2 規則」。這和 L175（calc 沒有轉發表）、L219（calc 不能服務）衝突。
- **C3**：L217 說 multicast 用 `l2_route`，L219 又把 multicast 列在「不能服務」。
- **C4**：L228 的範例規則要求「單一 32 位元 dstAddr 的 lpm key」，但 flowcache 的 `flow_cache` 是三個 exact key，所以這條規則不會產生報告說的假陽性。這條規則反而會命中 p4runtime（變成 8 支，不是 7 支）。
- **C5**：L98-99 列 5 個名字，L361 寫「4 個」，而 delete 實際只有 2 個。
- **C6**：L43-44 與附錄 B 的 L347 衝突。
- **C7**：L105 與附錄 B 的 L356 衝突。
- **C8**：L113 與 L134 衝突。
- **C9**：L305 說「南向回 501 後記進 `recent_failures`，這是既有行為」，和 L122-123、L220、L280 衝突（它們都說今天是 500）。
  - 更要緊的是，7 支同形 pipeline 今天根本不會失敗，而是被 MODIFY 悄悄蓋掉（L120-121）。
  - 501 只出現在 delete／modify 帶了 priority 的情況（`api_routes.py:361-383`）。
- **C10**：L277 第一刀估 5–7 天，但它比 L221 的 (ii) 單表版（8–12 天）做的事更多，兩個數字沒有交代怎麼對得起來。
- **C11**：L12 說「兩邊一致」，但 L381 的抽驗顯示 grep 只找到 7 支，p4runtime 不在 glob 範圍內。我確認過 `~/tutorials/exercises/p4runtime/` 根本沒有 `solution/*.p4`，所以這個交叉檢查只涵蓋 12 支（UNTESTED）。
- **C12**：L111 的「每台」與 §4 (iv) L235-238 的前提衝突。
- **C13**：L296 與 L294 以及每個 package 自帶拓樸這件事衝突。

## 小幅引用偏移（宣稱本身成立）

- L108：實際在 47-55、58-61。另外 `send_to_cpu` 會回 `OUTPUT:CONTROLLER`（144-145），不是 `[]`。
- L235：「5 處編輯加 2 行 apply」漏算了 `ndtwin_telemetry.p4:61-65` 的三行實例化。
- 附錄 A L327：把 IntentTranslator 列為 HTTP 規則路由的使用者，但 `HttpSession.cpp:1836-1837` 說它直接呼叫 `FlowRoutingManager`。
- 附錄 C 漏了 `p4_client.py:1845`（`_ipv4_route_present` 寫死 `"MyIngress.ipv4_lpm"`，在 delete 的 UNKNOWN 退路上）。

## 核過而成立的（SUPPORTED）

- **§0–§1.1**：L12、L15、L37（45 條，逐條數過）、L40、L42、L45-50。
- **§1.2**：
  - L60-64：GUI 共 12 條，全在 `index.ts`／`LLM.ts`，沒有打 proxy、power 或斷鏈注入。
  - L68-70：ESA 14 條；`http.cpp:263-286`；sha `9facb78`；TE 的 :32、:345。
  - L59 的 sha `f63a55c`。
- **§2.1–§2.3**：
  - L92-100、L103-104、L107、L112、L115-116（以 docstring 身分引用）、L121、L130-134。
  - L145-153、L155。
  - L157-159：兩份原始 JSON 都對上，8 個交換機間方向全是 false，8 條主機邊全是 true，`links: {}`，skipped 那三項也對。
- **§3**：
  - 13 列的表名、key、action、位寬、cpm、mode、交換機數，全部逐檔核對。
  - L185-187：PLAN-0917:72 的「這張表」確實指 `MyIngress.ipv4_lpm`。
- **§5–§6 與附錄**：
  - L266、L269（`:873`）、L282、L285（pod-topo 兩個 spine）、L295。
  - 附錄 B 的 15 個行號全部準確。
  - L74／L341 的 404：`HttpSession.cpp:3519-3525` 支持這個推論。
- **抽驗段（L372-381）**：10 列全部可重現。第 8 支我補核了：`~/tutorials/exercises/p4runtime/advanced_tunnel.p4` 宣告了 `table ipv4_lpm`，p4runtime-solution 的 p4info 也是 `ipv4_lpm` → `ipv4_forward(dstAddr/48, port/9)`。

## 報告沒跑、我會跑的檢查

1. 在 flowentry 路徑上 grep `_refuse_write`／`ControlPlaneReadOnly`，不要只 grep 字串 `foreign`（→ 1-6）。
2. 讀 GUI 的**邊**樣式（`Topology.tsx:366-381`）、action 選單（`SwitchFlowTable.tsx:569`）、空值濾除（`:192`）。
3. 列出所有讀 p4info 的地方，再下「只在」這種斷言（→ 1-9）。
4. 列出 kernel 裡所有把邊寫成 `isEnabled = true` 的地方（→ 1-7）。
5. skeleton 版的核對（報告寫沒做）：我逐檔 grep 過，basic、basic_tunnel、ecn、qos、mri、link_monitor、firewall、p4runtime 的 skeleton p4info 都有 `MyIngress.ipv4_lpm`，所以「12/13」在 skeleton 上也被推翻。
   - 注意一個 grep 陷阱：對 `.test_run/packages` 做目錄層級的 grep 會靜默回 0 筆，因為 `.gitignore:1` 的 `build/` 讓 ripgrep 跳過了 build 目錄。要逐檔指定路徑才查得到。
6. 讀既有的 proxy 測試（例如 `p4_proxy/tests/test_flowentry_endpoints.py`）確認 external client／缺表時的狀態碼，用來定案 §2.1 ②③ 和 L305。
7. 確認 `ndt up p4 --app` 會不會重啟 kernel、會不會換掉 kernel 的拓樸檔（→ L296）。
8. 確認 `--app` 下 `NDTWIN_TOPO_FILE` 是否指向 package 的拓樸（§5「用 `load_switch_links` 把鏈路放進 net」的前提）。

## 更正清單（依重要性）

1. **GUI 邊的顏色**：L66、L164、L285（驗收條件要改）。
2. **L305 的狀態碼**：今天是 500 或悄悄蓋掉，不是 501。
3. **L114**：補上 external 的防護。
4. **L113**：與 L134 統一。
5. **L25／L232**：換證據來源，並標成 INFERRED。
6. **L65／L302**：補上 DROP。
7. **L207**：改成 10 支。
8. **L254**：把 calc 拆成獨立一列。
9. **L43-44**：`/sflow/stats` 是自有形狀。
10. **L105**：PRE 不查 p4info。
11. **L111**：「每台」加限定條件。
12. **L156**：「只由」加限定條件。
13. **L269-270**：「只拿來」加限定條件。
14. **L293**：「只在」加限定條件。
15. **L361**：改正 delete 的常數個數，附錄 C 補上 `p4_client.py:1845`。
16. **L12**：寫明交叉檢查只涵蓋 12 支，並補上 p4runtime 根目錄那支檔案作為第 8 支的證據。
17. **L296**：改標 INFERRED 並加限定。
18. **L228**：範例規則和 flowcache 假陽性要對得起來。
19. **L277 與 L221**：兩個工時估計要對帳，或說明差異。
