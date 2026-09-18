# TICKET-P2 — 階段二：per-switch pipeline（G4）、`POST /p4/table_entry`（G5）、單交換機 package、driver 對 NDTwin fabric

orchestrator「9/18 ochestrator」2026-09-18 寫；base trunk **`79dd4312`**（＝`62b77065`＋一顆只有文件的 commit；goal 寫「從 62b77065 開」，碼相同）。
正本方案 `PLAN-0917-exercise-support.md` §3、§6、§8.4、§8.5；階段一的三張工單 `TICKET-P1*.md` 是格式與慣例的前例。
Adam 09-18 裁決（表單逐字）：rule_journal **(a) 階段二先不 journal、明標「proxy 重啟即失」＋`switch_state` 揭露筆數**；`calc` 單交換機**階段二放寬**；
`tools/remote-lab/dorm_lab/` 留本地（與本工單無關，只是提醒：那個目錄永遠不進任何 commit）。

[Co-developed with claude code -- Adam]

## 0. 🔴 紅線（放最上面，因為階段一 D 把它放底下時仍然發生了一次 `pkill -f`）

1. **永不 `pkill -f`／`pgrep -f`／`killall`**。你要停的只有你自己 `Popen` 出來的東西，用它的 pid。閘門會掃你新增的每一行。
2. **不 sudo、不 `ndt up`、不 `mn`、不碰 lab、不起 bmv2**。live 由 orchestrator 跑。你的測試全部離線（stub 的 net／client／ps）。
3. **不建 C++**。本工單不需要 kernel；若你讀碼後認為需要，停下來寫進 SUMMARY，不要自己開 build（這台筆電 build 會被 systemd-oomd 連 Adam 的 app 一起殺）。
4. Python 測試一律 venv 直譯器 `p4_proxy/venv/bin/python -m unittest`（worktree 裡先 `ln -s` 主 checkout 的 `p4_proxy/venv` 與 `p4_proxy/p4_src/build`）；每次跑前清 `__pycache__`；閘門腳本用 `/usr/bin/grep`（互動 shell 的 `grep` 是 ugrep shim）。
5. 只在自己的 worktree、自己的分支 commit：`git commit -F <msgfile> -- <明列到檔案>`；目錄不是明確路徑。AI 參與的檔案標 `[Co-developed with claude code -- Adam]`；訊息結尾 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。**不推、不併 trunk、不動主 checkout。**
6. **沒看過紅不算交付**：每顆新測試都要有一個變異讓它紅（§3.7／§4.5），SUMMARY 列「哪個變異被哪顆測試殺」。
7. **檔案所有權（A、B 平行，不可越界）**：
   - **A** 只動 `p4_proxy/mininet/{app_package,p4_testbed_topo,topo_from_json}.py`、`tools/p4_exercise/**`、`tools/test_workflow/test_topo_from_json.py`、`p4_proxy/tests/{test_app_package,test_fabric_bring_up}.py`、`tests/shell/{mutate_app_package,mutate_p4_exercise_tools}.sh`。
   - **B** 只動 `p4_proxy/proxy_agent/{p4_client,main,api_routes}.py`、`p4_proxy/tests/{test_p4_client_writes,test_startup,test_app_package_proxy,test_readopt}.py`＋新 `test_table_entry_route.py`、新 `tests/shell/mutate_table_entry.sh`、`tools/contract_test/**`（只在 §4.6 那個情況）。
   - 需要動對方檔案＝設計有洞 ⇒ 寫進 SUMMARY 的「異議」，不要動。
8. 讀碼發現本工單行號漂了，以實際為準並在 SUMMARY 註明。工單裡「我確認過」的事實若與碼不符，碼為準、SUMMARY 說。

## 1. 現況（orchestrator 09-18 讀碼確認；行號＝`79dd4312`）

- **pipeline 的讀點階段一已收成一個**：`proxy_agent/main.py:231 build_p4_client` → `package.pipeline_for(dpid, base_dir)`；`mininet/p4_testbed_topo.py:329 MultiSwitchTopo.__init__` → `pipeline_for(1, …)[1]` **拿 dpid 1 的 json 發給每一台**（:345 `addSwitch(..., json_path=json_path)`）；`:810 plan_fabric` 只檢查 dpid 1 的 json 存在，`FabricPlan.json_path` 單值；`ntg_bmv2_topo.py:137-145` 走 `plan_fabric()`＋`bring_up()`，沒有自己的抄本。`BMv2Switch.__init__(json_path=…)` 本來就是 per-switch 參數（:182-216）。
- `mininet/app_package.py`：`SwitchSpec.pipeline` 恆 None（:133-152）；`_switches` :400-404 對非 null raise「G4 not implemented」；`Package.pipeline_for` :197-209 per-switch 優先、否則 `Package.pipeline`＝`BASELINE_PIPELINE`；`_under`／`_existing_file` :298-320；`load` :496-596。
- `tools/p4_exercise/preflight.py`：:360-367 對 pipeline 非 null 報 FAIL「G4 not done」；`P4InfoIndex` :112、`check_entry` :194-280（match 形狀：`[v, len]`＝lpm、純值＝exact；ternary／range 報「G5 not done」）；`_check_entries` :488 用 **entries 檔自己宣告的 p4info**（PLAN §6 第三條）；`_check_compile` :590 印 p4info／json 的 sha。
- `tools/p4_exercise/convert.py`：`parse_switches` :159 只取 `runtime_json`（`cli_input` 拒）；`plan` :275 每台 `pipeline: None`；`_runtime_json_dependencies` :422 把 runtime json 宣告的 p4info／bmv2_json 照相對路徑複製進 package；`source.p4info`／`bmv2_json` 由 `--p4` 的 stem 推。**tutorials `topology.json` 的 `switches[s].program`**（firewall pod-topo：s1 `"program": "build/firewall.json"`，s2–s4 無＝Makefile `DEFAULT_PROG basic.p4`）＝`utils/run_exercise.py:76-79` 的 per-switch json 覆寫，convert 今天把它丟掉。
- `mininet/topo_from_json.py`：`switch_links` :106-130，:128 `raise TopologyModelError("model declares no inter-switch links")`；`hosts` :90 的命名規則。
- `proxy_agent/main.py` `startup()` :~338-570：`read_only` ⇒ `skipped = EXTERNAL_SKIPS`（六步，:288-296）；每台 `set_forwarding_pipeline_config`；clone session／telemetry 每台；`kernel.switch_entered`；`start_lldp_discovery`；`start_link_watchdog(seed_expected=True)`；`start_liveness_polling`。揭露：`_control_plane`／`control_plane_report`／`entries_recorded_report` :286-320，`api_routes.inject_control_plane`；`GET /p4/switch_state` :511-560 加 `control_plane` 與每台 `entries_recorded`。
- `topology_manager.readopt_switch` :1222-1395：build → control_plane（external 502）→ mastership → `set_forwarding_pipeline_config` → `write_clone_session`（有 sample_callback 才寫）→ `install_initial_routes(only_dpid)`；step 名 build／control_plane／mastership／pipeline／routes。`switch_liveness` :1607-1727 每台的鍵（probe_ok…table_generation、pipeline_commits、rules_*）。
- `proxy_agent/p4_client.py`：`_bid` :219、`_refuse_write` :231、`_get_table_id`／`_get_action_id`／`_get_match_field_id`／`_get_action_param_id` :601-625（只認 `preamble.name`，不認 alias）、`_encode_5tuple_value` :883（固定寬）、寫入路徑範本 `insert_5tuple_rule` :966-1010（`_refuse_write` → `WriteRequest` → `_bid` → `Write` → `rule_install_times.record` → ALREADY_EXISTS/UNKNOWN 退 MODIFY）、`read_table_entries` :656。
- `drive_exercise.py`：`EXERCISES` :68 只有 `source_routing`／`basic`（其他 exit 2）；steps 直接用 `self.net.get("h1").popen/cmd`（:391-560）；`preflight()` :225（thrift 9090-9099、直譯器、binary sha）、`compile_prog()` :318 編到**骨架的輸出名**；`main()` :709-830。09-08 的紅（audit-raw `7af2f352`）：basic 骨架＝pingAll 100%、ping 0/3、receive 0；source_routing 骨架＝h2 收 0。
- `tools/test_workflow/ndt`：`host_pid()`＝`ps -eo pid,args` 尾欄 `mininet:hN`；`dataplane_ok()`＝`sudo -n mnexec -a <pid> ping -c 2`（rc 0≠0% loss）；`live-p1/_common.sh` 的 `ping_loss`／`pingall_loss`（`-c 5`、解析 ping 摘要）是 loss 量測範本；`ndt status` :1729「COMPILED P4 pipeline」、:2012 `sample rate`、`stale_pipeline` :1949。
- tutorials 事實（讀檔）：`link_monitor/pod-topo/s1-runtime.json`＝`MyEgress.swid` **default_action** `set_swid(swid=1)`＋`ipv4_lpm` 正常 entries（不是「default-only 表」，只有 swid 表是）；`calc/topology.json` 在 exercise 根、`s1` 一台、兩主機、零 inter-switch 鏈路；p4info `controller_packet_metadata`：`ndtwin_switch` 2 個、`basic` 0、`source_routing` 0（外來 pipeline 沒有 packet_in/out header——LLDP packet-out 打進去無意義）。

## 2. 契約變更（A、B、C 共同遵守；要改回 orchestrator）

### 2.1 `package.json` v1 的 `switches[<dpid>].pipeline`
- `null` ⇒ NDTwin 自己的 `p4_src/build/ndtwin_switch.{p4info.txt,json}`（不變）。
- `{"p4info": "<rel>", "bmv2_json": "<rel>"}` ⇒ 該台跑這一對；相對 package_dir、必須存在、必須在 package_dir 內（`_under`／`_existing_file`）。`format` 仍是 1（加法：舊 package 讀法不變）。
- `Package.pipeline_for(dpid, base_dir)`：per-switch 優先（已有），回絕對路徑。
- 新 `Package.pipeline_is_ndtwin(dpid, base_dir) -> bool`＝`self.pipeline_for(dpid, base_dir) == baseline().pipeline_for(dpid, base_dir)`（A 加）。**B 不 import 這個名字**——B 在 `main.py` 用同一個等價式自算（`_pipeline_is_ndtwin(package, dpid)`），兩邊併回後 orchestrator 收成一個。階段一的碼下這個式子恆 True，所以 B 的所有分支在 A 落地前都是 no-op——這是設計，不是巧合。

### 2.2 「外來 pipeline」下 proxy 的規則（B 實作、揭露；A 不碰）
- **每台**：`pipeline_is_ndtwin(dpid)` 為 False ⇒ 該台跳過 `clone_session`／`sflow_telemetry`（PRE 寫得進去但 pipeline 不 clone＝「報零不報錯」）；package 對該台宣告的 `entries` **套用**（走 G5 writer，§2.3 同一條路）。
- **fabric 級**：任一台為 False ⇒ 跳過 `lldp_discovery`／`link_watchdog`／`install_initial_routes`（三者都靠 packet-out／packet-in，外來 pipeline 沒有 controller header；watchdog 會把每條 seeded link 判 down）。
- **揭露**：`control_plane.skipped` 用同一組名字（`EXTERNAL_SKIPS` 的字串）；每台加 `pipeline: {"ndtwin": bool, "p4info": "<abs>", "p4info_sha256": "<16 hex>"}` 與 `table_entries: {"recorded": N, "applied": N, "failed": N, "api_writes": N, "journaled": false}`。
- **不變**：無 package、或 package 每台 `pipeline: null`、或 `external` 模式 ⇒ 行為與 `79dd4312` 逐位元組相同（entries 仍 recorded 不 applied；`skipped` 照今天）。`live-p1/01_baseline.sh` 是這條的活體斷言。

### 2.3 `POST /p4/table_entry`（B）
Body＝tutorials `sX-runtime.json` 一筆 entry 的形狀＋`dpid`（＋選配 `op`）：
```json
{"dpid": 1, "op": "insert",
 "table": "MyIngress.ipv4_lpm",
 "match": {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]},
 "action_name": "MyIngress.ipv4_forward",
 "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1},
 "default_action": false,
 "priority": null}
```
- `op` ∈ insert（預設）| modify | delete；match 值形狀照 tutorials：exact＝純值、lpm＝`[value, prefix_len]`、ternary＝`[value, mask]`、range＝`[lo, hi]`、optional＝純值——**後三種本階段回 501**，訊息帶 p4info 的 match_type 名。
- 表名／欄位名／action 名／參數名一律查該台 client 的 p4info（`preamble.name`；alias 也接受——tutorials 的 helper 兩者都認，寫進測試）；值編碼：MAC 字串 6 bytes、IPv4 字串 4 bytes、int ⇒ `ceil(bitwidth/8)` big-endian、超出 bitwidth ⇒ 400；`default_action: true` ⇒ `is_default_action`，帶 match ⇒ 400。
- `priority`：exact／lpm 表上非 null 且非 0 ⇒ 400「priority not honourable on this table」——**同一句話、不同碼**（09-18 07:5x orchestrator 裁，B 第一輪指出原文「與 `_refuse_unhonourable_priority` 同語意」對不上：那條回 501）。理由：這個端點講 P4Runtime，spec 定義 priority≠0 於沒有 ternary／range／optional 欄位的表為 INVALID_ARGUMENT＝client 的錯 ⇒ 400；`/stats/flowentry/*` 講 OpenFlow，合法 OF 而交換機做不到才 501。
- 回應 200：`{"status":"success","dpid":1,"op":"insert","table":"…","match_types":{"hdr.ipv4.dstAddr":"LPM"},"priority_honoured":false,"journaled":false,"note":"not journaled: this entry is lost when the proxy restarts (Adam 2026-09-18, option a)"}`。
- 非 200：404 未知 dpid／表／action／欄位／參數；400 形狀或位寬；501 ternary／range／optional；409 `external`（`ControlPlaneReadOnly` 的訊息）；502 switch 拒絕（gRPC code 名，用 `_grpc_status_name`）。**任何非 200 都沒有 Write 上線**——測試用 stub stub 斷言 `Write` 沒被呼叫。
- **不 journal**（裁決 a）：不碰 `rule_journal`、不碰 `topology_manager.route_flow`；`api_writes` 計數進 `switch_state`。

### 2.4 `topo_from_json.switch_links()`（A）
零 inter-switch 鏈路**只在模型恰好一台交換機時合法**（回 `[]`）；兩台以上零鏈路仍 raise，訊息改成同時說明兩種情況。判別式要能被 mutation 區分（M-A7）。

### 2.5 `convert.py`（A）
- `--p4 <rel>` 給了 ⇒ 每台 `pipeline = {"p4info": "build/<stem>.p4.p4info.txtpb", "bmv2_json": "build/<stem>.json"}`（stem＝`_p4_stem`）。
- tutorials `switches[s].program` 給了 ⇒ 該台用**那個 json 的 stem**（`build/firewall.json` ⇒ `build/firewall.p4.p4info.txtpb`），兩檔都複製進 package（缺＝ConversionError 叫人先 `make`）。
- 新旗標 `--ndtwin-pipeline` ⇒ 每台 `pipeline: null`（保住階段一「package 拓樸＋NDTwin pipeline」那一格，live-p1/02 會用）。
- 沒給 `--p4` ⇒ 維持今天（null）。

## 3. 工單 A — core（G4＋calc＋convert／preflight）
opus；worktree `scratch/overnight-2026-09-05/wt-p2-core-0918`，分支 `feat/p4-app-package-p2-core-0918`，base `79dd4312`（orchestrator 已開好、已 symlink venv 與 build）。

3.1 `app_package.py`：`_switches` 接受 §2.1 的物件（缺鍵／非字串／檔不存在／逃出 package_dir 各自 raise，訊息說是哪台哪個鍵）；`SwitchSpec.pipeline` 的型別與 docstring 改成真話（把「Always None in phase 1」那類句子拿掉——留下會說謊的註解等於埋 bug）；`pipeline_is_ndtwin`；`load()` 其餘不動；`baseline()` 逐字不動。
3.2 `p4_testbed_topo.py`：`MultiSwitchTopo` 每台 `package.pipeline_for(dpid, …)[1]`；`FabricPlan.json_path` ⇒ `json_paths: {dpid: path}`（兩個 main 的印字與 `test_fabric_bring_up.py` 跟著改）；`plan_fabric` 檢查**每台**的 json 存在，缺哪台就說哪台；baseline 下 bmv2 argv、ARP 指令、manifest 逐字同（既有 byte-identical 測試必須仍綠——那是 §5 守 baseline 的證明）。
3.3 `topo_from_json.switch_links`：§2.4。`tools/test_workflow/test_topo_from_json.py` 加：calc 形狀（1 台、2 主機、0 鏈路）⇒ `switch_links()==[]`、`host_links` 兩條、`switches` 一台；兩台零鏈路 ⇒ 仍 raise；既有三個模型的斷言不動。
3.4 `convert.py`：§2.5。fixtures：`tools/p4_exercise/tests/fixtures/firewall/`（pod-topo topology＋s1–s4 runtime＋`build/{basic,firewall}.{json,p4.p4info.txtpb}`——從 `~/tutorials/exercises/firewall` 複製，build 沒有就 `p4c-bm2-ss --p4v 16 --p4runtime-files … -o …` 編進 fixtures；**測試比 p4info 的 sha、不比 bmv2 json 的**——json 帶絕對路徑 `program` 欄位，換目錄就換 sha）與 `calc/`（根目錄 topology、單台）。測試：firewall ⇒ s1 pipeline＝firewall、s2–s4＝basic；`--ndtwin-pipeline` ⇒ 全 null；calc convert＋`read_back` 通；可重現（兩次 sha 同）。
3.5 `preflight.py`：:360-367 改成「switches pipeline」檢查：每台非 null ⇒ 兩檔存在、p4info 解析、**p4info 的表名集合與 action 名集合 ⊆ bmv2 json 的**（json：`pipelines[].tables[].name`、`actions[].name`；這是「同一次編譯」在沒有可對的 sha 時可檢查的條件）、印 p4info `sha256[:16]`（穩定識別碼）與 json 的 `program` 欄位（原始碼路徑，僅資訊）；**entries 檔宣告的 `p4info` 必須與該台 pipeline 的 p4info 是同一檔**（realpath 相等；不是 ⇒ FAIL 說 entries 是對哪份程式驗的）；pipeline null＋有 entries ⇒ 維持今天。ternary／range 的 FAIL 訊息改成「本階段 `POST /p4/table_entry` 回 501」的措辭（B 的契約）。
3.6 測試：`p4_proxy/tests/test_app_package.py`（pipeline 物件接受；拒絕：缺鍵、檔不存在、逃出 package_dir；`pipeline_for` per-dpid 回絕對路徑；`pipeline_is_ndtwin` 三態：baseline／null／非 null）、`test_fabric_bring_up.py`（stub topo 記每台 addSwitch 的 json_path：s1 firewall、s2–s4 basic；baseline byte-identical 仍綠；`plan_fabric` 缺 s2 json 的錯誤訊息含 s2）、`tools/p4_exercise/tests`（§3.4；preflight 紅格：p4info⊄json、entries 的 p4info≠pipeline 的、pipeline 檔缺、`--ndtwin-pipeline` 包 PASS）。
3.7 變異（`mutate_app_package.sh` 從 M39 續號；`mutate_p4_exercise_tools.sh` 續號；慣例：anchor 唯一、副本、rehash、HUNG 判定；每顆配具名測試）：
   - M-A1 `pipeline_for` 忽略 per-switch 覆寫（永遠回 fabric-wide）；M-A2 `MultiSwitchTopo` 仍拿 dpid 1 的 json 發每台；M-A3 `plan_fabric` 只檢查 dpid 1；M-A4 `convert` 丟掉 `program`；M-A5 `preflight` 跳過 p4info⊆json；M-A6 `preflight` 接受 entries 的 p4info≠pipeline 的；M-A7 `switch_links` 對兩台零鏈路也回 `[]`；M-A8 `_switches` 接受逃出 package_dir 的路徑；M-A9 `pipeline_is_ndtwin` 恆 True；＋控制組。
3.8 既有全套要綠：`p4_proxy/tests` 全跑、`tools/p4_exercise/tests`、`test_topo_from_json.py`、`tests/shell/mutate_app_package.sh`（38 顆舊的仍 0 survived）、`mutate_p4_exercise_tools.sh`、`bash scratch/overnight-2026-09-05/hunt-0911/drivers/merged_checks.sh <你的 head> 1`。
3.9 交件 `scratch/overnight-2026-09-05/hunt-0911/fix/P2-A-SUMMARY.md`：base sha、head、每個套件的實跑指令＋rc＋最後一行、`N mutations, M survived` 與每顆被誰殺、**沒做／沒驗的明列**、對本工單的異議。

## 4. 工單 B — entries（G5 writer＋route＋startup 套用＋外來 pipeline 跳過）
opus；worktree `scratch/overnight-2026-09-05/wt-p2-entries-0918`，分支 `feat/p4-app-package-p2-entries-0918`，base `79dd4312`（已開好）。

4.1 `p4_client.py`：`encode_value(value, bitwidth) -> bytes`（MAC 6、IPv4 4、int `ceil(bitwidth/8)` big-endian、負數或 ≥2^bitwidth raise `TableEntryInvalid`；規則對齊 tutorials `p4runtime_lib/convert.encode`，**不 import tutorials**）；`build_table_entry(spec) -> (p4runtime_pb2.TableEntry, match_types)`（表／欄位／action／param 全查 `self.p4info`，`preamble.name` 或 `alias`；match_type 用 `p4info_pb2.MatchField.MatchType.Name(field.match_type)`——**不要手抄數字**，enum 跳過 1：EXACT=2 LPM=3 TERNARY=4 RANGE=5 OPTIONAL=6；lpm 的 `prefix_len` 0..bitwidth；ternary／range／optional raise `TableEntryUnsupported(match_type)`）；`write_table_entry(spec, op="insert") -> dict`（`_refuse_write`；`_bid`；`Update.INSERT|MODIFY|DELETE`；`stub.Write`；成功後 `rule_install_times.record` 照 :984 的作法、match 用 `read_table_entries` 的形狀；gRPC 錯誤 raise 出去帶 code——**不要**像 `insert_5tuple_rule` 那樣自動退 MODIFY，這條路的呼叫者要知道 switch 說了什麼）。例外型別：`TableEntryUnsupported`（→501）、`TableEntryInvalid`（→400）、`KeyError`（→404）、`ControlPlaneReadOnly`（→409）、`grpc.RpcError`（→502）。
4.2 `main.py`：`_pipeline_is_ndtwin(package, dpid)`（§2.1 的等價式）；`apply_package_entries(client, entries_path) -> {"applied": n, "failed": n, "errors": [...]}`（讀 runtime json 的 `table_entries`，逐筆 `write_table_entry`，失敗印表名＋原因、不中止、不 raise）；`startup()`：pipeline push 成功且 `not ndtwin` 的台 ⇒ 套用；§2.2 的跳過（per-switch clone／telemetry；fabric 級 LLDP／watchdog／routes）；揭露：`_control_plane`（`skipped`）與新 `_table_entries`／`_pipelines` 報告，走同一個 `inject_control_plane` 或加一個 inject（照既有形狀）；`readopt`：外來 pipeline 下 readopt 之後重套 entries、不寫 clone、不 `install_initial_routes`——`readopt_switch` 在 `topology_manager.py`（不是你的檔），所以用 `main.py` 注入的 `client_factory`／`sample_callback` 與 readopt 回傳值在 `main` 側包一層完成，理由寫在碼裡；做不到就在 SUMMARY 提異議。
4.3 `api_routes.py`：`POST /p4/table_entry`（§2.3）；`GET /p4/switch_state` 每台加 `pipeline`／`table_entries`（§2.2；既有欄位一個不動、不改型別）。
4.4 測試：`test_p4_client_writes.py`（encode：MAC／IPv4／int 寬度／超寬 400；lpm prefix→wire 的 value 與 prefix_len；default_action ⇒ `is_default_action` 且無 match；ternary ⇒ Unsupported；**stub stub 斷言 4xx／501 路徑 `Write` 沒被呼叫**；delete／modify 的 `Update.type`）；`test_startup.py`（外來 pipeline：skips 名單、entries applied／failed 計數、失敗一筆不擋其它；NDTwin pipeline：recorded 不 applied、`skipped: []`；external：與階段一完全同）；新 `test_table_entry_route.py`（FastAPI `TestClient`；每個狀態碼一顆；200 的 `match_types`／`journaled: false`；alias 表名接受）；`test_readopt.py`（外來 pipeline 下 readopt 後重套 entries、不 clone）。
4.5 變異：新 `tests/shell/mutate_table_entry.sh`（照 `mutate_app_package.sh` 的框架：副本、anchor 唯一、rehash、`timeout` HUNG 判定、`N mutations, M survived`、exit 0/1/2/3）：
   - M-B1 exact/lpm 表上非 0 priority 被接受；M-B2 未知表名仍送 Write（table_id 0）；M-B3 lpm 的 prefix_len 不上線（永遠 32）；M-B4 default_action 不設 `is_default_action`；M-B5 int 超寬被截斷而不是 400；M-B6 ternary 回 200；M-B7 `switch_state` 少 `table_entries`（或 `journaled` 變 true）；M-B8 NDTwin 自己的 pipeline 下也套 entries；M-B9 外來 pipeline 下仍寫 clone session；M-B10 外來 pipeline 下 `skipped` 不揭露 lldp/watchdog/routes；M-B11 失敗的寫入被計成 applied；M-B12 readopt 後不重套；M-B13 `external` 下 route 回 200；＋控制組。
4.6 契約測試：跑 `tools/contract_test` 的 selftest＋spec；`switch_state` 新欄位若撞 schema（`additionalProperties`），改 spec 一起交、SUMMARY 明列。
4.7 既有全套要綠：`p4_proxy/tests` 全跑、`tests/shell/mutate_app_package.sh` 38 顆仍 0 survived（你動了 main.py／p4_client.py／api_routes.py——那個閘門 rehash 這三個檔）、`test_ndt_*.sh` 不需要（沒動 ndt）、`merged_checks.sh <head> 1`。
4.8 交件 `hunt-0911/fix/P2-B-SUMMARY.md`（同 §3.9）。

## 5. 工單 C — driver 對 NDTwin fabric＋live 腳本（A、B 併回 trunk 後才派；opus；派工時給 base sha）
5.1 `drive_exercise.py --fabric {tutorials,ndtwin}`：預設 `tutorials`，**plan 區與 sudo 行逐字同 09-08**（測試：`--dry-run` 的輸出對 fixture）。`ndtwin` 模式：**不需要 root、也不要 root**（`ndt` 設計成 operator 帶 sudoers 免密跑）；流程：`preflight()`（thrift 9090 那條在 ndtwin 模式不適用——NDTwin 用 9091-9100，改查 `ndt status` 的 claim／measuring，照 `_common.sh require_free_lab`）→ `compile_prog()`（同今天，編到骨架名）→ `tools/p4_exercise/convert.py <exdir> --topology <spec.topo> --p4 <src 相對路徑> --out .test_run/packages/<ex>-<which>` → `preflight.py` → `ndt claim` → `ndt up p4 --app <pkg>` → steps → `ndt down` → `ndt release`（EXIT 一律走 down＋release，照 `_common.sh finish` 的順序與 knob 還原）。
5.2 `HostRunner` 介面（steps 不再直接碰 `self.net`）：`popen(host, argv, stdin/stdout/stderr)`、`cmd(host, line)`、`pingall(count=5)`。tutorials 實作＝Mininet host（今天的碼搬進去）；ndtwin 實作＝`sudo -n mnexec -a <pid> …`，pid 用 `ps -eo pid=,args=` 尾欄 `mininet:hN`（與 `ndt host_pid` 同規則；測試用 stub ps 輸出）；`pingall`＝每對 `ping -c 5 -W 2` 解析 `% packet loss`（照 `_common.sh ping_loss`；**不是** `ndt` 的 `-c 2`；沒有摘要行＝UNTESTED 不是 0%）。receive.py／send.py 仍用 `/home/adam/p4dev-python-venv/bin/python`（唯一有 scapy 的），在 host namespace 內執行。
5.3 新 steps：**firewall**（README Step 1／3：`iperf h1 h3` 通；`iperf h3 h1` 在 solution **不通**、在 skeleton **通**——先讀 `firewall.p4:195-215` 與 `solution/firewall.p4` 推導骨架行為、標證據等級同 M7 三級；iperf：`-s` 在 host 內背景起、`-c … -t 3`、逾時＝不通；**紅臂＝骨架下 h3→h1 必須通，否則整支 FAIL「紅臂不紅」**——照 live-p1/03 的兩臂範本）、**link_monitor**（README Step 1：`h1 send.py` 探測、`receive.py` 印 `Switch X - Port Y: Z Mbps`；solution：每台 swid 出現且互不相同；skeleton：TODO 未填 ⇒ 從 `link_monitor.p4:240-243` 推導 receive.py 會印什麼，寫成期望；紅臂必須與綠臂可區分）。**四支（basic／source_routing／firewall／link_monitor）都要先在 `--fabric tutorials` 跑綠**（新 steps 對 tutorials harness 的 raw＝與 09-08 同口徑的對照），再對 NDTwin。你不跑 live（§0-2）：離線測試用 stub HostRunner 驗步驟與判定；live 由 orchestrator 跑八次（四支 × 兩臂）＋ `--fabric tutorials` 四次，raw 進 audit-raw。
5.4 `live-p1/02_app_basic.sh` 更新：convert 帶 `--p4` 後 pipeline 非 null ⇒ 斷言 `control_plane.skipped` 等於 §2.2 的 fabric 級集合、每台 `pipeline.ndtwin == false`、`table_entries.applied == 5`、pingall 0%；**另加一格** `--ndtwin-pipeline` 的 package（同一支腳本第二輪或 `02b_`）保住階段一的性質：`skipped == []`、`recorded 5 applied 0`、pingall 0%。01／03 不動。
5.5 `ndt`：`ndt status` 的 `sample rate`／rate source 在 package 任一台 pipeline 非 NDTwin 時印 `n/a (package pipeline)`，`stale_pipeline` 對外來 pipeline 不判（PLAN §3.1）；`tests/shell/test_ndt_app_package.sh` 加格、`mutate_ndt_app_package.sh` 加變異。
5.6 交件 `hunt-0911/fix/P2-C-SUMMARY.md`；driver 的 report 加 `fabric`／package 路徑／`switch_state` 快照（含每台 `pipeline.p4info_sha256` 與 `table_entries`）——那是 raw 的一部分。

## 6. 驗收（goal 原文的對應；orchestrator 執行）
1. A、B 各自：§3.8／§4.7 全綠、judge 一輪、orchestrator 逐 hunk 讀 diff、併回 trunk（`--no-ff`）、合併樹重跑全套；推兩本體（常設授權）。
2. C 併回後 live：`live-p1/01`（baseline 逐位元組不變）、`02`（兩格）、`03` 仍 PASS；driver 對 NDTwin fabric 八次：basic／source_routing／firewall／link_monitor × skeleton 紅／solution 綠；`--fabric tutorials` 四次當對照，basic 與 source_routing 的數字與 audit-raw `7af2f352` 對得上（pingAll 0%／100%、ping 3/3／0/3、h2 收 2／0、ttl [59,62]）。
3. `tests/shell/mutate_app_package.sh` 舊 38 顆全殺＋新的各有具名測試殺；`mutate_table_entry.sh`、`mutate_p4_exercise_tools.sh`、`mutate_ndt_app_package.sh` 0 survived；`merged_checks.sh` 六項綠；契約自測綠。
4. raw 進 audit-raw；宣稱只寫量到的。

## 7. 執行中的裁定（orchestrator，09-18；工單本體不回頭改，這裡是有效的補充）

1. **B §5-3 `default_action: true` ＋ `op: insert` 送成 MODIFY 並揭露（`op` 回 `"modify"`）**：接受。每張表本來就有 compiler 給的 default entry，INSERT 必被拒；tutorials 的 `switch.WriteTableEntry` 做同一個替換。這不是 §4.1 禁的「ALREADY_EXISTS 後自動退 MODIFY」。
2. **B §6-1 readopt 的 `install_initial_routes` 無條件呼叫**（`topology_manager.readopt_switch`，`79dd4312` 的 :1354）：B 第二輪加 `install_routes=True` 參數、外來 pipeline 傳 False；**`p4_proxy/proxy_agent/topology_manager.py` 及其 readopt 測試檔臨時擴給 B**（只准動那一個函式與它的測試），要紅測＋變異。
3. **B §6-2 `mutate_app_package.sh` M18 的 anchor 決定了生產碼形狀**（`read_only` 重綁而不是第二個布林）：這輪接受；「anchor 挑只有這個判斷會出現的字串」記為階段三閘門衛生項目，連同 `merged_checks.sh:11` 字面 `HEAD`、`test_topo_from_json.py` 不在任何閘門（A 的兩條）。
4. **B §5-11 baseline 的 `switch_state` 多 `pipeline`／`table_entries` 兩鍵、`startup()` 回傳多三鍵**：接受，與 P1-A §4-1 同一類；§2.2「逐位元組相同」讀成「所有既有 cell 逐格相同，外加有文件的新鍵」。
5. **A／B 各自的 `pipeline_is_ndtwin`**：A 併入後 B `git merge trunk`（不 rebase），`main._pipeline_is_ndtwin` 收成呼叫 `Package.pipeline_is_ndtwin`；B 用 A 的 fixtures（`tools/p4_exercise/tests/fixtures/{firewall,calc}/build/*.p4info.txtpb`）補「真外來 p4info」的紅測（B §7-2）。
6. **A 第二輪（judge 後）**：preflight 對 pipeline 路徑的規則要與 loader 對稱（拒絕絕對路徑與逃出 package 的路徑）；每個閘門與套件的 stdout 存 `scratch/overnight-2026-09-05/logs/gates-0910/<gate>.p2a-<sha>.log`——**沒有 log 的數字只是轉述**。
7. **`control_plane.skipped` 在外來 pipeline 下只放 fabric 級三個名字（lldp／watchdog／routes）**；per-switch 的跳過放每台 `switch_state[dpid].pipeline.skipped`（外來台 `["clone_session","sflow_telemetry"]`——**用 `main.py` 既有的 `SKIP_CLONE`／`SKIP_TELEMETRY` 常數字串，B 第二輪指出常數是 `"sflow_telemetry"` 不是 `"telemetry"`，常數勝**；NDTwin 台 `[]`）。理由（judge-B）：混合 fabric 裡鄰台 NDTwin 交換機仍有 clone session，fabric 級清單寫 `clone_session` 是對整個 fabric 說了只對部分交換機成立的事。C 照 §5 :110 斷言三名集合。
8. **外來 pipeline 下 readopt 的回應要說真話**：`clone_session: false`（不是 `topology_manager` 因 `sample_callback=None` 回的 true）、`routes` 具名說明沒裝；`readopt_switch(install_routes=False)` 之後 wrapper 不再吞例外。
9. **C 在 A 併入後就派（08:1x，base `b392f111`），不等 B**：C 的檔案（driver、live-p1/02、`ndt` 的兩處、ndt 閘門）與 B 的不重疊，A 已併；C 照 §2.2＋§7 第 7、8 條寫 `live-p1/02` 的斷言，B 併入後 C `git merge trunk` 對照真欄位名修正。§5 標題的「A、B 併回 trunk 後才派」改為「A 併回後」。

10. **（18:5x，live 於 `365c60e1` 之後）`ndt up p4 --app` 對 package 自己的 pipeline 的 verify，開 TICKET-P2-D**：live 02 FAIL、四次 ndtwin driver ERROR，全在 `verify_p4` 等 `all_destination_paths` 到 12（`4/12, never settled`）——而 proxy 照 §2.2 本來就不送 LLDP；資料面對（02 的 pingall 12 對 0% loss、`table_entries failed 0`）。裁定：路徑數 NOT CHECKED 但要**親自讀到** proxy 的 `control_plane.skipped` 含 `lldp_discovery`（讀不到＝紅）；**`table_entries.failed == 0` 是閘**（那是 NDTwin 自己的事）；**forwarding 是讀數不是閘**——source_routing 的解答對 plain ping 也不通（audit-raw `7af2f352` 是用 send/receive 量的），骨架本來就該紅，閘在這裡等於 driver 永遠只有 ERROR；verdict 仍是 `ready`＋但書段；`stack.sh` 讀到 skipped 含 lldp 就不等 300 s（external 也受益）。這是 live 才看得到的洞：§0-2 禁 worker `ndt up`，離線測試裡 `curl` 是 stub。
11. **（19:2x，tutorials 對照六次跑完）link_monitor 兩臂在 tutorials harness 都 FAIL——不是練習、是 driver 的儀器：`receive.py` 不 flush、driver 用 SIGTERM 收 ⇒ 輸出全在 buffer 裡死掉（log 0 B，而 bmv2 s1.log 有 8 個 probe 回到 h1 那個口）。開 TICKET-P2-E：`_start_receiver` 加 `-u`。** 其餘四次全 PASS 且與 audit-raw `7af2f352` 一致（basic pingAll 0%／ping 3/3／h2 1／ttl 63；source_routing 2 packets ttl [59,62]；firewall 解答 h3→h1 擋、骨架通）。
