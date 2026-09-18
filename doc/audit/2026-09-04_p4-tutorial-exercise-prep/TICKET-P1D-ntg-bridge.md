# TICKET-P1D — 階段一補丁 D：live 起 fabric 的是 `ntg_bmv2_topo.py`，它沒有跟上 package；橋接輸出要落檔

orchestrator「9/17 orchestrator」2026-09-18 寫；base＝本地 trunk **`41d7950f`**（A＋B＋C 已併、未推）。母工單 `TICKET-P1-app-package.md`、`TICKET-P1C-ndt-integration.md`。

[Co-developed with claude code -- Adam]

## 0. live 抓到的紅（`live-p1/runs/2026-09-18T024156Z_02_app_basic/`）
- `01_baseline` **PASS**（10 台、40 edge、`probe_ok` 全 True、`control_plane` ndtwin／None／[]）。
- `02_app_basic`：convert／preflight PASS，`ndt up p4 --app` 走到 `[1/3] bmv2 fabric` → **`fabric did not come up: 0/4 switches, manifest missing`** → rollback。`/tmp/sN_bmv2.log` 一個都沒產生。
- **根因（讀碼，待 traceback 確認）**：`/usr/local/sbin/ndtwin-lab topo-start` 起的是 **`p4_proxy/mininet/ntg_bmv2_topo.py`**（`ndtwin-lab:300 BRIDGE=…/ntg_bmv2_topo.py`，用 `NTG_PY`＝conda `ntg-env` python 3.10＋`sys.path.append('/usr/lib/python3/dist-packages')` 借系統 Mininet），**不是** `p4_testbed_topo.py`。
  A 的 G2 fabric 側全部改在 `p4_testbed_topo.main()`；`ntg_bmv2_topo.main()` 只從那裡 import `MultiSwitchTopo`（所以拓樸物件照 package 建成 4 台），其餘仍是抄本：
  `json_path` 寫死 `ndtwin_switch.json`（:67）、`grpc_port_block(range(1, 11))`（:87）、`hosts = range(1, _host_count_override()+1)`（:131）、**全對 `arp -s`**（:132-135；package 的 `host_commands` 完全沒跑 ⇒ pod-topo 主機沒有 default gw、跨子網 ping 必失敗）、**`switches = [net.get(f's{i}') for i in range(1, 11)]`（:139）⇒ 4 台的 fabric 上 `net.get('s5')` 拋 KeyError**，`write_manifest` 永遠到不了、沒有 try/finally ⇒ 行程死、tmux session 消失、pane 輸出跟著消失。
- **可診斷性缺口**：橋接腳本的 stdout/stderr 只在 root 的 tmux pane；行程一死 pane 就沒了，`ndt up` 只能印「look at the pane」。

## 1. 要做的
1. **一份 bring-up，兩個入口**：把 `p4_testbed_topo.main()` 裡「建 net → 起 → 主機設定（package 有 `host_commands` 就跑它、否則全對 ARP）→ `disable_host_offloads` → 交換機清單由模型 → `verify_switches` → `write_manifest` → verdict」抽成一個共用函式（例如 `bring_up(package, model) -> (net, switches, fatal, report)`），`p4_testbed_topo.main()` 與 `ntg_bmv2_topo.main()` 都呼叫它；兩邊的 teardown 也共用。`ntg_bmv2_topo.py` 的前置檢查（json 存在、nornir、binary、port block、`mn -c`、orphan 清理）改用 `fabric_model()`／`package.pipeline_for`／`grpc_port_block(dpids)` 同一套。**baseline（無 knob）下兩個入口產生的 argv、ARP 指令、manifest 內容要與改動前逐字相同**——用測試證（stub Mininet／net 物件記錄呼叫）。
2. **橋接輸出落檔**：`ntg_bmv2_topo.py` 一開始把 stdout/stderr tee 到 `$KERNEL_DIR/.test_run/logs/topo.log`（既有 proxy／kernel log 的輪替慣例，看 `stack.sh` 怎麼做 `p4_proxy.log.<stamp>`），tmux pane 照常顯示（NTG 的互動 CLI 要能用 ⇒ tee 不能吃掉 tty；用 `os.dup2` 或 `script`-style 的 line-buffered tee，讀 `command_line()` 對 stdin/stdout 的要求）。任何未捕捉例外要印 traceback 到那個檔再退出。
3. **`ndt up`**：`fabric did not come up` 時印 `topo.log` 最後 30 行（比照 C 給 proxy 加的 `proxy_log_tail`），並在 rollback 之前印；`ndt status --check` 不動。
4. **測試**：(a) 離線測試：以 package fixture（複製 `tools/p4_exercise/tests/fixtures` 或 A 的 `test_app_package.py` fixture）在 stub net 上跑共用 bring-up，斷言交換機集合＝模型、主機命令＝package 的 `commands`（且**沒有**全對 ARP）、manifest 寫的是 4 台；baseline fixture 下斷言全對 ARP 與十台、與改動前逐字同；(b) `ntg_bmv2_topo.main()` 在「模型宣告 4 台」下**不再**呼叫 `net.get('s5')`（這是紅格）；(c) 變異：`mutate_app_package.sh` 加 M：橋接端切回 `range(1, 11)`／不跑 `host_commands`／不 tee——各被具名測試殺；(d) 既有 `test_topo_from_json.py`、`p4_proxy/tests` 全套、`test_ndt_*.sh`、六項 merged checks 綠。
5. **不動**：`p4_proxy/proxy_agent/*`、package 格式、`ndt` 的 `--app` 語意。

## 2. 規矩
同母工單 §5；worktree 從本地 trunk `41d7950f` 開（`git -C /home/adam/Desktop/NDTwin-Kernel worktree add -b feat/p4-app-package-bridge-0918 scratch/overnight-2026-09-05/wt-app-bridge-0918 trunk`，symlink venv／build 同前）；不 sudo、不 `ndt up`；`/usr/bin/grep`；`-F` 訊息；交件 `hunt-0911/fix/P1-D-SUMMARY.md`。orchestrator 併回後親自跑 `live-p1/02_app_basic.sh`。
