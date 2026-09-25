# TICKET-P4-heartbeat — 第二刀：外來 P4 fabric 的 veth 心跳（偵測＋自動改路）

[Co-developed with claude code -- Adam]

- 發單：orchestrator「9/24 ochestrator」，2026-09-25；base＝trunk `bdda2fa8` 之後的 trunk HEAD。
- 前一刀：`doc/audit/2026-09-24_p4-driven-api-shape/TICKET-P4-roles.md`（roles 第一刀，併 `572d9462`）；設計在同目錄 `ANALYSIS.md` §5（「存活偵測，第一層是 veth 心跳」）。
- **Adam 09-25 裁決（互動表單，原文要點）**：
  1. 驗收＝**偵測＋自動改路**：外來 fabric 剪一條線 ⇒ ≤20 s 兩向不通 ⇒ NDTwin 改寫綁定的路由表 ⇒ 受影響主機 ping 恢復；capability `reroute` 在條件成立時為 true；含裁決 5(a)（`/stats/flowentry/*` 500→409）。
  2. 偵測速度**跟自家 fabric 同級**：自家是 `LLDP_BEACON_INTERVAL_S=5`、`LINK_BEACON_TIMEOUT_S=3×5`（`p4_proxy/proxy_agent/topology_manager.py:369,415`），最多約 20 s。
  3. sudo **加進現有 `ndtwin-lab` helper 的子指令**（sudoers 已是 `NOPASSWD: /usr/local/sbin/ndtwin-lab` 任意參數；helper 釘 sha，改版要 Adam 重裝）。**proxy 不提權**（09-24 已裁）。
  4. 心跳幀進使用者 pipeline 的副作用**可接受但要揭露**；**若改變使用者的轉送結果（任何封包因心跳而到達主機、任何 06 臂判定改變）⇒ 停下來回報，不要自己想辦法繞。**
  5. 不要求作者改 `.p4`（09-24 已裁）。

## 1. 分三段，每段各自交件（不要一口氣做完）

### 段 H — helper 子指令（先併，才能裝）

- `tools/test_workflow/ndtwin-lab` 加 `heartbeat` 子指令（`start`／`stop`／`status`，名字可議，要在 SUMMARY 說理由）。
- **root 入口的安全要求**（逐條要有看過紅的測試）：
  - 介面清單**只能來自正在跑的 fabric 自己的宣告**（manifest／`up.target` 記錄的拓樸），不接受任意介面名、任意路徑、任意 ethertype；參數白名單、無 shell 展開。
  - 只在 lab 有 fabric 在跑時可啟動；重複 start 不得產生第二個 daemon；`stop` 要真的停（pid＋cmdline 比對，**不准 `pkill -f`**）。
  - 結果交給 proxy 的方式由你設計（本機 HTTP 路由或檔案），但 **root 端不得替 proxy 做決策**：它只報「某方向在某時刻收不到／收到了」，改路是 proxy 的事。
- 既有 helper 測試（`tests/shell/test_ndtwin_lab_*.sh`）全綠；新增測試紅燈先行；新增具名變異進既有或新的 mutate 腳本。
- **交件後停。** orchestrator 逐 hunk 讀 → 併 trunk → 推播 Adam 裝（裝上去的 sha＝trunk 的，`ndt status` 不會警告）。

### 段 S — spike（要 lab，orchestrator 排時段給你）

量兩件事，數字進 `P4-HB-SPIKE.md`（OBSERVED／INFERRED 分欄）：
1. **偵測延遲分布**：pod-topo `--app basic`，用 **out-of-band** 的 `tc netem loss 100%`（不是 kernel 的 `inject_link_failure`，那條路 kernel 自己本來就知道）剪一條 spine 鏈路；量「套上 netem → 兩向判定不通」與「拿掉 → 判定恢復」各 ≥10 次。
2. **副作用普查**：13 個 tutorials 練習（`live-p1/06_thirteen.sh` 的清單）各自的 pipeline 收到心跳幀會怎樣：被丟？進了哪張表／計數器？**有沒有任何一個會把它送到主機**（主機端 sniff）？ethertype 的選擇要先對 13 支 `.p4` 的 parser 做碰撞檢查（例如 source_routing、basic_tunnel、calc 都有自訂 ethertype）。
- 停止條件：心跳幀到達任何主機 ⇒ 停、回報（裁決 4）。

### 段 W — 接線、改路、整合

- 心跳報告接到第一刀預留的 `TopologyManager.report_external_link_state`（`TICKET-P4-roles.md` §2.4）：外來 fabric 在心跳跑著時，走**和 beacon 逾時／恢復同一條路**（`_notify_link`＋watchdog pass），常數與自家 fabric 共用、不另寫一份。
- **改路**：每台外來交換機都是 `owner: ndtwin` 綁定時，斷線 ⇒ 重算 ⇒ 經 `RouteBinding` 改寫路由表；有任何 unbound／`owner: package` ⇒ 只偵測、不改路，`capabilities.reroute=false` 並給原因（與第一刀的 501 reason 同一套詞）。
- `capabilities.reroute` 只在「心跳在跑 **且** 全部綁定 `owner: ndtwin`」時為 true；`link_discovery` 在心跳在跑時要能看出來源（例如 `heartbeat`），不再是 `declared`。
- 生命週期：`ndt up p4 --app`（外來 fabric）啟動心跳、`ndt down` 停；`ndt status` 顯示心跳狀態；pidfile 與 `down` 的 rc 語意照既有慣例。**NDTwin 自己的 pipeline（LLDP）不啟動心跳。**
- 裁決 5(a)：`/stats/flowentry/*` 在唯讀／外部控制平面上回 409（`ControlPlaneReadOnly`），不再是 500。
- 揭露：心跳副作用（段 S 的普查結果）寫進 `switch_state` 能看得到的地方與 SUMMARY。

## 2. 驗收

**離線（你做）**：每段新測試紅燈先行（commit 分開，log 在 `logs/gates-0910/*.p4hb-*.log`）；具名變異 0 survived；`check_gate_anchors` ok；p4_proxy 全套、p4_exercise、drive_exercise 全綠；baseline（NDTwin pipeline）零變化的證據沿用第一刀的鏈（`/stats/flow` fixture 等）。

**live（併進 trunk 後 orchestrator 做，你要備好腳本 `live-p1/08_heartbeat.sh`，照 07 的寫法自己 claim／release、快照還原旋鈕）**：
- **H1**：pod-topo `--app basic`（`owner: ndtwin`）＋心跳：out-of-band netem 剪一條 spine 鏈路 ⇒ ≤20 s kernel 圖兩向 `is_up:false` ⇒ 路由改寫 ⇒ 12 對主機 ping 全部恢復（收斂後 0% loss）；拿掉 netem ⇒ ≤20 s 恢復 `is_up:true`；兩端無殘留 netem。
- **H2（陰性對照）**：同一剪法、心跳**不跑** ⇒ `is_up` 保持 true（證明偵測來自心跳，不是別的路）。
- **H3**：unbound 版 package ⇒ 偵測到、不改路、作者 entries 前後相同、`reroute:false` 附原因；寫入仍回 501。
- **H4**：`/stats/flowentry/*` 在外部控制平面回 409。
- **H5**：06 完整跑**一次**、心跳開著 ⇒ 26/26 且逐臂與 `2026-09-24T185505Z` 相同；01 PASS（NDTwin fabric 不變）。
- 每步 raw 進 `live-p1/runs/`；不如預期照實回報，不准重跑到綠。

## 3. 紀律（違反＝退件）

- 只在你的 worktree／分支動；commit 一律 `git commit -m ... -- <列到檔案>`，新檔先 `git add -N`；**不 push、不 merge、不碰主 checkout**。
- 新 worktree 沒有 `p4_proxy/venv` ⇒ 閘門用 `PYTHON=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python`；build／閘門走 `tools/build_guard/guarded_build.sh`，`JOBS=1 LOCK_WAIT=10800`。
- **lab 只在 orchestrator 給你時段時用**，`NDT_OWNER` 用你自己的、先 claim、看 `measuring` 欄；斷線只用 `tc netem`；長跑包 `setsid`；**永不 `pkill -f`／`pgrep -f`**；不碰實體 testbed。
- sudo 只能透過 `/usr/local/sbin/ndtwin-lab`（已裝的版本）；**不要叫 Adam 做任何事**，要他做的寫進 SUMMARY 由 orchestrator 轉。
- AI 碼標 `[Co-developed with claude code -- Adam]`；code／commit 英文，SUMMARY 中文（OBSERVED／INFERRED 分開，「跑過」與「讀過未執行」不混表）。
- 交件：`scratch/overnight-2026-09-05/hunt-0911/fix/P4-HB-SUMMARY.md`（每段一節，末尾寫 head sha 與每支閘門最後一行）。
