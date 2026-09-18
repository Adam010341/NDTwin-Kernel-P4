# TICKET-P1 — 階段一：P4 app package 骨架（profile／pre-flight／convert／G2／G3／`ndt up p4 --app`）

orchestrator「9/17 orchestrator」2026-09-17 寫；base trunk **`532b6c31`**；正本方案 `PLAN-0917-exercise-support.md` §3、§8。
Adam 09-17 裁決：路線 2（profile 旁掛、baseline 逐位元組不變）、L3；每階段閘門綠＋judge 過就直接推（常設授權）。

[Co-developed with claude code -- Adam]

## 0. 範圍與不在範圍

**目標**：NDTwin 的 P4 fabric（`p4_testbed_topo.py`＋`proxy_agent/main.py`＋kernel）能從一個「app package」目錄拿到
拓樸、主機設定、控制面模式；**沒有 package 時，每一個被改的讀取點回傳今天的字面值**，既有測試與閘門不變。
驗收（goal 原文）：①無 package：P4 側既有測試＋`merged_checks.sh` 六項全綠、`ndt up p4 4` 的 `switch_state`／`get_graph_data`
與改動前逐格同；②`--app basic`（pod-topo）在 NDTwin **自己的** pipeline 與路由下 `pingall` 0%；③`p4runtime` 的 `mycontroller.py`
與 proxy 共存不清表（`p4_proxy/reference/p4runtime_mastership_probe.py` 當斷言）。

**不在階段一**（記錄、不做）：G4 per-switch pipeline 載入（package 的 `pipeline` 欄位階段一一律 `null`＝NDTwin 自己的
artefact）、G5 `POST /p4/table_entry`（package 的 `entries` 階段一**只驗證不套用**）、G1 metadata 按名字、遙測 A/B、TCLink、G7–G9。

三張工單、三個 worktree、三條分支（都從 `532b6c31`）：
- **A core**：`feat/p4-app-package-core-0917` @ `scratch/overnight-2026-09-05/wt-app-core-0917` — §2
- **B tools**：`feat/p4-app-package-tools-0917` @ `scratch/overnight-2026-09-05/wt-app-tools-0917` — §3
- **C integration**（A、B 併回 trunk 後才派）：`ndt up p4 --app`、knob 生命週期、live 驗收腳本 — §4

## 1. package 格式 v1（A、B 的共同契約；改格式要先回 orchestrator）

```
<package_dir>/
  package.json
  ndtwin/topology.json        # NDTwin 拓樸模型（convert.py 產；schema＝setting/StaticNetworkTopologyP4_10Switches_4Hosts.json）
  (其餘檔案以 package.json 內的路徑引用；相對路徑相對於 package_dir，允許絕對路徑指進 ~/tutorials)
```
`package.json`：
```json
{
  "format": 1,
  "name": "basic",
  "source": {"kind": "p4lang-tutorials", "exercise_dir": "/home/adam/tutorials/exercises/basic",
             "topology_json": "pod-topo/topology.json", "p4": "solution/basic.p4"},
  "topology": "ndtwin/topology.json",
  "hosts": {"h1": {"ip": "10.0.1.1", "prefix_len": 24, "mac": "08:00:00:00:01:11",
                   "commands": ["route add default gw 10.0.1.10 dev eth0",
                                "arp -i eth0 -s 10.0.1.10 08:00:00:00:01:00"]}},
  "switches": {"1": {"name": "s1", "pipeline": null, "entries": "pod-topo/s1-runtime.json"}},
  "control_plane": {"mode": "ndtwin", "election_id": [0, 65535], "grpc_base": 30050, "device_id": "dpid"},
  "bmv2": {"cpu_port": 255},
  "links": [{"a": ["h1", 1], "b": ["s1", 1], "bandwidth_bps": 1000000000}]
}
```
語意：
- `switches` 的 key＝dpid（字串），`name`＝Mininet 名（`sN` ⇒ dpid N）。`pipeline: null` ⇒ NDTwin 自己的
  `p4_src/build/ndtwin_switch.{json,p4info.txt}`（階段一唯一允許的值；非 null 由 pre-flight 拒絕並印「G4 未做」）。
  `entries`＝tutorials 的 `sX-runtime.json` 路徑或 null；階段一 **pre-flight 驗它對得上 p4info、proxy 只在 `switch_state` 揭露「N 筆已記錄未套用」**。
- `hosts`：主機名一律 `h<N>`，且 **`N` 必須等於 IP 最後一個 octet**——這是 `topo_from_json.hosts()` 的命名規則（`p4_proxy/mininet/topo_from_json.py:86`），
  對不上就拒絕（pod-topo：10.0.1.1→h1…10.0.4.4→h4 ✓）。`mac` 存字串；模型檔裡存整數（`_mac_str` 會格式回 48 bit）。
  `commands` 在 Mininet 起來後於該 host 執行（取代 baseline 的全對 `arp -s`）。
- `control_plane.mode`：`ndtwin`＝proxy 照今天的流程（推 pipeline、clone session、LLDP、路由），但 election_id 用 package 的值；
  `external`＝**exercise 自帶控制器**（p4runtime／flowcache）：proxy 不開 arbitration stream、不推 pipeline、不寫任何東西、不建 clone、
  不發 LLDP、不裝路由，只讀（`ReadRequest` 不需要 election_id），並在 `GET /p4/switch_state` 揭露跳過了什麼。
  `election_id`：baseline 固定 `[0, 1]`（`p4_client.py:255-256` 等 12 處）；package 的 `ndtwin` 模式預設 `[0, 65535]`，
  讓任何投 `(0,1)` 的冒名者變成非 primary（被 bmv2 以 `PERMISSION_DENIED` 拒絕）而不是清表（`p4_client.py:60-74` 記的 08-13 實測）。
  `grpc_base`／`device_id`：階段一只允許 `30050`／`"dpid"`（`grpc_ports.py:48`，F-15 的埠區塊前檢）；tutorials 控制器寫死的
  `127.0.0.1:5005N／dev N-1` 由 B 的 adapter 在**控制器那一側**改寫，不動 fabric 的埠。
- `links`：轉換時記錄（含 tutorials 第 3／4 元素的 bw／delay 若有），階段一**不套用**整形（G2-C 在階段三）。

**knob**：`p4_proxy/mininet/app_package_override`——一行 package_dir 絕對路徑，同 `host_count_override`／`bmv2_binary_override` 的形狀
（第一個非空非 `#` 行；檔案不存在＝baseline；格式錯＝拒絕啟動）。proxy 與拓樸腳本都只讀這個檔（拓樸腳本經 tmux 起、環境變數傳不到——
`p4_testbed_topo.py:390-393` 的理由）。**寫入者只有 `ndt`（工單 C）**；A 只讀。

## 2. 工單 A — core（proxy／mininet／client；opus，worktree `wt-app-core-0917`）

### 2.1 `p4_proxy/mininet/app_package.py`（新；proxy 與拓樸腳本共用，經既有的 `sys.path.insert(mininet)` 慣例）
- `KNOB_PATH`、`read_knob(path=None) -> Optional[str]`、`load(package_dir) -> Package`（dataclass；驗 `format==1`、每個引用檔存在、
  hosts 命名規則、`switches` key 是正整數、`pipeline` 是 null、`control_plane.mode ∈ {ndtwin, external}`、`grpc_base==30050`）、
  `baseline() -> Package`（**回傳今天每個字面值**：election_id `(0,1)`、`cpu_port 255`、pipeline paths＝`p4_src/build/ndtwin_switch.*`、
  topology＝None（＝照 host count 選檔）、mode `ndtwin`、host commands None）。錯誤一律 `AppPackageError(ValueError)`，訊息說是哪個欄位。
- `p4_proxy/proxy_agent/profile.py`（goal 點名的檔）：`current() -> Package`＝讀 knob → `load` 或 `baseline()`，proxy 側唯一入口；
  import 時就決定、印一行 `[Proxy Agent] app package: <dir>|baseline`。

### 2.2 G2 — 拓樸改讀檔
- **共用選檔規則**：把 `p4_testbed_topo.py:87-135 _topology_model_path(host_num)` 搬到 `topo_from_json.model_path(host_num, setting_dir)`
  （拓樸腳本改成呼叫它；行為不變，`NDTWIN_P4_TOPO_FILE` 仍照原邏輯），package 存在時回傳 `package.topology`。
- `proxy_agent/main.py:103-120`：刪掉 `_HOST_NUM`／四等分公式，改 `for name, ip, mac in topo_from_json.hosts(model)` ＋
  `host_links(model)` 建 `topo.add_host(ip, mac_str, dpid, port)`；model＝`profile.current()` 的拓樸（baseline ⇒ `model_path(host_count_override)`）。
  **測試**：baseline 4 與 128 主機下 add_host 的 (ip, mac, dpid, port) 集合與舊公式**逐項相等**（`tools/test_workflow/test_topo_from_json.py`
  已對 Mininet 側證過同一件事，比照）。
- `proxy_agent/main.py:154 DEFAULT_SWITCH_DPIDS`：改由模型 `switches(model)` 推導；baseline 模型 10 台 ⇒ 仍是 `(1..10)`（測試斷言）。
  `build_p4_client(dpid, port_base, pipeline=None)`：pipeline 來自 `package.switches[dpid].pipeline or baseline`（階段一恆 baseline）。
- `mininet/p4_testbed_topo.py`：`MultiSwitchTopo` 的 `range(1, 11)`（:365）、`main()` 的 `grpc_port_block(range(1, 11))`（:825）與
  `range(1, 11)`（:877）全部改由模型的 switches 推導；`json_path`（:361）與 `--cpu-port 255`（:274-275）改讀 package（baseline 同值）；
  hosts 的 `/24`（:411）改讀 `prefix_len`（baseline 24）；package 存在時 `main()` 用 `hosts[*].commands` 取代 :867-873 的全對 `arp -s`
  （baseline 路徑一字不改）。`disable_host_offloads` 兩者都跑。

### 2.3 G3 — election_id 與 external 模式（`proxy_agent/p4_client.py`）
- `P4RuntimeClient.__init__(..., election_id=(0, 1), arbitration=True)`；`:255-256` 與 11 個 unary 的 `req.election_id.low = 1`
  （`:343 :433 :870 :907 :944 :963 :1060 :1112`…全部 grep `election_id` 確認）改用 `self.election_id`。
- `arbitration=False`：`start()` 不開 stream、不起 receiver thread；`set_forwarding_pipeline_config`／所有 write／`write_clone_session`／
  `send_packet_out` 一律 raise `ControlPlaneReadOnly(RuntimeError)`（訊息含 dpid 與「external control plane」）；`read_table_entries`／
  counter 讀取照常。`mastership_confirmed` 維持 False。liveness probe 若依賴 stream，改用一個 unary read 當 probe（先查
  `topology_manager.start_liveness_polling` 怎麼探）。
- `main.py startup()`：mode external ⇒ 跳過 pipeline push、clone session、`start_lldp_discovery`、`start_link_watchdog`、
  `install_initial_routes`（先找到它在哪被叫——不在 `main.py`，grep `topology_manager.py:1151` 的呼叫端）；`kernel.switch_entered` 仍呼叫。
  `startup()` 回傳值加 `"control_plane": {"mode", "skipped": [...], "package": dir|None}`。
- `api_routes.py` `GET /p4/switch_state`：**加**頂層欄位 `control_plane`（同上）與每台 `entries_recorded: N`（階段一恆「未套用」）。
  這是加法；跑 `tools/contract_test`（selftest＋spec）看 switch_state 的 schema 是否鎖死 `additionalProperties`——若是，改 spec 一起交，
  SUMMARY 明列。

### 2.4 測試與閘門（venv 直譯器 `p4_proxy/venv/bin/python -m unittest`；worktree 裡先 `ln -s` 主 checkout 的 `p4_proxy/venv` 與 `p4_proxy/p4_src/build`）
- 新 `p4_proxy/tests/test_app_package.py`：baseline 每個值＝字面值（**這就是「逐位元組不變」的證明**）、knob 解析（缺檔／註解／壞行）、
  package 驗證每一種拒絕理由各一顆（hosts 命名、pipeline 非 null、mode 非法、grpc_base 非 30050、引用檔不存在）。
- `test_startup.py` 加：external 模式 skip 清單、ndtwin 模式下 client 拿到 package 的 election_id、`control_plane` 回傳值。
- `test_p4_client.py` 加：arbitration request 與每個 unary 帶 `self.election_id`；`arbitration=False` 下 write／push raise、read 通。
- `tools/test_workflow/test_topo_from_json.py` 加：proxy 側 host table baseline 等價（4／128）。
- 變異閘 `tests/shell/mutate_app_package.sh`（照 `tests/shell/mutate_ryu_rest_topology_bounded.sh` 那種純 python 閘門的形狀：anchor 唯一、
  `cp -p`＋`touch`、還原 byte-identical、每次清 `__pycache__`、編不過／anchor 移位＝survivor、印 `N mutations, M survived`、exit 0/1/2）：
  M1 baseline election_id 回 (0,2)；M2 knob 存在但被忽略；M3 external 仍推 pipeline；M4 skipped 清單不回報；M5 host table 換回四等分公式；
  M6 dpids 寫回 `range(1,11)`；M7 某個 unary 不用 `self.election_id`；M8 hosts 命名檢查拿掉；＋控制組。**每個變異要被具名測試殺**，
  沒看過紅不算交付。
- 既有全套：`p4_proxy/tests` 全跑、`tests/shell` 裡 P4 相關閘門（`ls tests/shell | grep -i 'p4\|clone\|five_tuple\|sflow'`）、
  `tools/test_workflow/test_topo_from_json.py`、`tools/contract_test` selftest、`bash scratch/overnight-2026-09-05/hunt-0911/drivers/merged_checks.sh <sha> 1`。
  C++ 不動 ⇒ 不用 build（SUMMARY 用 `git diff --stat` 證）。

## 3. 工單 B — tools（`tools/p4_exercise/`；opus，worktree `wt-app-tools-0917`；純 python、不需 root、不動 p4_proxy）
- `convert.py <exercise_dir> --topology <rel topology.json> [--p4 solution/x.p4|x.p4] --out <package_dir>`：
  tutorials `topology.json`（`hosts{ip/mac/commands}`、`switches{runtime_json}`、`links[[a,b(,bw(,delay))]]`，端點 `hN` 或 `sN-pM`）
  → §1 的 `package.json` ＋ `ndtwin/topology.json`。模型：switch node 照 4-host 模型的 12 個 key（`brand_name "BMv2"`、`bridge_name/device_name/nickname sN`、
  `device_layer 2`、`dpid N`、`ip ["192.168.123.<10+N>"]`（agent IP 慣例）、`mac 0`、`smart_plug_ip ""`、`smart_plug_outlet 0`、
  `vertex_type 0`、`ecmp_groups`——**先 grep kernel `src/`／`include/` 看空陣列是否被接受，不確定就照 4-host 模型的形狀給**）；
  host node（`device_layer 3`、`dpid 0`、`ip [addr 無 prefix]`、`mac` 整數、`vertex_type 1`）；edges 雙向、host 側 `src_dpid 0`／`src_interface 1`／
  `src_ip [host ip]`、switch 側 `dst_interface`＝`pM` 的 M、`dst_ip [agent ip]`、`link_bandwidth_bps`（tutorials 有 bw 就換算，沒有 1e9）；頂層 `links: []`。
  `control_plane.mode`：exercise 目錄有 `mycontroller.py` ⇒ `external`，否則 `ndtwin`。輸出 `sort_keys`、固定縮排 ⇒ 可重現（測試比 sha）。
  必須用 `p4_proxy/mininet/topo_from_json.py` 回讀自己的輸出（`switches`／`hosts`／`switch_links`／`host_links` 都要過）。
- `preflight.py <package_dir>`：逐項印 PASS/FAIL 表、exit 0/1：`format`；引用檔存在；`topo_from_json` 四個 reader 通過；hosts 命名規則；
  p4info 解析（`google.protobuf.text_format`，用 `p4runtime` 的 `p4info_pb2`——venv 有 grpc；tutorials 的 `.p4info.txtpb` 同格式）；
  **entries 對 p4info**：表名、match 欄位名、match 形狀（`[addr, len]`＝lpm、純值＝exact；ternary／range 階段一報 FAIL「G5 未做」）、
  action 名、參數名、值能塞進 `bitwidth`；`default_action` 表存在；`pipeline` 非 null ⇒ FAIL「G4 未做」；`grpc_base` 非 30050 ⇒ FAIL；
  若 `source.p4` 給了且 `p4c-bm2-ss` 在 PATH ⇒ 編到暫存目錄、印 rc 與 sha（沒有 p4c ⇒ 印 `NOT COMPILED (p4c-bm2-ss absent)`，不裝作過）；
  埠區塊：`grpc_ports.assert_port_block_is_safe(grpc_port_block(dpids))`。
- `run_external_controller.py <package_dir> <controller.py>`：以 venv python，在 exercise 目錄為 cwd 下 `runpy.run_path` 該控制器，
  之前 monkeypatch `p4runtime_lib.bmv2.Bmv2SwitchConnection.__init__`（tutorials 的 `utils/p4runtime_lib`，sys.path 加 `~/tutorials/utils`）：
  `address '127.0.0.1:5005N' → 'localhost:<grpc_base+N>'`、`device_id N-1 → N`（對照 `mycontroller.py:167-176` 與 `p4runtime_lib/switch.py`）；
  印每次改寫。這是 ③ 的工具；本身不需 root，**不要在本 session 跑真控制器**（沒 fabric）。
- 測試 `tools/p4_exercise/tests/`（venv unittest）：fixtures 直接複製 `~/tutorials/exercises/{basic/pod-topo,basic/triangle-topo,p4runtime}` 的
  `topology.json`＋`s*-runtime.json`（+ `basic.p4.p4info` 若編得出）；convert 可重現（兩次 sha 同）、回讀通過、pod-topo 4 host 4 switch 8 link
  的具體數字；preflight 紅格：壞表名、壞欄位名、pipeline 非 null、host 命名不符、ternary entry；adapter 用假 `p4runtime_lib` 模組驗改寫。
  變異閘 `tests/shell/mutate_p4_exercise_tools.sh`（同 §2.4 慣例）：M1 convert 漏掉反向 edge、M2 host 側 dpid 不是 0、M3 preflight 對壞表名回 PASS、
  M4 adapter 不改 device_id、M5 lpm 長度不驗；＋控制組。
- 產出一個真的 package 供工單 C 用：`convert.py ~/tutorials/exercises/basic --topology pod-topo/topology.json --p4 solution/basic.p4 --out <worktree>/scratch-packages/basic/`
  與 `p4runtime` 的一份（external）；**不進版控**（寫在 SUMMARY 的路徑即可）；preflight 兩份都要 PASS 並附輸出。

## 4. 工單 C — integration（A、B 併回 trunk 後；opus）
`ndt up p4 --app <dir>`：跑 `preflight.py`（紅就拒）、寫 knob、`NDT_TOPO=<package>/ndtwin/topology.json`、`host_count_override`＝模型主機數
（`ndt:1587-1605` 已有 NDT_TOPO 與 host count 的一致性檢查，順著它走）、其餘照今天的 p4 路徑；`ndt up` 沒帶 `--app` 與 `ndt down` 刪 knob；
`ndt status` 印 `app package  <dir>|none`。`stack.sh` 的 `TOPO_P4`（:904）要跟 NDT_TOPO（先讀 `components.env` 怎麼定它）。
live 驗收腳本（Adam 跑 sudo）：**先在改動前的 trunk 抓 baseline**（`ndt up p4 4` → 存 `GET /p4/switch_state`、`get_graph_data`、`ndt verify_p4` 輸出）
再在合併樹抓一次逐格 diff；②`ndt up p4 --app <basic pkg>` → `ndt verify_p4`／pingall 0%；③`--app <p4runtime pkg>` → adapter 跑 `mycontroller.py`
→ `h1 ping h2` 通 → 用 `p4runtime_mastership_probe.py` 的第三方 client 讀表計數，proxy 掛著前後相同。

## 5. 規矩（三張共通）
- 記憶與 CLAUDE.md 的硬規則：不 `pkill -f`／`pgrep -f`；不碰 lab（無 sudo、不 `ndt up`、不 `mn`）；python 測試一律 venv 直譯器；
  每次跑測試前清 `__pycache__`（stale .pyc 兩次咬過人）；閘門腳本用 `/usr/bin/grep`（互動 shell 的 `grep` 是 ugrep shim）。
- commit：只在自己的 worktree、自己的分支；`git commit -F <msgfile> -- <明列檔案>`；AI 參與的檔案標 `[Co-developed with claude code -- Adam]`；
  結尾 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。不推、不併 trunk、不動主 checkout。
- 交件 `scratch/overnight-2026-09-05/hunt-0911/fix/P1-<A|B>-SUMMARY.md`：base sha、分支 head、每個測試套件的實跑指令＋rc＋最後一行、
  變異閘的 `N mutations, M survived` 與每個變異被哪顆測試殺、**沒做／沒驗的明列**、對本工單的異議（設計不合理就寫，別硬做）。
- 讀碼發現本工單行號漂了就以實際為準並在 SUMMARY 註明。
