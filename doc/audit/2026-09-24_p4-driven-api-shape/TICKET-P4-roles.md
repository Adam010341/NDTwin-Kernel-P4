# TICKET-P4 — 階段四第一刀：roles manifest（單表 `ipv4_route`）＋宣告鏈路＋能力旗標

orchestrator「9/24 ochestrator」2026-09-24 寫；base trunk **`6291db35`**（＝`141d1b86`＋Adam 的兩個 README commit；
proxy／package／kernel 碼與 `ANALYSIS.md` 的 base `057a01f0` **逐位元相同**（`git diff --name-only 057a01f0 6291db35 -- p4_proxy tools src include` 為空）⇒ ANALYSIS 的行號在本工單的 base 上仍有效）。
正本：同目錄 `ANALYSIS.md` §5 第一刀、§8 Adam 四條裁決（判官更正輪後版本）；`JUDGE.md`；階段二／三工單 `doc/audit/2026-09-04_p4-tutorial-exercise-prep/TICKET-P{2,3}*.md` 是格式、慣例與裁定前例。

**Adam 09-24 goal 原文（摘要；全文在 `/goal`）**：只做第一刀；心跳由 fabric root helper 送收、本刀只預留入口；GUI 只起草本機分支＋欄位規格；
驗收＝basic live＋其餘 6 支離線＋13/13 回歸；**外來 fabric 上的 `is_up` 來自宣告的鏈路、不代表斷線偵測；(c) 斷鏈自動重算在本刀仍不成立，報告與工單都照這個口徑寫。**

**Adam 09-24 17:4x 追加裁決（互動表單）**：範圍＝第一刀；心跳層＝fabric 的 root helper（proxy 不提權）；GUI＝本機分支＋欄位規格、不推不開 PR；
GUI 測試＝裝 Node＋完整依賴（草稿完成後刪 `node_modules`）；驗收＝basic live＋其餘離線＋13/13 回歸。

[Co-developed with claude code -- Adam]

## 0. 🔴 紅線（同 TICKET-P3 §0，逐條有效；這裡只列有變動或要重申的）

1. **永不 `pkill -f`／`pgrep -f`／`killall`**。只停你自己 `Popen` 出來的東西，用它的 pid。
2. **不 sudo、不 `ndt up`、不 `mn`、不 `tc`、不碰 lab、不起 bmv2。** live 由 orchestrator 跑；你的測試全部離線（stub 的 net／client／subprocess／HTTP）。
3. **沒有任何一張工單可以建 C++。** 本刀不碰 kernel（`src/`、`include/`、`tests/*.cpp`）；覺得需要就停下來寫進 SUMMARY 的「異議」。
4. Python 測試一律 venv 直譯器 `p4_proxy/venv/bin/python -m unittest`（worktree 裡已 `ln -s` 主 checkout 的 `p4_proxy/venv` 與 `p4_proxy/p4_src/build`）；每次跑前清 `__pycache__`；閘門腳本用 `/usr/bin/grep`。
5. 只在自己的 worktree／分支 commit：`git commit -F <msgfile> -- <明列到檔案>`；**目錄不是明確路徑**。AI 參與的檔案標 `[Co-developed with claude code -- Adam]`；
   訊息結尾 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。**不推、不併 trunk、不動主 checkout、Bash 呼叫裡不 `cd`（用 `git -C`／絕對路徑）。**
6. **沒看過紅不算交付**：每顆新測試都要有一個變異讓它紅，SUMMARY 列「哪個變異被哪顆測試殺」；閘門 log 存
   `scratch/overnight-2026-09-05/logs/gates-0910/<gate>.p4<x>-<sha>.log`——沒有 log 的數字只是轉述。log 要在你**最終 head** 上跑。
7. 磁碟：開工時 3.4 G。driver／閘門留下的 `/tmp/drv-*`、`/tmp/tmp*` 自己清；任何一步前 `df -h /` < 1.5 G ⇒ 停下回報，不要自己刪別人的東西。
8. 讀碼發現本工單的事實與碼不符 ⇒ **碼為準**，SUMMARY 說。
9. **所有權（R、G、P 平行，不可越界；需要動對方檔案＝設計有洞 ⇒ 寫進「異議」，不要動）**：
   - **R（roles，proxy＋package 工具）**：`p4_proxy/mininet/app_package.py`；`p4_proxy/proxy_agent/{p4_client,topology_manager,main,api_routes,ryu_flow_stats,ryu_topology}.py`；
     新 `p4_proxy/proxy_agent/route_binding.py`；`tools/p4_exercise/{preflight,convert,common}.py`、`tools/p4_exercise/tests/**`；
     `p4_proxy/tests/{test_app_package,test_app_package_proxy,test_p4_client,test_p4_client_writes,test_foreign_pipeline,test_switch_state,test_ryu_flow_stats,test_flow_stats_route,test_startup,test_readopt,test_table_entry_route,test_lldp_beacon,test_topology_properties}.py`；
     新 `p4_proxy/tests/{test_route_binding,test_declared_links,test_link_state_entry}.py`、新 `p4_proxy/tests/fixtures/renamed_route/**`；
     新 `tests/shell/mutate_roles_binding.sh`；`tests/shell/{mutate_app_package,mutate_table_entry,mutate_p4_exercise_tools}.sh`（**只續號、只修 anchor**）；
     新 `doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/07_roles_basic.sh`、`live-p1/_common.sh`（**只加 helper**）、`live-p1/README.md`（加一列）、
     `tests/shell/{test_live_p1_common,mutate_live_p1_common}.sh`（只在加了 helper 時）。
     **不動**：`p4_proxy/p4_src/ndtwin_switch.p4`、`p4_proxy/p4_src/build/*`、任何 C++、`tools/test_workflow/{ndt,stack.sh}`（`ndt up p4 --app` 若必須改 ⇒ 異議）。
   - **G（GUI 草稿）**：只有 `~/Web-GUI` 的本機分支 `draft/p4-capabilities-0924`（從 `main` `f63a55c` 開）。**不推、不開 PR、不碰未追蹤的 `.env` 與 `NDTwin-Kernel.code-workspace`。**
     Node 裝在 conda 獨立 env（見 §6）。規格正本是本工單附錄 A，G 不改規格；覺得規格錯 ⇒ 異議。
   - **P（PREREG 修訂）**：只有 `doc/audit/2026-09-19_telemetry-three-groups/PREREG.md`（只在檔尾加一節）。

## 1. 現況（ANALYSIS 已核、判官更正後；行號＝`6291db35`＝`057a01f0`）

- kernel 不認得 pipeline；北向 45 條路由（附錄 A）不動。今天外來 pipeline 的寫入：`owner` 概念不存在；7 支同形 ndtwin 模式 pipeline 被
  `p4_client.py:1781,1791` 的字面常數寫進作者的表，同一 /32 已存在時 INSERT 失敗改 MODIFY **悄悄蓋掉**（`:1825-1827`，INFERRED）；其他外來回 500；
  external 模式有 `_refuse_write`（`p4_client.py:424`）擋板。
- `main.py:1535-1545`：一台外來 ⇒ 整個 fabric `skipped` 加 `FOREIGN_PIPELINE_FABRIC_SKIPS`（`:298`，LLDP／watchdog／routes）。
- 鏈路只能經 LLDP 進 proxy 的圖（`topology_manager.py:1546` 是 `add_link` 唯一正式呼叫點）；`render_links`（`ryu_topology.py:87-127`）只輸出圖上的邊；
  kernel 的交換機間邊由輪詢 `updateLinks` 啟用並設 up（`TopologyAndFlowMonitor.cpp:2877-2883`）。live `2026-09-19T062604Z_02_app_basic` 的 8 個交換機間方向全 `false`。
- `load_switch_links`（`topology_manager.py:452`）已讀 package 的拓樸（`--app` 下 `NDTWIN_TOPO_FILE`），今天只拿來 seed watchdog（`seed_expected_links` `:1811`）與決定 LLDP 埠。
- `LinkFailureDetected` 在正式碼沒有訂閱者 ⇒ **kernel 不重算**；改路是 proxy watchdog（`run_watchdog_pass` `:1962-2000`）的事。
  `/ndt/inject_link_failure`（`HttpSession.cpp:1097`）＝兩向 `setEdgeDownByDeclaration`＋兩頭 netem（兩頭或都不）。
  kernel 對「宣告斷」的邊拒絕被 recovery 回報或輪詢復活（`TopologyAndFlowMonitor.cpp:4068` 附近、`m_linkResurrectionDeclined`）——**這層在本刀之後是否仍擋住，是 live L4 要驗的**。
- `ryu_flow_stats.py:59` 按字面 `MyIngress.ipv4_forward` 反查；不認得的 action 今天渲染成 drop（ANALYSIS §6）。
- 501 的既有形狀：`api_routes.py:338-383`（`outcome: "unsupported_on_p4"`）；kernel 端 `P4RoutingStrategy.cpp:11-23`。

## 2. 契約（R、G 共同遵守；要改回 orchestrator）

### 2.1 `roles`（package.json 頂層；format 仍是 1，只加不改）

```json
"roles": {
  "ipv4_route": {
    "owner": "ndtwin",
    "table": "MyIngress.ipv4_lpm",
    "match_field": "hdr.ipv4.dstAddr",
    "action": "MyIngress.ipv4_forward",
    "params": {"dst_mac": "dstAddr", "port": "port"}
  }
}
```

1. **沒有 `roles` 的 package 行為逐位元不變**（今天所有 package 都是這種）。本刀只認 `ipv4_route` 一個 role；其他 role 名、`ipv4_route` 內多餘或缺少的鍵 ⇒ `AppPackageError` 點名欄位。
2. `owner` 只允許 `ndtwin` 或 `package`。`ndtwin`＝NDTwin 獨佔這張表（§8-1）；`package`＝作者擁有，NDTwin 知道綁定（讀回、渲染用）但**不寫**。
3. `roles` 套用到 `pipeline` 非 null 的每一台（外來）；NDTwin pipeline 的交換機一律用 baseline 綁定（§2.2），`roles` 對它們無效且在 `switch_state` 揭露。
   firewall 這種 s1 與 s2–s4 不同 p4info 的 package：同一個 `roles` 對每台各自的 p4info 解析，任一台解析失敗 ⇒ 整包拒絕。
4. **名字一律明寫，不猜。** loader 只驗形狀；p4info 驗證在 `tools/p4_exercise/preflight.py`（fabric 起來之前）**與** proxy 建 client 時（同一個函式，兩處呼叫）：
   表存在；`match_field` 在該表且 match type＝LPM、位寬 32；`action` 在該表的 action refs；`params` 兩個都存在、`dst_mac` 位寬 48、`port` 位寬＝p4info 所記且容得下拓樸裡最大的埠號；
   action 不得有第三個參數（NDTwin 填不了）。proxy 端解析失敗 ⇒ 拒絕啟動（與 preflight 同一個錯誤訊息），不是退回 unbound。
5. `owner: ndtwin` 時，package 對該表的**比對 entries** 在 preflight 就 FAIL 並逐條點名（§8-1）；該表的 `default_action` entry 允許、揭露。
6. preflight 對「外來 pipeline 沒有 `roles` 但有一張 lpm 32 位元＋兩參數 action 的表」印**建議**（非 fatal、一行、寫出可貼的 `roles` 區塊）。啟發式只准出現在這裡。
7. `tools/p4_exercise/convert.py` 加 `--role-ipv4-route owner=…,table=…,match_field=…,action=…,dst_mac=…,port=…`（全部必填、不猜）：寫 `roles`、
   `owner=ndtwin` 時把各台 runtime 裡對該表的比對 entries 移掉並在 convert 報告裡算數。**不帶這個旗標的輸出與今天逐位元相同**（對 fixture 斷言）。

### 2.2 `RouteBinding`（proxy；新模組 `route_binding.py`）

1. `RouteBinding(table, match_field, action, dst_mac_param, port_param, owner, source)`，`source ∈ {baseline, package}`。
   `BASELINE` 的值＝今天的字面常數；重構後這些字面常數**只准出現在 `BASELINE`**（閘門 grep 斷言）。
2. 每個 P4 client 建立時（含 readopt）決定綁定：NDTwin pipeline ⇒ `BASELINE`；外來＋`roles` ⇒ 解析結果；外來無 `roles` ⇒ `None`（unbound）。
3. `insert/modify/delete_ipv4_route` 與 `install_initial_routes` 從綁定讀名字。**unbound 或 `owner: package` 的寫入 ⇒ 501**，body 沿用 `api_routes.py:338-383` 形狀
   （`outcome: "unsupported_on_p4"`、`reason` 寫 `unbound` 或 `owned_by_package`）；取代今天的 500／悄悄 MODIFY。外來交換機上的 5-tuple 寫入一律同樣 501（本刀沒有 5-tuple role）。
4. external 模式照舊由 `_refuse_write` 擋（409 唯讀），優先於 roles；本刀不改它。
5. **baseline 零變化**：在 base 用 stub 錄下 `insert/modify/delete_ipv4_route` 與 `install_initial_routes` 對 NDTwin pipeline 送出的 P4Runtime WriteRequest（序列化位元組），
   存 fixture；重構後逐位元相等。既有測試**不改斷言**（只准改 import 或 fixture 路徑，SUMMARY 逐條列）。
6. **必須有一個名字與字面常數不同的 fixture**（`fixtures/renamed_route/`：表、match 欄位、action、兩個參數全改名的 p4info）——
   basic 的名字恰好等於字面常數，只拿 basic 測，綁定碼與寫死常數分不出來。

### 2.3 宣告鏈路

1. fabric 裡有外來交換機時，proxy 用 `load_switch_links`（package 拓樸）把交換機間鏈路放進 `net`，走與 LLDP 同一個 `add_link` 入口（或抽出共用函式），
   讓 `render_links` 輸出它們、kernel 的 `updateLinks` 把邊啟用並設 up。每條在 `switch_state` 標 `source: "declared"`。全 NDTwin fabric 不變（LLDP 照舊）。
2. **seed 不得向 kernel 送 `/ndt/link_recovery_detected`**（也不送 `link_failure_detected`）——宣告只是「線存在」，不是「線剛恢復」；送了會和 kernel 的宣告斷防護打架。測試＋變異。
3. **每台外來交換機都有 `owner: ndtwin` 的綁定時**，`install_initial_routes` 不再跳過（從該 fabric 的 `skipped` 拿掉 routes）；有任何一台 unbound 或 `owner: package` ⇒ 照舊整個跳過。
   **LLDP 與 watchdog 在外來 fabric 照舊跳過**（本刀不改）。
4. 口徑：外來 fabric 的 `is_up` 來自宣告，**不是斷線偵測**；`capabilities.reroute` 為 false（§2.5）。報告、log 訊息、SUMMARY 一律照這個寫。

### 2.4 外部鏈路狀態入口（預留給第二刀的 fabric root helper）

`TopologyManager.report_external_link_state(src_dpid, src_port, dst_dpid, dst_port, up, source)`：
- watchdog 在跑（全 NDTwin fabric）時：與 beacon 逾時／恢復**走同一條路**（`_notify_link`＋`run_watchdog_pass`）。
- watchdog 被跳過（外來 fabric，本刀的狀態）時：**只記錄、不改路、不通知 kernel**，在 `switch_state` 以 `external_link_reports` 計數揭露。
- 本刀**不加 HTTP 路由**、沒有呼叫者（第二刀接）；SUMMARY 明寫「入口存在、外來 fabric 上未接線」。兩個分支都要有看過紅的測試。

### 2.5 讀回與揭露

1. `ryu_flow_stats` 用綁定反查 `OUTPUT:<port>`；**不認得的 action 不列出**（不再渲染成 drop），每台的數字在 `switch_state` 的 `flow_stats.unrendered_entries`。
   NDTwin pipeline 的 `/stats/flow` 輸出對 base 逐位元相同（fixture）。
2. `GET /p4/switch_state` 每台加（只加不改）：
   ```
   "capabilities": {
     "ipv4_route": "ndtwin" | "package" | "unbound",
     "five_tuple": true | false,          // 只有 NDTwin pipeline 為 true
     "reroute": true | false,             // 只有 LLDP＋watchdog 在跑的 fabric 為 true
     "link_discovery": "lldp" | "declared",
     "binding_source": "baseline" | "package" | null
   }
   ```
   混合 fabric：watchdog 是整個 fabric 跳過的 ⇒ NDTwin pipeline 那幾台 `reroute` 也是 false。

## 3. 工單 R — roles（opus-worker；worktree `scratch/overnight-2026-09-05/wt-p4-roles-0924`，分支 `feat/p4-roles-first-cut-0924`，base `6291db35`）

3.1 §2.1–§2.5 全部。
3.2 測試（全部先看紅）：`test_route_binding.py`（baseline 值、renamed fixture 解析、每一條 §2.1-4 的拒絕、owner 兩值、readopt 重解析）、
`test_declared_links.py`（seed 進 `net`、`render_links` 輸出、全 NDTwin fabric 不 seed、seed 不送 recovery／failure、routes 跳過與否的三種組合）、
`test_link_state_entry.py`（§2.4 兩分支）、`test_p4_client_writes.py` 加 WriteRequest 逐位元 fixture 與 renamed 綁定的寫入、`test_switch_state.py`（capabilities 形狀與混合 fabric）、
`test_ryu_flow_stats.py`（綁定反查、不認得的不列出、計數）、`test_app_package.py`（`roles` 形狀拒絕、無 `roles` 不變）、`tools/p4_exercise/tests`（preflight 驗 p4info、entries 拒絕、建議行、convert 旗標與不帶旗標逐位元不變）。
3.3 變異（新 `mutate_roles_binding.sh`，每顆具名、每顆指名殺它的測試，＋2 控制）：
M-R1 綁定解析忽略 `roles`、一律用字面常數（只有 renamed fixture 殺得到）；M-R2 unbound 外來寫入落回字面寫入（不是 501）；M-R3 `owner: package` 仍可寫；
M-R4 preflight 不拒 owned 表的 entries；M-R5 preflight 不驗位寬；M-R6 宣告鏈路不 seed；M-R7 seed 送 `link_recovery_detected`；
M-R8 全 owned 時仍跳過 routes；M-R9 有一台 unbound 時不跳過 routes；M-R10 外來 fabric 不跳過 LLDP／watchdog；M-R11 不認得的 action 渲染成 drop；
M-R12 外來 fabric `reroute: true`；M-R13 baseline 綁定任一名字改掉；M-R14 §2.4 watchdog 跳過時仍改路；M-R15 convert 不帶旗標時輸出變了。
`mutate_app_package.sh`／`mutate_table_entry.sh`／`mutate_p4_exercise_tools.sh` 既有變異全殺（anchor 漂了修回，SUMMARY 列）。
3.4 既有全套要綠：`p4_proxy/tests` 全跑、`tools/p4_exercise/tests`、上面四支閘門、`tests/shell/check_gate_anchors.py`、契約自測、
`scratch/overnight-2026-09-05/hunt-0911/drivers/merged_checks.sh <head> 1`。
3.5 live 腳本 `07_roles_basic.sh`（你寫、離線自測、**不跑**）：實作 §5 的 L1–L6，照 `_common.sh` 慣例（`NDT_OWNER`、claim、run 目錄、每步存原始 JSON）。
3.6 交件 `scratch/overnight-2026-09-05/hunt-0911/fix/P4-R-SUMMARY.md`：OBSERVED／INFERRED 分開；變異表；閘門 log 路徑與它們的 head；`git diff --stat 6291db35..HEAD`；
「orchestrator 要跑的 live 清單」（逐行指令，含 roles 版 basic package 怎麼用 convert 產生）；「異議」。**送出最終訊息後不准再改 SUMMARY。**

## 4. 工單 G — GUI 草稿（opus-worker；`~/Web-GUI` 本機分支）

4.1 開工先 `df -h /`，< 2.5 G ⇒ 停下回報。Node：`~/miniconda3/bin/conda create -y -n webgui-node -c conda-forge nodejs=22`，pnpm 用該 env 的 `npm install -g pnpm`；
`pnpm install --frozen-lockfile`（**lockfile 不准變**）。
4.2 依附錄 A 寫純函式模組（不依賴 React）：節點 → 被停用的操作集合；**沒有 `capabilities` ⇒ 全部可用**（OVS、舊 kernel）。
單元測試用 `node --test --experimental-strip-types`（或已在依賴裡的測試工具；不新增依賴），先看紅（每條規則一個變異）。
4.3 接進元件：不支援的操作變灰＋tooltip 說原因（`unbound`／`owned_by_package`／`reroute unavailable`）。`tsc -b` 與 `pnpm build` 通過。
用假資料（附錄 A 的三個節點樣本存成 fixture）驗顯示；不能截圖就寫清楚驗了什麼、沒驗什麼。
4.4 交件 `scratch/overnight-2026-09-05/hunt-0911/fix/P4-G-SUMMARY.md`：分支名與 head、改了哪些元件、映射表、測試與變異、build log 路徑、「讀過未執行」與「跑過」分開列。
**不推、不開 PR；`node_modules` 留著，orchestrator 讀完後刪。**

## 5. 驗收（goal 原文的對應；orchestrator 執行）

1. R：§3.4 全綠 → opus-judge（難裁決才 fable-judge）→ 我逐 hunk 讀、在 R 的 head 重跑閘門 → `--no-ff` 併 trunk → 合併樹全套 → 推兩本體並驗公開。
2. live（`ndt claim`＋`NDT_OWNER`，開跑前查磁碟；binary sha 記進 run）——`07_roles_basic.sh`：
   - **L1** pod-topo、`--app basic`（roles `owner: ndtwin`）：`GET /ndt/get_graph_data` 8 個交換機間方向全部 `is_enabled:true, is_up:true`（對帳：`062604Z_02_app_basic` 全 false）。
   - **L2** 經 kernel API 的 batch 規則寫得進去：`get_flow_dispatch_status` 無失敗、`/stats/flow/{dpid}` 讀得回。
   - **L3** 主機間 ping 走得通（NDTwin 用 `install_initial_routes` 寫進作者表的路由真的會轉發）。
   - **L4** `inject_link_failure` 一條交換機間鏈路 → 兩向 `is_up:false`，**等過一次 `updateLinks` 輪詢（≥ 35 s）仍為 false** → `inject_link_recovery` → 回 true、無 netem 殘留。
     不斷言改路（(c) 本刀不成立）；該路徑上的流量中斷照實記錄。
   - **L5** 陰性對照：不帶 `roles` 的 basic（今天的 package）——kernel 寫入得到 501 `unsupported_on_p4`（記進 `recent_failures`），作者的 `ipv4_lpm` entries 前後逐條相同。
   - **L6** `switch_state` 每台 `capabilities` 與 §2.5 相符（L1 的 fabric：`ipv4_route: ndtwin`、`five_tuple: false`、`reroute: false`、`link_discovery: declared`）。
3. 離線：其餘 6 支同形（ecn、qos、mri、link_monitor、firewall、basic_tunnel 的 IP 部分）用 convert 旗標產 package＋preflight PASS；
   反向對照：calc／load_balance／multicast／source_routing 指向 `ipv4_lpm` 的 roles ⇒ preflight FAIL 並點名缺什麼。
4. 回歸：live-p1 `01`（NDTwin pipeline，對上一輪逐格同）＋`06_thirteen` 13×2 全綠（對帳階段三 13/13）。
5. 所有閘門 0 survived、控制組 0 紅；raw 進 audit-raw。

## 6. 工單 P — PREREG-AMENDMENT-2（opus-worker；worktree `wt-p4-prereg-0924`，分支 `docs/prereg-amendment-2-0924`，base `6291db35`）

在 `doc/audit/2026-09-19_telemetry-three-groups/PREREG.md` 檔尾加 `## AMENDMENT-2（2026-09-24）`，只補三條（來源：`TICKET-P3-observation.md` §9 裁決 40 ②③⑤）：
(a) H-B0「H-B1 與 H-B2 皆不成立」分支與它的意義（低速率的誤差來源既非 shot-noise 也非同號偏差），以及它對應的結局表動作；
(b) H-C2 第二條件的「≈」＝比值 ∈ [0.5, 2.0]；(c) H-C0 的散佈量＝同一格三窗 Δkernel 的散佈（寫出算式）。
每條寫明：**只管 commit 之後取得的資料；不重跑、不回填；第五次 campaign 的 FINDINGS 不因此改判**；並引用裁決 40 原文位置。不改 PREREG 其他任何一行。
交件＝commit sha＋一段 SUMMARY 直接放在最終訊息（不另開檔）。

## 附錄 A — kernel `get_graph_data` 節點 `capabilities` 欄位規格（第三刀實作；G 照這個寫）

- 交換機節點可帶 `capabilities` 物件，**內容逐字抄 proxy `GET /p4/switch_state` 該台的 `capabilities`**（§2.5-2）；P4 模式下 kernel 讀不到就**不帶這個欄位**；OVS 模式不帶。
- **沒有 `capabilities` ⇒ 所有操作視為支援**（向後相容：OVS、舊 kernel、proxy 沒報）。GUI 不得把缺欄位當成「不支援」。
- 語意：`ipv4_route != "ndtwin"` ⇒ 以目的 IP 為準的路由寫入（加／改／刪）不支援；`five_tuple: false` ⇒ 帶 5-tuple 欄位的規則寫入不支援；
  `reroute: false` ⇒ 斷鏈後不會自動改路（注入斷鏈本身仍可做，GUI 只加提示、不擋）；`link_discovery: "declared"` ⇒ 鏈路狀態來自宣告（提示用）。
- 三個 fixture 樣本（G 的測試用）：①無 `capabilities`（OVS）；②NDTwin pipeline（`ndtwin`/`true`/`true`/`lldp`/`baseline`）；③外來 owned（`ndtwin`/`false`/`false`/`declared`/`package`）；
  另加 ④外來 unbound（`unbound`/`false`/`false`/`declared`/`null`）。

## 7. 執行中的裁定（orchestrator；工單本體不回頭改，這裡是有效的補充）

### 裁決 1（09-24 18:5x）：goal (7) tutorials 18 臂——16 臂如預期、2 臂是儀器錯，派工單 D' 修 driver 後重跑那 2 臂

- 實跑（trunk `6291db35`、driver blob `99c862a9` 未改；`scratch/overnight-2026-09-05/logs/orchestrator-0924/tutorials-18/`）：16 臂與 P3-D-SUMMARY §7.1 的預期表一致
  （basic_tunnel／flowcache 骨架 rc 1 RED ARM、其餘骨架與解答 rc 0 PASS）；**flowcache 與 p4runtime 的解答臂 FAIL (4/4)**。
- 原因（讀 log＋開檔核過）：tutorials 臂直接執行 `solution/mycontroller.py`，它以自身目錄加 `../../utils/` 找 `p4runtime_lib` ⇒ 解析成 `exercises/utils/`（不存在）⇒ import 即死
  （`ModuleNotFoundError`）。tutorials 的用法是把解答複製到練習目錄再跑；骨架在練習目錄所以正常。**這是 driver 在一條從未實跑過的路徑上的錯，不是資料面結果。**
- 裁：派 D'（worktree `wt-p4-driver-0924`，分支 `fix/tutorials-solution-controller-0924`；只准動 `drive_exercise.py`／`DRIVER.md`／`tests/**`／`mutate_drive_exercise.sh`）：
  不改 `--fabric ndtwin` 路徑、不改骨架臂、不改凍結的 tutorials plan／sudo 行；紅先＋具名變異。併回後 orchestrator 重跑這 2 臂；REPORT-P3 附錄照「16 如預期＋2 儀器錯→修→重跑結果」寫，不把第一次的 FAIL 刪掉。

### 裁決 2（09-24 19:0x，Adam 互動表單）：PREREG-AMENDMENT-2 不併，改寫進下一輪的新 PREREG

- P 交 `69e79a8f`（`docs/prereg-amendment-2-0924`，只在 PREREG.md 檔尾加 94 行、刪除 0 行，orchestrator 核過）。P 的異議兩條改變了前提：
  ① PREREG `:20` 把 AMENDMENT-1 的三條（零封包、理由只引既有資料、只收緊）定為本檔修訂門檻，而本修訂寫在第五次資料之後，(b) 的 [0.5, 2.0] 更是看過 link 0.537 之後提出、且 0.537 落在區間內；
  ② (c)「同一格三窗 Δkernel」在梯子設計裡不存在（每階多半 1 rep，只有 loss ∈ (0, 2%] 才補到 3 rep）——**裁決 40⑤ 的前提有誤，REPORT-P3 §1③ 照抄了它**。
- Adam 裁：**不併**；分支留作草稿；下一次排量測時（天花板換工作點本來就要重新註冊）寫進那一輪自己的 PREREG，不是事後修訂。goal (6) 以「草稿完成、刻意不併」收案。

### 裁決 3（09-24 19:0x，Adam 互動表單）：FINDINGS §4 的每階 CPU 時間窗疑遭確認 rep 污染——現在派人離線重算，只算不改

- orchestrator 開檔核過的部分（OBSERVED）：第五次 raw 的 `rungs.tsv` 把梯頂確認 rep 記成 `c1`–`c3`、kpps＝最高乾淨階、時間在更高階之後；`analyse.py` `rung_windows`（`:693`）把同 kpps 的列聯集成一個窗，`cpu_for_window`（`:739-740`）與 `rung_samples_per_second`（`:708`）都用它 ⇒ 例 `G4/link_f64_b` 的 20 kpps 窗 ≈ 110 s、包住 30–110 kpps。
- 對 FINDINGS 判決的影響是 INFERRED、未重算。派工單 C（`wt-p4-cpuwin-0924`，`analysis/cpu-window-recheck-0924`）：先確認 PREREG 註冊的每階窗是什麼（PREREG 沒說清楚就兩種讀法並列、不選）、紅先修碼、新舊對照表。
  **FINDINGS 要不要更正由 Adam 看過對照表再裁**；在那之前公開的 FINDINGS §4 維持原樣，報告裡明講「待驗證」。

### 裁決 4（09-24 20:0x，Adam 互動表單）：FINDINGS §4＋fig3 更正、保留舊值勘誤表；主讀法＝「只算爬升」（Adam 裁定，非 PREREG 註冊）

- C 交 `93033c44`，opus-judge **HOLDS WITH CORRECTIONS**。成立：`rung_windows` 的聯集窗確實包進確認 rep；修正後 H-C（兩組）與對帳 (b) 不變；
  F 約 ÷3（coop 0.9234→0.3212、link 0.7692→0.2492）、share（coop 0.0722→0.0257）、m 小升（coop 122.89→126.19、link 79.00→82.41）；§1–§3 零變動（1560 葉同、99 葉變）。
  **判官更正 C 與 orchestrator 的說法：註冊的 bmv2 每階判決有翻**（PREREG `:276-277`）——12 kpps 帶外→帶內、30 kpps 帶內→帶外，帶外總數仍 2／11。
- 讀法：PREREG 沒決定確認 rep 屬不屬該階 CPU；兩種讀法在第五次的判決完全相同。Adam 選「只算爬升」，理由記錄：§5.3（`:263-266`）把 CPU(k) 與 S(k) 配對，而 S(k) 只涵蓋爬升（`:505-507`）⇒ 同窗；
  08-28 規則（`2026-08-28_flow-count-capacity/PREREG.md:254-255`）把首讀與確認分開記。FINDINGS 與輸出要標「Adam 2026-09-24 裁定、非 PREREG 註冊」。
- C 第二輪：判官各項＋下游（`cpu_bmv2_ratio`、對帳 (b)、render、fig3）標明讀法＋FINDINGS 以腳本重生＋勘誤表（舊值保留）＋重生 fig3（fig1／fig2 須逐位元不變）。
  cooperative 仍貼 H-C1，但名稱「固定成分主導」與 share 0.026 字面不符 ⇒ FINDINGS 在標籤旁明寫「成立依據只有 m 落帶」（裁決 40④）。

### 裁決 5（09-24 21:4x）：R 首刀 opus-judge「MERGE AFTER FIXES」——R 第二輪修 9 項；orchestrator 裁 4 項口徑

- 判官全文：`scratch/overnight-2026-09-05/logs/orchestrator-0924/judge-R-57aae1bf.md`（agent `a8ed6d7da8b264752`，對 `57aae1bf`）。基線主宣稱大致成立（NDTwin pipeline 的 WriteRequest／`/stats/flow` 不變、unbound／`owner: package` 寫入 501、宣告鏈路不通知 kernel、§2.4 兩分支看過紅、108/0）。
- orchestrator 開檔核過（OBSERVED）：判官 1——`main.py:1336-1338` readopt 以 `install_routes=ndtwin` 呼叫，繞過 `:1838-1849` 的 fabric 級 routes 跳過；本刀在外來 fabric seed 了交換機間的邊 ⇒ 混合 fabric 上 readopt 一台 NDTwin 交換機會寫穿過 unbound 交換機的路由（刀前 `net` 無此邊，只補得到直連主機）。
  判官 4——`ryu_flow_stats.py:307-313` 只在 match 有可用鍵時才計數；renamed fixture 的非路由列用 `hdr.ip4.proto`，不在詞彙內 ⇒ 不列也不計。判官 12——主 checkout 的 `host_count_override` 未提交值是 **4**（HEAD 與 R worktree 為 128；我先前記成 128 是錯的）。
- **R 第二輪（紅先＋具名變異；只准動 R 已動過的檔、新測試、SUMMARY）：**
  ① readopt 補路由服從 fabric 級的 routes 跳過：fabric 跳過 routes 時，readopt **不得寫任何路徑穿過其他交換機的路由**；優先保留刀前行為（只補該台直連主機），做不乾淨就整個不補並揭露。
     全 owned fabric 上外來交換機 readopt：與啟動同一判準（fabric 未跳過 routes 且該台綁定 owner `ndtwin` 才補）。兩個方向都要有看過紅的測試（紅先：一台 NDTwin＋一台 unbound＋宣告鏈路，readopt NDTwin 那台 ⇒ 無遠端路由）。
  ② 字面常數閘門擴到 route role 的 match field：`FIELD_TO_RYU` 的 `hdr.ipv4.dstAddr` 鍵改由 `BASELINE.match_field` 導出；閘門斷言表名、action、match field、`dst_mac_param` 只在 BASELINE＋具名例外。
     5-tuple 的鍵（`p4_client.py:1648`、`topology_manager.py:197-198,222`）不屬 route role ⇒ 具名例外；`"port"` 無法 grep ⇒ 豁免並寫明。
  ③ `unrendered_entries`＝外來交換機上**所有未列出的非預設列**（action 不認得，或 match 無可用鍵）——即該欄自己的語意「描述不了的規則不列、但計數」。NDTwin pipeline 恆為 0、`/stats/flow` body 不變。M-R11 殺手測試改用 renamed fixture 的真實列形狀。
  ④ 補 baseline 逐位元證據鏈：base（`d492a346`）四個 fixture 常數區塊對 HEAD 的 diff（或在 HEAD production 上跑 base 的四個 fixture 測試類別），log 進 `logs/gates-0910/`；
     NDTwin client 的 `/stats/flow` 加一條 HTTP body 位元組比對（在 base 錄，錄製腳本入 repo、附出處標頭）。
  ⑤ 外來交換機上 5-tuple delete／modify 經 HTTP 回 501 的測試（§2.2-3；現只測 add 與 client 層 insert）。
  ⑥ 07 自測：其餘 8 個判定各一顆變異，另加拿掉 reason、`"unbound"` 子字串、`is_enabled` 子條件各一顆；L5 加一個打作者 /32 的探針（例：s1 上 10.0.1.1 換 port），驗同一 /32 不被悄悄 MODIFY。
  ⑦ 跑 `tests/shell/mutate_a7_dispatch_status.sh --python-only`（錨點在本刀改過的 `api_routes.py`）。
  ⑧ `link_discovery` 由模式決定、不由 seed 數目決定：外來 fabric（非 external）⇒ `"declared"`（含零條宣告鏈路、含 seed 拋錯）；seed 拋錯另在 fabric 層 `switch_state` 揭露（欄名 R 定、SUMMARY 寫明）。`"none"` 只留給 external。
  ⑨ SUMMARY 更正：§0「全綠」改成實際（merged_checks 七項逐項、tools 全套用真 tutorials 紅且 base 同紅）；D12 行號（`:20`）；§4 最後一行；OBS4「不是手打」；D3 範圍（照 ②）；D5 措辭照碼（external 下任何綁定含 baseline 都寫 `package`）；
     OBS6 無 log 的那筆標明；OBS1 無 roles 的行為宣稱收窄（外來無 roles 的 `/stats/flow` 會漏列未知 action）；OBS10 `_withmodel` 兩份 log 的出處；記名揭露 fail-open 預設（`p4_client.py:260,429` 綁 BASELINE、production 唯一建構點 `main.py:245`）。
- **orchestrator 裁（不改碼）：**
  (a) §2.2-4 的「409 唯讀」更正：`_refuse_write` 在綁定之前擋（成立），但 `/stats/flowentry/*` 不接 `ControlPlaneReadOnly` ⇒ HTTP 500，與 base 相同；本刀照 §2.2-4 不改，列第二刀。
  (b) 附錄 A 補 `link_discovery: "none"`＝external 模式（沒有任何機制發現或宣告鏈路；提示用，不擋操作）。G 的草稿下一次動時補這個值。
  (c) D7（external 不 seed）＝對 §2.3-1 的窄讀，**照准**：§2.2-4 定了 external 本刀不改，seed 會改變 external 下 kernel 看到的邊。
  (d) 判官 11 的 fail-open 預設是被「既有測試不改斷言」逼出的設計，可接受；照 ⑨ 記名揭露。`merged_checks.sh` 整支由 orchestrator 在合併樹跑（D12）。
- 第二輪收件：同一個判官（`a8ed6d7da8b264752`）只審第二輪 diff 與 ①–⑨ 的逐項證據（範圍限定，同裁決 40⑩ 前例不另開判官）。

### 裁決 6（09-24 23:1x）：R 第二輪 `3ff87a10` 判官（同一位、範圍限定）「MERGE AFTER FIXES」——①–⑨ 全 DONE，小修一項＋三項揭露

- 判官全文：`scratch/overnight-2026-09-05/logs/orchestrator-0924/judge-R-r2-3ff87a10.md`。①–⑨ 逐項 DONE、證據屬實；總表的 RED 只是那兩列 FixtureProvenance 預期值過期（`advanced_tunnel.json` mtime 21:16:14＝orchestrator 的還原）。
- orchestrator 開檔核過（OBSERVED）F1：`topology_manager.py:1053-1085` `_control_plane_port` 不看 `routes_to_attached_hosts_only`，`unroute_flow` 的 A-4d 還原（`:1142-1155`）用它 ⇒ 混合 fabric 上刪一條 app 規則，仍會「還原」一條穿過其他交換機的路由——① 同一類、另一個入口。
- **R 第三輪（範圍只到這裡；紅先＋具名變異）：** F1 `_control_plane_port` 在旗標為真且下一跳不是目的主機時回 None，並改掉 `:659-662`「readopt's refill is the one writer left there」；
  F2 `main.readopt_switch` 依 `_fabric["watchdog"]` 拿掉沒有 watchdog 時的 `routes_pending`／「watchdog 會補」（不動 M-B29 的錨點行）；F3 外來 owned 交換機的補路由被跳過時，`routes_note` 寫真正的原因；
  F4 錄製 wrapper 放進 scripts 目錄、錄製腳本的 sha 在新 head 由閘門重算；F5（① 無 live、all-NDTwin LLDP 啟動失敗只剩 `reroute:false`）寫進 SUMMARY 的已知缺口。
- 第三輪收件：orchestrator 逐 hunk 讀＋重跑 `mutate_roles_binding` 與 p4_proxy 全套（範圍限定，同裁決 40⑩ 前例不另開判官）。
