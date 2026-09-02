# run-01（sonnet）— orchestrator 獨立複驗（2026-09-02 18:46–19:0x CST）

**原則**：tester 的回報是宣稱。下面每一列都是我自己進 guest 或讀 repo 查出來的；「CONFIRMED-by-log」表示我只讀了它留下的
raw log 而沒有重跑那個步驟。三支複驗腳本在 `orchestrator-scripts/`，原樣可重跑。VM＝`nslab:~/ndtwin-vm-usertest-01-sonnet/`（port 2311）。

## 時間線（host＝CST；guest＝UTC，差 8 小時）

| 時刻 | 事件 |
|---|---|
| 14:07:50 | VM start（4 vCPU／6144 MB、affinity 16-19），guest 驗新（無 `~/Desktop`、無 repo、無工具鏈） |
| 14:1x | sonnet tester 派出；guest 06:09Z 開始讀手冊 |
| 14:2x | **本線 Claude Code 閃退**；tester 停在 §2（06:20Z）；VM 不受影響 |
| 14:36 | SendMessage 續接同一 agent；它自己記 06:36Z 恢復 |
| ~15:41 | **tester 在 Browser 工具那步 stall**，harness watchdog 600 s 判 failed（07:41Z） |
| 15:5x | 第二次 SendMessage 續接（加「不用 Browser 工具」規則） |
| 18:03 | tester 記錄的實際恢復時間（10:03Z）——**與續接訊息差約 2 小時，原因不明**（harness 排程；VM 期間空轉，§6.1 背景安裝 06:46Z→08:52Z 期間跑完） |
| 18:44 | tester 交最終報告；VM `uptime` 4h35m |
| 18:46–19:0x | 本複驗；然後 `stop` |

## 逐項

| # | 宣稱 | 我查了什麼 | 判定 |
|---|---|---|---|
| 1 | `JOURNAL.md` 498／`BUGS.md` 582／`CHECKLIST.md` 134 行 | `wc -l`＋`md5sum`，拉回本機後逐位元組同（a83255ee…／bfe82f9d…／275889a7…） | ✅ CONFIRMED |
| 2 | Checklist 69 WORKS／4 BROKEN／1 SKIPPED／~33 NOT-TRIED | 我自己數：**63 WORKS＋21 WORKS-BUT、5 BROKEN、1 SKIPPED、29 NOT-TRIED**（它的 tally 把 WORKS-BUT 混進 WORKS、BROKEN 少算一個） | ⚠️ 數字略異，方向一致 |
| 3 | OVS 路線裝好 | `build/bin/ndtwin_kernel` 在；`/usr/bin/mn`、`/usr/bin/ovs-vsctl` 在；fabric 收斂的證據只在它的 `manual_terminal*.log`（未重跑） | ✅ CONFIRMED（靜態）／收斂 CONFIRMED-by-log |
| 4 | §6.1 P4 工具鏈裝好 | `simple_switch_grpc` **1.15.6-1c8c9a4f**、`p4c-bm2-ss` **1.2.5.17 (d46d824202)**——與同日 A-6 prep61 完全相同；`~/p4dev-python-venv/pyvenv.cfg` **home=/usr/bin、3.12.3**（tester 有做 `conda init`，手冊 §6.1 的紅字仍把它擋對了）；七棵樹在 `$HOME`、repo 內 0 棵；`step6.1_p4toolchain.log` **`Total time : 7544 sec`**（06:46Z→08:52Z，4 vCPU／5925 MB ⇒ 2 個 job） | ✅ CONFIRMED＋**第四個計時資料點：4 vCPU／6 GB＝2h05m44s** |
| 5 | P4 資料平面跑起來（10 台 bmv2、16256 paths、流量） | `kernel_p4.log` 10:09:59Z 起 1282 行、`p4proxy.log` 2.0 MB、`ndt_up_p4.log`；未重跑 | ✅ CONFIRMED-by-log |
| 6 | ESA 自主把 s9 關掉，且用第二個查詢確認 | `kernel_sim2.log`：**10:26:49.774 `POST /ndt/set_switches_power_state?ip=192.168.123.19&action=off` → 10:26:50.745 `MININET: switch s9 -> off` → `link failed on 9:1 -> 5:3`**；tester 的 `GET /ndt/get_graph_data` 在 10:27:10.410 落在之後。接著 ESA 每分鐘再關一台（.17 於 10:27:49、.15 於 10:28:49） | ✅ CONFIRMED——而且證據比它給的更強：kernel 自己記了「s9 -> off」的動作，不只是 200 |
| 7 | 「VM 留著 Web GUI stack 與 Simulation Platform stack 仍在跑」 | docker 三個容器 Up（frontend 6 min、api／postgres 3 h）；`simulation_platform_manager` pid 431581（:9000）與 `energy_saving_app` pid 431726（:8001）活著；**但 `ndtwin_kernel`／`ryu-manager`／`simple_switch_grpc` 全部 0 個**——底下的 fabric 已被它 10:3x 的 `ndt up` P4 重試拆掉，`esa_run.log` 結尾是 connection refused 的 stack trace | ⚠️ PARTLY：兩個 app 行程在、但已無 kernel 可連 |
| 8 | BUG-001／002（§2.6 的 `is_mininet` 是死開關、`switch_num = 10` 不存在） | 本機 `intelligent_router.py:43,56`：`is_mininet = True   # … SEE ABOVE, this value is discarded`；`:92–98` `switch_num` 由 `NDTWIN_RYU_SWITCH_NUM` 或 topology 檔導出 | ✅ CONFIRMED（原始碼）；**新** |
| 9 | BUG-003（`ndt up ovs` 因 `ndtwin-lab` 不在 `/usr/local/sbin` 而死） | User Manual 該頁第 28 行只給 `ln -sf …/tools/test_workflow/ndt ~/.local/bin/ndt`；`tools/test_workflow/ndt` 用 `sudo -n "$LAB"` 呼叫 `ndtwin-lab`；guest 內 `/usr/local/sbin/ndtwin-lab` 是 tester 06:53 自己補的 symlink、且原檔非可執行（repo diff 顯示 mode change） | ✅ CONFIRMED；**新**（文件缺步驟＋工具假設） |
| 10 | BUG-004（`ndt up` 3/3 失敗：`fabric has 0 hosts, expected 128`／`0/10 switches, manifest missing`） | `ndt_up_ovs_2.log`、`ndt_up_p4.log` 原文如它所述；訊息出自 `ndt:923`；**機制未查**（要進 `ndtwin-lab` 的 root tmux 看 pane，它已結束）；我沒重跑 | ✅ CONFIRMED-as-observed；機制 OPEN；**新** |
| 11 | BUG-005（`ndt apps sim`／`energy` 印 ok 卻沒起任何東西） | 原始碼 `ndt:1928-1929`：`sudo -n "$LAB" sim-start >/dev/null && ok "sim started (tmux: sim)"`——只看 `ndtwin-lab` 的 rc，**沒有存活檢查**（對照 `nsr` 走 `app_spawn`，`sleep 1; kill -0`）。**我自己重現一次（18:5x）**：印 `ok  sim started (tmux: sim)`、rc 0、root 的 `ndtwinlab` socket 上 `no server running`、`.test_run/pids/` 空、無 `app_sim.log`、java／kernel 行程數前後皆 0 | ✅ CONFIRMED ×3（tester 2＋我 1）；**新**；「失敗回報成功」一族 |
| 12 | BUG-006（NSR 的 stop 腳本用 `kill $(pgrep -f …)`） | `~/Desktop/Network-State-Recorder/stop_network_state_recorder.sh:2-3` 原文 `echo $(pgrep -f network_state_recorder.py)`／`sudo kill -15 $(pgrep -f …)` | ✅ CONFIRMED；**新**（別的 repo） |
| 13 | BUG-007（User Manual 的 NTG 啟動指令指向不存在的 conda 路徑） | User Manual NTG 頁 **第 138、263 行**：`~/miniconda3/envs/ntg-env/bin/python`；Installation Manual 建的是 `~/ntg-env` venv（guest 內 `~/ntg-env/pyvenv.cfg` home=/usr/bin） | ✅ CONFIRMED；**新**（兩本手冊互相矛盾） |
| 14 | BUG-008（venv 看不到 apt 裝的 `mininet`） | `~/ntg-env/pyvenv.cfg`：`include-system-site-packages = true`、`command = … --system-site-packages`＝tester 的 workaround 留痕 | ✅ CONFIRMED（by workaround）；**新**（文件缺一個旗標） |
| 15 | BUG-009（Web-GUI Dockerfile 未釘 pnpm，build 直接死） | `~/Desktop/Web-GUI/Dockerfile` 第 11 行 diff：`-RUN npm install -g pnpm` → `+RUN npm install -g pnpm@9`；`server/Dockerfile:6` 仍未釘；三個容器現在 Up | ✅ CONFIRMED；**新**（Web-GUI repo） |
| 16 | BUG-010（kernel 的 log 印完整關機序列後行程仍活 14 分鐘） | **`kernel_p4.log`（1282 行，10:09:59Z→10:24Z）裡沒有 `All subsystems stopped`、沒有 `Exiting.`、沒有 `terminate called`——它說「log 顯示完整關機序列」是錯的**（很可能跟 07:25Z 的 OVS 場 `kernel_session2.log` 混了）。站得住的部分：`kernel_sim.log:17` 10:23:48Z `bind: Address already in use`＝10:09:59Z 起的 P4 kernel 當時仍在聽 :8000（`ps` 的 `ELAPSED 14:22` 與之吻合）；而它 D13 判「乾淨」用的檢查（`simple_switch_grpc` 計數、:8081）**本來就不看 kernel** | ⚠️ **PARTLY REFUTED**：log 宣稱錯、「行程沒死」成立。改判為 ①手冊 P4 關機檢查缺 kernel 存活（:8000）一項——文件缺口；②`kill -INT` 打在 `setsid nohup sudo` 的 wrapper pid 上是否送達 kernel——**OPEN，要刻意重現** |
| 17 | BUG-011（`get_cpu_utilization` 是 `10 + hash(ip) % 50`） | 原始碼 `DeviceConfigurationAndPowerManager.cpp:947,1548,1810`；**`doc/KNOWN-ISSUES.md` F-1 早已記載**；`ndt check` 那句是我們自己寫的 | ✅ CONFIRMED；**已知（F-1）**，naive user 透過 `ndt check` 再發現；新角度＝**兩本手冊都沒揭露** |
| 18 | 每台交換機 130 條 flow 不是手冊寫的 131 | User Manual 該頁第 119 行寫 **131**、第 112 行的公式算出 129；tester 量兩次 130 | ✅ CONFIRMED（文件三個數字互不一致）；**新**；真值待重量 |
| 19 | `ndt --help` 的介面遠大於手冊 | 我在 guest 跑 `ndt --help`：up 變體、`down --deep`、`status --check`、`clean`、`check`、`apps`、`ntg`、`claim`／`release` | ✅ CONFIRMED |
| 20 | NTG／NSR／Visualizer／SPM 各 WORKS | 只讀 log 與各 repo 的 diff（NTG `host_file` 改 Mininet.yaml、NSR interval 2→1、Visualizer 的 `xwd` 截圖 `tester-files/tv_screen.png` 144 KB、ESA／SPM 已 build）；未重跑 | ✅ CONFIRMED-by-log／artefact |

## tester 報告裡站不住的三處

1. **BUG-010 的「log 顯示完整關機」**——`kernel_p4.log` 沒有那些行（見 #16）。
2. **「stacks still live」**——app 行程在，kernel 不在（#7）。
3. **自己的工時帳**：報告說「active ~2 h」，`JOURNAL.md` SUMMARY 說「roughly 4.5 hours of active work」；VM uptime 4h35m 含兩段空轉。取 journal 的分段時間為準：**安裝（§1–5）約 20 分鐘、§6.1 背景 2h06m、使用與抓 bug 約 1h30m**。

## 這一輪自己的方法缺陷（不是 NDTwin 的）

- 兩次中斷都出在 harness 這側（閃退、Browser 工具 stall），VM 從頭到尾沒事；第二次續接到它實際恢復差了約 2 小時，沒解釋。
- run-02 起模板已禁 Browser 工具（`3b09e75c`）。
