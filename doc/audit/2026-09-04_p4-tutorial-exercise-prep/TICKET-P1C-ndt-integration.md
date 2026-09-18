# TICKET-P1C — 階段一工單 C：`ndt up p4 --app <dir>`、knob 生命週期、live 驗收腳本

orchestrator「9/17 orchestrator」2026-09-17 寫；base＝A、B 併入後的 trunk（派工時給 sha）。母工單 `TICKET-P1-app-package.md` §4；
A 的交件 `scratch/overnight-2026-09-05/hunt-0911/fix/P1-A-SUMMARY.md`（**先讀 §4 的 11 條偏離與 §5 的「沒做」第 9 條**）、
B 的交件 `P1-B-SUMMARY.md`（§5 兩個 package 的 preflight 輸出、adapter 的改寫表）。

[Co-developed with claude code -- Adam]

## 0. 已經落地、你要接的東西（讀碼確認，行號以實際為準）
- **knob** `p4_proxy/mininet/app_package_override`：一行 package_dir **絕對路徑**；檔案不存在＝baseline；**存在但沒有指令行＝拒絕啟動**
  （A §4-3，與 `host_count_override` 不同）。讀者：`p4_proxy/mininet/app_package.py`（`read_knob`／`load`／`baseline`／`current`）、
  `p4_proxy/proxy_agent/profile.py`、`p4_testbed_topo.py`（經 `topo_from_json` 的搬家函式）。**寫入者只有 `ndt`＝你。**
- package 的 topology 與 `NDTWIN_P4_TOPO_FILE` 不一致 ⇒ 拒絕（A §4-5）；proxy **import 時**就讀拓樸模型、讀不到就 raise（A §4-11）。
- `GET /p4/switch_state` 多了頂層 `control_plane {mode, package, skipped}` 與每台 `entries_recorded`；baseline 也有（`skipped: []`／`0`）。
- `tools/p4_exercise/{convert,preflight,run_external_controller}.py`（venv python）；B 的兩個 package 在
  `scratch/overnight-2026-09-05/wt-app-tools-0917/scratch-packages/{basic,p4runtime}`（版控外）——**live 用的 package 由你用 convert.py 重新產到
  `.test_run/packages/{basic,p4runtime}`**（`.test_run` 在 .gitignore），preflight 兩份都要 PASS 並把輸出存進 runs/。
- 🔴 A §5-9：`sflow_emitter.load_switch_agent_ips()` 讀 `NDTWIN_TOPO_FILE`（否則 `DEFAULT_TOPO_FILE`＝4-host 模型），**沒改成讀 package**
  ⇒ `ndt up p4 --app` 必須讓 proxy 的環境看到 `NDTWIN_TOPO_FILE=<pkg>/ndtwin/topology.json`（proxy 由 `stack.sh:~1007` 起，先查它怎麼傳環境）。

## 1. `ndt`（`tools/test_workflow/ndt`，8500 行 bash；`ndt:8287` 的 `up)` 分派、`:1587-1605` 的 `NDT_TOPO` 一致性檢查、`:1646` 寫 host_count_override）
- 語法：`ndt up p4 --app <dir>`（也接受 `--app=<dir>`）；`<dir>` 轉絕對路徑；**`p4` 以外的 plane 帶 `--app` 一律拒絕**。
- 流程：①`preflight.py <dir>`（用 `components.env` 的 `P4_PROXY_PY`）—— FAIL ⇒ 原樣印表、**rc 沿用 `ndt` 既有的「refused to build」碼**（看 NDT-8 定的 rc 契約 1/3/5，選同一個；`ndt help` 的 rc 表要對得上）；②寫 knob（絕對路徑＋一行 `# written by ndt up p4 --app at <UTC>` 註解）；
  ③`host_count_override`＝模型主機數（走既有 `:1646` 那條、印同一句 warn）；④`NDT_TOPO=<dir>/ndtwin/topology.json` 進既有一致性檢查；
  ⑤`stack.sh` 的 `TOPO_P4` 要等於它（**先讀 `components.env` 怎麼定 `TOPO_P4`、`NDT_TOPO` 有沒有流進去**——不是就補），kernel `--topology` 與
  proxy 的 `NDTWIN_TOPO_FILE` 都指同一檔；⑥其餘照今天的 p4 路徑。
- **knob 生命週期**：`ndt up`（任何 plane）沒帶 `--app` ⇒ 先刪 knob；`ndt down` ⇒ 刪 knob；`ndt clean` 同 down。刪之前若 knob 存在要印一行
  `app package cleared: <dir>`。**絕不留一個空 knob**（A 把空檔定義成拒起）。
- `ndt status`：加一列 `app package   <dir> (mode <ndtwin|external>)` 或 `none`；有 knob 但目錄不存在 ⇒ 列成 problem（`--check` 要黃）。
- **proxy 起不來要看得見**：A §4-11 讓 `proxy_agent/main.py` 在 import 時 raise。查 `stack.sh` 怎麼判 proxy 活著（`:8081` listen？）、log 在哪
  （`.test_run/logs/`？）；`ndt up` 在 proxy 沒起來時要印 proxy log 的最後 10 行，不能只說「proxy not listening」。
- `ndt verify_p4`（`ndt:1173-1280`：路徑數穩定、graph／拓樸檔／`fabric_host_count()` 三方一致、真 ping）在 package 下要能過：
  grep `ndt` 裡寫死 `10.0.0.`／`h1..h4`／`range 1..10` 的地方，package 的主機是 `10.0.1.1`…`10.0.4.4`、交換機 4 台。
- **測試**：`tests/shell/test_ndt_app_package.sh`（離線，照 NDT-10 的離線守衛測試形狀：`ndt:2105` 的 source guard，stub 掉 preflight／stack）：
  `--app` 寫 knob、無 `--app` 刪 knob、`down` 刪 knob、preflight FAIL ⇒ 拒＋rc、status 那列、非 p4 plane 拒絕、空 knob 不會被留下；
  變異閘 `tests/shell/mutate_ndt_app_package.sh`（≥5 個變異＋控制組，慣例同 A/B）。既有 `tests/shell/test_ndt_*.sh` 全綠。

## 2. live 驗收（Adam 跑 sudo；你只寫腳本＋預期輸出，**不跑 sudo、不 `ndt up`**）
目錄 `doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/`：`README.md`（每一步一格＋預期最後一行）、腳本各自把 raw 寫進
`live-p1/runs/<UTC>_<step>/`（之後進 audit-raw）。每支腳本：`set -euo pipefail`、開頭 `NDT_OWNER=adam ndt status` 看 claim／measuring、
自己 claim、EXIT trap `ndt down`＋release、**不 `pkill -f`**。
- `01_baseline.sh`：無 knob（先確認 `app_package_override` 不存在）`ndt up p4 4` → 存 `GET :8081/p4/switch_state`、`GET :8000/ndt/get_graph_data`、
  `ndt status`、`ndt verify_p4`、proxy log 前 40 行 → `ndt down`。**對帳「改動前」**：找 09-12 的 live cells／`--tag ndt` 輸出裡最近一份
  `switch_state`／`get_graph_data`（`scratch/overnight-2026-09-05/logs/`、`hunt-0911/logs/`）；比**結構欄位**（switch 數、host 數、edge 數、
  每台 `probe_ok`／`isEnabled`、`skipped`），時間戳／age 類欄位標「不比」；找不到可比的就明說「無改動前 raw，只能證明合併樹自身自洽」。
  新增兩鍵（`control_plane`、`entries_recorded`）預期出現且為 `skipped: []`／`0`——這是驗收①的讀法（A §4-1）。
- `02_app_basic.sh`：`convert.py` 產 `.test_run/packages/basic`（solution）→ preflight PASS → `ndt up p4 --app .test_run/packages/basic` →
  `switch_state.control_plane.mode == ndtwin`、`package` 路徑對、`entries_recorded` 每台 5、四台交換機、四主機 → `ndt verify_p4`（真 ping）
  ＋ `mnexec` 的 `pingall` 0% loss（用 `ndt` 既有的 helper，不自己 `pgrep`）→ `ndt down` → knob 已被刪。
- `03_app_p4runtime.sh`：`convert.py` 產 `.test_run/packages/p4runtime`（external）→ preflight → `ndt up p4 --app …`（proxy external：
  `switch_state.control_plane.skipped` 含 pipeline_push／clone_session／lldp／link_watchdog／initial_routes，`entries_recorded` 0）→
  背景 `setsid` 跑 `run_external_controller.py <pkg> mycontroller.py`（它會推 pipeline、灌 tunnel 規則、每 2 s 印 counter；stdout 存檔）→ 等 10 s →
  `h1 ping -c3 h2` 3/3（**這證明 proxy 掛著時 exercise 的控制器是 primary 且規則在**）→ 用 `p4_proxy/reference/p4runtime_mastership_probe.py`
  的第三方 client（或它的 read 片段）數 s1 表項 N>0 → `POST :8081/p4/readopt/1`（proxy 試圖推 pipeline）⇒ 預期 **4xx/5xx 且 body 含
  `ControlPlaneReadOnly`／external** → 再數 s1 表項 ＝ N、`ping` 仍 3/3 ⇒ **共存不清表**（驗收③）→ 停控制器（用它的 pid，`kill <pid>`）→ `ndt down`。
- 每支結尾印 `PASS`／`FAIL <原因>`；README 寫清楚三支要依序跑、中間任何 FAIL 就停、raw 目錄路徑。

## 3. 規矩
同母工單 §5：venv python、`/usr/bin/grep`、清 `__pycache__`、不 sudo、不 `pkill -f`、`-F` 訊息、明列 pathspec、AI 標記、
`Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`、交件 `hunt-0911/fix/P1-C-SUMMARY.md`（沒做／沒驗明列；對工單的異議寫出來）。
